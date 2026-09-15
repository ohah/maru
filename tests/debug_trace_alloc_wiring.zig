//! std 의 **스택 트레이스 포획 할당자 덮어쓰기**가 루트에 실제로 붙어 있는지 본다.
//!
//! `std/debug.zig` 의 `getDebugInfoAllocator` 는 `@hasDecl(root, "debug")` 로만 우리 것을 집는다.
//! 즉 `src/main.zig` 에서 `pub const debug` 가 사라지면 std 는 **조용히** 기본값(전역 아레나)으로
//! 돌아간다 — 컴파일도 되고 테스트도 다 초록인데, 세션 host 메모리만 다시 단조 증가한다
//! (실측: 같은 부하에서 525 MB 대 7.5 MB). 그 되돌림을 잡을 자가 여기밖에 없다.
//!
//! `src/debug_trace_alloc.zig` 의 판정자는 「그 할당자가 되돌려받는가」를 보고, 이 판정자는
//! 「그 할당자가 std 에 꽂혀 있는가」를 본다. 둘 다 있어야 한 줄이 된다.
const std = @import("std");

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(8 << 20));
}

/// 주석 줄은 뺀다 — 설명문에 적힌 한 줄이 판정을 뒤집으면 안 된다(`png_codec_wiring.zig` 와 같은 이유).
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

test "루트가 std 의 트레이스 할당자 자리를 덮는다" {
    const src = try readSource(std.testing.allocator, "src/main.zig");
    defer std.testing.allocator.free(src);

    // std 가 보는 이름 그대로여야 한다. `debug` 도 `getDebugInfoAllocator` 도 이름이 계약이다.
    try std.testing.expectEqual(@as(usize, 1), countOutsideComments(src, "pub const debug = struct {"));
    try std.testing.expectEqual(@as(usize, 1), countOutsideComments(src, "pub const getDebugInfoAllocator = maru.debug_trace_alloc.allocator;"));
}

test "덮어쓴 할당자는 아레나가 아니다" {
    const src = try readSource(std.testing.allocator, "src/debug_trace_alloc.zig");
    defer std.testing.allocator.free(src);

    // 누수의 정체가 아레나였다. 여기로 아레나가 돌아오면 덮어쓰기는 있으나 마나다 —
    // 이름만 갈아 끼운 되돌림을 잡는다.
    try std.testing.expectEqual(@as(usize, 0), countOutsideComments(src, "ArenaAllocator = .init(std.heap.page_allocator)"));
    try std.testing.expect(countOutsideComments(src, "return std.heap.smp_allocator;") == 1);
}
