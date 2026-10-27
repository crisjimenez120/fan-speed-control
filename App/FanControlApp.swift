import AppKit
import SwiftUI

@main
struct FanControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environment(model)
                .onAppear { delegate.model = model }
        } label: {
            MenuBarLabel(model: model)
                .onAppear { delegate.model = model }
        }
        .menuBarExtraStyle(.window)

        Window("Fan Control", id: "main") {
            MainWindow()
                .environment(model)
                .frame(minWidth: 820, minHeight: 560)
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 980, height: 660)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    private var previewWindow: NSWindow?
    private var extraWindows: [NSWindow] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `-FCPreviewPopover YES` shows the popover in a normal window, for screenshots and debugging.
        guard UserDefaults.standard.bool(forKey: "FCPreviewPopover") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            MainActor.assumeIsolated {
                guard let model = self.model else { return }
                let window = NSWindow(contentViewController: NSHostingController(rootView: PopoverView().environment(model)))
                window.title = "Fan Control Popover Preview"
                window.makeKeyAndOrderFront(nil)
                NSApp.activate()
                self.previewWindow = window
                if let name = UserDefaults.standard.string(forKey: "FCPreviewSection"), let section = MainSection(rawValue: name) {
                    MainSection.pending = section
                    let main = NSWindow(contentViewController: NSHostingController(rootView: MainWindow().environment(model).frame(width: 1000, height: 680)))
                    main.title = "Main \(name)"
                    main.makeKeyAndOrderFront(nil)
                    self.extraWindows.append(main)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    for w in NSApp.windows where w.isVisible && w.contentView != nil && w.frame.width > 200 {
                        Self.snapshot(w, to: "/tmp/fc-\(w.title.isEmpty ? "untitled" : w.title.replacingOccurrences(of: " ", with: "-")).png")
                    }
                }
            }
        }
    }

    @MainActor private static func snapshot(_ window: NSWindow, to path: String) {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model?.shutdown() }
    }
}

/// Opens (or focuses) the main window. The app is a menu bar agent, so it must activate itself first.
@MainActor
struct OpenMainWindow {
    let openWindow: OpenWindowAction

    func callAsFunction(_ section: MainSection? = nil) {
        if let section { MainSection.pending = section }
        NSApp.activate()
        openWindow(id: "main")
        NotificationCenter.default.post(name: .selectMainSection, object: nil)
    }
}

extension Notification.Name {
    static let selectMainSection = Notification.Name("FanControl.selectMainSection")
}

extension EnvironmentValues {
    var openMain: OpenMainWindow { OpenMainWindow(openWindow: openWindow) }
}
