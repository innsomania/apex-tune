#ifndef APEXTUNE_POWER_SNAPSHOT_H
#define APEXTUNE_POWER_SNAPSHOT_H

#include <stdint.h>

#define APT_POWER_MAGIC 0x41505431u
#define APT_POWER_VERSION 1u
#define APT_SELECTOR_SNAPSHOT 0u
#define APT_MSR_POWER_UNIT 0x606u
#define APT_MSR_PACKAGE_POWER_LIMIT 0x610u

typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint16_t version;
    uint16_t size;
    uint64_t power_unit_msr;
    uint64_t package_power_limit_msr;
} apt_power_snapshot;

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
    if (exponent > 15) return 0;
    result->watts_per_unit = 1.0 / (double)(1u << exponent);
    const uint64_t limit = snapshot->package_power_limit_msr;
    result->pl1_watts = (double)(limit & 0x7fffULL) * result->watts_per_unit;
    result->pl1_enabled = (unsigned)((limit >> 15) & 1ULL);
    result->pl1_clamp = (unsigned)((limit >> 16) & 1ULL);
    result->pl2_watts = (double)((limit >> 32) & 0x7fffULL) * result->watts_per_unit;
    result->pl2_enabled = (unsigned)((limit >> 47) & 1ULL);
    result->pl2_clamp = (unsigned)((limit >> 48) & 1ULL);
    result->locked = (unsigned)((limit >> 63) & 1ULL);
    return 1;
}
#endif
