import AppKit
import SwiftUI
import TideKit
import UniformTypeIdentifiers

// MARK: - Semantic styles

extension StateTint {
    /// `.accent` maps to the tint so it follows the system accent (and Graphite).
    var style: AnyShapeStyle {
        switch self {
        case .accent: return AnyShapeStyle(.tint)
        case .secondary: return AnyShapeStyle(.secondary)
        case .gray: return AnyShapeStyle(Color.primary.opacity(0.22))
        case .orange: return AnyShapeStyle(Color.orange)
        case .red: return AnyShapeStyle(Color.red)
        case .green: return AnyShapeStyle(Color.green)
        case .teal: return AnyShapeStyle(Color.teal)
        case .indigo: return AnyShapeStyle(Color.indigo)
        }
    }

    /// Solid colour for fills that need opacity (banners).
    var color: Color {
        switch self {
        case .accent: return .accentColor
        case .secondary, .gray: return Color(nsColor: .systemGray)
        case .orange: return .orange
        case .red: return .red
        case .green: return .green
        case .teal: return .teal
        case .indigo: return .indigo
        }
    }
}

// MARK: - Progress capsule

/// The one progress bar style: a capsule track with a forward-only fill (DESIGN.md §9 motion).
struct ProgressCapsule: View {
    var value: Double
    var tint: StateTint
    var height: CGFloat = 4

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var shown: Double? = nil

    var body: some View {
        let v = max(0, min(1, shown ?? value))
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(contrast == .increased ? AnyShapeStyle(Color(nsColor: .separatorColor)) : AnyShapeStyle(.quaternary))
                Capsule()
                    .fill(tint.style)
                    .frame(width: v > 0 ? max(height, geo.size.width * v) : 0)
            }
            .overlay {
                if contrast == .increased {
                    Capsule().strokeBorder(Color.primary.opacity(0.6), lineWidth: 0.5)
                }
            }
        }
        .frame(height: height)
        .onAppear { shown = value }
        .onChange(of: value) { old, new in
            if new > old, !reduceMotion {
                withAnimation(.linear(duration: 1.0)) { shown = new }
            } else {
                shown = new  // never animate backwards
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Status text with ↓/↑ as SF Symbols

/// Text that interpolates arrow symbols properly (AttributedString can't hold Images, so build
/// a Text by concatenation).
func statusText(_ s: String) -> Text {
    var result = Text(verbatim: "")
    var buf = ""
    for ch in s {
        if ch == "↑" || ch == "↓" {
            if !buf.isEmpty { result = Text("\(result)\(Text(verbatim: buf))"); buf = "" }
            result = Text("\(result)\(Image(systemName: ch == "↑" ? "arrow.up" : "arrow.down"))")
        } else {
            buf.append(ch)
        }
    }
    if !buf.isEmpty { result = Text("\(result)\(Text(verbatim: buf))") }
    return result
}

// MARK: - File icons

@MainActor
enum FileIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(forName name: String, isFolder: Bool = false) -> NSImage {
        let ext = isFolder ? "/folder" : (name as NSString).pathExtension.lowercased()
        if let i = cache[ext] { return i }
        let type: UTType
        if isFolder { type = .folder }
        else { type = UTType(filenameExtension: ext) ?? .data }
        let img = NSWorkspace.shared.icon(for: type)
        cache[ext] = img
        return img
    }

    static func icon(for task: DownloadTask) -> NSImage {
        if let f = task.primaryFile { return icon(forName: f.lastPathComponent) }
        let ext = (task.name as NSString).pathExtension
        if let t = UTType(filenameExtension: ext), t.conforms(to: .content) || t.conforms(to: .archive) || t.conforms(to: .diskImage) {
            return icon(forName: task.name)
        }
        // A torrent named like a release ("Show.S02.2160p…") is a folder of files.
        return task.kind == .http ? icon(forName: task.name) : icon(forName: task.name, isFolder: true)
    }
}

struct FileIconView: View {
    var image: NSImage
    var size: CGFloat
    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

// MARK: - State symbol

struct StateSymbol: View {
    var presentation: TaskPresentation
    var size: CGFloat = 14
    var body: some View {
        Image(systemName: presentation.symbol)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(presentation.symbolTint.style)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: size + 2)
            .accessibilityHidden(true)
    }
}

// MARK: - Borderless circular icon button (popover)

struct CircleIconButtonStyle: ButtonStyle {
    var size: CGFloat = 28
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .medium))
            .frame(width: size, height: size)
            .background(
                Circle().fill(Color.primary.opacity(configuration.isPressed ? 0.14 : (hovering ? 0.08 : 0)))
            )
            .contentShape(Circle())
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
    }
}

/// Small row action button (24pt).
struct RowActionButton: View {
    var action: RowAction
    var perform: () -> Void
    var body: some View {
        if action == .none {
            Color.clear.frame(width: 24, height: 24)
        } else {
            Button(action: perform) {
                Image(systemName: action.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(CircleIconButtonStyle(size: 24))
            .help(action.label)
            .accessibilityLabel(action.label)
        }
    }
}

// MARK: - Piece bar

/// 10pt piece map, downsampled to pixel width (DESIGN.md §5 Inspector).
struct PieceBar: View {
    var map: PieceMap
    var height: CGFloat = 10
    @Environment(\.displayScale) private var scale

    var body: some View {
        Canvas { ctx, size in
            let track = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 3)
            ctx.fill(track, with: .style(.quaternary))
            let n = max(1, Int(size.width * scale))
            let buckets = map.buckets(min(n, max(1, map.count)))
            guard !buckets.isEmpty else { return }
            ctx.clip(to: track)
            let w = size.width / CGFloat(buckets.count)
            for (i, f) in buckets.enumerated() where f > 0 {
                let rect = CGRect(x: CGFloat(i) * w, y: 0, width: w + 0.5, height: size.height)
                ctx.fill(Path(rect), with: .style(.tint.opacity(f)))
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Pieces")
        .accessibilityValue("\(TideFormat.count(map.doneCount)) of \(TideFormat.count(map.count)) downloaded")
    }
}

// MARK: - Drop overlay

struct DropOverlay: View {
    var visible: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        ZStack {
            if visible {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(reduceTransparency ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor)) : AnyShapeStyle(.tint.opacity(0.06)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(.tint, lineWidth: 2)
                    )
                    .overlay {
                        VStack(spacing: 8) {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 32, weight: .regular))
                                .foregroundStyle(.tint)
                            Text("Drop to Add")
                                .font(.system(size: 13, weight: .medium))
                        }
                    }
                    .padding(8)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: visible)
        .allowsHitTesting(false)
    }
}

/// Accepts torrents, magnets and URLs dropped on a view and hands them to the model.
struct AddDropModifier: ViewModifier {
    var model: AppModel
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .overlay(DropOverlay(visible: targeted))
            .onDrop(of: [.fileURL, .url, .plainText], isTargeted: $targeted) { providers in
                DropReader.read(providers) { inputs in
                    if !inputs.isEmpty { model.requestAdd(inputs) }
                }
                return true
            }
    }
}

extension View {
    func acceptsDownloadDrops(_ model: AppModel) -> some View { modifier(AddDropModifier(model: model)) }
}

enum DropReader {
    static func read(_ providers: [NSItemProvider], completion: @escaping @MainActor ([AddInput]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        var strings: [String] = []
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                group.enter()
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { lock.lock(); urls.append(url); lock.unlock() }
                    group.leave()
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                group.enter()
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { lock.lock(); urls.append(url); lock.unlock() }
                    group.leave()
                }
            } else if p.canLoadObject(ofClass: String.self) {
                group.enter()
                _ = p.loadObject(ofClass: String.self) { s, _ in
                    if let s { lock.lock(); strings.append(s); lock.unlock() }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            let inputs = InputParser.inputs(urls: urls, strings: strings)
            MainActor.assumeIsolated { completion(inputs) }
        }
    }

    /// Reads a pasteboard (drag onto the status item, ⌘V).
    static func inputs(from pb: NSPasteboard) -> [AddInput] {
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? []
        let strings = (pb.readObjects(forClasses: [NSString.self], options: nil) as? [String]) ?? []
        return InputParser.inputs(urls: urls, strings: strings)
    }
}

// MARK: - Section header

struct SectionHeader: View {
    var title: String
    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Finder helpers

@MainActor
enum Finder {
    static func reveal(_ task: DownloadTask) {
        if let f = task.primaryFile, FileManager.default.fileExists(atPath: f.path) {
            NSWorkspace.shared.activateFileViewerSelecting([f])
        } else {
            NSWorkspace.shared.open(task.directory)
        }
    }

    static func open(_ task: DownloadTask) {
        if let f = task.primaryFile { NSWorkspace.shared.open(f) } else { NSWorkspace.shared.open(task.directory) }
    }

    static func copyLink(_ task: DownloadTask) {
        guard let link = task.magnetLink ?? task.sourceURL else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(link, forType: .string)
    }
}

/// Human folder line: "Movies — Media".
func folderLine(_ dir: URL, volumeName: String) -> String {
    "\(dir.lastPathComponent) — \(volumeName)"
}
