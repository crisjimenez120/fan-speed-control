import Foundation

/// A point on a fan curve: at `temperature` °C, run at `percent` (0...100) of the fan's RPM range.
public struct CurvePoint: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var temperature: Double
    public var percent: Double

    public init(temperature: Double, percent: Double) {
        self.temperature = temperature
        self.percent = percent
    }

    private enum CodingKeys: String, CodingKey { case temperature, percent }

    // Identity is only for SwiftUI; value equality ignores it.
    public static func == (a: Self, b: Self) -> Bool { a.temperature == b.temperature && a.percent == b.percent }
    public func hash(into h: inout Hasher) {
        h.combine(temperature)
        h.combine(percent)
    }
}

public struct FanCurve: Codable, Hashable, Sendable {
    public var points: [CurvePoint]

    public init(points: [CurvePoint]) {
        self.points = points.sorted { $0.temperature < $1.temperature }
    }

    public static let balanced = FanCurve(points: [
        .init(temperature: 45, percent: 0),
        .init(temperature: 60, percent: 20),
        .init(temperature: 75, percent: 55),
        .init(temperature: 90, percent: 100),
    ])

    /// Linear interpolation, flat beyond the first/last point. Returns 0...100.
    public func percent(at temperature: Double) -> Double {
        let pts = points.sorted { $0.temperature < $1.temperature }
        guard let first = pts.first, let last = pts.last else { return 0 }
        if temperature <= first.temperature { return first.percent.clamped(0, 100) }
        if temperature >= last.temperature { return last.percent.clamped(0, 100) }
        for (a, b) in zip(pts, pts.dropFirst()) where temperature <= b.temperature {
            let span = b.temperature - a.temperature
            let t = span > 0 ? (temperature - a.temperature) / span : 1
            return (a.percent + (b.percent - a.percent) * t).clamped(0, 100)
        }
        return last.percent.clamped(0, 100)
    }
}

public enum FanMode: Codable, Hashable, Sendable {
    /// Let macOS control the fan.
    case auto
    /// Hold a constant RPM.
    case fixed(rpm: Double)
    /// Scale linearly from min RPM at `lowTemp` to max RPM at `highTemp` of a sensor.
    case sensor(sensorID: String, lowTemp: Double, highTemp: Double)
    /// Follow a multi-point curve driven by a sensor.
    case curve(sensorID: String, curve: FanCurve)

    public var kind: Kind {
        switch self {
        case .auto: .auto
        case .fixed: .fixed
        case .sensor: .sensor
        case .curve: .curve
        }
    }

    public var sensorID: String? {
        switch self {
        case .sensor(let id, _, _), .curve(let id, _): id
        default: nil
        }
    }

    public enum Kind: String, CaseIterable, Codable, Sendable, Identifiable {
        case auto, fixed, sensor, curve
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .auto: "Auto"
            case .fixed: "Fixed"
            case .sensor: "Sensor"
            case .curve: "Curve"
            }
        }
    }
}

public struct Profile: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var symbol: String
    /// Mode per fan index. Fans missing from the map run in `.auto`.
    public var modes: [Int: FanMode]
    public var isBuiltIn: Bool

    public init(id: UUID = UUID(), name: String, symbol: String, modes: [Int: FanMode], isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.modes = modes
        self.isBuiltIn = isBuiltIn
    }

    public func mode(for fan: Int) -> FanMode { modes[fan] ?? .auto }

    /// Built-in profiles. Stable IDs so selections persist across launches.
    public static func builtIns(fanCount: Int, cpuSensorID: String) -> [Profile] {
        func all(_ m: FanMode) -> [Int: FanMode] {
            Dictionary(uniqueKeysWithValues: (0..<max(fanCount, 1)).map { ($0, m) })
        }
        return [
            Profile(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "Auto", symbol: "a.circle",
                    modes: all(.auto), isBuiltIn: true),
            Profile(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, name: "Silent", symbol: "moon",
                    modes: all(.curve(sensorID: cpuSensorID, curve: FanCurve(points: [
                        .init(temperature: 55, percent: 0),
                        .init(temperature: 75, percent: 15),
                        .init(temperature: 88, percent: 45),
                        .init(temperature: 98, percent: 100),
                    ]))), isBuiltIn: true),
            Profile(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, name: "Balanced", symbol: "dial.medium",
                    modes: all(.curve(sensorID: cpuSensorID, curve: .balanced)), isBuiltIn: true),
            Profile(id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!, name: "Performance", symbol: "bolt",
                    modes: all(.sensor(sensorID: cpuSensorID, lowTemp: 40, highTemp: 80)), isBuiltIn: true),
            Profile(id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!, name: "Max", symbol: "wind",
                    modes: all(.fixed(rpm: 100_000)), isBuiltIn: true),
        ]
    }
}

public struct AlertRule: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var sensorID: String
    public var threshold: Double
    public var enabled = true

    public init(sensorID: String, threshold: Double, enabled: Bool = true) {
        self.sensorID = sensorID
        self.threshold = threshold
        self.enabled = enabled
    }
}

public enum MenuBarStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    case icon, temperature, rpm, both
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .icon: "Icon only"
        case .temperature: "Temperature"
        case .rpm: "Fan speed"
        case .both: "Temperature + speed"
        }
    }
}

public enum TemperatureUnit: String, Codable, CaseIterable, Sendable, Identifiable {
    case celsius, fahrenheit
    public var id: String { rawValue }

    public func format(_ celsius: Double, decimals: Bool = false) -> String {
        let v = self == .celsius ? celsius : celsius * 9 / 5 + 32
        return decimals ? String(format: "%.1f°", v) : String(format: "%.0f°", v)
    }
}

extension Comparable {
    public func clamped(_ lo: Self, _ hi: Self) -> Self { min(max(self, lo), hi) }
}
