//! session-host **connection dispatch state machine**(§10 hello·command 순서). 한 client connection이 보낸 MRSH
//! frame을 받아 hello를 협상하고 read-only command를 `TerminalRuntimeRegistry`로 dispatch해 응답 frame을 만든다.
//!
//! 이 파일은 **순수 상태 기계**다 — socket·fd·프로세스를 모른다(platform import 0). 실제 unix socket bind/accept/
//! peer-cred와 read/write loop는 P3-d1의 platform 통합 층이 이 `Connection.handleFrame`을 구동하고, on-demand
//! detached-helper launch와 `maru-sessiond` entrypoint는 P3-d2다. 이렇게 나눠야 hello/command 계약을 실 socket 없이
//! non-macOS에서 TDD하고, control-plane(`maru.control.v1`)과 wire·ID를 섞지 않는다(§10).
//!
//! 현재 major 규칙:
//!   - connection의 첫 frame은 반드시 `hello`다. 아니면 protocol error로 connection을 닫는다(runtime은 유지).
//!   - header major는 현재 MRSH major와 같아야 하며, client `{protocol_min, protocol_max}`도 그 major를 포함해야 한다.
//!   - d1이 dispatch하는 command는 **read-only**다: `host.info`, `runtime.list`, `runtime.get`. host를 auto-start하지
//!     않는 조회 명령이라 실 runtime 소유·spawn/attach(P3-d2 이후)와 무관하게 registry 상태만 읽는다.

const std = @import("std");
const protocol = @import("protocol.zig");
const framing = @import("framing.zig");
const reg = @import("registry.zig");
const core_command_wire = @import("core_command_wire.zig");

/// hello가 밝히는 client 종류. GUI window인지 CLI(`maru attach`)인지 — 권한/표시에 쓴다(§9).
pub const ClientKind = enum { gui, cli, unknown };

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
    zdotdir: ?[]const u8 = null,
    ssh_integration_bin: ?[]const u8 = null,
    pane_id: ?u64 = null,
    cols: u16,
    rows: u16,
    initial_config: ?core_command_wire.Command.RuntimeConfig = null,
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
    bracketed_paste: bool,
    observer_generation: u64,
    title_generation: u32,
    cols: u16,
    rows: u16,
    foreground_available: bool,
    foreground_pgid: ?i32,
    processes: []Process,

    pub fn deinit(self: *RuntimeObservation, allocator: std.mem.Allocator) void {
        allocator.free(self.cwd);
        allocator.free(self.window_title);
        if (self.ssh_remote_dest) |dest| allocator.free(dest);
        for (self.processes) |p| allocator.free(p.name);
        allocator.free(self.processes);
        self.* = undefined;
    }
};

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
    resize: *const fn (ctx: *anyopaque, runtime_id: u128, cols: u16, rows: u16) anyerror!void,
    /// runtime의 현재 화면을 §12 screen_stream 레코드 스트림(length-prefixed)으로 투영한다(attach 첫 snapshot). caller가
    /// 소유하는 바이트를 돌려주며(host가 core lock 아래 투영), server가 이를 snapshot_chunk frame으로 나눠 보낸다.
    snapshot: *const fn (ctx: *anyopaque, runtime_id: u128, allocator: std.mem.Allocator) anyerror![]u8,
    /// `base`(client가 마지막으로 받은 full snapshot 바이트) 대비 현재 화면 변화를 계산한다(§9 delta). host가 core lock
    /// 아래 diff하고 `StreamUpdate`를 돌려준다 — `send`(delta 또는 fresh snapshot)와 다음 diff의 base가 될 현재 snapshot.
    delta: *const fn (ctx: *anyopaque, runtime_id: u128, base: []const u8, allocator: std.mem.Allocator) anyerror!StreamUpdate,
    /// runtime의 대기 중인 OSC 9/777 데스크톱 알림(host의 `TerminalCore`가 파싱)을 빼서 JSON `{title, body}`로 준다(§6.32
    /// GUI가 종료된 동안의 알림 — host가 core와 함께 알림을 소유). host가 core lock 아래 읽고 clearNotification한다(off-thread
    /// 동기화, snapshot과 동형). 없으면 `{title:"",body:""}`. caller 소유 바이트.
    notification: *const fn (ctx: *anyopaque, runtime_id: u128, allocator: std.mem.Allocator) anyerror![]u8,
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
    select_op: *const fn (ctx: *anyopaque, runtime_id: u128, op: []const u8, row: u16, col: u16, allocator: std.mem.Allocator) anyerror![]u8,
    /// §6c 원격 검색: client가 보낸 검색어(hex — 임의 텍스트라 escape 회피)로 host가 **콘텐츠·스크롤백을 아는 자기 core**에서
    /// `findMatches`(로컬과 같은 함수)로 매치를 찾고, 보이는 매치를 `matchViewportSpan`으로 클립해 JSON `{count, cur:[...], spans:[...]}`로
    /// 준다. count=전체 매치 수, spans=보이는 **비현재** 매치의 flat 좌표, cur=현재 매치(index `cur_index`)의 뷰포트 span(안 보이면 `[]`).
    /// §6c-2 네비: `scroll`이면 host가 현재 매치의 abs 위치로 `scrollToAbs`해 화면을 이동한다(client가 그 매치를 보게).
    find: *const fn (ctx: *anyopaque, runtime_id: u128, query_hex: []const u8, cur_index: u32, scroll: bool, allocator: std.mem.Allocator) anyerror![]u8,
    /// host 실제 core/PTY의 cwd/title/semantic/OSC5379/foreground를 한 번에 owned copy한다. screen snapshot과 분리된
    /// attach/event full-state이며 public runtime.list/get에는 노출하지 않는다.
    observation: *const fn (ctx: *anyopaque, runtime_id: u128, allocator: std.mem.Allocator) anyerror!RuntimeObservation,
    /// host-backed 마우스 리포팅(§ 입력 패리티): client가 마우스 이벤트를 보내면 host가 **자기 core의 mouse_tracking/
    /// mouse_format**으로 SGR/x10 리포트를 인코딩해 PTY로 흘린다(로컬 reader가 report_mouse core command를 적용 후
    /// pendingResponse를 흘리는 것과 동형 — 인코딩 모드가 host에만 있으므로 host가 인코딩·주입한다). codec 순수라
    /// primitive `MouseReport`만 넘기고 runtime_manager가 CoreCommand로 매핑·적용·flush한다.
    report_mouse: *const fn (ctx: *anyopaque, runtime_id: u128, report: MouseReport) anyerror!void,
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
pub const SelectSpan = struct { sr: u16, sc: u16, er: u16, ec: u16, block: bool };

/// `RuntimeOps.delta` 결과. `send`/`new_base`는 caller 소유이고 **항상 별개 버퍼**다(둘 다 free해도 안전). `send.len==0`이면
/// 변화 없음(아무것도 안 보냄). `is_snapshot`이면 `send`가 fresh snapshot(snapshot_chunk로, client가 화면을 교체), 아니면
/// delta(delta_chunk로, client가 증분 적용). `new_base`는 다음 diff의 base가 될 현재 full snapshot이다.
pub const StreamUpdate = struct {
    send: []u8,
    is_snapshot: bool,
    new_base: []u8,
};

/// `handleFrame`이 caller(socket write loop)에게 지시하는 것. `reply`/`reply_and_close`의 바이트는 **caller 소유**다
/// (socket에 write한 뒤 free). `close`는 응답 없이 connection을 닫으라는 뜻이다(runtime에는 손대지 않는다).
pub const Action = union(enum) {
    reply: []u8,
    reply_and_close: []u8,
    close,
    /// 응답 없이 connection을 유지한다(input_bytes 같은 fire-and-forget stream frame 처리 후). caller는 아무것도 write하지 않는다.
    none,
    /// 여러 frame을 **순서대로** write하고 connection을 유지한다(attach 응답 + snapshot_chunk* — §10 attach 순서). 바깥
    /// 슬라이스와 각 `[]u8`은 caller 소유다(순서대로 write한 뒤 각 frame free, 마지막에 바깥 슬라이스 free). `frames[0]`이
    /// 응답 frame, 이후가 snapshot_chunk들이다.
    frames: [][]u8,
};

pub const HandleError = error{OutOfMemory};

/// 한 client connection의 상태. socket 하나당 하나. `host_id`는 server가 발급한 128-bit opaque(테스트는 고정 주입).
pub const Connection = struct {
    allocator: std.mem.Allocator,
    host_id: u128,
    registry: *reg.TerminalRuntimeRegistry,
    /// 실 runtime 소유 위임(host만 설정). null이면 read-only host라 spawn/terminate/input/resize가 unauthorized다.
    runtime_ops: ?RuntimeOps = null,
    state: State = .pre_hello,
    selected_version: u16 = 0,
    client_kind: ClientKind = .unknown,
    /// MRSH v2에 후속 비동기 event를 무조건 밀면 같은 major의 구 client가 protocol error로 종료한다. hello에서
    /// 명시적으로 협상한 client에게만 runtime metadata attach/event/RPC를 노출한다.
    runtime_metadata_v1: bool = false,
    /// 이 connection이 연 stream 구독 표(§9 attach subscription). key=`stream_id`, value=`Subscription`(runtime_id +
    /// 마지막 full snapshot base). input_bytes/resize/detach가 stream_id로 runtime을 찾고, delta push는 base 대비 diff한다.
    /// connection 종료 시 모두 detach하고 base를 해제한다. host가 stream_id를 발급한다(현재 per-connection 단조 — serial serve
    /// 전제라 겹치지 않는다; 동시 연결 후속에서 host-global 발급으로 승격).
    attachments: std.AutoHashMapUnmanaged(reg.StreamId, Subscription) = .empty,
    next_stream_id: reg.StreamId = 1,

    /// 한 stream 구독의 상태. `base`는 이 stream에 마지막으로 보낸 full snapshot 바이트(다음 delta diff의 기준). attach
    /// 직후 첫 snapshot으로 채워지고, delta push마다 갱신된다. null이면 아직 base가 없다(read-only host 또는 snapshot 실패).
    /// `resync_pending`=client가 `runtime.resync`로 fresh snapshot 재요청(§9 desync 복구) — 다음 `collectDeltas`가 delta 대신
    /// 현재 full snapshot을 snapshot_chunk로 push하고 base를 그걸로 교체한다. client의 조립기 generation gap을 리셋한다.
    pub const Subscription = struct {
        runtime_id: u128,
        base: ?[]u8 = null,
        resync_pending: bool = false,
        observation_base: ?[]u8 = null,
        observation_revision: u64 = 0,
        observation_ticks: u8 = 0,
    };

    pub const State = enum { pre_hello, ready, closed };

    pub fn init(allocator: std.mem.Allocator, host_id: u128, registry: *reg.TerminalRuntimeRegistry) Connection {
        return .{ .allocator = allocator, .host_id = host_id, .registry = registry };
    }

    /// connection 종료(EOF/close) 시 이 connection의 모든 subscription을 registry에서 떼고 base를 해제한다(§9 "EOF는 모든
    /// stream을 detach하지만 runtime/child에는 종료 신호를 보내지 않는다"). runtime이 이미 없으면(동시 terminate) 무시한다.
    pub fn deinit(self: *Connection) void {
        var it = self.attachments.iterator();
        while (it.next()) |e| {
            _ = self.registry.detach(e.value_ptr.runtime_id, e.key_ptr.*) catch {};
            if (e.value_ptr.base) |b| self.allocator.free(b);
            if (e.value_ptr.observation_base) |b| self.allocator.free(b);
        }
        self.attachments.deinit(self.allocator);
        self.* = undefined;
    }

    /// MRSH frame 하나를 처리한다. connection state에 따라 hello 협상 또는 command dispatch를 하고, 응답 frame을
    /// 만들어 `Action`으로 돌려준다. 응답이 없거나 protocol을 어긴 경우 `.close`다(runtime은 유지).
    pub fn handleFrame(self: *Connection, frame: framing.Frame) HandleError!Action {
        if (frame.header.major != protocol.version_major) {
            self.state = .closed;
            return .close;
        }
        return switch (self.state) {
            .pre_hello => self.handleHello(frame),
            .ready => self.handleReady(frame),
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
        self.client_kind = parseClientKind(strField(obj, "client_kind"));
        self.runtime_metadata_v1 = stringArrayContains(obj, "capabilities", "runtime_metadata_v1");

        // 겹치는 major가 없으면 incompatible_version으로 끝낸다(§10). 이때는 응답을 준 뒤 닫는다.
        if (!(pmin <= protocol.version_major and protocol.version_major <= pmax)) {
            const body = try self.errorJson(.incompatible_version);
            defer self.allocator.free(body);
            const wire = try self.encodeSmall(.hello_ack, frame.header.request_id, 0, body);
            self.state = .closed;
            return .{ .reply_and_close = wire };
        }

        self.selected_version = protocol.version_major;
        self.state = .ready;
        const ack = try self.helloAckJson();
        defer self.allocator.free(ack);
        const wire = try self.encodeSmall(.hello_ack, frame.header.request_id, 0, ack);
        return .{ .reply = wire };
    }

    fn handleReady(self: *Connection, frame: framing.Frame) HandleError!Action {
        switch (frame.header.kind) {
            .ping => {
                // diagnostic nonce를 그대로 되돌린다(payload passthrough). ping·pong cap이 같아 재초과 없음.
                const wire = try self.encodeSmall(.pong, frame.header.request_id, frame.header.stream_id, frame.payload);
                return .{ .reply = wire };
            },
            .request => return self.dispatchRequest(frame),
            .input_bytes => return self.routeInput(frame),
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

    fn dispatchRequest(self: *Connection, frame: framing.Frame) HandleError!Action {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, frame.payload, .{}) catch {
            return self.replyError(frame.header.request_id, .invalid_request);
        };
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return self.replyError(frame.header.request_id, .invalid_request),
        };
        const method = strField(obj, "method") orelse return self.replyError(frame.header.request_id, .invalid_request);
        const params: ?std.json.ObjectMap = switch (obj.get("params") orelse std.json.Value.null) {
            .object => |o| o,
            else => null,
        };

        if (std.mem.eql(u8, method, "host.info")) {
            const body = try self.hostInfoJson();
            defer self.allocator.free(body);
            return self.replyResult(frame.header.request_id, body);
        } else if (std.mem.eql(u8, method, "runtime.list")) {
            const body = try self.runtimeListJson();
            defer self.allocator.free(body);
            return self.replyResult(frame.header.request_id, body);
        } else if (std.mem.eql(u8, method, "runtime.get")) {
            const id_hex = if (params) |p| strField(p, "runtime_id") else null;
            const id = if (id_hex) |h| parseHex128(h) else null;
            if (id == null) return self.replyError(frame.header.request_id, .invalid_request);
            const entry = self.registry.get(id.?) orelse return self.replyError(frame.header.request_id, .runtime_not_found);
            const body = try self.runtimeMetaJson(entry);
            defer self.allocator.free(body);
            return self.replyResult(frame.header.request_id, body);
        } else if (std.mem.eql(u8, method, "runtime.spawn")) {
            return self.dispatchSpawn(frame.header.request_id, params, false);
        } else if (std.mem.eql(u8, method, "runtime.spawn_full")) {
            return self.dispatchSpawn(frame.header.request_id, params, true);
        } else if (std.mem.eql(u8, method, "runtime.terminate")) {
            return self.dispatchTerminate(frame.header.request_id, params);
        } else if (std.mem.eql(u8, method, "runtime.attach")) {
            return self.dispatchAttach(frame.header.request_id, params);
        } else if (std.mem.eql(u8, method, "runtime.detach")) {
            return self.dispatchDetach(frame.header.request_id, params);
        } else if (std.mem.eql(u8, method, "runtime.resync")) {
            return self.dispatchResync(frame.header.request_id, params);
        } else if (std.mem.eql(u8, method, "runtime.observation")) {
            return self.dispatchObservation(frame.header.request_id, params);
        } else if (std.mem.eql(u8, method, "runtime.core_command")) {
            return self.dispatchCoreCommand(frame.header.request_id, params);
        } else if (std.mem.eql(u8, method, "runtime.report_mouse")) {
            return self.dispatchReportMouse(frame.header.request_id, params);
        } else if (std.mem.eql(u8, method, "runtime.selected_text")) {
            return self.dispatchSelectedText(frame.header.request_id, params);
        } else if (std.mem.eql(u8, method, "runtime.select_op")) {
            return self.dispatchSelectOp(frame.header.request_id, params);
        } else if (std.mem.eql(u8, method, "runtime.find")) {
            return self.dispatchFind(frame.header.request_id, params);
        } else if (std.mem.eql(u8, method, "runtime.resize")) {
            return self.dispatchResize(frame.header.request_id, params);
        } else if (std.mem.eql(u8, method, "runtime.notification")) {
            return self.dispatchNotification(frame.header.request_id, params);
        }
        return self.replyError(frame.header.request_id, .invalid_request);
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
        if (!reg.Capability.has(self.registry.capabilitiesOf(sub.runtime_id, stream), reg.Capability.observe))
            return self.replyError(request_id, .unauthorized);

        var observation = ops.observation(ops.ctx, sub.runtime_id, self.allocator) catch |err| switch (err) {
            error.RuntimeNotFound => return self.replyError(request_id, .runtime_not_found),
            else => return self.replyError(request_id, .internal),
        };
        defer observation.deinit(self.allocator);
        const canonical = self.stringify(observation) catch return error.OutOfMemory;
        var canonical_owned = true;
        defer if (canonical_owned) self.allocator.free(canonical);
        const changed = if (sub.observation_base) |old| !std.mem.eql(u8, old, canonical) else true;
        const revision = if (changed) sub.observation_revision +% 1 else sub.observation_revision;
        const body = try self.stringify(.{ .result = .{
            .metadata_revision = revision,
            .metadata = observation,
        } });
        defer self.allocator.free(body);
        const action = try self.replyResult(request_id, body);

        // response frame까지 소유한 뒤에만 server base를 전진시킨다. 이 전 OOM이면 다음 periodic event가 같은 변화를
        // 다시 보낼 수 있어 client cache가 영구 누락되지 않는다.
        if (changed) {
            if (sub.observation_base) |old| self.allocator.free(old);
            sub.observation_base = canonical;
            sub.observation_revision = revision;
            canonical_owned = false;
        }
        return action;
    }

    /// `runtime.notification`(§6.32): runtime의 대기 중인 OSC 9/777 알림을 빼서 `{title, body}`로 응답한다. read-only host면
    /// unauthorized. 없으면 `{title:"",body:""}`(client가 빈 값을 "없음"으로 해석). runtime 없으면 runtime_not_found.
    fn dispatchNotification(self: *Connection, request_id: u64, params: ?std.json.ObjectMap) HandleError!Action {
        const ops = self.runtime_ops orelse return self.replyError(request_id, .unauthorized);
        const p = params orelse return self.replyError(request_id, .invalid_request);
        const id_hex = strField(p, "runtime_id") orelse return self.replyError(request_id, .invalid_request);
        const id = parseHex128(id_hex) orelse return self.replyError(request_id, .invalid_request);
        const body = ops.notification(ops.ctx, id, self.allocator) catch |err| switch (err) {
            error.RuntimeNotFound => return self.replyError(request_id, .runtime_not_found),
            else => return self.replyError(request_id, .internal),
        };
        defer self.allocator.free(body);
        return self.replyResult(request_id, body);
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
        const initial_config: ?core_command_wire.Command.RuntimeConfig = if (p.get("runtime_config")) |value|
            switch (value) {
                .null => null,
                .object => |object| core_command_wire.decodeRuntimeConfig(object) orelse
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
            .zdotdir = zdotdir,
            .ssh_integration_bin = ssh_integration_bin,
            .pane_id = pane_id,
            .cols = cols,
            .rows = rows,
            .initial_config = initial_config,
        }) catch return self.replyError(request_id, .internal);

        const id_hex = try self.hex128(runtime_id);
        defer self.allocator.free(id_hex);
        const body = try self.stringify(.{ .result = .{ .runtime_id = id_hex } });
        defer self.allocator.free(body);
        return self.replyResult(request_id, body);
    }

    /// `runtime.terminate`: read-only host면 unauthorized. `runtime_id`를 파싱해 `RuntimeOps.terminate`로 종료(멱등).
    fn dispatchTerminate(self: *Connection, request_id: u64, params: ?std.json.ObjectMap) HandleError!Action {
        const ops = self.runtime_ops orelse return self.replyError(request_id, .unauthorized);
        const p = params orelse return self.replyError(request_id, .invalid_request);
        const id = if (strField(p, "runtime_id")) |h| parseHex128(h) else null;
        if (id == null) return self.replyError(request_id, .invalid_request);
        ops.terminate(ops.ctx, id.?);
        const body = try self.stringify(.{ .result = .{ .terminated = true } });
        defer self.allocator.free(body);
        return self.replyResult(request_id, body);
    }

    /// `runtime.attach`: runtime에 subscription을 연다(§8·§9). mode(observer/controller/takeover)에 따라 capability를
    /// 부여하고 host가 발급한 `stream_id`·granted·`controller_busy`를 응답한 뒤, **현재 화면 snapshot을 `snapshot_chunk`
    /// frame으로 이어 보낸다**(§10 attach 순서: response → snapshot_chunk*의 마지막 end_stream → delta_chunk*). delta_chunk
    /// stream과 takeover revocation event fan-out은 e2d-3에서 얹는다. read-only host나 snapshot 실패 시엔 응답만 보낸다
    /// (attach는 성공 — client가 나중에 fresh snapshot을 요청한다, e2d-3 stream_ack).
    fn dispatchAttach(self: *Connection, request_id: u64, params: ?std.json.ObjectMap) HandleError!Action {
        const p = params orelse return self.replyError(request_id, .invalid_request);
        const id = if (strField(p, "runtime_id")) |h| parseHex128(h) else null;
        if (id == null) return self.replyError(request_id, .invalid_request);
        const mode = parseAttachMode(strField(p, "mode"));

        const stream = self.next_stream_id;
        const outcome = self.registry.attach(id.?, stream, mode) catch |e| switch (e) {
            error.RuntimeNotFound => return self.replyError(request_id, .runtime_not_found),
            error.AlreadyAttached => return self.replyError(request_id, .invalid_request),
            error.OutOfMemory => return error.OutOfMemory,
            else => return self.replyError(request_id, .internal),
        };
        self.attachments.put(self.allocator, stream, .{ .runtime_id = id.? }) catch {
            _ = self.registry.detach(id.?, stream) catch {}; // 매핑 실패 시 registry subscription을 되돌린다(유령 subscription 방지).
            return error.OutOfMemory;
        };
        self.next_stream_id += 1;

        // attach 응답에 **현재 full metadata**를 함께 싣는다. response 뒤 snapshot만 온다는 기존 client 순서를 깨지 않으면서,
        // 재접속 GUI가 새 OSC를 기다리지 않고 cwd/title/SSH/agent 정보를 첫 frame 전에 복구한다. observation 실패는 화면
        // attach를 깨지 않고 null(unavailable)로 둔다. public runtime.list/get redaction과는 별도 observe-capability 경로다.
        var initial_observation: ?RuntimeObservation = null;
        defer if (initial_observation) |*obs| obs.deinit(self.allocator);
        if (self.runtime_metadata_v1) if (self.runtime_ops) |ops| {
            initial_observation = ops.observation(ops.ctx, id.?, self.allocator) catch null;
            if (initial_observation) |obs| {
                const canonical = self.stringify(obs) catch null;
                if (canonical) |bytes| {
                    if (self.attachments.getPtr(stream)) |sub| {
                        sub.observation_base = bytes;
                        sub.observation_revision = 1;
                    } else self.allocator.free(bytes);
                } else {
                    // response revision과 subscription base를 원자적으로 세운다. canonical을 소유하지 못했는데 rev1
                    // metadata를 보내면 다음 성공 event도 rev1이라 client가 duplicate로 버린다.
                    initial_observation.?.deinit(self.allocator);
                    initial_observation = null;
                }
            }
        };
        const metadata_revision: u64 = if (self.attachments.get(stream)) |sub| sub.observation_revision else 0;
        const body = try self.stringify(.{ .result = .{
            .stream_id = stream,
            .granted = .{
                .observe = reg.Capability.has(outcome.granted, reg.Capability.observe),
                .input = reg.Capability.has(outcome.granted, reg.Capability.input),
                .resize = reg.Capability.has(outcome.granted, reg.Capability.resize),
            },
            .controller_busy = outcome.controller_busy,
            .metadata_revision = metadata_revision,
            .metadata = initial_observation,
        } });
        defer self.allocator.free(body);
        const reply_frame = self.encode(.response, request_id, 0, body) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.PayloadTooLarge => return self.replyError(request_id, .payload_too_large),
        };

        // read-only host면 실 runtime이 없어 응답만. snapshot 실패도 attach를 깨지 않고 응답만 보낸다(best-effort).
        const ops = self.runtime_ops orelse return .{ .reply = reply_frame };
        const snap_bytes = ops.snapshot(ops.ctx, id.?, self.allocator) catch return .{ .reply = reply_frame };
        // snapshot을 이 stream의 delta base로 보관한다(free하지 않고 subscription이 소유). chunk frame은 payload를 복사한다.
        if (self.attachments.getPtr(stream)) |sub| sub.base = snap_bytes else self.allocator.free(snap_bytes);

        // 응답 frame + snapshot_chunk*를 순서대로 실어 보낸다(§10). errdefer가 부분 조립 시 전부 회수한다.
        var list: std.ArrayListUnmanaged([]u8) = .empty;
        errdefer {
            for (list.items) |f| self.allocator.free(f);
            list.deinit(self.allocator);
        }
        list.append(self.allocator, reply_frame) catch {
            self.allocator.free(reply_frame); // 아직 list 밖이라 직접 회수.
            return error.OutOfMemory;
        };
        try self.appendChunks(&list, .snapshot_chunk, stream, snap_bytes);
        return .{ .frames = list.toOwnedSlice(self.allocator) catch return error.OutOfMemory };
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
        const sub = self.attachments.get(stream) orelse return self.replyError(request_id, .invalid_request);
        _ = self.registry.detach(sub.runtime_id, stream) catch {};
        if (sub.base) |b| self.allocator.free(b); // 이 stream의 delta base 해제.
        if (sub.observation_base) |b| self.allocator.free(b);
        _ = self.attachments.remove(stream);
        const body = try self.stringify(.{ .result = .{ .detached = true } });
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

    /// `runtime.core_command`: strict bounded wire command를 이 stream의 host core reader queue로 라우팅한다.
    /// observer가 focus/config/viewport를 바꾸지 못하도록 controller input capability를 같은 경계에서 검사한다.
    fn dispatchCoreCommand(self: *Connection, request_id: u64, params: ?std.json.ObjectMap) HandleError!Action {
        const p = params orelse return self.replyError(request_id, .invalid_request);
        const stream = intFieldU64(p, "stream_id") orelse return self.replyError(request_id, .invalid_request);
        const runtime_id = (self.attachments.get(stream) orelse return self.replyError(request_id, .invalid_request)).runtime_id;
        if (!reg.Capability.has(self.registry.capabilitiesOf(runtime_id, stream), reg.Capability.input))
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
        const runtime_id = (self.attachments.get(stream) orelse return self.replyError(request_id, .invalid_request)).runtime_id;
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

    /// `runtime.selected_text`(§6b 원격 선택 복사): client가 보낸 뷰포트 선택 span을 host core에 적용해 `extractSelection`으로
    /// 텍스트를 뽑아 `{text}`로 응답한다(host가 콘텐츠 소유 = 선택 의미론 단일 출처, client는 span만 보내고 host가 해석). 모르는
    /// stream_id는 invalid_request. read-only host면 빈 text. 추출 텍스트는 임의 바이트라 host가 실 JSON encoder로 escape한다.
    fn dispatchSelectedText(self: *Connection, request_id: u64, params: ?std.json.ObjectMap) HandleError!Action {
        const p = params orelse return self.replyError(request_id, .invalid_request);
        const stream = intFieldU64(p, "stream_id") orelse return self.replyError(request_id, .invalid_request);
        const runtime_id = (self.attachments.get(stream) orelse return self.replyError(request_id, .invalid_request)).runtime_id;
        const span = SelectSpan{
            .sr = intField(p, "sr") orelse 0,
            .sc = intField(p, "sc") orelse 0,
            .er = intField(p, "er") orelse 0,
            .ec = intField(p, "ec") orelse 0,
            .block = boolField(p, "block"),
        };
        const body = if (self.runtime_ops) |ops|
            ops.selected_text(ops.ctx, runtime_id, span, self.allocator) catch return self.replyError(request_id, .internal)
        else
            (self.allocator.dupe(u8, "{\"text\":\"\"}") catch return error.OutOfMemory);
        defer self.allocator.free(body);
        return self.replyResult(request_id, body);
    }

    /// `runtime.select_op`(§6b-2 단어/줄 선택): client가 보낸 (op, row, col)로 host가 콘텐츠 인지 경계를 계산해
    /// (`selectWordAt`/`selectLineAt`) 결과 뷰포트 선택 span을 응답한다(client가 그 span을 placeholder에 적용해 하이라이트).
    /// 모르는 stream_id는 invalid_request. read-only host는 `{sel:false}`. span은 primitive라 escape 불필요(정수/bool).
    fn dispatchSelectOp(self: *Connection, request_id: u64, params: ?std.json.ObjectMap) HandleError!Action {
        const p = params orelse return self.replyError(request_id, .invalid_request);
        const stream = intFieldU64(p, "stream_id") orelse return self.replyError(request_id, .invalid_request);
        const op = strField(p, "op") orelse return self.replyError(request_id, .invalid_request);
        const row = intField(p, "row") orelse 0;
        const col = intField(p, "col") orelse 0;
        const runtime_id = (self.attachments.get(stream) orelse return self.replyError(request_id, .invalid_request)).runtime_id;
        const body = if (self.runtime_ops) |ops|
            ops.select_op(ops.ctx, runtime_id, op, row, col, self.allocator) catch return self.replyError(request_id, .internal)
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
        const runtime_id = (self.attachments.get(stream) orelse return self.replyError(request_id, .invalid_request)).runtime_id;
        const body = if (self.runtime_ops) |ops|
            ops.find(ops.ctx, runtime_id, query_hex, cur_index, scroll, self.allocator) catch return self.replyError(request_id, .internal)
        else
            (self.allocator.dupe(u8, "{\"count\":0,\"cur\":[],\"spans\":[]}") catch return error.OutOfMemory);
        defer self.allocator.free(body);
        return self.replyResult(request_id, body);
    }

    /// `runtime.resize`: controller가 canonical PTY size를 바꾼다(§9). registry가 controller/sequence를 검증하고, 실제
    /// 크기가 바뀔 때만 runtime_ops(실 `TerminalCore`+`TIOCSWINSZ`)에 적용한 뒤 applied size/generation을 응답한다.
    /// observer의 resize는 unauthorized, stale sequence는 `{stale:true}`. 모든 subscription으로의 `runtime.resized`
    /// broadcast는 e2d(event fan-out)에서 얹는다. (registry가 canonical을 먼저 commit하므로 실 적용 실패는 드문 error 경로다.)
    fn dispatchResize(self: *Connection, request_id: u64, params: ?std.json.ObjectMap) HandleError!Action {
        const p = params orelse return self.replyError(request_id, .invalid_request);
        const stream = intFieldU64(p, "stream_id") orelse return self.replyError(request_id, .invalid_request);
        const cols = intField(p, "cols") orelse return self.replyError(request_id, .invalid_request);
        const rows = intField(p, "rows") orelse return self.replyError(request_id, .invalid_request);
        const seq = intFieldU64(p, "client_sequence") orelse 0;
        const runtime_id = (self.attachments.get(stream) orelse return self.replyError(request_id, .invalid_request)).runtime_id;

        const outcome = self.registry.resize(runtime_id, stream, cols, rows, seq) catch |e| switch (e) {
            error.NotController => return self.replyError(request_id, .unauthorized),
            error.RuntimeNotFound => return self.replyError(request_id, .runtime_not_found),
            else => return self.replyError(request_id, .internal),
        };
        switch (outcome) {
            .stale => {
                const body = try self.stringify(.{ .result = .{ .stale = true } });
                defer self.allocator.free(body);
                return self.replyResult(request_id, body);
            },
            .applied => |a| {
                if (a.changed) {
                    if (self.runtime_ops) |ops| {
                        ops.resize(ops.ctx, runtime_id, a.cols, a.rows) catch return self.replyError(request_id, .internal);
                    }
                }
                const body = try self.stringify(.{ .result = .{
                    .cols = a.cols,
                    .rows = a.rows,
                    .client_sequence = seq,
                    .resize_generation = a.resize_generation,
                    .changed = a.changed,
                } });
                defer self.allocator.free(body);
                return self.replyResult(request_id, body);
            },
        }
    }

    /// `input_bytes`: controller가 보낸 terminal input을 runtime PTY로 보낸다(§9 `input` capability). 응답 없는 stream
    /// frame이라 항상 `.none`이다. 미attach stream·비controller·runtime_ops 없음이면 조용히 버린다(connection은 유지 —
    /// detach 직후 도착한 stray input은 benign race라 연결을 끊지 않는다).
    fn routeInput(self: *Connection, frame: framing.Frame) HandleError!Action {
        const stream = frame.header.stream_id;
        const runtime_id = (self.attachments.get(stream) orelse return .none).runtime_id;
        if (!reg.Capability.has(self.registry.capabilitiesOf(runtime_id, stream), reg.Capability.input)) return .none;
        const ops = self.runtime_ops orelse return .none;
        ops.write_input(ops.ctx, runtime_id, frame.payload) catch {
            // controller bytes는 ACK 없는 ownership transfer다. host queue admission 실패 뒤 연결을 usable로
            // 두면 client는 성공으로 간주한 입력을 영구 유실하므로 EOF detach/reconnect 경계로 fail-close한다.
            self.state = .closed;
            return .close;
        };
        return .none;
    }

    /// `scroll_to_bottom`: controller 전용 fire-and-forget viewport command. AppKit IME callback에서
    /// request/response 왕복을 기다리지 않도록 payload 없는 stream frame으로 받는다. 같은 connection의
    /// 다음 `input_bytes`보다 먼저 dispatch되므로 scroll barrier의 wire 순서를 보존한다.
    fn routeScrollToBottom(self: *Connection, frame: framing.Frame) HandleError!Action {
        if (frame.payload.len != 0) return .none;
        const stream = frame.header.stream_id;
        const runtime_id = (self.attachments.get(stream) orelse return .none).runtime_id;
        if (!reg.Capability.has(self.registry.capabilitiesOf(runtime_id, stream), reg.Capability.input)) return .none;
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
        const runtime_id = (self.attachments.get(stream) orelse return .none).runtime_id;
        if (!reg.Capability.has(self.registry.capabilitiesOf(runtime_id, stream), reg.Capability.input)) return .none;
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
        const ops = self.runtime_ops orelse return null;
        var list: std.ArrayListUnmanaged([]u8) = .empty;
        errdefer {
            for (list.items) |f| self.allocator.free(f);
            list.deinit(self.allocator);
        }
        var it = self.attachments.iterator();
        while (it.next()) |entry| {
            const stream = entry.key_ptr.*;
            const sub = entry.value_ptr;
            // 화면과 별개인 runtime metadata full-state를 약 100ms(serve tick 20ms × 5)마다 관측한다. foreground process는
            // terminal output 없이도 바뀌므로 screen delta 유무로 게이트하면 Claude/Codex 전환을 놓친다. 동일 canonical
            // state는 전송하지 않고, 변화한 최신 full-state만 event 한 건으로 보낸다. client도 stream별 latest로 coalesce한다.
            sub.observation_ticks +%= 1;
            if (self.runtime_metadata_v1 and sub.observation_ticks >= 5) {
                sub.observation_ticks = 0;
                if (ops.observation(ops.ctx, sub.runtime_id, self.allocator) catch null) |obs_value| {
                    var obs = obs_value;
                    defer obs.deinit(self.allocator);
                    const canonical = self.stringify(obs) catch null;
                    if (canonical) |current| {
                        const changed = if (sub.observation_base) |old| !std.mem.eql(u8, old, current) else true;
                        if (changed) {
                            const next_revision = sub.observation_revision +% 1;
                            const event_body = self.stringify(.{
                                .event = "runtime.metadata",
                                .metadata_revision = next_revision,
                                .metadata = obs,
                            }) catch null;
                            if (event_body) |json| {
                                defer self.allocator.free(json);
                                const frame = self.encodeWithFlags(.event, 0, stream, 0, json) catch null;
                                if (frame) |owned_frame| {
                                    list.append(self.allocator, owned_frame) catch {
                                        self.allocator.free(owned_frame);
                                        self.allocator.free(current);
                                        return error.OutOfMemory;
                                    };
                                    if (sub.observation_base) |old| self.allocator.free(old);
                                    sub.observation_base = current;
                                    sub.observation_revision = next_revision;
                                } else self.allocator.free(current);
                            } else self.allocator.free(current);
                        } else self.allocator.free(current);
                    }
                }
            }
            // §9 desync 복구: resync 요청된 stream은 delta 대신 **fresh snapshot**을 push하고 base를 교체한다(client generation
            // gap 리셋). base-null skip보다 먼저 처리한다(base 없어도 snapshot은 보낼 수 있다). snapshot 실패는 이 tick만 건너뛰되
            // pending은 유지(다음 tick 재시도). send(snapshot_chunk)와 base는 별개 버퍼여야 하므로 base용으로 복사한다.
            if (sub.resync_pending) {
                const snap = ops.snapshot(ops.ctx, sub.runtime_id, self.allocator) catch continue; // 실패 → pending 유지, 다음 tick.
                const base_copy = self.allocator.dupe(u8, snap) catch {
                    self.allocator.free(snap);
                    continue;
                };
                sub.resync_pending = false;
                if (sub.base) |b| self.allocator.free(b);
                sub.base = base_copy;
                self.appendChunks(&list, .snapshot_chunk, stream, snap) catch {
                    self.allocator.free(snap);
                    return error.OutOfMemory;
                };
                self.allocator.free(snap);
                continue;
            }
            const base = sub.base orelse continue; // base가 없으면(read-only/실패) 이 stream은 아직 delta 대상이 아니다.
            const update = ops.delta(ops.ctx, sub.runtime_id, base, self.allocator) catch continue; // diff 실패는 이 tick만 건너뛴다.
            // base를 현재 snapshot으로 교체한다(다음 diff 기준). send는 별개 버퍼다.
            self.allocator.free(base);
            sub.base = update.new_base;
            if (update.send.len == 0) {
                self.allocator.free(update.send); // 변화 없음.
                continue;
            }
            const kind: protocol.Kind = if (update.is_snapshot) .snapshot_chunk else .delta_chunk;
            self.appendChunks(&list, kind, stream, update.send) catch {
                self.allocator.free(update.send);
                return error.OutOfMemory;
            };
            self.allocator.free(update.send);
        }
        if (list.items.len == 0) {
            list.deinit(self.allocator);
            return null;
        }
        return list.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
    }

    // ── JSON 응답 빌더 ──────────────────────────────────────────────────────

    fn helloAckJson(self: *Connection) HandleError![]u8 {
        const host_hex = try self.hostHex();
        defer self.allocator.free(host_hex);
        return self.stringify(.{
            .version = self.selected_version,
            .host_id = host_hex,
            .capabilities = [_][]const u8{ "host.info", "runtime.list", "runtime.get", "runtime_metadata_v1", "screen_viewport_scrolled_v1", "async_scroll_to_bottom_v1", "runtime_core_command_v1", "runtime_selected_text_v1" },
        });
    }

    fn hostInfoJson(self: *Connection) HandleError![]u8 {
        const host_hex = try self.hostHex();
        defer self.allocator.free(host_hex);
        return self.stringify(.{
            .result = .{ .host_id = host_hex, .runtime_count = self.registry.count() },
        });
    }

    fn runtimeMetaJson(self: *Connection, entry: *reg.RuntimeEntry) HandleError![]u8 {
        const id_hex = try self.hex128(entry.id);
        defer self.allocator.free(id_hex);
        return self.stringify(.{ .result = runtimeMetaValue(id_hex, entry) });
    }

    fn runtimeListJson(self: *Connection) HandleError![]u8 {
        // registry entry들을 순회해 redacted metadata 배열을 만든다. 각 hex 문자열을 arena로 모아 stringify 후 해제.
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        var list: std.ArrayListUnmanaged(RuntimeMetaWire) = .empty;
        var it = self.registry.entries.valueIterator();
        while (it.next()) |entry_ptr| {
            const id_hex = std.fmt.allocPrint(a, "{x:0>32}", .{entry_ptr.*.id}) catch return error.OutOfMemory;
            list.append(a, runtimeMetaValue(id_hex, entry_ptr.*)) catch return error.OutOfMemory;
        }
        return self.stringify(.{ .result = .{ .runtimes = list.items } });
    }

    fn errorJson(self: *Connection, code: protocol.ErrorCode) HandleError![]u8 {
        return self.stringify(.{ .@"error" = code.wireName() });
    }

    // ── low-level helpers ──────────────────────────────────────────────────

    fn replyError(self: *Connection, request_id: u64, code: protocol.ErrorCode) HandleError!Action {
        const body = try self.errorJson(code);
        defer self.allocator.free(body);
        return .{ .reply = try self.encodeSmall(.response, request_id, 0, body) };
    }

    const FrameError = error{ OutOfMemory, PayloadTooLarge };

    fn encodeWithFlags(self: *Connection, kind: protocol.Kind, request_id: u64, stream_id: u64, flags: u32, payload: []const u8) FrameError![]u8 {
        return framing.encodeFrame(self.allocator, .{ .kind = kind, .request_id = request_id, .stream_id = stream_id, .flags = flags }, payload) catch |e| switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.PayloadTooLarge => error.PayloadTooLarge,
            // encodeFrame은 직렬화만 하므로 decode 계열(magic·unknown kind) error를 낼 수 없다.
            error.BadMagic, error.UnknownRequiredFrame => unreachable,
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

/// runtime metadata의 wire 표현(redacted — output/scrollback·cwd·command는 싣지 않는다, §11). hex id는 caller가 소유.
const RuntimeMetaWire = struct {
    runtime_id: []const u8,
    cols: u16,
    rows: u16,
    resize_generation: u64,
    has_controller: bool,
    observer_count: usize,
};

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

fn intField(obj: std.json.ObjectMap, key: []const u8) ?u16 {
    return switch (obj.get(key) orelse return null) {
        .integer => |n| if (n >= 0 and n <= std.math.maxInt(u16)) @intCast(n) else null,
        else => null,
    };
}

/// stream_id·client_sequence(u64) 필드. std.json integer는 i64라 음수만 거른다 — host 발급 값은 작아 표현 범위 안이다.
fn intFieldU64(obj: std.json.ObjectMap, key: []const u8) ?u64 {
    return switch (obj.get(key) orelse return null) {
        .integer => |n| if (n >= 0) @intCast(n) else null,
        else => null,
    };
}

/// signed i64 필드(§6a core_command arg — scroll delta는 음수 가능). std.json integer가 그대로 i64다.
fn intFieldI64(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    return switch (obj.get(key) orelse return null) {
        .integer => |n| n,
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

fn parseAttachMode(s: ?[]const u8) reg.AttachMode {
    const v = s orelse return .observer;
    if (std.mem.eql(u8, v, "controller")) return .controller;
    if (std.mem.eql(u8, v, "takeover")) return .takeover;
    return .observer;
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
    return .unknown;
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
        .reply, .reply_and_close => |bytes| {
            defer allocator.free(bytes);
            var rp = framing.FrameParser.init(allocator);
            defer rp.deinit();
            try rp.push(bytes);
            const out = (try rp.next()).?; // caller가 out.deinit
            return .{ .action = if (action == .reply) "reply" else "reply_and_close", .frame = out };
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
    try testing.expect(std.mem.indexOf(u8, r.frame.?.payload, "\"runtime_selected_text_v1\"") != null);
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

test "server: oversize result replies payload_too_large instead of dropping the connection" {
    const allocator = testing.allocator;
    var registry = reg.TerminalRuntimeRegistry.init(allocator);
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
const FakeRuntimeOps = struct {
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
    delta_base_seen: [64]u8 = undefined,
    delta_base_seen_len: usize = 0,
    last_core_command: ?core_command_wire.Command = null,
    core_command_runtime: u128 = 0,
    core_command_failure: bool = false,
    last_mouse_report: ?MouseReport = null,
    last_select_span: SelectSpan = .{ .sr = 0, .sc = 0, .er = 0, .ec = 0, .block = false },
    selected_text_runtime: u128 = 0,
    last_select_op: [16]u8 = undefined,
    last_select_op_len: usize = 0,
    last_select_op_row: u16 = 0,
    last_select_op_col: u16 = 0,
    last_find_query_hex: [64]u8 = undefined,
    last_find_query_hex_len: usize = 0,
    last_find_cur: u32 = 0,
    last_find_scroll: bool = false,
    observation_version: u8 = 0,

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
        self.spawn_zdotdir_seen = params.zdotdir != null;
        self.spawn_ssh_bin_seen = params.ssh_integration_bin != null;
        self.spawn_pane_id = params.pane_id;
        self.spawn_initial_config = params.initial_config;
        return self.next_id;
    }
    fn terminateFn(ctx: *anyopaque, id: u128) void {
        const self: *FakeRuntimeOps = @ptrCast(@alignCast(ctx));
        self.terminated_id = id;
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
        self.resized_cols = cols;
        self.resized_rows = rows;
        self.resized_runtime = runtime_id;
    }
    /// 고정 snapshot 바이트를 caller 소유로 돌려준다(server가 이걸 snapshot_chunk로 나눠 보낸다).
    fn snapshotFn(ctx: *anyopaque, runtime_id: u128, allocator: std.mem.Allocator) anyerror![]u8 {
        _ = ctx;
        _ = runtime_id;
        return allocator.dupe(u8, "SNAPSHOT-BYTES");
    }
    /// 받은 base를 기록하고 고정 delta + 새 base를 돌려준다(둘 다 별개 owned 버퍼). delta 라우팅·base 갱신을 검증한다.
    fn deltaFn(ctx: *anyopaque, runtime_id: u128, base: []const u8, allocator: std.mem.Allocator) anyerror!StreamUpdate {
        const self: *FakeRuntimeOps = @ptrCast(@alignCast(ctx));
        _ = runtime_id;
        const n = @min(base.len, self.delta_base_seen.len);
        @memcpy(self.delta_base_seen[0..n], base[0..n]);
        self.delta_base_seen_len = n;
        const send = try allocator.dupe(u8, "DELTA-BYTES");
        errdefer allocator.free(send);
        const new_base = try allocator.dupe(u8, "NEW-BASE");
        return .{ .send = send, .is_snapshot = false, .new_base = new_base };
    }
    /// 대기 알림 없음(빈 title/body)을 돌려준다 — 기본 fake. server dispatch 배선만 검증(실 core 파싱은 runtime_manager smoke).
    fn notificationFn(ctx: *anyopaque, runtime_id: u128, allocator: std.mem.Allocator) anyerror![]u8 {
        _ = ctx;
        _ = runtime_id;
        return allocator.dupe(u8, "{\"title\":\"\",\"body\":\"\"}");
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
    /// 받은 (op,row,col)을 기록하고 고정 span을 준다 — server 라우팅·파싱 검증(실 경계 계산은 runtime_manager smoke).
    fn selectOpFn(ctx: *anyopaque, runtime_id: u128, op: []const u8, row: u16, col: u16, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *FakeRuntimeOps = @ptrCast(@alignCast(ctx));
        _ = runtime_id;
        const n = @min(op.len, self.last_select_op.len);
        @memcpy(self.last_select_op[0..n], op[0..n]);
        self.last_select_op_len = n;
        self.last_select_op_row = row;
        self.last_select_op_col = col;
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
        const cwd = try allocator.dupe(u8, if (self.observation_version == 0) "/tmp/project" else "/tmp/project-next");
        errdefer allocator.free(cwd);
        const title = try allocator.dupe(u8, "project");
        errdefer allocator.free(title);
        const dest = try allocator.dupe(u8, "workbox");
        errdefer allocator.free(dest);
        const processes = try allocator.alloc(RuntimeObservation.Process, 0);
        errdefer allocator.free(processes);
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
            .bracketed_paste = false,
            .observer_generation = 7,
            .title_generation = 3,
            .cols = 80,
            .rows = 24,
            .foreground_available = true,
            .foreground_pgid = 42,
            .processes = processes,
        };
    }
    fn ops(self: *FakeRuntimeOps) RuntimeOps {
        return .{ .ctx = self, .spawn = spawnFn, .terminate = terminateFn, .write_input = writeInputFn, .resize = resizeFn, .snapshot = snapshotFn, .delta = deltaFn, .notification = notificationFn, .core_command = coreCommandFn, .selected_text = selectedTextFn, .select_op = selectOpFn, .find = findFn, .observation = observationFn, .report_mouse = reportMouseFn };
    }
};

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
        try testing.expect(std.mem.indexOf(u8, frames[0].payload, "\"metadata_revision\":0") != null);
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
        const r = try feedJson(&conn, .request, 3, "{\"method\":\"runtime.select_op\",\"params\":{\"stream_id\":1,\"op\":\"word\",\"row\":1,\"col\":2}}");
        defer if (r.frame) |f| f.deinit(allocator);
        try testing.expect(std.mem.indexOf(u8, r.frame.?.payload, "\"sel\":true") != null);
        try testing.expect(std.mem.indexOf(u8, r.frame.?.payload, "\"ec\":3") != null);
    }
    try testing.expectEqualStrings("word", fake.last_select_op[0..fake.last_select_op_len]);
    try testing.expectEqual(@as(u16, 1), fake.last_select_op_row);
    try testing.expectEqual(@as(u16, 2), fake.last_select_op_col);

    // 모르는 stream_id → invalid_request.
    {
        const r = try feedJson(&conn, .request, 4, "{\"method\":\"runtime.select_op\",\"params\":{\"stream_id\":99,\"op\":\"line\",\"row\":0,\"col\":0}}");
        defer if (r.frame) |f| f.deinit(allocator);
        try testing.expect(std.mem.indexOf(u8, r.frame.?.payload, "invalid_request") != null);
    }
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
