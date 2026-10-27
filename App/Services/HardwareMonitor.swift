import Foundation
import SMCKit

struct HardwareSnapshot: Sendable {
    var fans: [FanInfo]
    var sensors: [SensorReading]
}

/// Owns the SMC reader off the main thread.
actor HardwareMonitor {
    private let reader: HardwareReader?

    init() {
        reader = try? HardwareReader()
    }

    var isAvailable: Bool { reader != nil }

    func snapshot() -> HardwareSnapshot {
        guard let reader else { return HardwareSnapshot(fans: [], sensors: []) }
        return HardwareSnapshot(fans: reader.readFans(), sensors: reader.readSensors())
    }
}
