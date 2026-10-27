import Foundation

public struct Sample: Sendable, Hashable {
    public var date: Date
    public var value: Double
    public init(date: Date, value: Double) {
        self.date = date
        self.value = value
    }
}

/// Fixed-capacity time series. Older samples are downsampled so 24h of history fits in memory.
public struct History: Sendable {
    public private(set) var recent: [Sample] = []
    public private(set) var archive: [Sample] = []
    public let recentWindow: TimeInterval
    public let archiveWindow: TimeInterval
    public let archiveInterval: TimeInterval

    public init(recentWindow: TimeInterval = 600, archiveWindow: TimeInterval = 86_400, archiveInterval: TimeInterval = 30) {
        self.recentWindow = recentWindow
        self.archiveWindow = archiveWindow
        self.archiveInterval = archiveInterval
    }

    public mutating func append(_ value: Double, at date: Date = .now) {
        recent.append(Sample(date: date, value: value))
        if let first = recent.first, date.timeIntervalSince(first.date) > recentWindow {
            recent.removeFirst(recent.prefix { date.timeIntervalSince($0.date) > recentWindow }.count)
        }
        if archive.last.map({ date.timeIntervalSince($0.date) >= archiveInterval }) ?? true {
            archive.append(Sample(date: date, value: value))
            if let first = archive.first, date.timeIntervalSince(first.date) > archiveWindow {
                archive.removeFirst(archive.prefix { date.timeIntervalSince($0.date) > archiveWindow }.count)
            }
        }
    }

    /// Samples covering the last `window` seconds, at the best resolution available.
    public func samples(last window: TimeInterval, now: Date = .now) -> [Sample] {
        let source = window <= recentWindow ? recent : archive
        return source.filter { now.timeIntervalSince($0.date) <= window }
    }

    public var latest: Double? { recent.last?.value }
}

/// Fires each alert once when crossed, re-arming after the sensor cools 3° below the threshold.
public struct AlertEvaluator: Sendable {
    private var firing: Set<UUID> = []
    public let rearmMargin: Double

    public init(rearmMargin: Double = 3) { self.rearmMargin = rearmMargin }

    public mutating func evaluate(_ rules: [AlertRule], temperatures: [String: Double]) -> [AlertRule] {
        var triggered: [AlertRule] = []
        for rule in rules where rule.enabled {
            guard let t = temperatures[rule.sensorID] else { continue }
            if t >= rule.threshold, !firing.contains(rule.id) {
                firing.insert(rule.id)
                triggered.append(rule)
            } else if t < rule.threshold - rearmMargin {
                firing.remove(rule.id)
            }
        }
        return triggered
    }
}
