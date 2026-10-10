//! `browser.press` 의 키 이름(`"Enter"`·`"Shift+Tab"`·`"Meta+a"`·`"가"`)을 DevTools `Input.dispatchKeyEvent` 의 누름·뗌으로 푼다
//! (W9b①b-2 — Chromium 탭의 진짜 키 입력). 순수 — CEF·control-plane 을 모른다.
//!
//! - 이름은 `수식키+…+키`. 수식키는 `Shift`·`Control`(`Ctrl`)·`Alt`(`Option`)·`Meta`(`Cmd`·`Command`). 키는 이름 있는 키(아래 표)이거나
//!   글자 하나(유니코드 스칼라 하나). 마지막이 `+` 면 그 글자다(`Shift++`).
//! - **macOS 의 편집 단축키는 명령을 함께 싣는다** — OSR Chromium 은 `Meta+a` 의 keydown 만 페이지에 주고 전체 선택은 하지 않았다
//!   (착수 전 실측 — `commands:["selectAll"]` 을 실으니 됐다). 명령 이름은 macOS 의 표준 키 바인딩(`NSStandardKeyBindingResponding`
//!   셀렉터 — 공개 API)에서 콜론을 뺀 것이다. 붙여넣기(`Meta+v` → `paste`)는 **사용자 클립보드를 페이지에 넣는다**(사용자 결정
//!   2026-10-10 — 막지 않는다).
//! - 글자는 `Meta`·`Control` 이 없을 때만 글(`text`)을 싣는다(단축키는 글을 넣지 않는다). `Shift` 는 US 배열로 바꾼다 — 영문 소문자는
//!   대문자, 숫자·기호는 위 글자(`Shift+1` → `!`, `Shift+/` → `?`). 기호는 그 자리의 `code`·keyCode 를 싣는다(`?` → `Slash`·191).
//! - 대문자·위 글자를 바로 주면(`A`·`?`) shiftKey 를 켠다. `Meta`·`Control` 과 함께면 영문은 소문자 key 다(`Meta+A` = Cmd+a).
//! - 이름은 대소문자를 가리지 않는다(`enter`·`ctrl+a`), `Esc`·`Return` 도 받는다. `Control`·`Alt` + 글자는 macOS 의 뜻(Emacs 줄 이동·
//!   `Option+a` = `å`)을 만들지 않고 그대로 보낸다(그 글자·modifiers 만 — 적대 리뷰 1 회차).

const std = @import("std");

pub const Modifier = struct {
    pub const alt: u8 = 1;
    pub const control: u8 = 2;
    pub const meta: u8 = 4;
    pub const shift: u8 = 8;
};

pub const Press = struct {
    /// DOM `KeyboardEvent.key`.
    key: []const u8,
    /// DOM `KeyboardEvent.code`(모르면 빈 것).
    code: []const u8,
    vk: u16,
    modifiers: u8,
    /// 넣을 글(없으면 rawKeyDown).
    text: ?[]const u8,
    /// macOS 편집 명령(Chromium `commands`).
    command: ?[]const u8,
    /// `key`·`text` 가 가리키는 글자 자리(이름 있는 키는 표의 정적 글을 가리킨다).
    buf: [8]u8 = undefined,
};

const Named = struct { name: []const u8, key: []const u8, code: []const u8, vk: u16, text: ?[]const u8 = null };

const named_keys = [_]Named{
    .{ .name = "Enter", .key = "Enter", .code = "Enter", .vk = 13, .text = "\r" },
    .{ .name = "Tab", .key = "Tab", .code = "Tab", .vk = 9 },
    .{ .name = "Escape", .key = "Escape", .code = "Escape", .vk = 27 },
    .{ .name = "Esc", .key = "Escape", .code = "Escape", .vk = 27 },
    .{ .name = "Return", .key = "Enter", .code = "Enter", .vk = 13, .text = "\r" },
    .{ .name = "Backspace", .key = "Backspace", .code = "Backspace", .vk = 8 },
    .{ .name = "Delete", .key = "Delete", .code = "Delete", .vk = 46 },
    .{ .name = "Insert", .key = "Insert", .code = "Insert", .vk = 45 },
    .{ .name = "Space", .key = " ", .code = "Space", .vk = 32, .text = " " },
    .{ .name = "ArrowUp", .key = "ArrowUp", .code = "ArrowUp", .vk = 38 },
    .{ .name = "ArrowDown", .key = "ArrowDown", .code = "ArrowDown", .vk = 40 },
    .{ .name = "ArrowLeft", .key = "ArrowLeft", .code = "ArrowLeft", .vk = 37 },
    .{ .name = "ArrowRight", .key = "ArrowRight", .code = "ArrowRight", .vk = 39 },
    .{ .name = "Home", .key = "Home", .code = "Home", .vk = 36 },
    .{ .name = "End", .key = "End", .code = "End", .vk = 35 },
    .{ .name = "PageUp", .key = "PageUp", .code = "PageUp", .vk = 33 },
    .{ .name = "PageDown", .key = "PageDown", .code = "PageDown", .vk = 34 },
    .{ .name = "F1", .key = "F1", .code = "F1", .vk = 112 },
    .{ .name = "F2", .key = "F2", .code = "F2", .vk = 113 },
    .{ .name = "F3", .key = "F3", .code = "F3", .vk = 114 },
    .{ .name = "F4", .key = "F4", .code = "F4", .vk = 115 },
    .{ .name = "F5", .key = "F5", .code = "F5", .vk = 116 },
    .{ .name = "F6", .key = "F6", .code = "F6", .vk = 117 },
    .{ .name = "F7", .key = "F7", .code = "F7", .vk = 118 },
    .{ .name = "F8", .key = "F8", .code = "F8", .vk = 119 },
    .{ .name = "F9", .key = "F9", .code = "F9", .vk = 120 },
    .{ .name = "F10", .key = "F10", .code = "F10", .vk = 121 },
    .{ .name = "F11", .key = "F11", .code = "F11", .vk = 122 },
    .{ .name = "F12", .key = "F12", .code = "F12", .vk = 123 },
};

/// 이름의 바이트 상한(L2 도 같은 상한으로 거절한다).
pub const max_spec_bytes = 64;

pub const ParseError = error{InvalidKey};

/// `spec` 을 푼다. `out.key`·`out.text` 는 `out.buf` 나 정적 글을 가리킨다 — 푼 그 자리에서 쓴다(값으로 옮기지 않는다 — op 은 이름을
/// 쥐고 이벤트를 만들 때마다 다시 푼다).
pub fn parse(spec: []const u8, out: *Press) ParseError!void {
    if (spec.len == 0 or spec.len > max_spec_bytes) return error.InvalidKey;
    var mods: u8 = 0;
    var rest = spec;
    while (true) {
        // 마지막 조각이 키 — `+` 자체가 키면(`Shift++`·`+`) 그 앞에서 끊는다.
        const plus = std.mem.indexOfScalar(u8, rest, '+') orelse break;
        if (plus == rest.len - 1) break; // `+` 하나만 남았으면 그것이 키(`+`·`Shift++`), 아니면 아래에서 거절
        if (plus == 0) return error.InvalidKey;
        mods |= modifierBit(rest[0..plus]) orelse return error.InvalidKey;
        rest = rest[plus + 1 ..];
    }
    if (rest.len > 1 and rest[rest.len - 1] == '+') return error.InvalidKey; // `Shift+` — 키가 없다
    out.* = .{ .key = "", .code = "", .vk = 0, .modifiers = mods, .text = null, .command = null };
    for (named_keys) |n| if (rest.len > 1 and std.ascii.eqlIgnoreCase(n.name, rest)) {
        out.key = n.key;
        out.code = n.code;
        out.vk = n.vk;
        out.text = if (mods & (Modifier.meta | Modifier.control) == 0) n.text else null;
        out.command = editingCommand(n.key, mods);
        return;
    };
    // 글자 하나.
    const len = std.unicode.utf8ByteSequenceLength(rest[0]) catch return error.InvalidKey;
    if (len != rest.len) return error.InvalidKey;
    const cp = std.unicode.utf8Decode(rest) catch return error.InvalidKey;
    if (cp < 0x20 or (cp >= 0x7f and cp <= 0x9f)) return error.InvalidKey; // C0·DEL·C1 제어 문자
    var ch = rest;
    @memcpy(out.buf[0..ch.len], ch);
    if (cp < 0x80) {
        const c: u8 = @intCast(cp);
        const shift = mods & Modifier.shift != 0;
        const shortcut = mods & (Modifier.meta | Modifier.control) != 0;
        if (std.ascii.isAlphabetic(c)) {
            const upper = std.ascii.toUpper(c);
            if (shift) {
                out.buf[0] = upper;
            } else if (shortcut) {
                out.buf[0] = std.ascii.toLower(c); // `Meta+A` 는 실제 Cmd+A 처럼 key `a`(적대 리뷰 2 회차)
            } else if (c == upper) {
                out.modifiers |= Modifier.shift; // 대문자를 바로 줬다 — 실제 키보드처럼 shiftKey 를 켠다
            }
            out.code = letter_codes[upper - 'A'];
            out.vk = upper;
        } else if (c == ' ') {
            out.code = "Space";
            out.vk = 32;
        } else for (us_keys) |k| if (c == k.plain or c == k.shifted) {
            // 그 자리의 키 — `Shift` 면 위 글자를 넣는다(`?` 처럼 위 글자를 바로 줘도 같은 자리).
            if (shift) {
                out.buf[0] = k.shifted;
            } else if (c == k.shifted) {
                out.modifiers |= Modifier.shift; // 위 글자(`?`·`Meta+!`)를 바로 줬다 — Shift 없이는 낼 수 없으니 shiftKey 를 켠다(3 회차)
            }
            out.code = k.code;
            out.vk = k.vk;
            break;
        };
    }
    ch = out.buf[0..rest.len];
    out.key = ch;
    out.text = if (mods & (Modifier.meta | Modifier.control) == 0) ch else null;
    out.command = editingCommand(rest, mods);
}

/// US 배열의 숫자·기호 자리(아래 글자·위 글자·DOM code·Windows keyCode).
const UsKey = struct { plain: u8, shifted: u8, code: []const u8, vk: u16 };
const us_keys = [_]UsKey{
    .{ .plain = '1', .shifted = '!', .code = "Digit1", .vk = '1' },
    .{ .plain = '2', .shifted = '@', .code = "Digit2", .vk = '2' },
    .{ .plain = '3', .shifted = '#', .code = "Digit3", .vk = '3' },
    .{ .plain = '4', .shifted = '$', .code = "Digit4", .vk = '4' },
    .{ .plain = '5', .shifted = '%', .code = "Digit5", .vk = '5' },
    .{ .plain = '6', .shifted = '^', .code = "Digit6", .vk = '6' },
    .{ .plain = '7', .shifted = '&', .code = "Digit7", .vk = '7' },
    .{ .plain = '8', .shifted = '*', .code = "Digit8", .vk = '8' },
    .{ .plain = '9', .shifted = '(', .code = "Digit9", .vk = '9' },
    .{ .plain = '0', .shifted = ')', .code = "Digit0", .vk = '0' },
    .{ .plain = '`', .shifted = '~', .code = "Backquote", .vk = 192 },
    .{ .plain = '-', .shifted = '_', .code = "Minus", .vk = 189 },
    .{ .plain = '=', .shifted = '+', .code = "Equal", .vk = 187 },
    .{ .plain = '[', .shifted = '{', .code = "BracketLeft", .vk = 219 },
    .{ .plain = ']', .shifted = '}', .code = "BracketRight", .vk = 221 },
    .{ .plain = '\\', .shifted = '|', .code = "Backslash", .vk = 220 },
    .{ .plain = ';', .shifted = ':', .code = "Semicolon", .vk = 186 },
    .{ .plain = '\'', .shifted = '"', .code = "Quote", .vk = 222 },
    .{ .plain = ',', .shifted = '<', .code = "Comma", .vk = 188 },
    .{ .plain = '.', .shifted = '>', .code = "Period", .vk = 190 },
    .{ .plain = '/', .shifted = '?', .code = "Slash", .vk = 191 },
};

const letter_codes = blk: {
    var out: [26][]const u8 = undefined;
    for (0..26) |i| out[i] = "Key" ++ [_]u8{'A' + i};
    break :blk out;
};

fn modifierBit(name: []const u8) ?u8 {
    const table = [_]struct { []const u8, u8 }{
        .{ "Shift", Modifier.shift },
        .{ "Control", Modifier.control },
        .{ "Ctrl", Modifier.control },
        .{ "Alt", Modifier.alt },
        .{ "Option", Modifier.alt },
        .{ "Meta", Modifier.meta },
        .{ "Cmd", Modifier.meta },
        .{ "Command", Modifier.meta },
    };
    for (table) |e| if (std.ascii.eqlIgnoreCase(e[0], name)) return e[1];
    return null;
}

/// macOS 표준 키 바인딩의 편집 명령(셀렉터 이름에서 콜론을 뺀 것). OSR Chromium 은 이 단축키의 동작을 키 이벤트만으로 하지 않는다.
fn editingCommand(key: []const u8, mods: u8) ?[]const u8 {
    const shift = mods & Modifier.shift != 0;
    const base = mods & ~Modifier.shift;
    if (base == Modifier.meta) {
        if (eqi(key, "a") and !shift) return "selectAll";
        if (eqi(key, "c") and !shift) return "copy";
        if (eqi(key, "x") and !shift) return "cut";
        if (eqi(key, "v") and !shift) return "paste";
        if (eqi(key, "z")) return if (shift) "redo" else "undo";
        if (eq(key, "ArrowLeft")) return if (shift) "moveToBeginningOfLineAndModifySelection" else "moveToBeginningOfLine";
        if (eq(key, "ArrowRight")) return if (shift) "moveToEndOfLineAndModifySelection" else "moveToEndOfLine";
        if (eq(key, "ArrowUp")) return if (shift) "moveToBeginningOfDocumentAndModifySelection" else "moveToBeginningOfDocument";
        if (eq(key, "ArrowDown")) return if (shift) "moveToEndOfDocumentAndModifySelection" else "moveToEndOfDocument";
        if (eq(key, "Backspace") and !shift) return "deleteToBeginningOfLine";
    }
    if (base == Modifier.alt) {
        if (eq(key, "ArrowLeft")) return if (shift) "moveWordLeftAndModifySelection" else "moveWordLeft";
        if (eq(key, "ArrowRight")) return if (shift) "moveWordRightAndModifySelection" else "moveWordRight";
    }
    return null;
}

/// 누름(`down`)·뗌 의 `Input.dispatchKeyEvent` 인자 JSON(소유) — `spec` 은 `parse` 를 지난 이름.
pub fn eventParams(gpa: std.mem.Allocator, spec: []const u8, down: bool) (std.mem.Allocator.Error || ParseError)![]u8 {
    var p: Press = undefined;
    try parse(spec, &p);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    writeEvent(&s, &p, down) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn writeEvent(s: *std.json.Stringify, p: *const Press, down: bool) !void {
    try s.beginObject();
    try s.objectField("type");
    try s.write(if (!down) "keyUp" else if (p.text != null) "keyDown" else "rawKeyDown");
    try s.objectField("key");
    try s.write(p.key);
    try s.objectField("code");
    try s.write(p.code);
    try s.objectField("windowsVirtualKeyCode");
    try s.write(p.vk);
    try s.objectField("modifiers");
    try s.write(p.modifiers);
    if (down) {
        if (p.text) |t| {
            try s.objectField("text");
            try s.write(t);
            try s.objectField("unmodifiedText");
            try s.write(t);
        }
        if (p.command) |c| {
            try s.objectField("commands");
            try s.beginArray();
            try s.write(c);
            try s.endArray();
        }
    }
    try s.endObject();
}

inline fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

inline fn eqi(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

const testing = std.testing;

fn expectEvent(spec: []const u8, down: bool, want: []const u8) !void {
    const got = try eventParams(testing.allocator, spec, down);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

test "키 이름: 이름 있는 키·글자·수식키·편집 명령" {
    try expectEvent("Enter", true, "{\"type\":\"keyDown\",\"key\":\"Enter\",\"code\":\"Enter\",\"windowsVirtualKeyCode\":13,\"modifiers\":0,\"text\":\"\\r\",\"unmodifiedText\":\"\\r\"}");
    try expectEvent("Enter", false, "{\"type\":\"keyUp\",\"key\":\"Enter\",\"code\":\"Enter\",\"windowsVirtualKeyCode\":13,\"modifiers\":0}");
    try expectEvent("Shift+Tab", true, "{\"type\":\"rawKeyDown\",\"key\":\"Tab\",\"code\":\"Tab\",\"windowsVirtualKeyCode\":9,\"modifiers\":8}");
    try expectEvent("a", true, "{\"type\":\"keyDown\",\"key\":\"a\",\"code\":\"KeyA\",\"windowsVirtualKeyCode\":65,\"modifiers\":0,\"text\":\"a\",\"unmodifiedText\":\"a\"}");
    try expectEvent("Shift+a", true, "{\"type\":\"keyDown\",\"key\":\"A\",\"code\":\"KeyA\",\"windowsVirtualKeyCode\":65,\"modifiers\":8,\"text\":\"A\",\"unmodifiedText\":\"A\"}");
    try expectEvent("Meta+a", true, "{\"type\":\"rawKeyDown\",\"key\":\"a\",\"code\":\"KeyA\",\"windowsVirtualKeyCode\":65,\"modifiers\":4,\"commands\":[\"selectAll\"]}");
    try expectEvent("Cmd+v", true, "{\"type\":\"rawKeyDown\",\"key\":\"v\",\"code\":\"KeyV\",\"windowsVirtualKeyCode\":86,\"modifiers\":4,\"commands\":[\"paste\"]}");
    try expectEvent("Meta+Shift+z", true, "{\"type\":\"rawKeyDown\",\"key\":\"Z\",\"code\":\"KeyZ\",\"windowsVirtualKeyCode\":90,\"modifiers\":12,\"commands\":[\"redo\"]}");
    try expectEvent("Alt+Shift+ArrowLeft", true, "{\"type\":\"rawKeyDown\",\"key\":\"ArrowLeft\",\"code\":\"ArrowLeft\",\"windowsVirtualKeyCode\":37,\"modifiers\":9,\"commands\":[\"moveWordLeftAndModifySelection\"]}");
    try expectEvent("Control+a", true, "{\"type\":\"rawKeyDown\",\"key\":\"a\",\"code\":\"KeyA\",\"windowsVirtualKeyCode\":65,\"modifiers\":2}");
    try expectEvent("가", true, "{\"type\":\"keyDown\",\"key\":\"가\",\"code\":\"\",\"windowsVirtualKeyCode\":0,\"modifiers\":0,\"text\":\"가\",\"unmodifiedText\":\"가\"}");
    try expectEvent("Space", true, "{\"type\":\"keyDown\",\"key\":\" \",\"code\":\"Space\",\"windowsVirtualKeyCode\":32,\"modifiers\":0,\"text\":\" \",\"unmodifiedText\":\" \"}");
    try expectEvent("+", true, "{\"type\":\"keyDown\",\"key\":\"+\",\"code\":\"Equal\",\"windowsVirtualKeyCode\":187,\"modifiers\":8,\"text\":\"+\",\"unmodifiedText\":\"+\"}");
    try expectEvent("Shift++", true, "{\"type\":\"keyDown\",\"key\":\"+\",\"code\":\"Equal\",\"windowsVirtualKeyCode\":187,\"modifiers\":8,\"text\":\"+\",\"unmodifiedText\":\"+\"}");
    // Shift 는 US 배열의 위 글자로, 기호는 그 자리의 code·keyCode.
    try expectEvent("Shift+1", true, "{\"type\":\"keyDown\",\"key\":\"!\",\"code\":\"Digit1\",\"windowsVirtualKeyCode\":49,\"modifiers\":8,\"text\":\"!\",\"unmodifiedText\":\"!\"}");
    try expectEvent("Shift+/", true, "{\"type\":\"keyDown\",\"key\":\"?\",\"code\":\"Slash\",\"windowsVirtualKeyCode\":191,\"modifiers\":8,\"text\":\"?\",\"unmodifiedText\":\"?\"}");
    try expectEvent("?", true, "{\"type\":\"keyDown\",\"key\":\"?\",\"code\":\"Slash\",\"windowsVirtualKeyCode\":191,\"modifiers\":8,\"text\":\"?\",\"unmodifiedText\":\"?\"}");
    // 대문자를 바로 주면 shiftKey 를 켜고, Meta·Control 과 함께면 실제 단축키처럼 소문자 key 다.
    try expectEvent("A", true, "{\"type\":\"keyDown\",\"key\":\"A\",\"code\":\"KeyA\",\"windowsVirtualKeyCode\":65,\"modifiers\":8,\"text\":\"A\",\"unmodifiedText\":\"A\"}");
    try expectEvent("Meta+!", true, "{\"type\":\"rawKeyDown\",\"key\":\"!\",\"code\":\"Digit1\",\"windowsVirtualKeyCode\":49,\"modifiers\":12}");
    try expectEvent("Meta+A", true, "{\"type\":\"rawKeyDown\",\"key\":\"a\",\"code\":\"KeyA\",\"windowsVirtualKeyCode\":65,\"modifiers\":4,\"commands\":[\"selectAll\"]}");
    // 이름은 대소문자를 가리지 않고 Esc·Return 도 받는다.
    try expectEvent("ctrl+ENTER", false, "{\"type\":\"keyUp\",\"key\":\"Enter\",\"code\":\"Enter\",\"windowsVirtualKeyCode\":13,\"modifiers\":2}");
    try expectEvent("Esc", false, "{\"type\":\"keyUp\",\"key\":\"Escape\",\"code\":\"Escape\",\"windowsVirtualKeyCode\":27,\"modifiers\":0}");
    try expectEvent("cmd+arrowleft", true, "{\"type\":\"rawKeyDown\",\"key\":\"ArrowLeft\",\"code\":\"ArrowLeft\",\"windowsVirtualKeyCode\":37,\"modifiers\":4,\"commands\":[\"moveToBeginningOfLine\"]}");
    try expectEvent("7", true, "{\"type\":\"keyDown\",\"key\":\"7\",\"code\":\"Digit7\",\"windowsVirtualKeyCode\":55,\"modifiers\":0,\"text\":\"7\",\"unmodifiedText\":\"7\"}");
}

test "키 이름: 틀린 이름은 거절한다" {
    var p: Press = undefined;
    for ([_][]const u8{ "", "Hyper+a", "ab", "Enterr", "+a", "Shift+", "Shift+Ctrl", "\x01", "\x7f", "\u{85}", "a+b", "Shift+++", "Return+" }) |bad| {
        try testing.expectError(error.InvalidKey, parse(bad, &p));
    }
    try testing.expectError(error.InvalidKey, parse("a" ** 65, &p));
}
