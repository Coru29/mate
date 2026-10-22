import Foundation

public struct FileCursor: Codable, Sendable {
    public var inode: UInt64
    public var offset: UInt64
    /// Bytes after the last newline read so far (an unfinished line).
    public var pending: Data

    public init(inode: UInt64, offset: UInt64, pending: Data) {
        self.inode = inode
        self.offset = offset
        self.pending = pending
    }
}

/// Reads only the bytes appended since the last call and returns complete lines.
public enum IncrementalReader {
    /// An unfinished line longer than this is dropped; the garbage tail that follows fails JSON parsing and is ignored.
    static let maxPending = 1_048_576

    public static func read(url: URL, cursor: FileCursor?) throws -> (lines: [Data], cursor: FileCursor) {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0

        var start: UInt64 = 0
        var pending = Data()
        if let c = cursor, c.inode == inode, size >= c.offset {
            start = c.offset
            pending = c.pending
        }

        var chunk = Data()
        if size > start {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: start)
            chunk = try handle.readToEnd() ?? Data()
        }
        let newOffset = start + UInt64(chunk.count)

        var buffer = pending
        buffer.append(chunk)
        var lines: [Data] = []
        var lineStart = buffer.startIndex
        while let nl = buffer[lineStart...].firstIndex(of: 0x0A) {
            let line = buffer[lineStart..<nl]
            if !line.isEmpty { lines.append(Data(line)) }
            lineStart = buffer.index(after: nl)
        }
        var rest = Data(buffer[lineStart...])
        if rest.count > maxPending { rest = Data() }
        return (lines, FileCursor(inode: inode, offset: newOffset, pending: rest))
    }
}
