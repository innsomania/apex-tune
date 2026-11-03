import Foundation
import Darwin

enum ServiceState: String, Codable {
    case starting, controlling, restoring, restored, failed, stale
}

struct ServiceStatus: Codable {
    let updatedAt: Date
    let powerSampleAt: Date?
    let state: ServiceState
    let message: String
    let actualPL1: Double?
    let actualPL2: Double?
    let appliedPL1: Int?
    let appliedTier: Int?
    let appliedPL2: Int?
    let packageWatts: Double?
    let cpuTemperatureC: Double?

    init(updatedAt: Date = Date(), state: ServiceState, message: String,
         actualPL1: Double? = nil, actualPL2: Double? = nil,
         appliedPL1: Int? = nil, appliedTier: Int? = nil, appliedPL2: Int? = nil,
         packageWatts: Double? = nil, cpuTemperatureC: Double? = nil,
         powerSampleAt: Date? = nil) {
        self.updatedAt = updatedAt
        self.powerSampleAt = powerSampleAt
        self.state = state
        self.message = String(message.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }.prefix(120))
        self.actualPL1 = Self.valid(actualPL1)
        self.actualPL2 = Self.valid(actualPL2)
        self.appliedPL1 = appliedPL1
        self.appliedTier = appliedTier
        self.appliedPL2 = appliedPL2
        self.packageWatts = Self.valid(packageWatts)
        self.cpuTemperatureC = Self.valid(cpuTemperatureC)
    }

    private static func valid(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }
}

struct ServiceStatusStore {
    let url: URL

    static let installed = ServiceStatusStore(url: URL(fileURLWithPath:
        "/Library/Application Support/ApexTune/status.json"))

    func write(_ status: ServiceStatus) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(status)
        try data.write(to: url, options: .atomic)
        guard chmod(url.path, mode_t(0o644)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    func read(now: Date = Date(), maxAge: TimeInterval = 8) -> ServiceStatus? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let status = try? decoder.decode(ServiceStatus.self, from: data) else { return nil }
        guard now.timeIntervalSince(status.updatedAt) >= -1,
              now.timeIntervalSince(status.updatedAt) <= maxAge else {
            return ServiceStatus(updatedAt: status.updatedAt, state: .stale,
                                 message: "Power service status is stale")
        }
        if let sampleAt = status.powerSampleAt,
           now.timeIntervalSince(sampleAt) <= 4,
           now.timeIntervalSince(sampleAt) >= -1 { return status }
        return ServiceStatus(updatedAt: status.updatedAt, state: status.state,
                             message: status.message, actualPL1: status.actualPL1,
                             actualPL2: status.actualPL2, appliedPL1: status.appliedPL1,
                             appliedTier: status.appliedTier, appliedPL2: status.appliedPL2)
    }
}

final class ControllerInstanceLock {
    private var descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }

    static func acquire(path: String = "/var/run/apextune-controller.lock") -> ControllerInstanceLock? {
        let descriptor = open(path, O_CREAT | O_RDWR | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        return ControllerInstanceLock(descriptor: descriptor)
    }

    func release() {
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit { release() }
}

enum ApexTuneLaunchMode: Equatable {
    case observe, control, daemon, status, simulate

    static func parse(_ arguments: [String]) -> ApexTuneLaunchMode? {
        let modes: [(String, ApexTuneLaunchMode)] = [
            ("--control", .control), ("--daemon", .daemon),
            ("--status", .status), ("--simulate", .simulate)
        ]
        let selected = modes.filter { arguments.contains($0.0) }
        guard selected.count <= 1,
              arguments.allSatisfy({ argument in modes.contains(where: { $0.0 == argument }) }) else { return nil }
        return selected.first?.1 ?? .observe
    }
}
