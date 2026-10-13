//! 입력 조합(`insertTextWithRange` — 문서 모델 §3.7 타이핑 보조 × §9.1 다중 커서)의 **순수 판정** — 커서마다 무엇을
//! 넣고(쌍 넣기·type-over·감싸기·평범한 삽입), 편집 뒤 caret 을 어디 두는가.
//!
//! 적용·undo·스크롤·IME 는 호출자(L4 `app_session/editor` 의 `insertTextWithRange`)가 한다. **IME 는 일부러 여기 없다** —
//! 재변환 범위 보정·직접 입력 추적(`DirectIMEState`)·조합 선택(`.inserted`·`.preserve_primary`)은 L4 상태를 읽는다
//! (이식 계획 §1.3 「갈라서 옮길 수 있으면 갈라서 옮긴다」). 그래서 caret 은 두 단계로 낸다: `baseCarets`(넣은 글자 뒤)
//! → 호출자의 IME 덮어쓰기 → `finishCarets`(쌍 가운데·감싼 글자 고르기). 순서는 옮기기 전과 같다.
//!
//! 이 폴더는 OS 를 부르지 않는다(`tests/boundary/editor_ops_sans_io.zig`).
const std = @import("std");
const delta = @import("../delta.zig");
const pairs = @import("../pairs.zig");
const selection = @import("../selection.zig");
const line_index = @import("../line_index.zig");
const language = @import("../language.zig");
const indent_guides = @import("../indent_guides.zig");
const literals = @import("../literals.zig");

const Change = delta.Change;
const Selection = selection.Selection;
const LineIndex = line_index.LineIndex;

/// 감싼 커서 — 감싼 글자를 고른 채 둔다(§3.7). 원래 선택이 거꾸로였는지도 함께 든다.
pub const Surrounded = struct { sel: usize, reversed: bool };

pub const Typing = struct {
    /// 문서 순서(입력 선택이 문서 순서다). 겹치면 `wellFormed` 가 거짓이다.
    changes: std.ArrayList(Change) = .empty,
    /// 쌍·감싸기 문자열(우리 소유 — 호출자의 `text` 와 달리 임시다).
    owned: std.ArrayList([]u8) = .empty,
    /// **커서마다 자기 첫 변경의 인덱스.** 감싸기는 커서 하나에 변경이 둘이라 「변경 i = 커서 i」로 짝지으면 둘째
    /// 커서부터 앞 커서의 닫는 괄호 뒤로 갔다(결함 5).
    first_change: std.ArrayList(usize) = .empty,
    /// type-over 로 지나간 자리 — **변경의 인덱스**로 적는다(오름차순). 정렬 전 인덱스로 적어 primary 가 뒤일 때 엉뚱한
    /// 커서가 넘어가던 것이 결함 4 다.
    skip_overs: std.ArrayList(usize) = .empty,
    surrounded: std.ArrayList(Surrounded) = .empty,

    pub fn deinit(self: *Typing, allocator: std.mem.Allocator) void {
        for (self.owned.items) |t| allocator.free(t);
        self.owned.deinit(allocator);
        self.changes.deinit(allocator);
        self.first_change.deinit(allocator);
        self.skip_overs.deinit(allocator);
        self.surrounded.deinit(allocator);
        self.* = .{};
    }

    /// **type-over 만 있었다** — 문서는 안 바뀐다(caret 만 한 칸씩 넘긴다, delta·undo 없음).
    pub fn onlySkips(self: Typing) bool {
        return self.changes.items.len == self.skip_overs.items.len;
    }

    /// 문서 순서·비겹침(`delta` 의 불변식). `mergeOverlapping` 이 선택 단계에서 합치므로 정상 경로에서는 참이지만, 걸러
    /// 두지 않으면 `apply` 가 `MalformedDelta` 로 거절해 사용자에게는 「타이핑이 안 먹는다」로 보인다.
    pub fn wellFormed(self: Typing) bool {
        for (self.changes.items, 0..) |c, i| {
            if (i > 0 and c.start < self.changes.items[i - 1].end) return false;
        }
        return true;
    }

    fn own(self: *Typing, allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
        const t = try allocator.dupe(u8, bytes);
        self.owned.append(allocator, t) catch |e| {
            allocator.free(t);
            return e;
        };
        return t;
    }
};

/// 타이핑의 언어 문맥(계획 editor-typing-rules TR2~TR4) — 호출자가 그 문법의 괄호(`bracketRuleFor().chars`)와 줄 색인, 구문 트리가 답한
/// 문자열·주석 조각을 준다. 닫는 괄호 내어쓰기·낱말 내어쓰기·따옴표 자동 닫기가 본다.
pub const Context = struct {
    lines: LineIndex,
    brackets: []const u8,
    /// 낱말 내어쓰기(TR3 — Ruby `end`·Python `else:` …)가 쓴다. 단위가 없으면 그 갈래를 안 탄다.
    grammar: language.Grammar = .none,
    unit: ?indent_guides.Unit = null,
    tab_width: u16 = 4,
    /// 구문 트리가 답한 문자열·주석 조각(TR4 — `literals.flatten`, 문서 절대 byte, 입력 커서들을 덮는 범위). `null` 이면 트리가 없거나
    /// 낡았다 — 문맥 없이(줄 스캐너로) 간다.
    literal_spans: ?[]const literals.Span = null,
};

/// 짝 여는 괄호를 거슬러 찾는 상한(byte) — 그 너머면 내어쓰지 않는다(적대 입력 §3.8: 한 줄짜리 거대 문서에서 타이핑마다 끝까지 걷지 않게).
pub const reindent_scan_limit: usize = 64 * 1024;

/// 닫는 괄호를 쳤을 때 그 줄을 **짝 여는 괄호가 있는 줄의 들여쓰기**로 맞출 자리 — caret `lo` 앞이 그 줄의 공백뿐일 때만. 바꿀 것이 없으면
/// (이미 같다·짝을 못 찾았다·괄호가 아니다) `null`. 짝은 거슬러 읽으며 같은 종류의 괄호 깊이로 찾는다. 구문 트리가 답했으면(TR4) 문자열·
/// 주석 안 괄호는 세지 않고, caret 이 문자열·주석 안이면(여러 줄 문자열·블록 주석의 공백 줄) 바꾸지 않는다 — 트리가 없으면 다 센다.
pub fn closerReindent(content: []const u8, r: Context, lo: usize, typed: u8) ?struct { line_start: usize, indent: []const u8 } {
    var open: ?u8 = null;
    var k: usize = 0;
    while (k + 1 < r.brackets.len) : (k += 2) if (r.brackets[k + 1] == typed) {
        open = r.brackets[k];
    };
    const o = open orelse return null;
    const line = r.lines.line(r.lines.lineAt(lo)) orelse return null;
    const head = content[line.start..lo];
    for (head) |b| if (b != ' ' and b != '\t') return null;
    if (r.literal_spans) |ls| if (literals.at(ls, content, lo) != .code) return null;
    // 짝을 거슬러 찾는다.
    const floor = line.start -| reindent_scan_limit;
    var depth: usize = 0;
    var i = line.start;
    var lk: usize = if (r.literal_spans) |ls| literals.countBefore(ls, line.start) else 0;
    const at: usize = while (i > floor) {
        i -= 1;
        // 트리가 문자열·주석으로 본 byte 는 건너뛴다 — 그 조각의 머리로 단번에.
        if (r.literal_spans) |ls| {
            while (lk > 0 and ls[lk - 1].start > i) lk -= 1;
            if (lk > 0 and i < ls[lk - 1].end) {
                i = ls[lk - 1].start;
                continue;
            }
        }
        const b = content[i];
        if (b == typed) {
            depth += 1;
        } else if (b == o) {
            if (depth == 0) break i;
            depth -= 1;
        }
    } else return null;
    const oline = r.lines.line(r.lines.lineAt(at)) orelse return null;
    const otext = content[oline.start..oline.contentEnd()];
    const indent = otext[0 .. otext.len - std.mem.trimStart(u8, otext, " \t").len];
    if (std.mem.eql(u8, indent, head)) return null;
    return .{ .line_start = line.start, .indent = indent };
}

/// 낱말 글자(ASCII 영숫자·`_`) — 이 폴더는 `std.ascii` 를 쓰지 않는다(sans-io 경계 `tests/boundary/editor_ops_sans_io.zig` 의 허용 목록 밖).
fn isWordByte(b: u8) bool {
    return (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or (b >= '0' and b <= '9') or b == '_';
}

/// 낱말 내어쓰기가 위쪽 내용 줄을 찾아 거슬러 가는 줄 수의 상한.
pub const keyword_scan_lines: usize = 4096;

/// 블록을 닫거나 잇는 낱말을 **다 쳤을 때** 그 줄을 한 단계 내어쓴다(계획 editor-typing-rules TR3) — Ruby `end`·`else`·`elsif`·`ensure`·
/// `rescue`(낱말 끝 글자)·`when `(뒤 공백), Python `else:`·`elif …:`·`except …:`·`finally:`(`:`). caret 뒤가 그 줄의 끝이고, 그 줄의 들여쓰기가
/// 위쪽 내용 줄의 들여쓰기 이상일 때만 — 이미 내어썼으면 그대로(VS Code Ruby `decreaseIndentPattern`·Python 언어 서버의 같은 동작).
/// 새 줄 머리(들여쓰기 + 이미 친 글자 + 친 글자)를 낸다 — 바꿀 것이 없으면 `null`.
pub fn keywordOutdent(allocator: std.mem.Allocator, content: []const u8, r: Context, lo: usize, typed: u8) !?struct { line_start: usize, text: []u8 } {
    const unit = r.unit orelse return null;
    if (r.grammar != .ruby and r.grammar != .python) return null;
    const line = r.lines.line(r.lines.lineAt(lo)) orelse return null;
    if (std.mem.trim(u8, content[lo..line.contentEnd()], " \t").len != 0) return null; // caret 뒤에 글자가 있다
    const head = content[line.start..lo];
    const indent = head[0 .. head.len - std.mem.trimStart(u8, head, " \t").len];
    if (indent.len == 0) return null;
    const code = head[indent.len..];
    const hit = switch (r.grammar) {
        .ruby => blk: {
            // 친 글자까지 붙인 낱말이 정확히 그것이다.
            var buf: [8]u8 = undefined;
            if (code.len + 1 > buf.len) break :blk false;
            @memcpy(buf[0..code.len], code);
            buf[code.len] = typed;
            const w = buf[0 .. code.len + 1];
            for ([_][]const u8{ "end", "else", "elsif", "ensure", "rescue", "when " }) |k| if (std.mem.eql(u8, w, k)) break :blk true;
            break :blk false;
        },
        .python => typed == ':' and blk: {
            var i: usize = 0;
            while (i < code.len and isWordByte(code[i])) i += 1;
            const w = code[0..i];
            for ([_][]const u8{ "else", "elif", "except", "finally" }) |k| if (std.mem.eql(u8, w, k)) break :blk true;
            break :blk false;
        },
        else => false,
    };
    if (!hit) return null;
    // 문자열·주석 안에서 친 낱말(파이썬 독스트링의 `else:`)은 블록이 아니다(TR4 — 트리가 답했을 때만).
    if (r.literal_spans) |ls| if (literals.at(ls, content, lo) != .code) return null;
    // 위쪽 내용 줄(공백뿐인 줄은 건너뛴다)의 들여쓰기 — 지금 줄이 그보다 얕으면 이미 내어썼다. 거슬러 가는 줄 수에 상한을 둔다(빈 줄이
    // 수십만인 적대 문서에서 낱말을 칠 때마다 끝까지 걷지 않게 — 넘으면 위 내용 줄이 없는 것으로 본다).
    var n = r.lines.lineAt(lo);
    const floor = n -| keyword_scan_lines;
    const above: []const u8 = while (n > floor) {
        n -= 1;
        const pl = r.lines.line(n) orelse break "";
        const pt = content[pl.start..pl.contentEnd()];
        const pi = pt.len - std.mem.trimStart(u8, pt, " \t").len;
        if (pi < pt.len) break pt[0..pi];
    } else "";
    if (indent_guides.visualColumn(indent, r.tab_width) < indent_guides.visualColumn(above, r.tab_width)) return null;
    // 한 단계 빼기 — 탭이면 하나, 공백이면 단위 폭까지.
    var keep = indent.len;
    if (indent[keep - 1] == '\t') {
        keep -= 1;
    } else {
        var k: usize = 0;
        while (keep > 0 and indent[keep - 1] == ' ' and k < unit.width) : (k += 1) keep -= 1;
    }
    const text = try std.mem.concat(allocator, u8, &.{ indent[0..keep], code, &[_]u8{typed} });
    return .{ .line_start = line.start, .text = text };
}

/// `sels` 는 문서 순서. **타이핑 보조는 한 글자 입력일 때만 본다**(§3.7) — `assist` 가 거짓이면(IME 재변환 등) 보지
/// 않는다. 붙여넣기·IME 확정은 여러 글자가 한 번에 오는데 그때 괄호를 닫으면 사용자가 넣지 않은 문자가 들어간다.
pub fn planTyping(allocator: std.mem.Allocator, content: []const u8, sels: []const Selection, text: []const u8, assist: bool, ctx: ?Context) !Typing {
    const aid: ?u8 = if (text.len == 1 and assist) text[0] else null;
    var t: Typing = .{};
    errdefer t.deinit(allocator);
    for (sels, 0..) |sel, index| {
        try t.first_change.append(allocator, t.changes.items.len);
        // 앞 커서의 변경 끝 — 닫는 괄호 내어쓰기가 그 앞까지 넓어지면 겹쳐 입력 전체가 거절된다(같은 공백 줄의 커서 둘 — TR2 적대적 3회차).
        const prev_end: usize = if (t.changes.items.len > 0) t.changes.items[t.changes.items.len - 1].end else 0;
        const lo = @min(sel.start(), content.len);
        const hi = @min(sel.end(), content.len);
        if (aid) |typed| {
            const before: ?u8 = if (lo > 0) content[lo - 1] else null;
            const after: ?u8 = if (hi < content.len) content[hi] else null;
            // 따옴표 자동 닫기는 caret 의 문맥을 본다(TR4 — 트리가 답하지 못하면 `unknown`, 종전대로).
            const lit: literals.Literal = if (ctx) |c| (if (c.literal_spans) |ls| literals.at(ls, content, lo) else .unknown) else .unknown;
            switch (pairs.decideIn(typed, hi > lo, before, after, lit)) {
                .insert_plain => if (hi == lo) if (ctx) |r| {
                    if (closerReindent(content, r, lo, typed)) |ri| if (ri.line_start >= prev_end) {
                        // **닫는 괄호를 짝 줄의 들여쓰기로**(계획 editor-typing-rules TR2) — 줄 머리부터 caret 까지(공백뿐)를 그 들여쓰기 + 괄호로.
                        const joined = try std.mem.concat(allocator, u8, &.{ ri.indent, &[_]u8{typed} });
                        t.owned.append(allocator, joined) catch |e| {
                            allocator.free(joined);
                            return e;
                        };
                        try t.changes.append(allocator, .{ .start = ri.line_start, .end = lo, .text = joined });
                        continue;
                    };
                    if (try keywordOutdent(allocator, content, r, lo, typed)) |ko| {
                        // **낱말을 다 쳤다** — 그 줄을 한 단계 내어쓴다(TR3). 줄 머리부터 caret 까지를 새 머리 + 친 글자로. 앞 커서의 변경과 겹치면
                        // 하지 않는다(같은 줄의 커서 둘).
                        if (ko.line_start >= prev_end) {
                            t.owned.append(allocator, ko.text) catch |e| {
                                allocator.free(ko.text);
                                return e;
                            };
                            try t.changes.append(allocator, .{ .start = ko.line_start, .end = lo, .text = ko.text });
                            continue;
                        }
                        allocator.free(ko.text);
                    }
                },
                .insert_pair => |pr| {
                    const owned = try t.own(allocator, &[_]u8{ pr.open, pr.close });
                    try t.changes.append(allocator, .{ .start = lo, .end = hi, .text = owned });
                    continue;
                },
                .skip_over => {
                    // **빈 변경을 넣어 자리를 지킨다** — caret 이 `inverse.changes` 와 인덱스로 맞는다.
                    try t.skip_overs.append(allocator, t.changes.items.len);
                    try t.changes.append(allocator, .{ .start = lo, .end = lo, .text = "" });
                    continue;
                },
                .surround => |pr| {
                    // **감싼다** — 앞뒤 두 변경으로 나눠 넣어 그 사이 내용(고른 것)을 살린다.
                    const o = try t.own(allocator, &[_]u8{pr.open});
                    const c = try t.own(allocator, &[_]u8{pr.close});
                    try t.changes.append(allocator, .{ .start = lo, .end = lo, .text = o });
                    try t.changes.append(allocator, .{ .start = hi, .end = hi, .text = c });
                    try t.surrounded.append(allocator, .{ .sel = index, .reversed = sel.isReversed() });
                    continue;
                },
            }
        }
        try t.changes.append(allocator, .{ .start = lo, .end = hi, .text = text });
    }
    return t;
}

/// **친 커서는 넣은 글자 뒤로 간다 — 매핑에 맡기지 않는다.** `mapOffset` 은 삽입 지점의 offset 을 밀지 않아 친 커서가
/// 친 글자 **앞**에 남는다(EDIT1·EDIT5). 역연산 `inverse` 의 각 범위가 편집 **후** 좌표로 새로 들어간 구간이라 그 끝이
/// 커서 자리다. **건너뛴 커서는 한 칸 넘어간다**(type-over — 빈 변경이라 `end` 가 제자리). `skip_overs` 가 오름차순이라
/// 한 번만 앞으로 밀며 본다(커서마다 목록을 훑으면 커서 수에 곱해진다 — MC3).
pub fn baseCarets(t: Typing, inverse: []const Change, out: []Selection) void {
    var skip_at: usize = 0;
    for (t.first_change.items, 0..) |ci, i| {
        if (i >= out.len or ci >= inverse.len) break;
        var at = inverse[ci].end;
        if (skip_at < t.skip_overs.items.len and t.skip_overs.items[skip_at] == ci) {
            at += 1;
            skip_at += 1;
        }
        out[i] = Selection.at(at);
    }
}

/// 마무리 — **자동으로 닫은 쌍은 caret 이 가운데다**(§3.7 — 「넣은 것 뒤」면 닫는 괄호 뒤에 서서 자동 닫기가 오히려
/// 방해가 된다). **감싼 커서는 감싼 글자를 고른 채 둔다**(§3.7, 2026-10-11 사용자 결정 — 방향도 지킨다). 자동 닫기
/// 표식이 설 자리(Backspace 가 그것만 함께 지운다)를 돌려준다 — 여럿이면 마지막. `replaced` 면(IME 재변환) 쌍 보정을 안 한다.
pub fn finishCarets(t: Typing, inverse: []const Change, replaced: bool, out: []Selection) ?usize {
    var auto_closed: ?usize = null;
    for (t.first_change.items, 0..) |ci, i| {
        if (i >= out.len or ci >= t.changes.items.len) break;
        const r = t.changes.items[ci];
        if (!replaced and r.text.len == 2 and r.start == r.end) {
            const p = pairs.pairFor(r.text[0]) orelse continue;
            if (p.close != r.text[1]) continue;
            out[i] = Selection.at(out[i].focus -| 1);
            auto_closed = out[i].focus;
        }
    }
    for (t.surrounded.items) |sur| {
        if (sur.sel >= out.len or sur.sel >= t.first_change.items.len) continue;
        const ci = t.first_change.items[sur.sel];
        if (ci + 1 >= inverse.len) continue;
        const inner_lo = inverse[ci].end; // 여는 문자 뒤
        const inner_hi = inverse[ci + 1].start; // 닫는 문자 앞
        out[sur.sel] = if (sur.reversed) Selection.fromPoints(inner_hi, inner_lo) else Selection.fromPoints(inner_lo, inner_hi);
    }
    return auto_closed;
}

// ── 순수 test — 결함 4·5 의 재현 조건과 caret 규칙 ─────────────────────────────────────────

const testing = std.testing;

/// 변경을 적용하고 역연산(편집 후 좌표의 새 구간)을 만든다 — `delta.apply` 의 `inverse` 와 같은 뜻.
fn applyWithInverse(allocator: std.mem.Allocator, content: []const u8, changes: []const Change, inverse: *std.ArrayList(Change)) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var at: usize = 0;
    for (changes) |c| {
        try out.appendSlice(allocator, content[at..c.start]);
        const s = out.items.len;
        try out.appendSlice(allocator, c.text);
        try inverse.append(allocator, .{ .start = s, .end = out.items.len, .text = "" });
        at = c.end;
    }
    try out.appendSlice(allocator, content[at..]);
    return out.toOwnedSlice(allocator);
}

fn typeInto(content: []const u8, sels: []const Selection, text: []const u8, out_sels: []Selection) ![]u8 {
    const a = testing.allocator;
    var t = try planTyping(a, content, sels, text, true, null);
    defer t.deinit(a);
    try testing.expect(t.wellFormed());
    var inverse: std.ArrayList(Change) = .empty;
    defer inverse.deinit(a);
    const out = try applyWithInverse(a, content, t.changes.items, &inverse);
    baseCarets(t, inverse.items, out_sels);
    _ = finishCarets(t, inverse.items, false, out_sels);
    return out;
}

test "결함 4 — 일부만 type-over 이고 primary 가 뒤여도 커서마다 제자리" {
    // 문서 순서: 1(넣는다), 3(`)` 앞 — 지나간다). primary 가 어디든 이 함수는 문서 순서만 본다.
    var out: [2]Selection = undefined;
    const text = try typeInto("a b)\n", &.{ Selection.at(1), Selection.at(3) }, ")", &out);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("a) b)\n", text);
    try testing.expectEqual(@as(usize, 2), out[0].focus);
    try testing.expectEqual(@as(usize, 5), out[1].focus);
}

test "결함 5 — 여러 커서 감싸기는 커서마다 감싼 글자를 고른 채, 방향도 지킨다" {
    var out: [2]Selection = undefined;
    const text = try typeInto("aa bb\n", &.{ Selection.fromPoints(0, 2), Selection.fromPoints(5, 3) }, "(", &out);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("(aa) (bb)\n", text);
    try testing.expectEqual(@as(usize, 1), out[0].start());
    try testing.expectEqual(@as(usize, 3), out[0].end());
    try testing.expect(!out[0].isReversed());
    try testing.expectEqual(@as(usize, 6), out[1].start());
    try testing.expectEqual(@as(usize, 8), out[1].end());
    try testing.expect(out[1].isReversed());
}

test "자동으로 닫은 쌍은 caret 이 가운데이고 표식을 돌려준다" {
    const a = testing.allocator;
    var t = try planTyping(a, "x\n", &.{Selection.at(1)}, "(", true, null);
    defer t.deinit(a);
    var inverse: std.ArrayList(Change) = .empty;
    defer inverse.deinit(a);
    const text = try applyWithInverse(a, "x\n", t.changes.items, &inverse);
    defer a.free(text);
    try testing.expectEqualStrings("x()\n", text);
    var out: [1]Selection = undefined;
    baseCarets(t, inverse.items, &out);
    try testing.expectEqual(@as(?usize, 2), finishCarets(t, inverse.items, false, &out));
    try testing.expectEqual(@as(usize, 2), out[0].focus);
}

test "type-over 만 있으면 문서는 안 바뀐다 · 여러 글자 입력은 보조를 타지 않는다" {
    const a = testing.allocator;
    var t = try planTyping(a, "()\n", &.{Selection.at(1)}, ")", true, null);
    defer t.deinit(a);
    try testing.expect(t.onlySkips());
    var t2 = try planTyping(a, "\n", &.{Selection.at(0)}, "((", true, null);
    defer t2.deinit(a);
    try testing.expectEqual(@as(usize, 1), t2.changes.items.len);
    try testing.expectEqualStrings("((", t2.changes.items[0].text);
    // 보조를 끄면(IME 재변환) 한 글자도 그대로 넣는다.
    var t3 = try planTyping(a, "\n", &.{Selection.at(0)}, "(", false, null);
    defer t3.deinit(a);
    try testing.expectEqualStrings("(", t3.changes.items[0].text);
}

test "INDB3 닫는 괄호 내어쓰기 — 앞이 공백뿐이면 짝 여는 괄호 줄의 들여쓰기로, 이미 같거나 글자 뒤·짝 없음·괄호 아님은 그대로 (계획 editor-typing-rules TR2)" {
    const allocator = std.testing.allocator;
    const Case = struct { src: []const u8, caret: usize, typed: u8, want: ?[]const u8 };
    const cases = [_]Case{
        .{ .src = "if (x) {\n  foo();\n  \n", .caret = 20, .typed = '}', .want = "" }, // `  |` → `}`
        .{ .src = "  a = [\n    1,\n    \n", .caret = 19, .typed = ']', .want = "  " },
        .{ .src = "f(\n  a,\n      \n", .caret = 14, .typed = ')', .want = "" },
        .{ .src = "{\n  {\n  }\n  \n", .caret = 12, .typed = '}', .want = "" }, // 안쪽 짝은 닫혔다 — 바깥 `{` 의 줄
        .{ .src = "{\n\n", .caret = 2, .typed = '}', .want = null }, // 이미 같다(빈 들여쓰기)
        .{ .src = "{\n  x\n", .caret = 5, .typed = '}', .want = null }, // 글자 뒤
        .{ .src = "\n  \n", .caret = 3, .typed = '}', .want = null }, // 짝이 없다
        .{ .src = "{\n  \n", .caret = 4, .typed = 'x', .want = null }, // 괄호가 아니다
    };
    for (cases) |k| {
        var lines = try line_index.build(allocator, k.src);
        defer lines.deinit();
        const got = closerReindent(k.src, .{ .lines = lines, .brackets = "()[]{}" }, k.caret, k.typed);
        if (k.want) |w| {
            try std.testing.expect(got != null);
            try std.testing.expectEqualStrings(w, got.?.indent);
        } else try std.testing.expect(got == null);
    }
}

test "INDB5 닫는 괄호 내어쓰기 × 커서 여럿 — 같은 공백 줄의 두 커서는 앞 것만 내어쓰고 뒤 것은 그 자리에 넣는다(겹쳐 거절되지 않는다), 다른 줄은 각자 (계획 editor-typing-rules TR2)" {
    const a = std.testing.allocator;
    {
        const content = "{\n    \n";
        var lines = try line_index.build(a, content);
        defer lines.deinit();
        var t = try planTyping(a, content, &.{ Selection.at(4), Selection.at(6) }, "}", true, .{ .lines = lines, .brackets = "()[]{}" });
        defer t.deinit(a);
        try std.testing.expect(t.wellFormed());
        try std.testing.expectEqual(@as(usize, 2), t.changes.items.len);
        try std.testing.expectEqual(@as(usize, 2), t.changes.items[0].start); // 앞 커서 — 줄 머리부터
        try std.testing.expectEqualStrings("}", t.changes.items[0].text);
        try std.testing.expectEqual(@as(usize, 6), t.changes.items[1].start); // 뒤 커서 — 그 자리에
    }
    {
        const content = "{\n  {\n    \n  \n";
        var lines = try line_index.build(a, content);
        defer lines.deinit();
        var t = try planTyping(a, content, &.{ Selection.at(10), Selection.at(14) }, "}", true, .{ .lines = lines, .brackets = "()[]{}" });
        defer t.deinit(a);
        try std.testing.expect(t.wellFormed());
        try std.testing.expectEqualStrings("  }", t.changes.items[0].text); // 안쪽 `{` 의 줄(두 칸)
        try std.testing.expectEqual(@as(usize, 6), t.changes.items[0].start);
    }
}

test "INDR4 낱말 내어쓰기 — Ruby end·else·when·…, Python else:·elif …:·except …:·finally: 를 다 치면 한 단계, 이미 얕으면·줄 뒤에 글자가 있으면·다른 문법은 그대로 (계획 editor-typing-rules TR3)" {
    const a = std.testing.allocator;
    const four: indent_guides.Unit = .{ .tabs = false, .width = 4 };
    const Case = struct { g: language.Grammar, src: []const u8, caret: usize, typed: u8, want: ?[]const u8 };
    const cases = [_]Case{
        .{ .g = .ruby, .src = "def f\n    x\n    en\n", .caret = 18, .typed = 'd', .want = "end" },
        .{ .g = .ruby, .src = "if a\n    x\n    els\n", .caret = 18, .typed = 'e', .want = "else" },
        .{ .g = .ruby, .src = "case a\n    when 1\n        x\n        when\n", .caret = 40, .typed = ' ', .want = "    when " },
        .{ .g = .python, .src = "if a:\n    x\n    else\n", .caret = 20, .typed = ':', .want = "else:" },
        .{ .g = .python, .src = "try:\n    x\n    except ValueError\n", .caret = 32, .typed = ':', .want = "except ValueError:" },
        .{ .g = .python, .src = "if a:\n    x\nelse\n", .caret = 16, .typed = ':', .want = null }, // 이미 내어썼다(들여쓰기 없음)
        .{ .g = .python, .src = "if a:\n        x\n    else\n", .caret = 24, .typed = ':', .want = null }, // 위 줄보다 얕다 — 이미 맞췄다
        .{ .g = .ruby, .src = "def f\n    en x\n", .caret = 12, .typed = 'd', .want = null }, // caret 뒤에 글자
        .{ .g = .ruby, .src = "def f\n    x\n    xen\n", .caret = 19, .typed = 'd', .want = null }, // 낱말이 아니다
        .{ .g = .typescript, .src = "if (a) {\n    x\n    en\n", .caret = 21, .typed = 'd', .want = null }, // 다른 문법
    };
    for (cases) |k| {
        var lines = try line_index.build(a, k.src);
        defer lines.deinit();
        const r: Context = .{ .lines = lines, .brackets = "()[]{}", .grammar = k.g, .unit = four, .tab_width = 4 };
        const got = try keywordOutdent(a, k.src, r, k.caret, k.typed);
        if (k.want) |w| {
            try std.testing.expect(got != null);
            defer a.free(got.?.text);
            try std.testing.expectEqualStrings(w, got.?.text);
        } else {
            if (got) |g| a.free(g.text);
            try std.testing.expect(got == null);
        }
    }
}

test "INDR6 낱말 내어쓰기 × 커서 여럿 — 같은 줄의 두 커서(들여쓰기 안·줄 끝)는 겹치지 않게 뒤 것을 그 자리에 넣는다 (계획 editor-typing-rules TR3, H21)" {
    const a = std.testing.allocator;
    const content = "def f\n    x\n    en\n";
    var lines = try line_index.build(a, content);
    defer lines.deinit();
    const r: Context = .{ .lines = lines, .brackets = "()[]{}", .grammar = .ruby, .unit = .{ .tabs = false, .width = 4 }, .tab_width = 4 };
    var t = try planTyping(a, content, &.{ Selection.at(14), Selection.at(18) }, "d", true, r);
    defer t.deinit(a);
    try std.testing.expect(t.wellFormed());
    try std.testing.expectEqual(@as(usize, 2), t.changes.items.len);
    try std.testing.expectEqual(@as(usize, 18), t.changes.items[1].start); // 뒤 커서는 그 자리에
}

test "INDL2 구문 트리 문맥 × 타이핑 — 문자열·주석 안 괄호는 짝 찾기에서 안 세고, 문자열·주석 안 caret 은 내어쓰지 않으며, 따옴표는 문자열 안에서 안 닫는다; 트리가 없으면 종전 (계획 editor-typing-rules TR4)" {
    const a = std.testing.allocator;
    const Case = struct { src: []const u8, spans: []const literals.Span, caret: usize, with: ?[]const u8, without: ?[]const u8 };
    const cases = [_]Case{
        // 위 줄 문자열 안 `{` 를 건너 바깥 `f() {` 줄로 — 트리가 없으면 그 `{` 가 짝이라(들여쓰기가 같다) 그대로.
        .{ .src = "f() {\n  s = \"{\";\n  \n", .spans = &.{.{ .start = 12, .end = 15, .kind = .string }}, .caret = 19, .with = "", .without = null },
        // 줄 주석 안 `{` 도 같다.
        .{ .src = "f() {\n  x(); // {\n  \n", .spans = &.{.{ .start = 13, .end = 17, .kind = .comment }}, .caret = 20, .with = "", .without = null },
        // caret 이 여러 줄 문자열 안 — 글자를 바꾸지 않는다(트리가 없으면 `f() {` 줄로 내어쓴다).
        .{ .src = "f() {\n  s = `\n  \n", .spans = &.{.{ .start = 12, .end = 17, .kind = .string }}, .caret = 16, .with = null, .without = "" },
    };
    for (cases) |k| {
        var lines = try line_index.build(a, k.src);
        defer lines.deinit();
        for ([_]?[]const literals.Span{ k.spans, null }, [_]?[]const u8{ k.with, k.without }) |spans, want| {
            const got = closerReindent(k.src, .{ .lines = lines, .brackets = "()[]{}", .literal_spans = spans }, k.caret, '}');
            if (want) |w| {
                try std.testing.expect(got != null);
                try std.testing.expectEqualStrings(w, got.?.indent);
            } else try std.testing.expect(got == null);
        }
    }
    // 파이썬 독스트링 안에서 친 `else:` 는 내어쓰지 않는다 — 트리가 없으면 내어쓴다.
    {
        const src = "if a:\n    x\n    \"\"\"\n    else\n    \"\"\"\n";
        var lines = try line_index.build(a, src);
        defer lines.deinit();
        const spans = [_]literals.Span{.{ .start = 16, .end = 36, .kind = .string }};
        const four: indent_guides.Unit = .{ .tabs = false, .width = 4 };
        try std.testing.expect(try keywordOutdent(a, src, .{ .lines = lines, .brackets = "()[]{}", .grammar = .python, .unit = four, .literal_spans = &spans }, 28, ':') == null);
        const plain = (try keywordOutdent(a, src, .{ .lines = lines, .brackets = "()[]{}", .grammar = .python, .unit = four }, 28, ':')) orelse return error.TestExpectedOutdent;
        defer a.free(plain.text);
        try std.testing.expectEqualStrings("else:", plain.text);
    }
    // 따옴표 — 문자열 안(`"a |␣b"`)에서는 평범하게, 트리가 없으면 쌍으로.
    {
        const src = "x = \"a  b\"\n";
        var lines = try line_index.build(a, src);
        defer lines.deinit();
        const spans = [_]literals.Span{.{ .start = 4, .end = 10, .kind = .string }};
        for ([_]?[]const literals.Span{ &spans, null }, [_][]const u8{ "'", "''" }) |ls, want| {
            var t = try planTyping(a, src, &.{Selection.at(7)}, "'", true, .{ .lines = lines, .brackets = "()[]{}", .literal_spans = ls });
            defer t.deinit(a);
            try std.testing.expectEqualStrings(want, t.changes.items[0].text);
        }
    }
}
