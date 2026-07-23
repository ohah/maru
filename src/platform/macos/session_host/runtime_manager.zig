//! session-host **실 runtime 소유자**(`RuntimeManager`) — server.zig의 `RuntimeOps` seam을 실제 PTY runtime으로
//! 구현한다(§4·§13) — P3-e2b.
//!
//! P2에서 만든 `app.InProcessTermBackend`(=`TermRuntimeBackend` 계약의 in-process 구현)를 **그대로 재사용**한다.
//! host는 앱 프로세스가 아니지만 runtime 소유(PTY fork·reader·surface 코어)는 앱과 동일한 자원이라, `LiveSurfaceRegistry`+
//! `SurfaceRuntime`+`LivePtySession` 스택을 새로 만들지 않고 계약 뒤로 재사용한다(layering-and-portability.md §3.1
//! "src/app = 이식 시 재사용하는 OS 중립 공통 runtime"; SSOT — reader 동시성·수명 로직을 복제하지 않는다).
//!
//! ID 매핑(§4): server/wire는 128-bit `runtime_id`로 runtime을 가리키고, in-process backend는 u64 `RuntimeHandle`
//! (=surface handle)로 가리킨다. 이 매니저가 그 경계를 잇는다 — spawn마다 단조 증가 handle을 발급해 backend에 넘기고,
//! 무작위 `runtime_id`를 발급해 host `TerminalRuntimeRegistry`(재접속 조회·capability state)에 등록한 뒤, 그 entry의
//! opaque `runtime` 슬롯(그 목적이 "실 runtime handle 보관")에 handle을 실어 둔다. terminate는 그 슬롯에서 handle을
//! 되읽어 backend 수명을 끝낸다. 별도 side map이 없다.
//!
//! macOS 전용(실 forkpty·arc4random). server.zig(codec·순수)는 이 파일을 모르고 `RuntimeOps` 중립 vtable만 안다 —
//! 그래서 codec은 platform-import-0로 남고, 실 runtime 소유는 이 platform 경계 파일에 갇힌다. `maru`는 named module
//! import라(exe/test 모듈이 maru를 의존) codec 순수성과 무관하다.
//!
//! e2b 범위: spawn(실 PTY + reader) + terminate(clean teardown)까지다. attach 입력/resize(e2c)와 snapshot/delta
//! stream demux(e2d), host-backed `TermRuntimeBackend`(e2e)는 후속이다. 그래서 spawn은 output을 core에 반영하는
//! reader만 시작하고(process_in_reader=true), 화면 stream은 아직 내보내지 않는다.

const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const server = @import("server.zig");
const reg = @import("registry.zig");
const screen_snapshot = @import("screen_snapshot.zig");
const screen_stream = @import("screen_stream.zig");
const core_command = maru.session.core_command; // §6a 원격 스크롤 명령을 host core에 적용
const terminal = maru.terminal; // §6c 원격 검색(Match) 등

const InProcessTermBackend = maru.app.InProcessTermBackend;
const LiveRegistry = maru.app.in_process_term_backend.LiveRegistry;
const SurfaceRuntime = maru.app.SurfaceRuntime;
const RuntimeHandle = maru.app.TermRuntimeHandle;
const ForegroundProcessName = maru.pty.types.ForegroundProcessName;

// host runtime의 PTY→core 이벤트 큐 용량. 제품 경로(app_session.default_queue_capacity)와 같은 16으로 맞춰
// 재접속한 GUI가 in-process와 같은 backpressure를 보게 한다(e2d stream이 이 큐를 소비).
const default_queue_capacity: usize = 16;
const foreground_refresh_ns: i128 = 500 * std.time.ns_per_ms;

const ForegroundCache = struct {
    names: [64]ForegroundProcessName = undefined,
    count: usize = 0,
    pgid: ?i32 = null,
    refreshed_at_ns: i128 = 0,
};

// macOS libc CSPRNG(std.posix 미노출 — 이 파일은 macOS 전용). runtime_id 발급용.
extern "c" fn arc4random_buf(buf: [*]u8, nbytes: usize) void;

/// hex 문자열을 바이트로 디코드해 `out`에 채우고 채운 길이를 돌려준다(§6c 검색어 — 임의 텍스트라 hex로 실어 escape 회피).
/// 홀수/잘못된 hex나 `out` 초과는 거기서 멈춘다(best-effort — 검색어는 부가 기능).
fn hexDecodeInto(hex: []const u8, out: []u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i + 2 <= hex.len and n < out.len) : (i += 2) {
        out[n] = std.fmt.parseInt(u8, hex[i .. i + 2], 16) catch break;
        n += 1;
    }
    return n;
}

/// host가 소유하는 실 terminal runtime 표. `RuntimeOps`를 통해 server.zig가 이걸 구동한다. self-referential이라
/// **in-place `init`**을 쓴다(caller가 `var m: RuntimeManager = undefined; m.init(...)`) — backend가 아래 두 registry의
/// 안정 주소를 캡처하므로 init 후 매니저를 이동하면 안 된다.
pub const RuntimeManager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// 앱과 동일한 소유 스택 — 이 매니저가 **소유**한다(host 수명). backend가 아래 두 필드의 주소를 든다.
    live_registry: LiveRegistry,
    surface_runtime: SurfaceRuntime,
    backend_impl: InProcessTermBackend,
    /// host의 runtime_id 키드 표. 이 매니저가 아니라 daemon이 소유한다(SocketServer도 참조) — 여기선 등록/해제만 한다.
    host_registry: *reg.TerminalRuntimeRegistry,
    /// 다음 in-process handle. 1부터 발급한다 — 0은 opaque 슬롯의 null과 겹치므로 handle로 쓰지 않는다.
    next_handle: RuntimeHandle = 1,
    /// observation은 client/창/stream마다 100ms cadence로 호출될 수 있지만 OS process 열거는 runtime당 최대 2Hz다.
    /// cwd/title/OSC 상태는 계속 100ms full-state로 읽고, 비싼 foreground syscall 결과만 공유 cache한다.
    foreground_cache: std.AutoHashMapUnmanaged(RuntimeHandle, ForegroundCache) = .empty,

    /// self-referential 필드를 안정 주소로 세운다. caller가 준 `*RuntimeManager` 슬롯을 채운다(반환 이동 없음).
    pub fn init(self: *RuntimeManager, allocator: std.mem.Allocator, io: std.Io, host_registry: *reg.TerminalRuntimeRegistry) void {
        self.allocator = allocator;
        self.io = io;
        self.live_registry = LiveRegistry.init(allocator);
        self.surface_runtime = SurfaceRuntime.init(allocator);
        self.backend_impl = InProcessTermBackend.init(allocator, io, &self.live_registry, &self.surface_runtime);
        self.host_registry = host_registry;
        self.next_handle = 1;
        self.foreground_cache = .empty;
    }

    /// 소유 registry를 해제한다. **호출 전 모든 runtime이 terminate돼 있어야** 한다(reader join·슬롯 회수가 terminate에서
    /// 일어난다) — 남은 runtime이 있으면 reader 스레드가 join되지 않은 채 슬롯이 사라진다. graceful 종료 경로(§6)가 붙기
    /// 전까지 host는 SIGTERM으로 내려가 OS가 자식·스레드를 회수하므로 이 deinit은 clean-return 경로용이다.
    pub fn deinit(self: *RuntimeManager) void {
        self.foreground_cache.deinit(self.allocator);
        self.surface_runtime.deinit();
        self.live_registry.deinit();
        self.* = undefined;
    }

    /// server.zig가 dispatch에 넘길 중립 vtable. `ctx`는 이 매니저다.
    pub fn runtimeOps(self: *RuntimeManager) server.RuntimeOps {
        return .{ .ctx = self, .spawn = spawnOp, .terminate = terminateOp, .write_input = writeInputOp, .resize = resizeOp, .snapshot = snapshotOp, .delta = deltaOp, .notification = notificationOp, .core_command = coreCommandOp, .selected_text = selectedTextOp, .select_op = selectOpOp, .find = findOp, .observation = observationOp, .report_mouse = reportMouseOp };
    }

    fn spawnOp(ctx: *anyopaque, params: server.RuntimeSpawnParams) anyerror!u128 {
        const self: *RuntimeManager = @ptrCast(@alignCast(ctx));
        return self.spawnRuntime(params);
    }

    fn terminateOp(ctx: *anyopaque, runtime_id: u128) void {
        const self: *RuntimeManager = @ptrCast(@alignCast(ctx));
        self.terminateRuntime(runtime_id);
    }

    fn writeInputOp(ctx: *anyopaque, runtime_id: u128, bytes: []const u8) anyerror!void {
        const self: *RuntimeManager = @ptrCast(@alignCast(ctx));
        const handle = self.handleFor(runtime_id) orelse return error.RuntimeNotFound;
        return self.backend_impl.backend().writeInput(handle, bytes);
    }

    fn resizeOp(ctx: *anyopaque, runtime_id: u128, cols: u16, rows: u16) anyerror!void {
        const self: *RuntimeManager = @ptrCast(@alignCast(ctx));
        const handle = self.handleFor(runtime_id) orelse return error.RuntimeNotFound;
        return self.backend_impl.backend().resize(handle, .{ .cols = cols, .rows = rows }, self.io);
    }

    /// host 실제 core/PTY에서 화면 외 runtime 관측을 한 번에 owned copy한다. foreground syscall은 runtime별 500ms
    /// cache로 core lock 밖에서 수행하고, cwd/title/semantic/input modes/OSC5379는 reader와 같은 core lock 아래에서 복사한다.
    /// 1회성 agent progress는 multi-subscriber wire에서 제외한다.
    fn observationOp(ctx: *anyopaque, runtime_id: u128, allocator: std.mem.Allocator) anyerror!server.RuntimeObservation {
        const self: *RuntimeManager = @ptrCast(@alignCast(ctx));
        const handle = self.handleFor(runtime_id) orelse return error.RuntimeNotFound;
        const surface = self.backend_impl.surfaceFor(handle) orelse return error.RuntimeNotFound;
        const be = self.backend_impl.backend();

        const cache_gop = try self.foreground_cache.getOrPut(self.allocator, handle);
        if (!cache_gop.found_existing) cache_gop.value_ptr.* = .{};
        const foreground = cache_gop.value_ptr;
        const now_ns = std.Io.Clock.awake.now(self.io).nanoseconds;
        if (foreground.refreshed_at_ns == 0 or now_ns - foreground.refreshed_at_ns >= foreground_refresh_ns) {
            foreground.count = be.foregroundProcessNames(handle, &foreground.names);
            foreground.pgid = be.foregroundProcessGroup(handle);
            foreground.refreshed_at_ns = now_ns;
        }
        const process_count = foreground.count;
        const foreground_pgid = foreground.pgid;
        const processes = try allocator.alloc(server.RuntimeObservation.Process, process_count);
        var process_names_initialized: usize = 0;
        errdefer {
            for (processes[0..process_names_initialized]) |p| allocator.free(p.name);
            allocator.free(processes);
        }
        for (foreground.names[0..process_count], 0..) |p, i| {
            processes[i] = .{ .pid = p.pid, .name = try allocator.dupe(u8, p.slice()) };
            process_names_initialized += 1;
        }

        surface.lockCore(self.io);
        defer surface.unlockCore(self.io);
        const core = &surface.core;
        const cwd = try allocator.dupe(u8, core.currentCwd());
        errdefer allocator.free(cwd);
        const title = try allocator.dupe(u8, core.windowTitle());
        errdefer allocator.free(title);
        const ssh_dest: ?[]u8 = if (core.sshRemoteDest()) |dest| try allocator.dupe(u8, dest) else null;
        errdefer if (ssh_dest) |dest| allocator.free(dest);
        const result = server.RuntimeObservation{
            .cwd = cwd,
            .window_title = title,
            .ssh_remote_dest = ssh_dest,
            .semantic_state = @intFromEnum(core.semantic_state),
            .alt_active = core.alt_active,
            .app_cursor_keys = core.application_cursor_keys,
            .alternate_scroll = core.alternate_scroll,
            .mouse_tracking = core.mouse_tracking != .none,
            .observer_generation = core.observerGeneration(),
            .title_generation = core.title_generation.load(.monotonic),
            .cols = core.size.cols,
            .rows = core.size.rows,
            .foreground_available = true,
            .foreground_pgid = foreground_pgid,
            .processes = processes,
        };
        return result;
    }

    /// runtime의 현재 화면을 screen_stream 레코드 스트림으로 투영한다(§12, P3-e2d). reader 스레드가 core를 쓰므로
    /// **core_mutex를 잡은 채** 투영하고(투영이 grapheme·색을 소유 버퍼로 복사), 반환된 소유 바이트만 unlock 뒤 caller가
    /// snapshot_chunk로 나눠 보낸다(io-render-threading.md — snapshot 슬라이스는 core alias라 lock 밖으로 새면 안 됨).
    fn snapshotOp(ctx: *anyopaque, runtime_id: u128, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *RuntimeManager = @ptrCast(@alignCast(ctx));
        const handle = self.handleFor(runtime_id) orelse return error.RuntimeNotFound;
        const surface = self.backend_impl.surfaceFor(handle) orelse return error.RuntimeNotFound;
        const generation = if (self.host_registry.get(runtime_id)) |e| e.resize_generation else 0;
        surface.lockCore(self.io);
        defer surface.unlockCore(self.io);
        return screen_snapshot.projectSnapshot(allocator, &surface.core, .{ .generation = generation });
    }

    /// `base`(client가 마지막으로 받은 full snapshot) 대비 현재 화면 변화를 계산한다(§9 delta). core lock 아래에서 현재
    /// full snapshot(다음 base)과 delta를 함께 만든다. grid/alt-screen 변화면 delta 대신 fresh snapshot을 보낸다(client가
    /// 화면 교체). `send`와 `new_base`는 항상 별개 버퍼다(caller가 둘 다 free해도 안전).
    fn deltaOp(ctx: *anyopaque, runtime_id: u128, base: []const u8, allocator: std.mem.Allocator) anyerror!server.StreamUpdate {
        const self: *RuntimeManager = @ptrCast(@alignCast(ctx));
        const handle = self.handleFor(runtime_id) orelse return error.RuntimeNotFound;
        const surface = self.backend_impl.surfaceFor(handle) orelse return error.RuntimeNotFound;
        const generation = if (self.host_registry.get(runtime_id)) |e| e.resize_generation else 0;
        const opts = screen_snapshot.ProjectOptions{ .generation = generation };
        surface.lockCore(self.io);
        defer surface.unlockCore(self.io);

        // computeDelta가 delta와 새 base(현재 full snapshot)를 **한 번의 row build로** 함께 준다(재투영 없음).
        const result = screen_snapshot.computeDelta(allocator, base, &surface.core, opts) catch |e| switch (e) {
            error.SnapshotRequired => {
                // grid/alt 변화 → delta 불가, fresh snapshot을 보낸다. send는 new_base와 별개 버퍼여야 하므로 복사한다.
                const snap = try screen_snapshot.projectSnapshot(allocator, &surface.core, opts);
                errdefer allocator.free(snap);
                const send = allocator.dupe(u8, snap) catch return error.OutOfMemory;
                return .{ .send = send, .is_snapshot = true, .new_base = snap };
            },
            else => return e,
        };
        return .{ .send = result.delta, .is_snapshot = false, .new_base = result.snapshot };
    }

    /// runtime의 대기 중인 OSC 9/777 데스크톱 알림을 빼서 JSON `{title, body}`로 준다(§6.32). host의 `TerminalCore`가
    /// 파싱해 둔 title/body를 **core lock 아래** 읽고 clearNotification한다(reader 스레드가 core를 쓰므로, snapshot과 동일한
    /// off-thread 동기화). 없으면 `{title:"",body:""}`. title/body는 임의 바이트라 실 JSON encoder로 escape한다.
    fn notificationOp(ctx: *anyopaque, runtime_id: u128, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *RuntimeManager = @ptrCast(@alignCast(ctx));
        const handle = self.handleFor(runtime_id) orelse return error.RuntimeNotFound;
        const surface = self.backend_impl.surfaceFor(handle) orelse return error.RuntimeNotFound;
        surface.lockCore(self.io);
        defer surface.unlockCore(self.io);
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        if (surface.core.pendingNotification()) |n| {
            js.write(.{ .title = n.title, .body = n.body }) catch return error.OutOfMemory;
            surface.core.clearNotification(); // drain — 다음 조회는 없음.
        } else {
            js.write(.{ .title = "", .body = "" }) catch return error.OutOfMemory;
        }
        return allocator.dupe(u8, out.written()) catch return error.OutOfMemory;
    }

    /// 원격 client가 보낸 **스크롤 core command**를 host의 TerminalCore에 적용한다(§6a 원격 스크롤백). host가 core를 소유하고
    /// view_offset을 바꾸면 다음 projectSnapshot/computeDelta(renderSnapshot=뷰포트 인지)가 그 스크롤 화면을 client에 투영한다.
    /// `op`는 scroll 계열 태그, `arg`는 정수 인자(delta/절대행/offset). core를 쓰므로 **core lock 아래** 적용한다(reader와 단일
    /// mutator 동기화 — snapshot과 동일). 선택(select_*)·config는 후속(#6b) — 알 수 없는 op은 조용히 무시한다.
    fn coreCommandOp(ctx: *anyopaque, runtime_id: u128, op: []const u8, arg: i64) anyerror!void {
        const self: *RuntimeManager = @ptrCast(@alignCast(ctx));
        const handle = self.handleFor(runtime_id) orelse return error.RuntimeNotFound;
        const surface = self.backend_impl.surfaceFor(handle) orelse return error.RuntimeNotFound;
        const nonneg: usize = @intCast(@max(arg, 0)); // 절대행/offset은 음수 불가(악성/버그 client 방어 — @intCast 패닉 회피).
        const cmd: core_command.CoreCommand = if (std.mem.eql(u8, op, "scroll"))
            .{ .scroll = @intCast(arg) }
        else if (std.mem.eql(u8, op, "scroll_to_bottom"))
            .scroll_to_bottom
        else if (std.mem.eql(u8, op, "scroll_to_abs"))
            .{ .scroll_to_abs = nonneg }
        else if (std.mem.eql(u8, op, "scroll_to_offset"))
            .{ .scroll_to_offset = nonneg }
        else
            return; // 미지원 op(선택/config #6b) — 무시.
        surface.lockCore(self.io);
        defer surface.unlockCore(self.io);
        core_command.apply(&surface.core, cmd);
    }

    /// host-backed 마우스 리포트(§ 입력 패리티): client 마우스 이벤트를 host의 **reader에 report_mouse core command로
    /// enqueue**한다 — reader가 적용하면 core가 자기 mouse_tracking/format으로 SGR/x10 응답을 만들고, reader가 그
    /// pendingResponse를 PTY로 흘린다(로컬 휠·클릭 경로와 **동형**: enqueueCoreCommand→reader 적용+flush). dispatch
    /// 스레드가 직접 apply+writeInput하면 reader의 response PTY-write와 같은 자식-stdin fd에 동시 쓰기(race)가 되므로,
    /// 모든 PTY 입력 쓰기를 reader 단일 스레드로 모은다(§io-render-threading). scroll(응답 없음)은 direct apply로 충분.
    fn reportMouseOp(ctx: *anyopaque, runtime_id: u128, report: server.MouseReport) anyerror!void {
        const self: *RuntimeManager = @ptrCast(@alignCast(ctx));
        const handle = self.handleFor(runtime_id) orelse return error.RuntimeNotFound;
        return self.backend_impl.backend().enqueueCoreCommand(handle, .{ .report_mouse = .{
            .button = report.button,
            .col = report.col,
            .row = report.row,
            .x_px = report.x_px,
            .y_px = report.y_px,
            .pressed = report.pressed,
            .motion = report.motion,
            .mods = report.mods,
        } }, self.io);
    }

    /// 원격 client가 보낸 뷰포트 선택 span을 host core에 적용해 텍스트를 뽑는다(§6b 원격 선택 복사). **로컬과 같은
    /// `extractSelection`** 을 재사용하므로 soft-wrap 이음·블록·스크롤백 걸친 선택까지 충실하다(선택 의미론 단일 출처). host
    /// core의 선택은 평소 미사용(client가 렌더용 span 소유)이라 **core lock 아래 transient set-extract-clear**가 안전하다.
    /// span의 뷰포트 좌표는 host의 현재 view_offset 기준으로 abs 변환된다(selectionStart/Extend가 내부에서). JSON `{text}`(임의
    /// 바이트라 실 encoder로 escape). 추출 실패/빈 선택은 `{text:""}`.
    fn selectedTextOp(ctx: *anyopaque, runtime_id: u128, span: server.SelectSpan, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *RuntimeManager = @ptrCast(@alignCast(ctx));
        const handle = self.handleFor(runtime_id) orelse return error.RuntimeNotFound;
        const surface = self.backend_impl.surfaceFor(handle) orelse return error.RuntimeNotFound;
        surface.lockCore(self.io);
        defer surface.unlockCore(self.io);
        surface.core.selectionStart(span.sr, span.sc);
        if (span.block) surface.core.setSelectionBlock(true);
        surface.core.selectionExtend(span.er, span.ec);
        const extracted = surface.core.extractSelection(allocator) catch null;
        defer if (extracted) |e| allocator.free(e);
        surface.core.selectionClear(); // transient — host core 선택 원복.
        const text: []const u8 = extracted orelse "";
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        js.write(.{ .text = text }) catch return error.OutOfMemory;
        return allocator.dupe(u8, out.written()) catch return error.OutOfMemory;
    }

    /// 단어/줄 선택(§6b-2): host가 **콘텐츠를 아는 자기 core**로 경계를 계산해(`selectWordAt`/`selectLineAt`) 결과 뷰포트 선택
    /// span을 JSON으로 준다. 빈 client placeholder는 경계를 모르므로 host가 계산(선택 의미론 host 단일 출처). span만 계산해
    /// 돌려주고 host core 선택은 원복(transient — client가 그 span을 placeholder에 적용해 하이라이트, 복사는 #6b-1 selected_text).
    /// 구분자(word-separators) forwarding은 후속 — 기본 "" (공백 경계, config 기본값과 일치). 미지원 op·빈 선택은 `{sel:false}`.
    fn selectOpOp(ctx: *anyopaque, runtime_id: u128, op: []const u8, row: u16, col: u16, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *RuntimeManager = @ptrCast(@alignCast(ctx));
        const handle = self.handleFor(runtime_id) orelse return error.RuntimeNotFound;
        const surface = self.backend_impl.surfaceFor(handle) orelse return error.RuntimeNotFound;
        surface.lockCore(self.io);
        defer surface.unlockCore(self.io);
        if (std.mem.eql(u8, op, "word")) {
            surface.core.selectWordAt(row, col, ""); // 기본 공백 경계(구분자 forwarding 후속).
        } else if (std.mem.eql(u8, op, "line")) {
            surface.core.selectLineAt(row);
        } else {
            return allocator.dupe(u8, "{\"sel\":false}") catch return error.OutOfMemory;
        }
        const maybe = surface.core.selectionViewportSpan();
        surface.core.selectionClear(); // transient 원복.
        if (maybe) |sp| {
            return std.fmt.allocPrint(allocator, "{{\"sel\":true,\"sr\":{d},\"sc\":{d},\"er\":{d},\"ec\":{d},\"block\":{}}}", .{ sp.start.row, sp.start.col, sp.end.row, sp.end.col, sp.block }) catch return error.OutOfMemory;
        }
        return allocator.dupe(u8, "{\"sel\":false}") catch return error.OutOfMemory;
    }

    /// 원격 검색(§6c): client가 보낸 검색어(hex)로 host가 **콘텐츠·스크롤백을 아는 자기 core**에서 `findMatches`(로컬과 같은
    /// 함수)로 매치를 찾고, 보이는 매치를 `matchViewportSpan`으로 클립해 `{count, spans:[sr,sc,er,ec,...]}`로 준다(선택과 같이
    /// 검색 의미론 host 단일 출처). count=전체 매치 수, spans=현재 뷰포트에 보이는 매치의 flat 좌표. core lock 아래(findMatches가
    /// 스크롤백 rewrap으로 core mutate).
    fn findOp(ctx: *anyopaque, runtime_id: u128, query_hex: []const u8, cur_index: u32, scroll: bool, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *RuntimeManager = @ptrCast(@alignCast(ctx));
        const handle = self.handleFor(runtime_id) orelse return error.RuntimeNotFound;
        const surface = self.backend_impl.surfaceFor(handle) orelse return error.RuntimeNotFound;
        var qbuf: [512]u8 = undefined;
        const query = qbuf[0..hexDecodeInto(query_hex, &qbuf)];

        surface.lockCore(self.io);
        defer surface.unlockCore(self.io);
        var matches: std.ArrayList(terminal.Match) = .empty;
        defer matches.deinit(allocator);
        surface.core.findMatches(allocator, query, &matches) catch {}; // 실패 시 빈 매치(best-effort).
        // §6c-2 네비: scroll이면 현재 매치(cur_index)의 abs 위치로 host 화면을 이동한다 — client가 그 매치를 보게(view_offset
        // 변화 → 다음 delta로 스크롤 화면 투영). 그 뒤 클립하므로 현재 매치가 보이게 된다.
        if (scroll and cur_index < matches.items.len) {
            surface.core.scrollToAbs(matches.items[cur_index].start.row);
        }

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        var buf: [96]u8 = undefined;
        // cur=현재 매치의 뷰포트 span(보이면 4정수, 안 보이면 빈 배열).
        try out.appendSlice(allocator, try std.fmt.bufPrint(&buf, "{{\"count\":{d},\"cur\":[", .{matches.items.len}));
        if (cur_index < matches.items.len) {
            if (surface.core.matchViewportSpan(matches.items[cur_index])) |cs| {
                try out.appendSlice(allocator, try std.fmt.bufPrint(&buf, "{d},{d},{d},{d}", .{ cs.start.row, cs.start.col, cs.end.row, cs.end.col }));
            }
        }
        // spans=보이는 **비현재** 매치.
        try out.appendSlice(allocator, "],\"spans\":[");
        var first = true;
        for (matches.items, 0..) |m, mi| {
            if (mi == cur_index) continue; // 현재는 cur에 담았다.
            const span = surface.core.matchViewportSpan(m) orelse continue; // 뷰포트 밖 매치는 렌더 안 함.
            if (!first) try out.append(allocator, ',');
            first = false;
            try out.appendSlice(allocator, try std.fmt.bufPrint(&buf, "{d},{d},{d},{d}", .{ span.start.row, span.start.col, span.end.row, span.end.col }));
        }
        try out.appendSlice(allocator, "]}");
        return out.toOwnedSlice(allocator);
    }

    /// runtime_id → in-process handle. registry entry의 opaque 슬롯에서 되읽는다(spawn이 심어 둔 값). 없으면 null.
    fn handleFor(self: *RuntimeManager, runtime_id: u128) ?RuntimeHandle {
        const entry = self.host_registry.get(runtime_id) orelse return null;
        const slot = entry.runtime orelse return null;
        return @intFromPtr(slot);
    }

    /// 실 PTY runtime을 띄운다: backend.spawn(forkpty) → attach(reader 시작) → host registry 등록. `runtime_id`를 돌려준다.
    /// argv/cwd 슬라이스는 backend.spawn이 동기적으로 복사하므로(PtySession.spawn이 dupeZ) transient여도 안전하다.
    /// 에러 집합은 backend(anyerror)를 그대로 전파한다 — `error.EmptyArgv`/`error.IdSpaceExhausted`는 이 매니저 고유.
    fn spawnRuntime(self: *RuntimeManager, params: server.RuntimeSpawnParams) anyerror!u128 {
        if (params.argv.len == 0) return error.EmptyArgv; // server가 이미 거르지만 방어(handle 낭비 방지).
        const handle = self.next_handle;
        const be = self.backend_impl.backend();
        const size = maru.terminal.Size{ .cols = params.cols, .rows = params.rows };
        const args: []const []const u8 = if (params.argv.len > 1) params.argv[1..] else &.{};

        _ = try be.spawn(.{
            .handle = handle,
            .request = .{
                .command = params.argv[0],
                .args = args,
                .cwd = params.cwd,
                .login = params.login,
                .env = params.env,
                .parent_env = params.parent_env,
                .env_overrides = params.env_overrides,
                .term = params.term,
                .zdotdir = params.zdotdir,
                .ssh_integration_bin = params.ssh_integration_bin,
                .pane_id = params.pane_id,
                .size = size,
            },
            .size = size,
            .queue_capacity = default_queue_capacity,
        });
        // 여기부터 실패하면 방금 만든 runtime을 회수한다(closeAndDetach로 PTY/자식/reader 종료 → remove로 reader join+슬롯 해제).
        errdefer {
            be.closeAndDetach(handle);
            be.remove(handle);
        }
        _ = try be.attach(handle, true); // reader 시작. host runtime은 output을 core에 직접 반영한다(stream은 e2d).

        // 무작위 runtime_id를 발급해 host registry에 등록한다. 충돌은 사실상 불가능하지만 방어적으로 재시도한다.
        var attempts: usize = 0;
        while (attempts < 8) : (attempts += 1) {
            const rid = newRuntimeId();
            const entry = self.host_registry.register(rid, params.cols, params.rows) catch |err| switch (err) {
                error.DuplicateRuntime => continue,
                else => return err,
            };
            entry.runtime = @ptrFromInt(handle); // opaque 슬롯에 handle 보관(그 목적: 실 runtime handle). handle>=1이라 non-null.
            self.next_handle += 1;
            return rid;
        }
        return error.IdSpaceExhausted; // 8회 연속 128-bit 충돌 — 도달 불가.
    }

    /// runtime을 종료한다(§8 `runtime end`). 멱등 — 없는 id/handle 미기록은 무시한다. registry entry의 opaque 슬롯에서
    /// handle을 되읽어 backend 수명을 끝내고(closeAndDetach → remove), registry에서 뗀다.
    fn terminateRuntime(self: *RuntimeManager, runtime_id: u128) void {
        const entry = self.host_registry.get(runtime_id) orelse return; // 없는 id — 멱등 no-op.
        const slot = entry.runtime orelse {
            self.host_registry.unregister(runtime_id); // handle 미기록(비정상) — registry만 정리.
            return;
        };
        const handle: RuntimeHandle = @intFromPtr(slot);
        const be = self.backend_impl.backend();
        be.closeAndDetach(handle); // PTY/자식/reader 종료 + routing detach(멱등).
        be.remove(handle); // reader join → surface/live_pty 번들 deinit → 슬롯 회수.
        _ = self.foreground_cache.remove(handle);
        self.host_registry.unregister(runtime_id);
    }
};

/// 128-bit runtime_id를 발급한다(§4 opaque random). macOS `arc4random_buf`는 실패하지 않는 CSPRNG다(daemon.newHostId 대칭).
fn newRuntimeId() u128 {
    var bytes: [16]u8 = undefined;
    arc4random_buf(&bytes, bytes.len);
    return std.mem.readInt(u128, &bytes, .big);
}

// ─────────────────────────────────────────────────────────────────────────────
// process smoke (실 macOS PTY: RuntimeOps로 실 runtime을 띄우고 내린다)
//
// 이 테스트가 증명하는 것(그리고 터미널에서 왜 중요한가): 영속 host의 핵심은 GUI 밖에서 **실 PTY runtime을 소유**하는
// 것이다. server.zig의 read-only 조회를 넘어, `RuntimeOps.spawn`이 실제 forkpty로 셸을 띄워 host registry에 재접속
// 조회 대상으로 노출하고, `terminate`가 그 PTY/자식/reader를 누수 없이 회수하는지 고정한다. testing.allocator가
// 누수를(reader join 실패·슬롯 미회수) 잡는다. 실 forkpty라 macOS opt-in(non-macOS는 barrel에서 제외돼 test 자체가 없다).
// ─────────────────────────────────────────────────────────────────────────────

test "runtime manager: spawns a real PTY runtime through RuntimeOps and terminates it" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var host_registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer host_registry.deinit();

    var mgr: RuntimeManager = undefined;
    mgr.init(allocator, std.testing.io, &host_registry);
    defer mgr.deinit();

    const ops = mgr.runtimeOps();
    // 짧게 종료하는 controlled command를 RuntimeOps.spawn으로 띄운다(실 forkpty). argv는 transient(스택) — spawn이 복사한다.
    const rid = try ops.spawn(ops.ctx, .{
        .argv = &.{ "/bin/sh", "-c", "exit 0" },
        .cwd = null,
        .cols = 40,
        .rows = 10,
    });

    // host registry가 이 runtime을 재접속 조회 대상으로 노출한다(runtime.list/get이 이걸 읽는다).
    try std.testing.expectEqual(@as(usize, 1), host_registry.count());
    const entry = host_registry.get(rid) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 40), entry.cols);
    try std.testing.expect(entry.runtime != null); // opaque 슬롯에 handle이 실려 있다.

    // terminate: PTY/자식/reader를 정리하고 registry에서 제거한다.
    ops.terminate(ops.ctx, rid);
    try std.testing.expectEqual(@as(usize, 0), host_registry.count());
    // 두 번째 terminate는 no-op(없는 id 무시) — 멱등.
    ops.terminate(ops.ctx, rid);
}

test "runtime manager: writeInput and resize reach a real runtime through RuntimeOps" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var host_registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer host_registry.deinit();
    var mgr: RuntimeManager = undefined;
    mgr.init(allocator, std.testing.io, &host_registry);
    defer mgr.deinit();

    const ops = mgr.runtimeOps();
    // cat은 입력 EOF까지 살아 있어 writeInput/resize를 적용할 실 runtime을 준다.
    const rid = try ops.spawn(ops.ctx, .{ .argv = &.{"/bin/cat"}, .cwd = null, .cols = 40, .rows = 10 });

    // writeInput/resize가 실 backend에 에러 없이 위임된다(실제 화면 반영은 e2d stream이 검증). 매니저 resizeOp는 backend
    // 적용만 하고 canonical(registry) 갱신은 server.dispatchResize의 몫이라, 여기선 backend 위임 성공만 본다.
    try ops.write_input(ops.ctx, rid, "hello\n");
    try ops.resize(ops.ctx, rid, 100, 30);

    // 없는 runtime_id는 RuntimeNotFound(다른 runtime으로 새지 않는다).
    try std.testing.expectError(error.RuntimeNotFound, ops.write_input(ops.ctx, 0xDEADBEEF, "x"));
    try std.testing.expectError(error.RuntimeNotFound, ops.resize(ops.ctx, 0xDEADBEEF, 10, 10));

    ops.terminate(ops.ctx, rid);
    try std.testing.expectEqual(@as(usize, 0), host_registry.count());
}

test "runtime manager: snapshot projects the runtime's live screen through RuntimeOps" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var host_registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer host_registry.deinit();
    var mgr: RuntimeManager = undefined;
    mgr.init(allocator, std.testing.io, &host_registry);
    defer mgr.deinit();

    const ops = mgr.runtimeOps();
    const rid = try ops.spawn(ops.ctx, .{ .argv = &.{"/bin/cat"}, .cwd = null, .cols = 24, .rows = 6 });

    // snapshot이 실 core를 lock한 채 투영해 첫 record(screen_meta)에 spawn 크기(24x6)를 담는다.
    const snap = try ops.snapshot(ops.ctx, rid, allocator);
    defer allocator.free(snap);
    var rs = screen_stream.RecordStream{ .bytes = snap };
    const first = (try rs.next()).?;
    const s = try screen_stream.RecordStream.split(first);
    try std.testing.expectEqual(screen_stream.RecordKind.screen_meta, s.header.kind);
    const meta = try screen_stream.decodeScreenMeta(s.body);
    try std.testing.expectEqual(@as(u16, 24), meta.cols);
    try std.testing.expectEqual(@as(u16, 6), meta.rows);

    // 없는 runtime_id는 RuntimeNotFound(다른 runtime으로 새지 않는다).
    try std.testing.expectError(error.RuntimeNotFound, ops.snapshot(ops.ctx, 0xDEADBEEF, allocator));

    ops.terminate(ops.ctx, rid);
}

test "runtime manager: observation exports host-owned cwd title ssh and semantic metadata" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var host_registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer host_registry.deinit();
    var mgr: RuntimeManager = undefined;
    mgr.init(allocator, std.testing.io, &host_registry);
    defer mgr.deinit();

    const ops = mgr.runtimeOps();
    const rid = try ops.spawn(ops.ctx, .{ .argv = &.{"/bin/cat"}, .cwd = null, .cols = 24, .rows = 6 });
    defer ops.terminate(ops.ctx, rid);
    const handle = mgr.handleFor(rid) orelse return error.TestUnexpectedResult;
    const surface = mgr.backend_impl.surfaceFor(handle) orelse return error.TestUnexpectedResult;
    surface.lockCore(std.testing.io);
    surface.core.write(
        "\x1b]7;file://localhost/tmp/metadata-repo\x07" ++
            "\x1b]2;metadata-title\x07" ++
            "\x1b]5379;ssh;user@workbox\x07" ++
            "\x1b]133;C\x07",
    ) catch |err| {
        surface.unlockCore(std.testing.io);
        return err;
    };
    surface.unlockCore(std.testing.io);

    var observation = try ops.observation(ops.ctx, rid, allocator);
    defer observation.deinit(allocator);
    try std.testing.expectEqualStrings("/tmp/metadata-repo", observation.cwd);
    try std.testing.expectEqualStrings("metadata-title", observation.window_title);
    try std.testing.expectEqualStrings("user@workbox", observation.ssh_remote_dest.?);
    try std.testing.expectEqual(@as(u8, @intFromEnum(terminal.SemanticPrompt.command)), observation.semantic_state);
    try std.testing.expect(observation.foreground_available);
}

test "runtime manager: empty argv is rejected before allocating a handle" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var host_registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer host_registry.deinit();
    var mgr: RuntimeManager = undefined;
    mgr.init(allocator, std.testing.io, &host_registry);
    defer mgr.deinit();

    const ops = mgr.runtimeOps();
    try std.testing.expectError(error.EmptyArgv, ops.spawn(ops.ctx, .{ .argv = &.{}, .cwd = null, .cols = 80, .rows = 24 }));
    try std.testing.expectEqual(@as(usize, 0), host_registry.count()); // 실패라 registry에 아무것도 안 남는다.
}
