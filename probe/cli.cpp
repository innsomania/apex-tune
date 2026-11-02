#include "power_snapshot.h"
#include <IOKit/IOKitLib.h>
#include <cerrno>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <unistd.h>

static volatile sig_atomic_t stop_requested = 0;
static void request_stop(int) { stop_requested = 1; }

static bool parseUnsigned(const char *text, uint32_t *value) {
    if (!text || !*text || !value || *text == '-') return false;
    errno = 0;
    char *end = nullptr;
    const unsigned long parsed = std::strtoul(text, &end, 10);
    if (errno || !end || *end || parsed > UINT32_MAX) return false;
    *value = static_cast<uint32_t>(parsed);
    return true;
}

static io_connect_t openReader() {
    CFMutableDictionaryRef match = IOServiceMatching("ApexTunePowerReader");
    if (!match) return IO_OBJECT_NULL;
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, match);
    if (!service) return IO_OBJECT_NULL;
    io_connect_t connection = IO_OBJECT_NULL;
    kern_return_t status = IOServiceOpen(service, mach_task_self(), 0, &connection);
    IOObjectRelease(service);
    if (status != KERN_SUCCESS) {
        std::fprintf(stderr, "Cannot open ApexTune power service (0x%x); run this command with administrator privileges.\n", status);
        return IO_OBJECT_NULL;
    }
    return connection;
}

static bool readSnapshot(io_connect_t connection, apt_power_snapshot *snapshot) {
    size_t output_size = sizeof(*snapshot);
    kern_return_t status = IOConnectCallStructMethod(connection, APT_SELECTOR_SNAPSHOT,
                                                      nullptr, 0, snapshot, &output_size);
    if (status != KERN_SUCCESS || output_size != sizeof(*snapshot)) {
        std::fprintf(stderr, "Power snapshot failed (0x%x). The loaded reader may be an older protocol version.\n", status);
        return false;
    }
    apt_decoded_power decoded{};
    if (!apt_decode_power(snapshot, &decoded)) {
        std::fprintf(stderr, "Incompatible or invalid reader protocol. ApexTune reader v2 is required.\n");
        return false;
    }
    return true;
}

static void printLimit(const char *label, uint64_t raw, uint64_t units) {
    const double watt_unit = 1.0 / static_cast<double>(1ULL << (units & 0x0f));
    const uint64_t pl1 = raw & APT_PL1_POWER_MASK;
    const uint64_t pl2 = (raw & APT_PL2_POWER_MASK) >> 32;
    std::printf("%s PL1 %.2f W, PL2 %.2f W\n", label,
                static_cast<double>(pl1) * watt_unit,
                static_cast<double>(pl2) * watt_unit);
}

static bool finish(io_connect_t connection, apt_trial_result *result) {
    size_t output_size = sizeof(*result);
    kern_return_t status = IOConnectCallStructMethod(connection, APT_SELECTOR_FINISH_TRIAL,
                                                      nullptr, 0, result, &output_size);
    if (status != KERN_SUCCESS || output_size != sizeof(*result)) {
        std::fprintf(stderr, "Restore request failed (0x%x); restoration was not confirmed.\n", status);
        if (output_size == sizeof(*result) && result->magic == APT_POWER_MAGIC &&
            result->version == APT_POWER_VERSION && result->size == sizeof(*result)) {
            std::fprintf(stderr, "Restoration readback: 0x%016llx (saved original: 0x%016llx).\n",
                         static_cast<unsigned long long>(result->restored_raw),
                         static_cast<unsigned long long>(result->before_raw));
        }
        std::fprintf(stderr, "Closing the client makes one more restore attempt; verify the PL1/PL2 values afterward.\n");
        return false;
    }
    if (result->magic != APT_POWER_MAGIC || result->version != APT_POWER_VERSION ||
        result->size != sizeof(*result)) {
        std::fprintf(stderr, "Invalid restore result from reader.\n");
        return false;
    }
    return true;
}

static int runTrial(uint32_t pl1, uint32_t pl2, uint32_t seconds) {
    if (geteuid() != 0) {
        std::fprintf(stderr, "Temporary PL1/PL2 trials require administrator privileges. Use sudo for this command.\n");
        return 77;
    }
    if (seconds == 0 || seconds > APT_TRIAL_MAX_SECONDS ||
        pl1 < APT_TRIAL_MIN_WATTS || pl2 < APT_TRIAL_MIN_WATTS ||
        pl1 > APT_TRIAL_MAX_WATTS || pl2 > APT_TRIAL_MAX_WATTS || pl1 > pl2) {
        std::fprintf(stderr, "Trial bounds: %u <= PL1 <= PL2 <= %u W, duration 1..%u seconds.\n",
                     APT_TRIAL_MIN_WATTS, APT_TRIAL_MAX_WATTS, APT_TRIAL_MAX_SECONDS);
        return 64;
    }
    io_connect_t connection = openReader();
    if (connection == IO_OBJECT_NULL) return 69;

    apt_power_snapshot before{};
    if (!readSnapshot(connection, &before)) {
        IOServiceClose(connection);
        return 65;
    }
    apt_decoded_power decoded{};
    apt_decode_power(&before, &decoded);
    if (decoded.locked || !decoded.pl1_enabled || !decoded.pl2_enabled) {
        std::fprintf(stderr, "Trial refused: current package limits are locked or disabled.\n");
        IOServiceClose(connection);
        return 65;
    }
    std::printf("Before: PL1 %.2f W, PL2 %.2f W\n", decoded.pl1_watts, decoded.pl2_watts);

    apt_trial_request request{};
    request.magic = APT_POWER_MAGIC;
    request.version = APT_POWER_VERSION;
    request.size = sizeof(request);
    request.pl1_watts = pl1;
    request.pl2_watts = pl2;
    request.duration_seconds = seconds;
    apt_trial_result trial{};
    size_t output_size = sizeof(trial);
    kern_return_t status = IOConnectCallStructMethod(connection, APT_SELECTOR_BEGIN_TRIAL,
                                                      &request, sizeof(request), &trial, &output_size);
    if (status != KERN_SUCCESS || output_size != sizeof(trial) ||
        trial.magic != APT_POWER_MAGIC || trial.version != APT_POWER_VERSION ||
        trial.size != sizeof(trial)) {
        std::fprintf(stderr, "Trial was refused or failed (0x%x).\n", status);
        if (output_size == sizeof(trial) && trial.magic == APT_POWER_MAGIC &&
            trial.version == APT_POWER_VERSION && trial.size == sizeof(trial)) {
            printLimit("Applied readback:", trial.applied_raw, before.power_unit_msr);
            printLimit("Recovery readback:", trial.restored_raw, before.power_unit_msr);
            if (!apt_power_fields_equal(trial.restored_raw, trial.before_raw)) {
                std::fprintf(stderr, "The original PL1/PL2 fields are not confirmed restored; client close will make one more attempt.\n");
            }
        }
        IOServiceClose(connection);
        return 65;
    }
    printLimit("Applied readback:", trial.applied_raw, before.power_unit_msr);

    struct sigaction action{};
    struct sigaction old_int{};
    struct sigaction old_term{};
    action.sa_handler = request_stop;
    sigemptyset(&action.sa_mask);
    sigaction(SIGINT, &action, &old_int);
    sigaction(SIGTERM, &action, &old_term);
    stop_requested = 0;
    for (uint32_t i = 0; i < seconds && !stop_requested; ++i) sleep(1);

    apt_trial_result restored{};
    const bool restored_ok = finish(connection, &restored);
    if (restored_ok) {
        printLimit("Restored readback:", restored.restored_raw, before.power_unit_msr);
        if (restored.restored_raw != restored.before_raw) {
            std::printf("Original PL1/PL2 fields were restored; other register bits changed during the trial.\n");
        }
    }
    sigaction(SIGINT, &old_int, nullptr);
    sigaction(SIGTERM, &old_term, nullptr);
    IOServiceClose(connection);
    return restored_ok && apt_power_fields_equal(restored.restored_raw, restored.before_raw) ? 0 : 70;
}

static int printCurrent() {
    io_connect_t connection = openReader();
    if (connection == IO_OBJECT_NULL) return 69;
    apt_power_snapshot snapshot{};
    int result = 0;
    if (readSnapshot(connection, &snapshot)) {
        apt_decoded_power decoded{};
        apt_decode_power(&snapshot, &decoded);
        std::printf("Package PL1: %.2f W (%s, clamp %s)\n", decoded.pl1_watts,
                    decoded.pl1_enabled ? "enabled" : "disabled", decoded.pl1_clamp ? "on" : "off");
        std::printf("Package PL2: %.2f W (%s, clamp %s)\n", decoded.pl2_watts,
                    decoded.pl2_enabled ? "enabled" : "disabled", decoded.pl2_clamp ? "on" : "off");
        std::printf("Package limit lock: %s\n", decoded.locked ? "locked" : "unlocked");
        std::printf("These are package limits, not whole-computer power readings.\n");
    } else {
        result = 65;
    }
    IOServiceClose(connection);
    return result;
}

int main(int argc, char **argv) {
    if (argc == 1) {
        return printCurrent();
    }
    if (argc == 5 && std::strcmp(argv[1], "trial") == 0) {
        uint32_t pl1 = 0, pl2 = 0, seconds = 0;
        if (!parseUnsigned(argv[2], &pl1) || !parseUnsigned(argv[3], &pl2) ||
            !parseUnsigned(argv[4], &seconds)) {
            std::fprintf(stderr, "Usage: apextune-power-probe trial <PL1-W> <PL2-W> <seconds>\n");
            return 64;
        }
        return runTrial(pl1, pl2, seconds);
    }
    std::fprintf(stderr, "Usage: apextune-power-probe [trial <PL1-W> <PL2-W> <seconds>]\n");
    return 64;
}
