//! host 의 자식이 모두 샌드박스 안 `maru-web-helper` 인가(W1b·W1c 판정자가 함께 쓴다).

const std = @import("std");
const os = @import("os.zig");

pub const State = struct {
    total: usize,
    sandboxed: usize,
    named: usize,

    pub fn all(self: State, min: usize) bool {
        return self.total >= min and self.sandboxed == self.total and self.named == self.total;
    }
};

/// 막 fork 된 자식은 아직 exec 전이라 경로가 host 이고, helper 는 `cef_sandbox_initialize` 에 닿기 전 잠깐 샌드박스
/// 밖이다(실측 — 1 초 시점에는 GPU·네트워크·저장소 셋 다 샌드박스 안). 그래서 제한 시간 안에 **모두** 샌드박스 안
/// helper 가 되는지 본다. 끝내 안 되면 마지막 관찰을 돌려줘 실패로 판정된다.
pub fn settle(host_pid: c_int, min: usize, timeout_ms: u32) State {
    var buf: [64]c_int = undefined;
    var path_buf: [4096]u8 = undefined;
    var state: State = .{ .total = 0, .sandboxed = 0, .named = 0 };
    var waited: u32 = 0;
    while (waited <= timeout_ms) : (waited += 200) {
        const kids = os.children(host_pid, &buf);
        state = .{ .total = kids.len, .sandboxed = 0, .named = 0 };
        for (kids) |pid| {
            if (os.sandbox_check(pid, null, 0) == 1) state.sandboxed += 1;
            if (std.mem.endsWith(u8, os.executablePath(pid, &path_buf), "/maru-web-helper")) state.named += 1;
        }
        if (state.all(min)) return state;
        os.sleepMs(200);
    }
    return state;
}
