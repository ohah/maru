//! Zig 0.17 removed array multiplication (`value ** count`). Keep the exact
//! repeated-pattern behavior in one helper while using `@splat` for the common
//! one-element array case. String literals retain their sentinel-terminated type.

const std = @import("std");

pub fn repeat(comptime pattern: anytype, comptime count: usize) RepeatedType(@TypeOf(pattern), count) {
    return switch (@typeInfo(@TypeOf(pattern))) {
        .array => repeatArray(pattern, count),
        .pointer => |pointer| switch (@typeInfo(pointer.child)) {
            .array => |array| if (array.sentinel_ptr != null)
                repeatString(pattern, count)
            else
                repeatArray(pattern, count),
            else => @compileError("repeat expects an array or a pointer to an array"),
        },
        else => @compileError("repeat expects an array or a pointer to an array"),
    };
}

fn RepeatedType(comptime T: type, comptime count: usize) type {
    return switch (@typeInfo(T)) {
        .array => RepeatedArrayType(T, count),
        .pointer => |pointer| switch (@typeInfo(pointer.child)) {
            .array => |array| if (array.sentinel()) |sentinel|
                *const [array.len * count:sentinel]array.child
            else
                RepeatedArrayType(pointer.child, count),
            else => @compileError("repeat expects an array or a pointer to an array"),
        },
        else => @compileError("repeat expects an array or a pointer to an array"),
    };
}

fn RepeatedArrayType(comptime T: type, comptime count: usize) type {
    return switch (@typeInfo(T)) {
        .array => |array| if (array.sentinel()) |sentinel|
            [array.len * count:sentinel]array.child
        else
            [array.len * count]array.child,
        .pointer => |pointer| switch (@typeInfo(pointer.child)) {
            .array => |array| if (array.sentinel()) |sentinel|
                [array.len * count:sentinel]array.child
            else
                [array.len * count]array.child,
            else => @compileError("repeat expects an array or a pointer to an array"),
        },
        else => @compileError("repeat expects an array or a pointer to an array"),
    };
}

fn repeatArray(comptime pattern: anytype, comptime count: usize) RepeatedArrayType(@TypeOf(pattern), count) {
    const result_type = RepeatedArrayType(@TypeOf(pattern), count);
    const result: result_type = if (pattern.len == 1)
        @splat(pattern[0])
    else blk: {
        var output: result_type = undefined;
        @memcpy(output[0..pattern.len], pattern[0..]);
        var initialized = pattern.len;
        while (initialized < output.len) {
            const copy_len = @min(initialized, output.len - initialized);
            @memcpy(output[initialized..][0..copy_len], output[0..copy_len]);
            initialized += copy_len;
        }
        break :blk output;
    };
    return result;
}

fn repeatString(comptime pattern: anytype, comptime count: usize) RepeatedType(@TypeOf(pattern), count) {
    const result = comptime repeatArray(pattern, count);
    return &result;
}

test "array repeat preserves byte patterns and string sentinels" {
    const bytes = repeat([_]u8{ 0x12, 0x34 }, 3);
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x34, 0x12, 0x34, 0x12, 0x34 }, &bytes);

    const utf8 = repeat("가", 3);
    try std.testing.expectEqualStrings("가가가", utf8);
    try std.testing.expectEqual(*const [9:0]u8, @TypeOf(utf8));
}
