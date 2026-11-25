import Foundation
import Darwin

/// Small append-only lifecycle log. One instance can be used from multiple capture callbacks.
final class CaptureLog {
    private let file: URL
    private let limit: UInt64
    private let formatter = ISO8601DateFormatter()
    private let lock = NSLock()
    init(directory: URL, limit: UInt64 = 65_536) {
        file = directory.appendingPathComponent("capture.log"); self.limit = limit
    }
    private func handle() throws -> FileHandle {
        let fd = open(file.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            try? handle.close(); throw CocoaError(.fileWriteNoPermission)
        }
        return handle
    }
    func append(_ metadata: String, at time: Date = Date()) throws {
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let line = Data("\(formatter.string(from: time)) \(metadata)\n".utf8)
        var stream = try handle()
        defer { try? stream.close() }
        let size = try stream.seekToEnd()
        if size > 0 && size + UInt64(line.count) > limit {
            // rename atomically replaces at most one prior generation; never truncate the current file on failure.
            guard rename(file.path, file.appendingPathExtension("1").path) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            try stream.close(); stream = try handle()
        }
        try stream.write(contentsOf: line)
    }
}
