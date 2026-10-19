//! Presentation rows keep the diagnostic key available to filtering without making
//! serialization syntax the UI. The exported JSON remains unchanged.
const std = @import("std");
const i18n = @import("../../../i18n.zig");
pub const Row = struct { key: []const u8, label: []const u8, value: []const u8 = "", heading: bool = false, missing: bool = false };

fn humanize(a: std.mem.Allocator, key: []const u8) ![]const u8 {
    const text = try a.dupe(u8, key);
    for (text, 0..) |*c, i| {
        if (c.* == '_') c.* = ' ' else if (i == 0 and c.* < 128) c.* = std.ascii.toUpper(c.*);
    }
    return text;
}
fn heading(key: []const u8) ?i18n.Key {
    const entries = .{
        .{ "surface_id", .inspector_session_section },  .{ "observation", .inspector_observation_section },
        .{ "remote", .inspector_location_section },     .{ "osc7_cwd", .inspector_osc_section },
        .{ "hook_cwd", .inspector_hook_section },       .{ "ssh_destination", .inspector_routing_section },
        .{ "availability", .inspector_screen_section }, .{ "semantic_prompt", .inspector_input_section },
    };
    inline for (entries) |entry| if (std.mem.eql(u8, key, entry[0])) return entry[1];
    return null;
}
pub fn flatten(a: std.mem.Allocator, value: std.json.Value, prefix: []const u8, out: *std.ArrayList(Row)) !void {
    if (out.items.len >= 512) return;
    switch (value) {
        .object => |o| {
            var it = o.iterator();
            while (it.next()) |entry| {
                if (prefix.len == 0) if (heading(entry.key_ptr.*)) |key| try out.append(a, .{ .key = "", .label = i18n.t(key), .heading = true });
                try flatten(a, entry.value_ptr.*, try std.fmt.allocPrint(a, "{s}{s}{s}", .{ prefix, if (prefix.len > 0) "." else "", entry.key_ptr.* }), out);
            }
        },
        .array => |arr| {
            for (arr.items, 0..) |item, i| {
                if (std.mem.eql(u8, prefix, "items") and item == .object) {
                    const event = item.object;
                    const kind = event.get("kind") orelse continue;
                    const origin = event.get("origin") orelse continue;
                    const observed = event.get("observed_ms") orelse continue;
                    const sequence = event.get("sequence") orelse continue;
                    const revision = event.get("revision") orelse continue;
                    if (kind != .string or origin != .string or observed != .integer or sequence != .integer or revision != .integer) continue;
                    try out.append(a, .{ .key = try std.fmt.allocPrint(a, "items[{d}]", .{i}), .label = try std.fmt.allocPrint(a, "#{d} · {d} ms", .{ sequence.integer, observed.integer }), .value = try std.fmt.allocPrint(a, "{s} · {s} · r{d}", .{ kind.string, origin.string, revision.integer }) });
                } else try flatten(a, item, try std.fmt.allocPrint(a, "{s}[{d}]", .{ prefix, i }), out);
            }
        },
        else => {
            const text = if (value == .string) value.string else if (value == .null) i18n.t(.inspector_unavailable) else try std.json.Stringify.valueAlloc(a, value, .{});
            try out.append(a, .{ .key = prefix, .label = try humanize(a, prefix), .value = text, .missing = value == .null or (value == .string and value.string.len == 0) });
        },
    }
}
