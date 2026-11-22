import AppKit
import SwiftUI

/// Tide's app icon (DESIGN.md §10): the Tide mark — a disc sliced by two parallel wave cuts —
/// on an indigo→cyan squircle. Drawn on a 1024 canvas and scaled to any frame. The menu bar glyph
/// uses the same mark geometry (TideMark.cuts / amplitude / cycles / phase).
struct AppIconView: View {
    var dark = false
    /// The 16/32 px variant: wider cuts and stronger waves so the mark survives downsampling.
    var small = false

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 1024
            ZStack {
                // Body: 824×824 continuous squircle.
                RoundedRectangle(cornerRadius: 185.4 * s, style: .continuous)
                    .fill(LinearGradient(
                        colors: dark ? [Color(hex: 0x24243A), Color(hex: 0x0B0D14)]
                                     : [Color(hex: 0x4338CA), Color(hex: 0x2563EB), Color(hex: 0x06B6D4)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(
                        // Soft sheen over the top third.
                        RoundedRectangle(cornerRadius: 185.4 * s, style: .continuous)
                            .fill(LinearGradient(stops: [
                                .init(color: .white.opacity(0.16), location: 0),
                                .init(color: .white.opacity(0), location: 0.42),
                            ], startPoint: .top, endPoint: .bottom))
                    )
                    .frame(width: 824 * s, height: 824 * s)

                TideMark(dark: dark, small: small)
                    .frame(width: 500 * s, height: 500 * s)
                    .shadow(color: .black.opacity(0.22), radius: 30 * s, y: 16 * s)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// The Tide mark: a disc sliced by two parallel wave cuts into three bands — sky, swell, depth —
/// fading from solid to translucent. Abstract, and it reads at 16 px.
struct TideMark: View {
    var dark = false
    var small = false

    /// Cut centres (fraction of the disc's height from the top), gap and wave shape, shared with
    /// the menu bar glyph so the two always match.
    static let cuts: [CGFloat] = [0.43, 0.67]
    static let gap: CGFloat = 0.058
    static let amplitude: CGFloat = 0.034
    static let cycles: CGFloat = 1.05
    static let phase: CGFloat = 0.08
    /// Small-size variant (16/32 px icon).
    static let smallGap: CGFloat = 0.10
    static let smallAmplitude: CGFloat = 0.045

    var body: some View {
        GeometryReader { geo in
            let d = min(geo.size.width, geo.size.height)
            let c = Self.cuts, g = (small ? Self.smallGap : Self.gap) / 2
            let amp = small ? Self.smallAmplitude : Self.amplitude
            let opacities: [Double] = dark ? [1, 0.74, 0.52] : [1, 0.82, 0.6]
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    WaveBand(top: i == 0 ? nil : c[i - 1] + g, bottom: i == 2 ? nil : c[i] - g,
                             amplitude: amp, cycles: Self.cycles, phase: Self.phase)
                        .fill(i == 0
                              ? AnyShapeStyle(LinearGradient(colors: dark ? [Color(hex: 0xA5B4FC), Color(hex: 0x67E8F9)] : [.white, Color(hex: 0xE4F1FF)],
                                                             startPoint: .top, endPoint: .bottom))
                              : AnyShapeStyle((dark ? Color(hex: 0x67E8F9) : Color.white).opacity(opacities[i])))
                }
            }
            .frame(width: d, height: d)
            .clipShape(Circle())
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

/// Region between two sine curves (nil = the rect's top/bottom edge). Positions are fractions of
/// the height from the top.
struct WaveBand: Shape {
    var top: CGFloat?
    var bottom: CGFloat?
    var amplitude: CGFloat
    var cycles: CGFloat
    var phase: CGFloat

    func path(in rect: CGRect) -> Path {
        let steps = 120
        func y(_ base: CGFloat, _ t: CGFloat) -> CGFloat {
            rect.minY + rect.height * (base + amplitude * sin(2 * .pi * (t * cycles + phase)))
        }
        var p = Path()
        if let top {
            p.move(to: CGPoint(x: rect.minX, y: y(top, 0)))
            for i in 1...steps {
                let t = CGFloat(i) / CGFloat(steps)
                p.addLine(to: CGPoint(x: rect.minX + rect.width * t, y: y(top, t)))
            }
        } else {
            p.move(to: CGPoint(x: rect.minX, y: rect.minY - 1))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY - 1))
        }
        if let bottom {
            for i in stride(from: steps, through: 0, by: -1) {
                let t = CGFloat(i) / CGFloat(steps)
                p.addLine(to: CGPoint(x: rect.minX + rect.width * t, y: y(bottom, t)))
            }
        } else {
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY + 1))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY + 1))
        }
        p.closeSubpath()
        return p
    }
}

/// `Tide --render-icon <png> [--dark] [--small]`: the 1024 px icon (small = the 16/32 px art).
enum IconExport {
    @MainActor
    static func write(to path: String, dark: Bool, small: Bool) -> Never {
        let renderer = ImageRenderer(content: AppIconView(dark: dark, small: small).frame(width: 1024, height: 1024))
        renderer.scale = 1
        if let cg = renderer.cgImage,
           let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
        print(path)
        exit(0)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}
