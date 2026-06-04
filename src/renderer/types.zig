const terminal = @import("../terminal.zig");

pub const Backend = enum {
    // 미래 backend는 구현을 시작하기 전까지 public enum에 넣지 않는다.
    // 실제로 제공하지 않는 backend를 config나 테스트가 실수로 계약처럼
    // 의존하지 않게 하기 위해서다.
    metal,
};

pub const RenderFrame = struct {
    backend: Backend,
    snapshot: terminal.RenderSnapshot,
};

pub fn initialBackendForMacOS() Backend {
    return .metal;
}

test "macOS renderer starts with Metal" {
    try @import("std").testing.expectEqual(Backend.metal, initialBackendForMacOS());
}
