# ADR-001: A stable code-signing identity for Jarvis

**Status:** Proposed
**Date:** 2026-09-12
**Deciders:** Tarun (sole maintainer; the only action item needs his login password)

## Context

`scripts/build.sh` signs ad-hoc, because `security find-identity -v -p codesigning`
reports **0 valid identities** on this Mac. An ad-hoc signature's designated
requirement is nothing but a hash of the bytes:

```
$ codesign -d -r- Jarvis.app
# designated => cdhash H"0f10f1d0f7ee656b4f77f5c0122fe851aa63c96a"
```

macOS keys everything it grants *to an application* against that requirement. Change
one line of Swift, rebuild, and the system sees a different application:

| Bound to the designated requirement | Declared by Jarvis | Cost of a rebuild |
|---|---|---|
| TCC — microphone | `NSMicrophoneUsageDescription` | Re-request, or silent denial |
| TCC — screen capture | `NSScreenCaptureUsageDescription` | Re-request |
| TCC — Reminders | `NSRemindersFullAccessUsageDescription` | Re-request |
| Keychain ACL on `vault-key` | `Keychain.vaultKey`, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` | Login password prompt |

Measured on 2026-09-12: roughly ten rebuilds in one working session, each costing a
Touch ID or password prompt and a microphone re-grant. Twice the prompt arrived while
the app was being driven and blocked the work. Once the microphone reached a state
where `AVAudioApplication.requestRecordPermission()` never returned at all — no
prompt, no denial, no error — which made a spoken conversation impossible to test
end to end.

**Not affected:** the XPC pinning between the app and the broker.
`CodeIdentity.requirement(at:)` reads the peer's cdhash from disk *at runtime*, so it
re-derives after every build. It self-heals — but it is also trust-on-first-use: it
pins to whichever binary is sitting in the bundle, not to an identity that was
vouched for.

**Already on the machine:** a certificate named `Jarvis Local Signing` — self-signed,
RSA 2048, valid to 2036, critical `codeSigning` extended key usage, with its private
key present. It is a complete identity. It is simply not trusted:

```
$ security find-identity -p codesigning
1) A9A68DE6BD11406B3BD4CF968D03E625B2E82549 "Jarvis Local Signing" (CSSMERR_TP_NOT_TRUSTED)
```

`build.sh` already looks for that name, and for `Apple Development` and
`Developer ID Application`, before falling back to ad-hoc. No build changes are needed
by any option below.

## Decision

**Option A — trust the certificate that already exists**, in the user trust domain,
for the `codeSign` policy only. Adopt **Option B** if and when a second machine is
involved, and **Option C** only if Jarvis is ever distributed.

## Options considered

### Option A: trust the existing self-signed certificate

| Dimension | Assessment |
|---|---|
| Complexity | Low — one command, already scripted |
| Cost | Free |
| Scalability | This Mac only; a self-signed root means nothing elsewhere |
| Team familiarity | N/A (sole maintainer) |
| Time to working | Minutes |

**Pros:** the certificate, its key and the build-script support all exist already;
entirely local, no Apple account, no network; produces an identifier-and-certificate
requirement that survives every rebuild.
**Cons:** Gatekeeper on any other Mac will still reject the app; nothing here is a
step toward distribution.

### Option B: Apple Development certificate

| Dimension | Assessment |
|---|---|
| Complexity | Low-medium — Xcode > Settings > Accounts > Manage Certificates |
| Cost | Free with any Apple ID |
| Scalability | Works across your own machines and devices |
| Team familiarity | Standard Apple workflow |
| Time to working | ~2 minutes plus an Apple ID sign-in |

**Pros:** same stability as A, plus a real team identifier, and it is the first step
toward notarisation.
**Cons:** requires an Apple ID in Xcode and periodic certificate renewal; solves
nothing that A does not, for this machine.

### Option C: Developer ID + notarisation

| Dimension | Assessment |
|---|---|
| Complexity | High — paid membership, notarisation in the build, stapling |
| Cost | $99/year |
| Scalability | Runs on any Mac without a Gatekeeper warning |
| Team familiarity | Heaviest workflow |
| Time to working | Days, including Apple's enrolment |

**Pros:** the only option that lets anyone else run Jarvis normally.
**Cons:** solves a distribution problem the project does not have. `build.sh` also
writes `JarvisProjectRoot` — an absolute path into this checkout — into `Info.plist`,
so the bundle is not currently relocatable anyway. Premature.

### Option D: decouple from the signature in code

| Dimension | Assessment |
|---|---|
| Complexity | Medium |
| Cost | Free |
| Scalability | N/A |
| Team familiarity | N/A |
| Time to working | Hours |

**This option cannot work, and that is the decisive finding.** TCC grants are keyed to
the designated requirement by the system; there is no API, entitlement or plist key
that opts an application out. No amount of code change makes the microphone grant
survive a rebuild.

It could only address the Keychain half, and every way of doing so is a downgrade:
widening the item's `SecAccess` to a broader trusted-application list weakens the
"only this app opens the vault" property that `Vault.swift` is built on, and deriving
the vault key from a user passphrase instead replaces Touch ID with a secret the user
has to type and Jarvis has to handle. Both trade the app's central security claim for
developer convenience. Rejected.

### Option E: do nothing

**Pros:** no action.
**Cons:** the measured cost is already unacceptable — it blocked testing twice in one
session and left the microphone wedged once. It also makes any future report of
"the microphone stopped working" impossible to distinguish from a real defect, which
is how a genuine capture bug went unnoticed until this week.

## Trade-off analysis

A and B are the same fix with different blast radii; C is a different problem; D is
impossible for the half that matters; E has a measured cost.

The only real question is A versus B. B is strictly more capable, and if a second
machine were in play it would win outright. It is not: this is a single-machine,
local-only assistant whose bundle currently hardcodes an absolute path to this
checkout. A uses an artefact that is already sitting in the login keychain, needs no
Apple account, and is one command. Choosing B first would mean an Apple ID sign-in to
buy capability the project has no use for yet.

A is also reversible in a way C is not: deleting the trust setting returns the machine
to exactly its current state.

Worth noting as a bonus rather than a driver: with a stable identity, the app-to-broker
XPC pin could be tightened from a runtime-derived cdhash to `identifier ... and
certificate leaf = H"..."`. That would turn a trust-on-first-use check into a real
identity check — a security improvement, not just a convenience one.

## Consequences

**Easier**
- Microphone, screen capture and Reminders grants survive rebuilds; approve once
- The vault key's ACL keeps matching, so no login password per launch
- End-to-end voice testing becomes possible for the first time
- A future "the microphone broke" report means something

**Harder**
- Nothing operationally. One password prompt, once, to change trust settings

**To revisit**
- Any second machine → Option B
- Anyone else running Jarvis → Option C, and `JarvisProjectRoot` has to go first
- Tightening the XPC requirement once the identity is stable

## Action items

1. [ ] **Run `./scripts/trust-signing-identity.sh`.** This needs your login password, in
       macOS's own dialog. I cannot do it: changing certificate trust settings is
       refused to me by the sandbox, correctly.
2. [ ] `./scripts/build.sh` — it will pick the identity up automatically and print
       `Signing with stable identity: Jarvis Local Signing`
3. [ ] Approve the microphone and the Keychain prompt one final time
4. [ ] Confirm the requirement is no longer a bare hash:
       `codesign -d -r- Jarvis.app` should name the identifier and a certificate,
       not `cdhash H"..."`
5. [ ] Then: run a spoken conversation end to end, which has never been possible
6. [ ] Optional follow-up: tighten `CodeIdentity.requirement(at:)` to identifier +
       leaf certificate now that one exists
