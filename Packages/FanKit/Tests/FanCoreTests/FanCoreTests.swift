import Foundation
import Testing
@testable import FanCore

struct CurveTests {
    @Test func interpolatesBetweenPoints() {
        let c = FanCurve(points: [.init(temperature: 40, percent: 0), .init(temperature: 80, percent: 100)])
        #expect(c.percent(at: 60) == 50)
        #expect(c.percent(at: 30) == 0)
        #expect(c.percent(at: 95) == 100)
    }

    @Test func sortsUnorderedPoints() {
        let c = FanCurve(points: [.init(temperature: 80, percent: 100), .init(temperature: 40, percent: 0)])
        #expect(c.percent(at: 50) == 25)
    }

    @Test func emptyCurveIsZero() {
        #expect(FanCurve(points: []).percent(at: 70) == 0)
    }
}

struct ControllerTests {
    let limits = FanLimits(min: 1200, max: 6000)

    @Test func autoReturnsNil() {
        var c = FanController()
        #expect(c.target(fan: 0, mode: .auto, limits: limits, temperatures: [:]) == nil)
    }

    @Test func fixedIsClamped() {
        var c = FanController()
        #expect(c.target(fan: 0, mode: .fixed(rpm: 100_000), limits: limits, temperatures: [:]) == 6000)
        #expect(c.target(fan: 0, mode: .fixed(rpm: 10), limits: limits, temperatures: [:]) == 1200)
    }

    @Test func sensorModeScalesLinearly() {
        var c = FanController()
        let rpm = c.target(fan: 0, mode: .sensor(sensorID: "t", lowTemp: 40, highTemp: 80), limits: limits, temperatures: ["t": 60])
        #expect(rpm == 3600)
    }

    @Test func missingSensorFailsSafeToMax() {
        var c = FanController()
        #expect(c.target(fan: 0, mode: .curve(sensorID: "gone", curve: .balanced), limits: limits, temperatures: [:]) == 6000)
    }

    @Test func holdsSpeedThroughSmallDipsThenRampsDown() {
        var c = FanController(smoothing: 1, hysteresis: 2, rampDownPerTick: 100)
        let mode = FanMode.sensor(sensorID: "t", lowTemp: 40, highTemp: 80)
        #expect(c.target(fan: 0, mode: mode, limits: limits, temperatures: ["t": 80]) == 6000)
        // 1° dip: within hysteresis, hold.
        #expect(c.target(fan: 0, mode: mode, limits: limits, temperatures: ["t": 79]) == 6000)
        // Big drop: ramp down by at most 100/tick.
        #expect(c.target(fan: 0, mode: mode, limits: limits, temperatures: ["t": 40]) == 5900)
    }

    @Test func raisesImmediately() {
        var c = FanController(smoothing: 1)
        let mode = FanMode.sensor(sensorID: "t", lowTemp: 40, highTemp: 80)
        _ = c.target(fan: 0, mode: mode, limits: limits, temperatures: ["t": 40])
        #expect(c.target(fan: 0, mode: mode, limits: limits, temperatures: ["t": 80]) == 6000)
    }
}

struct HistoryTests {
    @Test func trimsOldSamples() {
        var h = History(recentWindow: 10, archiveWindow: 100, archiveInterval: 5)
        let t0 = Date(timeIntervalSince1970: 0)
        for i in 0..<30 { h.append(Double(i), at: t0.addingTimeInterval(Double(i))) }
        #expect(h.recent.count == 11)
        #expect(h.archive.count == 6)
        #expect(h.latest == 29)
    }
}

struct AlertTests {
    @Test func firesOnceAndRearms() {
        var e = AlertEvaluator(rearmMargin: 3)
        let rule = AlertRule(sensorID: "t", threshold: 90)
        #expect(e.evaluate([rule], temperatures: ["t": 91]).count == 1)
        #expect(e.evaluate([rule], temperatures: ["t": 95]).isEmpty)
        #expect(e.evaluate([rule], temperatures: ["t": 86]).isEmpty)
        #expect(e.evaluate([rule], temperatures: ["t": 92]).count == 1)
    }
}

struct CodableTests {
    @Test func profileRoundTrips() throws {
        let p = Profile.builtIns(fanCount: 2, cpuSensorID: "cpu.max")
        let data = try JSONEncoder().encode(p)
        #expect(try JSONDecoder().decode([Profile].self, from: data) == p)
    }
}
