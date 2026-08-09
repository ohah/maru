//! caret과 선택 범위 — **항상 배열이다**([native-editor.md](../../../docs/native-editor.md) §3.2).
//!
//! 멀티 커서가 1급 결정이라 단수 selection을 두었다가 나중에 배열로 넓히면 편집 연산을 전부
//! 재작성해야 한다. 그래서 커서가 하나뿐인 N1에서도 배열로 시작한다.
//!
//! **위치는 byte offset이다**(§3.1). 줄·열이 아니라서 랩·접힘·가상 텍스트에 영향받지 않는다.

const std = @import("std");

/// 선택 하나. `anchor`는 고정 끝, `focus`는 움직이는 끝이다(caret이 있는 쪽).
///
/// **둘의 순서를 강제하지 않는다.** 위로 끌면 `focus < anchor`가 되는데, 그 방향이 곧 사용자가
/// 어느 쪽을 늘리고 있는지이므로 정규화하면 정보를 잃는다. 범위가 필요한 곳은 `start()`/`end()`를 쓴다.
pub const Selection = struct {
    anchor: usize,
    focus: usize,
    /// 세로 이동 시 유지할 목표 시각 열. **L2는 이 값을 해석하지 않는다**(§3.2) — 시각 열은 뷰 폭·랩·
    /// 접힘에 의존하는 L3 개념이라, 여기서는 selection과 생사를 같이하도록 들고만 있는다.
    goal_col: ?u32 = null,

    /// caret 하나(선택 없음)를 만든다.
    pub fn at(offset: usize) Selection {
        return .{ .anchor = offset, .focus = offset };
    }

    pub fn start(self: Selection) usize {
        return @min(self.anchor, self.focus);
    }

    pub fn end(self: Selection) usize {
        return @max(self.anchor, self.focus);
    }

    /// 선택된 byte 수. caret이면 0이다.
    pub fn len(self: Selection) usize {
        return self.end() - self.start();
    }

    /// 범위 없이 caret만 있는 상태인가.
    pub fn isEmpty(self: Selection) bool {
        return self.anchor == self.focus;
    }

    /// 두 selection이 겹치거나 맞닿는가. **맞닿는 것도 겹침으로 본다** — `[0,5)`와 `[5,9)`를 그대로
    /// 두면 그 경계에 두 caret이 남아 같은 자리에 두 번 삽입된다.
    pub fn touches(self: Selection, other: Selection) bool {
        return self.start() <= other.end() and other.start() <= self.end();
    }
};

/// selection 배열. **항상 1개 이상**이고 `primary`는 그 안의 유효한 인덱스다.
///
/// 0개를 허용하면 모든 소비처가 "커서 없음" 분기를 져야 한다. 편집기는 빈 파일에도 커서를 보이므로
/// 그 상태가 존재하지 않는다.
pub const Selections = struct {
    items: []Selection,
    primary: usize,

    /// primary selection. 스크롤 추종·상태바 위치 표시의 기준이다(§3.2).
    pub fn primarySelection(self: Selections) Selection {
        return self.items[self.primary];
    }

    /// 커서 개수. 상태바가 "여럿이면 커서 개수"를 표시할 때 쓴다(§2.2).
    pub fn count(self: Selections) usize {
        return self.items.len;
    }

    /// 선택된 총 byte 수(모든 selection 합).
    pub fn totalSelected(self: Selections) usize {
        var total: usize = 0;
        for (self.items) |s| total += s.len();
        return total;
    }
};

/// 겹치는 selection들을 합치고 primary를 승계시킨다.
///
/// **primary가 사라지면 그것을 흡수한 selection이 primary를 승계한다**(§3.2). 승계 규칙이 없으면
/// 병합 후 primary 인덱스가 엉뚱한 selection을 가리켜 스크롤이 튄다.
///
/// `items`를 **제자리에서** 정렬·병합하고 남은 개수를 돌려준다. 호출자가 slice를 줄여 쓴다.
/// 할당하지 않으므로 편집 hot path에서 부담이 없다.
pub fn mergeOverlapping(items: []Selection, primary: usize) struct { len: usize, primary: usize } {
    if (items.len <= 1) return .{ .len = items.len, .primary = primary };

    // 어느 selection이 primary였는지를 정렬 전에 표시해 둔다. 정렬이 인덱스를 흩뜨리므로
    // 위치가 아니라 **값**으로 따라가야 한다.
    const primary_anchor = items[primary].anchor;
    const primary_focus = items[primary].focus;

    std.mem.sort(Selection, items, {}, lessByStart);

    var write: usize = 0;
    var new_primary: usize = 0;
    var primary_found = false;

    var read: usize = 0;
    while (read < items.len) : (read += 1) {
        const cur = items[read];
        const is_primary = cur.anchor == primary_anchor and cur.focus == primary_focus;

        if (write > 0 and items[write - 1].touches(cur)) {
            // 흡수: 범위를 넓힌다. 방향은 **살아남은 쪽**의 것을 쓴다 — 병합 결과의 caret이
            // 어디 있어야 하는지는 정할 수 없고, 임의로 뒤집으면 다음 shift+이동이 반대로 간다.
            const prev = items[write - 1];
            const lo = @min(prev.start(), cur.start());
            const hi = @max(prev.end(), cur.end());
            const reversed = prev.focus < prev.anchor;
            items[write - 1] = .{
                .anchor = if (reversed) hi else lo,
                .focus = if (reversed) lo else hi,
                // goal_col은 버린다. 병합된 범위의 "목표 열"은 어느 쪽 것도 맞지 않는다.
                .goal_col = null,
            };
            // 흡수된 것이 primary였으면 흡수한 쪽이 승계한다.
            if (is_primary) {
                new_primary = write - 1;
                primary_found = true;
            }
        } else {
            items[write] = cur;
            if (is_primary) {
                new_primary = write;
                primary_found = true;
            }
            write += 1;
        }
    }

    // 값으로 못 찾는 경우(같은 값이 여럿이라 앞엣것이 먼저 매칭됨)는 0으로 떨어뜨린다 —
    // 유효한 인덱스인 것이 중요하고, 같은 값이면 어느 쪽을 가리켜도 동작이 같다.
    return .{ .len = write, .primary = if (primary_found) new_primary else 0 };
}

fn lessByStart(_: void, a: Selection, b: Selection) bool {
    if (a.start() != b.start()) return a.start() < b.start();
    return a.end() < b.end();
}

const testing = std.testing;

test "caret은 빈 선택이다" {
    const c = Selection.at(5);
    try testing.expect(c.isEmpty());
    try testing.expectEqual(@as(usize, 0), c.len());
    try testing.expectEqual(@as(usize, 5), c.start());
    try testing.expectEqual(@as(usize, 5), c.end());
}

test "역방향 선택도 그대로 유지된다 — 방향이 정보다" {
    const back = Selection{ .anchor = 10, .focus = 3 };

    // 정규화하지 않는다. focus가 앞이라는 것이 "위로 끌고 있다"는 뜻이다.
    try testing.expectEqual(@as(usize, 10), back.anchor);
    try testing.expectEqual(@as(usize, 3), back.focus);
    // 범위 질의는 방향과 무관하게 답한다.
    try testing.expectEqual(@as(usize, 3), back.start());
    try testing.expectEqual(@as(usize, 10), back.end());
    try testing.expectEqual(@as(usize, 7), back.len());
}

test "맞닿는 범위도 겹침으로 본다 — 경계에 caret 둘이 남으면 중복 삽입된다" {
    const a = Selection{ .anchor = 0, .focus = 5 };
    const b = Selection{ .anchor = 5, .focus = 9 };
    try testing.expect(a.touches(b));
    try testing.expect(b.touches(a));

    const far = Selection{ .anchor = 6, .focus = 9 };
    try testing.expect(!a.touches(far));
}

test "merge: 겹치지 않으면 그대로 둔다" {
    var items = [_]Selection{
        Selection.at(0),
        Selection.at(10),
        Selection.at(20),
    };
    const r = mergeOverlapping(&items, 1);

    try testing.expectEqual(@as(usize, 3), r.len);
    try testing.expectEqual(@as(usize, 1), r.primary);
    try testing.expectEqual(@as(usize, 10), items[r.primary].anchor);
}

test "merge: 정렬되지 않은 입력도 처리한다" {
    var items = [_]Selection{
        Selection.at(20),
        Selection.at(0),
        Selection.at(10),
    };
    const r = mergeOverlapping(&items, 0); // primary는 offset 20

    try testing.expectEqual(@as(usize, 3), r.len);
    // 정렬 후 20은 마지막이다 — 인덱스가 아니라 값을 따라가야 한다.
    try testing.expectEqual(@as(usize, 20), items[r.primary].anchor);
}

test "merge: 겹치는 둘을 합친다" {
    var items = [_]Selection{
        .{ .anchor = 0, .focus = 6 },
        .{ .anchor = 4, .focus = 10 },
    };
    const r = mergeOverlapping(&items, 0);

    try testing.expectEqual(@as(usize, 1), r.len);
    try testing.expectEqual(@as(usize, 0), items[0].start());
    try testing.expectEqual(@as(usize, 10), items[0].end());
}

test "merge: primary가 흡수되면 흡수한 쪽이 승계한다" {
    var items = [_]Selection{
        .{ .anchor = 0, .focus = 6 },
        .{ .anchor = 4, .focus = 10 }, // 이것이 primary인데 위와 겹친다
    };
    const r = mergeOverlapping(&items, 1);

    try testing.expectEqual(@as(usize, 1), r.len);
    // 승계했으므로 유효한 인덱스여야 한다 — 1을 그대로 두면 범위 밖을 가리킨다.
    try testing.expect(r.primary < r.len);
    try testing.expectEqual(@as(usize, 0), r.primary);
}

test "merge: 병합 결과가 방향을 뒤집지 않는다" {
    // 살아남은 쪽이 역방향이면 결과도 역방향이어야 한다 — 뒤집으면 다음 shift+이동이 반대로 간다.
    var items = [_]Selection{
        .{ .anchor = 6, .focus = 0 }, // 역방향
        .{ .anchor = 4, .focus = 10 },
    };
    const r = mergeOverlapping(&items, 0);

    try testing.expectEqual(@as(usize, 1), r.len);
    try testing.expect(items[0].focus < items[0].anchor); // 역방향 유지
    try testing.expectEqual(@as(usize, 0), items[0].start());
    try testing.expectEqual(@as(usize, 10), items[0].end());
}

test "merge: 셋이 사슬로 이어지면 하나가 된다" {
    var items = [_]Selection{
        .{ .anchor = 0, .focus = 5 },
        .{ .anchor = 4, .focus = 9 },
        .{ .anchor = 8, .focus = 12 },
    };
    const r = mergeOverlapping(&items, 0);

    try testing.expectEqual(@as(usize, 1), r.len);
    try testing.expectEqual(@as(usize, 12), items[0].end());
}

test "merge: 병합된 selection은 goal_col을 버린다" {
    var items = [_]Selection{
        .{ .anchor = 0, .focus = 6, .goal_col = 3 },
        .{ .anchor = 4, .focus = 10, .goal_col = 7 },
    };
    _ = mergeOverlapping(&items, 0);

    // 어느 쪽 목표 열도 병합 범위에 맞지 않는다.
    try testing.expectEqual(@as(?u32, null), items[0].goal_col);
}

test "merge: 하나짜리는 그대로다" {
    var items = [_]Selection{Selection.at(3)};
    const r = mergeOverlapping(&items, 0);
    try testing.expectEqual(@as(usize, 1), r.len);
    try testing.expectEqual(@as(usize, 0), r.primary);
}

test "Selections: primary와 개수·선택 합" {
    var items = [_]Selection{
        .{ .anchor = 0, .focus = 3 },
        .{ .anchor = 10, .focus = 14 },
    };
    const sels = Selections{ .items = &items, .primary = 1 };

    try testing.expectEqual(@as(usize, 2), sels.count());
    try testing.expectEqual(@as(usize, 7), sels.totalSelected());
    try testing.expectEqual(@as(usize, 10), sels.primarySelection().anchor);
}
