import AppKit
import SwiftUI
import TideKit

/// The 360-wide menu bar popover (DESIGN.md §4). Hosted inside a glass NSPanel; everything
/// in here is flat.
struct PopoverView: View {
    @Environment(AppModel.self) private var model
    @Environment(EtaEstimator.self) private var eta
    @Environment(ClipboardStatus.self) private var clipboard
    @Environment(WindowRouter.self) private var router

    /// Reports the natural height so the panel can resize around it.
    var onHeightChange: (CGFloat) -> Void = { _ in }
    var maxHeight: CGFloat = 600

    @State private var focusIndex: Int? = nil
    @FocusState private var focused: Bool

    static let width: CGFloat = 360
    static let maxActiveRows = 6

    private var snap: EngineSnapshot { model.snapshot }
    private var active: [DownloadTask] { snap.inProgress }
    private var recentDone: [DownloadTask] {
        let cutoff = Date().addingTimeInterval(-86_400)
        return Array(snap.finished.filter { ($0.completedAt ?? .distantPast) > cutoff }.prefix(3))
    }

    var body: some View {
        let summary = SnapshotSummary(snap, etas: eta.etas)
        VStack(spacing: 0) {
            header(summary)
            if summary.isEmpty {
                emptyState
            } else {
                if let banner = PopoverBanner.pick(snap, clipboardHasLink: clipboard.hasLink) {
                    BannerView(banner: banner, action: { perform(banner) })
                        .padding(.horizontal, 8)
                        .padding(.bottom, 4)
                        .transition(.opacity)
                }
                taskList
            }
            footer
        }
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeightChange($0) }
        .acceptsDownloadDrops(model)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.return) { openFocused(); return .handled }
        .onKeyPress(.space) { quickLookFocused(); return .handled }
        .onAppear { model.surfaceAppeared("popover"); focused = true }
        .onDisappear { model.surfaceDisappeared("popover") }
        .animation(.easeInOut(duration: 0.2), value: PopoverBanner.pick(snap, clipboardHasLink: clipboard.hasLink))
    }

    // MARK: Header

    @ViewBuilder
    private func header(_ s: SnapshotSummary) -> some View {
        HStack(alignment: .center, spacing: 4) {
            if s.isEmpty {
                Text("Downloads")
                    .font(.system(size: 13, weight: .semibold))
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.headline)
                        .font(.system(size: 17, weight: .semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                    Text(s.subline)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            AddMenuButton()
            if !s.isEmpty {
                Button {
                    if s.showsPauseAll { model.pauseAll() } else if case .outsideWindow = snap.schedule {
                        model.startNow(snap.inProgress.map(\.id))
                    } else { model.resumeAll() }
                } label: {
                    Image(systemName: s.showsPauseAll ? "pause.fill" : "play.fill")
                }
                .buttonStyle(CircleIconButtonStyle())
                .help(s.showsPauseAll ? "Pause All" : s.goLabel)
                .accessibilityLabel(s.showsPauseAll ? "Pause All" : s.goLabel)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
    }

    // MARK: List

    private var taskList: some View {
        VStack(spacing: 0) {
            if !active.isEmpty {
                let rows = ForEach(Array(active.enumerated()), id: \.element.id) { i, task in
                    PopoverTaskRow(task: task, eta: eta.eta(task), focused: focusIndex == i) {
                        router.closePopover()
                        router.showMain(select: task.id)
                    }
                }
                if active.count > Self.maxActiveRows {
                    ScrollView(.vertical) { VStack(spacing: 0) { rows } }
                        .scrollIndicators(.automatic)
                        .frame(height: CGFloat(Self.maxActiveRows) * 56)
                } else {
                    VStack(spacing: 0) { rows }
                }
            }
            if !recentDone.isEmpty {
                // 8 here + 8 list inset = the 16pt text inset shared with the header and footer.
                HStack {
                    SectionHeader(title: "Completed")
                    Spacer()
                    Button("Clear") { model.clearCompleted() }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                ForEach(Array(recentDone.enumerated()), id: \.element.id) { i, task in
                    PopoverCompletedRow(task: task, focused: focusIndex == active.count + i)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .transaction { t in t.animation = nil }  // live updates never animate layout
    }

    // MARK: Empty

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("No Downloads")
                .font(.system(size: 15, weight: .semibold))
            Text("Drop a torrent, magnet link or URL here.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("Paste Link") { addFromClipboard() }
                Button("Import Existing Download…") { router.closePopover(); router.showImport() }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .accessibilityElement(children: .contain)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Button { model.toggleSlowMode() } label: {
                    Image(systemName: snap.slowMode ? "tortoise.fill" : "tortoise")
                        .foregroundStyle(snap.slowMode ? AnyShapeStyle(Color.indigo) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(CircleIconButtonStyle())
                .help("Slow Mode (\(TideFormat.speed(model.settings.slowModeDownLimit)))")
                .accessibilityLabel(snap.slowMode ? "Turn Off Slow Mode" : "Turn On Slow Mode")

                if let v = snap.defaultVolume {
                    Text(TideFormat.volumeLine(v))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button { router.closePopover(); router.showMain() } label: {
                    Image(systemName: "macwindow").foregroundStyle(.secondary)
                }
                .buttonStyle(CircleIconButtonStyle())
                .help("Open Downloads Window")
                .accessibilityLabel("Open Downloads Window")

                Menu {
                    Button("Settings…") { router.closePopover(); router.showSettings() }
                        .keyboardShortcut(",", modifiers: .command)
                    Button("About Tide") { router.closePopover(); router.showAbout() }
                    Divider()
                    Button("Quit Tide") { NSApp.terminate(nil) }
                        .keyboardShortcut("q", modifiers: .command)
                } label: {
                    Image(systemName: "gearshape").foregroundStyle(.secondary)
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(CircleIconButtonStyle())
                .fixedSize()
                .help("Settings")
                .accessibilityLabel("Settings")
            }
            // The 28pt tortoise button's glyph starts at the 16pt text inset.
            .padding(.horizontal, 12)
            .frame(height: 40)
        }
    }

    // MARK: Actions

    private func perform(_ banner: PopoverBanner) {
        switch banner {
        case .engineStopped: model.restartEngine()
        case .autoPaused: model.resumeAll()
        case .clipboardLink: addFromClipboard()
        }
    }

    private func addFromClipboard() {
        let inputs = clipboard.readInputs()
        router.closePopover()
        if inputs.isEmpty { router.showAddLink() } else { model.requestAdd(inputs) }
    }

    private var focusables: [DownloadTask] { active + recentDone }

    private func move(_ d: Int) {
        let n = focusables.count
        guard n > 0 else { return }
        focusIndex = ((focusIndex ?? (d > 0 ? -1 : n)) + d + n) % n
    }

    private func openFocused() {
        guard let i = focusIndex, focusables.indices.contains(i) else { return }
        let t = focusables[i]
        router.closePopover()
        if t.phase.isFinished { Finder.open(t) } else { router.showMain(select: t.id) }
    }

    private func quickLookFocused() {
        guard let i = focusIndex, focusables.indices.contains(i), focusables[i].phase.isFinished else { return }
        QuickLook.show(focusables[i])
    }
}

/// `plus` menu: Add Link… / Open Torrent File… / Import Existing Download…
struct AddMenuButton: View {
    @Environment(WindowRouter.self) private var router
    var body: some View {
        Menu {
            Button("Add Link…") { router.closePopover(); router.showAddLink() }
            Button("Open Torrent File…") { router.closePopover(); router.openTorrentFile() }
            Button("Import Existing Download…") { router.closePopover(); router.showImport() }
        } label: {
            Image(systemName: "plus")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(CircleIconButtonStyle())
        .fixedSize()
        .help("Add")
        .accessibilityLabel("Add")
    }
}

/// One contextual banner (DESIGN.md §4): 36pt, radius 10, 12% state-colour fill.
struct BannerView: View {
    var banner: PopoverBanner
    var action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: banner.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(banner.tint.style)
            Text(banner.text)
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(banner.actionTitle, action: action)
                .buttonStyle(.borderless)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 36)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(reduceTransparency
                      ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
                      : AnyShapeStyle(banner.tint.color.opacity(scheme == .dark ? 0.18 : 0.12)))
        )
        .overlay {
            if reduceTransparency {
                RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(banner.tint.color, lineWidth: 1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
