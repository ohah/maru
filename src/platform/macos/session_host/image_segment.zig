//! 이미지 채널 세그먼트 만들기 — 픽셀을 읽기 전용 공유 메모리 fd 하나로 바꾼다.
//!
//! 단일 출처는 [Session host 이미지 채널](../../../../docs/session-host-image-channel.md) §4.1 이다. 순서가 뜻을 만든다:
//!
//!   1. `shm_open(랜덤 이름, O_RDWR|O_CREAT|O_EXCL, 0600)` — 남의 객체를 열지 않게 EXCL.
//!   2. `ftruncate(byte_len)` — macOS 는 크기를 한 번만 정할 수 있다.
//!   3. 같은 이름을 `O_RDONLY` 로 다시 연다 — 앱에 넘길 것은 이 fd 다. 받는 쪽은 쓰기 매핑을 만들 수 없다(EPERM, 실측).
//!   4. `shm_unlink` — 이름이 사라져도 객체는 fd 가 살아 있는 동안 산다. 이름을 남기지 않으므로 host 가 죽어도
//!      `/dev/shm` 같은 곳에 고아가 남지 않는다.
//!   5. RW 매핑에 픽셀을 복사하고 RW 매핑·fd 를 놓는다. 남는 것은 읽기 전용 fd 하나다.
//!
//! `shm_open` 의 fd 는 FD_CLOEXEC 가 기본으로 켜져 있어 PTY 자식과 업그레이드 exec 로 새지 않는다(`O_CLOEXEC` 를
//! 플래그로 넘기면 macOS `shm_open` 이 실패한다 — 그래서 넘기지 않는다). 픽셀이 0 B 이면 세그먼트를 만들지 않는다.
//!
//! 이 파일은 fd 를 만들 뿐 소유하지 않는다. 돌려준 fd 는 배치 준비물이 쥐고, 이미지 채널로 보낸 뒤 host 가 닫는다(§4.2).

const std = @import("std");
const builtin = @import("builtin");

const c = std.c;

/// 읽기 전용 공유 메모리 fd 와 그 안의 픽셀 길이. 호출자가 fd 를 닫는다.
pub const Segment = struct {
    fd: c.fd_t,
    byte_len: u32,
};

pub const CreateError = error{
    /// 픽셀 길이가 `image_ref.byte_len`(u32)을 넘는다.
    TooLarge,
    /// 랜덤 이름이 거듭 남의 객체와 겹쳤다.
    NameCollision,
    /// `shm_open` 실패(자원 고갈 등).
    OpenFailed,
    /// `ftruncate` 실패.
    ResizeFailed,
    /// 읽기 전용으로 다시 열지 못했다.
    ReopenFailed,
    /// 복사할 RW 매핑을 못 만들었다.
    MapFailed,
};

/// macOS 공유 메모리 이름 상한(`PSHMNAMLEN`)은 31 자다. 넘으면 `ENAMETOOLONG`.
const name_max: usize = 31;
const name_prefix = "/maru-is-";
const name_len = name_prefix.len + 16;

comptime {
    if (name_len > name_max) @compileError("shared memory segment names must fit PSHMNAMLEN (31)");
}

const name_attempts: usize = 4;

/// 픽셀을 새 세그먼트에 담아 읽기 전용 fd 를 돌려준다. 픽셀이 비면 `null` — 세그먼트가 없다.
pub fn create(pixels: []const u8) CreateError!?Segment {
    if (pixels.len == 0) return null;
    var attempt: usize = 0;
    while (attempt < name_attempts) : (attempt += 1) {
        var name: [name_len:0]u8 = undefined;
        randomName(&name);
        return createNamed(&name, pixels) catch |err| switch (err) {
            error.NameCollision => continue,
            else => return err,
        };
    }
    return error.NameCollision;
}

fn randomName(out: *[name_len:0]u8) void {
    var raw: [8]u8 = undefined;
    c.arc4random_buf(&raw, raw.len);
    @memcpy(out[0..name_prefix.len], name_prefix);
    _ = std.fmt.bufPrint(out[name_prefix.len..], "{x}", .{&raw}) catch unreachable;
    out[name_len] = 0;
}

/// 이름을 정해 만든다 — 판정자가 「이름이 남지 않는다」를 재려고 이름을 알아야 해서 따로 둔다.
fn createNamed(name: [*:0]const u8, pixels: []const u8) CreateError!?Segment {
    if (pixels.len == 0) return null;
    if (pixels.len > std.math.maxInt(u32)) return error.TooLarge;
    const rw = c.shm_open(name, @as(c_int, @bitCast(c.O{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true })), @as(c.mode_t, 0o600));
    if (rw < 0) return if (std.posix.errno(rw) == .EXIST) error.NameCollision else error.OpenFailed;
    defer _ = c.close(rw);
    // 열기에 성공한 순간부터 이름은 이 함수가 지운다 — 어느 단계에서 실패해도 이름이 남지 않는다.
    var unlinked = false;
    defer if (!unlinked) {
        _ = c.shm_unlink(name);
    };
    if (c.ftruncate(rw, @intCast(pixels.len)) != 0) return error.ResizeFailed;
    const ro = c.shm_open(name, @as(c_int, @bitCast(c.O{ .ACCMODE = .RDONLY })), @as(c.mode_t, 0));
    if (ro < 0) return error.ReopenFailed;
    errdefer _ = c.close(ro);
    _ = c.shm_unlink(name);
    unlinked = true;
    const mapped = std.posix.mmap(null, pixels.len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, rw, 0) catch
        return error.MapFailed;
    defer std.posix.munmap(mapped);
    @memcpy(mapped[0..pixels.len], pixels);
    return .{ .fd = ro, .byte_len = @intCast(pixels.len) };
}

// ── 판정자 ────────────────────────────────────────────────────────────────────
//
// 앱은 이 fd 를 믿고 매핑한다. 쓰기 가능한 fd 가 나가면 앱(또는 그 fd 를 물려받은 자식)이 host 와 다른 판을 그릴 수
// 있고, 이름이 남으면 host 가 죽을 때마다 커널 객체가 쌓이고, CLOEXEC 가 꺼져 있으면 host 의 PTY 자식이 이미지 픽셀을
// 물려받는다.

const testing = std.testing;

fn testPixels(comptime n: usize) [n]u8 {
    var out: [n]u8 = undefined;
    for (&out, 0..) |*b, i| b.* = @truncate(i *% 31 +% 7);
    return out;
}

test "이미지 세그먼트: 픽셀이 읽기 전용 fd 로 그대로 건너간다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const pixels = testPixels(64 * 1024 + 3); // 페이지 배수가 아닌 길이
    const segment = (try create(&pixels)) orelse return error.TestUnexpectedResult;
    defer _ = c.close(segment.fd);
    try testing.expectEqual(@as(u32, pixels.len), segment.byte_len);
    const view = try std.posix.mmap(null, pixels.len, .{ .READ = true }, .{ .TYPE = .SHARED }, segment.fd, 0);
    defer std.posix.munmap(view);
    try testing.expectEqualSlices(u8, &pixels, view[0..pixels.len]);
}

test "이미지 세그먼트: 돌려준 fd 로는 쓰기 매핑을 만들 수 없다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const pixels = testPixels(4096);
    const segment = (try create(&pixels)) orelse return error.TestUnexpectedResult;
    defer _ = c.close(segment.fd);
    const flags = c.fcntl(segment.fd, c.F.GETFL, @as(c_int, 0));
    try testing.expect(flags >= 0);
    try testing.expectEqual(@as(c_int, 0), flags & 3); // O_ACCMODE == O_RDONLY
    if (std.posix.mmap(null, pixels.len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, segment.fd, 0)) |m| {
        std.posix.munmap(m);
        return error.TestUnexpectedResult;
    } else |_| {}
}

test "이미지 세그먼트: fd 는 exec 로 새지 않고 이름은 남지 않는다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const pixels = testPixels(128);
    var name: [name_len:0]u8 = undefined;
    randomName(&name);
    const segment = (try createNamed(&name, &pixels)) orelse return error.TestUnexpectedResult;
    defer _ = c.close(segment.fd);
    const fd_flags = c.fcntl(segment.fd, c.F.GETFD, @as(c_int, 0));
    try testing.expect(fd_flags >= 0);
    try testing.expect(fd_flags & c.FD_CLOEXEC != 0);
    // 이름은 이미 지워졌다 — 같은 이름을 다시 열 수 없다.
    const again = c.shm_open(&name, @as(c_int, @bitCast(c.O{ .ACCMODE = .RDONLY })), @as(c.mode_t, 0));
    if (again >= 0) {
        _ = c.close(again);
        return error.TestUnexpectedResult;
    }
    try testing.expectEqual(c.E.NOENT, std.posix.errno(again));
}

test "이미지 세그먼트: 이름이 남의 객체와 겹치면 그 객체를 건드리지 않고 겹침으로 보고한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var name: [name_len:0]u8 = undefined;
    randomName(&name);
    const theirs = c.shm_open(&name, @as(c_int, @bitCast(c.O{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true })), @as(c.mode_t, 0o600));
    if (theirs < 0) return error.SkipZigTest;
    defer {
        _ = c.close(theirs);
        _ = c.shm_unlink(&name);
    }
    const pixels = testPixels(16);
    try testing.expectError(error.NameCollision, createNamed(&name, &pixels));
    // 남의 이름을 지우지 않았다.
    const still = c.shm_open(&name, @as(c_int, @bitCast(c.O{ .ACCMODE = .RDONLY })), @as(c.mode_t, 0));
    try testing.expect(still >= 0);
    _ = c.close(still);
}

test "이미지 세그먼트: 픽셀이 0 B 이면 세그먼트를 만들지 않는다" {
    try testing.expect((try create(&.{})) == null);
}
