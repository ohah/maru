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

extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

/// 한도 초과로 **일부만 감시하게 된** 경우의 종료 코드. 호출자는 이 값을 보고 폴링으로 내려간다
/// (계획 §RW5) — 반쪽만 감시하면서 최신인 척하는 것이 최악이라 **조용히 계속하지 않는다.**
/// `--version` 이 내는 줄. 설치 쪽이 **이 문자열로** 「우리 것이고 이 판이다」를 확인한다 —
/// 판이 바뀌면 여기를 올리고, 그러면 옛 판이 깔린 원격은 다음 설치에서 갈린다.
pub const version_line = "maru-remote-watch 2\n";

/// **판 2 부터는 내지 않는다**(RW7d — 한도에서 폴링으로 내려간다). 상수를 남겨 두는 이유는 원격에
/// 아직 **판 1 바이너리가 도는 경우**가 있어서다 — 그쪽은 여전히 이 코드로 나가고, 앱은 그것을
/// 「영구 실패」로 읽어야 한다(판이 갈리면 다음 설치에서 바뀐다).
pub const exit_watch_limit: u8 = 2;
/// 감시 API 자체를 못 열었다(플랫폼 미지원 등). 호출자는 설치를 실패로 보고 현행 동작을 유지한다.
pub const exit_unsupported: u8 = 3;

/// 한 번에 등록할 디렉터리 상한. **넘으면 폴링으로 내려간다**(RW7d) — 넘는 순간 이 프로그램이 아는
/// 것은 「전부는 못 본다」뿐이고, 반쪽을 최신인 척 보여 주는 것이 최악이기 때문이다(계획 §6).
/// 예전에는 여기서 `exit_watch_limit` 으로 나갔고 앱이 포기했다(RW5). 이제 폴링이 있으니 **잃는 것은
/// 지연뿐**이라 포기할 이유가 없다.
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

    // 루트 뒤에 오는 것은 **굳히기까지 끝난 git 앞머리**다(RW7b — `ssh_upload.spawnRemoteWatch` 가
    // `git_command.config_overrides` 를 그대로 실어 보낸다). 없으면 폴링을 못 한다.
    var git_prefix: std.ArrayList([]const u8) = .empty;
    defer git_prefix.deinit(init.gpa);
    while (args.next()) |a| try git_prefix.append(init.gpa, a);

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
    // **한도를 넘으면 폴링이다**(RW7d) — 나가지 않는다. 폴링도 못 하면 그때 말한다.
    const over_limit = dirs.items.len >= max_dirs;

    switch (builtin.os.tag) {
        .linux => if (over_limit)
            try watchPoll(init.gpa, root, git_prefix.items)
        else
            try watchLinux(io, init.gpa, root, git_prefix.items, &dirs),
        // **폴링이다**(RW7c). kqueue 는 파일 «편집» 을 안 알리고 디렉터리마다 fd 를 써서 한도에도
        // 걸린다(§8.6 ①). 그래서 이 갈래는 저쪽에서 git 을 돌려 다이제스트를 비교한다.
        .macos, .freebsd, .netbsd, .openbsd, .dragonfly => try watchPoll(init.gpa, root, git_prefix.items),
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
fn watchLinux(io: std.Io, gpa: std.mem.Allocator, root: []const u8, git_prefix: []const []const u8, dirs: *std.ArrayList([]u8)) !void {
    const linux = std.os.linux;
    const ifd: i32 = @intCast(linux.inotify_init1(0));
    if (ifd < 0) return exitWith(exit_unsupported);
    var fds = [_]std.posix.pollfd{
        .{ .fd = ifd, .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = 0, .events = std.posix.POLL.IN, .revents = 0 }, // 채널이 끊기면 여기서 걸린다
    };
    // ⚠️ **한도에 걸리면 폴링으로 내려간다**(RW7d). `max_user_watches` 소진은 저 호스트의 형편이지
    // 「못 한다」가 아니다 — 폴링은 같은 것을 보고 느릴 뿐이다(계획 §11.7).
    armLinux(gpa, ifd, dirs.items) catch |err| switch (err) {
        error.WatchLimit => {
            _ = std.c.close(ifd);
            return watchPoll(gpa, root, git_prefix);
        },
        else => return err,
    };
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
            if (dirs.items.len >= max_dirs) {
                _ = std.c.close(ifd);
                return watchPoll(gpa, root, git_prefix); // 재무장 중에 넘었다 — 같은 이유로 폴링이다
            }
            // 이미 걸린 경로에 다시 걸면 **같은 wd 를 돌려준다** — 그래서 전부 다시 거는 것이 안전하고,
            // 어느 것이 새것인지 알 필요가 없다(그걸 알려면 wd→경로 표를 지어야 한다).
            armLinux(gpa, ifd, dirs.items) catch |err| switch (err) {
                error.WatchLimit => {
                    _ = std.c.close(ifd);
                    return watchPoll(gpa, root, git_prefix);
                },
                else => return err,
            };
        }
        if (!announce()) return;
    }
}

/// 목록의 디렉터리마다 watch 를 건다. **멱등이다** — 같은 경로면 같은 wd 가 온다.
///
/// 한도(`max_user_watches` 소진)는 **나가지 않고 돌려준다** — 호출자가 폴링으로 내려간다(RW7d).
fn armLinux(gpa: std.mem.Allocator, ifd: i32, dirs: []const []u8) error{ OutOfMemory, WatchLimit }!void {
    const linux = std.os.linux;
    const mask: u32 = linux.IN.MODIFY | linux.IN.CREATE | linux.IN.DELETE |
        linux.IN.MOVED_TO | linux.IN.MOVED_FROM | linux.IN.ATTRIB;
    for (dirs) |d| {
        const z = try gpa.dupeZ(u8, d);
        defer gpa.free(z);
        const wd: isize = @bitCast(linux.inotify_add_watch(ifd, z, mask));
        // ENOSPC = `max_user_watches` 소진. **일부만 보고 계속하지 않는다** — 폴링으로 내려간다.
        if (wd < 0) return error.WatchLimit;
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

/// 폴링 주기. 짧을수록 화면이 빨라지고 저쪽 부하가 는다 — 5 초에서 한 번이 저쪽 코어의 1% 미만이다
/// (실측: 다이제스트 한 번 0.04 s, 5 만 파일 저장소에서 0.11 s).
const poll_interval_ns: i128 = 5 * std.time.ns_per_s;

/// stdin 을 얼마나 자주 들여다보나. **고아 방지가 1 급 규율**이라(§5) 채널이 끊기면 한 주기가 아니라
/// 이 시간 안에 끝나야 한다.
const poll_tick_ms: c_int = 250;

/// 다이제스트에 넣을 읽기들. **도크가 읽는 것과 같은 범위여야 한다**(§11.3) — `status` 하나만 보면
/// 다른 곳에서 만든 브랜치·워크트리를 못 잡아 inotify 보다 좁아진다. 셋을 합쳐도 0.04 s 다(실측).
/// ⚠️ **`status` 만으로는 「틀린 화면」이 나온다** — 계획 §3 이 이미 재서 적어 둔 것이고, RW7 의 첫
/// 판이 그 경고를 그대로 밟았다(적대적 검증 2026-09-04). 실측: 이미 수정된 파일을 **더** 고치면
/// `status` 바이트는 그대로인데 `diff --numstat` 은 `1 1` → `3 3` 으로 바뀐다 — 그 숫자가 도크 행마다
/// 보이는 `+N −M` 이다. 그래서 다이제스트는 **화면의 숫자를 만드는 읽기까지** 봐야 한다.
///
/// 첫 줄(`status`)은 **필수**다. 나머지는 실패해도 「실패했다」를 해시에 넣고 계속한다 — `origin` 이
/// 없는 저장소에서 `rev-list` 가 실패한다고 감시 전체가 멀면 안 된다.
const digest_reads = [_][]const []const u8{
    &.{ "status", "--porcelain=v2", "--branch", "--untracked-files=all" },
    &.{ "for-each-ref", "--format=%(refname) %(objectname)" },
    &.{ "worktree", "list", "--porcelain" },
    // 행별 `+N −M` — 작업트리와 스테이지 양쪽(§3 이 잰 구멍이 여기다)
    &.{ "diff", "--numstat", "--find-renames", "--no-ext-diff", "--no-textconv" },
    &.{ "diff", "--numstat", "--find-renames", "--no-ext-diff", "--no-textconv", "--cached" },

    // ⚠️ **머리 줄 `↑↓` 는 여기 «없다» — 위 둘이 이미 덮는다**(적대적 검증 2026-09-05 — 실측).
    //
    // 한때 `rev-list --count --left-right origin/HEAD...HEAD` 를 넣었다. §3 이 「fetch 로 `↑↓` 만
    // 바뀌면 status 로는 못 본다」를 재 두었기 때문인데, **그 측정은 `status` 단독 기준이었다.**
    // `for-each-ref` 가 들어온 뒤로는 겹친다: `↑↓` 는 **어느 한쪽 ref 가 움직여야만** 바뀌고, ref 가
    // 움직이면 `for-each-ref` 의 oid 가 바뀐다. 분리 HEAD 처럼 `refs/` 밖인 경우는 `status --branch`
    // 의 `branch.oid` 가 덮는다. 둘 다 실측했다:
    //   비기본 기준(`origin/feat`)만 움직임 → `rev-list` 없이도 다이제스트가 바뀐다
    //   분리 HEAD 를 옮김                   → 마찬가지
    //
    // 그래서 **같은 사실을 두 번 묻던 것**이고, 5 초마다 원격에서 도는 명령 하나를 줄였다.
    // (도크가 숫자를 «그릴» 때는 여전히 클라이언트가 `rev-list` 를 돌린다 — 그쪽은 값이 필요하다.)
};

/// 한 명령의 결과. **`channel_closed` 가 있는 이유**가 이 파일의 1 급 규율이다 — git 이 멈춰 있는
/// 동안에도 채널이 끊기면 «즉시» 끝나야 한다(§5).
const RunResult = enum { ok, failed, channel_closed };

/// git 하나가 멈춰 있을 수 있는 최대 시간. 넘으면 죽이고 「못 읽었다」로 친다 — 큰 저장소의 `status`
/// 도 0.1 s 대라(실측) 이 값에 걸릴 일은 병든 원격뿐이다.
const command_deadline_ms: i64 = 30_000;

/// 한 명령을 돌려 stdout 을 해시에 흘려 넣는다. **출력을 모아 두지 않는다** — 다이제스트만 필요하고,
/// 큰 저장소의 `status` 출력을 통째로 들고 있을 이유가 없다.
///
/// `std.process.Child` 를 안 쓴다 — 이 파일은 이미 raw posix 로 사는데(§5 의 `poll` 결속) 그 API 는
/// 판마다 흔들려 왔다. fork/exec 는 여기서 예순 줄이고 흔들리지 않는다.
///
/// ⚠️ **git 을 기다리는 동안에도 stdin 을 본다**(적대적 검증 2026-09-04 17 회차 — 실측). 앞 판은
/// 파이프를 블로킹으로 읽었는데, git 이 멈추면 그 `read` 에서 서서 **채널이 끊겨도 안 끝났다** —
/// 남의 서버에 고아가 남는다. 이 트랙의 최악 실패다.
fn hashCommand(gpa: std.mem.Allocator, argv: []const []const u8, hasher: *std.hash.Wyhash) RunResult {
    var zargs: std.ArrayList(?[*:0]const u8) = .empty;
    defer {
        for (zargs.items) |a| if (a) |ptr| gpa.free(std.mem.span(ptr));
        zargs.deinit(gpa);
    }
    for (argv) |a| {
        const z = gpa.dupeZ(u8, a) catch return .failed;
        zargs.append(gpa, z.ptr) catch {
            gpa.free(z);
            return .failed;
        };
    }
    zargs.append(gpa, null) catch return .failed;

    var fds: [2]c_int = undefined;
    if (std.c.pipe(&fds) != 0) return .failed;
    const pid = std.c.fork();
    if (pid < 0) {
        _ = std.c.close(fds[0]);
        _ = std.c.close(fds[1]);
        return .failed;
    }
    if (pid == 0) {
        // **자식의 stdin 은 `/dev/null` 이다.** 우리 stdin 은 ssh 채널이라, git 이 그것을 읽으면
        // 채널 바이트를 먹거나 프롬프트에서 선다(그러면 위 함정으로 되돌아간다).
        const devnull = std.c.open("/dev/null", .{ .ACCMODE = .RDWR });
        if (devnull >= 0) {
            _ = std.c.dup2(devnull, 0);
            _ = std.c.dup2(devnull, 2); // git 의 경고를 다이제스트에 안 섞는다
        }
        _ = std.c.dup2(fds[1], 1);
        _ = std.c.close(fds[0]);
        _ = std.c.close(fds[1]);
        _ = execvp(zargs.items[0].?, @ptrCast(zargs.items.ptr));
        std.c._exit(127);
    }
    _ = std.c.close(fds[1]);

    var wait = [_]std.posix.pollfd{
        .{ .fd = fds[0], .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = 0, .events = std.posix.POLL.IN, .revents = 0 }, // 채널 — 여기가 열리면 곧장 접는다
    };
    var buf: [8192]u8 = undefined;
    var left_ms: i64 = command_deadline_ms;
    var outcome: RunResult = .failed;
    while (true) {
        if (left_ms <= 0) break; // 병든 원격 — 죽이고 「못 읽었다」로 친다
        const waited = std.posix.poll(&wait, poll_tick_ms) catch break;
        if (wait[1].revents != 0) {
            outcome = .channel_closed;
            break;
        }
        if (waited == 0) {
            left_ms -= poll_tick_ms;
            continue;
        }
        if (wait[0].revents == 0) continue;
        const rc = std.posix.system.read(fds[0], &buf, buf.len);
        const n: isize = @bitCast(rc);
        if (n < 0) break;
        if (n == 0) {
            outcome = .ok; // EOF — 자식이 출력을 끝냈다
            break;
        }
        hasher.update(buf[0..@intCast(n)]);
    }
    _ = std.c.close(fds[0]);
    if (outcome != .ok) _ = std.c.kill(pid, std.c.SIG.KILL); // 멈춘 자식을 남기지 않는다
    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);
    if (outcome != .ok) return outcome;
    const us: u32 = @bitCast(status);
    if (!(std.c.W.IFEXITED(us) and std.c.W.EXITSTATUS(us) == 0)) return .failed;
    return .ok;
}

/// 지금 상태의 다이제스트. 하나라도 못 읽으면 null — 그때는 **바뀌었다고 말하지 않는다**(git 이
/// 잠깐 실패한 것을 변경으로 읽으면 읽기 폭주가 된다).
fn digest(gpa: std.mem.Allocator, root: []const u8, git_prefix: []const []const u8) Digest {
    var hasher = std.hash.Wyhash.init(0);
    for (digest_reads, 0..) |tail, index| {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        argv.appendSlice(gpa, git_prefix) catch return .{ .state = .failed };
        argv.appendSlice(gpa, &.{ "-C", root }) catch return .{ .state = .failed };
        argv.appendSlice(gpa, tail) catch return .{ .state = .failed };
        switch (hashCommand(gpa, argv.items, &hasher)) {
            .ok => {},
            // **첫 읽기만 필수다.** git 이 없거나 저장소가 아니면 거기서 드러난다. 나머지는 실패를
            // 해시에 적고 계속한다 — `origin` 이 없는 저장소에서 `rev-list` 가 실패한다고 감시가
            // 통째로 멀면 안 된다(그 저장소가 오히려 흔하다).
            .failed => {
                if (index == 0) return .{ .state = .failed };
                hasher.update("!");
            },
            .channel_closed => return .{ .state = .channel_closed },
        }
        hasher.update("\x00");
    }
    return .{ .state = .ok, .value = hasher.final() };
}

const Digest = struct { state: RunResult, value: u64 = 0 };

/// macOS·BSD·한도 초과에서 쓰는 갈래(RW7). **git 을 돌려 다이제스트를 비교한다** — 파일을 훑지
/// 않는다(전체 stat 걷기는 0.37~0.83 s 로 10 배 넘게 비싸고 `.gitignore` 도 안 따른다).
///
/// ⚠️ 다이제스트는 **이 프로세스 안에서만** 산다. 밖으로 나가는 것은 여전히 `change` 한 줄이라
/// 파싱 계약이 두 벌이 되지 않는다(계약 §2 · §10).
fn watchPoll(gpa: std.mem.Allocator, root: []const u8, git_prefix: []const []const u8) !void {
    if (git_prefix.len == 0) return exitWith(exit_unsupported); // 앞머리가 없으면 git 을 못 돌린다
    const first = digest(gpa, root, git_prefix);
    if (first.state == .channel_closed) return;
    if (first.state != .ok) return exitWith(exit_unsupported);
    var last = first.value;

    var fds = [_]std.posix.pollfd{
        .{ .fd = 0, .events = std.posix.POLL.IN, .revents = 0 }, // 채널이 끊기면 여기서 걸린다
    };
    var waited_ns: i128 = 0;
    while (true) {
        _ = std.posix.poll(&fds, poll_tick_ms) catch return;
        if (fds[0].revents != 0) return; // stdin EOF/HUP → 종료(고아 방지 — 한 주기를 안 기다린다)
        waited_ns += @as(i128, poll_tick_ms) * std.time.ns_per_ms;
        if (waited_ns < poll_interval_ns) continue;
        waited_ns = 0;
        const now = digest(gpa, root, git_prefix);
        if (now.state == .channel_closed) return; // git 을 기다리는 동안 채널이 끊겼다 — 곧장 끝낸다
        if (now.state != .ok) continue; // 잠깐 실패는 변경이 아니다
        if (now.value == last) continue;
        last = now.value;
        if (!announce()) return;
    }
}
