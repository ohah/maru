//! 커서 이동·추가·토글·낱말/줄 고르기([문서 모델](../../../../docs/native-editor-document-model.md) §3.2·§3.2b·§3.2c·§3.2d·
//! §3.9a·§3.9c)의 **순수 판정** — 어디로 가고 무엇을 고르며 어느 것이 primary 인가. 커서 저장·undo 묶음 끊기·화면 추종은
//! 호출자(L4 `app_session/editor` 의 `moveCarets`·`addCursorVertically`·`addNextOccurrence`·`toggleCursorAt`·
//! `selectWordOrLineAt`)가 한다.
//!
//! **화면과 구문 트리에 묻는 것은 `Oracle` 로 받는다.** 랩된 시각 행(렌더 스냅숏 — L3 `VisualRow`)·괄호 짝(tree-sitter)·
//! 열↔offset(화면과 같은 출처, §5.4)은 L4 가 답하고, 이 파일은 그 답으로 판정한다(이동 단계 4 — 갈라서 옮겼다).
//! 경계 자체는 옆 `../motion.zig` 가 소유한다.
//!
//! 이 폴더는 OS 를 부르지 않는다(`tests/boundary/editor_ops_sans_io.zig`).
const std = @import("std");
const line_index = @import("../line_index.zig");
const motion = @import("../motion.zig");
const occurrence = @import("../occurrence.zig");
const selection = @import("../selection.zig");

const LineIndex = line_index.LineIndex;
const Selection = selection.Selection;

pub const Motion = enum {
    char_left,
    char_right,
    word_left,
    word_right,
    /// smart home — 첫 글자와 줄 머리를 오간다. **언제나 논리 줄**이다(비교 뷰·병합 판이 쓴다).
    line_start,
    /// 논리 줄 끝. `^E` 가 이것이다(VS Code `CursorLineEnd`).
    line_end,
    /// `⌘←`·`Home` — **행 첫 글자 → 줄 첫 글자 → 줄 머리**로 넓어진다(VS Code `CursorHome`).
    /// 랩이 꺼졌거나 스냅숏이 없으면 `line_start` 와 **같은 답**이다.
    row_then_line_start,
    /// `⌘→`·`End` — **행 끝 → 줄 끝**으로 넓어진다(VS Code `CursorEnd`). 위의 거울.
    row_then_line_end,
    /// `^A` — **무조건 줄 머리**(0열). smart home 토글이 없다(VS Code `CursorLineStart`).
    hard_line_start,
    line_up,
    line_down,
    doc_start,
    doc_end,
    page_up,
    page_down,
    /// 괄호 짝으로 점프(§3.9c). 가로 이동 부류다 — goal 열을 버린다.
    bracket_match,
};

/// 행 경계 offset 을 **어느 행의 것으로 읽을지**(§4 이음매). 행 경계 offset 은 「앞 행의 끝」이기도 하고 「뒤 행의 머리」이기도
/// 한데 우리 모델에서는 같은 byte 하나라, **묻는 질문이 정한다**.
pub const SeamSide = enum {
    /// **뒤 행 머리**로 읽는다 — `⌘←` 가 "이 행의 첫 글자가 어디냐"를 물을 때.
    next_row,
    /// **앞 행 끝**으로 읽는다 — `⌘→` 가 "이미 이 행 끝이냐"를 물을 때.
    prev_row,
};

/// 화면·구문 트리에 묻는 질의(호출자가 답한다). 답을 모르면 `null` — 그때는 논리 줄로 떨어진다(**오늘과 같은 동작**이라
/// 잃는 것이 없다. 모를 때 추측해 두 번째 규칙을 만들지 않는다).
pub const Oracle = struct {
    ctx: *const anyopaque,
    /// 열↔offset — 화면과 같은 출처(§5.4 MUST).
    map: motion.ColumnMap,
    /// 한 페이지의 행 수(렌더가 굳힌 기하). 아직 안 그렸으면 1 — 0 이면 PageDown 이 죽은 키가 된다.
    page_rows: usize,
    /// caret 이 든 **시각 행**의 원본 byte 범위. 랩이 꺼졌거나 확실히 모르면 `null`.
    rowSpan: *const fn (ctx: *const anyopaque, focus: usize, seam: SeamSide) ?motion.VisualRow,
    /// 랩이 켜졌을 때 **한 시각 행** 위/아래로 옮긴 offset(목표 열을 행 축으로 되쓴다). 랩이 꺼졌거나 스냅숏 밖이면 `null`.
    visualMove: *const fn (ctx: *const anyopaque, focus: usize, goal: *selection.Goal, down: bool) ?usize,
    /// 괄호 짝(§3.9c — 강조 §5.1b 와 같은 출처). 짝이 없으면 `null`.
    bracketTarget: *const fn (ctx: *const anyopaque, from: usize) ?usize,
};

/// 한 커서를 옮긴 결과 offset. **선택을 어떻게 다룰지는 호출자가 정한다**(Shift 여부).
pub fn movedOffset(content: []const u8, lines: LineIndex, sel: Selection, how: Motion, goal: *selection.Goal, o: Oracle) usize {
    const focus = @min(sel.focus, content.len);
    const line_idx = lines.lineAt(focus);
    const line = lines.line(line_idx) orelse return focus;
    const map = o.map;

    return switch (how) {
        // **가로 이동은 목표 열을 버린다**(§3.2) — 남기면 다음 세로 이동이 편집 전 열로 튄다.
        .char_left => blk: {
            goal.* = .none;
            break :blk motion.prevCharBoundary(content, focus);
        },
        .char_right => blk: {
            goal.* = .none;
            break :blk motion.nextCharBoundary(content, focus);
        },
        .word_left => blk: {
            goal.* = .none;
            break :blk motion.wordLeft(content, focus);
        },
        .word_right => blk: {
            goal.* = .none;
            break :blk motion.wordRight(content, focus);
        },
        .line_start => blk: {
            goal.* = .none;
            break :blk motion.lineStartSmart(content, line, focus);
        },
        // **`^A` 는 토글이 없다** — `line_start` 와 일부러 갈린다(VS Code 가 `CursorHome` 과
        // `CursorLineStart` 를 다른 명령으로 둔 그 가름이다).
        .hard_line_start => blk: {
            goal.* = .none;
            break :blk motion.lineStart(line);
        },
        // **랩이 켜졌으면 행이 먼저다**(§3.2). 세로 이동(§4.1g)과 클릭이 이미 행을 보는데 가로 끝
        // 이동만 줄을 보던 어긋남을 닫는다. 행에서 멈추기만 하면 줄 머리로 갈 길이 없어지므로
        // **한 번 더 누르면 넓어진다** — 단계는 `motion.zig` 의 `lineStartScope` 가 소유한다.
        .row_then_line_start => blk: {
            goal.* = .none;
            if (o.rowSpan(o.ctx, focus, .next_row)) |row| {
                if (motion.lineStartScope(content, line, focus, row) == .row)
                    break :blk motion.rowStartSmart(content, line, row);
            }
            break :blk motion.lineStartSmart(content, line, focus);
        },
        .row_then_line_end => blk: {
            if (o.rowSpan(o.ctx, focus, .prev_row)) |row| {
                if (motion.lineEndScope(line, focus, row) == .row) {
                    goal.* = .none;
                    break :blk motion.rowEnd(line, row);
                }
            }
            // **줄 끝에 가도 목표를 「끝」으로 안 세운다**(VS Code `CursorEnd` 의 `sticky: false`).
            // 세우면 다음 ↓ 가 길이가 다른 줄에서도 계속 끝을 따라가 **원래 열로 못 돌아온다**.
            goal.* = .none;
            break :blk motion.lineEnd(line);
        },
        // **짝이 없으면 제자리다**(§3.9c) — 「없다」와 「여기다」는 다른 답이고, 없는데 옮기면
        // 사용자가 자기 자리를 잃는다.
        .bracket_match => blk: {
            goal.* = .none;
            // **선택의 앞쪽 끝에서 판정하고 커서로 접는다**(§3.9c — VS Code `selection.getStartPosition()`: [1,3] 과 [3,1] 이 같은 데로 간다).
            const from = @min(sel.start(), content.len);
            break :blk o.bracketTarget(o.ctx, from) orelse from;
        },
        .line_end => blk: {
            // **목표를 안 세운다** — 다음 세로 이동이 `goalAt` 으로 **그 자리의 열**을 잡는다.
            // VS Code 의 `CursorLineEnd`(`^E`)도 `leftoverVisibleColumns` 를 0 으로 둔다.
            goal.* = .none;
            break :blk motion.lineEnd(line);
        },
        .doc_start => blk: {
            goal.* = .none;
            break :blk 0;
        },
        .doc_end => blk: {
            goal.* = .none;
            break :blk content.len;
        },
        .line_up, .line_down, .page_up, .page_down => blk: {
            // **세로 이동은 목표 열을 유지한다.** 없으면 지금 자리에서 세운다.
            if (goal.* == .none) goal.* = motion.goalAt(content, line, focus, map);
            // **랩이 켜졌으면 시각 행이 먼저다**(§4.1g). 논리 줄로만 움직이면 ↓ 한 번이 화면에서
            // 서너 행을 건너뛴다 — 사용자가 누른 것과 화면이 안 맞는다. 스냅숏 밖으로 나가는
            // 이동은 `null`이라 아래 논리 줄 경로로 떨어지고, caret 노출이 스크롤을 따라오게 하므로
            // 다음 눌림에는 다시 시각 축으로 돈다.
            if (how == .line_up or how == .line_down) {
                if (o.visualMove(o.ctx, focus, goal, how == .line_down)) |v| break :blk v;
            }
            const step: usize = switch (how) {
                .line_up, .line_down => 1,
                // 페이지는 **보이는 행 수**만큼이다(호출자가 0 을 1 로 올려 준다 — 죽은 키 방지).
                else => o.page_rows,
            };
            const down = (how == .line_down or how == .page_down);
            const target = if (down)
                @min(line_idx + step, lines.lineCount() -| 1)
            else
                line_idx -| step;
            const dest = lines.line(target) orelse break :blk focus;
            break :blk motion.offsetForGoal(content, dest, goal.*, map);
        },
    };
}

/// 커서 집합 — 제품은 primary 를 단수 필드에 들므로 그 인덱스를 함께 낸다.
pub const Cursors = struct {
    items: []Selection,
    primary: usize,

    pub fn deinit(self: *Cursors, allocator: std.mem.Allocator) void {
        allocator.free(self.items);
        self.* = undefined;
    }
};

/// **커서를 옮긴다**(§3.2) — 커서가 여럿이면 **전부** 같은 단위로 옮긴다. `extend` 면 anchor 를 남겨 선택이 늘어난다(Shift).
/// `jumps` 는 괄호 점프를 커서 전부 한 번에 판정한 도착(`[primary, extras…]` 순서, §3.9c — 없으면 앞쪽 끝으로 접힌다).
///
/// `extras` 는 **제자리에서** 옮긴다(할당이 없다 — 이동은 OOM 으로 씹히면 안 되는 키다). 새 primary 를 돌려주고, 아무
/// 커서도 안 움직였으면 `null` 이다. 겹침 합치기는 호출자가 저장 뒤에 한다(`mergeCarets`).
pub fn moveAll(content: []const u8, lines: LineIndex, primary: Selection, extras: []Selection, how: Motion, extend: bool, jumps: ?[]const ?usize, o: Oracle) ?Selection {
    var moved_any = false;
    const next_primary = stepOne(content, lines, primary, how, extend, if (jumps) |j| j[0] else null, jumps != null, o, &moved_any);
    for (extras, 0..) |*extra, ei| {
        extra.* = stepOne(content, lines, extra.*, how, extend, if (jumps) |j| j[ei + 1] else null, jumps != null, o, &moved_any);
    }
    return if (moved_any) next_primary else null;
}

fn stepOne(content: []const u8, lines: LineIndex, sel: Selection, how: Motion, extend: bool, jump: ?usize, jumped: bool, o: Oracle, moved_any: *bool) Selection {
    var goal = sel.goal;
    const off = if (jumped) blk: {
        // 도착이 없으면 **앞쪽 끝으로 접힌다**(VS Code 가 `position` = 선택 시작을 돌려준다). 가로 이동이라 목표 열을 버린다.
        goal = .none;
        break :blk jump orelse @min(sel.start(), content.len);
    } else if (!extend and !sel.isEmpty() and (how == .char_left or how == .char_right)) blk: {
        // **선택이 있으면 맨 ←/→ 는 선택 끝으로 접는다**(§3.2 — 사용자 결정 2026-10-11, VS Code `CursorLeft`·`CursorRight`·
        // macOS 와 같다). `←` 는 앞쪽 끝, `→` 는 뒤쪽 끝 — focus 가 어느 쪽이든. 예전에는 focus 에서 한 글자를 더 갔다
        // ([2,4] 에서 → 가 5). 가로 이동이라 목표 열을 버린다.
        goal = .none;
        break :blk if (how == .char_left) @min(sel.start(), content.len) else @min(sel.end(), content.len);
    } else movedOffset(content, lines, sel, how, &goal, o);
    var next = if (extend)
        Selection.fromAnchorRange(sel.anchorLo(), sel.anchorHi(), off, sel.kind)
    else
        Selection.at(off);
    next.goal = goal;
    if (off != sel.focus or (!extend and !sel.isEmpty())) moved_any.* = true;
    return next;
}

/// 위/아래로 커서 추가(§3.2b) — 각 커서마다 한 줄 위(아래)에 **사본**을 더한다. `current` 는 `[primary, extras…]`.
///
/// **선택 모양이 유지된다**(anchor 와 focus 를 각자의 목표 열로 옮긴다). **못 가면 안 더한다**(문서 끝·처음에서 clamp 된
/// 자리는 원본과 같아 병합이 곧바로 지운다). **primary 는 새로 생긴 쪽으로 간다** — 위로 더하면 맨 위, 아래로 더하면 맨
/// 아래(화면 추종이 방금 늘어난 곳을 따라간다). 겹치면 합친다. 아무것도 못 더했으면 `null`.
pub fn planAddVertically(allocator: std.mem.Allocator, content: []const u8, lines: LineIndex, current: []const Selection, down: bool, o: Oracle) !?Cursors {
    var buf: std.ArrayList(Selection) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, current);

    // **사본은 원본 뒤에 모아 넣는다.** 원본을 먼저 다 훑고 나서 더해야 방금 만든 사본을 다시
    // 훑어 한 번에 여러 줄이 늘어나지 않는다(VSCode `addCursorUp` 도 원본 배열만 훑는다).
    const original_len = buf.items.len;
    var added: usize = 0;
    var i: usize = 0;
    while (i < original_len) : (i += 1) {
        if (original_len + added >= selection.max_cursors) break; // 상한(§3.2)
        const sel = buf.items[i];
        const how: Motion = if (down) .line_down else .line_up;
        // **anchor 와 focus 를 각자의 목표 열로 옮긴다** — 하나만 옮기면 선택이 찌그러진다. 세로 이동과 같은
        // `movedOffset` 이다(랩이면 시각 행, 아니면 논리 줄, 문서 끝은 clamp) — 그 규칙을 두 번째로 적으면 둘이 갈린다.
        var focus_goal = sel.goal;
        const new_focus = movedOffset(content, lines, sel, how, &focus_goal, o);
        const anchor_lo = sel.anchorLo();
        var anchor_goal = sel.anchor_goal;
        const new_anchor = if (anchor_lo == sel.focus)
            new_focus // caret 하나 — 두 번 재지 않는다
        else blk: {
            // anchor 를 focus 자리에 놓은 사본으로 물어본다 — 그 함수는 `focus` 만 옮긴다.
            var probe = Selection.at(anchor_lo);
            probe.goal = sel.anchor_goal;
            break :blk movedOffset(content, lines, probe, how, &anchor_goal, o);
        };
        // **제자리면 안 더한다** — 문서 끝에서 clamp 된 것이고, 더해도 병합이 지운다.
        if (new_focus == sel.focus and new_anchor == anchor_lo) continue;
        // `kind` 는 승계하지 않는다(§3.2b) — 한 줄 위에 같은 낱말이 있을 이유가 없다.
        var copy = Selection.fromPoints(new_anchor, new_focus);
        copy.goal = focus_goal; // 옮기며 세운 목표 열을 사본이 이어받는다(§3.2)
        copy.anchor_goal = anchor_goal;
        buf.append(allocator, copy) catch break;
        added += 1;
    }
    if (added == 0) return null;

    var primary_idx: usize = original_len;
    var k: usize = original_len + 1;
    while (k < buf.items.len) : (k += 1) {
        const better = if (down)
            buf.items[k].focus > buf.items[primary_idx].focus
        else
            buf.items[k].focus < buf.items[primary_idx].focus;
        if (better) primary_idx = k;
    }
    const merged = selection.mergeOverlapping(buf.items, primary_idx);
    return .{ .items = try allocator.dupe(Selection, buf.items[0..merged.len]), .primary = merged.primary };
}

/// `⌘D` 의 다음 자리(§3.2). `current` 는 `[primary(씨앗), extras…]`. 고른 것이 없거나 상한이면 호출자가 먼저 거른다.
pub const NextOccurrence = struct {
    /// 새 primary — 찾은 자리. `kind` 는 잡은 단위를 말한다(낱말 경계와 맞으면 `.word`, 아니면 `.match`).
    primary: Selection,
    /// 씨앗을 나머지로 내리는가. **caret 씨앗은 내리지 않는다** — 낱말이 그 caret 을 대신한다(VSCode 도 첫 `⌘D` 는
    /// 커서를 늘리지 않는다). 내리면 길이 0 커서가 화면에 안 보이는데 타이핑은 거기로도 간다.
    demote_seed: bool,
};

pub fn planNextOccurrence(allocator: std.mem.Allocator, content: []const u8, current: []const Selection) !?NextOccurrence {
    if (current.len == 0) return null;
    const seed = current[0];
    const buf = try allocator.dupe(Selection, current);
    defer allocator.free(buf);
    // **`nextOccurrence`는 문서 순서를 요구한다**(이미 고른 자리를 이분 탐색으로 거른다). 씨앗은 값으로 이미 떠 뒀다.
    std.mem.sort(Selection, buf, {}, struct {
        fn lessThan(_: void, a: Selection, b: Selection) bool {
            return a.start() < b.start();
        }
    }.lessThan);
    const seed_index = for (buf, 0..) |s, i| {
        if (s.start() == seed.start() and s.end() == seed.end()) break i;
    } else 0;
    const found = occurrence.nextOccurrence(content, buf, seed_index) orelse return null;
    // **`kind`는 잡은 단위를 말한다 — 짐작으로 `.word`를 붙이지 않는다.** 이어지는 드래그가 무엇으로 늘어날지를 정한다.
    const w = selection.wordRangeAt(content, found.start);
    const found_is_word = w.lo == found.start and w.hi == found.end;
    return .{
        .primary = Selection.fromAnchorRange(found.start, found.end, found.end, if (found_is_word) .word else .match),
        .demote_seed = seed.len() > 0,
    };
}

/// `⌥클릭` 토글(§3.2c) — `off` 를 품는 커서가 있으면 지우고, 없으면 그 자리에 더한다. `current` 는 `[primary, extras…]`
/// (비어 있지 않다). **「그 자리」는 점이 아니라 selection 이 품는 범위다.** 아무 일도 없으면 `null`(마지막 커서 · 상한).
///
/// primary: 더하면 **새로 찍은 커서**(§3.2), primary 를 지우면 **남은 것 중 앞의 것**이 잇는다(제품은 primary 를 단수
/// 필드에 든다), 다른 커서를 지우면 **그대로**다(결함 15).
pub fn planToggle(allocator: std.mem.Allocator, current: []const Selection, off: usize) !?Cursors {
    if (current.len == 0) return null;
    // **primary 를 꼬리표로 들고 정렬한다** — 정렬이 자리를 옮긴다.
    const Tagged = struct { sel: Selection, primary: bool };
    const tagged = try allocator.alloc(Tagged, current.len);
    defer allocator.free(tagged);
    for (current, tagged, 0..) |sel, *t, i| t.* = .{ .sel = sel, .primary = i == 0 };
    // **문서 순서로 세운 뒤 찾는다.** 배열 순서(primary 가 맨 앞)로 「앞의 것」을 고르면 **화면에서 뒤에 있는 커서**가
    // primary 가 된다(`OPT2`).
    std.mem.sort(Tagged, tagged, {}, struct {
        fn lt(_: void, a: Tagged, b: Tagged) bool {
            return a.sel.start() < b.sel.start();
        }
    }.lt);
    var primary_at: usize = 0;
    var hit: ?usize = null;
    for (tagged, 0..) |t, i| {
        if (t.primary) primary_at = i;
        if (hit == null and off >= t.sel.start() and off <= t.sel.end()) hit = i;
    }

    var buf: std.ArrayList(Selection) = .empty;
    errdefer buf.deinit(allocator);
    try buf.ensureTotalCapacity(allocator, tagged.len + 1);
    for (tagged) |t| buf.appendAssumeCapacity(t.sel);
    if (hit) |i| {
        // **커서가 하나뿐이면 아무 일도 안 한다**(§3.2c) — 지우면 caret 이 사라진다.
        if (buf.items.len == 1) {
            buf.deinit(allocator);
            return null;
        }
        _ = buf.orderedRemove(i);
        const new_primary: usize = if (i == primary_at)
            (if (i == 0) 0 else i - 1)
        else if (primary_at > i) primary_at - 1 else primary_at;
        return .{ .items = try buf.toOwnedSlice(allocator), .primary = new_primary };
    }
    if (buf.items.len >= selection.max_cursors) { // 상한(§3.2) — 조용히 멈춘다
        buf.deinit(allocator);
        return null;
    }
    buf.appendAssumeCapacity(Selection.at(off));
    const merged = selection.mergeOverlapping(buf.items, buf.items.len - 1);
    buf.shrinkRetainingCapacity(merged.len);
    return .{ .items = try buf.toOwnedSlice(allocator), .primary = merged.primary };
}

/// 더블·트리플 클릭이 고르는 범위(§3.2) — 낱말, 또는 줄 전체(**개행은 뺀다** — 붙여넣기가 줄바꿈을 하나 더 만들지 않게).
/// **빈 범위면 `.simple`** — `fromAnchorRange` 가 `(kind == .simple) == (lo == hi)` 를 단언한다(빈 줄 트리플클릭).
pub fn wordOrLineRange(content: []const u8, lines: LineIndex, off: usize, whole_line: bool) ?struct { lo: usize, hi: usize, kind: selection.AnchorKind } {
    var lo: usize = undefined;
    var hi: usize = undefined;
    var kind: selection.AnchorKind = undefined;
    if (whole_line) {
        const li = lines.lineAt(@min(off, lines.byteLen()));
        const line = lines.line(li) orelse return null;
        lo = line.start;
        hi = line.contentEnd();
        kind = .line;
    } else {
        const w = selection.wordRangeAt(content, off);
        lo = w.lo;
        hi = w.hi;
        kind = .word;
    }
    return .{ .lo = lo, .hi = hi, .kind = if (lo == hi) .simple else kind };
}

/// 잡은 단위로 늘린 뒤의 `focus`. **드래그 확장과 `⌥더블/트리플클릭`이 이것 하나를 쓴다**(§3.2d) — 사용자에겐 둘이 같은
/// "늘리기"라, 다른 낱말을 잡으면 그 차이를 설명할 수 없다.
pub fn widenedFocus(content: []const u8, lines: LineIndex, sel: Selection, off: usize) usize {
    return switch (sel.kind) {
        // `.match`(일치로 잡은 범위)는 잡은 단위가 없으므로 글자 단위로 는다 — `.simple`과 같다.
        .simple, .match => off,
        .word => blk: {
            const w = selection.wordRangeAt(content, off);
            // 앞으로 끌면 그 단어의 **끝**, 뒤로 끌면 **시작**까지 삼킨다.
            break :blk if (off >= sel.anchorHi()) w.hi else w.lo;
        },
        .line => blk: {
            // `@min` 은 옮겨 온 기존 방어다(`off` 는 히트테스트가 낸 것이라 늘 그 안이다).
            const li = lines.lineAt(@min(off, lines.byteLen()));
            const line = lines.line(li) orelse break :blk off;
            break :blk if (off >= sel.anchorHi()) line.contentEnd() else line.start;
        },
    };
}

/// 선택이 **여러 줄에 걸치는가** — `Tab` 이 글자를 넣을지 줄을 들여쓸지 가른다(§3.9a). **줄 번호로 잰다**(offset 차이로
/// 재면 긴 한 줄이 여러 줄로 오인된다). 커서가 여럿이면 하나라도 걸치면 참이다 — 섞였을 때 일부만 들여쓰면 나머지 커서는
/// 탭 문자를 받아 한 연산이 두 뜻이 된다.
pub fn spansLines(content: []const u8, lines: LineIndex, sels: []const Selection) bool {
    for (sels) |sel| {
        const s_off = @min(sel.start(), content.len);
        const e_off = @min(sel.end(), content.len);
        if (e_off <= s_off) continue;
        if (lines.lineAt(s_off) != lines.lineAt(e_off)) return true;
    }
    return false;
}

// ── 판정자 ────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// 판정자 전용 질의 — 랩이 없고(시각 행 모름) 괄호 짝도 없다. 열은 byte 와 같다.
const plain = struct {
    fn columnOf(_: *const anyopaque, line: []const u8, byte_in_line: usize) u32 {
        return @intCast(@min(byte_in_line, line.len));
    }
    fn offsetOf(_: *const anyopaque, line: []const u8, column: u32) usize {
        return @min(column, line.len);
    }
    fn rowSpan(_: *const anyopaque, _: usize, _: SeamSide) ?motion.VisualRow {
        return null;
    }
    fn visualMove(_: *const anyopaque, _: usize, _: *selection.Goal, _: bool) ?usize {
        return null;
    }
    fn bracketTarget(_: *const anyopaque, _: usize) ?usize {
        return null;
    }
    const dummy: u8 = 0;
    fn oracle() Oracle {
        return .{
            .ctx = &dummy,
            .map = .{ .ctx = &dummy, .columnOf = columnOf, .offsetOf = offsetOf },
            .page_rows = 2,
            .rowSpan = rowSpan,
            .visualMove = visualMove,
            .bracketTarget = bracketTarget,
        };
    }
};

test "movedOffset — 세로 이동은 목표 열을 지키고, 시각 행을 모르면 논리 줄로 떨어진다 (§3.2)" {
    const content = "abcdef\nab\nabcdef\n";
    var lines = try line_index.build(testing.allocator, content);
    defer lines.deinit();
    var goal: selection.Goal = .none;
    const o = plain.oracle();
    const down1 = movedOffset(content, lines, Selection.at(5), .line_down, &goal, o);
    try testing.expectEqual(@as(usize, 9), down1); // 짧은 줄 끝에서 잘린다
    const down2 = movedOffset(content, lines, Selection.at(down1), .line_down, &goal, o);
    try testing.expectEqual(@as(usize, 15), down2); // 넓은 줄에서 원래 열로 돌아온다
    var g2: selection.Goal = .none;
    try testing.expectEqual(@as(usize, 10), movedOffset(content, lines, Selection.at(0), .page_down, &g2, o)); // 두 줄
    var g3: selection.Goal = .none;
    try testing.expectEqual(@as(usize, 1), movedOffset(content, lines, Selection.fromPoints(1, 3), .bracket_match, &g3, o)); // 짝 없음 → 앞쪽 끝
}

test "moveAll — 아무 커서도 안 움직이면 null, Shift 는 anchor 를 남기고 나머지도 같이 옮긴다 (§3.2)" {
    const content = "ab\n";
    var lines = try line_index.build(testing.allocator, content);
    defer lines.deinit();
    const o = plain.oracle();
    var none = [_]Selection{};
    try testing.expect(moveAll(content, lines, Selection.at(0), &none, .doc_start, false, null, o) == null);
    var extras = [_]Selection{Selection.at(1)};
    const p = moveAll(content, lines, Selection.at(0), &extras, .char_right, true, null, o).?;
    try testing.expectEqual(@as(usize, 0), p.start());
    try testing.expectEqual(@as(usize, 1), p.end());
    try testing.expectEqual(@as(usize, 2), extras[0].focus);
    // 괄호 점프 — 도착이 없으면 앞쪽 끝으로 접힌다.
    var ex2 = [_]Selection{Selection.fromPoints(2, 1)};
    const q = moveAll(content, lines, Selection.at(0), &ex2, .bracket_match, false, &.{ 2, null }, o).?;
    try testing.expectEqual(@as(usize, 2), q.focus);
    try testing.expectEqual(@as(usize, 1), ex2[0].focus);
}

test "moveAll — 선택이 있으면 맨 ←/→ 는 선택 끝으로 접고, Shift·낱말 이동은 focus 에서 간다 (§3.2, 2026-10-11)" {
    const content = "abcdef\n";
    var lines = try line_index.build(testing.allocator, content);
    defer lines.deinit();
    const o = plain.oracle();
    var none = [_]Selection{};
    try testing.expectEqual(@as(usize, 4), moveAll(content, lines, Selection.fromPoints(2, 4), &none, .char_right, false, null, o).?.focus);
    try testing.expectEqual(@as(usize, 2), moveAll(content, lines, Selection.fromPoints(2, 4), &none, .char_left, false, null, o).?.focus);
    // 뒤로 고른 선택도 같은 끝이다.
    try testing.expectEqual(@as(usize, 4), moveAll(content, lines, Selection.fromPoints(4, 2), &none, .char_right, false, null, o).?.focus);
    // Shift 는 focus 에서 한 글자 간다.
    try testing.expectEqual(@as(usize, 5), moveAll(content, lines, Selection.fromPoints(2, 4), &none, .char_right, true, null, o).?.focus);
    // 낱말 이동은 접지 않는다 — focus 에서 간다.
    try testing.expectEqual(@as(usize, 0), moveAll(content, lines, Selection.fromPoints(2, 4), &none, .word_left, false, null, o).?.focus);
}

test "planAddVertically — 아래로 더하면 primary 가 맨 아래 사본이고, 끝에서는 안 더한다 (§3.2b)" {
    const content = "aaa\nbbb\nccc";
    var lines = try line_index.build(testing.allocator, content);
    defer lines.deinit();
    const o = plain.oracle();
    var c = (try planAddVertically(testing.allocator, content, lines, &.{ Selection.at(1), Selection.at(5) }, true, o)).?;
    defer c.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), c.items.len); // 1 의 사본은 5 와 겹쳐 합쳐진다
    try testing.expectEqual(@as(usize, 9), c.items[c.primary].focus);
    try testing.expect((try planAddVertically(testing.allocator, content, lines, &.{Selection.at(9)}, true, o)) == null);
}

test "planToggle — 품으면 지우고 없으면 더한다, primary 승계는 primary 를 지웠을 때만 (§3.2c, 결함 15)" {
    const a = testing.allocator;
    // [primary=10, 0, 5]
    var removed_other = (try planToggle(a, &.{ Selection.at(10), Selection.at(0), Selection.at(5) }, 0)).?;
    defer removed_other.deinit(a);
    try testing.expectEqual(@as(usize, 10), removed_other.items[removed_other.primary].focus);
    var removed_primary = (try planToggle(a, &.{ Selection.at(10), Selection.at(0), Selection.at(5) }, 10)).?;
    defer removed_primary.deinit(a);
    try testing.expectEqual(@as(usize, 5), removed_primary.items[removed_primary.primary].focus);
    var added = (try planToggle(a, &.{Selection.at(0)}, 7)).?;
    defer added.deinit(a);
    try testing.expectEqual(@as(usize, 7), added.items[added.primary].focus);
    try testing.expect((try planToggle(a, &.{Selection.fromPoints(2, 6)}, 4)) == null); // 마지막 커서는 안 지운다
}

test "planNextOccurrence — caret 씨앗은 내리지 않고 낱말이 대신한다, 잡은 단위가 kind 다" {
    const a = testing.allocator;
    const content = "foo bar foo";
    const first = (try planNextOccurrence(a, content, &.{Selection.at(1)})).?;
    try testing.expect(!first.demote_seed);
    try testing.expectEqual(selection.AnchorKind.word, first.primary.kind);
    const next = (try planNextOccurrence(a, content, &.{first.primary})).?;
    try testing.expect(next.demote_seed);
    try testing.expectEqual(@as(usize, 8), next.primary.start());
}

test "wordOrLineRange·widenedFocus·spansLines" {
    const content = "foo bar\n\nbaz\n";
    var lines = try line_index.build(testing.allocator, content);
    defer lines.deinit();
    const w = wordOrLineRange(content, lines, 5, false).?;
    try testing.expectEqual(@as(usize, 4), w.lo);
    try testing.expectEqual(@as(usize, 7), w.hi);
    const empty_line = wordOrLineRange(content, lines, 8, true).?;
    try testing.expectEqual(selection.AnchorKind.simple, empty_line.kind); // 빈 줄은 단언을 안 깬다
    const word = Selection.fromAnchorRange(0, 3, 3, .word);
    try testing.expectEqual(@as(usize, 7), widenedFocus(content, lines, word, 5));
    try testing.expect(!spansLines(content, lines, &.{ Selection.fromPoints(0, 3), Selection.at(9) }));
    try testing.expect(spansLines(content, lines, &.{ Selection.at(0), Selection.fromPoints(5, 10) }));
}
