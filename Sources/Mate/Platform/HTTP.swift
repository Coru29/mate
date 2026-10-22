import Foundation

enum HTTP {
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 20
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpCookieStorage = nil
        c.httpAdditionalHeaders = ["User-Agent": userAgent]
        return URLSession(configuration: c)
    }()

    static let userAgent: String = {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "Mate/\(v)"
    }()

    /// Body and status code. Transport failures throw; any HTTP status is returned to the caller to interpret.
    static func json(_ req: URLRequest) async throws -> (Data, Int) {
        var req = req
        req.timeoutInterval = 20
        if req.value(forHTTPHeaderField: "Accept") == nil { req.setValue("application/json", forHTTPHeaderField: "Accept") }
        let (data, response) = try await session.data(for: req)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
