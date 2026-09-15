//! 세션 host 데몬이 쓸 **범용 할당자를 고른다** — 기본은 「스택 포획 없는 DebugAllocator」.
//!
//! Debug 빌드에서 std 가 주는 `init.gpa` 는 `DebugAllocator(.{})` 이고, 그것은 **할당·해제마다** 6 프레임을
//! 포획한다(`stack_trace_frames` 기본값). 포획 한 번은 DWARF CFI 를 가상머신으로 해석하는 일이라 수십 µs 이고,
//! 화면 델타를 만들 때마다 수천 번 일어난다. 실측(2026-09-15, 480×300 PNG 8 fps): host CPU 가 포획 켬 ~50%,
//! 끔 14%, ReleaseFast 1.1%. 스택 12 단 깊이의 단독 벤치로는 alloc+free 한 쌍이 frames=6 에서 24,349 ns,
//! frames=0 에서 1,488 ns, `smp_allocator` 에서 83 ns.
//!
//! 그래서 **기본은 포획을 끈다.** `stack_trace_frames = 0` 이어도 누수 «탐지» 는 그대로다 — 자연 종료 때
//! 샌 주소와 크기를 보고하고 `deinit()` 이 `.leak` 을 돌려준다. 잃는 것은 «어느 줄이 할당했는가» 하나이고,
//! 그것은 `MARU_ALLOC_TRACES=1` 로 앱을 띄우면 돌아온다(host 는 앱의 environ 을 통째로 물려받는다 —
//! `launcher.zig` 가 거르는 이름은 test 용 8 개와 root/readiness 뿐이다). 구성이 comptime 이라 돌아가는
//! 프로세스에서 토글할 수는 없다 — «켜고 다시 띄운다» 다.
//!
//! **왜 std 의 `init.gpa` 를 그대로 두는가.** std 의 gpa 가 호스트에서 맡는 할당은 `environ_map` 한 번과
//! `Io.Threaded` 의 `async`·batch poll·mmap 경로뿐인데, 호스트는 그 셋을 하나도 안 탄다(poll/read 는 libc
//! 직접 호출). 즉 뜨거운 할당은 전부 데몬에 넘기는 이 할당자를 지나므로 `main` 을 뜯을 이유가 없다.
//!
//! **deinit 은 우리가 부른다.** std 는 자기 gpa 만 `deinit` 하므로, 이 할당자의 누수 보고는 데몬이 돌아온
//! 뒤 우리가 `deinit` 해야 나온다. 그 보고가 프로세스를 죽이지 않는 것은 `std_environ_view` 가 보장한다
//! (그 고침 전에는 첫 `std.log` 가 곧 크래시라 보고가 한 줄도 못 나왔다).
const std = @import("std");
const builtin = @import("builtin");

pub const env_name: [:0]const u8 = "MARU_ALLOC_TRACES";

/// 기본: 포획 없음. 누수 탐지·주소·크기는 그대로.
var quiet: std.heap.DebugAllocator(.{ .stack_trace_frames = 0 }) = .init;
/// `MARU_ALLOC_TRACES=1`: std 기본값과 같은 6 프레임 포획. 누수의 할당 자리를 짚는다.
var traced: std.heap.DebugAllocator(.{}) = .init;

pub const Choice = enum { quiet, traced };

/// 값이 있고 첫 글자가 `0` 이 아니면 켠 것으로 본다. 없거나 비었거나 `0…` 이면 끈 것.
pub fn choiceForValue(value: ?[]const u8) Choice {
    const v = value orelse return .quiet;
    if (v.len == 0 or v[0] == '0') return .quiet;
    return .traced;
}

pub fn choiceFromEnvironment() Choice {
    const raw = std.c.getenv(env_name.ptr) orelse return .quiet;
    return choiceForValue(std.mem.span(raw));
}

pub const Selected = struct {
    choice: Choice,
    allocator: std.mem.Allocator,

    /// 데몬이 돌아온 뒤 **반드시** 부른다 — 누수 보고는 여기서 나온다.
    pub fn deinit(self: Selected) std.heap.Check {
        return switch (self.choice) {
            .quiet => quiet.deinit(),
            .traced => traced.deinit(),
        };
    }
};

pub fn select(choice: Choice) Selected {
    return .{
        .choice = choice,
        .allocator = switch (choice) {
            .quiet => quiet.allocator(),
            .traced => traced.allocator(),
        },
    };
}

test "env 값 해석: 없음·빔·0 은 조용, 그 밖은 포획" {
    try std.testing.expectEqual(Choice.quiet, choiceForValue(null));
    try std.testing.expectEqual(Choice.quiet, choiceForValue(""));
    try std.testing.expectEqual(Choice.quiet, choiceForValue("0"));
    try std.testing.expectEqual(Choice.quiet, choiceForValue("0abc"));
    try std.testing.expectEqual(Choice.traced, choiceForValue("1"));
    try std.testing.expectEqual(Choice.traced, choiceForValue("yes"));
}

// 「frames=0 이어도 누수를 탐지한다」는 리포 안에서 테스트하지 않는다 — 그 판정은 일부러 누수를 내야
// 하고, DebugAllocator 가 그것을 `std.log.err` 로 보고하면 러너가 «errors were logged» 로 실패시킨다.
// 그 성질은 std 의 것이고 독립 프로브로 확인했다(주소·크기 보고, `deinit() == .leak`, 스택만 빔).
test "select 는 고른 쪽의 할당자를 주고 deinit 은 같은 쪽을 닫는다" {
    // 전역 인스턴스를 실제로 쓰되, 알갱이 하나를 잡았다 놓아 .ok 로 끝낸다 — 다른 테스트를 오염시키지 않는다.
    const q = select(.quiet);
    const p = try q.allocator.alloc(u8, 16);
    q.allocator.free(p);
    try std.testing.expectEqual(std.heap.Check.ok, q.deinit());
    const t = select(.traced);
    const p2 = try t.allocator.alloc(u8, 16);
    t.allocator.free(p2);
    try std.testing.expectEqual(std.heap.Check.ok, t.deinit());
}
