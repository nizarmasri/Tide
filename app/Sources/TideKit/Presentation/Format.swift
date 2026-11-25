import Foundation

/// Number, size, speed, time and ETA formatting per DESIGN.md §9.
/// Sizes are decimal (like Finder), 3 significant digits, a space before the unit.
public enum TideFormat {
    private static let significant: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesSignificantDigits = true
        f.minimumSignificantDigits = 1
        f.maximumSignificantDigits = 3
        return f
    }()

    private static let oneDecimal: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 1
        f.maximumFractionDigits = 1
        f.roundingMode = .down
        return f
    }()

    private static let integer: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()

    private static let ordinalFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .ordinal
        return f
    }()

    private static let units = ["KB", "MB", "GB", "TB", "PB"]

    /// Scales a byte count to (value, unit index); index -1 means plain bytes.
    static func scale(_ bytes: Int64) -> (Double, Int) {
        let n = max(0, bytes)
        if n < 1000 { return (Double(n), -1) }
        var v = Double(n) / 1000
        var i = 0
        while v >= 999.5, i < units.count - 1 { v /= 1000; i += 1 }
        return (v, i)
    }

    /// "68.2 GB", "412 GB", "1.21 TB", "38 bytes".
    public static func bytes(_ bytes: Int64) -> String {
        let (v, i) = scale(bytes)
        if i < 0 {
            if bytes == 0 { return "Zero bytes" }
            return bytes == 1 ? "1 byte" : "\(integer.string(from: NSNumber(value: bytes)) ?? "\(bytes)") bytes"
        }
        return "\(significant.string(from: NSNumber(value: v)) ?? "\(v)") \(units[i])"
    }

    /// "24.6 MB/s", "512 KB/s". Zero is "0 KB/s".
    public static func speed(_ bytesPerSecond: Int64) -> String {
        if bytesPerSecond < 1000 { return bytesPerSecond <= 0 ? "0 KB/s" : "\(bytesPerSecond) B/s" }
        return bytes(bytesPerSecond) + "/s"
    }

    /// "9.4 of 41.0 GB", "1.2 of 6.1 GB", "45 of 412 GB": both numbers in the total's unit with the
    /// same decimals — one below 100, none at 100 or above. Nothing done yet → just the total.
    /// Too little to show in the total's unit gets its own: "64.1 MB of 8.0 GB", never "0.0 of 8.0 GB".
    public static func progress(_ done: Int64, of total: Int64) -> String {
        if done <= 0 || total <= 0 { return bytes(total) }
        let (tv, ti) = scale(total)
        if ti < 0 { return "\(count(Int(min(done, total)))) of \(bytes(total))" }
        let unit = pow(1000.0, Double(ti + 1))
        let dv = Double(min(done, total)) / unit
        let f = NumberFormatter()
        f.numberStyle = .decimal
        let decimals = tv < 99.95 ? 1 : 0
        f.minimumFractionDigits = decimals
        f.maximumFractionDigits = decimals
        f.roundingMode = .halfUp
        let t = f.string(from: NSNumber(value: tv)) ?? "\(tv)"
        if dv * pow(10, Double(decimals)) < 1 { return "\(bytes(done)) of \(t) \(units[ti])" }
        f.roundingMode = .down   // the done side never rounds up to the total
        let d = f.string(from: NSNumber(value: dv)) ?? "\(dv)"
        return "\(d) of \(t) \(units[ti])"
    }

    /// Display-only copy of a release name with zero-width spaces after ".", "-" and "_" so long
    /// names wrap at sensible points. Never use the result as data.
    public static func breakable(_ name: String) -> String {
        var out = ""
        out.reserveCapacity(name.count + name.count / 4)
        for ch in name {
            out.append(ch)
            if ch == "." || ch == "-" || ch == "_" { out.append("\u{200B}") }
        }
        return out
    }

    /// Integer percent, rounded down so 99.9% never reads as 100%.
    public static func percent(_ fraction: Double) -> String {
        let p = Int((max(0, min(1, fraction)) * 100).rounded(.down))
        return "\(p)%"
    }

    /// One decimal, for the inspector: "34.2%".
    public static func precisePercent(_ fraction: Double) -> String {
        let v = (max(0, min(1, fraction)) * 1000).rounded(.down) / 10
        return (oneDecimal.string(from: NSNumber(value: v)) ?? "\(v)") + "%"
    }

    /// "1 hr 12 min", "5 min", "Less than a minute", "1 day 4 hr", "2 days".
    public static func duration(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s < 60 { return "Less than a minute" }
        let m = s / 60
        if m < 60 { return "\(m) min" }
        let h = m / 60, mm = m % 60
        if h < 24 { return mm == 0 ? "\(h) hr" : "\(h) hr \(mm) min" }
        let d = h / 24, hh = h % 24
        if d >= 2 { return "\(d) days" }
        return hh == 0 ? "1 day" : "1 day \(hh) hr"
    }

    /// "1 hr 12 min left", "Less than a minute left".
    public static func timeLeft(_ seconds: Int) -> String { duration(seconds) + " left" }

    /// Second-precision variant for short checks: "38 sec left".
    public static func shortTimeLeft(_ seconds: Int) -> String {
        seconds < 60 ? "\(max(1, seconds)) sec left" : timeLeft(seconds)
    }

    /// "2nd"
    public static func ordinal(_ n: Int) -> String { ordinalFormatter.string(from: NSNumber(value: n)) ?? "\(n)" }

    public static func count(_ n: Int) -> String { integer.string(from: NSNumber(value: n)) ?? "\(n)" }

    /// Locale time, e.g. "01:00" or "1:00 AM".
    public static func time(_ date: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: date)
    }

    /// "Today at 07:42", "Yesterday at 21:10", "Nov 17 at 07:42".
    public static func dayAndTime(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let t = time(date, calendar: calendar)
        if calendar.isDate(date, inSameDayAs: now) { return "Today at \(t)" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) {
            return "Yesterday at \(t)"
        }
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return "\(f.string(from: date)) at \(t)"
    }

    /// "3 days ago", "2 years ago".
    public static func relative(_ date: Date, now: Date = Date(),
                                style: RelativeDateTimeFormatter.UnitsStyle = .full) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = style
        return f.localizedString(for: date, relativeTo: now)
    }

    /// "Starts at 01:00" (today), "Starts tomorrow at 01:00", "Starts Nov 24 at 01:00".
    public static func startsAt(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let t = time(date, calendar: calendar)
        if calendar.isDate(date, inSameDayAs: now) { return "Starts at \(t)" }
        if let tm = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tm) {
            return "Starts tomorrow at \(t)"
        }
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return "Starts \(f.string(from: date)) at \(t)"
    }

    /// "Media · 412 GB free" / "Media · Not connected".
    public static func volumeLine(_ v: VolumeStatus) -> String {
        guard v.isConnected else { return "\(v.name) · Not connected" }
        if let free = v.freeBytes { return "\(v.name) · \(bytes(free)) free" }
        return v.name
    }

    /// Middle-truncates a long name for dialog titles: "The.Movie…REMUX.mkv".
    public static func shortName(_ name: String, max: Int = 40) -> String {
        guard name.count > max, max > 8 else { return name }
        let tail = max / 2 - 1
        let head = max - tail - 1
        return String(name.prefix(head)) + "…" + String(name.suffix(tail))
    }

    // MARK: Spoken forms (VoiceOver)

    private static let spokenUnits = ["kilobytes", "megabytes", "gigabytes", "terabytes", "petabytes"]

    public static func spokenBytes(_ bytes: Int64) -> String {
        let (v, i) = scale(bytes)
        if i < 0 { return bytes == 1 ? "1 byte" : "\(bytes) bytes" }
        return "\(significant.string(from: NSNumber(value: v)) ?? "\(v)") \(spokenUnits[i])"
    }

    public static func spokenSpeed(_ bps: Int64) -> String { spokenBytes(bps) + " per second" }

    public static func spokenDuration(_ seconds: Int) -> String {
        if seconds < 60 { return "less than a minute" }
        let f = DateComponentsFormatter()
        f.unitsStyle = .full
        f.allowedUnits = seconds >= 86_400 ? [.day, .hour] : [.hour, .minute]
        f.maximumUnitCount = 2
        return f.string(from: TimeInterval(seconds)) ?? duration(seconds)
    }
}
