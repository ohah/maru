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
