//! Editor CLI namespace. Keep subcommand selection pure so adding future editor
//! commands cannot accidentally reinterpret an unknown command as a filename.
const std = @import("std");
pub const open = @import("editor/open.zig");
pub const help =
    \\usage: maru editor open <file> [-l N | --line N] [-c N | --column N]
    \\       maru editor --help
    \\
    \\Editor commands:
    \\  open  Open one file at a line/UTF-16 column in the default macOS app.
    \\        Use `maru editor open --help` for path and location rules.
    \\
;
pub const Command = union(enum) { help, open_help, open: open.Request };

pub fn parse(args: []const []const u8) !Command {
    if (args.len == 0) return .help;
    if (std.mem.eql(u8, args[0], "--help") or std.mem.eql(u8, args[0], "-h")) {
        if (args.len != 1) return error.InvalidArguments;
        return .help;
    }
    if (!std.mem.eql(u8, args[0], "open")) return error.InvalidArguments;
    return switch (try open.parse(args[1..])) {
        .help => .open_help,
        .request => |request| .{ .open = request },
    };
}

test "editor namespace rejects unknown commands and selects distinct help" {
    try std.testing.expect((try parse(&.{})) == .help);
    try std.testing.expect((try parse(&.{"--help"})) == .help);
    try std.testing.expect((try parse(&.{ "open", "--help" })) == .open_help);
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "wat", "a" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "--help", "open" }));
    try std.testing.expectEqualStrings("a", (try parse(&.{ "open", "a", "-l", "2", "-c", "3" })).open.path);
}
