//! GitHub release의 exact named asset을 stdout으로만 받는 closed command SSOT.

const std = @import("std");
const manifest = @import("release_manifest");
const identity = @import("release_adapter_identity");

const max_args = 9;

pub const Error = error{InvalidExpected};

pub const PlanStorage = struct {
    pattern: [manifest.max_asset_name_bytes * 2]u8 = undefined,
    args: [max_args][]const u8 = undefined,
};

pub const Plan = struct { args: []const []const u8 };

pub fn plan(storage: *PlanStorage, tag: []const u8, name: []const u8) Error!Plan {
    if (!identity.canonicalTag(tag) or !validName(name)) return error.InvalidExpected;
    var used: usize = 0;
    for (name) |byte| {
        if (byte == '\\' or byte == '*' or byte == '?' or byte == '[') {
            if (used == storage.pattern.len) return error.InvalidExpected;
            storage.pattern[used] = '\\';
            used += 1;
        }
        if (used == storage.pattern.len) return error.InvalidExpected;
        storage.pattern[used] = byte;
        used += 1;
    }
    const values = [_][]const u8{
        "release", "download", tag, "--repo", "ohah/maru", "--pattern", storage.pattern[0..used], "--output", "-",
    };
    for (values, 0..) |value, index| storage.args[index] = value;
    return .{ .args = &storage.args };
}

fn validName(value: []const u8) bool {
    if (value.len == 0 or value.len > manifest.max_asset_name_bytes or std.mem.eql(u8, value, ".") or
        std.mem.eql(u8, value, "..") or std.mem.indexOfScalar(u8, value, '/') != null)
        return false;
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}
