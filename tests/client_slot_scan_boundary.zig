//! `client_slot.zig` 의 두 전역 레지스트리(4096 항목)를 **값으로 순회하는 `for` 가 다시 생기지 않게** 센다.
//!
//! `for (client_slot_registry) |entry|` 는 배열 값을 순회하므로 컴파일러가 192 KiB 를 스택으로 `memcpy` 한 뒤
//! 돈다. 그 스캔이 `beginRegisteredNodeOperation` 안에 있어 runtime 마다 tick 마다 여러 번 돌았고, 32 세션 idle
//! 에서 앱 메인 스레드의 가장 큰 항목이 그 memcpy 였다(2026-09-20 실측 — `sample` 의 `<deduplicated_symbol>`
//! 이 `compiler_rt.memcpy` 였다; 이미지 부하 프로파일의 «미해석 29%» 도 같은 것이었다). 포인터 순회
//! (`for (&…) |*entry|`)로 바꾸자 그 잎이 408 → 10 표본, 프레임 tick 이 8.0% → 3.7% 로 줄었다.
//!
//! 판정은 문자열이다 — 이 결함은 타입도 판정자도 못 잡고 프로파일에서만 보인다. 값 순회 한 줄이 되살아나면
//! 여기서 빨개진다.
const std = @import("std");

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(8 << 20));
}

/// 주석 줄은 뺀다 — 설명문 한 줄이 판정을 뒤집으면 안 된다.
fn countOutsideComments(text: []const u8, needle: []const u8) usize {
    var total: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "//")) continue;
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, line, from, needle)) |at| {
            total += 1;
            from = at + needle.len;
        }
    }
    return total;
}

test "client_slot 의 전역 레지스트리는 값이 아니라 포인터로 순회한다" {
    const src = try readSource(std.testing.allocator, "src/platform/macos/session_host/client_slot.zig");
    defer std.testing.allocator.free(src);
    // 값 순회 0 — 그리고 포인터 순회가 실제로 있다(양성 대조: 배열 이름이 바뀌어 둘 다 0 이면 공허하다).
    try std.testing.expectEqual(@as(usize, 0), countOutsideComments(src, "for (client_slot_registry) |"));
    try std.testing.expectEqual(@as(usize, 0), countOutsideComments(src, "for (registered_node_operations) |"));
    try std.testing.expect(countOutsideComments(src, "for (&client_slot_registry) |*entry|") >= 4);
    try std.testing.expect(countOutsideComments(src, "for (&registered_node_operations) |*entry|") >= 1);
}
