import Foundation

public struct OntRequest: Equatable, Sendable {
    public enum Method: String, Sendable { case get = "GET", post = "POST" }

    public var method: Method
    /// Path plus optional query, e.g. `/login.cgi` or `/logout.cgi?RequestFile=html/logout.html`.
    public var path: String
    /// Form fields, sent url-encoded for POST.
    public var form: [(String, String)]
    /// Adds `X-Requested-With: XMLHttpRequest` like the web UI's AJAX calls.
    public var ajax: Bool

    public init(_ method: Method, _ path: String, form: [(String, String)] = [], ajax: Bool = true) {
        self.method = method
        self.path = path
        self.form = form
        self.ajax = ajax
    }

    public static func == (a: OntRequest, b: OntRequest) -> Bool {
        a.method == b.method && a.path == b.path && a.ajax == b.ajax
            && a.form.map { $0.0 } == b.form.map { $0.0 } && a.form.map { $0.1 } == b.form.map { $0.1 }
    }

    /// `application/x-www-form-urlencoded` body; base64 `+ / =` get percent-encoded.
    public var encodedForm: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
    }
}

/// Seam between the client and the network so tests can script router replies.
public protocol OntTransport: Sendable {
    func send(_ request: OntRequest, host: String) async throws -> String
    /// Drops cookies and sets the pre-login cookie the web UI's login page sets.
    func resetSession(host: String) async
}

public final class URLSessionOntTransport: OntTransport, @unchecked Sendable {
    private let session: URLSession
    private let cookies: HTTPCookieStorage

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 20
        config.waitsForConnectivity = false
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        self.cookies = config.httpCookieStorage ?? HTTPCookieStorage.shared
        self.session = URLSession(configuration: config)
    }

    public func resetSession(host: String) async {
        for cookie in cookies.cookies ?? [] { cookies.deleteCookie(cookie) }
        // The login page sets this before posting credentials; the router
        // replaces it with `Cookie=sid=...` on a successful login.
        if let cookie = HTTPCookie(properties: [
            .name: "Cookie",
            .value: "body:Language:english:id=-1",
            .domain: host,
            .path: "/",
        ]) {
            cookies.setCookie(cookie)
        }
    }

    public func send(_ request: OntRequest, host: String) async throws -> String {
        guard let url = URL(string: "http://\(host)\(request.path)") else { throw URLError(.badURL) }
        var r = URLRequest(url: url)
        r.httpMethod = request.method.rawValue
        r.cachePolicy = .reloadIgnoringLocalCacheData
        r.setValue("http://\(host)", forHTTPHeaderField: "Origin")
        r.setValue("http://\(host)/", forHTTPHeaderField: "Referer")
        if request.ajax { r.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With") }
        if request.method == .post {
            r.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            r.httpBody = Data(request.encodedForm.utf8)
        }
        let (data, response) = try await session.data(for: r)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
