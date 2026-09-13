#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
swift build -c release
APP="$PROJECT_DIR/Jarvis.app"
# Replacing the executable of a RUNNING app kills it with SIGKILL (Code Signature
# Invalid): the kernel validates each code page against the signature of the file
# backing it, and overwriting that file invalidates every page not yet resident. The
# process dies at its next page-in, with a crash report that looks like a memory bug
# in whatever happened to be on screen. Stop it first.
if pgrep -f "$APP/Contents/MacOS/Jarvis" >/dev/null 2>&1; then
    printf 'Quitting the running Jarvis before replacing its binary.\n'
    osascript -e 'quit app id "local.jarvis.mac"' >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -f "$APP/Contents/MacOS/Jarvis" >/dev/null 2>&1 || break
        sleep 0.3
    done
    pkill -f "$APP/Contents/MacOS/Jarvis" >/dev/null 2>&1 || true
    sleep 0.3
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/XPCServices/JarvisBroker.xpc/Contents/MacOS"
cp .build/release/Jarvis "$APP/Contents/MacOS/Jarvis"
cp .build/release/JarvisBroker "$APP/Contents/XPCServices/JarvisBroker.xpc/Contents/MacOS/JarvisBroker"
mkdir -p "$APP/Contents/Resources/Fonts"
cp Resources/Fonts/*.otf "$APP/Contents/Resources/Fonts/"
PROJECT_DIR="$PROJECT_DIR" /usr/bin/python3 - <<'PY'
import os,plistlib,pathlib
root=pathlib.Path(os.environ['PROJECT_DIR']);app=root/'Jarvis.app/Contents'
plist={'CFBundleIdentifier':'local.jarvis.mac','CFBundleName':'Jarvis','CFBundleDisplayName':'Jarvis','CFBundleExecutable':'Jarvis','CFBundlePackageType':'APPL','CFBundleShortVersionString':'0.1.0','CFBundleVersion':'1','LSMinimumSystemVersion':'26.0','NSHighResolutionCapable':True,'NSMicrophoneUsageDescription':'Record speech only while you have started a recording. Audio stays on your Mac.','NSScreenCaptureUsageDescription':'Attach the screen to a local question when you request it.','NSRemindersFullAccessUsageDescription':'Create reminders only after you approve the exact details.','JarvisProjectRoot':str(root)}
(app/'Info.plist').write_bytes(plistlib.dumps(plist))
helper={'CFBundleIdentifier':'local.jarvis.mac.broker','CFBundleName':'JarvisBroker','CFBundleExecutable':'JarvisBroker','CFBundlePackageType':'XPC!','CFBundleVersion':'1','NSRemindersFullAccessUsageDescription':'Create reminders only after you approve the exact details.','XPCService':{'ServiceType':'Application','RunLoopType':'NSRunLoop'}}
(app/'XPCServices/JarvisBroker.xpc/Contents/Info.plist').write_bytes(plistlib.dumps(helper))
PY
# Hardened Runtime (--options runtime) blocks microphone access unless the app carries
# com.apple.security.device.audio-input. Without it macOS refuses at the runtime layer
# before TCC is ever consulted, so no prompt appears and the app never shows up in
# System Settings > Privacy & Security > Microphone. This is a hardened-runtime
# entitlement, not a provisioning-profile one, so an ad-hoc signature can carry it.
ENTITLEMENTS="$PROJECT_DIR/.build/jarvis.entitlements"
cat > "$ENTITLEMENTS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key>
    <true/>
</dict>
</plist>
PLIST
# An ad-hoc signature's designated requirement is nothing but its cdhash:
#     designated => cdhash H"0a7131c2..."
# macOS keys TCC grants and Keychain ACLs to that requirement, so any change to the binary
# produces a new hash, and the microphone permission and Keychain approval are both asked
# for again. A real signing identity makes the requirement identifier-plus-certificate
# based instead, which survives rebuilds.
#
# Prefer an Apple Development certificate (free with any Apple ID, via Xcode > Settings >
# Accounts > Manage Certificates), then any self-signed identity named below. Falls back to
# ad-hoc so the build never breaks. Override with JARVIS_SIGNING_IDENTITY.
pick_identity() {
    if [ -n "${JARVIS_SIGNING_IDENTITY:-}" ]; then printf '%s' "$JARVIS_SIGNING_IDENTITY"; return; fi
    local available
    available="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    for candidate in "Apple Development" "Developer ID Application" "Jarvis Local Signing"; do
        if printf '%s' "$available" | grep -q "$candidate"; then printf '%s' "$candidate"; return; fi
    done
    printf '%s' "-"
}
SIGN_AS="$(pick_identity)"
if [ "$SIGN_AS" = "-" ]; then
    printf 'Signing ad-hoc: no code-signing identity found.\n'
    printf '  The microphone permission and Keychain approval will be asked for again after\n'
    printf '  any rebuild that changes the binary. Run ./scripts/check-signing-identity.sh\n'
    printf '  to see how to create one.\n'
else
    printf 'Signing with stable identity: %s\n' "$SIGN_AS"
fi
# The broker never records; it stays without the microphone entitlement.
codesign --force --sign "$SIGN_AS" --options runtime "$APP/Contents/XPCServices/JarvisBroker.xpc"
codesign --force --sign "$SIGN_AS" --options runtime --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --deep --strict "$APP"
printf 'Built %s\n' "$APP"
