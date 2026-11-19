// CelesTrakClient.hpp — fetches GP element sets from CelesTrak.
//
// Translated from the Swift app's Data/CelesTrakClient.swift. CelesTrak serves
// each group at most once every two hours per client. A repeat request inside
// that window answers 403 with a plain-text explanation ("GP data has not
// updated since your last successful download …"). That is a cache hit, not a
// failure, and is surfaced as `unchanged`.

#pragma once

#include <array>
#include <functional>
#include <map>
#include <optional>
#include <stdexcept>
#include <string>

#include "../Net/Http.hpp"
#include "../Sky/TimeUtil.hpp"
#include "Models.hpp"

namespace caelus {

class CelesTrakClient {
public:
    enum class FetchErrorKind { http, transport, backedOff, malformed };

    struct FetchError : std::runtime_error {
        FetchError(FetchErrorKind kind_, std::string message, int status_ = 0,
                   Date until_ = 0.0)
            : std::runtime_error(std::move(message)), kind(kind_), status(status_),
              until(until_) {}

        FetchErrorKind kind;
        int status = 0;
        Date until = 0.0;
        std::string detail() const { return what(); }

        bool isRetryable() const {
            switch (kind) {
                case FetchErrorKind::transport: return true;
                case FetchErrorKind::http: return status >= 500;
                default: return false;
            }
        }

        std::string shortDescription() const;
    };

    struct Backoff {
        // Delays applied after consecutive failures.
        static const std::array<double, 3>& ladder();

        int consecutiveFailures = 0;
        Date nextAttempt = distantPast();

        void recordFailure(Date now);
        void recordSuccess();

        static constexpr double distantPast() { return -1.0e12; }
    };

    explicit CelesTrakClient(HttpClient& http,
                             std::string userAgent = "Caelus/0.1 (macOS; personal use)",
                             double timeout = 30.0);

    // Ask for one group. Returns unchanged when CelesTrak says the data has not
    // moved since the last download. Throws FetchError.
    FetchOutcome fetch(const std::string& group);

    // When the next attempt for a group is allowed, if it is being held back.
    std::optional<Date> nextAttempt(const std::string& group) const;

    void resetBackoff();

    // The transport shared with other sources (SatNOGS uses the same session).
    HttpClient& http() { return http_; }

    // MARK: - Helpers

    static std::string url(const std::string& group);

    // A usable body contains at least one line-1 record.
    static bool looksLikeElements(const std::string& text);
    static bool isNotUpdated(const std::string& body);

    // Test seam: replace the wall clock.
    void setClock(std::function<Date()> clock) { now_ = std::move(clock); }

private:
    std::string trim(const std::string& body) const;

    HttpClient& http_;
    std::string userAgent_;
    double timeout_;
    std::function<Date()> now_;
    std::map<std::string, Backoff> backoff_;
    std::map<std::string, std::string> etags_;
};

}  // namespace caelus
