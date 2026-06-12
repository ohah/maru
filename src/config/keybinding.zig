const std = @import("std");
const action_mod = @import("action.zig");
const terminal = @import("../terminal.zig");

// This file intentionally stays pure Zig and does not know about TOML, AppKit,
// or global-hotkey registration. Keeping the resolver here lets us test the
// user-facing keybinding rules before platform event code starts calling them.

pub const KeyBindingError = error{
    EmptyChord,
    EmptyChordPart,
    DuplicateModifier,
    MissingKey,
    MultipleKeys,
    UnknownChordPart,
    InvalidFunctionKey,
    DuplicateAppBinding,
    DuplicateTerminalBinding,
    AppTerminalBindingConflict,
    InvalidControlKey,
};

pub const KeyName = union(enum) {
    char: u21,
    enter,
    escape,
    tab,
    backspace,
    delete,
    insert,
    home,
    end,
    page_up,
    page_down,
    arrow_up,
    arrow_down,
    arrow_left,
    arrow_right,
    function: u8,

    pub fn eql(self: KeyName, other: KeyName) bool {
        return switch (self) {
            .char => |value| other == .char and other.char == value,
            .enter => other == .enter,
            .escape => other == .escape,
            .tab => other == .tab,
            .backspace => other == .backspace,
            .delete => other == .delete,
            .insert => other == .insert,
            .home => other == .home,
            .end => other == .end,
            .page_up => other == .page_up,
            .page_down => other == .page_down,
            .arrow_up => other == .arrow_up,
            .arrow_down => other == .arrow_down,
            .arrow_left => other == .arrow_left,
            .arrow_right => other == .arrow_right,
            .function => |value| other == .function and other.function == value,
        };
    }
};

pub const KeyChord = struct {
    modifiers: terminal.ModifierSet = .{},
    key: KeyName,

    pub fn parse(raw: []const u8) KeyBindingError!KeyChord {
        // The parser accepts the human config spelling first. Platform-specific
        // key events are normalized later with fromKeyEvent so config files and
        // AppKit do not need to share string parsing code.
        if (raw.len == 0) return error.EmptyChord;

        var modifiers: terminal.ModifierSet = .{};
        var key: ?KeyName = null;
        var parts = std.mem.splitScalar(u8, raw, '+');
        while (parts.next()) |part| {
            if (part.len == 0) return error.EmptyChordPart;
            if (parseModifier(part)) |modifier| {
                try setModifier(&modifiers, modifier);
                continue;
            }

            const parsed_key = try parseKey(part);
            if (key != null) return error.MultipleKeys;
            key = parsed_key;
        }

        return .{
            .modifiers = modifiers,
            .key = key orelse return error.MissingKey,
        };
    }

    pub fn fromKeyEvent(event: terminal.KeyEvent) ?KeyChord {
        return .{
            .modifiers = event.modifiers,
            .key = keyNameFromTerminalKey(event.key) orelse return null,
        };
    }

    pub fn eql(self: KeyChord, other: KeyChord) bool {
        return std.meta.eql(self.modifiers, other.modifiers) and self.key.eql(other.key);
    }
};

pub const TerminalInputMacro = union(enum) {
    send_control: u21,
    send_text: []const u8,
    send_escape_sequence: []const u8,

    pub fn bytes(self: TerminalInputMacro, buffer: *[terminal.input.encoded_key_buffer_len]u8) KeyBindingError![]const u8 {
        // Terminal macros produce bytes, not AppAction values. That separation
        // prevents a shortcut like Cmd+B from accidentally doing both "new tab"
        // and "send Ctrl+B to the shell".
        return switch (self) {
            .send_control => |codepoint| blk: {
                buffer[0] = terminal.input.controlByte(codepoint) catch return error.InvalidControlKey;
                break :blk buffer[0..1];
            },
            .send_text => |text| text,
            .send_escape_sequence => |sequence| sequence,
        };
    }
};

pub const AppBinding = struct {
    chord: KeyChord,
    action: action_mod.Action,
};

pub const TerminalBinding = struct {
    chord: KeyChord,
    input: TerminalInputMacro,
};

pub const ResolvedKey = union(enum) {
    app_action: action_mod.Action,
    terminal_input: []const u8,
    ignored,
};

/// 빌트인 기본 terminal 바인딩 — macOS 줄 편집 관례를 셸 시퀀스로 매핑한다(Ghostty 기본 keybind와
/// 동작 일치). 흩어진 특수 케이스(Swift 하드코딩, ad-hoc 분기) 대신 한 테이블(데이터)로 둔다.
/// resolve 순서: 사용자 config 바인딩(override 가능) → 이 빌트인 → "안 묶인 Cmd → ignored" fallthrough.
/// 빌트인을 Cmd-무시보다 먼저 봐야 Cmd 편집 조합이 전부 ignored로 새지 않는다. KeyChord.eql이
/// modifier를 정확히 비교하므로 Cmd+Backspace만 매칭한다(Cmd+Shift+Backspace 등은 안 됨).
/// Option+Backspace(단어 삭제 `\x1b\x7f`)는 encodeKey의 meta-ESC가 이미 처리해 여기 없다.
pub const default_terminal_bindings = [_]TerminalBinding{
    .{ .chord = .{ .modifiers = .{ .command = true }, .key = .backspace }, .input = .{ .send_text = "\x15" } }, // Cmd+Backspace: 줄 시작까지 삭제(Ctrl+U)
    .{ .chord = .{ .modifiers = .{ .command = true }, .key = .arrow_left }, .input = .{ .send_text = "\x01" } }, // Cmd+Left: 줄 시작(Ctrl+A)
    .{ .chord = .{ .modifiers = .{ .command = true }, .key = .arrow_right }, .input = .{ .send_text = "\x05" } }, // Cmd+Right: 줄 끝(Ctrl+E)
    .{ .chord = .{ .modifiers = .{ .option = true }, .key = .arrow_left }, .input = .{ .send_escape_sequence = "\x1bb" } }, // Option+Left: 단어 왼쪽(Meta-b)
    .{ .chord = .{ .modifiers = .{ .option = true }, .key = .arrow_right }, .input = .{ .send_escape_sequence = "\x1bf" } }, // Option+Right: 단어 오른쪽(Meta-f)
};

/// 빌트인 기본 app(탭/창) 바인딩 — Mac 관례를 app action으로 매핑한다(Terminal.app/iTerm2/브라우저
/// 공통: Cmd+T=새 탭). 'T'는 글자라 normalizeEventChar가 대문자로 fold해 Shift 유무와 무관하게
/// 매칭된다(layout 안전). resolve 순서: 사용자 바인딩 → 빌트인 terminal → '''이 빌트인 app''' →
/// Cmd-무시 fallthrough. Cmd+Shift+]/[(다음/이전 탭)은 Shift+문자가 layout마다 달라(`]`→`}`) 별도
/// 처리가 필요해 탭바 UI(클릭 전환)와 함께 후속에서 추가한다.
pub const default_app_bindings = [_]AppBinding{
    .{ .chord = .{ .modifiers = .{ .command = true }, .key = .{ .char = 'T' } }, .action = .new_tab }, // Cmd+T: 새 탭
    .{ .chord = .{ .modifiers = .{ .command = true }, .key = .{ .char = 'W' } }, .action = .close_tab }, // Cmd+W: 활성 탭 닫기(마지막이면 창)
};

pub const KeyBindingResolver = struct {
    app_bindings: []const AppBinding = &.{},
    terminal_bindings: []const TerminalBinding = &.{},

    pub fn validate(self: KeyBindingResolver) KeyBindingError!void {
        // Validation rejects ambiguous config up front. Runtime key handling
        // should be a simple decision, not a place where we guess whether the
        // app or the shell should receive the same chord.
        for (self.app_bindings, 0..) |left, left_index| {
            for (self.app_bindings[left_index + 1 ..]) |right| {
                if (left.chord.eql(right.chord)) return error.DuplicateAppBinding;
            }
            for (self.terminal_bindings) |terminal_binding| {
                if (left.chord.eql(terminal_binding.chord)) return error.AppTerminalBindingConflict;
            }
        }

        for (self.terminal_bindings, 0..) |left, left_index| {
            for (self.terminal_bindings[left_index + 1 ..]) |right| {
                if (left.chord.eql(right.chord)) return error.DuplicateTerminalBinding;
            }
            // A send_control macro whose codepoint has no C0 mapping (e.g. a
            // digit) can only fail when the key is pressed. Validate it up front
            // so a bad binding is a config-load error, not a mid-session key
            // failure. resolve() relies on this so it never has to handle an
            // invalid control codepoint at runtime.
            switch (left.input) {
                .send_control => |codepoint| {
                    _ = terminal.input.controlByte(codepoint) catch return error.InvalidControlKey;
                },
                else => {},
            }
        }
    }

    pub fn resolve(
        self: KeyBindingResolver,
        event: terminal.KeyEvent,
        buffer: *[terminal.input.encoded_key_buffer_len]u8,
        // active surface의 현재 인코딩 모드(DECCKM 등). 매크로 binding엔 영향 없고 fallback
        // encodeKey에만 적용된다 — 모드는 TerminalCore가 추적하고 호출자가 매 키마다 읽어 넘긴다.
        encode_options: terminal.input.EncodeOptions,
    ) !ResolvedKey {
        const chord = KeyChord.fromKeyEvent(event) orelse return .ignored;

        for (self.app_bindings) |binding| {
            if (binding.chord.eql(chord)) return .{ .app_action = binding.action };
        }

        for (self.terminal_bindings) |binding| {
            if (binding.chord.eql(chord)) {
                return .{ .terminal_input = try binding.input.bytes(buffer) };
            }
        }

        // 빌트인 기본 바인딩(macOS 줄 편집). 사용자 바인딩 다음, Cmd-무시 fallthrough 전에 본다 —
        // 안 그러면 Cmd+Backspace/←/→가 아래 .ignored로 새 나간다.
        for (default_terminal_bindings) |binding| {
            if (binding.chord.eql(chord)) {
                return .{ .terminal_input = try binding.input.bytes(buffer) };
            }
        }

        // 빌트인 app 바인딩(Cmd+T=새 탭 등). 사용자 바인딩·빌트인 terminal 다음, Cmd-무시 fallthrough
        // 전에 본다 — 안 그러면 Cmd+T가 아래 .ignored로 새 나가 탭이 안 열린다.
        for (default_app_bindings) |binding| {
            if (binding.chord.eql(chord)) return .{ .app_action = binding.action };
        }

        if (event.modifiers.command) {
            // 여기까지 안 묶인 Cmd 조합은 macOS 앱 단축키다(Cmd+S/Q...). 셸로 raw 글자를 보내면
            // Cmd+S가 's'를 타이핑하므로 무시한다. 편집용 Cmd 조합은 위 빌트인 테이블이 이미 가져간다.
            return .ignored;
        }

        return .{ .terminal_input = try terminal.input.encodeKey(event, buffer, encode_options) };
    }
};

const ModifierName = enum { control, option, shift, command };

fn parseModifier(raw: []const u8) ?ModifierName {
    if (std.ascii.eqlIgnoreCase(raw, "Ctrl")) return .control;
    if (std.ascii.eqlIgnoreCase(raw, "Alt")) return .option;
    if (std.ascii.eqlIgnoreCase(raw, "Shift")) return .shift;
    if (std.ascii.eqlIgnoreCase(raw, "Cmd")) return .command;
    return null;
}

fn setModifier(modifiers: *terminal.ModifierSet, modifier: ModifierName) KeyBindingError!void {
    switch (modifier) {
        .control => {
            if (modifiers.control) return error.DuplicateModifier;
            modifiers.control = true;
        },
        .option => {
            if (modifiers.option) return error.DuplicateModifier;
            modifiers.option = true;
        },
        .shift => {
            if (modifiers.shift) return error.DuplicateModifier;
            modifiers.shift = true;
        },
        .command => {
            if (modifiers.command) return error.DuplicateModifier;
            modifiers.command = true;
        },
    }
}

fn parseKey(raw: []const u8) KeyBindingError!KeyName {
    if (raw.len == 1) {
        const byte = raw[0];
        if (std.ascii.isAlphabetic(byte)) return .{ .char = std.ascii.toUpper(byte) };
        if (std.ascii.isDigit(byte) or isAllowedPunctuation(byte)) return .{ .char = byte };
    }

    if (std.ascii.eqlIgnoreCase(raw, "Esc")) return .escape;
    if (std.ascii.eqlIgnoreCase(raw, "Tab")) return .tab;
    if (std.ascii.eqlIgnoreCase(raw, "Enter")) return .enter;
    if (std.ascii.eqlIgnoreCase(raw, "Space")) return .{ .char = ' ' };
    // '+' is the chord-part separator, so the literal plus key cannot be written
    // inline. Accept the "Plus" spelling so `Cmd+Plus` binds the '+' key.
    if (std.ascii.eqlIgnoreCase(raw, "Plus")) return .{ .char = '+' };
    if (std.ascii.eqlIgnoreCase(raw, "Backspace")) return .backspace;
    if (std.ascii.eqlIgnoreCase(raw, "Delete")) return .delete;
    if (std.ascii.eqlIgnoreCase(raw, "Insert")) return .insert;
    if (std.ascii.eqlIgnoreCase(raw, "Home")) return .home;
    if (std.ascii.eqlIgnoreCase(raw, "End")) return .end;
    if (std.ascii.eqlIgnoreCase(raw, "PageUp")) return .page_up;
    if (std.ascii.eqlIgnoreCase(raw, "PageDown")) return .page_down;
    if (std.ascii.eqlIgnoreCase(raw, "Up")) return .arrow_up;
    if (std.ascii.eqlIgnoreCase(raw, "Down")) return .arrow_down;
    if (std.ascii.eqlIgnoreCase(raw, "Left")) return .arrow_left;
    if (std.ascii.eqlIgnoreCase(raw, "Right")) return .arrow_right;
    if (raw.len >= 2 and (raw[0] == 'F' or raw[0] == 'f')) {
        const value = std.fmt.parseUnsigned(u8, raw[1..], 10) catch return error.InvalidFunctionKey;
        if (value == 0 or value > 24) return error.InvalidFunctionKey;
        return .{ .function = value };
    }

    return error.UnknownChordPart;
}

fn keyNameFromTerminalKey(key: terminal.Key) ?KeyName {
    // terminal.Key가 home/end/insert/delete/page_up/page_down/function 변형을 가지면서, 그 키들의
    // 바인딩이 실제 키 이벤트와 매칭된다(이전엔 죽은 설정이었다). F13~F24는 terminal.Key의 function이
    // 1~12만 물리 키로 들어오므로 설정으론 적되 매칭되지 않을 수 있다(F13+는 후속).
    return switch (key) {
        .char => |codepoint| .{ .char = normalizeEventChar(codepoint) },
        .enter => .enter,
        .escape => .escape,
        .tab => .tab,
        .backspace => .backspace,
        .delete => .delete,
        .insert => .insert,
        .home => .home,
        .end => .end,
        .page_up => .page_up,
        .page_down => .page_down,
        .arrow_up => .arrow_up,
        .arrow_down => .arrow_down,
        .arrow_left => .arrow_left,
        .arrow_right => .arrow_right,
        .function => |n| .{ .function = n },
    };
}

fn normalizeEventChar(codepoint: u21) u21 {
    // Fold ASCII letters to uppercase so a typed 'b' matches a parsed 'B'. parseKey
    // uses std.ascii.toUpper for the same fold; reuse it here so the two paths
    // cannot drift. Non-ASCII codepoints pass through unchanged.
    if (codepoint > std.math.maxInt(u8)) return codepoint;
    return std.ascii.toUpper(@intCast(codepoint));
}

fn isAllowedPunctuation(byte: u8) bool {
    return switch (byte) {
        ',', '.', '/', ';', '\'', '[', ']', '-', '=', '`' => true,
        else => false,
    };
}

test "parses key chords with canonical modifiers and keys" {
    const chord = try KeyChord.parse("ctrl+cmd+,");

    try std.testing.expect(chord.modifiers.control);
    try std.testing.expect(chord.modifiers.command);
    try std.testing.expect(!chord.modifiers.option);
    try std.testing.expect(chord.key.eql(.{ .char = ',' }));

    try std.testing.expect((try KeyChord.parse("Shift+Alt+F13")).key.eql(.{ .function = 13 }));
    try std.testing.expect((try KeyChord.parse("Cmd+B")).key.eql(.{ .char = 'B' }));
}

test "rejects ambiguous key chord strings" {
    try std.testing.expectError(error.DuplicateModifier, KeyChord.parse("Cmd+Cmd+B"));
    try std.testing.expectError(error.UnknownChordPart, KeyChord.parse("Command+B"));
    try std.testing.expectError(error.MissingKey, KeyChord.parse("Ctrl+Cmd"));
    try std.testing.expectError(error.MultipleKeys, KeyChord.parse("Ctrl+B+C"));
    try std.testing.expectError(error.InvalidFunctionKey, KeyChord.parse("F25"));
}

test "parses the literal plus key via the Plus spelling" {
    try std.testing.expect((try KeyChord.parse("Cmd+Plus")).key.eql(.{ .char = '+' }));
    // The bare '+' separator still cannot be a key, so an empty part errors.
    try std.testing.expectError(error.EmptyChordPart, KeyChord.parse("Cmd++"));
}

test "validate rejects a send_control macro with no C0 mapping" {
    // A digit has no control byte; this must fail at config validation, not when
    // the key is later pressed.
    try std.testing.expectError(error.InvalidControlKey, (KeyBindingResolver{
        .terminal_bindings = &.{
            .{ .chord = try KeyChord.parse("Ctrl+1"), .input = .{ .send_control = '1' } },
        },
    }).validate());
}

test "send_control accepts non-letter C0 controls like Ctrl+[" {
    var buffer: [terminal.input.encoded_key_buffer_len]u8 = undefined;
    const resolver: KeyBindingResolver = .{
        .terminal_bindings = &.{
            .{ .chord = try KeyChord.parse("Cmd+E"), .input = .{ .send_control = '[' } },
        },
    };
    try resolver.validate();
    const resolved = try resolver.resolve(.{
        .key = .{ .char = 'e' },
        .modifiers = .{ .command = true },
    }, &buffer, .{});
    try std.testing.expectEqualStrings("\x1b", resolved.terminal_input); // Ctrl+[ == ESC
}

test "unbound Ctrl with an unmapped key types the character instead of erroring" {
    var buffer: [terminal.input.encoded_key_buffer_len]u8 = undefined;
    const resolver: KeyBindingResolver = .{};
    try std.testing.expectEqualStrings(
        "1",
        (try resolver.resolve(.{
            .key = .{ .char = '1' },
            .modifiers = .{ .control = true },
        }, &buffer, .{})).terminal_input,
    );
}

test "resolver prioritizes app actions and blocks conflicting terminal macros" {
    const chord = try KeyChord.parse("Cmd+B");
    const resolver: KeyBindingResolver = .{
        .app_bindings = &.{.{ .chord = chord, .action = .new_tab }},
        .terminal_bindings = &.{.{ .chord = chord, .input = .{ .send_control = 'b' } }},
    };

    try std.testing.expectError(error.AppTerminalBindingConflict, resolver.validate());
}

test "resolver consumes configured app actions before terminal input" {
    var buffer: [terminal.input.encoded_key_buffer_len]u8 = undefined;
    const resolver: KeyBindingResolver = .{
        .app_bindings = &.{.{ .chord = try KeyChord.parse("Cmd+T"), .action = .new_tab }},
    };
    try resolver.validate();

    const resolved = try resolver.resolve(.{
        .key = .{ .char = 't' },
        .modifiers = .{ .command = true },
    }, &buffer, .{});

    try std.testing.expectEqual(action_mod.Action.new_tab, resolved.app_action);
}

test "built-in app binding resolves Cmd+T to new_tab without user config" {
    var buffer: [terminal.input.encoded_key_buffer_len]u8 = undefined;
    const resolver: KeyBindingResolver = .{}; // 사용자 바인딩 없음 — default_app_bindings가 가져가야

    // 글자 't'는 normalizeEventChar가 'T'로 fold하므로 default_app_bindings의 'T'와 매칭(Shift 무관).
    const resolved = try resolver.resolve(.{
        .key = .{ .char = 't' },
        .modifiers = .{ .command = true },
    }, &buffer, .{});
    try std.testing.expectEqual(action_mod.Action.new_tab, resolved.app_action);

    // Cmd+T가 아닌 안 묶인 Cmd 조합은 그대로 ignored(셸로 글자 안 샘).
    try std.testing.expect((try resolver.resolve(.{
        .key = .{ .char = 's' },
        .modifiers = .{ .command = true },
    }, &buffer, .{})) == .ignored);
}

test "built-in app binding resolves Cmd+W to close_tab without user config" {
    var buffer: [terminal.input.encoded_key_buffer_len]u8 = undefined;
    const resolver: KeyBindingResolver = .{};
    // 'w'는 normalizeEventChar가 'W'로 fold → default_app_bindings의 'W'와 매칭(Shift 무관).
    const resolved = try resolver.resolve(.{
        .key = .{ .char = 'w' },
        .modifiers = .{ .command = true },
    }, &buffer, .{});
    try std.testing.expectEqual(action_mod.Action.close_tab, resolved.app_action);
}

test "resolver rejects duplicate app and terminal bindings separately" {
    try std.testing.expectError(error.DuplicateAppBinding, (KeyBindingResolver{
        .app_bindings = &.{
            .{ .chord = try KeyChord.parse("Cmd+T"), .action = .new_tab },
            .{ .chord = try KeyChord.parse("Cmd+T"), .action = .close_tab },
        },
    }).validate());

    try std.testing.expectError(error.DuplicateTerminalBinding, (KeyBindingResolver{
        .terminal_bindings = &.{
            .{ .chord = try KeyChord.parse("F13"), .input = .{ .send_escape_sequence = "\x1b[25~" } },
            .{ .chord = try KeyChord.parse("F13"), .input = .{ .send_text = "duplicate" } },
        },
    }).validate());
}

test "resolver maps focused terminal macro to terminal bytes" {
    var buffer: [terminal.input.encoded_key_buffer_len]u8 = undefined;
    const resolver: KeyBindingResolver = .{
        .terminal_bindings = &.{.{
            .chord = try KeyChord.parse("Cmd+B"),
            .input = .{ .send_control = 'b' },
        }},
    };
    try resolver.validate();

    const resolved = try resolver.resolve(.{
        .key = .{ .char = 'b' },
        .modifiers = .{ .command = true },
    }, &buffer, .{});

    try std.testing.expectEqualStrings("\x02", resolved.terminal_input);
}

test "resolver maps text and escape sequence terminal macros to terminal bytes" {
    var buffer: [terminal.input.encoded_key_buffer_len]u8 = undefined;
    const resolver: KeyBindingResolver = .{
        .terminal_bindings = &.{
            .{ .chord = try KeyChord.parse("Ctrl+Up"), .input = .{ .send_escape_sequence = "\x1b[1;5A" } },
            .{ .chord = try KeyChord.parse("Cmd+1"), .input = .{ .send_text = "one" } },
        },
    };
    try resolver.validate();

    try std.testing.expectEqualStrings(
        "\x1b[1;5A",
        (try resolver.resolve(.{ .key = .arrow_up, .modifiers = .{ .control = true } }, &buffer, .{})).terminal_input,
    );
    try std.testing.expectEqualStrings(
        "one",
        (try resolver.resolve(.{ .key = .{ .char = '1' }, .modifiers = .{ .command = true } }, &buffer, .{})).terminal_input,
    );
}

test "resolver leaves ordinary terminal keys alone and ignores unbound command keys" {
    var buffer: [terminal.input.encoded_key_buffer_len]u8 = undefined;
    const resolver: KeyBindingResolver = .{};

    try std.testing.expectEqualStrings(
        "\x02",
        (try resolver.resolve(.{
            .key = .{ .char = 'b' },
            .modifiers = .{ .control = true },
        }, &buffer, .{})).terminal_input,
    );
    try std.testing.expectEqualStrings(
        "b",
        (try resolver.resolve(.{ .key = .{ .char = 'b' } }, &buffer, .{})).terminal_input,
    );
    try std.testing.expectEqual(
        ResolvedKey.ignored,
        try resolver.resolve(.{
            .key = .{ .char = 's' },
            .modifiers = .{ .command = true },
        }, &buffer, .{}),
    );
}

test "keybind: function/editing keys parse and match real terminal key events" {
    // 설정 표기 파싱
    try std.testing.expect((try KeyChord.parse("Delete")).key.eql(.delete));
    try std.testing.expect((try KeyChord.parse("Home")).key.eql(.home));
    try std.testing.expect((try KeyChord.parse("PageUp")).key.eql(.page_up));
    try std.testing.expect((try KeyChord.parse("Cmd+F5")).key.eql(.{ .function = 5 }));
    // 이제 실제 terminal.Key 이벤트와 매칭된다(이전엔 죽은 설정).
    var buf: [terminal.input.encoded_key_buffer_len]u8 = undefined;
    const resolver = KeyBindingResolver{ .app_bindings = &.{
        .{ .chord = .{ .key = .delete }, .action = .close_tab },
        .{ .chord = .{ .key = .{ .function = 5 } }, .action = .new_tab },
    } };
    const r1 = try resolver.resolve(.{ .key = .delete }, &buf, .{});
    try std.testing.expectEqual(action_mod.Action.close_tab, r1.app_action);
    const r2 = try resolver.resolve(.{ .key = .{ .function = 5 } }, &buf, .{});
    try std.testing.expectEqual(action_mod.Action.new_tab, r2.app_action);
}

test "resolve: built-in macOS line-editing bindings (Cmd/Option) override the ignore-Cmd fallthrough" {
    var buf: [terminal.input.encoded_key_buffer_len]u8 = undefined;
    const r = KeyBindingResolver{}; // 사용자 바인딩 없음 — 빌트인만
    // Cmd 편집 조합 → 셸 시퀀스(예전엔 .ignored로 새던 것).
    try std.testing.expectEqualStrings("\x15", (try r.resolve(.{ .key = .backspace, .modifiers = .{ .command = true } }, &buf, .{})).terminal_input);
    try std.testing.expectEqualStrings("\x01", (try r.resolve(.{ .key = .arrow_left, .modifiers = .{ .command = true } }, &buf, .{})).terminal_input);
    try std.testing.expectEqualStrings("\x05", (try r.resolve(.{ .key = .arrow_right, .modifiers = .{ .command = true } }, &buf, .{})).terminal_input);
    // Option 단어 이동.
    try std.testing.expectEqualStrings("\x1bb", (try r.resolve(.{ .key = .arrow_left, .modifiers = .{ .option = true } }, &buf, .{})).terminal_input);
    try std.testing.expectEqualStrings("\x1bf", (try r.resolve(.{ .key = .arrow_right, .modifiers = .{ .option = true } }, &buf, .{})).terminal_input);
    // 안 묶인 다른 Cmd 조합은 그대로 .ignored.
    try std.testing.expectEqual(ResolvedKey.ignored, try r.resolve(.{ .key = .{ .char = 's' }, .modifiers = .{ .command = true } }, &buf, .{}));
    // 정확한 modifier만 — Cmd+Shift+Backspace는 빌트인 매칭 안 되고 .ignored.
    try std.testing.expectEqual(ResolvedKey.ignored, try r.resolve(.{ .key = .backspace, .modifiers = .{ .command = true, .shift = true } }, &buf, .{}));
    // Option+Backspace는 encodeKey의 meta-ESC(\x1b\x7f)로 — 빌트인 아님.
    try std.testing.expectEqualStrings("\x1b\x7f", (try r.resolve(.{ .key = .backspace, .modifiers = .{ .option = true } }, &buf, .{})).terminal_input);
}

test "resolve: user terminal binding overrides a built-in default" {
    var buf: [terminal.input.encoded_key_buffer_len]u8 = undefined;
    const user = [_]TerminalBinding{
        .{ .chord = .{ .modifiers = .{ .command = true }, .key = .backspace }, .input = .{ .send_text = "X" } },
    };
    const r = KeyBindingResolver{ .terminal_bindings = &user };
    // 사용자 바인딩이 빌트인보다 우선.
    try std.testing.expectEqualStrings("X", (try r.resolve(.{ .key = .backspace, .modifiers = .{ .command = true } }, &buf, .{})).terminal_input);
}
