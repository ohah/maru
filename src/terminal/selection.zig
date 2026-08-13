//! 선택/검색/URL — 마우스 선택·더블클릭 단어·검색 매치·OSC 8 및 휴리스틱 URL 추출.
//!
//! `TerminalCore`(core.zig)가 VT 파서 + 화면/스크롤백 storage + host-reply + 선택/검색을 한 struct에 섞은
//! 구조 위반(docs/project-rules.md "구조와 파일 분리")을 목적별 파일로 떼어낸 결과다. 여기는 "화면/스크롤백을
//! 읽어 좌표·텍스트를 산출하는" 상위 레이어다 — 의존 방향은 `selection → screen → types` 단방향(screen이
//! selection을 import하면 레이어 역전이라 금지). 각 함수는 `*TerminalCore`를 받는 free 함수다(필드 직접 접근 —
//! Zig는 필드 privacy가 없다; osc/parser/screen와 동형). 외부가 점-호출하는 pub API(selectionStart·selectWordAt·
//! findMatches·extractSelection 등)는 core.zig에 얇은 facade 메서드로 남고 본문만 여기 있다.
//!
//! 좌표계: 절대 행(abs) = 스크롤백 시작 기준 0..(sb.count+rows). `screen.absRow`/`absRowWrapped`(분할 S1)로 읽고,
//! `absRowFromViewport`로 뷰포트 행을 abs로 바꾼다. 선택 상태(selection_anchor/head/block)·link_store는
//! core 필드(방향 A — 필드는 평평하게 core 잔류). `invalidateSelection`/`shiftCoordsForEviction`는 screen/kitty가
//! 부르는 다리라 core 잔류(seam), 여기엔 그 선택 부분(`shiftSelectionForEviction`)만 둔다.
//!
//! 베이스: 더블클릭 단어·블록 선택은 iTerm2/Terminal.app 관례, URL 휴리스틱은 Maru 독립 설계(http(s) 스킴 +
//! 괄호 균형 다듬기), 대소문자 무시 검색은 Unicode simple case folding(width.zig와 같은 정책의 오프셋 블록만).
//! 단일 출처: docs/plans/terminal-core-decomposition.md §7.

const std = @import("std");
const core = @import("core.zig");
const types = @import("types.zig");
const screen = @import("screen.zig"); // 화면/스크롤백 읽기(absRow·ensureScrollbackRewrapped)

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

/// 경계용 공백 판정 — isBlankCell과 달리 **배경색을 보지 않는다**. 단어/URL 경계는 "보이는 글자가 공백인가"만
/// 따져야 하므로, bce/erase·상태줄·프롬프트가 배경색으로 칠한 공백(codepoint=' '이지만 style.background ≠
/// default)도 경계로 본다. continuation(wide 2번째 칸)은 공백이 아니다. isBlankCell의 배경 기본값 조건은 복사
/// trim 등 다른 용도라 그대로 둔다.
fn isBoundarySpace(cell: types.Cell) bool {
    return cell.codepoint == ' ' and !cell.continuation;
}

/// 단어 경계 셀인가 — 공백(isBoundarySpace, 배경 무관) 또는 separators 집합 멤버. URL 감지는 separators=&.{}라
/// 공백만 본다(`:`·`/`·`.`가 URL을 쪼개지 않게). 선택은 config 구분자를 넘긴다. **배경색 칠한 공백도 경계**라,
/// bce로 색칠된 행(상태줄/프롬프트/erase)에서 URL 뒤의 공백·텍스트가 URL에 빨려들어 가지 않는다.
fn isWordBoundaryCell(cell: types.Cell, separators: []const u21) bool {
    return isBoundarySpace(cell) or isWordSeparatorCell(cell, separators);
}

/// 절대-행 [start, end] 선형 범위를 현재 뷰포트 좌표로 클립한다(화면 밖이면 null). 선택
/// 하이라이트와 URL 밑줄이 같은 규칙을 쓰게 공유한다.
fn clipAbsSpanToViewport(self: *const TerminalCore, start: types.SelectionPoint, end: types.SelectionPoint, block: bool) ?types.SelectionSpan {
    const top_abs = self.screen.sb.count - @min(self.view_offset, self.screen.sb.count);
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
fn linkBoundsAt(self: *const TerminalCore, abs: usize, col: u16, id: u32) WordBounds {
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
        // wide glyph wrap이 남긴 trailing padding 빈칸(link=0)은 경계가 아니므로 건너뛴 마지막 셀로 잇는다
        // (wordBoundsAtImpl과 대칭 — OSC 8 링크의 wrap 밑줄이 토막나지 않게). 링크 일부인 공백(link==id)은 보존.
        var prev_last = prev.len;
        while (prev_last > 0 and isBoundarySpace(prev[prev_last - 1]) and prev[prev_last - 1].link != id) prev_last -= 1;
        if (prev_last == 0 or prev[prev_last - 1].link != id) break;
        start_row -= 1;
        start_col = @intCast(prev_last - 1);
    }
    var end_row = abs;
    var end_col: u16 = col;
    outer_right: while (true) {
        const cells_row = screen.absRow(self, end_row) orelse break;
        // trailing padding 빈칸(wide glyph wrap, link=0)은 건너뛴다 — link run이 끊기지 않게(왼쪽과 대칭).
        var content_end = cells_row.len;
        while (content_end > 0 and isBoundarySpace(cells_row[content_end - 1]) and cells_row[content_end - 1].link != id) content_end -= 1;
        while (end_col + 1 < content_end) {
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
/// TerminalCore.grapheme_store.items로, 셀의 grapheme_id가 가리키는 extra 코드포인트(악센트·VS16·NFD
/// 한글 V/T·키캡 base+VS16+U+20E3 등)를 모두 무손실로 복원한다(잘림 금지 — 설계 §3.2). store가 단일
/// 출처라 키캡 VS16 재주입 같은 보정이 불필요하다(원본 시퀀스가 그대로 담겨 있다).
fn appendRowUtf8(out: *std.ArrayList(u8), allocator: std.mem.Allocator, row_cells: []const types.Cell, graphemes: []const []const u21, from: usize, to: usize) !void {
    var c = from;
    while (c < to) : (c += 1) {
        const cell = row_cells[c];
        if (cell.continuation) continue;
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cell.codepoint, &buf) catch continue;
        try out.appendSlice(allocator, buf[0..n]);
        if (cell.grapheme_id != 0 and cell.grapheme_id <= graphemes.len) {
            for (graphemes[cell.grapheme_id - 1]) |cp| {
                const m = std.unicode.utf8Encode(cp, &buf) catch continue;
                try out.appendSlice(allocator, buf[0..m]);
            }
        }
    }
}

// ── 링크 자동 감지(URL·파일 경로) 분류 ─────────────────────────────────────────────────────────────
// 단일 출처: docs/link-detection.md. 베이스 = Ghostty references/ghostty/src/config/url.zig의 *동작*만(무엇을
// 링크로 보는가: 스킴 URL / 절대·dot-relative / bare-relative, 끝 문장부호·`:`·`.` 제외, 괄호 균형). maru는
// 런타임 의존성 0 정책으로 oniguruma 정규식을 안 쓰고(코드 표현도 복사 안 함 — clean-room), 공백-경계 토큰
// (wordBoundsAt) + 아래 순수 Zig 문자열 분류로 재구현한다. 공백 든 경로는 토큰 모델상 1차 미지원이고, bare
// 경로 오탐은 클릭 시 core.zig의 존재(stat) 게이트가 거른다(hover 밑줄은 stat 없이 휴리스틱만).

// 링크 도메인 타입(LinkKind/LinkScopes/LinkScope/ViewportLink)은 types.zig가 소유한다 — RenderSnapshot이
// ViewportLink를 실어야 하는데(원격 host가 해석한 링크) types→selection import는 순환이기 때문이다. 여기선
// 기존 호출자(selection.LinkKind 등)를 위해 재노출만 한다.
pub const LinkKind = types.LinkKind;
pub const LinkScopes = types.LinkScopes;
pub const LinkScope = types.LinkScope;
pub const ViewportLink = types.ViewportLink;
pub const link_scopes_none = types.link_scopes_none;
pub const link_scopes_web = types.link_scopes_web;
pub const link_scopes_full = types.link_scopes_full;

/// 토큰(공백 없는 글자열) 안 첫 링크의 [start, end) 바이트 범위 + 종류 + 그 매치를 만든 감지 종류.
pub const LinkSpan = struct { start: usize, end: usize, kind: LinkKind, scope: LinkScope };

/// web 외 추가 스킴(`://` 또는 `:` 형). 가장 이른 위치가 우선이라 목록 순서는 무관하다.
const extra_scheme_list = [_][]const u8{ "file://", "ssh://", "ftp://", "git://", "mailto:", "tel:", "news:", "magnet:" };

const utf8_ellipsis = "\xE2\x80\xA6"; // U+2026 HORIZONTAL ELLIPSIS
const ellipsis_codepoint: u21 = 0x2026;

/// 매치된 링크 span [start, end) 자체에 U+2026(`…`)이 있으면 원본이 화면 밖에서 잘린 것이다(터미널 폭·UI
/// 말줄임). span 밖의 말줄임표 — 스킴 앞(`…https://example.com/page`)이나 콤마 다음(`src/a.zig,…`) — 는 링크
/// 본문과 무관하므로 보지 않는다. 그래야 뒤따르는 온전한 URL/경로를 계속 감지한다(토큰 어딘가에 `…`가 있다는
/// 이유만으로 거부하면 회귀).
fn spanIsTruncated(word: []const u8, start: usize, end: usize) bool {
    return std.mem.indexOf(u8, word[start..end], utf8_ellipsis) != null;
}

/// 토큰 안에서 첫 링크의 범위+종류를 찾는다(없으면 null). 우선순위: 스킴 URL > 절대 > 홈 > dot-relative >
/// bare-relative. 스킴이 경로보다 먼저라 `http://h:8080`의 `:8080`은 포트지 줄번호가 아니다. 매치된 span이
/// U+2026으로 잘렸으면(spanIsTruncated) 원본 복원이 불가하므로 감지하지 않는다 — 원본 URI가 따로 있으면 OSC 8
/// 명시 링크가 우선 처리한다.
pub fn linkSpanInWord(word: []const u8, scopes: LinkScopes) ?LinkSpan {
    if (schemeUrlSpan(word, scopes)) |s| {
        if (spanIsTruncated(word, s.start, s.end)) return null;
        return .{ .start = s.start, .end = s.end, .kind = .url, .scope = s.scope };
    }
    if (filePathSpan(word, scopes)) |s| {
        if (spanIsTruncated(word, s.start, s.end)) return null;
        return .{ .start = s.start, .end = s.end, .kind = .file_path, .scope = s.scope };
    }
    return null;
}

/// 토큰 안 가장 이른 스킴부터 끝까지를 URL로 본다("dot.http://x"도 스킴부터). 끝의 문장 부호는 다듬되 균형
/// 잡힌 닫는 ')'는 URL 일부로 보존한다(Wikipedia ".../Foo_(bar)"). 스킴만 있고 본문이 없으면 null.
fn schemeUrlSpan(word: []const u8, scopes: LinkScopes) ?struct { start: usize, end: usize, scope: LinkScope } {
    var best: ?usize = null;
    var best_len: usize = 0;
    var best_scope: LinkScope = .web;
    if (scopes.web) {
        for ([_][]const u8{ "https://", "http://" }) |s| {
            if (std.mem.indexOf(u8, word, s)) |i| {
                if (best == null or i < best.?) {
                    best = i;
                    best_len = s.len;
                    best_scope = .web;
                    if (i == 0) break; // 토큰 시작 매치 — 더 이른 건 불가, 남은 스캔 생략
                }
            }
        }
    }
    // best가 토큰 시작(0)이면 추가 스킴 스캔(최대 8회 indexOf)을 통째로 건너뛴다 — 더 이른 매치가 없으므로.
    if (scopes.extra_schemes and (best == null or best.? != 0)) {
        for (extra_scheme_list) |s| {
            if (std.mem.indexOf(u8, word, s)) |i| {
                if (best == null or i < best.?) {
                    best = i;
                    best_len = s.len;
                    best_scope = .extra_schemes;
                    if (i == 0) break;
                }
            }
        }
    }
    const start = best orelse return null;
    const end = trimUrlTail(word, start);
    if (end <= start + best_len) return null; // 스킴만 있고 본문 없음
    return .{ .start = start, .end = end, .scope = best_scope };
}

/// URL 끝의 마무리 문장 부호를 다듬는다(균형 잡힌 닫는 ')'·']'는 보존). 반환은 [start, end)의 end.
/// 대괄호 균형은 IPv6 권위부(`http://[::1]`)와 경로의 `[...]`(`/x/[foo]`)가 마지막 ']'를 잃지 않게 한다.
fn trimUrlTail(word: []const u8, start: usize) usize {
    var open_parens: usize = 0;
    var open_brackets: usize = 0;
    for (word[start..]) |ch| {
        if (ch == '(') open_parens += 1;
        if (ch == '[') open_brackets += 1;
    }
    var end_idx = word.len;
    while (end_idx > start) : (end_idx -= 1) {
        const ch = word[end_idx - 1];
        if (ch == ')' and open_parens > 0) {
            open_parens -= 1; // 균형 잡힌 닫는 괄호는 URL의 일부 — 다듬지 않는다
            break;
        }
        if (ch == ']' and open_brackets > 0) {
            open_brackets -= 1; // 균형 잡힌 닫는 대괄호(IPv6 등)는 URL의 일부
            break;
        }
        if (ch == '.' or ch == ',' or ch == ')' or ch == ']' or ch == '>' or ch == ';' or ch == '\'' or ch == '"') continue;
        break;
    }
    return end_idx;
}

/// 토큰 시작이 파일 경로(절대/홈/dot-relative/bare-relative, 각 scope)면 그 범위. 경로는 URL과 달리 토큰
/// 시작에서만 본다. 끝은 trimPathTail로 다듬되 `:line[:col]` 접미는 보존한다.
fn filePathSpan(word: []const u8, scopes: LinkScopes) ?struct { start: usize, end: usize, scope: LinkScope } {
    if (word.len == 0) return null;
    // 어느 종류로 매치됐는지도 함께 돌려준다(원격 span 태그용). 판정 순서는 §감지 종류 표의 우선순위와 같다 —
    // `./x.zig`처럼 dot_relative와 bare_relative가 둘 다 참인 토큰은 더 구체적인 dot_relative로 태그한다.
    // 어느 하나라도 켜져 있으면 매치라는 기존 or 의미론은 그대로다(scope는 태그일 뿐 게이트가 아니다).
    const scope: LinkScope =
        if (scopes.absolute_path and word[0] == '/' and !std.mem.startsWith(u8, word, "//"))
            .absolute_path
        else if (scopes.home_path and std.mem.startsWith(u8, word, "~/"))
            .home_path
        else if (scopes.dot_relative and (std.mem.startsWith(u8, word, "./") or std.mem.startsWith(u8, word, "../")))
            .dot_relative
        else if (scopes.bare_relative and looksLikeBareRelative(word))
            .bare_relative
        else
            return null;
    const end = trimPathTail(word);
    if (end == 0) return null;
    return .{ .start = 0, .end = end, .scope = scope };
}

/// dot-prefix 없는 상대 경로(src/foo.zig)인지 — 오탐 억제: 슬래시 필수 + (콤마 전) 점 필수 + 첫 글자가 글자/
/// 숫자/밑줄/'.' + '$'·'//' 시작 금지. "foo/bar"(점 없음)·"$10/x"·"//foo"는 false. "./"·"../"는 dot_relative
/// 분기에서 이미 잡히므로 여기 도달 시 해당 아님.
fn looksLikeBareRelative(word: []const u8) bool {
    if (word.len == 0) return false;
    const c0 = word[0];
    if (c0 == '$') return false;
    if (std.mem.startsWith(u8, word, "//")) return false;
    if (!(std.ascii.isAlphanumeric(c0) or c0 == '_' or c0 == '.')) return false;
    const comma = std.mem.indexOfScalar(u8, word, ',') orelse word.len;
    const head = word[0..comma];
    const slash = std.mem.indexOfScalar(u8, head, '/') orelse return false; // 슬래시 필수
    if (std.mem.indexOfScalar(u8, head, '.') == null) return false; // 점 필수(파일스러움)
    // 첫 세그먼트(첫 '/' 전)는 글자/숫자/_/-/. 만 허용 — "foo~/x"(mid-word ~)·"a:b/x" 등 제외
    // (Ghostty 첫 세그 [\w][\w\-.]*와 같은 취지). ~ 는 home_path(~/)에서만 의미를 갖는다.
    for (head[0..slash]) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '.' or ch == '-')) return false;
    }
    return true;
}

/// 파일 경로 끝을 다듬는다. 콤마에서 끊고(다음 토큰), 끝의 문장 부호·매달린 ':'를 제거하되 균형 잡힌 ')'와
/// ":line[:col]" 접미(숫자)는 보존한다. 반환은 end(=다듬은 길이).
fn trimPathTail(word: []const u8) usize {
    var end = std.mem.indexOfScalar(u8, word, ',') orelse word.len;
    var open_parens: usize = 0;
    var open_brackets: usize = 0;
    for (word[0..end]) |ch| {
        if (ch == '(') open_parens += 1;
        if (ch == '[') open_brackets += 1;
    }
    while (end > 0) {
        const ch = word[end - 1];
        if (ch == ')' and open_parens > 0) {
            open_parens -= 1; // 균형 괄호 보존
            break;
        }
        if (ch == ']' and open_brackets > 0) {
            open_brackets -= 1; // 균형 대괄호 보존(/x/[foo] 등)
            break;
        }
        if (ch == '.' or ch == ')' or ch == ']' or ch == '>' or ch == ';' or ch == '\'' or ch == '"') {
            end -= 1;
            continue;
        }
        break;
    }
    // 매달린 ':'(뒤에 숫자 없음)만 제거 — "./Downloads:" → "./Downloads". ":42:10"은 끝이 숫자라 보존.
    while (end > 0 and word[end - 1] == ':') end -= 1;
    return end;
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
    if (row_cells.len == 0) return null; // 빈 행(전부 공백 → A2 trim으로 len 0, §11) = 단어 없음 — [c] 인덱싱 전 가드
    const c = @min(col, @as(u16, @intCast(row_cells.len -| 1)));
    if (isBoundarySpace(row_cells[c])) return null; // 공백 클릭 → 선택 없음(배경색 칠한 공백도 동일)
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
        // 이전 행은 soft-wrap이다. wide glyph(CJK·와이드 이모지)가 마지막 칸에 안 들어가 다음 행으로 밀릴 때
        // 직전 행 끝에 남는 padding 빈칸(screen.zig putCell)은 진짜 공백 경계가 아니라 wrap 패딩이므로, 그걸 건너뛴
        // 마지막 비공백 셀부터 잇는다(구분자는 진짜 경계라 안 건너뜀). 안 그러면 한글 든 링크가 wrap 시 클릭이 끊긴다.
        var prev_last = prev.len;
        while (prev_last > 0 and isBoundarySpace(prev[prev_last - 1])) prev_last -= 1;
        if (prev_last == 0 or isWordBoundaryCell(prev[prev_last - 1], separators)) break;
        start_row -= 1;
        start_col = @intCast(prev_last - 1);
    }

    // 오른쪽 경계: 대칭 — 행 끝에 닿으면 이 행이 soft-wrap일 때 다음 행으로 계속.
    var end_row = abs;
    var end_col: u16 = c;
    outer_right: while (true) {
        const cells_row = screen.absRow(self, end_row) orelse break;
        const row_wrapped = screen.absRowWrapped(self, end_row);
        // wrapped 행의 trailing padding 빈칸(wide glyph가 다음 행으로 밀리며 남긴 것)은 경계가 아니라 wrap 패딩 —
        // 행 content 끝으로 보고 다음 행과 잇는다(왼쪽 이음과 대칭).
        var content_end = cells_row.len;
        if (row_wrapped) {
            while (content_end > 0 and isBoundarySpace(cells_row[content_end - 1])) content_end -= 1;
        }
        while (end_col + 1 < content_end) {
            if (isWordBoundaryCell(cells_row[end_col + 1], separators)) break :outer_right;
            end_col += 1;
        }
        if (!row_wrapped) break;
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
    const last_abs = self.screen.sb.count + self.size.rows - 1;
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

// ── 링크 감지(Cmd+hover/클릭) ──────────────────────────────────────────────────────────────────────
// OSC 8 명시적 링크가 항상 우선이고(보이는 텍스트와 무관), 없으면 클릭 단어의 자동 감지 휴리스틱
// (linkSpanInWord — scopes로 web/스킴/경로 토글). urlAnchorAt/urlSpanAtAbs/extractUrlAt는 core.zig facade로
// 점-호출되고, wordIsUrl은 hover의 매-mouseMove 비용을 줄이는 alloc-없는 판정. OSC 8 URI는 self.linkUri(core
// 잔류 link_store). file_path 경로의 resolve/존재검증은 core.zig가 하고, 여긴 순수 분류만 한다(파일 I/O 없음).

/// Cmd+클릭/hover 위치가 링크면 그 run의 시작 셀 절대 좌표를 돌려준다(밑줄 anchor용, 할당 없음).
/// OSC 8 명시적 링크가 우선이고, 없으면 화면 글자의 자동 감지(scopes). 밑줄 범위는 종류(url/file)와 무관.
pub fn urlAnchorAt(self: *const TerminalCore, viewport_row: u16, col: u16, scopes: LinkScopes) ?types.SelectionPoint {
    const abs = screen.absRowFromViewport(self, viewport_row);
    const id = cellLinkAt(self, abs, col);
    if (id != 0) return linkBoundsAt(self, abs, col, id).start;
    if (!wordIsUrl(self, viewport_row, col, scopes)) return null;
    const bounds = wordBoundsAt(self, viewport_row, col) orelse return null;
    return bounds.start;
}

/// 절대 좌표 anchor에서 시작하는 URL 단어의 현재 뷰포트 밑줄 범위. 매 frame 호출돼 스크롤/
/// 출력/resize 후에도 현재 폭/위치에 맞게 클립된다(stale span OOB 차단).
pub fn urlSpanAtAbs(self: *const TerminalCore, anchor: types.SelectionPoint) ?types.SelectionSpan {
    const top_abs = self.screen.sb.count - @min(self.view_offset, self.screen.sb.count);
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

/// 추출한 링크: raw 텍스트(호출자 free) + 종류. file_path는 raw 경로 텍스트(`:line:col` 포함 가능)이고
/// resolve/존재검증은 core.zig facade(extractUrlAt)가 한다. url은 OSC 8 URI나 스킴 URL을 그대로 담는다.
pub const ExtractedLink = struct { text: []u8, kind: LinkKind };

/// Cmd+클릭 위치의 링크를 추출한다(없으면 null). 클릭 셀이 속한 비공백 run(soft-wrap 포함)을 모아
/// linkSpanInWord(scopes)로 분류한다. OSC 8 명시적 링크가 있으면 그 URI를 그대로(kind=url). 호출자가 free.
pub fn extractUrlAt(self: *const TerminalCore, allocator: std.mem.Allocator, viewport_row: u16, col: u16, scopes: LinkScopes) !?ExtractedLink {
    // OSC 8 명시적 링크가 우선 — 프로그램이 지정한 URI를 그대로 연다(보이는 텍스트와 무관).
    const link_id = cellLinkAt(self, screen.absRowFromViewport(self, viewport_row), col);
    if (link_id != 0) {
        const uri = self.linkUri(link_id) orelse return null;
        return .{ .text = try allocator.dupe(u8, uri), .kind = .url };
    }
    const bounds = wordBoundsAt(self, viewport_row, col) orelse return null;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var abs = bounds.start.row;
    while (abs <= bounds.end.row) : (abs += 1) {
        const row_cells = screen.absRow(self, abs) orelse break;
        const from: usize = if (abs == bounds.start.row) bounds.start.col else 0;
        var to: usize = if (abs == bounds.end.row) @min(@as(usize, bounds.end.col) + 1, row_cells.len) else row_cells.len;
        // wrapped 중간 행의 trailing padding 빈칸(wide glyph가 다음 행으로 밀리며 남긴 것)은 텍스트에서 제외 —
        // 이은 행 사이에 padding 공백이 끼지 않게(wordBoundsAt 이음과 일관). 마지막 행은 bounds.end.col로 이미 클립.
        if (abs != bounds.end.row and screen.absRowWrapped(self, abs)) {
            while (to > from and isBoundarySpace(row_cells[to - 1])) to -= 1;
        }
        try appendRowUtf8(&out, allocator, row_cells, self.grapheme_store.items, from, to);
    }
    const span = linkSpanInWord(out.items, scopes) orelse {
        out.deinit(allocator);
        return null;
    };
    const text = try allocator.dupe(u8, out.items[span.start..span.end]);
    out.deinit(allocator);
    return .{ .text = text, .kind = span.kind };
}

/// 클릭 셀이 속한 단어가 링크인지(할당 없이) 판정한다. hover의 매-mouseMove 비용을 줄이려 extractUrlAt의
/// alloc 없이 같은 분류만 한다(존재검증 stat은 안 함 — 클릭에서만). app 호출은 없어 core facade가 없지만,
/// core.zig 테스트가 `selection.wordIsUrl(&core, ...)`로 cross-file 호출하므로 pub(linkSpanInWord와 같은 이유).
pub fn wordIsUrl(self: *const TerminalCore, viewport_row: u16, col: u16, scopes: LinkScopes) bool {
    return wordLinkAt(self, viewport_row, col, scopes) != null;
}

/// `wordIsUrl`의 본체 — 판정 결과(종류 + 매치를 만든 감지 종류)까지 돌려준다. hover는 bool만 쓰지만(위 래퍼),
/// 원격 host가 방출할 span 목록(`collectViewportLinks`)은 kind/scope가 필요하다. **분류기를 하나로 유지**해
/// 로컬 hover와 원격 span이 같은 규칙을 쓰게 한다(둘이 갈리면 "밑줄 보이는 곳 ≠ 열리는 곳"이 된다).
const WordLink = struct { kind: LinkKind, scope: LinkScope };

fn wordLinkAt(self: *const TerminalCore, viewport_row: u16, col: u16, scopes: LinkScopes) ?WordLink {
    if (cellLinkAt(self, screen.absRowFromViewport(self, viewport_row), col) != 0) return .{ .kind = .url, .scope = .osc8 };
    const bounds = wordBoundsAt(self, viewport_row, col) orelse return null;
    // URL은 보통 한 단어라 짧은 스택 버퍼로 분류한다(스킴/경로 prefix는 토큰 앞이라 버퍼 안에 들어온다).
    var buf: [2048]u8 = undefined;
    var len: usize = 0;
    var overflowed = false;
    var overflow_ellipsis = false; // 버퍼에 못 담은 토큰 뒷부분(>2048B)에서 U+2026을 봤다
    var abs = bounds.start.row;
    outer: while (abs <= bounds.end.row) : (abs += 1) {
        const row_cells = screen.absRow(self, abs) orelse break;
        const from: usize = if (abs == bounds.start.row) bounds.start.col else 0;
        var to: usize = if (abs == bounds.end.row) @min(@as(usize, bounds.end.col) + 1, row_cells.len) else row_cells.len;
        // wrapped 중간 행의 trailing padding 빈칸은 텍스트에서 제외(extractUrlAt과 일관 — 판정 결과가 같게).
        if (abs != bounds.end.row and screen.absRowWrapped(self, abs)) {
            while (to > from and isBoundarySpace(row_cells[to - 1])) to -= 1;
        }
        var c = from;
        while (c < to) : (c += 1) {
            const cell = row_cells[c];
            if (cell.continuation) continue;
            // 버퍼가 찬 뒤에는 더 담지 않되, span 잘림 판정에 필요한 U+2026만 끝까지 살핀다(아래 주석).
            if (overflowed) {
                if (cell.codepoint == ellipsis_codepoint) {
                    overflow_ellipsis = true;
                    break :outer;
                }
                continue;
            }
            var enc: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cell.codepoint, &enc) catch continue;
            if (len + n > buf.len) {
                overflowed = true;
                if (cell.codepoint == ellipsis_codepoint) {
                    overflow_ellipsis = true;
                    break :outer;
                }
                continue;
            }
            @memcpy(buf[len .. len + n], enc[0..n]);
            len += n;
        }
    }
    const matched = linkSpanInWord(buf[0..len], scopes) orelse return null;
    // 2048B를 넘긴 토큰 뒷부분에 U+2026이 있으면 click 경로(extractUrlAt)는 전체 토큰을 보고 잘린 링크로
    // 거부한다(span이 토큰 끝까지 이어지므로 그 U+2026은 span 안). hover도 같게 거부해 "밑줄은 떠도 클릭하면
    // 안 열리는" 불일치를 막는다. 공백 없는 2048B 초과 토큰은 사실상 URL뿐이라 이 보수적 판정이 안전하다.
    if (overflow_ellipsis) return null;
    return .{ .kind = matched.kind, .scope = matched.scope };
}

/// 현재 뷰포트에서 보이는 링크를 모두 모은다(원격 host가 `link_spans` record로 방출할 목록의 단일 출처).
/// 각 항목의 span은 **뷰포트 상대 좌표**로 클립돼 있고(로컬 밑줄과 같은 `clipAbsSpanToViewport`), 밑줄 범위는
/// 토큰/링크 run 전체다(로컬 `urlSpanAtAbs`와 같은 규칙 — 종류와 무관).
///
/// OSC 8 명시 링크와 자동 감지를 **한 목록에** 담는다: screen wire의 run에는 셀 OSC 8 link id가 없어 원격 client는
/// 명시 링크도 볼 수 없기 때문이다(docs/link-detection.md §원격(host-backed) 세션). 호출자(host)는 `scopes`에
/// 최대 집합(`link_scopes_full`)을 넘기고, 켤지 말지는 span의 `scope`를 보고 client가 정한다.
///
/// 스캔은 토큰 단위로 건너뛰고(같은 토큰을 다시 분류하지 않음), soft-wrap으로 다음 행까지 이어진 링크는 이미
/// 처리한 끝 좌표를 기억해 중복 방출하지 않는다.
pub fn collectViewportLinks(
    self: *const TerminalCore,
    allocator: std.mem.Allocator,
    scopes: LinkScopes,
    out: *std.ArrayList(ViewportLink),
) !void {
    out.clearRetainingCapacity();
    var consumed: ?types.SelectionPoint = null; // 직전에 방출/판정한 run의 마지막 절대 좌표(중복 스캔 차단)
    var row: u16 = 0;
    while (row < self.size.rows) : (row += 1) {
        const abs = screen.absRowFromViewport(self, row);
        const row_cells = screen.absRow(self, abs) orelse continue;
        var col: u16 = 0;
        while (col < row_cells.len) {
            // 이전 행에서 이어진 run이 이 행까지 덮으면 그 끝 다음 칸부터 본다.
            if (consumed) |c| {
                if (abs < c.row or (abs == c.row and col <= c.col)) {
                    if (abs < c.row) break; // 이 행 전체가 이미 처리된 run 안
                    col = c.col + 1;
                    continue;
                }
            }
            if (isBoundarySpace(row_cells[col])) {
                col += 1;
                continue;
            }
            const link_id = row_cells[col].link;
            const bounds: WordBounds = if (link_id != 0)
                linkBoundsAt(self, abs, col, link_id)
            else
                wordBoundsAt(self, row, col) orelse {
                    col += 1;
                    continue;
                };
            consumed = bounds.end;
            const classified: ?WordLink = if (link_id != 0)
                .{ .kind = .url, .scope = .osc8 }
            else
                wordLinkAt(self, row, col, scopes);
            if (classified) |cl| {
                if (clipAbsSpanToViewport(self, bounds.start, bounds.end, false)) |span| {
                    try out.append(allocator, .{ .span = span, .kind = cl.kind, .scope = cl.scope });
                }
            }
            // 같은 행 안이면 run 끝 다음 칸, 다음 행으로 이어졌으면 이 행은 여기서 끝(위 consumed 가드가 이어받는다).
            if (bounds.end.row != abs) break;
            col = bounds.end.col + 1;
        }
    }
}

// ── 검색(Find) + 추출(복사) ───────────────────────────────────────────────────────────────────────
// findMatches는 스크롤백 Find의 단일 출처(코어 상태), extractSelection/Block은 클립보드 복사 텍스트를 만든다.
// 전부 core.zig facade로 점-호출된다.

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
    const total = self.screen.sb.count + self.size.rows;
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
/// hard 줄끝에서만 \n을 넣는다. 각 행은 뒤 빈칸을 trim한다(soft 행도 같다 — 아래 주석). 블록 모드면 직사각형 추출로 분기한다.
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
        // **어느 행이든** 뒤 빈칸을 잘라 복사한다 — 패딩이 텍스트로 들어가지 않게. soft-wrap 행도
        // 예외가 아니다: 폭을 넓히는 resize는 커서 줄을 reflow하지 않고 새 폭으로 pad하므로(screen.zig
        // §resize), `wrapped`인데 내용이 행 끝에 못 미치는 행이 생긴다. 그때 행 폭 전체를 읽으면
        // **아무도 쓰지 않은 공백**이 클립보드로 샌다.
        //
        // 대가를 안다: 진짜로 뒤가 공백인 채 wrap된 행("ab" + 공백 8칸에서 넘어간 줄)은 그 공백을
        // 잃는다. 두 규칙이 짝을 이뤄야 한다 — 커서 줄까지 항상 reflow하면 이 상태가 아예 안 생겨
        // 행 폭 전체를 읽어도 되지만, Maru는 커서 줄을 안 건드리는 쪽을 골랐으므로(위 이유) 추출이
        // trim하는 쪽으로 맞춰야 없는 문자가 안 생긴다. 흔한 쪽(줄바꿈된 텍스트 복사)을 지킨다.
        const to: usize = @max(from, @min(full_to, screen.trimmedLen(row_cells)));
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

// 화면을 지우면(ED 2) **스크롤백에서 이어지던 줄도 끊긴다**. 활성 화면의 wrap 표시만 지우면
// 스크롤백 마지막 행이 계속 "다음 줄로 이어짐"을 주장하고, 지운 뒤 새로 쓴 첫 줄이 그 줄의
// 연속으로 취급된다 — 그 줄에서 단어를 잡으면 스크롤백의 wrap 뭉치까지 통째로 선택된다.
//
// 모바일 복사에서 드러났다: 화면의 `copyme`를 길게 눌러 복사했더니 클립보드에 스크롤백의
// W 수천 자가 담겼다. 선택 **범위**(뷰포트로 잘린다)는 멀쩡해 보여서 화면만 봐서는 못 잡는다.
test "화면을 지운 뒤 쓴 줄은 스크롤백 wrap의 연속이 아니다" {
    const allocator = std.testing.allocator;
    var c = try core.TerminalCore.init(allocator, .{ .cols = 20, .rows = 6 });
    defer c.deinit();
    // 자동 줄바꿈으로 스크롤백을 만든다(개행이 아니라 wrap 이어야 한다 — 그게 이 결함의 조건).
    var i: usize = 0;
    while (i < 40) : (i += 1) try c.write("WWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWW");
    try std.testing.expect(c.screen.sb.count > 0);

    try c.write("\x1b[2J\x1b[H");
    try c.write("copyme rest");

    c.selectWordAt(0, 1, &.{});
    const text = (try c.extractSelection(allocator)) orelse return error.TestUnexpectedResult;
    defer allocator.free(text);
    try std.testing.expectEqualStrings("copyme", text);
}

// **0행을 0열부터 지우는 모든 ED 가 같아야 한다.** 처음엔 ED 2 만 고쳤는데 `ESC[H ESC[J`(홈 +
// ED 0)는 가장 흔한 지우기 관용구라 그대로 샜다(적대적 검증 2라운드에서 재서 잡았다).
test "홈에서의 ED 0·ED 1 도 스크롤백 wrap 을 끊는다" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "\x1b[H\x1b[J", "\x1b[H\x1b[0J", "\x1b[9;99H\x1b[1J" }) |seq| {
        var c = try core.TerminalCore.init(allocator, .{ .cols = 20, .rows = 6 });
        defer c.deinit();
        var i: usize = 0;
        while (i < 40) : (i += 1) try c.write("WWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWW");
        try c.write(seq);
        try c.write("\x1b[Hcopyme rest");
        c.selectWordAt(0, 1, &.{});
        const text = (try c.extractSelection(allocator)) orelse return error.TestUnexpectedResult;
        defer allocator.free(text);
        try std.testing.expectEqualStrings("copyme", text);
    }
}

// **지우기만이 아니다.** 0행을 빈 줄로 바꾸거나 통째로 덮는 연산도 이어짐을 끊어야 한다 —
// EL(줄 지우기)·DECALN·IL/SD(0행에 빈 줄)·DL(0행 삭제)이 전부 같은 자리다. 적대적 검증
// 3라운드에서 하나씩 재서 찾았다(ED 만 고쳤을 때 여섯 경로가 남아 있었다).
test "0행을 비우거나 덮는 연산도 스크롤백 wrap 을 끊는다" {
    const allocator = std.testing.allocator;
    const seqs = [_][]const u8{
        "\x1b[H\x1b[2K", // EL 2 — 줄 전체
        "\x1b[H\x1b[K", // EL 0 — 커서~끝(홈)
        "\x1b#8", // DECALN — 화면을 통째로 덮는다
        "\x1b[H\x1b[L", // IL — 0행에 빈 줄
        "\x1b[H\x1b[T", // SD — 아래로 스크롤
        "\x1b[H\x1b[M", // DL — 0행 삭제
    };
    for (seqs) |seq| {
        var c = try core.TerminalCore.init(allocator, .{ .cols = 20, .rows = 6 });
        defer c.deinit();
        var i: usize = 0;
        while (i < 40) : (i += 1) try c.write("WWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWW");
        try c.write(seq);
        try c.write("\x1b[Hcopyme rest");
        c.selectWordAt(0, 1, &.{});
        const text = (try c.extractSelection(allocator)) orelse return error.TestUnexpectedResult;
        defer allocator.free(text);
        try std.testing.expectEqualStrings("copyme", text);
    }
}

// 수정이 **정상 경우를 안 깨뜨리는지**. ED 없이 스크롤백에서 활성 화면으로 이어지는 줄은
// 그대로 한 논리 줄이어야 하고, alt screen 의 ED 는 주 화면 스크롤백을 안 건드려야 한다.
test "이어지던 줄은 그대로, alt 의 ED 는 주 화면과 무관" {
    const allocator = std.testing.allocator;
    {
        var c = try core.TerminalCore.init(allocator, .{ .cols = 10, .rows = 4 });
        defer c.deinit();
        try c.write("abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJ");
        c.selectWordAt(3, 1, &.{});
        const t = (try c.extractSelection(allocator)) orelse return error.TestUnexpectedResult;
        defer allocator.free(t);
        try std.testing.expectEqualStrings("abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJ", t);
    }
    {
        var c = try core.TerminalCore.init(allocator, .{ .cols = 10, .rows = 4 });
        defer c.deinit();
        try c.write("abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJ");
        const before = c.screen.sb.count;
        const wrapped_before = c.scrollbackRowWrapped(before - 1);
        try c.write("\x1b[?1049h\x1b[2J\x1b[H\x1b[?1049l");
        try std.testing.expectEqual(before, c.screen.sb.count);
        try std.testing.expectEqual(wrapped_before, c.scrollbackRowWrapped(c.screen.sb.count - 1));
    }
}

// host-backed Find의 좌표계 계약. `runtime_manager.findOp`는 요청받은 매치로 host 화면을 먼저 스크롤한 뒤
// 그 **스크롤된 화면 기준**으로 span을 계산해 응답한다. client는 그 스크롤을 delta로 받기 전이라, 응답 span을
// 그대로 그리면 좌표계가 다른 화면에 하이라이트를 찍는다. 그래서 client가 view_offset을 대조해 정합할 때만
// 적용한다(app_session.remoteFindSpansApplicable). 이 테스트는 그 대조가 왜 필요한지를 코어 수준에서 고정한다.
// **폭을 넓히면 커서 줄은 reflow하지 않는다**(위 §resize — 셸이 SIGWINCH로 다시 그린다). 그래서
// 그 줄의 행들은 옛 폭 내용을 가진 채 새 폭 행에 앉고, 남는 칸은 resize가 넣은 **패딩**이다.
// 이 행들도 `wrapped`라 추출이 행 폭 전체를 읽으면 **아무도 쓰지 않은 공백**이 클립보드에 들어간다.
// wrap 이어짐도 뒤 빈칸을 trim해 잇는다(대가는 아래 「알려진 대가」 테스트가 값으로 박아 둔다).
test "넓히는 resize 뒤 커서 줄을 복사해도 패딩이 안 낀다" {
    const allocator = std.testing.allocator;
    var c = try core.TerminalCore.init(allocator, .{ .cols = 10, .rows = 4 });
    defer c.deinit();
    const written = "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJ"; // 46자 = 10칸에서 자동 줄바꿈 5행
    try c.write(written);
    try c.resize(20, 4);

    c.selectWordAt(1, 1, &.{});
    const text = (try c.extractSelection(allocator)) orelse return error.TestUnexpectedResult;
    defer allocator.free(text);
    try std.testing.expectEqualStrings(written, text);
}

// **대가를 값으로 박아 둔다.** 진짜로 뒤가 공백인 채 wrap된 줄은 그 공백을 잃는다. 주석의
// 주장이 아니라 판정자로 남겨야, 나중에 이 줄을 되돌릴 사람이 무엇을 사는지 본다.
test "알려진 대가: 뒤가 공백인 채 wrap된 줄은 그 공백을 잃는다" {
    const allocator = std.testing.allocator;
    var c = try core.TerminalCore.init(allocator, .{ .cols = 10, .rows = 4 });
    defer c.deinit();
    try c.write("ab        cd"); // "ab"+공백 8칸으로 10칸을 채우고 wrap, 다음 행에 "cd"
    try std.testing.expect(c.screen.wrapped[0]);

    c.selectWordAt(0, 0, &.{}); // 단어 경계는 wrap을 타고 "cd"까지 간다(soft-wrap = 한 논리 줄)
    const text = (try c.extractSelection(allocator)) orelse return error.TestUnexpectedResult;
    defer allocator.free(text);
    try std.testing.expectEqualStrings("abcd", text); // 이 수정 전에는 "ab" + 공백 8칸 + "cd" 였다
}

test "find span은 scroll 후 좌표계라 스크롤 전 화면과 어긋난다(host-backed 대조의 근거)" {
    const allocator = std.testing.allocator;
    var c = try core.TerminalCore.init(allocator, .{ .cols = 20, .rows = 4 });
    defer c.deinit();
    try c.write("l0\r\nMARUFIND\r\nl2\r\nl3\r\nl4\r\nl5\r\nl6\r\nl7\r\nl8\r\nl9\r\nl10\r\nl11");

    // client가 "이번 프레임에" 들고 있는 화면 = 아직 스크롤 delta를 못 받은 상태(바닥).
    var before: [4][20]u21 = undefined;
    for (0..4) |r| {
        const row = c.viewportRow(@intCast(r));
        for (0..20) |i| before[r][i] = if (i < row.len) row[i].codepoint else ' ';
    }

    var matches: std.ArrayList(types.Match) = .empty;
    defer matches.deinit(allocator);
    try findMatches(&c, allocator, "MARUFIND", &matches);
    try std.testing.expectEqual(@as(usize, 1), matches.items.len);

    // runtime_manager.findOp와 같은 순서: host 화면을 먼저 스크롤하고(:1396) 그 뒤에 span을 계산해 응답에 싣는다(:1405).
    c.scrollToAbs(matches.items[0].start.row);
    const span = matchViewportSpan(&c, matches.items[0]) orelse return error.TestUnexpectedResult;

    // (1) 스크롤 후 host 화면에서는 span이 실제 검색어를 가리킨다.
    const after = c.viewportRow(span.start.row);
    for ("MARUFIND", 0..) |ch, i| {
        try std.testing.expectEqual(@as(u21, ch), after[span.start.col + i].codepoint);
    }

    // (2) 그런데 client가 이 프레임에 그리는 화면(before)의 같은 좌표는 전혀 다른 줄이다 → 엉뚱한 셀이 하이라이트된다.
    var mismatched = false;
    for ("MARUFIND", 0..) |ch, i| {
        if (before[span.start.row][span.start.col + i] != ch) mismatched = true;
    }
    try std.testing.expect(mismatched);

    // 대조군: 매치가 이미 보이는 화면 안이면 host가 스크롤하지 않으므로(findOp의 scrollToAbs가 no-op) 같은
    // 검사가 통과한다 — 위 (2)는 "스크롤이 끼어든 경우"에만 어긋난다는 뜻이다(항상 참인 단언이 아니다).
    var c2 = try core.TerminalCore.init(allocator, .{ .cols = 20, .rows = 4 });
    defer c2.deinit();
    try c2.write("l0\r\nMARUFIND\r\nl2");
    var view2: [4][20]u21 = undefined;
    for (0..4) |r| {
        const row = c2.viewportRow(@intCast(r));
        for (0..20) |i| view2[r][i] = if (i < row.len) row[i].codepoint else ' ';
    }
    var m2: std.ArrayList(types.Match) = .empty;
    defer m2.deinit(allocator);
    try findMatches(&c2, allocator, "MARUFIND", &m2);
    c2.scrollToAbs(m2.items[0].start.row);
    const span2 = matchViewportSpan(&c2, m2.items[0]) orelse return error.TestUnexpectedResult;
    for ("MARUFIND", 0..) |ch, i| {
        try std.testing.expectEqual(@as(u21, ch), view2[span2.start.row][span2.start.col + i]);
    }
}
