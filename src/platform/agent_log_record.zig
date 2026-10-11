//! Authenticate the held directory before the native writer sees it.
//! Windows fails closed until ACL authentication exists; mode bits are not an ACL.
const std = @import("std");
const builtin = @import("builtin");
const writer = @import("agent_log_writer.zig");
const cli = @import("../cli/agent_log_record.zig");
const event = @import("../session/agent_hook_event.zig");

pub fn openPrivateDirectory(io: std.Io, path: []const u8) !std.Io.Dir {
    return openDirectory(io, path, false);
}

pub fn openPrivateDirectoryIterable(io: std.Io, path: []const u8) !std.Io.Dir {
    return openDirectory(io, path, true);
}

fn openDirectory(io: std.Io, path: []const u8, iterate: bool) !std.Io.Dir {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.UnsupportedPlatform;
    if (path.len == 0 or path[0] != '/') return error.UnsafeDirectory;
    var held = try std.Io.Dir.cwd().openDir(io, "/", .{ .follow_symlinks = false });
    errdefer held.close(io);
    var parts = std.mem.splitScalar(u8, path[1..], '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.UnsafeDirectory;
        const next = try held.openDir(io, part, .{ .follow_symlinks = false, .iterate = iterate and parts.peek() == null });
        held.close(io);
        held = next;
    }
    if (builtin.os.tag == .macos) {
        // Io.Stat has no uid. Stat this same handle, not a second path lookup.
        var stat: std.c.Stat = undefined;
        if (std.c.fstat(held.handle, &stat) != 0) return error.DirectoryStatFailed;
        if (stat.uid != std.c.geteuid() or stat.mode & 0o7777 != 0o700) return error.UnsafeDirectory;
    } else if (builtin.os.tag == .linux) {
        // Zig 0.16 exposes Linux metadata via statx, including on architectures
        // without the old fstat syscall. EMPTY_PATH authenticates the held fd.
        const linux = std.os.linux;
        var stat: linux.Statx = undefined;
        const mask: linux.STATX = .{ .UID = true, .MODE = true };
        if (linux.errno(linux.statx(held.handle, "", linux.AT.EMPTY_PATH, mask, &stat)) != .SUCCESS) return error.DirectoryStatFailed;
        if (!stat.mask.UID or !stat.mask.MODE) return error.DirectoryStatFailed;
        if (stat.uid != linux.geteuid() or stat.mode & 0o7777 != 0o700) return error.UnsafeDirectory;
    }
    return held;
}

pub fn run(io: std.Io, args: []const []const u8) !void {
    const options = try cli.parse(args);
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.UnsupportedPlatform;
    var record: [event.max_line_bytes + 2]u8 = undefined;
    var read_buffer: [1024]u8 = undefined;
    var input = std.Io.File.Reader.init(.stdin(), io, &read_buffer);
    const count = try input.interface.readSliceShort(&record);
    if (count == record.len) return error.RecordTooLong;
    const dir = try openPrivateDirectory(io, options.directory);
    defer dir.close(io);
    // One deadline for the entire lock wait, shorter than the provider's 2s timeout.
    const deadline = std.Io.Clock.awake.now(io).nanoseconds + 1500 * std.time.ns_per_ms;
    while (true) {
        _ = writer.append(io, dir, options.name, record[0..count]) catch |err| {
            if (err != error.WouldBlock or std.Io.Clock.awake.now(io).nanoseconds >= deadline) return err;
            try std.Io.sleep(io, .fromMilliseconds(2), .awake);
            continue;
        };
        return;
    }
}
