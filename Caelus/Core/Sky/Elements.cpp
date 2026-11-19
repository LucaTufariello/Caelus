#include "Elements.hpp"

#include <cctype>
#include <cmath>
#include <cstdlib>
#include <sstream>

#include "Astro.hpp"
#include "TimeUtil.hpp"

namespace caelus::sky {
namespace {

std::string trimmed(const std::string& s) {
    size_t begin = 0;
    size_t end = s.size();
    while (begin < end && std::isspace(static_cast<unsigned char>(s[begin]))) ++begin;
    while (end > begin && std::isspace(static_cast<unsigned char>(s[end - 1]))) --end;
    return s.substr(begin, end - begin);
}

// Swift's Int("..") / Double("..") fail on an empty string: an unparsable field is an error.
double parseDoubleField(const std::string& text, const char* fieldName) {
    const std::string t = trimmed(text);
    if (t.empty()) throw TLEError(std::string("unreadable ") + fieldName + " field ..");
    char* end = nullptr;
    const double value = std::strtod(t.c_str(), &end);
    if (end == t.c_str() || *end != '\0') {
        throw TLEError(std::string("unreadable ") + fieldName + " field ..");
    }
    return value;
}

int parseIntField(const std::string& text, const char* fieldName) {
    const std::string t = trimmed(text);
    if (t.empty()) throw TLEError(std::string("unreadable ") + fieldName + " field ..");
    char* end = nullptr;
    const long value = std::strtol(t.c_str(), &end, 10);
    if (end == t.c_str() || *end != '\0') {
        throw TLEError(std::string("unreadable ") + fieldName + " field ..");
    }
    return static_cast<int>(value);
}

// Convenience: TLE epoch YYDDD.DDDDDDDD to days since 1950.
double epochDays(int year, double days) {
    return static_cast<double>(year - 1950) * 365.0 +
           static_cast<double>((year - 1949) / 4) + days;
}

}  // namespace

uint32_t alpha5ID(const std::string& noradID) {
    std::string upper;
    upper.reserve(noradID.size());
    for (char c : noradID) upper.push_back(static_cast<char>(std::toupper(static_cast<unsigned char>(c))));

    std::string lastFive = "00000" + upper;
    lastFive = lastFive.substr(lastFive.size() - 5);

    const char first = lastFive[0];
    const std::string rest = lastFive.substr(1);
    if (rest.find_first_not_of("0123456789") != std::string::npos) return 0;
    const uint32_t seqNo = static_cast<uint32_t>(std::strtoul(rest.c_str(), nullptr, 10));

    if (first >= '0' && first <= '9') return static_cast<uint32_t>(first - 48) * 10000 + seqNo;
    if (first >= 'A' && first <= 'H') return static_cast<uint32_t>(first - 55) * 10000 + seqNo;
    if (first >= 'J' && first <= 'N') return static_cast<uint32_t>(first - 56) * 10000 + seqNo;
    if (first >= 'P' && first <= 'Z') return static_cast<uint32_t>(first - 57) * 10000 + seqNo;
    return 0;
}

Elements Elements::parse(const std::string& line0, const std::string& line1,
                         const std::string& line2) {
    if (line1.size() < 69) throw TLEError("line 1 too short ..");
    if (line2.size() < 69) throw TLEError("line 2 too short ..");

    const std::string& l1 = line1;
    const std::string& l2 = line2;

    Elements el;
    el.commonName = line0.rfind("0 ", 0) == 0 ? line0.substr(2) : line0;

    el.noradIndex = alpha5ID(l1.substr(2, 5));
    el.tleClass = l1.substr(7, 1);

    int launchYear = 56;  // parse failure -> year 2056
    try {
        launchYear = parseIntField(l1.substr(9, 2), "launch year");
    } catch (const TLEError&) {
        launchYear = 56;
    }
    const std::string launchPart = trimmed(l1.substr(11, 6));
    std::ostringstream launch;
    launch << (launchYear < 57 ? 2000 : 1900 + launchYear) << "-" << launchPart;
    el.launchName = launch.str();

    const int epochYear = parseIntField(l1.substr(18, 2), "epoch year");
    el.t0 = epochDays((epochYear < 57 ? 2000 : 1900) + epochYear,
                      parseDoubleField(l1.substr(20, 12), "epoch day"));

    const char dragSign = (l1[53] == ' ' || l1[53] == '+') ? '+' : '-';
    const char expSign = (l1[59] == ' ' || l1[59] == '+') ? '+' : '-';
    {
        std::string drag;
        drag += dragSign;
        drag += '.';
        drag += l1.substr(54, 1);
        drag += l1.substr(55, 4);
        drag += 'e';
        drag += expSign;
        drag += l1.substr(60, 1);
        char* end = nullptr;
        el.dragCoeff = std::strtod(drag.c_str(), &end);
        if (end == drag.c_str() || *end != '\0') throw TLEError("unreadable drag term ..");
    }

    try {
        el.ephemType = parseIntField(l1.substr(62, 1), "ephemeris type");
    } catch (const TLEError&) {
        el.ephemType = 0;
    }
    el.tleNumber = parseIntField(l1.substr(64, 4), "element number");

    if (el.noradIndex != alpha5ID(l2.substr(2, 5))) {
        throw TLEError("Line1 and Line2 NORAD IDs don't match ..");
    }

    el.i0 = parseDoubleField(l2.substr(8, 8), "inclination") * deg2rad;
    el.raan0 = parseDoubleField(l2.substr(17, 8), "RAAN") * deg2rad;

    {
        std::string ecc = "." + l2.substr(26, 7);
        for (char& c : ecc) {
            if (c == ' ') c = '0';
        }
        char* end = nullptr;
        el.e0 = std::strtod(ecc.c_str(), &end);
        if (end == ecc.c_str() || *end != '\0') throw TLEError("unreadable eccentricity ..");
    }

    el.w0 = parseDoubleField(l2.substr(34, 8), "argument of perigee") * deg2rad;
    el.M0 = parseDoubleField(l2.substr(43, 8), "mean anomaly") * deg2rad;
    el.n0Prime = parseDoubleField(l2.substr(52, 11), "mean motion");
    el.revNumber = parseIntField(l2.substr(63, 5), "revolution number");

    if (el.ephemType != 0 && el.ephemType != 2 && el.ephemType != 3) {
        std::ostringstream message;
        message << "Line1 ephemerisType ≠ 0, 2 or 3 .. [" << el.ephemType << "]";
        throw TLEError(message.str());
    }

    // Recover (un-Kozai) original mean motion and semi-major axis from the input elements.
    const double n0PrimeRad = el.n0Prime * (kPi / 720.0);
    const double theta = std::cos(el.i0);
    const double x3thm1 = 3.0 * theta * theta - 1.0;
    const double beta0 = std::sqrt(1.0 - el.e0 * el.e0);
    const double temp = 1.5 * EarthConstants::K2 * x3thm1 / (beta0 * beta0 * beta0);

    const double a0Prime = std::pow(EarthConstants::k_e / n0PrimeRad, kTwoThirds);
    const double delta1 = temp / (a0Prime * a0Prime);
    const double a1 = a0Prime * (1.0 - delta1 * (kOneThird + delta1 * (1.0 + 134.0 / 81.0 * delta1)));
    const double delta0 = temp / (a1 * a1);

    el.n0 = n0PrimeRad / (1.0 + delta0);
    el.a0 = a1 / (1.0 - delta0);

    return el;
}

}  // namespace caelus::sky
