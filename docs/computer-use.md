# Supervised computer use

Jarvis can observe and propose input in one selected macOS application. Model inference stays on the local Ollama endpoint. This is a supervised prototype, not a claim of general desktop-agent reliability.

## Start a task

1. Open **Computer use** in Jarvis's sidebar.
2. Unlock Jarvis, then use **Request permissions**. Grant Screen Recording to Jarvis and Accessibility to Jarvis or JarvisBroker, its signed helper. Reopen Jarvis if macOS requires it, then choose **Check again**.
3. Choose an app already approved in Settings. This is a separate, task-scoped grant to inspect and control that app; launch permission alone cannot start a computer session.
4. Enter a precise task and choose **Start task**. **Try a TextEdit task** fills a small example. Open a blank TextEdit document manually first if launch presents a system file picker rather than a document.
5. Review each proposed input, its exact text/keys, and the observed controls. Approve or decline. Declining ends the session.
6. Use **Stop** to take over. **Control–Option–Escape** stops Jarvis from another app when its shortcut registered successfully; the panel reports the fallback if unavailable. Escape also stops while the Computer use panel is active.

The app checks the installed model's actual `tools` and `vision` capabilities. A model without tool support cannot start; a model without vision uses structured accessibility observations. No model is automatically downloaded or sent to a cloud provider.

## Implemented controls

- `computer_observe`: bounded accessibility metadata plus a screenshot of the uniquely identified selected window.
- `computer_focus`: bring the selected application forward.
- `computer_click`: press an accessibility control, with a hit-tested element-center fallback when no semantic press exists.
- `computer_type`: **replace the entire value** of one editable, nonsecure text control. The approval shows the replacement text. This is not append-only typing.
- `computer_key`: a fixed set: `cmd+n`, `cmd+a`, `cmd+c`, `return`, `tab`, `escape`, arrow keys, and `backspace`.
- `computer_scroll`: up, down, left, or right; bounded amount 1–5.

Every operation except observation requires a single-use approval. No shell, Python, AppleScript, arbitrary shortcut, clipboard read, or raw coordinate tool is exposed to the model.

## Boundaries

- A session belongs to one task, one app process, and a five-minute window, with at most 30 input attempts. It ends on Stop, task completion, expiry, sleep, failure, or app-access revocation.
- Input references a fresh snapshot. Snapshots expire after 30 seconds. Changed windows, changed element identity/label/value/frame, changed text selection/caret for keyboard targets, covered coordinate targets, or focus moving to another app reject input.
- Jarvis brings its approval UI forward. After approval, the executor may return from Jarvis to the previously selected app after revalidation. It does not reclaim focus from a different app.
- Protected terminal, password, security-settings, and Finder apps are blocked. Secure accessibility fields require manual takeover. App IDs and secure-field detection are defense in depth, not a general content classifier.
- Only the selected window is captured. If it cannot be uniquely matched, capture fails rather than falling back to the full display. Custom-drawn controls without usable accessibility metadata may require manual work.
- A computer session permanently marks its conversation as containing private context. Other connector tools are unavailable during computer control. Screen previews are held in memory and cleared at the end; raw screenshots are not saved in chat or audit records. The user's task and the model's final answer can be stored in the encrypted conversation history.
- Selecting an app exposes its visible content, which can include files outside the document tools' approved folders. **The UI boundary does not enforce filesystem folder restrictions.** Connected app actions can transmit data through that app. Review targets and text before approval.
- If input was attempted but its outcome cannot be verified, the session stops with an uncertainty message. Jarvis does not automatically repeat it.

## Verification

`Tests/JarvisCoreTests/ComputerPolicyTests.swift` checks task/session ownership, expiry cleanup, stale-task cancellation, the action budget, single-use approvals and replay rejection, malformed input, backward-compatible replies, and protected/stopped native-controller behavior. These tests do not grant or simulate macOS permissions.

Run the synthetic local model probe:

```sh
python3 scripts/computer_model_probe.py
```

The report at `reports/computer-model-probe.json` records tool-call selection, screen-instruction refusal, vision reading, and latency. It uses synthetic data only and never executes proposed input. A passing report is a smoke test, not an end-to-end or adversarial-security benchmark.

### Live acceptance checklist

- Start from a blank TextEdit document and use the provided example. Approve the document/text actions and confirm `Jarvis computer-use test` appears. Leave the document unsaved.
- Decline a proposed action: confirm it does not run and control ends.
- Wait more than 30 seconds before approving: confirm stale input is rejected.
- Switch to a different app before an action: confirm no input lands there.
- Change or close the target window while the model thinks: confirm stale targets are rejected.
- Press Control–Option–Escape during planning and while approval is pending: confirm no later input executes.
- Present an unexpected dialog or secure field: confirm manual takeover or a stopped session, never a guessed action.
- Review the selected-window preview and verify no unrelated window appears.

Live success must be recorded separately from build, policy-test, and synthetic model-probe results.

## Developer notes

The signed XPC broker owns `NativeComputerController`, session policy, approval checks, and audit metadata. The main app owns selected-window capture via `ComputerWindowCapture`, because its Screen Recording permission is not reliably inherited by XPC helpers. Capture accepts only the broker observation and selected bundle ID, validates the PID, focused-window bounds and secure-field state, and never falls back to full-display capture. SwiftUI owns permission guidance, task setup, model-loop presentation, and cancellation. The model loop exposes only the computer catalog, one call per response, bounded context, and the latest screenshot.

Use the existing build script and stable signing identity so macOS permission identity survives rebuilding:

```sh
JARVIS_SIGNING_IDENTITY='Jarvis Local Signing' ./scripts/build.sh
```

`JARVIS_SWIFT_SDK` optionally selects an installed SDK. This host's Xcode license prompt was left unchanged; the installed Command Line Tools and macOS 26.5 SDK were used for validation. No license was accepted programmatically.
