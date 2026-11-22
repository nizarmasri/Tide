import AppKit
import TideKit

/// Draws the 18×18 template menu bar glyph (DESIGN.md §3): the Tide orb, its water level showing
/// progress, a state symbol and an optional attention dot. Monochrome; the system tints it.
enum GlyphRenderer {
    static let size = NSSize(width: 18, height: 18)

    static func image(_ glyph: MenuBarGlyph) -> NSImage {
        let img = NSImage(size: size, flipped: true) { _ in
            draw(glyph)
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Tide"
        return img
    }

    /// The Tide mark at 18 pt, one rule per state (design review):
    ///   idle → the logo (disc + two wave cuts);
    ///   moving → the disc at 32% filling with solid water up to the aggregate progress, no cuts;
    ///   stopped (paused, scheduled, waiting, problem, done) → the solid disc with the state symbol
    ///   knocked out of it, in an 8×8 pt box with 1.75 pt strokes.
    /// Never animated.
    private static func draw(_ g: MenuBarGlyph) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let black = NSColor.black.cgColor
        let r: CGFloat = 7.5
        let disc = CGRect(x: 9 - r, y: 9 - r, width: 2 * r, height: 2 * r)
        let d = 2 * r

        // A wave across the disc at `base` (fraction of the disc height from the top). Flipped
        // context: y grows downward.
        func wavePoints(_ base: CGFloat, amp: CGFloat) -> [CGPoint] {
            (0...40).map { i in
                let t = CGFloat(i) / 40
                return CGPoint(x: disc.minX - 1 + (d + 2) * t,
                               y: disc.minY + d * base + amp * sin(2 * .pi * (t * TideMark.cycles + TideMark.phase)))
            }
        }

        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setFillColor(black)
        ctx.setStrokeColor(black)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        switch g.center {
        case .idle:
            ctx.fillEllipse(in: disc)
            ctx.setBlendMode(.clear)
            ctx.setLineWidth(1.2)
            for c in TideMark.cuts {
                ctx.beginPath()
                ctx.addLines(between: wavePoints(c, amp: 0.6))
                ctx.strokePath()
            }
            ctx.setBlendMode(.normal)

        case .arrow:
            ctx.setAlpha(0.32)
            ctx.fillEllipse(in: disc)
            ctx.setAlpha(1)
            let level = min(1, max(0.1, CGFloat(g.progress ?? 0)))
            ctx.saveGState()
            ctx.addEllipse(in: disc)
            ctx.clip()
            ctx.beginPath()
            ctx.addLines(between: wavePoints(1 - level, amp: 0.7))
            ctx.addLine(to: CGPoint(x: disc.maxX + 1, y: 18))
            ctx.addLine(to: CGPoint(x: disc.minX - 1, y: 18))
            ctx.closePath()
            ctx.fillPath()
            ctx.restoreGState()

        case .exclamation, .dots, .clock, .pause, .check:
            ctx.fillEllipse(in: disc)
            ctx.setBlendMode(.clear)
            ctx.setLineWidth(1.75)
            // Symbols live in the 8×8 box x 5…13, y 5…13.
            func line(_ pts: [CGPoint]) {
                ctx.beginPath()
                ctx.addLines(between: pts)
                ctx.strokePath()
            }
            func dot(_ x: CGFloat, _ y: CGFloat, _ rad: CGFloat) {
                ctx.fillEllipse(in: CGRect(x: x - rad, y: y - rad, width: 2 * rad, height: 2 * rad))
            }
            switch g.center {
            case .exclamation:
                line([CGPoint(x: 9, y: 5.3), CGPoint(x: 9, y: 9.6)])
                dot(9, 12.4, 1.05)
            case .dots:
                for x: CGFloat in [5.9, 9.0, 12.1] { dot(x, 9, 1.1) }
            case .clock:
                line([CGPoint(x: 9, y: 5.4), CGPoint(x: 9, y: 9.1), CGPoint(x: 11.9, y: 10.9)])
            case .pause:
                line([CGPoint(x: 7.3, y: 5.6), CGPoint(x: 7.3, y: 12.4)])
                line([CGPoint(x: 10.7, y: 5.6), CGPoint(x: 10.7, y: 12.4)])
            case .check:
                line([CGPoint(x: 5.6, y: 9.3), CGPoint(x: 8.0, y: 11.7), CGPoint(x: 12.4, y: 6.5)])
            default: break
            }
            ctx.setBlendMode(.normal)
        }
        ctx.endTransparencyLayer()

        // Attention dot at (15,3), 5pt, with a 1.5pt knockout gap.
        if g.attention {
            let p = CGPoint(x: 15, y: 3)
            ctx.setFillColor(black)
            ctx.setBlendMode(.clear)
            ctx.fillEllipse(in: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8))
            ctx.setBlendMode(.normal)
            ctx.fillEllipse(in: CGRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5))
        }
    }

    /// Fixed width for the speed text so the menu bar never shifts.
    static let speedFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    static var speedTextWidth: CGFloat {
        ("888.8 MB/s" as NSString).size(withAttributes: [.font: speedFont]).width.rounded(.up)
    }
}
