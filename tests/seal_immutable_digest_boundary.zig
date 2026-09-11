//! **캐시한 다이제스트가 상하지 않는다**를 못 박는다.
//!
//! ## 무엇을 고쳤나
//!
//! 2026-09-11 실측 — 터미널 브라우저가 렌더링하는 동안 maru 주 스레드 작업의 24 % 가 BLAKE3 였고,
//! 그 진입 799 샘플을 부모별로 가르니 `PreparationFrame.sealInput` 이 312 (39 %) 로 1 위였다.
//! 한 번 불릴 때마다 고정 크기 구조체 5,816 B 를 통째로 해싱한다:
//!
//!     recipe 2,944 B · snapshot 1,152 B · protected_ranges 1,016 B · scratch 656 B · allocator_context 48 B
//!
//! 그런데 `recipe` 와 `snapshot` 은 `beginPreparationFrame` 에서 **딱 한 번** 대입된 뒤 읽기만 한다.
//! 즉 `seal()` 이 불리는 준비 경로 9 곳에서 매번 **4,096 B (70 %) 를 「바뀔 수 없는 값」에 쓰고 있었다.**
//!
//! ## 왜 이 판정자가 수정보다 중요한가
//!
//! 캐싱 자체는 무결성을 조금도 약화시키지 않는다 — 씰이 덮는 바이트가 완전히 동일하다. **위험은 딱
//! 하나**, 나중에 누가 `snapshot`·`recipe` 를 변경하는 것이다. 그 순간 캐시는 옛 값이 되고, 씰은
//! 조용히 엉뚱한 바이트를 덮는다. 드리프트 감지를 위해 존재하는 씰이 드리프트를 감추게 된다.
//!
//! 그래서 두 겹으로 막는다.
//!   ① 여기: 두 필드에 대한 **문법적 대입이 생성 지점 하나뿐**임을 소스로 고정한다.
//!   ② 제품 코드: debug·test 빌드에서 `sealInput` 이 **실제로 다시 계산해 대조**한다 — `@memcpy` 나
//!      포인터 경유 변경처럼 ①이 못 보는 경로까지 닫는다. ReleaseFast 에는 남지 않는다.
//!
//! 둘 중 하나라도 사라지면 이 캐싱은 안전하지 않다.

const std = @import("std");

const source_path = "src/platform/macos/session_host/pending_event_preparation.zig";
const max_source_bytes = 16 * 1024 * 1024;

fn read(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(max_source_bytes));
}

/// 줄 주석을 벗긴다 — 위 머리말이 옛 모습을 그대로 인용하므로, 벗기지 않으면 「설명하는 주석」이
/// 「쓰는 코드」로 세어진다.
fn stripComments(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |line| {
        const keep = if (std.mem.indexOf(u8, line, "//")) |at| line[0..at] else line;
        try out.appendSlice(allocator, keep);
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

fn countOutsideTests(src: []const u8, needle: []const u8) usize {
    // 테스트 블록은 프레임을 손으로 조립하므로 제품 계약에서 뺀다.
    const tests_at = std.mem.indexOf(u8, src, "\ntest \"") orelse src.len;
    const product = src[0..tests_at];
    var seen: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, product, at, needle)) |found| : (at = found + needle.len) seen += 1;
    return seen;
}

test "캐시한 씰 다이제스트: 불변 필드는 한 번만 쓰이고, debug 빌드가 값으로 대조한다" {
    const a = std.testing.allocator;
    const raw = try read(a, source_path);
    defer a.free(raw);
    const src = try stripComments(a, raw);
    defer a.free(src);

    // ① **대입은 생성 지점 하나뿐.** 두 번째가 생기면 캐시가 상한다.
    for ([_][]const u8{ "frame.snapshot = ", "frame.recipe = " }) |assign| {
        const seen = countOutsideTests(src, assign);
        if (seen != 1) {
            std.debug.print(
                "«{s}» 가 제품 코드에 {d} 번 — 1 번이어야 캐시가 유효하다\n",
                .{ assign, seen },
            );
            return error.ImmutableFieldReassigned;
        }
    }
    // `self.snapshot = ` / `self.recipe = ` 로 우회하는 것도 막는다.
    for ([_][]const u8{ "self.snapshot = ", "self.recipe = " }) |assign|
        try std.testing.expect(countOutsideTests(src, assign) == 0);

    // ② 캐시는 생성 지점에서 채워진다.
    try std.testing.expect(std.mem.indexOf(u8, src, "frame.snapshot_digest_cache = rawDigest(") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "frame.recipe_digest_cache = rawDigest(") != null);

    // ③ `sealInput` 은 **다시 해싱하지 않는다** — 이 fix 가 없애려던 비용이 되살아나면 빨개진다.
    const seal_at = std.mem.indexOf(u8, src, "fn sealInput(self: *const PreparationFrame)") orelse
        return error.SealInputMissing;
    const seal_end = std.mem.indexOfPos(u8, src, seal_at, "\n    }\n") orelse src.len;
    const seal_body = src[seal_at..seal_end];
    try std.testing.expect(std.mem.indexOf(u8, seal_body, "std.mem.asBytes(&self.snapshot)") == null);
    try std.testing.expect(std.mem.indexOf(u8, seal_body, "std.mem.asBytes(&self.recipe)") == null);
    try std.testing.expect(std.mem.indexOf(u8, seal_body, "self.cachedSnapshotDigest()") != null);
    try std.testing.expect(std.mem.indexOf(u8, seal_body, "self.cachedRecipeDigest()") != null);

    // ④ **debug·test 는 값으로 대조한다.** ①은 문법적 대입만 보므로 `@memcpy`·포인터 경유 변경을
    //    못 본다. 이 대조가 그 구멍을 닫는다 — 없으면 캐싱이 안전하지 않다.
    for ([_][]const u8{ "fn cachedSnapshotDigest(", "fn cachedRecipeDigest(" }) |fn_name| {
        const at = std.mem.indexOf(u8, src, fn_name) orelse return error.CachedAccessorMissing;
        const end = std.mem.indexOfPos(u8, src, at, "\n    }\n") orelse src.len;
        const body = src[at..end];
        if (std.mem.indexOf(u8, body, "builtin.mode == .Debug") == null or
            std.mem.indexOf(u8, body, "builtin.is_test") == null or
            std.mem.indexOf(u8, body, "rawDigest(") == null or
            std.mem.indexOf(u8, body, "fatalIntegrity") == null)
        {
            std.debug.print("«{s}» 에 debug 재계산 대조가 없다 — 캐시가 조용히 상할 수 있다\n", .{fn_name});
            return error.DriftCheckMissing;
        }
    }

    // ⑤ 캐시와 대조가 **같은 도메인 상수**를 쓴다. 리터럴이 흩어지면 한쪽만 바꿨을 때 어긋난다.
    try std.testing.expect(std.mem.indexOf(u8, src, "const snapshot_digest_domain = ") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "const recipe_digest_domain = ") != null);
    try std.testing.expect(countOutsideTests(src, "\"maru.pending-frame.snapshot.v1\"") == 1);
    try std.testing.expect(countOutsideTests(src, "\"maru.pending-frame.recipe.v1\"") == 1);
}
