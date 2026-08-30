const std = @import("std");

test "U5 stale sweep stays private and gates capability construction" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const daemon = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "src/platform/macos/session_host/daemon.zig",
        allocator,
        .limited(2 * 1024 * 1024),
    );
    defer allocator.free(daemon);
    const barrel = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "src/platform/macos/session_host.zig",
        allocator,
        .limited(512 * 1024),
    );
    defer allocator.free(barrel);

    const host_dir = std.mem.indexOf(u8, daemon, "const host_dir =") orelse
        return error.MissingHostDirectory;
    const lease = std.mem.indexOf(u8, daemon, "owner_lease.OwnerLease.acquire(owner_path)") orelse
        return error.MissingOwnerLease;
    const sweep = std.mem.indexOf(u8, daemon, "upgrade_stale_sweep.sweep(host_dir)") orelse
        return error.MissingStaleSweep;
    const rollback = std.mem.indexOf(u8, daemon, "rollback_image.Authority.prepare(") orelse
        return error.MissingRollbackPrepare;
    const owner = std.mem.indexOf(u8, daemon, "upgrade_owner.UpgradeOwner.init(") orelse
        return error.MissingUpgradeOwner;
    try std.testing.expect(lease < host_dir);
    try std.testing.expect(host_dir < sweep);
    try std.testing.expect(sweep < rollback);
    try std.testing.expect(sweep < owner);
    try std.testing.expect(std.mem.indexOf(u8, daemon, "exact_host_id != null and upgrade_residue_clean") != null);
    try std.testing.expect(std.mem.indexOf(u8, barrel, "upgrade_stale_sweep") == null);
}
