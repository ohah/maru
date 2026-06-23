//! 선택/검색/URL — 마우스 선택·더블클릭 단어·검색 매치·OSC 8 및 휴리스틱 URL 추출.
//!
//! `TerminalCore`(core.zig)가 VT 파서 + 화면/스크롤백 storage + host-reply + 선택/검색을 한 struct에 섞은
//! 구조 위반(docs/project-rules.md "구조와 파일 분리")을 목적별 파일로 떼어낸 결과다. 여기는 "화면/스크롤백을
//! 읽어 좌표·텍스트를 산출하는" 상위 레이어다 — 의존 방향은 `selection → screen → types` 단방향(screen이
//! selection을 import하면 레이어 역전이라 금지). 각 함수는 `*TerminalCore`를 받는 free 함수다(필드 직접 접근 —
//! Zig는 필드 privacy가 없다; osc/parser/screen와 동형). 외부가 점-호출하는 pub API(selectionStart·selectWordAt·
//! findMatches·extractSelection·setPreedit 등)는 core.zig에 얇은 facade 메서드로 남고 본문만 여기 있다.
//!
//! 좌표계: 절대 행(abs) = 스크롤백 시작 기준 0..(sb.count+rows). `screen.absRow`/`absRowWrapped`(분할 S1)로 읽고,
//! `absRowFromViewport`로 뷰포트 행을 abs로 바꾼다. 선택 상태(selection_anchor/head/block)·preedit·link_store는
//! core 필드(방향 A — 필드는 평평하게 core 잔류). `invalidateSelection`/`shiftCoordsForEviction`는 screen/kitty가
//! 부르는 다리라 core 잔류(seam), 여기엔 그 선택 부분(`shiftSelectionForEviction`)만 둔다.
//!
//! 베이스: 더블클릭 단어·블록 선택은 iTerm2/Terminal.app 관례, URL 휴리스틱은 Maru 독립 설계(http(s) 스킴 +
//! 괄호 균형 다듬기), 대소문자 무시 검색은 Unicode simple case folding(width.zig와 같은 정책의 오프셋 블록만).
//! 단일 출처: docs/terminal-core-decomposition.md §7.

const std = @import("std");
const core = @import("core.zig");
const types = @import("types.zig");
const screen = @import("screen.zig"); // 화면/스크롤백 읽기(absRow·isBlankCell·ensureScrollbackRewrapped)
const width = @import("../width.zig"); // 키캡 combining 재주입(복사 바이트를 렌더와 일치)

const TerminalCore = core.TerminalCore;

/// 셀이 추가 단어 구분자인가 — config codepoint 집합(separators) 멤버십. continuation(wide 2번째 칸)은 제외
/// (구분자는 폭 1 문장부호). separators가 비면(기본) 항상 false라 현행 "공백만 경계"와 동일.
fn isWordSeparatorCell(cell: types.Cell, separators: []const u21) bool {
    if (cell.continuation) return false;
    for (separators) |sep| {
        if (sep == cell.codepoint) return true;
    }
    return false;
}

/// 단어 경계 셀인가 — 공백(isBlankCell) 또는 separators 집합 멤버. URL 감지는 separators=&.{}라 공백만 본다
/// (`:`·`/`·`.`가 URL을 쪼개지 않게). 선택은 config 구분자를 넘긴다.
fn isWordBoundaryCell(cell: types.Cell, separators: []const u21) bool {
    return screen.isBlankCell(cell) or isWordSeparatorCell(cell, separators);
}

/// 절대-행 [start, end] 선형 범위를 현재 뷰포트 좌표로 클립한다(화면 밖이면 null). 선택
/// 하이라이트와 URL 밑줄이 같은 규칙을 쓰게 공유한다.
fn clipAbsSpanToViewport(self: *const TerminalCore, start: types.SelectionPoint, end: types.SelectionPoint, block: bool) ?types.SelectionSpan {
    const top_abs = self.sb.count - @min(self.view_offset, self.sb.count);
    const bottom_abs = top_abs + self.size.rows - 1;
    if (end.row < top_abs or start.row > bottom_abs) return null;
    const start_row: u16 = if (start.row < top_abs) 0 else @intCast(start.row - top_abs);
    // 선형은 첫 행이 위로 잘리면 col 0부터(행 흐름), 블록은 col이 모든 행에서 [start.col,end.col] 고정이라
    // 행이 잘려도 그대로 둔다(잘린 위 부분도 같은 col 사각형).
    const start_col: u16 = if (block) start.col else (if (start.row < top_abs) 0 else start.col);
    const end_row: u16 = if (end.row > bottom_abs) self.size.rows - 1 else @intCast(end.row - top_abs);
    const end_col: u16 = if (block) end.col else (if (end.row > bottom_abs) self.size.cols - 1 else end.col);
    return .{ .start = .{ .row = start_row, .col = start_col }, .end = .{ .row = end_row, .col = end_col }, .block = block };
}

/// 클릭 셀의 OSC 8 링크 id(0=없음).
fn cellLinkAt(self: *const TerminalCore, abs: usize, col: u16) u32 {
    const row_cells = screen.absRow(self, abs) orelse return 0;
    if (col >= row_cells.len) return 0;
    return row_cells[col].link;
}

/// 같은 OSC 8 링크 id가 이어지는 셀 run의 절대 좌표 경계. 링크 텍스트 안의 공백도 포함하고
/// (보이는 텍스트 전체에 밑줄), soft-wrap 경계 너머로도 이어진다. 행이 바뀌는 hard 줄도 같은
/// id면 잇는다 — 한 링크가 여러 줄에 걸쳐 출력된 경우(개행 포함 echo) 모두 한 링크다.
fn linkBoundsAt(self: *const TerminalCore, abs: usize, col: u16, id: u32) struct { start: types.SelectionPoint, end: types.SelectionPoint } {
    var start_row = abs;
    var start_col: u16 = col;
    outer_left: while (true) {
        const cells_row = screen.absRow(self, start_row) orelse break;
        while (start_col > 0) {
            if (cells_row[start_col - 1].link != id) break :outer_left;
            start_col -= 1;
        }
        if (start_row == 0) break;
        const prev = screen.absRow(self, start_row - 1) orelse break;
        if (prev.len == 0 or prev[prev.len - 1].link != id) break;
        start_row -= 1;
        start_col = @intCast(prev.len - 1);
    }
    var end_row = abs;
    var end_col: u16 = col;
    outer_right: while (true) {
        const cells_row = screen.absRow(self, end_row) orelse break;
        while (end_col + 1 < cells_row.len) {
            if (cells_row[end_col + 1].link != id) break :outer_right;
            end_col += 1;
        }
        const next = screen.absRow(self, end_row + 1) orelse break;
        if (next.len == 0 or next[0].link != id) break;
        end_row += 1;
        end_col = 0;
    }
    return .{ .start = .{ .row = start_row, .col = start_col }, .end = .{ .row = end_row, .col = end_col } };
}

/// 셀 [from, to) 구간을 UTF-8로 out에 덧붙인다(continuation 셀 건너뜀, grapheme cluster 본체 포함).
/// extractSelection과 extractUrlAt이 공유 — URL/선택이 같은 글자열을 만들게 한다. `graphemes`는
/// TerminalCore.grapheme_store.items로, 셀의 grapheme_id가 가리키는 다중 코드포인트(NFD 한글 V/T
/// 등)를 무손실로 복원한다(잘림 금지 — 설계 §3.2). grapheme_id가 0이면 단일 combining 폴백.
fn appendRowUtf8(out: *std.ArrayList(u8), allocator: std.mem.Allocator, row_cells: []const types.Cell, graphemes: []const []const u21, from: usize, to: usize) !void {
    var c = from;
    while (c < to) : (c += 1) {
        const cell = row_cells[c];
        if (cell.continuation) continue;
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cell.codepoint, &buf) catch continue;
        try out.appendSlice(allocator, buf[0..n]);
        if (cell.grapheme_id != 0 and cell.grapheme_id <= graphemes.len) {
            // 다중 코드포인트 cluster(NFD 한글 등) — store 본체 전체를 무손실로 내보낸다(combining
            // 그림자는 첫 extra의 사본이라 무시). store가 권위라 키캡 재주입도 불필요(원본 그대로 담김).
            for (graphemes[cell.grapheme_id - 1]) |cp| {
                const m = std.unicode.utf8Encode(cp, &buf) catch continue;
                try out.appendSlice(allocator, buf[0..m]);
            }
        } else if (cell.combining) |cp| {
            // 키캡(base+VS16+U+20E3)은 단일 combining 슬롯이라 VS16이 U+20E3에 덮여 사라진다. 복사·URL 추출 시
            // VS16을 재주입해 온전한 키캡 시퀀스를 내보낸다 — 화면 렌더(셰이퍼도 같은 재주입)와 클립보드를 일치시킴
            // (안 그러면 보이는 컬러 키캡과 달리 'base+U+20E3'만 복사돼 붙여넣는 앱에서 깨진다). 단일 출처: width.isKeycapCombining.
            if (width.isKeycapCombining(cp)) {
                const v = std.unicode.utf8Encode(0xFE0F, &buf) catch continue;
                try out.appendSlice(allocator, buf[0..v]);
            }
            const m = std.unicode.utf8Encode(cp, &buf) catch continue;
            try out.appendSlice(allocator, buf[0..m]);
        }
    }
}

/// 단어 글자열에서 http(s):// URL의 [start, end) 바이트 범위를 찾는다(없으면 null). 끝의
/// 마무리 문장 부호는 다듬되, 열린 '('가 있으면 그만큼의 닫는 ')'는 URL의 일부로 보존한다
/// (예: Wikipedia의 ".../Foo_(bar)"). 스킴만 있고 본문이 없으면 null.
pub fn urlSpanInWord(word: []const u8) ?struct { start: usize, end: usize } {
    const start = std.mem.indexOf(u8, word, "https://") orelse std.mem.indexOf(u8, word, "http://") orelse return null;
    // URL 안의 열린 괄호 수만큼 끝 ')'를 보존한다(괄호 균형).
    var open_parens: usize = 0;
    for (word[start..]) |ch| {
        if (ch == '(') open_parens += 1;
    }
    var end_idx = word.len;
    while (end_idx > start) : (end_idx -= 1) {
        const ch = word[end_idx - 1];
        if (ch == ')' and open_parens > 0) {
            open_parens -= 1; // 균형 잡힌 닫는 괄호는 URL의 일부 — 다듬지 않는다
            break;
        }
        if (ch == '.' or ch == ',' or ch == ')' or ch == ']' or ch == '>' or ch == ';' or ch == '\'' or ch == '"') continue;
        break;
    }
    const scheme_len: usize = if (std.mem.startsWith(u8, word[start..], "https://")) "https://".len else "http://".len;
    if (end_idx <= start + scheme_len) return null; // 스킴만 있고 본문 없음
    return .{ .start = start, .end = end_idx };
}

/// 가장 오래된 n개 행이 빠져 abs 좌표가 n칸 당겨질 때 선택을 보정한다(eviction n=1, 하향 트림 n=drop).
/// 끝점이 빠진 행 범위 [0, n)에 걸리면 선택을 해제한다.
pub fn shiftSelectionForEviction(self: *TerminalCore, n: usize) void {
    if (n == 0 or self.selection_anchor == null) return;
    const a = &self.selection_anchor.?;
    const h = &self.selection_head.?;
    if (a.row < n or h.row < n) {
        selectionClear(self);
        return;
    }
    a.row -= n;
    h.row -= n;
}

/// 정규화된 선택(start <= end). 없으면 null.
fn normalizedSelection(self: *const TerminalCore) ?struct { start: types.SelectionPoint, end: types.SelectionPoint } {
    const a = self.selection_anchor orelse return null;
    const h = self.selection_head orelse return null;
    if (a.row < h.row or (a.row == h.row and a.col <= h.col)) return .{ .start = a, .end = h };
    return .{ .start = h, .end = a };
}

/// 대문자를 소문자로 접는다(findMatches 대소문자 무시 비교용). **베이스 = Unicode simple case folding**,
/// 단 width.zig와 같은 정책(small first table — 깔끔한 오프셋 블록만, 나머지는 후속)으로 **오프셋이 일정한
/// 블록만** 알고리즘으로 덮는다:
///   - ASCII A-Z(+32)
///   - Latin-1 Supplement À-Ö·Ø-Þ(U+00C0–D6·D8–DE, +32; × U+00D7는 글자가 아니라 제외)
///   - Greek Α-Ρ·Σ-Ω(U+0391–A1·A3–A9, +32; U+03A2 reserved 제외)
///   - Cyrillic А-Я(U+0410–042F, +32) / Ѐ-Џ(U+0400–040F, +80)
/// **미덮음(후속)**: Latin Extended-A(parity가 U+0139에서 뒤집혀 단일 오프셋 불가 — 표가 필요),
/// ß→ss·İ 등 1:N·로케일 특수 폴딩. 이들은 표/생성기를 들일 때(docs/font·width 정책과 같은 시점) 확장한다.
pub fn foldCase(cp: u21) u21 {
    return switch (cp) {
        'A'...'Z' => cp + 32,
        0x00C0...0x00D6, 0x00D8...0x00DE => cp + 32, // Latin-1 À-Ö, Ø-Þ
        0x0391...0x03A1, 0x03A3...0x03A9 => cp + 32, // Greek Α-Ρ, Σ-Ω
        0x0410...0x042F => cp + 32, // Cyrillic А-Я
        0x0400...0x040F => cp + 80, // Cyrillic Ѐ-Џ
        else => cp,
    };
}

/// haystack 앞부분이 needle과 대소문자 무시(foldCase)로 일치하는지(needle.len ≤ haystack.len 가정 — 호출자가 보장).
fn matchAtIgnoreCase(haystack: []const u21, needle: []const u21) bool {
    for (needle, 0..) |n, k| {
        if (foldCase(haystack[k]) != foldCase(n)) return false;
    }
    return true;
}

// ── 포인터 선택(마우스/더블·트리플클릭) + 단어 경계 ──────────────────────────────────────────────
// 외부(app/session)가 점-호출하는 selectionStart/Extend·selectWordAt·setSelectionBlock·selectLineAt·
// selectAll·selectionClear는 core.zig에 facade 메서드로 남고 본문은 여기 있다. 좌표는 절대 행(abs)이라
// 스크롤해도 내용을 따라가고, 쓰기 전 screen.ensureScrollbackRewrapped로 ring을 현재 폭으로 확정한다.

/// 더블클릭 단어 선택의 추가 구분자 최대 개수(config input.word-separators codepoint 수). 스택 디코드 버퍼 크기 —
/// 초과분은 무시한다(구분자는 보통 문장부호 십수 개라 충분; 폭주 방어선).
pub const max_word_separators: usize = 64;

/// 단어 경계의 절대 좌표 [start, end]. wordBoundsAt(URL)·wordBoundsAtImpl(선택)이 같은 named 타입을 반환해야
/// 호출 위임이 타입 일치한다(익명 struct는 호출마다 별도 타입이라 어긋난다).
pub const WordBounds = struct { start: types.SelectionPoint, end: types.SelectionPoint };

/// 선택 시작(마우스 다운). 뷰포트 행/열을 받아 절대 행으로 저장한다. 미뤄둔 스크롤백 재-wrap이
/// 있으면 먼저 끝낸다 — 안 하면 절대 좌표를 옛 ring 기준으로 만들었다가 드래그 도중 첫
/// scrollViewport(자동 스크롤 포함)가 재-wrap을 수행하며 선택을 지워버린다.
pub fn selectionStart(self: *TerminalCore, viewport_row: u16, col: u16) void {
    screen.ensureScrollbackRewrapped(self);
    const abs = screen.absRowFromViewport(self, viewport_row);
    self.selection_anchor = .{ .row = abs, .col = @min(col, self.size.cols -| 1) };
    self.selection_head = self.selection_anchor;
    self.selection_block = false; // 기본 선형 — 블록은 setSelectionBlock으로 켠다(start 직후, Option+드래그)
    self.dirty = core.fullDirty(self.size);
}

/// 블록(직사각형) 선택 모드를 켜고 끈다. platform이 selectionStart 직후 Option+드래그면 켠다(시그니처를
/// 안 바꿔 기존 selectionStart 호출처 보존). 진행 중 anchor가 없으면(선택 없음) 무시.
pub fn setSelectionBlock(self: *TerminalCore, on: bool) void {
    if (self.selection_anchor == null or self.selection_block == on) return;
    self.selection_block = on;
    self.dirty = core.fullDirty(self.size);
}

/// 선택 확장(드래그). anchor가 없으면 무시.
pub fn selectionExtend(self: *TerminalCore, viewport_row: u16, col: u16) void {
    if (self.selection_anchor == null) return;
    self.selection_head = .{ .row = screen.absRowFromViewport(self, viewport_row), .col = @min(col, self.size.cols -| 1) };
    self.dirty = core.fullDirty(self.size);
}

/// 더블클릭 단어 선택. separator_bytes(config input.word-separators, UTF-8)를 codepoint로 디코드해 공백 외
/// 추가 경계로 쓴다 — app이 매 호출 현재 config를 넘기므로 reload-safe(코어는 구분자 상태를 안 든다). 빈 값이면
/// 공백만 경계(현행 — 비공백 run 선택). **URL 감지는 wordBoundsAt(구분자 없음)이라 영향 없다.**
pub fn selectWordAt(self: *TerminalCore, viewport_row: u16, col: u16, separator_bytes: []const u8) void {
    screen.ensureScrollbackRewrapped(self); // selectionStart와 같은 이유(절대 좌표를 최종 ring 기준으로)
    // config 구분자 바이트를 codepoint 스택 버퍼로 디코드(공백은 항상 경계라 제외, 상한 초과·잘못된 UTF-8은 무시).
    var sep_buf: [max_word_separators]u21 = undefined;
    var sep_len: usize = 0;
    if (std.unicode.Utf8View.init(separator_bytes)) |view| {
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| {
            if (cp == ' ' or sep_len >= sep_buf.len) continue;
            sep_buf[sep_len] = cp;
            sep_len += 1;
        }
    } else |_| {}
    const bounds = wordBoundsAtImpl(self, viewport_row, col, sep_buf[0..sep_len]) orelse {
        selectionClear(self);
        return;
    };
    self.selection_anchor = bounds.start;
    self.selection_head = bounds.end;
    self.selection_block = false; // 새 선택은 선형 — 블록은 setSelectionBlock으로만 opt-in(selectionStart와 일관)
    self.dirty = core.fullDirty(self.size);
}

/// URL 감지용(공백만 경계 — 구분자 무시). selectWordAt(선택)은 wordBoundsAtImpl에 config 구분자를 넘긴다.
fn wordBoundsAt(self: *const TerminalCore, viewport_row: u16, col: u16) ?WordBounds {
    return wordBoundsAtImpl(self, viewport_row, col, &.{});
}

/// 클릭 위치가 속한 비공백 run(단어)의 절대 좌표 경계. soft-wrap을 넘어 확장한다. 공백 위치면 null.
fn wordBoundsAtImpl(self: *const TerminalCore, viewport_row: u16, col: u16, separators: []const u21) ?WordBounds {
    const abs = screen.absRowFromViewport(self, viewport_row);
    const row_cells = screen.absRow(self, abs) orelse return null;
    const c = @min(col, @as(u16, @intCast(row_cells.len -| 1)));
    if (screen.isBlankCell(row_cells[c])) return null; // 공백 클릭 → 선택 없음(현행)
    // 구분자 클릭: 구분자는 제 자신이 한 토큰 → 그 1칸만 선택(Ghostty/iTerm2 관례). separators 비면 false라 무관.
    if (isWordSeparatorCell(row_cells[c], separators)) {
        return .{ .start = .{ .row = abs, .col = c }, .end = .{ .row = abs, .col = c } };
    }

    // 왼쪽 경계: 행 안에서 경계(공백/구분자)까지, 행 시작에 닿으면 이전 행이 soft-wrap으로 이어질 때 계속.
    var start_row = abs;
    var start_col: u16 = c;
    outer_left: while (true) {
        const cells_row = screen.absRow(self, start_row) orelse break;
        while (start_col > 0) {
            if (isWordBoundaryCell(cells_row[start_col - 1], separators)) break :outer_left;
            start_col -= 1;
        }
        if (start_row == 0 or !screen.absRowWrapped(self, start_row - 1)) break;
        const prev = screen.absRow(self, start_row - 1) orelse break;
        if (prev.len == 0 or isWordBoundaryCell(prev[prev.len - 1], separators)) break;
        start_row -= 1;
        start_col = @intCast(prev.len - 1);
    }

    // 오른쪽 경계: 대칭 — 행 끝에 닿으면 이 행이 soft-wrap일 때 다음 행으로 계속.
    var end_row = abs;
    var end_col: u16 = c;
    outer_right: while (true) {
        const cells_row = screen.absRow(self, end_row) orelse break;
        while (end_col + 1 < cells_row.len) {
            if (isWordBoundaryCell(cells_row[end_col + 1], separators)) break :outer_right;
            end_col += 1;
        }
        if (!screen.absRowWrapped(self, end_row)) break;
        const next = screen.absRow(self, end_row + 1) orelse break;
        if (next.len == 0 or isWordBoundaryCell(next[0], separators)) break;
        end_row += 1;
        end_col = 0;
    }

    return .{ .start = .{ .row = start_row, .col = start_col }, .end = .{ .row = end_row, .col = end_col } };
}

/// 트리플클릭 줄 선택: 클릭한 행이 속한 논리 줄 전체(soft-wrap된 행들 포함)를 선택한다.
pub fn selectLineAt(self: *TerminalCore, viewport_row: u16) void {
    screen.ensureScrollbackRewrapped(self); // selectionStart와 같은 이유
    const abs = screen.absRowFromViewport(self, viewport_row);
    if (screen.absRow(self, abs) == null) return;
    var start_row = abs;
    while (start_row > 0 and screen.absRowWrapped(self, start_row - 1)) start_row -= 1;
    var end_row = abs;
    while (screen.absRowWrapped(self, end_row) and screen.absRow(self, end_row + 1) != null) end_row += 1;
    const end_cells = screen.absRow(self, end_row) orelse return;
    self.selection_anchor = .{ .row = start_row, .col = 0 };
    self.selection_head = .{ .row = end_row, .col = @intCast(end_cells.len -| 1) };
    self.selection_block = false; // 새 선택은 선형(selectionStart와 일관)
    self.dirty = core.fullDirty(self.size);
}

/// 전체 내용(스크롤백 + 화면)을 선택한다 — Select All. 절대 좌표라 현재 스크롤 위치(view_offset)와
/// 무관하게 첫 스크롤백 행(abs 0)부터 마지막 화면 행까지 잡는다. extractSelection이 행별 trailing 공백을
/// 다듬으므로 빈 마지막 행까지 잡아도 복사 결과는 깔끔하다. 화면 행이 0이면 무동작.
pub fn selectAll(self: *TerminalCore) void {
    screen.ensureScrollbackRewrapped(self); // selectLineAt와 같은 이유 — abs 좌표 쓰기 전 스크롤백 rewrap 확정
    if (self.size.rows == 0) return;
    const last_abs = self.sb.count + self.size.rows - 1;
    const end_cells = screen.absRow(self, last_abs) orelse return;
    self.selection_anchor = .{ .row = 0, .col = 0 };
    self.selection_head = .{ .row = last_abs, .col = @intCast(end_cells.len -| 1) };
    self.selection_block = false; // 새 선택은 선형 — Option+드래그 블록 뒤 ⌘A가 직사각형으로 새던 누수 수정
    self.dirty = core.fullDirty(self.size);
}

/// 선택 해제(anchor가 없으면 무동작 — 불필요한 dirty 방지). 행 재배치 연산이 abs 좌표 불변식을 깰 때
/// core의 invalidateSelection seam이 이걸 부른다.
pub fn selectionClear(self: *TerminalCore) void {
    if (self.selection_anchor == null) return;
    self.selection_anchor = null;
    self.selection_head = null;
    self.selection_block = false;
    self.dirty = core.fullDirty(self.size);
}

// ── URL 감지(Cmd+hover/클릭) ──────────────────────────────────────────────────────────────────────
// OSC 8 명시적 링크가 항상 우선이고(보이는 텍스트와 무관), 없으면 클릭 단어의 http(s) 휴리스틱
// (urlSpanInWord). urlAnchorAt/urlSpanAtAbs/extractUrlAt는 core.zig facade로 점-호출되고, wordIsUrl은
// hover의 매-mouseMove 비용을 줄이는 alloc-없는 판정(내부 전용). OSC 8 URI는 self.linkUri(core 잔류 link_store).

/// Cmd+클릭/hover 위치가 URL이면 그 run의 시작 셀 절대 좌표를 돌려준다(밑줄 anchor용, 할당 없음).
/// OSC 8 명시적 링크가 있으면 그것이 우선이고(보이는 텍스트와 무관), 없으면 화면 글자의 http(s) 휴리스틱.
pub fn urlAnchorAt(self: *const TerminalCore, viewport_row: u16, col: u16) ?types.SelectionPoint {
    const abs = screen.absRowFromViewport(self, viewport_row);
    const id = cellLinkAt(self, abs, col);
    if (id != 0) return linkBoundsAt(self, abs, col, id).start;
    if (!wordIsUrl(self, viewport_row, col)) return null;
    const bounds = wordBoundsAt(self, viewport_row, col) orelse return null;
    return bounds.start;
}

/// 절대 좌표 anchor에서 시작하는 URL 단어의 현재 뷰포트 밑줄 범위. 매 frame 호출돼 스크롤/
/// 출력/resize 후에도 현재 폭/위치에 맞게 클립된다(stale span OOB 차단).
pub fn urlSpanAtAbs(self: *const TerminalCore, anchor: types.SelectionPoint) ?types.SelectionSpan {
    const top_abs = self.sb.count - @min(self.view_offset, self.sb.count);
    const bottom_abs = top_abs + self.size.rows - 1;
    if (anchor.row < top_abs or anchor.row > bottom_abs) return null; // anchor가 화면 밖
    const id = cellLinkAt(self, anchor.row, anchor.col);
    if (id != 0) {
        const bounds = linkBoundsAt(self, anchor.row, anchor.col, id);
        return clipAbsSpanToViewport(self, bounds.start, bounds.end, false);
    }
    const vp_row: u16 = @intCast(anchor.row - top_abs);
    const bounds = wordBoundsAt(self, vp_row, anchor.col) orelse return null;
    return clipAbsSpanToViewport(self, bounds.start, bounds.end, false);
}

/// Cmd+클릭 위치의 URL을 추출한다(없으면 null). 클릭 셀이 속한 비공백 run(soft-wrap 포함) 안에서
/// http:// 또는 https:// 부터 run 끝까지를 URL로 보고, 끝에 붙은 문장 부호(괄호/마침표 등)는 다듬는다.
/// OSC 8 명시적 링크가 있으면 그 URI를 그대로(다듬지 않고). 호출자가 free한다.
pub fn extractUrlAt(self: *const TerminalCore, allocator: std.mem.Allocator, viewport_row: u16, col: u16) !?[]u8 {
    // OSC 8 명시적 링크가 우선 — 프로그램이 지정한 URI를 그대로 연다(보이는 텍스트와 무관).
    const link_id = cellLinkAt(self, screen.absRowFromViewport(self, viewport_row), col);
    if (link_id != 0) {
        const uri = self.linkUri(link_id) orelse return null;
        return try allocator.dupe(u8, uri);
    }
    const bounds = wordBoundsAt(self, viewport_row, col) orelse return null;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var abs = bounds.start.row;
    while (abs <= bounds.end.row) : (abs += 1) {
        const row_cells = screen.absRow(self, abs) orelse break;
        const from: usize = if (abs == bounds.start.row) bounds.start.col else 0;
        const to: usize = if (abs == bounds.end.row) @min(@as(usize, bounds.end.col) + 1, row_cells.len) else row_cells.len;
        try appendRowUtf8(&out, allocator, row_cells, self.grapheme_store.items, from, to);
    }
    const span = urlSpanInWord(out.items) orelse {
        out.deinit(allocator);
        return null;
    };
    const url = try allocator.dupe(u8, out.items[span.start..span.end]);
    out.deinit(allocator);
    return url;
}

/// 클릭 셀이 속한 단어가 URL인지(할당 없이) 판정한다. hover의 매-mouseMove 비용을 줄이려
/// extractUrlAt의 alloc 없이 같은 판정만 한다. app 호출은 없어 core facade가 없지만, core.zig 테스트가
/// `selection.wordIsUrl(&core, ...)`로 cross-file 호출하므로 pub(foldCase·urlSpanInWord와 같은 이유).
pub fn wordIsUrl(self: *const TerminalCore, viewport_row: u16, col: u16) bool {
    if (cellLinkAt(self, screen.absRowFromViewport(self, viewport_row), col) != 0) return true;
    const bounds = wordBoundsAt(self, viewport_row, col) orelse return false;
    // URL은 보통 한 단어라 짧은 스택 버퍼로 충분하고, 넘치면 URL일 수 있으니 통과시킨다.
    var buf: [2048]u8 = undefined;
    var len: usize = 0;
    var abs = bounds.start.row;
    outer: while (abs <= bounds.end.row) : (abs += 1) {
        const row_cells = screen.absRow(self, abs) orelse break;
        const from: usize = if (abs == bounds.start.row) bounds.start.col else 0;
        const to: usize = if (abs == bounds.end.row) @min(@as(usize, bounds.end.col) + 1, row_cells.len) else row_cells.len;
        var c = from;
        while (c < to) : (c += 1) {
            const cell = row_cells[c];
            if (cell.continuation) continue;
            var enc: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cell.codepoint, &enc) catch continue;
            if (len + n > buf.len) break :outer; // 너무 긴 단어 — 판정 보류, 통과
            @memcpy(buf[len .. len + n], enc[0..n]);
            len += n;
        }
    }
    return urlSpanInWord(buf[0..len]) != null;
}

// ── 검색(Find) + 추출(복사) + IME preedit ─────────────────────────────────────────────────────────
// findMatches는 스크롤백 Find의 단일 출처(코어 상태), extractSelection/Block은 클립보드 복사 텍스트를 만든다.
// 전부 core.zig facade로 점-호출되고, setPreedit는 IME 조합 텍스트(렌더 합성 전용 — 셀 그리드 불변).

/// 스크롤백 + 화면에서 needle을 찾아 절대 좌표 매치를 out에 채운다(out은 호출자 소유). 논리 줄(soft-wrap 이음)
/// 단위로 스캔해 wrap 경계를 넘는 매치도 잡고, 같은 줄 안에선 비겹침(매치 뒤로 needle 길이만큼 건너뜀). needle이
/// 비면 무동작. 대소문자 무시는 foldCase(ASCII + Latin-1·Greek·Cyrillic 깔끔한 오프셋 블록 — Latin Ext-A 등은 후속).
/// 스크롤백 Find의 단일 출처(코어 상태) — UI 상태머신(find_overlay)은 이 결과를 받기만 한다. regex/fuzzy는 후속.
/// 베이스: alt에선 active area(현재 화면)만 검색(Ghostty ActiveSearch와 동작 일치 — alt는 sb.count==0이라 자연히).
pub fn findMatches(self: *TerminalCore, allocator: std.mem.Allocator, needle_utf8: []const u8, out: *std.ArrayList(types.Match)) !void {
    out.clearRetainingCapacity();
    if (needle_utf8.len == 0) return;
    screen.ensureScrollbackRewrapped(self); // abs 좌표 쓰기 전 스크롤백 rewrap 확정(selectAll과 같은 이유)

    // needle을 코드포인트 배열로 디코드(셀 codepoint와 같은 단위로 비교 — 멀티바이트 오프셋 매핑 회피).
    var needle: std.ArrayList(u21) = .empty;
    defer needle.deinit(allocator);
    var nv = std.unicode.Utf8View.init(needle_utf8) catch return; // 깨진 needle은 매치 없음
    var nit = nv.iterator();
    while (nit.nextCodepoint()) |cp| try needle.append(allocator, cp);
    if (needle.items.len == 0) return;

    // 스크롤백 포함 [0, total) 전체를 검색한다(abs 0부터). alt에선 sb.count==0이라 자연히 현재 화면뿐.
    const total = self.sb.count + self.size.rows;
    // 논리 줄마다 코드포인트 시퀀스(cps)와 각 코드포인트의 절대 좌표(coords)를 만들어 검색하고, 다음 줄에서
    // 버퍼를 재사용한다(스크롤백 전체를 한 문자열로 들지 않음 — 메모리는 가장 긴 논리 줄 하나).
    var cps: std.ArrayList(u21) = .empty;
    defer cps.deinit(allocator);
    var coords: std.ArrayList(types.SelectionPoint) = .empty;
    defer coords.deinit(allocator);

    var abs: usize = 0;
    while (abs < total) {
        cps.clearRetainingCapacity();
        coords.clearRetainingCapacity();
        // 논리 줄 = 현재 abs부터 wrapped=false인 행까지(soft-wrap 이음).
        var line_abs = abs;
        while (true) {
            const row = screen.absRow(self, line_abs) orelse break;
            const wrapped = screen.absRowWrapped(self, line_abs);
            // wrapped 행은 전폭이 실제 내용(우측 끝에서 wrap), 마지막(hard) 행은 뒤 빈칸을 자른다(extractSelection과 같은 규칙).
            const limit: usize = if (wrapped) row.len else screen.trimmedLen(row);
            var col: usize = 0;
            while (col < limit) : (col += 1) {
                const cell = row[col];
                if (cell.continuation) continue; // wide glyph의 둘째 슬롯은 건너뜀(코드포인트 1개)
                try cps.append(allocator, cell.codepoint);
                try coords.append(allocator, .{ .row = line_abs, .col = @intCast(col) });
            }
            if (!wrapped) break;
            line_abs += 1;
            if (line_abs >= total) break;
        }
        // 이 논리 줄에서 needle 슬라이딩 매치(비겹침).
        var i: usize = 0;
        while (i + needle.items.len <= cps.items.len) {
            if (matchAtIgnoreCase(cps.items[i..], needle.items)) {
                try out.append(allocator, .{
                    .start = coords.items[i],
                    .end = coords.items[i + needle.items.len - 1],
                });
                i += needle.items.len; // 비겹침: 매치 뒤로 건너뜀
            } else i += 1;
        }
        abs = line_abs + 1;
    }
}

/// 검색 매치(절대 좌표)를 현재 뷰포트 좌표로 클립한다(화면 밖이면 null) — 선택 하이라이트와 같은 규칙 공유.
pub fn matchViewportSpan(self: *const TerminalCore, m: types.Match) ?types.SelectionSpan {
    return clipAbsSpanToViewport(self, m.start, m.end, false);
}

/// IME 조합 중 텍스트를 설정한다(빈 입력 = 조합 종료/취소). 렌더 합성 전용 상태라 셀 그리드·커서는 변하지
/// 않는다(표시는 renderSnapshot). preedit는 core 소유 필드(방향 A) — selection.zig가 alloc/free만 한다.
pub fn setPreedit(self: *TerminalCore, bytes: []const u8) !void {
    self.owner_dbg.assertOwnedBySelf(); // reader 노출 시 core_mutex 보유 강제(디버그 전용 §6-5)
    if (self.preedit) |old| {
        self.allocator.free(old);
        self.preedit = null;
    }
    if (bytes.len > 0) self.preedit = try self.allocator.dupe(u8, bytes);
    self.dirty = core.fullDirty(self.size);
}

/// 현재 뷰포트에 보이는 선택 범위(렌더용). 화면 밖이면 null. 블록 모드면 col을 행과 무관하게 min/max로
/// 정렬해 직사각형 span([lo,hi]×[start.row,end.row])으로 낸다(normalizedSelection은 row만 정규화).
pub fn selectionViewportSpan(self: *const TerminalCore) ?types.SelectionSpan {
    const sel = normalizedSelection(self) orelse return null;
    if (self.selection_block) {
        const lo = @min(sel.start.col, sel.end.col);
        const hi = @max(sel.start.col, sel.end.col);
        return clipAbsSpanToViewport(
            self,
            .{ .row = sel.start.row, .col = lo },
            .{ .row = sel.end.row, .col = hi },
            true,
        );
    }
    return clipAbsSpanToViewport(self, sel.start, sel.end, false);
}

/// 선택된 텍스트를 추출한다(클립보드 복사용). 행 단위 선형 선택 — soft-wrap으로 이어진 행은 줄바꿈 없이 잇고,
/// hard 줄끝에서만 \n을 넣는다. 각 행은 뒤 빈칸을 trim한다(soft 행 제외). 블록 모드면 직사각형 추출로 분기한다.
pub fn extractSelection(self: *const TerminalCore, allocator: std.mem.Allocator) !?[]u8 {
    const sel = normalizedSelection(self) orelse return null;
    if (self.selection_block) return extractBlockSelection(self, allocator, sel.start, sel.end);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var abs = sel.start.row;
    while (abs <= sel.end.row) : (abs += 1) {
        const row_cells = screen.absRow(self, abs) orelse continue;
        const wrapped_flag = screen.absRowWrapped(self, abs);
        const from: usize = if (abs == sel.start.row) sel.start.col else 0;
        const full_to: usize = if (abs == sel.end.row) @min(@as(usize, sel.end.col) + 1, row_cells.len) else row_cells.len;
        // hard 줄끝(또는 선택 끝 행)은 뒤 빈칸을 잘라 복사한다 — 패딩이 텍스트로 들어가지 않게.
        const to: usize = if (wrapped_flag and abs != sel.end.row) full_to else @max(from, @min(full_to, screen.trimmedLen(row_cells)));
        try appendRowUtf8(&out, allocator, row_cells, self.grapheme_store.items, from, to);
        if (abs != sel.end.row and !wrapped_flag) try out.append(allocator, '\n');
    }
    return try out.toOwnedSlice(allocator);
}

/// 블록(직사각형) 선택 추출 — 각 행에서 [lo,hi] 열만(col은 행과 무관, soft-wrap 무시), 행마다 개행.
/// hi 칸 뒤 빈칸은 trim해 패딩이 텍스트로 안 들어간다(선형 추출과 같은 trimmedLen 규칙). 행이 hi보다
/// 짧으면 그 행 몫만(빈 줄도 개행은 유지 — 사각형 모양 보존). start/end는 row만 정규화돼 col은 여기서 min/max.
fn extractBlockSelection(self: *const TerminalCore, allocator: std.mem.Allocator, start: types.SelectionPoint, end: types.SelectionPoint) !?[]u8 {
    const lo: usize = @min(start.col, end.col);
    const hi: usize = @max(start.col, end.col);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var abs = start.row;
    while (abs <= end.row) : (abs += 1) {
        if (screen.absRow(self, abs)) |row_cells| {
            const from: usize = @min(lo, row_cells.len);
            const full_to: usize = @min(hi + 1, row_cells.len);
            const to: usize = @max(from, @min(full_to, screen.trimmedLen(row_cells)));
            try appendRowUtf8(&out, allocator, row_cells, self.grapheme_store.items, from, to);
        }
        if (abs != end.row) try out.append(allocator, '\n'); // 블록은 행마다 개행(사각형 — soft-wrap 무관)
    }
    return try out.toOwnedSlice(allocator);
}
