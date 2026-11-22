import AppKit
import QuickLookUI
import SwiftUI
import TideKit
import UniformTypeIdentifiers

extension UTType {
    static let torrentFile = UTType(importedAs: "org.bittorrent.torrent", conformingTo: .data)
}

/// The window dialogs attach to (the Downloads window when it's open).
@MainActor
enum DialogHost {
    static weak var window: NSWindow?

    static func run(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let w = window, w.isVisible {
            alert.beginSheetModal(for: w, completionHandler: completion)
        } else {
            NSApp.activate()
            completion(alert.runModal())
        }
    }
}

// MARK: - Remove

@MainActor
enum RemoveFlow {
    static func run(tasks: [DownloadTask], model: AppModel, trash: Bool) {
        guard !tasks.isEmpty else { return }
        let incomplete = tasks.filter { !$0.phase.isFinished }
        let ids = tasks.map(\.id)

        // Completed tasks leave the list without asking; trashing files always asks.
        if incomplete.isEmpty && !trash {
            Task { try? await model.remove(ids, trashFiles: false) }
            return
        }
        let alert = incomplete.isEmpty ? makeTrashAlert(tasks: tasks) : makeAlert(tasks: tasks)
        DialogHost.run(alert) { response in
            if incomplete.isEmpty {
                if response == .alertSecondButtonReturn { Task { try? await model.remove(ids, trashFiles: true) } }
                return
            }
            switch response {
            case .alertFirstButtonReturn: Task { try? await model.remove(ids, trashFiles: false) }
            case .alertSecondButtonReturn: Task { try? await model.remove(ids, trashFiles: true) }
            default: break
            }
        }
    }

    /// Incomplete download(s): [Remove] (default) · [Remove and Move to Trash] (destructive) · [Cancel].
    static func makeAlert(tasks: [DownloadTask]) -> NSAlert {
        let alert = NSAlert.tide()
        alert.alertStyle = .informational
        let done = tasks.reduce(Int64(0)) { $0 + $1.completedBytes }
        if tasks.count == 1, let t = tasks.first {
            alert.messageText = "Remove “\(TideFormat.shortName(t.name, max: 36))”?"
        } else {
            alert.messageText = "Remove \(tasks.count) Downloads?"
        }
        let t = tasks[0]
        let place = "\(t.directory.lastPathComponent) on \(t.volumeName)"
        if done > 0 {
            alert.informativeText = "The \(TideFormat.bytes(done)) already downloaded stays in \(place), so you can import it later."
        } else {
            alert.informativeText = "Nothing has been downloaded yet."
        }
        alert.addButton(withTitle: "Remove")
        let trash = alert.addButton(withTitle: "Remove and Move to Trash")
        trash.hasDestructiveAction = true
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"
        return alert
    }

    /// Completed download(s): moving files to the Trash confirms, Cancel is the default.
    static func makeTrashAlert(tasks: [DownloadTask]) -> NSAlert {
        let alert = NSAlert.tide()
        alert.alertStyle = .warning
        if tasks.count == 1, let t = tasks.first {
            alert.messageText = "Move “\(TideFormat.shortName(t.name, max: 36))” to the Trash?"
            alert.informativeText = "\(TideFormat.bytes(t.totalBytes)) in \(t.directory.lastPathComponent) on \(t.volumeName). It stays in the Trash until you empty it."
        } else {
            let total = tasks.reduce(Int64(0)) { $0 + $1.totalBytes }
            alert.messageText = "Move \(tasks.count) Downloads to the Trash?"
            alert.informativeText = "\(TideFormat.bytes(total)) in total. They stay in the Trash until you empty it."
        }
        alert.addButton(withTitle: "Cancel")
        let trash = alert.addButton(withTitle: "Move to Trash")
        trash.hasDestructiveAction = true
        return alert
    }
}

// MARK: - Quit

@MainActor
enum QuitFlow {
    static func makeAlert(activeCount: Int) -> NSAlert {
        let alert = NSAlert.tide()
        alert.messageText = "Quit Tide?"
        alert.informativeText = activeCount == 1
            ? "1 download will pause and continue when you open Tide again."
            : "\(activeCount) downloads will pause and continue when you open Tide again."
        alert.addButton(withTitle: "Quit")
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don’t ask again"
        return alert
    }
}

// MARK: - Start At…

@MainActor
enum StartAtPrompt {
    static func run(tasks: [DownloadTask], model: AppModel) {
        let picker = NSDatePicker()
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = .hourMinute
        picker.dateValue = nextDefault()
        picker.sizeToFit()
        let alert = NSAlert.tide()
        alert.messageText = "Start At"
        alert.informativeText = "Starts at this time today, or tomorrow if it has already passed."
        alert.accessoryView = picker
        alert.addButton(withTitle: "Schedule")
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"
        DialogHost.run(alert) { r in
            guard r == .alertFirstButtonReturn else { return }
            model.startAt(tasks.map(\.id), date: resolve(picker.dateValue))
        }
    }

    /// Today at that time, or tomorrow if it's already past.
    static func resolve(_ picked: Date, now: Date = Date(), calendar: Calendar = .current) -> Date {
        let hm = calendar.dateComponents([.hour, .minute], from: picked)
        var d = calendar.date(bySettingHour: hm.hour ?? 0, minute: hm.minute ?? 0, second: 0, of: now) ?? now
        if d <= now { d = calendar.date(byAdding: .day, value: 1, to: d) ?? d }
        return d
    }

    static func nextDefault(now: Date = Date(), calendar: Calendar = .current) -> Date {
        calendar.date(bySettingHour: 1, minute: 0, second: 0, of: now) ?? now
    }
}

// MARK: - Custom speed limit

@MainActor
enum CustomLimitPrompt {
    static func ask(current: Int64?) -> Int64? {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        field.placeholderString = "MB/s"
        if let c = current { field.stringValue = String(format: "%g", Double(c) / 1_000_000) }
        let alert = NSAlert.tide()
        alert.messageText = "Custom Speed Limit"
        alert.informativeText = "Megabytes per second."
        alert.accessoryView = field
        alert.addButton(withTitle: "Set Limit")
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"
        alert.window.initialFirstResponder = field
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let v = Double(field.stringValue.replacingOccurrences(of: ",", with: ".")) ?? 0
        return v > 0 ? Int64(v * 1_000_000) : nil
    }
}

// MARK: - Quick Look

@MainActor
final class QuickLook: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLook()
    private var url: URL?

    static func show(_ task: DownloadTask) {
        guard let f = task.primaryFile, FileManager.default.fileExists(atPath: f.path) else {
            Finder.reveal(task); return
        }
        shared.url = f
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = shared
        panel.reloadData()
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { url == nil ? 0 : 1 }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { url as NSURL? }
    }
}

extension NSAlert {
    /// An alert that shows Tide's icon (not a generic document or folder).
    @MainActor static func tide() -> NSAlert {
        let a = NSAlert()
        a.icon = NSApp.applicationIconImage
        return a
    }
}
