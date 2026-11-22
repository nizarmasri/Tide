import AppKit
import Observation
import SwiftUI
import TideKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private(set) var services: AppServices!
    private(set) var windows: WindowManager!
    private var statusItem: StatusItemController!
    private var launchedAtLogin = false
    private var pendingInputs: [AddInput] = []
    private var quitConfirmed = false

    private var model: AppModel { services.model }
    private var state: MainWindowState { services.windowState }

    // MARK: Launch

    func applicationWillFinishLaunching(_ notification: Notification) {
        if let ev = NSAppleEventManager.shared().currentAppleEvent,
           ev.eventID == kAEOpenApplication,
           ev.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem {
            launchedAtLogin = true
        }
        NSApp.setActivationPolicy(.accessory)
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURLEvent(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel(backend: Integration.makeBackend(), settingsStore: .appDefault())
        let wm = WindowManager()
        let services = AppServices(model: model, router: wm)
        wm.services = services
        self.services = services
        self.windows = wm
        model.openAddWindow = { [weak wm] id in wm?.openAddWindow(id) }
        model.showTaskInWindow = { [weak wm] id in wm?.showMain(select: id) }

        statusItem = StatusItemController(services: services)
        wm.statusItem = statusItem
        NSApp.mainMenu = MainMenu.build(target: self)

        model.start()
        feedETA()
        Integration.didLaunch(model: model)

        if !pendingInputs.isEmpty {
            model.requestAdd(pendingInputs)
            pendingInputs = []
        } else if !model.settings.welcomeDone {
            wm.showWelcome()
        } else if !launchedAtLogin {
            wm.showMain()
        }

        // Test hook: `open Tide.app --args --show-popover` opens the popover for screenshots.
        if CommandLine.arguments.contains("--show-popover") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.statusItem.togglePopover() }
        }
        if CommandLine.arguments.contains("--show-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.windows.showSettings() }
        }
    }

    /// Feeds every snapshot to the ETA estimator (10 s EMA, published ≤ every 2 s).
    private func feedETA() {
        withObservationTracking {
            services.eta.ingest(model.snapshot)
        } onChange: { [weak self] in
            Task { @MainActor in self?.feedETA() }
        }
    }

    // MARK: Opening

    func application(_ application: NSApplication, open urls: [URL]) {
        receive(urls.compactMap(InputParser.input(for:)))
    }

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue else { return }
        receive(InputParser.links(in: s))
    }

    private func receive(_ inputs: [AddInput]) {
        guard !inputs.isEmpty else { return }
        if services == nil { pendingInputs += inputs } else { model.requestAdd(inputs) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windows?.showMain()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: Quit

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let services, !quitConfirmed else { return .terminateNow }
        let active = services.model.snapshot.inProgress.filter { $0.phase.isActive || $0.phase.isPausable }
            .filter { $0.phase.isActive }
        if services.model.settings.askBeforeQuit, !active.isEmpty {
            let alert = QuitFlow.makeAlert(activeCount: active.count)
            NSApp.activate()
            let r = alert.runModal()
            if alert.suppressionButton?.state == .on { services.model.settings.askBeforeQuit = false }
            guard r == .alertFirstButtonReturn else { return .terminateCancel }
        }
        quitConfirmed = true
        Integration.willTerminate(model: services.model)
        return .terminateNow
    }

    // MARK: Menu actions

    private var selected: [DownloadTask] { state.selectedTasks(in: model) }
    private var mainIsKey: Bool { windows.isMainWindowVisible && state.isKey }

    @objc func showSettings(_ sender: Any?) { windows.showSettings() }
    @objc func showAbout(_ sender: Any?) { windows.showAbout() }
    @objc func addLink(_ sender: Any?) { windows.showAddLink() }
    @objc func openTorrent(_ sender: Any?) { windows.openTorrentFile() }
    @objc func importExisting(_ sender: Any?) { windows.showImport() }
    @objc func showDownloads(_ sender: Any?) { windows.showMain() }

    @objc func pauseSelected(_ sender: Any?) { model.pause(selected.filter { $0.phase.isPausable }.map(\.id)) }
    @objc func resumeSelected(_ sender: Any?) { model.resume(selected.map(\.id)) }
    @objc func pauseAll(_ sender: Any?) { model.pauseAll() }
    @objc func resumeAll(_ sender: Any?) { model.resumeAll() }
    @objc func toggleSlowMode(_ sender: Any?) { model.toggleSlowMode() }
    @objc func revealSelected(_ sender: Any?) { selected.forEach(Finder.reveal) }
    @objc func quickLookSelected(_ sender: Any?) {
        if let t = selected.first(where: { $0.phase.isFinished }) { QuickLook.show(t) }
    }
    @objc func toggleInspector(_ sender: Any?) { state.inspectorShown.toggle() }
    @objc func toggleCompact(_ sender: Any?) {
        state.compactRows.toggle()
        UserDefaults.standard.set(state.compactRows, forKey: "compactRows")
    }
    @objc func moveUp(_ sender: Any?) { if let t = selected.first { model.move(t.id, to: .up) } }
    @objc func moveDown(_ sender: Any?) { if let t = selected.first { model.move(t.id, to: .down) } }
    @objc func verifySelected(_ sender: Any?) { if let t = selected.first { model.verify(t.id) } }
    @objc func removeSelected(_ sender: Any?) { RemoveFlow.run(tasks: selected, model: model, trash: false) }
    @objc func trashSelected(_ sender: Any?) { RemoveFlow.run(tasks: selected, model: model, trash: true) }
    @objc func copyLinkSelected(_ sender: Any?) {
        let links = selected.compactMap { $0.magnetLink ?? $0.sourceURL }
        guard !links.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(links.joined(separator: "\n"), forType: .string)
    }
    @objc func findInDownloads(_ sender: Any?) {
        windows.showMain()
        if let item = NSApp.keyWindow?.toolbar?.items.compactMap({ $0 as? NSSearchToolbarItem }).first {
            item.beginSearchInteraction()
        }
    }

    /// ⌘V with no text field focused adds the links on the clipboard.
    @objc func paste(_ sender: Any?) {
        let inputs = services.clipboard.readInputs()
        if inputs.isEmpty { windows.showAddLink() } else { model.requestAdd(inputs) }
    }

    /// Edit ▸ Copy with no text selected copies the selected downloads' links.
    @objc func copy(_ sender: Any?) { copyLinkSelected(sender) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let services else { return true }
        let typing = NSApp.keyWindow?.firstResponder is NSText
        let sel = selected
        switch item.action {
        case #selector(pauseSelected): return mainIsKey && sel.contains { $0.phase.isPausable }
        case #selector(resumeSelected): return mainIsKey && sel.contains { !$0.phase.isPausable && !$0.phase.isFinished }
        case #selector(pauseAll): return services.model.anythingMoving
        case #selector(resumeAll): return services.model.snapshot.inProgress.contains { !$0.phase.isActive }
        case #selector(toggleSlowMode):
            item.state = services.model.slowMode ? .on : .off; return true
        case #selector(toggleCompact):
            item.state = state.compactRows ? .on : .off; return windows.isMainWindowVisible
        case #selector(toggleInspector):
            item.title = state.inspectorShown ? "Hide Info" : "Show Info"; return windows.isMainWindowVisible
        case #selector(revealSelected), #selector(copyLinkSelected): return mainIsKey && !sel.isEmpty
        case #selector(quickLookSelected): return mainIsKey && sel.contains { $0.phase.isFinished }
        case #selector(moveUp), #selector(moveDown):
            return mainIsKey && sel.count == 1 && !(sel.first?.phase.isFinished ?? true)
        case #selector(verifySelected):
            return mainIsKey && sel.count == 1 && sel.first?.kind != .http && !(sel.first?.phase.isFinished ?? true)
        case #selector(removeSelected), #selector(trashSelected): return mainIsKey && !sel.isEmpty && !typing
        case #selector(copy(_:)): return mainIsKey && !sel.isEmpty
        default: return true
        }
    }
}
