import AppKit
import SwiftUI

/// The dropdown under the menu bar item: a borderless glass panel that is created once and only
/// shown or hidden, so opening it is instant. Closes on outside click, app switch, or Escape.
@MainActor
final class MenuBarPanel: NSPanel {
    var onClose: (() -> Void)?
    private var sizeObservation: NSKeyValueObservation?
    private var anchorTop: CGFloat = 0
    private var anchorMidX: CGFloat = 0

    init(content: NSHostingController<AnyView>) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none

        content.sizingOptions = .preferredContentSize
        let glass = NSGlassEffectView()
        glass.cornerRadius = 18
        glass.contentView = content.view
        contentViewController = content
        contentView = glass

        sizeObservation = content.observe(\.preferredContentSize, options: [.new]) { [weak self] _, change in
            guard let size = change.newValue else { return }
            MainActor.assumeIsolated { self?.resize(to: size) }
        }
    }

    override var canBecomeKey: Bool { true }

    /// Renders once offscreen so the first real show doesn't pay for backing stores, fonts, and charts.
    func prewarm() {
        guard let view = contentViewController?.view else { return }
        resize(to: view.fittingSize)
        contentView?.layoutSubtreeIfNeeded()
        contentView?.displayIfNeeded()
    }

    func show(below button: NSStatusBarButton) {
        guard let buttonWindow = button.window else { return }
        let rect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        anchorTop = rect.minY - 6
        anchorMidX = rect.midX
        resize(to: frame.size == .zero ? (contentViewController?.view.fittingSize ?? .zero) : frame.size)
        alphaValue = 0
        makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
    }

    func dismiss() {
        guard isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.alphaValue == 0 else { return }
                self.orderOut(nil)
                self.onClose?()
            }
        })
    }

    /// Keeps the panel's top edge pinned under the menu bar as the content grows or shrinks.
    private func resize(to size: NSSize) {
        guard size.width > 0, size.height > 0 else { return }
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: anchorMidX, y: anchorTop)) } ?? NSScreen.main
        var origin = CGPoint(x: anchorMidX - size.width / 2, y: anchorTop - size.height)
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        }
        setFrame(NSRect(origin: origin, size: size), display: true)
    }

    override func resignKey() {
        super.resignKey()
        // Picker menus track without taking key, so losing key means focus really left.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible, !self.isKeyWindow else { return }
            self.dismiss()
        }
    }

    override func cancelOperation(_ sender: Any?) { dismiss() }
}
