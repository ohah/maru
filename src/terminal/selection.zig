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
pub fn isWordSeparatorCell(cell: types.Cell, separators: []const u21) bool {
    if (cell.continuation) return false;
    for (separators) |sep| {
        if (sep == cell.codepoint) return true;
    }
    return false;
}

/// 단어 경계 셀인가 — 공백(isBlankCell) 또는 separators 집합 멤버. URL 감지는 separators=&.{}라 공백만 본다
/// (`:`·`/`·`.`가 URL을 쪼개지 않게). 선택은 config 구분자를 넘긴다.
pub fn isWordBoundaryCell(cell: types.Cell, separators: []const u21) bool {
    return screen.isBlankCell(cell) or isWordSeparatorCell(cell, separators);
}

/// 절대-행 [start, end] 선형 범위를 현재 뷰포트 좌표로 클립한다(화면 밖이면 null). 선택
/// 하이라이트와 URL 밑줄이 같은 규칙을 쓰게 공유한다.
pub fn clipAbsSpanToViewport(self: *const TerminalCore, start: types.SelectionPoint, end: types.SelectionPoint, block: bool) ?types.SelectionSpan {
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
pub fn cellLinkAt(self: *const TerminalCore, abs: usize, col: u16) u32 {
    const row_cells = screen.absRow(self, abs) orelse return 0;
    if (col >= row_cells.len) return 0;
    return row_cells[col].link;
}

/// 같은 OSC 8 링크 id가 이어지는 셀 run의 절대 좌표 경계. 링크 텍스트 안의 공백도 포함하고
/// (보이는 텍스트 전체에 밑줄), soft-wrap 경계 너머로도 이어진다. 행이 바뀌는 hard 줄도 같은
/// id면 잇는다 — 한 링크가 여러 줄에 걸쳐 출력된 경우(개행 포함 echo) 모두 한 링크다.
pub fn linkBoundsAt(self: *const TerminalCore, abs: usize, col: u16, id: u32) struct { start: types.SelectionPoint, end: types.SelectionPoint } {
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

/// 셀 [from, to) 구간을 UTF-8로 out에 덧붙인다(continuation 셀 건너뜀, combining mark 포함).
/// extractSelection과 extractUrlAt이 공유 — URL/선택이 같은 글자열을 만들게 한다.
pub fn appendRowUtf8(out: *std.ArrayList(u8), allocator: std.mem.Allocator, row_cells: []const types.Cell, from: usize, to: usize) !void {
    var c = from;
    while (c < to) : (c += 1) {
        const cell = row_cells[c];
        if (cell.continuation) continue;
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cell.codepoint, &buf) catch continue;
        try out.appendSlice(allocator, buf[0..n]);
        if (cell.combining) |cp| {
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
        self.selectionClear();
        return;
    }
    a.row -= n;
    h.row -= n;
}

pub fn absRowFromViewport(self: *const TerminalCore, viewport_row: u16) usize {
    // 절대 행 = 스크롤백 시작 기준. 뷰포트 첫 행은 sb_count - view_offset.
    return self.sb.count - @min(self.view_offset, self.sb.count) + viewport_row;
}

/// 정규화된 선택(start <= end). 없으면 null.
pub fn normalizedSelection(self: *const TerminalCore) ?struct { start: types.SelectionPoint, end: types.SelectionPoint } {
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
pub fn matchAtIgnoreCase(haystack: []const u21, needle: []const u21) bool {
    for (needle, 0..) |n, k| {
        if (foldCase(haystack[k]) != foldCase(n)) return false;
    }
    return true;
}
