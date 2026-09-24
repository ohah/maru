//! 웹 OSR sidecar 중 CEF 를 모르는 부분의 시험 입구(W1b·W1c·W2) — 명령 상자·명령 처리·브라우저 목록·제목 조절·링 알림 검사·링 알림 권리. 링 시험은 실제 mach·IOSurface 를 쓴다(CEF 는 안 쓴다). CEF SDK 없이 기본 `zig build test`
//! 에서 돈다(build/web_sidecar.zig 가 시험 수를 잠근다).

test {
    _ = @import("inbox.zig");
    _ = @import("dispatch.zig");
    _ = @import("registry.zig");
    _ = @import("title_gate.zig");
    _ = @import("ring_receiver.zig");
    _ = @import("ring_producer.zig");
}
