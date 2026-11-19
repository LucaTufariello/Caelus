// TimeUtil.hpp — Julian dates, epochs and the app's Date value type.
//
// The app keeps time as seconds since the Unix epoch (1970-01-01T00:00:00Z); the
// propagators work in Julian dates and in "days since 1950", the TLE epoch reference.

#pragma once

#include <chrono>
#include <cmath>

namespace caelus::sky {

constexpr double kJulianEpoch1900 = 2415020.0;  // 1900 Jan 0.5
constexpr double kJulianEpoch1950 = 2433281.5;  // 1949-Dec-31 00:00:00 UTC
constexpr double kJulianEpochUnix = 2440587.5;  // 1970-Jan-01 00:00:00 UTC
constexpr double kJulianEpoch2000 = 2451545.0;  // 2000 Jan 1.5

constexpr double kDay2Hours = 24.0;
constexpr double kHours2Day = 1.0 / 24.0;
constexpr double kDay2Minutes = 24.0 * 60.0;
constexpr double kMinute2Day = 1.0 / kDay2Minutes;
constexpr double kDay2Seconds = 24.0 * 60.0 * 60.0;
constexpr double kSecond2Day = 1.0 / kDay2Seconds;
constexpr double kDaysPerCentury = 36525.0;

// Seconds since 1970-01-01T00:00:00Z.
using Date = double;

inline Date nowDate() {
    using namespace std::chrono;
    return duration<double>(system_clock::now().time_since_epoch()).count();
}

inline double julianFromDate(Date date) { return kJulianEpochUnix + date * kSecond2Day; }

inline Date dateFromJulian(double julianDays) { return (julianDays - kJulianEpochUnix) * kDay2Seconds; }

inline double daysSince1950(double julianDays) { return julianDays - kJulianEpoch1950; }

inline Date dateFromDays1950(double ds1950) { return dateFromJulian(kJulianEpoch1950 + ds1950); }

inline double dateToDays1950(Date date) { return julianFromDate(date) - kJulianEpoch1950; }

inline double julianDaysNow() { return julianFromDate(nowDate()); }

inline double ep1950DaysNow() { return julianDaysNow() - kJulianEpoch1950; }

// Calendar helpers used by the UI and by the cache metadata.

struct CivilTime {
    int year = 1970;
    int month = 1;
    int day = 1;
    int hour = 0;
    int minute = 0;
    int second = 0;
    int weekday = 4;  // 0 = Sunday ... 3 = Wednesday; 1970-01-01 was a Thursday
};

// Convert a Date to UTC calendar fields (Howard Hinnant's civil-from-days algorithm).
inline CivilTime civilTime(Date date) {
    const long long unixSeconds = static_cast<long long>(std::floor(date));
    const long long dayNumber = unixSeconds >= 0 ? unixSeconds / 86400
                                                 : -((-unixSeconds + 86399) / 86400);
    const long long secondsOfDay = unixSeconds - dayNumber * 86400;

    // 1970-01-01 was day 0 and a Thursday.
    const long long z = dayNumber + 719468;
    const long long era = (z >= 0 ? z : z - 146096) / 146097;
    const long long doe = z - era * 146097;                                   // [0, 146096]
    const long long yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;  // [0, 399]
    const long long y = yoe + era * 400;
    const long long doy = doe - (365 * yoe + yoe / 4 - yoe / 100);            // [0, 365]
    const long long mp = (5 * doy + 2) / 153;                                 // [0, 11]
    const long long d = doy - (153 * mp + 2) / 5 + 1;                         // [1, 31]
    const long long m = mp < 10 ? mp + 3 : mp - 9;                            // [1, 12]

    CivilTime t;
    t.year = static_cast<int>(y + (m <= 2 ? 1 : 0));
    t.month = static_cast<int>(m);
    t.day = static_cast<int>(d);
    t.hour = static_cast<int>(secondsOfDay / 3600);
    t.minute = static_cast<int>((secondsOfDay % 3600) / 60);
    t.second = static_cast<int>(secondsOfDay % 60);
    t.weekday = static_cast<int>(((dayNumber % 7) + 11) % 7);  // 0 = Sunday
    return t;
}

// Days since 1950 for a UTC calendar day number (days since 1970-01-01).
inline double epochDaysFromCivil(int year, double dayOfYear) {
    return static_cast<double>(year - 1950) * 365.0 +
           static_cast<double>((year - 1949) / 4) + dayOfYear;
}

}  // namespace caelus::sky
