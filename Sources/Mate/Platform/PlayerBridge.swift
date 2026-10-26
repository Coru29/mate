import AppKit
import CoreServices
import MateCore

/// What the card's buttons ask a player to do.
enum PlayerCommand: Equatable {
    case playPause, previous, next
    case seek(TimeInterval)
    case shuffle(Bool)
}

enum PlayerAccess: Equatable {
    case granted, denied, notRunning
    case failed(Int)
}

enum PlayerError: Error, Equatable {
    /// errAEEventNotPermitted (-1743): the user said no in Privacidad → Automatización.
    case notPermitted
    case notRunning
    case failed(Int)
}

/// One read: the readout plus where the artwork is (Spotify gives a URL; Music's bytes come from `artworkData`).
struct PlayerRead: Equatable {
    var readout: PlayerReadout
    var artworkURL: String?
}

/// Talks to Spotify and Music. `isRunning` is called on the main thread; everything else on the now-playing queue
/// (an Apple Event can block for a few seconds, and the first one waits for macOS's permission prompt).
protocol PlayerBridge: AnyObject {
    func isRunning(_ player: MusicPlayer) -> Bool
    /// Asks macOS for permission to send Apple Events (shows the prompt once, the first time).
    func access(_ player: MusicPlayer) -> PlayerAccess
    func read(_ player: MusicPlayer) throws -> PlayerRead
    func artworkData(_ player: MusicPlayer) throws -> Data?
    func send(_ player: MusicPlayer, _ command: PlayerCommand) throws
}

/// The real players through raw Apple Events (`NSAppleEventDescriptor`): no AppleScript compilation, so nothing
/// needs the player's dictionary and nothing launches a player. Events go only to a player that is running.
final class AppleEventPlayerBridge: PlayerBridge, @unchecked Sendable {
    private static let timeout: TimeInterval = 3

    func isRunning(_ player: MusicPlayer) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: player.bundleID).isEmpty
    }

    func access(_ player: MusicPlayer) -> PlayerAccess {
        guard isRunning(player) else { return .notRunning }
        let target = NSAppleEventDescriptor(bundleIdentifier: player.bundleID)
        guard let desc = target.aeDesc else { return .failed(-1) }
        // A concrete event (get data): with askUserIfNeeded, wildcards are not allowed.
        let status = AEDeterminePermissionToAutomateTarget(desc, AEEventClass(kAECoreSuite), AEEventID(kAEGetData), true)
        switch Int(status) {
        case Int(noErr): return .granted
        case Int(errAEEventNotPermitted): return .denied
        case Int(procNotFound): return .notRunning
        default: return .failed(Int(status))
        }
    }

    func read(_ player: MusicPlayer) throws -> PlayerRead {
        let stateCode = try get(player, prop("pPlS"))?.enumCodeValue
        let state: PlaybackState
        switch stateCode {
        case fourCC("kPSP"): state = .playing
        case fourCC("kPSp"): state = .paused
        default: state = .stopped
        }
        guard state != .stopped else { return PlayerRead(readout: PlayerReadout(state: .stopped)) }
        let track = prop("pTrk")
        var r = PlayerReadout(state: state)
        r.position = try get(player, prop("pPos"))?.doubleValue
        r.shuffle = try get(player, prop(player == .spotify ? "pShu" : "pShE"))?.booleanValue
        r.title = try get(player, prop("pnam", of: track))?.stringValue
        r.artist = try get(player, prop("pArt", of: track))?.stringValue
        r.album = try get(player, prop("pAlb", of: track))?.stringValue
        r.trackID = try get(player, prop(player == .spotify ? "ID  " : "pPIS", of: track))?.stringValue
        if let d = try get(player, prop("pDur", of: track))?.doubleValue, d > 0 {
            // Spotify's "duration" is in milliseconds despite its dictionary; Music's is in seconds.
            r.duration = player == .spotify ? d / 1000 : d
        }
        let url = player == .spotify ? try get(player, prop("aUrl", of: track))?.stringValue : nil
        return PlayerRead(readout: r, artworkURL: url)
    }

    /// Music: `raw data of artwork 1 of current track` (the file's own bytes). Spotify has only the URL.
    func artworkData(_ player: MusicPlayer) throws -> Data? {
        guard player == .music else { return nil }
        let artwork = element("cArt", index: 1, of: prop("pTrk"))
        if let raw = try? get(player, prop("pRaw", of: artwork)), !raw.data.isEmpty { return raw.data }
        return try get(player, prop("pPCT", of: artwork))?.data
    }

    func send(_ player: MusicPlayer, _ command: PlayerCommand) throws {
        let suite = player == .spotify ? "spfy" : "hook"
        switch command {
        case .playPause: _ = try perform(event(player, suite, "PlPs"), player)
        case .next: _ = try perform(event(player, suite, "Next"), player)
        // Music's ◀◀ is "back track" (to the start, or to the previous track when already there), like its own button.
        case .previous: _ = try perform(event(player, suite, player == .spotify ? "Prev" : "Back"), player)
        case .seek(let seconds): try set(player, prop("pPos"), NSAppleEventDescriptor(double: max(0, seconds)))
        case .shuffle(let on):
            try set(player, prop(player == .spotify ? "pShu" : "pShE"), NSAppleEventDescriptor(boolean: on))
        }
    }

    // MARK: Apple Events

    private func fourCC(_ s: String) -> FourCharCode {
        s.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
    }

    private func event(_ player: MusicPlayer, _ suite: String, _ id: String) -> NSAppleEventDescriptor {
        event(player, fourCC(suite), fourCC(id))
    }

    private func event(_ player: MusicPlayer, _ cls: FourCharCode, _ id: FourCharCode) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor.appleEvent(withEventClass: cls, eventID: id,
                                          targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: player.bundleID),
                                          returnID: AEReturnID(kAutoGenerateReturnID),
                                          transactionID: AETransactionID(kAnyTransactionID))
    }

    /// `<property code> of <container>` (the application when nil).
    private func prop(_ code: String, of container: NSAppleEventDescriptor? = nil) -> NSAppleEventDescriptor {
        specifier(want: FourCharCode(cProperty), form: NSAppleEventDescriptor(enumCode: FourCharCode(formPropertyID)),
                  data: NSAppleEventDescriptor(typeCode: fourCC(code)), container: container)
    }

    /// `<class> <index> of <container>`.
    private func element(_ cls: String, index: Int32, of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        specifier(want: fourCC(cls), form: NSAppleEventDescriptor(enumCode: FourCharCode(formAbsolutePosition)),
                  data: NSAppleEventDescriptor(int32: index), container: container)
    }

    private func specifier(want: FourCharCode, form: NSAppleEventDescriptor, data: NSAppleEventDescriptor,
                           container: NSAppleEventDescriptor?) -> NSAppleEventDescriptor {
        let spec = NSAppleEventDescriptor.record().coerce(toDescriptorType: DescType(typeObjectSpecifier))
            ?? NSAppleEventDescriptor.record()
        spec.setDescriptor(NSAppleEventDescriptor(typeCode: want), forKeyword: AEKeyword(keyAEDesiredClass))
        spec.setDescriptor(form, forKeyword: AEKeyword(keyAEKeyForm))
        spec.setDescriptor(data, forKeyword: AEKeyword(keyAEKeyData))
        spec.setDescriptor(container ?? NSAppleEventDescriptor.null(), forKeyword: AEKeyword(keyAEContainer))
        return spec
    }

    private func get(_ player: MusicPlayer, _ spec: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor? {
        let e = event(player, FourCharCode(kAECoreSuite), FourCharCode(kAEGetData))
        e.setParam(spec, forKeyword: AEKeyword(keyDirectObject))
        return try perform(e, player)
    }

    private func set(_ player: MusicPlayer, _ spec: NSAppleEventDescriptor, _ value: NSAppleEventDescriptor) throws {
        let e = event(player, FourCharCode(kAECoreSuite), FourCharCode(kAESetData))
        e.setParam(spec, forKeyword: AEKeyword(keyDirectObject))
        e.setParam(value, forKeyword: AEKeyword(keyAEData))
        _ = try perform(e, player)
    }

    /// Sends and returns the reply's direct object. Never to a player that is not running: a stray event must not
    /// launch it.
    private func perform(_ e: NSAppleEventDescriptor, _ player: MusicPlayer) throws -> NSAppleEventDescriptor? {
        guard isRunning(player) else { throw PlayerError.notRunning }
        let reply: NSAppleEventDescriptor
        do {
            reply = try e.sendEvent(options: [.waitForReply, .neverInteract], timeout: Self.timeout)
        } catch let error as NSError {
            throw Self.map(error.code)
        }
        if let n = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber))?.int32Value, n != 0 {
            throw Self.map(Int(n))
        }
        return reply.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))
    }

    private static func map(_ code: Int) -> PlayerError {
        switch code {
        case Int(errAEEventNotPermitted): .notPermitted
        case Int(procNotFound), Int(connectionInvalid): .notRunning
        default: .failed(code)
        }
    }
}
