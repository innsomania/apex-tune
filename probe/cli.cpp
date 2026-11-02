#include "power_snapshot.h"
#include <IOKit/IOKitLib.h>
#include <cstdio>
#include <cstring>

int main(int argc, char **) {
    if (argc != 1) {
        std::fprintf(stderr, "Usage: apextune-power-probe\n");
        return 64;
    }
    CFMutableDictionaryRef match = IOServiceMatching("ApexTunePowerReader");
    if (!match) return 70;
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, match);
    if (!service) {
        std::fprintf(stderr, "ApexTune read-only power service is not installed or loaded. No readings available.\n");
        return 69;
    }
    io_connect_t connection = IO_OBJECT_NULL;
    kern_return_t kr = IOServiceOpen(service, mach_task_self(), 0, &connection);
    IOObjectRelease(service);
    if (kr != KERN_SUCCESS) {
        std::fprintf(stderr, "Cannot open ApexTune power service (0x%x). Run as administrator after an authorized installation.\n", kr);
        return 77;
    }
    apt_power_snapshot snapshot{};
    size_t output_size = sizeof(snapshot);
    kr = IOConnectCallStructMethod(connection, APT_SELECTOR_SNAPSHOT, nullptr, 0,
                                   &snapshot, &output_size);
    IOServiceClose(connection);
    if (kr != KERN_SUCCESS || output_size != sizeof(snapshot)) {
        std::fprintf(stderr, "Power snapshot failed (0x%x).\n", kr);
        return 74;
    }
    apt_decoded_power decoded{};
    if (!apt_decode_power(&snapshot, &decoded)) {
        std::fprintf(stderr, "Power service returned an invalid snapshot.\n");
        return 65;
    }
    std::printf("Package PL1: %.2f W (%s, clamp %s)\n", decoded.pl1_watts,
                decoded.pl1_enabled ? "enabled" : "disabled", decoded.pl1_clamp ? "on" : "off");
    std::printf("Package PL2: %.2f W (%s, clamp %s)\n", decoded.pl2_watts,
                decoded.pl2_enabled ? "enabled" : "disabled", decoded.pl2_clamp ? "on" : "off");
    std::printf("Package limit lock: %s\n", decoded.locked ? "locked" : "unlocked");
    std::printf("These are package limits, not whole-computer power readings.\n");
    return 0;
}
