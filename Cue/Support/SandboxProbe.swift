#if DEBUG
import AppKit
import ApplicationServices
import AVFoundation
import os

/// Diagnostics only: what the sandbox lets through for AX on other apps, and for
/// the display's brightness. Logged under "Probe:".
@MainActor
enum SandboxProbe {
    static func run() {
        Log.app.info("Probe: AX trusted \(AXIsProcessTrusted(), privacy: .public)")
        for bundle in ["com.apple.notificationcenterui", "com.apple.finder", "com.apple.dock"] {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else {
                Log.app.info("Probe: \(bundle, privacy: .public) not running"); continue
            }
            let element = AXUIElementCreateApplication(app.processIdentifier)
            var windows: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windows)
            var role: CFTypeRef?
            let roleError = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            Log.app.info("Probe: AX \(bundle, privacy: .public) windows err \(error.rawValue) count \((windows as? [Any])?.count ?? -1) role err \(roleError.rawValue)")
        }
        // Waits for a Notification Center window (a banner) and dumps its tree.
        Task {
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(250))
                guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first else { return }
                var windows: CFTypeRef?
                AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute as CFString, &windows)
                guard let list = windows as? [AXUIElement], !list.isEmpty else { continue }
                for window in list { dump(window, depth: 0) }
                return
            }
            Log.app.info("Probe: no banner window")
        }
        typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
        if let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
           let symbol = dlsym(handle, "DisplayServicesGetBrightness") {
            var value = Float(-1)
            let result = unsafeBitCast(symbol, to: Get.self)(CGMainDisplayID(), &value)
            Log.app.info("Probe: DisplayServices get \(result) value \(value)")
        }
    }

    /// The mirror's camera run for 3 s, its state logged; no frame is kept.
    static func mirrorCamera() {
        Log.app.info("Probe: camera access \(AVCaptureDevice.authorizationStatus(for: .video).rawValue)")
        let camera = MirrorCamera()
        camera.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            Log.app.info("Probe: mirror \(String(describing: camera.state), privacy: .public) on \(camera.current?.localizedName ?? "none", privacy: .public), \(camera.devices.count) cameras, running \(camera.session.isRunning)")
            camera.stop()
        }
    }

    /// Brightness up as the key sends it, read before and after; down again 3 s later.
    static func pressBrightness() {
        func press(_ code: Int) {
            for down in [true, false] {
                let data1 = (code << 16) | ((down ? 0xA : 0xB) << 8)
                NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                   context: nil, subtype: 8, data1: data1, data2: -1)?.cgEvent?.post(tap: .cghidEventTap)
            }
        }
        let before = SystemLevels.brightness
        press(2)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            Log.app.info("Probe: brightness \(before ?? -1) -> \(SystemLevels.brightness ?? -1)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            press(3)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { Log.app.info("Probe: brightness back to \(SystemLevels.brightness ?? -1)") }
        }
    }

    private static func dump(_ element: AXUIElement, depth: Int) {
        guard depth < 14 else { return }
        func string(_ name: String) -> String {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(element, name as CFString, &value)
            return value.map { "\($0)" } ?? ""
        }
        var actions: CFArray?
        AXUIElementCopyActionNames(element, &actions)
        let line = String(repeating: "  ", count: depth) + "\(string("AXRole"))/\(string("AXSubrole")) id=\(string("AXIdentifier")) title=\(string("AXTitle")) desc=\(string("AXDescription")) value=\(string("AXValue")) actions=\((actions as? [String]) ?? [])"
        Log.app.info("Probe: \(line, privacy: .public)")
        var children: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
        for child in (children as? [AXUIElement]) ?? [] { dump(child, depth: depth + 1) }
    }
}
#endif
