// SatNOGSSource.hpp — fallback element source used when CelesTrak is unreachable.
//
// Translated from the Swift app's Data/SatNOGSSource.swift. SatNOGS publishes
// the same two-line elements as JSON; we re-emit them as a three-line document
// so a single parser handles every source.

#pragma once

#include <stdexcept>
#include <string>
#include <utility>

#include "../Net/Http.hpp"

namespace caelus {

class SatNOGSSource {
public:
    enum class ErrorKind { transport, http, malformed };

    struct SourceError : std::runtime_error {
        SourceError(ErrorKind kind_, std::string message, int status_ = 0)
            : std::runtime_error(std::move(message)), kind(kind_), status(status_) {}

        ErrorKind kind;
        int status = 0;

        std::string shortDescription() const {
            switch (kind) {
                case ErrorKind::transport: return what();
                case ErrorKind::http: return "HTTP " + std::to_string(status);
                case ErrorKind::malformed: return what();
            }
            return what();
        }
    };

    static const std::string& endpoint();

    // Download every element set SatNOGS holds and render them as 3LE text.
    static std::string fetchTLE(HttpClient& http, double timeout = 120.0);
};

}  // namespace caelus
