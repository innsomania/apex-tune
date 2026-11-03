import AppKit

private func check(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() {
        fputs("FAILED: \(message)\n", stderr)
        fatalError("FAILED: \(message)")
    }
}

@main
enum ApexTunePolicyTests {
    private struct MockProbe {
        let originalPL1: Int
        let originalPL2: Int
        private(set) var actual: Profile?
        private(set) var setCount = 0
        private(set) var active = false
        var rejectSet = false

        mutating func begin() { active = true }
        mutating func set(_ profile: Profile) -> Bool {
            guard active, profile.pl1 <= originalPL1, profile.pl2 <= originalPL2,
                  profile.pl1 <= 160, profile.pl2 <= 160, !rejectSet else { return false }
            actual = profile
            setCount += 1
            return true
        }
        mutating func finish() {
            actual = nil
            active = false
        }
    }

    static func main() {
        check(ApexTuneLaunchMode.parse([]) == .observe &&
              ApexTuneLaunchMode.parse(["--daemon"]) == .daemon &&
              ApexTuneLaunchMode.parse(["--status"]) == .status &&
              ApexTuneLaunchMode.parse(["--control"]) == .control &&
              ApexTuneLaunchMode.parse(["--daemon", "--status"]) == nil,
              "launch modes keep observe default and reject conflicting service modes")

        let statusURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ApexTune-status-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: statusURL) }
        let statusStore = ServiceStatusStore(url: statusURL)
        let statusTime = Date(timeIntervalSince1970: 1_800_000_000)
        try! statusStore.write(ServiceStatus(updatedAt: statusTime, state: .controlling,
            message: "active\ninvalid", actualPL1: 35, actualPL2: 45,
            appliedPL1: 35, appliedTier: 3, appliedPL2: 45,
            packageWatts: 28.5, cpuTemperatureC: 76.2, powerSampleAt: statusTime))
        let writtenStatus = try! Data(contentsOf: statusURL)
        let statusObject = try! JSONSerialization.jsonObject(with: writtenStatus) as! [String: Any]
        let statusAttributes = try! FileManager.default.attributesOfItem(atPath: statusURL.path)
        let statusPermissions = (statusAttributes[.posixPermissions] as? NSNumber)?.intValue
        check(statusObject["command"] == nil && statusPermissions == 0o644,
              "status file is read-only to users and contains no command channel")
        let currentStatus = statusStore.read(now: statusTime.addingTimeInterval(2))
        check(currentStatus?.state == .controlling && currentStatus?.actualPL1 == 35 &&
              currentStatus?.packageWatts == 28.5 && currentStatus?.cpuTemperatureC == 76.2,
              "read-only status provides current confirmed readings")
        check(currentStatus?.message == "activeinvalid", "status text is sanitized")
        let staleReading = statusStore.read(now: statusTime.addingTimeInterval(5))
        check(staleReading?.state == .controlling && staleReading?.packageWatts == nil &&
              staleReading?.cpuTemperatureC == nil && staleReading?.actualPL1 == 35,
              "stale sensors disappear while fresh daemon state and confirmed limits remain")
        check(statusStore.read(now: statusTime.addingTimeInterval(9))?.state == .stale,
              "stale status heartbeat is visibly unavailable")

        let lockURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ApexTune-lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: lockURL) }
        let firstLock = ControllerInstanceLock.acquire(path: lockURL.path)
        check(firstLock != nil && ControllerInstanceLock.acquire(path: lockURL.path) == nil,
              "controller lock rejects a second writer")
        firstLock?.release()
        check(ControllerInstanceLock.acquire(path: lockURL.path) != nil,
              "controller lock permits restart after release")

        check(ControlRuntime.powerMetricsArguments == [
            "--samplers", "cpu_power,gpu_power,smc", "-i", "1000", "-b", "1"
        ], "powermetrics uses supported one-second sampling and line-buffered output")
        let menuTrackingMode = RunLoop.Mode.eventTracking
        let controlTick = DispatchSemaphore(value: 0)
        let controlTimer = ControlRuntime.scheduleControlTimer(
            interval: 0.01, handler: { _ in controlTick.signal() })
        let menuTrackingDeadline = Date().addingTimeInterval(0.12)
        while Date() < menuTrackingDeadline {
            _ = RunLoop.main.run(mode: menuTrackingMode,
                                 before: Date().addingTimeInterval(0.02))
        }
        controlTimer.invalidate()
        let firstControlTick = controlTick.wait(timeout: .now()) == .success
        let secondControlTick = controlTick.wait(timeout: .now()) == .success
        check(firstControlTick && secondControlTick,
              "control timer continues in menu-tracking run-loop mode")
        let stopSignal = DispatchSemaphore(value: 0)
        let stoppingTimer = ControlRuntime.scheduleControlTimer(interval: 0.01) { _ in
            stopSignal.signal()
            CFRunLoopStop(CFRunLoopGetMain())
        }
        CFRunLoopRun()
        stoppingTimer.invalidate()
        check(stopSignal.wait(timeout: .now()) == .success,
              "headless Core Foundation loop exits after the stop request")

        check(ProfilePolicy.pl1Levels.count == 141, "141 PL1 values")
        check(ProfilePolicy.pl1Levels.first == 20 && ProfilePolicy.pl1Levels.last == 160,
              "10..80 W profile limits in 0.5 W steps")
        for pl1 in ProfilePolicy.pl1Levels {
            for tier in 1...5 {
                let profile = ProfilePolicy.fixedProfile(pl1: pl1, tier: tier,
                                                         baselinePL1: 200, baselinePL2: 250)
                check(profile?.pl1 == pl1 && profile?.tier == tier,
                      "all 15 PL1 levels and five tiers are supported: requested \(pl1)/\(tier), got \(String(describing: profile))")
                let mappedPL2 = min(160, pl1 + (tier - 1) * 10)
                check(profile?.pl2 == mappedPL2 && mappedPL2 <= 160 && mappedPL2 >= pl1,
                      "PL2 tier is bounded")
            }
        }

        let full = ProfilePolicy.proposal(for: frame(load: 1, temp: 50, watts: 20),
                                          baselinePL1: 200, baselinePL2: 250)
        check(full == Profile(pl1: 160, tier: 5, pl2: 160), "80 W ceiling and tier collapse")
        let bounded = ProfilePolicy.proposal(for: frame(load: 1, temp: 50, watts: 20),
                                             baselinePL1: 110, baselinePL2: 124)
        check(bounded?.pl1 == 110 && bounded?.pl2 == 124, "immutable session baseline caps proposals")
        check(ProfilePolicy.proposal(for: frame(load: 1, temp: 50, watts: 20),
                                     baselinePL1: 10, baselinePL2: 200) == nil,
              "baseline below minimum refuses a profile")
        check(ProfilePolicy.proposal(for: frame(load: 0.95, temp: 72, watts: 68))?.pl1 == 133,
              "moderate temperature and package power reduce proposal")
        let hot75 = ProfilePolicy.proposal(for: frame(load: 1, temp: 75, watts: 30))
        check(hot75?.pl1 == 50 && hot75?.tier == 1 && hot75?.pl2 == 50,
              "75 C caps PL1 at 25 W and removes PL2 headroom")
        let hot80 = ProfilePolicy.proposal(for: frame(load: 1, temp: 80, watts: 30))
        check(hot80 == Profile(pl1: 20, tier: 1, pl2: 20),
              "80 C immediately proposes the minimum 10/10 W profile")
        let serious = ProfilePolicy.proposal(for: frame(load: 1, temp: 75, watts: 30,
                                                          thermal: .serious))
        check(serious?.pl1 == 50 && serious?.tier == 1 && serious?.pl2 == 50,
              "serious system thermal state caps PL1 at 25 W without PL2 headroom")

        let demand = Profile(pl1: 80, tier: 5, pl2: 120)
        let burstStart = Date(timeIntervalSince1970: 1_800_000_000)
        var burstBudget = TurboBurstBudget()
        let burst0 = burstBudget.constrain(demand, cpuTemperatureC: 74,
                                           thermal: .nominal, now: burstStart)
        check(burst0.profile == Profile(pl1: 80, tier: 2, pl2: 90) &&
              !burst0.closeImmediately,
              "eligible Turbo burst adds no more than 5 W")
        check(burstBudget.burstStartedAt == nil,
              "Turbo duration starts only after the driver confirms the raised PL2")
        burstBudget.confirmApplied(burst0.profile, at: burstStart)
        let burst1 = burstBudget.constrain(demand, cpuTemperatureC: 74,
                                           thermal: .nominal,
                                           now: burstStart.addingTimeInterval(1))
        check(burst1.profile.pl2 == 90, "burst remains available before its 2-second limit")
        let changedDemand = Profile(pl1: 90, tier: 5, pl2: 130)
        let changedBurst = burstBudget.constrain(changedDemand, cpuTemperatureC: 74,
                                                 thermal: .nominal,
                                                 now: burstStart.addingTimeInterval(1.5))
        burstBudget.confirmApplied(changedBurst.profile, at: burstStart.addingTimeInterval(1.5))
        check(changedBurst.profile.pl2 == 100 && burstBudget.burstStartedAt == burstStart,
              "profile changes do not extend the confirmed burst timer")
        let burstEnd = burstBudget.constrain(changedDemand, cpuTemperatureC: 74,
                                             thermal: .nominal,
                                             now: burstStart.addingTimeInterval(2))
        check(burstEnd.profile == Profile(pl1: 90, tier: 1, pl2: 90) &&
              burstEnd.closeImmediately &&
              burstBudget.cooldownUntil == burstStart.addingTimeInterval(32),
              "burst closes at 2 seconds and starts a 30-second cooldown")
        let cooling = burstBudget.constrain(demand, cpuTemperatureC: 74,
                                            thermal: .nominal,
                                            now: burstStart.addingTimeInterval(31))
        check(cooling.profile.pl2 == 80 && burstBudget.burstCount == 1,
              "no repeated Turbo burst during cooldown")
        let afterCooldown = burstBudget.constrain(demand, cpuTemperatureC: 74,
                                                  thermal: .nominal,
                                                  now: burstStart.addingTimeInterval(32))
        burstBudget.confirmApplied(afterCooldown.profile, at: burstStart.addingTimeInterval(32))
        check(afterCooldown.profile.pl2 == 90 && burstBudget.burstCount == 2,
              "a new burst can start after the full cooldown")
        let hotBurstClosure = burstBudget.constrain(demand, cpuTemperatureC: 75,
                                                    thermal: .nominal,
                                                    now: burstStart.addingTimeInterval(33))
        check(hotBurstClosure.profile.pl2 == 80 && hotBurstClosure.closeImmediately,
              "75 C closes an active Turbo burst immediately")
        check(ProfilePolicy.fixedProfile(pl1: 160, tier: 5, baselinePL1: 150, baselinePL2: 250) == nil,
              "PL1 above immutable baseline is refused")
        check(ProfilePolicy.proposal(for: frame(load: 0.95, temp: 95, watts: 80,
                                                thermal: .critical)) == nil,
              "critical thermal state refuses a proposal")
        check(ProfilePolicy.proposal(for: frame(load: 0.5, temp: nil, watts: nil)) != nil,
              "observe-only proposal uses real CPU/thermal metrics without inventing power data")
        check(ProfilePolicy.proposal(for: frame(load: 0.5, temp: nil, watts: nil), requirePower: true) == nil,
              "control proposal requires real power and temperature sensors")

        let fallbackProfile = SensorFallbackRecovery.safeProfile
        check(fallbackProfile == Profile(pl1: 20, tier: 1, pl2: 20),
              "startup and sensor degradation use bounded 10/10 W profile")
        check(Profile(pl1: 21, tier: 1, pl2: 21).pl1Text == "10.5" &&
              Profile(pl1: 21, tier: 1, pl2: 21).pl2Text == "10.5",
              "half-watt profile output is formatted exactly for the probe protocol")
        var fallbackRecovery = SensorFallbackRecovery()
        let fallbackStart = Date(timeIntervalSince1970: 1_800_000_100)
        check(!fallbackRecovery.observe(isSafe: false, sampleAt: nil),
              "missing sensors remain in safe fallback")
        for second in 0...10 {
            let sampleAt = fallbackStart.addingTimeInterval(Double(second))
            let recovered = fallbackRecovery.observe(isSafe: true, sampleAt: sampleAt)
            if second == 4 {
                check(!recovered && fallbackRecovery.isDegraded,
                      "five safe samples alone do not leave fallback before the 10-second dwell")
            }
            if second < 10 {
                check(!recovered, "recovery waits for stable fresh CPU and power samples")
            } else {
                check(recovered && !fallbackRecovery.isDegraded,
                      "ten seconds of five or more fresh safe samples permit gradual recovery")
            }
        }
        fallbackRecovery.observe(isSafe: false, sampleAt: nil)
        check(fallbackRecovery.isDegraded && fallbackRecovery.consecutiveFreshSamples == 0,
              "critical or missing sensor resets recovery dwell to 10/10 fallback")
        check(!SensorFallbackRecovery.sampleIsFresh(fallbackStart, now: fallbackStart.addingTimeInterval(5)),
              "a sensor sample older than four seconds is unavailable")
        check(SensorFallbackRecovery.sampleIsFresh(fallbackStart.addingTimeInterval(1),
              now: fallbackStart.addingTimeInterval(1)),
              "fresh CPU tick is checked after the current sample timestamp is recorded")
        check(SensorFallbackRecovery.heartbeatIsDue(lastSentAt: fallbackStart,
              now: fallbackStart.addingTimeInterval(10)),
              "sensor fallback continues due heartbeats while readings are unavailable")
        check(!SensorFallbackRecovery.sensorsAreSafe(cpuFresh: true, powerFresh: true,
              thermal: .critical, cpuTemperatureC: 60),
              "critical thermal input keeps the live controller in 10/10 fallback")
        check(!SensorFallbackRecovery.sensorsAreSafe(cpuFresh: true, powerFresh: true,
              thermal: .nominal, cpuTemperatureC: 75),
              "recovery requires CPU die temperature below 75 C")

        var parser = PowerMetricsParser()
        let first = """
        *** Sampled system activity (Mon Nov 2 23:08:42 2026 +0300) (1008.68ms elapsed) ***
        Intel energy model derived package power (CPUs+GT+SA): 20.82W
        CPU die temperature: 66.43 C
        """
        let partial = String(first.prefix(57))
        check(parser.consume(partial, now: Date(timeIntervalSince1970: 100)).isEmpty,
              "parser accepts split pipe data")
        let rest = String(first.dropFirst(57))
        let parsed = parser.consume(rest + "\n*** Sampled system activity next\n",
                                    now: Date(timeIntervalSince1970: 101))
        check(parsed.count == 1, "parser emits complete Intel sample")
        check(parsed[0].map { abs($0.packageWatts - 20.82) < 0.001 && abs($0.cpuTemperatureC - 66.43) < 0.001 } == true,
              "actual powermetrics Intel output parsed")
        var ambiguousTemperature = PowerMetricsParser()
        _ = ambiguousTemperature.consume("*** Sampled system activity\n" +
            "Intel energy model derived package power (CPUs+GT+SA): 12.5W\n" +
            "CPU temperature: 96.4 C\n*** Sampled system activity next\n")
        check(ambiguousTemperature.finish() == nil,
              "ambiguous CPU temperature is not mislabeled as CPU die temperature")
        var malformed = PowerMetricsParser()
        _ = malformed.consume("*** Sampled system activity\nIntel energy model derived package power (CPUs+GT+SA): 10W\n*** Sampled system activity\n")
        check(malformed.finish() == nil, "missing temperature is invalid")

        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let small = Profile(pl1: 20, tier: 1, pl2: 20)
        let large = Profile(pl1: 160, tier: 5, pl2: 160)
        var hysteresis = ProfileHysteresis()
        hysteresis.confirmApplied(small, at: t0)
        check(hysteresis.observe(large, now: t0.addingTimeInterval(2)) == nil,
              "upward response waits three seconds between confirmed steps")
        let firstStep = hysteresis.observe(large, now: t0.addingTimeInterval(3))!
        check(firstStep.pl1 == 21 && firstStep.pl2 == 21,
              "first upward step is limited to 0.5 W for both limits")
        check(hysteresis.applied == small, "an unacknowledged candidate never changes applied state")
        hysteresis.confirmApplied(firstStep, at: t0.addingTimeInterval(3))
        check(hysteresis.observe(large, now: t0.addingTimeInterval(5)) == nil,
              "acknowledged increases still wait for the full three-second interval")
        let secondStep = hysteresis.observe(large, now: t0.addingTimeInterval(6))!
        check(secondStep.pl1 - firstStep.pl1 <= 1 && secondStep.pl2 - firstStep.pl2 <= 1,
              "successive PL1 and PL2 increases are bounded to 0.5 W")
        check(hysteresis.applied == firstStep, "second candidate awaits its own acknowledgement")

        var reversal = ProfileHysteresis()
        reversal.confirmApplied(small, at: t0)
        let upward = reversal.observe(large, now: t0.addingTimeInterval(3))!
        reversal.confirmApplied(upward, at: t0.addingTimeInterval(3))
        check(reversal.observe(small, now: t0.addingTimeInterval(4)) == nil,
              "reversing demand before three seconds cannot bypass the confirmed-step interval")
        let downward = reversal.observe(small, now: t0.addingTimeInterval(6))!
        check(downward.pl1 == upward.pl1 - 1 && downward.pl2 == upward.pl2 - 1,
              "reversed demand steps down by only 0.5 W after the confirmed interval")

        var mixedChange = ProfileHysteresis()
        let mixedBase = Profile(pl1: 120, tier: 1, pl2: 120)
        mixedChange.confirmApplied(mixedBase, at: t0)
        let mixedTarget = Profile(pl1: 100, tier: 5, pl2: 140)
        let mixedStep = mixedChange.observe(mixedTarget, now: t0.addingTimeInterval(3))!
        check(mixedStep.pl1 == 119 && mixedStep.pl2 == 121,
              "a PL1 reduction cannot bypass the 0.5 W cap on simultaneous PL2 increase")

        var tierCompatibleDrop = ProfileHysteresis()
        let headroomApplied = Profile(pl1: 40, tier: 2, pl2: 50)
        tierCompatibleDrop.confirmApplied(headroomApplied, at: t0)
        let baseTarget = Profile(pl1: 20, tier: 1, pl2: 20)
        let headroomStep = tierCompatibleDrop.observe(baseTarget, now: t0.addingTimeInterval(3))!
        check(headroomStep.pl1 == 39 && headroomStep.pl2 == 49 && headroomStep.tier == 2 &&
              ProfilePolicy.fixedProfile(pl1: headroomStep.pl1, tier: headroomStep.tier,
                  baselinePL1: 160, baselinePL2: 160)?.pl2 == headroomStep.pl2,
              "PL2 ramp-down retains the minimum compatible tier without enlarging its target")

        var immediateMixed = ProfileHysteresis()
        immediateMixed.confirmApplied(headroomApplied, at: t0)
        let firstImmediate = immediateMixed.observe(Profile(pl1: 80, tier: 1, pl2: 40),
            now: t0.addingTimeInterval(0.1), immediateReduction: true)!
        check(firstImmediate.pl1 == 40 && firstImmediate.pl2 == 40,
              "immediate reduction never raises PL1 while lowering PL2")
        immediateMixed.confirmApplied(firstImmediate, at: t0.addingTimeInterval(0.1))
        let secondImmediate = immediateMixed.observe(Profile(pl1: 30, tier: 5, pl2: 60),
            now: t0.addingTimeInterval(0.2), immediateReduction: true)!
        check(secondImmediate.pl1 == 30 && secondImmediate.pl2 == 40,
              "repeated immediate mixed changes below three seconds cannot raise PL2")

        hysteresis.confirmApplied(large, at: t0.addingTimeInterval(6))
        check(hysteresis.observe(small, now: t0.addingTimeInterval(8)) == nil,
              "ordinary reduction observes the three-second confirmed-step interval")
        let firstDown = hysteresis.observe(small, now: t0.addingTimeInterval(9))!
        check(firstDown.pl1 == large.pl1 - 1 && firstDown.pl2 == large.pl2 - 1,
              "ordinary 80 W to 10 W drop starts at 79.5 W after three seconds")
        check(hysteresis.applied == large, "downshift remains proposed until confirmed")
        hysteresis.confirmApplied(firstDown, at: t0.addingTimeInterval(9))
        check(hysteresis.observe(small, now: t0.addingTimeInterval(11)) == nil,
              "next ordinary downward step waits three seconds after readback")
        let secondDown = hysteresis.observe(small, now: t0.addingTimeInterval(12))!
        check(secondDown.pl1 == firstDown.pl1 - 1 && secondDown.pl2 == firstDown.pl2 - 1,
              "each ordinary downward readback advances by only another 0.5 W")

        var thermal = ProfileHysteresis()
        thermal.confirmApplied(large, at: t0)
        check(thermal.observe(Profile(pl1: 50, tier: 1, pl2: 50),
                              now: t0.addingTimeInterval(0.1), immediateReduction: true) ==
              Profile(pl1: 50, tier: 1, pl2: 50),
              "75 C thermal reduction bypasses the ordinary ramp immediately")
        check(thermal.applied == large, "thermal candidate also waits for confirmed readback")

        var emergency = ProfileHysteresis()
        emergency.confirmApplied(large, at: t0)
        check(emergency.observe(Profile(pl1: 20, tier: 1, pl2: 20),
                                now: t0.addingTimeInterval(0.1), immediateReduction: true) ==
              Profile(pl1: 20, tier: 1, pl2: 20),
              "80 C emergency reduction is eligible on the first valid sample")

        var lifecycle = ControllerLifecycle()
        lifecycle.begin(originalPL1: 200, originalPL2: 250)
        lifecycle.applyConfirmed(fallbackProfile)
        check(lifecycle.isActive && lifecycle.applied == fallbackProfile,
              "sensor fallback retains the active control lease and confirmed 10/10 W profile")
        lifecycle.restored()
        check(!lifecycle.isActive && lifecycle.applied == nil, "restore returns lifecycle to observe mode")

        let observationProposal = ProfilePolicy.proposal(for: frame(load: 1, temp: nil, watts: nil))
        var mock = MockProbe(originalPL1: 200, originalPL2: 250)
        check(observationProposal != nil && mock.setCount == 0 && mock.actual == nil,
              "observation proposes a profile without applying it or opening probe")
        mock.begin()
        if let proposal = full { _ = mock.set(proposal) }
        check(mock.actual == full && mock.setCount == 1,
              "injected control probe separates applied readback from proposal")
        mock.finish()
        check(!mock.active && mock.actual == nil && mock.originalPL1 == 200 && mock.originalPL2 == 250,
              "mock disconnect/finish restores saved baseline including values above the profile cap")

        var failedAck = ProfileHysteresis()
        failedAck.confirmApplied(small, at: t0)
        let failedCandidate = failedAck.observe(large, now: t0.addingTimeInterval(3))!
        var rejectingMock = MockProbe(originalPL1: 200, originalPL2: 250, rejectSet: true)
        rejectingMock.begin()
        check(!rejectingMock.set(failedCandidate) && failedAck.applied == small,
              "failed profile acknowledgement leaves applied state unchanged")
        lifecycle.begin(originalPL1: 200, originalPL2: 250)
        lifecycle.restored()
        check(!lifecycle.isActive, "failed acknowledgement cleanup releases the session")

        print(SimulationReport.render())
        print("Policy, telemetry parser, hysteresis, and fail-safe lifecycle tests passed.")
    }

    private static func frame(load: Double, temp: Double?, watts: Double?,
                              thermal: ThermalLevel = .nominal) -> SensorFrame {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let power = (temp != nil && watts != nil)
            ? PowerSample(packageWatts: watts!, cpuTemperatureC: temp!, timestamp: now) : nil
        return SensorFrame(cpuLoad: load, thermal: thermal, power: power, timestamp: now)
    }
}
