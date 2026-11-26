import Foundation

struct BingRequestExecutor: Sendable {
    private let transport: any BingHTTPTransport
    private let configuration: BingProviderConfiguration
    private let sleep: BingSleep

    init(
        transport: any BingHTTPTransport,
        configuration: BingProviderConfiguration,
        sleep: @escaping BingSleep
    ) {
        self.transport = transport
        self.configuration = configuration
        self.sleep = sleep
    }

    func perform(
        _ request: BingHTTPRequest,
        policy: BingRedirectPolicy
    ) async throws -> BingHTTPResponse {
        var attempt = 0
        while true {
            attempt += 1
            try Task.checkCancellation()

            do {
                let response = try await transport.perform(request)
                try Task.checkCancellation()

                guard policy.allows(response.finalURL) else {
                    throw BingProviderError.blockedURL(host: response.finalURL.host)
                }
                if let lengthText = response.header("Content-Length"),
                   let length = Int64(lengthText),
                   length > Int64(request.maximumBytes) {
                    throw BingProviderError.responseTooLarge(limit: request.maximumBytes)
                }
                guard response.data.count <= request.maximumBytes else {
                    throw BingProviderError.responseTooLarge(limit: request.maximumBytes)
                }
                guard (200..<300).contains(response.statusCode) else {
                    if (300..<400).contains(response.statusCode) {
                        let locationHost = response.header("Location")
                            .flatMap { URL(string: $0)?.host }
                        throw BingProviderError.unexpectedRedirect(
                            statusCode: response.statusCode,
                            locationHost: locationHost
                        )
                    }
                    throw BingProviderError.httpStatus(
                        code: response.statusCode,
                        retryAfterSeconds: Self.retryAfterSeconds(response.header("Retry-After"))
                    )
                }
                return response
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as BingProviderError {
                guard attempt < configuration.maximumAttempts,
                      Self.isRetryable(error)
                else { throw error }
                try await sleep(retryDelay(attempt: attempt, error: error))
            } catch {
                if Task.isCancelled { throw CancellationError() }
                let mapped = Self.providerError(from: error)
                guard attempt < configuration.maximumAttempts,
                      Self.isRetryable(mapped)
                else { throw mapped }
                try await sleep(retryDelay(attempt: attempt, error: mapped))
            }
        }
    }

    private func retryDelay(attempt: Int, error: BingProviderError) -> Duration {
        let cap = BingProviderConfiguration.nanoseconds(configuration.maximumRetryDelay)
        if case .httpStatus(_, let retryAfter) = error,
           let retryAfterSeconds = retryAfter {
            let seconds = min(max(0, retryAfterSeconds), 60)
            let nanoseconds = UInt64(seconds * 1_000_000_000)
            return .nanoseconds(Int64(min(nanoseconds, cap)))
        }
        let base = BingProviderConfiguration.nanoseconds(configuration.initialRetryDelay)
        let exponent = min(max(0, attempt - 1), 10)
        let multiplier = UInt64(1) << UInt64(exponent)
        let (product, overflow) = base.multipliedReportingOverflow(by: multiplier)
        let bounded = overflow ? cap : min(product, cap)
        return .nanoseconds(Int64(bounded))
    }

    private static func isRetryable(_ error: BingProviderError) -> Bool {
        switch error {
        case .transport:
            return true
        case .httpStatus(let code, _):
            return code == 408 || code == 425 || code == 429 || (500...599).contains(code)
        default:
            return false
        }
    }

    static func providerError(from error: Error) -> BingProviderError {
        if let provider = error as? BingProviderError { return provider }
        if let transport = error as? BingTransportError {
            switch transport {
            case .responseTooLarge(let limit):
                return .responseTooLarge(limit: limit)
            case .blockedURL(let host):
                return .blockedURL(host: host)
            case .nonHTTPResponse:
                return .transport(code: nil)
            case .transport(let code):
                return .transport(code: code)
            }
        }
        if let urlError = error as? URLError {
            return .transport(code: urlError.code.rawValue)
        }
        return .transport(code: nil)
    }

    private static func retryAfterSeconds(_ raw: String?) -> Double? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if let seconds = Double(raw), seconds.isFinite {
            return max(0, seconds)
        }
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEEE, dd-MMM-yy HH:mm:ss zzz",
            "EEE MMM d HH:mm:ss yyyy"
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) {
                return max(0, date.timeIntervalSinceNow)
            }
        }
        return nil
    }
}
