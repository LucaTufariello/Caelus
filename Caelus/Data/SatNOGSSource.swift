//
//  SatNOGSSource.swift
//  Caelus
//
//  Fallback element source used when CelesTrak is unreachable.
//  SatNOGS publishes the same two-line elements as JSON; we re-emit them as a
//  three-line document so a single parser handles every source.
//

import Foundation

enum SatNOGSSource {

    enum SourceError: Error, Sendable {
        case transport(String)
        case http(Int)
        case malformed(String)

        var shortDescription: String {
            switch self {
            case .transport(let m): m
            case .http(let s): "HTTP \(s)"
            case .malformed(let m): m
            }
        }
    }

    private struct Entry: Decodable {
        let tle0: String
        let tle1: String
        let tle2: String
        let norad_cat_id: Int
    }

    static let endpoint = URL(string: "https://db.satnogs.org/api/tle/")!

    /// Download every element set SatNOGS holds and render them as 3LE text.
    static func fetchTLE(timeout: TimeInterval = 120) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = timeout
        request.setValue("Caelus/0.1 (macOS; personal use)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SourceError.transport(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw SourceError.http(http.statusCode)
        }

        let entries: [Entry]
        do {
            entries = try JSONDecoder().decode([Entry].self, from: data)
        } catch {
            throw SourceError.malformed("SatNOGS response was not a TLE list")
        }

        var text = ""
        text.reserveCapacity(entries.count * 160)
        for entry in entries {
            let name = entry.tle0.hasPrefix("0 ") ? String(entry.tle0.dropFirst(2)) : entry.tle0
            text += name + "\n" + entry.tle1 + "\n" + entry.tle2 + "\n"
        }
        guard !entries.isEmpty else { throw SourceError.malformed("SatNOGS returned no elements") }
        return text
    }
}
