//! `owner.lock` 이름 유지가 **두 서브 루프 모두에** 배선돼 있는가.
//!
//! 이 게이트가 있는 이유는 실패 자체가 「한쪽에만 있었다」였기 때문이다. 자리 갱신은 첫 실행 경로
//! (`daemon`)에만 있었고 exec 로 승계한 뒤의 경로(`restore_activation.serveLoop`)에는 없었다. 그래서 한 번이라도
//! 업그레이드한 host 는 그 시점부터 tmp 정리 보호를 통째로 잃고, 자기 `owner.lock` 이름을 잃은 채 살아남아
//! 승계 대상에서 영구히 빠졌다(2026-09-27 실측: `upgrade_epoch=3` 인 8 일 된 host).
//!
//! 순수 판정자는 `owner_lease` 의 감사·치유 **계약**을 잰다. 그 계약이 **불려지는가**는 여기서 잰다 —
//! 루프를 실제로 돌리려면 살아 있는 host 가 필요하고, 그것은 사용자의 셸을 건드린다.

const std = @import("std");

test "owner.lock 이름 유지: 첫 실행 경로와 승계 경로가 **둘 다** 갱신하고 감사한다" {
    const allocator = std.testing.allocator;
    const daemon = try read(allocator, "src/platform/macos/session_host/daemon.zig", 4 * 1024 * 1024);
    defer allocator.free(daemon);
    const restore = try read(allocator, "src/platform/macos/session_host/restore_activation.zig", 2 * 1024 * 1024);
    defer allocator.free(restore);
    const retention = try read(allocator, "src/platform/macos/session_host/tmp_retention.zig", 128 * 1024);
    defer allocator.free(retention);
    const lease = try read(allocator, "src/platform/macos/session_host/owner_lease.zig", 256 * 1024);
    defer allocator.free(lease);
    const contract = try read(allocator, "docs/session-host-upgrade.md", 640 * 1024);
    defer allocator.free(contract);

    // 갱신 목록의 **단일 출처**. 두 벌이 되면 한쪽만 고쳐지고 그게 이 사고였다.
    try std.testing.expectEqual(@as(usize, 1), count(retention, "pub fn touchAll("));
    try std.testing.expectEqual(@as(usize, 1), count(retention, "subject.owner_path.ptr"));
    try std.testing.expectEqual(@as(usize, 1), count(retention, "pub fn shouldTouch("));

    // 두 루프가 그 출처를 쓴다.
    try std.testing.expectEqual(@as(usize, 1), count(daemon, "tmp_retention.touchAll("));
    try std.testing.expectEqual(@as(usize, 1), count(restore, "tmp_retention.touchAll("));
    try std.testing.expectEqual(@as(usize, 1), count(daemon, "tmp_retention.shouldTouch("));
    try std.testing.expectEqual(@as(usize, 1), count(restore, "tmp_retention.shouldTouch("));

    // 감사·치유도 두 루프 모두에 있다.
    try std.testing.expectEqual(@as(usize, 1), count(lease, "pub fn auditOwnedPath("));
    try std.testing.expectEqual(@as(usize, 1), count(lease, "pub fn healOwnedPath("));
    try std.testing.expectEqual(@as(usize, 1), count(daemon, "auditOwnedPath(owner_path)"));
    try std.testing.expectEqual(@as(usize, 1), count(daemon, "healOwnedPath(owner_path)"));
    try std.testing.expectEqual(@as(usize, 1), count(restore, "auditOwnedPath(retention.owner_path)"));
    try std.testing.expectEqual(@as(usize, 1), count(restore, "healOwnedPath(retention.owner_path)"));

    // 계약 문서가 그 사실을 적는다 — 코드만 고치고 문서가 침묵하면 다음 사람이 한쪽을 지운다.
    try std.testing.expectEqual(@as(usize, 1), count(contract, "**승계한 host도 이 일을 한다**"));
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
