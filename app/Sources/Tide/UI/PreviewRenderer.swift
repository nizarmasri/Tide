import AppKit
import SwiftUI
import TideKit

/// Renders the DESIGN.md §12 review matrix from canned data, light and dark (plus Graphite and
/// Increase Contrast for the key surfaces). Uses real AppKit windows offscreen and
/// `cacheDisplay`, because ImageRenderer can't draw AppKit-backed controls.
@MainActor
enum PreviewRenderer {
    private static var outDir = URL(fileURLWithPath: "preview")
    private static var written: [String] = []
    private static var activate = true

    enum Look: String {
        case light, dark, graphite, contrast
        var appearance: NSAppearance? {
            switch self {
            case .light, .graphite: return NSAppearance(named: .aqua)
            case .dark: return NSAppearance(named: .darkAqua)
            case .contrast: return NSAppearance(named: .accessibilityHighContrastAqua)
            }
        }
    }

    static func run(outputDir: String) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // Default buttons and switches only draw their active (accent) look in a key window of an
        // active app, so the renderer activates itself and hands focus back when it's done.
        let previous = NSWorkspace.shared.frontmostApplication
        activate = ProcessInfo.processInfo.environment["TIDE_PREVIEW_NO_ACTIVATE"] == nil
        if activate { app.activate() }
        outDir = URL(fileURLWithPath: (outputDir as NSString).expandingTildeInPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        if let old = try? FileManager.default.contentsOfDirectory(at: outDir, includingPropertiesForKeys: nil) {
            for f in old where f.pathExtension == "png" { try? FileManager.default.removeItem(at: f) }
        }

        VolumeProbe.overrides = [
            "/Volumes/Media": VolumeProbe(name: "Media", isExternal: true, isConnected: true, freeBytes: 412_000_000_000, isFAT32: false),
            "/Volumes/Tiny": VolumeProbe(name: "Tiny", isExternal: true, isConnected: true, freeBytes: 41_000_000_000, isFAT32: false),
            "/Volumes/Offline": VolumeProbe(name: "Media", isExternal: true, isConnected: false, freeBytes: nil, isFAT32: false),
            "/Volumes/OldStick": VolumeProbe(name: "OldStick", isExternal: true, isConnected: true, freeBytes: 120_000_000_000, isFAT32: true),
        ]

        let iconRenderer = ImageRenderer(content: AppIconView().frame(width: 256, height: 256))
        iconRenderer.scale = 2
        if let cg = iconRenderer.cgImage { app.applicationIconImage = NSImage(cgImage: cg, size: NSSize(width: 256, height: 256)) }

        glyphSheet()
        for look in [Look.light, .dark] { renderAll(look) }
        for look in [Look.graphite, .contrast] { renderKey(look) }

        if activate, let previous, previous != NSRunningApplication.current { previous.activate() }
        print(outDir.path)
        print("\(written.count) images")
        exit(0)
    }

    static func renderIcon(to path: String, dark: Bool) -> Never {
        let renderer = ImageRenderer(content: AppIconView(dark: dark).frame(width: 1024, height: 1024))
        renderer.scale = 1
        if let cg = renderer.cgImage,
           let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
        print(path)
        exit(0)
    }

    // MARK: Matrix

    private static func renderAll(_ look: Look) {
        let L = look.rawValue
        // Popover
        popover("01-popover-empty-\(L)", PreviewFixtures.empty, look)
        popover("02-popover-mixed-\(L)", PreviewFixtures.mixedToday, look)
        popover("03-popover-banner-clipboard-\(L)", PreviewFixtures.mixedToday, look, clipboard: true)
        popover("04-popover-banner-engine-\(L)", PreviewFixtures.engineStopped, look)
        popover("05-popover-banner-battery-\(L)", PreviewFixtures.onBattery, look)
        popover("06-popover-drop-\(L)", PreviewFixtures.mixedToday, look, dropOverlay: true)
        popover("07-popover-scrolling-\(L)", PreviewFixtures.manyRows, look)
        popover("08-popover-outside-hours-\(L)", PreviewFixtures.outsideHours, look)
        popover("09-popover-slow-mode-\(L)", PreviewFixtures.slowMode, look)

        // Main window
        main("10-window-empty-\(L)", PreviewFixtures.empty, look)
        main("11-window-standard-\(L)", PreviewFixtures.mixedToday, look)
        main("12-window-all-states-\(L)", PreviewFixtures.allStates, look, size: NSSize(width: 880, height: 980))
        main("13-window-compact-\(L)", PreviewFixtures.allStates, look, compact: true)
        main("14-window-inspector-info-\(L)", PreviewFixtures.mixedToday, look, select: [PreviewFixtures.movie.id], tab: .info)
        main("15-window-inspector-files-\(L)", PreviewFixtures.mixedToday, look, select: [PreviewFixtures.movie.id], tab: .files)
        main("16-window-inspector-peers-\(L)", PreviewFixtures.mixedToday, look, select: [PreviewFixtures.movie.id], tab: .peers)
        main("17-window-multiselect-\(L)", PreviewFixtures.mixedToday, look,
             select: [PreviewFixtures.movie.id, PreviewFixtures.show.id], tab: .info)
        main("18-window-inspector-error-\(L)", PreviewFixtures.mixedToday, look, select: [PreviewFixtures.failed.id], tab: .info)

        // Add window
        let media = PreviewFixtures.movies
        add("20-add-torrent-\(L)", [PreviewFixtures.torrentPreview], media, look)
        add("21-add-files-expanded-\(L)", [PreviewFixtures.torrentPreview], media, look, showAll: true)
        add("22-add-magnet-fetching-\(L)", [PreviewFixtures.magnetPreview], media, look)
        add("23-add-url-\(L)", [PreviewFixtures.urlPreview], URL(fileURLWithPath: NSHomeDirectory() + "/Downloads"), look)
        add("24-add-multiple-\(L)", PreviewFixtures.multiPreviews, media, look)
        add("25-add-low-space-\(L)", [PreviewFixtures.torrentPreview], URL(fileURLWithPath: "/Volumes/Tiny/Movies"), look)
        add("26-add-not-connected-\(L)", [PreviewFixtures.torrentPreview], URL(fileURLWithPath: "/Volumes/Offline/Movies"), look)
        add("27-add-unreadable-\(L)", [PreviewFixtures.unreadablePreview], media, look)
        add("28-add-duplicate-\(L)", [PreviewFixtures.duplicatePreview], media, look)
        add("29-add-existing-data-\(L)", [PreviewFixtures.existingPreview], media, look)
        add("30-add-scheduled-\(L)", [PreviewFixtures.torrentPreview], media, look, startAt: true)
        add("31-add-fat32-\(L)", [PreviewFixtures.torrentPreview], URL(fileURLWithPath: "/Volumes/OldStick/Movies"), look)
        add("32-add-link-empty-\(L)", [], media, look)

        // Import / Welcome
        importScreen("40-import-review-\(L)", [PreviewFixtures.movieImportRecent], look)
        importScreen("41-import-missing-progress-\(L)", [PreviewFixtures.importMissingProgress], look)
        importScreen("42-import-several-\(L)", PreviewFixtures.importSeveral, look)
        importScreen("43-import-nothing-\(L)", [], look)
        welcome("44-welcome-found-\(L)", [PreviewFixtures.movieImportRecent], look)
        welcome("45-welcome-none-\(L)", [], look)

        // Settings
        for (i, pane) in SettingsPane.allCases.enumerated() {
            settings("\(50 + i)-settings-\(pane.rawValue.lowercased())-\(L)", pane, look)
        }

        // Search
        let results = PreviewFixtures.searchResults
        let tears = results[0], ubuntu = results[1]
        searchWindow("70-search-empty-\(L)", .preview(query: "", results: [], phase: .idle), look)
        searchWindow("71-search-results-\(L)", .preview(query: "open movie", results: results), look, text: "open movie")
        searchWindow("72-search-inspector-full-\(L)", .preview(query: "open movie", results: results), look,
                     text: "open movie", select: tears.id, files: .full(PreviewFixtures.torrentPreview))
        searchWindow("73-search-inspector-listed-\(L)", .preview(query: "ubuntu", results: results), look,
                     text: "ubuntu", select: ubuntu.id,
                     files: .listed([TaskFile(index: 1, path: "ubuntu-26.04-desktop-amd64.iso", length: 0, selected: true, tag: .other)]))
        searchWindow("74-search-partial-failure-\(L)",
                     .preview(query: "open movie", results: results, failures: [.bitsearch: .rateLimited, .torrentscsv: .unavailable]),
                     look, text: "open movie", select: results[2].id, files: .unavailable)
        searchWindow("75-search-category-\(L)", .preview(query: "open movie", results: results), look,
                     text: "open movie", category: .movies)
        searchWindow("76-search-no-results-\(L)", .preview(query: "zzqqxx", results: []), look, text: "zzqqxx")
        searchWindow("77-search-unreachable-\(L)",
                     .preview(query: "ubuntu", results: [], failures: Dictionary(uniqueKeysWithValues:
                        SearchSourceID.allCases.map { ($0, SearchFailure.unavailable) })), look, text: "ubuntu")
        searchWindow("78-search-loading-files-\(L)", .preview(query: "ubuntu", results: results), look,
                     text: "ubuntu", select: ubuntu.id, files: .loading)

        // Dialogs
        alert("60-dialog-remove-\(L)", RemoveFlow.makeAlert(tasks: [PreviewFixtures.movie]), look)
        alert("61-dialog-remove-trash-completed-\(L)", RemoveFlow.makeTrashAlert(tasks: [PreviewFixtures.done]), look)
        alert("62-dialog-quit-\(L)", QuitFlow.makeAlert(activeCount: 2), look)
    }

    /// Graphite accent and Increase Contrast on the surfaces where they matter most.
    private static func renderKey(_ look: Look) {
        let L = look.rawValue
        popover("02-popover-mixed-\(L)", PreviewFixtures.mixedToday, look)
        main("12-window-all-states-\(L)", PreviewFixtures.allStates, look, size: NSSize(width: 880, height: 980))
        main("14-window-inspector-info-\(L)", PreviewFixtures.mixedToday, look, select: [PreviewFixtures.movie.id], tab: .info)
        add("20-add-torrent-\(L)", [PreviewFixtures.torrentPreview], PreviewFixtures.movies, look)
        importScreen("40-import-review-\(L)", [PreviewFixtures.movieImportRecent], look)
        settings("52-settings-schedule-\(L)", .schedule, look)
    }

    // MARK: Services

    private static func services(_ snap: EngineSnapshot, clipboard: Bool = false) -> AppServices {
        var settings = TideSettings()
        settings.defaultDirectory = PreviewFixtures.movies
        settings.recentDirectories = [PreviewFixtures.movies, URL(fileURLWithPath: NSHomeDirectory() + "/Downloads"),
                                      URL(fileURLWithPath: "/Volumes/Offline/TV")]
        settings.downloadHoursEnabled = true
        settings.slowModeScheduled = true
        settings.welcomeDone = true
        let model = AppModel(backend: PreviewBackend(snap), settingsStore: .inMemory(settings), initial: snap)
        let eta = EtaEstimator()
        eta.ingest(snap)
        let cb = ClipboardStatus()
        cb.hasLink = clipboard
        return AppServices(model: model, eta: eta, windowState: MainWindowState(compactRows: false), clipboard: cb,
                           router: WindowRouter())
    }

    private static func styled<V: View>(_ v: V, _ look: Look) -> AnyView {
        let base = v
            .environment(\.controlActiveState, .key)
            .environment(\.inlineInspector, true)
        if look == .graphite { return AnyView(base.tint(Color(nsColor: .systemGray))) }
        return AnyView(base)
    }

    // MARK: Surfaces

    private static func popover(_ name: String, _ snap: EngineSnapshot, _ look: Look, clipboard: Bool = false,
                                dropOverlay: Bool = false) {
        let s = services(snap, clipboard: clipboard)
        let root = PopoverView()
            .overlay { if dropOverlay { DropOverlay(visible: true) } }
            .tideEnvironment(s)
        let host = NSHostingView(rootView: styled(root, look))
        host.frame.size = NSSize(width: PopoverView.width, height: 600)
        let fit = host.fittingSize
        let size = NSSize(width: PopoverView.width, height: min(600, max(240, fit.height)))

        // Underlay approximating the glass panel (glass itself is composited by the window server).
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.cornerRadius = 18
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        let under = NSVisualEffectView(frame: container.bounds)
        under.material = .popover
        under.state = .active
        under.blendingMode = .behindWindow
        container.addSubview(under)
        container.appearance = look.appearance
        let tint = NSView(frame: container.bounds)
        tint.wantsLayer = true
        var bgColor = NSColor.windowBackgroundColor.cgColor
        (look.appearance ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance {
            bgColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
        }
        tint.layer?.backgroundColor = bgColor
        container.addSubview(tint)
        host.frame = container.bounds
        container.addSubview(host)
        captureView(container, name: name, look: look, padding: 24)
    }

    private static func main(_ name: String, _ snap: EngineSnapshot, _ look: Look, size: NSSize = NSSize(width: 980, height: 600),
                             compact: Bool = false, select: Set<TaskID> = [], tab: MainWindowState.InspectorTab = .info) {
        let s = services(snap)
        s.windowState.compactRows = compact
        s.windowState.selection = select
        s.windowState.inspectorShown = !select.isEmpty
        s.windowState.inspectorTab = tab
        let host = NSHostingController(rootView: styled(MainWindowView().tideEnvironment(s), look))
        host.sceneBridgingOptions = [.toolbars, .title]
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.contentViewController = host
        w.setContentSize(size)
        w.title = "Tide"
        w.subtitle = WindowSubtitle.text(snap)
        w.toolbarStyle = .unified
        captureWindow(w, name: name, look: look)
    }

    private static func searchWindow(_ name: String, _ search: TorrentSearch, _ look: Look, text: String = "",
                                     select: String? = nil, files: TorrentDetails.Files? = nil,
                                     category: SearchCategory? = nil) {
        let s = services(PreviewFixtures.mixedToday)
        let details = TorrentDetails(transport: { _ in throw URLError(.notConnectedToInternet) }) { _ in
            PreviewFixtures.torrentPreview
        }
        if let select, let files { details.preload(files, for: select) }
        let session = SearchSession(search: search, details: details)
        session.text = text
        session.selection = select
        session.category = category
        s.windowState.showSearch(session)
        let host = NSHostingController(rootView: styled(MainWindowView().tideEnvironment(s), look))
        host.sceneBridgingOptions = [.toolbars, .title]
        let size = NSSize(width: 980, height: 600)
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.contentViewController = host
        w.setContentSize(size)
        w.title = "Tide"
        if search.phase == .done, !search.allFailed {
            var sub = search.summary
            if let category {
                sub = "\(search.results.filter { $0.category == category }.count) of \(sub)"
            }
            if let note = search.failureNote { sub += " · \(note)" }
            w.subtitle = sub
        }
        w.toolbarStyle = .unified
        captureWindow(w, name: name, look: look)
    }

    private static func add(_ name: String, _ previews: [AddPreview], _ dest: URL, _ look: Look,
                            showAll: Bool = false, startAt: Bool = false) {
        let s = services(PreviewFixtures.mixedToday)
        let items = previews.map { AddItem(input: $0.input, preview: $0) }
        let root = AddDownloadView(requestID: UUID(), initialItems: items, initialDestination: dest,
                                   initialStartAt: startAt, initialShowAll: showAll)
            .tideEnvironment(s)
        panelWindow(styled(root, look), name: name, look: look)
    }

    private static func importScreen(_ name: String, _ candidates: [ImportCandidate], _ look: Look) {
        let s = services(PreviewFixtures.mixedToday)
        let root = ImportView(initialURL: nil, initialCandidates: candidates).tideEnvironment(s)
        panelWindow(styled(root, look), name: name, look: look)
    }

    private static func welcome(_ name: String, _ found: [ImportCandidate], _ look: Look) {
        let s = services(PreviewFixtures.empty)
        let root = WelcomeView(initialFound: found).tideEnvironment(s)
        panelWindow(styled(root, look), name: name, look: look)
    }

    private static func settings(_ name: String, _ pane: SettingsPane, _ look: Look) {
        let s = services(PreviewFixtures.mixedToday)
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        for p in SettingsPane.allCases {
            let host = NSHostingController(rootView: styled(p.view.tideEnvironment(s), look))
            host.sizingOptions = [.preferredContentSize]
            host.title = p.rawValue
            let item = NSTabViewItem(viewController: host)
            item.label = p.rawValue
            item.image = NSImage(systemSymbolName: p.symbol, accessibilityDescription: p.rawValue)
            tabs.addTabViewItem(item)
        }
        let w = NSWindow(contentViewController: tabs)
        w.styleMask = [.titled, .closable]
        w.toolbarStyle = .preference
        tabs.selectedTabViewItemIndex = SettingsPane.allCases.firstIndex(of: pane) ?? 0
        w.title = pane.rawValue
        captureWindow(w, name: name, look: look, fitContent: true)
    }

    private static func alert(_ name: String, _ alert: NSAlert, _ look: Look) {
        alert.window.appearance = look.appearance
        alert.layout()
        captureWindow(alert.window, name: name, look: look, alreadyLaidOut: true)
    }

    private static func panelWindow(_ root: AnyView, name: String, look: Look) {
        let host = NSHostingController(rootView: root)
        host.sizingOptions = [.preferredContentSize]
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        captureWindow(w, name: name, look: look, fitContent: true)
    }

    // MARK: Capture

    /// TIDE_PREVIEW_ONLY=<substring> renders just the matching screens.
    private static func wanted(_ name: String) -> Bool {
        guard let only = ProcessInfo.processInfo.environment["TIDE_PREVIEW_ONLY"], !only.isEmpty else { return true }
        return name.contains(only)
    }

    private static func settle(_ seconds: Double = 0.35) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until { RunLoop.current.run(mode: .default, before: until) }
    }

    private static func captureWindow(_ w: NSWindow, name: String, look: Look, fitContent: Bool = false,
                                      alreadyLaidOut: Bool = false) {
        guard wanted(name) else { return }
        if ProcessInfo.processInfo.environment["TIDE_PREVIEW_TRACE"] != nil { FileHandle.standardError.write(Data("render \(name)\n".utf8)) }
        w.appearance = look.appearance
        w.isReleasedWhenClosed = false
        w.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        w.orderFrontRegardless()
        if activate { w.makeKeyAndOrderFront(nil); w.makeMain() }
        settle()
        if fitContent, let cv = w.contentViewController?.view {
            let fit = cv.fittingSize
            if fit.width > 10, fit.height > 10 { w.setContentSize(fit) }
            settle(0.15)
        }
        if ProcessInfo.processInfo.environment["TIDE_PREVIEW_TRACE"] != nil {
            FileHandle.standardError.write(Data("  key=\(w.isKeyWindow) main=\(w.isMainWindow) active=\(NSApp.isActive)\n".utf8))
        }
        guard let frameView = w.contentView?.superview else { w.orderOut(nil); return }
        frameView.layoutSubtreeIfNeeded()
        frameView.displayIfNeeded()
        write(frameView, name: name, look: look, padding: 24, background: true)
        w.orderOut(nil)
        w.close()
    }

    private static func captureView(_ v: NSView, name: String, look: Look, padding: CGFloat) {
        guard wanted(name) else { return }
        if ProcessInfo.processInfo.environment["TIDE_PREVIEW_TRACE"] != nil { FileHandle.standardError.write(Data("render \(name)\n".utf8)) }
        let w = NSWindow(contentRect: NSRect(origin: NSPoint(x: -30_000, y: -30_000), size: v.frame.size),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = look.appearance
        w.isOpaque = false
        w.backgroundColor = .clear
        w.contentView = v
        w.orderFrontRegardless()
        settle()
        v.layoutSubtreeIfNeeded()
        write(v, name: name, look: look, padding: padding, background: true)
        w.orderOut(nil)
    }

    /// Writes the view at the window's backing scale (2x on Retina) onto a neutral desktop-ish
    /// background so window edges and shadows-free corners are visible.
    private static func write(_ v: NSView, name: String, look: Look, padding: CGFloat, background: Bool) {
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / max(1, v.bounds.width)
        let pad = padding * scale
        let W = CGFloat(rep.pixelsWide) + 2 * pad, H = CGFloat(rep.pixelsHigh) + 2 * pad
        guard let ctx = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cg = rep.cgImage else { return }
        let dark = look == .dark
        ctx.setFillColor(dark ? CGColor(red: 0.16, green: 0.17, blue: 0.20, alpha: 1) : CGColor(red: 0.86, green: 0.88, blue: 0.91, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        ctx.draw(cg, in: CGRect(x: pad, y: pad, width: CGFloat(rep.pixelsWide), height: CGFloat(rep.pixelsHigh)))
        guard let out = ctx.makeImage(),
              let png = NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:]) else { return }
        let url = outDir.appendingPathComponent(name + ".png")
        try? png.write(to: url)
        written.append(name)
    }

    // MARK: Menu bar glyph sheet

    private static func glyphSheet() {
        for dark in [false, true] {
            let states: [(String, MenuBarGlyph)] = [
                ("downloading 34%", MenuBarGlyph(center: .arrow, progress: 0.34, attention: false, speedText: nil)),
                ("problem", MenuBarGlyph(center: .exclamation, progress: 0.41, attention: false, speedText: nil)),
                ("waiting", MenuBarGlyph(center: .dots, progress: 0.23, attention: false, speedText: nil)),
                ("scheduled", MenuBarGlyph(center: .clock, progress: 0.0, attention: false, speedText: nil)),
                ("paused", MenuBarGlyph(center: .pause, progress: 0.62, attention: false, speedText: nil)),
                ("just completed", MenuBarGlyph(center: .check, progress: nil, attention: false, speedText: nil)),
                ("idle", MenuBarGlyph(center: .idle, progress: nil, attention: false, speedText: nil)),
                ("downloading + problem", MenuBarGlyph(center: .arrow, progress: 0.34, attention: true, speedText: nil)),
                ("speed text", MenuBarGlyph(center: .arrow, progress: 0.34, attention: false, speedText: "24.6 MB/s")),
                ("speed text (narrow value)", MenuBarGlyph(center: .arrow, progress: 0.34, attention: false, speedText: "512 KB/s")),
            ]
            let rowH: CGFloat = 40, width: CGFloat = 520
            let size = NSSize(width: width, height: CGFloat(states.count) * rowH + 40)
            let fg = dark ? NSColor.white : NSColor.black
            let bg = dark ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.93, alpha: 1)
            for scale in [1, 2] {
                let px = NSSize(width: size.width * CGFloat(scale), height: size.height * CGFloat(scale))
                guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px.width), pixelsHigh: Int(px.height),
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
                rep.size = size
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                bg.setFill()
                NSRect(origin: .zero, size: size).fill()
                let titleAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: fg.withAlphaComponent(0.6)]
                ("Menu bar glyph · \(scale)x · \(dark ? "dark" : "light")" as NSString)
                    .draw(at: NSPoint(x: 16, y: size.height - 26), withAttributes: titleAttrs)
                for (i, (label, glyph)) in states.enumerated() {
                    let y = size.height - 40 - CGFloat(i + 1) * rowH + 11
                    var x: CGFloat = 24
                    if let text = glyph.speedText {
                        let para = NSMutableParagraphStyle(); para.alignment = .right
                        let attrs: [NSAttributedString.Key: Any] = [.font: GlyphRenderer.speedFont, .foregroundColor: fg, .paragraphStyle: para]
                        (text as NSString).draw(in: NSRect(x: x, y: y + 1, width: GlyphRenderer.speedTextWidth, height: 16), withAttributes: attrs)
                        x += GlyphRenderer.speedTextWidth + 4
                    } else {
                        x += GlyphRenderer.speedTextWidth + 4
                    }
                    tinted(GlyphRenderer.image(glyph), fg).draw(in: NSRect(x: x, y: y, width: 18, height: 18))
                    (label as NSString).draw(at: NSPoint(x: x + 40, y: y + 2), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: fg])
                }
                NSGraphicsContext.restoreGraphicsState()
                if let png = rep.representation(using: .png, properties: [:]) {
                    let name = "00-menubar-glyphs-\(dark ? "dark" : "light")@\(scale)x"
                    try? png.write(to: outDir.appendingPathComponent(name + ".png"))
                    written.append(name)
                }
            }
        }
    }

    private static func tinted(_ template: NSImage, _ color: NSColor) -> NSImage {
        let img = NSImage(size: template.size)
        img.lockFocus()
        template.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        color.set()
        NSRect(origin: .zero, size: template.size).fill(using: .sourceAtop)
        img.unlockFocus()
        return img
    }
}
