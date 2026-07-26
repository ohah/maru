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
const compatibility = @import("compatibility.zig");
const framing = @import("framing.zig");
const socket_server = @import("socket_server.zig");
const screen_stream = @import("screen_stream.zig");
const observation_wire = @import("observation_wire.zig");
const upgrade_wire = @import("upgrade_wire.zig");

pub const ClientError = error{
    EndpointAbsent,
    EndpointDenied,
    EndpointTransient,
    /// hello 왕복이 실패했다(전송/수신/파싱). 또는 host_id를 못 읽었다.
    HandshakeFailed,
    AdminBusy,
    Unauthorized,
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

pub const EndpointFailure = enum { absent, denied, transient, other };

pub fn classifyConnectErrno(err: posix.E) EndpointFailure {
    return switch (err) {
        .NOENT, .CONNREFUSED => .absent,
        .ACCES, .PERM => .denied,
        .INTR, .AGAIN, .TIMEDOUT => .transient,
        else => .other,
    };
}

test "client connect errno classification separates launchable absence from denial and retry" {
    try std.testing.expectEqual(EndpointFailure.absent, classifyConnectErrno(.NOENT));
    try std.testing.expectEqual(EndpointFailure.absent, classifyConnectErrno(.CONNREFUSED));
    try std.testing.expectEqual(EndpointFailure.denied, classifyConnectErrno(.ACCES));
    try std.testing.expectEqual(EndpointFailure.denied, classifyConnectErrno(.PERM));
    try std.testing.expectEqual(EndpointFailure.transient, classifyConnectErrno(.INTR));
    try std.testing.expectEqual(EndpointFailure.transient, classifyConnectErrno(.AGAIN));
    try std.testing.expectEqual(EndpointFailure.transient, classifyConnectErrno(.TIMEDOUT));
}

test "client screen assembler yields between split snapshot chunks and resumes boundedly" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fds: [2]c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    defer _ = c.close(fds[1]);
    var client = Client{
        .allocator = allocator,
        .fd = fds[0],
        .host_id = 1,
        .parser = framing.FrameParser.init(allocator),
    };
    defer client.deinit();
    const first = try framing.encodeFrame(
        allocator,
        .{ .kind = .snapshot_chunk, .stream_id = 7 },
        "first-",
    );
    defer allocator.free(first);
    try socket_server.writeAll(fds[1], first);
    try testing.expect((try client.readStreamBatch(allocator, 7)) == null);
    try testing.expect(client.partial_batch != null);

    const last = try framing.encodeFrame(
        allocator,
        .{ .kind = .snapshot_chunk, .stream_id = 7, .flags = protocol.Flags.end_stream },
        "last",
    );
    defer allocator.free(last);
    try socket_server.writeAll(fds[1], last);
    const batch = (try client.readStreamBatch(allocator, 7)).?;
    defer allocator.free(batch.bytes);
    try testing.expect(batch.is_snapshot);
    try testing.expectEqualStrings("first-last", batch.bytes);
    try testing.expect(client.partial_batch == null);
}

test "client screen assembler poisons malformed async header and event interleave" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const Scenario = enum { event_request, event_flags, screen_request, interleaved_event };
    inline for (std.meta.tags(Scenario)) |scenario| {
        var fds: [2]c.fd_t = undefined;
        try testing.expectEqual(
            @as(c_int, 0),
            c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds),
        );
        defer _ = c.close(fds[1]);
        var client = Client{
            .allocator = allocator,
            .fd = fds[0],
            .host_id = 1,
            .parser = framing.FrameParser.init(allocator),
        };
        defer client.deinit();
        if (scenario == .interleaved_event) {
            const first = try framing.encodeFrame(
                allocator,
                .{ .kind = .snapshot_chunk, .stream_id = 7 },
                "partial",
            );
            defer allocator.free(first);
            try socket_server.writeAll(fds[1], first);
        }
        const malformed = switch (scenario) {
            .event_request => try framing.encodeFrame(
                allocator,
                .{ .kind = .event, .request_id = 9, .stream_id = 7 },
                "{}",
            ),
            .event_flags => try framing.encodeFrame(
                allocator,
                .{ .kind = .event, .stream_id = 7, .flags = 1 },
                "{}",
            ),
            .screen_request => try framing.encodeFrame(
                allocator,
                .{
                    .kind = .snapshot_chunk,
                    .request_id = 9,
                    .stream_id = 7,
                    .flags = protocol.Flags.end_stream,
                },
                "screen",
            ),
            .interleaved_event => try framing.encodeFrame(
                allocator,
                .{ .kind = .event, .stream_id = 7 },
                "{}",
            ),
        };
        defer allocator.free(malformed);
        try socket_server.writeAll(fds[1], malformed);
        try testing.expectError(error.ProtocolError, client.readStreamBatch(allocator, 7));
        try testing.expectError(error.ConnectionClosed, client.readStreamBatch(allocator, 7));
    }
}

fn endpointError(err: posix.E) ClientError {
    return switch (classifyConnectErrno(err)) {
        .absent => error.EndpointAbsent,
        .denied, .other => error.EndpointDenied,
        .transient => error.EndpointTransient,
    };
}

/// `readStreamBatch`가 돌려주는 한 화면 stream 배치. `is_snapshot`이면 fresh full snapshot(화면 리셋), 아니면 delta 증분이다
/// (§9 — host가 grid/alt 변화 시 delta 대신 snapshot을 push하므로 소비자는 둘 다 받는다). `bytes`는 `end_stream`까지 이은
/// record 바이트(caller 소유), `stream_id`는 어느 runtime의 화면인지다(멀티 runtime 라우팅).
pub const StreamBatch = struct {
    is_snapshot: bool,
    stream_id: u64,
    bytes: []u8,
};

pub const InventoryUnavailable = enum {
    unsupported,
    authority_changed,
    generation_changed,
    lifecycle_changed,
    cap_exceeded,
    unauthorized,
    host_rejected,
    protocol_rejected,
    malformed,
};

pub const RuntimeInventory = union(enum) {
    unavailable: struct {
        reason: InventoryUnavailable,
        page_count: u8,
    },
    complete: Complete,

    pub const Complete = struct {
        membership_generation: u64,
        upgrade_epoch: u64,
        authority_generation: u64,
        /// 전체 recovery collector가 host별 ceiling 합계를 31 page로 제한하기 위한 실제 소비량.
        page_count: u8,
        runtime_ids: []u128,

        pub fn deinit(self: *Complete, allocator: std.mem.Allocator) void {
            allocator.free(self.runtime_ids);
            self.* = undefined;
        }
    };
};

/// host와의 한 connection. `host_id`는 hello_ack로 받은 값이다(§4 stale handle 판정에 쓴다). `call`은 read-only
/// command를 왕복한다.
pub const Client = struct {
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    host_id: u128,
    /// Exact host manifest ABA 검증용 hello identity. 과거 manifest 없는 peer는 null/0/empty일 수 있다.
    build_id: ?[]u8 = null,
    upgrade_epoch: u64 = 0,
    authority_generation: u64 = 0,
    lifecycle: []u8 = &.{},
    /// host-id manifest를 publish하는 peer인지. 이 capability가 있으면 hello identity 필드는 전부 필수이며 legacy
    /// endpoint 추측 경로에서 받아들이지 않는다.
    host_manifest_v1: bool = false,
    host_exec_upgrade_v1: bool = false,
    runtime_inventory_v1: bool = false,
    /// Hidden one-shot admin role을 host가 명시적으로 지원하는가. CLI는 이 값 없이 read method를 추측하지 않는다.
    admin_one_shot_v1: bool = false,
    /// Public `runtime end`를 exact one-shot admin mutation으로 지원하는가.
    admin_runtime_end_v1: bool = false,
    /// 이 connection이 협상한 MRSH header major. current GUI는 current와 frozen N-1 adapter를 별도
    /// connection으로 유지하므로 모든 outbound/inbound frame이 이 값을 사용한다.
    wire_major: u16 = protocol.version_major,
    /// 이 MRSH adapter가 받아야 하는 exact screen record version. current major는 current codec,
    /// capability-tagged N-1 adapter는 직전 codec만 받는다. 두 버전을 전역 reader 범위로 섞지 않는다.
    screen_codec_version: u16 = @import("screen_stream.zig").codec_version,
    /// hello_ack에서 host가 `screen_viewport_scrolled_v1` mode bit을 신뢰할 수 있다고 광고했는가. 구 host ACK에는
    /// capability가 없으므로 false로 남겨 remote preedit가 숨은 live cursor에 그려지지 않게 한다.
    screen_viewport_scrolled_v1: bool = false,
    /// host가 응답 없는 `scroll_to_bottom` stream frame을 지원하는가. false인 구 host에서는
    /// AppKit callback이 동기 RPC로 fallback하지 않고 scrolled preedit를 fail-closed한다.
    async_scroll_to_bottom_v1: bool = false,
    /// host가 scroll 외 focus/config/prompt를 포함한 bounded `runtime.core_command` v1 집합을 지원하는가.
    /// false인 구 host에는 기존 scroll만 보내고 새 명령은 degraded no-op으로 남긴다.
    runtime_core_command_v1: bool = false,
    /// host가 `runtime.selected_text`로 자기 TerminalCore에서 선택 의미론을 해석할 수 있는가. false인 구 host는
    /// 앱 업데이트보다 먼저 떠 계속 살아 있을 수 있으므로, client의 현재 화면 projection에서 보이는 선택만 추출한다.
    runtime_selected_text_v1: bool = false,
    /// host가 consumptive notification RPC를 exact attached stream으로 인가하는가. false인 same-major 구 host에는
    /// legacy runtime selector를 보내되, 새 host도 그 connection의 live controller만 fallback으로 허용한다.
    notification_stream_auth_v1: bool = false,
    /// host가 `runtime.link_at`으로 자기 core의 `extractUrlAt`(추출 + cwd resolve + 존재 stat)을 실행할 수 있는가.
    /// 없으면 client는 이 RPC를 보내지 않고 원격 링크 열기를 비활성한다(docs/link-detection.md §원격(host-backed) 세션).
    runtime_link_at_v1: bool = false,
    /// host가 `runtime.clipboard_write`로 OSC 52 write 텍스트를 넘길 수 있는가. 없으면 원격 클립보드가 비활성이다.
    runtime_clipboard_v1: bool = false,
    parser: framing.FrameParser,
    // async full-state를 하나라도 수용하지 못하면 server subscription base는 이미 전진했을 수 있다. 그 뒤 같은 socket을
    // 계속 쓰면 어떤 shared stream이 누락됐는지 복구할 수 없으므로 connection 전체를 poison/close한다.
    unusable: bool = false,
    next_request_id: u64 = 1,
    // 응답을 기다리는 `call` 중에 host가 비동기로 push한 stream frame(delta_chunk/snapshot_chunk)을 여기 버퍼한다 — 드롭하면
    // 화면 갱신이 유실되므로(§9 delta는 증분이라 하나만 놓쳐도 desync), 다음 `readStreamBatch`가 소켓보다 먼저 이걸 비운다.
    pending_stream: std.ArrayListUnmanaged(framing.Frame) = .empty,
    pending_stream_bytes: usize = 0,
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
    pending_batch_bytes: usize = 0,
    partial_batch: ?PartialBatch = null,
    // UI의 non-blocking input/viewport-command 경로가 socket backpressure를 만났을 때 소유하는 **단 하나의 완성 wire
    // frame**. offset은 이미 kernel이 수락한 prefix 뒤를 가리킨다. frame을 이 슬롯에 넣는 순간 payload/command는 caller
    // 관점에서 accepted이므로 재전송하지 않는다. 한 슬롯 + RemoteRuntime의 stream별 sticky intent로 메모리가 고정 상한이다.
    pending_outbound: ?PendingOutbound = null,

    const PendingOutbound = struct {
        frame: []u8,
        offset: usize = 0,
    };

    const PartialBatch = struct {
        stream_id: u64,
        is_snapshot: bool,
        bytes: std.ArrayListUnmanaged(u8) = .empty,
        chunk_count: usize = 0,
    };

    /// host socket에 connect하고 hello를 왕복한다. 성공하면 `host_id`가 채워진 Client다. host가 없으면 EndpointAbsent
    /// (discovery가 이 신호로 spawn/host_unavailable을 가른다, P3-d2b). version 불일치는 IncompatibleVersion.
    pub fn connect(allocator: std.mem.Allocator, socket_path: [:0]const u8, client_kind: []const u8) ClientError!Client {
        return connectMajor(allocator, socket_path, client_kind, protocol.version_major);
    }

    pub fn connectAdmin(
        allocator: std.mem.Allocator,
        socket_path: [:0]const u8,
    ) ClientError!Client {
        return requireAdminCapability(try connect(allocator, socket_path, "admin"));
    }

    fn requireAdminCapability(candidate: Client) ClientError!Client {
        var client = candidate;
        if (!client.admin_one_shot_v1) {
            client.deinit();
            return error.IncompatibleVersion;
        }
        return client;
    }

    pub fn requireAdminRuntimeEnd(self: *Client) ClientError!void {
        if (self.admin_runtime_end_v1) return;
        self.failClosed();
        return error.IncompatibleVersion;
    }

    /// Frozen N-1 adapter 전용 연결점. 범위 협상처럼 보이게 여러 major를 한 connection에 광고하지 않고,
    /// 선택한 wire major의 header와 hello 범위를 정확히 하나로 고정한다.
    pub fn connectMajor(
        allocator: std.mem.Allocator,
        socket_path: [:0]const u8,
        client_kind: []const u8,
        wire_major: u16,
    ) ClientError!Client {
        const profile = compatibility.profileForMajor(wire_major) orelse return error.IncompatibleVersion;
        // over-long path는 sun_path(104B)를 넘겨 slice-bounds panic이 되므로 syscall 전에 거부한다(bind의 socketPathFits 대칭).
        if (!socket_server.socketPathFits(socket_path.len)) return error.EndpointDenied;
        const fd = c.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        if (fd < 0) return endpointError(posix.errno(fd));
        errdefer _ = c.close(fd);
        // host가 죽은 socket에 write하면 SIGPIPE로 **프로세스가 죽는다** — EPIPE로 바꿔 catchable하게 한다(server accept 경로와 대칭).
        socket_server.setNoSigPipe(fd);
        // host가 연결만 받고(backlog) 응답하지 않으면 read가 영원히 막힌다 — recv timeout으로 ConnectionClosed로 빠져나온다.
        setReadTimeoutMs(fd, 5000);
        var addr = posix.sockaddr.un{ .family = posix.AF.UNIX, .path = undefined };
        @memset(&addr.path, 0);
        @memcpy(addr.path[0..socket_path.len], socket_path);
        const connect_rc = c.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));
        if (connect_rc != 0) return endpointError(posix.errno(connect_rc));

        var self = Client{
            .allocator = allocator,
            .fd = fd,
            .host_id = 0,
            .wire_major = wire_major,
            .parser = framing.FrameParser.initForMajor(allocator, wire_major),
        };
        errdefer self.parser.deinit();

        // hello 전송.
        const hello = buildHelloMajor(allocator, client_kind, wire_major) catch return error.OutOfMemory;
        defer allocator.free(hello);
        const hello_frame = framing.encodeFrame(
            allocator,
            .{ .kind = .hello, .request_id = 0, .major = wire_major },
            hello,
        ) catch return error.OutOfMemory;
        defer allocator.free(hello_frame);
        socket_server.writeAll(fd, hello_frame) catch return error.WriteFailed;

        // hello_ack 수신.
        const ack = try self.readFrame();
        defer ack.deinit(allocator);
        if (ack.header.kind != .hello_ack) return error.HandshakeFailed;
        if (std.mem.indexOf(u8, ack.payload, "incompatible_version") != null) return error.IncompatibleVersion;
        if (std.mem.indexOf(u8, ack.payload, "\"error\":\"resource_exhausted\"") != null)
            return error.AdminBusy;
        if (std.mem.indexOf(u8, ack.payload, "\"error\":\"unauthorized\"") != null)
            return error.Unauthorized;
        if (parseSelectedVersion(ack.payload) != wire_major) return error.HandshakeFailed;
        // 과거 개발 중 같은 MRSH v1 아래 screen body 의미가 여러 번 바뀌었다. build identity가 없는 untagged v1을
        // current body로 추측하면 structurally-valid silent misrender가 가능하므로, frozen release가 명시한
        // capability가 있는 직전 major만 연다. current major는 major bump 자체가 screen v2 경계다.
        if (profile.required_fingerprint) |fingerprint| if (!payloadHasCapability(ack.payload, fingerprint))
            return error.IncompatibleVersion;
        self.host_id = parseHostId(ack.payload) orelse return error.HandshakeFailed;
        const build_id = try parseStringFieldAlloc(self.allocator, ack.payload, "build_id");
        errdefer if (build_id) |owned| self.allocator.free(owned);
        const lifecycle = try parseStringFieldAlloc(self.allocator, ack.payload, "lifecycle");
        errdefer if (lifecycle) |owned| self.allocator.free(owned);
        const upgrade_epoch = parseUnsignedField(ack.payload, "upgrade_epoch");
        const authority_generation = parseUnsignedField(ack.payload, "authority_generation");
        const peer_screen_codec = parseUnsignedField(ack.payload, "screen_codec_version");
        const manifest_capable = payloadHasCapability(ack.payload, "host_manifest_v1");
        const inventory_capable = payloadHasCapability(ack.payload, "runtime_inventory_v1");
        if (manifest_capable and
            (build_id == null or lifecycle == null or upgrade_epoch == null or peer_screen_codec == null))
            return error.HandshakeFailed;
        if (inventory_capable and
            (authority_generation == null or authority_generation.? == 0 or !manifest_capable))
            return error.HandshakeFailed;
        if (peer_screen_codec) |codec| {
            if (codec > std.math.maxInt(u16)) return error.HandshakeFailed;
            self.screen_codec_version = @intCast(codec);
        } else {
            self.screen_codec_version = profile.screen_codec_version;
        }
        self.build_id = build_id;
        self.upgrade_epoch = upgrade_epoch orelse 0;
        self.authority_generation = authority_generation orelse 0;
        self.lifecycle = lifecycle orelse &.{};
        self.host_manifest_v1 = manifest_capable;
        self.host_exec_upgrade_v1 = payloadHasCapability(ack.payload, "host_exec_upgrade_v1");
        self.runtime_inventory_v1 = inventory_capable;
        self.admin_one_shot_v1 = payloadHasCapability(ack.payload, "admin_one_shot_v1");
        self.admin_runtime_end_v1 = payloadHasCapability(ack.payload, "admin_runtime_end_v1");
        self.screen_viewport_scrolled_v1 = payloadHasCapability(ack.payload, "screen_viewport_scrolled_v1");
        self.async_scroll_to_bottom_v1 = payloadHasCapability(ack.payload, "async_scroll_to_bottom_v1");
        self.runtime_core_command_v1 = payloadHasCapability(ack.payload, "runtime_core_command_v1");
        self.runtime_selected_text_v1 = payloadHasCapability(ack.payload, "runtime_selected_text_v1");
        self.notification_stream_auth_v1 = payloadHasCapability(
            ack.payload,
            "notification_stream_auth_v1",
        );
        self.runtime_link_at_v1 = payloadHasCapability(ack.payload, "runtime_link_at_v1");
        self.runtime_clipboard_v1 = payloadHasCapability(ack.payload, "runtime_clipboard_v1");
        return self;
    }

    pub fn deinit(self: *Client) void {
        if (self.fd >= 0) _ = c.close(self.fd);
        if (self.build_id) |build_id| self.allocator.free(build_id);
        if (self.lifecycle.len != 0) self.allocator.free(self.lifecycle);
        self.clearPendingOutbound();
        for (self.pending_stream.items) |f| f.deinit(self.allocator); // 미소비 버퍼 stream frame 회수.
        self.pending_stream.deinit(self.allocator);
        for (self.pending_events.items) |f| f.deinit(self.allocator);
        self.pending_events.deinit(self.allocator);
        for (self.pending_batches.items) |b| self.allocator.free(b.bytes); // 미소비 demux 배치 회수(§9 멀티 runtime).
        self.pending_batches.deinit(self.allocator);
        if (self.partial_batch) |*partial| partial.bytes.deinit(self.allocator);
        self.parser.deinit();
        self.* = undefined;
    }

    /// read-only command를 왕복한다. `params_json`은 JSON object 문자열(예: `{"runtime_id":"aa"}`) 또는 null. 반환
    /// payload는 host의 response JSON(owned — caller가 free). typed error 판정은 caller가 payload에서 한다(§10 error 매핑).
    pub fn call(self: *Client, method: []const u8, params_json: ?[]const u8) ClientError![]u8 {
        try self.ensureUsable();
        // non-blocking input이 backpressure로 일부만 전송됐어도 뒤 request가 wire에서 추월하면 안 된다.
        try self.flushPendingOutboundBlocking();
        const req = buildRequest(self.allocator, method, params_json) catch return error.OutOfMemory;
        defer self.allocator.free(req);
        const request_id = self.next_request_id;
        self.next_request_id += 1;
        const frame_bytes = framing.encodeFrame(
            self.allocator,
            .{ .kind = .request, .request_id = request_id, .major = self.wire_major },
            req,
        ) catch return error.OutOfMemory;
        defer self.allocator.free(frame_bytes);
        socket_server.writeAll(self.fd, frame_bytes) catch {
            // request prefix가 이미 kernel에 들어갔을 수 있다. 이 connection은 frame 경계를 다시 찾을 수 없으므로
            // 이후 RPC를 허용하지 않고 EOF로 모든 host-side attachment를 정리한다.
            self.invalidateConnection();
            return error.WriteFailed;
        };

        // 응답을 기다리는 동안 host가 비동기로 push하는 stream frame(delta_chunk/snapshot_chunk)은 **버퍼에 쌓는다** — 드롭하면
        // 그 사이 화면 갱신이 유실된다(§9 delta는 증분이라 한 배치만 놓쳐도 desync). 다음 `readStreamBatch`가 이 버퍼부터 소비한다.
        while (true) {
            const resp = try self.readFrame();
            if (resp.header.kind == .delta_chunk or resp.header.kind == .snapshot_chunk) {
                if (self.pending_stream.items.len >= protocol.max_client_screen_items or
                    self.screenInboxBytes() +| resp.payload.len > protocol.max_client_screen_inbox)
                {
                    resp.deinit(self.allocator);
                    self.invalidateConnection();
                    return error.EventQueueFull;
                }
                self.pending_stream.append(self.allocator, resp) catch {
                    resp.deinit(self.allocator);
                    // frame은 socket에서 이미 소비됐다. 저장하지 못하면 다음 stream delta의 base가 끊기므로 fail-closed.
                    self.invalidateConnection();
                    return error.OutOfMemory;
                };
                self.pending_stream_bytes += resp.payload.len;
                continue;
            }
            if (resp.header.kind == .event) {
                try self.bufferEvent(resp);
                continue;
            }
            defer resp.deinit(self.allocator);
            // kind와 request_id를 함께 확인한다 — out-of-order frame을 이 call의 응답으로 오귀속하지 않는다.
            if (resp.header.kind != .response or resp.header.request_id != request_id) {
                self.invalidateConnection();
                return error.ProtocolError;
            }
            return self.allocator.dupe(u8, resp.payload) catch return error.OutOfMemory;
        }
    }

    /// ID-only inventory를 한 authority generation 아래 끝까지 모은다. 중간 page가 stale/error면 이미 모은 prefix를
    /// 절대 반환하지 않고 typed unavailable로 강등한다. Recovery projection의 malformed response는 canonical exact
    /// manifest attach가 같은 adapter에서 계속 가능하도록 connection 전체를 poison하지 않는다.
    pub fn runtimeInventory(self: *Client) ClientError!RuntimeInventory {
        var consumed: u8 = 0;
        return self.runtimeInventoryBounded(protocol.max_inventory_pages, &consumed);
    }

    pub fn runtimeInventoryBounded(
        self: *Client,
        max_pages: usize,
        consumed: *u8,
    ) ClientError!RuntimeInventory {
        consumed.* = 0;
        if (!self.runtime_inventory_v1) return .{ .unavailable = .{ .reason = .unsupported, .page_count = 0 } };
        var ids: std.ArrayListUnmanaged(u128) = .empty;
        errdefer ids.deinit(self.allocator);
        var cursor: []const u8 = "";
        var cursor_buf: [32]u8 = undefined;
        var generation: u64 = 0;
        var expected_total: ?usize = null;
        var page_count: usize = 0;

        while (true) {
            page_count += 1;
            if (page_count > protocol.max_inventory_pages or page_count > max_pages) {
                ids.deinit(self.allocator);
                return .{ .unavailable = .{
                    .reason = if (page_count > max_pages) .cap_exceeded else .malformed,
                    .page_count = @intCast(page_count - 1),
                } };
            }
            consumed.* = @intCast(page_count);
            var params: std.Io.Writer.Allocating = .init(self.allocator);
            defer params.deinit();
            var js: std.json.Stringify = .{ .writer = &params.writer, .options = .{} };
            js.write(.{
                .cursor = cursor,
                .limit = @as(u16, @intCast(protocol.max_inventory_page_runtimes)),
                .membership_generation = generation,
            }) catch return error.OutOfMemory;
            const response = try self.call("runtime.inventory", params.written());
            defer self.allocator.free(response);
            if (parseInventoryError(response)) |code| {
                ids.deinit(self.allocator);
                return .{ .unavailable = .{
                    .reason = inventoryUnavailableFor(code),
                    .page_count = @intCast(page_count),
                } };
            }

            const page = parseInventoryPage(self.allocator, response) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Malformed => {
                    ids.deinit(self.allocator);
                    return .{ .unavailable = .{ .reason = .malformed, .page_count = @intCast(page_count) } };
                },
            };
            defer page.deinit(self.allocator);
            if (page.upgrade_epoch != self.upgrade_epoch or
                page.authority_generation != self.authority_generation)
            {
                ids.deinit(self.allocator);
                return .{ .unavailable = .{ .reason = .authority_changed, .page_count = @intCast(page_count) } };
            }
            if (generation == 0) {
                generation = page.membership_generation;
                expected_total = page.total;
            } else if (page.membership_generation != generation or page.total != expected_total.?) {
                ids.deinit(self.allocator);
                return .{ .unavailable = .{ .reason = .malformed, .page_count = @intCast(page_count) } };
            }
            if (!std.mem.eql(u8, page.cursor, cursor) or ids.items.len + page.runtime_ids.len > page.total) {
                ids.deinit(self.allocator);
                return .{ .unavailable = .{ .reason = .malformed, .page_count = @intCast(page_count) } };
            }
            if (ids.items.len != 0 and page.runtime_ids.len != 0 and
                ids.items[ids.items.len - 1] >= page.runtime_ids[0])
            {
                ids.deinit(self.allocator);
                return .{ .unavailable = .{ .reason = .malformed, .page_count = @intCast(page_count) } };
            }
            ids.appendSlice(self.allocator, page.runtime_ids) catch return error.OutOfMemory;
            if (page.done) {
                if (page.next_cursor.len != 0 or ids.items.len != page.total) {
                    ids.deinit(self.allocator);
                    return .{ .unavailable = .{ .reason = .malformed, .page_count = @intCast(page_count) } };
                }
                return .{ .complete = .{
                    .membership_generation = generation,
                    .upgrade_epoch = page.upgrade_epoch,
                    .authority_generation = page.authority_generation,
                    .page_count = @intCast(page_count),
                    .runtime_ids = ids.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
                } };
            }
            if (page.runtime_ids.len != protocol.max_inventory_page_runtimes or
                ids.items.len >= page.total or
                page.runtime_ids[page.runtime_ids.len - 1] != (parseExactInventoryId(page.next_cursor) orelse {
                    ids.deinit(self.allocator);
                    return .{ .unavailable = .{ .reason = .malformed, .page_count = @intCast(page_count) } };
                }))
            {
                ids.deinit(self.allocator);
                return .{ .unavailable = .{ .reason = .malformed, .page_count = @intCast(page_count) } };
            }
            @memcpy(&cursor_buf, page.next_cursor);
            cursor = &cursor_buf;
        }
    }

    pub const PrepareUpgradeOutcome = union(enum) {
        /// Host가 accepted response를 전량 보낸 뒤 이 connection을 닫는다. 이후 status/attach는 새 connection이어야 한다.
        accepted_reconnect_required,
        completed: upgrade_wire.AttemptReport,
        rejected,
    };

    pub fn prepareUpgrade(self: *Client, request: upgrade_wire.PrepareRequest) ClientError!PrepareUpgradeOutcome {
        if (!self.host_exec_upgrade_v1) return error.IncompatibleVersion;
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        var attempt_buf: [32]u8 = undefined;
        const attempt = std.fmt.bufPrint(&attempt_buf, "{x:0>32}", .{request.attempt_id}) catch
            return error.ProtocolError;
        const sha = std.fmt.bytesToHex(request.target_sha256, .lower);
        js.write(.{
            .attempt_id = attempt,
            .target_path = request.target_path,
            .target_build_id = request.target_build_id,
            .target_sha256 = &sha,
            .handoff_reader_min = request.handoff_reader_min,
            .handoff_reader_max = request.handoff_reader_max,
        }) catch return error.OutOfMemory;
        const response = try self.call("host.upgrade.prepare", out.written());
        defer self.allocator.free(response);
        return switch (parsePrepareUpgradeResponse(response, request.attempt_id)) {
            .accepted => {
                self.invalidateConnection();
                return .accepted_reconnect_required;
            },
            .completed => |report| .{ .completed = report },
            .rejected => .rejected,
            .malformed => {
                self.invalidateConnection();
                return error.ProtocolError;
            },
        };
    }

    pub fn upgradeStatus(self: *Client, attempt_id: u128) ClientError!?upgrade_wire.AttemptReport {
        var attempt_buf: [32]u8 = undefined;
        const attempt = std.fmt.bufPrint(&attempt_buf, "{x:0>32}", .{attempt_id}) catch
            return error.ProtocolError;
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        js.write(.{ .attempt_id = attempt }) catch return error.OutOfMemory;
        const response = try self.call("host.upgrade.status", out.written());
        defer self.allocator.free(response);
        if (parseAttemptStatus(response)) |report| return report;
        if (responseHasTypedError(response)) return null;
        self.invalidateConnection();
        return error.ProtocolError;
    }

    /// attach 직후 host가 보내는 `snapshot_chunk` stream을 `end_stream`까지 읽어 record 바이트를 이어 돌려준다(§10 attach
    /// 순서: response → snapshot_chunk*). 반환 바이트는 caller 소유(screen_stream.RecordStream으로 순회). **attach 응답을
    /// 받은 뒤 다음 request 전에 반드시 이걸로 stream을 비운다** — 안 그러면 leftover chunk가 다음 응답으로 오독된다.
    pub fn readSnapshot(self: *Client, stream_id: u64) ClientError![]u8 {
        try self.ensureUsable();
        var attempts: usize = 0;
        while (attempts < 250) : (attempts += 1) {
            if (try self.readStreamBatch(self.allocator, stream_id)) |batch| {
                if (!batch.is_snapshot) {
                    self.allocator.free(batch.bytes);
                    self.invalidateConnection();
                    return error.ProtocolError;
                }
                return batch.bytes;
            }
            _ = usleepMs(20);
        }
        self.invalidateConnection();
        return error.ConnectionClosed;
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
            if (b.stream_id == want_stream_id) {
                const owned = self.pending_batches.orderedRemove(i);
                self.pending_batch_bytes -= owned.bytes.len;
                return owned;
            }
        }
        // 2) 소켓에서 완성 배치를 읽는다. 내 것이면 반환, 남의 것이면 버퍼하고 계속(내 것/idle까지).
        while (true) {
            const batch = (try self.readOneBatch(allocator)) orelse return null; // idle — 내 배치 없음.
            if (batch.stream_id == want_stream_id) return batch;
            if (self.pending_batches.items.len >= protocol.max_client_screen_items or
                self.screenInboxBytes() +| batch.bytes.len > protocol.max_client_screen_inbox)
            {
                allocator.free(batch.bytes);
                self.invalidateConnection();
                return error.EventQueueFull;
            }
            // 남의 stream 배치 — 그 runtime pump가 소비하도록 버퍼. append 실패 시 이 배치 bytes를 회수(누수 방지).
            self.pending_batches.append(self.allocator, batch) catch {
                allocator.free(batch.bytes);
                self.invalidateConnection();
                return error.OutOfMemory;
            };
            self.pending_batch_bytes += batch.bytes.len;
        }
    }

    /// 소켓/`pending_stream`에서 완성 stream 배치 하나를 `end_stream`까지 읽어 돌려준다(stream_id 무관). **논블로킹**: 배치가
    /// 아직 없으면 `null`(recv timeout을 세션 종료로 오인 안 함, §9). host는 grid/alt 변화 시 delta 대신 fresh snapshot을 push한다
    /// (SnapshotRequired). demux는 상위 `readStreamBatch`가 한다 — 여기선 순수하게 "다음 배치 하나".
    fn readOneBatch(self: *Client, allocator: std.mem.Allocator) ClientError!?StreamBatch {
        var state = self.partial_batch orelse PartialBatch{
            .stream_id = 0,
            .is_snapshot = false,
        };
        self.partial_batch = null;
        errdefer state.bytes.deinit(allocator);
        var started = state.stream_id != 0;
        while (true) {
            const frame = (try self.nextStreamFrame(started)) orelse {
                if (started) {
                    self.partial_batch = state;
                    return null;
                }
                state.bytes.deinit(allocator);
                return null;
            };
            if (frame.header.kind == .event) {
                if (started or frame.header.request_id != 0 or frame.header.flags != 0) {
                    frame.deinit(self.allocator);
                    self.invalidateConnection();
                    return error.ProtocolError;
                }
                try self.bufferEvent(frame);
                continue;
            }
            defer frame.deinit(self.allocator);
            if (frame.header.kind != .snapshot_chunk and frame.header.kind != .delta_chunk) {
                self.invalidateConnection();
                return error.ProtocolError;
            }
            if (frame.header.request_id != 0) {
                self.invalidateConnection();
                return error.ProtocolError;
            }
            if (!started) {
                if (frame.header.stream_id == 0) {
                    self.invalidateConnection();
                    return error.ProtocolError;
                }
                state.stream_id = frame.header.stream_id;
                state.is_snapshot = frame.header.kind == .snapshot_chunk;
                started = true;
            } else if (frame.header.stream_id != state.stream_id or
                (frame.header.kind == .snapshot_chunk) != state.is_snapshot)
            {
                self.invalidateConnection();
                return error.ProtocolError;
            }
            if (frame.header.flags & ~protocol.Flags.end_stream != 0 or
                state.chunk_count >= protocol.max_viewport_snapshot / protocol.max_binary_chunk or
                state.bytes.items.len +| frame.payload.len > protocol.max_viewport_snapshot or
                self.screenInboxBytes() +| state.bytes.items.len +| frame.payload.len >
                    protocol.max_client_screen_inbox)
            {
                self.invalidateConnection();
                return error.ProtocolError;
            }
            state.chunk_count += 1;
            const next_len = state.bytes.items.len + frame.payload.len;
            state.bytes.ensureTotalCapacityPrecise(allocator, next_len) catch {
                self.invalidateConnection();
                return error.OutOfMemory;
            };
            state.bytes.appendSliceAssumeCapacity(frame.payload);
            if (protocol.Flags.hasEndStream(frame.header.flags)) {
                const bytes = state.bytes.toOwnedSlice(allocator) catch {
                    self.invalidateConnection();
                    return error.OutOfMemory;
                };
                return .{
                    .is_snapshot = state.is_snapshot,
                    .stream_id = state.stream_id,
                    .bytes = bytes,
                };
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
                self.pending_batch_bytes -= b.bytes.len;
                self.allocator.free(b.bytes);
            } else i += 1;
        }
        if (self.partial_batch) |*partial| {
            if (partial.stream_id == stream_id) {
                partial.bytes.deinit(self.allocator);
                self.partial_batch = null;
            }
        }
        i = 0;
        while (i < self.pending_stream.items.len) {
            if (self.pending_stream.items[i].header.stream_id == stream_id) {
                const frame = self.pending_stream.orderedRemove(i);
                self.pending_stream_bytes -= frame.payload.len;
                frame.deinit(self.allocator);
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

    fn screenInboxBytes(self: *const Client) usize {
        const partial = if (self.partial_batch) |batch| batch.bytes.items.len else 0;
        return self.pending_stream_bytes +| self.pending_batch_bytes +| partial;
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
        if (frame.header.kind != .event or frame.header.request_id != 0 or
            frame.header.stream_id == 0 or frame.header.flags != 0)
        {
            frame.deinit(self.allocator);
            self.invalidateConnection();
            return error.ProtocolError;
        }
        const metadata_revision = observation_wire.eventRevision(self.allocator, frame.payload) catch {
            frame.deinit(self.allocator);
            self.invalidateConnection();
            return error.OutOfMemory;
        };
        if (std.mem.indexOf(u8, frame.payload, "\"event\":\"runtime.metadata\"") != null and metadata_revision == null) {
            // 손상된 full-state가 정상 최신 event를 coalesce로 밀어내면 host는 이미 base를 전진시켜 영구 누락될 수 있다.
            // 큐에 넣기 전에 최소 wire schema를 검증해 손상 event는 기존 cache를 건드리지 않고 버린다.
            frame.deinit(self.allocator);
            return;
        }
        const runtime_ended = std.mem.eql(u8, frame.payload, "{\"event\":\"runtime.ended\"}");
        if (runtime_ended) {
            // Ended terminally supersedes every pending full-state/control event for this stream.
            // With 256 live attachments this replacement must not become a 257th queue item and
            // poison otherwise healthy sibling runtimes.
            const ended_stream = frame.header.stream_id;
            var ended_index: usize = 0;
            while (ended_index < self.pending_events.items.len) {
                if (self.pending_events.items[ended_index].header.stream_id == ended_stream) {
                    const replaced = self.pending_events.orderedRemove(ended_index);
                    self.pending_event_bytes -= replaced.payload.len;
                    replaced.deinit(self.allocator);
                } else ended_index += 1;
            }
        }
        for (self.pending_events.items, 0..) |old, i| {
            const old_revision = observation_wire.eventRevision(self.allocator, old.payload) catch {
                frame.deinit(self.allocator);
                self.invalidateConnection();
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
            self.invalidateConnection();
            return error.OutOfMemory;
        };
        self.pending_event_bytes += frame.payload.len;
    }

    /// stream 배치를 잇는 다음 stream frame을 준다. 우선순위: `call`이 버퍼한 frame → parser에 남은 완성 frame → 소켓 read.
    /// 첫 frame과 continuation 모두 `pollReadable`로 논블로킹 확인하고, 데이터가 없으면 partial batch를 caller가 보존하도록
    /// `null`을 돌려준다. UI frame pump에서 socket timeout까지 기다리지 않는다.
    fn nextStreamFrame(self: *Client, _: bool) ClientError!?framing.Frame {
        try self.ensureUsable();
        if (self.pending_stream.items.len > 0) {
            const owned = self.pending_stream.orderedRemove(0);
            self.pending_stream_bytes -= owned.payload.len;
            return try self.requireWireMajor(owned);
        }
        var buf: [4096]u8 = undefined;
        while (true) {
            if (self.parser.next() catch {
                self.invalidateConnection();
                return error.ProtocolError;
            }) |frame|
                return try self.requireWireMajor(frame);
            // Partial batches live across pump calls, so neither the first nor a continuation may
            // enter the socket's 5s blocking read timeout on the UI frame loop.
            if (!pollReadable(self.fd)) return null;
            const n = c.read(self.fd, &buf, buf.len);
            if (n < 0) {
                if (posix.errno(n) == .INTR) continue; // 시그널 인터럽트는 재시도.
                if (posix.errno(n) == .AGAIN or posix.errno(n) == .TIMEDOUT) return null;
                self.invalidateConnection();
                return error.ConnectionClosed;
            }
            if (n == 0) {
                self.invalidateConnection();
                return error.ConnectionClosed;
            }
            self.parser.push(buf[0..@intCast(n)]) catch {
                self.invalidateConnection();
                return error.OutOfMemory;
            };
        }
    }

    /// terminal input bytes를 attach된 `stream_id`로 보낸다(§9 `input_bytes` — 응답 없는 fire-and-forget). controller만
    /// 유효하고, host는 비controller/미attach stream의 input을 조용히 버린다. attach 응답의 stream_id를 그대로 쓴다.
    pub fn sendInput(self: *Client, stream_id: u64, bytes: []const u8) ClientError!void {
        try self.ensureUsable();
        // 앞 tick의 non-blocking frame부터 끝낸 뒤 새 blocking input을 쓴다. 같은 stream뿐 아니라 connection을 공유하는
        // 여러 runtime 사이에서도 실제 socket write 순서를 보존한다.
        try self.flushPendingOutboundBlocking();
        // input frame의 wire cap은 1 MiB다. paste가 이를 넘는 것은 정상 입력이므로 encode 실패/드롭하지 않고 순서대로
        // 여러 frame으로 나눈다. 빈 입력은 전송할 것이 없다.
        var offset: usize = 0;
        while (offset < bytes.len) {
            const end = inputChunkEnd(offset, bytes.len);
            const frame_bytes = framing.encodeFrame(self.allocator, .{
                .kind = .input_bytes,
                .stream_id = stream_id,
                .major = self.wire_major,
            }, bytes[offset..end]) catch
                return error.OutOfMemory;
            socket_server.writeAll(self.fd, frame_bytes) catch {
                self.allocator.free(frame_bytes);
                // frame prefix가 이미 kernel에 들어갔을 수 있어 같은 connection에서 재시도하면 framing/입력이 중복된다.
                self.invalidateConnection();
                return error.WriteFailed;
            };
            self.allocator.free(frame_bytes);
            offset = end;
        }
    }

    /// terminal input을 UI thread에서 **실제로 논블로킹** 전송한다. 반환값은 socket에 즉시 쓴 바이트가 아니라 이 connection이
    /// 소유권을 인수한 payload 바이트 수다. 기존 pending frame이 아직 막혀 있으면 0, 새 frame을 pending 슬롯에 넣었으면
    /// DONTWAIT flush가 0/partial/full 어느 경우든 그 payload 길이를 반환한다 — caller가 동일 입력을 재전송하지 않게 한다.
    pub fn sendInputNonBlocking(self: *Client, stream_id: u64, bytes: []const u8) ClientError!usize {
        try self.ensureUsable();

        // 기존 frame을 먼저 밀어 FIFO를 지킨다. 여전히 막혔으면 새 payload는 caller가 계속 소유한다.
        if (!(try self.pumpPendingOutput())) return 0;
        if (bytes.len == 0) return 0;

        const accepted = inputChunkEnd(0, bytes.len);
        const frame = framing.encodeFrame(
            self.allocator,
            .{ .kind = .input_bytes, .stream_id = stream_id, .major = self.wire_major },
            bytes[0..accepted],
        ) catch return error.OutOfMemory;
        std.debug.assert(self.pending_outbound == null);
        self.pending_outbound = .{ .frame = frame };

        // EAGAIN/partial write여도 frame 소유권은 이미 client로 넘어왔다. hard error만 connection을 fail-closed한다.
        _ = try self.pumpPendingOutput();
        return accepted;
    }

    /// AppKit callback에서 host viewport를 live bottom으로 되돌리는 fire-and-forget frame을 bounded
    /// outbound 슬롯에 admission한다. true면 frame 소유권을 인수했고, false면 기존 frame이 backpressure로
    /// 남아 caller가 stream-local sticky intent를 유지해야 한다. 구 host에는 절대 동기 RPC fallback하지 않는다.
    pub fn sendScrollToBottomNonBlocking(self: *Client, stream_id: u64) ClientError!bool {
        try self.ensureUsable();
        if (!self.async_scroll_to_bottom_v1) return false;
        if (!(try self.pumpPendingOutput())) return false;
        const frame = framing.encodeFrame(
            self.allocator,
            .{ .kind = .scroll_to_bottom, .stream_id = stream_id, .major = self.wire_major },
            "",
        ) catch return error.OutOfMemory;
        std.debug.assert(self.pending_outbound == null);
        self.pending_outbound = .{ .frame = frame };
        _ = try self.pumpPendingOutput();
        return true;
    }

    /// Coalesced invalidation recovery control for the UI frame pump. It shares the one bounded
    /// pending outbound slot with input/core commands and never waits for a response.
    pub fn sendResyncNonBlocking(self: *Client, stream_id: u64) ClientError!bool {
        try self.ensureUsable();
        if (!(try self.pumpPendingOutput())) return false;
        const frame = framing.encodeFrame(
            self.allocator,
            .{ .kind = .stream_ack, .stream_id = stream_id, .major = self.wire_major },
            "{\"action\":\"resync\"}",
        ) catch return error.OutOfMemory;
        std.debug.assert(self.pending_outbound == null);
        self.pending_outbound = .{ .frame = frame };
        _ = try self.pumpPendingOutput();
        return true;
    }

    /// host core command JSON을 응답 없는 stream frame으로 admission한다. true면 Client가 frame 소유권을
    /// 인수했고, false면 기존 outbound frame의 backpressure 때문에 caller가 bounded sticky queue에서 재시도해야 한다.
    pub fn sendCoreCommandNonBlocking(self: *Client, stream_id: u64, payload: []const u8) ClientError!bool {
        try self.ensureUsable();
        if (!self.runtime_core_command_v1) return false;
        if (!(try self.pumpPendingOutput())) return false;
        const frame = framing.encodeFrame(
            self.allocator,
            .{ .kind = .core_command, .stream_id = stream_id, .major = self.wire_major },
            payload,
        ) catch return error.OutOfMemory;
        std.debug.assert(self.pending_outbound == null);
        self.pending_outbound = .{ .frame = frame };
        _ = try self.pumpPendingOutput();
        return true;
    }

    /// 이미 RemoteRuntime의 ordered input FIFO가 소유한 scroll barrier를 후속 blocking RPC보다 먼저 보낸다.
    /// `call`과 마찬가지로 기존 nonblocking frame을 먼저 끝내므로 connection wire 순서는 보존된다.
    pub fn sendScrollToBottom(self: *Client, stream_id: u64) ClientError!void {
        try self.ensureUsable();
        if (!self.async_scroll_to_bottom_v1) return;
        try self.flushPendingOutboundBlocking();
        const frame = framing.encodeFrame(
            self.allocator,
            .{ .kind = .scroll_to_bottom, .stream_id = stream_id, .major = self.wire_major },
            "",
        ) catch return error.OutOfMemory;
        defer self.allocator.free(frame);
        socket_server.writeAll(self.fd, frame) catch {
            self.invalidateConnection();
            return error.WriteFailed;
        };
    }

    /// RemoteRuntime의 ordered queue를 뒤따르는 blocking RPC 직전에 남은 core frame을 전량 보낸다. 응답은 없지만
    /// 기존 pending frame을 먼저 끝내므로 connection wire FIFO를 보존한다.
    pub fn sendCoreCommand(self: *Client, stream_id: u64, payload: []const u8) ClientError!void {
        try self.ensureUsable();
        if (!self.runtime_core_command_v1) return;
        try self.flushPendingOutboundBlocking();
        const frame = framing.encodeFrame(
            self.allocator,
            .{ .kind = .core_command, .stream_id = stream_id, .major = self.wire_major },
            payload,
        ) catch return error.OutOfMemory;
        defer self.allocator.free(frame);
        socket_server.writeAll(self.fd, frame) catch {
            self.invalidateConnection();
            return error.WriteFailed;
        };
    }

    /// pending outbound frame의 남은 wire bytes를 blocking으로 전량 보낸다. 부분 write마다 offset을 진전시켜 오류 뒤 같은 prefix를
    /// 다시 보낼 가능성을 없앤다. hard error면 이 socket은 framing 경계를 복구할 수 없으므로 connection을 닫는다.
    fn flushPendingOutboundBlocking(self: *Client) ClientError!void {
        while (self.pending_outbound) |*pending| {
            const remaining = pending.frame[pending.offset..];
            const rc = c.write(self.fd, remaining.ptr, remaining.len);
            if (rc < 0) {
                if (posix.errno(rc) == .INTR) continue;
                self.invalidateConnection();
                return error.WriteFailed;
            }
            if (rc == 0) {
                self.invalidateConnection();
                return error.WriteFailed;
            }
            pending.offset += @intCast(rc);
            if (pending.offset == pending.frame.len) self.clearPendingOutbound();
        }
    }

    /// MSG_DONTWAIT로 pending frame을 가능한 만큼 민다. true면 슬롯이 비었고 새 payload를 받을 수 있다. EAGAIN은 정상
    /// backpressure라 false이며, 다른 오류는 partial frame 뒤 framing 복구가 불가능하므로 connection을 닫는다. Darwin은
    /// MSG_DONTWAIT만으로 blocking socket의 send가 멈추는 동작이 보장되지 않아 helper가 호출 구간에 O_NONBLOCK도 함께 건다.
    pub fn pumpPendingOutput(self: *Client) ClientError!bool {
        try self.ensureUsable();
        while (self.pending_outbound) |*pending| {
            const remaining = pending.frame[pending.offset..];
            switch (try self.sendDontWait(remaining)) {
                .would_block => return false,
                .written => |written| {
                    pending.offset += written;
                    if (pending.offset == pending.frame.len) self.clearPendingOutbound();
                },
            }
        }
        return true;
    }

    const NonblockingSend = union(enum) {
        written: usize,
        would_block,
    };

    /// macOS에서 실 non-blocking을 보장하기 위해 send 구간에만 descriptor O_NONBLOCK을 켰다가 원 flags로 되돌린다.
    /// Client outbound/read는 GUI frame thread에서 직렬 호출한다는 현재 계약에 기대며, flags 복원 실패 시 이후 blocking
    /// call의 의미가 바뀌므로 같은 connection을 계속 쓰지 않고 fail-closed한다.
    fn sendDontWait(self: *Client, bytes: []const u8) ClientError!NonblockingSend {
        const flags = c.fcntl(self.fd, c.F.GETFL, @as(c_int, 0));
        if (flags < 0) {
            self.invalidateConnection();
            return error.WriteFailed;
        }
        const nonblock_flag: c_int = @bitCast(posix.O{ .NONBLOCK = true });
        const changed = flags & nonblock_flag == 0;
        if (changed and c.fcntl(self.fd, c.F.SETFL, flags | nonblock_flag) < 0) {
            self.invalidateConnection();
            return error.WriteFailed;
        }

        var rc: isize = undefined;
        var send_errno: ?posix.E = null;
        while (true) {
            rc = c.send(self.fd, bytes.ptr, bytes.len, posix.MSG.DONTWAIT);
            if (rc >= 0) break;
            send_errno = posix.errno(rc);
            if (send_errno.? == .INTR) continue;
            break;
        }

        if (changed and c.fcntl(self.fd, c.F.SETFL, flags) < 0) {
            self.invalidateConnection();
            return error.WriteFailed;
        }
        if (rc > 0) return .{ .written = @intCast(rc) };
        if (rc < 0 and send_errno.? == .AGAIN) return .would_block;
        self.invalidateConnection();
        return error.WriteFailed;
    }

    fn clearPendingOutbound(self: *Client) void {
        if (self.pending_outbound) |pending| self.allocator.free(pending.frame);
        self.pending_outbound = null;
    }

    /// 다음 완성 frame을 읽는다(partial read 재조립). EOF/timeout는 ConnectionClosed, codec 위반은 ProtocolError.
    fn readFrame(self: *Client) ClientError!framing.Frame {
        try self.ensureUsable();
        var buf: [4096]u8 = undefined;
        while (true) {
            if (self.parser.next() catch {
                self.invalidateConnection();
                return error.ProtocolError;
            }) |frame|
                return self.requireWireMajor(frame) catch |err| {
                    self.invalidateConnection();
                    return err;
                };
            const n = c.read(self.fd, &buf, buf.len);
            if (n < 0) {
                if (posix.errno(n) == .INTR) continue; // 시그널 인터럽트는 재시도(timeout/EAGAIN·기타 오류는 종료로).
                self.invalidateConnection();
                return error.ConnectionClosed;
            }
            if (n == 0) {
                self.invalidateConnection();
                return error.ConnectionClosed; // EOF.
            }
            self.parser.push(buf[0..@intCast(n)]) catch {
                // 이미 socket에서 소비한 바이트를 parser에 보존하지 못했다. 다음 frame 경계를 복구할 수 없다.
                self.invalidateConnection();
                return error.OutOfMemory;
            };
        }
    }

    /// parser·call 중 임시 stream queue 어느 경로에서 꺼낸 frame이든 같은 major gate를 거친다. 잘못된 major의
    /// payload는 caller에게 넘기지 않고 여기서 회수한다.
    fn requireWireMajor(self: *Client, frame: framing.Frame) ClientError!framing.Frame {
        if (frame.header.major != self.wire_major) {
            frame.deinit(self.allocator);
            return error.ProtocolError;
        }
        return frame;
    }

    fn ensureUsable(self: *const Client) ClientError!void {
        if (self.unusable) return error.ConnectionClosed;
    }

    fn invalidateConnection(self: *Client) void {
        // pending frame은 connection 소유 메모리다. 이미 unusable이어도 deinit 전 명시 invalidate가 재진입할 수 있으므로
        // 항상 회수 helper를 거친다.
        self.clearPendingOutbound();
        if (self.unusable) return;
        self.unusable = true;
        if (self.fd >= 0) {
            _ = c.close(self.fd);
            self.fd = -1;
        }
    }

    /// lifecycle cleanup frame조차 할당할 수 없는 경우 host가 EOF로 attachment를 정리하도록 shared connection을
    /// 명시적으로 닫는 fail-closed fallback.
    pub fn failClosed(self: *Client) void {
        self.invalidateConnection();
    }
};

test "admin client without one-shot capability closes before sending any request" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    defer _ = c.close(fds[1]);
    const candidate: Client = .{
        .allocator = std.testing.allocator,
        .fd = fds[0],
        .host_id = 1,
        .wire_major = protocol.version_major,
        .parser = framing.FrameParser.init(std.testing.allocator),
        .admin_one_shot_v1 = false,
    };
    try std.testing.expectError(error.IncompatibleVersion, Client.requireAdminCapability(candidate));
    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 0), c.read(fds[1], &byte, byte.len));
}

test "admin runtime end capability absence closes before sending any request" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    defer _ = c.close(fds[1]);
    var client: Client = .{
        .allocator = std.testing.allocator,
        .fd = fds[0],
        .host_id = 1,
        .wire_major = protocol.version_major,
        .parser = framing.FrameParser.init(std.testing.allocator),
        .admin_one_shot_v1 = true,
        .admin_runtime_end_v1 = false,
    };
    defer client.deinit();
    try std.testing.expectError(error.IncompatibleVersion, client.requireAdminRuntimeEnd());
    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 0), c.read(fds[1], &byte, byte.len));
}

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

test "client N-1 wire selection fixes hello range and every outbound header to that major" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const previous_major = protocol.version_major - 1;
    const hello = try buildHelloMajor(allocator, "gui", previous_major);
    defer allocator.free(hello);
    try std.testing.expect(std.mem.indexOf(u8, hello, "\"protocol_min\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, hello, "\"protocol_max\":1") != null);

    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    defer _ = c.close(fds[1]);
    var client: Client = .{
        .allocator = allocator,
        .fd = fds[0],
        .host_id = 1,
        .wire_major = previous_major,
        .parser = framing.FrameParser.initForMajor(allocator, previous_major),
    };
    defer client.deinit();
    try client.sendInput(7, "legacy");
    var header_bytes: [protocol.header_size]u8 = undefined;
    try readExactFd(fds[1], &header_bytes);
    const header = try protocol.Header.decode(&header_bytes);
    try std.testing.expectEqual(previous_major, header.major);
    try std.testing.expectEqual(protocol.Kind.input_bytes, header.kind);
    var payload: [6]u8 = undefined;
    try readExactFd(fds[1], &payload);
    try std.testing.expectEqualStrings("legacy", &payload);
}

test "client nonblocking input accepts one bounded frame without duplicating it before blocking input" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    socket_server.setNoSigPipe(fds[0]);
    defer _ = c.close(fds[1]);

    var client = Client{
        .allocator = allocator,
        .fd = fds[0],
        .host_id = 1,
        .parser = framing.FrameParser.init(allocator),
    };
    defer client.deinit();
    setReadTimeoutMs(fds[1], 1000);

    const filler_len = try fillSendBufferNonBlocking(fds[0]);
    try std.testing.expect(filler_len > 0);

    const first = "first-pending";
    const second = "second-blocking";
    // kernel send buffer가 이미 찼어도 frame 소유권을 넘긴 payload는 전량 accepted다.
    try std.testing.expectEqual(first.len, try client.sendInputNonBlocking(7, first));
    try std.testing.expect(client.pending_outbound != null);
    // pending이 여전히 막힌 동안 새 payload는 수락하지 않아 caller가 그대로 보존한다.
    try std.testing.expectEqual(@as(usize, 0), try client.sendInputNonBlocking(7, second));

    try drainExactFd(fds[1], filler_len);
    // blocking input은 앞의 pending frame을 먼저 끝내고 자기 frame을 이어 쓴다.
    try client.sendInput(7, second);

    const first_frame = try framing.encodeFrame(allocator, .{ .kind = .input_bytes, .stream_id = 7 }, first);
    defer allocator.free(first_frame);
    const second_frame = try framing.encodeFrame(allocator, .{ .kind = .input_bytes, .stream_id = 7 }, second);
    defer allocator.free(second_frame);
    const received = try allocator.alloc(u8, first_frame.len + second_frame.len);
    defer allocator.free(received);
    try readExactFd(fds[1], received);
    try std.testing.expectEqualSlices(u8, first_frame, received[0..first_frame.len]);
    try std.testing.expectEqualSlices(u8, second_frame, received[first_frame.len..]);
    try std.testing.expect(client.pending_outbound == null);
}

test "client nonblocking scroll barrier stays between prior and subsequent input under backpressure" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    socket_server.setNoSigPipe(fds[0]);
    defer _ = c.close(fds[1]);

    var client = Client{
        .allocator = allocator,
        .fd = fds[0],
        .host_id = 1,
        .async_scroll_to_bottom_v1 = true,
        .parser = framing.FrameParser.init(allocator),
    };
    defer client.deinit();
    setReadTimeoutMs(fds[1], 1000);

    const filler_len = try fillSendBufferNonBlocking(fds[0]);
    const first = "before-scroll";
    const second = "after-scroll";
    try std.testing.expectEqual(first.len, try client.sendInputNonBlocking(7, first));
    try std.testing.expect(!(try client.sendScrollToBottomNonBlocking(7))); // 기존 frame 뒤 sticky intent 유지.
    try std.testing.expectEqual(@as(usize, 0), try client.sendInputNonBlocking(7, second));

    try drainExactFd(fds[1], filler_len);
    try std.testing.expect(try client.pumpPendingOutput());
    try std.testing.expect(try client.sendScrollToBottomNonBlocking(7));
    // scroll frame이 partial이면 새 input은 0으로 남고, 완전 전송됐으면 바로 뒤에 admission된다.
    var accepted = try client.sendInputNonBlocking(7, second);
    while (accepted == 0) {
        _ = try client.pumpPendingOutput();
        accepted = try client.sendInputNonBlocking(7, second);
    }
    try std.testing.expectEqual(second.len, accepted);
    while (!(try client.pumpPendingOutput())) {}

    const first_frame = try framing.encodeFrame(allocator, .{ .kind = .input_bytes, .stream_id = 7 }, first);
    defer allocator.free(first_frame);
    const scroll_frame = try framing.encodeFrame(allocator, .{ .kind = .scroll_to_bottom, .stream_id = 7 }, "");
    defer allocator.free(scroll_frame);
    const second_frame = try framing.encodeFrame(allocator, .{ .kind = .input_bytes, .stream_id = 7 }, second);
    defer allocator.free(second_frame);
    const received = try allocator.alloc(u8, first_frame.len + scroll_frame.len + second_frame.len);
    defer allocator.free(received);
    try readExactFd(fds[1], received);
    var offset: usize = 0;
    try std.testing.expectEqualSlices(u8, first_frame, received[offset..][0..first_frame.len]);
    offset += first_frame.len;
    try std.testing.expectEqualSlices(u8, scroll_frame, received[offset..][0..scroll_frame.len]);
    offset += scroll_frame.len;
    try std.testing.expectEqualSlices(u8, second_frame, received[offset..][0..second_frame.len]);
}

test "client does not send async scroll frame without negotiated capability" {
    const allocator = std.testing.allocator;
    var client = Client{
        .allocator = allocator,
        .fd = -1,
        .host_id = 1,
        .parser = framing.FrameParser.init(allocator),
    };
    defer client.deinit();
    try std.testing.expect(!(try client.sendScrollToBottomNonBlocking(7)));
    try std.testing.expect(client.pending_outbound == null);
}

test "client pending outbound pump finishes the last accepted frame without another input or RPC" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    socket_server.setNoSigPipe(fds[0]);
    defer _ = c.close(fds[1]);

    var client = Client{
        .allocator = allocator,
        .fd = fds[0],
        .host_id = 1,
        .parser = framing.FrameParser.init(allocator),
    };
    defer client.deinit();
    setReadTimeoutMs(fds[1], 1000);

    const filler_len = try fillSendBufferNonBlocking(fds[0]);
    const input = "last-input";
    try std.testing.expectEqual(input.len, try client.sendInputNonBlocking(3, input));
    try std.testing.expect(client.pending_outbound != null);
    try drainExactFd(fds[1], filler_len);

    // 새 입력/RPC 없이 frame-loop pump만 와도 마지막 pending frame이 전진·완료돼야 한다.
    try std.testing.expect(try client.pumpPendingOutput());
    try std.testing.expect(client.pending_outbound == null);
    const expected = try framing.encodeFrame(allocator, .{ .kind = .input_bytes, .stream_id = 3 }, input);
    defer allocator.free(expected);
    const received = try allocator.alloc(u8, expected.len);
    defer allocator.free(received);
    try readExactFd(fds[1], received);
    try std.testing.expectEqualSlices(u8, expected, received);
}

test "client call flushes accepted nonblocking input before its request frame" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    socket_server.setNoSigPipe(fds[0]);
    defer _ = c.close(fds[1]);

    var client = Client{
        .allocator = allocator,
        .fd = fds[0],
        .host_id = 1,
        .parser = framing.FrameParser.init(allocator),
    };
    defer client.deinit();
    setReadTimeoutMs(fds[0], 1000);
    setReadTimeoutMs(fds[1], 1000);

    const filler_len = try fillSendBufferNonBlocking(fds[0]);
    const input = "pending-before-rpc";
    try std.testing.expectEqual(input.len, try client.sendInputNonBlocking(9, input));
    try drainExactFd(fds[1], filler_len);

    const input_frame = try framing.encodeFrame(allocator, .{ .kind = .input_bytes, .stream_id = 9 }, input);
    defer allocator.free(input_frame);
    const request_payload = try buildRequest(allocator, "host.info", null);
    defer allocator.free(request_payload);
    const request_frame = try framing.encodeFrame(allocator, .{ .kind = .request, .request_id = 1 }, request_payload);
    defer allocator.free(request_frame);
    const expected = try allocator.alloc(u8, input_frame.len + request_frame.len);
    defer allocator.free(expected);
    @memcpy(expected[0..input_frame.len], input_frame);
    @memcpy(expected[input_frame.len..], request_frame);

    const response_frame = try framing.encodeFrame(
        allocator,
        .{ .kind = .response, .request_id = 1 },
        "{\"result\":{\"ok\":true}}",
    );
    defer allocator.free(response_frame);
    var peer_ok = false;
    const peer = try std.Thread.spawn(.{}, callOrderingPeer, .{ fds[1], expected, response_frame, &peer_ok });
    const response = client.call("host.info", null) catch |err| {
        peer.join();
        return err;
    };
    defer allocator.free(response);
    peer.join();
    try std.testing.expectEqualStrings("{\"result\":{\"ok\":true}}", response);
    try std.testing.expect(peer_ok);
}

test "client call poisons malformed event headers instead of buffering them" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    inline for (.{ "request_id", "flags", "stream_id" }) |malformed_field| {
        var fds: [2]c.fd_t = undefined;
        try testing.expectEqual(
            @as(c_int, 0),
            c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds),
        );
        defer _ = c.close(fds[1]);
        var client = Client{
            .allocator = allocator,
            .fd = fds[0],
            .host_id = 1,
            .parser = framing.FrameParser.init(allocator),
        };
        defer client.deinit();
        const wire = try framing.encodeFrame(
            allocator,
            .{
                .kind = .event,
                .request_id = if (std.mem.eql(u8, malformed_field, "request_id")) 7 else 0,
                .stream_id = if (std.mem.eql(u8, malformed_field, "stream_id")) 0 else 7,
                .flags = if (std.mem.eql(u8, malformed_field, "flags")) 1 else 0,
            },
            "{\"event\":\"host.test\"}",
        );
        defer allocator.free(wire);
        try socket_server.writeAll(fds[1], wire);
        try testing.expectError(error.ProtocolError, client.call("host.info", null));
        try testing.expectError(error.ConnectionClosed, client.call("host.info", null));
    }
}

test "client request write failure invalidates the connection before another call" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    socket_server.setNoSigPipe(fds[0]);
    _ = c.close(fds[1]);

    var client = Client{
        .allocator = allocator,
        .fd = fds[0],
        .host_id = 1,
        .parser = framing.FrameParser.init(allocator),
    };
    defer client.deinit();
    try std.testing.expectError(error.WriteFailed, client.call("host.info", null));
    try std.testing.expect(client.unusable);
    try std.testing.expectEqual(@as(c.fd_t, -1), client.fd);
    try std.testing.expect(client.pending_outbound == null);
    try std.testing.expectError(error.ConnectionClosed, client.call("host.info", null));
}

test "client response timeout invalidates the connection before another request id can desync" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    socket_server.setNoSigPipe(fds[0]);
    defer _ = c.close(fds[1]); // peer는 연결만 유지하고 응답하지 않는다.
    setReadTimeoutMs(fds[0], 20);

    var client = Client{
        .allocator = allocator,
        .fd = fds[0],
        .host_id = 1,
        .parser = framing.FrameParser.init(allocator),
    };
    defer client.deinit();
    try std.testing.expectError(error.ConnectionClosed, client.call("host.info", null));
    try std.testing.expect(client.unusable);
    try std.testing.expectEqual(@as(c.fd_t, -1), client.fd);
    // 늦은 response가 다음 request에 오귀속될 수 없도록 같은 socket은 재사용하지 않는다.
    try std.testing.expectError(error.ConnectionClosed, client.call("host.info", null));
}

test "client invalidation releases an owned pending outbound frame" {
    const allocator = std.testing.allocator;
    var client = Client{
        .allocator = allocator,
        .fd = -1,
        .host_id = 1,
        .parser = framing.FrameParser.init(allocator),
        .pending_outbound = .{ .frame = try allocator.dupe(u8, "owned-frame") },
    };
    defer client.deinit();
    client.invalidateConnection();
    try std.testing.expect(client.pending_outbound == null);
    try std.testing.expect(client.unusable);
}

/// test socket의 send buffer를 DONTWAIT로 실제 EAGAIN까지 채운다. filler 길이를 돌려줘 peer가 이후 정확히 걷어내고,
/// 그 뒤에 오는 MRSH frame 순서를 byte-for-byte 검증할 수 있게 한다.
fn fillSendBufferNonBlocking(fd: c.fd_t) !usize {
    var requested: c_int = 4096;
    _ = c.setsockopt(fd, posix.SOL.SOCKET, posix.SO.SNDBUF, &requested, @sizeOf(c_int));
    const flags = c.fcntl(fd, c.F.GETFL, @as(c_int, 0));
    if (flags < 0) return error.TestUnexpectedResult;
    const nonblock_flag: c_int = @bitCast(posix.O{ .NONBLOCK = true });
    if (c.fcntl(fd, c.F.SETFL, flags | nonblock_flag) < 0) return error.TestUnexpectedResult;
    defer _ = c.fcntl(fd, c.F.SETFL, flags);
    var filler: [4096]u8 = @splat(0xA5);
    var total: usize = 0;
    while (true) {
        const rc = c.send(fd, &filler, filler.len, posix.MSG.DONTWAIT);
        if (rc > 0) {
            total += @intCast(rc);
            if (total > 64 * 1024 * 1024) return error.TestUnexpectedResult;
            continue;
        }
        if (rc == 0) return error.TestUnexpectedResult;
        switch (posix.errno(rc)) {
            .INTR => continue,
            .AGAIN => return total,
            else => return error.TestUnexpectedResult,
        }
    }
}

fn drainExactFd(fd: c.fd_t, count: usize) !void {
    var remaining = count;
    var buf: [4096]u8 = undefined;
    while (remaining > 0) {
        const rc = c.read(fd, &buf, @min(buf.len, remaining));
        if (rc > 0) {
            remaining -= @intCast(rc);
            continue;
        }
        if (rc < 0 and posix.errno(rc) == .INTR) continue;
        return error.TestUnexpectedResult;
    }
}

fn readExactFd(fd: c.fd_t, out: []u8) !void {
    var offset: usize = 0;
    while (offset < out.len) {
        const rc = c.read(fd, out.ptr + offset, out.len - offset);
        if (rc > 0) {
            offset += @intCast(rc);
            continue;
        }
        if (rc < 0 and posix.errno(rc) == .INTR) continue;
        return error.TestUnexpectedResult;
    }
}

fn callOrderingPeer(fd: c.fd_t, expected: []const u8, response: []const u8, ok: *bool) void {
    const received = std.heap.page_allocator.alloc(u8, expected.len) catch return;
    defer std.heap.page_allocator.free(received);
    readExactFd(fd, received) catch return;
    ok.* = std.mem.eql(u8, expected, received);
    socket_server.writeAll(fd, response) catch return;
}

fn readTestRequest(fd: c.fd_t, allocator: std.mem.Allocator) !protocol.Header {
    var raw_header: [protocol.header_size]u8 = undefined;
    try readExactFd(fd, &raw_header);
    const header = try protocol.Header.decode(&raw_header);
    if (header.kind != .request or header.payload_len > protocol.max_control_json)
        return error.TestUnexpectedResult;
    const payload = try allocator.alloc(u8, header.payload_len);
    defer allocator.free(payload);
    try readExactFd(fd, payload);
    return header;
}

fn writeTestResponse(fd: c.fd_t, allocator: std.mem.Allocator, request_id: u64, payload: []const u8) !void {
    const frame = try framing.encodeFrame(allocator, .{ .kind = .response, .request_id = request_id }, payload);
    defer allocator.free(frame);
    try socket_server.writeAll(fd, frame);
}

fn inventoryIsolationPeer(fd: c.fd_t, ok: *bool) void {
    defer _ = c.close(fd);
    const allocator = std.heap.page_allocator;
    const inventory = readTestRequest(fd, allocator) catch return;
    writeTestResponse(fd, allocator, inventory.request_id, "{\"result\":{\"broken\":true}}") catch return;
    const get = readTestRequest(fd, allocator) catch return;
    writeTestResponse(fd, allocator, get.request_id, "{\"result\":{\"runtime_id\":\"00000000000000000000000000000001\"}}") catch return;
    ok.* = true;
}

fn writeInventoryTestPage(
    fd: c.fd_t,
    allocator: std.mem.Allocator,
    request_id: u64,
    start_id: usize,
    count: usize,
    total: usize,
    generation: u64,
    authority_generation: u64,
    cursor: []const u8,
    done: bool,
) !void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.print(
        "{{\"result\":{{\"version\":1,\"membership_generation\":{d},\"upgrade_epoch\":3,\"authority_generation\":{d},\"lifecycle\":\"ready\",\"total\":{d},\"cursor\":\"{s}\",\"runtime_ids\":[",
        .{ generation, authority_generation, total, cursor },
    );
    for (0..count) |offset| {
        if (offset != 0) try out.writer.writeByte(',');
        try out.writer.print("\"{x:0>32}\"", .{start_id + offset});
    }
    if (done) {
        try out.writer.writeAll("],\"next_cursor\":\"\",\"done\":true}}");
    } else {
        try out.writer.print("],\"next_cursor\":\"{x:0>32}\",\"done\":false}}}}", .{start_id + count - 1});
    }
    try writeTestResponse(fd, allocator, request_id, out.written());
}

fn inventoryMaxPeer(fd: c.fd_t, ok: *bool) void {
    defer _ = c.close(fd);
    const allocator = std.heap.page_allocator;
    var cursor_buf: [32]u8 = undefined;
    var cursor: []const u8 = "";
    for (0..protocol.max_inventory_pages) |page_index| {
        const request = readTestRequest(fd, allocator) catch return;
        const start_id = page_index * protocol.max_inventory_page_runtimes + 1;
        const done = page_index + 1 == protocol.max_inventory_pages;
        writeInventoryTestPage(
            fd,
            allocator,
            request.request_id,
            start_id,
            protocol.max_inventory_page_runtimes,
            protocol.max_inventory_runtimes,
            44,
            9,
            cursor,
            done,
        ) catch return;
        _ = std.fmt.bufPrint(&cursor_buf, "{x:0>32}", .{start_id + protocol.max_inventory_page_runtimes - 1}) catch return;
        cursor = &cursor_buf;
    }
    ok.* = true;
}

test "client inventory collector owns the exact 16-page maximum snapshot" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    socket_server.setNoSigPipe(fds[0]);
    setReadTimeoutMs(fds[0], 5000);
    var client: Client = .{
        .allocator = allocator,
        .fd = fds[0],
        .host_id = 1,
        .upgrade_epoch = 3,
        .authority_generation = 9,
        .runtime_inventory_v1 = true,
        .parser = framing.FrameParser.init(allocator),
    };
    defer client.deinit();
    var peer_ok = false;
    const peer = try std.Thread.spawn(.{}, inventoryMaxPeer, .{ fds[1], &peer_ok });
    var inventory = client.runtimeInventory() catch |err| {
        client.failClosed();
        peer.join();
        return err;
    };
    switch (inventory) {
        .unavailable => {
            client.failClosed();
            peer.join();
            return error.TestUnexpectedResult;
        },
        .complete => |*complete| {
            peer.join();
            try std.testing.expect(peer_ok);
            defer complete.deinit(allocator);
            try std.testing.expectEqual(@as(u64, 44), complete.membership_generation);
            try std.testing.expectEqual(@as(u8, protocol.max_inventory_pages), complete.page_count);
            try std.testing.expectEqual(protocol.max_inventory_runtimes, complete.runtime_ids.len);
            try std.testing.expectEqual(@as(u128, 1), complete.runtime_ids[0]);
            try std.testing.expectEqual(@as(u128, protocol.max_inventory_runtimes), complete.runtime_ids[complete.runtime_ids.len - 1]);
        },
    }
}

test "client inventory bounded collector는 page budget 0에서 request 전에 차단한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    defer _ = c.close(fds[1]);
    var client: Client = .{
        .allocator = std.testing.allocator,
        .fd = fds[0],
        .host_id = 1,
        .runtime_inventory_v1 = true,
        .parser = framing.FrameParser.init(std.testing.allocator),
    };
    defer client.deinit();
    var consumed: u8 = 99;
    const inventory = try client.runtimeInventoryBounded(0, &consumed);
    try std.testing.expectEqual(@as(u8, 0), consumed);
    try std.testing.expectEqual(InventoryUnavailable.cap_exceeded, inventory.unavailable.reason);
    try std.testing.expectEqual(@as(u8, 0), inventory.unavailable.page_count);
}

test "client malformed recovery inventory leaves canonical RPC usable on the same adapter" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    socket_server.setNoSigPipe(fds[0]);
    setReadTimeoutMs(fds[0], 1000);
    var client: Client = .{
        .allocator = allocator,
        .fd = fds[0],
        .host_id = 1,
        .upgrade_epoch = 3,
        .authority_generation = 9,
        .runtime_inventory_v1 = true,
        .parser = framing.FrameParser.init(allocator),
    };
    defer client.deinit();
    var peer_ok = false;
    const peer = try std.Thread.spawn(.{}, inventoryIsolationPeer, .{ fds[1], &peer_ok });
    const inventory = client.runtimeInventory() catch |err| {
        client.failClosed();
        peer.join();
        return err;
    };
    try std.testing.expectEqual(InventoryUnavailable.malformed, inventory.unavailable.reason);
    try std.testing.expectEqual(@as(u8, 1), inventory.unavailable.page_count);
    try std.testing.expect(!client.unusable);
    const get = client.call("runtime.get", "{\"runtime_id\":\"00000000000000000000000000000001\"}") catch |err| {
        client.failClosed();
        peer.join();
        return err;
    };
    defer allocator.free(get);
    peer.join();
    try std.testing.expect(peer_ok);
    try std.testing.expect(std.mem.indexOf(u8, get, "\"runtime_id\"") != null);
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

test "client ended event replaces same-stream metadata at exact event cap" {
    const allocator = std.testing.allocator;
    const metadata =
        \\{"event":"runtime.metadata","metadata_revision":1,"metadata":{"cwd":"/one","window_title":"one","ssh_remote_dest":null,
        \\"semantic_state":0,"alt_active":false,"app_cursor_keys":false,"alternate_scroll":true,"observer_generation":1,
        \\"title_generation":1,"cols":80,"rows":24,"foreground_available":false,"foreground_pgid":null,"processes":[]}}
    ;
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

    for (0..256) |i| try client.bufferEvent(.{
        .header = .{ .kind = .event, .stream_id = @intCast(i + 1) },
        .payload = try allocator.dupe(u8, metadata),
    });
    try std.testing.expectEqual(@as(usize, 256), client.pending_events.items.len);
    try client.bufferEvent(.{
        .header = .{ .kind = .event, .stream_id = 1 },
        .payload = try allocator.dupe(u8, "{\"event\":\"runtime.ended\"}"),
    });

    try std.testing.expect(!client.unusable);
    try std.testing.expectEqual(@as(usize, 256), client.pending_events.items.len);
    const ended = client.takeEventForStream(1) orelse return error.TestUnexpectedResult;
    defer ended.deinit(allocator);
    try std.testing.expectEqualStrings("{\"event\":\"runtime.ended\"}", ended.payload);
    const sibling = client.takeEventForStream(256) orelse return error.TestUnexpectedResult;
    defer sibling.deinit(allocator);
    try std.testing.expectEqual(
        @as(?u64, 1),
        try observation_wire.eventRevision(allocator, sibling.payload),
    );
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
// 신뢰 계약: `client_kind`·`method`는 **코드 내부 고정 리터럴**만 받는다(client_kind∈{"gui","cli","admin"}, method는 정의된
// 명령 이름 집합). 그래서 JSON escape 없이 그대로 interpolate한다 — 이 값들엔 `"`·`\`·제어문자가 없다. `params_json`은
// 이미 유효한 JSON object 문자열이라는 계약이라 raw로 싣는다(호출자가 조립 시 escape 책임). runtime.spawn(P3-e2b)처럼
// **임의 바이트(argv/cwd)**를 실어야 하는 params는 반드시 실 JSON encoder(server.zig `stringify` 대칭)로 만들어 넘긴다
// — 여기서 hand-interpolation하지 않는다.

fn buildHello(allocator: std.mem.Allocator, client_kind: []const u8) error{OutOfMemory}![]u8 {
    return buildHelloMajor(allocator, client_kind, protocol.version_major);
}

fn buildHelloMajor(
    allocator: std.mem.Allocator,
    client_kind: []const u8,
    wire_major: u16,
) error{OutOfMemory}![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"protocol_min\":{d},\"protocol_max\":{d},\"client_kind\":\"{s}\",\"capabilities\":[\"runtime_metadata_v1\",\"runtime_ended_v1\",\"screen_viewport_scrolled_v1\",\"async_scroll_to_bottom_v1\",\"runtime_core_command_v1\",\"runtime_selected_text_v1\",\"runtime_link_at_v1\",\"runtime_clipboard_v1\"]}}",
        .{ wire_major, wire_major, client_kind },
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

fn parseSelectedVersion(payload: []const u8) ?u16 {
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, payload, .{}) catch return null;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const raw = switch (obj.get("version") orelse return null) {
        .integer => |v| v,
        else => return null,
    };
    return std.math.cast(u16, raw);
}

fn parseUnsignedField(payload: []const u8, name: []const u8) ?u64 {
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, payload, .{}) catch return null;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const raw = switch (obj.get(name) orelse return null) {
        .integer => |value| value,
        else => return null,
    };
    return std.math.cast(u64, raw);
}

const InventoryPage = struct {
    membership_generation: u64,
    upgrade_epoch: u64,
    authority_generation: u64,
    total: usize,
    cursor: []u8,
    runtime_ids: []u128,
    next_cursor: []u8,
    done: bool,

    fn deinit(self: *const InventoryPage, allocator: std.mem.Allocator) void {
        allocator.free(self.cursor);
        allocator.free(self.runtime_ids);
        allocator.free(self.next_cursor);
    }
};

const InventoryParseError = error{ OutOfMemory, Malformed };

fn parseInventoryPage(allocator: std.mem.Allocator, payload: []const u8) InventoryParseError!InventoryPage {
    const SuccessWire = struct {
        result: struct {
            version: u8,
            membership_generation: u64,
            upgrade_epoch: u64,
            authority_generation: u64,
            lifecycle: []const u8,
            total: usize,
            cursor: []const u8,
            runtime_ids: []const []const u8,
            next_cursor: []const u8,
            done: bool,
        },
    };
    var parsed = std.json.parseFromSlice(SuccessWire, allocator, payload, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Malformed,
    };
    defer parsed.deinit();
    const result = parsed.value.result;
    if (result.version != 1 or
        result.membership_generation == 0 or
        result.authority_generation == 0 or
        !std.mem.eql(u8, result.lifecycle, "ready") or
        result.total > protocol.max_inventory_runtimes or
        result.runtime_ids.len > protocol.max_inventory_page_runtimes or
        (result.cursor.len != 0 and parseExactInventoryId(result.cursor) == null) or
        (result.next_cursor.len != 0 and parseExactInventoryId(result.next_cursor) == null))
        return error.Malformed;

    const owned_cursor = allocator.dupe(u8, result.cursor) catch return error.OutOfMemory;
    errdefer allocator.free(owned_cursor);
    const owned_ids = allocator.alloc(u128, result.runtime_ids.len) catch return error.OutOfMemory;
    errdefer allocator.free(owned_ids);
    for (result.runtime_ids, 0..) |raw, index| {
        const id = parseExactInventoryId(raw) orelse return error.Malformed;
        if (index != 0 and owned_ids[index - 1] >= id) return error.Malformed;
        owned_ids[index] = id;
    }
    const owned_next_cursor = allocator.dupe(u8, result.next_cursor) catch return error.OutOfMemory;
    return .{
        .membership_generation = result.membership_generation,
        .upgrade_epoch = result.upgrade_epoch,
        .authority_generation = result.authority_generation,
        .total = result.total,
        .cursor = owned_cursor,
        .runtime_ids = owned_ids,
        .next_cursor = owned_next_cursor,
        .done = result.done,
    };
}

fn parseInventoryError(payload: []const u8) ?protocol.ErrorCode {
    const ErrorWire = struct { @"error": []const u8 };
    var parsed = std.json.parseFromSlice(ErrorWire, std.heap.page_allocator, payload, .{}) catch return null;
    defer parsed.deinit();
    return protocol.ErrorCode.fromWireName(parsed.value.@"error");
}

fn inventoryUnavailableFor(code: protocol.ErrorCode) InventoryUnavailable {
    return switch (code) {
        .invalid_generation => .generation_changed,
        .host_shutting_down => .lifecycle_changed,
        .resource_exhausted, .payload_too_large => .cap_exceeded,
        .unauthorized, .incompatible_version, .upgrade_unsupported => .unauthorized,
        .host_unavailable, .stale_host, .runtime_not_found => .host_rejected,
        else => .protocol_rejected,
    };
}

fn parseExactInventoryId(raw: []const u8) ?u128 {
    if (raw.len != 32) return null;
    for (raw) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return null;
    const value = std.fmt.parseInt(u128, raw, 16) catch return null;
    return if (value == 0) null else value;
}

test "client inventory page parser owns escaped cursors and rejects non-canonical payloads" {
    const allocator = std.testing.allocator;
    const payload =
        \\{"result":{"version":1,"membership_generation":7,"upgrade_epoch":3,"authority_generation":9,"lifecycle":"ready","total":2,"cursor":"\u0030\u0030\u0030\u0030\u0030\u0030\u0030\u0030\u0030\u0030\u0030\u0030\u0030\u0030\u0030\u0030\u0030\u0030\u0030\u0030\u0030\u0030\u0030\u0030\u0030\u0030\u0030\u0030\u0030\u0030\u0030\u0031","runtime_ids":["00000000000000000000000000000002"],"next_cursor":"","done":true}}
    ;
    const page = try parseInventoryPage(allocator, payload);
    defer page.deinit(allocator);
    try std.testing.expectEqualStrings("00000000000000000000000000000001", page.cursor);
    try std.testing.expectEqual(@as(u128, 2), page.runtime_ids[0]);

    const malformed = [_][]const u8{
        "{\"result\":{\"version\":2,\"membership_generation\":7,\"upgrade_epoch\":3,\"authority_generation\":9,\"lifecycle\":\"ready\",\"total\":0,\"cursor\":\"\",\"runtime_ids\":[],\"next_cursor\":\"\",\"done\":true}}",
        "{\"result\":{\"version\":1,\"membership_generation\":0,\"upgrade_epoch\":3,\"authority_generation\":9,\"lifecycle\":\"ready\",\"total\":0,\"cursor\":\"\",\"runtime_ids\":[],\"next_cursor\":\"\",\"done\":true}}",
        "{\"result\":{\"version\":1,\"membership_generation\":7,\"upgrade_epoch\":3,\"authority_generation\":0,\"lifecycle\":\"ready\",\"total\":0,\"cursor\":\"\",\"runtime_ids\":[],\"next_cursor\":\"\",\"done\":true}}",
        "{\"result\":{\"version\":1,\"membership_generation\":7,\"upgrade_epoch\":3,\"authority_generation\":9,\"lifecycle\":\"restoring\",\"total\":0,\"cursor\":\"\",\"runtime_ids\":[],\"next_cursor\":\"\",\"done\":true}}",
        "{\"result\":{\"version\":1,\"membership_generation\":7,\"upgrade_epoch\":3,\"authority_generation\":9,\"lifecycle\":\"ready\",\"total\":2,\"cursor\":\"\",\"runtime_ids\":[\"00000000000000000000000000000002\",\"00000000000000000000000000000001\"],\"next_cursor\":\"\",\"done\":true}}",
        "{\"result\":{\"version\":1,\"membership_generation\":7,\"upgrade_epoch\":3,\"authority_generation\":9,\"lifecycle\":\"ready\",\"total\":0,\"cursor\":\"\",\"cursor\":\"\",\"runtime_ids\":[],\"next_cursor\":\"\",\"done\":true}}",
        "{\"result\":{\"version\":1,\"membership_generation\":7,\"upgrade_epoch\":3,\"authority_generation\":9,\"lifecycle\":\"ready\",\"total\":0,\"cursor\":\"\",\"runtime_ids\":[],\"next_cursor\":\"\",\"done\":true,\"extra\":1}}",
        "{\"error\":\"not_a_real_error\"}",
    };
    for (malformed) |bad|
        try std.testing.expectError(error.Malformed, parseInventoryPage(allocator, bad));
    try std.testing.expectEqual(protocol.ErrorCode.invalid_generation, parseInventoryError("{\"error\":\"invalid_generation\"}").?);
    try std.testing.expectEqual(InventoryUnavailable.generation_changed, inventoryUnavailableFor(.invalid_generation));
    try std.testing.expectEqual(InventoryUnavailable.lifecycle_changed, inventoryUnavailableFor(.host_shutting_down));
    try std.testing.expectEqual(InventoryUnavailable.cap_exceeded, inventoryUnavailableFor(.resource_exhausted));
}

fn parseStringFieldAlloc(
    allocator: std.mem.Allocator,
    payload: []const u8,
    name: []const u8,
) error{OutOfMemory}!?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, payload, .{}) catch return null;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    return switch (obj.get(name) orelse return null) {
        .string => |value| allocator.dupe(u8, value) catch return error.OutOfMemory,
        else => null,
    };
}

fn responseState(payload: []const u8, expected: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, payload, .{}) catch return false;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |value| value,
        else => return false,
    };
    const result = switch (root.get("result") orelse return false) {
        .object => |value| value,
        else => return false,
    };
    const state = switch (result.get("state") orelse return false) {
        .string => |value| value,
        else => return false,
    };
    return std.mem.eql(u8, state, expected);
}

const PrepareResponse = union(enum) {
    accepted,
    completed: upgrade_wire.AttemptReport,
    rejected,
    malformed,
};

fn parsePrepareUpgradeResponse(payload: []const u8, expected_attempt_id: u128) PrepareResponse {
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, payload, .{}) catch return .malformed;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |value| value,
        else => return .malformed,
    };
    if (root.get("error") != null) return if (responseObjectHasTypedError(root)) .rejected else .malformed;
    const result = switch (root.get("result") orelse return .malformed) {
        .object => |value| value,
        else => return .malformed,
    };
    const state = switch (result.get("state") orelse return .malformed) {
        .string => |value| value,
        else => return .malformed,
    };
    const attempt_raw = switch (result.get("attempt_id") orelse return .malformed) {
        .string => |value| value,
        else => return .malformed,
    };
    if (attempt_raw.len != 32) return .malformed;
    const actual = std.fmt.parseInt(u128, attempt_raw, 16) catch return .malformed;
    if (actual != expected_attempt_id) return .malformed;
    if (std.mem.eql(u8, state, "accepted")) return .accepted;
    const reason_raw = switch (result.get("reason") orelse return .malformed) {
        .string => |value| value,
        else => return .malformed,
    };
    const replayed = switch (result.get("replayed") orelse return .malformed) {
        .bool => |value| value,
        else => return .malformed,
    };
    if (!replayed) return .malformed;
    const report: upgrade_wire.AttemptReport = .{
        .status = std.meta.stringToEnum(upgrade_wire.AttemptStatus, state) orelse return .malformed,
        .reason = std.meta.stringToEnum(upgrade_wire.AttemptReason, reason_raw) orelse return .malformed,
    };
    if (!upgrade_wire.validReport(report) or report.status == .pending) return .malformed;
    return .{ .completed = report };
}

fn parseAttemptStatus(payload: []const u8) ?upgrade_wire.AttemptReport {
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, payload, .{}) catch return null;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |value| value,
        else => return null,
    };
    const result = switch (root.get("result") orelse return null) {
        .object => |value| value,
        else => return null,
    };
    const state_raw = switch (result.get("state") orelse return null) {
        .string => |value| value,
        else => return null,
    };
    const reason_raw = switch (result.get("reason") orelse return null) {
        .string => |value| value,
        else => return null,
    };
    const report: upgrade_wire.AttemptReport = .{
        .status = std.meta.stringToEnum(upgrade_wire.AttemptStatus, state_raw) orelse return null,
        .reason = std.meta.stringToEnum(upgrade_wire.AttemptReason, reason_raw) orelse return null,
    };
    return if (upgrade_wire.validReport(report)) report else null;
}

fn responseHasTypedError(payload: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, payload, .{}) catch return false;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |value| value,
        else => return false,
    };
    return responseObjectHasTypedError(root);
}

fn responseObjectHasTypedError(root: std.json.ObjectMap) bool {
    const code = switch (root.get("error") orelse return false) {
        .string => |value| value,
        else => return false,
    };
    return protocol.ErrorCode.fromWireName(code) != null;
}

/// hello/hello_ack의 capability 문자열 배열을 관대하게 읽는다. 구 peer의 필드 부재·손상·타입 불일치는 미지원(false)이며
/// handshake 자체는 기존대로 host_id/version만으로 성립한다.
fn payloadHasCapability(payload: []const u8, wanted: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, payload, .{}) catch return false;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return false,
    };
    const capabilities = switch (obj.get("capabilities") orelse return false) {
        .array => |a| a.items,
        else => return false,
    };
    for (capabilities) |value| {
        const capability = switch (value) {
            .string => |s| s,
            else => continue,
        };
        if (std.mem.eql(u8, capability, wanted)) return true;
    }
    return false;
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
    try testing.expect(std.mem.indexOf(u8, hello, "\"runtime_ended_v1\"") != null);
    try testing.expect(std.mem.indexOf(u8, hello, "\"screen_viewport_scrolled_v1\"") != null);
    try testing.expect(std.mem.indexOf(u8, hello, "\"async_scroll_to_bottom_v1\"") != null);
    try testing.expect(std.mem.indexOf(u8, hello, "\"runtime_core_command_v1\"") != null);
    try testing.expect(std.mem.indexOf(u8, hello, "\"runtime_selected_text_v1\"") != null);

    const req = try buildRequest(allocator, "runtime.get", "{\"runtime_id\":\"aa\"}");
    defer allocator.free(req);
    try testing.expect(std.mem.indexOf(u8, req, "\"method\":\"runtime.get\"") != null);
    try testing.expect(std.mem.indexOf(u8, req, "\"runtime_id\":\"aa\"") != null);

    const req2 = try buildRequest(allocator, "host.info", null);
    defer allocator.free(req2);
    try testing.expectEqualStrings("{\"method\":\"host.info\"}", req2);

    try testing.expectEqual(@as(?u128, 0x1234), parseHostId("{\"host_id\":\"1234\"}"));
    try testing.expectEqual(@as(?u16, 1), parseSelectedVersion("{\"version\":1}"));
    try testing.expectEqual(@as(?u16, null), parseSelectedVersion("{\"protocol\":1}"));
    try testing.expectEqual(@as(?u128, null), parseHostId("{\"no_host\":true}"));
    try testing.expectEqual(@as(?u128, null), parseHostId("not json"));
    try testing.expect(payloadHasCapability(
        "{\"host_id\":\"1234\",\"capabilities\":[\"screen_viewport_scrolled_v1\"]}",
        "screen_viewport_scrolled_v1",
    ));
    // 구 hello_ack에는 capabilities 자체가 없다. handshake 호환성을 유지하되 새 mode bit 신뢰 여부는 false다.
    var legacy_client = Client{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0x1234,
        .parser = framing.FrameParser.init(allocator),
    };
    defer legacy_client.deinit();
    try testing.expect(!legacy_client.screen_viewport_scrolled_v1);
    try testing.expect(!legacy_client.runtime_selected_text_v1);
    try testing.expect(!legacy_client.notification_stream_auth_v1);
    legacy_client.screen_viewport_scrolled_v1 = payloadHasCapability(
        "{\"host_id\":\"1234\"}",
        "screen_viewport_scrolled_v1",
    );
    try testing.expect(!legacy_client.screen_viewport_scrolled_v1);
    legacy_client.runtime_selected_text_v1 = payloadHasCapability(
        "{\"host_id\":\"1234\"}",
        "runtime_selected_text_v1",
    );
    try testing.expect(!legacy_client.runtime_selected_text_v1);
    legacy_client.notification_stream_auth_v1 = payloadHasCapability(
        "{\"host_id\":\"1234\",\"capabilities\":[\"notification_stream_auth_v1\"]}",
        "notification_stream_auth_v1",
    );
    try testing.expect(legacy_client.notification_stream_auth_v1);
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
    try testing.expect(client.screen_viewport_scrolled_v1);
    try testing.expect(client.async_scroll_to_bottom_v1);
    try testing.expect(client.runtime_core_command_v1);
    try testing.expect(client.runtime_selected_text_v1);
    try testing.expect(client.notification_stream_auth_v1);
    const resp = try client.call("host.info", null);
    defer allocator.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "runtime_count") != null);
    // host.info 응답의 host_id(result에 중첩)도 hello_ack와 같은 host를 가리킨다 — hex로 대조(nested 파싱 없이).
    var host_hex_buf: [40]u8 = undefined;
    const host_hex = std.fmt.bufPrint(&host_hex_buf, "{x:0>32}", .{client.host_id}) catch unreachable;
    try testing.expect(std.mem.indexOf(u8, resp, host_hex) != null);
}

test "client: forked daemon serves ephemeral inventory while canonical GUI stays connected" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const discovery_mod = @import("discovery.zig");
    const short_endpoint_mod = @import("short_endpoint.zig");
    const host_manifest_mod = @import("host_manifest.zig");
    var base_buf: [128]u8 = undefined;
    const base = std.fmt.bufPrintZ(&base_buf, "/tmp/maru-sh-multifd-{d}", .{c.getpid()}) catch
        return error.SkipZigTest;
    _ = c.mkdir(base.ptr, 0o700);
    var dir_buf: [256]u8 = undefined;
    const dir_path = discovery_mod.sessionHostDirPath(&dir_buf, base) catch return error.SkipZigTest;
    _ = c.mkdir(dir_path.ptr, 0o700);
    const host_id: u128 = (@as(u128, @intCast(c.getpid())) << 64) | 0x4D554C54494644;
    try short_endpoint_mod.prepareCurrentUserNamespace();
    var sp_buf: [128]u8 = undefined;
    const socket_path = try short_endpoint_mod.currentSocketPathIn(&sp_buf, host_id);

    const child = c.fork();
    if (child < 0) return error.SkipZigTest;
    if (child == 0) {
        _ = c.setsid();
        // Match a detached product host's inherited-fd baseline. Otherwise the Zig test runner's
        // protocol/cache descriptors correctly make the upgrade coordinator fail closed before
        // exec, which would test rollback rather than the intended same-PID success path.
        var inherited_fd: c_int = 3;
        while (inherited_fd < getdtablesize()) : (inherited_fd += 1)
            _ = c.close(inherited_fd);
        daemon.runSessionHostWithIdentityTestAuthorizer(
            std.heap.page_allocator,
            testing.io,
            dir_path,
            socket_path,
            host_id,
        ) catch {};
        std.c._exit(0);
    }
    defer {
        _ = c.kill(child, posix.SIG.TERM);
        var status: c_int = undefined;
        _ = c.waitpid(child, &status, 0);
        _ = c.unlink(socket_path.ptr);
        var manifest_buf: [832]u8 = undefined;
        if (host_manifest_mod.manifestPathIn(&manifest_buf, dir_path, host_id)) |path|
            _ = c.unlink(path.ptr)
        else |_| {}
        var owner_buf: [832]u8 = undefined;
        if (host_manifest_mod.ownerLockPathIn(&owner_buf, dir_path, host_id)) |path|
            _ = c.unlink(path.ptr)
        else |_| {}
        var host_dir_buf: [768]u8 = undefined;
        if (host_manifest_mod.hostDirPathIn(&host_dir_buf, dir_path, host_id)) |path|
            _ = c.rmdir(path.ptr)
        else |_| {}
        var hosts_buf: [640]u8 = undefined;
        if (host_manifest_mod.hostsRootPathIn(&hosts_buf, dir_path)) |path|
            _ = c.rmdir(path.ptr)
        else |_| {}
        _ = c.rmdir(dir_path.ptr);
        _ = c.rmdir(base.ptr);
    }

    var gui: Client = blk: {
        var attempts: usize = 0;
        while (attempts < 150) : (attempts += 1) {
            if (Client.connect(allocator, socket_path, "gui")) |connected|
                break :blk connected
            else |_|
                _ = usleepMs(20);
        }
        return error.TestUnexpectedResult;
    };
    defer gui.deinit();
    try testing.expect(gui.runtime_inventory_v1);
    try testing.expectEqual(child, try testPeerPid(gui.fd));

    var ephemeral = try Client.connect(allocator, socket_path, "cli");
    const inventory = try ephemeral.call(
        "runtime.inventory",
        "{\"cursor\":\"\",\"limit\":256,\"membership_generation\":0}",
    );
    defer allocator.free(inventory);
    try testing.expect(std.mem.indexOf(u8, inventory, "\"runtime_ids\":[]") != null);
    ephemeral.deinit();

    const still_live = try gui.call("host.info", null);
    defer allocator.free(still_live);
    try testing.expect(std.mem.indexOf(u8, still_live, "\"runtime_count\":0") != null);

    try testing.expect(gui.host_exec_upgrade_v1);
    const product_raw = c.getenv("MARU_SESSION_HOST_PRODUCT_EXE") orelse
        return error.SkipZigTest;
    const product_path = try std.Io.Dir.cwd().realPathFileAlloc(
        testing.io,
        std.mem.span(product_raw),
        allocator,
    );
    defer allocator.free(product_path);
    const product_z = try allocator.dupeZ(u8, product_path);
    defer allocator.free(product_z);
    const target_identity = try @import("staged_image.zig").inspect(product_z);
    const target_build_id = try host_manifest_mod.buildIdForExecutable(allocator, product_z);
    defer allocator.free(target_build_id);
    const prior_epoch = gui.upgrade_epoch;
    const upgrade_result = try gui.prepareUpgrade(.{
        .attempt_id = (@as(u128, @intCast(c.getpid())) << 64) | 0x55504752414445,
        .target_path = product_path,
        .target_build_id = target_build_id,
        .target_sha256 = target_identity.sha256,
        .handoff_reader_min = 1,
        .handoff_reader_max = 1,
    });
    switch (upgrade_result) {
        .accepted_reconnect_required => {},
        else => return error.TestUnexpectedResult,
    }

    var restored: Client = blk: {
        var attempts: usize = 0;
        while (attempts < 250) : (attempts += 1) {
            if (Client.connect(allocator, socket_path, "gui")) |connected|
                break :blk connected
            else |_|
                _ = usleepMs(20);
        }
        return error.TestUnexpectedResult;
    };
    defer restored.deinit();
    try testing.expectEqual(host_id, restored.host_id);
    try testing.expect(restored.upgrade_epoch > prior_epoch);
    try testing.expectEqual(child, try testPeerPid(restored.fd));
    const restored_info = try restored.call("host.info", null);
    defer allocator.free(restored_info);
    try testing.expect(std.mem.indexOf(u8, restored_info, "\"runtime_count\":0") != null);
    try testing.expectEqual(@as(c_int, 0), c.kill(child, @enumFromInt(0)));
}

extern "c" fn usleep(usec: c_uint) c_int;
extern "c" fn getdtablesize() c_int;

fn testPeerPid(fd: c.fd_t) !c.pid_t {
    const sol_local: c_int = 0;
    const local_peerpid: c_int = 0x002;
    var pid: c.pid_t = 0;
    var len: c.socklen_t = @sizeOf(c.pid_t);
    if (c.getsockopt(fd, sol_local, local_peerpid, &pid, &len) != 0 or
        len != @sizeOf(c.pid_t) or pid <= 0)
        return error.TestUnexpectedResult;
    return pid;
}
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
    if (parseExactInventoryId(&out) == null) return null;
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

test "client: sibling attachment converges after explicit terminate and natural exit" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var dir_buf: [256]u8 = undefined;
    const dir_path = std.fmt.bufPrintZ(
        &dir_buf,
        "/tmp/maru-sh-converge-{d}",
        .{c.getpid()},
    ) catch return error.SkipZigTest;
    var sp_buf: [320]u8 = undefined;
    const socket_path = std.fmt.bufPrintZ(
        &sp_buf,
        "{s}/control.sock",
        .{dir_path},
    ) catch return error.SkipZigTest;

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

    var first: Client = blk: {
        var attempts: usize = 0;
        while (attempts < 150) : (attempts += 1) {
            if (Client.connect(allocator, socket_path, "gui")) |connected|
                break :blk connected
            else |_|
                _ = usleepMs(20);
        }
        return error.TestUnexpectedResult;
    };
    defer first.deinit();
    var sibling = try Client.connect(allocator, socket_path, "gui");
    defer sibling.deinit();

    const spawn_resp = try first.call(
        "runtime.spawn",
        "{\"argv\":[\"/bin/cat\"],\"cols\":40,\"rows\":10}",
    );
    defer allocator.free(spawn_resp);
    const rid = extractRuntimeId(spawn_resp) orelse return error.TestUnexpectedResult;
    var first_attach_buf: [96]u8 = undefined;
    const first_attach_params = std.fmt.bufPrint(
        &first_attach_buf,
        "{{\"runtime_id\":\"{s}\",\"mode\":\"controller\"}}",
        .{rid},
    ) catch return error.SkipZigTest;
    const first_attach = try first.call("runtime.attach", first_attach_params);
    defer allocator.free(first_attach);
    const first_stream = extractU64Field(first_attach, "\"stream_id\":") orelse
        return error.TestUnexpectedResult;
    const first_initial = try first.readSnapshot(first_stream);
    allocator.free(first_initial);
    var attach_buf: [96]u8 = undefined;
    const attach_params = std.fmt.bufPrint(
        &attach_buf,
        "{{\"runtime_id\":\"{s}\",\"mode\":\"observer\"}}",
        .{rid},
    ) catch return error.SkipZigTest;
    const attach_resp = try sibling.call("runtime.attach", attach_params);
    defer allocator.free(attach_resp);
    const sibling_stream = extractU64Field(attach_resp, "\"stream_id\":") orelse
        return error.TestUnexpectedResult;
    const initial = try sibling.readSnapshot(sibling_stream);
    allocator.free(initial);

    var term_buf: [64]u8 = undefined;
    const term_params = std.fmt.bufPrint(
        &term_buf,
        "{{\"runtime_id\":\"{s}\"}}",
        .{rid},
    ) catch return error.SkipZigTest;
    const term_resp = try first.call("runtime.terminate", term_params);
    defer allocator.free(term_resp);
    try testing.expect(std.mem.indexOf(u8, term_resp, "terminated") != null);
    _ = usleepMs(100);
    const still_live = try sibling.call("host.info", null);
    defer allocator.free(still_live);
    try testing.expect(std.mem.indexOf(u8, still_live, "\"runtime_count\":0") != null);
    const ended_event = sibling.takeEventForStream(sibling_stream) orelse
        return error.TestUnexpectedResult;
    defer ended_event.deinit(allocator);
    try testing.expectEqualStrings("{\"event\":\"runtime.ended\"}", ended_event.payload);
    const terminator_live = try first.call("host.info", null);
    defer allocator.free(terminator_live);
    const first_ended = first.takeEventForStream(first_stream) orelse
        return error.TestUnexpectedResult;
    defer first_ended.deinit(allocator);
    try testing.expectEqualStrings("{\"event\":\"runtime.ended\"}", first_ended.payload);
    var detach_buf: [48]u8 = undefined;
    const detach_params = std.fmt.bufPrint(
        &detach_buf,
        "{{\"stream_id\":{d}}}",
        .{sibling_stream},
    ) catch return error.SkipZigTest;
    const stale_detach = try sibling.call("runtime.detach", detach_params);
    defer allocator.free(stale_detach);
    try testing.expect(std.mem.indexOf(u8, stale_detach, "invalid_request") != null);

    const natural_resp = try first.call(
        "runtime.spawn",
        "{\"argv\":[\"/bin/sh\",\"-c\",\"sleep 0.2\"],\"cols\":40,\"rows\":10}",
    );
    defer allocator.free(natural_resp);
    const natural_rid = extractRuntimeId(natural_resp) orelse return error.TestUnexpectedResult;
    var natural_attach_buf: [96]u8 = undefined;
    const natural_attach_params = std.fmt.bufPrint(
        &natural_attach_buf,
        "{{\"runtime_id\":\"{s}\",\"mode\":\"observer\"}}",
        .{natural_rid},
    ) catch return error.SkipZigTest;
    const natural_attach = try sibling.call("runtime.attach", natural_attach_params);
    defer allocator.free(natural_attach);
    const natural_stream = extractU64Field(natural_attach, "\"stream_id\":") orelse
        return error.TestUnexpectedResult;
    const natural_initial = try sibling.readSnapshot(natural_stream);
    allocator.free(natural_initial);
    _ = usleepMs(400);
    const after_exit = try sibling.call("host.info", null);
    defer allocator.free(after_exit);
    try testing.expect(std.mem.indexOf(u8, after_exit, "\"runtime_count\":0") != null);
    const natural_ended = sibling.takeEventForStream(natural_stream) orelse
        return error.TestUnexpectedResult;
    defer natural_ended.deinit(allocator);
    try testing.expectEqualStrings("{\"event\":\"runtime.ended\"}", natural_ended.payload);
    var natural_detach_buf: [48]u8 = undefined;
    const natural_detach_params = std.fmt.bufPrint(
        &natural_detach_buf,
        "{{\"stream_id\":{d}}}",
        .{natural_stream},
    ) catch return error.SkipZigTest;
    const natural_stale = try sibling.call("runtime.detach", natural_detach_params);
    defer allocator.free(natural_stale);
    try testing.expect(std.mem.indexOf(u8, natural_stale, "invalid_request") != null);
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
