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
    // ⚠️ **kqueue 갈래는 지금 「못 한다」고 말한다**(적대적 검증 2026-09-04 13 회차 — 실측). 디렉터리에
    // 건 `EVFILT_VNODE` 는 **파일 내용 수정을 안 알린다**(만들기·지우기·이름 바꾸기만 온다). 그런데
    // 화면은 살아 있는 것처럼 보여, 계획 §6 이 「최악」이라 못 박은 조용한 반쪽 감시가 된다.
    // 되살릴 자리(`watchKqueueDirs`)는 남겨 두되 **stdin 결속은 그때도 지켜야 한다.**
    const kq_body = try bodyOf(src, "fn watchKqueue(", "\n}\n", 4096);
    try std.testing.expect(std.mem.indexOf(u8, kq_body, "exit_unsupported") != null);
    const kq_dirs = try bodyOf(src, "fn watchKqueueDirs(", "\n}\n", 4096);
    try std.testing.expect(std.mem.indexOf(u8, kq_dirs, ".ident = 0,") != null);
    try std.testing.expect(std.mem.indexOf(u8, kq_dirs, "EVFILT.READ") != null);

    // ── ⑶ 한도 초과를 **말한다** — 조용히 일부만 감시하지 않는다(§RW5) ──────────────────────
    try std.testing.expect(std.mem.indexOf(u8, src, "exit_watch_limit") != null);
    // ⚠️ **비교까지 본다**(적대적 검증 2026-09-04 12 회차). 이름만 세면 «죽은» 보고를 못 본다 —
    // `collect` 가 `max_dirs` 에서 멈추므로 `> max_dirs` 는 영원히 거짓이고, 그때 상한을 넘는 저장소가
    // 조용히 반쪽만 감시된다. 실제로 그 상태로 머지됐고 이 판정자는 초록이었다.
    try std.testing.expect(std.mem.indexOf(u8, src, "dirs.items.len >= max_dirs) return exitWith(exit_watch_limit)") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "dirs.items.len > max_dirs)") == null);
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
    try std.testing.expect(std.mem.indexOf(u8, linux_body, "exit_watch_limit") != null);
    try std.testing.expect(std.mem.indexOf(u8, kq_dirs, "exit_watch_limit") != null);

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

    // 감시자 쪽은 개행이 붙은 리터럴, 설치 쪽은 붙지 않은 리터럴이다 — 같은 값을 말하는지 센다.
    try std.testing.expect(std.mem.indexOf(u8, watcher, "\"maru-remote-watch 1\\n\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, install, "\"maru-remote-watch 1\"") != null);
    // 파일 이름에도 같은 판이 박혀 있어야 한다 — 판을 올리면서 이름을 안 올리면 옛 바이너리를 덮는다.
    try std.testing.expect(std.mem.indexOf(u8, install, "maru-remote-watch-1\"") != null);
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
