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

        if (event.modifiers.command) {
            // Unbound Cmd combinations are app-level key events on macOS. Sending
            // the raw character to the shell would make shortcuts like Cmd+S
            // unexpectedly type "s" into the terminal.
            return .ignored;
        }

        return .{ .terminal_input = try terminal.input.encodeKey(event, buffer) };
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
    // KNOWN LIMITATION: KeyName has .delete and .function (F1-F24) so configs can
    // parse them, but terminal.Key (the normalized runtime key event) has no such
    // variants yet, so this function can never produce them. A binding on
    // `Delete` or `F13` therefore parses and validates but can never match a real
    // key event — it is dead config until terminal.Key gains those variants and
    // their byte encodings. Tracked in docs/key-input-and-shortcuts.md.
    return switch (key) {
        .char => |codepoint| .{ .char = normalizeEventChar(codepoint) },
        .enter => .enter,
        .escape => .escape,
        .tab => .tab,
        .backspace => .backspace,
        .arrow_up => .arrow_up,
        .arrow_down => .arrow_down,
        .arrow_left => .arrow_left,
        .arrow_right => .arrow_right,
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
    }, &buffer);
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
        }, &buffer)).terminal_input,
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
    }, &buffer);

    try std.testing.expectEqual(action_mod.Action.new_tab, resolved.app_action);
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
    }, &buffer);

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
        (try resolver.resolve(.{ .key = .arrow_up, .modifiers = .{ .control = true } }, &buffer)).terminal_input,
    );
    try std.testing.expectEqualStrings(
        "one",
        (try resolver.resolve(.{ .key = .{ .char = '1' }, .modifiers = .{ .command = true } }, &buffer)).terminal_input,
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
        }, &buffer)).terminal_input,
    );
    try std.testing.expectEqualStrings(
        "b",
        (try resolver.resolve(.{ .key = .{ .char = 'b' } }, &buffer)).terminal_input,
    );
    try std.testing.expectEqual(
        ResolvedKey.ignored,
        try resolver.resolve(.{
            .key = .{ .char = 's' },
            .modifiers = .{ .command = true },
        }, &buffer),
    );
}
