import AppKit
import SwiftUI
import TideKit

/// First run (DESIGN.md §6 "First run: Welcome window"), 480 wide, one screen.
struct WelcomeView: View {
    var initialFound: [ImportCandidate]? = nil
    var onClose: () -> Void = {}

    @Environment(AppModel.self) private var model
    @Environment(WindowRouter.self) private var router

    @State private var folder: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    @State private var makeDefault = true
    @State private var openAtLogin = true
    @State private var found: [ImportCandidate] = []
    @State private var scanned = false
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 16) {
            AppIconView()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text("Welcome to Tide")
                    .font(.system(size: 15, weight: .semibold))
                Text("Torrents, magnet links and downloads, quietly in your menu bar.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            // Plain rows rather than a Form: a grouped Form inside a content-sized window loops
            // AppKit's constraint pass.
            VStack(spacing: 0) {
                HStack {
                    Text("Save to").font(.system(size: 13))
                    Spacer(minLength: 12)
                    SaveToMenu(destination: $folder)
                }
                .frame(minHeight: 40)
                Divider()
                switchRow("Open torrents and magnet links with Tide", $makeDefault)
                Divider()
                switchRow("Open at login", $openAtLogin)
            }
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.5)))

            if let c = found.first {
                HStack(spacing: 10) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 20))
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(found.count == 1 ? "Found an unfinished download in \(folder.lastPathComponent)"
                             : "Found \(found.count) unfinished downloads in \(folder.lastPathComponent)")
                            .font(.system(size: 13, weight: .medium))
                        Text("\(c.dataFile?.lastPathComponent ?? c.name) — \(TideFormat.percent(c.fraction)) of \(TideFormat.bytes(c.totalBytes))")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    Button("Import…") {
                        router.showImport(nil, candidates: found)
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.6)))
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else if scanned {
                Button("Import Existing Download…") { router.showImport() }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
            }

            HStack {
                Spacer()
                Button("Get Started") { finish() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .animation(.smooth(duration: 0.3), value: found.count)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            folder = model.settings.defaultDirectory
            openAtLogin = model.settings.openAtLogin
            if let initialFound { found = initialFound; scanned = true } else { Task { await scan() } }
        }
        .onChange(of: folder) { _, _ in Task { await scan() } }
    }

    private func switchRow(_ title: String, _ on: Binding<Bool>) -> some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer(minLength: 12)
            Toggle(title, isOn: on).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
        .frame(minHeight: 40)
    }

    private func scan() async {
        let results = await model.scanForImports(at: folder)
        found = results.filter { !$0.alreadyInLibrary }
        scanned = true
    }

    private func finish() {
        var s = model.settings
        s.defaultDirectory = folder
        s.openAtLogin = openAtLogin
        s.welcomeDone = true
        model.settings = s
        model.rememberDirectory(folder)
        if makeDefault { AppHooks.makeDefaultApp() }
        onClose()
    }
}
