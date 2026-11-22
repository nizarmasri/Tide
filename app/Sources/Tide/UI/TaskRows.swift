import AppKit
import SwiftUI
import TideKit

// MARK: - Actions

@MainActor
enum TaskActions {
    static func perform(_ action: RowAction, task: DownloadTask, model: AppModel) {
        switch action {
        case .pause: model.pause([task.id])
        case .resume, .resumeAnyway: model.resume([task.id])
        case .startNow: model.startNow([task.id])
        case .showInFinder: Finder.reveal(task)
        case .stopSharing: model.setSeedPolicy([task.id], policy: .stop)
        case .fix(let fix): performFix(fix, task: task, model: model)
        case .none: break
        }
    }

    static func performFix(_ fix: FixAction, task: DownloadTask, model: AppModel) {
        switch fix {
        case .retry, .resolve: model.retry(task.id)
        case .copyLink: Finder.copyLink(task)
        case .restartEngine: model.restartEngine()
        case .chooseFolder:
            // The contract has no "move to folder" call yet; show the folder so the user can fix
            // permissions, then retry.
            NSWorkspace.shared.open(task.directory)
        case .chooseAnotherFile:
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.torrentFile]
            panel.allowsMultipleSelection = false
            if panel.runModal() == .OK, let url = panel.url { model.requestAdd([.torrentFile(url)]) }
        }
    }

    /// Pause/resume toggle used by ⌘. / ⌘/ and the context menu.
    static func togglePause(_ tasks: [DownloadTask], model: AppModel) {
        let pausable = tasks.filter { $0.phase.isPausable }
        if !pausable.isEmpty { model.pause(pausable.map(\.id)) } else { model.resume(tasks.map(\.id)) }
    }
}

// MARK: - Popover rows

/// 56pt active row (DESIGN.md §4).
struct PopoverTaskRow: View {
    var task: DownloadTask
    var eta: Int?
    var focused: Bool = false
    var onOpen: () -> Void

    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        let p = task.presentation(eta: eta)
        HStack(spacing: 10) {
            FileIconView(image: FileIcons.icon(for: task), size: 32)
            VStack(alignment: .leading, spacing: 0) {
                Text(task.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer().frame(height: 5)
                if let tint = p.barTint {
                    ProgressCapsule(value: p.barValue, tint: tint, height: 4)
                }
                Spacer().frame(height: 5)
                HStack(spacing: 4) {
                    if p.showsInlineSymbol {
                        InlineStateSymbol(presentation: p)
                    }
                    statusText(p.status)
                        .foregroundStyle(p.isError ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                }
                .font(.system(size: 11))
                .monospacedDigit()
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            RowActionButton(action: p.action) { TaskActions.perform(p.action, task: task, model: model) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(height: 56)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(hovering || focused ? 0.06 : 0))
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .onTapGesture(perform: onOpen)
        .contextMenu { TaskContextMenu(tasks: [task]) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(task.name)
        .accessibilityValue(p.accessibilityValue)
        .accessibilityAction(named: p.action.label) { TaskActions.perform(p.action, task: task, model: model) }
        .accessibilityAction(named: "Show in Finder") { Finder.reveal(task) }
    }
}

/// 36pt completed row.
struct PopoverCompletedRow: View {
    var task: DownloadTask
    var focused: Bool = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            FileIconView(image: FileIcons.icon(for: task), size: 24)
                .frame(width: 32)
            Text(task.name)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(TideFormat.bytes(task.totalBytes))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button { Finder.reveal(task) } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(CircleIconButtonStyle(size: 24))
            .help("Show in Finder")
            .accessibilityLabel("Show in Finder")
        }
        .padding(.horizontal, 8)
        .frame(height: 36)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(hovering || focused ? 0.06 : 0))
        )
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .onTapGesture(count: 2) { Finder.open(task) }
        .contextMenu { TaskContextMenu(tasks: [task]) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(task.name)
        .accessibilityValue("Downloaded, \(TideFormat.spokenBytes(task.totalBytes))")
    }
}

// MARK: - Window rows

/// 60pt standard list row (DESIGN.md §5).
struct WindowTaskRow: View {
    var task: DownloadTask
    var eta: Int?
    @Environment(AppModel.self) private var model

    var body: some View {
        let p = task.presentation(eta: eta)
        HStack(spacing: 10) {
            FileIconView(image: FileIcons.icon(for: task), size: 32)
            VStack(alignment: .leading, spacing: 0) {
                Text(task.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let tint = p.barTint {
                    Spacer().frame(height: 5)
                    ProgressCapsule(value: p.barValue, tint: tint, height: 4)
                    Spacer().frame(height: 5)
                } else {
                    Spacer().frame(height: 4)
                }
                HStack(spacing: 4) {
                    if p.showsInlineSymbol {
                        InlineStateSymbol(presentation: p)
                    }
                    statusText(p.detailStatus)
                        .foregroundStyle(p.isError ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if let peers = p.peersLine {
                        Text(peers).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .font(.system(size: 11))
                .monospacedDigit()
            }
            RowActionButton(action: p.action) { TaskActions.perform(p.action, task: task, model: model) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(height: 60)
        .highlightOnImport(task.justImported)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(task.name)
        .accessibilityValue(p.accessibilityValue)
        .accessibilityAction(named: p.action.label) { TaskActions.perform(p.action, task: task, model: model) }
        .accessibilityAction(named: "Show in Finder") { Finder.reveal(task) }
        .accessibilityAction(named: "Copy Magnet Link") { Finder.copyLink(task) }
    }
}

/// 28pt one-line row (View ▸ Compact Rows).
struct CompactTaskRow: View {
    var task: DownloadTask
    var eta: Int?

    var body: some View {
        let p = task.presentation(eta: eta)
        HStack(spacing: 8) {
            Image(systemName: p.symbol)
                .font(.system(size: 14))
                .foregroundStyle(p.symbolTint.style)
                .frame(width: 16)
            Text(task.name)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let tint = p.barTint {
                ProgressCapsule(value: p.barValue, tint: tint, height: 4).frame(width: 60)
            } else {
                Color.clear.frame(width: 60, height: 4)
            }
            Text(task.phase.isFinished ? "" : TideFormat.percent(task.fraction))
                .frame(width: 32, alignment: .trailing)
            Text(task.totalBytes > 0 ? TideFormat.bytes(task.totalBytes) : "—")
                .frame(width: 64, alignment: .trailing)
            Text(task.downloadSpeed > 0 ? TideFormat.speed(task.downloadSpeed) : "")
                .frame(width: 72, alignment: .trailing)
            Text(compactRight(p))
                .frame(width: 72, alignment: .trailing)
                .lineLimit(1)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .padding(.horizontal, 12)
        .frame(height: 28)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(task.name)
        .accessibilityValue(p.accessibilityValue)
    }

    private func compactRight(_ p: TaskPresentation) -> String {
        if let e = eta, task.downloadSpeed > 0 { return TideFormat.duration(e) }
        return task.phase.shortName
    }
}

/// 11pt state symbol that leads the status line of every non-downloading row.
struct InlineStateSymbol: View {
    var presentation: TaskPresentation
    var body: some View {
        Image(systemName: presentation.symbol)
            .font(.system(size: 11))
            .foregroundStyle(presentation.symbolTint.style)
            .contentTransition(.symbolEffect(.replace))
            .accessibilityHidden(true)
    }
}

// MARK: - Import highlight

private struct ImportHighlight: ViewModifier {
    var active: Bool
    @State private var opacity: Double = 0
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.tint.opacity(0.10 * opacity))
            )
            .onAppear {
                guard active else { return }
                opacity = 1
                withAnimation(.easeOut(duration: 1.0).delay(0.2)) { opacity = 0 }
            }
    }
}

extension View {
    func highlightOnImport(_ active: Bool) -> some View { modifier(ImportHighlight(active: active)) }
}

// MARK: - Context menu (DESIGN.md §5)

struct TaskContextMenu: View {
    var tasks: [DownloadTask]
    @Environment(AppModel.self) private var model

    private var plural: String { tasks.count == 1 ? "" : " \(tasks.count) Downloads" }

    var body: some View {
        let ids = tasks.map(\.id)
        let anyPausable = tasks.contains { $0.phase.isPausable }
        let anyFinished = tasks.contains { $0.phase.isFinished }
        let allFinished = tasks.allSatisfy { $0.phase.isFinished }

        if !allFinished {
            if anyPausable {
                Button("Pause\(plural)") { model.pause(ids) }
            } else {
                Button("Resume\(plural)") { model.resume(ids) }
            }
            Button("Start Now") { model.startNow(ids) }
            Button("Start At…") { StartAtPrompt.run(tasks: tasks, model: model) }
            Divider()
        }
        if tasks.count == 1, let t = tasks.first {
            Button("Open") { Finder.open(t) }.disabled(!t.phase.isFinished)
        }
        Button("Show in Finder") { tasks.forEach(Finder.reveal) }
        if anyFinished, let t = tasks.first(where: { $0.phase.isFinished }) {
            Button("Quick Look") { QuickLook.show(t) }
        }
        Divider()
        if tasks.count == 1, let t = tasks.first {
            Button(t.kind == .http ? "Copy Link" : "Copy Magnet Link") { Finder.copyLink(t) }
                .disabled(t.magnetLink == nil && t.sourceURL == nil)
        }
        if !allFinished {
            Menu("Speed Limit") {
                SpeedLimitMenuItems(current: tasks.count == 1 ? tasks[0].speedLimit : nil) { limit in
                    model.setSpeedLimit(ids, bytesPerSecond: limit)
                }
            }
            if tasks.count == 1, let t = tasks.first {
                Button("Move to Top") { model.move(t.id, to: .top) }
                Button("Move to Bottom") { model.move(t.id, to: .bottom) }
                if t.kind != .http { Button("Verify Data") { model.verify(t.id) } }
            }
        }
        Divider()
        Button("Remove\(plural)…") { RemoveFlow.run(tasks: tasks, model: model, trash: false) }
        Button("Remove and Move to Trash…", role: .destructive) { RemoveFlow.run(tasks: tasks, model: model, trash: true) }
    }
}

/// Unlimited / 1 / 2 / 5 / 10 / 25 MB/s / Custom…
struct SpeedLimitMenuItems: View {
    var current: Int64?
    var set: (Int64?) -> Void
    static let presets: [Int64] = [1, 2, 5, 10, 25].map { $0 * 1_000_000 }

    var body: some View {
        Button { set(nil) } label: { check(current == nil, "Unlimited") }
        ForEach(Self.presets, id: \.self) { v in
            Button { set(v) } label: { check(current == v, TideFormat.speed(v)) }
        }
        Divider()
        Button("Custom…") {
            if let v = CustomLimitPrompt.ask(current: current) { set(v) }
        }
    }

    @ViewBuilder private func check(_ on: Bool, _ title: String) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }
}
