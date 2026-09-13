import SwiftUI

/// The Jarvis waveform is vector geometry at every size, but not the same
/// geometry at every size.
///
/// One set of ratios cannot serve 16 points and 92 points at once: at the small
/// end the capsules thin to under two points, the aperture shrinks to a smudge
/// with a hairline ring around it, and a one-percent edge highlight lands on
/// less than half a device pixel. So the view picks a build from the side it is
/// given. The silhouette, the rhythm and the accessibility label are constant;
/// only the detail that cannot survive the pixel grid is dropped.
struct JarvisMark: View {
    var ink: Color = JarvisTheme.accent

    private struct Build {
        let heights: [CGFloat]
        let barWidth: CGFloat
        let gap: CGFloat
        /// Diameter of the hub that joins the central capsules, as a fraction of
        /// the side. Zero leaves the capsules separate.
        let hub: CGFloat
        /// Diameter of the circular negative space. Zero leaves the mark solid.
        let aperture: CGFloat
        /// Whether the smoky-lilac edge can resolve at this size.
        let edge: Bool
    }

    /// Under 24pt the mark is a favicon: five bars, widened and spaced so their
    /// strokes land near whole device pixels, with no interior detail at all.
    private static let compact = Build(heights: [0.38, 0.68, 0.96, 0.68, 0.38],
                                       barWidth: 0.14, gap: 0.05, hub: 0, aperture: 0, edge: false)
    /// 24-48pt: the full rhythm, with the aperture opened up so the ring around
    /// it stays a shape rather than a hairline.
    private static let standard = Build(heights: [0.26, 0.51, 0.74, 0.94, 0.74, 0.51, 0.26],
                                        barWidth: 0.105, gap: 0.038, hub: 0.32, aperture: 0.22, edge: false)
    /// 48pt and up: display sizes, where the edge finally has room to read.
    private static let full = Build(heights: [0.26, 0.51, 0.74, 0.94, 0.74, 0.51, 0.26],
                                    barWidth: 0.105, gap: 0.038, hub: 0.30, aperture: 0.185, edge: true)

    private static func build(for side: CGFloat) -> Build {
        if side < 24 { return compact }
        if side < 48 { return standard }
        return full
    }

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let build = Self.build(for: side)
            waveform(build, side: side)
                .foregroundStyle(fill(build))
                .mask { aperture(build, side: side) }
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Jarvis")
    }

    /// A gradient stop rather than a masked sliver: it scales with the mark, and
    /// it reads as a cooler edge instead of a stray line.
    private func fill(_ build: Build) -> AnyShapeStyle {
        guard build.edge else { return AnyShapeStyle(ink) }
        return AnyShapeStyle(LinearGradient(
            stops: [.init(color: ink, location: 0.86), .init(color: JarvisTheme.lilac, location: 1)],
            startPoint: .leading, endPoint: .trailing))
    }

    private func waveform(_ build: Build, side: CGFloat) -> some View {
        ZStack {
            if build.hub > 0 {
                // Connects the central capsules around the circular aperture.
                Circle().frame(width: side * build.hub, height: side * build.hub)
            }
            HStack(spacing: side * build.gap) {
                ForEach(Array(build.heights.enumerated()), id: \.offset) { _, height in
                    Capsule().frame(width: side * build.barWidth, height: side * height)
                }
            }
        }.frame(width: side, height: side)
    }

    @ViewBuilder
    private func aperture(_ build: Build, side: CGFloat) -> some View {
        if build.aperture > 0 {
            Rectangle().overlay {
                Circle().frame(width: side * build.aperture, height: side * build.aperture)
                    .blendMode(.destinationOut)
            }.compositingGroup()
        } else {
            Rectangle()
        }
    }
}
