//! U5 upgrade-result notice product boundary.
//!
//! An upgrade attempt can fail and still end with a perfectly usable newly spawned host. If the
//! connect layer returns only that final Client, the reason the old PTYs were not migrated is lost
//! before AppSession can show it. This gate keeps the typed diagnostic on the same return path as
//! the Client and requires the UI to consume it once instead of recreating state in a global flag.

const std = @import("std");

test "U5 upgrade result stays typed through connect and one-shot AppSession notice" {
    const allocator = std.testing.allocator;
    const connect = try read(allocator, "src/platform/macos/session_host/host_connect.zig", 256 * 1024);
    defer allocator.free(connect);
    const app_session = try read(allocator, "src/platform/macos/app_session.zig", 8 * 1024 * 1024);
    defer allocator.free(app_session);
    const i18n = try read(allocator, "src/i18n.zig", 512 * 1024);
    defer allocator.free(i18n);

    try std.testing.expectEqual(@as(usize, 1), count(connect, "pub const UpgradeNotice = union(enum)"));
    try std.testing.expectEqual(@as(usize, 1), count(connect, "pub const DetailedOutcome = struct"));
    try std.testing.expectEqual(@as(usize, 1), count(connect, "upgrade_notice: ?UpgradeNotice"));
    try std.testing.expectEqual(@as(usize, 1), count(app_session, "session_host_upgrade_notice_pending: ?"));
    try std.testing.expectEqual(@as(usize, 1), count(app_session, "fn showPendingSessionHostUpgradeNotice("));
    try std.testing.expectEqual(@as(usize, 1), count(app_session, "self.showPendingSessionHostUpgradeNotice();"));
    try std.testing.expectEqual(@as(usize, 3), count(i18n, "app_session_host_upgrade_result"));
}

fn read(allocator: std.mem.Allocator, path: []const u8, max: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(max));
}

fn count(haystack: []const u8, needle: []const u8) usize {
    var total: usize = 0;
    var rest = haystack;
    while (std.mem.indexOf(u8, rest, needle)) |index| {
        total += 1;
        rest = rest[index + needle.len ..];
    }
    return total;
}
