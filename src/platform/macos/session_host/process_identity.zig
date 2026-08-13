//! 세션 호스트 process-domain 권위가 공유하는 PID 단일 출처다.
//!
//! macOS와 Linux는 실제 PID를 읽어 fork 뒤 상속 상태를 거부하고, 지원하지 않는 target은 0으로
//! fail-closed한다. 각 owner가 별도 PID 규칙을 만들면 같은 메모리를 서로 다른 process domain으로 볼 수 있다.

const builtin = @import("builtin");
const std = @import("std");

pub fn currentProcessId() u32 {
    return switch (builtin.os.tag) {
        .macos, .linux => @intCast(std.c.getpid()),
        else => 0,
    };
}

test "macOS와 Linux process identity는 실제 nonzero PID다" {
    if (builtin.os.tag == .macos or builtin.os.tag == .linux) {
        try std.testing.expectEqual(@as(u32, @intCast(std.c.getpid())), currentProcessId());
        try std.testing.expect(currentProcessId() != 0);
    } else {
        try std.testing.expectEqual(@as(u32, 0), currentProcessId());
    }
}
