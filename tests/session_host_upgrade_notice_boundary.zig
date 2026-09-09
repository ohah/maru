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
    const contract = try read(allocator, "docs/session-host-upgrade.md", 640 * 1024);
    defer allocator.free(contract);
    const matrix = try read(allocator, "docs/verification-matrix.md", 2 * 1024 * 1024);
    defer allocator.free(matrix);
    const plan = try read(allocator, "docs/plans/new-window-and-chrome.md", 256 * 1024);
    defer allocator.free(plan);

    try std.testing.expectEqual(@as(usize, 1), count(connect, "pub const UpgradeNotice = union(enum)"));
    try std.testing.expectEqual(@as(usize, 1), count(connect, "pub const DetailedOutcome = struct"));
    // One field in DetailedOutcome and one local accumulator in connect-or-launch.
    try std.testing.expectEqual(@as(usize, 2), count(connect, "upgrade_notice: ?UpgradeNotice"));
    try std.testing.expectEqual(@as(usize, 1), count(app_session, "session_host_upgrade_notice_pending: ?"));
    try std.testing.expectEqual(@as(usize, 1), count(app_session, "fn showPendingSessionHostUpgradeNotice("));
    try std.testing.expectEqual(@as(usize, 1), count(app_session, "self.showPendingSessionHostUpgradeNotice();"));
    try std.testing.expectEqual(@as(usize, 3), count(i18n, "app_session_host_upgrade_result"));

    // The product has made the best-effort attempt from the default connect path since U5 wiring.
    // Keep that fact separate from the stronger claim that frozen-release migration is verified:
    // otherwise an old rollout sentence can either disable a working recovery path or overstate the
    // still-unexecuted signed/app/soak gates.
    try std.testing.expectEqual(@as(usize, 1), count(connect, "switch (tryUpgradeExistingHost("));
    try std.testing.expectEqual(@as(usize, 1), count(contract, "자동 upgrade 시도는 기본 connect 경로에 연결하되"));
    try std.testing.expectEqual(@as(usize, 1), count(matrix, "자동 upgrade 시도가 기본 connect 경로에 연결된 사실과 완료 증거를 섞지 않는다."));
    try std.testing.expectEqual(@as(usize, 1), count(plan, "자동 upgrade 시도가 기본 connect 경로에 연결된 사실은 별도다."));
    try std.testing.expectEqual(@as(usize, 0), count(contract, "통과한 뒤에만 자동 upgrade를 기본 활성화한다"));
    try std.testing.expectEqual(@as(usize, 0), count(matrix, "기본 자동 migration을 주장하지 않는다"));
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
