import Foundation

public typealias BingSleep = @Sendable (Duration) async throws -> Void

// MARK: - HTTP transport

public struct BingHTTPRequest: Hashable, Sendable {
    public let url: URL
    public let headers: [String: String]
    public let timeout: TimeInterval
    public let maximumBytes: Int

    public init(
        url: URL,
        headers: [String: String] = [:],
        timeout: TimeInterval = 25,
        maximumBytes: Int = 1_048_576
    ) {
        self.url = url
        self.headers = headers
        self.timeout = timeout
        self.maximumBytes = maximumBytes
    }
}

public struct BingHTTPResponse: Hashable, Sendable {
    public let data: Data
    public let statusCode: Int
    public let headers: [String: String]
    public let finalURL: URL

    public init(data: Data, statusCode: Int, headers: [String: String], finalURL: URL) {
        self.data = data
        self.statusCode = statusCode
        self.headers = headers.reduce(into: [String: String]()) { result, pair in
            result[pair.key.lowercased()] = pair.value
        }
        self.finalURL = finalURL
    }

    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

public protocol BingHTTPTransport: Sendable {
    func perform(_ request: BingHTTPRequest) async throws -> BingHTTPResponse
}

public enum BingTransportError: Error, Hashable, Sendable {
    case responseTooLarge(limit: Int)
    case blockedURL(host: String?)
    case nonHTTPResponse
    case transport(code: Int?)
}

/// Exact-host HTTPS policy. Every request URL and every redirect hop is
/// checked; no wildcard or suffix matching is used.
public struct BingRedirectPolicy: Hashable, Sendable {
    public let allowedHosts: Set<String>

    public init(allowedHosts: Set<String>) {
        self.allowedHosts = Set(allowedHosts.compactMap { host -> String? in
            let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return trimmed.isEmpty ? nil : trimmed
        })
    }

    public func allows(_ url: URL?) -> Bool {
        guard let url,
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              allowedHosts.contains(host)
        else { return false }
        if let user = url.user, !user.isEmpty { return false }
        if let password = url.password, !password.isEmpty { return false }
        if let port = url.port, port != 443 { return false }
        return true
    }
}

/// Production transport. The redirect delegate is also the final defence for
/// 30x responses; the provider validates `finalURL` again before decoding.
public struct URLSessionBingTransport: BingHTTPTransport, Sendable {
    private let redirectPolicy: BingRedirectPolicy

    public init(redirectPolicy: BingRedirectPolicy) {
        self.redirectPolicy = redirectPolicy
    }

    public func perform(_ request: BingHTTPRequest) async throws -> BingHTTPResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = request.timeout
        configuration.timeoutIntervalForResource = max(request.timeout * 2, 30)
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false

        let delegate = BingRedirectDelegate(policy: redirectPolicy)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var urlRequest = URLRequest(url: request.url, timeoutInterval: request.timeout)
        urlRequest.httpMethod = "GET"
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let (bytes, response) = try await session.bytes(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw BingTransportError.nonHTTPResponse
        }
        let finalURL = http.url ?? request.url
        guard redirectPolicy.allows(finalURL) else {
            throw BingTransportError.blockedURL(host: finalURL.host)
        }
        if let lengthText = http.value(forHTTPHeaderField: "Content-Length"),
           let length = Int64(lengthText),
           length > Int64(request.maximumBytes) {
            throw BingTransportError.responseTooLarge(limit: request.maximumBytes)
        }

        let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, entry in
            guard let name = entry.key as? String else { return }
            result[name.lowercased()] = String(describing: entry.value)
        }

        guard (200..<300).contains(http.statusCode) else {
            // Do not buffer error bodies; Retry-After lives in the headers.
            return BingHTTPResponse(
                data: Data(),
                statusCode: http.statusCode,
                headers: headers,
                finalURL: finalURL
            )
        }

        var data = Data()
        data.reserveCapacity(min(request.maximumBytes, 1_048_576))
        for try await byte in bytes {
            try Task.checkCancellation()
            data.append(byte)
            if data.count > request.maximumBytes {
                throw BingTransportError.responseTooLarge(limit: request.maximumBytes)
            }
        }
        return BingHTTPResponse(
            data: data,
            statusCode: http.statusCode,
            headers: headers,
            finalURL: finalURL
        )
    }
}

private final class BingRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let policy: BingRedirectPolicy

    init(policy: BingRedirectPolicy) {
        self.policy = policy
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        if policy.allows(request.url) {
            completionHandler(request)
        } else {
            // Returning nil delivers the original 30x response. The provider
            // rejects it instead of following an unverified host.
            completionHandler(nil)
        }
    }
}
