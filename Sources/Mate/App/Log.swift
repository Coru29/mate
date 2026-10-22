import Foundation
import os

/// Unified logging (subsystem io.github.coru29.Mate).
enum Log {
    private static let logger = Logger(subsystem: "io.github.coru29.Mate", category: "app")

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}
