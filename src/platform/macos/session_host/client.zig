//! session-host **client** — GUI/CLI가 host에 connect해 hello를 협상하고 command를 왕복한다(§7 재접속, §10) — P3-e1.
//!
//! `server.zig`의 `Connection` dispatch를 client 쪽에서 마주 본다: unix socket에 connect한 뒤 첫 frame으로 hello를
//! 보내 protocol/`host_id`를 확정하고, `request` frame으로 command를 보내 `response`를 받는다. frame codec은 P3-a
//! (`protocol`/`framing`)를, host 진입점은 P3-d2c(`daemon`)를 재사용한다. macOS 전용(실 socket) — barrel 조건부.
//!
//! GUI 재접속(§7)은 이 client로 host에 붙어 manifest handle의 `host_id`와 hello의 값을 대조하고(stale 판정), runtime을
//! 조회/attach한다. 이 파일은 그 hello + read-only command 왕복(host.info/runtime.list/get)까지다 — runtime attach
//! subscription과 stream demux, host-backed `TermRuntimeBackend`(P2 계약의 원격 구현)는 P3-e2 이후에 얹는다.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;
const protocol = @import("protocol.zig");
const framing = @import("framing.zig");
const socket_server = @import("socket_server.zig");
const screen_stream = @import("screen_stream.zig");
const observation_wire = @import("observation_wire.zig");

pub const ClientError = error{
    ConnectFailed,
    /// hello 왕복이 실패했다(전송/수신/파싱). 또는 host_id를 못 읽었다.
    HandshakeFailed,
    /// host가 겹치는 major version이 없다고 응답했다(§10). runtime을 죽이지 않고 client만 끝낸다.
    IncompatibleVersion,
    /// frame codec 위반 또는 예상치 못한 frame kind.
    ProtocolError,
    WriteFailed,
    /// EOF/read 오류로 응답을 못 받았다(host 종료·crash).
    ConnectionClosed,
    /// async event queue의 count/byte cap을 넘었다. latest full-state를 조용히 버리면 host base가 이미 전진해 영구 stale이
    /// 되므로 connection/runtime을 fail-closed하고 재attach initial metadata로 복구한다.
    EventQueueFull,
    OutOfMemory,
};

/// `readStreamBatch`가 돌려주는 한 화면 stream 배치. `is_snapshot`이면 fresh full snapshot(화면 리셋), 아니면 delta 증분이다
/// (§9 — host가 grid/alt 변화 시 delta 대신 snapshot을 push하므로 소비자는 둘 다 받는다). `bytes`는 `end_stream`까지 이은
/// record 바이트(caller 소유), `stream_id`는 어느 runtime의 화면인지다(멀티 runtime 라우팅).
pub const StreamBatch = struct {
    is_snapshot: bool,
    stream_id: u64,
    bytes: []u8,
};

/// host와의 한 connection. `host_id`는 hello_ack로 받은 값이다(§4 stale handle 판정에 쓴다). `call`은 read-only
/// command를 왕복한다.
pub const Client = struct {
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    host_id: u128,
    parser: framing.FrameParser,
    // async full-state를 하나라도 수용하지 못하면 server subscription base는 이미 전진했을 수 있다. 그 뒤 같은 socket을
    // 계속 쓰면 어떤 shared stream이 누락됐는지 복구할 수 없으므로 connection 전체를 poison/close한다.
    unusable: bool = false,
    next_request_id: u64 = 1,
    // 응답을 기다리는 `call` 중에 host가 비동기로 push한 stream frame(delta_chunk/snapshot_chunk)을 여기 버퍼한다 — 드롭하면
    // 화면 갱신이 유실되므로(§9 delta는 증분이라 하나만 놓쳐도 desync), 다음 `readStreamBatch`가 소켓보다 먼저 이걸 비운다.
    pending_stream: std.ArrayListUnmanaged(framing.Frame) = .empty,
    // screen batch와 별개인 full-state runtime metadata event. response/snapshot을 기다리는 중에도 올 수 있으므로 버리지
    // 않고 stream별 최신 한 건으로 coalesce한다. full-state라 중간 revision을 건너뛰어도 최신 event만 적용하면 된다.
    pending_events: std.ArrayListUnmanaged(framing.Frame) = .empty,
    pending_event_bytes: usize = 0,
    // 멀티 runtime demux(§9): 여러 원격 runtime이 이 connection **하나**를 공유하므로, `readStreamBatch(want)`가 소켓에서 읽은
    // 완성 배치가 **다른** stream의 것이면 버리지 않고 여기 도착 순서대로 쌓아, 그 stream의 runtime pump가 나중에 소비한다(예전엔
    // pumpDelta가 남의 배치를 free해 두 번째 이후 터미널 화면이 영구 유실됐다 — code-review #1). host는 배치를 stream별로 연속
    // write하므로(프레임 인터리브 없음) 각 원소는 완결된 한 배치다. 모든 원격 runtime이 **단일 app-전역 backend**를 공유해 한
    // allocator로 이 배치들을 만들고/소비/해제하므로(불변식) 버퍼-소비 간 allocator가 일치한다. deinit이 잔여를 회수한다.
    pending_batches: std.ArrayListUnmanaged(StreamBatch) = .empty,

    /// host socket에 connect하고 hello를 왕복한다. 성공하면 `host_id`가 채워진 Client다. host가 없으면 ConnectFailed
    /// (discovery가 이 신호로 spawn/host_unavailable을 가른다, P3-d2b). version 불일치는 IncompatibleVersion.
    pub fn connect(allocator: std.mem.Allocator, socket_path: [:0]const u8, client_kind: []const u8) ClientError!Client {
        // over-long path는 sun_path(104B)를 넘겨 slice-bounds panic이 되므로 syscall 전에 거부한다(bind의 socketPathFits 대칭).
        if (!socket_server.socketPathFits(socket_path.len)) return error.ConnectFailed;
        const fd = c.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        if (fd < 0) return error.ConnectFailed;
        errdefer _ = c.close(fd);
        // host가 죽은 socket에 write하면 SIGPIPE로 **프로세스가 죽는다** — EPIPE로 바꿔 catchable하게 한다(server accept 경로와 대칭).
        socket_server.setNoSigPipe(fd);
        // host가 연결만 받고(backlog) 응답하지 않으면 read가 영원히 막힌다 — recv timeout으로 ConnectionClosed로 빠져나온다.
        setReadTimeoutMs(fd, 5000);
        var addr = posix.sockaddr.un{ .family = posix.AF.UNIX, .path = undefined };
        @memset(&addr.path, 0);
        @memcpy(addr.path[0..socket_path.len], socket_path);
        if (c.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) != 0) return error.ConnectFailed;

        var self = Client{ .allocator = allocator, .fd = fd, .host_id = 0, .parser = framing.FrameParser.init(allocator) };
        errdefer self.parser.deinit();

        // hello 전송.
        const hello = buildHello(allocator, client_kind) catch return error.OutOfMemory;
        defer allocator.free(hello);
        const hello_frame = framing.encodeFrame(allocator, .{ .kind = .hello, .request_id = 0 }, hello) catch return error.OutOfMemory;
        defer allocator.free(hello_frame);
        socket_server.writeAll(fd, hello_frame) catch return error.WriteFailed;

        // hello_ack 수신.
        const ack = try self.readFrame();
        defer ack.deinit(allocator);
        if (ack.header.kind != .hello_ack) return error.HandshakeFailed;
        if (std.mem.indexOf(u8, ack.payload, "incompatible_version") != null) return error.IncompatibleVersion;
        self.host_id = parseHostId(ack.payload) orelse return error.HandshakeFailed;
        return self;
    }

    pub fn deinit(self: *Client) void {
        if (self.fd >= 0) _ = c.close(self.fd);
        for (self.pending_stream.items) |f| f.deinit(self.allocator); // 미소비 버퍼 stream frame 회수.
        self.pending_stream.deinit(self.allocator);
        for (self.pending_events.items) |f| f.deinit(self.allocator);
        self.pending_events.deinit(self.allocator);
        for (self.pending_batches.items) |b| self.allocator.free(b.bytes); // 미소비 demux 배치 회수(§9 멀티 runtime).
        self.pending_batches.deinit(self.allocator);
        self.parser.deinit();
        self.* = undefined;
    }

    /// read-only command를 왕복한다. `params_json`은 JSON object 문자열(예: `{"runtime_id":"aa"}`) 또는 null. 반환
    /// payload는 host의 response JSON(owned — caller가 free). typed error 판정은 caller가 payload에서 한다(§10 error 매핑).
    pub fn call(self: *Client, method: []const u8, params_json: ?[]const u8) ClientError![]u8 {
        try self.ensureUsable();
        const req = buildRequest(self.allocator, method, params_json) catch return error.OutOfMemory;
        defer self.allocator.free(req);
        const request_id = self.next_request_id;
        self.next_request_id += 1;
        const frame_bytes = framing.encodeFrame(self.allocator, .{ .kind = .request, .request_id = request_id }, req) catch return error.OutOfMemory;
        defer self.allocator.free(frame_bytes);
        socket_server.writeAll(self.fd, frame_bytes) catch return error.WriteFailed;

        // 응답을 기다리는 동안 host가 비동기로 push하는 stream frame(delta_chunk/snapshot_chunk)은 **버퍼에 쌓는다** — 드롭하면
        // 그 사이 화면 갱신이 유실된다(§9 delta는 증분이라 한 배치만 놓쳐도 desync). 다음 `readStreamBatch`가 이 버퍼부터 소비한다.
        while (true) {
            const resp = try self.readFrame();
            if (resp.header.kind == .delta_chunk or resp.header.kind == .snapshot_chunk) {
                self.pending_stream.append(self.allocator, resp) catch {
                    resp.deinit(self.allocator);
                    return error.OutOfMemory;
                };
                continue;
            }
            if (resp.header.kind == .event) {
                try self.bufferEvent(resp);
                continue;
            }
            defer resp.deinit(self.allocator);
            // kind와 request_id를 함께 확인한다 — out-of-order frame을 이 call의 응답으로 오귀속하지 않는다.
            if (resp.header.kind != .response or resp.header.request_id != request_id) return error.ProtocolError;
            return self.allocator.dupe(u8, resp.payload) catch return error.OutOfMemory;
        }
    }

    /// attach 직후 host가 보내는 `snapshot_chunk` stream을 `end_stream`까지 읽어 record 바이트를 이어 돌려준다(§10 attach
    /// 순서: response → snapshot_chunk*). 반환 바이트는 caller 소유(screen_stream.RecordStream으로 순회). **attach 응답을
    /// 받은 뒤 다음 request 전에 반드시 이걸로 stream을 비운다** — 안 그러면 leftover chunk가 다음 응답으로 오독된다.
    pub fn readSnapshot(self: *Client, stream_id: u64) ClientError![]u8 {
        try self.ensureUsable();
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(self.allocator);
        while (true) {
            const frame = try self.readFrame();
            if (frame.header.kind == .event) {
                try self.bufferEvent(frame);
                continue;
            }
            defer frame.deinit(self.allocator);
            if (frame.header.kind != .snapshot_chunk or frame.header.stream_id != stream_id) return error.ProtocolError;
            out.appendSlice(self.allocator, frame.payload) catch return error.OutOfMemory;
            if (protocol.Flags.hasEndStream(frame.header.flags)) break;
        }
        return out.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
    }

    /// `want_stream_id`의 다음 **화면 stream 배치**를 논블로킹으로 돌려준다(caller가 `bytes` free). 여러 원격 runtime이 이
    /// connection 하나를 공유하므로 소켓엔 여러 stream의 배치가 섞여 온다 — 이 함수가 **stream_id로 demux**한다: 버퍼(§멀티
    /// runtime `pending_batches`)에 내 배치가 있으면 그걸 먼저(도착 순서), 없으면 소켓에서 완성 배치를 읽되 **다른 stream의
    /// 것이면 버리지 않고 버퍼에 넣고 계속** 읽어 내 배치를 찾는다. 소켓이 idle이면(내 배치 없음) `null`(그 사이 읽힌 남의 배치는
    /// 버퍼에 남아 그 runtime의 pump가 소비). 예전엔 pumpDelta가 남의 배치를 free해 두 번째 이후 터미널 화면이 영구 유실됐다
    /// (code-review #1). delta/snapshot 둘 다 받아 `is_snapshot`으로 리셋/증분을 가른다. `call`이 버퍼한 frame을 소켓보다 먼저 쓴다.
    pub fn readStreamBatch(self: *Client, allocator: std.mem.Allocator, want_stream_id: u64) ClientError!?StreamBatch {
        try self.ensureUsable();
        // 1) 이 stream 앞으로 이미 버퍼된 배치(다른 runtime의 pump가 소켓을 비우며 넣어 둔 것)를 도착 순서대로 먼저 준다.
        for (self.pending_batches.items, 0..) |b, i| {
            if (b.stream_id == want_stream_id) return self.pending_batches.orderedRemove(i);
        }
        // 2) 소켓에서 완성 배치를 읽는다. 내 것이면 반환, 남의 것이면 버퍼하고 계속(내 것/idle까지).
        while (true) {
            const batch = (try self.readOneBatch(allocator)) orelse return null; // idle — 내 배치 없음.
            if (batch.stream_id == want_stream_id) return batch;
            // 남의 stream 배치 — 그 runtime pump가 소비하도록 버퍼. append 실패 시 이 배치 bytes를 회수(누수 방지).
            self.pending_batches.append(self.allocator, batch) catch {
                allocator.free(batch.bytes);
                return error.OutOfMemory;
            };
        }
    }

    /// 소켓/`pending_stream`에서 완성 stream 배치 하나를 `end_stream`까지 읽어 돌려준다(stream_id 무관). **논블로킹**: 배치가
    /// 아직 없으면 `null`(recv timeout을 세션 종료로 오인 안 함, §9). host는 grid/alt 변화 시 delta 대신 fresh snapshot을 push한다
    /// (SnapshotRequired). demux는 상위 `readStreamBatch`가 한다 — 여기선 순수하게 "다음 배치 하나".
    fn readOneBatch(self: *Client, allocator: std.mem.Allocator) ClientError!?StreamBatch {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);
        var stream_id: u64 = 0;
        var is_snapshot = false;
        var started = false;
        while (true) {
            const frame = (try self.nextStreamFrame(started)) orelse {
                // 배치 시작 전이면 그냥 "아직 없음". 시작 후 데이터가 끊기면(rare) 미완성 배치는 버린다 — host가 다음 tick에
                // 새 delta/snapshot으로 다시 잇는다(부분 배치를 반영하는 것보다 안전).
                out.deinit(allocator);
                return null;
            };
            if (frame.header.kind == .event) {
                // host는 한 screen chunk batch 안에 event를 interleave하지 않지만 방어적으로 started 여부와 무관하게
                // full-state event를 보존하고 다음 async frame을 계속 찾는다.
                try self.bufferEvent(frame);
                continue;
            }
            defer frame.deinit(self.allocator);
            if (frame.header.kind != .snapshot_chunk and frame.header.kind != .delta_chunk) return error.ProtocolError;
            if (!started) {
                stream_id = frame.header.stream_id;
                is_snapshot = frame.header.kind == .snapshot_chunk;
                started = true;
            }
            out.appendSlice(allocator, frame.payload) catch return error.OutOfMemory;
            if (protocol.Flags.hasEndStream(frame.header.flags)) {
                return .{ .is_snapshot = is_snapshot, .stream_id = stream_id, .bytes = out.toOwnedSlice(allocator) catch return error.OutOfMemory };
            }
        }
    }

    /// `stream_id` 앞으로 버퍼된 demux 배치를 모두 버린다(runtime이 detach/remove될 때 그 runtime의 pump가 다신 안 도므로
    /// 잔여 배치가 영구히 쌓이지 않게 — RemoteRuntime.deinit/detachClientSide가 부른다). 없으면 no-op.
    pub fn dropBufferedStream(self: *Client, stream_id: u64) void {
        var i: usize = 0;
        while (i < self.pending_batches.items.len) {
            if (self.pending_batches.items[i].stream_id == stream_id) {
                const b = self.pending_batches.orderedRemove(i);
                self.allocator.free(b.bytes);
            } else i += 1;
        }
        i = 0;
        while (i < self.pending_events.items.len) {
            if (self.pending_events.items[i].header.stream_id == stream_id) {
                const frame = self.pending_events.orderedRemove(i);
                self.pending_event_bytes -= frame.payload.len;
                frame.deinit(self.allocator);
            } else i += 1;
        }
    }

    /// stream의 최신 full-state metadata event를 소유권째 꺼낸다. 없으면 null. caller는 payload 적용 뒤 frame.deinit.
    pub fn takeEventForStream(self: *Client, stream_id: u64) ?framing.Frame {
        // poison 전에 쌓인 event도 어느 stream의 누락보다 최신인지 증명할 수 없다. 일부 runtime만 한 번 더 전진시키지 않고
        // 모든 shared runtime이 다음 pump에서 같은 ConnectionClosed를 보게 한다.
        if (self.unusable) return null;
        for (self.pending_events.items, 0..) |frame, i| {
            if (frame.header.stream_id == stream_id) {
                const owned = self.pending_events.orderedRemove(i);
                self.pending_event_bytes -= owned.payload.len;
                return owned;
            }
        }
        return null;
    }

    /// event는 runtime별 full-state라 같은 stream의 이전 pending을 최신으로 교체한다. 악성/버그 host가 임의 stream id를
    /// 쏟아 count/byte cap을 넘기면 oldest를 버리지 않고 shared connection 전체를 poison해 모든 runtime을 fail-closed한다.
    fn bufferEvent(self: *Client, frame: framing.Frame) ClientError!void {
        const metadata_revision = observation_wire.eventRevision(self.allocator, frame.payload) catch {
            frame.deinit(self.allocator);
            return error.OutOfMemory;
        };
        if (std.mem.indexOf(u8, frame.payload, "\"event\":\"runtime.metadata\"") != null and metadata_revision == null) {
            // 손상된 full-state가 정상 최신 event를 coalesce로 밀어내면 host는 이미 base를 전진시켜 영구 누락될 수 있다.
            // 큐에 넣기 전에 최소 wire schema를 검증해 손상 event는 기존 cache를 건드리지 않고 버린다.
            frame.deinit(self.allocator);
            return;
        }
        for (self.pending_events.items, 0..) |old, i| {
            const old_revision = observation_wire.eventRevision(self.allocator, old.payload) catch {
                frame.deinit(self.allocator);
                return error.OutOfMemory;
            };
            if (metadata_revision != null and old_revision != null and old.header.stream_id == frame.header.stream_id) {
                if (metadata_revision.? <= old_revision.?) {
                    frame.deinit(self.allocator);
                    return;
                }
                const replaced = self.pending_events.items[i];
                const next_bytes = self.pending_event_bytes - replaced.payload.len +| frame.payload.len;
                if (next_bytes > protocol.max_client_queue) {
                    frame.deinit(self.allocator);
                    self.invalidateConnection();
                    return error.EventQueueFull;
                }
                self.pending_events.items[i] = frame;
                self.pending_event_bytes = next_bytes;
                replaced.deinit(self.allocator);
                return;
            }
        }
        if (self.pending_events.items.len >= 256 or
            self.pending_event_bytes +| frame.payload.len > protocol.max_client_queue)
        {
            // Eviction 금지: server는 event를 만들 때 이미 subscription base/revision을 전진시켰다. 해당 stream의 최신
            // full-state를 조용히 버리면 같은 상태를 다시 보내지 않는다. 어느 shared stream이 누락됐든 connection 전체를
            // 닫아 모든 runtime이 fail-closed하고, 다음 attach의 initial metadata에서만 복구한다.
            frame.deinit(self.allocator);
            self.invalidateConnection();
            return error.EventQueueFull;
        }
        self.pending_events.append(self.allocator, frame) catch {
            frame.deinit(self.allocator);
            return error.OutOfMemory;
        };
        self.pending_event_bytes += frame.payload.len;
    }

    /// stream 배치를 잇는 다음 stream frame을 준다. 우선순위: `call`이 버퍼한 frame → parser에 남은 완성 frame → 소켓 read.
    /// `started`=false(배치 첫 frame)면 소켓을 `pollReadable`로 논블로킹 확인해 데이터가 없으면 `null`(idle). `started`=true면
    /// 배치의 나머지 frame이 곧 오므로(host가 한 번에 write) blocking read를 허용하되, EOF만 ConnectionClosed로 올린다.
    fn nextStreamFrame(self: *Client, started: bool) ClientError!?framing.Frame {
        try self.ensureUsable();
        if (self.pending_stream.items.len > 0)
            return try self.requireCurrentMajor(self.pending_stream.orderedRemove(0));
        var buf: [4096]u8 = undefined;
        while (true) {
            if (self.parser.next() catch return error.ProtocolError) |frame|
                return try self.requireCurrentMajor(frame);
            if (!started and !pollReadable(self.fd)) return null; // 배치 시작 전 + 데이터 없음 → idle.
            const n = c.read(self.fd, &buf, buf.len);
            if (n < 0) {
                if (posix.errno(n) == .INTR) continue; // 시그널 인터럽트는 재시도.
                return null; // EAGAIN/timeout → 더 없음(idle). 세션을 죽이지 않는다.
            }
            if (n == 0) return error.ConnectionClosed; // EOF — host 종료.
            self.parser.push(buf[0..@intCast(n)]) catch return error.OutOfMemory;
        }
    }

    /// terminal input bytes를 attach된 `stream_id`로 보낸다(§9 `input_bytes` — 응답 없는 fire-and-forget). controller만
    /// 유효하고, host는 비controller/미attach stream의 input을 조용히 버린다. attach 응답의 stream_id를 그대로 쓴다.
    pub fn sendInput(self: *Client, stream_id: u64, bytes: []const u8) ClientError!void {
        try self.ensureUsable();
        // input frame의 wire cap은 1 MiB다. paste가 이를 넘는 것은 정상 입력이므로 encode 실패/드롭하지 않고 순서대로
        // 여러 frame으로 나눈다. 빈 입력은 전송할 것이 없다.
        var offset: usize = 0;
        while (offset < bytes.len) {
            const end = inputChunkEnd(offset, bytes.len);
            const frame_bytes = framing.encodeFrame(self.allocator, .{ .kind = .input_bytes, .stream_id = stream_id }, bytes[offset..end]) catch
                return error.OutOfMemory;
            socket_server.writeAll(self.fd, frame_bytes) catch {
                self.allocator.free(frame_bytes);
                return error.WriteFailed;
            };
            self.allocator.free(frame_bytes);
            offset = end;
        }
    }

    /// 다음 완성 frame을 읽는다(partial read 재조립). EOF/timeout는 ConnectionClosed, codec 위반은 ProtocolError.
    fn readFrame(self: *Client) ClientError!framing.Frame {
        try self.ensureUsable();
        var buf: [4096]u8 = undefined;
        while (true) {
            if (self.parser.next() catch return error.ProtocolError) |frame|
                return try self.requireCurrentMajor(frame);
            const n = c.read(self.fd, &buf, buf.len);
            if (n < 0) {
                if (posix.errno(n) == .INTR) continue; // 시그널 인터럽트는 재시도(timeout/EAGAIN·기타 오류는 종료로).
                return error.ConnectionClosed;
            }
            if (n == 0) return error.ConnectionClosed; // EOF.
            self.parser.push(buf[0..@intCast(n)]) catch return error.OutOfMemory;
        }
    }

    /// parser·call 중 임시 stream queue 어느 경로에서 꺼낸 frame이든 같은 major gate를 거친다. 잘못된 major의
    /// payload는 caller에게 넘기지 않고 여기서 회수한다.
    fn requireCurrentMajor(self: *Client, frame: framing.Frame) ClientError!framing.Frame {
        if (frame.header.major != protocol.version_major) {
            frame.deinit(self.allocator);
            return error.ProtocolError;
        }
        return frame;
    }

    fn ensureUsable(self: *const Client) ClientError!void {
        if (self.unusable) return error.ConnectionClosed;
    }

    fn invalidateConnection(self: *Client) void {
        if (self.unusable) return;
        self.unusable = true;
        if (self.fd >= 0) {
            _ = c.close(self.fd);
            self.fd = -1;
        }
    }
};

fn inputChunkEnd(offset: usize, total: usize) usize {
    std.debug.assert(offset <= total);
    return @min(offset +| protocol.max_binary_chunk, total);
}

test "client input chunking preserves exact-cap and cap-plus-one paste bytes" {
    try std.testing.expectEqual(protocol.max_binary_chunk, inputChunkEnd(0, protocol.max_binary_chunk));
    try std.testing.expectEqual(protocol.max_binary_chunk, inputChunkEnd(0, protocol.max_binary_chunk + 1));
    try std.testing.expectEqual(protocol.max_binary_chunk + 1, inputChunkEnd(protocol.max_binary_chunk, protocol.max_binary_chunk + 1));
    try std.testing.expectEqual(@as(usize, 0), inputChunkEnd(0, 0));
}

test "client stream path rejects a frame with the wrong MRSH header major" {
    const allocator = std.testing.allocator;
    var client = Client{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0,
        .parser = framing.FrameParser.init(allocator),
    };
    defer client.parser.deinit();
    defer client.pending_stream.deinit(allocator);
    defer client.pending_events.deinit(allocator);
    defer client.pending_batches.deinit(allocator);

    const wire = try framing.encodeFrame(allocator, .{
        .kind = .delta_chunk,
        .major = protocol.version_major - 1,
        .stream_id = 7,
    }, "delta");
    defer allocator.free(wire);
    try client.parser.push(wire);
    try std.testing.expectError(error.ProtocolError, client.nextStreamFrame(true));
}

test "client metadata events coalesce by stream and preserve other streams" {
    const allocator = std.testing.allocator;
    var client = Client{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0,
        .parser = framing.FrameParser.init(allocator),
    };
    defer client.parser.deinit();
    defer client.pending_stream.deinit(allocator);
    defer {
        for (client.pending_events.items) |frame| frame.deinit(allocator);
        client.pending_events.deinit(allocator);
    }
    defer client.pending_batches.deinit(allocator);

    const rev1 =
        \\{"event":"runtime.metadata","metadata_revision":1,"metadata":{"cwd":"/one","window_title":"one","ssh_remote_dest":null,
        \\"semantic_state":0,"alt_active":false,"app_cursor_keys":false,"alternate_scroll":true,"observer_generation":1,
        \\"title_generation":1,"cols":80,"rows":24,"foreground_available":false,"foreground_pgid":null,"processes":[]}}
    ;
    const rev2 =
        \\{"event":"runtime.metadata","metadata_revision":2,"metadata":{"cwd":"/two","window_title":"two","ssh_remote_dest":null,
        \\"semantic_state":0,"alt_active":false,"app_cursor_keys":false,"alternate_scroll":true,"observer_generation":2,
        \\"title_generation":2,"cols":80,"rows":24,"foreground_available":false,"foreground_pgid":null,"processes":[]}}
    ;
    try client.bufferEvent(.{ .header = .{ .kind = .event, .stream_id = 7 }, .payload = try allocator.dupe(u8, rev1) });
    try client.bufferEvent(.{ .header = .{ .kind = .event, .stream_id = 8 }, .payload = try allocator.dupe(u8, "other") });
    try client.bufferEvent(.{ .header = .{ .kind = .event, .stream_id = 7 }, .payload = try allocator.dupe(u8, rev2) });
    // stale 또는 consumer가 거부할 bounds 위반 newer event가 정상 pending full-state를 밀어내면 안 된다.
    try client.bufferEvent(.{ .header = .{ .kind = .event, .stream_id = 7 }, .payload = try allocator.dupe(u8, rev1) });
    const malformed_newer =
        \\{"event":"runtime.metadata","metadata_revision":3,"metadata":{"cwd":"/bad","window_title":"bad","ssh_remote_dest":null,
        \\"semantic_state":0,"alt_active":false,"app_cursor_keys":false,"alternate_scroll":true,"observer_generation":3,
        \\"title_generation":3,"cols":-1,"rows":24,"foreground_available":false,"foreground_pgid":null,"processes":[]}}
    ;
    try client.bufferEvent(.{ .header = .{ .kind = .event, .stream_id = 7 }, .payload = try allocator.dupe(u8, malformed_newer) });
    try std.testing.expectEqual(@as(usize, 2), client.pending_events.items.len);
    try std.testing.expect(client.pending_event_bytes > 0);

    const latest = client.takeEventForStream(7) orelse return error.TestUnexpectedResult;
    defer latest.deinit(allocator);
    try std.testing.expectEqualStrings(rev2, latest.payload);
    const other = client.takeEventForStream(8) orelse return error.TestUnexpectedResult;
    defer other.deinit(allocator);
    try std.testing.expectEqualStrings("other", other.payload);
    try std.testing.expectEqual(@as(usize, 0), client.pending_event_bytes);
}

test "client event queue overflow poisons every runtime sharing the connection" {
    const allocator = std.testing.allocator;
    var client = Client{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0,
        .parser = framing.FrameParser.init(allocator),
    };
    defer client.parser.deinit();
    defer client.pending_stream.deinit(allocator);
    defer {
        for (client.pending_events.items) |frame| frame.deinit(allocator);
        client.pending_events.deinit(allocator);
    }
    defer client.pending_batches.deinit(allocator);

    for (0..256) |i| {
        try client.bufferEvent(.{
            .header = .{ .kind = .event, .stream_id = @intCast(i + 1) },
            .payload = try allocator.dupe(u8, "{\"event\":\"other\"}"),
        });
    }
    const first_payload = client.pending_events.items[0].payload;
    try std.testing.expectError(error.EventQueueFull, client.bufferEvent(.{
        .header = .{ .kind = .event, .stream_id = 999 },
        .payload = try allocator.dupe(u8, "{\"event\":\"overflow\"}"),
    }));
    try std.testing.expectEqual(@as(usize, 256), client.pending_events.items.len);
    try std.testing.expectEqualStrings("{\"event\":\"other\"}", first_payload);
    // Overflow frame은 stream 999였지만 어느 subscription base가 전진했는지 client가 증명할 수 없다. 기존 stream 1의
    // pending event도 적용하지 않고, stream 1/2 양쪽 pump와 input/RPC가 모두 동일 connection failure를 보게 한다.
    try std.testing.expect(client.takeEventForStream(1) == null);
    try std.testing.expectError(error.ConnectionClosed, client.readStreamBatch(allocator, 1));
    try std.testing.expectError(error.ConnectionClosed, client.readStreamBatch(allocator, 2));
    try std.testing.expectError(error.ConnectionClosed, client.sendInput(1, "x"));
    try std.testing.expectError(error.ConnectionClosed, client.call("host.info", null));
}

/// 소켓에 읽을 데이터가 즉시 있는지 논블로킹 확인한다(timeout 0). `readStreamBatch`가 배치 첫 frame에서 idle이면 곧장
/// 빠져나오게 한다(blocking read로 recv timeout까지 매달리지 않음 — socket_server serveConnection의 poll gate와 대칭).
fn pollReadable(fd: c.fd_t) bool {
    var fds = [_]c.pollfd{.{ .fd = fd, .events = c.POLL.IN, .revents = 0 }};
    const rc = c.poll(&fds, 1, 0);
    if (rc <= 0) return false; // EINTR/timeout/오류 → 없음으로 취급(다음 tick에 재확인).
    return fds[0].revents & c.POLL.IN != 0;
}

/// recv timeout(ms)을 건다 — host가 연결만 받고 응답하지 않을 때 `readFrame`이 영원히 막히지 않게 한다(control_socket 관용구).
fn setReadTimeoutMs(fd: c.fd_t, ms: u32) void {
    var tv = posix.timeval{ .sec = @intCast(ms / 1000), .usec = @intCast((ms % 1000) * 1000) };
    _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.RCVTIMEO, &tv, @sizeOf(posix.timeval));
}

// ── 순수 JSON helper(client wire) ────────────────────────────────────────────
//
// 신뢰 계약: `client_kind`·`method`는 **코드 내부 고정 리터럴**만 받는다(client_kind∈{"gui","cli"}, method는 정의된
// 명령 이름 집합). 그래서 JSON escape 없이 그대로 interpolate한다 — 이 값들엔 `"`·`\`·제어문자가 없다. `params_json`은
// 이미 유효한 JSON object 문자열이라는 계약이라 raw로 싣는다(호출자가 조립 시 escape 책임). runtime.spawn(P3-e2b)처럼
// **임의 바이트(argv/cwd)**를 실어야 하는 params는 반드시 실 JSON encoder(server.zig `stringify` 대칭)로 만들어 넘긴다
// — 여기서 hand-interpolation하지 않는다.

fn buildHello(allocator: std.mem.Allocator, client_kind: []const u8) error{OutOfMemory}![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"protocol_min\":{d},\"protocol_max\":{d},\"client_kind\":\"{s}\",\"capabilities\":[\"runtime_metadata_v1\"]}}",
        .{ protocol.version_major, protocol.version_major, client_kind },
    );
}

fn buildRequest(allocator: std.mem.Allocator, method: []const u8, params_json: ?[]const u8) error{OutOfMemory}![]u8 {
    if (params_json) |p| {
        return std.fmt.allocPrint(allocator, "{{\"method\":\"{s}\",\"params\":{s}}}", .{ method, p });
    }
    return std.fmt.allocPrint(allocator, "{{\"method\":\"{s}\"}}", .{method});
}

/// hello_ack payload에서 `host_id`(32-hex)를 u128로 읽는다. 없거나 형식이 틀리면 null.
fn parseHostId(payload: []const u8) ?u128 {
    // 작은 payload라 std.json Value로 파싱(server와 대칭). 실패/부재는 null.
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, payload, .{}) catch return null;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const hex = switch (obj.get("host_id") orelse return null) {
        .string => |s| s,
        else => return null,
    };
    if (hex.len == 0 or hex.len > 32) return null;
    var v: u128 = 0;
    for (hex) |ch| {
        const d: u128 = switch (ch) {
            '0'...'9' => ch - '0',
            'a'...'f' => ch - 'a' + 10,
            'A'...'F' => ch - 'A' + 10,
            else => return null,
        };
        v = v * 16 + d;
    }
    return v;
}

// ─────────────────────────────────────────────────────────────────────────────
// 테스트 (순수 JSON은 always, 실 roundtrip은 fork된 host와 macOS opt-in)
//
// 이 테스트가 증명하는 것(그리고 터미널에서 왜 중요한가): GUI 재접속(§7)은 이 client가 host에 붙어 hello로 host_id를
// 확정하고 command를 왕복하는 데서 시작한다. hello/request JSON 조립과 host_id 파싱이 server 대칭인지(순수), 그리고
// 실제 fork된 host에 connect→hello→host.info가 왕복하고 host_id가 서로 일치하는지(실 socket)를 고정한다.
// ─────────────────────────────────────────────────────────────────────────────

const testing = std.testing;
const daemon = @import("daemon.zig");

test "client: hello/request JSON build and host_id parse are server-symmetric (pure)" {
    const allocator = testing.allocator;
    const hello = try buildHello(allocator, "gui");
    defer allocator.free(hello);
    try testing.expect(std.mem.indexOf(u8, hello, "\"protocol_min\":2") != null); // 리뷰 #3: version_major v2.
    try testing.expect(std.mem.indexOf(u8, hello, "\"client_kind\":\"gui\"") != null);
    try testing.expect(std.mem.indexOf(u8, hello, "\"runtime_metadata_v1\"") != null);

    const req = try buildRequest(allocator, "runtime.get", "{\"runtime_id\":\"aa\"}");
    defer allocator.free(req);
    try testing.expect(std.mem.indexOf(u8, req, "\"method\":\"runtime.get\"") != null);
    try testing.expect(std.mem.indexOf(u8, req, "\"runtime_id\":\"aa\"") != null);

    const req2 = try buildRequest(allocator, "host.info", null);
    defer allocator.free(req2);
    try testing.expectEqualStrings("{\"method\":\"host.info\"}", req2);

    try testing.expectEqual(@as(?u128, 0x1234), parseHostId("{\"host_id\":\"1234\"}"));
    try testing.expectEqual(@as(?u128, null), parseHostId("{\"no_host\":true}"));
    try testing.expectEqual(@as(?u128, null), parseHostId("not json"));
}

test "client: connects to a forked host, agrees on host_id, and calls host.info" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;

    var dir_buf: [256]u8 = undefined;
    const dir_path = std.fmt.bufPrintZ(&dir_buf, "/tmp/maru-sh-client-{d}", .{c.getpid()}) catch return error.SkipZigTest;
    var sp_buf: [320]u8 = undefined;
    const socket_path = std.fmt.bufPrintZ(&sp_buf, "{s}/control.sock", .{dir_path}) catch return error.SkipZigTest;

    const child = c.fork();
    if (child < 0) return error.SkipZigTest;
    if (child == 0) {
        _ = c.setsid();
        daemon.runSessionHost(std.heap.page_allocator, testing.io, dir_path, socket_path) catch {};
        std.c._exit(0);
    }
    defer {
        _ = c.kill(child, posix.SIG.TERM);
        var status: c_int = undefined;
        _ = c.waitpid(child, &status, 0);
        _ = c.unlink(socket_path.ptr);
        _ = c.rmdir(dir_path.ptr);
    }

    // host가 bind할 때까지 재시도 connect.
    var client: Client = blk: {
        var attempts: usize = 0;
        while (attempts < 150) : (attempts += 1) {
            if (Client.connect(allocator, socket_path, "cli")) |cl| {
                break :blk cl;
            } else |_| {
                _ = usleepMs(20);
            }
        }
        try testing.expect(false); // host가 3초 안에 안 떴다.
        return;
    };
    defer client.deinit();

    try testing.expect(client.host_id != 0); // hello_ack에서 host_id를 받았다.
    const resp = try client.call("host.info", null);
    defer allocator.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "runtime_count") != null);
    // host.info 응답의 host_id(result에 중첩)도 hello_ack와 같은 host를 가리킨다 — hex로 대조(nested 파싱 없이).
    var host_hex_buf: [40]u8 = undefined;
    const host_hex = std.fmt.bufPrint(&host_hex_buf, "{x:0>32}", .{client.host_id}) catch unreachable;
    try testing.expect(std.mem.indexOf(u8, resp, host_hex) != null);
}

extern "c" fn usleep(usec: c_uint) c_int;
fn usleepMs(ms: c_uint) c_int {
    return usleep(ms * 1000);
}

/// response JSON에서 `runtime_id`(server가 `{x:0>32}`로 낸 32-hex)를 뽑는다. 없으면 null. 실 wire 응답에서 runtime_id를
/// 되읽어 terminate에 되먹인다(nested JSON 파싱 없이 고정 폭 hex만 복사). `RemoteRuntime`(e2e-2c-2)도 이걸 재사용한다.
pub fn extractRuntimeId(payload: []const u8) ?[32]u8 {
    const key = "\"runtime_id\":\"";
    const start = std.mem.indexOf(u8, payload, key) orelse return null;
    const hex_start = start + key.len;
    if (hex_start + 32 > payload.len) return null;
    var out: [32]u8 = undefined;
    @memcpy(&out, payload[hex_start .. hex_start + 32]);
    return out;
}

/// response JSON에서 `"<key>":` 뒤의 unsigned 정수를 읽는다. 없으면 null(attach 응답의 stream_id 되읽기). `RemoteRuntime`도 재사용.
pub fn extractU64Field(payload: []const u8, key: []const u8) ?u64 {
    const at = std.mem.indexOf(u8, payload, key) orelse return null;
    var i = at + key.len;
    var v: u64 = 0;
    var any = false;
    while (i < payload.len and payload[i] >= '0' and payload[i] <= '9') : (i += 1) {
        v = v * 10 + (payload[i] - '0');
        any = true;
    }
    return if (any) v else null;
}

test "client: spawns, lists, and terminates a real runtime on a forked host over the wire" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;

    var dir_buf: [256]u8 = undefined;
    const dir_path = std.fmt.bufPrintZ(&dir_buf, "/tmp/maru-sh-spawn-{d}", .{c.getpid()}) catch return error.SkipZigTest;
    var sp_buf: [320]u8 = undefined;
    const socket_path = std.fmt.bufPrintZ(&sp_buf, "{s}/control.sock", .{dir_path}) catch return error.SkipZigTest;

    const child = c.fork();
    if (child < 0) return error.SkipZigTest;
    if (child == 0) {
        _ = c.setsid();
        daemon.runSessionHost(std.heap.page_allocator, testing.io, dir_path, socket_path) catch {};
        std.c._exit(0);
    }
    defer {
        _ = c.kill(child, posix.SIG.TERM);
        var status: c_int = undefined;
        _ = c.waitpid(child, &status, 0);
        _ = c.unlink(socket_path.ptr);
        _ = c.rmdir(dir_path.ptr);
    }

    var client: Client = blk: {
        var attempts: usize = 0;
        while (attempts < 150) : (attempts += 1) {
            if (Client.connect(allocator, socket_path, "gui")) |cl| break :blk cl else |_| _ = usleepMs(20);
        }
        try testing.expect(false); // host가 3초 안에 안 떴다.
        return;
    };
    defer client.deinit();

    // runtime.spawn: 실 PTY runtime을 host에 띄우고 runtime_id를 받는다(client→socket→dispatch→RuntimeOps→forkpty 전 경로).
    const spawn_resp = try client.call("runtime.spawn", "{\"argv\":[\"/bin/sh\",\"-c\",\"exit 0\"],\"cols\":40,\"rows\":10}");
    defer allocator.free(spawn_resp);
    const rid = extractRuntimeId(spawn_resp) orelse {
        try testing.expect(false); // 응답에 runtime_id가 없다.
        return;
    };

    // runtime.list: 방금 띄운 runtime이 재접속 조회에 보인다(같은 32-hex).
    const list_resp = try client.call("runtime.list", null);
    defer allocator.free(list_resp);
    try testing.expect(std.mem.indexOf(u8, list_resp, rid[0..]) != null);

    // runtime.terminate: 그 runtime을 내린다(host가 PTY/자식/reader를 회수).
    var term_buf: [64]u8 = undefined;
    const term_params = std.fmt.bufPrint(&term_buf, "{{\"runtime_id\":\"{s}\"}}", .{rid}) catch return error.SkipZigTest;
    const term_resp = try client.call("runtime.terminate", term_params);
    defer allocator.free(term_resp);
    try testing.expect(std.mem.indexOf(u8, term_resp, "terminated") != null);
}

test "client: attach, input, resize, and detach a real runtime over the wire" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;

    var dir_buf: [256]u8 = undefined;
    const dir_path = std.fmt.bufPrintZ(&dir_buf, "/tmp/maru-sh-attach-{d}", .{c.getpid()}) catch return error.SkipZigTest;
    var sp_buf: [320]u8 = undefined;
    const socket_path = std.fmt.bufPrintZ(&sp_buf, "{s}/control.sock", .{dir_path}) catch return error.SkipZigTest;

    const child = c.fork();
    if (child < 0) return error.SkipZigTest;
    if (child == 0) {
        _ = c.setsid();
        daemon.runSessionHost(std.heap.page_allocator, testing.io, dir_path, socket_path) catch {};
        std.c._exit(0);
    }
    defer {
        _ = c.kill(child, posix.SIG.TERM);
        var status: c_int = undefined;
        _ = c.waitpid(child, &status, 0);
        _ = c.unlink(socket_path.ptr);
        _ = c.rmdir(dir_path.ptr);
    }

    var client: Client = blk: {
        var attempts: usize = 0;
        while (attempts < 150) : (attempts += 1) {
            if (Client.connect(allocator, socket_path, "gui")) |cl| break :blk cl else |_| _ = usleepMs(20);
        }
        try testing.expect(false);
        return;
    };
    defer client.deinit();

    // cat runtime을 띄운다(입력 EOF까지 생존).
    const spawn_resp = try client.call("runtime.spawn", "{\"argv\":[\"/bin/cat\"],\"cols\":40,\"rows\":10}");
    defer allocator.free(spawn_resp);
    const rid = extractRuntimeId(spawn_resp) orelse {
        try testing.expect(false);
        return;
    };

    // controller로 attach → input+resize capability와 stream_id를 받는다.
    var attach_buf: [96]u8 = undefined;
    const attach_params = std.fmt.bufPrint(&attach_buf, "{{\"runtime_id\":\"{s}\",\"mode\":\"controller\"}}", .{rid}) catch return error.SkipZigTest;
    const attach_resp = try client.call("runtime.attach", attach_params);
    defer allocator.free(attach_resp);
    try testing.expect(std.mem.indexOf(u8, attach_resp, "\"input\":true") != null);
    const stream_id = extractU64Field(attach_resp, "\"stream_id\":") orelse {
        try testing.expect(false);
        return;
    };

    // attach 직후 host가 보내는 화면 snapshot stream을 end_stream까지 비운다(§10 순서). 첫 record는 screen_meta여야 한다.
    const snap = try client.readSnapshot(stream_id);
    defer allocator.free(snap);
    try testing.expect(snap.len > 0);
    {
        var rs = screen_stream.RecordStream{ .bytes = snap };
        const first = (try rs.next()).?;
        const s = try screen_stream.RecordStream.split(first);
        try testing.expectEqual(screen_stream.RecordKind.screen_meta, s.header.kind);
        const meta = try screen_stream.decodeScreenMeta(s.body);
        try testing.expectEqual(@as(u16, 40), meta.cols); // spawn한 cols=40이 snapshot에 반영됐다.
    }

    // input(fire-and-forget) → controller라 host가 PTY로 전달한다(에러 없이 전송됨만 본다; 반영은 e2d).
    try client.sendInput(stream_id, "hello\n");

    // resize(controller) → applied 응답(changed=true, 새 canonical size).
    var resize_buf: [96]u8 = undefined;
    const resize_params = std.fmt.bufPrint(&resize_buf, "{{\"stream_id\":{d},\"cols\":100,\"rows\":30,\"client_sequence\":1}}", .{stream_id}) catch return error.SkipZigTest;
    const resize_resp = try client.call("runtime.resize", resize_params);
    defer allocator.free(resize_resp);
    try testing.expect(std.mem.indexOf(u8, resize_resp, "\"changed\":true") != null);
    try testing.expect(std.mem.indexOf(u8, resize_resp, "\"cols\":100") != null);

    // detach → subscription 해제.
    var detach_buf: [48]u8 = undefined;
    const detach_params = std.fmt.bufPrint(&detach_buf, "{{\"stream_id\":{d}}}", .{stream_id}) catch return error.SkipZigTest;
    const detach_resp = try client.call("runtime.detach", detach_params);
    defer allocator.free(detach_resp);
    try testing.expect(std.mem.indexOf(u8, detach_resp, "detached") != null);

    // 정리: runtime 종료.
    var term_buf: [64]u8 = undefined;
    const term_params = std.fmt.bufPrint(&term_buf, "{{\"runtime_id\":\"{s}\"}}", .{rid}) catch return error.SkipZigTest;
    const term_resp = try client.call("runtime.terminate", term_params);
    defer allocator.free(term_resp);
    try testing.expect(std.mem.indexOf(u8, term_resp, "terminated") != null);
}

test "client: receives a delta_chunk stream reflecting input echoed onto the screen" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;

    var dir_buf: [256]u8 = undefined;
    const dir_path = std.fmt.bufPrintZ(&dir_buf, "/tmp/maru-sh-delta-{d}", .{c.getpid()}) catch return error.SkipZigTest;
    var sp_buf: [320]u8 = undefined;
    const socket_path = std.fmt.bufPrintZ(&sp_buf, "{s}/control.sock", .{dir_path}) catch return error.SkipZigTest;

    const child = c.fork();
    if (child < 0) return error.SkipZigTest;
    if (child == 0) {
        _ = c.setsid();
        daemon.runSessionHost(std.heap.page_allocator, testing.io, dir_path, socket_path) catch {};
        std.c._exit(0);
    }
    defer {
        _ = c.kill(child, posix.SIG.TERM);
        var status: c_int = undefined;
        _ = c.waitpid(child, &status, 0);
        _ = c.unlink(socket_path.ptr);
        _ = c.rmdir(dir_path.ptr);
    }

    var client: Client = blk: {
        var attempts: usize = 0;
        while (attempts < 150) : (attempts += 1) {
            if (Client.connect(allocator, socket_path, "gui")) |cl| break :blk cl else |_| _ = usleepMs(20);
        }
        try testing.expect(false);
        return;
    };
    defer client.deinit();

    const spawn_resp = try client.call("runtime.spawn", "{\"argv\":[\"/bin/cat\"],\"cols\":40,\"rows\":10}");
    defer allocator.free(spawn_resp);
    const rid = extractRuntimeId(spawn_resp) orelse {
        try testing.expect(false);
        return;
    };
    var attach_buf: [96]u8 = undefined;
    const attach_params = std.fmt.bufPrint(&attach_buf, "{{\"runtime_id\":\"{s}\",\"mode\":\"controller\"}}", .{rid}) catch return error.SkipZigTest;
    const attach_resp = try client.call("runtime.attach", attach_params);
    defer allocator.free(attach_resp);
    const stream_id = extractU64Field(attach_resp, "\"stream_id\":") orelse {
        try testing.expect(false);
        return;
    };
    const snap = try client.readSnapshot(stream_id);
    defer allocator.free(snap);

    // input을 보내면 PTY가 echo → 화면 row0이 바뀐다. host의 poll tick이 delta_chunk로 push한다.
    try client.sendInput(stream_id, "hello\n");

    // stream 배치를 폴링해 row0 set_runs의 첫 run이 "h"(echo된 "hello"의 시작)인지 확인한다(부분 echo·tick 타이밍 견딤).
    // readStreamBatch는 논블로킹이라 delta가 도착할 때까지 짧게 잔다(host delta tick ~20ms).
    var found = false;
    var attempts: usize = 0;
    while (attempts < 100 and !found) : (attempts += 1) {
        const batch = (client.readStreamBatch(allocator, stream_id) catch break) orelse {
            _ = usleepMs(20);
            continue;
        };
        defer allocator.free(batch.bytes);
        var rs = screen_stream.RecordStream{ .bytes = batch.bytes };
        while (try rs.next()) |rec| {
            const s = try screen_stream.RecordStream.split(rec);
            if (s.header.kind == .set_runs) {
                const sr = try screen_stream.decodeSetRuns(allocator, s.body);
                defer sr.deinit(allocator);
                if (sr.row_index == 0 and sr.runs.len > 0 and std.mem.eql(u8, sr.runs[0].grapheme, "h")) found = true;
            }
        }
    }
    try testing.expect(found);

    var term_buf: [64]u8 = undefined;
    const term_params = std.fmt.bufPrint(&term_buf, "{{\"runtime_id\":\"{s}\"}}", .{rid}) catch return error.SkipZigTest;
    const term_resp = try client.call("runtime.terminate", term_params);
    defer allocator.free(term_resp);
    try testing.expect(std.mem.indexOf(u8, term_resp, "terminated") != null);
}
