import AppKit
import Foundation
import IOKit.ps
import IOKit.pwr_mgt
import Network
import ServiceManagement
import UserNotifications

/// Everything Tide observes about the Mac, fed to the engine; plus the few things it does to the
/// Mac (keep awake, login item, notifications). Started once from the app delegate.
@MainActor
public final class SystemWatchers: NSObject {
    private let model: AppModel
    private var env = SystemEnvironment()
    private let pathMonitor = NWPathMonitor()
    private var powerSource: CFRunLoopSource?
    private var sleepAssertion: IOPMAssertionID = 0
    private var assertionReason: String?
    private var timer: Timer?
    private var watchFolder: WatchFolder?
    private var lastSettings: TideSettings?

    public init(model: AppModel) {
        self.model = model
        super.init()
    }

    public func start() {
        observeVolumes()
        observePower()
        observeNetwork()
        Notifier.shared.requestAuthorization()
        model.onEvent = { [weak self] event in self?.handle(event) }
        applySettings()
        // Cheap periodic work: keep-awake decision, timezone/DST changes, settings side effects.
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.periodic() }
        }
        periodic()
    }

    private func push() {
        model.updateEnvironment(env)
    }

    // MARK: Volumes

    private func observeVolumes() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.willUnmountNotification, object: nil, queue: .main) { [weak self] note in
            guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            // Synchronous: aria2 must close the files before the eject goes ahead.
            MainActor.assumeIsolated {
                (self?.model.backend as? VolumeEjectHandling)?.volumeWillUnmount(url.path)
            }
        }
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshVolumes() }
            }
        }
        refreshVolumes()
    }

    private func refreshVolumes() {
        let keys: [URLResourceKey] = [.volumeUUIDStringKey]
        var map: [String: String] = [:]
        for url in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? [] {
            map[url.path] = (try? url.resourceValues(forKeys: Set(keys)).volumeUUIDString) ?? ""
        }
        env.mountedVolumes = map
        push()
    }

    // MARK: Power

    private func observePower() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let me = Unmanaged<SystemWatchers>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { me.refreshPower() }
        }, ctx)?.takeRetainedValue() {
            powerSource = src
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        }
        refreshPower()
    }

    private func refreshPower() {
        let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue()
        let type = info.flatMap { IOPSGetProvidingPowerSourceType($0)?.takeUnretainedValue() as String? }
        let onBattery = type == kIOPSBatteryPowerValue
        if env.onBattery != onBattery {
            env.onBattery = onBattery
            push()
        }
    }

    // MARK: Network

    private func observeNetwork() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            let expensive = path.isExpensive || path.isConstrained
            DispatchQueue.main.async {
                guard let self else { return }
                if self.env.networkAvailable != available || self.env.networkExpensive != expensive {
                    self.env.networkAvailable = available
                    self.env.networkExpensive = expensive
                    self.push()
                }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "tide.network"))
    }

    // MARK: Periodic: keep awake, settings side effects

    private func periodic() {
        if model.settings != lastSettings { applySettings() }
        updateSleepAssertion()
    }

    private func applySettings() {
        let s = model.settings
        defer { lastSettings = s }
        if lastSettings?.openAtLogin != s.openAtLogin { LoginItem.set(s.openAtLogin) }
        if lastSettings?.watchFolderEnabled != s.watchFolderEnabled || lastSettings?.watchFolder != s.watchFolder {
            watchFolder = nil
            if s.watchFolderEnabled, let dir = s.watchFolder {
                watchFolder = WatchFolder(dir: dir) { [weak self] urls in
                    MainActor.assumeIsolated { self?.addFromWatchFolder(urls) }
                }
            }
        }
    }

    private func updateSleepAssertion() {
        let s = model.settings
        let tasks = model.snapshot.tasks
        let downloading = s.preventSleep && tasks.contains { $0.phase.isActive }
        let waitingForWindow = s.keepAwakeForSchedule && tasks.contains {
            if case .scheduled = $0.phase { return true } else { return false }
        }
        let reason: String? = downloading ? "Tide is downloading" : (waitingForWindow ? "Tide is waiting to start scheduled downloads" : nil)
        guard reason != assertionReason else { return }
        if sleepAssertion != 0 {
            IOPMAssertionRelease(sleepAssertion)
            sleepAssertion = 0
        }
        assertionReason = reason
        if let reason {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &sleepAssertion)
        }
    }

    // MARK: Events → notifications

    private func handle(_ event: EngineEvent) {
        let s = model.settings
        switch event {
        case let .completed(_, name, dir, volume):
            guard s.notifyCompleted else { return }
            Notifier.shared.post(title: "Download Complete",
                                 body: "\(name) is ready in \(dir.lastPathComponent) on \(volume).",
                                 reveal: dir, sound: s.soundOnCompletion)
        case let .stopped(_, name, reason):
            guard s.notifyProblems else { return }
            Notifier.shared.post(title: "Download Stopped", body: "\(name): \(reason)", reveal: nil, sound: false)
        case let .waitingForDrive(volume):
            guard s.notifyWaitingForDrive, model.snapshot.inProgress.contains(where: { $0.volumeName == volume }) else { return }
            Notifier.shared.post(title: "Waiting for \(volume)",
                                 body: "Downloads will continue when you plug \(volume) back in.", reveal: nil, sound: false)
        case let .engineStopped(reason):
            guard s.notifyProblems else { return }
            Notifier.shared.post(title: "Download Engine Stopped", body: reason, reveal: nil, sound: false)
        case let .addedFromWatchFolder(name):
            Notifier.shared.post(title: "Added from Watch Folder", body: "\(name) — only the movie selected", reveal: nil, sound: false)
        }
    }

    // MARK: Watch folder

    private func addFromWatchFolder(_ urls: [URL]) {
        let dest = model.settings.defaultDirectory
        let trash = model.settings.trashAddedTorrents
        for url in urls {
            Task { @MainActor in
                let preview = await model.inspect(.torrentFile(url), destination: dest)
                guard preview.problem == nil, preview.duplicateOf == nil else { return }
                do {
                    try await model.add(preview, options: AddOptions(directory: dest))
                    handle(.addedFromWatchFolder(name: preview.name))
                    if trash { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }
                } catch {}
            }
        }
    }
}

/// Open at Login via SMAppService (macOS 13+).
public enum LoginItem {
    public static func set(_ on: Bool) {
        let svc = SMAppService.mainApp
        do {
            if on, svc.status != .enabled { try svc.register() }
            if !on, svc.status == .enabled { try svc.unregister() }
        } catch {
            NSLog("Tide: login item change failed: \(error.localizedDescription)")
        }
    }
    public static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
}

/// Makes Tide the default app for magnet links and .torrent files.
public enum DefaultHandler {
    public static func makeDefault() {
        let app = Bundle.main.bundleURL
        NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "magnet") { _ in }
        if let type = UTType(filenameExtension: "torrent") {
            NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type) { _ in }
        }
    }

    public static var isDefault: Bool {
        guard let url = URL(string: "magnet:?xt=urn:btih:0000000000000000000000000000000000000000"),
              let handler = NSWorkspace.shared.urlForApplication(toOpen: url) else { return false }
        return handler.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }
}

import UniformTypeIdentifiers

/// Local notifications with a "Show in Finder" action.
public final class Notifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    public static let shared = Notifier()
    private let center = UNUserNotificationCenter.current()

    public func requestAuthorization() {
        center.delegate = self
        let reveal = UNNotificationAction(identifier: "reveal", title: "Show in Finder")
        center.setNotificationCategories([UNNotificationCategory(identifier: "completed", actions: [reveal], intentIdentifiers: [])])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    public func post(title: String, body: String, reveal: URL?, sound: Bool) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        if sound { c.sound = .default }
        if let reveal {
            c.categoryIdentifier = "completed"
            c.userInfo = ["reveal": reveal.path]
        }
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                       withCompletionHandler done: @escaping () -> Void) {
        if let path = response.notification.request.content.userInfo["reveal"] as? String {
            DispatchQueue.main.async {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
            }
        }
        done()
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                       withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }
}

/// Watches a folder for new .torrent files (DispatchSource on the directory).
final class WatchFolder {
    private let source: DispatchSourceFileSystemObject?
    private var seen: Set<String> = []
    private let dir: URL

    init(dir: URL, onNew: @escaping @Sendable ([URL]) -> Void) {
        self.dir = dir
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { source = nil; return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source = src
        seen = Set(Self.torrents(in: dir).map(\.path))
        src.setEventHandler { [weak self] in
            guard let self else { return }
            // Let the writer finish before reading.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let now = Self.torrents(in: self.dir)
                let fresh = now.filter { !self.seen.contains($0.path) }
                self.seen = Set(now.map(\.path))
                if !fresh.isEmpty { onNew(fresh) }
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
    }

    deinit { source?.cancel() }

    static func torrents(in dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "torrent" && !$0.lastPathComponent.hasPrefix(".") }
    }
}
