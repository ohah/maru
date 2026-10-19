//! Read-only live diagnostics shared by the GUI and CLI. Values describe one sampled
//! observation; metadata changes are explicitly distinguished from protocol events.
pub const layout = @import("layout.zig");
pub const metadata = @import("../../inspector_metadata.zig");
const std = @import("std");

pub const CwdSource = enum { hook, osc7, kernel, unknown };
pub const CwdDecision = struct {
    path: []const u8,
    source: CwdSource,
    reason: enum { fresh_matching_hook, hook_expired, hook_host_mismatch, no_hook, kernel_fallback, unavailable },
};

pub fn chooseRemoteCwd(hook_path: []const u8, fresh: bool, matches: bool, observed: []const u8) CwdDecision {
    if (hook_path.len != 0 and fresh and matches)
        return .{ .path = hook_path, .source = .hook, .reason = .fresh_matching_hook };
    return .{ .path = observed, .source = if (observed.len != 0) .osc7 else .unknown, .reason = if (hook_path.len == 0) .no_hook else if (!matches) .hook_host_mismatch else .hook_expired };
}

pub const Event = struct {
    sequence: u64,
    observed_ms: u64,
    origin: enum { sampled_metadata, shell_protocol },
    kind: []const u8,
    revision: u64,
};

/// Fixed capacity, no raw input/output or paths. Eviction and sample gaps are visible.
pub const History = struct {
    pub const capacity = 64;
    entries: [capacity]Event = undefined,
    count: usize = 0,
    next: u64 = 0,
    previous: ?Stamp = null,
    pub const Stamp = struct { cwd: u64, ssh: u64, modes: u64, size: u64, availability: u8, revision: u64 };

    pub fn append(self: *History, now: u64, origin: @FieldType(Event, "origin"), kind: []const u8, revision: u64) void {
        self.entries[@intCast(self.next % capacity)] = .{ .sequence = self.next, .observed_ms = now, .origin = origin, .kind = kind, .revision = revision };
        self.next +|= 1;
        self.count = @min(self.count + 1, capacity);
    }
    pub fn sample(self: *History, now: u64, stamp: Stamp) void {
        if (self.previous) |old| {
            if (old.cwd != stamp.cwd) self.append(now, .sampled_metadata, "cwd_changed", stamp.revision);
            if (old.ssh != stamp.ssh) self.append(now, .sampled_metadata, "ssh_changed", stamp.revision);
            if (old.modes != stamp.modes) self.append(now, .sampled_metadata, "terminal_modes_changed", stamp.revision);
            if (old.size != stamp.size) self.append(now, .sampled_metadata, "size_changed", stamp.revision);
            if (old.availability != stamp.availability) self.append(now, .sampled_metadata, "availability_changed", stamp.revision);
        } else self.append(now, .sampled_metadata, "observation_started", stamp.revision);
        self.previous = stamp;
    }
    pub fn copy(self: *const History, allocator: std.mem.Allocator) ![]const Event {
        const out = try allocator.alloc(Event, self.count);
        const start = self.next - self.count;
        for (out, 0..) |*e, i| e.* = self.entries[@intCast((start + i) % capacity)];
        return out;
    }
};

pub const Snapshot = struct {
    schema: []const u8 = "maru.inspector.v1",
    field_info: std.json.Value = .null,
    elements: std.json.Value = .null,
    overview: struct {
        surface_id: u64,
        runtime_id: ?[]const u8 = null,
        window: ?u64 = null,
        tab: usize,
        pane: usize,
        title: []const u8,
        backend: enum { in_process, session_host },
        observation: []const u8,
        observation_revision: u64,
        observer_generation: u64,
        sampled_at_ms: u64,
        terminated: bool,
    },
    path: struct {
        remote: bool,
        selected_cwd: []const u8,
        source: CwdSource,
        reason: @FieldType(CwdDecision, "reason"),
        osc7_cwd: []const u8,
        osc7_host: []const u8,
        hook_cwd: []const u8,
        hook_host: []const u8,
        hook_age_ms: ?u64,
        hook_fresh: bool,
        hook_host_matches: bool,
        hook_slot: []const u8,
        ssh_destination: []const u8,
        scm_target: []const u8,
        scm_reason: []const u8,
        explorer_mode: []const u8,
        explorer_root: []const u8,
        explorer_destination: []const u8,
        explorer_rows_remote: bool,
    },
    terminal: struct {
        availability: []const u8,
        cols: u16,
        rows: u16,
        semantic_prompt: []const u8,
        alternate_screen: bool,
        application_cursor_keys: bool,
        application_keypad: bool,
        kitty_flags: u5,
        alternate_scroll: bool,
        mouse_tracking: bool,
        mouse_tracking_mode: u8,
        bracketed_paste: bool,
        foreground_available: bool,
        foreground_pgid: ?i32,
        cursor: ?struct { row: u16, col: u16 } = null,
        scroll_region: ?struct { top: u16, bottom: u16 } = null,
        core_detail_support: []const u8,
    },
    events: struct {
        capture: []const u8 = "sampled changes since first inspection; intermediate metadata updates may be missed",
        protocol_support: []const u8,
        capacity: usize = History.capacity,
        evicted: u64,
        items: []const Event,
    },
};

/// Populate the typed DTO before either transport serializes it. The CLI nests this
/// DTO in session.get and therefore does not call the GUI export serializer.
pub fn addFieldInfo(a: std.mem.Allocator, snapshot: *Snapshot) error{OutOfMemory}!void {
    const raw = try std.json.Stringify.valueAlloc(a, snapshot.*, .{});
    defer a.free(raw);
    const parsed = std.json.parseFromSlice(std.json.Value, a, raw, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable, // Stringify produced this typed DTO in the same call.
    };
    defer parsed.deinit();
    snapshot.field_info = try metadata.collect(a, parsed.value);
}

pub fn serialize(allocator: std.mem.Allocator, snapshot: Snapshot) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var with_info = snapshot;
    if (with_info.field_info == .null) try addFieldInfo(arena.allocator(), &with_info);
    return std.json.Stringify.valueAlloc(allocator, with_info, .{ .whitespace = .indent_2 });
}

test "cwd decision shares the product precedence and explains rejected hooks" {
    const t = std.testing;
    try t.expectEqual(CwdSource.hook, chooseRemoteCwd("/agent", true, true, "/shell").source);
    const expired = chooseRemoteCwd("/agent", false, true, "/shell");
    try t.expectEqualStrings("/shell", expired.path);
    try t.expectEqual(.hook_expired, expired.reason);
    try t.expectEqual(.hook_host_mismatch, chooseRemoteCwd("/agent", true, false, "/shell").reason);
    try t.expectEqual(CwdSource.unknown, chooseRemoteCwd("", false, true, "").source);
}

test "history is bounded, ordered, distinguishes protocol events and exposes eviction" {
    var h: History = .{};
    for (0..80) |i| h.append(i, .shell_protocol, "prompt_start", 0);
    const events = try h.copy(std.testing.allocator);
    defer std.testing.allocator.free(events);
    try std.testing.expectEqual(@as(usize, 64), events.len);
    try std.testing.expectEqual(@as(u64, 16), events[0].sequence);
    try std.testing.expectEqual(@as(u64, 79), events[63].sequence);
    const stamp: History.Stamp = .{ .cwd = 1, .ssh = 2, .modes = 3, .size = 4, .availability = 1, .revision = 1 };
    h.sample(90, stamp);
    const count = h.next;
    h.sample(91, stamp);
    try std.testing.expectEqual(count, h.next);
}

/// Redact leaf string values, never JSON syntax or field names. A user named
/// "path" must not rename schema keys while anonymizing a report.
pub fn anonymizeJson(allocator: std.mem.Allocator, bytes: []const u8, options: @import("../../redact.zig").AnonymizeOptions) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var parsed = try std.json.parseFromSlice(std.json.Value, a, bytes, .{ .allocate = .alloc_always });
    try anonymizeValue(a, &parsed.value, options);
    return std.json.Stringify.valueAlloc(allocator, parsed.value, .{ .whitespace = .indent_2 });
}

fn anonymizeValue(a: std.mem.Allocator, value: *std.json.Value, options: @import("../../redact.zig").AnonymizeOptions) !void {
    switch (value.*) {
        .object => |*obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                if (std.mem.eql(u8, entry.key_ptr.*, "field_info") and metadata.isCanonical(entry.value_ptr.*)) continue;
                try anonymizeValue(a, entry.value_ptr, options);
            }
        },
        .array => |*arr| for (arr.items) |*v| {
            try anonymizeValue(a, v, options);
        },
        .string => |s| value.* = .{ .string = try @import("../../redact.zig").anonymizeAlloc(a, s, options) },
        else => {},
    }
}

test "inspector anonymization preserves JSON keys and structure" {
    const a = std.testing.allocator;
    const json = try anonymizeJson(a, "{\"path\":\"/Users/path/repo\",\"count\":1}", .{ .username = "path" });
    defer a.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("path") != null);
    try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("count").?.integer);
    try std.testing.expectEqualStrings("/Users/user/repo", parsed.value.object.get("path").?.string);
}

test "inspector anonymization preserves canonical metadata but redacts arbitrary field info" {
    const a = std.testing.allocator;
    const canonical =
        \\{"field_info":{"path.selected_cwd":{"availability":"not_collected","source":"agent_hook","reason":"no_shell_hook"}},"path":{"selected_cwd":"/Users/agent/private"}}
    ;
    const output = try anonymizeJson(a, canonical, .{ .username = "agent" });
    defer a.free(output);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, output, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("agent_hook", parsed.value.object.get("field_info").?.object.get("path.selected_cwd").?.object.get("source").?.string);
    try std.testing.expectEqualStrings("/Users/user/private", parsed.value.object.get("path").?.object.get("selected_cwd").?.string);
    const arbitrary = try anonymizeJson(a, "{\"field_info\":{\"secret\":\"/Users/agent/private\"}}", .{ .username = "agent" });
    defer a.free(arbitrary);
    try std.testing.expect(std.mem.indexOf(u8, arbitrary, "/Users/agent") == null);
}

test {
    std.testing.refAllDecls(layout);
    std.testing.refAllDecls(metadata);
}
