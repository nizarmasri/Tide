import AppKit
import SwiftUI
import TideKit

enum SettingsPane: String, CaseIterable, Identifiable {
    case general = "General", downloads = "Downloads", schedule = "Schedule"
    case network = "Network", bittorrent = "BitTorrent", engine = "Engine"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .downloads: return "arrow.down.circle"
        case .schedule: return "clock"
        case .network: return "network"
        case .bittorrent: return "point.3.connected.trianglepath.dotted"
        case .engine: return "gearshape.2"
        }
    }

    @MainActor @ViewBuilder var view: some View {
        switch self {
        case .general: GeneralPane()
        case .downloads: DownloadsPane()
        case .schedule: SchedulePane()
        case .network: NetworkPane()
        case .bittorrent: BitTorrentPane()
        case .engine: EnginePane()
        }
    }
}

/// Fixed 540 wide, height fits the content (DESIGN.md §2 Settings).
struct SettingsPaneFrame<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(width: 540)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - General

struct GeneralPane: View {
    @Environment(AppModel.self) private var model
    @State private var isDefault = AppHooks.isDefaultApp()

    var body: some View {
        @Bindable var model = model
        SettingsPaneFrame {
            Section {
                Toggle("Open at login", isOn: $model.settings.openAtLogin)
                Toggle("Show speed in menu bar", isOn: $model.settings.showSpeedInMenuBar)
                LabeledContent("Default app for torrents and magnet links") {
                    if isDefault {
                        Text("Tide").foregroundStyle(.secondary)
                    } else {
                        Button("Make Default") { AppHooks.makeDefaultApp(); isDefault = true }
                    }
                }
            }
            Section {
                Toggle("Prevent sleep while downloading", isOn: $model.settings.preventSleep)
                Toggle("Ask before quitting with active downloads", isOn: $model.settings.askBeforeQuit)
            }
            Section("Notifications") {
                Toggle("Completed", isOn: $model.settings.notifyCompleted)
                Toggle("Problems", isOn: $model.settings.notifyProblems)
                Toggle("Waiting for drive", isOn: $model.settings.notifyWaitingForDrive)
                Toggle("Sound on completion", isOn: $model.settings.soundOnCompletion)
            }
        }
    }
}

// MARK: - Downloads

struct DownloadsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        SettingsPaneFrame {
            Section {
                LabeledContent("Default folder") {
                    SaveToMenu(destination: $model.settings.defaultDirectory)
                }
            }
            Section("File Selection") {
                Toggle("Only the main video", isOn: $model.settings.onlyMainVideo)
                Toggle("Skip extras: samples, images, text files", isOn: $model.settings.skipExtras)
            }
            Section("Watch Folder") {
                Toggle("Add torrents saved to a folder", isOn: $model.settings.watchFolderEnabled)
                if model.settings.watchFolderEnabled {
                    LabeledContent("Folder") {
                        HStack {
                            Text(model.settings.watchFolder?.lastPathComponent ?? "None")
                                .foregroundStyle(.secondary)
                            Button("Choose…") { chooseWatch() }
                        }
                    }
                    Toggle("Move added torrents to Trash", isOn: $model.settings.trashAddedTorrents)
                }
            }
            Section {
                Picker("Clear completed from list", selection: $model.settings.clearCompleted) {
                    Text("Never").tag(ClearCompletedPolicy.never)
                    Text("After 1 Day").tag(ClearCompletedPolicy.afterDay)
                    Text("After 1 Week").tag(ClearCompletedPolicy.afterWeek)
                }
            }
        }
    }

    private func chooseWatch() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.prompt = "Choose"
        if p.runModal() == .OK, let u = p.url { model.settings.watchFolder = u }
    }
}

// MARK: - Schedule

struct SchedulePane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let s = model.settings
        SettingsPaneFrame {
            Section {
                Toggle("Download hours", isOn: $model.settings.downloadHoursEnabled)
                ScheduleTimelineView(downloads: $model.settings.downloadHours,
                                     downloadsEnabled: s.downloadHoursEnabled,
                                     slow: $model.settings.slowModeHours,
                                     slowEnabled: s.slowModeScheduled)
                    .padding(.vertical, 4)
                if s.downloadHoursEnabled {
                    LabeledContent("From") {
                        HStack(spacing: 8) {
                            MinuteField(minute: $model.settings.downloadHours.startMinute)
                            Text("to").foregroundStyle(.secondary)
                            MinuteField(minute: $model.settings.downloadHours.endMinute)
                        }
                    }
                    DaysPicker(days: $model.settings.downloadHours.weekdays)
                }
                Text(ScheduleText.summary(enabled: s.downloadHoursEnabled, window: s.downloadHours,
                                          status: ScheduleText.status(s.downloadHours, now: Date())))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Toggle(isOn: $model.settings.keepAwakeForSchedule) {
                    Text("Keep Mac awake to start downloads on time")
                    Text("Your Mac can’t start downloads while it’s asleep.")
                }
            }
            Section("Slow Mode") {
                LabeledContent("Download limit") { RateField(bytes: $model.settings.slowModeDownLimit) }
                LabeledContent("Upload limit") { RateField(bytes: $model.settings.slowModeUpLimit) }
                Toggle("Turn on automatically", isOn: $model.settings.slowModeScheduled)
                if s.slowModeScheduled {
                    LabeledContent("From") {
                        HStack(spacing: 8) {
                            MinuteField(minute: $model.settings.slowModeHours.startMinute)
                            Text("to").foregroundStyle(.secondary)
                            MinuteField(minute: $model.settings.slowModeHours.endMinute)
                        }
                    }
                }
            }
            Section("Pause Automatically") {
                Toggle("On battery power", isOn: $model.settings.pauseOnBattery)
                Toggle("On Personal Hotspot or Low Data Mode networks", isOn: $model.settings.pauseOnExpensiveNetwork)
            }
        }
    }
}

/// hh:mm field bound to minutes after midnight.
struct MinuteField: View {
    @Binding var minute: Int
    var body: some View {
        DatePicker("", selection: Binding(
            get: { Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date() },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                minute = ((c.hour ?? 0) * 60 + (c.minute ?? 0)) / 15 * 15
            }), displayedComponents: .hourAndMinute)
            .datePickerStyle(.stepperField)
            .labelsHidden()
            .fixedSize()
    }
}

/// Every Day / Weekdays / Weekends / Custom…; the chips appear only for Custom.
struct DaysPicker: View {
    @Binding var days: Set<Int>
    @State private var custom = false

    private enum Preset: Hashable { case everyDay, weekdays, weekends, custom }

    private var preset: Preset {
        if custom { return .custom }
        switch days {
        case Set(1...7): return .everyDay
        case Set(2...6): return .weekdays
        case [1, 7]: return .weekends
        default: return .custom
        }
    }

    var body: some View {
        Picker("Days", selection: Binding<Preset>(get: { preset }, set: { p in
            switch p {
            case .everyDay: custom = false; days = Set(1...7)
            case .weekdays: custom = false; days = Set(2...6)
            case .weekends: custom = false; days = [1, 7]
            case .custom: custom = true
            }
        })) {
            Text("Every Day").tag(Preset.everyDay)
            Text("Weekdays").tag(Preset.weekdays)
            Text("Weekends").tag(Preset.weekends)
            Divider()
            Text("Custom…").tag(Preset.custom)
        }
        if preset == .custom {
            LabeledContent("") { WeekdayChips(days: $days) }
        }
    }
}

/// 24pt circular weekday chips (S M T W T F S), Calendar weekday numbering.
struct WeekdayChips: View {
    @Binding var days: Set<Int>
    var body: some View {
        let letters = Calendar.current.veryShortWeekdaySymbols
        let names = Calendar.current.weekdaySymbols
        HStack(spacing: 4) {
            ForEach(1...7, id: \.self) { d in
                Toggle(isOn: Binding(get: { days.contains(d) },
                                     set: { on in if on { days.insert(d) } else { days.remove(d) } })) {
                    Text(letters[d - 1]).font(.system(size: 11, weight: .medium)).frame(width: 14)
                }
                .toggleStyle(.button)
                .buttonBorderShape(.circle)
                .controlSize(.small)
                .accessibilityLabel(names[d - 1])
            }
        }
    }
}

/// Rate in MB/s or KB/s with a unit picker.
struct RateField: View {
    @Binding var bytes: Int64
    @State private var unit: Int64 = 1_000_000

    var body: some View {
        HStack(spacing: 6) {
            TextField("", value: Binding(
                get: { Double(bytes) / Double(unit) },
                set: { bytes = Int64(max(0, $0) * Double(unit)) }), format: .number.precision(.fractionLength(0...1)))
                .frame(width: 56)
                .multilineTextAlignment(.trailing)
                .labelsHidden()
            Picker("", selection: $unit) {
                Text("MB/s").tag(Int64(1_000_000))
                Text("KB/s").tag(Int64(1_000))
            }
            .labelsHidden()
            .fixedSize()
        }
        .onAppear { unit = bytes > 0 && bytes < 1_000_000 ? 1_000 : 1_000_000 }
    }
}

// MARK: - Network

struct NetworkPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        SettingsPaneFrame {
            Section("Speed Limits") {
                LabeledContent("Download") { OptionalRateField(bytes: $model.settings.downLimit) }
                LabeledContent("Upload") { OptionalRateField(bytes: $model.settings.upLimit) }
            }
            Section {
                Stepper(value: $model.settings.maxConcurrent, in: 1...20) {
                    LabeledContent("Simultaneous downloads", value: "\(model.settings.maxConcurrent)")
                }
                Stepper(value: $model.settings.connectionsPerServer, in: 1...16) {
                    LabeledContent("Connections per server", value: "\(model.settings.connectionsPerServer)")
                }
            }
        }
    }
}

/// Unlimited, or a rate.
struct OptionalRateField: View {
    @Binding var bytes: Int64?
    var body: some View {
        HStack(spacing: 8) {
            Picker("", selection: Binding(get: { bytes == nil ? 0 : 1 },
                                          set: { bytes = $0 == 0 ? nil : (bytes ?? 5_000_000) })) {
                Text("Unlimited").tag(0)
                Text("Limit to").tag(1)
            }
            .labelsHidden()
            .fixedSize()
            if bytes != nil {
                RateField(bytes: Binding(get: { bytes ?? 0 }, set: { bytes = $0 }))
            }
        }
    }
}

// MARK: - BitTorrent

struct BitTorrentPane: View {
    @Environment(AppModel.self) private var model
    @State private var trackersOpen = false

    private enum After: Int { case stop, ratio, time }

    var body: some View {
        @Bindable var model = model
        SettingsPaneFrame {
            Section {
                Picker("After download", selection: Binding<After>(
                    get: {
                        switch model.settings.afterDownload { case .stop: .stop; case .ratio: .ratio; case .minutes: .time }
                    },
                    set: { v in
                        switch v {
                        case .stop: model.settings.afterDownload = .stop
                        case .ratio: model.settings.afterDownload = .ratio(1.0)
                        case .time: model.settings.afterDownload = .minutes(60)
                        }
                    })) {
                    Text("Stop Sharing").tag(After.stop)
                    Text("Seed Until Ratio…").tag(After.ratio)
                    Text("Seed For…").tag(After.time)
                }
                switch model.settings.afterDownload {
                case .ratio(let r):
                    LabeledContent("Ratio") {
                        TextField("", value: Binding(get: { r }, set: { model.settings.afterDownload = .ratio(max(0.1, $0)) }),
                                  format: .number.precision(.fractionLength(1)))
                            .frame(width: 56).multilineTextAlignment(.trailing).labelsHidden()
                    }
                case .minutes(let m):
                    LabeledContent("Minutes") {
                        TextField("", value: Binding(get: { m }, set: { model.settings.afterDownload = .minutes(max(1, $0)) }),
                                  format: .number)
                            .frame(width: 56).multilineTextAlignment(.trailing).labelsHidden()
                    }
                case .stop:
                    EmptyView()
                }
            }
            Section {
                Stepper(value: $model.settings.maxPeers, in: 5...500, step: 5) {
                    LabeledContent("Max peers per download", value: "\(model.settings.maxPeers)")
                }
                LabeledContent("Listening port") {
                    TextField("", value: $model.settings.listenPort, format: .number.grouping(.never))
                        .frame(width: 72).multilineTextAlignment(.trailing).labelsHidden()
                }
            }
            Section {
                Toggle("DHT", isOn: $model.settings.dht)
                Toggle("Peer Exchange", isOn: $model.settings.pex)
                Toggle("Local Peer Discovery", isOn: $model.settings.lpd)
                Toggle("Prefer encrypted connections", isOn: $model.settings.preferEncryption)
            }
            Section {
                DisclosureGroup("Extra trackers", isExpanded: $trackersOpen) {
                    TextEditor(text: $model.settings.extraTrackers)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(height: 80)
                    Text("One tracker per line. Added to every torrent.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                ForEach(SearchSourceID.allCases) { source in
                    Toggle(isOn: Binding(get: { model.settings.searchSources.contains(source) },
                                         set: { model.settings.setSearchSource(source, enabled: $0) })) {
                        Text(source.name)
                        Text(source.coverage)
                    }
                }
                Toggle("Show adult results", isOn: Binding(get: { model.settings.showAdultResults },
                                                           set: { model.settings.searchShowAdult = $0 ? true : nil }))
            } header: {
                Text("Search")
            } footer: {
                Text("Searches go to the sources you turn on. File lists can also come from itorrents.net.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Engine

struct EnginePane: View {
    @Environment(AppModel.self) private var model
    @State private var advancedOpen = false

    var body: some View {
        @Bindable var model = model
        SettingsPaneFrame {
            Section {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle().fill(statusColor).frame(width: 8, height: 8)
                        Text(statusText)
                    }
                }
                Text("Progress saved every 10 seconds")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Restart Engine") { model.restartEngine() }
                    Button("Show Log") { AppHooks.showEngineLog(model) }
                    Spacer()
                }
            }
            Section {
                DisclosureGroup("Advanced aria2 options", isExpanded: $advancedOpen) {
                    TextEditor(text: $model.settings.advancedOptions)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(height: 100)
                    Text("One option per line, like max-tries=5. Wrong values can stop downloads from starting.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var statusText: String {
        switch model.snapshot.engine {
        case .starting: return "Starting…"
        case .running(let v): return "Running · aria2 \(v)"
        case .stopped(let r): return "Stopped · \(r)"
        }
    }

    private var statusColor: Color {
        switch model.snapshot.engine {
        case .starting: return .orange
        case .running: return .green
        case .stopped: return .red
        }
    }
}
