//! remote_runtime — **client 쪽 원격 runtime**(host runtime의 client-side 상대) — P3-e2e-2c-2.
//!
//! host의 `runtime_manager`(host 프로세스가 실 PTY/`TerminalCore`를 소유)와 대칭이다: 이쪽은 client RPC로 그 host runtime을
//! spawn/제어하고, host가 보내는 snapshot/delta stream을 `RemoteScreen`(조립기+cell 격자)으로 조립해 **원격-backed `Surface`**
//! 로 노출한다. GUI는 이 `Surface`를 in-process runtime과 똑같이 렌더한다(`surface.renderSnapshot()` — SSOT). 즉 이 파일이
//! "원격 runtime = client가 든 Surface 하나"라는 client-side 소유 모델을 만든다.
//!
//! 범위(e2e-2c-2): client-side runtime 소유·제어·화면까지다. P2 `TermRuntimeBackend` **vtable 어댑터**와 GUI **frame-loop
//! pump 배선**(delta stream을 매 프레임 소비, `RuntimeEventPump` 재해석)은 app_session이 프레임 루프를 만지는 **e3**에서 이
//! 위에 얹는다 — 여기 `pumpDelta`는 그 배선이 부를 수 있는 최소 단위(한 delta batch 소비)다. macOS 전용(client·Surface·terminal).

const std = @import("std");
const maru = @import("maru");
const terminal = maru.terminal;
const Surface = maru.session.Surface;
const term_backend = maru.app.term_runtime_backend;
const client_mod = @import("client.zig");
const protocol = @import("protocol.zig");
const remote_screen = @import("remote_screen.zig");
const screen_assembler = @import("screen_assembler.zig");
const observation_wire = @import("observation_wire.zig");
const core_command_wire = @import("core_command_wire.zig");

/// host에서 가져온 대기 OSC 9/777 데스크톱 알림 한 건(§6.32). title/body는 owned(caller가 deinit).
pub const Notification = struct {
    title: []u8,
    body: []u8,
    pub fn deinit(self: Notification, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.body);
    }
};

/// 한 원격 runtime. self-referential(`surface.remote`가 `&self.remote_screen`을 가리킴)이라 **in-place `spawn`**을 쓴다
/// (caller가 `var rr: RemoteRuntime = undefined; try rr.spawn(...)`). spawn 후 이 값을 이동하면 안 된다.
pub const RemoteRuntime = struct {
    client: *client_mod.Client, // borrowed — 여러 runtime이 한 connection을 공유한다(stream_id로 구분).
    allocator: std.mem.Allocator,
    io: std.Io,
    runtime_id_hex: [32]u8, // host 발급 runtime_id(hex) — terminate에 되먹인다.
    stream_id: u64, // attach가 발급한 stream — input/resize/delta 라우팅.
    resize_seq: u64, // 단조 증가 client_sequence — registry가 이하 sequence를 stale로 거부하므로 매 resize마다 올린다.
    // blocking `SurfaceRuntime.writeInput`의 key bytes와 그 사이 core command를 한 시간축으로 보존한다.
    // control.barrier는 그 명령보다 먼저 host에 도착해야 하는 direct_input byte prefix 끝이다.
    direct_input: std.ArrayListUnmanaged(u8),
    direct_input_offset: usize,
    pending_controls: std.ArrayListUnmanaged(PendingControl),
    // shared transport hard failure를 이 runtime surface에 한 번만 투영한다. connection 하나를 여러 runtime이
    // 공유하므로 각 runtime pump가 자기 surface를 exited로 latch하되 매 frame 같은 read_error를 재방출하지 않는다.
    transport_failed: bool,
    observation: term_backend.RuntimeObservation, // host attach/event에서 받은 화면 외 full-state owned cache.
    remote_screen: remote_screen.RemoteScreen, // 조립기+cell 격자(surface의 화면 소스).
    surface: Surface, // 원격-backed(surface.remote = remote_screen.screenSource()). GUI가 이걸 렌더.

    /// host에 runtime을 띄우고(`runtime.spawn`) controller로 attach한 뒤 첫 snapshot을 조립해 원격 Surface를 세운다.
    /// 실패 시 이미 띄운 host runtime을 회수한다(orphan 방지). `argv`/`size`는 spawn할 셸 스펙이다.
    pub fn spawn(
        self: *RemoteRuntime,
        client: *client_mod.Client,
        allocator: std.mem.Allocator,
        io: std.Io,
        surface_id: u64,
        request: maru.pty.SpawnRequest,
        size: terminal.Size,
    ) anyerror!void {
        return self.spawnWithConfig(client, allocator, io, surface_id, request, size, null);
    }

    pub fn spawnWithConfig(
        self: *RemoteRuntime,
        client: *client_mod.Client,
        allocator: std.mem.Allocator,
        io: std.Io,
        surface_id: u64,
        request: maru.pty.SpawnRequest,
        size: terminal.Size,
        initial_config: ?maru.session.core_command.RuntimeConfig,
    ) anyerror!void {
        // origin/main의 구 v2 daemon도 runtime.spawn_full 이름은 알지만 unknown `runtime_config` 필드를 무시한다.
        // 새 config codec과 함께 도입된 capability가 없으면 잘못된 기본값으로 spawn 성공을 가장하지 않고,
        // AppSession이 명시적인 in-process fallback 경로를 선택하게 한다.
        if (initial_config != null and !client.runtime_core_command_v1) return error.UnsupportedSpawnContract;
        self.client = client;
        self.allocator = allocator;
        self.io = io;
        self.resize_seq = 0;
        self.direct_input = .empty;
        self.direct_input_offset = 0;
        self.pending_controls = .empty;
        self.transport_failed = false;
        self.observation = .{};
        errdefer self.observation.deinit(allocator);

        // 1. runtime.spawn_full — host가 확장 spawn 계약으로 실 PTY를 띄우고 runtime_id를 준다.
        const spawn_params = buildSpawnParams(allocator, request, size, initial_config) catch return error.OutOfMemory;
        defer allocator.free(spawn_params);
        // 기존 v2 host가 새 필드를 unknown JSON으로 무시해 다른 셸을 띄우지 않도록 새 method 이름을 쓴다. 구 host는
        // invalid_request로 거부하고 기존 runtime attach는 계속 v2로 가능하다.
        const spawn_resp = try client.call("runtime.spawn_full", spawn_params);
        defer allocator.free(spawn_resp);
        self.runtime_id_hex = client_mod.extractRuntimeId(spawn_resp) orelse {
            if (std.mem.indexOf(u8, spawn_resp, "invalid_request") != null) return error.UnsupportedSpawnContract;
            return error.SpawnFailed;
        };
        // 이 지점부터 실패하면 방금 띄운 host runtime을 회수한다(orphan 방지) — spawn한 건 우리 소유다.
        errdefer self.terminateBestEffort();

        try self.attachAndAssemble(surface_id, size);
    }

    /// **이미 host에 있는 runtime에 재접속**한다(spawn 없이) — GUI를 재실행하면 workspace가 저장한 `runtime_id_hex`로 같은
    /// host runtime에 붙어 화면·PID·scrollback을 잇는다(§7). runtime이 없으면(host 재시작·runtime 종료 등) attach가
    /// `error.AttachFailed`(host RuntimeNotFound → 응답에 stream_id 없음)를 내고, restore caller는 fail-closed한다.
    /// **`spawn`과 달리 실패해도 runtime을 terminate하지 않는다** — 우리가 띄운 게 아니라 pre-existing이므로(남의 runtime을
    /// attach 실패로 죽이면 안 됨). 성공 뒤 이 RemoteRuntime은 spawn한 것과 동일하게 다룬다(input/resize/pump/terminate).
    pub fn attachExisting(
        self: *RemoteRuntime,
        client: *client_mod.Client,
        allocator: std.mem.Allocator,
        io: std.Io,
        surface_id: u64,
        runtime_id_hex: [32]u8,
        size: terminal.Size,
    ) anyerror!void {
        self.client = client;
        self.allocator = allocator;
        self.io = io;
        self.resize_seq = 0;
        self.direct_input = .empty;
        self.direct_input_offset = 0;
        self.pending_controls = .empty;
        self.transport_failed = false;
        self.observation = .{};
        errdefer self.observation.deinit(allocator);
        self.runtime_id_hex = runtime_id_hex;
        // terminate errdefer 없음(pre-existing runtime을 attach 실패로 죽이지 않는다).
        try self.attachAndAssemble(surface_id, size);
    }

    /// spawn/attachExisting 공통(§10 attach 순서): controller attach(stream_id) → 첫 snapshot 조립 → 원격-backed Surface.
    /// `self.runtime_id_hex`가 이미 채워져 있어야 한다(spawn=runtime.spawn 응답, attachExisting=저장된 값).
    fn attachAndAssemble(self: *RemoteRuntime, surface_id: u64, size: terminal.Size) anyerror!void {
        // 2. runtime.attach(controller) — stream_id + snapshot 순서(§10).
        var attach_buf: [96]u8 = undefined;
        const attach_params = std.fmt.bufPrint(&attach_buf, "{{\"runtime_id\":\"{s}\",\"mode\":\"controller\"}}", .{self.runtime_id_hex}) catch return error.AttachFailed;
        const attach_resp = try self.client.call("runtime.attach", attach_params);
        defer self.allocator.free(attach_resp);
        self.stream_id = client_mod.extractU64Field(attach_resp, "\"stream_id\":") orelse return error.AttachFailed;
        // 새 host는 attach response에 current full metadata를 싣는다. 구 host/누락은 attach 자체를 깨지 않고 unavailable로
        // 남겨 GUI가 empty와 혼동하지 않게 한다.
        _ = self.applyObservationJson(attach_resp) catch {};
        // attach RPC가 controller lease를 잡은 뒤 snapshot/화면 조립이 실패하면 caller에는 아직 완성된
        // RemoteRuntime이 없어 detachClientSide를 부를 수 없다. 이 구간에서 반드시 lease와 demux 큐를 되돌린다.
        errdefer {
            self.detachBestEffort();
            self.client.dropBufferedStream(self.stream_id);
            self.stream_id = 0;
        }

        // 3. 첫 snapshot을 읽어 원격 화면을 조립한다.
        const snap = try self.client.readSnapshot(self.stream_id);
        defer self.allocator.free(snap);
        self.remote_screen = try remote_screen.RemoteScreen.init(self.allocator);
        errdefer self.remote_screen.deinit();
        // mode bit 자체는 v2에도 우연히 존재할 수 있으므로 hello_ack에서 명시 협상한 host일 때만 "0 = live bottom"을
        // 신뢰한다. 구 host는 capability=false로 두고, RemoteScreen이 snapshot별 visible cursor 증거만으로
        // legacy live preedit/candidate를 허용한다. hidden/ambiguous snapshot은 계속 fail-closed다.
        self.remote_screen.viewport_scrolled_known = self.client.screen_viewport_scrolled_v1;
        try self.remote_screen.applySnapshot(snap, self.io);

        // 4. 원격-backed Surface를 세운다(로컬 core는 placeholder — 렌더는 remote 소스로 간다).
        self.surface = try Surface.init(self.allocator, surface_id, size);
        self.surface.remote = self.remote_screen.screenSource();
    }

    /// host가 발급한 runtime_id(hex)를 돌려준다 — workspace가 저장해 재실행 시 `attachExisting`으로 재접속한다(§7, e3-5).
    pub fn runtimeIdHex(self: *const RemoteRuntime) [32]u8 {
        return self.runtime_id_hex;
    }

    /// runtime을 종료하고(host `runtime.terminate`) client-side 자원을 회수한다. 멱등 시도(종료 실패는 무시).
    pub fn deinit(self: *RemoteRuntime) void {
        self.client.dropBufferedStream(self.stream_id); // 이 stream 앞으로 남은 demux 배치 회수(더는 pump 안 함 — §멀티 runtime).
        self.terminateBestEffort();
        self.surface.deinit();
        self.remote_screen.deinit();
        self.observation.deinit(self.allocator);
        self.direct_input.deinit(self.allocator);
        self.pending_controls.deinit(self.allocator);
        self.* = undefined;
    }

    /// client-side 자원만 회수한다(surface/screen) — **host runtime은 안 죽인다**(terminate 안 보냄). 앱 quit 시 host-backed
    /// Term을 이걸로 정리하면 runtime이 host에 남아(연결 EOF를 host가 detach로 처리해 유지, §6 app-quit=detach) GUI 재실행 시
    /// `attachExisting`으로 재접속한다. `deinit`과 대칭이되 terminate만 뺀다.
    pub fn detachClientSide(self: *RemoteRuntime) void {
        // shared connection은 앱 종료 전까지 EOF가 오지 않을 수 있다. RPC detach 없이 로컬 객체만 버리면 host의 controller
        // lease가 남아 같은 connection의 재attach가 controller_busy가 되므로 subscription을 먼저 명시 해제한다.
        self.detachBestEffort();
        self.client.dropBufferedStream(self.stream_id); // 이 stream 앞으로 남은 demux 배치 회수(더는 pump 안 함 — §멀티 runtime).
        self.surface.deinit();
        self.remote_screen.deinit();
        self.observation.deinit(self.allocator);
        self.direct_input.deinit(self.allocator);
        self.pending_controls.deinit(self.allocator);
        self.* = undefined;
    }

    /// 렌더/입력 라우팅에 쓸 Surface(GUI가 in-process처럼 다룬다).
    pub fn surfacePtr(self: *RemoteRuntime) *Surface {
        return &self.surface;
    }

    /// terminal input을 host runtime으로 보낸다(controller). 응답 없는 fire-and-forget.
    pub fn sendInput(self: *RemoteRuntime, bytes: []const u8) client_mod.ClientError!void {
        if (bytes.len == 0) return;
        self.compactDirectInput();
        const pending = self.direct_input.items.len - self.direct_input_offset;
        if (bytes.len > max_direct_input_bytes -| pending) return error.OutOfMemory;
        self.direct_input.appendSlice(self.allocator, bytes) catch return error.OutOfMemory;
        // 소유권을 queue가 인수한 뒤에는 backpressure나 frame encode OOM을 오류로 돌려 caller가 같은 key를
        // 실패/재시도 처리하게 하지 않는다. hard connection error만 전파하고 tick이 이어 보낸다.
        _ = try self.pumpQueuedInput();
    }

    /// UI tick의 입력을 client 연결의 bounded pending frame에 맡긴다. 반환값은 wire write량이 아니라 client가 소유권을
    /// 인수한 payload 길이라 caller가 partial socket write를 같은 입력으로 재시도하지 않는다.
    pub fn sendInputNonBlocking(self: *RemoteRuntime, bytes: []const u8) client_mod.ClientError!usize {
        if (!(try self.pumpQueuedInput())) return 0;
        return self.client.sendInputNonBlocking(self.stream_id, bytes);
    }

    /// AppKit callback-safe live-bottom 요청. socket read/blocking write를 하지 않고 stream-local intent만
    /// bounded control FIFO에 넣은 뒤 DONTWAIT admission을 한 번 시도한다. 같은 byte barrier의 연속 scroll은
    /// coalesce하고, 슬롯이 다른 frame으로 막혔으면 tick/input 경로가 다시 시도한다.
    pub fn requestScrollToBottom(self: *RemoteRuntime) client_mod.ClientError!void {
        if (!self.client.async_scroll_to_bottom_v1) return;
        const barrier = self.direct_input.items.len;
        if (self.pending_controls.items.len > 0) {
            const last = self.pending_controls.items[self.pending_controls.items.len - 1];
            if (last.barrier == barrier and last.op == .scroll_to_bottom) {
                _ = try self.pumpQueuedInput();
                return;
            }
        }
        if (self.pending_controls.items.len >= max_pending_controls) return self.failControlAdmission();
        self.pending_controls.append(self.allocator, .{ .barrier = barrier, .op = .scroll_to_bottom }) catch
            return self.failControlAdmission();
        _ = try self.pumpQueuedInput();
    }

    /// focus/config/prompt 등 host-authoritative 명령을 input과 같은 stream-local 시간축에 넣는다. queue가 인수한 뒤
    /// socket backpressure가 생겨도 다음 frame tick이 재시도하며, bounded cap을 넘으면 명시적으로 실패한다.
    pub fn queueCoreCommand(self: *RemoteRuntime, command: core_command_wire.Command) client_mod.ClientError!void {
        if (!self.client.runtime_core_command_v1) {
            if (command.isLegacyScroll()) return self.sendCoreCommandBlocking(command);
            return;
        }
        if (self.pending_controls.items.len >= max_pending_controls) return self.failControlAdmission();
        self.pending_controls.append(self.allocator, .{
            .barrier = self.direct_input.items.len,
            .op = .{ .core_command = command },
        }) catch return self.failControlAdmission();
        _ = try self.pumpQueuedInput();
    }

    const max_direct_input_bytes: usize = 64 * 1024;
    const max_pending_controls: usize = 64;

    fn failControlAdmission(self: *RemoteRuntime) client_mod.ClientError!void {
        // cap 초과뿐 아니라 queue allocation OOM도 caller가 UI best-effort로 삼키면 최종 focus/config 상태가
        // 조용히 유실된다. 이 stream만 복구할 ACK가 없으므로 shared connection을 poison해 다음 pump가
        // 명시적 disconnect와 surface exit latch를 관측하게 한다.
        self.client.failClosed();
        return error.ConnectionClosed;
    }

    const PendingControl = struct {
        barrier: usize,
        op: union(enum) {
            scroll_to_bottom,
            core_command: core_command_wire.Command,
        },
    };

    fn admitControl(self: *RemoteRuntime, control: PendingControl) client_mod.ClientError!bool {
        return switch (control.op) {
            .scroll_to_bottom => self.client.sendScrollToBottomNonBlocking(self.stream_id) catch |err| switch (err) {
                error.OutOfMemory => false,
                else => return err,
            },
            .core_command => |command| blk: {
                const params = core_command_wire.encodeParams(self.allocator, self.stream_id, command) catch break :blk false;
                defer self.allocator.free(params);
                break :blk self.client.sendCoreCommandNonBlocking(self.stream_id, params) catch |err| switch (err) {
                    error.OutOfMemory => false,
                    else => return err,
                };
            },
        };
    }

    fn compactDirectInput(self: *RemoteRuntime) void {
        if (self.direct_input_offset == 0) return;
        // 모든 control barrier는 아직 소비하지 않은 byte suffix 안에 있다. suffix를 앞으로 당길 때 같은 양만큼
        // 보정해 input→control→input 시간 위치를 보존한다.
        const consumed = self.direct_input_offset;
        const remaining = self.direct_input.items[consumed..];
        std.mem.copyForwards(u8, self.direct_input.items[0..remaining.len], remaining);
        self.direct_input.items.len = remaining.len;
        for (self.pending_controls.items) |*control| {
            std.debug.assert(control.barrier >= consumed);
            control.barrier -= consumed;
        }
        self.direct_input_offset = 0;
    }

    /// 직접 key FIFO와 control FIFO를 단일 시간 순서로 Client outbound에 넘긴다.
    /// 반환 false는 socket backpressure로 아직 queue/barrier가 남았다는 뜻이며 데이터 소유권은 유지된다.
    fn pumpQueuedInput(self: *RemoteRuntime) client_mod.ClientError!bool {
        while (true) {
            if (self.pending_controls.items.len > 0) {
                const control = self.pending_controls.items[0];
                const barrier = control.barrier;
                if (self.direct_input_offset < barrier) {
                    const accepted = self.client.sendInputNonBlocking(
                        self.stream_id,
                        self.direct_input.items[self.direct_input_offset..barrier],
                    ) catch |err| switch (err) {
                        error.OutOfMemory => return false,
                        else => return err,
                    };
                    if (accepted == 0) return false;
                    self.direct_input_offset += accepted;
                    continue;
                }
                if (!(try self.admitControl(control))) return false;
                _ = self.pending_controls.orderedRemove(0);
                continue;
            }
            if (self.direct_input_offset < self.direct_input.items.len) {
                const accepted = self.client.sendInputNonBlocking(
                    self.stream_id,
                    self.direct_input.items[self.direct_input_offset..],
                ) catch |err| switch (err) {
                    error.OutOfMemory => return false,
                    else => return err,
                };
                if (accepted == 0) return false;
                self.direct_input_offset += accepted;
                continue;
            }
            self.direct_input.clearRetainingCapacity();
            self.direct_input_offset = 0;
            return true;
        }
    }

    /// 이 runtime이 이미 소유한 key/control barrier를 blocking RPC보다 먼저 전송한다. RemoteRuntime의 FIFO와
    /// Client의 connection-level pending frame이라는 두 ownership 층 사이에서 mouse/core/resize RPC가 key를
    /// 추월하지 않게 하는 단일 경계다. 각 blocking RPC는 원래도 Client.call에서 pending socket write를 기다린다.
    fn flushQueuedInputBlocking(self: *RemoteRuntime) client_mod.ClientError!void {
        while (true) {
            if (self.pending_controls.items.len > 0) {
                const control = self.pending_controls.items[0];
                const barrier = control.barrier;
                if (self.direct_input_offset < barrier) {
                    try self.client.sendInput(
                        self.stream_id,
                        self.direct_input.items[self.direct_input_offset..barrier],
                    );
                    self.direct_input_offset = barrier;
                    continue;
                }
                switch (control.op) {
                    .scroll_to_bottom => try self.client.sendScrollToBottom(self.stream_id),
                    .core_command => |command| {
                        const params = core_command_wire.encodeParams(self.allocator, self.stream_id, command) catch
                            return error.OutOfMemory;
                        defer self.allocator.free(params);
                        try self.client.sendCoreCommand(self.stream_id, params);
                    },
                }
                _ = self.pending_controls.orderedRemove(0);
                continue;
            }
            if (self.direct_input_offset < self.direct_input.items.len) {
                try self.client.sendInput(
                    self.stream_id,
                    self.direct_input.items[self.direct_input_offset..],
                );
                self.direct_input_offset = self.direct_input.items.len;
                continue;
            }
            self.direct_input.clearRetainingCapacity();
            self.direct_input_offset = 0;
            return;
        }
    }

    fn callOrdered(self: *RemoteRuntime, method: []const u8, params_json: ?[]const u8) client_mod.ClientError![]u8 {
        try self.flushQueuedInputBlocking();
        return self.client.call(method, params_json);
    }

    /// canonical PTY size를 바꾼다(host `runtime.resize`). host가 실 `TerminalCore`+`TIOCSWINSZ`에 적용한다.
    pub fn resize(self: *RemoteRuntime, cols: u16, rows: u16) client_mod.ClientError!void {
        self.resize_seq += 1; // 단조 증가 — registry가 이하 sequence를 stale로 거부(첫 resize만 적용되는 버그 방지).
        var buf: [96]u8 = undefined;
        const params = std.fmt.bufPrint(&buf, "{{\"stream_id\":{d},\"cols\":{d},\"rows\":{d},\"client_sequence\":{d}}}", .{ self.stream_id, cols, rows, self.resize_seq }) catch return error.OutOfMemory;
        const resp = try self.callOrdered("runtime.resize", params);
        self.allocator.free(resp);
        self.observation.size = .{ .cols = cols, .rows = rows };
    }

    /// 내 stream(§멀티 runtime demux)의 다음 화면 배치 하나를 소비해 원격 화면에 반영한다(§9/§10). **논블로킹** — 내 배치가
    /// 없으면 `idle`, metadata만 적용했으면 `metadata`, 화면 batch를 적용했으면 `screen`을 돌려준다. caller는 있는 동안
    /// 반복해 다 비우되 metadata를 PTY output activity로 세지 않는다(`RemoteTermBackend`의
    /// drain이 이걸로 `RuntimeEventPump.drainAvailable`과 같은 의미를 만든다). client가 `stream_id`로 demux하므로 여기 도달한
    /// 배치는 **항상 내 것**이다(예전엔 남의 배치를 free해 유실 — code-review #1; 이제 client가 남의 것은 버퍼해 그 runtime pump로
    /// 보낸다). host가 grid/alt 변화 시 delta 대신 fresh snapshot을 push하므로 둘 다 처리한다(is_snapshot이면 리셋, 아니면 증분).
    pub const PumpResult = enum { idle, metadata, screen };

    pub fn pumpDelta(self: *RemoteRuntime) (client_mod.ClientError || screen_assembler.ApplyError)!PumpResult {
        // 마지막 non-blocking input 뒤에 새 입력/RPC가 영원히 없더라도 frame-loop pump가 연결의 bounded pending frame을
        // 계속 DONTWAIT로 진전시킨다. Client 하나를 여러 runtime이 공유하므로 어느 runtime pump가 호출해도 충분하다.
        _ = try self.pumpQueuedInput();
        _ = try self.client.pumpPendingOutput();
        var changed = try self.drainObservationEvents();
        const maybe_batch = try self.client.readStreamBatch(self.allocator, self.stream_id);
        if (maybe_batch == null) {
            // readStreamBatch가 socket에서 event만 읽어 pending queue에 넣고 screen batch 없이 돌아올 수 있다.
            changed = (try self.drainObservationEvents()) or changed;
            return if (changed) .metadata else .idle;
        }
        const batch = maybe_batch.?;
        defer self.allocator.free(batch.bytes);
        if (batch.is_snapshot) {
            try self.remote_screen.applySnapshot(batch.bytes, self.io); // §9 fresh snapshot(grid/alt 변화) → 화면 리셋.
        } else {
            try self.remote_screen.applyDelta(batch.bytes, self.io);
        }
        _ = try self.drainObservationEvents();
        return .screen;
    }

    fn drainObservationEvents(self: *RemoteRuntime) error{OutOfMemory}!bool {
        var changed = false;
        while (self.client.takeEventForStream(self.stream_id)) |frame| {
            defer frame.deinit(self.allocator);
            changed = (try self.applyObservationJson(frame.payload)) or changed;
        }
        return changed;
    }

    /// attach response(`result.metadata`)와 후속 event(`metadata`)가 공유하는 parser. event는 full-state이므로 현재보다 큰
    /// revision만 owned cache로 원자 교체한다. duplicate/stale revision은 무시하고, 손상 JSON은 기존 cache를 보존한다.
    fn applyObservationJson(self: *RemoteRuntime, payload: []const u8) error{OutOfMemory}!bool {
        const wire_revision = (try observation_wire.payloadRevision(self.allocator, payload)) orelse return false;
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, payload, .{}) catch return false;
        defer parsed.deinit();
        const root = switch (parsed.value) {
            .object => |o| o,
            else => return false,
        };
        if (root.get("result") == null) {
            const event = jsonString(root.get("event") orelse return false) orelse return false;
            if (!std.mem.eql(u8, event, "runtime.metadata")) return false;
        }
        const container = if (root.get("result")) |result| switch (result) {
            .object => |o| o,
            else => root,
        } else root;
        const revision = jsonU64(container.get("metadata_revision") orelse return false) orelse return false;
        if (revision != wire_revision) return false;
        if (revision == 0 or revision <= self.observation.revision) return false;
        const metadata = switch (container.get("metadata") orelse return false) {
            .object => |o| o,
            else => return false,
        };
        const cwd = jsonString(metadata.get("cwd") orelse return false) orelse return false;
        const title = jsonString(metadata.get("window_title") orelse return false) orelse return false;
        const ssh_dest: ?[]const u8 = if (metadata.get("ssh_remote_dest")) |v| switch (v) {
            .null => null,
            .string => |s| s,
            else => return false,
        } else null;
        const semantic_raw = jsonU64(metadata.get("semantic_state") orelse return false) orelse return false;
        const semantic: terminal.SemanticPrompt = if (semantic_raw <= @intFromEnum(terminal.SemanticPrompt.command))
            @enumFromInt(@as(u8, @intCast(semantic_raw)))
        else
            .unknown;
        const alt_active = jsonBool(metadata.get("alt_active") orelse return false) orelse return false;
        const app_cursor_keys = jsonBool(metadata.get("app_cursor_keys") orelse return false) orelse return false;
        const alternate_scroll = jsonBool(metadata.get("alternate_scroll") orelse return false) orelse return false;
        // mouse_tracking은 optional(구버전 host 호환) — 없으면 false. host-backed 마우스 리포트 게이트(휠 리포트 vs 스크롤백)용.
        const mouse_tracking = if (metadata.get("mouse_tracking")) |v| (jsonBool(v) orelse return false) else false;
        // bracketed_paste도 optional(구버전 host 호환) — 없으면 false. host-backed 붙여넣기 게이트/인코딩용.
        const bracketed_paste = if (metadata.get("bracketed_paste")) |v| (jsonBool(v) orelse return false) else false;
        // app_keypad·kitty_flags도 optional(구버전 host 호환) — host-backed 일반 key의 DECKPAM(numpad)·kitty keyboard
        // 인코딩 parity용. 없으면 기본값(numeric·legacy)이라 구 host 재접속에도 안전하다.
        const app_keypad = if (metadata.get("app_keypad")) |v| (jsonBool(v) orelse return false) else false;
        const kitty_flags: u5 = if (metadata.get("kitty_flags")) |v| blk: {
            const n = jsonU64(v) orelse return false;
            if (n > std.math.maxInt(u5)) return false; // kitty flag 스택 최상단은 5비트 — 범위 밖은 malformed.
            break :blk @intCast(n);
        } else 0;
        const observer_generation = jsonU64(metadata.get("observer_generation") orelse return false) orelse return false;
        const title_generation_u64 = jsonU64(metadata.get("title_generation") orelse return false) orelse return false;
        if (title_generation_u64 > std.math.maxInt(u32)) return false;
        const cols_u64 = jsonU64(metadata.get("cols") orelse return false) orelse return false;
        const rows_u64 = jsonU64(metadata.get("rows") orelse return false) orelse return false;
        if (cols_u64 > std.math.maxInt(u16) or rows_u64 > std.math.maxInt(u16)) return false;
        const foreground_available = jsonBool(metadata.get("foreground_available") orelse return false) orelse return false;
        const foreground_pgid: ?i32 = if (metadata.get("foreground_pgid")) |v| switch (v) {
            .null => null,
            .integer => |n| if (n >= std.math.minInt(i32) and n <= std.math.maxInt(i32)) @intCast(n) else return false,
            else => return false,
        } else null;

        var processes: [64]maru.pty.types.ForegroundProcessName = undefined;
        var process_count: usize = 0;
        if (metadata.get("processes")) |pv| switch (pv) {
            .array => |arr| {
                for (arr.items) |item| {
                    if (process_count >= processes.len) break;
                    const obj = switch (item) {
                        .object => |o| o,
                        else => return false,
                    };
                    const pid_raw = switch (obj.get("pid") orelse return false) {
                        .integer => |n| n,
                        else => return false,
                    };
                    if (pid_raw < std.math.minInt(i32) or pid_raw > std.math.maxInt(i32)) return false;
                    const name = jsonString(obj.get("name") orelse return false) orelse return false;
                    const len = @min(name.len, processes[process_count].bytes.len);
                    processes[process_count] = .{ .pid = @intCast(pid_raw), .len = @intCast(len), .bytes = undefined };
                    @memcpy(processes[process_count].bytes[0..len], name[0..len]);
                    process_count += 1;
                }
            },
            else => return false,
        };

        try self.observation.replace(self.allocator, .{
            .availability = .current,
            .revision = revision,
            .observer_generation = observer_generation,
            .title_generation = @intCast(title_generation_u64),
            .size = .{ .cols = @intCast(cols_u64), .rows = @intCast(rows_u64) },
            .cwd = cwd,
            .window_title = title,
            .ssh_remote_dest = ssh_dest,
            .semantic_state = semantic,
            .alt_active = alt_active,
            .app_cursor_keys = app_cursor_keys,
            .app_keypad = app_keypad,
            .kitty_flags = kitty_flags,
            .alternate_scroll = alternate_scroll,
            .mouse_tracking = mouse_tracking,
            .bracketed_paste = bracketed_paste,
            .foreground_available = foreground_available,
            .foreground_pgid = foreground_pgid,
            .foreground_processes = processes[0..process_count],
        });
        return true;
    }

    fn jsonU64(value: std.json.Value) ?u64 {
        return switch (value) {
            .integer => |n| if (n >= 0) @intCast(n) else null,
            else => null,
        };
    }

    fn jsonString(value: std.json.Value) ?[]const u8 {
        return switch (value) {
            .string => |s| s,
            else => null,
        };
    }

    fn jsonBool(value: std.json.Value) ?bool {
        return switch (value) {
            .bool => |b| b,
            else => null,
        };
    }

    /// host runtime을 종료한다(client-side 자원은 남긴다 — 회수는 `deinit`). `TermRuntimeBackend.close_and_detach`/`close`가
    /// 부른다(계약: routing 끊고 프로세스 kill). 멱등(host가 없는 id 무시). client 객체는 이후 `remove`→`deinit`에서 회수한다.
    pub fn terminate(self: *RemoteRuntime) void {
        self.terminateBestEffort();
    }

    /// host에 fresh snapshot 재요청(§9 desync 복구) — 조립기가 `GenerationGap`/`MalformedRow`로 뒤처졌을 때 `pumpDelta` 실패
    /// 경로가 부른다. host가 다음 delta tick에 현재 full snapshot을 snapshot_chunk로 push하고, 그걸 `pumpDelta`의 applySnapshot이
    /// 받아 generation을 리셋해 복구한다(delta는 base_generation이 현재라 stale client를 못 고쳐 snapshot이 유일한 복구). 응답 무시.
    pub fn requestResync(self: *RemoteRuntime) client_mod.ClientError!void {
        var buf: [64]u8 = undefined;
        const params = std.fmt.bufPrint(&buf, "{{\"stream_id\":{d}}}", .{self.stream_id}) catch return error.OutOfMemory;
        const resp = try self.callOrdered("runtime.resync", params);
        self.allocator.free(resp);
    }

    /// periodic event보다 강한 metadata barrier. SSH upload처럼 stale destination으로 실행하면 안 되는 user action이
    /// 직전에 호출한다. host가 subscription revision/base와 같은 원자 상태에서 응답하므로 성공 뒤 observation은 host가
    /// 응답을 만든 시점의 full-state다.
    pub fn refreshObservation(self: *RemoteRuntime) client_mod.ClientError!void {
        var buf: [64]u8 = undefined;
        const params = std.fmt.bufPrint(&buf, "{{\"stream_id\":{d}}}", .{self.stream_id}) catch return error.OutOfMemory;
        const before = self.observation.revision;
        const resp = try self.callOrdered("runtime.observation", params);
        defer self.allocator.free(resp);
        const revision = client_mod.extractU64Field(resp, "\"metadata_revision\":") orelse return error.ProtocolError;
        if (revision < before) return error.ProtocolError;
        const changed = try self.applyObservationJson(resp);
        if (revision > before and !changed) return error.ProtocolError;
        if (self.observation.availability != .current or self.observation.revision != revision)
            return error.ProtocolError;
    }

    /// host에 뷰포트 선택 span을 보내 host의 `extractSelection`(로컬과 같은 함수)으로 뽑은 텍스트를 받는다(§6b 원격 선택 복사).
    /// **선택 의미론은 host core 단일 출처** — client는 렌더용 span만 보내고 콘텐츠 추출(soft-wrap 이음·블록·스크롤백)은 host가
    /// 한다. 단 앱보다 먼저 떠 계속 살아 있는 구 host는 이 RPC를 모르므로 capability가 없을 때만 현재 client 화면 projection의
    /// 보이는 선택을 추출한다. 반환 텍스트는 caller 소유(빈 선택/오류면 null). `block`은 std.fmt가 true/false로 찍어 유효 JSON.
    pub fn selectedText(self: *RemoteRuntime, span: terminal.SelectionSpan) client_mod.ClientError!?[]u8 {
        if (!self.client.runtime_selected_text_v1) return self.selectedTextFromProjection(span);
        var buf: [160]u8 = undefined;
        const params = std.fmt.bufPrint(&buf, "{{\"stream_id\":{d},\"sr\":{d},\"sc\":{d},\"er\":{d},\"ec\":{d},\"block\":{}}}", .{ self.stream_id, span.start.row, span.start.col, span.end.row, span.end.col, span.block }) catch return error.OutOfMemory;
        const resp = try self.callOrdered("runtime.selected_text", params);
        defer self.allocator.free(resp);
        return self.decodeSelectedTextResponse(resp);
    }

    fn decodeSelectedTextResponse(self: *RemoteRuntime, resp: []const u8) client_mod.ClientError!?[]u8 {
        const field = decodeSingleStringObject(self.allocator, resp) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            self.client.failClosed();
            return error.ProtocolError;
        };
        defer self.allocator.free(field.key);
        if (std.mem.eql(u8, field.key, "error")) {
            defer self.allocator.free(field.value);
            if (protocol.ErrorCode.fromWireName(field.value) == null) {
                self.client.failClosed();
                return error.ProtocolError;
            }
            return null;
        }
        if (!std.mem.eql(u8, field.key, "text")) {
            self.allocator.free(field.value);
            // capability를 광고한 host가 success schema를 지키지 않으면 같은 connection의 나머지 RPC도 신뢰할 수 없다.
            // 구 host 호환은 capability=false에서만 허용하고, 거짓 광고/드리프트는 빈 복사로 숨기지 않는다.
            self.client.failClosed();
            return error.ProtocolError;
        }
        const text = field.value;
        if (text.len == 0) {
            self.allocator.free(text);
            return null;
        }
        return text;
    }

    /// 구 host 호환 경로. RemoteScreen이 조립한 현재 viewport에서만 추출한다. 구 screen wire에는 soft-wrap bit가 없어
    /// multi-row 선형 선택은 보이는 행 사이에 개행을 보존하는 degraded 정책이며, capability가 있는 최신 host에서는 반드시
    /// 위 RPC를 써 host SSOT를 유지한다.
    fn selectedTextFromProjection(self: *RemoteRuntime, span: terminal.SelectionSpan) client_mod.ClientError!?[]u8 {
        return self.remote_screen.extractVisibleSelection(self.allocator, self.io, span);
    }

    /// 원격 검색(§6c): 검색어로 host가 **콘텐츠·스크롤백을 아는 자기 core**에서 `findMatches`(로컬과 같은 함수)로 매치를 찾게
    /// 하고, 보이는 매치의 뷰포트 span을 `out_spans`에 채운다(검색 의미론 host 단일 출처). 전체 매치 수를 돌려준다(뷰포트 밖 포함).
    /// `out_spans`는 먼저 비운다. 검색어는 임의 텍스트라 hex로 실어 escape를 피한다(상한 256 char).
    /// §6c 검색 결과. `count`=전체 매치 수, `cur`=현재 매치(cur_index)의 뷰포트 span(안 보이면 null). 보이는 **비현재** 매치는
    /// `out_spans`에 채운다(하이라이트용).
    pub const FindResult = struct { count: usize, cur: ?terminal.SelectionSpan };

    pub fn find(self: *RemoteRuntime, query: []const u8, cur_index: u32, scroll: bool, out_spans: *std.ArrayList(terminal.SelectionSpan)) client_mod.ClientError!FindResult {
        out_spans.clearRetainingCapacity();
        var hexbuf: [512]u8 = undefined;
        const qn = @min(query.len, hexbuf.len / 2);
        const hex_chars = "0123456789abcdef";
        for (query[0..qn], 0..) |b, i| {
            hexbuf[i * 2] = hex_chars[b >> 4];
            hexbuf[i * 2 + 1] = hex_chars[b & 0xf];
        }
        var buf: [640]u8 = undefined;
        const params = std.fmt.bufPrint(&buf, "{{\"stream_id\":{d},\"q\":\"{s}\",\"cur\":{d},\"scroll\":{}}}", .{ self.stream_id, hexbuf[0 .. qn * 2], cur_index, scroll }) catch return error.OutOfMemory;
        const resp = try self.callOrdered("runtime.find", params);
        defer self.allocator.free(resp);
        const count = client_mod.extractU64Field(resp, "\"count\":") orelse 0;
        const cur = parseFirstSpan(resp, "\"cur\":[");
        parseSpansInto(resp, out_spans, self.allocator);
        return .{ .count = @intCast(count), .cur = cur };
    }

    /// 단어/줄 선택(§6b-2): host가 콘텐츠를 아는 자기 core로 경계를 계산하게 하고(`selectWordAt`/`selectLineAt`) 결과 뷰포트
    /// 선택 span을 받는다(빈 placeholder는 경계를 모른다 = 선택 의미론 host 단일 출처). caller는 이 span을 placeholder에 적용해
    /// 하이라이트한다(복사는 #6b-1 selectedText가 그 span으로 host 추출). `op`는 고정 리터럴("word"/"line"). 선택 없으면 null.
    pub fn selectContentAware(self: *RemoteRuntime, op: []const u8, row: u16, col: u16) client_mod.ClientError!?terminal.SelectionSpan {
        var buf: [96]u8 = undefined;
        const params = std.fmt.bufPrint(&buf, "{{\"stream_id\":{d},\"op\":\"{s}\",\"row\":{d},\"col\":{d}}}", .{ self.stream_id, op, row, col }) catch return error.OutOfMemory;
        const resp = try self.callOrdered("runtime.select_op", params);
        defer self.allocator.free(resp);
        if (std.mem.indexOf(u8, resp, "\"sel\":true") == null) return null; // 빈 선택(공백 셀 등).
        const sr = client_mod.extractU64Field(resp, "\"sr\":") orelse return null;
        const sc = client_mod.extractU64Field(resp, "\"sc\":") orelse return null;
        const er = client_mod.extractU64Field(resp, "\"er\":") orelse return null;
        const ec = client_mod.extractU64Field(resp, "\"ec\":") orelse return null;
        const block = std.mem.indexOf(u8, resp, "\"block\":true") != null;
        return .{ .start = .{ .row = @intCast(sr), .col = @intCast(sc) }, .end = .{ .row = @intCast(er), .col = @intCast(ec) }, .block = block };
    }

    /// host-authoritative core command를 strict bounded codec으로 보낸다. 구 host는 scroll 4종만 이해하므로 capability가
    /// 없는 연결에는 그 legacy subset만 보내고 focus/config/prompt는 unknown RPC를 시험하지 않고 degraded no-op으로 둔다.
    pub fn sendCoreCommandBlocking(self: *RemoteRuntime, command: core_command_wire.Command) client_mod.ClientError!void {
        if (!shouldSendCoreCommand(self.client.runtime_core_command_v1, command)) return;
        const params = core_command_wire.encodeParams(self.allocator, self.stream_id, command) catch return error.OutOfMemory;
        defer self.allocator.free(params);
        const resp = try self.callOrdered("runtime.core_command", params);
        self.allocator.free(resp);
    }

    /// host-backed 마우스 리포트(§ 입력 패리티): 마우스 이벤트를 host로 보내 host core가 자기 mouse_tracking/format으로
    /// SGR 리포트를 인코딩·PTY 주입하게 한다. 인코딩 모드가 host에만 있어 client는 raw 이벤트만 전달한다(방식 B).
    pub fn sendMouseReport(self: *RemoteRuntime, m: maru.session.core_command.MouseReport) client_mod.ClientError!void {
        var buf: [192]u8 = undefined;
        const params = std.fmt.bufPrint(
            &buf,
            "{{\"stream_id\":{d},\"button\":{d},\"col\":{d},\"row\":{d},\"x_px\":{d},\"y_px\":{d},\"pressed\":{},\"motion\":{},\"mods\":{d}}}",
            .{ self.stream_id, m.button, m.col, m.row, m.x_px, m.y_px, m.pressed, m.motion, m.mods },
        ) catch return error.OutOfMemory;
        const resp = try self.callOrdered("runtime.report_mouse", params);
        self.allocator.free(resp);
    }

    /// host에 대기 중인 OSC 9/777 데스크톱 알림을 뺀다(§6.32 — host가 core와 함께 알림을 소유·전달). 없으면 null. host-backed
    /// 터미널의 알림은 host의 `TerminalCore`가 파싱하므로 client가 이걸로 가져와 GUI 알림 funnel에 넣는다(app_session이 surfacing).
    /// 반환 title/body는 caller 소유(Notification.deinit로 회수). 둘 다 빈 값이면(host 대기 없음) null.
    pub fn takeNotification(self: *RemoteRuntime) client_mod.ClientError!?Notification {
        var buf: [96]u8 = undefined;
        const params = std.fmt.bufPrint(&buf, "{{\"runtime_id\":\"{s}\"}}", .{self.runtime_id_hex}) catch return error.OutOfMemory;
        const resp = try self.callOrdered("runtime.notification", params);
        defer self.allocator.free(resp);
        // std.json.parseFromSlice 대신 **수동 디코드** — parseFromSlice가 숫자 파서(f128 소프트플로트 ___divtf3/___fixtfti
        // 등)를 링크로 끌어와, 이 경로가 live가 되면 ReleaseSafe 제품 빌드(macos-live-preview-perf)가 undefined symbol로
        // 깨진다(code-review 후속). client는 이미 extractU64Field 등 수동 파싱 관례라 여기서도 그 관례를 따른다.
        const title = (decodeJsonStringField(self.allocator, resp, "title") catch return error.OutOfMemory) orelse return null;
        errdefer self.allocator.free(title);
        const body = (decodeJsonStringField(self.allocator, resp, "body") catch return error.OutOfMemory) orelse {
            self.allocator.free(title);
            return null;
        };
        errdefer self.allocator.free(body);
        if (title.len == 0 and body.len == 0) { // host에 대기 알림 없음(빈 {title,body}).
            self.allocator.free(title);
            self.allocator.free(body);
            return null;
        }
        return .{ .title = title, .body = body };
    }

    /// `key` 뒤 `[...]` 배열의 **첫 4정수**를 `SelectionSpan`으로 파싱한다(§6c-2 현재 매치 `"cur":[sr,sc,er,ec]`). 4개 미만
    /// (빈 배열=현재 매치 안 보임)이면 null. std.json 안 씀(f128 회피).
    fn parseFirstSpan(resp: []const u8, key: []const u8) ?terminal.SelectionSpan {
        const start = std.mem.indexOf(u8, resp, key) orelse return null;
        var i = start + key.len;
        var nums: [4]u16 = undefined;
        var ni: usize = 0;
        while (i < resp.len and resp[i] != ']' and ni < 4) {
            if (resp[i] < '0' or resp[i] > '9') {
                i += 1;
                continue;
            }
            var j = i;
            while (j < resp.len and resp[j] >= '0' and resp[j] <= '9') j += 1;
            nums[ni] = std.fmt.parseInt(u16, resp[i..j], 10) catch return null;
            i = j;
            ni += 1;
        }
        if (ni < 4) return null; // 빈/불완전 = 현재 매치 뷰포트 밖.
        return .{ .start = .{ .row = nums[0], .col = nums[1] }, .end = .{ .row = nums[2], .col = nums[3] }, .block = false };
    }

    /// `{...,"spans":[sr,sc,er,ec, sr,sc,er,ec, ...]}`의 flat 정수 배열을 4개씩 `SelectionSpan`으로 파싱해 `out`에 append한다
    /// (§6c 검색 매치 뷰포트 span). std.json.parseFromSlice 대신 수동 스캔(f128 회피, decodeJsonStringField와 같은 이유).
    /// 잘못된 형식/append 실패는 best-effort로 멈춘다(검색은 부가 기능).
    fn parseSpansInto(resp: []const u8, out: *std.ArrayList(terminal.SelectionSpan), allocator: std.mem.Allocator) void {
        const key = "\"spans\":[";
        const start = std.mem.indexOf(u8, resp, key) orelse return;
        var i = start + key.len;
        var nums: [4]u16 = undefined;
        var ni: usize = 0;
        while (i < resp.len and resp[i] != ']') {
            if (resp[i] < '0' or resp[i] > '9') { // 구분자(`,` 공백) 스킵.
                i += 1;
                continue;
            }
            var j = i;
            while (j < resp.len and resp[j] >= '0' and resp[j] <= '9') j += 1;
            nums[ni] = std.fmt.parseInt(u16, resp[i..j], 10) catch break;
            i = j;
            ni += 1;
            if (ni == 4) {
                out.append(allocator, .{ .start = .{ .row = nums[0], .col = nums[1] }, .end = .{ .row = nums[2], .col = nums[3] }, .block = false }) catch return;
                ni = 0;
            }
        }
    }

    /// `{"key":"<json-string>", ...}`에서 `key`의 문자열 값을 디코드해 owned 바이트로 돌려준다(키 없으면 null). host는
    /// `std.json.Stringify`로 escape하므로 그 역(표준 JSON string escape)만 처리한다: `\" \\ \/ \n \r \t \b \f \u00XX`.
    /// Stringify 기본은 non-ASCII를 raw로 두므로 `\uXXXX`는 제어문자(≤0x1F)뿐이라 surrogate pair는 없다. **std.json.parseFromSlice를
    /// 안 쓴다** — 그 숫자 파서가 f128 소프트플로트를 링크로 끌어와 ReleaseSafe 제품 빌드를 깬다(takeNotification 참고).
    fn decodeJsonStringField(allocator: std.mem.Allocator, json: []const u8, key: []const u8) error{OutOfMemory}!?[]u8 {
        var pat_buf: [64]u8 = undefined;
        const pat = std.fmt.bufPrint(&pat_buf, "\"{s}\"", .{key}) catch return null;
        const k = std.mem.indexOf(u8, json, pat) orelse return null;
        var i = k + pat.len;
        while (i < json.len and (json[i] == ' ' or json[i] == ':')) i += 1; // `:` + 공백 스킵
        if (i >= json.len or json[i] != '"') return null;
        i += 1; // 여는 따옴표 뒤
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);
        while (i < json.len) : (i += 1) {
            const ch = json[i];
            if (ch == '"') return try out.toOwnedSlice(allocator); // 닫는 따옴표 = 끝
            if (ch != '\\') {
                try out.append(allocator, ch);
                continue;
            }
            i += 1; // escape 문자
            if (i >= json.len) break;
            switch (json[i]) {
                '"' => try out.append(allocator, '"'),
                '\\' => try out.append(allocator, '\\'),
                '/' => try out.append(allocator, '/'),
                'n' => try out.append(allocator, '\n'),
                'r' => try out.append(allocator, '\r'),
                't' => try out.append(allocator, '\t'),
                'b' => try out.append(allocator, 0x08),
                'f' => try out.append(allocator, 0x0c),
                'u' => {
                    if (i + 4 >= json.len) break;
                    const cp = std.fmt.parseInt(u21, json[i + 1 .. i + 5], 16) catch break;
                    var u8buf: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(cp, &u8buf) catch break;
                    try out.appendSlice(allocator, u8buf[0..n]);
                    i += 4; // 4 hex 소비(루프 증가가 'u'를 넘긴다)
                },
                else => |e| try out.append(allocator, e), // 알 수 없는 escape는 그대로(best-effort)
            }
        }
        return try out.toOwnedSlice(allocator); // 닫는 따옴표 못 만남(손상) — 여기까지 best-effort
    }

    const SingleStringField = struct {
        key: []u8,
        value: []u8,

        fn deinit(self: SingleStringField, allocator: std.mem.Allocator) void {
            allocator.free(self.key);
            allocator.free(self.value);
        }
    };

    /// server의 단일-field success/error envelope(`{"text":"..."}` / `{"error":"..."}`) 전용 strict parser.
    /// 선택 복사는 clipboard에 쓰이므로 notification용 best-effort field scanner를 재사용하지 않는다.
    fn decodeSingleStringObject(
        allocator: std.mem.Allocator,
        json: []const u8,
    ) error{ OutOfMemory, InvalidJson }!SingleStringField {
        var i: usize = 0;
        skipJsonWhitespace(json, &i);
        if (i >= json.len or json[i] != '{') return error.InvalidJson;
        i += 1;
        skipJsonWhitespace(json, &i);
        const key = try decodeStrictJsonStringAt(allocator, json, &i);
        errdefer allocator.free(key);
        skipJsonWhitespace(json, &i);
        if (i >= json.len or json[i] != ':') return error.InvalidJson;
        i += 1;
        skipJsonWhitespace(json, &i);
        const value = try decodeStrictJsonStringAt(allocator, json, &i);
        errdefer allocator.free(value);
        skipJsonWhitespace(json, &i);
        if (i >= json.len or json[i] != '}') return error.InvalidJson;
        i += 1;
        skipJsonWhitespace(json, &i);
        if (i != json.len) return error.InvalidJson;
        return .{ .key = key, .value = value };
    }

    fn skipJsonWhitespace(json: []const u8, i: *usize) void {
        while (i.* < json.len and switch (json[i.*]) {
            ' ', '\t', '\r', '\n' => true,
            else => false,
        }) i.* += 1;
    }

    fn decodeStrictJsonStringAt(
        allocator: std.mem.Allocator,
        json: []const u8,
        i: *usize,
    ) error{ OutOfMemory, InvalidJson }![]u8 {
        if (i.* >= json.len or json[i.*] != '"') return error.InvalidJson;
        i.* += 1;
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);
        while (i.* < json.len) {
            const ch = json[i.*];
            i.* += 1;
            if (ch == '"') {
                const owned = out.toOwnedSlice(allocator) catch return error.OutOfMemory;
                if (!std.unicode.utf8ValidateSlice(owned)) {
                    allocator.free(owned);
                    return error.InvalidJson;
                }
                return owned;
            }
            if (ch < 0x20) return error.InvalidJson;
            if (ch != '\\') {
                out.append(allocator, ch) catch return error.OutOfMemory;
                continue;
            }
            if (i.* >= json.len) return error.InvalidJson;
            const escaped = json[i.*];
            i.* += 1;
            switch (escaped) {
                '"' => out.append(allocator, '"') catch return error.OutOfMemory,
                '\\' => out.append(allocator, '\\') catch return error.OutOfMemory,
                '/' => out.append(allocator, '/') catch return error.OutOfMemory,
                'n' => out.append(allocator, '\n') catch return error.OutOfMemory,
                'r' => out.append(allocator, '\r') catch return error.OutOfMemory,
                't' => out.append(allocator, '\t') catch return error.OutOfMemory,
                'b' => out.append(allocator, 0x08) catch return error.OutOfMemory,
                'f' => out.append(allocator, 0x0c) catch return error.OutOfMemory,
                'u' => {
                    if (i.* + 4 > json.len) return error.InvalidJson;
                    const cp = std.fmt.parseInt(u21, json[i.* .. i.* + 4], 16) catch return error.InvalidJson;
                    if (cp >= 0xD800 and cp <= 0xDFFF) return error.InvalidJson;
                    var buf: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(cp, &buf) catch return error.InvalidJson;
                    out.appendSlice(allocator, buf[0..n]) catch return error.OutOfMemory;
                    i.* += 4;
                },
                else => return error.InvalidJson,
            }
        }
        return error.InvalidJson;
    }

    fn terminateBestEffort(self: *RemoteRuntime) void {
        var buf: [64]u8 = undefined;
        const params = std.fmt.bufPrint(&buf, "{{\"runtime_id\":\"{s}\"}}", .{self.runtime_id_hex}) catch return;
        // lifecycle cleanup은 transient input-frame OOM 때문에 생략하면 안 된다. 가능한 경우 accepted input을 먼저
        // flush하되, 준비 OOM이면 terminate 자체는 계속 시도한다.
        self.flushQueuedInputBlocking() catch |err| if (err != error.OutOfMemory) return;
        const resp = self.client.call("runtime.terminate", params) catch |err| {
            // cleanup request를 만들거나 응답을 추적할 메모리조차 없으면 shared connection을 닫아 host EOF 경로가
            // 모든 attachment/controller lease를 회수하게 한다.
            if (err == error.OutOfMemory) self.client.failClosed();
            return;
        };
        self.allocator.free(resp);
    }

    fn detachBestEffort(self: *RemoteRuntime) void {
        if (self.stream_id == 0) return;
        var buf: [64]u8 = undefined;
        const params = std.fmt.bufPrint(&buf, "{{\"stream_id\":{d}}}", .{self.stream_id}) catch return;
        // controller lease 해제는 transient input-frame OOM보다 우선한다. hard connection error면 어차피 EOF detach된다.
        self.flushQueuedInputBlocking() catch |err| if (err != error.OutOfMemory) return;
        const resp = self.client.call("runtime.detach", params) catch |err| {
            if (err == error.OutOfMemory) self.client.failClosed();
            return;
        };
        self.allocator.free(resp);
    }
};

fn shouldSendCoreCommand(runtime_core_command_v1: bool, command: core_command_wire.Command) bool {
    return runtime_core_command_v1 or command.isLegacyScroll();
}

test "remote runtime: extended core commands require capability while legacy scroll remains compatible" {
    try std.testing.expect(shouldSendCoreCommand(false, .{ .scroll = 1 }));
    try std.testing.expect(!shouldSendCoreCommand(false, .{ .report_focus = true }));
    try std.testing.expect(!shouldSendCoreCommand(false, .{ .set_max_scrollback = 1000 }));
    try std.testing.expect(shouldSendCoreCommand(true, .{ .report_focus = false }));
}

test "remote runtime: new spawn config fails closed against a legacy daemon that would ignore the field" {
    var client = client_mod.Client{
        .allocator = std.testing.allocator,
        .fd = -1,
        .host_id = 1,
        .runtime_core_command_v1 = false,
        .parser = framing.FrameParser.init(std.testing.allocator),
    };
    defer client.deinit();
    var rr: RemoteRuntime = undefined;
    try std.testing.expectError(error.UnsupportedSpawnContract, rr.spawnWithConfig(
        &client,
        std.testing.allocator,
        std.testing.io,
        1,
        .{ .command = "/bin/cat" },
        .{ .cols = 80, .rows = 24 },
        .{
            .max_scrollback = 1000,
            .ambiguous_wide = false,
            .emoji_wide = true,
            .palette = .{null} ** 16,
            .default_colors = .{
                .foreground = .{ .r = 0xD0, .g = 0xD0, .b = 0xD0 },
                .background = .{ .r = 0x10, .g = 0x10, .b = 0x10 },
            },
            .cell_metrics = null,
        },
    ));
}

test "remote runtime: advertised selected-text capability with a missing response field fails the connection closed" {
    const allocator = std.testing.allocator;
    var client = client_mod.Client{
        .allocator = allocator,
        .fd = -1,
        .host_id = 1,
        .runtime_selected_text_v1 = true,
        .parser = framing.FrameParser.init(allocator),
    };
    defer client.deinit();
    var rr: RemoteRuntime = undefined;
    rr.client = &client;
    rr.allocator = allocator;

    try std.testing.expectError(
        error.ProtocolError,
        rr.decodeSelectedTextResponse("{\"error\":{\"code\":\"invalid_request\"}}"),
    );
    try std.testing.expectError(error.ConnectionClosed, client.call("host.info", null));
}

test "remote runtime: selected-text response envelope is strict while typed host errors remain valid" {
    const allocator = std.testing.allocator;
    const text = try RemoteRuntime.decodeSingleStringObject(allocator, "{\"text\":\"e\\u000a\"}");
    defer text.deinit(allocator);
    try std.testing.expectEqualStrings("text", text.key);
    try std.testing.expectEqualStrings("e\n", text.value);

    const typed_error = try RemoteRuntime.decodeSingleStringObject(allocator, "{\"error\":\"invalid_request\"}");
    defer typed_error.deinit(allocator);
    try std.testing.expectEqualStrings("error", typed_error.key);
    try std.testing.expect(protocol.ErrorCode.fromWireName(typed_error.value) != null);

    try std.testing.expectError(
        error.InvalidJson,
        RemoteRuntime.decodeSingleStringObject(allocator, "{\"text\":\"unterminated}"),
    );
    try std.testing.expectError(
        error.InvalidJson,
        RemoteRuntime.decodeSingleStringObject(allocator, "{\"text\":\"bad\\q\"}"),
    );
    try std.testing.expectError(
        error.InvalidJson,
        RemoteRuntime.decodeSingleStringObject(allocator, "{\"text\":\"ok\",\"extra\":\"no\"}"),
    );
}

/// `{argv:[...], cols, rows}` spawn params를 JSON으로 만든다(caller free). argv는 임의 바이트라 실 JSON encoder로 escape한다
/// (client hand-built JSON의 신뢰 계약 밖 — client.zig 주석대로 임의 argv는 stringify로).
fn buildSpawnParams(
    allocator: std.mem.Allocator,
    request: maru.pty.SpawnRequest,
    size: terminal.Size,
    initial_config: ?maru.session.core_command.RuntimeConfig,
) error{OutOfMemory}![]u8 {
    const argv = allocator.alloc([]const u8, 1 + request.args.len) catch return error.OutOfMemory;
    defer allocator.free(argv);
    argv[0] = request.command;
    for (request.args, 0..) |arg, i| argv[i + 1] = arg;
    var pane_id_buf: [16]u8 = undefined;
    const pane_id: ?[]const u8 = if (request.pane_id) |id|
        std.fmt.bufPrint(&pane_id_buf, "{x:0>16}", .{id}) catch return error.OutOfMemory
    else
        null;
    var inherited: std.ArrayListUnmanaged([]const u8) = .empty;
    defer inherited.deinit(allocator);
    if (request.env.len == 0 and request.parent_env == null) {
        const environ = std.c.environ;
        var index: usize = 0;
        while (environ[index]) |entry| : (index += 1) {
            inherited.append(allocator, std.mem.span(entry)) catch return error.OutOfMemory;
        }
    }
    // env=[]의 "호출자 부모 상속" 의미를 오래 살아 있는 daemon 환경으로 바꾸지 않는다. GUI가 본 raw parent
    // snapshot을 별도 필드로 보내고, host의 단일 EnvStorage가 TERM/ZDOTDIR/config override를 그대로 적용한다.
    const parent_env: []const []const u8 = if (request.env.len != 0)
        &.{}
    else if (request.parent_env) |snapshot|
        snapshot
    else
        inherited.items;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    js.write(.{
        .argv = argv,
        .cwd = request.cwd,
        .login = request.login,
        .env = request.env,
        .parent_env = parent_env,
        .env_overrides = request.env_overrides,
        .term = request.term,
        .zdotdir = request.zdotdir,
        .ssh_integration_bin = request.ssh_integration_bin,
        .pane_id = pane_id,
        .cols = size.cols,
        .rows = size.rows,
        .runtime_config = if (initial_config) |config| coreConfigToSpawnWire(config) else null,
    }) catch return error.OutOfMemory;
    return allocator.dupe(u8, out.written()) catch return error.OutOfMemory;
}

const RuntimeConfigSpawnWire = struct {
    lines: u64,
    ambiguous_wide: bool,
    emoji_wide: bool,
    palette: core_command_wire.Command.Palette,
    foreground: u32,
    background: u32,
    cell_width: u32,
    cell_height: u32,
};

fn coreConfigToSpawnWire(config: maru.session.core_command.RuntimeConfig) RuntimeConfigSpawnWire {
    var palette: core_command_wire.Command.Palette = .{null} ** 16;
    for (config.palette, 0..) |maybe_rgb, index| {
        palette[index] = if (maybe_rgb) |rgb|
            (@as(u32, rgb.r) << 16) | (@as(u32, rgb.g) << 8) | rgb.b
        else
            null;
    }
    return .{
        .lines = @intCast(config.max_scrollback),
        .ambiguous_wide = config.ambiguous_wide,
        .emoji_wide = config.emoji_wide,
        .palette = palette,
        .foreground = (@as(u32, config.default_colors.foreground.r) << 16) |
            (@as(u32, config.default_colors.foreground.g) << 8) |
            config.default_colors.foreground.b,
        .background = (@as(u32, config.default_colors.background.r) << 16) |
            (@as(u32, config.default_colors.background.g) << 8) |
            config.default_colors.background.b,
        .cell_width = if (config.cell_metrics) |metrics| metrics.width else 0,
        .cell_height = if (config.cell_metrics) |metrics| metrics.height else 0,
    };
}

test "remote runtime: spawn wire preserves extended SpawnRequest fields" {
    const allocator = std.testing.allocator;
    const request: maru.pty.SpawnRequest = .{
        .command = "/bin/zsh",
        .args = &.{ "-l", "-c", "pwd" },
        .cwd = "/tmp/maru cwd",
        .login = true,
        .env = &.{ "BASE=one", "UNICODE=한글" },
        .parent_env = &.{"SHOULD=NOT_BE_SENT"},
        .env_overrides = &.{ "BASE=two", "MARU_FLAG=yes" },
        .term = "xterm-maru",
        .zdotdir = "/tmp/maru-zdotdir",
        .ssh_integration_bin = "/Applications/Maru.app/Contents/MacOS/maru",
        .pane_id = 0x1234,
    };
    var palette: [16]?terminal.Rgb = .{null} ** 16;
    palette[0] = .{ .r = 0x11, .g = 0x22, .b = 0x33 };
    const json = try buildSpawnParams(allocator, request, .{ .cols = 132, .rows = 43 }, .{
        .max_scrollback = 4321,
        .ambiguous_wide = true,
        .emoji_wide = false,
        .palette = palette,
        .default_colors = .{
            .foreground = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC },
            .background = .{ .r = 0x01, .g = 0x02, .b = 0x03 },
        },
        .cell_metrics = .{ .width = 9, .height = 18 },
    });
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"argv\":[\"/bin/zsh\",\"-l\",\"-c\",\"pwd\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"cwd\":\"/tmp/maru cwd\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"login\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"env\":[\"BASE=one\",\"UNICODE=한글\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"parent_env\":[]") != null); // explicit env가 우선한다.
    try std.testing.expect(std.mem.indexOf(u8, json, "\"env_overrides\":[\"BASE=two\",\"MARU_FLAG=yes\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"term\":\"xterm-maru\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"zdotdir\":\"/tmp/maru-zdotdir\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ssh_integration_bin\":\"/Applications/Maru.app/Contents/MacOS/maru\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"pane_id\":\"0000000000001234\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"cols\":132") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"rows\":43") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"runtime_config\":{\"lines\":4321") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"foreground\":11189196") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"cell_width\":9,\"cell_height\":18") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"max_scrollback\"") == null); // host decoder와 다른 내부 필드명 누출 금지.
}

test "remote runtime: metadata parser applies only newer coherent full-state revisions" {
    const allocator = std.testing.allocator;
    var rr: RemoteRuntime = undefined;
    rr.allocator = allocator;
    rr.observation = .{};
    defer rr.observation.deinit(allocator);

    const rev2 =
        \\{"event":"runtime.metadata","metadata_revision":2,"metadata":{"cwd":"/repo","window_title":"work","ssh_remote_dest":"host",
        \\"semantic_state":3,"alt_active":true,"app_cursor_keys":true,"alternate_scroll":true,"mouse_tracking":true,"bracketed_paste":true,"app_keypad":true,"kitty_flags":5,"observer_generation":9,"title_generation":4,"cols":120,"rows":40,
        \\"foreground_available":true,"foreground_pgid":55,"processes":[{"pid":55,"name":"claude"}]}}
    ;
    try std.testing.expect(try rr.applyObservationJson(rev2));
    try std.testing.expectEqual(term_backend.ObservationAvailability.current, rr.observation.availability);
    try std.testing.expectEqual(@as(u64, 2), rr.observation.revision);
    try std.testing.expectEqualStrings("/repo", rr.observation.cwd.items);
    try std.testing.expectEqualStrings("host", rr.observation.ssh_remote_dest.items);
    try std.testing.expectEqual(terminal.SemanticPrompt.command, rr.observation.semantic_state);
    try std.testing.expect(rr.observation.alt_active);
    try std.testing.expect(rr.observation.mouse_tracking); // host-backed 마우스 리포트 게이트용(§입력 패리티)
    try std.testing.expect(rr.observation.bracketed_paste); // host-backed 붙여넣기 bracketed 게이트/인코딩용(§입력 패리티)
    try std.testing.expect(rr.observation.app_keypad); // host-backed 일반 key DECKPAM(numpad) 인코딩 모드(§입력 패리티)
    try std.testing.expectEqual(@as(u5, 5), rr.observation.kitty_flags); // host-backed 일반 key kitty keyboard flag(§입력 패리티)
    try std.testing.expectEqual(@as(?i32, 55), rr.observation.foreground_pgid);
    try std.testing.expectEqual(@as(u16, 120), rr.observation.size.cols);
    try std.testing.expectEqualStrings("claude", rr.observation.foreground_processes.items[0].slice());

    const stale =
        \\{"event":"runtime.metadata","metadata_revision":1,"metadata":{"cwd":"/stale","window_title":"old","ssh_remote_dest":null,
        \\"semantic_state":0,"alt_active":false,"app_cursor_keys":false,"alternate_scroll":true,"observer_generation":1,"title_generation":1,"cols":80,"rows":24,
        \\"foreground_available":false,"foreground_pgid":null,"processes":[]}}
    ;
    try std.testing.expect(!try rr.applyObservationJson(stale));
    try std.testing.expectEqualStrings("/repo", rr.observation.cwd.items);

    // malformed newer event is atomic: revision과 일부 문자열 어느 것도 바뀌지 않는다.
    try std.testing.expect(!try rr.applyObservationJson(
        "{\"metadata_revision\":3,\"metadata\":{\"cwd\":\"/partial\"}}",
    ));
    try std.testing.expectEqual(@as(u64, 2), rr.observation.revision);
    try std.testing.expectEqualStrings("/repo", rr.observation.cwd.items);
}

test "remote runtime: mouse_tracking is optional — 구버전 host metadata(필드 없음)는 적용되고 false로 폴백한다" {
    const allocator = std.testing.allocator;
    var rr: RemoteRuntime = undefined;
    rr.allocator = allocator;
    rr.observation = .{};
    defer rr.observation.deinit(allocator);

    // mouse_tracking 필드가 없는(구버전 host) metadata — 통째로 거부되지 않고 적용되며, 나머지 관측은 살고
    // mouse_tracking만 false로 폴백한다(호환 계약, observation_wire.fieldIsBoolOrAbsent). host-backed 마우스 리포트는
    // 그 host에선 pre-fix 동작(스크롤백 폴백)을 유지한다.
    const legacy =
        \\{"event":"runtime.metadata","metadata_revision":1,"metadata":{"cwd":"/legacy","window_title":"w","ssh_remote_dest":null,
        \\"semantic_state":0,"alt_active":false,"app_cursor_keys":false,"alternate_scroll":true,"observer_generation":1,"title_generation":1,"cols":80,"rows":24,
        \\"foreground_available":false,"foreground_pgid":null,"processes":[]}}
    ;
    try std.testing.expect(try rr.applyObservationJson(legacy));
    try std.testing.expectEqualStrings("/legacy", rr.observation.cwd.items);
    try std.testing.expect(!rr.observation.mouse_tracking); // 필드 없음 → false 폴백
    try std.testing.expect(!rr.observation.bracketed_paste); // bracketed_paste도 optional — 필드 없음 → false 폴백
    try std.testing.expect(!rr.observation.app_keypad); // app_keypad도 optional — 필드 없음 → false(numeric) 폴백
    try std.testing.expectEqual(@as(u5, 0), rr.observation.kitty_flags); // kitty_flags도 optional — 필드 없음 → 0(legacy) 폴백
}

// ─────────────────────────────────────────────────────────────────────────────
// process smoke (실 macOS: fork된 host에 client-side 원격 runtime을 띄우고 화면을 몬다)
//
// 이 테스트가 증명하는 것(그리고 터미널에서 왜 중요한가): 원격 runtime이 client 쪽에서 **하나의 Surface**로 다뤄져야
// GUI가 in-process와 같은 코드로 렌더한다(SSOT). fork한 host에 RemoteRuntime.spawn으로 셸을 띄우면 그 Surface가 host
// 화면을 반영하고, 입력→delta→Surface 갱신이 도는지, terminate로 회수되는지 고정한다. 실 forkpty·socket이라 macOS opt-in.
// ─────────────────────────────────────────────────────────────────────────────

const testing = std.testing;
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;
const framing = @import("framing.zig");
const socket_server = @import("socket_server.zig");

fn fillRemoteTestSendBuffer(fd: c.fd_t) !usize {
    var requested: c_int = 4096;
    _ = c.setsockopt(fd, posix.SOL.SOCKET, posix.SO.SNDBUF, &requested, @sizeOf(c_int));
    const flags = c.fcntl(fd, c.F.GETFL, @as(c_int, 0));
    if (flags < 0) return error.TestUnexpectedResult;
    const nonblock_flag: c_int = @bitCast(posix.O{ .NONBLOCK = true });
    if (c.fcntl(fd, c.F.SETFL, flags | nonblock_flag) < 0) return error.TestUnexpectedResult;
    defer _ = c.fcntl(fd, c.F.SETFL, flags);
    var chunk: [4096]u8 = undefined;
    @memset(&chunk, 0xA5);
    var total: usize = 0;
    while (true) {
        const rc = c.send(fd, &chunk, chunk.len, posix.MSG.DONTWAIT);
        if (rc > 0) {
            total += @intCast(rc);
            if (total > 64 * 1024 * 1024) return error.TestUnexpectedResult;
            continue;
        }
        if (rc == 0) return error.TestUnexpectedResult;
        if (rc < 0 and posix.errno(rc) == .INTR) continue;
        if (rc < 0 and posix.errno(rc) == .AGAIN) return total;
        return error.TestUnexpectedResult;
    }
}

fn readRemoteTestExact(fd: c.fd_t, out: []u8) !void {
    var offset: usize = 0;
    while (offset < out.len) {
        const rc = c.read(fd, out[offset..].ptr, out.len - offset);
        if (rc > 0) {
            offset += @intCast(rc);
            continue;
        }
        if (rc < 0 and posix.errno(rc) == .INTR) continue;
        return error.TestUnexpectedResult;
    }
}

fn remoteOrderingPeer(fd: c.fd_t, expected: []const u8, response: []const u8, ok: *bool) void {
    const received = std.heap.page_allocator.alloc(u8, expected.len) catch return;
    defer std.heap.page_allocator.free(received);
    readRemoteTestExact(fd, received) catch return;
    ok.* = std.mem.eql(u8, expected, received);
    if (response.len > 0) socket_server.writeAll(fd, response) catch return;
}

test "remote runtime retains direct key behind async scroll barrier under socket backpressure" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fds: [2]c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    socket_server.setNoSigPipe(fds[0]);
    defer _ = c.close(fds[1]);

    var client = client_mod.Client{
        .allocator = allocator,
        .fd = fds[0],
        .host_id = 1,
        .async_scroll_to_bottom_v1 = true,
        .parser = framing.FrameParser.init(allocator),
    };
    defer client.deinit();
    var rr: RemoteRuntime = undefined;
    rr.client = &client;
    rr.allocator = allocator;
    rr.stream_id = 9;
    rr.direct_input = .empty;
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
    defer rr.direct_input.deinit(allocator);
    defer rr.pending_controls.deinit(allocator);

    const filler_len = try fillRemoteTestSendBuffer(fds[0]);
    try testing.expect(filler_len > 0);
    try testing.expectEqual(@as(usize, 1), try client.sendInputNonBlocking(9, "A"));

    // 실제 상위 호출 순서: imeBegin이 scroll intent를 만들고, 일반 key writeInput이 B를 보낸다.
    // B는 would-block을 오류로 돌리지 않고 RemoteRuntime이 소유해 재시도해야 한다.
    try rr.requestScrollToBottom();
    try rr.sendInput("B");
    try testing.expectEqualStrings("B", rr.direct_input.items[rr.direct_input_offset..]);
    try testing.expectEqual(@as(usize, 1), rr.pending_controls.items.len);

    const filler = try allocator.alloc(u8, filler_len);
    defer allocator.free(filler);
    try readRemoteTestExact(fds[1], filler);
    while (!(try rr.pumpQueuedInput())) {}
    while (!(try client.pumpPendingOutput())) {}

    const a_frame = try framing.encodeFrame(allocator, .{ .kind = .input_bytes, .stream_id = 9 }, "A");
    defer allocator.free(a_frame);
    const scroll_frame = try framing.encodeFrame(allocator, .{ .kind = .scroll_to_bottom, .stream_id = 9 }, "");
    defer allocator.free(scroll_frame);
    const b_frame = try framing.encodeFrame(allocator, .{ .kind = .input_bytes, .stream_id = 9 }, "B");
    defer allocator.free(b_frame);
    const received = try allocator.alloc(u8, a_frame.len + scroll_frame.len + b_frame.len);
    defer allocator.free(received);
    try readRemoteTestExact(fds[1], received);
    var offset: usize = 0;
    try testing.expectEqualSlices(u8, a_frame, received[offset..][0..a_frame.len]);
    offset += a_frame.len;
    try testing.expectEqualSlices(u8, scroll_frame, received[offset..][0..scroll_frame.len]);
    offset += scroll_frame.len;
    try testing.expectEqualSlices(u8, b_frame, received[offset..][0..b_frame.len]);
    try testing.expectEqual(@as(usize, 0), rr.direct_input.items.len);
    try testing.expectEqual(@as(usize, 0), rr.pending_controls.items.len);
}

test "remote runtime preserves input core-command input order under socket backpressure" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fds: [2]c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    socket_server.setNoSigPipe(fds[0]);
    defer _ = c.close(fds[1]);

    var client = client_mod.Client{
        .allocator = allocator,
        .fd = fds[0],
        .host_id = 1,
        .runtime_core_command_v1 = true,
        .parser = framing.FrameParser.init(allocator),
    };
    defer client.deinit();
    var rr: RemoteRuntime = undefined;
    rr.client = &client;
    rr.allocator = allocator;
    rr.stream_id = 10;
    rr.direct_input = .empty;
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
    defer rr.direct_input.deinit(allocator);
    defer rr.pending_controls.deinit(allocator);

    const filler_len = try fillRemoteTestSendBuffer(fds[0]);
    try testing.expectEqual(@as(usize, 1), try client.sendInputNonBlocking(10, "A"));
    try rr.queueCoreCommand(.{ .report_focus = true });
    try rr.sendInput("B");
    try testing.expectEqual(@as(usize, 1), rr.pending_controls.items.len);

    const filler = try allocator.alloc(u8, filler_len);
    defer allocator.free(filler);
    try readRemoteTestExact(fds[1], filler);
    while (!(try rr.pumpQueuedInput())) {}
    while (!(try client.pumpPendingOutput())) {}

    const a_frame = try framing.encodeFrame(allocator, .{ .kind = .input_bytes, .stream_id = 10 }, "A");
    defer allocator.free(a_frame);
    const params = try core_command_wire.encodeParams(allocator, 10, .{ .report_focus = true });
    defer allocator.free(params);
    const command_frame = try framing.encodeFrame(allocator, .{ .kind = .core_command, .stream_id = 10 }, params);
    defer allocator.free(command_frame);
    const b_frame = try framing.encodeFrame(allocator, .{ .kind = .input_bytes, .stream_id = 10 }, "B");
    defer allocator.free(b_frame);
    const received = try allocator.alloc(u8, a_frame.len + command_frame.len + b_frame.len);
    defer allocator.free(received);
    try readRemoteTestExact(fds[1], received);
    var offset: usize = 0;
    try testing.expectEqualSlices(u8, a_frame, received[offset..][0..a_frame.len]);
    offset += a_frame.len;
    try testing.expectEqualSlices(u8, command_frame, received[offset..][0..command_frame.len]);
    offset += command_frame.len;
    try testing.expectEqualSlices(u8, b_frame, received[offset..][0..b_frame.len]);
    try testing.expectEqual(@as(usize, 0), rr.pending_controls.items.len);
}

test "remote runtime control cap overflow fail-closes instead of silently losing final state" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fds: [2]c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    defer _ = c.close(fds[1]);
    var client = client_mod.Client{
        .allocator = allocator,
        .fd = fds[0],
        .host_id = 1,
        .runtime_core_command_v1 = true,
        .parser = framing.FrameParser.init(allocator),
    };
    defer client.deinit();
    var rr: RemoteRuntime = undefined;
    rr.client = &client;
    rr.allocator = allocator;
    rr.stream_id = 10;
    rr.direct_input = .empty;
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
    defer rr.direct_input.deinit(allocator);
    defer rr.pending_controls.deinit(allocator);
    for (0..RemoteRuntime.max_pending_controls) |_| {
        try rr.pending_controls.append(allocator, .{
            .barrier = 0,
            .op = .{ .core_command = .{ .report_focus = true } },
        });
    }
    try testing.expectError(error.ConnectionClosed, rr.queueCoreCommand(.{ .report_focus = false }));
    try testing.expect(client.unusable);
    var byte: [1]u8 = undefined;
    try testing.expectEqual(@as(isize, 0), c.read(fds[1], &byte, byte.len));
}

test "remote runtime control allocation failure also fail-closes instead of silently losing final state" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fds: [2]c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    defer _ = c.close(fds[1]);
    var client = client_mod.Client{
        .allocator = allocator,
        .fd = fds[0],
        .host_id = 1,
        .runtime_core_command_v1 = true,
        .parser = framing.FrameParser.init(allocator),
    };
    defer client.deinit();
    var failing = testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var rr: RemoteRuntime = undefined;
    rr.client = &client;
    rr.allocator = failing.allocator();
    rr.stream_id = 10;
    rr.direct_input = .empty;
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
    rr.transport_failed = false;
    defer rr.pending_controls.deinit(rr.allocator);

    try testing.expectError(error.ConnectionClosed, rr.queueCoreCommand(.{ .report_focus = false }));
    try testing.expect(client.unusable);
    var byte: [1]u8 = undefined;
    try testing.expectEqual(@as(isize, 0), c.read(fds[1], &byte, byte.len));
}

test "remote runtime owns exact-cap key after client encode OOM and rejects cap plus one" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fds: [2]c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    socket_server.setNoSigPipe(fds[0]);
    defer _ = c.close(fds[1]);

    var failing = testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var client = client_mod.Client{
        .allocator = failing.allocator(),
        .fd = fds[0],
        .host_id = 1,
        .parser = framing.FrameParser.init(failing.allocator()),
    };
    defer client.deinit();
    var rr: RemoteRuntime = undefined;
    rr.client = &client;
    rr.allocator = allocator;
    rr.stream_id = 11;
    rr.direct_input = .empty;
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
    defer rr.direct_input.deinit(allocator);
    defer rr.pending_controls.deinit(allocator);
    try rr.direct_input.ensureTotalCapacity(allocator, RemoteRuntime.max_direct_input_bytes);

    const exact = try allocator.alloc(u8, RemoteRuntime.max_direct_input_bytes);
    defer allocator.free(exact);
    @memset(exact, 'K');
    // Client frame allocation fails after RemoteRuntime admission. The call still succeeds because the FIFO now
    // owns the key bytes; reporting failure here would permit a caller retry and duplicate later delivery.
    try rr.sendInput(exact);
    try testing.expectEqual(RemoteRuntime.max_direct_input_bytes, rr.direct_input.items.len);
    try testing.expectError(error.OutOfMemory, rr.sendInput("X"));
    try testing.expectEqual(RemoteRuntime.max_direct_input_bytes, rr.direct_input.items.len);

    failing.fail_index = std.math.maxInt(usize);
    const expected = try framing.encodeFrame(
        allocator,
        .{ .kind = .input_bytes, .stream_id = 11 },
        exact,
    );
    defer allocator.free(expected);
    var peer_ok = false;
    const peer = try std.Thread.spawn(.{}, remoteOrderingPeer, .{ fds[1], expected, "", &peer_ok });
    while (!(try rr.pumpQueuedInput())) {}
    while (!(try client.pumpPendingOutput())) {}
    peer.join();
    try testing.expect(peer_ok);
    try testing.expectEqual(@as(usize, 0), rr.direct_input.items.len);
}

test "remote runtime compaction rebases a pending scroll barrier" {
    const allocator = testing.allocator;
    var rr: RemoteRuntime = undefined;
    rr.direct_input = .empty;
    defer rr.direct_input.deinit(allocator);
    rr.pending_controls = .empty;
    defer rr.pending_controls.deinit(allocator);
    try rr.direct_input.appendSlice(allocator, "ABC");
    rr.direct_input_offset = 1;
    try rr.pending_controls.append(allocator, .{ .barrier = 2, .op = .scroll_to_bottom });
    rr.compactDirectInput();
    try testing.expectEqualStrings("BC", rr.direct_input.items);
    try testing.expectEqual(@as(usize, 0), rr.direct_input_offset);
    try testing.expectEqual(@as(usize, 1), rr.pending_controls.items[0].barrier);
}

test "remote runtime flushes key and scroll barrier before mouse RPC" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fds: [2]c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    socket_server.setNoSigPipe(fds[0]);
    defer _ = c.close(fds[1]);

    var client = client_mod.Client{
        .allocator = allocator,
        .fd = fds[0],
        .host_id = 1,
        .async_scroll_to_bottom_v1 = true,
        .parser = framing.FrameParser.init(allocator),
    };
    defer client.deinit();
    var rr: RemoteRuntime = undefined;
    rr.client = &client;
    rr.allocator = allocator;
    rr.stream_id = 13;
    rr.direct_input = .empty;
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
    defer rr.direct_input.deinit(allocator);
    defer rr.pending_controls.deinit(allocator);

    const filler_len = try fillRemoteTestSendBuffer(fds[0]);
    try testing.expectEqual(@as(usize, 1), try client.sendInputNonBlocking(13, "A"));
    try rr.requestScrollToBottom();
    try rr.sendInput("B");
    const filler = try allocator.alloc(u8, filler_len);
    defer allocator.free(filler);
    try readRemoteTestExact(fds[1], filler);

    const a_frame = try framing.encodeFrame(allocator, .{ .kind = .input_bytes, .stream_id = 13 }, "A");
    defer allocator.free(a_frame);
    const scroll_frame = try framing.encodeFrame(allocator, .{ .kind = .scroll_to_bottom, .stream_id = 13 }, "");
    defer allocator.free(scroll_frame);
    const b_frame = try framing.encodeFrame(allocator, .{ .kind = .input_bytes, .stream_id = 13 }, "B");
    defer allocator.free(b_frame);
    const params = "{\"stream_id\":13,\"button\":0,\"col\":2,\"row\":3,\"x_px\":4,\"y_px\":5,\"pressed\":true,\"motion\":false,\"mods\":0}";
    const request_payload = try std.fmt.allocPrint(
        allocator,
        "{{\"method\":\"runtime.report_mouse\",\"params\":{s}}}",
        .{params},
    );
    defer allocator.free(request_payload);
    const request_frame = try framing.encodeFrame(
        allocator,
        .{ .kind = .request, .request_id = 1 },
        request_payload,
    );
    defer allocator.free(request_frame);
    const expected = try allocator.alloc(u8, a_frame.len + scroll_frame.len + b_frame.len + request_frame.len);
    defer allocator.free(expected);
    var offset: usize = 0;
    @memcpy(expected[offset..][0..a_frame.len], a_frame);
    offset += a_frame.len;
    @memcpy(expected[offset..][0..scroll_frame.len], scroll_frame);
    offset += scroll_frame.len;
    @memcpy(expected[offset..][0..b_frame.len], b_frame);
    offset += b_frame.len;
    @memcpy(expected[offset..][0..request_frame.len], request_frame);
    const response = try framing.encodeFrame(
        allocator,
        .{ .kind = .response, .request_id = 1 },
        "{\"result\":{\"ok\":true}}",
    );
    defer allocator.free(response);
    var peer_ok = false;
    const peer = try std.Thread.spawn(.{}, remoteOrderingPeer, .{ fds[1], expected, response, &peer_ok });
    rr.sendMouseReport(.{
        .button = 0,
        .col = 2,
        .row = 3,
        .x_px = 4,
        .y_px = 5,
        .pressed = true,
        .motion = false,
        .mods = 0,
    }) catch |err| {
        peer.join();
        return err;
    };
    peer.join();
    try testing.expect(peer_ok);
    try testing.expectEqual(@as(usize, 0), rr.direct_input.items.len);
    try testing.expectEqual(@as(usize, 0), rr.pending_controls.items.len);
}

test "remote runtime lifecycle cleanup fail-closes the connection on persistent allocator OOM" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fds: [2]c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    socket_server.setNoSigPipe(fds[0]);
    defer _ = c.close(fds[1]);

    var failing = testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var client = client_mod.Client{
        .allocator = failing.allocator(),
        .fd = fds[0],
        .host_id = 1,
        .parser = framing.FrameParser.init(failing.allocator()),
    };
    defer client.deinit();
    var rr: RemoteRuntime = undefined;
    rr.client = &client;
    rr.allocator = allocator;
    rr.stream_id = 17;
    rr.direct_input = .empty;
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
    defer rr.direct_input.deinit(allocator);
    defer rr.pending_controls.deinit(allocator);

    // FailingAllocator는 fail_index에서 계속 실패한다. detach request를 만들 수 없어도 shared socket을 닫아
    // host EOF cleanup이 controller lease를 회수해야 한다.
    rr.detachBestEffort();
    try testing.expect(client.unusable);
    try testing.expectEqual(@as(c.fd_t, -1), client.fd);
    var byte: [1]u8 = undefined;
    try testing.expectEqual(@as(isize, 0), c.read(fds[1], &byte, byte.len));
}

const daemon = @import("daemon.zig");

extern "c" fn usleep(usec: c_uint) c_int;

test "remote runtime: spawns over the wire, renders host screen into a Surface, and reflects input via delta" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = testing.io;

    var dir_buf: [256]u8 = undefined;
    const dir_path = std.fmt.bufPrintZ(&dir_buf, "/tmp/maru-sh-rr-{d}", .{c.getpid()}) catch return error.SkipZigTest;
    var sp_buf: [320]u8 = undefined;
    const socket_path = std.fmt.bufPrintZ(&sp_buf, "{s}/control.sock", .{dir_path}) catch return error.SkipZigTest;

    const child = c.fork();
    if (child < 0) return error.SkipZigTest;
    if (child == 0) {
        _ = c.setsid();
        daemon.runSessionHost(std.heap.page_allocator, io, dir_path, socket_path) catch {};
        std.c._exit(0);
    }
    defer {
        _ = c.kill(child, posix.SIG.TERM);
        var status: c_int = undefined;
        _ = c.waitpid(child, &status, 0);
        _ = c.unlink(socket_path.ptr);
        _ = c.rmdir(dir_path.ptr);
    }

    var client: client_mod.Client = blk: {
        var attempts: usize = 0;
        while (attempts < 150) : (attempts += 1) {
            if (client_mod.Client.connect(allocator, socket_path, "gui")) |cl| break :blk cl else |_| _ = usleep(20 * 1000);
        }
        try testing.expect(false);
        return;
    };
    defer client.deinit();

    // client-side 원격 runtime: 화면 밖 metadata OSC를 먼저 emit한 뒤 cat으로 전환한다. 실제 독립 host reader가
    // cwd/title/SSH destination을 소유 core에 파싱하고 event wire로 client cache까지 보내는 제품 경로를 함께 고정한다.
    var rr: RemoteRuntime = undefined;
    try rr.spawn(&client, allocator, io, 1, .{
        .command = "/bin/sh",
        .args = &.{
            "-c",
            "printf '\\033]7;file://localhost/tmp/remote-meta\\007\\033]2;remote-title\\007\\033]5379;ssh;user@workbox\\007'; exec /bin/cat",
        },
    }, .{ .cols = 40, .rows = 10 });
    defer rr.deinit();

    // Surface가 원격 화면을 렌더한다(초기 cat 화면 = 빈 40x10).
    const surface = rr.surfacePtr();
    surface.lockCore(io);
    const cols0 = surface.renderSnapshot().size.cols;
    surface.unlockCore(io);
    try testing.expectEqual(@as(u16, 40), cols0);

    var metadata_found = false;
    var metadata_attempts: usize = 0;
    while (metadata_attempts < 100 and !metadata_found) : (metadata_attempts += 1) {
        _ = rr.pumpDelta() catch break;
        metadata_found = std.mem.eql(u8, rr.observation.cwd.items, "/tmp/remote-meta");
        if (!metadata_found) _ = usleep(20 * 1000);
    }
    try testing.expect(metadata_found);
    try testing.expectEqualStrings("remote-title", rr.observation.window_title.items);
    try testing.expect(rr.observation.ssh_remote_dest_present);
    try testing.expectEqualStrings("user@workbox", rr.observation.ssh_remote_dest.items);

    // 입력을 보내면 host가 echo → 화면 row0이 바뀌고 delta가 온다. pumpDelta는 논블로킹이라 delta가 도착할 때까지 폴링한다
    // (host delta tick ~20ms). Surface에 "h"가 반영되는지 본다.
    try rr.sendInput("hello\n");
    var found = false;
    var attempts: usize = 0;
    while (attempts < 100 and !found) : (attempts += 1) {
        _ = rr.pumpDelta() catch break;
        surface.lockCore(io);
        const c0 = surface.renderSnapshot().cells[0].codepoint;
        surface.unlockCore(io);
        if (c0 == 'h') found = true else _ = usleep(20 * 1000);
    }
    try testing.expect(found); // 원격 runtime의 화면 변화가 client Surface에 반영됐다.
}

// code-review #1 회귀 — 두 원격 runtime이 **connection 하나**를 공유할 때, 예전엔 한 runtime의 pump가 소켓에서 다른
// runtime의 배치를 읽어 free해(discard) 두 번째 화면이 영구 유실됐다. client의 stream_id demux가 남의 배치를 버퍼해 그
// runtime pump로 보내므로 **둘 다** 자기 echo를 화면에 반영해야 한다. 실 fork host + 실 socket이라 macOS opt-in.
test "remote runtime: two runtimes sharing one connection both receive their own screen updates (demux)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = testing.io;

    var dir_buf: [256]u8 = undefined;
    const dir_path = std.fmt.bufPrintZ(&dir_buf, "/tmp/maru-sh-rr-mux-{d}", .{c.getpid()}) catch return error.SkipZigTest;
    var sp_buf: [320]u8 = undefined;
    const socket_path = std.fmt.bufPrintZ(&sp_buf, "{s}/control.sock", .{dir_path}) catch return error.SkipZigTest;

    const child = c.fork();
    if (child < 0) return error.SkipZigTest;
    if (child == 0) {
        _ = c.setsid();
        daemon.runSessionHost(std.heap.page_allocator, io, dir_path, socket_path) catch {};
        std.c._exit(0);
    }
    defer {
        _ = c.kill(child, posix.SIG.TERM);
        var status: c_int = undefined;
        _ = c.waitpid(child, &status, 0);
        _ = c.unlink(socket_path.ptr);
        _ = c.rmdir(dir_path.ptr);
    }

    var client: client_mod.Client = blk: {
        var attempts: usize = 0;
        while (attempts < 150) : (attempts += 1) {
            if (client_mod.Client.connect(allocator, socket_path, "gui")) |cl| break :blk cl else |_| _ = usleep(20 * 1000);
        }
        try testing.expect(false);
        return;
    };
    defer client.deinit();

    // 한 client에 두 원격 runtime을 띄운다(둘 다 /bin/cat). 서로 다른 host runtime → 서로 다른 stream_id로 attach된다.
    var rr1: RemoteRuntime = undefined;
    try rr1.spawn(&client, allocator, io, 1, .{ .command = "/bin/cat" }, .{ .cols = 40, .rows = 10 });
    defer rr1.deinit();
    var rr2: RemoteRuntime = undefined;
    try rr2.spawn(&client, allocator, io, 2, .{ .command = "/bin/cat" }, .{ .cols = 40, .rows = 10 });
    defer rr2.deinit();
    try testing.expect(rr1.stream_id != rr2.stream_id); // 공유 connection이지만 stream이 갈린다(demux 대상).

    const s1 = rr1.surfacePtr();
    const s2 = rr2.surfacePtr();

    // 각 runtime에 **다른** 입력을 보낸다 → host가 각자 echo → 각 stream에 delta가 온다. 두 pump를 매 tick 함께 돌려
    // (frame loop처럼) 둘 다 자기 echo('h'/'w')를 반영하는지 본다. demux 없으면 먼저 도는 pump가 남의 배치를 삼켜 하나는
    // 영영 못 받는다.
    try rr1.sendInput("hello\n");
    try rr2.sendInput("world\n");
    var f1 = false;
    var f2 = false;
    var attempts: usize = 0;
    while (attempts < 200 and !(f1 and f2)) : (attempts += 1) {
        _ = rr1.pumpDelta() catch break;
        _ = rr2.pumpDelta() catch break;
        s1.lockCore(io);
        const a = s1.renderSnapshot().cells[0].codepoint;
        s1.unlockCore(io);
        s2.lockCore(io);
        const b = s2.renderSnapshot().cells[0].codepoint;
        s2.unlockCore(io);
        if (a == 'h') f1 = true;
        if (b == 'w') f2 = true;
        if (!(f1 and f2)) _ = usleep(20 * 1000);
    }
    try testing.expect(f1); // rr1 화면이 자기 echo를 받았다.
    try testing.expect(f2); // rr2도 — 남의 pump에 배치를 뺏기지 않았다(demux).
}

test "remote runtime: attachExisting reconnects to a pre-existing host runtime and renders its screen" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = testing.io;

    var dir_buf: [256]u8 = undefined;
    const dir_path = std.fmt.bufPrintZ(&dir_buf, "/tmp/maru-sh-rr-att-{d}", .{c.getpid()}) catch return error.SkipZigTest;
    var sp_buf: [320]u8 = undefined;
    const socket_path = std.fmt.bufPrintZ(&sp_buf, "{s}/control.sock", .{dir_path}) catch return error.SkipZigTest;

    const child = c.fork();
    if (child < 0) return error.SkipZigTest;
    if (child == 0) {
        _ = c.setsid();
        daemon.runSessionHost(std.heap.page_allocator, io, dir_path, socket_path) catch {};
        std.c._exit(0);
    }
    defer {
        _ = c.kill(child, posix.SIG.TERM);
        var status: c_int = undefined;
        _ = c.waitpid(child, &status, 0);
        _ = c.unlink(socket_path.ptr);
        _ = c.rmdir(dir_path.ptr);
    }

    var client: client_mod.Client = blk: {
        var attempts: usize = 0;
        while (attempts < 150) : (attempts += 1) {
            if (client_mod.Client.connect(allocator, socket_path, "gui")) |cl| break :blk cl else |_| _ = usleep(20 * 1000);
        }
        try testing.expect(false);
        return;
    };
    defer client.deinit();

    // host에 runtime을 하나 띄운다(raw runtime.spawn — client controller 없이). runtime_id를 얻어 "재실행 후 재접속" 상황을 만든다.
    const spawn_resp = try client.call("runtime.spawn", "{\"argv\":[\"/bin/cat\"],\"cols\":40,\"rows\":10}");
    defer allocator.free(spawn_resp);
    const rid = client_mod.extractRuntimeId(spawn_resp) orelse {
        try testing.expect(false);
        return;
    };

    // **재접속**: attachExisting으로 그 runtime에 붙어 원격-backed Surface를 세운다(spawn 없이 — 저장된 runtime_id로).
    var rr: RemoteRuntime = undefined;
    try rr.attachExisting(&client, allocator, io, 1, rid, .{ .cols = 40, .rows = 10 });
    defer rr.deinit();
    try testing.expectEqual(rid, rr.runtimeIdHex()); // 재접속한 runtime_id가 저장한 값과 같다.

    const surface = rr.surfacePtr();
    surface.lockCore(io);
    const cols0 = surface.renderSnapshot().size.cols;
    surface.unlockCore(io);
    try testing.expectEqual(@as(u16, 40), cols0); // 그 runtime의 화면(빈 40x10 cat)을 조립했다.

    // 재접속한 controller로 입력→echo→화면 반영(재접속이 실제 제어권을 얻었다).
    try rr.sendInput("hi\n");
    var found = false;
    var attempts: usize = 0;
    while (attempts < 100 and !found) : (attempts += 1) {
        _ = rr.pumpDelta() catch break;
        surface.lockCore(io);
        const c0 = surface.renderSnapshot().cells[0].codepoint;
        surface.unlockCore(io);
        if (c0 == 'h') found = true else _ = usleep(20 * 1000);
    }
    try testing.expect(found);

    // 없는 runtime_id에 attachExisting → error.AttachFailed(host RuntimeNotFound). app_session restore는 이 신호를
    // 동일 세션 단절로 보고 fail-closed한다. 실패해도 남의 runtime을 안 죽인다(terminate errdefer 없음).
    var bogus: RemoteRuntime = undefined;
    const bogus_id: [32]u8 = "deadbeefdeadbeefdeadbeefdeadbeef".*;
    try testing.expectError(error.AttachFailed, bogus.attachExisting(&client, allocator, io, 2, bogus_id, .{ .cols = 40, .rows = 10 }));
}

test "remote runtime: takeNotification pulls a host-side OSC 9/777 desktop notification (§6.32)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = testing.io;

    var dir_buf: [256]u8 = undefined;
    const dir_path = std.fmt.bufPrintZ(&dir_buf, "/tmp/maru-sh-rr-notif-{d}", .{c.getpid()}) catch return error.SkipZigTest;
    var sp_buf: [320]u8 = undefined;
    const socket_path = std.fmt.bufPrintZ(&sp_buf, "{s}/control.sock", .{dir_path}) catch return error.SkipZigTest;

    const child = c.fork();
    if (child < 0) return error.SkipZigTest;
    if (child == 0) {
        _ = c.setsid();
        daemon.runSessionHost(std.heap.page_allocator, io, dir_path, socket_path) catch {};
        std.c._exit(0);
    }
    defer {
        _ = c.kill(child, posix.SIG.TERM);
        var status: c_int = undefined;
        _ = c.waitpid(child, &status, 0);
        _ = c.unlink(socket_path.ptr);
        _ = c.rmdir(dir_path.ptr);
    }

    var client: client_mod.Client = blk: {
        var attempts: usize = 0;
        while (attempts < 150) : (attempts += 1) {
            if (client_mod.Client.connect(allocator, socket_path, "gui")) |cl| break :blk cl else |_| _ = usleep(20 * 1000);
        }
        try testing.expect(false);
        return;
    };
    defer client.deinit();

    var rr: RemoteRuntime = undefined;
    try rr.spawn(&client, allocator, io, 1, .{ .command = "/bin/cat" }, .{ .cols = 40, .rows = 10 });
    defer rr.deinit();

    // 처음엔 대기 알림 없음(fresh cat).
    if (try rr.takeNotification()) |n| {
        n.deinit(allocator);
        try testing.expect(false);
    }

    // OSC 777 알림 시퀀스를 입력 → cat이 raw로 echo → host core가 파싱 → notification pending. 폴링으로 뺀다(host tick·echo 대기).
    try rr.sendInput("\x1b]777;notify;Deploy;done in 3s\x1b\\\n");
    var got: ?Notification = null;
    var attempts: usize = 0;
    while (attempts < 100 and got == null) : (attempts += 1) {
        got = try rr.takeNotification();
        if (got == null) _ = usleep(20 * 1000);
    }
    const n = got orelse {
        try testing.expect(false);
        return;
    };
    defer n.deinit(allocator);
    // host의 TerminalCore가 파싱한 OSC 777 title/body가 client로 전달됐다(host-backed 터미널의 알림이 유실 안 됨).
    try testing.expectEqualStrings("Deploy", n.title);
    try testing.expectEqualStrings("done in 3s", n.body);
}

// takeNotification의 수동 JSON 문자열 디코더(std.json.parseFromSlice의 f128 링크 회피). host의 std.json.Stringify escape를
// 되돈다 — 순수 함수라 fork host 없이 escape 처리를 고정한다(제어문자 \u00XX·\" \\ \n \t \uXXXX·키 부재·빈 값·둘째 필드).
test "remote runtime: decodeJsonStringField unescapes JSON string fields (parseFromSlice 대체)" {
    const allocator = testing.allocator;
    const decode = RemoteRuntime.decodeJsonStringField;

    // 단순 값 + 둘째 필드.
    const j1 = "{\"title\":\"Build\",\"body\":\"ok\"}";
    const t1 = (try decode(allocator, j1, "title")).?;
    defer allocator.free(t1);
    try testing.expectEqualStrings("Build", t1);
    const b1 = (try decode(allocator, j1, "body")).?;
    defer allocator.free(b1);
    try testing.expectEqualStrings("ok", b1);

    // escape: quote/backslash/newline/tab + 제어문자 u0007.
    const j2 = "{\"title\":\"a\\\"b\\\\c\\nd\\te\\u0007f\"}";
    const t2 = (try decode(allocator, j2, "title")).?;
    defer allocator.free(t2);
    try testing.expectEqualStrings("a\"b\\c\nd\te\x07f", t2);

    // 키 부재 → null.
    try testing.expect((try decode(allocator, j1, "nope")) == null);

    // 빈 값 → 빈 슬라이스(대기 알림 없음 판정용).
    const j3 = "{\"title\":\"\",\"body\":\"\"}";
    const t3 = (try decode(allocator, j3, "title")).?;
    defer allocator.free(t3);
    try testing.expectEqual(@as(usize, 0), t3.len);

    // 비-ASCII(UTF-8 passthrough — Stringify 기본은 raw).
    const j4 = "{\"body\":\"빌드 완료\"}";
    const b4 = (try decode(allocator, j4, "body")).?;
    defer allocator.free(b4);
    try testing.expectEqualStrings("빌드 완료", b4);
}

// code-review #7 end-to-end — requestResync(§9 desync 복구)가 host에 fresh snapshot을 재요청하면, host가 delta가 아니라
// **snapshot_chunk**(is_snapshot)를 push하는지 실 fork host로 고정한다. drainRemote가 GenerationGap/MalformedRow에서 이걸
// 불러 조립기 generation을 리셋해 "영구 멈춤" 대신 복구한다. macOS opt-in(실 forkpty·socket).
test "remote runtime: requestResync makes the host push a fresh snapshot (desync 복구)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = testing.io;

    var dir_buf: [256]u8 = undefined;
    const dir_path = std.fmt.bufPrintZ(&dir_buf, "/tmp/maru-sh-rr-rsy-{d}", .{c.getpid()}) catch return error.SkipZigTest;
    var sp_buf: [320]u8 = undefined;
    const socket_path = std.fmt.bufPrintZ(&sp_buf, "{s}/control.sock", .{dir_path}) catch return error.SkipZigTest;

    const child = c.fork();
    if (child < 0) return error.SkipZigTest;
    if (child == 0) {
        _ = c.setsid();
        daemon.runSessionHost(std.heap.page_allocator, io, dir_path, socket_path) catch {};
        std.c._exit(0);
    }
    defer {
        _ = c.kill(child, posix.SIG.TERM);
        var status: c_int = undefined;
        _ = c.waitpid(child, &status, 0);
        _ = c.unlink(socket_path.ptr);
        _ = c.rmdir(dir_path.ptr);
    }

    var client: client_mod.Client = blk: {
        var attempts: usize = 0;
        while (attempts < 150) : (attempts += 1) {
            if (client_mod.Client.connect(allocator, socket_path, "gui")) |cl| break :blk cl else |_| _ = usleep(20 * 1000);
        }
        try testing.expect(false);
        return;
    };
    defer client.deinit();

    var rr: RemoteRuntime = undefined;
    try rr.spawn(&client, allocator, io, 1, .{ .command = "/bin/cat" }, .{ .cols = 40, .rows = 10 });
    defer rr.deinit();

    // attach가 첫 snapshot을 이미 소비했다 — 이제 fresh snapshot을 **재요청**한다.
    try rr.requestResync();

    // host가 다음 delta tick에 snapshot_chunk를 push한다(delta 아님). 그 배치가 is_snapshot인지 확인한다(input 없어 delta는 안 옴).
    var saw_snapshot = false;
    var attempts: usize = 0;
    while (attempts < 150 and !saw_snapshot) : (attempts += 1) {
        if (try rr.client.readStreamBatch(allocator, rr.stream_id)) |batch| {
            defer allocator.free(batch.bytes);
            if (batch.is_snapshot) saw_snapshot = true;
        } else _ = usleep(20 * 1000);
    }
    try testing.expect(saw_snapshot); // resync 요청이 host의 fresh snapshot push를 유발했다(generation 리셋 = 복구 경로).
}

// code-review #6a end-to-end — 원격 스크롤백. 스크롤 core command를 host로 라우팅하면 host가 자기 core view_offset을 바꾸고,
// projectSnapshot/computeDelta가 renderSnapshot(뷰포트)을 써서 그 스크롤백 윈도를 client에 투영한다. TOPMARKER를 화면 밖
// (스크롤백)으로 민 뒤 위로 스크롤 → client 화면 최상단에 TOPMARKER가 나타나는지 실 fork host로 고정. macOS opt-in.
test "remote runtime: scroll core command routes to host so client sees scrolled-back content (§6a)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = testing.io;

    var dir_buf: [256]u8 = undefined;
    const dir_path = std.fmt.bufPrintZ(&dir_buf, "/tmp/maru-sh-rr-scr-{d}", .{c.getpid()}) catch return error.SkipZigTest;
    var sp_buf: [320]u8 = undefined;
    const socket_path = std.fmt.bufPrintZ(&sp_buf, "{s}/control.sock", .{dir_path}) catch return error.SkipZigTest;

    const child = c.fork();
    if (child < 0) return error.SkipZigTest;
    if (child == 0) {
        _ = c.setsid();
        daemon.runSessionHost(std.heap.page_allocator, io, dir_path, socket_path) catch {};
        std.c._exit(0);
    }
    defer {
        _ = c.kill(child, posix.SIG.TERM);
        var status: c_int = undefined;
        _ = c.waitpid(child, &status, 0);
        _ = c.unlink(socket_path.ptr);
        _ = c.rmdir(dir_path.ptr);
    }

    var client: client_mod.Client = blk: {
        var attempts: usize = 0;
        while (attempts < 150) : (attempts += 1) {
            if (client_mod.Client.connect(allocator, socket_path, "gui")) |cl| break :blk cl else |_| _ = usleep(20 * 1000);
        }
        try testing.expect(false);
        return;
    };
    defer client.deinit();

    var rr: RemoteRuntime = undefined;
    try rr.spawn(&client, allocator, io, 1, .{ .command = "/bin/cat" }, .{ .cols = 40, .rows = 8 });
    defer rr.deinit();
    const surface = rr.surfacePtr();

    // TOPMARKER 한 줄 + 8행을 넘기는 filler → TOPMARKER는 스크롤백으로 밀려 화면 밖(host 기본 scrollback 1000행).
    try rr.sendInput("TOPMARKER\n");
    var k: usize = 0;
    while (k < 20) : (k += 1) try rr.sendInput("filler\n");

    // host echo가 화면에 반영될 때까지 pump — 바닥엔 filler(row0 시작이 'f', TOPMARKER는 안 보임).
    var settled = false;
    var attempts: usize = 0;
    while (attempts < 200 and !settled) : (attempts += 1) {
        _ = rr.pumpDelta() catch break;
        surface.lockCore(io);
        const c0 = surface.renderSnapshot().cells[0].codepoint;
        surface.unlockCore(io);
        if (c0 == 'f') settled = true else _ = usleep(20 * 1000);
    }
    try testing.expect(settled); // 바닥 화면은 filler(TOPMARKER는 스크롤백)

    // **위로 스크롤**(host core view_offset 이동 → renderSnapshot 뷰포트가 스크롤백 윈도로) → 최상단에 TOPMARKER.
    try rr.queueCoreCommand(.{ .scroll = 100 }); // 위로 100(스크롤백 top으로 cap)

    var saw_marker = false;
    attempts = 0;
    while (attempts < 200 and !saw_marker) : (attempts += 1) {
        _ = rr.pumpDelta() catch break;
        surface.lockCore(io);
        const c0 = surface.renderSnapshot().cells[0].codepoint;
        surface.unlockCore(io);
        if (c0 == 'T') saw_marker = true else _ = usleep(20 * 1000);
    }
    try testing.expect(saw_marker); // 스크롤 명령이 host를 거쳐 client 화면을 스크롤백(TOPMARKER)으로 이동시켰다(#6a).
}

// code-review #6b end-to-end — 원격 선택 복사. client가 뷰포트 선택 span을 host로 보내면, host가 자기 core에 적용해
// **로컬과 같은 `extractSelection`**(선택 의미론 단일 출처)으로 텍스트를 뽑아 돌려주는지 실 fork host로 고정한다. 하이라이트는
// placeholder core(app_session)가 즉시 그리고, 이 복사만 host가 해석한다("client 렌더/host 해석"). macOS opt-in.
test "remote runtime: selectedText extracts the selection text on the host (§6b, extractSelection 재사용)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = testing.io;

    var dir_buf: [256]u8 = undefined;
    const dir_path = std.fmt.bufPrintZ(&dir_buf, "/tmp/maru-sh-rr-sel-{d}", .{c.getpid()}) catch return error.SkipZigTest;
    var sp_buf: [320]u8 = undefined;
    const socket_path = std.fmt.bufPrintZ(&sp_buf, "{s}/control.sock", .{dir_path}) catch return error.SkipZigTest;

    const child = c.fork();
    if (child < 0) return error.SkipZigTest;
    if (child == 0) {
        _ = c.setsid();
        daemon.runSessionHost(std.heap.page_allocator, io, dir_path, socket_path) catch {};
        std.c._exit(0);
    }
    defer {
        _ = c.kill(child, posix.SIG.TERM);
        var status: c_int = undefined;
        _ = c.waitpid(child, &status, 0);
        _ = c.unlink(socket_path.ptr);
        _ = c.rmdir(dir_path.ptr);
    }

    var client: client_mod.Client = blk: {
        var attempts: usize = 0;
        while (attempts < 150) : (attempts += 1) {
            if (client_mod.Client.connect(allocator, socket_path, "gui")) |cl| break :blk cl else |_| _ = usleep(20 * 1000);
        }
        try testing.expect(false);
        return;
    };
    defer client.deinit();

    var rr: RemoteRuntime = undefined;
    try rr.spawn(&client, allocator, io, 1, .{ .command = "/bin/cat" }, .{ .cols = 40, .rows = 8 });
    defer rr.deinit();
    const surface = rr.surfacePtr();

    // "HELLO"를 입력 → cat echo → host core row0 = "HELLO". RemoteScreen에 반영될 때까지 pump(= host가 처리 완료).
    try rr.sendInput("HELLO\n");
    var ready = false;
    var attempts: usize = 0;
    while (attempts < 200 and !ready) : (attempts += 1) {
        _ = rr.pumpDelta() catch break;
        surface.lockCore(io);
        const c0 = surface.renderSnapshot().cells[0].codepoint;
        surface.unlockCore(io);
        if (c0 == 'H') ready = true else _ = usleep(20 * 1000);
    }
    try testing.expect(ready);

    // 뷰포트 선택 span (0,0)~(0,4) = row0의 "HELLO"를 host에 보내 host가 extractSelection으로 뽑는다.
    const span: terminal.SelectionSpan = .{ .start = .{ .row = 0, .col = 0 }, .end = .{ .row = 0, .col = 4 }, .block = false };
    const text = (try rr.selectedText(span)) orelse {
        try testing.expect(false);
        return;
    };
    defer allocator.free(text);
    try testing.expectEqualStrings("HELLO", text); // host가 자기 core에서 선택 텍스트를 뽑아 client로 전달했다(선택 의미론=host).

    // 앱보다 먼저 떠 있던 같은-major 구 host를 협상 결과로 재현한다. 실제 host snapshot으로 조립한 RemoteScreen만
    // 남아 있고 placeholder core는 비어 있으므로, 이 assertion은 fallback이 렌더 projection을 읽는지 제품과 같은
    // 조건으로 검증한다(옛 잘못된 테스트처럼 placeholder에 문자열을 직접 쓰지 않는다).
    client.runtime_selected_text_v1 = false;
    const legacy_text = (try rr.selectedText(span)) orelse {
        try testing.expect(false);
        return;
    };
    defer allocator.free(legacy_text);
    try testing.expectEqualStrings("HELLO", legacy_text);
}

// code-review #6b-2 end-to-end — 단어/줄 선택. 빈 client placeholder는 단어/줄 경계를 모르므로 host가 콘텐츠로 계산해
// span을 돌려준다(selectContentAware → runtime.select_op). 그 span으로 selectedText를 부르면(=client가 placeholder에 적용 후
// #6b-1 복사와 같은 경로) 그 단어/줄 텍스트가 나온다. 실 fork host로 왕복 고정. macOS opt-in.
test "remote runtime: selectContentAware computes word/line boundaries on the host (§6b-2)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = testing.io;

    var dir_buf: [256]u8 = undefined;
    const dir_path = std.fmt.bufPrintZ(&dir_buf, "/tmp/maru-sh-rr-wl-{d}", .{c.getpid()}) catch return error.SkipZigTest;
    var sp_buf: [320]u8 = undefined;
    const socket_path = std.fmt.bufPrintZ(&sp_buf, "{s}/control.sock", .{dir_path}) catch return error.SkipZigTest;

    const child = c.fork();
    if (child < 0) return error.SkipZigTest;
    if (child == 0) {
        _ = c.setsid();
        daemon.runSessionHost(std.heap.page_allocator, io, dir_path, socket_path) catch {};
        std.c._exit(0);
    }
    defer {
        _ = c.kill(child, posix.SIG.TERM);
        var status: c_int = undefined;
        _ = c.waitpid(child, &status, 0);
        _ = c.unlink(socket_path.ptr);
        _ = c.rmdir(dir_path.ptr);
    }

    var client: client_mod.Client = blk: {
        var attempts: usize = 0;
        while (attempts < 150) : (attempts += 1) {
            if (client_mod.Client.connect(allocator, socket_path, "gui")) |cl| break :blk cl else |_| _ = usleep(20 * 1000);
        }
        try testing.expect(false);
        return;
    };
    defer client.deinit();

    var rr: RemoteRuntime = undefined;
    try rr.spawn(&client, allocator, io, 1, .{ .command = "/bin/cat" }, .{ .cols = 40, .rows = 8 });
    defer rr.deinit();
    const surface = rr.surfacePtr();

    // "foo bar"를 입력 → cat echo → host core row0. RemoteScreen 반영까지 pump.
    try rr.sendInput("foo bar\n");
    var ready = false;
    var attempts: usize = 0;
    while (attempts < 200 and !ready) : (attempts += 1) {
        _ = rr.pumpDelta() catch break;
        surface.lockCore(io);
        const c0 = surface.renderSnapshot().cells[0].codepoint;
        surface.unlockCore(io);
        if (c0 == 'f') ready = true else _ = usleep(20 * 1000);
    }
    try testing.expect(ready);

    // (0,0)의 **단어** = "foo"를 host가 경계 계산 → span. 그 span으로 텍스트를 뽑으면 "foo".
    const word_span = (try rr.selectContentAware("word", 0, 0)) orelse {
        try testing.expect(false);
        return;
    };
    try testing.expectEqual(@as(u16, 0), word_span.start.col); // "foo" 시작
    const word = (try rr.selectedText(word_span)) orelse {
        try testing.expect(false);
        return;
    };
    defer allocator.free(word);
    try testing.expectEqualStrings("foo", word); // host가 공백 경계로 단어를 잡았다(빈 placeholder는 못 함).

    // **줄** 선택 = row0 전체 "foo bar".
    const line_span = (try rr.selectContentAware("line", 0, 0)) orelse {
        try testing.expect(false);
        return;
    };
    const line = (try rr.selectedText(line_span)) orelse {
        try testing.expect(false);
        return;
    };
    defer allocator.free(line);
    try testing.expectEqualStrings("foo bar", line); // 줄 전체(host 계산).
}

// code-review #6c end-to-end — 원격 검색. 빈 client placeholder는 검색을 못 하므로 host가 자기 core(콘텐츠·스크롤백)에서
// findMatches로 매치를 찾아 보이는 뷰포트 span을 돌려주는지 실 fork host로 고정한다(검색 의미론 host 단일 출처). macOS opt-in.
test "remote runtime: find matches on the host and returns viewport spans (§6c)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = testing.io;

    var dir_buf: [256]u8 = undefined;
    const dir_path = std.fmt.bufPrintZ(&dir_buf, "/tmp/maru-sh-rr-find-{d}", .{c.getpid()}) catch return error.SkipZigTest;
    var sp_buf: [320]u8 = undefined;
    const socket_path = std.fmt.bufPrintZ(&sp_buf, "{s}/control.sock", .{dir_path}) catch return error.SkipZigTest;

    const child = c.fork();
    if (child < 0) return error.SkipZigTest;
    if (child == 0) {
        _ = c.setsid();
        daemon.runSessionHost(std.heap.page_allocator, io, dir_path, socket_path) catch {};
        std.c._exit(0);
    }
    defer {
        _ = c.kill(child, posix.SIG.TERM);
        var status: c_int = undefined;
        _ = c.waitpid(child, &status, 0);
        _ = c.unlink(socket_path.ptr);
        _ = c.rmdir(dir_path.ptr);
    }

    var client: client_mod.Client = blk: {
        var attempts: usize = 0;
        while (attempts < 150) : (attempts += 1) {
            if (client_mod.Client.connect(allocator, socket_path, "gui")) |cl| break :blk cl else |_| _ = usleep(20 * 1000);
        }
        try testing.expect(false);
        return;
    };
    defer client.deinit();

    var rr: RemoteRuntime = undefined;
    try rr.spawn(&client, allocator, io, 1, .{ .command = "/bin/cat" }, .{ .cols = 40, .rows = 8 });
    defer rr.deinit();
    const surface = rr.surfacePtr();

    // "xyz"를 입력. PTY는 **라인 에코 + cat 출력**으로 같은 줄을 2번 낸다(row0=에코, row1=cat) → "xyz" 매치 2개.
    // 결정적이려면 두 줄이 다 올 때까지(row1[0]=='x') 기다린다.
    try rr.sendInput("xyz\n");
    var ready = false;
    var attempts: usize = 0;
    while (attempts < 200 and !ready) : (attempts += 1) {
        _ = rr.pumpDelta() catch break;
        surface.lockCore(io);
        const snap = surface.renderSnapshot();
        const row1_c0 = snap.cells[snap.size.cols].codepoint; // row1 col0
        surface.unlockCore(io);
        if (row1_c0 == 'x') ready = true else _ = usleep(20 * 1000);
    }
    try testing.expect(ready);

    // "xyz" 검색(현재 매치=index 0) → host가 2개(에코 줄=row0 + cat 줄=row1) 찾고, cur=현재(row0)·spans=비현재(row1).
    var spans: std.ArrayList(terminal.SelectionSpan) = .empty;
    defer spans.deinit(allocator);
    const r0 = try rr.find("xyz", 0, false, &spans);
    try testing.expectEqual(@as(usize, 2), r0.count); // 전체 매치 수
    try testing.expect(r0.cur != null); // 현재 매치(index0) 뷰포트 span
    try testing.expectEqual(@as(u16, 0), r0.cur.?.start.row); // 현재 매치는 row0
    try testing.expectEqual(@as(usize, 1), spans.items.len); // 비현재 보이는 매치 = row1 1개
    try testing.expectEqual(@as(u16, 1), spans.items[0].start.row);

    // §6c-2 네비: 현재 매치를 index 1로 → cur=row1, 비현재=row0. (host가 cur_index로 현재 매치를 가른다)
    const r1 = try rr.find("xyz", 1, false, &spans);
    try testing.expectEqual(@as(usize, 2), r1.count);
    try testing.expect(r1.cur != null);
    try testing.expectEqual(@as(u16, 1), r1.cur.?.start.row); // 현재 매치가 row1로 바뀜
    try testing.expectEqual(@as(u16, 0), spans.items[0].start.row); // 비현재 = row0

    // scroll=true(⌘G 네비)도 크래시 없이 현재 매치를 준다(내용이 다 보여 scrollToAbs는 사실상 무이동).
    const rs = try rr.find("xyz", 0, true, &spans);
    try testing.expectEqual(@as(usize, 2), rs.count);

    // 없는 검색어 → 0.
    const zero = try rr.find("zzz", 0, false, &spans);
    try testing.expectEqual(@as(usize, 0), zero.count);
    try testing.expect(zero.cur == null);
    try testing.expectEqual(@as(usize, 0), spans.items.len);
}
