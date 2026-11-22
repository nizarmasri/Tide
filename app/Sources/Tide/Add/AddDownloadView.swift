import AppKit
import SwiftUI
import TideKit

/// One item being added (a torrent, magnet or URL).
struct AddItem: Identifiable, Equatable {
    var id = UUID()
    var input: AddInput
    var preview: AddPreview?
    /// nil = smart default from the preview.
    var selection: Set<Int>?
    var expanded = false

    var selected: Set<Int> {
        selection ?? Set((preview?.files ?? []).filter(\.selected).map(\.index))
    }
    var selectedBytes: Int64 {
        guard let p = preview else { return 0 }
        if p.files.isEmpty { return p.totalBytes ?? 0 }
        return p.files.filter { selected.contains($0.index) }.reduce(0) { $0 + $1.length }
    }
    var largestSelected: Int64 {
        guard let p = preview else { return 0 }
        if p.files.isEmpty { return p.totalBytes ?? 0 }
        return p.files.filter { selected.contains($0.index) }.map(\.length).max() ?? 0
    }
    var isAddable: Bool {
        guard let p = preview else { return false }
        return p.problem == nil && p.duplicateOf == nil
    }
}

/// The Add Download window (DESIGN.md §6). 520 wide, content margins 20, no tabs.
struct AddDownloadView: View {
    var requestID: UUID
    var initialItems: [AddItem]? = nil       // previews/tests inject resolved items
    var initialDestination: URL? = nil
    var initialStartAt: Bool = false
    var initialShowAll: Bool = false
    var onClose: () -> Void = {}

    @Environment(AppModel.self) private var model
    @Environment(WindowRouter.self) private var router

    @State private var items: [AddItem] = []
    @State private var linkText = ""
    @State private var destination: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    @State private var probe = VolumeProbe(name: "", isExternal: false, isConnected: true, freeBytes: nil, isFAT32: false)
    @State private var showStartAt = false
    @State private var addPaused = false
    @State private var startTime = StartAtPrompt.nextDefault()
    @State private var submitting = false
    @State private var submitError: String?
    @State private var loaded = false
    @State private var noPeersYet = false
    @FocusState private var linkFocused: Bool

    private var needsLink: Bool { items.isEmpty }
    private var single: AddItem? { items.count == 1 ? items[0] : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if needsLink {
                linkField
            } else if let item = single {
                if item.preview?.problem == .unreadableTorrent {
                    unreadable
                } else {
                    singleItem(item)
                }
            } else {
                multiItems
            }
            if !needsLink, single?.preview?.problem == nil {
                saveTo
                if showStartAt { startAtRow }
            }
            if let e = submitError {
                Label(e, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                    .symbolRenderingMode(.multicolor)
            }
            buttons
        }
        .padding(20)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear(perform: load)
        .task(id: items.first?.preview?.metadataPending) { await watchMagnet() }
        .onChange(of: destination) { _, new in
            probe = VolumeProbe.probe(new)
            Task { await reinspect() }
        }
    }

    // MARK: Loading

    private func load() {
        guard !loaded else { return }
        loaded = true
        destination = initialDestination ?? model.settings.defaultDirectory
        probe = VolumeProbe.probe(destination)
        showStartAt = initialStartAt
        if let initialItems {
            items = initialItems.map { var i = $0; i.expanded = initialShowAll; return i }
            return
        }
        let inputs = model.addRequests[requestID] ?? []
        items = inputs.map { AddItem(input: $0) }
        if items.isEmpty { linkFocused = true }
        Task { await reinspect() }
    }

    private func reinspect() async {
        let dest = destination
        for i in items.indices {
            let input = items[i].input
            let p = await model.inspect(input, destination: dest)
            if let j = items.firstIndex(where: { $0.input == input }) { items[j].preview = p }
        }
    }

    private func watchMagnet() async {
        guard let p = single?.preview, p.metadataPending else { return }
        let started = Date()
        while !Task.isCancelled, single?.preview?.metadataPending == true {
            try? await Task.sleep(for: .seconds(3))
            if Task.isCancelled { return }
            await reinspect()
            if Date().timeIntervalSince(started) >= 30, (single?.preview?.metadataPeers ?? 0) == 0 { noPeersYet = true }
        }
    }

    // MARK: Link field

    private var linkField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add Link")
                .font(.system(size: 15, weight: .semibold))
            TextField("Paste a magnet link or URL", text: $linkText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .focused($linkFocused)
                .onChange(of: linkText) { _, new in
                    let links = InputParser.links(in: new)
                    if !links.isEmpty, !new.hasSuffix(" ") {
                        items = links.map { AddItem(input: $0) }
                        Task { await reinspect() }
                    }
                }
            Text("One link per line.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Single item

    @ViewBuilder
    private func singleItem(_ item: AddItem) -> some View {
        let p = item.preview
        HStack(alignment: .top, spacing: 12) {
            FileIconView(image: icon(for: item), size: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(TideFormat.breakable(p?.name ?? "Reading…"))
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(2)
                    .truncationMode(.middle)
                if let dup = p?.duplicateOf {
                    HStack(spacing: 6) {
                        Text("Already in your downloads")
                        Button("Show") { router.showMain(select: dup); onClose() }
                            .buttonStyle(.link)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                } else {
                    Text(subtitle(item))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        if let ex = p?.existing {
            HStack(spacing: 8) {
                Image(systemName: "arrow.clockwise.circle")
                    .foregroundStyle(.tint)
                Text("Found \(TideFormat.bytes(ex.completedBytes)) already here — it’ll continue from \(TideFormat.percent(ex.fraction)).")
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.tint.opacity(0.12)))
        }
        if let p, p.kind != .http {
            filesBox(item, preview: p)
        }
    }

    private func subtitle(_ item: AddItem) -> String {
        guard let p = item.preview else { return " " }
        switch p.kind {
        case .torrent:
            let n = p.files.count
            return "Torrent · \(n) \(n == 1 ? "file" : "files") · \(TideFormat.bytes(p.totalBytes ?? 0))"
        case .magnet:
            if p.metadataPending { return "Magnet link" }
            return "Magnet link · \(p.files.count) files · \(TideFormat.bytes(p.totalBytes ?? 0))"
        case .http:
            if let t = p.totalBytes { return "Link · \(TideFormat.bytes(t))" }
            return "Link · Size unknown"
        }
    }

    private func icon(for item: AddItem) -> NSImage {
        guard let p = item.preview else { return FileIcons.icon(forName: "x.torrent") }
        if let main = p.files.filter({ item.selected.contains($0.index) }).max(by: { $0.length < $1.length }) {
            return FileIcons.icon(forName: main.name)
        }
        if p.kind == .http { return FileIcons.icon(forName: p.name) }
        return FileIcons.icon(forName: p.name.contains(".") ? p.name : "x.mkv")
    }

    @ViewBuilder
    private func filesBox(_ item: AddItem, preview p: AddPreview) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if p.metadataPending {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(noPeersYet && p.metadataPeers == 0
                             ? "No peers yet. It’ll keep trying in the background."
                             : "Getting file list from peers… (\(p.metadataPeers) connected)")
                            .font(.system(size: 12))
                    }
                    Text("You can start now — only the main video will be selected when the list arrives.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else if item.expanded {
                    ScrollView {
                        FileTreeView(files: p.files, selected: selectionBinding(item.id))
                    }
                    .frame(maxHeight: 240)
                    HStack(spacing: 4) {
                        Button("All") { setSelection(item.id, Set(p.files.map(\.index))) }
                        Text("·").foregroundStyle(.secondary)
                        Button("Videos Only") { setSelection(item.id, Set(p.files.videoIndexes)) }
                        Text("·").foregroundStyle(.secondary)
                        Button("None") { setSelection(item.id, []) }
                        Spacer()
                        Text("\(TideFormat.bytes(item.selectedBytes)) selected of \(TideFormat.bytes(p.totalBytes ?? 0))")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                } else {
                    let chosen = p.files.filter { item.selected.contains($0.index) }.sorted { $0.length > $1.length }
                    ForEach(chosen.prefix(4)) { f in
                        HStack(spacing: 6) {
                            Toggle("", isOn: Binding(
                                get: { item.selected.contains(f.index) },
                                set: { on in
                                    var s = item.selected
                                    if on { s.insert(f.index) } else { s.remove(f.index) }
                                    setSelection(item.id, s)
                                }))
                                .toggleStyle(.checkbox)
                                .labelsHidden()
                            FileIconView(image: FileIcons.icon(forName: f.name), size: 16)
                            Text(f.name)
                                .font(.system(size: 13))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(TideFormat.bytes(f.length))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .accessibilityElement(children: .combine)
                    }
                    if chosen.count > 4 {
                        Text("and \(chosen.count - 4) more")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    if chosen.isEmpty {
                        Text("No files selected")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    HStack(alignment: .firstTextBaseline) {
                        Text(skipLine(item, p))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button("Show All Files") { toggleExpanded(item.id) }
                            .buttonStyle(.link)
                            .font(.system(size: 11))
                    }
                }
            }
            .padding(4)
        } label: {
            Text("Files").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
        }
    }

    private func skipLine(_ item: AddItem, _ p: AddPreview) -> String {
        if item.selection == nil, let s = p.smart, s.skippedCount > 0 {
            return "Skipping \(s.skippedCount) \(s.skippedCount == 1 ? "extra" : "extras") (\(TideFormat.bytes(s.skippedBytes))): \(s.skippedDescription)"
        }
        let skipped = p.files.filter { !item.selected.contains($0.index) }
        if skipped.isEmpty { return "All \(p.files.count) files selected" }
        let bytes = skipped.reduce(Int64(0)) { $0 + $1.length }
        return "Skipping \(skipped.count) \(skipped.count == 1 ? "file" : "files") (\(TideFormat.bytes(bytes)))"
    }

    private func selectionBinding(_ id: UUID) -> Binding<Set<Int>> {
        Binding(get: { items.first { $0.id == id }?.selected ?? [] },
                set: { setSelection(id, $0) })
    }

    private func setSelection(_ id: UUID, _ s: Set<Int>) {
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].selection = s }
    }

    private func toggleExpanded(_ id: UUID) {
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].expanded.toggle() }
    }

    // MARK: Multi

    private var multiItems: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add \(items.count) Downloads")
                .font(.system(size: 15, weight: .semibold))
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(items) { item in
                        MultiItemCard(item: item, onToggle: { toggleExpanded(item.id) },
                                      selection: selectionBinding(item.id))
                    }
                }
            }
            .frame(maxHeight: 320)
        }
    }

    // MARK: Unreadable

    private var unreadable: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 4) {
                Text("This torrent file can’t be read.")
                    .font(.system(size: 15, weight: .semibold))
                Text("It may be incomplete or damaged. Try downloading it again.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Save To

    private var saveTo: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Save to")
                    .font(.system(size: 13))
                SaveToMenu(destination: $destination)
            }
            if let w = warning {
                HStack(spacing: 6) {
                    Image(systemName: w.symbol).foregroundStyle(w.tint.style)
                    Text(w.message)
                }
                .font(.system(size: 11))
                .padding(.leading, 52)
            }
        }
    }

    private var warning: DestinationWarning? {
        let needed = items.reduce(Int64(0)) { sum, i in
            sum + max(0, i.selectedBytes - (i.preview?.existing?.completedBytes ?? 0))
        }
        let largest = items.map(\.largestSelected).max() ?? 0
        return DestinationWarning.evaluate(probe: probe, needed: needed, largestFile: largest)
    }

    // MARK: Start at

    private var startAtRow: some View {
        HStack(spacing: 8) {
            Text("Starts at")
                .font(.system(size: 13))
            DatePicker("", selection: $startTime, displayedComponents: .hourAndMinute)
                .datePickerStyle(.stepperField)
                .labelsHidden()
                .fixedSize()
            Text("· \(dayWord(StartAtPrompt.resolve(startTime)))")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Button { showStartAt = false } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Don’t Schedule")
                .accessibilityLabel("Don’t Schedule")
            Spacer()
        }
        .padding(.leading, 52)
    }

    private func dayWord(_ d: Date) -> String {
        Calendar.current.isDateInToday(d) ? "today" : "tomorrow"
    }

    // MARK: Buttons

    private var timingTitle: String {
        if showStartAt { return "Start at \(TideFormat.time(StartAtPrompt.resolve(startTime)))" }
        return addPaused ? "Add Paused" : "Start Now"
    }

    @ViewBuilder private func checkLabel(_ t: String, _ on: Bool) -> some View {
        if on { Label(t, systemImage: "checkmark") } else { Text(t) }
    }

    private var primaryTitle: String {
        if showStartAt { return "Schedule" }
        if addPaused { return "Add" }
        if case .notConnected = warning { return "Add" }
        let n = items.filter(\.isAddable).count
        return n > 1 ? "Download \(n)" : "Download"
    }

    private var canSubmit: Bool {
        !submitting && !items.isEmpty && items.allSatisfy { $0.preview != nil } && items.contains(where: \.isAddable)
            && !(warning?.blocksAdding ?? false)
            && items.allSatisfy { $0.preview?.metadataPending == true || $0.preview?.kind == .http || !$0.selected.isEmpty }
    }

    private var buttons: some View {
        HStack {
            if single?.preview?.problem == .unreadableTorrent {
                Spacer()
                Button("Cancel", role: .cancel) { close() }
                    .keyboardShortcut(.cancelAction)
                Button("Choose Another File…") { chooseAnother() }
                    .keyboardShortcut(.defaultAction)
            } else {
                // Timing lives in a pop-up on the left so the window keeps exactly one
                // prominent, default button (a split Menu can't be drawn prominent on macOS).
                Menu {
                    Button { showStartAt = false; addPaused = false } label: { checkLabel("Download Now", !showStartAt && !addPaused) }
                    Button { showStartAt = true; addPaused = false } label: { checkLabel("Download At…", showStartAt) }
                    Button { showStartAt = false; addPaused = true } label: { checkLabel("Add Paused", addPaused) }
                } label: {
                    Label(timingTitle, systemImage: showStartAt ? "clock" : (addPaused ? "pause.circle" : "arrow.down.circle"))
                }
                .menuStyle(.button)
                .fixedSize()
                .help("When to Start")
                Spacer()
                Button("Cancel", role: .cancel) { close() }
                    .keyboardShortcut(.cancelAction)
                Button(primaryTitle) {
                    submit(showStartAt ? .at(StartAtPrompt.resolve(startTime)) : (addPaused ? .paused : .now))
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
            }
        }
    }

    private func close() {
        model.finishAddRequest(requestID)
        onClose()
    }

    private func chooseAnother() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.torrentFile]
        if panel.runModal() == .OK, let url = panel.url {
            items = [AddItem(input: .torrentFile(url))]
            Task { await reinspect() }
        }
    }

    private func submit(_ mode: StartMode) {
        guard canSubmit else { return }
        submitting = true
        submitError = nil
        let dest = destination
        let work = items.filter(\.isAddable)
        Task {
            do {
                for item in work {
                    guard let p = item.preview else { continue }
                    let opts = AddOptions(directory: dest, selectedFiles: item.selection.map { $0.sorted() }, start: mode)
                    try await model.add(p, options: opts)
                }
                submitting = false
                close()
            } catch {
                submitting = false
                submitError = error.localizedDescription
            }
        }
    }
}

/// Collapsible card for one of several items.
private struct MultiItemCard: View {
    var item: AddItem
    var onToggle: () -> Void
    @Binding var selection: Set<Int>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                FileIconView(image: FileIcons.icon(forName: item.preview?.name ?? "x.torrent"), size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.preview?.name ?? "Reading…")
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(line)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                Spacer()
                if let p = item.preview, !p.files.isEmpty {
                    Button(action: onToggle) {
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(item.expanded ? 90 : 0))
                    }
                    .buttonStyle(.borderless)
                    .help(item.expanded ? "Hide Files" : "Show Files")
                    .accessibilityLabel(item.expanded ? "Hide Files" : "Show Files")
                }
            }
            if item.expanded, let p = item.preview {
                FileTreeView(files: p.files, selected: $selection)
                    .padding(.leading, 42)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.5)))
    }

    private var line: String {
        guard let p = item.preview else { return " " }
        if p.duplicateOf != nil { return "Already in your downloads" }
        if p.problem == .unreadableTorrent { return "This torrent file can’t be read" }
        if p.problem == .invalidLink { return "This link can’t be used" }
        if p.metadataPending { return "Magnet link · getting file list" }
        var s = TideFormat.bytes(item.selectedBytes)
        if let sm = p.smart, sm.skippedCount > 0, item.selection == nil {
            s += " · only the main video, skipping \(sm.skippedCount) \(sm.skippedCount == 1 ? "extra" : "extras")"
        }
        return s
    }
}

/// Recent folders with volume and free space, then Choose Folder… (DESIGN.md §6 "Save To").
struct SaveToMenu: View {
    @Binding var destination: URL
    @Environment(AppModel.self) private var model

    private var folders: [URL] {
        var list = [destination, model.settings.defaultDirectory] + model.settings.recentDirectories
        var seen = Set<String>()
        list = list.filter { seen.insert($0.standardizedFileURL.path).inserted }
        return Array(list.prefix(5))
    }

    var body: some View {
        let current = VolumeProbe.probe(destination)
        Menu {
            ForEach(folders, id: \.self) { url in
                let v = VolumeProbe.probe(url)
                Button { destination = url } label: {
                    Label {
                        Text(folderLine(url, volumeName: v.name))
                        Text(TideFormat.volumeLine(v.status))
                    } icon: {
                        Image(systemName: v.symbol)
                    }
                }
            }
            Divider()
            Button("Choose Folder…") { choose() }
        } label: {
            Label {
                Text("\(folderLine(destination, volumeName: current.name)) · \(current.isConnected ? (current.freeBytes.map { "\(TideFormat.bytes($0)) free" } ?? "") : "Not connected")")
                    .monospacedDigit()
            } icon: {
                Image(systemName: current.symbol)
            }
        }
        .menuStyle(.button)
        .fixedSize()
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = destination
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { destination = url }
    }
}
