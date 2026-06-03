const std = @import("std");
const maru = @import("maru");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    // The CLI is only a development smoke target for now. Keeping it tiny makes
    // it obvious whether the Zig module graph compiles before the macOS app exists.
    const size = maru.terminal.Size.default;
    try stdout.print("maru-dev: clean-room terminal core scaffold ({d}x{d})\n", .{
        size.cols,
        size.rows,
    });
    try stdout.flush();
}

test "development CLI imports maru module" {
    try std.testing.expectEqual(@as(u16, 80), maru.terminal.Size.default.cols);
}
