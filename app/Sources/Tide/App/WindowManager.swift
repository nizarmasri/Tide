import AppKit
import Observation
import SwiftUI
import TideKit

/// Owns every window. Tide is an accessory (menu bar) app; it becomes a regular app with a
/// Dock icon only while the Downloads window is open (DESIGN.md §2 Activation).
@MainActor
final class WindowManager: WindowRouter {
    unowned(unsafe) var services: AppServices!
    weak var statusItem: StatusItemController?

    private var mainWindow: NSWindow?
    private var mainDelegate: WindowCloseObserver?
    private var addWindows: [UUID: NSWindow] = [:]
    private var importWindow: NSWindow?
    private var welcomeWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var observers: [WindowCloseObserver] = []

    // MARK: Main window

    override func showMain(select: TaskID? = nil) {
        let w = mainWindow ?? makeMainWindow()
        mainWindow = w
        if let id = select {
            services.windowState.selection = [id]
            services.windowState.inspectorShown = true
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
        services.model.surfaceAppeared("main")
        DialogHost.window = w
    }

    private func makeMainWindow() -> NSWindow {
        let root = MainWindowView().tideEnvironment(services)
        let host = NSHostingController(rootView: root)
        host.sceneBridgingOptions = [.toolbars, .title]
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 600),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.contentViewController = host
        w.setContentSize(NSSize(width: 980, height: 600))
        w.contentMinSize = NSSize(width: 640, height: 400)
        w.title = "Tide"
        w.toolbarStyle = .unified
        w.isReleasedWhenClosed = false
        w.setFrameAutosaveName("TideDownloads")
        if w.frame.origin == .zero { w.center() }
        w.tabbingMode = .disallowed

        let obs = WindowCloseObserver(window: w)
        obs.onClose = { [weak self] in
            guard let self else { return }
            self.services.model.surfaceDisappeared("main")
            self.services.windowState.endSearch(model: self.services.model)
            NSApp.setActivationPolicy(.accessory)
        }
        obs.onOcclusion = { [weak self] visible in
            guard let self else { return }
            if visible { self.services.model.surfaceAppeared("main") } else { self.services.model.surfaceDisappeared("main") }
        }
        obs.onKey = { [weak self] key in self?.services.windowState.isKey = key }
        mainDelegate = obs
        return w
    }

    var isMainWindowVisible: Bool { mainWindow?.isVisible ?? false }

    // MARK: Search

    /// The Search view of the main window, with the cursor in its search bar.
    override func showSearch() {
        showMain()
        services.windowState.focusSearch(model: services.model)
    }

    // MARK: Add

    override func showAdd(_ inputs: [AddInput]) {
        services.model.requestAdd(inputs)
    }

    /// Called by AppModel.openAddWindow for each request.
    func openAddWindow(_ id: UUID) {
        let root = AddDownloadView(requestID: id, onClose: { [weak self] in self?.closeAdd(id) })
            .tideEnvironment(services)
        let w = makePanelWindow(root, title: "Add Download")
        addWindows[id] = w
        let obs = WindowCloseObserver(window: w)
        obs.onClose = { [weak self] in
            self?.addWindows[id] = nil
            self?.services.model.finishAddRequest(id)
        }
        observers.append(obs)
        present(w)
    }

    private func closeAdd(_ id: UUID) {
        addWindows[id]?.close()
        addWindows[id] = nil
    }

    override func showAddLink() { services.model.requestAdd([]) }

    override func openTorrentFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.torrentFile]
        panel.allowsMultipleSelection = true
        panel.message = "Choose torrent files to add."
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        let inputs = panel.urls.map { AddInput.torrentFile($0) }
        if !inputs.isEmpty { services.model.requestAdd(inputs) }
    }

    // MARK: Import / Welcome

    override func showImport(_ url: URL? = nil, candidates: [ImportCandidate]? = nil) {
        importWindow?.close()
        let root = ImportView(initialURL: url, initialCandidates: candidates,
                              onClose: { [weak self] in self?.importWindow?.close() })
            .tideEnvironment(services)
        let w = makePanelWindow(root, title: "Import Existing Download")
        importWindow = w
        present(w)
    }

    override func showWelcome() {
        if let w = welcomeWindow { present(w); return }
        let root = WelcomeView(onClose: { [weak self] in self?.welcomeWindow?.close(); self?.welcomeWindow = nil })
            .tideEnvironment(services)
        let w = makePanelWindow(root, title: "Welcome to Tide")
        welcomeWindow = w
        present(w)
    }

    // MARK: Settings

    override func showSettings() {
        if settingsWindow == nil { settingsWindow = makeSettingsWindow() }
        present(settingsWindow!)
    }

    private func makeSettingsWindow() -> NSWindow {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.canPropagateSelectedChildViewControllerTitle = true
        for pane in SettingsPane.allCases {
            let host = NSHostingController(rootView: AnyView(pane.view.tideEnvironment(services)))
            host.sizingOptions = [.preferredContentSize]
            host.title = pane.rawValue
            let item = NSTabViewItem(viewController: host)
            item.label = pane.rawValue
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.rawValue)
            tabs.addTabViewItem(item)
        }
        let w = NSWindow(contentViewController: tabs)
        w.styleMask = [.titled, .closable]
        w.toolbarStyle = .preference
        w.isReleasedWhenClosed = false
        w.center()
        return w
    }

    override func showAbout() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Tide",
            .credits: NSAttributedString(string: "A quiet front end for aria2.",
                                         attributes: [.font: NSFont.systemFont(ofSize: 11),
                                                      .foregroundColor: NSColor.secondaryLabelColor]),
        ])
    }

    override func closePopover() { statusItem?.closePopover() }

    // MARK: Helpers

    /// Titled window with hidden title, sized to its SwiftUI content.
    private func makePanelWindow<V: View>(_ root: V, title: String) -> NSWindow {
        let host = NSHostingController(rootView: root)
        host.sizingOptions = [.preferredContentSize]
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.title = title
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.tabbingMode = .disallowed
        w.center()
        return w
    }

    private func present(_ w: NSWindow) {
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }
}

/// Window delegate with closures.
@MainActor
final class WindowCloseObserver: NSObject, NSWindowDelegate {
    var onClose: () -> Void = {}
    var onOcclusion: (Bool) -> Void = { _ in }
    var onKey: (Bool) -> Void = { _ in }
    // Block-based observers stay registered until they are removed.
    nonisolated(unsafe) private var tokens: [NSObjectProtocol] = []

    deinit {
        tokens.forEach(NotificationCenter.default.removeObserver)
    }

    init(window: NSWindow) {
        super.init()
        window.delegate = self
        tokens.append(NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                             object: window, queue: .main) { [weak self] n in
            let visible = (n.object as? NSWindow)?.occlusionState.contains(.visible) ?? false
            MainActor.assumeIsolated { self?.onOcclusion(visible) }
        })
    }

    func windowWillClose(_ notification: Notification) { onClose() }
    func windowDidBecomeKey(_ notification: Notification) { onKey(true) }
    func windowDidResignKey(_ notification: Notification) { onKey(false) }
}
