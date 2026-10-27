import AppKit
import SwiftUI

@main
struct FanControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // The status item, popover, and main window are AppKit-managed (see AppDelegate),
        // so SwiftUI only does work while something is actually on screen.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel!
    private var statusItem: StatusItemController!
    private var mainWindow: MainWindowController!
    private var previewWindows: [NSWindow] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = AppModel()
        let actions = AppActions()
        mainWindow = MainWindowController(model: model, actions: actions)
        statusItem = StatusItemController(model: model, actions: actions)
        actions.openMain = { [weak self] section in
            self?.statusItem.closePopover()
            self?.mainWindow.show(section)
        }
        if UserDefaults.standard.bool(forKey: "FCPreviewPopover") { showPreview(actions) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        mainWindow.show(nil)
        return false
    }

    /// `-FCPreviewPopover YES [-FCPreviewSection fans]` renders the UI into PNGs in /tmp, for screenshots.
    private func showPreview(_ actions: AppActions) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
            let popover = NSWindow(contentViewController: NSHostingController(rootView: PopoverView().environment(model).environment(\.appActions, actions)))
            popover.title = "Fan Control Popover Preview"
            popover.makeKeyAndOrderFront(nil)
            previewWindows.append(popover)
            model.uiDidAppear()
            if let name = UserDefaults.standard.string(forKey: "FCPreviewSection"), let section = MainSection(rawValue: name) {
                mainWindow.show(section)
            }
            NSApp.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                for w in NSApp.windows where w.isVisible && w.frame.width > 200 {
                    Self.snapshot(w, to: "/tmp/fc-\(w.title.isEmpty ? "untitled" : w.title.replacingOccurrences(of: " ", with: "-")).png")
                }
            }
        }
    }

    private static func snapshot(_ window: NSWindow, to path: String) {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

/// App-level navigation available to SwiftUI views.
@MainActor
final class AppActions {
    var openMain: (MainSection?) -> Void = { _ in }
}

private struct AppActionsKey: EnvironmentKey {
    static let defaultValue: AppActions? = nil
}

extension EnvironmentValues {
    var appActions: AppActions? {
        get { self[AppActionsKey.self] }
        set { self[AppActionsKey.self] = newValue }
    }
}

@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let actions: AppActions
    private var window: NSWindow?

    init(model: AppModel, actions: AppActions) {
        self.model = model
        self.actions = actions
    }

    func show(_ section: MainSection?) {
        if let section { MainSection.pending = section }
        let w = window ?? makeWindow()
        if !w.isVisible { model.uiDidAppear() }
        NotificationCenter.default.post(name: .selectMainSection, object: nil)
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }

    /// Built once and kept: closing only hides it, so reopening is instant. While hidden the model
    /// doesn't publish, so its views do no work.
    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: MainWindow().environment(model).environment(\.appActions, actions))
        hosting.sceneBridgingOptions = [.toolbars, .title]
        let w = NSWindow(contentViewController: hosting)
        w.title = "Fan Control"
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        w.toolbarStyle = .unified
        w.setContentSize(NSSize(width: 980, height: 660))
        w.contentMinSize = NSSize(width: 820, height: 560)
        w.isReleasedWhenClosed = false
        w.delegate = self
        if !w.setFrameUsingName("FanControlMain") { w.center() }
        w.setFrameAutosaveName("FanControlMain")
        window = w
        return w
    }

    func windowWillClose(_ notification: Notification) {
        model.uiDidDisappear()
    }
}

extension Notification.Name {
    static let selectMainSection = Notification.Name("FanControl.selectMainSection")
}
