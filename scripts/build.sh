#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
swift build -c release
APP="$PROJECT_DIR/Jarvis.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/XPCServices/JarvisBroker.xpc/Contents/MacOS"
cp .build/release/Jarvis "$APP/Contents/MacOS/Jarvis"
cp .build/release/JarvisBroker "$APP/Contents/XPCServices/JarvisBroker.xpc/Contents/MacOS/JarvisBroker"
PROJECT_DIR="$PROJECT_DIR" /usr/bin/python3 - <<'PY'
import os,plistlib,pathlib
root=pathlib.Path(os.environ['PROJECT_DIR']);app=root/'Jarvis.app/Contents'
plist={'CFBundleIdentifier':'local.jarvis.mac','CFBundleName':'Jarvis','CFBundleDisplayName':'Jarvis','CFBundleExecutable':'Jarvis','CFBundlePackageType':'APPL','CFBundleShortVersionString':'0.1.0','CFBundleVersion':'1','LSMinimumSystemVersion':'15.0','NSHighResolutionCapable':True,'NSMicrophoneUsageDescription':'Record speech only while you hold the push-to-talk shortcut. Audio stays on your Mac.','NSScreenCaptureUsageDescription':'Attach the screen to a local question when you request it.','NSRemindersFullAccessUsageDescription':'Create reminders only after you approve the exact details.','JarvisProjectRoot':str(root)}
(app/'Info.plist').write_bytes(plistlib.dumps(plist))
helper={'CFBundleIdentifier':'local.jarvis.mac.broker','CFBundleName':'JarvisBroker','CFBundleExecutable':'JarvisBroker','CFBundlePackageType':'XPC!','CFBundleVersion':'1','NSRemindersFullAccessUsageDescription':'Create reminders only after you approve the exact details.','XPCService':{'ServiceType':'Application','RunLoopType':'NSRunLoop'}}
(app/'XPCServices/JarvisBroker.xpc/Contents/Info.plist').write_bytes(plistlib.dumps(helper))
PY
codesign --force --sign - --options runtime "$APP/Contents/XPCServices/JarvisBroker.xpc"
codesign --force --sign - --options runtime "$APP"
codesign --verify --deep --strict "$APP"
printf 'Built %s\n' "$APP"
