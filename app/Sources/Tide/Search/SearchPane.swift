import AppKit
import SwiftUI
import TideKit

/// The Search view of the main window: find torrents on free public indexes, look at one, add it
/// through the usual Add window. Its search bar sits in the content, large and labelled, so it
/// can't be mistaken for the toolbar field that filters downloads. Nothing touches the network
/// until the user presses Return.
struct SearchPane: View {
    @Bindable var session: SearchSession
    @Environment(AppModel.self) private var model
    @Environment(WindowRouter.self) private var router
    @Environment(MainWindowState.self) private var windowState
    @Environment(\.inlineInspector) private var inlineInspector
    @State private var library: [String: TaskID] = [:]

    private var search: TorrentSearch { session.search }
    private var details: TorrentDetails { session.details }

    private var rows: [SearchResult] {
        search.results.filter { session.category == nil || $0.category == session.category }
            .sorted(using: session.sortOrder)
    }

    private func result(_ id: SearchResult.ID?) -> SearchResult? {
        id.flatMap { id in search.results.first { $0.id == id } }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(LibraryWatcher(library: $library))
        .navigationTitle("Tide")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { session.inspectorShown.toggle() } label: {
                    Label("Show Info", systemImage: "sidebar.trailing")
                }
                .help(session.inspectorShown ? "Hide Info" : "Show Info")
            }
        }
        .onChange(of: session.selection) {
            details.select(result(session.selection), sources: Set(model.settings.searchSources))
        }
        .modifier(SearchInspectorPlacement(shown: $session.inspectorShown, inline: inlineInspector) {
            SearchInspector(result: result(session.selection), details: details,
                            libraryID: session.selection.flatMap { library[$0] }, onDownload: download,
                            onShow: showInDownloads)
        })
    }

    // MARK: Search bar

    private var searchBar: some View {
        HStack(spacing: 12) {
            TorrentSearchField(text: $session.text, focusRequest: session.focusRequest) { run($0) }
            Picker("Category", selection: $session.category) {
                Text("All Categories").tag(SearchCategory?.none)
                Divider()
                ForEach(SearchCategory.allCases.filter { $0 != .adult || model.settings.showAdultResults }) { c in
                    Label(c.title, systemImage: c.symbol).tag(Optional(c))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .help("Show One Category")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if model.settings.searchSources.isEmpty {
            ContentUnavailableView {
                Label("No Search Sources", systemImage: "magnifyingglass")
            } description: {
                Text("Turn on a source in Settings ▸ BitTorrent.")
            } actions: {
                Button("Open Settings…") { router.showSettings() }
            }
        } else {
            switch search.phase {
            case .idle:
                ContentUnavailableView {
                    Label("Search for Torrents", systemImage: "magnifyingglass")
                } description: {
                    Text("Searches The Pirate Bay, YTS, Nyaa, Bitsearch and more. Free, no account.")
                }
            case .searching:
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Searching \(search.searched.count) \(search.searched.count == 1 ? "source" : "sources")…")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            case .done:
                let rows = self.rows
                if search.allFailed {
                    ContentUnavailableView {
                        Label(search.isOffline ? "You're Offline" : "Can't Reach Any Search Source",
                              systemImage: search.isOffline ? "wifi.slash" : "exclamationmark.magnifyingglass")
                    } description: {
                        Text(search.isOffline ? "Connect to the internet, then try again."
                                              : "The search sources didn't respond. Try again in a moment.")
                    } actions: {
                        Button("Try Again") { run(search.query) }
                    }
                } else if rows.isEmpty {
                    ContentUnavailableView.search(text: search.query)
                } else {
                    table(rows)
                }
            }
        }
    }

    private func table(_ rows: [SearchResult]) -> some View {
        Table(rows, selection: $session.selection, sortOrder: $session.sortOrder) {
            TableColumn("Name", value: \.name) { r in
                SearchResultCell(result: r, inLibrary: library[r.id] != nil)
            }
            .width(min: 180, ideal: 240)
            TableColumn("Size", value: \.size) { r in
                Text(r.size > 0 ? TideFormat.bytes(r.size) : "—").foregroundStyle(.secondary)
            }
            .width(min: 64, ideal: 80, max: 100)
            .alignment(.trailing)
            TableColumn("Seeds", value: \.seeders) { r in
                Text(TideFormat.count(r.seeders))
            }
            .width(min: 48, ideal: 60, max: 80)
            .alignment(.trailing)
            TableColumn("Peers", value: \.leechers) { r in
                Text(TideFormat.count(r.leechers)).foregroundStyle(.secondary)
            }
            .width(min: 48, ideal: 60, max: 80)
            .alignment(.trailing)
            TableColumn("Added", value: \.addedOrDistantPast) { r in
                Text(r.added.map { TideFormat.relative($0, style: .abbreviated) } ?? "—").foregroundStyle(.secondary)
            }
            .width(min: 64, ideal: 80, max: 120)
        }
        .monospacedDigit()
        .contextMenu(forSelectionType: SearchResult.ID.self) { ids in
            if let r = result(ids.first) {
                Button(library[r.id] == nil ? "Download" : "Show in Downloads") { download(r) }
                Button("Copy Magnet Link") { copyMagnet(r) }
                if let hit = r.sources.first(where: { $0.page != nil }), let page = hit.page {
                    Button("Open on \(hit.label)") { NSWorkspace.shared.open(page) }
                }
            }
        } primaryAction: { ids in
            if let r = result(ids.first) { download(r) }
        }
        .onCopyCommand {
            result(session.selection).map { [NSItemProvider(object: $0.magnet as NSString)] } ?? []
        }
    }

    private var subtitle: String {
        guard search.phase == .done, !search.allFailed else { return "" }
        var s = search.summary
        if session.category != nil { s = "\(TideFormat.count(rows.count)) of \(s)" }
        if let note = search.failureNote { s += " · \(note)" }
        return s
    }

    // MARK: Actions

    private func run(_ query: String) {
        session.selection = nil
        search.search(query, sources: model.settings.searchSources, showAdult: model.settings.showAdultResults)
    }

    private func download(_ r: SearchResult) {
        if let id = library[r.id] { showInDownloads(id); return }
        router.showAdd([details.addInput(for: r)])
    }

    private func showInDownloads(_ id: TaskID) {
        windowState.show(.downloads, model: model)
        router.showMain(select: id)
    }
}

/// The native search field, large: Return (or clearing it) runs the search, never each keystroke.
private struct TorrentSearchField: NSViewRepresentable {
    @Binding var text: String
    var focusRequest: Int
    var onSubmit: (String) -> Void

    func makeNSView(context: Context) -> NSSearchField {
        let f = NSSearchField()
        f.placeholderString = "Search for torrents"
        f.controlSize = .large
        f.font = .systemFont(ofSize: NSFont.systemFontSize(for: .large))
        f.sendsWholeSearchString = true
        f.sendsSearchStringImmediately = false
        f.target = context.coordinator
        f.action = #selector(Coordinator.submit(_:))
        f.delegate = context.coordinator
        f.setAccessibilityLabel("Search for torrents")
        return f
    }

    func updateNSView(_ f: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if f.stringValue != text { f.stringValue = text }
        // Fresh field (the view just appeared) or an explicit request: put the cursor in it.
        if context.coordinator.focused != focusRequest {
            context.coordinator.focused = focusRequest
            DispatchQueue.main.async { f.window?.makeFirstResponder(f) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: TorrentSearchField
        var focused = -1
        init(_ parent: TorrentSearchField) { self.parent = parent }

        @objc func submit(_ f: NSSearchField) { parent.onSubmit(f.stringValue) }

        func controlTextDidChange(_ n: Notification) {
            if let f = n.object as? NSSearchField { parent.text = f.stringValue }
        }
    }
}

func copyMagnet(_ r: SearchResult) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(r.magnet, forType: .string)
}

// MARK: - Row

private struct SearchResultCell: View {
    var result: SearchResult
    var inLibrary: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: result.category.symbol)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityLabel(result.category.title)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 4) {
                    if inLibrary {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("In Downloads ·")
                    }
                    Text(result.labels.joined(separator: " · "))
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
        .help(result.name)
    }
}

/// Mirrors the downloads' info hashes into `library` only when they change, so the results table
/// doesn't redraw on every engine snapshot.
private struct LibraryWatcher: View {
    @Environment(AppModel.self) private var model
    @Binding var library: [String: TaskID]

    var body: some View {
        let current = Dictionary(model.snapshot.tasks.compactMap { t in t.infoHash.map { ($0, t.id) } },
                                 uniquingKeysWith: { a, _ in a })
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: current, initial: true) { library = current }
    }
}

// MARK: - Inspector

private struct SearchInspector: View {
    var result: SearchResult?
    var details: TorrentDetails
    var libraryID: TaskID?
    var onDownload: (SearchResult) -> Void
    var onShow: (TaskID) -> Void
    @State private var detailsOpen = false

    /// Very large torrents show only their largest files.
    static let fileLimit = 500

    var body: some View {
        if let r = result {
            VStack(spacing: 0) {
                header(r)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        files(r)
                        more(r)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                actions(r).padding(16)
            }
        } else {
            ContentUnavailableView("No Selection", systemImage: "info.circle",
                                   description: Text("Select a result to see its files."))
        }
    }

    private func header(_ r: SearchResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(TideFormat.breakable(r.name))
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(3)
                .truncationMode(.middle)
                .help(r.name)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    stat("Size", r.size > 0 ? TideFormat.bytes(r.size) : "Unknown")
                    stat("Peers", "\(TideFormat.count(r.seeders)) seeds · \(TideFormat.count(r.leechers)) peers")
                }
                GridRow {
                    stat("Added", r.added.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "Unknown")
                    stat("Category", r.category.title)
                }
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func files(_ r: SearchResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Files")
            switch details.files[r.id] {
            case nil, .loading?:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Getting the file list…")
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            case .listed(let list)?:
                fileList(list, smart: nil)
            case .full(let preview)?:
                fileList(preview.files, smart: preview.smart)
            case .unavailable?:
                Text("The file list arrives when the download starts.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func fileList(_ list: [TaskFile], smart: SmartSummary?) -> some View {
        let total = list.reduce(Int64(0)) { $0 + $1.length }
        let shown = list.count > Self.fileLimit
            ? Array(list.sorted { $0.length > $1.length }.prefix(Self.fileLimit)) : list
        Text(total > 0 ? "\(TideFormat.count(list.count)) \(list.count == 1 ? "file" : "files") · \(TideFormat.bytes(total))"
                       : "\(TideFormat.count(list.count)) \(list.count == 1 ? "file" : "files")")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .monospacedDigit()
        if let smart, smart.skippedCount > 0 {
            Text("Skipping \(smart.skippedCount) \(smart.skippedCount == 1 ? "extra" : "extras") (\(TideFormat.bytes(smart.skippedBytes))): \(smart.skippedDescription)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        FileTreeView(files: shown, selected: .constant(Set(shown.filter(\.selected).map(\.index))), editable: false)
        if shown.count < list.count {
            Text("Showing the \(TideFormat.count(shown.count)) largest of \(TideFormat.count(list.count)) files.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func more(_ r: SearchResult) -> some View {
        DisclosureGroup("Details", isExpanded: $detailsOpen) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    label("Info hash")
                    Text(r.infoHash)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
                GridRow {
                    label("Found on")
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(pages(r), id: \.label) { hit in
                            if let page = hit.page { Link(hit.label, destination: page) } else { Text(hit.label) }
                        }
                    }
                }
                if let uploader = r.uploader {
                    GridRow { label("Uploaded by"); Text(uploader) }
                }
                GridRow { label("Trackers"); Text(TideFormat.count(r.trackers.count)).monospacedDigit() }
            }
            .font(.system(size: 13))
            .padding(.top, 8)
        }
        .font(.system(size: 13))
    }

    private func label(_ s: String) -> some View {
        Text(s).font(.system(size: 11)).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }

    /// One entry per badge, with a page link when any source has one.
    private func pages(_ r: SearchResult) -> [SourceHit] {
        r.labels.compactMap { l in
            r.sources.first { $0.label == l && $0.page != nil } ?? r.sources.first { $0.label == l }
        }
    }

    private func actions(_ r: SearchResult) -> some View {
        HStack {
            if let id = libraryID {
                Label("Already in your downloads", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .labelStyle(StatusLabelStyle())
                Spacer()
                Button("Show") { onShow(id) }
            } else {
                Button("Copy Magnet Link") { copyMagnet(r) }
                Spacer()
                Button("Download") { onDownload(r) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

/// Green symbol, primary text.
private struct StatusLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.foregroundStyle(.green)
            configuration.title
        }
    }
}

/// The system inspector, or (for offscreen preview renders) the same content laid out inline.
private struct SearchInspectorPlacement<Inspector: View>: ViewModifier {
    @Binding var shown: Bool
    var inline: Bool
    @ViewBuilder var inspector: () -> Inspector

    func body(content: Content) -> some View {
        if inline {
            HStack(spacing: 0) {
                content
                if shown {
                    Divider()
                    inspector().frame(width: 300)
                }
            }
        } else {
            content.inspector(isPresented: $shown) {
                inspector().inspectorColumnWidth(min: 260, ideal: 300, max: 380)
            }
        }
    }
}

extension SearchCategory {
    var symbol: String {
        switch self {
        case .movies: return "film"
        case .tv: return "tv"
        case .music: return "music.note"
        case .anime: return "sparkles.tv"
        case .apps: return "shippingbox"
        case .games: return "gamecontroller"
        case .books: return "book.closed"
        case .adult: return "eye.slash"
        case .other: return "doc"
        }
    }
}
