//! 원격이 tmux 일 때 **어느 Term 의 이벤트인가**를 되찾는 순수 규칙([계획](../../docs/plans/remote-agent-state.md) RA6).
//!
//! **문제**: tmux 안에서는 `LC_MARU_PANE` 이 오염된다. tmux 서버가 만들어질 때의 값이 자식에게 가고,
//! `update-environment` 기본 목록 아홉에 `LC_*` 가 없다(2026-08-29 실측). 그래서 나중에 다른 값으로
//! attach 해도 **먼저 값이 그대로 온다** — 값이 비는 것이 아니라 **남의 값이 오는 오배달**이다. 그게 더
//! 나쁘다: 로컬에서는 그 줄이 멀쩡해 보인다.
//!
//! **해법**: 오염된 env 를 믿지 않고 tmux 에 **직접 묻는다**. 훅이 `$TMUX_PANE`(자기 pane)과 `$TMUX`
//! (소켓 경로)를 함께 싣고, 스트리머가 `pane → session → client` 를 역조회해 **그 클라이언트 프로세스의
//! env** 에서 오염되지 않은 nonce 를 읽는다. tmux 클라이언트는 SSH 셸이 직접 exec 한 것이라 그 env 는
//! 멀쩡하다(최악 조건 실측 성공 — `update-environment` 미설정 + 서버가 오염된 값으로 생성).
//!
//! **이 파일은 순수하다.** tmux 를 부르지 않는다 — 부른 **결과**를 받아 판정만 한다.

const std = @import("std");
const command = @import("agent_hook_command.zig");

/// 훅 줄에 함께 실려 오는 tmux 관측치.
pub const Observed = struct {
    /// `$TMUX_PANE`(예: `%3`). 없으면 tmux 밖이다.
    pane: ?[]const u8 = null,
    /// `$TMUX` 의 소켓 경로. 사용자가 `-L`/`-S` 를 쓰면 기본 소켓이 아니다 — 그때 기본으로 물으면
    /// **엉뚱한 서버**를 본다(2026-08-29 실측: 기본 조회가 남의 세션을 봤다).
    socket: ?[]const u8 = null,
    /// 역조회를 **실제로 물어봤는가**. 원격에 `tmux` 바이너리가 없으면 물어보지도 못한다.
    ///
    /// ⚠️ **이 칸이 없으면 「못 물어봤다」와 「진짜 detached」가 같은 값이 된다**(적대적 검증 2026-08-29 이
    /// 잡았다). 둘은 대응이 다르다 — detached 는 보류·폐기의 문제이고, 못 물어본 것은 **다시 시도하거나
    /// 사용자에게 말할** 문제다. `ssh host cmd` 는 로그인 셸이 아니라 PATH 가
    /// `/usr/bin:/bin:/usr/sbin:/sbin` 뿐인 경우가 흔해 Homebrew tmux 가 실제로 안 잡혔다(실측).
    lookup_ran: bool = true,
};

/// tmux 에 물어 얻은 클라이언트 하나.
pub const Client = struct {
    /// 그 클라이언트 프로세스의 env 에서 읽은 `LC_MARU_PANE`. 못 읽었으면 `null`.
    nonce: ?[]const u8 = null,
};

/// 이 이벤트를 어디로 보낼 것인가.
pub const Route = union(enum) {
    /// tmux 밖이다 — env 의 nonce 를 그대로 믿는다(RA2 가 그 값을 보장한다).
    direct,
    /// 역조회로 되찾은 nonce. **하나로 좁혀졌다.**
    resolved: []const u8,
    /// 클라이언트가 여럿이다. **조용히 하나 고르지 않는다** — 규칙을 호출자가 정한다.
    ambiguous: usize,
    /// 붙어 있는 클라이언트가 없다(detached tmux). 귀속할 Term 이 없다.
    detached,
    /// tmux 안인데 역조회를 못 했다(소켓을 못 찾음·권한 등).
    unresolved,
};

/// 원격에 `tmux` 바이너리가 없을 때 스크립트가 내는 표식.
///
/// **`exit 0` 으로 끝낸다** — 셸이 «명령 없음» 으로 주는 127 은 「연결이 끊겼다」와 구분되지 않는다.
/// 이 표식을 받으면 `lookup_ran = false` 로 접어 **「진짜 detached」와 가른다**.
pub const no_tmux_marker = "!maru-no-tmux";

/// 훅이 남긴 **옆 파일**(`<nonce>.tmux`)의 내용을 읽는다.
///
/// 형식은 `<$TMUX>\t<$TMUX_PANE>\n` 한 줄이다. tmux 밖이면 두 칸이 다 비어 있고, 그때는 `null` 을
/// 돌려준다 — 호출자는 그것을 «관측치 없음»(`Observed{}`)으로 접어 `direct` 가 된다.
///
/// ⚠️ **`$TMUX` 는 `<소켓>,<pid>,<세션번호>` 세 칸이다.** 소켓만 떼어 써야 한다 — 통째로 `-S` 에 넘기면
/// 그런 이름의 소켓이 없어 조회가 조용히 빈다.
pub fn parseSidecar(bytes: []const u8) ?Observed {
    const line = blk: {
        const nl = std.mem.indexOfScalar(u8, bytes, '\n') orelse bytes.len;
        break :blk bytes[0..nl];
    };
    var it = std.mem.splitScalar(u8, line, '\t');
    const tmux_env = std.mem.trim(u8, it.next() orelse return null, " \t\r");
    const pane = std.mem.trim(u8, it.next() orelse "", " \t\r");
    if (pane.len == 0) return null; // tmux 밖
    const socket = blk: {
        if (tmux_env.len == 0) break :blk null;
        const comma = std.mem.indexOfScalar(u8, tmux_env, ',') orelse tmux_env.len;
        const sock = tmux_env[0..comma];
        break :blk if (sock.len == 0) null else sock;
    };
    return .{ .pane = pane, .socket = socket };
}

/// 역조회 스크립트. **`/bin/sh` 가 그 기계에서 직접 돈다** — 스트리머가 이미 그 기계에 있으므로 ssh 왕복이
/// 없다(계획: «스트리머가 `pane → session → client` 를 물어»).
///
/// Linux 는 `/proc/<pid>/environ`, macOS 는 `ps -E` 로 클라이언트 env 를 읽는다. 둘 다 같은 uid 의
/// 프로세스라 권한이 있다. 한 줄에 클라이언트 하나의 nonce 가 나오고, 못 읽었으면 빈 줄이다.
///
/// ⚠️ **`tmux` 가 비대화형 PATH 에 없을 수 있다.** 스트리머는 `ssh host cmd` 로 떠서 PATH 가
/// `/usr/bin:/bin:/usr/sbin:/sbin` 뿐인 경우가 흔하다(2026-08-29 실측 — Homebrew tmux 가 안 잡혔다).
/// 흔한 자리를 앞에 붙여 찾을 확률을 올리되, **못 찾으면 표식이 나가 `lookup_ran = false` 로 접는다** —
/// 그것이 안전한 실패다(오배달보다 낫다).
///
/// ⚠️ 소켓·pane 은 **작은따옴표 안에 들어간다.** 두 값 모두 tmux 가 만든 것이라 작은따옴표를 담지 않지만,
/// 그 가정을 코드가 아니라 여기 적어 둔다 — 언젠가 사용자 입력이 이 자리에 오면 인용이 아니라 검증이 필요하다.
pub fn lookupScript(allocator: std.mem.Allocator, socket: []const u8, pane: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\PATH="/opt/homebrew/bin:/usr/local/bin:/usr/pkg/bin:$PATH"; command -v tmux >/dev/null 2>&1 || {{ echo '{s}'; exit 0; }};
        \\tmux -S '{s}' display -p -t '{s}' '#{{session_name}}' 2>/dev/null | while IFS= read -r s; do
        \\tmux -S '{s}' list-clients -t "$s" -F '#{{client_pid}}' 2>/dev/null | while IFS= read -r p; do
        \\if [ -r "/proc/$p/environ" ]; then tr '\0' '\n' < "/proc/$p/environ" | sed -n 's/^LC_MARU_PANE=//p' | head -1;
        \\else ps -E -p "$p" 2>/dev/null | tr ' ' '\n' | sed -n 's/^LC_MARU_PANE=//p' | head -1; fi; echo; done; done
    , .{ no_tmux_marker, socket, pane, socket });
}

/// 스크립트 출력을 클라이언트 목록으로 접는다.
///
/// 한 줄이 클라이언트 하나이고, 빈 줄은 «그 클라이언트의 nonce 를 못 읽었다» 다(`Client{}`). 표식이
/// 보이면 목록이 아니라 **«물어보지도 못했다»** 이므로 `null` 을 돌려준다 — 호출자가 `lookup_ran = false`
/// 로 접어 detached 와 가른다.
pub fn parseClients(out: []const u8, buf: []Client) ?[]const Client {
    if (std.mem.indexOf(u8, out, no_tmux_marker) != null) return null;
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |raw| {
        if (n == buf.len) break;
        // 마지막 조각이 개행 뒤의 빈 꼬리면 클라이언트가 아니다 — 그것까지 세면 클라이언트가 하나
        // 더 있는 것처럼 보여 `ambiguous` 로 잘못 접힌다.
        if (lines.peek() == null and raw.len == 0) break;
        const nonce = std.mem.trim(u8, raw, " \t\r");
        buf[n] = .{ .nonce = if (nonce.len == 0) null else nonce };
        n += 1;
    }
    return buf[0..n];
}

/// tmux 관측치와 역조회 결과로 라우팅을 정한다.
///
/// **오염된 env 값은 인자로 받지도 않는다.** tmux 안이면 그것을 쓸 일이 없기 때문이다 — 받으면 언젠가
/// 누군가 «없으면 그거라도» 로 폴백을 넣고, 그 순간 조용한 오배달이 돌아온다.
pub fn route(obs: Observed, clients: []const Client) Route {
    if (obs.pane == null) return .direct; // tmux 밖
    if (obs.socket == null) return .unresolved; // 어느 서버에 물을지 모른다
    if (!obs.lookup_ran) return .unresolved; // 물어보지도 못했다 — detached 와 섞지 않는다
    if (clients.len == 0) return .detached;

    var found: ?[]const u8 = null;
    var n: usize = 0;
    for (clients) |cl| {
        const nonce = cl.nonce orelse continue;
        if (!isRoutableNonce(nonce)) continue;
        n += 1;
        if (found == null) found = nonce;
    }
    if (n == 0) return .unresolved;
    if (n > 1) return .{ .ambiguous = n };
    return .{ .resolved = found.? };
}

/// 역조회로 얻은 값도 **다시 검증한다** — 남의 프로세스 env 에서 읽은 값이다.
pub fn isRoutableNonce(nonce: []const u8) bool {
    return command.parseRemotePaneNonce(nonce) != null;
}

const testing = std.testing;

test "tmux 밖이면 env 값을 그대로 믿는다" {
    try testing.expectEqual(Route.direct, route(.{}, &.{}));
    try testing.expectEqual(Route.direct, route(.{ .socket = "/tmp/x" }, &.{}));
}

test "tmux 안인데 소켓을 모르면 역조회를 못 한다 — 기본으로 물으면 남의 서버를 본다" {
    try testing.expectEqual(Route.unresolved, route(.{ .pane = "%3" }, &.{}));
}

test "클라이언트가 하나면 그 nonce 로 되찾는다 — 오염된 env 를 안 쓴다" {
    const r = route(.{ .pane = "%3", .socket = "/tmp/tmux-501/default" }, &.{.{ .nonce = "4331_9" }});
    try testing.expectEqualStrings("4331_9", r.resolved);
}

test "클라이언트가 여럿이면 조용히 고르지 않는다 — 규칙은 호출자가 정한다" {
    const r = route(.{ .pane = "%3", .socket = "/tmp/s" }, &.{ .{ .nonce = "4331_7" }, .{ .nonce = "4331_9" } });
    try testing.expectEqual(@as(usize, 2), r.ambiguous);
}

test "붙어 있는 클라이언트가 없으면 귀속할 Term 이 없다" {
    try testing.expectEqual(Route.detached, route(.{ .pane = "%3", .socket = "/tmp/s" }, &.{}));
}

test "역조회 값도 다시 거른다 — 남의 프로세스 env 에서 읽은 값이다" {
    // 쓰레기만 있으면 unresolved 다(조용히 통과시키지 않는다).
    try testing.expectEqual(Route.unresolved, route(.{ .pane = "%3", .socket = "/tmp/s" }, &.{.{ .nonce = "../etc" }}));
    try testing.expectEqual(Route.unresolved, route(.{ .pane = "%3", .socket = "/tmp/s" }, &.{.{ .nonce = null }}));
    // 쓰레기와 정상이 섞이면 정상 하나만 센다.
    const r = route(.{ .pane = "%3", .socket = "/tmp/s" }, &.{ .{ .nonce = "A B" }, .{ .nonce = "4331_7" } });
    try testing.expectEqualStrings("4331_7", r.resolved);
}

test "pane 은 있는데 소켓만 없으면 절대 direct 로 새지 않는다" {
    // direct 로 새면 오염된 env 를 믿게 된다 — 이 축이 막으려는 바로 그것이다.
    try testing.expectEqual(Route.unresolved, route(.{ .pane = "%3" }, &.{.{ .nonce = "4331_7" }}));
}

test "detached 와 unresolved 를 섞지 않는다 — 원인이 다르면 대응도 다르다" {
    // 클라이언트 0 개 = detached(에이전트는 돌지만 볼 사람이 없다 — 보류할지 버릴지의 문제).
    try testing.expectEqual(Route.detached, route(.{ .pane = "%1", .socket = "/s" }, &.{}));
    // 클라이언트는 있는데 값을 못 읽음 = unresolved(권한·race — 다시 시도할 문제).
    try testing.expectEqual(Route.unresolved, route(.{ .pane = "%1", .socket = "/s" }, &.{.{ .nonce = null }}));
}

test "물어보지도 못한 것과 진짜 detached 를 구분한다 — 원인이 다르면 대응도 다르다" {
    // 원격에 tmux 바이너리가 없으면 출력이 통째로 빈다. 그것을 detached 로 접으면 「에이전트는 도는데
    // 볼 사람이 없다」로 잘못 읽고, 다시 시도할 기회를 잃는다(적대적 검증 2026-08-29).
    try testing.expectEqual(Route.unresolved, route(.{ .pane = "%0", .socket = "/s", .lookup_ran = false }, &.{}));
    // 물어봤는데 클라이언트가 0 개면 그때가 진짜 detached 다.
    try testing.expectEqual(Route.detached, route(.{ .pane = "%0", .socket = "/s", .lookup_ran = true }, &.{}));
}

test "한 줄만 유효하면 그것으로 정한다 — 나머지가 쓰레기여도" {
    const clients = [_]Client{ .{ .nonce = null }, .{ .nonce = "../x" }, .{ .nonce = "4331_9" }, .{ .nonce = "A B" } };
    try testing.expectEqualStrings("4331_9", route(.{ .pane = "%0", .socket = "/s" }, &clients).resolved);
}

test "parseSidecar: $TMUX 의 세 칸에서 소켓만 뗀다 — 통째로 넘기면 조회가 조용히 빈다" {
    const got = parseSidecar("/tmp/tmux-501/default,123,0\t%9\n").?;
    try testing.expectEqualStrings("/tmp/tmux-501/default", got.socket.?);
    try testing.expectEqualStrings("%9", got.pane.?);

    // 사용자가 `-S` 로 준 경로에 쉼표가 없을 수도 있다.
    const plain = parseSidecar("/tmp/mysock\t%1\n").?;
    try testing.expectEqualStrings("/tmp/mysock", plain.socket.?);
}

test "parseSidecar: tmux 밖이면 관측치가 없다 — 그러면 route 가 direct 다" {
    // 훅이 tmux 밖에서 남긴 옆 파일은 두 칸이 다 비어 있다(실측: 2 바이트).
    try testing.expect(parseSidecar("\t\n") == null);
    try testing.expect(parseSidecar("") == null);
    try testing.expect(parseSidecar("\n") == null);
    // pane 은 있는데 소켓이 없다 = tmux 안인데 어느 서버인지 모른다 → `unresolved` 로 접혀야 한다.
    const no_sock = parseSidecar("\t%9\n").?;
    try testing.expect(no_sock.socket == null);
    try testing.expectEqual(Route.unresolved, route(no_sock, &.{}));
}

test "parseClients: 빈 꼬리를 클라이언트로 세지 않는다 — 세면 ambiguous 로 잘못 접힌다" {
    var buf: [8]Client = undefined;

    // 클라이언트 하나가 값을 냈다.
    const one = parseClients("4331_7\n", &buf).?;
    try testing.expectEqual(@as(usize, 1), one.len);
    try testing.expectEqualStrings("4331_7", one[0].nonce.?);
    try testing.expectEqualStrings("4331_7", route(.{ .pane = "%9", .socket = "/s" }, one).resolved);

    // 둘이면 **조용히 하나 고르지 않는다**.
    const two = parseClients("4331_7\n4331_8\n", &buf).?;
    try testing.expectEqual(@as(usize, 2), two.len);
    try testing.expectEqual(@as(usize, 2), route(.{ .pane = "%9", .socket = "/s" }, two).ambiguous);

    // 값을 못 읽은 클라이언트는 빈 줄로 온다 — 클라이언트는 있지만 nonce 가 없다.
    const blank = parseClients("\n", &buf).?;
    try testing.expectEqual(@as(usize, 1), blank.len);
    try testing.expect(blank[0].nonce == null);
    try testing.expectEqual(Route.unresolved, route(.{ .pane = "%9", .socket = "/s" }, blank));

    // 아무 줄도 없다 = 붙어 있는 클라이언트가 없다(detached).
    const none = parseClients("", &buf).?;
    try testing.expectEqual(@as(usize, 0), none.len);
    try testing.expectEqual(Route.detached, route(.{ .pane = "%9", .socket = "/s" }, none));
}

test "parseClients: tmux 가 없으면 목록이 아니라 «물어보지도 못했다» 다" {
    var buf: [8]Client = undefined;
    try testing.expect(parseClients("motd\n" ++ no_tmux_marker ++ "\n", &buf) == null);
    // 그 경우 호출자는 `lookup_ran = false` 로 접고, 그것이 **detached 와 갈린다**.
    try testing.expectEqual(Route.unresolved, route(.{ .pane = "%9", .socket = "/s", .lookup_ran = false }, &.{}));
    try testing.expectEqual(Route.detached, route(.{ .pane = "%9", .socket = "/s", .lookup_ran = true }, &.{}));
}

test "lookupScript: 소켓과 pane 을 그대로 싣고, tmux 가 없으면 표식으로 말한다" {
    const a = testing.allocator;
    const script = try lookupScript(a, "/tmp/tmux-501/default", "%9");
    defer a.free(script);
    try testing.expect(std.mem.indexOf(u8, script, "-S '/tmp/tmux-501/default'") != null);
    try testing.expect(std.mem.indexOf(u8, script, "-t '%9'") != null);
    try testing.expect(std.mem.indexOf(u8, script, no_tmux_marker) != null);
    // 127 은 「연결 끊김」과 구분되지 않으므로 **0 으로 끝낸다**.
    try testing.expect(std.mem.indexOf(u8, script, "exit 0") != null);
    // 비대화형 PATH 가 좁아 Homebrew tmux 를 놓친 실측이 있었다 — 흔한 자리를 앞에 붙인다.
    try testing.expect(std.mem.indexOf(u8, script, "/opt/homebrew/bin") != null);
    // 클라이언트 env 를 읽는 두 길(Linux·macOS)이 모두 있어야 한다.
    try testing.expect(std.mem.indexOf(u8, script, "/proc/$p/environ") != null);
    try testing.expect(std.mem.indexOf(u8, script, "ps -E -p") != null);

    // ⚠️ **tmux 포맷은 중괄호 하나다.** Zig `allocPrint` 는 `{{` 를 `{` 로 접으므로 소스에 몇 개를 적는지
    // 틀리기 쉽고, 틀리면 `'#{{session_name}}'` 같은 문자열이 나가 tmux 가 **빈 줄을 준다** — 스크립트는
    // 성공하고 조회만 조용히 비어, 증상은 「tmux 안에서만 배지가 남의 pane 에 뜬다」 하나뿐이다.
    // 실제로 그렇게 한 번 틀렸고 실측으로만 잡혔다.
    try testing.expect(std.mem.indexOf(u8, script, "'#{session_name}'") != null);
    try testing.expect(std.mem.indexOf(u8, script, "'#{client_pid}'") != null);
    try testing.expect(std.mem.indexOf(u8, script, "{{") == null);
}
