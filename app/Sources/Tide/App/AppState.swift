import AppKit
import Observation
import SwiftUI
import TideKit
import UniformTypeIdentifiers

/// Whether the pasteboard holds a magnet or URL. The main thread's clipboard watcher sets
/// `hasLink` (using detect/type APIs that don't read the contents, so no paste-privacy prompt);
/// the content itself is read only when the user clicks Add.
@MainActor
@Observable
final class ClipboardStatus {
    static let shared = ClipboardStatus()
    var hasLink = false

    /// Reads the pasteboard now (user-initiated) and returns the links on it.
    func readInputs() -> [AddInput] {
        DropReader.inputs(from: .general)
    }
}

/// UI state of the Downloads window, shared with the main menu so ⌘. / ⌘I etc. act on the
/// current selection.
@MainActor
@Observable
final class MainWindowState {
    var selection = Set<TaskID>()
    var inspectorShown = false
    var compactRows = false
    var search = ""
    var completedExpanded = true
    var inspectorTab: InspectorTab = .info
    var isKey = false

    enum InspectorTab: String, CaseIterable, Identifiable {
        case info = "Info", files = "Files", peers = "Peers"
        var id: String { rawValue }
    }

    func selectedTasks(in model: AppModel) -> [DownloadTask] {
        model.snapshot.tasks.filter { selection.contains($0.id) }
    }

    init(compactRows: Bool = UserDefaults.standard.bool(forKey: "compactRows")) {
        self.compactRows = compactRows
    }
}

/// System actions the UI triggers. Main-thread code may replace these (e.g. OpenHandler).
@MainActor
enum AppHooks {
    /// Makes Tide the default app for magnet: links and .torrent files.
    static var makeDefaultApp: () -> Void = {
        let app = Bundle.main.bundleURL
        NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "magnet") { _ in }
        NSWorkspace.shared.setDefaultApplication(at: app, toOpen: .torrentFile) { _ in }
    }

    /// True when Tide already handles magnet: links.
    static var isDefaultApp: () -> Bool = {
        guard let url = URL(string: "magnet:?xt=urn:btih:0"),
              let handler = NSWorkspace.shared.urlForApplication(toOpen: url) else { return false }
        return handler.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    static var showEngineLog: (AppModel) -> Void = { model in
        if let url = model.engineLogURL { NSWorkspace.shared.open(url) }
        else { NSWorkspace.shared.open(TidePaths.logDirectory) }
    }
}

/// Everything views need, injected once at each hosting root.
struct AppEnvironment: ViewModifier {
    var model: AppModel
    var eta: EtaEstimator
    var window: MainWindowState
    var clipboard: ClipboardStatus
    var router: WindowRouter

    func body(content: Content) -> some View {
        content
            .environment(model)
            .environment(eta)
            .environment(window)
            .environment(clipboard)
            .environment(router)
    }
}

extension View {
    func tideEnvironment(_ services: AppServices) -> some View {
        modifier(AppEnvironment(model: services.model, eta: services.eta, window: services.windowState,
                                clipboard: services.clipboard, router: services.router))
    }
}

/// Holder for the shared objects.
@MainActor
final class AppServices {
    let model: AppModel
    let eta: EtaEstimator
    let windowState: MainWindowState
    let clipboard: ClipboardStatus
    let router: WindowRouter

    init(model: AppModel, eta: EtaEstimator? = nil, windowState: MainWindowState? = nil,
         clipboard: ClipboardStatus? = nil, router: WindowRouter) {
        self.model = model
        self.eta = eta ?? EtaEstimator()
        self.windowState = windowState ?? MainWindowState()
        self.clipboard = clipboard ?? .shared
        self.router = router
    }
}

/// Window-opening actions callable from any view. The real implementation is WindowManager.
@MainActor
@Observable
class WindowRouter {
    func showMain(select: TaskID? = nil) {}
    func showAdd(_ inputs: [AddInput]) {}
    func showAddLink() {}
    func openTorrentFile() {}
    func showImport(_ url: URL? = nil, candidates: [ImportCandidate]? = nil) {}
    func showSettings() {}
    func showWelcome() {}
    func showAbout() {}
    func closePopover() {}
}
