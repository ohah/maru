//! kitty graphics **매체 전송**(`t=f` 파일 · `t=t` 임시 파일 · `t=s` POSIX 공유메모리)의 읽기 — 리더 스레드가
//! 락 **밖**에서 부른다. 코어는 I/O 를 하지 않으므로(`terminal/kitty.zig` `kittyTransmitMedia`) 경로의 뜻은
//! 전부 여기서 정한다. 결과는 `KittyDecoded` 로 코어의 `completeKittyTransmit` 에 그대로 들어간다.
//!
//! 명세(kitty graphics protocol «The transmission medium»)가 정한 규칙 넷:
//!
//!  1. **일반 파일만 읽는다.** 경로는 신뢰 경계 밖(ssh 세션·`cat` 한 파일)에서 오므로 장치·소켓·FIFO 는
//!     거부한다. 심링크는 **따라간다**(명세) — 루프·과다는 열기 실패로 `EBADF`.
//!  2. **`t=t` 는 읽은 뒤 지운다 — 단, 알려진 임시 디렉터리 안이고 경로에 `tty-graphics-protocol` 이 있을 때만.**
//!     삭제는 예의가 아니라 **계약**이다: icat 은 탐침(`a=q`)의 임시 파일이 실제로 사라졌는지 보고 그 매체를
//!     믿는다(실측 2026-09-14). 그리고 제한 없는 삭제는 원격이 보낸 한 줄로 내 파일을 지우는 통로다 —
//!     이 기능의 유일한 실 방어선이다(소유자 검사는 연극이다: 터미널이 읽을 수 있는 파일은 사용자도 읽을 수
//!     있다. `docs/plans/terminal-input-and-protocols.md` «보안»).
//!  3. **`t=s` 는 읽은 뒤 `shm_unlink`** — 열기에 성공했으면 읽기가 실패해도 unlink 한다(앱은 터미널이 언제 다
//!     읽었는지 모르므로 자기가 지울 수 없다). 이름은 `/` 로 시작하지 않아도 받는다: kitten 이 macOS 에서
//!     `icat-<랜덤>` 을 보낸다(실측 2026-09-20) — 거부하면 kitty 공식 도구가 이 매체를 못 쓴다.
//!  4. **`S`/`O`** — `O` 부터 `S` 바이트. `S=0` 은 «끝까지». **`S` 가 자원보다 크면 있는 데까지 읽는다** — icat 의
//!     탐침은 3 바이트를 두고 `S=` 에 경로 길이를 싣는다(실측 2026-09-20: `S=159`, 파일 3 바이트; shm 은 `S=18`,
//!     16 KiB 페이지에 3 바이트). kitty 가 그것에 OK 로 답하므로 여기서 거부하면 kitty 공식 도구가 두 매체를
//!     «미지원» 으로 읽는다. `O` 가 자원 밖이면 `EBADF`. 넘치는 픽셀은 코어가 버린다(`decodeKittyRaw`).
//!
//! 크기 상한(`cap`)은 호출자가 준다 — 코어의 이미지 총량 한도. raw 픽셀은 `expected` 로 정확히 알지만 PNG·zlib 는
//! 읽어 봐야 아니 한도로 막는다(320 MB 파일을 읽어 놓고 거부하는 일이 없게 **읽기 전에** 크기로 거른다).
const std = @import("std");
const builtin = @import("builtin");
const terminal = @import("../terminal.zig");

const KittyPendingJob = terminal.kitty.KittyPendingJob;
const KittyDecoded = terminal.kitty.KittyDecoded;

/// 임시 파일 삭제를 허용하는 디렉터리(명세: `/tmp`·`/dev/shm`·`TMPDIR`·플랫폼 임시 디렉터리). 실제 비교는
/// **정규화된** 경로로 한다 — macOS 의 `/tmp` 는 `/private/tmp` 의 심링크라 글자 비교는 헛돈다.
pub const temp_roots = [_][]const u8{ "/tmp", "/var/tmp", "/dev/shm" };
/// 명세가 요구하는 파일 이름 표식. 없으면 임시 디렉터리 안이라도 지우지 않는다.
pub const temp_marker = "tty-graphics-protocol";

/// job 하나를 읽어 디코드까지 한다. `cap` 은 한 번에 받아들일 최대 바이트(코어 한도). 실패는 전부
/// `.unreadable`(→ `EBADF`) — 무엇이 틀렸는지는 응답 한 줄로 못 실으므로 구분하지 않는다.
pub fn readAndDecode(io: std.Io, alloc: std.mem.Allocator, job: *const KittyPendingJob, cap: usize) KittyDecoded {
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    const name = decodeName(&name_buf, job.payload) orelse return .unreadable;
    const range: Range = .{ .offset = job.cmd.data_offset, .size = job.cmd.data_size };
    const raw = switch (job.medium) {
        'f' => readFile(io, alloc, name, range, cap, .keep),
        't' => readFile(io, alloc, name, range, cap, .delete_if_temp),
        's' => readSharedMemory(io, alloc, name, range, cap),
        else => return .unreadable,
    } orelse return .unreadable;
    return terminal.kitty.decodeKittyRaw(job, raw, alloc);
}

/// payload(base64 경로·이름) → 문자열. NUL 이 들어 있으면 거부(경로가 잘려 다른 파일을 가리킨다).
fn decodeName(buf: *[std.fs.max_path_bytes]u8, payload: []const u8) ?[:0]const u8 {
    const dec = terminal.kitty.base64Decoder(payload); // kitten 은 패딩 없이 보낸다
    const len = dec.calcSizeForSlice(payload) catch return null;
    if (len == 0 or len >= buf.len) return null;
    dec.decode(buf[0..len], payload) catch return null;
    if (std.mem.indexOfScalar(u8, buf[0..len], 0) != null) return null;
    buf[len] = 0;
    return buf[0..len :0];
}

pub const Range = struct {
    offset: u64,
    /// 0 = 끝까지.
    size: u64,

    /// 자원 길이 `total` 안에서 실제로 읽을 [start, end). `offset` 이 자원 밖이면 null. `size` 는 있는 데까지로 잘린다(머리말 4).
    pub fn resolve(self: Range, total: u64) ?struct { start: u64, len: usize } {
        if (self.offset > total) return null;
        const avail = total - self.offset;
        const want = if (self.size == 0) avail else @min(self.size, avail);
        return .{ .start = self.offset, .len = std.math.cast(usize, want) orelse return null };
    }
};

const TempPolicy = enum { keep, delete_if_temp };

/// 파일을 연 뒤에 검증한다(TOCTOU — 경로를 먼저 검사하고 열면 그 사이 바꿔치기된다). 정규 경로는 **열린
/// 핸들에서** 얻어 삭제 판정에 쓴다.
fn readFile(io: std.Io, alloc: std.mem.Allocator, path: []const u8, range: Range, cap: usize, policy: TempPolicy) ?[]u8 {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);
    const st = file.stat(io) catch return null;
    if (st.kind != .file) return null; // 장치·소켓·FIFO·디렉터리 — 명세가 금지
    const win = range.resolve(st.size) orelse return null;
    if (win.len > cap) return null;
    const out = alloc.alloc(u8, win.len) catch return null;
    const got = file.readPositionalAll(io, out, win.start) catch {
        alloc.free(out);
        return null;
    };
    if (got != win.len) {
        alloc.free(out);
        return null;
    }
    if (policy == .delete_if_temp) {
        var real_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (file.realPath(io, &real_buf)) |n| {
            const real = real_buf[0..n];
            if (isDeletableTempPath(io, real, std.c.getenv("TMPDIR"))) {
                std.Io.Dir.cwd().deleteFile(io, real) catch {};
            }
        } else |_| {}
    }
    return out;
}

/// 명세의 삭제 조건 — 정규화된 `abs_path` 가 임시 루트(`temp_roots`·`TMPDIR`) 중 하나 **안**에 있고 이름에
/// `temp_marker` 가 있다. 루트도 정규화해 비교한다(`/tmp` → `/private/tmp`).
pub fn isDeletableTempPath(io: std.Io, abs_path: []const u8, tmpdir_env: ?[*:0]const u8) bool {
    if (std.mem.indexOf(u8, abs_path, temp_marker) == null) return false;
    for (temp_roots) |root| if (underRoot(io, abs_path, root)) return true;
    if (tmpdir_env) |t| {
        const env = std.mem.span(t);
        if (env.len > 0 and underRoot(io, abs_path, env)) return true;
    }
    return false;
}

fn underRoot(io: std.Io, abs_path: []const u8, root: []const u8) bool {
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    var dir = std.Io.Dir.openDirAbsolute(io, root, .{}) catch return false;
    defer dir.close(io);
    const n = dir.realPath(io, &real_buf) catch return false;
    const real_root = std.mem.trimEnd(u8, real_buf[0..n], "/");
    if (real_root.len == 0 or abs_path.len <= real_root.len) return false;
    return std.mem.startsWith(u8, abs_path, real_root) and abs_path[real_root.len] == '/';
}

/// POSIX 공유메모리 — `shm_open` → `fstat` → `mmap` 복사 → `shm_unlink`(열렸으면 언제나). 이름은 그대로 쓴다
/// (머리말 3). Windows·libc 없는 타깃은 없는 기능이다(→ `EBADF`).
fn readSharedMemory(io: std.Io, alloc: std.mem.Allocator, name: [:0]const u8, range: Range, cap: usize) ?[]u8 {
    if (comptime builtin.os.tag == .windows or !builtin.link_libc) return null;
    const fd = std.c.shm_open(name.ptr, @as(c_int, @bitCast(std.c.O{ .ACCMODE = .RDONLY })), @as(std.c.mode_t, 0));
    if (fd < 0) return null;
    // fd 를 `std.Io.File` 로 감싸 stat·close 를 Io 로 한다 — `std.c.fstat` 은 linux 타깃에서 심볼이 아니라(cross-target
    // 게이트 실측) 직접 부르면 안 된다. `shm_open`·`shm_unlink` 만 libc 다.
    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    defer file.close(io);
    defer _ = std.c.shm_unlink(name.ptr); // 앱은 터미널이 언제 다 읽었는지 모른다 — 지우는 쪽은 언제나 터미널이다
    const st = file.stat(io) catch return null;
    if (st.size <= 0) return null;
    // shm 의 stat 크기는 페이지 배수로 올라가 있을 수 있다 — 범위는 `S`/`O` 가 정하고 여기서는 상한만 본다.
    const total: u64 = @intCast(st.size);
    const win = range.resolve(total) orelse return null;
    if (win.len > cap) return null;
    const mapped = std.posix.mmap(null, @intCast(total), .{ .READ = true }, .{ .TYPE = .SHARED }, fd, 0) catch return null;
    defer std.posix.munmap(mapped);
    const out = alloc.alloc(u8, win.len) catch return null;
    const start: usize = @intCast(win.start);
    @memcpy(out, mapped[start .. start + win.len]);
    return out;
}

// ── 판정자 ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn b64(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    const out = try alloc.alloc(u8, std.base64.standard.Encoder.calcSize(s.len));
    _ = std.base64.standard.Encoder.encode(out, s);
    return out;
}

fn jobFor(medium: u8, payload: []u8, format: u32, w: u32, h: u32, size: u32, offset: u32) KittyPendingJob {
    const bpp: u8 = if (format == 24) 3 else 4;
    return .{
        .cmd = .{ .action = 't', .format = @intCast(format), .width = w, .height = h, .image_id = 1, .medium = medium, .data_size = size, .data_offset = offset },
        .payload = payload,
        .generation = 1,
        .expected = if (format == 100) 0 else @as(usize, w) * @as(usize, h) * bpp,
        .bpp = bpp,
        .format = format,
        .medium = medium,
    };
}

test "Range: S=0 은 끝까지, S 가 자원을 넘으면 있는 데까지, O 가 자원 밖이면 null" {
    try testing.expectEqual(@as(usize, 10), Range.resolve(.{ .offset = 0, .size = 0 }, 10).?.len);
    try testing.expectEqual(@as(usize, 7), Range.resolve(.{ .offset = 3, .size = 0 }, 10).?.len);
    try testing.expectEqual(@as(usize, 4), Range.resolve(.{ .offset = 3, .size = 4 }, 10).?.len);
    try testing.expectEqual(@as(usize, 7), Range.resolve(.{ .offset = 3, .size = 7 }, 10).?.len);
    try testing.expectEqual(@as(usize, 7), Range.resolve(.{ .offset = 3, .size = 159 }, 10).?.len); // icat 탐침 모양
    try testing.expect(Range.resolve(.{ .offset = 11, .size = 0 }, 10) == null);
    try testing.expectEqual(@as(usize, 0), Range.resolve(.{ .offset = 10, .size = 0 }, 10).?.len);
}

test "t=f: 일반 파일의 [O, O+S) 를 읽어 픽셀이 되고, 파일은 남는다; 짧은 파일·디렉터리·상한 초과는 EBADF" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = testing.io;
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    // 헤더 4 바이트 + 2x1 RGBA 8 바이트 + 꼬리 2 바이트.
    try tmp.dir.writeFile(io, .{ .sub_path = "px.bin", .data = "HDR!" ++ "\xff\x00\x00\xff" ++ "\x00\xff\x00\xff" ++ "zz" });
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/px.bin", .{root});
    const payload = try b64(a, path);
    defer a.free(payload);

    const ok = readAndDecode(io, a, &jobFor('f', payload, 32, 2, 1, 8, 4), 1 << 20);
    switch (ok) {
        .pixels => |px| {
            defer a.free(px.data);
            try testing.expectEqual(@as(usize, 8), px.data.len);
            try testing.expectEqual(@as(u8, 0xff), px.data[0]);
            try testing.expectEqual(@as(u8, 0xff), px.data[5]);
        },
        else => return error.TestUnexpectedResult,
    }
    try tmp.dir.access(io, "px.bin", .{}); // t=f 는 지우지 않는다

    // S 가 파일을 넘는다 → 있는 데까지(10 바이트) 읽고 넘치는 2 바이트는 코어가 버린다 → OK(icat 탐침 모양).
    switch (readAndDecode(io, a, &jobFor('f', payload, 32, 2, 1, 159, 4), 1 << 20)) {
        .pixels => |px| {
            defer a.free(px.data);
            try testing.expectEqual(@as(usize, 8), px.data.len);
            try testing.expectEqual(@as(u8, 0xff), px.data[0]);
        },
        else => return error.TestUnexpectedResult,
    }
    // O 가 파일 밖 → EBADF.
    try testing.expect(readAndDecode(io, a, &jobFor('f', payload, 32, 2, 1, 0, 99), 1 << 20) == .unreadable);
    // S=0 (끝까지) 로 14 바이트 → 앞 8 바이트가 픽셀, 나머지는 버린다(헤더가 앞이면 O 로 건너뛰는 것이 앱 몫).
    switch (readAndDecode(io, a, &jobFor('f', payload, 32, 2, 1, 0, 0), 1 << 20)) {
        .pixels => |px| {
            defer a.free(px.data);
            try testing.expectEqualStrings("HDR!", px.data[0..4]); // 앞 8 바이트 = "HDR!" + 빨강 픽셀
        },
        else => return error.TestUnexpectedResult,
    }
    // 픽셀 수보다 **모자라면** EINVAL.
    try testing.expect(readAndDecode(io, a, &jobFor('f', payload, 32, 2, 1, 5, 4), 1 << 20) == .invalid);
    // 상한보다 크다 → EBADF(읽기 전에 거른다).
    try testing.expect(readAndDecode(io, a, &jobFor('f', payload, 32, 2, 1, 8, 4), 7) == .unreadable);
    // 디렉터리는 일반 파일이 아니다.
    const dir_payload = try b64(a, root);
    defer a.free(dir_payload);
    try testing.expect(readAndDecode(io, a, &jobFor('f', dir_payload, 32, 2, 1, 8, 4), 1 << 20) == .unreadable);
    // 없는 파일.
    const missing = try b64(a, "/nonexistent/tty-graphics-protocol-x");
    defer a.free(missing);
    try testing.expect(readAndDecode(io, a, &jobFor('f', missing, 32, 2, 1, 8, 4), 1 << 20) == .unreadable);
    // 매체 글자가 틀리면 못 읽는다.
    try testing.expect(readAndDecode(io, a, &jobFor('x', payload, 32, 2, 1, 8, 4), 1 << 20) == .unreadable);
}

test "t=t: 임시 디렉터리 + 표식이 있는 파일만 읽은 뒤 지운다 — 표식 없음·임시 밖은 읽되 남긴다" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = testing.io;
    const a = testing.allocator;
    // (1) TMPDIR 안 + 표식 → 지워진다. TMPDIR 을 우리 tmp 로 돌린다(실제 /tmp 를 안 건드린다).
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    const rootz = try a.dupeZ(u8, root);
    defer a.free(rootz);
    const saved = if (std.c.getenv("TMPDIR")) |v| try a.dupeZ(u8, std.mem.span(v)) else null;
    defer if (saved) |v| a.free(v);
    _ = setenv("TMPDIR", rootz.ptr, 1);
    // 되돌릴 때 `unsetenv` 를 안 쓴다 — std 가 붙잡은 envp 조각이 stale 이 되어 다음 `std.log` 가 죽는다
    // (`session_host/std_environ_view.zig` 머리말). 빈 값은 이 모듈이 «없음» 으로 읽는다.
    defer _ = setenv("TMPDIR", if (saved) |v| v.ptr else "", 1);
    const pixels = "\xff\x00\x00\xff" ++ "\x00\xff\x00\xff";
    try tmp.dir.writeFile(io, .{ .sub_path = "kitty-tty-graphics-protocol-1", .data = pixels });
    try tmp.dir.writeFile(io, .{ .sub_path = "plain-1", .data = pixels });
    var p1: [std.fs.max_path_bytes]u8 = undefined;
    const marked = try b64(a, try std.fmt.bufPrint(&p1, "{s}/kitty-tty-graphics-protocol-1", .{root}));
    defer a.free(marked);
    var p2: [std.fs.max_path_bytes]u8 = undefined;
    const plain = try b64(a, try std.fmt.bufPrint(&p2, "{s}/plain-1", .{root}));
    defer a.free(plain);

    const r1 = readAndDecode(io, a, &jobFor('t', marked, 32, 2, 1, 0, 0), 1 << 20);
    switch (r1) {
        .pixels => |px| a.free(px.data),
        else => return error.TestUnexpectedResult,
    }
    try testing.expectError(error.FileNotFound, tmp.dir.access(io, "kitty-tty-graphics-protocol-1", .{}));

    // (2) 표식이 없으면 읽되 남긴다.
    const r2 = readAndDecode(io, a, &jobFor('t', plain, 32, 2, 1, 0, 0), 1 << 20);
    switch (r2) {
        .pixels => |px| a.free(px.data),
        else => return error.TestUnexpectedResult,
    }
    try tmp.dir.access(io, "plain-1", .{});

    // (3) 표식은 있지만 임시 디렉터리 밖(TMPDIR 을 다른 곳으로) → 읽되 남긴다. 이것이 «원격이 보낸 한 줄로
    // 내 파일을 지운다» 를 막는 방어선이다.
    try tmp.dir.writeFile(io, .{ .sub_path = "kitty-tty-graphics-protocol-2", .data = pixels });
    _ = setenv("TMPDIR", "/nonexistent-tmp", 1);
    var p3: [std.fs.max_path_bytes]u8 = undefined;
    const outside = try b64(a, try std.fmt.bufPrint(&p3, "{s}/kitty-tty-graphics-protocol-2", .{root}));
    defer a.free(outside);
    const r3 = readAndDecode(io, a, &jobFor('t', outside, 32, 2, 1, 0, 0), 1 << 20);
    switch (r3) {
        .pixels => |px| a.free(px.data),
        else => return error.TestUnexpectedResult,
    }
    try tmp.dir.access(io, "kitty-tty-graphics-protocol-2", .{});
}

test "삭제 판정: 정규화된 루트로 비교한다(/tmp 심링크) — 접두만 같은 형제 디렉터리는 밖이다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const io = testing.io;
    // macOS: /tmp → /private/tmp. 정규 경로가 /private/tmp/… 이어도 루트 /tmp 와 맞아야 한다.
    try testing.expect(isDeletableTempPath(io, "/private/tmp/kitty-tty-graphics-protocol-9", null));
    try testing.expect(!isDeletableTempPath(io, "/private/tmp/kitty-9", null)); // 표식 없음
    try testing.expect(!isDeletableTempPath(io, "/private/tmpfoo/kitty-tty-graphics-protocol-9", null)); // 형제 디렉터리
    try testing.expect(!isDeletableTempPath(io, "/Users/x/kitty-tty-graphics-protocol-9", null)); // 홈
    // TMPDIR: 실제로 있는 디렉터리여야 정규화가 된다(없는 루트는 «밖»이다 — 열어서 realpath 를 얻는다).
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    const rootz = try testing.allocator.dupeZ(u8, root);
    defer testing.allocator.free(rootz);
    var in_buf: [std.fs.max_path_bytes]u8 = undefined;
    const inside = try std.fmt.bufPrint(&in_buf, "{s}/kitty-tty-graphics-protocol-9", .{root});
    try testing.expect(isDeletableTempPath(io, inside, rootz.ptr)); // TMPDIR 이 그곳이면 된다
    var sib_buf: [std.fs.max_path_bytes]u8 = undefined;
    const sibling = try std.fmt.bufPrint(&sib_buf, "{s}-sibling/kitty-tty-graphics-protocol-9", .{root});
    try testing.expect(!isDeletableTempPath(io, sibling, rootz.ptr)); // 접두만 같은 형제 — 밖
    try testing.expect(!isDeletableTempPath(io, inside, "/nonexistent-tmpdir")); // 없는 TMPDIR 은 아무것도 허용하지 않는다
}

test "t=s: 공유메모리를 [O, O+S) 로 읽고 unlink 한다; 없는 이름은 EBADF" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const a = testing.allocator;
    var name_buf: [64]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&name_buf, "/maru-kmt-{d}", .{std.c.getpid()});
    _ = std.c.shm_unlink(name.ptr);
    const fd = std.c.shm_open(name.ptr, @as(c_int, @bitCast(std.c.O{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true })), @as(std.c.mode_t, 0o600));
    if (fd < 0) return error.SkipZigTest;
    const content = "HDR!" ++ "\xff\x00\x00\xff" ++ "\x00\xff\x00\xff";
    if (std.c.ftruncate(fd, content.len) != 0) return error.TestUnexpectedResult;
    const m = try std.posix.mmap(null, content.len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
    @memcpy(m[0..content.len], content);
    std.posix.munmap(m);
    _ = std.c.close(fd);

    const payload = try b64(a, name);
    defer a.free(payload);
    const r = readAndDecode(testing.io, a, &jobFor('s', payload, 32, 2, 1, 8, 4), 1 << 20);
    switch (r) {
        .pixels => |px| {
            defer a.free(px.data);
            try testing.expectEqual(@as(usize, 8), px.data.len);
            try testing.expectEqual(@as(u8, 0xff), px.data[0]);
            try testing.expectEqual(@as(u8, 0x00), px.data[4]);
        },
        else => return error.TestUnexpectedResult,
    }
    // unlink 됐다 — 같은 이름을 다시 열면 없다.
    try testing.expect(std.c.shm_open(name.ptr, @as(c_int, @bitCast(std.c.O{ .ACCMODE = .RDONLY })), @as(std.c.mode_t, 0)) < 0);
    try testing.expect(readAndDecode(testing.io, a, &jobFor('s', payload, 32, 2, 1, 8, 4), 1 << 20) == .unreadable);
}

test "t=f + f=100: PNG 파일은 자기 치수로 디코드된다" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = testing.io;
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    try tmp.dir.writeFile(io, .{ .sub_path = "a.png", .data = &red_2x1_png });
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const payload = try b64(a, try std.fmt.bufPrint(&path_buf, "{s}/a.png", .{root}));
    defer a.free(payload);
    const r = readAndDecode(io, a, &jobFor('f', payload, 100, 0, 0, 0, 0), 1 << 20);
    switch (r) {
        .pixels => |px| {
            defer a.free(px.data);
            try testing.expectEqual(@as(u32, 2), px.width);
            try testing.expectEqual(@as(u32, 1), px.height);
            try testing.expectEqual(@as(u8, 255), px.data[0]);
        },
        else => return error.TestUnexpectedResult,
    }
}

/// 2x1 RGBA PNG(빨강·초록). `zig` 로 만든 최소 파일 — 바이트는 판정자 안에서만 쓴다.
const red_2x1_png = [_]u8{
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0xF4, 0x22, 0x7F,
    0x8A, 0x00, 0x00, 0x00, 0x0E, 0x49, 0x44, 0x41, 0x54, 0x78, 0xDA, 0x63, 0xF8, 0xCF, 0xC0, 0xF0,
    0x1F, 0x04, 0x01, 0x10, 0xF8, 0x03, 0xFD, 0x53, 0xFD, 0x8F, 0x19, 0x00, 0x00, 0x00, 0x00, 0x49,
    0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
};

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
