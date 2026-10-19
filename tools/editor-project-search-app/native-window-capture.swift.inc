import AppKit
import ScreenCaptureKit
import CoreGraphics
@main struct Capture {
    @MainActor static func main() async {
        // ScreenCaptureKit의 창 필터가 사용할 AppKit/WindowServer 연결을 먼저 연다.
        _ = NSApplication.shared
        let args = CommandLine.arguments
        let root = URL(fileURLWithPath: "/tmp/maru-screen-capture-status.json")
        do {
            guard CGPreflightScreenCaptureAccess() else {
                _ = CGRequestScreenCaptureAccess()
                try JSONSerialization.data(withJSONObject: ["permission": false]).write(to: root)
                return
            }
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let windows = content.windows.map { ["id": $0.windowID, "title": $0.title ?? "", "owner": $0.owningApplication?.applicationName ?? "", "pid": $0.owningApplication?.processID ?? 0] as [String: Any] }
            try JSONSerialization.data(withJSONObject: ["permission": true, "windows": windows], options: .prettyPrinted).write(to: root)
            guard args.count == 3, let id = UInt32(args[1]), let window = content.windows.first(where: { $0.windowID == id }) else { return }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            config.width = Int(window.frame.width * 2)
            config.height = Int(window.frame.height * 2)
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw NSError(domain: "capture", code: 1) }
            try png.write(to: URL(fileURLWithPath: args[2]))
        } catch {
            try? JSONSerialization.data(withJSONObject: ["error": String(describing: error)]).write(to: root)
        }
    }
}
