//! 턴 스냅샷 임시 index(`~/.cache/maru/turn-index-<창>`)의 **수명**.
//!
//! 파일을 **만드는** 자리는 `AppSession.turnIndexPath`, **쓰는** 자리는 `git_backend.takeTurnSnapshot`
//! (`GIT_INDEX_FILE` 로 걸어 `read-tree`·`add -A`·`write-tree`)이고, 이 모듈은 그 파일을 **거두는** 규칙만
//! 든다. 두 규칙이 있다.
//!
//! 1. **창이 닫히면 그 창의 파일을 지운다**(`removeIndexFile`). 이름이 세션 포인터라 창 수명 동안만
//!    뜻이 있다 — 다음 실행에서는 주소가 달라져 **재사용이 일어나지 않는다**(ASLR + 할당 위치).
//!    「남아도 무해하다」는 파일 하나에는 맞지만 **쌓임에는 틀렸다**: 실측 2026-09-15, 8 월 1 일부터
//!    6,123 개(창마다 하나; 최근 7 일은 1,448 개 ≈ 207 개/일)가 남아 있었고 지우는 자리가 없었다.
//! 2. **오래된 형제는 쓸어 낸다**(`sweepStale`). 크래시·강제 종료로 1 이 안 돈 파일은 mtime 이
//!    `stale_after` 를 넘긴 뒤 다음 스냅샷 워커가 거둔다. 살아 있는 창의 파일을 지워도 안전하다 —
//!    `read-tree` 가 없으면 만들고 매번 덮어쓴다(`takeTurnSnapshot`). 그래서 mtime 은 «마지막 스냅샷
//!    시각»이고, 그 뒤로 `stale_after` 동안 스냅샷이 없던 창은 파일을 잃어도 다음 턴에 292 ms(첫 스냅샷)
//!    를 한 번 더 낼 뿐이다(docs/editor-surface-tooling.md §6.1 비용 표).
//!
//! **접두가 아닌 이름은 건드리지 않는다.** 같은 디렉터리에 `terminfo`·`remote-view`·`session-host`
//! 같은 다른 캐시가 산다 — 스윕은 이름 규칙으로만 고른다.
//!
//! **왜 스윕이 워커에 있나.** 실측(2026-09-15, 실제 캐시를 mtime 보존 복사, APFS): 6,127 항목 중 4,678 개
//! 삭제 포함 **Debug 176 ms · ReleaseFast 143 ms**. 메인 스레드(첫 `turnIndexPath`)에서 하면 첫 턴 경계에
//! 프레임 열 장을 먹는다 — 스냅샷 워커는 이미 detached 스레드라 거기서 **프로세스당 한 번**
//! (`sweepStaleSiblingsOnce`) 돈다. 쌓인 것을 다 거둔 뒤의 정상 상태는 항목 수백 개·삭제 0 이라 훨씬 싸다.
const std = @import("std");

/// 임시 index 파일 이름의 접두. `AppSession.turnIndexPath` 가 이것으로 이름을 짓는다 — 두 자리가 갈리면
/// 스윕이 아무것도 안 고르거나(공허) 남의 파일을 고른다. 판정자가 그쪽 문자열과 같은지 센다.
pub const prefix = "turn-index-";

/// 이 시간 동안 스냅샷이 없던 파일을 스윕이 거둔다. 7 일인 이유: 창이 그보다 오래 열려 있으면서 턴이 한
/// 번도 없는 경우는 드물고, 있더라도 잃는 것은 첫 스냅샷 비용 한 번이다.
pub const stale_after: std.Io.Duration = .{ .nanoseconds = 7 * std.time.ns_per_day };

pub const SweepReport = struct {
    /// 접두가 맞고 오래돼서 지운 수.
    removed: u32 = 0,
    /// 접두가 맞지만 아직 새것이라 둔 수.
    kept: u32 = 0,
    /// 접두가 다른 항목 — 세기만 하고 건드리지 않는다.
    other: u32 = 0,
    /// `stat`·삭제가 실패한 수(권한·경합). 실패는 다음 스윕이 다시 본다.
    failed: u32 = 0,
};

/// `dir` 안에서 `prefix` 로 시작하는 **일반 파일** 중 mtime 이 `now - stale_after` 보다 오래된 것을 지운다.
/// 디렉터리·심볼릭 링크는 접두가 맞아도 `other` 다(이 모듈이 만드는 것은 일반 파일뿐이다).
pub fn sweepStale(io: std.Io, dir: std.Io.Dir, now: std.Io.Timestamp, stale: std.Io.Duration) SweepReport {
    var report: SweepReport = .{};
    const cutoff = now.subDuration(stale);
    var it = dir.iterate();
    while (it.next(io) catch return report) |entry| {
        if (!std.mem.startsWith(u8, entry.name, prefix) or entry.kind != .file) {
            report.other += 1;
            continue;
        }
        const stat = dir.statFile(io, entry.name, .{ .follow_symlinks = false }) catch {
            report.failed += 1;
            continue;
        };
        if (stat.mtime.nanoseconds >= cutoff.nanoseconds) {
            report.kept += 1;
            continue;
        }
        dir.deleteFile(io, entry.name) catch {
            report.failed += 1;
            continue;
        };
        report.removed += 1;
    }
    return report;
}

var swept_once: std.atomic.Value(bool) = .init(false);

/// `index_path` 의 **형제**(같은 디렉터리의 `prefix` 파일)를 프로세스당 한 번 쓸어 낸다. 스냅샷 워커가
/// 부른다 — 첫 스냅샷이 있는 프로세스만 스윕하므로 이 기능을 안 쓰는 사용자는 비용이 0 이다.
/// 두 번째부터는 `null`(안 돌았다).
pub fn sweepStaleSiblingsOnce(io: std.Io, index_path: []const u8) ?SweepReport {
    if (swept_once.swap(true, .acq_rel)) return null;
    return sweepStaleSiblings(io, index_path);
}

/// 같은 일을 매번 한다 — 판정자와 `sweepStaleSiblingsOnce` 가 쓴다.
pub fn sweepStaleSiblings(io: std.Io, index_path: []const u8) ?SweepReport {
    const parent = std.fs.path.dirname(index_path) orelse return null;
    var dir = std.Io.Dir.openDirAbsolute(io, parent, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    return sweepStale(io, dir, std.Io.Timestamp.now(io, .real), stale_after);
}

/// 판정자 전용 — 「한 번」 플래그를 되돌린다. 제품에는 부를 자리가 없다.
pub fn resetSweepOnceForTest() void {
    swept_once.store(false, .release);
}

/// 창이 닫힐 때 그 창의 임시 index 를 지운다. 없으면(스냅샷이 한 번도 안 찍힌 창) 그대로 성공이다.
/// 그 밖의 실패는 삼킨다 — 창 닫기를 파일 하나 때문에 막지 않고, 남은 파일은 스윕이 거둔다.
pub fn removeIndexFile(io: std.Io, index_path: []const u8) void {
    std.Io.Dir.deleteFileAbsolute(io, index_path) catch {};
}

// ── 판정자 ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn touchWithMtime(io: std.Io, dir: std.Io.Dir, name: []const u8, mtime: std.Io.Timestamp) !void {
    var file = try dir.createFile(io, name, .{});
    defer file.close(io);
    try file.setTimestamps(io, .{ .modify_timestamp = .{ .new = mtime } });
}

fn exists(io: std.Io, dir: std.Io.Dir, name: []const u8) bool {
    dir.access(io, name, .{}) catch return false;
    return true;
}

test "오래된 index 는 지우고 새 index 와 다른 이름은 둔다 — 부정 대조 둘" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const now: std.Io.Timestamp = .{ .nanoseconds = 1_800_000_000 * std.time.ns_per_s };
    const old = now.subDuration(.{ .nanoseconds = stale_after.nanoseconds + std.time.ns_per_hour });
    const fresh = now.subDuration(.{ .nanoseconds = stale_after.nanoseconds - std.time.ns_per_hour });
    try touchWithMtime(io, tmp.dir, "turn-index-1", old);
    try touchWithMtime(io, tmp.dir, "turn-index-2.lock", old); // git 이 죽으며 남긴 잠금도 접두가 같다
    try touchWithMtime(io, tmp.dir, "turn-index-3", fresh);
    try touchWithMtime(io, tmp.dir, "other-index-4", old); // 접두가 다르면 아무리 오래돼도 남는다
    try touchWithMtime(io, tmp.dir, "turn-index", old); // 접두 미만(대시 없음)도 남는다
    try tmp.dir.createDirPath(io, "turn-index-5"); // 디렉터리는 접두가 맞아도 안 건드린다

    const report = sweepStale(io, tmp.dir, now, stale_after);
    try testing.expectEqual(@as(u32, 2), report.removed);
    try testing.expectEqual(@as(u32, 1), report.kept);
    try testing.expectEqual(@as(u32, 3), report.other);
    try testing.expectEqual(@as(u32, 0), report.failed);
    try testing.expect(!exists(io, tmp.dir, "turn-index-1"));
    try testing.expect(!exists(io, tmp.dir, "turn-index-2.lock"));
    try testing.expect(exists(io, tmp.dir, "turn-index-3"));
    try testing.expect(exists(io, tmp.dir, "other-index-4"));
    try testing.expect(exists(io, tmp.dir, "turn-index"));
    try testing.expect(exists(io, tmp.dir, "turn-index-5"));
}

test "경계: 딱 stale_after 만큼 오래된 것은 남고 1 ns 더 오래되면 지워진다" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const now: std.Io.Timestamp = .{ .nanoseconds = 1_800_000_000 * std.time.ns_per_s };
    // APFS 는 ns 단위 mtime 을 그대로 저장한다 — 경계를 1 ns 로 잘라도 실측이 같다.
    try touchWithMtime(io, tmp.dir, "turn-index-at", now.subDuration(stale_after));
    try touchWithMtime(io, tmp.dir, "turn-index-past", now.subDuration(.{ .nanoseconds = stale_after.nanoseconds + 1 }));
    const report = sweepStale(io, tmp.dir, now, stale_after);
    try testing.expectEqual(@as(u32, 1), report.removed);
    try testing.expectEqual(@as(u32, 1), report.kept);
    try testing.expect(exists(io, tmp.dir, "turn-index-at"));
    try testing.expect(!exists(io, tmp.dir, "turn-index-past"));
}

test "형제 스윕은 index 경로의 디렉터리를 보고, 「한 번」은 두 번째 호출에 null 이다" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const index_path = try std.fmt.bufPrint(&path_buf, "{s}/turn-index-live", .{root});

    const now = std.Io.Timestamp.now(io, .real);
    try touchWithMtime(io, tmp.dir, "turn-index-old", now.subDuration(.{ .nanoseconds = stale_after.nanoseconds + std.time.ns_per_hour }));
    try touchWithMtime(io, tmp.dir, "turn-index-live", now);

    resetSweepOnceForTest();
    const first = sweepStaleSiblingsOnce(io, index_path) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 1), first.removed);
    try testing.expectEqual(@as(u32, 1), first.kept);
    try testing.expect(exists(io, tmp.dir, "turn-index-live"));
    try testing.expect(!exists(io, tmp.dir, "turn-index-old"));

    // 두 번째는 안 돈다 — 새로 오래된 것을 놓아도 그대로다.
    try touchWithMtime(io, tmp.dir, "turn-index-old2", now.subDuration(.{ .nanoseconds = stale_after.nanoseconds + std.time.ns_per_hour }));
    try testing.expect(sweepStaleSiblingsOnce(io, index_path) == null);
    try testing.expect(exists(io, tmp.dir, "turn-index-old2"));
    resetSweepOnceForTest();
}

test "창의 index 는 지워지고, 없는 파일은 조용히 지나간다" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const index_path = try std.fmt.bufPrint(&path_buf, "{s}/turn-index-7", .{root});

    try tmp.dir.writeFile(io, .{ .sub_path = "turn-index-7", .data = "DIRC" });
    try testing.expect(exists(io, tmp.dir, "turn-index-7"));
    removeIndexFile(io, index_path);
    try testing.expect(!exists(io, tmp.dir, "turn-index-7"));
    removeIndexFile(io, index_path); // 두 번째: 없음 → 실패도 패닉도 아니다
}
