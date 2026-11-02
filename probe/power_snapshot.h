#ifndef APEXTUNE_POWER_SNAPSHOT_H
#define APEXTUNE_POWER_SNAPSHOT_H

#include <stdint.h>

#define APT_POWER_MAGIC 0x41505431u
#define APT_POWER_VERSION 2u
#define APT_SELECTOR_SNAPSHOT 0u
#define APT_SELECTOR_BEGIN_TRIAL 1u
#define APT_SELECTOR_FINISH_TRIAL 2u
#define APT_MSR_POWER_UNIT 0x606u
#define APT_MSR_PACKAGE_POWER_LIMIT 0x610u
#define APT_TRIAL_MAX_SECONDS 10u
#define APT_WATCHDOG_MAX_SECONDS 30u
#define APT_TRIAL_MIN_WATTS 10u
#define APT_TRIAL_MAX_WATTS 45u
#define APT_PL1_POWER_MASK 0x0000000000007fffULL
#define APT_PL1_ENABLE_MASK 0x0000000000008000ULL
#define APT_PL1_CLAMP_MASK 0x0000000000010000ULL
#define APT_PL2_POWER_MASK 0x00007fff00000000ULL
#define APT_PL2_ENABLE_MASK 0x0000800000000000ULL
#define APT_PL2_CLAMP_MASK 0x0001000000000000ULL
#define APT_POWER_LOCK_MASK 0x8000000000000000ULL
#define APT_TRIAL_POWER_MASK (APT_PL1_POWER_MASK | APT_PL2_POWER_MASK)

typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint16_t version;
    uint16_t size;
    uint64_t power_unit_msr;
    uint64_t package_power_limit_msr;
} apt_power_snapshot;

typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint16_t version;
    uint16_t size;
    uint32_t pl1_watts;
    uint32_t pl2_watts;
    uint32_t duration_seconds;
} apt_trial_request;

typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint16_t version;
    uint16_t size;
    uint32_t duration_seconds;
    uint64_t before_raw;
    uint64_t applied_raw;
    uint64_t restored_raw;
} apt_trial_result;

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
static inline int apt_build_trial_limit(uint64_t unit_msr, uint64_t current_raw,
                                        uint32_t pl1_watts, uint32_t pl2_watts,
                                        uint32_t duration_seconds, uint64_t *updated_raw) {
    if (!updated_raw || duration_seconds == 0 || duration_seconds > APT_TRIAL_MAX_SECONDS ||
        pl1_watts < APT_TRIAL_MIN_WATTS || pl2_watts < APT_TRIAL_MIN_WATTS ||
        pl1_watts > APT_TRIAL_MAX_WATTS || pl2_watts > APT_TRIAL_MAX_WATTS ||
        pl1_watts > pl2_watts) return 0;
    if ((current_raw & APT_POWER_LOCK_MASK) != 0 ||
        (current_raw & APT_PL1_ENABLE_MASK) == 0 ||
        (current_raw & APT_PL2_ENABLE_MASK) == 0) return 0;
    const unsigned exponent = (unsigned)(unit_msr & 0x0f);
    const uint64_t unit = 1ULL << exponent;
    const uint64_t pl1_units = (uint64_t)pl1_watts * unit;
    const uint64_t pl2_units = (uint64_t)pl2_watts * unit;
    const uint64_t current_pl1 = current_raw & APT_PL1_POWER_MASK;
    const uint64_t current_pl2 = (current_raw & APT_PL2_POWER_MASK) >> 32;
    if (pl1_units > APT_PL1_POWER_MASK || pl2_units > 0x7fffULL ||
        pl1_units > current_pl1 || pl2_units > current_pl2) return 0;
    *updated_raw = (current_raw & ~APT_TRIAL_POWER_MASK) |
                   pl1_units | (pl2_units << 32);
    return 1;
}

// Restore only the saved PL1/PL2 power fields, preserving current control bits.
static inline int apt_build_restore_limit(uint64_t current_raw, uint64_t original_raw,
                                          uint64_t *updated_raw) {
    if (!updated_raw || (current_raw & APT_POWER_LOCK_MASK) != 0) return 0;
    *updated_raw = (current_raw & ~APT_TRIAL_POWER_MASK) |
                   (original_raw & APT_TRIAL_POWER_MASK);
    return 1;
}

static inline int apt_power_fields_equal(uint64_t left, uint64_t right) {
    return (left & APT_TRIAL_POWER_MASK) == (right & APT_TRIAL_POWER_MASK);
}
#endif
