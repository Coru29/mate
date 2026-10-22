import Foundation
import MateCore

/// Runs `/usr/bin/security` synchronously. Secrets travel only through stdin and the stdout pipe, never argv, and
/// nothing they carry is logged. Waits on a semaphore, not the run loop, so a caller on the main thread is not
/// re-entered while it waits.
enum SecurityTool {
    struct Result {
        let status: Int32
        let output: Data
    }

    static func run(_ arguments: [String], input: Data? = nil, timeout: TimeInterval) throws -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: SecurityCommand.path)
        p.arguments = arguments
        let out = Pipe()
        let stdin = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = input == nil ? FileHandle.nullDevice : stdin
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        try p.run()

        var output = Data()
        let reader = DispatchGroup()
        reader.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            output = out.fileHandleForReading.readDataToEndOfFile()
            reader.leave()
        }
        if let input {
            let w = stdin.fileHandleForWriting
            // If `security` exits before reading, the write fails with EPIPE instead of a SIGPIPE killing Mate.
            _ = fcntl(w.fileDescriptor, F_SETNOSIGPIPE, 1)
            try? w.write(contentsOf: input)
            try? w.close()
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            exited.wait()
            reader.wait()
            throw KeychainError.timedOut
        }
        reader.wait()
        return Result(status: p.terminationStatus, output: output)
    }
}
