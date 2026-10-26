import CoreGraphics
import Foundation
import Testing
@testable import MateCore

@Suite struct NowPlayingParseTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func spotifyUserInfo() {
        let info: [AnyHashable: Any] = [
            "Player State": "Playing", "Track ID": "spotify:track:abc", "Name": "Song", "Artist": "Band",
            "Album": "Record", "Duration": NSNumber(value: 153_000), "Playback Position": NSNumber(value: 66.5),
        ]
        let np = NowPlayingParse.spotify(info, previous: nil, now: t0)
        #expect(np == NowPlaying(player: .spotify, state: .playing, trackID: "spotify:track:abc", title: "Song",
                                 artist: "Band", album: "Record", duration: 153, position: 66.5, positionAt: t0,
                                 shuffle: nil, changedAt: t0))
    }

    @Test func musicUserInfo() {
        let info: [AnyHashable: Any] = [
            "Player State": "Paused", "Name": "Tema", "Artist": "Grupo", "Album": "Disco",
            "Total Time": NSNumber(value: 200_500), "PersistentID": NSNumber(value: Int64(-2)),
        ]
        let np = NowPlayingParse.music(info, previous: nil, now: t0)
        #expect(np.player == .music)
        #expect(np.state == .paused)
        #expect(np.title == "Tema" && np.artist == "Grupo" && np.album == "Disco")
        #expect(np.duration == 200.5)
        // The persistent id as Music's own hex string (unsigned).
        #expect(np.trackID == "FFFFFFFFFFFFFFFE")
        // A new track with no position in the notification starts at 0.
        #expect(np.position == 0)
    }

    @Test func stoppedAndUnknownStates() {
        let stopped = NowPlayingParse.music(["Player State": "Stopped"], previous: nil, now: t0)
        #expect(stopped.state == .stopped)
        #expect(!stopped.hasTrack)
        let odd = NowPlayingParse.spotify(["Player State": "Buffering", "Name": "x"], previous: nil, now: t0)
        #expect(odd.state == .stopped)
    }

    @Test func sameTrackKeepsInterpolatedPositionAndShuffle() {
        var prev = NowPlayingParse.music(["Player State": "Playing", "Name": "Tema", "PersistentID": NSNumber(value: 7),
                                          "Total Time": NSNumber(value: 100_000)], previous: nil, now: t0)
        prev.position = 10
        prev.shuffle = true
        // Paused 5 s later; Music sends no position: the interpolated one stays until a read.
        let paused = NowPlayingParse.music(["Player State": "Paused", "Name": "Tema", "PersistentID": NSNumber(value: 7),
                                            "Total Time": NSNumber(value: 100_000)],
                                           previous: prev, now: t0 + 5)
        #expect(paused.position == 15)
        #expect(paused.positionAt == t0 + 5)
        #expect(paused.shuffle == true)
        #expect(paused.changedAt == t0 + 5)
        // Another track: position from zero, shuffle (a player setting) kept.
        let next = NowPlayingParse.music(["Player State": "Playing", "Name": "Otro", "PersistentID": NSNumber(value: 8)],
                                         previous: paused, now: t0 + 6)
        #expect(next.position == 0)
        #expect(next.shuffle == true)
    }

    @Test func readoutFillsWhatTheNotificationLacks() {
        let np = NowPlayingParse.spotify(["Player State": "Playing", "Track ID": "t1", "Name": "Song",
                                          "Duration": NSNumber(value: 100_000)], previous: nil, now: t0)
        let read = PlayerReadout(state: .playing, position: 42, shuffle: true, trackID: "t1", title: "Song",
                                 artist: "Band", album: "Rec", duration: 100)
        let merged = NowPlaying.from(read, player: .spotify, previous: np, now: t0 + 1)
        #expect(merged.position == 42 && merged.positionAt == t0 + 1)
        #expect(merged.shuffle == true)
        #expect(merged.artist == "Band")
        // Same state and track: not a change for "most recently changed".
        #expect(merged.changedAt == t0)
        let paused = NowPlaying.from(PlayerReadout(state: .paused, position: 43), player: .spotify, previous: merged,
                                     now: t0 + 2)
        #expect(paused.changedAt == t0 + 2)
        #expect(paused.title == "Song")
        #expect(paused.shuffle == true)
    }
}

@Suite struct NowPlayingLogicTests {
    let t0 = Date(timeIntervalSince1970: 2_000_000)

    func np(_ player: MusicPlayer, _ state: PlaybackState, changed: TimeInterval, title: String = "x") -> NowPlaying {
        NowPlaying(player: player, state: state, trackID: nil, title: title, artist: "", album: "", duration: 100,
                   position: 0, positionAt: t0, shuffle: nil, changedAt: t0 + changed)
    }

    @Test func choosesThePlayingOne() {
        let a = np(.spotify, .paused, changed: 10), b = np(.music, .playing, changed: 1)
        #expect(NowPlayingChoice.active([a, b])?.player == .music)
    }

    @Test func bothOrNeitherPlayingTakesTheLatestChange() {
        #expect(NowPlayingChoice.active([np(.spotify, .playing, changed: 1), np(.music, .playing, changed: 2)])?.player == .music)
        #expect(NowPlayingChoice.active([np(.spotify, .paused, changed: 3), np(.music, .paused, changed: 2)])?.player == .spotify)
    }

    @Test func stoppedOrEmptyIsNothing() {
        #expect(NowPlayingChoice.active([np(.spotify, .stopped, changed: 5)]) == nil)
        #expect(NowPlayingChoice.active([np(.spotify, .paused, changed: 5, title: "")]) == nil)
        #expect(NowPlayingChoice.active([np(.spotify, .stopped, changed: 9), np(.music, .paused, changed: 1)])?.player == .music)
        #expect(NowPlayingChoice.active([]) == nil)
    }

    @Test func elapsedInterpolatesOnlyWhilePlaying() {
        var p = np(.spotify, .playing, changed: 0)
        p.position = 60
        #expect(p.elapsed(at: t0 + 6) == 66)
        #expect(p.remaining(at: t0 + 6) == 34)
        #expect(p.progress(at: t0 + 6) == 0.66)
        // Clamped to the duration.
        #expect(p.elapsed(at: t0 + 500) == 100)
        p.state = .paused
        #expect(p.elapsed(at: t0 + 6) == 60)
        // Unknown duration: no remaining time and no progress.
        p.duration = nil
        #expect(p.remaining(at: t0) == nil)
        #expect(p.progress(at: t0) == nil)
        #expect(p.elapsed(at: t0) == 60)
    }

    @Test func timeText() {
        #expect(NowPlayingText.time(66) == "1:06")
        #expect(NowPlayingText.time(5.9) == "0:05")
        #expect(NowPlayingText.time(3723) == "1:02:03")
        #expect(NowPlayingText.remaining(87) == "-1:27")
        #expect(NowPlayingText.time(-3) == "0:00")
    }

    @Test func cardShowsWhileATrackIsLoaded() {
        #expect(NowPlayingUI.showsCard(enabled: true, nowPlaying: np(.spotify, .paused, changed: 0)))
        #expect(NowPlayingUI.showsCard(enabled: true, nowPlaying: np(.spotify, .playing, changed: 0)))
        #expect(!NowPlayingUI.showsCard(enabled: false, nowPlaying: np(.spotify, .playing, changed: 0)))
        #expect(!NowPlayingUI.showsCard(enabled: true, nowPlaying: np(.spotify, .stopped, changed: 0)))
        #expect(!NowPlayingUI.showsCard(enabled: true, nowPlaying: nil))
    }

    @Test func clockTicksOnlyOpenAndPlaying() {
        #expect(NowPlayingUI.ticks(panelOpen: true, nowPlaying: np(.music, .playing, changed: 0)))
        #expect(!NowPlayingUI.ticks(panelOpen: false, nowPlaying: np(.music, .playing, changed: 0)))
        #expect(!NowPlayingUI.ticks(panelOpen: true, nowPlaying: np(.music, .paused, changed: 0)))
        #expect(!NowPlayingUI.ticks(panelOpen: true, nowPlaying: nil))
    }

    @Test func leftEarPicksMusicWhilePlaying() {
        func ear(music: Bool = true, playing: Bool, mate: Bool = true, menuBar: Bool = true, pill: Bool = false,
                 awake: Bool = false) -> LeftEarContent {
            NowPlayingUI.leftEar(showMusic: music, playing: playing, showMate: mate, menuBarVisible: menuBar,
                                 pillShown: pill, keptAwake: awake)
        }
        // Playing: the art, even with the pill hidden and the mate off.
        #expect(ear(playing: true) == .music)
        #expect(ear(playing: true, mate: false) == .music)
        #expect(ear(playing: true, pill: true, awake: true) == .music)
        // Paused or stopped: back to the mate's own rule.
        #expect(ear(playing: false) == .none)
        #expect(ear(playing: false, pill: true) == .mate)
        #expect(ear(playing: false, awake: true) == .mate)
        #expect(ear(playing: false, mate: false, pill: true) == .none)
        // The option off, or another app's full screen.
        #expect(ear(music: false, playing: true) == .none)
        #expect(ear(music: false, playing: true, pill: true) == .mate)
        #expect(ear(playing: true, menuBar: false) == .none)
    }

    @Test func artworkHostIsOnlySpotifysCDN() {
        #expect(NowPlayingArtwork.allowedURL("https://i.scdn.co/image/ab67616d0000b273") != nil)
        #expect(NowPlayingArtwork.allowedURL("http://i.scdn.co/image/x") == nil)
        #expect(NowPlayingArtwork.allowedURL("https://evil.example/i.scdn.co") == nil)
        #expect(NowPlayingArtwork.allowedURL("https://i.scdn.co.evil.example/x") == nil)
        #expect(NowPlayingArtwork.allowedURL("not a url") == nil)
    }

    @Test func artworkCacheKeepsTheLastFive() {
        var cache = ArtworkCache<Int>(limit: 5)
        for i in 1...7 { cache.insert(i, for: "t\(i)") }
        #expect(cache.value(for: "t1") == nil && cache.value(for: "t2") == nil)
        #expect(cache.value(for: "t3") == 3 && cache.value(for: "t7") == 7)
        // Reading a key keeps it fresh.
        cache.insert(8, for: "t8")
        #expect(cache.value(for: "t3") == 3)
        #expect(cache.value(for: "t4") == nil)
    }
}

@Suite struct MusicEarLayoutTests {
    @Test func musicEarLeftOfNotch() {
        let n = CGRect(x: 662, y: 950, width: 188, height: 32)
        // 7 pt padding, 18 pt art, 6 pt gap, 9 pt of bars, 8 pt padding.
        #expect(NotchLayout.musicEarWidth == 48)
        #expect(NotchLayout.musicRect(notch: n) == CGRect(x: 614, y: 950, width: 48, height: 32))
        #expect(NotchLayout.musicArtRect(notch: n) == CGRect(x: 621, y: 957, width: 18, height: 18))
        #expect(NotchLayout.musicBarsRect(notch: n) == CGRect(x: 645, y: 960, width: 9, height: 12))
        #expect(NotchLayout.leftEarRect(notch: n, content: .music) == NotchLayout.musicRect(notch: n))
        #expect(NotchLayout.leftEarRect(notch: n, content: .mate) == NotchLayout.mateRect(notch: n))
        #expect(NotchLayout.leftEarRect(notch: n, content: .none) == nil)
    }

    @Test func musicEarRightOfNotch() {
        let n = CGRect(x: 662, y: 950, width: 188, height: 32)
        // Same padding and order (art, then bars), starting at the notch's right edge.
        #expect(NotchLayout.musicRect(notch: n, onRight: true) == CGRect(x: 850, y: 950, width: 48, height: 32))
        #expect(NotchLayout.musicArtRect(notch: n, onRight: true) == CGRect(x: 857, y: 957, width: 18, height: 18))
        #expect(NotchLayout.musicBarsRect(notch: n, onRight: true) == CGRect(x: 881, y: 960, width: 9, height: 12))
        #expect(NotchLayout.leftEarRect(notch: n, content: .music, onRight: true)
            == NotchLayout.musicRect(notch: n, onRight: true))
        #expect(NotchLayout.leftEarRect(notch: n, content: .none, onRight: true) == nil)
    }
}
