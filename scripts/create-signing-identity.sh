#!/bin/bash
# Creates a local, self-signed code-signing identity for Jarvis.
#
# Why this exists: an ad-hoc signature (codesign -s -) gets a new cdhash every time the
# app is rebuilt. macOS keys BOTH TCC permissions (microphone, screen recording) and
# Keychain ACLs to the code identity, so every rebuild looks like a different app:
# the microphone permission is asked for again, and the Keychain asks for your password
# again because the item's ACL no longer matches the app that is asking.
#
# A stable identity fixes both. This certificate is local, self-signed, never leaves this
# Mac, and grants nothing beyond signing your own build. It is not an Apple Developer
# certificate and does not enable distribution or notarization.
#
# You will be asked to authorise adding it to your login keychain - that is macOS asking,
# not Jarvis, and it is the only time it should ask.
#
# To undo:
#   security delete-identity -c "Jarvis Local Signing" ~/Library/Keychains/login.keychain-db
set -euo pipefail
NAME="Jarvis Local Signing"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
    printf 'Identity "%s" already exists. Nothing to do.\n' "$NAME"
    exit 0
fi

printf 'Generating a self-signed code-signing certificate...\n'
openssl req -x509 -newkey rsa:2048 -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -days 3650 -nodes -subj "/CN=$NAME" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" >/dev/null 2>&1
openssl pkcs12 -export -out "$WORK/identity.p12" -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -passout pass:jarvis -name "$NAME" >/dev/null 2>&1

printf 'Adding it to your login keychain (macOS will ask you to authorise this)...\n'
security import "$WORK/identity.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
    -P jarvis -T /usr/bin/codesign

# Lets codesign use the key without prompting on every build. macOS asks for your login
# password here; it is not read or stored by this script.
printf 'Allowing codesign to use the key (macOS will ask for your login password)...\n'
security set-key-partition-list -S apple-tool:,apple:,codesign: \
    -s -l "$NAME" "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1 || \
    printf 'Note: could not preauthorise codesign. If a prompt appears during a build, choose "Always Allow".\n'

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
    printf '\nDone. "%s" is ready.\n' "$NAME"
    printf 'Now run ./scripts/build.sh - it picks the identity up automatically.\n'
    printf 'Approve the microphone once more after that build; it will persist from then on.\n'
else
    printf '\nThe identity was not created. Jarvis still builds ad-hoc; permissions will be re-asked after each rebuild.\n'
    exit 1
fi
