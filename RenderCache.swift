import OpenGL.GL3

/// Stores only ray geometry, never desktop pixels or animated disk light.
final class LensGeometryCache {
    let program: GLuint
    private var framebuffer: GLuint = 0
    private var textures = [GLuint](repeating: 0, count: 3)
    private var width: GLsizei = 0
    private var height: GLsizei = 0
    private var signature: [Float]?
    private(set) var rebuilds = 0
    private(set) var available = true

    init(program: GLuint) { self.program = program; available = program != 0 }

    func prepare(width: GLsizei, height: GLsizei, signature: [Float],
                 configure: (GLuint) -> Void) -> Bool {
        guard available else { return false }
        if self.width == width && self.height == height && self.signature == signature { return true }
        var previous: GLint = 0
        glGetIntegerv(GLenum(GL_FRAMEBUFFER_BINDING), &previous)
        defer { glBindFramebuffer(GLenum(GL_FRAMEBUFFER), GLuint(previous)) }
        if framebuffer == 0 { glGenFramebuffers(1, &framebuffer) }
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffer)
        if self.width != width || self.height != height {
            glDeleteTextures(3, &textures)
            glGenTextures(3, &textures)
            glActiveTexture(GLenum(GL_TEXTURE2))
            for i in textures.indices {
                glBindTexture(GLenum(GL_TEXTURE_2D), textures[i])
                glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GL_NEAREST)
                glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GL_NEAREST)
                glTexImage2D(GLenum(GL_TEXTURE_2D), 0, GL_RGBA32F, width, height, 0,
                             GLenum(GL_RGBA), GLenum(GL_FLOAT), nil)
                glFramebufferTexture2D(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0) + GLenum(i),
                                       GLenum(GL_TEXTURE_2D), textures[i], 0)
            }
            let buffers = (0..<3).map { GLenum(GL_COLOR_ATTACHMENT0) + GLenum($0) }
            glDrawBuffers(3, buffers)
            guard glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER)) == GL_FRAMEBUFFER_COMPLETE else {
                available = false
                release()
                log("GEOMETRY_CACHE_UNAVAILABLE")
                return false
            }
            self.width = width; self.height = height
        }
        glViewport(0, 0, width, height)
        glUseProgram(program)
        configure(program)
        glDrawArrays(GLenum(GL_TRIANGLES), 0, 3)
        self.signature = signature
        rebuilds += 1
        if rebuilds == 1 { log("GEOMETRY_CACHE_ACTIVE \(width)x\(height)") }
        return true
    }

    func bind() {
        for i in textures.indices {
            glActiveTexture(GLenum(GL_TEXTURE2) + GLenum(i))
            glBindTexture(GLenum(GL_TEXTURE_2D), textures[i])
        }
        glActiveTexture(GLenum(GL_TEXTURE0))
    }

    func release() {
        glDeleteTextures(3, &textures)
        textures = [GLuint](repeating: 0, count: 3)
        if framebuffer != 0 { glDeleteFramebuffers(1, &framebuffer) }
        framebuffer = 0; width = 0; height = 0; signature = nil
    }
}
