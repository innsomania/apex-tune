import AppKit
import Darwin
import Dispatch
import Foundation

final class CPUUsageSampler {
    private var previous: [UInt32]?

    func sample() -> Double? {
        var cpuCount: natural_t = 0
        var infoCount: mach_msg_type_number_t = 0
        var info: processor_info_array_t?
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                         &cpuCount, &info, &infoCount)
        guard result == KERN_SUCCESS, let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size))
        }
        let ticks = UnsafeMutablePointer<natural_t>(OpaquePointer(info))
        var current: [UInt32] = []
        current.reserveCapacity(Int(cpuCount) * Int(CPU_STATE_MAX))
        for index in 0..<(Int(cpuCount) * Int(CPU_STATE_MAX)) {
            current.append(ticks[index])
        }
        defer { previous = current }
        guard let old = previous, old.count == current.count else { return nil }
        var busy: UInt64 = 0
        var total: UInt64 = 0
        for cpu in 0..<Int(cpuCount) {
            let base = cpu * Int(CPU_STATE_MAX)
            let user = UInt64(current[base + Int(CPU_STATE_USER)] &- old[base + Int(CPU_STATE_USER)])
            let system = UInt64(current[base + Int(CPU_STATE_SYSTEM)] &- old[base + Int(CPU_STATE_SYSTEM)])
            let idle = UInt64(current[base + Int(CPU_STATE_IDLE)] &- old[base + Int(CPU_STATE_IDLE)])
            let nice = UInt64(current[base + Int(CPU_STATE_NICE)] &- old[base + Int(CPU_STATE_NICE)])
            busy += user + system + nice
            total += user + system + idle + nice
        }
        guard total > 0 else { return nil }
        return min(1, Double(busy) / Double(total))
    }
}

final class ProbeClient: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var pending = Data()
    var onEvent: (([String: Any]) -> Void)?
    var onExit: (() -> Void)?

    func start() throws {
        guard let executable = Bundle.main.resourceURL?.appendingPathComponent("apextune-power-probe") else {
            throw NSError(domain: "ApexTune", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Bundled power probe is missing."])
        }
        process.executableURL = executable
        process.arguments = ["controller", "--machine"]
        process.standardInput = input
        process.standardOutput = output
        let errors = Pipe()
        process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            guard !bytes.isEmpty else { return }
            DispatchQueue.main.async { self?.consume(bytes) }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            let bytes = handle.availableData
            if !bytes.isEmpty, let text = String(data: bytes, encoding: .utf8) {
                fputs("ApexTune power probe: \(text)", stderr)
            }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.output.fileHandleForReading.readabilityHandler = nil
                self?.onExit?()
            }
        }
        try process.run()
    }

    func send(_ line: String) {
        guard process.isRunning, let data = (line + "\n").data(using: .utf8) else { return }
        do { try input.fileHandleForWriting.write(contentsOf: data) }
        catch { onEvent?(["event": "transport_error", "message": error.localizedDescription]) }
    }

    func stopTransport() {
        output.fileHandleForReading.readabilityHandler = nil
        input.fileHandleForWriting.closeFile()
        if process.isRunning { process.terminate() }
    }

    private func consume(_ data: Data) {
        pending.append(data)
        while let newline = pending.firstRange(of: Data([10])) {
            let line = pending[..<newline.lowerBound]
            pending.removeSubrange(...newline.lowerBound)
            guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            onEvent?(event)
        }
    }
}

final class PowerMetricsMonitor: @unchecked Sendable {
    private let process = Process()
    private let output = Pipe()
    private var parser = PowerMetricsParser()
    var onSample: ((PowerSample?) -> Void)?
    var onExit: (() -> Void)?

    func start() throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/powermetrics")
        process.arguments = ControlRuntime.powerMetricsArguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async { self?.consume(data) }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.output.fileHandleForReading.readabilityHandler = nil
                self.onSample?(self.parser.finish())
                self.onExit?()
            }
        }
        try process.run()
    }

    func stop() {
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }

    private func consume(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        for sample in parser.consume(text) { onSample?(sample) }
    }
}

@MainActor
final class ApexTuneApp: NSObject, NSApplicationDelegate {
    private lazy var statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let cpuItem = NSMenuItem(title: "CPU: measuring…", action: nil, keyEquivalent: "")
    private let thermalItem = NSMenuItem(title: "Thermal: unknown", action: nil, keyEquivalent: "")
    private let proposedItem = NSMenuItem(title: "Proposed profile: unavailable", action: nil, keyEquivalent: "")
    private let actualItem = NSMenuItem(title: "Actual limits: not read (observe only)", action: nil, keyEquivalent: "")
    private let packageItem = NSMenuItem(title: "Package watts: control mode only", action: nil, keyEquivalent: "")
    private let temperatureItem = NSMenuItem(title: "CPU die temperature: unavailable", action: nil, keyEquivalent: "")
    private let modeItem = NSMenuItem(title: "Mode: observe only", action: nil, keyEquivalent: "")
    private let undervoltItem = NSMenuItem(title: "Undervolt lock: unknown / unsupported", action: nil, keyEquivalent: "")
    private let cpuSampler = CPUUsageSampler()
    private var powerMonitor: PowerMetricsMonitor?
    private var probe: ProbeClient?
    private var timer: Timer?
    private var frame: SensorFrame?
    private var actualPL1: Double?
    private var actualPL2: Double?
    private var originalPL1 = 0
    private var originalPL2 = 0
    private var controller = ControllerLifecycle()
    private var hysteresis = ProfileHysteresis()
    private var turboBurstBudget = TurboBurstBudget()
    private var controlRequested = false
    private var controlStartedAt = Date()
    private var cpuLastSampleAt = Date.distantPast
    private var lastHeartbeat = Date.distantPast
    private var heartbeatSentAt: Date?
    private var pendingProfileAt: Date?
    private var releaseStarted = false
    private var quitAfterRelease = false
    private var lastLoggedPowerSampleAt = Date.distantPast
    private let headless: Bool
    private let statusOnly: Bool
    private let statusStore: ServiceStatusStore
    private let instanceLock: ControllerInstanceLock?
    private var signalSource: DispatchSourceSignal?
    private var currentServiceState: ServiceState = .starting
    private var serviceMessage = "Starting power controller"
    private var latestProposal: Profile?
    private var latestPowerSample: PowerSample?
    private var statusWriteFailed = false

    init(control: Bool, headless: Bool = false, statusOnly: Bool = false,
         statusStore: ServiceStatusStore = .installed,
         instanceLock: ControllerInstanceLock? = nil) {
        controlRequested = control
        self.headless = headless
        self.statusOnly = statusOnly
        self.statusStore = statusStore
        self.instanceLock = instanceLock
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureMenu()
        if controlRequested { startControl() }
        timer = ControlRuntime.scheduleControlTimer(interval: 1) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
    }

    private func configureMenu() {
        let menu = NSMenu()
        let items = statusOnly
            ? [modeItem, proposedItem, actualItem, packageItem, temperatureItem]
            : [modeItem, cpuItem, thermalItem, proposedItem, actualItem, packageItem,
               temperatureItem, undervoltItem]
        items.forEach { $0.isEnabled = false; menu.addItem($0) }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit ApexTune", action: #selector(quit), keyEquivalent: "q"))
        menu.items.last?.target = self
        statusItem.menu = menu
        statusItem.button?.title = ""
        statusItem.button?.image = NSImage(systemSymbolName: "bolt.circle", accessibilityDescription: "ApexTune")
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.toolTip = "ApexTune"
    }

    func startHeadless() {
        guard headless else { return }
        statusStoreWrite(state: .starting, message: "Starting automatic power control")
        guard !statusWriteFailed else {
            stopHeadlessRunLoop()
            return
        }
        installTerminationHandler()
        startControl()
        timer = ControlRuntime.scheduleControlTimer(interval: 1) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
    }

    var daemonExitCode: Int32 { currentServiceState == .restored ? 0 : 1 }

    private func installTerminationHandler() {
        Darwin.signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.shutdownHeadless() }
        }
        source.resume()
        signalSource = source
    }

    private func shutdownHeadless() {
        guard headless else { return }
        quitAfterRelease = true
        if controlRequested { releaseControl(reason: "launchd requested stop") }
        else { stopHeadlessRunLoop() }
    }

    private func stopHeadlessRunLoop() {
        guard headless else { return }
        timer?.invalidate()
        timer = nil
        signalSource?.cancel()
        signalSource = nil
        instanceLock?.release()
        CFRunLoopStop(CFRunLoopGetMain())
    }

    @objc private func quit() {
        guard controlRequested else { NSApp.terminate(nil); return }
        quitAfterRelease = true
        if !releaseStarted { releaseControl(reason: "User quit") }
    }

    private func startControl() {
        guard getuid() == 0 else {
            controlRequested = false
            currentServiceState = .failed
            serviceMessage = "Power control requires root"
            modeItem.title = "Mode: failed · control requires root"
            return
        }
        currentServiceState = .starting
        serviceMessage = "Waiting for power and temperature sensors"
        modeItem.title = "Mode: control pending sensors"
        controlStartedAt = Date()
        let child = ProbeClient()
        child.onEvent = { [weak self] in self?.handleProbeEvent($0) }
        child.onExit = { [weak self] in self?.handleProbeExit() }
        probe = child
        do { try child.start() }
        catch { releaseControl(reason: error.localizedDescription); return }

        let monitor = PowerMetricsMonitor()
        monitor.onSample = { [weak self] sample in
            guard let self else { return }
            guard let sample else {
                self.latestPowerSample = nil
                self.frame = SensorFrame(cpuLoad: self.frame?.cpuLoad ?? 0,
                                         thermal: self.thermalLevel, power: nil, timestamp: Date())
                self.packageItem.title = "Package power: unavailable"
                self.temperatureItem.title = "CPU die temperature: unavailable"
                return
            }
            self.frame = SensorFrame(cpuLoad: self.frame?.cpuLoad ?? 0,
                                     thermal: self.thermalLevel,
                                     power: sample, timestamp: Date())
            self.packageItem.title = String(format: "Package power: %.1f W", sample.packageWatts)
            self.latestPowerSample = sample
            self.temperatureItem.title = String(format: "CPU die temperature: %.1f °C", sample.cpuTemperatureC)
            let now = Date()
            if self.controlRequested && now.timeIntervalSince(self.lastLoggedPowerSampleAt) >= 10 {
                self.lastLoggedPowerSampleAt = now
                self.logControl(String(format: "sensor package=%.1fW cpu=%.1fC", sample.packageWatts,
                                        sample.cpuTemperatureC))
            }
        }
        monitor.onExit = { [weak self] in
            guard let self, self.controlRequested, !self.releaseStarted else { return }
            self.releaseControl(reason: "powermetrics stopped")
        }
        powerMonitor = monitor
        do { try monitor.start() }
        catch { releaseControl(reason: "powermetrics failed to start: \(error.localizedDescription)") }
    }

    private var thermalLevel: ThermalLevel {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .unknown
        }
    }

    private func tick() {
        defer { if headless { publishStatus() } }
        let now = Date()
        if statusOnly {
            refreshDaemonStatus()
            return
        }
        if controlRequested, !releaseStarted {
            if probe == nil || (!controller.isActive && now.timeIntervalSince(controlStartedAt) > 5) {
                releaseControl(reason: "Control session did not become ready")
            }
            if let pendingProfileAt, now.timeIntervalSince(pendingProfileAt) > 4 {
                releaseControl(reason: "Profile acknowledgement timed out")
            }
            if let heartbeatSentAt, now.timeIntervalSince(heartbeatSentAt) > 4 {
                releaseControl(reason: "Kernel lease heartbeat timed out")
            }
            if now.timeIntervalSince(cpuLastSampleAt) > 4,
               now.timeIntervalSince(controlStartedAt) > 5 {
                releaseControl(reason: "CPU load sensor is stale")
            }
        }
        if let load = cpuSampler.sample() {
            cpuLastSampleAt = now
            let oldPower = frame?.power
            frame = SensorFrame(cpuLoad: load, thermal: thermalLevel, power: oldPower, timestamp: now)
            cpuItem.title = String(format: "CPU load: %.0f%%", load * 100)
        }
        thermalItem.title = "Thermal: \(thermalLevel.rawValue)"
        if now.timeIntervalSince(cpuLastSampleAt) > 4 {
            cpuItem.title = "CPU load: unavailable (stale)"
            if !controlRequested { proposedItem.title = "Proposed profile: unavailable (CPU load stale)" }
        }
        if let latestPowerSample,
           now.timeIntervalSince(latestPowerSample.timestamp) > 4 {
            packageItem.title = "Package power: unavailable (stale)"
            temperatureItem.title = "CPU die temperature: unavailable (stale)"
        }
        if let frame {
            if let proposal = ProfilePolicy.proposal(for: frame,
                                                      baselinePL1: controlRequested ? originalPL1 : 80,
                                                      baselinePL2: controlRequested ? originalPL2 : 80,
                                                      requirePower: controlRequested) {
                latestProposal = proposal
                proposedItem.title = "Proposed: PL1 \(proposal.pl1) W · tier \(proposal.tier) · PL2 \(proposal.pl2) W"
                if controlRequested, !releaseStarted {
                    guard let power = frame.power, now.timeIntervalSince(power.timestamp) <= 4 else {
                        if now.timeIntervalSince(controlStartedAt) > 5 { releaseControl(reason: "Power or temperature sensor is stale") }
                        return
                    }
                    controller.sensorSeen(at: power.timestamp)
                    if controller.shouldRelease(now: now, thermal: thermalLevel) {
                        releaseControl(reason: thermalLevel == .critical ? "Critical thermal state" : "Sensors became stale")
                        return
                    }
                    let thermalReduction = thermalLevel == .serious || power.cpuTemperatureC >= 75 ||
                        power.packageWatts >= 75
                    let turboDecision = turboBurstBudget.constrain(proposal,
                        cpuTemperatureC: power.cpuTemperatureC, thermal: thermalLevel, now: now)
                    latestProposal = turboDecision.profile
                    if let change = hysteresis.observe(turboDecision.profile, now: now,
                                                       thermalReduction: thermalReduction,
                                                       immediateReduction: power.cpuTemperatureC >= 80 ||
                                                           turboDecision.closeImmediately),
                       !releaseStarted, pendingProfileAt == nil {
                        probe?.send("set \(change.pl1) \(change.tier)")
                        pendingProfileAt = now
                    }
                    if now.timeIntervalSince(lastHeartbeat) >= 10 {
                        probe?.send("heartbeat")
                        lastHeartbeat = now
                        heartbeatSentAt = now
                    }
                }
            } else {
                latestProposal = nil
                proposedItem.title = "Proposed profile: unavailable (sensor/baseline)"
                if controlRequested && !releaseStarted && now.timeIntervalSince(controlStartedAt) > 5 {
                    releaseControl(reason: "Required sensors or safe baseline unavailable")
                }
            }
        }
        if controlRequested, !releaseStarted, thermalLevel == .critical {
            releaseControl(reason: "Critical thermal state")
        }
    }

    private func handleProbeEvent(_ event: [String: Any]) {
        guard let name = event["event"] as? String else { return }
        if name == "error" || name == "transport_error" {
            releaseControl(reason: event["message"] as? String ?? "Probe communication failed")
            return
        }
        guard let actual1 = event["actual_pl1_watts"] as? Double,
              let actual2 = event["actual_pl2_watts"] as? Double else { return }
        actualPL1 = actual1
        actualPL2 = actual2
        actualItem.title = String(format: "Actual limits: PL1 %.1f W · PL2 %.1f W", actual1, actual2)
        if name == "ready" {
            originalPL1 = Int((event["original_pl1_watts"] as? Double ?? 0).rounded(.down))
            originalPL2 = Int((event["original_pl2_watts"] as? Double ?? 0).rounded(.down))
            guard originalPL1 > 0, originalPL2 >= 10 else {
                releaseControl(reason: "Probe returned an invalid baseline")
                return
            }
            controller.begin(originalPL1: originalPL1, originalPL2: originalPL2)
            hysteresis.confirmBaseline(pl1: originalPL1, pl2: originalPL2)
            currentServiceState = .controlling
            serviceMessage = "Automatic power control active"
            modeItem.title = "Mode: automatic control (sensor-gated)"
            logControl(String(format: "session ready; baseline PL1=%.1fW PL2=%.1fW", actual1, actual2))
            lastHeartbeat = Date()
            heartbeatSentAt = nil
        } else if name == "applied", let pl1 = event["pl1_watts"] as? Int,
                  let tier = event["tier"] as? Int, let pl2 = event["pl2_watts"] as? Int {
            let profile = Profile(pl1: pl1, tier: tier, pl2: pl2)
            controller.applyConfirmed(profile)
            hysteresis.confirmApplied(profile)
            turboBurstBudget.confirmApplied(profile, at: Date())
            pendingProfileAt = nil
            currentServiceState = .controlling
            serviceMessage = "Automatic power control active"
            logControl("profile confirmed PL1=\(pl1)W tier=\(tier) PL2=\(pl2)W")
        } else if name == "heartbeat" {
            heartbeatSentAt = nil
            logControl("kernel lease heartbeat confirmed")
        } else if name == "restored" {
            controller.restored()
            currentServiceState = .restored
            serviceMessage = "Saved power limits restored"
            actualItem.title = String(format: "Actual limits restored: PL1 %.1f W · PL2 %.1f W", actual1, actual2)
            logControl(String(format: "baseline restored PL1=%.1fW PL2=%.1fW", actual1, actual2))
            finishControl(reason: "Restored Apple's saved package limits")
        } else if name == "restore_failed" {
            currentServiceState = .failed
            serviceMessage = "Could not confirm saved limits restored"
            actualItem.title = "Restore failed; check probe output and current limits"
            finishControl(reason: "Restore failed; check the probe error output")
        }
    }

    private func handleProbeExit() {
        guard controlRequested, !releaseStarted else { return }
        currentServiceState = .failed
        serviceMessage = "Power controller connection closed unexpectedly"
        finishControl(reason: "Probe connection closed; kernel cleanup requested")
    }

    private func releaseControl(reason: String) {
        guard controlRequested, !releaseStarted else { return }
        releaseStarted = true
        currentServiceState = .restoring
        serviceMessage = reason
        logControl("releasing control: \(reason)")
        modeItem.title = "Mode: restoring · \(reason)"
        probe?.send("finish")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.controlRequested, self.releaseStarted else { return }
            self.probe?.stopTransport()
            self.finishControl(reason: reason + " (connection closed for kernel cleanup)")
        }
    }

    private func logControl(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[ApexTune \(timestamp)] \(message)\n"
        if let data = line.data(using: .utf8) {
            try? FileHandle.standardError.write(contentsOf: data)
        }
    }

    private func finishControl(reason: String) {
        powerMonitor?.stop()
        powerMonitor = nil
        probe?.stopTransport()
        probe = nil
        controller.restored()
        controlRequested = false
        if currentServiceState == .restoring {
            currentServiceState = .failed
            serviceMessage = "Restore acknowledgement not received"
        }
        modeItem.title = "Mode: observe only · \(reason)"
        packageItem.title = "Package power: unavailable"
        temperatureItem.title = "CPU die temperature: unavailable"
        if !headless { statusItem.button?.toolTip = "ApexTune · Observe" }
        if headless {
            statusStoreWrite(state: currentServiceState, message: serviceMessage)
            stopHeadlessRunLoop()
        }
        if quitAfterRelease {
            if headless { stopHeadlessRunLoop() }
            else { NSApp.terminate(nil) }
        }
    }

    private func publishStatus() {
        statusStoreWrite(state: currentServiceState, message: serviceMessage)
    }

    private func statusStoreWrite(state: ServiceState, message: String) {
        guard headless else { return }
        let status = ServiceStatus(
            state: state, message: message,
            actualPL1: actualPL1, actualPL2: actualPL2,
            appliedPL1: controller.applied?.pl1,
            appliedTier: controller.applied?.tier,
            appliedPL2: controller.applied?.pl2,
            packageWatts: latestPowerSample?.packageWatts,
            cpuTemperatureC: latestPowerSample?.cpuTemperatureC,
            powerSampleAt: latestPowerSample?.timestamp)
        do { try statusStore.write(status) }
        catch {
            guard !statusWriteFailed else { return }
            statusWriteFailed = true
            logControl("status file write failed: \(error.localizedDescription)")
            if controlRequested && !releaseStarted {
                releaseControl(reason: "Could not publish safe controller status")
            }
        }
    }

    private func refreshDaemonStatus() {
        guard let status = statusStore.read() else {
            modeItem.title = "Power service: unavailable"
            actualItem.title = "Actual limits: unavailable"
            proposedItem.title = "Confirmed profile: unavailable"
            packageItem.title = "Package power: unavailable"
            temperatureItem.title = "CPU die temperature: unavailable"
            statusItem.button?.toolTip = "ApexTune · Power service unavailable"
            return
        }
        modeItem.title = "Power service: \(status.state.rawValue) · \(status.message)"
        if let pl1 = status.actualPL1, let pl2 = status.actualPL2 {
            actualItem.title = String(format: "Actual limits: PL1 %.1f W · PL2 %.1f W", pl1, pl2)
        } else { actualItem.title = "Actual limits: unavailable" }
        if let pl1 = status.appliedPL1, let tier = status.appliedTier, let pl2 = status.appliedPL2 {
            proposedItem.title = "Confirmed profile: PL1 \(pl1) W · tier \(tier) · PL2 \(pl2) W"
        } else { proposedItem.title = "Confirmed profile: unavailable" }
        if let watts = status.packageWatts {
            packageItem.title = String(format: "Package power: %.1f W", watts)
        } else { packageItem.title = "Package power: unavailable (stale or missing)" }
        if let temperature = status.cpuTemperatureC {
            temperatureItem.title = String(format: "CPU die temperature: %.1f °C", temperature)
        } else { temperatureItem.title = "CPU die temperature: unavailable (stale or missing)" }
        statusItem.button?.toolTip = "ApexTune · \(status.state.rawValue)"
    }
}

@main
enum ApexTuneMain {
    @MainActor
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let mode = ApexTuneLaunchMode.parse(arguments) else {
            fputs("ApexTune: invalid or conflicting launch options\n", stderr)
            exit(64)
        }
        if mode == .simulate {
            print(SimulationReport.render())
            return
        }
        var controlLock: ControllerInstanceLock?
        if mode == .daemon || mode == .control {
            guard getuid() == 0 else {
                fputs("ApexTune: \(mode == .daemon ? "--daemon" : "--control") requires root\n", stderr)
                exit(77)
            }
            guard let lock = ControllerInstanceLock.acquire() else {
                fputs("ApexTune: another power controller holds the system lock\n", stderr)
                exit(75)
            }
            if mode == .daemon {
                let daemon = ApexTuneApp(control: true, headless: true, instanceLock: lock)
                daemon.startHeadless()
                CFRunLoopRun()
                exit(daemon.daemonExitCode)
            }
            controlLock = lock
        }
        let app = NSApplication.shared
        let delegate = ApexTuneApp(control: mode == .control,
                                    statusOnly: mode == .status,
                                    instanceLock: controlLock)
        app.delegate = delegate
        app.run()
    }
}
