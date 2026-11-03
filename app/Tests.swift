import AppKit

private func check(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError("FAILED: \(message)") }
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
                  profile.pl1 <= 80, profile.pl2 <= 80, !rejectSet else { return false }
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

        check(ProfilePolicy.pl1Levels.count == 15, "15 PL1 values")
        check(ProfilePolicy.pl1Levels.first == 10 && ProfilePolicy.pl1Levels.last == 80,
              "10..80 W profile limits")
        for pl1 in ProfilePolicy.pl1Levels {
            for tier in 1...5 {
                let profile = ProfilePolicy.fixedProfile(pl1: pl1, tier: tier,
                                                         baselinePL1: 100, baselinePL2: 125)
                check(profile?.pl1 == pl1 && profile?.tier == tier,
                      "all 15 PL1 levels and five tiers are supported")
                let mappedPL2 = min(80, pl1 + (tier - 1) * 5)
                check(profile?.pl2 == mappedPL2 && mappedPL2 <= 80 && mappedPL2 >= pl1,
                      "PL2 tier is bounded")
            }
        }

        let full = ProfilePolicy.proposal(for: frame(load: 1, temp: 50, watts: 20),
                                          baselinePL1: 100, baselinePL2: 125)
        check(full == Profile(pl1: 80, tier: 5, pl2: 80), "80 W ceiling and tier collapse")
        let bounded = ProfilePolicy.proposal(for: frame(load: 1, temp: 50, watts: 20),
                                             baselinePL1: 55, baselinePL2: 62)
        check(bounded?.pl1 == 55 && bounded?.pl2 == 62, "immutable session baseline caps proposals")
        check(ProfilePolicy.proposal(for: frame(load: 1, temp: 50, watts: 20),
                                     baselinePL1: 5, baselinePL2: 100) == nil,
              "baseline below minimum refuses a profile")
        check(ProfilePolicy.proposal(for: frame(load: 0.95, temp: 87, watts: 68))?.pl1 == 60,
              "temperature and package power reduce proposal")
        check(ProfilePolicy.fixedProfile(pl1: 80, tier: 5, baselinePL1: 75, baselinePL2: 125) == nil,
              "PL1 above immutable baseline is refused")
        check(ProfilePolicy.proposal(for: frame(load: 0.95, temp: 95, watts: 80,
                                                thermal: .critical)) == nil,
              "critical thermal state refuses a proposal")
        check(ProfilePolicy.proposal(for: frame(load: 0.5, temp: nil, watts: nil)) != nil,
              "observe-only proposal uses real CPU/thermal metrics without inventing power data")
        check(ProfilePolicy.proposal(for: frame(load: 0.5, temp: nil, watts: nil), requirePower: true) == nil,
              "control proposal requires real power and temperature sensors")

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
        var malformed = PowerMetricsParser()
        _ = malformed.consume("*** Sampled system activity\nIntel energy model derived package power (CPUs+GT+SA): 10W\n*** Sampled system activity\n")
        check(malformed.finish() == nil, "missing temperature is invalid")

        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let small = Profile(pl1: 10, tier: 1, pl2: 10)
        let large = Profile(pl1: 80, tier: 5, pl2: 80)
        var hysteresis = ProfileHysteresis()
        hysteresis.confirmApplied(small, at: t0)
        let firstStep = hysteresis.observe(large, now: t0.addingTimeInterval(1))
        check(firstStep?.pl1 == 20 && firstStep?.pl2 == 20,
              "upward response starts promptly with a bounded step")
        check(hysteresis.applied == small, "an unacknowledged candidate never changes applied state")
        check(hysteresis.observe(large, now: t0.addingTimeInterval(2)) == firstStep,
              "pending upward candidate is stable until acknowledged")
        hysteresis.confirmApplied(firstStep!, at: t0.addingTimeInterval(2))
        let secondStep = hysteresis.observe(large, now: t0.addingTimeInterval(3))
        check(secondStep?.pl1 == 30 && secondStep!.pl1 - firstStep!.pl1 <= 10 &&
              secondStep!.pl2 - firstStep!.pl2 <= 10,
              "successive upward steps are bounded to 10 W")
        check(hysteresis.applied == firstStep, "second candidate awaits its own acknowledgement")

        hysteresis.confirmApplied(large, at: t0.addingTimeInterval(3))
        for second in 4...8 {
            check(hysteresis.observe(small, now: t0.addingTimeInterval(Double(second))) == nil,
                  "routine downshift waits for five consistent samples and five seconds")
        }
        check(hysteresis.observe(small, now: t0.addingTimeInterval(9)) == small,
              "routine downshift becomes eligible after five seconds")
        check(hysteresis.applied == large, "downshift remains proposed until confirmed")

        var thermal = ProfileHysteresis()
        thermal.confirmApplied(large, at: t0)
        check(thermal.observe(small, now: t0.addingTimeInterval(1), thermalReduction: true) == nil,
              "thermal reduction takes two samples")
        check(thermal.observe(small, now: t0.addingTimeInterval(2), thermalReduction: true) == small,
              "thermal reduction bypasses the routine five-second dwell")
        check(thermal.applied == large, "thermal candidate also waits for confirmed readback")

        var lifecycle = ControllerLifecycle()
        lifecycle.begin(originalPL1: 100, originalPL2: 125)
        lifecycle.sensorSeen(at: t0)
        check(!lifecycle.shouldRelease(now: t0.addingTimeInterval(3), thermal: .nominal), "fresh sensors retain session")
        check(lifecycle.shouldRelease(now: t0.addingTimeInterval(5), thermal: .nominal), "stale sensors release session")
        check(lifecycle.shouldRelease(now: t0, thermal: .critical), "critical thermal releases immediately")
        lifecycle.restored()
        check(!lifecycle.isActive && lifecycle.applied == nil, "restore returns lifecycle to observe mode")

        let observationProposal = ProfilePolicy.proposal(for: frame(load: 1, temp: nil, watts: nil))
        var mock = MockProbe(originalPL1: 100, originalPL2: 125)
        check(observationProposal != nil && mock.setCount == 0 && mock.actual == nil,
              "observation proposes a profile without applying it or opening probe")
        mock.begin()
        if let proposal = full { _ = mock.set(proposal) }
        check(mock.actual == full && mock.setCount == 1,
              "injected control probe separates applied readback from proposal")
        mock.finish()
        check(!mock.active && mock.actual == nil && mock.originalPL1 == 100 && mock.originalPL2 == 125,
              "mock disconnect/finish restores saved baseline including values above the profile cap")

        var failedAck = ProfileHysteresis()
        failedAck.confirmApplied(small, at: t0)
        let failedCandidate = failedAck.observe(large, now: t0.addingTimeInterval(1))!
        var rejectingMock = MockProbe(originalPL1: 100, originalPL2: 125, rejectSet: true)
        rejectingMock.begin()
        check(!rejectingMock.set(failedCandidate) && failedAck.applied == small,
              "failed profile acknowledgement leaves applied state unchanged")
        lifecycle.begin(originalPL1: 100, originalPL2: 125)
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
