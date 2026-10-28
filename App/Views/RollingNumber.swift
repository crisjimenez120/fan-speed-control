import AppKit
import SwiftUI

/// A live number whose changed digits roll in with a blur, like SwiftUI's numeric text transition,
/// but driven entirely by Core Animation: the render server runs every frame, so a roll costs the
/// app nothing per frame and never re-lays out the surrounding view.
///
/// Display hysteresis keeps sensor jitter from triggering rolls: the shown value only moves once
/// the reading has moved by at least `threshold`.
struct RollingNumber: View {
    let value: Double
    let threshold: Double
    var size: CGFloat = 13
    var weight: NSFont.Weight = .semibold
    var color: Color = .primary
    let format: (Double) -> String

    var body: some View {
        let font = Self.font(size: size, weight: weight)
        let baseline = ceil(font.ascender)
        RollingDigits(value: value, threshold: threshold, font: font, color: NSColor(color), format: format)
            // SwiftUI doesn't read AppKit baselines, so declare it for neighbouring text like "RPM".
            .alignmentGuide(.firstTextBaseline) { _ in baseline }
            .alignmentGuide(.lastTextBaseline) { _ in baseline }
    }

    /// Rounded system font with monospaced digits, so digit slots have constant widths.
    static func font(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        let rounded = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
        let mono = rounded.addingAttributes([.featureSettings: [[
            NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
            NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
        ]]])
        return NSFont(descriptor: mono, size: size) ?? base
    }
}

private struct RollingDigits: NSViewRepresentable {
    let value: Double
    let threshold: Double
    let font: NSFont
    let color: NSColor
    let format: (Double) -> String

    func makeNSView(context: Context) -> RollingDigitsView { RollingDigitsView() }

    func updateNSView(_ view: RollingDigitsView, context: Context) {
        view.font = font
        view.color = color
        // Hysteresis: hold the shown value until the reading moves past the threshold.
        if let shown = view.shownValue, abs(value - shown) < threshold { return }
        let animated = view.shownValue != nil
        let rising = value >= (view.shownValue ?? value)
        view.shownValue = value
        view.setText(format(value), rising: rising, animated: animated)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: RollingDigitsView, context: Context) -> CGSize? {
        nsView.font = font
        return nsView.size(for: format(nsView.shownValue ?? value))
    }
}

final class RollingDigitsView: NSView {
    var shownValue: Double?
    var font: NSFont = .systemFont(ofSize: 13) {
        didSet { if font != oldValue { relayout() } }
    }
    var color: NSColor = .labelColor {
        didSet { if color != oldValue { recolor() } }
    }

    private var text = ""
    private var glyphs: [CATextLayer] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        layer?.masksToBounds = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }


    /// Width of `string` with every digit replaced by "8", so the size only changes with length.
    func size(for string: String) -> CGSize {
        let template = String(string.map { $0.isNumber ? "8" : $0 })
        let s = (template as NSString).size(withAttributes: [.font: font])
        return CGSize(width: ceil(s.width), height: ceil(font.ascender - font.descender))
    }

    func setText(_ new: String, rising: Bool, animated: Bool) {
        guard new != text else { return }
        let old = text
        text = new
        // Different lengths (e.g. 999 → 1,000) shift every slot, so roll the whole number.
        let sameShape = old.count == new.count
        let newChars = Array(new)
        let oldChars = Array(old)
        var next: [CATextLayer] = []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, ch) in newChars.enumerated() {
            if animated, sameShape, i < glyphs.count, oldChars[i] == ch {
                next.append(glyphs[i])
                continue
            }
            let glyph = makeGlyph(ch)
            layer?.addSublayer(glyph)
            next.append(glyph)
            if animated { rollIn(glyph, rising: rising) }
        }
        for old in glyphs where !next.contains(where: { $0 === old }) {
            if animated { rollOut(old, rising: rising) } else { old.removeFromSuperlayer() }
        }
        glyphs = next
        positionGlyphs()
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        positionGlyphs()
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        recolor()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        glyphs.forEach { $0.contentsScale = scale }
    }

    // MARK: Glyphs

    private func makeGlyph(_ ch: Character) -> CATextLayer {
        let t = CATextLayer()
        t.string = attributed(String(ch))
        t.contentsScale = window?.backingScaleFactor ?? 2
        t.alignmentMode = .center
        let blur = CIFilter(name: "CIGaussianBlur")!
        blur.name = "blur"
        blur.setValue(0, forKey: kCIInputRadiusKey)
        t.filters = [blur]
        return t
    }

    /// Right-aligned, each glyph at its natural advance.
    private func positionGlyphs() {
        let height = ceil(font.ascender - font.descender)
        var x = bounds.width
        for glyph in glyphs.reversed() {
            let ch = (glyph.string as? NSAttributedString)?.string ?? ""
            let w = ceil((ch as NSString).size(withAttributes: [.font: font]).width)
            x -= w
            glyph.bounds = CGRect(x: 0, y: 0, width: w, height: height)
            glyph.position = CGPoint(x: x + w / 2, y: (bounds.height - height) / 2 + height / 2)
        }
    }

    private static let duration: CFTimeInterval = 0.45
    private static let curve = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)

    private func rollIn(_ glyph: CATextLayer, rising: Bool) {
        let offset = font.pointSize * 0.55 * (rising ? 1 : -1)
        let group = CAAnimationGroup()
        group.animations = [
            from("transform.translation.y", offset),
            from("opacity", 0),
            from("filters.blur.inputRadius", font.pointSize * 0.18),
        ]
        group.duration = Self.duration
        group.timingFunction = Self.curve
        glyph.add(group, forKey: "rollIn")
    }

    private func rollOut(_ glyph: CATextLayer, rising: Bool) {
        let offset = font.pointSize * 0.55 * (rising ? -1 : 1)
        // Own transaction so each outgoing glyph gets its own removal callback.
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak glyph] in glyph?.removeFromSuperlayer() }
        glyph.opacity = 0
        glyph.setValue(offset, forKeyPath: "transform.translation.y")
        let group = CAAnimationGroup()
        group.animations = [
            fromTo("transform.translation.y", 0, offset),
            fromTo("opacity", 1, 0),
            fromTo("filters.blur.inputRadius", 0, font.pointSize * 0.18),
        ]
        group.duration = Self.duration * 0.8
        group.timingFunction = Self.curve
        glyph.add(group, forKey: "rollOut")
        CATransaction.commit()
    }

    private func from(_ keyPath: String, _ value: CGFloat) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: keyPath)
        a.fromValue = value
        return a
    }

    private func fromTo(_ keyPath: String, _ a: CGFloat, _ b: CGFloat) -> CABasicAnimation {
        let anim = CABasicAnimation(keyPath: keyPath)
        anim.fromValue = a
        anim.toValue = b
        return anim
    }

    private var resolvedColor: CGColor {
        var c = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { c = color.cgColor }
        return c
    }

    /// CATextLayer ignores `foregroundColor` for attributed strings, so color goes in the attributes.
    private func attributed(_ s: String) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: NSColor(cgColor: resolvedColor) ?? color])
    }

    private func recolor() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for glyph in glyphs {
            if let s = (glyph.string as? NSAttributedString)?.string { glyph.string = attributed(s) }
        }
        CATransaction.commit()
    }

    private func relayout() {
        let current = text
        text = ""
        glyphs.forEach { $0.removeFromSuperlayer() }
        glyphs = []
        setText(current, rising: true, animated: false)
    }
}
