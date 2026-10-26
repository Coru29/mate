import Foundation

/// The two players Mate follows. Both are reached only through Apple Events (and their distributed notifications);
/// MediaRemote is private and blocked on recent macOS.
public enum MusicPlayer: String, CaseIterable, Sendable {
    case spotify, music

    public var bundleID: String {
        switch self {
        case .spotify: "com.spotify.client"
        case .music: "com.apple.Music"
        }
    }

    /// The distributed notification the player posts on every play, pause, stop and track change.
    public var notificationName: String {
        switch self {
        case .spotify: "com.spotify.client.PlaybackStateChanged"
        case .music: "com.apple.Music.playerInfo"
        }
    }
}

public enum PlaybackState: String, Sendable {
    case playing, paused, stopped

    /// "Playing" / "Paused" / "Stopped" as both players spell it in their notifications; anything else is stopped.
    init(playerState: String?) {
        switch playerState?.lowercased() {
        case "playing": self = .playing
        case "paused": self = .paused
        default: self = .stopped
        }
    }
}

/// One player's current track and where it is.
public struct NowPlaying: Equatable, Sendable {
    public var player: MusicPlayer
    public var state: PlaybackState
    public var trackID: String?
    public var title: String
    public var artist: String
    public var album: String
    /// Seconds; nil for a stream with no length.
    public var duration: TimeInterval?
    /// Seconds into the track at `positionAt`; nil when unknown.
    public var position: TimeInterval?
    public var positionAt: Date
    /// The player's shuffle setting; nil until read.
    public var shuffle: Bool?
    /// Last change of state or track, to pick between two players.
    public var changedAt: Date

    public init(player: MusicPlayer, state: PlaybackState, trackID: String?, title: String, artist: String,
                album: String, duration: TimeInterval?, position: TimeInterval?, positionAt: Date, shuffle: Bool?,
                changedAt: Date) {
        self.player = player
        self.state = state
        self.trackID = trackID
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.position = position
        self.positionAt = positionAt
        self.shuffle = shuffle
        self.changedAt = changedAt
    }

    /// Something to show: a track is loaded (playing or paused).
    public var hasTrack: Bool { state != .stopped && !title.isEmpty }

    /// The key artwork is cached by.
    public var artKey: String { trackID ?? "\(title)\u{1F}\(artist)\u{1F}\(album)" }

    /// Seconds into the track at `now`: the last known position, moved forward while playing, within the duration.
    public func elapsed(at now: Date) -> TimeInterval? {
        guard let position else { return nil }
        var t = position
        if state == .playing { t += now.timeIntervalSince(positionAt) }
        if let duration { t = min(t, duration) }
        return max(0, t)
    }

    public func remaining(at now: Date) -> TimeInterval? {
        guard let duration, duration > 0, let e = elapsed(at: now) else { return nil }
        return max(0, duration - e)
    }

    /// 0…1 through the track; nil without a duration.
    public func progress(at now: Date) -> Double? {
        guard let duration, duration > 0, let e = elapsed(at: now) else { return nil }
        return min(max(e / duration, 0), 1)
    }

    /// The state after an Apple Events read: what was read wins, the rest is kept.
    public static func from(_ r: PlayerReadout, player: MusicPlayer, previous: NowPlaying?, now: Date) -> NowPlaying {
        let state = r.state ?? previous?.state ?? .stopped
        let sameTrack = previous != nil && (r.trackID == nil || r.trackID == previous?.trackID)
        let base = sameTrack ? previous : nil
        let changed = previous == nil || previous?.state != state || !sameTrack
        let position: TimeInterval? = r.position ?? (sameTrack ? previous?.elapsed(at: now) : 0)
        return NowPlaying(player: player, state: state, trackID: r.trackID ?? base?.trackID,
                          title: r.title ?? base?.title ?? "", artist: r.artist ?? base?.artist ?? "",
                          album: r.album ?? base?.album ?? "", duration: r.duration ?? base?.duration,
                          position: position, positionAt: now, shuffle: r.shuffle ?? previous?.shuffle,
                          changedAt: changed ? now : previous!.changedAt)
    }
}

/// What one Apple Events read of a player returned (any field may be missing).
public struct PlayerReadout: Equatable, Sendable {
    public var state: PlaybackState?
    public var position: TimeInterval?
    public var shuffle: Bool?
    public var trackID: String?
    public var title: String?
    public var artist: String?
    public var album: String?
    public var duration: TimeInterval?

    public init(state: PlaybackState? = nil, position: TimeInterval? = nil, shuffle: Bool? = nil,
                trackID: String? = nil, title: String? = nil, artist: String? = nil, album: String? = nil,
                duration: TimeInterval? = nil) {
        self.state = state
        self.position = position
        self.shuffle = shuffle
        self.trackID = trackID
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
    }
}

/// The players' notification userInfos as `NowPlaying`.
public enum NowPlayingParse {
    /// Spotify: "Player State", "Track ID", "Name", "Artist", "Album", "Duration" (ms), "Playback Position" (s).
    public static func spotify(_ info: [AnyHashable: Any], previous: NowPlaying?, now: Date) -> NowPlaying {
        make(.spotify, info, trackID: info["Track ID"] as? String, durationMs: number(info["Duration"]),
             position: number(info["Playback Position"]), previous: previous, now: now)
    }

    /// Music: "Player State", "Name", "Artist", "Album", "Total Time" (ms), "PersistentID"; no position.
    public static func music(_ info: [AnyHashable: Any], previous: NowPlaying?, now: Date) -> NowPlaying {
        // Music's own "persistent ID" property is the same 64-bit number as unsigned hex.
        let id = (info["PersistentID"] as? NSNumber).map { String(format: "%016llX", UInt64(bitPattern: $0.int64Value)) }
        return make(.music, info, trackID: id, durationMs: number(info["Total Time"]), position: nil,
                    previous: previous, now: now)
    }

    private static func make(_ player: MusicPlayer, _ info: [AnyHashable: Any], trackID: String?, durationMs: Double?,
                             position: Double?, previous: NowPlaying?, now: Date) -> NowPlaying {
        let state = PlaybackState(playerState: info["Player State"] as? String)
        let sameTrack = previous != nil && previous?.trackID == trackID
        let pos = position ?? (sameTrack ? previous?.elapsed(at: now) : 0)
        return NowPlaying(player: player, state: state, trackID: trackID, title: info["Name"] as? String ?? "",
                          artist: info["Artist"] as? String ?? "", album: info["Album"] as? String ?? "",
                          duration: durationMs.flatMap { $0 > 0 ? $0 / 1000 : nil }, position: pos, positionAt: now,
                          shuffle: previous?.shuffle, changedAt: now)
    }

    private static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }
}

public enum NowPlayingChoice {
    /// The player to show: the one playing; if both or neither play, the one that changed last. Stopped players
    /// and empty tracks are never shown.
    public static func active(_ players: [NowPlaying]) -> NowPlaying? {
        let loaded = players.filter(\.hasTrack)
        let playing = loaded.filter { $0.state == .playing }
        return (playing.isEmpty ? loaded : playing).max { $0.changedAt < $1.changedAt }
    }
}

/// What the notch's left ear shows.
public enum LeftEarContent: Equatable, Sendable {
    case none, mate, music
}

public enum NowPlayingUI {
    /// The panel's card: the option on and a track loaded (playing or paused).
    public static func showsCard(enabled: Bool, nowPlaying: NowPlaying?) -> Bool {
        enabled && nowPlaying?.hasTrack == true
    }

    /// The card's elapsed time ticks (a 1 s timer) only while the panel is open and music plays.
    public static func ticks(panelOpen: Bool, nowPlaying: NowPlaying?) -> Bool {
        panelOpen && nowPlaying?.state == .playing
    }

    /// The album art replaces the mate while music plays (even with the pill hidden); otherwise the mate's rule.
    public static func leftEar(showMusic: Bool, playing: Bool, showMate: Bool, menuBarVisible: Bool, pillShown: Bool,
                               keptAwake: Bool) -> LeftEarContent {
        if showMusic && playing && menuBarVisible { return .music }
        return MateEar.shown(showMate: showMate, menuBarVisible: menuBarVisible, pillShown: pillShown,
                             keptAwake: keptAwake) ? .mate : .none
    }
}

public enum NowPlayingText {
    /// "1:06", "1:02:03".
    public static func time(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds.isFinite ? seconds : 0))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// "-1:27".
    public static func remaining(_ seconds: TimeInterval) -> String { "-" + time(seconds) }
}

public enum NowPlayingArtwork {
    /// The only host artwork is downloaded from: Spotify's image CDN, over https (no tokens, no cookies).
    public static let host = "i.scdn.co"

    public static func allowedURL(_ string: String) -> URL? {
        guard let url = URL(string: string), url.scheme == "https", url.host == host else { return nil }
        return url
    }
}

/// The last few artworks by track, least recently used dropped first.
public struct ArtworkCache<Value> {
    private var order: [String] = []
    private var values: [String: Value] = [:]
    public let limit: Int

    public init(limit: Int = 5) { self.limit = limit }

    public mutating func value(for key: String) -> Value? {
        guard let v = values[key] else { return nil }
        order.removeAll { $0 == key }
        order.append(key)
        return v
    }

    public mutating func insert(_ value: Value, for key: String) {
        values[key] = value
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > limit { values[order.removeFirst()] = nil }
    }
}
