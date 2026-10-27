import Foundation

public struct FanInfo: Sendable, Hashable, Identifiable {
    public var id: Int { index }
    public let index: Int
    public var name: String
    public var currentRPM: Double
    public var targetRPM: Double
    public var minRPM: Double
    public var maxRPM: Double
    public var isManual: Bool
}

public enum SensorGroup: String, Sendable, CaseIterable, Comparable {
    case cpu = "CPU", gpu = "GPU", memory = "Memory", storage = "Storage", battery = "Battery"
    case enclosure = "Enclosure", wireless = "Wireless", power = "Power", other = "Other"

    public static func < (a: Self, b: Self) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }

    public var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .gpu: "rectangle.3.group"
        case .memory: "memorychip"
        case .storage: "internaldrive"
        case .battery: "battery.75percent"
        case .enclosure: "laptopcomputer"
        case .wireless: "wifi"
        case .power: "bolt"
        case .other: "thermometer.medium"
        }
    }
}

public struct SensorReading: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let group: SensorGroup
    /// True for derived summary sensors (e.g. "CPU hottest core").
    public let isSummary: Bool
    public var celsius: Double
}

/// Discovers fans and temperature sensors once, then polls them cheaply.
public final class HardwareReader {
    private let smc: SMC
    private var rawKeys: [(key: String, name: String, group: SensorGroup)] = []
    public private(set) var fanCount = 0
    private let isAppleSilicon: Bool

    public init() throws {
        smc = try SMC()
        var sys = utsname()
        uname(&sys)
        isAppleSilicon = withUnsafeBytes(of: &sys.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }.hasPrefix("arm64")
        fanCount = Int(smc.number("FNum") ?? 0)
        discoverSensors()
    }

    private func discoverSensors() {
        rawKeys = smc.allKeys().compactMap { key in
            guard key.hasPrefix("T"), let v = smc.number(key), v > 10, v < 130,
                  let (name, group) = SensorCatalog.describe(key, appleSilicon: isAppleSilicon) else { return nil }
            return (key, name, group)
        }
    }

    public func readFans() -> [FanInfo] {
        (0..<fanCount).map { i in
            let mode = smc.number("F\(i)Md")
            let forced = smc.number("FS! ").map { (Int($0) >> i) & 1 == 1 } ?? false
            return FanInfo(
                index: i,
                name: fanCount == 2 ? (i == 0 ? "Left Fan" : "Right Fan") : "Fan \(i + 1)",
                currentRPM: max(0, smc.number("F\(i)Ac") ?? 0),
                targetRPM: smc.number("F\(i)Tg") ?? 0,
                minRPM: smc.number("F\(i)Mn") ?? 0,
                maxRPM: smc.number("F\(i)Mx") ?? 6000,
                isManual: (mode ?? 0) == 1 || forced
            )
        }
    }

    public func readSensors() -> [SensorReading] {
        var raw: [SensorReading] = rawKeys.compactMap { k in
            guard let v = smc.number(k.key), v > 0, v < 150 else { return nil }
            return SensorReading(id: k.key, name: k.name, group: k.group, isSummary: false, celsius: v)
        }
        // SSD temperature on Apple Silicon is only exposed over HID.
        let hid = HIDSensors.temperatures()
        if let nand = hid.filter({ $0.name.hasPrefix("NAND") }).map(\.celsius).max() {
            raw.append(SensorReading(id: "hid.nand", name: "SSD", group: .storage, isSummary: false, celsius: nand))
        }
        return SensorCatalog.summaries(from: raw) + raw
    }
}

enum SensorCatalog {
    static let named: [String: (String, SensorGroup)] = [
        // Intel
        "TC0P": ("CPU Proximity", .cpu), "TC0D": ("CPU Die", .cpu), "TC0E": ("CPU Die (avg)", .cpu),
        "TC0F": ("CPU Die (filtered)", .cpu), "TCXC": ("CPU PECI", .cpu), "TG0P": ("GPU Proximity", .gpu),
        "TG0D": ("GPU Die", .gpu), "TM0P": ("Memory Proximity", .memory), "TPCD": ("Platform Controller Hub", .other),
        "TA0P": ("Ambient", .enclosure), "TH0P": ("SSD Proximity", .storage),
        // Apple Silicon, common across generations
        "TB0T": ("Battery 1", .battery), "TB1T": ("Battery 2", .battery), "TB2T": ("Battery 3", .battery),
        "TW0P": ("Wi-Fi Module", .wireless), "Ts0P": ("Palm Rest Left", .enclosure), "Ts1P": ("Palm Rest Right", .enclosure),
        "TaLP": ("Airflow Left", .enclosure), "TaRF": ("Airflow Right", .enclosure), "TaTP": ("Airflow Top", .enclosure),
        "TH0x": ("SSD (max)", .storage), "TH0a": ("SSD A", .storage), "TH0b": ("SSD B", .storage),
        "TCDX": ("CPU Die (max)", .cpu), "TCHP": ("Charger Proximity", .power), "TMVR": ("Memory VRM", .power),
        "TPDX": ("Power Delivery (max)", .power), "TVMR": ("VRM", .power), "TAOL": ("Ambient Light Sensor", .enclosure),
    ]

    static func describe(_ key: String, appleSilicon: Bool) -> (String, SensorGroup)? {
        if let n = named[key] { return n }
        let chars = Array(key)
        guard chars.count == 4 else { return nil }
        let suffix = String(chars[2...])
        if appleSilicon {
            switch String(chars[0...1]) {
            case "Tp": return ("Performance Core \(suffix)", .cpu)
            case "Te": return ("Efficiency Core \(suffix)", .cpu)
            case "Tg": return ("GPU Cluster \(suffix)", .gpu)
            case "Tm": return ("Memory \(suffix)", .memory)
            case "Ta": return ("Airflow \(suffix)", .enclosure)
            default: return nil
            }
        }
        if key.hasPrefix("TC"), chars[3] == "C", chars[2].isNumber { return ("CPU Core \(chars[2])", .cpu) }
        return nil
    }

    static func summaries(from raw: [SensorReading]) -> [SensorReading] {
        func summary(_ id: String, _ name: String, _ group: SensorGroup, _ values: [Double], max useMax: Bool = true) -> SensorReading? {
            guard !values.isEmpty else { return nil }
            let v = useMax ? values.max()! : values.reduce(0, +) / Double(values.count)
            return SensorReading(id: id, name: name, group: group, isSummary: true, celsius: v)
        }
        let byPrefix = { (prefixes: [String]) in raw.filter { r in prefixes.contains { r.id.hasPrefix($0) } }.map(\.celsius) }
        let cores = byPrefix(["Tp", "Te"]) + raw.filter { $0.id.hasPrefix("TC") && $0.id.hasSuffix("C") }.map(\.celsius)
        let cpuFallback = raw.filter { ["TC0P", "TC0D", "TC0E", "TCDX"].contains($0.id) }.map(\.celsius)
        let cpu = cores.isEmpty ? cpuFallback : cores
        return [
            summary("cpu.max", "CPU (hottest core)", .cpu, cpu),
            summary("cpu.avg", "CPU (average)", .cpu, cpu, max: false),
            summary("gpu.max", "GPU", .gpu, byPrefix(["Tg", "TG0"])),
            summary("mem.avg", "Memory", .memory, byPrefix(["Tm", "TM0"]), max: false),
            summary("bat.max", "Battery", .battery, raw.filter { $0.group == .battery }.map(\.celsius)),
        ].compactMap { $0 }
    }
}
