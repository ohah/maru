//! Nonblocking, connection-local readiness turn adapter for the session-host reactor.
//!
//! The daemon poll owner decides which fd is ready. This module owns one fd, parser, protocol
//! `Connection`, and the outbound bytes charged to its `connection_slot.Slot`; it never polls or
//! waits. T0b2 only has to admit/remove these stable heap clients and schedule one turn at a time.

const std = @import("std");
const builtin = @import("builtin");
const host_log = @import("host_log.zig");
const c = std.c;
const posix = std.posix;
const framing = @import("framing.zig");
const protocol = @import("protocol.zig");
const registry = @import("registry.zig");
const server = @import("server.zig");
const slot_mod = @import("connection_slot.zig");
const subscription_identity = @import("subscription_identity.zig");
const upgrade = @import("upgrade_coordinator.zig");
const upgrade_wire = @import("upgrade_wire.zig");
const process_seal_service = @import("process_seal_service.zig");
const catchup_barrier_contract = @import("catchup_barrier_contract.zig");
const collect_failure = @import("collect_failure.zig");
const image_channel_wire = @import("image_channel_wire.zig");
const image_segment_ledger = @import("image_segment_ledger.zig");
const image_segment = @import("image_segment.zig");

pub const CloseReason = enum {
    eof,
    socket_error,
    protocol_error,
    resource_exhausted,
    internal_error,
    admission_closed,
    peer_requested,
    reply_flushed,
    partial_timeout,
    upgrade_completed,
    upgrade_failed,
};

pub const State = union(enum) {
    open,
    closing: CloseReason,
};

pub const ArmedUpgrade = struct {
    attempt_id: u128,
    /// `upgrade_attempt.freezePreclosed` is mandatory for this marker.
    gate_preclosed: bool = true,
};

/// **어느 자리에서 몇 바이트로 한도에 걸렸는지** 남긴다.
///
/// `resource_exhausted` 는 네 자리에서 나는데(스트림 목록 할당 실패·턴 게이트·bounded push·파서 OOM)
/// 고칠 곳이 전부 다르다. 그런데 닫힘 로그에는 `why=resource_exhausted` 한 줄만 남아 갈리지 않는다.
///
/// 2026-09-11 실측: 복구 세션 23 개 중 21 개는 붙었고 **2 개만** 이 경로로 GUI 연결을 끊었다
/// (`client poison: reason=connection_eof` → `transport_read_failure`). 둘 다 `runtime.get` 응답이
/// 성공한 21 개와 구별되지 않아(필드 6 개, 272×72, 리스 없음) **내용 크기 말고는 후보가 없는데**,
/// 실제 바이트 수가 안 남아 확정할 수 없었다. 한 줄이면 「최대 프레임이 cap 과 같아져 걸리는가」가
/// 즉시 갈린다 — cap 은 `header_size + max_binary_chunk` 라 최대 프레임 하나가 정확히 들어가는 크기고,
/// 검사는 `>=` 다.
fn noteResidentCap(site: []const u8, buffered: usize) void {
    if (builtin.is_test) return;
    host_log.line(
        "session host inbound cap: site={s} buffered={d} cap={d}",
        .{ site, buffered, inbound_resident_cap },
    );
}

pub const inbound_resident_cap: usize =
    protocol.header_size + protocol.max_binary_chunk;
pub const handshake_deadline_ns: u64 = 10 * std.time.ns_per_s;
pub const admin_request_deadline_ns: u64 = 5 * std.time.ns_per_s;
pub const unattached_idle_deadline_ns: u64 = 30 * std.time.ns_per_s;

comptime {
    const max_snapshot_frames =
        (protocol.max_viewport_snapshot + protocol.max_binary_chunk - 1) /
        protocol.max_binary_chunk;
    if (slot_mod.resync_batch_bytes <
        protocol.max_viewport_snapshot + max_snapshot_frames * protocol.header_size)
        @compileError("resync queue cap cannot hold one maximum wire snapshot");
}

pub const Options = struct {
    runtime_ops: ?server.RuntimeOps = null,
    upgrade_ops: ?upgrade_wire.Ops = null,
    admission_gate: ?*upgrade.AdmissionGate = null,
    host_status: server.HostStatus = .{},
    live_host_status: ?*const server.HostStatus = null,
    admin_admission: ?*server.AdminAdmission = null,
    upgrade_preflight: ?OwnerUpgradePreflight = null,
    pressure_reclaim: ?OwnerPressureReclaim = null,
    controller_transition: ?OwnerControllerTransition = null,
    resize: ?OwnerResize = null,
    image_channel: ?OwnerImageChannel = null,
    now_ns: u64 = 0,
    process_identity: ?process_seal_service.ReadyIdentity = null,
};

/// 이미지 채널 자리 확보·token 표는 owner 층이다(이미지 채널 §3.1). Client 는 자기 hello 판정 때 묻고, abandon 때
/// 자기 token 을 버리게 한다.
pub const OwnerImageChannel = struct {
    ctx: *anyopaque,
    admit_hello: *const fn (ctx: *anyopaque, requester: *Client) bool,
    issue_token: *const fn (ctx: *anyopaque, requester: *Client) ?u128,
    drop_tokens: *const fn (ctx: *anyopaque, requester: *Client) void,
};

/// 이미지 채널을 내린 이유(이미지 채널 §3.2). 주 연결은 어느 경우에도 닫지 않는다.
pub const ImageChannelLoss = enum {
    /// 앱이 `image_channel.abandon` 을 보냈다(입양 뒤 늦게 온 abandon 포함).
    abandoned,
    /// 채널이 EOF·HUP 로 끝났다.
    peer_closed,
    socket_error,
    /// 앱이 release 가 아닌 바이트나 fd 를 보냈다(§3.3).
    protocol_error,
    /// `bind_ack` 를 다 쓰지 못했다. 빈 소켓에 8 B 라 앱이 살아 있으면 생기지 않는다 — 앱이 이미 채널을 닫은 경우다.
    bind_ack_send,
    /// 세그먼트 메시지를 보내지 못했다. 원장 상한(≤ 32)이 커널의 fd 메시지 버퍼(64)보다 작아 정상은 막히지 않는다 — 앱이 채널을
    /// 닫았거나 불변식이 깨진 경우다(§4.3).
    segment_send,
};

/// 투영이 이미지 하나에 대해 받는 답(이미지 채널 §4·§5). 준비한 세그먼트는 그 배치가 큐에 승인되면 `issueImageSegments`, 아니면
/// (배치 롤백·투영 실패) `cancelImageSegments` 로 **정확히 한 번** 끝나야 한다 — 그 사이 원장에는 준비 상태로 남는다. 타입은
/// Connection 층과 함께 쓰므로 원장 leaf 에 있다.
pub const ImageSegmentPrepare = image_segment_ledger.ImageSegmentPrepare;
pub const PreparedImageSegment = image_segment_ledger.PreparedImageSegment;

/// 이미지 fd 의 한 읽기 턴에서 받는 최대 바이트(release 256 개).
pub const image_channel_read_bytes: usize = 256 * image_channel_wire.release_len;

/// 이 맥에서 한 메시지에 실리는 fd 상한(255 개부터 `sendmsg` 가 EINVAL, 2026-10-11 실측).
pub const image_channel_max_fds_per_message: usize = 254;

/// release 에 붙어 올 수 있는 SCM_RIGHTS 를 **전부** 담는 제어 버퍼. 잘리면 커널은 fd 를 전부 설치하고 잘린 만큼은
/// 알려 주지 않아 닫을 수 없다(이미지 채널 §10). `CMSG_SPACE(254 * 4)` 는 1028 B 다.
pub const image_channel_control_bytes: usize = 2048;

comptime {
    // 「적정화」로 줄이면 fd 가 새는데 판정자가 못 볼 수 있다 — 상한 하나를 담는 크기 아래로는 못 내려가게 잠근다.
    const header = std.mem.alignForward(usize, @sizeOf(c.cmsghdr), @sizeOf(u32));
    const data = std.mem.alignForward(usize, image_channel_max_fds_per_message * @sizeOf(c.fd_t), @sizeOf(u32));
    if (image_channel_control_bytes < header + data)
        @compileError("image channel control buffer must hold the largest SCM_RIGHTS message the kernel accepts");
}

pub const OwnerUpgradePreflight = struct {
    ctx: *anyopaque,
    check: *const fn (ctx: *anyopaque, requester: *Client) bool,
};

pub const OwnerPressureReclaim = struct {
    ctx: *anyopaque,
    reclaim: *const fn (
        ctx: *anyopaque,
        requester: slot_mod.ConnectionKey,
        required_bytes: usize,
    ) bool,
};

pub const OwnerControllerTransition = struct {
    ctx: *anyopaque,
    /// Consumes every frame and the owning prepared token in `transition` on both success and
    /// failure. Caller must not discard or reuse any field after apply returns.
    apply: *const fn (
        ctx: *anyopaque,
        requester: *Client,
        transition: server.Action.ControllerTransitionRequested,
    ) bool,
};

pub const OwnerResize = struct {
    ctx: *anyopaque,
    /// Consumes every owned frame/body and the prepared token on both success and failure.
    apply: *const fn (
        ctx: *anyopaque,
        requester: *Client,
        resize: server.Action.ResizeRequested,
    ) bool,
};

pub const ScreenPressureCandidate = struct {
    stream: subscription_identity.LocalStreamId,
    tracker: slot_mod.ScreenTrackerKey,
    queued_bytes: usize,
    reclaimable_bytes: usize,
    written_prefix: bool,
};

const SubscriptionAdoption = enum {
    admitted,
    deferred_global_pressure,
    deferred_resync,
    rejected,
};

/// **attach 가 왜 거절됐는지** 남긴다. 이 네 값은 성격이 정반대인데 호출부가 `!= .admitted` 하나로 묶어
/// **연결 전체를 끊는다** — `deferred_*` 는 이름 그대로 「지금은 안 됨, 나중에」이고 `rejected` 는 영구다.
///
/// 2026-09-11 실측: `terminal-browser-pane` 세션 하나가 복구 목록에서 붙지 않았다. host 는
/// `why=resource_exhausted` 만 남겼고, 그 반환 주소를 `atos` 로 풀어서야 이 자리로 좁혀졌다
/// (`adoptPreparedAttach+228`). 그 전까지는 수신 한도(`inbound_resident_cap`)를 의심해 상수 세 개의
/// 정합성을 파고 있었는데 **전부 헛짚었다** — 그 자리에서는 한 줄도 안 찍혔다.
///
/// 프레임 수를 함께 낸다. 「예산에 걸렸다」면 그 수가 크고, 「검증에 걸렸다」면 작아도 난다.
/// `rejected` 를 낸 **여덟 자리 중 어디인가.**
///
/// 2026-09-11 실측: 복구 세션 하나가 `adoption=rejected frames=11` 로 끝내 안 붙었다. `rejected` 는
/// 영구라 재시도로는 안 되고, 프레임이 11 개뿐이라 **예산이 아니라 검증**이다. 그런데 그 여덟 자리는
/// 고칠 곳이 전부 다르다 — 배치 검증·슬롯 조회·트래커 부재·화면 상태 조회·무효화 중 delta 혼입·
/// resync enqueue OOM·resync stale·일반 enqueue 실패.
///
/// 이 축에서 추측으로 세 번 틀렸다(수신 한도·프레임 경계·턴 예산). 자리 이름 없이 또 고치면 네 번째다.
var adoption_reject_site: []const u8 = "none";

fn notePreparedAttachRejected(site: []const u8) void {
    adoption_reject_site = site;
    adoption_reject_error = "-";
    adoption_reject_bytes = 0;
}

/// 자리가 **여러 오류를 한 이름으로 묶는** 경우의 마지막 구분자.
///
/// 2026-09-12 실측: `site=screen_batch_enqueue` 까지 왔는데 그 자리는 `GlobalLimit` 을 뺀 **다섯**을
/// 한 이름으로 낸다 — `ScreenInvalidated`·`SlotLimit`·`ChunkLimit`·`OutOfMemory`·`Stale`. 고칠 곳이
/// 전부 다르다. 한도를 보면 `max_chunks_per_slot`(4096)은 `frames=11` 로 못 걸리고 `per_slot_bytes`
/// 는 18 MiB 라, `screen_soft_bytes`(8 MiB)가 유력하다 — 그러나 그건 **추론이다.**
/// 이 축에서 네 번 추측으로 틀렸다. 이름 하나면 끝난다.
var adoption_reject_error: []const u8 = "-";

/// 거부 배치의 합계 바이트. `ScreenInvalidated` 는 **연성 상한 초과**와 **길이 0 청크** 둘에서 나오고
/// 고칠 곳이 다르다. 숫자가 있으면 그 구분도, 17 MiB 재동기화 차선에 담기는 크기인지도 한 번에 끝난다.
var adoption_reject_bytes: usize = 0;

fn notePreparedAttachRejectedErr(site: []const u8, err: anyerror, batch_bytes: usize) void {
    adoption_reject_site = site;
    adoption_reject_error = @errorName(err);
    adoption_reject_bytes = batch_bytes;
}

const ResyncSweepBlock = struct {
    streams: usize,
    invalidated: usize,
    no_tracker: usize,
    state_stale: usize,
    not_pending: usize,
    cannot_attempt: usize,
    backoff: usize,
};

/// 직전과 **같은 분포면 다시 안 찍는다.** 멈춘 상태는 틱마다 같은 값을 내므로 그대로 두면 초당
/// 수십 줄이 된다 — 오늘 로그의 92 % 가 진단이었던 일을 되풀이하지 않는다(#3605).
var last_sweep_block: ?ResyncSweepBlock = null;

/// `collectOutput` 이 접힌 자리와 **원래 오류**를 남긴다. 닫기 직전 한 번뿐이라 소음이 아니다.
fn noteCollectFailure() void {
    if (builtin.is_test) return;
    // 줄 모양·길이 상한·방향은 `collect_failure.render` 가 소유하고 PR 에서 도는 순수 테스트가 잰다.
    // 여기서는 **그 렌더를 그대로** 한 줄로 낸다 — 다른 줄을 찍는 갈래를 두지 않는다.
    var buf: [collect_failure.line_capacity]u8 = undefined;
    host_log.line("{s}", .{collect_failure.render(&buf, collect_failure.last())});
}

/// frontier 가 어긋난 스트림을 **닫지 않고** resync 로 돌렸다는 한 줄. 바로 앞의 `collect failed` 줄이 무엇이
/// 얼마나 어긋났는지를 말하고, 이 줄은 그 뒤 연결이 살아 있다는 것을 말한다 — 없으면 「닫힘 줄이 안 보인다」로만
/// 추론해야 한다(로그 0건 ≠ 안 일어남).
fn noteStreamFrontierResync(stream: subscription_identity.LocalStreamId) void {
    if (builtin.is_test) return;
    host_log.line("session host stream resync after frontier mismatch: stream={d} -> snapshot.invalidated", .{stream});
}

/// 이 프로세스에서 구독 출력을 무효화한 횟수. 처음 몇 번과 그 뒤 일정 간격만 찍는 데 쓴다.
var subscription_invalidations: u64 = 0;

/// 다음 무효화가 방금 거부된 subscription turn 때문인가. 그 갈래(`tick` 의 `.rejected`)만 세우고 다음
/// `noteSubscriptionInvalidated` 가 소비한다 — 그때만 `adoption_reject_*` 가 그 무효화의 원인이다. 자리 이름을
/// 문자열로 비교하지 않는 이유: 자리 이름은 소스에 정확히 한 번만 있어야 로그 한 줄이 한 자리로 갈린다
/// (`close_site_name_boundary`).
var turn_reject_detail_pending: bool = false;

/// 구독 출력 무효화 한 줄 — **어느 자리가, 왜, 그 순간 얼마가 쌓여 있었는지.** 무효화는 그 스트림을
/// 1 초 백오프 뒤 전체 스냅샷 resync 로 보내므로 화면이 멈칫한다. 예전엔 `resync sweep blocked:
/// invalidated=1` 만 남아 다섯 자리 중 무엇인지, 연성 상한(`screen_soft_bytes`) 초과인지 길이 0 청크인지
/// 가를 수 없었다(2026-10-10 terminal-browser 프레임 드랍 조사). `reject_*` 는 `turn_rejected` 갈래에서만
/// 그 거부를 만든 enqueue 오류다(다른 갈래는 `-`). 브라우저가 이미지를 흘리면 초당 한 번꼴로 일어나므로
/// 처음 8 번과 그 뒤 256 번마다만 찍는다 — `n` 이 누적 횟수다.
fn noteSubscriptionInvalidated(
    site: []const u8,
    stream: subscription_identity.LocalStreamId,
    screen_resident: ?usize,
    slot_pending: usize,
) void {
    if (builtin.is_test) return;
    const turn_rejected = turn_reject_detail_pending;
    turn_reject_detail_pending = false; // 찍든 안 찍든 이 무효화에서 소비한다 — 다음 무효화로 새지 않게.
    subscription_invalidations +%= 1;
    const n = subscription_invalidations;
    if (n > 8 and n % 256 != 0) return;
    host_log.line(
        "session host stream invalidated: n={d} site={s} stream={d} reject_site={s} reject_err={s} reject_bytes={d} screen_resident={d} soft_cap={d} slot_pending={d}",
        .{
            n,
            site,
            stream,
            if (turn_rejected) adoption_reject_site else "-",
            if (turn_rejected) adoption_reject_error else "-",
            if (turn_rejected) adoption_reject_bytes else 0,
            screen_resident orelse 0,
            slot_mod.screen_soft_bytes,
            slot_pending,
        },
    );
}

/// 정체로 닫기 **직전** 한 줄. 바로 뒤의 `closed client connection ... site=tick_partial_*_stalled` 줄은
/// 「정체로 닫았다」까지만 말한다. 2026-10-07 18:59 GUI 끊김에서 그 줄만으로는
/// ① 두 기한(진행 없음 10 초 / 전체 30 초) 중 어느 것인지, ② 얼마나 쌓였는지, ③ 언제인지를 몰라
/// 「앱이 멈췄나 host 가 폭주했나」를 가르지 못했다(host 로그 줄에는 시각이 없다).
/// `at_unix` 는 앱 로그의 `client poison ... at_unix=` 와 같은 시계라 두 줄을 맞붙일 수 있다.
/// 연결마다 닫기는 한 번이라 소음이 아니다.
fn notePartialStall(
    direction: slot_mod.Slot.PartialDirection,
    expiry: slot_mod.Slot.PartialExpiry,
    stall: slot_mod.Slot.PartialStall,
) void {
    if (builtin.is_test) return;
    var wall: std.c.timespec = undefined;
    const at: i64 = if (std.c.clock_gettime(.REALTIME, &wall) == 0) wall.sec else 0;
    host_log.line(
        "session host partial stall: dir={s} expiry={s} since_progress_ms={d} since_start_ms={d} pending_bytes={d} resident_bytes={d} chunks={d} at_unix={d}",
        .{
            @tagName(direction),
            @tagName(expiry),
            stall.since_progress_ns / std.time.ns_per_ms,
            stall.since_start_ns / std.time.ns_per_ms,
            stall.pending_bytes,
            stall.resident_bytes,
            stall.chunks,
            at,
        },
    );
}

fn noteResyncSweepBlocked(now: ResyncSweepBlock) void {
    if (builtin.is_test) return;
    if (last_sweep_block) |prev| if (std.meta.eql(prev, now)) return;
    last_sweep_block = now;
    host_log.line(
        "session host resync sweep blocked: streams={d} invalidated={d} no_tracker={d} state_stale={d} not_pending={d} cannot_attempt={d} backoff={d}",
        .{ now.streams, now.invalidated, now.no_tracker, now.state_stale, now.not_pending, now.cannot_attempt, now.backoff },
    );
}

fn noteAttachAdoption(adopted: SubscriptionAdoption, frames: usize) void {
    if (builtin.is_test) return;
    host_log.line(
        "session host attach not admitted: adoption={s} site={s} err={s} bytes={d} frames={d}",
        .{ @tagName(adopted), adoption_reject_site, adoption_reject_error, adoption_reject_bytes, frames },
    );
}

pub const Client = struct {
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    reactor: *slot_mod.ReactorCore,
    admission: slot_mod.ReactorCore.Admission,
    parser: framing.FrameParser,
    connection: server.Connection,
    trackers: std.AutoHashMapUnmanaged(u64, slot_mod.ScreenTrackerKey) = .empty,
    state: State = .open,
    /// `beginClose` 를 부른 지점(0 = 아직 안 닫음). 사유가 같은 호출부가 여럿이라 사유만으론 못 좁힌다.
    close_ra: usize = 0,
    /// **어느 «줄»이 닫았는가.** `close_ra` 는 주소라 사람이 풀어야 하는데, 2026-09-13 에 그것을
    /// 역어셈블로 풀다가 명령이 넘긴 사유 값과 로그의 사유가 어긋나 **거기서 막혔다.** 사유만으로는
    /// 애초에 못 좁힌다 — `socket_error` 29 곳, `resource_exhausted` 18 곳이다.
    ///
    /// `attach not admitted` 가 여덟 자리를 한 사유로 뭉치던 것을 자리 이름으로 끝낸 것과 같은
    /// 방식이다(#3577·#3603 → #3610). 전부에 붙이지 않고 **실제로 막힌 경로부터** 붙인다.
    close_site: []const u8 = "-",
    /// 그 자리를 만든 **오류 이름**. 이름만으로 못 좁히는 자리가 있다(§beginCloseAtErr).
    close_error: []const u8 = "-",
    close_after_flush: ?CloseReason = null,
    pending_upgrade: ?u128 = null,
    upgrade_gate_closed: bool = false,
    upgrade_ops: ?upgrade_wire.Ops,
    admission_gate: ?*upgrade.AdmissionGate,
    armed_upgrade: ?u128 = null,
    destroyed: bool = false,
    created_ns: u64,
    last_activity_ns: u64,
    admin_request_deadline_at_ns: ?u64 = null,
    upgrade_preflight: ?OwnerUpgradePreflight = null,
    pressure_reclaim: ?OwnerPressureReclaim = null,
    controller_transition: ?OwnerControllerTransition = null,
    resize: ?OwnerResize = null,
    sync_fail_once: bool = false,
    control_admission_fail_once: bool = false,
    producer_streams: []u64 = &.{},
    producer_sweep_cursor: usize = 0,
    producer_observation_epoch_ns: u64 = 0,
    pressure_reclaim_available: bool = false,
    projection_global_unavailable: bool = false,
    process_identity: ?process_seal_service.ReadyIdentity = null,
    image_channel: ?OwnerImageChannel = null,
    /// 입양된 이미지 채널 fd(이미지 채널 §3.5). -1 이면 이 연결에 이미지 채널이 없다.
    image_fd: c.fd_t = -1,
    /// 이미지 채널이 묶인 동안만 있다. 연결 종료와 채널 상실이 `releaseAll` 을 정확히 한 번 부른다(§4.3).
    image_ledger: ?image_segment_ledger.Ledger = null,
    /// 소켓은 메시지 경계를 지키지 않는다 — 지난 읽기 끝에 남은 release 반쪽.
    image_rx: [image_channel_wire.release_len]u8 = undefined,
    image_rx_len: usize = 0,
    /// 이 연결 자신이 hello{role:"image_channel"} 을 보낸 보조 연결이면 그 token. 턴이 끝난 뒤 owner 가 꺼내 입양한다.
    image_channel_bind: ?u128 = null,
    /// 용량 사건이 이미지를 미룬 stream 을 깨웠다 — owner 가 꺼내 이 연결의 producer 를 바로 예약한다(§3.5·§5).
    image_capacity_wake: bool = false,
    /// 「전송 불가」 진단을 이미 적은 (stream, image, generation)(§4.4).
    untransmittable_memo: image_segment_ledger.UntransmittableMemo = .{},

    pub fn create(
        allocator: std.mem.Allocator,
        fd: c.fd_t,
        reactor: *slot_mod.ReactorCore,
        host_id: u128,
        registry_ptr: *registry.TerminalRuntimeRegistry,
        subscriptions: *subscription_identity.Table,
        options: Options,
    ) error{ OutOfMemory, SocketSetupFailed, Full, Exhausted }!*Client {
        errdefer _ = c.close(fd);
        try configureOwnedSocket(fd);
        const admission = reactor.admit() catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Full => error.Full,
            error.Exhausted => error.Exhausted,
        };
        errdefer reactor.closeConnection(admission) catch unreachable;
        const self = allocator.create(Client) catch return error.OutOfMemory;
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .fd = fd,
            .reactor = reactor,
            .admission = admission,
            .parser = framing.FrameParser.init(allocator),
            .connection = server.Connection.initProduct(
                allocator,
                host_id,
                registry_ptr,
                admission.key,
                subscriptions,
            ),
            .upgrade_ops = options.upgrade_ops,
            .admission_gate = options.admission_gate,
            .created_ns = options.now_ns,
            .last_activity_ns = options.now_ns,
            .upgrade_preflight = options.upgrade_preflight,
            .pressure_reclaim = options.pressure_reclaim,
            .controller_transition = options.controller_transition,
            .resize = options.resize,
            .process_identity = options.process_identity,
            .image_channel = options.image_channel,
        };
        if (options.image_channel != null) self.connection.image_channel = .{
            .ctx = self,
            .admit_hello = admitImageChannelHello,
            .issue_token = issueImageChannelToken,
            .prepare_segment = prepareImageSegmentOp,
            .issue_segments = issueImageSegmentsOp,
            .cancel_segments = cancelImageSegmentsOp,
            .issued_through = imageSegmentsIssuedThroughOp,
        };
        self.connection.runtime_ops = options.runtime_ops;
        self.connection.upgrade_ops = options.upgrade_ops;
        self.connection.admin_admission = options.admin_admission;
        if (options.upgrade_preflight != null) {
            self.connection.upgrade_preflight = .{
                .ctx = self,
                .reserve = reserveServerUpgrade,
                .cancel = cancelServerUpgrade,
            };
        }
        self.connection.host_status = options.host_status;
        self.connection.live_host_status = options.live_host_status;
        self.connection.projection_budget = .{
            .ctx = self,
            .prepare = prepareProjectionBudget,
            .commit = commitProjectionBudget,
            .rollback = rollbackProjectionBudget,
            .release = releaseProjectionBudget,
        };
        return self;
    }

    /// Canonical removal path. The protocol connection revokes subscriptions before the reactor
    /// slot releases queued accounting; fd ownership ends exactly once.
    pub fn destroy(self: *Client) void {
        std.debug.assert(!self.destroyed);
        std.debug.assert(self.armed_upgrade == null);
        self.destroyed = true;
        if (self.pending_upgrade) |attempt_id| {
            if (self.upgrade_ops) |ops| ops.cancel_unaccepted(ops.ctx, attempt_id);
            self.pending_upgrade = null;
        }
        if (self.upgrade_gate_closed) {
            self.admission_gate.?.cancelClose();
            self.upgrade_gate_closed = false;
        }
        // 주 연결이 닫히면 채널도 닫는다(§3.2). 입양된 보조 연결은 fd 를 주 연결로 넘겨 -1 이다.
        self.dropImageChannel();
        if (self.fd >= 0) _ = c.close(self.fd);
        self.fd = -1;
        self.connection.deinit();
        self.trackers.deinit(self.allocator);
        self.allocator.free(self.producer_streams);
        self.parser.deinit();
        self.reactor.closeConnection(self.admission) catch unreachable;
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    pub fn wantsWrite(self: *Client) bool {
        const slot = self.reactor.get(self.admission) catch return false;
        return slot.firstPending() != null;
    }

    /// Owner-only pressure selection keeps protocol mutation in Client while exposing only the
    /// stable local stream identity and charged queued bytes.
    pub fn largestScreenPressure(self: *Client) ?ScreenPressureCandidate {
        const slot = self.reactor.get(self.admission) catch return null;
        if (!slot.writeBackpressured() or !slot.writeStallObserved()) return null;
        var result: ?ScreenPressureCandidate = null;
        var iterator = self.trackers.iterator();
        while (iterator.next()) |entry| {
            const state = slot.screenState(entry.value_ptr.*) catch continue;
            if (state != .valid and state != .resync_draining) continue;
            const queued = slot.screenResidentBytes(entry.value_ptr.*) catch continue;
            if (queued == 0) continue;
            if ((slot.preparedBaseBytes(entry.value_ptr.*) catch continue) != 0) continue;
            const retained = slot.retainedBaseBytes(entry.value_ptr.*) catch continue;
            const reclaimable = queued +| retained;
            const written_prefix = slot.trackerHasWrittenPrefix(entry.value_ptr.*) catch continue;
            if (written_prefix and
                (self.connection.streamHasInputCapability(entry.key_ptr.*) or
                    self.connection.hasInputCapability())) continue;
            if (result == null or queued > result.?.queued_bytes or
                (queued == result.?.queued_bytes and
                    (reclaimable > result.?.reclaimable_bytes or
                        (reclaimable == result.?.reclaimable_bytes and
                            entry.key_ptr.* < result.?.stream))))
                result = .{
                    .stream = entry.key_ptr.*,
                    .tracker = entry.value_ptr.*,
                    .queued_bytes = queued,
                    .reclaimable_bytes = reclaimable,
                    .written_prefix = written_prefix,
                };
        }
        return result;
    }

    pub fn acceptsPressureReclaim(self: *Client) bool {
        const slot = self.reactor.get(self.admission) catch return false;
        return !slot.writeBackpressured();
    }

    pub fn noteWriteStalled(self: *Client, now_ns: u64) void {
        const slot = self.reactor.get(self.admission) catch return;
        if (slot.firstPending() != null) slot.notePartial(.write, now_ns, false);
    }

    pub fn noteWriteReady(self: *Client) void {
        const slot = self.reactor.get(self.admission) catch return;
        slot.noteWriteReady();
    }

    /// The owner selected this connection as the global queued-screen pressure offender.
    /// Zero-prefix queues invalidate immediately; a partial screen batch drains to its end marker.
    pub fn reclaimScreenPressure(self: *Client, candidate: ScreenPressureCandidate) bool {
        const tracker = self.trackers.get(candidate.stream) orelse return false;
        if (!std.meta.eql(tracker, candidate.tracker)) return false;
        // owner 가 고른 희생자는 **압력을 겪는 연결이 아니라** 큐가 가장 큰 다른 연결이다
        // (`poll_owner.reclaimScreenPressure` 가 requester 를 후보에서 뺀다). 클라이언트가 하나뿐이면
        // 후보가 없어 이 갈래는 아예 안 탄다 — 나머지 넷과 재현 조건부터 다르다.
        self.invalidateSubscriptionOutput("invalidate_pressure_victim", candidate.stream, tracker);
        return true;
    }

    pub fn hasBufferedReadWork(self: *const Client) bool {
        return !self.isClosing() and self.close_after_flush == null and self.image_channel_bind == null and
            self.parser.bufferState() == .complete_or_error;
    }

    /// 이 보조 연결이 입양을 기다리는 token. owner 가 턴 뒤에 한 번 꺼낸다.
    pub fn takeImageChannelBind(self: *Client) ?u128 {
        const token = self.image_channel_bind;
        self.image_channel_bind = null;
        return token;
    }

    /// 채널 hello 뒤에 이미 와 있는 바이트가 있는가 — parser 에 읽힌 것과 아직 소켓에 있는 것 둘 다. 앱은 `bind_ack` 전에
    /// 아무것도 보내지 않는다. `readReady` 는 bind 에서 읽기를 멈추므로 소켓에 남은 것은 엿봐야 보인다.
    pub fn hasTrailingInbound(self: *const Client) bool {
        if (self.parser.bufferedBytes() != 0) return true;
        var byte: [1]u8 = undefined;
        var interrupted: u8 = 0;
        while (true) {
            const rc = c.recv(self.fd, &byte, byte.len, posix.MSG.PEEK | posix.MSG.DONTWAIT);
            if (rc < 0 and posix.errno(rc) == .INTR and interrupted < 8) {
                interrupted += 1;
                continue;
            }
            return rc > 0;
        }
    }

    /// 입양 때 owner 가 보조 연결의 fd 를 떼어 간다. 이 Client 는 이후 fd 없이 destroy 된다.
    pub fn detachFdForImageChannel(self: *Client) c.fd_t {
        const fd = self.fd;
        self.fd = -1;
        return fd;
    }

    pub fn hasImageChannel(self: *const Client) bool {
        return self.image_fd >= 0;
    }

    /// 입양할 수 있는 주 연결인가 — 닫히는 중이 아니고(응답 뒤 닫기 대기 포함) 아직 채널이 없다.
    pub fn acceptsImageChannel(self: *const Client) bool {
        return !self.isClosing() and self.close_after_flush == null and self.image_fd < 0;
    }

    pub fn imageLedger(self: *Client) ?*image_segment_ledger.Ledger {
        return if (self.image_ledger) |*ledger| ledger else null;
    }

    /// 입양한 채널 fd 를 이 주 연결에 묶고 `bind_ack` 를 보낸다(§3.1). fd 의 NONBLOCK·CLOEXEC·NOSIGPIPE 는 accept 때
    /// `configureOwnedSocket` 이 켠 fd 속성이라 옮겨도 남는다. `bind_ack` 를 다 못 쓰면 채널 상실로 내리고 false.
    pub fn bindImageChannel(self: *Client, fd: c.fd_t, host_budget: *image_segment_ledger.HostBudget) bool {
        std.debug.assert(self.image_fd < 0 and self.image_ledger == null);
        self.image_fd = fd;
        self.image_ledger = image_segment_ledger.Ledger.init(host_budget);
        self.image_rx_len = 0;
        const ack = image_channel_wire.encodeBindAck();
        while (true) {
            const rc = c.send(fd, &ack, ack.len, posix.MSG.DONTWAIT);
            // 신호가 끼면 다시 쓴다 — 논블로킹 송신이라 기다리는 일은 없고, 8 B 를 다음 턴으로 미룰 자리가 없다.
            if (rc < 0 and posix.errno(rc) == .INTR) continue;
            if (rc == ack.len) {
                // 채널이 묶였다 — 그 전에 붙어 「이미지 채널 없음」으로 미룬 stream 을 깨운다.
                self.noteImageCapacity();
                return true;
            }
            self.loseImageChannel(.bind_ack_send);
            return false;
        }
    }

    /// 이미지 fd 의 읽기 턴(§3.5). release 만 읽어 원장을 바꾼다 — admission 게이트가 닫힌 동안에도 owner 가 부른다.
    /// 받은 fd 가 있으면 닫고 채널 상실이다(앱 → host 방향에는 fd 가 없다, §3.3).
    pub fn imageReadReady(self: *Client) void {
        if (self.image_fd < 0) return;
        var buf: [image_channel_read_bytes]u8 = undefined;
        @memcpy(buf[0..self.image_rx_len], self.image_rx[0..self.image_rx_len]);
        var filled = self.image_rx_len;
        var control: [image_channel_control_bytes]u8 align(@alignOf(c.cmsghdr)) = undefined;
        var iov = [_]posix.iovec{.{ .base = buf[filled..].ptr, .len = buf.len - filled }};
        var msg: c.msghdr = .{
            .name = null,
            .namelen = 0,
            .iov = &iov,
            .iovlen = 1,
            .control = &control,
            .controllen = control.len,
            .flags = 0,
        };
        var interruptions: u8 = 0;
        const rc = while (true) {
            const n = c.recvmsg(self.image_fd, &msg, posix.MSG.DONTWAIT);
            if (n < 0 and posix.errno(n) == .INTR and interruptions < 8) {
                interruptions += 1;
                continue;
            }
            break n;
        };
        if (rc < 0) {
            // 신호가 계속 끼면 다음 poll 로 미룬다 — 주 연결의 `readReady` 와 같다. 레벨 트리거라 다시 깨어난다.
            if (posix.errno(rc) == .AGAIN or posix.errno(rc) == .INTR) return;
            return self.loseImageChannel(.socket_error);
        }
        if (msg.controllen != 0 or msg.flags & c.MSG.CTRUNC != 0) {
            closeReceivedFds(control[0..@min(msg.controllen, control.len)]);
            return self.loseImageChannel(.protocol_error);
        }
        if (rc == 0) return self.loseImageChannel(.peer_closed);
        filled += @intCast(rc);
        var split: image_channel_wire.ReleaseSplit = .{ .bytes = buf[0..filled] };
        const ledger = &self.image_ledger.?;
        var returned = false;
        while (split.next() catch return self.loseImageChannel(.protocol_error)) |segment_id| {
            if (ledger.release(segment_id) == .returned) returned = true;
        }
        const rest = split.rest();
        @memcpy(self.image_rx[0..rest.len], rest);
        self.image_rx_len = rest.len;
        // 원장에 자리가 생겼다 — 미룬 이미지가 있는 stream 을 깨운다. 큰 한 장이 우선권을 쥐었으면 원장이 빌 때만 깨운다(§4.4) —
        // 그 전엔 그 이미지도 못 들어가고 다른 이미지는 우선권에 막혀, 깨워 봐야 투영만 헛돈다.
        if (returned and (self.connection.image_priority == null or ledger.count() == 0)) self.noteImageCapacity();
    }

    /// 채널 HUP/ERR(§3.5 — 레벨 트리거라 미루면 계속 깨어난다).
    pub fn imagePeerBroken(self: *Client) void {
        self.loseImageChannel(.peer_closed);
    }

    /// 이미지 채널을 내린다(§3.2). 원장을 전부 반환하고 「이미지 채널 없음」으로 간다. 주 연결은 그대로다.
    pub fn loseImageChannel(self: *Client, reason: ImageChannelLoss) void {
        if (self.image_fd < 0) return;
        noteImageChannelLost(self.admission.index, reason, self.image_ledger.?);
        self.dropImageChannel();
    }

    /// 이미지 하나의 세그먼트를 준비한다(§4.1·§5) — 원장에 먼저 청구하고, 청구가 되면 픽셀을 새 공유 메모리에 담는다.
    /// `snapshot` 은 「같은 이미지의 미반환 세그먼트가 있으면 미룬다」 규칙에서 빠진다(앱이 스냅샷 적용 때 이미지를 비운다).
    /// `pixels` 는 이 호출 동안만 빌린 것이다(투영이 core lock 아래 넘긴다) — 복사는 여기서 끝난다.
    pub fn prepareImageSegment(
        self: *Client,
        stream_id: u64,
        image_id: u32,
        generation: u64,
        pixels: []const u8,
        snapshot: bool,
    ) ImageSegmentPrepare {
        // 「이미지 채널 없음」(협상했지만 묶이지 않음·잃음) — 세그먼트를 만들지 않는다(§3.2).
        const ledger = self.imageLedger() orelse return .deferred;
        const byte_len = std.math.cast(u32, pixels.len) orelse return self.imageUntransmittable(stream_id, image_id, generation, pixels.len);
        // 0 B 이미지는 세그먼트가 없다 — 투영은 청하지 않는다(메타만 `image_ref` 로 간다).
        if (byte_len == 0) return .deferred;
        if (!snapshot and ledger.hasOutstanding(stream_id, image_id)) return .deferred;
        const segment_id = ledger.reserve(stream_id, image_id, generation, byte_len) catch |err| return switch (err) {
            error.TooLargeForHost => self.imageUntransmittable(stream_id, image_id, generation, pixels.len),
            error.EmptySegment, error.ConnectionCountFull, error.ConnectionBytesFull, error.HostBytesFull => .deferred,
        };
        // 공유 메모리를 못 만들면(fd·커널 자원 부족) 청구를 되돌리고 미룬다 — 다음 투영이 다시 청한다.
        const created = image_segment.create(pixels) catch null;
        const segment = created orelse {
            _ = ledger.cancel(segment_id);
            return .deferred;
        };
        return .{ .segment = .{
            .segment_id = segment_id,
            .stream_id = stream_id,
            .image_id = image_id,
            .generation = generation,
            .byte_len = byte_len,
            .fd = segment.fd,
        } };
    }

    /// 「전송 불가」(§4.4) — host 전체 상한·레코드 길이보다 큰 한 장은 무엇이 반환돼도 못 보낸다. 투영은 placement 를 빼고 깨우지
    /// 않는다. (stream, image, generation) 당 진단 한 줄을 남긴다 — 앱 화면에는 그 이미지가 그냥 없으므로 이 줄이 유일한 단서다.
    fn imageUntransmittable(self: *Client, stream_id: u64, image_id: u32, generation: u64, bytes: usize) ImageSegmentPrepare {
        if (self.untransmittable_memo.firstSighting(stream_id, image_id, generation))
            noteImageUntransmittable(self.admission.index, stream_id, image_id, generation, bytes);
        return .untransmittable;
    }

    /// 배치가 큐에 승인된 같은 턴(§4.2): 준비한 세그먼트를 원장에서 발급하고 이미지 채널로 보낸다. 주 소켓의 그 배치 바이트는
    /// 다음 `writeReady` 에 나가므로 「채널이 먼저」다(§3.4). host 는 보낸 fd 를 바로 닫는다. 보내지 못하면 채널 상실로 내린다 —
    /// 그 배치의 `image_ref` 는 앱에서 「세그먼트 없음」이 되어 그 연결이 재접속한다.
    pub fn issueImageSegments(self: *Client, segments: []const PreparedImageSegment) void {
        for (segments) |segment| {
            defer _ = c.close(segment.fd);
            // 그 사이 채널을 잃었으면 `releaseAll` 이 이미 반환했다 — fd 만 닫는다.
            const ledger = self.imageLedger() orelse continue;
            if (!ledger.issue(segment.segment_id)) continue;
            if (!sendImageSegment(self.image_fd, segment)) self.loseImageChannel(.segment_send);
        }
    }

    /// 배치 롤백·투영 실패: 앱이 본 적 없는 세그먼트를 되돌리고 fd 를 닫는다(§4).
    pub fn cancelImageSegments(self: *Client, segments: []const PreparedImageSegment) void {
        for (segments) |segment| {
            if (self.imageLedger()) |ledger| _ = ledger.cancel(segment.segment_id);
            _ = c.close(segment.fd);
        }
    }

    fn noteImageCapacity(self: *Client) void {
        if (self.connection.noteImageCapacity()) self.image_capacity_wake = true;
    }

    /// 용량 사건의 깨움을 꺼낸다 — owner 가 이 연결의 producer 를 예약한다.
    pub fn takeImageCapacityWake(self: *Client) bool {
        defer self.image_capacity_wake = false;
        return self.image_capacity_wake;
    }

    /// 이 연결에서 지금까지 발급한 가장 큰 세그먼트 id(0 = 없음·채널 없음) — 배치의 `image_seg_hwm` 의 바닥값이다.
    pub fn imageSegmentsIssuedThrough(self: *const Client) u64 {
        return if (self.image_ledger) |ledger| ledger.last_issued else 0;
    }

    /// 채널 fd 를 닫고 원장을 반환한다. 연결 종료와 채널 상실이 모두 여기를 지나고, 두 번째 호출은 아무것도 안 한다 —
    /// 그래서 `releaseAll` 은 연결 수명 동안 정확히 한 번이다.
    fn dropImageChannel(self: *Client) void {
        if (self.image_ledger) |*ledger| ledger.releaseAll();
        self.image_ledger = null;
        if (self.image_fd >= 0) _ = c.close(self.image_fd);
        self.image_fd = -1;
        self.image_rx_len = 0;
    }

    pub fn isClosing(self: *const Client) bool {
        return switch (self.state) {
            .open => false,
            .closing => true,
        };
    }

    /// **왜 닫는 중인지.** 열려 있으면 `null`.
    ///
    /// `beginClose` 는 닫힘 사유(`CloseReason`)를 받아 상태에 담는데, 지금까지 그 값은 **밖으로 한
    /// 번도 안 나갔다** — `poll_owner.logClientClosed` 는 자기 바깥 enum 만 찍고, 그중 `client_closing`
    /// 하나가 「host 상태기가 스스로 닫았다」 전부를 뭉갠다.
    ///
    /// 2026-09-08 실측: GUI 가 `client poison: reason=connection_eof` 로 끊겼고 host 는
    /// `reason=client_closing pending_out=21` 을 남겼다. `closed_by_peer` 가 거짓이었으므로 **host 가
    /// 먼저 닫은 것**까지는 갈렸는데, 안쪽 사유 중 무엇인지는 알 수 없었다 — `protocol_error` 와
    /// `resource_exhausted` 와 `partial_timeout` 은 고칠 곳이 완전히 다르다.
    pub fn closeReason(self: *const Client) ?CloseReason {
        return switch (self.state) {
            .open => null,
            .closing => |reason| reason,
        };
    }

    /// `beginClose` 를 부른 지점의 return address. 아직 열려 있으면 0.
    ///
    /// 사후에 `atos -o <바이너리> -l <slide> <ra>` 로 푼다 — 슬라이드를 함께 남기는 이유는
    /// `client.zig` 의 `logPoisonCallSite` 에 적어 둔 것과 같다(앱이 다시 뜨면 ASLR 이 달라져 주소만으론
    /// 못 읽는다).
    pub fn closeReturnAddress(self: *const Client) usize {
        return self.close_ra;
    }

    /// 닫은 «줄»의 이름. 안 붙인 자리는 `"-"` 라, 로그만 보고도 「아직 이름이 없는 자리」와
    /// 「이름이 붙은 그 자리」가 갈린다.
    pub fn closeSite(self: *const Client) []const u8 {
        return self.close_site;
    }

    /// 그 자리를 만든 **오류 이름**. `-` 면 오류가 아니라 판단으로 닫은 것이다(§beginCloseAtErr).
    pub fn closeError(self: *const Client) []const u8 {
        return self.close_error;
    }

    pub fn isUpgradeDraining(self: *const Client) bool {
        return self.pending_upgrade != null or
            (self.close_after_flush orelse return false) == .upgrade_completed;
    }

    /// Kernel HUP/ERR/NVAL after the final readable bytes means no queued reply can be delivered.
    /// Cancel upgrade state if present, then converge through the canonical owner destroy path.
    pub fn peerBroken(self: *Client) void {
        self.failPendingUpgrade(.socket_error);
    }

    pub fn idleForUpgrade(self: *Client) bool {
        return self.upgradeReady(false);
    }

    pub fn requesterReadyForUpgrade(self: *Client) bool {
        return self.upgradeReady(true);
    }

    fn upgradeReady(self: *Client, requester: bool) bool {
        if (self.isClosing() or self.close_after_flush != null or
            self.pending_upgrade != null or self.armed_upgrade != null or
            self.parser.bufferState() != .empty or self.trackers.count() != 0 or
            self.connection.attachmentCount() != 0)
            return false;
        const slot = self.reactor.get(self.admission) catch return false;
        return if (requester)
            slot.requesterReadyForUpgrade()
        else
            slot.idleForUpgrade();
    }

    pub fn socketQuiescentForUpgrade(self: *Client) bool {
        var byte: [1]u8 = undefined;
        var interrupted: u8 = 0;
        while (interrupted < 4) : (interrupted += 1) {
            const rc = c.recv(self.fd, &byte, byte.len, posix.MSG.PEEK | posix.MSG.DONTWAIT);
            if (rc < 0 and posix.errno(rc) == .INTR) continue;
            return rc < 0 and posix.errno(rc) == .AGAIN;
        }
        return false;
    }

    /// Captures and sorts one cadence epoch exactly once. Subsequent owner turns consume one entry
    /// each, avoiding an allocation+sort and whole-stream scan for every subscription.
    pub fn beginProducerSweep(self: *Client, now_ns: u64) usize {
        self.allocator.free(self.producer_streams);
        self.producer_streams = self.connection.localStreams(self.allocator) catch {
            self.producer_streams = &.{};
            self.beginClose(.resource_exhausted);
            return 1;
        };
        std.mem.sort(u64, self.producer_streams, {}, std.sort.asc(u64));
        self.producer_sweep_cursor = 0;
        self.producer_observation_epoch_ns = now_ns;
        if (self.producer_streams.len == 0) return 1;

        const slot = self.reactor.get(self.admission) catch return 1;
        // **왜 아무도 안 뽑혔는지 센다.** 여섯 갈래가 전부 조용히 `continue`·`false` 로 빠지는데,
        // 화면이 멈춘 순간 「고를 것이 없었다」와 「있었는데 다 막혔다」가 로그에서 똑같아 보인다.
        //
        // 2026-09-13 실측: ssh 가 끊긴 뒤 터미널에 입력이 안 먹다가 **pane 을 하나 만들면 나머지가
        // 전부 복구됐다.** 데이터가 사라진 게 아니라 이 sweep 이 멈춰 있다가 `localStreams` 가
        // 바뀌며 다시 돌았다는 뜻이다 — 그런데 무엇이 막고 있었는지는 어디에도 안 남는다.
        var blocked_no_tracker: usize = 0;
        var blocked_state_stale: usize = 0;
        var invalidated_seen: usize = 0;
        var blocked_not_pending: usize = 0;
        var blocked_cannot_attempt: usize = 0;
        var blocked_backoff: usize = 0;
        var chose = false;
        for (self.producer_streams, 0..) |candidate, index| {
            const candidate_tracker = self.trackers.get(candidate) orelse {
                blocked_no_tracker += 1;
                continue;
            };
            const state = slot.screenState(candidate_tracker) catch {
                blocked_state_stale += 1;
                continue;
            };
            if (state != .invalidated) continue;
            invalidated_seen += 1;
            if (!self.connection.resyncPending(candidate)) {
                blocked_not_pending += 1;
                continue;
            }
            if (!(slot.canAttemptResync(candidate_tracker) catch false)) {
                blocked_cannot_attempt += 1;
                continue;
            }
            if (!(slot.resyncAttemptReady(candidate_tracker, now_ns) catch false)) {
                blocked_backoff += 1;
                continue;
            }
            self.producer_sweep_cursor = index;
            chose = true;
            break;
        }
        // **막혔을 때만 낸다.** sweep 은 틱마다 도므로 늘 찍으면 로그를 통째로 먹는다. 무효화된
        // 스트림이 있는데 아무도 못 뽑힌 순간이 곧 「멈춰 있다」이고, 그때만 한 줄이면 족하다.
        if (!chose and invalidated_seen != 0) noteResyncSweepBlocked(.{
            .streams = self.producer_streams.len,
            .invalidated = invalidated_seen,
            .no_tracker = blocked_no_tracker,
            .state_stale = blocked_state_stale,
            .not_pending = blocked_not_pending,
            .cannot_attempt = blocked_cannot_attempt,
            .backoff = blocked_backoff,
        });
        return self.producer_streams.len;
    }

    /// T0b2 owner calls this before canonical destroy, but publishes the host-global completed
    /// marker only after destroy removed fd/subscriptions/slot. A second take cannot re-arm.
    pub fn takeArmedUpgrade(self: *Client) ?ArmedUpgrade {
        const attempt = self.armed_upgrade;
        self.armed_upgrade = null;
        return if (attempt) |attempt_id| .{ .attempt_id = attempt_id } else null;
    }

    /// One nonblocking readable turn. At most 1 MiB and 64 complete frames are admitted.
    pub fn readReady(self: *Client, now_ns: u64) void {
        if (!self.validateProcessIdentity()) return self.beginClose(.protocol_error);
        if (self.isClosing() or self.close_after_flush != null or self.image_channel_bind != null) return;
        var budget: slot_mod.TurnBudget = .{};
        var buf: [64 * 1024]u8 = undefined;
        var interruptions: u8 = 0;

        // Complete buffered frames always drain before another socket read. This bounds inbound
        // resident growth when a previous turn stopped at frame 64.
        if (self.drainBuffered(&budget, now_ns, false)) return;
        while (budget.read_bytes < slot_mod.turn_bytes and
            budget.read_frames < slot_mod.turn_frames)
        {
            if (self.parser.bufferedBytes() >= inbound_resident_cap) {
                noteResidentCap("turn_gate", self.parser.bufferedBytes());
                return self.beginClose(.resource_exhausted);
            }
            const turn_remaining = slot_mod.turn_bytes - budget.read_bytes;
            const resident_remaining = inbound_resident_cap - self.parser.bufferedBytes();
            const rc = c.recv(
                self.fd,
                &buf,
                @min(buf.len, @min(turn_remaining, resident_remaining)),
                posix.MSG.DONTWAIT,
            );
            if (rc < 0) {
                switch (posix.errno(rc)) {
                    .INTR => {
                        interruptions += 1;
                        if (interruptions == 8) return;
                        continue;
                    },
                    .AGAIN => return,
                    else => return self.beginClose(.socket_error),
                }
            }
            if (rc == 0) return self.beginClose(.eof);
            const bytes = buf[0..@intCast(rc)];
            self.last_activity_ns = now_ns;
            if (!budget.allowRead(bytes.len, 0)) return;
            self.parser.pushBounded(bytes, inbound_resident_cap) catch {
                noteResidentCap("push_bounded", self.parser.bufferedBytes() + bytes.len);
                return self.beginClose(.resource_exhausted);
            };
            if (self.drainBuffered(&budget, now_ns, true)) return;
        }
    }

    fn drainBuffered(
        self: *Client,
        budget: *slot_mod.TurnBudget,
        now_ns: u64,
        read_progressed: bool,
    ) bool {
        const slot = self.reactor.get(self.admission) catch {
            self.beginClose(.socket_error);
            return true;
        };
        while (budget.read_frames < slot_mod.turn_frames) {
            const outcome = self.parser.nextOutcome() catch |err| {
                self.beginClose(switch (err) {
                    error.OutOfMemory => .resource_exhausted,
                    else => .protocol_error,
                });
                return true;
            };
            switch (outcome) {
                .incomplete => break,
                .skipped => {
                    slot.clearPartial(.read);
                    _ = budget.allowRead(0, 1);
                },
                .frame => |frame| {
                    slot.clearPartial(.read);
                    _ = budget.allowRead(0, 1);
                    defer frame.deinit(self.allocator);
                    self.dispatch(frame, now_ns) catch {
                        self.beginClose(.resource_exhausted);
                        return true;
                    };
                },
            }
            if (self.close_after_flush != null or self.isClosing() or self.image_channel_bind != null) return true;
        }
        switch (self.parser.bufferState()) {
            .incomplete => slot.notePartial(.read, now_ns, read_progressed),
            .empty, .complete_or_error => slot.clearPartial(.read),
        }
        return budget.read_frames == slot_mod.turn_frames;
    }

    /// One nonblocking writable turn. Queue offsets and global accounting advance only by bytes
    /// accepted by the kernel.
    pub fn writeReady(self: *Client, now_ns: u64) void {
        if (!self.validateProcessIdentity()) return self.beginClose(.protocol_error);
        if (self.isClosing()) return;
        var budget: slot_mod.TurnBudget = .{};
        var interruptions: u8 = 0;
        const slot = self.reactor.get(self.admission) catch return self.beginClose(.socket_error);
        while (slot.firstPending()) |pending| {
            const allowance = slot_mod.turn_bytes - budget.write_bytes;
            if (allowance == 0 or budget.write_frames == slot_mod.turn_frames) return;
            const bytes = pending.bytes[0..@min(pending.bytes.len, allowance)];
            const rc = c.send(self.fd, bytes.ptr, bytes.len, posix.MSG.DONTWAIT);
            if (rc < 0) {
                switch (posix.errno(rc)) {
                    .INTR => {
                        interruptions += 1;
                        if (interruptions == 8) return;
                        continue;
                    },
                    .AGAIN => {
                        slot.notePartial(.write, now_ns, false);
                        return;
                    },
                    else => return self.failPendingUpgrade(.socket_error),
                }
            }
            if (rc == 0) return self.failPendingUpgrade(.socket_error);
            const written: usize = @intCast(rc);
            self.last_activity_ns = now_ns;
            const completed_chunk = written == pending.bytes.len;
            slot.consumeWritten(written) catch return self.failPendingUpgrade(.socket_error);
            self.publishCompletedPressureInvalidations(slot);
            if (self.isClosing()) return;
            _ = budget.allowWrite(written, @intFromBool(completed_chunk));
            if (!completed_chunk) {
                slot.notePartial(.write, now_ns, true);
                return;
            }
            // A new queue head gets its own absolute deadline. If the turn cap leaves it queued,
            // its progress clock starts only on its first write/EAGAIN attempt.
            slot.clearPartial(.write);
        }
        slot.clearPartial(.write);
        if (self.pending_upgrade != null) return self.finalizePendingUpgrade();
        if (self.close_after_flush) |reason| {
            self.close_after_flush = null;
            self.beginClose(reason);
        }
    }

    /// Deadline/lifecycle tick; screen updates are queued and therefore cannot block another fd.
    pub fn tick(self: *Client, now_ns: u64) void {
        if (!self.validateProcessIdentity()) return self.beginClose(.protocol_error);
        if (self.isClosing()) return;
        self.pressure_reclaim_available = true;
        self.projection_global_unavailable = false;
        defer self.pressure_reclaim_available = false;
        const slot = self.reactor.get(self.admission) catch return self.beginClose(.socket_error);
        if (self.pending_upgrade != null and !self.wantsWrite()) {
            self.finalizePendingUpgrade();
            return;
        }
        // `partial_timeout` 은 이 함수 안에서만 **네 자리**가 쓰고, 넷의 고칠 곳이 전부 다르다.
        // 2026-09-15 실측: host 로그 88 개에 이 사유가 126 번 있었는데 전부 `site=-` 였고,
        // `why_ra` 로도 못 갈랐다 — 최적화가 네 자리를 뭉개 줄번호가 `defer` 와
        // `producer_sweep_cursor %` 를 가리켰다. 그래서 숫자 126 은 **사고인지 정상 회수인지조차
        // 말하지 못한다**. 자리 이름을 붙여 그 126 을 읽을 수 있게 만든다.
        if (!self.connection.handshakeComplete() and
            elapsedAtLeast(self.created_ns, now_ns, handshake_deadline_ns))
            return self.beginCloseAt("tick_handshake_deadline", .partial_timeout);
        if (self.admin_request_deadline_at_ns) |deadline|
            if (now_ns >= deadline) return self.beginCloseAt("tick_admin_request_deadline", .partial_timeout);
        // 이 하나만 **정상 회수**다 — 구독이 0 이고 쓸 것도 없는 연결을 거둔다. 나머지 셋과 한
        // 이름으로 묶이면 「사고가 126 번」으로 읽힌다.
        if (self.connection.handshakeComplete() and
            self.connection.attachmentCount() == 0 and
            !self.wantsWrite() and
            elapsedAtLeast(self.last_activity_ns, now_ns, unattached_idle_deadline_ns))
            return self.beginCloseAt("tick_unattached_idle", .partial_timeout);
        // read 와 write 도 가른다. write 정체는 **client 가 안 빼간다**(배압)이고 read 정체는
        // **client 가 안 보낸다**로, 의심할 쪽이 서로 반대다.
        if (slot.partialExpiry(.write, now_ns)) |expiry| {
            notePartialStall(.write, expiry, slot.partialStall(.write, now_ns));
            return self.failPendingUpgradeAt("tick_partial_write_stalled", .partial_timeout);
        }
        if (slot.partialExpiry(.read, now_ns)) |expiry| {
            notePartialStall(.read, expiry, slot.partialStall(.read, now_ns));
            return self.failPendingUpgradeAt("tick_partial_read_stalled", .partial_timeout);
        }
        if (self.close_after_flush != null) return;
        var lease = if (self.admission_gate) |gate| gate.tryEnter() orelse return else null;
        defer if (lease) |*held| held.release();
        slot.beginDispatch() catch |err| return self.beginCloseAtErr("tick_begin_dispatch", @errorName(err), .resource_exhausted);
        defer slot.endDispatch() catch unreachable;
        self.connection.expireCatchups(now_ns);
        if (self.producer_streams.len == 0 and self.trackers.count() != 0)
            _ = self.beginProducerSweep(now_ns);
        if (self.producer_streams.len == 0) return;
        // Exactly one captured producer candidate per owner turn. Missing trackers mean the
        // subscription detached after the cadence snapshot and are skipped without harming peers.
        const stream = self.producer_streams[
            self.producer_sweep_cursor % self.producer_streams.len
        ];
        self.producer_sweep_cursor =
            (self.producer_sweep_cursor + 1) % self.producer_streams.len;
        const tracker = self.trackers.get(stream) orelse return;
        if (self.connection.runtimeMissing(stream)) {
            self.notifyEndedAndRemoveTracker(stream);
            return;
        }
        var tracker_state = slot.screenState(tracker) catch
            return self.beginClose(.socket_error);
        if (!(slot.globalPressureReady(tracker, now_ns) catch
            return self.beginClose(.socket_error))) return;
        const resync_pending = self.connection.resyncPending(stream);
        if (resync_pending and tracker_state == .valid) {
            slot.invalidateAndPurgeScreenTracker(tracker) catch
                return self.beginClose(.socket_error);
            self.connection.markResyncDeliveryPurged(stream);
            tracker_state = .invalidated;
        }
        if (tracker_state == .resync_draining or tracker_state == .drain_current_batch) return;
        if (tracker_state == .invalidated) {
            if (!resync_pending) return;
            if (!(slot.canAttemptResync(tracker) catch
                return self.beginClose(.socket_error))) return;
            if (!(slot.beginResyncAttempt(tracker, now_ns) catch
                return self.beginClose(.socket_error))) return;
        }
        var maybe_output = self.connection.collectOutputForLocalStreamAtEpoch(
            stream,
            now_ns,
            self.producer_observation_epoch_ns,
        ) catch |err| {
            switch (err) {
                error.ProjectionBudgetUnavailable => {
                    if (self.projection_global_unavailable) {
                        slot.deferGlobalPressure(tracker, now_ns) catch
                            return self.beginClose(.socket_error);
                    } else if (tracker_state == .valid) {
                        self.invalidateSubscriptionOutput("invalidate_projection_budget", stream, tracker);
                    }
                    return;
                },
                error.OutOfMemory => {
                    // **한 겹 더 있다.** `site=tick_collect_oom` 까지 오면 「출력을 모으다 접혔다」
                    // 는 알지만, 그 안에서 스물넷이 다시 `OutOfMemory` 하나로 접힌다. 진짜 할당
                    // 실패와 원격 ops 오류가 같은 이름으로 나오므로 `resource_exhausted` 가
                    // 「메모리가 모자랐다」는 뜻이 아닐 수 있다 — 닫기 «전» 에 그 자리를 남긴다.
                    noteCollectFailure();
                    self.beginCloseAt("tick_collect_oom", .resource_exhausted);
                    return;
                },
                error.StreamFrontierDiverged => {
                    // **스트림 하나의 실패다 — 연결을 닫지 않는다.** 예전에는 이것도 `OutOfMemory` 로 접혀
                    // 연결 전체가 닫혔고, 한 탭의 어긋남이 그 창의 탭 전부(2026-09-28, 16 개)를 끊었다. 전송은
                    // 멀쩡하고 `collectOutput` 이 준비물을 되돌렸으므로, 그 스트림만 무효화해 클라이언트가
                    // `runtime.resync` 로 새 스냅샷을 받게 한다 — 예산 부족(`invalidate_projection_budget`)·
                    // prepared attach 가 이미 타는 복구 경로다. 숫자는 닫힘과 같은 줄로 남긴다.
                    noteCollectFailure();
                    if (tracker_state == .valid) {
                        noteStreamFrontierResync(stream);
                        self.invalidateSubscriptionOutput("invalidate_frontier_mismatch", stream, tracker);
                        return;
                    }
                    // resync 스냅샷 **자체**가 어긋났다(`.invalidated` 에서 resync 를 시도하던 중). 스냅샷으로도
                    // 못 맞추는 스트림을 다시 무효화하면 같은 자리를 돈다 — 무한 재시도 대신 예전처럼 닫는다.
                    self.beginCloseAt("tick_frontier_resync_failed", .resource_exhausted);
                    return;
                },
            }
        };
        // Producer validation/revision terminals happen without an inbound peer frame. The
        // Connection marks itself closed after rolling back its projection; mirror that terminal
        // into the readiness owner immediately so poll_owner destroys the fd and all attachment
        // authority instead of treating `null` as an idle cadence forever.
        if (self.connection.isClosed())
            return self.beginCloseAt("tick_connection_self_closed", .resource_exhausted);
        if (maybe_output) |*output| {
            const prepared_catchup = if (output.prepared_catchup) |*prepared| blk: {
                const identity = self.process_identity orelse {
                    output.rollback(&self.connection);
                    return self.beginClose(.protocol_error);
                };
                if (!prepared.bindFinal(
                    identity.pid,
                    identity.process_nonce,
                    @intFromPtr(self),
                    self.admission.key,
                    @intCast(std.Thread.getCurrentId()),
                )) {
                    output.rollback(&self.connection);
                    return self.beginClose(.protocol_error);
                }
                break :blk prepared;
            } else null;
            switch (self.tryAdoptSubscriptionTurn(stream, output.takeFrames(), prepared_catchup)) {
                .admitted => output.commit(&self.connection),
                .deferred_global_pressure => {
                    output.rollback(&self.connection);
                    slot.deferGlobalPressure(tracker, now_ns) catch
                        return self.beginClose(.socket_error);
                },
                .deferred_resync => {
                    output.rollback(&self.connection);
                    slot.deferResyncAttempt(tracker, now_ns) catch
                        return self.beginClose(.socket_error);
                },
                .rejected => {
                    output.rollback(&self.connection);
                    if (!self.isClosing()) {
                        // 거부 사유(`adoption_reject_*`)를 이 무효화의 원인으로 한 줄에 싣는다.
                        turn_reject_detail_pending = true;
                        self.invalidateSubscriptionOutput("invalidate_turn_rejected", stream, tracker);
                    }
                },
            }
            if (self.isClosing()) return;
        } else if (!self.connection.hasLocalStream(stream)) {
            self.notifyEndedAndRemoveTracker(stream);
        }
        return;
    }

    fn notifyEndedAndRemoveTracker(self: *Client, stream: u64) void {
        if (!self.connection.supportsRuntimeEnded()) {
            self.connection.convergeEndedStream(stream);
            self.removeEndedTracker(stream);
            return;
        }
        const frame = self.connection.runtimeEndedFrame(stream) catch {
            self.connection.convergeEndedStream(stream);
            self.removeEndedTracker(stream);
            return self.beginClose(.resource_exhausted);
        };
        self.adoptControl(frame) catch return self.beginClose(.resource_exhausted);
        self.connection.convergeEndedStream(stream);
        self.removeEndedTracker(stream);
    }

    /// RuntimeNotFound is a stream lifecycle transition, not a transport failure. Purge its queued
    /// prefix and accounting without allocating, while preserving the shared client connection.
    fn removeEndedTracker(self: *Client, stream: u64) void {
        const tracker = self.trackers.fetchRemove(stream) orelse return;
        const slot = self.reactor.get(self.admission) catch
            return self.beginClose(.socket_error);
        slot.purgeAndDestroyScreenTracker(tracker.value) catch
            return self.beginClose(.socket_error);
        slot.detachStream() catch return self.beginClose(.socket_error);
    }

    fn tryAdoptSubscriptionTurn(
        self: *Client,
        stream: subscription_identity.LocalStreamId,
        frames: [][]u8,
        prepared_catchup: ?*server.PreparedCatchupBatch,
    ) SubscriptionAdoption {
        defer self.allocator.free(frames);
        if (!validateSubscriptionBatch(stream, frames, if (prepared_catchup) |prepared| prepared.barrier else null) or
            !self.validatePreparedCatchup(stream, prepared_catchup))
        {
            for (frames) |bytes| self.allocator.free(bytes);
            notePreparedAttachRejected("batch_validation");
            _ = self.closeAndReject(.protocol_error);
            return .rejected;
        }
        const slot = self.reactor.get(self.admission) catch {
            notePreparedAttachRejected("slot_lookup");
            _ = self.closeAndReject(.socket_error);
            return .rejected;
        };
        const tracker = self.trackers.get(stream) orelse {
            for (frames) |bytes| self.allocator.free(bytes);
            notePreparedAttachRejected("tracker_missing");
            _ = self.closeAndReject(.socket_error);
            return .rejected;
        };
        const state = slot.screenState(tracker) catch {
            for (frames) |bytes| self.allocator.free(bytes);
            notePreparedAttachRejected("screen_state");
            _ = self.closeAndReject(.socket_error);
            return .rejected;
        };
        if (state == .invalidated) {
            var snapshot_start: ?usize = null;
            for (frames, 0..) |bytes, index| {
                const class = server.classifyOutbound(bytes) catch unreachable;
                switch (class) {
                    .control => unreachable,
                    .subscription => |output| {
                        if (output.kind == .delta) {
                            for (frames) |owned| self.allocator.free(owned);
                            notePreparedAttachRejected("delta_while_invalidated");
                            _ = self.closeAndReject(.protocol_error);
                            return .rejected;
                        }
                        if (output.kind == .snapshot and snapshot_start == null)
                            snapshot_start = index;
                    },
                }
            }
            const start = snapshot_start orelse {
                for (frames) |owned| self.allocator.free(owned);
                return .deferred_resync;
            };
            _ = start;
            // Metadata prefix and snapshot chunks share one atomic subscription batch. Keeping
            // their original order avoids a valid->draining transition between the two classes.
            slot.enqueueOwnedResyncSnapshot(tracker, frames) catch |err| switch (err) {
                error.SlotLimit, error.GlobalLimit, error.ChunkLimit => return .deferred_resync,
                error.OutOfMemory => {
                    notePreparedAttachRejected("resync_enqueue_oom");
                    _ = self.closeAndReject(.resource_exhausted);
                    return .rejected;
                },
                error.Stale, error.ScreenInvalidated => {
                    notePreparedAttachRejected("resync_stale");
                    _ = self.closeAndReject(.socket_error);
                    return .rejected;
                },
            };
            self.consumePreparedCatchup(prepared_catchup);
            return .admitted;
        }

        slot.enqueueOwnedScreenBatch(tracker, frames) catch |err| {
            if (err == error.GlobalLimit) {
                if (self.pressure_reclaim_available) if (self.pressure_reclaim) |ops| {
                    self.pressure_reclaim_available = false;
                    var total: usize = 0;
                    for (frames) |bytes| total +|= bytes.len;
                    if (ops.reclaim(ops.ctx, self.admission.key, total)) {
                        slot.enqueueOwnedScreenBatch(tracker, frames) catch |retry_err| {
                            for (frames) |bytes| self.allocator.free(bytes);
                            if (retry_err == error.GlobalLimit) return .deferred_global_pressure;
                            notePreparedAttachRejectedErr("reclaim_retry_failed", retry_err, total);
                            return .rejected;
                        };
                        self.consumePreparedCatchup(prepared_catchup);
                        return .admitted;
                    }
                };
                for (frames) |bytes| self.allocator.free(bytes);
                return .deferred_global_pressure;
            }
            var batch_bytes: usize = 0;
            for (frames) |bytes| batch_bytes +|= bytes.len;
            for (frames) |bytes| self.allocator.free(bytes);
            notePreparedAttachRejectedErr("screen_batch_enqueue", err, batch_bytes);
            return .rejected;
        };
        self.consumePreparedCatchup(prepared_catchup);
        return .admitted;
    }

    fn validatePreparedCatchup(
        self: *Client,
        stream: subscription_identity.LocalStreamId,
        maybe_prepared: ?*server.PreparedCatchupBatch,
    ) bool {
        const prepared = maybe_prepared orelse return true;
        const expected = self.process_identity orelse return false;
        const current = readyIdentityOrLog("validatePreparedCatchup") orelse return false;
        if (@intFromPtr(prepared) != prepared.self_addr or prepared.active_raw != 1 or
            prepared.pid != expected.pid or prepared.process_nonce != expected.process_nonce or
            prepared.owner_addr != @intFromPtr(self) or
            !std.meta.eql(prepared.owner_connection, self.admission.key) or
            prepared.owner_thread_id != @as(u64, @intCast(std.Thread.getCurrentId())) or
            !std.meta.eql(current, expected) or !self.connection.runtime_catchup_barrier_v1) return false;
        const sub = self.connection.attachments.get(stream) orelse return false;
        const owner = self.connection.subscription_identity orelse return false;
        const pending = switch (prepared.before) {
            .pending => |pending| pending,
            else => return false,
        };
        if (!std.meta.eql(sub.catchup, prepared.before) or
            !std.meta.eql(prepared.barrier.identity, pending.identity) or
            pending.identity.host_id != self.connection.host_id or
            pending.identity.subscription.value != sub.subscription_id.value or
            pending.identity.runtime_id != sub.runtime_id or
            !std.meta.eql(pending.identity.connection, owner.connection) or
            !registry.Capability.has(
                self.connection.registry.capabilitiesOfSubscription(
                    sub.runtime_id,
                    sub.subscription_id,
                ),
                registry.Capability.observe,
            )) return false;
        var recomputed = prepared.before;
        recomputed.admit(prepared.barrier, prepared.now_ns) catch return false;
        return std.meta.eql(recomputed, prepared.after);
    }

    fn consumePreparedCatchup(
        self: *Client,
        maybe_prepared: ?*server.PreparedCatchupBatch,
    ) void {
        _ = self;
        const prepared = maybe_prepared orelse return;
        // validatePreparedCatchup is the only fallible boundary and runs before queue ownership
        // moves.  Once enqueue succeeds, consuming the exact permit is a no-fail suffix.
        std.debug.assert(prepared.active_raw == 1);
        prepared.active_raw = 0;
    }

    fn closeAndReject(self: *Client, reason: CloseReason) bool {
        self.beginClose(reason);
        return false;
    }

    /// 구독 하나의 밀린 출력을 무효화한다. **`site` 는 호출자가 준다** — 이 함수는 부르는 자리가
    /// 다섯인데 전부 한 이름(`invalidate_purge_tracker`)으로 닫아, 2026-09-15 실측의 6 건이 다섯 중
    /// 무엇이었는지 알 수 없었다. 고칠 곳이 갈래마다 다르다: 제 예산이 모자란 것과, owner 가 남의
    /// 큐를 고른 것과, 첫 화면이 연성 상한을 넘은 것은 서로 다른 문제다.
    ///
    /// `invalidate_slot_lookup` 만 호출자 이름을 안 받는다 — `reactor.get(self.admission)` 은 오직
    /// **자기 admission** 에만 달려 있어 어느 자리에서 불렀든 뜻이 같다(이 연결의 슬롯이 사라졌다).
    fn invalidateSubscriptionOutput(
        self: *Client,
        site: []const u8,
        stream: subscription_identity.LocalStreamId,
        tracker: slot_mod.ScreenTrackerKey,
    ) void {
        const slot = self.reactor.get(self.admission) catch |err|
            return self.beginCloseAtErr("invalidate_slot_lookup", @errorName(err), .socket_error);
        // purge 가 쌓인 바이트를 비우기 «전» 에 잰다 — 그래야 상한 대비 얼마였는지가 남는다.
        noteSubscriptionInvalidated(site, stream, slot.screenResidentBytes(tracker) catch null, slot.pending_bytes);
        const outcome = slot.beginPressureInvalidation(tracker) catch |err|
            return self.beginCloseAtErr(site, @errorName(err), .socket_error);
        if (outcome == .drain_current_batch) return;
        self.publishSubscriptionInvalidation(stream);
    }

    fn publishCompletedPressureInvalidations(self: *Client, slot: *slot_mod.Slot) void {
        var iterator = self.trackers.iterator();
        while (iterator.next()) |entry| {
            const ready = slot.takePressureInvalidationNotice(entry.value_ptr.*) catch |err|
                return self.beginCloseAtErr("invalidate_notice_take", @errorName(err), .socket_error);
            if (ready) {
                self.publishSubscriptionInvalidation(entry.key_ptr.*);
                if (self.isClosing()) return;
            }
        }
    }

    fn publishSubscriptionInvalidation(
        self: *Client,
        stream: subscription_identity.LocalStreamId,
    ) void {
        self.connection.markSubscriptionOutputInvalidated(stream);
        const notice = self.connection.snapshotInvalidatedFrame(stream) catch |err|
            return self.beginCloseAtErr("invalidate_notice_build", @errorName(err), .resource_exhausted);
        self.adoptControl(notice) catch |err|
            return self.beginCloseAtErr("invalidate_notice_adopt", @errorName(err), .resource_exhausted);
    }

    fn dispatch(self: *Client, frame: framing.Frame, now_ns: u64) error{OutOfMemory}!void {
        const slot = self.reactor.get(self.admission) catch return self.beginClose(.socket_error);
        var lease = if (self.admission_gate) |gate| gate.tryEnter() orelse {
            self.beginClose(.admission_closed);
            return;
        } else null;
        defer if (lease) |*held| held.release();
        slot.beginDispatch() catch return self.beginClose(.resource_exhausted);
        defer slot.endDispatch() catch unreachable;

        const was_admin = self.connection.isAdmin();
        if (was_admin) self.admin_request_deadline_at_ns = null;
        const action = try self.connection.handleFrameAt(frame, now_ns);
        if (!was_admin and self.connection.isAdmin())
            self.admin_request_deadline_at_ns = now_ns +| admin_request_deadline_ns;
        switch (action) {
            .reply => |bytes| {
                try self.adoptControl(bytes);
                try self.syncTrackers();
            },
            .reply_and_close => |bytes| {
                try self.adoptControl(bytes);
                try self.syncTrackers();
                self.close_after_flush = .reply_flushed;
            },
            .admin_terminate_accepted => |accepted| {
                self.adoptControl(accepted.bytes) catch return error.OutOfMemory;
                const ops = self.connection.runtime_ops orelse
                    return self.beginClose(.socket_error);
                ops.terminate(ops.ctx, accepted.runtime_id);
                self.close_after_flush = .reply_flushed;
            },
            .upgrade_accepted => |accepted| {
                const ops = self.upgrade_ops orelse {
                    self.allocator.free(accepted.bytes);
                    return self.beginClose(.upgrade_failed);
                };
                const gate = self.admission_gate orelse {
                    ops.cancel_unaccepted(ops.ctx, accepted.attempt_id);
                    self.allocator.free(accepted.bytes);
                    return self.beginClose(.upgrade_failed);
                };
                if (!self.upgrade_gate_closed) {
                    ops.cancel_unaccepted(ops.ctx, accepted.attempt_id);
                    self.allocator.free(accepted.bytes);
                    return self.beginClose(.upgrade_failed);
                }
                self.adoptControl(accepted.bytes) catch {
                    ops.cancel_unaccepted(ops.ctx, accepted.attempt_id);
                    gate.cancelClose();
                    self.upgrade_gate_closed = false;
                    return error.OutOfMemory;
                };
                self.pending_upgrade = accepted.attempt_id;
                self.close_after_flush = .upgrade_completed;
            },
            // 상위(`server.Connection`)가 판정한 닫기를 옮긴다. **여기서 이름을 짓지 않는다** —
            // 사유가 같은 자리가 `server.zig` 안에만 서른이라, 옮기는 쪽이 붙일 수 있는 이름은
            // 전부 `dispatch` 하나뿐이다. 2026-09-14 에 `site=-` 를 `why_ra` 로 풀었더니 정확히
            // 그 하나(`Client.dispatch + 7488`)가 나왔고, 거기서 더 못 좁혔다. 자리 이름은
            // **판정한 쪽**이 실어 보내고 이 줄은 그대로 통과시킨다.
            .close => |close| self.beginCloseAtErr(close.site, close.err, switch (close.reason) {
                .protocol_error => .protocol_error,
                .resource_exhausted => .resource_exhausted,
                .internal_error => .internal_error,
            }),
            .none => try self.syncTrackers(),
            .resync_ack => |stream| {
                try self.syncTrackers();
                const tracker = self.trackers.get(stream) orelse
                    return self.beginClose(.socket_error);
                slot.deferResyncAttempt(tracker, now_ns) catch
                    return self.beginClose(.socket_error);
            },
            .frames => |frames| {
                try self.adoptFrameBatch(frames);
            },
            .prepared_attach => |prepared_value| {
                var prepared = prepared_value;
                try self.adoptPreparedAttach(&prepared);
            },
            .prepared_reply => |prepared_value| {
                var prepared = prepared_value;
                self.adoptControl(prepared.reply) catch {
                    prepared.output.rollback(&self.connection);
                    return error.OutOfMemory;
                };
                prepared.output.commit(&self.connection);
            },
            .catchup_arm_requested => |prepared_value| {
                var prepared = prepared_value;
                const identity = self.process_identity orelse
                    return self.beginClose(.protocol_error);
                if (!prepared.bindFinal(identity.pid, identity.process_nonce))
                    return self.beginClose(.protocol_error);
                self.adoptControl(prepared.reply) catch return error.OutOfMemory;
                if (!self.commitCatchupArm(&prepared))
                    return self.beginClose(.protocol_error);
            },
            .prepared_notification => |prepared| {
                self.adoptControl(prepared.reply) catch return error.OutOfMemory;
                const ops = self.connection.runtime_ops orelse
                    return self.beginClose(.socket_error);
                _ = ops.notification_commit(
                    ops.ctx,
                    prepared.runtime_id,
                    prepared.generation,
                );
            },
            .controller_transition_requested => |transition_value| {
                var transition = transition_value;
                const owner = self.controller_transition orelse {
                    self.allocator.free(transition.success_reply);
                    self.allocator.free(transition.stale_reply);
                    self.allocator.free(transition.exhausted_reply);
                    if (transition.revocation) |revocation|
                        self.allocator.free(revocation.frame);
                    self.connection.discardPreparedControllerTransition(
                        &transition.prepared,
                    );
                    return self.beginClose(.resource_exhausted);
                };
                if (!owner.apply(owner.ctx, self, transition))
                    return self.beginClose(.resource_exhausted);
            },
            .resize_requested => |resize_value| {
                var resize = resize_value;
                const owner = self.resize orelse {
                    self.connection.discardPreparedResize(&resize);
                    return self.beginClose(.resource_exhausted);
                };
                if (!owner.apply(owner.ctx, self, resize))
                    return self.beginClose(.resource_exhausted);
            },
            // 입양은 owner 가 턴 뒤에 한다(§3.1). 여기서는 token 만 맡기고 읽기를 멈춘다.
            .image_channel_bind => |token| self.image_channel_bind = token,
            .image_channel_abandon => |bytes| {
                try self.adoptControl(bytes);
                if (self.image_channel) |owner| owner.drop_tokens(owner.ctx, self);
                self.loseImageChannel(.abandoned);
            },
        }
    }

    fn adoptPreparedAttach(
        self: *Client,
        prepared: *server.Action.PreparedAttach,
    ) error{OutOfMemory}!void {
        const stream = prepared.output.stream;
        self.syncTrackers() catch {
            self.allocator.free(prepared.reply);
            prepared.output.rollback(&self.connection);
            self.connection.rollbackPreparedAttach(stream);
            return error.OutOfMemory;
        };
        self.adoptControl(prepared.reply) catch {
            prepared.output.rollback(&self.connection);
            self.connection.rollbackPreparedAttach(stream);
            return error.OutOfMemory;
        };
        const frame_count = prepared.output.frames.len;
        const adopted = self.tryAdoptSubscriptionTurn(
            stream,
            prepared.output.takeFrames(),
            null,
        );
        if (adopted != .admitted) {
            noteAttachAdoption(adopted, frame_count);
            prepared.output.rollback(&self.connection);
            // **여기서 연결을 닫으면 그 세션은 영영 못 붙는다.** 평상시 턴은 똑같은 결과를 받고도
            // 스트림을 무효화해 클라이언트에게 `snapshot.invalidated` 를 알리고, 클라이언트가
            // `runtime.resync` 로 되물어 `resync_batch_bytes`(17 MiB) 차선으로 전체 스냅샷을 받는다.
            // prepared attach 만 그 복구를 통째로 건너뛰고 `resource_exhausted` 로 닫았다.
            //
            // 그래서 첫 화면이 연성 상한(`screen_soft_bytes`, 8 MiB)을 넘는 세션은 고리에 갇힌다:
            // 붙을 때마다 트래커가 `.valid` 로 새로 나 8 MiB 차선만 타고, 같은 자리에서 무효화되고,
            // 연결이 끊긴다. 17 MiB 차선은 `.invalidated` 에서만 열리므로 **영영 닿지 못한다**.
            // (실측 2026-09-12: 터미널 브라우저 세션이 이 고리에 갇혀, 누를 때마다 GUI 가 끊겼다.)
            //
            // 전송 자체가 깨진 게 아니므로 닫을 이유가 없다. attach 를 되돌리는 대신 **스트림을
            // 살려 둔 채 무효화**해, 평상시 경로와 같은 복구를 받게 한다. 되돌리면 구동부가 훑는
            // `localStreams` 에서 빠져 재동기화를 돌릴 주체가 사라진다.
            const tracker = self.trackers.get(stream) orelse {
                self.connection.rollbackPreparedAttach(stream);
                return self.beginClose(.resource_exhausted);
            };
            self.invalidateSubscriptionOutput("invalidate_prepared_attach", stream, tracker);
            // 복구 통지조차 못 넣어 결국 닫히는 경우가 있다 — 슬롯이 청크로 가득 차면
            // `snapshotInvalidatedFrame` 도 자리를 못 얻는다. 그때는 되살릴 스트림이 아니라 닫히는
            // 연결이므로 attach 를 남기면 **매달린 attachment** 가 된다. 옛 동작으로 돌아간다.
            if (self.isClosing()) self.connection.rollbackPreparedAttach(stream);
            return;
        }
        prepared.output.commit(&self.connection);
    }

    fn adoptFrameBatch(self: *Client, frames: [][]u8) error{OutOfMemory}!void {
        defer self.allocator.free(frames);
        if (frames.len == 0) return;
        var remaining_start: usize = 0;
        errdefer for (frames[remaining_start..]) |bytes| self.allocator.free(bytes);
        try self.syncTrackers();
        remaining_start = 1;
        try self.adoptControl(frames[0]);
        if (frames.len == 1) return;
        const class = server.classifyOutbound(frames[1]) catch {
            for (frames[1..]) |bytes| self.allocator.free(bytes);
            remaining_start = frames.len;
            return error.OutOfMemory;
        };
        const stream = switch (class) {
            .control => {
                for (frames[1..]) |bytes| self.allocator.free(bytes);
                remaining_start = frames.len;
                return error.OutOfMemory;
            },
            .subscription => |output| blk: {
                if (output.kind != .snapshot) {
                    for (frames[1..]) |bytes| self.allocator.free(bytes);
                    remaining_start = frames.len;
                    return error.OutOfMemory;
                }
                break :blk output.stream;
            },
        };
        if (!validateSubscriptionBatch(stream, frames[1..], null)) {
            for (frames[1..]) |bytes| self.allocator.free(bytes);
            remaining_start = frames.len;
            return error.OutOfMemory;
        }
        const slot = self.reactor.get(self.admission) catch {
            for (frames[1..]) |bytes| self.allocator.free(bytes);
            remaining_start = frames.len;
            return self.beginClose(.socket_error);
        };
        const tracker = self.trackers.get(stream) orelse {
            for (frames[1..]) |bytes| self.allocator.free(bytes);
            remaining_start = frames.len;
            return self.beginClose(.socket_error);
        };
        slot.invalidateScreen(tracker) catch {
            for (frames[1..]) |bytes| self.allocator.free(bytes);
            remaining_start = frames.len;
            return self.beginClose(.socket_error);
        };
        remaining_start = frames.len;
        slot.enqueueOwnedResyncSnapshot(tracker, frames[1..]) catch {
            // Attach bootstrap has no RemoteRuntime pump yet to acknowledge invalidation. Fail the
            // connection so the controller lease is revoked instead of leaving readSnapshot hung.
            self.beginClose(.resource_exhausted);
        };
    }

    fn syncTrackers(self: *Client) error{OutOfMemory}!void {
        if (self.sync_fail_once) {
            self.sync_fail_once = false;
            return error.OutOfMemory;
        }
        const slot = self.reactor.get(self.admission) catch
            return self.beginClose(.socket_error);
        const streams = try self.connection.localStreams(self.allocator);
        defer self.allocator.free(streams);
        var removed: [slot_mod.max_screen_trackers_per_slot]u64 = undefined;
        var removed_len: usize = 0;
        var it = self.trackers.keyIterator();
        while (it.next()) |tracked| {
            var live = false;
            for (streams) |stream| {
                if (stream == tracked.*) {
                    live = true;
                    break;
                }
            }
            if (!live) {
                removed[removed_len] = tracked.*;
                removed_len += 1;
            }
        }
        for (removed[0..removed_len]) |stream| {
            const tracker = self.trackers.fetchRemove(stream).?.value;
            slot.purgeAndDestroyScreenTracker(tracker) catch
                return self.beginClose(.socket_error);
            slot.detachStream() catch return self.beginClose(.socket_error);
        }
        for (streams) |stream| {
            if (self.trackers.contains(stream)) continue;
            _ = try self.ensureTracker(stream);
        }
    }

    pub fn screenTracker(self: *const Client, stream: u64) ?slot_mod.ScreenTrackerKey {
        return self.trackers.get(stream);
    }

    fn ensureTracker(
        self: *Client,
        stream: subscription_identity.LocalStreamId,
    ) error{OutOfMemory}!slot_mod.ScreenTrackerKey {
        if (self.trackers.get(stream)) |tracker| return tracker;
        const slot = self.reactor.get(self.admission) catch return error.OutOfMemory;
        const tracker = slot.createScreenTracker() catch return error.OutOfMemory;
        errdefer slot.destroyScreenTracker(tracker) catch unreachable;
        self.trackers.put(self.allocator, stream, tracker) catch
            return error.OutOfMemory;
        slot.attachStream() catch {
            _ = self.trackers.remove(stream);
            return error.OutOfMemory;
        };
        return tracker;
    }

    fn prepareProjectionBudget(
        ctx: *anyopaque,
        stream: subscription_identity.LocalStreamId,
        upper_bound: usize,
    ) ?slot_mod.BaseReservation {
        const self: *Client = @ptrCast(@alignCast(ctx));
        const tracker = self.ensureTracker(stream) catch return null;
        const slot = self.reactor.get(self.admission) catch return null;
        return slot.reserveBaseUpdate(tracker, upper_bound) catch |err| {
            if (err != error.GlobalLimit) return null;
            if ((slot.screenState(tracker) catch return null) != .valid) {
                self.projection_global_unavailable = true;
                return null;
            }
            if (!self.pressure_reclaim_available) {
                self.projection_global_unavailable = true;
                return null;
            }
            const ops = self.pressure_reclaim orelse {
                self.projection_global_unavailable = true;
                return null;
            };
            self.pressure_reclaim_available = false;
            if (!ops.reclaim(ops.ctx, self.admission.key, upper_bound)) {
                self.projection_global_unavailable = true;
                return null;
            }
            return slot.reserveBaseUpdate(tracker, upper_bound) catch |retry_err| {
                if (retry_err == error.GlobalLimit)
                    self.projection_global_unavailable = true;
                return null;
            };
        };
    }

    fn commitProjectionBudget(
        ctx: *anyopaque,
        reservation: slot_mod.BaseReservation,
        actual: usize,
    ) void {
        const self: *Client = @ptrCast(@alignCast(ctx));
        const slot = self.reactor.get(self.admission) catch unreachable;
        slot.commitBaseUpdate(reservation, actual) catch unreachable;
    }

    fn rollbackProjectionBudget(
        ctx: *anyopaque,
        reservation: slot_mod.BaseReservation,
    ) void {
        const self: *Client = @ptrCast(@alignCast(ctx));
        const slot = self.reactor.get(self.admission) catch unreachable;
        slot.rollbackBaseUpdate(reservation) catch unreachable;
    }

    fn releaseProjectionBudget(
        ctx: *anyopaque,
        stream: subscription_identity.LocalStreamId,
    ) void {
        const self: *Client = @ptrCast(@alignCast(ctx));
        const tracker = self.trackers.get(stream) orelse return;
        const slot = self.reactor.get(self.admission) catch unreachable;
        slot.releaseBaseState(tracker) catch unreachable;
    }

    /// 봉인을 읽지 못하면 **말하고** 실패한다.
    ///
    /// 세 검증자(`validateProcessIdentity`·`validatePreparedCatchup`·`commitCatchupArm`)가 모두 이걸
    /// `catch return false` 로 삼켰다. 그 거짓은 호출부에서 `beginClose(.protocol_error)` 가 되는데,
    /// 「봉인을 잠깐 못 읽었다」와 「상대가 정말 다른 프로세스다」가 같은 사유·같은 줄로 합쳐져
    /// `why_ra` 로도 안 갈렸다. 둘은 고칠 곳이 다르다.
    ///
    /// `where` 는 어느 검증자가 물었는지다 — 셋이 같은 문구를 쓰면 다시 합쳐진다.
    fn readyIdentityOrLog(where: []const u8) ?process_seal_service.ReadyIdentity {
        return process_seal_service.currentReadyIdentity() catch |err| {
            if (!builtin.is_test)
                std.log.warn(
                    "session host: process identity unreadable — treating as protocol_error: where={s} error={s}",
                    .{ where, @errorName(err) },
                );
            return null;
        };
    }

    /// 거짓을 돌려주면 호출부가 곧바로 `beginClose(.protocol_error)` 한다. 그런데 거짓이 되는 길이
    /// **둘**이고 — 봉인을 읽지 못한 것과 실제로 신원이 달라진 것 — 호출부가 셋이라, `why_ra` 로도
    /// 그 둘은 안 갈린다. 여기서 갈라 둔다.
    ///
    /// 둘은 고칠 곳이 다르다. 앞은 `process_seal_service` 가 잠깐 답을 못 준 것이고, 뒤는 상대가 정말
    /// 다른 프로세스가 된 것이다.
    fn validateProcessIdentity(self: *const Client) bool {
        const expected = self.process_identity orelse return true;
        const current = readyIdentityOrLog("validateProcessIdentity") orelse return false;
        if (std.meta.eql(expected, current)) return true;
        if (!builtin.is_test)
            std.log.warn("session host: process identity changed — closing as protocol_error", .{});
        return false;
    }

    fn commitCatchupArm(
        self: *Client,
        prepared: *server.Action.PreparedCatchupArm,
    ) bool {
        if (prepared.self_addr != @intFromPtr(prepared) or prepared.active_raw != 1)
            return false;
        const expected_process = self.process_identity orelse return false;
        const current_process = readyIdentityOrLog("commitCatchupArm") orelse return false;
        if (!std.meta.eql(expected_process, current_process) or
            prepared.pid != current_process.pid or
            prepared.process_nonce != current_process.process_nonce or
            !self.connection.runtime_catchup_barrier_v1) return false;
        const owner = self.connection.subscription_identity orelse return false;
        const sub = self.connection.attachments.getPtr(prepared.stream) orelse return false;
        if (!registry.Capability.has(
            self.connection.registry.capabilitiesOfSubscription(
                sub.runtime_id,
                sub.subscription_id,
            ),
            registry.Capability.observe,
        ) or
            prepared.identity.host_id != self.connection.host_id or
            prepared.identity.subscription.value != sub.subscription_id.value or
            prepared.identity.runtime_id != sub.runtime_id or
            !std.meta.eql(prepared.identity.connection, owner.connection) or
            !std.meta.eql(sub.catchup, prepared.before)) return false;
        var recomputed = prepared.before;
        const result = recomputed.arm(
            prepared.identity,
            prepared.now_ns,
            prepared.expires_at_ns,
        );
        if (result != prepared.result or !std.meta.eql(recomputed, prepared.after)) return false;
        sub.catchup = prepared.after;
        prepared.active_raw = 0;
        return true;
    }

    fn adoptControl(self: *Client, bytes: []u8) error{OutOfMemory}!void {
        if (self.control_admission_fail_once) {
            self.control_admission_fail_once = false;
            self.allocator.free(bytes);
            return error.OutOfMemory;
        }
        const slot = self.reactor.get(self.admission) catch return self.beginClose(.socket_error);
        slot.enqueueOwnedControl(bytes) catch {
            self.allocator.free(bytes);
            return error.OutOfMemory;
        };
    }

    fn failPendingUpgrade(self: *Client, reason: CloseReason) void {
        self.failPendingUpgradeAt("-", reason);
    }

    /// 대기 중인 업그레이드를 접고 **자리 이름을 남기며** 닫는다.
    fn failPendingUpgradeAt(self: *Client, site: []const u8, reason: CloseReason) void {
        if (self.pending_upgrade) |attempt_id| {
            if (self.upgrade_ops) |ops| ops.cancel_unaccepted(ops.ctx, attempt_id);
            self.pending_upgrade = null;
        }
        if (self.upgrade_gate_closed) {
            self.admission_gate.?.cancelClose();
            self.upgrade_gate_closed = false;
        }
        self.beginCloseAt(site, reason);
    }

    fn finalizePendingUpgrade(self: *Client) void {
        const attempt_id = self.pending_upgrade orelse return;
        const gate = self.admission_gate orelse
            return self.failPendingUpgrade(.upgrade_failed);
        // Arm records reply-flush linearization only. The typed preclosed coordinator owns the
        // bounded wait for pre-close leases and reader quiesce.
        _ = gate;
        const ops = self.upgrade_ops orelse
            return self.failPendingUpgrade(.upgrade_failed);
        if (ops.arm_accepted(ops.ctx, attempt_id) != .armed)
            return self.failPendingUpgrade(.upgrade_failed);
        self.pending_upgrade = null;
        self.upgrade_gate_closed = false;
        self.armed_upgrade = attempt_id;
        self.beginClose(.upgrade_completed);
    }

    /// `noinline` 인 이유는 `@returnAddress()` 다. 인라인되면 이 함수가 돌려주는 주소는 **닫기로 한
    /// 지점이 아니라 그 위 프레임**이 되어, 사유와 지점이 어긋난 채 로그에 남는다.
    /// 자리 이름을 남기고 닫는다. `beginClose` 는 **첫 호출이 이긴다** — 이름도 같이 이겨야 사유와
    /// 짝이 맞으므로, 이름을 «먼저» 두고 그 안에서 닫는다.
    noinline fn beginCloseAt(self: *Client, site: []const u8, reason: CloseReason) void {
        self.beginCloseAtErr(site, "-", reason);
    }

    /// 자리 이름과 **그 자리를 만든 오류**를 함께 남기고 닫는다.
    ///
    /// 이름만으로 부족한 자리가 있다. `invalidate_purge_tracker` 가 그랬다 —
    /// `invalidateAndPurgeScreenTracker` 는 `error{ Stale, PartialFrame }` 둘로 실패하는데 호출부의
    /// `catch` 가 `|err|` 없이 오류를 버려, 로그는 **어디서**만 말하고 **무엇**은 말하지 못했다.
    /// 고칠 곳이 정반대다: `Stale` 은 트래커 신원(슬롯 재사용) 문제이고, `PartialFrame` 은 소켓에
    /// 절반 쓰인 청크가 있어 지금은 버릴 수 없다는 뜻이라 **기다렸다 버리면 되는** 것이다.
    ///
    /// 2026-09-13 실측: 터미널 브라우저를 여는 순간 이 자리로 연결이 죽어 **세션 23 개가 한꺼번에
    /// detach** 됐다. 둘 중 어느 것이었는지 끝내 알 수 없었다.
    noinline fn beginCloseAtErr(self: *Client, site: []const u8, err_name: []const u8, reason: CloseReason) void {
        if (self.isClosing()) return;
        self.close_site = site;
        self.close_error = err_name;
        self.state = .{ .closing = reason };
        self.close_ra = @returnAddress();
    }

    noinline fn beginClose(self: *Client, reason: CloseReason) void {
        if (self.isClosing()) return;
        self.state = .{ .closing = reason };
        // 사유만으로는 못 좁힌다 — `socket_error` 는 호출부가 29 곳, `resource_exhausted` 는 18 곳이다.
        // `client.zig` 의 poison 로그와 같은 관례로 호출 지점을 함께 남긴다. 슬라이드는 찍는 쪽에서
        // 붙이므로 여기서는 주소만 든다.
        self.close_ra = @returnAddress();
    }
};

fn admitImageChannelHello(ctx: *anyopaque) bool {
    const self: *Client = @ptrCast(@alignCast(ctx));
    const owner = self.image_channel orelse return true;
    return owner.admit_hello(owner.ctx, self);
}

fn issueImageChannelToken(ctx: *anyopaque) ?u128 {
    const self: *Client = @ptrCast(@alignCast(ctx));
    const owner = self.image_channel orelse return null;
    return owner.issue_token(owner.ctx, self);
}

/// 받은 SCM_RIGHTS 의 fd 를 모두 닫는다 — 해석하지 않을 fd 라도 프로세스에 이미 설치됐다(이미지 채널 §10). 잘린
/// 헤더는 원래 길이를 그대로 들고 있으므로 버퍼 끝에서 자른다 — 그래야 보이는 fd 만이라도 닫는다.
fn closeReceivedFds(control: []const u8) void {
    var offset: usize = 0;
    while (offset + @sizeOf(c.cmsghdr) <= control.len) {
        const header = std.mem.bytesToValue(c.cmsghdr, control[offset..][0..@sizeOf(c.cmsghdr)]);
        if (header.len < @sizeOf(c.cmsghdr)) return;
        const end = @min(offset + header.len, control.len);
        if (header.level == c.SOL.SOCKET and header.type == c.SCM.RIGHTS) {
            const data = control[offset + @sizeOf(c.cmsghdr) .. end];
            var i: usize = 0;
            while (i + @sizeOf(c.fd_t) <= data.len) : (i += @sizeOf(c.fd_t))
                _ = c.close(std.mem.bytesToValue(c.fd_t, data[i..][0..@sizeOf(c.fd_t)]));
        }
        offset += std.mem.alignForward(usize, header.len, @sizeOf(u32));
    }
}

fn prepareImageSegmentOp(ctx: *anyopaque, stream_id: u64, image_id: u32, generation: u64, pixels: []const u8, snapshot: bool) ImageSegmentPrepare {
    const client: *Client = @ptrCast(@alignCast(ctx));
    return client.prepareImageSegment(stream_id, image_id, generation, pixels, snapshot);
}

fn issueImageSegmentsOp(ctx: *anyopaque, segments: []const PreparedImageSegment) void {
    const client: *Client = @ptrCast(@alignCast(ctx));
    client.issueImageSegments(segments);
}

fn cancelImageSegmentsOp(ctx: *anyopaque, segments: []const PreparedImageSegment) void {
    const client: *Client = @ptrCast(@alignCast(ctx));
    client.cancelImageSegments(segments);
}

fn imageSegmentsIssuedThroughOp(ctx: *anyopaque) u64 {
    const client: *Client = @ptrCast(@alignCast(ctx));
    return client.imageSegmentsIssuedThrough();
}

/// 세그먼트 메시지 하나를 fd 와 함께 보낸다(§3.3 — 메시지 첫 바이트와 함께 fd 정확히 하나). 전부 보냈으면 true.
fn sendImageSegment(channel_fd: c.fd_t, segment: PreparedImageSegment) bool {
    if (channel_fd < 0) return false;
    const payload = image_channel_wire.encodeSegment(.{
        .segment_id = segment.segment_id,
        .stream_id = segment.stream_id,
        .image_id = segment.image_id,
        .generation = segment.generation,
        .byte_len = segment.byte_len,
    }) catch return false;
    var control: [@sizeOf(c.cmsghdr) + @sizeOf(c.fd_t) + 4]u8 align(@alignOf(c.cmsghdr)) = @splat(0);
    const header: c.cmsghdr = .{
        .len = @intCast(@sizeOf(c.cmsghdr) + @sizeOf(c.fd_t)),
        .level = c.SOL.SOCKET,
        .type = c.SCM.RIGHTS,
    };
    @memcpy(control[0..@sizeOf(c.cmsghdr)], std.mem.asBytes(&header));
    @memcpy(control[@sizeOf(c.cmsghdr)..][0..@sizeOf(c.fd_t)], std.mem.asBytes(&segment.fd));
    var iov = [_]posix.iovec_const{.{ .base = &payload, .len = payload.len }};
    const msg: c.msghdr_const = .{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = 1,
        .control = &control,
        .controllen = @intCast(std.mem.alignForward(usize, @sizeOf(c.cmsghdr) + @sizeOf(c.fd_t), @sizeOf(u32))),
        .flags = 0,
    };
    var interruptions: u8 = 0;
    while (true) {
        const rc = c.sendmsg(channel_fd, &msg, posix.MSG.DONTWAIT);
        // 신호가 끼면 다시 보낸다(주 연결의 `writeReady` 와 같은 상한) — 논블로킹이라 기다리는 일은 없다.
        if (rc < 0 and posix.errno(rc) == .INTR and interruptions < 8) {
            interruptions += 1;
            continue;
        }
        return rc == payload.len;
    }
}

fn noteImageUntransmittable(slot: usize, stream_id: u64, image_id: u32, generation: u64, bytes: usize) void {
    if (builtin.is_test) return;
    host_log.line(
        "session host image untransmittable: slot={d} stream={d} image={d} generation={d} bytes={d} host_cap={d}",
        .{ slot, stream_id, image_id, generation, bytes, image_segment_ledger.image_segment_bytes_per_host },
    );
}

fn noteImageChannelLost(slot: usize, reason: ImageChannelLoss, ledger: image_segment_ledger.Ledger) void {
    if (builtin.is_test) return;
    host_log.line(
        "session host image channel lost: slot={d} reason={s} outstanding={d} ignored_releases={d}",
        .{ slot, @tagName(reason), ledger.count(), ledger.ignored_releases },
    );
}

fn reserveServerUpgrade(ctx: *anyopaque) bool {
    const client: *Client = @ptrCast(@alignCast(ctx));
    const preflight = client.upgrade_preflight orelse return false;
    const gate = client.admission_gate orelse return false;
    if (!gate.close()) return false;
    client.upgrade_gate_closed = true;
    if (preflight.check(preflight.ctx, client)) return true;
    cancelServerUpgrade(ctx);
    return false;
}

fn cancelServerUpgrade(ctx: *anyopaque) void {
    const client: *Client = @ptrCast(@alignCast(ctx));
    if (!client.upgrade_gate_closed) return;
    client.admission_gate.?.cancelClose();
    client.upgrade_gate_closed = false;
}

fn validateSubscriptionBatch(
    expected_stream: subscription_identity.LocalStreamId,
    frames: []const []const u8,
    expected_barrier: ?catchup_barrier_contract.Barrier,
) bool {
    // An ordinary empty delta can advance only the server's diff base and carries no wire frame.
    // Catch-up is different: idle is never evidence, so a pending request must still carry the
    // canonical barrier-only frame.
    if (frames.len == 0) return expected_barrier == null;
    var snapshot_batch: ?bool = null;
    var screen_started = false;
    var barrier_seen = false;
    for (frames, 0..) |bytes, index| {
        if (bytes.len < protocol.header_size) return false;
        const header_bytes: *const [protocol.header_size]u8 = @ptrCast(bytes.ptr);
        const header = protocol.Header.decode(header_bytes) catch return false;
        const class = server.classifyOutbound(bytes) catch return false;
        const output = switch (class) {
            .control => return false,
            .subscription => |subscription| subscription,
        };
        if (output.stream != expected_stream or header.major != protocol.version_major)
            return false;
        switch (output.kind) {
            .event => {
                if (screen_started or header.flags != 0) return false;
            },
            .snapshot, .delta => {
                const is_snapshot = output.kind == .snapshot;
                if (snapshot_batch) |existing| {
                    if (existing != is_snapshot) return false;
                } else snapshot_batch = is_snapshot;
                screen_started = true;
                if (header.flags & ~protocol.Flags.end_stream != 0) return false;
                const ends = protocol.Flags.hasEndStream(header.flags);
                const last_screen_index = frames.len - 1 - @intFromBool(expected_barrier != null);
                if (ends != (index == last_screen_index)) return false;
            },
            .barrier => {
                const expected = expected_barrier orelse return false;
                if (index + 1 != frames.len or header.payload_len != catchup_barrier_contract.payload_size)
                    return false;
                const payload: *const [catchup_barrier_contract.payload_size]u8 =
                    @ptrCast(bytes[protocol.header_size..].ptr);
                const decoded = catchup_barrier_contract.Barrier.decode(payload) catch return false;
                if (!std.meta.eql(decoded, expected)) return false;
                barrier_seen = true;
            },
        }
    }
    if ((expected_barrier != null) != barrier_seen) return false;
    return true;
}

fn elapsedAtLeast(start_ns: u64, now_ns: u64, duration_ns: u64) bool {
    return now_ns >= start_ns and now_ns - start_ns >= duration_ns;
}

pub fn configureOwnedSocket(fd: c.fd_t) error{SocketSetupFailed}!void {
    const descriptor_flags = c.fcntl(fd, c.F.GETFD, @as(c_int, 0));
    if (descriptor_flags < 0 or
        c.fcntl(fd, c.F.SETFD, descriptor_flags | c.FD_CLOEXEC) < 0)
        return error.SocketSetupFailed;
    const flags = c.fcntl(fd, c.F.GETFL, @as(c_int, 0));
    const nonblocking: c_int = @bitCast(posix.O{ .NONBLOCK = true });
    if (flags < 0 or c.fcntl(fd, c.F.SETFL, flags | nonblocking) < 0)
        return error.SocketSetupFailed;
    const one: c_int = 1;
    if (c.setsockopt(
        fd,
        posix.SOL.SOCKET,
        posix.SO.NOSIGPIPE,
        @ptrCast(&one),
        @sizeOf(c_int),
    ) != 0) return error.SocketSetupFailed;
}

const TestUpgradeOwner = struct {
    staged: usize = 0,
    canceled: usize = 0,
    armed: usize = 0,
    attempt_id: u128 = 0,

    fn stage(ctx: *anyopaque, request: upgrade_wire.PrepareRequest) upgrade_wire.PrepareDecision {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.staged += 1;
        self.attempt_id = request.attempt_id;
        return .accepted;
    }
    fn cancel(ctx: *anyopaque, attempt_id: u128) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        std.debug.assert(self.attempt_id == attempt_id);
        self.canceled += 1;
    }
    fn arm(ctx: *anyopaque, attempt_id: u128) upgrade_wire.ArmDecision {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (self.attempt_id != attempt_id) return .conflict;
        self.armed += 1;
        return .armed;
    }
    fn status(_: *anyopaque, _: u128) ?upgrade_wire.AttemptReport {
        return .{ .status = .pending };
    }
    fn ops(self: *@This()) upgrade_wire.Ops {
        return .{
            .ctx = self,
            .probe_prepare = upgrade_wire.requiresPreflight,
            .stage_pending = stage,
            .cancel_unaccepted = cancel,
            .arm_accepted = arm,
            .abort_armed = upgrade_wire.cannotAbortArmed,
            .status = status,
        };
    }
};

fn allowReadyTestUpgrade(_: *anyopaque, requester: *Client) bool {
    return requester.requesterReadyForUpgrade() and requester.socketQuiescentForUpgrade();
}

const test_hello =
    "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"gui\",\"capabilities\":[],\"screen_stream_version\":2}";
const test_upgrade_request =
    \\{"method":"host.upgrade.prepare","params":{"attempt_id":"0000000000000000000000000000aabb","target_path":"/Applications/Maru.app/Contents/MacOS/maru","target_build_id":"sha256:build","target_sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","handoff_reader_min":1,"handoff_reader_max":1}}
;

fn sendTestFrame(fd: c.fd_t, kind: protocol.Kind, request_id: u64, payload: []const u8) !void {
    const wire = try framing.encodeFrame(std.testing.allocator, .{
        .kind = kind,
        .request_id = request_id,
    }, payload);
    defer std.testing.allocator.free(wire);
    var offset: usize = 0;
    while (offset < wire.len) {
        const rc = c.send(fd, wire.ptr + offset, wire.len - offset, 0);
        if (rc <= 0) return error.TestUnexpectedResult;
        offset += @intCast(rc);
    }
}

fn sendTestStreamFrame(
    fd: c.fd_t,
    kind: protocol.Kind,
    stream_id: u64,
    payload: []const u8,
) !void {
    const wire = try framing.encodeFrame(std.testing.allocator, .{
        .kind = kind,
        .stream_id = stream_id,
    }, payload);
    defer std.testing.allocator.free(wire);
    var offset: usize = 0;
    while (offset < wire.len) {
        const rc = c.send(fd, wire.ptr + offset, wire.len - offset, 0);
        if (rc <= 0) return error.TestUnexpectedResult;
        offset += @intCast(rc);
    }
}

fn drainNonblocking(fd: c.fd_t) usize {
    var total: usize = 0;
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const rc = c.recv(fd, &buf, buf.len, posix.MSG.DONTWAIT);
        if (rc <= 0) return total;
        total += @intCast(rc);
    }
}

fn receiveIntoParserNonblocking(fd: c.fd_t, parser: *framing.FrameParser) !usize {
    var total: usize = 0;
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const rc = c.recv(fd, &buf, buf.len, posix.MSG.DONTWAIT);
        if (rc < 0 and posix.errno(rc) == .AGAIN) return total;
        if (rc <= 0) return total;
        const len: usize = @intCast(rc);
        try parser.push(buf[0..len]);
        total += len;
    }
}

test "readiness client socketpair yields on partial input and closes canonically on EOF" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    var fds: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    defer _ = c.close(fds[1]);

    var registry_value = registry.TerminalRuntimeRegistry.init(testing.allocator);
    defer registry_value.deinit();
    var subscriptions = subscription_identity.Table.init(testing.allocator);
    defer subscriptions.deinit();
    const reactor = try slot_mod.ReactorCore.create(testing.allocator);
    defer reactor.destroy();
    const client = try Client.create(
        testing.allocator,
        fds[0],
        reactor,
        1,
        &registry_value,
        &subscriptions,
        .{},
    );
    const stale_admission = client.admission;
    const closed_fd = client.fd;

    const hello = try framing.encodeFrame(testing.allocator, .{ .kind = .hello }, "{\"protocol_min\":2,\"protocol_max\":2,\"client\":\"gui\",\"screen_stream_version\":2}");
    defer testing.allocator.free(hello);
    _ = c.write(fds[1], hello.ptr, 7);
    client.readReady(1);
    try testing.expect(!client.isClosing());
    try testing.expect(!client.wantsWrite());
    _ = c.write(fds[1], hello.ptr + 7, hello.len - 7);
    client.readReady(2);
    try testing.expect(client.wantsWrite());
    client.writeReady(3);
    try testing.expect(!client.wantsWrite());

    _ = c.close(fds[1]);
    fds[1] = -1;
    client.readReady(4);
    try testing.expect(client.isClosing());
    client.destroy();
    try testing.expectEqual(@as(usize, 0), reactor.activeCount());
    try testing.expectEqual(@as(usize, 0), subscriptions.count());
    try testing.expectError(error.Stale, reactor.get(stale_admission));
    try testing.expect(c.fcntl(closed_fd, c.F.GETFD, @as(c_int, 0)) < 0);
}

test "readiness client charges skipped optional frame 65 to the next turn before reading more" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    var fds: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    defer _ = c.close(fds[1]);
    var registry_value = registry.TerminalRuntimeRegistry.init(testing.allocator);
    defer registry_value.deinit();
    var subscriptions = subscription_identity.Table.init(testing.allocator);
    defer subscriptions.deinit();
    const reactor = try slot_mod.ReactorCore.create(testing.allocator);
    defer reactor.destroy();
    const client = try Client.create(
        testing.allocator,
        fds[0],
        reactor,
        2,
        &registry_value,
        &subscriptions,
        .{},
    );
    defer client.destroy();

    const optional = (protocol.Header{
        .kind = @enumFromInt(55_000),
        .flags = protocol.Flags.optional,
    }).encode();
    const hello = try framing.encodeFrame(
        testing.allocator,
        .{ .kind = .hello },
        "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"gui\",\"capabilities\":[],\"screen_stream_version\":2}",
    );
    defer testing.allocator.free(hello);
    const wire = try testing.allocator.alloc(u8, optional.len * 64 + hello.len);
    defer testing.allocator.free(wire);
    for (0..64) |index|
        @memcpy(wire[index * optional.len ..][0..optional.len], &optional);
    @memcpy(wire[optional.len * 64 ..], hello);
    try testing.expectEqual(@as(isize, @intCast(wire.len)), c.send(
        fds[1],
        wire.ptr,
        wire.len,
        posix.MSG.DONTWAIT,
    ));

    client.readReady(1);
    try testing.expect(!client.wantsWrite());
    try testing.expect(client.parser.bufferedBytes() >= hello.len);
    try testing.expect(client.hasBufferedReadWork());
    const slot = try reactor.get(client.admission);
    try testing.expect(!slot.partialExpired(.read, 1 + slot_mod.partial_absolute_deadline_ns));
    client.readReady(2);
    try testing.expect(client.wantsWrite());
}

test "upgrade reply arms only after EAGAIN tail is fully written and marker is taken once" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    var fds: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    defer _ = c.close(fds[1]);
    var registry_value = registry.TerminalRuntimeRegistry.init(testing.allocator);
    defer registry_value.deinit();
    var subscriptions = subscription_identity.Table.init(testing.allocator);
    defer subscriptions.deinit();
    const reactor = try slot_mod.ReactorCore.create(testing.allocator);
    defer reactor.destroy();
    var owner: TestUpgradeOwner = .{};
    var gate = upgrade.AdmissionGate.init(testing.io);
    const client = try Client.create(
        testing.allocator,
        fds[0],
        reactor,
        3,
        &registry_value,
        &subscriptions,
        .{
            .upgrade_ops = owner.ops(),
            .upgrade_preflight = .{ .ctx = &owner, .check = allowReadyTestUpgrade },
            .admission_gate = &gate,
            .host_status = .{ .manifest_capable = true, .upgrade_capable = true },
        },
    );
    defer client.destroy();

    try sendTestFrame(fds[1], .hello, 1, test_hello);
    client.readReady(1);
    client.writeReady(2);
    try testing.expect(drainNonblocking(fds[1]) != 0);

    var filler: [64 * 1024]u8 = [_]u8{0xA5} ** (64 * 1024);
    while (true) {
        const rc = c.send(client.fd, &filler, filler.len, posix.MSG.DONTWAIT);
        if (rc < 0 and posix.errno(rc) == .AGAIN) break;
        if (rc <= 0) return error.TestUnexpectedResult;
    }
    try sendTestFrame(fds[1], .request, 2, test_upgrade_request);
    client.readReady(3);
    try testing.expectEqual(@as(usize, 1), owner.staged);
    client.writeReady(4);
    try testing.expectEqual(@as(usize, 0), owner.armed);
    try testing.expect(client.takeArmedUpgrade() == null);

    try testing.expect(drainNonblocking(fds[1]) != 0);
    client.writeReady(5);
    try testing.expectEqual(@as(usize, 1), owner.armed);
    const armed = client.takeArmedUpgrade().?;
    try testing.expectEqual(@as(u128, 0xAABB), armed.attempt_id);
    try testing.expect(armed.gate_preclosed);
    try testing.expect(client.takeArmedUpgrade() == null);
    try testing.expect(client.isClosing());
    try testing.expectEqual(@as(usize, 0), owner.canceled);
    try testing.expect(!gate.snapshot().open);
}

test "upgrade write after peer close cancels once without SIGPIPE" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    var fds: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    var registry_value = registry.TerminalRuntimeRegistry.init(testing.allocator);
    defer registry_value.deinit();
    var subscriptions = subscription_identity.Table.init(testing.allocator);
    defer subscriptions.deinit();
    const reactor = try slot_mod.ReactorCore.create(testing.allocator);
    defer reactor.destroy();
    var owner: TestUpgradeOwner = .{};
    var gate = upgrade.AdmissionGate.init(testing.io);
    const client = try Client.create(
        testing.allocator,
        fds[0],
        reactor,
        4,
        &registry_value,
        &subscriptions,
        .{
            .upgrade_ops = owner.ops(),
            .upgrade_preflight = .{ .ctx = &owner, .check = allowReadyTestUpgrade },
            .admission_gate = &gate,
            .host_status = .{ .manifest_capable = true, .upgrade_capable = true },
        },
    );

    try sendTestFrame(fds[1], .hello, 1, test_hello);
    client.readReady(1);
    client.writeReady(2);
    _ = drainNonblocking(fds[1]);
    try sendTestFrame(fds[1], .request, 2, test_upgrade_request);
    client.readReady(3);
    _ = c.close(fds[1]);
    fds[1] = -1;
    client.writeReady(4);
    try testing.expect(client.isClosing());
    try testing.expectEqual(@as(usize, 1), owner.canceled);
    try testing.expectEqual(@as(usize, 0), owner.armed);
    try testing.expect(gate.snapshot().open);
    client.destroy();
}

test "silent pre-hello client has an exact bounded handshake deadline" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    var fds: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    defer _ = c.close(fds[1]);
    var registry_value = registry.TerminalRuntimeRegistry.init(testing.allocator);
    defer registry_value.deinit();
    var subscriptions = subscription_identity.Table.init(testing.allocator);
    defer subscriptions.deinit();
    const reactor = try slot_mod.ReactorCore.create(testing.allocator);
    defer reactor.destroy();
    const client = try Client.create(
        testing.allocator,
        fds[0],
        reactor,
        5,
        &registry_value,
        &subscriptions,
        .{ .now_ns = 100 },
    );
    defer client.destroy();
    client.tick(100 + handshake_deadline_ns - 1);
    try testing.expect(!client.isClosing());
    client.tick(100 + handshake_deadline_ns);
    try testing.expect(client.isClosing());
}

test "frame batch sync failure frees every still-owned inner frame" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    var fds: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    defer _ = c.close(fds[1]);
    var registry_value = registry.TerminalRuntimeRegistry.init(testing.allocator);
    defer registry_value.deinit();
    var subscriptions = subscription_identity.Table.init(testing.allocator);
    defer subscriptions.deinit();
    const reactor = try slot_mod.ReactorCore.create(testing.allocator);
    defer reactor.destroy();
    const client = try Client.create(
        testing.allocator,
        fds[0],
        reactor,
        6,
        &registry_value,
        &subscriptions,
        .{},
    );
    defer client.destroy();
    const frames = try testing.allocator.alloc([]u8, 3);
    for (frames, 0..) |*frame, index|
        frame.* = try testing.allocator.dupe(u8, if (index == 0) "a" else "b");
    client.sync_fail_once = true;
    try testing.expectError(error.OutOfMemory, client.adoptFrameBatch(frames));
}

test "product attach admission failure and EOF release retained projection authority" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    var registry_value = registry.TerminalRuntimeRegistry.init(testing.allocator);
    defer registry_value.deinit();
    _ = try registry_value.register(0xAA, 80, 24);
    var subscriptions = subscription_identity.Table.init(testing.allocator);
    defer subscriptions.deinit();
    const reactor = try slot_mod.ReactorCore.create(testing.allocator);
    defer reactor.destroy();
    var runtime_ops: server.FakeRuntimeOps = .{};

    {
        var fds: [2]c_int = undefined;
        try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
        defer _ = c.close(fds[1]);
        const client = try Client.create(
            testing.allocator,
            fds[0],
            reactor,
            61,
            &registry_value,
            &subscriptions,
            .{ .runtime_ops = runtime_ops.ops() },
        );
        try sendTestFrame(
            fds[1],
            .hello,
            1,
            "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"gui\",\"capabilities\":[\"runtime_metadata_v1\"],\"screen_stream_version\":2}",
        );
        client.readReady(1);
        client.control_admission_fail_once = true;
        try sendTestFrame(
            fds[1],
            .request,
            2,
            "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"controller\"}}",
        );
        client.readReady(2);
        try testing.expect(client.isClosing());
        try testing.expectEqual(@as(usize, 0), client.connection.attachmentCount());
        try testing.expectEqual(@as(usize, 0), reactor.budget.prepared_base_bytes);
        try testing.expectEqual(@as(usize, 0), reactor.budget.prepared_reclaim_bytes);
        client.destroy();
        try testing.expectEqual(@as(usize, 0), reactor.budget.resident_bytes);
        try testing.expectEqual(@as(usize, 0), subscriptions.count());
        try testing.expectEqual(@as(usize, 0), registry_value.attachmentCount());
        try testing.expectEqual(
            @as(u64, 0),
            registry_value.get(0xAA).?.controller_generation,
        );
    }

    {
        var fds: [2]c_int = undefined;
        try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
        defer _ = c.close(fds[1]);
        const client = try Client.create(
            testing.allocator,
            fds[0],
            reactor,
            64,
            &registry_value,
            &subscriptions,
            .{ .runtime_ops = runtime_ops.ops() },
        );
        try sendTestFrame(fds[1], .hello, 1, test_hello);
        client.readReady(1);
        try sendTestFrame(
            fds[1],
            .request,
            2,
            "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"observer\"}}",
        );
        client.readReady(2);
        const slot = try reactor.get(client.admission);
        const tracker = client.trackers.get(1).?;
        try testing.expect((try slot.retainedBaseBytes(tracker)) > 0);
        try sendTestFrame(
            fds[1],
            .request,
            3,
            "{\"method\":\"runtime.detach\",\"params\":{\"stream_id\":1}}",
        );
        client.readReady(3);
        try testing.expect(!client.isClosing());
        try testing.expectEqual(@as(usize, 0), client.connection.attachmentCount());
        try testing.expectEqual(@as(usize, 0), client.trackers.count());
        try testing.expectEqual(@as(usize, 0), reactor.budget.prepared_base_bytes);
        try testing.expectEqual(@as(usize, 0), reactor.budget.prepared_reclaim_bytes);
        client.destroy();
        try testing.expectEqual(@as(usize, 0), reactor.budget.resident_bytes);
        try testing.expectEqual(@as(usize, 0), subscriptions.count());
        try testing.expectEqual(@as(usize, 0), registry_value.attachmentCount());
    }

    {
        var fds: [2]c_int = undefined;
        try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
        defer _ = c.close(fds[1]);
        const client = try Client.create(
            testing.allocator,
            fds[0],
            reactor,
            63,
            &registry_value,
            &subscriptions,
            .{ .runtime_ops = runtime_ops.ops() },
        );
        try sendTestFrame(fds[1], .hello, 1, test_hello);
        client.readReady(1);
        const slot = try reactor.get(client.admission);
        try slot.consumeWritten(slot.pending_bytes);
        for (slot.chunk_len..slot_mod.max_chunks_per_slot - 1) |_|
            try slot.enqueueControl("x");
        try sendTestFrame(
            fds[1],
            .request,
            2,
            "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"observer\"}}",
        );
        client.readReady(2);
        try testing.expect(client.isClosing());
        try testing.expectEqual(@as(usize, 0), client.connection.attachmentCount());
        try testing.expectEqual(@as(usize, 0), reactor.budget.prepared_base_bytes);
        try testing.expectEqual(@as(usize, 0), reactor.budget.prepared_reclaim_bytes);
        client.destroy();
        try testing.expectEqual(@as(usize, 0), reactor.budget.resident_bytes);
        try testing.expectEqual(@as(usize, 0), subscriptions.count());
        try testing.expectEqual(@as(usize, 0), registry_value.attachmentCount());
    }

    {
        var fds: [2]c_int = undefined;
        try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
        defer _ = c.close(fds[1]);
        const client = try Client.create(
            testing.allocator,
            fds[0],
            reactor,
            62,
            &registry_value,
            &subscriptions,
            .{ .runtime_ops = runtime_ops.ops() },
        );
        try sendTestFrame(
            fds[1],
            .hello,
            1,
            "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"gui\",\"capabilities\":[\"runtime_metadata_v1\"],\"screen_stream_version\":2}",
        );
        client.readReady(1);
        try sendTestFrame(
            fds[1],
            .request,
            2,
            "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"observer\"}}",
        );
        client.readReady(2);
        const slot = try reactor.get(client.admission);
        const tracker = client.trackers.get(1).?;
        try testing.expect((try slot.retainedBaseBytes(tracker)) > 0);
        try slot.consumeWritten(slot.pending_bytes);
        runtime_ops.observation_version = 1;
        try sendTestFrame(
            fds[1],
            .request,
            3,
            "{\"method\":\"runtime.observation\",\"params\":{\"stream_id\":1}}",
        );
        client.readReady(3);
        try testing.expect(!client.isClosing());
        try testing.expectEqual(@as(usize, 0), try slot.preparedBaseBytes(tracker));
        try testing.expectEqual(@as(usize, 0), reactor.budget.prepared_base_bytes);
        const observed = client.connection.attachments.get(1).?;
        try testing.expectEqual(
            observed.base.?.len,
            try slot.retainedBaseBytes(tracker),
        );
        client.peerBroken();
        try testing.expect(client.isClosing());
        client.destroy();
        try testing.expectEqual(@as(usize, 0), reactor.budget.resident_bytes);
        try testing.expectEqual(@as(usize, 0), reactor.budget.prepared_base_bytes);
        try testing.expectEqual(@as(usize, 0), subscriptions.count());
        try testing.expectEqual(@as(usize, 0), registry_value.attachmentCount());
    }
}

test "CR4a host admission은 control queue 성공 뒤 pending을 게시하고 expiry를 연장하지 않는다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    const allocator = testing.allocator;
    var registry_value = registry.TerminalRuntimeRegistry.init(allocator);
    defer registry_value.deinit();
    _ = try registry_value.register(0xAA, 80, 24);
    var subscriptions = subscription_identity.Table.init(allocator);
    defer subscriptions.deinit();
    const reactor = try slot_mod.ReactorCore.create(allocator);
    defer reactor.destroy();
    var runtime_ops: server.FakeRuntimeOps = .{};
    const process_identity = process_seal_service.currentReadyIdentity() catch |err| switch (err) {
        error.NotReady => ready: {
            const process_pid = process_seal_service.currentProcessId();
            const process_nonce = try process_seal_service.generateProcessNonce();
            process_seal_service.commitReady(try process_seal_service.prepare(process_pid, process_nonce));
            break :ready try process_seal_service.currentReadyIdentity();
        },
        else => return err,
    };
    const nonce = "00112233445566778899aabbccddeeff";
    const request =
        "{\"method\":\"runtime.catchup\",\"params\":{\"stream_id\":1,\"request_nonce\":\"" ++
        nonce ++ "\"}}";
    const expectReply = struct {
        fn contains(fd: c.fd_t, needle: []const u8) !void {
            var parser = framing.FrameParser.init(testing.allocator);
            defer parser.deinit();
            _ = try receiveIntoParserNonblocking(fd, &parser);
            var found = false;
            while (try parser.next()) |frame| {
                defer frame.deinit(testing.allocator);
                if (std.mem.indexOf(u8, frame.payload, needle) != null) found = true;
            }
            try testing.expect(found);
        }
    }.contains;
    const prepareDirect = struct {
        fn one(client: *Client, now_ns: u64, request_id: u64, payload: []const u8) !server.Action.PreparedCatchupArm {
            const wire = try framing.encodeFrame(
                testing.allocator,
                .{ .kind = .request, .request_id = request_id },
                payload,
            );
            defer testing.allocator.free(wire);
            var parser = framing.FrameParser.init(testing.allocator);
            defer parser.deinit();
            try parser.push(wire);
            const frame = (try parser.next()).?;
            defer frame.deinit(testing.allocator);
            const action = try client.connection.handleFrameAt(frame, now_ns);
            if (action != .catchup_arm_requested) return error.TestUnexpectedResult;
            return action.catchup_arm_requested;
        }
    }.one;

    // Capability absence is a product negative: the request gets a typed denial and cannot arm
    // the subscription even though the observer attachment itself is otherwise valid.
    {
        var fds: [2]c_int = undefined;
        try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
        defer _ = c.close(fds[1]);
        const client = try Client.create(
            allocator,
            fds[0],
            reactor,
            0x1234,
            &registry_value,
            &subscriptions,
            .{ .runtime_ops = runtime_ops.ops(), .process_identity = process_identity },
        );
        defer client.destroy();
        try sendTestFrame(
            fds[1],
            .hello,
            1,
            "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"gui\",\"capabilities\":[]}",
        );
        client.readReady(1);
        client.writeReady(1);
        _ = drainNonblocking(fds[1]);
        try sendTestFrame(
            fds[1],
            .request,
            2,
            "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"observer\"}}",
        );
        client.readReady(2);
        client.writeReady(2);
        _ = drainNonblocking(fds[1]);
        try sendTestFrame(fds[1], .request, 3, request);
        client.readReady(3);
        client.writeReady(3);
        try expectReply(fds[1], "unauthorized");
        try testing.expect(client.connection.attachments.get(1).?.catchup == .idle);
    }

    // A mixed-type capabilities array is malformed, not a permissive negotiation surface.
    {
        var fds: [2]c_int = undefined;
        try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
        defer _ = c.close(fds[1]);
        const client = try Client.create(
            allocator,
            fds[0],
            reactor,
            0x1234,
            &registry_value,
            &subscriptions,
            .{ .runtime_ops = runtime_ops.ops(), .process_identity = process_identity },
        );
        try sendTestFrame(
            fds[1],
            .hello,
            1,
            "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"gui\",\"capabilities\":[{},\"runtime_catchup_barrier_v1\"]}",
        );
        client.readReady(1);
        try testing.expect(client.isClosing());
        try testing.expectEqual(@as(usize, 0), client.connection.attachments.count());
        client.destroy();
    }

    {
        var fds: [2]c_int = undefined;
        try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
        defer _ = c.close(fds[1]);
        const client = try Client.create(
            allocator,
            fds[0],
            reactor,
            0x1234,
            &registry_value,
            &subscriptions,
            .{ .runtime_ops = runtime_ops.ops(), .process_identity = process_identity },
        );
        try sendTestFrame(
            fds[1],
            .hello,
            1,
            "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"gui\",\"capabilities\":[\"runtime_catchup_barrier_v1\"]}",
        );
        client.readReady(1);
        client.writeReady(1);
        _ = drainNonblocking(fds[1]);
        try sendTestFrame(
            fds[1],
            .request,
            2,
            "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"observer\"}}",
        );
        client.readReady(2);
        client.writeReady(2);
        _ = drainNonblocking(fds[1]);
        client.control_admission_fail_once = true;
        try sendTestFrame(fds[1], .request, 3, request);
        client.readReady(3);
        try testing.expect(client.isClosing());
        try testing.expect(client.connection.attachments.get(1).?.catchup == .idle);
        client.destroy();
    }

    {
        var fds: [2]c_int = undefined;
        try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
        defer _ = c.close(fds[1]);
        const client = try Client.create(
            allocator,
            fds[0],
            reactor,
            0x1234,
            &registry_value,
            &subscriptions,
            .{ .runtime_ops = runtime_ops.ops(), .process_identity = process_identity },
        );
        defer client.destroy();
        try sendTestFrame(
            fds[1],
            .hello,
            1,
            "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"gui\",\"capabilities\":[\"runtime_catchup_barrier_v1\"]}",
        );
        client.readReady(10);
        client.writeReady(10);
        _ = drainNonblocking(fds[1]);
        try sendTestFrame(
            fds[1],
            .request,
            2,
            "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"observer\"}}",
        );
        client.readReady(11);
        client.writeReady(11);
        _ = drainNonblocking(fds[1]);
        try sendTestFrame(fds[1], .request, 3, request);
        client.readReady(12);
        const pending = client.connection.attachments.get(1).?.catchup.pending;
        try testing.expectEqual(@as(u64, 12 + server.catchup_host_expiry_ns), pending.expires_at_ns);
        client.writeReady(12);
        _ = drainNonblocking(fds[1]);

        // The response queue owner is the only product caller, but this same-module hostile seam
        // proves that its final-address receipt cannot be copied, drifted, or replayed.
        var prepared = try prepareDirect(client, 12, 40, request);
        defer allocator.free(prepared.reply);
        try testing.expect(prepared.bindFinal(process_identity.pid, process_identity.process_nonce));
        const state_before_hostile = client.connection.attachments.get(1).?.catchup;
        var copied = prepared;
        try testing.expect(!client.commitCatchupArm(&copied));
        try testing.expectEqualDeep(state_before_hostile, client.connection.attachments.get(1).?.catchup);
        prepared.pid +%= 1;
        try testing.expect(!client.commitCatchupArm(&prepared));
        try testing.expectEqualDeep(state_before_hostile, client.connection.attachments.get(1).?.catchup);
        prepared.pid -%= 1;
        prepared.process_nonce +%= 1;
        try testing.expect(!client.commitCatchupArm(&prepared));
        try testing.expectEqualDeep(state_before_hostile, client.connection.attachments.get(1).?.catchup);
        prepared.process_nonce -%= 1;
        try testing.expect(client.commitCatchupArm(&prepared));
        try testing.expectEqual(@as(u8, 0), prepared.active_raw);
        try testing.expect(!client.commitCatchupArm(&prepared));
        try testing.expectEqualDeep(state_before_hostile, client.connection.attachments.get(1).?.catchup);

        try sendTestFrame(fds[1], .request, 4, request);
        client.readReady(13);
        try testing.expectEqualDeep(pending, client.connection.attachments.get(1).?.catchup.pending);
        client.writeReady(13);
        try expectReply(fds[1], "idempotent");

        const foreign_request =
            "{\"method\":\"runtime.catchup\",\"params\":{\"stream_id\":1,\"request_nonce\":\"ffeeddccbbaa99887766554433221100\"}}";
        try sendTestFrame(fds[1], .request, 5, foreign_request);
        client.readReady(14);
        try testing.expectEqualDeep(pending, client.connection.attachments.get(1).?.catchup.pending);
        client.writeReady(14);
        try expectReply(fds[1], "busy");

        // Do not run the subscription output tick here: the host frontier slice intentionally
        // turns a live pending row into admitted.  This row isolates response admission and
        // verifies expiry through the request owner itself.
        try testing.expect(client.connection.attachments.get(1).?.catchup == .pending);
        try sendTestFrame(fds[1], .request, 6, request);
        client.readReady(pending.expires_at_ns);
        client.writeReady(pending.expires_at_ns);
        try expectReply(fds[1], "expired");
        try testing.expect(client.connection.attachments.get(1).?.catchup == .terminal);
    }
}

test "CR4a host frontier batch는 screen 뒤 barrier를 admit하고 pending을 exact once 고정한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    const fresh_role = std.c.getenv("MARU_CR4A_HOST_FRONTIER_ROLE") orelse
        return error.SkipZigTest;
    if (!std.mem.eql(u8, std.mem.span(fresh_role), "maru-cr4a-host-frontier-fresh-v1"))
        return error.TestUnexpectedResult;
    var registry_value = registry.TerminalRuntimeRegistry.init(testing.allocator);
    defer registry_value.deinit();
    _ = try registry_value.register(0xAA, 80, 24);
    var subscriptions = subscription_identity.Table.init(testing.allocator);
    defer subscriptions.deinit();
    const reactor = try slot_mod.ReactorCore.create(testing.allocator);
    defer reactor.destroy();
    var runtime_ops: server.FakeRuntimeOps = .{};
    const process_identity = process_seal_service.currentReadyIdentity() catch |err| switch (err) {
        error.NotReady => ready: {
            const pid = process_seal_service.currentProcessId();
            const nonce = try process_seal_service.generateProcessNonce();
            process_seal_service.commitReady(try process_seal_service.prepare(pid, nonce));
            break :ready try process_seal_service.currentReadyIdentity();
        },
        else => return err,
    };
    var fds: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    defer _ = c.close(fds[1]);
    const client = try Client.create(
        testing.allocator,
        fds[0],
        reactor,
        0x1234,
        &registry_value,
        &subscriptions,
        .{ .runtime_ops = runtime_ops.ops(), .process_identity = process_identity },
    );
    defer client.destroy();

    try sendTestFrame(
        fds[1],
        .hello,
        1,
        "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"gui\",\"capabilities\":[\"runtime_catchup_barrier_v1\"]}",
    );
    client.readReady(1);
    client.writeReady(1);
    _ = drainNonblocking(fds[1]);
    try sendTestFrame(
        fds[1],
        .request,
        2,
        "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"observer\"}}",
    );
    client.readReady(2);
    client.writeReady(2);
    _ = drainNonblocking(fds[1]);
    const request_nonce: u128 = 0x00112233445566778899aabbccddeeff;
    try sendTestFrame(
        fds[1],
        .request,
        3,
        "{\"method\":\"runtime.catchup\",\"params\":{\"stream_id\":1,\"request_nonce\":\"00112233445566778899aabbccddeeff\"}}",
    );
    client.readReady(3);
    client.writeReady(3);
    _ = drainNonblocking(fds[1]);
    try testing.expect(client.connection.attachments.get(1).?.catchup == .pending);

    var hostile_output = (try client.connection.collectOutputForLocalStreamAt(1, 4)).?;
    defer hostile_output.rollback(&client.connection);
    const hostile_prepared = &hostile_output.prepared_catchup.?;
    try testing.expect(hostile_prepared.bindFinal(
        process_identity.pid,
        process_identity.process_nonce,
        @intFromPtr(client),
        client.admission.key,
        @intCast(std.Thread.getCurrentId()),
    ));
    const pending_before_hostile = client.connection.attachments.get(1).?.catchup;
    var copied_prepared = hostile_prepared.*;
    try testing.expect(!client.validatePreparedCatchup(1, &copied_prepared));
    try testing.expectEqualDeep(pending_before_hostile, client.connection.attachments.get(1).?.catchup);
    hostile_prepared.pid +%= 1;
    try testing.expect(!client.validatePreparedCatchup(1, hostile_prepared));
    hostile_prepared.pid -%= 1;
    hostile_prepared.process_nonce +%= 1;
    try testing.expect(!client.validatePreparedCatchup(1, hostile_prepared));
    hostile_prepared.process_nonce -%= 1;
    hostile_prepared.owner_addr +%= 1;
    try testing.expect(!client.validatePreparedCatchup(1, hostile_prepared));
    hostile_prepared.owner_addr -%= 1;
    hostile_prepared.owner_connection.slot_generation +%= 1;
    try testing.expect(!client.validatePreparedCatchup(1, hostile_prepared));
    hostile_prepared.owner_connection.slot_generation -%= 1;
    hostile_prepared.owner_thread_id +%= 1;
    try testing.expect(!client.validatePreparedCatchup(1, hostile_prepared));
    hostile_prepared.owner_thread_id -%= 1;
    client.connection.runtime_catchup_barrier_v1 = false;
    try testing.expect(!client.validatePreparedCatchup(1, hostile_prepared));
    client.connection.runtime_catchup_barrier_v1 = true;
    hostile_prepared.barrier.target.sequence +%= 1;
    try testing.expect(!client.validatePreparedCatchup(1, hostile_prepared));
    hostile_prepared.barrier.target.sequence -%= 1;
    const canonical_after = hostile_prepared.after;
    hostile_prepared.after = .idle;
    try testing.expect(!client.validatePreparedCatchup(1, hostile_prepared));
    hostile_prepared.after = canonical_after;
    hostile_output.rollback(&client.connection);
    try testing.expectEqual(@as(u8, 0), hostile_prepared.active_raw);
    try testing.expectEqualDeep(pending_before_hostile, client.connection.attachments.get(1).?.catchup);

    // Prepare with real projection authority, then fill the shared queue budget only after the
    // base reservation exists.  The real queue owner must reject the complete screen+barrier
    // batch without leaving a prefix or committing either frontier or pending state.
    var pressure_output = (try client.connection.collectOutputForLocalStreamAt(1, 4)).?;
    defer pressure_output.rollback(&client.connection);
    const pressure_prepared = &pressure_output.prepared_catchup.?;
    try testing.expect(pressure_prepared.bindFinal(
        process_identity.pid,
        process_identity.process_nonce,
        @intFromPtr(client),
        client.admission.key,
        @intCast(std.Thread.getCurrentId()),
    ));
    const sub_before_pressure = client.connection.attachments.get(1).?;
    const slot = try reactor.get(client.admission);
    const chunk_len_before_pressure = slot.chunk_len;
    const pending_bytes_before_pressure = slot.pending_bytes;
    const resident_before_pressure = slot.resident_bytes;
    const injected_pressure = slot_mod.shared_steady_bytes - reactor.budget.shared_bytes;
    reactor.budget.resident_bytes += injected_pressure;
    reactor.budget.shared_bytes += injected_pressure;
    var pressure_injected = true;
    defer if (pressure_injected) {
        reactor.budget.resident_bytes -= injected_pressure;
        reactor.budget.shared_bytes -= injected_pressure;
    };
    try testing.expectEqual(
        SubscriptionAdoption.deferred_global_pressure,
        client.tryAdoptSubscriptionTurn(1, pressure_output.takeFrames(), pressure_prepared),
    );
    pressure_output.rollback(&client.connection);
    try testing.expectEqual(@as(u8, 0), pressure_prepared.active_raw);
    reactor.budget.resident_bytes -= injected_pressure;
    reactor.budget.shared_bytes -= injected_pressure;
    pressure_injected = false;
    const sub_after_pressure = client.connection.attachments.get(1).?;
    try testing.expectEqualDeep(sub_before_pressure.catchup, sub_after_pressure.catchup);
    try testing.expectEqual(sub_before_pressure.screen_generation, sub_after_pressure.screen_generation);
    try testing.expectEqual(sub_before_pressure.screen_sequence, sub_after_pressure.screen_sequence);
    try testing.expectEqualStrings(sub_before_pressure.base.?, sub_after_pressure.base.?);
    try testing.expectEqual(chunk_len_before_pressure, slot.chunk_len);
    try testing.expectEqual(pending_bytes_before_pressure, slot.pending_bytes);
    try testing.expectEqual(resident_before_pressure, slot.resident_bytes);

    const admitted_at: u64 = 4;
    client.tick(admitted_at);
    try testing.expect(client.connection.attachments.get(1).?.catchup == .admitted);
    client.writeReady(admitted_at);
    var parser = framing.FrameParser.init(testing.allocator);
    defer parser.deinit();
    _ = try receiveIntoParserNonblocking(fds[1], &parser);
    var saw_screen = false;
    var saw_barrier = false;
    while (try parser.next()) |frame| {
        defer frame.deinit(testing.allocator);
        switch (frame.header.kind) {
            .delta_chunk, .snapshot_chunk => {
                try testing.expect(!saw_barrier);
                saw_screen = true;
            },
            .screen_frontier_barrier => {
                try testing.expect(!saw_barrier);
                saw_barrier = true;
                try testing.expectEqual(@as(u64, 1), frame.header.stream_id);
                try testing.expectEqual(@as(usize, catchup_barrier_contract.payload_size), frame.payload.len);
                const payload: *const [catchup_barrier_contract.payload_size]u8 = @ptrCast(frame.payload.ptr);
                const barrier = try catchup_barrier_contract.Barrier.decode(payload);
                try testing.expectEqual(request_nonce, barrier.identity.request_nonce);
                try testing.expectEqualDeep(
                    client.connection.attachments.get(1).?.catchup.admitted.barrier,
                    barrier,
                );
            },
            else => {},
        }
    }
    try testing.expect(saw_screen);
    try testing.expect(saw_barrier);

    const admitted_before_retry = client.connection.attachments.get(1).?.catchup;
    client.tick(admitted_at + 1);
    try testing.expectEqualDeep(admitted_before_retry, client.connection.attachments.get(1).?.catchup);

    // A second subscription with no semantic screen change still needs a host-issued cut.  Idle
    // is never the oracle: the product queue must carry one canonical barrier-only batch.
    runtime_ops.delta_send_len = 0;
    try sendTestFrame(
        fds[1],
        .request,
        4,
        "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"observer\"}}",
    );
    client.readReady(admitted_at + 2);
    client.writeReady(admitted_at + 2);
    _ = drainNonblocking(fds[1]);
    if (client.connection.attachments.get(2) == null) return error.NoChangeAttachMissing;
    try sendTestFrame(
        fds[1],
        .request,
        5,
        "{\"method\":\"runtime.catchup\",\"params\":{\"stream_id\":2,\"request_nonce\":\"102132435465768798a9bacbdcedfe0f\"}}",
    );
    client.readReady(admitted_at + 3);
    client.writeReady(admitted_at + 3);
    _ = drainNonblocking(fds[1]);
    if (client.connection.attachments.get(2).?.catchup != .pending)
        return error.NoChangePendingMissing;
    var idle_output = (try client.connection.collectOutputForLocalStreamAt(2, admitted_at + 4)).?;
    defer idle_output.rollback(&client.connection);
    const idle_prepared = &idle_output.prepared_catchup.?;
    try testing.expect(idle_prepared.bindFinal(
        process_identity.pid,
        process_identity.process_nonce,
        @intFromPtr(client),
        client.admission.key,
        @intCast(std.Thread.getCurrentId()),
    ));
    if (client.tryAdoptSubscriptionTurn(2, idle_output.takeFrames(), idle_prepared) != .admitted)
        return error.NoChangeQueueAdmissionFailed;
    idle_output.commit(&client.connection);
    if (client.connection.attachments.get(2).?.catchup != .admitted)
        return error.NoChangeAdmissionMissing;
    client.writeReady(admitted_at + 5);
    var idle_parser = framing.FrameParser.init(testing.allocator);
    defer idle_parser.deinit();
    _ = try receiveIntoParserNonblocking(fds[1], &idle_parser);
    var idle_frame_count: usize = 0;
    while (try idle_parser.next()) |frame| {
        defer frame.deinit(testing.allocator);
        idle_frame_count += 1;
        if (frame.header.kind != .screen_frontier_barrier) return error.NoChangeUnexpectedFrame;
        if (frame.header.stream_id != 2) return error.NoChangeWrongStream;
        const payload: *const [catchup_barrier_contract.payload_size]u8 = @ptrCast(frame.payload.ptr);
        const barrier = try catchup_barrier_contract.Barrier.decode(payload);
        if (barrier.target.sequence != 0) return error.NoChangeWrongFrontier;
    }
    if (idle_frame_count != 1) return error.NoChangeWrongFrameCount;
}

test "notification consume commits only after response control admission" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    var registry_value = registry.TerminalRuntimeRegistry.init(testing.allocator);
    defer registry_value.deinit();
    _ = try registry_value.register(0xAA, 80, 24);
    var subscriptions = subscription_identity.Table.init(testing.allocator);
    defer subscriptions.deinit();
    const reactor = try slot_mod.ReactorCore.create(testing.allocator);
    defer reactor.destroy();
    var runtime_ops: server.FakeRuntimeOps = .{};
    var fds: [2]c_int = undefined;
    try testing.expectEqual(
        @as(c_int, 0),
        c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds),
    );
    defer _ = c.close(fds[1]);
    const client = try Client.create(
        testing.allocator,
        fds[0],
        reactor,
        71,
        &registry_value,
        &subscriptions,
        .{ .runtime_ops = runtime_ops.ops() },
    );
    defer client.destroy();
    try sendTestFrame(
        fds[1],
        .hello,
        1,
        "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"gui\"}",
    );
    client.readReady(1);
    client.writeReady(2);
    _ = drainNonblocking(fds[1]);
    try sendTestFrame(
        fds[1],
        .request,
        2,
        "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"controller\"}}",
    );
    client.readReady(3);
    client.writeReady(4);
    _ = drainNonblocking(fds[1]);

    client.control_admission_fail_once = true;
    try sendTestFrame(
        fds[1],
        .request,
        3,
        "{\"method\":\"runtime.notification\",\"params\":{\"stream_id\":1}}",
    );
    client.readReady(5);
    try testing.expectEqual(@as(usize, 1), runtime_ops.notification_calls);
    try testing.expectEqual(@as(usize, 0), runtime_ops.notification_commit_calls);
    try testing.expect(client.isClosing());
}

test "completed chunk gives the next queued frame a fresh absolute write deadline" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    var fds: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    defer _ = c.close(fds[1]);
    var registry_value = registry.TerminalRuntimeRegistry.init(testing.allocator);
    defer registry_value.deinit();
    var subscriptions = subscription_identity.Table.init(testing.allocator);
    defer subscriptions.deinit();
    const reactor = try slot_mod.ReactorCore.create(testing.allocator);
    defer reactor.destroy();
    const client = try Client.create(
        testing.allocator,
        fds[0],
        reactor,
        7,
        &registry_value,
        &subscriptions,
        .{},
    );
    defer client.destroy();
    const slot = try reactor.get(client.admission);
    for (0..65) |_| try slot.enqueueControl("x");

    const filler: [64 * 1024]u8 = [_]u8{0x5A} ** (64 * 1024);
    while (true) {
        const rc = c.send(client.fd, &filler, filler.len, posix.MSG.DONTWAIT);
        if (rc < 0 and posix.errno(rc) == .AGAIN) break;
        if (rc <= 0) return error.TestUnexpectedResult;
    }
    client.writeReady(0);
    try testing.expect(slot.partialExpired(.write, slot_mod.partial_deadline_ns));
    _ = drainNonblocking(fds[1]);
    client.writeReady(9 * std.time.ns_per_s);
    try testing.expectEqual(@as(usize, 1), slot.chunk_len);
    try testing.expect(!slot.partialExpired(.write, 10 * std.time.ns_per_s));
    try testing.expect(!slot.partialExpired(.write, slot_mod.partial_absolute_deadline_ns));
}

test "socketpair attach creates tracker and detach purges only unsent screen frames" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    var fds: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    defer _ = c.close(fds[1]);
    var registry_value = registry.TerminalRuntimeRegistry.init(testing.allocator);
    defer registry_value.deinit();
    _ = try registry_value.register(0xAA, 80, 24);
    var subscriptions = subscription_identity.Table.init(testing.allocator);
    defer subscriptions.deinit();
    const reactor = try slot_mod.ReactorCore.create(testing.allocator);
    defer reactor.destroy();
    const client = try Client.create(
        testing.allocator,
        fds[0],
        reactor,
        8,
        &registry_value,
        &subscriptions,
        .{},
    );
    defer client.destroy();
    try sendTestFrame(fds[1], .hello, 1, test_hello);
    client.readReady(1);
    try sendTestFrame(
        fds[1],
        .request,
        2,
        "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"controller\"}}",
    );
    client.readReady(2);
    const slot = try reactor.get(client.admission);
    try testing.expectEqual(@as(usize, 1), client.trackers.count());
    try testing.expectEqual(@as(usize, 1), slot.attached_streams);
    try testing.expectEqual(slot_mod.QueueClass.control, slot.firstPending().?.class);

    const attach_batch = try testing.allocator.alloc([]u8, 2);
    attach_batch[0] = try framing.encodeFrame(
        testing.allocator,
        .{ .kind = .response, .request_id = 2 },
        "{\"result\":\"attached\"}",
    );
    attach_batch[1] = try framing.encodeFrame(
        testing.allocator,
        .{ .kind = .snapshot_chunk, .stream_id = 1, .flags = protocol.Flags.end_stream },
        "screen",
    );
    try client.adoptFrameBatch(attach_batch);
    try testing.expectEqual(@as(usize, 4), slot.chunk_len);
    try testing.expectEqual(
        slot_mod.QueueClass.screen,
        slot.chunks[(slot.chunk_head + 3) % slot_mod.max_chunks_per_slot].class,
    );
    try sendTestFrame(
        fds[1],
        .request,
        3,
        "{\"method\":\"runtime.detach\",\"params\":{\"stream_id\":1}}",
    );
    client.readReady(3);
    try testing.expect(!client.isClosing());
    try testing.expectEqual(@as(usize, 0), client.trackers.count());
    try testing.expectEqual(@as(usize, 0), slot.attached_streams);
    for (0..slot.chunk_len) |index| {
        const chunk = slot.chunks[(slot.chunk_head + index) % slot_mod.max_chunks_per_slot];
        try testing.expectEqual(slot_mod.QueueClass.control, chunk.class);
    }
}

test "missing runtime converges attachment identity tracker and queued screen in one turn" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    var failing = testing.FailingAllocator.init(
        testing.allocator,
        .{ .fail_index = std.math.maxInt(usize) },
    );
    const allocator = failing.allocator();
    var fds: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    defer _ = c.close(fds[1]);
    var registry_value = registry.TerminalRuntimeRegistry.init(allocator);
    defer registry_value.deinit();
    _ = try registry_value.register(0xAA, 80, 24);
    var subscriptions = subscription_identity.Table.init(allocator);
    defer subscriptions.deinit();
    const reactor = try slot_mod.ReactorCore.create(allocator);
    defer reactor.destroy();
    var runtime_ops: server.FakeRuntimeOps = .{};
    const client = try Client.create(
        allocator,
        fds[0],
        reactor,
        82,
        &registry_value,
        &subscriptions,
        .{ .runtime_ops = runtime_ops.ops() },
    );
    defer client.destroy();
    try sendTestFrame(
        fds[1],
        .hello,
        1,
        "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"gui\",\"capabilities\":[\"runtime_ended_v1\"]}",
    );
    client.readReady(1);
    try sendTestFrame(
        fds[1],
        .request,
        2,
        "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"controller\"}}",
    );
    client.readReady(2);
    const slot = try reactor.get(client.admission);
    const tracker = client.trackers.get(1).?;
    const attached = client.connection.attachments.get(1).?;
    const attached_retained = attached.base.?.len;
    try testing.expectEqual(
        attached_retained,
        try slot.retainedBaseBytes(tracker),
    );
    try testing.expectEqual(@as(usize, 0), try slot.preparedBaseBytes(tracker));
    try testing.expectEqual(@as(usize, 0), reactor.budget.prepared_base_bytes);
    try slot.consumeWritten(slot.pending_bytes);
    try slot.enqueueScreen(tracker, "stale-screen");
    try testing.expectEqual(@as(usize, 1), client.connection.attachmentCount());
    try testing.expectEqual(@as(usize, 1), subscriptions.count());
    try testing.expectEqual(@as(usize, 1), slot.attached_streams);

    // Pressure invalidation waits for a stream ACK and used to return before consulting the
    // registry, stranding authority forever if another client terminated the runtime meanwhile.
    try slot.invalidateAndPurgeScreenTracker(tracker);
    client.connection.markSubscriptionOutputInvalidated(1);
    try testing.expectEqual(slot_mod.ScreenState.invalidated, try slot.screenState(tracker));
    try testing.expect(!client.connection.resyncPending(1));
    _ = client.beginProducerSweep(3);
    registry_value.unregister(0xAA);
    runtime_ops.runtime_missing = true;
    // Ended convergence itself is allocation-free; a starved allocator cannot strand ownership.
    failing.fail_index = failing.alloc_index;
    client.tick(3);

    try testing.expect(client.isClosing());
    try testing.expectEqual(@as(usize, 0), client.connection.attachmentCount());
    try testing.expectEqual(@as(usize, 0), subscriptions.count());
    try testing.expectEqual(@as(usize, 0), client.trackers.count());
    try testing.expectEqual(@as(usize, 0), slot.attached_streams);
    try testing.expectEqual(@as(usize, 0), slot.chunk_len);
    try testing.expectEqual(@as(usize, 0), slot.pending_bytes);
}

test "subscription pressure emits one control notice and recovers with an atomic snapshot" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    var fds: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    defer _ = c.close(fds[1]);
    var registry_value = registry.TerminalRuntimeRegistry.init(testing.allocator);
    defer registry_value.deinit();
    _ = try registry_value.register(0xAA, 80, 24);
    var subscriptions = subscription_identity.Table.init(testing.allocator);
    defer subscriptions.deinit();
    const reactor = try slot_mod.ReactorCore.create(testing.allocator);
    defer reactor.destroy();
    var runtime_ops: server.FakeRuntimeOps = .{};
    const client = try Client.create(
        testing.allocator,
        fds[0],
        reactor,
        81,
        &registry_value,
        &subscriptions,
        .{ .runtime_ops = runtime_ops.ops() },
    );
    var client_alive = true;
    defer if (client_alive) client.destroy();
    try sendTestFrame(
        fds[1],
        .hello,
        1,
        "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"gui\",\"capabilities\":[\"runtime_metadata_v1\"],\"screen_stream_version\":2}",
    );
    client.readReady(1);
    try sendTestFrame(
        fds[1],
        .request,
        2,
        "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"controller\"}}",
    );
    client.readReady(2);
    const slot = try reactor.get(client.admission);
    const tracker = client.trackers.get(1).?;
    try slot.consumeWritten(slot.pending_bytes);
    runtime_ops.snapshot_len = 2 * 1024 * 1024 + 17;
    try testing.expectEqual(slot_mod.ScreenState.valid, try slot.screenState(tracker));

    try slot.enqueueScreen(tracker, "controller-zero-prefix");
    slot.notePartial(.write, 10, false);
    const controller_candidate = client.largestScreenPressure().?;
    try testing.expectEqual(@as(u64, 1), controller_candidate.stream);
    try testing.expect(std.meta.eql(tracker, controller_candidate.tracker));
    try testing.expect(!controller_candidate.written_prefix);
    try testing.expect(registry.Capability.has(
        registry_value.capabilitiesOfSubscription(
            0xAA,
            client.connection.attachments.get(1).?.subscription_id,
        ),
        registry.Capability.input,
    ));
    slot.clearPartial(.write);
    try slot.consumeWritten("controller-zero-prefix".len);

    try slot.enqueueScreen(tracker, "controller-written-prefix");
    try slot.consumeWritten(1);
    slot.notePartial(.write, 20, false);
    try testing.expect(client.largestScreenPressure() == null);
    slot.clearPartial(.write);
    try slot.consumeWritten("controller-written-prefix".len - 1);

    for (0..slot_mod.max_chunks_per_slot - slot_mod.control_chunk_reserve - slot.chunk_len) |_| try slot.enqueueScreen(tracker, "queued");

    const overflowing = try testing.allocator.alloc([]u8, 1);
    overflowing[0] = try framing.encodeFrame(
        testing.allocator,
        .{ .kind = .delta_chunk, .stream_id = 1, .flags = protocol.Flags.end_stream },
        "overflow",
    );
    try testing.expect(!try adoptTurnLikeProduct(client, 1, overflowing));
    try testing.expect(!client.isClosing());
    try testing.expectEqual(slot_mod.ScreenState.invalidated, try slot.screenState(tracker));
    try testing.expect(registry.Capability.has(
        registry_value.capabilitiesOfSubscription(
            0xAA,
            client.connection.attachments.get(1).?.subscription_id,
        ),
        registry.Capability.input,
    ));
    try testing.expectEqual(@as(usize, 0), try slot.retainedBaseBytes(tracker));
    var notice_count: usize = 0;
    for (0..slot.chunk_len) |logical| {
        const chunk = slot.chunks[(slot.chunk_head + logical) % slot_mod.max_chunks_per_slot];
        try testing.expectEqual(slot_mod.QueueClass.control, chunk.class);
        if (std.mem.indexOf(u8, chunk.bytes, "snapshot.invalidated") != null)
            notice_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), notice_count);
    var notice_parser = framing.FrameParser.init(testing.allocator);
    defer notice_parser.deinit();
    client.writeReady(3);
    try testing.expect((try receiveIntoParserNonblocking(fds[1], &notice_parser)) != 0);
    var wire_notices: usize = 0;
    while (try notice_parser.next()) |frame| {
        defer frame.deinit(testing.allocator);
        try testing.expectEqual(protocol.Kind.event, frame.header.kind);
        try testing.expectEqual(@as(u64, 1), frame.header.stream_id);
        try testing.expect(std.mem.indexOf(u8, frame.payload, "snapshot.invalidated") != null);
        wire_notices += 1;
    }
    try testing.expectEqual(@as(usize, 1), wire_notices);
    try testing.expect(!client.connection.attachments.get(1).?.resync_pending);
    try sendTestStreamFrame(fds[1], .stream_ack, 1, "{\"action\":\"resync\"}");
    const ack_at: u64 = 4;
    client.readReady(ack_at);
    try testing.expect(client.connection.attachments.get(1).?.resync_pending);
    try sendTestStreamFrame(fds[1], .stream_ack, 1, "{\"action\":\"resync\"}");
    client.readReady(ack_at + 1);
    client.tick(ack_at + slot_mod.resync_retry_backoff_ns - 1);
    try testing.expectEqual(@as(usize, 1), runtime_ops.snapshot_calls);
    try testing.expectEqual(slot_mod.ScreenState.invalidated, try slot.screenState(tracker));
    client.tick(ack_at + slot_mod.resync_retry_backoff_ns);
    try testing.expectEqual(@as(usize, 2), runtime_ops.snapshot_calls);
    try testing.expect(!client.isClosing());
    try testing.expectEqual(slot_mod.ScreenState.resync_draining, try slot.screenState(tracker));
    try testing.expect(!client.connection.attachments.get(1).?.resync_pending);
    try sendTestStreamFrame(fds[1], .stream_ack, 1, "{\"action\":\"resync\"}");
    client.readReady(ack_at + slot_mod.resync_retry_backoff_ns + 1);
    try testing.expect(!client.connection.attachments.get(1).?.resync_pending);
    try testing.expect((try slot.screenResidentBytes(tracker)) > 0);
    var recovered_chunks: usize = 0;
    for (0..slot.chunk_len) |logical| {
        const chunk = slot.chunks[(slot.chunk_head + logical) % slot_mod.max_chunks_per_slot];
        if (chunk.class == .screen) recovered_chunks += 1;
    }
    try testing.expectEqual(@as(usize, 4), recovered_chunks);
    const recovered = client.connection.attachments.get(1).?;
    const recovered_retained = recovered.base.?.len;
    try testing.expectEqual(
        recovered_retained,
        try slot.retainedBaseBytes(tracker),
    );
    try testing.expectEqual(@as(usize, 0), reactor.budget.prepared_base_bytes);
    var recovery_parser = framing.FrameParser.init(testing.allocator);
    defer recovery_parser.deinit();
    const recovery_write_at = ack_at + slot_mod.resync_retry_backoff_ns + 2;
    client.writeReady(recovery_write_at);
    _ = try receiveIntoParserNonblocking(fds[1], &recovery_parser);
    try testing.expect(slot.pending_bytes != 0);
    try testing.expectEqual(
        slot_mod.ScreenState.resync_draining,
        try slot.screenState(tracker),
    );
    var write_attempts: usize = 1;
    while (slot.pending_bytes != 0 and write_attempts < 1024) : (write_attempts += 1) {
        client.writeReady(recovery_write_at + write_attempts);
        _ = try receiveIntoParserNonblocking(fds[1], &recovery_parser);
    }
    try testing.expectEqual(@as(usize, 0), slot.pending_bytes);
    try testing.expect(write_attempts < 1024);
    _ = try receiveIntoParserNonblocking(fds[1], &recovery_parser);
    var metadata_frames: usize = 0;
    var snapshot_frames: usize = 0;
    var snapshot_bytes: usize = 0;
    var wire_index: usize = 0;
    while (try recovery_parser.next()) |frame| {
        defer frame.deinit(testing.allocator);
        try testing.expectEqual(@as(u64, 1), frame.header.stream_id);
        switch (frame.header.kind) {
            .event => {
                try testing.expectEqual(@as(usize, 0), wire_index);
                metadata_frames += 1;
            },
            .snapshot_chunk => {
                snapshot_frames += 1;
                try testing.expectEqual(snapshot_frames, wire_index);
                snapshot_bytes += frame.payload.len;
                try testing.expectEqual(
                    snapshot_frames == 3,
                    protocol.Flags.hasEndStream(frame.header.flags),
                );
            },
            else => return error.TestUnexpectedResult,
        }
        wire_index += 1;
    }
    try testing.expectEqual(@as(usize, 1), metadata_frames);
    try testing.expectEqual(@as(usize, 3), snapshot_frames);
    try testing.expectEqual(@as(usize, 2 * 1024 * 1024 + 17), snapshot_bytes);
    try testing.expectEqual(slot_mod.ScreenState.valid, try slot.screenState(tracker));
    client.destroy();
    client_alive = false;
    try testing.expectEqual(@as(usize, 0), subscriptions.count());
    try testing.expectEqual(@as(usize, 0), reactor.budget.resident_bytes);
    try testing.expectEqual(@as(usize, 0), reactor.budget.shared_bytes);
    try testing.expectEqual(@as(usize, 0), reactor.budget.prepared_base_bytes);
    try testing.expectEqual(@as(usize, 0), reactor.budget.prepared_reclaim_bytes);
}

test "periodic producer terminals immediately close readiness ownership and release attachment" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    const modes = [_]enum { invalid_observation, encoded_overflow, revision_exhaustion }{
        .invalid_observation,
        .encoded_overflow,
        .revision_exhaustion,
    };
    for (modes) |mode| {
        var fds: [2]c_int = undefined;
        var sibling_fds: [2]c_int = undefined;
        try testing.expectEqual(
            @as(c_int, 0),
            c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds),
        );
        try testing.expectEqual(
            @as(c_int, 0),
            c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &sibling_fds),
        );
        var registry_value = registry.TerminalRuntimeRegistry.init(testing.allocator);
        defer registry_value.deinit();
        _ = try registry_value.register(0xAA, 80, 24);
        _ = try registry_value.register(0xBB, 80, 24);
        var subscriptions = subscription_identity.Table.init(testing.allocator);
        defer subscriptions.deinit();
        const reactor = try slot_mod.ReactorCore.create(testing.allocator);
        defer reactor.destroy();
        var runtime_ops: server.FakeRuntimeOps = .{};
        var sibling_ops: server.FakeRuntimeOps = .{};
        const client = try Client.create(
            testing.allocator,
            fds[0],
            reactor,
            90,
            &registry_value,
            &subscriptions,
            .{ .runtime_ops = runtime_ops.ops() },
        );
        var client_alive = true;
        defer if (client_alive) client.destroy();
        const sibling = try Client.create(
            testing.allocator,
            sibling_fds[0],
            reactor,
            91,
            &registry_value,
            &subscriptions,
            .{ .runtime_ops = sibling_ops.ops() },
        );
        var sibling_alive = true;
        defer if (sibling_alive) sibling.destroy();
        try sendTestFrame(
            fds[1],
            .hello,
            1,
            "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"gui\",\"capabilities\":[\"runtime_metadata_v1\"]}",
        );
        client.readReady(1);
        try sendTestFrame(
            fds[1],
            .request,
            2,
            "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"controller\"}}",
        );
        client.readReady(2);
        try sendTestFrame(
            sibling_fds[1],
            .hello,
            1,
            "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"gui\"}",
        );
        sibling.readReady(1);
        try sendTestFrame(
            sibling_fds[1],
            .request,
            2,
            "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"bb\",\"mode\":\"controller\"}}",
        );
        sibling.readReady(2);
        const slot = try reactor.get(client.admission);
        try slot.consumeWritten(slot.pending_bytes);
        const sibling_slot = try reactor.get(sibling.admission);
        try sibling_slot.consumeWritten(sibling_slot.pending_bytes);
        runtime_ops.observation_urgent = true;
        switch (mode) {
            .invalid_observation => runtime_ops.observation_invalid = .mouse_mode,
            .encoded_overflow => runtime_ops.observation_invalid = .encoded_escape_expansion,
            .revision_exhaustion => {
                runtime_ops.observation_version = 1;
                client.connection.attachments.getPtr(1).?.observation_revision =
                    std.math.maxInt(u64);
            },
        }
        _ = client.beginProducerSweep(10);
        client.tick(10);
        try testing.expect(client.isClosing());
        sibling.tick(10);
        try testing.expect(!sibling.isClosing());
        try testing.expectEqual(@as(usize, 2), subscriptions.count());

        client.destroy();
        client_alive = false;
        try testing.expectEqual(@as(usize, 1), subscriptions.count());
        try sendTestFrame(sibling_fds[1], .ping, 3, "still-alive");
        sibling.readReady(11);
        try testing.expect(!sibling.isClosing());
        sibling.destroy();
        sibling_alive = false;
        try testing.expectEqual(@as(usize, 0), subscriptions.count());
        try testing.expectEqual(@as(usize, 0), reactor.budget.resident_bytes);
        try testing.expectEqual(@as(usize, 0), reactor.budget.shared_bytes);
        try testing.expectEqual(@as(usize, 0), reactor.budget.prepared_base_bytes);
        try testing.expectEqual(@as(usize, 0), reactor.budget.prepared_reclaim_bytes);
        var byte: [1]u8 = undefined;
        try testing.expectEqual(@as(isize, 0), c.recv(fds[1], &byte, byte.len, 0));
        try testing.expectEqual(@as(isize, 0), c.recv(sibling_fds[1], &byte, byte.len, 0));
        _ = c.close(fds[1]);
        _ = c.close(sibling_fds[1]);
    }
}

test "partial observer in a mixed controller connection is not a fail-close victim" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    var fds: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    defer _ = c.close(fds[1]);
    var registry_value = registry.TerminalRuntimeRegistry.init(testing.allocator);
    defer registry_value.deinit();
    _ = try registry_value.register(0xAA, 80, 24);
    _ = try registry_value.register(0xBB, 80, 24);
    var subscriptions = subscription_identity.Table.init(testing.allocator);
    defer subscriptions.deinit();
    const reactor = try slot_mod.ReactorCore.create(testing.allocator);
    defer reactor.destroy();
    var runtime_ops: server.FakeRuntimeOps = .{};
    const client = try Client.create(
        testing.allocator,
        fds[0],
        reactor,
        83,
        &registry_value,
        &subscriptions,
        .{ .runtime_ops = runtime_ops.ops() },
    );
    defer client.destroy();
    try sendTestFrame(
        fds[1],
        .hello,
        1,
        "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"gui\"}",
    );
    client.readReady(1);
    try sendTestFrame(
        fds[1],
        .request,
        2,
        "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"controller\"}}",
    );
    client.readReady(2);
    try sendTestFrame(
        fds[1],
        .request,
        3,
        "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"bb\",\"mode\":\"observer\"}}",
    );
    client.readReady(3);
    const slot = try reactor.get(client.admission);
    try slot.consumeWritten(slot.pending_bytes);
    const observer = client.trackers.get(2).?;
    try slot.enqueueScreen(observer, "partial-observer");
    try slot.consumeWritten(1);
    slot.notePartial(.write, 10, false);

    try testing.expect(client.largestScreenPressure() == null);
    try testing.expect(registry.Capability.has(
        registry_value.capabilitiesOfSubscription(
            0xAA,
            client.connection.attachments.get(1).?.subscription_id,
        ),
        registry.Capability.input,
    ));
    try testing.expect(!client.isClosing());
}

test "failed recovery backoff does not pin round robin ahead of healthy siblings" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    var fds: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    defer _ = c.close(fds[1]);
    var registry_value = registry.TerminalRuntimeRegistry.init(testing.allocator);
    defer registry_value.deinit();
    inline for (.{ 0xAA, 0xBB, 0xCC }) |id| _ = try registry_value.register(id, 80, 24);
    var subscriptions = subscription_identity.Table.init(testing.allocator);
    defer subscriptions.deinit();
    const reactor = try slot_mod.ReactorCore.create(testing.allocator);
    defer reactor.destroy();
    var runtime_ops: server.FakeRuntimeOps = .{};
    const client = try Client.create(
        testing.allocator,
        fds[0],
        reactor,
        82,
        &registry_value,
        &subscriptions,
        .{ .runtime_ops = runtime_ops.ops() },
    );
    defer client.destroy();
    try sendTestFrame(
        fds[1],
        .hello,
        1,
        "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"gui\",\"capabilities\":[\"runtime_metadata_v1\"],\"screen_stream_version\":2}",
    );
    client.readReady(1);
    inline for (.{ "aa", "bb", "cc" }, 0..) |id, index| {
        var params: [128]u8 = undefined;
        const request = try std.fmt.bufPrint(
            &params,
            "{{\"method\":\"runtime.attach\",\"params\":{{\"runtime_id\":\"{s}\",\"mode\":\"observer\"}}}}",
            .{id},
        );
        try sendTestFrame(fds[1], .request, 2 + index, request);
        client.readReady(2 + index);
    }
    const slot = try reactor.get(client.admission);
    try slot.consumeWritten(slot.pending_bytes);
    const recovering = client.trackers.get(2).?;
    client.invalidateSubscriptionOutput("invalidate_test_fixture", 2, recovering);
    try sendTestStreamFrame(fds[1], .stream_ack, 2, "{\"action\":\"resync\"}");
    client.readReady(10);

    runtime_ops.observation_fail_count = 1;
    runtime_ops.snapshot_fail_count = 1;
    const preflight_blocked_at = 10 + slot_mod.resync_retry_backoff_ns;
    const injected_pressure = slot_mod.shared_steady_bytes -
        reactor.budget.shared_bytes -
        slot_mod.base_update_max_bytes -
        slot_mod.resync_batch_bytes +
        1;
    reactor.budget.resident_bytes += injected_pressure;
    reactor.budget.shared_bytes += injected_pressure;
    _ = client.beginProducerSweep(preflight_blocked_at);
    client.tick(preflight_blocked_at);
    try testing.expectEqual(@as(usize, 3), runtime_ops.snapshot_calls);
    try testing.expect(client.connection.attachments.get(2).?.resync_pending);
    try testing.expectEqualStrings(
        "NEW-BASE",
        client.connection.attachments.get(1).?.base.?,
    );
    try testing.expectEqual(@as(usize, 1), runtime_ops.delta_calls);
    reactor.budget.resident_bytes -= injected_pressure;
    reactor.budget.shared_bytes -= injected_pressure;

    const revision_before_failure =
        client.connection.attachments.get(2).?.observation_revision;
    const observation_failure_at = preflight_blocked_at + 1;
    _ = client.beginProducerSweep(observation_failure_at);
    client.tick(observation_failure_at);
    try testing.expectEqual(@as(usize, 3), runtime_ops.snapshot_calls);
    try testing.expect(client.connection.attachments.get(2).?.resync_pending);
    try testing.expectEqual(
        revision_before_failure,
        client.connection.attachments.get(2).?.observation_revision,
    );
    try testing.expectEqual(
        @as(?u64, null),
        client.connection.attachments.get(2).?.observation_token,
    );

    const first_attempt = observation_failure_at + slot_mod.resync_retry_backoff_ns;
    _ = client.beginProducerSweep(first_attempt);
    client.tick(first_attempt);
    try testing.expectEqual(@as(usize, 4), runtime_ops.snapshot_calls);
    try testing.expect(client.connection.attachments.get(2).?.resync_pending);
    try testing.expectEqual(
        @as(usize, 0),
        try slot.preparedBaseBytes(recovering),
    );
    try testing.expectEqual(@as(usize, 0), try slot.retainedBaseBytes(recovering));
    try testing.expectEqual(@as(usize, 0), try slot.screenResidentBytes(recovering));
    try testing.expectEqual(
        revision_before_failure,
        client.connection.attachments.get(2).?.observation_revision,
    );
    try testing.expectEqual(
        @as(?u64, null),
        client.connection.attachments.get(2).?.observation_token,
    );
    try testing.expectEqual(@as(usize, 0), reactor.budget.prepared_base_bytes);
    try testing.expectEqual(@as(usize, 0), reactor.budget.prepared_reclaim_bytes);
    try testing.expectEqualStrings("NEW-BASE", client.connection.attachments.get(1).?.base.?);
    try testing.expectEqualStrings("SNAPSHOT-BYTES", client.connection.attachments.get(3).?.base.?);

    // Stream 2 is now inside the one-second backoff. Priority selection must not rewind the
    // cursor, so stream 3 and then stream 1 each get a normal producer turn.
    client.tick(first_attempt + 1);
    try testing.expectEqualStrings("NEW-BASE", client.connection.attachments.get(3).?.base.?);
    try testing.expectEqual(@as(usize, 2), runtime_ops.delta_calls);
    client.tick(first_attempt + 2);
    try testing.expectEqualStrings("NEW-BASE", client.connection.attachments.get(1).?.base.?);
    try testing.expectEqual(@as(usize, 3), runtime_ops.delta_calls);
    try testing.expect(client.connection.attachments.get(2).?.resync_pending);
    try testing.expect(!client.connection.attachments.get(2).?.awaiting_resync_ack);
    var notices_after_failure: usize = 0;
    for (0..slot.chunk_len) |logical| {
        const chunk = slot.chunks[(slot.chunk_head + logical) % slot_mod.max_chunks_per_slot];
        if (chunk.class == .control and
            std.mem.indexOf(u8, chunk.bytes, "snapshot.invalidated") != null)
            notices_after_failure += 1;
    }
    try testing.expectEqual(@as(usize, 1), notices_after_failure);

    const retry_at = first_attempt + slot_mod.resync_retry_backoff_ns;
    _ = client.beginProducerSweep(retry_at - 1);
    client.tick(retry_at - 1);
    try testing.expectEqual(@as(usize, 4), runtime_ops.snapshot_calls);
    try testing.expect(client.connection.attachments.get(2).?.resync_pending);
    _ = client.beginProducerSweep(retry_at);
    client.tick(retry_at);
    try testing.expectEqual(@as(usize, 5), runtime_ops.snapshot_calls);
    try testing.expect(!client.connection.attachments.get(2).?.resync_pending);
    try testing.expectEqual(
        slot_mod.ScreenState.resync_draining,
        try slot.screenState(recovering),
    );
}

test "P5b2b3 pressure drains a written screen batch before target-only invalidation" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    var fds: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    defer _ = c.close(fds[1]);
    var registry_value = registry.TerminalRuntimeRegistry.init(testing.allocator);
    defer registry_value.deinit();
    _ = try registry_value.register(0xAA, 80, 24);
    _ = try registry_value.register(0xBB, 80, 24);
    var subscriptions = subscription_identity.Table.init(testing.allocator);
    defer subscriptions.deinit();
    const reactor = try slot_mod.ReactorCore.create(testing.allocator);
    defer reactor.destroy();
    var runtime_ops: server.FakeRuntimeOps = .{};
    const client = try Client.create(
        testing.allocator,
        fds[0],
        reactor,
        83,
        &registry_value,
        &subscriptions,
        .{ .runtime_ops = runtime_ops.ops() },
    );
    defer client.destroy();
    try sendTestFrame(
        fds[1],
        .hello,
        1,
        "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"gui\"}",
    );
    client.readReady(1);
    try sendTestFrame(
        fds[1],
        .request,
        2,
        "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"observer\"}}",
    );
    client.readReady(2);
    try sendTestFrame(
        fds[1],
        .request,
        3,
        "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"bb\",\"mode\":\"observer\"}}",
    );
    client.readReady(3);
    const slot = try reactor.get(client.admission);
    try slot.consumeWritten(slot.pending_bytes);
    const tracker = client.trackers.get(1).?;
    var sibling_stream: subscription_identity.LocalStreamId = 0;
    var tracker_iterator = client.trackers.iterator();
    while (tracker_iterator.next()) |entry| {
        if (entry.key_ptr.* != 1) {
            sibling_stream = entry.key_ptr.*;
            break;
        }
    }
    try testing.expect(sibling_stream != 0);
    const sibling_tracker = client.trackers.get(sibling_stream).?;
    const tiny: c_int = 1024;
    try testing.expectEqual(@as(c_int, 0), c.setsockopt(
        fds[0],
        posix.SOL.SOCKET,
        posix.SO.SNDBUF,
        @ptrCast(&tiny),
        @sizeOf(c_int),
    ));
    try testing.expectEqual(@as(c_int, 0), c.setsockopt(
        fds[1],
        posix.SOL.SOCKET,
        posix.SO.RCVBUF,
        @ptrCast(&tiny),
        @sizeOf(c_int),
    ));
    const first_payload = try testing.allocator.alloc(u8, protocol.max_binary_chunk);
    defer testing.allocator.free(first_payload);
    @memset(first_payload, 'p');
    const first = try framing.encodeFrame(
        testing.allocator,
        .{ .kind = .delta_chunk, .stream_id = 1 },
        first_payload,
    );
    const last = try framing.encodeFrame(
        testing.allocator,
        .{ .kind = .delta_chunk, .stream_id = 1, .flags = protocol.Flags.end_stream },
        "written-suffix",
    );
    const current_batch = try testing.allocator.alloc([]u8, 2);
    current_batch[0] = first;
    current_batch[1] = last;
    try testing.expect(try adoptTurnLikeProduct(client, 1, current_batch));
    try testing.expectEqual(slot_mod.QueueClass.screen, slot.firstPending().?.class);
    client.writeReady(4);
    try testing.expect(try slot.trackerHasWrittenPrefix(tracker));
    client.writeReady(5);
    try testing.expect(slot.writeStallObserved());

    const sibling_batch = try testing.allocator.alloc([]u8, 1);
    sibling_batch[0] = try framing.encodeFrame(
        testing.allocator,
        .{ .kind = .delta_chunk, .stream_id = sibling_stream, .flags = protocol.Flags.end_stream },
        "SIBLING-MARKER",
    );
    try testing.expect(try adoptTurnLikeProduct(client, sibling_stream, sibling_batch));

    const megabyte = try testing.allocator.alloc(u8, protocol.max_binary_chunk);
    defer testing.allocator.free(megabyte);
    @memset(megabyte, 'q');
    for (0..6) |_| try slot.enqueueScreen(tracker, megabyte);
    const batch = try testing.allocator.alloc([]u8, 1);
    batch[0] = try framing.encodeFrame(
        testing.allocator,
        .{ .kind = .delta_chunk, .stream_id = 1, .flags = protocol.Flags.end_stream },
        megabyte,
    );
    try testing.expect(!try adoptTurnLikeProduct(client, 1, batch));
    try testing.expect(!client.isClosing());
    try testing.expectEqual(
        slot_mod.ScreenState.drain_current_batch,
        try slot.screenState(tracker),
    );
    try testing.expectError(error.Busy, slot.reserveBaseUpdate(tracker, 16));
    var received: std.ArrayListUnmanaged(u8) = .empty;
    defer received.deinit(testing.allocator);
    var recv_buf: [64 * 1024]u8 = undefined;
    for (0..4096) |turn| {
        while (true) {
            const rc = c.recv(fds[1], &recv_buf, recv_buf.len, posix.MSG.DONTWAIT);
            if (rc < 0 and posix.errno(rc) == .AGAIN) break;
            try testing.expect(rc > 0);
            try received.appendSlice(testing.allocator, recv_buf[0..@intCast(rc)]);
        }
        client.writeReady(6 + turn);
        if (try slot.screenState(tracker) == .invalidated and !client.wantsWrite()) break;
    }
    while (true) {
        const rc = c.recv(fds[1], &recv_buf, recv_buf.len, posix.MSG.DONTWAIT);
        if (rc < 0 and posix.errno(rc) == .AGAIN) break;
        try testing.expect(rc > 0);
        try received.appendSlice(testing.allocator, recv_buf[0..@intCast(rc)]);
    }
    try testing.expect(!client.isClosing());
    try testing.expectEqual(slot_mod.ScreenState.invalidated, try slot.screenState(tracker));
    try testing.expectEqual(slot_mod.ScreenState.valid, try slot.screenState(sibling_tracker));
    var parser = framing.FrameParser.init(testing.allocator);
    defer parser.deinit();
    try parser.push(received.items);
    var target_frames: usize = 0;
    var target_ended = false;
    var sibling_seen = false;
    var notice_seen = false;
    while (try parser.next()) |frame| {
        defer frame.deinit(testing.allocator);
        if (frame.header.stream_id == 1 and frame.header.kind == .delta_chunk) {
            try testing.expect(!target_ended);
            target_frames += 1;
            if (protocol.Flags.hasEndStream(frame.header.flags)) {
                try testing.expectEqualStrings("written-suffix", frame.payload);
                target_ended = true;
            }
        } else if (frame.header.stream_id == sibling_stream) {
            try testing.expect(target_ended);
            try testing.expectEqualStrings("SIBLING-MARKER", frame.payload);
            sibling_seen = true;
        } else if (frame.header.kind == .event and
            std.mem.indexOf(u8, frame.payload, "snapshot.invalidated") != null)
        {
            try testing.expect(target_ended);
            try testing.expect(!notice_seen);
            notice_seen = true;
        }
    }
    try testing.expectEqual(@as(usize, 2), target_frames);
    try testing.expect(target_ended and sibling_seen and notice_seen);

    try sendTestFrame(fds[1], .request, 4, "{\"method\":\"host.info\"}");
    client.readReady(5000);
    client.writeReady(5001);
    var info_bytes: [4096]u8 = undefined;
    const info_len = c.recv(fds[1], &info_bytes, info_bytes.len, 0);
    try testing.expect(info_len > 0);
    var info_parser = framing.FrameParser.init(testing.allocator);
    defer info_parser.deinit();
    try info_parser.push(info_bytes[0..@intCast(info_len)]);
    const info = (try info_parser.next()) orelse return error.TestUnexpectedResult;
    defer info.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 4), info.header.request_id);
    try testing.expect(std.mem.indexOf(u8, info.payload, "host_id") != null);
}

test "subscription batch preflight rejects cross-stream mixed and unterminated output" {
    const testing = std.testing;
    const valid = [_][]u8{
        try framing.encodeFrame(
            testing.allocator,
            .{ .kind = .event, .stream_id = 1 },
            "{\"event\":\"runtime.metadata\"}",
        ),
        try framing.encodeFrame(
            testing.allocator,
            .{ .kind = .snapshot_chunk, .stream_id = 1, .flags = protocol.Flags.end_stream },
            "snapshot",
        ),
    };
    defer for (valid) |frame| testing.allocator.free(frame);
    try testing.expect(validateSubscriptionBatch(1, &valid, null));

    const cross = [_][]u8{try framing.encodeFrame(
        testing.allocator,
        .{ .kind = .delta_chunk, .stream_id = 2, .flags = protocol.Flags.end_stream },
        "delta",
    )};
    defer testing.allocator.free(cross[0]);
    try testing.expect(!validateSubscriptionBatch(1, &cross, null));

    const unterminated = [_][]u8{try framing.encodeFrame(
        testing.allocator,
        .{ .kind = .snapshot_chunk, .stream_id = 1 },
        "snapshot",
    )};
    defer testing.allocator.free(unterminated[0]);
    try testing.expect(!validateSubscriptionBatch(1, &unterminated, null));

    const mixed = [_][]u8{
        try framing.encodeFrame(
            testing.allocator,
            .{ .kind = .snapshot_chunk, .stream_id = 1 },
            "a",
        ),
        try framing.encodeFrame(
            testing.allocator,
            .{ .kind = .delta_chunk, .stream_id = 1, .flags = protocol.Flags.end_stream },
            "b",
        ),
    };
    defer for (mixed) |frame| testing.allocator.free(frame);
    try testing.expect(!validateSubscriptionBatch(1, &mixed, null));
}

test "reply-and-close waits through EAGAIN and closes only after full typed reply" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    var fds: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    defer _ = c.close(fds[1]);
    var registry_value = registry.TerminalRuntimeRegistry.init(testing.allocator);
    defer registry_value.deinit();
    var subscriptions = subscription_identity.Table.init(testing.allocator);
    defer subscriptions.deinit();
    const reactor = try slot_mod.ReactorCore.create(testing.allocator);
    defer reactor.destroy();
    const client = try Client.create(
        testing.allocator,
        fds[0],
        reactor,
        9,
        &registry_value,
        &subscriptions,
        .{},
    );
    defer client.destroy();
    const filler: [64 * 1024]u8 = [_]u8{0xC3} ** (64 * 1024);
    while (true) {
        const rc = c.send(client.fd, &filler, filler.len, posix.MSG.DONTWAIT);
        if (rc < 0 and posix.errno(rc) == .AGAIN) break;
        if (rc <= 0) return error.TestUnexpectedResult;
    }
    try sendTestFrame(
        fds[1],
        .hello,
        1,
        "{\"protocol_min\":1,\"protocol_max\":1,\"client_kind\":\"gui\"}",
    );
    client.readReady(1);
    try testing.expect(client.close_after_flush != null);
    client.writeReady(2);
    try testing.expect(!client.isClosing());
    try testing.expect(drainNonblocking(fds[1]) != 0);
    client.writeReady(3);
    try testing.expect(client.isClosing());
}

test "one-shot admin leaves a pipelined second request undispatched" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    var fds: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    defer _ = c.close(fds[1]);
    var registry_value = registry.TerminalRuntimeRegistry.init(testing.allocator);
    defer registry_value.deinit();
    var subscriptions = subscription_identity.Table.init(testing.allocator);
    defer subscriptions.deinit();
    var admin_admission: server.AdminAdmission = .{};
    const reactor = try slot_mod.ReactorCore.create(testing.allocator);
    defer reactor.destroy();
    const client = try Client.create(
        testing.allocator,
        fds[0],
        reactor,
        9,
        &registry_value,
        &subscriptions,
        .{ .admin_admission = &admin_admission },
    );
    defer client.destroy();

    try sendTestFrame(
        fds[1],
        .hello,
        1,
        "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"admin\"}",
    );
    client.readReady(1);
    client.writeReady(2);
    _ = drainNonblocking(fds[1]);
    try testing.expect(admin_admission.active);

    try sendTestFrame(fds[1], .ping, 2, "admin-ping");
    try sendTestFrame(fds[1], .request, 3, "{\"method\":\"host.info\"}");
    client.readReady(3);
    try testing.expect(client.close_after_flush != null);
    try testing.expect(client.admin_request_deadline_at_ns == null);
    client.tick(3 +| admin_request_deadline_ns);
    try testing.expect(!client.isClosing());
    try testing.expect(client.hasBufferedReadWork() == false);
    client.writeReady(4);
    try testing.expect(client.isClosing());

    var parser = framing.FrameParser.init(testing.allocator);
    defer parser.deinit();
    var bytes: [4096]u8 = undefined;
    const rc = c.recv(fds[1], &bytes, bytes.len, 0);
    try testing.expect(rc > 0);
    try parser.push(bytes[0..@intCast(rc)]);
    var responses: usize = 0;
    while (try parser.next()) |frame| {
        defer frame.deinit(testing.allocator);
        try testing.expectEqual(@as(u64, 2), frame.header.request_id);
        try testing.expect(std.mem.indexOf(u8, frame.payload, "unauthorized") != null);
        responses += 1;
    }
    try testing.expectEqual(@as(usize, 1), responses);
}

test "admin runtime end mutates only after reply queue admission and then flushes before close" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    var registry_value = registry.TerminalRuntimeRegistry.init(testing.allocator);
    defer registry_value.deinit();
    _ = try registry_value.register(0xAA, 80, 24);
    var runtime_ops: server.FakeRuntimeOps = .{};
    var subscriptions = subscription_identity.Table.init(testing.allocator);
    defer subscriptions.deinit();
    const reactor = try slot_mod.ReactorCore.create(testing.allocator);
    defer reactor.destroy();

    {
        var fds: [2]c_int = undefined;
        try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
        defer _ = c.close(fds[1]);
        var admin_admission: server.AdminAdmission = .{};
        const client = try Client.create(
            testing.allocator,
            fds[0],
            reactor,
            9,
            &registry_value,
            &subscriptions,
            .{ .admin_admission = &admin_admission, .runtime_ops = runtime_ops.ops() },
        );
        defer client.destroy();
        try sendTestFrame(
            fds[1],
            .hello,
            1,
            "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"admin\"}",
        );
        client.readReady(1);
        client.writeReady(2);
        _ = drainNonblocking(fds[1]);
        client.control_admission_fail_once = true;
        try sendTestFrame(
            fds[1],
            .request,
            2,
            "{\"method\":\"runtime.terminate\",\"params\":{\"runtime_id\":\"aa\"}}",
        );
        client.readReady(3);
        try testing.expectEqual(@as(u128, 0), runtime_ops.terminated_id);
    }

    {
        var fds: [2]c_int = undefined;
        try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
        defer _ = c.close(fds[1]);
        var admin_admission: server.AdminAdmission = .{};
        const client = try Client.create(
            testing.allocator,
            fds[0],
            reactor,
            9,
            &registry_value,
            &subscriptions,
            .{ .admin_admission = &admin_admission, .runtime_ops = runtime_ops.ops() },
        );
        defer client.destroy();
        try sendTestFrame(
            fds[1],
            .hello,
            3,
            "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"admin\"}",
        );
        client.readReady(4);
        client.writeReady(5);
        _ = drainNonblocking(fds[1]);
        try sendTestFrame(
            fds[1],
            .request,
            4,
            "{\"method\":\"runtime.terminate\",\"params\":{\"runtime_id\":\"aa\"}}",
        );
        client.readReady(6);
        try testing.expectEqual(@as(u128, 0xAA), runtime_ops.terminated_id);
        try testing.expect(client.close_after_flush != null);
        try testing.expect(!client.isClosing());
        client.writeReady(7);
        try testing.expect(client.isClosing());
        var response: [4096]u8 = undefined;
        const count = c.recv(fds[1], &response, response.len, 0);
        try testing.expect(count > 0);
        try testing.expect(std.mem.indexOf(u8, response[0..@intCast(count)], "\"terminated\":true") != null);
    }
}

test "admin request deadline is immutable under incomplete-byte drip" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    var fds: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    defer _ = c.close(fds[1]);
    var registry_value = registry.TerminalRuntimeRegistry.init(testing.allocator);
    defer registry_value.deinit();
    var subscriptions = subscription_identity.Table.init(testing.allocator);
    defer subscriptions.deinit();
    var admin_admission: server.AdminAdmission = .{};
    const reactor = try slot_mod.ReactorCore.create(testing.allocator);
    defer reactor.destroy();
    const client = try Client.create(
        testing.allocator,
        fds[0],
        reactor,
        9,
        &registry_value,
        &subscriptions,
        .{ .admin_admission = &admin_admission },
    );
    defer client.destroy();

    try sendTestFrame(
        fds[1],
        .hello,
        1,
        "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"admin\"}",
    );
    client.readReady(1);
    client.writeReady(2);
    _ = drainNonblocking(fds[1]);
    try testing.expectEqual(@as(?u64, 1 + admin_request_deadline_ns), client.admin_request_deadline_at_ns);

    const partial = [_]u8{'M'};
    try testing.expectEqual(@as(isize, 1), c.send(fds[1], &partial, partial.len, 0));
    client.readReady(admin_request_deadline_ns);
    try testing.expect(!client.isClosing());
    client.tick(1 + admin_request_deadline_ns);
    try testing.expect(client.isClosing());
}

test "socketpair read partial clock resets at the next frame boundary" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    var fds: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    defer _ = c.close(fds[1]);
    var registry_value = registry.TerminalRuntimeRegistry.init(testing.allocator);
    defer registry_value.deinit();
    var subscriptions = subscription_identity.Table.init(testing.allocator);
    defer subscriptions.deinit();
    const reactor = try slot_mod.ReactorCore.create(testing.allocator);
    defer reactor.destroy();
    const client = try Client.create(
        testing.allocator,
        fds[0],
        reactor,
        10,
        &registry_value,
        &subscriptions,
        .{},
    );
    defer client.destroy();
    const optional = (protocol.Header{
        .kind = @enumFromInt(55_000),
        .flags = protocol.Flags.optional,
    }).encode();
    const hello = try framing.encodeFrame(testing.allocator, .{ .kind = .hello }, test_hello);
    defer testing.allocator.free(hello);
    _ = c.send(fds[1], &optional, 7, 0);
    client.readReady(0);
    const slot = try reactor.get(client.admission);
    try testing.expect(slot.partialExpired(.read, slot_mod.partial_deadline_ns));

    var remainder: [protocol.header_size - 7 + 7]u8 = undefined;
    @memcpy(remainder[0 .. protocol.header_size - 7], optional[7..]);
    @memcpy(remainder[protocol.header_size - 7 ..], hello[0..7]);
    _ = c.send(fds[1], &remainder, remainder.len, 0);
    client.readReady(20 * std.time.ns_per_s);
    try testing.expectEqual(
        @as(?u64, 20 * std.time.ns_per_s),
        slot.read_partial_started_ns,
    );
    try testing.expect(!slot.partialExpired(.read, 30 * std.time.ns_per_s - 1));
    try testing.expect(slot.partialExpired(.read, 30 * std.time.ns_per_s));
}

// 2026-09-15 실측이 세운 판정자다. host 로그 88 개에 `why=partial_timeout` 이 126 번 있었는데
// 전부 `site=-` 여서 **사고인지 정상 회수인지조차** 가릴 수 없었다. `why_ra` 도 소용이 없었다 —
// 최적화가 네 자리를 뭉개 줄번호가 `defer` 와 `producer_sweep_cursor %` 를 가리켰다.
// 그러므로 「이름이 다르다」가 아니라 **「네 갈래를 실제로 몰아넣고 각각 제 이름이 나온다」** 를 센다.
test "tick tells its four partial_timeout sites apart by name" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;

    const Fixture = struct {
        fds: [2]c_int = undefined,
        registry_value: registry.TerminalRuntimeRegistry,
        subscriptions: subscription_identity.Table,
        reactor: *slot_mod.ReactorCore,
        client: *Client,

        /// **호출자가 놓은 자리에서 바로 초기화한다 — 값으로 돌려주지 않는다.** `Client` 가
        /// `registry_value`·`subscriptions` 의 **주소**를 들고 있으므로, 예전처럼 지역 `self` 를
        /// 만들어 `return self` 하면 `Client` 는 사라진 스택 프레임을 가리킨 채 남는다. Debug 에서는
        /// 그 자리가 우연히 그대로 남아 통과했고, ReleaseFast 에서는 스택이 재사용돼 **매번 SEGV**
        /// 로 죽었다(단독 실행 3/3 · CI 수동 실행 집계 588 번째).
        fn open(self: *@This(), id: u64) !void {
            var fds: [2]c_int = undefined;
            if (c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds) != 0)
                return error.TestUnexpectedResult;
            self.* = .{
                .fds = fds,
                .registry_value = registry.TerminalRuntimeRegistry.init(testing.allocator),
                .subscriptions = subscription_identity.Table.init(testing.allocator),
                .reactor = try slot_mod.ReactorCore.create(testing.allocator),
                .client = undefined,
            };
            self.client = try Client.create(
                testing.allocator,
                fds[0],
                self.reactor,
                id,
                &self.registry_value,
                &self.subscriptions,
                .{ .now_ns = 100 },
            );
        }

        /// hello 를 흘려 넣어 핸드셰이크를 끝낸다 — 그래야 첫 갈래(핸드셰이크 데드라인)가
        /// 뒤 세 갈래를 가로채지 않는다.
        fn shakeHands(self: *@This()) !void {
            try sendTestFrame(
                self.fds[1],
                .hello,
                1,
                "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"gui\"}",
            );
            self.client.readReady(100);
            self.client.writeReady(100);
            _ = drainNonblocking(self.fds[1]);
            try testing.expect(self.client.connection.handshakeComplete());
        }

        fn close(self: *@This()) void {
            self.client.destroy();
            self.reactor.destroy();
            self.subscriptions.deinit();
            self.registry_value.deinit();
            _ = c.close(self.fds[1]);
        }
    };

    // ① 핸드셰이크를 끝내지 않은 채 데드라인을 넘긴다.
    {
        var fx: Fixture = undefined;
        try fx.open(901);
        defer fx.close();
        fx.client.tick(100 + handshake_deadline_ns);
        try testing.expect(fx.client.isClosing());
        try testing.expectEqual(CloseReason.partial_timeout, fx.client.closeReason().?);
        try testing.expectEqualStrings("tick_handshake_deadline", fx.client.closeSite());
    }

    // ② 구독이 0 인 연결을 유휴로 거둔다 — 넷 중 **이것만 정상**이다.
    {
        var fx: Fixture = undefined;
        try fx.open(902);
        defer fx.close();
        try fx.shakeHands();
        try testing.expectEqual(@as(usize, 0), fx.client.connection.attachmentCount());
        fx.client.tick(100 + unattached_idle_deadline_ns);
        try testing.expect(fx.client.isClosing());
        try testing.expectEqual(CloseReason.partial_timeout, fx.client.closeReason().?);
        try testing.expectEqualStrings("tick_unattached_idle", fx.client.closeSite());
    }

    // ③ 쓰기가 정체한다 — client 가 안 빼간다(배압). 유휴(30 s) 보다 **먼저** 걸려야 한다.
    {
        var fx: Fixture = undefined;
        try fx.open(903);
        defer fx.close();
        try fx.shakeHands();
        const slot = try fx.reactor.get(fx.client.admission);
        slot.clearPartial(.read);
        slot.notePartial(.write, 100, false);
        fx.client.tick(100 + slot_mod.partial_deadline_ns);
        try testing.expect(fx.client.isClosing());
        try testing.expectEqual(CloseReason.partial_timeout, fx.client.closeReason().?);
        try testing.expectEqualStrings("tick_partial_write_stalled", fx.client.closeSite());
    }

    // ④ 읽기가 정체한다 — client 가 안 보낸다. ③ 과 의심할 쪽이 정반대라 이름이 달라야 한다.
    {
        var fx: Fixture = undefined;
        try fx.open(904);
        defer fx.close();
        try fx.shakeHands();
        const slot = try fx.reactor.get(fx.client.admission);
        slot.clearPartial(.write);
        slot.notePartial(.read, 100, false);
        fx.client.tick(100 + slot_mod.partial_deadline_ns);
        try testing.expect(fx.client.isClosing());
        try testing.expectEqual(CloseReason.partial_timeout, fx.client.closeReason().?);
        try testing.expectEqualStrings("tick_partial_read_stalled", fx.client.closeSite());
    }
}

// 호출자가 준 자리 이름이 **실제로 닫기까지 닿는지** 잰다.
//
// 경계 축(`collect_failure_site_boundary`)은 「모든 호출자가 리터럴을 준다」를 소스로 센다. 그런데
// 그것만으로는 **그 값이 `closeSite()` 에 실리는지**를 모른다 — 파라미터를 받아 놓고 안 쓰거나
// 다른 리터럴로 닫아도 소스 검사는 통과한다(돌연변이 N1 이 정확히 그 모양이었고, 축이 잡았지만
// 그것은 「리터럴을 안 쓴다」를 본 것이지 「받은 값을 쓴다」를 본 것이 아니다).
//
// `Stale` 갈래로 재는 이유: 트래커 키 하나만 틀리게 주면 `trackerEntry` 가 바로 `error.Stale` 을
// 내므로, 소켓 상태를 만들지 않고도 **`site` 가 `beginCloseAtErr` 를 거쳐 나오는 그 길**을 탄다.
// 이 판정자가 재는 것은 갈래의 의미가 아니라 **배선**이다.
test "invalidateSubscriptionOutput 은 호출자가 준 이름으로 닫는다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    var fds: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    defer _ = c.close(fds[1]);
    var registry_value = registry.TerminalRuntimeRegistry.init(testing.allocator);
    defer registry_value.deinit();
    var subscriptions = subscription_identity.Table.init(testing.allocator);
    defer subscriptions.deinit();
    const reactor = try slot_mod.ReactorCore.create(testing.allocator);
    defer reactor.destroy();
    const client = try Client.create(
        testing.allocator,
        fds[0],
        reactor,
        915,
        &registry_value,
        &subscriptions,
        .{ .now_ns = 100 },
    );
    defer client.destroy();

    // 어느 트래커에도 해당하지 않는 키. `generation` 을 어긋나게 두면 `trackerEntry` 가 `Stale` 이다.
    const slot = try reactor.get(client.admission);
    const bogus: slot_mod.ScreenTrackerKey = .{
        .owner = slot.key,
        .index = 0,
        .generation = 0xDEAD_BEEF,
    };

    client.invalidateSubscriptionOutput("invalidate_wiring_probe", 7, bogus);

    try testing.expect(client.isClosing());
    // 사유와 오류는 기존 계약 그대로여야 한다 — 이름만 더한 변경이다.
    try testing.expectEqual(CloseReason.socket_error, client.closeReason().?);
    try testing.expectEqualStrings("Stale", client.closeError());
    // 핵심: 리터럴이 아니라 **호출자가 준 값**이 실려 나온다.
    try testing.expectEqualStrings("invalidate_wiring_probe", client.closeSite());
}

/// 구독 한 턴을 채택하고, **제품(`tick`)이 그 결과에 하는 일을 그대로** 한다.
///
/// 예전에는 제품 함수 `adoptSubscriptionTurn` 이 이 노릇을 했는데, 2026-07-26 에 `tick` 이
/// `tryAdoptSubscriptionTurn` 을 직접 부르도록 바뀌면서 **호출자를 잃고 죽은 코드가 됐다.**
/// 그런데도 판정자 넷이 그것을 계속 불러, 제품이 안 타는 길을 재고 있었다 — 게다가 그 죽은
/// 함수는 `.deferred_global_pressure` 에 **무효화**를 했고 제품은 **백오프**만 한다(정반대다).
///
/// 그래서 헬퍼를 테스트 쪽으로 옮기고 제품과 같은 갈래만 남긴다. 미뤄지는 두 갈래에 닿으면
/// **실패시킨다** — 제품은 거기서 무효화를 안 하므로, 그 자리에 닿는 픽스처는 「제품과 다른 길을
/// 재고 있다」는 뜻이다. 조용히 갈라지느니 빨갛게 서는 편이 낫다.
fn adoptTurnLikeProduct(
    client: *Client,
    stream: subscription_identity.LocalStreamId,
    frames: [][]u8,
) !bool {
    switch (client.tryAdoptSubscriptionTurn(stream, frames, null)) {
        .admitted => return true,
        .rejected => {
            if (!client.isClosing()) {
                const tracker = client.trackers.get(stream) orelse {
                    _ = client.closeAndReject(.socket_error);
                    return false;
                };
                client.invalidateSubscriptionOutput("invalidate_turn_rejected", stream, tracker);
            }
            return false;
        },
        .deferred_global_pressure, .deferred_resync => return error.NotTheProductPath,
    }
}

/// 가짜 producer 위에 GUI 연결 하나를 세우고 stream 1 을 observer 로 붙인다(socketpair 만, host 없음).
const FrontierTickHarness = struct {
    fds: [2]c_int,
    registry_value: registry.TerminalRuntimeRegistry,
    subscriptions: subscription_identity.Table,
    reactor: *slot_mod.ReactorCore,
    runtime_ops: server.FakeRuntimeOps,
    client: *Client,

    fn init(h: *FrontierTickHarness, skew_resync_snapshot: bool) !void {
        const testing = std.testing;
        try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &h.fds));
        h.registry_value = registry.TerminalRuntimeRegistry.init(testing.allocator);
        _ = try h.registry_value.register(0xAA, 80, 24);
        h.subscriptions = subscription_identity.Table.init(testing.allocator);
        h.reactor = try slot_mod.ReactorCore.create(testing.allocator);
        h.runtime_ops = .{};
        var ops = h.runtime_ops.ops();
        if (skew_resync_snapshot) {
            frontier_resync_skew_inner = ops.snapshot;
            ops.snapshot = frontierResyncSkewedSnapshot;
        }
        h.client = try Client.create(
            testing.allocator,
            h.fds[0],
            h.reactor,
            83,
            &h.registry_value,
            &h.subscriptions,
            .{ .runtime_ops = ops },
        );
        try sendTestFrame(h.fds[1], .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"gui\"}");
        h.client.readReady(1);
        try sendTestFrame(h.fds[1], .request, 2, "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"observer\"}}");
        h.client.readReady(2);
        try h.drain();
        try testing.expect(!h.client.isClosing());
    }

    fn deinit(h: *FrontierTickHarness) void {
        h.client.destroy();
        h.reactor.destroy();
        h.subscriptions.deinit();
        h.registry_value.deinit();
        _ = c.close(h.fds[1]);
    }

    fn drain(h: *FrontierTickHarness) !void {
        const slot = try h.reactor.get(h.client.admission);
        try slot.consumeWritten(slot.pending_bytes);
    }

    fn changeAndTick(h: *FrontierTickHarness, now: u64) void {
        h.runtime_ops.screen_change_token.revision += 1;
        _ = h.client.beginProducerSweep(now);
        h.client.tick(now);
    }

    fn trackerState(h: *FrontierTickHarness) !slot_mod.ScreenState {
        const slot = try h.reactor.get(h.client.admission);
        return slot.screenState(h.client.trackers.get(1) orelse return error.TestUnexpectedResult);
    }
};

// 한 스트림의 frontier 가 어긋나도 **연결은 산다**(2026-09-28 — 한 탭의 어긋남이 창의 탭 16 개를 끊었다).
// 그 스트림만 무효화되고, 클라이언트가 `runtime.resync` 로 되묻자 새 세대 스냅샷으로 다시 맞춰진다. 진단 줄의
// 값도 그대로 남는다(닫힘과 같은 한 줄). producer 는 가짜, socketpair 만, host 없음.
test "tick 은 frontier 가 어긋난 스트림만 무효화하고 연결을 살려 resync 로 복구한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    var h: FrontierTickHarness = undefined;
    try h.init(false);
    defer h.deinit();

    // 정상 tick: seq 1 gen 0 commit.
    h.changeAndTick(10);
    try testing.expect(!h.client.isClosing());
    try testing.expectEqual(@as(u64, 1), h.client.connection.attachments.get(1).?.screen_sequence);
    try h.drain();

    // gen 만 다른 delta — **닫지 않는다.** 기록은 그 값을 말하고, 그 스트림만 무효화된다.
    h.runtime_ops.frontier_generation = 4;
    h.changeAndTick(20);
    try testing.expect(!h.client.isClosing());
    var buf: [collect_failure.line_capacity]u8 = undefined;
    try testing.expectEqualStrings(
        "session host collect failed: site=delta_seq_mismatch err=- runtime=000000000000000000000000000000aa seq=2->2 gen=0->4 snapshot=0 send=11",
        collect_failure.render(&buf, collect_failure.last()),
    );
    try testing.expectEqual(slot_mod.ScreenState.invalidated, try h.trackerState());
    // 실패는 commit 된 frontier 를 안 옮긴다.
    try testing.expectEqual(@as(u64, 1), h.client.connection.attachments.get(1).?.screen_sequence);
    try testing.expectEqual(@as(u64, 0), h.client.connection.attachments.get(1).?.screen_generation);
    try h.drain();

    // 클라이언트가 무효화 알림을 받고 되묻는다 → 다음 tick 이 새 세대 스냅샷으로 다시 맞춘다.
    try sendTestFrame(h.fds[1], .request, 3, "{\"method\":\"runtime.resync\",\"params\":{\"stream_id\":1}}");
    h.client.readReady(30);
    try h.drain();
    try testing.expect(h.client.connection.resyncPending(1));
    h.changeAndTick(40);
    try testing.expect(!h.client.isClosing());
    try testing.expectEqualStrings("-", collect_failure.last().site);
    try testing.expectEqual(@as(u64, 4), h.client.connection.attachments.get(1).?.screen_generation);
    try testing.expectEqual(@as(u64, 2), h.client.connection.attachments.get(1).?.screen_sequence);
}

var frontier_resync_skew_inner: ?*const fn (ctx: *anyopaque, runtime_id: u128, sequence: u64, allocator: std.mem.Allocator) anyerror!server.ProjectedSnapshot = null;
fn frontierResyncSkewedSnapshot(ctx: *anyopaque, runtime_id: u128, sequence: u64, allocator: std.mem.Allocator) anyerror!server.ProjectedSnapshot {
    var out = try frontier_resync_skew_inner.?(ctx, runtime_id, sequence, allocator);
    if (sequence != 0) out.frontier.sequence = sequence + 7; // attach(0)은 두고 resync 스냅샷만 비튼다
    return out;
}

// **resync 스냅샷 자체가 어긋나면 닫는다.** 스냅샷으로도 못 맞추는 스트림을 다시 무효화하면 같은 자리를 돈다 —
// 무한 재시도 대신 예전처럼 닫되, 이름이 따로 있어 「resync 도 실패했다」로 읽힌다.
test "tick 은 resync 스냅샷까지 frontier 가 어긋나면 무한 재시도 대신 닫는다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    var h: FrontierTickHarness = undefined;
    try h.init(true); // 하네스의 가짜 producer 스냅샷을 감싸 resync 스냅샷만 sequence 를 비튼다
    defer h.deinit();
    defer frontier_resync_skew_inner = null;

    // 무효화 → resync 요청 → 스냅샷이 어긋난다.
    h.runtime_ops.frontier_generation = 4;
    h.changeAndTick(10); // 첫 delta 에서 gen 이 어긋나거나(무효화) 정상 — 어느 쪽이든 다음이 resync 다
    try h.drain();
    try sendTestFrame(h.fds[1], .request, 3, "{\"method\":\"runtime.resync\",\"params\":{\"stream_id\":1}}");
    h.client.readReady(20);
    try h.drain();
    h.changeAndTick(30);
    try testing.expect(h.client.isClosing());
    try testing.expectEqualStrings("tick_frontier_resync_failed", h.client.closeSite());
    try testing.expectEqualStrings("snapshot_seq_mismatch", collect_failure.last().site);
}
