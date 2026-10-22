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
    /// Default upper bound of bytes read per call, so memory stays bounded on huge logs.
    public static let defaultChunk = 8 * 1_048_576

    /// Reads at most `maxChunk` new bytes. `atEnd` is false while more bytes remain: call again with the returned
    /// cursor.
    public static func read(url: URL, cursor: FileCursor?, maxChunk: Int = defaultChunk)
        throws -> (lines: [Data], cursor: FileCursor, atEnd: Bool) {
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
            chunk = try handle.read(upToCount: Int(min(UInt64(max(1, maxChunk)), size - start))) ?? Data()
        }
        let newOffset = start + UInt64(chunk.count)

        // Only the unfinished line from the last read is joined with the chunk: split the chunk at its first newline.
        var lines: [Data] = []
        var tailStart = chunk.startIndex
        if let firstNL = chunk.firstIndex(of: 0x0A) {
            var first = pending
            first.append(chunk[chunk.startIndex..<firstNL])
            if !first.isEmpty { lines.append(first) }
            var lineStart = chunk.index(after: firstNL)
            while let nl = chunk[lineStart...].firstIndex(of: 0x0A) {
                if nl > lineStart { lines.append(chunk.subdata(in: lineStart..<nl)) }
                lineStart = chunk.index(after: nl)
            }
            tailStart = lineStart
            pending = Data()
        }
        var rest = pending
        rest.append(chunk[tailStart...])
        if rest.count > maxPending { rest = Data() }
        return (lines, FileCursor(inode: inode, offset: newOffset, pending: rest), newOffset >= size)
    }
}
