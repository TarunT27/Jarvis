#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
swift build -c release
APP="$PROJECT_DIR/Jarvis.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/XPCServices/JarvisBroker.xpc/Contents/MacOS"
cp .build/release/Jarvis "$APP/Contents/MacOS/Jarvis"
cp .build/release/JarvisBroker "$APP/Contents/XPCServices/JarvisBroker.xpc/Contents/MacOS/JarvisBroker"
mkdir -p "$APP/Contents/Resources/Fonts"
cp Resources/Fonts/*.otf "$APP/Contents/Resources/Fonts/"
PROJECT_DIR="$PROJECT_DIR" /usr/bin/python3 - <<'PY'
import os,plistlib,pathlib
root=pathlib.Path(os.environ['PROJECT_DIR']);app=root/'Jarvis.app/Contents'
plist={'CFBundleIdentifier':'local.jarvis.mac','CFBundleName':'Jarvis','CFBundleDisplayName':'Jarvis','CFBundleExecutable':'Jarvis','CFBundlePackageType':'APPL','CFBundleShortVersionString':'0.1.0','CFBundleVersion':'1','LSMinimumSystemVersion':'15.0','NSHighResolutionCapable':True,'NSMicrophoneUsageDescription':'Record speech only while you hold the push-to-talk shortcut. Audio stays on your Mac.','NSScreenCaptureUsageDescription':'Attach the screen to a local question when you request it.','NSRemindersFullAccessUsageDescription':'Create reminders only after you approve the exact details.','JarvisProjectRoot':str(root)}
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
# An ad-hoc signature changes its cdhash on every rebuild, and macOS keys both TCC grants
# and Keychain ACLs to the code identity - so each rebuild looks like a brand new app and
# re-asks for the microphone and the Keychain password. A stable self-signed identity fixes
# both. Use one when it exists; otherwise fall back to ad-hoc so the build never breaks.
IDENTITY="${JARVIS_SIGNING_IDENTITY:-Jarvis Local Signing}"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    SIGN_AS="$IDENTITY"
    printf 'Signing with stable identity: %s\n' "$IDENTITY"
else
    SIGN_AS="-"
    printf 'Signing ad-hoc (no "%s" identity found). Microphone and Keychain approval will be asked again after each rebuild.\n' "$IDENTITY"
fi
# The broker never records; it stays without the microphone entitlement.
codesign --force --sign "$SIGN_AS" --options runtime "$APP/Contents/XPCServices/JarvisBroker.xpc"
codesign --force --sign "$SIGN_AS" --options runtime --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --deep --strict "$APP"
printf 'Built %s\n' "$APP"
