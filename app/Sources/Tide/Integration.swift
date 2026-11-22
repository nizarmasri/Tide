import AppKit
import TideKit
#if TIDE_ENGINE
import TideEngine
#endif

/// Engine wiring and system watchers. Owned by the engine side; the UI layer calls these hooks
/// from the app delegate and never constructs a backend itself.
enum Integration {
    /// The real Rust-backed engine when it's linked, otherwise canned preview data.
    @MainActor static func makeBackend() -> EngineBackend {
        #if TIDE_ENGINE
        return FFIBackend()
        #else
        return PreviewBackend(PreviewFixtures.mixed)
        #endif
    }

    @MainActor private static var watchers: SystemWatchers?

    /// Called once from applicationDidFinishLaunching, after the model has started.
    @MainActor static func didLaunch(model: AppModel) {
        guard watchers == nil else { return }
        let w = SystemWatchers(model: model)
        w.start()
        watchers = w
    }

    /// Called from applicationShouldTerminate / willTerminate; must return quickly.
    @MainActor static func willTerminate(model: AppModel) {
        model.shutdown()
    }
}
