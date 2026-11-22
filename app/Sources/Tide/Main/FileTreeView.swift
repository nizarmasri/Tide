import AppKit
import SwiftUI
import TideKit

/// Outline of torrent files with tri-state folder checkboxes (Add window and Files inspector).
struct FileTreeView: View {
    var files: [TaskFile]
    @Binding var selected: Set<Int>
    var showProgress: Bool = false

    var body: some View {
        let tree = FileNode.tree(files)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(tree) { node in
                FileNodeRow(node: node, selected: $selected, showProgress: showProgress, depth: 0)
            }
        }
    }
}

private struct FileNodeRow: View {
    var node: FileNode
    @Binding var selected: Set<Int>
    var showProgress: Bool
    var depth: Int
    @State private var expanded = true

    var body: some View {
        if node.isFolder {
            DisclosureGroup(isExpanded: $expanded) {
                ForEach(node.children) { child in
                    FileNodeRow(node: child, selected: $selected, showProgress: showProgress, depth: depth + 1)
                }
            } label: {
                rowContent
            }
        } else {
            rowContent
        }
    }

    private var leafBindings: [Binding<Bool>] {
        node.leafIndexes.map { idx in
            Binding(get: { selected.contains(idx) },
                    set: { on in if on { selected.insert(idx) } else { selected.remove(idx) } })
        }
    }

    private var isSelected: Bool { node.check(selected: selected) != .off }

    /// Line 1: checkbox, 16pt icon, name (flexible, middle-truncated, tag when room), size in a
    /// fixed 64pt column. Line 2 (Files inspector, selected only): 40pt bar and percent.
    private var rowContent: some View {
        let tag = node.file?.tag
        let isJunk = tag?.junkLabel != nil
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Group {
                    if let f = node.file {
                        Toggle("", isOn: Binding(get: { selected.contains(f.index) },
                                                 set: { on in if on { selected.insert(f.index) } else { selected.remove(f.index) } }))
                    } else {
                        Toggle(sources: leafBindings, isOn: \.self) { EmptyView() }
                    }
                }
                .toggleStyle(.checkbox)
                .labelsHidden()
                FileIconView(image: FileIcons.icon(forName: node.name, isFolder: node.isFolder), size: 16)
                NameWithTag(name: node.name, tag: tag?.junkLabel, dim: isJunk)
                Text(TideFormat.bytes(node.totalBytes))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 64, alignment: .trailing)
            }
            if showProgress, isSelected, node.totalBytes > 0 {
                let f = Double(node.completedBytes) / Double(node.totalBytes)
                HStack(spacing: 6) {
                    ProgressCapsule(value: f, tint: .accent, height: 4).frame(width: 40)
                    Text(TideFormat.percent(f))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 44)   // under the name: checkbox + gap + icon + gap
            }
        }
        .monospacedDigit()
        .frame(minHeight: 24)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(node.name)
        .accessibilityValue("\(isSelected ? "Selected" : "Not selected"), \(TideFormat.spokenBytes(node.totalBytes))")
    }
}

/// File name with its junk tag; the tag hides when the name would get less than 120pt.
private struct NameWithTag: View {
    var name: String
    var tag: String?
    var dim: Bool
    @State private var width: CGFloat = 0
    private static let tagAllowance: CGFloat = 56

    var body: some View {
        HStack(spacing: 6) {
            Text(name)
                .font(.system(size: 13))
                .foregroundStyle(dim ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .lineLimit(1)
                .truncationMode(.middle)
            if let tag, width - Self.tagAllowance >= 120 {
                Text(tag)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.quaternary))
                    .fixedSize()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}
