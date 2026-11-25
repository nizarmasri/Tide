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

/// The two views of the main window, switched in the toolbar (⌘1 / ⌘2).
enum MainTab: String, CaseIterable, Identifiable {
    case downloads = "Downloads", search = "Search"
    var id: String { rawValue }
}

/// One torrent search, alive while the main window is open: the query, results, selection and
/// the files loaded for it. Nothing in it touches the network until the user presses Return.
@MainActor
@Observable
final class SearchSession {
    let search: TorrentSearch
    let details: TorrentDetails
    var text = ""
    var selection: SearchResult.ID?
    var category: SearchCategory?
    var sortOrder = [KeyPathComparator(\SearchResult.seeders, order: .reverse)]
    var inspectorShown = true
    /// Bumped to put the cursor in the search bar.
    var focusRequest = 0

    init(search: TorrentSearch, details: TorrentDetails) {
        self.search = search
        self.details = details
    }

    convenience init(model: AppModel) {
        self.init(search: TorrentSearch(), details: TorrentDetails { await model.inspect($0) })
    }
}

extension AppModel {
    /// Downloaded .torrent files that an open Add window still needs.
    var pendingTorrentFiles: Set<URL> {
        Set(addRequests.values.joined().compactMap { input in
            if case .torrentFile(let url) = input { return url } else { return nil }
        })
    }
}

/// UI state of the Downloads window, shared with the main menu so ⌘. / ⌘I etc. act on the
/// current selection.
@MainActor
@Observable
final class MainWindowState {
    var tab: MainTab = .downloads
    /// Created the first time the Search view opens; dropped when the window closes.
    private(set) var searchSession: SearchSession?
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

    func show(_ tab: MainTab, model: AppModel) {
        if tab == .search, searchSession == nil {
            TorrentDetails.removeTemporaryFiles(keeping: model.pendingTorrentFiles)
            searchSession = SearchSession(model: model)
        }
        self.tab = tab
    }

    /// Switches to Search with the cursor in the search bar.
    func focusSearch(model: AppModel) {
        show(.search, model: model)
        searchSession?.focusRequest += 1
    }

    /// The window closed: forget the search and the .torrent files it downloaded.
    func endSearch(model: AppModel) {
        searchSession = nil
        tab = .downloads
        TorrentDetails.removeTemporaryFiles(keeping: model.pendingTorrentFiles)
    }

    /// Previews and renders: show a prepared search.
    func showSearch(_ session: SearchSession) {
        searchSession = session
        tab = .search
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
    func showSearch() {}
    func showImport(_ url: URL? = nil, candidates: [ImportCandidate]? = nil) {}
    func showSettings() {}
    func showWelcome() {}
    func showAbout() {}
    func closePopover() {}
}
