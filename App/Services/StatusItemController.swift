import AppKit
import FanCore
import Observation
import SwiftUI

/// Owns the menu bar item. Drawn directly with AppKit (cheap to update), and the popover's
/// SwiftUI content exists only while the popover is open.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    private let actions: AppActions
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var renderedTitle: String?
    private var renderedSymbol: String?

    init(model: AppModel, actions: AppActions) {
        self.model = model
        self.actions = actions
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
            button.setAccessibilityTitle("Fan Control")
        }
        observe()
    }

    // MARK: Rendering

    /// Re-renders only when the values it reads change, and only touches AppKit when they differ.
    private func observe() {
        withObservationTracking {
            render(title: model.menuBarText, controlling: !model.controlledFans.isEmpty)
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
        } else if popover.isShown {
            closePopover()
        } else {
            showPopover(from: sender)
        }
    }

    private func showPopover(from button: NSStatusBarButton) {
        let hosting = NSHostingController(rootView: PopoverView().environment(model).environment(\.appActions, actions))
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        model.uiDidAppear()
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func closePopover() {
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
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
