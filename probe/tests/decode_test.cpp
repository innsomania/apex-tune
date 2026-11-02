#include "../power_snapshot.h"
#include <cassert>
#include <cmath>
#include <cstdint>

static void check(bool value) { assert(value); }
int main() {
    apt_power_snapshot s{};
    apt_decoded_power d{};
    check(!apt_decode_power(nullptr, &d));
    check(!apt_decode_power(&s, nullptr));
    s.magic = APT_POWER_MAGIC; s.version = APT_POWER_VERSION; s.size = sizeof(s);
    s.power_unit_msr = 0x3; // 1/8 W
    s.package_power_limit_msr = 80ULL | (1ULL << 15) | (1ULL << 16) |
        (200ULL << 32) | (1ULL << 47) | (1ULL << 48) | (1ULL << 63);
    check(apt_decode_power(&s, &d));
    check(std::fabs(d.watts_per_unit - 0.125) < 1e-9);
    check(std::fabs(d.pl1_watts - 10.0) < 1e-9 && d.pl1_enabled && d.pl1_clamp);
    check(std::fabs(d.pl2_watts - 25.0) < 1e-9 && d.pl2_enabled && d.pl2_clamp && d.locked);
    s.power_unit_msr = 15; // highest unit exponent: 1/32768 W
    s.package_power_limit_msr = 0x7fffULL | (0x7fffULL << 32);
    check(apt_decode_power(&s, &d));
    check(std::fabs(d.watts_per_unit - 1.0 / 32768.0) < 1e-12);
    check(std::fabs(d.pl1_watts - 0.999969482421875) < 1e-12);
    check(std::fabs(d.pl2_watts - 0.999969482421875) < 1e-12);
    check(!d.pl1_enabled && !d.pl1_clamp && !d.pl2_enabled && !d.pl2_clamp && !d.locked);
    s.power_unit_msr = 0;
    s.package_power_limit_msr = 0ULL | ((uint64_t)0x7fff << 32);
    check(apt_decode_power(&s, &d));
    check(d.pl2_watts == 32767.0); // PL2 must use a wide unsigned shift
    s.magic ^= 1; check(!apt_decode_power(&s, &d)); s.magic ^= 1;
    s.version++; check(!apt_decode_power(&s, &d)); s.version--;
    s.size--; check(!apt_decode_power(&s, &d));
    return 0;
}
