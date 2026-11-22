import AppKit
import SwiftUI
import TideKit

/// Single-task inspector (DESIGN.md §5 Inspector).
struct InspectorView: View {
    var task: DownloadTask
    @Environment(AppModel.self) private var model
    @Environment(EtaEstimator.self) private var eta
    @Environment(MainWindowState.self) private var state

    var body: some View {
        @Bindable var state = state
        let p = task.presentation(eta: eta.eta(task))
        VStack(alignment: .leading, spacing: 0) {
            header(p)
                .padding(16)
            if task.kind != .http {
                Picker("", selection: $state.inspectorTab) {
                    ForEach(MainWindowState.InspectorTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            Divider()
            Group {
                switch task.kind == .http ? .info : state.inspectorTab {
                case .info: InfoTab(task: task)
                case .files: FilesTab(task: task)
                case .peers: PeersTab(task: task)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private func header(_ p: TaskPresentation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                FileIconView(image: FileIcons.icon(for: task), size: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text(TideFormat.breakable(task.name))
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .help(task.name)
                    HStack(spacing: 4) {
                        Image(systemName: p.symbol).foregroundStyle(p.symbolTint.style)
                        Text(p.stateName).foregroundStyle(.secondary)
                    }
                    .font(.system(size: 11))
                }
            }
            if let tint = p.barTint {
                ProgressCapsule(value: p.barValue, tint: tint, height: 6)
                    .accessibilityHidden(false)
                    .accessibilityLabel("Progress")
                    .accessibilityValue(TideFormat.precisePercent(p.barValue))
                HStack {
                    Text(TideFormat.precisePercent(task.fraction))
                    Spacer()
                    if let e = eta.eta(task) { Text(TideFormat.timeLeft(e)) }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    stat("Downloaded", TideFormat.progress(task.completedBytes, of: task.totalBytes))
                    stat("Speed", "↓ \(TideFormat.speed(task.downloadSpeed))  ↑ \(TideFormat.speed(task.uploadSpeed))")
                }
                GridRow {
                    stat("Peers", task.kind == .http ? "—" : "\(task.seeders) seeds · \(task.peers) peers")
                    stat("Limit", task.speedLimit.map { TideFormat.speed($0) } ?? "None")
                }
            }
            .padding(.top, 4)
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            statusText(value)
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Info

struct InfoTab: View {
    var task: DownloadTask
    @Environment(AppModel.self) private var model
    @State private var pieces: PieceMap?
    @State private var detailsOpen = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Saved to") {
                    HStack(spacing: 6) {
                        Image(systemName: task.volumeIsExternal ? "externaldrive" : "folder")
                            .foregroundStyle(.secondary)
                        Text(folderLine(task.directory, volumeName: task.volumeName))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button { Finder.reveal(task) } label: { Image(systemName: "arrow.right.circle.fill") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Show in Finder")
                            .accessibilityLabel("Show in Finder")
                    }
                }
                if !task.phase.isFinished {
                    Picker("Speed limit", selection: Binding(
                        get: { task.speedLimit ?? 0 },
                        set: { v in
                            if v == -1 {
                                if let c = CustomLimitPrompt.ask(current: task.speedLimit) {
                                    model.setSpeedLimit([task.id], bytesPerSecond: c)
                                }
                            } else {
                                model.setSpeedLimit([task.id], bytesPerSecond: v == 0 ? nil : v)
                            }
                        })) {
                        Text("Unlimited").tag(Int64(0))
                        ForEach(SpeedLimitMenuItems.presets, id: \.self) { Text(TideFormat.speed($0)).tag($0) }
                        if let l = task.speedLimit, !SpeedLimitMenuItems.presets.contains(l) {
                            Text(TideFormat.speed(l)).tag(l)
                        }
                        Divider()
                        Text("Custom…").tag(Int64(-1))
                    }
                }
                if task.kind != .http {
                    Picker("After download", selection: Binding(
                        get: { 0 },
                        set: { v in model.setSeedPolicy([task.id], policy: v == 0 ? nil : (v == 1 ? .stop : .ratio(1.0))) })) {
                        Text("Default (Stop)").tag(0)
                        Text("Stop").tag(1)
                        Text("Seed…").tag(2)
                    }
                }
                if let at = task.startAt {
                    LabeledContent("Start at", value: TideFormat.startsAt(at).replacingOccurrences(of: "Starts ", with: ""))
                }
            }
            if let pc = task.pieceCount, task.kind != .http {
                Section("Pieces") {
                    VStack(alignment: .leading, spacing: 6) {
                        if let pieces { PieceBar(map: pieces) } else { PieceBar(map: PieceMap(count: pc, bits: [])) }
                        Text("\(TideFormat.count(pieces?.doneCount ?? task.piecesDone ?? 0)) of \(TideFormat.count(pc)) pieces · \(TideFormat.bytes(task.pieceLength ?? 0)) each")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            Section {
                DisclosureGroup("Details", isExpanded: $detailsOpen) {
                    LabeledContent("Added", value: TideFormat.dayAndTime(task.addedAt))
                    if let h = task.infoHash {
                        LabeledContent("Info hash") {
                            Text(h).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                    if task.magnetLink != nil || task.sourceURL != nil {
                        LabeledContent(task.kind == .http ? "Link" : "Magnet link") {
                            Button("Copy") { Finder.copyLink(task) }
                        }
                    }
                    if task.kind != .http { LabeledContent("Trackers", value: "\(task.trackerCount)") }
                    if let c = task.createdBy { LabeledContent("Created by", value: c) }
                    if let c = task.comment { LabeledContent("Comment", value: c) }
                    if let g = task.gid {
                        LabeledContent("aria2 GID") { Text(g).font(.system(size: 11, design: .monospaced)).textSelection(.enabled) }
                    }
                    if case .error(let p) = task.phase {
                        if let code = p.code { LabeledContent("Error code", value: "\(code)") }
                        if let raw = p.rawMessage { LabeledContent("Message") { Text(raw).textSelection(.enabled) } }
                    }
                }
            }
            if case .error(let p) = task.phase, let ex = p.explanation {
                Section {
                    Label { Text(ex) } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                    Button(p.fix.label) { TaskActions.performFix(p.fix, task: task, model: model) }
                }
            }
        }
        .formStyle(.grouped)
        .task(id: task.id) {
            pieces = await model.pieces(task.id)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if task.phase.isActive { pieces = await model.pieces(task.id) }
            }
        }
    }
}

// MARK: - Files

struct FilesTab: View {
    var task: DownloadTask
    @Environment(AppModel.self) private var model
    @State private var files: [TaskFile] = []

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                FileTreeView(files: files, selected: Binding(
                    get: { Set(files.filter(\.selected).map(\.index)) },
                    set: { new in
                        files = files.map { var f = $0; f.selected = new.contains(f.index); return f }
                        Task { try? await model.setSelectedFiles(task.id, indexes: new.sorted()) }
                    }), showProgress: true)
                .padding(12)
            }
            Divider()
            HStack {
                Text("\(TideFormat.bytes(files.filter(\.selected).reduce(0) { $0 + $1.length })) selected")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 32)
        }
        .task(id: task.id) {
            files = await model.files(task.id)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                if task.phase.isActive { files = await model.files(task.id) }
            }
        }
    }
}

// MARK: - Peers

struct PeersTab: View {
    var task: DownloadTask
    @Environment(AppModel.self) private var model
    @State private var peers: [Peer] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Connected to \(peers.count) \(peers.count == 1 ? "peer" : "peers") · \(peers.filter(\.isSeeder).count) seeds")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            List(peers) { peer in
                HStack(spacing: 8) {
                    Text(peer.address)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(width: 128, alignment: .leading)
                    Text(peer.client)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(TideFormat.percent(peer.progress))
                        .font(.system(size: 11))
                        .frame(width: 34, alignment: .trailing)
                    Text(peer.downloadSpeed > 0 ? TideFormat.speed(peer.downloadSpeed) : "")
                        .font(.system(size: 11))
                        .frame(width: 64, alignment: .trailing)
                }
                .monospacedDigit()
                .frame(height: 28)
                .accessibilityElement(children: .combine)
            }
            .listStyle(.plain)
            .transaction { $0.animation = nil }
        }
        .task(id: task.id) {
            while !Task.isCancelled {
                peers = await model.peers(task.id).sorted { $0.downloadSpeed > $1.downloadSpeed }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}

// MARK: - Multi-select

struct MultiInspectorView: View {
    var tasks: [DownloadTask]
    @Environment(AppModel.self) private var model

    var body: some View {
        let total = tasks.reduce(Int64(0)) { $0 + $1.totalBytes }
        let done = tasks.reduce(Int64(0)) { $0 + $1.completedBytes }
        let frac = total > 0 ? Double(done) / Double(total) : 0
        VStack(alignment: .leading, spacing: 12) {
            Text("\(tasks.count) Downloads")
                .font(.system(size: 15, weight: .semibold))
            Text("\(TideFormat.bytes(total)) · \(TideFormat.percent(frac)) overall")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            ProgressCapsule(value: frac, tint: .accent, height: 6)
            HStack {
                Button("Pause") { model.pause(tasks.map(\.id)) }
                Button("Resume") { model.resume(tasks.map(\.id)) }
                Button("Remove…") { RemoveFlow.run(tasks: tasks, model: model, trash: false) }
            }
            Form {
                Picker("Speed limit", selection: Binding(get: { Int64(0) }, set: { v in
                    model.setSpeedLimit(tasks.map(\.id), bytesPerSecond: v == 0 ? nil : v)
                })) {
                    Text("Unlimited").tag(Int64(0))
                    ForEach(SpeedLimitMenuItems.presets, id: \.self) { Text(TideFormat.speed($0)).tag($0) }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            Spacer()
        }
        .padding(16)
    }
}
