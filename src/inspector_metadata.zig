//! Canonical collection facts, shared by JSON exports and the property inspector.
//! Empty strings and false flags remain raw data; their availability is described separately.
const std = @import("std");
pub const Availability = enum { available, not_applicable, not_collected, unsupported, unavailable };
pub const Source = enum { published_ui_tree, session_model, window_membership, runtime_observation, terminal_screen, local_core, osc7, agent_hook, kernel, scm_decision, explorer_state, inspector_history, sampling_policy };
pub const Reason = enum { none, no_session_host, window_unbound, local_terminal, no_shell_hook, no_observed_cwd, host_omitted, no_ssh_destination, host_transport_missing, observation_unavailable, foreground_unavailable, detail_not_ready, not_captured };
pub const Info = struct { availability: Availability = .available, source: Source, reason: Reason = .none };

fn valueAt(root: std.json.Value, path: []const u8) ?std.json.Value {
    var value = root;
    var parts = std.mem.splitScalar(u8, path, '.');
    while (parts.next()) |part| {
        if (value != .object) return null;
        value = value.object.get(part) orelse return null;
    }
    return value;
}
fn text(root: std.json.Value, path: []const u8) []const u8 {
    const value = valueAt(root, path) orelse return "";
    return if (value == .string) value.string else "";
}
fn flag(root: std.json.Value, path: []const u8) bool {
    const value = valueAt(root, path) orelse return false;
    return value == .bool and value.bool;
}
fn empty(value: std.json.Value) bool {
    return value == .null or (value == .string and value.string.len == 0);
}
fn sourceFor(root: std.json.Value, key: []const u8) Source {
    if (std.mem.startsWith(u8, key, "elements.")) return .published_ui_tree;
    if (std.mem.eql(u8, key, "overview.window")) return .window_membership;
    if (std.mem.startsWith(u8, key, "overview.observ") or std.mem.eql(u8, key, "overview.sampled_at_ms")) return .runtime_observation;
    if (std.mem.startsWith(u8, key, "path.hook_")) return .agent_hook;
    if (std.mem.startsWith(u8, key, "path.osc7_")) return .osc7;
    if (std.mem.startsWith(u8, key, "path.scm_")) return .scm_decision;
    if (std.mem.startsWith(u8, key, "path.explorer_")) return .explorer_state;
    if (std.mem.eql(u8, key, "path.selected_cwd") or std.mem.eql(u8, key, "path.source") or std.mem.eql(u8, key, "path.reason")) {
        const selected = text(root, "path.source");
        if (std.mem.eql(u8, selected, "hook")) return .agent_hook;
        if (std.mem.eql(u8, selected, "osc7")) return .osc7;
        if (std.mem.eql(u8, selected, "kernel")) return .kernel;
        return .runtime_observation;
    }
    if (std.mem.startsWith(u8, key, "path.")) return .runtime_observation;
    if (std.mem.startsWith(u8, key, "terminal.cursor")) return .terminal_screen;
    if (std.mem.startsWith(u8, key, "terminal.scroll_region")) return .local_core;
    if (std.mem.startsWith(u8, key, "terminal.")) return .runtime_observation;
    if (std.mem.eql(u8, key, "events.capture") or std.mem.eql(u8, key, "events.protocol_support")) return .sampling_policy;
    if (std.mem.startsWith(u8, key, "events.")) return .inspector_history;
    return .session_model;
}
/// Classification uses explicit producer facts, never guesses a missing value from zero/false.
pub fn describe(root: std.json.Value, key: []const u8, value: std.json.Value) Info {
    var info: Info = .{ .source = sourceFor(root, key) };
    const host = std.mem.eql(u8, text(root, "overview.backend"), "session_host");
    if (std.mem.eql(u8, key, "overview.runtime_id") and !host) return .{ .source = info.source, .availability = .not_applicable, .reason = .no_session_host };
    if (std.mem.eql(u8, key, "overview.window") and empty(value)) return .{ .source = info.source, .availability = .not_collected, .reason = .window_unbound };
    if (std.mem.startsWith(u8, key, "path.hook_") and text(root, "path.hook_cwd").len == 0 and !std.mem.eql(u8, key, "path.hook_slot")) {
        info.availability = if (std.mem.eql(u8, key, "path.hook_fresh") or std.mem.eql(u8, key, "path.hook_host_matches")) .not_applicable else .not_collected;
        info.reason = .no_shell_hook;
        return info;
    }
    if (std.mem.eql(u8, key, "path.osc7_host") and empty(value) and text(root, "path.osc7_cwd").len != 0) return .{ .source = info.source, .availability = .not_applicable, .reason = .host_omitted };
    // Row painting can lag behind the selected explorer mode during a transition.
    // Destination applicability follows its producer, rather than the previous rows.
    const local_destination = if (std.mem.eql(u8, key, "path.explorer_destination")) !std.mem.eql(u8, text(root, "path.explorer_mode"), "remote") else !flag(root, "path.remote");
    if ((std.mem.eql(u8, key, "path.ssh_destination") or std.mem.eql(u8, key, "path.scm_target") or std.mem.eql(u8, key, "path.explorer_destination")) and empty(value) and local_destination) return .{ .source = info.source, .availability = .not_applicable, .reason = .local_terminal };
    if (std.mem.startsWith(u8, key, "terminal.scroll_region") and host) return .{ .source = .local_core, .availability = .unsupported, .reason = .host_transport_missing };
    if (std.mem.startsWith(u8, key, "terminal.") and !std.mem.eql(u8, key, "terminal.availability") and !std.mem.eql(u8, key, "terminal.core_detail_support") and std.mem.eql(u8, text(root, "terminal.availability"), "unavailable")) return .{ .source = info.source, .availability = .unavailable, .reason = .observation_unavailable };
    if (std.mem.eql(u8, key, "terminal.foreground_pgid") and !flag(root, "terminal.foreground_available")) return .{ .source = info.source, .availability = .unavailable, .reason = .foreground_unavailable };
    if (empty(value)) {
        info.availability = .not_collected;
        info.reason = if (std.mem.eql(u8, key, "path.selected_cwd") or std.mem.eql(u8, key, "path.osc7_cwd")) .no_observed_cwd else if (std.mem.eql(u8, key, "path.ssh_destination")) .no_ssh_destination else if (std.mem.startsWith(u8, key, "terminal.cursor") or std.mem.startsWith(u8, key, "terminal.scroll_region")) .detail_not_ready else .not_captured;
    }
    return info;
}
fn jsonInfo(a: std.mem.Allocator, info: Info) !std.json.Value {
    var object: std.json.ObjectMap = .empty;
    try object.put(a, "availability", .{ .string = @tagName(info.availability) });
    try object.put(a, "source", .{ .string = @tagName(info.source) });
    try object.put(a, "reason", .{ .string = @tagName(info.reason) });
    return .{ .object = object };
}
fn walk(a: std.mem.Allocator, root: std.json.Value, path: []const u8, value: std.json.Value, out: *std.json.ObjectMap) !void {
    try out.put(a, path, try jsonInfo(a, describe(root, path, value)));
    if (value == .object) {
        var it = value.object.iterator();
        while (it.next()) |entry| try walk(a, root, try std.fmt.allocPrint(a, "{s}.{s}", .{ path, entry.key_ptr.* }), entry.value_ptr.*, out);
    }
}
pub fn collect(a: std.mem.Allocator, root: std.json.Value) !std.json.Value {
    var out: std.json.ObjectMap = .empty;
    for ([_][]const u8{ "overview", "path", "terminal", "events", "elements" }) |section| {
        const object = valueAt(root, section) orelse continue;
        if (object == .object) {
            var it = object.object.iterator();
            while (it.next()) |entry| try walk(a, root, try std.fmt.allocPrint(a, "{s}.{s}", .{ section, entry.key_ptr.* }), entry.value_ptr.*, &out);
        }
    }
    return .{ .object = out };
}
/// Export metadata contains canonical vocabulary only; arbitrary data under this key
/// must still pass through normal redaction rather than gaining an exemption.
pub fn isCanonical(value: std.json.Value) bool {
    if (value != .object or value.object.count() > 128) return false;
    var it = value.object.iterator();
    while (it.next()) |entry| {
        const object = entry.value_ptr.*;
        if (object != .object or object.object.count() != 3) return false;
        const availability = object.object.get("availability") orelse return false;
        const source = object.object.get("source") orelse return false;
        const reason = object.object.get("reason") orelse return false;
        if (availability != .string or source != .string or reason != .string) return false;
        if (std.meta.stringToEnum(Availability, availability.string) == null or std.meta.stringToEnum(Source, source.string) == null or std.meta.stringToEnum(Reason, reason.string) == null) return false;
    }
    return true;
}

// GUI projection and JSON clients consume the same producer classification.
pub fn forField(root: std.json.Value, path: []const u8) Info {
    if (valueAt(root, "field_info")) |all| if (all == .object) {
        var key = path;
        while (true) {
            if (all.object.get(key)) |item| if (item == .object) {
                const av = item.object.get("availability");
                const src = item.object.get("source");
                const why = item.object.get("reason");
                if (av != null and src != null and why != null and av.? == .string and src.? == .string and why.? == .string) return .{
                    .availability = std.meta.stringToEnum(Availability, av.?.string) orelse .not_collected,
                    .source = std.meta.stringToEnum(Source, src.?.string) orelse .session_model,
                    .reason = std.meta.stringToEnum(Reason, why.?.string) orelse .not_captured,
                };
            };
            const end = std.mem.lastIndexOfAny(u8, key, ".[") orelse break;
            key = key[0..end];
        }
    };
    return describe(root, path, valueAt(root, path) orelse .null);
}

test "inspector metadata separates absent producer, unsupported transport and measured false" {
    const a = std.testing.allocator;
    const raw = try std.json.parseFromSlice(std.json.Value, a,
        \\{"overview":{"backend":"in_process","window":null},"path":{"remote":false,"hook_cwd":"","osc7_cwd":"/tmp"},"terminal":{"availability":"current","foreground_available":false}}
    , .{});
    defer raw.deinit();
    try std.testing.expectEqual(Availability.not_applicable, describe(raw.value, "overview.runtime_id", .null).availability);
    try std.testing.expectEqual(Availability.not_collected, describe(raw.value, "overview.window", .null).availability);
    try std.testing.expectEqual(Availability.available, describe(raw.value, "terminal.mouse_tracking", .{ .bool = false }).availability);
    try std.testing.expectEqual(Availability.available, describe(raw.value, "terminal.cursor.row", .{ .integer = 0 }).availability);
    try std.testing.expectEqual(Availability.not_applicable, describe(raw.value, "path.hook_fresh", .{ .bool = false }).availability);
    try std.testing.expectEqual(Reason.host_omitted, describe(raw.value, "path.osc7_host", .{ .string = "" }).reason);
    try std.testing.expectEqual(Availability.unavailable, describe(raw.value, "terminal.foreground_pgid", .null).availability);
}

test "inspector metadata marks missing host transport independently of observation age" {
    const a = std.testing.allocator;
    const raw = try std.json.parseFromSlice(std.json.Value, a,
        \\{"overview":{"backend":"session_host"},"terminal":{"availability":"unavailable"},"path":{"remote":true,"source":"hook"}}
    , .{});
    defer raw.deinit();
    try std.testing.expectEqual(Availability.unsupported, describe(raw.value, "terminal.scroll_region", .null).availability);
    try std.testing.expectEqual(Availability.unavailable, describe(raw.value, "terminal.cols", .{ .integer = 80 }).availability);
    try std.testing.expectEqual(Source.agent_hook, describe(raw.value, "path.selected_cwd", .{ .string = "/remote" }).source);
}

test "inspector metadata bounds history projection and preserves nested field identity" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const raw = try std.json.parseFromSlice(std.json.Value, a,
        \\{"overview":{"backend":"in_process","window":7},"terminal":{"cursor":{"row":0,"col":0}},"events":{"items":[{"kind":"changed"}]}}
    , .{});
    defer raw.deinit();
    const info = try collect(arena.allocator(), raw.value);
    try std.testing.expect(isCanonical(info));
    try std.testing.expect(info.object.contains("terminal.cursor.row"));
    try std.testing.expect(info.object.contains("events.items"));
    try std.testing.expect(!info.object.contains("events.items[0]"));
}

test "inspector explorer applicability follows mode while previous local rows remain visible" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"path":{"remote":true,"explorer_mode":"remote","explorer_rows_remote":false}}
    , .{});
    defer parsed.deinit();
    try std.testing.expectEqual(Availability.not_collected, describe(parsed.value, "path.explorer_destination", .{ .string = "" }).availability);
}
