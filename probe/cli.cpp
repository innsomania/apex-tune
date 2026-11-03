#include "power_snapshot.h"
#include <IOKit/IOKitLib.h>
#include <cerrno>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <poll.h>
#include <sstream>
#include <string>
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
        std::fprintf(stderr, "Cannot open ApexTune power service (0x%x); run as administrator.\n", status);
        return IO_OBJECT_NULL;
    }
    return connection;
}

static bool validSessionResult(const apt_session_result &result) {
    return apt_valid_header(result.magic, result.version, result.size, sizeof(result));
}

static bool readSnapshot(io_connect_t connection, apt_power_snapshot *snapshot) {
    size_t output_size = sizeof(*snapshot);
    kern_return_t status = IOConnectCallStructMethod(connection, APT_SELECTOR_SNAPSHOT,
                                                      nullptr, 0, snapshot, &output_size);
    if (status != KERN_SUCCESS || output_size != sizeof(*snapshot)) {
        std::fprintf(stderr, "Power snapshot failed (0x%x); the loaded reader may not use protocol v4.\n", status);
        return false;
    }
    apt_decoded_power decoded{};
    if (!apt_decode_power(snapshot, &decoded) ||
        snapshot->undervolt_lock_status != APT_UNDERVOLT_LOCK_UNKNOWN) {
        std::fprintf(stderr, "Incompatible or invalid protocol v4 snapshot.\n");
        return false;
    }
    return true;
}

static void printLimit(const char *label, uint64_t raw, uint64_t unitMSR) {
    const double watt_unit = 1.0 / static_cast<double>(1ULL << (unitMSR & 0x0f));
    const uint64_t pl1 = raw & APT_PL1_POWER_MASK;
    const uint64_t pl2 = (raw & APT_PL2_POWER_MASK) >> 32;
    std::printf("%s PL1 %.3f W, PL2 %.3f W\n", label,
                static_cast<double>(pl1) * watt_unit,
                static_cast<double>(pl2) * watt_unit);
}

static void printSnapshot(const apt_power_snapshot &snapshot) {
    apt_decoded_power decoded{};
    apt_decode_power(&snapshot, &decoded);
    std::printf("Package PL1: %.2f W (%s, clamp %s)\n", decoded.pl1_watts,
                decoded.pl1_enabled ? "enabled" : "disabled", decoded.pl1_clamp ? "on" : "off");
    std::printf("Package PL2: %.2f W (%s, clamp %s)\n", decoded.pl2_watts,
                decoded.pl2_enabled ? "enabled" : "disabled", decoded.pl2_clamp ? "on" : "off");
    std::printf("Package limit lock: %s\n", decoded.locked ? "locked" : "unlocked");
    std::printf("Undervolt lock status: unknown (no documented family-specific read-only bit)\n");
    std::printf("These are package limits, not whole-computer power readings.\n");
}

static bool beginSession(io_connect_t connection, apt_session_result *result) {
    apt_session_request request{};
    request.magic = APT_POWER_MAGIC;
    request.version = APT_POWER_VERSION;
    request.size = sizeof(request);
    size_t output_size = sizeof(*result);
    kern_return_t status = IOConnectCallStructMethod(connection, APT_SELECTOR_BEGIN_SESSION,
                                                      &request, sizeof(request), result, &output_size);
    if (status != KERN_SUCCESS || output_size != sizeof(*result) || !validSessionResult(*result) || !result->active) {
        std::fprintf(stderr, "Power control session refused (0x%x).\n", status);
        return false;
    }
    return true;
}

static bool setProfile(io_connect_t connection, uint32_t pl1HalfWatts, uint32_t tier,
                       uint32_t pl2HalfWatts,
                       apt_session_result *result) {
    uint32_t maximum_pl2 = 0;
    if (!apt_profile_pl2(pl1HalfWatts, tier, APT_PROFILE_MAX_HALF_WATTS, &maximum_pl2) ||
        pl2HalfWatts < pl1HalfWatts || pl2HalfWatts > maximum_pl2) return false;
    apt_profile_request request{};
    request.magic = APT_POWER_MAGIC;
    request.version = APT_POWER_VERSION;
    request.size = sizeof(request);
    request.pl1_half_watts = pl1HalfWatts;
    request.pl2_half_watts = pl2HalfWatts;
    request.turbo_tier = tier;
    size_t output_size = sizeof(*result);
    kern_return_t status = IOConnectCallStructMethod(connection, APT_SELECTOR_SET_PROFILE,
                                                      &request, sizeof(request), result, &output_size);
    if (status != KERN_SUCCESS || output_size != sizeof(*result) || !validSessionResult(*result) ||
        !result->active || result->pl1_half_watts != pl1HalfWatts || result->turbo_tier != tier ||
        result->pl2_half_watts != pl2HalfWatts) {
        std::fprintf(stderr, "Profile update refused or failed (0x%x).\n", status);
        return false;
    }
    return true;
}

static bool heartbeat(io_connect_t connection, apt_session_result *result) {
    size_t output_size = sizeof(*result);
    kern_return_t status = IOConnectCallStructMethod(connection, APT_SELECTOR_HEARTBEAT,
                                                      nullptr, 0, result, &output_size);
    return status == KERN_SUCCESS && output_size == sizeof(*result) &&
           validSessionResult(*result) && result->active;
}

static bool finishSession(io_connect_t connection, apt_session_result *result) {
    size_t output_size = sizeof(*result);
    kern_return_t status = IOConnectCallStructMethod(connection, APT_SELECTOR_FINISH_SESSION,
                                                      nullptr, 0, result, &output_size);
    if (status != KERN_SUCCESS || output_size != sizeof(*result) || !validSessionResult(*result)) {
        std::fprintf(stderr, "Restore failed or was blocked (0x%x); verify the package limits.\n", status);
        if (output_size == sizeof(*result) && validSessionResult(*result))
            std::fprintf(stderr, "Restore active=%u, current MSR 0x%016llx, original MSR 0x%016llx\n",
                         result->active, static_cast<unsigned long long>(result->current_raw),
                         static_cast<unsigned long long>(result->original_raw));
        return false;
    }
    return !result->active && apt_power_fields_equal(result->current_raw, result->original_raw);
}

static bool validTrial(uint32_t pl1HalfWatts, uint32_t tier, uint32_t seconds) {
    uint32_t pl2 = 0;
    return apt_profile_pl2(pl1HalfWatts, tier, APT_PROFILE_MAX_HALF_WATTS, &pl2) && seconds > 0 && seconds <= 20;
}

static int runTrial(uint32_t pl1HalfWatts, uint32_t tier, uint32_t seconds) {
    uint32_t pl2HalfWatts = 0;
    if (!validTrial(pl1HalfWatts, tier, seconds)) {
        std::fprintf(stderr, "Trial requires PL1 10..80 W in 0.5 W steps, tier 1..5, duration 1..20s.\n");
        return 64;
    }
    if (!apt_profile_pl2(pl1HalfWatts, tier, APT_PROFILE_MAX_HALF_WATTS, &pl2HalfWatts)) return 64;
    if (geteuid() != 0) {
        std::fprintf(stderr, "Power profile changes require administrator privileges; run with sudo.\n");
        return 77;
    }
    io_connect_t connection = openReader();
    if (connection == IO_OBJECT_NULL) return 69;
    apt_power_snapshot before{};
    apt_session_result state{};
    int exit_code = 0;
    if (!readSnapshot(connection, &before) || !beginSession(connection, &state)) {
        IOServiceClose(connection);
        return 65;
    }
    printLimit("Before:", state.original_raw, before.power_unit_msr);
    if (!setProfile(connection, pl1HalfWatts, tier, pl2HalfWatts, &state)) {
        apt_session_result ignored{};
        finishSession(connection, &ignored);
        IOServiceClose(connection);
        return 65;
    }
    printLimit("Applied readback:", state.current_raw, before.power_unit_msr);

    struct sigaction action{};
    struct sigaction old_int{};
    struct sigaction old_term{};
    action.sa_handler = request_stop;
    sigemptyset(&action.sa_mask);
    sigaction(SIGINT, &action, &old_int);
    sigaction(SIGTERM, &action, &old_term);
    stop_requested = 0;
    for (uint32_t i = 0; i < seconds && !stop_requested; ++i) sleep(1);

    apt_session_result restored{};
    if (finishSession(connection, &restored)) {
        printLimit("Restored readback:", restored.current_raw, before.power_unit_msr);
    } else {
        exit_code = 70;
    }
    sigaction(SIGINT, &old_int, nullptr);
    sigaction(SIGTERM, &old_term, nullptr);
    IOServiceClose(connection);
    return exit_code;
}

static bool parseProfileCommand(const std::string &line, uint32_t *pl1HalfWatts,
                                uint32_t *tier, uint32_t *pl2HalfWatts) {
    if (!pl1HalfWatts || !tier || !pl2HalfWatts) return false;
    std::istringstream command(line);
    std::string verb, pl1Text, tierText, pl2Text, extra;
    if (!(command >> verb >> pl1Text >> tierText) || verb != "set" ||
        !apt_parse_half_watts(pl1Text.c_str(), pl1HalfWatts) ||
        !parseUnsigned(tierText.c_str(), tier)) return false;
    uint32_t maximumPL2 = 0;
    if (!apt_profile_pl2(*pl1HalfWatts, *tier, APT_PROFILE_MAX_HALF_WATTS, &maximumPL2)) return false;
    const bool hasExplicitPL2 = static_cast<bool>(command >> pl2Text);
    if (command >> extra) return false;
    if (hasExplicitPL2) {
        return apt_parse_half_watts(pl2Text.c_str(), pl2HalfWatts) &&
               *pl2HalfWatts >= *pl1HalfWatts && *pl2HalfWatts <= maximumPL2;
    }
    *pl2HalfWatts = maximumPL2;
    return true;
}

static bool processControllerCommand(io_connect_t connection, const std::string &line,
                                     uint64_t unitMSR, bool *finished) {
    *finished = false;
    if (line == "status") {
        apt_power_snapshot snapshot{};
        if (!readSnapshot(connection, &snapshot)) return false;
        printSnapshot(snapshot);
        return true;
    }
    if (line == "finish" || line == "quit") {
        apt_session_result result{};
        const bool restored = finishSession(connection, &result);
        if (validSessionResult(result)) printLimit("Restored readback:", result.current_raw, unitMSR);
        *finished = true;
        return restored;
    }
    uint32_t pl1HalfWatts = 0, tier = 0, pl2HalfWatts = 0;
    if (parseProfileCommand(line, &pl1HalfWatts, &tier, &pl2HalfWatts)) {
        uint32_t maximumPL2 = 0;
        if (!apt_profile_pl2(pl1HalfWatts, tier, APT_PROFILE_MAX_HALF_WATTS, &maximumPL2) ||
            pl2HalfWatts < pl1HalfWatts || pl2HalfWatts > maximumPL2) {
            std::fprintf(stderr, "Invalid profile; PL1 must be 10..80 W in 0.5 W steps and tier 1..5.\n");
            return false;
        }
        apt_session_result result{};
        if (!setProfile(connection, pl1HalfWatts, tier, pl2HalfWatts, &result)) return false;
        printLimit("Applied readback:", result.current_raw, unitMSR);
        std::printf("Turbo power budget tier %u; PL2 target %.1f W.\n", tier, pl2HalfWatts / 2.0);
        return true;
    }
    std::fprintf(stderr, "Commands: status | set <PL1-W-in-0.5-W-steps> <tier-1..5> | finish\n");
    return false;
}

static int runController() {
    if (geteuid() != 0) {
        std::fprintf(stderr, "The controller requires administrator privileges; run with sudo.\n");
        return 77;
    }
    io_connect_t connection = openReader();
    if (connection == IO_OBJECT_NULL) return 69;
    apt_power_snapshot snapshot{};
    apt_session_result state{};
    if (!readSnapshot(connection, &snapshot) || !beginSession(connection, &state)) {
        IOServiceClose(connection);
        return 65;
    }
    printSnapshot(snapshot);
    std::printf("Session active; profiles renew a 30-second lease. Type status, set <PL1-W-in-0.5-W-steps> <tier>, or finish.\n");
    std::string pending;
    bool finished = false;
    int exit_code = 0;
    struct sigaction action{};
    struct sigaction old_int{};
    struct sigaction old_term{};
    action.sa_handler = request_stop;
    sigemptyset(&action.sa_mask);
    sigaction(SIGINT, &action, &old_int);
    sigaction(SIGTERM, &action, &old_term);
    stop_requested = 0;
    while (!finished && !stop_requested) {
        struct pollfd descriptor{};
        descriptor.fd = STDIN_FILENO;
        descriptor.events = POLLIN;
        const int poll_status = poll(&descriptor, 1, APT_HEARTBEAT_SECONDS * 1000);
        if (poll_status < 0 && errno == EINTR) continue;
        if (poll_status < 0) {
            std::perror("poll");
            exit_code = 1;
            break;
        }
        if (poll_status == 0) {
            if (!heartbeat(connection, &state)) {
                std::fprintf(stderr, "Session heartbeat failed; closing the connection to trigger restoration.\n");
                exit_code = 70;
                break;
            }
            continue;
        }
        char buffer[512];
        const ssize_t count = read(STDIN_FILENO, buffer, sizeof(buffer));
        if (count == 0) {
            stop_requested = 1;
            break;
        }
        if (count < 0) {
            if (errno == EINTR) continue;
            std::perror("read");
            exit_code = 1;
            break;
        }
        pending.append(buffer, (size_t)count);
        if (!heartbeat(connection, &state)) {
            std::fprintf(stderr, "Session heartbeat failed; closing the connection to trigger restoration.\n");
            exit_code = 70;
            break;
        }
        size_t newline = 0;
        while (!finished && (newline = pending.find('\n')) != std::string::npos) {
            const std::string line = pending.substr(0, newline);
            pending.erase(0, newline + 1);
            const bool command_ok = processControllerCommand(connection, line, snapshot.power_unit_msr, &finished);
            if (!command_ok && finished) exit_code = 70;
            else if (!command_ok)
                std::fprintf(stderr, "Command failed; session remains leased and will restore on timeout or disconnect.\n");
        }
    }
    if (!finished) {
        apt_session_result result{};
        if (finishSession(connection, &result))
            printLimit("Restored readback:", result.current_raw, snapshot.power_unit_msr);
        else
            exit_code = 70;
    }
    sigaction(SIGINT, &old_int, nullptr);
    sigaction(SIGTERM, &old_term, nullptr);
    IOServiceClose(connection);
    return exit_code;
}

static double wattsFromRaw(uint64_t raw, uint64_t unitMSR, uint64_t mask, unsigned shift) {
    const uint64_t units = (raw & mask) >> shift;
    return static_cast<double>(units) / static_cast<double>(1ULL << (unitMSR & 0x0f));
}

static void emitMachineState(const char *event, const apt_session_result &state,
                             uint64_t unitMSR, bool active) {
    std::printf("{\"event\":\"%s\",\"active\":%s,\"pl1_watts\":%.1f,\"pl2_watts\":%.1f,"
                "\"tier\":%u,\"actual_pl1_watts\":%.3f,\"actual_pl2_watts\":%.3f,"
                "\"original_pl1_watts\":%.3f,\"original_pl2_watts\":%.3f}\n",
                event, active ? "true" : "false", state.pl1_half_watts / 2.0, state.pl2_half_watts / 2.0,
                state.turbo_tier,
                wattsFromRaw(state.current_raw, unitMSR, APT_PL1_POWER_MASK, 0),
                wattsFromRaw(state.current_raw, unitMSR, APT_PL2_POWER_MASK, 32),
                wattsFromRaw(state.original_raw, unitMSR, APT_PL1_POWER_MASK, 0),
                wattsFromRaw(state.original_raw, unitMSR, APT_PL2_POWER_MASK, 32));
    std::fflush(stdout);
}

static int runMachineController() {
    if (geteuid() != 0) {
        std::fprintf(stderr, "The control mode requires administrator privileges; run it explicitly as root.\n");
        return 77;
    }
    io_connect_t connection = openReader();
    if (connection == IO_OBJECT_NULL) return 69;
    apt_power_snapshot snapshot{};
    apt_session_result state{};
    if (!readSnapshot(connection, &snapshot) || !beginSession(connection, &state)) {
        IOServiceClose(connection);
        return 65;
    }
    emitMachineState("ready", state, snapshot.power_unit_msr, true);
    std::string line;
    int exit_code = 0;
    bool finished = false;
    while (!finished && std::getline(std::cin, line)) {
        if (line == "heartbeat") {
            if (!heartbeat(connection, &state)) {
                std::fprintf(stderr, "Session heartbeat failed.\n");
                exit_code = 70;
                break;
            }
            emitMachineState("heartbeat", state, snapshot.power_unit_msr, true);
        } else if (line == "finish") {
            apt_session_result restored{};
            const bool ok = finishSession(connection, &restored);
            emitMachineState(ok ? "restored" : "restore_failed", restored,
                             snapshot.power_unit_msr, restored.active != 0);
            if (!ok) exit_code = 70;
            finished = true;
        } else {
            uint32_t pl1HalfWatts = 0, tier = 0, pl2HalfWatts = 0;
            if (!parseProfileCommand(line, &pl1HalfWatts, &tier, &pl2HalfWatts) ||
                !apt_is_profile_pl1(pl1HalfWatts) || pl2HalfWatts < pl1HalfWatts ||
                pl2HalfWatts > APT_PROFILE_MAX_HALF_WATTS) {
                std::printf("{\"event\":\"error\",\"message\":\"invalid command\"}\n");
                std::fflush(stdout);
                continue;
            }
            if (!setProfile(connection, pl1HalfWatts, tier, pl2HalfWatts, &state)) {
                std::printf("{\"event\":\"error\",\"message\":\"profile refused\"}\n");
                std::fflush(stdout);
                apt_session_result restored{};
                if (!finishSession(connection, &restored)) exit_code = 70;
                else emitMachineState("restored", restored, snapshot.power_unit_msr, false);
                finished = true;
                break;
            }
            emitMachineState("applied", state, snapshot.power_unit_msr, true);
        }
    }
    if (!finished) {
        apt_session_result restored{};
        if (finishSession(connection, &restored))
            emitMachineState("restored", restored, snapshot.power_unit_msr, false);
        else
            exit_code = 70;
    }
    IOServiceClose(connection);
    return exit_code;
}

static int printCurrent() {
    io_connect_t connection = openReader();
    if (connection == IO_OBJECT_NULL) return 69;
    apt_power_snapshot snapshot{};
    const bool ok = readSnapshot(connection, &snapshot);
    if (ok) printSnapshot(snapshot);
    IOServiceClose(connection);
    return ok ? 0 : 65;
}

int main(int argc, char **argv) {
    std::setvbuf(stdout, nullptr, _IOLBF, 0);
    if (argc == 1) return printCurrent();
    if (argc == 2 && std::strcmp(argv[1], "controller") == 0) return runController();
    if (argc == 3 && std::strcmp(argv[1], "controller") == 0 &&
        std::strcmp(argv[2], "--machine") == 0) return runMachineController();
    if (argc == 5 && std::strcmp(argv[1], "trial") == 0) {
        uint32_t pl1HalfWatts = 0, tier = 0, seconds = 0;
        if (!apt_parse_half_watts(argv[2], &pl1HalfWatts) || !parseUnsigned(argv[3], &tier) ||
            !parseUnsigned(argv[4], &seconds)) {
            std::fprintf(stderr, "Usage: apextune-power-probe trial <PL1-W-in-0.5-W-steps> <tier-1..5> <seconds>\n");
            return 64;
        }
        return runTrial(pl1HalfWatts, tier, seconds);
    }
    std::fprintf(stderr, "Usage: apextune-power-probe [controller [--machine] | trial <PL1-W-in-0.5-W-steps> <tier-1..5> <seconds>]\n");
    return 64;
}
