//! W7a2 — `maru-chromium` 설치를 띄우기 전에 검증하고, **실행 사본**에서 띄운다(docs/plans/web-osr-backend.md 결정 표
//! 「sidecar 실행 전 검증」·「실행 사본」).
//!
//! - **어디를 믿나**: formula 설치는 ad-hoc 서명이라 서명이 만든 이를 증명하지 못한다. 그래서 막는 것은 **경로와 소유권**이다
//!   — 실제 경로가 `<prefix>/Cellar/maru-chromium/<버전>/libexec` 이고, keg(`<버전>`) 안의 모든 항목이 이 사용자나 root 소유에
//!   그룹·남이 쓸 수 없으며 일반 파일·디렉터리뿐이다(링크·FIFO 없음). 그 위 `Cellar`·rack 은 Homebrew 모델대로 admin 그룹이
//!   쓸 수 있다(실측) — 그래서 검사와 복제를 **같은 fd** 로 한다: prefix 부터 한 단계씩 열어 쥔 keg 를 검사하고 그 fd 에서
//!   복제한다(검사 뒤 admin 그룹의 다른 계정이 rack 을 바꿔치기해도 복제는 검사한 것에서 — W7a2 적대 검증 1 차).
//!   서명은 host·helper 만 `codesign --verify --strict` 로 본다(깨짐을 거른다) — CEF 프레임워크는 배포본 그대로도 strict 검증에
//!   실패한다(실측 — 사용자 결정 2026-09-29: 프레임워크는 경로·소유권으로만).
//! - **릴리스 판**: hardened runtime 으로 도는 maru(서명된 dmg)는 `MARU_WEB_OSR_DIR`·`HOMEBREW_PREFIX`·`HOME` 을 무시한다 —
//!   환경변수로 고른 실행 파일을 띄우면 hardened runtime 의 `DYLD_*` 차단을 우회한다(W7 착수 전 공격). 판정은 빌드 플래그가
//!   아니라 실행 중인 이 프로세스의 서명 상태(`csops` 의 `CS_RUNTIME`)로 한다 — 빠뜨릴 수 없게. 같은 사용자 권한의 공격자에게는
//!   경계가 아니라 심층 방어다(keg 와 사본은 그 사용자가 쓸 수 있다).
//! - **실행 사본**: 검증한 설치를 `~/Library/Caches/maru/web-osr-run/run-<pid>-<무작위>` 로 APFS 복제(`fclonefileat` — 330MB 에
//!   14ms·추가 용량 0, 실측)해 거기서 띄운다. 도는 동안 `brew upgrade` 가 옛 keg 를 지워도 새 렌더러가 뜬다(W7 착수 전 실측:
//!   설치가 지워지면 새 사이트·새 탭이 영영 로딩). 사본마다 옆의 `.lock` 을 공유 잠금으로 **그 sidecar 가 끝날 때까지** 쥐고
//!   (`RunCopy` — 거둘 때 지운다), 띄울 때와 엔진을 정할 때 잠기지 않은 옛 사본을 지운다(다른 maru 인스턴스가 쓰는 사본은
//!   잠겨 있어 남는다). 릴리스 판은 복제가 안 되면 띄우지 않는다(설치에서 바로 띄우면 CEF 가 helper 를 경로로 다시 띄워 검사가
//!   무력해진다). 개발 디렉터리는 복제가 안 되면 그 자리에서 띄운다.

const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const ws = maru.session.web_sidecar;

extern "c" fn csops(pid: std.c.pid_t, ops: c_uint, useraddr: ?*anyopaque, usersize: usize) c_int;
extern "c" fn fclonefileat(src_fd: c_int, dst_dir_fd: c_int, dst: [*:0]const u8, flags: u32) c_int;
extern "c" fn posix_spawn(
    pid: *std.c.pid_t,
    path: [*:0]const u8,
    file_actions: *const ?*anyopaque,
    attrp: *const ?*anyopaque,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
) c_int;
extern "c" fn posix_spawnattr_init(attr: *?*anyopaque) c_int;
extern "c" fn posix_spawnattr_setflags(attr: *?*anyopaque, flags: c_short) c_int;
extern "c" fn posix_spawnattr_destroy(attr: *?*anyopaque) c_int;
extern "c" fn posix_spawn_file_actions_init(actions: *?*anyopaque) c_int;
extern "c" fn posix_spawn_file_actions_addopen(actions: *?*anyopaque, fd: c_int, path: [*:0]const u8, oflag: c_int, mode: std.c.mode_t) c_int;
extern "c" fn posix_spawn_file_actions_destroy(actions: *?*anyopaque) c_int;
extern "c" fn arc4random_buf(buf: [*]u8, len: usize) void;
extern "c" fn nanosleep(rqtp: *const std.c.timespec, rmtp: ?*std.c.timespec) c_int;

const cs_ops_status: c_uint = 0;
const cs_runtime: u32 = 0x0001_0000;
const clone_nofollow: u32 = 0x0001;
const posix_spawn_cloexec_default: c_short = 0x4000;
const lock_ex: c_int = 2;
const lock_nb: c_int = 4;
const s_ifmt: u32 = 0o170000;
const s_ifdir: u32 = 0o040000;
const s_ifreg: u32 = 0o100000;
const s_iflnk: u32 = 0o120000;
/// codesign 한 번의 기한(보통 약 10ms — 실측). 넘으면 죽이고 「확인 못 함」.
const codesign_timeout_ms: u32 = 10_000;

/// 이 프로세스가 hardened runtime 으로 도는가(서명된 dmg 판). 알 수 없으면 도는 것으로 본다(닫혀 실패 — 환경변수를 안 믿는다).
pub fn hardenedRuntime() bool {
    var flags: u32 = 0;
    if (csops(std.c.getpid(), cs_ops_status, &flags, @sizeOf(u32)) != 0) return true;
    return flags & cs_runtime != 0;
}

pub const Problem = enum {
    not_in_keg,
    not_owned,
    writable_by_others,
    symlink,
    not_regular,
    too_large,
    bad_signature,
    no_manifest,
    bad_manifest,
    version_mismatch,
    unreadable,
    clone_failed,
};

/// `real` 이 `<prefix_real>/Cellar/maru-chromium/<버전>/libexec` 이면 그 `<버전>`(순수 — 시험한다).
pub fn kegVersion(real: []const u8, prefix_real: []const u8) ?[]const u8 {
    const head = "/Cellar/maru-chromium/";
    if (!std.mem.startsWith(u8, real, prefix_real)) return null;
    const rest = real[prefix_real.len..];
    if (!std.mem.startsWith(u8, rest, head)) return null;
    const tail = rest[head.len..];
    const slash = std.mem.indexOfScalar(u8, tail, '/') orelse return null;
    const version = tail[0..slash];
    if (version.len == 0 or std.mem.eql(u8, version, ".") or std.mem.eql(u8, version, "..")) return null;
    if (!std.mem.eql(u8, tail[slash..], "/libexec")) return null;
    return version;
}

/// 한 항목의 소유·권한·종류(순수 — 시험한다). 이 사용자나 root 소유, 그룹·남이 쓸 수 없음, 일반 파일이나 디렉터리.
pub fn entryProblem(mode: u32, uid: u32, my_uid: u32) ?Problem {
    if (mode & s_ifmt == s_iflnk) return .symlink;
    if (uid != my_uid and uid != 0) return .not_owned;
    if (mode & 0o022 != 0) return .writable_by_others;
    if (mode & s_ifmt != s_ifreg and mode & s_ifmt != s_ifdir) return .not_regular;
    return null;
}

fn myUid() u32 {
    return @intCast(std.c.getuid());
}

fn statNoFollow(path: [*:0]const u8) ?std.c.Stat {
    var st: std.c.Stat = undefined;
    if (std.c.fstatat(std.c.AT.FDCWD, path, &st, std.c.AT.SYMLINK_NOFOLLOW) != 0) return null;
    return st;
}

fn fdStat(fd: c_int) ?std.c.Stat {
    var st: std.c.Stat = undefined;
    if (std.c.fstat(fd, &st) != 0) return null;
    return st;
}

/// `parent` 아래 `name` 디렉터리를 링크를 따라가지 않고 연다.
fn openDirAt(parent: c_int, name: [*:0]const u8) c_int {
    return std.c.openat(parent, name, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true });
}

fn closeFd(fd: c_int) void {
    _ = std.c.close(fd);
}

/// 연 디렉터리의 항목을 차례로 준다(`.`·`..` 는 건너뛴다). 그 디렉터리를 새로 열어 읽으므로(`dup` 은 읽은 자리를 나눠
/// 두 번째 순회가 빈 목록이 된다 — W7a2 적대 검증 2 차) 호출자의 fd 와 무관하다. 읽다 오류가 나면 `failed` 가 선다 —
/// 검사하는 쪽은 빈 목록을 통과로 보지 않는다.
const Entries = struct {
    dir: *std.c.DIR,
    failed: bool = false,

    fn open(fd: c_int) ?Entries {
        const own = openDirAt(fd, ".");
        if (own < 0) return null;
        const dir = std.c.fdopendir(own) orelse {
            closeFd(own);
            return null;
        };
        return .{ .dir = dir };
    }

    fn next(self: *Entries) ?[*:0]const u8 {
        while (true) {
            std.c._errno().* = 0;
            const entry = std.c.readdir(self.dir) orelse {
                if (std.c._errno().* != 0) self.failed = true;
                return null;
            };
            const name: [*:0]const u8 = @ptrCast(&entry.name);
            const s = std.mem.span(name);
            if (std.mem.eql(u8, s, ".") or std.mem.eql(u8, s, "..")) continue;
            return name;
        }
    }

    fn close(self: *Entries) void {
        _ = std.c.closedir(self.dir);
    }
};

/// 연 디렉터리 아래 전체의 소유·권한·종류. 항목 수·깊이에 상한을 둔다(설치물은 459 개·깊이 6 — 실측). 하위 디렉터리는
/// 방금 본 그것인지(장치·inode) 확인하고 들어간다.
fn treeProblemAt(dir_fd: c_int, my_uid: u32, depth: u32, budget: *u32) ?Problem {
    if (depth > 16) return .too_large;
    var entries = Entries.open(dir_fd) orelse return .unreadable;
    defer entries.close();
    while (entries.next()) |name| {
        if (budget.* == 0) return .too_large;
        budget.* -= 1;
        var st: std.c.Stat = undefined;
        if (std.c.fstatat(dir_fd, name, &st, std.c.AT.SYMLINK_NOFOLLOW) != 0) return .unreadable;
        if (entryProblem(st.mode, st.uid, my_uid)) |p| return p;
        if (st.mode & s_ifmt != s_ifdir) continue;
        const child = openDirAt(dir_fd, name);
        if (child < 0) return .unreadable;
        defer closeFd(child);
        const opened = fdStat(child) orelse return .unreadable;
        if (opened.dev != st.dev or opened.ino != st.ino) return .unreadable;
        if (treeProblemAt(child, my_uid, depth + 1, budget)) |p| return p;
    }
    return if (entries.failed) .unreadable else null;
}

pub const Opened = union(enum) { ok: c_int, bad: Problem };

/// brew 설치(`findInstall` 이 찾은 `<prefix>/opt/maru-chromium/libexec`)를 검사하고 **검사한 libexec 의 fd** 를 준다(호출자가
/// 닫는다). 실제 경로가 그 prefix 의 keg 여야 하고, prefix 에서 keg 까지 한 단계씩 링크 없이 다시 열어 그 keg·libexec 와 그
/// 안 전체를 본다.
pub fn openBrewSource(dir: []const u8, prefix: []const u8) Opened {
    var dir_z_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_z = std.fmt.bufPrintZ(&dir_z_buf, "{s}", .{dir}) catch return .{ .bad = .too_large };
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real = std.mem.span(std.c.realpath(dir_z, &real_buf) orelse return .{ .bad = .unreadable });
    var prefix_z_buf: [std.fs.max_path_bytes]u8 = undefined;
    const prefix_z = std.fmt.bufPrintZ(&prefix_z_buf, "{s}", .{prefix}) catch return .{ .bad = .too_large };
    var prefix_real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const prefix_real = std.c.realpath(prefix_z, &prefix_real_buf) orelse return .{ .bad = .unreadable };
    const version = kegVersion(real, std.mem.span(prefix_real)) orelse return .{ .bad = .not_in_keg };
    var version_buf: [256]u8 = undefined;
    const version_z = std.fmt.bufPrintZ(&version_buf, "{s}", .{version}) catch return .{ .bad = .too_large };

    const prefix_fd = std.c.open(prefix_real, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true });
    if (prefix_fd < 0) return .{ .bad = .unreadable };
    defer closeFd(prefix_fd);
    const cellar = openDirAt(prefix_fd, "Cellar");
    if (cellar < 0) return .{ .bad = .not_in_keg };
    defer closeFd(cellar);
    const rack = openDirAt(cellar, "maru-chromium");
    if (rack < 0) return .{ .bad = .not_in_keg };
    defer closeFd(rack);
    const keg = openDirAt(rack, version_z);
    if (keg < 0) return .{ .bad = .not_in_keg };
    defer closeFd(keg);
    const my_uid = myUid();
    // keg(`<버전>`)부터 — libexec 의 부모도 이 사용자·root 소유에 남이 쓸 수 없어야 한다(그 안에서 libexec 를 바꿔치지 못하게).
    const keg_st = fdStat(keg) orelse return .{ .bad = .unreadable };
    if (entryProblem(keg_st.mode, keg_st.uid, my_uid)) |p| return .{ .bad = p };
    const libexec = openDirAt(keg, "libexec");
    if (libexec < 0) return .{ .bad = .not_in_keg };
    const libexec_st = fdStat(libexec) orelse {
        closeFd(libexec);
        return .{ .bad = .unreadable };
    };
    if (entryProblem(libexec_st.mode, libexec_st.uid, my_uid)) |p| {
        closeFd(libexec);
        return .{ .bad = p };
    }
    var budget: u32 = 5000;
    if (treeProblemAt(libexec, my_uid, 0, &budget)) |p| {
        closeFd(libexec);
        return .{ .bad = p };
    }
    return .{ .ok = libexec };
}

/// 개발 디렉터리(`MARU_WEB_OSR_DIR`)를 연다 — 검사하지 않는다(빌드 디렉터리다).
pub fn openDevSource(dir: []const u8) ?c_int {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{dir}) catch return null;
    const fd = std.c.open(z, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
    return if (fd < 0) null else fd;
}

/// 띄울 디렉터리(실행 사본이나 개발 디렉터리)의 내용 — host·helper 가 일반 파일이고 서명이 온전한가, manifest 의 제어 채널
/// 버전이 이 maru 와 같은가(`require_manifest` 가 아니면 — 개발용 `MARU_WEB_OSR_DIR` — manifest 가 없어도 된다).
pub fn verifyRunDir(dir: []const u8, require_manifest: bool) ?Problem {
    for ([_][]const u8{ "maru-web-host", "maru-web-helper" }) |name| {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ dir, name }) catch return .too_large;
        const st = statNoFollow(path) orelse return .unreadable;
        if (st.mode & s_ifmt != s_ifreg) return .not_regular;
        switch (signature(path)) {
            .valid => {},
            .invalid => return .bad_signature,
            .unknown => return .unreadable,
        }
    }
    return manifestProblem(dir, require_manifest);
}

fn manifestProblem(dir: []const u8, require_manifest: bool) ?Problem {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/maru-chromium.json", .{dir}) catch return .too_large;
    // FIFO 면 열기에서 멈추지 않게 NONBLOCK 으로 열고 일반 파일인지 본다(W7a2 적대 검증 1 차).
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true });
    if (fd < 0) return if (require_manifest) .no_manifest else null;
    defer closeFd(fd);
    const st = fdStat(fd) orelse return .bad_manifest;
    if (st.mode & s_ifmt != s_ifreg) return .bad_manifest;
    var bytes: [4096]u8 = undefined;
    const n = std.c.read(fd, &bytes, bytes.len);
    if (n <= 0 or n == bytes.len) return .bad_manifest;
    return switch (manifestWireVersion(bytes[0..@intCast(n)])) {
        .ok => |v| if (v == ws.wire.version) null else .version_mismatch,
        .bad => .bad_manifest,
    };
}

/// manifest 의 `wire_version`(순수 — 시험한다).
pub fn manifestWireVersion(json: []const u8) union(enum) { ok: u16, bad } {
    var arena_buf: [16 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&arena_buf);
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, fba.allocator(), json, .{}) catch return .bad;
    if (parsed != .object) return .bad;
    const v = parsed.object.get("wire_version") orelse return .bad;
    if (v != .integer or v.integer < 0 or v.integer > std.math.maxInt(u16)) return .bad;
    return .{ .ok = @intCast(v.integer) };
}

const Signature = enum { valid, invalid, unknown };

/// `codesign --verify --strict <path>` — 서명이 내용과 맞는가(ad-hoc 이라 만든 이는 증명하지 않는다 — 깨짐·바꿔치기 뒤 재서명
/// 안 한 것을 거른다). maru 의 fd 를 물려주지 않고(stdio 는 /dev/null) 기한을 둔다. 띄우지 못하거나 기한을 넘기면 「모름」.
fn signature(path: [*:0]const u8) Signature {
    const argv = [_:null]?[*:0]const u8{ "/usr/bin/codesign", "--verify", "--strict", path };
    const envp = [_:null]?[*:0]const u8{};
    var attr: ?*anyopaque = null;
    if (posix_spawnattr_init(&attr) != 0) return .unknown;
    defer _ = posix_spawnattr_destroy(&attr);
    if (posix_spawnattr_setflags(&attr, posix_spawn_cloexec_default) != 0) return .unknown;
    var actions: ?*anyopaque = null;
    if (posix_spawn_file_actions_init(&actions) != 0) return .unknown;
    defer _ = posix_spawn_file_actions_destroy(&actions);
    for ([_]c_int{ 0, 1, 2 }) |fd| {
        const flags: c_int = if (fd == 0) 0 else 1; // O_RDONLY · O_WRONLY
        if (posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", flags, 0) != 0) return .unknown;
    }
    var pid: std.c.pid_t = 0;
    if (posix_spawn(&pid, "/usr/bin/codesign", &actions, &attr, &argv, &envp) != 0) return .unknown;
    var status: c_int = 0;
    var waited: u32 = 0;
    while (true) {
        const r = std.c.waitpid(pid, &status, std.c.W.NOHANG);
        if (r == pid) break;
        if (r == -1 and std.c._errno().* != @intFromEnum(std.c.E.INTR)) return .unknown;
        if (waited >= codesign_timeout_ms) {
            _ = std.c.kill(pid, .KILL);
            while (std.c.waitpid(pid, &status, 0) == -1 and std.c._errno().* == @intFromEnum(std.c.E.INTR)) {}
            return .unknown;
        }
        sleepMs(5);
        waited += 5;
    }
    const s: u32 = @bitCast(status);
    return if (s & 0x7f == 0 and (s >> 8) & 0xff == 0) .valid else .invalid;
}

fn sleepMs(ms: u32) void {
    const ts: std.c.timespec = .{ .sec = 0, .nsec = @intCast(@as(u64, ms) * std.time.ns_per_ms) };
    _ = nanosleep(&ts, null);
}

// ── 실행 사본 ──────────────────────────────────────────────────────────────────────────────────────────────────────

/// sidecar 가 쓰는 홈(실행 사본·프로필의 뿌리). 릴리스 판은 `HOME` 대신 계정 정보의 홈이다(환경변수로 자리를 고르지 못하게 —
/// W7a2). 개발 판은 `HOME` — 시험이 임시 홈으로 가른다. 절대 경로가 아니면 null.
pub fn homeDir(buf: []u8, hardened: bool) ?[]const u8 {
    var pw_buf: [4096]u8 = undefined;
    var pw: std.c.passwd = undefined;
    var found: ?*std.c.passwd = null;
    const home: [*:0]const u8 = if (hardened) blk: {
        if (std.c.getpwuid_r(std.c.getuid(), &pw, &pw_buf, pw_buf.len, &found) != 0) return null;
        const entry = found orelse return null;
        break :blk entry.dir orelse return null;
    } else std.c.getenv("HOME") orelse return null;
    const s = std.mem.span(home);
    if (s.len == 0 or s[0] != '/' or s.len > buf.len) return null;
    @memcpy(buf[0..s.len], s);
    return buf[0..s.len];
}

/// 실행 사본을 두는 자리(`~/Library/Caches` — 백업에서 빠지고 지워도 되는 곳).
pub fn runCacheRoot(buf: []u8, hardened: bool) ?[]const u8 {
    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = homeDir(&home_buf, hardened) orelse return null;
    return std.fmt.bufPrint(buf, "{s}/Library/Caches/maru/web-osr-run", .{home}) catch null;
}

/// 지금 쓰는 실행 사본 — 그 sidecar 가 끝날 때까지 쥐고(공유 잠금), 거둔 뒤 `release` 로 지운다.
pub const RunCopy = struct {
    lock_fd: c_int,
    path_buf: [std.fs.max_path_bytes]u8 = undefined,
    path_len: usize = 0,
    /// 경로에서 이름(`run-…`)이 시작하는 곳.
    name_at: usize = 0,

    pub fn dir(self: *const RunCopy) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    /// 사본과 잠금 파일을 지우고 잠금을 놓는다.
    pub fn release(self: *RunCopy) void {
        var root_buf: [std.fs.max_path_bytes]u8 = undefined;
        var name_buf: [std.fs.max_path_bytes]u8 = undefined;
        const root = std.fmt.bufPrintZ(&root_buf, "{s}", .{self.path_buf[0 .. self.name_at - 1]}) catch return self.unlock();
        const name = std.fmt.bufPrintZ(&name_buf, "{s}", .{self.path_buf[self.name_at..self.path_len]}) catch return self.unlock();
        const root_fd = std.c.open(root, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true });
        if (root_fd >= 0) {
            defer closeFd(root_fd);
            removeTreeAt(root_fd, name, 0);
            var lock_buf: [std.fs.max_path_bytes]u8 = undefined;
            if (std.fmt.bufPrintZ(&lock_buf, "{s}.lock", .{name})) |lock| _ = std.c.unlinkat(root_fd, lock, 0) else |_| {}
        }
        self.unlock();
    }

    fn unlock(self: *RunCopy) void {
        if (self.lock_fd >= 0) closeFd(self.lock_fd);
        self.lock_fd = -1;
    }
};

pub const Cloned = union(enum) { ok: RunCopy, bad: Problem };

/// 연 설치(`source`)를 `<cache_root>/run-<pid>-<무작위>` 로 복제하고 그 잠금을 쥔다. 먼저 잠기지 않은 옛 사본을 지운다.
/// 캐시 뿌리는 이 사용자 소유에 남이 못 들어오는(0700) 디렉터리여야 한다.
pub fn cloneForRun(source: c_int, cache_root: []const u8) Cloned {
    const root_fd = openCacheRoot(cache_root) catch |e| return .{ .bad = switch (e) {
        error.unreadable => .unreadable,
        error.not_owned => .not_owned,
        error.writable_by_others => .writable_by_others,
        error.too_large => .too_large,
    } };
    defer closeFd(root_fd);
    sweepAt(root_fd);
    var attempt: u32 = 0;
    while (attempt < 3) : (attempt += 1) {
        var copy: RunCopy = .{ .lock_fd = -1 };
        var rand: [8]u8 = undefined;
        arc4random_buf(&rand, rand.len);
        const name_hex = std.fmt.bytesToHex(rand, .lower);
        const path = std.fmt.bufPrint(&copy.path_buf, "{s}/run-{d}-{s}", .{ cache_root, std.c.getpid(), &name_hex }) catch return .{ .bad = .too_large };
        copy.path_len = path.len;
        copy.name_at = cache_root.len + 1;
        var name_buf: [64]u8 = undefined;
        const name = std.fmt.bufPrintZ(&name_buf, "{s}", .{path[copy.name_at..]}) catch return .{ .bad = .too_large };
        var lock_buf: [80]u8 = undefined;
        const lock = std.fmt.bufPrintZ(&lock_buf, "{s}.lock", .{name}) catch return .{ .bad = .too_large };
        // 잠금을 **먼저** 만들고 쥔다 — 다른 maru 의 청소가 복제 중인 사본을 지우지 않게.
        copy.lock_fd = std.c.openat(root_fd, lock, .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true, .NOFOLLOW = true, .CLOEXEC = true, .SHLOCK = true }, @as(std.c.mode_t, 0o600));
        if (copy.lock_fd < 0) return .{ .bad = .clone_failed };
        if (builtin.is_test) if (test_after_lock_create) |hook| hook(root_fd, lock);
        // `O_SHLOCK` 은 만들기와 원자적이지 않다(실측 — 만든 직후를 노린 배타 잠금이 11~16 % 잡혔다): 그 틈에 다른 maru 의
        // 청소가 이 잠금 파일을 「사본 없는 잠금」으로 지웠으면 이름이 가리키는 것이 이 fd 가 아니다 — 새 이름으로 다시.
        if (!lockStillNamed(root_fd, lock, copy.lock_fd)) {
            copy.unlock();
            continue;
        }
        if (fclonefileat(source, root_fd, name, clone_nofollow) != 0) {
            std.log.scoped(.web_osr).warn("run copy: fclonefileat failed (errno {d})", .{std.c._errno().*});
            _ = std.c.unlinkat(root_fd, lock, 0);
            copy.unlock();
            return .{ .bad = .clone_failed };
        }
        return .{ .ok = copy };
    }
    return .{ .bad = .clone_failed };
}

/// 시험용 — 잠금을 만든 직후 끼어든다(다른 maru 의 청소가 그 틈에 지우는 경우를 만든다).
var test_after_lock_create: ?*const fn (root_fd: c_int, lock: [*:0]const u8) void = null;

/// 잠금 fd 가 아직 그 이름에 걸린 파일인가(지워지지도, 다른 파일로 바뀌지도 않았다).
fn lockStillNamed(root_fd: c_int, lock: [*:0]const u8, fd: c_int) bool {
    const held = fdStat(fd) orelse return false;
    if (held.nlink == 0) return false;
    var named: std.c.Stat = undefined;
    if (std.c.fstatat(root_fd, lock, &named, std.c.AT.SYMLINK_NOFOLLOW) != 0) return false;
    return named.dev == held.dev and named.ino == held.ino;
}

/// 캐시 뿌리를 만들고 연다 — 이 사용자 소유의 0700 디렉터리여야 한다(링크 아님).
fn openCacheRoot(cache_root: []const u8) error{ unreadable, not_owned, writable_by_others, too_large }!c_int {
    if (!mkdirs(cache_root)) return error.unreadable;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{cache_root}) catch return error.too_large;
    const fd = std.c.open(z, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true });
    if (fd < 0) return error.unreadable;
    errdefer closeFd(fd);
    const st = fdStat(fd) orelse return error.unreadable;
    if (st.uid != myUid()) return error.not_owned;
    if (st.mode & 0o077 != 0) return error.writable_by_others;
    return fd;
}

/// 엔진을 정할 때 — 사본을 만들지 않아도(WebKit 으로 돌아갔어도) 잠기지 않은 옛 사본을 지운다. 캐시 뿌리가 없으면 무동작.
pub fn sweepRunCopies(cache_root: []const u8) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{cache_root}) catch return;
    const st = statNoFollow(z) orelse return;
    if (st.mode & s_ifmt != s_ifdir) return;
    const fd = openCacheRoot(cache_root) catch return;
    defer closeFd(fd);
    sweepAt(fd);
}

/// 잠기지 않은 사본과 그 잠금 파일을 지운다. 잠금 파일이 없는 `run-*` 디렉터리(잠금보다 먼저 죽은 것)와 사본 없이 남은
/// 잠금 파일(복제 전에 죽은 것)도 지운다.
fn sweepAt(root_fd: c_int) void {
    var entries = Entries.open(root_fd) orelse return;
    defer entries.close();
    while (entries.next()) |name_z| {
        const name = std.mem.span(name_z);
        if (!std.mem.startsWith(u8, name, "run-")) continue;
        if (std.mem.endsWith(u8, name, ".lock")) {
            var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
            const dir_name = std.fmt.bufPrintZ(&dir_buf, "{s}", .{name[0 .. name.len - ".lock".len]}) catch continue;
            var st: std.c.Stat = undefined;
            if (std.c.fstatat(root_fd, dir_name, &st, std.c.AT.SYMLINK_NOFOLLOW) == 0) continue; // 사본 쪽에서 다룬다
            const fd = std.c.openat(root_fd, name_z, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .CLOEXEC = true });
            if (fd < 0) continue;
            defer closeFd(fd);
            if (std.c.flock(fd, lock_ex | lock_nb) == 0) _ = std.c.unlinkat(root_fd, name_z, 0);
            continue;
        }
        var lock_buf: [std.fs.max_path_bytes]u8 = undefined;
        const lock = std.fmt.bufPrintZ(&lock_buf, "{s}.lock", .{name}) catch continue;
        const fd = std.c.openat(root_fd, lock, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .CLOEXEC = true });
        if (fd >= 0) {
            defer closeFd(fd);
            // 누가 쓰고 있으면(공유 잠금) 배타 잠금이 안 잡힌다 — 남긴다.
            if (std.c.flock(fd, lock_ex | lock_nb) != 0) continue;
            removeTreeAt(root_fd, name_z, 0);
            _ = std.c.unlinkat(root_fd, lock, 0);
        } else if (std.c._errno().* == @intFromEnum(std.c.E.NOENT)) {
            removeTreeAt(root_fd, name_z, 0); // 잠금이 정말 없을 때만(fd 가 바닥나 못 연 것이면 남의 사본일 수 있다)
        }
    }
}

/// `parent` 아래 `name` 을 통째로 지운다 — 링크는 따라가지 않는다(fd 기준이라 도중에 링크로 바꿔도 밖을 지우지 않는다).
fn removeTreeAt(parent: c_int, name: [*:0]const u8, depth: u32) void {
    if (depth > 32) return;
    const fd = openDirAt(parent, name);
    if (fd < 0) {
        _ = std.c.unlinkat(parent, name, 0); // 파일·링크
        return;
    }
    {
        defer closeFd(fd);
        // 주인이 쓸 수 없는 디렉터리(0555)는 비우지 못한다 — 먼저 열어 준다(복제는 모드를 그대로 가져온다).
        if (fdStat(fd)) |st| if (st.mode & 0o700 != 0o700) {
            _ = std.c.fchmod(fd, @intCast((st.mode & 0o7777) | 0o700));
        };
        var entries = Entries.open(fd) orelse return;
        defer entries.close();
        while (entries.next()) |child| removeTreeAt(fd, child, depth + 1);
    }
    _ = std.c.unlinkat(parent, name, std.c.AT.REMOVEDIR);
}

/// 경로로 지운다(시험·청소용 — 부모를 열고 fd 기준으로).
fn removeTreePath(path: []const u8) void {
    const parent = std.fs.path.dirname(path) orelse return;
    var parent_buf: [std.fs.max_path_bytes]u8 = undefined;
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    const parent_z = std.fmt.bufPrintZ(&parent_buf, "{s}", .{parent}) catch return;
    const name_z = std.fmt.bufPrintZ(&name_buf, "{s}", .{std.fs.path.basename(path)}) catch return;
    const fd = std.c.open(parent_z, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
    if (fd < 0) return;
    defer closeFd(fd);
    removeTreeAt(fd, name_z, 0);
}

fn mkdirs(path: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= buf.len) return false;
    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i != path.len and path[i] != '/') continue;
        @memcpy(buf[0..i], path[0..i]);
        buf[i] = 0;
        const z: [*:0]const u8 = @ptrCast(&buf);
        if (std.c.mkdir(z, 0o700) != 0 and std.c._errno().* != @intFromEnum(std.c.E.EXIST)) return false;
    }
    return true;
}

// ── 시험 ─────────────────────────────────────────────────────────────────────────────────────────────────────────

test "only <prefix>/Cellar/maru-chromium/<version>/libexec is an install" {
    try std.testing.expectEqualStrings("1.2", kegVersion("/opt/homebrew/Cellar/maru-chromium/1.2/libexec", "/opt/homebrew").?);
    try std.testing.expect(kegVersion("/opt/homebrew/Cellar/maru-chromium/1.2/libexec/x", "/opt/homebrew") == null);
    try std.testing.expect(kegVersion("/opt/homebrew/Cellar/maru-chromium/libexec", "/opt/homebrew") == null);
    try std.testing.expect(kegVersion("/opt/homebrew/Cellar/maru-chromium/../libexec", "/opt/homebrew") == null);
    try std.testing.expect(kegVersion("/opt/homebrew/Cellar/other/1.2/libexec", "/opt/homebrew") == null);
    try std.testing.expect(kegVersion("/tmp/x/Cellar/maru-chromium/1.2/libexec", "/opt/homebrew") == null); // 다른 prefix
    try std.testing.expect(kegVersion("/opt/homebrew2/Cellar/maru-chromium/1.2/libexec", "/opt/homebrew") == null);
    try std.testing.expect(kegVersion("/Users/me/dev/maru/zig-out/maru-chromium", "/opt/homebrew") == null);
}

test "entries must be ours or root's, not group/other writable, plain files or directories, never links" {
    try std.testing.expectEqual(@as(?Problem, null), entryProblem(0o100755, 501, 501));
    try std.testing.expectEqual(@as(?Problem, null), entryProblem(0o040755, 0, 501)); // root 소유
    try std.testing.expectEqual(@as(?Problem, .not_owned), entryProblem(0o100755, 502, 501));
    try std.testing.expectEqual(@as(?Problem, .writable_by_others), entryProblem(0o100775, 501, 501));
    try std.testing.expectEqual(@as(?Problem, .writable_by_others), entryProblem(0o040757, 501, 501));
    try std.testing.expectEqual(@as(?Problem, .symlink), entryProblem(0o120755, 501, 501));
    try std.testing.expectEqual(@as(?Problem, .not_regular), entryProblem(0o010644, 501, 501)); // FIFO
    try std.testing.expectEqual(@as(?Problem, .not_regular), entryProblem(0o140755, 501, 501)); // 소켓
}

test "the manifest's control-channel version is read strictly" {
    try std.testing.expectEqual(@as(u16, 2), manifestWireVersion("{\"format\":1,\"wire_version\":2}").ok);
    try std.testing.expect(manifestWireVersion("{\"wire_version\":\"2\"}") == .bad);
    try std.testing.expect(manifestWireVersion("{\"wire_version\":70000}") == .bad);
    try std.testing.expect(manifestWireVersion("[2]") == .bad);
    try std.testing.expect(manifestWireVersion("not json") == .bad);
}

test "this test binary is not a hardened-runtime build (development env overrides stay allowed)" {
    try std.testing.expect(!hardenedRuntime());
}

test "the run cache follows HOME only in development builds" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = std.mem.span(std.c.getenv("HOME") orelse return error.SkipZigTest);
    const dev = runCacheRoot(&buf, false) orelse return error.NoCache;
    try std.testing.expect(std.mem.startsWith(u8, dev, home));
    try std.testing.expect(std.mem.endsWith(u8, dev, "/Library/Caches/maru/web-osr-run"));
    var pw_buf: [std.fs.max_path_bytes]u8 = undefined;
    const release = runCacheRoot(&pw_buf, true) orelse return error.NoCache;
    try std.testing.expect(std.mem.endsWith(u8, release, "/Library/Caches/maru/web-osr-run"));
    // 계정 정보의 홈 — HOME 을 바꿔도 따라가지 않는다.
    const saved = try std.testing.allocator.dupeZ(u8, home);
    defer std.testing.allocator.free(saved);
    defer _ = setenv("HOME", saved, 1);
    try std.testing.expectEqual(@as(c_int, 0), setenv("HOME", "/tmp/maru-not-home", 1));
    try std.testing.expectEqualStrings(release, runCacheRoot(&buf, true).?);
    try std.testing.expect(std.mem.startsWith(u8, runCacheRoot(&buf, false).?, "/tmp/maru-not-home/"));
    try std.testing.expectEqual(@as(c_int, 0), setenv("HOME", "relative", 1));
    try std.testing.expect(runCacheRoot(&buf, false) == null);
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;
extern "c" fn umask(mask: std.c.mode_t) std.c.mode_t;

/// 시험용 가짜 prefix — `<root>/Cellar/maru-chromium/9.9/libexec`(host·helper 는 `/usr/bin/true` 사본, 프레임워크 자리 하나,
/// manifest)와 `<root>/opt/maru-chromium` 링크. 권한은 umask 와 무관하게 `go-w` 로 맞춘다.
const Fake = struct {
    root: []const u8 = "",
    libexec: []const u8 = "",
    root_buf: [std.fs.max_path_bytes]u8 = undefined,
    libexec_buf: [std.fs.max_path_bytes]u8 = undefined,

    fn make(self: *Fake, wire: u16) !void {
        const tmp = if (std.c.getenv("TMPDIR")) |t| std.mem.trimEnd(u8, std.mem.span(t), "/") else "/tmp";
        var template_buf: [std.fs.max_path_bytes]u8 = undefined;
        const template = try std.fmt.bufPrintZ(&template_buf, "{s}/maru-install-{d}-XXXXXX", .{ if (tmp.len > 0 and tmp[0] == '/') tmp else "/tmp", std.c.getpid() });
        const made = mkdtemp(template.ptr) orelse return error.NoTemp;
        const real = std.c.realpath(made, &self.root_buf) orelse {
            removeTreePath(std.mem.span(made));
            return error.NoTemp;
        };
        self.root = std.mem.span(real);
        errdefer self.cleanup();
        self.libexec = try std.fmt.bufPrint(&self.libexec_buf, "{s}/Cellar/maru-chromium/9.9/libexec", .{self.root});
        try std.testing.expect(mkdirs(self.libexec));
        try self.sh(&.{ "/bin/mkdir", "-p", "fw/Chromium Embedded Framework.framework" }, self.libexec);
        try self.sh(&.{ "/bin/cp", "/usr/bin/true", "maru-web-host" }, self.libexec);
        try self.sh(&.{ "/bin/cp", "/usr/bin/true", "maru-web-helper" }, self.libexec);
        var json_buf: [128]u8 = undefined;
        const json = try std.fmt.bufPrint(&json_buf, "{{\"format\":1,\"wire_version\":{d}}}\n", .{wire});
        var manifest_buf: [std.fs.max_path_bytes]u8 = undefined;
        const manifest = try std.fmt.bufPrintZ(&manifest_buf, "{s}/maru-chromium.json", .{self.libexec});
        const fd = std.c.open(manifest, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
        try std.testing.expect(fd >= 0);
        _ = std.c.write(fd, json.ptr, json.len);
        _ = std.c.close(fd);
        var opt_buf: [std.fs.max_path_bytes]u8 = undefined;
        const opt = try std.fmt.bufPrint(&opt_buf, "{s}/opt", .{self.root});
        try std.testing.expect(mkdirs(opt));
        try self.sh(&.{ "/bin/ln", "-s", "../Cellar/maru-chromium/9.9", "maru-chromium" }, opt);
        try self.sh(&.{ "/bin/chmod", "-R", "go-w", "Cellar/maru-chromium/9.9" }, self.root);
    }

    fn optLibexec(self: *const Fake, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "{s}/opt/maru-chromium/libexec", .{self.root});
    }

    fn sh(self: *const Fake, argv: []const []const u8, cwd: []const u8) !void {
        _ = self;
        var store: [8][:0]u8 = undefined;
        var c_argv: [9:null]?[*:0]const u8 = @splat(null);
        for (argv, 0..) |a, i| {
            store[i] = try std.testing.allocator.dupeZ(u8, a);
            c_argv[i] = store[i].ptr;
        }
        defer for (store[0..argv.len]) |a| std.testing.allocator.free(a);
        const cwd_z = try std.testing.allocator.dupeZ(u8, cwd);
        defer std.testing.allocator.free(cwd_z);
        const pid = std.c.fork();
        if (pid == 0) {
            if (std.c.chdir(cwd_z) != 0) std.c._exit(126);
            _ = std.c.execve(c_argv[0].?, &c_argv, @ptrCast(std.c.environ));
            std.c._exit(127);
        }
        var status: c_int = 0;
        _ = std.c.waitpid(pid, &status, 0);
        const s: u32 = @bitCast(status);
        if (s != 0) return error.CommandFailed;
    }

    fn exists(self: *const Fake, rel: []const u8) bool {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const z = std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ self.root, rel }) catch return false;
        return statNoFollow(z) != null;
    }

    fn cleanup(self: *const Fake) void {
        removeTreePath(self.root);
    }
};

fn expectBad(want: Problem, got: Opened) !void {
    switch (got) {
        .ok => |fd| {
            closeFd(fd);
            return error.TestExpectedBad;
        },
        .bad => |p| try std.testing.expectEqual(want, p),
    }
}

test "a brew install is accepted only as a real, private keg with a matching manifest" {
    var fake: Fake = .{};
    try fake.make(ws.wire.version);
    defer fake.cleanup();
    var opt_buf: [std.fs.max_path_bytes]u8 = undefined;
    const opt = try fake.optLibexec(&opt_buf);
    const opened = openBrewSource(opt, fake.root);
    try std.testing.expect(opened == .ok);
    closeFd(opened.ok);
    try std.testing.expectEqual(@as(?Problem, null), verifyRunDir(fake.libexec, true));
    // prefix 는 실제 경로로 비교한다 — 링크로 가리킨 prefix 도 같은 설치다.
    try fake.sh(&.{ "/bin/ln", "-s", fake.root, "prefix-link" }, fake.root);
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    const link = try std.fmt.bufPrint(&link_buf, "{s}/prefix-link", .{fake.root});
    const via_link = openBrewSource(opt, link);
    try std.testing.expect(via_link == .ok);
    closeFd(via_link.ok);
    // 다른 prefix 의 설치로 들이밀면 안 된다.
    try expectBad(.not_in_keg, openBrewSource(opt, "/opt/homebrew"));
    // 안에 링크가 하나라도 있으면 안 된다.
    try fake.sh(&.{ "/bin/ln", "-s", "/etc/hosts", "fw/sneaky" }, fake.libexec);
    try expectBad(.symlink, openBrewSource(opt, fake.root));
    try fake.sh(&.{ "/bin/rm", "fw/sneaky" }, fake.libexec);
    // FIFO 도 안 된다(열면 멈춘다).
    try fake.sh(&.{ "/usr/bin/mkfifo", "-m", "644", "fw/pipe" }, fake.libexec);
    try expectBad(.not_regular, openBrewSource(opt, fake.root));
    try fake.sh(&.{ "/bin/rm", "fw/pipe" }, fake.libexec);
    // 그룹이 쓸 수 있으면 안 된다 — 안의 파일도, keg 자체도(keg 에서 libexec 를 바꿔치지 못하게).
    try fake.sh(&.{ "/bin/chmod", "g+w", "maru-web-helper" }, fake.libexec);
    try expectBad(.writable_by_others, openBrewSource(opt, fake.root));
    try fake.sh(&.{ "/bin/chmod", "g-w", "maru-web-helper" }, fake.libexec);
    var cellar_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rack = try std.fmt.bufPrint(&cellar_buf, "{s}/Cellar/maru-chromium", .{fake.root});
    try fake.sh(&.{ "/bin/chmod", "g+w", "9.9" }, rack);
    try expectBad(.writable_by_others, openBrewSource(opt, fake.root));
    try fake.sh(&.{ "/bin/chmod", "g-w", "9.9" }, rack);
    try fake.sh(&.{ "/bin/chmod", "g+w", "libexec" }, fake.libexec[0 .. fake.libexec.len - "/libexec".len]);
    try expectBad(.writable_by_others, openBrewSource(opt, fake.root));
    try fake.sh(&.{ "/bin/chmod", "g-w", "libexec" }, fake.libexec[0 .. fake.libexec.len - "/libexec".len]);
    // 서명이 내용과 안 맞으면(바꿔치기 뒤 재서명 안 함) 안 된다.
    try fake.sh(&.{ "/bin/sh", "-c", "printf x >> maru-web-host" }, fake.libexec);
    try std.testing.expectEqual(@as(?Problem, .bad_signature), verifyRunDir(fake.libexec, true));
    try fake.sh(&.{ "/bin/cp", "/usr/bin/true", "maru-web-host" }, fake.libexec);
    // manifest: 없으면 brew 설치는 안 되고(개발 디렉터리는 된다), 제어 채널 버전이 다르면 버전 불일치, FIFO 면 멈추지 않고 거절.
    try fake.sh(&.{ "/bin/mv", "maru-chromium.json", "saved.json" }, fake.libexec);
    try std.testing.expectEqual(@as(?Problem, .no_manifest), verifyRunDir(fake.libexec, true));
    try std.testing.expectEqual(@as(?Problem, null), verifyRunDir(fake.libexec, false));
    try fake.sh(&.{ "/usr/bin/mkfifo", "maru-chromium.json" }, fake.libexec);
    try std.testing.expectEqual(@as(?Problem, .bad_manifest), verifyRunDir(fake.libexec, false));
    try fake.sh(&.{ "/bin/rm", "maru-chromium.json" }, fake.libexec);
    try fake.sh(&.{ "/bin/sh", "-c", "printf '{\"wire_version\":999}' > maru-chromium.json" }, fake.libexec);
    try std.testing.expectEqual(@as(?Problem, .version_mismatch), verifyRunDir(fake.libexec, true));
}

test "a tree deeper or larger than any real install is refused" {
    var fake: Fake = .{};
    try fake.make(ws.wire.version);
    defer fake.cleanup();
    var opt_buf: [std.fs.max_path_bytes]u8 = undefined;
    const opt = try fake.optLibexec(&opt_buf);
    // 깊이: libexec 아래 16 단계까지는 되고 17 단계는 안 된다(경계에서 — 상한을 늦추면 걸린다).
    try fake.sh(&.{ "/bin/mkdir", "-p", "d/d/d/d/d/d/d/d/d/d/d/d/d/d/d/d" }, fake.libexec);
    try fake.sh(&.{ "/bin/chmod", "-R", "go-w", "d" }, fake.libexec);
    const deep_ok = openBrewSource(opt, fake.root);
    try std.testing.expect(deep_ok == .ok);
    closeFd(deep_ok.ok);
    try fake.sh(&.{ "/bin/mkdir", "-p", "d/d/d/d/d/d/d/d/d/d/d/d/d/d/d/d/d" }, fake.libexec);
    try fake.sh(&.{ "/bin/chmod", "-R", "go-w", "d" }, fake.libexec);
    try expectBad(.too_large, openBrewSource(opt, fake.root));
    try fake.sh(&.{ "/bin/rm", "-r", "d" }, fake.libexec);
    // 항목 수: 모두 5000 개면 되고 5001 개면 안 된다.
    try fake.sh(&.{ "/bin/sh", "-c", "n=$(find . -mindepth 1 | wc -l); mkdir wide && cd wide && i=$((n+1)); while [ $i -lt 5000 ]; do : > f$i; i=$((i+1)); done; chmod -R go-w ." }, fake.libexec);
    const wide_ok = openBrewSource(opt, fake.root);
    try std.testing.expect(wide_ok == .ok);
    closeFd(wide_ok.ok);
    try fake.sh(&.{ "/usr/bin/touch", "wide/one-more" }, fake.libexec);
    try expectBad(.too_large, openBrewSource(opt, fake.root));
    try fake.sh(&.{ "/bin/rm", "-r", "wide" }, fake.libexec);
    const ok = openBrewSource(opt, fake.root);
    try std.testing.expect(ok == .ok);
    closeFd(ok.ok);
}

test "the clone comes from the keg that was checked, even if the rack is swapped after the check" {
    var fake: Fake = .{};
    try fake.make(ws.wire.version);
    defer fake.cleanup();
    var opt_buf: [std.fs.max_path_bytes]u8 = undefined;
    const opt = try fake.optLibexec(&opt_buf);
    const opened = openBrewSource(opt, fake.root);
    try std.testing.expect(opened == .ok);
    defer closeFd(opened.ok);
    // 검사 뒤 — admin 그룹의 다른 계정 흉내: rack 을 치우고 같은 이름에 다른 트리를 둔다.
    try fake.sh(&.{ "/bin/mv", "Cellar/maru-chromium", "Cellar/moved" }, fake.root);
    try fake.sh(&.{ "/bin/mkdir", "-p", "Cellar/maru-chromium/9.9/libexec" }, fake.root);
    try fake.sh(&.{ "/usr/bin/touch", "Cellar/maru-chromium/9.9/libexec/evil" }, fake.root);
    var cache_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cache = try std.fmt.bufPrint(&cache_buf, "{s}/cache", .{fake.root});
    var copy = switch (cloneForRun(opened.ok, cache)) {
        .ok => |c| c,
        .bad => return error.CloneFailed,
    };
    defer copy.release();
    try std.testing.expectEqual(@as(?Problem, null), verifyRunDir(copy.dir(), true));
    var evil_buf: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expect(statNoFollow(try std.fmt.bufPrintZ(&evil_buf, "{s}/evil", .{copy.dir()})) == null);
}

test "each start runs from a fresh clone held until release; unlocked leftovers are swept, another maru's clone is kept" {
    var fake: Fake = .{};
    try fake.make(ws.wire.version);
    defer fake.cleanup();
    const source = openDevSource(fake.libexec) orelse return error.NoSource;
    defer closeFd(source);
    var cache_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cache = try std.fmt.bufPrint(&cache_buf, "{s}/cache", .{fake.root});
    var first = switch (cloneForRun(source, cache)) {
        .ok => |c| c,
        .bad => return error.CloneFailed,
    };
    var first_released = false;
    defer if (!first_released) first.release();
    try std.testing.expectEqual(@as(?Problem, null), verifyRunDir(first.dir(), true));
    // 다른 maru 인스턴스가 쥔 사본 흉내 — 잠금을 따로 쥔다(flock 은 열린 파일마다라 같은 프로세스여도 겹친다).
    try fake.sh(&.{ "/bin/mkdir", "-p", "run-1-other" }, cache);
    try fake.sh(&.{ "/usr/bin/touch", "run-1-other.lock" }, cache);
    var other_lock_buf: [std.fs.max_path_bytes]u8 = undefined;
    const other_lock = try std.fmt.bufPrintZ(&other_lock_buf, "{s}/run-1-other.lock", .{cache});
    const other_fd = std.c.open(other_lock, .{ .ACCMODE = .RDONLY, .SHLOCK = true });
    try std.testing.expect(other_fd >= 0);
    defer closeFd(other_fd);
    // 잠금 없이 남은 옛 사본(잠금보다 먼저 죽은 것 — 주인이 쓸 수 없는 디렉터리도)과 사본 없이 남은 잠금(복제 전에 죽은 것).
    try fake.sh(&.{ "/bin/mkdir", "-p", "run-2-orphan/sub/ro" }, cache);
    try fake.sh(&.{ "/usr/bin/touch", "run-2-orphan/sub/ro/f" }, cache);
    try fake.sh(&.{ "/bin/chmod", "555", "run-2-orphan/sub/ro" }, cache);
    try fake.sh(&.{ "/usr/bin/touch", "run-3-lockonly.lock" }, cache);
    // 다른 maru 가 방금 잠금을 만들고 아직 복제하지 않은 것(쥐고 있다) — 지우면 안 된다.
    try fake.sh(&.{ "/usr/bin/touch", "run-5-cloning.lock" }, cache);
    var cloning_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cloning_fd = std.c.open(try std.fmt.bufPrintZ(&cloning_buf, "{s}/run-5-cloning.lock", .{cache}), .{ .ACCMODE = .RDONLY, .SHLOCK = true });
    try std.testing.expect(cloning_fd >= 0);
    defer closeFd(cloning_fd);
    // 잠금을 열 수 없는 사본(권한 — fd 가 바닥난 것과 같이 「잠금 없음」이 아니다)은 남긴다.
    try fake.sh(&.{ "/bin/mkdir", "-p", "run-6-unreadable" }, cache);
    try fake.sh(&.{ "/usr/bin/touch", "run-6-unreadable.lock" }, cache);
    try fake.sh(&.{ "/bin/chmod", "000", "run-6-unreadable.lock" }, cache);
    // 두 번째 사본 — 첫 사본은 아직 쥐고 있으니(물러나는 sidecar) 남는다.
    var second = switch (cloneForRun(source, cache)) {
        .ok => |c| c,
        .bad => return error.CloneFailed,
    };
    defer second.release();
    try std.testing.expect(!std.mem.eql(u8, first.dir(), second.dir()));
    try std.testing.expect(fake.exists("cache/run-1-other"));
    try std.testing.expect(!fake.exists("cache/run-2-orphan"));
    try std.testing.expect(!fake.exists("cache/run-3-lockonly.lock"));
    try std.testing.expect(fake.exists("cache/run-5-cloning.lock"));
    try std.testing.expect(fake.exists("cache/run-6-unreadable"));
    var z_buf: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expect(statNoFollow(try std.fmt.bufPrintZ(&z_buf, "{s}", .{first.dir()})) != null);
    // 놓으면 사본과 잠금이 지워진다.
    first.release();
    first_released = true;
    try std.testing.expect(statNoFollow(try std.fmt.bufPrintZ(&z_buf, "{s}", .{first.dir()})) == null);
    try std.testing.expect(statNoFollow(try std.fmt.bufPrintZ(&z_buf, "{s}.lock", .{first.dir()})) == null);
    try std.testing.expect(statNoFollow(try std.fmt.bufPrintZ(&z_buf, "{s}", .{second.dir()})) != null);
    // 엔진을 정할 때의 청소도 남의 사본은 남긴다.
    try fake.sh(&.{ "/bin/mkdir", "-p", "run-4-orphan" }, cache);
    sweepRunCopies(cache);
    try std.testing.expect(!fake.exists("cache/run-4-orphan"));
    try std.testing.expect(fake.exists("cache/run-1-other"));
    try std.testing.expect(statNoFollow(try std.fmt.bufPrintZ(&z_buf, "{s}", .{second.dir()})) != null);
}

test "a lock file removed or replaced between create and lock is noticed" {
    var fake: Fake = .{};
    try fake.make(ws.wire.version);
    defer fake.cleanup();
    const root_fd = openDevSource(fake.root) orelse return error.NoRoot;
    defer closeFd(root_fd);
    const fd = std.c.openat(root_fd, "x.lock", .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true }, @as(std.c.mode_t, 0o600));
    try std.testing.expect(fd >= 0);
    defer closeFd(fd);
    try std.testing.expect(lockStillNamed(root_fd, "x.lock", fd));
    _ = std.c.unlinkat(root_fd, "x.lock", 0);
    try std.testing.expect(!lockStillNamed(root_fd, "x.lock", fd));
    const other = std.c.openat(root_fd, "x.lock", .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true }, @as(std.c.mode_t, 0o600));
    try std.testing.expect(other >= 0);
    closeFd(other);
    try std.testing.expect(!lockStillNamed(root_fd, "x.lock", fd)); // 같은 이름의 다른 파일
    // 잠근 파일이 다른 이름으로도 살아 있어(nlink > 0) 이름만 다른 파일로 바뀐 경우 — inode 로 가른다.
    _ = std.c.unlinkat(root_fd, "x.lock", 0);
    const kept = std.c.openat(root_fd, "y.lock", .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true }, @as(std.c.mode_t, 0o600));
    try std.testing.expect(kept >= 0);
    defer closeFd(kept);
    try std.testing.expectEqual(@as(c_int, 0), linkat(root_fd, "y.lock", root_fd, "z.lock", 0));
    try std.testing.expectEqual(@as(c_int, 0), std.c.unlinkat(root_fd, "y.lock", 0));
    const again = std.c.openat(root_fd, "y.lock", .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true }, @as(std.c.mode_t, 0o600));
    try std.testing.expect(again >= 0);
    closeFd(again);
    try std.testing.expect(!lockStillNamed(root_fd, "y.lock", kept));
}

extern "c" fn linkat(fd1: c_int, name1: [*:0]const u8, fd2: c_int, name2: [*:0]const u8, flag: c_int) c_int;

test "a lock taken away between create and lock makes the clone retry under a new name" {
    var fake: Fake = .{};
    try fake.make(ws.wire.version);
    defer fake.cleanup();
    const source = openDevSource(fake.libexec) orelse return error.NoSource;
    defer closeFd(source);
    var cache_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cache = try std.fmt.bufPrint(&cache_buf, "{s}/cache", .{fake.root});
    const Hook = struct {
        var calls: u32 = 0;
        fn stealFirst(root_fd: c_int, lock: [*:0]const u8) void {
            calls += 1;
            if (calls == 1) _ = std.c.unlinkat(root_fd, lock, 0); // 다른 maru 의 청소가 막 만든 잠금을 지웠다
        }
    };
    Hook.calls = 0;
    test_after_lock_create = Hook.stealFirst;
    defer test_after_lock_create = null;
    var copy = switch (cloneForRun(source, cache)) {
        .ok => |c| c,
        .bad => return error.CloneFailed,
    };
    defer copy.release();
    try std.testing.expectEqual(@as(u32, 2), Hook.calls);
    var lock_buf: [std.fs.max_path_bytes]u8 = undefined;
    const lock = try std.fmt.bufPrintZ(&lock_buf, "{s}.lock", .{copy.dir()});
    try std.testing.expect(lockStillNamed(std.c.AT.FDCWD, lock, copy.lock_fd));
}

test "the run cache must be a private directory of this user" {
    var fake: Fake = .{};
    try fake.make(ws.wire.version);
    defer fake.cleanup();
    const source = openDevSource(fake.libexec) orelse return error.NoSource;
    defer closeFd(source);
    var cache_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cache = try std.fmt.bufPrint(&cache_buf, "{s}/cache", .{fake.root});
    try std.testing.expect(mkdirs(cache));
    try fake.sh(&.{ "/bin/chmod", "755", "cache" }, fake.root);
    try std.testing.expectEqual(Problem.writable_by_others, cloneForRun(source, cache).bad);
    try fake.sh(&.{ "/bin/chmod", "700", "cache" }, fake.root);
    try fake.sh(&.{ "/bin/mv", "cache", "real-cache" }, fake.root);
    try fake.sh(&.{ "/bin/ln", "-s", "real-cache", "cache" }, fake.root);
    try std.testing.expectEqual(Problem.unreadable, cloneForRun(source, cache).bad);
    // 만들 때는 umask 와 무관하게 0700.
    const old = umask(0o002);
    defer _ = umask(old);
    var fresh_buf: [std.fs.max_path_bytes]u8 = undefined;
    const fresh = try std.fmt.bufPrint(&fresh_buf, "{s}/fresh/cache", .{fake.root});
    var copy = switch (cloneForRun(source, fresh)) {
        .ok => |c| c,
        .bad => return error.CloneFailed,
    };
    copy.release();
}
