//! **캐시한 `recipe` 다이제스트가 상하지 않는다**를 못 박는다.
//!
//! ## 왜 캐시해도 되는가 — 측정으로 얻은 전제
//!
//! `recipe` 는 `sealInput` 구조체 해싱의 **51 %**(2,944 B × 호출 수)였다. 유휴 2.27 MB/초,
//! 브라우저 부하 **33 MB/초** 중 절반이다(#3574 자리별 실측).
//!
//! #3557 은 `snapshot` 과 `recipe` 를 **함께** 캐시했다가 debug 재계산 대조가 `fatalIntegrity`(exit 86)로
//! 잡아 닫혔다. 그런데 **둘을 묶어 검사해 어느 쪽이 바뀌는지는 안 갈렸다.** #3581 이 `recipe` 하나만
//! 탐침으로 걸었고, `keep-alive recovered session macOS` 스모크와 Debug 전체 테스트가 **통과했다** —
//! 바뀌던 것은 `snapshot` 이었다.
//!
//! ## 왜 이 판정자가 최적화보다 중요한가
//!
//! 불변은 **지금** 참일 뿐이다. 나중에 누가 `recipe` 를 변경 가능하게 만들면 캐시가 옛 값이 되고 씰은
//! 조용히 엉뚱한 바이트를 덮는다 — 드리프트를 잡으라고 있는 씰이 드리프트를 감춘다.
//!
//! 두 겹으로 막는다.
//!   ① 여기: `recipe` 에 대한 **문법적 대입이 생성 지점 하나뿐**임을 소스로 고정한다.
//!   ② 제품 코드: debug·test 에서 **실제로 다시 계산해 대조**한다 — ①이 못 보는 `@memcpy`·포인터 경유
//!      변경까지 닫는다. ReleaseFast 에는 남지 않아 이 최적화가 되살아나지 않는다.
//!
//! 둘 중 하나라도 사라지면 이 캐싱은 안전하지 않다.

const std = @import("std");

const source_path = "src/platform/macos/session_host/pending_event_preparation.zig";
const max_source_bytes = 16 * 1024 * 1024;

fn read(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(max_source_bytes));
}

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
    const tests_at = std.mem.indexOf(u8, src, "\ntest \"") orelse src.len;
    const product = src[0..tests_at];
    var seen: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, product, at, needle)) |found| : (at = found + needle.len) seen += 1;
    return seen;
}

test "캐시한 recipe 다이제스트: 대입은 한 번뿐이고 debug 가 값으로 대조한다" {
    const a = std.testing.allocator;
    const raw = try read(a, source_path);
    defer a.free(raw);
    const src = try stripComments(a, raw);
    defer a.free(src);

    // ① **대입은 생성 지점 하나뿐.** 두 번째가 생기면 캐시가 상한다.
    const assigns = countOutsideTests(src, "frame.recipe = ");
    if (assigns != 1) {
        std.debug.print("«frame.recipe = » 가 제품 코드에 {d} 번 — 1 번이어야 캐시가 유효하다\n", .{assigns});
        return error.RecipeReassigned;
    }
    // `self.recipe = ` 로 우회하는 것도 막는다.
    try std.testing.expect(countOutsideTests(src, "self.recipe = ") == 0);

    // ② 캐시는 생성 지점에서 채워진다.
    try std.testing.expect(std.mem.indexOf(u8, src, "frame.recipe_digest_cache = rawDigest(") != null);

    // ③ `sealInput` 은 **다시 해싱하지 않는다** — 이 최적화가 되살아나면 빨개진다.
    const seal_at = std.mem.indexOf(u8, src, "fn sealInput(self: *const PreparationFrame)") orelse
        return error.SealInputMissing;
    const seal_end = std.mem.indexOfPos(u8, src, seal_at, "\n    }\n") orelse src.len;
    const seal_body = src[seal_at..seal_end];
    try std.testing.expect(std.mem.indexOf(u8, seal_body, "std.mem.asBytes(&self.recipe)") == null);
    try std.testing.expect(std.mem.indexOf(u8, seal_body, "self.recipeDigestChecked()") != null);

    // ④ **debug·test 는 값으로 대조한다.** ①은 문법적 대입만 보므로 `@memcpy`·포인터 경유 변경을 못 본다.
    const fn_at = std.mem.indexOf(u8, src, "fn recipeDigestChecked(") orelse return error.AccessorMissing;
    const fn_end = std.mem.indexOfPos(u8, src, fn_at, "\n    }\n") orelse src.len;
    const body = src[fn_at..fn_end];
    for ([_][]const u8{ "builtin.mode == .Debug", "builtin.is_test", "rawDigest(", "fatalIntegrity" }) |needle| {
        if (std.mem.indexOf(u8, body, needle) == null) {
            std.debug.print("recipeDigestChecked 에 «{s}» 이 없다 — 캐시가 조용히 상할 수 있다\n", .{needle});
            return error.DriftCheckMissing;
        }
    }
    // ⑤ **ReleaseFast 에는 재계산이 없어야** 이 최적화가 의미를 갖는다 — 대조가 가드 밖으로 나가면 빨개진다.
    const guard_at = std.mem.indexOf(u8, body, "if (builtin.mode == .Debug") orelse return error.DriftCheckMissing;
    const hash_at = std.mem.indexOf(u8, body, "rawDigest(") orelse return error.DriftCheckMissing;
    try std.testing.expect(guard_at < hash_at);
}
