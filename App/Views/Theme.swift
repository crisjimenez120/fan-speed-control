import Charts
import FanCore
import SMCKit
import SwiftUI

enum Theme {
    /// Cool → hot color for a temperature in °C.
    static func color(forCelsius t: Double) -> Color {
        switch t {
        case ..<50: .teal
        case ..<65: .green
        case ..<78: .yellow
        case ..<88: .orange
        default: .red
        }
    }

    static func color(forLoad load: Double) -> Color {
        switch load {
        case ..<0.25: .teal
        case ..<0.5: .blue
        case ..<0.75: .orange
        default: .red
        }
    }

    static let heat = LinearGradient(colors: [.teal, .green, .yellow, .orange, .red], startPoint: .leading, endPoint: .trailing)
    static let heatVertical = LinearGradient(colors: [.teal, .green, .yellow, .orange, .red], startPoint: .bottom, endPoint: .top)
}

extension Double {
    var rpmString: String { formatted(.number.precision(.fractionLength(0)).grouping(.automatic)) }
}

/// Rounded card used throughout.
struct Card<Content: View>: View {
    var padding: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
    }
}

struct Sparkline: View {
    let samples: [Sample]
    let color: Color

    var body: some View {
        Chart(samples, id: \.date) { s in
            AreaMark(x: .value("t", s.date), yStart: .value("min", lower), yEnd: .value("v", s.value))
                .foregroundStyle(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.0)], startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.monotone)
            LineMark(x: .value("t", s.date), y: .value("v", s.value))
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .interpolationMethod(.monotone)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: lower...upper)
        .chartLegend(.hidden)
    }

    private var lower: Double { (samples.map(\.value).min() ?? 0) - 2 }
    private var upper: Double { (samples.map(\.value).max() ?? 1) + 2 }
}

/// Horizontal bar showing where the fan sits between its min and max RPM.
struct RPMBar: View {
    let fan: FanInfo

    var body: some View {
        let load = ((fan.currentRPM - fan.minRPM) / max(fan.maxRPM - fan.minRPM, 1)).clamped(0, 1)
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.fill.tertiary)
                Capsule()
                    .fill(LinearGradient(colors: [.teal, Theme.color(forLoad: load)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(6, geo.size.width * load))
                    .animation(.smooth(duration: 0.6), value: load)
            }
        }
        .frame(height: 6)
    }
}

/// A fan glyph that spins at a speed proportional to RPM.
struct SpinningFan: View {
    let rpm: Double
    var size: CGFloat = 22
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || rpm < 1)) { context in
            // Visual speed, not literal: ~0.5 rev/s at 1200 RPM up to ~2.5 rev/s at 6000.
            let revsPerSecond = rpm / 2400
            let angle = context.date.timeIntervalSinceReferenceDate * revsPerSecond * 360
            Image(systemName: "fan.fill")
                .font(.system(size: size, weight: .medium))
                .rotationEffect(.degrees(reduceMotion ? 0 : angle.truncatingRemainder(dividingBy: 360)))
        }
        .frame(width: size + 4, height: size + 4)
    }
}

struct SensorPicker: View {
    @Environment(AppModel.self) private var model
    let title: String
    let selection: String
    let onChange: @MainActor (String) -> Void

    var body: some View {
        Picker(title, selection: Binding(get: { selection }, set: onChange)) {
            let grouped = Dictionary(grouping: model.sensors, by: \.group)
            ForEach(grouped.keys.sorted(), id: \.self) { group in
                Section(group.rawValue) {
                    ForEach(grouped[group]!.sorted { ($0.isSummary ? 0 : 1, $0.name) < ($1.isSummary ? 0 : 1, $1.name) }) { s in
                        Text("\(s.name)  \(model.format(s.celsius))").tag(s.id)
                    }
                }
            }
            if model.sensorsByID[selection] == nil {
                Text("Unavailable sensor").tag(selection)
            }
        }
    }
}
