// DeepSDP4.cpp — deep-space (SDP4) propagation: luni-solar perturbations and geopotential
// resonance terms for orbits with periods of 225 minutes or more.
//
// Ported from SatelliteKit, MIT licence, © 2017-25 Gavin Eadie.

#include <cmath>

#include "Astro.hpp"
#include "Propagator.hpp"

namespace caelus::sky {
namespace {

double cubicPoly(double x, double p0, double p1, double p2, double p3) {
    return p0 + x * (p1 + x * (p2 + x * p3));
}

// The deep-space propagator: constructed fresh for every call, exactly as the Swift
// propagation path did, so results never depend on the order of earlier calls.
class DeepSDP4 {
public:
    explicit DeepSDP4(const Elements& tle);

    PVCoordinates getPVCoordinates(double minsAfterEpoch);

private:
    void sxpPropagate(double minsAfterEpoch);
    void luniSolarTermsComputation();
    void deepSecularEffects(double mins);
    void deepPeriodicEffects(double mins);
    void computeSecularDerivs();

    static constexpr double zeSolar = 0.01675;   // mean eccentricity of the Sun's "orbit"
    static constexpr double zeLunar = 0.05490;   // mean eccentricity of the Moon's orbit
    static constexpr double znSolar = 1.19459e-5;   // d(solar mean anomaly)/dt, rad/min
    static constexpr double znLunar = 1.5835218e-4; // d(lunar mean anomaly)/dt, rad/min
    static constexpr double THDT = 4.3752691e-3;    // Earth angular velocity, rad/min
    static constexpr double C1SS = 2.9864797e-6;
    static constexpr double C1L = 4.7968065e-7;
    static constexpr double SECULAR_INTEGRATION_STEP = 720.0;  // ½ day, minutes

    Elements tle_;
    PropagatorData data_;

    // Final state handed to the short-period corrections.
    double e_ = 0.0;
    double i_ = 0.0;
    double w_ = 0.0;
    double raan_ = 0.0;
    double a_ = 0.0;
    double xl_ = 0.0;
    double sini_ = 0.0;
    double cosi_ = 0.0;

    double wNew_ = 0.0;
    double nNew_ = 0.0;
    double eNew_ = 0.0;
    double iNew_ = 0.0;
    double xll_ = 0.0;

    double gmst_ = 0.0;
    double xnq_ = 0.0;
    double zmol_ = 0.0;
    double zmos_ = 0.0;
    double savtsn_ = 0.0;

    double ee2_ = 0.0;
    double e3_ = 0.0;
    double xi2_ = 0.0, xi3_ = 0.0;
    double xl2_ = 0.0, xl3_ = 0.0, xl4_ = 0.0;
    double xgh2_ = 0.0, xgh3_ = 0.0, xgh4_ = 0.0;
    double xh2_ = 0.0, xh3_ = 0.0;

    double d2201_ = 0.0, d2211_ = 0.0;
    double d3210_ = 0.0, d3222_ = 0.0;
    double d4410_ = 0.0, d4422_ = 0.0;
    double d5220_ = 0.0, d5232_ = 0.0;
    double d5421_ = 0.0, d5433_ = 0.0;
    double xlamo_ = 0.0;

    double sse_ = 0.0, se2_ = 0.0, se3_ = 0.0;
    double ssi_ = 0.0, si2_ = 0.0, si3_ = 0.0;
    double ssl_ = 0.0, sl2_ = 0.0, sl3_ = 0.0, sl4_ = 0.0;
    double ssh_ = 0.0, sh2_ = 0.0, sh3_ = 0.0;
    double ssg_ = 0.0, sgh2_ = 0.0, sgh3_ = 0.0, sgh4_ = 0.0;

    double del1_ = 0.0, del2_ = 0.0, del3_ = 0.0;
    double xfact_ = 0.0;
    double xli_ = 0.0;
    double xni_ = 0.0;
    double atime_ = 0.0;

    double derivs0_ = 0.0, derivs1_ = 0.0;

    bool resonant_ = false;
    bool synchronous_ = false;
    bool isDundeeCompliant_ = false;
};

DeepSDP4::DeepSDP4(const Elements& tle) : tle_(tle), data_(createPropagatorData(tle)) {
    luniSolarTermsComputation();
}

void DeepSDP4::luniSolarTermsComputation() {
    const double sinq = std::sin(tle_.raan0);
    const double cosq = std::cos(tle_.raan0);
    const double aqnv = 1.0 / tle_.a0;

    double cc = C1SS;
    double ze = zeSolar;
    double zn = znSolar;

    gmst_ = zeroMeanSiderealTime(tle_.t0 + kJulianEpoch1950) * deg2rad;
    xnq_ = tle_.n0;

    const double days1900 = tle_.t0 + (kJulianEpoch1950 - kJulianEpoch1900);

    const double lunarAscNode = 4.5236020 - 9.2422029e-4 * days1900;
    const double stem = std::sin(lunarAscNode);
    const double ctem = std::cos(lunarAscNode);
    const double cMinusGam = 0.228027132 * days1900 - 1.1151842;
    const double gam = 5.8351514 + 0.0019443680 * days1900;  // longitude of lunar perigee

    const double zcosil = 0.91375164 - 0.03568096 * ctem;
    const double zsinil = std::sqrt(1.0 - zcosil * zcosil);
    const double zsinhl = 0.089683511 * stem / zsinil;
    const double zcoshl = std::sqrt(1.0 - zsinhl * zsinhl);

    zmol_ = fmod2pi_pi(cMinusGam);

    double zx = 0.39785416 * stem / zsinil;
    const double zy = zcoshl * ctem + 0.91744867 * zsinhl * stem;
    zx = std::atan2(zx, zy) + gam - lunarAscNode;
    const double zcosgl = std::cos(zx);
    const double zsingl = std::sin(zx);
    zmos_ = fmod2pi_pi(6.2565837 + 0.017201977 * days1900);

    savtsn_ = 1e20;  // do solar terms

    double zsing = -0.98088458;  // sin of -78.779197 degrees
    double zcosg = 0.1945905;
    double zsinh = sinq;
    double zcosh = cosq;

    double zsini = 0.39785416;  // sin of 23.444100 degrees
    double zcosi = 0.91744867;

    double se = 0.0;
    double sgh = 0.0;
    double sh = 0.0;
    double si = 0.0;
    double sl = 0.0;

    // Solar terms, then lunar terms, then solar again with the improved lunar data.
    for (int iteration = 0; iteration <= 1; ++iteration) {
        const double a1 = zcosg * zcosh + zsing * zcosi * zsinh;
        const double a3 = -zsing * zcosh + zcosg * zcosi * zsinh;
        const double a7 = -zcosg * zsinh + zsing * zcosi * zcosh;
        const double a8 = zsing * zsini;
        const double a9 = zsing * zsinh + zcosg * zcosi * zcosh;
        const double a10 = zcosg * zsini;

        const double a2 = data_.cosi0 * a7 + data_.sini0 * a8;
        const double a4 = data_.cosi0 * a9 + data_.sini0 * a10;
        const double a5 = -data_.sini0 * a7 + data_.cosi0 * a8;
        const double a6 = -data_.sini0 * a9 + data_.cosi0 * a10;

        const double sing = std::sin(tle_.w0);
        const double cosg = std::cos(tle_.w0);

        const double x1 = a1 * cosg + a2 * sing;
        const double x2 = a3 * cosg + a4 * sing;
        const double x3 = -a1 * sing + a2 * cosg;
        const double x4 = -a3 * sing + a4 * cosg;
        const double x5 = a5 * sing;
        const double x6 = a6 * sing;
        const double x7 = a5 * cosg;
        const double x8 = a6 * cosg;

        const double z31 = 12.0 * x1 * x1 - 3.0 * x3 * x3;
        const double z32 = 24.0 * x1 * x2 - 6.0 * x3 * x4;
        const double z33 = 12.0 * x2 * x2 - 3.0 * x4 * x4;
        const double z11 = -6.0 * a1 * a5 + data_.e0sq * (-24.0 * x1 * x7 - 6.0 * x3 * x5);
        const double z12 = -6.0 * (a1 * a6 + a3 * a5) +
                           data_.e0sq * (-24.0 * (x2 * x7 + x1 * x8) - 6.0 * (x3 * x6 + x4 * x5));
        const double z13 = -6.0 * a3 * a6 + data_.e0sq * (-24.0 * x2 * x8 - 6.0 * x4 * x6);
        const double z21 = 6.0 * a2 * a5 + data_.e0sq * (24.0 * x1 * x5 - 6.0 * x3 * x7);
        const double z22 = 6.0 * (a4 * a5 + a2 * a6) +
                           data_.e0sq * (24.0 * (x2 * x5 + x1 * x6) - 6.0 * (x4 * x7 + x3 * x8));
        const double z23 = 6.0 * a4 * a6 + data_.e0sq * (24.0 * x2 * x6 - 6.0 * x4 * x8);

        const double s3 = cc / xnq_;
        const double s2 = -0.5 * s3 / data_.beta0;
        const double s4 = s3 * data_.beta0;
        const double s1 = -15.0 * tle_.e0 * s4;
        const double s5 = x1 * x3 + x2 * x4;
        const double s6 = x2 * x3 + x1 * x4;
        const double s7 = x2 * x4 - x1 * x3;

        double z1 = 3.0 * (a1 * a1 + a2 * a2) + z31 * data_.e0sq;
        double z2 = 6.0 * (a1 * a3 + a2 * a4) + z32 * data_.e0sq;
        double z3 = 3.0 * (a3 * a3 + a4 * a4) + z33 * data_.e0sq;

        z1 = z1 + z1 + data_.beta0sq * z31;
        z2 = z2 + z2 + data_.beta0sq * z32;
        z3 = z3 + z3 + data_.beta0sq * z33;
        se = s1 * zn * s5;
        si = s2 * zn * (z11 + z13);
        sl = -zn * s3 * (z1 + z3 - 14.0 - 6.0 * data_.e0sq);
        sgh = s4 * zn * (z31 + z33 - 6.0);

        sh = tle_.i0 < kPi / 60.0 ? 0.0 : -zn * s2 * (z21 + z23);

        ee2_ = 2.0 * s1 * s6;
        e3_ = 2.0 * s1 * s7;
        xi2_ = 2.0 * s2 * z12;
        xi3_ = 2.0 * s2 * (z13 - z11);
        xl2_ = -2.0 * s3 * z2;
        xl3_ = -2.0 * s3 * (z3 - z1);
        xl4_ = -2.0 * s3 * (-21.0 - 9.0 * data_.e0sq) * ze;
        xgh2_ = 2.0 * s4 * z32;
        xgh3_ = 2.0 * s4 * (z33 - z31);
        xgh4_ = -18.0 * s4 * ze;
        xh2_ = -2.0 * s2 * z22;
        xh3_ = -2.0 * s2 * (z23 - z21);

        if (iteration == 0) {  // compute lunar terms on the first pass only
            sse_ = se;
            ssi_ = si;
            ssl_ = sl;
            ssh_ = tle_.i0 < kPi / 60.0 ? 0.0 : sh / data_.sini0;
            ssg_ = sgh - data_.cosi0 * ssh_;
            se2_ = ee2_;
            si2_ = xi2_;
            sl2_ = xl2_;
            sgh2_ = xgh2_;
            sh2_ = xh2_;
            se3_ = e3_;
            si3_ = xi3_;
            sl3_ = xl3_;
            sgh3_ = xgh3_;
            sh3_ = xh3_;
            sl4_ = xl4_;
            sgh4_ = xgh4_;

            zcosg = zcosgl;
            zsing = zsingl;
            zcosi = zcosil;
            zsini = zsinil;
            zcosh = zsinhl * sinq + zcoshl * cosq;
            zsinh = zcoshl * sinq - zsinhl * cosq;
            zn = znLunar;
            cc = C1L;
            ze = zeLunar;
        }
    }

    sse_ += se;
    ssi_ += si;
    ssl_ += sl;
    ssg_ += sgh - (tle_.i0 < kPi / 60.0 ? 0.0 : sh * data_.cosi0 / data_.sini0);
    ssh_ += tle_.i0 < kPi / 60.0 ? 0.0 : sh / data_.sini0;

    // Resonant-synchronous tests and initialisation.
    double bfact = 0.0;

    if (xnq_ >= 1.893053 * kPi / 720.0 && xnq_ <= 2.117652 * kPi / 720.0 && tle_.e0 >= 0.5) {
        resonant_ = true;      // it is resonant...
        synchronous_ = false;  // ...but not synchronous

        const double sini0sq = data_.sini0 * data_.sini0;

        const double g201 = -0.306 - (tle_.e0 - 0.64) * 0.440;
        const double f220 = 0.75 * (1.0 + 2.0 * data_.cosi0 + data_.theta2);
        const double f221 = 1.5 * sini0sq;
        const double f321 = 1.875 * data_.sini0 * (1.0 - 2.0 * data_.cosi0 - 3.0 * data_.theta2);
        const double f322 = -1.875 * data_.sini0 * (1.0 + 2.0 * data_.cosi0 - 3.0 * data_.theta2);
        const double f441 = 35.0 * sini0sq * f220;
        const double f442 = 39.3750 * sini0sq * sini0sq;
        const double f522 =
            9.84375 * data_.sini0 *
            (sini0sq * (1.0 - 2.0 * data_.cosi0 - 5.0 * data_.theta2) +
             kOneThird * (-2.0 + 4.0 * data_.cosi0 + 6.0 * data_.theta2));
        const double f523 =
            data_.sini0 *
            (4.92187512 * sini0sq * (-2.0 - 4.0 * data_.cosi0 + 10.0 * data_.theta2) +
             6.56250012 * (1.0 + 2.0 * data_.cosi0 - 3.0 * data_.theta2));
        const double f542 =
            29.53125 * data_.sini0 *
            (2.0 - 8.0 * data_.cosi0 +
             data_.theta2 * (-12.0 + 8.0 * data_.cosi0 + 10.0 * data_.theta2));
        const double f543 =
            29.53125 * data_.sini0 *
            (-2.0 - 8.0 * data_.cosi0 +
             data_.theta2 * (12.0 + 8.0 * data_.cosi0 - 10.0 * data_.theta2));

        double g211 = 0.0;
        double g310 = 0.0;
        double g322 = 0.0;
        double g410 = 0.0;
        double g422 = 0.0;
        double g520 = 0.0;

        if (tle_.e0 <= 0.65) {
            g211 = cubicPoly(tle_.e0, 3.616, -13.247, +16.290, 0.0);
            g310 = cubicPoly(tle_.e0, -19.302, 117.390, -228.419, 156.591);
            g322 = cubicPoly(tle_.e0, -18.9068, 109.7927, -214.6334, 146.5816);
            g410 = cubicPoly(tle_.e0, -41.122, 242.694, -471.094, 313.953);
            g422 = cubicPoly(tle_.e0, -146.407, 841.880, -1629.014, 1083.435);
            g520 = cubicPoly(tle_.e0, -532.114, 3017.977, -5740.032, 3708.276);
        } else {
            g211 = cubicPoly(tle_.e0, -72.099, 331.819, -508.738, 266.724);
            g310 = cubicPoly(tle_.e0, -346.844, 1582.851, -2415.925, 1246.113);
            g322 = cubicPoly(tle_.e0, -342.585, 1554.908, -2466.899, 1215.972);
            g410 = cubicPoly(tle_.e0, -1052.797, 4758.686, -7193.992, 3651.957);
            g422 = cubicPoly(tle_.e0, -3581.69, 16178.11, -24462.77, 12422.52);

            g520 = tle_.e0 <= 0.715 ? cubicPoly(tle_.e0, 1464.74, -4664.75, 3763.64, 0.0)
                                    : cubicPoly(tle_.e0, -5149.66, 29936.92, -54087.36, 31324.56);
        }

        const double g521 = tle_.e0 < 0.7 ? cubicPoly(tle_.e0, -822.71072, 4568.6173, -8491.4146, 5337.524)
                                          : cubicPoly(tle_.e0, -51752.104, 218913.95, -309468.16, 146349.42);
        const double g532 = tle_.e0 < 0.7 ? cubicPoly(tle_.e0, -853.666, 4690.25, -8624.77, 5341.4)
                                          : cubicPoly(tle_.e0, -40023.88, 170470.89, -242699.48, 115605.82);
        const double g533 = tle_.e0 < 0.7 ? cubicPoly(tle_.e0, -919.2277, 4988.61, -9064.77, 5542.21)
                                          : cubicPoly(tle_.e0, -37995.78, 161616.52, -229838.2, 109377.94);

        constexpr double ROOT22 = 1.7891679e-6;
        constexpr double ROOT32 = 3.7393792e-7;
        constexpr double ROOT44 = 7.3636953e-9;
        constexpr double ROOT52 = 1.1428639e-7;
        constexpr double ROOT54 = 2.1765803e-9;

        double temp1 = 3.0 * xnq_ * xnq_ * aqnv * aqnv;
        double temp = temp1 * ROOT22;
        d2201_ = temp * f220 * g201;
        d2211_ = temp * f221 * g211;
        temp1 *= aqnv;
        temp = temp1 * ROOT32;
        d3210_ = temp * f321 * g310;
        d3222_ = temp * f322 * g322;
        temp1 *= aqnv;
        temp = 2.0 * temp1 * ROOT44;
        d4410_ = temp * f441 * g410;
        d4422_ = temp * f442 * g422;
        temp1 *= aqnv;
        temp = temp1 * ROOT52;
        d5220_ = temp * f522 * g520;
        d5232_ = temp * f523 * g532;
        temp = 2.0 * temp1 * ROOT54;
        d5421_ = temp * f542 * g521;
        d5433_ = temp * f543 * g533;

        xlamo_ = tle_.M0 + tle_.raan0 + tle_.raan0 - gmst_ - gmst_;
        bfact = data_.M_dot + data_.raan_dot + data_.raan_dot - THDT - THDT;
        bfact += ssl_ + ssh_ + ssh_;
    } else if (xnq_ > 0.8 * kPi / 720.0 && xnq_ < 1.2 * kPi / 720.0) {
        resonant_ = true;
        synchronous_ = true;

        constexpr double Q22 = 1.7891679e-6;
        constexpr double Q31 = 2.1460748e-6;
        constexpr double Q33 = 2.2123015e-7;

        const double cosioPlus1 = 1.0 + data_.cosi0;
        const double g200 = 1.0 + data_.e0sq * (-2.5 + 0.8125 * data_.e0sq);
        const double g300 = 1.0 + data_.e0sq * (-6.0 + 6.60937 * data_.e0sq);
        const double f311 =
            0.9375 * data_.sini0 * data_.sini0 * (1.0 + 3.0 * data_.cosi0) -
            0.75 * cosioPlus1;
        const double g310 = 1.0 + 2.0 * data_.e0sq;
        const double f220 = 0.75 * cosioPlus1 * cosioPlus1;
        const double f330 = 2.5 * f220 * cosioPlus1;

        del1_ = 3.0 * xnq_ * xnq_ * aqnv * aqnv;
        del2_ = 2.0 * del1_ * f220 * g200 * Q22;
        del3_ = 3.0 * del1_ * f330 * g300 * Q33 * aqnv;
        del1_ = del1_ * f311 * g310 * Q31 * aqnv;

        xlamo_ = tle_.M0 + tle_.raan0 + tle_.w0 - gmst_;
        bfact = data_.M_dot + data_.w_dot + data_.raan_dot - THDT;
        bfact += ssl_ + ssg_ + ssh_;
    } else {
        resonant_ = false;
        synchronous_ = false;
    }

    if (resonant_) {
        xfact_ = bfact - xnq_;

        // Initialise the integrator.
        xli_ = xlamo_;
        xni_ = xnq_;
        atime_ = 0.0;
    }
}

void DeepSDP4::deepSecularEffects(double mins) {
    xll_ += ssl_ * mins;
    raan_ += ssh_ * mins;
    wNew_ += ssg_ * mins;
    eNew_ = tle_.e0 + sse_ * mins;
    iNew_ = tle_.i0 + ssi_ * mins;

    if (resonant_) {
        if (std::fabs(mins) < std::fabs(mins - atime_) || isDundeeCompliant_) {
            atime_ = 0.0;  // epoch restart
            xni_ = xnq_;
            xli_ = xlamo_;
        }

        bool lastIntegrationStep = false;
        while (!lastIntegrationStep) {
            double delt = mins - atime_;
            if (delt > SECULAR_INTEGRATION_STEP) {
                delt = SECULAR_INTEGRATION_STEP;
            } else if (delt < -SECULAR_INTEGRATION_STEP) {
                delt = -SECULAR_INTEGRATION_STEP;
            } else {
                lastIntegrationStep = true;
            }

            computeSecularDerivs();

            const double xldot = xni_ + xfact_;

            double xlpow = 1.0;
            xli_ += delt * xldot;
            xni_ += delt * derivs0_;
            double deltFactor = delt;

            xlpow *= xldot;
            derivs1_ *= xlpow;
            deltFactor *= delt / 2.0;
            xli_ += deltFactor * derivs0_;
            xni_ += deltFactor * derivs1_;

            atime_ += delt;
        }

        nNew_ = xni_;
        const double temp = -raan_ + gmst_ + mins * THDT;
        xll_ = xli_ + temp + (synchronous_ ? -wNew_ : temp);
    }
}

void DeepSDP4::deepPeriodicEffects(double mins) {
    double pe = 0.0;
    double pinc = 0.0;
    double pl = 0.0;
    double pgh = 0.0;
    double ph = 0.0;

    // Recompute only when the time moved by 30 minutes or more (Dundee always recomputes).
    if (std::fabs(savtsn_ - mins) >= 30.0 || isDundeeCompliant_) {
        savtsn_ = mins;

        // Solar perturbations.
        double zm = zmos_ + znSolar * mins;
        double zf = zm + 2.0 * zeSolar * std::sin(zm);
        double sinzf = std::sin(zf);
        double f2 = 0.5 * sinzf * sinzf - 0.25;
        double f3 = -0.5 * sinzf * std::cos(zf);
        const double seSolar = se2_ * f2 + se3_ * f3;
        const double siSolar = si2_ * f2 + si3_ * f3;
        const double slSolar = sl2_ * f2 + sl3_ * f3 + sl4_ * sinzf;
        const double sgSolar = sgh2_ * f2 + sgh3_ * f3 + sgh4_ * sinzf;
        const double shSolar = sh2_ * f2 + sh3_ * f3;

        // Lunar perturbations.
        zm = zmol_ + znLunar * mins;
        zf = zm + 2.0 * zeLunar * std::sin(zm);
        sinzf = std::sin(zf);
        f2 = 0.5 * sinzf * sinzf - 0.25;
        f3 = -0.5 * sinzf * std::cos(zf);
        const double seLunar = ee2_ * f2 + e3_ * f3;
        const double siLunar = xi2_ * f2 + xi3_ * f3;
        const double slLunar = xl2_ * f2 + xl3_ * f3 + xl4_ * sinzf;
        const double sgLunar = xgh2_ * f2 + xgh3_ * f3 + xgh4_ * sinzf;
        const double shLunar = xh2_ * f2 + xh3_ * f3;

        pe = seSolar + seLunar;
        pinc = siSolar + siLunar;
        pl = slSolar + slLunar;
        pgh = sgSolar + sgLunar;
        ph = shSolar + shLunar;
    }

    eNew_ += pe;
    xll_ += pl;
    wNew_ += pgh;
    iNew_ += pinc;
    iNew_ = fmod2pi_0(iNew_);

    const double sinis = std::sin(iNew_);
    const double cosis = std::cos(iNew_);

    if (std::fabs(iNew_) >= 0.2) {  // apply periodics directly
        const double tempVal = ph / sinis;
        wNew_ -= cosis * tempVal;
        raan_ += tempVal;
    } else {  // apply periodics with Lyddane modification
        const double sinok = std::sin(raan_);
        const double cosok = std::cos(raan_);
        const double alfdp = ph * cosok + (pinc * cosis + sinis) * sinok;
        const double betdp = -ph * sinok + (pinc * cosis + sinis) * cosok;
        const double deltaXnode = fmod2pi_0(std::atan2(alfdp, betdp) - raan_);
        const double dls = -raan_ * sinis * pinc;
        wNew_ += dls - cosis * deltaXnode;
        raan_ += deltaXnode;
    }
}

void DeepSDP4::computeSecularDerivs() {
    const double sinLi = std::sin(xli_);
    const double cosLi = std::cos(xli_);
    const double sin2li = 2.0 * sinLi * cosLi;
    const double cos2li = 2.0 * cosLi * cosLi - 1.0;

    if (synchronous_) {
        constexpr double C_FASX2 = 0.99139134268488593;
        constexpr double S_FASX2 = 0.13093206501640101;
        constexpr double C_2FASX4 = 0.87051638752972937;
        constexpr double S_2FASX4 = -0.49213943048915526;
        constexpr double C_3FASX6 = 0.43258117585763334;
        constexpr double S_3FASX6 = 0.90159499016666422;

        const double sin3li = sin2li * cosLi + cos2li * sinLi;
        const double cos3li = cos2li * cosLi - sin2li * sinLi;

        const double term1a = del1_ * (sinLi * C_FASX2 - cosLi * S_FASX2);
        const double term2a = del2_ * (sin2li * C_2FASX4 - cos2li * S_2FASX4);
        const double term3a = del3_ * (sin3li * C_3FASX6 - cos3li * S_3FASX6);

        const double term1b = del1_ * (cosLi * C_FASX2 + sinLi * S_FASX2);
        const double term2b = 2.0 * del2_ * (cos2li * C_2FASX4 + sin2li * S_2FASX4);
        const double term3b = 3.0 * del3_ * (cos3li * C_3FASX6 + sin3li * S_3FASX6);

        derivs0_ = term1a + term2a + term3a;
        derivs1_ = term1b + term2b + term3b;
    } else {  // 12-hour resonant orbit
        const double xomi = tle_.w0 + data_.w_dot * atime_;
        const double sinOmi = std::sin(xomi);
        const double cosOmi = std::cos(xomi);
        const double sinLiMOmi = sinLi * cosOmi - sinOmi * cosLi;
        const double sinLiPOmi = sinLi * cosOmi + sinOmi * cosLi;
        const double cosLiMOmi = cosLi * cosOmi + sinOmi * sinLi;
        const double cosLiPOmi = cosLi * cosOmi - sinOmi * sinLi;
        const double sin2omi = 2.0 * sinOmi * cosOmi;
        const double cos2omi = 2.0 * cosOmi * cosOmi - 1.0;
        const double sin2liMOmi = sin2li * cosOmi - sinOmi * cos2li;
        const double sin2liPOmi = sin2li * cosOmi + sinOmi * cos2li;
        const double cos2liMOmi = cos2li * cosOmi + sinOmi * sin2li;
        const double cos2liPOmi = cos2li * cosOmi - sinOmi * sin2li;
        const double sin2liP2omi = sin2li * cos2omi + sin2omi * cos2li;
        const double cos2liP2omi = cos2li * cos2omi - sin2omi * sin2li;
        const double sin2omiPLi = sinLi * cos2omi + sin2omi * cosLi;
        const double cos2omiPLi = cosLi * cos2omi - sin2omi * sinLi;

        constexpr double C_G22 = 0.87051638752972937;
        constexpr double S_G22 = -0.49213943048915526;
        constexpr double C_G32 = 0.57972190187001149;
        constexpr double S_G32 = 0.81481440616389245;
        constexpr double C_G44 = -0.22866241528815548;
        constexpr double S_G44 = 0.97350577801807991;
        constexpr double C_G52 = 0.49684831179884198;
        constexpr double S_G52 = 0.86783740128127729;
        constexpr double C_G54 = -0.29695209575316894;
        constexpr double S_G54 = -0.95489237761529999;

        const double term1a =
            d2201_ * (sin2omiPLi * C_G22 - cos2omiPLi * S_G22) +
            d2211_ * (sinLi * C_G22 - cosLi * S_G22) +
            d3210_ * (sinLiPOmi * C_G32 - cosLiPOmi * S_G32) +
            d3222_ * (sinLiMOmi * C_G32 - cosLiMOmi * S_G32) +
            d5220_ * (sinLiPOmi * C_G52 - cosLiPOmi * S_G52) +
            d5232_ * (sinLiMOmi * C_G52 - cosLiMOmi * S_G52);
        const double term2a =
            d4410_ * (sin2liP2omi * C_G44 - cos2liP2omi * S_G44) +
            d4422_ * (sin2li * C_G44 - cos2li * S_G44) +
            d5421_ * (sin2liPOmi * C_G54 - cos2liPOmi * S_G54) +
            d5433_ * (sin2liMOmi * C_G54 - cos2liMOmi * S_G54);
        const double term1b =
            d2201_ * (cos2omiPLi * C_G22 + sin2omiPLi * S_G22) +
            d2211_ * (cosLi * C_G22 + sinLi * S_G22) +
            d3210_ * (cosLiPOmi * C_G32 + sinLiPOmi * S_G32) +
            d3222_ * (cosLiMOmi * C_G32 + sinLiMOmi * S_G32) +
            d5220_ * (cosLiPOmi * C_G52 + sinLiPOmi * S_G52) +
            d5232_ * (cosLiMOmi * C_G52 + sinLiMOmi * S_G52);
        const double term2b =
            2.0 * (d4410_ * (cos2liP2omi * C_G44 + sin2liP2omi * S_G44) +
                   d4422_ * (cos2li * C_G44 + sin2li * S_G44) +
                   d5421_ * (cos2liPOmi * C_G54 + sin2liPOmi * S_G54) +
                   d5433_ * (cos2liMOmi * C_G54 + sin2liMOmi * S_G54));

        derivs0_ = term1a + term2a;
        derivs1_ = term1b + term2b;
    }
}

void DeepSDP4::sxpPropagate(double minsAfterEpoch) {
    wNew_ = tle_.w0 + data_.w_dot * minsAfterEpoch;
    const double xnoddf = tle_.raan0 + data_.raan_dot * minsAfterEpoch;
    const double minsAfterEpochSq = minsAfterEpoch * minsAfterEpoch;
    raan_ = xnoddf + data_.xnodcf * minsAfterEpochSq;
    nNew_ = tle_.n0;

    xll_ = tle_.M0 + data_.M_dot * minsAfterEpoch;

    deepSecularEffects(minsAfterEpoch);

    if (nNew_ < 0.0) throw SGPError("2: mean motion less than zero");

    const double tempa = 1.0 - data_.c1 * minsAfterEpoch;
    a_ = std::pow(EarthConstants::k_e / nNew_, kTwoThirds) * tempa * tempa;
    eNew_ -= tle_.dragCoeff * data_.c4 * minsAfterEpoch;

    xll_ += tle_.n0 * data_.t2cof * minsAfterEpochSq;

    deepPeriodicEffects(minsAfterEpoch);

    xl_ = xll_ + wNew_ + raan_;

    e_ = eNew_;
    i_ = iNew_;
    w_ = wNew_;
    cosi_ = std::cos(iNew_);
    sini_ = std::sin(iNew_);
}

PVCoordinates DeepSDP4::getPVCoordinates(double minsAfterEpoch) {
    sxpPropagate(minsAfterEpoch);

    PropagatorState state;
    state.e = e_;
    state.i = i_;
    state.w = w_;
    state.raan = raan_;
    state.a = a_;
    state.xl = xl_;

    return computePV(state, sini_, cosi_);
}

}  // namespace

PVCoordinates DeepSDP4Propagator::getPVCoordinates(double minsAfterEpoch) const {
    DeepSDP4 propagator(tle_);
    return propagator.getPVCoordinates(minsAfterEpoch);
}

}  // namespace caelus::sky
