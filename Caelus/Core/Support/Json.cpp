#include "Json.hpp"

#include <cmath>
#include <cstdlib>
#include <cstring>

namespace caelus {
namespace {

void appendUTF8(std::string& out, unsigned int codePoint) {
    if (codePoint <= 0x7F) {
        out.push_back(static_cast<char>(codePoint));
    } else if (codePoint <= 0x7FF) {
        out.push_back(static_cast<char>(0xC0 | (codePoint >> 6)));
        out.push_back(static_cast<char>(0x80 | (codePoint & 0x3F)));
    } else if (codePoint <= 0xFFFF) {
        out.push_back(static_cast<char>(0xE0 | (codePoint >> 12)));
        out.push_back(static_cast<char>(0x80 | ((codePoint >> 6) & 0x3F)));
        out.push_back(static_cast<char>(0x80 | (codePoint & 0x3F)));
    } else {
        out.push_back(static_cast<char>(0xF0 | (codePoint >> 18)));
        out.push_back(static_cast<char>(0x80 | ((codePoint >> 12) & 0x3F)));
        out.push_back(static_cast<char>(0x80 | ((codePoint >> 6) & 0x3F)));
        out.push_back(static_cast<char>(0x80 | (codePoint & 0x3F)));
    }
}

}  // namespace

const JsonValue* JsonValue::member(const std::string& key) const {
    if (type_ != Type::object) return nullptr;
    for (const auto& entry : members_) {
        if (entry.first == key) return entry.second.get();
    }
    return nullptr;
}

class JsonParser {
public:
    explicit JsonParser(const std::string& text) : text_(text) {}

    std::optional<JsonValue> parseDocument() {
        skipWhitespace();
        auto value = parseValue(0);
        if (!value) return std::nullopt;
        skipWhitespace();
        if (index_ != text_.size()) return std::nullopt;  // trailing garbage
        return value;
    }

private:
    static constexpr int maxDepth = 512;

    const std::string& text_;
    size_t index_ = 0;

    void skipWhitespace() {
        while (index_ < text_.size()) {
            const char c = text_[index_];
            if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
                ++index_;
            } else {
                break;
            }
        }
    }

    bool consume(const char* literal) {
        const size_t length = std::strlen(literal);
        if (text_.compare(index_, length, literal) != 0) return false;
        index_ += length;
        return true;
    }

    std::optional<JsonValue> parseValue(int depth) {
        if (depth > maxDepth) return std::nullopt;
        skipWhitespace();
        if (index_ >= text_.size()) return std::nullopt;

        switch (text_[index_]) {
            case '{': return parseObject(depth);
            case '[': return parseArray(depth);
            case '"': {
                auto string = parseString();
                if (!string) return std::nullopt;
                JsonValue value;
                value.type_ = JsonValue::Type::string;
                value.string_ = std::move(*string);
                return value;
            }
            case 't':
                if (!consume("true")) return std::nullopt;
                {
                    JsonValue value;
                    value.type_ = JsonValue::Type::boolean;
                    value.boolean_ = true;
                    return value;
                }
            case 'f':
                if (!consume("false")) return std::nullopt;
                {
                    JsonValue value;
                    value.type_ = JsonValue::Type::boolean;
                    value.boolean_ = false;
                    return value;
                }
            case 'n':
                if (!consume("null")) return std::nullopt;
                return JsonValue();
            default: return parseNumber();
        }
    }

    std::optional<JsonValue> parseObject(int depth) {
        ++index_;  // '{'
        JsonValue value;
        value.type_ = JsonValue::Type::object;

        skipWhitespace();
        if (index_ < text_.size() && text_[index_] == '}') {
            ++index_;
            return value;
        }

        while (true) {
            skipWhitespace();
            auto key = parseString();
            if (!key) return std::nullopt;
            skipWhitespace();
            if (index_ >= text_.size() || text_[index_] != ':') return std::nullopt;
            ++index_;
            auto memberValue = parseValue(depth + 1);
            if (!memberValue) return std::nullopt;
            value.members_.emplace_back(std::move(*key),
                                        std::make_unique<JsonValue>(std::move(*memberValue)));

            skipWhitespace();
            if (index_ >= text_.size()) return std::nullopt;
            if (text_[index_] == ',') {
                ++index_;
                continue;
            }
            if (text_[index_] == '}') {
                ++index_;
                return value;
            }
            return std::nullopt;
        }
    }

    std::optional<JsonValue> parseArray(int depth) {
        ++index_;  // '['
        JsonValue value;
        value.type_ = JsonValue::Type::array;

        skipWhitespace();
        if (index_ < text_.size() && text_[index_] == ']') {
            ++index_;
            return value;
        }

        while (true) {
            auto element = parseValue(depth + 1);
            if (!element) return std::nullopt;
            value.items_.push_back(std::make_unique<JsonValue>(std::move(*element)));

            skipWhitespace();
            if (index_ >= text_.size()) return std::nullopt;
            if (text_[index_] == ',') {
                ++index_;
                continue;
            }
            if (text_[index_] == ']') {
                ++index_;
                return value;
            }
            return std::nullopt;
        }
    }

    std::optional<std::string> parseString() {
        if (index_ >= text_.size() || text_[index_] != '"') return std::nullopt;
        ++index_;

        std::string out;
        while (index_ < text_.size()) {
            const unsigned char c = static_cast<unsigned char>(text_[index_]);
            if (c == '"') {
                ++index_;
                return out;
            }
            if (c == '\\') {
                ++index_;
                if (index_ >= text_.size()) return std::nullopt;
                const char escape = text_[index_++];
                switch (escape) {
                    case '"': out.push_back('"'); break;
                    case '\\': out.push_back('\\'); break;
                    case '/': out.push_back('/'); break;
                    case 'b': out.push_back('\b'); break;
                    case 'f': out.push_back('\f'); break;
                    case 'n': out.push_back('\n'); break;
                    case 'r': out.push_back('\r'); break;
                    case 't': out.push_back('\t'); break;
                    case 'u': {
                        auto first = parseHex4();
                        if (!first) return std::nullopt;
                        unsigned int codePoint = *first;
                        if (codePoint >= 0xD800 && codePoint <= 0xDBFF) {
                            // High surrogate: expect a following low surrogate.
                            if (index_ + 1 >= text_.size() || text_[index_] != '\\' ||
                                text_[index_ + 1] != 'u') {
                                return std::nullopt;
                            }
                            index_ += 2;
                            auto second = parseHex4();
                            if (!second || *second < 0xDC00 || *second > 0xDFFF) {
                                return std::nullopt;
                            }
                            codePoint = 0x10000 + ((codePoint - 0xD800) << 10) +
                                        (*second - 0xDC00);
                        } else if (codePoint >= 0xDC00 && codePoint <= 0xDFFF) {
                            return std::nullopt;
                        }
                        appendUTF8(out, codePoint);
                        break;
                    }
                    default: return std::nullopt;
                }
                continue;
            }
            if (c < 0x20) return std::nullopt;  // control characters must be escaped
            out.push_back(static_cast<char>(c));
            ++index_;
        }
        return std::nullopt;
    }

    std::optional<unsigned int> parseHex4() {
        if (index_ + 4 > text_.size()) return std::nullopt;
        unsigned int value = 0;
        for (int digit = 0; digit < 4; ++digit) {
            const char c = text_[index_++];
            value <<= 4;
            if (c >= '0' && c <= '9') {
                value |= static_cast<unsigned int>(c - '0');
            } else if (c >= 'a' && c <= 'f') {
                value |= static_cast<unsigned int>(c - 'a' + 10);
            } else if (c >= 'A' && c <= 'F') {
                value |= static_cast<unsigned int>(c - 'A' + 10);
            } else {
                return std::nullopt;
            }
        }
        return value;
    }

    std::optional<JsonValue> parseNumber() {
        const size_t start = index_;

        if (index_ < text_.size() && text_[index_] == '-') ++index_;

        auto digits = [&]() {
            const size_t begin = index_;
            while (index_ < text_.size() && text_[index_] >= '0' && text_[index_] <= '9') {
                ++index_;
            }
            return index_ > begin;
        };

        if (index_ < text_.size() && text_[index_] == '0') {
            ++index_;
        } else if (!digits()) {
            return std::nullopt;
        }

        if (index_ < text_.size() && text_[index_] == '.') {
            ++index_;
            if (!digits()) return std::nullopt;
        }

        if (index_ < text_.size() && (text_[index_] == 'e' || text_[index_] == 'E')) {
            ++index_;
            if (index_ < text_.size() && (text_[index_] == '+' || text_[index_] == '-')) {
                ++index_;
            }
            if (!digits()) return std::nullopt;
        }

        const std::string token = text_.substr(start, index_ - start);
        char* end = nullptr;
        const double number = std::strtod(token.c_str(), &end);
        if (end != token.c_str() + token.size() || !std::isfinite(number)) {
            return std::nullopt;
        }

        JsonValue value;
        value.type_ = JsonValue::Type::number;
        value.number_ = number;
        return value;
    }
};

std::optional<JsonValue> JsonValue::parse(const std::string& text) {
    JsonParser parser(text);
    return parser.parseDocument();
}

void JsonValue::appendQuoted(std::string& out, const std::string& text) {
    out.push_back('"');
    for (char c : text) {
        switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\b': out += "\\b"; break;
            case '\f': out += "\\f"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (static_cast<unsigned char>(c) < 0x20) {
                    static const char* hex = "0123456789abcdef";
                    out += "\\u00";
                    out.push_back(hex[(c >> 4) & 0xF]);
                    out.push_back(hex[c & 0xF]);
                } else {
                    out.push_back(c);
                }
                break;
        }
    }
    out.push_back('"');
}

}  // namespace caelus
