import Foundation
import AppKit
import ApplicationServices
import ScreenCaptureKit

/// Captures only the broker-observed window from the main application process.
///
/// The broker owns Accessibility and input.  This helper consumes the broker's
/// trusted observation only to use the main app's Screen Recording grant; the
/// model never supplies a PID, window frame, or capture target directly.
@MainActor public enum ComputerWindowCapture {
    private struct Observation: Decodable {
        let snapshot: String
        let bundleID: String
        let pid: Int
        let windowFrame: [Double]

        enum CodingKeys: String, CodingKey {
            case snapshot
            case bundleID
            case pid
            case windowFrame = "window_frame"
        }
    }

    private static let maximumJPEGBytes = 2_000_000
    private static let maximumWidth = 1_280
    private static let maximumHeight = 1_600
    private static let frameTolerance: CGFloat = 4

    /// Captures the single broker-observed application window as a base64 JPEG.
    /// Returns `nil` when the image cannot be encoded within the size bound.
    public static func capture(observation: String, expectedBundleID: String) async throws -> String? {
        try Task.checkCancellation()

        let record: Observation
        do {
            record = try JSONDecoder().decode(Observation.self, from: Data(observation.utf8))
        } catch {
            throw JarvisError.message("The broker returned an invalid computer observation.")
        }
        guard UUID(uuidString: record.snapshot) != nil else {
            throw JarvisError.message("The computer observation is missing a valid snapshot.")
        }
        guard !expectedBundleID.isEmpty, record.bundleID == expectedBundleID else {
            throw JarvisError.message("The observed app does not match the selected app.")
        }
        guard record.pid > 0 else {
            throw JarvisError.message("The computer observation has an invalid process identity.")
        }
        let observedFrame = try parseFrame(record.windowFrame)

        guard CGPreflightScreenCaptureAccess() else {
            throw JarvisError.message("Enable Screen Recording for Jarvis, then try the computer task again.")
        }
        guard AXIsProcessTrusted() else {
            throw JarvisError.message("Enable Accessibility for Jarvis, then try the computer task again.")
        }

        guard let app = NSRunningApplication(processIdentifier: pid32(record.pid)) else {
            throw JarvisError.message("The selected app is no longer running.")
        }
        try validateProcess(app, pid: record.pid, bundleID: expectedBundleID)
        try validateFocusedWindow(app, frame: observedFrame)

        // ScreenCaptureKit enumerates windows asynchronously.  Keep the
        // existing NSRunningApplication instance pinned across that await so a
        // terminated process cannot be replaced by a new process with the same
        // PID while the capture is in flight.
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        guard CGPreflightScreenCaptureAccess() else {
            throw JarvisError.message("Screen Recording access was revoked. No screenshot was returned.")
        }
        try validateProcess(app, pid: record.pid, bundleID: expectedBundleID)
        try validateFocusedWindow(app, frame: observedFrame)

        let matches = content.windows.filter { candidate in
            guard candidate.isOnScreen,
                  let owningApplication = candidate.owningApplication,
                  Int(owningApplication.processID) == record.pid,
                  validFrame(candidate.frame) else {
                return false
            }
            return frameMatches(candidate.frame, observedFrame, tolerance: frameTolerance)
        }
        guard matches.count == 1, let window = matches.first else {
            throw JarvisError.message("Could not uniquely identify the selected app window. No screenshot was returned.")
        }

        // Recheck immediately before the second await.  The filter below is
        // intentionally window-scoped and never uses a display/full-desktop
        // capture, even if the target app changes focus afterward.
        try Task.checkCancellation()
        try validateProcess(app, pid: record.pid, bundleID: expectedBundleID)
        try validateFocusedWindow(app, frame: observedFrame)
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = try captureConfiguration(for: observedFrame)
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        try Task.checkCancellation()
        guard CGPreflightScreenCaptureAccess() else {
            throw JarvisError.message("Screen Recording access was revoked. No screenshot was returned.")
        }
        try validateProcess(app, pid: record.pid, bundleID: expectedBundleID)
        try validateFocusedWindow(app, frame: observedFrame)

        guard let jpeg = encodeJPEG(image), jpeg.count <= maximumJPEGBytes else { return nil }
        return jpeg.base64EncodedString()
    }

    private static func pid32(_ pid: Int) -> pid_t {
        pid_t(pid)
    }

    private static func parseFrame(_ values: [Double]) throws -> CGRect {
        guard values.count == 4,
              values.allSatisfy({ $0.isFinite }),
              values[2] > 0,
              values[3] > 0,
              values[2] <= 100_000,
              values[3] <= 100_000 else {
            throw JarvisError.message("The computer observation has invalid window bounds.")
        }
        let frame = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        guard validFrame(frame) else {
            throw JarvisError.message("The computer observation has invalid window bounds.")
        }
        return frame
    }

    private static func validFrame(_ frame: CGRect) -> Bool {
        frame.minX.isFinite && frame.minY.isFinite && frame.maxX.isFinite && frame.maxY.isFinite &&
            frame.width.isFinite && frame.height.isFinite && frame.width > 0 && frame.height > 0
    }

    private static func frameMatches(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat) -> Bool {
        validFrame(lhs) && validFrame(rhs) &&
            abs(lhs.minX - rhs.minX) <= tolerance &&
            abs(lhs.minY - rhs.minY) <= tolerance &&
            abs(lhs.width - rhs.width) <= tolerance &&
            abs(lhs.height - rhs.height) <= tolerance
    }

    private static func validateProcess(_ app: NSRunningApplication, pid: Int, bundleID: String) throws {
        guard !app.isTerminated,
              Int(app.processIdentifier) == pid,
              app.bundleIdentifier == bundleID,
              let current = NSRunningApplication(processIdentifier: pid32(pid)),
              !current.isTerminated,
              Int(current.processIdentifier) == pid,
              current.bundleIdentifier == bundleID else {
            throw JarvisError.message("The selected app changed during capture. No screenshot was returned.")
        }

        // launchDate is not part of the broker observation.  When AppKit
        // exposes it for both handles, use it as an additional PID-reuse guard;
        // the pinned handle and termination checks above remain authoritative.
        if let originalLaunch = app.launchDate,
           let currentLaunch = current.launchDate,
           abs(originalLaunch.timeIntervalSince(currentLaunch)) > 0.001 {
            throw JarvisError.message("The selected app changed during capture. No screenshot was returned.")
        }
    }

    private static func applicationElement(for app: NSRunningApplication) -> AXUIElement {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.3)
        return element
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func axElement(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func axString(_ element: AXUIElement, _ name: String) -> String {
        attribute(element, name) as? String ?? ""
    }

    private static func axFrame(_ element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute),
              let size = attribute(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(),
              CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        let frame = CGRect(origin: point, size: dimensions)
        return validFrame(frame) ? frame : nil
    }

    private static func secure(_ element: AXUIElement) -> Bool {
        let role = axString(element, kAXRoleAttribute).lowercased()
        let subrole = axString(element, kAXSubroleAttribute).lowercased()
        let description = axString(element, kAXRoleDescriptionAttribute).lowercased()
        return role.contains("secure") || subrole.contains("secure") || description.contains("secure") ||
            role.contains("password") || subrole.contains("password") || description.contains("password")
    }

    private static func validateFocusedWindow(_ app: NSRunningApplication, frame: CGRect) throws {
        let application = applicationElement(for: app)
        guard let focusedWindow = axElement(attribute(application, kAXFocusedWindowAttribute)),
              let focusedFrame = axFrame(focusedWindow),
              frameMatches(focusedFrame, frame, tolerance: frameTolerance) else {
            throw JarvisError.message("The selected app window changed during capture. No screenshot was returned.")
        }
        if let focusedElement = axElement(attribute(application, kAXFocusedUIElementAttribute)), secure(focusedElement) {
            throw JarvisError.message("A secure field has focus. No screenshot was returned.")
        }
    }

    private static func captureConfiguration(for frame: CGRect) throws -> SCStreamConfiguration {
        let width = max(frame.width, 1)
        let height = max(frame.height, 1)
        let scale = min(1, Double(maximumWidth) / Double(width), Double(maximumHeight) / Double(height))
        let pixelWidth = max(1, Int((Double(width) * scale).rounded(.down)))
        let pixelHeight = max(1, Int((Double(height) * scale).rounded(.down)))
        guard pixelWidth <= maximumWidth, pixelHeight <= maximumHeight else {
            throw JarvisError.message("The selected app window is too large to capture safely.")
        }
        let configuration = SCStreamConfiguration()
        configuration.width = pixelWidth
        configuration.height = pixelHeight
        configuration.showsCursor = false
        return configuration
    }

    private static func encodeJPEG(_ image: CGImage) -> Data? {
        let qualities: [CGFloat] = [0.78, 0.68, 0.58, 0.48, 0.38, 0.28, 0.18, 0.10]
        var scale = 1.0
        for _ in 0..<8 {
            guard let candidate = resized(image, scale: scale) else { return nil }
            let bitmap = NSBitmapImageRep(cgImage: candidate)
            for quality in qualities {
                guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality]) else { continue }
                if data.count <= maximumJPEGBytes { return data }
            }
            scale *= 0.8
        }
        return nil
    }

    private static func resized(_ image: CGImage, scale: Double) -> CGImage? {
        let width = max(1, Int((Double(image.width) * scale).rounded(.down)))
        let height = max(1, Int((Double(image.height) * scale).rounded(.down)))
        guard width > 0, height > 0 else { return nil }
        if width == image.width, height == image.height { return image }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
