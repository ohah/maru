//! Bounded, privacy-preserving recent-turn projection for an archive session tab.
//!
//! The platform worker supplies only a tail of one already-identified JSONL
//! source.  This module never opens a file and deliberately discards tool
//! input/output: an archive disclosure is a navigation aid, not a transcript viewer.
//! The platform worker applies the shared redact policy before publishing a
//! parsed turn across the worker boundary.

const std = @import("std");
const archive = @import("agent_session_archive.zig");

pub const max_recent_turns: usize = 3;
pub const max_turn_bytes: usize = 480;

pub const Role = enum { user, assistant };

pub const Turn = struct {
    role: Role,
    text: []u8,

    pub fn deinit(self: *Turn, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }
};

pub const Detail = struct {
    turns: std.ArrayList(Turn) = .empty,
    /// Tool/permission-shaped records are counted, never rendered.  Their
    /// arguments and results often contain commands, paths, or credentials.
    action_records: u32 = 0,
    /// A tail beginning in the middle of a line deliberately skips that line.
    truncated_prefix: bool = false,

    pub fn deinit(self: *Detail, allocator: std.mem.Allocator) void {
        for (self.turns.items) |*turn| turn.deinit(allocator);
        self.turns.deinit(allocator);
        self.* = undefined;
    }
};

/// Parses a bounded JSONL tail.  `complete_first_line` is true only when the
/// worker read from byte offset zero; otherwise the first split fragment could
/// be a forged/incomplete JSON object and must not become a visible turn.
pub fn parseTail(
    allocator: std.mem.Allocator,
    provider: archive.Provider,
    bytes: []const u8,
    complete_first_line: bool,
) !Detail {
    var out: Detail = .{ .truncated_prefix = !complete_first_line };
    errdefer out.deinit(allocator);

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (first) {
            first = false;
            if (!complete_first_line) continue;
        }
        const parsed = parseObject(allocator, line) orelse continue;
        defer parsed.deinit();
        const obj = parsed.value.object;
        switch (provider) {
            .claude => parseClaudeRecord(allocator, &out, obj),
            .codex => parseCodexRecord(allocator, &out, obj),
        }
    }
    return out;
}

fn parseClaudeRecord(allocator: std.mem.Allocator, out: *Detail, obj: std.json.ObjectMap) void {
    const kind = string(obj.get("type")) orelse return;
    const message = object(obj.get("message")) orelse return;
    if (std.mem.eql(u8, kind, "assistant")) {
        countClaudeActions(out, message);
        appendTurnIfText(allocator, out, .assistant, contentText(message));
        return;
    }
    if (!std.mem.eql(u8, kind, "user")) return;
    // Injected compaction/meta turns do not represent the user's recent
    // conversation.  Tool results inside them are intentionally not exposed.
    if (isTrue(obj.get("isMeta")) or isTrue(obj.get("isSynthetic")) or isTrue(obj.get("isCompactSummary"))) return;
    appendTurnIfText(allocator, out, .user, contentText(message));
}

fn parseCodexRecord(allocator: std.mem.Allocator, out: *Detail, obj: std.json.ObjectMap) void {
    const payload = object(obj.get("payload")) orelse return;
    const kind = string(obj.get("type")) orelse return;
    if (std.mem.eql(u8, kind, "event_msg")) {
        const event = string(payload.get("type")) orelse return;
        const text = string(payload.get("message"));
        if (std.mem.eql(u8, event, "user_message")) {
            appendTurnIfText(allocator, out, .user, if (text) |value| stripCodexPrefix(value) else null);
        } else if (std.mem.eql(u8, event, "agent_message")) {
            appendTurnIfText(allocator, out, .assistant, text);
        }
        return;
    }
    if (!std.mem.eql(u8, kind, "response_item")) return;
    const item_type = string(payload.get("type")) orelse return;
    if (std.mem.eql(u8, item_type, "function_call") or std.mem.eql(u8, item_type, "local_shell_call")) {
        out.action_records +|= 1;
        return;
    }
    if (!std.mem.eql(u8, item_type, "message")) return;
    const role = string(payload.get("role")) orelse return;
    if (std.mem.eql(u8, role, "user")) {
        appendTurnIfText(allocator, out, .user, contentText(payload));
    } else if (std.mem.eql(u8, role, "assistant")) {
        appendTurnIfText(allocator, out, .assistant, contentText(payload));
    }
}

fn countClaudeActions(out: *Detail, message: std.json.ObjectMap) void {
    const content = message.get("content") orelse return;
    const parts = switch (content) {
        .array => |items| items.items,
        else => return,
    };
    for (parts) |part| {
        const item = object(part) orelse continue;
        const kind = string(item.get("type")) orelse continue;
        if (std.mem.eql(u8, kind, "tool_use")) out.action_records +|= 1;
    }
}

fn appendTurnIfText(allocator: std.mem.Allocator, out: *Detail, role: Role, maybe_text: ?[]const u8) void {
    const raw = maybe_text orelse return;
    const text = displayText(allocator, raw) catch return;
    if (text.len == 0) {
        allocator.free(text);
        return;
    }
    if (out.turns.items.len == max_recent_turns) {
        var oldest = out.turns.orderedRemove(0);
        oldest.deinit(allocator);
    }
    out.turns.append(allocator, .{ .role = role, .text = text }) catch allocator.free(text);
}

fn displayText(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var normalized: [max_turn_bytes]u8 = undefined;
    var n: usize = 0;
    for (raw) |byte| {
        if (n == normalized.len) break;
        normalized[n] = if (byte < 0x20 or byte == 0x7f) ' ' else byte;
        n += 1;
    }
    const trimmed = std.mem.trim(u8, normalized[0..n], " \t\r\n");
    return allocator.dupe(u8, trimmed);
}

fn contentText(obj: std.json.ObjectMap) ?[]const u8 {
    if (string(obj.get("text"))) |text| return text;
    const content = obj.get("content") orelse return null;
    return switch (content) {
        .string => |text| text,
        .array => |items| for (items.items) |item| {
            const part = object(item) orelse continue;
            if (string(part.get("text"))) |text| break text;
        } else null,
        else => null,
    };
}

fn stripCodexPrefix(text: []const u8) []const u8 {
    const marker = "## My request for Codex:";
    const start = if (std.mem.indexOf(u8, text, marker)) |index| text[index + marker.len ..] else text;
    return std.mem.trim(u8, start, " \t\r\n");
}

fn parseObject(allocator: std.mem.Allocator, line: []const u8) ?std.json.Parsed(std.json.Value) {
    if (line.len < 2 or line[0] != '{') return null;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return null;
    if (parsed.value != .object) {
        parsed.deinit();
        return null;
    }
    return parsed;
}

fn object(value: ?std.json.Value) ?std.json.ObjectMap {
    return switch (value orelse return null) {
        .object => |o| o,
        else => null,
    };
}

fn string(value: ?std.json.Value) ?[]const u8 {
    return switch (value orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn isTrue(value: ?std.json.Value) bool {
    return switch (value orelse return false) {
        .bool => |v| v,
        else => false,
    };
}

test "Claude tail keeps recent conversation but hides tool payloads" {
    const fixture =
        \\{"type":"user","message":{"content":"first"}}
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"secret"}},{"type":"text","text":"second"}]}}
        \\{"type":"user","message":{"content":"third"}}
        \\{"type":"assistant","message":{"content":"fourth"}}
    ;
    var detail = try parseTail(std.testing.allocator, .claude, fixture, true);
    defer detail.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 1), detail.action_records);
    try std.testing.expectEqual(@as(usize, 3), detail.turns.items.len);
    try std.testing.expectEqual(Role.assistant, detail.turns.items[2].role);
    try std.testing.expectEqualStrings("fourth", detail.turns.items[2].text);
}

test "truncated prefix skips the partial first record" {
    const fixture =
        \\partial-json
        \\{"type":"event_msg","payload":{"type":"user_message","message":"API_TOKEN=do-not-show"}}
        \\{"type":"event_msg","payload":{"type":"agent_message","message":"done"}}
    ;
    var detail = try parseTail(std.testing.allocator, .codex, fixture, false);
    defer detail.deinit(std.testing.allocator);
    try std.testing.expect(detail.truncated_prefix);
    try std.testing.expectEqual(@as(usize, 2), detail.turns.items.len);
    try std.testing.expectEqualStrings("API_TOKEN=do-not-show", detail.turns.items[0].text);
}
