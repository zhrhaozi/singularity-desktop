import Cocoa
import OpenGL.GL3
import SwiftUI

/// Offscreen rendering shares the real pet's uniforms, shaders and multi-body compositor, not its capture session.
final class PreviewRenderer {
    private let renderer: PetView
    private let state: Model
    private var framebuffer: GLuint = 0, color: GLuint = 0
    private let side: GLsizei = 240
    private var count = 0

    init?(state: Model) {
        let previous = NSOpenGLContext.current
        defer { if let previous { previous.makeCurrentContext() } else { NSOpenGLContext.clearCurrentContext() } }
        guard let view = PetView(frame: NSRect(x: 0, y: 0, width: 120, height: 120), capture: Capture(), state: state, preview: true),
              let context = view.openGLContext else { return nil }
        renderer = view; self.state = state
        context.makeCurrentContext(); view.prepareOpenGL()
        guard view.program != 0 else { return nil }
        glGenFramebuffers(1, &framebuffer); glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffer)
        glGenTextures(1, &color); glBindTexture(GLenum(GL_TEXTURE_2D), color)
        glTexImage2D(GLenum(GL_TEXTURE_2D), 0, GL_RGBA8, side, side, 0, GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), nil)
        glFramebufferTexture2D(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_TEXTURE_2D), color, 0)
        guard glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER)) == GL_FRAMEBUFFER_COMPLETE else { return nil }
    }

    func frame(dt: Double) -> NSImage? {
        let previous = NSOpenGLContext.current
        defer { if let previous { previous.makeCurrentContext() } else { NSOpenGLContext.clearCurrentContext() } }
        renderer.openGLContext?.makeCurrentContext()
        if count != state.bodyCount { count = state.bodyCount; renderer.resetOrbits() }
        renderer.orbits?.driftEnabled = state.systemDrift
        if !state.paused { renderer.orbits?.advance(dt: dt, speed: state.orbitSpeed) }
        renderer.advanceAnimation(dt: dt)
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffer)
        renderer.renderFrame(width: side, height: side, useCapture: false)
        // A fixed 120 pt stage still shows changes to the pet's size. Crop centrally, never sample the screen.
        let fraction = (state.size - SettingsSpec.size.range.lowerBound) / (SettingsSpec.size.range.upperBound - SettingsSpec.size.range.lowerBound)
        let n = Int(Double(side) * (0.94 - 0.40 * min(1, max(0, fraction))))
        let origin = (Int(side) - n) / 2, stride = n * 4
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bitmapFormat: .alphaNonpremultiplied, bytesPerRow: stride, bitsPerPixel: 32),
              let dst = rep.bitmapData else { return nil }
        var bytes = [UInt8](repeating: 0, count: stride * n)
        bytes.withUnsafeMutableBytes { glReadPixels(GLint(origin), GLint(origin), GLsizei(n), GLsizei(n), GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), $0.baseAddress) }
        bytes.withUnsafeBytes { src in
            for y in 0..<n { memcpy(dst.advanced(by: y * stride), src.baseAddress!.advanced(by: (n - 1 - y) * stride), stride) }
        }
        rep.size = NSSize(width: 120, height: 120)
        let image = NSImage(size: rep.size); image.addRepresentation(rep); return image
    }
    deinit {
        let previous = NSOpenGLContext.current
        renderer.openGLContext?.makeCurrentContext()
        glDeleteFramebuffers(1, &framebuffer); glDeleteTextures(1, &color); renderer.disposePreview()
        if let previous, previous !== renderer.openGLContext { previous.makeCurrentContext() } else { NSOpenGLContext.clearCurrentContext() }
    }
}

final class PreviewImageView: NSImageView {
    let state: Model
    private var engine: PreviewRenderer?
    private var timer: Timer?
    private var observations: [NSObjectProtocol] = []
    private var lastFrame = 0.0
    private var dirty = true, attempted = false
    private(set) var frameCount = 0
    var isAnimating: Bool { timer != nil }
    static let period = 1.0 / 15.0
    init(state: Model) {
        self.state = state; super.init(frame: .zero)
        imageScaling = .scaleProportionallyUpOrDown; setAccessibilityLabel("黑洞实时预览，不读取桌面")
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); detach()
        guard let window else { return }
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didDeminiaturizeNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didMiniaturizeNotification] {
            observations.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in self?.refreshVisibility() })
        }
        observations.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in self?.stop() })
        refreshVisibility()
    }
    private var visible: Bool {
        guard let w = window else { return false }
        return w.isVisible && !w.isMiniaturized && w.occlusionState.contains(.visible) && !isHiddenOrHasHiddenAncestor
    }
    func modelChanged() { dirty = true; refreshVisibility() }
    func refreshVisibility() {
        guard visible else { stop(); return }
        guard timer == nil, !attempted || engine != nil else { return }
        // Coalesce model changes even while paused; a single tick renders the edited frame and then sleeps.
        let next = Timer(timeInterval: Self.period, repeats: true) { [weak self] _ in self?.tick() }
        next.tolerance = 0.003; timer = next; RunLoop.main.add(next, forMode: .common)
    }
    private func tick() {
        guard visible else { stop(); return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastFrame >= Self.period - 0.0005 else { return }
        if !state.paused || dirty { render(dt: lastFrame == 0 ? 0 : min(0.12, now - lastFrame)); lastFrame = now }
        if state.paused || engine == nil { timer?.invalidate(); timer = nil }
    }
    private func render(dt: Double) {
        if !attempted { attempted = true; engine = PreviewRenderer(state: state) }
        if let frame = engine?.frame(dt: dt) { image = frame; frameCount += 1 }
        else if image == nil { image = Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap(NSImage.init(contentsOf:)); setAccessibilityLabel("黑洞预览不可用") }
        dirty = false
    }
    private func stop() {
        timer?.invalidate(); timer = nil; engine = nil; attempted = false; lastFrame = 0; dirty = true
    }
    func detach() {
        observations.forEach(NotificationCenter.default.removeObserver); observations.removeAll(); stop()
    }
    #if SELF_TEST
    func renderStillForQA() { render(dt: 0) }
    #endif
    deinit { detach() }
}

struct LivePreview: NSViewRepresentable {
    @ObservedObject var state: Model
    func makeNSView(context: Context) -> PreviewImageView { PreviewImageView(state: state) }
    func updateNSView(_ view: PreviewImageView, context: Context) { view.modelChanged() }
    static func dismantleNSView(_ view: PreviewImageView, coordinator: ()) { view.detach() }
}
