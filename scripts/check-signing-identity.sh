#!/bin/bash
# Reports whether Jarvis has a code-signing identity that will keep its macOS permissions
# across rebuilds, and how to create one if not.
#
# Why it matters. An ad-hoc signature (codesign -s -) has a designated requirement that is
# only its own hash:
#     designated => cdhash H"0a7131c2..."
# macOS keys both TCC grants (microphone, screen recording) and Keychain ACLs to that
# requirement. Change one line of Swift, rebuild, and the hash changes - so macOS sees a
# different application, re-asks for the microphone, and asks for your login password
# again because the vault key's ACL no longer matches the app requesting it.
#
# A real identity produces an identifier-and-certificate requirement instead, which is
# stable across rebuilds. Approve once, not once per build.
#
# Creating one is deliberately left to you: it changes your login keychain, and both routes
# below need your authorisation. A certificate imported from the command line does NOT work
# - it lands untrusted, `security find-identity -v -p codesigning` does not list it, and
# codesign reports "no identity found". Both routes below avoid that.
set -euo pipefail

FOUND="$(security find-identity -v -p codesigning 2>/dev/null | grep -cE "Apple Development|Developer ID Application|Jarvis Local Signing" || true)"

if [ "${FOUND:-0}" -gt 0 ]; then
    printf 'A usable code-signing identity is present:\n\n'
    security find-identity -v -p codesigning | grep -E "Apple Development|Developer ID Application|Jarvis Local Signing"
    printf '\nscripts/build.sh will use it automatically.\n'
    printf 'Permissions granted after the next build will persist across later rebuilds.\n'
    exit 0
fi

cat <<'TEXT'
No code-signing identity found. Jarvis is being signed ad-hoc, so the microphone
permission and the Keychain password will be asked for again after any rebuild that
changes the binary.

Two ways to fix it. Both need a few clicks from you; neither can be scripted safely.

  Option A - Apple Development certificate (recommended, free, ~2 minutes)
    Works with any Apple ID; no paid developer account needed. It is also the path
    towards notarisation later, if Jarvis ever leaves this Mac.

      1. Xcode > Settings > Accounts
      2. Add your Apple ID if it is not listed
      3. Select it, click "Manage Certificates..."
      4. Click "+" and choose "Apple Development"

  Option B - self-signed certificate via Keychain Access
    Stays entirely local. Use the assistant, not the command line: a CLI-imported
    self-signed certificate is untrusted and codesign refuses it.

      1. Keychain Access > Certificate Assistant > Create a Certificate...
      2. Name: Jarvis Local Signing
      3. Identity Type: Self Signed Root
      4. Certificate Type: Code Signing
      5. Create, then confirm it appears in the login keychain

Then:
      ./scripts/check-signing-identity.sh     # confirm it is recognised
      ./scripts/build.sh                      # picks it up automatically

Approve the microphone once more after that build. From then on it sticks.
TEXT
exit 1
