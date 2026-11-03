import Foundation

struct SimulationReport {
    static func render() -> String {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func frame(_ load: Double, _ temp: Double?, _ watts: Double?, _ offset: TimeInterval = 0,
                   thermal: ThermalLevel = .nominal) -> SensorFrame {
            let power: PowerSample?
            if let temp, let watts {
                power = PowerSample(packageWatts: watts, cpuTemperatureC: temp,
                                    timestamp: now.addingTimeInterval(offset))
            } else { power = nil }
            return SensorFrame(cpuLoad: load, thermal: thermal, power: power, timestamp: now)
        }

        var rows = ["SIMULATION ONLY — no IOKit, powermetrics, driver, or MSR access."]
        let scenarios: [(String, SensorFrame, Int, Int)] = [
            ("idle", frame(0.04, 42, 9), 100, 125),
            ("load burst", frame(0.98, 72, 58), 100, 125),
            ("thermal cooldown", frame(0.92, 87, 68), 100, 125),
            ("stale sensors", frame(0.80, 70, 50, -10), 100, 125),
            ("baseline refusal", frame(0.99, 70, 50), 5, 70),
            ("critical thermal", frame(0.90, 95, 70, thermal: .critical), 100, 125)
        ]
        for (name, sensor, baselinePL1, baselinePL2) in scenarios {
            let decision = ProfilePolicy.proposal(for: sensor,
                                                 baselinePL1: baselinePL1,
                                                 baselinePL2: baselinePL2)
            if let decision {
                rows.append("\(name): proposed PL1 \(decision.pl1) W, tier \(decision.tier), PL2 \(decision.pl2) W")
            } else {
                rows.append("\(name): release / no safe profile")
            }
        }
        rows.append("Simulated applied profile is separate from proposal; actual hardware limits are not read.")
        return rows.joined(separator: "\n")
    }
}
