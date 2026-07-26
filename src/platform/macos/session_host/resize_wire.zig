//! `runtime.resized` full-state event의 strict decoder.

const std = @import("std");

/// `std.json.Value.integer`와 모든 현재 MRSH JSON adapter가 lossless로 운반하는 counter 상한.
pub const max_counter: u64 = @intCast(std.math.maxInt(i64));

pub const Event = struct {
    runtime_id: u128,
    cols: u16,
    rows: u16,
    resize_generation: u64,
};

pub const ParseError = error{ OutOfMemory, Invalid };

pub fn parseEvent(
    allocator: std.mem.Allocator,
    payload: []const u8,
) ParseError!Event {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch |err|
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.Invalid,
        };
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |value| value,
        else => return error.Invalid,
    };
    if (root.count() != 2) return error.Invalid;
    const event = string(root.get("event") orelse return error.Invalid) orelse
        return error.Invalid;
    if (!std.mem.eql(u8, event, "runtime.resized")) return error.Invalid;
    const data = switch (root.get("data") orelse return error.Invalid) {
        .object => |value| value,
        else => return error.Invalid,
    };
    if (data.count() != 5) return error.Invalid;
    const runtime_text = string(data.get("runtime_id") orelse return error.Invalid) orelse
        return error.Invalid;
    const runtime_id = parseHex128(runtime_text) orelse return error.Invalid;
    const cols = unsigned(u16, data.get("cols") orelse return error.Invalid) orelse
        return error.Invalid;
    const rows = unsigned(u16, data.get("rows") orelse return error.Invalid) orelse
        return error.Invalid;
    const generation = unsigned(
        u64,
        data.get("resize_generation") orelse return error.Invalid,
    ) orelse return error.Invalid;
    const reason = string(data.get("reason") orelse return error.Invalid) orelse
        return error.Invalid;
    if (runtime_id == 0 or cols < 2 or rows == 0 or generation == 0 or
        !std.mem.eql(u8, reason, "controller"))
        return error.Invalid;
    return .{
        .runtime_id = runtime_id,
        .cols = cols,
        .rows = rows,
        .resize_generation = generation,
    };
}

fn string(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn unsigned(comptime T: type, value: std.json.Value) ?T {
    return switch (value) {
        .integer => |number| if (number >= 0) std.math.cast(T, number) else null,
        else => null,
    };
}

fn parseHex128(text: []const u8) ?u128 {
    if (text.len != 32) return null;
    var value: u128 = 0;
    for (text) |byte| {
        const digit: u8 = switch (byte) {
            '0'...'9' => byte - '0',
            'a'...'f' => byte - 'a' + 10,
            else => return null,
        };
        value = (value << 4) | digit;
    }
    return value;
}

test "resize event strict decoder accepts full state and rejects malformed fields" {
    const valid =
        \\{"event":"runtime.resized","data":{"runtime_id":"000000000000000000000000000000aa","cols":120,"rows":40,"resize_generation":9,"reason":"controller"}}
    ;
    const decoded = try parseEvent(std.testing.allocator, valid);
    try std.testing.expectEqual(@as(u128, 0xAA), decoded.runtime_id);
    try std.testing.expectEqual(@as(u16, 120), decoded.cols);
    try std.testing.expectEqual(@as(u64, 9), decoded.resize_generation);

    inline for (&.{
        \\{"event":"runtime.resized","data":{"runtime_id":"AA","cols":120,"rows":40,"resize_generation":9,"reason":"controller"}}
        ,
        \\{"event":"runtime.resized","data":{"runtime_id":"000000000000000000000000000000aa","cols":0,"rows":40,"resize_generation":9,"reason":"controller"}}
        ,
        \\{"event":"runtime.resized","data":{"runtime_id":"000000000000000000000000000000aa","cols":120,"rows":40,"resize_generation":0,"reason":"controller"}}
        ,
        \\{"event":"runtime.resized","data":{"runtime_id":"000000000000000000000000000000aa","cols":120,"rows":40,"resize_generation":9,"reason":"other"}}
        ,
    }) |malformed|
        try std.testing.expectError(
            error.Invalid,
            parseEvent(std.testing.allocator, malformed),
        );
}
