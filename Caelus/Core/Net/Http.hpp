// Http.hpp — the boundary between the portable core and the platform's network stack.
//
// The macOS shell implements HttpClient with NSURLSession; tests and the CLI use
// fakes. Response header names are stored lower-cased so lookups are case-blind.

#pragma once

#include <map>
#include <optional>
#include <stdexcept>
#include <string>

namespace caelus {

struct HttpResponse {
    int status = 0;
    std::map<std::string, std::string> headers;
    std::string body;

    std::optional<std::string> header(const std::string& name) const {
        const auto found = headers.find(name);
        if (found == headers.end()) return std::nullopt;
        return found->second;
    }
};

// Transport-level failure: timeout, offline, DNS, TLS.
struct HttpTransportError : std::runtime_error {
    using std::runtime_error::runtime_error;
};

class HttpClient {
public:
    virtual ~HttpClient() = default;

    // Performs a GET. Throws HttpTransportError when no HTTP response arrives.
    virtual HttpResponse get(const std::string& url,
                             const std::map<std::string, std::string>& headers,
                             double timeoutSeconds) = 0;
};

}  // namespace caelus
