#if SELF_TEST
import Cocoa
import Carbon.HIToolbox
import ScreenCaptureKit
import CoreMedia

/// A real, self-owned window. Never enumerate desktop content or request capture permission.
private final class OwnedFrames: NSObject, SCStreamOutput {
    private let lock = NSLock()
    private var last: CVPixelBuffer?
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
        lock.lock(); last = buffer; lock.unlock()
    }
    func take() -> CVPixelBuffer? { lock.lock(); defer { lock.unlock() }; return last }
}

enum NativeInteractionQA {
    private static func require(_ pass: Bool, _ label: String) { NativeSelfTest.require(pass, label) }

    @MainActor static func shortcuts() {
        var received = [PetShortcut]()
        let manager = GlobalShortcuts { received.append($0) }
        let keys = manager.start()
        defer { manager.stop() }
        require(keys == Set(PetShortcut.allCases), "test machine has both configured hot keys available")
        func send(_ action: PetShortcut, signature: OSType = GlobalShortcuts.signature) {
            var event: EventRef?
            require(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0, 0, &event) == noErr, "create local Carbon event")
            guard let event else { return }; defer { ReleaseEvent(event) }
            var id = EventHotKeyID(signature: signature, id: action.rawValue)
            require(SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &id) == noErr, "local hotkey id")
            // Not a system-wide key press; deliver only to this QA process's installed Carbon handler.
            _ = SendEventToEventTarget(event, GetApplicationEventTarget())
        }
        let competing = GlobalShortcuts { _ in fatalError("unregistered combination") }
        require(competing.start().isEmpty, "conflicting registrations do not replace active shortcuts")
        competing.stop()
        send(.visibility); send(.pause); send(.pause, signature: 0)
        require(received == [.visibility, .pause], "exact registered combinations routed; unrelated id ignored")
        manager.stop(); send(.pause)
        require(received.count == 2, "teardown unregisters events")
        require(manager.start() == keys, "hotkeys can be registered again after teardown")
        log("HOTKEY_QA_PASS two system registrations, scoped Carbon delivery, foreign id, teardown and re-registration")
    }

    @MainActor static func run(_ app: AppDelegate) async {
        shortcuts()
        let state = Model(defaults: nil)
        let fixture = NSPanel(contentRect: NSRect(x: 100, y: 100, width: 300, height: 134), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        fixture.title = "奇点 QA · 合成色块"; fixture.isOpaque = true; fixture.hasShadow = false
        fixture.hidesOnDeactivate = false; fixture.isReleasedWhenClosed = false
        fixture.backgroundColor = .red; fixture.level = .floating
        let canvas = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 134))
        let preview = PreviewImageView(state: state); preview.frame = NSRect(x: 4, y: 7, width: 120, height: 120)
        canvas.addSubview(preview); fixture.contentView = canvas; fixture.orderFrontRegardless()
        defer { fixture.orderOut(nil); fixture.close(); preview.detach() }
        for _ in 0..<40 where preview.frameCount == 0 { try? await Task.sleep(nanoseconds: 50_000_000) }
        require(preview.frameCount > 0 && preview.isAnimating, "visible preview runs")
        let start = ProcessInfo.processInfo.systemUptime, first = preview.frameCount
        try? await Task.sleep(nanoseconds: 520_000_000)
        let elapsed = ProcessInfo.processInfo.systemUptime - start, frames = preview.frameCount - first
        require(frames > 0 && Double(frames) <= ceil(elapsed * 15) + 1, "preview capped at 15 fps")
        state.paused = true; preview.modelChanged(); try? await Task.sleep(nanoseconds: 220_000_000)
        require(!preview.isAnimating, "paused preview stops its timer")
        let still = preview.image?.tiffRepresentation
        state.style = 1; state.brightness = 1; preview.modelChanged(); try? await Task.sleep(nanoseconds: 200_000_000)
        require(preview.image?.tiffRepresentation != still, "paused preview updates real appearance")
        let original = state.size, previous = preview.image?.tiffRepresentation
        state.size = 700; preview.modelChanged(); try? await Task.sleep(nanoseconds: 200_000_000)
        require(preview.image?.tiffRepresentation != previous, "size changes the visible black hole")
        state.size = original; state.bodyCount = 3; preview.modelChanged(); try? await Task.sleep(nanoseconds: 200_000_000)
        require(preview.image != nil && !state.capturing, "multi-body preview uses no screen")
        fixture.orderOut(nil); try? await Task.sleep(nanoseconds: 100_000_000)
        let hidden = preview.frameCount; state.paused = false; preview.modelChanged(); try? await Task.sleep(nanoseconds: 220_000_000)
        require(!preview.isAnimating && preview.frameCount == hidden, "hidden window creates no preview frames or timer")
        fixture.orderFrontRegardless(); try? await Task.sleep(nanoseconds: 280_000_000)
        require(preview.frameCount > hidden, "reshown window resumes the preview")
        log("PREVIEW_QA_PASS visible=\(frames) interval=\(elapsed) paused-edit size multibody hidden-zero resume")

        let before = app.view.diskPhase
        model.reduceMotion = true; model.paused = false; model.wander = true
        app.view.advanceAnimation(dt: 0.1)
        let slow = app.view.diskPhase - before
        model.reduceMotion = false; let at = app.view.diskPhase
        app.view.advanceAnimation(dt: 0.1)
        require(slow > 0 && slow < (app.view.diskPhase - at) * 0.6 && model.effectiveWander, "renderer respects motion policy without overwriting preferences")
        let location = CGPoint(x: app.view.bounds.midX, y: app.view.bounds.midY)
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: 0, windowNumber: app.pet.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [], timestamp: 0, windowNumber: app.pet.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0)!
        app.view.mouseDown(with: down); require(app.view.dragging && NSCursor.current == .closedHand, "closed hand while dragging")
        app.view.mouseUp(with: up); require(!app.view.dragging && NSCursor.current == .openHand, "open hand on release")
        NSCursor.arrow.set()
        log("MOTION_CURSOR_QA_PASS actual shader phase and AppKit hand cursors")
        if #available(macOS 14.4, *) { await ownWindowCapture(fixture) }
        log("INTERACTION_QA_PASS")
    }

    @available(macOS 14.4, *) @MainActor private static func ownWindowCapture(_ window: NSWindow) async {
        do {
            let content = try await SCShareableContent.currentProcess
            guard let owned = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) && $0.owningApplication?.processID == getpid() }) else {
                log("OWN_WINDOW_CAPTURE_UNAVAILABLE no consent-free self-owned source"); return
            }
            let filter = SCContentFilter(desktopIndependentWindow: owned)
            let config = SCStreamConfiguration(); config.width = 300; config.height = 134
            config.pixelFormat = kCVPixelFormatType_32BGRA; config.showsCursor = false; config.capturesAudio = false; config.ignoreShadowsSingleWindow = true
            config.minimumFrameInterval = CMTime(value: 1, timescale: 15)
            func isColor(_ buffer: CVPixelBuffer?, red: Bool) -> Bool {
                guard let b = buffer, CVPixelBufferLockBaseAddress(b, .readOnly) == kCVReturnSuccess else { return false }
                defer { CVPixelBufferUnlockBaseAddress(b, .readOnly) }
                guard let p = CVPixelBufferGetBaseAddress(b)?.assumingMemoryBound(to: UInt8.self) else { return false }
                let i = CVPixelBufferGetHeight(b)/2 * CVPixelBufferGetBytesPerRow(b) + CVPixelBufferGetWidth(b)*3/4*4
                return red ? Int(p[i+2]) > Int(p[i+1])+80 : Int(p[i+1]) > Int(p[i+2])+80
            }
            for red in [true, false] {
                window.backgroundColor = red ? .red : .green; window.displayIfNeeded()
                let sink = OwnedFrames(), stream = SCStream(filter: filter, configuration: config, delegate: nil)
                try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: DispatchQueue(label: "qa.own-window"))
                try await stream.startCapture()
                for _ in 0..<40 where !isColor(sink.take(), red: red) { try await Task.sleep(nanoseconds: 50_000_000) }
                let correct = isColor(sink.take(), red: red); try await stream.stopCapture()
                require(correct, "real ScreenCaptureKit stream delivered only owned fixture color")
                let sample = try await SCScreenshotManager.captureSampleBuffer(contentFilter: filter, configuration: config)
                require(isColor(CMSampleBufferGetImageBuffer(sample), red: red), "real ScreenCaptureKit snapshot delivered own window")
            }
            log("OWN_WINDOW_CAPTURE_PASS signed runtime, consent-free own window only, 2 streams/restarts and 2 snapshots; no pixels persisted")
        } catch { log("OWN_WINDOW_CAPTURE_UNAVAILABLE \((error as NSError).domain) \((error as NSError).code)") }
    }
}
#endif
