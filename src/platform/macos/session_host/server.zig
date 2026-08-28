//! session-host **connection dispatch state machine**(§10 hello·command 순서). 한 client connection이 보낸 MRSH
//! frame을 받아 hello를 협상하고 command를 `TerminalRuntimeRegistry`/`RuntimeOps`로 dispatch해 응답 frame을 만든다.
//!
//! 이 파일은 **순수 상태 기계**다 — socket·fd·프로세스를 모른다(platform import 0). 실제 unix socket bind/accept/
//! peer-cred와 read/write loop는 P3-d1의 platform 통합 층이 이 `Connection.handleFrame`을 구동하고, on-demand
//! detached-helper launch와 `maru-sessiond` entrypoint는 P3-d2다. 이렇게 나눠야 hello/command 계약을 실 socket 없이
//! non-macOS에서 TDD하고, control-plane(`maru.control.v1`)과 wire·ID를 섞지 않는다(§10).
//!
//! 현재 major 규칙:
//!   - connection의 첫 frame은 반드시 `hello`다. 아니면 protocol error로 connection을 닫는다(runtime은 유지).
//!   - header major는 현재 MRSH major와 같아야 하며, client `{protocol_min, protocol_max}`도 그 major를 포함해야 한다.
//!   - 초기 d1 read command 뒤 spawn/attach와 same-UID admin mutation이 추가됐다. canonical `RequestPolicy`가
//!     admin read/mutation과 GUI privileged command를 한 곳에서 분류한다.

const std = @import("std");
const protocol = @import("protocol.zig");
const framing = @import("framing.zig");
const reg = @import("registry.zig");
const core_command_wire = @import("core_command_wire.zig");
const screen_stream = @import("maru").session.screen_stream;
const host_identity = @import("host_identity.zig");
const upgrade_wire = @import("upgrade_wire.zig");
const connection_slot = @import("connection_slot.zig");
const subscription_identity = @import("subscription_identity.zig");
const catchup_barrier_contract = @import("catchup_barrier_contract.zig");
const runtime_metadata_wire = @import("runtime_metadata_wire.zig");

pub const HostStatus = struct {
    manifest_capable: bool = false,
    upgrade_capable: bool = false,
    build_id: []const u8 = "unknown",
    protocol_major: u16 = protocol.version_major,
    screen_codec_version: u16 = screen_stream.codec_version,
    upgrade_epoch: u64 = 0,
    /// lifecycle ready/restoring/rollback/commit 전이마다 증가하는 daemon-local ABA token.
    authority_generation: u64 = 1,
    /// 현재 owner reactor에 admitted된 연결 수. listener/PTY 수가 아니라 GUI/CLI/admin socket 수다.
    client_count: usize = 0,
    lifecycle: host_identity.Lifecycle = .ready,
};

/// hello가 밝히는 client 종류. GUI window인지 CLI(`maru attach`)인지 — 권한/표시에 쓴다(§9).
pub const ClientKind = enum { gui, cli, admin, unknown };

/// Single-owner daemon lease for the hidden one-shot admin traffic class. This is a quota, not an
/// authentication identity; peer credentials remain the security boundary.
pub const AdminAdmission = struct {
    active: bool = false,

    pub fn acquire(self: *AdminAdmission) bool {
        if (self.active) return false;
        self.active = true;
        return true;
    }

    pub fn release(self: *AdminAdmission) void {
        std.debug.assert(self.active);
        self.active = false;
    }
};

pub const UpgradePreflight = struct {
    ctx: *anyopaque,
    reserve: *const fn (ctx: *anyopaque) bool,
    cancel: *const fn (ctx: *anyopaque) void,
};

/// `runtime.spawn`의 중립 파라미터(server가 JSON에서 파싱해 넘긴다). host가 이 argv/크기로 실 PTY를 띄운다.
pub const RuntimeSpawnParams = struct {
    /// `[command, args...]` — argv[0]은 실행 파일 경로. server는 JSON string 배열만 파싱하고 프로세스는 host가 띄운다.
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    login: bool = false,
    env: []const []const u8 = &.{},
    // null은 legacy `runtime.spawn`의 "host process environ 상속" 의미다. `runtime.spawn_full`은 GUI가 캡처한
    // snapshot을 non-null로 보내 daemon 생성 시점 환경으로 바뀌지 않게 한다.
    parent_env: ?[]const []const u8 = null,
    env_overrides: []const []const u8 = &.{},
    term: []const u8 = "xterm-256color",
    /// `SpawnRequest.shell_integration_dir`의 RPC 짝. **wire 키는 여전히 `"zdotdir"`다** — 아래 파싱이 그
    /// 문자열을 직접 쓴다(필드 이름과 독립, docs/windows-platform.md §4.2).
    shell_integration_dir: ?[]const u8 = null,
    ssh_integration_bin: ?[]const u8 = null,
    pane_id: ?u64 = null,
    cols: u16,
    rows: u16,
    initial_config: ?core_command_wire.Command.RuntimeConfig = null,
    initial_notification: ?NotificationConfigSnapshot = null,
};

pub const NotificationConfigSnapshot = struct {
    config_generation: u64,
    notifications_osc: bool,
    display_label: []const u8,
};

/// attach된 observe-capability client에만 보내는 화면 외 runtime full-state. public `runtime.list/get` redacted metadata와
/// 섞지 않는다. 모든 slice는 caller 소유이며 `deinit`으로 회수한다. full-state라 중간 event가 coalesce되어 revision이
/// 건너뛰어도 최신 한 건만 적용하면 복구된다.
pub const RuntimeObservation = struct {
    pub const Process = struct {
        pid: i32,
        name: []u8,
    };

    cwd: []u8,
    window_title: []u8,
    ssh_remote_dest: ?[]u8,
    semantic_state: u8,
    alt_active: bool,
    app_cursor_keys: bool,
    app_keypad: bool,
    kitty_flags: u5,
    alternate_scroll: bool,
    mouse_tracking: bool,
    /// 마우스 트래킹 **모드**(`terminal.MouseTracking`의 ordinal — 0=none,1=x10,2=normal,3=button,4=any).
    /// 위 `mouse_tracking`은 "켜져 있는가"만 알려주는 레거시 bool이라 **1003(any-event motion)을 구분할 수 없다** —
    /// 그래서 host-backed 세션에서 버튼 없는 motion 리포트가 통째로 빠져 있었다. 이 필드가 모드의 단일 출처이고,
    /// bool은 구 client 호환을 위해 계속 싣는 미러다(consumer는 mode를 우선 보고 없을 때만 bool로 폴백).
    mouse_tracking_mode: u8 = 0,
    bracketed_paste: bool,
    /// BEL 누적 횟수(monotonic). client가 마지막에 본 값과 다르면 벨을 울린다 — core의 소비형 bool을 그대로
    /// 실으면 full-state 관측이 true→true 전이를 잃어 둘째 벨을 놓치기 때문이다.
    bell_count: u64 = 0,
    /// OSC 52 요청 누적 seq(write/read 각각). client가 마지막에 본 값보다 크면 그 요청을 처리한다 —
    /// 소비형 플래그는 full-state 관측에서 둘째 요청을 잃는다(벨과 같은 이유).
    clipboard_write_seq: u64 = 0,
    clipboard_read_seq: u64 = 0,
    /// 마지막 read 요청의 target(Pc). 응답 echo용이라 짧아 관측에 그대로 싣는다(write 텍스트는 커서 RPC로 뺀다).
    clipboard_read_target: []const u8 = "",
    observer_generation: u64,
    title_generation: u32,
    cols: u16,
    rows: u16,
    foreground_available: bool,
    foreground_pgid: ?i32,
    /// 이 runtime PTY의 **자식 뿌리 pid**(host가 fork한 `login`/셸). GUI가 상태바 리소스 항목에서 그 트리를
    /// 직접 재는 유일한 출처다 — PTY가 host 안에 살아 GUI의 트리 walk가 닿지 않는다(docs/status-bar.md §4.1).
    /// **구 host면 0**이고, 그때 GUI는 표본을 못 얻어 그 탭 행이 `—`로 남는다(기존 동작과 같다).
    child_pid: i32 = 0,
    /// 그 자식을 소유한 **host 프로세스 자신의 pid**. GUI가 데몬 자체의 오버헤드를 "모든 창 공유" 행으로
    /// 세는 데 쓴다. 자식 트리(`child_pid`)와 **서로소**라 이중 계산이 없다 — 자식은 host의 직속 자식이고
    /// 이 값은 host 자기 자신만 가리킨다(트리를 훑지 않는다).
    host_pid: i32 = 0,
    processes: []Process,

    pub fn deinit(self: *RuntimeObservation, allocator: std.mem.Allocator) void {
        allocator.free(self.cwd);
        allocator.free(self.window_title);
        if (self.ssh_remote_dest) |dest| allocator.free(dest);
        for (self.processes) |p| allocator.free(p.name);
        allocator.free(self.processes);
        allocator.free(self.clipboard_read_target);
        self.* = undefined;
    }
};

pub const CachedRuntimeObservation = struct {
    canonical_json: []const u8,
    change_token: u64,
};

pub const ObservationRequest = union(enum) {
    current,
    cadence_epoch: u64,
    fresh,
};

const RawCanonicalObservation = struct {
    bytes: []const u8,

    pub fn jsonStringify(self: RawCanonicalObservation, js: anytype) !void {
        try js.beginWriteRaw();
        try js.writer.writeAll(self.bytes);
        js.endWriteRaw();
    }
};

pub fn observationWireValid(observation: RuntimeObservation) bool {
    if (observation.mouse_tracking_mode > 4 or
        observation.processes.len > runtime_metadata_wire.max_process_entries or
        !std.unicode.utf8ValidateSlice(observation.cwd) or
        !std.unicode.utf8ValidateSlice(observation.window_title) or
        !std.unicode.utf8ValidateSlice(observation.clipboard_read_target))
        return false;
    if (observation.ssh_remote_dest) |dest|
        if (!std.unicode.utf8ValidateSlice(dest)) return false;
    if (!observation.foreground_available and
        (observation.foreground_pgid != null or observation.processes.len != 0))
        return false;
    var aggregate: usize = 0;
    const strings = [_][]const u8{
        observation.cwd,
        observation.window_title,
        observation.ssh_remote_dest orelse "",
        observation.clipboard_read_target,
    };
    for (strings) |value|
        aggregate = std.math.add(usize, aggregate, value.len) catch return false;
    if (aggregate > protocol.max_control_json) return false;
    for (observation.processes) |process| {
        if (process.name.len > 128 or !std.unicode.utf8ValidateSlice(process.name))
            return false;
        aggregate = std.math.add(usize, aggregate, process.name.len) catch return false;
    }
    return aggregate <= protocol.max_control_json;
}

pub fn canonicalizeObservation(
    allocator: std.mem.Allocator,
    observation: RuntimeObservation,
) error{ InvalidObservation, OutOfMemory }![]u8 {
    if (!observationWireValid(observation)) return error.InvalidObservation;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    js.write(observation) catch return error.OutOfMemory;
    return allocator.dupe(u8, out.written()) catch error.OutOfMemory;
}

/// host의 실 runtime 소유(spawn/terminate)를 dispatch가 위임하는 vtable(`runtime.PtyIo` 선례, layering-and-portability.md
/// §3.1). server.zig는 이 계약만 알아 codec 순수성을 지키고, host 측 `runtime_manager`(app `InProcessTermBackend` 재사용)가
/// 이를 구현한다. read-only host(테스트·조회 전용)는 null이라 spawn/terminate 요청이 unauthorized로 떨어진다.
pub const RuntimeOps = struct {
    ctx: *anyopaque,
    /// 실 PTY runtime을 띄우고 발급한 `runtime_id`(u128, §4)를 돌려준다. 실패는 anyerror(host 내부 오류로 매핑).
    spawn: *const fn (ctx: *anyopaque, params: RuntimeSpawnParams) anyerror!u128,
    /// runtime을 종료한다(§8 `runtime end`). 멱등 — 없는 id는 무시.
    terminate: *const fn (ctx: *anyopaque, runtime_id: u128) void,
    /// controller가 보낸 terminal input을 runtime PTY로 보낸다(§9 `input` capability). registry가 controller임을 확인한 뒤 호출.
    write_input: *const fn (ctx: *anyopaque, runtime_id: u128, bytes: []const u8) anyerror!void,
    /// canonical PTY size를 실 `TerminalCore`+`TIOCSWINSZ`에 적용한다(§9). registry가 controller/sequence를 검증한 뒤 호출.
    /// 실패가 부분 core/PTY mutation 뒤 발생할 수 있는 backend는 반환 전에 runtime을 fail-stop terminate해 실제
    /// allocation을 회수해야 한다. 그러면 registry transaction은 commit하지 않고 남은 runtime만 계속 정확히 계상한다.
    resize: *const fn (ctx: *anyopaque, runtime_id: u128, cols: u16, rows: u16) anyerror!void,
    /// runtime의 현재 화면을 §12 screen_stream 레코드 스트림(length-prefixed)으로 투영한다(attach 첫 snapshot). caller가
    /// 소유하는 바이트를 돌려주며(host가 core lock 아래 투영), server가 이를 snapshot_chunk frame으로 나눠 보낸다.
    snapshot: *const fn (ctx: *anyopaque, runtime_id: u128, sequence: u64, allocator: std.mem.Allocator) anyerror!ProjectedSnapshot,
    /// `base`(client가 마지막으로 받은 full snapshot 바이트) 대비 현재 화면 변화를 계산한다(§9 delta). host가 core lock
    /// 아래 diff하고 `StreamUpdate`를 돌려준다 — `send`(delta 또는 fresh snapshot)와 다음 diff의 base가 될 현재 snapshot.
    delta: *const fn (ctx: *anyopaque, runtime_id: u128, base: []const u8, sequence: u64, allocator: std.mem.Allocator) anyerror!StreamUpdate,
    /// Runtime-owner screen mutation token. When present, an equal committed token proves that
    /// opening the delta projector would only rebuild the same base. Null keeps the legacy test
    /// seam polling until its backend adopts P4 E3a.
    screen_change_token: ?*const fn (
        ctx: *anyopaque,
        runtime_id: u128,
    ) anyerror!ScreenChangeToken = null,
    /// Pending notification을 지우지 않고 off-side JSON과 generation token으로 복제한다. server가 response를
    /// canonical control queue에 admission한 뒤에만 `notification_commit`으로 같은 generation을 소비한다.
    notification_peek: *const fn (
        ctx: *anyopaque,
        runtime_id: u128,
        stable_delivery: bool,
        allocator: std.mem.Allocator,
    ) anyerror!NotificationSnapshot,
    notification_commit: *const fn (
        ctx: *anyopaque,
        runtime_id: u128,
        generation: ?u64,
    ) bool,
    notification_config_update: ?*const fn (
        ctx: *anyopaque,
        runtime_id: u128,
        current_controller_generation: u64,
        snapshot: NotificationConfigSnapshot,
    ) anyerror!bool = null,
    /// host-authoritative core command. JSON은 server에서 strict bounded DTO로 검증하고, runtime_manager가 내부
    /// `session.CoreCommand`로 명시 변환해 reader queue에 넣는다.
    core_command: *const fn (ctx: *anyopaque, runtime_id: u128, command: core_command_wire.Command) anyerror!void,
    /// §6b 원격 선택 복사: client가 보낸 뷰포트 선택 span을 host `TerminalCore`에 적용해 `extractSelection`(로컬과 같은
    /// 함수, soft-wrap 이음·스크롤백 충실)으로 텍스트를 뽑아 JSON `{text}`로 준다. host가 콘텐츠를 소유하므로(client는 렌더만)
    /// 선택 의미론이 한 곳(host core)에 산다. codec 순수성 위해 span은 primitive(SelectSpan), runtime_manager가 core 연산으로 매핑.
    selected_text: *const fn (ctx: *anyopaque, runtime_id: u128, span: SelectSpan, allocator: std.mem.Allocator) anyerror![]u8,
    /// §6b-2 단어/줄 선택: client가 (op, row, col)을 보내면 host가 **콘텐츠를 아는 자기 core**로 경계를 계산해
    /// (`selectWordAt`/`selectLineAt`) 그 뷰포트 선택 span을 JSON으로 돌려준다(client는 그 span을 placeholder에 적용해
    /// 하이라이트). 빈 placeholder는 단어/줄 경계를 모르므로 host가 계산 = 선택 의미론 host 단일 출처. codec 순수라 op는 문자열.
    select_op: *const fn (ctx: *anyopaque, runtime_id: u128, op: []const u8, row: u16, col: u16, separators_hex: []const u8, allocator: std.mem.Allocator) anyerror![]u8,
    /// §6c 원격 검색: client가 보낸 검색어(hex — 임의 텍스트라 escape 회피)로 host가 **콘텐츠·스크롤백을 아는 자기 core**에서
    /// `findMatches`(로컬과 같은 함수)로 매치를 찾고, 보이는 매치를 `matchViewportSpan`으로 클립해 JSON `{count, cur:[...], spans:[...]}`로
    /// 준다. count=전체 매치 수, spans=보이는 **비현재** 매치의 flat 좌표, cur=현재 매치(index `cur_index`)의 뷰포트 span(안 보이면 `[]`).
    /// §6c-2 네비: `scroll`이면 host가 현재 매치의 abs 위치로 `scrollToAbs`해 화면을 이동한다(client가 그 매치를 보게).
    find: *const fn (ctx: *anyopaque, runtime_id: u128, query_hex: []const u8, cur_index: u32, scroll: bool, allocator: std.mem.Allocator) anyerror![]u8,
    /// host 실제 core/PTY의 cwd/title/semantic/OSC5379/foreground를 한 번에 owned copy한다. screen snapshot과 분리된
    /// attach/event full-state이며 public runtime.list/get에는 노출하지 않는다.
    observation: *const fn (ctx: *anyopaque, runtime_id: u128, allocator: std.mem.Allocator) anyerror!RuntimeObservation,
    /// Subscription delivery path. Returned canonical JSON is borrowed from the runtime-global
    /// cache and remains valid until the next call that refreshes the same runtime.
    cached_observation: *const fn (
        ctx: *anyopaque,
        runtime_id: u128,
        request: ObservationRequest,
    ) anyerror!CachedRuntimeObservation,
    /// host-backed 마우스 리포팅(§ 입력 패리티): client가 마우스 이벤트를 보내면 host가 **자기 core의 mouse_tracking/
    /// mouse_format**으로 SGR/x10 리포트를 인코딩해 PTY로 흘린다(로컬 reader가 report_mouse core command를 적용 후
    /// pendingResponse를 흘리는 것과 동형 — 인코딩 모드가 host에만 있으므로 host가 인코딩·주입한다). codec 순수라
    /// primitive `MouseReport`만 넘기고 runtime_manager가 CoreCommand로 매핑·적용·flush한다.
    report_mouse: *const fn (ctx: *anyopaque, runtime_id: u128, report: MouseReport) anyerror!void,
    /// 원격 Cmd+클릭 링크 열기(§링크 감지): client가 (row, col)을 보내면 host가 **콘텐츠·cwd·파일시스템을 아는 자기
    /// core**로 `extractUrlAt`(추출 + cwd resolve + 존재 stat)을 수행해 열 대상을 돌려준다. hover 밑줄은 screen stream의
    /// `link_spans`로 오지만, 여는 대상은 스크롤백 soft-wrap 이음과 host FS 검증이 필요해 RPC다.
    /// docs/link-detection.md §원격(host-backed) 세션.
    link_at: *const fn (ctx: *anyopaque, runtime_id: u128, row: u16, col: u16, scopes: u8, allocator: std.mem.Allocator) anyerror![]u8,
    /// OSC 52 write 요청 텍스트를 host에서 가져온다(가져가면 host 버퍼는 비운다). 텍스트가 커서 관측 full-state에
    /// 실을 수 없어 별도 RPC다 — client는 관측의 `clipboard_write_seq` 증가를 보고 이걸 부른다.
    /// 정책(`osc52` write allow)과 실제 NSPasteboard 쓰기는 client가 한다(§기능 배치 규칙).
    clipboard_write: *const fn (ctx: *anyopaque, runtime_id: u128, allocator: std.mem.Allocator) anyerror![]u8,
    /// 이 runtime에 **즉시 전달해야 할 이벤트**(BEL·OSC 52)가 core에 대기 중인가. 관측은 평소 약 100ms 주기로
    /// 폴링하는데(foreground process처럼 폴링 말고는 알 방법이 없는 상태 때문), 벨·클립보드는 발생 시점을
    /// host가 정확히 아는 **이벤트**라 그 주기를 기다릴 이유가 없다. true면 다음 serve tick(약 20ms)에 바로
    /// 관측을 만들어 push한다 — 통로는 그대로 두고 트리거만 앞당긴다.
    observation_urgent: *const fn (ctx: *anyopaque, runtime_id: u128) bool,
};

pub const ScreenChangeToken = struct {
    incarnation: u64,
    revision: u64,
};

pub const NotificationSnapshot = struct {
    body: []u8,
    generation: ?u64,
};

/// host-backed 마우스 리포트 wire payload(primitive — codec 순수). `core_command.MouseReport`의 미러다(codec은
/// session/core_command을 안 import하려고 필드만 복제 — runtime_manager가 CoreCommand로 매핑).
pub const MouseReport = struct {
    button: u8,
    col: u16,
    row: u16,
    x_px: u16,
    y_px: u16,
    pressed: bool,
    motion: bool,
    mods: u8,
};

/// §6b 원격 선택 복사용 뷰포트 선택 span(primitive — codec 순수 유지). client가 보고 있는 화면(host의 뷰포트) 기준
/// 시작/끝 셀 좌표와 block(직사각형) 여부. host가 `selectionStart/Extend`로 자기 core에 적용(뷰포트→abs는 host view_offset 기준).
pub const SelectSpan = struct { sr: u16, sc: u16, er: u16, ec: u16, block: bool, all: bool = false, authoritative: bool = false };

/// `RuntimeOps.delta` 결과. `send`/`new_base`는 caller 소유이고 **항상 별개 버퍼**다(둘 다 free해도 안전). `send.len==0`이면
/// 변화 없음(아무것도 안 보냄). `is_snapshot`이면 `send`가 fresh snapshot(snapshot_chunk로, client가 화면을 교체), 아니면
/// delta(delta_chunk로, client가 증분 적용). `new_base`는 다음 diff의 base가 될 현재 full snapshot이다.
pub const StreamUpdate = struct {
    send: []u8,
    is_snapshot: bool,
    new_base: []u8,
    /// RuntimeManager가 화면 core lock을 보유한 projection turn에서 발급한다. server는 encoded
    /// record를 다시 읽거나 mutable Subscription을 재조회해 barrier target을 만들지 않는다.
    frontier: catchup_barrier_contract.ScreenFrontier,
};

pub const ProjectedSnapshot = struct {
    bytes: []u8,
    frontier: catchup_barrier_contract.ScreenFrontier,
};

/// Host issuer가 projection과 fixed wire barrier를 같은 owner turn에 묶는 final-address 준비물이다.
/// Reactor queue admission 전에는 `HostState`를 바꾸지 않으며, product socket owner가 PID/process
/// seal을 결속한 뒤 exact 한 번만 commit할 수 있다.
pub const PreparedCatchupBatch = struct {
    self_addr: usize = 0,
    active_raw: u8 = 0,
    pid: u32 = 0,
    process_nonce: u64 = 0,
    owner_addr: usize = 0,
    owner_connection: connection_slot.ConnectionKey = .{ .monotonic_id = 0, .slot_generation = 0 },
    owner_thread_id: u64 = 0,
    before: catchup_barrier_contract.HostState,
    after: catchup_barrier_contract.HostState,
    barrier: catchup_barrier_contract.Barrier,
    now_ns: u64,

    pub fn bindFinal(
        self: *PreparedCatchupBatch,
        pid: u32,
        process_nonce: u64,
        owner_addr: usize,
        owner_connection: connection_slot.ConnectionKey,
        owner_thread_id: u64,
    ) bool {
        if (self.self_addr != 0 or self.active_raw != 0 or pid == 0 or process_nonce == 0 or
            owner_addr == 0 or !owner_connection.valid() or owner_thread_id == 0)
            return false;
        self.self_addr = @intFromPtr(self);
        self.pid = pid;
        self.process_nonce = process_nonce;
        self.owner_addr = owner_addr;
        self.owner_connection = owner_connection;
        self.owner_thread_id = owner_thread_id;
        self.active_raw = 1;
        return true;
    }
};

pub const catchup_host_expiry_ns: u64 = 2 * std.time.ns_per_s;

/// `handleFrame`이 caller(socket write loop)에게 지시하는 것. `reply`/`reply_and_close`의 바이트는 **caller 소유**다
/// (socket에 write한 뒤 free). `close`는 응답 없이 connection을 닫으라는 뜻이다(runtime에는 손대지 않는다).
pub const Action = union(enum) {
    pub const PreparedCatchupArm = struct {
        self_addr: usize = 0,
        active_raw: u8 = 0,
        pid: u32 = 0,
        process_nonce: u64 = 0,
        reply: []u8,
        stream: subscription_identity.LocalStreamId,
        identity: catchup_barrier_contract.CatchupIdentity,
        now_ns: u64,
        expires_at_ns: u64,
        before: catchup_barrier_contract.HostState,
        after: catchup_barrier_contract.HostState,
        result: catchup_barrier_contract.HostState.ArmResult,

        pub fn bindFinal(self: *PreparedCatchupArm, pid: u32, process_nonce: u64) bool {
            if (self.self_addr != 0 or self.active_raw != 0 or pid == 0 or process_nonce == 0)
                return false;
            self.self_addr = @intFromPtr(self);
            self.pid = pid;
            self.process_nonce = process_nonce;
            self.active_raw = 1;
            return true;
        }
    };
    pub const UpgradeAccepted = struct {
        bytes: []u8,
        attempt_id: u128,
    };
    pub const AdminTerminateAccepted = struct {
        bytes: []u8,
        runtime_id: u128,
    };
    pub const PreparedAttach = struct {
        reply: []u8,
        output: CollectedOutput,
    };
    pub const PreparedReply = struct {
        reply: []u8,
        output: CollectedOutput,
    };
    pub const PreparedNotification = struct {
        reply: []u8,
        runtime_id: u128,
        generation: ?u64,
    };
    pub const ControllerTransitionRequested = struct {
        pub const Revocation = struct {
            subscription: subscription_identity.SubscriptionId,
            frame: []u8,
        };
        prepared: reg.PreparedControllerTransition,
        success_reply: []u8,
        stale_reply: []u8,
        exhausted_reply: []u8,
        revocation: ?Revocation = null,
    };
    pub const ResizeRequested = struct {
        prepared: reg.PreparedResize,
        runtime_id: u128,
        success_reply: []u8,
        internal_reply: []u8,
        exhausted_reply: []u8,
        event_body: ?[]u8,
    };

    reply: []u8,
    reply_and_close: []u8,
    /// Public admin mutation은 reply frame이 owner outbound queue에 들어간 뒤에만 실행한다. socket adapter가
    /// admission에 실패하면 bytes만 회수하고 mutation은 0이다.
    admin_terminate_accepted: AdminTerminateAccepted,
    /// Socket adapter가 bytes 전량 write에 성공한 뒤 completed marker를 publish하고, fd close/active count 감소가 끝난
    /// 후에만 daemon outer loop가 attempt를 take한다.
    upgrade_accepted: UpgradeAccepted,
    close,
    /// 응답 없이 connection을 유지한다(input_bytes 같은 fire-and-forget stream frame 처리 후). caller는 아무것도 write하지 않는다.
    none,
    /// The first valid resync ACK changed connection authority. The socket owner uses its injected
    /// monotonic dispatch time to arm the recovery deadline; duplicates remain `.none`.
    resync_ack: subscription_identity.LocalStreamId,
    /// 여러 frame을 **순서대로** write하고 connection을 유지한다(attach 응답 + snapshot_chunk* — §10 attach 순서). 바깥
    /// 슬라이스와 각 `[]u8`은 caller 소유다(순서대로 write한 뒤 각 frame free, 마지막에 바깥 슬라이스 free). `frames[0]`이
    /// 응답 frame, 이후가 snapshot_chunk들이다.
    frames: [][]u8,
    /// Product attach keeps projection bases prepared until the owner admits both the response and
    /// the complete snapshot batch.
    prepared_attach: PreparedAttach,
    /// A response that advances retained metadata only after control-queue admission.
    prepared_reply: PreparedReply,
    catchup_arm_requested: PreparedCatchupArm,
    prepared_notification: PreparedNotification,
    /// Cross-connection authority mutation is deliberately not executed in `Connection`. The
    /// daemon poll owner resolves the global subscription, atomically admits every control frame,
    /// and only then commits the prepared registry transition in the same dispatch turn.
    controller_transition_requested: ControllerTransitionRequested,
    /// Canonical resize and its all-subscription event are committed only by the daemon owner
    /// after every destination queue has admitted the complete response/event batch.
    resize_requested: ResizeRequested,
};

pub const OutboundClass = union(enum) {
    control,
    subscription: struct {
        stream: subscription_identity.LocalStreamId,
        kind: enum { snapshot, delta, event, barrier },
    },
};

/// Single classification authority for already encoded server output. Socket adapters must not
/// guess from JSON method names; screen stream identity is carried by the MRSH header itself.
pub fn classifyOutbound(bytes: []const u8) error{InvalidFrame}!OutboundClass {
    if (bytes.len < protocol.header_size) return error.InvalidFrame;
    const header_bytes: *const [protocol.header_size]u8 = @ptrCast(bytes.ptr);
    const header = protocol.Header.decode(header_bytes) catch return error.InvalidFrame;
    if (bytes.len != protocol.header_size + @as(usize, header.payload_len))
        return error.InvalidFrame;
    return switch (header.kind) {
        .snapshot_chunk => .{ .subscription = .{
            .stream = header.stream_id,
            .kind = .snapshot,
        } },
        .delta_chunk => .{ .subscription = .{
            .stream = header.stream_id,
            .kind = .delta,
        } },
        .screen_frontier_barrier => if (header.request_id == 0 and header.stream_id != 0 and
            header.flags == 0 and header.payload_len == protocol.screen_frontier_barrier_payload_size) .{ .subscription = .{
            .stream = header.stream_id,
            .kind = .barrier,
        } } else error.InvalidFrame,
        // Stream-scoped events (currently runtime.metadata) belong to the subscription budget.
        // Connection-wide notices are encoded by the adapter and admitted explicitly as control.
        .event => if (header.stream_id != 0) .{ .subscription = .{
            .stream = header.stream_id,
            .kind = .event,
        } } else .control,
        else => .control,
    };
}

test "CR4a host barrier frame은 exact subscription header만 admit한다" {
    var bytes: [protocol.header_size + 97]u8 = @splat(0);
    const valid = (protocol.Header{
        .kind = .screen_frontier_barrier,
        .request_id = 0,
        .stream_id = 7,
        .payload_len = 96,
    }).encode();
    @memcpy(bytes[0..protocol.header_size], &valid);
    const classified = try classifyOutbound(bytes[0 .. protocol.header_size + 96]);
    switch (classified) {
        .subscription => |output| {
            try std.testing.expectEqual(@as(u64, 7), output.stream);
            try std.testing.expectEqual(.barrier, output.kind);
        },
        .control => return error.TestUnexpectedResult,
    }

    const hostile = [_]protocol.Header{
        .{ .kind = .screen_frontier_barrier, .request_id = 1, .stream_id = 7, .payload_len = 96 },
        .{ .kind = .screen_frontier_barrier, .request_id = 0, .stream_id = 0, .payload_len = 96 },
        .{ .kind = .screen_frontier_barrier, .flags = protocol.Flags.end_stream, .stream_id = 7, .payload_len = 96 },
        .{ .kind = .screen_frontier_barrier, .request_id = 0, .stream_id = 7, .payload_len = 95 },
        .{ .kind = .screen_frontier_barrier, .request_id = 0, .stream_id = 7, .payload_len = 97 },
    };
    for (hostile) |header| {
        const encoded = header.encode();
        @memcpy(bytes[0..protocol.header_size], &encoded);
        const len = protocol.header_size + @as(usize, header.payload_len);
        try std.testing.expectError(error.InvalidFrame, classifyOutbound(bytes[0..len]));
    }
}

pub const HandleError = error{OutOfMemory};

/// The reactor remains the sole accounting authority. The protocol state machine only carries the
/// stable reservation token between prepare and queue admission.
pub const ProjectionBudgetOps = struct {
    ctx: *anyopaque,
    prepare: *const fn (
        ctx: *anyopaque,
        stream: subscription_identity.LocalStreamId,
        upper_bound: usize,
    ) ?connection_slot.BaseReservation,
    commit: *const fn (
        ctx: *anyopaque,
        reservation: connection_slot.BaseReservation,
        actual: usize,
    ) void,
    rollback: *const fn (
        ctx: *anyopaque,
        reservation: connection_slot.BaseReservation,
    ) void,
    release: *const fn (
        ctx: *anyopaque,
        stream: subscription_identity.LocalStreamId,
    ) void,
};

pub const CollectedOutput = struct {
    allocator: std.mem.Allocator,
    stream: subscription_identity.LocalStreamId,
    frames: [][]u8,
    next_base: ?[]u8 = null,
    replace_base: bool = false,
    next_screen_sequence: ?u64 = null,
    next_screen_generation: ?u64 = null,
    next_screen_change_token: ?ScreenChangeToken = null,
    prepared_catchup: ?PreparedCatchupBatch = null,
    clear_resync: bool = false,
    next_observation_token: ?u64 = null,
    next_observation_revision: ?u64 = null,
    previous_observation_ticks: u8,
    base_reservation: ?connection_slot.BaseReservation = null,
    frames_taken: bool = true,
    finished: bool = false,

    pub fn takeFrames(self: *CollectedOutput) [][]u8 {
        std.debug.assert(!self.frames_taken and !self.finished);
        self.frames_taken = true;
        return self.frames;
    }

    pub fn commit(self: *CollectedOutput, connection: *Connection) void {
        std.debug.assert(!self.finished);
        const sub = connection.attachments.getPtr(self.stream) orelse {
            self.rollback(connection);
            return;
        };
        if (self.prepared_catchup) |*prepared| {
            // The queue owner consumes the final-address permit only after the complete
            // screen+barrier batch is admitted.  Catch-up state and the projected frontier are
            // one semantic commit: never advance either side when the permit is stale or copied.
            std.debug.assert(prepared.self_addr == @intFromPtr(prepared));
            std.debug.assert(prepared.active_raw == 0);
            std.debug.assert(std.meta.eql(sub.catchup, prepared.before));
        }
        const next_screen_len = if (self.replace_base)
            if (self.next_base) |base| base.len else 0
        else if (sub.base) |base| base.len else 0;
        const next_observation_len: usize = 0;
        const retained_len = std.math.add(
            usize,
            next_screen_len,
            next_observation_len,
        ) catch unreachable;
        if (self.base_reservation) |reservation| {
            connection.projection_budget.?.commit(
                connection.projection_budget.?.ctx,
                reservation,
                retained_len,
            );
            self.base_reservation = null;
        }
        if (self.replace_base) {
            if (sub.base) |old| connection.allocator.free(old);
            sub.base = self.next_base;
            self.next_base = null;
        }
        if (self.next_screen_sequence) |sequence| sub.screen_sequence = sequence;
        if (self.next_screen_generation) |generation| sub.screen_generation = generation;
        if (self.next_screen_change_token) |token| sub.screen_change_token = token;
        if (self.prepared_catchup) |*prepared| {
            sub.catchup = prepared.after;
        }
        if (self.clear_resync) {
            sub.resync_pending = false;
            sub.awaiting_resync_ack = false;
        }
        sub.unpublished_controller_generation = null;
        if (self.next_observation_token) |next| {
            sub.observation_token = next;
            self.next_observation_token = null;
            sub.observation_revision = self.next_observation_revision.?;
        }
        self.finishFrames();
        self.finished = true;
    }

    pub fn rollback(self: *CollectedOutput, connection: *Connection) void {
        if (self.finished) return;
        if (self.prepared_catchup) |*prepared| {
            // A bound permit that did not reach queue admission is terminally aborted.  Leaving
            // it active until stack destruction would make a rejected batch look replayable.
            prepared.active_raw = 0;
        }
        if (connection.attachments.getPtr(self.stream)) |sub|
            sub.observation_ticks = self.previous_observation_ticks;
        if (self.base_reservation) |reservation| {
            connection.projection_budget.?.rollback(
                connection.projection_budget.?.ctx,
                reservation,
            );
            self.base_reservation = null;
        }
        if (self.next_base) |owned| self.allocator.free(owned);
        self.finishFrames();
        self.finished = true;
    }

    fn finishFrames(self: *CollectedOutput) void {
        if (self.frames_taken) return;
        for (self.frames) |frame| self.allocator.free(frame);
        self.allocator.free(self.frames);
    }
};

/// 한 client connection의 상태. socket 하나당 하나. `host_id`는 server가 발급한 128-bit opaque(테스트는 고정 주입).
pub const Connection = struct {
    allocator: std.mem.Allocator,
    host_id: u128,
    registry: *reg.TerminalRuntimeRegistry,
    host_status: HostStatus = .{},
    /// 실 socket server에서는 accept 뒤 lifecycle이 바뀌어도 fresh host.info/inventory가 최신 authority를 읽는다.
    live_host_status: ?*const HostStatus = null,
    /// 실 runtime 소유 위임(host만 설정). null이면 read-only host라 spawn/terminate/input/resize가 unauthorized다.
    runtime_ops: ?RuntimeOps = null,
    /// `prepare`는 pending attempt 게시까지만 하고 즉시 반환해야 한다. Quiesce/exec는 reply-and-close와 gate lease
    /// release 뒤 daemon outer loop가 실행한다.
    upgrade_ops: ?upgrade_wire.Ops = null,
    upgrade_preflight: ?UpgradePreflight = null,
    state: State = .pre_hello,
    selected_version: u16 = 0,
    client_kind: ClientKind = .unknown,
    admin_admission: ?*AdminAdmission = null,
    admin_lease_held: bool = false,
    /// MRSH v2에 후속 비동기 event를 무조건 밀면 같은 major의 구 client가 protocol error로 종료한다. hello에서
    /// 명시적으로 협상한 client에게만 runtime metadata attach/event/RPC를 노출한다.
    runtime_metadata_v1: bool = false,
    runtime_ended_v1: bool = false,
    controller_transfer_v1: bool = false,
    runtime_catchup_barrier_v1: bool = false,
    /// Deterministic fault injection: real builds leave false; tests force the snapshot-build failure boundary without
    /// also starving the tiny typed error response allocation.
    inventory_fail_snapshot_once: bool = false,
    /// 이 connection이 연 stream 구독 표(§9 attach subscription). key=`stream_id`, value=`Subscription`(runtime_id +
    /// 마지막 full snapshot base). input_bytes/resize/detach가 stream_id로 runtime을 찾고, delta push는 base 대비 diff한다.
    /// connection 종료 시 모두 detach하고 base를 해제한다.
    attachments: std.AutoHashMapUnmanaged(subscription_identity.LocalStreamId, Subscription) = .empty,
    /// Product poll-owner injection. Null is retained only for isolated pure protocol tests and
    /// read-only legacy seams that never expose a multi-fd product connection.
    projection_budget: ?ProjectionBudgetOps = null,
    subscription_identity: ?struct {
        connection: connection_slot.ConnectionKey,
        table: *subscription_identity.Table,
    } = null,
    next_stream_id: subscription_identity.LocalStreamId = 1,

    /// 한 stream 구독의 상태. `base`는 이 stream에 마지막으로 보낸 full snapshot 바이트(다음 delta diff의 기준). attach
    /// 직후 첫 snapshot으로 채워지고, delta push마다 갱신된다. null이면 아직 base가 없다(read-only host 또는 snapshot 실패).
    /// `resync_pending`=client가 `runtime.resync`로 fresh snapshot 재요청(§9 desync 복구) — 다음 `collectDeltas`가 delta 대신
    /// 현재 full snapshot을 snapshot_chunk로 push하고 base를 그걸로 교체한다. client의 조립기 generation gap을 리셋한다.
    pub const Subscription = struct {
        runtime_id: u128,
        subscription_id: subscription_identity.SubscriptionId,
        base: ?[]u8 = null,
        resync_pending: bool = false,
        awaiting_resync_ack: bool = false,
        observation_token: ?u64 = null,
        observation_revision: u64 = 0,
        observation_ticks: u8 = 0,
        /// Non-null only while a newly acquired controller attach is unpublished. rollbackAttach
        /// may restore this exact epoch; normal detach never decrements generation.
        unpublished_controller_generation: ?u64 = null,
        /// 마지막으로 queue admission까지 commit된 screen output frontier. initial attach snapshot만
        /// 0이고, 이후 resync/fallback snapshot과 non-empty delta batch는 exact +1로 전진한다.
        screen_sequence: u64 = 0,
        screen_generation: u64 = 0,
        screen_change_token: ?ScreenChangeToken = null,
        catchup: catchup_barrier_contract.HostState = .idle,
    };

    pub const State = enum { pre_hello, ready, closed };

    fn init(allocator: std.mem.Allocator, host_id: u128, registry: *reg.TerminalRuntimeRegistry) Connection {
        return .{ .allocator = allocator, .host_id = host_id, .registry = registry };
    }

    pub fn initProduct(
        allocator: std.mem.Allocator,
        host_id: u128,
        registry: *reg.TerminalRuntimeRegistry,
        connection: connection_slot.ConnectionKey,
        subscriptions: *subscription_identity.Table,
    ) Connection {
        var result = init(allocator, host_id, registry);
        result.subscription_identity = .{
            .connection = connection,
            .table = subscriptions,
        };
        return result;
    }

    /// connection 종료(EOF/close) 시 이 connection의 모든 subscription을 registry에서 떼고 base를 해제한다(§9 "EOF는 모든
    /// stream을 detach하지만 runtime/child에는 종료 신호를 보내지 않는다"). runtime이 이미 없으면(동시 terminate) 무시한다.
    pub fn deinit(self: *Connection) void {
        var it = self.attachments.iterator();
        while (it.next()) |e| {
            _ = self.registry.detachSubscription(e.value_ptr.runtime_id, e.value_ptr.subscription_id) catch {};
            if (self.projection_budget) |budget|
                budget.release(budget.ctx, e.key_ptr.*);
            if (e.value_ptr.base) |b| self.allocator.free(b);
        }
        if (self.subscription_identity) |identity|
            _ = identity.table.revokeConnection(identity.connection);
        self.attachments.deinit(self.allocator);
        if (self.admin_lease_held) self.admin_admission.?.release();
        self.* = undefined;
    }

    /// Readiness adapter lifecycle projection. The returned local stream IDs are a snapshot owned
    /// by the caller; registry authority remains the daemon-global SubscriptionId table.
    pub fn localStreams(self: *const Connection, allocator: std.mem.Allocator) error{OutOfMemory}![]subscription_identity.LocalStreamId {
        const streams = allocator.alloc(
            subscription_identity.LocalStreamId,
            self.attachments.count(),
        ) catch return error.OutOfMemory;
        var index: usize = 0;
        var it = self.attachments.keyIterator();
        while (it.next()) |stream| {
            streams[index] = stream.*;
            index += 1;
        }
        return streams;
    }

    pub fn handshakeComplete(self: *const Connection) bool {
        return self.state != .pre_hello;
    }

    /// Readiness owner projection for producer-side terminals that do not have a peer request to
    /// return an error on (invalid observation, encoded payload overflow, revision exhaustion).
    pub fn isClosed(self: *const Connection) bool {
        return self.state == .closed;
    }

    pub fn attachmentCount(self: *const Connection) usize {
        return self.attachments.count();
    }

    pub fn isAdmin(self: *const Connection) bool {
        return self.client_kind == .admin and self.admin_lease_held;
    }

    pub fn hasLocalStream(
        self: *const Connection,
        stream: subscription_identity.LocalStreamId,
    ) bool {
        return self.attachments.contains(stream);
    }

    /// Registry membership is the lifecycle SSOT. Owner adapters call this before tracker-state
    /// early returns so an invalidated/resync-draining stream cannot hide a completed teardown.
    pub fn runtimeMissing(
        self: *Connection,
        stream: subscription_identity.LocalStreamId,
    ) bool {
        const sub = self.attachments.get(stream) orelse return false;
        return self.registry.get(sub.runtime_id) == null;
    }

    pub fn convergeEndedStream(
        self: *Connection,
        stream: subscription_identity.LocalStreamId,
    ) void {
        self.endMissingRuntime(stream);
    }

    pub fn runtimeEndedFrame(
        self: *Connection,
        stream: subscription_identity.LocalStreamId,
    ) HandleError![]u8 {
        const body = try self.stringify(.{ .event = "runtime.ended" });
        defer self.allocator.free(body);
        return self.encodeWithFlags(.event, 0, stream, 0, body) catch error.OutOfMemory;
    }

    pub fn supportsRuntimeEnded(self: *const Connection) bool {
        return self.runtime_ended_v1;
    }

    /// Registry/runtime ownership has already ended. Reclaim only this connection-local projection;
    /// the shared socket and sibling subscriptions remain live.
    fn endMissingRuntime(
        self: *Connection,
        stream: subscription_identity.LocalStreamId,
    ) void {
        _ = self.removeAttachment(stream);
    }

    fn discardPreparedOutput(
        self: *Connection,
        list: *std.ArrayListUnmanaged([]u8),
        output: *CollectedOutput,
    ) void {
        for (list.items) |frame| self.allocator.free(frame);
        list.deinit(self.allocator);
        if (output.next_base) |bytes| self.allocator.free(bytes);
        output.next_base = null;
        output.next_observation_token = null;
    }

    /// Canonical per-stream ownership release shared by explicit detach, attach rollback, and
    /// RuntimeNotFound convergence. Every external race therefore reaches the same idempotent edge.
    fn removeAttachment(
        self: *Connection,
        stream: subscription_identity.LocalStreamId,
    ) bool {
        const removed = self.attachments.fetchRemove(stream) orelse return false;
        const sub = removed.value;
        _ = self.registry.detachSubscription(sub.runtime_id, sub.subscription_id) catch {};
        if (self.projection_budget) |budget|
            budget.release(budget.ctx, stream);
        if (self.subscription_identity) |identity| _ = identity.table.revoke(.{
            .connection = identity.connection,
            .stream_id = stream,
        }) catch {};
        if (sub.base) |bytes| self.allocator.free(bytes);
        return true;
    }

    /// MRSH frame 하나를 처리한다. connection state에 따라 hello 협상 또는 command dispatch를 하고, 응답 frame을
    /// 만들어 `Action`으로 돌려준다. 응답이 없거나 protocol을 어긴 경우 `.close`다(runtime은 유지).
    pub fn handleFrame(self: *Connection, frame: framing.Frame) HandleError!Action {
        return self.handleFrameAt(frame, 0);
    }

    pub fn handleFrameAt(self: *Connection, frame: framing.Frame, now_ns: u64) HandleError!Action {
        if (frame.header.major != protocol.version_major) {
            self.state = .closed;
            return .close;
        }
        return switch (self.state) {
            .pre_hello => self.handleHello(frame),
            .ready => self.handleReady(frame, now_ns),
            .closed => .close,
        };
    }

    fn handleHello(self: *Connection, frame: framing.Frame) HandleError!Action {
        // 첫 frame은 반드시 hello. 아니면 조용히 닫는다(잘못된 client/socket 혼선).
        if (frame.header.kind != .hello) {
            self.state = .closed;
            return .close;
        }

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, frame.payload, .{}) catch {
            self.state = .closed;
            return .close; // hello가 파싱 불가면 attach 전이라 응답 없이 닫는다.
        };
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => {
                self.state = .closed;
                return .close;
            },
        };

        const pmin = intField(obj, "protocol_min") orelse 0;
        const pmax = intField(obj, "protocol_max") orelse 0;
        // Capability negotiation is an authority boundary. Silently skipping a malformed
        // element would let a syntactically invalid hello enable a later capability.
        if (!stringArrayFieldValid(obj, "capabilities")) {
            self.state = .closed;
            return .close;
        }
        self.client_kind = parseClientKind(strField(obj, "client_kind"));
        self.runtime_metadata_v1 = stringArrayContains(obj, "capabilities", "runtime_metadata_v1");
        self.runtime_ended_v1 = stringArrayContains(obj, "capabilities", "runtime_ended_v1");
        self.controller_transfer_v1 = stringArrayContains(
            obj,
            "capabilities",
            "controller_transfer_v1",
        );
        self.runtime_catchup_barrier_v1 = self.subscription_identity != null and
            stringArrayContains(obj, "capabilities", catchup_barrier_contract.capability);

        // 겹치는 major가 없으면 incompatible_version으로 끝낸다(§10). 이때는 응답을 준 뒤 닫는다.
        if (!(pmin <= protocol.version_major and protocol.version_major <= pmax)) {
            const body = try self.errorJson(.incompatible_version);
            defer self.allocator.free(body);
            const wire = try self.encodeSmall(.hello_ack, frame.header.request_id, 0, body);
            self.state = .closed;
            return .{ .reply_and_close = wire };
        }

        if (self.client_kind == .admin) {
            const admission = self.admin_admission orelse {
                const body = try self.errorJson(.unauthorized);
                defer self.allocator.free(body);
                const wire = try self.encodeSmall(.hello_ack, frame.header.request_id, 0, body);
                self.state = .closed;
                return .{ .reply_and_close = wire };
            };
            if (!admission.acquire()) {
                const body = try self.errorJson(.resource_exhausted);
                defer self.allocator.free(body);
                const wire = try self.encodeSmall(.hello_ack, frame.header.request_id, 0, body);
                self.state = .closed;
                return .{ .reply_and_close = wire };
            }
            self.admin_lease_held = true;
        }

        self.selected_version = protocol.version_major;
        self.state = .ready;
        const ack = try self.helloAckJson();
        defer self.allocator.free(ack);
        const wire = try self.encodeSmall(.hello_ack, frame.header.request_id, 0, ack);
        return .{ .reply = wire };
    }

    fn handleReady(self: *Connection, frame: framing.Frame, now_ns: u64) HandleError!Action {
        if (frame.header.kind == .request and frame.header.request_id == 0) {
            self.state = .closed;
            return .close;
        }
        if (self.client_kind == .admin) return self.handleAdminReady(frame, now_ns);
        switch (frame.header.kind) {
            .ping => {
                // diagnostic nonce를 그대로 되돌린다(payload passthrough). ping·pong cap이 같아 재초과 없음.
                const wire = try self.encodeSmall(.pong, frame.header.request_id, frame.header.stream_id, frame.payload);
                return .{ .reply = wire };
            },
            .request => return self.dispatchRequest(frame, now_ns),
            .input_bytes => return self.routeInput(frame),
            .stream_ack => return self.routeStreamAck(frame),
            .scroll_to_bottom => return self.routeScrollToBottom(frame),
            .core_command => return self.routeCoreCommandFrame(frame),
            .hello => {
                // hello는 connection당 한 번. 두 번째 hello는 protocol 위반.
                self.state = .closed;
                return .close;
            },
            else => {
                // stream_ack 등 stream demux frame은 e2d에서 처리한다. 그 전까지 미지 kind는 connection을 닫는다.
                self.state = .closed;
                return .close;
            },
        }
    }

    fn handleAdminReady(self: *Connection, frame: framing.Frame, now_ns: u64) HandleError!Action {
        if (frame.header.kind != .request)
            return self.adminErrorAndClose(frame.header.request_id, .unauthorized);
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, frame.payload, .{}) catch
            return self.adminErrorAndClose(frame.header.request_id, .invalid_request);
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return self.adminErrorAndClose(frame.header.request_id, .invalid_request),
        };
        const method_text = strField(obj, "method") orelse
            return self.adminErrorAndClose(frame.header.request_id, .invalid_request);
        const method = parseRequestMethod(method_text) orelse
            return self.adminErrorAndClose(frame.header.request_id, .invalid_request);
        const params: ?std.json.ObjectMap = switch (obj.get("params") orelse std.json.Value.null) {
            .object => |o| o,
            else => null,
        };
        return switch (requestPolicy(method)) {
            .admin_read => blk: {
                const action = try self.dispatchParsedRequest(frame, method, params, now_ns);
                self.state = .closed;
                break :blk .{ .reply_and_close = action.reply };
            },
            .admin_mutation => blk: {
                if (self.runtime_ops == null)
                    return self.adminErrorAndClose(frame.header.request_id, .unauthorized);
                const action = try self.dispatchParsedRequest(frame, method, params, now_ns);
                self.state = .closed;
                break :blk switch (action) {
                    .reply => |bytes| .{ .reply_and_close = bytes },
                    .admin_terminate_accepted => action,
                    else => unreachable,
                };
            },
            .privileged => self.adminErrorAndClose(frame.header.request_id, .unauthorized),
        };
    }

    fn adminErrorAndClose(
        self: *Connection,
        request_id: u64,
        code: protocol.ErrorCode,
    ) HandleError!Action {
        const action = try self.replyError(request_id, code);
        self.state = .closed;
        return .{ .reply_and_close = action.reply };
    }

    fn dispatchRequest(self: *Connection, frame: framing.Frame, now_ns: u64) HandleError!Action {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, frame.payload, .{}) catch {
            return self.replyError(frame.header.request_id, .invalid_request);
        };
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return self.replyError(frame.header.request_id, .invalid_request),
        };
        const method_text = strField(obj, "method") orelse return self.replyError(frame.header.request_id, .invalid_request);
        const method = parseRequestMethod(method_text) orelse
            return self.replyError(frame.header.request_id, .invalid_request);
        const params: ?std.json.ObjectMap = switch (obj.get("params") orelse std.json.Value.null) {
            .object => |o| o,
            else => null,
        };

        return self.dispatchParsedRequest(frame, method, params, now_ns);
    }

    fn dispatchParsedRequest(
        self: *Connection,
        frame: framing.Frame,
        method: RequestMethod,
        params: ?std.json.ObjectMap,
        now_ns: u64,
    ) HandleError!Action {
        return switch (method) {
            .host_info => blk: {
                const body = try self.hostInfoJson();
                defer self.allocator.free(body);
                break :blk self.replyResult(frame.header.request_id, body);
            },
            .host_upgrade_prepare => self.dispatchUpgradePrepare(frame.header.request_id, params),
            .host_upgrade_status => self.dispatchUpgradeStatus(frame.header.request_id, params),
            .runtime_list => blk: {
                const body = try self.runtimeListJson();
                defer self.allocator.free(body);
                break :blk self.replyResult(frame.header.request_id, body);
            },
            .runtime_inventory => self.dispatchRuntimeInventory(frame.header.request_id, frame.payload),
            .runtime_get => blk: {
                const id_hex = if (params) |p| strField(p, "runtime_id") else null;
                const id = if (id_hex) |h| parseHex128(h) else null;
                if (id == null) break :blk self.replyError(frame.header.request_id, .invalid_request);
                const entry = self.registry.get(id.?) orelse
                    break :blk self.replyError(frame.header.request_id, .runtime_not_found);
                const body = try self.runtimeMetaJson(entry);
                defer self.allocator.free(body);
                break :blk self.replyResult(frame.header.request_id, body);
            },
            .runtime_spawn => self.dispatchSpawn(frame.header.request_id, params, false),
            .runtime_spawn_full => self.dispatchSpawn(frame.header.request_id, params, true),
            .runtime_terminate => self.dispatchTerminate(frame.header.request_id, params),
            .runtime_attach => self.dispatchAttach(frame.header.request_id, params),
            .runtime_detach => self.dispatchDetach(frame.header.request_id, params),
            .controller_status => self.dispatchControllerStatus(
                frame.header.request_id,
                params,
            ),
            .controller_takeover => self.dispatchControllerTransition(
                frame.header.request_id,
                params,
                .takeover,
            ),
            .controller_release => self.dispatchControllerTransition(
                frame.header.request_id,
                params,
                .release,
            ),
            .runtime_resync => self.dispatchResync(frame.header.request_id, params),
            .runtime_catchup => self.dispatchCatchup(frame.header.request_id, params, now_ns),
            .runtime_observation => self.dispatchObservation(frame.header.request_id, params),
            .runtime_core_command => self.dispatchCoreCommand(frame.header.request_id, params),
            .runtime_report_mouse => self.dispatchReportMouse(frame.header.request_id, params),
            .runtime_selected_text => self.dispatchSelectedText(frame.header.request_id, params),
            .runtime_clipboard_write => self.dispatchClipboardWrite(frame.header.request_id, params),
            .runtime_link_at => self.dispatchLinkAt(frame.header.request_id, params),
            .runtime_select_op => self.dispatchSelectOp(frame.header.request_id, params),
            .runtime_find => self.dispatchFind(frame.header.request_id, params),
            .runtime_resize => self.dispatchResize(frame.header.request_id, params),
            .runtime_notification => self.dispatchNotification(frame.header.request_id, params),
            .notification_config_update => self.dispatchNotificationConfigUpdate(frame.header.request_id, params),
        };
    }

    fn dispatchNotificationConfigUpdate(self: *Connection, request_id: u64, params: ?std.json.ObjectMap) HandleError!Action {
        const ops = self.runtime_ops orelse return self.replyError(request_id, .unauthorized);
        const update = ops.notification_config_update orelse return self.replyError(request_id, .unauthorized);
        const p = params orelse return self.replyError(request_id, .invalid_request);
        if (p.count() != 5) return self.replyError(request_id, .invalid_request);
        const stream = intFieldU64(p, "stream_id") orelse return self.replyError(request_id, .invalid_request);
        const expected_generation = intFieldU64(p, "expected_controller_generation") orelse
            return self.replyError(request_id, .invalid_request);
        const config_generation = intFieldU64(p, "config_generation") orelse
            return self.replyError(request_id, .invalid_request);
        const notifications_osc = exactBoolField(p, "notifications_osc") orelse
            return self.replyError(request_id, .invalid_request);
        const display_label = strField(p, "display_label") orelse
            return self.replyError(request_id, .invalid_request);
        const attachment = self.attachments.get(stream) orelse
            return self.replyError(request_id, .invalid_request);
        if (!reg.Capability.has(
            self.registry.capabilitiesOfSubscription(attachment.runtime_id, attachment.subscription_id),
            reg.Capability.input,
        )) return self.replyError(request_id, .unauthorized);
        const current_generation = self.registry.controllerGeneration(attachment.runtime_id) catch
            return self.replyError(request_id, .runtime_not_found);
        if (current_generation != expected_generation)
            return self.replyError(request_id, .invalid_generation);
        const applied = update(ops.ctx, attachment.runtime_id, current_generation, .{
            .config_generation = config_generation,
            .notifications_osc = notifications_osc,
            .display_label = display_label,
        }) catch |err| return switch (err) {
            error.RuntimeNotFound => self.replyError(request_id, .runtime_not_found),
            error.DisplayLabelTooLong, error.InvalidDisplayLabel, error.InvalidConfigGeneration => self.replyError(request_id, .invalid_request),
            error.OutOfMemory => error.OutOfMemory,
            else => self.replyError(request_id, .internal),
        };
        if (!applied) return self.replyError(request_id, .invalid_generation);
        const body = try self.stringify(.{ .applied = true });
        defer self.allocator.free(body);
        return self.replyResult(request_id, body);
    }

    fn dispatchRuntimeInventory(
        self: *Connection,
        request_id: u64,
        request_payload: []const u8,
    ) HandleError!Action {
        if (!self.currentHostStatus().manifest_capable)
            return self.replyError(request_id, .unauthorized);
        const InventoryRequest = struct {
            method: []const u8,
            params: struct {
                cursor: []const u8,
                limit: u16,
                membership_generation: u64,
            },
        };
        var request = std.json.parseFromSlice(InventoryRequest, self.allocator, request_payload, .{}) catch
            return self.replyError(request_id, .invalid_request);
        defer request.deinit();
        if (!std.mem.eql(u8, request.value.method, "runtime.inventory"))
            return self.replyError(request_id, .invalid_request);
        const cursor_text = request.value.params.cursor;
        const limit = request.value.params.limit;
        const requested_generation = request.value.params.membership_generation;
        if (limit != protocol.max_inventory_page_runtimes)
            return self.replyError(request_id, .invalid_request);
        if ((cursor_text.len == 0) != (requested_generation == 0))
            return self.replyError(request_id, .invalid_request);
        const cursor: ?u128 = if (cursor_text.len == 0) null else (parseExactHex128(cursor_text) orelse return self.replyError(request_id, .invalid_request));
        const generation = self.registry.membershipGeneration() catch
            return self.replyError(request_id, .resource_exhausted);
        if (requested_generation != 0 and requested_generation != generation)
            return self.replyError(request_id, .invalid_generation);
        if (self.registry.count() > protocol.max_inventory_runtimes)
            return self.replyError(request_id, .resource_exhausted);
        if (self.inventory_fail_snapshot_once) {
            self.inventory_fail_snapshot_once = false;
            return self.replyError(request_id, .resource_exhausted);
        }

        var ids = self.allocator.alloc(u128, self.registry.count()) catch
            return self.replyError(request_id, .resource_exhausted);
        defer self.allocator.free(ids);
        var id_len: usize = 0;
        var it = self.registry.entries.keyIterator();
        while (it.next()) |id| {
            ids[id_len] = id.*;
            id_len += 1;
        }
        std.mem.sort(u128, ids, {}, comptime std.sort.asc(u128));
        var first: usize = 0;
        if (cursor) |after| {
            while (first < ids.len and ids[first] <= after) first += 1;
        }
        const page_len = @min(@as(usize, @intCast(limit)), ids.len - first);

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var wire_ids = a.alloc([]const u8, page_len) catch
            return self.replyError(request_id, .resource_exhausted);
        for (ids[first .. first + page_len], 0..) |id, i| {
            wire_ids[i] = std.fmt.allocPrint(a, "{x:0>32}", .{id}) catch
                return self.replyError(request_id, .resource_exhausted);
        }
        const done = first + page_len == ids.len;
        const next_cursor = if (!done and page_len != 0)
            wire_ids[page_len - 1]
        else
            "";
        const status = self.currentHostStatus();
        if (status.lifecycle != .ready) return self.replyError(request_id, .host_shutting_down);
        const body = self.stringify(.{ .result = .{
            .version = @as(u8, 1),
            .membership_generation = generation,
            .upgrade_epoch = status.upgrade_epoch,
            .authority_generation = status.authority_generation,
            .lifecycle = "ready",
            .total = ids.len,
            .cursor = cursor_text,
            .runtime_ids = wire_ids,
            .next_cursor = next_cursor,
            .done = done,
        } }) catch return self.replyError(request_id, .resource_exhausted);
        defer self.allocator.free(body);
        return self.replyResult(request_id, body);
    }

    fn dispatchUpgradePrepare(
        self: *Connection,
        request_id: u64,
        params: ?std.json.ObjectMap,
    ) HandleError!Action {
        const ops = self.upgrade_ops orelse return self.replyError(request_id, .upgrade_unsupported);
        const request = upgrade_wire.parsePrepare(params orelse
            return self.replyError(request_id, .invalid_request)) orelse
            return self.replyError(request_id, .invalid_request);
        // Completed replay는 read-only 결과 조회지만 attempt ID만으로 우회하면 다른 target identity가 성공으로
        // 위장된다. Owner가 immutable request 전체를 exact-match/conflict로 분류하고, active exact retry와
        // 알려지지 않은 new request만 종전 all-or-none preflight로 보낸다.
        switch (ops.probe_prepare(ops.ctx, request)) {
            .completed => |report| {
                if (!upgrade_wire.validReport(report) or report.status == .pending)
                    return self.replyError(request_id, .upgrade_busy);
                var replay_buf: [32]u8 = undefined;
                const replay_attempt = std.fmt.bufPrint(&replay_buf, "{x:0>32}", .{request.attempt_id}) catch
                    return error.OutOfMemory;
                const replay_body = try self.stringify(.{ .result = .{
                    .attempt_id = replay_attempt,
                    .state = @tagName(report.status),
                    .reason = @tagName(report.reason),
                    .replayed = true,
                } });
                defer self.allocator.free(replay_body);
                return self.replyResult(request_id, replay_body);
            },
            .conflict => return self.replyError(request_id, .attempt_conflict),
            .requires_preflight => {},
        }
        if (!self.currentHostStatus().upgrade_capable)
            return self.replyError(request_id, .upgrade_unsupported);
        const preflight = self.upgrade_preflight orelse
            return self.replyError(request_id, .upgrade_busy);
        if (!preflight.reserve(preflight.ctx))
            return self.replyError(request_id, .upgrade_busy);
        var reservation_transferred = false;
        defer if (!reservation_transferred) preflight.cancel(preflight.ctx);
        return switch (ops.stage_pending(ops.ctx, request)) {
            .accepted => blk: {
                var action_ready = false;
                defer if (!action_ready) ops.cancel_unaccepted(ops.ctx, request.attempt_id);
                var attempt_buf: [32]u8 = undefined;
                const attempt = std.fmt.bufPrint(&attempt_buf, "{x:0>32}", .{request.attempt_id}) catch
                    return error.OutOfMemory;
                const body = try self.stringify(.{ .result = .{
                    .attempt_id = attempt,
                    .state = "accepted",
                } });
                defer self.allocator.free(body);
                const wire = self.encode(.response, request_id, 0, body) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.PayloadTooLarge => return self.replyError(request_id, .payload_too_large),
                };
                self.state = .closed;
                action_ready = true;
                reservation_transferred = true;
                break :blk .{ .upgrade_accepted = .{
                    .bytes = wire,
                    .attempt_id = request.attempt_id,
                } };
            },
            .completed => |report| blk: {
                var attempt_buf: [32]u8 = undefined;
                const attempt = std.fmt.bufPrint(&attempt_buf, "{x:0>32}", .{request.attempt_id}) catch
                    return error.OutOfMemory;
                const body = try self.stringify(.{ .result = .{
                    .attempt_id = attempt,
                    .state = @tagName(report.status),
                    .reason = @tagName(report.reason),
                    .replayed = true,
                } });
                defer self.allocator.free(body);
                break :blk self.replyResult(request_id, body);
            },
            .busy => self.replyError(request_id, .upgrade_busy),
            .conflict => self.replyError(request_id, .attempt_conflict),
            .unsupported => self.replyError(request_id, .upgrade_unsupported),
            .invalid_target => self.replyError(request_id, .invalid_target),
            .resource_exhausted => self.replyError(request_id, .resource_exhausted),
        };
    }

    fn dispatchUpgradeStatus(
        self: *Connection,
        request_id: u64,
        params: ?std.json.ObjectMap,
    ) HandleError!Action {
        const ops = self.upgrade_ops orelse return self.replyError(request_id, .upgrade_unsupported);
        const attempt_id = upgrade_wire.parseStatus(params orelse
            return self.replyError(request_id, .invalid_request)) orelse
            return self.replyError(request_id, .invalid_request);
        const report = ops.status(ops.ctx, attempt_id) orelse
            return self.replyError(request_id, .invalid_request);
        const body = try self.stringify(.{ .result = .{
            .state = @tagName(report.status),
            .reason = @tagName(report.reason),
        } });
        defer self.allocator.free(body);
        return self.replyResult(request_id, body);
    }

    /// user action 직전 metadata barrier. 주기 event cache가 `.current`여도 마지막 100ms 안의 OSC 5379 전환은 아직
    /// 도착하지 않았을 수 있으므로, 파일/이미지 SSH 라우팅은 이 RPC 응답 뒤에만 결정한다. 같은 subscription base/revision을
    /// 갱신해 다음 periodic event와 단조 순서를 공유한다.
    fn dispatchObservation(self: *Connection, request_id: u64, params: ?std.json.ObjectMap) HandleError!Action {
        if (!self.runtime_metadata_v1) return self.replyError(request_id, .invalid_request);
        const ops = self.runtime_ops orelse return self.replyError(request_id, .unauthorized);
        const p = params orelse return self.replyError(request_id, .invalid_request);
        const stream = intFieldU64(p, "stream_id") orelse return self.replyError(request_id, .invalid_request);
        const sub = self.attachments.getPtr(stream) orelse return self.replyError(request_id, .runtime_not_found);
        if (!reg.Capability.has(
            self.registry.capabilitiesOfSubscription(sub.runtime_id, sub.subscription_id),
            reg.Capability.observe,
        ))
            return self.replyError(request_id, .unauthorized);
        if (self.projection_budget != null)
            return self.dispatchPreparedObservation(request_id, stream, ops, sub);

        const observation = ops.cached_observation(ops.ctx, sub.runtime_id, .fresh) catch |err| switch (err) {
            error.RuntimeNotFound => return self.replyError(request_id, .runtime_not_found),
            error.InvalidObservation,
            error.ObservationTokenExhausted,
            error.ObservationTransactionCorrupt,
            => {
                self.state = .closed;
                return .close;
            },
            else => return self.replyError(request_id, .internal),
        };
        const canonical = observation.canonical_json;
        const changed = sub.observation_token != observation.change_token;
        const revision = if (changed)
            std.math.add(u64, sub.observation_revision, 1) catch {
                self.state = .closed;
                return .close;
            }
        else
            sub.observation_revision;
        const body = try self.stringify(.{ .result = .{
            .metadata_revision = revision,
            .metadata = RawCanonicalObservation{ .bytes = canonical },
        } });
        defer self.allocator.free(body);
        const action = try self.replyResult(request_id, body);

        // response frame까지 소유한 뒤에만 server base를 전진시킨다. 이 전 OOM이면 다음 periodic event가 같은 변화를
        // 다시 보낼 수 있어 client cache가 영구 누락되지 않는다.
        if (changed) {
            sub.observation_token = observation.change_token;
            sub.observation_revision = revision;
        }
        return action;
    }

    fn dispatchPreparedObservation(
        self: *Connection,
        request_id: u64,
        stream: subscription_identity.LocalStreamId,
        ops: RuntimeOps,
        sub: *Subscription,
    ) HandleError!Action {
        var output: CollectedOutput = .{
            .allocator = self.allocator,
            .stream = stream,
            .frames = &.{},
            .previous_observation_ticks = sub.observation_ticks,
        };
        const budget = self.projection_budget.?;
        output.base_reservation = budget.prepare(
            budget.ctx,
            stream,
            connection_slot.base_update_max_bytes,
        ) orelse return self.replyError(request_id, .resource_exhausted);
        var transferred = false;
        defer if (!transferred) output.rollback(self);

        const observation = ops.cached_observation(ops.ctx, sub.runtime_id, .fresh) catch |err| switch (err) {
            error.RuntimeNotFound => return self.replyError(request_id, .runtime_not_found),
            error.InvalidObservation,
            error.ObservationTokenExhausted,
            error.ObservationTransactionCorrupt,
            => {
                self.state = .closed;
                return .close;
            },
            else => return self.replyError(request_id, .internal),
        };
        const canonical = observation.canonical_json;
        const changed = sub.observation_token != observation.change_token;
        const revision = if (changed)
            std.math.add(u64, sub.observation_revision, 1) catch {
                self.state = .closed;
                return .close;
            }
        else
            sub.observation_revision;
        const body = try self.stringify(.{ .result = .{
            .metadata_revision = revision,
            .metadata = RawCanonicalObservation{ .bytes = canonical },
        } });
        defer self.allocator.free(body);
        const reply = self.encode(.response, request_id, 0, body) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.PayloadTooLarge => return self.replyError(request_id, .payload_too_large),
        };
        if (!changed) return .{ .reply = reply };

        output.next_observation_token = observation.change_token;
        output.next_observation_revision = revision;
        transferred = true;
        return .{ .prepared_reply = .{ .reply = reply, .output = output } };
    }

    /// `runtime.notification`(§6.32): exact subscription이 가리키는 runtime의 대기 중인 OSC 9/777 알림을 빼서
    /// `{title, body}`로 응답한다. 소비는 shared runtime mutation이므로 controller stream만 허용한다. 같은 connection에
    /// 같은 runtime의 controller가 따로 있어도 observer `stream_id` 권위를 빌릴 수 없다. 없으면
    /// `{title:"",body:""}`(client가 빈 값을 "없음"으로 해석). runtime 없으면 runtime_not_found.
    fn dispatchNotification(self: *Connection, request_id: u64, params: ?std.json.ObjectMap) HandleError!Action {
        const ops = self.runtime_ops orelse return self.replyError(request_id, .unauthorized);
        const p = params orelse return self.replyError(request_id, .invalid_request);
        if (p.count() != 1 and p.count() != 2) return self.replyError(request_id, .invalid_request);
        const stable_delivery = if (p.get("delivery_version")) |value| switch (value) {
            .integer => |version| version == 1,
            else => false,
        } else false;
        if (p.count() == 2 and !stable_delivery) return self.replyError(request_id, .invalid_request);
        if (stable_delivery and intFieldU64(p, "stream_id") == null)
            return self.replyError(request_id, .invalid_request);
        const runtime_id = if (intFieldU64(p, "stream_id")) |stream| blk: {
            const attachment = self.attachments.get(stream) orelse
                return self.replyError(request_id, .invalid_request);
            if (!reg.Capability.has(
                self.registry.capabilitiesOfSubscription(
                    attachment.runtime_id,
                    attachment.subscription_id,
                ),
                reg.Capability.input,
            )) return self.replyError(request_id, .unauthorized);
            break :blk attachment.runtime_id;
        } else if (strField(p, "runtime_id")) |id_hex| blk: {
            // Same-major legacy adapter: old clients do not know stream-scoped notification auth.
            // The fallback still requires a live controller for this runtime on this connection.
            const id = parseHex128(id_hex) orelse
                return self.replyError(request_id, .invalid_request);
            if (!self.hasRuntimeCapability(id, reg.Capability.input))
                return self.replyError(request_id, .unauthorized);
            break :blk id;
        } else return self.replyError(request_id, .invalid_request);
        const snapshot = ops.notification_peek(
            ops.ctx,
            runtime_id,
            stable_delivery,
            self.allocator,
        ) catch |err| switch (err) {
            error.RuntimeNotFound => return self.replyError(request_id, .runtime_not_found),
            else => return self.replyError(request_id, .internal),
        };
        defer self.allocator.free(snapshot.body);
        const reply = self.encode(
            .response,
            request_id,
            0,
            snapshot.body,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.PayloadTooLarge => return self.replyError(
                request_id,
                .payload_too_large,
            ),
        };
        return .{ .prepared_notification = .{
            .reply = reply,
            .runtime_id = runtime_id,
            .generation = snapshot.generation,
        } };
    }

    /// `runtime.spawn`: read-only host면 unauthorized. argv/cwd/cols/rows를 파싱해 `RuntimeOps`로 실 PTY를 띄우고
    /// `runtime_id`(hex)를 응답한다. argv는 비어 있으면 invalid_request, spawn 실패는 internal.
    fn dispatchSpawn(self: *Connection, request_id: u64, params: ?std.json.ObjectMap, full_contract: bool) HandleError!Action {
        const ops = self.runtime_ops orelse return self.replyError(request_id, .unauthorized);
        const p = params orelse return self.replyError(request_id, .invalid_request);
        const argv_val = switch (p.get("argv") orelse std.json.Value.null) {
            .array => |arr| arr,
            else => return self.replyError(request_id, .invalid_request),
        };
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const argv = stringArrayFromValue(a, argv_val) catch |err| switch (err) {
            error.InvalidStringArray => return self.replyError(request_id, .invalid_request),
            error.OutOfMemory => return error.OutOfMemory,
        };
        if (argv.len == 0) return self.replyError(request_id, .invalid_request);
        const env = stringArrayField(a, p, "env", !full_contract) catch |err| switch (err) {
            error.InvalidStringArray => return self.replyError(request_id, .invalid_request),
            error.OutOfMemory => return error.OutOfMemory,
        };
        const parent_env: ?[]const []const u8 = if (p.get("parent_env") != null)
            stringArrayField(a, p, "parent_env", false) catch |err| switch (err) {
                error.InvalidStringArray => return self.replyError(request_id, .invalid_request),
                error.OutOfMemory => return error.OutOfMemory,
            }
        else if (full_contract)
            &.{}
        else
            null;
        const env_overrides = stringArrayField(a, p, "env_overrides", !full_contract) catch |err| switch (err) {
            error.InvalidStringArray => return self.replyError(request_id, .invalid_request),
            error.OutOfMemory => return error.OutOfMemory,
        };
        const pane_id = paneIdField(p) catch return self.replyError(request_id, .invalid_request);
        // runtime.spawn은 구 v2 client와 호환되는 최소 계약이다. runtime.spawn_full은 새 GUI가 사용하는 확장
        // 계약이므로, 필드가 존재하면서 타입/범위가 틀리면 기본값으로 조용히 바꾸지 않고 fail-closed한다.
        const cwd = if (full_contract)
            spawnOptionalStringField(p, "cwd") catch return self.replyError(request_id, .invalid_request)
        else
            strField(p, "cwd");
        const login = if (full_contract)
            spawnBoolField(p, "login", false) catch return self.replyError(request_id, .invalid_request)
        else
            boolField(p, "login");
        const term = if (full_contract)
            spawnStringField(p, "term", "xterm-256color") catch return self.replyError(request_id, .invalid_request)
        else
            (strField(p, "term") orelse "xterm-256color");
        const zdotdir = if (full_contract)
            spawnOptionalStringField(p, "zdotdir") catch return self.replyError(request_id, .invalid_request)
        else
            strField(p, "zdotdir");
        const ssh_integration_bin = if (full_contract)
            spawnOptionalStringField(p, "ssh_integration_bin") catch return self.replyError(request_id, .invalid_request)
        else
            strField(p, "ssh_integration_bin");
        const cols = if (full_contract)
            spawnSizeField(p, "cols", 80) catch return self.replyError(request_id, .invalid_request)
        else
            (intField(p, "cols") orelse 80);
        const rows = if (full_contract)
            spawnSizeField(p, "rows", 24) catch return self.replyError(request_id, .invalid_request)
        else
            (intField(p, "rows") orelse 24);
        if (!reg.gridSizeAllowed(cols, rows))
            return self.replyError(request_id, .invalid_request);
        const initial_config: ?core_command_wire.Command.RuntimeConfig = if (p.get("runtime_config")) |value|
            switch (value) {
                .null => null,
                .object => |object| core_command_wire.decodeRuntimeConfig(object) orelse
                    return self.replyError(request_id, .invalid_request),
                else => return self.replyError(request_id, .invalid_request),
            }
        else
            null;
        const initial_notification: ?NotificationConfigSnapshot = if (p.get("notification_config")) |value|
            switch (value) {
                .null => null,
                .object => decodeInitialNotification(value) orelse
                    return self.replyError(request_id, .invalid_request),
                else => return self.replyError(request_id, .invalid_request),
            }
        else
            null;
        const runtime_id = ops.spawn(ops.ctx, .{
            .argv = argv,
            .cwd = cwd,
            .login = login,
            .env = env,
            .parent_env = parent_env,
            .env_overrides = env_overrides,
            .term = term,
            .shell_integration_dir = zdotdir,
            .ssh_integration_bin = ssh_integration_bin,
            .pane_id = pane_id,
            .cols = cols,
            .rows = rows,
            .initial_config = initial_config,
            .initial_notification = initial_notification,
        }) catch |err| switch (err) {
            error.RuntimeLimitReached, error.AggregateGridLimitReached => return self.replyError(request_id, .resource_exhausted),
            error.InvalidGridSize => return self.replyError(request_id, .invalid_request),
            else => return self.replyError(request_id, .internal),
        };

        const id_hex = try self.hex128(runtime_id);
        defer self.allocator.free(id_hex);
        const body = try self.stringify(.{ .result = .{ .runtime_id = id_hex } });
        defer self.allocator.free(body);
        return self.replyResult(request_id, body);
    }

    /// `runtime.terminate`: read-only host면 unauthorized. 일반 GUI 요청은 기존 멱등 semantics를 유지하지만,
    /// admin mutation은 같은 owner turn의 registry exact membership을 다시 확인한다. success frame을 먼저 전량
    /// allocate/encode한 뒤 backend를 종료해 OOM이 "실행됐지만 응답 없음"으로 바뀌지 않게 한다.
    fn dispatchTerminate(self: *Connection, request_id: u64, params: ?std.json.ObjectMap) HandleError!Action {
        const ops = self.runtime_ops orelse return self.replyError(request_id, .unauthorized);
        const p = params orelse return self.replyError(request_id, .invalid_request);
        const id = if (strField(p, "runtime_id")) |h| parseHex128(h) else null;
        if (id == null) return self.replyError(request_id, .invalid_request);
        if (self.client_kind == .admin and self.registry.get(id.?) == null)
            return self.replyError(request_id, .runtime_not_found);
        if (self.client_kind == .admin) {
            const body = try self.stringify(.{ .result = .{ .terminated = true } });
            defer self.allocator.free(body);
            const action = try self.replyResult(request_id, body);
            return .{ .admin_terminate_accepted = .{
                .bytes = action.reply,
                .runtime_id = id.?,
            } };
        }
        // GUI close는 기존 best-effort 의미론을 보존한다. 응답 allocation 실패가 runtime 종료를 취소하면
        // 명시적으로 닫은 tab만 사라지고 host runtime이 남는 회귀가 된다.
        ops.terminate(ops.ctx, id.?);
        const body = try self.stringify(.{ .result = .{ .terminated = true } });
        defer self.allocator.free(body);
        return self.replyResult(request_id, body);
    }

    /// `runtime.attach`: runtime에 새 subscription을 연다(§8·§9). mode는 observer/controller만 받는다. 이미 붙은
    /// observer의 권위 요청과 controller release는 기존 stream을 지정하는 별도
    /// `controller.takeover`/`controller.release` owner transaction만 사용한다. host가 발급한
    /// `stream_id`·granted·`controller_busy`를 응답한 뒤, **현재 화면 snapshot을 `snapshot_chunk`
    /// frame으로 이어 보낸다**(§10 attach 순서: response → snapshot_chunk*의 마지막 end_stream → delta_chunk*).
    /// read-only host는 응답만 보내는 관리용 seam이다.
    /// runtime을 가진 product host에서 initial snapshot 생성이 실패하면 pre-runtime recovery pump가 없으므로 attach 권위를
    /// rollback하고 success reply 없이 fail-close한다.
    fn dispatchAttach(self: *Connection, request_id: u64, params: ?std.json.ObjectMap) HandleError!Action {
        const p = params orelse return self.replyError(request_id, .invalid_request);
        const id = if (strField(p, "runtime_id")) |h| parseHex128(h) else null;
        if (id == null) return self.replyError(request_id, .invalid_request);
        const mode = parseAttachMode(strField(p, "mode")) orelse
            return self.replyError(request_id, .invalid_request);

        if (self.next_stream_id == 0)
            return self.replyError(request_id, .resource_exhausted);
        const stream = self.next_stream_id;
        const subscription_id = if (self.subscription_identity) |identity|
            identity.table.register(.{
                .connection = identity.connection,
                .stream_id = stream,
            }, id.?) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Full, error.Exhausted => return self.replyError(request_id, .resource_exhausted),
                else => return self.replyError(request_id, .internal),
            }
        else
            subscription_identity.SubscriptionId{ .value = stream };
        var identity_registered = self.subscription_identity != null;
        errdefer if (identity_registered) {
            const identity = self.subscription_identity.?;
            _ = identity.table.revoke(.{
                .connection = identity.connection,
                .stream_id = stream,
            }) catch {};
        };
        const outcome = self.registry.attachSubscription(id.?, subscription_id, mode) catch |e| {
            if (identity_registered) {
                const identity = self.subscription_identity.?;
                _ = identity.table.revoke(.{
                    .connection = identity.connection,
                    .stream_id = stream,
                }) catch {};
                identity_registered = false;
            }
            return switch (e) {
                error.RuntimeNotFound => self.replyError(request_id, .runtime_not_found),
                error.AlreadyAttached => self.replyError(request_id, .invalid_request),
                error.ControllerGenerationExhausted => self.replyError(
                    request_id,
                    .resource_exhausted,
                ),
                error.OutOfMemory => error.OutOfMemory,
                else => self.replyError(request_id, .internal),
            };
        };
        const unpublished_controller_generation = if (reg.Capability.has(
            outcome.granted,
            reg.Capability.input,
        ))
            self.registry.controllerGeneration(id.?) catch {
                _ = self.registry.detachSubscription(id.?, subscription_id) catch {};
                return self.replyError(request_id, .internal);
            }
        else
            null;
        self.attachments.put(self.allocator, stream, .{
            .runtime_id = id.?,
            .subscription_id = subscription_id,
            .unpublished_controller_generation = unpublished_controller_generation,
        }) catch {
            if (unpublished_controller_generation) |generation| {
                const rolled_back = self.registry.rollbackControllerAttach(
                    id.?,
                    subscription_id,
                    generation,
                );
                std.debug.assert(rolled_back);
            }
            _ = self.registry.detachSubscription(id.?, subscription_id) catch {};
            return error.OutOfMemory;
        };
        identity_registered = false;
        self.next_stream_id = std.math.add(
            subscription_identity.LocalStreamId,
            self.next_stream_id,
            1,
        ) catch 0;
        var prepared_output: CollectedOutput = .{
            .allocator = self.allocator,
            .stream = stream,
            .frames = &.{},
            .previous_observation_ticks = 0,
        };
        const prepared_product = self.projection_budget != null and self.runtime_ops != null;
        if (prepared_product) {
            const budget = self.projection_budget.?;
            prepared_output.base_reservation = budget.prepare(
                budget.ctx,
                stream,
                connection_slot.base_update_max_bytes,
            ) orelse {
                self.rollbackAttach(stream);
                self.state = .closed;
                return .close;
            };
        }
        var prepared_transferred = false;
        defer if (prepared_product and !prepared_transferred)
            prepared_output.rollback(self);

        // attach 응답에 **현재 full metadata**를 함께 싣는다. response 뒤 snapshot만 온다는 기존 client 순서를 깨지 않으면서,
        // 재접속 GUI가 새 OSC를 기다리지 않고 cwd/title/SSH/agent 정보를 첫 frame 전에 복구한다. observation 실패는 화면
        // attach를 깨지 않고 null(unavailable)로 둔다. public runtime.list/get redaction과는 별도 observe-capability 경로다.
        var initial_observation: ?RawCanonicalObservation = null;
        if (self.runtime_metadata_v1) if (self.runtime_ops) |ops| {
            const cached = ops.cached_observation(ops.ctx, id.?, .current) catch |err| switch (err) {
                error.InvalidObservation,
                error.ObservationTokenExhausted,
                error.ObservationTransactionCorrupt,
                => {
                    self.rollbackAttach(stream);
                    self.state = .closed;
                    return .close;
                },
                else => null,
            };
            initial_observation = if (cached) |view|
                .{ .bytes = view.canonical_json }
            else
                null;
            if (cached) |view| {
                if (self.attachments.getPtr(stream)) |sub| {
                    if (prepared_product) {
                        prepared_output.next_observation_token = view.change_token;
                        prepared_output.next_observation_revision = 1;
                    } else {
                        sub.observation_token = view.change_token;
                        sub.observation_revision = 1;
                    }
                }
            }
        };
        const metadata_revision: u64 = if (prepared_output.next_observation_revision) |revision|
            revision
        else if (self.attachments.get(stream)) |sub|
            sub.observation_revision
        else
            0;
        const controller_generation = self.registry.controllerGeneration(
            id.?,
        ) catch {
            self.rollbackAttach(stream);
            return self.replyError(request_id, .internal);
        };
        const granted = .{
            .observe = reg.Capability.has(outcome.granted, reg.Capability.observe),
            .input = reg.Capability.has(outcome.granted, reg.Capability.input),
            .resize = reg.Capability.has(outcome.granted, reg.Capability.resize),
        };
        const body = if (self.runtime_metadata_v1)
            try self.stringify(.{ .result = .{
                .stream_id = stream,
                .controller_generation = controller_generation,
                .granted = granted,
                .controller_busy = outcome.controller_busy,
                .metadata_revision = metadata_revision,
                .metadata = initial_observation,
            } })
        else
            try self.stringify(.{ .result = .{
                .stream_id = stream,
                .controller_generation = controller_generation,
                .granted = granted,
                .controller_busy = outcome.controller_busy,
            } });
        defer self.allocator.free(body);
        const reply_frame = self.encode(.response, request_id, 0, body) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.PayloadTooLarge => {
                if (prepared_product) {
                    prepared_output.rollback(self);
                    prepared_transferred = true;
                }
                self.rollbackAttach(stream);
                // RuntimeOps produced a semantically valid-looking observation that cannot fit
                // the negotiated control frame after JSON escaping/envelope overhead. This is a
                // producer contract violation, not a peer request error.
                self.state = .closed;
                return .close;
            },
        };
        var reply_transferred = false;
        defer if (!reply_transferred) self.allocator.free(reply_frame);

        // read-only 관리 seam만 응답-only다. product runtime snapshot 실패는 아래에서 권위를 rollback하고 fail-close한다.
        const ops = self.runtime_ops orelse {
            if (self.attachments.getPtr(stream)) |sub|
                sub.unpublished_controller_generation = null;
            reply_transferred = true;
            return .{ .reply = reply_frame };
        };
        const initial_screen_change_token: ?ScreenChangeToken = if (ops.screen_change_token) |read_token|
            read_token(ops.ctx, id.?) catch {
                if (prepared_product) {
                    prepared_output.rollback(self);
                    prepared_transferred = true;
                }
                self.rollbackAttach(stream);
                self.state = .closed;
                return .close;
            }
        else
            null;
        const projected_snapshot = ops.snapshot(ops.ctx, id.?, 0, self.allocator) catch {
            if (prepared_product) {
                prepared_output.rollback(self);
                prepared_transferred = true;
            }
            self.rollbackAttach(stream);
            self.state = .closed;
            return .close;
        };
        const snap_bytes = projected_snapshot.bytes;
        if (snap_bytes.len > protocol.max_viewport_snapshot or
            projected_snapshot.frontier.sequence != 0)
        {
            self.allocator.free(snap_bytes);
            if (prepared_product) {
                prepared_output.rollback(self);
                prepared_transferred = true;
            }
            self.rollbackAttach(stream);
            self.state = .closed;
            return .close;
        }
        // snapshot을 이 stream의 delta base로 보관한다(free하지 않고 subscription이 소유). chunk frame은 payload를 복사한다.
        if (prepared_product) {
            prepared_output.next_base = snap_bytes;
            prepared_output.replace_base = true;
            prepared_output.next_screen_sequence = projected_snapshot.frontier.sequence;
            prepared_output.next_screen_generation = projected_snapshot.frontier.generation;
            prepared_output.next_screen_change_token = initial_screen_change_token;
        } else if (self.attachments.getPtr(stream)) |sub| {
            sub.base = snap_bytes;
            sub.screen_sequence = projected_snapshot.frontier.sequence;
            sub.screen_generation = projected_snapshot.frontier.generation;
            sub.screen_change_token = initial_screen_change_token;
        } else self.allocator.free(snap_bytes);

        // snapshot_chunk*를 조립한다. Product path는 response와 이 batch를 owner가 각각 admission한 뒤
        // transaction을 commit하고, pure legacy seam만 기존 frames 배열로 합친다.
        var list: std.ArrayListUnmanaged([]u8) = .empty;
        errdefer {
            for (list.items) |f| self.allocator.free(f);
            list.deinit(self.allocator);
        }
        try self.appendChunks(&list, .snapshot_chunk, stream, snap_bytes);
        const snapshot_frames = list.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
        if (prepared_product) {
            prepared_output.frames = snapshot_frames;
            prepared_output.frames_taken = false;
            prepared_transferred = true;
            reply_transferred = true;
            return .{ .prepared_attach = .{
                .reply = reply_frame,
                .output = prepared_output,
            } };
        }
        const frames = self.allocator.alloc([]u8, snapshot_frames.len + 1) catch {
            for (snapshot_frames) |frame| self.allocator.free(frame);
            self.allocator.free(snapshot_frames);
            return error.OutOfMemory;
        };
        frames[0] = reply_frame;
        @memcpy(frames[1..], snapshot_frames);
        self.allocator.free(snapshot_frames);
        reply_transferred = true;
        if (self.attachments.getPtr(stream)) |sub|
            sub.unpublished_controller_generation = null;
        return .{ .frames = frames };
    }

    /// A product attach cannot recover before `RemoteRuntime` exists. If the initial snapshot
    /// cannot be produced, revoke every authority created earlier in dispatchAttach and close
    /// without publishing a success response; otherwise the client would wait for a snapshot that
    /// can never arrive while an orphan controller lease remains live.
    fn rollbackAttach(self: *Connection, stream: subscription_identity.LocalStreamId) void {
        if (self.attachments.get(stream)) |attachment| {
            if (attachment.unpublished_controller_generation) |generation| {
                const rolled_back = self.registry.rollbackControllerAttach(
                    attachment.runtime_id,
                    attachment.subscription_id,
                    generation,
                );
                std.debug.assert(rolled_back);
            }
        }
        _ = self.removeAttachment(stream);
    }

    pub fn rollbackPreparedAttach(
        self: *Connection,
        stream: subscription_identity.LocalStreamId,
    ) void {
        self.rollbackAttach(stream);
    }

    pub fn discardPreparedControllerTransition(
        self: *Connection,
        prepared: *reg.PreparedControllerTransition,
    ) void {
        self.registry.discardControllerTransition(prepared);
    }

    /// record 바이트를 `kind` frame(각 ≤ `max_binary_chunk`)으로 잘라 `list`에 덧붙인다. 마지막 chunk에 `end_stream` flag를
    /// 세운다(§10 — 한 batch의 끝). 빈 바이트도 end_stream 한 frame으로 batch 종료를 알린다. 각 chunk는 `stream`을 싣는다.
    /// snapshot(snapshot_chunk)과 delta(delta_chunk)가 같은 chunk 규칙을 공유한다.
    fn appendChunks(self: *Connection, list: *std.ArrayListUnmanaged([]u8), kind: protocol.Kind, stream: u64, bytes: []const u8) HandleError!void {
        const chunk_size = protocol.max_binary_chunk;
        var off: usize = 0;
        while (true) {
            const end = @min(off + chunk_size, bytes.len);
            const is_last = end >= bytes.len;
            const flags: u32 = if (is_last) protocol.Flags.end_stream else 0;
            const f = self.encodeWithFlags(kind, 0, stream, flags, bytes[off..end]) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.PayloadTooLarge => unreachable, // chunk를 max_binary_chunk 이하로 자르므로 도달 불가.
            };
            list.append(self.allocator, f) catch {
                self.allocator.free(f);
                return error.OutOfMemory;
            };
            off = end;
            if (is_last) break;
        }
    }

    /// `runtime.detach`: 이 connection의 한 subscription을 뗀다(§9). runtime은 유지된다. 모르는 stream_id는 invalid_request.
    fn dispatchDetach(self: *Connection, request_id: u64, params: ?std.json.ObjectMap) HandleError!Action {
        const p = params orelse return self.replyError(request_id, .invalid_request);
        const stream = intFieldU64(p, "stream_id") orelse return self.replyError(request_id, .invalid_request);
        if (!self.removeAttachment(stream))
            return self.replyError(request_id, .invalid_request);
        const body = try self.stringify(.{ .result = .{ .detached = true } });
        defer self.allocator.free(body);
        return self.replyResult(request_id, body);
    }

    fn dispatchControllerTransition(
        self: *Connection,
        request_id: u64,
        params: ?std.json.ObjectMap,
        kind: reg.ControllerTransitionKind,
    ) HandleError!Action {
        if (!self.controller_transfer_v1)
            return self.replyError(request_id, .unauthorized);
        const p = params orelse return self.replyError(request_id, .invalid_request);
        if (p.count() != 2)
            return self.replyError(request_id, .invalid_request);
        const stream = intFieldU64(p, "stream_id") orelse
            return self.replyError(request_id, .invalid_request);
        const expected_generation = intFieldU64(
            p,
            "expected_controller_generation",
        ) orelse return self.replyError(request_id, .invalid_request);
        const attachment = self.attachments.get(stream) orelse
            return self.replyError(request_id, .invalid_request);
        const identity = self.subscription_identity orelse
            return self.replyError(request_id, .unauthorized);
        const local_subscription = identity.table.resolveLocal(.{
            .connection = identity.connection,
            .stream_id = stream,
        }) orelse return self.replyError(request_id, .unauthorized);
        if (local_subscription.value != attachment.subscription_id.value)
            return self.replyError(request_id, .unauthorized);
        const current_generation = self.registry.controllerGeneration(
            attachment.runtime_id,
        ) catch return self.replyError(request_id, .runtime_not_found);
        if (current_generation != expected_generation)
            return self.replyError(request_id, .invalid_generation);

        var prepared = switch (kind) {
            .takeover => self.registry.prepareControllerTakeover(
                attachment.runtime_id,
                attachment.subscription_id,
            ),
            .release => self.registry.prepareControllerRelease(
                attachment.runtime_id,
                attachment.subscription_id,
            ),
        } catch |err| return switch (err) {
            error.RuntimeNotFound => self.replyError(request_id, .runtime_not_found),
            error.NotController, error.NotObserver, error.StaleControllerTransition => self.replyError(request_id, .unauthorized),
            error.ControllerGenerationExhausted => self.replyError(request_id, .resource_exhausted),
            error.OutOfMemory => error.OutOfMemory,
            else => self.replyError(request_id, .internal),
        };
        var prepared_owned = true;
        defer if (prepared_owned)
            self.registry.discardControllerTransition(&prepared);
        std.debug.assert(prepared.expected_generation == expected_generation);

        const runtime_hex = try self.hex128(attachment.runtime_id);
        defer self.allocator.free(runtime_hex);
        const success_body = try self.stringify(.{ .result = .{
            .runtime_id = runtime_hex,
            .stream_id = stream,
            .controller_generation = prepared.next_generation,
            .reason = @tagName(kind),
            .granted = .{
                .observe = true,
                .input = kind == .takeover,
                .resize = kind == .takeover,
            },
        } });
        defer self.allocator.free(success_body);
        const success_reply = self.encode(
            .response,
            request_id,
            0,
            success_body,
        ) catch return error.OutOfMemory;
        var success_owned = true;
        defer if (success_owned)
            self.allocator.free(success_reply);
        const stale_reply = try self.replyErrorFrame(
            request_id,
            .invalid_generation,
        );
        var stale_owned = true;
        defer if (stale_owned) self.allocator.free(stale_reply);
        const exhausted_reply = try self.replyErrorFrame(
            request_id,
            .resource_exhausted,
        );
        var exhausted_owned = true;
        defer if (exhausted_owned) self.allocator.free(exhausted_reply);

        var revocation: ?Action.ControllerTransitionRequested.Revocation = null;
        if (kind == .takeover) if (prepared.expected_controller) |old| {
            const old_record = identity.table.resolveGlobal(old) orelse {
                return self.replyError(request_id, .unauthorized);
            };
            if (old_record.runtime_id != attachment.runtime_id) {
                return self.replyError(request_id, .unauthorized);
            }
            const event_body = try self.stringify(.{ .event = "controller.revoked", .data = .{
                .runtime_id = runtime_hex,
                .stream_id = old_record.stream_id,
                .controller_generation = prepared.next_generation,
                .reason = "takeover",
            } });
            defer self.allocator.free(event_body);
            const event_frame = self.encodeWithFlags(
                .event,
                0,
                old_record.stream_id,
                0,
                event_body,
            ) catch {
                return error.OutOfMemory;
            };
            revocation = .{
                .subscription = old,
                .frame = event_frame,
            };
        };
        prepared_owned = false;
        success_owned = false;
        stale_owned = false;
        exhausted_owned = false;
        return .{ .controller_transition_requested = .{
            .prepared = prepared,
            .success_reply = success_reply,
            .stale_reply = stale_reply,
            .exhausted_reply = exhausted_reply,
            .revocation = revocation,
        } };
    }

    fn dispatchControllerStatus(
        self: *Connection,
        request_id: u64,
        params: ?std.json.ObjectMap,
    ) HandleError!Action {
        if (!self.controller_transfer_v1)
            return self.replyError(request_id, .unauthorized);
        const p = params orelse return self.replyError(request_id, .invalid_request);
        if (p.count() != 1) return self.replyError(request_id, .invalid_request);
        const stream = intFieldU64(p, "stream_id") orelse
            return self.replyError(request_id, .invalid_request);
        const attachment = self.attachments.get(stream) orelse
            return self.replyError(request_id, .invalid_request);
        const generation = self.registry.controllerGeneration(
            attachment.runtime_id,
        ) catch return self.replyError(request_id, .runtime_not_found);
        const capabilities = self.registry.capabilitiesOfSubscription(
            attachment.runtime_id,
            attachment.subscription_id,
        );
        const body = try self.stringify(.{ .result = .{
            .stream_id = stream,
            .controller_generation = generation,
            .controller = reg.Capability.has(capabilities, reg.Capability.input),
        } });
        defer self.allocator.free(body);
        return self.replyResult(request_id, body);
    }

    /// `runtime.resync`(§9 desync 복구): 이 stream 구독에 fresh snapshot 재요청을 표시한다 — 다음 `collectDeltas`가 delta 대신
    /// 현재 full snapshot을 push해 client 조립기의 generation gap을 리셋한다. delta는 base_generation이 현재라 stale client를
    /// 못 고치므로(applyDelta가 또 GenerationGap) snapshot이 유일한 복구다. 모르는 stream_id는 invalid_request. runtime 유지.
    fn dispatchResync(self: *Connection, request_id: u64, params: ?std.json.ObjectMap) HandleError!Action {
        const p = params orelse return self.replyError(request_id, .invalid_request);
        const stream = intFieldU64(p, "stream_id") orelse return self.replyError(request_id, .invalid_request);
        const sub = self.attachments.getPtr(stream) orelse return self.replyError(request_id, .invalid_request);
        sub.resync_pending = true;
        const body = try self.stringify(.{ .result = .{ .resync = true } });
        defer self.allocator.free(body);
        return self.replyResult(request_id, body);
    }

    fn dispatchCatchup(
        self: *Connection,
        request_id: u64,
        params: ?std.json.ObjectMap,
        now_ns: u64,
    ) HandleError!Action {
        if (!self.runtime_catchup_barrier_v1)
            return self.replyError(request_id, .unauthorized);
        const owner = self.subscription_identity orelse
            return self.replyError(request_id, .unauthorized);
        const p = params orelse return self.replyError(request_id, .invalid_request);
        if (p.count() != 2) return self.replyError(request_id, .invalid_request);
        const stream = intFieldU64(p, "stream_id") orelse
            return self.replyError(request_id, .invalid_request);
        const nonce_text = strField(p, "request_nonce") orelse
            return self.replyError(request_id, .invalid_request);
        const request_nonce = parseHex128(nonce_text) orelse
            return self.replyError(request_id, .invalid_request);
        const sub = self.attachments.get(stream) orelse
            return self.replyError(request_id, .runtime_not_found);
        if (!reg.Capability.has(
            self.registry.capabilitiesOfSubscription(sub.runtime_id, sub.subscription_id),
            reg.Capability.observe,
        )) return self.replyError(request_id, .unauthorized);

        const identity: catchup_barrier_contract.CatchupIdentity = .{
            .host_id = self.host_id,
            .subscription = sub.subscription_id,
            .runtime_id = sub.runtime_id,
            .connection = owner.connection,
            .request_nonce = request_nonce,
        };
        const expires_at_ns = now_ns +| catchup_host_expiry_ns;
        const before = sub.catchup;
        var after = before;
        const result = after.arm(identity, now_ns, expires_at_ns);
        if (result == .invalid) return self.replyError(request_id, .invalid_request);
        var host_id_buf: [32]u8 = undefined;
        const host_id_text = std.fmt.bufPrint(&host_id_buf, "{x:0>32}", .{identity.host_id}) catch
            return error.OutOfMemory;
        var runtime_id_buf: [32]u8 = undefined;
        const runtime_id_text = std.fmt.bufPrint(&runtime_id_buf, "{x:0>32}", .{identity.runtime_id}) catch
            return error.OutOfMemory;
        var subscription_buf: [16]u8 = undefined;
        const subscription_text = std.fmt.bufPrint(&subscription_buf, "{x:0>16}", .{identity.subscription.value}) catch
            return error.OutOfMemory;
        var connection_id_buf: [16]u8 = undefined;
        const connection_id_text = std.fmt.bufPrint(&connection_id_buf, "{x:0>16}", .{identity.connection.monotonic_id}) catch
            return error.OutOfMemory;
        var connection_generation_buf: [16]u8 = undefined;
        const connection_generation_text = std.fmt.bufPrint(&connection_generation_buf, "{x:0>16}", .{identity.connection.slot_generation}) catch
            return error.OutOfMemory;
        const body = try self.stringify(.{ .result = .{
            .catchup = @tagName(result),
            .stream_id = stream,
            .request_nonce = nonce_text,
            .host_id = host_id_text,
            .runtime_id = runtime_id_text,
            .subscription_id = subscription_text,
            .connection_id = connection_id_text,
            .connection_generation = connection_generation_text,
        } });
        defer self.allocator.free(body);
        const reply = switch (try self.replyResult(request_id, body)) {
            .reply => |bytes| bytes,
            else => unreachable,
        };
        return .{ .catchup_arm_requested = .{
            .reply = reply,
            .stream = stream,
            .identity = identity,
            .now_ns = now_ns,
            .expires_at_ns = expires_at_ns,
            .before = before,
            .after = after,
            .result = result,
        } };
    }

    /// `runtime.core_command`: strict bounded wire command를 이 stream의 host core reader queue로 라우팅한다.
    /// observer가 focus/config/viewport를 바꾸지 못하도록 controller input capability를 같은 경계에서 검사한다.
    fn dispatchCoreCommand(self: *Connection, request_id: u64, params: ?std.json.ObjectMap) HandleError!Action {
        const p = params orelse return self.replyError(request_id, .invalid_request);
        const stream = intFieldU64(p, "stream_id") orelse return self.replyError(request_id, .invalid_request);
        const sub = self.attachments.get(stream) orelse return self.replyError(request_id, .invalid_request);
        const runtime_id = sub.runtime_id;
        if (!reg.Capability.has(self.registry.capabilitiesOfSubscription(runtime_id, sub.subscription_id), reg.Capability.input))
            return self.replyError(request_id, .unauthorized);
        const command = core_command_wire.decodeParams(p) orelse return self.replyError(request_id, .invalid_request);
        if (self.runtime_ops) |ops| {
            ops.core_command(ops.ctx, runtime_id, command) catch return self.replyError(request_id, .internal);
        }
        const body = try self.stringify(.{ .result = .{ .applied = true } });
        defer self.allocator.free(body);
        return self.replyResult(request_id, body);
    }

    /// `runtime.report_mouse`(§ 입력 패리티): client가 보낸 마우스 이벤트를 host core에 report_mouse로 적용하면 host가
    /// **자기 mouse_tracking/format**으로 SGR/x10 리포트를 인코딩해 PTY로 흘린다(인코딩 모드가 host에만 있어 host가
    /// 인코딩·주입). 모르는 stream_id는 invalid_request. 좌표/버튼은 wire 범위로 clamp(악성/버그 client 방어).
    fn dispatchReportMouse(self: *Connection, request_id: u64, params: ?std.json.ObjectMap) HandleError!Action {
        const p = params orelse return self.replyError(request_id, .invalid_request);
        const stream = intFieldU64(p, "stream_id") orelse return self.replyError(request_id, .invalid_request);
        const sub = self.attachments.get(stream) orelse return self.replyError(request_id, .invalid_request);
        const runtime_id = sub.runtime_id;
        if (!reg.Capability.has(
            self.registry.capabilitiesOfSubscription(runtime_id, sub.subscription_id),
            reg.Capability.input,
        ))
            return self.replyError(request_id, .unauthorized);
        const report = MouseReport{
            .button = @intCast(@min(intFieldU64(p, "button") orelse 0, std.math.maxInt(u8))),
            .col = @intCast(@min(intFieldU64(p, "col") orelse 0, std.math.maxInt(u16))),
            .row = @intCast(@min(intFieldU64(p, "row") orelse 0, std.math.maxInt(u16))),
            .x_px = @intCast(@min(intFieldU64(p, "x_px") orelse 0, std.math.maxInt(u16))),
            .y_px = @intCast(@min(intFieldU64(p, "y_px") orelse 0, std.math.maxInt(u16))),
            .pressed = boolField(p, "pressed"),
            .motion = boolField(p, "motion"),
            .mods = @intCast(@min(intFieldU64(p, "mods") orelse 0, std.math.maxInt(u8))),
        };
        if (self.runtime_ops) |ops| {
            ops.report_mouse(ops.ctx, runtime_id, report) catch return self.replyError(request_id, .internal);
        }
        const body = try self.stringify(.{ .result = .{ .applied = true } });
        defer self.allocator.free(body);
        return self.replyResult(request_id, body);
    }

    /// `runtime.selected_text`(§6b 원격 선택 복사): client가 보낸 뷰포트 span 또는 additive 전체 선택 의도를 host core에 적용해 `extractSelection`으로
    /// 텍스트를 뽑아 `{text}`로 응답한다(host가 콘텐츠 소유 = 선택 의미론 단일 출처, client는 span만 보내고 host가 해석). 모르는
    /// stream_id는 invalid_request. read-only host면 빈 text. 추출 텍스트는 임의 바이트라 host가 실 JSON encoder로 escape한다.
    fn dispatchSelectedText(self: *Connection, request_id: u64, params: ?std.json.ObjectMap) HandleError!Action {
        const p = params orelse return self.replyError(request_id, .invalid_request);
        const stream = intFieldU64(p, "stream_id") orelse return self.replyError(request_id, .invalid_request);
        const sub = self.attachments.get(stream) orelse return self.replyError(request_id, .invalid_request);
        const runtime_id = sub.runtime_id;
        const span = SelectSpan{
            .sr = intField(p, "sr") orelse 0,
            .sc = intField(p, "sc") orelse 0,
            .er = intField(p, "er") orelse 0,
            .ec = intField(p, "ec") orelse 0,
            .block = boolField(p, "block"),
            .all = optionalBoolField(p, "all") orelse return self.replyError(request_id, .invalid_request),
            .authoritative = optionalBoolField(p, "authoritative") orelse return self.replyError(request_id, .invalid_request),
        };
        if ((span.all or span.authoritative) and !reg.Capability.has(
            self.registry.capabilitiesOfSubscription(runtime_id, sub.subscription_id),
            reg.Capability.input,
        )) return self.replyError(request_id, .unauthorized);
        const body = if (self.runtime_ops) |ops|
            ops.selected_text(ops.ctx, runtime_id, span, self.allocator) catch return self.replyError(request_id, .internal)
        else
            (self.allocator.dupe(u8, "{\"text\":\"\"}") catch return error.OutOfMemory);
        defer self.allocator.free(body);
        return self.replyResult(request_id, body);
    }

    /// `runtime.clipboard_write`: host가 모아 둔 OSC 52 write 텍스트를 넘긴다(가져가면 비운다). 대기 중이 없으면
    /// 빈 text. 임의 바이트라 host가 실 JSON encoder로 escape한다. 정책·NSPasteboard 쓰기는 client 몫이다.
    fn dispatchClipboardWrite(self: *Connection, request_id: u64, params: ?std.json.ObjectMap) HandleError!Action {
        const p = params orelse return self.replyError(request_id, .invalid_request);
        const stream = intFieldU64(p, "stream_id") orelse return self.replyError(request_id, .invalid_request);
        const sub = self.attachments.get(stream) orelse return self.replyError(request_id, .invalid_request);
        const runtime_id = sub.runtime_id;
        // 이 RPC는 host 상태를 **소비**한다(가져가면 write 버퍼가 비워진다). observer 모드 attachment가 controller의
        // 클립보드를 가로채지 못하도록 core_command와 같은 경계에서 input capability를 확인한다.
        if (!reg.Capability.has(self.registry.capabilitiesOfSubscription(runtime_id, sub.subscription_id), reg.Capability.input))
            return self.replyError(request_id, .unauthorized);
        const body = if (self.runtime_ops) |ops|
            ops.clipboard_write(ops.ctx, runtime_id, self.allocator) catch return self.replyError(request_id, .internal)
        else
            (self.allocator.dupe(u8, "{\"text\":\"\"}") catch return error.OutOfMemory);
        defer self.allocator.free(body);
        return self.replyResult(request_id, body);
    }

    /// `runtime.link_at`(원격 Cmd+클릭 링크 열기): client가 보낸 뷰포트 (row,col)에서 host가 `extractUrlAt`으로 링크를
    /// 추출하고 file_path면 자기 cwd/$HOME으로 resolve + 존재 stat까지 해 `{text,kind}`로 응답한다. client가 자기 FS로
    /// stat하면 host 쪽 경로를 잘못 판정하므로 검증은 host가 한다. `scopes`는 client의 `input.link-detection` 비트
    /// (host는 정책을 모르므로 client가 보낸 대로 적용 — hover 필터와 같은 값이라 "밑줄=열림"이 유지된다).
    /// 모르는 stream_id는 invalid_request. read-only host면 빈 text. 추출 텍스트는 임의 바이트라 실 JSON encoder로 escape.
    fn dispatchLinkAt(self: *Connection, request_id: u64, params: ?std.json.ObjectMap) HandleError!Action {
        const p = params orelse return self.replyError(request_id, .invalid_request);
        const stream = intFieldU64(p, "stream_id") orelse return self.replyError(request_id, .invalid_request);
        const runtime_id = (self.attachments.get(stream) orelse return self.replyError(request_id, .invalid_request)).runtime_id;
        const row = intField(p, "row") orelse 0;
        const col = intField(p, "col") orelse 0;
        const scopes: u8 = @truncate(intFieldU64(p, "scopes") orelse 0);
        const body = if (self.runtime_ops) |ops|
            ops.link_at(ops.ctx, runtime_id, row, col, scopes, self.allocator) catch return self.replyError(request_id, .internal)
        else
            (self.allocator.dupe(u8, "{\"text\":\"\"}") catch return error.OutOfMemory);
        defer self.allocator.free(body);
        return self.replyResult(request_id, body);
    }

    /// `runtime.select_op`(§6b-2 단어/줄/전체 선택): client가 보낸 (op, row, col)로 host가 콘텐츠 인지 경계를 계산해
    /// (`selectWordAt`/`selectLineAt`/`selectAll`) 결과 뷰포트 선택 span을 응답한다(client가 그 span을 placeholder에 적용해 하이라이트).
    /// 모르는 stream_id는 invalid_request. read-only host는 `{sel:false}`. span은 primitive라 escape 불필요(정수/bool).
    fn dispatchSelectOp(self: *Connection, request_id: u64, params: ?std.json.ObjectMap) HandleError!Action {
        const p = params orelse return self.replyError(request_id, .invalid_request);
        const stream = intFieldU64(p, "stream_id") orelse return self.replyError(request_id, .invalid_request);
        const op = strField(p, "op") orelse return self.replyError(request_id, .invalid_request);
        const row = intField(p, "row") orelse 0;
        const col = intField(p, "col") orelse 0;
        const separators_hex = strField(p, "separators_hex") orelse "";
        const sub = self.attachments.get(stream) orelse return self.replyError(request_id, .invalid_request);
        const runtime_id = sub.runtime_id;
        if (!reg.Capability.has(
            self.registry.capabilitiesOfSubscription(runtime_id, sub.subscription_id),
            reg.Capability.input,
        )) return self.replyError(request_id, .unauthorized);
        const body = if (self.runtime_ops) |ops|
            ops.select_op(ops.ctx, runtime_id, op, row, col, separators_hex, self.allocator) catch return self.replyError(request_id, .internal)
        else
            (self.allocator.dupe(u8, "{\"sel\":false}") catch return error.OutOfMemory);
        defer self.allocator.free(body);
        return self.replyResult(request_id, body);
    }

    /// `runtime.find`(§6c 원격 검색): client가 보낸 검색어(hex)로 host가 콘텐츠·스크롤백에서 매치를 찾아(`findMatches`) 보이는
    /// 매치의 뷰포트 span 배열 + 전체 매치 수를 `{count, spans:[...]}`로 응답한다. 모르는 stream_id는 invalid_request. read-only
    /// host는 `{count:0,spans:[]}`. span은 primitive(정수)라 escape 불필요, 검색어만 hex(임의 텍스트).
    fn dispatchFind(self: *Connection, request_id: u64, params: ?std.json.ObjectMap) HandleError!Action {
        const p = params orelse return self.replyError(request_id, .invalid_request);
        const stream = intFieldU64(p, "stream_id") orelse return self.replyError(request_id, .invalid_request);
        const query_hex = strField(p, "q") orelse "";
        const cur_index: u32 = @intCast(intFieldU64(p, "cur") orelse 0);
        const scroll = boolField(p, "scroll");
        const attachment = self.attachments.get(stream) orelse
            return self.replyError(request_id, .invalid_request);
        const runtime_id = attachment.runtime_id;
        if (scroll and !reg.Capability.has(
            self.registry.capabilitiesOfSubscription(
                runtime_id,
                attachment.subscription_id,
            ),
            reg.Capability.input,
        )) return self.replyError(request_id, .unauthorized);
        const body = if (self.runtime_ops) |ops|
            ops.find(ops.ctx, runtime_id, query_hex, cur_index, scroll, self.allocator) catch return self.replyError(request_id, .internal)
        else
            (self.allocator.dupe(u8, "{\"count\":0,\"cur\":[],\"spans\":[]}") catch return error.OutOfMemory);
        defer self.allocator.free(body);
        return self.replyResult(request_id, body);
    }

    fn hasRuntimeCapability(
        self: *Connection,
        runtime_id: u128,
        capability: u8,
    ) bool {
        var it = self.attachments.valueIterator();
        while (it.next()) |attachment| {
            if (attachment.runtime_id != runtime_id) continue;
            if (reg.Capability.has(
                self.registry.capabilitiesOfSubscription(
                    runtime_id,
                    attachment.subscription_id,
                ),
                capability,
            )) return true;
        }
        return false;
    }

    /// `runtime.resize`: controller가 canonical PTY size를 바꾼다(§9). registry가 controller/sequence를 검증하고, 실제
    /// 크기가 바뀔 때만 owner가 response+event 전체를 선예약한 뒤 runtime_ops(실 `TerminalCore`+`TIOCSWINSZ`)에
    /// 적용하고 registry를 commit한다. observer의 resize는 unauthorized, stale sequence는 `{stale:true}`.
    fn dispatchResize(self: *Connection, request_id: u64, params: ?std.json.ObjectMap) HandleError!Action {
        _ = self.runtime_ops orelse return self.replyError(request_id, .unauthorized);
        const p = params orelse return self.replyError(request_id, .invalid_request);
        const stream = intFieldU64(p, "stream_id") orelse return self.replyError(request_id, .invalid_request);
        const cols = intField(p, "cols") orelse return self.replyError(request_id, .invalid_request);
        const rows = intField(p, "rows") orelse return self.replyError(request_id, .invalid_request);
        const seq = intFieldU64(p, "client_sequence") orelse
            return self.replyError(request_id, .invalid_request);
        const sub = self.attachments.get(stream) orelse return self.replyError(request_id, .invalid_request);
        const runtime_id = sub.runtime_id;

        var prepared = self.registry.prepareResizeSubscription(
            runtime_id,
            sub.subscription_id,
            cols,
            rows,
            seq,
        ) catch |e| switch (e) {
            error.NotController => return self.replyError(request_id, .unauthorized),
            error.RuntimeNotFound => return self.replyError(request_id, .runtime_not_found),
            error.InvalidGridSize => return self.replyError(request_id, .invalid_request),
            error.AggregateGridLimitReached, error.ResizeGenerationExhausted => return self.replyError(request_id, .resource_exhausted),
            else => return self.replyError(request_id, .internal),
        };
        switch (prepared.preview()) {
            .stale => {
                const body = try self.stringify(.{ .result = .{ .stale = true } });
                defer self.allocator.free(body);
                return self.replyResult(request_id, body);
            },
            .applied => |a| {
                const body = try self.stringify(.{ .result = .{
                    .cols = a.cols,
                    .rows = a.rows,
                    .client_sequence = seq,
                    .resize_generation = a.resize_generation,
                    .changed = a.changed,
                } });
                defer self.allocator.free(body);
                const success = try self.encodeSmall(.response, request_id, 0, body);
                errdefer self.allocator.free(success);
                const internal = try self.replyErrorFrame(request_id, .internal);
                errdefer self.allocator.free(internal);
                const exhausted = try self.replyErrorFrame(request_id, .resource_exhausted);
                errdefer self.allocator.free(exhausted);
                var event_body: ?[]u8 = null;
                errdefer if (event_body) |bytes| self.allocator.free(bytes);
                if (a.changed) {
                    const runtime_hex = try self.hex128(runtime_id);
                    defer self.allocator.free(runtime_hex);
                    event_body = try self.stringify(.{
                        .event = "runtime.resized",
                        .data = .{
                            .runtime_id = runtime_hex,
                            .cols = a.cols,
                            .rows = a.rows,
                            .resize_generation = a.resize_generation,
                            .reason = "controller",
                        },
                    });
                }
                return .{ .resize_requested = .{
                    .prepared = prepared,
                    .runtime_id = runtime_id,
                    .success_reply = success,
                    .internal_reply = internal,
                    .exhausted_reply = exhausted,
                    .event_body = event_body,
                } };
            },
        }
    }

    pub fn discardPreparedResize(self: *Connection, resize: *Action.ResizeRequested) void {
        self.allocator.free(resize.success_reply);
        self.allocator.free(resize.internal_reply);
        self.allocator.free(resize.exhausted_reply);
        if (resize.event_body) |body| self.allocator.free(body);
        resize.* = undefined;
    }

    /// `input_bytes`: controller가 보낸 terminal input을 runtime PTY로 보낸다(§9 `input` capability). 응답 없는 stream
    /// frame이라 항상 `.none`이다. 미attach stream·비controller·runtime_ops 없음이면 조용히 버린다(connection은 유지 —
    /// detach 직후 도착한 stray input은 benign race라 연결을 끊지 않는다).
    fn routeInput(self: *Connection, frame: framing.Frame) HandleError!Action {
        const stream = frame.header.stream_id;
        const sub = self.attachments.get(stream) orelse return .none;
        const runtime_id = sub.runtime_id;
        if (!reg.Capability.has(self.registry.capabilitiesOfSubscription(runtime_id, sub.subscription_id), reg.Capability.input)) return .none;
        const ops = self.runtime_ops orelse return .none;
        ops.write_input(ops.ctx, runtime_id, frame.payload) catch {
            // controller bytes는 ACK 없는 ownership transfer다. host queue admission 실패 뒤 연결을 usable로
            // 두면 client는 성공으로 간주한 입력을 영구 유실하므로 EOF detach/reconnect 경계로 fail-close한다.
            self.state = .closed;
            return .close;
        };
        return .none;
    }

    /// Allocation-free fire-and-forget resync acknowledgement used by the UI frame pump. Only a
    /// host that emitted `snapshot.invalidated` can require this new same-major frame.
    fn routeStreamAck(self: *Connection, frame: framing.Frame) HandleError!Action {
        if (frame.header.request_id != 0 or frame.header.stream_id == 0 or
            frame.header.flags != 0 or
            !std.mem.eql(u8, frame.payload, "{\"action\":\"resync\"}"))
        {
            self.state = .closed;
            return .close;
        }
        const sub = self.attachments.getPtr(frame.header.stream_id) orelse return .none;
        if (!sub.awaiting_resync_ack) return .none;
        sub.awaiting_resync_ack = false;
        sub.resync_pending = true;
        return .{ .resync_ack = frame.header.stream_id };
    }

    /// `scroll_to_bottom`: controller 전용 fire-and-forget viewport command. AppKit IME callback에서
    /// request/response 왕복을 기다리지 않도록 payload 없는 stream frame으로 받는다. 같은 connection의
    /// 다음 `input_bytes`보다 먼저 dispatch되므로 scroll barrier의 wire 순서를 보존한다.
    fn routeScrollToBottom(self: *Connection, frame: framing.Frame) HandleError!Action {
        if (frame.payload.len != 0) return .none;
        const stream = frame.header.stream_id;
        const sub = self.attachments.get(stream) orelse return .none;
        const runtime_id = sub.runtime_id;
        if (!reg.Capability.has(self.registry.capabilitiesOfSubscription(runtime_id, sub.subscription_id), reg.Capability.input)) return .none;
        const ops = self.runtime_ops orelse return .none;
        ops.core_command(ops.ctx, runtime_id, .scroll_to_bottom) catch {
            self.state = .closed;
            return .close;
        };
        return .none;
    }

    /// `core_command`: controller 전용 fire-and-forget host-core command. payload의 stream_id도 header와 같아야
    /// 하므로 JSON을 다른 stream header에 재사용할 수 없다. malformed command는 응답할 request_id가 없고 framing
    /// 의미가 불명확하므로 fail-closed하며, detach 직후의 미attach/권한 없는 stream은 input과 같이 benign drop한다.
    fn routeCoreCommandFrame(self: *Connection, frame: framing.Frame) HandleError!Action {
        const stream = frame.header.stream_id;
        const sub = self.attachments.get(stream) orelse return .none;
        const runtime_id = sub.runtime_id;
        if (!reg.Capability.has(self.registry.capabilitiesOfSubscription(runtime_id, sub.subscription_id), reg.Capability.input)) return .none;
        const ops = self.runtime_ops orelse return .none;

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, frame.payload, .{}) catch {
            self.state = .closed;
            return .close;
        };
        defer parsed.deinit();
        const params = switch (parsed.value) {
            .object => |object| object,
            else => {
                self.state = .closed;
                return .close;
            },
        };
        if (intFieldU64(params, "stream_id") != stream) {
            self.state = .closed;
            return .close;
        }
        const command = core_command_wire.decodeParams(params) orelse {
            self.state = .closed;
            return .close;
        };
        ops.core_command(ops.ctx, runtime_id, command) catch {
            // 응답 없는 frame의 host queue admission(OOM/QueueClosed)이 실패하면 command를 재전송할 ACK가 없다.
            // 성공처럼 connection을 유지해 최종 focus/config를 조용히 잃지 말고 connection 전체를 fail-close한다.
            self.state = .closed;
            return .close;
        };
        return .none;
    }

    /// attach된 각 stream의 화면 변화를 모아 push할 frame들을 만든다(§9·§10 delta stream). stream별 `base`(마지막 full
    /// snapshot) 대비 `RuntimeOps.delta`로 diff해, 변화가 있으면 `delta_chunk`(또는 geometry 변화면 fresh `snapshot_chunk`)
    /// frame으로 싣고 base를 갱신한다. 보낼 게 없으면 null. caller(socket serve loop)가 poll tick마다 불러 그 프레임을
    /// 순서대로 write한다(단일 스레드 push — reader는 core만 쓰고 이 diff는 host가 core lock 아래 한다). read-only host는 항상 null.
    pub fn collectDeltas(self: *Connection) HandleError!?[][]u8 {
        const streams = try self.localStreams(self.allocator);
        defer self.allocator.free(streams);
        var all: std.ArrayListUnmanaged([]u8) = .empty;
        errdefer {
            for (all.items) |frame| self.allocator.free(frame);
            all.deinit(self.allocator);
        }
        for (streams) |stream| {
            var output = self.collectOutputForLocalStream(stream) catch |err| switch (err) {
                error.ProjectionBudgetUnavailable => return error.OutOfMemory,
                else => |other| return other,
            } orelse continue;
            const frames = output.takeFrames();
            all.appendSlice(self.allocator, frames) catch {
                for (frames) |frame| self.allocator.free(frame);
                self.allocator.free(frames);
                output.rollback(self);
                return error.OutOfMemory;
            };
            self.allocator.free(frames);
            output.commit(self);
        }
        if (all.items.len == 0) {
            all.deinit(self.allocator);
            return null;
        }
        return all.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
    }

    /// Readiness adapters call this with one local stream so a noisy subscription cannot make one
    /// turn materialize every attachment's metadata and screen output outside the charged queue.
    /// The returned state does not mutate base/revision until queue admission calls `commit`.
    pub fn collectOutputForLocalStream(
        self: *Connection,
        stream: subscription_identity.LocalStreamId,
    ) (HandleError || error{ProjectionBudgetUnavailable})!?CollectedOutput {
        return self.collectOutputForLocalStreamAt(stream, 0);
    }

    pub fn collectOutputForLocalStreamAt(
        self: *Connection,
        stream: subscription_identity.LocalStreamId,
        now_ns: u64,
    ) (HandleError || error{ProjectionBudgetUnavailable})!?CollectedOutput {
        return self.collectOutputForLocalStreamAtEpoch(stream, now_ns, now_ns);
    }

    pub fn collectOutputForLocalStreamAtEpoch(
        self: *Connection,
        stream: subscription_identity.LocalStreamId,
        now_ns: u64,
        observation_epoch_ns: u64,
    ) (HandleError || error{ProjectionBudgetUnavailable})!?CollectedOutput {
        const ops = self.runtime_ops orelse return null;
        const sub = self.attachments.getPtr(stream) orelse return null;
        var list: std.ArrayListUnmanaged([]u8) = .empty;
        errdefer {
            for (list.items) |frame| self.allocator.free(frame);
            list.deinit(self.allocator);
        }
        var output: CollectedOutput = .{
            .allocator = self.allocator,
            .stream = stream,
            .frames = &.{},
            .previous_observation_ticks = sub.observation_ticks,
        };
        errdefer output.rollback(self);
        if (self.projection_budget) |budget| {
            output.base_reservation = budget.prepare(
                budget.ctx,
                stream,
                connection_slot.base_update_max_bytes,
            ) orelse return error.ProjectionBudgetUnavailable;
        }

        sub.observation_ticks +%= 1;
        if (self.runtime_metadata_v1 and
            (sub.observation_ticks >= 5 or ops.observation_urgent(ops.ctx, sub.runtime_id)))
        {
            sub.observation_ticks = 0;
            const maybe_observation = ops.cached_observation(
                ops.ctx,
                sub.runtime_id,
                .{ .cadence_epoch = observation_epoch_ns },
            ) catch |err| switch (err) {
                error.RuntimeNotFound => {
                    if (!self.runtimeMissing(stream)) return error.OutOfMemory;
                    output.rollback(self);
                    self.endMissingRuntime(stream);
                    return null;
                },
                error.InvalidObservation,
                error.ObservationTokenExhausted,
                error.ObservationTransactionCorrupt,
                => {
                    self.state = .closed;
                    output.rollback(self);
                    return null;
                },
                error.TransientObservationUnavailable => null,
                else => return error.OutOfMemory,
            };
            if (maybe_observation) |obs| {
                const current = obs.canonical_json;
                const changed = sub.observation_token != obs.change_token;
                if (changed) {
                    const next_revision = std.math.add(
                        u64,
                        sub.observation_revision,
                        1,
                    ) catch {
                        self.state = .closed;
                        output.rollback(self);
                        return null;
                    };
                    const event_body = try self.stringify(.{
                        .event = "runtime.metadata",
                        .metadata_revision = next_revision,
                        .metadata = RawCanonicalObservation{ .bytes = current },
                    });
                    defer self.allocator.free(event_body);
                    const frame = self.encodeWithFlags(
                        .event,
                        0,
                        stream,
                        0,
                        event_body,
                    ) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.PayloadTooLarge => {
                            self.state = .closed;
                            output.rollback(self);
                            return null;
                        },
                    };
                    list.append(self.allocator, frame) catch {
                        self.allocator.free(frame);
                        return error.OutOfMemory;
                    };
                    output.next_observation_token = obs.change_token;
                    output.next_observation_revision = next_revision;
                }
            }
        }

        // Read once before projection. A reader mutation racing after this read advances a later
        // token and therefore schedules another delta; reading after projection could instead
        // stamp a base with a mutation it did not contain and lose that wake.
        const screen_change_token: ?ScreenChangeToken = if (ops.screen_change_token) |read_token|
            read_token(ops.ctx, sub.runtime_id) catch |err| switch (err) {
                error.RuntimeNotFound => {
                    if (!self.runtimeMissing(stream)) return error.OutOfMemory;
                    self.discardPreparedOutput(&list, &output);
                    output.rollback(self);
                    self.endMissingRuntime(stream);
                    return null;
                },
                else => return error.OutOfMemory,
            }
        else
            null;
        const screen_changed = screen_change_token == null or
            sub.screen_change_token == null or
            !std.meta.eql(screen_change_token.?, sub.screen_change_token.?);
        const screen_incarnation_changed = if (screen_change_token) |current|
            if (sub.screen_change_token) |committed|
                current.incarnation != committed.incarnation
            else
                false
        else
            false;

        if (sub.resync_pending or screen_incarnation_changed) {
            // Invalidation releases both screen and metadata delivery authority. A metadata-capable
            // client must therefore receive a fresh prefix in the same atomic recovery batch; a
            // transient observation/encoding miss cannot be committed as snapshot-only recovery.
            if (sub.resync_pending and self.runtime_metadata_v1 and sub.observation_token == null and
                output.next_observation_token == null)
            {
                self.discardPreparedOutput(&list, &output);
                sub.observation_ticks = output.previous_observation_ticks;
                output.rollback(self);
                return null;
            }
            const next_sequence = std.math.add(u64, sub.screen_sequence, 1) catch
                return error.OutOfMemory;
            const projected = ops.snapshot(ops.ctx, sub.runtime_id, next_sequence, self.allocator) catch |err| {
                if (err == error.RuntimeNotFound) {
                    if (!self.runtimeMissing(stream)) return error.OutOfMemory;
                    self.discardPreparedOutput(&list, &output);
                    output.rollback(self);
                    self.endMissingRuntime(stream);
                    return null;
                }
                if (err != error.TransientSnapshotUnavailable)
                    return error.OutOfMemory;
                // Metadata and snapshot are one recovery transaction. Never expose a metadata-only
                // batch to an adapter when the snapshot producer failed.
                self.discardPreparedOutput(&list, &output);
                sub.observation_ticks = output.previous_observation_ticks;
                output.rollback(self);
                return null;
            };
            defer self.allocator.free(projected.bytes);
            if (projected.bytes.len > protocol.max_viewport_snapshot or
                projected.frontier.sequence != next_sequence)
                return error.OutOfMemory;
            output.next_base = self.allocator.dupe(u8, projected.bytes) catch return error.OutOfMemory;
            output.replace_base = true;
            output.clear_resync = sub.resync_pending;
            output.next_screen_sequence = projected.frontier.sequence;
            output.next_screen_generation = projected.frontier.generation;
            output.next_screen_change_token = screen_change_token;
            try self.appendChunks(&list, .snapshot_chunk, stream, projected.bytes);
        } else if (sub.base) |base| if (screen_changed) {
            // A valid delta producer failure cannot be treated as "no change": bounded projection
            // overflow would then retry every tick forever while the client silently freezes on an
            // old base. The adapter fail-closes this connection and revokes its leases.
            const next_sequence = std.math.add(u64, sub.screen_sequence, 1) catch
                return error.OutOfMemory;
            const update = ops.delta(ops.ctx, sub.runtime_id, base, next_sequence, self.allocator) catch |err|
                switch (err) {
                    // Runtime teardown races are stream lifecycle, not transport corruption. The
                    // caller's existing ended/detach path must keep the shared connection usable.
                    error.RuntimeNotFound => {
                        if (!self.runtimeMissing(stream)) return error.OutOfMemory;
                        self.discardPreparedOutput(&list, &output);
                        output.rollback(self);
                        self.endMissingRuntime(stream);
                        return null;
                    },
                    // Projection cap/OOM and unknown producer failures cannot masquerade as an
                    // unchanged screen; fail-close prevents an infinite stale-base retry loop.
                    else => return error.OutOfMemory,
                };
            defer self.allocator.free(update.send);
            if (update.send.len > protocol.max_viewport_snapshot or
                update.new_base.len > protocol.max_viewport_snapshot)
            {
                self.allocator.free(update.new_base);
                return error.OutOfMemory;
            }
            output.next_base = update.new_base;
            output.replace_base = true;
            output.next_screen_change_token = screen_change_token;
            if (update.send.len != 0) {
                const kind: protocol.Kind = if (update.is_snapshot) .snapshot_chunk else .delta_chunk;
                try self.appendChunks(&list, kind, stream, update.send);
                if (update.frontier.sequence != next_sequence or
                    (!update.is_snapshot and update.frontier.generation != sub.screen_generation))
                    return error.OutOfMemory;
                output.next_screen_sequence = update.frontier.sequence;
                output.next_screen_generation = update.frontier.generation;
            } else if (update.frontier.sequence != sub.screen_sequence or
                update.frontier.generation != sub.screen_generation)
            {
                return error.OutOfMemory;
            }
        };

        if (sub.catchup == .pending) {
            const pending = sub.catchup.pending;
            const target: catchup_barrier_contract.ScreenFrontier = .{
                .generation = output.next_screen_generation orelse sub.screen_generation,
                .sequence = output.next_screen_sequence orelse sub.screen_sequence,
            };
            const barrier: catchup_barrier_contract.Barrier = .{
                .identity = pending.identity,
                .target = target,
            };
            const payload = barrier.encode() catch return error.OutOfMemory;
            const barrier_frame = self.encodeWithFlags(
                .screen_frontier_barrier,
                0,
                stream,
                0,
                &payload,
            ) catch return error.OutOfMemory;
            list.append(self.allocator, barrier_frame) catch {
                self.allocator.free(barrier_frame);
                return error.OutOfMemory;
            };
            var after = sub.catchup;
            after.admit(barrier, now_ns) catch return error.OutOfMemory;
            output.prepared_catchup = .{
                .before = sub.catchup,
                .after = after,
                .barrier = barrier,
                .now_ns = now_ns,
            };
        }

        if (list.items.len == 0 and !output.replace_base and
            output.next_observation_token == null)
        {
            output.rollback(self);
            return null;
        }
        output.frames = list.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
        output.frames_taken = false;
        return output;
    }

    /// Queue admission failure invalidates only this subscription and re-arms metadata observation.
    /// Snapshot production remains quiescent until the client returns the typed stream ack.
    pub fn markSubscriptionOutputInvalidated(
        self: *Connection,
        stream: subscription_identity.LocalStreamId,
    ) void {
        const sub = self.attachments.getPtr(stream) orelse return;
        sub.awaiting_resync_ack = true;
        self.resetBasesAfterPurge(stream, sub);
    }

    /// An explicit resync also purges already-committed but unsent metadata from the tracker queue.
    /// Re-emit that full state without opening a second ACK handshake.
    pub fn markResyncDeliveryPurged(
        self: *Connection,
        stream: subscription_identity.LocalStreamId,
    ) void {
        const sub = self.attachments.getPtr(stream) orelse return;
        self.resetBasesAfterPurge(stream, sub);
    }

    fn resetBasesAfterPurge(
        self: *Connection,
        stream: subscription_identity.LocalStreamId,
        sub: *Subscription,
    ) void {
        sub.observation_ticks = 5;
        if (self.projection_budget) |budget|
            budget.release(budget.ctx, stream);
        if (sub.base) |old| {
            self.allocator.free(old);
            sub.base = null;
        }
        sub.observation_token = null;
    }

    pub fn resyncPending(
        self: *const Connection,
        stream: subscription_identity.LocalStreamId,
    ) bool {
        return if (self.attachments.get(stream)) |sub| sub.resync_pending else false;
    }

    pub fn expireCatchups(self: *Connection, now_ns: u64) void {
        var iterator = self.attachments.valueIterator();
        while (iterator.next()) |sub| _ = sub.catchup.expire(now_ns);
    }

    pub fn streamHasInputCapability(
        self: *const Connection,
        stream: subscription_identity.LocalStreamId,
    ) bool {
        const sub = self.attachments.get(stream) orelse return false;
        return reg.Capability.has(
            self.registry.capabilitiesOfSubscription(sub.runtime_id, sub.subscription_id),
            reg.Capability.input,
        );
    }

    pub fn hasInputCapability(self: *const Connection) bool {
        var iterator = self.attachments.iterator();
        while (iterator.next()) |entry|
            if (self.streamHasInputCapability(entry.key_ptr.*)) return true;
        return false;
    }

    pub fn snapshotInvalidatedFrame(
        self: *Connection,
        stream: subscription_identity.LocalStreamId,
    ) HandleError![]u8 {
        const body = try self.stringify(.{ .event = "snapshot.invalidated" });
        defer self.allocator.free(body);
        return self.encodeWithFlags(.event, 0, stream, 0, body) catch error.OutOfMemory;
    }

    // ── JSON 응답 빌더 ──────────────────────────────────────────────────────

    fn helloAckJson(self: *Connection) HandleError![]u8 {
        const host_hex = try self.hostHex();
        defer self.allocator.free(host_hex);
        var capability_buf: [23][]const u8 = undefined;
        const capabilities = self.helloCapabilities(&capability_buf);
        if (!self.host_status.manifest_capable) {
            return self.stringify(.{
                .version = self.selected_version,
                .host_id = host_hex,
                .capabilities = capabilities,
            });
        }
        if (self.host_status.upgrade_capable) {
            return self.stringify(.{
                .version = self.selected_version,
                .host_id = host_hex,
                .build_id = self.host_status.build_id,
                .protocol_major = self.host_status.protocol_major,
                .screen_codec_version = self.host_status.screen_codec_version,
                .upgrade_epoch = self.host_status.upgrade_epoch,
                .lifecycle = @tagName(self.host_status.lifecycle),
                .authority_generation = self.host_status.authority_generation,
                .capabilities = capabilities,
            });
        }
        return self.stringify(.{
            .version = self.selected_version,
            .host_id = host_hex,
            .build_id = self.host_status.build_id,
            .protocol_major = self.host_status.protocol_major,
            .screen_codec_version = self.host_status.screen_codec_version,
            .upgrade_epoch = self.host_status.upgrade_epoch,
            .lifecycle = @tagName(self.host_status.lifecycle),
            .authority_generation = self.host_status.authority_generation,
            .capabilities = capabilities,
        });
    }

    fn helloCapabilities(self: *const Connection, buf: *[23][]const u8) []const []const u8 {
        var count: usize = 0;
        const append = struct {
            fn one(target: *[23][]const u8, index: *usize, value: []const u8) void {
                target[index.*] = value;
                index.* += 1;
            }
        }.one;
        append(buf, &count, "host.info");
        append(buf, &count, "runtime.list");
        append(buf, &count, "runtime.get");
        if (self.host_status.manifest_capable) {
            append(buf, &count, "runtime_inventory_v1");
            append(buf, &count, "host_manifest_v1");
            if (self.host_status.upgrade_capable) append(buf, &count, "host_exec_upgrade_v1");
        }
        append(buf, &count, "admin_one_shot_v1");
        if (self.runtime_ops != null) append(buf, &count, "admin_runtime_end_v1");
        append(buf, &count, "runtime_metadata_v1");
        append(buf, &count, "runtime_ended_v1");
        append(buf, &count, "screen_stream_v2_current_body");
        append(buf, &count, "screen_viewport_scrolled_v1");
        append(buf, &count, "async_scroll_to_bottom_v1");
        append(buf, &count, "runtime_core_command_v1");
        append(buf, &count, "runtime_clear_screen_v1");
        append(buf, &count, "runtime_selected_text_v1");
        append(buf, &count, "runtime_selection_state_v1");
        append(buf, &count, "runtime_link_at_v1");
        append(buf, &count, "runtime_clipboard_v1");
        if (self.runtime_ops != null and self.subscription_identity != null) {
            append(buf, &count, "controller_transfer_v1");
            append(buf, &count, "notification_stream_auth_v1");
            append(buf, &count, "notification_delivery_v1");
        }
        if (self.subscription_identity != null)
            append(buf, &count, catchup_barrier_contract.capability);
        return buf[0..count];
    }

    fn hostInfoJson(self: *Connection) HandleError![]u8 {
        const status = self.currentHostStatus();
        const host_hex = try self.hostHex();
        defer self.allocator.free(host_hex);
        return self.stringify(.{ .result = .{
            .host_id = host_hex,
            .build_id = status.build_id,
            .protocol_major = status.protocol_major,
            .screen_codec_version = status.screen_codec_version,
            .upgrade_epoch = status.upgrade_epoch,
            .authority_generation = status.authority_generation,
            .lifecycle = @tagName(status.lifecycle),
            .runtime_count = self.registry.count(),
            .client_count = status.client_count,
        } });
    }

    fn currentHostStatus(self: *const Connection) HostStatus {
        return if (self.live_host_status) |status| status.* else self.host_status;
    }

    /// `runtime.get` 은 **title 을 싣지 않는다.** 이 응답의 소비자는 사람이 아니라 기계다 —
    /// `attach_product_resolver.decodeMembership` 과 `recovered_session_adopt` 가 **필드 수 6을
    /// 정확히 요구하며 fail-close** 한다("accepts only exact … envelope"). 그 strict 방어는 응답
    /// 드리프트를 잡으려고 일부러 그렇게 둔 것이라, 목록에 title 을 실으려고 그것을 느슨하게
    /// 만들지 않는다. 사람이 세션을 고르는 자리는 `runtime.list` 다(§8).
    fn runtimeMetaJson(self: *Connection, entry: *reg.RuntimeEntry) HandleError![]u8 {
        const id_hex = try self.hex128(entry.id);
        defer self.allocator.free(id_hex);
        return self.stringify(.{ .result = runtimeMetaValue(id_hex, entry) });
    }

    /// title 하나를 위해 observation 을 뜬다. **실패는 title 없음으로 접는다** — 목록 조회가
    /// 부가 정보 때문에 통째로 지면 안 된다(그 정보는 wire 에서 optional 이다).
    /// read-only host(`runtime_ops == null`)는 아예 안 부른다.
    fn observeForTitle(self: *Connection, runtime_id: u128) ?RuntimeObservation {
        const ops = self.runtime_ops orelse return null;
        return ops.observation(ops.ctx, runtime_id, self.allocator) catch null;
    }

    fn runtimeListJson(self: *Connection) HandleError![]u8 {
        // registry entry들을 순회해 redacted metadata 배열을 만든다. 각 hex 문자열을 arena로 모아 stringify 후 해제.
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        var list: std.ArrayListUnmanaged(RuntimeListEntry) = .empty;
        var it = self.registry.entries.valueIterator();
        while (it.next()) |entry_ptr| {
            const id_hex = std.fmt.allocPrint(a, "{x:0>32}", .{entry_ptr.*.id}) catch return error.OutOfMemory;
            // title 은 arena 로 복사해 든다 — observation 의 소유 버퍼는 이 걸음 끝에 풀린다.
            var observation = self.observeForTitle(entry_ptr.*.id);
            defer if (observation) |*o| o.deinit(self.allocator);
            const title: ?[]const u8 = if (observation) |o|
                (a.dupe(u8, clampTitle(o.window_title)) catch return error.OutOfMemory)
            else
                null;
            list.append(a, runtimeListEntryValue(id_hex, entry_ptr.*, title)) catch return error.OutOfMemory;
        }
        return self.stringify(.{ .result = .{ .runtimes = list.items } });
    }

    fn errorJson(self: *Connection, code: protocol.ErrorCode) HandleError![]u8 {
        return self.stringify(.{ .@"error" = code.wireName() });
    }

    // ── low-level helpers ──────────────────────────────────────────────────

    fn replyError(self: *Connection, request_id: u64, code: protocol.ErrorCode) HandleError!Action {
        return .{ .reply = try self.replyErrorFrame(request_id, code) };
    }

    fn replyErrorFrame(self: *Connection, request_id: u64, code: protocol.ErrorCode) HandleError![]u8 {
        const body = try self.errorJson(code);
        defer self.allocator.free(body);
        return try self.encodeSmall(.response, request_id, 0, body);
    }

    const FrameError = error{ OutOfMemory, PayloadTooLarge };

    fn encodeWithFlags(self: *Connection, kind: protocol.Kind, request_id: u64, stream_id: u64, flags: u32, payload: []const u8) FrameError![]u8 {
        return framing.encodeFrame(self.allocator, .{ .kind = kind, .request_id = request_id, .stream_id = stream_id, .flags = flags }, payload) catch |e| switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.PayloadTooLarge => error.PayloadTooLarge,
        };
    }

    fn encode(self: *Connection, kind: protocol.Kind, request_id: u64, stream_id: u64, payload: []const u8) FrameError![]u8 {
        return self.encodeWithFlags(kind, request_id, stream_id, 0, payload);
    }

    /// 크기가 고정적으로 작은 body(hello_ack·typed error·pong nonce)를 frame으로 싣는다. 이들은 control cap(256 KiB)을
    /// 넘을 수 없어 PayloadTooLarge는 도달 불가다(넘으면 codec 불변식 위반). result body는 `replyResult`를 써야 한다.
    fn encodeSmall(self: *Connection, kind: protocol.Kind, request_id: u64, stream_id: u64, payload: []const u8) HandleError![]u8 {
        return self.encode(kind, request_id, stream_id, payload) catch |e| switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.PayloadTooLarge => unreachable,
        };
    }

    /// result JSON을 response frame으로 싣되, control cap을 넘으면 connection을 끊지 않고 `payload_too_large` typed
    /// error로 응답한다(client가 request_id로 상관지을 수 있게, §10). runtime.list처럼 runtime 수에 비례해 커지는
    /// 응답을 조용히 드롭하지 않기 위함이다. error body는 짧아 재초과하지 않는다.
    fn replyResult(self: *Connection, request_id: u64, json: []const u8) HandleError!Action {
        const wire = self.encode(.response, request_id, 0, json) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.PayloadTooLarge => return self.replyError(request_id, .payload_too_large),
        };
        return .{ .reply = wire };
    }

    fn stringify(self: *Connection, value: anytype) HandleError![]u8 {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        js.write(value) catch return error.OutOfMemory;
        return self.allocator.dupe(u8, out.written()) catch return error.OutOfMemory;
    }

    fn hostHex(self: *Connection) HandleError![]u8 {
        return self.hex128(self.host_id);
    }
    fn hex128(self: *Connection, v: u128) HandleError![]u8 {
        return std.fmt.allocPrint(self.allocator, "{x:0>32}", .{v}) catch error.OutOfMemory;
    }
};

/// runtime metadata의 wire 표현(redacted — output/scrollback·cwd·command는 싣지 않는다, §11).
/// hex id 는 caller 가 소유.
///
/// **`runtime.get` 이 쓰는 정확히 6필드 모양이다.** 그 응답의 소비자는 기계이고
/// (`attach_product_resolver.decodeMembership`·`recovered_session_adopt`) **필드 수 6을 정확히
/// 요구하며 fail-close** 한다. 여기에 필드를 더하면 attach 와 recovery adopt 가 함께 진다.
const RuntimeMetaWire = struct {
    runtime_id: []const u8,
    cols: u16,
    rows: u16,
    resize_generation: u64,
    has_controller: bool,
    observer_count: usize,
};

/// `runtime.list` 전용 모양 — 위 6필드에 **title 하나**를 더한다(§8). 사람이 세션을 고르는 자리라
/// 여기만 낸다.
///
/// **optional 을 안 쓴다.** `std.json.Stringify` 는 null optional 도 `"title":null` 로 내보내
/// 필드 수를 늘린다 — 그러면 위 strict 소비자와 같은 함정을 목록에도 들이게 된다. 값이 없으면
/// 아예 이 모양을 안 쓰고 `RuntimeMetaWire` 를 쓴다.
const RuntimeMetaTitledWire = struct {
    runtime_id: []const u8,
    cols: u16,
    rows: u16,
    resize_generation: u64,
    has_controller: bool,
    observer_count: usize,
    title: []const u8,
};

/// 목록 한 줄. title 이 있으면 7필드 모양, 없으면 6필드 모양으로 직렬화된다.
const RuntimeListEntry = union(enum) {
    plain: RuntimeMetaWire,
    titled: RuntimeMetaTitledWire,

    pub fn jsonStringify(self: RuntimeListEntry, js: anytype) !void {
        switch (self) {
            .plain => |value| try js.write(value),
            .titled => |value| try js.write(value),
        }
    }
};

/// 상한 안으로 자르되 **UTF-8 경계를 지킨다** — 바이트로 자르면 깨진 시퀀스가 wire 로 나간다.
fn clampTitle(title: []const u8) []const u8 {
    if (title.len <= protocol.max_title_bytes) return title;
    var end = protocol.max_title_bytes;
    // continuation byte(10xxxxxx) 위에 서 있으면 그 문자의 시작까지 물러난다.
    while (end > 0 and (title[end] & 0xC0) == 0x80) end -= 1;
    return title[0..end];
}

fn runtimeMetaValue(id_hex: []const u8, entry: *reg.RuntimeEntry) RuntimeMetaWire {
    return .{
        .runtime_id = id_hex,
        .cols = entry.cols,
        .rows = entry.rows,
        .resize_generation = entry.resize_generation,
        .has_controller = entry.controller != null,
        .observer_count = entry.observers.items.len,
    };
}

/// 목록 한 줄을 만든다. **빈 title 은 없는 것과 같다** — `"title":""` 은 "제목이 빈 세션" 이라는
/// 다른 말이고 소비자가 그것을 값으로 읽는다.
fn runtimeListEntryValue(id_hex: []const u8, entry: *reg.RuntimeEntry, title: ?[]const u8) RuntimeListEntry {
    const plain = runtimeMetaValue(id_hex, entry);
    const text = title orelse return .{ .plain = plain };
    const clamped = clampTitle(text);
    if (clamped.len == 0) return .{ .plain = plain };
    return .{ .titled = .{
        .runtime_id = plain.runtime_id,
        .cols = plain.cols,
        .rows = plain.rows,
        .resize_generation = plain.resize_generation,
        .has_controller = plain.has_controller,
        .observer_count = plain.observer_count,
        .title = clamped,
    } };
}

fn intField(obj: std.json.ObjectMap, key: []const u8) ?u16 {
    return switch (obj.get(key) orelse return null) {
        .integer => |n| if (n >= 0 and n <= std.math.maxInt(u16)) @intCast(n) else null,
        else => null,
    };
}

/// stream_id·client_sequence wire field. JSON integers are signed i64, which is also the
/// canonical counter ceiling shared with resize response/event encoding.
fn intFieldU64(obj: std.json.ObjectMap, key: []const u8) ?u64 {
    return switch (obj.get(key) orelse return null) {
        .integer => |n| if (n >= 0) @intCast(n) else null,
        else => null,
    };
}

/// bool 필드(§6b block 선택). 없거나 타입 다르면 false.
fn boolField(obj: std.json.ObjectMap, key: []const u8) bool {
    return switch (obj.get(key) orelse return false) {
        .bool => |b| b,
        else => false,
    };
}

fn exactBoolField(obj: std.json.ObjectMap, key: []const u8) ?bool {
    return switch (obj.get(key) orelse return null) {
        .bool => |b| b,
        else => null,
    };
}

fn decodeInitialNotification(value: ?std.json.Value) ?NotificationConfigSnapshot {
    const object = switch (value orelse return null) {
        .object => |object| object,
        else => return null,
    };
    if (object.count() != 3) return null;
    const config_generation = intFieldU64(object, "config_generation") orelse return null;
    if (config_generation == 0) return null;
    return .{
        .config_generation = config_generation,
        .notifications_osc = exactBoolField(object, "notifications_osc") orelse return null,
        .display_label = strField(object, "display_label") orelse return null,
    };
}

/// Additive bool은 부재만 legacy false로 허용하고, 존재하는데 bool이 아니면 schema 위반으로 거부한다.
fn optionalBoolField(obj: std.json.ObjectMap, key: []const u8) ?bool {
    return switch (obj.get(key) orelse return false) {
        .bool => |b| b,
        else => null,
    };
}

fn parseAttachMode(s: ?[]const u8) ?reg.AttachMode {
    const v = s orelse return .observer;
    if (std.mem.eql(u8, v, "observer")) return .observer;
    if (std.mem.eql(u8, v, "controller")) return .controller;
    // P5b3 deliberately removes the unsafe bootstrap takeover path. A client first completes an
    // observer attach, then promotes that exact existing stream through controller.takeover.
    return null;
}

fn strField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (obj.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn stringArrayContains(obj: std.json.ObjectMap, key: []const u8, needle: []const u8) bool {
    const array = switch (obj.get(key) orelse return false) {
        .array => |items| items,
        else => return false,
    };
    for (array.items) |value| switch (value) {
        .string => |s| if (std.mem.eql(u8, s, needle)) return true,
        else => {},
    };
    return false;
}

fn stringArrayFieldValid(obj: std.json.ObjectMap, key: []const u8) bool {
    const array = switch (obj.get(key) orelse return true) {
        .array => |items| items,
        else => return false,
    };
    for (array.items) |value| switch (value) {
        .string => {},
        else => return false,
    };
    return true;
}

const SpawnFieldError = error{InvalidSpawnField};

fn spawnOptionalStringField(obj: std.json.ObjectMap, key: []const u8) SpawnFieldError!?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .null => null,
        .string => |s| s,
        else => error.InvalidSpawnField,
    };
}

fn spawnStringField(obj: std.json.ObjectMap, key: []const u8, default: []const u8) SpawnFieldError![]const u8 {
    const value = obj.get(key) orelse return default;
    return switch (value) {
        .string => |s| s,
        else => error.InvalidSpawnField,
    };
}

fn spawnBoolField(obj: std.json.ObjectMap, key: []const u8, default: bool) SpawnFieldError!bool {
    const value = obj.get(key) orelse return default;
    return switch (value) {
        .bool => |b| b,
        else => error.InvalidSpawnField,
    };
}

fn spawnSizeField(obj: std.json.ObjectMap, key: []const u8, default: u16) SpawnFieldError!u16 {
    const value = obj.get(key) orelse return default;
    return switch (value) {
        .integer => |n| if (n > 0 and n <= std.math.maxInt(u16)) @intCast(n) else error.InvalidSpawnField,
        else => error.InvalidSpawnField,
    };
}

fn paneIdField(obj: std.json.ObjectMap) error{InvalidPaneId}!?u64 {
    const value = obj.get("pane_id") orelse return null;
    if (value == .null) return null;
    const text = switch (value) {
        .string => |s| s,
        else => return error.InvalidPaneId,
    };
    if (text.len != 16) return error.InvalidPaneId;
    const parsed = parseHex128(text) orelse return error.InvalidPaneId;
    if (parsed > std.math.maxInt(u64)) return error.InvalidPaneId;
    return @intCast(parsed);
}

const StringArrayError = error{ InvalidStringArray, OutOfMemory };

fn stringArrayFromValue(allocator: std.mem.Allocator, value: std.json.Array) StringArrayError![]const []const u8 {
    const strings = allocator.alloc([]const u8, value.items.len) catch return error.OutOfMemory;
    for (value.items, 0..) |item, i| {
        strings[i] = switch (item) {
            .string => |s| s,
            else => return error.InvalidStringArray,
        };
    }
    return strings;
}

fn stringArrayField(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8, allow_null: bool) StringArrayError![]const []const u8 {
    const value = obj.get(key) orelse return &.{};
    return switch (value) {
        .array => |items| stringArrayFromValue(allocator, items),
        .null => if (allow_null) &.{} else error.InvalidStringArray,
        else => error.InvalidStringArray,
    };
}

fn parseClientKind(s: ?[]const u8) ClientKind {
    const v = s orelse return .unknown;
    if (std.mem.eql(u8, v, "gui")) return .gui;
    if (std.mem.eql(u8, v, "cli")) return .cli;
    if (std.mem.eql(u8, v, "admin")) return .admin;
    return .unknown;
}

const RequestMethod = enum {
    host_info,
    host_upgrade_prepare,
    host_upgrade_status,
    runtime_list,
    runtime_inventory,
    runtime_get,
    runtime_spawn,
    runtime_spawn_full,
    runtime_terminate,
    runtime_attach,
    runtime_detach,
    controller_status,
    controller_takeover,
    controller_release,
    runtime_resync,
    runtime_catchup,
    runtime_observation,
    runtime_core_command,
    runtime_report_mouse,
    runtime_selected_text,
    runtime_clipboard_write,
    runtime_link_at,
    runtime_select_op,
    runtime_find,
    runtime_resize,
    runtime_notification,
    notification_config_update,

    fn wireName(self: RequestMethod) []const u8 {
        return switch (self) {
            .host_info => "host.info",
            .host_upgrade_prepare => "host.upgrade.prepare",
            .host_upgrade_status => "host.upgrade.status",
            .runtime_list => "runtime.list",
            .runtime_inventory => "runtime.inventory",
            .runtime_get => "runtime.get",
            .runtime_spawn => "runtime.spawn",
            .runtime_spawn_full => "runtime.spawn_full",
            .runtime_terminate => "runtime.terminate",
            .runtime_attach => "runtime.attach",
            .runtime_detach => "runtime.detach",
            .controller_status => "controller.status",
            .controller_takeover => "controller.takeover",
            .controller_release => "controller.release",
            .runtime_resync => "runtime.resync",
            .runtime_catchup => "runtime.catchup",
            .runtime_observation => "runtime.observation",
            .runtime_core_command => "runtime.core_command",
            .runtime_report_mouse => "runtime.report_mouse",
            .runtime_selected_text => "runtime.selected_text",
            .runtime_clipboard_write => "runtime.clipboard_write",
            .runtime_link_at => "runtime.link_at",
            .runtime_select_op => "runtime.select_op",
            .runtime_find => "runtime.find",
            .runtime_resize => "runtime.resize",
            .runtime_notification => "runtime.notification",
            .notification_config_update => "config.update",
        };
    }
};

fn parseRequestMethod(text: []const u8) ?RequestMethod {
    inline for (std.enums.values(RequestMethod)) |method|
        if (std.mem.eql(u8, text, method.wireName())) return method;
    return null;
}

const RequestPolicy = enum { admin_read, admin_mutation, privileged };

fn requestPolicy(method: RequestMethod) RequestPolicy {
    return switch (method) {
        .host_info, .runtime_list, .runtime_inventory, .runtime_get => .admin_read,
        .runtime_terminate => .admin_mutation,
        .host_upgrade_prepare,
        .host_upgrade_status,
        .runtime_spawn,
        .runtime_spawn_full,
        .runtime_attach,
        .runtime_detach,
        .controller_status,
        .controller_takeover,
        .controller_release,
        .runtime_resync,
        .runtime_catchup,
        .runtime_observation,
        .runtime_core_command,
        .runtime_report_mouse,
        .runtime_selected_text,
        .runtime_clipboard_write,
        .runtime_link_at,
        .runtime_select_op,
        .runtime_find,
        .runtime_resize,
        .runtime_notification,
        .notification_config_update,
        => .privileged,
    };
}

/// 32자 이하 lowercase hex → u128. 길이/문자가 어긋나면 null(invalid_request). runtime_id·host_id wire 파싱.
fn parseHex128(s: []const u8) ?u128 {
    if (s.len == 0 or s.len > 32) return null;
    var v: u128 = 0;
    for (s) |c| {
        const d: u128 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => return null,
        };
        v = v * 16 + d;
    }
    return v;
}

fn parseExactHex128(s: []const u8) ?u128 {
    if (s.len != 32) return null;
    for (s) |c| switch (c) {
        '0'...'9', 'a'...'f' => {},
        else => return null,
    };
    const value = parseHex128(s);
    return if (value == 0) null else value;
}

// ─────────────────────────────────────────────────────────────────────────────
// 단위 테스트
//
// 이 테스트가 증명하는 것(그리고 터미널에서 왜 중요한가): 재접속·`maru attach`는 이 dispatch가 hello를 올바로
// 협상하고 조회 command에 정확한 host_id/runtime metadata를 돌려줘야 시작된다. 첫 frame이 hello가 아니거나 version이
// 안 맞으면 runtime을 죽이지 않고 connection만 닫아야 하고(§10), unknown method는 typed error여야 한다. 순수 state
// machine이라 실 socket 없이 non-macOS에서 이 계약을 고정한다.
// ─────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

const FedResult = struct { action: []const u8, frame: ?framing.Frame };

/// 완성된 wire frame 하나를 handleFrame에 넣고 응답을 파싱해 돌려주는 공통 경로.
fn runWire(conn: *Connection, wire: []const u8) !FedResult {
    const allocator = testing.allocator;
    var parser = framing.FrameParser.init(allocator);
    defer parser.deinit();
    try parser.push(wire);
    const in = (try parser.next()).?;
    defer in.deinit(allocator);

    const action = try conn.handleFrame(in);
    switch (action) {
        .close => return .{ .action = "close", .frame = null },
        .none => return .{ .action = "none", .frame = null },
        .resync_ack => return .{ .action = "resync_ack", .frame = null },
        .reply, .reply_and_close => |bytes| {
            defer allocator.free(bytes);
            var rp = framing.FrameParser.init(allocator);
            defer rp.deinit();
            try rp.push(bytes);
            const out = (try rp.next()).?; // caller가 out.deinit
            return .{ .action = if (action == .reply) "reply" else "reply_and_close", .frame = out };
        },
        .upgrade_accepted => |accepted| {
            defer allocator.free(accepted.bytes);
            var rp = framing.FrameParser.init(allocator);
            defer rp.deinit();
            try rp.push(accepted.bytes);
            const out = (try rp.next()).?;
            return .{ .action = "upgrade_accepted", .frame = out };
        },
        .admin_terminate_accepted => |accepted| {
            defer allocator.free(accepted.bytes);
            var rp = framing.FrameParser.init(allocator);
            defer rp.deinit();
            try rp.push(accepted.bytes);
            const out = (try rp.next()).?;
            return .{ .action = "admin_terminate_accepted", .frame = out };
        },
        .frames => |list| {
            // 첫 frame(응답)만 파싱해 돌려주고 나머지(snapshot_chunk)는 이 helper에선 버린다. 전 frame 검사는 feedExpectFrames.
            defer {
                for (list) |f| allocator.free(f);
                allocator.free(list);
            }
            var rp = framing.FrameParser.init(allocator);
            defer rp.deinit();
            try rp.push(list[0]);
            const out = (try rp.next()).?;
            return .{ .action = "frames", .frame = out };
        },
        .controller_transition_requested => |transition_value| {
            var transition = transition_value;
            defer allocator.free(transition.success_reply);
            defer allocator.free(transition.stale_reply);
            defer allocator.free(transition.exhausted_reply);
            if (transition.revocation) |revocation|
                allocator.free(revocation.frame);
            defer conn.discardPreparedControllerTransition(
                &transition.prepared,
            );
            var rp = framing.FrameParser.init(allocator);
            defer rp.deinit();
            try rp.push(transition.success_reply);
            const out = (try rp.next()).?;
            return .{ .action = "controller_transition_requested", .frame = out };
        },
        .resize_requested => |resize_value| {
            var resize = resize_value;
            var response = resize.success_reply;
            const preview = resize.prepared.preview();
            const backend_ok = switch (preview) {
                .stale => unreachable,
                .applied => |applied| if (applied.changed) blk: {
                    const ops = conn.runtime_ops orelse break :blk false;
                    ops.resize(
                        ops.ctx,
                        resize.runtime_id,
                        applied.cols,
                        applied.rows,
                    ) catch break :blk false;
                    break :blk true;
                } else true,
            };
            if (backend_ok) {
                _ = try conn.registry.commitResizeSubscription(&resize.prepared);
                allocator.free(resize.internal_reply);
            } else {
                response = resize.internal_reply;
                allocator.free(resize.success_reply);
            }
            defer allocator.free(response);
            allocator.free(resize.exhausted_reply);
            if (resize.event_body) |body| allocator.free(body);
            var rp = framing.FrameParser.init(allocator);
            defer rp.deinit();
            try rp.push(response);
            const out = (try rp.next()).?;
            return .{ .action = "resize_requested", .frame = out };
        },
        .prepared_notification => |prepared| {
            defer allocator.free(prepared.reply);
            if (conn.runtime_ops) |ops|
                _ = ops.notification_commit(
                    ops.ctx,
                    prepared.runtime_id,
                    prepared.generation,
                );
            var rp = framing.FrameParser.init(allocator);
            defer rp.deinit();
            try rp.push(prepared.reply);
            const out = (try rp.next()).?;
            return .{ .action = "prepared_notification", .frame = out };
        },
        .catchup_arm_requested => |prepared| {
            defer allocator.free(prepared.reply);
            var rp = framing.FrameParser.init(allocator);
            defer rp.deinit();
            try rp.push(prepared.reply);
            const out = (try rp.next()).?;
            return .{ .action = "catchup_arm_requested", .frame = out };
        },
        .prepared_attach, .prepared_reply => unreachable,
    }
}

/// `.frames` action(attach 응답 + snapshot_chunk*)을 기대하고 각 frame을 파싱해 돌려준다(caller가 각 Frame.deinit + 슬라이스 free).
fn feedExpectFrames(conn: *Connection, kind: protocol.Kind, request_id: u64, json: []const u8) ![]framing.Frame {
    const allocator = testing.allocator;
    const wire = try framing.encodeFrame(allocator, .{ .kind = kind, .request_id = request_id }, json);
    defer allocator.free(wire);
    var parser = framing.FrameParser.init(allocator);
    defer parser.deinit();
    try parser.push(wire);
    const in = (try parser.next()).?;
    defer in.deinit(allocator);

    const action = try conn.handleFrame(in);
    if (action != .frames) return error.TestUnexpectedResult;
    const list = action.frames;
    defer {
        for (list) |f| allocator.free(f);
        allocator.free(list);
    }
    var out: std.ArrayListUnmanaged(framing.Frame) = .empty;
    errdefer {
        for (out.items) |f| f.deinit(allocator);
        out.deinit(allocator);
    }
    for (list) |fbytes| {
        var rp = framing.FrameParser.init(allocator);
        defer rp.deinit();
        try rp.push(fbytes);
        const f = (try rp.next()).?;
        try out.append(allocator, f);
    }
    return out.toOwnedSlice(allocator);
}

/// 테스트 helper: JSON payload로 request/response frame(request_id 헤더)을 만들어 넣는다.
fn feedJson(conn: *Connection, kind: protocol.Kind, request_id: u64, json: []const u8) !FedResult {
    const allocator = testing.allocator;
    const wire = try framing.encodeFrame(allocator, .{ .kind = kind, .request_id = request_id }, json);
    defer allocator.free(wire);
    return runWire(conn, wire);
}

/// 테스트 helper: stream frame(input_bytes 등, stream_id 헤더)을 만들어 넣는다. request_id가 아니라 stream_id로 라우팅.
fn feedStream(conn: *Connection, kind: protocol.Kind, stream_id: u64, payload: []const u8) !FedResult {
    const allocator = testing.allocator;
    const wire = try framing.encodeFrame(allocator, .{ .kind = kind, .stream_id = stream_id }, payload);
    defer allocator.free(wire);
    return runWire(conn, wire);
}

test "server: first non-hello frame closes the connection" {
    var registry = reg.TerminalRuntimeRegistry.init(testing.allocator);
    defer registry.deinit();
    var conn = Connection.init(testing.allocator, 0xABCD, &registry);
    const r = try feedJson(&conn, .request, 1, "{\"method\":\"host.info\"}");
    try testing.expectEqualStrings("close", r.action);
    try testing.expectEqual(Connection.State.closed, conn.state);
}

test "server: hello with overlapping version acks host_id and moves to ready" {
    var registry = reg.TerminalRuntimeRegistry.init(testing.allocator);
    defer registry.deinit();
    var conn = Connection.init(testing.allocator, 0x1234567890ABCDEF, &registry);
    const r = try feedJson(&conn, .hello, 7, "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"gui\"}");
    defer if (r.frame) |f| f.deinit(testing.allocator);
    try testing.expectEqualStrings("reply", r.action);
    try testing.expectEqual(protocol.Kind.hello_ack, r.frame.?.header.kind);
    try testing.expectEqual(@as(u64, 7), r.frame.?.header.request_id);
    try testing.expectEqual(Connection.State.ready, conn.state);
    try testing.expectEqual(ClientKind.gui, conn.client_kind);
    // host_id hex가 응답에 담긴다.
    try testing.expect(std.mem.indexOf(u8, r.frame.?.payload, "1234567890abcdef") != null);
    try testing.expect(std.mem.indexOf(u8, r.frame.?.payload, "\"screen_viewport_scrolled_v1\"") != null);
    try testing.expect(std.mem.indexOf(u8, r.frame.?.payload, "\"async_scroll_to_bottom_v1\"") != null);
    try testing.expect(std.mem.indexOf(u8, r.frame.?.payload, "\"runtime_core_command_v1\"") != null);
    try testing.expect(std.mem.indexOf(u8, r.frame.?.payload, "\"runtime_clear_screen_v1\"") != null);
    try testing.expect(std.mem.indexOf(u8, r.frame.?.payload, "\"runtime_selected_text_v1\"") != null);
    try testing.expect(std.mem.indexOf(u8, r.frame.?.payload, "\"runtime_selection_state_v1\"") != null);
}

test "CR4a host capability는 typed hello와 pending prepare만 허용한다" {
    const allocator = testing.allocator;
    const prepare = struct {
        fn one(
            conn: *Connection,
            now_ns: u64,
            request_id: u64,
            nonce: []const u8,
        ) !Action.PreparedCatchupArm {
            const test_allocator = testing.allocator;
            const body = try std.fmt.allocPrint(
                test_allocator,
                "{{\"method\":\"runtime.catchup\",\"params\":{{\"stream_id\":1,\"request_nonce\":\"{s}\"}}}}",
                .{nonce},
            );
            defer test_allocator.free(body);
            const wire = try framing.encodeFrame(
                test_allocator,
                .{ .kind = .request, .request_id = request_id },
                body,
            );
            defer test_allocator.free(wire);
            var parser = framing.FrameParser.init(test_allocator);
            defer parser.deinit();
            try parser.push(wire);
            const frame = (try parser.next()).?;
            defer frame.deinit(test_allocator);
            const action = try conn.handleFrameAt(frame, now_ns);
            if (action != .catchup_arm_requested) return error.TestUnexpectedResult;
            return action.catchup_arm_requested;
        }
    }.one;

    var registry = reg.TerminalRuntimeRegistry.init(testing.allocator);
    defer registry.deinit();
    _ = try registry.register(0xAA, 80, 24);
    var subscriptions = subscription_identity.Table.init(testing.allocator);
    defer subscriptions.deinit();
    var fake: FakeRuntimeOps = .{};
    var conn = Connection.initProduct(
        testing.allocator,
        0x1234,
        &registry,
        .{ .monotonic_id = 1, .slot_generation = 1 },
        &subscriptions,
    );
    defer conn.deinit();
    conn.runtime_ops = fake.ops();

    const hello = try feedJson(
        &conn,
        .hello,
        1,
        "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"gui\",\"capabilities\":[\"runtime_catchup_barrier_v1\"]}",
    );
    defer if (hello.frame) |frame| frame.deinit(testing.allocator);
    try testing.expect(conn.runtime_catchup_barrier_v1);
    try testing.expect(std.mem.indexOf(
        u8,
        hello.frame.?.payload,
        catchup_barrier_contract.capability,
    ) != null);
    const attach = try feedExpectFrames(
        &conn,
        .request,
        2,
        "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"observer\"}}",
    );
    defer {
        for (attach) |frame| frame.deinit(allocator);
        allocator.free(attach);
    }
    try testing.expect(conn.attachments.get(1).?.catchup == .idle);

    const nonce = "00112233445566778899aabbccddeeff";
    const rejected = try prepare(&conn, 100, 3, nonce);
    defer allocator.free(rejected.reply);
    try testing.expectEqual(catchup_barrier_contract.HostState.ArmResult.armed, rejected.result);
    try testing.expect(conn.attachments.get(1).?.catchup == .idle);

    const second = try prepare(&conn, 100, 4, nonce);
    defer allocator.free(second.reply);
    try testing.expectEqual(catchup_barrier_contract.HostState.ArmResult.armed, second.result);
    try testing.expect(conn.attachments.get(1).?.catchup == .idle);

    var malformed = Connection.initProduct(
        testing.allocator,
        0x1234,
        &registry,
        .{ .monotonic_id = 2, .slot_generation = 1 },
        &subscriptions,
    );
    defer malformed.deinit();
    const malformed_hello = try feedJson(
        &malformed,
        .hello,
        8,
        "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"gui\",\"capabilities\":[{},\"runtime_catchup_barrier_v1\"]}",
    );
    defer if (malformed_hello.frame) |frame| frame.deinit(testing.allocator);
    try testing.expectEqualStrings("close", malformed_hello.action);
    try testing.expect(!malformed.runtime_catchup_barrier_v1);
    try testing.expectEqual(@as(usize, 0), malformed.attachments.count());
}

// code-review(max) 회귀: preflight(전체 정지 판정)가 **완료된 attempt의 멱등 replay**까지 가로막아, 결과를
// 다시 조회하면 완료 보고 대신 upgrade_busy가 돌아왔다. 클라이언트는 이미 성공한 업그레이드를 다시 몰아붙일 수
// 있다. 새 시도는 종전대로 preflight가 먼저여야 하므로(all-or-none 규율) 둘을 함께 고정한다.
test "server: 완료된 attempt replay는 preflight를 거치지 않는다" {
    const FakeOwner = struct {
        staged: usize = 0,
        reservations: usize = 0,

        fn stagePending(ctx: *anyopaque, _: upgrade_wire.PrepareRequest) upgrade_wire.PrepareDecision {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.staged += 1;
            return .accepted;
        }
        fn probePrepare(_: *anyopaque, request: upgrade_wire.PrepareRequest) upgrade_wire.PrepareProbe {
            if (request.attempt_id != 0xAABB) return .requires_preflight;
            const exact = std.mem.eql(u8, request.target_path, "/Applications/Maru.app/Contents/MacOS/maru") and
                std.mem.eql(u8, request.target_build_id, "sha256:build") and
                std.mem.eql(u8, &request.target_sha256, &([_]u8{
                    0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF,
                } ** 4)) and
                request.handoff_reader_min == 1 and request.handoff_reader_max == 1;
            return if (exact)
                .{ .completed = .{ .status = .committed, .reason = .none } }
            else
                .conflict;
        }
        fn status(_: *anyopaque, _: u128) ?upgrade_wire.AttemptReport {
            return .{ .status = .committed, .reason = .none }; // 이미 끝난 attempt
        }
        fn armAccepted(_: *anyopaque, _: u128) upgrade_wire.ArmDecision {
            return .armed;
        }
        fn cancelUnaccepted(_: *anyopaque, _: u128) void {}
        fn reserve(ctx: *anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.reservations += 1;
            return false; // 전체 정지가 아니다 — 예전엔 이 한 표로 replay까지 막혔다
        }
        fn cancelReserve(_: *anyopaque) void {}
    };

    var registry = reg.TerminalRuntimeRegistry.init(testing.allocator);
    defer registry.deinit();
    var owner: FakeOwner = .{};
    var conn = Connection.init(testing.allocator, 0x1234, &registry);
    conn.state = .ready;
    conn.selected_version = protocol.version_major;
    conn.host_status = .{ .manifest_capable = true, .upgrade_capable = true };
    conn.upgrade_ops = .{
        .ctx = &owner,
        .probe_prepare = FakeOwner.probePrepare,
        .stage_pending = FakeOwner.stagePending,
        .cancel_unaccepted = FakeOwner.cancelUnaccepted,
        .arm_accepted = FakeOwner.armAccepted,
        .abort_armed = upgrade_wire.cannotAbortArmed,
        .status = FakeOwner.status,
    };
    conn.upgrade_preflight = .{
        .ctx = &owner,
        .reserve = FakeOwner.reserve,
        .cancel = FakeOwner.cancelReserve,
    };

    const request =
        \\{"method":"host.upgrade.prepare","params":{"attempt_id":"0000000000000000000000000000aabb","target_path":"/Applications/Maru.app/Contents/MacOS/maru","target_build_id":"sha256:build","target_sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","handoff_reader_min":1,"handoff_reader_max":1}}
    ;
    const replay = try feedJson(&conn, .request, 7, request);
    defer if (replay.frame) |frame| frame.deinit(testing.allocator);

    // 완료 보고가 돌아오고, preflight도 스테이징도 건드리지 않는다.
    const payload = replay.frame.?.payload;
    try testing.expect(std.mem.indexOf(u8, payload, "\"replayed\":true") != null);
    try testing.expect(std.mem.indexOf(u8, payload, "\"state\":\"committed\"") != null);
    try testing.expect(std.mem.indexOf(u8, payload, "upgrade_busy") == null);
    try testing.expectEqual(@as(usize, 0), owner.reservations);
    try testing.expectEqual(@as(usize, 0), owner.staged);

    const conflicts = [_][]const u8{
        \\{"method":"host.upgrade.prepare","params":{"attempt_id":"0000000000000000000000000000aabb","target_path":"/other","target_build_id":"sha256:build","target_sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","handoff_reader_min":1,"handoff_reader_max":1}}
        ,
        \\{"method":"host.upgrade.prepare","params":{"attempt_id":"0000000000000000000000000000aabb","target_path":"/Applications/Maru.app/Contents/MacOS/maru","target_build_id":"sha256:other","target_sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","handoff_reader_min":1,"handoff_reader_max":1}}
        ,
        \\{"method":"host.upgrade.prepare","params":{"attempt_id":"0000000000000000000000000000aabb","target_path":"/Applications/Maru.app/Contents/MacOS/maru","target_build_id":"sha256:build","target_sha256":"1123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","handoff_reader_min":1,"handoff_reader_max":1}}
        ,
        \\{"method":"host.upgrade.prepare","params":{"attempt_id":"0000000000000000000000000000aabb","target_path":"/Applications/Maru.app/Contents/MacOS/maru","target_build_id":"sha256:build","target_sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","handoff_reader_min":1,"handoff_reader_max":2}}
        ,
    };
    for (conflicts, 0..) |conflict_request, index| {
        const conflict = try feedJson(&conn, .request, @intCast(20 + index), conflict_request);
        defer if (conflict.frame) |frame| frame.deinit(testing.allocator);
        try testing.expect(std.mem.indexOf(u8, conflict.frame.?.payload, "attempt_conflict") != null);
    }
    try testing.expectEqual(@as(usize, 0), owner.reservations);
    try testing.expectEqual(@as(usize, 0), owner.staged);

    conn.host_status.upgrade_capable = false;
    const revoked_replay = try feedJson(&conn, .request, 30, request);
    defer if (revoked_replay.frame) |frame| frame.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, revoked_replay.frame.?.payload, "\"replayed\":true") != null);
    const new_request =
        \\{"method":"host.upgrade.prepare","params":{"attempt_id":"0000000000000000000000000000aabc","target_path":"/Applications/Maru.app/Contents/MacOS/maru","target_build_id":"sha256:build","target_sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","handoff_reader_min":1,"handoff_reader_max":1}}
    ;
    const unsupported = try feedJson(&conn, .request, 31, new_request);
    defer if (unsupported.frame) |frame| frame.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, unsupported.frame.?.payload, "upgrade_unsupported") != null);
}

test "server: upgrade prepare publishes pending then replies-and-closes before daemon work" {
    const FakeOwner = struct {
        accepted: bool = false,
        reject: bool = false,
        attempt_id: u128 = 0,
        reservations: usize = 0,
        reservation_cancels: usize = 0,
        stage_without_reservation: bool = false,

        fn stagePending(ctx: *anyopaque, request: upgrade_wire.PrepareRequest) upgrade_wire.PrepareDecision {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.reservations == self.reservation_cancels)
                self.stage_without_reservation = true;
            if (self.reject) return .busy;
            if (self.accepted and self.attempt_id != request.attempt_id) return .conflict;
            self.accepted = true;
            self.attempt_id = request.attempt_id;
            return .accepted;
        }

        fn status(ctx: *anyopaque, attempt_id: u128) ?upgrade_wire.AttemptReport {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (!self.accepted or self.attempt_id != attempt_id) return null;
            return .{ .status = .pending };
        }

        fn armAccepted(ctx: *anyopaque, attempt_id: u128) upgrade_wire.ArmDecision {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (!self.accepted) return .not_pending;
            if (self.attempt_id != attempt_id) return .conflict;
            return .armed;
        }

        fn cancelUnaccepted(_: *anyopaque, _: u128) void {}

        fn reserve(ctx: *anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.reservations += 1;
            return true;
        }

        fn cancelReservation(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.reservation_cancels += 1;
        }
    };

    var registry = reg.TerminalRuntimeRegistry.init(testing.allocator);
    defer registry.deinit();
    var owner: FakeOwner = .{};
    var conn = Connection.init(testing.allocator, 0x1234, &registry);
    conn.state = .ready;
    conn.selected_version = protocol.version_major;
    conn.host_status = .{ .manifest_capable = true, .upgrade_capable = true };
    conn.upgrade_ops = .{
        .ctx = &owner,
        .probe_prepare = upgrade_wire.requiresPreflight,
        .stage_pending = FakeOwner.stagePending,
        .cancel_unaccepted = FakeOwner.cancelUnaccepted,
        .arm_accepted = FakeOwner.armAccepted,
        .abort_armed = upgrade_wire.cannotAbortArmed,
        .status = FakeOwner.status,
    };
    const request =
        \\{"method":"host.upgrade.prepare","params":{"attempt_id":"0000000000000000000000000000aabb","target_path":"/Applications/Maru.app/Contents/MacOS/maru","target_build_id":"sha256:build","target_sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","handoff_reader_min":1,"handoff_reader_max":1}}
    ;
    const missing_preflight = try feedJson(&conn, .request, 7, request);
    defer if (missing_preflight.frame) |frame| frame.deinit(testing.allocator);
    try testing.expect(!owner.accepted);
    try testing.expect(std.mem.indexOf(
        u8,
        missing_preflight.frame.?.payload,
        "\"error\":\"upgrade_busy\"",
    ) != null);

    conn.upgrade_preflight = .{
        .ctx = &owner,
        .reserve = FakeOwner.reserve,
        .cancel = FakeOwner.cancelReservation,
    };
    var live_status: HostStatus = .{ .manifest_capable = true, .upgrade_capable = false };
    conn.live_host_status = &live_status;
    const revoked = try feedJson(&conn, .request, 8, request);
    defer if (revoked.frame) |frame| frame.deinit(testing.allocator);
    try testing.expect(!owner.accepted);
    try testing.expect(std.mem.indexOf(
        u8,
        revoked.frame.?.payload,
        "\"error\":\"upgrade_unsupported\"",
    ) != null);
    live_status.upgrade_capable = true;
    owner.reject = true;
    const stage_busy = try feedJson(&conn, .request, 9, request);
    defer if (stage_busy.frame) |frame| frame.deinit(testing.allocator);
    try testing.expect(!owner.accepted);
    try testing.expectEqual(@as(usize, 1), owner.reservations);
    try testing.expectEqual(@as(usize, 1), owner.reservation_cancels);
    try testing.expect(!owner.stage_without_reservation);
    owner.reject = false;
    const result = try feedJson(&conn, .request, 10, request);
    defer if (result.frame) |frame| frame.deinit(testing.allocator);
    try testing.expect(owner.accepted);
    try testing.expectEqual(@as(usize, 2), owner.reservations);
    try testing.expectEqual(@as(usize, 1), owner.reservation_cancels);
    try testing.expect(!owner.stage_without_reservation);
    try testing.expectEqual(@as(u128, 0xAABB), owner.attempt_id);
    try testing.expectEqualStrings("upgrade_accepted", result.action);
    try testing.expect(std.mem.indexOf(u8, result.frame.?.payload, "\"state\":\"accepted\"") != null);
    try testing.expect(std.mem.indexOf(u8, result.frame.?.payload, "\"attempt_id\":\"0000000000000000000000000000aabb\"") != null);
    try testing.expectEqual(Connection.State.closed, conn.state);
}

test "server: wrong header major closes before hello negotiation" {
    var registry = reg.TerminalRuntimeRegistry.init(testing.allocator);
    defer registry.deinit();
    var conn = Connection.init(testing.allocator, 1, &registry);
    const frame = framing.Frame{
        .header = .{ .major = protocol.version_major - 1, .kind = .hello, .request_id = 1 },
        .payload = try testing.allocator.dupe(u8, "{\"protocol_min\":2,\"protocol_max\":2}"),
    };
    defer frame.deinit(testing.allocator);
    const action = try conn.handleFrame(frame);
    try testing.expect(action == .close);
    try testing.expectEqual(Connection.State.closed, conn.state);
}

test "server: hello with no overlapping version returns incompatible_version and closes" {
    var registry = reg.TerminalRuntimeRegistry.init(testing.allocator);
    defer registry.deinit();
    var conn = Connection.init(testing.allocator, 1, &registry);
    const r = try feedJson(&conn, .hello, 1, "{\"protocol_min\":4,\"protocol_max\":4,\"client_kind\":\"cli\"}"); // host major(2) 밖 → 거부.
    defer if (r.frame) |f| f.deinit(testing.allocator);
    try testing.expectEqualStrings("reply_and_close", r.action);
    try testing.expect(std.mem.indexOf(u8, r.frame.?.payload, "incompatible_version") != null);
    try testing.expectEqual(Connection.State.closed, conn.state);
}

test "server: host.info and runtime.list/get dispatch registry state after hello" {
    var registry = reg.TerminalRuntimeRegistry.init(testing.allocator);
    defer registry.deinit();
    _ = try registry.register(0xAA, 80, 24);
    _ = try registry.register(0xBB, 132, 43);
    var conn = Connection.init(testing.allocator, 0xF00D, &registry);

    // hello 먼저.
    {
        const r = try feedJson(&conn, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2}");
        defer if (r.frame) |f| f.deinit(testing.allocator);
    }
    // host.info → runtime_count 2.
    {
        const r = try feedJson(&conn, .request, 2, "{\"method\":\"host.info\"}");
        defer if (r.frame) |f| f.deinit(testing.allocator);
        try testing.expectEqual(protocol.Kind.response, r.frame.?.header.kind);
        try testing.expect(std.mem.indexOf(u8, r.frame.?.payload, "\"runtime_count\":2") != null);
    }
    // runtime.list → 두 runtime의 hex id가 담긴다.
    {
        const r = try feedJson(&conn, .request, 3, "{\"method\":\"runtime.list\"}");
        defer if (r.frame) |f| f.deinit(testing.allocator);
        try testing.expect(std.mem.indexOf(u8, r.frame.?.payload, "runtimes") != null);
    }
    // runtime.get 존재.
    {
        const r = try feedJson(&conn, .request, 4, "{\"method\":\"runtime.get\",\"params\":{\"runtime_id\":\"aa\"}}");
        defer if (r.frame) |f| f.deinit(testing.allocator);
        try testing.expect(std.mem.indexOf(u8, r.frame.?.payload, "\"cols\":80") != null);
    }
    // runtime.get 부재 → runtime_not_found.
    {
        const r = try feedJson(&conn, .request, 5, "{\"method\":\"runtime.get\",\"params\":{\"runtime_id\":\"ff\"}}");
        defer if (r.frame) |f| f.deinit(testing.allocator);
        try testing.expect(std.mem.indexOf(u8, r.frame.?.payload, "runtime_not_found") != null);
    }
}

test "server: runtime.inventory pages canonical IDs under one exact authority" {
    var registry = reg.TerminalRuntimeRegistry.initWithLimits(testing.allocator, .{
        .max_live_runtimes = 257,
        .max_aggregate_grid_cells = 257 * 80 * 24,
    });
    defer registry.deinit();
    var runtime_id: u128 = 1;
    while (runtime_id <= 257) : (runtime_id += 1)
        _ = try registry.register(runtime_id, 80, 24);
    var status: HostStatus = .{
        .manifest_capable = true,
        .upgrade_epoch = 7,
        .authority_generation = 9,
        .lifecycle = .ready,
    };
    var conn = Connection.init(testing.allocator, 0xF00D, &registry);
    conn.state = .ready;
    conn.live_host_status = &status;

    const first = try feedJson(
        &conn,
        .request,
        1,
        "{\"method\":\"runtime.inventory\",\"params\":{\"cursor\":\"\",\"limit\":256,\"membership_generation\":0}}",
    );
    defer if (first.frame) |frame| frame.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, first.frame.?.payload, "\"membership_generation\":258") != null);
    try testing.expect(std.mem.indexOf(u8, first.frame.?.payload, "\"upgrade_epoch\":7") != null);
    try testing.expect(std.mem.indexOf(u8, first.frame.?.payload, "\"authority_generation\":9") != null);
    try testing.expect(std.mem.indexOf(u8, first.frame.?.payload, "\"total\":257") != null);
    try testing.expect(std.mem.indexOf(u8, first.frame.?.payload, "\"runtime_ids\":[\"00000000000000000000000000000001\",\"00000000000000000000000000000002\"") != null);
    try testing.expect(std.mem.indexOf(u8, first.frame.?.payload, "\"next_cursor\":\"00000000000000000000000000000100\"") != null);
    try testing.expect(std.mem.indexOf(u8, first.frame.?.payload, "\"done\":false") != null);

    const second = try feedJson(
        &conn,
        .request,
        2,
        "{\"method\":\"runtime.inventory\",\"params\":{\"cursor\":\"00000000000000000000000000000100\",\"limit\":256,\"membership_generation\":258}}",
    );
    defer if (second.frame) |frame| frame.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, second.frame.?.payload, "\"cursor\":\"00000000000000000000000000000100\"") != null);
    try testing.expect(std.mem.indexOf(u8, second.frame.?.payload, "\"runtime_ids\":[\"00000000000000000000000000000101\"]") != null);
    try testing.expect(std.mem.indexOf(u8, second.frame.?.payload, "\"next_cursor\":\"\"") != null);
    try testing.expect(std.mem.indexOf(u8, second.frame.?.payload, "\"done\":true") != null);

    status.authority_generation = 10;
    status.lifecycle = .restoring;
    const stopped = try feedJson(
        &conn,
        .request,
        3,
        "{\"method\":\"runtime.inventory\",\"params\":{\"cursor\":\"\",\"limit\":256,\"membership_generation\":0}}",
    );
    defer if (stopped.frame) |frame| frame.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, stopped.frame.?.payload, "host_shutting_down") != null);
}

test "server: runtime.inventory rejects malformed requests and stale membership" {
    var registry = reg.TerminalRuntimeRegistry.init(testing.allocator);
    defer registry.deinit();
    _ = try registry.register(1, 80, 24);
    var conn = Connection.init(testing.allocator, 1, &registry);
    conn.state = .ready;
    conn.host_status = .{ .manifest_capable = true };
    const invalid = [_][]const u8{
        "{\"method\":\"runtime.inventory\",\"params\":{\"cursor\":\"\",\"limit\":0,\"membership_generation\":0}}",
        "{\"method\":\"runtime.inventory\",\"params\":{\"cursor\":\"\",\"limit\":257,\"membership_generation\":0}}",
        "{\"method\":\"runtime.inventory\",\"params\":{\"cursor\":\"\",\"limit\":256,\"membership_generation\":2}}",
        "{\"method\":\"runtime.inventory\",\"params\":{\"cursor\":\"00000000000000000000000000000001\",\"limit\":256,\"membership_generation\":0}}",
        "{\"method\":\"runtime.inventory\",\"params\":{\"cursor\":\"0000000000000000000000000000000\",\"limit\":256,\"membership_generation\":2}}",
        "{\"method\":\"runtime.inventory\",\"params\":{\"cursor\":\"000000000000000000000000000000001\",\"limit\":256,\"membership_generation\":2}}",
        "{\"method\":\"runtime.inventory\",\"params\":{\"cursor\":\"0000000000000000000000000000000A\",\"limit\":256,\"membership_generation\":2}}",
        "{\"method\":\"runtime.inventory\",\"params\":{\"cursor\":\"0000000000000000000000000000000g\",\"limit\":256,\"membership_generation\":2}}",
        "{\"method\":\"runtime.inventory\",\"method\":\"runtime.inventory\",\"params\":{\"cursor\":\"\",\"limit\":256,\"membership_generation\":0}}",
        "{\"method\":\"runtime.inventory\",\"params\":{\"cursor\":\"\",\"cursor\":\"\",\"limit\":256,\"membership_generation\":0}}",
        "{\"method\":\"runtime.inventory\",\"params\":{\"cursor\":\"\",\"limit\":256,\"membership_generation\":0,\"extra\":1}}",
    };
    for (invalid, 0..) |request, index| {
        const result = try feedJson(&conn, .request, @intCast(index + 1), request);
        defer if (result.frame) |frame| frame.deinit(testing.allocator);
        try testing.expect(std.mem.indexOf(u8, result.frame.?.payload, "invalid_request") != null);
    }

    const stale = try feedJson(
        &conn,
        .request,
        20,
        "{\"method\":\"runtime.inventory\",\"params\":{\"cursor\":\"00000000000000000000000000000001\",\"limit\":256,\"membership_generation\":1}}",
    );
    defer if (stale.frame) |frame| frame.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, stale.frame.?.payload, "invalid_generation") != null);

    registry.membership_generation_exhausted = true;
    const exhausted = try feedJson(
        &conn,
        .request,
        21,
        "{\"method\":\"runtime.inventory\",\"params\":{\"cursor\":\"\",\"limit\":256,\"membership_generation\":0}}",
    );
    defer if (exhausted.frame) |frame| frame.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, exhausted.frame.?.payload, "resource_exhausted") != null);
}

test "server: runtime.inventory is neither advertised nor callable on a legacy host" {
    var registry = reg.TerminalRuntimeRegistry.init(testing.allocator);
    defer registry.deinit();
    var conn = Connection.init(testing.allocator, 1, &registry);
    const hello = try feedJson(&conn, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2}");
    defer if (hello.frame) |frame| frame.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, hello.frame.?.payload, "runtime_inventory_v1") == null);
    const result = try feedJson(
        &conn,
        .request,
        2,
        "{\"method\":\"runtime.inventory\",\"params\":{\"cursor\":\"\",\"limit\":256,\"membership_generation\":0}}",
    );
    defer if (result.frame) |frame| frame.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, result.frame.?.payload, "unauthorized") != null);
}

test "server: runtime.inventory accepts the workspace cap and rejects cap plus one without a prefix" {
    var registry = reg.TerminalRuntimeRegistry.initWithLimits(testing.allocator, .{
        .max_live_runtimes = protocol.max_inventory_runtimes + 1,
        .max_aggregate_grid_cells = (protocol.max_inventory_runtimes + 1) * 80 * 24,
    });
    defer registry.deinit();
    var id: u128 = 1;
    while (id <= protocol.max_inventory_runtimes) : (id += 1)
        _ = try registry.register(id, 80, 24);
    var conn = Connection.init(testing.allocator, 1, &registry);
    conn.state = .ready;
    conn.host_status = .{ .manifest_capable = true };
    const exact = try feedJson(
        &conn,
        .request,
        1,
        "{\"method\":\"runtime.inventory\",\"params\":{\"cursor\":\"\",\"limit\":256,\"membership_generation\":0}}",
    );
    defer if (exact.frame) |frame| frame.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, exact.frame.?.payload, "\"total\":4096") != null);
    try testing.expect(std.mem.indexOf(u8, exact.frame.?.payload, "\"done\":false") != null);

    _ = try registry.register(id, 80, 24);
    const oversized = try feedJson(
        &conn,
        .request,
        2,
        "{\"method\":\"runtime.inventory\",\"params\":{\"cursor\":\"\",\"limit\":256,\"membership_generation\":0}}",
    );
    defer if (oversized.frame) |frame| frame.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, oversized.frame.?.payload, "resource_exhausted") != null);
    try testing.expect(std.mem.indexOf(u8, oversized.frame.?.payload, "runtime_ids") == null);
}

test "server: inventory snapshot allocation failure is typed and preserves canonical RPC" {
    var registry = reg.TerminalRuntimeRegistry.init(testing.allocator);
    defer registry.deinit();
    _ = try registry.register(1, 80, 24);
    var conn = Connection.init(testing.allocator, 1, &registry);
    conn.state = .ready;
    conn.host_status = .{ .manifest_capable = true };
    conn.inventory_fail_snapshot_once = true;
    const inventory = try feedJson(
        &conn,
        .request,
        1,
        "{\"method\":\"runtime.inventory\",\"params\":{\"cursor\":\"\",\"limit\":256,\"membership_generation\":0}}",
    );
    defer if (inventory.frame) |frame| frame.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, inventory.frame.?.payload, "resource_exhausted") != null);
    const get = try feedJson(
        &conn,
        .request,
        2,
        "{\"method\":\"runtime.get\",\"params\":{\"runtime_id\":\"01\"}}",
    );
    defer if (get.frame) |frame| frame.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, get.frame.?.payload, "\"runtime_id\"") != null);
}

test "server: oversize result replies payload_too_large instead of dropping the connection" {
    const allocator = testing.allocator;
    var registry = reg.TerminalRuntimeRegistry.initWithLimits(allocator, .{
        .max_live_runtimes = 2600,
        .max_aggregate_grid_cells = 2600 * 80 * 24,
    });
    defer registry.deinit();
    // runtime.list JSON이 control cap(256 KiB)을 넘도록 충분히 많은 runtime을 등록한다(각 meta ~135B).
    var i: u128 = 1;
    while (i <= 2600) : (i += 1) {
        _ = try registry.register(i, 80, 24);
    }
    var conn = Connection.init(allocator, 0xF00D, &registry);
    {
        const h = try feedJson(&conn, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2,\"capabilities\":[\"runtime_metadata_v1\"]}");
        if (h.frame) |f| f.deinit(allocator);
    }
    // cap 초과 응답은 connection을 끊지 않고 payload_too_large typed error로 돌아오며 상관 request_id를 유지한다.
    const r = try feedJson(&conn, .request, 2, "{\"method\":\"runtime.list\"}");
    defer if (r.frame) |f| f.deinit(allocator);
    try testing.expectEqualStrings("reply", r.action);
    try testing.expectEqual(protocol.Kind.response, r.frame.?.header.kind);
    try testing.expectEqual(@as(u64, 2), r.frame.?.header.request_id);
    try testing.expect(std.mem.indexOf(u8, r.frame.?.payload, "payload_too_large") != null);
    try testing.expectEqual(Connection.State.ready, conn.state); // runtime·connection 유지
}

test "server: unknown method returns invalid_request; a request before hello closes" {
    var registry = reg.TerminalRuntimeRegistry.init(testing.allocator);
    defer registry.deinit();
    var conn = Connection.init(testing.allocator, 1, &registry);
    {
        const h = try feedJson(&conn, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2,\"capabilities\":[\"runtime_metadata_v1\"]}");
        if (h.frame) |f| f.deinit(testing.allocator);
    }
    const r = try feedJson(&conn, .request, 2, "{\"method\":\"no.such.method\"}");
    defer if (r.frame) |f| f.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, r.frame.?.payload, "invalid_request") != null);
}

test "server: admin lease is exact one and releases only on canonical deinit" {
    var registry = reg.TerminalRuntimeRegistry.init(testing.allocator);
    defer registry.deinit();
    var admission: AdminAdmission = .{};
    var first = Connection.init(testing.allocator, 0xAA, &registry);
    first.admin_admission = &admission;
    var first_live = true;
    defer if (first_live) first.deinit();

    const hello = try feedJson(
        &first,
        .hello,
        1,
        "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"admin\"}",
    );
    defer if (hello.frame) |f| f.deinit(testing.allocator);
    try testing.expectEqualStrings("reply", hello.action);
    try testing.expect(std.mem.indexOf(u8, hello.frame.?.payload, "admin_one_shot_v1") != null);
    try testing.expect(admission.active);

    var second = Connection.init(testing.allocator, 0xAA, &registry);
    second.admin_admission = &admission;
    defer second.deinit();
    const denied = try feedJson(
        &second,
        .hello,
        2,
        "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"admin\"}",
    );
    defer if (denied.frame) |f| f.deinit(testing.allocator);
    try testing.expectEqualStrings("reply_and_close", denied.action);
    try testing.expect(std.mem.indexOf(u8, denied.frame.?.payload, "resource_exhausted") != null);
    try testing.expect(admission.active);

    const info = try feedJson(&first, .request, 3, "{\"method\":\"host.info\",\"params\":{}}");
    defer if (info.frame) |f| f.deinit(testing.allocator);
    try testing.expectEqualStrings("reply_and_close", info.action);
    try testing.expect(admission.active);
    first.deinit();
    first_live = false;
    try testing.expect(!admission.active);

    var third = Connection.init(testing.allocator, 0xAA, &registry);
    third.admin_admission = &admission;
    var third_live = true;
    defer if (third_live) third.deinit();
    const reacquired = try feedJson(
        &third,
        .hello,
        4,
        "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"admin\"}",
    );
    defer if (reacquired.frame) |f| f.deinit(testing.allocator);
    try testing.expectEqualStrings("reply", reacquired.action);
    try testing.expect(admission.active);
    third.deinit();
    third_live = false;
    try testing.expect(!admission.active);
}

test "server: admin is one-shot read-only and rejects malformed or privileged requests" {
    var registry = reg.TerminalRuntimeRegistry.init(testing.allocator);
    defer registry.deinit();
    const cases = [_]struct {
        payload: []const u8,
        code: []const u8,
    }{
        .{ .payload = "{\"method\":\"runtime.terminate\",\"params\":{\"runtime_id\":\"1\"}}", .code = "unauthorized" },
        .{ .payload = "{\"method\":\"host.upgrade.prepare\",\"params\":{}}", .code = "unauthorized" },
        .{ .payload = "{\"method\":\"unknown.method\",\"params\":{}}", .code = "invalid_request" },
        .{ .payload = "{", .code = "invalid_request" },
    };
    for (cases, 0..) |case, index| {
        var admission: AdminAdmission = .{};
        var conn = Connection.init(testing.allocator, 0xAA, &registry);
        conn.admin_admission = &admission;
        defer conn.deinit();
        const admin_hello = try feedJson(
            &conn,
            .hello,
            @intCast(index * 2 + 1),
            "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"admin\"}",
        );
        defer if (admin_hello.frame) |f| f.deinit(testing.allocator);
        const response = try feedJson(&conn, .request, @intCast(index * 2 + 2), case.payload);
        defer if (response.frame) |f| f.deinit(testing.allocator);
        try testing.expectEqualStrings("reply_and_close", response.action);
        try testing.expect(std.mem.indexOf(u8, response.frame.?.payload, case.code) != null);
    }
}

test "server: every canonical request method has one exhaustive admin policy" {
    @setEvalBranchQuota(2000);
    var admin_reads: usize = 0;
    var admin_mutations: usize = 0;
    inline for (std.enums.values(RequestMethod), 0..) |method, index| {
        try testing.expectEqual(method, parseRequestMethod(method.wireName()).?);
        inline for (std.enums.values(RequestMethod)[0..index]) |prior|
            try testing.expect(!std.mem.eql(u8, method.wireName(), prior.wireName()));
        if (requestPolicy(method) == .admin_read) admin_reads += 1;
        if (requestPolicy(method) == .admin_mutation) admin_mutations += 1;
    }
    try testing.expectEqual(@as(usize, 4), admin_reads);
    try testing.expectEqual(@as(usize, 1), admin_mutations);
    try testing.expect(parseRequestMethod("runtime.future_method") == null);
}

test "server: admin runtime end requires exact membership and preallocates success before mutation" {
    var registry = reg.TerminalRuntimeRegistry.init(testing.allocator);
    defer registry.deinit();
    const target = try registry.register(0xAA, 80, 24);
    target.controller = 11;
    try target.observers.append(testing.allocator, 22);
    _ = try registry.register(0xBB, 100, 30);
    var fake: FakeRuntimeOps = .{};
    var admission: AdminAdmission = .{};

    var missing = Connection.init(testing.allocator, 1, &registry);
    missing.runtime_ops = fake.ops();
    missing.admin_admission = &admission;
    const missing_hello = try feedJson(
        &missing,
        .hello,
        1,
        "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"admin\"}",
    );
    defer if (missing_hello.frame) |frame| frame.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, missing_hello.frame.?.payload, "admin_runtime_end_v1") != null);
    const missing_reply = try feedJson(
        &missing,
        .request,
        2,
        "{\"method\":\"runtime.terminate\",\"params\":{\"runtime_id\":\"cc\"}}",
    );
    defer if (missing_reply.frame) |frame| frame.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, missing_reply.frame.?.payload, "runtime_not_found") != null);
    try testing.expectEqual(@as(u128, 0), fake.terminated_id);
    missing.deinit();

    var terminate = Connection.init(testing.allocator, 1, &registry);
    terminate.runtime_ops = fake.ops();
    terminate.admin_admission = &admission;
    defer terminate.deinit();
    const terminate_hello = try feedJson(
        &terminate,
        .hello,
        3,
        "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"admin\"}",
    );
    defer if (terminate_hello.frame) |frame| frame.deinit(testing.allocator);
    const terminated = try feedJson(
        &terminate,
        .request,
        4,
        "{\"method\":\"runtime.terminate\",\"params\":{\"runtime_id\":\"aa\"}}",
    );
    defer if (terminated.frame) |frame| frame.deinit(testing.allocator);
    try testing.expectEqualStrings("admin_terminate_accepted", terminated.action);
    try testing.expect(std.mem.indexOf(u8, terminated.frame.?.payload, "\"terminated\":true") != null);
    try testing.expectEqual(@as(u128, 0), fake.terminated_id);
    try testing.expect(registry.get(0xBB) != null);

    fake.terminated_id = 0;
    var params: std.json.ObjectMap = .empty;
    defer params.deinit(testing.allocator);
    try params.put(testing.allocator, "runtime_id", .{ .string = "aa" });
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var oom = Connection.init(failing.allocator(), 1, &registry);
    defer oom.deinit();
    oom.runtime_ops = fake.ops();
    oom.client_kind = .admin;
    try testing.expectError(error.OutOfMemory, oom.dispatchTerminate(5, params));
    try testing.expectEqual(@as(u128, 0), fake.terminated_id);

    // GUI의 명시적 tab close는 기존 best-effort 계약이다. reply allocation OOM이어도 runtime 종료는 취소하지 않는다.
    var gui_failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var gui_oom = Connection.init(gui_failing.allocator(), 1, &registry);
    defer gui_oom.deinit();
    gui_oom.runtime_ops = fake.ops();
    gui_oom.client_kind = .gui;
    try testing.expectError(error.OutOfMemory, gui_oom.dispatchTerminate(6, params));
    try testing.expectEqual(@as(u128, 0xAA), fake.terminated_id);
}

test "server: all four admin read methods share the canonical dispatcher" {
    var registry = reg.TerminalRuntimeRegistry.init(testing.allocator);
    defer registry.deinit();
    const cases = [_]struct {
        payload: []const u8,
        expected: []const u8,
    }{
        .{ .payload = "{\"method\":\"host.info\",\"params\":{}}", .expected = "host_id" },
        .{ .payload = "{\"method\":\"runtime.list\",\"params\":{}}", .expected = "runtimes" },
        .{
            .payload = "{\"method\":\"runtime.inventory\",\"params\":{\"cursor\":\"\",\"limit\":256,\"membership_generation\":0}}",
            .expected = "runtime_ids",
        },
        .{
            .payload = "{\"method\":\"runtime.get\",\"params\":{\"runtime_id\":\"00000000000000000000000000000001\"}}",
            .expected = "runtime_not_found",
        },
    };
    for (cases, 0..) |case, index| {
        var admission: AdminAdmission = .{};
        var conn = Connection.init(testing.allocator, 0xAA, &registry);
        conn.admin_admission = &admission;
        conn.host_status = .{ .manifest_capable = true };
        defer conn.deinit();
        const hello = try feedJson(
            &conn,
            .hello,
            @intCast(index * 2 + 1),
            "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"admin\"}",
        );
        defer if (hello.frame) |f| f.deinit(testing.allocator);
        const response = try feedJson(&conn, .request, @intCast(index * 2 + 2), case.payload);
        defer if (response.frame) |f| f.deinit(testing.allocator);
        try testing.expectEqualStrings("reply_and_close", response.action);
        try testing.expect(std.mem.indexOf(u8, response.frame.?.payload, case.expected) != null);
        try testing.expect(std.mem.indexOf(u8, response.frame.?.payload, "unauthorized") == null);
    }
}

test "server: ping echoes as pong after hello" {
    var registry = reg.TerminalRuntimeRegistry.init(testing.allocator);
    defer registry.deinit();
    var conn = Connection.init(testing.allocator, 1, &registry);
    {
        const h = try feedJson(&conn, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2}");
        if (h.frame) |f| f.deinit(testing.allocator);
    }
    const r = try feedJson(&conn, .ping, 9, "nonce-42");
    defer if (r.frame) |f| f.deinit(testing.allocator);
    try testing.expectEqual(protocol.Kind.pong, r.frame.?.header.kind);
    try testing.expectEqualStrings("nonce-42", r.frame.?.payload);
}

test "server: hex128 parse rejects malformed runtime ids" {
    try testing.expectEqual(@as(?u128, 0xabc), parseHex128("abc"));
    try testing.expectEqual(@as(?u128, null), parseHex128("")); // 빈 문자열
    try testing.expectEqual(@as(?u128, null), parseHex128("xyz")); // hex 아님
    try testing.expectEqual(@as(?u128, null), parseHex128("0" ** 33)); // 32자 초과
}

/// dispatch가 실 runtime 소유를 위임하는 계약(RuntimeOps)을 검증하는 fake. spawn/terminate에 더해 write_input/resize도
/// 기록해 input capability 라우팅과 resize 적용이 controller에게만 위임되는지 본다.
pub const FakeRuntimeOps = struct {
    const InvalidObservation = enum {
        none,
        process_name_too_long,
        process_count,
        aggregate_strings,
        encoded_escape_expansion,
        encoded_escape_fits,
        invalid_utf8,
        foreground_inconsistent,
        mouse_mode,
    };

    /// 벨·OSC 52가 core에 대기 중인 상황을 흉내낸다(실 pending 조회는 runtime_manager smoke).
    observation_urgent: bool = false,
    spawn_count: usize = 0,
    spawn_argv0: [64]u8 = undefined,
    spawn_argv0_len: usize = 0,
    spawn_cols: u16 = 0,
    spawn_cwd: [64]u8 = undefined,
    spawn_cwd_len: usize = 0,
    spawn_login: bool = false,
    spawn_env_count: usize = 0,
    spawn_parent_env_count: usize = 0,
    spawn_parent_env_present: bool = false,
    spawn_env_override_count: usize = 0,
    spawn_term: [32]u8 = undefined,
    spawn_term_len: usize = 0,
    spawn_zdotdir_seen: bool = false,
    spawn_ssh_bin_seen: bool = false,
    spawn_pane_id: ?u64 = null,
    spawn_initial_config: ?core_command_wire.Command.RuntimeConfig = null,
    terminated_id: u128 = 0,
    next_id: u128 = 0xCAFE,
    last_input: [64]u8 = undefined,
    last_input_len: usize = 0,
    input_runtime: u128 = 0,
    resized_cols: u16 = 0,
    resized_rows: u16 = 0,
    resized_runtime: u128 = 0,
    resize_fail_count: usize = 0,
    delta_base_seen: [64]u8 = undefined,
    delta_base_seen_len: usize = 0,
    delta_sequence_seen: u64 = 0,
    snapshot_sequence_seen: u64 = 0,
    last_core_command: ?core_command_wire.Command = null,
    core_command_runtime: u128 = 0,
    core_command_failure: bool = false,
    last_mouse_report: ?MouseReport = null,
    last_select_span: SelectSpan = .{ .sr = 0, .sc = 0, .er = 0, .ec = 0, .block = false },
    selected_text_runtime: u128 = 0,
    link_at_runtime: u128 = 0,
    last_link_row: u16 = 0,
    last_link_col: u16 = 0,
    last_link_scopes: u8 = 0,
    last_select_op: [16]u8 = undefined,
    last_select_op_len: usize = 0,
    last_select_op_row: u16 = 0,
    last_select_op_col: u16 = 0,
    last_select_separators_hex: [128]u8 = undefined,
    last_select_separators_hex_len: usize = 0,
    last_find_query_hex: [64]u8 = undefined,
    last_find_query_hex_len: usize = 0,
    last_find_cur: u32 = 0,
    last_find_scroll: bool = false,
    observation_version: u8 = 0,
    observation_invalid: InvalidObservation = .none,
    snapshot_len: ?usize = null,
    new_base_len: ?usize = null,
    delta_send_len: ?usize = null,
    delta_is_snapshot: bool = false,
    frontier_generation: u64 = 0,
    delta_calls: usize = 0,
    screen_change_token: ScreenChangeToken = .{ .incarnation = 1, .revision = 1 },
    screen_token_reads: usize = 0,
    delta_probe_ctx: ?*anyopaque = null,
    delta_probe: ?*const fn (*anyopaque) void = null,
    snapshot_fail_count: usize = 0,
    snapshot_permanent_failure: bool = false,
    snapshot_calls: usize = 0,
    observation_fail_count: usize = 0,
    observation_calls: usize = 0,
    cached_observation_len: usize = 0,
    cached_observation_token: u64 = 0,
    cached_observation_version: u8 = 0,
    cached_observation_epoch: ?u64 = null,
    cached_observation_valid: bool = false,
    notification_calls: usize = 0,
    notification_commit_calls: usize = 0,
    notification_config_calls: usize = 0,
    notification_config_generation: u64 = 0,
    notification_config_enabled: bool = false,
    notification_config_label: [256]u8 = undefined,
    notification_config_label_len: usize = 0,
    runtime_missing: bool = false,
    snapshot_missing: bool = false,
    delta_missing: bool = false,
    observation_missing: bool = false,

    fn spawnFn(ctx: *anyopaque, params: RuntimeSpawnParams) anyerror!u128 {
        const self: *FakeRuntimeOps = @ptrCast(@alignCast(ctx));
        self.spawn_count += 1;
        const a0 = params.argv[0];
        const n = @min(a0.len, self.spawn_argv0.len);
        @memcpy(self.spawn_argv0[0..n], a0[0..n]);
        self.spawn_argv0_len = n;
        self.spawn_cols = params.cols;
        if (params.cwd) |cwd| {
            const cwd_len = @min(cwd.len, self.spawn_cwd.len);
            @memcpy(self.spawn_cwd[0..cwd_len], cwd[0..cwd_len]);
            self.spawn_cwd_len = cwd_len;
        }
        self.spawn_login = params.login;
        self.spawn_env_count = params.env.len;
        self.spawn_parent_env_present = params.parent_env != null;
        self.spawn_parent_env_count = if (params.parent_env) |snapshot| snapshot.len else 0;
        self.spawn_env_override_count = params.env_overrides.len;
        const term_len = @min(params.term.len, self.spawn_term.len);
        @memcpy(self.spawn_term[0..term_len], params.term[0..term_len]);
        self.spawn_term_len = term_len;
        self.spawn_zdotdir_seen = params.shell_integration_dir != null;
        self.spawn_ssh_bin_seen = params.ssh_integration_bin != null;
        self.spawn_pane_id = params.pane_id;
        self.spawn_initial_config = params.initial_config;
        return self.next_id;
    }
    fn terminateFn(ctx: *anyopaque, id: u128) void {
        const self: *FakeRuntimeOps = @ptrCast(@alignCast(ctx));
        self.terminated_id = id;
    }
    fn notificationConfigUpdateFn(
        ctx: *anyopaque,
        runtime_id: u128,
        current_controller_generation: u64,
        snapshot: NotificationConfigSnapshot,
    ) anyerror!bool {
        const self: *FakeRuntimeOps = @ptrCast(@alignCast(ctx));
        if (self.runtime_missing or runtime_id != 0xaa) return error.RuntimeNotFound;
        self.notification_config_calls += 1;
        self.notification_config_generation = snapshot.config_generation;
        self.notification_config_enabled = snapshot.notifications_osc;
        self.notification_config_label_len = @min(snapshot.display_label.len, self.notification_config_label.len);
        @memcpy(self.notification_config_label[0..self.notification_config_label_len], snapshot.display_label[0..self.notification_config_label_len]);
        return current_controller_generation != 0;
    }
    fn writeInputFn(ctx: *anyopaque, runtime_id: u128, bytes: []const u8) anyerror!void {
        const self: *FakeRuntimeOps = @ptrCast(@alignCast(ctx));
        const n = @min(bytes.len, self.last_input.len);
        @memcpy(self.last_input[0..n], bytes[0..n]);
        self.last_input_len = n;
        self.input_runtime = runtime_id;
    }
    fn resizeFn(ctx: *anyopaque, runtime_id: u128, cols: u16, rows: u16) anyerror!void {
        const self: *FakeRuntimeOps = @ptrCast(@alignCast(ctx));
        if (self.resize_fail_count != 0) {
            self.resize_fail_count -= 1;
            return error.InjectedResizeFailure;
        }
        self.resized_cols = cols;
        self.resized_rows = rows;
        self.resized_runtime = runtime_id;
    }
    /// 고정 snapshot 바이트를 caller 소유로 돌려준다(server가 이걸 snapshot_chunk로 나눠 보낸다).
    fn snapshotFn(ctx: *anyopaque, runtime_id: u128, sequence: u64, allocator: std.mem.Allocator) anyerror!ProjectedSnapshot {
        const self: *FakeRuntimeOps = @ptrCast(@alignCast(ctx));
        _ = runtime_id;
        self.snapshot_sequence_seen = sequence;
        self.snapshot_calls += 1;
        if (self.runtime_missing or self.snapshot_missing) return error.RuntimeNotFound;
        if (self.snapshot_permanent_failure) return error.OutOfMemory;
        if (self.snapshot_fail_count != 0) {
            self.snapshot_fail_count -= 1;
            return error.TransientSnapshotUnavailable;
        }
        if (self.snapshot_len) |len| {
            const bytes = try allocator.alloc(u8, len);
            @memset(bytes, 'S');
            return .{ .bytes = bytes, .frontier = .{ .generation = self.frontier_generation, .sequence = sequence } };
        }
        return .{
            .bytes = try allocator.dupe(u8, "SNAPSHOT-BYTES"),
            .frontier = .{ .generation = self.frontier_generation, .sequence = sequence },
        };
    }
    /// 받은 base를 기록하고 고정 delta + 새 base를 돌려준다(둘 다 별개 owned 버퍼). delta 라우팅·base 갱신을 검증한다.
    fn deltaFn(ctx: *anyopaque, runtime_id: u128, base: []const u8, sequence: u64, allocator: std.mem.Allocator) anyerror!StreamUpdate {
        const self: *FakeRuntimeOps = @ptrCast(@alignCast(ctx));
        _ = runtime_id;
        self.delta_sequence_seen = sequence;
        self.delta_calls += 1;
        if (self.delta_probe) |probe| probe(self.delta_probe_ctx.?);
        if (self.runtime_missing or self.delta_missing) return error.RuntimeNotFound;
        const n = @min(base.len, self.delta_base_seen.len);
        @memcpy(self.delta_base_seen[0..n], base[0..n]);
        self.delta_base_seen_len = n;
        const send = if (self.delta_send_len) |len| blk: {
            const bytes = try allocator.alloc(u8, len);
            @memset(bytes, 'D');
            break :blk bytes;
        } else try allocator.dupe(u8, "DELTA-BYTES");
        errdefer allocator.free(send);
        const new_base = if (self.new_base_len) |len| blk: {
            const bytes = try allocator.alloc(u8, len);
            @memset(bytes, 'N');
            break :blk bytes;
        } else try allocator.dupe(u8, "NEW-BASE");
        return .{
            .send = send,
            .is_snapshot = self.delta_is_snapshot,
            .new_base = new_base,
            .frontier = .{
                .generation = self.frontier_generation,
                .sequence = if (send.len == 0) sequence - 1 else sequence,
            },
        };
    }
    fn screenChangeTokenFn(ctx: *anyopaque, runtime_id: u128) anyerror!ScreenChangeToken {
        const self: *FakeRuntimeOps = @ptrCast(@alignCast(ctx));
        if (self.runtime_missing or runtime_id != 0xaa) return error.RuntimeNotFound;
        self.screen_token_reads += 1;
        return self.screen_change_token;
    }
    /// 대기 알림 없음(빈 title/body)을 돌려준다 — 기본 fake. server dispatch 배선만 검증(실 core 파싱은 runtime_manager smoke).
    fn notificationPeekFn(
        ctx: *anyopaque,
        runtime_id: u128,
        stable_delivery: bool,
        allocator: std.mem.Allocator,
    ) anyerror!NotificationSnapshot {
        const self: *FakeRuntimeOps = @ptrCast(@alignCast(ctx));
        _ = runtime_id;
        self.notification_calls += 1;
        return .{
            .body = try allocator.dupe(u8, if (stable_delivery) "{\"event\":null}" else "{\"title\":\"\",\"body\":\"\"}"),
            .generation = null,
        };
    }
    fn notificationCommitFn(
        ctx: *anyopaque,
        runtime_id: u128,
        generation: ?u64,
    ) bool {
        const self: *FakeRuntimeOps = @ptrCast(@alignCast(ctx));
        _ = runtime_id;
        _ = generation;
        self.notification_commit_calls += 1;
        return true;
    }
    /// 검증을 마친 bounded core command와 runtime을 기록한다 — 실 core 적용은 runtime_manager smoke가 맡는다.
    fn coreCommandFn(ctx: *anyopaque, runtime_id: u128, command: core_command_wire.Command) anyerror!void {
        const self: *FakeRuntimeOps = @ptrCast(@alignCast(ctx));
        if (self.core_command_failure) return error.InjectedCoreCommandFailure;
        self.last_core_command = command;
        self.core_command_runtime = runtime_id;
    }
    fn reportMouseFn(ctx: *anyopaque, runtime_id: u128, report: MouseReport) anyerror!void {
        const self: *FakeRuntimeOps = @ptrCast(@alignCast(ctx));
        self.last_mouse_report = report;
        self.core_command_runtime = runtime_id;
    }
    /// 받은 선택 span(+runtime)을 기록하고 고정 텍스트를 준다 — server 라우팅·파싱 검증(실 extractSelection은 runtime_manager smoke).
    fn selectedTextFn(ctx: *anyopaque, runtime_id: u128, span: SelectSpan, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *FakeRuntimeOps = @ptrCast(@alignCast(ctx));
        self.last_select_span = span;
        self.selected_text_runtime = runtime_id;
        return allocator.dupe(u8, "{\"text\":\"PICKED\"}");
    }
    fn observationUrgentFn(ctx: *anyopaque, runtime_id: u128) bool {
        const self: *FakeRuntimeOps = @ptrCast(@alignCast(ctx));
        _ = runtime_id;
        return self.observation_urgent;
    }
    fn clipboardWriteFn(ctx: *anyopaque, runtime_id: u128, allocator: std.mem.Allocator) anyerror![]u8 {
        _ = ctx;
        _ = runtime_id;
        return allocator.dupe(u8, "{\"text\":\"COPIED\"}");
    }
    /// 받은 (row,col,scopes)를 기록하고 고정 링크를 준다 — server 라우팅·파싱 검증(실 추출은 runtime_manager가 담당).
    fn linkAtFn(ctx: *anyopaque, runtime_id: u128, row: u16, col: u16, scopes: u8, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *FakeRuntimeOps = @ptrCast(@alignCast(ctx));
        self.link_at_runtime = runtime_id;
        self.last_link_row = row;
        self.last_link_col = col;
        self.last_link_scopes = scopes;
        return allocator.dupe(u8, "{\"text\":\"https://example.com/x\",\"kind\":0}");
    }
    /// 받은 (op,row,col)을 기록하고 고정 span을 준다 — server 라우팅·파싱 검증(실 경계 계산은 runtime_manager smoke).
    fn selectOpFn(ctx: *anyopaque, runtime_id: u128, op: []const u8, row: u16, col: u16, separators_hex: []const u8, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *FakeRuntimeOps = @ptrCast(@alignCast(ctx));
        _ = runtime_id;
        const n = @min(op.len, self.last_select_op.len);
        @memcpy(self.last_select_op[0..n], op[0..n]);
        self.last_select_op_len = n;
        self.last_select_op_row = row;
        self.last_select_op_col = col;
        const separators_n = @min(separators_hex.len, self.last_select_separators_hex.len);
        @memcpy(self.last_select_separators_hex[0..separators_n], separators_hex[0..separators_n]);
        self.last_select_separators_hex_len = separators_n;
        return allocator.dupe(u8, "{\"sel\":true,\"sr\":0,\"sc\":1,\"er\":0,\"ec\":3,\"block\":false}");
    }
    /// 받은 검색어(hex)/cur/scroll을 기록하고 고정 결과(2 매치, cur span 1 + 비현재 span 1)를 준다 — server 라우팅·파싱 검증.
    fn findFn(ctx: *anyopaque, runtime_id: u128, query_hex: []const u8, cur_index: u32, scroll: bool, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *FakeRuntimeOps = @ptrCast(@alignCast(ctx));
        _ = runtime_id;
        const n = @min(query_hex.len, self.last_find_query_hex.len);
        @memcpy(self.last_find_query_hex[0..n], query_hex[0..n]);
        self.last_find_query_hex_len = n;
        self.last_find_cur = cur_index;
        self.last_find_scroll = scroll;
        return allocator.dupe(u8, "{\"count\":2,\"cur\":[0,0,0,2],\"spans\":[1,2,1,5]}");
    }
    fn observationFn(ctx: *anyopaque, runtime_id: u128, allocator: std.mem.Allocator) anyerror!RuntimeObservation {
        const self: *FakeRuntimeOps = @ptrCast(@alignCast(ctx));
        _ = runtime_id;
        self.observation_calls += 1;
        if (self.runtime_missing or self.observation_missing) return error.RuntimeNotFound;
        if (self.observation_fail_count != 0) {
            self.observation_fail_count -= 1;
            return error.TransientObservationUnavailable;
        }
        const cwd = if (self.observation_invalid == .aggregate_strings or
            self.observation_invalid == .encoded_escape_expansion or
            self.observation_invalid == .encoded_escape_fits)
        blk: {
            const len = switch (self.observation_invalid) {
                .aggregate_strings => protocol.max_control_json,
                .encoded_escape_expansion => protocol.max_control_json / 6 + 512,
                .encoded_escape_fits => protocol.max_control_json / 6 - 512,
                else => unreachable,
            };
            const value = try allocator.alloc(u8, len);
            @memset(value, 'x');
            if (self.observation_invalid == .encoded_escape_expansion or
                self.observation_invalid == .encoded_escape_fits)
                @memset(value, 0x01);
            break :blk value;
        } else try allocator.dupe(
            u8,
            if (self.observation_version == 0) "/tmp/project" else "/tmp/project-next",
        );
        errdefer allocator.free(cwd);
        const title = try allocator.dupe(u8, "project");
        errdefer allocator.free(title);
        const dest = try allocator.dupe(u8, "workbox");
        errdefer allocator.free(dest);
        const clipboard_read_target = try allocator.dupe(u8, "");
        errdefer allocator.free(clipboard_read_target);
        const process_count: usize = switch (self.observation_invalid) {
            .process_count => runtime_metadata_wire.max_process_entries + 1,
            .process_name_too_long, .invalid_utf8 => 1,
            else => 0,
        };
        const processes = try allocator.alloc(
            RuntimeObservation.Process,
            process_count,
        );
        var initialized_processes: usize = 0;
        errdefer {
            for (processes[0..initialized_processes]) |process| allocator.free(process.name);
            allocator.free(processes);
        }
        while (initialized_processes < processes.len) : (initialized_processes += 1) {
            const name_len: usize = if (self.observation_invalid == .process_name_too_long)
                129
            else
                1;
            const name = try allocator.alloc(u8, name_len);
            @memset(name, 'p');
            if (self.observation_invalid == .invalid_utf8) name[0] = 0xff;
            processes[initialized_processes] = .{
                .pid = @intCast(initialized_processes + 1),
                .name = name,
            };
        }
        return .{
            .cwd = cwd,
            .window_title = title,
            .ssh_remote_dest = dest,
            .semantic_state = 2,
            .alt_active = false,
            .app_cursor_keys = false,
            .app_keypad = false,
            .kitty_flags = 0,
            .alternate_scroll = true,
            .mouse_tracking = false,
            .mouse_tracking_mode = if (self.observation_invalid == .mouse_mode) 5 else 0,
            .bracketed_paste = false,
            .bell_count = 0,
            .clipboard_write_seq = 0,
            .clipboard_read_seq = 0,
            .clipboard_read_target = clipboard_read_target,
            .observer_generation = 7,
            .title_generation = 3,
            .cols = 80,
            .rows = 24,
            .foreground_available = self.observation_invalid != .foreground_inconsistent,
            .foreground_pgid = 42,
            .processes = processes,
        };
    }
    threadlocal var cached_observation_bytes: [protocol.max_control_json]u8 = undefined;

    fn cachedObservationFn(
        ctx: *anyopaque,
        runtime_id: u128,
        request: ObservationRequest,
    ) anyerror!CachedRuntimeObservation {
        const self: *FakeRuntimeOps = @ptrCast(@alignCast(ctx));
        const refresh = switch (request) {
            .fresh => true,
            .current => !self.cached_observation_valid,
            .cadence_epoch => |epoch| !self.cached_observation_valid or
                self.cached_observation_epoch == null or
                epoch > self.cached_observation_epoch.?,
        };
        if (!refresh) return .{
            .canonical_json = cached_observation_bytes[0..self.cached_observation_len],
            .change_token = self.cached_observation_token,
        };
        var observation = try observationFn(ctx, runtime_id, testing.allocator);
        defer observation.deinit(testing.allocator);
        const canonical = try canonicalizeObservation(testing.allocator, observation);
        defer testing.allocator.free(canonical);
        if (canonical.len > cached_observation_bytes.len) return error.InvalidObservation;
        @memcpy(cached_observation_bytes[0..canonical.len], canonical);
        if (!self.cached_observation_valid or self.cached_observation_version != self.observation_version)
            self.cached_observation_token = std.math.add(u64, self.cached_observation_token, 1) catch
                return error.ObservationTokenExhausted;
        self.cached_observation_len = canonical.len;
        self.cached_observation_version = self.observation_version;
        self.cached_observation_valid = true;
        switch (request) {
            .cadence_epoch => |epoch| {
                if (self.cached_observation_epoch == null or epoch > self.cached_observation_epoch.?)
                    self.cached_observation_epoch = epoch;
            },
            else => {},
        }
        return .{
            .canonical_json = cached_observation_bytes[0..canonical.len],
            .change_token = self.cached_observation_token,
        };
    }

    pub fn ops(self: *FakeRuntimeOps) RuntimeOps {
        return .{ .ctx = self, .spawn = spawnFn, .terminate = terminateFn, .write_input = writeInputFn, .resize = resizeFn, .snapshot = snapshotFn, .delta = deltaFn, .notification_peek = notificationPeekFn, .notification_commit = notificationCommitFn, .notification_config_update = notificationConfigUpdateFn, .core_command = coreCommandFn, .selected_text = selectedTextFn, .select_op = selectOpFn, .find = findFn, .observation = observationFn, .cached_observation = cachedObservationFn, .report_mouse = reportMouseFn, .link_at = linkAtFn, .clipboard_write = clipboardWriteFn, .observation_urgent = observationUrgentFn };
    }

    pub fn opsWithScreenChangeToken(self: *FakeRuntimeOps) RuntimeOps {
        var result = self.ops();
        result.screen_change_token = screenChangeTokenFn;
        return result;
    }
};

test "P4 N2b1 config.update is exact controller-bound and mutation-free on rejection" {
    const allocator = testing.allocator;
    var registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer registry.deinit();
    _ = try registry.register(0xaa, 80, 24);
    var fake: FakeRuntimeOps = .{};
    var conn = Connection.init(allocator, 1, &registry);
    defer conn.deinit();
    conn.runtime_ops = fake.ops();
    const hello = try feedJson(&conn, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2}");
    if (hello.frame) |frame| frame.deinit(allocator);
    inline for (.{ "controller", "observer" }, 0..) |mode, index| {
        var request_buf: [128]u8 = undefined;
        const request = try std.fmt.bufPrint(&request_buf, "{{\"method\":\"runtime.attach\",\"params\":{{\"runtime_id\":\"aa\",\"mode\":\"{s}\"}}}}", .{mode});
        const frames = try feedExpectFrames(&conn, .request, index + 2, request);
        defer {
            for (frames) |frame| frame.deinit(allocator);
            allocator.free(frames);
        }
    }
    const generation = try registry.controllerGeneration(0xaa);
    var good_buf: [256]u8 = undefined;
    const good = try std.fmt.bufPrint(&good_buf, "{{\"method\":\"config.update\",\"params\":{{\"stream_id\":1,\"expected_controller_generation\":{d},\"config_generation\":7,\"notifications_osc\":true,\"display_label\":\"workspace\"}}}}", .{generation});
    const accepted = try feedJson(&conn, .request, 4, good);
    defer if (accepted.frame) |frame| frame.deinit(allocator);
    try testing.expect(std.mem.indexOf(u8, accepted.frame.?.payload, "\"applied\":true") != null);
    try testing.expectEqual(@as(usize, 1), fake.notification_config_calls);
    try testing.expectEqualStrings("workspace", fake.notification_config_label[0..fake.notification_config_label_len]);

    const stable = try feedJson(&conn, .request, 7, "{\"method\":\"runtime.notification\",\"params\":{\"stream_id\":1,\"delivery_version\":1}}");
    defer if (stable.frame) |frame| frame.deinit(allocator);
    try testing.expect(std.mem.indexOf(u8, stable.frame.?.payload, "\"event\":null") != null);

    const forged_stable = try feedJson(&conn, .request, 8, "{\"method\":\"runtime.notification\",\"params\":{\"runtime_id\":\"aa\",\"delivery_version\":1}}");
    defer if (forged_stable.frame) |frame| frame.deinit(allocator);
    try testing.expect(std.mem.indexOf(u8, forged_stable.frame.?.payload, "invalid_request") != null);

    const denied = try feedJson(&conn, .request, 5, "{\"method\":\"config.update\",\"params\":{\"stream_id\":2,\"expected_controller_generation\":1,\"config_generation\":8,\"notifications_osc\":false,\"display_label\":\"observer\"}}");
    defer if (denied.frame) |frame| frame.deinit(allocator);
    try testing.expect(std.mem.indexOf(u8, denied.frame.?.payload, "unauthorized") != null);
    try testing.expectEqual(@as(usize, 1), fake.notification_config_calls);

    const stale = try feedJson(&conn, .request, 9, "{\"method\":\"config.update\",\"params\":{\"stream_id\":1,\"expected_controller_generation\":999,\"config_generation\":8,\"notifications_osc\":false,\"display_label\":\"stale\"}}");
    defer if (stale.frame) |frame| frame.deinit(allocator);
    try testing.expect(std.mem.indexOf(u8, stale.frame.?.payload, "invalid_generation") != null);
    try testing.expectEqual(@as(usize, 1), fake.notification_config_calls);

    const unknown = try feedJson(&conn, .request, 6, "{\"method\":\"config.update\",\"params\":{\"stream_id\":1,\"expected_controller_generation\":1,\"config_generation\":8,\"notifications_osc\":false,\"display_label\":\"bad\",\"extra\":1}}");
    defer if (unknown.frame) |frame| frame.deinit(allocator);
    try testing.expect(std.mem.indexOf(u8, unknown.frame.?.payload, "invalid_request") != null);
    try testing.expectEqual(@as(usize, 1), fake.notification_config_calls);
}

test "server: runtime.spawn/terminate dispatch through RuntimeOps; read-only host is unauthorized" {
    const allocator = testing.allocator;
    var registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer registry.deinit();

    // runtime_ops가 있는 host: spawn/terminate가 vtable로 위임된다.
    var fake: FakeRuntimeOps = .{};
    var conn = Connection.init(allocator, 1, &registry);
    conn.runtime_ops = fake.ops();
    {
        const h = try feedJson(&conn, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2}");
        if (h.frame) |f| f.deinit(allocator);
    }
    {
        const r = try feedJson(&conn, .request, 2, "{\"method\":\"runtime.spawn_full\",\"params\":{\"argv\":[\"/bin/sh\",\"-c\",\"cat\"],\"cwd\":\"/tmp/full-contract\",\"login\":true," ++
            "\"env\":[\"A=1\"],\"parent_env\":[],\"env_overrides\":[\"B=2\"],\"term\":\"xterm-maru\",\"zdotdir\":\"/tmp/zdot\"," ++
            "\"ssh_integration_bin\":\"/Applications/Maru.app/Contents/MacOS/maru\",\"pane_id\":\"ffffffffffffffff\",\"cols\":100,\"rows\":40," ++
            "\"runtime_config\":{\"lines\":4321,\"ambiguous_wide\":true,\"emoji_wide\":false," ++
            "\"palette\":[1,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null]," ++
            "\"foreground\":1122867,\"background\":4478310,\"cell_width\":9,\"cell_height\":18}}}");
        defer if (r.frame) |f| f.deinit(allocator);
        try testing.expect(std.mem.indexOf(u8, r.frame.?.payload, "cafe") != null); // runtime_id hex(0xCAFE)
    }
    try testing.expectEqualStrings("/bin/sh", fake.spawn_argv0[0..fake.spawn_argv0_len]);
    try testing.expectEqual(@as(u16, 100), fake.spawn_cols);
    try testing.expectEqualStrings("/tmp/full-contract", fake.spawn_cwd[0..fake.spawn_cwd_len]);
    try testing.expect(fake.spawn_login);
    try testing.expectEqual(@as(usize, 1), fake.spawn_env_count);
    try testing.expect(fake.spawn_parent_env_present);
    try testing.expectEqual(@as(usize, 0), fake.spawn_parent_env_count);
    try testing.expectEqual(@as(usize, 1), fake.spawn_env_override_count);
    try testing.expectEqualStrings("xterm-maru", fake.spawn_term[0..fake.spawn_term_len]);
    try testing.expect(fake.spawn_zdotdir_seen);
    try testing.expect(fake.spawn_ssh_bin_seen);
    try testing.expectEqual(@as(?u64, std.math.maxInt(u64)), fake.spawn_pane_id);
    try testing.expectEqual(@as(u32, 4321), fake.spawn_initial_config.?.max_scrollback);
    try testing.expect(fake.spawn_initial_config.?.ambiguous_wide);
    try testing.expectEqual(@as(?u32, 1), fake.spawn_initial_config.?.palette[0]);
    try testing.expectEqual(@as(u32, 9), fake.spawn_initial_config.?.cell_metrics.?.width);
    {
        const r = try feedJson(&conn, .request, 21, "{\"method\":\"runtime.spawn\",\"params\":{\"argv\":[\"/bin/sh\"],\"cols\":80,\"rows\":24}}");
        defer if (r.frame) |f| f.deinit(allocator);
        try testing.expect(std.mem.indexOf(u8, r.frame.?.payload, "cafe") != null);
        try testing.expect(!fake.spawn_parent_env_present); // legacy 요청의 env=[]는 host process environ 상속 의미를 보존한다.
    }
    {
        const r = try feedJson(&conn, .request, 22, "{\"method\":\"runtime.spawn_full\",\"params\":{\"argv\":[\"/bin/sh\"],\"pane_id\":\"not-a-pane-id!!!\"}}");
        defer if (r.frame) |f| f.deinit(allocator);
        try testing.expect(std.mem.indexOf(u8, r.frame.?.payload, "invalid_request") != null);
    }
    const count_after_valid = fake.spawn_count;
    inline for (.{
        "{\"method\":\"runtime.spawn_full\",\"params\":{\"argv\":[\"/bin/sh\"],\"cwd\":7}}",
        "{\"method\":\"runtime.spawn_full\",\"params\":{\"argv\":[\"/bin/sh\"],\"login\":\"yes\"}}",
        "{\"method\":\"runtime.spawn_full\",\"params\":{\"argv\":[\"/bin/sh\"],\"term\":null}}",
        "{\"method\":\"runtime.spawn_full\",\"params\":{\"argv\":[\"/bin/sh\"],\"zdotdir\":false}}",
        "{\"method\":\"runtime.spawn_full\",\"params\":{\"argv\":[\"/bin/sh\"],\"ssh_integration_bin\":[]}}",
        "{\"method\":\"runtime.spawn_full\",\"params\":{\"argv\":[\"/bin/sh\"],\"env\":null}}",
        "{\"method\":\"runtime.spawn_full\",\"params\":{\"argv\":[\"/bin/sh\"],\"parent_env\":null}}",
        "{\"method\":\"runtime.spawn_full\",\"params\":{\"argv\":[\"/bin/sh\"],\"env_overrides\":null}}",
        "{\"method\":\"runtime.spawn_full\",\"params\":{\"argv\":[\"/bin/sh\"],\"cols\":0}}",
        "{\"method\":\"runtime.spawn_full\",\"params\":{\"argv\":[\"/bin/sh\"],\"rows\":70000}}",
    }, 0..) |payload, i| {
        const r = try feedJson(&conn, .request, 30 + i, payload);
        defer if (r.frame) |f| f.deinit(allocator);
        try testing.expect(std.mem.indexOf(u8, r.frame.?.payload, "invalid_request") != null);
    }
    try testing.expectEqual(count_after_valid, fake.spawn_count); // malformed 요청은 PTY spawn에 도달하지 않는다.
    {
        const r = try feedJson(&conn, .request, 3, "{\"method\":\"runtime.terminate\",\"params\":{\"runtime_id\":\"cafe\"}}");
        defer if (r.frame) |f| f.deinit(allocator);
        try testing.expect(std.mem.indexOf(u8, r.frame.?.payload, "terminated") != null);
    }
    try testing.expectEqual(@as(u128, 0xCAFE), fake.terminated_id);

    // read-only host(runtime_ops=null): spawn은 unauthorized다(§10, §11 — attach 역할에 spawn을 암묵 부여하지 않는다).
    var conn2 = Connection.init(allocator, 1, &registry);
    {
        const h = try feedJson(&conn2, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2}");
        if (h.frame) |f| f.deinit(allocator);
    }
    const r = try feedJson(&conn2, .request, 2, "{\"method\":\"runtime.spawn\",\"params\":{\"argv\":[\"/bin/sh\"],\"cols\":80,\"rows\":24}}");
    defer if (r.frame) |f| f.deinit(allocator);
    try testing.expect(std.mem.indexOf(u8, r.frame.?.payload, "unauthorized") != null);
}

test "server: attach grants capabilities; controller input/resize dispatch through RuntimeOps; stale/detach honored" {
    const allocator = testing.allocator;
    var registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer registry.deinit();
    _ = try registry.register(0xAA, 80, 24);
    _ = try registry.register(0xBB, 80, 24);

    var fake: FakeRuntimeOps = .{};
    var conn = Connection.init(allocator, 1, &registry);
    defer conn.deinit(); // attach subscription을 registry에서 뗀다(deinit는 registry.deinit보다 먼저 — defer LIFO).
    conn.runtime_ops = fake.ops();
    {
        const h = try feedJson(&conn, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2}");
        if (h.frame) |f| f.deinit(allocator);
    }

    // controller attach → granted에 input+resize, host가 stream_id 발급.
    {
        const r = try feedJson(&conn, .request, 2, "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"controller\"}}");
        defer if (r.frame) |f| f.deinit(allocator);
        try testing.expect(std.mem.indexOf(u8, r.frame.?.payload, "\"input\":true") != null);
        try testing.expect(std.mem.indexOf(u8, r.frame.?.payload, "\"resize\":true") != null);
        try testing.expect(std.mem.indexOf(u8, r.frame.?.payload, "\"stream_id\":1") != null);
    }

    // input_bytes(stream 1) → controller라 runtime_ops.write_input에 라우팅된다(응답 없음 = none).
    {
        const r = try feedStream(&conn, .input_bytes, 1, "echo hi\n");
        try testing.expectEqualStrings("none", r.action);
    }
    try testing.expectEqualStrings("echo hi\n", fake.last_input[0..fake.last_input_len]);
    try testing.expectEqual(@as(u128, 0xAA), fake.input_runtime);

    // 응답 없는 scroll barrier는 controller stream에서만 host core에 적용된다.
    {
        const r = try feedStream(&conn, .scroll_to_bottom, 1, "");
        try testing.expectEqualStrings("none", r.action);
    }
    try testing.expectEqualDeep(core_command_wire.Command.scroll_to_bottom, fake.last_core_command.?);
    try testing.expectEqual(@as(u128, 0xAA), fake.core_command_runtime);

    // client_sequence is required and strictly typed; malformed requests cannot mutate backend.
    for ([_][]const u8{
        "{\"method\":\"runtime.resize\",\"params\":{\"stream_id\":1,\"cols\":100,\"rows\":40}}",
        "{\"method\":\"runtime.resize\",\"params\":{\"stream_id\":1,\"cols\":100,\"rows\":40,\"client_sequence\":\"1\"}}",
    }) |payload| {
        const r = try feedJson(&conn, .request, 30, payload);
        defer if (r.frame) |f| f.deinit(allocator);
        try testing.expect(std.mem.indexOf(u8, r.frame.?.payload, "invalid_request") != null);
    }
    try testing.expectEqual(@as(u16, 0), fake.resized_cols);

    // resize(controller, seq 1) → registry 적용 + runtime_ops.resize 위임 + applied 응답(changed=true).
    {
        const r = try feedJson(&conn, .request, 3, "{\"method\":\"runtime.resize\",\"params\":{\"stream_id\":1,\"cols\":100,\"rows\":40,\"client_sequence\":1}}");
        defer if (r.frame) |f| f.deinit(allocator);
        try testing.expect(std.mem.indexOf(u8, r.frame.?.payload, "\"changed\":true") != null);
        try testing.expect(std.mem.indexOf(u8, r.frame.?.payload, "\"cols\":100") != null);
    }
    try testing.expectEqual(@as(u16, 100), fake.resized_cols);
    try testing.expectEqual(@as(u16, 40), fake.resized_rows);
    try testing.expectEqual(@as(u128, 0xAA), fake.resized_runtime);

    // 같은/이하 sequence 재요청 → stale(재적용하지 않는다). runtime_ops.resize는 다시 호출되지 않는다.
    fake.resized_cols = 0;
    {
        const r = try feedJson(&conn, .request, 4, "{\"method\":\"runtime.resize\",\"params\":{\"stream_id\":1,\"cols\":50,\"rows\":10,\"client_sequence\":1}}");
        defer if (r.frame) |f| f.deinit(allocator);
        try testing.expect(std.mem.indexOf(u8, r.frame.?.payload, "stale") != null);
    }
    try testing.expectEqual(@as(u16, 0), fake.resized_cols); // stale이라 위임 안 됨.

    // detach → subscription 해제, 이후 input은 조용히 버려진다(none, write_input 미호출).
    {
        const r = try feedJson(&conn, .request, 5, "{\"method\":\"runtime.detach\",\"params\":{\"stream_id\":1}}");
        defer if (r.frame) |f| f.deinit(allocator);
        try testing.expect(std.mem.indexOf(u8, r.frame.?.payload, "detached") != null);
    }
    fake.last_input_len = 99;
    {
        const r = try feedStream(&conn, .input_bytes, 1, "late");
        try testing.expectEqualStrings("none", r.action);
    }
    try testing.expectEqual(@as(usize, 99), fake.last_input_len); // 미attach stream이라 write_input 미호출(값 그대로).
}

test "server: attach rejects unknown and legacy takeover modes without authority mutation" {
    var registry = reg.TerminalRuntimeRegistry.init(testing.allocator);
    defer registry.deinit();
    _ = try registry.register(0xAA, 80, 24);
    var conn = Connection.init(testing.allocator, 1, &registry);
    defer conn.deinit();
    {
        const result = try feedJson(
            &conn,
            .hello,
            1,
            "{\"protocol_min\":2,\"protocol_max\":2}",
        );
        if (result.frame) |frame| frame.deinit(testing.allocator);
    }

    inline for (&.{
        "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"takeover\"}}",
        "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"takevoer\"}}",
    }) |request| {
        const result = try feedJson(&conn, .request, 2, request);
        defer if (result.frame) |frame| frame.deinit(testing.allocator);
        try testing.expect(std.mem.indexOf(
            u8,
            result.frame.?.payload,
            "\"invalid_request\"",
        ) != null);
        try testing.expectEqual(@as(usize, 0), registry.attachmentCount());
        try testing.expectEqual(@as(usize, 0), conn.attachmentCount());
    }
}

test "server: backend resize failure leaves canonical size sequence generation and ledger unchanged" {
    const allocator = testing.allocator;
    var registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer registry.deinit();
    const entry = try registry.register(0xAA, 100, 40);
    const initial_cells = registry.liveGridCells();

    var fake: FakeRuntimeOps = .{ .resize_fail_count = 1 };
    var conn = Connection.init(allocator, 1, &registry);
    defer conn.deinit();
    conn.runtime_ops = fake.ops();
    {
        const hello = try feedJson(
            &conn,
            .hello,
            1,
            "{\"protocol_min\":2,\"protocol_max\":2,\"capabilities\":[\"runtime_metadata_v1\"]}",
        );
        if (hello.frame) |frame| frame.deinit(allocator);
    }
    {
        const attach = try feedJson(&conn, .request, 2, "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"controller\"}}");
        defer if (attach.frame) |frame| frame.deinit(allocator);
    }

    const failed = try feedJson(
        &conn,
        .request,
        3,
        "{\"method\":\"runtime.resize\",\"params\":{\"stream_id\":1,\"cols\":50,\"rows\":20,\"client_sequence\":7}}",
    );
    defer if (failed.frame) |frame| frame.deinit(allocator);
    try testing.expect(std.mem.indexOf(u8, failed.frame.?.payload, "internal") != null);
    try testing.expectEqual(@as(u16, 100), entry.cols);
    try testing.expectEqual(@as(u16, 40), entry.rows);
    try testing.expect(!entry.resize_seq_seen);
    try testing.expectEqual(@as(u64, 0), entry.controller_sequence);
    try testing.expectEqual(@as(u64, 0), entry.resize_generation);
    try testing.expectEqual(initial_cells, registry.liveGridCells());

    const retried = try feedJson(
        &conn,
        .request,
        4,
        "{\"method\":\"runtime.resize\",\"params\":{\"stream_id\":1,\"cols\":50,\"rows\":20,\"client_sequence\":7}}",
    );
    defer if (retried.frame) |frame| frame.deinit(allocator);
    try testing.expect(std.mem.indexOf(u8, retried.frame.?.payload, "\"changed\":true") != null);
    try testing.expectEqual(@as(u16, 50), entry.cols);
    try testing.expectEqual(@as(u16, 20), entry.rows);
    try testing.expect(entry.resize_seq_seen);
    try testing.expectEqual(@as(u64, 7), entry.controller_sequence);
    try testing.expectEqual(@as(u64, 1), entry.resize_generation);
    try testing.expectEqual(@as(usize, 50 * 20), registry.liveGridCells());
}

test "server: changed resize is prepared without backend or canonical mutation" {
    const allocator = testing.allocator;
    var registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer registry.deinit();
    const entry = try registry.register(0xAA, 100, 40);

    var fake: FakeRuntimeOps = .{};
    var conn = Connection.init(allocator, 1, &registry);
    defer conn.deinit();
    conn.runtime_ops = fake.ops();
    {
        const hello = try feedJson(
            &conn,
            .hello,
            1,
            "{\"protocol_min\":2,\"protocol_max\":2}",
        );
        if (hello.frame) |frame| frame.deinit(allocator);
    }
    {
        const attach = try feedJson(
            &conn,
            .request,
            2,
            "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"controller\"}}",
        );
        defer if (attach.frame) |frame| frame.deinit(allocator);
    }

    const wire = try framing.encodeFrame(
        allocator,
        .{ .kind = .request, .request_id = 3 },
        "{\"method\":\"runtime.resize\",\"params\":{\"stream_id\":1,\"cols\":50,\"rows\":20,\"client_sequence\":7}}",
    );
    defer allocator.free(wire);
    var parser = framing.FrameParser.init(allocator);
    defer parser.deinit();
    try parser.push(wire);
    const frame = (try parser.next()).?;
    defer frame.deinit(allocator);

    var action = try conn.handleFrame(frame);
    defer conn.discardPreparedResize(&action.resize_requested);
    try testing.expect(action == .resize_requested);
    try testing.expectEqual(@as(u16, 0), fake.resized_cols);
    try testing.expectEqual(@as(u16, 100), entry.cols);
    try testing.expectEqual(@as(u16, 40), entry.rows);
    try testing.expect(!entry.resize_seq_seen);
    try testing.expectEqual(@as(u64, 0), entry.resize_generation);
}

test "server: observer attach is denied input and resize" {
    const allocator = testing.allocator;
    var registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer registry.deinit();
    _ = try registry.register(0xBB, 80, 24);

    var fake: FakeRuntimeOps = .{};
    var conn = Connection.init(allocator, 1, &registry);
    defer conn.deinit();
    conn.runtime_ops = fake.ops();
    {
        const h = try feedJson(&conn, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2}");
        if (h.frame) |f| f.deinit(allocator);
    }
    // observer attach → observe만.
    {
        const r = try feedJson(&conn, .request, 2, "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"bb\",\"mode\":\"observer\"}}");
        defer if (r.frame) |f| f.deinit(allocator);
        try testing.expect(std.mem.indexOf(u8, r.frame.?.payload, "\"observe\":true") != null);
        try testing.expect(std.mem.indexOf(u8, r.frame.?.payload, "\"input\":false") != null);
    }
    // observer input_bytes는 write_input에 도달하지 않는다(input capability 없음).
    {
        const r = try feedStream(&conn, .input_bytes, 1, "nope");
        try testing.expectEqualStrings("none", r.action);
    }
    try testing.expectEqual(@as(usize, 0), fake.last_input_len);
    fake.last_core_command = null;
    {
        const r = try feedStream(&conn, .scroll_to_bottom, 1, "");
        try testing.expectEqualStrings("none", r.action);
    }
    try testing.expectEqual(@as(?core_command_wire.Command, null), fake.last_core_command); // observer는 shared viewport를 흔들 수 없다.
    // observer resize는 unauthorized(controller 아님).
    {
        const r = try feedJson(&conn, .request, 3, "{\"method\":\"runtime.resize\",\"params\":{\"stream_id\":1,\"cols\":90,\"rows\":30,\"client_sequence\":1}}");
        defer if (r.frame) |f| f.deinit(allocator);
        try testing.expect(std.mem.indexOf(u8, r.frame.?.payload, "unauthorized") != null);
    }
    try testing.expectEqual(@as(u16, 0), fake.resized_cols);
}

test "server: attach streams the runtime snapshot as snapshot_chunk frames after the reply" {
    const allocator = testing.allocator;
    var registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer registry.deinit();
    _ = try registry.register(0xAA, 80, 24);
    _ = try registry.register(0xBB, 80, 24);

    var fake: FakeRuntimeOps = .{};
    var conn = Connection.init(allocator, 1, &registry);
    defer conn.deinit();
    conn.runtime_ops = fake.ops();
    {
        const h = try feedJson(&conn, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2,\"capabilities\":[\"runtime_metadata_v1\"]}");
        if (h.frame) |f| f.deinit(allocator);
    }
    // attach → 응답 frame + snapshot_chunk(end_stream) frame이 순서대로 온다(§10).
    const frames = try feedExpectFrames(&conn, .request, 2, "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"observer\"}}");
    defer {
        for (frames) |f| f.deinit(allocator);
        allocator.free(frames);
    }
    try testing.expectEqual(@as(usize, 2), frames.len);
    // frames[0] = attach 응답(stream_id 포함).
    try testing.expectEqual(protocol.Kind.response, frames[0].header.kind);
    try testing.expect(std.mem.indexOf(u8, frames[0].payload, "stream_id") != null);
    try testing.expect(std.mem.indexOf(u8, frames[0].payload, "\"metadata_revision\":1") != null);
    try testing.expect(std.mem.indexOf(u8, frames[0].payload, "\"cwd\":\"/tmp/project\"") != null);
    try testing.expect(std.mem.indexOf(u8, frames[0].payload, "\"ssh_remote_dest\":\"workbox\"") != null);
    // frames[1] = snapshot_chunk(end_stream), attach가 발급한 stream_id(1), payload는 host가 투영한 snapshot 바이트.
    try testing.expectEqual(protocol.Kind.snapshot_chunk, frames[1].header.kind);
    try testing.expect(protocol.Flags.hasEndStream(frames[1].header.flags));
    try testing.expectEqual(@as(u64, 1), frames[1].header.stream_id);
    try testing.expectEqualStrings("SNAPSHOT-BYTES", frames[1].payload);
}

test "P4 E3a unchanged screen token opens no projector and one advance commits exactly once" {
    const allocator = testing.allocator;
    var registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer registry.deinit();
    _ = try registry.register(0xAA, 80, 24);

    var fake: FakeRuntimeOps = .{ .screen_change_token = .{ .incarnation = 1, .revision = 1 } };
    var conn = Connection.init(allocator, 1, &registry);
    defer conn.deinit();
    conn.runtime_ops = fake.opsWithScreenChangeToken();
    {
        const hello = try feedJson(&conn, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2}");
        if (hello.frame) |frame| frame.deinit(allocator);
    }
    const attach = try feedExpectFrames(
        &conn,
        .request,
        2,
        "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"observer\"}}",
    );
    defer {
        for (attach) |frame| frame.deinit(allocator);
        allocator.free(attach);
    }
    try testing.expectEqual(@as(usize, 1), fake.snapshot_calls);

    try testing.expectEqual(@as(?CollectedOutput, null), try conn.collectOutputForLocalStream(1));
    try testing.expectEqual(@as(usize, 0), fake.delta_calls);
    try testing.expectEqual(@as(usize, 2), fake.screen_token_reads);

    fake.screen_change_token.revision = 2;
    var rejected = (try conn.collectOutputForLocalStream(1)).?;
    try testing.expectEqual(@as(usize, 1), fake.delta_calls);
    rejected.rollback(&conn);

    // Admission rollback must not consume the edge: the same token is projected again.
    var changed = (try conn.collectOutputForLocalStream(1)).?;
    try testing.expectEqual(@as(usize, 2), fake.delta_calls);
    changed.commit(&conn);

    try testing.expectEqual(@as(?CollectedOutput, null), try conn.collectOutputForLocalStream(1));
    try testing.expectEqual(@as(usize, 2), fake.delta_calls);

    fake.screen_change_token = .{ .incarnation = 2, .revision = 1 };
    var rollover = (try conn.collectOutputForLocalStream(1)).?;
    try testing.expectEqual(@as(usize, 2), fake.snapshot_calls);
    try testing.expectEqual(@as(usize, 2), fake.delta_calls);
    rollover.commit(&conn);

    try testing.expectEqual(@as(?CollectedOutput, null), try conn.collectOutputForLocalStream(1));
    try testing.expectEqual(@as(usize, 2), fake.snapshot_calls);
}

test "CR4a frontier는 output admission commit 뒤에만 subscription sequence를 전진한다" {
    const allocator = testing.allocator;
    var registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer registry.deinit();
    _ = try registry.register(0xAA, 80, 24);

    var fake: FakeRuntimeOps = .{};
    var conn = Connection.init(allocator, 1, &registry);
    defer conn.deinit();
    conn.runtime_ops = fake.ops();
    {
        const hello = try feedJson(&conn, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2}");
        if (hello.frame) |frame| frame.deinit(allocator);
    }
    const attach = try feedExpectFrames(&conn, .request, 2, "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"observer\"}}");
    defer {
        for (attach) |frame| frame.deinit(allocator);
        allocator.free(attach);
    }
    try testing.expectEqual(@as(u64, 0), conn.attachments.get(1).?.screen_sequence);

    var rolled_back = (try conn.collectOutputForLocalStream(1)).?;
    try testing.expectEqual(@as(?u64, 1), rolled_back.next_screen_sequence);
    try testing.expectEqual(@as(u64, 1), fake.delta_sequence_seen);
    try testing.expectEqual(@as(u64, 0), conn.attachments.get(1).?.screen_sequence);
    rolled_back.rollback(&conn);
    try testing.expectEqual(@as(u64, 0), conn.attachments.get(1).?.screen_sequence);

    var committed = (try conn.collectOutputForLocalStream(1)).?;
    try testing.expectEqual(@as(?u64, 1), committed.next_screen_sequence);
    try testing.expectEqual(@as(u64, 1), fake.delta_sequence_seen);
    committed.commit(&conn);
    try testing.expectEqual(@as(u64, 1), conn.attachments.get(1).?.screen_sequence);

    const resync = try feedJson(&conn, .request, 3, "{\"method\":\"runtime.resync\",\"params\":{\"stream_id\":1}}");
    defer if (resync.frame) |frame| frame.deinit(allocator);
    var reset = (try conn.collectOutputForLocalStream(1)).?;
    try testing.expectEqual(@as(?u64, 2), reset.next_screen_sequence);
    try testing.expectEqual(@as(u64, 2), fake.snapshot_sequence_seen);
    reset.commit(&conn);
    try testing.expectEqual(@as(u64, 2), conn.attachments.get(1).?.screen_sequence);

    fake.delta_is_snapshot = true;
    var fallback_snapshot = (try conn.collectOutputForLocalStream(1)).?;
    try testing.expectEqual(@as(u64, 3), fake.delta_sequence_seen);
    try testing.expectEqual(@as(?u64, 3), fallback_snapshot.next_screen_sequence);
    fallback_snapshot.commit(&conn);
    try testing.expectEqual(@as(u64, 3), conn.attachments.get(1).?.screen_sequence);
    fake.delta_is_snapshot = false;

    fake.delta_send_len = 0;
    var unchanged = (try conn.collectOutputForLocalStream(1)).?;
    try testing.expectEqual(@as(u64, 4), fake.delta_sequence_seen);
    try testing.expectEqual(@as(?u64, null), unchanged.next_screen_sequence);
    unchanged.commit(&conn);
    try testing.expectEqual(@as(u64, 3), conn.attachments.get(1).?.screen_sequence);

    const unchanged_identity: catchup_barrier_contract.CatchupIdentity = .{
        .subscription = .{ .value = 9 },
        .runtime_id = 0xAA,
        .connection = .{ .monotonic_id = 3, .slot_generation = 4 },
        .host_id = 1,
        .request_nonce = 5,
    };
    try testing.expectEqual(
        catchup_barrier_contract.HostState.ArmResult.armed,
        conn.attachments.getPtr(1).?.catchup.arm(unchanged_identity, 10, 20),
    );
    const pending_before_barrier = conn.attachments.get(1).?.catchup;
    var barrier_only = (try conn.collectOutputForLocalStreamAt(1, 11)).?;
    try testing.expectEqual(@as(usize, 1), barrier_only.frames.len);
    try testing.expectEqual(
        OutboundClass{ .subscription = .{ .stream = 1, .kind = .barrier } },
        try classifyOutbound(barrier_only.frames[0]),
    );
    try testing.expectEqual(@as(?u64, null), barrier_only.next_screen_sequence);
    try testing.expectEqual(@as(u64, 3), barrier_only.prepared_catchup.?.barrier.target.sequence);
    barrier_only.rollback(&conn);
    try testing.expectEqualDeep(pending_before_barrier, conn.attachments.get(1).?.catchup);
    try testing.expectEqual(@as(u64, 3), conn.attachments.get(1).?.screen_sequence);

    fake.frontier_generation = 1;
    try testing.expectError(error.OutOfMemory, conn.collectOutputForLocalStreamAt(1, 12));
    try testing.expectEqualDeep(pending_before_barrier, conn.attachments.get(1).?.catchup);
    try testing.expectEqual(@as(u64, 0), conn.attachments.get(1).?.screen_generation);
    fake.delta_send_len = null;
    try testing.expectError(error.OutOfMemory, conn.collectOutputForLocalStreamAt(1, 12));
    try testing.expectEqualDeep(pending_before_barrier, conn.attachments.get(1).?.catchup);
    try testing.expectEqual(@as(u64, 3), conn.attachments.get(1).?.screen_sequence);
    fake.frontier_generation = 0;
    fake.delta_send_len = 0;

    // Sweep every allocation before the immutable barrier batch becomes prepared.  A local OOM
    // cannot consume the pending row or advance the committed projection frontier.
    var saw_barrier_oom = false;
    var saw_barrier_success = false;
    for (0..16) |fail_index| {
        var failing = testing.FailingAllocator.init(
            allocator,
            .{ .fail_index = fail_index },
        );
        conn.allocator = failing.allocator();
        const attempt = conn.collectOutputForLocalStreamAt(1, 12);
        conn.allocator = allocator;
        if (attempt) |maybe_output| {
            var prepared = maybe_output orelse return error.TestUnexpectedResult;
            prepared.rollback(&conn);
            saw_barrier_success = true;
            break;
        } else |err| switch (err) {
            error.OutOfMemory => saw_barrier_oom = true,
            error.ProjectionBudgetUnavailable => return error.TestUnexpectedResult,
        }
        try testing.expectEqualDeep(pending_before_barrier, conn.attachments.get(1).?.catchup);
        try testing.expectEqual(@as(u64, 3), conn.attachments.get(1).?.screen_sequence);
        try testing.expectEqualStrings("NEW-BASE", conn.attachments.get(1).?.base.?);
    }
    try testing.expect(saw_barrier_oom);
    try testing.expect(saw_barrier_success);

    conn.attachments.getPtr(1).?.screen_sequence = std.math.maxInt(u64);
    try testing.expectError(error.OutOfMemory, conn.collectOutputForLocalStream(1));
    try testing.expectEqual(std.math.maxInt(u64), conn.attachments.get(1).?.screen_sequence);
}

test "server: every invalid RuntimeOps metadata class closes before attach wire publication" {
    const cases = [_]FakeRuntimeOps.InvalidObservation{
        .process_name_too_long,
        .process_count,
        .aggregate_strings,
        .encoded_escape_expansion,
        .invalid_utf8,
        .foreground_inconsistent,
        .mouse_mode,
    };
    for (cases) |invalid| {
        const allocator = testing.allocator;
        var registry = reg.TerminalRuntimeRegistry.init(allocator);
        defer registry.deinit();
        _ = try registry.register(0xAA, 80, 24);
        var fake: FakeRuntimeOps = .{ .observation_invalid = invalid };
        var conn = Connection.init(allocator, 1, &registry);
        defer conn.deinit();
        conn.runtime_ops = fake.ops();
        {
            const hello = try feedJson(
                &conn,
                .hello,
                1,
                "{\"protocol_min\":2,\"protocol_max\":2,\"capabilities\":[\"runtime_metadata_v1\"]}",
            );
            defer if (hello.frame) |frame| frame.deinit(allocator);
        }
        const attach = try feedJson(
            &conn,
            .request,
            2,
            "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"observer\"}}",
        );
        try testing.expectEqualStrings("close", attach.action);
        try testing.expect(attach.frame == null);
        try testing.expectEqual(Connection.State.closed, conn.state);
        try testing.expectEqual(@as(usize, 0), conn.attachmentCount());
    }
}

test "server: JSON escape expansion below the encoded control cap still publishes attach" {
    const allocator = testing.allocator;
    var registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer registry.deinit();
    _ = try registry.register(0xAA, 80, 24);
    var fake: FakeRuntimeOps = .{ .observation_invalid = .encoded_escape_fits };
    var conn = Connection.init(allocator, 1, &registry);
    defer conn.deinit();
    conn.runtime_ops = fake.ops();
    {
        const hello = try feedJson(
            &conn,
            .hello,
            1,
            "{\"protocol_min\":2,\"protocol_max\":2,\"capabilities\":[\"runtime_metadata_v1\"]}",
        );
        defer if (hello.frame) |frame| frame.deinit(allocator);
    }
    const frames = try feedExpectFrames(
        &conn,
        .request,
        2,
        "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"observer\"}}",
    );
    defer {
        for (frames) |frame| frame.deinit(allocator);
        allocator.free(frames);
    }
    try testing.expectEqual(@as(usize, 2), frames.len);
    try testing.expect(frames[0].payload.len <= protocol.max_control_json);
    try testing.expectEqual(protocol.Kind.snapshot_chunk, frames[1].header.kind);
}

test "server: initial attach accepts exact viewport snapshot cap and rejects cap plus one before chunking" {
    const allocator = testing.allocator;
    var registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer registry.deinit();
    _ = try registry.register(0xAA, 80, 24);
    _ = try registry.register(0xBB, 80, 24);

    var fake: FakeRuntimeOps = .{ .snapshot_len = protocol.max_viewport_snapshot };
    var subscriptions = subscription_identity.Table.init(allocator);
    defer subscriptions.deinit();
    const connection_key = connection_slot.ConnectionKey{
        .monotonic_id = 1,
        .slot_generation = 1,
    };
    var conn = Connection.initProduct(
        allocator,
        1,
        &registry,
        connection_key,
        &subscriptions,
    );
    defer conn.deinit();
    conn.runtime_ops = fake.ops();
    {
        const hello = try feedJson(
            &conn,
            .hello,
            1,
            "{\"protocol_min\":2,\"protocol_max\":2}",
        );
        if (hello.frame) |frame| frame.deinit(allocator);
    }
    const exact = try feedExpectFrames(
        &conn,
        .request,
        2,
        "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"observer\"}}",
    );
    defer {
        for (exact) |frame| frame.deinit(allocator);
        allocator.free(exact);
    }
    try testing.expectEqual(
        @as(usize, 1 + protocol.max_viewport_snapshot / protocol.max_binary_chunk),
        exact.len,
    );
    try testing.expect(protocol.Flags.hasEndStream(exact[exact.len - 1].header.flags));
    try testing.expect(subscriptions.resolveLocal(.{
        .connection = connection_key,
        .stream_id = 1,
    }) != null);

    fake.snapshot_len = protocol.max_viewport_snapshot + 1;
    const oversized = try feedJson(
        &conn,
        .request,
        3,
        "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"bb\",\"mode\":\"observer\"}}",
    );
    defer if (oversized.frame) |frame| frame.deinit(allocator);
    try testing.expectEqualStrings("close", oversized.action);
    try testing.expectEqual(@as(?framing.Frame, null), oversized.frame);
    try testing.expectEqual(@as(usize, 1), conn.attachmentCount());
    try testing.expect(subscriptions.resolveLocal(.{
        .connection = connection_key,
        .stream_id = 2,
    }) == null);
    try testing.expectEqual(
        @as(u8, 0),
        registry.capabilitiesOfSubscription(0xBB, .{ .value = 2 }),
    );
}

test "server: product attach reserves retained budget before snapshot projection" {
    const RejectBudget = struct {
        prepare_calls: usize = 0,

        fn prepare(
            ctx: *anyopaque,
            _: subscription_identity.LocalStreamId,
            _: usize,
        ) ?connection_slot.BaseReservation {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.prepare_calls += 1;
            return null;
        }
        fn commit(_: *anyopaque, _: connection_slot.BaseReservation, _: usize) void {
            unreachable;
        }
        fn rollback(_: *anyopaque, _: connection_slot.BaseReservation) void {
            unreachable;
        }
        fn release(_: *anyopaque, _: subscription_identity.LocalStreamId) void {}
    };

    var registry = reg.TerminalRuntimeRegistry.init(testing.allocator);
    defer registry.deinit();
    _ = try registry.register(0xAA, 80, 24);
    var fake: FakeRuntimeOps = .{};
    var budget: RejectBudget = .{};
    var conn = Connection.init(testing.allocator, 1, &registry);
    defer conn.deinit();
    conn.runtime_ops = fake.ops();
    conn.projection_budget = .{
        .ctx = &budget,
        .prepare = RejectBudget.prepare,
        .commit = RejectBudget.commit,
        .rollback = RejectBudget.rollback,
        .release = RejectBudget.release,
    };
    {
        const hello = try feedJson(
            &conn,
            .hello,
            1,
            "{\"protocol_min\":2,\"protocol_max\":2}",
        );
        defer if (hello.frame) |frame| frame.deinit(testing.allocator);
    }
    const attach = try feedJson(
        &conn,
        .request,
        2,
        "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"observer\"}}",
    );
    try testing.expectEqualStrings("close", attach.action);
    try testing.expectEqual(@as(usize, 1), budget.prepare_calls);
    try testing.expectEqual(@as(usize, 0), fake.snapshot_calls);
    try testing.expectEqual(@as(usize, 0), conn.attachmentCount());
}

test "server: runtime metadata changes emit one full-state event and unchanged polls stay silent" {
    const allocator = testing.allocator;
    var registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer registry.deinit();
    _ = try registry.register(0xAA, 80, 24);

    var fake: FakeRuntimeOps = .{};
    var conn = Connection.init(allocator, 1, &registry);
    defer conn.deinit();
    conn.runtime_ops = fake.ops();
    {
        const h = try feedJson(&conn, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2,\"capabilities\":[\"runtime_metadata_v1\"]}");
        if (h.frame) |f| f.deinit(allocator);
    }
    {
        const frames = try feedExpectFrames(&conn, .request, 2, "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"observer\"}}");
        defer {
            for (frames) |f| f.deinit(allocator);
            allocator.free(frames);
        }
    }

    // cadence 전 네 tick은 metadata event가 없다(screen fake delta만 한 프레임).
    for (0..4) |_| {
        const frames = (try conn.collectDeltas()).?;
        defer {
            for (frames) |wire| allocator.free(wire);
            allocator.free(frames);
        }
        try testing.expectEqual(@as(usize, 1), frames.len);
    }

    fake.observation_version = 1;
    const changed = (try conn.collectDeltas()).?;
    defer {
        for (changed) |wire| allocator.free(wire);
        allocator.free(changed);
    }
    try testing.expectEqual(@as(usize, 2), changed.len); // metadata event + screen delta
    var parser = framing.FrameParser.init(allocator);
    defer parser.deinit();
    try parser.push(changed[0]);
    const event = (try parser.next()).?;
    defer event.deinit(allocator);
    try testing.expectEqual(protocol.Kind.event, event.header.kind);
    try testing.expectEqual(@as(u64, 1), event.header.stream_id);
    try testing.expect(std.mem.indexOf(u8, event.payload, "\"event\":\"runtime.metadata\"") != null);
    try testing.expect(std.mem.indexOf(u8, event.payload, "\"metadata_revision\":2") != null);
    try testing.expect(std.mem.indexOf(u8, event.payload, "\"cwd\":\"/tmp/project-next\"") != null);

    // 같은 full-state로 다음 cadence까지 가도 event를 반복하지 않는다.
    for (0..5) |_| {
        const frames = (try conn.collectDeltas()).?;
        defer {
            for (frames) |wire| allocator.free(wire);
            allocator.free(frames);
        }
        try testing.expectEqual(@as(usize, 1), frames.len);
    }
}

test "server: periodic metadata JSON escape expansion closes before event publication" {
    const allocator = testing.allocator;
    var registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer registry.deinit();
    _ = try registry.register(0xAA, 80, 24);
    var fake: FakeRuntimeOps = .{};
    var conn = Connection.init(allocator, 1, &registry);
    defer conn.deinit();
    conn.runtime_ops = fake.ops();
    {
        const hello = try feedJson(
            &conn,
            .hello,
            1,
            "{\"protocol_min\":2,\"protocol_max\":2,\"capabilities\":[\"runtime_metadata_v1\"]}",
        );
        if (hello.frame) |frame| frame.deinit(allocator);
        const frames = try feedExpectFrames(
            &conn,
            .request,
            2,
            "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"observer\"}}",
        );
        defer {
            for (frames) |frame| frame.deinit(allocator);
            allocator.free(frames);
        }
    }
    const before_revision = conn.attachments.get(1).?.observation_revision;
    fake.observation_invalid = .encoded_escape_expansion;
    conn.attachments.getPtr(1).?.observation_ticks = 5;
    try testing.expectEqual(
        @as(?CollectedOutput, null),
        try conn.collectOutputForLocalStream(1),
    );
    try testing.expectEqual(Connection.State.closed, conn.state);
    try testing.expectEqual(
        before_revision,
        conn.attachments.get(1).?.observation_revision,
    );
}

test "server: runtime metadata requires hello capability and fresh observation shares the event revision base" {
    const allocator = testing.allocator;
    var registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer registry.deinit();
    _ = try registry.register(0xAA, 80, 24);

    // 같은 MRSH v2의 구 client는 capability가 없으므로 알 수 없는 async event를 받지 않는다.
    var legacy_fake: FakeRuntimeOps = .{};
    var legacy = Connection.init(allocator, 1, &registry);
    defer legacy.deinit();
    legacy.runtime_ops = legacy_fake.ops();
    {
        const h = try feedJson(&legacy, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2}");
        if (h.frame) |f| f.deinit(allocator);
    }
    {
        const frames = try feedExpectFrames(&legacy, .request, 2, "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"observer\"}}");
        defer {
            for (frames) |f| f.deinit(allocator);
            allocator.free(frames);
        }
        try testing.expect(std.mem.indexOf(u8, frames[0].payload, "\"metadata_revision\"") == null);
        try testing.expect(std.mem.indexOf(u8, frames[0].payload, "\"metadata\"") == null);
    }
    legacy_fake.observation_version = 1;
    for (0..5) |_| {
        const frames = (try legacy.collectDeltas()).?;
        defer {
            for (frames) |wire| allocator.free(wire);
            allocator.free(frames);
        }
        try testing.expectEqual(@as(usize, 1), frames.len); // screen delta only, no unnegotiated event.
    }

    // 새 client의 on-demand barrier는 periodic event와 같은 base/revision을 전진시킨다.
    _ = try registry.register(0xBB, 80, 24);
    var fresh_fake: FakeRuntimeOps = .{};
    var fresh = Connection.init(allocator, 2, &registry);
    defer fresh.deinit();
    fresh.runtime_ops = fresh_fake.ops();
    {
        const h = try feedJson(&fresh, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2,\"capabilities\":[\"runtime_metadata_v1\"]}");
        if (h.frame) |f| f.deinit(allocator);
    }
    {
        const frames = try feedExpectFrames(&fresh, .request, 2, "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"bb\",\"mode\":\"observer\"}}");
        defer {
            for (frames) |f| f.deinit(allocator);
            allocator.free(frames);
        }
    }
    fresh_fake.observation_version = 1;
    const barrier = try feedJson(&fresh, .request, 3, "{\"method\":\"runtime.observation\",\"params\":{\"stream_id\":1}}");
    defer if (barrier.frame) |f| f.deinit(allocator);
    try testing.expect(std.mem.indexOf(u8, barrier.frame.?.payload, "\"metadata_revision\":2") != null);
    try testing.expect(std.mem.indexOf(u8, barrier.frame.?.payload, "\"cwd\":\"/tmp/project-next\"") != null);
    try testing.expectEqual(@as(u64, 2), fresh.attachments.get(1).?.observation_revision);
    for (0..5) |_| {
        const frames = (try fresh.collectDeltas()).?;
        defer {
            for (frames) |wire| allocator.free(wire);
            allocator.free(frames);
        }
        try testing.expectEqual(@as(usize, 1), frames.len); // barrier state와 같아 metadata event 중복 없음.
    }
}

test "server: metadata revision exhaustion closes without emit or base mutation and reattach restarts at one" {
    const allocator = testing.allocator;
    var registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer registry.deinit();
    _ = try registry.register(0xAA, 80, 24);
    _ = try registry.register(0xBB, 80, 24);

    var fake: FakeRuntimeOps = .{};
    var exhausted = Connection.init(allocator, 1, &registry);
    defer exhausted.deinit();
    exhausted.runtime_ops = fake.ops();
    {
        const hello = try feedJson(
            &exhausted,
            .hello,
            1,
            "{\"protocol_min\":2,\"protocol_max\":2,\"capabilities\":[\"runtime_metadata_v1\"]}",
        );
        defer if (hello.frame) |frame| frame.deinit(allocator);
    }
    {
        const frames = try feedExpectFrames(
            &exhausted,
            .request,
            2,
            "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"observer\"}}",
        );
        defer {
            for (frames) |frame| frame.deinit(allocator);
            allocator.free(frames);
        }
    }
    const sub = exhausted.attachments.getPtr(1).?;
    const old_token = sub.observation_token.?;
    sub.observation_revision = std.math.maxInt(u64);
    fake.observation_version = 1;
    sub.observation_ticks = 4;

    try testing.expect((try exhausted.collectOutputForLocalStream(1)) == null);
    try testing.expectEqual(Connection.State.closed, exhausted.state);
    try testing.expectEqual(std.math.maxInt(u64), sub.observation_revision);
    try testing.expectEqual(old_token, sub.observation_token.?);

    var fresh_fake: FakeRuntimeOps = .{};
    var fresh = Connection.init(allocator, 2, &registry);
    defer fresh.deinit();
    fresh.runtime_ops = fresh_fake.ops();
    {
        const hello = try feedJson(
            &fresh,
            .hello,
            1,
            "{\"protocol_min\":2,\"protocol_max\":2,\"capabilities\":[\"runtime_metadata_v1\"]}",
        );
        defer if (hello.frame) |frame| frame.deinit(allocator);
    }
    const frames = try feedExpectFrames(
        &fresh,
        .request,
        2,
        "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"bb\",\"mode\":\"observer\"}}",
    );
    defer {
        for (frames) |frame| frame.deinit(allocator);
        allocator.free(frames);
    }
    try testing.expect(std.mem.indexOf(u8, frames[0].payload, "\"metadata_revision\":1") != null);
    try testing.expectEqual(@as(u64, 1), fresh.attachments.get(1).?.observation_revision);
}

test "server: direct and prepared metadata barriers fail-close revision exhaustion before reply" {
    const AcceptBudget = struct {
        prepare_calls: usize = 0,
        rollback_calls: usize = 0,
        commit_calls: usize = 0,

        fn prepare(
            context: *anyopaque,
            _: subscription_identity.LocalStreamId,
            _: usize,
        ) ?connection_slot.BaseReservation {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.prepare_calls += 1;
            return .{
                .tracker = .{
                    .owner = .{ .monotonic_id = 1, .slot_generation = 1 },
                    .index = 0,
                    .generation = 1,
                },
                .generation = 1,
            };
        }
        fn commit(
            context: *anyopaque,
            _: connection_slot.BaseReservation,
            _: usize,
        ) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.commit_calls += 1;
        }
        fn rollback(context: *anyopaque, _: connection_slot.BaseReservation) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.rollback_calls += 1;
        }
        fn release(_: *anyopaque, _: subscription_identity.LocalStreamId) void {}
    };

    const allocator = testing.allocator;
    var registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer registry.deinit();
    _ = try registry.register(0xAA, 80, 24);
    _ = try registry.register(0xBB, 80, 24);

    var direct_fake: FakeRuntimeOps = .{};
    var direct = Connection.init(allocator, 1, &registry);
    defer direct.deinit();
    direct.runtime_ops = direct_fake.ops();
    {
        const hello = try feedJson(
            &direct,
            .hello,
            1,
            "{\"protocol_min\":2,\"protocol_max\":2,\"capabilities\":[\"runtime_metadata_v1\"]}",
        );
        defer if (hello.frame) |frame| frame.deinit(allocator);
        const frames = try feedExpectFrames(
            &direct,
            .request,
            2,
            "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"observer\"}}",
        );
        defer {
            for (frames) |frame| frame.deinit(allocator);
            allocator.free(frames);
        }
    }
    const direct_sub = direct.attachments.getPtr(1).?;
    const direct_token = direct_sub.observation_token.?;
    direct_sub.observation_revision = std.math.maxInt(u64);
    const unchanged = try feedJson(
        &direct,
        .request,
        3,
        "{\"method\":\"runtime.observation\",\"params\":{\"stream_id\":1}}",
    );
    defer if (unchanged.frame) |frame| frame.deinit(allocator);
    try testing.expectEqualStrings("reply", unchanged.action);
    try testing.expect(std.mem.indexOf(
        u8,
        unchanged.frame.?.payload,
        "\"metadata_revision\":18446744073709551615",
    ) != null);
    try testing.expectEqual(Connection.State.ready, direct.state);
    direct_fake.observation_version = 1;
    const direct_result = try feedJson(
        &direct,
        .request,
        4,
        "{\"method\":\"runtime.observation\",\"params\":{\"stream_id\":1}}",
    );
    try testing.expectEqualStrings("close", direct_result.action);
    try testing.expect(direct_result.frame == null);
    try testing.expectEqual(std.math.maxInt(u64), direct_sub.observation_revision);
    try testing.expectEqual(direct_token, direct_sub.observation_token.?);

    var prepared_fake: FakeRuntimeOps = .{};
    var prepared = Connection.init(allocator, 2, &registry);
    defer prepared.deinit();
    prepared.runtime_ops = prepared_fake.ops();
    {
        const hello = try feedJson(
            &prepared,
            .hello,
            1,
            "{\"protocol_min\":2,\"protocol_max\":2,\"capabilities\":[\"runtime_metadata_v1\"]}",
        );
        defer if (hello.frame) |frame| frame.deinit(allocator);
        const frames = try feedExpectFrames(
            &prepared,
            .request,
            2,
            "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"bb\",\"mode\":\"observer\"}}",
        );
        defer {
            for (frames) |frame| frame.deinit(allocator);
            allocator.free(frames);
        }
    }
    const prepared_sub = prepared.attachments.getPtr(1).?;
    const prepared_token = prepared_sub.observation_token.?;
    prepared_sub.observation_revision = std.math.maxInt(u64);
    prepared_fake.observation_version = 1;
    var budget: AcceptBudget = .{};
    prepared.projection_budget = .{
        .ctx = &budget,
        .prepare = AcceptBudget.prepare,
        .commit = AcceptBudget.commit,
        .rollback = AcceptBudget.rollback,
        .release = AcceptBudget.release,
    };
    const prepared_result = try feedJson(
        &prepared,
        .request,
        3,
        "{\"method\":\"runtime.observation\",\"params\":{\"stream_id\":1}}",
    );
    try testing.expectEqualStrings("close", prepared_result.action);
    try testing.expect(prepared_result.frame == null);
    try testing.expectEqual(@as(usize, 1), budget.prepare_calls);
    try testing.expectEqual(@as(usize, 1), budget.rollback_calls);
    try testing.expectEqual(@as(usize, 0), budget.commit_calls);
    try testing.expectEqual(std.math.maxInt(u64), prepared_sub.observation_revision);
    try testing.expectEqual(prepared_token, prepared_sub.observation_token.?);
}

test "server: 벨·OSC 52가 대기 중이면 관측 주기를 기다리지 않고 즉시 push한다" {
    const allocator = testing.allocator;
    var registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer registry.deinit();
    _ = try registry.register(0xCC, 80, 24);
    var fake: FakeRuntimeOps = .{};
    var conn = Connection.init(allocator, 1, &registry);
    defer conn.deinit();
    conn.runtime_ops = fake.ops();
    {
        const h = try feedJson(&conn, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2,\"capabilities\":[\"runtime_metadata_v1\"]}");
        if (h.frame) |f| f.deinit(allocator);
    }
    {
        const frames = try feedExpectFrames(&conn, .request, 2, "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"cc\",\"mode\":\"observer\"}}");
        defer {
            for (frames) |f| f.deinit(allocator);
            allocator.free(frames);
        }
    }

    // 기준선: attach 직후 첫 tick은 관측을 싣지 않는다(delta frame 1개뿐) — 주기(5 tick)가 아직 안 찼다.
    {
        const frames = (try conn.collectDeltas()).?;
        defer {
            for (frames) |wire| allocator.free(wire);
            allocator.free(frames);
        }
        try testing.expectEqual(@as(usize, 1), frames.len);
    }

    // 벨이 대기 중이면 같은 자리(2번째 tick)에서 관측 event가 함께 나간다 — 100ms를 기다리지 않는다.
    fake.observation_urgent = true;
    fake.observation_version = 1; // 관측 내용이 바뀌어야 "동일 state 미전송"에 걸리지 않는다
    {
        const frames = (try conn.collectDeltas()).?;
        defer {
            for (frames) |wire| allocator.free(wire);
            allocator.free(frames);
        }
        try testing.expectEqual(@as(usize, 2), frames.len);
        try testing.expect(std.mem.indexOf(u8, frames[0], "runtime.metadata") != null); // 관측 event가 screen delta보다 먼저 실린다
        try testing.expect(std.mem.indexOf(u8, frames[1], "DELTA-BYTES") != null);
    }
}

test "server: read-only host attach replies without a snapshot stream" {
    const allocator = testing.allocator;
    var registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer registry.deinit();
    _ = try registry.register(0xBB, 80, 24);
    var conn = Connection.init(allocator, 1, &registry); // runtime_ops = null (read-only host).
    defer conn.deinit();
    {
        const h = try feedJson(&conn, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2}");
        if (h.frame) |f| f.deinit(allocator);
    }
    // 실 runtime이 없으면 attach는 capability만 세우고 응답만 보낸다(.frames가 아니라 .reply — snapshot stream 없음).
    const r = try feedJson(&conn, .request, 2, "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"bb\",\"mode\":\"observer\"}}");
    defer if (r.frame) |f| f.deinit(allocator);
    try testing.expectEqualStrings("reply", r.action);
    try testing.expect(std.mem.indexOf(u8, r.frame.?.payload, "stream_id") != null);
}

test "server: collectDeltas pushes delta_chunk for attached streams and advances the base" {
    const allocator = testing.allocator;
    var registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer registry.deinit();
    _ = try registry.register(0xAA, 80, 24);

    var fake: FakeRuntimeOps = .{};
    var conn = Connection.init(allocator, 1, &registry);
    defer conn.deinit();
    conn.runtime_ops = fake.ops();
    {
        const h = try feedJson(&conn, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2}");
        if (h.frame) |f| f.deinit(allocator);
    }
    // attach → base가 fake snapshot("SNAPSHOT-BYTES")로 세팅된다.
    {
        const frames = try feedExpectFrames(&conn, .request, 2, "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"observer\"}}");
        defer {
            for (frames) |f| f.deinit(allocator);
            allocator.free(frames);
        }
    }
    // read-only host가 아니므로 collectDeltas가 stream을 diff한다. delta가 delta_chunk(end_stream)로 나온다.
    const maybe = try conn.collectDeltas();
    try testing.expect(maybe != null);
    const frames = maybe.?;
    defer {
        for (frames) |f| allocator.free(f);
        allocator.free(frames);
    }
    // fake.delta가 attach 때 세팅된 base("SNAPSHOT-BYTES")를 받았다.
    try testing.expectEqualStrings("SNAPSHOT-BYTES", fake.delta_base_seen[0..fake.delta_base_seen_len]);
    // 프레임을 파싱: delta_chunk(end_stream), stream_id 1, payload는 fake delta 바이트.
    try testing.expectEqual(@as(usize, 1), frames.len);
    {
        var rp = framing.FrameParser.init(allocator);
        defer rp.deinit();
        try rp.push(frames[0]);
        const f = (try rp.next()).?;
        defer f.deinit(allocator);
        try testing.expectEqual(protocol.Kind.delta_chunk, f.header.kind);
        try testing.expect(protocol.Flags.hasEndStream(f.header.flags));
        try testing.expectEqual(@as(u64, 1), f.header.stream_id);
        try testing.expectEqualStrings("DELTA-BYTES", f.payload);
    }
    // base가 새 값("NEW-BASE")으로 전진했다 — 다음 diff의 기준.
    try testing.expectEqualStrings("NEW-BASE", conn.attachments.get(1).?.base.?);

    // read-only host(runtime_ops=null)는 collectDeltas가 항상 null이다.
    var ro = Connection.init(allocator, 1, &registry);
    defer ro.deinit();
    try testing.expectEqual(@as(?[][]u8, null), try ro.collectDeltas());
}

test "server: delta rejects oversized new base independently and preserves old base" {
    const allocator = testing.allocator;
    var registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer registry.deinit();
    _ = try registry.register(0xAA, 80, 24);

    var fake: FakeRuntimeOps = .{ .new_base_len = protocol.max_viewport_snapshot };
    var conn = Connection.init(allocator, 1, &registry);
    defer conn.deinit();
    conn.runtime_ops = fake.ops();
    {
        const hello = try feedJson(
            &conn,
            .hello,
            1,
            "{\"protocol_min\":2,\"protocol_max\":2}",
        );
        defer if (hello.frame) |frame| frame.deinit(allocator);
    }
    {
        const frames = try feedExpectFrames(
            &conn,
            .request,
            2,
            "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"observer\"}}",
        );
        defer {
            for (frames) |frame| frame.deinit(allocator);
            allocator.free(frames);
        }
    }
    var exact = (try conn.collectOutputForLocalStream(1)).?;
    const exact_frames = exact.takeFrames();
    for (exact_frames) |frame| allocator.free(frame);
    allocator.free(exact_frames);
    exact.commit(&conn);
    try testing.expectEqual(
        protocol.max_viewport_snapshot,
        conn.attachments.get(1).?.base.?.len,
    );

    fake.new_base_len = protocol.max_viewport_snapshot + 1;
    try testing.expectError(error.OutOfMemory, conn.collectOutputForLocalStream(1));
    try testing.expectEqual(
        protocol.max_viewport_snapshot,
        conn.attachments.get(1).?.base.?.len,
    );
}

test "server: one-stream delta collection never materializes a sibling subscription" {
    const allocator = testing.allocator;
    var registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer registry.deinit();
    _ = try registry.register(0xAA, 80, 24);
    _ = try registry.register(0xBB, 80, 24);
    var fake: FakeRuntimeOps = .{};
    var conn = Connection.init(allocator, 1, &registry);
    defer conn.deinit();
    conn.runtime_ops = fake.ops();
    {
        const hello = try feedJson(
            &conn,
            .hello,
            1,
            "{\"protocol_min\":2,\"protocol_max\":2,\"capabilities\":[\"runtime_metadata_v1\"]}",
        );
        if (hello.frame) |frame| frame.deinit(allocator);
    }
    for ([_][]const u8{
        "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"observer\"}}",
        "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"bb\",\"mode\":\"observer\"}}",
    }, 0..) |request, index| {
        const batch = try feedExpectFrames(&conn, .request, index + 2, request);
        defer {
            for (batch) |frame| frame.deinit(allocator);
            allocator.free(batch);
        }
    }

    var output = (try conn.collectOutputForLocalStream(2)).?;
    const frames = output.takeFrames();
    defer {
        for (frames) |wire| allocator.free(wire);
        allocator.free(frames);
    }
    try testing.expectEqual(@as(usize, 1), frames.len);
    const class = try classifyOutbound(frames[0]);
    try testing.expectEqual(@as(u64, 2), class.subscription.stream);
    try testing.expectEqual(.delta, class.subscription.kind);
    try testing.expectEqualStrings("SNAPSHOT-BYTES", conn.attachments.get(1).?.base.?);
    // Prepared output has not changed the authoritative base before queue admission.
    try testing.expectEqualStrings("SNAPSHOT-BYTES", conn.attachments.get(2).?.base.?);
    output.commit(&conn);
    try testing.expectEqualStrings("NEW-BASE", conn.attachments.get(2).?.base.?);
}

test "server: missing runtime wins over resync retry and preserves sibling stream" {
    const allocator = testing.allocator;
    var registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer registry.deinit();
    _ = try registry.register(0xAA, 80, 24);
    _ = try registry.register(0xBB, 80, 24);
    var subscriptions = subscription_identity.Table.init(allocator);
    defer subscriptions.deinit();
    var fake: FakeRuntimeOps = .{};
    var conn = Connection.initProduct(
        allocator,
        1,
        &registry,
        .{ .monotonic_id = 7, .slot_generation = 1 },
        &subscriptions,
    );
    defer conn.deinit();
    conn.runtime_ops = fake.ops();
    {
        const hello = try feedJson(
            &conn,
            .hello,
            1,
            "{\"protocol_min\":2,\"protocol_max\":2,\"capabilities\":[\"runtime_metadata_v1\"]}",
        );
        if (hello.frame) |frame| frame.deinit(allocator);
    }
    for ([_][]const u8{
        "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"observer\"}}",
        "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"bb\",\"mode\":\"observer\"}}",
    }, 0..) |request, index| {
        const batch = try feedExpectFrames(&conn, .request, index + 2, request);
        defer {
            for (batch) |frame| frame.deinit(allocator);
            allocator.free(batch);
        }
    }
    conn.attachments.getPtr(1).?.resync_pending = true;
    conn.attachments.getPtr(1).?.observation_ticks = 5;
    registry.unregister(0xAA);
    fake.snapshot_missing = true;

    try testing.expectEqual(@as(?CollectedOutput, null), try conn.collectOutputForLocalStream(1));
    try testing.expect(!conn.hasLocalStream(1));
    try testing.expect(conn.hasLocalStream(2));
    try testing.expectEqual(@as(usize, 1), conn.attachmentCount());
    try testing.expectEqual(@as(usize, 1), subscriptions.count());
    // A concurrent connection close after ended convergence is an idempotent no-op for stream 1.
}

test "server: metadata RuntimeNotFound ends the stream before screen production" {
    const allocator = testing.allocator;
    var registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer registry.deinit();
    _ = try registry.register(0xAA, 80, 24);
    var fake: FakeRuntimeOps = .{};
    var conn = Connection.init(allocator, 1, &registry);
    defer conn.deinit();
    conn.runtime_ops = fake.ops();
    {
        const hello = try feedJson(
            &conn,
            .hello,
            1,
            "{\"protocol_min\":2,\"protocol_max\":2,\"capabilities\":[\"runtime_metadata_v1\"]}",
        );
        if (hello.frame) |frame| frame.deinit(allocator);
        const batch = try feedExpectFrames(
            &conn,
            .request,
            2,
            "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"observer\"}}",
        );
        defer {
            for (batch) |frame| frame.deinit(allocator);
            allocator.free(batch);
        }
    }
    conn.attachments.getPtr(1).?.observation_ticks = 5;
    registry.unregister(0xAA);
    fake.runtime_missing = true;

    try testing.expectEqual(@as(?CollectedOutput, null), try conn.collectOutputForLocalStream(1));
    try testing.expectEqual(@as(usize, 0), conn.attachmentCount());
    try testing.expectEqual(@as(usize, 0), registry.attachmentCount());
}

test "server: RuntimeNotFound cannot override live registry SSOT" {
    const allocator = testing.allocator;
    var registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer registry.deinit();
    _ = try registry.register(0xAA, 80, 24);
    var fake: FakeRuntimeOps = .{ .delta_missing = true };
    var conn = Connection.init(allocator, 1, &registry);
    defer conn.deinit();
    conn.runtime_ops = fake.ops();
    {
        const hello = try feedJson(&conn, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2}");
        if (hello.frame) |frame| frame.deinit(allocator);
        const batch = try feedExpectFrames(
            &conn,
            .request,
            2,
            "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"observer\"}}",
        );
        defer {
            for (batch) |frame| frame.deinit(allocator);
            allocator.free(batch);
        }
    }

    try testing.expectError(error.OutOfMemory, conn.collectOutputForLocalStream(1));
    try testing.expect(conn.hasLocalStream(1));
    registry.unregister(0xAA);
    try testing.expectEqual(@as(?CollectedOutput, null), try conn.collectOutputForLocalStream(1));
    try testing.expect(!conn.hasLocalStream(1));
    conn.convergeEndedStream(1);
    try testing.expectEqual(@as(usize, 0), conn.attachmentCount());
}

test "server: runtime ended event requires explicit hello capability" {
    const allocator = testing.allocator;
    var registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer registry.deinit();
    var legacy = Connection.init(allocator, 1, &registry);
    defer legacy.deinit();
    const legacy_hello = try feedJson(
        &legacy,
        .hello,
        1,
        "{\"protocol_min\":2,\"protocol_max\":2}",
    );
    if (legacy_hello.frame) |frame| frame.deinit(allocator);
    try testing.expect(!legacy.supportsRuntimeEnded());

    var current = Connection.init(allocator, 1, &registry);
    defer current.deinit();
    const current_hello = try feedJson(
        &current,
        .hello,
        1,
        "{\"protocol_min\":2,\"protocol_max\":2,\"capabilities\":[\"runtime_ended_v1\"]}",
    );
    if (current_hello.frame) |frame| frame.deinit(allocator);
    try testing.expect(current.supportsRuntimeEnded());
}

test "server: stream event is subscription output while invalidation notice is explicit control" {
    const allocator = testing.allocator;
    const metadata = try framing.encodeFrame(
        allocator,
        .{ .kind = .event, .stream_id = 7 },
        "{\"event\":\"runtime.metadata\"}",
    );
    defer allocator.free(metadata);
    const class = try classifyOutbound(metadata);
    try testing.expectEqual(@as(u64, 7), class.subscription.stream);
    try testing.expectEqual(.event, class.subscription.kind);

    var registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer registry.deinit();
    var conn = Connection.init(allocator, 1, &registry);
    defer conn.deinit();
    const notice = try conn.snapshotInvalidatedFrame(7);
    defer allocator.free(notice);
    // The adapter intentionally uses adoptControl for this frame; generic classification remains
    // subscription-scoped so no other stream event can consume the shared control reserve.
    try testing.expectEqual(@as(u64, 7), (try classifyOutbound(notice)).subscription.stream);
}

test "server: output rollback preserves base and resync intent until queue admission commits" {
    const allocator = testing.allocator;
    var registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer registry.deinit();
    _ = try registry.register(0xAA, 80, 24);
    var fake: FakeRuntimeOps = .{};
    var conn = Connection.init(allocator, 1, &registry);
    defer conn.deinit();
    conn.runtime_ops = fake.ops();
    {
        const hello = try feedJson(&conn, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2}");
        if (hello.frame) |frame| frame.deinit(allocator);
        const batch = try feedExpectFrames(
            &conn,
            .request,
            2,
            "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"observer\"}}",
        );
        defer {
            for (batch) |frame| frame.deinit(allocator);
            allocator.free(batch);
        }
    }
    try testing.expectEqualStrings("SNAPSHOT-BYTES", conn.attachments.get(1).?.base.?);
    conn.markSubscriptionOutputInvalidated(1);
    try testing.expectEqual(@as(?[]u8, null), conn.attachments.get(1).?.base);
    {
        var unknown = framing.Frame{
            .header = .{ .kind = .stream_ack, .stream_id = 99 },
            .payload = try allocator.dupe(u8, "{\"action\":\"resync\"}"),
        };
        defer unknown.deinit(allocator);
        try testing.expect((try conn.handleFrame(unknown)) == .none);
        try testing.expect(conn.attachments.get(1).?.awaiting_resync_ack);
        try testing.expect(!conn.attachments.get(1).?.resync_pending);
    }
    {
        var ack_frame = framing.Frame{
            .header = .{ .kind = .stream_ack, .stream_id = 1 },
            .payload = try allocator.dupe(u8, "{\"action\":\"resync\"}"),
        };
        defer ack_frame.deinit(allocator);
        const action = try conn.handleFrame(ack_frame);
        try testing.expect(action == .resync_ack);
    }
    for (0..8) |_| {
        var duplicate = framing.Frame{
            .header = .{ .kind = .stream_ack, .stream_id = 1 },
            .payload = try allocator.dupe(u8, "{\"action\":\"resync\"}"),
        };
        defer duplicate.deinit(allocator);
        try testing.expect((try conn.handleFrame(duplicate)) == .none);
    }
    var rejected = (try conn.collectOutputForLocalStream(1)).?;
    const rejected_frames = rejected.takeFrames();
    for (rejected_frames) |frame| allocator.free(frame);
    allocator.free(rejected_frames);
    rejected.rollback(&conn);
    try testing.expect(conn.attachments.get(1).?.resync_pending);
    try testing.expectEqual(@as(?[]u8, null), conn.attachments.get(1).?.base);

    var accepted = (try conn.collectOutputForLocalStream(1)).?;
    const accepted_frames = accepted.takeFrames();
    for (accepted_frames) |frame| allocator.free(frame);
    allocator.free(accepted_frames);
    accepted.commit(&conn);
    try testing.expect(!conn.attachments.get(1).?.resync_pending);
    try testing.expectEqualStrings("SNAPSHOT-BYTES", conn.attachments.get(1).?.base.?);
}

test "server: malformed resync acknowledgements fail close without granting recovery" {
    const allocator = testing.allocator;
    const malformed = [_]struct {
        request_id: u64 = 0,
        flags: u32 = 0,
        payload: []const u8 = "{\"action\":\"resync\"}",
    }{
        .{ .request_id = 1 },
        .{ .flags = 1 },
        .{ .payload = "{\"action\":\"other\"}" },
    };
    for (malformed) |case| {
        var registry = reg.TerminalRuntimeRegistry.init(allocator);
        defer registry.deinit();
        _ = try registry.register(0xAA, 80, 24);
        var fake: FakeRuntimeOps = .{};
        var conn = Connection.init(allocator, 1, &registry);
        defer conn.deinit();
        conn.runtime_ops = fake.ops();
        const hello = try feedJson(
            &conn,
            .hello,
            1,
            "{\"protocol_min\":2,\"protocol_max\":2}",
        );
        if (hello.frame) |frame| frame.deinit(allocator);
        const batch = try feedExpectFrames(
            &conn,
            .request,
            2,
            "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"observer\"}}",
        );
        defer {
            for (batch) |frame| frame.deinit(allocator);
            allocator.free(batch);
        }
        conn.markSubscriptionOutputInvalidated(1);
        var frame = framing.Frame{
            .header = .{
                .kind = .stream_ack,
                .request_id = case.request_id,
                .stream_id = 1,
                .flags = case.flags,
            },
            .payload = try allocator.dupe(u8, case.payload),
        };
        defer frame.deinit(allocator);
        try testing.expect((try conn.handleFrame(frame)) == .close);
        try testing.expect(conn.attachments.get(1).?.awaiting_resync_ack);
        try testing.expect(!conn.attachments.get(1).?.resync_pending);
    }
}

test "server: metadata recovery allocation failures release canonical prefix ownership" {
    const allocator = testing.allocator;
    for (0..48) |fail_index| {
        var registry = reg.TerminalRuntimeRegistry.init(allocator);
        defer registry.deinit();
        _ = try registry.register(0xAA, 80, 24);
        var fake: FakeRuntimeOps = .{};
        var conn = Connection.init(allocator, 1, &registry);
        defer conn.deinit();
        conn.runtime_ops = fake.ops();
        const hello = try feedJson(
            &conn,
            .hello,
            1,
            "{\"protocol_min\":2,\"protocol_max\":2,\"capabilities\":[\"runtime_metadata_v1\"]}",
        );
        if (hello.frame) |frame| frame.deinit(allocator);
        const batch = try feedExpectFrames(
            &conn,
            .request,
            2,
            "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"observer\"}}",
        );
        defer {
            for (batch) |frame| frame.deinit(allocator);
            allocator.free(batch);
        }
        conn.markSubscriptionOutputInvalidated(1);
        conn.attachments.getPtr(1).?.resync_pending = true;

        var failing = testing.FailingAllocator.init(
            allocator,
            .{ .fail_index = fail_index },
        );
        conn.allocator = failing.allocator();
        const maybe_output = conn.collectOutputForLocalStream(1) catch |err| blk: {
            try testing.expectEqual(error.OutOfMemory, err);
            break :blk null;
        };
        if (maybe_output) |value| {
            var output = value;
            output.rollback(&conn);
        }
        conn.allocator = allocator;
    }
}

test "server: failed resync attempt keeps metadata prefix due for the retry" {
    const allocator = testing.allocator;
    var registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer registry.deinit();
    _ = try registry.register(0xAA, 80, 24);
    var fake: FakeRuntimeOps = .{};
    var conn = Connection.init(allocator, 1, &registry);
    defer conn.deinit();
    conn.runtime_ops = fake.ops();
    {
        const hello = try feedJson(
            &conn,
            .hello,
            1,
            "{\"protocol_min\":2,\"protocol_max\":2,\"capabilities\":[\"runtime_metadata_v1\"]}",
        );
        if (hello.frame) |frame| frame.deinit(allocator);
        const batch = try feedExpectFrames(
            &conn,
            .request,
            2,
            "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"observer\"}}",
        );
        defer {
            for (batch) |frame| frame.deinit(allocator);
            allocator.free(batch);
        }
    }
    conn.markSubscriptionOutputInvalidated(1);
    var ack = framing.Frame{
        .header = .{ .kind = .stream_ack, .stream_id = 1 },
        .payload = try allocator.dupe(u8, "{\"action\":\"resync\"}"),
    };
    defer ack.deinit(allocator);
    try testing.expect((try conn.handleFrame(ack)) == .resync_ack);

    fake.observation_fail_count = 1;
    fake.snapshot_fail_count = 1;
    try testing.expectEqual(@as(?CollectedOutput, null), try conn.collectOutputForLocalStream(1));
    try testing.expectEqual(@as(u8, 5), conn.attachments.get(1).?.observation_ticks);
    try testing.expectEqual(@as(?CollectedOutput, null), try conn.collectOutputForLocalStream(1));
    try testing.expectEqual(@as(u8, 5), conn.attachments.get(1).?.observation_ticks);

    var retry = (try conn.collectOutputForLocalStream(1)).?;
    defer if (!retry.finished) retry.rollback(&conn);
    const frames = retry.takeFrames();
    defer {
        for (frames) |frame| allocator.free(frame);
        allocator.free(frames);
    }
    try testing.expectEqual(.event, (try classifyOutbound(frames[0])).subscription.kind);
    try testing.expectEqual(.snapshot, (try classifyOutbound(frames[1])).subscription.kind);
    retry.rollback(&conn);
    fake.snapshot_permanent_failure = true;
    try testing.expectError(
        error.OutOfMemory,
        conn.collectOutputForLocalStream(1),
    );
}

test "server: runtime.resync makes collectDeltas push a fresh snapshot_chunk, not a delta (§9 desync 복구)" {
    const allocator = testing.allocator;
    var registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer registry.deinit();
    _ = try registry.register(0xAA, 80, 24);

    var fake: FakeRuntimeOps = .{};
    var conn = Connection.init(allocator, 1, &registry);
    defer conn.deinit();
    conn.runtime_ops = fake.ops();
    {
        const h = try feedJson(&conn, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2}");
        if (h.frame) |f| f.deinit(allocator);
    }
    // attach(controller) → base = fake snapshot("SNAPSHOT-BYTES"), stream_id 1.
    {
        const frames = try feedExpectFrames(&conn, .request, 2, "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"controller\"}}");
        defer {
            for (frames) |f| f.deinit(allocator);
            allocator.free(frames);
        }
    }
    // resync 요청 → {resync:true} 응답 + resync_pending 세팅.
    {
        const r = try feedJson(&conn, .request, 3, "{\"method\":\"runtime.resync\",\"params\":{\"stream_id\":1}}");
        defer if (r.frame) |f| f.deinit(allocator);
        try testing.expectEqual(protocol.Kind.response, r.frame.?.header.kind);
        try testing.expect(std.mem.indexOf(u8, r.frame.?.payload, "\"resync\":true") != null);
    }
    try testing.expect(conn.attachments.get(1).?.resync_pending);

    // collectDeltas → delta가 **아니라** snapshot_chunk를 push한다(fresh snapshot으로 client generation 리셋). 이게 없으면
    // desync한 client가 계속 GenerationGap이라 영구 멈춘다(code-review #7).
    const maybe = try conn.collectDeltas();
    try testing.expect(maybe != null);
    const frames = maybe.?;
    defer {
        for (frames) |f| allocator.free(f);
        allocator.free(frames);
    }
    try testing.expectEqual(@as(usize, 1), frames.len);
    {
        var rp = framing.FrameParser.init(allocator);
        defer rp.deinit();
        try rp.push(frames[0]);
        const f = (try rp.next()).?;
        defer f.deinit(allocator);
        try testing.expectEqual(protocol.Kind.snapshot_chunk, f.header.kind); // delta_chunk 아님!
        try testing.expect(protocol.Flags.hasEndStream(f.header.flags));
        try testing.expectEqual(@as(u64, 1), f.header.stream_id);
        try testing.expectEqualStrings("SNAPSHOT-BYTES", f.payload); // fake snapshot 그대로
    }
    try testing.expect(!conn.attachments.get(1).?.resync_pending); // 한 번 소비(다음 tick부턴 다시 delta).
    try testing.expectEqualStrings("SNAPSHOT-BYTES", conn.attachments.get(1).?.base.?); // base = 그 snapshot(다음 diff 기준).

    // 다음 collectDeltas는 다시 delta(resync 소비됨).
    {
        const m2 = try conn.collectDeltas();
        try testing.expect(m2 != null);
        const f2 = m2.?;
        defer {
            for (f2) |f| allocator.free(f);
            allocator.free(f2);
        }
        var rp = framing.FrameParser.init(allocator);
        defer rp.deinit();
        try rp.push(f2[0]);
        const f = (try rp.next()).?;
        defer f.deinit(allocator);
        try testing.expectEqual(protocol.Kind.delta_chunk, f.header.kind); // resync 소비 → 일반 delta 복귀
    }

    // 모르는 stream_id resync → invalid_request(runtime 유지).
    {
        const r = try feedJson(&conn, .request, 4, "{\"method\":\"runtime.resync\",\"params\":{\"stream_id\":99}}");
        defer if (r.frame) |f| f.deinit(allocator);
        try testing.expect(std.mem.indexOf(u8, r.frame.?.payload, "invalid_request") != null);
    }
}

test "server: product connections isolate same local stream through global subscription authority" {
    const allocator = testing.allocator;
    var registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer registry.deinit();
    _ = try registry.register(0xAA, 80, 24);
    var identities = subscription_identity.Table.init(allocator);
    defer identities.deinit();
    var fake: FakeRuntimeOps = .{};

    var controller = Connection.initProduct(
        allocator,
        1,
        &registry,
        .{ .monotonic_id = 1, .slot_generation = 1 },
        &identities,
    );
    var observer = Connection.initProduct(
        allocator,
        1,
        &registry,
        .{ .monotonic_id = 2, .slot_generation = 1 },
        &identities,
    );
    controller.runtime_ops = fake.ops();
    observer.runtime_ops = fake.ops();
    inline for (&.{ &controller, &observer }) |conn| {
        const hello = try feedJson(conn, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2}");
        if (hello.frame) |frame| frame.deinit(allocator);
        const frames = try feedExpectFrames(
            conn,
            .request,
            2,
            "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"controller\"}}",
        );
        defer {
            for (frames) |frame| frame.deinit(allocator);
            allocator.free(frames);
        }
    }

    try testing.expect(controller.attachments.contains(1));
    try testing.expect(observer.attachments.contains(1));
    const controller_sub = controller.attachments.get(1).?.subscription_id;
    const observer_sub = observer.attachments.get(1).?.subscription_id;
    try testing.expect(!std.meta.eql(controller_sub, observer_sub));
    try testing.expect(reg.Capability.has(
        registry.capabilitiesOfSubscription(0xAA, controller_sub),
        reg.Capability.input,
    ));
    try testing.expect(!reg.Capability.has(
        registry.capabilitiesOfSubscription(0xAA, observer_sub),
        reg.Capability.input,
    ));

    const input = try feedStream(&observer, .input_bytes, 1, "blocked");
    try testing.expectEqualStrings("none", input.action);
    try testing.expectEqual(@as(usize, 0), fake.last_input_len);
    const resize = try feedJson(
        &observer,
        .request,
        3,
        "{\"method\":\"runtime.resize\",\"params\":{\"stream_id\":1,\"cols\":90,\"rows\":30,\"client_sequence\":1}}",
    );
    defer if (resize.frame) |frame| frame.deinit(allocator);
    try testing.expect(std.mem.indexOf(u8, resize.frame.?.payload, "unauthorized") != null);
    const mouse = try feedJson(
        &observer,
        .request,
        4,
        "{\"method\":\"runtime.report_mouse\",\"params\":{\"stream_id\":1,\"button\":0,\"col\":1,\"row\":1,\"pressed\":true}}",
    );
    defer if (mouse.frame) |frame| frame.deinit(allocator);
    try testing.expect(std.mem.indexOf(u8, mouse.frame.?.payload, "unauthorized") != null);
    try testing.expect(fake.last_mouse_report == null);

    // observer는 자기 projection의 viewport span 복사만 가능하다. host 권위 선택/전체 scrollback과
    // 선택 mutation은 controller input capability 없이는 읽거나 바꿀 수 없다.
    {
        const response = try feedJson(&observer, .request, 5, "{\"method\":\"runtime.selected_text\",\"params\":{\"stream_id\":1,\"sr\":0,\"sc\":0,\"er\":0,\"ec\":1,\"block\":false}}");
        defer if (response.frame) |frame| frame.deinit(allocator);
        try testing.expect(std.mem.indexOf(u8, response.frame.?.payload, "PICKED") != null);
    }
    inline for (.{
        "{\"method\":\"runtime.selected_text\",\"params\":{\"stream_id\":1,\"sr\":0,\"sc\":0,\"er\":0,\"ec\":1,\"block\":false,\"all\":true}}",
        "{\"method\":\"runtime.selected_text\",\"params\":{\"stream_id\":1,\"sr\":0,\"sc\":0,\"er\":0,\"ec\":1,\"block\":false,\"authoritative\":true}}",
        "{\"method\":\"runtime.select_op\",\"params\":{\"stream_id\":1,\"op\":\"all\"}}",
    }, 6..) |payload, request_id| {
        const response = try feedJson(&observer, .request, request_id, payload);
        defer if (response.frame) |frame| frame.deinit(allocator);
        try testing.expect(std.mem.indexOf(u8, response.frame.?.payload, "unauthorized") != null);
    }

    observer.deinit();
    try testing.expectEqual(@as(usize, 1), identities.count());
    try testing.expect(reg.Capability.has(
        registry.capabilitiesOfSubscription(0xAA, controller_sub),
        reg.Capability.input,
    ));
    controller.deinit();
    try testing.expectEqual(@as(usize, 0), identities.count());
}

test "server: controller transition action build OOM never publishes authority" {
    const allocator = testing.allocator;
    inline for (.{ reg.ControllerTransitionKind.takeover, .release }) |kind| {
        var saw_oom = false;
        var saw_success = false;
        var fail_index: usize = 0;
        while (fail_index < 48) : (fail_index += 1) {
            var registry = reg.TerminalRuntimeRegistry.init(allocator);
            defer registry.deinit();
            _ = try registry.register(0xAA, 80, 24);
            var identities = subscription_identity.Table.init(allocator);
            defer identities.deinit();
            var fake: FakeRuntimeOps = .{};
            var controller = Connection.initProduct(
                allocator,
                1,
                &registry,
                .{ .monotonic_id = 1, .slot_generation = 1 },
                &identities,
            );
            defer controller.deinit();
            var observer = Connection.initProduct(
                allocator,
                1,
                &registry,
                .{ .monotonic_id = 2, .slot_generation = 1 },
                &identities,
            );
            defer observer.deinit();
            controller.runtime_ops = fake.ops();
            observer.runtime_ops = fake.ops();
            inline for (&.{ &controller, &observer }) |conn| {
                const hello = try feedJson(
                    conn,
                    .hello,
                    1,
                    "{\"protocol_min\":2,\"protocol_max\":2}",
                );
                if (hello.frame) |frame| frame.deinit(allocator);
            }
            const controller_frames = try feedExpectFrames(
                &controller,
                .request,
                2,
                "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"controller\"}}",
            );
            for (controller_frames) |frame| frame.deinit(allocator);
            allocator.free(controller_frames);
            const observer_frames = try feedExpectFrames(
                &observer,
                .request,
                2,
                "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"observer\"}}",
            );
            for (observer_frames) |frame| frame.deinit(allocator);
            allocator.free(observer_frames);
            controller.controller_transfer_v1 = true;
            observer.controller_transfer_v1 = true;
            const controller_subscription = controller.attachments.get(1).?.subscription_id;
            const observer_subscription = observer.attachments.get(1).?.subscription_id;

            var params: std.json.ObjectMap = .empty;
            defer params.deinit(allocator);
            try params.put(allocator, "stream_id", .{ .integer = 1 });
            try params.put(
                allocator,
                "expected_controller_generation",
                .{ .integer = 1 },
            );
            var failing = testing.FailingAllocator.init(
                allocator,
                .{ .fail_index = fail_index },
            );
            const failing_allocator = failing.allocator();
            const subject = if (kind == .takeover) &observer else &controller;
            subject.allocator = failing_allocator;
            registry.allocator = failing_allocator;
            const result = subject.dispatchControllerTransition(
                3,
                params,
                kind,
            );
            if (result) |action| {
                saw_success = true;
                var transition = switch (action) {
                    .controller_transition_requested => |value| value,
                    else => return error.TestUnexpectedResult,
                };
                failing_allocator.free(transition.success_reply);
                failing_allocator.free(transition.stale_reply);
                failing_allocator.free(transition.exhausted_reply);
                if (transition.revocation) |revocation|
                    failing_allocator.free(revocation.frame);
                registry.discardControllerTransition(&transition.prepared);
            } else |err| {
                saw_oom = true;
                try testing.expectEqual(error.OutOfMemory, err);
            }
            subject.allocator = allocator;
            registry.allocator = allocator;
            try testing.expectEqual(@as(u64, 1), registry.get(0xAA).?.controller_generation);
            try testing.expectEqual(
                controller_subscription.value,
                registry.get(0xAA).?.controller.?,
            );
            try testing.expect(reg.Capability.has(
                registry.capabilitiesOfSubscription(0xAA, controller_subscription),
                reg.Capability.input,
            ));
            try testing.expectEqual(
                reg.Capability.observe,
                registry.capabilitiesOfSubscription(0xAA, observer_subscription),
            );
            if (saw_success) break;
        }
        try testing.expect(saw_oom);
        try testing.expect(saw_success);
    }
}

test "server: runtime.core_command validates and routes bounded commands to controller RuntimeOps" {
    const allocator = testing.allocator;
    var registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer registry.deinit();
    _ = try registry.register(0xAA, 80, 24);
    _ = try registry.register(0xBB, 80, 24);

    var fake: FakeRuntimeOps = .{};
    var conn = Connection.init(allocator, 1, &registry);
    defer conn.deinit();
    conn.runtime_ops = fake.ops();
    {
        const h = try feedJson(&conn, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2}");
        if (h.frame) |f| f.deinit(allocator);
    }
    {
        const frames = try feedExpectFrames(&conn, .request, 2, "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"controller\"}}");
        defer {
            for (frames) |f| f.deinit(allocator);
            allocator.free(frames);
        }
    }
    // scroll up 5 → op="scroll", arg=5, runtime=0xAA로 라우팅.
    {
        const r = try feedJson(&conn, .request, 3, "{\"method\":\"runtime.core_command\",\"params\":{\"stream_id\":1,\"op\":\"scroll\",\"arg\":5}}");
        defer if (r.frame) |f| f.deinit(allocator);
        try testing.expect(std.mem.indexOf(u8, r.frame.?.payload, "\"applied\":true") != null);
    }
    try testing.expectEqualDeep(core_command_wire.Command{ .scroll = 5 }, fake.last_core_command.?);
    try testing.expectEqual(@as(u128, 0xAA), fake.core_command_runtime);

    // 음수 delta(scroll down)도 그대로 전달된다(signed arg).
    {
        const r = try feedJson(&conn, .request, 4, "{\"method\":\"runtime.core_command\",\"params\":{\"stream_id\":1,\"op\":\"scroll\",\"arg\":-3}}");
        defer if (r.frame) |f| f.deinit(allocator);
    }
    try testing.expectEqualDeep(core_command_wire.Command{ .scroll = -3 }, fake.last_core_command.?);

    // focus/config처럼 구 handler가 조용히 버리던 명령도 같은 typed seam으로 들어간다.
    {
        const r = try feedJson(&conn, .request, 5, "{\"method\":\"runtime.core_command\",\"params\":{\"stream_id\":1,\"op\":\"report_focus\",\"gained\":true}}");
        defer if (r.frame) |f| f.deinit(allocator);
    }
    try testing.expectEqualDeep(core_command_wire.Command{ .report_focus = true }, fake.last_core_command.?);

    // malformed palette는 부분 적용 없이 invalid_request.
    {
        const r = try feedJson(&conn, .request, 6, "{\"method\":\"runtime.core_command\",\"params\":{\"stream_id\":1,\"op\":\"set_config_palette\",\"palette\":[1]}}");
        defer if (r.frame) |f| f.deinit(allocator);
        try testing.expect(std.mem.indexOf(u8, r.frame.?.payload, "invalid_request") != null);
    }

    // 모르는 stream_id → invalid_request(라우팅 안 함).
    {
        const r = try feedJson(&conn, .request, 7, "{\"method\":\"runtime.core_command\",\"params\":{\"stream_id\":99,\"op\":\"scroll\",\"arg\":1}}");
        defer if (r.frame) |f| f.deinit(allocator);
        try testing.expect(std.mem.indexOf(u8, r.frame.?.payload, "invalid_request") != null);
    }

    // 현재 GUI hot path는 응답 없는 core_command stream frame을 쓴다. header/payload stream이 같은 controller면
    // RPC reply 없이 같은 typed seam으로 라우팅된다.
    {
        const r = try feedStream(&conn, .core_command, 1, "{\"stream_id\":1,\"op\":\"report_focus\",\"gained\":false}");
        defer if (r.frame) |f| f.deinit(allocator);
        try testing.expectEqualStrings("none", r.action);
    }
    try testing.expectEqualDeep(core_command_wire.Command{ .report_focus = false }, fake.last_core_command.?);

    // fire-and-forget frame을 host reader queue에 admission하지 못하면 성공처럼 유지하지 않고 connection을 닫는다.
    // ACK가 없어 client가 이 command만 안전하게 재전송할 수 없기 때문이다.
    fake.core_command_failure = true;
    {
        const r = try feedStream(&conn, .core_command, 1, "{\"stream_id\":1,\"op\":\"report_focus\",\"gained\":true}");
        defer if (r.frame) |f| f.deinit(allocator);
        try testing.expectEqualStrings("close", r.action);
    }
    fake.core_command_failure = false;

    // observer attachment는 같은 runtime을 보더라도 focus/config/viewport를 바꿀 input capability가 없다.
    var observer = Connection.init(allocator, 2, &registry);
    defer observer.deinit();
    observer.runtime_ops = fake.ops();
    {
        const h = try feedJson(&observer, .hello, 8, "{\"protocol_min\":2,\"protocol_max\":2}");
        if (h.frame) |f| f.deinit(allocator);
    }
    {
        const frames = try feedExpectFrames(&observer, .request, 9, "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"bb\",\"mode\":\"observer\"}}");
        defer {
            for (frames) |f| f.deinit(allocator);
            allocator.free(frames);
        }
    }
    {
        const r = try feedJson(&observer, .request, 10, "{\"method\":\"runtime.core_command\",\"params\":{\"stream_id\":1,\"op\":\"report_focus\",\"gained\":false}}");
        defer if (r.frame) |f| f.deinit(allocator);
        try testing.expect(std.mem.indexOf(u8, r.frame.?.payload, "unauthorized") != null);
    }
    try testing.expectEqualDeep(core_command_wire.Command{ .report_focus = false }, fake.last_core_command.?);
}

test "server: runtime.report_mouse routes the mouse event to RuntimeOps (§host-backed 마우스 리포팅)" {
    const allocator = testing.allocator;
    var registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer registry.deinit();
    _ = try registry.register(0xBB, 80, 24);

    var fake: FakeRuntimeOps = .{};
    var conn = Connection.init(allocator, 1, &registry);
    defer conn.deinit();
    conn.runtime_ops = fake.ops();
    {
        const h = try feedJson(&conn, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2}");
        if (h.frame) |f| f.deinit(allocator);
    }
    {
        const frames = try feedExpectFrames(&conn, .request, 2, "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"bb\",\"mode\":\"controller\"}}");
        defer {
            for (frames) |f| f.deinit(allocator);
            allocator.free(frames);
        }
    }
    // 휠-up 리포트(button 64)를 그대로 host로 라우팅한다 — host가 자기 mouse_tracking/format으로 인코딩·PTY 주입.
    {
        const r = try feedJson(&conn, .request, 3, "{\"method\":\"runtime.report_mouse\",\"params\":{\"stream_id\":1,\"button\":64,\"col\":10,\"row\":5,\"x_px\":80,\"y_px\":40,\"pressed\":true,\"motion\":false,\"mods\":0}}");
        defer if (r.frame) |f| f.deinit(allocator);
        try testing.expect(std.mem.indexOf(u8, r.frame.?.payload, "\"applied\":true") != null);
    }
    try testing.expect(fake.last_mouse_report != null);
    const m = fake.last_mouse_report.?;
    try testing.expectEqual(@as(u8, 64), m.button);
    try testing.expectEqual(@as(u16, 10), m.col);
    try testing.expectEqual(@as(u16, 5), m.row);
    try testing.expect(m.pressed and !m.motion);
    try testing.expectEqual(@as(u128, 0xBB), fake.core_command_runtime);

    // 모르는 stream_id → invalid_request(라우팅 안 함).
    {
        const r = try feedJson(&conn, .request, 4, "{\"method\":\"runtime.report_mouse\",\"params\":{\"stream_id\":99,\"button\":0,\"col\":0,\"row\":0,\"x_px\":0,\"y_px\":0,\"pressed\":true,\"motion\":false,\"mods\":0}}");
        defer if (r.frame) |f| f.deinit(allocator);
        try testing.expect(std.mem.indexOf(u8, r.frame.?.payload, "invalid_request") != null);
    }
}

// 원격 Cmd+클릭 링크 열기는 host가 판정한다(client core는 빈 placeholder이고, file_path 존재 검증은 host FS에서
// 해야 정확하다). server가 (row,col,scopes)를 RuntimeOps로 그대로 라우팅하고 host 응답을 돌려주는지 고정한다 —
// scopes가 유실되면 client의 link-detection 설정이 무시돼 "밑줄은 뜨는데 안 열리는"(또는 그 반대) 불일치가 난다.
// clipboard_write는 host 상태를 **소비**하는 RPC라 observer 모드가 controller의 클립보드를 가로채면 안 된다.
// 라우팅과 권한 게이트를 함께 고정한다 — 이 경로는 이번 슬라이스에서 어느 계층에도 테스트가 없었다.
test "server: runtime.clipboard_write requires input capability and returns the host text" {
    const allocator = testing.allocator;
    var registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer registry.deinit();
    _ = try registry.register(0xAA, 80, 24);

    var fake: FakeRuntimeOps = .{};
    var conn = Connection.init(allocator, 1, &registry);
    defer conn.deinit();
    conn.runtime_ops = fake.ops();
    {
        const h = try feedJson(&conn, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2}");
        if (h.frame) |f| f.deinit(allocator);
    }
    // observer로 attach하면 input capability가 없다 → 클립보드를 가져갈 수 없어야 한다.
    {
        const frames = try feedExpectFrames(&conn, .request, 2, "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"observer\"}}");
        defer {
            for (frames) |f| f.deinit(allocator);
            allocator.free(frames);
        }
    }
    {
        const r = try feedJson(&conn, .request, 3, "{\"method\":\"runtime.clipboard_write\",\"params\":{\"stream_id\":1}}");
        defer if (r.frame) |f| f.deinit(allocator);
        try testing.expect(std.mem.indexOf(u8, r.frame.?.payload, "unauthorized") != null);
        try testing.expect(std.mem.indexOf(u8, r.frame.?.payload, "COPIED") == null);
    }
}

test "server: runtime.link_at routes cell and scopes to RuntimeOps and returns the host link" {
    const allocator = testing.allocator;
    var registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer registry.deinit();
    _ = try registry.register(0xAA, 80, 24);

    var fake: FakeRuntimeOps = .{};
    var conn = Connection.init(allocator, 1, &registry);
    defer conn.deinit();
    conn.runtime_ops = fake.ops();
    {
        const h = try feedJson(&conn, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2}");
        if (h.frame) |f| f.deinit(allocator);
    }
    {
        const frames = try feedExpectFrames(&conn, .request, 2, "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"controller\"}}");
        defer {
            for (frames) |f| f.deinit(allocator);
            allocator.free(frames);
        }
    }
    {
        const r = try feedJson(&conn, .request, 3, "{\"method\":\"runtime.link_at\",\"params\":{\"stream_id\":1,\"row\":7,\"col\":11,\"scopes\":63}}");
        defer if (r.frame) |f| f.deinit(allocator);
        try testing.expect(std.mem.indexOf(u8, r.frame.?.payload, "https://example.com/x") != null);
    }
    try testing.expectEqual(@as(u16, 7), fake.last_link_row);
    try testing.expectEqual(@as(u16, 11), fake.last_link_col);
    try testing.expectEqual(@as(u8, 63), fake.last_link_scopes); // link_scopes_full
    try testing.expectEqual(@as(u128, 0xAA), fake.link_at_runtime);
}

test "server: runtime.selected_text routes span to RuntimeOps and returns text (§6b 원격 선택 복사)" {
    const allocator = testing.allocator;
    var registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer registry.deinit();
    _ = try registry.register(0xAA, 80, 24);

    var fake: FakeRuntimeOps = .{};
    var conn = Connection.init(allocator, 1, &registry);
    defer conn.deinit();
    conn.runtime_ops = fake.ops();
    {
        const h = try feedJson(&conn, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2}");
        if (h.frame) |f| f.deinit(allocator);
    }
    {
        const frames = try feedExpectFrames(&conn, .request, 2, "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"controller\"}}");
        defer {
            for (frames) |f| f.deinit(allocator);
            allocator.free(frames);
        }
    }
    // 선택 span(sr1,sc2,er3,ec4,block) → RuntimeOps.selected_text로 라우팅 + host 텍스트("PICKED")를 응답에 담는다.
    {
        const r = try feedJson(&conn, .request, 3, "{\"method\":\"runtime.selected_text\",\"params\":{\"stream_id\":1,\"sr\":1,\"sc\":2,\"er\":3,\"ec\":4,\"block\":true}}");
        defer if (r.frame) |f| f.deinit(allocator);
        try testing.expect(std.mem.indexOf(u8, r.frame.?.payload, "PICKED") != null);
    }
    try testing.expectEqual(@as(u16, 1), fake.last_select_span.sr);
    try testing.expectEqual(@as(u16, 2), fake.last_select_span.sc);
    try testing.expectEqual(@as(u16, 3), fake.last_select_span.er);
    try testing.expectEqual(@as(u16, 4), fake.last_select_span.ec);
    try testing.expect(fake.last_select_span.block);
    try testing.expectEqual(@as(u128, 0xAA), fake.selected_text_runtime);

    // additive 전체 선택 의도는 기존 viewport 좌표와 별도로 라우팅된다.
    {
        const r = try feedJson(&conn, .request, 31, "{\"method\":\"runtime.selected_text\",\"params\":{\"stream_id\":1,\"sr\":0,\"sc\":0,\"er\":7,\"ec\":79,\"block\":false,\"all\":true}}");
        defer if (r.frame) |f| f.deinit(allocator);
        try testing.expect(std.mem.indexOf(u8, r.frame.?.payload, "PICKED") != null);
    }
    try testing.expect(fake.last_select_span.all);

    // 필드 부재는 same-major legacy false지만, 존재하는 malformed 값은 조용히 viewport 모드로 낮추지 않는다.
    {
        const r = try feedJson(&conn, .request, 32, "{\"method\":\"runtime.selected_text\",\"params\":{\"stream_id\":1,\"sr\":0,\"sc\":0,\"er\":0,\"ec\":0,\"block\":false,\"all\":1}}");
        defer if (r.frame) |f| f.deinit(allocator);
        try testing.expect(std.mem.indexOf(u8, r.frame.?.payload, "invalid_request") != null);
    }

    // 모르는 stream_id → invalid_request.
    {
        const r = try feedJson(&conn, .request, 4, "{\"method\":\"runtime.selected_text\",\"params\":{\"stream_id\":99,\"sr\":0,\"sc\":0,\"er\":0,\"ec\":0,\"block\":false}}");
        defer if (r.frame) |f| f.deinit(allocator);
        try testing.expect(std.mem.indexOf(u8, r.frame.?.payload, "invalid_request") != null);
    }
}

test "server: runtime.select_op routes word/line op to RuntimeOps and returns span (§6b-2)" {
    const allocator = testing.allocator;
    var registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer registry.deinit();
    _ = try registry.register(0xAA, 80, 24);

    var fake: FakeRuntimeOps = .{};
    var conn = Connection.init(allocator, 1, &registry);
    defer conn.deinit();
    conn.runtime_ops = fake.ops();
    {
        const h = try feedJson(&conn, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2}");
        if (h.frame) |f| f.deinit(allocator);
    }
    {
        const frames = try feedExpectFrames(&conn, .request, 2, "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"controller\"}}");
        defer {
            for (frames) |f| f.deinit(allocator);
            allocator.free(frames);
        }
    }
    // word(row1,col2) → RuntimeOps.select_op으로 라우팅 + fake span을 응답에 담는다.
    {
        const r = try feedJson(&conn, .request, 3, "{\"method\":\"runtime.select_op\",\"params\":{\"stream_id\":1,\"op\":\"word\",\"row\":1,\"col\":2,\"separators_hex\":\"2e\"}}");
        defer if (r.frame) |f| f.deinit(allocator);
        try testing.expect(std.mem.indexOf(u8, r.frame.?.payload, "\"sel\":true") != null);
        try testing.expect(std.mem.indexOf(u8, r.frame.?.payload, "\"ec\":3") != null);
    }
    try testing.expectEqualStrings("word", fake.last_select_op[0..fake.last_select_op_len]);
    try testing.expectEqual(@as(u16, 1), fake.last_select_op_row);
    try testing.expectEqual(@as(u16, 2), fake.last_select_op_col);
    try testing.expectEqualStrings("2e", fake.last_select_separators_hex[0..fake.last_select_separators_hex_len]);

    // all은 같은 RPC의 additive op이며 좌표를 추측하지 않고 RuntimeOps에 그대로 위임한다.
    {
        const r = try feedJson(&conn, .request, 31, "{\"method\":\"runtime.select_op\",\"params\":{\"stream_id\":1,\"op\":\"all\"}}");
        defer if (r.frame) |f| f.deinit(allocator);
        try testing.expect(std.mem.indexOf(u8, r.frame.?.payload, "\"sel\":true") != null);
    }
    try testing.expectEqualStrings("all", fake.last_select_op[0..fake.last_select_op_len]);

    // 모르는 stream_id → invalid_request.
    {
        const r = try feedJson(&conn, .request, 4, "{\"method\":\"runtime.select_op\",\"params\":{\"stream_id\":99,\"op\":\"line\",\"row\":0,\"col\":0}}");
        defer if (r.frame) |f| f.deinit(allocator);
        try testing.expect(std.mem.indexOf(u8, r.frame.?.payload, "invalid_request") != null);
    }
}

test "runtime.list 만 title 을 싣고, runtime.get 은 6필드를 지킨다" {
    // **이 둘이 갈리는 데는 근거가 있다.** `runtime.get` 응답의 소비자는 기계이고
    // (`attach_product_resolver.decodeMembership`·`recovered_session_adopt`) 필드 수 6을 정확히
    // 요구하며 fail-close 한다. 실제로 title 을 get 에도 실었다가 attach 가 통째로 졌다.
    var entry: reg.RuntimeEntry = .{ .id = 0xaa, .cols = 80, .rows = 24 };
    defer entry.observers.deinit(std.testing.allocator);

    // 목록: title 이 있으면 7필드.
    const titled = runtimeListEntryValue("000000000000000000000000000000aa", &entry, "zsh — maru");
    try std.testing.expect(titled == .titled);
    try std.testing.expectEqualStrings("zsh — maru", titled.titled.title);

    // **빈 title 은 없는 것과 같다** — `"title":""` 은 "제목이 빈 세션" 이라는 다른 말이다.
    try std.testing.expect(runtimeListEntryValue("000000000000000000000000000000aa", &entry, "") == .plain);
    try std.testing.expect(runtimeListEntryValue("000000000000000000000000000000aa", &entry, null) == .plain);

    // get 모양은 6필드 그대로다. 필드를 세어 고정한다 — 늘면 attach 가 진다.
    const meta = runtimeMetaValue("000000000000000000000000000000aa", &entry);
    try std.testing.expectEqual(@as(usize, 6), @typeInfo(@TypeOf(meta)).@"struct".fields.len);
}

test "title 은 상한에서 UTF-8 경계로 잘린다" {
    // 원격이 정하는 길이라 상한이 필요하고(§8), 바이트로 자르면 깨진 시퀀스가 wire 로 나간다.
    const one = "한"; // 3바이트
    var long: [protocol.max_title_bytes + 12]u8 = undefined;
    var i: usize = 0;
    while (i + one.len <= long.len) : (i += one.len) @memcpy(long[i..][0..one.len], one);
    const clamped = clampTitle(long[0..i]);
    try std.testing.expect(clamped.len <= protocol.max_title_bytes);
    try std.testing.expect(std.unicode.utf8ValidateSlice(clamped));
    try std.testing.expectEqualStrings("zsh", clampTitle("zsh"));
}

test "server: runtime.find routes query(hex) to RuntimeOps and returns {count,spans} (§6c)" {
    const allocator = testing.allocator;
    var registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer registry.deinit();
    _ = try registry.register(0xAA, 80, 24);

    var fake: FakeRuntimeOps = .{};
    var conn = Connection.init(allocator, 1, &registry);
    defer conn.deinit();
    conn.runtime_ops = fake.ops();
    {
        const h = try feedJson(&conn, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2}");
        if (h.frame) |f| f.deinit(allocator);
    }
    {
        const frames = try feedExpectFrames(&conn, .request, 2, "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"controller\"}}");
        defer {
            for (frames) |f| f.deinit(allocator);
            allocator.free(frames);
        }
    }
    // 검색어 "hi" = hex "6869", cur=1, scroll=true → RuntimeOps.find로 라우팅 + fake {count,cur,spans}를 응답에 담는다.
    {
        const r = try feedJson(&conn, .request, 3, "{\"method\":\"runtime.find\",\"params\":{\"stream_id\":1,\"q\":\"6869\",\"cur\":1,\"scroll\":true}}");
        defer if (r.frame) |f| f.deinit(allocator);
        try testing.expect(std.mem.indexOf(u8, r.frame.?.payload, "\"count\":2") != null);
        try testing.expect(std.mem.indexOf(u8, r.frame.?.payload, "\"cur\":[0,0,0,2]") != null); // 현재 매치 span
        try testing.expect(std.mem.indexOf(u8, r.frame.?.payload, "\"spans\":[1,2,1,5]") != null);
    }
    try testing.expectEqualStrings("6869", fake.last_find_query_hex[0..fake.last_find_query_hex_len]);
    try testing.expectEqual(@as(u32, 1), fake.last_find_cur); // cur 라우팅
    try testing.expect(fake.last_find_scroll); // scroll 라우팅

    // 모르는 stream_id → invalid_request.
    {
        const r = try feedJson(&conn, .request, 4, "{\"method\":\"runtime.find\",\"params\":{\"stream_id\":99,\"q\":\"6869\"}}");
        defer if (r.frame) |f| f.deinit(allocator);
        try testing.expect(std.mem.indexOf(u8, r.frame.?.payload, "invalid_request") != null);
    }
}

test "server: observer find cannot mutate the shared viewport" {
    const allocator = testing.allocator;
    var registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer registry.deinit();
    _ = try registry.register(0xAA, 80, 24);
    var fake: FakeRuntimeOps = .{};
    var conn = Connection.init(allocator, 1, &registry);
    defer conn.deinit();
    conn.runtime_ops = fake.ops();
    {
        const h = try feedJson(
            &conn,
            .hello,
            1,
            "{\"protocol_min\":2,\"protocol_max\":2}",
        );
        if (h.frame) |frame| frame.deinit(allocator);
    }
    {
        const frames = try feedExpectFrames(
            &conn,
            .request,
            2,
            "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"observer\"}}",
        );
        defer {
            for (frames) |frame| frame.deinit(allocator);
            allocator.free(frames);
        }
    }
    {
        const read_only = try feedJson(
            &conn,
            .request,
            3,
            "{\"method\":\"runtime.find\",\"params\":{\"stream_id\":1,\"q\":\"6869\",\"scroll\":false}}",
        );
        defer if (read_only.frame) |frame| frame.deinit(allocator);
        try testing.expect(std.mem.indexOf(
            u8,
            read_only.frame.?.payload,
            "\"count\":2",
        ) != null);
    }
    fake.last_find_scroll = false;
    {
        const mutating = try feedJson(
            &conn,
            .request,
            4,
            "{\"method\":\"runtime.find\",\"params\":{\"stream_id\":1,\"q\":\"6869\",\"scroll\":true}}",
        );
        defer if (mutating.frame) |frame| frame.deinit(allocator);
        try testing.expect(std.mem.indexOf(
            u8,
            mutating.frame.?.payload,
            "\"unauthorized\"",
        ) != null);
    }
    try testing.expect(!fake.last_find_scroll);
}

test "server: notification consumption is authorized by the exact stream subscription" {
    const allocator = testing.allocator;
    var registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer registry.deinit();
    _ = try registry.register(0xAA, 80, 24);
    var fake: FakeRuntimeOps = .{};
    var conn = Connection.init(allocator, 1, &registry);
    defer conn.deinit();
    conn.runtime_ops = fake.ops();
    {
        const hello = try feedJson(
            &conn,
            .hello,
            1,
            "{\"protocol_min\":2,\"protocol_max\":2}",
        );
        if (hello.frame) |frame| frame.deinit(allocator);
    }
    inline for (.{ "controller", "observer" }, 0..) |mode, index| {
        var request_buf: [128]u8 = undefined;
        const request = try std.fmt.bufPrint(
            &request_buf,
            "{{\"method\":\"runtime.attach\",\"params\":{{\"runtime_id\":\"aa\",\"mode\":\"{s}\"}}}}",
            .{mode},
        );
        const frames = try feedExpectFrames(
            &conn,
            .request,
            index + 2,
            request,
        );
        defer {
            for (frames) |frame| frame.deinit(allocator);
            allocator.free(frames);
        }
    }

    // 같은 connection의 stream 1이 controller여도 observer stream 2는 그 권위를 빌려
    // shared pending notification을 소비할 수 없다.
    {
        const observer = try feedJson(
            &conn,
            .request,
            4,
            "{\"method\":\"runtime.notification\",\"params\":{\"stream_id\":2}}",
        );
        defer if (observer.frame) |frame| frame.deinit(allocator);
        try testing.expect(std.mem.indexOf(
            u8,
            observer.frame.?.payload,
            "\"unauthorized\"",
        ) != null);
    }
    try testing.expectEqual(@as(usize, 0), fake.notification_calls);
    {
        const controller = try feedJson(
            &conn,
            .request,
            5,
            "{\"method\":\"runtime.notification\",\"params\":{\"stream_id\":1}}",
        );
        defer if (controller.frame) |frame| frame.deinit(allocator);
        try testing.expect(std.mem.indexOf(
            u8,
            controller.frame.?.payload,
            "\"title\":\"\"",
        ) != null);
    }
    try testing.expectEqual(@as(usize, 1), fake.notification_calls);
    try testing.expectEqual(@as(usize, 1), fake.notification_commit_calls);
    // Same-major old client → new host: legacy runtime selector remains accepted only because this
    // connection owns the live controller for that runtime.
    {
        const legacy_controller = try feedJson(
            &conn,
            .request,
            6,
            "{\"method\":\"runtime.notification\",\"params\":{\"runtime_id\":\"aa\"}}",
        );
        defer if (legacy_controller.frame) |frame| frame.deinit(allocator);
        try testing.expect(std.mem.indexOf(
            u8,
            legacy_controller.frame.?.payload,
            "\"title\":\"\"",
        ) != null);
    }
    try testing.expectEqual(@as(usize, 2), fake.notification_calls);
    try testing.expectEqual(@as(usize, 2), fake.notification_commit_calls);

    var legacy_observer = Connection.init(allocator, 2, &registry);
    defer legacy_observer.deinit();
    // This pure seam has no daemon-wide SubscriptionIdentityTable; keep its raw registry ID
    // distinct from conn's local 1/2. Product owner tests cover colliding local stream 1 safely.
    legacy_observer.next_stream_id = 3;
    legacy_observer.runtime_ops = fake.ops();
    {
        const hello = try feedJson(
            &legacy_observer,
            .hello,
            1,
            "{\"protocol_min\":2,\"protocol_max\":2}",
        );
        if (hello.frame) |frame| frame.deinit(allocator);
    }
    {
        const frames = try feedExpectFrames(
            &legacy_observer,
            .request,
            2,
            "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"observer\"}}",
        );
        defer {
            for (frames) |frame| frame.deinit(allocator);
            allocator.free(frames);
        }
    }
    {
        const denied = try feedJson(
            &legacy_observer,
            .request,
            3,
            "{\"method\":\"runtime.notification\",\"params\":{\"runtime_id\":\"aa\"}}",
        );
        defer if (denied.frame) |frame| frame.deinit(allocator);
        try testing.expect(std.mem.indexOf(
            u8,
            denied.frame.?.payload,
            "\"unauthorized\"",
        ) != null);
    }
    try testing.expectEqual(@as(usize, 2), fake.notification_calls);
    try testing.expectEqual(@as(usize, 2), fake.notification_commit_calls);
}
