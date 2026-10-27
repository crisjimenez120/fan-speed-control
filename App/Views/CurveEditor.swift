import Charts
import FanCore
import SwiftUI

/// Interactive temperature → fan speed curve. Drag points, click empty space to add, select and delete to remove.
struct CurveEditor: View {
    let curve: FanCurve
    let onChange: (FanCurve) -> Void
    var currentTemp: Double?
    var limits: FanLimits?
    var unit: TemperatureUnit = .celsius

    @State private var selected: UUID?
    @State private var dragging: UUID?
    /// The curve as it's being dragged. Committed at most 5×/s and on release.
    @State private var draft: FanCurve?
    @State private var lastCommit = Date.distantPast

    private var shown: FanCurve { draft ?? curve }

    private let tempRange: ClosedRange<Double> = 20...110

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            chart
                .frame(minHeight: 220)
            controls
        }
    }

    private var points: [CurvePoint] { shown.points.sorted { $0.temperature < $1.temperature } }

    private var chart: some View {
        Chart {
            ForEach(points) { p in
                AreaMark(x: .value("Temp", p.temperature), y: .value("Speed", p.percent))
                    .foregroundStyle(LinearGradient(colors: [.orange.opacity(0.28), .teal.opacity(0.05)], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Temp", p.temperature), y: .value("Speed", p.percent))
                    .foregroundStyle(Theme.heat)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            }
            ForEach(points) { p in
                PointMark(x: .value("Temp", p.temperature), y: .value("Speed", p.percent))
                    .symbolSize(p.id == selected || p.id == dragging ? 220 : 110)
                    .foregroundStyle(Theme.color(forCelsius: p.temperature))
                    .annotation(position: .top, spacing: 6) {
                        if p.id == selected || p.id == dragging {
                            Text("\(unit.format(p.temperature)) · \(Int(p.percent))%")
                                .font(.caption2.monospacedDigit().weight(.semibold))
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(.regularMaterial, in: Capsule())
                        }
                    }
            }
            if let t = currentTemp {
                RuleMark(x: .value("Now", t.clamped(tempRange.lowerBound, tempRange.upperBound)))
                    .foregroundStyle(.secondary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .center) {
                        Text("Now \(unit.format(t))").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                    }
                PointMark(x: .value("Now", t.clamped(tempRange.lowerBound, tempRange.upperBound)), y: .value("Speed", shown.percent(at: t)))
                    .symbol(.circle)
                    .symbolSize(60)
                    .foregroundStyle(.white)
            }
        }
        .chartXScale(domain: tempRange)
        .chartYScale(domain: 0...100)
        .chartXAxis {
            AxisMarks(values: .stride(by: 10)) { v in
                AxisGridLine().foregroundStyle(.separator.opacity(0.4))
                AxisValueLabel { if let d = v.as(Double.self) { Text(unit.format(d)) } }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { v in
                AxisGridLine().foregroundStyle(.separator.opacity(0.4))
                AxisValueLabel {
                    if let d = v.as(Double.self) {
                        if let limits { Text(limits.rpm(forPercent: d).rpmString) } else { Text("\(Int(d))%") }
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in drag(value, proxy: proxy, geo: geo) }
                            .onEnded { value in endDrag(value, proxy: proxy, geo: geo) }
                    )
            }
        }
        .animation(.snappy(duration: 0.2), value: selected)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            if let id = selected, let p = points.first(where: { $0.id == id }) {
                Stepper("\(unit.format(p.temperature))", value: Binding(
                    get: { p.temperature },
                    set: { update(id, temperature: $0, percent: p.percent) }
                ), in: tempRange, step: 1)
                .monospacedDigit()
                Stepper("\(Int(p.percent))%", value: Binding(
                    get: { p.percent },
                    set: { update(id, temperature: p.temperature, percent: $0) }
                ), in: 0...100, step: 5)
                .monospacedDigit()
                Button(role: .destructive) { remove(id) } label: { Label("Remove", systemImage: "trash") }
                    .disabled(points.count <= 2)
                    .keyboardShortcut(.delete, modifiers: [])
            } else {
                Text("Drag points to shape the curve. Click empty space to add one.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Menu("Presets") {
                Button("Silent") { onChange(Self.silent) }
                Button("Balanced") { onChange(.balanced) }
                Button("Aggressive") { onChange(Self.aggressive) }
            }
            .fixedSize()
        }
        .controlSize(.small)
    }

    static let silent = FanCurve(points: [.init(temperature: 55, percent: 0), .init(temperature: 75, percent: 15), .init(temperature: 88, percent: 45), .init(temperature: 98, percent: 100)])
    static let aggressive = FanCurve(points: [.init(temperature: 40, percent: 10), .init(temperature: 55, percent: 40), .init(temperature: 70, percent: 75), .init(temperature: 80, percent: 100)])

    // MARK: Gestures

    private func plotPoint(_ location: CGPoint, proxy: ChartProxy, geo: GeometryProxy) -> CGPoint? {
        guard let anchor = proxy.plotFrame else { return nil }
        let frame = geo[anchor]
        return CGPoint(x: location.x - frame.origin.x, y: location.y - frame.origin.y)
    }

    private func nearest(to loc: CGPoint, proxy: ChartProxy) -> UUID? {
        var best: (UUID, CGFloat)?
        for p in points {
            guard let pos = proxy.position(for: (x: p.temperature, y: p.percent)) else { continue }
            let d = hypot(pos.x - loc.x, pos.y - loc.y)
            if d < 18, d < (best?.1 ?? .infinity) { best = (p.id, d) }
        }
        return best?.0
    }

    private func drag(_ value: DragGesture.Value, proxy: ChartProxy, geo: GeometryProxy) {
        guard let loc = plotPoint(value.location, proxy: proxy, geo: geo) else { return }
        if dragging == nil {
            guard let start = plotPoint(value.startLocation, proxy: proxy, geo: geo),
                  let hit = nearest(to: start, proxy: proxy) else { return }
            dragging = hit
            selected = hit
        }
        guard let id = dragging,
              let t: Double = proxy.value(atX: loc.x),
              let pct: Double = proxy.value(atY: loc.y) else { return }
        update(id, temperature: t.rounded(), percent: pct.rounded(), live: true)
    }

    private func endDrag(_ value: DragGesture.Value, proxy: ChartProxy, geo: GeometryProxy) {
        defer { dragging = nil }
        if let d = draft {
            onChange(d)
            draft = nil
            return
        }
        guard dragging == nil, hypot(value.translation.width, value.translation.height) < 3,
              let loc = plotPoint(value.location, proxy: proxy, geo: geo) else { return }
        guard let t: Double = proxy.value(atX: loc.x), let pct: Double = proxy.value(atY: loc.y),
              tempRange.contains(t) else {
            selected = nil
            return
        }
        if points.contains(where: { abs($0.temperature - t) < 2 }) {
            selected = nil
            return
        }
        let p = CurvePoint(temperature: t.rounded(), percent: pct.rounded().clamped(0, 100))
        onChange(FanCurve(points: curve.points + [p]))
        selected = p.id
    }

    /// Moves a point, keeping it between its neighbors so the curve stays a function.
    private func update(_ id: UUID, temperature: Double, percent: Double, live: Bool = false) {
        let sorted = points
        guard let i = sorted.firstIndex(where: { $0.id == id }) else { return }
        let lo = i > 0 ? sorted[i - 1].temperature + 1 : tempRange.lowerBound
        let hi = i < sorted.count - 1 ? sorted[i + 1].temperature - 1 : tempRange.upperBound
        var pts = sorted
        pts[i].temperature = temperature.clamped(lo, max(lo, hi))
        pts[i].percent = percent.clamped(0, 100)
        let next = FanCurve(points: pts)
        guard live else { return onChange(next) }
        draft = next
        if Date().timeIntervalSince(lastCommit) > 0.2 {
            lastCommit = Date()
            onChange(next)
        }
    }

    private func remove(_ id: UUID) {
        guard points.count > 2 else { return }
        onChange(FanCurve(points: curve.points.filter { $0.id != id }))
        selected = nil
    }
}

/// Non-interactive thumbnail of a curve.
struct CurveThumbnail: View {
    let curve: FanCurve
    var currentTemp: Double?

    var body: some View {
        Chart {
            ForEach(curve.points.sorted { $0.temperature < $1.temperature }) { p in
                AreaMark(x: .value("T", p.temperature), y: .value("P", p.percent))
                    .foregroundStyle(LinearGradient(colors: [.orange.opacity(0.25), .clear], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("T", p.temperature), y: .value("P", p.percent))
                    .foregroundStyle(Theme.heat)
            }
            if let t = currentTemp {
                PointMark(x: .value("T", t.clamped(20, 110)), y: .value("P", curve.percent(at: t)))
                    .symbolSize(30).foregroundStyle(.primary)
            }
        }
        .chartXScale(domain: 20...110)
        .chartYScale(domain: 0...100)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
    }
}
