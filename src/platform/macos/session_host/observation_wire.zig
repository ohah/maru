//! runtime metadata JSON wire schema의 단일 validator.
//!
//! Client event queue와 RemoteRuntime consumer가 서로 다른 schema/range 규칙을 가지면, consumer가 거부할 malformed newer
//! event가 정상 pending full-state를 밀어내거나 새 필드를 한쪽만 받아 영구 누락시킬 수 있다. 두 경로는 반드시 이 validator를
//! 먼저 통과한다. 반환 revision 외 값 적용은 RemoteRuntime이 owned cache로 수행한다.

const std = @import("std");

pub fn eventRevision(allocator: std.mem.Allocator, payload: []const u8) error{OutOfMemory}!?u64 {
    return revision(allocator, payload, false);
}

pub fn payloadRevision(allocator: std.mem.Allocator, payload: []const u8) error{OutOfMemory}!?u64 {
    return revision(allocator, payload, true);
}

fn revision(allocator: std.mem.Allocator, payload: []const u8, allow_response: bool) error{OutOfMemory}!?u64 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const container = if (allow_response and root.get("result") != null)
        switch (root.get("result").?) {
            .object => |o| o,
            else => return null,
        }
    else blk: {
        const event = switch (root.get("event") orelse return null) {
            .string => |s| s,
            else => return null,
        };
        if (!std.mem.eql(u8, event, "runtime.metadata")) return null;
        break :blk root;
    };

    const metadata_revision: u64 = switch (container.get("metadata_revision") orelse return null) {
        .integer => |n| if (n > 0) @intCast(n) else return null,
        else => return null,
    };
    const metadata = switch (container.get("metadata") orelse return null) {
        .object => |o| o,
        else => return null,
    };
    if (!fieldIs(metadata, "cwd", .string) or
        !fieldIs(metadata, "window_title", .string) or
        !fieldIsStringOrNull(metadata, "ssh_remote_dest") or
        !fieldIsNonNegative(metadata, "semantic_state") or
        !fieldIs(metadata, "alt_active", .bool) or
        !fieldIs(metadata, "app_cursor_keys", .bool) or
        !fieldIs(metadata, "alternate_scroll", .bool) or
        !fieldIsNonNegative(metadata, "observer_generation") or
        !fieldFitsUnsigned(metadata, "title_generation", std.math.maxInt(u32)) or
        !fieldFitsUnsigned(metadata, "cols", std.math.maxInt(u16)) or
        !fieldFitsUnsigned(metadata, "rows", std.math.maxInt(u16)) or
        !fieldIs(metadata, "foreground_available", .bool) or
        !fieldIsI32OrNull(metadata, "foreground_pgid"))
        return null;
    const processes = switch (metadata.get("processes") orelse return null) {
        .array => |items| items,
        else => return null,
    };
    for (processes.items) |item| {
        const process = switch (item) {
            .object => |o| o,
            else => return null,
        };
        if (!fieldIsI32(process, "pid") or !fieldIs(process, "name", .string)) return null;
    }
    return metadata_revision;
}

const JsonKind = enum { string, bool };

fn fieldIs(obj: std.json.ObjectMap, key: []const u8, comptime kind: JsonKind) bool {
    const value = obj.get(key) orelse return false;
    return switch (kind) {
        .string => value == .string,
        .bool => value == .bool,
    };
}

fn fieldIsStringOrNull(obj: std.json.ObjectMap, key: []const u8) bool {
    return switch (obj.get(key) orelse return false) {
        .string, .null => true,
        else => false,
    };
}

fn fieldIsNonNegative(obj: std.json.ObjectMap, key: []const u8) bool {
    return switch (obj.get(key) orelse return false) {
        .integer => |n| n >= 0,
        else => false,
    };
}

fn fieldFitsUnsigned(obj: std.json.ObjectMap, key: []const u8, max: u64) bool {
    return switch (obj.get(key) orelse return false) {
        .integer => |n| n >= 0 and @as(u64, @intCast(n)) <= max,
        else => false,
    };
}

fn fieldIsI32(obj: std.json.ObjectMap, key: []const u8) bool {
    return switch (obj.get(key) orelse return false) {
        .integer => |n| n >= std.math.minInt(i32) and n <= std.math.maxInt(i32),
        else => false,
    };
}

fn fieldIsI32OrNull(obj: std.json.ObjectMap, key: []const u8) bool {
    return switch (obj.get(key) orelse return false) {
        .integer => |n| n >= std.math.minInt(i32) and n <= std.math.maxInt(i32),
        .null => true,
        else => false,
    };
}

test "observation wire rejects consumer-invalid bounds and accepts event/response containers" {
    const allocator = std.testing.allocator;
    const metadata =
        \\{"cwd":"/repo","window_title":"work","ssh_remote_dest":null,"semantic_state":0,"alt_active":false,
        \\"app_cursor_keys":false,"alternate_scroll":true,"observer_generation":1,"title_generation":1,"cols":80,"rows":24,
        \\"foreground_available":false,"foreground_pgid":null,"processes":[]}
    ;
    const event = try std.fmt.allocPrint(allocator, "{{\"event\":\"runtime.metadata\",\"metadata_revision\":2,\"metadata\":{s}}}", .{metadata});
    defer allocator.free(event);
    try std.testing.expectEqual(@as(?u64, 2), try eventRevision(allocator, event));
    const response = try std.fmt.allocPrint(allocator, "{{\"result\":{{\"metadata_revision\":3,\"metadata\":{s}}}}}", .{metadata});
    defer allocator.free(response);
    try std.testing.expectEqual(@as(?u64, 3), try payloadRevision(allocator, response));
    const bad = try std.mem.replaceOwned(u8, allocator, event, "\"cols\":80", "\"cols\":-1");
    defer allocator.free(bad);
    try std.testing.expectEqual(@as(?u64, null), try eventRevision(allocator, bad));
}
