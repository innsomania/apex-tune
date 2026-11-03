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
    static let pl1Levels = Array(stride(from: 10, through: 80, by: 5))
    static let tierHeadroom = [0, 5, 10, 15, 20]
    static let maximumWatts = 80

    static func fixedProfile(pl1: Int, tier: Int, baselinePL1: Int,
                             baselinePL2: Int) -> Profile? {
        guard pl1Levels.contains(pl1), (1...5).contains(tier),
              pl1 <= min(maximumWatts, baselinePL1),
              baselinePL2 >= pl1 else { return nil }
        let pl2 = min(maximumWatts, baselinePL2, pl1 + tierHeadroom[tier - 1])
        return pl2 >= pl1 ? Profile(pl1: pl1, tier: tier, pl2: pl2) : nil
    }

    static func proposal(for frame: SensorFrame, baselinePL1: Int = 80,
                         baselinePL2: Int = 80, requirePower: Bool = false) -> Profile? {
        guard frame.cpuLoad.isFinite, frame.cpuLoad >= 0, frame.cpuLoad <= 1,
              frame.thermal != .critical,
              !requirePower || frame.thermal != .unknown,
              !requirePower || frame.power != nil else { return nil }

        let index = min(14, Int((frame.cpuLoad * 14).rounded(.down)))
        var desiredPL1 = pl1Levels[index]
        if frame.thermal == .serious { desiredPL1 -= 15 }
        else if frame.thermal == .fair { desiredPL1 -= 5 }
        if let power = frame.power {
            guard frame.timestamp.timeIntervalSince(power.timestamp) <= 4,
                  power.timestamp.timeIntervalSince(frame.timestamp) <= 1,
                  power.packageWatts.isFinite, power.packageWatts >= 0,
                  power.cpuTemperatureC.isFinite, power.cpuTemperatureC > 0 else { return nil }
            if power.cpuTemperatureC >= 90 { desiredPL1 -= 20 }
            else if power.cpuTemperatureC >= 85 { desiredPL1 -= 10 }
            else if power.cpuTemperatureC >= 80 { desiredPL1 -= 5 }
            if power.packageWatts >= 75 { desiredPL1 -= 10 }
            else if power.packageWatts >= 65 { desiredPL1 -= 5 }
        }
        desiredPL1 = max(10, desiredPL1)

        let ceiling = min(maximumWatts, baselinePL1, baselinePL2)
        guard let pl1 = pl1Levels.last(where: { $0 <= desiredPL1 && $0 <= ceiling }) else { return nil }
        let tier = min(5, max(1, Int((frame.cpuLoad * 5).rounded(.down)) + 1))
        let pl2 = min(maximumWatts, baselinePL2, pl1 + tierHeadroom[tier - 1])
        guard pl2 >= pl1 else { return nil }
        return Profile(pl1: pl1, tier: tier, pl2: pl2)
    }
}

struct ProfileHysteresis {
    private(set) var proposed: Profile?
    private(set) var applied: Profile?
    private var candidate: Profile?
    private var candidateCount = 0
    private var candidateStartedAt = Date.distantPast
    private var lastChange = Date.distantPast

    mutating func observe(_ next: Profile?, now: Date, thermalReduction: Bool = false) -> Profile? {
        proposed = next
        guard let next, let applied else { return nil }
        guard next != applied else {
            candidate = nil
            candidateCount = 0
            return nil
        }
        if candidate == next { candidateCount += 1 }
        else { candidate = next; candidateCount = 1; candidateStartedAt = now }
        let isReducing = next.pl1 < applied.pl1 || next.pl2 < applied.pl2
        if isReducing {
            let requiredSamples = thermalReduction ? 2 : 5
            let requiredSeconds: TimeInterval = thermalReduction ? 1 : 5
            guard candidateCount >= requiredSamples,
                  now.timeIntervalSince(candidateStartedAt) >= requiredSeconds else { return nil }
            return next
        }

        guard now.timeIntervalSince(lastChange) >= 1 else { return nil }
        let steppedPL1 = min(next.pl1, applied.pl1 + 10)
        var steppedTier = next.tier
        var stepped: Profile?
        while steppedTier >= 1 {
            if let attempt = ProfilePolicy.fixedProfile(pl1: steppedPL1, tier: steppedTier,
                                                         baselinePL1: 80, baselinePL2: 80),
               attempt.pl2 <= min(applied.pl2 + 10, next.pl2) {
                stepped = attempt
                break
            }
            steppedTier -= 1
        }
        guard let stepped, stepped != applied else { return nil }
        return stepped
    }

    mutating func confirmBaseline(pl1: Int, pl2: Int) {
        applied = Profile(pl1: pl1, tier: 1, pl2: pl2)
        lastChange = Date.distantPast
        candidate = nil
        candidateCount = 0
        candidateStartedAt = .distantPast
    }

    mutating func confirmApplied(_ profile: Profile, at time: Date = Date()) {
        applied = profile
        lastChange = time
        candidate = nil
        candidateCount = 0
        candidateStartedAt = .distantPast
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
            pattern: #"(?m)^CPU(?: die)? temperature:\s*([0-9]+(?:\.[0-9]+)?)\s*(?:°?C)\b"#) else { return nil }
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
    private(set) var lastSensorTime: Date?

    mutating func begin(originalPL1: Int, originalPL2: Int) {
        isActive = true
        applied = nil
        _ = (originalPL1, originalPL2)
    }

    mutating func applyConfirmed(_ profile: Profile) { applied = profile }
    mutating func sensorSeen(at time: Date) { lastSensorTime = time }

    mutating func shouldRelease(now: Date, thermal: ThermalLevel) -> Bool {
        guard isActive else { return false }
        if thermal == .critical { return true }
        guard let lastSensorTime else { return true }
        return now.timeIntervalSince(lastSensorTime) > 4
    }

    mutating func restored() {
        isActive = false
        applied = nil
        lastSensorTime = nil
    }
}
