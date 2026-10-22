import AppKit
import SwiftUI
import MateCore

/// Colors of the notch UI, shared with the website's demo.
enum NotchPalette {
    static let onNotch = Color(red: 0xf1 / 255, green: 0xf3 / 255, blue: 0xea / 255)
    static let muted = Color(red: 0xa9 / 255, green: 0xb0 / 255, blue: 0xa1 / 255)
    static let accountColors: [NSColor] = [
        NSColor(srgbRed: 0x6f / 255, green: 0xd0 / 255, blue: 0x8a / 255, alpha: 1),
        NSColor(srgbRed: 0x7a / 255, green: 0xa7 / 255, blue: 0xff / 255, alpha: 1),
        NSColor(srgbRed: 0xf3 / 255, green: 0xb4 / 255, blue: 0x43 / 255, alpha: 1),
        NSColor(srgbRed: 0xc5 / 255, green: 0x8c / 255, blue: 0xff / 255, alpha: 1),
        NSColor(srgbRed: 0xff / 255, green: 0x8a / 255, blue: 0x65 / 255, alpha: 1),
        NSColor(srgbRed: 0x4d / 255, green: 0xd0 / 255, blue: 0xe1 / 255, alpha: 1),
    ]

    static func accountColor(_ index: Int) -> NSColor {
        accountColors[((index % accountColors.count) + accountColors.count) % accountColors.count]
    }
}

/// Pace state as a color: green on track, amber ahead, red when it runs out or is at the limit.
enum Tone {
    case ok, warn, hot

    init(_ pace: PaceState?) {
        switch pace {
        case .ahead: self = .warn
        case .runsOut, .limitReached: self = .hot
        case .onTrack, nil: self = .ok
        }
    }

    var nsColor: NSColor {
        switch self {
        case .ok: NSColor(srgbRed: 0x3c / 255, green: 0xcf / 255, blue: 0x7a / 255, alpha: 1)
        case .warn: NSColor(srgbRed: 0xf3 / 255, green: 0xb4 / 255, blue: 0x43 / 255, alpha: 1)
        case .hot: NSColor(srgbRed: 0xff / 255, green: 0x6b / 255, blue: 0x5d / 255, alpha: 1)
        }
    }

    var color: Color { Color(nsColor: nsColor) }
}

/// One limit window: label and percent, a bar, the reset and the pace.
struct Meter: View {
    let window: LimitWindow
    let pace: PaceState?
    let now: Date

    var body: some View {
        let tone = Tone(pace)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: NotchText.windowLabel(window.kind))
                    .font(.system(size: 12.5))
                    .foregroundStyle(NotchPalette.muted)
                Spacer(minLength: 8)
                Text(verbatim: NotchText.percent(window.usedPercent))
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(NotchPalette.onNotch)
            }
            Capsule()
                .fill(Color.white.opacity(0.12))
                .frame(height: 6)
                .overlay(alignment: .leading) {
                    GeometryReader { geo in
                        Capsule()
                            .fill(tone.color)
                            .frame(width: geo.size.width * min(max(window.usedPercent, 0), 100) / 100)
                    }
                }
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: footnote)
                    .foregroundStyle(NotchPalette.muted)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let text = NotchText.pace(pace) {
                    Text(verbatim: text)
                        .fontWeight(.semibold)
                        .foregroundStyle(tone.color)
                        .lineLimit(1)
                }
            }
            .font(.system(size: 12))
        }
    }

    private var footnote: String {
        [NotchText.reset(window.resetsAt, now: now), window.detail].compactMap { $0 }.joined(separator: " · ")
    }
}
