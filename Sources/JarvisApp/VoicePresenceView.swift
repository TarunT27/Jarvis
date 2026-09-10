import SwiftUI

enum VoicePresenceState: Equatable {
    case listening
    case thinking
    case speaking

    var label: String {
        switch self {
        case .listening: "LISTENING"
        case .thinking: "THINKING"
        case .speaking: "SPEAKING"
        }
    }

    var detail: String {
        switch self {
        case .listening: "Listening for your voice"
        case .thinking: "Working on it"
        case .speaking: "Jarvis is responding"
        }
    }
}

struct VoicePresenceView: View {
    let state: VoicePresenceState
    let audioLevel: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let particles = makeParticles()

    var body: some View {
        VStack(spacing: 8) {
            TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
                Canvas { context, size in
                    drawPresence(
                        in: &context,
                        size: size,
                        time: reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                    )
                }
                .frame(width: 220, height: 170)
            }
            Text(state.label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(2.2)
                .foregroundStyle(.teal)
            Text(state.detail)
                .font(JarvisTypography.font(.regular, style: .caption))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Jarvis voice presence")
        .accessibilityValue(state.detail)
    }

    private func drawPresence(
        in context: inout GraphicsContext,
        size: CGSize,
        time: TimeInterval
    ) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let baseRadius = min(size.width, size.height) * 0.245
        let level = max(0, min(1, audioLevel))
        let syntheticPulse = CGFloat((sin(time * 4.8) + 1) * 0.5)
        let energy = min(1, level * 0.95 + syntheticPulse * 0.12)
        let breathing = CGFloat(sin(time * 1.15)) * 0.035
        let coreRadius = min(size.width, size.height) * (0.145 + breathing + energy * 0.018)

        let haloRadius = baseRadius * 1.9
        let haloRect = CGRect(
            x: center.x - haloRadius,
            y: center.y - haloRadius,
            width: haloRadius * 2,
            height: haloRadius * 2
        )
        context.fill(
            Path(ellipseIn: haloRect),
            with: .radialGradient(
                Gradient(colors: [.teal.opacity(0.22), .teal.opacity(0.05), .clear]),
                center: center,
                startRadius: 0,
                endRadius: haloRadius
            )
        )

        drawParticles(in: &context, center: center, radius: baseRadius, time: time, energy: energy)

        for (index, multiplier) in [1.0, 1.28, 1.52].enumerated() {
            let ringPulse = CGFloat(sin(time * (0.8 + Double(index) * 0.16) + Double(index))) * 0.012
            let expansion = energy * CGFloat(0.032 + Double(index) * 0.028)
            let radius = baseRadius * CGFloat(multiplier + ringPulse + expansion)
            let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            context.stroke(
                Path(ellipseIn: rect),
                with: .color(.teal.opacity(0.72 - Double(index) * 0.16 + Double(energy) * 0.08)),
                lineWidth: index == 0 ? 1.5 : 0.9
            )
        }

        drawAudioField(in: &context, center: center, radius: baseRadius, time: time, energy: energy)

        let coreRect = CGRect(x: center.x - coreRadius, y: center.y - coreRadius, width: coreRadius * 2, height: coreRadius * 2)
        context.fill(
            Path(ellipseIn: coreRect),
            with: .radialGradient(
                Gradient(colors: [.white.opacity(0.96), .teal.opacity(0.92), .teal.opacity(0.34)]),
                center: CGPoint(x: center.x - coreRadius * 0.22, y: center.y - coreRadius * 0.28),
                startRadius: 0,
                endRadius: coreRadius * 1.3
            )
        )
    }

    private func drawAudioField(
        in context: inout GraphicsContext,
        center: CGPoint,
        radius: CGFloat,
        time: TimeInterval,
        energy: CGFloat
    ) {
        var path = Path()
        let sampleCount = 96
        for sample in 0...sampleCount {
            let progress = CGFloat(sample) / CGFloat(sampleCount)
            let angle = progress * .pi * 2
            let harmonic =
                sin(angle * 5 + CGFloat(time) * 4.2) * 0.52 +
                sin(angle * 9 - CGFloat(time) * 2.1) * 0.26 +
                sin(angle * 13 + CGFloat(time) * 1.4) * 0.12
            let pointRadius = radius * (1.02 + energy * (0.08 + harmonic * 0.075))
            let point = CGPoint(x: center.x + cos(angle) * pointRadius, y: center.y + sin(angle) * pointRadius)
            if sample == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        context.stroke(path, with: .color(.teal.opacity(0.82)), lineWidth: 1.1 + energy * 1.2)
    }

    private func drawParticles(
        in context: inout GraphicsContext,
        center: CGPoint,
        radius: CGFloat,
        time: TimeInterval,
        energy: CGFloat
    ) {
        for particle in Self.particles {
            let distance = radius * particle.distance + CGFloat(sin(time * 0.42 + particle.phase)) * 5 + energy * 16
            let angle = particle.angle + CGFloat(time) * particle.orbitSpeed
            let point = CGPoint(x: center.x + cos(angle) * distance, y: center.y + sin(angle) * distance)
            let pulse = 0.55 + 0.45 * CGFloat(sin(time * 1.5 + particle.phase))
            let opacity = particle.opacity * pulse * (0.42 + energy * 0.72)
            let size = particle.size * (0.8 + energy * 0.65)
            let rect = CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
            context.fill(Path(ellipseIn: rect), with: .color(.teal.opacity(opacity)))
        }
    }

    private struct Particle {
        let angle: CGFloat
        let distance: CGFloat
        let size: CGFloat
        let opacity: Double
        let phase: CGFloat
        let orbitSpeed: CGFloat
    }

    private static func makeParticles() -> [Particle] {
        var seed: UInt64 = 0x4A4152564953
        func next() -> Double {
            seed = 2862933555777941757 &* seed &+ 3037000493
            return Double(seed % 10_000) / 10_000
        }
        return (0..<42).map { _ in
            Particle(
                angle: CGFloat(next() * Double.pi * 2),
                distance: CGFloat(1.05 + next() * 0.7),
                size: CGFloat(0.8 + next() * 2.2),
                opacity: 0.14 + next() * 0.36,
                phase: CGFloat(next() * Double.pi * 2),
                orbitSpeed: CGFloat(-0.012 + next() * 0.024)
            )
        }
    }
}
