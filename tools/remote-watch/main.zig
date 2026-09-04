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
/// `--version` 이 내는 줄. 설치 쪽이 **이 문자열로** 「우리 것이고 이 판이다」를 확인한다 —
/// 판이 바뀌면 여기를 올리고, 그러면 옛 판이 깔린 원격은 다음 설치에서 갈린다.
pub const version_line = "maru-remote-watch 1\n";

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

    // **멱등 확인용 진입점.** 설치 쪽은 「이미 있고 **돌아가는가**」를 물어야 한다 — 파일 존재만 보면
    // 아키텍처가 틀린 바이너리나 잘린 파일을 「설치됨」으로 읽는다(그러면 감시가 조용히 안 된다).
    // 실제로 실행해 보는 것이 그 둘을 함께 가른다.
    if (std.mem.eql(u8, root, "--version")) {
        _ = std.posix.system.write(1, version_line.ptr, version_line.len);
        return;
    }

    var dirs: std.ArrayList([]u8) = .empty;
    defer {
        for (dirs.items) |d| init.gpa.free(d);
        dirs.deinit(init.gpa);
    }
    // ⚠️ **실패를 삼키지 않는다**(적대적 검증 2026-09-04 15 회차). `collect` 는 못 여는 디렉터리를
    // 건너뛰는 것과 별개로 OOM 이면 **도중에** 멈춘다 — 그때 `catch {}` 로 넘어가면 남은 절반을 「전부」
    // 로 알고 무장해, §6 이 「최악」이라 못 박은 조용한 반쪽 감시가 된다. 못 하면 못 한다고 말한다.
    collect(io, init.gpa, root, &dirs) catch return exitWith(exit_unsupported);
    // **0 개는 「볼 것이 없다」가 아니라 「못 봤다」다** — 루트를 못 열었다는 뜻이라 폴백해야 한다.
    if (dirs.items.len == 0) return exitWith(exit_unsupported);
    // ⚠️ **「닿았다」로 묻는다 — 「넘었다」로 물으면 영원히 거짓이다**(적대적 검증 2026-09-04 12 회차).
    // `collect` 는 `>= max_dirs` 에서 «멈추므로» 이 값은 `max_dirs` 를 절대 넘지 않는다. 앞 판은 `>` 로
    // 물어서 이 보고가 **죽은 코드**였고, 그래서 상한을 넘는 저장소가 §6 이 「최악」이라 못 박은 상태 —
    // **조용히 반쪽만 감시** — 로 들어갔다. 판정자는 문자열만 봐서 그것을 못 봤다.
    if (dirs.items.len >= max_dirs) return exitWith(exit_watch_limit);

    switch (builtin.os.tag) {
        .linux => try watchLinux(io, init.gpa, root, &dirs),
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
///
/// ⚠️ **디렉터리가 새로 생기면 다시 무장한다**(적대적 검증 2026-09-04 14 회차 — 실측). inotify 는
/// 새 디렉터리를 자동으로 안 본다. 시작할 때 걸어 둔 것만 보므로, 그냥 두면:
///
/// | 동작 | 알림 |
/// |---|---|
/// | 새 디렉터리 생성 | 1 (부모에서 온다) |
/// | **그 안에 파일 생성** | **0** |
/// | **그 안의 파일 수정** | **0** |
///
/// `git checkout` 이 디렉터리를 만드는 브랜치로 옮기거나 새 모듈을 만들면 그 뒤 편집이 통째로 안
/// 보인다 — §6 이 「최악」이라 못 박은 조용한 반쪽 감시다.
fn watchLinux(io: std.Io, gpa: std.mem.Allocator, root: []const u8, dirs: *std.ArrayList([]u8)) !void {
    const linux = std.os.linux;
    const ifd: i32 = @intCast(linux.inotify_init1(0));
    if (ifd < 0) return exitWith(exit_unsupported);
    var fds = [_]std.posix.pollfd{
        .{ .fd = ifd, .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = 0, .events = std.posix.POLL.IN, .revents = 0 }, // 채널이 끊기면 여기서 걸린다
    };
    try armLinux(gpa, ifd, dirs.items);
    var buf: [8192]u8 = undefined;
    while (true) {
        _ = std.posix.poll(&fds, -1) catch return;
        if (fds[1].revents != 0) return; // stdin EOF/HUP → 종료(고아 방지)
        if (fds[0].revents == 0) continue;
        const rc = std.posix.system.read(ifd, &buf, buf.len);
        const n: isize = @bitCast(rc);
        if (n <= 0) return;
        // **이벤트를 세지도, 경로를 읽지도 않는다.** 무엇이 몇 개 바뀌었는지는 호출자가 다시 읽어
        // 알아낸다(계약 §2). 여기서 보는 것은 **비트 하나** — 「디렉터리가 관련됐는가」뿐이고, 그것은
        // 파싱 계약이 아니라 **다시 무장해야 하는가**라는 이 프로세스 안의 질문이다.
        if (sawDirEvent(buf[0..@intCast(n)])) {
            for (dirs.items) |d| gpa.free(d);
            dirs.clearRetainingCapacity();
            collect(io, gpa, root, dirs) catch return exitWith(exit_unsupported);
            if (dirs.items.len == 0) return exitWith(exit_unsupported);
            if (dirs.items.len >= max_dirs) return exitWith(exit_watch_limit);
            // 이미 걸린 경로에 다시 걸면 **같은 wd 를 돌려준다** — 그래서 전부 다시 거는 것이 안전하고,
            // 어느 것이 새것인지 알 필요가 없다(그걸 알려면 wd→경로 표를 지어야 한다).
            try armLinux(gpa, ifd, dirs.items);
        }
        if (!announce()) return;
    }
}

/// 목록의 디렉터리마다 watch 를 건다. **멱등이다** — 같은 경로면 같은 wd 가 온다.
fn armLinux(gpa: std.mem.Allocator, ifd: i32, dirs: []const []u8) !void {
    const linux = std.os.linux;
    const mask: u32 = linux.IN.MODIFY | linux.IN.CREATE | linux.IN.DELETE |
        linux.IN.MOVED_TO | linux.IN.MOVED_FROM | linux.IN.ATTRIB;
    for (dirs) |d| {
        const z = try gpa.dupeZ(u8, d);
        defer gpa.free(z);
        const wd: isize = @bitCast(linux.inotify_add_watch(ifd, z, mask));
        // ENOSPC = `max_user_watches` 소진. **일부만 보고 계속하지 않는다**(§RW5).
        if (wd < 0) return exitWith(exit_watch_limit);
    }
}

/// 이 배치에 **디렉터리가 얽힌 이벤트**가 있었나. `struct inotify_event` 는 `{ i32 wd; u32 mask;
/// u32 cookie; u32 len; }` 뒤에 `len` 바이트 이름이 붙는 가변 길이라, 그 머리만 훑는다.
fn sawDirEvent(bytes: []const u8) bool {
    const header = 16;
    const in_isdir: u32 = 0x4000_0000;
    var off: usize = 0;
    while (off + header <= bytes.len) {
        const mask = std.mem.bytesToValue(u32, bytes[off + 4 ..][0..4]);
        const len = std.mem.bytesToValue(u32, bytes[off + 12 ..][0..4]);
        if (mask & in_isdir != 0) return true;
        off += header + len;
    }
    return false;
}

/// macOS·BSD: **못 한다고 말한다**(적대적 검증 2026-09-04 13 회차 — 실측).
///
/// ⚠️ kqueue 의 `EVFILT_VNODE` 를 **디렉터리**에 걸면 「그 디렉터리 자체」의 변화만 온다. 실측(같은
/// 디렉터리에서 하나씩):
///
/// | 동작 | 알림 |
/// |---|---|
/// | 파일 내용 수정(append) | **0** |
/// | 파일 덮어쓰기 | **0** |
/// | `touch`(mtime) · `chmod` | **0** |
/// | 새 파일 · 삭제 · 이름 바꾸기 | 1 |
///
/// 즉 **가장 흔한 경우인 「파일을 고쳤다」가 안 온다.** 그런데 만들기·지우기는 오므로 화면은 「살아
/// 있는」 것처럼 보인다 — 계획 §6 이 「최악」이라 못 박은 **조용히 반쪽만 감시**가 바로 이것이다.
///
/// **파일마다 fd 를 여는 길은 닫혀 있다.** maru3 하나가 파일 29,694 개인데(디렉터리는 4,595 개),
/// 리눅스의 흔한 `ulimit -Sn` 은 1,024 다(§6 실측). 제대로 하려면 macOS 는 FSEvents 가 필요한데
/// 그것은 CoreServices + run loop 라 이 작은 바이너리의 모양이 아니다 — **후속으로 남긴다.**
///
/// 그래서 지금은 `exit_unsupported` 다. RW5 가 다시 안 띄우고 RW6 이 사용자에게 말하며, 화면은
/// 포커스·새로고침으로 돌아간다. **반쪽을 최신인 척하는 것보다 낫다.**
fn watchKqueue(gpa: std.mem.Allocator, dirs: []const []u8) !void {
    _ = gpa;
    _ = dirs;
    return exitWith(exit_unsupported);
}

/// 위가 되살아날 때 쓸 자리 — **지금은 안 부른다.** 지우지 않는 이유는 FSEvents 로 갈아탈 때
/// stdin 결속(`EVFILT_READ`)과 종료 규율이 그대로 필요하기 때문이다.
fn watchKqueueDirs(gpa: std.mem.Allocator, dirs: []const []u8) !void {
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
