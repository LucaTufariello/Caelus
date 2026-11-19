#include "Propagator.hpp"

#include "Astro.hpp"

#include <cmath>

namespace caelus::sky {

PropagatorData createPropagatorData(const Elements& tle) {
    PropagatorData d;
    d.tle = tle;

    const double perigee = (tle.a0 * (1.0 - tle.e0) - 1.0) * EarthConstants::R_e;
    d.perigee = perigee;

    double s;
    if (perigee < 98.0) {
        s = 20.0;
    } else if (perigee <= 156.0) {
        s = perigee - 78.0;
    } else {
        s = 78.0;
    }
    const double q0_s = (120.0 - s) / EarthConstants::R_e;
    const double sFinal = s / EarthConstants::R_e + 1.0;

    const double sini0 = std::sin(tle.i0);
    const double cosi0 = std::cos(tle.i0);
    const double theta2 = cosi0 * cosi0;

    const double e0sq = tle.e0 * tle.e0;
    const double beta0sq = 1.0 - e0sq;
    const double beta0 = std::sqrt(beta0sq);

    const double xi = 1.0 / (tle.a0 - sFinal);
    const double eta = tle.a0 * tle.e0 * xi;
    const double etasq = eta * eta;
    const double eeta = tle.e0 * eta;

    const double coef = q0_s * q0_s * q0_s * q0_s * xi * xi * xi * xi;
    const double psi2 = std::fabs(1.0 - etasq);
    const double coef1 = coef / std::pow(psi2, 3.5);

    const double x3thm1 = 3.0 * theta2 - 1.0;
    const double c2 =
        coef1 * tle.n0 *
        (tle.a0 * (1.0 + 1.5 * etasq + eeta * (4.0 + etasq)) +
         0.75 * EarthConstants::K2 * xi / psi2 * x3thm1 * (8.0 + 3.0 * etasq * (8.0 + etasq)));
    const double c1 = tle.dragCoeff * c2;

    const double x1mth2 = 1.0 - theta2;

    const double c4 =
        2.0 * tle.n0 * coef1 * tle.a0 * beta0sq *
        (eta * (2.0 + 0.5 * etasq) + tle.e0 * (0.5 + 2.0 * etasq) -
         2.0 * EarthConstants::K2 * xi / (tle.a0 * psi2) *
             (-3.0 * x3thm1 * (1.0 - 2.0 * eeta + etasq * (1.5 - 0.5 * eeta)) +
              0.75 * x1mth2 * (2.0 * etasq - eeta * (1.0 + etasq)) * std::cos(2.0 * tle.w0)));

    const double pinv = 1.0 / (tle.a0 * beta0sq);
    const double pinvsq = pinv * pinv;

    const double temp1 = 3.0 * EarthConstants::K2 * pinvsq * tle.n0;
    const double temp2 = temp1 * EarthConstants::K2 * pinvsq;
    const double temp3 = 1.25 * EarthConstants::K4 * pinvsq * pinvsq * tle.n0;

    const double theta4 = theta2 * theta2;
    const double M_dot = tle.n0 + 0.5 * temp1 * beta0 * x3thm1 +
                         0.0625 * temp2 * beta0 * (13.0 - 78.0 * theta2 + 137.0 * theta4);

    const double x1m5theta2 = 1.0 - 5.0 * theta2;

    const double w_dot = -0.5 * temp1 * x1m5theta2 +
                         0.0625 * temp2 * (7.0 - 114.0 * theta2 + 395.0 * theta4) +
                         temp3 * (3.0 - 36.0 * theta2 + 49.0 * theta4);

    const double xhdot1 = -temp1 * cosi0;

    const double raan_dot =
        xhdot1 + (0.5 * temp2 * (4.0 - 19.0 * theta2) + 2.0 * temp3 * (3.0 - 7.0 * theta2)) * cosi0;
    const double xnodcf = 3.5 * beta0sq * xhdot1 * c1;
    const double t2cof = 1.5 * c1;

    d.M_dot = M_dot;
    d.w_dot = w_dot;
    d.raan_dot = raan_dot;
    d.xnodcf = xnodcf;
    d.e0sq = e0sq;
    d.beta0sq = beta0sq;
    d.beta0 = beta0;
    d.xi = xi;
    d.eta = eta;
    d.etasq = etasq;
    d.eeta = eeta;
    d.coef = coef;
    d.coef1 = coef1;
    d.c1 = c1;
    d.c2 = c2;
    d.c4 = c4;
    d.t2cof = t2cof;
    d.sini0 = sini0;
    d.cosi0 = cosi0;
    d.theta2 = theta2;
    d.s = sFinal;
    return d;
}

PVCoordinates computePV(const PropagatorState& state, double sini0, double cosi0) {
    // Long period periodics.
    const double axn = state.e * std::cos(state.w);
    double temp = 1.0 / (state.a * (1.0 - state.e * state.e));
    const double xlcof =
        0.125 * EarthConstants::J3OVK2 * sini0 * (3.0 + 5.0 * cosi0) / (1.0 + cosi0);
    const double aycof = 0.250 * EarthConstants::J3OVK2 * sini0;
    const double aynl = temp * aycof;
    const double xlt = state.xl + temp * xlcof * axn;
    const double ayn = state.e * std::sin(state.w) + aynl;
    const double elsq = axn * axn + ayn * ayn;

    if (elsq > 1.0) throw SGPError("4: semi-latus rectum < 0.0");

    const double capu = fmod2pi_pi(xlt - state.raan);

    // Items dependent on cosio get recomputed after the deep-space periodic corrections.
    const double costheta2 = cosi0 * cosi0;
    const double x3thm1 = 3.0 * costheta2 - 1.0;
    const double x1mth2 = 1.0 - costheta2;
    const double x7thm1 = 7.0 * costheta2 - 1.0;

    if (state.e > (1.0 - 1e-6)) throw SGPError("1: eccentricity too close to 1.0");

    // Solve Kepler's equation.
    double epw = capu;
    double sinEPW = 0.0;
    double cosEPW = 0.0;
    double ecosE = 0.0;
    double esinE = 0.0;

    constexpr double newtonRaphsonEpsilon = 1e-12;
    for (int j = 0; j <= 10; ++j) {
        bool doSecondOrderNewtonRaphson = true;

        sinEPW = std::sin(epw);
        cosEPW = std::cos(epw);
        ecosE = axn * cosEPW + ayn * sinEPW;
        esinE = axn * sinEPW - ayn * cosEPW;
        const double f = capu - epw + esinE;
        if (std::fabs(f) < newtonRaphsonEpsilon) break;

        const double fdot = 1.0 - ecosE;
        double deltaEpw = f / fdot;
        if (j == 0) {
            const double maxNewtonRaphson = 1.25 * std::fabs(state.e);
            doSecondOrderNewtonRaphson = false;
            if (deltaEpw > maxNewtonRaphson) {
                deltaEpw = maxNewtonRaphson;
            } else if (deltaEpw < -maxNewtonRaphson) {
                deltaEpw = -maxNewtonRaphson;
            } else {
                doSecondOrderNewtonRaphson = true;
            }
        }
        if (doSecondOrderNewtonRaphson) deltaEpw = f / (fdot + 0.5 * esinE * deltaEpw);
        epw += deltaEpw;
    }

    // Short period preliminary quantities.
    temp = 1.0 - elsq;
    const double pl = state.a * temp;
    const double r = state.a * (1.0 - ecosE);
    double temp2 = state.a / r;
    const double betal = std::sqrt(temp);
    temp = esinE / (1.0 + betal);
    const double cosu = temp2 * (cosEPW - axn + ayn * temp);
    const double sinu = temp2 * (sinEPW - ayn - axn * temp);
    const double u = std::atan2(sinu, cosu);
    const double sin2u = 2.0 * sinu * cosu;
    const double cos2u = 2.0 * cosu * cosu - 1.0;
    const double temp1 = EarthConstants::K2 / pl;
    temp2 = temp1 / pl;

    // Update for short periodics.
    const double rk = r * (1.0 - 1.5 * temp2 * betal * x3thm1) + 0.5 * temp1 * x1mth2 * cos2u;

    if (rk < 1.0) throw SGPError("6: decay condition .. radius < R_e");

    const double uk = u - 0.25 * temp2 * x7thm1 * sin2u;
    const double xnodek = state.raan + 1.5 * temp2 * cosi0 * sin2u;
    const double xinck = state.i + 1.5 * temp2 * cosi0 * sini0 * cos2u;

    // Orientation vectors.
    const double sinuk = std::sin(uk);
    const double cosuk = std::cos(uk);
    const double sinik = std::sin(xinck);
    const double cosik = std::cos(xinck);
    const double sinnok = std::sin(xnodek);
    const double cosnok = std::cos(xnodek);
    const double xmx = -sinnok * cosik;
    const double xmy = cosnok * cosik;
    const double ux = xmx * sinuk + cosnok * cosuk;
    const double uy = xmy * sinuk + sinnok * cosuk;
    const double uz = sinik * sinuk;

    // Position and velocity.
    const double cr = 1000.0 * rk * EarthConstants::R_e;
    const Vec3 pos(cr * ux, cr * uy, cr * uz);

    const double rdot = EarthConstants::k_e * std::sqrt(state.a) * esinE / r;
    const double rfdot = EarthConstants::k_e * std::sqrt(pl) / r;
    const double xn = EarthConstants::k_e / (state.a * std::sqrt(state.a));
    const double rdotk = rdot - xn * temp1 * x1mth2 * sin2u;
    const double rfdotk = rfdot + xn * temp1 * (x1mth2 * cos2u + 1.5 * x3thm1);
    const double vx = xmx * cosuk - cosnok * sinuk;
    const double vy = xmy * cosuk - sinnok * sinuk;
    const double vz = sinik * cosuk;

    const double cv = 1000.0 * EarthConstants::R_e / 60.0;
    const Vec3 vel(cv * (rdotk * ux + rfdotk * vx), cv * (rdotk * uy + rfdotk * vy),
                   cv * (rdotk * uz + rfdotk * vz));

    if (std::isnan(cv * (rdotk * ux + rfdotk * vx))) throw SGPError("nan");

    return {pos, vel};
}

// ── SGP4 ───────────────────────────────────────────────────────────────────────────────────

SGP4Propagator::SGP4Propagator(const Elements& tle) : data_(createPropagatorData(tle)) {
    if (data_.perigee > 220.0) {
        const double dM0 = 1.0 + data_.eta * std::cos(data_.tle.M0);
        dM0Cubed_ = dM0 * dM0 * dM0;

        const double c1sq = data_.c1 * data_.c1;
        d2_ = 4.0 * data_.tle.a0 * data_.xi * c1sq;
        const double temp = d2_ * data_.xi * data_.c1 / 3.0;
        d3_ = (17.0 * data_.tle.a0 + data_.s) * temp;
        d4_ = 0.5 * temp * data_.tle.a0 * data_.xi * (221.0 * data_.tle.a0 + 31.0 * data_.s) *
              data_.c1;
        t3cof_ = d2_ + 2.0 * c1sq;
        t4cof_ = 0.25 * (3.0 * d3_ + data_.c1 * (12.0 * d2_ + 10.0 * c1sq));
        t5cof_ = 0.2 * (3.0 * d4_ + 12.0 * data_.c1 * d3_ + 6.0 * d2_ * d2_ +
                        15.0 * c1sq * (2.0 * d2_ + c1sq));

        if (data_.tle.e0 > 1e-4) {
            const double c3 =
                data_.coef * data_.xi * EarthConstants::J3OVK2 * data_.tle.n0 * data_.sini0 /
                data_.tle.e0;
            xmcof_ = -kTwoThirds * data_.coef * data_.tle.dragCoeff / data_.eeta;
            omgcof_ = data_.tle.dragCoeff * c3 * std::cos(data_.tle.w0);
        }
    }

    c5_ = 2.0 * data_.coef1 * data_.tle.a0 * data_.beta0sq *
          (1.0 + 2.75 * (data_.etasq + data_.eeta) + data_.eeta * data_.etasq);
}

void SGP4Propagator::sxpPropagate(double minsAfterEpoch, PropagatorState& state) const {
    state.w = data_.tle.w0 + data_.w_dot * minsAfterEpoch;
    const double xnoddf = data_.tle.raan0 + data_.raan_dot * minsAfterEpoch;
    const double anomdf = data_.tle.M0 + data_.M_dot * minsAfterEpoch;
    double xmp = anomdf;
    const double minsAfterEpochSq = minsAfterEpoch * minsAfterEpoch;
    state.raan = xnoddf + data_.xnodcf * minsAfterEpochSq;
    double tempa = 1.0 - data_.c1 * minsAfterEpoch;
    double tempe = data_.tle.dragCoeff * data_.c4 * minsAfterEpoch;
    double templ = data_.t2cof * minsAfterEpochSq;

    if (data_.perigee > 220.0) {
        const double deltaOm = omgcof_ * minsAfterEpoch;
        double deltaM = 1.0 + data_.eta * std::cos(anomdf);
        deltaM = xmcof_ * (deltaM * deltaM * deltaM - dM0Cubed_);
        const double temp = deltaOm + deltaM;
        xmp = anomdf + temp;
        state.w -= temp;
        const double minsAfterEpochCubed = minsAfterEpochSq * minsAfterEpoch;
        const double minsAfterEpochQuartic = minsAfterEpochCubed * minsAfterEpoch;
        tempa = tempa - d2_ * minsAfterEpochSq - d3_ * minsAfterEpochCubed -
                d4_ * minsAfterEpochQuartic;
        tempe = tempe +
                data_.tle.dragCoeff * c5_ * (std::sin(xmp) - std::sin(data_.tle.M0));
        templ = templ + t3cof_ * minsAfterEpochCubed +
                minsAfterEpochQuartic * (t4cof_ + minsAfterEpoch * t5cof_);
    }

    state.a = data_.tle.a0 * tempa * tempa;
    state.e = data_.tle.e0 - tempe;

    if (state.e >= 1.0 || state.e < -0.001) throw SGPError("1: eccentricity out of range 0...1");
    if (state.e < 1e-6) state.e = 1e-6;

    state.xl = xmp + state.w + state.raan + data_.tle.n0 * templ;
    state.i = data_.tle.i0;
}

PVCoordinates SGP4Propagator::getPVCoordinates(double minsAfterEpoch) const {
    PropagatorState state;
    sxpPropagate(minsAfterEpoch, state);
    return computePV(state, data_.sini0, data_.cosi0);
}

bool isDeepSpace(const Elements& tle) {
    if (tle.ephemType == 2) return false;
    if (tle.ephemType == 3) return true;
    return (2.0 * kPi) / (tle.n0 * kDay2Minutes) >= (1.0 / 6.4);
}

}  // namespace caelus::sky
