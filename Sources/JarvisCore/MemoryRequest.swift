import Foundation

/// Recognises an explicit "remember ..." instruction.
///
/// Left to its own judgement the model is unreliable here: asked to remember a preference
/// it calls save_memory every time in isolation, but nearly never once the conversation
/// has history - it imitates the earlier turns where a stated preference was simply
/// acknowledged, and replies "Noted." while saving nothing. The user is then told their
/// preference was remembered when it was not. Stronger prompt wording did not move it.
///
/// The design already says lasting facts are saved through an explicit "remember this",
/// so that phrasing is honoured directly rather than left to discretion. The result is
/// still only a *proposal*: save_memory is consequential and the user approves the exact
/// text before anything is written.
public enum MemoryRequest {
    public static func fact(in message: String) -> String? {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 2000 else { return nil }
        let lower = trimmed.lowercased()

        // Questions and reminiscing are not save requests.
        guard !trimmed.hasSuffix("?") else { return nil }
        for opener in ["remember when", "remember how", "remember if", "remember why",
                       "do you remember", "did you remember", "can you remember",
                       "remember what", "remember our", "remember the time"] {
            if lower.hasPrefix(opener) { return nil }
        }
        // A reminder is a Reminders-app request, not a memory.
        if lower.hasPrefix("remember to ") { return nil }

        var rest: Substring?
        for opener in ["please remember that ", "please remember ", "remember that ",
                       "remember this: ", "remember: ", "remember "] {
            if lower.hasPrefix(opener) {
                rest = trimmed.dropFirst(opener.count)
                break
            }
        }
        guard var fact = rest.map({ String($0).trimmingCharacters(in: .whitespacesAndNewlines) }),
              fact.count >= 3, fact.count <= 1000 else { return nil }
        if fact.hasSuffix(".") == false { fact += "." }
        return fact
    }
}
