#include "../power_snapshot.h"
#include <cassert>
#include <cmath>
#include <cstdint>

static void check(bool value) { assert(value); }

static uint64_t limit(uint64_t pl1, uint64_t pl2, uint64_t flags = 0) {
    return flags | (pl1 & APT_PL1_POWER_MASK) | ((pl2 & 0x7fffULL) << 32);
}

int main() {
    apt_power_snapshot s{};
    apt_decoded_power d{};
    check(!apt_decode_power(nullptr, &d));
    check(!apt_decode_power(&s, nullptr));
    s.magic = APT_POWER_MAGIC; s.version = APT_POWER_VERSION; s.size = sizeof(s);
    s.power_unit_msr = 3;
    s.package_power_limit_msr = limit(80, 200, APT_PL1_ENABLE_MASK | APT_PL1_CLAMP_MASK |
        APT_PL2_ENABLE_MASK | APT_PL2_CLAMP_MASK | APT_POWER_LOCK_MASK);
    check(apt_decode_power(&s, &d));
    check(std::fabs(d.watts_per_unit - 0.125) < 1e-9);
    check(std::fabs(d.pl1_watts - 10.0) < 1e-9 && d.pl1_enabled && d.pl1_clamp);
    check(std::fabs(d.pl2_watts - 25.0) < 1e-9 && d.pl2_enabled && d.pl2_clamp && d.locked);
    s.power_unit_msr = 15;
    s.package_power_limit_msr = limit(0x7fff, 0x7fff);
    check(apt_decode_power(&s, &d));
    check(std::fabs(d.watts_per_unit - 1.0 / 32768.0) < 1e-12);
    check(std::fabs(d.pl1_watts - 0.999969482421875) < 1e-12);
    check(std::fabs(d.pl2_watts - 0.999969482421875) < 1e-12);
    check(!d.pl1_enabled && !d.pl1_clamp && !d.pl2_enabled && !d.pl2_clamp && !d.locked);
    s.power_unit_msr = 0;
    s.package_power_limit_msr = limit(0, 0x7fff);
    check(apt_decode_power(&s, &d) && d.pl2_watts == 32767.0);
    s.magic ^= 1; check(!apt_decode_power(&s, &d)); s.magic ^= 1;
    s.version++; check(!apt_decode_power(&s, &d)); s.version--;
    s.size--; check(!apt_decode_power(&s, &d));

    const uint64_t flags = APT_PL1_ENABLE_MASK | APT_PL1_CLAMP_MASK |
        APT_PL2_ENABLE_MASK | APT_PL2_CLAMP_MASK | (1ULL << 17) | (1ULL << 49);
    const uint64_t baseline = limit(100 * 8, 125 * 8, flags);
    uint64_t target = 0;
    check(apt_build_trial_limit(3, baseline, 30, 45, 10, &target));
    check((target & APT_TRIAL_POWER_MASK) == limit(30 * 8, 45 * 8));
    check((target & ~APT_TRIAL_POWER_MASK) == (baseline & ~APT_TRIAL_POWER_MASK));
    check(!apt_build_trial_limit(3, baseline, 46, 46, 1, &target));
    check(!apt_build_trial_limit(3, baseline, 40, 39, 1, &target));
    check(!apt_build_trial_limit(3, baseline, 9, 40, 1, &target));
    check(!apt_build_trial_limit(3, baseline, 20, 46, 1, &target));
    check(!apt_build_trial_limit(3, baseline, 20, 30, 0, &target));
    check(!apt_build_trial_limit(3, baseline, 20, 30, 11, &target));
    check(!apt_build_trial_limit(3, baseline, 110, 120, 1, &target)); // cannot raise PL1 above baseline
    check(!apt_build_trial_limit(3, baseline, 90, 126, 1, &target)); // cannot raise PL2 above baseline
    check(!apt_build_trial_limit(3, baseline | APT_POWER_LOCK_MASK, 20, 30, 1, &target));
    check(!apt_build_trial_limit(3, baseline & ~APT_PL1_ENABLE_MASK, 20, 30, 1, &target));
    check(!apt_build_trial_limit(3, baseline & ~APT_PL2_ENABLE_MASK, 20, 30, 1, &target));
    check(!apt_build_trial_limit(15, limit(0x7fff, 0x7fff, flags), 10, 20, 1, &target));
    check(!apt_build_trial_limit(3, baseline, 20, 30, 1, nullptr));

    const uint64_t changed_power = limit(35 * 8, 50 * 8,
        APT_PL1_ENABLE_MASK | APT_PL2_ENABLE_MASK | APT_PL2_CLAMP_MASK |
        (1ULL << 20) | (1ULL << 55));
    uint64_t restore = 0;
    check(apt_build_restore_limit(changed_power, baseline, &restore));
    check((restore & APT_TRIAL_POWER_MASK) == (baseline & APT_TRIAL_POWER_MASK));
    check((restore & ~APT_TRIAL_POWER_MASK) == (changed_power & ~APT_TRIAL_POWER_MASK));
    check(apt_power_fields_equal(restore, baseline));
    check(!apt_power_fields_equal(restore, changed_power));
    check(!apt_build_restore_limit(changed_power | APT_POWER_LOCK_MASK, baseline, &restore));
    check(!apt_build_restore_limit(changed_power, baseline, nullptr));
    return 0;
}
