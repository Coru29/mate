import AppKit
import Network
import SwiftUI
import MateCore

/// "Agregar cuenta…": the providers' own OAuth sign-in in the default browser, without touching the agent's session.
/// Codes and tokens are never logged. Each flow times out after 5 minutes; cancelling closes its window and listener.
@MainActor
enum OAuthLogin {
    static let timeout: TimeInterval = 300

    /// Claude: the user pastes the "code#state" Anthropic shows; identity from the OAuth profile.
    static func claude() async throws -> (OAuthTokens, identity: String, email: String?) {
        let pkce = PKCE.random()
        let state = PKCE.randomToken()
        let url = ClaudeLogin.authorizeURL(clientID: ClaudeProvider.clientID, challenge: pkce.challenge, state: state)
        let prompt = LoginPrompt(
            title: String(localized: "Agregar cuenta de Claude"),
            message: String(localized: "Entrá con tu cuenta en el navegador. Al terminar, Anthropic te muestra un código: copialo y pegalo acá."),
            url: url, asksForCode: true)
        defer { prompt.close() }
        NSWorkspace.shared.open(url)
        return try await run(prompt) {
            while true {
                let code = try await prompt.code { try ClaudeLogin.code(fromPasted: $0, expectedState: state) }
                var req = URLRequest(url: ClaudeProvider.tokenURL)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try ClaudeLogin.exchangeBody(code: code, state: state, verifier: pkce.verifier,
                                                            clientID: ClaudeProvider.clientID)
                let (data, status) = try await HTTP.json(req)
                if status == 400 || status == 401 {
                    // A used or mistyped code: the same sign-in can go on with a new one.
                    prompt.reject(String(localized: "Anthropic no aceptó ese código. Abrí el navegador de nuevo y pegá el código nuevo."))
                    continue
                }
                try ProviderError.check(status: status)
                let tokens = try ClaudeTokenResponse.tokens(from: data, previous: OAuthTokens(accessToken: ""), now: Date())
                let identity = try await ClaudeProvider.profile(accessToken: tokens.accessToken)
                return (tokens, identity.uuid, identity.email)
            }
        }
    }

    /// Codex: loopback callback on 127.0.0.1:1455; identity from the id_token's ChatGPT account id.
    static func codex() async throws -> (OAuthTokens, identity: String, email: String?) {
        let pkce = PKCE.random()
        let state = PKCE.randomToken()
        let url = CodexLogin.authorizeURL(challenge: pkce.challenge, state: state)
        let server = LoopbackServer(port: CodexLogin.port, expectedState: state)
        let prompt = LoginPrompt(
            title: String(localized: "Agregar cuenta de Codex"),
            message: String(localized: "Entrá con tu cuenta de ChatGPT en el navegador. Mate sigue solo cuando termines."),
            url: url, asksForCode: false)
        defer {
            server.stop()
            prompt.close()
        }
        return try await run(prompt, onCancel: { server.stop() }) {
            try await server.start()
            NSWorkspace.shared.open(url)
            let callback = try await server.code()
            do {
                var req = URLRequest(url: CodexLogin.tokenURL)
                req.httpMethod = "POST"
                req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                req.httpBody = CodexLogin.exchangeBody(code: callback.code, verifier: pkce.verifier)
                let (data, status) = try await HTTP.json(req)
                if status == 400 || status == 401 { throw LoginError.denied("token_exchange_failed") }
                try ProviderError.check(status: status)
                let tokens = try CodexTokenResponse.tokens(from: data, previous: OAuthTokens(accessToken: ""))
                guard let identity = tokens.extra["id_token"].flatMap(CodexIdentity.from(idToken:)) else {
                    throw LoginError.denied("missing_account_id")
                }
                callback.respond(true)
                return (tokens, identity.identity, identity.email)
            } catch {
                callback.respond(false)
                throw error
            }
        }
    }

    /// Runs the whole sign-in `body` (port binding, waits and network included) raced against the prompt's
    /// "Cancelar" and the 5-minute timeout. Whichever ends first wins and the others are cancelled, so a cancelled
    /// or timed-out sign-in never returns tokens. `onCancel` unblocks waits that do not follow task cancellation.
    private static func run<T: Sendable>(_ prompt: LoginPrompt, onCancel: @escaping @MainActor () -> Void = {},
                                         _ body: @escaping @MainActor () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { @MainActor in
                try await withTaskCancellationHandler { try await body() } onCancel: {
                    Task { @MainActor in
                        prompt.cancel()
                        onCancel()
                    }
                }
            }
            group.addTask { @MainActor () async throws -> T in try await prompt.waitForCancel() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw LoginError.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}

extension LoginError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidCode: String(localized: "El código está incompleto. Copialo entero, con el # del medio.")
        case .stateMismatch: String(localized: "Ese código es de otro inicio de sesión. Usá el de la página que abrió Mate.")
        case .denied: String(localized: "El inicio de sesión no se completó.")
        case .timedOut: String(localized: "Pasaron 5 minutos sin terminar el inicio de sesión.")
        case .cancelled: String(localized: "Inicio de sesión cancelado.")
        case .portInUse: String(localized: "Hay otro inicio de sesión de Codex abierto (el puerto 1455 está ocupado). Cerralo y probá de nuevo.")
        }
    }
}

// MARK: - Loopback server (Codex)

/// One-shot HTTP listener on 127.0.0.1 for the OAuth redirect. Answers other requests with 404 and keeps waiting.
final class LoopbackServer: @unchecked Sendable {
    /// The callback's code and a way to answer the browser once the exchange is done.
    struct Callback: Sendable {
        let code: String
        let respond: @Sendable (_ success: Bool) -> Void
    }

    private let port: UInt16
    private let expectedState: String
    private let queue = DispatchQueue(label: "io.github.coru29.Mate.oauth")
    private var listener: NWListener?
    private var waiter: CheckedContinuation<Callback, Error>?
    /// A result that arrived before `code()` was awaited.
    private var early: Result<Callback, Error>?
    private var delivered = false
    private var stopped = false

    init(port: UInt16, expectedState: String) {
        self.port = port
        self.expectedState = expectedState
    }

    /// Binds the port; throws `.portInUse` when another sign-in holds it. Retries once after a moment, for the
    /// listener of a sign-in that was just cancelled, which lets go of the port asynchronously.
    func start() async throws {
        do {
            try await bind()
        } catch LoginError.portInUse {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            try await bind()
        }
    }

    private func bind() async throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: params)
        let alreadyStopped = queue.sync {
            if !stopped { self.listener = listener }
            return stopped
        }
        if alreadyStopped { throw LoginError.cancelled }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let started = Answered()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if started.once() { c.resume() }
                case .failed(let error):
                    let mapped: Error = error == .posix(.EADDRINUSE) ? LoginError.portInUse : error
                    listener.cancel()
                    if started.once() { c.resume(throwing: mapped) } else { self?.finish(.failure(mapped)) }
                case .cancelled:
                    if started.once() { c.resume(throwing: LoginError.cancelled) }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            listener.start(queue: queue)
        }
    }

    func code() async throws -> Callback {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Callback, Error>) in
                queue.async {
                    if let early = self.early { c.resume(with: early); return }
                    if self.stopped { c.resume(throwing: LoginError.cancelled); return }
                    self.waiter = c
                }
            }
        } onCancel: {
            self.stop()
        }
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.listener?.cancel()
            self.listener = nil
            self.finish(.failure(LoginError.cancelled))
        }
    }

    /// Queue only.
    private func finish(_ result: Result<Callback, Error>) {
        guard !delivered else { return }
        delivered = true
        if let w = waiter {
            waiter = nil
            w.resume(with: result)
        } else {
            early = result
        }
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            let head = String(decoding: buffer, as: UTF8.self)
            guard head.contains("\r\n\r\n") || isComplete || error != nil || buffer.count > 65_536 else {
                self.receive(conn, buffer: buffer)
                return
            }
            self.handle(head, conn)
        }
    }

    private func handle(_ head: String, _ conn: NWConnection) {
        switch CodexLogin.callback(requestHead: head, expectedState: expectedState) {
        case .notCallback:
            Self.send(conn, status: "404 Not Found", body: "")
        case .stateMismatch:
            Self.send(conn, status: "400 Bad Request", body: Self.page(String(localized: "Este inicio de sesión no es el que abrió Mate.")))
        case .denied(let why):
            Self.send(conn, status: "200 OK", body: Self.page(String(localized: "El inicio de sesión no se completó.")))
            finish(.failure(LoginError.denied(why)))
        case .code(let code):
            guard !delivered else {
                Self.send(conn, status: "409 Conflict", body: "")
                return
            }
            let queue = self.queue
            let answered = Answered()
            finish(.success(Callback(code: code) { success in
                queue.async {
                    guard answered.once() else { return }
                    let text = success ? String(localized: "Listo, ya podés volver a Mate")
                                       : String(localized: "El inicio de sesión no se completó.")
                    Self.send(conn, status: "200 OK", body: Self.page(text))
                }
            }))
        }
    }

    /// True on the first call only (state handlers and answers run on `queue`).
    private final class Answered: @unchecked Sendable {
        private var done = false
        func once() -> Bool { defer { done = true }; return !done }
    }

    private static func page(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        return """
        <!doctype html><html lang="es"><head><meta charset="utf-8"><title>Mate</title>\
        <style>body{font:17px -apple-system,system-ui,sans-serif;display:flex;align-items:center;justify-content:center;\
        height:100vh;margin:0;background:#111;color:#eee}</style></head><body><p>\(escaped)</p></body></html>
        """
    }

    private static func send(_ conn: NWConnection, status: String, body: String) {
        let bytes = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bytes.count)\r\n"
            + "Connection: close\r\nCache-Control: no-store\r\n\r\n"
        conn.send(content: Data(head.utf8) + bytes, completion: .contentProcessed { _ in conn.cancel() })
    }
}

// MARK: - Prompt window

/// The small window of a sign-in: the explanation, "Abrir el navegador de nuevo", for Claude the code field, and
/// "Cancelar". Closing it cancels the sign-in.
@MainActor
final class LoginPrompt: NSObject, NSWindowDelegate {
    final class Model: ObservableObject {
        @Published var code = ""
        @Published var error: String?
        @Published var busy = false
    }

    private let model = Model()
    private let url: URL
    private let asksForCode: Bool
    private var window: NSWindow?
    private var validate: ((String) throws -> String)?
    private var codeWaiter: CheckedContinuation<String, Error>?
    private var cancelWaiter: CheckedContinuation<Void, Error>?
    private var cancelled = false

    init(title: String, message: String, url: URL, asksForCode: Bool) {
        self.url = url
        self.asksForCode = asksForCode
        super.init()
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 10), styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = title
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.level = .floating
        let view = LoginPromptView(model: model, message: message, asksForCode: asksForCode,
                                   onSubmit: { [weak self] in self?.submit() },
                                   onReopen: { [weak self] in if let u = self?.url { NSWorkspace.shared.open(u) } },
                                   onCancel: { [weak self] in self?.cancel() })
        let hosting = NSHostingView(rootView: view)
        w.contentView = hosting
        w.setContentSize(hosting.fittingSize)
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Waits for a pasted code that `validate` accepts (its errors are shown and the user can try again).
    func code(validate: @escaping (String) throws -> String) async throws -> String {
        if cancelled { throw LoginError.cancelled }
        self.validate = validate
        return try await withCheckedThrowingContinuation { codeWaiter = $0 }
    }

    /// Returns only by throwing: `.cancelled` when the user cancels, `CancellationError` when the task is cancelled.
    func waitForCancel() async throws -> Never {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                if cancelled { c.resume(throwing: LoginError.cancelled) } else { cancelWaiter = c }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelWaiter?.resume(throwing: CancellationError())
                self?.cancelWaiter = nil
            }
        }
        throw LoginError.cancelled // not reached: the continuation only ever throws
    }

    private func submit() {
        guard let validate, let waiter = codeWaiter else { return }
        do {
            let code = try validate(model.code)
            model.error = nil
            model.busy = true
            codeWaiter = nil
            waiter.resume(returning: code)
        } catch {
            model.error = error.localizedDescription
        }
    }

    /// The provider refused the accepted code: show `message` and wait for another one.
    func reject(_ message: String) {
        model.busy = false
        model.code = ""
        model.error = message
    }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        codeWaiter?.resume(throwing: LoginError.cancelled)
        codeWaiter = nil
        cancelWaiter?.resume(throwing: LoginError.cancelled)
        cancelWaiter = nil
        close()
    }

    func close() {
        guard let w = window else { return }
        window = nil
        w.delegate = nil
        w.close()
        w.contentView = nil
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        cancel()
    }
}

private struct LoginPromptView: View {
    @ObservedObject var model: LoginPrompt.Model
    let message: String
    let asksForCode: Bool
    let onSubmit: () -> Void
    let onReopen: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: message)
                .fixedSize(horizontal: false, vertical: true)
            if asksForCode {
                TextField("Código", text: $model.code)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(onSubmit)
                    .disabled(model.busy)
            }
            if let error = model.error {
                Text(verbatim: error)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Abrir el navegador de nuevo", action: onReopen)
                    .disabled(model.busy)
                Spacer()
                if model.busy || !asksForCode { ProgressView().controlSize(.small) }
                Button("Cancelar", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                if asksForCode {
                    Button("Continuar", action: onSubmit)
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.busy || model.code.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
