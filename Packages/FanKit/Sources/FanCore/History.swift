import Foundation

public struct Sample: Sendable, Hashable {
    public var date: Date
    public var value: Double
    public init(date: Date, value: Double) {
        self.date = date
        self.value = value
    }
}

/// Fixed-capacity circular buffer: O(1) append, no reallocation once full.
struct Ring<Element: Sendable>: Sendable {
    private var storage: [Element] = []
    private var head = 0
    let capacity: Int

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        storage.reserveCapacity(self.capacity)
    }

    var count: Int { storage.count }
    var last: Element? { storage.isEmpty ? nil : storage[(head + storage.count - 1) % storage.count] }

    mutating func append(_ e: Element) {
        if storage.count < capacity {
            storage.append(e)
        } else {
            storage[head] = e
            head = (head + 1) % capacity
        }
    }

    /// Elements oldest → newest.
    var elements: [Element] {
        head == 0 ? storage : Array(storage[head...] + storage[..<head])
    }
}

/// Two-resolution time series: a fine-grained recent window plus a downsampled 24h archive.
public struct History: Sendable {
    private var recentRing: Ring<Sample>
    private var archiveRing: Ring<Sample>
    public let recentWindow: TimeInterval
    public let archiveWindow: TimeInterval
    public let archiveInterval: TimeInterval

    /// `minimumSpacing` is the fastest expected sample rate; it sizes the recent buffer.
    public init(recentWindow: TimeInterval = 600, archiveWindow: TimeInterval = 86_400,
                archiveInterval: TimeInterval = 30, minimumSpacing: TimeInterval = 1) {
        self.recentWindow = recentWindow
        self.archiveWindow = archiveWindow
        self.archiveInterval = archiveInterval
        recentRing = Ring(capacity: Int((recentWindow / minimumSpacing).rounded(.up)) + 1)
        archiveRing = Ring(capacity: Int((archiveWindow / archiveInterval).rounded(.up)) + 1)
    }

    public mutating func append(_ value: Double, at date: Date = .now) {
        recentRing.append(Sample(date: date, value: value))
        if archiveRing.last.map({ date.timeIntervalSince($0.date) >= archiveInterval }) ?? true {
            archiveRing.append(Sample(date: date, value: value))
        }
    }

    public var recent: [Sample] { recentRing.elements }
    public var archive: [Sample] { archiveRing.elements }

    /// Samples covering the last `window` seconds, at the best resolution available.
    public func samples(last window: TimeInterval, now: Date = .now) -> [Sample] {
        let source = window <= recentWindow ? recentRing.elements : archiveRing.elements
        guard let start = source.firstIndex(where: { now.timeIntervalSince($0.date) <= window }) else { return [] }
        return Array(source[start...])
    }

    public var latest: Double? { recentRing.last?.value }
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
