//
//  CacheStore.swift
//  Caelus
//
//  On-disk cache of raw GP text plus per-group bookkeeping.
//
//  Reads are synchronous and cheap (a few megabytes) so the app can populate
//  the globe from cache before the network answers. Writes are atomic and are
//  performed off the main actor by the caller.
//

import Foundation

struct CacheStore: Sendable {

    let root: URL

    private var tleDirectory: URL { root.appendingPathComponent("tle", isDirectory: true) }
    private var metaURL: URL { root.appendingPathComponent("meta.json", isDirectory: false) }

    init(root: URL) {
        self.root = root
    }

    /// The sandboxed Application Support location used by the running app.
    static func applicationDefault() -> CacheStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return CacheStore(root: base.appendingPathComponent("Caelus", isDirectory: true))
    }

    // MARK: - Paths

    func textURL(group: String) -> URL {
        tleDirectory.appendingPathComponent("\(group).tle", isDirectory: false)
    }

    // MARK: - Reading

    /// Raw cached text for a group, if present.
    func loadText(group: String) -> String? {
        guard let data = try? Data(contentsOf: textURL(group: group)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// All per-group metadata. A missing or corrupt file yields an empty map
    /// rather than an error: the cache is an optimisation, not the source of truth.
    func loadMeta() -> [String: CacheMeta] {
        guard let data = try? Data(contentsOf: metaURL),
              let document = try? JSONDecoder.cache.decode(MetaDocument.self, from: data) else {
            return [:]
        }
        return document.groups
    }

    /// Everything needed to rebuild the catalog at launch.
    func loadAll() -> (texts: [String: String], meta: [String: CacheMeta]) {
        let meta = loadMeta()
        var texts: [String: String] = [:]
        for group in meta.keys {
            if let text = loadText(group: group) { texts[group] = text }
        }
        return (texts, meta)
    }

    // MARK: - Writing

    /// Store fresh text and its metadata atomically.
    func save(group: String, text: String, meta: CacheMeta) throws {
        try FileManager.default.createDirectory(at: tleDirectory,
                                                withIntermediateDirectories: true)
        guard let data = text.data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        try data.write(to: textURL(group: group), options: .atomic)

        var all = loadMeta()
        all[group] = meta
        try writeMeta(all)
    }

    /// Move `lastChecked` forward after a "data has not updated" answer.
    func markChecked(group: String, at date: Date) throws {
        var all = loadMeta()
        guard var meta = all[group] else { return }
        meta.lastChecked = date
        all[group] = meta
        try writeMeta(all)
    }

    func writeMeta(_ groups: [String: CacheMeta]) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let document = MetaDocument(version: MetaDocument.currentVersion, groups: groups)
        let data = try JSONEncoder.cache.encode(document)
        try data.write(to: metaURL, options: .atomic)
    }

    // MARK: - Maintenance

    func clear() throws {
        if FileManager.default.fileExists(atPath: tleDirectory.path) {
            try FileManager.default.removeItem(at: tleDirectory)
        }
        if FileManager.default.fileExists(atPath: metaURL.path) {
            try FileManager.default.removeItem(at: metaURL)
        }
    }

    /// Total bytes on disk.
    func diskUsage() -> Int {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root,
                                             includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total = 0
        for case let url as URL in enumerator {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += size
        }
        return total
    }

    // MARK: - Document

    struct MetaDocument: Codable, Sendable {
        static let currentVersion = 1
        var version: Int
        var groups: [String: CacheMeta]
    }
}

extension JSONDecoder {
    static var cache: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}

extension JSONEncoder {
    static var cache: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
