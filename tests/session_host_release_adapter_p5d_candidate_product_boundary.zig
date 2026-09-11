const std = @import("std");
const product = @import("release_adapter_p5d_candidate_product");

test "P5d mounted gate has one product caller and no workflow or GitHub dependency" {
    _ = product.run;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/platform/macos/session_host/release_adapter_p5d_candidate_product.zig", std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "dmg.observeWithMountedGate("));
    try std.testing.expect(std.mem.indexOf(u8, bytes, "github") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "GITHUB_TOKEN") == null);

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
    // One declaration plus the sole product call above. Any second source caller must update the
    // authority inventory explicitly instead of bypassing the P5d evidence composition.
    try std.testing.expectEqual(@as(usize, 2), inventory);
}
