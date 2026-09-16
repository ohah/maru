//! 진단 층의 순수 계산(docs/native-editor-visual-mapping.md §5 · §5.4).
//!
//! 진단은 **범위 + severity + 출처 + 메시지**이고, 출처가 여럿이어도 목록은 하나다(§5 「출처가 여럿이어도 층은 하나」).
//! 이 모듈은 그 목록 위의 규칙만 든다 — **범위를 줄로 접는 규칙**(gutter 마커는 시작 줄에 하나, severity 최고), **줄마다의
//! 밑줄 조각**(여러 줄에 걸친 진단은 줄마다 그 줄에 걸친 부분), **다음/이전 이동**(caret 줄 기준, 감김). 트리에서 진단을
//! 뽑는 것은 `syntax.Provider.syntaxErrors` 가, 그리기·키는 위층이 한다.

const std = @import("std");

/// 낮은 것부터 — `@intFromEnum` 비교가 곧 우선순위다(§5 「error > warning > info > hint」).
pub const Severity = enum(u8) {
    hint = 0,
    info = 1,
    warning = 2,
    @"error" = 3,

    pub fn atLeast(self: Severity, other: Severity) bool {
        return @intFromEnum(self) >= @intFromEnum(other);
    }
};

/// 어느 층이 냈나 — 표시가 아니라 메타데이터다(§5). LSP·린트는 같은 목록에 합쳐질 때 이 값으로 자기 것을 걷어 낸다.
pub const Source = enum(u8) { syntax, lsp, lint };

pub const Diagnostic = struct {
    /// 문서 절대 byte(§3.1). `end` 는 반열림. `MISSING` 처럼 폭이 없는 것도 **1 byte 는 준다**(§5.4) — 폭 0 은 그릴 수 없다.
    start: u32,
    end: u32,
    severity: Severity,
    source: Source = .syntax,
    /// 정적 문자열 또는 출처가 소유하는 메모리 — 이 모듈은 소유하지 않는다.
    message: []const u8 = "",
};

/// `start` 오름차순, 같으면 severity 높은 것이 앞(줄 접기가 첫 항목을 그대로 쓸 수 있게).
pub fn lessThan(_: void, a: Diagnostic, b: Diagnostic) bool {
    if (a.start != b.start) return a.start < b.start;
    return @intFromEnum(a.severity) > @intFromEnum(b.severity);
}

pub fn sort(items: []Diagnostic) void {
    std.mem.sort(Diagnostic, items, {}, lessThan);
}

/// 한 줄의 밑줄 조각 — 줄 안 byte 로(`frame.Mark` 와 같은 축).
pub const LinePiece = struct { start: u32, len: u32, severity: Severity };

/// **범위 → 줄 조각.** `line_start`/`line_end` 는 그 줄의 문서 byte 구간(개행 제외, 반열림). 진단이 그 줄에 걸치면 걸친 부분을
/// 돌려주고, 아니면 `null`. 빈 줄에 걸친 진단(폭 0)은 조각도 0 이라 `null` — 그릴 셀이 없다.
pub fn pieceOnLine(d: Diagnostic, line_start: u32, line_end: u32) ?LinePiece {
    const a = @max(d.start, line_start);
    const b = @min(d.end, line_end);
    if (b <= a) return null;
    return .{ .start = a - line_start, .len = b - a, .severity = d.severity };
}

/// **gutter 마커의 severity** — 이 줄에서 **시작하는** 진단 중 최고(§5 「여러 줄에 걸친 진단은 시작 줄에만」). 목록은 정렬돼
/// 있어야 한다. 없으면 `null`.
pub fn markerOnLine(sorted: []const Diagnostic, line_start: u32, line_end_incl_newline: u32) ?Severity {
    var best: ?Severity = null;
    // 이진 탐색으로 첫 후보를 찾는다 — 12만 줄 문서에서 줄마다 선형으로 훑으면 O(줄 × 진단)이다.
    var lo: usize = 0;
    var hi: usize = sorted.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (sorted[mid].start < line_start) lo = mid + 1 else hi = mid;
    }
    var i = lo;
    while (i < sorted.len and sorted[i].start < line_end_incl_newline) : (i += 1) {
        const s = sorted[i].severity;
        if (best == null or s.atLeast(best.?)) best = s;
    }
    return best;
}

pub const Direction = enum { next, prev };

/// **다음/이전 진단**(§5.4 이동) — 기준은 `cur_line` 의 줄 범위 `[cur_start, cur_end)`: 「다음」은 그 줄 **뒤**에서 시작하는 첫
/// 진단, 없으면 첫 진단(감김); 「이전」은 그 줄 **앞**에서 시작하는 마지막 진단, 없으면 마지막. 같은 줄의 것은 건너뛴다 —
/// 그 줄에 서 있으면 「다음」은 그다음이어야 한다(F7 과 같은 규칙). 목록이 비면 `null`.
pub fn step(sorted: []const Diagnostic, cur_start: u32, cur_end: u32, dir: Direction) ?usize {
    if (sorted.len == 0) return null;
    switch (dir) {
        .next => {
            for (sorted, 0..) |d, i| {
                if (d.start >= cur_end) return i;
            }
            return 0;
        },
        .prev => {
            var i: usize = sorted.len;
            while (i > 0) : (i -= 1) {
                if (sorted[i - 1].start < cur_start) return i - 1;
            }
            return sorted.len - 1;
        },
    }
}

// ── 판정 ────────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "DG1 정렬은 start 오름차순, 같으면 severity 높은 것이 앞 (§5.4)" {
    var items = [_]Diagnostic{
        .{ .start = 10, .end = 12, .severity = .hint },
        .{ .start = 4, .end = 6, .severity = .warning },
        .{ .start = 10, .end = 11, .severity = .@"error" },
    };
    sort(&items);
    try testing.expectEqual(@as(u32, 4), items[0].start);
    try testing.expectEqual(Severity.@"error", items[1].severity);
    try testing.expectEqual(Severity.hint, items[2].severity);
}

test "DG2 줄 조각 — 걸친 부분만, 줄 안 byte 로; 안 걸치면 null; 폭 0 도 null (§5.4)" {
    const d: Diagnostic = .{ .start = 5, .end = 14, .severity = .@"error" };
    // 줄 [0,8): 5..8 → start 5 len 3
    const p0 = pieceOnLine(d, 0, 8) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 5), p0.start);
    try testing.expectEqual(@as(u32, 3), p0.len);
    // 줄 [9,20): 9..14 → start 0 len 5
    const p1 = pieceOnLine(d, 9, 20) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 0), p1.start);
    try testing.expectEqual(@as(u32, 5), p1.len);
    try testing.expectEqual(Severity.@"error", p1.severity);
    // 줄 [14,20): 반열림이라 안 걸친다
    try testing.expect(pieceOnLine(d, 14, 20) == null);
    // 빈 줄 [8,8) 에 걸친 진단: 폭 0 → null
    try testing.expect(pieceOnLine(d, 8, 8) == null);
}

test "DG3 gutter 마커는 시작 줄에만, 한 줄에 여럿이면 severity 최고 (§5)" {
    var items = [_]Diagnostic{
        .{ .start = 2, .end = 30, .severity = .warning }, // 줄 0 에서 시작해 줄 2 까지
        .{ .start = 3, .end = 4, .severity = .hint },
        .{ .start = 12, .end = 13, .severity = .@"error" }, // 줄 1
    };
    sort(&items);
    // 줄 0 = [0,10) (개행 포함 끝 10), 줄 1 = [10,20), 줄 2 = [20,40)
    try testing.expectEqual(Severity.warning, markerOnLine(&items, 0, 10).?);
    try testing.expectEqual(Severity.@"error", markerOnLine(&items, 10, 20).?);
    try testing.expect(markerOnLine(&items, 20, 40) == null); // 걸치기만 하고 시작하지 않는다
    try testing.expect(markerOnLine(&.{}, 0, 10) == null);
    // **줄의 첫 byte 에서 시작하는** 진단도 잡는다 — 이진 탐색이 `<=` 로 한 칸 지나치면 이것만 빠진다(적대적 1회차 A4).
    var at_start = [_]Diagnostic{ .{ .start = 0, .end = 1, .severity = .hint }, .{ .start = 20, .end = 21, .severity = .info } };
    sort(&at_start);
    try testing.expectEqual(Severity.info, markerOnLine(&at_start, 20, 40).?);
    try testing.expectEqual(Severity.hint, markerOnLine(&at_start, 0, 10).?);
    // 한 줄에서 **낮은 것이 먼저** 오고 높은 것이 뒤에 와도 최고를 고른다 — 첫 항목을 쓰는 변이는 DG3 의 첫 줄(높은 것이 먼저)
    // 에서 살았다(적대적 1회차 A5).
    var low_first = [_]Diagnostic{ .{ .start = 21, .end = 22, .severity = .hint }, .{ .start = 25, .end = 26, .severity = .@"error" } };
    sort(&low_first);
    try testing.expectEqual(Severity.@"error", markerOnLine(&low_first, 20, 40).?);
    // `atLeast` 는 같음을 포함한다(9회차 I5) — 「최고」 판정에서는 등가지만 이름이 약속하는 뜻이다.
    try testing.expect(Severity.warning.atLeast(.warning) and Severity.@"error".atLeast(.hint) and !Severity.hint.atLeast(.info));
}

test "DG4 다음/이전은 caret 줄을 건너뛰고 감긴다 (§5.4)" {
    var items = [_]Diagnostic{
        .{ .start = 5, .end = 6, .severity = .@"error" },
        .{ .start = 25, .end = 26, .severity = .warning },
        .{ .start = 27, .end = 28, .severity = .info },
        .{ .start = 60, .end = 61, .severity = .hint },
    };
    sort(&items);
    // caret 줄 [20,30): 다음 = 60(줄 안의 25·27 은 건너뛴다), 이전 = 5
    try testing.expectEqual(@as(?usize, 3), step(&items, 20, 30, .next));
    try testing.expectEqual(@as(?usize, 0), step(&items, 20, 30, .prev));
    // 마지막 줄 [60,70) 에서 다음은 감겨 첫 것, 첫 줄 [0,10) 에서 이전은 감겨 마지막 것
    try testing.expectEqual(@as(?usize, 0), step(&items, 60, 70, .next));
    try testing.expectEqual(@as(?usize, 3), step(&items, 0, 10, .prev));
    try testing.expect(step(&.{}, 0, 10, .next) == null);
}
