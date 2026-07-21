//! session-host **connection dispatch state machine**(§10 hello·command 순서). 한 client connection이 보낸 MRSH
//! frame을 받아 hello를 협상하고 read-only command를 `TerminalRuntimeRegistry`로 dispatch해 응답 frame을 만든다.
//!
//! 이 파일은 **순수 상태 기계**다 — socket·fd·프로세스를 모른다(platform import 0). 실제 unix socket bind/accept/
//! peer-cred와 read/write loop는 P3-d1의 platform 통합 층이 이 `Connection.handleFrame`을 구동하고, on-demand
//! detached-helper launch와 `maru-sessiond` entrypoint는 P3-d2다. 이렇게 나눠야 hello/command 계약을 실 socket 없이
//! non-macOS에서 TDD하고, control-plane(`maru.control.v1`)과 wire·ID를 섞지 않는다(§10).
//!
//! v1 규칙:
//!   - connection의 첫 frame은 반드시 `hello`다. 아니면 protocol error로 connection을 닫는다(runtime은 유지).
//!   - client `{protocol_min, protocol_max}`가 host major(1)를 포함하지 않으면 attach 전에 `incompatible_version`으로 끝낸다.
//!   - d1이 dispatch하는 command는 **read-only**다: `host.info`, `runtime.list`, `runtime.get`. host를 auto-start하지
//!     않는 조회 명령이라 실 runtime 소유·spawn/attach(P3-d2 이후)와 무관하게 registry 상태만 읽는다.

const std = @import("std");
const protocol = @import("protocol.zig");
const framing = @import("framing.zig");
const reg = @import("registry.zig");

/// hello가 밝히는 client 종류. GUI window인지 CLI(`maru attach`)인지 — 권한/표시에 쓴다(§9).
pub const ClientKind = enum { gui, cli, unknown };

/// `runtime.spawn`의 중립 파라미터(server가 JSON에서 파싱해 넘긴다). host가 이 argv/크기로 실 PTY를 띄운다.
pub const RuntimeSpawnParams = struct {
    /// `[command, args...]` — argv[0]은 실행 파일 경로. server는 JSON string 배열만 파싱하고 프로세스는 host가 띄운다.
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    cols: u16,
    rows: u16,
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
};

/// `handleFrame`이 caller(socket write loop)에게 지시하는 것. `reply`/`reply_and_close`의 바이트는 **caller 소유**다
/// (socket에 write한 뒤 free). `close`는 응답 없이 connection을 닫으라는 뜻이다(runtime에는 손대지 않는다).
pub const Action = union(enum) {
    reply: []u8,
    reply_and_close: []u8,
    close,
    /// 응답 없이 connection을 유지한다(input_bytes 같은 fire-and-forget stream frame 처리 후). caller는 아무것도 write하지 않는다.
    none,
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
    /// 이 connection이 연 `stream_id`→`runtime_id` 매핑(§9 attach subscription). input_bytes/resize/detach가 stream_id로
    /// runtime을 찾고, connection 종료 시 이 목록을 모두 detach한다. host가 stream_id를 발급한다(현재 per-connection 단조 —
    /// serial serve 전제라 stream_id가 겹치지 않는다; 동시 연결을 여는 후속에서 host-global 발급으로 승격한다).
    attachments: std.AutoHashMapUnmanaged(reg.StreamId, u128) = .empty,
    next_stream_id: reg.StreamId = 1,

    pub const State = enum { pre_hello, ready, closed };

    pub fn init(allocator: std.mem.Allocator, host_id: u128, registry: *reg.TerminalRuntimeRegistry) Connection {
        return .{ .allocator = allocator, .host_id = host_id, .registry = registry };
    }

    /// connection 종료(EOF/close) 시 이 connection의 모든 subscription을 registry에서 뗀다(§9 "EOF는 모든 stream을
    /// detach하지만 runtime/child에는 종료 신호를 보내지 않는다"). runtime이 이미 없으면(동시 terminate) 무시한다.
    pub fn deinit(self: *Connection) void {
        var it = self.attachments.iterator();
        while (it.next()) |e| {
            _ = self.registry.detach(e.value_ptr.*, e.key_ptr.*) catch {};
        }
        self.attachments.deinit(self.allocator);
        self.* = undefined;
    }

    /// MRSH frame 하나를 처리한다. connection state에 따라 hello 협상 또는 command dispatch를 하고, 응답 frame을
    /// 만들어 `Action`으로 돌려준다. 응답이 없거나 protocol을 어긴 경우 `.close`다(runtime은 유지).
    pub fn handleFrame(self: *Connection, frame: framing.Frame) HandleError!Action {
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
            return self.dispatchSpawn(frame.header.request_id, params);
        } else if (std.mem.eql(u8, method, "runtime.terminate")) {
            return self.dispatchTerminate(frame.header.request_id, params);
        } else if (std.mem.eql(u8, method, "runtime.attach")) {
            return self.dispatchAttach(frame.header.request_id, params);
        } else if (std.mem.eql(u8, method, "runtime.detach")) {
            return self.dispatchDetach(frame.header.request_id, params);
        } else if (std.mem.eql(u8, method, "runtime.resize")) {
            return self.dispatchResize(frame.header.request_id, params);
        }
        return self.replyError(frame.header.request_id, .invalid_request);
    }

    /// `runtime.spawn`: read-only host면 unauthorized. argv/cwd/cols/rows를 파싱해 `RuntimeOps`로 실 PTY를 띄우고
    /// `runtime_id`(hex)를 응답한다. argv는 비어 있으면 invalid_request, spawn 실패는 internal.
    fn dispatchSpawn(self: *Connection, request_id: u64, params: ?std.json.ObjectMap) HandleError!Action {
        const ops = self.runtime_ops orelse return self.replyError(request_id, .unauthorized);
        const p = params orelse return self.replyError(request_id, .invalid_request);
        const argv_val = switch (p.get("argv") orelse std.json.Value.null) {
            .array => |arr| arr,
            else => return self.replyError(request_id, .invalid_request),
        };
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        for (argv_val.items) |item| {
            const s = switch (item) {
                .string => |str| str,
                else => return self.replyError(request_id, .invalid_request),
            };
            argv.append(a, s) catch return error.OutOfMemory;
        }
        if (argv.items.len == 0) return self.replyError(request_id, .invalid_request);
        const runtime_id = ops.spawn(ops.ctx, .{
            .argv = argv.items,
            .cwd = strField(p, "cwd"),
            .cols = intField(p, "cols") orelse 80,
            .rows = intField(p, "rows") orelse 24,
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
    /// 부여하고 host가 발급한 `stream_id`·granted·`controller_busy`를 응답한다. 실 화면 stream(snapshot/delta)과 takeover
    /// revocation 이벤트는 이 subscription 위에 e2d(event fan-out)에서 얹는다 — attach 자체는 capability state만 세운다.
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
        self.attachments.put(self.allocator, stream, id.?) catch {
            _ = self.registry.detach(id.?, stream) catch {}; // 매핑 실패 시 registry subscription을 되돌린다(유령 subscription 방지).
            return error.OutOfMemory;
        };
        self.next_stream_id += 1;

        const body = try self.stringify(.{ .result = .{
            .stream_id = stream,
            .granted = .{
                .observe = reg.Capability.has(outcome.granted, reg.Capability.observe),
                .input = reg.Capability.has(outcome.granted, reg.Capability.input),
                .resize = reg.Capability.has(outcome.granted, reg.Capability.resize),
            },
            .controller_busy = outcome.controller_busy,
        } });
        defer self.allocator.free(body);
        return self.replyResult(request_id, body);
    }

    /// `runtime.detach`: 이 connection의 한 subscription을 뗀다(§9). runtime은 유지된다. 모르는 stream_id는 invalid_request.
    fn dispatchDetach(self: *Connection, request_id: u64, params: ?std.json.ObjectMap) HandleError!Action {
        const p = params orelse return self.replyError(request_id, .invalid_request);
        const stream = intFieldU64(p, "stream_id") orelse return self.replyError(request_id, .invalid_request);
        const runtime_id = self.attachments.get(stream) orelse return self.replyError(request_id, .invalid_request);
        _ = self.registry.detach(runtime_id, stream) catch {};
        _ = self.attachments.remove(stream);
        const body = try self.stringify(.{ .result = .{ .detached = true } });
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
        const runtime_id = self.attachments.get(stream) orelse return self.replyError(request_id, .invalid_request);

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
        const runtime_id = self.attachments.get(stream) orelse return .none;
        if (!reg.Capability.has(self.registry.capabilitiesOf(runtime_id, stream), reg.Capability.input)) return .none;
        const ops = self.runtime_ops orelse return .none;
        ops.write_input(ops.ctx, runtime_id, frame.payload) catch {};
        return .none;
    }

    // ── JSON 응답 빌더 ──────────────────────────────────────────────────────

    fn helloAckJson(self: *Connection) HandleError![]u8 {
        const host_hex = try self.hostHex();
        defer self.allocator.free(host_hex);
        return self.stringify(.{
            .version = self.selected_version,
            .host_id = host_hex,
            .capabilities = [_][]const u8{ "host.info", "runtime.list", "runtime.get" },
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

    fn encode(self: *Connection, kind: protocol.Kind, request_id: u64, stream_id: u64, payload: []const u8) FrameError![]u8 {
        return framing.encodeFrame(self.allocator, .{ .kind = kind, .request_id = request_id, .stream_id = stream_id }, payload) catch |e| switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.PayloadTooLarge => error.PayloadTooLarge,
            // encodeFrame은 직렬화만 하므로 decode 계열(magic·unknown kind) error를 낼 수 없다.
            error.BadMagic, error.UnknownRequiredFrame => unreachable,
        };
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
    }
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
    const r = try feedJson(&conn, .hello, 7, "{\"protocol_min\":1,\"protocol_max\":1,\"client_kind\":\"gui\"}");
    defer if (r.frame) |f| f.deinit(testing.allocator);
    try testing.expectEqualStrings("reply", r.action);
    try testing.expectEqual(protocol.Kind.hello_ack, r.frame.?.header.kind);
    try testing.expectEqual(@as(u64, 7), r.frame.?.header.request_id);
    try testing.expectEqual(Connection.State.ready, conn.state);
    try testing.expectEqual(ClientKind.gui, conn.client_kind);
    // host_id hex가 응답에 담긴다.
    try testing.expect(std.mem.indexOf(u8, r.frame.?.payload, "1234567890abcdef") != null);
}

test "server: hello with no overlapping version returns incompatible_version and closes" {
    var registry = reg.TerminalRuntimeRegistry.init(testing.allocator);
    defer registry.deinit();
    var conn = Connection.init(testing.allocator, 1, &registry);
    const r = try feedJson(&conn, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":3,\"client_kind\":\"cli\"}");
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
        const r = try feedJson(&conn, .hello, 1, "{\"protocol_min\":1,\"protocol_max\":1}");
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
        const h = try feedJson(&conn, .hello, 1, "{\"protocol_min\":1,\"protocol_max\":1}");
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
        const h = try feedJson(&conn, .hello, 1, "{\"protocol_min\":1,\"protocol_max\":1}");
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
        const h = try feedJson(&conn, .hello, 1, "{\"protocol_min\":1,\"protocol_max\":1}");
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
    spawn_argv0: [64]u8 = undefined,
    spawn_argv0_len: usize = 0,
    spawn_cols: u16 = 0,
    terminated_id: u128 = 0,
    next_id: u128 = 0xCAFE,
    last_input: [64]u8 = undefined,
    last_input_len: usize = 0,
    input_runtime: u128 = 0,
    resized_cols: u16 = 0,
    resized_rows: u16 = 0,
    resized_runtime: u128 = 0,

    fn spawnFn(ctx: *anyopaque, params: RuntimeSpawnParams) anyerror!u128 {
        const self: *FakeRuntimeOps = @ptrCast(@alignCast(ctx));
        const a0 = params.argv[0];
        const n = @min(a0.len, self.spawn_argv0.len);
        @memcpy(self.spawn_argv0[0..n], a0[0..n]);
        self.spawn_argv0_len = n;
        self.spawn_cols = params.cols;
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
    fn ops(self: *FakeRuntimeOps) RuntimeOps {
        return .{ .ctx = self, .spawn = spawnFn, .terminate = terminateFn, .write_input = writeInputFn, .resize = resizeFn };
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
        const h = try feedJson(&conn, .hello, 1, "{\"protocol_min\":1,\"protocol_max\":1}");
        if (h.frame) |f| f.deinit(allocator);
    }
    {
        const r = try feedJson(&conn, .request, 2, "{\"method\":\"runtime.spawn\",\"params\":{\"argv\":[\"/bin/sh\",\"-c\",\"cat\"],\"cols\":100,\"rows\":40}}");
        defer if (r.frame) |f| f.deinit(allocator);
        try testing.expect(std.mem.indexOf(u8, r.frame.?.payload, "cafe") != null); // runtime_id hex(0xCAFE)
    }
    try testing.expectEqualStrings("/bin/sh", fake.spawn_argv0[0..fake.spawn_argv0_len]);
    try testing.expectEqual(@as(u16, 100), fake.spawn_cols);
    {
        const r = try feedJson(&conn, .request, 3, "{\"method\":\"runtime.terminate\",\"params\":{\"runtime_id\":\"cafe\"}}");
        defer if (r.frame) |f| f.deinit(allocator);
        try testing.expect(std.mem.indexOf(u8, r.frame.?.payload, "terminated") != null);
    }
    try testing.expectEqual(@as(u128, 0xCAFE), fake.terminated_id);

    // read-only host(runtime_ops=null): spawn은 unauthorized다(§10, §11 — attach 역할에 spawn을 암묵 부여하지 않는다).
    var conn2 = Connection.init(allocator, 1, &registry);
    {
        const h = try feedJson(&conn2, .hello, 1, "{\"protocol_min\":1,\"protocol_max\":1}");
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

    var fake: FakeRuntimeOps = .{};
    var conn = Connection.init(allocator, 1, &registry);
    defer conn.deinit(); // attach subscription을 registry에서 뗀다(deinit는 registry.deinit보다 먼저 — defer LIFO).
    conn.runtime_ops = fake.ops();
    {
        const h = try feedJson(&conn, .hello, 1, "{\"protocol_min\":1,\"protocol_max\":1}");
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
        const h = try feedJson(&conn, .hello, 1, "{\"protocol_min\":1,\"protocol_max\":1}");
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
    // observer resize는 unauthorized(controller 아님).
    {
        const r = try feedJson(&conn, .request, 3, "{\"method\":\"runtime.resize\",\"params\":{\"stream_id\":1,\"cols\":90,\"rows\":30,\"client_sequence\":1}}");
        defer if (r.frame) |f| f.deinit(allocator);
        try testing.expect(std.mem.indexOf(u8, r.frame.?.payload, "unauthorized") != null);
    }
    try testing.expectEqual(@as(u16, 0), fake.resized_cols);
}
