// CacheStore.hpp — on-disk cache of raw GP text plus per-group bookkeeping.
//
// Translated from the Swift app's Data/CacheStore.swift. Reads are synchronous
// and cheap (a few megabytes) so the app can populate the globe from cache
// before the network answers. Writes are atomic.

#pragma once

#include <cstdint>
#include <map>
#include <optional>
#include <stdexcept>
#include <string>

#include "../Support/FileSystem.hpp"
#include "Models.hpp"

namespace caelus {

struct CacheStore {
    explicit CacheStore(fsutil::path root) : root_(std::move(root)) {}

    // The sandboxed Application Support location used by the running app.
    static CacheStore applicationDefault() {
        return CacheStore(fsutil::applicationSupportDirectory("Caelus"));
    }

    const fsutil::path& root() const { return root_; }

    // MARK: - Paths

    fsutil::path textURL(const std::string& group) const;

    // MARK: - Reading

    // Raw cached text for a group, if present.
    std::optional<std::string> loadText(const std::string& group) const;

    // All per-group metadata. A missing or corrupt file yields an empty map
    // rather than an error: the cache is an optimisation, not the source of truth.
    std::map<std::string, CacheMeta> loadMeta() const;

    struct LoadedAll {
        std::map<std::string, std::string> texts;
        std::map<std::string, CacheMeta> meta;
    };

    // Everything needed to rebuild the catalog at launch.
    LoadedAll loadAll() const;

    // MARK: - Writing

    // Store fresh text and its metadata atomically. Throws std::runtime_error.
    void save(const std::string& group, const std::string& text, const CacheMeta& meta) const;

    // Move `lastChecked` forward after a "data has not updated" answer.
    void markChecked(const std::string& group, Date date) const;

    void writeMeta(const std::map<std::string, CacheMeta>& groups) const;

    // MARK: - Maintenance

    void clear() const;

    // Total bytes on disk.
    uintmax_t diskUsage() const;

    // MARK: - Document

    struct MetaDocument {
        static constexpr int currentVersion = 1;
        int version = currentVersion;
        std::map<std::string, CacheMeta> groups;
    };

private:
    fsutil::path tleDirectory() const;
    fsutil::path metaURL() const;

    fsutil::path root_;
};

}  // namespace caelus
