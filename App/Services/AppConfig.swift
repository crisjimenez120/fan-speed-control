import FanCore
import Foundation

/// Everything the user configures. Persisted as JSON in Application Support.
struct AppConfig: Codable, Equatable {
    var profiles: [Profile] = []
    var activeProfileID: UUID?
    /// The modes currently in effect. Selecting a profile copies its modes here.
    var liveModes: [Int: FanMode] = [:]
    var alerts: [AlertRule] = []
    var menuBarStyle: MenuBarStyle = .both
    var menuBarSensorID = "cpu.max"
    var unit: TemperatureUnit = .celsius
    var pinnedSensorIDs: [String] = ["cpu.max", "gpu.max", "mem.avg", "hid.nand", "bat.max"]
    var hotkeyEnabled = true
    var updateInterval: Double = 1.5
    var notifyOnProfileChange = false

    static var fileURL: URL {
        let dir = URL.applicationSupportDirectory.appending(path: "FanControl", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "config.json")
    }

    static func load() -> AppConfig {
        guard let data = try? Data(contentsOf: fileURL),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data) else { return AppConfig() }
        return config
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(self).write(to: Self.fileURL, options: .atomic)
    }

    init() {}

    // Decode field by field so a missing or corrupt setting never wipes the rest of the config.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig()
        profiles = (try? c.decodeIfPresent([Profile].self, forKey: .profiles)) ?? d.profiles
        activeProfileID = try? c.decodeIfPresent(UUID.self, forKey: .activeProfileID)
        liveModes = (try? c.decodeIfPresent([Int: FanMode].self, forKey: .liveModes)) ?? d.liveModes
        alerts = (try? c.decodeIfPresent([AlertRule].self, forKey: .alerts)) ?? d.alerts
        menuBarStyle = (try? c.decodeIfPresent(MenuBarStyle.self, forKey: .menuBarStyle)) ?? d.menuBarStyle
        menuBarSensorID = (try? c.decodeIfPresent(String.self, forKey: .menuBarSensorID)) ?? d.menuBarSensorID
        unit = (try? c.decodeIfPresent(TemperatureUnit.self, forKey: .unit)) ?? d.unit
        pinnedSensorIDs = (try? c.decodeIfPresent([String].self, forKey: .pinnedSensorIDs)) ?? d.pinnedSensorIDs
        hotkeyEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .hotkeyEnabled)) ?? d.hotkeyEnabled
        updateInterval = (try? c.decodeIfPresent(Double.self, forKey: .updateInterval)) ?? d.updateInterval
        notifyOnProfileChange = (try? c.decodeIfPresent(Bool.self, forKey: .notifyOnProfileChange)) ?? d.notifyOnProfileChange
    }
}
