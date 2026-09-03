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
    const kq_body = try bodyOf(src, "fn watchKqueue(", "\n}\n", 4096);
    try std.testing.expect(std.mem.indexOf(u8, kq_body, ".ident = 0,") != null);
    try std.testing.expect(std.mem.indexOf(u8, kq_body, "EVFILT.READ") != null);

    // ── ⑶ 한도 초과를 **말한다** — 조용히 일부만 감시하지 않는다(§RW5) ──────────────────────
    try std.testing.expect(std.mem.indexOf(u8, src, "exit_watch_limit") != null);
    try std.testing.expect(std.mem.indexOf(u8, linux_body, "exit_watch_limit") != null);
    try std.testing.expect(std.mem.indexOf(u8, kq_body, "exit_watch_limit") != null);

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
