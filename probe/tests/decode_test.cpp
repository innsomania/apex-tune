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
    s.undervolt_lock_status = APT_UNDERVOLT_LOCK_UNKNOWN;
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

    apt_session_request session{};
    session.magic = APT_POWER_MAGIC;
    session.version = APT_POWER_VERSION;
    session.size = sizeof(session);
    check(apt_valid_header(session.magic, session.version, session.size, sizeof(session)));
    check(!apt_valid_header(session.magic, 2, session.size, sizeof(session)));
    check(!apt_valid_header(session.magic, session.version, session.size - 1, sizeof(session)));
    check(!apt_valid_header(0, session.version, session.size, sizeof(session)));

    const uint64_t flags = APT_PL1_ENABLE_MASK | APT_PL1_CLAMP_MASK |
        APT_PL2_ENABLE_MASK | APT_PL2_CLAMP_MASK | (1ULL << 17) | (1ULL << 49);
    const uint64_t baseline = limit(100 * 8, 125 * 8, flags);
    uint64_t target = 0;
    uint32_t pl2_watts = 0;
    const uint32_t profiles[] = {10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60, 65, 70, 75, 80};
    for (uint32_t pl1 : profiles) {
        check(apt_is_profile_pl1(pl1));
        for (uint32_t tier = 1; tier <= APT_TURBO_TIER_COUNT; ++tier) {
            check(apt_profile_pl2(pl1, tier, 125, &pl2_watts));
            const uint32_t requested = pl1 + (tier - 1) * 5;
            check(pl2_watts == (requested < 80 ? requested : 80));
            check(apt_build_profile_limit(3, baseline, baseline, pl1, tier, &target, &pl2_watts));
            check((target & APT_PL1_POWER_MASK) == pl1 * 8);
            check(((target & APT_PL2_POWER_MASK) >> 32) == pl2_watts * 8);
            check(pl2_watts <= 80 && pl2_watts >= pl1);
            check((target & ~APT_PROFILE_POWER_MASK) == (baseline & ~APT_PROFILE_POWER_MASK));
        }
    }
    check(!apt_is_profile_pl1(9) && !apt_is_profile_pl1(12) && !apt_is_profile_pl1(85));
    check(!apt_profile_pl2(10, 0, 80, &pl2_watts));
    check(!apt_profile_pl2(10, 6, 80, &pl2_watts));
    check(!apt_profile_pl2(10, 1, 80, nullptr));
    check(!apt_profile_pl2(80, 5, 79, &pl2_watts));
    check(!apt_build_profile_limit(3, baseline, baseline, 12, 1, &target, &pl2_watts));
    check(!apt_build_profile_limit(3, baseline, baseline, 25, 6, &target, &pl2_watts));
    check(!apt_build_profile_limit(3, baseline | APT_POWER_LOCK_MASK, baseline, 10, 1, &target, &pl2_watts));
    check(!apt_build_profile_limit(3, baseline, baseline | APT_POWER_LOCK_MASK, 10, 1, &target, &pl2_watts));
    check(!apt_build_profile_limit(3, baseline, baseline & ~APT_PL1_ENABLE_MASK, 10, 1, &target, &pl2_watts));
    check(!apt_build_profile_limit(3, baseline, baseline & ~APT_PL2_ENABLE_MASK, 10, 1, &target, &pl2_watts));
    const uint64_t lower_original_pl2 = limit(100 * 8, 62 * 8, flags);
    check(apt_build_profile_limit(3, lower_original_pl2, lower_original_pl2, 55, 5, &target, &pl2_watts));
    check(pl2_watts == 62 && ((target & APT_PL2_POWER_MASK) >> 32) == 62 * 8);
    check(!apt_build_profile_limit(3, lower_original_pl2, lower_original_pl2, 65, 1, &target, &pl2_watts));
    const uint64_t lower_original_pl1 = limit(55 * 8, 80 * 8, flags);
    check(!apt_build_profile_limit(3, lower_original_pl1, lower_original_pl1, 60, 1, &target, &pl2_watts));
    check(!apt_build_profile_limit(15, limit(0x7fff, 0x7fff, flags), limit(0x7fff, 0x7fff, flags),
                                   80, 5, &target, &pl2_watts));
    check(!apt_build_profile_limit(3, baseline, baseline, 10, 1, nullptr, &pl2_watts));
    check(!apt_build_profile_limit(3, baseline, baseline, 10, 1, &target, nullptr));

    const uint64_t reduced_current = limit(25 * 8, 25 * 8, flags | (1ULL << 55));
    check(apt_build_profile_limit(3, baseline, reduced_current, 75, 5, &target, &pl2_watts));
    check(pl2_watts == 80);
    check((target & APT_PL1_POWER_MASK) == 75 * 8);
    check(((target & APT_PL2_POWER_MASK) >> 32) == 80 * 8);
    check((target & ~APT_PROFILE_POWER_MASK) == (reduced_current & ~APT_PROFILE_POWER_MASK));

    const uint64_t changed_power = limit(35 * 8, 50 * 8,
        APT_PL1_ENABLE_MASK | APT_PL2_ENABLE_MASK | APT_PL2_CLAMP_MASK |
        (1ULL << 20) | (1ULL << 55));
    uint64_t restore = 0;
    check(apt_build_restore_limit(changed_power, baseline, &restore));
    check((restore & APT_PROFILE_POWER_MASK) == (baseline & APT_PROFILE_POWER_MASK));
    check((restore & ~APT_PROFILE_POWER_MASK) == (changed_power & ~APT_PROFILE_POWER_MASK));
    check(apt_power_fields_equal(restore, baseline));
    check(!apt_power_fields_equal(restore, changed_power));
    check(!apt_build_restore_limit(changed_power | APT_POWER_LOCK_MASK, baseline, &restore));
    check(!apt_build_restore_limit(changed_power, baseline, nullptr));
    return 0;
}
