# Native workspace feature validation — 2026-09-12

Scope: first Open WebUI-inspired feature increment. See `../docs/open-webui-feature-coverage.md` for coverage and explicit gaps.

## Commands and results

- `git status --short` — inspected existing dirty tree before editing; unrelated changes preserved.
- `git clone --depth 1 --filter=blob:none --sparse https://github.com/open-webui/open-webui.git ../../work/open-webui-reference` — read-only research checkout.
- `git -C ../../work/open-webui-reference sparse-checkout set backend/open_webui/models backend/open_webui/routers` — inspected note/prompt schemas; no upstream source copied into app.
- `swift build > reports/workspace-build.log 2>&1` — passed after fixing compile errors; final log retained.
- `swift test > reports/workspace-tests.log 2>&1` — 46 XCTest cases passed, including 9 new tests. Existing approval, path, credentials, document, privacy, memory, and activity tests passed.
- `JARVIS_SIGNING_IDENTITY='Jarvis Local Signing' ./scripts/build.sh > reports/workspace-package.log 2>&1` — passed; app and broker signed with the existing stable identity.
- `codesign --verify --deep --strict Jarvis.app` — passed.
- `git diff --check` — passed.

The script rebuilds the exact requested `Jarvis.app` path. The previous bundle and pre-edit versions of overlapping source files were preserved in `../../work/open-webui-before/`.

## Files changed in this increment

New:
- `Sources/JarvisCore/Workspace.swift` — bounded workspace types/storage, durable conversation privacy, generation settings/statistics, versioned export.
- `Sources/JarvisCore/MessageMarkdown.swift` — inert Markdown block parser.
- `Sources/JarvisApp/WorkspaceView.swift` — native workspace editor/list and response settings.
- `Sources/JarvisApp/MessageMarkdownView.swift` — native Markdown/code presentation.
- `Tests/JarvisCoreTests/WorkspaceTests.swift` — 9 regression tests.
- `docs/open-webui-feature-coverage.md` — scope, status, provenance, next work.
- `reports/workspace-validation.md` and `reports/workspace-{build,tests,package}.log` — validation evidence.

Modified:
- `Sources/JarvisCore/Types.swift` — optional backward-compatible chat metadata.
- `Sources/JarvisCore/ModelClient.swift` — bounded options, metrics, completion gate.
- `Sources/JarvisCore/Vault.swift` — exact-ID filtering and SQLite read-error handling.
- `Sources/JarvisBroker/BrokerService.swift` — workspace operations, record allowlist, persistent privacy checks.
- `Sources/JarvisApp/Assistant.swift` — workspace lifecycle, attachments, exports, private context, memory outcome.
- `Sources/JarvisApp/AppNavigation.swift` — workspace Go menu entry.
- `Sources/JarvisApp/JarvisApp.swift` — workspace sidebar and destination.
- `Sources/JarvisApp/ChatView.swift` — attachment controls, response controls, export, save-as-note, metrics and Markdown.

Other pre-existing changes in git status are not part of this feature increment.

## Validation limits

No live microphone, Gmail sending, Calendar writing, or model downloads were triggered. Tests use isolated temporary encrypted vaults, not the user's data. UI walkthrough and accessibility inspection are deferred per the latest request. New controls have semantic labels, native keyboard controls and explicit editor save/cancel, but this is code review, not a VoiceOver certification.

Core tests exercise encrypted reopen/update/delete, derived-index cleanup, credential namespace isolation, invalid/oversized data rejection, predictable prompt expansion, privacy persistence, generation bounds/units, legacy decoding, inert code fences and export format. They do not exercise a live authenticated XPC session or the new note-to-model flow end to end.

Important behavior change: injecting saved memories makes a conversation private. Public search requires turning off Include saved memories and starting a clean chat without private context. Old chats lacking provenance are also conservative. Privacy markers contain only conversation IDs and are retained to prevent reopened chats regaining public-search access.

Final release packaging and deep/strict signature verification passed. The installed bundle must be relaunched to use new code. Full Open WebUI parity is not complete.
