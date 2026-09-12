const std = @import("std");
const product = @import("release_adapter_p5d_candidate_product");

test "mounted candidate gates have one caller each and no workflow or GitHub dependency" {
    _ = product.run;
    const paths = [_][]const u8{
        "src/platform/macos/session_host/release_adapter_p5d_candidate_product.zig",
        "src/platform/macos/session_host/release_adapter_notification_candidate_product.zig",
    };
    for (paths) |path| {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(64 * 1024));
        defer std.testing.allocator.free(bytes);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "dmg.observeWithMountedGate("));
        try std.testing.expect(std.mem.indexOf(u8, bytes, "github") == null);
        try std.testing.expect(std.mem.indexOf(u8, bytes, "GH_TOKEN") == null);
    }

    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "src/platform/macos/session_host", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var iterator = dir.iterate();
    var inventory: usize = 0;
    while (try iterator.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig")) continue;
        const source = try dir.readFileAlloc(std.testing.io, entry.name, std.testing.allocator, .limited(16 * 1024 * 1024));
        defer std.testing.allocator.free(source);
        inventory += std.mem.count(u8, source, "observeWithMountedGate(");
    }
    // One declaration plus the P5d and Notification product calls. Any additional source caller
    // must update this authority inventory explicitly instead of bypassing either composition.
    try std.testing.expectEqual(@as(usize, 3), inventory);
}
