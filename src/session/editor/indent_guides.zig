//! 들여쓰기 안내선 — 줄마다 몇 단계인가 · 간격은 몇 열인가 · 어느 블록이 활성인가
//! ([시각 매핑](../../../docs/native-editor-visual-mapping.md) §5.1c).
//!
//! **들여쓰기 열은 접힘과 같은 함수다**(`fold.indentOf` — 공백 1열, 탭은 다음 탭스톱, 공백만인 줄은 없음). 두 곳이 따로 세면 접힘 화살표가
//! 서는 블록과 선이 가리키는 블록이 갈린다.
//!
//! 줄은 `src` 가 준다 — `count() usize` 와 `text(i) []const u8`(줄바꿈 제외) 두 메서드를 가진 값. 문서 줄 전체가 대상이고(접혀 숨은 줄도),
//! 화면 축으로 옮기는 것은 호출자의 일이다.
const std = @import("std");
const fold = @import("fold.zig");

/// 간격 추정이 보는 줄 수의 상한 — VS Code `guessIndentation` 과 같다.
pub const guess_line_limit: usize = 10_000;

/// 추정한 들여쓰기. **탭 파일은 폭을 들지 않는다** — 「탭이다」만 들어 설정(`editor.tab-width`)을 바꾸면 간격이 따라간다(§5.1c).
pub const Guess = struct {
    tabs: bool,
    /// 공백 파일의 한 단계 폭(2~8). `tabs` 면 뜻이 없다.
    spaces: u8,

    /// 안내선 간격(열).
    pub fn unit(self: Guess, tab_width: u16) u32 {
        return if (self.tabs) @max(tab_width, 1) else self.spaces;
    }
};

/// **파일의 들여쓰기를 추정한다** — VS Code `guessIndentation` 의 규칙 그대로(§5.1c). 앞 10,000 줄에서 탭으로 들여쓴 줄과 공백으로 들여쓴
/// 줄 중 많은 쪽을 고르고, 공백이면 이웃한 내용 줄끼리의 들여쓰기 차이를 세어 {2, 4, 6, 8, 3, 5, 7} 중 가장 많은 것을 쓴다(2 가 4 의 2/3
/// 이상이면 2). 정렬처럼 보이는 차이는 세지 않는다.
///
/// **기본값은 VS Code 의 것이다**(`insertSpaces` 참 · `tabSize` = 설정) — 동률일 때와 정렬 예외가 그 값을 읽는다. 우리 `Tab` 키는 탭 문자를
/// 넣지만 이 추정은 안내선 간격에만 쓰므로(§5.1c 「다른 점」 ②) VS Code 와 같은 선을 긋는 쪽을 따른다.
pub fn guess(src: anytype, default_tab: u16) Guess {
    return guessWith(src, default_tab, true);
}

/// `guess` 에 **언어별 기본**을 준다 — VS Code 는 몇 언어의 `insertSpaces` 기본을 바꾼다(`configurationDefaults`: `[go]` 거짓 · `[makefile]` 거짓 ·
/// `[yaml]` 참·폭 2 — 확장 `package.json` 원문). 그 기본이 **동률**(탭 줄 = 공백 줄)과 **정렬 예외**를 가른다. 우리 번들 grammar 중 해당하는 것은
/// Go 하나다(YAML·Makefile 은 grammar 없는 문서라 언어를 모른다 — §5.1c).
pub fn guessWith(src: anytype, default_tab: u16, default_spaces_mode: bool) Guess {
    const n = @min(src.count(), guess_line_limit);
    var tab_lines: usize = 0;
    var space_lines: usize = 0;
    var prev_text: []const u8 = "";
    var prev_indent: usize = 0;
    var counts = [_]usize{0} ** 9;
    const default_spaces: usize = @min(default_tab, 8);

    for (0..n) |ln| {
        const text = src.text(ln);
        var tabs: usize = 0;
        var spaces: usize = 0;
        var indent: ?usize = null;
        for (text, 0..) |ch, j| {
            if (ch == '\t') {
                tabs += 1;
            } else if (ch == ' ') {
                spaces += 1;
            } else {
                indent = j;
                break;
            }
        }
        const cur_indent = indent orelse continue; // 빈 줄·공백만인 줄은 안 센다
        if (tabs > 0) {
            tab_lines += 1;
        } else if (spaces > 1) {
            space_lines += 1;
        }
        const d = spacesDiff(prev_text, prev_indent, text, cur_indent);
        // 정렬 예외 — `const a = 1,` 아래 `      b = 2;` 같은 것은 들여쓰기 신호가 아니다. 다만 그 차이가 기본 폭과 같으면 들여쓰기로 센다(목록의
        // `- item` 아래 `  - item`). 건너뛸 때는 윗줄도 그대로 둔다(VS Code 와 같다).
        if (d.alignment and !(default_spaces_mode and d.diff == default_spaces)) continue;
        if (d.diff <= 8) counts[d.diff] += 1;
        prev_text = text;
        prev_indent = cur_indent;
    }

    var spaces_mode = default_spaces_mode; // 동률이면 기본(VS Code `insertSpaces`)
    if (tab_lines != space_lines) spaces_mode = tab_lines < space_lines;
    var size: usize = @max(default_spaces, 1);
    if (spaces_mode) {
        var score: usize = 0;
        // 순서는 **동률에서만** 뜻이 있다(더 큰 점수만 바꾸므로 앞 후보가 남는다). 2·4 동률은 아래 규칙이 어차피 2 로 정해 둘의 순서는 답을
        // 안 바꾼다(적대적 1회차 G5: 4 를 앞에 둬도 등가) — 뜻이 있는 동률은 2·3 같은 짝이다(`IG1`).
        for ([_]usize{ 2, 4, 6, 8, 3, 5, 7 }) |p| {
            if (counts[p] > score) {
                score = counts[p];
                size = p;
            }
        }
        // 2 가 4 의 2/3 이상이면 2 — 깊은 중첩이 4 칸 차이를 만드는 2 칸 파일(YAML 등)을 가른다. 정수로 옮겼다(`3·c2 ≥ 2·c4`).
        if (size == 4 and counts[4] > 0 and counts[2] > 0 and 3 * counts[2] >= 2 * counts[4]) size = 2;
    }
    return .{ .tabs = !spaces_mode, .spaces = @intCast(@min(size, 8)) };
}

const Diff = struct { diff: usize = 0, alignment: bool = false };

/// 두 줄의 들여쓰기 차이(VS Code `spacesDiff`). 공통 앞부분을 빼고 남은 공백·탭을 센다 — 한 줄에 공백과 탭이 섞였으면 0. 탭 수가 같으면 공백
/// 차이이고, 그때 **정렬처럼 보이는지**(윗줄이 쉼표로 끝나고 아래 줄의 첫 글자가 윗줄의 공백 뒤 글자 자리에 선다)를 본다. 탭 수가 다르면 공백
/// 차이가 탭 차이로 나누어떨어질 때만 그 몫.
fn spacesDiff(a: []const u8, a_len: usize, b: []const u8, b_len: usize) Diff {
    var i: usize = 0;
    while (i < a_len and i < b_len and a[i] == b[i]) : (i += 1) {}
    var a_sp: usize = 0;
    var a_tab: usize = 0;
    for (a[i..a_len]) |ch| {
        if (ch == ' ') a_sp += 1 else a_tab += 1;
    }
    var b_sp: usize = 0;
    var b_tab: usize = 0;
    for (b[i..b_len]) |ch| {
        if (ch == ' ') b_sp += 1 else b_tab += 1;
    }
    if (a_sp > 0 and a_tab > 0) return .{};
    if (b_sp > 0 and b_tab > 0) return .{};
    const tabs_diff = if (a_tab > b_tab) a_tab - b_tab else b_tab - a_tab;
    const sp_diff = if (a_sp > b_sp) a_sp - b_sp else b_sp - a_sp;
    if (tabs_diff == 0) {
        var out: Diff = .{ .diff = sp_diff };
        // 색인은 VS Code 그대로다(`bSpacesCnt` 를 윗줄의 자리로 읽는다 — 공통 앞부분이 0 인 흔한 경우에 「아래 줄 첫 글자의 열」이 된다).
        if (sp_diff > 0 and b_sp >= 1 and b_sp - 1 < a.len and b_sp < b.len) {
            if (b[b_sp] != ' ' and a[b_sp - 1] == ' ' and a.len > 0 and a[a.len - 1] == ',') out.alignment = true;
        }
        return out;
    }
    if (sp_diff % tabs_diff == 0) return .{ .diff = sp_diff / tabs_diff };
    return .{};
}

/// 내용 줄의 단계 — `ceil(들여쓰기 열 / 간격)`. 공백만인 줄이면 `null`.
fn contentLevel(text: []const u8, tab_width: u16, unit: u32) ?u32 {
    const col = fold.indentOf(text, tab_width) orelse return null;
    return (col + unit - 1) / unit;
}

/// **공백만인 줄의 단계**(VS Code `_getIndentLevelForWhitespaceLine`). `above`·`below` 는 가장 가까운 내용 줄의 들여쓰기 **열**(없으면 `null` —
/// 문서 처음·끝). 위가 얕으면 위 블록 안, 같으면 아래와 같이, 위가 깊으면 offSide 언어는 아래 블록과 같이·아니면 끝나는 블록 안.
pub fn whitespaceLevel(offside: bool, above: ?u32, below: ?u32, unit: u32) u32 {
    const a = above orelse return 0;
    const b = below orelse return 0;
    if (a < b) return 1 + a / unit;
    if (a == b) return (b + unit - 1) / unit;
    return if (offside) (b + unit - 1) / unit else 1 + b / unit;
}

/// 입력 묶음 — 규칙이 읽는 값들.
pub const Params = struct {
    tab_width: u16,
    /// 안내선 간격(열, ≥ 1) — `Guess.unit`.
    unit: u32,
    /// 공백만인 줄이 아래 블록 쪽인가(Python — §5.1c).
    offside: bool = false,
};

/// 문서 줄 `ln` 의 단계(한 줄만 묻는다 — 공백만이면 위·아래로 훑는다).
pub fn levelAt(src: anytype, p: Params, ln: usize) u32 {
    if (contentLevel(src.text(ln), p.tab_width, p.unit)) |lv| return lv;
    var above: ?u32 = null;
    var k = ln;
    while (k > 0) {
        k -= 1;
        if (fold.indentOf(src.text(k), p.tab_width)) |c| {
            above = c;
            break;
        }
    }
    var below: ?u32 = null;
    var j = ln + 1;
    while (j < src.count()) : (j += 1) {
        if (fold.indentOf(src.text(j), p.tab_width)) |c| {
            below = c;
            break;
        }
    }
    return whitespaceLevel(p.offside, above, below, p.unit);
}

/// **오름차순 문서 줄들의 단계**를 `out` 에 채운다(`out.len == lines.len`). 공백만인 줄이 이어지면 위·아래 내용 줄을 **한 번** 찾고 재사용한다 —
/// 줄마다 따로 훑으면 긴 빈 구간에서 곱으로 붙는다(VS Code `getLinesIndentGuides` 와 같은 캐시). 숨은 줄은 `lines` 에 없어도 탐색은 그 위를
/// 지난다(§5.1c 「접힘」).
pub fn levels(src: anytype, p: Params, lines: []const u32, out: []u16) void {
    std.debug.assert(out.len == lines.len);
    // 캐시: 마지막으로 찾은 위 내용 줄(그 줄 번호와 열)과 아래 내용 줄.
    var above_ln: ?usize = null;
    var above_col: ?u32 = null;
    var above_known = false;
    var below_ln: ?usize = null;
    var below_col: ?u32 = null;
    var below_known = false;
    var prev: ?usize = null;
    for (lines, 0..) |l32, i| {
        const ln: usize = l32;
        // 건너뛴 줄(접힘)이 있으면 위 캐시가 틀릴 수 있다 — 버린다.
        if (prev) |pv| {
            if (ln != pv + 1) above_known = false;
        }
        prev = ln;
        const text = src.text(ln);
        if (fold.indentOf(text, p.tab_width)) |col| {
            above_ln = ln;
            above_col = col;
            above_known = true;
            out[i] = @intCast(@min((col + p.unit - 1) / p.unit, std.math.maxInt(u16)));
            continue;
        }
        if (!above_known) {
            above_ln = null;
            above_col = null;
            var k = ln;
            while (k > 0) {
                k -= 1;
                if (fold.indentOf(src.text(k), p.tab_width)) |c| {
                    above_ln = k;
                    above_col = c;
                    break;
                }
            }
            above_known = true;
        }
        // `<=` 와 `<` 는 같다(적대적 1회차 G13: 등가) — 이 갈래는 공백만인 줄에서만 오고 `below_ln` 은 늘 내용 줄이라 지금 줄과 같을 수 없다.
        if (!below_known or (below_ln != null and below_ln.? <= ln)) {
            below_ln = null;
            below_col = null;
            var j = ln + 1;
            while (j < src.count()) : (j += 1) {
                if (fold.indentOf(src.text(j), p.tab_width)) |c| {
                    below_ln = j;
                    below_col = c;
                    break;
                }
            }
            below_known = true;
        }
        out[i] = @intCast(@min(whitespaceLevel(p.offside, above_col, below_col, p.unit), std.math.maxInt(u16)));
    }
}

/// **한 방향으로 한 줄씩 걸으며** 단계를 묻는다 — 공백만인 줄의 위·아래 내용 줄을 들고 가서, 긴 빈 구간을 줄마다 다시 훑지 않는다.
///
/// 활성 블록(`active`)은 caret 에서 위·아래로 한 줄씩 넓힌다. 처음엔 줄마다 `levelAt` 을 불러 공백만인 줄이 이어지면 **창 줄 수 × 빈 구간**
/// 만큼 훑었다 — 공백만인 줄 20 만 사이에 caret 을 두면 한 프레임이 81.8 ms 였다(ReleaseFast, 20 회 평균; 적대적 검증 2026-09-24). 방향마다
/// 「지나온 쪽의 가장 가까운 내용 줄」(걸으며 갱신)과 「가는 쪽의 가장 가까운 내용 줄」(닿으면 다시 찾는다)을 들면 훑기가 겹치지 않는다.
const Walker = struct {
    /// 위로 걷는가(줄이 줄어든다).
    up: bool,
    /// 지나온 쪽(위로 가면 아래, 아래로 가면 위)의 가장 가까운 내용 줄의 열. `behind_known` 이 거짓이면 아직 안 찾았다.
    behind: ?u32 = null,
    behind_known: bool = false,
    /// 가는 쪽의 가장 가까운 내용 줄과 그 열. 그 줄에 닿거나 지나면 다시 찾는다.
    ahead_ln: usize = 0,
    ahead: ?u32 = null,
    ahead_known: bool = false,

    fn level(self: *Walker, src: anytype, p: Params, ln: usize) u32 {
        if (fold.indentOf(src.text(ln), p.tab_width)) |col| {
            self.behind = col; // 다음 줄에서 보면 이 줄이 지나온 쪽의 가장 가까운 내용 줄이다
            self.behind_known = true;
            return (col + p.unit - 1) / p.unit;
        }
        if (!self.behind_known) {
            self.behind = scan(src, p, ln, !self.up);
            self.behind_known = true;
        }
        // `>=` 와 `>` 는 같다(적대적 4회차 W2: 등가) — 여기 오는 줄은 공백만인 줄이고 `ahead_ln` 은 내용 줄이라 둘이 같을 수 없다.
        const reached = if (self.up) self.ahead_ln >= ln else self.ahead_ln <= ln;
        if (!self.ahead_known or (self.ahead != null and reached)) {
            self.ahead = null;
            self.ahead_ln = ln;
            var k = ln;
            while (true) {
                if (self.up) {
                    if (k == 0) break;
                    k -= 1;
                } else {
                    k += 1;
                    if (k >= src.count()) break;
                }
                if (fold.indentOf(src.text(k), p.tab_width)) |c| {
                    self.ahead = c;
                    self.ahead_ln = k;
                    break;
                }
            }
            self.ahead_known = true;
        }
        const above = if (self.up) self.ahead else self.behind;
        const below = if (self.up) self.behind else self.ahead;
        return whitespaceLevel(p.offside, above, below, p.unit);
    }

    /// `ln` 에서 한쪽(`up` 이면 위)으로 가장 가까운 내용 줄의 열.
    fn scan(src: anytype, p: Params, ln: usize, up: bool) ?u32 {
        var k = ln;
        while (true) {
            if (up) {
                if (k == 0) return null;
                k -= 1;
            } else {
                k += 1;
                if (k >= src.count()) return null;
            }
            if (fold.indentOf(src.text(k), p.tab_width)) |c| return c;
        }
    }
};

/// 활성 블록 — 문서 줄 `[start, end]` 의 단계 `level` 선이 활성 색이다.
pub const Active = struct { start: u32, end: u32, level: u32 };

/// VS Code 가 이 한 줄 뒤에서 훑기를 멈추는 거리(`getActiveIndentGuide` 의 50,000).
pub const active_distance_limit: usize = 50_000;

/// **활성 블록**(VS Code `getActiveIndentGuide`, §5.1c). caret 줄의 단계 `d` 에서 시작해, 다음 줄이 `d + 1` 이면(스코프 머리) 아래 블록을, 윗줄이
/// `d + 1` 이면(스코프 끝) 위 블록을 고르고, 아니면 `d`(0 이면 없음). 위·아래로 단계가 그 이상인 줄까지 넓히되 **`[min_line, max_line]` 안에서**
/// 멈춘다(그려진 범위 — 첫 두 걸음은 그 밖이어도 본다, VS Code 와 같다).
pub fn active(src: anytype, p: Params, line: usize, min_line: usize, max_line: usize) ?Active {
    const count = src.count();
    if (line >= count) return null;
    var start: usize = 0;
    var end: usize = 0;
    var level: u32 = 0;
    var go_up = true;
    var go_down = true;
    var initial: u32 = 0;
    var distance: usize = 0;
    var up_walk: Walker = .{ .up = true };
    var down_walk: Walker = .{ .up = false };
    while (go_up or go_down) : (distance += 1) {
        const up_ok = distance <= line; // 위 줄이 문서 안인가
        const up: usize = if (up_ok) line - distance else 0;
        const down = line + distance;
        if (distance > 1 and (!up_ok or up < min_line)) go_up = false;
        if (distance > 1 and (down >= count or down > max_line)) go_down = false;
        if (distance > active_distance_limit) break;

        // 두 방향이 각자 한 줄씩 걷는다(거리 0 은 위 걸음이 묻는다) — 줄마다 `levelAt` 으로 훑으면 긴 빈 구간에서 곱으로 붙는다(`Walker` 주석).
        const up_level: ?u32 = if (go_up and up_ok) up_walk.level(src, p, up) else null;
        // 거리 0 의 아래 값은 안 쓰인다 — `distance > 0` 은 호출 하나를 아낄 뿐이다(적대적 4회차 W4: 등가 — caret 줄에서 걸음을 시작해도 줄 1 이
        // 쓰는 캐시가 같다: caret 줄이 내용이면 그 열, 공백이면 그 위의 가장 가까운 내용 줄).
        const down_level: ?u32 = if (go_down and down < count and distance > 0) down_walk.level(src, p, down) else null;

        if (distance == 0) {
            initial = up_level orelse 0;
            continue;
        }
        if (distance == 1) {
            if (down_level) |dl| if (initial + 1 == dl) {
                // 스코프 머리 — 자식 블록이 활성이다
                go_up = false;
                start = down;
                end = down;
                level = dl;
                continue;
            };
            if (up_level) |ul| if (ul == initial + 1) {
                // 스코프 끝 — 위와 대칭
                go_down = false;
                start = up;
                end = up;
                level = ul;
                continue;
            };
            start = line;
            end = line;
            level = initial;
            if (level == 0) return null;
        }
        if (go_up) {
            if (up_level != null and up_level.? >= level) start = up else go_up = false;
        }
        if (go_down) {
            if (down_level != null and down_level.? >= level) end = down else go_down = false;
        }
    }
    if (level == 0) return null;
    return .{ .start = @intCast(start), .end = @intCast(end), .level = level };
}

// ── 판정자 ────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// 판정자용 줄 묶음.
const Lines = struct {
    items: []const []const u8,
    pub fn count(self: Lines) usize {
        return self.items.len;
    }
    pub fn text(self: Lines, i: usize) []const u8 {
        return self.items[i];
    }
};

test "IG1 간격 추정 — 공백 2·4, 탭 파일, 2 가 4 의 2/3 이상이면 2, 정렬 예외, 줄이 없으면 기본 (§5.1c, VS Code guessIndentation)" {
    const two = Lines{ .items = &.{ "a {", "  b {", "    c;", "  }", "}" } };
    try testing.expectEqual(Guess{ .tabs = false, .spaces = 2 }, guess(two, 4));
    const four = Lines{ .items = &.{ "a {", "    b {", "        c;", "    }", "}" } };
    try testing.expectEqual(Guess{ .tabs = false, .spaces = 4 }, guess(four, 8));
    const tabs = Lines{ .items = &.{ "a {", "\tb {", "\t\tc;", "\t}", "}" } };
    try testing.expect(guess(tabs, 4).tabs);
    try testing.expectEqual(@as(u32, 3), guess(tabs, 4).unit(3)); // 탭 파일은 설정을 따른다
    // 2 칸 차이 넷 · 4 칸 차이 여섯(들어가고 나오는 차이를 다 센다) → 4 가 가장 많지만 `3·4 ≥ 2·6` 이라 2 — 정수 경계에 딱 선다
    const mixed = Lines{ .items = &.{ "a", "  b", "a", "  b", "a", "    c", "a", "    c", "a", "    c", "a" } };
    try testing.expectEqual(@as(u8, 2), guess(mixed, 4).spaces);
    // 2 칸 둘 · 4 칸 넷 → `3·2 < 2·4` 라 4
    const mostly4 = Lines{ .items = &.{ "a", "  b", "a", "    c", "a", "    c", "a" } };
    try testing.expectEqual(@as(u8, 4), guess(mostly4, 4).spaces);
    // 정렬 — `const a = 1,` 아래 여섯 칸은 안 센다. **세면 6 이 이기는 표본이라야 갈린다**: 정렬 줄 둘이 6 을 넷 만들고 진짜 들여쓰기는 2 가 둘이다
    const align_src = Lines{ .items = &.{ "const a = 1,", "      b = 2;", "const c = 3,", "      d = 4;", "f {", "  x;", "}" } };
    try testing.expectEqual(@as(u8, 2), guess(align_src, 4).spaces);
    // **섞인 들여쓰기는 차이로 안 센다**(탭과 공백이 한 줄에 — 적대적 1회차 G6). 4 칸 줄 셋에 섞인 줄·공백 줄 짝 다섯: 섞인 줄을 세면 2 칸이
    // 다섯 쌓여 2 가 된다
    var mixed_items: [16][]const u8 = undefined;
    var mi: usize = 0;
    for (0..3) |_| {
        mixed_items[mi] = "a";
        mixed_items[mi + 1] = "    b";
        mi += 2;
    }
    for (0..5) |_| {
        mixed_items[mi] = "\t  m";
        mixed_items[mi + 1] = "    n";
        mi += 2;
    }
    try testing.expectEqual(@as(u8, 4), guess(Lines{ .items = mixed_items[0..mi] }, 4).spaces);
    // **탭 수와 공백 수가 함께 다르면 공백 차이를 탭 차이로 나눈다**(`\t\t` 와 여덟 칸 → 4, 적대적 1회차 G7 — 나누지 않으면 8)
    const tabs_to_spaces = Lines{ .items = &.{ "\t\tx", "        y", "\t\tx", "        y", "\t\tx", "        y", "\t\tx", "        y", "        z" } };
    try testing.expectEqual(Guess{ .tabs = false, .spaces = 4 }, guess(tabs_to_spaces, 3));
    // **동률은 앞 후보** — 2 칸 둘 · 3 칸 둘이면 2(3 을 앞에 두면 3)
    const tie = Lines{ .items = &.{ "a", "  b", "a", "   c", "a" } };
    try testing.expectEqual(@as(u8, 2), guess(tie, 4).spaces);
    // 들여쓴 줄이 없으면 기본 폭(공백 모드 — VS Code 기본 `insertSpaces`)
    const flat = Lines{ .items = &.{ "a", "b" } };
    try testing.expectEqual(Guess{ .tabs = false, .spaces = 4 }, guess(flat, 4));
}

test "IG2 공백만인 줄의 단계 — 처음·끝 0, 위가 얕으면 위 블록 안, 같으면 아래와 같이, 위가 깊으면 offSide 에 따라 (§5.1c)" {
    try testing.expectEqual(@as(u32, 0), whitespaceLevel(false, null, 4, 4));
    try testing.expectEqual(@as(u32, 0), whitespaceLevel(false, 4, null, 4));
    try testing.expectEqual(@as(u32, 1), whitespaceLevel(false, 0, 4, 4)); // 위 블록 안: 1 + 0/4
    try testing.expectEqual(@as(u32, 2), whitespaceLevel(false, 4, 8, 4));
    try testing.expectEqual(@as(u32, 1), whitespaceLevel(false, 4, 4, 4)); // 같으면 ceil(4/4)
    // **간격의 배수가 아닌 열**이라야 올림·내림이 갈린다 — 위 표본은 전부 배수라 `ceil` 을 `floor` 로 바꿔도 초록이었다(적대적 1회차 G10)
    try testing.expectEqual(@as(u32, 2), whitespaceLevel(false, 6, 6, 4));
    try testing.expectEqual(@as(u32, 1), whitespaceLevel(false, 8, 0, 4)); // 끝나는 블록 안: 1 + 0/4
    try testing.expectEqual(@as(u32, 0), whitespaceLevel(true, 8, 0, 4)); // offSide: 아래 블록과 같이
    try testing.expectEqual(@as(u32, 2), whitespaceLevel(true, 8, 6, 4)); // offSide: ceil(6/4)
    try testing.expectEqual(@as(u32, 2), whitespaceLevel(false, 8, 6, 4)); // 1 + 6/4
}

test "IG3 줄마다 단계 — 내용 줄은 ceil, 빈 줄은 이웃으로, 탭은 탭스톱, 건너뛴 줄(접힘) 뒤에도 옳다 (§5.1c)" {
    const src = Lines{
        .items = &.{
            "fn f() {", //   0 → 0
            "    a;", //     1 → 1
            "", //           2 → 위 4 < 아래 6 → 1 + 4/4 = 2
            "      b;", //   3 → ceil(6/4) = 2
            "\tc;", //       4 → 탭 = 4 열 → 1
            "", //           5 → 위 4 > 아래 0 → 1 + 0 = 1
            "}", //          6 → 0
            "", //           7 → 아래 없음 → 0
        },
    };
    const p: Params = .{ .tab_width = 4, .unit = 4 };
    const all = [_]u32{ 0, 1, 2, 3, 4, 5, 6, 7 };
    var out: [8]u16 = undefined;
    levels(src, p, &all, &out);
    try testing.expectEqualSlices(u16, &.{ 0, 1, 2, 2, 1, 1, 0, 0 }, &out);
    // 한 줄씩 묻는 것과 같다(두 출처가 같은 답)
    for (all, 0..) |ln, i| try testing.expectEqual(@as(u32, out[i]), levelAt(src, p, ln));
    // **접혀 숨은 줄을 건너뛰면 위 캐시를 버린다** — 숨은 3 번(8 열)이 4 번 빈 줄의 진짜 위다. 2 번에서 찾아 둔 위(1 번, 2 열)를 그대로 쓰면
    // `2 < 4` 라 1 이 나온다(옳은 답은 `8 > 4` 라 1 + 4/4 = 2).
    const hid = Lines{ .items = &.{ "a {", "  x", "", "        y", "", "    z" } };
    const sparse = [_]u32{ 0, 2, 4, 5 };
    var out2: [4]u16 = undefined;
    levels(hid, p, &sparse, &out2);
    try testing.expectEqualSlices(u16, &.{ 0, 1, 2, 1 }, &out2);
    // **빈 줄이 이어지면** 한 줄씩 묻는 `levelAt` 도 위 내용 줄까지 올라간다 — 바로 윗줄만 보면 둘째 빈 줄의 위가 「없다」가 되어 0 이다(적대적
    // 1회차 G19: 표본의 빈 줄이 다 내용 줄 바로 아래라 초록이었다). `levelAt` 은 활성 블록이 쓴다.
    const two_blank = Lines{ .items = &.{ "a {", "    b", "", "", "    c", "}" } };
    const tb = [_]u32{ 0, 1, 2, 3, 4, 5 };
    var tb_out: [6]u16 = undefined;
    levels(two_blank, p, &tb, &tb_out);
    try testing.expectEqual(@as(u16, 1), tb_out[3]);
    try testing.expectEqual(@as(u32, 1), levelAt(two_blank, p, 3));
    // 간격 2 — 같은 문서가 더 촘촘해진다
    var out3: [8]u16 = undefined;
    levels(src, .{ .tab_width = 4, .unit = 2 }, &all, &out3);
    try testing.expectEqualSlices(u16, &.{ 0, 2, 3, 3, 2, 1, 0, 0 }, &out3);
}

test "IG4 활성 블록 — 몸통 안·머리·끝·단계 0·그려진 범위 (§5.1c, VS Code getActiveIndentGuide)" {
    const src = Lines{
        .items = &.{
            "a {", //        0 lv0
            "    b {", //    1 lv1
            "        c;", // 2 lv2
            "        d;", // 3 lv2
            "    }", //      4 lv1
            "    e;", //     5 lv1
            "}", //          6 lv0
            "z;", //         7 lv0
        },
    };
    const p: Params = .{ .tab_width = 4, .unit = 4 };
    // 몸통 안(2) — 단계 2 블록 [2,3]
    try testing.expectEqual(Active{ .start = 2, .end = 3, .level = 2 }, active(src, p, 2, 0, 7).?);
    // 스코프 머리(1 — 다음 줄이 한 단계 깊다) — 자식 블록
    try testing.expectEqual(Active{ .start = 2, .end = 3, .level = 2 }, active(src, p, 1, 0, 7).?);
    // 스코프 끝(4 — 윗줄이 한 단계 깊다) — 위 블록
    try testing.expectEqual(Active{ .start = 2, .end = 3, .level = 2 }, active(src, p, 4, 0, 7).?);
    // 단계 1 몸통(5) — [1,5]
    try testing.expectEqual(Active{ .start = 1, .end = 5, .level = 1 }, active(src, p, 5, 0, 7).?);
    // 단계 0 이고 이웃도 머리·끝이 아니다(7) — 없음
    try testing.expectEqual(@as(?Active, null), active(src, p, 7, 0, 7));
    // 그려진 범위 [3, 7] — 위로 3 에서 멈춘다(단계는 이어지지만 범위 밖이다)
    try testing.expectEqual(Active{ .start = 3, .end = 5, .level = 1 }, active(src, p, 5, 3, 7).?);
    // 범위 [5, 7] — 첫 걸음(거리 1)은 범위 밖(4)도 본다, VS Code 와 같다
    try testing.expectEqual(Active{ .start = 4, .end = 5, .level = 1 }, active(src, p, 5, 5, 7).?);
    try testing.expectEqual(@as(?Active, null), active(src, p, 99, 0, 7));
}

test "IG5 VS Code 와 대조 — monaco 0.56 을 실행해 뽑은 추정·단계·활성 블록과 문서 77 개가 줄마다 같다 (§5.1c)" {
    // **변이 검사는 규칙이 판정자와 맞는지만 본다 — VS Code 와 맞는지는 이 판정자가 본다.** 데이터는 monaco 를 Node 에서 돌려 뽑았다(파일의
    // `source`). 317 개로 한 번 대조해 불일치 0 을 확인했고(규칙 변이 둘을 넣으면 추정 5 · 단계 118 · 활성 402 건이 갈려 대조 자체가 살아 있음을
    // 확인했다), 그중 손 사례 17 과 무작위 60 을 남겼다.
    const Doc = struct { text: []const u8, offside: bool, tabs: bool, size: u8, levels: []const u16, active: []const ?[3]u32 };
    const Data = struct { source: []const u8, docs: []const Doc };
    const parsed = try std.json.parseFromSlice(Data, testing.allocator, @embedFile("testdata/indent_guides_vscode.json"), .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 77), parsed.value.docs.len);
    for (parsed.value.docs, 0..) |d, di| {
        errdefer std.debug.print("IG5 문서 {d}: {s}\n", .{ di, d.text });
        var lines_buf: [64][]const u8 = undefined;
        var nl: usize = 0;
        var it = std.mem.splitScalar(u8, d.text, '\n');
        while (it.next()) |l| : (nl += 1) lines_buf[nl] = l;
        const src = Lines{ .items = lines_buf[0..nl] };
        try testing.expectEqual(d.levels.len, nl); // 줄 수 — 끝 개행 뒤 빈 줄도 한 줄이다(양쪽이 같다)
        const g = guess(src, 4);
        try testing.expectEqual(d.tabs, g.tabs);
        if (!d.tabs) try testing.expectEqual(d.size, g.spaces);
        const p: Params = .{ .tab_width = 4, .unit = g.unit(4), .offside = d.offside };
        var all: [64]u32 = undefined;
        for (0..nl) |i| all[i] = @intCast(i);
        var lv: [64]u16 = undefined;
        levels(src, p, all[0..nl], lv[0..nl]);
        try testing.expectEqualSlices(u16, d.levels, lv[0..nl]);
        for (0..nl) |i| {
            const a = active(src, p, i, 0, nl - 1);
            if (d.active[i]) |w| {
                try testing.expectEqual(Active{ .start = w[0], .end = w[1], .level = w[2] }, a.?);
            } else try testing.expectEqual(@as(?Active, null), a);
        }
    }
}

test "IG6 VS Code 와 다른 점 — 공백 파일 속 탭 줄은 우리 탭 폭(설정)으로 센다 (§5.1c 「다른 점」 ②)" {
    // VS Code 는 추정한 폭(2)을 **탭 표시 폭**에도 써서 `\tc` 를 2 열로 그리고 단계 1 이다(monaco 0.56 실측: `[0,1,1,1,1,0,0]`). 우리는 탭을
    // 설정 폭(4)으로 **그리므로** 그 줄의 글자가 4 열에서 시작하고, 0·2 열의 선 둘이 그 글자와 맞는다 — 하나만 그으면 우리 화면에서 2 열 선이
    // 빠진다. 추정은 간격에만 쓰고 탭 폭은 바꾸지 않는다는 결정(§5.1c)의 귀결이다.
    const src = Lines{ .items = &.{ "a {", "  b", "  b", "  b", "\tc", "}", "" } };
    const g = guess(src, 4);
    try testing.expectEqual(Guess{ .tabs = false, .spaces = 2 }, g);
    var out: [7]u16 = undefined;
    levels(src, .{ .tab_width = 4, .unit = g.unit(4) }, &.{ 0, 1, 2, 3, 4, 5, 6 }, &out);
    try testing.expectEqualSlices(u16, &.{ 0, 1, 1, 1, 2, 0, 0 }, &out); // VS Code 는 4 번 줄이 1
}

test "IG7 긴 공백 구간에서도 활성 블록은 줄을 선형으로 읽는다 — 걸음 수로 잰다 (§5.1c, 적대적 검증 2026-09-24)" {
    // 처음엔 줄마다 `levelAt` 이 공백만인 구간을 끝까지 훑어 **창 줄 수 × 구간 길이**를 읽었다 — 공백만인 줄 20 만 사이에 caret 을 두면 한
    // 프레임이 81.8 ms(ReleaseFast, 20 회 평균)였다. 시간은 기기마다 달라(CI 가 2.8 배 느렸다) **읽은 줄 수**로 잰다: 지금은 구간을 방향마다
    // 한 번씩만 지나므로 문서 줄 수의 몇 배 안이고, 옛 방식이면 창 256 × 구간 2 만 ≈ 500 만이다.
    const Counting = struct {
        items: []const []const u8,
        reads: *usize,
        pub fn count(self: @This()) usize {
            return self.items.len;
        }
        pub fn text(self: @This(), i: usize) []const u8 {
            self.reads.* += 1;
            return self.items[i];
        }
    };
    const n: usize = 20_002;
    const items = try testing.allocator.alloc([]const u8, n);
    defer testing.allocator.free(items);
    for (items) |*l| l.* = "    ";
    items[0] = "a {";
    items[1] = "    b";
    items[n - 1] = "}";
    var reads: usize = 0;
    const src = Counting{ .items = items, .reads = &reads };
    const mid = n / 2;
    const a = active(src, .{ .tab_width = 4, .unit = 4 }, mid, mid - 100, mid + 155).?;
    try testing.expectEqual(@as(u32, 1), a.level);
    try testing.expectEqual(@as(u32, @intCast(mid - 100)), a.start); // 그려진 범위에서 멈췄다
    try testing.expect(reads <= 3 * n);
}

test "IG8 언어별 기본 — 기본이 탭 모드(VS Code `[go]`)면 동률은 탭, 들여쓴 줄이 없어도 탭 (§5.1c, monaco 0.56 실측)" {
    // 값은 monaco `detectIndentation(insertSpaces, 4)` 를 두 기본으로 돌려 뽑았다. 전역 기본(공백)만 쓰면 Go 파일의 동률이 공백 2 칸이 되어 선
    // 간격이 VS Code 와 갈린다(적대적 검증 2026-09-24 — 확장 `package.json` 의 `configurationDefaults` 를 열어 찾았다).
    const tie = Lines{ .items = &.{ "a", "  b", "\tc", "" } };
    try testing.expectEqual(Guess{ .tabs = false, .spaces = 2 }, guessWith(tie, 4, true));
    try testing.expect(guessWith(tie, 4, false).tabs);
    const tie2 = Lines{ .items = &.{ "a", "\tb", "  c", "  d", "\te", "" } };
    try testing.expectEqual(Guess{ .tabs = false, .spaces = 2 }, guessWith(tie2, 4, true));
    try testing.expect(guessWith(tie2, 4, false).tabs);
    const flat = Lines{ .items = &.{ "x", "" } };
    try testing.expect(!guessWith(flat, 4, true).tabs);
    try testing.expect(guessWith(flat, 4, false).tabs);
    // 공백 줄이 이기면 기본과 무관하다
    const four = Lines{ .items = &.{ "const a = 1,", "    b = 2;", "x", "    y", "" } };
    try testing.expectEqual(Guess{ .tabs = false, .spaces = 4 }, guessWith(four, 4, false));
}
