import Foundation
import AppKit

enum ControlRuntime {
    static let powerMetricsArguments = [
        "--samplers", "cpu_power,gpu_power,smc", "-i", "1000", "-b", "1"
    ]

    static func scheduleControlTimer(on runLoop: RunLoop = .main,
                                     interval: TimeInterval,
                                     handler: @escaping @Sendable (Timer) -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true, block: handler)
        runLoop.add(timer, forMode: .common)
        runLoop.add(timer, forMode: .eventTracking)
        return timer
    }
}

struct Profile: Equatable {
    let pl1: Int
    let tier: Int
    let pl2: Int

    var pl1Watts: Double { Double(pl1) / 2 }
    var pl2Watts: Double { Double(pl2) / 2 }
    var pl1Text: String { "\(pl1 / 2).\(pl1.isMultiple(of: 2) ? "0" : "5")" }
    var pl2Text: String { "\(pl2 / 2).\(pl2.isMultiple(of: 2) ? "0" : "5")" }
}

enum ThermalLevel: String {
    case nominal, fair, serious, critical, unknown
}

struct PowerSample: Equatable {
    let packageWatts: Double
    let cpuTemperatureC: Double
    let timestamp: Date
}

struct SensorFrame: Equatable {
    let cpuLoad: Double
    let thermal: ThermalLevel
    let power: PowerSample?
    let timestamp: Date
}

struct ProfilePolicy {
    static let pl1Levels = Array(stride(from: 20, through: 160, by: 1))
    static let tierHeadroomHalfWatts = [0, 10, 20, 30, 40]
    static let maximumHalfWatts = 160

    static func fixedProfile(pl1: Int, tier: Int, baselinePL1: Int,
                             baselinePL2: Int) -> Profile? {
        guard pl1Levels.contains(pl1), (1...5).contains(tier),
              pl1 <= min(maximumHalfWatts, baselinePL1),
              baselinePL2 >= pl1 else { return nil }
        let pl2 = min(maximumHalfWatts, baselinePL2, pl1 + tierHeadroomHalfWatts[tier - 1])
        return pl2 >= pl1 ? Profile(pl1: pl1, tier: tier, pl2: pl2) : nil
    }

    static func proposal(for frame: SensorFrame, baselinePL1: Int = 160,
                         baselinePL2: Int = 160, requirePower: Bool = false) -> Profile? {
        guard frame.cpuLoad.isFinite, frame.cpuLoad >= 0, frame.cpuLoad <= 1,
              frame.thermal != .critical,
              !requirePower || frame.thermal != .unknown,
              !requirePower || frame.power != nil else { return nil }

        let index = min(pl1Levels.count - 1,
                        Int((frame.cpuLoad * Double(pl1Levels.count - 1)).rounded(.down)))
        var desiredPL1 = pl1Levels[index]
        var forceBaseTier = frame.thermal == .serious
        if frame.thermal == .serious { desiredPL1 -= 30 }
        else if frame.thermal == .fair { desiredPL1 -= 10 }
        if let power = frame.power {
            guard frame.timestamp.timeIntervalSince(power.timestamp) <= 4,
                  power.timestamp.timeIntervalSince(frame.timestamp) <= 1,
                  power.packageWatts.isFinite, power.packageWatts >= 0,
                  power.cpuTemperatureC.isFinite, power.cpuTemperatureC > 0 else { return nil }
            if power.cpuTemperatureC >= 80 {
                desiredPL1 = 20
                forceBaseTier = true
            } else if power.cpuTemperatureC >= 75 {
                desiredPL1 = min(desiredPL1, 50)
                forceBaseTier = true
            } else if power.cpuTemperatureC >= 70 { desiredPL1 -= 10 }
            if power.packageWatts >= 75 { desiredPL1 -= 20 }
            else if power.packageWatts >= 65 { desiredPL1 -= 10 }
        }
        if frame.thermal == .serious { desiredPL1 = min(desiredPL1, 50) }
        desiredPL1 = max(20, desiredPL1)

        let ceiling = min(maximumHalfWatts, baselinePL1, baselinePL2)
        guard let pl1 = pl1Levels.last(where: { $0 <= desiredPL1 && $0 <= ceiling }) else { return nil }
        let tier = forceBaseTier ? 1 : min(5, max(1, Int((frame.cpuLoad * 5).rounded(.down)) + 1))
        let pl2 = min(maximumHalfWatts, baselinePL2, pl1 + tierHeadroomHalfWatts[tier - 1])
        guard pl2 >= pl1 else { return nil }
        return Profile(pl1: pl1, tier: tier, pl2: pl2)
    }
}

struct ProfileHysteresis {
    private(set) var proposed: Profile?
    private(set) var applied: Profile?
    private var lastChange = Date.distantPast

    mutating func observe(_ next: Profile?, now: Date,
                          immediateReduction: Bool = false) -> Profile? {
        proposed = next
        guard let next, let applied else { return nil }
        guard next != applied else { return nil }
        guard immediateReduction || now.timeIntervalSince(lastChange) >= 3 else { return nil }
        let pl1 = immediateReduction
            ? min(next.pl1, applied.pl1)
            : min(max(next.pl1, applied.pl1 - 1), applied.pl1 + 1)
        let pl2 = immediateReduction
            ? min(next.pl2, applied.pl2)
            : min(max(next.pl2, applied.pl2 - 1), applied.pl2 + 1)
        let boundedPL2 = max(pl1, pl2)
        let requiredTier = ProfilePolicy.tierHeadroomHalfWatts.firstIndex {
            boundedPL2 <= pl1 + $0
        }.map { $0 + 1 } ?? ProfilePolicy.tierHeadroomHalfWatts.count
        let bounded = Profile(pl1: pl1, tier: requiredTier, pl2: boundedPL2)
        return bounded == applied ? nil : bounded
    }

    mutating func confirmBaseline(pl1: Int, pl2: Int) {
        applied = Profile(pl1: pl1, tier: 1, pl2: pl2)
        lastChange = Date.distantPast
    }

    mutating func confirmApplied(_ profile: Profile, at time: Date = Date()) {
        applied = profile
        lastChange = time
    }
}

struct TurboBurstDecision: Equatable {
    let profile: Profile
    let closeImmediately: Bool
}

struct TurboBurstBudget {
    private(set) var burstStartedAt: Date?
    private(set) var cooldownUntil = Date.distantPast
    private(set) var burstCount = 0
    private var active = false

    mutating func constrain(_ requested: Profile, cpuTemperatureC: Double?,
                            thermal: ThermalLevel, now: Date) -> TurboBurstDecision {
        let canBurst = requested.tier > 1 && requested.pl2 > requested.pl1 && thermal != .serious &&
            cpuTemperatureC.map { $0.isFinite && $0 < 75 } == true
        guard canBurst else {
            let closed = active
            endBurst(at: now)
            return TurboBurstDecision(profile: baseProfile(requested), closeImmediately: closed)
        }

        if let burstStartedAt {
            guard now.timeIntervalSince(burstStartedAt) < 2 else {
                endBurst(at: burstStartedAt.addingTimeInterval(2))
                return TurboBurstDecision(profile: baseProfile(requested), closeImmediately: true)
            }
            return TurboBurstDecision(profile: burstProfile(requested), closeImmediately: false)
        }

        guard now >= cooldownUntil else {
            return TurboBurstDecision(profile: baseProfile(requested), closeImmediately: false)
        }
        return TurboBurstDecision(profile: burstProfile(requested), closeImmediately: false)
    }

    mutating func confirmApplied(_ profile: Profile, at time: Date) {
        guard profile.tier == 2, profile.pl2 > profile.pl1,
              !active, time >= cooldownUntil else { return }
        burstStartedAt = time
        active = true
        burstCount += 1
    }

    private func baseProfile(_ requested: Profile) -> Profile {
        Profile(pl1: requested.pl1, tier: 1, pl2: requested.pl1)
    }

    private func burstProfile(_ requested: Profile) -> Profile {
        let pl2 = min(requested.pl2, requested.pl1 + 10)
        return Profile(pl1: requested.pl1, tier: pl2 > requested.pl1 ? 2 : 1, pl2: pl2)
    }

    private mutating func endBurst(at time: Date) {
        if active { cooldownUntil = time.addingTimeInterval(30) }
        active = false
        burstStartedAt = nil
    }
}

struct PowerMetricsParser {
    private var pending = ""
    private var block = ""
    private let start = "Sampled system activity"

    mutating func consume(_ text: String, now: Date = Date()) -> [PowerSample?] {
        pending += text
        var output: [PowerSample?] = []
        while let newline = pending.firstIndex(of: "\n") {
            let line = String(pending[..<newline])
            pending.removeSubrange(...newline)
            if line.contains(start) {
                if !block.isEmpty { output.append(parse(block, now: now)) }
                block = line + "\n"
            } else if !block.isEmpty {
                block += line + "\n"
            }
        }
        return output
    }

    mutating func finish(now: Date = Date()) -> PowerSample? {
        defer { block = "" }
        return block.isEmpty ? nil : parse(block, now: now)
    }

    private func parse(_ block: String, now: Date) -> PowerSample? {
        guard let watts = firstNumber(in: block,
            pattern: #"(?m)^Intel energy model derived package power \(CPUs\+GT\+SA\):\s*([0-9]+(?:\.[0-9]+)?)\s*W\b"#),
              let temperature = firstNumber(in: block,
            pattern: #"(?m)^CPU die temperature:\s*([0-9]+(?:\.[0-9]+)?)\s*(?:°?C)\b"#) else { return nil }
        return PowerSample(packageWatts: watts, cpuTemperatureC: temperature, timestamp: now)
    }

    private func firstNumber(in text: String, pattern: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Double(text[range])
    }
}

struct ControllerLifecycle {
    private(set) var isActive = false
    private(set) var applied: Profile?

    mutating func begin(originalPL1: Int, originalPL2: Int) {
        isActive = true
        applied = nil
        _ = (originalPL1, originalPL2)
    }

    mutating func applyConfirmed(_ profile: Profile) { applied = profile }

    mutating func restored() {
        isActive = false
        applied = nil
    }
}

struct SensorFallbackRecovery {
    static let safeProfile = Profile(pl1: 20, tier: 1, pl2: 20)
    private(set) var isDegraded = true
    private(set) var consecutiveFreshSamples = 0
    private var lastCountedSample: Date?
    private var recoveryStartedAt: Date?

    @discardableResult
    mutating func observe(isSafe: Bool, sampleAt: Date?, requiredSamples: Int = 5,
                          requiredDuration: TimeInterval = 10) -> Bool {
        guard isSafe, let sampleAt else {
            isDegraded = true
            consecutiveFreshSamples = 0
            lastCountedSample = nil
            recoveryStartedAt = nil
            return false
        }
        guard isDegraded else { return true }
        guard lastCountedSample != sampleAt else { return false }
        if recoveryStartedAt == nil { recoveryStartedAt = sampleAt }
        lastCountedSample = sampleAt
        consecutiveFreshSamples += 1
        if consecutiveFreshSamples >= requiredSamples,
           sampleAt.timeIntervalSince(recoveryStartedAt ?? sampleAt) >= requiredDuration {
            isDegraded = false
            consecutiveFreshSamples = 0
            lastCountedSample = nil
            recoveryStartedAt = nil
            return true
        }
        return false
    }

    static func sampleIsFresh(_ sampleAt: Date, now: Date, maximumAge: TimeInterval = 4) -> Bool {
        let age = now.timeIntervalSince(sampleAt)
        return age >= -1 && age <= maximumAge
    }

    static func sensorsAreSafe(cpuFresh: Bool, powerFresh: Bool,
                               thermal: ThermalLevel, cpuTemperatureC: Double?) -> Bool {
        cpuFresh && powerFresh && thermal != .critical && thermal != .unknown &&
            cpuTemperatureC.map { $0.isFinite && $0 > 0 && $0 < 75 } == true
    }

    static func heartbeatIsDue(lastSentAt: Date, now: Date, interval: TimeInterval = 10) -> Bool {
        now.timeIntervalSince(lastSentAt) >= interval
    }
}
