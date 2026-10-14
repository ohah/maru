//! 에이전트의 파일 올리기(W9c③ `browser.upload`)에서 **파일을 여는 일과 사본을 만드는 일**(L4 — POSIX). 업로드의 유일한 관문은 확인 모달이고
//! (사용자 결정 2026-10-15 — 앱이 파일을 읽는다), 모달이 보인 파일과 페이지가 받는 바이트가 같아야 한다. 그래서(계획 공격 A3·A4·A7):
//!
//! - **모달 전에 연다**(`prepare`): `realpath` → `open(O_RDONLY|O_NONBLOCK|O_NOFOLLOW)` → `fstat`(정규 파일만 — 폴더·FIFO·장치·소켓은
//!   거절, `O_NONBLOCK` 이라 FIFO 를 열다 멈추지 않는다) → `F_GETPATH`(모달이 보일 실제 경로 — 연 fd 의 것) → 앞부분 4 KiB. fd 를 쥔 채로
//!   둔다. realpath 뒤 마지막 이름이 링크로 바뀌면 `O_NOFOLLOW` 가 막는다(ELOOP).
//! - **승인 뒤에 쥔 fd 에서 사본**(`stageFile`): `fclonefileat`(같은 볼륨 — 2 ms, 원본이 갈라질 때까지 공간을 쓰지 않는다), 안 되면 fd 에서
//!   복사(다른 볼륨 — 상한 안에서만). 사본 뒤 fd 를 다시 `fstat` 해 (장치·inode·크기·mtime) 가 모달 때와 다르면 실패 — 「승인 뒤 파일이
//!   바뀌었다」. 페이지는 사본만 본다: 승인 뒤 원본을 바꾸거나 링크를 바꿔도 닿지 않는다(실측 k9c — 원본 경로를 넘기면 바뀐 대상을 읽었다).
//! - **사본 자리**: `<프로필>/upload-staging/<탭>/<op>/<i>/<이름>` — 폴더 0700, 파일 0400. 탭이 닫힐 때 그 탭의 폴더를 지우고(방문 기록
//!   뒤로가기가 그 파일을 새 문서에 되살린다 — 실측 l), 이 실행이 처음 프로필을 잡을 때 전부 지운다. 뿌리는 한 번 `realpath` 한
//!   정규 경로다(정규가 아닌 경로는 읽기가 깨지거나 렌더러가 죽었다 — 실측 k3·k4).
//!
//! 느린 볼륨(죽은 망 마운트)의 `open`·`stat`·읽기는 멈출 수 있다 — 이 함수들은 **작업 스레드**에서 부른다(`app_host_abi` 의 업로드 작업).
//! 이 파일은 스레드를 띄우지 않는다.

const std = @import("std");
const builtin = @import("builtin");
const display = @import("maru").session.web_upload_display;

extern "c" fn fclonefileat(srcfd: c_int, dst_dirfd: c_int, dst: [*:0]const u8, flags: u32) c_int;

/// 다른 볼륨에서 복사할 때 한 번의 호출이 쓸 수 있는 바이트(작성자 선택 1 GiB)와 한 탭이 쓸 수 있는 바이트(4 GiB) — 같은 볼륨의 복제는 세지 않는다.
pub const copy_cap_per_call: u64 = 1 << 30;
pub const copy_cap_per_tab: u64 = 4 << 30;

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
    /// 앞부분(최대 `display.head_bytes`, 소유) — 엿보기.
    head: []u8,

    pub fn deinit(self: *Prepared, gpa: std.mem.Allocator) void {
        if (self.fd >= 0) _ = std.c.close(self.fd);
        gpa.free(self.real);
        gpa.free(self.head);
        self.* = undefined;
    }

    pub fn info(self: *const Prepared) display.FileInfo {
        return .{ .path = self.real, .size = self.size, .nlink = self.nlink, .peek = display.classify(self.head, self.size) };
    }

    /// 사본의 이름 — 실제 경로의 마지막 이름(모달이 보인 그 이름을 페이지가 받는다. 링크의 이름이 아니다 — 작성자 선택).
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
        };
    }
};

pub const PrepareResult = union(enum) { ok: Prepared, refused: Refusal };

fn statOf(fd: c_int) ?std.c.Stat {
    var st: std.c.Stat = undefined;
    if (std.c.fstat(fd, &st) != 0) return null;
    return st;
}

/// 경로 하나를 연다(모달 전). 상대 경로·제어 문자는 L2 가 거절했다. 작업 스레드에서 부른다.
pub fn prepare(gpa: std.mem.Allocator, path: []const u8) !PrepareResult {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return .{ .refused = .too_long };
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real = std.c.realpath(path_z.ptr, &real_buf) orelse {
        const e = std.c._errno().*;
        return .{ .refused = if (e == @intFromEnum(std.c.E.NOENT) or e == @intFromEnum(std.c.E.NOTDIR)) .not_found else .unreadable };
    };
    const fd = std.c.open(real, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true, .NONBLOCK = true }, @as(std.c.mode_t, 0));
    if (fd < 0) {
        const e = std.c._errno().*;
        return .{ .refused = if (e == @intFromEnum(std.c.E.LOOP)) .swapped else if (e == @intFromEnum(std.c.E.NOENT)) .not_found else if (e == @intFromEnum(std.c.E.OPNOTSUPP) or e == @intFromEnum(std.c.E.NXIO)) .not_regular else .unreadable };
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
    const size: u64 = @intCast(@max(st.size, 0));
    const want = @min(size, display.head_bytes);
    const head = try gpa.alloc(u8, want);
    errdefer gpa.free(head);
    var have: usize = 0;
    while (have < want) {
        const n = std.c.pread(fd, head.ptr + have, want - have, @intCast(have));
        if (n < 0) {
            if (std.c._errno().* == @intFromEnum(std.c.E.INTR)) continue;
            gpa.free(head);
            return .{ .refused = .unreadable };
        }
        if (n == 0) break;
        have += @intCast(n);
    }
    const head_owned = if (have < want) blk: {
        const shrunk = try gpa.dupe(u8, head[0..have]);
        gpa.free(head);
        break :blk shrunk;
    } else head;
    errdefer gpa.free(head_owned);
    const real_owned = try gpa.dupe(u8, got);
    keep = true;
    return .{ .ok = .{
        .fd = fd,
        .real = real_owned,
        .size = size,
        .dev = st.dev,
        .ino = st.ino,
        .nlink = st.nlink,
        .mtime_sec = st.mtimespec.sec,
        .mtime_nsec = st.mtimespec.nsec,
        .head = head_owned,
    } };
}

/// 같은 파일을 두 번 적었는가(심링크·하드 링크로 다른 경로가 같은 파일 — 장치·inode). `files[i]` 와 앞의 것.
pub fn sameFileBefore(files: []const Prepared, i: usize) bool {
    for (files[0..i]) |p| if (p.dev == files[i].dev and p.ino == files[i].ino) return true;
    return false;
}

/// 사본의 뿌리 — `<base>/upload-staging` 을 만들고(0700) 정규 경로로 돌려준다(소유).
pub fn ensureRoot(gpa: std.mem.Allocator, base: []const u8) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = std.fmt.bufPrintZ(&buf, "{s}/upload-staging", .{base}) catch return error.PathTooLong;
    if (std.c.mkdir(root.ptr, 0o700) != 0 and std.c._errno().* != @intFromEnum(std.c.E.EXIST)) return error.CreateFailed;
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

    pub fn text(self: StageError) []const u8 {
        return switch (self) {
            .changed => "the file changed after the user approved it — run upload again",
            .too_large => "the file is on another volume and is too large to copy (1 GiB per call, 4 GiB per tab)",
            .io => "could not make the copy the page reads",
        };
    }
};

pub const StageResult = union(enum) {
    /// 사본의 정규 경로(소유).
    ok: []u8,
    failed: StageError,
};

fn mkdirOwned(path: [:0]const u8) bool {
    return std.c.mkdir(path.ptr, 0o700) == 0 or std.c._errno().* == @intFromEnum(std.c.E.EXIST);
}

/// 승인 뒤 — 쥔 fd 에서 `<root>/<tab>/<op>/<index>/<이름>` 으로 사본을 만든다(복제, 안 되면 복사 — `copy_budget` 안에서, 쓴 만큼 줄인다).
/// 사본 뒤 원본이 모달 때와 다르면 사본을 지우고 `changed`. 작업 스레드에서 부른다.
pub fn stageFile(gpa: std.mem.Allocator, root: []const u8, tab: u64, op: u64, index: usize, p: *const Prepared, copy_budget: *u64) !StageResult {
    return stageFileWith(gpa, root, tab, op, index, p, copy_budget, true);
}

/// `try_clone` 거짓 — 복제를 건너뛰고 복사한다(시험이 다른 볼륨의 길을 같은 볼륨에서 본다).
fn stageFileWith(gpa: std.mem.Allocator, root: []const u8, tab: u64, op: u64, index: usize, p: *const Prepared, copy_budget: *u64, try_clone: bool) !StageResult {
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    inline for (.{ "{s}/{d}", "{s}/{d}/{d}", "{s}/{d}/{d}/{d}" }, 0..) |fmt, depth| {
        const args = switch (depth) {
            0 => .{ root, tab },
            1 => .{ root, tab, op },
            else => .{ root, tab, op, index },
        };
        const d = std.fmt.bufPrintZ(&dir_buf, fmt, args) catch return .{ .failed = .io };
        if (!mkdirOwned(d)) return .{ .failed = .io };
    }
    var dest_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dest = std.fmt.bufPrintZ(&dest_buf, "{s}/{d}/{d}/{d}/{s}", .{ root, tab, op, index, p.name() }) catch return .{ .failed = .io };
    var made = false;
    defer if (!made) {
        _ = std.c.unlink(dest.ptr);
    };
    if (!try_clone or fclonefileat(p.fd, std.c.AT.FDCWD, dest.ptr, 0) != 0) {
        const e = std.c._errno().*;
        // 같은 볼륨이 아니거나(EXDEV) 복제를 모르는 파일 시스템(ENOTSUP) — 복사한다. 그 밖의 실패는 그대로.
        if (try_clone and e != @intFromEnum(std.c.E.XDEV) and e != @intFromEnum(std.c.E.OPNOTSUPP)) return .{ .failed = .io };
        if (p.size > copy_budget.*) return .{ .failed = .too_large };
        if (!try copyFromFd(p.fd, dest, p.size)) return .{ .failed = .io };
        copy_budget.* -= p.size;
    }
    // 사본은 읽기만(0400) — 페이지가 읽는 동안 바뀌지 않게.
    const out = std.c.open(dest.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, @as(std.c.mode_t, 0));
    if (out < 0) return .{ .failed = .io };
    defer _ = std.c.close(out);
    if (std.c.fchmod(out, 0o400) != 0) return .{ .failed = .io };
    const copied = statOf(out) orelse return .{ .failed = .io };
    // 원본이 모달 때와 같은가(장치·inode·크기·mtime) — 승인 뒤 바뀌었으면 사본이 모달과 다른 내용일 수 있다.
    const now = statOf(p.fd) orelse return .{ .failed = .io };
    if (now.dev != p.dev or now.ino != p.ino or now.size != @as(i64, @intCast(p.size)) or now.mtimespec.sec != p.mtime_sec or now.mtimespec.nsec != p.mtime_nsec)
        return .{ .failed = .changed };
    if (copied.size != @as(i64, @intCast(p.size))) return .{ .failed = .changed };
    made = true;
    return .{ .ok = try gpa.dupe(u8, dest) };
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
            if (std.c._errno().* == @intFromEnum(std.c.E.INTR)) continue;
            return false;
        }
        if (n == 0) return false; // 짧아졌다 — 바뀐 것이다(부른 쪽의 비교가 아니라 여기서 멈춘다)
        var done: usize = 0;
        const got: usize = @intCast(n);
        while (done < got) {
            const w = std.c.write(out, buf[done..].ptr, got - done);
            if (w < 0) {
                if (std.c._errno().* == @intFromEnum(std.c.E.INTR)) continue;
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
    const root_z = std.fmt.bufPrintZ(&buf, "{s}", .{root}) catch return;
    const dir = std.c.open(root_z.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .DIRECTORY = true, .NOFOLLOW = true }, @as(std.c.mode_t, 0));
    if (dir < 0) return;
    defer _ = std.c.close(dir);
    var name_buf: [256]u8 = undefined;
    const name = std.fmt.bufPrintZ(&name_buf, "{s}", .{sub}) catch return;
    removeAt(dir, name, 0);
}

/// 뿌리 전체를 지운다(이 실행이 처음 프로필을 잡을 때 — 지난 실행이 남긴 사본).
pub fn wipeRoot(base: []const u8) void {
    removeUnder(base, "upload-staging");
}

fn removeAt(dir: c_int, name: [:0]const u8, depth: u8) void {
    if (std.c.unlinkat(dir, name.ptr, 0) == 0) return;
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
            var nb: [256]u8 = undefined;
            const nz = std.fmt.bufPrintZ(&nb, "{s}", .{n}) catch continue;
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
        const tmpl = try std.fmt.bufPrintZ(&tmpl_buf, "{s}/maru-upload-XXXXXX", .{if (base) |b| std.mem.trimEnd(u8, std.mem.span(b), "/") else "/tmp"});
        const made = mkdtemp(tmpl.ptr) orelse return error.TempFailed;
        var real_buf: [std.fs.max_path_bytes]u8 = undefined;
        const real = std.c.realpath(made, &real_buf) orelse return error.TempFailed;
        return .{ .path = try testing.allocator.dupeZ(u8, std.mem.sliceTo(real, 0)) };
    }

    fn deinit(self: *Tmp) void {
        const slash = std.mem.lastIndexOfScalar(u8, self.path, '/').?;
        removeUnder(self.path[0..slash], self.path[slash + 1 ..]);
        testing.allocator.free(self.path);
    }

    fn join(self: *const Tmp, buf: []u8, name: []const u8) [:0]u8 {
        return std.fmt.bufPrintZ(buf, "{s}/{s}", .{ self.path, name }) catch unreachable;
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
        try testing.expectEqualStrings("hello", r.ok.info().peek.text.?);
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
    const z = try std.fmt.bufPrintZ(&zb, "{s}", .{staged});
    const sfd = std.c.open(z.ptr, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    defer _ = std.c.close(sfd);
    var got: [8]u8 = undefined;
    try testing.expectEqual(@as(isize, 4), std.c.read(sfd, &got, got.len));
    try testing.expectEqualStrings("AAAA", got[0..4]);
    const st = statOf(sfd).?;
    try testing.expectEqual(@as(u16, 0o400), st.mode & 0o777);
    inline for (.{ "{s}/7", "{s}/7/42", "{s}/7/42/0" }) |fmt| {
        var db: [std.fs.max_path_bytes]u8 = undefined;
        const d = try std.fmt.bufPrintZ(&db, fmt, .{root});
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
    const d = try std.fmt.bufPrintZ(&db, "{s}/1/2/0/a.txt", .{root});
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
    const dest = try std.fmt.bufPrintZ(&db, "{s}/copy.txt", .{t.path});
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
    const dest2 = try std.fmt.bufPrintZ(&db2, "{s}/copy2.txt", .{t.path});
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
    const inner = try std.fmt.bufPrintZ(&b2, "{s}/9", .{root});
    try testing.expectEqual(@as(c_int, 0), std.c.mkdir(inner.ptr, 0o700));
    var lb: [std.fs.max_path_bytes]u8 = undefined;
    const link = try std.fmt.bufPrintZ(&lb, "{s}/9/out", .{root});
    try testing.expectEqual(@as(c_int, 0), std.c.symlink(t.path.ptr, link.ptr));
    wipeRoot(t.path);
    var rb: [std.fs.max_path_bytes]u8 = undefined;
    const rz = try std.fmt.bufPrintZ(&rb, "{s}", .{root});
    try testing.expect(statPath(rz.ptr) == null);
    try testing.expect(statPath(t.join(&b1, "outside.txt").ptr) != null);
}
