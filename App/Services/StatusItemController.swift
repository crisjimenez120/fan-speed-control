import AppKit
import FanCore
import Observation
import SwiftUI

/// Owns the menu bar item, drawn directly with AppKit because that's cheap to update. The popover's
/// SwiftUI content is built once and kept, so it opens instantly; while it's closed the model
/// stops publishing, so the hidden views cost nothing.
@MainActor
final class StatusItemController: NSObject {
    private let model: AppModel
    private let actions: AppActions
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private lazy var panel: MenuBarPanel = {
        let p = MenuBarPanel(content: hosting)
        p.onClose = { [weak self] in self?.panelDidClose() }
        return p
    }()
    /// When the panel just closed because the status item was clicked, don't immediately reopen it.
    private var lastClose = Date.distantPast
    private lazy var hosting: NSHostingController<AnyView> = {
        let h = NSHostingController(rootView: AnyView(PopoverView().environment(model).environment(\.appActions, actions)))
        h.sizingOptions = .preferredContentSize
        return h
    }()
    private var renderedTitle: String?
    private var renderedSymbol: String?

    init(model: AppModel, actions: AppActions) {
        self.model = model
        self.actions = actions
        super.init()
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
            button.setAccessibilityTitle("Fan Control")
        }
        observe()
        // Pay SwiftUI's first-build cost now rather than on the first click.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in panel.prewarm() }
    }

    // MARK: Rendering

    /// Re-renders only when the values it reads change, and only touches AppKit when they differ.
    private func observe() {
        withObservationTracking {
            render(title: model.menuBarFlash ?? model.menuBarText, controlling: !model.controlledFans.isEmpty)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func render(title: String, controlling: Bool) {
        guard let button = item.button else { return }
        let symbol = controlling ? "fan.fill" : "fan"
        if symbol != renderedSymbol {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Fan Control")?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
            image?.isTemplate = true
            button.image = image
            renderedSymbol = symbol
        }
        if title != renderedTitle {
            button.attributedTitle = title.isEmpty ? NSAttributedString() : NSAttributedString(
                string: " " + title,
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)]
            )
            renderedTitle = title
        }
    }

    // MARK: Interaction

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else if panel.isVisible {
            closePopover()
        } else if Date().timeIntervalSince(lastClose) > 0.25 {
            showPopover(from: sender)
        }
    }

    private func showPopover(from button: NSStatusBarButton) {
        model.uiDidAppear()
        button.highlight(true)
        panel.show(below: button)
    }

    func closePopover() {
        panel.dismiss()
    }

    private func panelDidClose() {
        lastClose = Date()
        item.button?.highlight(false)
        model.uiDidDisappear()
    }

    private func showMenu() {
        let menu = NSMenu()
        for p in model.config.profiles {
            let mi = NSMenuItem(title: p.name, action: #selector(applyProfile(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = p.id
            mi.image = NSImage(systemSymbolName: p.symbol, accessibilityDescription: nil)
            mi.state = p.id == model.config.activeProfileID ? .on : .off
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "All Fans Auto", action: #selector(allAuto), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open Fan Control…", action: #selector(openMain), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Fan Control", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func applyProfile(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let p = model.config.profiles.first(where: { $0.id == id }) else { return }
        model.apply(p)
    }

    @objc private func allAuto() { model.resetAllToAuto() }
    @objc private func openMain() { actions.openMain(nil) }
}
