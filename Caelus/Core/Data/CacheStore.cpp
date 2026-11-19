#include "CacheStore.hpp"

#include <cmath>
#include <cstdio>

#include "../Support/Json.hpp"

namespace caelus {
namespace {

std::string formatDate(Date date) {
    char buffer[64];
    std::snprintf(buffer, sizeof(buffer), "%.9f", date);
    std::string text = buffer;

    // Trim trailing zeros, then a trailing point: JSON numbers need no padding.
    if (text.find('.') != std::string::npos) {
        while (!text.empty() && text.back() == '0') text.pop_back();
        if (!text.empty() && text.back() == '.') text.pop_back();
    }
    if (text.empty() || text == "-") return "0";
    return text;
}

}  // namespace

fsutil::path CacheStore::tleDirectory() const { return root_ / "tle"; }

fsutil::path CacheStore::metaURL() const { return root_ / "meta.json"; }

fsutil::path CacheStore::textURL(const std::string& group) const {
    return tleDirectory() / (group + ".tle");
}

std::optional<std::string> CacheStore::loadText(const std::string& group) const {
    return fsutil::readFile(textURL(group));
}

std::map<std::string, CacheMeta> CacheStore::loadMeta() const {
    const std::optional<std::string> text = fsutil::readFile(metaURL());
    if (!text) return {};

    const std::optional<JsonValue> document = JsonValue::parse(*text);
    if (!document || !document->isObject()) return {};

    const JsonValue* version = document->member("version");
    const JsonValue* groups = document->member("groups");
    if (!version || !version->isNumber() || !groups || !groups->isObject()) return {};

    std::map<std::string, CacheMeta> result;
    for (const auto& entry : groups->members()) {
        const JsonValue& value = *entry.second;
        if (!value.isObject()) return {};

        const JsonValue* group = value.member("group");
        const JsonValue* fetchedAt = value.member("fetchedAt");
        const JsonValue* lastChecked = value.member("lastChecked");
        const JsonValue* count = value.member("count");
        if (!group || !group->isString() || !fetchedAt || !fetchedAt->isNumber() ||
            !lastChecked || !lastChecked->isNumber() || !count || !count->isNumber()) {
            return {};
        }

        CacheMeta meta;
        meta.group = group->stringOr("");
        meta.fetchedAt = fetchedAt->numberOr(0.0);
        meta.lastChecked = lastChecked->numberOr(0.0);
        meta.count = static_cast<int>(std::llround(count->numberOr(0.0)));

        if (const JsonValue* etag = value.member("etag")) {
            if (etag->isString()) meta.etag = etag->stringOr("");
        }

        result[meta.group] = meta;
    }
    return result;
}

CacheStore::LoadedAll CacheStore::loadAll() const {
    LoadedAll all;
    all.meta = loadMeta();
    for (const auto& entry : all.meta) {
        if (auto text = loadText(entry.first)) all.texts[entry.first] = std::move(*text);
    }
    return all;
}

void CacheStore::save(const std::string& group, const std::string& text,
                      const CacheMeta& meta) const {
    if (!fsutil::createDirectories(tleDirectory())) {
        throw std::runtime_error("cannot create " + tleDirectory().string());
    }

    std::string error;
    if (!fsutil::writeFileAtomic(textURL(group), text, &error)) {
        throw std::runtime_error(error);
    }

    std::map<std::string, CacheMeta> all = loadMeta();
    all[group] = meta;
    writeMeta(all);
}

void CacheStore::markChecked(const std::string& group, Date date) const {
    std::map<std::string, CacheMeta> all = loadMeta();
    const auto found = all.find(group);
    if (found == all.end()) return;
    found->second.lastChecked = date;
    writeMeta(all);
}

void CacheStore::writeMeta(const std::map<std::string, CacheMeta>& groups) const {
    if (!fsutil::createDirectories(root_)) {
        throw std::runtime_error("cannot create " + root_.string());
    }

    std::string document = "{\n";
    document += "  \"version\" : " + std::to_string(MetaDocument::currentVersion) + ",\n";
    document += "  \"groups\" : {";

    bool firstGroup = true;
    for (const auto& entry : groups) {
        const CacheMeta& meta = entry.second;
        document += firstGroup ? "\n" : ",\n";
        firstGroup = false;

        document += "    ";
        JsonValue::appendQuoted(document, entry.first);
        document += " : {\n";

        document += "      \"count\" : " + std::to_string(meta.count) + ",\n";
        if (meta.etag) {
            document += "      \"etag\" : ";
            JsonValue::appendQuoted(document, *meta.etag);
            document += ",\n";
        }
        document += "      \"fetchedAt\" : " + formatDate(meta.fetchedAt) + ",\n";
        document += "      \"group\" : ";
        JsonValue::appendQuoted(document, meta.group);
        document += ",\n";
        document += "      \"lastChecked\" : " + formatDate(meta.lastChecked) + "\n";
        document += "    }";
    }

    document += firstGroup ? "}\n" : "\n  }\n";
    document += "}\n";

    std::string error;
    if (!fsutil::writeFileAtomic(metaURL(), document, &error)) {
        throw std::runtime_error(error);
    }
}

void CacheStore::clear() const {
    if (fsutil::exists(tleDirectory())) fsutil::removeAll(tleDirectory());
    if (fsutil::exists(metaURL())) fsutil::removeFile(metaURL());
}

uintmax_t CacheStore::diskUsage() const {
    uintmax_t total = 0;
    for (const fsutil::path& file : fsutil::regularFiles(root_)) {
        total += fsutil::fileSize(file);
    }
    return total;
}

}  // namespace caelus
