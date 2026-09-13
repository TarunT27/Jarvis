import SwiftUI

/// Three curves, and nothing else. Anything that moves in Jarvis picks one of
/// them, so a window full of independent animations still reads as one surface.
///
/// Reduce Motion never removes the feedback, only the travel: `settling`
/// collapses to a short crossfade, `nudging` becomes instant, `breathing`
/// becomes a static state that the adjacent text label already describes.
enum JarvisMotion {
    /// Anything that changes size or position: sheets, the composer growing,
    /// a reply arriving, selection moving between rows.
    static let settle = Animation.spring(response: 0.34, dampingFraction: 0.86)
    /// Anything that only changes colour or fill: send enabling, chips, toggles.
    /// Critically damped, so a control never overshoots under the pointer.
    static let nudge = Animation.spring(response: 0.22, dampingFraction: 1)
    /// Exactly one use: the mark while Jarvis is listening, thinking or speaking.
    static let breathe = Animation.easeInOut(duration: 1.6).repeatForever(autoreverses: true)

    static func settling(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? .easeOut(duration: 0.12) : settle
    }
    static func nudging(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : nudge
    }
    static func breathing(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : breathe
    }
}
