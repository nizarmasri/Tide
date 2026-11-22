import AppKit
import SwiftUI
import TideKit

/// Borderless panel that can take key focus without activating the app.
final class PopoverPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Layer-backed view that clips everything (including the glass backdrop) to a continuous
/// rounded rect, so the window's alpha, shadow and rim are rounded too.
final class RoundedContainerView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = PopoverPanelController.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor
        autoresizingMask = [.width, .height]
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isOpaque: Bool { false }
}

/// Hosts PopoverView in a Liquid Glass panel, 4pt below the status item (DESIGN.md §4).
@MainActor
final class PopoverPanelController: NSObject, NSWindowDelegate {
    private let services: AppServices
    private var panel: PopoverPanel?
    private var hosting: NSHostingView<AnyView>?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var anchor: NSRect = .zero
    private var contentHeight: CGFloat = 240
    private weak var button: NSStatusBarButton?

    init(services: AppServices) { self.services = services }

    var isShown: Bool { panel?.isVisible ?? false }

    private func makePanel() -> PopoverPanel {
        let p = PopoverPanel(contentRect: NSRect(x: 0, y: 0, width: PopoverView.width, height: 240),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        p.animationBehavior = .utilityWindow
        p.delegate = self

        let root = PopoverView(onHeightChange: { [weak self] h in self?.heightChanged(h) })
            .tideEnvironment(services)
        let host = NSHostingView(rootView: AnyView(root))
        host.sizingOptions = []
        hosting = host

        let glass = NSGlassEffectView()
        glass.cornerRadius = PopoverPanelController.cornerRadius
        glass.autoresizingMask = [.width, .height]
        glass.frame = NSRect(x: 0, y: 0, width: PopoverView.width, height: 240)
        // The SwiftUI content must fill the glass exactly; otherwise it keeps its own size and gets
        // centred, clipping the header and footer.
        host.translatesAutoresizingMaskIntoConstraints = true
        host.autoresizingMask = [.width, .height]
        host.frame = glass.bounds
        glass.contentView = host

        // A borderless window is a rectangle to the window server: its shadow and Tahoe's hairline
        // rim are computed from the window's alpha. The glass draws its backdrop over the full
        // rect, so without a real mask the shadow (and the dark outline) come out square. Clip the
        // whole content to the same continuous rounded rect so alpha — and the shadow — follow it.
        let container = RoundedContainerView(frame: NSRect(x: 0, y: 0, width: PopoverView.width, height: 240))
        glass.frame = container.bounds
        container.addSubview(glass)
        p.contentView = container
        return p
    }

    static let cornerRadius: CGFloat = 18

    func show(below button: NSStatusBarButton) {
        guard let bw = button.window else { return }
        let p = panel ?? makePanel()
        panel = p
        self.button = button
        anchor = bw.convertToScreen(button.convert(button.bounds, to: nil))
        contentHeight = measuredHeight() ?? contentHeight
        p.setFrame(frame(for: contentHeight, screen: bw.screen), display: true)
        p.makeKeyAndOrderFront(nil)
        // Recompute the shadow from the rounded content now that it has drawn, and re-measure once
        // SwiftUI has finished its first layout pass.
        p.invalidateShadow()
        DispatchQueue.main.async { [weak self] in
            guard let self, let p = self.panel, p.isVisible else { return }
            if let h = self.measuredHeight(), abs(h - p.frame.height) > 0.5 {
                self.contentHeight = h
                p.setFrame(self.frame(for: h, screen: p.screen), display: true)
            }
            p.invalidateShadow()
        }
        button.highlight(true)
        installMonitors()
    }

    func close() {
        guard let p = panel, p.isVisible else { return }
        p.orderOut(nil)
        removeMonitors()
        button?.highlight(false)
    }

    /// The SwiftUI content's natural height at the popover's fixed width.
    private func measuredHeight() -> CGFloat? {
        guard let host = hosting else { return nil }
        host.layoutSubtreeIfNeeded()
        let h = host.fittingSize.height
        return h > 0 ? h : nil
    }

    private func frame(for height: CGFloat, screen: NSScreen?) -> NSRect {
        let vis = (screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let maxH = min(600, vis.height - 40)
        let h = min(max(240, height), maxH)
        let w = PopoverView.width
        var x = anchor.midX - w / 2
        x = min(max(x, vis.minX + 8), vis.maxX - 8 - w)
        let top = anchor.minY - 4
        return NSRect(x: x, y: top - h, width: w, height: h)
    }

    private func heightChanged(_ h: CGFloat) {
        guard abs(h - contentHeight) > 0.5 else { return }
        contentHeight = h
        guard let p = panel, p.isVisible else { return }
        let target = frame(for: h, screen: p.screen)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            p.setFrame(target, display: true)
            p.invalidateShadow()
        } else {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                p.animator().setFrame(target, display: true)
            }, completionHandler: { p.invalidateShadow() })
        }
    }

    // MARK: Dismissal

    private func installMonitors() {
        removeMonitors()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self, let p = self.panel else { return event }
            if event.type == .keyDown {
                guard event.window === p else { return event }
                if event.keyCode == 53 { self.close(); return nil }      // Esc
                let cmd = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
                if cmd, let ch = event.charactersIgnoringModifiers {
                    switch ch {
                    case ".": self.services.model.pauseAll(); return nil
                    case "/": self.services.model.resumeAll(); return nil
                    case "v":
                        let inputs = self.services.clipboard.readInputs()
                        self.close()
                        if inputs.isEmpty { self.services.router.showAddLink() } else { self.services.model.requestAdd(inputs) }
                        return nil
                    default: break
                    }
                }
                return event
            }
            // Clicks in other windows of ours close the popover; clicks on the status item are
            // handled by its overlay (which toggles).
            if event.window !== p, !(event.window?.className.contains("StatusBar") ?? false) {
                self.close()
            }
            return event
        }
    }

    private func removeMonitors() {
        if let g = globalMonitor { NSEvent.removeMonitor(g) }
        if let l = localMonitor { NSEvent.removeMonitor(l) }
        globalMonitor = nil; localMonitor = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        // A menu opened from inside the popover (Add, gear) takes key briefly; only close when
        // focus went somewhere else entirely.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, let p = self.panel, p.isVisible, !p.isKeyWindow else { return }
            if NSApp.keyWindow == nil || NSApp.keyWindow === p { return }
            self.close()
        }
    }
}
