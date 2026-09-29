//! 인라인 이름 편집기(사이드바 워크스페이스·그룹, pane·탭 라벨, 파일 트리 행, 이름 상자)의 **L3 순수 규칙**.
//!
//! 편집 상태는 `text_field.TextField` 가 소유한다(caret·그래핌 경계·IME preedit-at-caret). 이 파일은 그 위에서
//! 인라인 편집만의 세 가지를 정한다 — 셋 다 AppSession 없이 재야 해서 여기 둔다:
//!
//! 1. **키 → 편집**(`applyKey`): macOS 줄 편집 규약(주소창과 같다) — ←/→ 한 글자, ⌥←/→ 단어, ⌘←/→·⌃A/⌃E
//!    처음/끝, ⌫ 한 글자, ⌥⌫ 단어, ⌘⌫ 처음까지.
//! 2. **caret 자리에 끼운 한 줄**(`composeLine`): 인라인 편집기는 셀 스트림의 글자로 caret(`|`)을 그린다.
//! 3. **넘칠 때 caret 이 보이게 자르기**(`composeLineFit`): 사이드바는 편집 줄을 tail 앵커로 그린다.
//!
//! ## 왜 생겼나
//!
//! 2026-09-29 사용자 제보 — 「사이드바 워크스페이스 이름 변경할 때 커서 왔다갔다가 안 된다」. 인라인 rename 은
//! 끝-caret 전용 `OverlayInput` 을 썼다: 상태에 caret 이 없고(`appendChar`/`backspace` 가 끝 고정), 키 핸들러가
//! ←/→ 를 `else => {}` 로 버리고, 렌더가 `query ++ preedit ++ "|"` 로 늘 끝에 caret 을 붙였다. 세 겹이 모두 막혀
//! 있었으므로 셋을 함께 연다(docs/text-field-editor.md §2.2 — 두 번째 소비자).
//!
//! **선택은 만들지 않는다.** 인라인 편집기를 그리는 자리는 선택 하이라이트를 그리지 못한다 — 보이지 않는 선택이
//! 다음 타이핑에 글을 통째로 덮는다. 그래서 ⇧ 는 이동으로만 읽고 ⌘A 는 무시한다.

const std = @import("std");
const input = @import("../input.zig");
const text_field = @import("text_field.zig");
const text_layout = @import("../text_layout.zig");

pub const TextField = text_field.TextField;

/// 이름 속 단어 경계 — 이름은 URL 이 아니라 사람 말이라 공백과 흔한 구분 기호에서 끊는다.
pub const word_separators = " -_./:";

/// 키 하나의 결과. 호출자는 `commit`·`cancel` 을 제 대상에 맞게 처리하고, `edited`·`moved` 면 다시 그린다.
pub const Outcome = enum { edited, moved, commit, cancel, ignored };

/// 키 하나를 편집기에 적용한다. 선택은 만들지 않는다(파일 머리 주석).
pub fn applyKey(field: *TextField, allocator: std.mem.Allocator, k: input.InputEvent.KeyEvent) Outcome {
    switch (k.key) {
        .escape => return .cancel,
        .enter => return .commit,
        .left => {
            if (k.mods.command) field.moveHome(false) // ⌘← = 처음
            else if (k.mods.option) field.moveWordLeft(word_separators, false) // ⌥← = 단어
            else field.moveLeft(false);
            return .moved;
        },
        .right => {
            if (k.mods.command) field.moveEnd(false) // ⌘→ = 끝
            else if (k.mods.option) field.moveWordRight(word_separators, false) else field.moveRight(false);
            return .moved;
        },
        .backspace => {
            if (k.mods.command) field.deleteToLineStart() // ⌘⌫ = 처음까지 삭제
            else if (k.mods.option) field.deleteWordBackward(word_separators) // ⌥⌫ = 단어 삭제
            else field.deleteBackward();
            return .edited;
        },
        .char => {
            const is_a = k.codepoint == 'a' or k.codepoint == 'A';
            const is_e = k.codepoint == 'e' or k.codepoint == 'E';
            if (k.mods.control and is_a) {
                field.moveHome(false); // ⌃A 처음(emacs)
                return .moved;
            }
            if (k.mods.control and is_e) {
                field.moveEnd(false); // ⌃E 끝
                return .moved;
            }
            if (k.mods.command or k.mods.control or k.mods.option) return .ignored; // 그 외 조합은 안 쌓는다
            field.insertCp(allocator, k.codepoint) catch return .ignored;
            return .edited;
        },
        .up, .down, .tab, .other => return .ignored,
    }
}

/// 편집 줄 — caret 앞 글 + 조합 중 글자 + caret 글리프 + caret 뒤 글. 조합은 caret 자리에서 일어나므로 caret
/// 글리프는 조합 뒤에 온다(조합이 끝나면 그 자리에 확정된다). 호출자 소유.
pub fn composeLine(allocator: std.mem.Allocator, field: *const TextField, caret_glyph: []const u8) ![]u8 {
    const text = field.text.items;
    const at = @min(field.caret, text.len);
    return std.mem.concat(allocator, u8, &.{ text[0..at], field.preedit.items, caret_glyph, text[at..] });
}

/// `composeLine` 을 폭 `avail_cols` 칸 줄에 tail 앵커로 그릴 때 **caret 이 보이게** 한다. tail 앵커는 긴 줄의
/// 앞을 자르고 끝을 보인다 — caret 이 끝에 있으면 맞지만, 앞으로 옮기면 잘린 앞부분에 숨는다. 그때는 caret
/// 뒤 글을 창의 절반까지만 남겨 tail 창이 caret 을 담게 한다(가로 스크롤과 같은 효과). 안 넘치면 그대로다.
/// 폭은 방출자와 같은 cluster 단위(`text_layout.displayCols`)로 잰다.
pub fn composeLineFit(allocator: std.mem.Allocator, field: *const TextField, caret_glyph: []const u8, avail_cols: usize) ![]u8 {
    const full = try composeLine(allocator, field, caret_glyph);
    if (avail_cols == 0 or text_layout.displayCols(full, null) <= avail_cols) return full;
    const text = field.text.items;
    const at = @min(field.caret, text.len);
    const post = text[at..];
    const keep = avail_cols / 2;
    if (text_layout.displayCols(post, null) < keep) return full; // tail 창이 이미 caret 을 담는다
    var end: usize = 0;
    var cols: usize = 0;
    while (end < post.len) {
        const base = text_layout.decodeCodepoint(post, end);
        const w = text_layout.clusterCols(base.cp, null);
        if (cols + w > keep) break;
        cols += w;
        end = text_layout.clusterEndAfter(post, end, base.advance);
    }
    allocator.free(full);
    return std.mem.concat(allocator, u8, &.{ text[0..at], field.preedit.items, caret_glyph, post[0..end] });
}

/// 그려진 줄에서 caret(조합 시작점)이 놓이는 **창 안의 열** — IME 후보창 자리.
///
/// 렌더는 `lead ++ composeLineFit(…, fit_cols)` 한 줄을 폭 `window_cols` 칸에 tail 앵커로 놓는다(`text_layout.plan`).
/// 여기서도 **같은 계획을 돌려** caret 앞 글자가 끝나는 열을 찾는다 — 따로 셈하면 넘칠 때(앞이 "…"로 잘리거나 뒤가
/// fit 으로 잘릴 때) 후보창과 그려진 caret 이 수 칸씩 어긋났다(적대적 검증 2026-09-29). `lead` 는 편집 글 앞에 같은
/// 줄로 그려지는 접두(그룹 헤더의 들여쓰기·삼각·공백)이고, 폭만 같으면 된다. `fit_cols=0` 이면 자르지 않는다.
pub fn drawnCaretCol(
    allocator: std.mem.Allocator,
    lead: []const u8,
    field: *const TextField,
    caret_glyph: []const u8,
    fit_cols: usize,
    window_cols: u16,
) !u16 {
    const fitted = try composeLineFit(allocator, field, caret_glyph, fit_cols);
    defer allocator.free(fitted);
    const line = try std.mem.concat(allocator, u8, &.{ lead, fitted });
    defer allocator.free(line);
    const at = lead.len + @min(field.caret, field.text.items.len); // 조합·caret 이 시작하는 바이트
    var p = text_layout.plan(line, 0, window_cols, .tail, null);
    var last_end: u16 = 0;
    while (p.next()) |item| switch (item) {
        .cluster => |c| {
            if (c.start >= at) return c.col; // caret 자리에서 시작하는 첫 글자의 열
            last_end = c.col + c.cols;
        },
        .ellipsis => |col| last_end = col + 1,
    };
    return last_end; // caret 뒤가 비었으면(끝) 마지막 글자 바로 뒤
}

/// caret **앞** 글의 표시 칸 수(cluster 단위) — caret·IME 후보창의 열.
pub fn caretCols(field: *const TextField) usize {
    const text = field.text.items;
    return text_layout.displayCols(text[0..@min(field.caret, text.len)], null);
}

// ── 판정 ────────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn key(k: input.Key, cp: u21, mods: input.Mods) input.InputEvent.KeyEvent {
    return .{ .key = k, .codepoint = cp, .mods = mods };
}

fn typeText(field: *TextField, s: []const u8) !void {
    for (s) |ch| try testing.expectEqual(Outcome.edited, applyKey(field, testing.allocator, key(.char, ch, .{})));
}

test "인라인 편집: ←/→ 로 caret 을 옮기고 그 자리에 쓰고 지운다" {
    // 제보의 핵심 — 예전에는 ←/→ 를 버려 caret 이 늘 끝이었고, 글은 끝에만 붙었다.
    var f: TextField = .{};
    defer f.deinit(testing.allocator);
    try f.setText(testing.allocator, "maru");
    try testing.expectEqual(Outcome.moved, applyKey(&f, testing.allocator, key(.left, 0, .{})));
    try testing.expectEqual(Outcome.moved, applyKey(&f, testing.allocator, key(.left, 0, .{})));
    try typeText(&f, "X");
    try testing.expectEqualStrings("maXru", f.text.items);
    _ = applyKey(&f, testing.allocator, key(.backspace, 0, .{}));
    try testing.expectEqualStrings("maru", f.text.items);
    _ = applyKey(&f, testing.allocator, key(.right, 0, .{}));
    try typeText(&f, "Y");
    try testing.expectEqualStrings("marYu", f.text.items);
}

test "인라인 편집: ⌘←/→·⌃A/⌃E 는 처음/끝, ⌥←/→ 는 단어, ⌥⌫·⌘⌫ 는 단어·처음까지 지운다" {
    var f: TextField = .{};
    defer f.deinit(testing.allocator);
    try f.setText(testing.allocator, "my work-space");
    _ = applyKey(&f, testing.allocator, key(.left, 0, .{ .command = true }));
    try testing.expectEqual(@as(usize, 0), f.caret);
    _ = applyKey(&f, testing.allocator, key(.char, 'e', .{ .control = true }));
    try testing.expectEqual(f.text.items.len, f.caret);
    _ = applyKey(&f, testing.allocator, key(.char, 'a', .{ .control = true }));
    try testing.expectEqual(@as(usize, 0), f.caret);
    _ = applyKey(&f, testing.allocator, key(.right, 0, .{ .option = true }));
    try testing.expectEqual(@as(usize, 2), f.caret); // "my" 뒤
    _ = applyKey(&f, testing.allocator, key(.right, 0, .{ .command = true }));
    _ = applyKey(&f, testing.allocator, key(.backspace, 0, .{ .option = true }));
    try testing.expectEqualStrings("my work-", f.text.items); // '-' 가 경계
    _ = applyKey(&f, testing.allocator, key(.left, 0, .{ .option = true }));
    _ = applyKey(&f, testing.allocator, key(.backspace, 0, .{ .command = true }));
    try testing.expectEqualStrings("work-", f.text.items);
    try testing.expectEqual(@as(usize, 0), f.caret);
}

test "인라인 편집: 선택은 만들지 않는다 — ⇧←, ⌘A 뒤 타이핑이 글을 덮지 않는다" {
    // 인라인 편집기는 선택을 그리지 못한다. 보이지 않는 선택이 생기면 다음 글자가 그 범위를 조용히 지운다.
    var f: TextField = .{};
    defer f.deinit(testing.allocator);
    try f.setText(testing.allocator, "abc");
    _ = applyKey(&f, testing.allocator, key(.left, 0, .{ .shift = true }));
    try testing.expect(f.selection == null);
    try testing.expectEqual(Outcome.ignored, applyKey(&f, testing.allocator, key(.char, 'a', .{ .command = true })));
    try testing.expect(f.selection == null);
    try typeText(&f, "Z");
    try testing.expectEqualStrings("abZc", f.text.items);
}

test "인라인 편집: Enter·Esc 는 호출자에게 넘기고, ↑↓·단축키 조합은 글을 안 바꾼다" {
    var f: TextField = .{};
    defer f.deinit(testing.allocator);
    try f.setText(testing.allocator, "abc");
    try testing.expectEqual(Outcome.commit, applyKey(&f, testing.allocator, key(.enter, 0, .{})));
    try testing.expectEqual(Outcome.cancel, applyKey(&f, testing.allocator, key(.escape, 0, .{})));
    for ([_]input.InputEvent.KeyEvent{ key(.up, 0, .{}), key(.down, 0, .{}), key(.tab, 0, .{}), key(.other, 0, .{}), key(.char, 'k', .{ .command = true }), key(.char, 'x', .{ .option = true }) }) |k|
        try testing.expectEqual(Outcome.ignored, applyKey(&f, testing.allocator, k));
    try testing.expectEqualStrings("abc", f.text.items);
    try testing.expectEqual(@as(usize, 3), f.caret);
}

test "인라인 편집: 편집 줄은 caret 자리에 조합 글자와 caret 을 끼운다" {
    var f: TextField = .{};
    defer f.deinit(testing.allocator);
    try f.setText(testing.allocator, "한글");
    const end = try composeLine(testing.allocator, &f, "|");
    defer testing.allocator.free(end);
    try testing.expectEqualStrings("한글|", end); // 시작은 끝(이어 쓰기)
    f.moveLeft(false);
    try f.setPreedit(testing.allocator, "ㅁ");
    const mid = try composeLine(testing.allocator, &f, "|");
    defer testing.allocator.free(mid);
    try testing.expectEqualStrings("한ㅁ|글", mid);
    try testing.expectEqual(@as(usize, 2), caretCols(&f)); // '한' 2칸 — 조합은 caret 열에 안 더한다
}

test "인라인 편집: 넘치는 줄에서 caret 을 앞으로 옮겨도 tail 창 안에 남는다" {
    // tail 앵커는 끝 avail 칸을 보인다. caret 을 앞으로 옮기면 그 창 밖으로 나가 사라졌다 — 창 절반까지만
    // 뒤 글을 남겨 caret 이 창 안에 오게 한다.
    var f: TextField = .{};
    defer f.deinit(testing.allocator);
    try f.setText(testing.allocator, "abcdefghijklmnopqrstuvwxyz0123456789");
    const avail: usize = 12;
    // 끝 caret — 그대로(끝이 보이면 caret 도 보인다).
    const at_end = try composeLineFit(testing.allocator, &f, "|", avail);
    defer testing.allocator.free(at_end);
    try testing.expect(std.mem.endsWith(u8, at_end, "|"));
    // caret 을 앞쪽으로 — 뒤 글이 잘리고, tail 창(끝 avail 칸)이 caret 을 담는다.
    f.caret = 5;
    const fitted = try composeLineFit(testing.allocator, &f, "|", avail);
    defer testing.allocator.free(fitted);
    // tail 앵커는 넘치면 선두 1칸을 "…" 에 쓴다 — 보이는 꼬리는 avail-1 칸이다. 그 안에 caret 이 있어야 한다.
    const caret_at = std.mem.indexOfScalar(u8, fitted, '|') orelse return error.TestUnexpectedResult;
    const tail_start = fitted.len -| (avail - 1);
    try testing.expect(fitted.len <= avail or caret_at >= tail_start);
    try testing.expectEqualStrings("abcde|fghijk", fitted[0..@min(fitted.len, 12)]);
    // 안 넘치면 자르지 않는다.
    f.caret = 1;
    const roomy = try composeLineFit(testing.allocator, &f, "|", 200);
    defer testing.allocator.free(roomy);
    try testing.expectEqual(f.text.items.len + 1, roomy.len);
}

test "인라인 편집: ⌘⌫ 는 처음까지, ⌥⌫ 는 한 단어만 지운다 — 둘이 갈린다" {
    // 앞 판정자는 두 동작의 결과가 우연히 같은 자리에서만 재 ⌘⌫ 를 단어 삭제로 바꿔도 초록이었다.
    var a: TextField = .{};
    defer a.deinit(testing.allocator);
    try a.setText(testing.allocator, "ab cd ef");
    _ = applyKey(&a, testing.allocator, key(.backspace, 0, .{ .option = true }));
    try testing.expectEqualStrings("ab cd ", a.text.items);
    var c: TextField = .{};
    defer c.deinit(testing.allocator);
    try c.setText(testing.allocator, "ab cd ef");
    _ = applyKey(&c, testing.allocator, key(.backspace, 0, .{ .command = true }));
    try testing.expectEqualStrings("", c.text.items);
}

test "인라인 편집: 넘친 줄에서 caret 을 앞으로 옮기면 그려진 자리는 tail 창 안이다 (avail-1 칸)" {
    // 잘린 줄을 실제 렌더 계획(`text_layout.plan` tail)으로 놓아 caret 글리프가 창 안에 그려지는지 잰다.
    var f: TextField = .{};
    defer f.deinit(testing.allocator);
    try f.setText(testing.allocator, "abcdefghijklmnopqrstuvwxyz0123456789");
    for ([_]usize{ 0, 5, 18, 30, 36 }) |caret| {
        f.caret = caret;
        const line = try composeLineFit(testing.allocator, &f, "|", 12);
        defer testing.allocator.free(line);
        var p = text_layout.plan(line, 0, 12, .tail, null);
        var drawn = false;
        while (p.next()) |item| switch (item) {
            .cluster => |cl| if (std.mem.eql(u8, line[cl.start..cl.end], "|")) {
                drawn = true;
            },
            .ellipsis => {},
        };
        try testing.expect(drawn);
    }
}

test "인라인 편집: IME 열은 렌더와 같은 계획으로 잰다 — 넘쳐도 그려진 caret 과 같은 열" {
    var f: TextField = .{};
    defer f.deinit(testing.allocator);
    try f.setText(testing.allocator, "abcdefghijklmnopqrstuvwxyz0123456789");
    const window: u16 = 12;
    for ([_]usize{ 0, 5, 18, 30, 36 }) |caret| {
        f.caret = caret;
        const col = try drawnCaretCol(testing.allocator, "", &f, "|", window, window);
        const line = try composeLineFit(testing.allocator, &f, "|", window);
        defer testing.allocator.free(line);
        var p = text_layout.plan(line, 0, window, .tail, null);
        var glyph_col: ?u16 = null;
        while (p.next()) |item| switch (item) {
            .cluster => |cl| if (std.mem.eql(u8, line[cl.start..cl.end], "|")) {
                glyph_col = cl.col;
            },
            .ellipsis => {},
        };
        // 조합이 없으면 caret 글리프가 caret 자리 그 자체다.
        try testing.expectEqual(glyph_col, col);
        try testing.expect(col < window);
    }
    // 안 넘치면 caret 앞 글 폭 그대로(접두 포함).
    f.caret = 3;
    try f.setText(testing.allocator, "abc");
    f.caret = 1;
    try testing.expectEqual(@as(u16, 2 + 1), try drawnCaretCol(testing.allocator, "  ", &f, "|", 0, 40));
}
