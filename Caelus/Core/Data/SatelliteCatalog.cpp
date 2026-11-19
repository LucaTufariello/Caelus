#include "SatelliteCatalog.hpp"

#include <algorithm>
#include <cctype>
#include <unordered_map>

namespace caelus {
namespace {

// One UTF-8 code point's worth of bytes starting at `index`.
size_t utf8Width(const std::string& text, size_t index) {
    const unsigned char c = static_cast<unsigned char>(text[index]);
    if ((c & 0xE0) == 0xC0) return 2;
    if ((c & 0xF0) == 0xE0) return 3;
    if ((c & 0xF8) == 0xF0) return 4;
    return 1;
}

// Latin-1 / Latin Extended-A letters with diacritics, folded to their base
// letter. The table is deliberately small: catalog names are almost entirely
// ASCII, and this covers the Latin accents that appear in practice.
struct FoldEntry {
    const char* octets;
    char base;
};

const FoldEntry kFolds[] = {
    {"\xC3\x80", 'a'}, {"\xC3\x81", 'a'}, {"\xC3\x82", 'a'}, {"\xC3\x83", 'a'},
    {"\xC3\x84", 'a'}, {"\xC3\x85", 'a'}, {"\xC3\x86", 'a'}, {"\xC3\x87", 'c'},
    {"\xC3\x88", 'e'}, {"\xC3\x89", 'e'}, {"\xC3\x8A", 'e'}, {"\xC3\x8B", 'e'},
    {"\xC3\x8C", 'i'}, {"\xC3\x8D", 'i'}, {"\xC3\x8E", 'i'}, {"\xC3\x8F", 'i'},
    {"\xC3\x91", 'n'}, {"\xC3\x92", 'o'}, {"\xC3\x93", 'o'}, {"\xC3\x94", 'o'},
    {"\xC3\x95", 'o'}, {"\xC3\x96", 'o'}, {"\xC3\x98", 'o'}, {"\xC3\x99", 'u'},
    {"\xC3\x9A", 'u'}, {"\xC3\x9B", 'u'}, {"\xC3\x9C", 'u'}, {"\xC3\x9D", 'y'},
    {"\xC3\xA0", 'a'}, {"\xC3\xA1", 'a'}, {"\xC3\xA2", 'a'}, {"\xC3\xA3", 'a'},
    {"\xC3\xA4", 'a'}, {"\xC3\xA5", 'a'}, {"\xC3\xA6", 'a'}, {"\xC3\xA7", 'c'},
    {"\xC3\xA8", 'e'}, {"\xC3\xA9", 'e'}, {"\xC3\xAA", 'e'}, {"\xC3\xAB", 'e'},
    {"\xC3\xAC", 'i'}, {"\xC3\xAD", 'i'}, {"\xC3\xAE", 'i'}, {"\xC3\xAF", 'i'},
    {"\xC3\xB1", 'n'}, {"\xC3\xB2", 'o'}, {"\xC3\xB3", 'o'}, {"\xC3\xB4", 'o'},
    {"\xC3\xB5", 'o'}, {"\xC3\xB6", 'o'}, {"\xC3\xB8", 'o'}, {"\xC3\xB9", 'u'},
    {"\xC3\xBA", 'u'}, {"\xC3\xBB", 'u'}, {"\xC3\xBC", 'u'}, {"\xC3\xBD", 'y'},
    {"\xC3\xBF", 'y'},
};

int naturalCompare(const std::string& lhs, const std::string& rhs) {
    const std::string a = folded(lhs);
    const std::string b = folded(rhs);

    size_t i = 0;
    size_t j = 0;
    while (i < a.size() && j < b.size()) {
        const unsigned char ca = static_cast<unsigned char>(a[i]);
        const unsigned char cb = static_cast<unsigned char>(b[j]);
        if (std::isdigit(ca) && std::isdigit(cb)) {
            size_t endA = i;
            size_t endB = j;
            while (endA < a.size() && std::isdigit(static_cast<unsigned char>(a[endA]))) ++endA;
            while (endB < b.size() && std::isdigit(static_cast<unsigned char>(b[endB]))) ++endB;
            size_t startA = i;
            size_t startB = j;
            while (startA < endA && a[startA] == '0') ++startA;
            while (startB < endB && b[startB] == '0') ++startB;
            const size_t lengthA = endA - startA;
            const size_t lengthB = endB - startB;
            if (lengthA != lengthB) return lengthA < lengthB ? -1 : 1;
            const int digits = a.compare(startA, lengthA, b, startB, lengthB);
            if (digits != 0) return digits < 0 ? -1 : 1;
            i = endA;
            j = endB;
            continue;
        }
        if (ca != cb) return ca < cb ? -1 : 1;
        ++i;
        ++j;
    }
    if (i == a.size() && j == b.size()) return 0;
    return i == a.size() ? -1 : 1;
}

}  // namespace

std::string folded(const std::string& text) {
    std::string out;
    out.reserve(text.size());
    size_t index = 0;
    while (index < text.size()) {
        const size_t width = utf8Width(text, index);
        const std::string unit = text.substr(index, width);

        bool foldedUnit = false;
        for (const FoldEntry& entry : kFolds) {
            if (unit == entry.octets) {
                out.push_back(entry.base);
                foldedUnit = true;
                break;
            }
        }
        if (!foldedUnit) {
            // Combining marks (U+0300…U+036F) are dropped, which is what
            // diacritic-insensitive folding amounts to for decomposed text.
            const bool combining =
                width == 2 && static_cast<unsigned char>(unit[0]) == 0xCC;
            if (!combining) {
                if (width == 1) {
                    out.push_back(static_cast<char>(
                        std::tolower(static_cast<unsigned char>(unit[0]))));
                } else {
                    out += unit;
                }
            }
        }
        index += width;
    }
    return out;
}

int localizedStandardCompare(const std::string& lhs, const std::string& rhs) {
    const int compared = naturalCompare(lhs, rhs);
    if (compared != 0) return compared;
    if (lhs == rhs) return 0;
    return lhs < rhs ? -1 : 1;
}

std::string searchKey(const SatelliteRecord& record) {
    return folded(record.name + " " + std::to_string(record.id));
}

SatelliteCatalog::SatelliteCatalog(std::vector<SatelliteRecord> input, Date generated)
    : records(std::move(input)), generatedAt(generated) {
    searchKeys_.reserve(records.size());

    for (size_t index = 0; index < records.size(); ++index) {
        const SatelliteRecord& record = records[index];
        indexByID[record.id] = index;
        for (SatelliteGroup group : record.groups) {
            indicesByGroup[group].push_back(index);
        }
        renderIndices[record.renderGroup()].push_back(index);
        searchKeys_.push_back(searchKey(record));
    }
}

const SatelliteRecord* SatelliteCatalog::record(int id) const {
    const auto found = indexByID.find(id);
    if (found == indexByID.end()) return nullptr;
    return &records[found->second];
}

std::optional<size_t> SatelliteCatalog::index(int id) const {
    const auto found = indexByID.find(id);
    if (found == indexByID.end()) return std::nullopt;
    return found->second;
}

size_t SatelliteCatalog::countIn(SatelliteGroup group) const {
    const auto found = indicesByGroup.find(group);
    return found == indicesByGroup.end() ? 0 : found->second.size();
}

int SatelliteCatalog::score(const std::string& key, const std::string& needle, int id) {
    // Swift's `Int(needle)`: an exact decimal integer, otherwise no match.
    if (!needle.empty()) {
        bool numeric = true;
        size_t index = 0;
        if (needle[0] == '+' || needle[0] == '-') index = 1;
        if (index == needle.size()) numeric = false;
        for (; index < needle.size() && numeric; ++index) {
            if (!std::isdigit(static_cast<unsigned char>(needle[index]))) numeric = false;
        }
        if (numeric) {
            try {
                if (std::stoll(needle) == id) return 1000;
            } catch (const std::out_of_range&) {
                // Swift's Int(...) returns nil for values outside Int's range.
            }
        }
    }
    if (key.rfind(needle, 0) == 0) return 500;
    if (key.find(" " + needle) != std::string::npos) return 300;  // start of a later word
    if (key.find(needle) != std::string::npos) return 100;
    return 0;
}

std::vector<size_t> SatelliteCatalog::search(const std::string& query,
                                             const std::set<SatelliteGroup>& groups,
                                             bool favoritesOnly,
                                             const std::set<int>& favorites,
                                             size_t limit) const {
    const std::string needle = folded(trimWhitespace(query));

    auto passesFilters = [&](size_t index) {
        const SatelliteRecord& record = records[index];
        if (!groups.empty()) {
            bool intersects = false;
            for (SatelliteGroup group : record.groups) {
                if (groups.count(group) != 0) {
                    intersects = true;
                    break;
                }
            }
            if (!intersects) return false;
        }
        if (favoritesOnly && favorites.count(record.id) == 0) return false;
        return true;
    };

    // Fast path: no text query — walk the catalog in order.
    if (needle.empty()) {
        std::vector<size_t> result;
        result.reserve(std::min(limit, records.size()));
        for (size_t index = 0; index < records.size(); ++index) {
            if (!passesFilters(index)) continue;
            result.push_back(index);
            if (result.size() >= limit) break;
        }
        return result;
    }

    std::vector<std::pair<size_t, int>> scored;
    scored.reserve(256);

    for (size_t index = 0; index < records.size(); ++index) {
        if (!passesFilters(index)) continue;
        const int value = score(searchKeys_[index], needle, records[index].id);
        if (value > 0) scored.emplace_back(index, value);
    }

    std::stable_sort(scored.begin(), scored.end(),
                     [&](const std::pair<size_t, int>& lhs, const std::pair<size_t, int>& rhs) {
                         if (lhs.second != rhs.second) return lhs.second > rhs.second;
                         return localizedStandardCompare(records[lhs.first].name,
                                                         records[rhs.first].name) < 0;
                     });

    std::vector<size_t> result;
    const size_t count = std::min(limit, scored.size());
    result.reserve(count);
    for (size_t index = 0; index < count; ++index) result.push_back(scored[index].first);
    return result;
}

SatelliteCatalog::Assembled SatelliteCatalog::assemble(const std::vector<Batch>& batches) {
    LoadDiagnostics diagnostics;
    std::unordered_map<int, SatelliteRecord> byID;
    byID.reserve(18000);

    for (const Batch& batch : batches) {
        diagnostics.parseFailures += static_cast<int>(batch.failures.size());
        if (!batch.failures.empty()) {
            const size_t sampleCount = std::min<size_t>(3, batch.failures.size());
            for (size_t index = 0; index < sampleCount; ++index) {
                const TLEParser::Failure& failure = batch.failures[index];
                diagnostics.messages.push_back(batch.group + " — " + failure.name + ": " +
                                               failure.reason);
            }
        }

        for (const SatelliteRecord& record : batch.records) {
            const auto existing = byID.find(record.id);
            if (existing != byID.end()) {
                diagnostics.duplicateRecords += 1;
                SatelliteRecord merged = existing->second;
                std::set<SatelliteGroup> groups = merged.groups;
                groups.insert(record.groups.begin(), record.groups.end());
                if (record.epoch > merged.epoch) merged = record;
                merged.groups = groups;
                byID[record.id] = merged;
            } else {
                byID[record.id] = record;
            }
        }
    }

    // Name-prefix tagging for Starlink, which is far too large to fetch twice.
    std::vector<SatelliteRecord> records;
    records.reserve(byID.size());
    for (auto& entry : byID) {
        SatelliteRecord record = entry.second;
        std::string upper = record.name;
        for (char& c : upper) c = static_cast<char>(std::toupper(static_cast<unsigned char>(c)));
        if (upper.rfind("STARLINK", 0) == 0) record.groups.insert(SatelliteGroup::starlink);
        if (record.groups.empty()) record.groups.insert(SatelliteGroup::other);
        if (record.groups.size() > 1) record.groups.erase(SatelliteGroup::other);
        records.push_back(std::move(record));
    }

    std::stable_sort(records.begin(), records.end(),
                     [](const SatelliteRecord& lhs, const SatelliteRecord& rhs) {
                         return localizedStandardCompare(lhs.name, rhs.name) < 0;
                     });

    Assembled assembled;
    assembled.catalog = SatelliteCatalog(std::move(records));
    assembled.diagnostics = diagnostics;
    return assembled;
}

}  // namespace caelus
