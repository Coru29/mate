import AppKit
import MateCore
import Security

/// Keeps Mate up to date from its GitHub releases (a port of Rambla's updater): it checks once a day (through the
/// system's energy-aware scheduler) or on demand, and when the user accepts it downloads the DMG, verifies that the
/// new app is signed with the same certificate as the running one (the designated requirement), swaps the bundle in
/// place and relaunches. Anything not signed by the project's certificate is refused and the user gets the release
/// page. The same certificate is also what keeps macOS's "Permitir siempre" keychain answers across updates.
@MainActor
final class Updater {
    static let shared = Updater()
    /// The release list, not `/releases/latest`: 0.x releases are pre-releases, which `latest` skips.
    static let releasesAPI = URL(string: "https://api.github.com/repos/Coru29/mate/releases?per_page=30")!
    /// Developer override (`defaults write io.github.coru29.Mate updateFeedURL <url>`, or the `MATE_DEFAULTS_SUITE`
    /// of a test run) used to test updates against a local copy of the release list instead of GitHub.
    static var testFeed: URL? { UserDefaults.mate.string(forKey: "updateFeedURL").flatMap(URL.init(string:)) }
    static var feedURL: URL { testFeed ?? releasesAPI }

    enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self { case .message(let text): return text }
        }
    }

    /// No cookies, no disk cache. GitHub serves the DMG from its own download host through a redirect, so unlike
    /// `HTTP` this session follows redirects; no token is ever sent here.
    private nonisolated static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpCookieStorage = nil
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 15 * 60
        return URLSession(configuration: c)
    }()

    /// A newer release than the running one, once a check has found it.
    private(set) var available: ReleaseInfo?
    private(set) var isInstalling = false
    private var scheduler: NSBackgroundActivityScheduler?
    /// The check 30 s after launch (or after the option is turned on): cancelled when the option is turned off.
    private var launchCheck: Task<Void, Never>?
    private(set) var automatic = false

    var currentVersion: AppVersion {
        AppVersion(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") ?? AppVersion("0")!
    }

    /// Turns the daily check on or off (Configuración → Actualizaciones). Calling it with the current value is a no-op.
    func configure(automatic: Bool) {
        guard automatic != self.automatic else { return }
        self.automatic = automatic
        scheduler?.invalidate()
        scheduler = nil
        launchCheck?.cancel()
        launchCheck = nil
        guard automatic else { return }
        let scheduler = NSBackgroundActivityScheduler(identifier: "io.github.coru29.Mate.updates")
        scheduler.repeats = true
        scheduler.interval = 24 * 60 * 60
        scheduler.tolerance = 2 * 60 * 60
        scheduler.qualityOfService = .utility
        scheduler.schedule { [weak self] completion in
            Task { @MainActor in
                await self?.check(userInitiated: false)
                completion(.finished)
            }
        }
        self.scheduler = scheduler
        launchCheck = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            await self?.check(userInitiated: false)
        }
    }

    // MARK: - Checking

    func check(userInitiated: Bool) async {
        do {
            let releases = try await fetchReleases()
            available = UpdateFeed.newest(releases, current: currentVersion)
            if let available {
                Log.info("Update available: \(available.version)")
                if userInitiated { offerInstall() }
            } else if userInitiated {
                let current = currentVersion.description
                inform(String(localized: "Tenés la última versión"), String(localized: "Mate \(current) es la versión más nueva."))
            }
        } catch {
            Log.error("Update check failed: \(error.localizedDescription)")
            if userInitiated { inform(String(localized: "No se pudo buscar actualizaciones"), error.localizedDescription) }
        }
    }

    private func fetchReleases() async throws -> [ReleaseInfo] {
        var request = URLRequest(url: Self.feedURL, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Mate/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await Self.session.data(for: request)
        let releases = UpdateFeed.parse(data)
        guard (response as? HTTPURLResponse)?.statusCode == 200, !releases.isEmpty else {
            throw Failure.message(String(localized: "No se encontró una versión publicada."))
        }
        return releases
    }

    // MARK: - Installing

    /// Asks before doing anything: install now (and relaunch), see the release, or later.
    func offerInstall() {
        guard let release = available, !isInstalling else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        let version = release.version.description, current = currentVersion.description
        alert.messageText = String(localized: "Mate \(version) está disponible")
        let english = Bundle.main.preferredLocalizations.first != "es"
        let notes = ReleaseNotes.localized(release.notes, english: english)
        alert.informativeText = String(localized: "Tenés la \(current). Mate se descarga, se reemplaza y se vuelve a abrir; los permisos del llavero se mantienen.")
            + (notes.isEmpty ? "" : "\n\n" + String(localized: "Novedades:") + "\n\n" + String(notes.prefix(700)))
        alert.addButton(withTitle: String(localized: "Actualizar y reiniciar"))
        alert.addButton(withTitle: String(localized: "Ver en GitHub"))
        alert.addButton(withTitle: String(localized: "Más tarde"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: install(release)
        case .alertSecondButtonReturn: NSWorkspace.shared.open(release.page)
        default: break
        }
    }

    /// Test hook for `--debug-update`: only active while a local test feed is configured. In `--fake` runs the
    /// relaunch is replaced by quitting, so a test never opens a real Mate.
    func installForTesting() async {
        guard Self.testFeed != nil else {
            Log.error("debug-update ignored: no test feed configured")
            Self.report("debug-update ignored: set updateFeedURL in the defaults suite first")
            return
        }
        await check(userInitiated: false)
        if let release = available { Self.report("debug-update: offering \(release.version) from \(release.dmg?.absoluteString ?? "-")") }
        guard let release = available else {
            Self.report("debug-update: no newer release in the test feed")
            return
        }
        install(release)
    }

    private func install(_ release: ReleaseInfo) {
        guard let dmg = release.dmg else {
            NSWorkspace.shared.open(release.page)
            return
        }
        isInstalling = true
        let appURL = Bundle.main.bundleURL
        Log.info("Installing update \(release.version) from \(dmg.absoluteString)")
        Task.detached(priority: .userInitiated) {
            let outcome: Error?
            do {
                try await Self.downloadVerifyAndReplace(dmg: dmg, appURL: appURL, expected: release.version)
                outcome = nil
            } catch {
                outcome = error
            }
            await Updater.shared.finishInstall(outcome, release: release, appURL: appURL)
        }
    }

    private func finishInstall(_ error: Error?, release: ReleaseInfo, appURL: URL) {
        isInstalling = false
        guard let error else {
            Log.info("Updated to \(release.version); relaunching")
            if DebugCLI.isFake {
                Self.report("debug-update: installed \(release.version) at \(appURL.path); quitting (no relaunch in --fake)")
                NSApp.terminate(nil)
                return
            }
            Self.relaunch(appURL)
            return
        }
        Log.error("Update failed: \(error.localizedDescription)")
        if DebugCLI.isDebugUpdate { Self.report("debug-update failed: \(error.localizedDescription)") }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = String(localized: "No se pudo actualizar automáticamente")
        alert.informativeText = error.localizedDescription + "\n\n" + String(localized: "Podés bajar la versión nueva desde GitHub.")
        alert.addButton(withTitle: String(localized: "Abrir GitHub"))
        alert.addButton(withTitle: String(localized: "Cerrar"))
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(release.page) }
    }

    /// Off the main thread: download, mount, verify signer and version, then swap the bundle atomically.
    private nonisolated static func downloadVerifyAndReplace(dmg: URL, appURL: URL, expected: AppVersion) async throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("mate-update-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let (downloaded, response) = try await session.download(from: dmg)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.message(String(localized: "La descarga falló.")) }
        let image = work.appendingPathComponent("Mate.dmg")
        try fm.moveItem(at: downloaded, to: image)

        let mount = work.appendingPathComponent("mnt")
        try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, image.path])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", "-force", mount.path]) }

        let newApp = mount.appendingPathComponent("Mate.app")
        guard fm.fileExists(atPath: newApp.path) else { throw Failure.message(String(localized: "El DMG no contiene Mate.app.")) }
        try verifySameSigner(newApp)
        let shipped = Bundle(url: newApp)?.infoDictionary?["CFBundleShortVersionString"] as? String
        guard let version = shipped.flatMap(AppVersion.init), version == expected else {
            throw Failure.message(String(localized: "La versión descargada no coincide con la publicada."))
        }

        // Stage next to the current app (same volume) so the swap is atomic.
        let staged = appURL.deletingLastPathComponent().appendingPathComponent(".Mate-update-\(UUID().uuidString).app")
        do {
            try run("/usr/bin/ditto", [newApp.path, staged.path])
            _ = try fm.replaceItemAt(appURL, withItemAt: staged)
        } catch {
            try? fm.removeItem(at: staged)
            let path = appURL.path, reason = error.localizedDescription
            throw Failure.message(String(localized: "No se pudo reemplazar \(path): \(reason)"))
        }
    }

    /// The new app must satisfy the running app's designated requirement: same bundle id, same certificate.
    nonisolated static func verifySameSigner(_ app: URL) throws {
        var selfCode: SecCode?
        var selfStatic: SecStaticCode?
        var requirement: SecRequirement?
        var candidate: SecStaticCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode,
              SecCodeCopyStaticCode(selfCode, [], &selfStatic) == errSecSuccess, let selfStatic,
              SecCodeCopyDesignatedRequirement(selfStatic, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(app as CFURL, [], &candidate) == errSecSuccess, let candidate else {
            throw Failure.message(String(localized: "No se pudo leer la firma de las aplicaciones."))
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        let status = SecStaticCodeCheckValidity(candidate, flags, requirement)
        guard status == errSecSuccess else {
            let code = String(status)
            throw Failure.message(String(localized: "La versión descargada no está firmada con el certificado de Mate (\(code)); no se instaló."))
        }
    }

    @discardableResult
    private nonisolated static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let name = URL(fileURLWithPath: tool).lastPathComponent
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure.message(String(localized: "\(name) falló: \(detail)"))
        }
        return output
    }

    /// Quits normally (which saves the store) and reopens the new app once this process is gone.
    private static func relaunch(_ appURL: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", appURL.path]
        try? process.run()
        NSApp.terminate(nil)
    }

    /// `--debug-update` output, on stderr (unbuffered, so it is there even when the run is stopped).
    private static func report(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    private func inform(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}
