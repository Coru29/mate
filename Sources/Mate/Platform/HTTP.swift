import Foundation

enum HTTP {
    /// Follows a redirect only within the original host, so a token never leaves its provider's host.
    private final class SameHostRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            let from = task.originalRequest?.url?.host?.lowercased()
            let to = request.url?.host?.lowercased()
            completionHandler(from != nil && from == to && request.url?.scheme == "https" ? request : nil)
        }
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 20
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpCookieStorage = nil
        c.httpAdditionalHeaders = ["User-Agent": userAgent]
        return URLSession(configuration: c, delegate: SameHostRedirects(), delegateQueue: nil)
    }()

    static let userAgent: String = {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "Mate/\(v)"
    }()

    /// Body and status code. Transport failures throw; any HTTP status (a refused redirect comes back as its 3xx)
    /// is returned to the caller to interpret.
    static func json(_ req: URLRequest) async throws -> (Data, Int) {
        var req = req
        req.timeoutInterval = 20
        if req.value(forHTTPHeaderField: "Accept") == nil { req.setValue("application/json", forHTTPHeaderField: "Accept") }
        let (data, response) = try await session.data(for: req)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
