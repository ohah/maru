//! 세 판의 **대응표**(S3b-M — docs/editor-merge-conflicts.md §5 S3b-M).
//!
//! 「Result 의 N 줄이 이 판에서는 몇 줄인가」를 답한다. 출처는 `diff.compute` — 그 결과(`Rows`)는
//! 같은 첨자가 같은 높이이므로 `left[i].line ↔ right[i].line` 이 곧 줄 대응이다. **새 diff 를
//! 쓰지 않는다**(같은 규칙의 주인이 둘이 된다).
//!
//! **축은 Result 다.** 스크롤도 고르기도 Result 에서 출발하므로 표 셋(`ours`·`theirs`·`base`)이 전부
//! `판 ↔ Result` 다. 이 모듈은 한 쌍만 안다 — 셋을 드는 것은 상태(플랫폼)의 몫이다.
//!
//! **빠진 줄의 규칙**: 한쪽에만 있는 줄(추가·삭제)은 저쪽에 짝이 없다. 그때는 **앞으로 가장 가까운
//! 짝 있는 줄**로 옮긴다. VS Code 는 대응 구간 안의 비율을 쓴다(§7 ⑥ 실측) — 한 단계 거친 규칙으로
//! 시작하고, 그 차이가 화면에서 보일 때 올린다.
//!
//! **짝의 머리 규칙**: 짝 있는 줄로 갈 때, 저쪽에서 그 줄 **바로 위에 저쪽에만 있는 줄 무리**가
//! 붙어 있으면 그 무리의 머리로 간다. 안 그러면 Result 0 줄에서 판이 맨 위에 더 가진 줄들이 어디서도
//! 안 보인다(판은 스스로 못 굴러간다). 구간 경계에서 VS Code 의 비율 규칙과 같은 답이다.

const std = @import("std");
const diff = @import("diff.zig");
const line_index = @import("line_index.zig");

/// `판 ↔ Result` 한 쌍. `rows.left` 가 판, `rows.right` 가 Result 다.
pub const Map = struct {
    rows: diff.Rows,

    pub fn deinit(self: *Map, allocator: std.mem.Allocator) void {
        self.rows.deinit(allocator);
    }

    /// Result 의 줄(0-based) → 판의 줄(0-based). 짝이 없으면 **앞으로 가장 가까운 짝**.
    /// 표보다 뒤의 줄은 판의 마지막 짝으로 묶인다(넘겨 짚지 않는다).
    pub fn toSide(self: Map, result_line: u32) ?u32 {
        return project(self.rows.right, self.rows.left, result_line);
    }

    /// 판의 줄(0-based) → Result 의 줄(0-based). 같은 규칙.
    pub fn toResult(self: Map, side_line: u32) ?u32 {
        return project(self.rows.left, self.rows.right, side_line);
    }

    /// Result 의 줄(0-based) → 판의 **정확한 짝**(0-based). 짝이 없으면 `null` — 앞 짝도, 무리 머리도
    /// 아니다. **위젯의 자리**가 이것을 쓴다(S3b-3c 공격 ②): `toSide` 는 «굴리기 자리»라 짝 위에 붙은
    /// 판만의 줄 무리 머리로 밀리는데, 고르기 줄은 그 본문 줄 바로 위에 서야 한다.
    pub fn pairOnSide(self: Map, result_line: u32) ?u32 {
        return pair(self.rows.right, self.rows.left, result_line);
    }

    /// S3b-3c 의 앵커 규칙 — 충돌 구간의 **한 쪽 본문** `[from, to)`(Result 축, 0-based)이 판에서 어느
    /// 줄 위에 서나. 본문 첫 줄의 짝, 본문이 비었으면(우리 쪽이 지운 구간) 구간 **다음 줄** `after` 의
    /// 짝, 그것도 없으면 `null`(EOF — Result 줄만 남는다). 계약 §5 S3b-3c.
    pub fn anchorOnSide(self: Map, from: u32, to: u32, after: u32) ?u32 {
        if (from < to) return self.pairOnSide(from);
        return self.pairOnSide(after);
    }
};

/// `from` 축의 줄이 `to` 축에 갖는 짝. 둘 다 줄이 있는 행이어야 짝이다.
fn pair(from: []const diff.Row, to: []const diff.Row, line0: u32) ?u32 {
    const want: u32 = line0 + 1;
    for (from, 0..) |r, i| {
        const l = r.line orelse continue;
        if (l > want) return null;
        if (l == want) return if (to[i].line) |tl| tl - 1 else null;
    }
    return null;
}

/// `from` 축의 줄을 `to` 축으로 옮긴다. 둘은 같은 길이의 정렬된 행 배열이다.
fn project(from: []const diff.Row, to: []const diff.Row, line0: u32) ?u32 {
    const want: u32 = line0 + 1; // `Row.line` 은 1-based 다
    var best: ?u32 = null;
    for (from, 0..) |r, i| {
        const l = r.line orelse continue;
        // 정렬돼 있으므로 지나쳤다. **등가 변이**(적대적 1회차 A7): 이 `break` 를 지워도 답은 같다 —
        // `from` 의 줄 번호는 1..n 이 빠짐없이 이어져 `want ≤ n` 이면 아래 `l == want` 가 먼저 돌아가고,
        // `want > n` 이면 끝까지 훑어도 마지막 짝이다. 일찍 끊는 것은 비용 문제일 뿐이다.
        if (l > want) break;
        // 이 자리의 저쪽 줄 — 저쪽이 filler 면 «앞으로 가장 가까운 짝» 규칙으로 뒤에서 덮인 값이 남는다.
        if (to[i].line) |tl| best = tl - 1;
        if (l == want) {
            if (to[i].line != null) return runHead(from, to, i);
            return best; // 이 줄이 저쪽에 없다 — 앞 짝으로
        }
    }
    return best;
}

/// «짝의 머리 규칙» — `i` 는 양쪽 다 줄이 있는 행이다. 그 바로 위에 `to` 에만 있는 행(`from` 이
/// filler)이 붙어 있으면 그 무리의 첫 행의 `to` 줄을, 아니면 `i` 자신의 `to` 줄을 준다(0-based).
fn runHead(from: []const diff.Row, to: []const diff.Row, i: usize) u32 {
    var j = i;
    while (j > 0 and from[j - 1].line == null and to[j - 1].line != null) j -= 1;
    return to[j].line.? - 1;
}

/// 판의 전문을 **Result 와 같은 줄 규칙**으로 쪼갠다 — 편집기 문서의 줄 인덱스(`line_index`)로
/// 자르고 줄바꿈은 뺀다. 호출자가 배열을 놓는다(줄들은 `bytes` 를 빌린다).
///
/// **`diff_state.splitLines` 로 쪼개면 표가 거짓이 된다.** 그쪽은 줄바꿈을 **붙인 채** 자르고 끝
/// 개행 뒤의 빈 줄을 세지 않는다 — 편집기의 `editor_lines` 는 줄바꿈을 **떼고** 끝 개행 뒤 빈 줄을
/// 센다. 같은 글자의 줄이 전부 «다른 줄» 이 되어 `diff.compute` 가 첨자대로 «바뀜» 으로 짝짓고,
/// 표는 항등처럼 보이면서 한 줄씩 어긋난다(MPN12 가 처음 그렇게 빨갰다).
pub fn splitLikeEditor(allocator: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}![]const []const u8 {
    var idx = line_index.build(allocator, bytes) catch return error.OutOfMemory;
    defer idx.deinit();
    const n = idx.lineCount();
    const out = try allocator.alloc([]const u8, n);
    for (0..n) |i| {
        const l = idx.line(i).?;
        out[i] = bytes[l.start..l.contentEnd()];
    }
    return out;
}

/// 판과 Result 의 줄 배열로 대응표를 만든다. 호출자가 `Map` 을 놓는다.
/// **줄 슬라이스를 빌린다** — 두 전문이 이 표보다 오래 살아야 한다(`diff.Row.text` 의 계약과 같다).
pub fn build(allocator: std.mem.Allocator, side_lines: []const []const u8, result_lines: []const []const u8) error{OutOfMemory}!?Map {
    const view = try diff.compute(allocator, side_lines, result_lines, .{});
    return switch (view) {
        .compare => |rows| .{ .rows = rows },
        // 다른 곳이 없으면 항등이다 — 그때도 표를 만들어야 호출자가 「없음」과 「항등」을 안 헷갈린다.
        .unchanged => blk: {
            var rows = try identity(allocator, side_lines);
            errdefer rows.deinit(allocator);
            break :blk .{ .rows = rows };
        },
        .loading, .unavailable => null,
    };
}

fn identity(allocator: std.mem.Allocator, lines: []const []const u8) error{OutOfMemory}!diff.Rows {
    const left = try allocator.alloc(diff.Row, lines.len);
    errdefer allocator.free(left);
    const right = try allocator.alloc(diff.Row, lines.len);
    for (lines, 0..) |t, i| {
        const row: diff.Row = .{ .kind = .context, .line = @intCast(i + 1), .text = t };
        left[i] = row;
        right[i] = row;
    }
    return .{ .left = left, .right = right, .changed = 0 };
}

const testing = std.testing;

test "MAP1 같은 줄은 같은 번호로 간다 — 그리고 «없음» 과 «항등» 이 다르다" {
    const a = [_][]const u8{ "x\n", "y\n", "z\n" };
    var m = (try build(testing.allocator, &a, &a)) orelse return error.NoMap;
    defer m.deinit(testing.allocator);
    try testing.expectEqual(@as(?u32, 0), m.toSide(0));
    try testing.expectEqual(@as(?u32, 2), m.toSide(2));
    try testing.expectEqual(@as(?u32, 1), m.toResult(1));
}

test "MAP2 Result 에만 있는 줄은 «앞으로 가장 가까운 짝» 으로 간다" {
    // 판:      x  y     z
    // Result:  x  y  Q  z      ← Q 는 Result 에만 있다(추가)
    const side = [_][]const u8{ "x\n", "y\n", "z\n" };
    const result = [_][]const u8{ "x\n", "y\n", "Q\n", "z\n" };
    var m = (try build(testing.allocator, &side, &result)) orelse return error.NoMap;
    defer m.deinit(testing.allocator);
    try testing.expectEqual(@as(?u32, 1), m.toSide(2)); // Q → 앞 짝 y
    try testing.expectEqual(@as(?u32, 2), m.toSide(3)); // z → z
    try testing.expectEqual(@as(?u32, 2), m.toResult(2)); // z → Q (z 바로 위에 붙은 Result 만의 무리의 머리 — 「짝의 머리 규칙」)
    try testing.expectEqual(@as(?u32, 1), m.toResult(1)); // y → y (위에 무리 없음)
}

test "MAP3 판에만 있는 줄은 Result 쪽으로 «앞 짝» 으로 간다 — 그리고 넘겨 짚지 않는다" {
    // 판:      x  D  y        ← D 는 판에만 있다(삭제)
    // Result:  x     y
    const side = [_][]const u8{ "x\n", "D\n", "y\n" };
    const result = [_][]const u8{ "x\n", "y\n" };
    var m = (try build(testing.allocator, &side, &result)) orelse return error.NoMap;
    defer m.deinit(testing.allocator);
    try testing.expectEqual(@as(?u32, 0), m.toResult(1)); // D → 앞 짝 x
    try testing.expectEqual(@as(?u32, 1), m.toResult(2)); // y → y
    // **표 밖**(문서보다 뒤)은 마지막 짝으로 묶인다 — 없는 줄을 지어내지 않는다.
    try testing.expectEqual(@as(?u32, 1), m.toResult(99));
    try testing.expectEqual(@as(?u32, 2), m.toSide(99));
}

test "MAP5 판의 전문은 편집기의 줄 규칙으로 쪼개진다 — 줄바꿈 없이, 끝 개행 뒤 빈 줄까지" {
    const a = std.testing.allocator;
    // 편집기가 같은 bytes 를 열었을 때의 줄들 — 그 규칙(`line_index`)이 기준이다.
    const bytes = "EXTRA\r\nline 000\nline 001\n";
    const got = try splitLikeEditor(a, bytes);
    defer a.free(got);
    try std.testing.expectEqual(@as(usize, 4), got.len);
    try std.testing.expectEqualStrings("EXTRA", got[0]);
    try std.testing.expectEqualStrings("line 000", got[1]);
    try std.testing.expectEqualStrings("line 001", got[2]);
    try std.testing.expectEqualStrings("", got[3]);

    // 그래서 표가 선다: 판 = `EXTRA` + Result. Result 의 1 은 판의 2 다(항등이 아니다).
    const result = try splitLikeEditor(a, "line 000\nline 001\n");
    defer a.free(result);
    var m = (try build(a, got, result)) orelse return error.MapMissing;
    defer m.deinit(a);
    try std.testing.expectEqual(@as(?u32, 2), m.toSide(1));
    try std.testing.expectEqual(@as(?u32, 1), m.toResult(2));

    // 빈 전문은 **빈 줄 하나**다 — 편집기가 빈 파일을 그렇게 연다. 「없는 판」은 줄 배열이 아니라
    // `stages.has_*` 가 말한다.
    const empty = try splitLikeEditor(a, "");
    defer a.free(empty);
    try std.testing.expectEqual(@as(usize, 1), empty.len);
    try std.testing.expectEqualStrings("", empty[0]);
}

test "MAP6 짝의 머리 규칙 — 짝 바로 위에 붙은 저쪽만의 무리는 그 머리로 온다, 그리고 단조다" {
    // 판:      A  B  x  y  C  z      ← A·B 는 x 위에, C 는 z 위에 붙은 판만의 무리
    // Result:        x  y     z
    const side = [_][]const u8{ "A", "B", "x", "y", "C", "z" };
    const result = [_][]const u8{ "x", "y", "z" };
    var m = (try build(testing.allocator, &side, &result)) orelse return error.NoMap;
    defer m.deinit(testing.allocator);
    try testing.expectEqual(@as(?u32, 0), m.toSide(0)); // x → 무리 머리 A (x 자신인 2 가 아니다)
    try testing.expectEqual(@as(?u32, 3), m.toSide(1)); // y → y (위에 무리 없음)
    try testing.expectEqual(@as(?u32, 4), m.toSide(2)); // z → 무리 머리 C
    // 반대 방향도 같은 규칙 — 그리고 판만의 줄은 여전히 «앞 짝»(MAP3).
    try testing.expectEqual(@as(?u32, 0), m.toResult(2)); // x → x
    try testing.expectEqual(@as(?u32, 1), m.toResult(4)); // C → 앞 짝 y
    // Result 에만 있는 무리가 z 위에 붙은 경우: 판의 z 는 Result 의 무리 머리로.
    const side2 = [_][]const u8{ "x", "z" };
    const result2 = [_][]const u8{ "x", "P", "Q", "z" };
    var m2 = (try build(testing.allocator, &side2, &result2)) orelse return error.NoMap;
    defer m2.deinit(testing.allocator);
    try testing.expectEqual(@as(?u32, 1), m2.toResult(1)); // z → P (무리 머리)
    try testing.expectEqual(@as(?u32, 1), m2.toSide(3)); // z → z (판 쪽엔 무리 없음)
}

test "MAP7 «짝» 은 앞 짝도 무리 머리도 아니다 — 그리고 앵커 규칙: 본문 첫 줄 · 빈 쪽은 다음 줄 · EOF 는 없음" {
    // 판:      A  B  x  D  y        ← A·B 는 x 위의 판만의 무리, D 는 판에만
    // Result:        x     y  Q     ← Q 는 Result 에만
    const side = [_][]const u8{ "A", "B", "x", "D", "y" };
    const result = [_][]const u8{ "x", "y", "Q" };
    var m = (try build(testing.allocator, &side, &result)) orelse return error.NoMap;
    defer m.deinit(testing.allocator);
    try testing.expectEqual(@as(?u32, 2), m.pairOnSide(0)); // x → x 자신(무리 머리 A 가 아니다 — toSide 는 0)
    try testing.expectEqual(@as(?u32, 0), m.toSide(0));
    try testing.expectEqual(@as(?u32, 4), m.pairOnSide(1)); // y → y
    try testing.expectEqual(@as(?u32, null), m.pairOnSide(2)); // Q 는 짝이 없다(앞 짝 y 가 아니다)
    try testing.expectEqual(@as(?u32, null), m.pairOnSide(99)); // 표 밖도 없음

    // 앵커: 구간 본문이 [0,1) 이면 그 첫 줄의 짝. 비었으면([2,2)) 다음 줄(2 = Q, 짝 없음) → null.
    try testing.expectEqual(@as(?u32, 2), m.anchorOnSide(0, 1, 1));
    try testing.expectEqual(@as(?u32, 4), m.anchorOnSide(1, 1, 1)); // 빈 쪽 → 다음 줄 y 의 짝
    try testing.expectEqual(@as(?u32, null), m.anchorOnSide(2, 2, 3)); // EOF 다음은 없다
}

test "MAP4 맨 앞이 저쪽에 없으면 «앞 짝» 이 없다 — null 이다" {
    // Result 의 첫 줄이 추가된 줄이면 앞 짝이 없다. 0 으로 지어내면 첫 줄을 «같은 줄» 이라고 거짓말한다.
    const side = [_][]const u8{ "y\n", "z\n" };
    const result = [_][]const u8{ "Q\n", "y\n", "z\n" };
    var m = (try build(testing.allocator, &side, &result)) orelse return error.NoMap;
    defer m.deinit(testing.allocator);
    try testing.expectEqual(@as(?u32, null), m.toSide(0));
    try testing.expectEqual(@as(?u32, 0), m.toSide(1));
}
