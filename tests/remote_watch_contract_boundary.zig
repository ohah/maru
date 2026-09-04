//! 원격 감시자(RW1)의 **소스에서만 셀 수 있는 계약**([계획](../docs/plans/remote-watch.md)).
//!
//! ## 왜 컴파일 게이트로 부족한가
//!
//! 실측에서 **컴파일도 되고 `nftw` 도 성공을 반환하는데 watch 를 하나도 안 거는** 판을 만들었다 —
//! `FTW_D` 상수가 libc 마다 달라서다(glibc 1 · musl 2). 증상은 「원격만 갱신이 안 된다」뿐이라
//! 동작 test 없이는 조용히 지나간다. 그래서 **그 함정으로 되돌아가는 것 자체를** 여기서 막는다.

const std = @import("std");

fn read(allocator: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(limit));
}

test "원격 감시자는 libc 상수로 디렉터리를 판정하지 않는다" {
    const allocator = std.testing.allocator;
    const src = try read(allocator, "tools/remote-watch/main.zig", 256 * 1024);
    defer allocator.free(src);

    // ── ⑴ `nftw`·`FTW_D` 로 되돌아가지 않는다 ────────────────────────────────────────────────
    //
    // 그 조합이 **조용히 아무것도 감시하지 않는** 판을 만들었다. 판정은 `std.Io.Dir` 이 진다.
    //
    // ⚠️ **주석을 벗기고 센다.** 그러지 않으면 「그 함정을 설명하는 주석」이 걸린다 — 실제로 처음
    // 쓴 판이 그렇게 빨갛게 났다. 세야 하는 것은 「언급하는가」가 아니라 **「쓰는가」**다.
    const code = try stripComments(allocator, src);
    defer allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "nftw") == null);
    try std.testing.expect(std.mem.indexOf(u8, code, "FTW_D") == null);
    try std.testing.expect(std.mem.indexOf(u8, code, "entry.kind != .directory") != null);

    // ── ⑵ **stdin 이 감시와 «같은 대기»에 있다** — 고아 방지의 전부다 ────────────────────────
    //
    // 감시자는 설계상 조용해서 EPIPE 를 못 받는다. 실측: 조용한 프로세스는 ssh 채널이 끊겨도
    // 살아남았다. 두 갈래 **모두** stdin 을 대기에 넣어야 한다 — 한쪽만 넣으면 그 플랫폼 원격에만
    // 고아가 쌓이고, 남의 서버라 우리는 영영 모른다.
    const linux_body = try bodyOf(src, "fn watchLinux(", "\n}\n", 4096);
    try std.testing.expect(std.mem.indexOf(u8, linux_body, ".fd = 0,") != null);
    try std.testing.expect(std.mem.indexOf(u8, linux_body, "fds[1].revents != 0") != null);
    // ⚠️ **macOS·BSD 는 폴링이다**(RW7 — 13 회차 실측이 kqueue 를 버리게 했다). 그 갈래도 stdin 을
    // 같은 대기에 넣어야 한다. 게다가 **주기를 기다리면 안 된다** — 고아 방지가 1 급 규율이라
    // 채널이 끊기면 한 주기(5 초)가 아니라 한 tick 안에 끝나야 한다(실측 59 ms).
    const poll_body = try bodyOf(src, "fn watchPoll(", "\n}\n", 4096);
    try std.testing.expect(std.mem.indexOf(u8, poll_body, ".fd = 0,") != null);
    try std.testing.expect(std.mem.indexOf(u8, poll_body, "fds[0].revents != 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, poll_body, "poll_tick_ms") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "poll_tick_ms: c_int = 250") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "poll_interval_ns: i128 = 5 * std.time.ns_per_s") != null);
    // git 앞머리가 없으면 폴링을 못 한다 — 조용히 멈춰 있지 말고 말해야 한다.
    try std.testing.expect(std.mem.indexOf(u8, poll_body, "git_prefix.len == 0) return exitWith(exit_unsupported)") != null);
    // ⚠️ **다이제스트는 도크가 읽는 것과 «같은 범위» 여야 한다**(§11.3). `status` 하나만 보면 다른
    // 곳에서 만든 브랜치·워크트리를 못 잡아 inotify 보다 좁아진다 — 셋을 합쳐도 0.04 s 다(실측).
    const reads = try bodyOf(src, "const digest_reads = [_][]const []const u8{", "\n};", 2048);
    try std.testing.expect(std.mem.indexOf(u8, reads, "\"status\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, reads, "\"for-each-ref\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, reads, "\"worktree\"") != null);
    // ⚠️ **`status` 만 보면 「틀린 화면」이 나온다** — 계획 §3 이 이미 재서 적어 둔 것이고 RW7 의 첫
    // 판이 그 경고를 그대로 밟았다. 실측: 이미 수정된 파일을 더 고치면 `status` 바이트는 같은데
    // `numstat` 은 `1 1` → `3 3` 이다(도크 행의 `+N −M`). `↑↓` 는 `branch.ab`(upstream 기준)와 **다른
    // 기준**(`origin/HEAD...HEAD`)이라 그것도 status 로는 못 본다.
    try std.testing.expect(std.mem.indexOf(u8, reads, "\"--numstat\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, reads, "\"--cached\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, reads, "\"rev-list\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, reads, "origin/HEAD...HEAD") != null);
    // 첫 읽기만 필수다 — `origin` 이 없는 저장소에서 `rev-list` 가 실패한다고 감시가 멀면 안 된다.
    const dg_body = try bodyOf(src, "fn digest(", "\n}\n", 2048);
    try std.testing.expect(std.mem.indexOf(u8, dg_body, "if (index == 0) return .{ .state = .failed }") != null);
    // ⚠️ 다이제스트는 **이 프로세스 안에서만** 산다 — 밖으로 나가는 것은 `change` 한 줄뿐이다(§10).
    try std.testing.expect(std.mem.indexOf(u8, poll_body, "announce()") != null);

    // ⚠️ **git 을 기다리는 동안에도 stdin 을 본다**(적대적 검증 2026-09-04 17 회차 — 실측). 폴링 갈래는
    // 자식을 띄우므로 §5 의 고아 방지를 «새로» 지켜야 한다. 앞 판은 파이프를 블로킹으로 읽어서, git 이
    // 멈추면 채널이 끊겨도 안 끝났다(고치기 전 바이너리로 재현 확인 · 고친 뒤 60 ms).
    const run_body = try bodyOf(src, "fn hashCommand(", "\n}\n", 4096);
    try std.testing.expect(std.mem.indexOf(u8, run_body, ".fd = 0,") != null);
    try std.testing.expect(std.mem.indexOf(u8, run_body, "channel_closed") != null);
    // 병든 원격이 폴링을 영원히 붙잡지 못한다.
    // ⚠️ **상수가 있는지가 아니라 «그 값으로 끊는지»를 본다.** 이름만 세면 `if (left_ms <= 0) break;`
    // 를 죽여도 초록이다 — 실제로 그 반증이 통과했다(세 번째로 같은 함정을 밟았다).
    try std.testing.expect(std.mem.indexOf(u8, run_body, "var left_ms: i64 = command_deadline_ms") != null);
    try std.testing.expect(std.mem.indexOf(u8, run_body, "if (left_ms <= 0) break;") != null);
    try std.testing.expect(std.mem.indexOf(u8, run_body, "left_ms -= poll_tick_ms;") != null);
    // ⚠️ **자식의 stdin 은 우리 채널이 아니다.** git 이 그것을 읽으면 채널 바이트를 먹거나 프롬프트에
    // 서고, 그러면 위 함정으로 되돌아간다.
    try std.testing.expect(std.mem.indexOf(u8, run_body, "std.c.dup2(devnull, 0)") != null);
    // 그리고 채널이 끊겼으면 **위에서도** 곧장 접어야 한다 — 여기서만 알고 삼키면 소용이 없다.
    // **두 자리 모두** 접어야 한다 — 첫 다이제스트와 주기 안쪽. 하나만 세면 다른 쪽을 `continue` 로
    // 바꿔도 초록이다(실제로 그 반증이 통과했다).
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, poll_body, ".channel_closed) return"));

    // ── ⑶ 한도 초과를 **말한다** — 조용히 일부만 감시하지 않는다(§RW5) ──────────────────────
    // ⚠️ **한도는 이제 「포기」가 아니라 「격하」다**(RW7d). 폴링이 생겼으니 잃는 것은 지연뿐이라
    // 포기할 이유가 없다 — 그래서 **판 2 부터 `exitWith(exit_watch_limit)` 은 어디에도 없어야 한다.**
    // (상수 자체는 남는다: 원격에 판 1 바이너리가 돌면 그쪽은 여전히 그 코드로 나간다.)
    try std.testing.expect(std.mem.indexOf(u8, code, "exitWith(exit_watch_limit)") == null);
    // 「닿았다」로 묻는 자리는 그대로다 — `collect` 가 `max_dirs` 에서 멈추므로 `>` 는 영원히 거짓이다
    // (12 회차에 잡은 죽은 코드). 이제 그 자리는 폴링으로 간다.
    try std.testing.expect(std.mem.indexOf(u8, code, "dirs.items.len >= max_dirs") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "dirs.items.len > max_dirs)") == null);
    try std.testing.expect(std.mem.indexOf(u8, code, "const over_limit = dirs.items.len >= max_dirs") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "if (over_limit)") != null);
    // 무장 중 한도는 **나가지 않고 돌려준다** — 호출자가 폴링으로 내려간다.
    const linux_body_for_limit = linux_body;
    const arm_body = try bodyOf(src, "fn armLinux(", "\n}\n", 2048);
    try std.testing.expect(std.mem.indexOf(u8, arm_body, "return error.WatchLimit") != null);
    // **세 자리 모두** 내려가야 한다: 최초 무장 실패 · 재무장 중 한도 초과 · 재무장 실패. 하나만
    // 세면 나머지에서 조용히 나가도 초록이다.
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, linux_body_for_limit, "return watchPoll(gpa, root, git_prefix)"));
    // ⚠️ **수집 실패를 삼키지 않는다**(15 회차). `catch {}` 면 OOM 으로 도중에 멈춘 절반을 「전부」로
    // 알고 무장한다 — 조용한 반쪽 감시다.
    try std.testing.expect(std.mem.indexOf(u8, code, "collect(io, init.gpa, root, &dirs) catch {}") == null);
    try std.testing.expect(std.mem.indexOf(u8, code, "collect(io, gpa, root, dirs) catch {}") == null);
    // ⚠️ **새 디렉터리는 다시 무장한다**(14 회차 — 실측: 안 하면 그 안의 편집이 통째로 안 보인다).
    //
    // ⚠️ **정의가 아니라 «호출»을 센다.** `code` 전체에서 `sawDirEvent(` 를 찾으면 함수 **정의**가
    // 걸려, 호출을 `if (false)` 로 죽여도 초록이다 — 실제로 그 반증이 통과했다(16 회차). 3 회차에서
    // 같은 함정을 잡고도 반복했다. 세야 하는 것은 언제나 **쓰는가**다.
    try std.testing.expect(std.mem.indexOf(u8, linux_body, "if (sawDirEvent(") != null);
    try std.testing.expect(std.mem.indexOf(u8, linux_body, "armLinux(gpa, ifd, dirs.items)") != null);
    // 무장은 **처음과 재무장 두 번** 일어난다 — 하나만 있으면 둘 중 한 경로가 빠진 것이다.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, linux_body, "armLinux(gpa, ifd, dirs.items)"));

    // ── ⑷ 이벤트를 **해석하지 않는다**(계약 §2 — 파싱 계약을 두 벌로 만들지 않는다) ──────────
    //
    // 출력은 「바뀌었다」한 줄뿐이다. 경로나 종류를 실어 보내기 시작하면 그 형식이 곧 두 번째
    // 파싱 계약이 되고, 원격·로컬 버전이 갈리는 순간 화면이 조용히 틀린다.
    try std.testing.expect(std.mem.indexOf(u8, src, "\"change\\n\"") != null);
}

test "감시자와 설치 계약이 같은 «판»을 말한다" {
    // 판 문자열이 **두 파일**에 있다: 감시자가 내고(`--version`), 설치 쪽이 그것으로 「이미 있고
    // 우리 것인가」를 판정한다. 갈리면 설치가 **매번 다시 심거나**(영영 안 맞아서) 반대로 **옛 판을
    // 그대로 쓴다**(우연히 맞아서) — 둘 다 조용하다.
    const allocator = std.testing.allocator;
    const watcher = try read(allocator, "tools/remote-watch/main.zig", 256 * 1024);
    defer allocator.free(watcher);
    const install = try read(allocator, "src/session/remote_watch_install.zig", 256 * 1024);
    defer allocator.free(install);

    // ⚠️ **판 번호를 여기 박지 않는다**(RW7d 에서 2 로 올리며 배웠다). 박아 두면 판을 올릴 때마다
    // 판정자를 고쳐야 하고, 그 손질이 곧 「무엇을 확인하는지」를 흐린다. **뽑아서 대조한다.**
    const marker = "maru-remote-watch ";
    const at = std.mem.indexOf(u8, watcher, "version_line = \"" ++ marker) orelse return error.TestUnexpectedResult;
    const digits_at = at + ("version_line = \"" ++ marker).len;
    var end = digits_at;
    while (end < watcher.len and watcher[end] >= '0' and watcher[end] <= '9') end += 1;
    const version = watcher[digits_at..end];
    try std.testing.expect(version.len > 0);

    // 감시자 쪽은 개행이 붙은 리터럴, 설치 쪽은 붙지 않은 리터럴이다 — 같은 값을 말하는지 센다.
    var buf: [64]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, watcher, try std.fmt.bufPrint(&buf, "\"{s}{s}\\n\"", .{ marker, version })) != null);
    var buf2: [64]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, install, try std.fmt.bufPrint(&buf2, "\"{s}{s}\"", .{ marker, version })) != null);
    // 파일 이름에도 같은 판이 박혀 있어야 한다 — 판을 올리면서 이름을 안 올리면 옛 바이너리를 덮는다.
    var buf3: [64]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, install, try std.fmt.bufPrint(&buf3, "maru-remote-watch-{s}\"", .{version})) != null);
}

test "빌드가 만드는 변종과 앱이 찾는 변종이 같다" {
    // 이름이 **두 곳**에 있다: `build.zig` 가 손으로 적은 `asset` switch 와 `Variant.assetName`.
    // 어긋나면 앱이 **빌드가 만들지 않은 자리**를 뒤지고, 증상은 「그 아키텍처 원격만 감시가 안 된다」 —
    // 컴파일러가 못 잇는 관계라 여기서 센다.
    const allocator = std.testing.allocator;
    const build_zig = try read(allocator, "build.zig", 2 * 1024 * 1024);
    defer allocator.free(build_zig);
    const install = try read(allocator, "src/session/remote_watch_install.zig", 256 * 1024);
    defer allocator.free(install);

    for ([_][]const u8{ "linux-x86_64", "linux-aarch64", "macos-x86_64", "macos-aarch64" }) |name| {
        var needle: [64]u8 = undefined;
        const quoted = try std.fmt.bufPrint(&needle, "\"{s}\"", .{name});
        // ⑴ 빌드가 그 이름으로 설치한다 ⑵ 앱이 그 이름으로 찾는다 ⑶ 번들 검사가 그 이름을 센다
        try std.testing.expect(std.mem.indexOf(u8, build_zig, quoted) != null);
        try std.testing.expect(std.mem.indexOf(u8, install, quoted) != null);
    }
    // ⚠️ **양쪽 «개수»도 센다.** 이름 넷이 양쪽에 있다는 것만 보면 **한쪽에만 다섯 번째를 더해도
    //    통과한다**(적대적 검증 2 회차에서 실제로 그랬다). 그러면 빌드는 만들고 번들은 싣는데 앱은
    //    영영 고를 수 없는 변종이 생기고, 더한 사람은 되는 줄 안다.
    const build_switch = try bodyOf(build_zig, "const asset = switch (query.os_tag.?)", "\n        };", 2048);
    const name_switch = try bodyOf(install, "pub fn assetName(self: Variant)", "\n    }", 1024);
    const bundle_line = try bodyOf(build_zig, "\"for v in ", "; do \" ++", 256);
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, build_switch, "=> \""));
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, name_switch, "=> \""));
    // 번들 검사 줄도 넷이다 — 여기만 빠지면 그 변종은 **없어도 빌드가 안 선다.**
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, bundle_line, "-"));

    // 번들 단계가 **네 변종을 전부** 검사하고, 없으면 빌드를 세운다.
    try std.testing.expect(std.mem.indexOf(u8, build_zig, "for v in linux-x86_64 linux-aarch64 macos-x86_64 macos-aarch64") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_zig, "remote watcher variant missing or empty") != null);
    // 경로 조립은 **한 곳**이다 — 앱이 문자열을 다시 짜면 그 자리가 또 어긋난다.
    try std.testing.expect(std.mem.indexOf(u8, install, "pub fn assetRelPath") != null);
}

/// 줄 주석(`//`)을 벗긴다. 문자열 안의 `//` 는 이 소스에 없다 — 생기면 이 헬퍼부터 고쳐야 한다.
fn stripComments(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |line| {
        const keep = if (std.mem.indexOf(u8, line, "//")) |at| line[0..at] else line;
        try out.appendSlice(allocator, keep);
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

/// 함수 하나의 본문을 자른다. `max` 를 넘으면 실패한다 — 경계가 안 맞으면 슬라이스가 파일 끝까지
/// 달아나고, 그러면 위 needle 들이 **아무 데서나** 걸려 판정자가 통째로 초록이 된다.
fn bodyOf(src: []const u8, head: []const u8, close: []const u8, max: usize) ![]const u8 {
    const at = std.mem.indexOf(u8, src, head) orelse return error.FunctionMissing;
    const end = std.mem.indexOfPos(u8, src, at, close) orelse return error.FunctionUnterminated;
    const body = src[at..end];
    if (body.len > max) return error.FunctionBodyRunaway;
    return body;
}
