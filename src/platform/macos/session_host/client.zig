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
    OutOfMemory,
};

/// host와의 한 connection. `host_id`는 hello_ack로 받은 값이다(§4 stale handle 판정에 쓴다). `call`은 read-only
/// command를 왕복한다.
pub const Client = struct {
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    host_id: u128,
    parser: framing.FrameParser,
    next_request_id: u64 = 1,

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
        _ = c.close(self.fd);
        self.parser.deinit();
        self.* = undefined;
    }

    /// read-only command를 왕복한다. `params_json`은 JSON object 문자열(예: `{"runtime_id":"aa"}`) 또는 null. 반환
    /// payload는 host의 response JSON(owned — caller가 free). typed error 판정은 caller가 payload에서 한다(§10 error 매핑).
    pub fn call(self: *Client, method: []const u8, params_json: ?[]const u8) ClientError![]u8 {
        const req = buildRequest(self.allocator, method, params_json) catch return error.OutOfMemory;
        defer self.allocator.free(req);
        const request_id = self.next_request_id;
        self.next_request_id += 1;
        const frame_bytes = framing.encodeFrame(self.allocator, .{ .kind = .request, .request_id = request_id }, req) catch return error.OutOfMemory;
        defer self.allocator.free(frame_bytes);
        socket_server.writeAll(self.fd, frame_bytes) catch return error.WriteFailed;

        // 응답을 기다리는 동안 host가 비동기로 push하는 stream frame(delta_chunk/snapshot_chunk)은 건너뛴다 — 이 간단한
        // 동기 client는 그 화면 stream을 소비하지 않으므로(GUI event loop가 라우팅) 여기선 무시하고 응답만 골라낸다.
        while (true) {
            const resp = try self.readFrame();
            defer resp.deinit(self.allocator);
            if (resp.header.kind == .delta_chunk or resp.header.kind == .snapshot_chunk) continue;
            // kind와 request_id를 함께 확인한다 — out-of-order frame을 이 call의 응답으로 오귀속하지 않는다.
            if (resp.header.kind != .response or resp.header.request_id != request_id) return error.ProtocolError;
            return self.allocator.dupe(u8, resp.payload) catch return error.OutOfMemory;
        }
    }

    /// attach 직후 host가 보내는 `snapshot_chunk` stream을 `end_stream`까지 읽어 record 바이트를 이어 돌려준다(§10 attach
    /// 순서: response → snapshot_chunk*). 반환 바이트는 caller 소유(screen_stream.RecordStream으로 순회). **attach 응답을
    /// 받은 뒤 다음 request 전에 반드시 이걸로 stream을 비운다** — 안 그러면 leftover chunk가 다음 응답으로 오독된다.
    pub fn readSnapshot(self: *Client, stream_id: u64) ClientError![]u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(self.allocator);
        while (true) {
            const frame = try self.readFrame();
            defer frame.deinit(self.allocator);
            if (frame.header.kind != .snapshot_chunk or frame.header.stream_id != stream_id) return error.ProtocolError;
            out.appendSlice(self.allocator, frame.payload) catch return error.OutOfMemory;
            if (protocol.Flags.hasEndStream(frame.header.flags)) break;
        }
        return out.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
    }

    /// 다음 delta batch(host가 push한 `delta_chunk` stream)를 `end_stream`까지 읽어 record 바이트로 잇는다(caller 소유,
    /// `screen_stream.RecordStream`으로 순회). 화면이 바뀌면 host가 poll tick마다 보낸다. `stream_id`로 구분한다. 응답/
    /// snapshot_chunk를 만나면 ProtocolError(이 helper는 delta batch 전용 — 실 GUI는 event loop가 모든 frame을 라우팅한다).
    pub fn readDelta(self: *Client, stream_id: u64) ClientError![]u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(self.allocator);
        while (true) {
            const frame = try self.readFrame();
            defer frame.deinit(self.allocator);
            if (frame.header.kind != .delta_chunk or frame.header.stream_id != stream_id) return error.ProtocolError;
            out.appendSlice(self.allocator, frame.payload) catch return error.OutOfMemory;
            if (protocol.Flags.hasEndStream(frame.header.flags)) break;
        }
        return out.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
    }

    /// terminal input bytes를 attach된 `stream_id`로 보낸다(§9 `input_bytes` — 응답 없는 fire-and-forget). controller만
    /// 유효하고, host는 비controller/미attach stream의 input을 조용히 버린다. attach 응답의 stream_id를 그대로 쓴다.
    pub fn sendInput(self: *Client, stream_id: u64, bytes: []const u8) ClientError!void {
        const frame_bytes = framing.encodeFrame(self.allocator, .{ .kind = .input_bytes, .stream_id = stream_id }, bytes) catch return error.OutOfMemory;
        defer self.allocator.free(frame_bytes);
        socket_server.writeAll(self.fd, frame_bytes) catch return error.WriteFailed;
    }

    /// 다음 완성 frame을 읽는다(partial read 재조립). EOF/timeout는 ConnectionClosed, codec 위반은 ProtocolError.
    fn readFrame(self: *Client) ClientError!framing.Frame {
        var buf: [4096]u8 = undefined;
        while (true) {
            if (self.parser.next() catch return error.ProtocolError) |frame| return frame;
            const n = c.read(self.fd, &buf, buf.len);
            if (n < 0) {
                if (posix.errno(n) == .INTR) continue; // 시그널 인터럽트는 재시도(timeout/EAGAIN·기타 오류는 종료로).
                return error.ConnectionClosed;
            }
            if (n == 0) return error.ConnectionClosed; // EOF.
            self.parser.push(buf[0..@intCast(n)]) catch return error.OutOfMemory;
        }
    }
};

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
    return std.fmt.allocPrint(allocator, "{{\"protocol_min\":{d},\"protocol_max\":{d},\"client_kind\":\"{s}\"}}", .{ protocol.version_major, protocol.version_major, client_kind });
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
    try testing.expect(std.mem.indexOf(u8, hello, "\"protocol_min\":1") != null);
    try testing.expect(std.mem.indexOf(u8, hello, "\"client_kind\":\"gui\"") != null);

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

    // delta batch를 몇 번 읽어 row0 set_runs의 첫 run이 "h"(echo된 "hello"의 시작)인지 확인한다(부분 echo·tick 타이밍 견딤).
    var found = false;
    var attempts: usize = 0;
    while (attempts < 8 and !found) : (attempts += 1) {
        const delta = client.readDelta(stream_id) catch break;
        defer allocator.free(delta);
        var rs = screen_stream.RecordStream{ .bytes = delta };
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
