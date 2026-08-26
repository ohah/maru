//! 편집기 클립보드 — **멀티 커서가 규칙을 규정한다**
//! ([native-editor-document-model.md](../../../docs/native-editor-document-model.md) §3.4).
//!
//! selection이 배열(§3.2)이라 복사·붙여넣기가 단순하지 않다. 시스템 클립보드에는 **통짜 문자열**
//! 하나만 들어가므로(다른 앱이 붙여넣을 때 자연스러우라고 §3.4가 정했다), 조각이 몇 개였는지는
//! **앱이 따로 기억해야** 한다. 이 모듈이 그 기억을 값으로 만든다.
//!
//! **왜 별도 모듈인가**: 이 기억은 *"클립보드 문자열이 그 사이 바뀌지 않았는가"*를 판정해야 하고
//! (외부 앱이 복사하면 우리 경계는 무의미하다), 그 판정은 순수 계산이다. L3에 두면 픽스처 없이
//! 못 재고, 다른 소비처(붙여넣기·줄 단위 삽입)가 각자 판정을 복사하게 된다.

const std = @import("std");

/// 조각 경계 포맷 version(§3.4).
///
/// **없으면 포맷을 바꾼 뒤 옛 값을 잘못 해석한다.** 경계 표현이 달라졌는데 옛 메타데이터가 남아
/// 있으면 조각 수가 맞는 것처럼 보여 **엉뚱한 분배**가 된다 — 버리려면 버릴 근거가 있어야 한다.
/// VSCode의 클립보드 메타데이터(`{version, isFromEmptySelection, multicursorText, mode}`)에서
/// 확인한 축이다.
pub const format_version: u32 = 1;

/// 한 번의 복사가 남긴 기억.
///
/// **시스템 클립보드 문자열 자체는 여기 없다.** 그것은 OS가 들고 있고 우리 것이 아니다 —
/// 이 값은 *"그 문자열이 우리가 넣은 그것이면, 조각은 이렇게 나뉜다"*는 **부가 정보**다.
pub const Meta = struct {
    version: u32 = format_version,
    /// 우리가 클립보드에 넣은 문자열(소유). **이것과 다르면 남의 것**이다.
    text: []const u8,
    /// 조각마다 `text` 안의 끝 offset. 조각 수 = `ends.len`.
    ///
    /// **시작이 아니라 끝을 든다** — 조각 사이 구분자(`\n`)가 한 byte라 시작은 끝에서 나오지만,
    /// 마지막 조각의 끝은 시작 목록만으로는 나오지 않는다(길이를 따로 들어야 한다).
    ends: []const usize,
    /// **선택 없이 복사했는가**(§3.4 — caret이 있는 줄 전체를 담았다).
    ///
    /// 이 표식이 서 있으면 붙여넣기가 **caret 위치가 아니라 줄 단위로** 삽입한다. 줄 중간에
    /// 끼워 넣으면 줄이 깨지기 때문이다.
    from_empty_selection: bool = false,
    /// 언어 id — 붙여넣기 시 자동 들여쓰기·주석 토글이 언어별로 다르다(§3.7).
    /// **같은 앱 안의 복사·붙여넣기에서만 유효하다.**
    language: []const u8 = "",

    pub fn deinit(self: *Meta, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        allocator.free(self.ends);
        if (self.language.len > 0) allocator.free(self.language);
        self.* = undefined;
    }

    pub fn pieceCount(self: Meta) usize {
        return self.ends.len;
    }

    /// `i`번째 조각. 범위 밖이면 `null`.
    pub fn piece(self: Meta, i: usize) ?[]const u8 {
        if (i >= self.ends.len) return null;
        const start = if (i == 0) 0 else self.ends[i - 1] + 1; // 구분자 `\n` 하나를 건너뛴다
        const end = self.ends[i];
        if (start > end or end > self.text.len) return null;
        return self.text[start..end];
    }
};

/// 이 메타가 **지금 클립보드 내용을 설명하는가**(§3.4 — "외부에서 온 클립보드는 항상 통짜다").
///
/// **문자열을 비교한다.** 시스템 클립보드가 그 사이 바뀌었으면(다른 앱이 복사했으면) 우리가 기억한
/// 경계는 남의 문자열을 자르는 것이 되고, 그러면 **사용자가 복사한 적 없는 조각**이 커서마다
/// 들어간다. version이 다른 것도 같은 이유로 남이다 — 포맷이 달라졌으면 해석할 수 없다.
pub fn describes(meta: ?Meta, clipboard: []const u8) bool {
    const m = meta orelse return false;
    if (m.version != format_version) return false;
    return std.mem.eql(u8, m.text, clipboard);
}

/// 붙여넣기가 커서마다 넣을 것.
pub const Distribution = union(enum) {
    /// 커서마다 자기 조각. 길이는 커서 수와 같다.
    per_cursor: []const []const u8,
    /// 전부에 같은 통짜.
    whole: []const u8,
};

/// **개수가 맞을 때만 분배한다**(§3.4).
///
/// 클립보드 조각 수와 커서 수가 **같으면** 각 커서에 자기 조각을, **다르면** 전체 텍스트를 모두에
/// 똑같이 넣는다. 개수가 다른데 억지로 나누면(앞에서부터 잘라 넣거나 남는 것을 버리면) 사용자가
/// **예측할 수 없다** — 그 절이 그렇게 적은 이유다.
///
/// `out`은 호출자가 준 저장소이고 `per_cursor`가 그것을 빌린다.
pub fn distribute(
    meta: ?Meta,
    clipboard: []const u8,
    cursor_count: usize,
    out: [][]const u8,
) Distribution {
    if (!describes(meta, clipboard)) return .{ .whole = clipboard };
    const m = meta.?;
    if (m.pieceCount() != cursor_count) return .{ .whole = clipboard };
    if (out.len < cursor_count) return .{ .whole = clipboard };
    for (0..cursor_count) |i| out[i] = m.piece(i) orelse return .{ .whole = clipboard };
    return .{ .per_cursor = out[0..cursor_count] };
}

// ── 판정자 ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn makeMeta(allocator: std.mem.Allocator, pieces: []const []const u8) !Meta {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(allocator);
    var ends: std.ArrayList(usize) = .empty;
    errdefer ends.deinit(allocator);
    for (pieces, 0..) |p, i| {
        if (i > 0) try text.append(allocator, '\n');
        try text.appendSlice(allocator, p);
        try ends.append(allocator, text.items.len);
    }
    return .{
        .text = try text.toOwnedSlice(allocator),
        .ends = try ends.toOwnedSlice(allocator),
    };
}

test "CLIP1: 조각을 넣은 그대로 되꺼낸다 — 경계가 구분자를 건너뛴다" {
    // **구분자를 조각에 포함시키면** 붙여넣기가 커서마다 개행을 하나씩 더 넣는다.
    var m = try makeMeta(testing.allocator, &.{ "alpha", "beta", "gamma" });
    defer m.deinit(testing.allocator);

    try testing.expectEqualStrings("alpha\nbeta\ngamma", m.text);
    try testing.expectEqual(@as(usize, 3), m.pieceCount());
    try testing.expectEqualStrings("alpha", m.piece(0).?);
    try testing.expectEqualStrings("beta", m.piece(1).?);
    try testing.expectEqualStrings("gamma", m.piece(2).?);
    try testing.expect(m.piece(3) == null);
}

test "CLIP2: 빈 조각도 조각이다 — 개수가 줄면 분배가 어긋난다" {
    // 빈 줄을 고른 커서가 있으면 조각이 빈 문자열이 된다. 그것을 빼면 조각 수가 커서 수와
    // 달라져 **통짜 분배로 떨어지고**, 사용자는 빈 줄 하나 때문에 전혀 다른 결과를 본다.
    var m = try makeMeta(testing.allocator, &.{ "a", "", "b" });
    defer m.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), m.pieceCount());
    try testing.expectEqualStrings("a", m.piece(0).?);
    try testing.expectEqualStrings("", m.piece(1).?);
    try testing.expectEqualStrings("b", m.piece(2).?);
}

test "CLIP3: 클립보드가 바뀌었으면 남의 것이다 (§3.4)" {
    // **외부에서 온 클립보드는 항상 통짜다.** 우리 경계로 남의 문자열을 자르면 사용자가 복사한
    // 적 없는 조각이 커서마다 들어간다.
    var m = try makeMeta(testing.allocator, &.{ "a", "b" });
    defer m.deinit(testing.allocator);

    try testing.expect(describes(m, "a\nb")); // 우리가 넣은 그것
    try testing.expect(!describes(m, "a\nb\n")); // 한 byte만 달라도 남의 것
    try testing.expect(!describes(m, "other")); //

    // **version이 다르면 해석할 수 없다** — 경계 포맷이 바뀐 뒤 옛 값이 남은 경우다.
    var stale = m;
    stale.version = format_version + 1;
    try testing.expect(!describes(stale, "a\nb"));

    try testing.expect(!describes(null, "a\nb")); // 기억이 없으면 통짜
}

test "CLIP6: 길이가 같아도 내용이 다르면 남의 것이다 (§3.4)" {
    // **길이만 비교하면 같은 길이의 남의 문자열이 통과한다** — 그러면 우리 경계로 그것을 잘라
    // **사용자가 복사한 적 없는 조각**이 커서마다 들어간다. 우연히 길이가 겹치는 일은 흔하다
    // (짧은 낱말 둘, 경로 조각 둘…). 적대적 검증 2026-08-26이 이 축을 열었다.
    var m = try makeMeta(testing.allocator, &.{ "a", "b" });
    defer m.deinit(testing.allocator);

    try testing.expect(describes(m, "a\nb"));
    try testing.expect(!describes(m, "xyz")); // 길이 3으로 같지만 남의 것
    var out: [2][]const u8 = undefined;
    switch (distribute(m, "xyz", 2, &out)) {
        .whole => |w| try testing.expectEqualStrings("xyz", w),
        .per_cursor => return error.ExpectedWhole,
    }
}

test "CLIP7: 저장소가 모자라면 통짜로 떨어진다 — 범위 밖을 쓰지 않는다" {
    // `distribute`가 `out`을 빌려 채우므로 **호출자가 준 크기를 넘으면 남의 메모리를 쓴다.**
    // 지금 유일한 호출자는 커서 수만큼 잡지만, 그 결합이 이 함수 밖에 있어 호출자가 바뀌면
    // 조용히 깨진다(적대적 검증 2026-08-26 — 그 검사를 지운 뮤턴트가 살아남았다).
    var m = try makeMeta(testing.allocator, &.{ "a", "b", "c" });
    defer m.deinit(testing.allocator);

    var small: [2][]const u8 = undefined;
    switch (distribute(m, "a\nb\nc", 3, &small)) { // 커서 셋인데 저장소 둘
        .whole => |w| try testing.expectEqualStrings("a\nb\nc", w),
        .per_cursor => return error.ExpectedWhole,
    }
}

test "CLIP8: 경계가 문자열을 넘으면 조각이 없다 — 통짜로 떨어진다" {
    // `Meta`는 공개 구조체라 **우리가 만들지 않은 값**이 올 수 있다(복원·다른 소비처). 경계가
    // 문자열 밖을 가리키면 자르다가 **범위 밖을 읽는다**.
    const text = try testing.allocator.dupe(u8, "ab");
    const ends = try testing.allocator.dupe(usize, &.{ 2, 99 }); // 둘째 경계가 문자열 밖
    var m = Meta{ .text = text, .ends = ends };
    defer m.deinit(testing.allocator);

    try testing.expect(m.piece(0) != null);
    try testing.expect(m.piece(1) == null); // **읽지 않고 없다고 답한다**

    var out: [2][]const u8 = undefined;
    switch (distribute(m, "ab", 2, &out)) {
        .whole => |w| try testing.expectEqualStrings("ab", w),
        .per_cursor => return error.ExpectedWhole,
    }
}

test "CLIP4: 개수가 맞을 때만 분배한다 (§3.4)" {
    var m = try makeMeta(testing.allocator, &.{ "one", "two" });
    defer m.deinit(testing.allocator);
    var out: [4][]const u8 = undefined;

    // 맞으면 하나씩.
    switch (distribute(m, "one\ntwo", 2, &out)) {
        .per_cursor => |ps| {
            try testing.expectEqual(@as(usize, 2), ps.len);
            try testing.expectEqualStrings("one", ps[0]);
            try testing.expectEqualStrings("two", ps[1]);
        },
        .whole => return error.ExpectedPerCursor,
    }

    // **다르면 전부에 통짜** — 억지로 나누지 않는다.
    for ([_]usize{ 1, 3 }) |n| {
        switch (distribute(m, "one\ntwo", n, &out)) {
            .whole => |w| try testing.expectEqualStrings("one\ntwo", w),
            .per_cursor => return error.ExpectedWhole,
        }
    }

    // 클립보드가 남의 것이면 개수가 맞아도 통짜다.
    switch (distribute(m, "someone else", 2, &out)) {
        .whole => |w| try testing.expectEqualStrings("someone else", w),
        .per_cursor => return error.ExpectedWhole,
    }
}

test "CLIP5: 선택 없이 복사한 것은 줄 단위로 기억된다 (§3.4)" {
    // 이 표식이 없으면 붙여넣기가 caret 위치에 끼워 넣어 **줄이 깨진다**.
    var m = try makeMeta(testing.allocator, &.{"const x = 1;\n"});
    defer m.deinit(testing.allocator);
    try testing.expect(!m.from_empty_selection); // 기본은 선택 복사다

    m.from_empty_selection = true;
    try testing.expect(m.from_empty_selection);
    // 줄 단위여도 조각 수는 그대로다 — 분배 규칙은 같은 축이 아니다.
    try testing.expectEqual(@as(usize, 1), m.pieceCount());
}
