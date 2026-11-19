// Json.hpp — a small read-only JSON reader.
//
// The app only parses two documents (the cache's meta.json and SatNOGS' TLE
// list), so this is deliberately minimal: RFC 8259 values, UTF-8 strings,
// \uXXXX escapes and strict error handling. Anything malformed yields nullopt,
// which is how a corrupt cache file becomes an empty map.

#pragma once

#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

namespace caelus {

class JsonValue {
public:
    enum class Type { nullValue, boolean, number, string, array, object };

    JsonValue() = default;
    JsonValue(JsonValue&&) = default;
    JsonValue& operator=(JsonValue&&) = default;
    JsonValue(const JsonValue&) = delete;
    JsonValue& operator=(const JsonValue&) = delete;

    Type type() const { return type_; }
    bool isNull() const { return type_ == Type::nullValue; }
    bool isBoolean() const { return type_ == Type::boolean; }
    bool isNumber() const { return type_ == Type::number; }
    bool isString() const { return type_ == Type::string; }
    bool isArray() const { return type_ == Type::array; }
    bool isObject() const { return type_ == Type::object; }

    bool booleanOr(bool fallback) const {
        return type_ == Type::boolean ? boolean_ : fallback;
    }
    double numberOr(double fallback) const {
        return type_ == Type::number ? number_ : fallback;
    }
    std::string stringOr(const std::string& fallback) const {
        return type_ == Type::string ? string_ : fallback;
    }

    // Object lookup; nullptr when absent or when this is not an object.
    const JsonValue* member(const std::string& key) const;

    const std::vector<std::unique_ptr<JsonValue>>& elements() const { return items_; }
    const std::vector<std::pair<std::string, std::unique_ptr<JsonValue>>>& members() const {
        return members_;
    }

    static std::optional<JsonValue> parse(const std::string& text);

    // Append a JSON-quoted, escaped form of `text` (including the quotes).
    static void appendQuoted(std::string& out, const std::string& text);

private:
    friend class JsonParser;

    Type type_ = Type::nullValue;
    bool boolean_ = false;
    double number_ = 0.0;
    std::string string_;
    std::vector<std::unique_ptr<JsonValue>> items_;
    std::vector<std::pair<std::string, std::unique_ptr<JsonValue>>> members_;
};

}  // namespace caelus
