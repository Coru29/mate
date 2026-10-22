import AppKit
import MateCore
import UserNotifications

/// Alerts that drop from the notch: a queue of one-line texts, the view that shows one, and the optional system
/// notification. The controller animates the shape and times the 4 s.
@MainActor
final class AlertBanner {
    struct Item: Equatable {
        /// What a click on the alert does.
        enum Action: Equatable { case openPanel, installUpdate }

        var text: String
        var tone: Tone
        var action: Action = .openPanel
    }

    static let visibleFor: TimeInterval = 4
    static let width: CGFloat = 360
    static let lineHeight: CGFloat = 40

    private(set) var queue: [Item] = []

    func enqueue(_ item: Item) { queue.append(item) }

    func next() -> Item? { queue.isEmpty ? nil : queue.removeFirst() }

    func makeView(_ item: Item) -> NSView { AlertBannerView(item: item) }

    // MARK: System notifications

    /// `UNUserNotificationCenter` needs an app bundle: only the installed `.app` uses it (not `swift run`).
    static var canNotify: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier == Preferences.suiteName
    }

    /// Called when the option is turned on: the only moment Mate asks for permission.
    static func requestPermission() {
        guard canNotify else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error { Log.error("notifications: \(error.localizedDescription)") }
            Log.info("notifications \(granted ? "allowed" : "not allowed")")
        }
    }

    static func post(_ text: String) {
        guard canNotify else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = "Mate"
            content.body = text
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}

/// One line under the notch: a tone dot and the text.
private final class AlertBannerView: NSView {
    init(item: AlertBanner.Item) {
        super.init(frame: .zero)
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = item.tone.nsColor.cgColor
        dot.layer?.cornerRadius = 4
        let label = NSTextField(labelWithString: item.text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = NSColor(srgbRed: 0xf1 / 255, green: 0xf3 / 255, blue: 0xea / 255, alpha: 1)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for v in [dot, label] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 10),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // Clicks go to the shape view, which opens the panel.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
