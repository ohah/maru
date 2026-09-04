const std = @import("std");

// 컨트롤 축의 **정책이 코어에 있다**는 것을 «구조로» 못 박는다.
//
// **왜 있나.** 순서·가드·분류·마감이 두 host 의 C/ObjC tick 안에 있었고, 그래서 iOS 가 열기를
// 닫기보다 먼저 해 「열고 그 자리에서 닫기」를 무한히 되풀이했다 — 컨트롤 채널이 opening↔closed
// 로 진동하고 아무 세션도 안 떴는데 **판정자는 내내 초록이었다**(실기 2026-09-04). 그 정책을
// `mobile_bridge.zig` 로 올렸으니, 다시 host 로 새는 것을 여기서 막는다.
//
// 값 판정(순서·마감이 실제로 그렇게 도는가)은 `mobile_bridge_contract.zig` 의 「정책:」 판정자가
// 한다. **여기가 세는 것은 «자리»** 다.

test "정책 경계: 두 host 는 행동을 «받아서 실행만» 한다 — 순서를 스스로 정하지 않는다" {
    const allocator = std.testing.allocator;
    const ios = try readSource(allocator, "src/platform/ios/ios_app_host.m");
    defer allocator.free(ios);
    const android = try readSource(allocator, "src/platform/android/android_app_host.c");
    defer allocator.free(android);

    for ([_][]const u8{ ios, android }) |host| {
        // 행동을 묻는 자리는 **한 곳**이다. 둘이 되면 한 tick 에 두 행동이 나갈 수 있다.
        try std.testing.expectEqual(@as(usize, 1), count(host, "maru_mobile_control_tick("));
        // 열기 결과의 분류도 코어가 한다 — host 는 「포기했나」만 보고 찍는다.
        try std.testing.expectEqual(@as(usize, 1), count(host, "maru_mobile_control_note_open("));

        // **host 가 순서를 정하던 자리들이 없어야 한다.** 하나라도 살아 있으면 그 tick 이
        // 코어가 정한 행동 말고 제 판단으로 움직인다는 뜻이다.
        try std.testing.expectEqual(@as(usize, 0), count(host, "maru_mobile_take_control_open"));
        try std.testing.expectEqual(@as(usize, 0), count(host, "maru_mobile_take_control_close"));
        // 마감을 host 가 세던 자리(시계 전역 + 5초 상수)도 없어야 한다 — 그것이 있으면 헤드리스
        // 판정자가 시간을 못 넣어 그 갈래가 통째로 안 덮인다.
        try std.testing.expectEqual(@as(usize, 0), count(host, "> 5000"));
        try std.testing.expectEqual(@as(usize, 0), count(host, "maru_mobile_control_open_retry"));
        try std.testing.expectEqual(@as(usize, 0), count(host, "maru_mobile_control_timeout"));
        // `MARU_SSH_ERR_NOT_READY` 분류도 코어 것이다.
        try std.testing.expectEqual(@as(usize, 0), count(host, "MARU_SSH_ERR_NOT_READY"));
    }
}

test "정책 경계: 코어가 베낀 ABI 상수는 헤더와 같은 값이다" {
    // 브리지는 `MARU_SSH_CONTROL_*` 와 `MARU_SSH_ERR_NOT_READY` 를 **값으로** 안다(Zig 는 그
    // 헤더를 안 읽는다). 갈리면 정책이 조용히 틀린 상태를 보고, 증상은 「세션이 안 열린다」다 —
    // 이 축이 이미 그 모양으로 한 번 죽었다. 그래서 **헤더 원문과 대조한다.**
    const allocator = std.testing.allocator;
    const header = try readSource(allocator, "src/platform/mobile/mobile_host_abi.h");
    defer allocator.free(header);
    const bridge = try readSource(allocator, "src/platform/mobile/mobile_bridge.zig");
    defer allocator.free(bridge);

    try expectPair(header, bridge, "#define MARU_SSH_CONTROL_NONE ", "const ssh_control_none: u32 = ");
    try expectPair(header, bridge, "#define MARU_SSH_CONTROL_CLOSED ", "const ssh_control_closed: u32 = ");
    try expectPair(header, bridge, "#define MARU_SSH_ERR_NOT_READY ", "const ssh_err_not_ready: c_int = ");

    // 행동 상수도 두 자리에 산다(헤더의 `#define` 과 Zig 의 `enum`). 그 셋이 짝이어야 host 의
    // `switch` 가 코어의 뜻과 같은 것을 가리킨다.
    try std.testing.expectEqual(@as(usize, 1), count(header, "#define MARU_MOBILE_CONTROL_ACTION_NONE 0"));
    try std.testing.expectEqual(@as(usize, 1), count(header, "#define MARU_MOBILE_CONTROL_ACTION_CLOSE 1"));
    try std.testing.expectEqual(@as(usize, 1), count(header, "#define MARU_MOBILE_CONTROL_ACTION_OPEN 2"));
    try std.testing.expectEqual(@as(usize, 1), count(bridge, "none = 0,"));
    try std.testing.expectEqual(@as(usize, 1), count(bridge, "close = 1,"));
    try std.testing.expectEqual(@as(usize, 1), count(bridge, "open = 2,"));
}

/// 헤더의 `#define <name> <v>` 와 Zig 의 `const <name>: T = <v>` 가 같은 값인가.
/// **괄호는 벗긴다** — C 는 음수를 `(-7)` 로 적는다.
fn expectPair(header: []const u8, bridge: []const u8, c_prefix: []const u8, zig_prefix: []const u8) !void {
    const c_val = try valueAfter(header, c_prefix);
    const zig_val = try valueAfter(bridge, zig_prefix);
    try std.testing.expectEqualStrings(std.mem.trim(u8, c_val, "()"), std.mem.trim(u8, zig_val, "();"));
}

/// `prefix` 뒤 그 줄의 나머지(공백 제거). 없으면 **오류** — 조용히 통과하지 않는다.
fn valueAfter(haystack: []const u8, prefix: []const u8) ![]const u8 {
    const at = std.mem.indexOf(u8, haystack, prefix) orelse return error.PrefixMissing;
    const rest = haystack[at + prefix.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
    return std.mem.trim(u8, rest[0..end], " \t\r");
}

fn count(haystack: []const u8, needle: []const u8) usize {
    var total: usize = 0;
    var rest = haystack;
    while (std.mem.indexOf(u8, rest, needle)) |at| {
        total += 1;
        rest = rest[at + needle.len ..];
    }
    return total;
}

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![:0]u8 {
    return std.Io.Dir.cwd().readFileAllocOptions(
        std.testing.io,
        path,
        allocator,
        .limited(16 * 1024 * 1024),
        .of(u8),
        0,
    );
}
