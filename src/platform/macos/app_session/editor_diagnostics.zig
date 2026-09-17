//! 진단 층의 제품 쪽(docs/native-editor-visual-mapping.md §5.4) — 목록을 채우고(첫 출처: 트리의 구문 오류), 렌더가 받는 세 표
//! (줄마다의 밑줄 조각 · 줄마다의 gutter severity · 마커 줄)로 편다. 규칙은 `session.editor.diagnostic` 이, 그리기는 chrome 이 든다.
//!
//! **저장소는 Term 이 들고 프레임마다 재사용한다** — 검색 마크(`editor_find_marks`)와 같은 관례. 세 표는 **보이는 줄 축**이다
//! (접히면 숨은 줄의 진단은 표에서 빠진다 — 마커도 밑줄도 「가면 도착하는 자리」가 아니라 그냥 안 보이는 것이 맞다: 접힌
//! 머리에 오류 표식을 얹는 규칙은 §5 가 검색 마커에만 정했다).

const std = @import("std");
const syntax = @import("syntax");
const maru = @import("maru");
const diagnostic = maru.session.editor.diagnostic;
const chrome_diag = maru.chrome.components.editor_view.diagnostic;
const LineIndex = maru.session.editor.line_index.LineIndex;

pub const Diagnostic = diagnostic.Diagnostic;

pub const State = struct {
    /// 정렬된 목록(§5.4 모델). 출처가 여럿이어도 하나다.
    list: std.ArrayList(Diagnostic) = .empty,
    /// 트리에서 뽑은 원본 — 매 프레임 재사용.
    raw: std.ArrayList(syntax.Provider.SyntaxError) = .empty,
    /// 언어 서버가 준 목록(§8.2a) — `publishDiagnostics` 마다 통째로 갈아 끼운다. 메시지는 `lsp_messages` 안의 조각.
    lsp: std.ArrayList(Diagnostic) = .empty,
    lsp_messages: std.ArrayList(u8) = .empty,
    /// 서버 목록이 바뀌었는데 아직 `list` 에 합치지 않았다.
    lsp_dirty: bool = false,
    /// 아래 셋은 **보이는 줄 축**의 표. 길이는 보이는 줄 수까지 자란다.
    marks: [][]const chrome_diag.Mark = &.{},
    mark_buf: []chrome_diag.Mark = &.{},
    markers: []?chrome_diag.Level = &.{},
    lines: []chrome_diag.LineMark = &.{},
    lines_len: usize = 0,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.list.deinit(allocator);
        self.raw.deinit(allocator);
        self.lsp.deinit(allocator);
        self.lsp_messages.deinit(allocator);
        if (self.marks.len > 0) allocator.free(self.marks);
        if (self.mark_buf.len > 0) allocator.free(self.mark_buf);
        if (self.markers.len > 0) allocator.free(self.markers);
        if (self.lines.len > 0) allocator.free(self.lines);
        self.* = .{};
    }
};

// 구문 오류 출처의 `message` 는 **표시 문장이 아니라 재료**다: `MISSING` 이면 기대 토큰 이름(문법이 소유하는 정적 문자열),
// `ERROR` 면 빈 문자열. 사람이 읽는 문장(「구문 오류」·「빠짐: ‹토큰›」)은 표시 자리(§8.3 호버)가 i18n 키로 만든다 — 여기
// 한국어를 박으면 영어 화면에 한국어가 섞인다(i18n 계약 §7).

/// **트리에서 목록을 다시 채운다**(§5.4 갱신 시점: 트리가 있을 때마다). 트리가 없으면(파싱이 끊긴 프레임) 직전 목록을 유지하고
/// `false`. 다른 출처(LSP·린트)가 생기면 여기서 `.syntax` 항목만 갈아 끼운다 — 지금은 목록이 곧 구문 오류다.
pub fn refreshFromSyntax(self: *State, allocator: std.mem.Allocator, provider: ?*syntax.Provider) bool {
    const had_tree = if (provider) |prov| (prov.syntaxErrors(allocator, &self.raw) catch false) else false;
    // 트리가 없어도 서버 목록이 바뀌었으면 합친다(§8.2a — 두 출처가 한 목록).
    if (!had_tree and !self.lsp_dirty) return false;
    self.lsp_dirty = false;
    self.list.clearRetainingCapacity();
    for (self.lsp.items) |d| self.list.append(allocator, d) catch break;
    for (self.raw.items) |e| {
        self.list.append(allocator, .{
            .start = e.start,
            .end = @max(e.end, e.start + 1), // 출처가 이미 1 byte 를 준다(`syntaxErrors`) — 여기 clamp 는 등가(적대적 2회차 B1), 규칙을 두 층이 함께 든다
            .severity = .@"error",
            .source = .syntax,
            .message = if (e.missing) e.expected else "",
        }) catch break; // 모자라면 앞부분만 — 목록은 이미 문서 순이라 「앞쪽」이 남는다
    }
    // 트리 순회(전위)가 이미 문서 순이라 오늘은 등가다(적대적 2회차 B2). 남기는 이유는 두 번째 출처다 — LSP 목록은 서버 순서라
    // 합치는 순간 이 정렬이 규칙이 된다.
    diagnostic.sort(self.list.items);
    return true;
}

pub const Views = struct {
    marks: []const []const chrome_diag.Mark,
    markers: []const ?chrome_diag.Level,
    lines: []const chrome_diag.LineMark,
};

/// 목록을 **보이는 줄 축**의 세 표로 편다. `visible_numbers` 가 비면 줄 = 문서 줄. 할당에 실패하면 `null`(그 프레임은 진단 없이) —
/// 검색 마크와 같은 저하.
pub fn buildViews(
    self: *State,
    allocator: std.mem.Allocator,
    line_idx: LineIndex,
    visible_numbers: []const ?u32,
    visible_len: usize,
) ?Views {
    const lines_len = if (visible_numbers.len > 0) visible_numbers.len else visible_len;
    // 빈 표와 `null` 은 소비자(프레임)에게 같다 — 등가(적대적 6회차 F5). 빈 표를 주는 이유는 뜻이다: 「셌는데 없다」 ≠ 「못 셌다」.
    if (lines_len == 0 or self.list.items.len == 0) return .{ .marks = &.{}, .markers = &.{}, .lines = &.{} };
    if (self.marks.len < lines_len) {
        const grown = allocator.alloc([]const chrome_diag.Mark, lines_len) catch return null;
        if (self.marks.len > 0) allocator.free(self.marks);
        self.marks = grown;
    }
    if (self.markers.len < lines_len) {
        const grown = allocator.alloc(?chrome_diag.Level, lines_len) catch return null;
        if (self.markers.len > 0) allocator.free(self.markers);
        self.markers = grown;
    }
    if (self.lines.len < lines_len) {
        const grown = allocator.alloc(chrome_diag.LineMark, lines_len) catch return null;
        if (self.lines.len > 0) allocator.free(self.lines);
        self.lines = grown;
    }
    // 조각 수 상한: 진단마다 걸치는 줄 수만큼 — 여러 줄 진단이 많으면 넘칠 수 있어 **줄 수 + 진단 수** 로 잡고 넘치면 자른다.
    const want_buf = self.list.items.len + lines_len;
    if (self.mark_buf.len < want_buf) {
        const grown = allocator.alloc(chrome_diag.Mark, want_buf) catch return null;
        if (self.mark_buf.len > 0) allocator.free(self.mark_buf);
        self.mark_buf = grown;
    }
    const marks = self.marks[0..lines_len];
    const markers = self.markers[0..lines_len];
    @memset(marks, &.{});
    @memset(markers, null);
    self.lines_len = 0;

    const sorted = self.list.items;
    var w: usize = 0;
    var di: usize = 0; // 이 줄 앞에서 끝난 진단은 지나간다(정렬 덕에 되돌릴 일이 없다 — 단, 여러 줄 진단은 끝이 늦어 뒤 줄에서 다시 본다)
    for (0..lines_len) |i| {
        const doc_line: usize = if (visible_numbers.len > 0) ((visible_numbers[i] orelse continue) - 1) else i;
        const ln = line_idx.line(doc_line) orelse continue;
        const ls: u32 = @intCast(ln.start);
        const le: u32 = @intCast(ln.contentEnd());
        const le_nl: u32 = @intCast(ln.end_with_ending);
        // 이 줄보다 앞에서 **시작하고 끝난** 진단은 건너뛴다 — 결과에는 등가(적대적 6회차 F2: 0 부터 훑어도 `pieceOnLine` 이
        // 걸러 낸다), 비용의 자리다(줄 × 진단이 되지 않게).
        while (di < sorted.len and sorted[di].end <= ls and sorted[di].start < ls) di += 1;
        const from = w;
        var j = di;
        while (j < sorted.len and sorted[j].start < le_nl) : (j += 1) {
            if (diagnostic.pieceOnLine(sorted[j], ls, le)) |pc| {
                if (w >= self.mark_buf.len) break;
                self.mark_buf[w] = .{ .start = pc.start, .len = pc.len, .level = toLevel(pc.severity) };
                w += 1;
            }
        }
        if (w > from) marks[i] = self.mark_buf[from..w];
        if (diagnostic.markerOnLine(sorted, ls, le_nl)) |sev| {
            markers[i] = toLevel(sev);
            self.lines[self.lines_len] = .{ .line = @intCast(i), .level = toLevel(sev) };
            self.lines_len += 1;
        }
    }
    return .{ .marks = marks, .markers = markers, .lines = self.lines[0..self.lines_len] };
}

pub fn toLevel(sev: diagnostic.Severity) chrome_diag.Level {
    return switch (sev) {
        .@"error" => .err,
        .warning => .warning,
        .info => .info,
        .hint => .hint,
    };
}

// ── 판정 ────────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "DGS1 표 펴기 — 여러 줄 진단은 줄마다 조각, 마커는 시작 줄만, 접힌(숨은) 줄은 표에서 빠진다 (§5.4)" {
    const allocator = testing.allocator;
    const src = "abc\ndefgh\nij\nklmno\n"; // 줄 시작 0·4·10·13
    var idx = try maru.session.editor.line_index.build(allocator, src);
    defer idx.deinit();
    var st: State = .{};
    defer st.deinit(allocator);
    try st.list.append(allocator, .{ .start = 1, .end = 12, .severity = .@"error" }); // 줄 0 의 1.. 부터 줄 2 의 2 까지
    try st.list.append(allocator, .{ .start = 14, .end = 16, .severity = .warning }); // 줄 3
    diagnostic.sort(st.list.items);

    // 접힘 없음.
    const v = buildViews(&st, allocator, idx, &.{}, 4) orelse return error.NoViews;
    try testing.expectEqual(@as(usize, 1), v.marks[0].len);
    try testing.expectEqual(@as(u32, 1), v.marks[0][0].start);
    try testing.expectEqual(@as(u32, 2), v.marks[0][0].len); // "bc"
    try testing.expectEqual(@as(u32, 0), v.marks[1][0].start);
    try testing.expectEqual(@as(u32, 5), v.marks[1][0].len); // "defgh"
    try testing.expectEqual(@as(u32, 2), v.marks[2][0].len); // "ij"
    try testing.expectEqual(chrome_diag.Level.warning, v.marks[3][0].level);
    try testing.expectEqual(@as(?chrome_diag.Level, .err), v.markers[0]);
    try testing.expect(v.markers[1] == null and v.markers[2] == null); // 걸치기만 — 마커 없음
    try testing.expectEqual(@as(?chrome_diag.Level, .warning), v.markers[3]);
    try testing.expectEqual(@as(usize, 2), v.lines.len);
    try testing.expectEqual(@as(u32, 3), v.lines[1].line);

    // 접힘: 보이는 줄이 0·3 뿐(1·2 는 숨었다) — 표는 보이는 줄 축.
    const nums = [_]?u32{ 1, 4 };
    const f = buildViews(&st, allocator, idx, &nums, 2) orelse return error.NoViews;
    try testing.expectEqual(@as(usize, 2), f.marks.len);
    try testing.expectEqual(@as(u32, 2), f.marks[0][0].len);
    try testing.expectEqual(chrome_diag.Level.warning, f.marks[1][0].level);
    try testing.expectEqual(@as(u32, 1), f.lines[1].line);

    // **한 줄에 진단이 줄 수보다 많아도** 조각이 다 선다 — 저장소를 줄 수로만 잡으면 셋째부터 잘린다(적대적 6회차 F1).
    var st2: State = .{};
    defer st2.deinit(allocator);
    try st2.list.append(allocator, .{ .start = 0, .end = 1, .severity = .@"error" });
    try st2.list.append(allocator, .{ .start = 2, .end = 3, .severity = .@"error" });
    try st2.list.append(allocator, .{ .start = 4, .end = 5, .severity = .@"error" });
    diagnostic.sort(st2.list.items);
    var idx2 = try maru.session.editor.line_index.build(allocator, "abcdef\ng\n");
    defer idx2.deinit();
    const v2 = buildViews(&st2, allocator, idx2, &.{}, 2) orelse return error.NoViews;
    try testing.expectEqual(@as(usize, 3), v2.marks[0].len);

    // **개행 byte 에서 시작하는 진단**(빠진 토큰이 줄 끝에 선다)은 그 줄의 마커다 — 줄 끝을 개행 제외로 재면 어느 줄에도 안 선다
    // (적대적 6회차 F4). 밑줄 조각은 폭 0 이라 없다(그릴 셀이 없다).
    var st3: State = .{};
    defer st3.deinit(allocator);
    try st3.list.append(allocator, .{ .start = 3, .end = 4, .severity = .@"error" }); // "abc\n" 의 '\n'
    const v3 = buildViews(&st3, allocator, idx, &.{}, 4) orelse return error.NoViews;
    try testing.expectEqual(@as(?chrome_diag.Level, .err), v3.markers[0]);
    try testing.expect(v3.markers[1] == null);
    try testing.expectEqual(@as(usize, 0), v3.marks[0].len);
    // severity → Level 은 넷이 제자리로(9회차 I7: info 를 hint 로 옮겨도 초록이었다 — 구문 출처는 error 뿐이라).
    try testing.expectEqual(chrome_diag.Level.err, toLevel(.@"error"));
    try testing.expectEqual(chrome_diag.Level.warning, toLevel(.warning));
    try testing.expectEqual(chrome_diag.Level.info, toLevel(.info));
    try testing.expectEqual(chrome_diag.Level.hint, toLevel(.hint));
}
