import Charts
import FanCore
import FanShared
import SMCKit
import SwiftUI

enum MainSection: String, CaseIterable, Identifiable, Hashable {
    case fans, sensors, profiles, alerts, settings
    var id: String { rawValue }

    /// Section requested by the popover before the window existed.
    @MainActor static var pending: MainSection?

    var title: String {
        switch self {
        case .fans: "Fans"
        case .sensors: "Sensors"
        case .profiles: "Profiles"
        case .alerts: "Alerts"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .fans: "fan"
        case .sensors: "thermometer.medium"
        case .profiles: "square.stack.3d.up"
        case .alerts: "bell.badge"
        case .settings: "gearshape"
        }
    }
}

struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @State private var section: MainSection? = .fans

    var body: some View {
        NavigationSplitView {
            List(MainSection.allCases, selection: $section) { s in
                Label(s.title, systemImage: s.symbol).tag(s)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
            .safeAreaInset(edge: .bottom) { SidebarStatus().padding(12) }
        } detail: {
            Group {
                switch section ?? .fans {
                case .fans: FansPane()
                case .sensors: SensorsPane()
                case .profiles: ProfilesPane()
                case .alerts: AlertsPane()
                case .settings: SettingsPane()
                }
            }
            .navigationTitle((section ?? .fans).title)
        }
        .onAppear(perform: takePending)
        .onReceive(NotificationCenter.default.publisher(for: .selectMainSection)) { _ in takePending() }
    }

    private func takePending() {
        if let p = MainSection.pending {
            section = p
            MainSection.pending = nil
        }
    }
}

struct SidebarStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            if let t = model.sensorsByID["cpu.max"]?.celsius {
                Text("CPU \(model.format(t)) · \(model.averageRPM.rpmString) RPM")
                    .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var color: Color {
        switch model.helperState {
        case .ready: .green
        case .checking: .gray
        default: .orange
        }
    }

    private var label: String {
        switch model.helperState {
        case .ready: "Helper connected"
        case .checking: "Checking helper…"
        case .notInstalled: "Helper not installed"
        case .outdated: "Helper needs update"
        case .failed: "Helper not responding"
        }
    }
}

// MARK: - Fans

struct FansPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HelperBanner()
                if let err = model.lastError { ErrorBanner(message: err) }
                HStack {
                    ProfileChips()
                    Spacer()
                    SaveProfileButton()
                }
                ForEach(model.fans) { fan in FanDetailCard(fan: fan) }
                if model.fans.isEmpty {
                    ContentUnavailableView("No fans found", systemImage: "fan.slash", description: Text("This Mac doesn't report any controllable fans."))
                }
            }
            .padding(20)
        }
    }
}

struct SaveProfileButton: View {
    @Environment(AppModel.self) private var model
    @State private var naming = false
    @State private var name = ""

    var body: some View {
        Button("Save as Profile…", systemImage: "plus") {
            name = "My Profile"
            naming = true
        }
        .buttonStyle(.glass)
        .alert("Save current settings as a profile", isPresented: $naming) {
            TextField("Name", text: $name)
            Button("Save") { model.saveLiveModesAsProfile(named: name.isEmpty ? "My Profile" : name) }
            Button("Cancel", role: .cancel) {}
        }
    }
}

struct FanDetailCard: View {
    @Environment(AppModel.self) private var model
    let fan: FanInfo

    var body: some View {
        Card(padding: 16) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        SpinningFan(rpm: fan.currentRPM, size: 28,
                                    tint: Theme.color(forLoad: (fan.currentRPM - fan.minRPM) / max(fan.maxRPM - fan.minRPM, 1)))
                        VStack(alignment: .leading) {
                            Text(fan.name).font(.title3.weight(.semibold))
                            Text("\(fan.minRPM.rpmString)–\(fan.maxRPM.rpmString) RPM").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        RollingNumber(value: fan.currentRPM, threshold: 50, size: 40) { (($0 / 10).rounded() * 10).rpmString }
                        Text("RPM").foregroundStyle(.secondary)
                    }
                    RPMBar(fan: fan)
                    Chart(model.fanSamples(fan.index, last: 600).downsampled(to: 150), id: \.date) { s in
                        LineMark(x: .value("Time", s.date), y: .value("RPM", s.value))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(.teal)
                    }
                    .chartYScale(domain: 0...fan.maxRPM)
                    .chartXScale(domain: Date.now.addingTimeInterval(-600)...Date.now)
                    .chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
                    .chartXAxis { AxisMarks(values: .stride(by: .minute, count: 3)) { AxisValueLabel(format: .dateTime.hour().minute()) } }
                    .frame(height: 90)
                }
                .frame(width: 250)

                FanModeEditor(fan: fan, mode: model.mode(for: fan.index)) { model.setMode($0, for: fan.index) }
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - Sensors

struct SensorsPane: View {
    @Environment(AppModel.self) private var model
    @State private var selection: String? = "cpu.max"
    @State private var search = ""
    @State private var window: TimeInterval = 300

    var body: some View {
        HSplitView {
            List(selection: $selection) {
                let filtered = model.sensors.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search) }
                let grouped = Dictionary(grouping: filtered, by: \.group)
                ForEach(grouped.keys.sorted(), id: \.self) { group in
                    Section {
                        ForEach(grouped[group]!.sorted { ($0.isSummary ? 0 : 1, $0.name) < ($1.isSummary ? 0 : 1, $1.name) }) { s in
                            SensorRow(sensor: s).tag(s.id)
                        }
                    } header: {
                        Label(group.rawValue, systemImage: group.symbol)
                    }
                }
            }
            .searchable(text: $search, placement: .sidebar, prompt: "Filter sensors")
            .frame(minWidth: 300)

            detail
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let id = selection, let s = model.sensorsByID[id] {
            let samples = model.sensorSamples(id, last: window).downsampled(to: 300)
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading) {
                        Text(s.name).font(.title2.weight(.semibold))
                        Text(s.isSummary ? "Derived from \(s.group.rawValue) sensors" : "SMC key \(s.id)")
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    Text(model.format(s.celsius, decimals: true))
                        .font(.system(size: 36, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(Theme.color(forCelsius: s.celsius))
                }
                HStack {
                    Picker("Range", selection: $window) {
                        Text("5 min").tag(300.0)
                        Text("10 min").tag(600.0)
                        Text("1 hour").tag(3600.0)
                        Text("24 hours").tag(86_400.0)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 300)
                    Spacer()
                    Button(model.config.pinnedSensorIDs.contains(id) ? "Unpin from Menu" : "Pin to Menu",
                           systemImage: model.config.pinnedSensorIDs.contains(id) ? "pin.slash" : "pin") { model.togglePin(id) }
                }
                Chart(samples, id: \.date) { sample in
                    AreaMark(x: .value("Time", sample.date), yStart: .value("Base", (samples.map(\.value).min() ?? 0) - 3), yEnd: .value("Temp", sample.value))
                        .foregroundStyle(LinearGradient(colors: [Theme.color(forCelsius: s.celsius).opacity(0.3), .clear], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", sample.date), y: .value("Temp", sample.value))
                        .foregroundStyle(Theme.heatVertical)
                        .interpolationMethod(.monotone)
                }
                .chartYScale(domain: ((samples.map(\.value).min() ?? 0) - 3)...((samples.map(\.value).max() ?? 100) + 3))
                .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(model.format(d)) } } } }
                .frame(maxHeight: .infinity)
                if !samples.isEmpty {
                    HStack(spacing: 24) {
                        stat("Min", samples.map(\.value).min()!)
                        stat("Avg", samples.map(\.value).reduce(0, +) / Double(samples.count))
                        stat("Max", samples.map(\.value).max()!)
                    }
                }
            }
            .padding(20)
        } else {
            ContentUnavailableView("Select a sensor", systemImage: "thermometer.medium")
        }
    }

    private func stat(_ label: String, _ v: Double) -> some View {
        VStack(alignment: .leading) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(model.format(v, decimals: true)).font(.headline.monospacedDigit())
        }
    }
}

struct SensorRow: View {
    @Environment(AppModel.self) private var model
    let sensor: SensorReading

    var body: some View {
        HStack {
            if model.config.pinnedSensorIDs.contains(sensor.id) {
                Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary)
            }
            Text(sensor.name).fontWeight(sensor.isSummary ? .semibold : .regular)
            Spacer()
            Sparkline(samples: model.sensorSamples(sensor.id, last: 120), color: Theme.color(forCelsius: sensor.celsius))
                .frame(width: 50, height: 14)
            Text(model.format(sensor.celsius))
                .monospacedDigit()
                .foregroundStyle(Theme.color(forCelsius: sensor.celsius))
                .frame(width: 40, alignment: .trailing)
        }
    }
}

// MARK: - Profiles

struct ProfilesPane: View {
    @Environment(AppModel.self) private var model
    @State private var selection: UUID?

    var body: some View {
        HSplitView {
            List(selection: $selection) {
                ForEach(model.config.profiles) { p in
                    HStack {
                        Label(p.name, systemImage: p.symbol)
                        Spacer()
                        if p.id == model.config.activeProfileID {
                            Text("Active").font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.tint.opacity(0.2), in: Capsule())
                        }
                    }
                    .tag(p.id)
                    .contextMenu {
                        Button("Apply") { model.apply(p) }
                        Button("Duplicate") { duplicate(p) }
                        Button("Delete", role: .destructive) { model.deleteProfile(p.id) }
                    }
                }
                .onMove { model.config.profiles.move(fromOffsets: $0, toOffset: $1) }
            }
            .frame(minWidth: 220)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button("New", systemImage: "plus") {
                        let p = Profile(name: "New Profile", symbol: "slider.horizontal.3", modes: model.config.liveModes)
                        model.config.profiles.append(p)
                        selection = p.id
                    }
                    Spacer()
                    Menu("More") {
                        Button("Restore Built-in Profiles") { model.restoreBuiltInProfiles() }
                    }
                    .fixedSize()
                }
                .buttonStyle(.borderless)
                .padding(10)
            }

            Group {
                if let id = selection, let profile = model.config.profiles.first(where: { $0.id == id }) {
                    ProfileEditor(profile: profile, onDuplicate: { duplicate(profile) })
                } else {
                    ContentUnavailableView("Select a profile", systemImage: "square.stack.3d.up",
                                           description: Text("Profiles save a mode for every fan. Switch between them from the menu bar or with \(HotKey.displayString)."))
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { selection = selection ?? model.config.activeProfileID ?? model.config.profiles.first?.id }
    }

    private func duplicate(_ p: Profile) {
        let copy = Profile(name: "\(p.name) Copy", symbol: p.symbol, modes: p.modes)
        model.config.profiles.append(copy)
        selection = copy.id
    }
}

struct ProfileEditor: View {
    @Environment(AppModel.self) private var model
    let profile: Profile
    let onDuplicate: () -> Void

    private static let symbols = ["moon", "dial.low", "dial.medium", "dial.high", "bolt", "wind", "leaf", "flame", "gamecontroller",
                                  "film", "hammer", "headphones", "snowflake", "tortoise", "hare", "slider.horizontal.3"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Menu {
                        ForEach(Self.symbols, id: \.self) { s in
                            Button { save { $0.symbol = s } } label: { Label(s, systemImage: s) }
                        }
                    } label: {
                        Image(systemName: profile.symbol).font(.title2).frame(width: 36, height: 36)
                    }
                    .menuStyle(.button)
                    .fixedSize()
                    TextField("Name", text: Binding(get: { profile.name }, set: { n in save { $0.name = n } }))
                        .textFieldStyle(.plain)
                        .font(.title2.weight(.semibold))
                    Spacer()
                    Button("Duplicate", action: onDuplicate).buttonStyle(.glass)
                    Button(profile.id == model.config.activeProfileID ? "Active" : "Apply") { model.apply(profile) }
                        .buttonStyle(.glassProminent)
                        .disabled(profile.id == model.config.activeProfileID)
                }
                if profile.isBuiltIn {
                    Text("Built-in profile. Your edits are kept, and you can restore the originals from More.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(model.fans) { fan in
                    Card(padding: 14) {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(fan.name, systemImage: "fan").font(.headline)
                            FanModeEditor(fan: fan, mode: profile.mode(for: fan.index)) { m in save { $0.modes[fan.index] = m } }
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button("Copy settings from other fans to all", systemImage: "square.on.square") {
                        save { p in
                            let first = p.mode(for: 0)
                            for f in model.fans { p.modes[f.index] = first }
                        }
                    }
                    .disabled(model.fans.count < 2)
                    .help("Apply the first fan's mode to every fan")
                }
            }
            .padding(20)
        }
    }

    private func save(_ edit: (inout Profile) -> Void) {
        var p = profile
        edit(&p)
        model.updateProfile(p)
    }
}

// MARK: - Alerts

struct AlertsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                ForEach(model.config.alerts) { rule in
                    AlertRow(rule: rule)
                }
                .onDelete { model.config.alerts.remove(atOffsets: $0) }
                if model.config.alerts.isEmpty {
                    Text("No alerts yet. You'll get a notification when a sensor crosses its threshold. It fires again only after the sensor cools down.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                HStack {
                    Text("Temperature alerts")
                    Spacer()
                    Button("Add Alert", systemImage: "plus") { model.addAlert(sensorID: "cpu.max", threshold: 95) }
                }
            }
            Section("Other notifications") {
                Toggle("Notify when the profile changes", isOn: Binding(
                    get: { model.config.notifyOnProfileChange },
                    set: { model.config.notifyOnProfileChange = $0 }
                ))
            }
        }
        .formStyle(.grouped)
    }
}

struct AlertRow: View {
    @Environment(AppModel.self) private var model
    let rule: AlertRule

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: bind(\.enabled)).labelsHidden().toggleStyle(.switch).controlSize(.small)
            SensorPicker(title: "", selection: rule.sensorID, context: rule.id.hashValue) { id in edit { $0.sensorID = id } }
                .equatable()
                .labelsHidden()
                .frame(maxWidth: 260)
            Text("above").foregroundStyle(.secondary)
            Stepper(value: bind(\.threshold), in: 30...115, step: 1) {
                Text(model.format(rule.threshold)).monospacedDigit().frame(width: 40)
            }
            Spacer()
            if let t = model.sensorsByID[rule.sensorID]?.celsius {
                Text("now \(model.format(t))").font(.caption.monospacedDigit())
                    .foregroundStyle(t >= rule.threshold ? .red : .secondary)
            }
            Button(role: .destructive) {
                model.config.alerts.removeAll { $0.id == rule.id }
            } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
        }
    }

    private func edit(_ change: (inout AlertRule) -> Void) {
        guard let i = model.config.alerts.firstIndex(where: { $0.id == rule.id }) else { return }
        change(&model.config.alerts[i])
    }

    private func bind<T>(_ kp: WritableKeyPath<AlertRule, T>) -> Binding<T> {
        Binding(get: { rule[keyPath: kp] }, set: { v in edit { $0[keyPath: kp] = v } })
    }
}

// MARK: - Settings

struct SettingsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Menu bar") {
                Picker("Show", selection: $model.config.menuBarStyle) {
                    ForEach(MenuBarStyle.allCases) { Text($0.title).tag($0) }
                }
                SensorPicker(title: "Temperature sensor", selection: model.config.menuBarSensorID) { model.config.menuBarSensorID = $0 }
                    .equatable()
                    .disabled(model.config.menuBarStyle == .icon || model.config.menuBarStyle == .rpm)
            }
            Section("General") {
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
                Picker("Temperature unit", selection: $model.config.unit) {
                    Text("Celsius").tag(TemperatureUnit.celsius)
                    Text("Fahrenheit").tag(TemperatureUnit.fahrenheit)
                }
                .pickerStyle(.segmented)
                Picker("Update every", selection: $model.config.updateInterval) {
                    Text("1 s").tag(1.0)
                    Text("1.5 s").tag(1.5)
                    Text("2 s").tag(2.0)
                    Text("3 s").tag(3.0)
                    Text("5 s").tag(5.0)
                }
                Toggle("Cycle profiles with \(HotKey.displayString)", isOn: $model.config.hotkeyEnabled)
            }
            Section {
                LabeledContent("Status") { SidebarStatus() }
                LabeledContent("Location") { Text(FanShared.HelperConstants.helperPath).font(.caption.monospaced()).textSelection(.enabled) }
                HStack {
                    Button(model.helperState == .notInstalled ? "Install Helper" : "Reinstall Helper") { model.installHelper() }
                        .disabled(model.installing)
                    Button("Uninstall Helper", role: .destructive) { model.uninstallHelper() }
                        .disabled(model.helperState == .notInstalled)
                    Spacer()
                    Button("Check Again") { Task { await model.refreshHelperState() } }
                }
            } header: {
                Text("Privileged helper")
            } footer: {
                Text("The helper only sets fan speeds. If Fan Control quits, crashes, or stops responding for \(Int(FanShared.HelperConstants.watchdogTimeout)) seconds, it hands every fan back to macOS. The same happens when your Mac sleeps.")
            }
        }
        .formStyle(.grouped)
    }
}
