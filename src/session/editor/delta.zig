//! 한 번의 편집 = delta 하나 — **여러 range를 담고, selection을 같은 연산에서 민다**
//! ([native-editor-document-model.md](../../../docs/native-editor-document-model.md) §3.3).
//!
//! `buffer.zig`는 한 자리를 고치는 연산(`insert`/`delete`)을 준다. 그것만으로는 §3.3을 만족할 수
//! 없다 — 멀티 커서로 타이핑하면 **첫 삽입이 뒤 커서들의 offset을 민다.** 그것을 안 밀고 두 번째
//! 삽입을 하면 엉뚱한 자리에 들어간다. 그래서 그 절은 매핑을 *"delta 적용과 한 연산으로 묶어
//! 중간 상태가 새어 나가지 않게 한다"*고 요구한다. `apply`가 그 한 연산이다.
//!
//! **뒤에서부터 적용한다.** 앞에서부터 하면 첫 변경이 뒤 변경의 offset을 밀어 두 번째가 빗나간다.
//! 뒤에서부터 하면 아직 손대지 않은 앞쪽 offset이 그대로라 변경 목록을 다시 계산할 필요가 없다 —
//! `Selections.init`이 정렬을 **불변식으로 강제**하는 이유가 이것이고, 여기서도 같은 것을 요구한다.
//!
//! **역연산을 함께 낸다.** §3.3이 undo 표현을 delta로 정했고, 되돌리려면 *지워진 내용*이 필요한데
//! 그것은 **적용하기 전에만** 읽을 수 있다. 그래서 `apply`가 그 자리에서 떠서 `Inverse`로 준다.
//!
//! **스택과 그룹핑은 여기 없다.** §3.3의 그룹핑 규칙(연속 타이핑은 하나로, *커서 이동·시간 경과·
//! 연산 종류 변경*에서 끊는다)은 **시계와 입력 사건**을 읽어야 하는데 둘 다 L2 밖이다. 이 모듈은
//! "한 번의 편집"을 값으로 만들고, 그것을 언제 쌓고 언제 끊을지는 배선 슬라이스가 정한다.

const std = @import("std");
const buffer = @import("buffer.zig");
const selection = @import("selection.zig");

/// 한 구간의 교체 — `[start, end)`를 `text`로 바꾼다.
///
/// 삽입은 `start == end`, 삭제는 `text.len == 0`이다. **셋을 따로 두지 않는 이유**: 교체는
/// 삭제+삽입으로 쪼갤 수 있지만 그러면 undo 하나가 둘로 갈리고, §3.3이 *"한 번의 연산 = undo
/// 하나"*를 자료구조 수준에서 보장하라고 한 것과 어긋난다.
///
/// **`text`를 소유하지 않는다.** 호출자가 살려 둔다 — 대개 키 입력 버퍼나 클립보드라 이미 어딘가에
/// 있다. 역연산이 내는 `Change`는 반대로 소유한다(`Inverse.deinit`이 푼다).
pub const Change = struct {
    start: usize,
    end: usize,
    text: []const u8,

    pub fn removedLen(self: Change) usize {
        return self.end - self.start;
    }
};

/// 한 번의 편집. **변경들이 문서 순서로 정렬돼 있고 겹치지 않는다.**
///
/// 겹침을 허용하면 "어느 것이 이겼는가"를 정하는 규칙이 필요해지고, 그 규칙은 호출자마다 다르게
/// 기대된다. 멀티 커서가 겹치는 경우는 `selection.mergeOverlapping`이 **selection 단계에서** 이미
/// 합치므로, 여기까지 겹친 채로 오는 것은 호출자의 결함이다.
pub const Delta = struct {
    changes: []const Change,

    /// 불변식을 만족하는가. `apply`가 Debug에서 이것으로 멈춘다.
    pub fn isWellFormed(self: Delta) bool {
        var prev_end: usize = 0;
        for (self.changes, 0..) |c, i| {
            if (c.start > c.end) return false;
            if (i > 0 and c.start < prev_end) return false;
            prev_end = c.end;
        }
        return true;
    }
};

/// `apply`가 돌려주는 역연산 — 이것을 다시 `apply`하면 편집 전으로 돌아간다.
///
/// **좌표는 편집 *후* 문서 기준이다.** 되돌릴 때는 편집이 이미 적용된 문서에 대고 쓰기 때문이다.
///
/// **지워진 내용을 소유한다.** 원본 버퍼에서 떠 온 복사본이라 버퍼가 바뀌어도 살아 있다 — 그래야
/// undo 스택에 오래 쌓아 둘 수 있다.
pub const Inverse = struct {
    allocator: std.mem.Allocator,
    changes: []Change,

    pub fn deinit(self: *Inverse) void {
        for (self.changes) |c| self.allocator.free(@constCast(c.text));
        self.allocator.free(self.changes);
        self.* = undefined;
    }

    pub fn delta(self: Inverse) Delta {
        return .{ .changes = self.changes };
    }
};

/// 편집 전 offset을 편집 후 축으로 옮긴다(§3.3).
///
/// 규칙 둘: **앞선 변경의 길이 차만큼 밀고**, **지워진 구간 안을 가리키고 있었으면 구간 시작으로
/// 접는다.** 접지 않으면 그 offset이 사라진 자리를 가리켜 다음 입력이 엉뚱한 곳에 간다.
///
/// 구간 **끝**(`c.end`)은 지워진 텍스트 바로 뒤이므로 접지 않고 민다 — 지운 자리에 커서를 두는 것이
/// 자연스러운 결과다.
pub fn mapOffset(d: Delta, offset: usize) usize {
    var shift: isize = 0;
    for (d.changes) |c| {
        if (offset <= c.start) break;
        if (offset < c.end) return applyShift(c.start, shift);
        shift += @as(isize, @intCast(c.text.len)) - @as(isize, @intCast(c.removedLen()));
    }
    return applyShift(offset, shift);
}

fn applyShift(offset: usize, shift: isize) usize {
    if (shift >= 0) return offset + @as(usize, @intCast(shift));
    return offset - @as(usize, @intCast(-shift));
}

/// delta를 버퍼에 적용하고 **같은 연산에서** selection을 민다. 역연산을 돌려준다.
///
/// **실패하면 버퍼가 그대로다.** 지워질 내용을 전부 먼저 떠 놓고, 그 다음에 버퍼를 고친다 —
/// 중간에 할당이 실패해 편집이 반쯤 적용된 상태는 만들지 않는다. `selections`는 버퍼가 다 바뀐
/// 뒤에 건드리므로 같은 규칙을 따른다.
///
/// **`selections`를 옵셔널로 두지 않았다.** 매핑을 잊을 수 있는 형태로 만들면 §3.3이 막으려던 바로
/// 그 결함(민 것과 안 민 것이 섞임)이 돌아온다. 걸 selection이 없는 호출자는 caret 하나짜리를 준다.
pub fn apply(
    allocator: std.mem.Allocator,
    buf: *buffer.Buffer,
    d: Delta,
    selections: *selection.Selections,
) !Inverse {
    std.debug.assert(d.isWellFormed());
    if (d.changes.len > 0) std.debug.assert(d.changes[d.changes.len - 1].end <= buf.byteLen());

    // ① 지워질 내용을 **먼저 전부** 뜬다. 버퍼를 고치기 시작하면 읽을 수 없다.
    var removed = try allocator.alloc([]u8, d.changes.len);
    var taken: usize = 0;
    errdefer {
        for (removed[0..taken]) |r| allocator.free(r);
        allocator.free(removed);
    }
    for (d.changes) |c| {
        removed[taken] = try buf.copyRange(allocator, c.start, c.end);
        taken += 1;
    }

    // ② 역연산의 좌표(편집 **후** 축)를 정한다. 버퍼를 고치기 전에 계산해도 결과가 같고,
    //    실패 지점을 버퍼 변경 앞으로 몰 수 있다.
    const inverse_changes = try allocator.alloc(Change, d.changes.len);
    errdefer allocator.free(inverse_changes);
    var shift: isize = 0;
    for (d.changes, 0..) |c, i| {
        const new_start = applyShift(c.start, shift);
        inverse_changes[i] = .{
            .start = new_start,
            .end = new_start + c.text.len,
            .text = removed[i],
        };
        shift += @as(isize, @intCast(c.text.len)) - @as(isize, @intCast(c.removedLen()));
    }

    // ③ **뒤에서부터** 버퍼를 고친다 — 앞쪽 offset이 아직 안 밀렸으므로 그대로 쓸 수 있다.
    //
    // **변경이 여럿이면 중간에 실패할 수 있다.** 그때 일부만 적용된 채 두면 문서가 사용자가 요청한
    // 적 없는 상태가 되고, 역연산은 그 상태를 되돌리지 못한다(전부 적용됐다고 가정하고 만든 좌표다).
    // 그래서 편집 전 판을 `O(1)`로 떠 두었다가 되돌린다 — persistent rope라 **할당 없이** 된다.
    // 적대적 검증(2026-08-24)이 이 자리를 열어 뒀던 것을 반증했다.
    var snap = buf.snapshot();
    var need_rollback = true;
    errdefer if (need_rollback) buf.restore(snap);
    {
        var i = d.changes.len;
        while (i > 0) {
            i -= 1;
            const c = d.changes[i];
            if (c.end > c.start) _ = try buf.delete(c.start, c.end);
            if (c.text.len > 0) _ = try buf.insert(c.start, c.text);
        }
    }
    need_rollback = false;
    snap.deinit();

    // ④ selection을 민다. **버퍼가 다 바뀐 뒤 한 번에** — 중간 상태가 새어 나가지 않는다(§3.3).
    for (selections.items) |*s| {
        s.anchor_start = mapOffset(d, s.anchor_start);
        s.anchor_end = mapOffset(d, s.anchor_end);
        s.focus = mapOffset(d, s.focus);
    }

    // 편집은 caret을 가로로 옮긴다 — 목표 열을 남겨 두면 다음 위/아래 이동이 **편집 전 열**로 튄다.
    // `resetGoalsAfterHorizontalMove`가 정확히 그 사건을 위한 것이다(§3.2).
    selections.resetGoalsAfterHorizontalMove();

    // 열/블록 선택 원본은 **진행 중인 제스처**이지 문서 상태가 아니다(§3.2a·§3.3). 문서가 바뀌면
    // 그것이 붙들고 있던 offset이 의미를 잃으므로 버린다 — undo가 그것을 복원하지 않는 것과 같은 이유다.
    selections.column = null;

    allocator.free(removed);

    // **역연산도 delta다 — 같은 불변식을 만족해야 한다.** 정렬·비겹침이 성립하는 것은 증명할 수
    // 있지만(입력이 정렬·비겹침이고 shift가 누적이라 새 시작점이 앞 것의 끝 이상이다), 증명을
    // 적어 두는 것과 확인하는 것은 다르다. 이 단언이 그 증명을 **실행 중에** 다시 본다.
    std.debug.assert((Delta{ .changes = inverse_changes }).isWellFormed());
    return .{ .allocator = allocator, .changes = inverse_changes };
}

// ── 판정자 ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn makeSelections(items: []selection.Selection) selection.Selections {
    return selection.Selections.init(items, 0);
}

test "DLT1: 변경 하나가 버퍼와 selection을 함께 옮긴다" {
    var buf = try buffer.Buffer.init(testing.allocator, "hello world");
    defer buf.deinit();

    var items = [_]selection.Selection{selection.Selection.at(11)};
    var sels = makeSelections(&items);

    const changes = [_]Change{.{ .start = 0, .end = 5, .text = "goodbye" }};
    var inv = try apply(testing.allocator, &buf, .{ .changes = &changes }, &sels);
    defer inv.deinit();

    const all = try buf.copyAll(testing.allocator);
    defer testing.allocator.free(all);
    try testing.expectEqualStrings("goodbye world", all);
    try testing.expectEqual(@as(usize, 13), sels.items[0].focus);
}

test "DLT2: 멀티 커서 동시 편집 — 앞 삽입이 뒤 커서를 민다" {
    var buf = try buffer.Buffer.init(testing.allocator, "aa bb cc");
    defer buf.deinit();

    // 세 자리에 커서를 놓고 각각 "X"를 친 것과 같은 delta.
    var items = [_]selection.Selection{
        selection.Selection.at(0),
        selection.Selection.at(3),
        selection.Selection.at(6),
    };
    var sels = makeSelections(&items);

    const changes = [_]Change{
        .{ .start = 0, .end = 0, .text = "X" },
        .{ .start = 3, .end = 3, .text = "X" },
        .{ .start = 6, .end = 6, .text = "X" },
    };
    var inv = try apply(testing.allocator, &buf, .{ .changes = &changes }, &sels);
    defer inv.deinit();

    const all = try buf.copyAll(testing.allocator);
    defer testing.allocator.free(all);
    try testing.expectEqualStrings("Xaa Xbb Xcc", all);

    // **이 세 값이 §3.3의 요구다.** 앞 삽입을 반영하지 않으면 뒤 커서가 1·2씩 뒤처진다.
    try testing.expectEqual(@as(usize, 0), sels.items[0].focus);
    try testing.expectEqual(@as(usize, 4), sels.items[1].focus);
    try testing.expectEqual(@as(usize, 8), sels.items[2].focus);
}

test "DLT3: 지워진 구간 안을 가리키던 커서는 구간 시작으로 접힌다" {
    var buf = try buffer.Buffer.init(testing.allocator, "0123456789");
    defer buf.deinit();

    var items = [_]selection.Selection{selection.Selection.at(5)};
    var sels = makeSelections(&items);

    const changes = [_]Change{.{ .start = 2, .end = 8, .text = "" }};
    var inv = try apply(testing.allocator, &buf, .{ .changes = &changes }, &sels);
    defer inv.deinit();

    const all = try buf.copyAll(testing.allocator);
    defer testing.allocator.free(all);
    try testing.expectEqualStrings("0189", all);
    try testing.expectEqual(@as(usize, 2), sels.items[0].focus);
}

test "DLT4: 역연산을 적용하면 내용과 selection이 편집 전으로 돌아간다" {
    const original = "the quick brown fox";
    var buf = try buffer.Buffer.init(testing.allocator, original);
    defer buf.deinit();

    var items = [_]selection.Selection{ selection.Selection.at(4), selection.Selection.at(16) };
    var sels = makeSelections(&items);

    const changes = [_]Change{
        .{ .start = 4, .end = 9, .text = "slow" },
        .{ .start = 16, .end = 19, .text = "cat" },
    };
    var inv = try apply(testing.allocator, &buf, .{ .changes = &changes }, &sels);
    defer inv.deinit();

    const edited = try buf.copyAll(testing.allocator);
    defer testing.allocator.free(edited);
    try testing.expectEqualStrings("the slow brown cat", edited);

    var back = try apply(testing.allocator, &buf, inv.delta(), &sels);
    defer back.deinit();

    const restored = try buf.copyAll(testing.allocator);
    defer testing.allocator.free(restored);
    try testing.expectEqualStrings(original, restored);
}

test "DLT5: 역연산은 편집 후 좌표를 쓴다 — 변경이 여럿이어도 자리가 맞는다" {
    var buf = try buffer.Buffer.init(testing.allocator, "aaaa bbbb cccc");
    defer buf.deinit();

    var items = [_]selection.Selection{selection.Selection.at(0)};
    var sels = makeSelections(&items);

    // 앞 변경이 길이를 크게 바꿔 뒤 변경의 좌표를 민다 — 역연산이 옛 좌표를 쓰면 여기서 어긋난다.
    const changes = [_]Change{
        .{ .start = 0, .end = 4, .text = "A" },
        .{ .start = 10, .end = 14, .text = "CCCCCCCC" },
    };
    var inv = try apply(testing.allocator, &buf, .{ .changes = &changes }, &sels);
    defer inv.deinit();

    try testing.expectEqual(@as(usize, 0), inv.changes[0].start);
    try testing.expectEqual(@as(usize, 1), inv.changes[0].end);
    try testing.expectEqual(@as(usize, 7), inv.changes[1].start); // 10 + (1-4) = 7
    try testing.expectEqual(@as(usize, 15), inv.changes[1].end); // 7 + 8

    var back = try apply(testing.allocator, &buf, inv.delta(), &sels);
    defer back.deinit();

    const restored = try buf.copyAll(testing.allocator);
    defer testing.allocator.free(restored);
    try testing.expectEqualStrings("aaaa bbbb cccc", restored);
}

test "DLT6: 선택 범위의 양 끝이 각각 매핑된다 — anchor만 밀고 focus를 두지 않는다" {
    var buf = try buffer.Buffer.init(testing.allocator, "0123456789");
    defer buf.deinit();

    var items = [_]selection.Selection{selection.Selection.fromPoints(6, 9)};
    var sels = makeSelections(&items);

    const changes = [_]Change{.{ .start = 0, .end = 0, .text = "??" }};
    var inv = try apply(testing.allocator, &buf, .{ .changes = &changes }, &sels);
    defer inv.deinit();

    try testing.expectEqual(@as(usize, 8), sels.items[0].anchor_start);
    try testing.expectEqual(@as(usize, 8), sels.items[0].anchor_end);
    try testing.expectEqual(@as(usize, 11), sels.items[0].focus);
}

test "DLT7: 편집은 목표 열과 열 선택 원본을 버린다" {
    var buf = try buffer.Buffer.init(testing.allocator, "line one\nline two");
    defer buf.deinit();

    var items = [_]selection.Selection{selection.Selection.at(3)};
    items[0].goal = .{ .col = 7 };
    items[0].anchor_goal = .{ .col = 7 };
    var sels = makeSelections(&items);
    sels.column = .{ .from_row = 0, .from_col = 0, .to_row = 1, .to_col = 3 };

    const changes = [_]Change{.{ .start = 0, .end = 0, .text = "X" }};
    var inv = try apply(testing.allocator, &buf, .{ .changes = &changes }, &sels);
    defer inv.deinit();

    // 편집은 caret을 가로로 옮긴다 — 옛 목표 열이 남으면 다음 ↑/↓가 편집 전 열로 튄다.
    try testing.expect(sels.items[0].goal.eql(.none));
    try testing.expect(sels.items[0].anchor_goal.eql(.none));
    try testing.expectEqual(@as(?selection.ColumnAnchor, null), sels.column);
}

test "DLT8: 변경이 없는 delta는 아무것도 바꾸지 않는다" {
    var buf = try buffer.Buffer.init(testing.allocator, "unchanged");
    defer buf.deinit();

    var items = [_]selection.Selection{selection.Selection.at(4)};
    var sels = makeSelections(&items);

    const changes = [_]Change{};
    var inv = try apply(testing.allocator, &buf, .{ .changes = &changes }, &sels);
    defer inv.deinit();

    try testing.expectEqual(@as(usize, 0), inv.changes.len);
    try testing.expectEqual(@as(usize, 4), sels.items[0].focus);
    try testing.expectEqual(@as(usize, 9), buf.byteLen());
}

test "DLT9: 겹치거나 뒤집힌 delta는 불변식이 거른다" {
    const overlapping = [_]Change{
        .{ .start = 0, .end = 5, .text = "" },
        .{ .start = 3, .end = 7, .text = "" }, // 앞 변경과 겹친다
    };
    try testing.expect(!(Delta{ .changes = &overlapping }).isWellFormed());

    const reversed = [_]Change{.{ .start = 7, .end = 3, .text = "" }};
    try testing.expect(!(Delta{ .changes = &reversed }).isWellFormed());

    const ok = [_]Change{
        .{ .start = 0, .end = 3, .text = "x" },
        .{ .start = 3, .end = 5, .text = "y" }, // 맞닿는 것은 겹치는 것이 아니다
    };
    try testing.expect((Delta{ .changes = &ok }).isWellFormed());
}

test "DLT10: 지운 자리 바로 뒤 커서는 접히지 않고 밀린다" {
    var buf = try buffer.Buffer.init(testing.allocator, "0123456789");
    defer buf.deinit();

    var items = [_]selection.Selection{selection.Selection.at(8)};
    var sels = makeSelections(&items);

    const changes = [_]Change{.{ .start = 2, .end = 8, .text = "ab" }};
    var inv = try apply(testing.allocator, &buf, .{ .changes = &changes }, &sels);
    defer inv.deinit();

    // 8은 지워진 구간의 **끝**이다 — 접으면 2, 밀면 2 + 2 = 4. 밀어야 지운 자리 뒤에 커서가 선다.
    try testing.expectEqual(@as(usize, 4), sels.items[0].focus);
}

test "DLT11: 무작위 delta 300번을 배열 모델과 대조하고 매번 되돌린다" {
    var prng = std.Random.DefaultPrng.init(0xD317A);
    const rand = prng.random();

    var buf = try buffer.Buffer.init(testing.allocator, "seed text for the model comparison\n");
    defer buf.deinit();

    var model: std.ArrayList(u8) = .empty;
    defer model.deinit(testing.allocator);
    try model.appendSlice(testing.allocator, "seed text for the model comparison\n");

    var round: usize = 0;
    while (round < 300) : (round += 1) {
        // 겹치지 않는 변경 1~3개를 문서 순서로 만든다.
        var changes: std.ArrayList(Change) = .empty;
        defer changes.deinit(testing.allocator);

        var cursor: usize = 0;
        const want = 1 + rand.uintLessThan(usize, 3);
        var k: usize = 0;
        while (k < want and cursor < model.items.len) : (k += 1) {
            const gap = rand.uintLessThan(usize, @max(1, (model.items.len - cursor) / 2));
            const start = cursor + gap;
            if (start > model.items.len) break;
            const room = @min(model.items.len - start, 6);
            const end = start + rand.uintLessThan(usize, room + 1);
            const texts = [_][]const u8{ "", "q", "new\n", "12345" };
            try changes.append(testing.allocator, .{
                .start = start,
                .end = end,
                .text = texts[rand.uintLessThan(usize, texts.len)],
            });
            cursor = end + 1;
        }
        if (changes.items.len == 0) continue;

        const before = try testing.allocator.dupe(u8, model.items);
        defer testing.allocator.free(before);

        var items = [_]selection.Selection{selection.Selection.at(0)};
        var sels = makeSelections(&items);

        var inv = try apply(testing.allocator, &buf, .{ .changes = changes.items }, &sels);
        defer inv.deinit();

        // 모델도 뒤에서부터 적용한다.
        var i = changes.items.len;
        while (i > 0) {
            i -= 1;
            const c = changes.items[i];
            try model.replaceRange(testing.allocator, c.start, c.end - c.start, c.text);
        }

        const edited = try buf.copyAll(testing.allocator);
        defer testing.allocator.free(edited);
        try testing.expectEqualStrings(model.items, edited);

        // 되돌리면 매번 편집 전과 같아야 한다 — 역연산 좌표가 틀리면 여기서 어긋난다.
        var back = try apply(testing.allocator, &buf, inv.delta(), &sels);
        defer back.deinit();

        const restored = try buf.copyAll(testing.allocator);
        defer testing.allocator.free(restored);
        try testing.expectEqualStrings(before, restored);

        // 다음 라운드를 위해 다시 편집 상태로 만든다(모델과 버퍼를 맞춰 둔다).
        var again = try apply(testing.allocator, &buf, back.delta(), &sels);
        defer again.deinit();
    }
}

test "DLT12: 변경이 여럿일 때 중간에 실패해도 버퍼가 반쯤 바뀌지 않는다" {
    // **이 판정자는 적대적 검증이 세그폴트를 낸 자리에서 나왔다.** 그때는 소유권 규약이 어긋나
    // 이중 해제였고(buffer.zig에서 고쳤다), 고친 뒤에도 **일부만 적용된 채 남는** 문제가 남았다 —
    // 역연산은 전부 적용됐다고 가정한 좌표라 그 상태를 되돌리지 못한다.
    const original = "aaaa bbbb cccc dddd eeee";
    var idx: usize = 0;
    var failures: usize = 0;
    while (idx < 90) : (idx += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = idx });
        const a = failing.allocator();

        var buf = buffer.Buffer.init(a, original) catch continue;
        defer buf.deinit();

        var items = [_]selection.Selection{selection.Selection.at(0)};
        var sels = selection.Selections.init(&items, 0);

        const changes = [_]Change{
            .{ .start = 0, .end = 4, .text = "X" },
            .{ .start = 5, .end = 9, .text = "YY" },
            .{ .start = 10, .end = 14, .text = "ZZZ" },
        };
        if (apply(a, &buf, .{ .changes = &changes }, &sels)) |inv| {
            var done = inv;
            done.deinit();
        } else |_| {
            failures += 1;
            const after = buf.copyAll(testing.allocator) catch continue;
            defer testing.allocator.free(after);
            try testing.expectEqualStrings(original, after);
            // selection도 안 밀렸다 — 매핑은 버퍼가 다 바뀐 뒤에만 돈다.
            try testing.expectEqual(@as(usize, 0), sels.items[0].focus);
        }
    }
    try testing.expect(failures > 0); // 실패를 못 만들었으면 아무것도 판정하지 않은 것이다
}
