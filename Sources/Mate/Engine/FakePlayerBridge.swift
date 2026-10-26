import AppKit
import MateCore

/// `--fake --fake-now-playing <fixture>`: a scripted player for snapshots and idle measurements. Never talks to the
/// real Spotify or Music. Fixtures: `none` (the default: nothing running), `playing`, `paused`, `shuffle` (playing
/// with shuffle on), `denied` (Spotify playing but Automatización denied), `music` (Music playing).
final class FakePlayerBridge: PlayerBridge, @unchecked Sendable {
    enum Fixture: String { case none, playing, paused, shuffle, denied, music }

    let fixture: Fixture
    private let lock = NSLock()
    private var state: PlaybackState
    private var shuffle: Bool
    private var position: TimeInterval = 66
    private var positionAt = Date()
    private var track = 0
    private static let tracks: [(id: String, title: String, artist: String, album: String, duration: TimeInterval)] = [
        ("fake:1", "Mate amargo", "Los Termos", "Yerba suave", 153),
        ("fake:2", "Bombilla de plata", "Los Termos", "Yerba suave", 201),
        ("fake:3", "Agua a 80 grados", "La Pava Eléctrica", "Cebador", 178),
    ]

    var player: MusicPlayer { fixture == .music ? .music : .spotify }

    static var fromArguments: FakePlayerBridge {
        let args = CommandLine.arguments
        let name = args.firstIndex(of: "--fake-now-playing").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        return FakePlayerBridge(fixture: name.flatMap(Fixture.init(rawValue:)) ?? .none)
    }

    init(fixture: Fixture) {
        self.fixture = fixture
        state = fixture == .paused ? .paused : .playing
        shuffle = fixture == .shuffle
    }

    /// The notification a real player would have posted (the denied fixture still shows its track from it).
    var initialNotification: [AnyHashable: Any]? {
        guard fixture == .denied else { return nil }
        let t = Self.tracks[0]
        return ["Player State": "Playing", "Track ID": t.id, "Name": t.title, "Artist": t.artist, "Album": t.album,
                "Duration": NSNumber(value: t.duration * 1000), "Playback Position": NSNumber(value: 66.0)]
    }

    func isRunning(_ p: MusicPlayer) -> Bool { fixture != .none && p == player }

    func access(_ p: MusicPlayer) -> PlayerAccess {
        guard isRunning(p) else { return .notRunning }
        return fixture == .denied ? .denied : .granted
    }

    func read(_ p: MusicPlayer) throws -> PlayerRead {
        guard isRunning(p) else { throw PlayerError.notRunning }
        guard fixture != .denied else { throw PlayerError.notPermitted }
        lock.lock()
        defer { lock.unlock() }
        let t = Self.tracks[track]
        return PlayerRead(readout: PlayerReadout(state: state, position: elapsed, shuffle: shuffle, trackID: t.id,
                                                 title: t.title, artist: t.artist, album: t.album,
                                                 duration: t.duration))
    }

    func artworkData(_ p: MusicPlayer) throws -> Data? {
        lock.lock()
        let i = track
        lock.unlock()
        return Self.artwork(i)
    }

    func send(_ p: MusicPlayer, _ command: PlayerCommand) throws {
        guard isRunning(p) else { throw PlayerError.notRunning }
        guard fixture != .denied else { throw PlayerError.notPermitted }
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        switch command {
        case .playPause:
            position = elapsed
            state = state == .playing ? .paused : .playing
        case .next:
            track = (track + 1) % Self.tracks.count
            position = 0
        case .previous:
            if elapsed < 3 { track = (track + Self.tracks.count - 1) % Self.tracks.count }
            position = 0
        case .seek(let s): position = s
        case .shuffle(let on): shuffle = on
        }
        positionAt = now
    }

    private var elapsed: TimeInterval {
        let t = position + (state == .playing ? Date().timeIntervalSince(positionAt) : 0)
        return min(t, Self.tracks[track].duration)
    }

    /// A made-up cover: a diagonal gradient per track, as PNG bytes.
    private static func artwork(_ i: Int) -> Data? {
        let palettes: [[CGFloat]] = [[0.93, 0.55, 0.20, 0.55, 0.12, 0.35], [0.20, 0.62, 0.55, 0.10, 0.20, 0.45],
                                     [0.85, 0.80, 0.30, 0.30, 0.50, 0.15]]
        let c = palettes[i % palettes.count]
        let size = 120
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let gradient = CGGradient(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                        colorComponents: [c[0], c[1], c[2], 1, c[3], c[4], c[5], 1],
                                        locations: [0, 1], count: 2) else { return nil }
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size, y: size), options: [])
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.85))
        ctx.fillEllipse(in: CGRect(x: 40, y: 40, width: 40, height: 40))
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.6))
        ctx.fillEllipse(in: CGRect(x: 54, y: 54, width: 12, height: 12))
        guard let image = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
