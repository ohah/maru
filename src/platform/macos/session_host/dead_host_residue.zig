//! 죽은 host 가 `<session_dir>` 에 남긴 잔재를 거둔다(daemon 시작).
//!
//! host 는 정상 종료에서 자기 것을 스스로 치운다 — manifest·`owner.lock`·`rollback-current` 는 `defer` 로
//! 철거되고 빈 `hosts/<id>/` 는 `removeEmptyHostDirectories` 가 지운다. **SIGKILL·크래시·전원 차단**에서는
//! 그 `defer` 가 안 돌고, 아무도 남의 자리를 치우지 않았다. 실측 2026-09-15(사용자 머신):
//!
//!   - `hosts/<id>/` 64 개 중 살아 있는 host 는 10 개 남짓. 죽은 것 29 개가 `rollback-current`(host 바이너리
//!     사본, 각 44 MB)를 들고 있어 **1.0 GB**.
//!   - `host-<id>.log` 87 개(347 KB) — 종료해도 안 지운다(사후 진단용이라 그 자체는 맞다). 그러나 상한이 없다.
//!   - `preflight.log` 는 append 전용으로 1,075 줄·81 KB — 상한 없음.
//!
//! **살아 있는가**는 `owner_lease.observe` 가 답한다(flock). `held`·`unknown` 은 남긴다 — 모르면 남긴다는
//! 규율은 `agent_hook_logs.sweepDeadHostDirs` 와 같다(산 host 의 자리를 지우면 그 host 의 업그레이드가 그
//! 자리에서 죽고, 죽은 자리를 남기면 다음 시작이 거둔다 — 대가가 비대칭이다).
//!
//! ⚠️ **죽은 host 의 디렉터리 자체·manifest·`owner.lock` 은 지우지 않는다.** «manifest 가 있는데 lease 가
//! 풀렸다»는 조합이 GUI 의 **host 종료 확정 신호**다 — 그 신호로 저장된 runtime handle 을 `ended` 로 닫는다
//! (docs/persistent-session-host.md «죽은 entry 를 열거 결과에서 지우지는 않는다»). 파일을 지우면 다음
//! 실행이 그것을 «endpoint 미발견 = 생존 가능성 있음» 으로 격하해 stale handle 이 영영 안 풀린다. 정상 종료는
//! host 가 스스로 지우지만 그때는 runtime 이 0 이라 닫을 handle 이 없다. discovery 의 상한(16)은 `.free` 를
//! 세지 않으므로 신호 파일 두 개가 남는 것은 기능에 해가 없다. 그래서 여기서 지우는 것은 **신호가 아닌 무거운
//! 잔재**뿐이다: `rollback-current`·`rollback-previous`(host 바이너리 사본)와 `target-<id>.image`
//! (업그레이드로 받은 이미지, `.sweep-` 묘비 포함). 그 이름들은 `rollback_image`·`upgrade_target` 이 짓는다.
//!
//! **막 뜨는 host 의 창.** `prepareHostDirectory`(mkdir) 와 `OwnerLease.acquire`(lock 파일 생성 + flock) 사이에는
//! `observe` 가 NOENT 로 `free` 를 준다. 그 창을 이름으로는 못 가르므로 **디렉터리 mtime 이 `dir_grace` 보다
//! 새로우면 남긴다.** 죽은 host 의 디렉터리 mtime 은 죽은 시각에 멈춰 있고 잔재는 며칠 단위로 쌓이므로 1 시간
//! 유예는 아무것도 잃지 않는다. host id 는 launch 마다 `arc4random` 128 비트라 죽은 id 가 되살아나는 경로는
//! 없다(`daemon.newHostId`) — 그래서 죽은 host 의 이미지는 **바로** 지워도 된다.
//!
//! 로그는 다르다: 죽은 host 의 `host-<id>.log` 는 «왜 죽었나»를 답하는 유일한 흔적이라 `log_stale_after`
//! (7 일) 동안 남기고 그 뒤에 지운다. `preflight.log` 는 `preflight_log_max_bytes` 를 넘으면 `.1` 로 한 번
//! 회전한다(두 번째 회전은 첫 번째를 덮는다 — 상한은 최대 2 배).
//!
//! **우리 모양이 아닌 이름은 건드리지 않는다**(`hosts/<32 hex>/` 안의 위 어휘·`host-<32 hex>.log` 만).
//! 심링크·남의 uid 는 `fstatat(NOFOLLOW)` + uid 검사로 거르고, 삭제는 이름 하나씩 `unlinkat` 이다 — 재귀 삭제를
//! 안 쓰는 이유는 심링크 대상의 내용을 지울 수 있어 대가가 크기 때문이다.
const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;
const owner_lease = @import("owner_lease.zig");
const host_manifest = @import("host_manifest.zig");

/// 죽은 host 의 로그를 남겨 두는 기간 — 사후 진단 창.
pub const log_stale_after_s: i64 = 7 * 24 * 60 * 60;
/// 디렉터리가 이보다 새로우면 «막 뜨는 host» 로 보고 남긴다(머리말).
pub const dir_grace_s: i64 = 60 * 60;
/// `preflight.log` 회전 문턱.
pub const preflight_log_max_bytes: u64 = 1 << 20;
/// 한 번의 sweep 이 보는 항목 상한 — 넘으면 다음 시작이 이어 거둔다(무한 루프 이유가 없다).
pub const max_entries: usize = 256;

pub const Report = struct {
    /// 죽은 host 디렉터리 중 이미지를 하나라도 지운 수.
    dirs_swept: u32 = 0,
    /// 지운 이미지 파일 수와 바이트.
    images_removed: u32 = 0,
    bytes_reclaimed: u64 = 0,
    dirs_live: u32 = 0,
    dirs_young: u32 = 0,
    dirs_unknown: u32 = 0,
    logs_removed: u32 = 0,
    logs_kept: u32 = 0,
    preflight_rotated: bool = false,

    pub fn anyRemoved(self: Report) bool {
        return self.images_removed > 0 or self.logs_removed > 0 or self.preflight_rotated;
    }
};

const Liveness = enum { live, dead, young, unknown };

/// `session_dir` 안의 잔재를 거둔다. `own_host_id` 의 것은 어떤 판정과도 무관하게 남긴다(자기 lock 은 아직 안
/// 잡혔을 수 있다). `now_s` 는 벽시계(초) — 판정자가 시각을 고정하려고 인자로 받는다.
pub fn sweep(io: std.Io, session_dir: [:0]const u8, own_host_id: u128, now_s: i64) Report {
    var report: Report = .{};
    if (builtin.os.tag != .macos) return report;
    // 로그를 **먼저** 본다 — 이미지를 unlink 하면 그 디렉터리의 mtime 이 «지금» 이 되어, 뒤에 보면 죽은 host 가
    // 유예 창 안의 «막 뜬 host» 로 읽혀 로그가 한 시작 더 남는다(e2e 판정자가 잡았다).
    sweepHostLogs(io, session_dir, own_host_id, now_s, &report);
    sweepHostDirs(io, session_dir, own_host_id, now_s, &report);
    report.preflight_rotated = rotatePreflightLog(session_dir);
    return report;
}

fn sweepHostDirs(io: std.Io, session_dir: [:0]const u8, own_host_id: u128, now_s: i64, report: *Report) void {
    var root_buf: [640]u8 = undefined;
    const root = host_manifest.hostsRootPathIn(&root_buf, session_dir) catch return;
    var handle = std.Io.Dir.openDirAbsolute(io, root, .{ .iterate = true }) catch return;
    defer handle.close(io);
    // 훑고 나서 지운다 — 순회 중 삭제는 readdir 이 뒤 항목을 건너뛰게 한다(`agent_hook_logs` 와 같은 규율).
    var doomed: [max_entries]u128 = undefined;
    var count: usize = 0;
    var it = handle.iterate();
    var seen: usize = 0;
    while (it.next(io) catch null) |entry| {
        seen += 1;
        if (seen > max_entries) break;
        if (entry.kind != .directory) continue;
        const id = hostIdFromHex(entry.name) orelse continue;
        if (id == own_host_id) continue;
        switch (hostDirLiveness(session_dir, id, now_s)) {
            .live => report.dirs_live += 1,
            .young => report.dirs_young += 1,
            .unknown => report.dirs_unknown += 1,
            .dead => {
                if (count < doomed.len) {
                    doomed[count] = id;
                    count += 1;
                }
            },
        }
    }
    for (doomed[0..count]) |id| {
        var dir_buf: [768]u8 = undefined;
        const dir = host_manifest.hostDirPathIn(&dir_buf, session_dir, id) catch continue;
        const before = report.images_removed;
        removeHeavyResidue(io, dir, report);
        if (report.images_removed > before) report.dirs_swept += 1;
    }
}

/// 죽은 host 디렉터리 안의 **이미지 파일만** 지운다(머리말의 닫힌 어휘). manifest·lock·그 밖의 이름은 남긴다.
fn removeHeavyResidue(io: std.Io, dir: [:0]const u8, report: *Report) void {
    var handle = std.Io.Dir.openDirAbsolute(io, dir, .{ .iterate = true }) catch return;
    defer handle.close(io);
    var names: [max_entries][80]u8 = undefined;
    var lens: [max_entries]usize = undefined;
    var count: usize = 0;
    var it = handle.iterate();
    while (it.next(io) catch null) |entry| {
        if (count >= max_entries) break;
        if (entry.kind != .file or !isHeavyResidueName(entry.name) or entry.name.len >= 80) continue;
        @memcpy(names[count][0..entry.name.len], entry.name);
        lens[count] = entry.name.len;
        count += 1;
    }
    for (names[0..count], lens[0..count]) |*name_buf, len| {
        var path_buf: [1024]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ dir, name_buf[0..len] }) catch continue;
        var st: posix.Stat = undefined;
        if (c.fstatat(posix.AT.FDCWD, path.ptr, &st, posix.AT.SYMLINK_NOFOLLOW) != 0) continue;
        if (!posix.S.ISREG(st.mode) or st.uid != c.getuid()) continue;
        if (c.unlink(path.ptr) != 0) continue;
        report.images_removed += 1;
        report.bytes_reclaimed += @intCast(@max(st.size, 0));
    }
}

/// 무거운 잔재의 닫힌 어휘. `rollback_image.current_leaf`·`previous_residue_leaf`, `upgrade_target` 의
/// `target-<32 hex>.image`, `upgrade_stale_sweep` 의 묘비 `.sweep-target-<32 hex>.image`.
pub fn isHeavyResidueName(name: []const u8) bool {
    if (std.mem.eql(u8, name, "rollback-current") or std.mem.eql(u8, name, "rollback-previous")) return true;
    const forms = [_]struct { prefix: []const u8, suffix: []const u8 }{
        .{ .prefix = "target-", .suffix = ".image" },
        .{ .prefix = ".sweep-target-", .suffix = ".image" },
    };
    for (forms) |form| {
        if (name.len != form.prefix.len + 32 + form.suffix.len) continue;
        if (!std.mem.startsWith(u8, name, form.prefix) or !std.mem.endsWith(u8, name, form.suffix)) continue;
        return hostIdFromHex(name[form.prefix.len .. form.prefix.len + 32]) != null;
    }
    return false;
}

/// 그 host 의 디렉터리가 어느 상태인가(머리말의 네 갈래).
fn hostDirLiveness(session_dir: [:0]const u8, id: u128, now_s: i64) Liveness {
    var dir_buf: [768]u8 = undefined;
    const dir = host_manifest.hostDirPathIn(&dir_buf, session_dir, id) catch return .unknown;
    var st: posix.Stat = undefined;
    const rc = c.fstatat(posix.AT.FDCWD, dir.ptr, &st, posix.AT.SYMLINK_NOFOLLOW);
    // 디렉터리가 없으면 «죽었다» — 정상 종료가 빈 디렉터리를 지우므로 로그만 남은 host 가 이 모양이다.
    // 그 밖의 실패(권한 등)는 모른다.
    if (rc != 0) return if (posix.errno(rc) == .NOENT) .dead else .unknown;
    if (!posix.S.ISDIR(st.mode) or st.uid != c.getuid()) return .unknown;
    var lock_buf: [832]u8 = undefined;
    const lock = host_manifest.ownerLockPathIn(&lock_buf, session_dir, id) catch return .unknown;
    switch (owner_lease.observe(lock)) {
        .held => return .live,
        .unknown => return .unknown,
        .free => {},
    }
    const age = now_s - @as(i64, @intCast(st.mtimespec.sec));
    return if (age < dir_grace_s) .young else .dead;
}

/// 그 host 가 살아 있는가 — 로그 판정용. 디렉터리가 없으면 «죽었다»(정상 종료가 빈 디렉터리를 지운다).
fn hostAlive(session_dir: [:0]const u8, id: u128, now_s: i64) bool {
    return switch (hostDirLiveness(session_dir, id, now_s)) {
        .live, .young, .unknown => true,
        .dead => false,
    };
}

fn sweepHostLogs(io: std.Io, session_dir: [:0]const u8, own_host_id: u128, now_s: i64, report: *Report) void {
    var handle = std.Io.Dir.openDirAbsolute(io, session_dir, .{ .iterate = true }) catch return;
    defer handle.close(io);
    var doomed: [max_entries]u128 = undefined;
    var count: usize = 0;
    var it = handle.iterate();
    var seen: usize = 0;
    while (it.next(io) catch null) |entry| {
        seen += 1;
        if (seen > max_entries) break;
        if (entry.kind != .file) continue;
        const id = hostIdFromLogName(entry.name) orelse continue;
        if (id == own_host_id) continue;
        var log_buf: [1024]u8 = undefined;
        const path = std.fmt.bufPrintZ(&log_buf, "{s}/{s}", .{ session_dir, entry.name }) catch continue;
        var st: posix.Stat = undefined;
        if (c.fstatat(posix.AT.FDCWD, path.ptr, &st, posix.AT.SYMLINK_NOFOLLOW) != 0) continue;
        if (!posix.S.ISREG(st.mode) or st.uid != c.getuid()) continue;
        const age = now_s - @as(i64, @intCast(st.mtimespec.sec));
        if (age < log_stale_after_s or hostAlive(session_dir, id, now_s)) {
            report.logs_kept += 1;
            continue;
        }
        if (count < doomed.len) {
            doomed[count] = id;
            count += 1;
        }
    }
    for (doomed[0..count]) |id| {
        var log_buf: [1024]u8 = undefined;
        const path = logPathIn(&log_buf, session_dir, id) catch continue;
        if (c.unlink(path.ptr) == 0) report.logs_removed += 1;
    }
}

/// `daemon.redirectStderrToHostLog` 와 같은 이름 규칙. 그쪽이 단일 출처이고 여기는 읽기만 한다.
pub fn logPathIn(buf: []u8, session_dir: []const u8, id: u128) error{NoSpaceLeft}![:0]u8 {
    return std.fmt.bufPrintZ(buf, "{s}/host-{x:0>32}.log", .{ session_dir, id });
}

pub const log_prefix = "host-";
pub const log_suffix = ".log";
pub const preflight_log_leaf = "preflight.log";
pub const preflight_log_rotated_leaf = "preflight.log.1";

/// `preflight.log` 가 문턱을 넘으면 `.1` 로 옮긴다(없으면·작으면 아무 일도 없다).
fn rotatePreflightLog(session_dir: [:0]const u8) bool {
    var path_buf: [1024]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ session_dir, preflight_log_leaf }) catch return false;
    var st: posix.Stat = undefined;
    if (c.fstatat(posix.AT.FDCWD, path.ptr, &st, posix.AT.SYMLINK_NOFOLLOW) != 0) return false;
    if (!posix.S.ISREG(st.mode) or st.uid != c.getuid()) return false;
    if (@as(u64, @intCast(st.size)) <= preflight_log_max_bytes) return false;
    var rotated_buf: [1024]u8 = undefined;
    const rotated = std.fmt.bufPrintZ(&rotated_buf, "{s}/{s}", .{ session_dir, preflight_log_rotated_leaf }) catch return false;
    // rename 은 원자적이고, 열려 있는 쓰기 fd(살아 있는 preflight 자식)는 옮겨진 inode 에 계속 쓴다 —
    // 잃는 줄이 없다. 다음 preflight 는 새 파일을 만든다(O_CREAT|O_APPEND).
    return c.rename(path.ptr, rotated.ptr) == 0;
}

/// `<32 hex>` 면 그 host_id. `host_manifest.hostDirPathIn` 이 `{x:0>32}` 로 짓는다.
fn hostIdFromHex(name: []const u8) ?u128 {
    if (name.len != 32) return null;
    return std.fmt.parseInt(u128, name, 16) catch null;
}

/// `host-<32 hex>.log` 면 그 host_id.
fn hostIdFromLogName(name: []const u8) ?u128 {
    if (!std.mem.startsWith(u8, name, log_prefix) or !std.mem.endsWith(u8, name, log_suffix)) return null;
    return hostIdFromHex(name[log_prefix.len .. name.len - log_suffix.len]);
}

// ── 판정자 ────────────────────────────────────────────────────────────────────

const testing = std.testing;

const Fixture = struct {
    base: [:0]u8,
    session_dir: [:0]u8,
    base_buf: [128]u8 = undefined,
    dir_buf: [256]u8 = undefined,

    fn init(self: *Fixture, tag: []const u8) !void {
        self.base = try std.fmt.bufPrintZ(&self.base_buf, "/tmp/maru-sh-dhr-{s}-{d}", .{ tag, c.getpid() });
        _ = std.Io.Dir.cwd().deleteTree(testing.io, self.base) catch {};
        _ = c.mkdir(self.base.ptr, 0o700);
        self.session_dir = try std.fmt.bufPrintZ(&self.dir_buf, "{s}/session-host", .{self.base});
        _ = c.mkdir(self.session_dir.ptr, 0o700);
    }

    fn deinit(self: *Fixture) void {
        std.Io.Dir.cwd().deleteTree(testing.io, self.base) catch {};
    }

    /// `hosts/<id>/` 에 manifest 흉내와 큰 `rollback-current` 흉내를 놓고 mtime 을 `age_s` 만큼 과거로 둔다.
    fn deadHost(self: *Fixture, id: u128, age_s: i64, now_s: i64) !void {
        try host_manifest.prepareHostDirectory(self.session_dir, id);
        var dir_buf: [768]u8 = undefined;
        const dir = try host_manifest.hostDirPathIn(&dir_buf, self.session_dir, id);
        try writeIn(dir, "host.v1.json", "{}");
        try writeIn(dir, "rollback-current", "MACHO");
        try writeIn(dir, "target-000000000000000000000000000000aa.image", "MACHO-target");
        try writeIn(dir, "attempt-000000000000000000000000000000aa", "{}"); // 작은 기록 — 어휘 밖, 남긴다
        try setMtime(dir, now_s - age_s);
    }

    fn log(self: *Fixture, id: u128, age_s: i64, now_s: i64) !void {
        var buf: [1024]u8 = undefined;
        const path = try logPathIn(&buf, self.session_dir, id);
        try writeIn(self.session_dir, std.fs.path.basename(path), "session host started\n");
        try setMtime(path, now_s - age_s);
    }
};

fn writeIn(dir: [:0]const u8, leaf: []const u8, data: []const u8) !void {
    var buf: [1024]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, leaf });
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = data });
}

fn setMtime(path: [:0]const u8, at_s: i64) !void {
    const times = [2]c.timespec{
        .{ .sec = @intCast(at_s), .nsec = 0 },
        .{ .sec = @intCast(at_s), .nsec = 0 },
    };
    if (c.utimensat(posix.AT.FDCWD, path.ptr, &times, posix.AT.SYMLINK_NOFOLLOW) != 0) return error.TestUnexpectedResult;
}

fn exists(path: [:0]const u8) bool {
    var st: posix.Stat = undefined;
    return c.fstatat(posix.AT.FDCWD, path.ptr, &st, posix.AT.SYMLINK_NOFOLLOW) == 0;
}

fn hostDirExists(session_dir: [:0]const u8, id: u128) bool {
    var buf: [768]u8 = undefined;
    const dir = host_manifest.hostDirPathIn(&buf, session_dir, id) catch return false;
    return exists(dir);
}

fn fileInHostDirExists(session_dir: [:0]const u8, id: u128, leaf: []const u8) bool {
    var buf: [768]u8 = undefined;
    const dir = host_manifest.hostDirPathIn(&buf, session_dir, id) catch return false;
    var path_buf: [1024]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ dir, leaf }) catch return false;
    return exists(path);
}

/// 그 host 디렉터리에 이미지가 남아 있는가(둘 중 하나라도).
fn imagesRemain(session_dir: [:0]const u8, id: u128) bool {
    return fileInHostDirExists(session_dir, id, "rollback-current") or
        fileInHostDirExists(session_dir, id, "target-000000000000000000000000000000aa.image");
}

/// 신호 파일(manifest)과 어휘 밖 파일이 그대로인가.
fn signalIntact(session_dir: [:0]const u8, id: u128) bool {
    return hostDirExists(session_dir, id) and
        fileInHostDirExists(session_dir, id, "host.v1.json") and
        fileInHostDirExists(session_dir, id, "attempt-000000000000000000000000000000aa");
}

const day_s: i64 = 24 * 60 * 60;

test "죽은 host 의 이미지만 지우고 신호(manifest·lock)는 남긴다; 산 host·막 뜬 host·우리 것은 안 건드린다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init("dirs");
    defer fx.deinit();
    const now_s: i64 = 1_800_000_000;

    const dead: u128 = 0xD_EAD;
    const live: u128 = 0x11_7E;
    const young: u128 = 0x40_0146;
    const own: u128 = 0x0_0004;
    try fx.deadHost(dead, 3 * day_s, now_s);
    try fx.deadHost(young, 10 * 60, now_s); // 10 분 전 — 막 뜨는 host 의 창
    try fx.deadHost(own, 30 * day_s, now_s); // 우리 것 — 아무리 오래돼도 남긴다
    try fx.deadHost(live, 30 * day_s, now_s);
    // 산 host: lock 을 실제로 잡는다(같은 프로세스의 다른 fd 에서 flock 은 EWOULDBLOCK → `held`).
    var lock_buf: [832]u8 = undefined;
    const live_lock = try host_manifest.ownerLockPathIn(&lock_buf, fx.session_dir, live);
    var lease = try owner_lease.OwnerLease.acquire(live_lock);
    defer lease.deinit();
    // lock 생성이 디렉터리 mtime 을 «지금» 으로 만들었으니 다시 과거로 — 판정이 lock 을 보는지 mtime 을 보는지 가른다.
    var live_dir_buf: [768]u8 = undefined;
    try setMtime(try host_manifest.hostDirPathIn(&live_dir_buf, fx.session_dir, live), now_s - 30 * day_s);
    // 우리 모양이 아닌 이름은 세지도 지우지도 않는다.
    var stray_buf: [768]u8 = undefined;
    const stray = try std.fmt.bufPrintZ(&stray_buf, "{s}/hosts/not-a-host", .{fx.session_dir});
    _ = c.mkdir(stray.ptr, 0o700);
    try setMtime(stray, now_s - 30 * day_s);

    const report = sweep(testing.io, fx.session_dir, own, now_s);
    try testing.expectEqual(@as(u32, 1), report.dirs_swept);
    try testing.expectEqual(@as(u32, 2), report.images_removed);
    try testing.expectEqual(@as(u64, "MACHO".len + "MACHO-target".len), report.bytes_reclaimed);
    try testing.expectEqual(@as(u32, 1), report.dirs_live);
    try testing.expectEqual(@as(u32, 1), report.dirs_young);
    try testing.expectEqual(@as(u32, 0), report.dirs_unknown);
    // 죽은 것: 이미지는 사라지고 신호와 어휘 밖 파일은 그대로다.
    try testing.expect(!imagesRemain(fx.session_dir, dead));
    try testing.expect(signalIntact(fx.session_dir, dead));
    // 산 것·막 뜬 것·우리 것: 이미지까지 그대로다.
    try testing.expect(imagesRemain(fx.session_dir, live) and signalIntact(fx.session_dir, live));
    try testing.expect(imagesRemain(fx.session_dir, young) and signalIntact(fx.session_dir, young));
    try testing.expect(imagesRemain(fx.session_dir, own) and signalIntact(fx.session_dir, own));
    try testing.expect(exists(stray));
    // 두 번째 sweep 은 할 일이 없다 — 세는 것도 0 이다(로그줄이 매 시작마다 나지 않게).
    const again = sweep(testing.io, fx.session_dir, own, now_s);
    try testing.expectEqual(@as(u32, 0), again.dirs_swept);
    try testing.expectEqual(@as(u32, 0), again.images_removed);
    try testing.expect(!again.anyRemoved());
}

test "경계: 유예 딱 1 시간은 남고 1 초 더 오래되면 지워진다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init("grace");
    defer fx.deinit();
    const now_s: i64 = 1_800_000_000;
    try fx.deadHost(0xA7, dir_grace_s - 1, now_s);
    try fx.deadHost(0xB8, dir_grace_s, now_s);
    const report = sweep(testing.io, fx.session_dir, 0, now_s);
    try testing.expectEqual(@as(u32, 1), report.dirs_swept);
    try testing.expectEqual(@as(u32, 1), report.dirs_young);
    try testing.expect(imagesRemain(fx.session_dir, 0xA7));
    try testing.expect(!imagesRemain(fx.session_dir, 0xB8));
    try testing.expect(signalIntact(fx.session_dir, 0xB8));
}

test "로그: 죽은 host 의 7 일 지난 것만 지운다 — 최근 죽음·산 host·우리 것·다른 이름은 남긴다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init("logs");
    defer fx.deinit();
    const now_s: i64 = 1_800_000_000;

    const old_dead: u128 = 0x01; // 디렉터리 없음(정상 종료) + 8 일 → 지운다
    const fresh_dead: u128 = 0x02; // 디렉터리 없음 + 1 일 → 진단 창 안, 남긴다
    const old_live: u128 = 0x03; // 30 일 됐지만 lock 이 잡혀 있다 → 남긴다
    const own: u128 = 0x04; // 우리 것 → 남긴다
    try fx.log(old_dead, 8 * day_s, now_s);
    try fx.log(fresh_dead, 1 * day_s, now_s);
    try fx.log(old_live, 30 * day_s, now_s);
    try fx.log(own, 30 * day_s, now_s);
    try fx.deadHost(old_live, 30 * day_s, now_s);
    var lock_buf: [832]u8 = undefined;
    var lease = try owner_lease.OwnerLease.acquire(try host_manifest.ownerLockPathIn(&lock_buf, fx.session_dir, old_live));
    defer lease.deinit();
    // 이름이 다르면 오래돼도 남긴다.
    try writeIn(fx.session_dir, "host-notahost.log", "x");
    try writeIn(fx.session_dir, "launch-v2.lock", "");
    var other_buf: [1024]u8 = undefined;
    const other = try std.fmt.bufPrintZ(&other_buf, "{s}/host-notahost.log", .{fx.session_dir});
    try setMtime(other, now_s - 30 * day_s);

    const report = sweep(testing.io, fx.session_dir, own, now_s);
    try testing.expectEqual(@as(u32, 1), report.logs_removed);
    try testing.expectEqual(@as(u32, 2), report.logs_kept);
    var buf: [1024]u8 = undefined;
    try testing.expect(!exists(try logPathIn(&buf, fx.session_dir, old_dead)));
    try testing.expect(exists(try logPathIn(&buf, fx.session_dir, fresh_dead)));
    try testing.expect(exists(try logPathIn(&buf, fx.session_dir, old_live)));
    try testing.expect(exists(try logPathIn(&buf, fx.session_dir, own)));
    try testing.expect(exists(other));
}

test "경계: 로그 나이 딱 7 일은 남고 1 초 더 지나면 지워진다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init("logage");
    defer fx.deinit();
    const now_s: i64 = 1_800_000_000;
    try fx.log(0x0A, log_stale_after_s - 1, now_s);
    try fx.log(0x0B, log_stale_after_s, now_s);
    const report = sweep(testing.io, fx.session_dir, 0, now_s);
    try testing.expectEqual(@as(u32, 1), report.logs_removed);
    try testing.expectEqual(@as(u32, 1), report.logs_kept);
    var buf: [1024]u8 = undefined;
    try testing.expect(exists(try logPathIn(&buf, fx.session_dir, 0x0A)));
    try testing.expect(!exists(try logPathIn(&buf, fx.session_dir, 0x0B)));
}

test "preflight.log 는 문턱을 넘을 때만 .1 로 회전하고, 두 번째 회전은 첫 번째를 덮는다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init("preflight");
    defer fx.deinit();
    const now_s: i64 = 1_800_000_000;
    var small: [64]u8 = undefined;
    @memset(&small, 'a');
    try writeIn(fx.session_dir, preflight_log_leaf, &small);
    try testing.expect(!sweep(testing.io, fx.session_dir, 0, now_s).preflight_rotated);

    const big = try testing.allocator.alloc(u8, preflight_log_max_bytes + 1);
    defer testing.allocator.free(big);
    @memset(big, 'b');
    try writeIn(fx.session_dir, preflight_log_leaf, big);
    try testing.expect(sweep(testing.io, fx.session_dir, 0, now_s).preflight_rotated);
    var buf: [1024]u8 = undefined;
    try testing.expect(!exists(try std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ fx.session_dir, preflight_log_leaf })));
    var rotated_buf: [1024]u8 = undefined;
    const rotated = try std.fmt.bufPrintZ(&rotated_buf, "{s}/{s}", .{ fx.session_dir, preflight_log_rotated_leaf });
    try testing.expect(exists(rotated));

    // 정확히 문턱은 안 넘는다.
    try writeIn(fx.session_dir, preflight_log_leaf, big[0..preflight_log_max_bytes]);
    try testing.expect(!sweep(testing.io, fx.session_dir, 0, now_s).preflight_rotated);
    // 문턱을 넘는 두 번째 회전은 .1 을 덮는다(상한 = 최대 2 배).
    @memset(big, 'c');
    try writeIn(fx.session_dir, preflight_log_leaf, big);
    try testing.expect(sweep(testing.io, fx.session_dir, 0, now_s).preflight_rotated);
    const rotated_bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, rotated, testing.allocator, .limited(preflight_log_max_bytes + 16));
    defer testing.allocator.free(rotated_bytes);
    try testing.expectEqual(preflight_log_max_bytes + 1, rotated_bytes.len);
    try testing.expectEqual(@as(u8, 'c'), rotated_bytes[0]);
}

test "무거운 잔재 어휘: rollback 둘과 target 이미지(묘비 포함)만이고, manifest·lock·attempt 기록은 아니다" {
    try testing.expect(isHeavyResidueName("rollback-current"));
    try testing.expect(isHeavyResidueName("rollback-previous"));
    try testing.expect(isHeavyResidueName("target-000000000000000000000000000000aa.image"));
    try testing.expect(isHeavyResidueName(".sweep-target-000000000000000000000000000000aa.image"));
    try testing.expect(!isHeavyResidueName("host.v1.json"));
    try testing.expect(!isHeavyResidueName("owner.lock"));
    try testing.expect(!isHeavyResidueName("attempt-000000000000000000000000000000aa"));
    try testing.expect(!isHeavyResidueName("target-00000000000000000000000000000aa.image")); // 31 hex
    try testing.expect(!isHeavyResidueName("target-000000000000000000000000000000aa.image.bak"));
    try testing.expect(!isHeavyResidueName("rollback-current.bak"));
}

test "이름 규칙: 32 hex 만 host 이고 로그는 host-<32 hex>.log 만이다" {
    try testing.expectEqual(@as(?u128, 0xAB), hostIdFromHex("000000000000000000000000000000ab"));
    try testing.expect(hostIdFromHex("00000000000000000000000000000ab") == null); // 31
    try testing.expect(hostIdFromHex("000000000000000000000000000000abc") == null); // 33
    try testing.expect(hostIdFromHex("0000000000000000000000000000zzzz") == null);
    try testing.expectEqual(@as(?u128, 0xAB), hostIdFromLogName("host-000000000000000000000000000000ab.log"));
    try testing.expect(hostIdFromLogName("host-000000000000000000000000000000ab.log.1") == null);
    try testing.expect(hostIdFromLogName("hosts") == null);
    try testing.expect(hostIdFromLogName("preflight.log") == null);
}
