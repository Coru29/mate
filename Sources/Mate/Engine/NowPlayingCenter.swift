import AppKit
import Combine
import ImageIO
import MateCore

/// "Mostrar lo que estás escuchando": follows Spotify and Music through their distributed notifications and the
/// app launch/quit notifications, reads what a notification lacks (position, shuffle, artwork) with one coalesced
/// Apple Events read, and sends the card's controls. Nothing polls; a player that is not running gets no events.
/// With the option off there are no observers and no events at all.
@MainActor
final class NowPlayingCenter: ObservableObject {
    static let shared = NowPlayingCenter()

    /// The track to show (`NowPlayingChoice`), nil when nothing is loaded or the option is off.
    @Published private(set) var current: NowPlaying?
    /// The current track's artwork, downsampled for the card.
    @Published private(set) var artwork: CGImage?
    /// The current player refused Automatización: the card asks for it instead of showing controls.
    @Published private(set) var denied = false
    /// Ticks once a second while the panel is open and music plays (its own object, so the notch does not redraw
    /// on every tick).
    let clock = NowPlayingClock()

    private(set) var enabled = false
    private var bridge: PlayerBridge = AppleEventPlayerBridge()
    private var fake: FakePlayerBridge?
    private var states: [MusicPlayer: NowPlaying] = [:]
    private var deniedPlayers: Set<MusicPlayer> = []
    private var readTimers: [MusicPlayer: Timer] = [:]
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var prefObserver: NSObjectProtocol?
    private var artCache = ArtworkCache<CGImage>(limit: 5)
    private var artLoading: String?
    private let queue = DispatchQueue(label: "io.github.coru29.Mate.now-playing", qos: .userInitiated)
    private lazy var session = URLSession(configuration: .ephemeral)
    /// After a notification or a control: one read this much later, whatever else arrives meanwhile.
    nonisolated private static let coalesce: TimeInterval = 0.3
    /// Set while the panel is open (the clock ticks only then).
    var panelOpen = false {
        didSet {
            guard panelOpen != oldValue else { return }
            updateClock()
            // Shuffle posts no notification: refresh it (and the position) once when the panel opens.
            if panelOpen, let p = current?.player { scheduleRead(p) }
        }
    }

    /// `fake` replaces the real players (`--fake`): no notifications are observed then.
    func start(fake: FakePlayerBridge?) {
        guard prefObserver == nil else { return }
        if let fake {
            self.fake = fake
            bridge = fake
        }
        prefObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil,
                                                              queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setEnabled(NotchPrefs.showNowPlaying) }
        }
        setEnabled(NotchPrefs.showNowPlaying)
    }

    func stop() {
        if let prefObserver { NotificationCenter.default.removeObserver(prefObserver) }
        prefObserver = nil
        setEnabled(false)
    }

    private func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on {
            Log.info("now playing: on")
            observePlayers()
            if let info = fake?.initialNotification, let p = fake?.player { received(p, info) }
            for p in MusicPlayer.allCases where bridge.isRunning(p) { read(p) }
        } else {
            Log.info("now playing: off")
            for (center, token) in observers { center.removeObserver(token) }
            observers.removeAll()
            for t in readTimers.values { t.invalidate() }
            readTimers.removeAll()
            states.removeAll()
            deniedPlayers.removeAll()
            publish()
        }
    }

    private func observePlayers() {
        guard fake == nil else { return }
        let distributed = DistributedNotificationCenter.default()
        for p in MusicPlayer.allCases {
            let token = distributed.addObserver(forName: Notification.Name(p.notificationName), object: nil,
                                                queue: .main) { [weak self] note in
                nonisolated(unsafe) let info = note.userInfo ?? [:]
                MainActor.assumeIsolated { self?.received(p, info) }
            }
            observers.append((distributed, token))
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for (name, launched) in [(NSWorkspace.didLaunchApplicationNotification, true),
                                 (NSWorkspace.didTerminateApplicationNotification, false)] {
            let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                guard let p = MusicPlayer.allCases.first(where: { $0.bundleID == id }) else { return }
                MainActor.assumeIsolated { launched ? self?.launched(p) : self?.terminated(p) }
            }
            observers.append((workspace, token))
        }
    }

    // MARK: Events

    private func received(_ p: MusicPlayer, _ info: [AnyHashable: Any]) {
        guard enabled else { return }
        let now = Date()
        let parsed = p == .spotify ? NowPlayingParse.spotify(info, previous: states[p], now: now)
            : NowPlayingParse.music(info, previous: states[p], now: now)
        states[p] = parsed
        publish()
        if parsed.state != .stopped { scheduleRead(p) }
    }

    /// A player started: it gets a fresh chance at permission, and one read once it is up.
    private func launched(_ p: MusicPlayer) {
        deniedPlayers.remove(p)
        scheduleRead(p, after: 1.5)
    }

    private func terminated(_ p: MusicPlayer) {
        readTimers.removeValue(forKey: p)?.invalidate()
        states[p] = nil
        deniedPlayers.remove(p)
        publish()
    }

    private func scheduleRead(_ p: MusicPlayer, after delay: TimeInterval = coalesce) {
        guard enabled, readTimers[p] == nil else { return }
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.readTimers[p] = nil
                self?.read(p)
            }
        }
        t.tolerance = delay * 0.1
        RunLoop.main.add(t, forMode: .common)
        readTimers[p] = t
    }

    /// One read of a running, permitted player, off the main thread.
    private func read(_ p: MusicPlayer) {
        guard enabled, !deniedPlayers.contains(p), bridge.isRunning(p) else { return }
        nonisolated(unsafe) let b = bridge
        queue.async { [weak self] in
            let result: Result<PlayerRead, PlayerError>
            switch b.access(p) {
            case .granted:
                do { result = .success(try b.read(p)) } catch { result = .failure(error as? PlayerError ?? .failed(-1)) }
            case .denied: result = .failure(.notPermitted)
            case .notRunning: result = .failure(.notRunning)
            case .failed(let code): result = .failure(.failed(code))
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.didRead(p, result) } }
        }
    }

    private func didRead(_ p: MusicPlayer, _ result: Result<PlayerRead, PlayerError>) {
        guard enabled else { return }
        switch result {
        case .success(let r):
            let next = NowPlaying.from(r.readout, player: p, previous: states[p], now: Date())
            states[p] = next
            publish()
            if next.hasTrack { loadArtwork(next, url: r.artworkURL) }
        case .failure(.notPermitted): markDenied(p)
        case .failure(.notRunning): break
        case .failure(.failed(let code)): Log.error("now playing: \(p.rawValue) read failed (\(code))")
        }
    }

    private func markDenied(_ p: MusicPlayer) {
        guard !deniedPlayers.contains(p) else { return }
        Log.info("now playing: \(p.rawValue) denied Automatización; no more events until it relaunches or retry")
        deniedPlayers.insert(p)
        publish()
    }

    /// Recomputes what is shown and publishes only real changes.
    private func publish() {
        let next = enabled ? NowPlayingChoice.active(Array(states.values)) : nil
        if next != current { current = next }
        let isDenied = next.map { deniedPlayers.contains($0.player) } ?? false
        if isDenied != denied { denied = isDenied }
        let art = next.flatMap { artCache.value(for: $0.artKey) }
        if art !== artwork { artwork = art }
        updateClock()
    }

    private func updateClock() {
        clock.run(NowPlayingUI.ticks(panelOpen: panelOpen, nowPlaying: current))
    }

    // MARK: Artwork

    private func loadArtwork(_ np: NowPlaying, url: String?) {
        let key = np.artKey
        guard artCache.value(for: key) == nil, artLoading != key else { return }
        artLoading = key
        if let url {
            guard let u = NowPlayingArtwork.allowedURL(url) else { artLoading = nil; return }
            var request = URLRequest(url: u)
            request.httpShouldHandleCookies = false
            session.dataTask(with: request) { [weak self] data, _, _ in
                let image = data.flatMap(Self.downsample)
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.didLoad(image, key: key) } }
            }.resume()
            return
        }
        nonisolated(unsafe) let b = bridge
        let p = np.player
        queue.async { [weak self] in
            let image = (try? b.artworkData(p)).flatMap { $0 }.flatMap(Self.downsample)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.didLoad(image, key: key) } }
        }
    }

    private func didLoad(_ image: CGImage?, key: String) {
        if artLoading == key { artLoading = nil }
        guard let image else { return }
        artCache.insert(image, for: key)
        publish()
    }

    /// Covers can be 3000 px; the card needs 44 pt at 2x.
    nonisolated private static func downsample(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 132,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }

    // MARK: Controls

    func perform(_ command: PlayerCommand) {
        guard enabled, var np = current else { return }
        let p = np.player
        guard !deniedPlayers.contains(p), bridge.isRunning(p) else { return }
        // Shown at once; the next notification or read confirms it.
        let now = Date()
        switch command {
        case .playPause:
            np.position = np.elapsed(at: now)
            np.positionAt = now
            np.state = np.state == .playing ? .paused : .playing
            np.changedAt = now
        case .seek(let s):
            np.position = s
            np.positionAt = now
        case .shuffle(let on): np.shuffle = on
        case .next, .previous: break
        }
        states[p] = np
        publish()
        nonisolated(unsafe) let b = bridge
        queue.async { [weak self] in
            var failure: PlayerError?
            switch b.access(p) {
            case .granted:
                do { try b.send(p, command) } catch { failure = error as? PlayerError ?? .failed(-1) }
            case .denied: failure = .notPermitted
            case .notRunning: failure = .notRunning
            case .failed(let code): failure = .failed(code)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if failure == .notPermitted { self.markDenied(p) }
                    else if case .failed(let code) = failure { Log.error("now playing: \(p.rawValue) control failed (\(code))") }
                    self.scheduleRead(p)
                }
            }
        }
    }

    /// "Reintentar" on the card: asks again (macOS shows nothing new until the user changes Automatización).
    func retryPermission() {
        guard let p = current?.player else { return }
        deniedPlayers.remove(p)
        publish()
        read(p)
    }

    func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: --dump

    /// `--dump`: the player, state, title/artist, position/duration and shuffle. Reads the running players once
    /// (the fake one with `--fake`).
    static func dumpLine() -> String {
        guard NotchPrefs.showNowPlaying else { return "now-playing: option=off" }
        let bridge: PlayerBridge = DebugCLI.isFake ? FakePlayerBridge.fromArguments : AppleEventPlayerBridge()
        var lines: [String] = []
        for p in MusicPlayer.allCases where bridge.isRunning(p) {
            switch bridge.access(p) {
            case .denied: lines.append("\(p.rawValue) denied (Automatización)")
            case .notRunning: break
            case .failed(let code): lines.append("\(p.rawValue) error \(code)")
            case .granted:
                guard let r = try? bridge.read(p) else { lines.append("\(p.rawValue) unreadable"); continue }
                let np = NowPlaying.from(r.readout, player: p, previous: nil, now: Date())
                guard np.hasTrack else { lines.append("\(p.rawValue) \(np.state.rawValue)"); continue }
                let pos = np.elapsed(at: Date()).map(NowPlayingText.time) ?? "?"
                let dur = np.duration.map(NowPlayingText.time) ?? "?"
                let shuffle = np.shuffle.map { $0 ? "on" : "off" } ?? "?"
                lines.append("\(p.rawValue) \(np.state.rawValue) \"\(np.title)\" — \"\(np.artist)\"  \(pos)/\(dur)  shuffle=\(shuffle)")
            }
        }
        return "now-playing: option=on  " + (lines.isEmpty ? "nothing running" : lines.joined(separator: "; "))
    }
}

/// The card's clock: one tick a second, only while it runs.
@MainActor
final class NowPlayingClock: ObservableObject {
    @Published private(set) var now = Date()
    private var timer: Timer?

    func run(_ on: Bool) {
        if on, timer == nil {
            now = Date()
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.now = Date() }
            }
            t.tolerance = 0.2
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if !on, let t = timer {
            t.invalidate()
            timer = nil
            now = Date()
        }
    }
}
