import Foundation
import OpenGL.GL3

/// The caller owns a program only after both shaders have compiled and the program has linked.
enum GLProgram {
    enum Failure: Error, CustomStringConvertible {
        case resource(String), compile(String), link(String)
        var description: String {
            switch self {
            case .resource(let name): return "missing or unreadable resource: \(name)"
            case .compile(let info): return "compile: \(info)"
            case .link(let info): return "link: \(info)"
            }
        }
    }
    static func source(_ name: String, _ ext: String, in bundle: Bundle = .main) throws -> String {
        guard let url = bundle.url(forResource: name, withExtension: ext),
              let text = try? String(contentsOf: url, encoding: .utf8) else { throw Failure.resource("\(name).\(ext)") }
        return text
    }
    private static func compile(_ type: GLenum, _ text: String) throws -> GLuint {
        let shader = glCreateShader(type)
        guard shader != 0 else { throw Failure.compile("could not allocate shader") }
        text.withCString { var ptr: UnsafePointer<GLchar>? = $0; glShaderSource(shader, 1, &ptr, nil) }
        glCompileShader(shader)
        var ok: GLint = 0
        glGetShaderiv(shader, GLenum(GL_COMPILE_STATUS), &ok)
        guard ok != 0 else {
            var info = [GLchar](repeating: 0, count: 4096)
            glGetShaderInfoLog(shader, GLsizei(info.count), nil, &info)
            glDeleteShader(shader)
            throw Failure.compile(String(cString: info))
        }
        return shader
    }
    static func build(vertex: String, fragment: String, outputs: [String] = []) throws -> GLuint {
        let vert = try compile(GLenum(GL_VERTEX_SHADER), vertex)
        defer { glDeleteShader(vert) }
        let frag = try compile(GLenum(GL_FRAGMENT_SHADER), fragment)
        defer { glDeleteShader(frag) }
        let program = glCreateProgram()
        guard program != 0 else { throw Failure.link("could not allocate program") }
        glAttachShader(program, vert); glAttachShader(program, frag)
        for (index, name) in outputs.enumerated() { glBindFragDataLocation(program, GLuint(index), name) }
        glLinkProgram(program)
        var ok: GLint = 0
        glGetProgramiv(program, GLenum(GL_LINK_STATUS), &ok)
        guard ok != 0 else {
            var info = [GLchar](repeating: 0, count: 4096)
            glGetProgramInfoLog(program, GLsizei(info.count), nil, &info)
            glDeleteProgram(program)
            throw Failure.link(String(cString: info))
        }
        return program
    }
}
