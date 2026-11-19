// MathUtil.hpp — angles, 3-vectors and small numeric helpers.
//
// Ported from SatelliteKit (https://github.com/gavineadie/SatelliteKit), MIT licence,
// © 2017-25 Gavin Eadie. Formatting and identifiers changed for C++; the arithmetic is
// unchanged so propagated positions match the library this app shipped with.

#pragma once

#include <cmath>

namespace caelus::sky {

constexpr double kPi = 3.14159265358979323846;
constexpr double kOneThird = 1.0 / 3.0;
constexpr double kTwoThirds = 2.0 / 3.0;
constexpr double deg2rad = kPi / 180.0;
constexpr double rad2deg = 180.0 / kPi;

struct Vec3 {
    double x = 0.0;
    double y = 0.0;
    double z = 0.0;

    constexpr Vec3() = default;
    constexpr Vec3(double x_, double y_, double z_) : x(x_), y(y_), z(z_) {}

    Vec3 operator-() const { return {-x, -y, -z}; }
    Vec3 operator+(const Vec3& o) const { return {x + o.x, y + o.y, z + o.z}; }
    Vec3 operator-(const Vec3& o) const { return {x - o.x, y - o.y, z - o.z}; }
    bool operator==(const Vec3& o) const { return x == o.x && y == o.y && z == o.z; }

    double magnitude() const { return std::sqrt(x * x + y * y + z * z); }
};

inline double magnitude(const Vec3& v) { return v.magnitude(); }

inline Vec3 normalize(const Vec3& v) {
    const double m = v.magnitude();
    // A zero-length vector cannot be normalised; the caller must avoid it.
    if (m <= 0.0) return {};
    return {v.x / m, v.y / m, v.z / m};
}

inline double dotProduct(const Vec3& a, const Vec3& b) {
    return a.x * b.x + a.y * b.y + a.z * b.z;
}

inline Vec3 crossProduct(const Vec3& a, const Vec3& b) {
    return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x};
}

// Angle between two vectors, in degrees.
inline double separation(const Vec3& a, const Vec3& b) {
    return std::acos(dotProduct(a, b) / (a.magnitude() * b.magnitude())) * rad2deg;
}

// atan2 mapped to [0, 2π); zero for the origin.
inline double atan2pi(double y, double x) {
    if (x == 0.0 && y == 0.0) return 0.0;
    double r = std::fmod(std::atan2(y, x), 2.0 * kPi);
    if (r < 0.0) r += 2.0 * kPi;
    return r;
}

// acos mapped to [0, π] for y > 0 and (π, 2π] for y < 0.
inline double acos2pi(double x, double y) {
    if (y > 0.0) return std::acos(x / y);
    if (y < 0.0) return kPi + std::acos(x / y);
    return 0.0;
}

// Limit radians to -π..π.
inline double fmod2pi_0(double angle) {
    return angle - (2.0 * kPi) * std::floor((angle + kPi) / (2.0 * kPi));
}

// Limit radians to 0..2π.
inline double fmod2pi_pi(double radians) {
    double r = std::fmod(radians, 2.0 * kPi);
    if (r < 0.0) r += 2.0 * kPi;
    return r;
}

// Limit degrees to -180..180.
inline double limit180(double value) {
    while (value > 180.0) value -= 360.0;
    while (value < -180.0) value += 360.0;
    return value;
}

// Limit degrees to 0..360.
inline double limit360(double value) {
    while (value > 360.0) value -= 360.0;
    while (value < 0.0) value += 360.0;
    return value;
}

}  // namespace caelus::sky
