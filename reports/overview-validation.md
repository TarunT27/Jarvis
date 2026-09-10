# Native Overview UI — validation

Validated September 10, 2026 on this Mac. Scope: the native SwiftUI Jarvis application only.

## Exact source changes

| File | Change |
| --- | --- |
| `Sources/JarvisApp/OverviewView.swift` | New adaptive native dashboard, reusable material metric cards, real 7/30/90-day Swift Charts activity, recent ChatMessage rows, empty states and accessibility descriptions. |
| `Sources/JarvisCore/ConversationActivity.swift` | Pure calendar-aware, zero-filled daily message projection; excludes future, duplicate, blank and non-conversation records. |
| `Tests/JarvisCoreTests/ConversationActivityTests.swift` | Five tests covering empty ranges, date boundaries, DST, range switching and record filtering. |
| `Sources/JarvisApp/AppNavigation.swift` | Shared sidebar/menu page metadata and native Go menu shortcuts, Control–Command–1 through 7, plus Command–comma for Settings. Reuses an existing visible main window. |
| `Sources/JarvisApp/JarvisApp.swift` | Replaces the existing draft dashboard; adds collapsible balanced NavigationSplitView integration, native navigation and New conversation control, semantic Chat typography, explicit control labels and a Copy message context menu. Existing screens retained. |
| `Sources/JarvisApp/Assistant.swift` | New conversation selects Chat before performing the existing reset. Preserves the user's pre-existing Overview default. |

Pre-existing user edits were inspected and preserved in intent. The original modified files and diff were saved under the repository's `work/overview-before/` before editing. No unrelated files were reset or deleted. No web dependencies were introduced.

## Apple interface architecture

Assistant remains the observable source of truth. Overview only projects existing state; daily aggregation is separate from presentation. Native controls, SF Symbols, semantic fonts, system colors/materials, leading/trailing alignment and Foundation date/number formatting support macOS conventions. Metric columns and chart/recent layout adapt to available width. The native sidebar toggle, keyboard menu navigation and explicit accessibility labels supplement mouse interaction. Chart transitions honor Reduce Motion.

## Commands

Run from the native project directory:

```sh
swift build
swift test
scripts/build.sh
codesign --verify --deep --strict Jarvis.app
git diff --check
```

All passed. The final XCTest run executed **37 tests with zero failures**, including the existing privacy/security suite and five new activity tests. The additional Swift Testing runner reports zero tests because these are XCTest tests. Build and release packaging completed successfully. The app and embedded XPC helper retain the build script's existing personal ad-hoc signing/Hardened Runtime configuration.

Logs: [build](overview-build.log), [tests](overview-tests.log), [packaging](overview-package.log).

## Native runtime and visual checks

- Relaunched the rebuilt `Jarvis.app` and inspected its actual rendered window and accessibility tree.
- Overview displays the configured Qwen3.5 9B model, real message counts and actual approved access (0 folders, 6 apps during testing).
- Selected 7-, 30- and 90-day chart ranges; verified selected control values, date ranges and actual counts. Empty conversation renders a zero chart and empty recent activity.
- Verified sidebar collapse/expansion; inspected narrow 850-point and wide approximately 1262-point layouts. Cards adapt from two columns to four; chart and recent activity stack or sit side by side. Scrollable content remains accessible.
- Opened Chat, Memory, Drafts, Connections, Settings and Activity. New conversation routes to Chat. Open chat preserves the current conversation.
- Sent a harmless local Chat test and received the exact requested response: “Overview check passed.”
- Requested a test memory, inspected the existing approval sheet, declined it and verified Memory remained empty. No lasting memory or outgoing action was approved.
- Verified Control–Command–2, Command–comma and Control–Command–1 navigate Chat, Settings and Overview in the same final window (`main-AppWindow-1`).
- Accessibility inspection exposed full metric values, chart summary and dated points, labeled range choices and navigation controls.
- The final signed app remained running without a crash during these checks and was left on Overview.

## Privacy and remaining limits

The dashboard adds no network calls, telemetry, audio capture, credentials or permission grants. XPC broker, encrypted storage, voice processing and approval enforcement implementations were not changed. Existing security tests pass; this UI validation is not a new exhaustive security audit or network capture.

Activity reflects the conversation currently available to Assistant, including up to 50 restored messages. Selecting 90 days does not recover expired or unloaded history. Model status describes configuration/installation, not measured model residency. Readiness reflects current application state, not a new hardware monitoring service.

Two harmless UI test exchanges remain in encrypted conversation history. No existing history was deleted. Light appearance, spoken VoiceOver, RTL languages and accessibility-size typography were not manually exercised; full translated localization is not included. Offline speech latency and performance benchmarks were not rerun for this presentation change.
