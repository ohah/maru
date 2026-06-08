import AppKit

@MainActor
final class MaruAppHostController {
    private var capabilities = MaruAppHostCapabilities()

    func validateZigBoundary() -> Bool {
        // 이 skeleton은 아직 앱을 실행하지 않는다. 먼저 Swift가 C header를 통해 Zig ABI를
        // 볼 수 있는지 확인해서, 다음 PR의 실제 NSApplication loop가 임의 DTO를 만들지
        // 못하게 한다.
        let status = maru_macos_app_host_capabilities(&capabilities)
        return status == MaruAppHostStatusOk.rawValue &&
            capabilities.abi_version == MARU_MACOS_APP_HOST_ABI_VERSION
    }

    func makePlaceholderWindow() -> NSWindow {
        // 실제 terminal surface 연결은 다음 PR의 책임이다. 여기서는 Swift가 소유할
        // window lifecycle 위치만 고정해 ObjC smoke bridge와 제품 host가 섞이지 않게 한다.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Maru"
        return window
    }
}
