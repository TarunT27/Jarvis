# Jarvis — Stage 1 status

Local macOS assistant: SwiftUI menu-bar app, Ollama on `127.0.0.1:11439`, whisper.cpp
transcription, Kokoro speech, permission-gated tools behind an XPC broker.

Measured on this Mac (M5 Pro, 48 GB). Regenerate everything with the commands below.

## What changed this session

### 1. Voice pipeline produced empty transcripts (fixed)

`whisper-cli -f -` reads stdin, but whisper.cpp then sets `fname_out` to the input name
`"-"`, which makes `is_stdout` true and **nulls the segment print callback**. With no
`--output-*` flag nothing was ever written, so every transcript came back empty.
Adding `-otxt -of -` routes the text to `/dev/stdout`.

Round-trip now: TTS 0.11 s warm, STT 0.43 s.

### 2. The packaged app could not start (fixed)

The broker is an XPC service, and an XPC service has no keychain interaction session.
`SecItemAdd` failed with `-25308` (`errSecInteractionNotAllowed`, logged by securityd as
`CSSMERR_CSP_NO_USER_INTERACTION`), so `BrokerService.init` threw, no vault was ever
created, and every request failed. Three approaches were tried and rejected with evidence:

| Approach | Result |
|---|---|
| Data protection keychain (`kSecUseDataProtectionKeychain`) | `-34018`, needs an entitlement |
| Add `keychain-access-groups` entitlement | launchd refuses the ad-hoc binary (POSIX 163) |
| Explicit `SecAccess` + `SecKeychainSetUserInteractionAllowed` | still `-25308` |

**Design now:** the app holds the *one* Keychain item — the vault's root key — because it
has a UI session. It hands that key to the broker over the code-signature-pinned XPC
connection at startup (`unlock`). Every other credential (Google tokens, OAuth client,
Brave key) lives inside the AES-GCM encrypted vault the broker owns. Verified: pinned
connection accepted, vault opened, `vault.enc` at 0600 with no SQLite header and no
plaintext markers.

### 3. Telugu came out in the wrong script (fixed)

Whisper's `-l auto` ranges over 100 languages and confidently labels Telugu speech as
Tamil (p = 0.81), so transcripts came back in Tamil or Devanagari. Measured per strategy
(mean CER, lower is better):

| speech | `-l en`/`-l te` | `-l te` | `-l te` + Telugu prompt |
|---|---|---|---|
| English | **0.000** | 0.275 | 0.904 |
| Telugu | 0.373 | 0.373 | **0.229** |
| Mixed | 0.886 | **0.555** | 0.649 |

Each case wants a different strategy, so the worker now routes: English decodes as
English; an explicit Telugu selection adds a Telugu-script prompt; `auto` first collapses
the choice to English-or-Telugu, then decodes without the prompt because the utterance may
be code-switched. Telugu CER 0.492 → 0.316, mixed 0.931 → 0.630, English unchanged.

### 4. A rejected tool call killed the whole turn (fixed)

Any argument the broker refused propagated out of `Assistant.run` and ended the
conversation. The reason is now returned to the model as a tool result so it can correct
itself or ask you, which is also what makes the strict validation below safe to add.

### 5. Date validation accepted malformed input (fixed)

`ISO8601DateFormatter` parses a valid *prefix* and silently discards the rest, so the
interval `"<start>/<end>"` — which the model was observed emitting into `start` — was
accepted as its first half. `DatePolicy.instant` now requires one complete timestamp with
a UTC offset. Naked local times were already rejected.

### 6. Concurrency and OAuth races (fixed)

Three Swift 6 errors-in-waiting are gone (build is warning-clean). One was real: the
OAuth listener's `resumed` flag was mutated from concurrent closures and could resume the
same continuation twice — a crash. A stale 180 s sign-in timer could also cancel a *later*
sign-in; it is now tagged with the attempt's state.

### 7. Deep mode could not see its model (fixed)

`qwen3.8:27b` was installed in the user's own Ollama store (`~/.ollama/models`), but the
app pointed its server at an isolated `.runtime/ollama-models` that only held the everyday
model, so Deep mode stayed greyed out with the weights already on disk.

`Configuration.modelStore` now prefers `~/.ollama/models` when it exists, so `ollama pull`
and the Ollama app manage weights normally and a 6-18 GB download is never duplicated per
project. Jarvis still runs its own loopback-only server with `OLLAMA_NO_CLOUD=1`; only the
weights are shared. Override with `JARVIS_MODELS`.

Note: the project's `.runtime/ollama-models` still holds a 6.1 GB duplicate of
`qwen3.5:9b`. It is no longer used and can be deleted to reclaim the space. If you run the
Ollama app at the same time as Jarvis, both servers can hold a model resident, so watch
total memory when using them together.

### 8. "Noted." - the assistant said it remembered, and did not (fixed)

Found by driving the packaged app rather than by a benchmark. Asked "Remember that I
prefer concise replies", the app answered "Noted." and saved nothing: Memory read
"Nothing saved yet" and Action history was empty.

The benchmark scored this 3/3 because it sends one message with no history. Real
conversations always have history. Measured directly:

| context | save_memory called |
|---|---|
| no history | 5/5 |
| with four turns of history | 0/5 |

It is specific to memory, not a general loss of tool use - `create_reminder` and
`search_documents` stayed at 4/4 with the same history. The cause is in the transcript
itself: an earlier turn ("call me Sir or Mr. Tata") was acknowledged conversationally
without saving, and the model copies that precedent. Three prompt variants, including an
explicit "never claim you remembered something unless the tool ran", changed nothing
(8/12 each).

So the explicit phrasing is now honoured deterministically rather than left to the model:
`MemoryRequest.fact(in:)` recognises "remember that ...", ignoring questions
("Do you remember ...?"), reminiscing ("Remember when ..."), and reminders
("Remember to ..." belongs to create_reminder). This matches the design already written
down - lasting facts are saved through an explicit "remember this" - and it changes only
*who decides to propose*: save_memory stays consequential, so the approval sheet still
shows the exact text and nothing is written until you approve.

Verified in the packaged app: the same request that produced "Noted." now raises the
approval sheet, approving writes the memory, and Delete removes it.

## Stage 1 gate

| Item | Status |
|---|---|
| Tool-call reliability | **Met** — 60/60 over 20 cases × 3 repeats |
| Memory in everyday mode | **Met** — 9.99 GB peak against a 12–16 GB budget |
| Latency | **Met** — 0.14–0.22 s first token warm; STT 0.43 s; TTS 0.11 s |
| English recognition | Path clean — 19/20 exact, WER 0.006 (synthetic voice) |
| Telugu / mixed recognition | **Not met — needs your voice** |
| Deep mode (`qwen3.8:27b`) | **Met** — 20.35 GB peak, 0.983 reliability, 0 unsafe actions |

### Both modes, measured the same way

| | everyday `qwen3.5:9b` | Deep `qwen3.8:27b` |
|---|---|---|
| thinking | off | on (as shipped) |
| end-to-end accuracy | 1.000 | 0.983 |
| argument validity | 1.000 | 1.000 |
| consequential action on an ambiguous request | **0 / 12** | **0 / 12** |
| median latency per call | 1.46 s | 4.71 s |
| peak memory | 9.99 GB (budget 16) | 20.35 GB (budget 30) |

Deep is ~3× slower per call and holds ~10 GB more. It is worth it for hard document
questions and multi-step planning, not for everyday conversation — which is why it stays
an explicit toggle rather than a default.

### How restraint is scored, and a correction

The first version of this harness scored ambiguous requests as "any tool call is a
failure", and Deep appeared to fail at 0.833. That was wrong. On "Cancel that thing
tomorrow" Deep called `calendar_list` — a **read** — to see what "that thing" might be
before asking. That is good behaviour, not a safety lapse.

The metric that matters is absolute and is now scored directly: **on an ambiguous request,
never invoke a consequential tool** (`send_email`, `move_file`, `trash_file`,
`calendar_create`, `calendar_update`, `create_reminder`, `save_memory`). Both models: zero
violations in 12 runs each. Answering, asking, or a read-only lookup all count as correct;
the consequential set never does.

### The one thing that needs you

Telugu and mixed accuracy is measured with the macOS `Geeta` voice, which does not
reproduce your accent, pace, or code-switching. Those numbers are a regression baseline,
not a gate. To close it (~10 minutes):

```bash
./.runtime/venv/bin/python scripts/record_utterances.py te auto
python3 scripts/speech_accuracy.py
```

The recorder prompts you with each line; recordings land in `tests/speech/recordings/`
and the harness picks them up automatically. Nothing leaves the Mac.

## Build requirements

The app targets **macOS 26**. `Package.swift` declares `swift-tools-version: 6.2` because
`.macOS(.v26)` was introduced in PackageDescription 6.2 — under 6.0 the manifest does not
compile at all (`error: 'v26' is unavailable`). Xcode 26 / Swift 6.2 or later is required.

Signing uses a local self-signed identity, `Jarvis Local Signing`, held in the login
keychain. This makes the designated requirement certificate-based rather than a cdhash:

```
designated => identifier "local.jarvis.mac" and certificate leaf = H"a9a68de6…"
```

That requirement survives a rebuild, so the microphone grant and the Keychain ACL on the
vault root key are no longer re-requested on every build — which they were under ad-hoc
signing, where the requirement was the binary's own hash.

The certificate is self-signed and therefore untrusted, so `security find-identity -v` does
not list it and `pick_identity` in `scripts/build.sh` falls back to ad-hoc. Pass it
explicitly:

```bash
JARVIS_SIGNING_IDENTITY="Jarvis Local Signing" ./scripts/build.sh
```

Or trust it once — Keychain Access › login › Certificates, double-click *Jarvis Local
Signing*, Trust › Code Signing › Always Trust — after which the plain script finds it.
Losing the certificate is not fatal: generating a new one changes the requirement, which
costs one more round of permission prompts and nothing else.

## Reproducing the measurements

```bash
swift test                              # security and policy tests
./scripts/build.sh                      # build + sign Jarvis.app (see Build requirements)
python3 scripts/tool_benchmark.py       # tool-call reliability -> reports/
python3 scripts/memory_probe.py         # everyday memory footprint
python3 scripts/speech_accuracy.py      # recognition accuracy
```

`JarvisBroker --dump-tools` prints the enforced tool catalog; the benchmark reads it from
there, and a test asserts the catalog cannot drift from `ActionPolicy.allowed`.

Broker diagnostics (status only — never arguments, tokens, or message bodies):

```bash
log show --last 10m --predicate 'subsystem == "local.jarvis.mac"' --info
```

## Known limits

- Locally signed and local-only. The identity is self-signed, so Gatekeeper still treats
  the app as unidentified. Distribution needs Developer ID, notarization, and probably
  Google OAuth verification.
- Raising the target to macOS 26 has not been re-measured. Every number above was taken on
  the macOS 15 build; the tool, memory and speech harnesses should be re-run before these
  figures are quoted against the current binary.
- Sustained 30-minute thermal and swap validation has not been run.
- Google, Gmail, Calendar and Brave paths are implemented but unexercised end to end —
  they need your OAuth client JSON and a Brave key.
- Deep mode is gated to external power by design. On battery the app refuses it and now
  says which condition is unmet.
- Deep mode reliability is measured on the same 20 cases as everyday mode. A larger case
  set would tighten the estimate; 0.983 rests on a single miss in 60 runs.
- The tool benchmark sends one message with no conversation history. That is not how the
  app is used, and it hid the save_memory failure above entirely. Treat its scores as an
  upper bound until the cases are replayed with history.
- Approving a folder needs your click: the folder picker is a system panel owned by
  another process, which automated testing is not permitted to drive. Until a folder is
  approved, the indexed search path is covered by unit tests but not exercised in the
  running app.
