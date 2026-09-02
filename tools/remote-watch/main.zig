//! **원격 감시자**(RW1 — [계획](../../docs/plans/remote-watch.md)). 원격에서 저장소가 바뀌면
//! stdout 에 `change` 한 줄을 낸다. 그 줄을 받은 maru 가 **자기 읽기 파이프라인을 다시 건다** —
//! 이 프로그램은 git 을 돌리지도, 무엇이 바뀌었는지 말하지도 않는다(계약 §2 「트리거만 바꾼다」).
//!
//! ## 왜 셸이 아니라 바이너리인가
//!
//! 감시 API 는 셸에서 못 부른다 — FSEvents 는 C 호출, inotify·kqueue 는 syscall 이고, 그 CLI 래퍼
//! (`inotifywait`·`fswatch`)는 **기본 설치가 아니다**(계획 §3 실측). 셸로 가면 폴링이 천장이다.
//!
//! ## 고아를 남기지 않는다 — 이 파일의 가장 중요한 계약
//!
//! 감시자는 **설계상 조용하다**(바뀔 때만 출력). 그래서 「쓸 때 EPIPE 로 죽는다」에 기댈 수 없고,
//! 실측에서 **조용한 프로세스는 ssh 채널이 끊겨도 살아남았다**(계획 §5). 남의 서버에 무한 루프를
//! 쌓는 것이 이 트랙의 최악 실패이므로, **stdin 을 감시 대기와 같은 자리에 넣고 EOF 면 종료한다.**
//!
//! ⚠️ 그래서 호출자는 **채널의 stdin 을 열어 둬야 한다.** 닫힌 채로 띄우면 뜨자마자 죽는다.

const std = @import("std");
const builtin = @import("builtin");

/// 한도 초과로 **일부만 감시하게 된** 경우의 종료 코드. 호출자는 이 값을 보고 폴링으로 내려간다
/// (계획 §RW5) — 반쪽만 감시하면서 최신인 척하는 것이 최악이라 **조용히 계속하지 않는다.**
pub const exit_watch_limit: u8 = 2;
/// 감시 API 자체를 못 열었다(플랫폼 미지원 등). 호출자는 설치를 실패로 보고 현행 동작을 유지한다.
pub const exit_unsupported: u8 = 3;

/// 한 번에 등록할 디렉터리 상한. 넘으면 `exit_watch_limit` 으로 나간다 — 넘는 순간 이 프로그램이
/// 아는 것은 「전부는 못 본다」뿐이고, 그 사실을 **말해야** 호출자가 폴링으로 갈아탄다.
const max_dirs: usize = 65_536;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    const root = args.next() orelse return exitWith(exit_unsupported);

    var dirs: std.ArrayList([]u8) = .empty;
    defer {
        for (dirs.items) |d| init.gpa.free(d);
        dirs.deinit(init.gpa);
    }
    collect(io, init.gpa, root, &dirs) catch {};
    // **0 개는 「볼 것이 없다」가 아니라 「못 봤다」다** — 루트를 못 열었다는 뜻이라 폴백해야 한다.
    if (dirs.items.len == 0) return exitWith(exit_unsupported);
    if (dirs.items.len > max_dirs) return exitWith(exit_watch_limit);

    switch (builtin.os.tag) {
        .linux => try watchLinux(init.gpa, dirs.items),
        .macos, .freebsd, .netbsd, .openbsd, .dragonfly => try watchKqueue(init.gpa, dirs.items),
        else => return exitWith(exit_unsupported),
    }
}

fn exitWith(code: u8) noreturn {
    std.process.exit(code);
}

/// 루트 아래 디렉터리를 모은다. **`st_mode` 로 판정한다** — `nftw` 의 `FTW_D` 는 libc 마다 값이 달라
/// (glibc 1 · musl 2) 상수를 박으면 **조용히 아무것도 감시하지 않는다**(실측에서 그렇게 당했다).
/// `std.Io.Dir` 의 항목 종류를 쓰면 그 판정을 libc 가 아니라 std 가 진다.
fn collect(io: std.Io, gpa: std.mem.Allocator, root: []const u8, out: *std.ArrayList([]u8)) !void {
    if (out.items.len >= max_dirs) return;
    var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return;
    defer dir.close(io);
    try out.append(gpa, try gpa.dupe(u8, root));

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        // `.git` 은 **본다**(index·HEAD 가 바뀌는 자리다). 빌드 산출물은 호출자가 정할 일이라
        // 여기서 목록을 박지 않는다 — 박으면 저장소마다 다른 규칙을 이 바이너리가 지게 된다.
        const child = try std.fs.path.join(gpa, &.{ root, entry.name });
        defer gpa.free(child);
        try collect(io, gpa, child, out);
        if (out.items.len >= max_dirs) return;
    }
}

/// 바뀌었다고 한 줄 낸다. **쓰기가 실패하면 종료한다** — 채널이 끊긴 것이고, 계속 돌면 고아가 된다.
fn announce() bool {
    const sys = std.posix.system;
    var left: usize = 7;
    const msg = "change\n";
    while (left > 0) {
        const rc = sys.write(1, msg[7 - left ..].ptr, left);
        const n: isize = @bitCast(rc);
        if (n <= 0) return false;
        left -= @intCast(n);
    }
    return true;
}

/// 리눅스: inotify 인스턴스 **하나**에 디렉터리마다 watch 를 건다(watch 는 fd 가 아니다 — 한도는
/// `max_user_watches` 이지 `ulimit -n` 이 아니다, 계획 §6). 그 fd 와 **stdin 을 함께 `poll`** 한다.
fn watchLinux(gpa: std.mem.Allocator, dirs: []const []u8) !void {
    const linux = std.os.linux;
    const ifd: i32 = @intCast(linux.inotify_init1(0));
    if (ifd < 0) return exitWith(exit_unsupported);
    const mask: u32 = linux.IN.MODIFY | linux.IN.CREATE | linux.IN.DELETE |
        linux.IN.MOVED_TO | linux.IN.MOVED_FROM | linux.IN.ATTRIB;
    for (dirs) |d| {
        const z = try gpa.dupeZ(u8, d);
        defer gpa.free(z);
        const wd: isize = @bitCast(linux.inotify_add_watch(ifd, z, mask));
        // ENOSPC = `max_user_watches` 소진. **일부만 보고 계속하지 않는다**(§RW5).
        if (wd < 0) return exitWith(exit_watch_limit);
    }
    var fds = [_]std.posix.pollfd{
        .{ .fd = ifd, .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = 0, .events = std.posix.POLL.IN, .revents = 0 }, // 채널이 끊기면 여기서 걸린다
    };
    var buf: [8192]u8 = undefined;
    while (true) {
        _ = std.posix.poll(&fds, -1) catch return;
        if (fds[1].revents != 0) return; // stdin EOF/HUP → 종료(고아 방지)
        if (fds[0].revents == 0) continue;
        const rc = std.posix.system.read(ifd, &buf, buf.len);
        const n: isize = @bitCast(rc);
        if (n <= 0) return;
        // **이벤트를 세지 않는다.** 무엇이 몇 개 바뀌었는지는 호출자가 다시 읽어 알아낸다 —
        // 여기서 해석하면 파싱 계약이 두 벌이 된다(계약 §2).
        if (!announce()) return;
    }
}

/// macOS·BSD: kqueue 는 **디렉터리마다 fd 를 연다**(그래서 한도가 `ulimit -n` 이다, 계획 §6).
/// stdin 은 `EVFILT_READ` 로 같은 kqueue 에 넣어 EOF 를 함께 받는다.
fn watchKqueue(gpa: std.mem.Allocator, dirs: []const []u8) !void {
    const c = std.c;
    const kq = c.kqueue();
    if (kq < 0) return exitWith(exit_unsupported);
    var change: [1]c.Kevent = undefined;
    for (dirs) |d| {
        const z = try gpa.dupeZ(u8, d);
        defer gpa.free(z);
        // `O_EVTONLY` — 「이벤트만 받으려고 연다」는 뜻이라 언마운트를 막지 않는다.
        const fd = std.c.open(z, .{ .ACCMODE = .RDONLY, .EVTONLY = true });
        if (fd < 0)
            return exitWith(exit_watch_limit); // EMFILE = fd 소진(§6 — kqueue 의 한도는 `ulimit -n` 이다)
        change[0] = .{
            .ident = @intCast(fd),
            .filter = c.EVFILT.VNODE,
            .flags = c.EV.ADD | c.EV.CLEAR,
            .fflags = c.NOTE.WRITE | c.NOTE.DELETE | c.NOTE.RENAME | c.NOTE.EXTEND | c.NOTE.ATTRIB,
            .data = 0,
            .udata = 0,
        };
        if (c.kevent(kq, &change, 1, undefined, 0, null) < 0) return exitWith(exit_watch_limit);
    }
    // stdin 을 **같은 kqueue** 에 — 채널이 끊기면 여기서 온다(고아 방지).
    change[0] = .{
        .ident = 0,
        .filter = c.EVFILT.READ,
        .flags = c.EV.ADD | c.EV.CLEAR,
        .fflags = 0,
        .data = 0,
        .udata = 0,
    };
    _ = c.kevent(kq, &change, 1, undefined, 0, null);
    var out: [16]c.Kevent = undefined;
    while (true) {
        const n = c.kevent(kq, undefined, 0, &out, out.len, null);
        if (n <= 0) return;
        for (out[0..@intCast(n)]) |ev| {
            if (ev.filter == c.EVFILT.READ) return; // stdin → 종료
        }
        // **이벤트를 세지 않는다** — 무엇이 바뀌었는지는 호출자가 다시 읽어 알아낸다(계약 §2).
        if (!announce()) return;
    }
}
