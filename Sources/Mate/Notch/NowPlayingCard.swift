import SwiftUI
import MateCore

/// The open panel's now-playing card, above the accounts: album art, title and artist with the equalizer bars; the
/// elapsed time, a progress bar (click or drag to seek, applied on release) and the remaining time; then previous,
/// play/pause, next and shuffle. When the player refused Automatización, the controls give way to how to allow it.
struct NowPlayingCard: View {
    @ObservedObject var center: NowPlayingCenter
    /// Re-renders the times once a second while playing (see `NowPlayingClock`).
    @ObservedObject var clock: NowPlayingClock
    /// The seek position while the bar is dragged (0…1).
    @State private var drag: Double?

    static let artSize: CGFloat = 46
    static let width = NotchController.panelWidth - 40

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let np = center.current {
                header(np)
                if center.denied {
                    deniedRow(np.player)
                } else {
                    if let duration = np.duration { progress(np, duration: duration) }
                    controls(np)
                }
                Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1).padding(.top, 2)
            }
        }
        .frame(width: Self.width, alignment: .topLeading)
        .environment(\.colorScheme, .dark)
    }

    private func header(_ np: NowPlaying) -> some View {
        HStack(spacing: 12) {
            Group {
                if let art = center.artwork {
                    Image(decorative: art, scale: 2).resizable().aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Color.white.opacity(0.1)
                        Image(systemName: "music.note")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(NotchPalette.muted)
                    }
                }
            }
            .frame(width: Self.artSize, height: Self.artSize)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: np.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(NotchPalette.onNotch)
                Text(verbatim: np.artist.isEmpty ? np.album : np.artist)
                    .font(.system(size: 12.5))
                    .foregroundStyle(NotchPalette.muted)
            }
            .lineLimit(1)
            .truncationMode(.tail)
            Spacer(minLength: 8)
            Equalizer(playing: np.state == .playing, color: NSColor(NotchPalette.onNotch))
                .frame(width: 10, height: 14)
        }
    }

    private func progress(_ np: NowPlaying, duration: TimeInterval) -> some View {
        let now = Date()
        let live = np.progress(at: now) ?? 0
        let fraction = drag ?? live
        let elapsed = drag.map { $0 * duration } ?? np.elapsed(at: now) ?? 0
        return HStack(spacing: 10) {
            Text(verbatim: NowPlayingText.time(elapsed))
                .frame(minWidth: 34, alignment: .leading)
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.16))
                    Capsule().fill(NotchPalette.onNotch).frame(width: max(0, min(w, w * fraction)))
                }
                .frame(height: drag == nil ? 4 : 6)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in drag = min(max(v.location.x / max(w, 1), 0), 1) }
                    .onEnded { v in
                        let f = min(max(v.location.x / max(w, 1), 0), 1)
                        center.perform(.seek(f * duration))
                        drag = nil
                    })
            }
            .frame(height: 14)
            Text(verbatim: NowPlayingText.remaining(max(0, duration - elapsed)))
                .frame(minWidth: 38, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .medium).monospacedDigit())
        .foregroundStyle(NotchPalette.muted)
    }

    private func controls(_ np: NowPlaying) -> some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            button("backward.fill", size: 15, help: Text("Anterior")) { center.perform(.previous) }
            Spacer(minLength: 0)
            button(np.state == .playing ? "pause.fill" : "play.fill", size: 21,
                   help: np.state == .playing ? Text("Pausar") : Text("Reproducir")) { center.perform(.playPause) }
            Spacer(minLength: 0)
            button("forward.fill", size: 15, help: Text("Siguiente")) { center.perform(.next) }
            Spacer(minLength: 0)
            button("shuffle", size: 14, help: Text("Aleatorio"),
                   color: np.shuffle == true ? Tone.ok.color : NotchPalette.muted) {
                center.perform(.shuffle(!(np.shuffle ?? false)))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
    }

    private func button(_ symbol: String, size: CGFloat, help: Text, color: Color = NotchPalette.onNotch,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 34, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func deniedRow(_ player: MusicPlayer) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Permití a Mate controlar \(player.displayName) en Ajustes del Sistema → Privacidad → Automatización")
                .font(.system(size: 12))
                .foregroundStyle(NotchPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button { center.openAutomationSettings() } label: { Text("Abrir Ajustes") }
                Button { center.retryPermission() } label: { Text("Reintentar") }
            }
            .controlSize(.small)
        }
    }
}

extension MusicPlayer {
    /// The player's name as macOS shows it.
    var displayName: String {
        switch self {
        case .spotify: "Spotify"
        case .music: String(localized: "Música")
        }
    }
}
