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

    var symbol: String {
        switch self {
        case .listening: "waveform"
        case .thinking: "ellipsis"
        case .speaking: "speaker.wave.2"
        }
    }

    var tint: Color {
        self == .listening ? JarvisTheme.recording : JarvisTheme.accent
    }
}

struct VoicePresenceView: View {
    let state: VoicePresenceState
    let audioLevel: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    var body: some View {
        VStack(spacing: 8) {
            JarvisMark()
                .frame(width: 92, height: 92)
                // The mic level rides on top of a slow pulse, so silence still
                // reads as live rather than frozen.
                .scaleEffect(reduceMotion ? 1 : (breathing ? 1.035 : 1) + max(0, min(1, audioLevel)) * 0.035)
                .opacity(reduceMotion ? 1 : (breathing ? 1 : 0.78))
                .frame(width: 220, height: 170)
                .accessibilityHidden(true)
            Text(state.label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(2.2)
                .foregroundStyle(state.tint)
            Text(state.detail)
                .font(JarvisTypography.font(.regular, style: .caption))
                .foregroundStyle(JarvisTheme.secondary)
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(JarvisMotion.breathe) { breathing = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Jarvis voice presence")
        .accessibilityValue(state.detail)
    }
}
