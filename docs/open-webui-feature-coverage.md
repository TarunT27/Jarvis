# Open WebUI-inspired native functionality

Reviewed 2026-09-12 against [Open WebUI](https://github.com/open-webui/open-webui), reference commit `0a7c15832fb30b1903753e83f81dc7d27e5b0944`. Inspected its README, license/history, and note/prompt models. The read-only checkout is at `../../work/open-webui-reference`.

This is the first implementation increment, **not complete feature parity**. The user confirmed local-only inference, one user, and approved tools. Existing native UI direction is preserved; a visual walkthrough is deferred at the user's request.

## Implemented in this increment

- **Notes and reusable prompts:** Notes & prompts in the sidebar and Go menu. Create, edit, search, delete; encrypted storage and search index. User-driven changes use dedicated authenticated XPC operations. Up to 500 items, 160-byte titles, 32 KB bodies. Save a chat message as a note from its context menu.
- **Local note attachments:** Attach up to three notes totalling 16 KB; inspect/remove attachment chips before sending. The attachment is a snapshot for that request, not a persistent automatic knowledge subscription. It is excluded from external search. Deleting a note clears its saved/indexed copy and any pending attachment; existing quotations in chat history remain until chat history is cleared.
- **Prompt variables:** `{{date}}`, `{{time}}`, `{{timezone}}` expand locally. The expanded prompt is inserted into the composer, never automatically sent. Prompts cannot execute code, read clipboard/files, change policy, or grant permissions.
- **Response controls:** Session-only creativity 0–1 and response limit 128–2048 tokens. Fixed 8K context and existing single-model loading remain enforced. Deep mode retains its installed-model and external-power requirements.
- **Generation statistics:** Persist optional output token count and generation rate on assistant messages. Measurements describe the final model call, not an entire multi-tool turn or speech latency. Missing metrics stay absent. The client now rejects streams lacking a completion marker before executing collected tools. Field units follow [Ollama's chat API](https://docs.ollama.com/api/chat).
- **Markdown subset:** Inline formatting/links, headings, fenced code blocks and Copy code. No HTML execution, remote image loading, rendered artifacts, or code execution. Tables and LaTeX are not rendered.
- **Conversation export:** Current chat as versioned Jarvis JSON or Markdown using a native save dialog. The user chooses where to write an explicitly unencrypted export. This is not an Open WebUI-compatible import/export format.
- **Privacy persistence:** The broker stores private-conversation markers durably in the encrypted vault. They survive restarts and in-memory ledger eviction. Legacy messages with unknown provenance are treated conservatively. Exact-ID database reads avoid pagination errors. Generic app record reads cannot retrieve credentials/settings. A new response setting excludes saved memories for new public-search conversations; this does not clear existing private-conversation markers.
- **Memory approval result:** The model now receives an explicit saved/declined result for the app's direct “remember” path; failed approvals are no longer silently reported as successes by that path. Model wording still needs live verification.

## Coverage and remaining work

Feature groups below come from the [README's key features](https://github.com/open-webui/open-webui#key-features-of-open-webui-). Status describes Jarvis, not upstream equivalence.

| Feature group | Jarvis status / remaining work |
| --- | --- |
| Setup | Existing native build/runtime; polished first-run installer and dependency provisioning remain. |
| Local models | Existing two configured models; response controls added. General model catalog/download management remains. |
| Presets | Reusable prompts added; agent profiles with per-profile tools/knowledge remain. |
| Notes | Encrypted plain-text/Markdown-source notes added; rich editing and selection rewrite remain. |
| Memory | Existing explicit memories preserved; review/edit sophistication remains. |
| Workflow queues | Not implemented. Needs conversation-bound queue and cancellation tests. |
| Calendar | Existing approved Google event writes and Apple Reminders; recurrence editor remains. |
| Scheduled prompts | Not implemented. Needs a wake/sleep-aware scheduler with no unattended consequential actions. |
| Voice/video | Existing local push-to-talk and English speech; hands-free mode and video remain. |
| Markdown/LaTeX | Markdown subset added; math and table rendering remain. |
| Artifacts | Save output as notes; interactive artifact rendering/storage API remains. |
| Document retrieval | Existing approved-folder PDF/text/Markdown extraction and lexical search. Vector embeddings/reranking and knowledge collections remain. |
| Web | Existing Brave search preserved. Safe direct URL fetch and additional providers remain. |
| Images | Existing on-demand screen questions; local generation/editing backend remains. |
| Multiple models | Existing sequential model switching. Side-by-side comparison remains subject to memory budgets. |
| Analytics/evaluation | Per-answer measurements added; aggregate usage and evaluation workflow remain. |
| Tool extensions | Existing fixed broker catalog. Declarative adapters for reviewed tools remain; unrestricted plugins/code are excluded. |
| External storage | Existing Gmail/Calendar. Selected Drive document import remains; cloud conversation storage excluded. |
| Localization | Existing transcription language choice; app string localization remains. |
| Team channels, roles, SSO | Excluded by confirmed single-user scope. |
| PWA/server scaling | Excluded: native Mac application, no browser/server replacement. |
| Cloud inference | Excluded by confirmed local-only scope. |
| Telemetry | Remote telemetry excluded; local diagnostics can be expanded. |

Next implementation work should address model/setup management, retrieval/attachments, and conversation workflows before scheduler or image-backend integrations. Those need their own lifecycle and resource validation; no stubs are presented as working features.

## Architecture and licensing

These features are independently implemented in Swift. No upstream Python, Svelte, assets, dependencies, or executable plugin code was copied into Jarvis or bundled. The reference checkout is not a runtime dependency. Upstream's [license](https://github.com/open-webui/open-webui/blob/main/LICENSE) and [license history](https://github.com/open-webui/open-webui/blob/main/LICENSE_HISTORY) were reviewed before choosing this approach. Any later direct reuse needs a component-specific license review.

No cloud AI endpoint, arbitrary shell tool, new network listener, external telemetry, or background microphone capture was introduced. XPC code identity checks, encrypted vault, existing tool arguments/approvals, root restrictions and outgoing-action handling remain in place. No commits were made.
