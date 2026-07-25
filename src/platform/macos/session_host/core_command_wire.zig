const std = @import("std");

pub const max_scrollback_lines: u64 = 100_000; // config SSOT `scrollback.lines`와 같은 제품 상한.
pub const max_scroll_delta: i64 = @intCast(max_scrollback_lines); // 그 이상은 현재 보존 가능한 history 밖이라 의미가 없다.
pub const max_cell_metric_px: u32 = std.math.maxInt(u16); // 악성 u32가 후속 pixel 산술을 넘치지 않게 wire에서 닫는다.

/// GUI와 session host 사이에서 전달하는 backend-neutral core command.
///
/// `session.CoreCommand`를 JSON에 그대로 직렬화하지 않는 이유는 그 타입이 process-local slice와 `usize`를
/// 포함하기 때문이다. wire는 길이와 정수 범위를 고정하고, GUI/host가 이 닫힌 명령 집합을 함께 사용한다.
/// 선택처럼 client-local 투영과 host 콘텐츠 계산을 함께 요구하는 명령은 별도 RPC가 소유하므로 여기 넣지 않는다.
pub const Command = union(enum) {
    scroll: i64,
    scroll_to_bottom,
    scroll_to_abs: u64,
    scroll_to_offset: u64,
    report_focus: bool,
    set_cell_metrics: CellMetrics,
    set_default_colors: DefaultColors,
    set_config_palette: Palette,
    set_max_scrollback: u64,
    set_ambiguous_wide: bool,
    set_emoji_wide: bool,
    set_runtime_config: RuntimeConfig,
    jump_to_prompt: i8,
    /// 비파괴 입력 모드 리셋(⌘⇧R). 인자 없는 명령이라 op 이름만 실린다.
    reset_input_modes,

    pub const CellMetrics = struct {
        width: u32,
        height: u32,
    };

    pub const DefaultColors = struct {
        foreground: u32,
        background: u32,
    };

    /// ANSI 16색 config base. 값은 `0xRRGGBB`, null은 해당 index에 config override가 없다는 뜻이다.
    pub const Palette = [16]?u32;
    pub const RuntimeConfig = struct {
        max_scrollback: u64,
        ambiguous_wide: bool,
        emoji_wide: bool,
        palette: Palette,
        default_colors: DefaultColors,
        cell_metrics: ?CellMetrics,
    };

    /// 구 host도 지원하던 v1 스크롤 명령인가. 나머지는 hello capability가 있는 host에만 보낸다.
    pub fn isLegacyScroll(self: Command) bool {
        return switch (self) {
            .scroll, .scroll_to_bottom, .scroll_to_abs, .scroll_to_offset => true,
            else => false,
        };
    }
};

pub const EncodeError = error{OutOfMemory};

/// `runtime.core_command`의 params JSON을 만든다. 모든 op 이름은 이 모듈의 고정 리터럴이고, palette도 16개로
/// 고정되어 control payload가 protocol cap 아래에 머문다.
pub fn encodeParams(allocator: std.mem.Allocator, stream_id: u64, command: Command) EncodeError![]u8 {
    return switch (command) {
        .scroll => |arg| stringify(allocator, .{ .stream_id = stream_id, .op = "scroll", .arg = arg }),
        .scroll_to_bottom => stringify(allocator, .{ .stream_id = stream_id, .op = "scroll_to_bottom" }),
        .scroll_to_abs => |arg| stringify(allocator, .{ .stream_id = stream_id, .op = "scroll_to_abs", .arg = arg }),
        .scroll_to_offset => |arg| stringify(allocator, .{ .stream_id = stream_id, .op = "scroll_to_offset", .arg = arg }),
        .report_focus => |gained| stringify(allocator, .{ .stream_id = stream_id, .op = "report_focus", .gained = gained }),
        .set_cell_metrics => |metrics| stringify(allocator, .{
            .stream_id = stream_id,
            .op = "set_cell_metrics",
            .width = metrics.width,
            .height = metrics.height,
        }),
        .set_default_colors => |colors| stringify(allocator, .{
            .stream_id = stream_id,
            .op = "set_default_colors",
            .foreground = colors.foreground,
            .background = colors.background,
        }),
        .set_config_palette => |palette| stringify(allocator, .{
            .stream_id = stream_id,
            .op = "set_config_palette",
            .palette = palette,
        }),
        .set_max_scrollback => |lines| stringify(allocator, .{ .stream_id = stream_id, .op = "set_max_scrollback", .lines = lines }),
        .set_ambiguous_wide => |wide| stringify(allocator, .{ .stream_id = stream_id, .op = "set_ambiguous_wide", .wide = wide }),
        .set_emoji_wide => |wide| stringify(allocator, .{ .stream_id = stream_id, .op = "set_emoji_wide", .wide = wide }),
        .set_runtime_config => |config| stringify(allocator, .{
            .stream_id = stream_id,
            .op = "set_runtime_config",
            .lines = config.max_scrollback,
            .ambiguous_wide = config.ambiguous_wide,
            .emoji_wide = config.emoji_wide,
            .palette = config.palette,
            .foreground = config.default_colors.foreground,
            .background = config.default_colors.background,
            .cell_width = if (config.cell_metrics) |metrics| metrics.width else 0,
            .cell_height = if (config.cell_metrics) |metrics| metrics.height else 0,
        }),
        .jump_to_prompt => |direction| stringify(allocator, .{
            .stream_id = stream_id,
            .op = "jump_to_prompt",
            .direction = direction,
        }),
        .reset_input_modes => stringify(allocator, .{
            .stream_id = stream_id,
            .op = "reset_input_modes",
        }),
    };
}

/// server가 이미 파싱한 params object를 닫힌 wire command로 검증한다. 잘못된 타입·범위·palette 길이는
/// `null`로 fail-close해 host core에 부분 명령이 적용되지 않게 한다.
pub fn decodeParams(params: std.json.ObjectMap) ?Command {
    const op = stringField(params, "op") orelse return null;
    if (std.mem.eql(u8, op, "scroll")) {
        const delta = i64Field(params, "arg") orelse return null;
        if (delta < -max_scroll_delta or delta > max_scroll_delta) return null;
        return .{ .scroll = delta };
    }
    if (std.mem.eql(u8, op, "scroll_to_bottom")) return .scroll_to_bottom;
    if (std.mem.eql(u8, op, "scroll_to_abs")) {
        return .{ .scroll_to_abs = u64Field(params, "arg") orelse return null };
    }
    if (std.mem.eql(u8, op, "scroll_to_offset")) {
        return .{ .scroll_to_offset = u64Field(params, "arg") orelse return null };
    }
    if (std.mem.eql(u8, op, "report_focus")) {
        return .{ .report_focus = boolField(params, "gained") orelse return null };
    }
    if (std.mem.eql(u8, op, "set_cell_metrics")) {
        const width = u32Field(params, "width") orelse return null;
        const height = u32Field(params, "height") orelse return null;
        if (width == 0 or height == 0 or width > max_cell_metric_px or height > max_cell_metric_px) return null;
        return .{ .set_cell_metrics = .{ .width = width, .height = height } };
    }
    if (std.mem.eql(u8, op, "set_default_colors")) {
        const foreground = rgbField(params, "foreground") orelse return null;
        const background = rgbField(params, "background") orelse return null;
        return .{ .set_default_colors = .{ .foreground = foreground, .background = background } };
    }
    if (std.mem.eql(u8, op, "set_config_palette")) {
        return .{ .set_config_palette = paletteField(params) orelse return null };
    }
    if (std.mem.eql(u8, op, "set_max_scrollback")) {
        const lines = u64Field(params, "lines") orelse return null;
        if (lines > max_scrollback_lines) return null;
        return .{ .set_max_scrollback = lines };
    }
    if (std.mem.eql(u8, op, "set_ambiguous_wide")) {
        return .{ .set_ambiguous_wide = boolField(params, "wide") orelse return null };
    }
    if (std.mem.eql(u8, op, "set_emoji_wide")) {
        return .{ .set_emoji_wide = boolField(params, "wide") orelse return null };
    }
    if (std.mem.eql(u8, op, "set_runtime_config")) {
        return .{ .set_runtime_config = decodeRuntimeConfig(params) orelse return null };
    }
    if (std.mem.eql(u8, op, "reset_input_modes")) return .reset_input_modes;
    if (std.mem.eql(u8, op, "jump_to_prompt")) {
        const direction = i64Field(params, "direction") orelse return null;
        if (direction != -1 and direction != 1) return null;
        return .{ .jump_to_prompt = @intCast(direction) };
    }
    return null;
}

/// `runtime.spawn_full.runtime_config`와 `set_runtime_config`가 공유하는 bounded snapshot decoder.
/// caller가 넘긴 object는 `lines/ambiguous_wide/...` 필드를 직접 포함한다.
pub fn decodeRuntimeConfig(params: std.json.ObjectMap) ?Command.RuntimeConfig {
    const lines = u64Field(params, "lines") orelse return null;
    if (lines > max_scrollback_lines) return null;
    const cell_width = u32Field(params, "cell_width") orelse return null;
    const cell_height = u32Field(params, "cell_height") orelse return null;
    const cell_metrics: ?Command.CellMetrics = if (cell_width == 0 and cell_height == 0)
        null
    else if (cell_width != 0 and cell_height != 0 and cell_width <= max_cell_metric_px and cell_height <= max_cell_metric_px)
        .{ .width = cell_width, .height = cell_height }
    else
        return null;
    return .{
        .max_scrollback = lines,
        .ambiguous_wide = boolField(params, "ambiguous_wide") orelse return null,
        .emoji_wide = boolField(params, "emoji_wide") orelse return null,
        .palette = paletteField(params) orelse return null,
        .default_colors = .{
            .foreground = rgbField(params, "foreground") orelse return null,
            .background = rgbField(params, "background") orelse return null,
        },
        .cell_metrics = cell_metrics,
    };
}

fn stringify(allocator: std.mem.Allocator, value: anytype) EncodeError![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    json.write(value) catch return error.OutOfMemory;
    return allocator.dupe(u8, out.written()) catch return error.OutOfMemory;
}

fn stringField(params: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (params.get(key) orelse return null) {
        .string => |value| value,
        else => null,
    };
}

fn boolField(params: std.json.ObjectMap, key: []const u8) ?bool {
    return switch (params.get(key) orelse return null) {
        .bool => |value| value,
        else => null,
    };
}

fn i64Field(params: std.json.ObjectMap, key: []const u8) ?i64 {
    return switch (params.get(key) orelse return null) {
        .integer => |value| value,
        else => null,
    };
}

fn u64Field(params: std.json.ObjectMap, key: []const u8) ?u64 {
    const value = i64Field(params, key) orelse return null;
    return if (value >= 0) @intCast(value) else null;
}

fn u32Field(params: std.json.ObjectMap, key: []const u8) ?u32 {
    const value = u64Field(params, key) orelse return null;
    return if (value <= std.math.maxInt(u32)) @intCast(value) else null;
}

fn rgbField(params: std.json.ObjectMap, key: []const u8) ?u32 {
    const value = u32Field(params, key) orelse return null;
    return if (value <= 0xFF_FF_FF) value else null;
}

fn paletteField(params: std.json.ObjectMap) ?Command.Palette {
    const values = switch (params.get("palette") orelse return null) {
        .array => |items| items.items,
        else => return null,
    };
    if (values.len != 16) return null;
    var palette: Command.Palette = .{null} ** 16;
    for (values, 0..) |value, index| {
        palette[index] = switch (value) {
            .null => null,
            .integer => |rgb| if (rgb >= 0 and rgb <= 0xFF_FF_FF) @intCast(rgb) else return null,
            else => return null,
        };
    }
    return palette;
}

fn decodeEncoded(allocator: std.mem.Allocator, stream_id: u64, command: Command) !Command {
    const encoded = try encodeParams(allocator, stream_id, command);
    defer allocator.free(encoded);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, encoded, .{});
    defer parsed.deinit();
    return decodeParams(switch (parsed.value) {
        .object => |object| object,
        else => return error.TestUnexpectedResult,
    }) orelse error.TestUnexpectedResult;
}

test "core command wire round-trips every bounded command" {
    const allocator = std.testing.allocator;
    var palette: Command.Palette = .{null} ** 16;
    palette[0] = 0x12_34_56;
    palette[15] = 0xAB_CD_EF;

    const cases = [_]Command{
        .{ .scroll = -3 },
        .scroll_to_bottom,
        .{ .scroll_to_abs = 123 },
        .{ .scroll_to_offset = 77 },
        .{ .report_focus = true },
        .{ .set_cell_metrics = .{ .width = 18, .height = 36 } },
        .{ .set_default_colors = .{ .foreground = 0x11_22_33, .background = 0x44_55_66 } },
        .{ .set_config_palette = palette },
        .{ .set_max_scrollback = 20_000 },
        .{ .set_ambiguous_wide = true },
        .{ .set_emoji_wide = false },
        .{ .set_runtime_config = .{
            .max_scrollback = 50_000,
            .ambiguous_wide = true,
            .emoji_wide = false,
            .palette = palette,
            .default_colors = .{ .foreground = 0x11_22_33, .background = 0x44_55_66 },
            .cell_metrics = .{ .width = 18, .height = 36 },
        } },
        .{ .jump_to_prompt = -1 },
    };
    for (cases) |command| {
        const decoded = try decodeEncoded(allocator, 42, command);
        try std.testing.expectEqualDeep(command, decoded);
    }
}

test "core command wire rejects malformed bounded values without partial command" {
    const allocator = std.testing.allocator;
    const malformed = [_][]const u8{
        "{\"op\":\"set_cell_metrics\",\"width\":0,\"height\":16}",
        "{\"op\":\"set_cell_metrics\",\"width\":65536,\"height\":16}",
        "{\"op\":\"scroll\",\"arg\":9223372036854775807}",
        "{\"op\":\"set_default_colors\",\"foreground\":16777216,\"background\":0}",
        "{\"op\":\"set_config_palette\",\"palette\":[1,2]}",
        "{\"op\":\"set_config_palette\",\"palette\":[16777216,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null]}",
        "{\"op\":\"set_max_scrollback\",\"lines\":-1}",
        "{\"op\":\"set_max_scrollback\",\"lines\":100001}",
        "{\"op\":\"set_runtime_config\",\"lines\":1,\"ambiguous_wide\":true,\"emoji_wide\":true,\"palette\":[null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null],\"foreground\":0,\"background\":0,\"cell_width\":8,\"cell_height\":0}",
        "{\"op\":\"jump_to_prompt\",\"direction\":0}",
        "{\"op\":\"unknown\",\"arg\":1}",
    };
    for (malformed) |json| {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
        defer parsed.deinit();
        const params = switch (parsed.value) {
            .object => |object| object,
            else => return error.TestUnexpectedResult,
        };
        try std.testing.expectEqual(@as(?Command, null), decodeParams(params));
    }
}
