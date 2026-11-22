import Foundation
import TideKit

/// Destination facts for the Save To picker and its warnings (free space, FAT32, connected).
struct VolumeProbe: Equatable {
    var name: String
    var isExternal: Bool
    var isConnected: Bool
    var freeBytes: Int64?
    var isFAT32: Bool

    var status: VolumeStatus {
        VolumeStatus(name: name, isExternal: isExternal, isConnected: isConnected, freeBytes: freeBytes)
    }

    /// Preview/test overrides keyed by path prefix.
    nonisolated(unsafe) static var overrides: [String: VolumeProbe] = [:]

    static func probe(_ dir: URL) -> VolumeProbe {
        let path = dir.standardizedFileURL.path
        if let o = overrides.first(where: { path.hasPrefix($0.key) })?.value { return o }

        // /Volumes/<Name>/… whose mount point is missing → not connected.
        let comps = path.split(separator: "/").map(String.init)
        if comps.count >= 2, comps[0] == "Volumes" {
            let mount = "/Volumes/\(comps[1])"
            var isDir: ObjCBool = false
            if !FileManager.default.fileExists(atPath: mount, isDirectory: &isDir) {
                return VolumeProbe(name: comps[1], isExternal: true, isConnected: false, freeBytes: nil, isFAT32: false)
            }
        }

        // Walk up to an existing ancestor so a not-yet-created folder still resolves its volume.
        var probeURL = dir
        while !FileManager.default.fileExists(atPath: probeURL.path), probeURL.path != "/" {
            probeURL.deleteLastPathComponent()
        }
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeLocalizedNameKey, .volumeIsInternalKey,
                                         .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        let v = try? probeURL.resourceValues(forKeys: keys)
        let name = v?.volumeLocalizedName ?? v?.volumeName ?? "Mac"
        let isInternal = v?.volumeIsInternal ?? true
        var free: Int64? = v?.volumeAvailableCapacityForImportantUsage
        if free == nil || free == 0, let c = v?.volumeAvailableCapacity { free = Int64(c) }

        var fs = statfs()
        var fat = false
        if statfs(probeURL.path, &fs) == 0 {
            let type = withUnsafePointer(to: &fs.f_fstypename) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
            }
            fat = type == "msdos"
        }
        return VolumeProbe(name: name, isExternal: !isInternal, isConnected: true, freeBytes: free, isFAT32: fat)
    }

    var symbol: String { isExternal ? "externaldrive" : "internaldrive" }
}

/// Add-window warnings (DESIGN.md §6 "Warnings").
enum DestinationWarning: Equatable {
    case notEnoughSpace(needs: Int64, volume: String, free: Int64)
    case fat32(volume: String)
    case notConnected(volume: String)

    static let fat32Limit: Int64 = 4_294_967_295

    static func evaluate(probe: VolumeProbe, needed: Int64, largestFile: Int64) -> DestinationWarning? {
        if !probe.isConnected { return .notConnected(volume: probe.name) }
        if probe.isFAT32, largestFile > fat32Limit { return .fat32(volume: probe.name) }
        if let free = probe.freeBytes, needed > free {
            return .notEnoughSpace(needs: needed, volume: probe.name, free: free)
        }
        return nil
    }

    var message: String {
        switch self {
        case .notEnoughSpace(let needs, let volume, let free):
            return "Needs \(TideFormat.bytes(needs)) — \(volume) has \(TideFormat.bytes(free)) free."
        case .fat32(let volume):
            return "\(volume) is formatted as FAT32, which can’t store files over 4 GB."
        case .notConnected(let volume):
            return "\(volume) isn’t connected. The download will start when you plug it in."
        }
    }

    var symbol: String {
        switch self {
        case .notEnoughSpace, .fat32: return "exclamationmark.triangle.fill"
        case .notConnected: return "externaldrive"
        }
    }

    var tint: StateTint {
        switch self {
        case .notEnoughSpace, .fat32: return .red
        case .notConnected: return .orange
        }
    }

    var blocksAdding: Bool {
        switch self {
        case .notEnoughSpace, .fat32: return true
        case .notConnected: return false
        }
    }
}
