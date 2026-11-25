import AppKit
import Observation
import SwiftUI
import TideKit

/// The menu bar item: drawn template glyph, drag-and-drop target, left-click popover,
/// right-click menu (DESIGN.md §3).
@MainActor
final class StatusItemController: NSObject {
    private let services: AppServices
    private var model: AppModel { services.model }
    private let statusItem: NSStatusItem
    private let overlay: StatusItemOverlay
    private lazy var popover = PopoverPanelController(services: services)

    private var lastGlyph: MenuBarGlyph?
    private var lastAXValue = ""
    private var justCompletedUntil: Date?
    private var finishedIDs = Set<TaskID>()
    private var completedTimer: Timer?

    init(services: AppServices) {
        self.services = services
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        overlay = StatusItemOverlay()
        super.init()

        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.toolTip = "Show downloads"
            button.setAccessibilityLabel("Tide")
            button.setAccessibilityHelp("Show downloads")
            overlay.frame = button.bounds
            overlay.autoresizingMask = [.width, .height]
            button.addSubview(overlay)
        }
        overlay.onLeftClick = { [weak self] in self?.togglePopover() }
        overlay.onRightClick = { [weak self] in self?.showMenu() }
        overlay.onDrop = { [weak self] inputs in
            guard let self, !inputs.isEmpty else { return }
            self.popover.close()
            self.model.requestAdd(inputs)
        }
        overlay.onDragHighlight = { [weak self] on in self?.statusItem.button?.highlight(on) }

        finishedIDs = Set(model.snapshot.finished.map(\.id))
        observe()
    }

    var isPopoverShown: Bool { popover.isShown }

    func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown { popover.close() } else { popover.show(below: button) }
    }

    func closePopover() { popover.close() }

    // MARK: Observation

    private func observe() {
        withObservationTracking {
            _ = model.snapshot
            _ = model.settings.showSpeedInMenuBar
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.update()
                self?.observe()
            }
        }
        update()
    }

    private func update() {
        let snap = model.snapshot
        // Detect completions for the 4 s checkmark.
        let finishedNow = Set(snap.finished.map(\.id))
        if !finishedNow.subtracting(finishedIDs).isEmpty {
            justCompletedUntil = Date().addingTimeInterval(4)
            completedTimer?.invalidate()
            completedTimer = Timer.scheduledTimer(withTimeInterval: 4.05, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.update() }
            }
        }
        finishedIDs = finishedNow
        let just = (justCompletedUntil ?? .distantPast) > Date()
        let glyph = MenuBarGlyph(snap, showSpeed: model.settings.showSpeedInMenuBar, justCompleted: just)
        if glyph != lastGlyph {
            lastGlyph = glyph
            render(glyph)
        }
        let ax = MenuBarGlyph.accessibilityValue(snap)
        if ax != lastAXValue {
            lastAXValue = ax
            statusItem.button?.setAccessibilityValue(ax)
        }
    }

    private func render(_ glyph: MenuBarGlyph) {
        guard let button = statusItem.button else { return }
        button.image = GlyphRenderer.image(glyph)
        if let text = glyph.speedText {
            let para = NSMutableParagraphStyle()
            para.alignment = .right
            button.attributedTitle = NSAttributedString(string: text, attributes: [
                .font: GlyphRenderer.speedFont, .paragraphStyle: para,
            ])
            button.imagePosition = .imageTrailing
            statusItem.length = GlyphRenderer.speedTextWidth + 4 + 18 + 10
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
            statusItem.length = NSStatusItem.squareLength
        }
    }

    // MARK: Right-click menu

    private func showMenu() {
        popover.close()
        let menu = NSMenu()
        let moving = model.anythingMoving
        menu.addItem(item(moving ? "Pause All" : "Resume All") { [weak self] in
            guard let self else { return }
            if moving { self.model.pauseAll() } else { self.model.resumeAll() }
        })
        let slow = item("Slow Mode") { [weak self] in self?.model.toggleSlowMode() }
        slow.state = model.slowMode ? .on : .off
        menu.addItem(slow)
        menu.addItem(.separator())
        let paste = item("Add from Clipboard") { [weak self] in
            guard let self else { return }
            let inputs = self.services.clipboard.readInputs()
            if inputs.isEmpty { self.services.router.showAddLink() } else { self.model.requestAdd(inputs) }
        }
        menu.addItem(paste)
        menu.addItem(item("Search Torrents") { [weak self] in self?.services.router.showSearch() })
        menu.addItem(item("Open Downloads Window") { [weak self] in self?.services.router.showMain() })
        menu.addItem(.separator())
        menu.addItem(item("Settings…") { [weak self] in self?.services.router.showSettings() })
        menu.addItem(item("Quit Tide") { NSApp.terminate(nil) })
        if let button = statusItem.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 5), in: button)
        }
    }

    private func item(_ title: String, _ action: @escaping () -> Void) -> NSMenuItem {
        let i = ClosureMenuItem(title: title, action: action)
        return i
    }
}

/// NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private var handler: () -> Void
    init(title: String, keyEquivalent: String = "", modifiers: NSEvent.ModifierFlags = [.command], action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(fire), keyEquivalent: keyEquivalent)
        keyEquivalentModifierMask = modifiers
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}

/// Transparent view over the status button: owns clicks and accepts drops.
final class StatusItemOverlay: NSView {
    var onLeftClick: () -> Void = {}
    var onRightClick: () -> Void = {}
    var onDrop: ([AddInput]) -> Void = { _ in }
    var onDragHighlight: (Bool) -> Void = { _ in }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .URL, .string])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { onRightClick() } else { onLeftClick() }
    }
    override func rightMouseDown(with event: NSEvent) { onRightClick() }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let ok = !DropReader.inputs(from: sender.draggingPasteboard).isEmpty
        onDragHighlight(ok)
        return ok ? .copy : []
    }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { onDragHighlight(false) }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        onDragHighlight(false)
        let inputs = DropReader.inputs(from: sender.draggingPasteboard)
        onDrop(inputs)
        return !inputs.isEmpty
    }
}
