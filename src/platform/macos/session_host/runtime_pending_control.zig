//! Canonical queued-control storage for a RemoteRuntime.

const std = @import("std");
const core_command_wire = @import("core_command_wire.zig");
const control_types = @import("runtime_control_types.zig");

pub const RawQueuedRuntimeControl = extern struct {
    barrier: u64,
    control: control_types.RuntimeControl,

    pub fn scrollToBottom(barrier: usize) ?RawQueuedRuntimeControl {
        return .{ .barrier = std.math.cast(u64, barrier) orelse return null, .control = .scrollToBottom() };
    }

    pub fn coreCommand(barrier: usize, command: core_command_wire.Command) ?RawQueuedRuntimeControl {
        return .{
            .barrier = std.math.cast(u64, barrier) orelse return null,
            .control = .coreCommand(projectCoreCommand(command)),
        };
    }

    pub fn observationProbe(barrier: usize, nonce: u64) ?RawQueuedRuntimeControl {
        if (nonce == 0) return null;
        return .{
            .barrier = std.math.cast(u64, barrier) orelse return null,
            .control = .observationProbe(nonce),
        };
    }
};

pub const Decoded = struct {
    barrier: u64,
    control: control_types.ValidatedRuntimeControl,
};

pub fn decode(raw: *const RawQueuedRuntimeControl) ?Decoded {
    return .{ .barrier = raw.barrier, .control = raw.control.decode() orelse return null };
}

pub fn projectCoreCommand(command: core_command_wire.Command) control_types.CoreCommandRequest {
    return switch (command) {
        .scroll => |v| .{ .scroll = v },
        .scroll_to_bottom => .scroll_to_bottom,
        .scroll_to_abs => |v| .{ .scroll_to_abs = v },
        .scroll_to_offset => |v| .{ .scroll_to_offset = v },
        .report_focus => |v| .{ .report_focus = v },
        .set_cell_metrics => |v| .{ .set_cell_metrics = .{ .width = v.width, .height = v.height } },
        .set_default_colors => |v| .{ .set_default_colors = .{ .foreground = v.foreground, .background = v.background } },
        .set_config_palette => |v| .{ .set_config_palette = v },
        .set_max_scrollback => |v| .{ .set_max_scrollback = v },
        .set_ambiguous_wide => |v| .{ .set_ambiguous_wide = v },
        .set_emoji_wide => |v| .{ .set_emoji_wide = v },
        .set_default_cursor_shape => |v| .{ .set_default_cursor_shape = v },
        .set_runtime_config => |v| .{ .set_runtime_config = .{
            .max_scrollback = v.max_scrollback,
            .ambiguous_wide = v.ambiguous_wide,
            .emoji_wide = v.emoji_wide,
            .palette = v.palette,
            .foreground = v.default_colors.foreground,
            .background = v.default_colors.background,
            .cell_width = if (v.cell_metrics) |m| m.width else 0,
            .cell_height = if (v.cell_metrics) |m| m.height else 0,
            .cursor_shape = v.cursor_shape,
        } },
        .jump_to_prompt => |v| .{ .jump_to_prompt = v },
        .clear_screen => .clear_screen,
        .reset_input_modes => .reset_input_modes,
        .selection_start => |v| .{ .selection_start = .{ .row = v.row, .col = v.col, .block = v.block } },
        .selection_extend => |v| .{ .selection_extend = .{ .row = v.row, .col = v.col } },
        .selection_extend_or_collapse => |v| .{ .selection_extend_or_collapse = .{ .row = v.row, .col = v.col } },
        .selection_scroll_and_extend => |v| .{ .selection_scroll_and_extend = .{ .row = v.row, .col = v.col, .delta = v.delta } },
        .selection_clear => .selection_clear,
    };
}

pub fn toCoreCommand(command: control_types.CoreCommandRequest) core_command_wire.Command {
    return switch (command) {
        .scroll => |v| .{ .scroll = v },
        .scroll_to_bottom => .scroll_to_bottom,
        .scroll_to_abs => |v| .{ .scroll_to_abs = v },
        .scroll_to_offset => |v| .{ .scroll_to_offset = v },
        .report_focus => |v| .{ .report_focus = v },
        .set_cell_metrics => |v| .{ .set_cell_metrics = .{ .width = v.width, .height = v.height } },
        .set_default_colors => |v| .{ .set_default_colors = .{ .foreground = v.foreground, .background = v.background } },
        .set_config_palette => |v| .{ .set_config_palette = v },
        .set_max_scrollback => |v| .{ .set_max_scrollback = v },
        .set_ambiguous_wide => |v| .{ .set_ambiguous_wide = v },
        .set_emoji_wide => |v| .{ .set_emoji_wide = v },
        .set_default_cursor_shape => |v| .{ .set_default_cursor_shape = v },
        .set_runtime_config => |v| .{ .set_runtime_config = .{
            .max_scrollback = v.max_scrollback,
            .ambiguous_wide = v.ambiguous_wide,
            .emoji_wide = v.emoji_wide,
            .palette = v.palette,
            .default_colors = .{ .foreground = v.foreground, .background = v.background },
            .cell_metrics = if (v.cell_width == 0 and v.cell_height == 0) null else .{ .width = v.cell_width, .height = v.cell_height },
            .cursor_shape = v.cursor_shape,
        } },
        .jump_to_prompt => |v| .{ .jump_to_prompt = v },
        .clear_screen => .clear_screen,
        .reset_input_modes => .reset_input_modes,
        .selection_start => |v| .{ .selection_start = .{ .row = v.row, .col = v.col, .block = v.block } },
        .selection_extend => |v| .{ .selection_extend = .{ .row = v.row, .col = v.col } },
        .selection_extend_or_collapse => |v| .{ .selection_extend_or_collapse = .{ .row = v.row, .col = v.col } },
        .selection_scroll_and_extend => |v| .{ .selection_scroll_and_extend = .{ .row = v.row, .col = v.col, .delta = v.delta } },
        .selection_clear => .selection_clear,
    };
}

test "C3-3b2b3 integration queued controls use checked barriers and preserve semantic commands" {
    const raw = RawQueuedRuntimeControl.coreCommand(17, .{ .report_focus = true }).?;
    const value = decode(&raw).?;
    try std.testing.expectEqual(@as(u64, 17), value.barrier);
    try std.testing.expect(toCoreCommand(value.control.core_command).report_focus);
}

test "P4 async observation probe retains input barrier and nonce" {
    const raw = RawQueuedRuntimeControl.observationProbe(23, 0xBEEF).?;
    const value = decode(&raw).?;
    try std.testing.expectEqual(@as(u64, 23), value.barrier);
    try std.testing.expectEqual(@as(u64, 0xBEEF), value.control.observation_probe);
    try std.testing.expect(RawQueuedRuntimeControl.observationProbe(23, 0) == null);
}
