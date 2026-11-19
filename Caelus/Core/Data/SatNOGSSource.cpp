#include "SatNOGSSource.hpp"

#include <cmath>

#include "../Support/Json.hpp"

namespace caelus {

const std::string& SatNOGSSource::endpoint() {
    static const std::string url = "https://db.satnogs.org/api/tle/";
    return url;
}

std::string SatNOGSSource::fetchTLE(HttpClient& http, double timeout) {
    std::map<std::string, std::string> headers;
    headers["User-Agent"] = "Caelus/0.1 (macOS; personal use)";
    headers["Accept"] = "application/json";

    HttpResponse response;
    try {
        response = http.get(endpoint(), headers, timeout);
    } catch (const HttpTransportError& error) {
        throw SourceError(ErrorKind::transport, error.what());
    }

    if (response.status != 200) {
        throw SourceError(ErrorKind::http, "HTTP " + std::to_string(response.status),
                          response.status);
    }

    const std::optional<JsonValue> document = JsonValue::parse(response.body);
    if (!document || !document->isArray()) {
        throw SourceError(ErrorKind::malformed, "SatNOGS response was not a TLE list");
    }

    std::string text;
    text.reserve(document->elements().size() * 160);

    for (const auto& element : document->elements()) {
        if (!element || !element->isObject()) {
            throw SourceError(ErrorKind::malformed, "SatNOGS response was not a TLE list");
        }

        const JsonValue* tle0 = element->member("tle0");
        const JsonValue* tle1 = element->member("tle1");
        const JsonValue* tle2 = element->member("tle2");
        const JsonValue* norad = element->member("norad_cat_id");
        if (!tle0 || !tle0->isString() || !tle1 || !tle1->isString() || !tle2 ||
            !tle2->isString() || !norad || !norad->isNumber()) {
            throw SourceError(ErrorKind::malformed, "SatNOGS response was not a TLE list");
        }

        std::string name = tle0->stringOr("");
        if (name.rfind("0 ", 0) == 0) name.erase(0, 2);

        text += name + "\n" + tle1->stringOr("") + "\n" + tle2->stringOr("") + "\n";
    }

    if (document->elements().empty()) {
        throw SourceError(ErrorKind::malformed, "SatNOGS returned no elements");
    }
    return text;
}

}  // namespace caelus
