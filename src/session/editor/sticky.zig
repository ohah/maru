//! sticky scroll 의 **고정할 줄 고르기**(docs/native-editor-visual-mapping.md §4.1i) — 순수 계산.
//!
//! 스코프 목록(머리줄·끝 줄, 머리줄 오름차순 · 같으면 끝 내림차순)과 **줄 → 화면 행** 두 함수를 받아, 위에서부터 칸마다 설 머리줄을
//! 고른다. 깊이 `d` 인 후보는 칸 `d` 에 서는데 **머리줄의 행 < d ≤ (끝 줄 − 1) 의 마지막 행** 일 때만이다 — 머리줄이 그 칸보다 위로
//! 올라갔고, 스코프의 마지막 본문 줄이 아직 그 칸에 닿아 있다. 닫는 줄(`}`)에 이르면 떨어진다.
//!
//! 이 모듈은 접힘·줄바꿈을 모른다 — 두 함수가 그것을 안다(숨은 줄은 `null`, 랩된 줄의 마지막 행). 어느 출처(심볼·접힘)의 스코프인지도
//! 모른다.
const std = @import("std");

/// 스코프 하나 — 문서 줄(0-based). `end` 는 스코프의 **마지막 줄**(닫는 줄 포함)이다.
pub const Scope = struct { head: u32, end: u32 };

/// 설정이 허락하는 줄 수의 상한(`editor.sticky-scroll-max-lines` 의 range 와 같다).
pub const max_lines_cap: usize = 10;

/// 고정할 머리줄을 `out` 에 바깥부터 담는다(최대 `max`). `scopes` 는 머리줄 오름차순 · 같으면 끝 내림차순이어야 한다.
///
/// `rows` 는 두 메서드를 가진 값이다:
///   - `headRow(line: u32) ?i64` — 그 줄 **첫 조각**의 화면 행(맨 위가 0, 위로 올라간 줄은 음수). 숨은 줄이면 `null`.
///   - `lastRow(line: u32) ?i64` — 그 줄 **이하**에서 마지막으로 보이는 줄의 **마지막 조각** 행. 보이는 줄이 없으면 `null`.
pub fn select(
    allocator: std.mem.Allocator,
    scopes: []const Scope,
    rows: anytype,
    max: usize,
    out: *std.ArrayList(u32),
) error{OutOfMemory}!void {
    out.clearRetainingCapacity();
    if (max == 0) return;
    var stack: std.ArrayList(Scope) = .empty;
    defer stack.deinit(allocator);
    for (scopes) |s| {
        if (s.end < s.head +| 2) continue; // 세 줄 이상만(§4.1i — VS Code `end > start + 1`)
        // 품지 않는 조상은 내린다 — 스택에는 지금 스코프를 품는 사슬만 남는다.
        while (stack.items.len > 0) {
            const top = stack.items[stack.items.len - 1];
            if (top.head <= s.head and s.end <= top.end) break;
            _ = stack.pop();
        }
        // 머리줄이 부모와 같은 중첩은 바깥 하나만(같은 줄을 두 칸에 세우지 않는다).
        if (stack.items.len > 0 and stack.items[stack.items.len - 1].head == s.head) continue;
        const d = stack.items.len;
        try stack.append(allocator, s);
        // 조상 칸이 안 섰다 — 이 깊이는 설 수 없다. **오늘 등가다**(적대적 1회차 S4): 부모가 안 선 까닭(마지막 본문 줄이 칸 위로 갔다 ·
        // 머리줄이 숨었다)은 품긴 자식에게도 그대로라 자식도 칸 조건을 못 맞춘다. 뜻으로 둔다(바깥이 없는 안쪽은 세우지 않는다).
        if (d != out.items.len) continue;
        const hr = rows.headRow(s.head) orelse continue; // 머리줄이 숨었다(접힌 스코프 안)
        // **머리줄이 아직 칸 d 에 안 올라왔다** — 뒤의 스코프는 머리줄이 더 아래라(오름차순) 칸 조건을 더 못 맞춘다: 멈춘다. 결과에는 등가
        // (적대적 1회차 S6 — `continue` 로 바꿔도 뒤가 안 선다), 비용의 길이다.
        if (hr >= @as(i64, @intCast(d))) break;
        const lr = rows.lastRow(s.end - 1) orelse continue;
        if (@as(i64, @intCast(d)) <= lr) {
            try out.append(allocator, s.head);
            if (out.items.len >= max) break;
        }
    }
}

/// 스코프 목록을 `select` 가 요구하는 순서로 맞춘다(머리줄 오름차순 · 같으면 끝 내림차순 — 바깥이 먼저).
pub fn sortScopes(scopes: []Scope) void {
    std.mem.sort(Scope, scopes, {}, struct {
        fn lt(_: void, a: Scope, b: Scope) bool {
            if (a.head != b.head) return a.head < b.head;
            return a.end > b.end;
        }
    }.lt);
}

/// 보이는 행 수에서 설 수 있는 줄 수 — `min(설정, round(행 × 0.25))`(§4.1i — VS Code 의 25% 규칙).
pub fn maxLines(setting: u32, visible_rows: usize) usize {
    const quarter = (visible_rows + 2) / 4; // round(v / 4)
    return @min(@min(@as(usize, setting), max_lines_cap), quarter);
}

const testing = std.testing;

/// 판정자용 행 함수 — 줄바꿈 없음, 맨 위 줄 `top`, `hidden` 줄은 숨음, `pieces` 는 줄마다 조각 수(없으면 1).
const TestRows = struct {
    top: u32,
    /// 맨 위 줄 안에서 이미 올라간 조각 수(§4.1d 의 조각 오프셋).
    first_piece: i64 = 0,
    hidden: []const u32 = &.{},
    wrap: []const struct { line: u32, pieces: u32 } = &.{},

    fn isHidden(self: TestRows, line: u32) bool {
        for (self.hidden) |h| if (h == line) return true;
        return false;
    }
    fn piecesOf(self: TestRows, line: u32) i64 {
        for (self.wrap) |w| if (w.line == line) return w.pieces;
        return 1;
    }
    /// 보이는 줄만 세어 `top` 에서의 행 거리(조각 포함).
    fn rowOfFirst(self: TestRows, line: u32) i64 {
        var r: i64 = 0;
        if (line >= self.top) {
            var l = self.top;
            while (l < line) : (l += 1) {
                if (!self.isHidden(l)) r += self.piecesOf(l);
            }
        } else {
            var l = line;
            while (l < self.top) : (l += 1) {
                if (!self.isHidden(l)) r -= self.piecesOf(l);
            }
        }
        return r - self.first_piece;
    }
    pub fn headRow(self: TestRows, line: u32) ?i64 {
        if (self.isHidden(line)) return null;
        return self.rowOfFirst(line);
    }
    pub fn lastRow(self: TestRows, line: u32) ?i64 {
        var l = line;
        while (self.isHidden(l)) {
            if (l == 0) return null;
            l -= 1;
        }
        return self.rowOfFirst(l) + self.piecesOf(l) - 1;
    }
};

fn pick(scopes: []const Scope, rows: TestRows, max: usize) ![]u32 {
    var out: std.ArrayList(u32) = .empty;
    errdefer out.deinit(testing.allocator);
    try select(testing.allocator, scopes, rows, max, &out);
    return out.toOwnedSlice(testing.allocator);
}

test "STK1 칸 규칙 — 머리줄이 칸보다 위로 올라가고 마지막 본문 줄이 그 칸에 닿아 있을 때만, 바깥부터 (§4.1i)" {
    // 0 class A {        ← [0, 20]
    // 2   fn f() {       ← [2, 10]
    // 4     if (x) {     ← [4, 8]
    // 10  }
    // 12  fn g() {       ← [12, 18]
    // 20 }
    const scopes = [_]Scope{ .{ .head = 0, .end = 20 }, .{ .head = 2, .end = 10 }, .{ .head = 4, .end = 8 }, .{ .head = 12, .end = 18 } };
    // 맨 위가 0 — 머리줄이 칸 0 에 있다(아직 안 올라갔다): 아무것도 안 선다.
    try expectPicks(&scopes, .{ .top = 0 }, 5, &.{});
    // 맨 위가 1 — class 머리줄(행 −1)이 칸 0 위로: class 가 선다. fn f 머리줄은 행 1 — 칸 1 에 아직 안 올라왔다.
    try expectPicks(&scopes, .{ .top = 1 }, 5, &.{0});
    // 맨 위가 5 — class(칸 0) · fn f(행 −3 < 1) · if(행 −1 < 2, 끝−1=7 → 행 2 ≥ 2) 셋.
    try expectPicks(&scopes, .{ .top = 5 }, 5, &.{ 0, 2, 4 });
    // 맨 위가 6 — if 의 마지막 본문 줄(7)이 행 1 — 칸 2 에 안 닿는다: if 는 떨어진다.
    try expectPicks(&scopes, .{ .top = 6 }, 5, &.{ 0, 2 });
    // 맨 위가 9 — fn f 의 마지막 본문 줄(9)이 행 0 — 칸 1 에 안 닿는다: class 만.
    try expectPicks(&scopes, .{ .top = 9 }, 5, &.{0});
    // 맨 위가 14 — class · fn g.
    try expectPicks(&scopes, .{ .top = 14 }, 5, &.{ 0, 12 });
    // 상한 — 둘까지만.
    try expectPicks(&scopes, .{ .top = 5 }, 2, &.{ 0, 2 });
}

test "STK2 세 줄 미만은 후보가 아니고, 머리줄이 같은 중첩은 바깥 하나만 (§4.1i)" {
    // [0,1] 은 두 줄 — 후보 아님. [3, 20] 과 [3, 15] 는 머리줄이 같다 — 바깥 하나만, 안쪽의 자식 [5, 12] 는 그 아래 칸.
    const scopes = [_]Scope{ .{ .head = 0, .end = 1 }, .{ .head = 3, .end = 20 }, .{ .head = 3, .end = 15 }, .{ .head = 5, .end = 12 } };
    try expectPicks(&scopes, .{ .top = 8 }, 5, &.{ 3, 5 });
    // **두 줄 스코프는 줄바꿈 뒤에도 안 선다** — 머리줄(0)이 세 조각이고 한 조각 올라가 있으면 칸 조건(머리 첫 조각 −1 < 0 ≤ 마지막 조각 1)은
    // 맞는다. 세 줄 규칙이 없으면 여기서 [0, 1] 이 선다 — 줄바꿈이 없으면 칸 규칙이 대신 막아 이 규칙이 안 보였다(적대적 1회차 S1).
    const two = [_]Scope{.{ .head = 0, .end = 1 }};
    try expectPicks(&two, .{ .top = 0, .first_piece = 1, .wrap = &.{.{ .line = 0, .pieces = 3 }} }, 5, &.{});
    const three = [_]Scope{.{ .head = 0, .end = 2 }};
    try expectPicks(&three, .{ .top = 0, .first_piece = 1, .wrap = &.{.{ .line = 0, .pieces = 3 }} }, 5, &.{0}); // 대조군 — 세 줄이면 선다
}

test "STK3 숨은 줄 — 접힌 스코프 안의 머리줄은 안 서고, 끝 줄이 숨으면 그 앞의 보이는 줄로 잰다 (§4.1i)" {
    // [0, 30] 안에 [2, 20] — 3..19 가 접혔다(머리줄 2 만 보인다). 그 안의 [4, 10] 은 머리줄이 숨었다.
    const scopes = [_]Scope{ .{ .head = 0, .end = 30 }, .{ .head = 2, .end = 20 }, .{ .head = 4, .end = 10 } };
    var hidden: [17]u32 = undefined;
    for (&hidden, 0..) |*h, i| h.* = @intCast(3 + i);
    // 맨 위가 21 — class 만: [2, 20] 의 마지막 본문 줄(19)이 숨어 그 앞의 보이는 줄 2(행 −2)로 잰다 — 칸 1 에 안 닿는다.
    try expectPicks(&scopes, .{ .top = 21, .hidden = &hidden }, 5, &.{0});
    // **부모는 섰는데 자식의 머리줄만 숨은 경우** — 위 픽스처는 깊이 규칙이 먼저 걸러 이 갈래를 못 쟀다. [0, 30] 안의 [4, 20] 이고
    // 4..9 가 접혔다(머리줄 3 의 접힘). 맨 위가 11 이면 class 는 서고, [4, 20] 은 머리줄이 숨어 안 선다(행으로 치면 칸 조건은 맞는다).
    const scopes2 = [_]Scope{ .{ .head = 0, .end = 30 }, .{ .head = 4, .end = 20 } };
    try expectPicks(&scopes2, .{ .top = 11, .hidden = &.{ 4, 5, 6, 7, 8, 9 } }, 5, &.{0});
    try expectPicks(&scopes2, .{ .top = 11 }, 5, &.{ 0, 4 }); // 대조군: 숨지 않으면 선다
}

test "STK4 줄바꿈 — 머리줄은 첫 조각, 끝은 마지막 조각의 행으로 잰다 (§4.1i)" {
    // [0, 6] 의 마지막 본문 줄 5 가 세 조각이다. 맨 위가 5 면 그 줄이 행 0..2 — 칸 1 에 닿는다(첫 조각만 보면 안 닿는다).
    const scopes = [_]Scope{ .{ .head = 0, .end = 20 }, .{ .head = 2, .end = 6 } };
    try expectPicks(&scopes, .{ .top = 5, .wrap = &.{.{ .line = 5, .pieces = 3 }} }, 5, &.{ 0, 2 });
    // 조각이 하나면 떨어진다.
    try expectPicks(&scopes, .{ .top = 5 }, 5, &.{0});
}

test "STK5 줄 수 상한 — 설정과 화면 25% 중 작은 쪽, 설정 상한 10 (§4.1i)" {
    try testing.expectEqual(@as(usize, 5), maxLines(5, 40));
    try testing.expectEqual(@as(usize, 2), maxLines(5, 8)); // 8 행 × 0.25 = 2
    try testing.expectEqual(@as(usize, 3), maxLines(5, 10)); // round(2.5) = 3
    try testing.expectEqual(@as(usize, 10), maxLines(99, 400));
    try testing.expectEqual(@as(usize, 0), maxLines(5, 1));
    // 정렬 — 머리줄 오름차순, 같으면 끝 내림차순(바깥이 먼저).
    var s = [_]Scope{ .{ .head = 3, .end = 5 }, .{ .head = 1, .end = 9 }, .{ .head = 3, .end = 9 } };
    sortScopes(&s);
    try testing.expectEqual(@as(u32, 1), s[0].head);
    try testing.expectEqual(@as(u32, 9), s[1].end);
    try testing.expectEqual(@as(u32, 5), s[2].end);
}

fn expectPicks(scopes: []const Scope, rows: TestRows, max: usize, want: []const u32) !void {
    const got = try pick(scopes, rows, max);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u32, want, got);
}
