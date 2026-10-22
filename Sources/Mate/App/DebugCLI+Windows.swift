import AppKit

/// Screenshots of Mate's own windows for UI checks: `--snapshot-settings <dir>` writes settings-<page>.png for every
/// settings page; `--snapshot-welcome <dir>` writes welcome-<step>.png for every welcome step (the guide opens even
/// when already seen), then finishes it and writes notch-hint.png of the panel with its hint.
extension DebugCLI {
    static var forceWelcome: Bool { CommandLine.arguments.contains("--snapshot-welcome") }

    private static func dir(after flag: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func scheduleWindowSnapshots(notch: NotchController) {
        let step = 1.4
        if let dir = dir(after: "--snapshot-settings") {
            for (i, section) in SettingsSection.allCases.enumerated() {
                let t = 2.0 + Double(i) * step
                DispatchQueue.main.asyncAfter(deadline: .now() + t) { SettingsWindowController.shared.show(section: section) }
                DispatchQueue.main.asyncAfter(deadline: .now() + t + 1) {
                    captureWindow(SettingsWindowController.shared.debugWindowNumber, to: "\(dir)/settings-\(section.rawValue).png")
                }
            }
        }
        if let dir = dir(after: "--snapshot-welcome") {
            let pages = WelcomePage.allCases
            for (i, page) in pages.enumerated() {
                let t = 1.5 + Double(i) * step
                DispatchQueue.main.asyncAfter(deadline: .now() + t) { WelcomeWindowController.shared.model?.debugGo(to: page) }
                DispatchQueue.main.asyncAfter(deadline: .now() + t + 1) {
                    captureWindow(WelcomeWindowController.shared.debugWindowNumber, to: "\(dir)/welcome-\(i + 1)-\(page).png")
                }
            }
            let end = 1.5 + Double(pages.count) * step
            DispatchQueue.main.asyncAfter(deadline: .now() + end) { WelcomeWindowController.shared.model?.advance() }
            DispatchQueue.main.asyncAfter(deadline: .now() + end + 1.5) { snapshot(notch.debugView, to: "\(dir)/notch-hint.png") }
        }
    }

    /// The window's own pixels (SwiftUI text does not survive `cacheDisplay`).
    static func captureWindow(_ number: Int?, to path: String) {
        guard let number,
              let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(number), .boundsIgnoreFraming),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            Log.error("snapshot \(path): no window")
            return
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            Log.info("snapshot \(path)")
        } catch {
            Log.error("snapshot \(path): \(error)")
        }
    }
}
