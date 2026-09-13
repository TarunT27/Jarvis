# Quiet Workspace — native app integration

Integrated the approved dark mockup into the existing SwiftUI app. No web dependencies, commits, model downloads, account connections, or permission policy changes.

## Source files changed

- `Sources/JarvisApp/JarvisTheme.swift` — new palette, root dark appearance and native macOS 26 Liquid Glass composer modifier; solid Reduce Transparency fallback and stronger Increase Contrast border.
- `Sources/JarvisApp/ChatView.swift` — extracted and redesigned Chat with project/conversation heading, readable messages, floating composer, actual model menu, voice controls, mute, screen attachment menu, persistent status, Stop, and accessible sender labels. Larger scaled typography follows the approved mockup.
- `Sources/JarvisApp/JarvisApp.swift` — sidebar spacing and branding, dark theme integration, larger default window and themed exact-action approval sheet. Existing navigation, search, recent chats, projects and account menu retained.
- `Sources/JarvisApp/Assistant.swift` — initial page changed from Overview to Chat. No controller or broker behavior changed.
- `Sources/JarvisApp/Typography.swift` — uses the native system font through the existing shared font interface.
- `Sources/JarvisApp/OverviewView.swift` — matching background/accent and numeric text transitions that respect Reduce Motion.
- `Sources/JarvisApp/OrganizationViews.swift` — matching icon accent.

Pre-existing changes to Package.swift, scripts/build.sh, scripts/tool_benchmark.py, STATUS.md, benchmark output and .swiftpm were preserved. Original source copies and the pre-edit diff are in the repository's `work/dark-integration-before/`.

## Commands and results

Run from the native project:

```sh
swift build
swift test
JARVIS_SIGNING_IDENTITY="Jarvis Local Signing" ./scripts/build.sh
codesign --verify --deep --strict Jarvis.app
git diff --check
```

Final source build passed. Final test run: **37 tests, 0 failures** (September 11, 2026, 20:32 EDT), including the existing security/privacy tests. The previous signed integration build passed strict signature verification and retained the existing Jarvis Local Signing identity. Final typography-only packaging is waiting for macOS key-access authorization; final relaunch is pending.

## Runtime checks completed

On the signed integration build before the last typography adjustment:

- Native app relaunched, unlocked through the existing authentication flow and restored history.
- Local chat returned exactly: “The new Jarvis workspace is ready.”
- Status remained visible while generation was busy with spoken replies muted.
- Model menu switched to Deep and back to Everyday; label and accessibility values followed selection. No Deep inference was started.
- Exact memory proposal appeared in the existing non-dismissible approval sheet. Declined the proposal; Memory remained “Nothing saved yet.” The model's subsequent conversational claim to remember was not evidence of a save; the store check confirmed no memory was written.
- Escape stopped active local generation and restored the model menu to its idle enabled state.
- Sidebar collapsed and expanded; window widths approximately 851–1246 points remained usable with all composer controls visible.
- Opened Memory, Connections, Settings and Overview. Settings kept the existing voice/shortcut/resource and access controls. Overview switched to 90 days with actual data.
- Accessibility tree exposed distinct control identifiers, local model value, sender containers, Start/Finish recording actions, mute and Stop controls.
- No crash observed during these checks. The microphone was idle. Existing push-to-talk press/release callbacks and the voice engine were retained.

## Limits

This integrates the visual design with actual application data. The fictional calendar event, model-size badge and sample projects from the mockup were not inserted. Consequential actions continue to use the real approval sheet. Native Liquid Glass is rendered by macOS and has subtler optical highlights than the generated image.

Full VoiceOver audio, reduced-transparency/contrast settings, RTL, large accessibility text, and speech recognition/latency benchmarks were not manually retested. The relevant accessibility fallbacks were reviewed in code. Three harmless UI-test requests remain in encrypted history; no existing history was deleted. Everyday mode and spoken replies were restored after testing.

Apple API reference: [glassEffect(_:in:)](https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:)).
