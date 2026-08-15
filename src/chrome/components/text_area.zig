//! 멀티라인 텍스트 상자의 **세로 축** — 커밋 메시지 입력(docs/text-field-editor.md §12).
//!
//! **새 편집 모델이 아니다.** §12.1이 정한 조합의 얇은 층이다:
//!
//! ```
//! TextArea (이 파일 — 세로 축만)
//!  ├ 편집 상태 ─→ text_field.TextField          (그대로 재사용 — caret/selection이 바이트 오프셋이라 개행 무관)
//!  ├ 랩       ─→ ui/visual_map.pieces           (그대로 재사용 — CJK 정확)
//!  └ 행 배치   ─→ text_field.fieldLayout        (시각 행마다 호출 — 호출자가 한다)
//! ```
//!
//! 여기가 소유하는 것은 **"오프셋 ↔ 시각 행"** 하나다. 그 매핑이 없으면 ↑↓도, 상자 높이도, 세로
//! 스크롤바도 계산할 수 없다.
//!
//! ## §12.3이 남긴 제약 — 이 파일이 지키는 몫
//!
//! - **① 텍스트 역할은 13pt(`.control`/`.body`)다.** 랩을 셀 열 단위로 계산하는 것이 성립하는 유일한
//!   이유가 "chrome 글자가 등폭이라 셀 = 실제 advance"이기 때문이다. `.supporting`(12pt)으로 낮추면
//!   랩 지점이 그려지는 글자와 어긋나고, 자르기와 달리 **글자가 상자 밖으로 넘치는 형태로 드러난다.**
//!   그래서 이 층은 열수를 받기만 하고 스스로 pt를 고르지 않는다 — 호출자가 13pt 역할로 잰 열수를 준다.
//! - **② 이 설계는 등폭 폰트 규칙에 묶여 있다**(①의 귀결). face를 바꾸는 논의를 하면 §12를 함께 본다.
//! - **③ 탭을 전개하지 않는다.** `visual_map`은 "이미 전개된 텍스트"를 요구하지만, 커밋 메시지는
//!   전개하면 **저장되는 내용과 보이는 것이 달라진다.** 탭은 한 칸으로 세고 그대로 둔다.
//! - **④ `\n`을 단어 구분자로 넘긴다** — `separators`는 주입 인자다. 안 넘기면 ⌥←/→가 줄 끝과 다음 줄
//!   첫 단어를 **한 단어로 붙인다**(`isSeparator`가 공백·탭만 항상 구분자로 본다).
//! - **⑤ Home/End를 시각 행 단위로 다시 정의한다** — `TextField`의 것은 한 줄 전제다.
//! - **⑥ 세로 스크롤바는 논리 줄이 아니라 시각 행으로 센다.** 랩이 켜지면 논리 줄 하나가 여러 시각
//!   행이라, 논리 줄로 세면 막대가 실제보다 위에 선다. **스크롤이 붙기 전에는 그 값이 늘 0이라 아무도
//!   못 보다가 붙이는 순간 드러난다**(편집기 N1.5에서 실제로 겪은 함정).
//!
//! **할당하지 않는다.** 시각 행 목록은 호출자가 준 버퍼에 채운다.

const std = @import("std");
const text_field = @import("text_field.zig");
const visual_map = @import("../ui/visual_map.zig");

/// 커밋 메시지의 단어 구분자. 주소창의 `/ . ? & # =`와 다르다 — 여기서는 **개행이 핵심**이다(제약 ④).
/// 공백·탭은 `isSeparator`가 항상 구분자로 보므로 여기 없어도 된다.
pub const word_separators = "\n";

/// 시각 행 하나: 원문의 어느 구간이 화면 몇 번째 줄에 오는가.
pub const VisualLine = struct {
    /// 원문 바이트 구간 [start, end). **개행은 포함하지 않는다** — 그 줄에 그릴 글자만 가리킨다.
    start: usize,
    end: usize,
    /// 몇 번째 논리 줄인가(0-based).
    logical: u32,
    /// 그 논리 줄 안에서 몇 번째 조각인가(0-based). 0이면 줄의 시작이다.
    piece: u32,
};

/// 랩 결과. `lines`는 호출자 버퍼의 앞부분이고, `truncated`는 버퍼가 모자라 **끊겼다**는 사실이다.
///
/// 끊김을 조용히 삼키지 않는 이유: 상자 높이와 스크롤 범위가 이 개수에서 나오므로, 모자란 채로 진행하면
/// 화면이 "메시지가 짧다"고 거짓말한다.
pub const Wrapped = struct {
    lines: []const VisualLine,
    truncated: bool,

    /// 시각 행 수. **상자 높이와 스크롤바가 이 값을 쓴다**(제약 ⑥ — 논리 줄 수가 아니다).
    pub fn count(self: Wrapped) usize {
        return self.lines.len;
    }
};

/// 원문을 시각 행으로 나눈다.
///
/// `view_cols`는 **13pt 역할로 잰 열수**다(제약 ①). `wrap`이 false면 논리 줄 하나가 시각 행 하나다.
///
/// **빈 줄도 한 행이다.** 개행만 있는 줄을 건너뛰면 그 자리에 caret을 놓을 수 없고, 사용자가 Enter를
/// 눌렀는데 상자가 안 자라는 것으로 보인다(커밋 메시지는 제목과 본문 사이 빈 줄이 관례다).
pub fn wrap(text: []const u8, view_cols: u16, do_wrap: bool, out: []VisualLine) Wrapped {
    var n: usize = 0;
    var logical: u32 = 0;
    var line_start: usize = 0;

    while (true) {
        const nl = std.mem.indexOfScalarPos(u8, text, line_start, '\n');
        const line_end = nl orelse text.len;
        const line = text[line_start..line_end];

        var piece_index: u32 = 0;
        var it = visual_map.pieces(line, view_cols, do_wrap);
        var any = false;
        while (it.next()) |piece| {
            if (n == out.len) return .{ .lines = out[0..n], .truncated = true };
            out[n] = .{
                .start = line_start + piece.start,
                .end = line_start + piece.end,
                .logical = logical,
                .piece = piece_index,
            };
            n += 1;
            piece_index += 1;
            any = true;
        }
        // 빈 줄은 조각이 하나도 안 나온다 — 그래도 **한 행을 낸다**(위 doc).
        if (!any) {
            if (n == out.len) return .{ .lines = out[0..n], .truncated = true };
            out[n] = .{ .start = line_start, .end = line_start, .logical = logical, .piece = 0 };
            n += 1;
        }

        if (nl == null) break;
        line_start = line_end + 1;
        logical += 1;
    }
    return .{ .lines = out[0..n], .truncated = false };
}

/// 바이트 오프셋이 몇 번째 시각 행에 있나. 없으면 마지막 행(끝에 붙은 caret).
///
/// **`end`를 포함으로 본다** — caret은 글자 *사이*에 서므로 줄 끝 오프셋도 그 줄의 것이다. 배타로 보면
/// 줄 끝에서 caret이 다음 줄 머리로 튄다.
pub fn lineAt(w: Wrapped, offset: usize) usize {
    if (w.lines.len == 0) return 0;
    for (w.lines, 0..) |line, index| {
        if (offset >= line.start and offset <= line.end) return index;
    }
    return w.lines.len - 1;
}

/// 시각 행 하나를 `text_field.fieldLayout`에 넘길 View로 만든다.
///
/// **가로 축은 그쪽이 소유한다**(§12.1) — caret 열·선택 span·가로 스크롤 창을 여기서 다시 풀면 "그려진
/// caret == 클릭 caret" 불변식이 두 벌이 된다.
pub fn viewForLine(field: text_field.View, w: Wrapped, index: usize) text_field.View {
    if (index >= w.lines.len) return .{ .text = "", .caret = 0 };
    const line = w.lines[index];
    const slice = field.text[line.start..line.end];
    // caret이 이 줄에 있으면 줄-상대 오프셋으로 옮기고, 아니면 이 줄에는 caret이 없다(0으로 두되
    // 호출자가 `lineAt`으로 어느 줄인지 이미 안다).
    const caret: usize = if (field.caret >= line.start and field.caret <= line.end)
        field.caret - line.start
    else
        0;
    return .{ .text = slice, .caret = caret, .selection = null };
}

// ── 세로 이동(제약 ⑤) ───────────────────────────────────────────────────────────

/// ↑/↓ — **시각 행 단위**로 움직인다. 논리 줄 단위면 접힌 줄 안에서 caret이 건너뛴다.
///
/// **목표 열을 유지하지 않는다**(v1). 긴 줄에서 짧은 줄로 내려갔다 돌아오면 열이 줄 끝으로 붙는데,
/// 커밋 메시지는 줄이 짧아 그 차이가 작다. 유지하려면 호출자가 "마지막으로 의도한 열"을 들어야 하고
/// 그건 상태라 이 순수 층이 아니라 세션이 가질 것이다.
pub fn moveVertical(w: Wrapped, offset: usize, delta: i32) usize {
    if (w.lines.len == 0) return offset;
    const current = lineAt(w, offset);
    const col = offset - w.lines[current].start;

    const target_i64 = @as(i64, @intCast(current)) + delta;
    if (target_i64 < 0) return w.lines[0].start; // 맨 위에서 더 올라가면 문서 처음
    const target: usize = @intCast(target_i64);
    if (target >= w.lines.len) return w.lines[w.lines.len - 1].end; // 맨 아래에서 더 내려가면 문서 끝

    const line = w.lines[target];
    const width = line.end - line.start;
    return line.start + @min(col, width);
}

/// Home — 그 **시각 행**의 처음(논리 줄의 처음이 아니다).
pub fn lineStart(w: Wrapped, offset: usize) usize {
    if (w.lines.len == 0) return offset;
    return w.lines[lineAt(w, offset)].start;
}

/// End — 그 **시각 행**의 끝.
pub fn lineEnd(w: Wrapped, offset: usize) usize {
    if (w.lines.len == 0) return offset;
    return w.lines[lineAt(w, offset)].end;
}

// ── 상자 높이·스크롤(제약 ⑥) ────────────────────────────────────────────────────

/// 상자가 보여 줄 시각 행 수. 내용을 따라 자라되 `max_rows`에서 멈춘다(그 뒤는 세로 스크롤).
///
/// **최소 한 행이다.** 빈 메시지에서 높이 0이면 상자가 사라져 어디를 눌러야 할지 알 수 없다.
pub fn visibleRows(w: Wrapped, max_rows: usize) usize {
    return std.math.clamp(w.count(), 1, @max(max_rows, 1));
}

/// caret이 보이도록 맞춘 첫 행(스크롤 offset). **시각 행으로 센다**(제약 ⑥).
pub fn scrollToCaret(w: Wrapped, first_row: usize, visible: usize, caret_offset: usize) usize {
    if (visible == 0) return first_row;
    const at = lineAt(w, caret_offset);
    if (at < first_row) return at; // 위로 벗어남
    if (at >= first_row + visible) return at + 1 - visible; // 아래로 벗어남
    return first_row;
}

// ── 테스트 ──────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn wrapFixture(text: []const u8, cols: u16, do_wrap: bool, buf: []VisualLine) Wrapped {
    return wrap(text, cols, do_wrap, buf);
}

test "논리 줄이 시각 행이 된다 — 빈 줄도 한 행이다" {
    // 커밋 메시지는 제목과 본문 사이에 빈 줄을 두는 것이 관례다. 그 줄을 건너뛰면 caret을 거기 놓을 수
    // 없고, Enter를 눌렀는데 상자가 안 자라는 것으로 보인다.
    var buf: [16]VisualLine = undefined;
    const w = wrapFixture("subject\n\nbody", 40, true, &buf);
    try testing.expectEqual(@as(usize, 3), w.count());
    try testing.expectEqualStrings("subject", "subject\n\nbody"[w.lines[0].start..w.lines[0].end]);
    try testing.expectEqual(w.lines[1].start, w.lines[1].end); // 빈 줄
    try testing.expectEqual(@as(u32, 2), w.lines[2].logical);
}

test "랩: 한 논리 줄이 여러 시각 행으로 갈리고 조각 번호가 붙는다" {
    var buf: [16]VisualLine = undefined;
    const text = "aaaabbbbcccc";
    const w = wrapFixture(text, 4, true, &buf);
    try testing.expectEqual(@as(usize, 3), w.count());
    for (w.lines, 0..) |line, index| {
        try testing.expectEqual(@as(u32, 0), line.logical); // 전부 같은 논리 줄
        try testing.expectEqual(@as(u32, @intCast(index)), line.piece);
    }
    try testing.expectEqualStrings("aaaa", text[w.lines[0].start..w.lines[0].end]);
    try testing.expectEqualStrings("cccc", text[w.lines[2].start..w.lines[2].end]);
}

test "랩을 끄면 논리 줄 하나가 시각 행 하나다" {
    var buf: [16]VisualLine = undefined;
    const w = wrapFixture("aaaabbbbcccc\nsecond", 4, false, &buf);
    try testing.expectEqual(@as(usize, 2), w.count());
}

test "CJK: `ceil(폭/열수)`로 세면 틀린다 — cluster를 쪼개지 않는다" {
    // `visual_map` 헤더가 기록한 함정이다: 한글 5자·뷰 5열이면 식은 2행인데 실제는 3행이다(행 끝에 한
    // 칸이 남고 그 낭비가 누적된다). 이 층이 그 계산을 **복제하지 않는** 것이 요점이라 여기서 고정한다.
    var buf: [16]VisualLine = undefined;
    const w = wrapFixture("한글한글한", 5, true, &buf);
    try testing.expectEqual(@as(usize, 3), w.count());
}

test "버퍼가 모자라면 끊겼다고 말한다(조용히 삼키지 않는다)" {
    // 상자 높이와 스크롤 범위가 이 개수에서 나온다 — 모자란 채로 진행하면 화면이 "메시지가 짧다"고
    // 거짓말한다.
    var buf: [2]VisualLine = undefined;
    const w = wrapFixture("a\nb\nc\nd", 40, true, &buf);
    try testing.expect(w.truncated);
    try testing.expectEqual(@as(usize, 2), w.count());
}

test "제약 ⑤: Home/End는 **시각 행** 단위다" {
    var buf: [16]VisualLine = undefined;
    const text = "aaaabbbb";
    const w = wrapFixture(text, 4, true, &buf);
    // 두 번째 시각 행 한가운데(offset 6)
    try testing.expectEqual(@as(usize, 4), lineStart(w, 6));
    try testing.expectEqual(@as(usize, 8), lineEnd(w, 6));
    // 논리 줄 단위였다면 0과 8이 나왔을 것이다.
}

test "제약 ⑤: ↑↓는 시각 행 단위로 움직이고 짧은 줄에서는 끝으로 붙는다" {
    var buf: [16]VisualLine = undefined;
    const text = "aaaa\nbb\ncccc";
    const w = wrapFixture(text, 40, true, &buf);
    // 첫 줄 3열 → 아래로: 두 번째 줄은 2글자뿐이라 끝(offset 7)으로 붙는다.
    try testing.expectEqual(@as(usize, 7), moveVertical(w, 3, 1));
    // 맨 위에서 더 올라가면 문서 처음, 맨 아래에서 더 내려가면 문서 끝.
    try testing.expectEqual(@as(usize, 0), moveVertical(w, 2, -1));
    try testing.expectEqual(text.len, moveVertical(w, 9, 1));
}

test "caret은 줄 끝 오프셋에서 다음 줄로 튀지 않는다" {
    // `end`를 배타로 보면 줄 끝에 선 caret이 다음 줄 머리로 옮겨 보인다.
    var buf: [16]VisualLine = undefined;
    const w = wrapFixture("aaaabbbb", 4, true, &buf);
    try testing.expectEqual(@as(usize, 0), lineAt(w, 4)); // 첫 행의 끝
}

test "제약 ⑥: 높이와 스크롤은 **시각 행**으로 센다" {
    var buf: [16]VisualLine = undefined;
    // 논리 줄은 하나인데 시각 행은 셋이다 — 논리 줄로 세면 상자가 한 줄로 남고 스크롤바가 안 뜬다.
    const w = wrapFixture("aaaabbbbcccc", 4, true, &buf);
    try testing.expectEqual(@as(usize, 3), w.count());
    try testing.expectEqual(@as(usize, 2), visibleRows(w, 2)); // 상한에서 멈춘다
    try testing.expectEqual(@as(usize, 3), visibleRows(w, 8)); // 내용을 따라 자란다

    // 빈 메시지도 한 행은 있다(상자가 사라지면 어디를 눌러야 할지 모른다).
    var empty_buf: [4]VisualLine = undefined;
    try testing.expectEqual(@as(usize, 1), visibleRows(wrapFixture("", 40, true, &empty_buf), 8));
}

test "스크롤: caret이 창 밖으로 나가면 그만큼만 따라간다" {
    var buf: [16]VisualLine = undefined;
    const w = wrapFixture("a\nb\nc\nd\ne", 40, true, &buf);
    // 창이 두 행이고 caret이 5번째 행(offset 8)이면 first_row는 3이 된다.
    try testing.expectEqual(@as(usize, 3), scrollToCaret(w, 0, 2, 8));
    // 창 안이면 움직이지 않는다.
    try testing.expectEqual(@as(usize, 3), scrollToCaret(w, 3, 2, 6));
    // 위로 벗어나면 그 행으로.
    try testing.expectEqual(@as(usize, 0), scrollToCaret(w, 3, 2, 0));
}

test "가로 축은 text_field가 소유한다 — 줄 슬라이스와 줄-상대 caret을 넘긴다" {
    // 여기서 caret 열을 다시 풀면 "그려진 caret == 클릭 caret" 불변식이 두 벌이 된다(§12.1).
    var buf: [16]VisualLine = undefined;
    const text = "aaaabbbb";
    const w = wrapFixture(text, 4, true, &buf);
    const field: text_field.View = .{ .text = text, .caret = 6 };
    const line_view = viewForLine(field, w, 1);
    try testing.expectEqualStrings("bbbb", line_view.text);
    try testing.expectEqual(@as(usize, 2), line_view.caret); // 줄-상대
}

test "제약 ④: 개행이 단어 구분자에 들어 있다" {
    // 안 넘기면 ⌥←/→가 줄 끝과 다음 줄 첫 단어를 한 단어로 붙인다.
    try testing.expect(std.mem.indexOfScalar(u8, word_separators, '\n') != null);
}
