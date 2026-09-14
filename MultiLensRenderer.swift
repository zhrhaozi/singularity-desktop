import Cocoa
import OpenGL.GL3

struct LensBodyPass {
    let index: Int
    let viewport: CGRect
    let sceneRect: CGRect
    let sceneTexture: GLuint
    let geometry: LensGeometryCache
    let encounter: Float
    let impact: Float
}

struct LensDesktop {
    let texture: GLuint
    let surface: GLuint
    let usesSurface: Bool
    let available: Bool
    let rect: CGRect
}

/// Far-to-near compositing uses one desktop image and two reusable scene textures.
/// Each body retains local ray geometry independently of its screen-space motion.
final class MultiLensRenderer {
    private var program: GLuint = 0
    private var framebuffer: GLuint = 0
    private var textures = [GLuint](repeating: 0, count: 2)
    private var dimensions = CGSize.zero
    private var locations = [String: GLint]()
    private var caches = [LensGeometryCache]()
    private(set) var frames = 0
    private(set) var allocations = 0
    private(set) var available = true
    var stacksLensing = true
    var cacheRebuilds: Int { caches.reduce(0) { $0 + $1.rebuilds } }
    var hasResources: Bool { framebuffer != 0 }

    static func rect(for body: OrbitalBody) -> CGRect {
        let diameter = min(0.64, max(0.35, body.radius * 1.35))
        let positionScale = body.radius > 0.4 ? 0.64 : 0.74
        // Coordinates are top-down here, matching captured desktop pixels.
        return CGRect(x: 0.5 + body.position.x * positionScale - diameter / 2,
                      y: 0.5 - body.position.y * positionScale - diameter / 2,
                      width: diameter, height: diameter)
    }

    func release() {
        caches.forEach { $0.release() }
        glDeleteTextures(2, &textures)
        textures = [0, 0]
        if framebuffer != 0 { glDeleteFramebuffers(1, &framebuffer) }
        framebuffer = 0
        dimensions = .zero
    }

    private func prepare(width: GLsizei, height: GLsizei, geometryProgram: GLuint) -> Bool {
        guard available, width > 0, height > 0 else { return false }
        if program == 0 {
            let vertex = """
            #version 150
            void main() {
                vec2 p=vec2((gl_VertexID<<1)&2,gl_VertexID&2);
                gl_Position=vec4(p*2.0-1.0,0.0,1.0);
            }
            """
            guard let url = Bundle.main.url(forResource: "multilens", withExtension: "frag"),
                  let fragment = try? String(contentsOf: url, encoding: .utf8) else {
                available = false; log("MULTILENS_SHADER_MISSING"); return false
            }
            var shaders = [GLuint]()
            for (kind, text) in [(GLenum(GL_VERTEX_SHADER), vertex), (GLenum(GL_FRAGMENT_SHADER), fragment)] {
                let shader = glCreateShader(kind)
                text.withCString { pointer in
                    var source: UnsafePointer<GLchar>? = pointer
                    glShaderSource(shader, 1, &source, nil)
                }
                glCompileShader(shader)
                var success: GLint = 0
                glGetShaderiv(shader, GLenum(GL_COMPILE_STATUS), &success)
                shaders.append(shader)
                if success == 0 {
                    var message = [GLchar](repeating: 0, count: 4096)
                    glGetShaderInfoLog(shader, 4096, nil, &message)
                    log("MULTILENS_SHADER_ERROR \(String(cString: message))")
                    shaders.forEach { glDeleteShader($0) }
                    available = false; return false
                }
            }
            program = glCreateProgram()
            shaders.forEach { glAttachShader(program, $0) }
            glLinkProgram(program)
            shaders.forEach { glDeleteShader($0) }
            var linked: GLint = 0
            glGetProgramiv(program, GLenum(GL_LINK_STATUS), &linked)
            guard linked == 1 else {
                glDeleteProgram(program); program = 0; available = false
                log("MULTILENS_LINK_FAILED"); return false
            }
            for name in ["mode", "scene", "desktop", "desktopSurface", "useDesktopSurface",
                         "hasCapture", "resolution", "captureRect", "bodyCount", "bodyRects[0]"] {
                locations[name] = glGetUniformLocation(program, name)
            }
            caches = (0..<3).map { _ in LensGeometryCache(program: geometryProgram) }
        }
        let size = CGSize(width: Int(width), height: Int(height))
        if size != dimensions {
            release()
            glGenFramebuffers(1, &framebuffer)
            glGenTextures(2, &textures)
            for texture in textures {
                glBindTexture(GLenum(GL_TEXTURE_2D), texture)
                glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GL_LINEAR)
                glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GL_LINEAR)
                glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GL_CLAMP_TO_EDGE)
                glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GL_CLAMP_TO_EDGE)
                glTexImage2D(GLenum(GL_TEXTURE_2D), 0, GL_RGBA8, width, height, 0,
                             GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), nil)
            }
            glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffer)
            glFramebufferTexture2D(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0),
                                   GLenum(GL_TEXTURE_2D), textures[0], 0)
            guard glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER)) == GL_FRAMEBUFFER_COMPLETE else {
                release(); available = false; log("MULTILENS_FRAMEBUFFER_FAILED"); return false
            }
            dimensions = size; allocations += 1
        }
        return true
    }

    func render(width: GLsizei, height: GLsizei, geometryProgram: GLuint,
                bodies: [OrbitalBody], desktop: LensDesktop, drawBody: (LensBodyPass) -> Void) -> Bool {
        var target: GLint = 0
        glGetIntegerv(GLenum(GL_FRAMEBUFFER_BINDING), &target)
        defer {
            glBindFramebuffer(GLenum(GL_FRAMEBUFFER), GLuint(target))
            glViewport(0, 0, width, height)
            glDisable(GLenum(GL_BLEND))
            glActiveTexture(GLenum(GL_TEXTURE0))
        }
        glActiveTexture(GLenum(GL_TEXTURE0))
        guard prepare(width: width, height: height, geometryProgram: geometryProgram) else { return false }
        let visible = Array(bodies.prefix(3))
        guard visible.count >= 2 else { return false }
        let rects = visible.map { Self.rect(for: $0) }
        func fullScreen(_ mode: GLint, _ scene: GLuint) {
            glViewport(0, 0, width, height)
            glDisable(GLenum(GL_BLEND))
            glUseProgram(program)
            glActiveTexture(GLenum(GL_TEXTURE0)); glBindTexture(GLenum(GL_TEXTURE_2D), scene)
            glActiveTexture(GLenum(GL_TEXTURE1)); glBindTexture(GLenum(GL_TEXTURE_2D), desktop.texture)
            glActiveTexture(GLenum(GL_TEXTURE2)); glBindTexture(GLenum(GL_TEXTURE_RECTANGLE), desktop.surface)
            glUniform1i(locations["mode"]!, mode)
            glUniform1i(locations["scene"]!, 0); glUniform1i(locations["desktop"]!, 1)
            glUniform1i(locations["desktopSurface"]!, 2)
            glUniform1i(locations["hasCapture"]!, desktop.available ? 1 : 0)
            glUniform1i(locations["useDesktopSurface"]!, desktop.usesSurface ? 1 : 0)
            glUniform2f(locations["resolution"]!, Float(width), Float(height))
            glUniform4f(locations["captureRect"]!, Float(desktop.rect.minX), Float(desktop.rect.minY),
                        Float(desktop.rect.width), Float(desktop.rect.height))
            glUniform1i(locations["bodyCount"]!, GLint(visible.count))
            let packed = rects.flatMap { [Float($0.minX), Float($0.minY), Float($0.width), Float($0.height)] }
            packed.withUnsafeBufferPointer { glUniform4fv(locations["bodyRects[0]"]!, GLsizei(rects.count), $0.baseAddress) }
            glDrawArrays(GLenum(GL_TRIANGLES), 0, 3)
        }
        func attach(_ index: Int) {
            glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffer)
            glFramebufferTexture2D(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0),
                                   GLenum(GL_TEXTURE_2D), textures[index], 0)
        }
        attach(0)
        fullScreen(0, desktop.texture)
        var previous = 0
        // Stable layer identities avoid discontinuous ordering swaps at close approaches.
        for (index, body) in visible.enumerated() {
            let next = 1 - previous
            attach(next)
            fullScreen(1, textures[previous])
            let rect = rects[index]
            let side = CGFloat(width) * rect.width
            let viewport = CGRect(x: (CGFloat(width) * rect.minX).rounded(),
                                  y: (CGFloat(height) * (1 - rect.maxY)).rounded(),
                                  width: side.rounded(), height: side.rounded())
            let actualRect = CGRect(x: viewport.minX / CGFloat(width),
                                    y: 1 - viewport.maxY / CGFloat(height),
                                    width: viewport.width / CGFloat(width), height: viewport.height / CGFloat(height))
            glEnable(GLenum(GL_BLEND))
            glBlendFunc(GLenum(GL_ONE), GLenum(GL_ONE_MINUS_SRC_ALPHA))
            drawBody(LensBodyPass(index: index, viewport: viewport, sceneRect: actualRect,
                                 sceneTexture: textures[previous], geometry: caches[index],
                                 encounter: Float(body.encounter), impact: Float(body.impact)))
            previous = next
        }
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), GLuint(target))
        fullScreen(2, textures[previous])
        frames += 1
        return true
    }
}
