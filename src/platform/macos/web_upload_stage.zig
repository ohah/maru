//! 에이전트의 파일 올리기(W9c③ `browser.upload`)에서 **파일을 여는 일과 사본을 만드는 일**(L4 — POSIX). 앱이 파일을 읽는다(사용자 결정
//! 2026-10-15). 확인 모달은 사용자 결정 2026-11-16(「AI 가 모든 접근」)으로 걷혔다 — 그래도 연 파일과 페이지가 받는 바이트가 같아야 한다
//! (그 사이 파일을 바꿔치는 길을 막는다). 그래서(계획 공격 A3·A4·A7):
//!
//! - **먼저 연다**(`prepare`): `realpath` → `open(O_RDONLY|O_NONBLOCK|O_NOFOLLOW)` → `fstat`(정규 파일만 — 폴더·FIFO·장치·소켓은
//!   거절, `O_NONBLOCK` 이라 FIFO 를 열다 멈추지 않는다) → `F_GETPATH`(실제 경로 — 연 fd 의 것) → 앞부분 4 KiB. fd 를 쥔 채로
//!   둔다. realpath 뒤 마지막 이름이 링크로 바뀌면 `O_NOFOLLOW` 가 막는다(ELOOP).
//! - **그 뒤에 쥔 fd 에서 사본**(`stageFile`): `fclonefileat`(같은 볼륨 — 2 ms, 원본이 갈라질 때까지 공간을 쓰지 않는다), 안 되면 fd 에서
//!   복사(다른 볼륨 — 상한 안에서만). 사본 뒤 fd 를 다시 `fstat` 해 (장치·inode·크기·mtime·ctime) 가 열 때와 다르면 실패 — 「연 뒤
//!   파일이 바뀌었다」. ctime 은 사용자가 되돌릴 수 없다(적대 리뷰 1 회차 — 같은 길이로 제자리에서 바꿔 쓰고 `futimens` 로 mtime 을 되돌리면
//!   mtime 만으로는 몰랐다). **다만 공유 매핑(`mmap` MAP_SHARED)으로 쓴 것은 msync 전까지 mtime·ctime 을 움직이지 않는다**(적대 리뷰 3 회차 실측 —
//!   복제·복사는 바뀐 바이트를 가져갔다). 그래서 내용으로도 본다: 열 때 앞부분을 읽는 그 읽기로 SHA-256 을 내고(`hash_cap_per_call` 까지 —
//!   앞부분은 늘 그 안이다), 사본의 같은 앞부분을 다시 읽어 같지 않으면 `changed`. 복제는 그 순간 원본과 갈라지므로(CoW) 사본을 재면 페이지가
//!   읽을 바이트를 잰다. 복제는 원본의 파일 플래그(Finder 의 「잠금」 `uchg`)도 옮긴다 — 사본에서 푼다(못 풀면 0400 도, 지우기도 막혔다).
//!   페이지는 사본만 본다: 연 뒤 원본을 바꾸거나 링크를 바꿔도 닿지 않는다(실측 k9c — 원본 경로를 넘기면 바뀐 대상을 읽었다).
//! - **사본 자리**: `<프로필>/upload-staging/<탭>/<op>/<i>/<이름>` — 폴더 0700, 파일 0400. 탭이 닫힐 때 그 탭의 폴더를 지우고(방문 기록
//!   뒤로가기가 그 파일을 새 문서에 되살린다 — 실측 l), 이 실행이 처음 프로필을 잡을 때 전부 지운다. 뿌리는 한 번 `realpath` 한
//!   정규 경로다(정규가 아닌 경로는 읽기가 깨지거나 렌더러가 죽었다 — 실측 k3·k4).
//!
//! 느린 볼륨(죽은 망 마운트)의 `open`·`stat`·읽기는 멈출 수 있다 — 이 함수들은 **작업 스레드**에서 부른다(`app_host_abi` 의 업로드 작업).
//! 이 파일은 스레드를 띄우지 않는다.

const array_repeat = @import("array_repeat");

const std = @import("std");
const builtin = @import("builtin");
/// 파일을 열 때 앞부분을 이만큼 읽어 같은 읽기로 해시한다(사본의 같은 앞부분과 견준다 — 적대 리뷰 3 회차 M1).
pub const head_bytes = 4096;

extern "c" fn fclonefileat(srcfd: c_int, dst_dirfd: c_int, dst: [*:0]const u8, flags: u32) c_int;
extern "c" fn fchflags(fd: c_int, flags: c_uint) c_int;

/// 사용자가 거는 잠금 플래그 — Finder 의 「잠금」(`uchg` = UF_IMMUTABLE)과 `uappnd`(UF_APPEND). 사본에서는 **이것만** 푼다: 플래그를 통째로
/// 지우면 투명 압축(UF_COMPRESSED — decmpfs, `ditto --hfsCompression`·앱 번들·설치 프로그램이 깐 파일)도 지워져 데이터(리소스 포크 xattr)의
/// 해석을 잃고 사본이 0 바이트가 된다(적대 리뷰 2 회차 실측 — 그러면 늘 「changed」).
const uf_lock_flags: u32 = 0x2 | 0x4; // UF_IMMUTABLE | UF_APPEND

/// macOS 의 EOPNOTSUPP(102) — 소켓을 `open` 하면 이것이다. zig 의 `E.OPNOTSUPP` 는 ENOTSUP(45)라 이름이 없다(적대 리뷰 1 회차 — 소켓이
/// 「열 수 없다」 로 샜다).
const darwin_eopnotsupp: c_int = 102;

/// 다른 볼륨에서 복사할 때 한 번의 호출이 쓸 수 있는 바이트(작성자 선택 1 GiB)와 한 탭이 쓸 수 있는 바이트(4 GiB) — 같은 볼륨의 복제는 세지 않는다.
pub const copy_cap_per_call: u64 = 1 << 30;
pub const copy_cap_per_tab: u64 = 4 << 30;

/// 한 번의 호출이 내용 해시(적대 리뷰 3 회차 M1)로 읽는 바이트 — 복사 상한과 같은 1 GiB(작성자 선택). 파일마다 엿보기만큼은 늘 잰다(넘어도 —
/// 파일 열 개면 40 KiB). 상한을 넘은 뒤쪽은 stat(크기·ctime)만 본다 — 공유 매핑으로 그 뒤쪽만 바꾸면 모른다(문서의 남는 틈). 실측(M4 Max,
/// ReleaseFast, 따뜻한 캐시): 1 GiB 를 모달 전에 한 번 0.41 초(SHA-256 만 0.36 초), 승인 뒤 사본에서 한 번 더 0.43 초 — 모달이 그만큼 늦게 뜬다
/// (작성자 선택: 「확인 중」 상태 없이 받아들인다 — 큰 파일만, 상한까지만). 다른 볼륨의 원본은 그래서 **두 번** 읽힌다 — 모달 전 해시(1 GiB 까지),
/// 승인 뒤 복사(1 GiB 까지), 그리고 로컬 사본의 해시. 셋 다 모달의 120 초 창 안이다(앱이 모달을 멈출 때 요청 시한을 그만큼 잡고, 사본이 다 된 뒤에야
/// 보통 시한으로 되돌린다). 느린 볼륨(SMB·USB 약 20 MB/s 면 1 GiB 에 50 초씩)에서는 큰 업로드가 승인 뒤 그 창을 넘겨 `-32004` 로 끝날 수 있다 —
/// 닫힌 쪽으로 실패한다(넣기 전이라 아무것도 올라가지 않고 사본은 작업 스레드가 지운다). 해시하며 곧바로 대기 사본을 쓰고 승인에만 내놓으면 한 번으로
/// 줄지만, 모달 전에(사용자가 답하기 전에) 원본을 프로필로 복사하게 된다 — 적대 리뷰 4 회차 N5 는 문서로만 남긴다(작성자 선택).
pub const hash_cap_per_call: u64 = 1 << 30;

const Sha256 = std.crypto.hash.sha2.Sha256;
/// 해시 읽기의 한 번 크기(작업 스레드의 힙).
const hash_chunk_bytes = 1 << 20;

/// 모달 전에 연 파일 하나. `fd` 는 승인 뒤 사본을 만들 때까지 쥔다(`deinit` 이 닫는다).
pub const Prepared = struct {
    fd: c_int,
    /// `F_GETPATH` — 모달이 보이는 실제 경로(소유).
    real: []u8,
    size: u64,
    dev: i32,
    ino: u64,
    nlink: u64,
    mtime_sec: i64,
    mtime_nsec: i64,
    /// 상태가 바뀐 시각 — 내용·mtime 을 바꾸면 움직이고 사용자가 되돌릴 수 없다(`futimens` 도 이것을 지금으로 바꾼다).
    ctime_sec: i64,
    ctime_nsec: i64,
    /// 앞부분(최대 `head_bytes`, 소유) — 해시의 앞쪽.
    head: []u8,
    /// 앞 `hashed` 바이트의 SHA-256 — `head` 를 읽은 그 읽기에서 낸다(적대 리뷰 3 회차 M1). 사본의 같은 앞부분과 견준다.
    digest: [Sha256.digest_length]u8,
    hashed: u64,

    pub fn deinit(self: *Prepared, gpa: std.mem.Allocator) void {
        if (self.fd >= 0) _ = std.c.close(self.fd);
        gpa.free(self.real);
        gpa.free(self.head);
        self.* = undefined;
    }

    /// 사본의 이름 — 실제 경로의 마지막 이름(링크의 이름이 아니다 — 작성자 선택).
    pub fn name(self: *const Prepared) []const u8 {
        const slash = std.mem.lastIndexOfScalar(u8, self.real, '/') orelse return self.real;
        return self.real[slash + 1 ..];
    }
};

/// 열지 못한 이유(CLI·MCP 로 가는 영어 글 — 부른 쪽이 경로를 앞에 붙인다).
pub const Refusal = enum {
    not_found,
    is_folder,
    not_regular,
    swapped,
    unreadable,
    control_chars,
    duplicate,
    too_long,
    unsteady,

    pub fn text(self: Refusal) []const u8 {
        return switch (self) {
            .not_found => "no such file",
            .is_folder => "it is a folder — pass the files inside it, not the folder",
            .not_regular => "not a regular file (a device, pipe or socket)",
            .swapped => "the file was replaced by a link while it was being opened",
            .unreadable => "cannot open it for reading",
            .control_chars => "its real path contains control characters",
            .duplicate => "the same file is listed twice",
            .too_long => "the path is too long",
            .unsteady => "the file kept changing while it was being opened",
        };
    }
};

pub const PrepareResult = union(enum) { ok: Prepared, refused: Refusal };

fn statOf(fd: c_int) ?std.c.Stat {
    var st: std.c.Stat = undefined;
    if (std.c.fstat(fd, &st) != 0) return null;
    return st;
}

/// 경로 하나를 연다(모달 전) — 해시 예산은 이 파일 혼자(1 GiB). 시험이 쓴다.
pub fn prepare(gpa: std.mem.Allocator, path: []const u8) !PrepareResult {
    var budget: u64 = hash_cap_per_call;
    return prepareWith(gpa, path, &budget);
}

/// 경로 하나를 연다(모달 전). 상대 경로·제어 문자는 L2 가 거절했다. 작업 스레드에서 부른다. `hash_budget` — 이 호출의 파일들이 함께 쓰는 내용
/// 해시 예산(`hash_cap_per_call` 에서 시작, 잰 만큼 준다).
pub fn prepareWith(gpa: std.mem.Allocator, path: []const u8, hash_budget: *u64) !PrepareResult {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_z = std.fmt.bufPrintSentinel(&path_buf, "{s}", .{path}, 0) catch return .{ .refused = .too_long };
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real = std.c.realpath(path_z.ptr, &real_buf) orelse {
        const e = std.c._errno().*;
        return .{ .refused = if (e == @backingInt(std.c.E.NOENT) or e == @backingInt(std.c.E.NOTDIR)) .not_found else .unreadable };
    };
    if (builtin.is_test) if (test_after_realpath) |hook| hook(real);
    // 정규 경로를 정한 뒤 열기 전에 그 자리가 링크로 바뀌면(남이 바꿔치기) 따라가지 않는다 — 「바뀌었다」(`swapped`).
    const fd = std.c.open(real, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true, .NONBLOCK = true }, @as(std.c.mode_t, 0));
    if (fd < 0) {
        const e = std.c._errno().*;
        return .{ .refused = if (e == @backingInt(std.c.E.LOOP)) .swapped else if (e == @backingInt(std.c.E.NOENT)) .not_found else if (e == darwin_eopnotsupp or e == @backingInt(std.c.E.OPNOTSUPP) or e == @backingInt(std.c.E.NXIO)) .not_regular else .unreadable };
    }
    var keep = false;
    defer if (!keep) {
        _ = std.c.close(fd);
    };
    const st = statOf(fd) orelse return .{ .refused = .unreadable };
    const fmt = st.mode & std.c.S.IFMT;
    if (fmt == std.c.S.IFDIR) return .{ .refused = .is_folder };
    if (fmt != std.c.S.IFREG) return .{ .refused = .not_regular };
    var got_buf: [std.fs.max_path_bytes]u8 = undefined;
    @memset(&got_buf, 0);
    if (std.c.fcntl(fd, std.c.F.GETPATH, &got_buf) != 0) return .{ .refused = .unreadable };
    const got = std.mem.sliceTo(&got_buf, 0);
    // 실제 경로에 제어 문자가 있으면(링크가 줄바꿈 이름을 가리킨다 — 요청 경로는 L2 가 막았다) 모달에서 다른 줄처럼 보이게 할 수 있다 — 거절.
    for (got) |b| if (b < 0x20 or b == 0x7f) return .{ .refused = .control_chars };
    if (std.unicode.Utf8View.init(got)) |view| {
        var it = view.iterator();
        while (it.nextCodepoint()) |c| if (c >= 0x80 and c <= 0x9f) return .{ .refused = .control_chars };
    } else |_| {}
    // 엿보기는 적은 상태보다 새것이면 안 된다 — stat 을 먼저 하고 읽은 뒤 다시 본다. 읽기가 파일을 바꿀 수 있다: 데이터가 내려와 있지 않은
    // 파일(iCloud 「Mac 저장 공간 최적화」·Dropbox 온라인 전용 — dataless)은 읽는 순간 내려받아 채워지고 ctime 이 움직인다. 처음 적은 상태로는
    // 승인 뒤 사본의 비교가 늘 「changed」 라 사용자가 모달을 두 번 보았다(적대 리뷰 2 회차 LOW-C). 그래서 읽기 뒤 상태가 다르면 한 번 더 읽고
    // 두 번째 상태를 쓴다 — 그것도 다르면 계속 바뀌는 파일이니 거절(모달이 보일 것을 정할 수 없다).
    // 내용 해시(3 회차 M1)도 같은 읽기에서 낸다 — 엿보기가 해시한 바이트의 앞부분이어야 사본의 해시가 같을 때 사본의 앞부분이 연 때의 그것이다.
    var attempt: u8 = 0;
    const snap: Snapshot = while (true) : (attempt += 1) {
        const before = statOf(fd) orelse return .{ .refused = .unreadable };
        const read = (try readHeadHashed(gpa, fd, @intCast(@max(before.size, 0)), hash_budget.*)) orelse return .{ .refused = .unreadable };
        if (builtin.is_test) if (test_after_peek) |hook| hook(fd);
        const after = statOf(fd) orelse {
            gpa.free(read.head);
            return .{ .refused = .unreadable };
        };
        if (sameState(before, after)) break .{ .st = before, .head = read.head, .digest = read.digest, .hashed = read.hashed };
        gpa.free(read.head);
        if (attempt >= 1) return .{ .refused = .unsteady };
    };
    errdefer gpa.free(snap.head);
    hash_budget.* -|= snap.hashed;
    const real_owned = try gpa.dupe(u8, got);
    keep = true;
    const st2 = snap.st;
    return .{ .ok = .{
        .fd = fd,
        .real = real_owned,
        .size = @intCast(@max(st2.size, 0)),
        .dev = st2.dev,
        .ino = st2.ino,
        .nlink = st2.nlink,
        .mtime_sec = st2.mtimespec.sec,
        .mtime_nsec = st2.mtimespec.nsec,
        .ctime_sec = st2.ctimespec.sec,
        .ctime_nsec = st2.ctimespec.nsec,
        .head = snap.head,
        .digest = snap.digest,
        .hashed = snap.hashed,
    } };
}

const Snapshot = struct { st: std.c.Stat, head: []u8, digest: [Sha256.digest_length]u8, hashed: u64 };

/// 시험만 — 엿보기를 읽은 뒤·다시 stat 하기 전에 부른다(그 사이에 파일이 바뀌는 것을 흉내 낸다).
var test_after_peek: ?*const fn (fd: c_int) void = null;
/// 시험만 — 정규 경로를 정한 뒤·열기 전에 부른다(그 사이 그 자리를 링크로 바꿔치는 것을 흉내 낸다 — 5 회차 변이).
var test_after_realpath: ?*const fn (real: [*:0]const u8) void = null;

/// 두 stat 이 같은 파일의 같은 상태인가 — 사본 뒤 비교(`stageFileWith`)와 같은 항목(장치·inode·크기·mtime·ctime).
fn sameState(a: std.c.Stat, b: std.c.Stat) bool {
    return a.dev == b.dev and a.ino == b.ino and a.size == b.size and a.mtimespec.sec == b.mtimespec.sec and a.mtimespec.nsec == b.mtimespec.nsec and
        a.ctimespec.sec == b.ctimespec.sec and a.ctimespec.nsec == b.ctimespec.nsec;
}

const HeadHashed = struct { head: []u8, digest: [Sha256.digest_length]u8, hashed: u64 };

/// 앞부분(최대 `head_bytes`, 소유)을 읽고, 같은 읽기로 앞 `max(엿보기, min(크기, budget))` 바이트의 SHA-256 을 낸다(파일이
/// 짧아졌으면 읽은 만큼 — 부른 쪽의 stat 비교가 다시 읽게 한다). 읽기 오류면 null.
fn readHeadHashed(gpa: std.mem.Allocator, fd: c_int, size: u64, budget: u64) !?HeadHashed {
    const want_head: usize = @intCast(@min(size, head_bytes));
    const limit = @max(@as(u64, want_head), @min(size, budget));
    const buf = try gpa.alloc(u8, @intCast(@min(limit, hash_chunk_bytes)));
    defer gpa.free(buf);
    var h = Sha256.init(.{});
    var head = try gpa.alloc(u8, want_head);
    errdefer gpa.free(head);
    var have_head: usize = 0;
    const got = hashFd(fd, limit, buf, &h, struct {
        head: []u8,
        have: *usize,
        fn see(self: @This(), off: u64, bytes: []const u8) void {
            if (off >= self.head.len) return;
            const n = @min(bytes.len, self.head.len - @as(usize, @intCast(off)));
            @memcpy(self.head[@intCast(off)..][0..n], bytes[0..n]);
            self.have.* = @intCast(off + n);
        }
    }{ .head = head, .have = &have_head }) orelse {
        gpa.free(head);
        return null;
    };
    if (have_head < head.len) {
        const short = try gpa.dupe(u8, head[0..have_head]);
        gpa.free(head);
        head = short;
    }
    return .{ .head = head, .digest = h.finalResult(), .hashed = got };
}

/// fd 의 앞 `limit` 바이트를 `buf` 단위로 읽어 `h` 에 넣는다(`sink.see(오프셋, 바이트)` 도 부른다). 읽은 바이트 수 — 끝에 닿으면 그만큼. 읽기
/// 오류면 null.
fn hashFd(fd: c_int, limit: u64, buf: []u8, h: *Sha256, sink: anytype) ?u64 {
    var off: u64 = 0;
    while (off < limit) {
        const want: usize = @intCast(@min(limit - off, buf.len));
        const n = std.c.pread(fd, buf.ptr, want, @intCast(off));
        if (n < 0) {
            if (std.c._errno().* == @backingInt(std.c.E.INTR)) continue;
            return null;
        }
        if (n == 0) break;
        const got = buf[0..@intCast(n)];
        h.update(got);
        sink.see(off, got);
        off += got.len;
    }
    return off;
}

const NoSink = struct {
    fn see(_: NoSink, _: u64, _: []const u8) void {}
};

/// 사본의 앞 `p.hashed` 바이트가 모달 전에 잰 그것과 같은가(적대 리뷰 3 회차 M1). 읽기 오류면 null.
fn sameContent(gpa: std.mem.Allocator, fd: c_int, p: *const Prepared) !?bool {
    const buf = try gpa.alloc(u8, @intCast(@max(@as(u64, 1), @min(p.hashed, hash_chunk_bytes))));
    defer gpa.free(buf);
    var h = Sha256.init(.{});
    const got = hashFd(fd, p.hashed, buf, &h, NoSink{}) orelse return null;
    if (got != p.hashed) return false;
    const digest = h.finalResult();
    return std.mem.eql(u8, &digest, &p.digest);
}

// ── 폴더 올리기(사용자 결정 2026-11-20 「iframe·폴더 둘 다」) ──────────────────────────────────────────────────────────────────
// 사람의 폴더 고르기(`MaruAppHost.swift` `osrFolderFiles` — CEF 는 폴더 경로를 펼치지 않아 maru 가 파일들로 펼쳐 답한다)와 같은 뺄 것으로 펼친다
// (다른 점: 상한 `max_folder_files`·항목·깊이 상한, 넘길 수 없는 이름은 뺀다 — 사람의 고르개는 4096 개, 이름은 그대로. 둘을 한 자리로 모으는 일은
// docs/plans/web-osr-backend.md 「W9c③ 넓힘」 의 남은 일):
// 숨긴 것(`.` 이름·`UF_HIDDEN`)은 파일이든 폴더든 빼고, 심볼릭 링크는 따라가지 않고 빼고, 패키지(`.app` 등 — `kCFURLIsPackageKey`)는 통째로
// 빼고, 보통 파일만 남긴다. 펼치기는 파일을 열지 않는다(`fstatat(AT_SYMLINK_NOFOLLOW)` — fd 를 쥐지 않는다); 사본 단계가 파일마다 지금의
// `prepareWith` 로 열고 펼칠 때의 (장치, inode, 크기)와 같은지 본 뒤 사본을 만들고 곧 닫는다(그 사이 링크로 바꿔치기·밖으로 빠지기를 막는다).

/// 폴더 한 번에 올리는 보통 파일 수 상한(작성자 선택 — 사람의 고르개는 4096). 실제로는 사본 경로 목록이 DevTools 인자 한 번(64 KiB)에 들어가야
/// 해 이름이 보통이면 더 적다 — 사본 전에 셈한다(`folderListFits`).
pub const max_folder_files: usize = 1000;
/// 폴더 한 번의 파일 크기 합 상한(복제도 센다 — 작성자 선택: 탭의 복사 상한 `copy_cap_per_tab` 과 같은 값).
pub const max_folder_bytes: u64 = copy_cap_per_tab;
/// 훑는 항목(빼는 것까지) 상한과 깊이 상한 — 큰 나무가 작업 스레드를 오래 묶지 않게. 넘으면 통째로 실패(일부만 올리지 않는다).
pub const max_folder_entries: usize = 20_000;
pub const max_folder_depth: usize = 32;

/// 펼친 보통 파일 하나. `rel` 은 폴더 아래의 상대 경로(소유), `name` 은 그 마지막 이름(`rel` 의 조각 — 페이지가 받는 `File.name`).
pub const FolderEntry = struct {
    rel: []u8,
    dev: i32,
    ino: u64,
    size: u64,

    pub fn name(self: *const FolderEntry) []const u8 {
        const slash = std.mem.lastIndexOfScalar(u8, self.rel, '/') orelse return self.rel;
        return self.rel[slash + 1 ..];
    }
};

/// 뺀 것의 수(이름은 싣지 않는다).
pub const Skipped = struct { hidden: u32 = 0, links: u32 = 0, packages: u32 = 0, other: u32 = 0 };

pub const Folder = struct {
    /// 폴더의 실제 경로(소유 — `realpath`).
    real: []u8,
    entries: std.ArrayList(FolderEntry) = .empty,
    bytes: u64 = 0,
    skipped: Skipped = .{},

    pub fn deinit(self: *Folder, gpa: std.mem.Allocator) void {
        for (self.entries.items) |e| gpa.free(e.rel);
        self.entries.deinit(gpa);
        gpa.free(self.real);
        self.* = undefined;
    }

    /// 파일 하나의 전체 경로(`real/rel`).
    pub fn pathOf(self: *const Folder, buf: []u8, e: *const FolderEntry) ?[]const u8 {
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ self.real, e.rel }) catch null;
    }
};

/// 폴더를 펼치지 못한 까닭(앱 로그·에이전트 글 — `FolderRefusal.text`).
pub const FolderRefusal = enum {
    not_found,
    not_folder,
    unreadable,
    control_chars,
    too_many_files,
    too_large,
    too_many_entries,
    too_deep,
    empty,
    cancelled,

    pub fn text(self: FolderRefusal) []const u8 {
        return switch (self) {
            .not_found => "no such folder",
            .not_folder => "it is not a folder — give a folder with --folder, or the files without it",
            .unreadable => "cannot read the folder",
            .control_chars => "the folder's real path contains control characters",
            .too_many_files => std.fmt.comptimePrint("the folder has more than {d} files to upload (hidden files, links and packages are not counted) — upload a smaller folder", .{max_folder_files}),
            .too_large => std.fmt.comptimePrint("the files in the folder add up to more than {d} GiB — upload a smaller folder", .{max_folder_bytes >> 30}),
            .too_many_entries => std.fmt.comptimePrint("the folder has more than {d} entries — upload a smaller folder", .{max_folder_entries}),
            .too_deep => std.fmt.comptimePrint("the folder is nested more than {d} levels deep — upload a smaller folder", .{max_folder_depth}),
            .empty => "the folder has no files to upload (hidden files, links and packages inside it are skipped, as when a person picks a folder)",
            .cancelled => "the request ended",
        };
    }
};

pub const FolderResult = union(enum) { ok: Folder, refused: FolderRefusal };

const uf_hidden: u32 = 0x8000; // UF_HIDDEN — Finder 의 숨김 표지(NSURLIsHiddenKey 가 `.` 이름과 함께 본다)

extern "c" fn CFURLCreateFromFileSystemRepresentation(alloc: ?*anyopaque, buffer: [*]const u8, len: isize, is_dir: u8) ?*anyopaque;
extern "c" fn CFURLCopyResourcePropertyForKey(url: *anyopaque, key: ?*const anyopaque, value: *?*anyopaque, err: ?*?*anyopaque) u8;
extern "c" fn CFRelease(cf: *anyopaque) void;
extern "c" const kCFURLIsPackageKey: ?*const anyopaque;
extern "c" const kCFBooleanTrue: ?*const anyopaque;

/// 패키지 폴더인가(`.app`·`.bundle` 처럼 Finder 가 파일 하나로 보이는 폴더 — FileManager 의 `.skipsPackageDescendants` 가 보는 것과 같은 키).
/// 시험은 이름 끝 `.maru-pkg` 도 패키지로 본다(Mac 마다 LaunchServices 등록이 달라 시험을 고정한다).
fn isPackage(path: []const u8) bool {
    if (builtin.is_test and std.mem.endsWith(u8, path, ".maru-pkg")) return true;
    if (builtin.os.tag != .macos) return false;
    const url = CFURLCreateFromFileSystemRepresentation(null, path.ptr, @intCast(path.len), 1) orelse return false;
    defer CFRelease(url);
    var value: ?*anyopaque = null;
    if (CFURLCopyResourcePropertyForKey(url, kCFURLIsPackageKey, &value, null) == 0) return false;
    const v = value orelse return false;
    defer CFRelease(v);
    return @as(?*const anyopaque, v) == kCFBooleanTrue;
}

/// 이름이 올릴 수 있는 글인가 — 올바른 UTF-8 이고 제어 문자(C0·DEL·C1)가 없다(앱 로그·DevTools 인자·에이전트의 글에 줄바꿈 같은 글자를
/// 넣지 않게 — 명시한 파일의 실제 경로와 같은 규칙).
fn nameOk(n: []const u8) bool {
    const view = std.unicode.Utf8View.init(n) catch return false;
    var it = view.iterator();
    while (it.nextCodepoint()) |c| if (c < 0x20 or (c >= 0x7f and c <= 0x9f)) return false;
    return true;
}

fn entryLess(_: void, a: FolderEntry, b: FolderEntry) bool {
    return std.mem.lessThan(u8, a.rel, b.rel);
}

/// 폴더 하나를 펼친다(작업 스레드 — 사본 전, 파일은 열지 않는다). `stop` 이 2 가 되면(메인이 그 작업을 놓았다 — 요청이 끝났다) 곧 그만둔다.
pub fn enumerateFolder(gpa: std.mem.Allocator, path: []const u8, stop: ?*const std.atomic.Value(u8)) !FolderResult {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_z = std.fmt.bufPrintSentinel(&path_buf, "{s}", .{path}, 0) catch return .{ .refused = .not_found };
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_c = std.c.realpath(path_z.ptr, &real_buf) orelse {
        const e = std.c._errno().*;
        return .{ .refused = if (e == @backingInt(std.c.E.NOENT) or e == @backingInt(std.c.E.NOTDIR)) .not_found else .unreadable };
    };
    const real = std.mem.sliceTo(real_c, 0);
    if (!nameOk(real)) return .{ .refused = .control_chars };
    const root = std.c.open(real_c, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true, .NONBLOCK = true }, @as(std.c.mode_t, 0));
    if (root < 0) return .{ .refused = if (std.c._errno().* == @backingInt(std.c.E.NOENT)) .not_found else .unreadable };
    const st = statOf(root) orelse {
        _ = std.c.close(root);
        return .{ .refused = .unreadable };
    };
    if (st.mode & std.c.S.IFMT != std.c.S.IFDIR) {
        _ = std.c.close(root);
        return .{ .refused = .not_folder };
    }
    var folder: Folder = .{ .real = try gpa.dupe(u8, real) };
    errdefer folder.deinit(gpa);
    var walk: Walk = .{ .gpa = gpa, .folder = &folder, .stop = stop };
    var rel_buf: [std.fs.max_path_bytes]u8 = undefined;
    const why = try walk.dir(root, &rel_buf, 0, 0); // `dir` 이 root 를 닫는다
    if (why) |w| {
        folder.deinit(gpa);
        return .{ .refused = w };
    }
    if (folder.entries.items.len == 0) {
        folder.deinit(gpa);
        return .{ .refused = .empty };
    }
    std.mem.sort(FolderEntry, folder.entries.items, {}, entryLess);
    return .{ .ok = folder };
}

const Walk = struct {
    gpa: std.mem.Allocator,
    folder: *Folder,
    stop: ?*const std.atomic.Value(u8),
    seen: usize = 0,

    /// 폴더 fd 하나를 훑는다(그 fd 는 이 함수가 닫는다). `rel` 은 지금 폴더의 상대 경로(`rel_buf[0..rel_len]`). 실패 까닭이면 그것.
    fn dir(self: *Walk, fd: c_int, rel_buf: []u8, rel_len: usize, depth: usize) !?FolderRefusal {
        defer _ = std.c.close(fd);
        if (depth > max_folder_depth) return .too_deep;
        const again = std.c.dup(fd);
        if (again < 0) return .unreadable;
        const handle = std.c.fdopendir(again) orelse {
            _ = std.c.close(again);
            return .unreadable;
        };
        defer _ = std.c.closedir(handle);
        while (std.c.readdir(handle)) |entry| {
            const n = entry.name[0..@min(entry.namlen, entry.name.len)];
            if (std.mem.eql(u8, n, ".") or std.mem.eql(u8, n, "..")) continue;
            if (self.stop) |s| if (s.load(.acquire) == 2) return .cancelled;
            self.seen += 1;
            if (self.seen > max_folder_entries) return .too_many_entries;
            var nb: [1024]u8 = undefined;
            const nz = std.fmt.bufPrintSentinel(&nb, "{s}", .{n}, 0) catch {
                self.folder.skipped.other += 1;
                continue;
            };
            var est: std.c.Stat = undefined;
            if (std.c.fstatat(fd, nz.ptr, &est, std.c.AT.SYMLINK_NOFOLLOW) != 0) {
                self.folder.skipped.other += 1; // 그 사이 사라졌다·읽을 수 없다
                continue;
            }
            const fmt = est.mode & std.c.S.IFMT;
            if (fmt == std.c.S.IFLNK) {
                self.folder.skipped.links += 1;
                continue;
            }
            if (n[0] == '.' or est.flags & uf_hidden != 0) {
                self.folder.skipped.hidden += 1;
                continue;
            }
            // 넘길 수 없는 이름(제어 문자·UTF-8 아님)은 폴더든 파일이든 뺀다 — 폴더를 내려가면 그 아래 파일의 실제 경로가 사본 단계의 제어 문자
            // 검사(`prepareWith`)에 걸려 그 폴더 전체가 매번 「바뀌었다」 로 실패했다(적대 검증 5 회차 MED).
            if (!nameOk(n)) {
                self.folder.skipped.other += 1;
                continue;
            }
            // 상대 경로 = 지금 폴더 + "/" + 이름.
            const sep: usize = if (rel_len == 0) 0 else 1;
            if (rel_len + sep + n.len > rel_buf.len) {
                self.folder.skipped.other += 1;
                continue;
            }
            if (sep == 1) rel_buf[rel_len] = '/';
            @memcpy(rel_buf[rel_len + sep ..][0..n.len], n);
            const child_len = rel_len + sep + n.len;
            if (fmt == std.c.S.IFDIR) {
                var full_buf: [std.fs.max_path_bytes]u8 = undefined;
                const full = std.fmt.bufPrint(&full_buf, "{s}/{s}", .{ self.folder.real, rel_buf[0..child_len] }) catch {
                    self.folder.skipped.other += 1;
                    continue;
                };
                if (isPackage(full)) {
                    self.folder.skipped.packages += 1;
                    continue;
                }
                const sub = std.c.openat(fd, nz.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .DIRECTORY = true, .NOFOLLOW = true, .NONBLOCK = true }, @as(std.c.mode_t, 0));
                if (sub < 0) {
                    self.folder.skipped.other += 1;
                    continue;
                }
                if (try self.dir(sub, rel_buf, child_len, depth + 1)) |why| return why;
                continue;
            }
            if (fmt != std.c.S.IFREG or !nameOk(n)) {
                self.folder.skipped.other += 1; // FIFO·장치·소켓, 넘길 수 없는 이름
                continue;
            }
            // 전체 경로가 경로 상한을 넘는 파일은 폴더처럼 뺀다(사본 단계에서 열 수 없어 매번 실패했다 — 18 회차).
            if (self.folder.real.len + 1 + child_len >= std.fs.max_path_bytes) {
                self.folder.skipped.other += 1;
                continue;
            }
            if (self.folder.entries.items.len >= max_folder_files) return .too_many_files;
            const size: u64 = @intCast(@max(est.size, 0));
            self.folder.bytes +|= size;
            if (self.folder.bytes > max_folder_bytes) return .too_large;
            const rel = try self.gpa.dupe(u8, rel_buf[0..child_len]);
            self.folder.entries.append(self.gpa, .{ .rel = rel, .dev = est.dev, .ino = est.ino, .size = size }) catch |e| {
                self.gpa.free(rel);
                return e;
            };
        }
        return null;
    }
};

/// 폴더의 사본 경로 목록(`<root>/<tab>/<op>/<i>/<이름>`)과 넣은 뒤 읽기의 이름·크기 목록이 DevTools 인자 한 번(`params_cap` — 64 KiB)에 드는가.
/// 사본을 만들기 **전에** 실제 뿌리로 센다(넘으면 사본 하나 만들지 않고 실패 — 공격 A2-2). `overhead` 는 인자의 나머지(objectId·함수 본문 등).
pub fn folderListFits(folder: *const Folder, root: []const u8, tab: u64, op: u64, params_cap: usize, overhead: usize) bool {
    var paths: usize = overhead;
    var names: usize = overhead;
    var nb: [64]u8 = undefined;
    for (folder.entries.items, 0..) |*e, i| {
        const ids = (std.fmt.bufPrint(&nb, "/{d}/{d}/{d}/", .{ tab, op, i }) catch return false).len;
        const nm = jsonLen(e.name());
        paths += (jsonLen(root) - 2) + ids + nm + 1; // 따옴표 안(뿌리도 이스케이프해 센다 — 16 회차) + 쉼표
        names += nm + 1 + 21; // 이름 + 쉼표 + 크기(u64 최대 20 자리와 쉼표)
        if (paths > params_cap or names > params_cap) return false;
    }
    return true;
}

/// JSON 글로 쓴 길이(따옴표 둘 포함 — `std.json` 의 이스케이프와 같은 셈: `"`·`\\` 는 둘, 제어 문자는 `nameOk` 가 이미 막았다).
fn jsonLen(s: []const u8) usize {
    var n: usize = 2;
    for (s) |b| n += if (b == '"' or b == '\\') 2 else 1;
    return n;
}

/// 같은 파일을 두 번 적었는가(심링크·하드 링크로 다른 경로가 같은 파일 — 장치·inode). `files[i]` 와 앞의 것.
pub fn sameFileBefore(files: []const Prepared, i: usize) bool {
    for (files[0..i]) |p| if (p.dev == files[i].dev and p.ino == files[i].ino) return true;
    return false;
}

/// 사본의 뿌리 — `<base>/upload-staging` 을 만들고(0700) 정규 경로로 돌려준다(소유).
pub fn ensureRoot(gpa: std.mem.Allocator, base: []const u8) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = std.fmt.bufPrintSentinel(&buf, "{s}/upload-staging", .{base}, 0) catch return error.PathTooLong;
    if (std.c.mkdir(root.ptr, 0o700) != 0 and std.c._errno().* != @backingInt(std.c.E.EXIST)) return error.CreateFailed;
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real = std.c.realpath(root.ptr, &real_buf) orelse return error.CreateFailed;
    // 링크로 된 뿌리는 받지 않는다(남이 놓은 링크를 따라 다른 곳에 쓰지 않게) — 정규 경로의 마지막 이름이 그대로여야 한다.
    const real_s = std.mem.sliceTo(real, 0);
    if (!std.mem.endsWith(u8, real_s, "/upload-staging")) return error.CreateFailed;
    return gpa.dupe(u8, real_s);
}

pub const StageError = enum {
    changed,
    too_large,
    io,
    /// 폴더 안의 파일 하나가 펼친 뒤 바뀌었다·사라졌다·링크·보통 파일이 아닌 것으로 바뀌었다·크기가 달라졌다(통째로 실패 — 공격 A2-1).
    folder_changed,
    /// 폴더의 사본 경로 목록이 DevTools 인자 한 번에 들지 않는다(`folderListFits` — 공격 A2-2).
    folder_list_too_long,
    /// 다른 볼륨의 폴더라 복사하는데, 파일들의 합이 복사 예산(`copy_cap_per_call`·탭의 남은 몫)을 넘는다 — 폴더의 글(적대 검증 6·10 회차: 「그 파일」 을 말했다).
    folder_too_large_to_copy,
    /// 폴더 안의 파일 하나를 열 수 없다(권한·경로 길이) — 다시 해도 같다(「바뀌었다 — 다시 올려라」 로 답해 같은 실패를 되풀이하게 했다 — 적대 검증 18 회차).
    folder_unreadable,

    pub fn text(self: StageError) []const u8 {
        return switch (self) {
            .changed => "the file changed while maru was copying it — run upload again",
            .too_large => "the file is on another volume and is too large to copy (1 GiB per call, 4 GiB per tab)",
            .io => "could not make the copy the page reads",
            .folder_changed => "a file in the folder changed, disappeared or turned into something maru does not upload while maru was copying it — nothing was uploaded; run upload again",
            .folder_list_too_long => "the folder has too many files, or file names too long, for one upload — the paths of maru's copies must fit one DevTools call (64 KiB, about 400 files with short names); nothing was uploaded — upload a smaller folder",
            .folder_too_large_to_copy => "the folder is on another volume, so maru copies its files, and they add up to more than it copies at once (1 GiB per call, 4 GiB per tab) — nothing was uploaded; upload a smaller folder",
            .folder_unreadable => "a file in the folder cannot be opened for reading (its permissions, or a path too long) — nothing was uploaded; it fails the same way until that file is readable or moved out of the folder",
        };
    }
};

/// 폴더의 파일 하나의 사본(작업 스레드 — 사본 단계): 지금의 `prepareWith`(realpath·O_NOFOLLOW·정규 파일·실제 경로·해시)로 열고, 펼칠 때의
/// (장치, inode, 크기)와 같아야 사본을 만든다(펼친 뒤 그 자리나 위 폴더를 링크로 바꿔 밖의 파일을 가리켜도 다른 inode 라 걸린다). 사본의 이름은
/// 펼친 이름. fd 는 곧 닫는다(1000 개 fd 를 쥐지 않는다). 하나라도 안 되면 `folder_changed`(부른 쪽이 통째로 실패시킨다).
pub fn stageFolderEntry(gpa: std.mem.Allocator, folder: *const Folder, index: usize, root: []const u8, tab: u64, op: u64, hash_budget: *u64, copy_budget: *u64, try_clone: bool) !StageResult {
    const e = &folder.entries.items[index];
    var pb: [std.fs.max_path_bytes]u8 = undefined;
    const path = folder.pathOf(&pb, e) orelse return .{ .failed = .folder_unreadable };
    var r = try prepareWith(gpa, path, hash_budget);
    switch (r) {
        // 열 수 없다(권한·길이·이름)는 다시 해도 같다 — 그 밖(사라짐·바꿔치기·자람)은 「바뀌었다」(적대 검증 18 회차).
        .refused => |why| return .{ .failed = switch (why) {
            .unreadable, .too_long, .control_chars => .folder_unreadable,
            else => .folder_changed,
        } },
        .ok => |*p| {
            defer p.deinit(gpa);
            if (p.dev != e.dev or p.ino != e.ino or p.size != e.size) return .{ .failed = .folder_changed };
            const out = try stageFileAs(gpa, root, tab, op, index, p, e.name(), copy_budget, try_clone);
            return switch (out) {
                .ok => out,
                .failed => |why| .{ .failed = switch (why) {
                    .changed => .folder_changed,
                    .too_large => .folder_too_large_to_copy,
                    else => why,
                } },
            };
        },
    }
}

pub const StageResult = union(enum) {
    /// 사본의 정규 경로(소유).
    ok: []u8,
    failed: StageError,
};

fn mkdirOwned(path: [:0]const u8) bool {
    return std.c.mkdir(path.ptr, 0o700) == 0 or std.c._errno().* == @backingInt(std.c.E.EXIST);
}

/// 승인 뒤 — 쥔 fd 에서 `<root>/<tab>/<op>/<index>/<이름>` 으로 사본을 만든다(복제, 안 되면 복사 — `copy_budget` 안에서, 쓴 만큼 줄인다).
/// 사본 뒤 원본이 모달 때와 다르면 사본을 지우고 `changed`. 작업 스레드에서 부른다.
pub fn stageFile(gpa: std.mem.Allocator, root: []const u8, tab: u64, op: u64, index: usize, p: *const Prepared, copy_budget: *u64) !StageResult {
    return stageFileWith(gpa, root, tab, op, index, p, copy_budget, true);
}

/// `try_clone` 거짓 — 복제를 건너뛰고 복사한다(시험이 다른 볼륨의 길을 같은 볼륨에서 본다 — 앱 시험도 복사 예산을 보려고 부른다).
pub fn stageFileWith(gpa: std.mem.Allocator, root: []const u8, tab: u64, op: u64, index: usize, p: *const Prepared, copy_budget: *u64, try_clone: bool) !StageResult {
    return stageFileAs(gpa, root, tab, op, index, p, p.name(), copy_budget, try_clone);
}

/// `stageFileWith` 와 같되 사본의 이름을 준다 — 폴더의 파일은 펼칠 때의 이름(하드 링크면 `F_GETPATH` 가 다른 이름을 줄 수 있다 — 공격 A2-7).
pub fn stageFileAs(gpa: std.mem.Allocator, root: []const u8, tab: u64, op: u64, index: usize, p: *const Prepared, name: []const u8, copy_budget: *u64, try_clone: bool) !StageResult {
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    inline for (.{ "{s}/{d}", "{s}/{d}/{d}", "{s}/{d}/{d}/{d}" }, 0..) |fmt, depth| {
        const args = switch (depth) {
            0 => .{ root, tab },
            1 => .{ root, tab, op },
            else => .{ root, tab, op, index },
        };
        const d = std.fmt.bufPrintSentinel(&dir_buf, fmt, args, 0) catch return .{ .failed = .io };
        if (!mkdirOwned(d)) return .{ .failed = .io };
    }
    var dest_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dest = std.fmt.bufPrintSentinel(&dest_buf, "{s}/{d}/{d}/{d}/{s}", .{ root, tab, op, index, name }, 0) catch return .{ .failed = .io };
    var made = false;
    defer if (!made) unlinkUnlocked(dest);
    if (!try_clone or fclonefileat(p.fd, std.c.AT.FDCWD, dest.ptr, 0) != 0) {
        const e = std.c._errno().*;
        // 같은 볼륨이 아니거나(EXDEV) 복제를 모르는 파일 시스템(ENOTSUP) — 복사한다. 그 밖의 실패는 그대로.
        if (try_clone and e != @backingInt(std.c.E.XDEV) and e != @backingInt(std.c.E.OPNOTSUPP)) return .{ .failed = .io };
        if (p.size > copy_budget.*) return .{ .failed = .too_large };
        if (!try copyFromFd(p.fd, dest, p.size)) return .{ .failed = .io };
        copy_budget.* -= p.size;
    }
    // 사본은 읽기만(0400) — 페이지가 읽는 동안 바뀌지 않게.
    const out = std.c.open(dest.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, @as(std.c.mode_t, 0));
    if (out < 0) return .{ .failed = .io };
    defer _ = std.c.close(out);
    // 복제는 원본의 파일 플래그(`uchg` 등)를 옮긴다 — 풀지 않으면 0400 으로 못 바꾸고(EPERM) 지우지도 못한다(적대 리뷰 1 회차 실측: `cp -c` 의 사본이 `uchg`).
    // 잠금만 푼다 — 투명 압축(UF_COMPRESSED)은 그대로 둔다(지우면 사본이 0 바이트 — 2 회차 실측: `chflags nouchg` 는 압축을 지키고 `chflags 0` 은 비웠다).
    if (statOf(out)) |o| if (o.flags & uf_lock_flags != 0 and fchflags(out, o.flags & ~uf_lock_flags) != 0) return .{ .failed = .io };
    if (std.c.fchmod(out, 0o400) != 0) return .{ .failed = .io };
    const copied = statOf(out) orelse return .{ .failed = .io };
    // 원본이 모달 때와 같은가(장치·inode·크기·mtime·ctime) — 승인 뒤 바뀌었으면 사본이 모달과 다른 내용일 수 있다. ctime 은 같은 길이로 바꿔 쓰고
    // mtime 을 되돌려도 움직인다(사용자가 정할 수 없다). 읽기(atime)는 ctime 을 움직이지 않는다. 공유 매핑의 쓰기는 둘 다 안 움직인다 — 아래 내용 비교.
    const now = statOf(p.fd) orelse return .{ .failed = .io };
    if (now.dev != p.dev or now.ino != p.ino or now.size != @as(i64, @intCast(p.size)) or now.mtimespec.sec != p.mtime_sec or now.mtimespec.nsec != p.mtime_nsec or
        now.ctimespec.sec != p.ctime_sec or now.ctimespec.nsec != p.ctime_nsec)
        return .{ .failed = .changed };
    if (copied.size != @as(i64, @intCast(p.size))) return .{ .failed = .changed };
    // 내용 — 공유 매핑으로 쓴 것은 stat 을 움직이지 않는다(3 회차 M1 실측). 사본(복제는 이제 원본과 갈라졌다)의 앞부분이 모달 전에 잰 해시와 같아야 한다.
    if (!((try sameContent(gpa, out, p)) orelse return .{ .failed = .io })) return .{ .failed = .changed };
    made = true;
    return .{ .ok = try gpa.dupe(u8, dest) };
}

/// 지운다 — 잠금(`uchg`)이 걸려 EPERM 이면 풀고 다시(링크는 따라가지 않는다).
fn unlinkUnlocked(path: [:0]const u8) void {
    if (std.c.unlink(path.ptr) == 0) return;
    if (clearFlagsAt(std.c.AT.FDCWD, path)) _ = std.c.unlink(path.ptr);
}

/// `dir` 아래 `name` 의 잠금 플래그(`uf_lock_flags`)를 푼다(링크는 따라가지 않는다 — 다른 플래그는 그대로). 풀었으면 참 — 잠금이 없었거나 열 수
/// 없으면 거짓.
fn clearFlagsAt(dir: c_int, name: [:0]const u8) bool {
    const fd = std.c.openat(dir, name.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true, .NONBLOCK = true }, @as(std.c.mode_t, 0));
    if (fd < 0) return false;
    defer _ = std.c.close(fd);
    const st = statOf(fd) orelse return false;
    return st.flags & uf_lock_flags != 0 and fchflags(fd, st.flags & ~uf_lock_flags) == 0;
}

fn copyFromFd(src: c_int, dest: [:0]const u8, size: u64) !bool {
    const out = std.c.open(dest.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true, .NOFOLLOW = true }, @as(std.c.mode_t, 0o600));
    if (out < 0) return false;
    defer _ = std.c.close(out);
    var buf: [64 * 1024]u8 = undefined;
    var off: u64 = 0;
    while (off < size) {
        const want: usize = @intCast(@min(size - off, buf.len));
        const n = std.c.pread(src, &buf, want, @intCast(off));
        if (n < 0) {
            if (std.c._errno().* == @backingInt(std.c.E.INTR)) continue;
            return false;
        }
        if (n == 0) return false; // 짧아졌다 — 바뀐 것이다(부른 쪽의 비교가 아니라 여기서 멈춘다)
        var done: usize = 0;
        const got: usize = @intCast(n);
        while (done < got) {
            const w = std.c.write(out, buf[done..].ptr, got - done);
            if (w < 0) {
                if (std.c._errno().* == @backingInt(std.c.E.INTR)) continue;
                return false;
            }
            done += @intCast(w);
        }
        off += got;
    }
    return true;
}

/// `<root>/<sub>` 를 지운다(링크를 따라가지 않는다 — 폴더는 `O_NOFOLLOW|O_DIRECTORY` 로 열어 그 안을 지운다). 없으면 그냥 끝.
pub fn removeUnder(root: []const u8, sub: []const u8) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_z = std.fmt.bufPrintSentinel(&buf, "{s}", .{root}, 0) catch return;
    const dir = std.c.open(root_z.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .DIRECTORY = true, .NOFOLLOW = true }, @as(std.c.mode_t, 0));
    if (dir < 0) return;
    defer _ = std.c.close(dir);
    var name_buf: [1024]u8 = undefined;
    const name = std.fmt.bufPrintSentinel(&name_buf, "{s}", .{sub}, 0) catch return;
    removeAt(dir, name, 0);
}

/// 뿌리 전체를 지운다(이 실행이 처음 프로필을 잡을 때 — 지난 실행이 남긴 사본).
pub fn wipeRoot(base: []const u8) void {
    removeUnder(base, "upload-staging");
}

fn removeAt(dir: c_int, name: [:0]const u8, depth: u8) void {
    if (std.c.unlinkat(dir, name.ptr, 0) == 0) return;
    // 잠긴(`uchg`) 항목 — 풀고 다시(폴더면 플래그만 풀리고 아래에서 비운 뒤 지운다). 복제가 원본의 잠금을 옮겨 왔을 수 있다(적대 리뷰 1 회차).
    if (clearFlagsAt(dir, name) and std.c.unlinkat(dir, name.ptr, 0) == 0) return;
    if (depth >= 8) return; // 우리가 만드는 깊이는 넷이다 — 남이 만든 깊은 나무를 끝없이 내려가지 않는다
    const sub = std.c.openat(dir, name.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .DIRECTORY = true, .NOFOLLOW = true }, @as(std.c.mode_t, 0));
    if (sub < 0) return;
    // 지운 것이 있으면 다시 돈다 — 순회하며 지우면 항목을 건너뛸 수 있다(다운로드 사본 지우기와 같은 까닭).
    var pass: u8 = 0;
    while (pass < 4) : (pass += 1) {
        const again = std.c.dup(sub);
        if (again < 0) break;
        const handle = std.c.fdopendir(again) orelse {
            _ = std.c.close(again);
            break;
        };
        var removed: usize = 0;
        while (std.c.readdir(handle)) |entry| {
            const n = entry.name[0..@min(entry.namlen, entry.name.len)];
            if (std.mem.eql(u8, n, ".") or std.mem.eql(u8, n, "..")) continue;
            // 이름은 255 바이트를 넘을 수 있다(HFS+·APFS 는 글자 수로 센다 — 한글 86 자면 넘는다; 공격 A2-11: 256 칸이면 그런 사본이 남았다).
            var nb: [1024]u8 = undefined;
            const nz = std.fmt.bufPrintSentinel(&nb, "{s}", .{n}, 0) catch continue;
            removeAt(sub, nz, depth + 1);
            removed += 1;
        }
        _ = std.c.closedir(handle);
        if (removed == 0) break;
    }
    _ = std.c.close(sub);
    _ = std.c.unlinkat(dir, name.ptr, std.c.AT.REMOVEDIR);
}

// ── 시험 ──────────────────────────────────────────────────────────────────────────────────────────────────
// 임시 폴더에서 실제 파일 시스템으로 본다 — 모달이 보인 파일과 페이지가 받는 바이트가 같은가(링크 바꾸기·폴더·FIFO·장치·바뀐 원본),
// 사본의 자리와 권한, 지우기.

const testing = std.testing;

extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;

/// 경로의 stat(링크를 따라가지 않는다 — 폴더도 연다). 없으면 null.
fn statPath(path: [*:0]const u8) ?std.c.Stat {
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true, .NONBLOCK = true }, @as(std.c.mode_t, 0));
    if (fd < 0) return null;
    defer _ = std.c.close(fd);
    return statOf(fd);
}
extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;

const Tmp = struct {
    path: [:0]u8,

    fn init() !Tmp {
        var tmpl_buf: [std.fs.max_path_bytes]u8 = undefined;
        const base = std.c.getenv("TMPDIR");
        const tmpl = try std.fmt.bufPrintSentinel(&tmpl_buf, "{s}/maru-upload-XXXXXX", .{if (base) |b| std.mem.trimEnd(u8, std.mem.span(b), "/") else "/tmp"}, 0);
        const made = mkdtemp(tmpl.ptr) orelse return error.TempFailed;
        var real_buf: [std.fs.max_path_bytes]u8 = undefined;
        const real = std.c.realpath(made, &real_buf) orelse return error.TempFailed;
        return .{ .path = try testing.allocator.dupeSentinel(u8, std.mem.sliceTo(real, 0), 0) };
    }

    fn deinit(self: *Tmp) void {
        const slash = std.mem.lastIndexOfScalar(u8, self.path, '/').?;
        removeUnder(self.path[0..slash], self.path[slash + 1 ..]);
        testing.allocator.free(self.path);
    }

    fn join(self: *const Tmp, buf: []u8, name: []const u8) [:0]u8 {
        return std.fmt.bufPrintSentinel(buf, "{s}/{s}", .{ self.path, name }, 0) catch unreachable;
    }

    fn write(self: *const Tmp, name: []const u8, bytes: []const u8) !void {
        var b: [std.fs.max_path_bytes]u8 = undefined;
        const p = self.join(&b, name);
        const fd = std.c.open(p.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
        if (fd < 0) return error.WriteFailed;
        defer _ = std.c.close(fd);
        if (std.c.write(fd, bytes.ptr, bytes.len) != @as(isize, @intCast(bytes.len))) return error.WriteFailed;
    }
};

fn expectRefused(r: PrepareResult, want: Refusal) !void {
    switch (r) {
        .refused => |got| try testing.expectEqual(want, got),
        .ok => |p| {
            var m = p;
            m.deinit(testing.allocator);
            return error.TestUnexpectedResult;
        },
    }
}

test "W9c③ 열기: 링크는 실제 경로로(모달이 보이는 것), 폴더·FIFO·장치는 거절(FIFO 는 멈추지 않는다), 없는 파일·제어 문자 실제 경로도 거절" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var t = try Tmp.init();
    defer t.deinit();
    try t.write("a.txt", "hello\n");
    var b1: [std.fs.max_path_bytes]u8 = undefined;
    var b2: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqual(@as(c_int, 0), std.c.symlink(t.join(&b1, "a.txt").ptr, t.join(&b2, "link.txt").ptr));
    {
        var r = try prepare(testing.allocator, t.join(&b1, "link.txt"));
        defer r.ok.deinit(testing.allocator);
        try testing.expectEqualStrings(t.join(&b2, "a.txt"), r.ok.real);
        try testing.expectEqualStrings("a.txt", r.ok.name());
        try testing.expectEqual(@as(u64, 6), r.ok.size);
        try testing.expectEqualStrings("hello\n", r.ok.head);
    }
    try testing.expectEqual(@as(c_int, 0), std.c.mkdir(t.join(&b1, "d").ptr, 0o700));
    try expectRefused(try prepare(testing.allocator, t.join(&b1, "d")), .is_folder);
    try testing.expectEqual(@as(c_int, 0), mkfifo(t.join(&b1, "fifo").ptr, 0o600));
    try expectRefused(try prepare(testing.allocator, t.join(&b1, "fifo")), .not_regular); // 쓰는 쪽이 없어도 돌아온다(O_NONBLOCK)
    try expectRefused(try prepare(testing.allocator, "/dev/zero"), .not_regular);
    try expectRefused(try prepare(testing.allocator, "/dev/null"), .not_regular);
    try expectRefused(try prepare(testing.allocator, t.join(&b1, "none.txt")), .not_found);
    // 링크가 줄바꿈 이름을 가리킨다 — 요청 경로에는 제어 문자가 없어도 실제 경로에 있다.
    try t.write("line1\nline2.txt", "x");
    try testing.expectEqual(@as(c_int, 0), std.c.symlink(t.join(&b1, "line1\nline2.txt").ptr, t.join(&b2, "nl.txt").ptr));
    try expectRefused(try prepare(testing.allocator, t.join(&b1, "nl.txt")), .control_chars);
}

test "W9c③ 열기: 하드 링크는 링크 수가, 같은 파일을 두 이름으로 적으면 sameFileBefore 가 알아본다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var t = try Tmp.init();
    defer t.deinit();
    try t.write("a.txt", "a");
    var b1: [std.fs.max_path_bytes]u8 = undefined;
    var b2: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqual(@as(c_int, 0), std.c.link(t.join(&b1, "a.txt").ptr, t.join(&b2, "hard.txt").ptr));
    var files: [2]Prepared = .{ (try prepare(testing.allocator, t.join(&b1, "a.txt"))).ok, (try prepare(testing.allocator, t.join(&b1, "hard.txt"))).ok };
    defer for (&files) |*f| f.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 2), files[0].nlink);
    try testing.expect(!sameFileBefore(&files, 0));
    try testing.expect(sameFileBefore(&files, 1));
}

test "W9c③ 사본: 쥔 fd 에서 <뿌리>/<탭>/<op>/<i>/<이름> 으로, 폴더 0700·파일 0400, 승인 뒤 원본을 바꾸거나 링크를 바꿔도 사본은 모달 때의 것" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var t = try Tmp.init();
    defer t.deinit();
    try t.write("a.txt", "AAAA");
    var b1: [std.fs.max_path_bytes]u8 = undefined;
    var b2: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqual(@as(c_int, 0), std.c.symlink(t.join(&b1, "a.txt").ptr, t.join(&b2, "link.txt").ptr));
    const root = try ensureRoot(testing.allocator, t.path);
    defer testing.allocator.free(root);
    try testing.expect(std.mem.startsWith(u8, root, t.path));
    var p = (try prepare(testing.allocator, t.join(&b1, "link.txt"))).ok;
    defer p.deinit(testing.allocator);
    // 승인 뒤 링크를 같은 크기의 다른 파일로 바꾼다(실측 k9c — 원본 경로를 넘기면 페이지가 BBBB 를 읽었다).
    try t.write("b.txt", "BBBB");
    _ = std.c.unlink(t.join(&b1, "link.txt").ptr);
    try testing.expectEqual(@as(c_int, 0), std.c.symlink(t.join(&b1, "b.txt").ptr, t.join(&b2, "link.txt").ptr));
    var budget: u64 = copy_cap_per_call;
    const r = try stageFile(testing.allocator, root, 7, 42, 0, &p, &budget);
    const staged = r.ok;
    defer testing.allocator.free(staged);
    var want_buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings(try std.fmt.bufPrint(&want_buf, "{s}/7/42/0/a.txt", .{root}), staged);
    var zb: [std.fs.max_path_bytes]u8 = undefined;
    const z = try std.fmt.bufPrintSentinel(&zb, "{s}", .{staged}, 0);
    const sfd = std.c.open(z.ptr, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    defer _ = std.c.close(sfd);
    var got: [8]u8 = undefined;
    try testing.expectEqual(@as(isize, 4), std.c.read(sfd, &got, got.len));
    try testing.expectEqualStrings("AAAA", got[0..4]);
    const st = statOf(sfd).?;
    try testing.expectEqual(@as(u16, 0o400), st.mode & 0o777);
    inline for (.{ "{s}/7", "{s}/7/42", "{s}/7/42/0" }) |fmt| {
        var db: [std.fs.max_path_bytes]u8 = undefined;
        const d = try std.fmt.bufPrintSentinel(&db, fmt, .{root}, 0);
        const dst = statPath(d.ptr) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(@as(u16, 0o700), dst.mode & 0o777);
    }
    // 같은 볼륨이라 복제였다 — 복사 예산을 쓰지 않았다.
    try testing.expectEqual(copy_cap_per_call, budget);
    // 탭의 폴더를 지우면 그 아래가 다 사라진다(0400 파일도).
    removeUnder(root, "7");
    try testing.expect(statPath(z.ptr) == null);
}

test "W9c③ 사본: 모달 뒤 원본이 바뀌었으면(크기·mtime) 사본을 지우고 changed" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var t = try Tmp.init();
    defer t.deinit();
    try t.write("a.txt", "AAAA");
    var b1: [std.fs.max_path_bytes]u8 = undefined;
    const root = try ensureRoot(testing.allocator, t.path);
    defer testing.allocator.free(root);
    var p = (try prepare(testing.allocator, t.join(&b1, "a.txt"))).ok;
    defer p.deinit(testing.allocator);
    // 같은 파일(inode)을 덧붙여 바꾼다.
    const fd = std.c.open(t.join(&b1, "a.txt").ptr, .{ .ACCMODE = .WRONLY, .APPEND = true }, @as(std.c.mode_t, 0));
    _ = std.c.write(fd, "more", 4);
    _ = std.c.close(fd);
    var budget: u64 = copy_cap_per_call;
    const r = try stageFile(testing.allocator, root, 1, 2, 0, &p, &budget);
    try testing.expectEqual(StageError.changed, r.failed);
    var db: [std.fs.max_path_bytes]u8 = undefined;
    const d = try std.fmt.bufPrintSentinel(&db, "{s}/1/2/0/a.txt", .{root}, 0);
    try testing.expect(statPath(d.ptr) == null); // 사본은 지웠다
}

test "W9c③ 사본: 복사(다른 볼륨의 길)는 예산 안에서만 — 예산을 넘는 파일은 too_large, 쓴 만큼 예산이 준다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var t = try Tmp.init();
    defer t.deinit();
    try t.write("a.txt", "0123456789");
    var b1: [std.fs.max_path_bytes]u8 = undefined;
    var p = (try prepare(testing.allocator, t.join(&b1, "a.txt"))).ok;
    defer p.deinit(testing.allocator);
    var db: [std.fs.max_path_bytes]u8 = undefined;
    const dest = try std.fmt.bufPrintSentinel(&db, "{s}/copy.txt", .{t.path}, 0);
    try testing.expect(try copyFromFd(p.fd, dest, p.size));
    const sfd = std.c.open(dest.ptr, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    defer _ = std.c.close(sfd);
    var got: [16]u8 = undefined;
    try testing.expectEqual(@as(isize, 10), std.c.read(sfd, &got, got.len));
    try testing.expectEqualStrings("0123456789", got[0..10]);
    // stageFile 의 복사 길: 예산이 크기보다 작으면 too_large(사본을 만들지 않는다), 넉넉하면 복사하고 쓴 만큼 준다.
    const root = try ensureRoot(testing.allocator, t.path);
    defer testing.allocator.free(root);
    var small: u64 = 9;
    try testing.expectEqual(StageError.too_large, (try stageFileWith(testing.allocator, root, 3, 4, 0, &p, &small, false)).failed);
    try testing.expectEqual(@as(u64, 9), small);
    var big: u64 = 25;
    const ok = (try stageFileWith(testing.allocator, root, 3, 5, 0, &p, &big, false)).ok;
    defer testing.allocator.free(ok);
    try testing.expectEqual(@as(u64, 15), big);
    // 원본이 그사이 짧아졌으면 복사가 멈춘다.
    var db2: [std.fs.max_path_bytes]u8 = undefined;
    const dest2 = try std.fmt.bufPrintSentinel(&db2, "{s}/copy2.txt", .{t.path}, 0);
    try testing.expect(!try copyFromFd(p.fd, dest2, p.size + 5));
}

test "W9c③ 지우기: wipeRoot 는 upload-staging 전체를 지우고, 링크를 따라 밖을 지우지 않는다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var t = try Tmp.init();
    defer t.deinit();
    try t.write("outside.txt", "keep");
    const root = try ensureRoot(testing.allocator, t.path);
    defer testing.allocator.free(root);
    var b1: [std.fs.max_path_bytes]u8 = undefined;
    var b2: [std.fs.max_path_bytes]u8 = undefined;
    const inner = try std.fmt.bufPrintSentinel(&b2, "{s}/9", .{root}, 0);
    try testing.expectEqual(@as(c_int, 0), std.c.mkdir(inner.ptr, 0o700));
    var lb: [std.fs.max_path_bytes]u8 = undefined;
    const link = try std.fmt.bufPrintSentinel(&lb, "{s}/9/out", .{root}, 0);
    try testing.expectEqual(@as(c_int, 0), std.c.symlink(t.path.ptr, link.ptr));
    wipeRoot(t.path);
    var rb: [std.fs.max_path_bytes]u8 = undefined;
    const rz = try std.fmt.bufPrintSentinel(&rb, "{s}", .{root}, 0);
    try testing.expect(statPath(rz.ptr) == null);
    try testing.expect(statPath(t.join(&b1, "outside.txt").ptr) != null);
}

// ── W9c③ 적대 리뷰 1 회차 ─────────────────────────────────────────────────────────────────────────────────────

extern "c" fn futimens(fd: c_int, times: *const [2]std.c.timespec) c_int;
extern "c" fn chflags(path: [*:0]const u8, flags: c_uint) c_int;
const uf_immutable: c_uint = 0x2; // UF_IMMUTABLE — Finder 의 「잠금」(`chflags uchg`)

test "W9c③ 적대 리뷰 1 회차 재현 R1: 모달 동안 같은 길이로 제자리에서 바꿔 쓰고 mtime 을 되돌려도(futimens) 사본은 changed 로 실패한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var t = try Tmp.init();
    defer t.deinit();
    try t.write("a.txt", "meow meow meow\n");
    var b1: [std.fs.max_path_bytes]u8 = undefined;
    const root = try ensureRoot(testing.allocator, t.path);
    defer testing.allocator.free(root);
    var p = (try prepare(testing.allocator, t.join(&b1, "a.txt"))).ok;
    defer p.deinit(testing.allocator);
    // 에이전트가 같은 inode·같은 길이로 비밀을 써 넣고 mtime(과 atime)을 모달 때의 값으로 되돌린다 — 사용자는 바꿀 수 없는 ctime 만 움직인다.
    const fd = std.c.open(t.join(&b1, "a.txt").ptr, .{ .ACCMODE = .WRONLY }, @as(std.c.mode_t, 0));
    try testing.expect(fd >= 0);
    defer _ = std.c.close(fd);
    try testing.expectEqual(@as(isize, 15), std.c.pwrite(fd, "SECRET-KEY-DATA", 15, 0));
    const times = [2]std.c.timespec{ .{ .sec = p.mtime_sec, .nsec = p.mtime_nsec }, .{ .sec = p.mtime_sec, .nsec = p.mtime_nsec } };
    try testing.expectEqual(@as(c_int, 0), futimens(fd, &times));
    var budget: u64 = copy_cap_per_call;
    const r = try stageFile(testing.allocator, root, 1, 2, 0, &p, &budget);
    if (r == .ok) testing.allocator.free(r.ok);
    try testing.expect(r == .failed and r.failed == .changed);
}

test "W9c③ 적대 리뷰 1 회차 재현 R2: Finder 로 잠근(uchg) 원본도 사본이 되고(복제가 잠금을 옮겨도 사본에서 푼다), 사본은 지울 수 있다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var t = try Tmp.init();
    defer t.deinit();
    try t.write("locked.txt", "LOCK");
    var b1: [std.fs.max_path_bytes]u8 = undefined;
    const src = t.join(&b1, "locked.txt");
    try testing.expectEqual(@as(c_int, 0), chflags(src.ptr, uf_immutable));
    defer _ = chflags(src.ptr, 0); // 시험 폴더를 지울 수 있게
    const root = try ensureRoot(testing.allocator, t.path);
    defer testing.allocator.free(root);
    var p = (try prepare(testing.allocator, src)).ok;
    defer p.deinit(testing.allocator);
    var budget: u64 = copy_cap_per_call;
    const r = try stageFile(testing.allocator, root, 7, 8, 0, &p, &budget);
    var zb: [std.fs.max_path_bytes]u8 = undefined;
    const staged_z = try std.fmt.bufPrintSentinel(&zb, "{s}/7/8/0/locked.txt", .{root}, 0);
    // 실패했어도 남은 것을 풀어 시험 폴더를 지울 수 있게 한다(고치기 전 — 잠긴 사본이 남았다).
    defer _ = chflags(staged_z.ptr, 0);
    switch (r) {
        .ok => |path| testing.allocator.free(path),
        .failed => return error.TestUnexpectedResult,
    }
    const st = statPath(staged_z.ptr) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 0), @as(u32, st.flags) & uf_immutable);
    try testing.expectEqual(@as(u16, 0o400), st.mode & 0o777);
    // 탭이 닫히면 지운다 — 잠긴 것이 남으면 안 된다.
    removeUnder(root, "7");
    try testing.expect(statPath(staged_z.ptr) == null);
}

test "W9c③ 적대 리뷰 1 회차 재현 R2b: 지우기는 잠금(uchg)이 걸린 항목도 풀고 지운다(남이 놓은 잠긴 사본이 탭 폴더를 못 지우게 하지 않는다)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var t = try Tmp.init();
    defer t.deinit();
    const root = try ensureRoot(testing.allocator, t.path);
    defer testing.allocator.free(root);
    var db: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqual(@as(c_int, 0), std.c.mkdir((try std.fmt.bufPrintSentinel(&db, "{s}/5", .{root}, 0)).ptr, 0o700));
    var fb: [std.fs.max_path_bytes]u8 = undefined;
    const f = try std.fmt.bufPrintSentinel(&fb, "{s}/5/x.txt", .{root}, 0);
    const fd = std.c.open(f.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true }, @as(std.c.mode_t, 0o400));
    try testing.expect(fd >= 0);
    _ = std.c.close(fd);
    try testing.expectEqual(@as(c_int, 0), chflags(f.ptr, uf_immutable));
    defer _ = chflags(f.ptr, 0);
    removeUnder(root, "5");
    try testing.expect(statPath(f.ptr) == null);
}

test "W9c③ 적대 리뷰 1 회차 재현 R6: 유닉스 소켓은 「정규 파일이 아니다」(EOPNOTSUPP 102 — zig 의 E.OPNOTSUPP 는 45 라 「열 수 없다」 로 샜다)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var t = try Tmp.init();
    defer t.deinit();
    var b1: [std.fs.max_path_bytes]u8 = undefined;
    const path = t.join(&b1, "s.sock");
    const sock = std.c.socket(std.c.AF.UNIX, std.c.SOCK.STREAM, 0);
    try testing.expect(sock >= 0);
    defer _ = std.c.close(sock);
    var addr: std.c.sockaddr.un = .{ .path = undefined };
    @memset(&addr.path, 0);
    if (path.len >= addr.path.len) return error.SkipZigTest; // 임시 폴더 경로가 너무 길다
    @memcpy(addr.path[0..path.len], path);
    try testing.expectEqual(@as(c_int, 0), std.c.bind(sock, @ptrCast(&addr), @sizeOf(std.c.sockaddr.un)));
    try expectRefused(try prepare(testing.allocator, path), .not_regular);
}

// ── W9c③ 적대 리뷰 2 회차 ──
const uf_compressed: c_uint = 0x20; // UF_COMPRESSED — 투명 압축(decmpfs: `ditto --hfsCompression`, 앱 번들·설치 프로그램이 깐 파일)

// 실측(셸): `ditto --hfsCompression` 한 46000 바이트 파일을 `cp -c`(복제) → 사본도 `compressed` → `chflags 0` 하면 사본이 **0 바이트**가 된다
// (데이터는 리소스 포크 xattr 에 있고 UF_COMPRESSED 를 지우면 그 해석을 잃는다). 고치기 전 `stageFile` 은 복제 뒤 `fchflags(out, 0)` 로 플래그를
// 다 풀었다(1 회차 uchg 고침) — 투명 압축된 원본은 사본 크기가 0 이 되어 늘 「the file changed after the user approved it — run upload again」
// 이었다(다시 해도 같다). 잠금만 풀면 압축은 남는다 — 잠기고 압축된 원본(`uchg,compressed`)도 보고, 그 원본을 지우는 길(`clearFlagsAt`)도 본다.
test "W9c③ 적대 리뷰 2 회차 재현 S1: 투명 압축(UF_COMPRESSED) 원본도 같은 볼륨 복제로 같은 바이트의 사본이 된다 — 잠겨 있어도, 잠금만 풀고 압축은 둔다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    // `ditto` 를 띄우는 것은 이 시험뿐이다 — 선언을 시험 안에 둔다(앱 코드의 spawn 축 판정자는 시험 몸을 세지 않는다).
    const libc = struct {
        extern "c" fn system(cmd: [*:0]const u8) c_int;
    };
    var t = try Tmp.init();
    defer t.deinit();
    var body: [46000]u8 = undefined;
    for (&body, 0..) |*b, i| b.* = "hello compressed world\n"[i % 23];
    try t.write("plain.txt", &body);
    var cmd_buf: [3 * std.fs.max_path_bytes]u8 = undefined;
    const cmd = try std.fmt.bufPrintSentinel(&cmd_buf, "/usr/bin/ditto --hfsCompression '{s}/plain.txt' '{s}/comp.txt'", .{ t.path, t.path }, 0);
    try testing.expectEqual(@as(c_int, 0), libc.system(cmd.ptr));
    var b1: [std.fs.max_path_bytes]u8 = undefined;
    const src = t.join(&b1, "comp.txt");
    const sst = statPath(src.ptr) orelse return error.TestUnexpectedResult;
    if (@as(u32, sst.flags) & uf_compressed == 0) return error.SkipZigTest; // 이 볼륨이 압축하지 않았다
    const root = try ensureRoot(testing.allocator, t.path);
    defer testing.allocator.free(root);
    // 0: 압축만. 1: 압축에 Finder 잠금(`uchg`)까지.
    for (0..2) |index| {
        if (index == 1) {
            const fd = std.c.open(src.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, @as(std.c.mode_t, 0));
            try testing.expect(fd >= 0);
            defer _ = std.c.close(fd);
            const st = statOf(fd) orelse return error.TestUnexpectedResult;
            try testing.expectEqual(@as(c_int, 0), fchflags(fd, st.flags | 0x2)); // uchg(UF_IMMUTABLE) — 압축은 그대로
        }
        var p = (try prepare(testing.allocator, src)).ok;
        defer p.deinit(testing.allocator);
        var budget: u64 = copy_cap_per_call;
        const r = try stageFile(testing.allocator, root, 3, 4, index, &p, &budget);
        switch (r) {
            .ok => |path| testing.allocator.free(path),
            .failed => |e| {
                std.debug.print("S1: stageFile failed: {s}\n", .{@tagName(e)});
                return error.TestUnexpectedResult;
            },
        }
        try testing.expectEqual(copy_cap_per_call, budget); // 복제였다(복사 예산을 쓰지 않았다)
        var zb: [std.fs.max_path_bytes]u8 = undefined;
        const staged_z = try std.fmt.bufPrintSentinel(&zb, "{s}/3/4/{d}/comp.txt", .{ root, index }, 0);
        const st = statPath(staged_z.ptr) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(@as(i64, 46000), st.size);
        try testing.expectEqual(@as(u32, 0), @as(u32, st.flags) & uf_lock_flags); // 잠금은 풀렸다
        // 바이트가 원본과 같다(압축의 해석을 잃지 않았다).
        const fd = std.c.open(staged_z.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, @as(std.c.mode_t, 0));
        try testing.expect(fd >= 0);
        defer _ = std.c.close(fd);
        var got: [46000]u8 = undefined;
        try testing.expectEqual(@as(isize, got.len), std.c.pread(fd, &got, got.len, 0));
        try testing.expectEqualSlices(u8, &body, &got);
    }
    // 잠긴 원본을 지우는 길 — 잠금만 풀고 지운다.
    removeUnder(t.path, "comp.txt");
    try testing.expect(statPath(src.ptr) == null);
}

/// 시험 P1 의 흉내 — 엿보기 뒤에 파일을 바꾼다(첫 바이트를 「b」 로, 끝에 한 바이트 — 크기가 늘어 ctime 도 반드시 움직인다). `changes_left` 번만.
const PeekChanger = struct {
    var path: [:0]const u8 = "";
    var changes_left: usize = 0;
    var calls: usize = 0;

    fn hook(_: c_int) void {
        calls += 1;
        if (changes_left == 0) return;
        changes_left -= 1;
        const fd = std.c.open(path.ptr, .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, @as(std.c.mode_t, 0));
        if (fd < 0) return;
        defer _ = std.c.close(fd);
        _ = std.c.pwrite(fd, "b", 1, 0);
        const st = statOf(fd) orelse return;
        _ = std.c.pwrite(fd, "z", 1, st.size);
    }
};

// dataless 파일(iCloud 최적화·Dropbox 온라인 전용)은 엿보기 읽기가 내려받아 채우며 ctime 을 바꾼다 — 읽기 **앞의** stat 하나로 적으면 승인 뒤 사본의
// 비교가 늘 「changed」 였다(사용자는 모달을 두 번 본다). 실제 dataless 파일은 계정이 있어야 만들 수 있어, 엿보기와 두 번째 stat 사이에 파일을
// 바꾸는 것으로 흉내 낸다.
test "W9c③ 적대 리뷰 2 회차 재현 P1: 엿보기 읽기 사이에 파일이 한 번 바뀌면(dataless 가 내려받아진다) 다시 읽어 두 번째 상태로 적는다 — 사본이 「changed」 가 아니다, 계속 바뀌면 거절" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var t = try Tmp.init();
    defer t.deinit();
    try t.write("cloud.txt", "aaaa");
    var b1: [std.fs.max_path_bytes]u8 = undefined;
    const src = t.join(&b1, "cloud.txt");
    PeekChanger.path = src;
    test_after_peek = &PeekChanger.hook;
    defer test_after_peek = null;

    // 한 번 바뀐다 → 두 번째 읽기의 상태와 엿보기(「baaaz」).
    PeekChanger.changes_left = 1;
    PeekChanger.calls = 0;
    var p = switch (try prepare(testing.allocator, src)) {
        .ok => |x| x,
        .refused => |why| {
            std.debug.print("P1: refused: {s}\n", .{@tagName(why)});
            return error.TestUnexpectedResult;
        },
    };
    defer p.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), PeekChanger.calls);
    try testing.expectEqual(@as(u64, 5), p.size);
    try testing.expectEqualStrings("baaaz", p.head);
    const root = try ensureRoot(testing.allocator, t.path);
    defer testing.allocator.free(root);
    var budget: u64 = copy_cap_per_call;
    switch (try stageFile(testing.allocator, root, 1, 1, 0, &p, &budget)) {
        .ok => |path| testing.allocator.free(path),
        .failed => |e| {
            std.debug.print("P1: stageFile failed: {s}\n", .{@tagName(e)});
            return error.TestUnexpectedResult;
        },
    }

    // 읽을 때마다 바뀐다 → 정할 수 없다(두 번까지만 읽는다).
    PeekChanger.changes_left = 5;
    PeekChanger.calls = 0;
    try expectRefused(try prepare(testing.allocator, src), .unsteady);
    try testing.expectEqual(@as(usize, 2), PeekChanger.calls);

    // 바뀌지 않으면 한 번만 읽는다.
    PeekChanger.changes_left = 0;
    PeekChanger.calls = 0;
    var q = (try prepare(testing.allocator, src)).ok;
    q.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), PeekChanger.calls);
}

// ── W9c③ 적대 리뷰 3 회차 ──
// 1 회차 R1 의 ctime 비교는 `write`·`futimens` 를 잡지만 **공유 매핑(MAP_SHARED)으로 쓴 것**은 잡지 못한다: macOS 는 그 쓰기에 mtime·ctime 을
// msync 전까지 움직이지 않고, 복제(`fclonefileat`)·복사(`pread`)는 바뀐 바이트를 가져간다(실측 review_w9c3_r3/exp/mm.c — 2 초 기다려도, 복제 뒤에도
// ctime 그대로, 사본은 바뀐 내용). 같은 uid 의 에이전트가 모달이 뜬 뒤(엿보기를 읽은 뒤) 자기 파일을 그렇게 바꾸면 모달의 엿보기(첫 줄)와 페이지가
// 받는 바이트가 달랐다 — 「모달이 보인 파일과 페이지가 받는 바이트가 같아야 한다」 가 깨졌다. 고친 뒤: 모달 전의 읽기로 낸 SHA-256 과 사본의 것이
// 다르면 `changed`(복제·복사 둘 다).
test "W9c③ 적대 리뷰 3 회차 재현 M1: 엿보기를 읽은 뒤 공유 매핑으로 같은 길이로 바꿔 써도(msync 없음 — ctime 그대로) 사본은 changed 다(복제·복사 둘 다)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var t = try Tmp.init();
    defer t.deinit();
    const benign = "Quarterly report: all good.\n";
    try t.write("report.txt", benign);
    var b1: [std.fs.max_path_bytes]u8 = undefined;
    const src = t.join(&b1, "report.txt");
    var p = (try prepare(testing.allocator, src)).ok;
    defer p.deinit(testing.allocator);
    try testing.expectEqualStrings(benign, p.head);
    try testing.expectEqual(@as(u64, benign.len), p.hashed);
    // 모달이 떠 있는 동안 — 같은 uid 의 다른 프로세스가 공유 매핑으로 바꿔 쓴다(크기 그대로, msync·futimens 없음).
    const rw = std.c.open(src.ptr, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, @as(std.c.mode_t, 0));
    try testing.expect(rw >= 0);
    defer _ = std.c.close(rw);
    const m = try std.posix.mmap(null, benign.len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, rw, 0);
    defer std.posix.munmap(m);
    const secret = "-----BEGIN OPENSSH PRIVATE KEY-----\n";
    @memset(m, 'X');
    @memcpy(m[0..@min(secret.len, m.len)], secret[0..@min(secret.len, m.len)]);
    // stat 은 그대로다(그래서 1 회차의 비교로는 몰랐다) — 이 시험이 보는 길이 아직 그 길인지 먼저 본다.
    const st = statOf(p.fd).?;
    try testing.expect(st.ctimespec.sec == p.ctime_sec and st.ctimespec.nsec == p.ctime_nsec and st.mtimespec.nsec == p.mtime_nsec);
    const root = try ensureRoot(testing.allocator, t.path);
    defer testing.allocator.free(root);
    for ([_]bool{ true, false }) |clone| {
        var budget: u64 = copy_cap_per_call;
        const r = try stageFileWith(testing.allocator, root, 1, if (clone) 1 else 2, 0, &p, &budget, clone);
        if (r == .ok) {
            defer testing.allocator.free(r.ok);
            std.debug.print("M1 ({s}): staged ok although the file changed through a shared mapping\n", .{if (clone) "clone" else "copy"});
            return error.TestUnexpectedResult;
        }
        try testing.expectEqual(StageError.changed, r.failed);
        var db: [std.fs.max_path_bytes]u8 = undefined;
        const d = try std.fmt.bufPrintSentinel(&db, "{s}/1/{d}/0/report.txt", .{ root, @as(u8, if (clone) 1 else 2) }, 0);
        try testing.expect(statPath(d.ptr) == null); // 사본은 지웠다
    }
}

test "W9c③ 적대 리뷰 3 회차: 내용 해시는 호출의 예산(1 GiB) 안에서 — 넘은 파일은 엿보기만큼 재고, 여러 조각의 파일도 바뀌지 않았으면 사본이 된다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var t = try Tmp.init();
    defer t.deinit();
    // 조각(1 MiB)보다 큰 파일 — 해시가 여러 번 읽어도 사본의 해시와 같다.
    const big = try testing.allocator.alloc(u8, 3 * hash_chunk_bytes + 17);
    defer testing.allocator.free(big);
    for (big, 0..) |*b, i| b.* = @truncate(i *% 31 +% 7);
    try t.write("big.bin", big);
    try t.write("small.txt", "small file\n");
    var b1: [std.fs.max_path_bytes]u8 = undefined;
    var budget: u64 = 2 * hash_chunk_bytes; // 시험용 작은 예산
    var p1 = (try prepareWith(testing.allocator, t.join(&b1, "big.bin"), &budget)).ok;
    defer p1.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 2 * hash_chunk_bytes), p1.hashed); // 예산만큼
    try testing.expectEqual(@as(u64, 0), budget);
    var p2 = (try prepareWith(testing.allocator, t.join(&b1, "small.txt"), &budget)).ok;
    defer p2.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 11), p2.hashed); // 예산이 없어도 엿보기만큼은 잰다
    try testing.expectEqualStrings("small file\n", p2.head);
    const root = try ensureRoot(testing.allocator, t.path);
    defer testing.allocator.free(root);
    for ([_]bool{ true, false }) |clone| {
        var copy_budget: u64 = copy_cap_per_call;
        const r = try stageFileWith(testing.allocator, root, 4, if (clone) 1 else 2, 0, &p1, &copy_budget, clone);
        try testing.expect(r == .ok);
        testing.allocator.free(r.ok);
    }
    // 예산 밖의 뒤쪽은 stat 만 본다 — 공유 매핑으로 그 뒤쪽만 바꾸면 모른다(문서의 남는 틈). 앞쪽(잰 곳)을 바꾸면 안다.
    const rw = std.c.open(t.join(&b1, "big.bin").ptr, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, @as(std.c.mode_t, 0));
    try testing.expect(rw >= 0);
    defer _ = std.c.close(rw);
    const m = try std.posix.mmap(null, big.len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, rw, 0);
    defer std.posix.munmap(m);
    m[2 * hash_chunk_bytes + 5] ^= 0xff; // 잰 곳 밖
    {
        var copy_budget: u64 = copy_cap_per_call;
        const r = try stageFileWith(testing.allocator, root, 5, 1, 0, &p1, &copy_budget, true);
        try testing.expect(r == .ok);
        testing.allocator.free(r.ok);
    }
    m[hash_chunk_bytes + 5] ^= 0xff; // 잰 곳 안(첫 조각 뒤 — 엿보기 밖)
    {
        var copy_budget: u64 = copy_cap_per_call;
        const r = try stageFileWith(testing.allocator, root, 5, 2, 0, &p1, &copy_budget, true);
        try testing.expectEqual(StageError.changed, r.failed);
    }
}

// ── W9c③ 적대 리뷰 5 회차 변이(전 기능) — 살아남은 변이를 잡는 시험 ──
// PRnofollow: 정규 경로(`realpath`)는 링크를 다 푼 뒤의 경로라 보통은 `O_NOFOLLOW` 가 할 일이 없다 — 그것이 지키는 것은 정한 뒤·열기 전에 그 자리가
// 링크로 바뀌는 경쟁뿐이고, 그 경쟁을 만드는 시험이 없어 `O_NOFOLLOW` 를 지운 변이가 살아남았다.
var swap_target_buf: [std.fs.max_path_bytes]u8 = undefined;
var swap_target: [:0]const u8 = "";

const RealpathSwapper = struct {
    fn hook(real: [*:0]const u8) void {
        _ = std.c.unlink(real);
        _ = std.c.symlink(swap_target.ptr, real);
    }
};

test "W9c③ 적대 리뷰 5 회차 변이 PRnofollow: 정규 경로를 정한 뒤 열기 전에 그 자리가 다른 파일을 가리키는 링크로 바뀌면 따라가지 않고 거절한다(swapped)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var t = try Tmp.init();
    defer t.deinit();
    try t.write("a.txt", "cat picture\n");
    try t.write("secret.txt", "-----BEGIN OPENSSH PRIVATE KEY-----\n");
    var b1: [std.fs.max_path_bytes]u8 = undefined;
    const target = t.join(&b1, "secret.txt");
    @memcpy(swap_target_buf[0..target.len], target);
    swap_target_buf[target.len] = 0;
    swap_target = swap_target_buf[0..target.len :0];
    test_after_realpath = &RealpathSwapper.hook;
    defer test_after_realpath = null;
    var b2: [std.fs.max_path_bytes]u8 = undefined;
    try expectRefused(try prepare(testing.allocator, t.join(&b2, "a.txt")), .swapped);
}

// PRctime: 같은 길이로 바꿔 쓰고 mtime 을 되돌린 것(1 회차 R1)은 이제 내용 해시(3 회차 M1)도 잡아, 승인 뒤 비교에서 ctime 을 지운 변이가 살아남았다.
// ctime 만 잡는 자리는 해시 예산 밖이다 — 호출의 1 GiB 를 넘은 뒤쪽(또는 예산을 다 쓴 뒤의 파일)은 엿보기만큼만 해시한다(남는 틈으로 적은 것).
test "W9c③ 적대 리뷰 5 회차 변이 PRctime: 해시 예산 밖의 바이트를 같은 길이로 바꿔 쓰고 mtime 을 되돌려도 ctime 이 잡는다(changed)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var t = try Tmp.init();
    defer t.deinit();
    const body = array_repeat.repeat("x", (2 * head_bytes));
    try t.write("big.txt", body);
    var b1: [std.fs.max_path_bytes]u8 = undefined;
    const root = try ensureRoot(testing.allocator, t.path);
    defer testing.allocator.free(root);
    var hash_budget: u64 = 0; // 이 호출의 예산을 앞 파일들이 다 썼다 — 엿보기(앞 4 KiB)만 해시한다
    var p = (try prepareWith(testing.allocator, t.join(&b1, "big.txt"), &hash_budget)).ok;
    defer p.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, head_bytes), p.hashed);
    const fd = std.c.open(t.join(&b1, "big.txt").ptr, .{ .ACCMODE = .WRONLY }, @as(std.c.mode_t, 0));
    try testing.expect(fd >= 0);
    defer _ = std.c.close(fd);
    try testing.expectEqual(@as(isize, 6), std.c.pwrite(fd, "SECRET", 6, head_bytes + 100));
    const times = [2]std.c.timespec{ .{ .sec = p.mtime_sec, .nsec = p.mtime_nsec }, .{ .sec = p.mtime_sec, .nsec = p.mtime_nsec } };
    try testing.expectEqual(@as(c_int, 0), futimens(fd, &times));
    var budget: u64 = copy_cap_per_call;
    const r = try stageFile(testing.allocator, root, 1, 2, 0, &p, &budget);
    if (r == .ok) testing.allocator.free(r.ok);
    try testing.expect(r == .failed and r.failed == .changed);
}

// ── 폴더 올리기(사용자 결정 2026-11-20 「iframe·폴더 둘 다」) — 펼치기·사본 ─────────────────────────────────────────────────────────────

fn expectFolderRefused(r: FolderResult, want: FolderRefusal) !void {
    switch (r) {
        .refused => |got| try testing.expectEqual(want, got),
        .ok => |f| {
            var m = f;
            m.deinit(testing.allocator);
            return error.TestUnexpectedResult;
        },
    }
}

fn mkdirT(t: *const Tmp, name: []const u8) !void {
    var b: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqual(@as(c_int, 0), std.c.mkdir(t.join(&b, name).ptr, 0o700));
}

test "폴더 펼치기: 사람의 폴더 고르기처럼 — 숨긴 것(점 이름·숨김 표지, 폴더면 그 안까지)·링크(파일·폴더)·패키지·FIFO·넘길 수 없는 이름은 빼고 센다, 보통 파일은 상대 경로 순" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var t = try Tmp.init();
    defer t.deinit();
    try mkdirT(&t, "up");
    try mkdirT(&t, "up/sub");
    try mkdirT(&t, "up/sub/deep");
    try mkdirT(&t, "up/.git");
    try mkdirT(&t, "up/App.maru-pkg");
    try t.write("up/b.txt", "bb");
    try t.write("up/a.txt", "a");
    try t.write("up/sub/c.txt", "ccc");
    try t.write("up/sub/deep/d.txt", "dddd");
    try t.write("up/.env", "SECRET=1");
    try t.write("up/.git/config", "x");
    try t.write("up/App.maru-pkg/inner.txt", "pkg");
    try t.write("up/flagged.txt", "hidden by flag");
    try t.write("up/bad\x01name.txt", "ctl");
    try mkdirT(&t, "up/ctl\x01dir");
    try t.write("up/ctl\x01dir/inside.txt", "in");
    try t.write("outside.txt", "OUTSIDE");
    var b1: [std.fs.max_path_bytes]u8 = undefined;
    var b2: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqual(@as(c_int, 0), chflags(t.join(&b1, "up/flagged.txt").ptr, uf_hidden));
    try testing.expectEqual(@as(c_int, 0), std.c.symlink(t.join(&b1, "outside.txt").ptr, t.join(&b2, "up/link.txt").ptr));
    try testing.expectEqual(@as(c_int, 0), std.c.symlink(t.join(&b1, "up/sub").ptr, t.join(&b2, "up/dirlink").ptr));
    try testing.expectEqual(@as(c_int, 0), mkfifo(t.join(&b1, "up/fifo").ptr, 0o600));
    var r = try enumerateFolder(testing.allocator, t.join(&b1, "up"), null);
    defer r.ok.deinit(testing.allocator);
    const f = &r.ok;
    const want = [_][]const u8{ "a.txt", "b.txt", "sub/c.txt", "sub/deep/d.txt" };
    try testing.expectEqual(want.len, f.entries.items.len);
    for (want, f.entries.items) |w, e| try testing.expectEqualStrings(w, e.rel);
    try testing.expectEqualStrings("d.txt", f.entries.items[3].name());
    try testing.expectEqual(@as(u64, 1 + 2 + 3 + 4), f.bytes);
    // .env·.git(그 안은 세지 않는다 — 폴더째 뺀다)·숨김 표지 하나 = 3, 링크 둘, 패키지 하나, FIFO·제어 문자 이름의 파일과 폴더(그 안은 세지
    // 않는다 — 적대 검증 5 회차) = 3.
    try testing.expectEqual(Skipped{ .hidden = 3, .links = 2, .packages = 1, .other = 3 }, f.skipped);
    try testing.expectEqualStrings(t.join(&b2, "up"), f.real);
}

test "폴더 펼치기: 없는 폴더·폴더 아님·빈 폴더(숨긴 것만 있어도)는 거절, 폴더 자리의 링크는 실제 경로로 따른다(명시한 파일과 같다)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var t = try Tmp.init();
    defer t.deinit();
    var b1: [std.fs.max_path_bytes]u8 = undefined;
    var b2: [std.fs.max_path_bytes]u8 = undefined;
    try expectFolderRefused(try enumerateFolder(testing.allocator, t.join(&b1, "none"), null), .not_found);
    try t.write("file.txt", "x");
    try expectFolderRefused(try enumerateFolder(testing.allocator, t.join(&b1, "file.txt"), null), .not_folder);
    try mkdirT(&t, "empty");
    try t.write("empty/.DS_Store", "x");
    try expectFolderRefused(try enumerateFolder(testing.allocator, t.join(&b1, "empty"), null), .empty);
    try mkdirT(&t, "real");
    try t.write("real/a.txt", "a");
    try testing.expectEqual(@as(c_int, 0), std.c.symlink(t.join(&b1, "real").ptr, t.join(&b2, "alias").ptr));
    var r = try enumerateFolder(testing.allocator, t.join(&b1, "alias"), null);
    defer r.ok.deinit(testing.allocator);
    try testing.expectEqualStrings(t.join(&b2, "real"), r.ok.real);
    // 멈추라는 표지(메인이 작업을 놓았다)면 곧 그만둔다.
    var stop: std.atomic.Value(u8) = .init(2);
    try expectFolderRefused(try enumerateFolder(testing.allocator, t.join(&b1, "real"), &stop), .cancelled);
}

test "폴더 펼치기 상한: 파일 1000 개 넘음·크기 합 4 GiB 넘음(성긴 파일)·깊이 32 넘음은 통째로 거절 — 일부만 올리지 않는다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var t = try Tmp.init();
    defer t.deinit();
    var b1: [std.fs.max_path_bytes]u8 = undefined;
    try mkdirT(&t, "many");
    var nb: [64]u8 = undefined;
    for (0..max_folder_files) |i| try t.write(try std.fmt.bufPrint(&nb, "many/f{d}", .{i}), "");
    {
        var r = try enumerateFolder(testing.allocator, t.join(&b1, "many"), null);
        try testing.expectEqual(max_folder_files, r.ok.entries.items.len); // 딱 상한은 된다
        r.ok.deinit(testing.allocator);
    }
    try t.write("many/one-more", "");
    try expectFolderRefused(try enumerateFolder(testing.allocator, t.join(&b1, "many"), null), .too_many_files);
    try mkdirT(&t, "big");
    try t.write("big/a", "");
    {
        const fd = std.c.open(t.join(&b1, "big/a").ptr, .{ .ACCMODE = .WRONLY }, @as(std.c.mode_t, 0));
        defer _ = std.c.close(fd);
        try testing.expectEqual(@as(c_int, 0), std.c.ftruncate(fd, @intCast(max_folder_bytes + 1)));
    }
    try expectFolderRefused(try enumerateFolder(testing.allocator, t.join(&b1, "big"), null), .too_large);
    var path_buf: [4096]u8 = undefined;
    var len: usize = (try std.fmt.bufPrint(&path_buf, "deep", .{})).len;
    try mkdirT(&t, "deep");
    for (0..max_folder_depth + 1) |_| {
        @memcpy(path_buf[len..][0..2], "/d");
        len += 2;
        try mkdirT(&t, path_buf[0..len]);
    }
    @memcpy(path_buf[len..][0..6], "/x.txt");
    try t.write(path_buf[0 .. len + 6], "x");
    try expectFolderRefused(try enumerateFolder(testing.allocator, t.join(&b1, "deep"), null), .too_deep);
}

test "폴더 사본: 펼친 이름으로 <뿌리>/<탭>/<op>/<i>/<이름> — 펼친 뒤 그 자리를 밖의 파일 링크로·위 폴더를 다른 폴더 링크로 바꾸거나 크기가 바뀌면 folder_changed" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var t = try Tmp.init();
    defer t.deinit();
    var b1: [std.fs.max_path_bytes]u8 = undefined;
    var b2: [std.fs.max_path_bytes]u8 = undefined;
    try mkdirT(&t, "up");
    try mkdirT(&t, "up/sub");
    try t.write("up/a.txt", "AAAA");
    try t.write("up/sub/b.txt", "BBBB");
    try mkdirT(&t, "evil");
    try t.write("evil/b.txt", "EVIL");
    try t.write("secret.txt", "SECR");
    const root = try ensureRoot(testing.allocator, t.path);
    defer testing.allocator.free(root);
    var r = try enumerateFolder(testing.allocator, t.join(&b1, "up"), null);
    defer r.ok.deinit(testing.allocator);
    var hash: u64 = hash_cap_per_call;
    var budget: u64 = copy_cap_per_call;
    {
        const s = try stageFolderEntry(testing.allocator, &r.ok, 1, root, 3, 4, &hash, &budget, true);
        defer testing.allocator.free(s.ok);
        var want: [std.fs.max_path_bytes]u8 = undefined;
        try testing.expectEqualStrings(try std.fmt.bufPrint(&want, "{s}/3/4/1/b.txt", .{root}), s.ok);
    }
    // 열 수 없는 파일(권한)은 「바뀌었다」 가 아니라 열 수 없다는 글 — 다시 해도 같다(적대 검증 18 회차).
    {
        var b3: [std.fs.max_path_bytes]u8 = undefined;
        const p = t.join(&b3, "up/sub/b.txt");
        try testing.expectEqual(@as(c_int, 0), std.c.chmod(p.ptr, 0));
        defer _ = std.c.chmod(p.ptr, 0o644);
        const s = try stageFolderEntry(testing.allocator, &r.ok, 1, root, 3, 8, &hash, &budget, true);
        try testing.expect(s == .failed and s.failed == .folder_unreadable);
    }
    // 복사(다른 볼륨)의 예산을 넘으면 폴더의 글(「그 파일」 이 아니다 — 적대 검증 6·10 회차).
    {
        var small: u64 = 3;
        const s = try stageFolderEntry(testing.allocator, &r.ok, 1, root, 3, 9, &hash, &small, false);
        try testing.expect(s == .failed and s.failed == .folder_too_large_to_copy);
        try testing.expect(std.mem.indexOf(u8, StageError.folder_too_large_to_copy.text(), "the folder is on another volume") != null);
    }
    // 펼친 뒤 a.txt 를 같은 크기의 밖 파일 링크로 — 다른 inode 라 올리지 않는다.
    _ = std.c.unlink(t.join(&b1, "up/a.txt").ptr);
    try testing.expectEqual(@as(c_int, 0), std.c.symlink(t.join(&b1, "secret.txt").ptr, t.join(&b2, "up/a.txt").ptr));
    {
        const s = try stageFolderEntry(testing.allocator, &r.ok, 0, root, 3, 5, &hash, &budget, true);
        try testing.expect(s == .failed and s.failed == .folder_changed);
    }
    // 위 폴더(sub)를 같은 이름의 파일이 든 다른 폴더 링크로.
    try testing.expectEqual(@as(c_int, 0), std.c.rename(t.join(&b1, "up/sub").ptr, t.join(&b2, "up/sub-old").ptr));
    try testing.expectEqual(@as(c_int, 0), std.c.symlink(t.join(&b1, "evil").ptr, t.join(&b2, "up/sub").ptr));
    {
        const s = try stageFolderEntry(testing.allocator, &r.ok, 1, root, 3, 6, &hash, &budget, true);
        try testing.expect(s == .failed and s.failed == .folder_changed);
    }
    // 되돌리고 크기를 바꾼다(펼친 크기와 다르다).
    _ = std.c.unlink(t.join(&b1, "up/sub").ptr);
    try testing.expectEqual(@as(c_int, 0), std.c.rename(t.join(&b1, "up/sub-old").ptr, t.join(&b2, "up/sub").ptr));
    try t.write("up/sub/b.txt", "BBBBBBBB");
    {
        const s = try stageFolderEntry(testing.allocator, &r.ok, 1, root, 3, 7, &hash, &budget, true);
        try testing.expect(s == .failed and s.failed == .folder_changed);
    }
}

test "폴더 사본 목록: 사본 경로(뿌리 포함)와 읽기의 이름·크기가 DevTools 인자 한 번에 드는가 — 경계 바로 아래는 들고 바로 위는 안 든다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var entries: std.ArrayList(FolderEntry) = .empty;
    defer {
        for (entries.items) |e| testing.allocator.free(e.rel);
        entries.deinit(testing.allocator);
    }
    for (0..3) |_| try entries.append(testing.allocator, .{ .rel = try testing.allocator.dupe(u8, "d/ab\"c"), .dev = 1, .ino = 1, .size = 1 });
    var folder: Folder = .{ .real = @constCast("/x"), .entries = entries };
    const root = "/rrrrrrrrrrrrrrrrrrrr";
    // 경로 하나 = 뿌리 21 + "/9/8/<i>/" 7 + JSON 글 "ab\"c"(따옴표 둘 + 4 + 이스케이프 1 = 7) + 쉼표 1 = 36 → 셋이면 108(이름·크기 쪽은 (7+1+21)×3 = 87).
    try testing.expect(folderListFits(&folder, root, 9, 8, 108, 0));
    try testing.expect(!folderListFits(&folder, root, 9, 8, 107, 0));
    try testing.expect(!folderListFits(&folder, root, 9, 8, 108, 1)); // 여유를 더하면 넘는다
    entries = folder.entries;
}

test "에이전트에게 가는 업로드 글은 걷힌 확인(approval)을 말하지 않는다(문서 리뷰 2026-11-20)" {
    for (std.enums.values(StageError)) |e| try testing.expect(std.mem.indexOf(u8, e.text(), "approv") == null);
    for (std.enums.values(FolderRefusal)) |e| try testing.expect(std.mem.indexOf(u8, e.text(), "approv") == null);
}
