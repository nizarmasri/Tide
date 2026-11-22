import SwiftUI
import TideKit

/// Two-track 24-hour timeline: download hours (accent) and slow mode (indigo), with draggable
/// 15-minute knobs (DESIGN.md §8). The one custom control.
struct ScheduleTimelineView: View {
    @Binding var downloads: TimeWindow
    var downloadsEnabled: Bool
    @Binding var slow: TimeWindow
    var slowEnabled: Bool
    var now: Date = Date()

    private let labelWidth: CGFloat = 76
    private let track: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                Color.clear.frame(width: labelWidth, height: 12)
                GeometryReader { geo in
                    ForEach(0...8, id: \.self) { i in
                        let x = geo.size.width * CGFloat(i) / 8
                        Text(hourLabel(i * 3))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .fixedSize()
                            .position(x: min(max(x, 8), geo.size.width - 8), y: 6)
                    }
                }
                .frame(height: 12)
            }
            row(title: "Downloads", window: $downloads, enabled: downloadsEnabled, tint: .accent, offLabel: "Any time")
            row(title: "Slow Mode", window: $slow, enabled: slowEnabled, tint: .indigo, offLabel: nil)
            HStack(spacing: 0) {
                Color.clear.frame(width: labelWidth, height: 8)
                GeometryReader { geo in
                    let x = geo.size.width * nowFraction
                    Path { p in
                        p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x - 5, y: 6)); p.addLine(to: CGPoint(x: x + 5, y: 6))
                        p.closeSubpath()
                    }
                    .fill(.primary)
                }
                .frame(height: 8)
                .accessibilityHidden(true)
            }
        }
    }

    private var nowFraction: CGFloat {
        let c = Calendar.current.dateComponents([.hour, .minute], from: now)
        return CGFloat((c.hour ?? 0) * 60 + (c.minute ?? 0)) / 1440
    }

    private func hourLabel(_ h: Int) -> String {
        let uses24 = !(DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "").contains("a")
        if uses24 { return String(format: "%02d", h) }
        let hh = h % 12 == 0 ? 12 : h % 12
        return h == 24 ? "12a" : "\(hh)\(h < 12 ? "a" : "p")"
    }

    private func row(title: String, window: Binding<TimeWindow>, enabled: Bool, tint: StateTint, offLabel: String?) -> some View {
        HStack(spacing: 0) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(.quaternary)
                    if enabled {
                        TimelineBand(window: window, width: geo.size.width, height: track, tint: tint, title: title)
                    } else if let off = offLabel {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(tint.style)
                            .opacity(0.85)
                        Text(off)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.leading, 6)
                    }
                    // "now" line
                    Rectangle()
                        .fill(.primary)
                        .frame(width: 1, height: track + 4)
                        .offset(x: geo.size.width * nowFraction)
                        .accessibilityHidden(true)
                }
            }
            .frame(height: track)
        }
        .padding(.vertical, 2)
    }
}

/// The band(s) of one window plus its two knobs. A window crossing midnight draws as two
/// segments.
private struct TimelineBand: View {
    @Binding var window: TimeWindow
    var width: CGFloat
    var height: CGFloat
    var tint: StateTint
    var title: String

    @State private var dragOrigin: TimeWindow?

    private func x(_ minute: Int) -> CGFloat { width * CGFloat(minute) / 1440 }
    private func minute(atDelta dx: CGFloat) -> Int { Int((dx / width * 1440 / 15).rounded()) * 15 }

    var body: some View {
        let s = window.startMinute, e = window.endMinute
        ZStack(alignment: .leading) {
            ForEach(segments(s, e), id: \.0) { seg in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(tint.style)
                    .frame(width: max(2, x(seg.1) - x(seg.0)), height: height)
                    .offset(x: x(seg.0))
                    .gesture(bodyDrag)
            }
            knob(minute: s, isStart: true)
            knob(minute: e, isStart: false)
        }
    }

    private func segments(_ s: Int, _ e: Int) -> [(Int, Int)] {
        if s == e { return [(0, 1440)] }
        return s < e ? [(s, e)] : [(0, e), (s, 1440)]
    }

    private var bodyDrag: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { v in
                let o = dragOrigin ?? window
                if dragOrigin == nil { dragOrigin = o }
                let d = minute(atDelta: v.translation.width)
                window.startMinute = wrap(o.startMinute + d)
                window.endMinute = wrap(o.endMinute + d)
            }
            .onEnded { _ in dragOrigin = nil }
    }

    private func wrap(_ m: Int) -> Int { ((m % 1440) + 1440) % 1440 }

    private func knob(minute m: Int, isStart: Bool) -> some View {
        Circle()
            .fill(.white)
            .frame(width: 12, height: 12)
            .glassEffect(.regular.interactive(), in: Circle())
            .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
            .offset(x: x(m) - 6)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let o = dragOrigin ?? window
                        if dragOrigin == nil { dragOrigin = o }
                        let base = isStart ? o.startMinute : o.endMinute
                        let nm = wrap(base + minute(atDelta: v.translation.width))
                        if isStart { window.startMinute = nm } else { window.endMinute = nm }
                    }
                    .onEnded { _ in dragOrigin = nil }
            )
            .accessibilityElement()
            .accessibilityLabel("\(title) \(isStart ? "start" : "end")")
            .accessibilityValue(clock(m))
            .accessibilityAdjustableAction { dir in
                let step = dir == .increment ? 15 : -15
                if isStart { window.startMinute = wrap(window.startMinute + step) }
                else { window.endMinute = wrap(window.endMinute + step) }
            }
    }

    private func clock(_ m: Int) -> String {
        let d = Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
        return TideFormat.time(d)
    }
}
