import AppKit
import SwiftUI
import TideKit

/// The Downloads window (DESIGN.md §5): no sidebar, two sections, inspector, 4 toolbar buttons
/// plus search.
struct MainWindowView: View {
    @Environment(AppModel.self) private var model
    @Environment(EtaEstimator.self) private var eta
    @Environment(MainWindowState.self) private var state
    @Environment(WindowRouter.self) private var router
    @Environment(\.inlineInspector) private var inlineInspector

    private var snap: EngineSnapshot { model.snapshot }

    /// The inset list draws section headers 6pt left of row content (rows carry their own 12pt
    /// padding); this lines the headers up with the row icons.
    static let headerInset: CGFloat = 6

    private func matches(_ t: DownloadTask) -> Bool {
        state.search.isEmpty || t.name.localizedCaseInsensitiveContains(state.search)
    }

    var body: some View {
        @Bindable var state = state
        let inProgress = snap.inProgress.filter(matches)
        let finished = snap.finished.filter(matches)

        Group {
            if snap.tasks.isEmpty {
                emptyState
            } else if inProgress.isEmpty && finished.isEmpty {
                ContentUnavailableView.search(text: state.search)
            } else {
                list(inProgress: inProgress, finished: finished)
            }
        }
        .frame(minWidth: 640, minHeight: 400)
        .acceptsDownloadDrops(model)
        .navigationTitle("Downloads")
        .navigationSubtitle(WindowSubtitle.text(snap))
        .toolbar { toolbar }
        .searchable(text: $state.search, placement: .toolbar, prompt: "Search")
        .modifier(InspectorPlacement(shown: $state.inspectorShown, inline: inlineInspector))
    }

    // MARK: List

    private func list(inProgress: [DownloadTask], finished: [DownloadTask]) -> some View {
        @Bindable var state = state
        return List(selection: $state.selection) {
            if !inProgress.isEmpty {
                Section {
                    ForEach(inProgress) { task in
                        row(task).tag(task.id)
                    }
                    .onMove { from, to in
                        guard let i = from.first, inProgress.indices.contains(i) else { return }
                        let dest = to > i ? to - 1 : to
                        model.move(inProgress[i].id, to: .index(dest))
                    }
                } header: {
                    SectionHeader(title: "In Progress")
                        .padding(.horizontal, Self.headerInset)
                }
            }
            if !finished.isEmpty {
                Section(isExpanded: $state.completedExpanded) {
                    ForEach(finished) { task in
                        row(task).tag(task.id)
                            .draggable(task.primaryFile ?? task.directory)
                    }
                } header: {
                    HStack {
                        SectionHeader(title: "Completed")
                        Spacer()
                        Button("Clear") { model.clearCompleted() }
                            .buttonStyle(.borderless)
                            .font(.system(size: 11))
                    }
                    .padding(.horizontal, Self.headerInset)
                }
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: TaskID.self) { ids in
            TaskContextMenu(tasks: model.snapshot.tasks.filter { ids.contains($0.id) })
        } primaryAction: { ids in
            primaryAction(ids)
        }
        .onKeyPress(.space) {
            if let t = state.selectedTasks(in: model).first(where: { $0.phase.isFinished }) {
                QuickLook.show(t); return .handled
            }
            return .ignored
        }
        .onDeleteCommand {
            RemoveFlow.run(tasks: state.selectedTasks(in: model), model: model, trash: false)
        }
        .transaction { $0.animation = nil }
    }

    @ViewBuilder
    private func row(_ task: DownloadTask) -> some View {
        if state.compactRows {
            CompactTaskRow(task: task, eta: eta.eta(task))
                .listRowInsets(EdgeInsets())
        } else {
            WindowTaskRow(task: task, eta: eta.eta(task))
                .listRowInsets(EdgeInsets())
        }
    }

    private func primaryAction(_ ids: Set<TaskID>) {
        let tasks = model.snapshot.tasks.filter { ids.contains($0.id) }
        guard let first = tasks.first else { return }
        if tasks.count == 1, first.phase.isFinished { Finder.open(first) }
        else { state.inspectorShown = true }
    }

    // MARK: Empty

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Downloads", systemImage: "arrow.down.circle")
        } description: {
            Text("Drop a torrent, magnet link or URL here.")
        } actions: {
            Button("Add Link…") { router.showAddLink() }
            Button("Import Existing Download…") { router.showImport() }
                .buttonStyle(.link)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button("Add Link…") { router.showAddLink() }
                Button("Open Torrent File…") { router.openTorrentFile() }
                Button("Import Existing Download…") { router.showImport() }
            } label: {
                Label("Add", systemImage: "plus")
            } primaryAction: {
                router.showAddLink()
            }
            .help("Add Link…")

            Button {
                if model.anythingMoving { model.pauseAll() } else { model.resumeAll() }
            } label: {
                Label(model.anythingMoving ? "Pause All" : "Resume All",
                      systemImage: model.anythingMoving ? "pause.fill" : "play.fill")
            }
            .help(model.anythingMoving ? "Pause All" : "Resume All")

            Button { model.toggleSlowMode() } label: {
                Label("Slow Mode", systemImage: snap.slowMode ? "tortoise.fill" : "tortoise")
                    .foregroundStyle(snap.slowMode ? AnyShapeStyle(Color.indigo) : AnyShapeStyle(.primary))
            }
            .help(snap.slowMode ? "Turn Off Slow Mode" : "Slow Mode (\(TideFormat.speed(model.settings.slowModeDownLimit)))")
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            Button { state.inspectorShown.toggle() } label: {
                Label("Show Info", systemImage: "sidebar.trailing")
            }
            .help(state.inspectorShown ? "Hide Info" : "Show Info")
        }
    }
}

/// Picks single/multi/empty inspector content.
struct InspectorContainer: View {
    @Environment(AppModel.self) private var model
    @Environment(MainWindowState.self) private var state

    var body: some View {
        let selected = state.selectedTasks(in: model)
        Group {
            if selected.count == 1, let task = selected.first {
                InspectorView(task: task)
            } else if selected.count > 1 {
                MultiInspectorView(tasks: selected)
            } else {
                ContentUnavailableView("No Selection", systemImage: "info.circle",
                                       description: Text("Select a download to see its details."))
            }
        }
    }
}

/// The system inspector, or (for offscreen preview renders, which can't capture the inspector's
/// split view) the same content laid out inline.
private struct InspectorPlacement: ViewModifier {
    @Binding var shown: Bool
    var inline: Bool

    func body(content: Content) -> some View {
        if inline {
            HStack(spacing: 0) {
                content
                if shown {
                    Divider()
                    InspectorContainer().frame(width: 300)
                }
            }
        } else {
            content.inspector(isPresented: $shown) {
                InspectorContainer()
                    .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
            }
        }
    }
}

extension EnvironmentValues {
    @Entry var inlineInspector = false
}
