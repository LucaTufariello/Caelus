// TestSupport.hpp — the small self-contained test harness for the C++ core.
//
// The Swift suite used XCTest; the core is deliberately dependency-free, so its
// tests carry their own runner. Registration is static, every test is a plain
// function, and a failure throws — which means a test stops at its first
// broken expectation but the rest of the suite still runs.

#pragma once

#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace test {

struct Case {
    std::string suite;
    std::string name;
    void (*function)();
};

std::vector<Case>& registry();

struct Registrar {
    Registrar(const char* suite, const char* name, void (*function)()) {
        registry().push_back(Case{suite, name, function});
    }
};

// Thrown by the assertion macros; caught by the runner.
struct Failure : std::runtime_error {
    using std::runtime_error::runtime_error;
};

[[noreturn]] void fail(const char* file, int line, const std::string& message);

template <typename T>
std::string describe(const T& value) {
    std::ostringstream stream;
    stream << value;
    return stream.str();
}
std::string describe(bool value);
std::string describe(const std::string& value);

// Entry point: `caelus-core-tests [substring]`. Returns the number of failures.
int runAll(int argc, char** argv);

}  // namespace test

#define TEST(suite, name)                                                     \
    static void suite##_##name##_body();                                      \
    static const ::test::Registrar suite##_##name##_registration(              \
        #suite, #name, suite##_##name##_body);                                \
    static void suite##_##name##_body()

#define CHECK(condition)                                                      \
    do {                                                                      \
        if (!(condition)) {                                                   \
            ::test::fail(__FILE__, __LINE__, "CHECK(" #condition ")");        \
        }                                                                     \
    } while (false)

#define CHECK_EQ(actual, expected)                                            \
    do {                                                                      \
        const auto& actual_ = (actual);                                       \
        const auto& expected_ = (expected);                                   \
        if (!(actual_ == expected_)) {                                        \
            ::test::fail(__FILE__, __LINE__,                                  \
                         std::string("CHECK_EQ(" #actual ", " #expected ")\n") \
                             + "  actual:   " + ::test::describe(actual_)     \
                             + "\n  expected: " + ::test::describe(expected_));\
        }                                                                     \
    } while (false)

#define CHECK_NEAR(actual, expected, tolerance)                               \
    do {                                                                      \
        const auto actual_ = (actual);                                        \
        const auto expected_ = (expected);                                    \
        const auto tolerance_ = (tolerance);                                  \
        const auto difference_ = (actual_ > expected_ ? actual_ - expected_   \
                                                      : expected_ - actual_); \
        if (!(difference_ <= tolerance_)) {                                   \
            ::test::fail(                                                     \
                __FILE__, __LINE__,                                           \
                std::string("CHECK_NEAR(" #actual ", " #expected ") by ")     \
                    + #tolerance + "\n  actual:   " + ::test::describe(actual_)\
                    + "\n  expected: " + ::test::describe(expected_)          \
                    + "\n  difference: " + ::test::describe(difference_));    \
        }                                                                     \
    } while (false)

#define CHECK_THROWS(expression)                                              \
    do {                                                                      \
        bool threw_ = false;                                                  \
        try {                                                                 \
            (void)(expression);                                               \
        } catch (...) {                                                       \
            threw_ = true;                                                    \
        }                                                                     \
        if (!threw_) {                                                        \
            ::test::fail(__FILE__, __LINE__,                                  \
                         "CHECK_THROWS(" #expression ") did not throw");      \
        }                                                                     \
    } while (false)

namespace test {

// Days since 1970-01-01 for a proleptic Gregorian date (Hinnant's algorithm).
inline long long daysFromCivil(int year, int month, int day) {
    long long y = year;
    const unsigned m = static_cast<unsigned>(month);
    const unsigned d = static_cast<unsigned>(day);
    y -= m <= 2;
    const long long era = (y >= 0 ? y : y - 399) / 400;
    const unsigned yoe = static_cast<unsigned>(y - era * 400);
    const unsigned doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
    const unsigned doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + static_cast<long long>(doe) - 719468;
}

// A UTC instant, in the core's Date units (seconds since 1970-01-01).
inline double utc(int year, int month, int day, int hour = 12) {
    return static_cast<double>(daysFromCivil(year, month, day)) * 86400.0 +
           static_cast<double>(hour) * 3600.0;
}

}  // namespace test
