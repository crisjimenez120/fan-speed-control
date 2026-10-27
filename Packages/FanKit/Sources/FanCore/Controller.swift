import Foundation

public struct FanLimits: Sendable, Hashable {
    public var min: Double
    public var max: Double
    public init(min: Double, max: Double) {
        self.min = min
        self.max = max
    }

    public func rpm(forPercent p: Double) -> Double {
        min + (max - min) * p.clamped(0, 100) / 100
    }
}

/// Computes fan targets from a mode and current temperatures.
///
/// Stateful per fan: smooths temperatures, holds RPM through small dips (hysteresis),
/// and ramps down gradually so fans don't pulse.
public struct FanController: Sendable {
    public var smoothing: Double
    public var hysteresis: Double
    public var rampDownPerTick: Double

    private var smoothedTemp: [String: Double] = [:]
    private var lastTarget: [Int: Double] = [:]
    private var tempAtLastRaise: [Int: Double] = [:]

    public init(smoothing: Double = 0.35, hysteresis: Double = 2.0, rampDownPerTick: Double = 120) {
        self.smoothing = smoothing
        self.hysteresis = hysteresis
        self.rampDownPerTick = rampDownPerTick
    }

    /// Returns the RPM to command, or nil for "hand back to macOS".
    public mutating func target(fan: Int, mode: FanMode, limits: FanLimits, temperatures: [String: Double]) -> Double? {
        switch mode {
        case .auto:
            reset(fan: fan)
            return nil
        case .fixed(let rpm):
            let t = rpm.clamped(limits.min, limits.max)
            lastTarget[fan] = t
            return t
        case .sensor(let id, let low, let high):
            guard let temp = smoothed(id, temperatures[id]) else { return failSafe(fan: fan, limits: limits) }
            let span = high - low
            let p = span > 0 ? (temp - low) / span * 100 : (temp >= high ? 100 : 0)
            return settle(fan: fan, desired: limits.rpm(forPercent: p), temp: temp, limits: limits)
        case .curve(let id, let curve):
            guard let temp = smoothed(id, temperatures[id]) else { return failSafe(fan: fan, limits: limits) }
            return settle(fan: fan, desired: limits.rpm(forPercent: curve.percent(at: temp)), temp: temp, limits: limits)
        }
    }

    public mutating func reset(fan: Int) {
        lastTarget[fan] = nil
        tempAtLastRaise[fan] = nil
    }

    private mutating func smoothed(_ id: String, _ raw: Double?) -> Double? {
        guard let raw else { return nil }
        let next = smoothedTemp[id].map { $0 + (raw - $0) * smoothing } ?? raw
        smoothedTemp[id] = next
        return next
    }

    /// If the driving sensor disappears, run at max rather than guessing.
    private mutating func failSafe(fan: Int, limits: FanLimits) -> Double {
        lastTarget[fan] = limits.max
        return limits.max
    }

    private mutating func settle(fan: Int, desired: Double, temp: Double, limits: FanLimits) -> Double {
        let desired = desired.clamped(limits.min, limits.max)
        guard let prev = lastTarget[fan] else {
            lastTarget[fan] = desired
            tempAtLastRaise[fan] = temp
            return desired
        }
        let next: Double
        if desired >= prev {
            next = desired
            tempAtLastRaise[fan] = temp
        } else if let raisedAt = tempAtLastRaise[fan], temp > raisedAt - hysteresis {
            next = prev
        } else {
            next = max(desired, prev - rampDownPerTick)
        }
        lastTarget[fan] = next
        return next
    }
}
