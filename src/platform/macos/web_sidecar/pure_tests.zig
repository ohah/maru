//! 웹 OSR sidecar 중 CEF 를 모르는 부분의 시험 입구(W1b) — 명령 상자·명령 처리. CEF SDK 없이 기본 `zig build test`
//! 에서 돈다(build/web_sidecar.zig 가 시험 수를 잠근다).

test {
    _ = @import("inbox.zig");
    _ = @import("dispatch.zig");
    _ = @import("registry.zig");
}
