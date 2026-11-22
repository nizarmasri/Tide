import AppKit
import TideKit

// Developer flags. Without any, this is the normal app.
//   --render-preview <dir>   write a PNG of every screen in the review matrix (light and dark)
//   --render-icon <file> [--dark] [--small]   write the 1024px app icon (small = 16/32 px art)
//   --cli <command…>         drive the engine from a terminal (see CLI.swift)

let arguments = CommandLine.arguments

if let flag = arguments.firstIndex(of: "--render-preview") {
    let dir = arguments.indices.contains(flag + 1) ? arguments[flag + 1] : "preview"
    MainActor.assumeIsolated { PreviewRenderer.run(outputDir: dir) }
}

if let flag = arguments.firstIndex(of: "--render-icon") {
    let path = arguments.indices.contains(flag + 1) ? arguments[flag + 1] : "icon.png"
    let dark = arguments.contains("--dark")
    let small = arguments.contains("--small")
    MainActor.assumeIsolated { IconExport.write(to: path, dark: dark, small: small) }
}

if let flag = arguments.firstIndex(of: "--cli") {
    CLI.run(Array(arguments[(flag + 1)...]))
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
