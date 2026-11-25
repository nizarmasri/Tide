import AppKit
import SwiftUI
import TideKit

/// Import Existing Download (DESIGN.md §6): choose → read progress → review → continue in place.
struct ImportView: View {
    var initialURL: URL?
    var initialCandidates: [ImportCandidate]?
    var onClose: () -> Void = {}

    @Environment(AppModel.self) private var model
    @Environment(WindowRouter.self) private var router

    enum Phase: Equatable { case choosing, scanning, review, nothing }
    @State private var phase: Phase = .choosing
    @State private var candidates: [ImportCandidate] = []
    @State private var chosen = Set<String>()
    @State private var selections: [String: Set<Int>] = [:]
    @State private var showFiles = false
    @State private var working = false
    @State private var errorText: String?
    @State private var started = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch phase {
            case .choosing:
                choosing
            case .scanning:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading progress…").font(.system(size: 13))
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            case .review:
                if candidates.count == 1, let c = candidates.first { single(c) } else { multiple }
            case .nothing:
                ContentUnavailableView {
                    Label("No Unfinished Download Here", systemImage: "tray")
                } description: {
                    Text("Tide looks for a .torrent file next to an .aria2 progress file.")
                } actions: {
                    Button("Choose Another Folder…") { choose() }
                }
                .frame(width: 440, height: 220)
            }
            if let e = errorText {
                Label(e, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .symbolRenderingMode(.multicolor)
            }
            if phase == .review || phase == .nothing {
                buttons
            }
        }
        .padding(20)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear(perform: start)
    }

    private func start() {
        guard !started else { return }
        started = true
        if let c = initialCandidates { setCandidates(c) }
        else if let url = initialURL { Task { await scan(url) } }
        else { DispatchQueue.main.async { choose() } }
    }

    private var choosing: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Import Existing Download")
                .font(.system(size: 15, weight: .semibold))
            Text("Choose the folder with your unfinished download, or its .torrent or .aria2 file.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onClose() }.keyboardShortcut(.cancelAction)
                Button("Choose…") { choose() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the folder with your unfinished download, or its .torrent or .aria2 file."
        panel.prompt = "Choose"
        panel.directoryURL = model.settings.defaultDirectory
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url {
            Task { await scan(url) }
        } else if phase == .choosing {
            onClose()
        }
    }

    private func scan(_ url: URL) async {
        phase = .scanning
        let found = await model.scanForImports(at: url)
        setCandidates(found)
    }

    private func setCandidates(_ found: [ImportCandidate]) {
        candidates = found
        chosen = Set(found.filter { !$0.alreadyInLibrary }.map(\.id))
        phase = found.isEmpty ? .nothing : .review
    }

    // MARK: Single review

    @ViewBuilder
    private func single(_ c: ImportCandidate) -> some View {
        HStack(alignment: .top, spacing: 12) {
            FileIconView(image: FileIcons.icon(forName: c.dataFile?.lastPathComponent ?? (c.name.contains(".") ? c.name : "x.mkv")), size: 48)
            VStack(alignment: .leading, spacing: 4) {
                Text(TideFormat.breakable(c.dataFile?.lastPathComponent ?? c.name))
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text("\(TideFormat.bytes(c.totalBytes)) · in \(c.directory.lastPathComponent) on \(c.volumeName)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }

        VStack(alignment: .leading, spacing: 6) {
            if let pieces = c.pieces { PieceBar(map: pieces) }
            if c.needsCheck {
                Text("Progress will be confirmed by a quick check")
                    .font(.system(size: 15, weight: .semibold))
            } else {
                Text("\(TideFormat.percent(c.fraction)) already downloaded")
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
            }
            Text(TideFormat.progress(c.completedBytes, of: c.totalBytes))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }

        VStack(alignment: .leading, spacing: 6) {
            checkRow(ok: c.torrentFile != nil, title: "Torrent file",
                     detail: c.torrentFile?.lastPathComponent ?? "Not found — the file list will be fetched from peers.",
                     warn: c.torrentFile == nil)
            checkRow(ok: c.progressFile != nil, title: "Progress file",
                     detail: c.progressFile.map { pf in
                         var s = pf.lastPathComponent
                         if let at = c.progressSavedAt { s += " · saved \(TideFormat.relative(at))" }
                         return s
                     } ?? missingProgressText(c),
                     warn: c.progressFile == nil)
            checkRow(ok: c.dataFile != nil, title: "Downloaded data",
                     detail: c.dataFile?.lastPathComponent ?? "Not found", warn: c.dataFile == nil)
        }

        if !c.files.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Files: \(filesSummary(c))")
                        .font(.system(size: 13))
                    Spacer()
                    Button(showFiles ? "Done" : "Change…") { showFiles.toggle() }
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                }
                if showFiles {
                    ScrollView {
                        FileTreeView(files: c.files, selected: selection(for: c))
                    }
                    .frame(maxHeight: 200)
                }
            }
        }
        Text("Continues in place — files stay in \(c.directory.lastPathComponent) on \(c.volumeName).")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
    }

    private func missingProgressText(_ c: ImportCandidate) -> String {
        if let s = c.estimatedCheckSeconds {
            return "Missing — Tide will check the data on disk first (about \(TideFormat.duration(s).lowercased()) on this drive)."
        }
        return "Missing — Tide will check the data on disk first."
    }

    private func checkRow(ok: Bool, title: String, detail: String, warn: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(ok ? AnyShapeStyle(Color.green) : AnyShapeStyle(Color.orange))
            Text(title)
                .font(.system(size: 13))
                .frame(width: 120, alignment: .leading)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(warn ? .primary : .secondary)
                .lineLimit(warn ? 2 : 1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func filesSummary(_ c: ImportCandidate) -> String {
        if let s = selections[c.id] {
            let n = s.count
            return n == c.files.count ? "All files" : "\(n) of \(c.files.count) files"
        }
        if let sm = c.smart, sm.skippedCount > 0 {
            return "Only the movie (skipping \(sm.skippedCount) \(sm.skippedCount == 1 ? "extra" : "extras"))"
        }
        return "All files"
    }

    private func selection(for c: ImportCandidate) -> Binding<Set<Int>> {
        Binding(get: { selections[c.id] ?? Set(c.files.filter(\.selected).map(\.index)) },
                set: { selections[c.id] = $0 })
    }

    // MARK: Multiple

    private var multiple: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Found \(candidates.count) Unfinished Downloads")
                .font(.system(size: 15, weight: .semibold))
            ForEach(candidates) { c in
                HStack(spacing: 10) {
                    Toggle("", isOn: Binding(get: { chosen.contains(c.id) },
                                             set: { on in if on { chosen.insert(c.id) } else { chosen.remove(c.id) } }))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .disabled(c.alreadyInLibrary)
                    FileIconView(image: FileIcons.icon(forName: c.dataFile?.lastPathComponent ?? "x.mkv"), size: 32)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(c.name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        ProgressCapsule(value: c.fraction, tint: .accent, height: 4)
                        Text(c.alreadyInLibrary ? "Already in your downloads"
                             : "\(TideFormat.percent(c.fraction)) · \(TideFormat.progress(c.completedBytes, of: c.totalBytes))")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    // MARK: Buttons

    private var buttons: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { onClose() }.keyboardShortcut(.cancelAction)
            if phase == .review {
                Button(primaryTitle) { importNow() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(working || chosen.isEmpty)
            }
        }
    }

    private var primaryTitle: String {
        if candidates.count == 1 { return "Continue Download" }
        return "Import \(chosen.count) \(chosen.count == 1 ? "Download" : "Downloads")"
    }

    private func importNow() {
        working = true
        errorText = nil
        let picked = candidates.filter { chosen.contains($0.id) }
        let files = selections.mapValues { $0.sorted() }
        Task {
            do {
                let ids = try await model.importDownloads(picked, selectedFiles: files)
                working = false
                onClose()
                router.showMain(select: ids.first)
            } catch {
                working = false
                errorText = error.localizedDescription
            }
        }
    }
}
