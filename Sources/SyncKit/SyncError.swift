import Foundation

/// The server's RFC 7807 error document.
///
/// `requestId` is the useful bit when something goes wrong in the field: it
/// lets a failure here be matched to a line in the server's log.
public struct ProblemDetails: Sendable, Equatable {
    public var type: String?
    public var title: String?
    public var detail: String?
    public var code: String?
    public var requestId: String?
    public var retryable: Bool?

    public init?(data: Data) {
        guard let value = try? CanonicalJSON.decode(data), value.objectValue != nil else {
            return nil
        }
        type = value["type"]?.stringValue
        title = value["title"]?.stringValue
        detail = value["detail"]?.stringValue
        code = value["code"]?.stringValue
        requestId = value["requestId"]?.stringValue
        retryable = value["retryable"]?.boolValue
        // Anything without at least a code or title isn't a problem document.
        if code == nil && title == nil && type == nil { return nil }
    }

    /// Human-readable, with the request id kept so it can be quoted verbatim.
    public var summary: String {
        var parts: [String] = []
        if let title { parts.append(title) }
        if let detail, detail != title { parts.append(detail) }
        if let code { parts.append("[\(code)]") }
        if let requestId { parts.append("request \(requestId)") }
        return parts.isEmpty ? "unknown error" : parts.joined(separator: " · ")
    }
}

/// Failures the engine has to tell apart, because the correct response differs:
/// retry, re-pair, resnapshot, or stop and surface.
public enum SyncError: Error, Equatable {
    /// Timeouts, connection loss, 429, retryable 5xx.
    case transient(status: Int?, retryAfter: TimeInterval?, detail: String)
    /// 401 — credential missing or revoked. Return to pairing, keep local data.
    case unauthorized
    /// 403 — scope denial, or a pairing code that was invalid/expired/used.
    case forbidden(detail: String)
    /// 410 — snapshot token or change cursor no longer valid.
    case gone(detail: String)
    /// 409 on a tus PATCH: the local offset was stale.
    case offsetConflict(serverOffset: Int?)
    /// 460: the chunk checksum failed.
    case checksumMismatch(serverOffset: Int?)
    /// Other 4xx — the request must be corrected, not blindly retried.
    case permanent(status: Int, detail: String)
    case malformedResponse(String)
    /// Downloaded bytes failed size or digest verification.
    case corruptDownload(expected: String, actual: String)
    case notPaired
    case cancelled

    public var isRetryable: Bool {
        if case .transient = self { return true }
        return false
    }

    public var requiresRepairing: Bool { self == .unauthorized }

    public var retryAfter: TimeInterval? {
        if case .transient(_, let after, _) = self { return after }
        return nil
    }

    /// Maps an HTTP status onto the taxonomy above.
    ///
    /// The server answers failures with RFC 7807 problem documents that carry an
    /// explicit `retryable` flag; when present that beats guessing from the
    /// status code, since only the server knows whether a 5xx is worth another
    /// attempt.
    public static func from(status: Int, retryAfter: TimeInterval?, body: String,
                            problem: ProblemDetails? = nil) -> SyncError {
        let detail = problem?.summary ?? body

        if status == 401 { return .unauthorized }
        if status == 410 { return .gone(detail: detail) }
        if status == 409 { return .offsetConflict(serverOffset: nil) }
        if status == 460 { return .checksumMismatch(serverOffset: nil) }

        if let retryable = problem?.retryable {
            if retryable {
                return .transient(status: status, retryAfter: retryAfter, detail: detail)
            }
            // Explicitly not retryable, even if the status would suggest otherwise.
            if status == 403 { return .forbidden(detail: detail) }
            if status >= 400 { return .permanent(status: status, detail: detail) }
        }

        switch status {
        case 403: return .forbidden(detail: detail)
        case 429: return .transient(status: status, retryAfter: retryAfter, detail: detail)
        case 500, 502, 503, 504:
            return .transient(status: status, retryAfter: retryAfter, detail: detail)
        case 400...499: return .permanent(status: status, detail: detail)
        default:
            if status >= 500 {
                return .transient(status: status, retryAfter: retryAfter, detail: detail)
            }
            return .permanent(status: status, detail: detail)
        }
    }

    /// URLSession failures that mean "the network moved", not "the request was wrong".
    public static func from(urlError: URLError) -> SyncError {
        switch urlError.code {
        case .timedOut, .cannotConnectToHost, .networkConnectionLost,
             .notConnectedToInternet, .dnsLookupFailed, .cannotFindHost,
             .resourceUnavailable, .internationalRoamingOff, .callIsActive,
             .dataNotAllowed, .secureConnectionFailed:
            return .transient(status: nil, retryAfter: nil, detail: urlError.localizedDescription)
        case .cancelled:
            return .cancelled
        default:
            return .transient(status: nil, retryAfter: nil, detail: urlError.localizedDescription)
        }
    }
}

/// Exponential backoff with full jitter, capped, honouring `Retry-After`.
public struct RetryPolicy: Sendable {
    public var maxAttempts: Int
    public var baseDelay: TimeInterval
    public var maxDelay: TimeInterval
    /// Injectable so tests are deterministic and instant.
    public var jitter: @Sendable (TimeInterval) -> TimeInterval

    public init(maxAttempts: Int = 6,
                baseDelay: TimeInterval = 0.5,
                maxDelay: TimeInterval = 30,
                jitter: @escaping @Sendable (TimeInterval) -> TimeInterval = { .random(in: 0...$0) }) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.jitter = jitter
    }

    /// No waiting and no randomness — for tests that assert attempt counts.
    public static let immediate = RetryPolicy(maxAttempts: 3, baseDelay: 0,
                                              maxDelay: 0, jitter: { _ in 0 })

    public func delay(forAttempt attempt: Int, retryAfter: TimeInterval?) -> TimeInterval {
        if let retryAfter { return min(retryAfter, maxDelay) }
        let exponential = min(maxDelay, baseDelay * pow(2, Double(max(0, attempt - 1))))
        return jitter(exponential)
    }
}

/// Runs `operation`, retrying only what the taxonomy says is retryable.
public func withRetry<T: Sendable>(policy: RetryPolicy,
                                   sleeper: @Sendable (TimeInterval) async throws -> Void = {
                                       try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
                                   },
                                   operation: @Sendable () async throws -> T) async throws -> T {
    var attempt = 0
    while true {
        attempt += 1
        do {
            return try await operation()
        } catch let error as SyncError {
            guard error.isRetryable, attempt < policy.maxAttempts else { throw error }
            let wait = policy.delay(forAttempt: attempt, retryAfter: error.retryAfter)
            if wait > 0 { try await sleeper(wait) }
        } catch let error as URLError {
            let mapped = SyncError.from(urlError: error)
            guard mapped.isRetryable, attempt < policy.maxAttempts else { throw mapped }
            let wait = policy.delay(forAttempt: attempt, retryAfter: nil)
            if wait > 0 { try await sleeper(wait) }
        }
    }
}
