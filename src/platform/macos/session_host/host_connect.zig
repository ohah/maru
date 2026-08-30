//! host_connect — client의 **connect-or-launch 오케스트레이션**(§10 발견 실행층) — P3-e3-4.
//!
//! `discovery.zig`(순수 state machine)의 결정을 실 syscall(connect/flock/spawnDetached)로 **수행**한다: host가 있으면
//! 붙고, 없으면 detached helper를 **하나만** 띄워 붙는다(여러 GUI가 동시에 시작해도 중복 spawn 없이 — start lock winner만
//! spawn). AppSession이 keep-alive일 때 이걸 불러 host connection을 얻는다(e3-4b). 실패하면 null → caller가 in-process로
//! 폴백한다(host 문제가 GUI를 막지 않는다). macOS 전용(실 fork/exec/flock; 순수 결정은 discovery.zig가 이미 테스트).

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;
const discovery = @import("discovery.zig");
const launcher = @import("launcher.zig");
const client_mod = @import("client.zig");
const framing = @import("framing.zig");
const protocol = @import("protocol.zig");
const registry_mod = @import("registry.zig");
const socket_server = @import("socket_server.zig");
const host_manifest = @import("host_manifest.zig");
const short_endpoint = @import("short_endpoint.zig");
const screen_stream = @import("maru").session.screen_stream;
const owner_lease = @import("owner_lease.zig");
const attach_phase_deadline = @import("attach_phase_deadline.zig");
const client_deadline = @import("client_deadline.zig");
const staged_image = @import("staged_image.zig");
const compatibility = @import("compatibility.zig");
const upgrade_wire = @import("upgrade_wire.zig");

// flock(2)은 std.c 미노출(macOS 전용). start lock 직렬화용. LOCK_EX=2·LOCK_NB=4(sys/file.h).
extern "c" fn flock(fd: c_int, operation: c_int) c_int;
const LOCK_EX: c_int = 2;
const LOCK_NB: c_int = 4;
extern "c" fn usleep(usec: c_uint) c_int;
extern "c" fn arc4random_buf(buf: [*]u8, nbytes: usize) void;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

pub const Options = struct {
    /// spawn 뒤(또는 lock loser로서) host가 뜰 때까지 재connect 시도 횟수 × 간격. 기본 150×20ms=3s(cold launch 여유).
    connect_attempts: usize = 150,
    connect_delay_ms: u32 = 20,
};

/// CR6e baseline이 deadline-aware 제품 issuer의 실제 attempt/wait 횟수를 raw artifact로
/// 남기는 write-only observation이다. reconnect 결과나 정책을 바꾸지 않으며 일반 제품 caller는 null을 쓴다.
pub const DeadlineConnectObservation = struct {
    attempt_count: u32 = 0,
    backoff_wait_count: u32 = 0,
};

pub const FailureReason = enum {
    invalid_endpoint,
    endpoint_denied,
    incompatible_version,
    handshake_failed,
    protocol_error,
    resource_exhausted,
    transient_timeout,
    unauthorized,
    launch_failed,
    startup_timeout,
    invalid_manifest,
    stale_manifest,
    out_of_memory,
    deadline_exceeded,
    /// 그 `host_id`의 host **프로세스가 사라졌다**는 긍정적 증거가 있다(manifest도 legacy endpoint도 없음, 또는 manifest는
    /// 남았지만 endpoint 무응답 + owner lease 사망 = 재부팅·crash 뒤 stale manifest). 나머지 reason과 달리 "재시도하면
    /// 될 수도"가 아니라 **영구**다. 저장된 runtime을 종료 placeholder로 둘지 판정하는 caller가 이 구분에 의존한다 —
    /// 일시 실패를 영구로 오분류하면 살아 있는 세션을 placeholder로 굳혀 사용자가 잃는다(§7 접속 실패 행렬).
    host_gone,
};

pub const Outcome = union(enum) {
    connected: client_mod.Client,
    failed: FailureReason,
};

pub const UpgradeLocalFailure = enum {
    status_query_failed,
    no_attempt_record,
};

pub const UpgradeFailure = union(enum) {
    report: upgrade_wire.AttemptReport,
    reconnect: FailureReason,
    local: UpgradeLocalFailure,
};

/// A bounded value copied from the connect owner to AppSession. It contains no borrowed manifest,
/// JSON, or Client storage, so the UI can defer presentation until a modal-free frame.
pub const UpgradeNotice = union(enum) {
    upgraded: u128,
    upgrade_busy: u128,
    legacy_unavailable: u128,
    upgrade_failed: struct {
        host_id: u128,
        failure: UpgradeFailure,
    },

    pub fn detail(self: UpgradeNotice, buf: []u8) []const u8 {
        return switch (self) {
            .upgraded => |host_id| std.fmt.bufPrint(buf, "result=upgraded host={x:0>32}", .{host_id}),
            .upgrade_busy => |host_id| std.fmt.bufPrint(buf, "result=upgrade_busy host={x:0>32}", .{host_id}),
            .legacy_unavailable => |host_id| std.fmt.bufPrint(buf, "result=legacy_unavailable host={x:0>32}", .{host_id}),
            .upgrade_failed => |failed| switch (failed.failure) {
                .report => |report| std.fmt.bufPrint(
                    buf,
                    "result=upgrade_failed host={x:0>32} status={s} reason={s}",
                    .{ failed.host_id, @tagName(report.status), @tagName(report.reason) },
                ),
                .reconnect => |reason| std.fmt.bufPrint(
                    buf,
                    "result=upgrade_failed host={x:0>32} reconnect={s}",
                    .{ failed.host_id, @tagName(reason) },
                ),
                .local => |reason| std.fmt.bufPrint(
                    buf,
                    "result=upgrade_failed host={x:0>32} local={s}",
                    .{ failed.host_id, @tagName(reason) },
                ),
            },
        } catch "result=upgrade_failed detail=truncated";
    }
};

pub const DetailedOutcome = struct {
    outcome: Outcome,
    upgrade_notice: ?UpgradeNotice = null,
};

fn plain(outcome: Outcome) DetailedOutcome {
    return .{ .outcome = outcome };
}

/// host에 연결하거나(있으면) detached helper를 띄워 연결한다(§10 connect-first→start-lock→spawn). 반환 `Client`는
/// **caller 소유**(deinit 책임). `null`이면 host를 못 얻었다(권한 거부·spawn 실패·denied 등) — caller는 in-process로
/// 폴백한다. `exe_path`=현재 maru 실행 파일(helper로 exec), `base_cache_dir`=user cache dir(그 아래 `session-host/`).
pub fn connectOrLaunch(
    allocator: std.mem.Allocator,
    exe_path: [:0]const u8,
    base_cache_dir: []const u8,
    opts: Options,
) ?client_mod.Client {
    return switch (connectOrLaunchDetailed(allocator, exe_path, base_cache_dir, opts).outcome) {
        .connected => |client| client,
        .failed => null,
    };
}

pub fn connectOrLaunchDetailed(
    allocator: std.mem.Allocator,
    exe_path: [:0]const u8,
    base_cache_dir: []const u8,
    opts: Options,
) DetailedOutcome {
    if (builtin.os.tag != .macos) return plain(.{ .failed = .invalid_endpoint });

    var dir_buf: [512]u8 = undefined;
    const dir = discovery.sessionHostDirPath(&dir_buf, base_cache_dir) catch return plain(.{ .failed = .invalid_endpoint });

    // Manifest-capable host는 host별 short endpoint를 쓰므로 fixed major socket보다 registry를 먼저 본다.
    if (findCurrentManifestHost(allocator, exe_path, base_cache_dir, dir)) |outcome| return plain(outcome);

    var sock_buf: [640]u8 = undefined;
    const socket = discovery.socketPathIn(&sock_buf, dir) catch return plain(.{ .failed = .invalid_endpoint });
    var legacy_sock_buf: [640]u8 = undefined;
    const legacy_socket = discovery.legacySocketPathIn(&legacy_sock_buf, dir) catch return plain(.{ .failed = .invalid_endpoint });

    // 1. connect-first(§10): 있으면 바로 쓴다.
    switch (tryConnect(allocator, socket)) {
        .connected => |client| return plain(.{ .connected = client }),
        .absent => {},
        .transient => return plain(connectWithBackoffDetailed(allocator, socket, opts)),
        .failed => |reason| return plain(.{ .failed = reason }),
    }

    // versioned endpoint 전환 이전의 current-major host는 그대로 재사용한다. legacy endpoint의 다른 major는
    // current header handshake를 닫으므로 새 versioned host를 side-by-side로 시작하고, saved runtime restore가
    // 별도 N-1 adapter로 legacy endpoint를 찾는다.
    switch (tryConnect(allocator, legacy_socket)) {
        .connected => |client| return plain(.{ .connected = client }),
        .absent => {},
        .transient => return plain(connectWithBackoffDetailed(allocator, legacy_socket, opts)),
        .failed => |reason| switch (reason) {
            .incompatible_version, .handshake_failed, .protocol_error => {},
            else => return plain(.{ .failed = reason }),
        },
    }

    // 2. need_start_lock: lock 파일을 열고 nonblocking flock으로 "내가 시작 책임인가"를 가른다. lock은 fd close로 해제되며,
    // spawn+재connect가 끝날 때까지(defer) 잡고 있어 동시 시작자들이 하나의 host로 수렴하게 한다(daemon은 socket bind가
    // liveness라 lock을 안 쓴다 — 순수 시작 직렬화용).
    ensureDir(dir);
    const lock_fd = openLock(dir) orelse return plain(.{ .failed = .endpoint_denied });
    defer _ = c.close(lock_fd);
    const lock_probe: discovery.LockProbe = if (flock(lock_fd, LOCK_EX | LOCK_NB) == 0) .acquired else .contended;

    // 3. lock 취득/경합 뒤 다시 connect(§10 "lock 직전 race"): 그 사이 다른 프로세스가 bind했을 수 있다.
    switch (tryConnect(allocator, socket)) {
        .connected => |client| return plain(.{ .connected = client }),
        .transient => return plain(connectWithBackoffDetailed(allocator, socket, opts)),
        .failed => |reason| return plain(.{ .failed = reason }),
        .absent => {},
    }
    if (lock_probe == .contended) {
        if (connectManifestRegistryWithBackoff(allocator, exe_path, base_cache_dir, dir, opts)) |outcome|
            return plain(outcome);
        // 이전 winner가 publish 전에 실패했으면 loser가 영구 fallback하지 않고 lock을 한 번 재획득해 launch owner가 된다.
        if (flock(lock_fd, LOCK_EX | LOCK_NB) != 0) return plain(.{ .failed = .startup_timeout });
    }

    // Lock 취득 뒤 registry도 다시 읽는다. 다른 process가 manifest를 publish한 직후 fixed endpoint가 비어 있는
    // host-specific 모델에서도 중복 spawn을 막는다.
    if (findCurrentManifestHost(allocator, exe_path, base_cache_dir, dir)) |outcome| return plain(outcome);

    // 같은 build의 host가 없다면, **다른 build의 살아 있는 host**를 새 이미지로 exec 교체해 그 runtime을 그대로
    // 이어받는다. 여기(start lock 획득 뒤)에서 하는 이유: lock이 동시 시작자를 직렬화하므로 두 GUI가 같은 host에
    // 동시에 upgrade를 걸지 않는다. 실패하면 아래 spawn 경로가 그대로 새 host를 띄운다(회귀 없음).
    var upgrade_notice: ?UpgradeNotice = null;
    switch (tryUpgradeExistingHost(allocator, exe_path, base_cache_dir, dir)) {
        .none => {},
        .connected => |client| {
            const upgraded_host_id = client.host_id;
            return .{ .outcome = .{ .connected = client }, .upgrade_notice = .{ .upgraded = upgraded_host_id } };
        },
        .fallback => |notice| upgrade_notice = notice,
        .failed => |reason| return plain(.{ .failed = reason }),
    }

    short_endpoint.prepareCurrentUserNamespace() catch return plain(.{ .failed = .endpoint_denied });
    var host_id: u128 = 0;
    while (host_id == 0) arc4random_buf(std.mem.asBytes(&host_id).ptr, @sizeOf(u128));
    var short_socket_buf: [128]u8 = undefined;
    const short_socket = short_endpoint.currentSocketPathIn(&short_socket_buf, host_id) catch
        return plain(.{ .failed = .invalid_endpoint });
    launcher.spawnSessionHostDetached(allocator, exe_path, dir, short_socket, host_id) catch
        return plain(.{ .failed = .launch_failed });
    const launched = connectNewHostWithBackoff(allocator, base_cache_dir, host_id, opts);
    return switch (launched) {
        .connected => |client| .{ .outcome = .{ .connected = client }, .upgrade_notice = upgrade_notice },
        .failed => |reason| plain(.{ .failed = reason }),
    };
}

fn findCurrentManifestHost(
    allocator: std.mem.Allocator,
    exe_path: [:0]const u8,
    base_cache_dir: []const u8,
    session_dir: [:0]const u8,
) ?Outcome {
    const build_id = host_manifest.buildIdForExecutable(allocator, exe_path) catch return null;
    defer allocator.free(build_id);
    var hosts_buf: [640]u8 = undefined;
    const hosts_root = host_manifest.hostsRootPathIn(&hosts_buf, session_dir) catch return .{ .failed = .invalid_endpoint };
    const directory = c.opendir(hosts_root.ptr) orelse return null;
    defer _ = c.closedir(directory);
    while (c.readdir(directory)) |entry| {
        const name = std.mem.sliceTo(entry.name[0..], 0);
        if (name.len != 32) continue;
        const host_id = std.fmt.parseInt(u128, name, 16) catch continue;
        if (host_id == 0) continue;
        var manifest = host_manifest.load(allocator, session_dir, host_id) catch continue;
        defer manifest.deinit();
        // 후보를 **왜** 건너뛰었는지 남긴다.
        //
        // 2026-08-30: 사용자 PTY 22 개를 쥔 host 를 두고 앱이 새 host 를 띄웠는데, 이 루프가 조용히
        // `continue` 만 해서 build_id 때문인지 lease 때문인지 lifecycle 때문인지 로그로 갈리지 않았다.
        // 코드를 읽어 추론할 수는 있지만 그때의 manifest 상태는 이미 사라진 뒤다. 후보마다 한 줄이면
        // 「어느 host 를 어떤 이유로 버렸는가」가 사후에 재구성된다.
        const skip_reason: ?[]const u8 = if (manifest.protocol_major != protocol.version_major)
            "protocol_major"
        else if (manifest.screen_codec_version != screen_stream.codec_version)
            "screen_codec"
        else if (manifest.lifecycle != .ready)
            "lifecycle"
        else if (!std.mem.eql(u8, manifest.build_id, build_id))
            "build_id"
        else if (ownerLeaseState(session_dir, host_id) != .held)
            // 여기서는 `held`(생존이 확인된 host)만 재사용 대상이다. `.unknown`(우리가 못 봄)에 새 spawn을 붙이는 쪽이
            // 기존 세션에 안전하다 — 이 경로의 오판 비용은 host 하나를 더 띄우는 것뿐이다(restore 경로와 대비).
            "owner_lease"
        else
            null;
        if (skip_reason) |reason| {
            if (!builtin.is_test)
                std.log.info("session host candidate skipped: host={x:0>32} reason={s}", .{ host_id, reason });
            continue;
        }
        switch (connectExistingHost(allocator, base_cache_dir, host_id)) {
            .connected => |client| return .{ .connected = client },
            .failed => |reason| if (reason == .out_of_memory) return .{ .failed = reason },
        }
    }
    return null;
}

/// exec 뒤 재연결 예산. host의 pause budget(`upgrade_limits.pause_budget_ms` = 5s)**만으로는 부족하다** — 그 뒤에
/// 새 이미지 부팅·handoff 복원·manifest 재게시가 이어지고, 그동안 manifest lifecycle이 `.restoring`이라 어떤 스캔도
/// (`findCurrentManifestHost`도 `isUpgradeCandidate`도 `.ready`만 센다) 이 host를 기다려 주지 않는다.
///
/// 여기서 일찍 포기하면 **같은 build_id host가 둘** 남는다: exec된 쪽이 사용자 PTY를 전부 들고 있고, 새로 spawn된
/// 쪽은 비어 있는데, 이후 스캔은 `readdir` 순서로 아무거나 고른다. 그러면 사용자의 셸이 영구히 도달 불가가 되어
/// 이 경로가 막으려던 고아화를 그대로 재생산하며, 스스로 회복되지도 않는다. 넉넉히 잡는 대신 치르는 비용은
/// **업그레이드가 실패했을 때의 대기**뿐이라, 잃는 쪽이 훨씬 싼 비대칭이다.
const upgrade_reconnect_delay_ms: u32 = 20;
const upgrade_reconnect_attempts: usize = 500; // × 20ms = 10s (pause budget 5s + 부팅·복원 여유)

/// Structured logging and the UI notice share this exact bounded value. Formatting a second model
/// here would let the two surfaces disagree about whether the old PTYs were migrated.
fn logUpgradeNotice(notice: UpgradeNotice) void {
    if (builtin.is_test) return;
    var buf: [256]u8 = undefined;
    std.log.info("session host upgrade result: {s}", .{notice.detail(&buf)});
}

const UpgradeReconnect = union(enum) {
    connected: client_mod.Client,
    failed: UpgradeNotice,
};

/// 재연결한 host를 업그레이드 결과로 **채택해도 되는가**. hello ack의 build_id가 target과 정확히 같아야 한다.
///
/// `null`(광고 안 함)은 거부다 — fail-closed. build_id를 모르는 host는 우리가 보낸 이미지로 돌고 있다는 증거가
/// 없고, 증거 없이 채택하면 아래 `reconnectUpgradedHost` 주석의 실패 모드로 그대로 들어간다.
pub fn upgradedHostMatches(restored_build_id: ?[]const u8, target_build_id: []const u8) bool {
    const restored = restored_build_id orelse return false;
    return std.mem.eql(u8, restored, target_build_id);
}

/// exec 뒤 같은 host_id로 다시 붙되, **정말 새 이미지로 바뀌었는지 확인한다.** 실패하면 `null` — 호출자가
/// 기존대로 새 host를 spawn한다.
///
/// 재연결 성공만으로는 부족하다. host가 accepted를 보내고도 exec에 실패해 rollback하면 **같은 host_id로 다시
/// 붙지만 이미지는 옛것 그대로**다. 그 연결을 그대로 채택하면 GUI는 host-backed라고 믿고 `runtime.spawn`을
/// 걸었다가, 옛 host가 모르는 capability(`runtime_core_command_v1` 등) 때문에 `UnsupportedSpawnContract`로
/// 실패해 in-process로 떨어진다. build_id 게이팅이 원래 막아 주던 상황을 우리가 우회해서 만들어 내는 셈이라,
/// 업그레이드를 안 하느니만 못한 회귀가 된다(실측: 앱 업데이트 뒤 모든 터미널이 in-process로 폴백했다).
///
/// 그래서 hello ack의 build_id가 target과 **정확히 같을 때만** 채택하고, 아니면 연결을 버린다.
fn reconnectUpgradedHost(
    allocator: std.mem.Allocator,
    base_cache_dir: []const u8,
    host_id: u128,
    target_build_id: []const u8,
    attempt_id: u128,
) UpgradeReconnect {
    var restored = switch (connectNewHostWithBackoff(allocator, base_cache_dir, host_id, .{
        .connect_attempts = upgrade_reconnect_attempts,
        .connect_delay_ms = upgrade_reconnect_delay_ms,
    })) {
        .connected => |client| client,
        // 재연결조차 못 했으면 물어볼 상대가 없다. host가 exec 도중 죽었을 수도, 아직 restoring일 수도 있다.
        .failed => |reason| {
            const notice: UpgradeNotice = .{ .upgrade_failed = .{
                .host_id = host_id,
                .failure = .{ .reconnect = reason },
            } };
            logUpgradeNotice(notice);
            return .{ .failed = notice };
        },
    };
    if (!upgradedHostMatches(restored.build_id, target_build_id)) {
        // **왜 안 바뀌었는지 host에게 직접 묻는다.** 이 조회가 없으면 "재연결은 됐는데 옛 이미지"라는 사실만 알고
        // 그 이유(exec_failed·rolled_back·target_invalid…)는 영영 알 수 없다 — 정확히 그 상태로 이 회귀를 한참
        // 추적했다. 조회 자체가 실패해도 그 사실을 남겨 "묻지 못했음"과 "물었는데 기록이 없음"을 구분한다.
        const failure: UpgradeFailure = if (restored.upgradeStatus(attempt_id)) |maybe_report|
            if (maybe_report) |report| .{ .report = report } else .{ .local = .no_attempt_record }
        else |_|
            .{ .local = .status_query_failed };
        restored.deinit();
        const notice: UpgradeNotice = .{ .upgrade_failed = .{ .host_id = host_id, .failure = failure } };
        logUpgradeNotice(notice);
        return .{ .failed = notice };
    }
    const notice: UpgradeNotice = .{ .upgraded = host_id };
    logUpgradeNotice(notice);
    return .{ .connected = restored };
}

/// exec 업그레이드 후보 판정에 필요한 manifest 사실만 담는다. 실 `Manifest`는 allocator가 소유한 슬라이스를
/// 들고 있어 순수 판정 테스트에 쓰기 어렵다 — 판정에 쓰이는 값만 떼어내 syscall 없이 회귀를 고정한다.
pub const UpgradeCandidate = struct {
    protocol_major: u16,
    screen_codec_version: u16,
    lifecycle: host_manifest.Lifecycle,
    build_id: []const u8,
};

/// 이 host를 새 이미지로 exec 교체해도 되는가. **순수 판정**이라 단위 테스트로 고정한다.
///
/// 네 조건을 모두 만족해야 한다.
///   - wire가 같다(`protocol_major`·`screen_codec_version`): 다르면 exec 교체 대상이 아니라 side-by-side 대상이며
///     N-1 adapter가 그 host의 runtime을 따로 이어받는다. 여기서 교체하면 살아 있는 구 major 세션을 잃는다.
///   - `lifecycle == .ready`: draining 중인 host는 이미 정리 경로에 있어 새 이미지를 얹으면 안 된다.
///   - build_id가 **다르다**: 같으면 교체할 것이 없다(그 host는 `findCurrentManifestHost`가 이미 재사용했다).
///   - owner lease가 `.held`: 살아 있다는 **긍정적 증거**가 있을 때만 손댄다. `.free`(죽음)는 교체가 아니라 정리
///     대상이고, `.unknown`(우리가 못 봄)에 exec을 걸면 우리 쪽 사정으로 남의 host를 흔드는 것이 된다.
pub fn isUpgradeCandidate(
    candidate: UpgradeCandidate,
    target_build_id: []const u8,
    lease: owner_lease.Observation,
) bool {
    if (candidate.protocol_major != protocol.version_major) return false;
    if (candidate.screen_codec_version != screen_stream.codec_version) return false;
    if (candidate.lifecycle != .ready) return false;
    if (std.mem.eql(u8, candidate.build_id, target_build_id)) return false;
    return lease == .held;
}

/// build_id만 다른 **살아 있는 host**를 찾아 same-PID exec 업그레이드를 시도한다(docs/session-host-upgrade.md).
/// 성공하면 그 host가 새 이미지로 전환된 뒤의 Client를 반환한다 — host_id·PTY master·자식 프로세스·scrollback이
/// 모두 보존돼 사용자의 셸이 앱 업데이트를 넘어 살아남는다.
///
/// 이 경로가 없으면 새 빌드는 매번 새 host를 띄우고 이전 host의 runtime은 GUI에서 도달할 수 없는 고아가 된다
/// (실측: build_id별로 host가 4개까지 쌓이고 그 아래 셸이 접근 불가 상태로 남았다).
///
/// 실패는 전부 조용히 `null`이다 — 업그레이드는 **최적화**이고, 안 되면 호출자가 기존대로 새 host를 spawn하면
/// 된다. 여기서 오류를 올리면 "업그레이드 불가"가 곧 "터미널을 못 엶"이 되어 회귀가 된다.
const UpgradeSearch = union(enum) {
    none,
    connected: client_mod.Client,
    fallback: UpgradeNotice,
    failed: FailureReason,
};

fn tryUpgradeExistingHost(
    allocator: std.mem.Allocator,
    exe_path: [:0]const u8,
    base_cache_dir: []const u8,
    session_dir: [:0]const u8,
) UpgradeSearch {
    const target_identity = staged_image.inspect(exe_path) catch return .none;
    // build id를 **같은 inspect 결과에서** 유도한다(`buildIdForExecutable`은 경로를 한 번 더 읽는다). 두 번 읽으면
    // 그 사이 번들이 교체될 때(앱 업데이트가 실행 중에 끝나는 경우) build_id와 sha256이 서로 다른 바이트를 가리켜
    // host의 staging 해시 검증이 실패한다 — 게다가 같은 파일을 두 번 SHA-256하는 낭비다.
    const target_hex = std.fmt.bytesToHex(target_identity.sha256, .lower);
    const target_build_id = std.fmt.allocPrint(allocator, "sha256:{s}", .{&target_hex}) catch return .none;
    defer allocator.free(target_build_id);

    var hosts_buf: [640]u8 = undefined;
    const hosts_root = host_manifest.hostsRootPathIn(&hosts_buf, session_dir) catch return .none;
    const directory = c.opendir(hosts_root.ptr) orelse return .none;
    defer _ = c.closedir(directory);
    var legacy_notice: ?UpgradeNotice = null;
    while (c.readdir(directory)) |entry| {
        const name = std.mem.sliceTo(entry.name[0..], 0);
        if (name.len != 32) continue;
        const host_id = std.fmt.parseInt(u128, name, 16) catch continue;
        if (host_id == 0) continue;
        var manifest = host_manifest.load(allocator, session_dir, host_id) catch continue;
        defer manifest.deinit();
        if (!isUpgradeCandidate(.{
            .protocol_major = manifest.protocol_major,
            .screen_codec_version = manifest.screen_codec_version,
            .lifecycle = manifest.lifecycle,
            .build_id = manifest.build_id,
        }, target_build_id, ownerLeaseState(session_dir, host_id))) {
            // 스캔이 조용히 넘어가면 「살아 있는 host 를 두고 왜 새로 띄웠나」가 사후에 재구성되지 않는다.
            // 형제 스캔(`findCurrentManifestHost`)과 같은 이유로 후보마다 한 줄 남긴다.
            if (!builtin.is_test)
                std.log.info("session host upgrade candidate rejected: host={x:0>32} lifecycle={s} lease={s}", .{
                    host_id,
                    @tagName(manifest.lifecycle),
                    @tagName(ownerLeaseState(session_dir, host_id)),
                });
            continue;
        }

        var client = switch (connectExistingHost(allocator, base_cache_dir, host_id)) {
            .connected => |connected| connected,
            // OOM은 host에 대한 증거가 아니라 우리 쪽 사정이다. 삼키고 계속 스캔하면 메모리 압박 상황에서 host
            // 프로세스만 하나 더 늘린다 — 형제 스캔(`findCurrentManifestHost`)과 같은 규율로 즉시 올린다.
            .failed => |reason| if (reason == .out_of_memory)
                return .{ .failed = reason }
            else
                continue,
        };
        // capability를 광고하지 않는 구 host는 exec 교체를 모른다. **죽이지 않고** 그대로 둔다 — 그 아래 runtime이
        // 살아 있고, capability 없는 host를 종료해 migration처럼 보이게 하지 않는다(session-host-upgrade.md).
        if (!client.host_exec_upgrade_v1) {
            client.deinit();
            if (legacy_notice == null) legacy_notice = .{ .legacy_unavailable = host_id };
            continue;
        }
        var attempt_id: u128 = 0;
        while (attempt_id == 0) arc4random_buf(std.mem.asBytes(&attempt_id).ptr, @sizeOf(u128));
        const outcome = client.prepareUpgrade(.{
            .attempt_id = attempt_id,
            .target_path = exe_path,
            .target_build_id = target_build_id,
            .target_sha256 = target_identity.sha256,
            .handoff_reader_min = 1,
            .handoff_reader_max = 1,
        }) catch {
            // 응답을 못 받았다고 host가 아무것도 안 한 것은 아니다. server는 target 이미지를 복사·fsync·해시한
            // **뒤에** accepted를 쓰므로, 느린 디스크에서는 우리 recv 타임아웃이 먼저 만료되고 host는 그대로
            // exec한다. 그때 다른 host로 스캔을 이어 가면 이미 교체 중인 host를 두고 또 다른 host를 흔든다 —
            // 재연결로 결과를 확인하고, 아니면 여기서 끝낸다.
            client.deinit();
            return switch (reconnectUpgradedHost(allocator, base_cache_dir, host_id, target_build_id, attempt_id)) {
                .connected => |connected| .{ .connected = connected },
                .failed => |notice| .{ .fallback = notice },
            };
        };
        client.deinit();
        // **prepare를 한 번 보낸 뒤에는 결과와 무관하게 스캔을 끝낸다.** 한 번의 GUI 실행이 여러 host에 연쇄로
        // upgrade를 걸면 각 host가 클라이언트를 떨어뜨리며 재시작하는데, 그 피해는 새 host 하나를 더 띄우는
        // 것보다 훨씬 크다. 거절(`rejected`)도 마찬가지다 — host는 다른 attachment가 남아 있으면 거절하며,
        // 그건 "지금은 안 된다"이지 "이 host는 못 쓴다"가 아니다.
        switch (outcome) {
            // host가 응답을 전량 보낸 뒤 이 connection을 닫고 exec한다 — 같은 host_id로 다시 붙는다.
            .accepted_reconnect_required => return switch (reconnectUpgradedHost(
                allocator,
                base_cache_dir,
                host_id,
                target_build_id,
                attempt_id,
            )) {
                .connected => |connected| .{ .connected = connected },
                .failed => |notice| .{ .fallback = notice },
            },
            // host가 이미 끝난 attempt를 보고했다 — `AttemptReason`이 왜 못 바꿨는지 말해 준다. 이 값을 버리면
            // 사용자는 "업데이트했는데 세션이 안 이어진다"만 겪고 우리는 이유를 못 본다.
            .completed => |report| {
                if (report.status == .committed) {
                    return switch (reconnectUpgradedHost(
                        allocator,
                        base_cache_dir,
                        host_id,
                        target_build_id,
                        attempt_id,
                    )) {
                        .connected => |connected| .{ .connected = connected },
                        .failed => |notice| .{ .fallback = notice },
                    };
                }
                const notice: UpgradeNotice = .{ .upgrade_failed = .{
                    .host_id = host_id,
                    .failure = .{ .report = report },
                } };
                logUpgradeNotice(notice);
                return .{ .fallback = notice };
            },
            // 거절에는 이유가 실려 오지 않는다(문서 §240: 다른 attachment가 남아 있으면 거절). 적어도 "거절당했다"는
            // 사실은 남겨, 조용한 폴백과 구분되게 한다.
            .rejected => {
                const notice: UpgradeNotice = .{ .upgrade_busy = host_id };
                logUpgradeNotice(notice);
                return .{ .fallback = notice };
            },
        }
    }
    if (legacy_notice) |notice| {
        logUpgradeNotice(notice);
        return .{ .fallback = notice };
    }
    return .none;
}

/// owner lease 관측 결과. bool로 뭉개면 **"lease가 없다"(host가 죽었다는 증거)** 와 **"우리가 볼 수 없었다"**(fd 고갈·
/// 권한·심링크)가 같은 값이 되고, 그 값이 곧바로 `host_gone`(영구) 판정에 쓰인다 — 우리 쪽 사정으로 살아 있는 host를
/// 사라졌다고 단정하는 것이다. 오분류 비용이 비대칭이므로(§7 접속 실패 행렬) 증거 없음을 별도 상태로 남긴다(code-review).
fn ownerLeaseState(session_dir: [:0]const u8, host_id: u128) owner_lease.Observation {
    var path_buf: [832]u8 = undefined;
    const path = host_manifest.ownerLockPathIn(&path_buf, session_dir, host_id) catch return .unknown;
    return owner_lease.observe(path);
}

fn connectNewHostWithBackoff(
    allocator: std.mem.Allocator,
    base_cache_dir: []const u8,
    host_id: u128,
    opts: Options,
) Outcome {
    var attempts: usize = 0;
    while (attempts < opts.connect_attempts) : (attempts += 1) {
        switch (connectExistingHost(allocator, base_cache_dir, host_id)) {
            .connected => |client| return .{ .connected = client },
            .failed => |reason| switch (reason) {
                // 우리가 **방금 spawn한** host가 manifest를 publish할 때까지 기다리는 루프다. 이 시점의 "manifest도
                // endpoint도 없다"(host_gone)는 "사라졌다"가 아니라 "아직 안 떴다"이므로 재시도 대상이다 — host_gone의
                // 영구 의미는 이미 실행 중인 host를 조회하는 restore 경로(connectExistingHost 직접 호출)에서만 성립한다.
                // 이걸 빼면 갓 띄운 host를 첫 폴에서 버리고 in-process로 폴백한다(회귀).
                // `transient_timeout`은 **일부러 뺐다.** 안쪽 backoff가 이제 hello 실패에 자기 예산(10×20ms)을
                // 쓰므로, 여기서까지 재시도하면 500×220ms≈110s 가 되어 위 주석이 상정한 10s 예산이 11배로
                // 부풀고 업그레이드 실패 시 앱 시작이 그만큼 늦어진다. 고치려던 것보다 나쁜 회귀다.
                // `stale_manifest`도 재시도한다. exec upgrade 직후에는 host 가 아직 restore 중이라
                // manifest 를 **자기 새 이미지 값으로 정정하기 전**이고, 그 찰나에 읽으면 hello(새것)와
                // manifest(옛것)가 어긋난다. 그건 "영구히 틀린 host"가 아니라 **아직 갱신 전**이다.
                //
                // 2026-08-27 실측: 이 값이 재시도 대상이 아니어서 한 번의 불일치로 즉시 포기했고, 세션 6 개를
                // 쥔 host 를 버린 채 **빈 host 를 새로 띄웠다**. 잠시 뒤 manifest 는 정상값으로 정정됐으므로
                // 몇십 ms 만 기다렸으면 그대로 붙었을 자리다.
                //
                // 시간 비용은 안전하다 — `stale_manifest` 는 안쪽 backoff 가 hello ack 검증에서 **즉시**
                // 반환하므로(예산을 쓰지 않는다) 위 `transient_timeout` 이 일으켰던 110s 폭발이 없다.
                // 진짜로 다른 host 가 그 자리를 차지한 경우는 예산을 다 쓴 뒤 실패로 끝난다(fail-closed 유지).
                .startup_timeout, .invalid_manifest, .host_gone, .stale_manifest => {},
                else => return .{ .failed = reason },
            },
        }
        _ = usleep(opts.connect_delay_ms * 1000);
    }
    return .{ .failed = .startup_timeout };
}

fn connectManifestRegistryWithBackoff(
    allocator: std.mem.Allocator,
    exe_path: [:0]const u8,
    base_cache_dir: []const u8,
    session_dir: [:0]const u8,
    opts: Options,
) ?Outcome {
    var attempts: usize = 0;
    while (attempts < opts.connect_attempts) : (attempts += 1) {
        if (findCurrentManifestHost(allocator, exe_path, base_cache_dir, session_dir)) |outcome|
            return outcome;
        _ = usleep(opts.connect_delay_ms * 1000);
    }
    return null;
}

/// 이미 존재하는 특정 major host만 찾는다. 조회/restore 경로라 spawn하지 않으며 versioned endpoint를 먼저,
/// 전환 이전 legacy endpoint를 다음으로 probe한다.
pub fn connectExistingMajor(
    allocator: std.mem.Allocator,
    base_cache_dir: []const u8,
    major: u16,
) Outcome {
    if (builtin.os.tag != .macos) return .{ .failed = .invalid_endpoint };
    var dir_buf: [512]u8 = undefined;
    const dir = discovery.sessionHostDirPath(&dir_buf, base_cache_dir) catch return .{ .failed = .invalid_endpoint };
    var versioned_buf: [640]u8 = undefined;
    const versioned = discovery.socketPathForMajorIn(&versioned_buf, dir, major) catch
        return .{ .failed = .invalid_endpoint };
    switch (tryConnectMajor(allocator, versioned, major)) {
        .connected => |client| return .{ .connected = client },
        .absent => {},
        .transient => return connectMajorWithBackoffDetailed(allocator, versioned, major, .{
            .connect_attempts = 10,
            .connect_delay_ms = 20,
        }),
        .failed => |reason| return .{ .failed = reason },
    }
    var legacy_buf: [640]u8 = undefined;
    const legacy = discovery.legacySocketPathIn(&legacy_buf, dir) catch return .{ .failed = .invalid_endpoint };
    return switch (tryConnectMajor(allocator, legacy, major)) {
        .connected => |client| .{ .connected = client },
        .absent => .{ .failed = .startup_timeout },
        .transient => connectMajorWithBackoffDetailed(allocator, legacy, major, .{
            .connect_attempts = 10,
            .connect_delay_ms = 20,
        }),
        .failed => |reason| .{ .failed = reason },
    };
}

/// Workspace의 exact `host_id`를 registry manifest로 resolve한다. Manifest가 있으면 그 endpoint/major만 사용하고
/// hello identity·screen codec이 하나라도 다르면 다른 major socket을 추측하지 않는다. Manifest 도입 전 host에 한해
/// current/N-1 legacy endpoint를 제한적으로 probe하고 hello host_id가 정확히 같은 연결만 반환한다.
pub fn connectExistingHost(
    allocator: std.mem.Allocator,
    base_cache_dir: []const u8,
    host_id: u128,
) Outcome {
    if (builtin.os.tag != .macos or host_id == 0) return .{ .failed = .invalid_endpoint };
    var dir_buf: [512]u8 = undefined;
    const dir = discovery.sessionHostDirPath(&dir_buf, base_cache_dir) catch
        return .{ .failed = .invalid_endpoint };
    const manifest = host_manifest.load(allocator, dir, host_id) catch |err| switch (err) {
        error.ManifestNotFound => return connectLegacyExact(allocator, base_cache_dir, host_id),
        error.OutOfMemory => return .{ .failed = .out_of_memory },
        else => return .{ .failed = .invalid_manifest },
    };
    var exact = manifest;
    defer exact.deinit();
    if (exact.lifecycle == .restoring) return .{ .failed = .startup_timeout };
    const endpoint = allocator.dupeZ(u8, exact.endpoint) catch return .{ .failed = .out_of_memory };
    defer allocator.free(endpoint);
    const outcome = connectExactWithBackoff(
        allocator,
        endpoint,
        exact.descriptor(),
        .{ .connect_attempts = 10, .connect_delay_ms = 20 },
    );
    switch (outcome) {
        .connected => return outcome,
        .failed => |reason| {
            // manifest는 남아 있는데 endpoint가 응답하지 않으면 두 가지다: host가 사라졌거나(재부팅·crash 뒤 stale
            // manifest) 아직/일시적으로 못 붙는 것이다. owner lease는 이미 `findCurrentManifestHost`가 host 생존
            // 판정의 단일 출처로 쓰는 증거라 여기서도 그걸 쓴다 — lease를 **잡을 수 있었을 때만** 그 host 프로세스가
            // 죽었다고 단정한다. OOM은 host에 대한 증거가 아니므로 그대로 둔다. lease가 살아 있거나(예:
            // incompatible_version — hello에 답한 host가 존재) **판정 자체가 불가능하면**(fd 고갈·권한 — 우리 쪽
            // 사정) 일시 실패로 남긴다. 이 보수성이 살아 있는 세션을 placeholder로 굳히는 것을 막는다.
            if (reason == .out_of_memory) return outcome;
            if (ownerLeaseState(dir, host_id) == .free) return .{ .failed = .host_gone };
            return outcome;
        },
    }
}

/// CR4 reconnect issuer의 bounded exact-host entrypoint다. Catch-up barrier를 지원하는 새 host는
/// manifest descriptor를 이미 게시하므로 legacy endpoint 추측을 하지 않는다. 같은 absolute deadline을
/// 이후 observer attach/snapshot/catch-up에도 넘길 수 있도록 이 함수는 caller의 phase를 재생성하지 않는다.
pub fn connectExistingHostUntil(
    allocator: std.mem.Allocator,
    base_cache_dir: []const u8,
    host_id: u128,
    phase: attach_phase_deadline.PhaseDeadline,
) Outcome {
    return connectExistingHostUntilObserved(allocator, base_cache_dir, host_id, phase, null);
}

pub fn connectExistingHostUntilObserved(
    allocator: std.mem.Allocator,
    base_cache_dir: []const u8,
    host_id: u128,
    phase: attach_phase_deadline.PhaseDeadline,
    observation: ?*DeadlineConnectObservation,
) Outcome {
    if (builtin.os.tag != .macos or host_id == 0) return .{ .failed = .invalid_endpoint };
    if (phase.kind != .resolve and phase.kind != .connect_hello)
        return .{ .failed = .invalid_endpoint };
    if (phase.absolute.remainingNs() <= 0)
        return .{ .failed = .deadline_exceeded };
    var dir_buf: [512]u8 = undefined;
    const dir = discovery.sessionHostDirPath(&dir_buf, base_cache_dir) catch
        return .{ .failed = .invalid_endpoint };
    var manifest = host_manifest.load(allocator, dir, host_id) catch |err| switch (err) {
        error.ManifestNotFound => return .{ .failed = .invalid_manifest },
        error.OutOfMemory => return .{ .failed = .out_of_memory },
        else => return .{ .failed = .invalid_manifest },
    };
    defer manifest.deinit();
    if (phase.absolute.remainingNs() <= 0)
        return .{ .failed = .deadline_exceeded };
    if (manifest.lifecycle == .restoring)
        return .{ .failed = .startup_timeout };
    const outcome = connectDiscoveredHostProfileUntilObserved(
        allocator,
        base_cache_dir,
        manifest.descriptor(),
        .gui,
        phase,
        observation,
    );
    if (phase.absolute.remainingNs() <= 0) {
        var expired = outcome;
        if (expired == .connected) expired.connected.deinit();
        return .{ .failed = .deadline_exceeded };
    }
    switch (outcome) {
        .connected => return outcome,
        .failed => |reason| {
            if (reason == .out_of_memory or reason == .deadline_exceeded) return outcome;
            if (ownerLeaseState(dir, host_id) == .free) return .{ .failed = .host_gone };
            return outcome;
        },
    }
}

/// Recovery discovery가 pin한 exact descriptor에만 새 connection을 연다. pathname을 fresh revalidate하고
/// legacy endpoint 추측이나 spawn으로 우회하지 않는다.
pub fn connectDiscoveredHost(
    allocator: std.mem.Allocator,
    base_cache_dir: []const u8,
    expected: host_manifest.Descriptor,
) Outcome {
    return connectDiscoveredHostProfile(allocator, base_cache_dir, expected, .gui);
}

/// Unlike connectOrLaunch this path never creates a host or guesses another endpoint. The closed
/// profile derives wire identity and transfer capability together.
pub fn connectDiscoveredHostProfile(
    allocator: std.mem.Allocator,
    base_cache_dir: []const u8,
    expected: host_manifest.Descriptor,
    connection_profile: client_mod.ConnectionProfile,
) Outcome {
    return connectDiscoveredHostProfileWith(
        allocator,
        base_cache_dir,
        expected,
        connection_profile,
        .blocking,
    );
}

pub fn connectDiscoveredHostProfileUntil(
    allocator: std.mem.Allocator,
    base_cache_dir: []const u8,
    expected: host_manifest.Descriptor,
    connection_profile: client_mod.ConnectionProfile,
    phase: attach_phase_deadline.PhaseDeadline,
) Outcome {
    return connectDiscoveredHostProfileUntilObserved(
        allocator,
        base_cache_dir,
        expected,
        connection_profile,
        phase,
        null,
    );
}

fn connectDiscoveredHostProfileUntilObserved(
    allocator: std.mem.Allocator,
    base_cache_dir: []const u8,
    expected: host_manifest.Descriptor,
    connection_profile: client_mod.ConnectionProfile,
    phase: attach_phase_deadline.PhaseDeadline,
    observation: ?*DeadlineConnectObservation,
) Outcome {
    if (phase.kind != .resolve and phase.kind != .connect_hello)
        return .{ .failed = .invalid_endpoint };
    if (phase.absolute.remainingNs() <= 0)
        return .{ .failed = .deadline_exceeded };
    return connectDiscoveredHostProfileWithObserved(
        allocator,
        base_cache_dir,
        expected,
        connection_profile,
        .{ .deadline = phase.absolute },
        observation,
    );
}

const DiscoveredConnectIo = union(enum) {
    blocking,
    deadline: client_deadline.AbsoluteDeadline,
};

fn connectDiscoveredHostProfileWith(
    allocator: std.mem.Allocator,
    base_cache_dir: []const u8,
    expected: host_manifest.Descriptor,
    connection_profile: client_mod.ConnectionProfile,
    io: DiscoveredConnectIo,
) Outcome {
    return connectDiscoveredHostProfileWithObserved(
        allocator,
        base_cache_dir,
        expected,
        connection_profile,
        io,
        null,
    );
}

fn connectDiscoveredHostProfileWithObserved(
    allocator: std.mem.Allocator,
    base_cache_dir: []const u8,
    expected: host_manifest.Descriptor,
    connection_profile: client_mod.ConnectionProfile,
    io: DiscoveredConnectIo,
    observation: ?*DeadlineConnectObservation,
) Outcome {
    if (builtin.os.tag != .macos or expected.host_id == 0) return .{ .failed = .invalid_endpoint };
    var dir_buf: [512]u8 = undefined;
    const dir = discovery.sessionHostDirPath(&dir_buf, base_cache_dir) catch
        return .{ .failed = .invalid_endpoint };
    if (deadlineExpired(io)) return .{ .failed = .deadline_exceeded };
    var current = host_manifest.load(allocator, dir, expected.host_id) catch |err|
        return .{ .failed = manifestLoadFailure(io, err) };
    defer current.deinit();
    if (deadlineExpired(io)) return .{ .failed = .deadline_exceeded };
    if (!host_manifest.descriptorEql(current.descriptor(), expected)) {
        logStaleManifest("manifest", host_manifest.firstDescriptorMismatch(current.descriptor(), expected));
        return .{ .failed = .stale_manifest };
    }
    const endpoint = allocator.dupeZ(u8, expected.endpoint) catch return .{ .failed = .out_of_memory };
    defer allocator.free(endpoint);
    const outcome = switch (io) {
        .blocking => connectExactWithBackoffKind(
            allocator,
            endpoint,
            expected,
            connection_profile,
            .{ .connect_attempts = 10, .connect_delay_ms = 20 },
        ),
        .deadline => |deadline| connectExactWithBackoffKindUntil(
            allocator,
            endpoint,
            expected.protocol_major,
            expected,
            connection_profile,
            .{ .connect_attempts = 10, .connect_delay_ms = 20 },
            deadline,
            deadline_attempt_ops,
            client_deadline.posix_ops,
            observation,
        ),
    };
    if (deadlineExpired(io)) {
        var expired = outcome;
        if (expired == .connected) expired.connected.deinit();
        return .{ .failed = .deadline_exceeded };
    }
    return outcome;
}

fn deadlineExpired(io: DiscoveredConnectIo) bool {
    return switch (io) {
        .blocking => false,
        .deadline => |deadline| deadline.remainingNs() <= 0,
    };
}

fn manifestLoadFailure(io: DiscoveredConnectIo, err: anyerror) FailureReason {
    // The synchronous filesystem bundle is not cancellable mid-syscall. Once it returns, phase
    // expiry has priority over both success and failure classification.
    if (deadlineExpired(io)) return .deadline_exceeded;
    return switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.ManifestNotFound => .host_gone,
        else => .invalid_manifest,
    };
}

test "host_connect manifest load failure after phase boundary is deadline first" {
    const Clock = struct {
        now_ns: i128 = 0,

        fn now(context: *anyopaque) i128 {
            const self: *@This() = @ptrCast(@alignCast(context));
            return self.now_ns;
        }
    };
    var clock = Clock{};
    const deadline = client_deadline.AbsoluteDeadline.fromInjected(
        .{ .context = &clock, .now_ns = Clock.now },
        5,
    );
    clock.now_ns = deadline.expires_at_ns;
    try testing.expectEqual(
        FailureReason.deadline_exceeded,
        manifestLoadFailure(.{ .deadline = deadline }, error.ManifestNotFound),
    );
    try testing.expectEqual(
        FailureReason.deadline_exceeded,
        manifestLoadFailure(.{ .deadline = deadline }, error.OutOfMemory),
    );
}

fn connectLegacyExact(allocator: std.mem.Allocator, base_cache_dir: []const u8, host_id: u128) Outcome {
    var dir_buf: [512]u8 = undefined;
    const dir = discovery.sessionHostDirPath(&dir_buf, base_cache_dir) catch
        return .{ .failed = .invalid_endpoint };
    var major = protocol.version_major;
    const minimum = if (protocol.version_major > 1) protocol.version_major - 1 else protocol.version_major;
    // 한 endpoint라도 "지금은 모르겠다"였는지. 전 경로를 소진했다는 사실만으로는 부족하다 — 소진의 이유가 **부재**여야
    // host_gone이고, 이유에 미확정이 섞이면 살아 있는 host를 묘비로 굳힐 수 있다(code-review).
    var indeterminate = false;
    while (true) {
        var versioned_buf: [640]u8 = undefined;
        const versioned = discovery.socketPathForMajorIn(&versioned_buf, dir, major) catch
            return .{ .failed = .invalid_endpoint };
        switch (probeLegacyExactEndpoint(allocator, versioned, major, host_id)) {
            .outcome => |outcome| return outcome,
            .absent => {},
            .indeterminate => indeterminate = true,
        }

        // 같은 major의 versioned current host가 다른 host_id여도 전환 전 control.sock을 별도로 probe한다. 한 endpoint의
        // 성공이 다른 endpoint를 shadow하지 않게 해야 saved legacy handle을 정확히 복원할 수 있다.
        var legacy_buf: [640]u8 = undefined;
        const legacy = discovery.legacySocketPathIn(&legacy_buf, dir) catch
            return .{ .failed = .invalid_endpoint };
        switch (probeLegacyExactEndpoint(allocator, legacy, major, host_id)) {
            .outcome => |outcome| return outcome,
            .absent => {},
            .indeterminate => indeterminate = true,
        }
        if (major == minimum) break;
        major -= 1;
    }
    // manifest도 없고(호출자가 ManifestNotFound로 여기 왔다) current/N-1 legacy endpoint도 그 host_id로 응답하지 않았다.
    // **모든 probe가 부재였을 때만** "그 host는 사라졌다"로 단정한다 — 저장된 runtime을 종료 placeholder로 둘지
    // 판정하는 caller가 이 구분에 의존한다. 하나라도 미확정(EAGAIN/EINTR/ETIMEDOUT, 또는 말이 안 통한 peer)이 있었다면
    // 그 뒤에 host가 살아 있을 수 있으므로 manifest 경로와 같은 fail-closed(startup_timeout=일시)로 남긴다.
    return .{ .failed = if (indeterminate) .startup_timeout else .host_gone };
}

/// `probeLegacyExactEndpoint`의 결과. "부재"와 "미확정"을 같은 null로 접으면 호출자가 전 경로 소진을 곧바로
/// `host_gone`(영구)으로 올려, 잠깐 바쁜 host의 세션이 묘비가 된다(code-review).
const LegacyProbe = union(enum) {
    /// 결론이 났다 — 연결 성공이거나 그대로 전파할 실패다.
    outcome: Outcome,
    /// 그 endpoint에는 아무도 없거나 다른 host_id였다. 이 경로에 없다는 **증거**.
    absent,
    /// 지금 못 붙었거나(transient) 붙었어도 말이 안 통했다. host 생존에 대한 증거가 아니다.
    indeterminate,
};

fn probeLegacyExactEndpoint(
    allocator: std.mem.Allocator,
    endpoint: [:0]const u8,
    major: u16,
    host_id: u128,
) LegacyProbe {
    return switch (tryConnectMajor(allocator, endpoint, major)) {
        .connected => |client| blk: {
            // Manifest-capable peer가 entry를 잃었다면 legacy 추측으로 우회하지 않는다. 이 경우 registry corruption/stale
            // publish를 숨기지 않고 exact manifest 오류로 닫는다.
            if (client.host_manifest_v1) {
                var rejected = client;
                rejected.deinit();
                break :blk .{ .outcome = .{ .failed = .invalid_manifest } };
            }
            if (client.host_id == host_id) break :blk .{ .outcome = .{ .connected = client } };
            var mismatch = client;
            mismatch.deinit();
            break :blk .absent; // 응답한 host는 있으나 **우리가 찾는 host_id가 아니다** = 이 endpoint에는 없다.
        },
        .absent => .absent, // ENOENT/ECONNREFUSED — 소켓 자체가 없다.
        .transient => .indeterminate, // EAGAIN/EINTR/ETIMEDOUT — 살아 있는데 잠깐 바쁠 수 있다.
        .failed => |reason| switch (reason) {
            // hello 단계에서 갈렸다는 것은 그 endpoint에 **무언가 살아 있다**는 뜻이다. 우리 host_id인지 확인하지
            // 못했을 뿐이라 부재의 증거가 아니다.
            .incompatible_version, .handshake_failed, .protocol_error => .indeterminate,
            else => .{ .outcome = .{ .failed = reason } },
        },
    };
}

fn validateExactClient(client: client_mod.Client, expected: host_manifest.Descriptor) Outcome {
    if (client.host_manifest_v1 and client.host_id == expected.host_id and
        client.screen_codec_version == expected.screen_codec_version and
        client.wire_major == expected.protocol_major and
        client.build_id != null and std.mem.eql(u8, client.build_id.?, expected.build_id) and
        client.upgrade_epoch == expected.upgrade_epoch and
        std.mem.eql(u8, client.lifecycle, @tagName(expected.lifecycle)))
        return .{ .connected = client };
    logStaleClient(client, expected);
    var stale = client;
    stale.deinit();
    return .{ .failed = .stale_manifest };
}

/// `stale_manifest` 로 접히기 **전에** 어긋난 축을 남긴다.
///
/// 이 값 하나에 도달하는 축이 일곱이라, 사유만 보고는 `build_id` 인지 `lifecycle` 인지 알 수 없다.
/// 2026-08-27 실측: exec upgrade 가 `reason=stale_manifest` 로 실패해 구 host(사용자 PTY 6 개 보유)와
/// 새 host(빈 껍데기)가 공존했고, `host status` 가 ambiguous 가 됐다. 그 상태에서 앱을 다시 띄우면
/// 스캔이 빈 host 를 고를 수 있고 그러면 세션을 통째로 잃는다 — 원인을 좁히지 못하면 반복된다.
/// 같은 사유가 연속으로 반복되면 한 번만 남긴다.
///
/// `stale_manifest` 는 이제 재시도 대상이라 한 번의 upgrade 에서 최대 500 회 반복될 수 있다. 그대로 찍으면
/// 진단이 아니라 소음이 되고, 정작 봐야 할 다른 줄을 덮는다 — 2026-08-27 에 tick 마다 찍히던 정상 로그가
/// `app.log` 를 28MB 로 불려 4MB 캡을 무의미하게 만든 전례가 있다. 사유가 **바뀌는 순간**이 정보다.
var last_stale_key: u64 = 0;

fn logStaleManifest(site: []const u8, axis: ?host_manifest.DescriptorAxis) void {
    if (builtin.is_test) return;
    const axis_name = if (axis) |a| @tagName(a) else "none";
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(site);
    hasher.update(axis_name);
    const key = hasher.final() | 1; // 0 은 "아직 없음" 이라 예약한다
    if (key == last_stale_key) return;
    last_stale_key = key;
    std.log.err(
        "session host stale manifest: site={s} axis={s}",
        .{ site, axis_name },
    );
}

/// hello ack 검증 실패. client 가 실제로 답한 값과 기대값을 **둘 다** 남긴다 — 축 이름만으로는
/// "어느 쪽이 옛것인지" 가 안 보여서 upgrade 방향을 판단할 수 없다.
var last_stale_client_key: u64 = 0;

/// **심각도는 사실에 맞춘다.** `build_id`·`upgrade_epoch`·`lifecycle` 세 축의 불일치는 exec 업그레이드가
/// 지나가는 **예정된 전환 창**이다 — host 가 새 이미지로 바뀌어 hello 는 새 값을 답하는데 manifest 는 아직
/// 정정 전이라 어긋난다. `.stale_manifest` 가 재시도 대상인 이유가 그것이고(위 `connectNewHostWithBackoff`),
/// 실제로 몇십 ms 뒤 수렴한다. 그런데 이 셋을 `err` 로 찍는 바람에 **정상 업데이트마다 `error:` 가 쌓였고**,
/// 2026-08-29 에 그 줄들을 보고 앱의 조용한 종료와 잘못 연결지어 원인을 헛짚었다. 그래서 전환 창은 `warn`,
/// 문구도 "stale"(틀렸다)이 아니라 "lag"(아직 안 따라왔다)으로 적는다.
///
/// 나머지 축은 그대로 `err` 다 — `host_id` 가 다르면 **다른 host** 가 그 자리를 차지한 것이고,
/// codec·protocol 불일치는 버전 스큐다. 둘 다 재시도로 낫지 않는다.
fn logStaleClient(client: client_mod.Client, expected: host_manifest.Descriptor) void {
    if (builtin.is_test) return;
    // 값까지 넣은 키로 연속 중복을 억제한다. 재시도가 500 회까지 돌 수 있으므로 이게 없으면 같은 줄이
    // 그대로 500 번 쌓여, 정작 상태가 **바뀌는** 순간을 덮는다.
    var hasher = std.hash.Wyhash.init(1);
    hasher.update(if (client.build_id) |b| b else "");
    hasher.update(expected.build_id);
    hasher.update(client.lifecycle);
    hasher.update(std.mem.asBytes(&client.upgrade_epoch));
    const key = hasher.final() | 1;
    if (key == last_stale_client_key) return;
    last_stale_client_key = key;
    if (!client.host_manifest_v1) return logStaleManifest("hello:no_manifest_v1", null);
    if (client.host_id != expected.host_id) return logStaleManifest("hello", .host_id);
    if (client.screen_codec_version != expected.screen_codec_version) return logStaleManifest("hello", .screen_codec_version);
    if (client.wire_major != expected.protocol_major) return logStaleManifest("hello", .protocol_major);
    if (client.build_id == null) return logStaleManifest("hello:build_id_absent", .build_id);
    if (!std.mem.eql(u8, client.build_id.?, expected.build_id)) {
        std.log.warn(
            "session host manifest lag: site=hello axis=build_id got={s} want={s}",
            .{ client.build_id.?, expected.build_id },
        );
        return;
    }
    if (client.upgrade_epoch != expected.upgrade_epoch) {
        std.log.warn(
            "session host manifest lag: site=hello axis=upgrade_epoch got={d} want={d}",
            .{ client.upgrade_epoch, expected.upgrade_epoch },
        );
        return;
    }
    if (!std.mem.eql(u8, client.lifecycle, @tagName(expected.lifecycle))) {
        std.log.warn(
            "session host manifest lag: site=hello axis=lifecycle got={s} want={s}",
            .{ client.lifecycle, @tagName(expected.lifecycle) },
        );
        return;
    }
    logStaleManifest("hello", null);
}

fn connectExactWithBackoff(
    allocator: std.mem.Allocator,
    endpoint: [:0]const u8,
    expected: host_manifest.Descriptor,
    opts: Options,
) Outcome {
    return connectExactWithBackoffKind(allocator, endpoint, expected, .gui, opts);
}

fn connectExactWithBackoffKind(
    allocator: std.mem.Allocator,
    endpoint: [:0]const u8,
    expected: host_manifest.Descriptor,
    connection_profile: client_mod.ConnectionProfile,
    opts: Options,
) Outcome {
    var attempts: usize = 0;
    var saw_transient = false;
    while (attempts < opts.connect_attempts) : (attempts += 1) {
        switch (tryConnectExactKind(
            allocator,
            endpoint,
            expected,
            connection_profile,
        )) {
            .connected => |client| return validateExactClient(client, expected),
            .absent => {},
            .transient => saw_transient = true,
            // exec 직후 **복원 중**인 host는 endpoint를 이미 열어 accept까지 되지만, runtime과 큐를 되살리는 동안
            // hello만 아직 못 준다. client는 그 국면을 `handshake_failed`로 읽는데, 이건 "죽었다"가 아니라 "아직
            // 준비 전"이라 재시도 대상이다. 확정 실패로 보고 즉시 반환하면 여기 있는 예산을 **한 번도 쓰지 못한다** —
            // 2026-08-27 실측에서 총 시도가 1회였고, 살아 있는 host가 `unreachable`로 판정돼 새 host가 떴다.
            // 그 결과가 `connectNewHostWithBackoff`가 경고하는 **같은 build_id host 둘**이다.
            //
            // 진짜 프로토콜 불일치는 `incompatible_version`으로 따로 오므로 구 host를 오래 기다리게 되지도 않는다.
            .failed => |reason| switch (reason) {
                .handshake_failed => saw_transient = true,
                else => return .{ .failed = reason },
            },
        }
        _ = usleep(opts.connect_delay_ms * 1000);
    }
    return .{ .failed = if (saw_transient) .transient_timeout else .startup_timeout };
}

fn connectExactWithBackoffKindUntil(
    allocator: std.mem.Allocator,
    endpoint: [:0]const u8,
    major: u16,
    expected: host_manifest.Descriptor,
    connection_profile: client_mod.ConnectionProfile,
    opts: Options,
    deadline: client_deadline.AbsoluteDeadline,
    attempt_ops: DeadlineAttemptOps,
    wait_ops: client_deadline.Ops,
    observation: ?*DeadlineConnectObservation,
) Outcome {
    var attempts: usize = 0;
    var saw_transient = false;
    while (attempts < opts.connect_attempts) : (attempts += 1) {
        if (deadline.remainingNs() <= 0) return .{ .failed = .deadline_exceeded };
        if (observation) |value| value.attempt_count +|= 1;
        const candidate = attempt_ops.connect(
            attempt_ops.context,
            allocator,
            endpoint,
            connection_profile,
            major,
            deadline,
        );
        switch (candidate) {
            .connected => |client| {
                const validated = validateExactClient(client, expected);
                if (deadline.remainingNs() <= 0) {
                    var expired = validated;
                    if (expired == .connected) expired.connected.deinit();
                    return .{ .failed = .deadline_exceeded };
                }
                return validated;
            },
            .absent => {},
            .transient => {
                saw_transient = true;
            },
            .failed => |reason| return .{ .failed = reason },
        }
        // No delay after the final failed attempt. The derived wake target cannot extend the
        // caller's phase and EINTR does not restart this interval.
        if (attempts + 1 >= opts.connect_attempts) break;
        if (observation) |value| value.backoff_wait_count +|= 1;
        client_deadline.waitBackoffUntil(
            wait_ops,
            @as(i128, opts.connect_delay_ms) * std.time.ns_per_ms,
            deadline,
        ) catch |err| return .{ .failed = switch (err) {
            error.Timeout => .deadline_exceeded,
            else => .handshake_failed,
        } };
    }
    return .{ .failed = if (saw_transient) .transient_timeout else .startup_timeout };
}

const DeadlineAttemptResult = union(enum) {
    connected: client_mod.Client,
    absent,
    transient,
    failed: FailureReason,
};

const DeadlineAttemptOps = struct {
    context: *anyopaque,
    connect: *const fn (
        context: *anyopaque,
        allocator: std.mem.Allocator,
        endpoint: [:0]const u8,
        connection_profile: client_mod.ConnectionProfile,
        major: u16,
        deadline: client_deadline.AbsoluteDeadline,
    ) DeadlineAttemptResult,
};

const deadline_attempt_ops = DeadlineAttemptOps{
    .context = @ptrFromInt(1),
    .connect = deadlineConnectAttempt,
};

fn deadlineConnectAttempt(
    _: *anyopaque,
    allocator: std.mem.Allocator,
    endpoint: [:0]const u8,
    connection_profile: client_mod.ConnectionProfile,
    major: u16,
    deadline: client_deadline.AbsoluteDeadline,
) DeadlineAttemptResult {
    if (client_mod.Client.connectUntil(
        allocator,
        endpoint,
        connection_profile,
        major,
        deadline,
    )) |client| {
        return .{ .connected = client };
    } else |err| return switch (err) {
        error.EndpointAbsent => .absent,
        error.EndpointTransient => .transient,
        error.EndpointDenied => .{ .failed = .endpoint_denied },
        error.IncompatibleVersion => .{ .failed = .incompatible_version },
        error.AdminBusy => .{ .failed = .resource_exhausted },
        error.Unauthorized => .{ .failed = .unauthorized },
        error.ProtocolError, error.EventQueueFull, error.ExternalMode => .{ .failed = .protocol_error },
        error.OutOfMemory => .{ .failed = .out_of_memory },
        error.DeadlineExceeded => .{ .failed = .deadline_exceeded },
        error.HandshakeFailed, error.ConnectionClosed, error.WriteFailed => .{
            .failed = .handshake_failed,
        },
    };
}

test "host_connect deadline retry shares one expiry and never sleeps after final attempt" {
    const Fixture = struct {
        now_ns: i128 = 0,
        attempt_count: usize = 0,
        wait_count: usize = 0,
        expiries: [3]i128 = @splat(0),

        fn clock(context: *anyopaque) i128 {
            const self: *@This() = @ptrCast(@alignCast(context));
            return self.now_ns;
        }

        fn attempt(
            context: *anyopaque,
            _: std.mem.Allocator,
            _: [:0]const u8,
            _: client_mod.ConnectionProfile,
            _: u16,
            deadline: client_deadline.AbsoluteDeadline,
        ) DeadlineAttemptResult {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.expiries[self.attempt_count] = deadline.expires_at_ns;
            self.attempt_count += 1;
            return if (self.attempt_count == 1) .absent else .transient;
        }

        fn wait(
            context: *anyopaque,
            _: c.fd_t,
            _: client_deadline.WaitKind,
            timeout_ms: c_int,
        ) client_deadline.WaitOutcome {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.wait_count += 1;
            self.now_ns += @as(i128, timeout_ms) * std.time.ns_per_ms;
            return .timed_out;
        }

        fn waitOps(self: *@This()) client_deadline.Ops {
            var result = client_deadline.posix_ops;
            result.context = self;
            result.wait = wait;
            return result;
        }
    };
    var fixture = Fixture{};
    const deadline = client_deadline.AbsoluteDeadline.fromInjected(
        .{ .context = &fixture, .now_ns = Fixture.clock },
        100 * std.time.ns_per_ms,
    );
    const descriptor = host_manifest.Descriptor{
        .host_id = 1,
        .build_id = "build",
        .protocol_major = protocol.version_major,
        .screen_codec_version = screen_stream.codec_version,
        .upgrade_epoch = 1,
        .lifecycle = .ready,
        .endpoint = "/tmp/not-opened",
    };
    const outcome = connectExactWithBackoffKindUntil(
        testing.allocator,
        "/tmp/not-opened",
        protocol.version_major,
        descriptor,
        .cli_probe,
        .{ .connect_attempts = 2, .connect_delay_ms = 20 },
        deadline,
        .{ .context = &fixture, .connect = Fixture.attempt },
        fixture.waitOps(),
        null,
    );
    try testing.expectEqual(FailureReason.transient_timeout, outcome.failed);
    try testing.expectEqual(@as(usize, 2), fixture.attempt_count);
    try testing.expectEqual(@as(usize, 1), fixture.wait_count);
    try testing.expectEqualSlices(i128, &.{ deadline.expires_at_ns, deadline.expires_at_ns }, fixture.expiries[0..2]);
}

test "host_connect deadline backoff expiry performs no later attempt" {
    const Fixture = struct {
        now_ns: i128 = 0,
        attempt_count: usize = 0,
        wait_count: usize = 0,

        fn clock(context: *anyopaque) i128 {
            const self: *@This() = @ptrCast(@alignCast(context));
            return self.now_ns;
        }

        fn attempt(
            context: *anyopaque,
            _: std.mem.Allocator,
            _: [:0]const u8,
            _: client_mod.ConnectionProfile,
            _: u16,
            deadline: client_deadline.AbsoluteDeadline,
        ) DeadlineAttemptResult {
            const self: *@This() = @ptrCast(@alignCast(context));
            testing.expectEqual(@as(i128, 10 * std.time.ns_per_ms), deadline.expires_at_ns) catch
                return .{ .failed = .protocol_error };
            self.attempt_count += 1;
            return .absent;
        }

        fn wait(
            context: *anyopaque,
            _: c.fd_t,
            _: client_deadline.WaitKind,
            timeout_ms: c_int,
        ) client_deadline.WaitOutcome {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.wait_count += 1;
            self.now_ns += @as(i128, timeout_ms) * std.time.ns_per_ms;
            return .timed_out;
        }

        fn waitOps(self: *@This()) client_deadline.Ops {
            var result = client_deadline.posix_ops;
            result.context = self;
            result.wait = wait;
            return result;
        }
    };
    var fixture = Fixture{};
    const deadline = client_deadline.AbsoluteDeadline.fromInjected(
        .{ .context = &fixture, .now_ns = Fixture.clock },
        10 * std.time.ns_per_ms,
    );
    const descriptor = host_manifest.Descriptor{
        .host_id = 1,
        .build_id = "build",
        .protocol_major = protocol.version_major,
        .screen_codec_version = screen_stream.codec_version,
        .upgrade_epoch = 1,
        .lifecycle = .ready,
        .endpoint = "/tmp/not-opened",
    };
    const outcome = connectExactWithBackoffKindUntil(
        testing.allocator,
        "/tmp/not-opened",
        protocol.version_major,
        descriptor,
        .cli_probe,
        .{ .connect_attempts = 3, .connect_delay_ms = 50 },
        deadline,
        .{ .context = &fixture, .connect = Fixture.attempt },
        fixture.waitOps(),
        null,
    );
    try testing.expectEqual(FailureReason.deadline_exceeded, outcome.failed);
    try testing.expectEqual(@as(usize, 1), fixture.attempt_count);
    try testing.expectEqual(@as(usize, 1), fixture.wait_count);
    try testing.expectEqual(deadline.expires_at_ns, fixture.now_ns);
}

const TryConnectResult = union(enum) {
    connected: client_mod.Client,
    absent,
    transient,
    failed: FailureReason,
};

/// `handshake_failed` 로 접히기 전에 **원래 에러**를 남긴다. 세 에러가 같은 값으로 나가므로 이 한 줄이
/// 없으면 "상대가 아직 준비 전"과 "상대가 우리를 거부함"을 영영 구분할 수 없다.
/// `ConnectionClosed` 는 **exec 업그레이드가 지나가는 정상 경로**다 — host 가 새 이미지로 자기를 교체하며
/// 연결을 닫는다. 그래서 이것만 `warn` 이다. 진짜로 못 붙고 끝난 경우는 `logUpgradeNotApplied` 가 따로
/// `err` 로 남기므로 여기서 낮춰도 실패가 조용해지지 않는다.
///
/// 나머지 둘은 그대로 `err` 다 — `HandshakeFailed` 는 hello 를 거부당한 것이고 `WriteFailed` 는 쓰지도
/// 못한 것이라, 어느 쪽도 예정된 전환이 아니다.
fn logHandshakeFailure(err_name: []const u8) void {
    if (builtin.is_test) return;
    if (std.mem.eql(u8, err_name, "ConnectionClosed")) {
        std.log.warn("session host peer closed during handshake: error={s}", .{err_name});
        return;
    }
    std.log.err("session host handshake failure: error={s}", .{err_name});
}

fn connectFailure(err: client_mod.ClientError) TryConnectResult {
    return switch (err) {
        error.EndpointAbsent => .absent,
        error.EndpointTransient => .transient,
        error.EndpointDenied => .{ .failed = .endpoint_denied },
        error.IncompatibleVersion => .{ .failed = .incompatible_version },
        // 세 에러가 한 값으로 접힌다 — "hello 를 거부당함"·"상대가 소켓을 닫음"·"쓰지도 못함" 은 원인이
        // 전혀 다른데 로그에는 `handshake_failed` 한 단어만 남았다. 2026-08-27 에 exec upgrade 실패를
        // 추적할 때 이 셋을 구분할 수 없어 legacy 경로를 한 번 헛짚었다. 분류는 그대로 두고 사유만 남긴다.
        error.HandshakeFailed,
        error.ConnectionClosed,
        error.WriteFailed,
        => blk: {
            logHandshakeFailure(@errorName(err));
            break :blk .{ .failed = .handshake_failed };
        },
        error.AdminBusy => .{ .failed = .resource_exhausted },
        error.Unauthorized => .{ .failed = .unauthorized },
        error.ProtocolError, error.EventQueueFull, error.ExternalMode => .{ .failed = .protocol_error },
        error.OutOfMemory => .{ .failed = .out_of_memory },
    };
}

test "host_connect preserves endpoint and handshake failure classes" {
    try testing.expect(connectFailure(error.EndpointAbsent) == .absent);
    try testing.expect(connectFailure(error.EndpointTransient) == .transient);
    try testing.expectEqual(FailureReason.endpoint_denied, connectFailure(error.EndpointDenied).failed);
    try testing.expectEqual(FailureReason.incompatible_version, connectFailure(error.IncompatibleVersion).failed);
    try testing.expectEqual(FailureReason.handshake_failed, connectFailure(error.ConnectionClosed).failed);
    try testing.expectEqual(FailureReason.protocol_error, connectFailure(error.ProtocolError).failed);
    try testing.expectEqual(FailureReason.resource_exhausted, connectFailure(error.AdminBusy).failed);
    try testing.expectEqual(FailureReason.unauthorized, connectFailure(error.Unauthorized).failed);
    try testing.expectEqual(FailureReason.out_of_memory, connectFailure(error.OutOfMemory).failed);
}

fn readExact(fd: c.fd_t, bytes: []u8) bool {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const rc = c.read(fd, bytes.ptr + offset, bytes.len - offset);
        if (rc > 0) {
            offset += @intCast(rc);
            continue;
        }
        if (rc < 0 and posix.errno(rc) == .INTR) continue;
        return false;
    }
    return true;
}

const FrozenV1Peer = struct {
    fn serve(server: *socket_server.SocketServer, ok: *bool) void {
        var ready = c.pollfd{
            .fd = server.listen_fd,
            .events = c.POLL.IN,
            .revents = 0,
        };
        if (c.poll(@ptrCast(&ready), 1, 1_000) <= 0 or ready.revents & c.POLL.IN == 0) return;
        const fd = server.acceptOne() orelse return;
        defer _ = c.close(fd);
        socket_server.setBlocking(fd) catch return;
        var header_bytes: [protocol.header_size]u8 = undefined;
        if (!readExact(fd, &header_bytes)) return;
        const header = protocol.Header.decode(&header_bytes) catch return;
        if (header.major != 1 or header.kind != .hello) return;
        const payload = std.heap.page_allocator.alloc(u8, header.payload_len) catch return;
        defer std.heap.page_allocator.free(payload);
        if (!readExact(fd, payload)) return;
        if (std.mem.indexOf(u8, payload, "\"protocol_min\":1") == null or
            std.mem.indexOf(u8, payload, "\"protocol_max\":1") == null) return;
        const response = framing.encodeFrame(
            std.heap.page_allocator,
            .{ .kind = .hello_ack, .major = 1 },
            "{\"version\":1,\"host_id\":\"000000000000000000000000000000aa\",\"capabilities\":[\"screen_stream_v1_current_body\"]}",
        ) catch return;
        defer std.heap.page_allocator.free(response);
        socket_server.writeAll(fd, response) catch return;
        ok.* = true;
    }
};

const FrozenBuildMismatchPeer = struct {
    fn serve(server: *socket_server.SocketServer, ok: *bool) void {
        var ready = c.pollfd{
            .fd = server.listen_fd,
            .events = c.POLL.IN,
            .revents = 0,
        };
        if (c.poll(@ptrCast(&ready), 1, 1_000) <= 0 or ready.revents & c.POLL.IN == 0) return;
        const fd = server.acceptOne() orelse return;
        defer _ = c.close(fd);
        socket_server.setBlocking(fd) catch return;
        var header_bytes: [protocol.header_size]u8 = undefined;
        if (!readExact(fd, &header_bytes)) return;
        const header = protocol.Header.decode(&header_bytes) catch return;
        if (header.major != 1 or header.kind != .hello) return;
        const payload = std.heap.page_allocator.alloc(u8, header.payload_len) catch return;
        defer std.heap.page_allocator.free(payload);
        if (!readExact(fd, payload)) return;
        const response = framing.encodeFrame(
            std.heap.page_allocator,
            .{ .kind = .hello_ack, .major = 1 },
            "{\"version\":1,\"host_id\":\"000000000000000000000000000000aa\",\"build_id\":\"sha256:0000000000000000000000000000000000000000000000000000000000000000\",\"capabilities\":[]}",
        ) catch return;
        defer std.heap.page_allocator.free(response);
        socket_server.writeAll(fd, response) catch return;
        ok.* = true;
    }
};

test "P3-e4d-2b frozen GUI rejects a peer build ID that differs from the attested manifest" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var base_buf: [128]u8 = undefined;
    const base = std.fmt.bufPrintZ(&base_buf, "/tmp/maru-sh-v1-build-mismatch-{d}", .{c.getpid()}) catch
        return error.SkipZigTest;
    _ = c.mkdir(base.ptr, 0o700);
    var dir_buf: [256]u8 = undefined;
    const dir = discovery.sessionHostDirPath(&dir_buf, base) catch return error.SkipZigTest;
    var socket_buf: [320]u8 = undefined;
    const socket = discovery.socketPathForMajorIn(&socket_buf, dir, 1) catch return error.SkipZigTest;
    var registry = registry_mod.TerminalRuntimeRegistry.init(allocator);
    defer registry.deinit();
    var server = try socket_server.SocketServer.bind(allocator, dir, socket, 0xAA, &registry);
    defer {
        server.deinit();
        _ = c.rmdir(dir.ptr);
        _ = c.rmdir(base.ptr);
    }
    var served = false;
    var thread = try std.Thread.spawn(.{}, FrozenBuildMismatchPeer.serve, .{ &server, &served });
    const artifact = compatibility.frozenGuiArtifactForMajor(1).?;
    try testing.expectError(
        error.IncompatibleVersion,
        client_mod.Client.connectFrozenGui(allocator, socket, 1, artifact),
    );
    thread.join();
    try testing.expect(served);
}

test "host_connect finds an existing frozen N-1 major without spawning and preserves adapter major" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var base_buf: [128]u8 = undefined;
    const base = std.fmt.bufPrintZ(&base_buf, "/tmp/maru-sh-v1-{d}", .{c.getpid()}) catch
        return error.SkipZigTest;
    _ = c.mkdir(base.ptr, 0o700);
    var dir_buf: [256]u8 = undefined;
    const dir = discovery.sessionHostDirPath(&dir_buf, base) catch return error.SkipZigTest;
    var socket_buf: [320]u8 = undefined;
    const socket = discovery.socketPathForMajorIn(&socket_buf, dir, 1) catch return error.SkipZigTest;
    var registry = registry_mod.TerminalRuntimeRegistry.init(allocator);
    defer registry.deinit();
    var server = try socket_server.SocketServer.bind(allocator, dir, socket, 0xAA, &registry);
    defer {
        server.deinit();
        _ = c.rmdir(dir.ptr);
        _ = c.rmdir(base.ptr);
    }
    var served = false;
    var thread = try std.Thread.spawn(.{}, FrozenV1Peer.serve, .{ &server, &served });
    const outcome = connectExistingMajor(allocator, base, 1);
    var client = switch (outcome) {
        .connected => |value| value,
        .failed => return error.TestUnexpectedResult,
    };
    thread.join();
    defer client.deinit();
    try testing.expect(served);
    try testing.expectEqual(@as(u16, 1), client.wire_major);
    try testing.expectEqual(@as(u128, 0xAA), client.host_id);
}

/// 한 번 connect를 시도하되 endpoint 부재/권한/일시 오류와 wire 실패를 잃지 않는다.
fn tryConnect(allocator: std.mem.Allocator, socket: [:0]const u8) TryConnectResult {
    if (client_mod.Client.connect(allocator, socket, .gui)) |client| {
        return .{ .connected = client };
    } else |err| {
        return connectFailure(err);
    }
}

fn tryConnectMajor(allocator: std.mem.Allocator, socket: [:0]const u8, major: u16) TryConnectResult {
    return tryConnectMajorKind(allocator, socket, major, .gui);
}

fn tryConnectMajorKind(
    allocator: std.mem.Allocator,
    socket: [:0]const u8,
    major: u16,
    connection_profile: client_mod.ConnectionProfile,
) TryConnectResult {
    if (client_mod.Client.connectMajor(
        allocator,
        socket,
        connection_profile,
        major,
    )) |client| {
        return .{ .connected = client };
    } else |err| {
        return connectFailure(err);
    }
}

/// Manifest의 exact build SHA가 frozen compatibility row와 일치할 때만 historical GUI hello를 연다.
/// 다른 N-1 image, manifest 없는 legacy probe와 CLI는 일반 fingerprint 검증을 그대로 탄다.
fn tryConnectExactKind(
    allocator: std.mem.Allocator,
    socket: [:0]const u8,
    expected: host_manifest.Descriptor,
    connection_profile: client_mod.ConnectionProfile,
) TryConnectResult {
    if (connection_profile == .gui) if (frozenGuiArtifactDigest(expected)) |digest| {
        if (client_mod.Client.connectFrozenGui(
            allocator,
            socket,
            @intCast(expected.protocol_major),
            digest,
        )) |client| {
            return .{ .connected = client };
        } else |err| {
            return connectFailure(err);
        }
    };
    return tryConnectMajorKind(
        allocator,
        socket,
        @intCast(expected.protocol_major),
        connection_profile,
    );
}

fn frozenGuiArtifactDigest(expected: host_manifest.Descriptor) ?[32]u8 {
    const profile = compatibility.profileForMajor(@intCast(expected.protocol_major)) orelse return null;
    const artifact = compatibility.frozenGuiArtifactForMajor(@intCast(expected.protocol_major)) orelse return null;
    if (profile.kind != .previous or
        expected.lifecycle != .ready or
        expected.screen_codec_version != profile.screen_codec_version or expected.host_id == 0 or
        expected.endpoint.len == 0 or !compatibility.artifactBuildIdMatches(expected.build_id, artifact))
        return null;
    return artifact;
}

test "P3-e4d-2b frozen GUI exception requires an exact ready manifest" {
    const artifact = compatibility.frozenGuiArtifactForMajor(1).?;
    const artifact_hex = std.fmt.bytesToHex(artifact, .lower);
    var build_id_buf: ["sha256:".len + 64]u8 = undefined;
    @memcpy(build_id_buf[0.."sha256:".len], "sha256:");
    @memcpy(build_id_buf["sha256:".len..], &artifact_hex);
    const exact = host_manifest.Descriptor{
        .host_id = 1,
        .build_id = &build_id_buf,
        .protocol_major = 1,
        .screen_codec_version = 1,
        .upgrade_epoch = 1,
        .lifecycle = .ready,
        .endpoint = "/tmp/frozen-gui",
    };
    try testing.expectEqualSlices(u8, &artifact, &frozenGuiArtifactDigest(exact).?);

    var wrong_build = build_id_buf;
    wrong_build[wrong_build.len - 1] = if (wrong_build[wrong_build.len - 1] == '0') '1' else '0';
    var changed = exact;
    changed.build_id = &wrong_build;
    try testing.expect(frozenGuiArtifactDigest(changed) == null);
    changed = exact;
    changed.lifecycle = .restoring;
    try testing.expect(frozenGuiArtifactDigest(changed) == null);
    changed = exact;
    changed.host_id = 0;
    try testing.expect(frozenGuiArtifactDigest(changed) == null);
    changed = exact;
    changed.endpoint = "";
    try testing.expect(frozenGuiArtifactDigest(changed) == null);
    changed = exact;
    changed.screen_codec_version = 2;
    try testing.expect(frozenGuiArtifactDigest(changed) == null);
    changed = exact;
    changed.protocol_major = protocol.version_major;
    try testing.expect(frozenGuiArtifactDigest(changed) == null);
}

fn connectWithBackoffDetailed(allocator: std.mem.Allocator, socket: [:0]const u8, opts: Options) Outcome {
    var attempts: usize = 0;
    while (attempts < opts.connect_attempts) : (attempts += 1) {
        switch (tryConnect(allocator, socket)) {
            .connected => |client| return .{ .connected = client },
            .absent, .transient => {},
            .failed => |reason| return .{ .failed = reason },
        }
        _ = usleep(opts.connect_delay_ms * 1000);
    }
    return .{ .failed = .startup_timeout };
}

fn connectMajorWithBackoffDetailed(
    allocator: std.mem.Allocator,
    socket: [:0]const u8,
    major: u16,
    opts: Options,
) Outcome {
    var attempts: usize = 0;
    while (attempts < opts.connect_attempts) : (attempts += 1) {
        switch (tryConnectMajor(allocator, socket, major)) {
            .connected => |client| return .{ .connected = client },
            .absent, .transient => {},
            .failed => |reason| return .{ .failed = reason },
        }
        _ = usleep(opts.connect_delay_ms * 1000);
    }
    return .{ .failed = .startup_timeout };
}

/// session-host 디렉터리를 0700으로 만든다(best-effort — EEXIST 무해). lock 파일 생성에 필요하다. 소유/perm의 진짜
/// 검증은 host `SocketServer.bind`가 fstatat(SYMLINK_NOFOLLOW)로 한다(§11) — 여기선 lock을 놓을 자리만 확보한다.
fn ensureDir(dir: [:0]const u8) void {
    _ = c.mkdir(dir.ptr, 0o700);
}

fn openLock(dir: [:0]const u8) ?c.fd_t {
    var lock_buf: [640]u8 = undefined;
    const lock = discovery.lockPathIn(&lock_buf, dir) catch return null;
    const fd = c.open(lock.ptr, .{ .ACCMODE = .RDWR, .CREAT = true }, @as(c.mode_t, 0o600));
    if (fd < 0) return null;
    return fd;
}

// ─────────────────────────────────────────────────────────────────────────────
// process smoke (실 macOS: fork host에 connect-first로 붙고, host 없을 땐 폴백)
//
// 이 테스트가 증명하는 것(그리고 왜 e3에서 중요한가): keep-alive GUI가 시작할 때 "있으면 붙고 없으면 하나 띄운다"는
// 발견 실행층이 실제 socket/flock/connect로 도는지 고정한다. use_connection(이미 뜬 host에 붙음), 제품 `maru`
// 바이너리의 spawn_host argv/hidden-command 진입, 폴백(host도 없고 spawn도 실패 → null로 in-process 유지)을 검증한다.
// 실 syscall이라 macOS opt-in.
// ─────────────────────────────────────────────────────────────────────────────

const testing = std.testing;
const daemon = @import("daemon.zig");

test "CR4a actual issuer는 bounded connectExistingHostUntil로 existing host에 연결한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = testing.io;

    var base_buf: [128]u8 = undefined;
    const base = std.fmt.bufPrintZ(&base_buf, "/tmp/maru-sh-hc-{d}", .{c.getpid()}) catch return error.SkipZigTest;
    _ = c.mkdir(base.ptr, 0o700); // 제품에선 base=user cache dir(이미 존재). host bind는 <base>/session-host만 mkdir하므로 base를 먼저 만든다.
    // discovery 경로와 동일하게 host별 short endpoint + cache manifest를 띄운다.
    var dir_buf: [256]u8 = undefined;
    const dir = discovery.sessionHostDirPath(&dir_buf, base) catch return error.SkipZigTest;
    _ = c.mkdir(dir.ptr, 0o700);
    // short endpoint는 base dir 밖의 user-global namespace라 고정 host id를 쓰면 병렬 test process끼리 같은
    // socket을 unlink/connect한다. PID를 identity 상위 비트에 넣어 manifest와 실제 endpoint를 함께 격리한다.
    const host_id: u128 = (@as(u128, @intCast(c.getpid())) << 64) | 0xAABBCCDD;
    try short_endpoint.prepareCurrentUserNamespace();
    var sock_buf: [128]u8 = undefined;
    const socket = try short_endpoint.currentSocketPathIn(&sock_buf, host_id);

    const child = c.fork();
    if (child < 0) return error.SkipZigTest;
    if (child == 0) {
        _ = c.setsid();
        _ = unsetenv("MARU_SESSION_HOST_TEST_ONESHOT");
        daemon.runSessionHostWithIdentity(std.heap.page_allocator, io, dir, socket, host_id) catch {};
        std.c._exit(0);
    }
    defer {
        _ = c.kill(child, posix.SIG.TERM);
        var status: c_int = undefined;
        _ = c.waitpid(child, &status, 0);
        _ = c.unlink(socket.ptr);
        var manifest_buf: [832]u8 = undefined;
        if (host_manifest.manifestPathIn(&manifest_buf, dir, host_id)) |path| _ = c.unlink(path.ptr) else |_| {}
        var owner_buf: [832]u8 = undefined;
        if (host_manifest.ownerLockPathIn(&owner_buf, dir, host_id)) |path| _ = c.unlink(path.ptr) else |_| {}
        var host_dir_buf: [768]u8 = undefined;
        if (host_manifest.hostDirPathIn(&host_dir_buf, dir, host_id)) |path| _ = c.rmdir(path.ptr) else |_| {}
        var hosts_buf: [640]u8 = undefined;
        if (host_manifest.hostsRootPathIn(&hosts_buf, dir)) |path| _ = c.rmdir(path.ptr) else |_| {}
        _ = c.rmdir(dir.ptr);
        _ = c.rmdir(base.ptr);
    }

    // host가 bind할 때까지 잠깐 기다렸다가 connect-first로 붙는다(spawn 없이). exe_path는 이 경로에선 안 쓰이므로 더미.
    // (호스트가 아직 안 떴으면 첫 connect가 absent→start-lock→우리가 spawn을 시도하는데, 더미 exe라 폴백될 수 있어
    //  host가 확실히 뜰 때까지 기다린 뒤 부른다.)
    var up = false;
    var attempts: usize = 0;
    while (attempts < 200) : (attempts += 1) {
        if (client_mod.Client.connect(allocator, socket, .gui)) |cl| {
            var probe = cl;
            probe.deinit();
            up = true;
            break;
        } else |_| _ = usleep(20 * 1000);
    }
    try testing.expect(up);

    const current_exe_raw = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(current_exe_raw);
    const current_exe = try allocator.dupeZ(u8, current_exe_raw);
    defer allocator.free(current_exe);
    {
        var client = connectOrLaunch(allocator, current_exe, base, .{ .connect_attempts = 5, .connect_delay_ms = 10 }) orelse {
            try testing.expect(false);
            return;
        };
        defer client.deinit();
        try testing.expectEqual(host_id, client.host_id);
        try testing.expect(client.host_manifest_v1);
    }

    // Workspace restore는 major endpoint를 추측하지 않고 daemon이 publish한 exact host manifest를 따라간다.
    {
        var exact = switch (connectExistingHost(allocator, base, host_id)) {
            .connected => |value| value,
            .failed => return error.TestUnexpectedResult,
        };
        defer exact.deinit();
        try testing.expectEqual(host_id, exact.host_id);
    }
    // CR4 issuer는 동일 manifest resolver를 쓰되 connect/hello 이후 단계와 공유할 absolute deadline을
    // 재생성하지 않는다. 이 행은 실제 daemon/manifest/socket을 bounded 제품 entrypoint로 통과한다.
    {
        const phase = try attach_phase_deadline.PhaseDeadline.start(io, .connect_hello);
        var exact = switch (connectExistingHostUntil(allocator, base, host_id, phase)) {
            .connected => |value| value,
            .failed => return error.TestUnexpectedResult,
        };
        defer exact.deinit();
        try testing.expectEqual(host_id, exact.host_id);
        try testing.expect(phase.absolute.remainingNs() > 0);
    }

    // 같은 host_id/endpoint라도 disk generation의 build identity가 peer와 다르면 stale entry로 거부한다.
    var manifest_path_buf: [832]u8 = undefined;
    const manifest_path = try host_manifest.manifestPathIn(&manifest_path_buf, dir, host_id);
    try testing.expect(c.unlink(manifest_path.ptr) == 0);
    var stale_manifest = try host_manifest.publish(allocator, dir, .{
        .host_id = host_id,
        .build_id = "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        .protocol_major = protocol.version_major,
        .screen_codec_version = @import("maru").session.screen_stream.codec_version,
        .upgrade_epoch = 0,
        .lifecycle = .ready,
        .endpoint = socket,
    });
    defer stale_manifest.deinit();
    const stale = connectExistingHost(allocator, base, host_id);
    try testing.expectEqual(FailureReason.stale_manifest, stale.failed);
}

test "host_connect: falls back to null when no host exists and spawn cannot bind" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;

    var base_buf: [128]u8 = undefined;
    const base = std.fmt.bufPrintZ(&base_buf, "/tmp/maru-sh-hcf-{d}", .{c.getpid()}) catch return error.SkipZigTest;
    _ = c.mkdir(base.ptr, 0o700); // base 존재 → spawn_host 경로를 실제로 탄다(lock 취득→spawn 실패→backoff→null).
    defer {
        // 테스트가 만든 dir/lock 정리(host는 안 떴다).
        var dir_buf: [256]u8 = undefined;
        if (discovery.sessionHostDirPath(&dir_buf, base)) |dir| {
            var lp_buf: [320]u8 = undefined;
            if (discovery.lockPathIn(&lp_buf, dir)) |lp| _ = c.unlink(lp.ptr) else |_| {}
            _ = c.rmdir(dir.ptr);
        } else |_| {}
        _ = c.rmdir(base.ptr);
    }

    // host 없음 + helper exe가 bind 못 함(/nonexistent → exec 실패 _exit 127) → 짧은 backoff 뒤 null(in-process 폴백).
    const result = connectOrLaunch(allocator, "/nonexistent-maru-helper", base, .{ .connect_attempts = 3, .connect_delay_ms = 10 });
    try testing.expect(result == null);
}

// §7 접속 실패 행렬의 **영구 vs 일시** 구분을 못박는다. 저장된 runtime을 종료 placeholder로 둘지는 이 구분 하나에만
// 의존하므로, 일시 실패가 host_gone으로 새면 살아 있는 세션이 placeholder로 굳어 되찾을 길이 사라진다. 터미널에서
// 중요한 이유: 이 판정이 사용자가 며칠 띄워 둔 셸·빌드·SSH를 살릴지 버릴지 가른다. 격리된 base를 쓰는 이유는 실
// 사용자 캐시에 살아 있는 host가 있으면 결과가 환경에 따라 달라지기 때문이다(결정적 테스트).
test "host_connect: manifest도 endpoint도 없는 host_id는 host_gone으로 단정한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;

    var base_buf: [128]u8 = undefined;
    const base = std.fmt.bufPrintZ(&base_buf, "/tmp/maru-sh-gone-{d}", .{c.getpid()}) catch return error.SkipZigTest;
    _ = c.mkdir(base.ptr, 0o700);
    var dir_buf: [256]u8 = undefined;
    const dir = discovery.sessionHostDirPath(&dir_buf, base) catch return error.SkipZigTest;
    _ = c.mkdir(dir.ptr, 0o700);
    defer {
        _ = c.rmdir(dir.ptr);
        _ = c.rmdir(base.ptr);
    }

    // manifest 없음 + 그 host_id로 응답하는 current/N-1 legacy endpoint 없음 → 추측할 경로가 소진됐으므로 "아직 안
    // 떴다"가 아니라 "사라졌다"다. host_id=0은 손상 입력이라 invalid_endpoint로 남아야 하고(영구로 승격 금지),
    // 이 대조가 없으면 "전부 host_gone" 구현도 테스트를 통과한다.
    const gone = connectExistingHost(allocator, base, 0x1234_5678_9abc_def0_1234_5678_9abc_def0);
    try testing.expect(gone == .failed);
    try testing.expectEqual(FailureReason.host_gone, gone.failed);

    const invalid = connectExistingHost(allocator, base, 0);
    try testing.expect(invalid == .failed);
    try testing.expectEqual(FailureReason.invalid_endpoint, invalid.failed);
}

test "host_connect: recovery descriptor replacement는 legacy probe 없이 stale로 거부한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var base_buf: [128]u8 = undefined;
    const base = std.fmt.bufPrintZ(&base_buf, "/tmp/maru-sh-discovered-{d}", .{c.getpid()}) catch
        return error.SkipZigTest;
    _ = c.mkdir(base.ptr, 0o700);
    var dir_buf: [256]u8 = undefined;
    const dir = discovery.sessionHostDirPath(&dir_buf, base) catch return error.SkipZigTest;
    _ = c.mkdir(dir.ptr, 0o700);
    const host_id: u128 = 0xD15C0;
    var endpoint_buf: [128]u8 = undefined;
    const endpoint = try short_endpoint.currentSocketPathIn(&endpoint_buf, host_id);
    const original: host_manifest.Descriptor = .{
        .host_id = host_id,
        .build_id = "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        .protocol_major = protocol.version_major,
        .screen_codec_version = screen_stream.codec_version,
        .upgrade_epoch = 1,
        .lifecycle = .ready,
        .endpoint = endpoint,
    };
    var published = try host_manifest.publish(allocator, dir, original);
    defer {
        published.deinit();
        host_manifest.removeEmptyHostDirectories(dir, host_id);
        _ = c.rmdir(dir.ptr);
        _ = c.rmdir(base.ptr);
    }
    var replacement = original;
    replacement.upgrade_epoch = 2;
    try published.republish(replacement);

    const result = connectDiscoveredHost(allocator, base, original);
    try testing.expect(result == .failed);
    try testing.expectEqual(FailureReason.stale_manifest, result.failed);
}

// code-review(max) 회귀: owner lease 관측이 bool이라 **"lease 파일이 없다"(host 사망의 증거)** 와 **"우리가 볼 수 없었다"**
// (fd 고갈·권한)가 같은 값이었고, 그 값이 곧바로 `host_gone`(영구) 판정에 쓰였다. 즉 우리 쪽 사정으로 살아 있는 host를
// 사라졌다고 단정할 수 있었다. 터미널에서 왜 중요한가: 그 오분류의 대가는 실행 중인 셸·빌드·SSH 세션이 통째로 묘비가
// 되고 다음 checkpoint가 그 handle을 지워 **되찾을 길이 사라지는** 것이다(§7 접속 실패 행렬의 비대칭).
test "host_connect: owner lease는 부재(free)와 판정 불가(unknown)를 구분한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    var base_buf: [128]u8 = undefined;
    const base = std.fmt.bufPrintZ(&base_buf, "/tmp/maru-sh-lease-{d}", .{c.getpid()}) catch return error.SkipZigTest;
    _ = c.mkdir(base.ptr, 0o700);
    var dir_buf: [256]u8 = undefined;
    const dir = discovery.sessionHostDirPath(&dir_buf, base) catch return error.SkipZigTest;
    _ = c.mkdir(dir.ptr, 0o700);
    defer {
        _ = c.rmdir(dir.ptr);
        _ = c.rmdir(base.ptr);
    }

    const host_id: u128 = 0xFEED_BEEF;
    // (1) lease 파일이 아예 없다 = host가 lease를 놓았다 → free(= 사라졌다고 단정해도 되는 유일한 상태).
    try testing.expectEqual(owner_lease.Observation.free, ownerLeaseState(dir, host_id));

    // (2) 같은 경로가 **열 수 없는 것**이면(여기선 디렉터리 — open(RDWR)이 EISDIR) 파일 상태를 알 수 없다 → unknown.
    //     예전 bool 구현은 이 경우도 "lease 없음"으로 접어 host_gone을 만들었다.
    var hosts_buf: [640]u8 = undefined;
    const hosts_root = host_manifest.hostsRootPathIn(&hosts_buf, dir) catch return error.SkipZigTest;
    _ = c.mkdir(hosts_root.ptr, 0o700);
    var host_dir_buf: [768]u8 = undefined;
    const host_dir = host_manifest.hostDirPathIn(&host_dir_buf, dir, host_id) catch return error.SkipZigTest;
    _ = c.mkdir(host_dir.ptr, 0o700);
    var lock_buf: [832]u8 = undefined;
    const lock_path = host_manifest.ownerLockPathIn(&lock_buf, dir, host_id) catch return error.SkipZigTest;
    _ = c.mkdir(lock_path.ptr, 0o700);
    defer {
        _ = c.rmdir(lock_path.ptr);
        _ = c.rmdir(host_dir.ptr);
        _ = c.rmdir(hosts_root.ptr);
    }
    try testing.expectEqual(owner_lease.Observation.unknown, ownerLeaseState(dir, host_id));
}

/// legacy endpoint에 **연결은 되지만 hello가 갈리는** peer. 살아 있는 host를 흉내 내되 우리 major와 말이 안 통하는
/// 상태다(mixed-build·구 host). 응답 없이 닫아 client가 handshake 실패로 보게 한다.
const MismatchedPeer = struct {
    fn serve(server: *socket_server.SocketServer, ok: *bool) void {
        var ready = c.pollfd{
            .fd = server.listen_fd,
            .events = c.POLL.IN,
            .revents = 0,
        };
        if (c.poll(@ptrCast(&ready), 1, 1_000) <= 0 or ready.revents & c.POLL.IN == 0) return;
        const fd = server.acceptOne() orelse return;
        _ = c.close(fd); // hello를 읽지도 답하지도 않는다 → client는 ConnectionClosed(=handshake_failed).
        ok.* = true;
    }
};

// code-review(max) 회귀: `connectLegacyExact`가 **모든 probe가 일시 실패여도** 경로 소진만으로 `host_gone`(영구)을
// 반환했다. manifest 경로와 달리 owner-lease 교차확인도 backoff도 없어, 잠깐 바쁘거나 말이 안 통한 host의 세션이
// 그대로 묘비가 됐다. 이제 **모든 probe가 부재였을 때만** 영구로 올리고, 하나라도 미확정이면 fail-closed(일시)로 남긴다.
// 터미널에서 왜 중요한가: 위 lease 테스트와 같은 비대칭 — 영구를 일시로 보면 창 복원이 한 번 실패할 뿐이지만, 반대는
// 살아 있는 세션을 영구히 잃는다.
test "host_connect: legacy 경로의 미확정 probe는 host_gone으로 승격되지 않는다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;

    var base_buf: [128]u8 = undefined;
    const base = std.fmt.bufPrintZ(&base_buf, "/tmp/maru-sh-ind-{d}", .{c.getpid()}) catch return error.SkipZigTest;
    _ = c.mkdir(base.ptr, 0o700);
    var dir_buf: [256]u8 = undefined;
    const dir = discovery.sessionHostDirPath(&dir_buf, base) catch return error.SkipZigTest;
    var socket_buf: [320]u8 = undefined;
    // current major의 versioned endpoint에 peer를 세운다 — manifest는 없으므로 호출자는 legacy 경로로 내려온다.
    const socket = discovery.socketPathForMajorIn(&socket_buf, dir, protocol.version_major) catch
        return error.SkipZigTest;
    var registry = registry_mod.TerminalRuntimeRegistry.init(allocator);
    defer registry.deinit();
    var server = try socket_server.SocketServer.bind(allocator, dir, socket, 0xBB, &registry);
    defer {
        server.deinit();
        _ = c.rmdir(dir.ptr);
        _ = c.rmdir(base.ptr);
    }
    var served = false;
    var thread = try std.Thread.spawn(.{}, MismatchedPeer.serve, .{ &server, &served });
    const outcome = connectExistingHost(allocator, base, 0x9999_8888_7777_6666);
    thread.join();
    try testing.expect(served);
    try testing.expect(outcome == .failed);
    // 핵심: 응답하지 않은 endpoint 뒤에 host가 살아 있을 수 있으므로 **영구(host_gone)가 아니다**.
    try testing.expect(outcome.failed != .host_gone);
}

/// exec 직후 **복원 중**인 host: endpoint는 이미 열려 accept까지 되지만 hello는 아직 답하지 못한다. runtime과
/// 큐를 되살리는 동안의 정상 국면이며, 죽은 상태가 아니다. client는 이를 `handshake_failed`(=ConnectionClosed)로
/// 본다 — `MismatchedPeer`와 wire 동작은 같고 **의미만 다르다**(말이 안 통함 vs 아직 준비 전).
const RestoringPeer = struct {
    fn serve(server: *socket_server.SocketServer, accepted: *usize, want: usize) void {
        while (accepted.* < want) {
            var ready = c.pollfd{
                .fd = server.listen_fd,
                .events = c.POLL.IN,
                .revents = 0,
            };
            if (c.poll(@ptrCast(&ready), 1, 1_000) <= 0 or ready.revents & c.POLL.IN == 0) return;
            const fd = server.acceptOne() orelse return;
            _ = c.close(fd); // 아직 hello를 줄 수 없다 — 복원이 끝나면 준다.
            accepted.* += 1;
        }
    }
};

// 회귀: exec upgrade의 재연결이 **재시도 예산을 한 번도 쓰지 못하고** 첫 실패에서 끝났다.
//
// exec 직후 host는 manifest를 이미 publish했고 owner lease도 쥐고 있다. 그래서 "아직 안 떴다"(`host_gone`)도,
// "복원 중"(`lifecycle == .restoring`)도 아니다 — endpoint는 accept까지 되는데 복원이 끝나지 않아 hello만 아직
// 못 준다. client는 그 국면을 `handshake_failed`로 읽는데, 두 겹의 backoff가 **모두** 그 값을 확정 실패로 보고
// 즉시 반환한다: 안쪽 `connectExactWithBackoffKind`의 `.failed => return`, 바깥
// `connectNewHostWithBackoff`의 `else => return`. 결과적으로 500×20ms=10s 예산을 두고도 **총 시도는 1회**다.
//
// 이 파일이 스스로 경고한 최악의 형태가 그대로 나온다 — 살아 있는 host를 `unreachable`로 오판하고 새 host를 띄워
// **같은 build_id host가 둘** 남는다. 2026-08-27 실측이 정확히 그랬다: 어제 저녁 host와 새벽 host가 공존했고,
// `host status`가 ambiguous로 답했으며, 복구 세션을 눌러도 어느 쪽에 붙을지 정하지 못해 앱이 조용히 종료됐다.
//
// 관찰 지표는 **peer가 accept당한 횟수**다. 첫 실패에서 포기하면 1회, 예산을 쓰면 요청한 횟수만큼 찍힌다.
test "host_connect: 복원 중 host 의 hello 실패는 재연결 예산을 소진한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;

    var base_buf: [128]u8 = undefined;
    const base = std.fmt.bufPrintZ(&base_buf, "/tmp/maru-sh-restoring-{d}", .{c.getpid()}) catch
        return error.SkipZigTest;
    _ = c.mkdir(base.ptr, 0o700);
    var dir_buf: [256]u8 = undefined;
    const dir = discovery.sessionHostDirPath(&dir_buf, base) catch return error.SkipZigTest;
    var socket_buf: [320]u8 = undefined;
    const socket = discovery.socketPathForMajorIn(&socket_buf, dir, protocol.version_major) catch
        return error.SkipZigTest;
    var registry = registry_mod.TerminalRuntimeRegistry.init(allocator);
    defer registry.deinit();
    var server = try socket_server.SocketServer.bind(allocator, dir, socket, 0xBB, &registry);
    defer {
        server.deinit();
        _ = c.rmdir(dir.ptr);
        _ = c.rmdir(base.ptr);
    }

    // 실패 경로만 보므로 descriptor는 대조에 쓰이지 않는다(`validateExactClient`는 connected에서만 돈다).
    const expected = host_manifest.Descriptor{
        .host_id = 0x9999_8888_7777_6666,
        .build_id = "test-build-id",
        .protocol_major = protocol.version_major,
        .screen_codec_version = 0,
        .upgrade_epoch = 0,
        .lifecycle = .ready,
        .endpoint = socket,
    };

    const want: usize = 3;
    var accepted: usize = 0;
    var thread = try std.Thread.spawn(.{}, RestoringPeer.serve, .{ &server, &accepted, want });
    const outcome = connectExactWithBackoffKind(allocator, socket, expected, .gui, .{
        .connect_attempts = want,
        .connect_delay_ms = 1,
    });
    thread.join();

    try testing.expect(outcome == .failed);
    // 핵심: 복원이 끝나지 않아 결국 실패하더라도, 그 전에 **예산을 모두 써 봐야** 한다. 살아 있는 host를 한 번의
    // hello 실패로 `unreachable`이라 단정하는 것이 이 회귀의 본체였다.
    try testing.expectEqual(want, accepted);
}

test "host_connect: launches the product maru session host and completes host.info" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    // `@import("root")`는 Zig test runner module 배치에 따라 이 barrel의
    // declaration을 보지 못해 전용 `test-session-host`에서도 조용히
    // skip됐다. Build step이 주는 exact marker로 전용 실행과 전체 test의
    // 중복 수집을 구분하고, marker가 있는데 product artifact가 빠졌다면
    // wiring 회귀로 실패시킨다.
    const required = std.c.getenv(
        "MARU_SESSION_HOST_REQUIRE_PRODUCT_LAUNCH_SMOKE",
    ) orelse return error.SkipZigTest;
    if (!std.mem.eql(
        u8,
        std.mem.span(required),
        "maru-test-only-v1",
    )) return error.SkipZigTest;
    const allocator = testing.allocator;
    const product_exe_raw = std.c.getenv("MARU_SESSION_HOST_PRODUCT_EXE") orelse {
        try testing.expect(false); // macOS 공식 build wiring이 product artifact 주입을 잃으면 skip이 아니라 실패한다.
        return;
    };
    const product_exe: [:0]const u8 = std.mem.span(product_exe_raw);

    // PID만 쓰면 강제 종료 뒤 PID 재사용 시 stale host에 connect-first로 붙어 새 product exec를 건너뛸 수 있다.
    // CSPRNG nonce + 배타적 mkdir로 매 실행의 launch 경로가 비어 있음을 보장한다.
    var nonce: u64 = undefined;
    arc4random_buf(std.mem.asBytes(&nonce).ptr, @sizeOf(u64));
    var base_buf: [160]u8 = undefined;
    const base = std.fmt.bufPrintZ(&base_buf, "/tmp/maru-sh-product-{d}-{x}", .{ c.getpid(), nonce }) catch return error.SkipZigTest;
    try testing.expectEqual(@as(c_int, 0), c.mkdir(base.ptr, 0o700));

    var dir_buf: [256]u8 = undefined;
    const dir = discovery.sessionHostDirPath(&dir_buf, base) catch return error.SkipZigTest;
    var launched_host_id: u128 = 0;
    var launched_socket_buf: [128]u8 = undefined;

    {
        var client = connectOrLaunch(allocator, product_exe, base, .{}) orelse {
            try testing.expect(false);
            return;
        };
        defer client.deinit();
        launched_host_id = client.host_id;
        try testing.expect(client.host_manifest_v1);
        _ = try short_endpoint.currentSocketPathIn(&launched_socket_buf, launched_host_id);
        const response = try client.call("host.info", null);
        defer allocator.free(response);
        try testing.expect(std.mem.indexOf(u8, response, "\"runtime_count\":0") != null);
    }

    var owner_buf: [832]u8 = undefined;
    const owner_path = try host_manifest.ownerLockPathIn(&owner_buf, dir, launched_host_id);
    var manifest_buf: [832]u8 = undefined;
    const manifest_path = try host_manifest.manifestPathIn(&manifest_buf, dir, launched_host_id);
    var host_dir_buf: [768]u8 = undefined;
    const host_dir = try host_manifest.hostDirPathIn(&host_dir_buf, dir, launched_host_id);
    var hosts_buf: [640]u8 = undefined;
    const hosts_root = try host_manifest.hostsRootPathIn(&hosts_buf, dir);

    // oneshot host의 정상 종료가 endpoint뿐 아니라 manifest→owner lock→빈 registry directory 순으로 전부 회수하는지
    // 확인한다. 테스트가 직접 지우면 제품의 누적 회귀를 숨기므로 부재만 관찰한다.
    var stopped = false;
    var attempts: usize = 0;
    // 병렬 전체 게이트에서도 제품 종료 순서는 바꾸지 않고, filesystem 회수 완료를 최대 15초 관측한다.
    while (attempts < 750) : (attempts += 1) {
        if (c.access(@ptrCast(&launched_socket_buf), 0) != 0 and
            c.access(manifest_path.ptr, 0) != 0 and
            c.access(owner_path.ptr, 0) != 0 and
            c.access(host_dir.ptr, 0) != 0 and
            c.access(hosts_root.ptr, 0) != 0)
        {
            stopped = true;
            break;
        }
        _ = usleep(20 * 1000);
    }
    try testing.expect(stopped);

    var lock_buf: [320]u8 = undefined;
    if (discovery.lockPathIn(&lock_buf, dir)) |lock| _ = c.unlink(lock.ptr) else |_| {}
    _ = c.rmdir(dir.ptr);
    _ = c.rmdir(base.ptr);
}

// 이 테스트가 증명하는 것(그리고 터미널에서 왜 중요한가): 앱을 업데이트하면 새 binary는 build_id가 달라 기존 host를
// 재사용하지 못한다. 그때 살아 있는 host를 새 이미지로 exec 교체하면 PTY master·자식 프로세스·scrollback이 그대로
// 보존돼 사용자의 셸이 업데이트를 넘어 살아남는다. 반대로 **교체 대상을 잘못 고르면 살아 있는 세션을 통째로 흔든다** —
// wire가 갈리는 host는 exec이 아니라 side-by-side 대상이고(구 major 세션을 N-1 adapter가 따로 이어받는다), 이미 정리
// 중인 host에 새 이미지를 얹으면 drain 계약이 깨지며, 생존의 긍정적 증거가 없는 host를 건드리면 우리 쪽 관측 실패로
// 남의 host를 exec하는 것이 된다. 순수 판정이라 syscall 없이 이 네 경계를 고정한다.
test "exec 업그레이드 후보: build_id가 다르고 wire가 같은 살아 있는 ready host만 고른다" {
    const target = "sha256:new";
    const base: UpgradeCandidate = .{
        .protocol_major = protocol.version_major,
        .screen_codec_version = screen_stream.codec_version,
        .lifecycle = .ready,
        .build_id = "sha256:old",
    };
    try testing.expect(isUpgradeCandidate(base, target, .held));

    // 같은 build면 교체할 것이 없다 — findCurrentManifestHost가 이미 그 host를 재사용했다.
    var same = base;
    same.build_id = target;
    try testing.expect(!isUpgradeCandidate(same, target, .held));

    // wire가 갈리면 exec 대상이 아니다(side-by-side).
    var other_major = base;
    other_major.protocol_major = protocol.version_major +% 1;
    try testing.expect(!isUpgradeCandidate(other_major, target, .held));
    var other_codec = base;
    other_codec.screen_codec_version = screen_stream.codec_version +% 1;
    try testing.expect(!isUpgradeCandidate(other_codec, target, .held));

    // 정리 중이거나 아직 복원 중인 host에 새 이미지를 얹지 않는다.
    var draining = base;
    draining.lifecycle = .draining;
    try testing.expect(!isUpgradeCandidate(draining, target, .held));
    var restoring = base;
    restoring.lifecycle = .restoring;
    try testing.expect(!isUpgradeCandidate(restoring, target, .held));

    // 생존의 긍정적 증거가 있을 때만 손댄다 — free는 정리 대상이고, unknown은 우리 쪽 관측 실패다.
    try testing.expect(!isUpgradeCandidate(base, target, .free));
    try testing.expect(!isUpgradeCandidate(base, target, .unknown));
}

// 이 테스트가 증명하는 것(그리고 터미널에서 왜 중요한가): exec 업그레이드는 host가 accepted를 보내고도 실제 exec에
// 실패해 옛 이미지로 rollback할 수 있다. 그때 같은 host_id로 재연결은 **성공한다** — 프로세스가 살아 있으니까.
// 재연결 성공만으로 채택하면 GUI는 host-backed라고 믿고 runtime.spawn을 걸었다가, 옛 host가 모르는 capability
// (`runtime_core_command_v1`) 때문에 UnsupportedSpawnContract로 실패해 **모든 터미널이 in-process로 떨어진다**
// (실측: 앱 업데이트 뒤 정확히 이 일이 벌어졌고, stage=runtime_death 로그로 드러났다). build_id 게이팅이 원래
// 막아 주던 상황을 업그레이드 경로가 우회해 만들어 내는 셈이라, 업그레이드를 안 하느니 못한 회귀가 된다.
// 그래서 build_id가 target과 정확히 같을 때만 채택하고, 모르면(null) 거부하는 fail-closed 규율을 고정한다.
test "업그레이드 재연결 채택: build_id가 target과 같을 때만, 모르면 거부한다" {
    const target = "sha256:new";
    try testing.expect(upgradedHostMatches("sha256:new", target));

    // rollback 등으로 옛 이미지가 그대로면 거부한다 — 이 한 줄이 없으면 전 터미널이 in-process로 떨어진다.
    try testing.expect(!upgradedHostMatches("sha256:old", target));
    // build_id를 광고하지 않는 host는 증거가 없으므로 거부(fail-closed).
    try testing.expect(!upgradedHostMatches(null, target));
    // 접두사만 겹치는 경우도 정확 일치가 아니면 거부한다.
    try testing.expect(!upgradedHostMatches("sha256:ne", target));
    try testing.expect(!upgradedHostMatches("sha256:neww", target));
}

// The UI and structured log must not independently translate wire state. These representative
// values prove the bounded DTO preserves the exact host/status/reason vocabulary and remains safe
// when a caller supplies a buffer too small for diagnostic text.
test "upgrade notice detail is bounded and preserves typed result" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "result=upgraded host=0000000000000000000000000000002a",
        (UpgradeNotice{ .upgraded = 42 }).detail(&buf),
    );
    try testing.expectEqualStrings(
        "result=upgrade_busy host=0000000000000000000000000000002a",
        (UpgradeNotice{ .upgrade_busy = 42 }).detail(&buf),
    );
    try testing.expectEqualStrings(
        "result=legacy_unavailable host=0000000000000000000000000000002a",
        (UpgradeNotice{ .legacy_unavailable = 42 }).detail(&buf),
    );
    try testing.expectEqualStrings(
        "result=upgrade_failed host=0000000000000000000000000000002a status=rolled_back reason=restore_failed",
        (UpgradeNotice{ .upgrade_failed = .{
            .host_id = 42,
            .failure = .{ .report = .{ .status = .rolled_back, .reason = .restore_failed } },
        } }).detail(&buf),
    );
    var tiny: [1]u8 = undefined;
    try testing.expectEqualStrings(
        "result=upgrade_failed detail=truncated",
        (UpgradeNotice{ .upgrade_failed = .{
            .host_id = 42,
            .failure = .{ .local = .status_query_failed },
        } }).detail(&tiny),
    );
}
