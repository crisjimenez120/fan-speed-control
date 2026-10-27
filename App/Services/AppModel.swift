import AppKit
import FanCore
import FanShared
import Foundation
import Observation
import ServiceManagement
import SMCKit
import UserNotifications

@MainActor
@Observable
final class AppModel {
    private(set) var fans: [FanInfo] = []
    private(set) var sensors: [SensorReading] = []
    /// Bumped once per refresh. Views that chart history read it to subscribe, then pull from `history`.
    private(set) var historyTick = 0
    /// Precomputed so the status item only re-renders when its text actually changes.
    private(set) var menuBarText = ""
    private(set) var sensorsByID: [String: SensorReading] = [:]
    private(set) var helperState: HelperState = .checking
    /// The installed helper works but differs from the one bundled with this build.
    private(set) var helperUpdateAvailable = false
    private(set) var hardwareAvailable = true
    private(set) var lastError: String?
    /// Fans the app has put in manual mode.
    private(set) var controlledFans: Set<Int> = []
    var installing = false

    var config: AppConfig {
        didSet {
            guard config != oldValue else { return }
            saveTask?.cancel()
            saveTask = Task { [config] in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                config.save()
            }
            if config.hotkeyEnabled != oldValue.hotkeyEnabled { updateHotKey() }
            if config.menuBarStyle != oldValue.menuBarStyle || config.menuBarSensorID != oldValue.menuBarSensorID
                || config.unit != oldValue.unit {
                displayedMenuBarTemp = nil
                updateMenuBarText(force: true)
            }
        }
    }

    @ObservationIgnored private var sensorHistory: [String: History] = [:]
    @ObservationIgnored private var fanHistory: [Int: History] = [:]
    @ObservationIgnored private let monitor = HardwareMonitor()
    @ObservationIgnored private let helper = HelperClient()
    @ObservationIgnored private var controller = FanController()
    @ObservationIgnored private var alertEvaluator = AlertEvaluator()
    @ObservationIgnored private var lastSent: [Int: (rpm: Double, at: Date)] = [:]
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var sleeping = false
    @ObservationIgnored private let hotKey = HotKey()
    @ObservationIgnored private var displayedMenuBarTemp: Double?
    @ObservationIgnored private var displayedMenuBarRPM: Double?
    @ObservationIgnored private var lastMenuBarUpdate = Date.distantPast
    /// Open popovers/windows. While zero, refreshes read only the sensors something depends on.
    @ObservationIgnored private var visibleUI = 0
    @ObservationIgnored private var lastFullRead = Date.distantPast
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var ticking = false
    @ObservationIgnored private var tickRequested = false

    init() {
        config = AppConfig.load()
        observeSleep()
        updateHotKey()
        loop = Task { [weak self] in await self?.run() }
        Task { await refreshHelperState() }
    }

    // MARK: Derived state

    func sensorSamples(_ id: String, last window: TimeInterval) -> [Sample] {
        _ = historyTick
        return sensorHistory[id]?.samples(last: window) ?? []
    }

    func fanSamples(_ index: Int, last window: TimeInterval) -> [Sample] {
        _ = historyTick
        return fanHistory[index]?.samples(last: window) ?? []
    }

    var pinnedSensors: [SensorReading] {
        let byID = sensorsByID
        return config.pinnedSensorIDs.compactMap { byID[$0] }
    }

    var activeProfile: Profile? { config.profiles.first { $0.id == config.activeProfileID } }

    var menuBarTemperature: Double? { sensorsByID[config.menuBarSensorID]?.celsius ?? sensorsByID["cpu.max"]?.celsius }

    var averageRPM: Double {
        guard !fans.isEmpty else { return 0 }
        return fans.map(\.currentRPM).reduce(0, +) / Double(fans.count)
    }

    /// 0...1 of the fans' range, for the menu bar glyph.
    var fanLoad: Double {
        guard !fans.isEmpty else { return 0 }
        return fans.map { ($0.currentRPM - $0.minRPM) / max($0.maxRPM - $0.minRPM, 1) }.reduce(0, +) / Double(fans.count)
    }

    func mode(for fan: Int) -> FanMode { config.liveModes[fan] ?? .auto }

    func format(_ celsius: Double?, decimals: Bool = false) -> String {
        guard let celsius else { return "—" }
        return config.unit.format(celsius, decimals: decimals)
    }

    // MARK: Intents

    func setMode(_ mode: FanMode, for fan: Int) {
        config.liveModes[fan] = mode
        // Hand-editing leaves any profile unless it still matches.
        if let p = activeProfile, (0..<fans.count).contains(where: { p.mode(for: $0) != self.mode(for: $0) }) {
            config.activeProfileID = nil
        }
        requestTick()
    }

    func apply(_ profile: Profile) {
        config.activeProfileID = profile.id
        config.liveModes = Dictionary(uniqueKeysWithValues: (0..<max(fans.count, 1)).map { ($0, profile.mode(for: $0)) })
        if config.notifyOnProfileChange { notify(title: "Fan profile: \(profile.name)", body: "") }
        requestTick()
    }

    func cycleProfile() {
        guard !config.profiles.isEmpty else { return }
        let idx = config.profiles.firstIndex { $0.id == config.activeProfileID } ?? -1
        apply(config.profiles[(idx + 1) % config.profiles.count])
    }

    func saveLiveModesAsProfile(named name: String) {
        let p = Profile(name: name, symbol: "slider.horizontal.3", modes: config.liveModes)
        config.profiles.append(p)
        config.activeProfileID = p.id
    }

    func updateProfile(_ profile: Profile) {
        guard let i = config.profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        config.profiles[i] = profile
        if config.activeProfileID == profile.id { apply(profile) }
    }

    func deleteProfile(_ id: UUID) {
        config.profiles.removeAll { $0.id == id }
        if config.activeProfileID == id { config.activeProfileID = nil }
    }

    func restoreBuiltInProfiles() {
        let builtIns = Profile.builtIns(fanCount: max(fans.count, 1), cpuSensorID: "cpu.max")
        config.profiles = builtIns + config.profiles.filter { !$0.isBuiltIn }
    }

    func resetAllToAuto() {
        config.liveModes = [:]
        config.activeProfileID = config.profiles.first { $0.isBuiltIn && $0.name == "Auto" }?.id
        requestTick()
    }

    func togglePin(_ id: String) {
        if let i = config.pinnedSensorIDs.firstIndex(of: id) {
            config.pinnedSensorIDs.remove(at: i)
        } else {
            config.pinnedSensorIDs.append(id)
        }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                lastError = "Launch at login: \(error.localizedDescription)"
            }
        }
    }

    func addAlert(sensorID: String, threshold: Double) {
        config.alerts.append(AlertRule(sensorID: sensorID, threshold: threshold))
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func clearError() { lastError = nil }

    // MARK: Helper

    func refreshHelperState() async {
        guard let version = await helper.installedVersion() else {
            helper.reset()
            helperState = FileManager.default.fileExists(atPath: FanShared.HelperConstants.helperPath)
                ? .failed("The helper is installed but not responding. Reinstall it.")
                : .notInstalled
            return
        }
        // A different protocol version can't be used. A rebuilt binary with the same version still
        // works, so keep controlling fans and just offer the update.
        helperState = version == FanShared.HelperConstants.version ? .ready : .outdated(installed: version)
        helperUpdateAvailable = helperState.isReady && !FileManager.default.contentsEqual(
            atPath: FanShared.HelperConstants.helperPath, andPath: HelperInstaller.bundledHelperURL.path)
    }

    func installHelper() {
        installing = true
        defer { installing = false }
        do {
            try HelperInstaller.install()
            helper.reset()
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                await refreshHelperState()
                await tick()
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func uninstallHelper() {
        Task {
            _ = await helper.setAllAuto()
            do {
                try HelperInstaller.uninstall()
                helper.reset()
                controlledFans = []
                helperState = .notInstalled
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    /// Called from applicationWillTerminate.
    func shutdown() {
        loop?.cancel()
        config.save()
        if !controlledFans.isEmpty { helper.setAllAutoSynchronously() }
    }

    // MARK: Loop

    private func run() async {
        hardwareAvailable = await monitor.isAvailable
        while !Task.isCancelled {
            await tick()
            // Tolerance lets macOS coalesce our wakeups with others.
            let interval = config.updateInterval
            try? await Task.sleep(for: .seconds(interval), tolerance: .seconds(interval * 0.2))
        }
    }

    func requestTick() {
        Task { await tick() }
    }

    /// One read/record/control pass. Overlapping requests coalesce into one extra pass.
    private func tick() async {
        guard !ticking else {
            tickRequested = true
            return
        }
        ticking = true
        defer { ticking = false }
        repeat {
            tickRequested = false
            await tickOnce()
        } while tickRequested
    }

    private func tickOnce() async {
        let now = Date()
        let full = visibleUI > 0 || now.timeIntervalSince(lastFullRead) >= 10 || sensors.isEmpty
        let snap = await monitor.snapshot(only: full ? nil : requiredSensorIDs)
        if full { lastFullRead = now }
        if fans != snap.fans { fans = snap.fans }
        // A partial read refreshes what it read and keeps the last value for everything else.
        let merged: [SensorReading]
        if full {
            merged = snap.sensors
        } else {
            let fresh = Dictionary(snap.sensors.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            merged = sensors.map { fresh[$0.id] ?? $0 }
        }
        if sensors != merged {
            sensors = merged
            sensorsByID = Dictionary(merged.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        }
        updateMenuBarText()
        if config.profiles.isEmpty, !snap.fans.isEmpty { restoreBuiltInProfiles() }
        applyLaunchProfileIfRequested()
        recordHistory(snap, now: now)
        evaluateAlerts()
        guard !sleeping else { return }
        await control(now: now)
    }

    /// `-FCProfile <name>` applies a profile at launch (handy for scripts and login items).
    @ObservationIgnored private var launchProfileName = UserDefaults.standard.string(forKey: "FCProfile")

    private func applyLaunchProfileIfRequested() {
        guard let name = launchProfileName, !fans.isEmpty else { return }
        launchProfileName = nil
        if let p = config.profiles.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { apply(p) }
    }

    /// Sensors that fan modes, alerts, or the menu bar depend on.
    private var requiredSensorIDs: Set<String> {
        var ids = Set(config.liveModes.values.compactMap(\.sensorID))
        ids.formUnion(config.alerts.filter(\.enabled).map(\.sensorID))
        if config.menuBarStyle == .temperature || config.menuBarStyle == .both {
            ids.insert(config.menuBarSensorID)
            ids.insert("cpu.max")
        }
        return ids
    }

    func uiDidAppear() {
        visibleUI += 1
        requestTick()
    }

    func uiDidDisappear() {
        visibleUI = max(0, visibleUI - 1)
    }

    private func recordHistory(_ snap: HardwareSnapshot, now: Date) {
        for s in snap.sensors { sensorHistory[s.id, default: History()].append(s.celsius, at: now) }
        for f in snap.fans { fanHistory[f.index, default: History()].append(f.currentRPM, at: now) }
        historyTick &+= 1
    }

    /// The status item is expensive to redraw (once per display), so its text changes at most every
    /// 3 s, and only when a value moves past a threshold.
    private func updateMenuBarText(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastMenuBarUpdate) >= 3 else { return }
        lastMenuBarUpdate = now
        let text: String
        // Hold the displayed value until it moves a full degree, so ±0.5° jitter doesn't redraw the menu bar.
        if let t = menuBarTemperature {
            if displayedMenuBarTemp.map({ abs($0 - t) >= 1 }) ?? true { displayedMenuBarTemp = t }
        } else {
            displayedMenuBarTemp = nil
        }
        let temp = format(displayedMenuBarTemp)
        if displayedMenuBarRPM.map({ abs($0 - averageRPM) >= 100 }) ?? true { displayedMenuBarRPM = averageRPM }
        let avg = displayedMenuBarRPM ?? 0
        let rpm = fans.isEmpty ? "—" : avg >= 1000 ? String(format: "%.1fk", avg / 1000) : avg.rpmString
        switch config.menuBarStyle {
        case .icon: text = ""
        case .temperature: text = temp
        case .rpm: text = rpm
        case .both: text = "\(temp) \(rpm)"
        }
        if text != menuBarText { menuBarText = text }
    }

    private func control(now: Date) async {
        let temps = Dictionary(sensors.map { ($0.id, $0.celsius) }, uniquingKeysWith: { a, _ in a })
        let wantsManual = fans.contains { mode(for: $0.index) != .auto }
        guard helperState.isReady else {
            if wantsManual, helperState == .checking { await refreshHelperState() }
            return
        }
        for fan in fans {
            let limits = FanLimits(min: fan.minRPM, max: fan.maxRPM)
            if let rpm = controller.target(fan: fan.index, mode: mode(for: fan.index), limits: limits, temperatures: temps) {
                let last = lastSent[fan.index]
                // Re-send occasionally even if unchanged; doubles as a heartbeat and recovers from SMC resets.
                guard last == nil || abs(last!.rpm - rpm) >= 15 || now.timeIntervalSince(last!.at) > 5 || !fan.isManual else { continue }
                if let err = await helper.setRPM(fan.index, rpm) {
                    lastError = "Couldn't set \(fan.name): \(err)"
                    await refreshHelperState()
                } else {
                    lastSent[fan.index] = (rpm, now)
                    controlledFans.insert(fan.index)
                }
            } else if controlledFans.contains(fan.index) || fan.isManual {
                if let err = await helper.setAuto(fan.index) {
                    lastError = "Couldn't release \(fan.name): \(err)"
                } else {
                    controlledFans.remove(fan.index)
                    lastSent[fan.index] = nil
                }
            }
        }
        if !controlledFans.isEmpty { helper.heartbeat() }
    }

    private func evaluateAlerts() {
        let temps = Dictionary(sensors.map { ($0.id, $0.celsius) }, uniquingKeysWith: { a, _ in a })
        let byID = sensorsByID
        for rule in alertEvaluator.evaluate(config.alerts, temperatures: temps) {
            let name = byID[rule.sensorID]?.name ?? rule.sensorID
            notify(title: "\(name) is hot", body: "\(format(temps[rule.sensorID])) — above your \(format(rule.threshold)) alert.")
        }
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: System

    private func observeSleep() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.sleeping = true
                Task {
                    _ = await self.helper.setAllAuto()
                    self.controlledFans = []
                    self.lastSent = [:]
                }
            }
        }
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.sleeping = false
                self.controller = FanController()
                Task { await self.tick() }
            }
        }
    }

    private func updateHotKey() {
        if config.hotkeyEnabled {
            hotKey.register { [weak self] in self?.cycleProfile() }
        } else {
            hotKey.unregister()
        }
    }
}
