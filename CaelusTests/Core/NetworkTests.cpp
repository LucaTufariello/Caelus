// NetworkTests.cpp — new coverage for the C++ port's network seam.
//
// The Swift suite exercised the parser, geometry and propagation, but never the
// fetch policy: CelesTrak's two-hour window is unusual enough (a 403 is a cache
// hit, not an error) that it deserves its own tests. Everything here runs
// offline against a scripted HttpClient.

#include "TestSupport.hpp"
#include "TLEFixtures.hpp"

#include "Data/CelesTrakClient.hpp"
#include "Data/SatNOGSSource.hpp"
#include "Data/TLEParser.hpp"
#include "Net/Http.hpp"
#include "Support/Json.hpp"

#include <deque>
#include <functional>
#include <stdexcept>
#include <string>
#include <vector>

using namespace caelus;

namespace {

struct FakeHttp : HttpClient {
    struct Call {
        std::string url;
        std::map<std::string, std::string> headers;
        double timeout = 0.0;
    };

    std::vector<Call> calls;
    std::deque<HttpResponse> replies;
    std::optional<std::string> transportError;

    HttpResponse get(const std::string& url,
                     const std::map<std::string, std::string>& headers,
                     double timeoutSeconds) override {
        calls.push_back(Call{url, headers, timeoutSeconds});
        if (transportError) throw HttpTransportError(*transportError);
        if (replies.empty()) throw HttpTransportError("no scripted reply");
        HttpResponse reply = replies.front();
        replies.pop_front();
        return reply;
    }
};

HttpResponse reply(int status, const std::string& body,
                   const std::map<std::string, std::string>& headers = {}) {
    HttpResponse response;
    response.status = status;
    response.body = body;
    response.headers = headers;
    return response;
}

}  // namespace

// MARK: - URL and body helpers

TEST(Network, BuildsTheCelesTrakURL) {
    CHECK_EQ(CelesTrakClient::url("gps-ops"),
             std::string("https://celestrak.org/NORAD/elements/gp.php?GROUP=gps-ops&FORMAT=tle"));
    CHECK_EQ(CelesTrakClient::url("weather"),
             std::string("https://celestrak.org/NORAD/elements/gp.php?GROUP=weather&FORMAT=tle"));
}

TEST(Network, DetectsElementBodies) {
    CHECK(CelesTrakClient::looksLikeElements(fixtures::issDocument()));
    CHECK(CelesTrakClient::looksLikeElements("garbage\r\n" + fixtures::issLine1 + "\r\n"));
    CHECK(!CelesTrakClient::looksLikeElements("<html>rate limited</html>"));
    CHECK(!CelesTrakClient::looksLikeElements(""));
}

TEST(Network, RecognisesTheNotUpdatedMessage) {
    CHECK(CelesTrakClient::isNotUpdated(
        "GP data has not updated since your last successful download"));
    CHECK(CelesTrakClient::isNotUpdated("This data has not updated since 08:00 UTC"));
    CHECK(!CelesTrakClient::isNotUpdated("Forbidden"));
}

// MARK: - Fetch policy

TEST(Network, SuccessfulFetchReturnsUpdatedBody) {
    FakeHttp http;
    http.replies.push_back(
        reply(200, fixtures::issDocument(), {{"etag", "\"v1\""}}));

    CelesTrakClient client(http);
    const FetchOutcome outcome = client.fetch("active");

    CHECK(outcome.kind == FetchOutcome::Kind::updated);
    CHECK_EQ(outcome.text, fixtures::issDocument());
    CHECK_EQ(http.calls.size(), size_t(1));
    CHECK_EQ(http.calls[0].url, CelesTrakClient::url("active"));
    CHECK_EQ(http.calls[0].headers.at("User-Agent"), std::string("Caelus/0.1 (macOS; personal use)"));
    CHECK(http.calls[0].headers.count("If-None-Match") == 0);
}

TEST(Network, SecondFetchSendsTheStoredEtag) {
    FakeHttp http;
    http.replies.push_back(reply(200, fixtures::issDocument(), {{"etag", "\"v1\""}}));
    http.replies.push_back(reply(304, ""));

    CelesTrakClient client(http);
    CHECK(client.fetch("active").kind == FetchOutcome::Kind::updated);
    const FetchOutcome second = client.fetch("active");

    CHECK(second.kind == FetchOutcome::Kind::unchanged);
    CHECK_EQ(http.calls.size(), size_t(2));
    CHECK_EQ(http.calls[1].headers.at("If-None-Match"), std::string("\"v1\""));
}

TEST(Network, NotModifiedIsUnchanged) {
    FakeHttp http;
    http.replies.push_back(reply(304, ""));
    CelesTrakClient client(http);

    const FetchOutcome outcome = client.fetch("active");
    CHECK(outcome.kind == FetchOutcome::Kind::unchanged);
    CHECK_EQ(outcome.text, std::string("active"));
}

TEST(Network, NotUpdatedForbiddenIsACacheHit) {
    FakeHttp http;
    http.replies.push_back(reply(403, "GP data has not updated since your last download"));
    CelesTrakClient client(http);

    const FetchOutcome outcome = client.fetch("active");
    CHECK(outcome.kind == FetchOutcome::Kind::unchanged);
    CHECK(!client.nextAttempt("active").has_value());
}

TEST(Network, GenericForbiddenBacksOff) {
    FakeHttp http;
    http.replies.push_back(reply(403, "Forbidden\n"));
    CelesTrakClient client(http);

    double now = 1000.0;
    client.setClock([&now] { return now; });

    try {
        client.fetch("active");
        CHECK(false);
    } catch (const CelesTrakClient::FetchError& error) {
        CHECK(error.kind == CelesTrakClient::FetchErrorKind::http);
        CHECK_EQ(error.status, 403);
        CHECK_EQ(error.what(), std::string("Forbidden"));
        CHECK(!error.isRetryable());
    }

    // The first rung of the backoff ladder is one minute.
    const auto until = client.nextAttempt("active");
    CHECK(until.has_value());
    if (until) CHECK_NEAR(*until, now + 60.0, 1e-9);

    try {
        client.fetch("active");
        CHECK(false);
    } catch (const CelesTrakClient::FetchError& error) {
        CHECK(error.kind == CelesTrakClient::FetchErrorKind::backedOff);
        CHECK_EQ(error.shortDescription().rfind("retry after ", 0), size_t(0));
    }
    CHECK_EQ(http.calls.size(), size_t(1));
}

TEST(Network, BackoffLadderGrowsAndCaps) {
    FakeHttp http;
    for (int step = 0; step < 4; ++step) http.replies.push_back(reply(500, "boom"));

    CelesTrakClient client(http);
    double now = 1000.0;
    client.setClock([&now] { return now; });

    const std::vector<double> expected = {60.0, 300.0, 1800.0, 1800.0};
    for (double delay : expected) {
        try {
            client.fetch("active");
            CHECK(false);
        } catch (const CelesTrakClient::FetchError& error) {
            CHECK(error.kind == CelesTrakClient::FetchErrorKind::http);
            CHECK(error.isRetryable());
            CHECK_EQ(error.status, 500);
        }
        const auto until = client.nextAttempt("active");
        CHECK(until.has_value());
        if (until) CHECK_NEAR(*until, now + delay, 1e-9);
        now += delay;
    }
}

TEST(Network, SuccessClearsTheBackoff) {
    FakeHttp http;
    http.replies.push_back(reply(500, "boom"));
    http.replies.push_back(reply(200, fixtures::issDocument()));

    CelesTrakClient client(http);
    double now = 1000.0;
    client.setClock([&now] { return now; });

    CHECK_THROWS(client.fetch("active"));
    now += 61.0;
    CHECK(client.fetch("active").kind == FetchOutcome::Kind::updated);
    CHECK(!client.nextAttempt("active").has_value());
}

TEST(Network, TransportFailureIsRetryable) {
    FakeHttp http;
    http.transportError = "The Internet connection appears to be offline.";

    CelesTrakClient client(http);
    try {
        client.fetch("active");
        CHECK(false);
    } catch (const CelesTrakClient::FetchError& error) {
        CHECK(error.kind == CelesTrakClient::FetchErrorKind::transport);
        CHECK(error.isRetryable());
        CHECK_EQ(error.what(), std::string("The Internet connection appears to be offline."));
    }
    CHECK(client.nextAttempt("active").has_value());
}

TEST(Network, MalformedBodyIsRejected) {
    FakeHttp http;
    http.replies.push_back(reply(200, "<html>maintenance</html>"));

    CelesTrakClient client(http);
    try {
        client.fetch("active");
        CHECK(false);
    } catch (const CelesTrakClient::FetchError& error) {
        CHECK(error.kind == CelesTrakClient::FetchErrorKind::malformed);
        CHECK_EQ(error.what(), std::string("response did not contain element sets"));
        CHECK(!error.isRetryable());
    }
}

TEST(Network, NotFoundIsAnImmediateErrorWithoutBackoff) {
    FakeHttp http;
    http.replies.push_back(reply(404, "no such group"));

    CelesTrakClient client(http);
    try {
        client.fetch("nope");
        CHECK(false);
    } catch (const CelesTrakClient::FetchError& error) {
        CHECK_EQ(error.status, 404);
        CHECK_EQ(error.shortDescription(), std::string("HTTP 404"));
    }
    CHECK(!client.nextAttempt("nope").has_value());
}

// MARK: - SatNOGS

TEST(Network, SatNOGSReassemblesThreeLineElements) {
    const std::string json = R"json([
        {"norad_cat_id": 25544, "tle0": "0 ISS (ZARYA)",
         "tle1": "1 25544U 98067A   26315.33607970  .00009043  00000+0  17017-3 0  9996",
         "tle2": "2 25544  51.6323 291.9174 0007326  13.1877 346.9302 15.49313022594566"}
    ])json";

    FakeHttp http;
    http.replies.push_back(reply(200, json));

    const std::string text = SatNOGSSource::fetchTLE(http);
    CHECK_EQ(http.calls.front().url, SatNOGSSource::endpoint());

    const TLEParser::Result parsed = TLEParser::parse(text, {});
    CHECK_EQ(parsed.records.size(), size_t(1));
    CHECK_EQ(parsed.records.front().id, 25544);
    CHECK_EQ(parsed.records.front().name, std::string("ISS (ZARYA)"));
}

TEST(Network, SatNOGSEmptyArrayIsMalformed) {
    FakeHttp http;
    http.replies.push_back(reply(200, "[]"));

    try {
        SatNOGSSource::fetchTLE(http);
        CHECK(false);
    } catch (const SatNOGSSource::SourceError& error) {
        CHECK(error.kind == SatNOGSSource::ErrorKind::malformed);
        CHECK_EQ(error.what(), std::string("SatNOGS returned no elements"));
    }
}

TEST(Network, SatNOGSHttpFailureReportsStatus) {
    FakeHttp http;
    http.replies.push_back(reply(503, "unavailable"));

    try {
        SatNOGSSource::fetchTLE(http);
        CHECK(false);
    } catch (const SatNOGSSource::SourceError& error) {
        CHECK(error.kind == SatNOGSSource::ErrorKind::http);
        CHECK_EQ(error.status, 503);
        CHECK_EQ(error.shortDescription(), std::string("HTTP 503"));
    }
}

TEST(Network, SatNOGSBadJsonIsMalformed) {
    FakeHttp http;
    http.replies.push_back(reply(200, "{not an array"));

    try {
        SatNOGSSource::fetchTLE(http);
        CHECK(false);
    } catch (const SatNOGSSource::SourceError& error) {
        CHECK(error.kind == SatNOGSSource::ErrorKind::malformed);
    }
}

// MARK: - JSON

TEST(Json, ParsesObjectsArraysAndScalars) {
    const auto value = JsonValue::parse(R"({"a": [1, 2.5, "x", true, null], "b": {"c": 3}})");
    CHECK(value.has_value());
    if (!value) return;

    CHECK(value->type() == JsonValue::Type::object);
    CHECK_EQ(value->members().size(), size_t(2));

    const JsonValue* a = value->member("a");
    CHECK(a != nullptr);
    if (a != nullptr) {
        CHECK_EQ(a->elements().size(), size_t(5));
        CHECK(a->elements()[0]->numberOr(-1.0) == 1.0);
        CHECK_EQ(a->elements()[2]->stringOr(""), std::string("x"));
        CHECK(a->elements()[3]->booleanOr(false));
        CHECK(a->elements()[4]->isNull());
    }

    const JsonValue* b = value->member("b");
    CHECK(b != nullptr);
    if (b != nullptr && b->member("c") != nullptr) CHECK(b->member("c")->numberOr(-1.0) == 3.0);
}

TEST(Json, HandlesEscapesAndSurrogatePairs) {
    const auto value = JsonValue::parse(R"({"s": "line\nbreak é 🚀"})");
    CHECK(value.has_value());
    if (!value) return;
    const JsonValue* s = value->member("s");
    CHECK(s != nullptr);
    if (s == nullptr) return;
    CHECK(s->stringOr("").rfind("line\nbreak", 0) == 0);
    CHECK_EQ(s->stringOr("").size(), std::string("line\nbreak \xc3\xa9 \xf0\x9f\x9a\x80").size());
}

TEST(Json, RejectsTrailingGarbageAndTruncation) {
    CHECK(!JsonValue::parse("{} x").has_value());
    CHECK(!JsonValue::parse("{\"a\": 1").has_value());
    CHECK(!JsonValue::parse("[1, 2,]").has_value());
    CHECK(!JsonValue::parse("").has_value());
    CHECK(JsonValue::parse("null").has_value());
}
