const std = @import("std");
const receipt = @import("../session/codex_hook_receipt.zig");
const private_dir = @import("agent_log_record.zig");

pub fn run(io: std.Io, allocator: std.mem.Allocator, directory: []const u8, stdout: *std.Io.Writer) !void {
    var bytes: [32768]u8 = undefined;
    var read_buffer: [1024]u8 = undefined;
    var input = std.Io.File.Reader.init(.stdin(), io, &read_buffer);
    const n = try input.interface.readSliceShort(&bytes);
    if (n == bytes.len) return error.InputTooLong;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes[0..n], .{});
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const ev = parsed.value.object.get("hook_event_name") orelse return;
    if (ev != .string or !std.mem.eql(u8, ev.string, "SessionStart")) return;
    const sid = parsed.value.object.get("session_id") orelse return;
    if (sid != .string or sid.string.len != 36) return;
    var nonce: [16]u8 = undefined;
    io.random(&nonce);
    const issued = std.Io.Clock.real.now(io).nanoseconds;
    var marker: [160]u8 = undefined;
    const text = try std.fmt.bufPrint(&marker, receipt.prefix ++ "{s}:{x}:{d}!", .{ sid.string, nonce, issued });
    const value = receipt.parse(text) orelse return;
    const dir = try private_dir.createPrivateDirectory(io, directory);
    defer dir.close(io);
    var atomic = try dir.createFileAtomic(io, value.session, .{ .permissions = .fromMode(0o600), .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, text);
    try atomic.replace(io);
    try stdout.print("{{\"systemMessage\":\"Maru session connected: {s}\"}}\n", .{text});
    try stdout.flush();
}
