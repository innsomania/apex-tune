#ifndef APEXTUNE_POWER_SNAPSHOT_H
#define APEXTUNE_POWER_SNAPSHOT_H

#include <stdint.h>

#define APT_POWER_MAGIC 0x41505431u
#define APT_POWER_VERSION 4u
#define APT_SELECTOR_SNAPSHOT 0u
#define APT_SELECTOR_BEGIN_SESSION 1u
#define APT_SELECTOR_SET_PROFILE 2u
#define APT_SELECTOR_HEARTBEAT 3u
#define APT_SELECTOR_FINISH_SESSION 4u
#define APT_MSR_POWER_UNIT 0x606u
#define APT_MSR_PACKAGE_POWER_LIMIT 0x610u
#define APT_WATCHDOG_MAX_SECONDS 30u
#define APT_HEARTBEAT_SECONDS 10u
#define APT_PROFILE_LEVEL_COUNT 141u
#define APT_TURBO_TIER_COUNT 5u
#define APT_PROFILE_MIN_HALF_WATTS 20u
#define APT_PROFILE_MAX_HALF_WATTS 160u
#define APT_PROFILE_STEP_HALF_WATTS 1u
#define APT_TURBO_TIER_HEADROOM_HALF_WATTS 10u
#define APT_UNDERVOLT_LOCK_UNKNOWN 0u
#define APT_PL1_POWER_MASK 0x0000000000007fffULL
#define APT_PL1_ENABLE_MASK 0x0000000000008000ULL
#define APT_PL1_CLAMP_MASK 0x0000000000010000ULL
#define APT_PL2_POWER_MASK 0x00007fff00000000ULL
#define APT_PL2_ENABLE_MASK 0x0000800000000000ULL
#define APT_PL2_CLAMP_MASK 0x0001000000000000ULL
#define APT_POWER_LOCK_MASK 0x8000000000000000ULL
#define APT_PROFILE_POWER_MASK (APT_PL1_POWER_MASK | APT_PL2_POWER_MASK)

typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint16_t version;
    uint16_t size;
    uint64_t power_unit_msr;
    uint64_t package_power_limit_msr;
    uint32_t undervolt_lock_status;
    uint32_t reserved;
} apt_power_snapshot;

typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint16_t version;
    uint16_t size;
} apt_session_request;

typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint16_t version;
    uint16_t size;
    uint32_t pl1_half_watts;
    uint32_t pl2_half_watts;
    uint32_t turbo_tier;
} apt_profile_request;

typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint16_t version;
    uint16_t size;
    uint32_t active;
    uint32_t pl1_half_watts;
    uint32_t pl2_half_watts;
    uint32_t turbo_tier;
    uint64_t original_raw;
    uint64_t current_raw;
} apt_session_result;

typedef struct {
    double watts_per_unit;
    double pl1_watts;
    double pl2_watts;
    unsigned pl1_enabled;
    unsigned pl1_clamp;
    unsigned pl2_enabled;
    unsigned pl2_clamp;
    unsigned locked;
} apt_decoded_power;

static inline int apt_valid_header(uint32_t magic, uint16_t version, uint16_t size,
                                   uint16_t expected_size) {
    return magic == APT_POWER_MAGIC && version == APT_POWER_VERSION && size == expected_size;
}

static inline int apt_is_profile_pl1(uint32_t half_watts) {
    return half_watts >= APT_PROFILE_MIN_HALF_WATTS &&
           half_watts <= APT_PROFILE_MAX_HALF_WATTS &&
           (half_watts - APT_PROFILE_MIN_HALF_WATTS) % APT_PROFILE_STEP_HALF_WATTS == 0;
}

static inline int apt_parse_half_watts(const char *text, uint32_t *half_watts) {
    if (!text || !*text || !half_watts) return 0;
    uint64_t whole = 0;
    const char *cursor = text;
    if (*cursor < '0' || *cursor > '9') return 0;
    while (*cursor >= '0' && *cursor <= '9') {
        whole = whole * 10u + (unsigned)(*cursor - '0');
        if (whole > UINT32_MAX / 2u) return 0;
        ++cursor;
    }
    uint32_t fraction = 0;
    if (*cursor == '.') {
        ++cursor;
        if (*cursor == '5') {
            fraction = 1;
            ++cursor;
            if (*cursor == '0') ++cursor;
        }
        else if (*cursor == '0') {
            ++cursor;
            if (*cursor == '0') ++cursor;
        } else return 0;
    }
    if (*cursor != '\0') return 0;
    *half_watts = (uint32_t)(whole * 2u + fraction);
    return 1;
}

static inline int apt_profile_pl2(uint32_t pl1_half_watts, uint32_t turbo_tier,
                                  uint32_t baseline_pl2_half_watts,
                                  uint32_t *pl2_half_watts) {
    if (!pl2_half_watts || !apt_is_profile_pl1(pl1_half_watts) ||
        turbo_tier == 0 || turbo_tier > APT_TURBO_TIER_COUNT) return 0;
    if (baseline_pl2_half_watts > APT_PROFILE_MAX_HALF_WATTS)
        baseline_pl2_half_watts = APT_PROFILE_MAX_HALF_WATTS;
    if (baseline_pl2_half_watts < pl1_half_watts) return 0;
    const uint32_t requested = pl1_half_watts +
        (turbo_tier - 1u) * APT_TURBO_TIER_HEADROOM_HALF_WATTS;
    *pl2_half_watts = requested < baseline_pl2_half_watts ? requested : baseline_pl2_half_watts;
    return 1;
}

static inline int apt_decode_power(const apt_power_snapshot *snapshot,
                                   apt_decoded_power *result) {
    if (!snapshot || !result || snapshot->magic != APT_POWER_MAGIC ||
        snapshot->version != APT_POWER_VERSION ||
        snapshot->size != sizeof(*snapshot)) return 0;

    const unsigned exponent = (unsigned)(snapshot->power_unit_msr & 0x0f);
    const uint64_t limit = snapshot->package_power_limit_msr;
    result->watts_per_unit = 1.0 / (double)(1u << exponent);
    result->pl1_watts = (double)(limit & APT_PL1_POWER_MASK) * result->watts_per_unit;
    result->pl1_enabled = (unsigned)((limit & APT_PL1_ENABLE_MASK) != 0);
    result->pl1_clamp = (unsigned)((limit & APT_PL1_CLAMP_MASK) != 0);
    result->pl2_watts = (double)((limit & APT_PL2_POWER_MASK) >> 32) * result->watts_per_unit;
    result->pl2_enabled = (unsigned)((limit & APT_PL2_ENABLE_MASK) != 0);
    result->pl2_clamp = (unsigned)((limit & APT_PL2_CLAMP_MASK) != 0);
    result->locked = (unsigned)((limit & APT_POWER_LOCK_MASK) != 0);
    return 1;
}

// Produces a PL1/PL2-only RAPL update. Other register bits are preserved exactly.
static inline int apt_build_profile_limit(uint64_t unit_msr, uint64_t original_raw,
                                          uint64_t current_raw, uint32_t pl1_half_watts,
                                          uint32_t pl2_half_watts, uint32_t turbo_tier,
                                          uint64_t *updated_raw) {
    if (!updated_raw || !apt_is_profile_pl1(pl1_half_watts) ||
        pl2_half_watts < pl1_half_watts || pl2_half_watts > APT_PROFILE_MAX_HALF_WATTS) return 0;
    if ((original_raw & APT_POWER_LOCK_MASK) != 0 || (current_raw & APT_POWER_LOCK_MASK) != 0 ||
        (current_raw & APT_PL1_ENABLE_MASK) == 0 ||
        (current_raw & APT_PL2_ENABLE_MASK) == 0) return 0;
    const unsigned exponent = (unsigned)(unit_msr & 0x0f);
    if (exponent == 0) return 0; // Half-watt target is not exactly representable.
    const uint64_t half_watt_units = 1ULL << (exponent - 1);
    const uint64_t pl1_units = (uint64_t)pl1_half_watts * half_watt_units;
    const uint64_t original_pl1 = original_raw & APT_PL1_POWER_MASK;
    const uint64_t original_pl2 = (original_raw & APT_PL2_POWER_MASK) >> 32;
    const uint32_t baseline_pl2_half_watts = (uint32_t)(original_pl2 / half_watt_units);
    uint32_t max_pl2_half_watts = 0;
    if (!apt_profile_pl2(pl1_half_watts, turbo_tier, baseline_pl2_half_watts,
                         &max_pl2_half_watts) || pl2_half_watts > max_pl2_half_watts) return 0;
    const uint64_t pl2_units = (uint64_t)pl2_half_watts * half_watt_units;
    if (pl1_units > (uint64_t)APT_PROFILE_MAX_HALF_WATTS * half_watt_units ||
        pl2_units > (uint64_t)APT_PROFILE_MAX_HALF_WATTS * half_watt_units ||
        pl1_units > APT_PL1_POWER_MASK || pl2_units > 0x7fffULL ||
        pl1_units > original_pl1 || pl2_units > original_pl2) return 0;
    *updated_raw = (current_raw & ~APT_PROFILE_POWER_MASK) |
                   pl1_units | (pl2_units << 32);
    return 1;
}

// Restore only the saved PL1/PL2 power fields, preserving current control bits.
static inline int apt_build_restore_limit(uint64_t current_raw, uint64_t original_raw,
                                          uint64_t *updated_raw) {
    if (!updated_raw || (current_raw & APT_POWER_LOCK_MASK) != 0) return 0;
    *updated_raw = (current_raw & ~APT_PROFILE_POWER_MASK) |
                   (original_raw & APT_PROFILE_POWER_MASK);
    return 1;
}

static inline int apt_power_fields_equal(uint64_t left, uint64_t right) {
    return (left & APT_PROFILE_POWER_MASK) == (right & APT_PROFILE_POWER_MASK);
}
#endif
