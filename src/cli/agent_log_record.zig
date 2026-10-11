//! Parse the whole record invocation before stdin or file I/O.
const std = @import("std");
const command = @import("../session/agent_hook_command.zig");
pub const usage = "usage: maru agent-hooks record --file=<absolute .ndjson path>\n";
pub const Options = struct { directory: []const u8, name: []const u8 };

pub fn parse(args: []const []const u8) !Options {
    if (args.len != 1 or !std.mem.startsWith(u8, args[0], "--file=")) return error.InvalidArguments;
    const path = args[0]["--file=".len..];
    if (path.len == 0 or path[0] != '/' or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidArguments;
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return error.InvalidArguments;
    if (slash == 0 or !std.mem.endsWith(u8, path, ".ndjson")) return error.InvalidArguments;
    const name = path[slash + 1 .. path.len - ".ndjson".len];
    if (name.len > command.remote_log_name_max or !command.instance_token_class.accepts(name)) return error.InvalidArguments;
    var components = std.mem.splitScalar(u8, path[1..slash], '/');
    while (components.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidArguments;
    }
    return .{ .directory = path[0..slash], .name = name };
}

test "record args require one absolute file without traversal or ambiguous selectors" {
    const t = std.testing;
    const o = try parse(&.{"--file=/private/cache/a_2.ndjson"});
    try t.expectEqualStrings("/private/cache", o.directory);
    try t.expectEqualStrings("a_2", o.name);
    for ([_][]const u8{ "--file=a.ndjson", "--file=/a.ndjson", "--file=/p//a.ndjson", "--file=/p/../a.ndjson", "--file=/p/./a.ndjson", "--file=/p/.ndjson", "--file=/p/a.json", "--file=/p/a\x00.ndjson" }) |arg| try t.expectError(error.InvalidArguments, parse(&.{arg}));
    try t.expectError(error.InvalidArguments, parse(&.{}));
    try t.expectError(error.InvalidArguments, parse(&.{ "--file=/p/a.ndjson", "--file=/p/a.ndjson" }));
}

test "native hook command rejects executable fallback and quotes shell metacharacters" {
    const t = std.testing;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(t.allocator);
    for ([_][]const u8{ "", "maru", "./maru", "/a\nmaru", "/a\rmaru", "/a\x00maru" }) |binary| {
        try t.expectError(error.InvalidExecutable, command.buildNative(&out, t.allocator, "claude", "/p", "/p", binary));
        try t.expectEqual(@as(usize, 0), out.items.len);
    }
    try command.buildNative(&out, t.allocator, "claude", "/p", "/p", "/private/maru's $(false)");
    try t.expect(std.mem.indexOf(u8, out.items, "'/private/maru'\\''s $(false)' agent-hooks record") != null);
    try t.expect(command.isOurs(out.items));
}
