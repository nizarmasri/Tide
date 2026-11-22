import Foundation
import TideKit
#if TIDE_ENGINE
import TideEngine
#endif

/// Headless commands for testing the real engine from a terminal. Read-only: they never start a
/// second aria2 next to the running app.
///
///   Tide --cli version
///   Tide --cli scan <folder>                        unfinished downloads found there (no hashing)
///   Tide --cli verify-sample <torrent> <folder> [n] hash n finished pieces, report speed
enum CLI {
    static func run(_ args: [String]) -> Never {
        #if TIDE_ENGINE
        switch args.first {
        case "version":
            print("Tide core \(FFIBackend.coreVersionString), aria2 at \(FFIBackend.aria2Path())")
        case "scan" where args.count >= 2:
            let sem = DispatchSemaphore(value: 0)
            let backend = FFIBackend()
            let url = URL(fileURLWithPath: args[1])
            let start = Date()
            Task.detached {
                let found = await backend.scanForImports(at: url)
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                if found.isEmpty { print("No unfinished downloads in \(url.path) (\(ms) ms)") }
                for c in found {
                    let pct = String(format: "%.1f", c.fraction * 100)
                    let sel = c.files.filter(\.selected).map(\.name).joined(separator: ", ")
                    print("\(c.name)\n  \(pct)% of \(c.totalBytes) bytes · progress file: \(c.progressFile?.lastPathComponent ?? "missing") · torrent: \(c.torrentFile?.lastPathComponent ?? "missing")\n  selected: \(sel)\n  skipped: \(c.smart?.skippedDescription ?? "-")\n  scanned in \(ms) ms")
                }
                sem.signal()
            }
            sem.wait()
        case "verify-sample" where args.count >= 3:
            let n = args.count >= 4 ? Int(args[3]) ?? 200 : 200
            print(FFIBackend.verifySample(torrent: args[1], directory: args[2], sample: n))
        default:
            print("usage: Tide --cli version | scan <folder> | verify-sample <torrent> <folder> [n]")
            exit(2)
        }
        exit(0)
        #else
        print("This build has no engine (run scripts/build-core.sh).")
        exit(2)
        #endif
    }
}
