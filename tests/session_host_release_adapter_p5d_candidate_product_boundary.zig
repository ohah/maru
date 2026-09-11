const std = @import("std");
const product = @import("release_adapter_p5d_candidate_product");

test "P5d mounted gate has one product caller and no workflow or GitHub dependency" {
    _ = product.run;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/platform/macos/session_host/release_adapter_p5d_candidate_product.zig", std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "dmg.observeWithMountedGate("));
    try std.testing.expect(std.mem.indexOf(u8, bytes, "github") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "GITHUB_TOKEN") == null);
}
