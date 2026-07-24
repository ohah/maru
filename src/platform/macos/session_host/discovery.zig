//! session-host **socket 발견 정책 + 경로**(§10) — P3-d2b의 순수 부분.
//!
//! GUI/CLI는 host에 connect할 때 "없으면 언제 helper를 띄우고 언제 그냥 실패하는가"를 정해야 한다(§10). 이 파일은
//! 그 결정을 **순수 state machine**으로 담는다 — 실제 connect/flock/spawn syscall은 P3-d2b의 platform 통합(discovery
//! 실행층·launcher)이 이 결정을 받아 수행한다. 순수라 non-macOS에서 발견 정책 회귀를 고정한다(platform import 0).
//!
//! §10 핵심 규칙:
//!   - `host.status`/`runtime.list/get`처럼 **조회** 의도는 host를 auto-start하지 않는다 — 없으면 `host_unavailable`.
//!   - 새 persistent Term의 `runtime.spawn` 의도만 on-demand로 helper를 띄운다.
//!   - 먼저 connect한다. 없을 때만 nonblocking start lock을 잡고, **lock을 얻은 쪽만** helper를 spawn한다. lock을 못 얻은
//!     쪽(loser)은 spawn하지 않고 잠깐 기다렸다 다시 connect한다(먼저 잡은 쪽이 띄운 host에 붙는다).
//!   - lock을 얻은 뒤에도 다시 connect해 본다 — lock 잡기 직전에 다른 프로세스가 bind했을 수 있어, 그러면 spawn하지 않고 그 host를 쓴다.

const std = @import("std");

/// 호출자가 host에 무엇을 하려는가. `query_only`는 auto-start 금지, `spawn_ready`만 on-demand launch를 허용한다(§10).
pub const Intent = enum { query_only, spawn_ready };

/// connect 시도 결과. `absent`=endpoint 없음/거절(ENOENT·ECONNREFUSED — stale이거나 아직 안 뜸), `denied`=권한/자격 실패.
pub const ConnectProbe = enum { connected, absent, denied };

/// nonblocking start lock 결과. `acquired`=내가 잡음(내가 시작 책임), `contended`=다른 프로세스가 홀드(나는 loser).
pub const LockProbe = enum { acquired, contended };

/// 발견 state machine이 지시하는 다음 행동. platform 통합층이 이 값에 따라 실 syscall을 한다.
pub const Action = enum {
    /// connect가 성공했다 — 그 연결을 그대로 쓴다.
    use_connection,
    /// query 의도인데 host가 없다 — auto-start하지 않고 `host_unavailable`로 끝낸다(§10).
    host_unavailable,
    /// spawn 의도 + host 없음 — nonblocking start lock을 시도해야 한다.
    need_start_lock,
    /// start lock을 얻었고 재connect도 실패했다 — 내가 detached helper를 spawn한 뒤 connect한다.
    spawn_host,
    /// start lock을 못 얻었다(loser) — spawn하지 않고 잠깐 기다렸다 다시 connect한다.
    wait_and_connect,
    /// connect가 권한/자격으로 거절됐다 — 회복 불가, 오류로 끝낸다.
    fail_denied,
};

/// 첫 connect 결과로 다음 행동을 정한다(§10 connect-first).
pub fn afterConnect(intent: Intent, probe: ConnectProbe) Action {
    return switch (probe) {
        .connected => .use_connection,
        .denied => .fail_denied,
        .absent => switch (intent) {
            .query_only => .host_unavailable, // 조회는 host를 띄우지 않는다.
            .spawn_ready => .need_start_lock, // spawn 의도만 start lock으로 진행.
        },
    };
}

/// start lock 결과와 lock 취득 뒤 재connect 결과로 다음 행동을 정한다(§10 "lock 획득 뒤 다시 connect").
pub fn afterStartLock(lock: LockProbe, reconnect: ConnectProbe) Action {
    return switch (lock) {
        .contended => .wait_and_connect, // loser는 spawn하지 않는다.
        .acquired => switch (reconnect) {
            .connected => .use_connection, // lock 직전에 다른 프로세스가 bind함 — 그 host를 쓴다(중복 spawn 방지).
            .denied => .fail_denied,
            .absent => .spawn_host, // 내가 helper를 띄운다.
        },
    };
}

// ── 경로(§10 macOS endpoint) ─────────────────────────────────────────────────

/// session-host 디렉터리 `<base>/session-host`. base는 caller가 정한다(테스트=격리 tmp, 제품=user cache dir).
/// control-plane(`<base>/control`)과 **다른 디렉터리**라 두 socket이 섞이지 않는다(§10). NUL 종단(mkdir/chmod용).
pub fn sessionHostDirPath(buf: []u8, base: []const u8) error{NoSpaceLeft}![:0]u8 {
    return std.fmt.bufPrintZ(buf, "{s}/session-host", .{trimTrailingSlash(base)});
}

/// 제어 socket 경로 `<dir>/control.sock`. session-host는 user login당 host 하나라 인스턴스 키 없이 고정 이름을 쓴다(§10).
pub fn socketPathIn(buf: []u8, dir: []const u8) error{NoSpaceLeft}![:0]u8 {
    return std.fmt.bufPrintZ(buf, "{s}/control.sock", .{trimTrailingSlash(dir)});
}

/// 라이브니스/start lock 경로 `<dir>/control.lock`(socket과 별도 regular 파일 — flock 대상, §10).
pub fn lockPathIn(buf: []u8, dir: []const u8) error{NoSpaceLeft}![:0]u8 {
    return std.fmt.bufPrintZ(buf, "{s}/control.lock", .{trimTrailingSlash(dir)});
}

/// host process lifetime 전체와 same-PID exec를 관통하는 배타적 owner lease.
pub fn ownerLockPathIn(buf: []u8, dir: []const u8) error{NoSpaceLeft}![:0]u8 {
    return std.fmt.bufPrintZ(buf, "{s}/owner.lock", .{trimTrailingSlash(dir)});
}

fn trimTrailingSlash(base: []const u8) []const u8 {
    if (base.len > 1 and base[base.len - 1] == '/') return base[0 .. base.len - 1];
    return base;
}

// ─────────────────────────────────────────────────────────────────────────────
// 단위 테스트
//
// 이 테스트가 증명하는 것(그리고 터미널에서 왜 중요한가): 여러 GUI/CLI가 동시에 host에 붙으려 할 때, host가 하나만
// 뜨고(중복 spawn 없음) 조회 명령은 죽은 host를 되살리지 않아야(§10) 유령 프로세스·경합이 안 생긴다. connect-first,
// query auto-start 금지, spawn 의도만 start lock, lock loser는 spawn 금지, lock 직전 race면 기존 host 사용을 순수
// state machine으로 고정한다. 경로도 control-plane과 분리됨을 확인한다. 순수라 non-macOS에서도 회귀를 잡는다.
// ─────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "discovery: connect-first uses an existing host" {
    try testing.expectEqual(Action.use_connection, afterConnect(.spawn_ready, .connected));
    try testing.expectEqual(Action.use_connection, afterConnect(.query_only, .connected));
}

test "discovery: query intent never auto-starts a missing host" {
    try testing.expectEqual(Action.host_unavailable, afterConnect(.query_only, .absent));
}

test "discovery: spawn intent on a missing host proceeds to a start lock" {
    try testing.expectEqual(Action.need_start_lock, afterConnect(.spawn_ready, .absent));
}

test "discovery: denied connect fails without spawning" {
    try testing.expectEqual(Action.fail_denied, afterConnect(.spawn_ready, .denied));
    try testing.expectEqual(Action.fail_denied, afterConnect(.query_only, .denied));
}

test "discovery: only the start-lock winner spawns; a loser waits and reconnects" {
    // 내가 lock을 얻고 재connect도 실패 → 내가 spawn.
    try testing.expectEqual(Action.spawn_host, afterStartLock(.acquired, .absent));
    // lock을 못 얻음(다른 프로세스가 시작 중) → spawn하지 않고 기다렸다 connect.
    try testing.expectEqual(Action.wait_and_connect, afterStartLock(.contended, .absent));
    try testing.expectEqual(Action.wait_and_connect, afterStartLock(.contended, .connected));
}

test "discovery: winning the lock but finding a freshly-bound host uses it (no double spawn)" {
    // lock을 잡기 직전에 다른 프로세스가 bind함 → 그 host를 쓴다(중복 spawn 방지).
    try testing.expectEqual(Action.use_connection, afterStartLock(.acquired, .connected));
    try testing.expectEqual(Action.fail_denied, afterStartLock(.acquired, .denied));
}

test "discovery: paths are under session-host dir and separate from control-plane" {
    var dir_buf: [256]u8 = undefined;
    const dir = try sessionHostDirPath(&dir_buf, "/tmp/cache");
    try testing.expectEqualStrings("/tmp/cache/session-host", dir);
    var sp_buf: [256]u8 = undefined;
    try testing.expectEqualStrings("/tmp/cache/session-host/control.sock", try socketPathIn(&sp_buf, dir));
    var lp_buf: [256]u8 = undefined;
    try testing.expectEqualStrings("/tmp/cache/session-host/control.lock", try lockPathIn(&lp_buf, dir));
    var op_buf: [256]u8 = undefined;
    try testing.expectEqualStrings("/tmp/cache/session-host/owner.lock", try ownerLockPathIn(&op_buf, dir));
    // trailing slash 정규화.
    var d2: [256]u8 = undefined;
    try testing.expectEqualStrings("/tmp/session-host", try sessionHostDirPath(&d2, "/tmp/"));
}
