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
            }
        }
        .frame(height: 6)
    }
}

/// A fan glyph that spins faster with RPM. The rotation is a Core Animation layer animation,
/// so the render server runs it and our process does no per-frame work.
struct SpinningFan: View {
    let rpm: Double
    var size: CGFloat = 22
    var tint: Color = .secondary
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Quantized so RPM jitter doesn't keep restarting the animation.
        let revsPerSecond = rpm < 1 || reduceMotion ? 0 : max(0.25, (rpm / 2400 * 4).rounded() / 4)
        SpinningSymbolView(symbol: "fan.fill", pointSize: size, revsPerSecond: revsPerSecond, tint: NSColor(tint))
            .frame(width: size + 4, height: size + 4)
    }
}

private struct SpinningSymbolView: NSViewRepresentable {
    let symbol: String
    let pointSize: CGFloat
    let revsPerSecond: Double
    let tint: NSColor

    func makeNSView(context: Context) -> SpinnerView { SpinnerView() }

    func updateNSView(_ view: SpinnerView, context: Context) {
        view.tint = tint
        view.configure(symbol: symbol, pointSize: pointSize, revsPerSecond: revsPerSecond)
    }

    final class SpinnerView: NSView {
        private let imageLayer = CALayer()
        private var symbol = ""
        private var pointSize: CGFloat = 0
        private var revsPerSecond: Double = -1

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.addSublayer(imageLayer)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            imageLayer.bounds = bounds
            imageLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
            CATransaction.commit()
        }

        // Dynamic colors (e.g. secondary label) resolve differently in light and dark mode.
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            renderImage()
        }

        func configure(symbol: String, pointSize: CGFloat, revsPerSecond: Double) {
            if symbol != self.symbol || pointSize != self.pointSize {
                self.symbol = symbol
                self.pointSize = pointSize
                renderImage()
            }
            guard revsPerSecond != self.revsPerSecond else { return }
            self.revsPerSecond = revsPerSecond
            // Continue from the current angle so speed changes don't jump.
            let current = (imageLayer.presentation()?.value(forKeyPath: "transform.rotation.z") as? Double) ?? 0
            imageLayer.removeAnimation(forKey: "spin")
            imageLayer.setValue(current, forKeyPath: "transform.rotation.z")
            guard revsPerSecond > 0 else { return }
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.byValue = -2 * Double.pi
            spin.duration = 1 / revsPerSecond
            spin.repeatCount = .infinity
            spin.isAdditive = true
            imageLayer.add(spin, forKey: "spin")
        }

        private func renderImage() {
            guard pointSize > 0 else { return }
            var resolved = tint
            effectiveAppearance.performAsCurrentDrawingAppearance { resolved = tint.usingColorSpace(.sRGB) ?? tint }
            let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
                .applying(.init(paletteColors: [resolved]))
            guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
            imageLayer.contents = image
            imageLayer.contentsGravity = .center
            imageLayer.contentsScale = window?.backingScaleFactor ?? 2
        }

        var tint: NSColor = .secondaryLabelColor {
            didSet { if tint != oldValue { renderImage() } }
        }
    }
}

/// Reports whether the hosting window is on screen. The menu bar popover's window stays alive
/// when closed, so this lets us stop rendering it.
struct WindowVisibilityReader: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ObserverView {
        let v = ObserverView()
        v.onChange = onChange
        return v
    }

    func updateNSView(_ view: ObserverView, context: Context) { view.onChange = onChange }

    final class ObserverView: NSView {
        var onChange: ((Bool) -> Void)?
        private var token: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let token { NotificationCenter.default.removeObserver(token) }
            guard let window else { return }
            token = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
            report()
        }

        private func report() {
            onChange?(window?.occlusionState.contains(.visible) ?? false)
        }
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
