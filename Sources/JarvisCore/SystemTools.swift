import Foundation
import AppKit
import CoreAudio
import AudioToolbox
import IOKit.ps
import CoreWLAN
import ApplicationServices

/// The Mac-control surface: names, argument rules, and which calls need approval.
///
/// Arguments stay strings because they travel through the same model/XPC JSON
/// contract as every other tool. Everything here is validated before it reaches
/// `SystemController`, and the broker is the only process that executes it.
public enum SystemToolCatalog {
    /// Read the Mac's state. No approval; nothing changes.
    public static let reads: Set<String> = ["system_status", "list_apps", "find_files", "list_shortcuts"]
    /// Change something the user can undo in one gesture (a slider, a key). These run
    /// without an approval sheet because asking "turn the volume down?" every time would
    /// make the assistant useless for the thing people ask it most. They still pass
    /// strict validation, and they are never counted as safe on an ambiguous request.
    public static let instant: Set<String> = ["set_volume", "set_brightness", "set_dark_mode", "media_control", "set_timer"]
    /// Anything that can lose work, leave the Mac, expose private data, or run user code.
    public static let approved: Set<String> = ["quit_app", "open_url", "open_file", "clipboard_read", "clipboard_write", "lock_screen", "run_shortcut"]
    public static let all = reads.union(instant).union(approved)

    public static let fields: [String: Set<String>] = [
        "system_status": [], "list_apps": [], "find_files": ["query"], "list_shortcuts": [],
        "set_volume": ["level"], "set_brightness": ["level"], "set_dark_mode": ["enabled"],
        "media_control": ["action"], "set_timer": ["seconds", "label"],
        "quit_app": ["bundle_id"], "open_url": ["url"], "open_file": ["path"],
        "clipboard_read": [], "clipboard_write": ["text"], "lock_screen": [], "run_shortcut": ["name"]
    ]
    /// Fields the model may legitimately leave empty.
    public static let optional: Set<String> = ["label"]
    /// Reading these puts private content into the conversation, which then blocks web search.
    public static let privateReads: Set<String> = ["find_files", "clipboard_read"]

    public static let descriptions: [String: String] = [
        "system_status": "Read this Mac's current state: battery and power, volume and mute, display brightness, dark mode, Wi-Fi power, disk space, memory, thermal state, uptime and the frontmost app.",
        "list_apps": "List the apps currently running on this Mac with their bundle IDs.",
        "find_files": "Locate where a file is: Spotlight search of the home folder returning paths, kinds and dates only. It cannot see what a file says, so never use it to answer a question about a document's contents; use search_documents for that.",
        "list_shortcuts": "List the user's Apple Shortcuts by name. Use this before run_shortcut, and for Focus/Do Not Disturb, Bluetooth, Wi-Fi, smart-home or other requests no other tool covers.",
        "set_volume": "Set the Mac's output volume. level is a whole number 0 to 100, or mute, or unmute.",
        "set_brightness": "Set the built-in display brightness. level is a whole number 0 to 100.",
        "set_dark_mode": "Switch the Mac between dark and light appearance. enabled is true for dark, false for light.",
        "media_control": "Control whatever is playing (Music, Spotify, a browser video). action is play_pause, next, or previous.",
        "set_timer": "Start a countdown timer. seconds is a whole number from 1 to 86400. label names it, or is an empty string.",
        "quit_app": "Propose quitting one running app by bundle ID, as if the user chose Quit. The app may ask to save. Approval required.",
        "open_url": "Propose opening one http or https web address in the default browser. Never put private data in the URL. Approval required.",
        "open_file": "Propose opening a file or folder inside the user's home folder with its default app. Programs and scripts are refused. Approval required.",
        "clipboard_read": "Propose reading the text currently on the clipboard. Approval required.",
        "clipboard_write": "Propose replacing the clipboard with text. Approval required.",
        "lock_screen": "Propose locking the Mac's screen immediately. Approval required.",
        "run_shortcut": "Propose running one of the user's Apple Shortcuts by its exact name from list_shortcuts. Approval required."
    ]

    public static let mediaActions: Set<String> = ["play_pause", "next", "previous"]
    /// Apps that must never be quit on the model's word: the session, the desktop, and Jarvis.
    public static let unquittable: Set<String> = ["com.apple.finder", "com.apple.loginwindow", "com.apple.dock",
        "com.apple.systemuiserver", "com.apple.WindowManager", "com.apple.controlcenter"]
    /// Types that execute or install something when opened. Opening one would turn
    /// open_file into a program launcher, which no tool is allowed to be.
    public static let unopenableExtensions: Set<String> = [
        "app", "command", "sh", "zsh", "bash", "csh", "ksh", "fish", "tool", "terminal", "scpt", "scptd", "applescript",
        "workflow", "action", "pkg", "mpkg", "jar", "py", "pl", "rb", "php", "js", "osax", "prefpane", "kext",
        "dylib", "bundle", "plugin", "webloc", "inetloc", "fileloc", "shortcut", "mobileconfig", "saver", "qlgenerator"
    ]

    public static func isSystemTool(_ name: String) -> Bool { all.contains(name) }
}

public enum SystemToolPolicy {
    /// Shape and range checks beyond the generic field-set check in ActionPolicy.
    public static func validate(_ call: ToolCall, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let a = call.arguments
        func percent(_ value: String) throws -> Int {
            guard value.range(of: "^\\d{1,3}$", options: .regularExpression) != nil, let n = Int(value), (0...100).contains(n) else {
                throw JarvisError.message("level must be a whole number from 0 to 100.")
            }
            return n
        }
        switch call.name {
        case "set_volume":
            let level = a["level"]!.lowercased()
            if level != "mute" && level != "unmute" { _ = try percent(level) }
        case "set_brightness": _ = try percent(a["level"]!)
        case "set_dark_mode":
            guard ["true", "false"].contains(a["enabled"]!.lowercased()) else { throw JarvisError.message("enabled must be true or false.") }
        case "media_control":
            guard SystemToolCatalog.mediaActions.contains(a["action"]!) else { throw JarvisError.message("action must be play_pause, next, or previous.") }
        case "set_timer":
            guard let s = a["seconds"], s.range(of: "^\\d{1,5}$", options: .regularExpression) != nil, let n = Int(s), (1...86_400).contains(n) else {
                throw JarvisError.message("seconds must be a whole number from 1 to 86400.")
            }
            guard a["label"]!.count <= 80, !a["label"]!.contains("\n") else { throw JarvisError.message("Keep the timer label to one short line.") }
        case "find_files":
            guard a["query"]!.count <= 200, !a["query"]!.contains("\n") else { throw JarvisError.message("Use a short, single-line search.") }
        case "quit_app":
            let id = a["bundle_id"]!
            guard id.range(of: "^[A-Za-z0-9.-]{1,200}$", options: .regularExpression) != nil else { throw JarvisError.message("Use one app bundle ID.") }
            guard !SystemToolCatalog.unquittable.contains(id), !id.hasPrefix(Configuration.appID) else {
                throw JarvisError.message("Jarvis will not quit that app. Quit it yourself if you need to.")
            }
        case "open_url": _ = try url(a["url"]!)
        case "open_file": _ = try openablePath(a["path"]!, home: home)
        case "clipboard_write":
            guard a["text"]!.utf8.count <= 16_000 else { throw JarvisError.message("Clipboard text is limited to 16 KB.") }
        case "run_shortcut":
            guard a["name"]!.count <= 200, !a["name"]!.contains("\n"), !a["name"]!.contains("\r") else {
                throw JarvisError.message("Use the exact name of one shortcut.")
            }
        default: break
        }
    }

    public static func url(_ value: String) throws -> URL {
        guard value.utf8.count <= 2_000, let url = URL(string: value.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), let host = url.host, !host.isEmpty else {
            throw JarvisError.message("Only a complete http or https address can be opened.")
        }
        // user:password@host is how credentials get smuggled into an address bar.
        guard url.user == nil, url.password == nil else { throw JarvisError.message("Addresses containing credentials are refused.") }
        return url
    }

    /// A file inside the home folder that opens as a document, never as a program.
    public static func openablePath(_ value: String, home: URL) throws -> URL {
        let expanded = (value as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { throw JarvisError.message("Use a full path, for example ~/Documents/report.pdf.") }
        let candidate = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath()
        let root = home.standardizedFileURL.resolvingSymlinksInPath().path
        guard candidate.path.hasPrefix(root + "/") else { throw JarvisError.message("Only files inside your home folder can be opened.") }
        let components = candidate.path.dropFirst(root.count + 1).split(separator: "/")
        guard !components.contains(where: { $0.hasPrefix(".") }), components.first != "Library" else {
            throw JarvisError.message("Hidden and Library files are not opened by Jarvis.")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory) else { throw JarvisError.message("That file does not exist.") }
        // Walk every component: a folder named Foo.app is still an application.
        for component in components {
            if SystemToolCatalog.unopenableExtensions.contains((String(component) as NSString).pathExtension.lowercased()) {
                throw JarvisError.message("Programs, scripts and installers are not opened by Jarvis. Open it yourself if you trust it.")
            }
        }
        if !isDirectory.boolValue && FileManager.default.isExecutableFile(atPath: candidate.path) {
            throw JarvisError.message("Executable files are not opened by Jarvis.")
        }
        return candidate
    }
}

/// Executes Mac-control tools. Owned by the broker; each call has already passed
/// ActionPolicy and, where required, a single-use approval.
@MainActor public final class SystemController {
    public init() {}

    public func execute(_ call: ToolCall) async throws -> String {
        let a = call.arguments
        switch call.name {
        case "system_status": return try json(status())
        case "list_apps":
            let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map {
                ["name": $0.localizedName ?? "", "bundle_id": $0.bundleIdentifier ?? "", "active": $0.isActive ? "yes" : "no"]
            }
            return try json(apps)
        case "find_files": return try json(await findFiles(a["query"]!))
        case "list_shortcuts": return try json(try await shortcuts())
        case "set_volume":
            let level = a["level"]!.lowercased()
            if level == "mute" || level == "unmute" { try Audio.setMuted(level == "mute"); return level == "mute" ? "Sound muted." : "Sound unmuted." }
            let value = Float(Int(level)!) / 100
            try Audio.setVolume(value)
            if value > 0, (try? Audio.muted()) == true { try? Audio.setMuted(false) }
            return "Volume set to \(level)%."
        case "set_brightness":
            try Display.setBrightness(Float(Int(a["level"]!)!) / 100)
            return "Brightness set to \(a["level"]!)%."
        case "set_dark_mode":
            let dark = a["enabled"]!.lowercased() == "true"
            try appleScript("tell application \"System Events\" to tell appearance preferences to set dark mode to \(dark)")
            return dark ? "Dark mode on." : "Light mode on."
        case "media_control":
            try MediaKeys.press(a["action"]!)
            return "Sent \(a["action"]!.replacingOccurrences(of: "_", with: "/")) to the current media player."
        case "set_timer":
            // The app owns the countdown so it can notify and speak; the broker only validates.
            return "Timer started for \(a["seconds"]!) seconds."
        case "quit_app":
            guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == a["bundle_id"]! }) else {
                throw JarvisError.message("That app is not running.")
            }
            let name = app.localizedName ?? a["bundle_id"]!
            guard app.terminate() else { throw JarvisError.message("\(name) refused to quit.") }
            for _ in 0..<15 where !app.isTerminated { try await Task.sleep(for: .milliseconds(200)) }
            return app.isTerminated ? "\(name) quit." : "Asked \(name) to quit. It may be waiting for you to save changes."
        case "open_url":
            guard NSWorkspace.shared.open(try SystemToolPolicy.url(a["url"]!)) else { throw JarvisError.message("No app could open that address.") }
            return "Opened in the default browser."
        case "open_file":
            // Re-resolve at execution: the path could have been swapped since approval.
            let url = try SystemToolPolicy.openablePath(a["path"]!, home: FileManager.default.homeDirectoryForCurrentUser)
            guard NSWorkspace.shared.open(url) else { throw JarvisError.message("No app could open that file.") }
            return "Opened \(url.lastPathComponent)."
        case "clipboard_read":
            guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return "The clipboard holds no text." }
            return String(text.prefix(16_000))
        case "clipboard_write":
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.setString(a["text"]!, forType: .string) else { throw JarvisError.message("The clipboard could not be written.") }
            return "Copied to the clipboard."
        case "lock_screen":
            try lockScreen(); return "Screen locked."
        case "run_shortcut":
            let name = a["name"]!
            guard try await shortcuts().contains(name) else { throw JarvisError.message("No shortcut is named \"\(name)\". Call list_shortcuts for the exact names.") }
            let result = try await Command.run("/usr/bin/shortcuts", ["run", name], timeout: 90)
            guard result.status == 0 else { throw JarvisError.message("The shortcut \"\(name)\" failed.") }
            let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return output.isEmpty ? "Ran \"\(name)\"." : "Ran \"\(name)\". Output: \(output.prefix(4_000))"
        default: throw JarvisError.message("Tool is unavailable.")
        }
    }

    private func json(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }

    func status() -> [String: Any] {
        var s: [String: Any] = [:]
        let process = ProcessInfo.processInfo
        s["macos"] = process.operatingSystemVersionString
        s["uptime_hours"] = (process.systemUptime / 360).rounded() / 10
        s["memory_gb"] = Int(process.physicalMemory / 1_073_741_824)
        s["thermal_state"] = ["nominal", "fair", "serious", "critical"][min(process.thermalState.rawValue, 3)]
        var load = [Double](repeating: 0, count: 3)
        if getloadavg(&load, 3) == 3 { s["load_average_1m"] = (load[0] * 100).rounded() / 100 }
        s["frontmost_app"] = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        s["dark_mode"] = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        if let volume = try? Audio.volume() { s["volume_percent"] = Int((volume * 100).rounded()) }
        if let muted = try? Audio.muted() { s["muted"] = muted }
        if let brightness = try? Display.brightness() { s["brightness_percent"] = Int((brightness * 100).rounded()) }
        if let wifi = CWWiFiClient.shared().interface() { s["wifi_on"] = wifi.powerOn() }
        if let values = try? FileManager.default.homeDirectoryForCurrentUser.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
           let free = values.volumeAvailableCapacityForImportantUsage, let total = values.volumeTotalCapacity {
            s["disk_free_gb"] = Int(free / 1_000_000_000); s["disk_total_gb"] = total / 1_000_000_000
        }
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for source in list {
                guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                      d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
                if let current = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 {
                    s["battery_percent"] = current * 100 / max
                }
                s["charging"] = d[kIOPSIsChargingKey] as? Bool ?? false
                s["on_battery"] = d[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
                if let minutes = d[kIOPSTimeToEmptyKey] as? Int, minutes > 0 { s["minutes_remaining"] = minutes }
            }
        }
        return s
    }

    /// Spotlight over the home folder, names and metadata only. Library and hidden
    /// folders are left out: that is where credentials, caches and mail stores live.
    private func findFiles(_ query: String) async throws -> [[String: String]] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let result = try await Command.run("/usr/bin/mdfind", ["-onlyin", home, query], timeout: 15)
        let formatter = ISO8601DateFormatter()
        var found: [[String: String]] = []
        for path in result.output.split(separator: "\n").map(String.init) {
            let relative = path.hasPrefix(home + "/") ? String(path.dropFirst(home.count + 1)) : path
            if relative.hasPrefix("Library/") || relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { continue }
            let url = URL(fileURLWithPath: path)
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey, .localizedTypeDescriptionKey])
            found.append(["path": "~/" + relative, "kind": values?.isDirectory == true ? "folder" : (values?.localizedTypeDescription ?? "file"),
                          "modified": values?.contentModificationDate.map { formatter.string(from: $0) } ?? ""])
            if found.count == 25 { break }
        }
        return found
    }

    private func shortcuts() async throws -> [String] {
        let result = try await Command.run("/usr/bin/shortcuts", ["list"], timeout: 20)
        guard result.status == 0 else { throw JarvisError.message("The Shortcuts app did not respond.") }
        return result.output.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func appleScript(_ source: String) throws {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            // -1743: the user has not allowed Jarvis to control System Events.
            if code == -1743 {
                throw JarvisError.message("Allow Jarvis to control System Events in System Settings › Privacy & Security › Automation, then try again.")
            }
            throw JarvisError.message("macOS refused the appearance change (\(code)).")
        }
    }

    private func lockScreen() throws {
        // The login framework's own entry point locks immediately, whatever the
        // "require password after sleep" delay is set to.
        if let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_NOW),
           let symbol = dlsym(handle, "SACLockScreenImmediate") {
            typealias Lock = @convention(c) () -> Int32
            if unsafeBitCast(symbol, to: Lock.self)() == 0 { return }
        }
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset"); p.arguments = ["displaysleepnow"]
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw JarvisError.message("The screen could not be locked.") }
    }
}

/// Runs one fixed system binary with an argument array (never a shell), bounded in time and output.
enum Command {
    struct Result { var status: Int32; var output: String }
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let p = Process(), out = Pipe()
                p.executableURL = URL(fileURLWithPath: path); p.arguments = arguments
                p.standardOutput = out; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch { continuation.resume(throwing: error); return }
                let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                var data = Data()
                while case let chunk = out.fileHandleForReading.availableData, !chunk.isEmpty {
                    if data.count < 2_000_000 { data.append(chunk) }
                }
                p.waitUntilExit(); timer.cancel()
                if p.terminationReason == .uncaughtSignal { continuation.resume(throwing: JarvisError.message("The system command timed out.")); return }
                continuation.resume(returning: Result(status: p.terminationStatus, output: String(decoding: data, as: UTF8.self)))
            }
        }
    }
}

enum Audio {
    private static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput,
                                _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }
    static func outputDevice() throws -> AudioDeviceID {
        var id = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var a = address(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id) == noErr, id != 0 else {
            throw JarvisError.message("No sound output device is available.")
        }
        return id
    }
    static func volume() throws -> Float {
        let device = try outputDevice()
        var value = Float32(0), size = UInt32(MemoryLayout<Float32>.size)
        var a = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        if AudioObjectGetPropertyData(device, &a, 0, nil, &size, &value) == noErr { return value }
        a = address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, 1)
        guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, &value) == noErr else { throw JarvisError.message("This output device has no volume control.") }
        return value
    }
    static func setVolume(_ level: Float) throws {
        let device = try outputDevice()
        var value = Float32(max(0, min(1, level)))
        var a = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        if AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr { return }
        // Devices without a virtual main control take per-channel volume instead.
        var changed = false
        for channel: UInt32 in [0, 1, 2] {
            a = address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, channel)
            if AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr { changed = true }
        }
        guard changed else { throw JarvisError.message("This output device's volume cannot be set. Use its own controls.") }
    }
    static func muted() throws -> Bool {
        var value = UInt32(0), size = UInt32(MemoryLayout<UInt32>.size)
        var a = address(kAudioDevicePropertyMute)
        guard AudioObjectGetPropertyData(try outputDevice(), &a, 0, nil, &size, &value) == noErr else { throw JarvisError.message("This device has no mute control.") }
        return value != 0
    }
    static func setMuted(_ muted: Bool) throws {
        var value = UInt32(muted ? 1 : 0)
        var a = address(kAudioDevicePropertyMute)
        guard AudioObjectSetPropertyData(try outputDevice(), &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr else {
            throw JarvisError.message("This output device cannot be muted. Try setting the volume to 0.")
        }
    }
}

/// Built-in display brightness. There is no public API for this; DisplayServices is
/// what the brightness keys use. External monitors are not covered and say so.
enum Display {
    private typealias Getter = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Setter = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private static let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
    private static func builtIn() -> CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8), count = UInt32(0)
        guard CGGetActiveDisplayList(8, &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }
    static func brightness() throws -> Float {
        guard let handle, let symbol = dlsym(handle, "DisplayServicesGetBrightness"), let display = builtIn() else {
            throw JarvisError.message("No built-in display brightness is available.")
        }
        var value = Float(0)
        guard unsafeBitCast(symbol, to: Getter.self)(display, &value) == 0 else { throw JarvisError.message("Brightness could not be read.") }
        return value
    }
    static func setBrightness(_ level: Float) throws {
        guard let handle, let symbol = dlsym(handle, "DisplayServicesSetBrightness"), let display = builtIn() else {
            throw JarvisError.message("Only a built-in display's brightness can be set. Use the monitor's own controls.")
        }
        guard unsafeBitCast(symbol, to: Setter.self)(display, max(0, min(1, level))) == 0 else { throw JarvisError.message("Brightness could not be changed.") }
    }
}

/// The hardware media keys, posted as the system-defined events the keyboard sends,
/// so they reach whichever app owns Now Playing.
enum MediaKeys {
    static func press(_ action: String) throws {
        guard AXIsProcessTrusted() else {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            throw JarvisError.message("Media control needs Accessibility access. Allow JarvisBroker in System Settings › Privacy & Security › Accessibility, then try again.")
        }
        // NX_KEYTYPE_PLAY, NX_KEYTYPE_NEXT, NX_KEYTYPE_PREVIOUS from IOKit's ev_keymap.h.
        let key: Int = ["play_pause": 16, "next": 17, "previous": 18][action]!
        for down in [true, false] {
            let state = down ? 0xA : 0xB
            let event = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                                           timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: (key << 16) | (state << 8), data2: -1)
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}
