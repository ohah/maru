//! A random receipt travels through the session's own TUI, never the daemon's
//! inherited pane environment. Only the latest receipt in the private registry
//! is accepted. This authenticates accidental/forged text, not a hostile same-UID process.
const std = @import("std");
pub const prefix = "MARU_SESSION_V1:";
pub const dirname = "codex-session-receipts";
pub const Receipt = struct {
    session: []const u8,
    issued: u64,
    text: []const u8,
};
pub fn parse(text: []const u8) ?Receipt {
    if (!std.mem.startsWith(u8, text, prefix) or !std.mem.endsWith(u8, text, "!")) return null;
    var fields = std.mem.splitScalar(u8, text[prefix.len .. text.len - 1], ':');
    const sid = fields.next() orelse return null;
    if (sid.len != 36) return null;
    for (sid, 0..) |c, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            if (c != '-') return null;
        } else if (!std.ascii.isHex(c)) return null;
    }
    const nonce = fields.next() orelse return null;
    if (nonce.len != 32) return null;
    for (nonce) |c| if (!std.ascii.isHex(c)) return null;
    const issued = std.fmt.parseInt(u64, fields.next() orelse return null, 10) catch return null;
    if (issued == 0 or fields.next() != null) return null;
    return .{ .session = sid, .issued = issued, .text = text };
}

/// Caller holds the authenticated 0700 registry directory.
pub fn verify(io: std.Io, dir: std.Io.Dir, receipt: Receipt) bool {
    const file = dir.openFile(io, receipt.session, .{ .follow_symlinks = false }) catch return false;
    defer file.close(io);
    const stat = file.stat(io) catch return false;
    if (stat.kind != .file or stat.size != receipt.text.len) return false;
    var bytes: [160]u8 = undefined;
    if (receipt.text.len > bytes.len) return false;
    const n = file.readPositionalAll(io, bytes[0..receipt.text.len], 0) catch return false;
    return n == receipt.text.len and std.mem.eql(u8, bytes[0..n], receipt.text);
}

/// Screen wraps can insert whitespace inside the marker. Return slices into scratch.
pub fn scan(io: std.Io, dir: std.Io.Dir, screen: []const u8, started_us: u64, minimum: u64, scratch: []u8) ?Receipt {
    var n: usize = 0;
    for (screen) |c| {
        if (std.ascii.isWhitespace(c)) continue;
        if (n == scratch.len) return null;
        scratch[n] = c;
        n += 1;
    }
    var rest = scratch[0..n];
    var best: ?Receipt = null;
    while (std.mem.indexOf(u8, rest, prefix)) |at| {
        rest = rest[at..];
        const end = std.mem.indexOfScalar(u8, rest, '!') orelse break;
        if (parse(rest[0 .. end + 1])) |value| {
            if (value.issued / 1000 >= started_us and value.issued >= minimum and
                (best == null or value.issued > best.?.issued) and verify(io, dir, value)) best = value;
        }
        rest = rest[prefix.len..];
    }
    return best;
}

test "Codex receipt rejects forged, truncated and path identities" {
    const good = prefix ++ "12345678-1234-1234-1234-123456789abc:0123456789abcdef0123456789abcdef:123!";
    try std.testing.expectEqual(@as(u64, 123), parse(good).?.issued);
    try std.testing.expect(parse(good[0 .. good.len - 1]) == null);
    try std.testing.expect(parse(prefix ++ "../../bad:0123456789abcdef0123456789abcdef:123!") == null);
    try std.testing.expect(parse(prefix ++ "12345678-1234-1234-1234-123456789abc:bad:123!") == null);
    try std.testing.expect(parse(good ++ "x") == null);
}

test "Codex receipt verifies wraps, rejects stale replay, wrong nonce and previous process" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const sid = "12345678-1234-1234-1234-123456789abc";
    const first = prefix ++ sid ++ ":0123456789abcdef0123456789abcdef:100000!";
    const second = prefix ++ sid ++ ":fedcba9876543210fedcba9876543210:200000!";
    try tmp.dir.writeFile(io, .{ .sub_path = sid, .data = first });
    var scratch: [1024]u8 = undefined;
    const wrapped = "Hook · MARU_SESSION_V1:12345678-1234-1234-1234-123456789abc:0123456789abcdef\n  0123456789abcdef:100000!";
    try std.testing.expectEqualStrings(sid, scan(io, tmp.dir, wrapped, 100, 0, &scratch).?.session);
    try std.testing.expect(scan(io, tmp.dir, wrapped, 101, 0, &scratch) == null);
    try std.testing.expect(scan(io, tmp.dir, wrapped, 0, 100001, &scratch) == null);
    try std.testing.expect(scan(io, tmp.dir, second, 0, 0, &scratch) == null);
    try tmp.dir.writeFile(io, .{ .sub_path = sid, .data = second });
    try std.testing.expect(scan(io, tmp.dir, first, 0, 0, &scratch) == null);
    try std.testing.expectEqual(@as(u64, 200000), scan(io, tmp.dir, first ++ "\n" ++ second, 0, 0, &scratch).?.issued);
    // A registry pathname redirected to another file is never followed.
    try tmp.dir.deleteFile(io, sid);
    try tmp.dir.writeFile(io, .{ .sub_path = "other", .data = second });
    try tmp.dir.symLink(io, "other", sid, .{});
    try std.testing.expect(!verify(io, tmp.dir, parse(second).?));
}

/// Explicit native `codex resume UUID` is a client-owned proof when a cached
/// daemon thread is rejoined without running SessionStart again. Never use --last.
pub fn resumeFromProcArgs(data: []const u8) ?[]const u8 {
    if (data.len < 4) return null;
    const argc = std.mem.readInt(u32, data[0..4], .little);
    if (argc < 3 or argc > 1024) return null;
    var at: usize = 4;
    while (at < data.len and data[at] != 0) at += 1;
    while (at < data.len and data[at] == 0) at += 1;
    var skip_value = false;
    var want_id = false;
    for (0..argc) |i| {
        const start = at;
        while (at < data.len and data[at] != 0) at += 1;
        if (at == data.len) return null;
        const arg = data[start..at];
        at += 1;
        if (i == 0) {
            if (!std.mem.eql(u8, std.fs.path.basename(arg), "codex")) return null;
            continue;
        }
        if (skip_value) {
            skip_value = false;
            continue;
        }
        if (want_id) {
            // Reuse the receipt UUID validator; no shell or env parsing.
            var buf: [160]u8 = undefined;
            if (arg.len != 36) return null;
            const text = std.fmt.bufPrint(&buf, prefix ++ "{s}:00000000000000000000000000000000:1!", .{arg}) catch return null;
            _ = parse(text) orelse return null;
            return arg;
        }
        if (std.mem.eql(u8, arg, "resume")) {
            want_id = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--config") or
            std.mem.eql(u8, arg, "--remote") or std.mem.eql(u8, arg, "-C") or std.mem.eql(u8, arg, "--cd") or
            std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--model") or
            std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--profile"))
        {
            skip_value = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-alt-screen") or std.mem.eql(u8, arg, "--no-daemon") or
            std.mem.eql(u8, arg, "--dangerously-bypass-hook-trust")) continue;
        return null; // Unknown syntax may consume `resume` as an option value.
    }
    return null;
}

test "Codex receipt explicit resume reads only the client argv and rejects option values" {
    const sid = "12345678-1234-1234-1234-123456789abc";
    try std.testing.expectEqualStrings(sid, resumeFromProcArgs("\x06\x00\x00\x00/bin/codex\x00codex\x00--remote\x00unix://socket\x00--no-alt-screen\x00resume\x00" ++ sid ++ "\x00").?);
    try std.testing.expect(resumeFromProcArgs("\x04\x00\x00\x00/bin/codex\x00codex\x00-c\x00resume\x00" ++ sid ++ "\x00") == null);
    try std.testing.expect(resumeFromProcArgs("\x03\x00\x00\x00/bin/codex\x00codex\x00resume\x00--last\x00") == null);
    try std.testing.expect(resumeFromProcArgs("\x02\x00\x00\x00/bin/codex\x00codex\x00resume\x00" ++ sid ++ "\x00") == null);
}
