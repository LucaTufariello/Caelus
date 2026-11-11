//
//  CelesTrakClient.swift
//  SatTracker
//
//  Fetches GP element sets from CelesTrak.
//
//  CelesTrak serves each group at most once every two hours per client. A
//  repeat request inside that window answers 403 with a plain-text explanation
//  ("GP data has not updated since your last successful download …"). That is a
//  cache hit, not a failure, and is surfaced as `.unchanged`.
//

import Foundation

actor CelesTrakClient {

    // MARK: - Types

    enum FetchError: Error, Sendable, Equatable {
        /// The server answered with something we cannot use.
        case http(status: Int, body: String)
        /// Transport-level failure: timeout, offline, DNS, TLS.
        case transport(String)
        /// A previous failure scheduled a retry that has not come due yet.
        case backedOff(until: Date)
        /// The body arrived but did not look like element sets.
        case malformed(String)

        var isRetryable: Bool {
            switch self {
            case .transport, .http(status: 500..., body: _): true
            default: false
            }
        }

        var shortDescription: String {
            switch self {
            case .http(let status, _): "HTTP \(status)"
            case .transport(let message): message
            case .backedOff(let until): "retry after \(until.formatted(date: .omitted, time: .shortened))"
            case .malformed(let message): message
            }
        }
    }

    struct Backoff: Sendable {
        /// Delays applied after consecutive failures.
        static let ladder: [TimeInterval] = [60, 5 * 60, 30 * 60]

        var consecutiveFailures = 0
        var nextAttempt: Date = .distantPast

        mutating func recordFailure(now: Date = Date()) {
            consecutiveFailures += 1
            let index = min(consecutiveFailures - 1, Backoff.ladder.count - 1)
            nextAttempt = now.addingTimeInterval(Backoff.ladder[index])
        }

        mutating func recordSuccess() {
            consecutiveFailures = 0
            nextAttempt = .distantPast
        }
    }

    // MARK: - State

    private let session: URLSession
    private let userAgent: String
    private var backoff: [String: Backoff] = [:]
    private var etags: [String: String] = [:]

    init(userAgent: String = "SatTracker/0.1 (macOS; personal use)",
         timeout: TimeInterval = 30) {
        self.userAgent = userAgent

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpAdditionalHeaders = ["User-Agent": userAgent]
        self.session = URLSession(configuration: configuration)
    }

    // MARK: - Public API

    /// Ask for one group. Returns `.unchanged` when CelesTrak says the data has
    /// not moved since the last download; the caller keeps its cache.
    func fetch(group: String) async throws -> FetchOutcome {
        let now = Date()
        if let state = backoff[group], now < state.nextAttempt {
            throw FetchError.backedOff(until: state.nextAttempt)
        }

        var request = URLRequest(url: Self.url(for: group))
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        if let etag = etags[group] {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            var state = backoff[group] ?? Backoff()
            state.recordFailure()
            backoff[group] = state
            throw FetchError.transport(Self.describe(error))
        }

        guard let http = response as? HTTPURLResponse else {
            throw FetchError.transport("no HTTP response")
        }

        switch http.statusCode {
        case 200:
            guard let text = String(data: data, encoding: .utf8) else {
                throw FetchError.malformed("response was not UTF-8")
            }
            guard Self.looksLikeElements(text) else {
                throw FetchError.malformed("response did not contain element sets")
            }
            if let etag = http.value(forHTTPHeaderField: "ETag") { etags[group] = etag }
            backoff[group]?.recordSuccess()
            if backoff[group] == nil { backoff[group] = Backoff() }
            return .updated(text)

        case 304:
            backoff[group]?.recordSuccess()
            return .unchanged(group)

        case 403:
            let body = String(data: data, encoding: .utf8) ?? ""
            if Self.isNotUpdated(body) {
                // Not a failure: the two-hour window has not elapsed.
                backoff[group]?.recordSuccess()
                return .unchanged(group)
            }
            var state = backoff[group] ?? Backoff()
            state.recordFailure()
            backoff[group] = state
            throw FetchError.http(status: 403, body: Self.trim(body))

        case 404:
            throw FetchError.http(status: 404, body: Self.trim(String(data: data, encoding: .utf8) ?? ""))

        default:
            var state = backoff[group] ?? Backoff()
            state.recordFailure()
            backoff[group] = state
            throw FetchError.http(status: http.statusCode,
                                  body: Self.trim(String(data: data, encoding: .utf8) ?? ""))
        }
    }

    /// When the next attempt for a group is allowed, if it is being held back.
    func nextAttempt(for group: String) -> Date? {
        guard let state = backoff[group], state.nextAttempt > Date() else { return nil }
        return state.nextAttempt
    }

    func resetBackoff() {
        backoff.removeAll()
    }

    // MARK: - Helpers

    static func url(for group: String) -> URL {
        var components = URLComponents(string: "https://celestrak.org/NORAD/elements/gp.php")!
        components.queryItems = [
            URLQueryItem(name: "GROUP", value: group),
            URLQueryItem(name: "FORMAT", value: "tle"),
        ]
        return components.url!
    }

    /// A usable body contains at least one line-1 record.
    static func looksLikeElements(_ text: String) -> Bool {
        text.split(whereSeparator: \.isNewline).contains { $0.hasPrefix("1 ") }
    }

    static func isNotUpdated(_ body: String) -> Bool {
        let lowered = body.lowercased()
        return lowered.contains("has not updated") || lowered.contains("not updated since")
    }

    private static func trim(_ body: String) -> String {
        let line = body.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return String(line.prefix(160))
    }

    private static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return "timed out"
            case .notConnectedToInternet: return "no internet connection"
            case .cannotFindHost, .cannotConnectToHost: return "host unreachable"
            case .networkConnectionLost: return "connection lost"
            default: return urlError.localizedDescription
            }
        }
        return error.localizedDescription
    }
}
