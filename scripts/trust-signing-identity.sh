#!/bin/bash
# Trusts the existing "Jarvis Local Signing" certificate for code signing.
#
# Why this exists. A certificate created by Keychain Access - or imported from the command
# line - lands in the login keychain WITHOUT trust settings. It has a private key, so it is
# a complete identity, but `security find-identity -v -p codesigning` refuses to list it:
#
#     1) A9A6...2549 "Jarvis Local Signing" (CSSMERR_TP_NOT_TRUSTED)
#
# codesign then falls back to an ad-hoc signature, whose designated requirement is nothing
# but its own cdhash. macOS keys TCC grants (microphone, screen recording) and Keychain
# ACLs to that requirement, so every rebuild looks like a brand-new application: the
# microphone is re-requested, and the vault key's ACL no longer matches, so the login
# password is asked for again.
#
# Trusting the certificate for the codeSign policy - in YOUR user trust domain only, not
# system-wide - turns it into an identifier-and-certificate requirement that survives
# rebuilds. Approve once, not once per build.
#
# macOS will ask for your login password to change trust settings. That prompt comes from
# the system; nothing here reads or stores it.
set -euo pipefail

NAME="Jarvis Local Signing"
CERT="$(mktemp -t jarvis-signing).pem"
trap 'rm -f "$CERT"' EXIT

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
    printf '"%s" is already trusted for code signing. Nothing to do.\n\n' "$NAME"
    security find-identity -v -p codesigning | grep "$NAME"
    exit 0
fi

if ! security find-certificate -c "$NAME" >/dev/null 2>&1; then
    printf 'No certificate named "%s" was found in your login keychain.\n' "$NAME"
    printf 'Create one first - see ./scripts/check-signing-identity.sh for the two routes.\n'
    exit 1
fi

security find-certificate -c "$NAME" -p > "$CERT"
printf 'Trusting "%s" for code signing (user trust domain only).\n' "$NAME"
printf 'macOS will ask for your login password.\n\n'
security add-trusted-cert -r trustRoot -p codeSign "$CERT"

printf '\nResult:\n'
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
    security find-identity -v -p codesigning | grep "$NAME"
    printf '\nNow rebuild once:\n    ./scripts/build.sh\n'
    printf 'Approve the microphone and the Keychain prompt one final time after that build.\n'
    printf 'From then on both stick across rebuilds.\n'
else
    printf 'Still not listed as valid. Check Keychain Access > "%s" > Trust >\n' "$NAME"
    printf '"Code Signing" and set it to "Always Trust".\n'
    exit 1
fi
