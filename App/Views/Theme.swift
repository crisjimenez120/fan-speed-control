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

/// A tiny line-and-fill graph drawn as one path. Swift Charts is far heavier than this needs,
/// and the sensor list shows dozens of these at once.
struct Sparkline: View {
    let samples: [Sample]
    let color: Color

    var body: some View {
        Canvas { context, size in
            guard samples.count > 1, let first = samples.first, let last = samples.last else { return }
            let values = samples.map(\.value)
            let lo = values.min()! - 2, hi = values.max()! + 2
            let t0 = first.date.timeIntervalSinceReferenceDate
            let span = max(last.date.timeIntervalSinceReferenceDate - t0, 1)
            func point(_ s: Sample) -> CGPoint {
                CGPoint(x: (s.date.timeIntervalSinceReferenceDate - t0) / span * size.width,
                        y: size.height - (s.value - lo) / (hi - lo) * size.height)
            }
            var line = Path()
            line.addLines(samples.map(point))
            var fill = line
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()
            context.fill(fill, with: .linearGradient(
                Gradient(colors: [color.opacity(0.35), color.opacity(0)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }
}

extension Array where Element == Sample {
    /// Averages into at most `count` buckets, so long ranges chart quickly without visible loss.
    func downsampled(to count: Int) -> [Sample] {
        guard self.count > count, count > 0 else { return self }
        let size = Double(self.count) / Double(count)
        return (0..<count).map { i in
            let slice = self[Int(Double(i) * size)..<Swift.min(Int(Double(i + 1) * size), self.count)]
            return Sample(date: slice[slice.startIndex + slice.count / 2].date,
                          value: slice.reduce(0) { $0 + $1.value } / Double(slice.count))
        }
    }
}

/// Horizontal bar showing where the fan sits between its min and max RPM. The fill is a
/// Core Animation layer, so it glides between readings without any SwiftUI per-frame work.
struct RPMBar: View {
    let fan: FanInfo

    var body: some View {
        let load = ((fan.currentRPM - fan.minRPM) / max(fan.maxRPM - fan.minRPM, 1)).clamped(0, 1)
        AnimatedBarView(fraction: load, endColor: NSColor(Theme.color(forLoad: load)))
            .frame(height: 6)
    }
}

private struct AnimatedBarView: NSViewRepresentable {
    let fraction: Double
    let endColor: NSColor

    func makeNSView(context: Context) -> BarView { BarView() }
    func updateNSView(_ view: BarView, context: Context) { view.set(fraction: fraction, endColor: endColor) }

    final class BarView: NSView {
        private let track = CALayer()
        private let fill = CAGradientLayer()
        private var fraction: Double = 0
        private var endColor: NSColor = .systemTeal

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.addSublayer(track)
            track.addSublayer(fill)
            fill.startPoint = CGPoint(x: 0, y: 0.5)
            fill.endPoint = CGPoint(x: 1, y: 0.5)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            track.frame = bounds
            track.cornerRadius = bounds.height / 2
            fill.cornerRadius = bounds.height / 2
            fill.frame = fillFrame
            CATransaction.commit()
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            applyColors()
        }

        private var fillFrame: CGRect {
            CGRect(x: 0, y: 0, width: max(bounds.height, bounds.width * fraction), height: bounds.height)
        }

        func set(fraction: Double, endColor: NSColor) {
            let colorChanged = endColor != self.endColor
            self.fraction = fraction
            self.endColor = endColor
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.8)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
            fill.frame = fillFrame
            if colorChanged { applyColors() }
            CATransaction.commit()
        }

        private func applyColors() {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                track.backgroundColor = NSColor.quaternaryLabelColor.cgColor
                fill.colors = [NSColor.systemTeal.cgColor, endColor.cgColor]
            }
        }
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

/// Sensor menu. Items come from the stable sensor catalog (names only, no live values) and the
/// view is Equatable, so the menu isn't rebuilt on every refresh.
struct SensorPicker: View, Equatable {
    @Environment(AppModel.self) private var model
    let title: String
    let selection: String
    /// Hash of whatever `onChange` captures. Re-render when it changes so the closure is never stale.
    var context: Int = 0
    let onChange: @MainActor (String) -> Void

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.title == b.title && a.selection == b.selection && a.context == b.context
    }

    var body: some View {
        let popUp = SensorPopUp(catalog: model.sensorCatalog, selection: selection, onChange: onChange)
        if title.isEmpty {
            popUp
        } else {
            LabeledContent(title) { popUp }
        }
    }
}

/// An AppKit pop-up whose menu is built only when it opens. A SwiftUI `Picker` keeps a live view
/// for every option, which for ~90 sensors per picker was most of the panel's memory.
private struct SensorPopUp: NSViewRepresentable {
    let catalog: [SensorReading]
    let selection: String
    let onChange: @MainActor (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.controlSize = .regular
        button.menu?.delegate = context.coordinator
        context.coordinator.button = button
        button.target = context.coordinator
        button.action = #selector(Coordinator.picked(_:))
        button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        let c = context.coordinator
        c.catalog = catalog
        c.selection = selection
        c.onChange = onChange
        c.showSelection(in: button)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }

    @MainActor
    final class Coordinator: NSObject, NSMenuDelegate {
        var catalog: [SensorReading] = []
        var selection = ""
        var onChange: @MainActor (String) -> Void = { _ in }
        weak var button: NSPopUpButton?
        private var shown: String?

        /// Until first opened, the menu holds just the selected item so the button can show its title.
        /// Afterwards the full list (plain menu items, cheap) stays until the selection changes.
        func showSelection(in button: NSPopUpButton) {
            let title = catalog.first { $0.id == selection }?.name ?? "Unavailable sensor"
            guard shown != title else { return }
            shown = title
            button.removeAllItems()
            button.addItem(withTitle: title)
            button.lastItem?.representedObject = selection
            button.invalidateIntrinsicContentSize()
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            let grouped = Dictionary(grouping: catalog, by: \.group)
            for group in grouped.keys.sorted() {
                menu.addItem(.sectionHeader(title: group.rawValue))
                for s in grouped[group]!.sorted(by: { ($0.isSummary ? 0 : 1, $0.name) < ($1.isSummary ? 0 : 1, $1.name) }) {
                    let item = NSMenuItem(title: s.name, action: nil, keyEquivalent: "")
                    item.representedObject = s.id
                    menu.addItem(item)
                }
            }
            if !catalog.contains(where: { $0.id == selection }) {
                menu.addItem(withTitle: "Unavailable sensor", action: nil, keyEquivalent: "").representedObject = selection
            }
            if let index = menu.items.firstIndex(where: { $0.representedObject as? String == selection }) {
                button?.selectItem(at: index)
            }
        }

        @objc func picked(_ sender: NSPopUpButton) {
            guard let id = sender.selectedItem?.representedObject as? String, id != selection else { return }
            selection = id
            onChange(id)
        }
    }
}

/// Sensor picker plus the sensor's current reading.
struct SensorPickerRow: View {
    @Environment(AppModel.self) private var model
    let selection: String
    var context: Int = 0
    let onChange: @MainActor (String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            SensorPicker(title: "Sensor", selection: selection, context: context, onChange: onChange)
                .equatable()
                .labelsHidden()
                .fixedSize()
            Text(model.format(model.sensorsByID[selection]?.celsius))
                .monospacedDigit()
                .foregroundStyle(model.sensorsByID[selection].map { Theme.color(forCelsius: $0.celsius) } ?? .secondary)
            Spacer(minLength: 0)
        }
    }
}
