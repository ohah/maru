//! 단일행 입력 오버레이(find·palette)의 **공유 기반** — 컴포넌트가 아니라 두 입력 오버레이가 같은 모델을 쓰게 하는
//! neutral 헬퍼다. (1) `OverlayInput`: IME 조합을 보존하는 검색어 입력(query+preedit) 상태·전이, (2) `displayCols`:
//! UTF-8 표시 폭(EAW), (3) `panelLayout`: palette의 창-중앙 패널 레이아웃, (4) `findLayout`: find의 활성 pane 우상단
//! 레이아웃(p.active_pane 경계). 이주 전엔 find.zig·palette.zig에 같은 코드가
//! 복붙돼 있었다(C1 리뷰 cleanup으로 단일 출처화). 의존은 std + sibling chrome(draw/props) + ../../width.zig뿐
//! (chrome neutral). 단일 출처: docs/chrome-strategy.md §5.4, docs/layering-and-portability.md §5.

const std = @import("std");
const draw = @import("../draw.zig");
const props = @import("../props.zig");
const width = @import("../../width.zig"); // Unicode 셀 폭(EAW) — 한글/CJK=2칸.
// 손상 UTF-8 해석의 단일 출처 — 깨진 바이트 하나 = U+FFFD 한 칸. 도크 rich 경로(`chrome_draw_lowering`)와
// 오버레이 셀 경로(`metal_lowering.placeText`)가 같은 디코더를 써야 폭 셈과 그림이 갈리지 않는다.
const text_layout = @import("../text_layout.zig");
// 글자 묶음(grapheme cluster) 경계 — 자르기가 결합 부호·ZWJ 이모지·국기 쌍을 가르지 않게 한다.
const grapheme = @import("../../grapheme.zig");

/// **앞을 남기는 자르기의 끝**(바이트) — 표시 폭 `budget_cols` 칸과 `max_bytes` 바이트 안에 드는 가장 긴 앞부분이고,
/// 글자 묶음 경계로 **내린다**. 예전에는 코드포인트 경계에서 끊어 `e\u{301}` 의 결합 부호처럼 묶음의 뒷부분을 떼어
/// 냈다(적대적 검증 2026-10-06). 폭은 그대로 `displayCols` 셈법이다(§7.9.1 — 단위 통합은 별도).
/// `truncateToCols`·`elideMiddle`·`app_session.truncateColsInto` 가 함께 쓴다.
pub fn headEnd(bytes: []const u8, budget_cols: u32, max_bytes: usize) usize {
    var cols: u32 = 0;
    var end: usize = 0;
    while (end < bytes.len) {
        const d = text_layout.decodeCodepoint(bytes, end);
        const w = @max(1, width.cellWidth(d.cp));
        if (cols + w > budget_cols or end + d.advance > max_bytes) break;
        cols += w;
        end += d.advance;
    }
    return grapheme.snapToBoundary(bytes, end);
}

/// **끝을 남기는 자르기의 시작**을 글자 묶음 경계로 **올린다** — 꼬리가 결합 부호로 시작하면 그 부호가 「…」나 빈칸에
/// 홀로 붙어 보였다(가운데 줄임에서 폭 35 개 중 17 개, 적대적 검증). 덜 남기는 쪽이라 폭 상한은 그대로 지켜진다.
fn tailStart(bytes: []const u8, i: usize) usize {
    const floor = grapheme.snapToBoundary(bytes, i);
    var start = if (floor == i) i else grapheme.clusterEnd(bytes, floor);
    // **맨 앞의 확장 부호도 건너뛴다.** 묶음 규칙은 손상 바이트를 1 바이트 묶음으로 끊으므로 `"\xff\u{301}"` 의 U+0301 은
    // 경계에서 **새 묶음을 시작한다** — 경계로 올려도 그 부호가 「…」 뒤에 홀로 붙었다(적대적 검증 2026-10-07 재현).
    while (start < bytes.len) {
        const d = text_layout.decodeCodepoint(bytes, start);
        if (!grapheme.isExtendOrZwj(d.cp)) break;
        start += d.advance;
    }
    return start;
}

/// UTF-8 바이트열의 **표시 폭**(셀 칸 수) = Σ max(1, cellWidth(cp)). 한글/CJK는 2칸, 결합 문자는 1칸으로 친다
/// (placeText·coretext_frame_builder의 `@max(1, cellWidth)`와 같은 규약). 코드포인트 수가 아니다 — 한글을 1칸으로
/// 세면 caret/우측정렬이 글자 중간에 박혀 잘려 보인다(회귀의 루트커즈). caret 위치·바인딩 우측정렬에 쓴다.
pub fn displayCols(bytes: []const u8) u32 {
    // **손상 바이트는 하나당 한 칸이다**(U+FFFD — `text_layout.decodeCodepoint`). 예전에는 문자열 하나에 깨진
    // 바이트가 하나라도 있으면 **전체를 바이트 수로** 셌다 — 「한\xff」가 4칸이 되어, 그것을 「�」 섞어 그리는
    // 도크와 폭이 갈렸고, 오버레이는 그 run 을 아예 안 그렸다(`placeText`).
    var cols: u32 = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        const d = text_layout.decodeCodepoint(bytes, i);
        cols += @max(1, width.cellWidth(d.cp));
        i += d.advance;
    }
    return cols;
}

/// `bytes`를 표시 폭 `max_cols`칸 이내로 자른다(EAW 기준 — displayCols의 짝). 넘치면 끝에 `…`(1칸)를 붙여
/// 잘렸음을 보인다(글자 예산=max_cols-1). 안 넘치면 원본을 그대로 돌려준다(복사 없음). 자를 때만 arena alloc.
/// 코드포인트 경계로만 자르므로 UTF-8이 깨지지 않는다. 세팅 폼의 긴 값(폰트 패밀리 등)을 control 폭 안에 가두는 데 쓴다.
pub fn truncateToCols(arena: std.mem.Allocator, bytes: []const u8, max_cols: u32) ![]const u8 {
    if (displayCols(bytes) <= max_cols) return bytes;
    if (max_cols == 0) return "";
    // "…" 1칸 자리를 남긴다. 손상 UTF-8 도 같은 디코더로 자른다 — 예전에는 원본을 그대로 돌려줘 폭 상한을 넘겼다.
    const end = headEnd(bytes, max_cols - 1, bytes.len);
    return std.fmt.allocPrint(arena, "{s}…", .{bytes[0..end]});
}

/// `bytes` 가 표시 폭 `max_cols` 칸을 넘으면 **앞과 끝을 남기고 가운데를 `…` 로** 줄여 `buf` 에 쓴다(할당 없음).
/// 안 넘치면 원본을 그대로 돌려준다(복사 없음). URL·경로처럼 앞(호스트)과 끝(파일·질의)이 둘 다 뜻을 갖는 값을 문장
/// 안에 넣을 때 쓴다 — 문장 끝에서 자르면 그 뒤의 말(확인 대화상자의 질문)이 함께 사라진다. 앞에 예산의 2/3 를 준다.
/// 코드포인트 경계로만 자르고(정상 UTF-8 이 깨지지 않는다) 결과 표시 폭은 `max_cols` 이하다. 손상 바이트는 `displayCols`
/// 와 같이 하나당 한 칸으로 센다. `buf` 가 모자라면 끝을 잘라 `…` 로 마친다(`truncateToCols` 와 같은 모양).
pub fn elideMiddle(buf: []u8, bytes: []const u8, max_cols: u32) []const u8 {
    const total = displayCols(bytes);
    if (total <= max_cols) return bytes;
    const ellipsis = "…";
    const ellipsis_cols = displayCols(ellipsis);
    if (max_cols < ellipsis_cols or buf.len < ellipsis.len) return "";
    const budget = max_cols - ellipsis_cols;
    const head_cols = budget * 2 / 3;
    const tail_cols = budget - head_cols;
    // 손상 UTF-8 도 같은 디코더로 센다(깨진 바이트 하나 = 한 칸). 그래서 앞·끝을 자르는 경계가 정상 입력과
    // 같은 규칙이고, 결과 폭도 같은 셈법으로 상한 안이다(예전 손상 입력 특례 — ADV2 — 는 필요 없어졌다).
    //
    // 앞: head_cols 칸까지(글자 묶음 경계로 내린다 — `headEnd`).
    const head_end = headEnd(bytes, head_cols, bytes.len);
    // 끝: 남은 폭이 tail_cols 칸 이하가 되는 첫 글자부터.
    var tail_start: usize = bytes.len;
    var consumed: u32 = 0;
    var k: usize = 0;
    while (k < bytes.len) {
        if (total - consumed <= tail_cols) {
            tail_start = k;
            break;
        }
        const d = text_layout.decodeCodepoint(bytes, k);
        consumed += @max(1, width.cellWidth(d.cp));
        k += d.advance;
    }
    tail_start = tailStart(bytes, tail_start); // 글자 묶음을 가르지 않는다 — 꼬리는 올린다(결합 부호가 「…」 뒤에 홀로 남지 않게)
    if (tail_start < head_end) tail_start = head_end;
    const tail = bytes[tail_start..];
    if (head_end + ellipsis.len + tail.len > buf.len) return copyHeadWithEllipsis(buf, bytes, head_end);
    @memcpy(buf[0..head_end], bytes[0..head_end]);
    @memcpy(buf[head_end..][0..ellipsis.len], ellipsis);
    @memcpy(buf[head_end + ellipsis.len ..][0..tail.len], tail);
    return buf[0 .. head_end + ellipsis.len + tail.len];
}

fn copyHeadWithEllipsis(buf: []u8, bytes: []const u8, head_end: usize) []const u8 {
    const ellipsis = "…";
    const room = buf.len - ellipsis.len;
    var n = @min(head_end, room);
    while (n > 0 and n < bytes.len and (bytes[n] & 0xC0) == 0x80) n -= 1; // 코드포인트 경계로 되돌린다
    // 그리고 **글자 묶음 경계로 내린다** — 버퍼가 모자란 이 경로만 코드포인트에서 멈춰 `e\u{301}` 를 `e…` 로 갈랐다
    // (`headEnd` 와 같은 규칙, 적대적 검증 2026-10-07 재현).
    n = grapheme.snapToBoundary(bytes, n);
    @memcpy(buf[0..n], bytes[0..n]);
    @memcpy(buf[n..][0..ellipsis.len], ellipsis);
    return buf[0 .. n + ellipsis.len];
}

test "elideMiddle·tailWindow: 버퍼가 모자란 경로도 묶음을 가르지 않고, 손상 바이트 뒤 결합 부호를 「…」 뒤에 홀로 두지 않는다" {
    // 버퍼가 모자라면 앞만 남기고 「…」로 마치는 경로(`copyHeadWithEllipsis`)가 코드포인트에서 멈춰 결합 부호를 떼었다.
    var small: [4]u8 = undefined;
    const head_only = elideMiddle(&small, "e\u{301}" ** 30, 40);
    try std.testing.expect(!std.mem.startsWith(u8, head_only, "e…")); // `e` 만 남기고 부호를 떼지 않는다
    try std.testing.expect(std.mem.endsWith(u8, head_only, "…"));
    // 손상 바이트는 1 바이트 묶음이라 그 뒤의 결합 부호가 새 묶음을 시작한다 — 꼬리 맨 앞이면 건너뛴다.
    var buf: [512]u8 = undefined;
    const out = elideMiddle(&buf, "\xff\u{301}" ** 40, 10);
    const cut = std.mem.indexOf(u8, out, "…").?;
    try std.testing.expect(!std.mem.startsWith(u8, out[cut + "…".len ..], "\u{301}"));
    try std.testing.expect(displayCols(out) <= 10);
    const tail = tailWindow("\xff\u{301}" ** 40, 5);
    try std.testing.expect(tail.truncated and !std.mem.startsWith(u8, tail.text, "\u{301}"));
    try std.testing.expect(displayCols(tail.text) <= 5);
}

test "elideMiddle: 앞과 끝을 남기고 가운데를 줄이며, 폭과 UTF-8 을 지킨다" {
    var buf: [128]u8 = undefined;
    // 안 넘치면 원본 그대로(복사 없음).
    const short = "https://example.com/";
    try std.testing.expect(elideMiddle(&buf, short, 40).ptr == short.ptr);
    // 넘치면 앞(호스트)과 끝(파일)이 남고 가운데가 「…」.
    const url = "https://example.com/" ++ "a" ** 300 ++ "/report.pdf";
    const out = elideMiddle(&buf, url, 40);
    try std.testing.expect(displayCols(out) <= 40);
    try std.testing.expect(std.mem.startsWith(u8, out, "https://example.com/"));
    try std.testing.expect(std.mem.endsWith(u8, out, "report.pdf"));
    try std.testing.expect(std.mem.indexOf(u8, out, "…") != null);
    // 한글(2칸) — 코드포인트를 쪼개지 않고 폭 안이다.
    const hangul = "가" ** 80;
    const h = elideMiddle(&buf, hangul, 21);
    try std.testing.expect(std.unicode.utf8ValidateSlice(h));
    try std.testing.expect(displayCols(h) <= 21);
    // buf 가 모자라면 앞만 남기고 「…」로 마친다(여전히 유효 UTF-8).
    var tiny: [12]u8 = undefined;
    const t = elideMiddle(&tiny, hangul, 40);
    try std.testing.expect(std.unicode.utf8ValidateSlice(t));
    try std.testing.expect(std.mem.endsWith(u8, t, "…"));
}

test "truncateToCols: EAW 폭 기준 자르기 + 말줄임" {
    const a = std.testing.allocator;
    // 안 넘치면 원본 그대로(복사 없음 — free 금지).
    try std.testing.expectEqualStrings("abc", try truncateToCols(a, "abc", 5));
    try std.testing.expectEqualStrings("abc", try truncateToCols(a, "abc", 3));
    try std.testing.expectEqualStrings("", try truncateToCols(a, "abc", 0)); // max_cols=0 → ""(리터럴)
    // 넘치면 글자 예산(max_cols-1)까지 + "…", 결과 표시폭 ≤ max_cols.
    {
        const r = try truncateToCols(a, "abcdef", 4);
        defer a.free(r);
        try std.testing.expectEqualStrings("abc…", r);
        try std.testing.expect(displayCols(r) <= 4);
    }
    { // max_cols=1 → budget 0 → "…"만
        const r = try truncateToCols(a, "abc", 1);
        defer a.free(r);
        try std.testing.expectEqualStrings("…", r);
    }
    // 한글(2칸): "한국어"(6칸) max 5 → budget 4 → 한(2)국(2)=4, 어 초과 → "한국…"(5칸), 코드포인트 경계 유지.
    {
        const r = try truncateToCols(a, "한국어", 5);
        defer a.free(r);
        try std.testing.expectEqualStrings("한국…", r);
        try std.testing.expect(displayCols(r) <= 5);
        try std.testing.expect(std.unicode.utf8ValidateSlice(r)); // 글자 중간에서 안 잘림
    }
    { // 2칸 글자가 마지막 예산에 안 들어가면 과잘림(표시폭 < max_cols)이지만 절대 넘치지 않음
        const r = try truncateToCols(a, "한국어", 4); // budget 3 → 한(2), 국 초과 → "한…"(3칸)
        defer a.free(r);
        try std.testing.expectEqualStrings("한…", r);
        try std.testing.expect(displayCols(r) <= 4);
    }
}

/// `bytes`의 **뒤쪽**(caret 쪽)을 표시 폭 `max_cols` 안에 맞춘다 — truncateToCols(선두 고정)의 **말미 고정 짝**.
/// 넘치면 앞 코드포인트를 EAW 폭 기준으로 버려 남은 **뒤쪽** 표시폭이 max_cols 이하가 되게 하고 `.truncated=true`를
/// 돌려준다(호출자가 선두 "…" 1칸을 따로 그림 — 잘림 표시 자리를 미리 빼려면 max_cols-1을 넘긴다). 안 넘치면 원본
/// 슬라이스 + `.truncated=false`. **무 alloc**(원본의 뒤쪽 부분 슬라이스만) — caretRect(무 arena)도 그대로 쓴다.
/// 단일 줄 편집 입력(find·palette·사이드바 검색)이 caret(문자열 끝)를 따라 가로 스크롤하게 하는 tail 창의 단일 출처.
pub fn tailWindow(bytes: []const u8, max_cols: u32) struct { text: []const u8, truncated: bool } {
    if (displayCols(bytes) <= max_cols) return .{ .text = bytes, .truncated = false };
    // 앞에서부터 글자를 버려 남은 뒤쪽 표시폭이 max_cols 이하가 되는 첫 시작 바이트를 찾는다(displayCols와 같은 셈법 —
    // 손상 바이트도 같은 디코더로 하나당 한 칸이다. 예전에는 손상 입력을 안 잘라 폭 상한을 넘겼다).
    var remaining = displayCols(bytes);
    var start: usize = 0;
    while (remaining > max_cols and start < bytes.len) {
        const d = text_layout.decodeCodepoint(bytes, start);
        remaining -= @max(1, width.cellWidth(d.cp));
        start += d.advance; // 이 글자 끝(= 다음 시작) — 여기부터가 보이는 tail
    }
    // 글자 묶음을 가르지 않는다 — 보이는 꼬리가 결합 부호로 시작하지 않게 시작을 올린다(`tailStart`).
    return .{ .text = bytes[tailStart(bytes, start)..], .truncated = true };
}

test "tailWindow: 뒤쪽을 폭 안에 남기고(무 alloc) 앞이 잘리면 truncated" {
    // 안 넘치면 원본 그대로 + truncated=false.
    {
        const w = tailWindow("abc", 5);
        try std.testing.expectEqualStrings("abc", w.text);
        try std.testing.expect(!w.truncated);
    }
    // 넘치면 뒤쪽 max_cols칸만(앞을 버림) + truncated=true. "abcdef" max 3 → "def".
    {
        const w = tailWindow("abcdef", 3);
        try std.testing.expectEqualStrings("def", w.text);
        try std.testing.expect(w.truncated);
        try std.testing.expect(displayCols(w.text) <= 3);
    }
    // 한글(2칸): "한국어"(6칸) max 3 → 뒤에서 "어"(2칸)만(국 넣으면 4칸 초과), 코드포인트 경계 유지.
    {
        const w = tailWindow("한국어", 3);
        try std.testing.expectEqualStrings("어", w.text);
        try std.testing.expect(w.truncated);
        try std.testing.expect(std.unicode.utf8ValidateSlice(w.text)); // 반쪽 안 남김
    }
    // 한글 max 4 → "국어"(4칸) 딱.
    {
        const w = tailWindow("한국어", 4);
        try std.testing.expectEqualStrings("국어", w.text);
    }
}

/// 목록 오버레이(palette·settings·notifications)의 **보이는-윈도우 시작 인덱스** 단일 출처 — selected가 [start,
/// start+win) 안에 들게 하되 prev_start(이전 스크롤 위치)를 최대한 존중한다(휠 스크롤 보존). total ≤ win이면 0,
/// 결과는 [0, total-win]로 clamp. palette·settings는 prev_start=0(selected 기준 재파생), notifications는 scroll_offset을
/// 넘겨 위치를 유지한다(휠로 굴린 자리에서 selected만 보이게 최소 이동).
pub fn windowStart(total: usize, win: usize, selected: usize, prev_start: usize) usize {
    if (total <= win) return 0;
    const max_start = total - win;
    var s = @min(prev_start, max_start);
    if (selected < s) {
        s = selected; // selected가 창 위로 → 창 top을 selected에
    } else if (selected >= s + win) {
        s = selected - win + 1; // selected가 창 아래로 → 창 bottom을 selected에
    }
    return @min(s, max_start);
}

test "overlay_input windowStart: prev=0 재파생(palette·settings) + prev 유지(notifications)" {
    // prev_start=0 → selected 기준 재파생(기존 settings.windowStart 케이스와 동일).
    try std.testing.expectEqual(@as(usize, 0), windowStart(5, 10, 3, 0)); // 전체(5) ≤ 창(10) → 0
    try std.testing.expectEqual(@as(usize, 0), windowStart(20, 10, 2, 0)); // selected 2 < 창 → 0
    try std.testing.expectEqual(@as(usize, 3), windowStart(20, 10, 12, 0)); // selected 12 → 12-10+1=3
    try std.testing.expectEqual(@as(usize, 10), windowStart(20, 10, 19, 0)); // 끝 → 20-10=10(clamp)
    try std.testing.expectEqual(@as(usize, 10), windowStart(20, 10, 25, 0)); // 범위 밖이어도 clamp
    // prev_start 유지(notifications 휠 위치 보존).
    try std.testing.expectEqual(@as(usize, 4), windowStart(5, 1, 4, 0)); // 창1, selected4 → 끝맞춤 4
    try std.testing.expectEqual(@as(usize, 1), windowStart(5, 1, 1, 4)); // prev4, selected1 → 위로 1
    try std.testing.expectEqual(@as(usize, 2), windowStart(10, 3, 3, 2)); // prev2, selected3 창[2,5) 안 → 2 유지
    try std.testing.expectEqual(@as(usize, 1), windowStart(10, 3, 1, 2)); // prev2, selected1 창 위 → 1
}

/// 검색어(query) + IME 조합(preedit) 입력 모델. **커밋과 조합은 독립** — `appendChar`는 preedit를 건드리지 않고,
/// preedit는 `setPreedit`가 단일 관리한다(터미널 Surface overlay와 같은 commit/preedit 분리 모델). 이주 전 두 컴포넌트가 `appendChar`에서 preedit를
/// 비우다가 IME 멀티-문자 흐름(커밋 N + 조합 N+1)에서 다음 조합을 지워 "조합 안 보임" 버그를 냈다 — 그 모델을 여기
/// 단일 출처로 못 박는다. query·preedit는 ArrayList라 소유자(컴포넌트 State)가 deinit한다.
pub const OverlayInput = struct {
    query: std.ArrayList(u8) = .empty,
    preedit: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *OverlayInput, allocator: std.mem.Allocator) void {
        self.query.deinit(allocator);
        self.preedit.deinit(allocator);
    }

    /// 열기/리셋용 — 검색어·조합을 비운다(capacity 유지). 컴포넌트 show()가 고유 상태 리셋과 함께 부른다.
    pub fn clear(self: *OverlayInput) void {
        self.query.clearRetainingCapacity();
        self.preedit.clearRetainingCapacity();
    }

    /// 검색어에 확정 글자 추가(UTF-8 인코딩). **preedit는 안 건드린다**(위 모델). 인코딩 불가/OOM은 무시.
    pub fn appendChar(self: *OverlayInput, allocator: std.mem.Allocator, cp: u21) !void {
        var utf8: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &utf8) catch return;
        try self.query.appendSlice(allocator, utf8[0..n]);
    }

    /// IME 조합 중(marked) 텍스트를 교체한다(빈 bytes = 조합 해제). session.imeMarked가 해당 오버레이 열림일 때 부른다.
    pub fn setPreedit(self: *OverlayInput, allocator: std.mem.Allocator, bytes: []const u8) !void {
        self.preedit.clearRetainingCapacity();
        try self.preedit.appendSlice(allocator, bytes);
    }

    /// 조합 중(preedit) 텍스트를 검색어로 확정한다(query 뒤에 붙이고 preedit 비움) — 포커스 상실 등에서 조합을 잃지
    /// 않게. 확정한 게 있으면 true(호출자가 재검색/재필터). 빈 조합이면 false. OOM이면 조합을 버리고 false(반쪽 안 남김).
    pub fn commitPreedit(self: *OverlayInput, allocator: std.mem.Allocator) bool {
        if (self.preedit.items.len == 0) return false;
        self.query.appendSlice(allocator, self.preedit.items) catch {
            self.preedit.clearRetainingCapacity();
            return false;
        };
        self.preedit.clearRetainingCapacity();
        return true;
    }

    /// 마지막 코드포인트 1개 삭제(UTF-8 경계 존중). 빈 쿼리면 무동작. width.dropLastCodepoint 단일 출처.
    pub fn backspace(self: *OverlayInput) void {
        self.query.shrinkRetainingCapacity(width.dropLastCodepoint(self.query.items, self.query.items.len));
    }

    /// 검색어의 표시 폭(EAW). caret 열 = prompt_cols + 이 값(조합중 preedit는 안 더한다 — 커서가 조합 글자를 덮음).
    pub fn queryCols(self: *const OverlayInput) u32 {
        return displayCols(self.query.items);
    }
};

/// find·palette 입력줄의 표시 배치(단일 출처) — `view`의 텍스트 run 배치와 `caretRect`가 **공유**해 caret가 그려진
/// 글자와 어긋나지 않는다. `text_cols`=프롬프트+입력+caret이 들어갈 수 있는 총 칸(패널 폭에서 카운터 등 우측 예약을
/// 뺀 값, 호출자가 계산). content(query+preedit)가 그 안에 다 들어가면 넘침 아님(기존 좌측 정렬 배치 그대로 — caret=
/// prompt_cols+queryCols). 넘치면 **tail 창**(선두 "…")으로 오른쪽 정렬해 caret(= query 끝)을 시야에 유지한다: 긴 검색어를
/// 칠 때 caret과 방금 친 글자가 오른쪽으로 잘려 안 보이던 문제를 없앤다. 넘침이면 preedit(활성 조합)은 통째 보존하고
/// query만 tail로 줄인다(극단적으로 preedit이 예산을 넘으면 preedit도 tail). 반환 슬라이스는 원본 부분 슬라이스라 무 alloc
/// — caretRect(무 arena)도 그대로 쓴다. 프롬프트 폭이 달라도(find "Find: "=6, palette "> "=2) 이 한 함수를 공유한다.
pub const InputLineView = struct {
    truncated: bool, // 선두 "…"(1칸)를 그릴지 — 앞이 잘렸음(호출자가 프롬프트 뒤에 "…" run을 넣는다)
    query: []const u8, // 표시할 query(넘침이면 뒤쪽 슬라이스, 아니면 원본)
    preedit: []const u8, // 표시할 preedit(보통 원본, 극단 넘침일 때만 tail)
    caret_col: u32, // 패널(프롬프트 원점) 기준 caret 절대 col — query 끝(조합 글자는 그 위에 겹침)
};

pub fn inputLineView(in: *const OverlayInput, prompt_cols: u32, text_cols: u32) InputLineView {
    const q_cols = displayCols(in.query.items);
    const p_cols = displayCols(in.preedit.items);
    // 프롬프트+content+caret(1칸)이 다 들어가면 넘침 아님 — 기존 배치 그대로(caret = 프롬프트 + query 폭).
    const avail_content = text_cols -| prompt_cols -| 1; // 우측 caret 1칸 예약
    if (q_cols + p_cols <= avail_content) {
        return .{ .truncated = false, .query = in.query.items, .preedit = in.preedit.items, .caret_col = prompt_cols + q_cols };
    }
    // 넘침: 선두 "…"(1칸) 뒤에 뒤쪽만. preedit(활성 조합)을 우선 보존하고 남은 예산으로 query tail을 남긴다.
    const budget = avail_content -| 1; // "…" 1칸
    if (p_cols >= budget) {
        // 조합 텍스트가 예산을 다 먹는 극단(패널보다 긴 조합) — query는 숨기고 preedit tail만, caret은 그 끝.
        const pw = tailWindow(in.preedit.items, budget);
        return .{ .truncated = true, .query = "", .preedit = pw.text, .caret_col = prompt_cols + 1 + displayCols(pw.text) };
    }
    const qw = tailWindow(in.query.items, budget - p_cols);
    // caret = "…"(1) 뒤 query tail 끝 = query 끝(조합 글자는 그 위/뒤에 겹쳐 그려진다 — 기존 규약 보존).
    return .{ .truncated = true, .query = qw.text, .preedit = in.preedit.items, .caret_col = prompt_cols + 1 + displayCols(qw.text) };
}

test "inputLineView: 비넘침은 기존 배치 유지, 넘치면 tail 창 + caret 시야 유지" {
    const a = std.testing.allocator;
    var in: OverlayInput = .{};
    defer in.deinit(a);

    // 비넘침: 짧은 query → 잘림 없음, caret = prompt_cols + queryCols(기존과 동일).
    try in.appendChar(a, 'a');
    try in.appendChar(a, 'b');
    {
        const v = inputLineView(&in, 6, 40); // prompt 6, 넉넉한 40칸
        try std.testing.expect(!v.truncated);
        try std.testing.expectEqualStrings("ab", v.query);
        try std.testing.expectEqual(@as(u32, 8), v.caret_col); // 6 + 2
    }

    // 넘침: 좁은 text_cols → tail 창. caret_col은 text_cols 안(패널 밖으로 안 나감).
    in.clear();
    for ("abcdefghij") |c| try in.appendChar(a, c); // 10칸
    {
        const v = inputLineView(&in, 6, 12); // prompt 6, text 12 → avail_content=12-6-1=5, budget=4
        try std.testing.expect(v.truncated);
        try std.testing.expect(displayCols(v.query) <= 4); // query tail은 예산(4) 이하
        try std.testing.expectEqualStrings("ghij", v.query); // 뒤 4글자
        try std.testing.expect(v.caret_col < 12); // caret은 text 영역 안 → 그려짐(숨지 않음)
        try std.testing.expectEqual(@as(u32, 11), v.caret_col); // 6 + 1(…) + 4(tail)
    }
}

/// find·palette 프롬프트 입력줄 text op의 run 배열(arena 소유)을 만드는 **공유 헬퍼** — `inputLineView` 결과로
/// `[프롬프트, (…?), query, preedit]`를 만든다(넘침이면 프롬프트 뒤 "…"). 두 컴포넌트의 view가 이 한 곳을 써서
/// run 구성(예: preedit에 별도 role 부여)이 한쪽만 바뀌는 드리프트를 막는다. `prompt`는 각 컴포넌트 접두("Find: "/"> ").
pub fn promptRuns(arena: std.mem.Allocator, prompt: []const u8, line: InputLineView) ![]draw.Run {
    var buf: [4]draw.Run = undefined;
    var n: usize = 0;
    buf[n] = .{ .text = prompt };
    n += 1;
    if (line.truncated) { // 앞이 잘렸음 — 프롬프트 뒤 "…"
        buf[n] = .{ .text = "…" };
        n += 1;
    }
    buf[n] = .{ .text = line.query };
    n += 1;
    buf[n] = .{ .text = line.preedit };
    n += 1;
    return arena.dupe(draw.Run, buf[0..n]);
}

pub const PanelLayout = struct { x: i32, y: i32, panel_cols: u32, cw: u32, ch: u32 };

/// 패널 **폭 산출 공유 코어** — panelLayout(palette 창-중앙)·findLayout(find pane 우상단)이 정렬만 달리하고 이걸
/// 함께 쓴다. 이 모듈의 존재 이유가 패널 레이아웃 복붙 제거(위 모듈 doc)이므로, 폭 규약(60·−4·2*pad)을 여기 한
/// 곳에만 둔다. region_w(가용 가로 px)/cw==0이면 null(영역 0칸 — 호출자 무동작). C4b 패딩: 폭 상한을 2*pad만큼
/// 줄인 가용 칸으로 panel_cols를 산출 — platform lowering이 배경 quad를 ±pad 확장한 뒤에도 박스가 영역에 들도록
/// 텍스트 폭을 양보한다(pad=0(tui)이면 무변화). 단 avail_cols==0(region_w < 2*pad, 1~3칸의 비정상적으로 좁은
/// 영역)이면 soft-lock 방지로 panel_cols=1을 강제하므로 ±pad 확장이 최대 pad만큼 경계를 침범할 수 있다 — bounded
/// 이고 '안 보이는 열린 모달'보다 작은 박스가 낫다는 절충(panelLayout·findLayout 양쪽 동일).
const PanelSize = struct { panel_cols: u32, panel_w: u32, cw: u32, ch: u32 };
fn panelSize(p: props.ChromeProps, region_w: u32) ?PanelSize {
    const m = p.metrics;
    const cw = @max(m.cell_width_px, 1);
    const ch = @max(m.cell_height_px, 1);
    if (region_w / cw == 0) return null;
    const pad: u32 = p.shape.modal_padding_px;
    const avail_cols = (region_w -| 2 * pad) / cw;
    const panel_cols: u32 = @max(@min(@as(u32, 60), avail_cols -| 4), 1);
    return .{ .panel_cols = panel_cols, .panel_w = panel_cols * cw, .cw = cw, .ch = ch };
}

/// 오버레이를 붙일 **활성 pane 영역**(backing px) 단일 출처. active_pane.w>0이면 그 rect, 미초기화(w==0)면
/// 사이드바 오른쪽 터미널 영역 전체로 폴백(단일-pane·헤드리스 안전). findLayout(find 한 줄)과 paneTopRightBox
/// (멀티행 힌트)가 같은 앵커를 쓰게 해 복붙을 막는다([keybind-hints.md] §3.1). h는 멀티행 박스가 pane 높이로
/// 행 수를 clamp하는 데 쓴다(find는 한 줄이라 h 무시).
pub const Region = struct { x: u32, y: u32, w: u32, h: u32 };
pub fn paneRegion(p: props.ChromeProps) Region {
    const m = p.metrics;
    return if (p.active_pane.w > 0)
        .{ .x = p.active_pane.x, .y = p.active_pane.y, .w = p.active_pane.w, .h = p.active_pane.h }
    else blk: {
        const workspace = props.workspaceRect(m);
        break :blk .{ .x = workspace.x, .y = workspace.y, .w = workspace.w, .h = workspace.h };
    };
}

/// palette 패널 가로 레이아웃(전체 작업영역, 상단-중앙) — **palette 전용**(find는 활성 pane 우상단 findLayout으로
/// 분리). 폭은 panelSize 공유. clamp로 panel_w ≤ term_w_px라 중앙배치 뺄셈이 안전. y는 상단에서 두 줄 아래.
pub fn panelLayout(p: props.ChromeProps) ?PanelLayout {
    const m = p.metrics;
    const workspace = props.workspaceRect(m);
    if (workspace.w == 0 or workspace.h == 0) return null;
    const term_w_px = workspace.w;
    const sz = panelSize(p, term_w_px) orelse return null;
    const x = @as(i32, @intCast(workspace.x)) + @as(i32, @intCast((term_w_px - sz.panel_w) / 2));
    const y = @as(i32, @intCast(workspace.y)) + 2 * @as(i32, @intCast(sz.ch)); // workspace 상단에서 두 줄 내려
    return .{ .x = x, .y = y, .panel_cols = sz.panel_cols, .cw = sz.cw, .ch = sz.ch };
}

/// find 오버레이 레이아웃 — **활성 pane 우상단**(브라우저/iTerm/VS Code 관례). palette의 창-중앙 panelLayout과
/// 분리: 검색·하이라이트가 활성 surface만 보므로(app_session.activeSurface) 바도 그 pane에 붙여 어느 분할을 검색
/// 중인지 시각적으로 맞춘다. 경계 = `p.active_pane`(platform active_pane_rect 미러); 미초기화(w==0)면 사이드바
/// 오른쪽 터미널 영역 전체로 폴백해 단일-pane·헤드리스 테스트에서도 안전. 폭은 panelSize 공유. 우측 정렬이라
/// 오른쪽 여백을 pad로 둬 **정상 폭에선** 우측 pane/divider를 안 침범한다 — 단 panelSize가 panel_cols=1을 강제하는
/// 비정상적으로 좁은 pane(panel_w+pad > 영역 폭)이면 우측 여백이 0으로 saturate돼 ±pad 확장이 최대 pad만큼 경계를
/// 넘을 수 있다(bounded, panelLayout과 동일 절충). y는 pane 상단 한 줄 아래 — 패널 높이는 한 칸이라 region.h는
/// 안 본다(2칸보다 낮은 극단적 pane이면 아래로 한 칸 넘칠 수 있으나 bounded).
pub fn findLayout(p: props.ChromeProps) ?PanelLayout {
    // 활성 pane 경계(paneRegion 단일 출처 — paneTopRightBox와 공유). 미초기화면 터미널 영역 전체 폴백.
    const region = paneRegion(p);
    const sz = panelSize(p, region.w) orelse return null; // 영역 0칸 — 무동작
    const pad: u32 = p.shape.modal_padding_px;
    // 우상단: 우측 정렬(오른쪽 여백 = pad라 정상 폭이면 lowering ±pad 확장 후에도 pane 안), 상단에서 한 줄 내려.
    const x = @as(i32, @intCast(region.x)) + @as(i32, @intCast(region.w -| sz.panel_w -| pad));
    const y = @as(i32, @intCast(region.y)) + @as(i32, @intCast(sz.ch));
    return .{ .x = x, .y = y, .panel_cols = sz.panel_cols, .cw = sz.cw, .ch = sz.ch };
}

/// 멀티행 오버레이(단축키 힌트)를 **활성 pane 우상단**에 붙이는 박스 — findLayout(한 줄)의 멀티행 일반화.
/// 같은 paneRegion 앵커·우측 정렬을 쓰되, 폭은 고정 panelSize가 아니라 `content_cols`(콘텐츠 폭, 가용 칸으로
/// clamp)이고 높이는 `content_rows`(영역 높이−상단 한 줄로 clamp — 짧은 pane에서 넘침 방지, 초과분은
/// framebuffer 클립). 영역 0칸/패딩이 영역보다 큼이면 null(무동작). 우측 여백 pad라 rich lowering ±pad 확장
/// 후에도 pane 안(findLayout과 동일 절충). y는 pane 상단 한 줄 아래(탭 바·divider와 안 겹치게).
pub const Box = struct { x: i32, y: i32, cols: u32, rows: u32, cw: u32, ch: u32 };
pub fn paneTopRightBox(p: props.ChromeProps, content_cols: u32, content_rows: u32) ?Box {
    const m = p.metrics;
    const cw = @max(m.cell_width_px, 1);
    const ch = @max(m.cell_height_px, 1);
    const region = paneRegion(p);
    if (region.w / cw == 0) return null; // 영역 0칸
    const pad: u32 = p.shape.modal_padding_px;
    const avail_cols = (region.w -| 2 * pad) / cw;
    if (avail_cols == 0) return null; // 영역이 패딩보다 좁음(비정상)
    const box_cols = @max(@min(content_cols, avail_cols), 1);
    const box_w = box_cols * cw;
    // 높이 clamp: 상단 한 줄 내려 배치하므로 가용 행 = 영역 행 − 1. 0이면 1 강제(soft-lock 방지, bounded 넘침).
    const avail_rows = @max((region.h / ch) -| 1, 1);
    const box_rows = @max(@min(content_rows, avail_rows), 1);
    const x = @as(i32, @intCast(region.x)) + @as(i32, @intCast(region.w -| box_w -| pad));
    const y = @as(i32, @intCast(region.y)) + @as(i32, @intCast(ch));
    return .{ .x = x, .y = y, .cols = box_cols, .rows = box_rows, .cw = cw, .ch = ch };
}

// ── 테스트 ──────────────────────────────────────────────────────────────────────

test "OverlayInput: appendChar(UTF-8)·backspace(코드포인트 경계)·preedit는 독립" {
    const allocator = std.testing.allocator;
    var in: OverlayInput = .{};
    defer in.deinit(allocator);

    try in.appendChar(allocator, 'a');
    try in.appendChar(allocator, 'b');
    try in.appendChar(allocator, '한'); // 3바이트
    try std.testing.expectEqual(@as(usize, 5), in.query.items.len);
    in.backspace(); // '한' 한 코드포인트(3바이트) 제거
    try std.testing.expectEqualStrings("ab", in.query.items);

    // appendChar는 조합(preedit)을 안 건드린다(커밋·조합 독립 — IME 멀티-문자 회귀 고정).
    try in.setPreedit(allocator, "\xea\xb0\x80"); // 조합 "가"
    try in.appendChar(allocator, 'c');
    try std.testing.expectEqualStrings("abc", in.query.items);
    try std.testing.expectEqualStrings("\xea\xb0\x80", in.preedit.items); // 조합 유지

    in.backspace();
    in.backspace();
    in.backspace();
    in.backspace(); // 빈 쿼리에서 추가 backspace 무동작
    try std.testing.expectEqual(@as(usize, 0), in.query.items.len);
    in.clear();
    try std.testing.expectEqual(@as(usize, 0), in.preedit.items.len);
}

test "OverlayInput: commitPreedit는 조합을 query로 확정·빈 조합이면 false" {
    const allocator = std.testing.allocator;
    var in: OverlayInput = .{};
    defer in.deinit(allocator);
    try in.appendChar(allocator, 'a');
    try in.setPreedit(allocator, "\xea\xb0\x80"); // 조합 "가"
    try std.testing.expect(in.commitPreedit(allocator)); // 확정 → "a가", preedit 비움
    try std.testing.expectEqualStrings("a\xea\xb0\x80", in.query.items);
    try std.testing.expectEqual(@as(usize, 0), in.preedit.items.len);
    try std.testing.expect(!in.commitPreedit(allocator)); // 빈 조합이면 무동작 false
}

test "OverlayInput: displayCols/queryCols는 EAW(한글=2칸)" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqual(@as(u32, 8), displayCols("\xea\xb0\x80\xeb\x82\x98\xeb\x8b\xa4\xeb\x9d\xbc")); // "가나다라" = 4×2
    try std.testing.expectEqual(@as(u32, 4), displayCols("abcd"));
    var in: OverlayInput = .{};
    defer in.deinit(allocator);
    for ([_]u21{ '가', '나' }) |c| try in.appendChar(allocator, c);
    try std.testing.expectEqual(@as(u32, 4), in.queryCols()); // 한글 2글자 = 4칸
}

test "panelLayout: term_cols 0이면 null, 아니면 사이드바 오른쪽 상단-중앙" {
    try std.testing.expectEqual(@as(?PanelLayout, null), panelLayout(.{
        .metrics = .{
            .cell_width_px = 8,
            .cell_height_px = 16,
            .sidebar_width_px = 800, // 사이드바가 backing 전부 — 터미널 0칸
            .backing_width_px = 800,
            .backing_height_px = 600,
        },
    }));
    const lay = panelLayout(.{ .metrics = .{
        .cell_width_px = 8,
        .cell_height_px = 16,
        .sidebar_width_px = 40,
        .backing_width_px = 800,
        .backing_height_px = 600,
    } }) orelse return error.NoLayout;
    try std.testing.expect(lay.x >= 40); // 사이드바 오른쪽
    try std.testing.expectEqual(@as(i32, 32), lay.y); // 2 줄(2×16)
    try std.testing.expectEqual(@as(u32, 8), lay.cw);
    try std.testing.expectEqual(@as(u32, 16), lay.ch);
    try std.testing.expect(lay.panel_cols >= 1 and lay.panel_cols <= 60);
}

test "panelLayout: authoritative zero-height workspace fails closed" {
    try std.testing.expectEqual(@as(?PanelLayout, null), panelLayout(.{ .metrics = .{
        .cell_width_px = 8,
        .cell_height_px = 16,
        .sidebar_width_px = 200,
        .backing_width_px = 1200,
        .backing_height_px = 800,
        .workspace_x_px = 200,
        .workspace_y_px = 800,
        .workspace_width_px = 1000,
        .workspace_height_px = 0,
        .workspace_present = true,
    } }));
}

test "panelLayout: rich 패딩이면 확장 박스(panel_w + 2*pad)가 터미널 영역 안 — 사이드바 침범·화면밖 방지" {
    const pad: u32 = 12;
    const sidebar: u32 = 40;
    const backing: u32 = 200; // 좁은 창 — clamp가 걸리는 경계
    const lay = panelLayout(.{
        .metrics = .{ .cell_width_px = 8, .cell_height_px = 16, .sidebar_width_px = sidebar, .backing_width_px = backing, .backing_height_px = 600 },
        .shape = .{ .modal_padding_px = @intCast(pad) },
    }) orelse return error.NoLayout;
    const term_w_px = backing - sidebar;
    const panel_w = lay.panel_cols * lay.cw;
    // lowering이 ±pad 확장해도 박스가 [sidebar, sidebar+term_w_px] 안: 좌단 quad.x>=sidebar, 우단<=sidebar+term_w_px.
    try std.testing.expect(panel_w + 2 * pad <= term_w_px);
    try std.testing.expect(lay.x - @as(i32, @intCast(pad)) >= @as(i32, @intCast(sidebar)));
    try std.testing.expect(lay.x + @as(i32, @intCast(panel_w + pad)) <= @as(i32, @intCast(sidebar + term_w_px)));
}

test "findLayout: 활성 pane 우상단 우측 정렬·미초기화면 창 전체로 폴백" {
    // 활성 pane = 창 오른쪽 절반(x=400..800, top=32 — 탭 바 아래). 바는 그 pane 우상단에 붙는다.
    const lay = findLayout(.{
        .metrics = .{ .cell_width_px = 8, .cell_height_px = 16, .sidebar_width_px = 40, .backing_width_px = 800, .backing_height_px = 600 },
        .active_pane = .{ .x = 400, .y = 32, .w = 400, .h = 568 },
    }) orelse return error.NoLayout;
    const panel_w = lay.panel_cols * lay.cw;
    try std.testing.expectEqual(@as(i32, 800), lay.x + @as(i32, @intCast(panel_w))); // 우단이 pane 우단(800)에 닿음(pad=0)
    try std.testing.expect(lay.x >= 400); // pane 안 — 왼쪽 pane 안 침범
    try std.testing.expectEqual(@as(i32, 48), lay.y); // pane top(32) + 한 줄(16)

    // 미초기화(active_pane.w==0) → 사이드바 오른쪽 터미널 영역 전체로 폴백, 그 영역 우상단.
    const fb = findLayout(.{ .metrics = .{ .cell_width_px = 8, .cell_height_px = 16, .sidebar_width_px = 40, .backing_width_px = 800, .backing_height_px = 600 } }) orelse return error.NoLayout;
    const fb_w = fb.panel_cols * fb.cw;
    try std.testing.expectEqual(@as(i32, 800), fb.x + @as(i32, @intCast(fb_w))); // 우단이 창 우단
    try std.testing.expect(fb.x >= 40); // 사이드바 오른쪽
    try std.testing.expectEqual(@as(i32, 16), fb.y); // 폴백 영역 top(0) + 한 줄
}

test "findLayout: rich 패딩이면 우측 확장 박스가 pane 안 — 우측 pane/divider 침범 방지" {
    const pad: u32 = 12;
    const lay = findLayout(.{
        .metrics = .{ .cell_width_px = 8, .cell_height_px = 16, .sidebar_width_px = 40, .backing_width_px = 800, .backing_height_px = 600 },
        .active_pane = .{ .x = 400, .y = 0, .w = 200, .h = 600 }, // 좁은 가운데 pane(우측에 divider/다른 pane)
        .shape = .{ .modal_padding_px = @intCast(pad) },
    }) orelse return error.NoLayout;
    const panel_w = lay.panel_cols * lay.cw;
    // lowering이 ±pad 확장해도 박스가 [pane.x, pane.x+pane.w](=[400,600]) 안.
    try std.testing.expect(lay.x + @as(i32, @intCast(panel_w + pad)) <= 600);
    try std.testing.expect(lay.x - @as(i32, @intCast(pad)) >= 400);
}

test "paneTopRightBox: 활성 pane 우상단 멀티행 — 우측 정렬·콘텐츠 폭·높이 clamp" {
    // 활성 pane = 창 오른쪽 절반(x=400..800, top=32). 10칸×4행 콘텐츠 박스가 그 pane 우상단에 붙는다.
    const box = paneTopRightBox(.{
        .metrics = .{ .cell_width_px = 8, .cell_height_px = 16, .sidebar_width_px = 40, .backing_width_px = 800, .backing_height_px = 600 },
        .active_pane = .{ .x = 400, .y = 32, .w = 400, .h = 568 },
    }, 10, 4) orelse return error.NoBox;
    try std.testing.expectEqual(@as(u32, 10), box.cols); // 콘텐츠 폭(가용 50칸 안)
    try std.testing.expectEqual(@as(u32, 4), box.rows); // 콘텐츠 행(가용 35행 안)
    try std.testing.expectEqual(@as(i32, 720), box.x); // 400 + (400 − 80) = 720(우측 정렬)
    try std.testing.expectEqual(@as(i32, 800), box.x + @as(i32, @intCast(box.cols * box.cw))); // 우단 = pane 우단
    try std.testing.expectEqual(@as(i32, 48), box.y); // pane top(32) + 한 줄(16)
    try std.testing.expect(box.x >= 400); // 왼쪽 pane 안 침범

    // 미초기화(active_pane.w==0) → 터미널 영역 전체 우상단 폴백.
    const fb = paneTopRightBox(.{ .metrics = .{ .cell_width_px = 8, .cell_height_px = 16, .sidebar_width_px = 40, .backing_width_px = 800, .backing_height_px = 600 } }, 10, 3) orelse return error.NoBox;
    try std.testing.expectEqual(@as(i32, 800), fb.x + @as(i32, @intCast(fb.cols * fb.cw))); // 우단 = 창 우단
    try std.testing.expect(fb.x >= 40); // 사이드바 오른쪽
}

test "paneTopRightBox: 콘텐츠가 영역보다 크면 폭·높이를 clamp (짧은 pane 넘침 방지)" {
    // 작은 pane(폭 80px=10칸, 높이 48px=3행)에 큰 콘텐츠(20칸×10행) → 박스가 영역으로 clamp된다.
    const box = paneTopRightBox(.{
        .metrics = .{ .cell_width_px = 8, .cell_height_px = 16, .sidebar_width_px = 0, .backing_width_px = 800, .backing_height_px = 600 },
        .active_pane = .{ .x = 100, .y = 0, .w = 80, .h = 48 },
    }, 20, 10) orelse return error.NoBox;
    try std.testing.expectEqual(@as(u32, 10), box.cols); // 폭 80/8=10으로 clamp
    try std.testing.expectEqual(@as(u32, 2), box.rows); // 높이 3행 − 상단 1행 = 2로 clamp
    try std.testing.expectEqual(@as(i32, 180), box.x + @as(i32, @intCast(box.cols * box.cw))); // 우단 = pane 우단(180)

    // 영역이 0칸(폭<셀)이면 null.
    try std.testing.expect(paneTopRightBox(.{ .metrics = .{ .cell_width_px = 8, .cell_height_px = 16, .sidebar_width_px = 0, .backing_width_px = 4, .backing_height_px = 600 } }, 10, 3) == null);
}

test "elideMiddle: 손상 UTF-8 이어도 결과 폭이 상한을 넘지 않는다 (적대적 ADV2)" {
    // 예전에는 손상 바이트열이면 원문 **전체** 뒤에 「…」를 붙여 폭이 하나도 안 줄었다(퍼징 18,663 건 중 16,095 건).
    var buf: [64]u8 = undefined;
    const bad = "abc\xffdefghijklmnopqrstuvwxyz0123456789";
    const out = elideMiddle(buf[0 .. bad.len + 3], bad, 10);
    try std.testing.expect(displayCols(out) <= 10);
    try std.testing.expect(std.mem.startsWith(u8, out, "abc"));
    // 상한이 「…」 바이트 수보다 작아도 넘지 않는다.
    try std.testing.expect(displayCols(elideMiddle(buf[0 .. bad.len + 3], bad, 2)) <= 2);

    // 성질: 섞인 입력 전부에서 폭 상한, 정상 입력이면 UTF-8 유지.
    var prng = std.Random.DefaultPrng.init(42);
    const r = prng.random();
    const pieces = [_][]const u8{ "a", "한", "🙂", "e\u{301}", "\u{FE0F}", "…", "\xff", "\xc3", "\xe2\x80", "ｗ", "\u{200D}", " " };
    var invalid_seen: usize = 0;
    for (0..3000) |_| {
        var src: [400]u8 = undefined;
        var n: usize = 0;
        for (0..r.intRangeAtMost(usize, 0, 60)) |_| {
            const pc = pieces[r.intRangeLessThan(usize, 0, pieces.len)];
            if (n + pc.len > src.len) break;
            @memcpy(src[n..][0..pc.len], pc);
            n += pc.len;
        }
        const bytes = src[0..n];
        const max: u32 = r.intRangeAtMost(u32, 0, 40);
        var obuf: [403]u8 = undefined;
        const o = elideMiddle(obuf[0 .. n + 3], bytes, max);
        try std.testing.expect(displayCols(o) <= max or displayCols(bytes) <= max);
        if (std.unicode.utf8ValidateSlice(bytes)) try std.testing.expect(std.unicode.utf8ValidateSlice(o)) else invalid_seen += 1;
    }
    try std.testing.expect(invalid_seen > 1000); // 손상 경로를 실제로 탔다
}

test "손상 바이트는 하나당 한 칸이고, 자르기 셋이 같은 셈법으로 폭 상한을 지킨다" {
    // 예전에는 깨진 바이트가 하나라도 있으면 **전체를 바이트 수로** 셌고(「한\xff」= 4칸), 자르기 셋은 손상 입력을
    // **안 잘랐다** — 오버레이 셀 경로는 그 run 을 아예 안 그렸다. 지금은 도크와 같은 디코더(U+FFFD 한 칸)다.
    try std.testing.expectEqual(@as(u32, 3), displayCols("한\xff"));
    try std.testing.expectEqual(@as(u32, 5), displayCols("ab\xffcd"));
    try std.testing.expectEqual(@as(u32, 2), displayCols("\xe2\x80")); // 끊긴 시퀀스 = 바이트마다 한 칸

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var prng = std.Random.DefaultPrng.init(7);
    const r = prng.random();
    const pieces = [_][]const u8{ "a", "한", "🙂", "e\u{301}", "…", "\xff", "\xc3", "\xe2\x80", "\x80", "ｗ", " " };
    var invalid_seen: usize = 0;
    var cut: usize = 0;
    for (0..3000) |_| {
        _ = arena_state.reset(.retain_capacity);
        var src: [300]u8 = undefined;
        var n: usize = 0;
        for (0..r.intRangeAtMost(usize, 0, 50)) |_| {
            const pc = pieces[r.intRangeLessThan(usize, 0, pieces.len)];
            if (n + pc.len > src.len) break;
            @memcpy(src[n..][0..pc.len], pc);
            n += pc.len;
        }
        const bytes = src[0..n];
        const max: u32 = r.intRangeAtMost(u32, 1, 40);
        const valid = std.unicode.utf8ValidateSlice(bytes);
        if (!valid) invalid_seen += 1;
        if (displayCols(bytes) > max) cut += 1;

        const head = try truncateToCols(arena_state.allocator(), bytes, max);
        try std.testing.expect(displayCols(head) <= max);
        const tail = tailWindow(bytes, max).text;
        try std.testing.expect(displayCols(tail) <= max);
        var buf: [303]u8 = undefined;
        const mid = elideMiddle(buf[0 .. n + 3], bytes, max);
        try std.testing.expect(displayCols(mid) <= max);
        if (valid) {
            try std.testing.expect(std.unicode.utf8ValidateSlice(head));
            try std.testing.expect(std.unicode.utf8ValidateSlice(tail));
            try std.testing.expect(std.unicode.utf8ValidateSlice(mid));
        }
    }
    // 두 경로를 실제로 탔는지 센다 — 0 이면 이 판정자는 아무것도 지키지 않는다.
    try std.testing.expect(invalid_seen > 1000 and cut > 1000);
}

test "자르기 셋은 글자 묶음을 가르지 않는다 — 결합 부호·ZWJ 이모지·국기·분해형 한글, 폭 상한도 그대로" {
    // 예전에는 코드포인트 경계에서 끊어, 가운데 줄임의 꼬리가 결합 부호로 시작했다(`e\u{301}` × 30 에서 폭 35 개 중 17 개).
    var buf: [256]u8 = undefined;
    const accents = "e\u{301}" ** 30;
    var m: u32 = 5;
    while (m < 40) : (m += 1) {
        const out = elideMiddle(&buf, accents, m);
        const at = std.mem.indexOf(u8, out, "…") orelse continue;
        try std.testing.expect(!std.mem.startsWith(u8, out[at + "…".len ..], "\u{301}"));
    }

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var prng = std.Random.DefaultPrng.init(21);
    const r = prng.random();
    const pieces = [_][]const u8{ "a", "e\u{301}", "한", "\u{1112}\u{1161}\u{11AB}", "👨\u{200D}👩\u{200D}👧", "🇰🇷", "☺\u{FE0F}", " ", "\xff", "ｗ" };
    var cut: usize = 0;
    for (0..3000) |_| {
        _ = arena_state.reset(.retain_capacity);
        var src: [400]u8 = undefined;
        var n: usize = 0;
        for (0..r.intRangeAtMost(usize, 0, 40)) |_| {
            const pc = pieces[r.intRangeLessThan(usize, 0, pieces.len)];
            if (n + pc.len > src.len) break;
            @memcpy(src[n..][0..pc.len], pc);
            n += pc.len;
        }
        const bytes = src[0..n];
        const max: u32 = r.intRangeAtMost(u32, 2, 40);
        if (displayCols(bytes) > max) cut += 1;
        // 앞을 남기는 쪽 — 끝이 묶음 경계다.
        const head = try truncateToCols(arena_state.allocator(), bytes, max);
        try std.testing.expect(displayCols(head) <= max);
        if (head.ptr != bytes.ptr) {
            const e = head.len - "…".len;
            try std.testing.expectEqual(e, grapheme.snapToBoundary(bytes, e));
        }
        // 끝을 남기는 쪽 — 시작이 묶음 경계다.
        const tail = tailWindow(bytes, max).text;
        try std.testing.expect(displayCols(tail) <= max);
        const t0 = bytes.len - tail.len;
        try std.testing.expectEqual(t0, grapheme.snapToBoundary(bytes, t0));
        // 가운데 줄임 — 앞의 끝과 꼬리의 시작 둘 다 묶음 경계다.
        var obuf: [403]u8 = undefined;
        const mid = elideMiddle(obuf[0 .. n + 3], bytes, max);
        try std.testing.expect(displayCols(mid) <= max);
        if (std.mem.indexOf(u8, mid, "…")) |at| if (mid.ptr != bytes.ptr and std.mem.startsWith(u8, bytes, mid[0..at])) {
            try std.testing.expectEqual(at, grapheme.snapToBoundary(bytes, at));
            const rest = mid[at + "…".len ..];
            try std.testing.expect(std.mem.endsWith(u8, bytes, rest));
            const ts = bytes.len - rest.len;
            try std.testing.expectEqual(ts, grapheme.snapToBoundary(bytes, ts));
        };
    }
    try std.testing.expect(cut > 1000); // 자르기 경로를 실제로 탔다
}
