//! Pointer-free control values shared by RemoteRuntime and generation attachments.
//!
//! Raw discriminators are validated before an extern-union payload is read. Keeping this codec
//! below both owners prevents either side from inventing a second control representation.

const std = @import("std");

pub const CoreCommandRequest = union(enum) {
    scroll: i64,
    scroll_to_bottom,
    scroll_to_abs: u64,
    scroll_to_offset: u64,
    report_focus: bool,
    set_cell_metrics: struct { width: u32, height: u32 },
    set_default_colors: struct { foreground: u32, background: u32 },
    set_config_palette: [16]?u32,
    set_max_scrollback: u64,
    set_ambiguous_wide: bool,
    set_emoji_wide: bool,
    set_default_cursor_shape: u8,
    set_runtime_config: struct {
        max_scrollback: u64,
        ambiguous_wide: bool,
        emoji_wide: bool,
        palette: [16]?u32,
        foreground: u32,
        background: u32,
        cell_width: u32,
        cell_height: u32,
        cursor_shape: u8,
    },
    jump_to_prompt: i8,
    reset_input_modes,
};

pub const RawOptionalU32 = extern struct { present: u8, value: u32 };
pub const RawRuntimeConfig = extern struct {
    max_scrollback: u64,
    ambiguous_wide: u8,
    emoji_wide: u8,
    palette: [16]RawOptionalU32,
    foreground: u32,
    background: u32,
    cell_width: u32,
    cell_height: u32,
    cursor_shape: u8,
};
pub const RawCorePayload = extern union {
    empty: u8,
    scroll: i64,
    unsigned: u64,
    flag: u8,
    cell_metrics: extern struct { width: u32, height: u32 },
    colors: extern struct { foreground: u32, background: u32 },
    palette: [16]RawOptionalU32,
    shape: u8,
    runtime_config: RawRuntimeConfig,
    direction: i8,
};
pub const RawCoreCommand = extern struct { tag: u8, payload: RawCorePayload };
pub const RuntimeControlTag = enum(u8) { scroll_to_bottom, core_command };
pub const RawRuntimeControlPayload = extern union {
    empty: u8,
    core_command: RawCoreCommand,
};

pub const RuntimeControl = extern struct {
    tag: u8,
    payload: RawRuntimeControlPayload,

    pub fn scrollToBottom() RuntimeControl {
        var result: RuntimeControl = std.mem.zeroes(RuntimeControl);
        result.tag = @intFromEnum(RuntimeControlTag.scroll_to_bottom);
        return result;
    }

    pub fn coreCommand(command: CoreCommandRequest) RuntimeControl {
        var result: RuntimeControl = std.mem.zeroes(RuntimeControl);
        result.tag = @intFromEnum(RuntimeControlTag.core_command);
        encodeRawCoreCommandInto(&result.payload.core_command, command);
        return result;
    }

    pub fn decode(self: *const RuntimeControl) ?ValidatedRuntimeControl {
        return switch (self.tag) {
            @intFromEnum(RuntimeControlTag.scroll_to_bottom) => .scroll_to_bottom,
            @intFromEnum(RuntimeControlTag.core_command) => .{
                .core_command = decodeRawCoreCommand(&self.payload.core_command) orelse return null,
            },
            else => null,
        };
    }
};

pub const ValidatedRuntimeControl = union(RuntimeControlTag) {
    scroll_to_bottom,
    core_command: CoreCommandRequest,
};

fn encodeRawOptional(value: ?u32) RawOptionalU32 {
    return if (value) |color|
        .{ .present = 1, .value = color }
    else
        .{ .present = 0, .value = 0 };
}

fn encodeRawPalette(values: [16]?u32) [16]RawOptionalU32 {
    var result: [16]RawOptionalU32 = undefined;
    for (&result, values) |*out, value| out.* = encodeRawOptional(value);
    return result;
}

fn decodeRawPalette(values: *const [16]RawOptionalU32) ?[16]?u32 {
    var result: [16]?u32 = undefined;
    for (values, &result) |value, *out| {
        out.* = switch (value.present) {
            0 => null,
            1 => value.value,
            else => return null,
        };
    }
    return result;
}

pub fn encodeRawCoreCommandInto(out: *RawCoreCommand, value: CoreCommandRequest) void {
    out.* = std.mem.zeroes(RawCoreCommand);
    const Tag = std.meta.Tag(CoreCommandRequest);
    switch (value) {
        .scroll => |arg| {
            out.tag = @intFromEnum(Tag.scroll);
            out.payload.scroll = arg;
        },
        .scroll_to_bottom => out.tag = @intFromEnum(Tag.scroll_to_bottom),
        .scroll_to_abs => |arg| {
            out.tag = @intFromEnum(Tag.scroll_to_abs);
            out.payload.unsigned = arg;
        },
        .scroll_to_offset => |arg| {
            out.tag = @intFromEnum(Tag.scroll_to_offset);
            out.payload.unsigned = arg;
        },
        .report_focus => |flag| {
            out.tag = @intFromEnum(Tag.report_focus);
            out.payload.flag = @intFromBool(flag);
        },
        .set_cell_metrics => |v| {
            out.tag = @intFromEnum(Tag.set_cell_metrics);
            out.payload.cell_metrics = .{ .width = v.width, .height = v.height };
        },
        .set_default_colors => |v| {
            out.tag = @intFromEnum(Tag.set_default_colors);
            out.payload.colors = .{ .foreground = v.foreground, .background = v.background };
        },
        .set_config_palette => |v| {
            out.tag = @intFromEnum(Tag.set_config_palette);
            out.payload.palette = encodeRawPalette(v);
        },
        .set_max_scrollback => |v| {
            out.tag = @intFromEnum(Tag.set_max_scrollback);
            out.payload.unsigned = v;
        },
        .set_ambiguous_wide => |v| {
            out.tag = @intFromEnum(Tag.set_ambiguous_wide);
            out.payload.flag = @intFromBool(v);
        },
        .set_emoji_wide => |v| {
            out.tag = @intFromEnum(Tag.set_emoji_wide);
            out.payload.flag = @intFromBool(v);
        },
        .set_default_cursor_shape => |v| {
            out.tag = @intFromEnum(Tag.set_default_cursor_shape);
            out.payload.shape = v;
        },
        .set_runtime_config => |v| {
            out.tag = @intFromEnum(Tag.set_runtime_config);
            out.payload.runtime_config = .{
                .max_scrollback = v.max_scrollback,
                .ambiguous_wide = @intFromBool(v.ambiguous_wide),
                .emoji_wide = @intFromBool(v.emoji_wide),
                .palette = encodeRawPalette(v.palette),
                .foreground = v.foreground,
                .background = v.background,
                .cell_width = v.cell_width,
                .cell_height = v.cell_height,
                .cursor_shape = v.cursor_shape,
            };
        },
        .jump_to_prompt => |v| {
            out.tag = @intFromEnum(Tag.jump_to_prompt);
            out.payload.direction = v;
        },
        .reset_input_modes => out.tag = @intFromEnum(Tag.reset_input_modes),
    }
}

pub fn encodeRawCoreCommand(value: CoreCommandRequest) RawCoreCommand {
    var result: RawCoreCommand = undefined;
    encodeRawCoreCommandInto(&result, value);
    return result;
}

pub fn decodeRawCoreCommand(raw: *const RawCoreCommand) ?CoreCommandRequest {
    const Tag = std.meta.Tag(CoreCommandRequest);
    return switch (raw.tag) {
        @intFromEnum(Tag.scroll) => .{ .scroll = raw.payload.scroll },
        @intFromEnum(Tag.scroll_to_bottom) => .scroll_to_bottom,
        @intFromEnum(Tag.scroll_to_abs) => .{ .scroll_to_abs = raw.payload.unsigned },
        @intFromEnum(Tag.scroll_to_offset) => .{ .scroll_to_offset = raw.payload.unsigned },
        @intFromEnum(Tag.report_focus) => if (raw.payload.flag <= 1) .{ .report_focus = raw.payload.flag == 1 } else null,
        @intFromEnum(Tag.set_cell_metrics) => .{ .set_cell_metrics = .{ .width = raw.payload.cell_metrics.width, .height = raw.payload.cell_metrics.height } },
        @intFromEnum(Tag.set_default_colors) => .{ .set_default_colors = .{ .foreground = raw.payload.colors.foreground, .background = raw.payload.colors.background } },
        @intFromEnum(Tag.set_config_palette) => .{ .set_config_palette = decodeRawPalette(&raw.payload.palette) orelse return null },
        @intFromEnum(Tag.set_max_scrollback) => .{ .set_max_scrollback = raw.payload.unsigned },
        @intFromEnum(Tag.set_ambiguous_wide) => if (raw.payload.flag <= 1) .{ .set_ambiguous_wide = raw.payload.flag == 1 } else null,
        @intFromEnum(Tag.set_emoji_wide) => if (raw.payload.flag <= 1) .{ .set_emoji_wide = raw.payload.flag == 1 } else null,
        @intFromEnum(Tag.set_default_cursor_shape) => .{ .set_default_cursor_shape = raw.payload.shape },
        @intFromEnum(Tag.set_runtime_config) => blk: {
            const v = raw.payload.runtime_config;
            if (v.ambiguous_wide > 1 or v.emoji_wide > 1) break :blk null;
            break :blk .{ .set_runtime_config = .{
                .max_scrollback = v.max_scrollback,
                .ambiguous_wide = v.ambiguous_wide == 1,
                .emoji_wide = v.emoji_wide == 1,
                .palette = decodeRawPalette(&v.palette) orelse break :blk null,
                .foreground = v.foreground,
                .background = v.background,
                .cell_width = v.cell_width,
                .cell_height = v.cell_height,
                .cursor_shape = v.cursor_shape,
            } };
        },
        @intFromEnum(Tag.jump_to_prompt) => .{ .jump_to_prompt = raw.payload.direction },
        @intFromEnum(Tag.reset_input_modes) => .reset_input_modes,
        else => null,
    };
}

test "C3-3b2b3 integration runtime control raw discriminators fail closed and encoders zero backing" {
    var outer = RuntimeControl.scrollToBottom();
    var valid_outer: usize = 0;
    for (0..256) |raw| {
        outer.tag = @intCast(raw);
        if (outer.decode() != null) valid_outer += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), valid_outer);

    var nested = RuntimeControl.coreCommand(.scroll_to_bottom);
    var valid_nested: usize = 0;
    for (0..256) |raw| {
        nested.payload.core_command.tag = @intCast(raw);
        if (nested.decode() != null) valid_nested += 1;
    }
    try std.testing.expectEqual(@as(usize, @typeInfo(CoreCommandRequest).@"union".fields.len), valid_nested);

    const zeroed = RuntimeControl.coreCommand(.scroll_to_bottom);
    const bytes = std.mem.asBytes(&zeroed);
    const outer_offset = @offsetOf(RuntimeControl, "tag");
    const core_offset = @offsetOf(RuntimeControl, "payload") + @offsetOf(RawCoreCommand, "tag");
    for (bytes, 0..) |byte, index| {
        if (index == outer_offset or index == core_offset) continue;
        try std.testing.expectEqual(@as(u8, 0), byte);
    }
}
