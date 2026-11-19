#include "CelesTrakClient.hpp"

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <ctime>

namespace caelus {
namespace {

std::string percentEncode(const std::string& text) {
    static const char* hex = "0123456789ABCDEF";
    std::string out;
    for (unsigned char c : text) {
        if (std::isalnum(c) || c == '-' || c == '_' || c == '.' || c == '~') {
            out.push_back(static_cast<char>(c));
        } else {
            out.push_back('%');
            out.push_back(hex[(c >> 4) & 0xF]);
            out.push_back(hex[c & 0xF]);
        }
    }
    return out;
}

}  // namespace

const std::array<double, 3>& CelesTrakClient::Backoff::ladder() {
    static const std::array<double, 3> delays = {60.0, 5.0 * 60.0, 30.0 * 60.0};
    return delays;
}

void CelesTrakClient::Backoff::recordFailure(Date now) {
    consecutiveFailures += 1;
    const int index = std::min(consecutiveFailures - 1,
                               static_cast<int>(ladder().size()) - 1);
    nextAttempt = now + ladder()[static_cast<size_t>(index)];
}

void CelesTrakClient::Backoff::recordSuccess() {
    consecutiveFailures = 0;
    nextAttempt = distantPast();
}

std::string CelesTrakClient::FetchError::shortDescription() const {
    switch (kind) {
        case FetchErrorKind::http:
            return "HTTP " + std::to_string(status);
        case FetchErrorKind::transport:
            return what();
        case FetchErrorKind::malformed:
            return what();
        case FetchErrorKind::backedOff: {
            const std::time_t seconds = static_cast<std::time_t>(until);
            std::tm local{};
            ::localtime_r(&seconds, &local);
            char buffer[32];
            std::strftime(buffer, sizeof(buffer), "%H:%M", &local);
            return std::string("retry after ") + buffer;
        }
    }
    return what();
}

CelesTrakClient::CelesTrakClient(HttpClient& http, std::string userAgent, double timeout)
    : http_(http), userAgent_(std::move(userAgent)), timeout_(timeout),
      now_([] { return sky::nowDate(); }) {}

FetchOutcome CelesTrakClient::fetch(const std::string& group) {
    const Date now = now_();
    const auto state = backoff_.find(group);
    if (state != backoff_.end() && now < state->second.nextAttempt) {
        throw FetchError(FetchErrorKind::backedOff,
                         "retry after " + std::to_string(state->second.nextAttempt), 0,
                         state->second.nextAttempt);
    }

    std::map<std::string, std::string> headers;
    headers["User-Agent"] = userAgent_;
    headers["Accept"] = "text/plain";
    const auto etag = etags_.find(group);
    if (etag != etags_.end()) headers["If-None-Match"] = etag->second;

    HttpResponse response;
    try {
        response = http_.get(url(group), headers, timeout_);
    } catch (const HttpTransportError& error) {
        Backoff& backoff = backoff_[group];
        backoff.recordFailure(now);
        throw FetchError(FetchErrorKind::transport, error.what());
    }

    switch (response.status) {
        case 200: {
            if (!looksLikeElements(response.body)) {
                throw FetchError(FetchErrorKind::malformed,
                                 "response did not contain element sets");
            }
            if (const auto header = response.header("etag")) {
                etags_[group] = *header;
            }
            if (backoff_.find(group) == backoff_.end()) {
                backoff_[group] = Backoff();
            }
            backoff_[group].recordSuccess();

            FetchOutcome outcome;
            outcome.kind = FetchOutcome::Kind::updated;
            outcome.text = response.body;
            return outcome;
        }

        case 304: {
            if (auto found = backoff_.find(group); found != backoff_.end()) {
                found->second.recordSuccess();
            }
            FetchOutcome outcome;
            outcome.kind = FetchOutcome::Kind::unchanged;
            outcome.text = group;
            return outcome;
        }

        case 403: {
            if (isNotUpdated(response.body)) {
                // Not a failure: the two-hour window has not elapsed.
                if (auto found = backoff_.find(group); found != backoff_.end()) {
                    found->second.recordSuccess();
                }
                FetchOutcome outcome;
                outcome.kind = FetchOutcome::Kind::unchanged;
                outcome.text = group;
                return outcome;
            }
            Backoff& backoff = backoff_[group];
            backoff.recordFailure(now);
            throw FetchError(FetchErrorKind::http, trim(response.body), 403);
        }

        case 404:
            throw FetchError(FetchErrorKind::http, trim(response.body), 404);

        default: {
            Backoff& backoff = backoff_[group];
            backoff.recordFailure(now);
            throw FetchError(FetchErrorKind::http, trim(response.body), response.status);
        }
    }
}

std::optional<Date> CelesTrakClient::nextAttempt(const std::string& group) const {
    const auto found = backoff_.find(group);
    if (found == backoff_.end()) return std::nullopt;
    if (!(found->second.nextAttempt > now_())) return std::nullopt;
    return found->second.nextAttempt;
}

void CelesTrakClient::resetBackoff() { backoff_.clear(); }

std::string CelesTrakClient::url(const std::string& group) {
    return "https://celestrak.org/NORAD/elements/gp.php?GROUP=" + percentEncode(group) +
           "&FORMAT=tle";
}

bool CelesTrakClient::looksLikeElements(const std::string& text) {
    size_t start = 0;
    while (start <= text.size()) {
        size_t end = text.find_first_of("\r\n", start);
        if (end == std::string::npos) end = text.size();
        const std::string line = text.substr(start, end - start);
        if (line.rfind("1 ", 0) == 0) return true;
        if (end == text.size()) break;
        start = end + 1;
    }
    return false;
}

bool CelesTrakClient::isNotUpdated(const std::string& body) {
    std::string lowered = body;
    for (char& c : lowered) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return lowered.find("has not updated") != std::string::npos ||
           lowered.find("not updated since") != std::string::npos;
}

std::string CelesTrakClient::trim(const std::string& body) const {
    const size_t end = body.find_first_of("\r\n");
    std::string line = end == std::string::npos ? body : body.substr(0, end);
    if (line.size() > 160) line = line.substr(0, 160);
    return line;
}

}  // namespace caelus
