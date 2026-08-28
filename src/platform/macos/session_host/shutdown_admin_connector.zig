//! 앱 종료가 고른 exact current manifest에 one-shot admin 연결을 여는 제품 경계다.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;
const client_mod = @import("client.zig");
const client_deadline = @import("client_deadline.zig");
const compatibility = @import("compatibility.zig");
const daemon = @import("daemon.zig");
const discovery = @import("discovery.zig");
const framing = @import("framing.zig");
const host_manifest = @import("host_manifest.zig");
const launcher = @import("launcher.zig");
const protocol = @import("protocol.zig");
const process_seal = @import("process_seal_service.zig");
const remote_runtime = @import("remote_runtime.zig");
const screen_stream = @import("maru").session.screen_stream;
const shutdown_attempt = @import("shutdown_attempt_authority.zig");
const shutdown_n1_baseline = @import("shutdown_n1_baseline.zig");
const shutdown_wire = @import("maru").app.shutdown_wire_contract;
const short_endpoint = @import("short_endpoint.zig");
const socket_server = @import("socket_server.zig");
const staged_image = @import("staged_image.zig");
extern "c" fn usleep(usec: c_uint) c_int;

pub const Unavailable = enum {
    invalid_manifest,
    endpoint_absent,
    denied,
    unsupported,
    busy,
    transient,
    protocol_error,
    out_of_memory,
    deadline,
};

pub const Outcome = union(enum) {
    connected: client_mod.Client,
    unavailable: Unavailable,
};

pub const PreviousTerminateResult = enum {
    confirmed,
    not_executed,
    sent_ambiguous,
};

threadlocal var reject_previous_response_publication = false;

/// 종료 transaction이 이미 봉인한 manifest만 받는다. 여기서 discovery를 다시 하면 같은 attempt가 다른 host를
/// 고를 수 있으므로 endpoint 연결과 hello identity 재검증 외의 target 선택은 하지 않는다.
pub fn connectExactCurrent(
    allocator: std.mem.Allocator,
    exact: host_manifest.Descriptor,
) Outcome {
    if (!eligibleCurrent(exact)) return .{ .unavailable = .invalid_manifest };
    const endpoint = allocator.dupeZ(u8, exact.endpoint) catch
        return .{ .unavailable = .out_of_memory };
    defer allocator.free(endpoint);

    var client = client_mod.Client.connectAdmin(allocator, endpoint) catch |err|
        return .{ .unavailable = unavailableFor(err) };
    errdefer client.deinit();
    client.requireAdminRuntimeEnd() catch |err|
        return .{ .unavailable = unavailableFor(err) };
    if (!clientMatchesManifest(&client, exact))
        return .{ .unavailable = .protocol_error };
    return .{ .connected = client };
}

pub fn connectExactCurrentUntil(
    allocator: std.mem.Allocator,
    exact: host_manifest.Descriptor,
    deadline: client_deadline.AbsoluteDeadline,
) Outcome {
    if (!eligibleCurrent(exact)) return .{ .unavailable = .invalid_manifest };
    const endpoint = allocator.dupeZ(u8, exact.endpoint) catch
        return .{ .unavailable = .out_of_memory };
    defer allocator.free(endpoint);
    var client = client_mod.Client.connectAdminUntil(allocator, endpoint, deadline) catch |err|
        return .{ .unavailable = unavailableFor(err) };
    errdefer client.deinit();
    client.requireAdminRuntimeEnd() catch |err|
        return .{ .unavailable = unavailableFor(err) };
    if (!clientMatchesManifest(&client, exact))
        return .{ .unavailable = .protocol_error };
    return .{ .connected = client };
}

/// frozen N-1의 exact artifact manifest를 먼저 검증한 뒤 attachment-free GUI maintenance 연결을 연다.
/// 구 hello에 screen fingerprint가 없더라도 일반 attach로 승격하지 않고 list/terminate RPC에만 소비한다.
fn connectExactPreviousUntil(
    allocator: std.mem.Allocator,
    exact: host_manifest.Descriptor,
    deadline: client_deadline.AbsoluteDeadline,
) Outcome {
    const profile = compatibility.profileForMajor(@intCast(exact.protocol_major)) orelse
        return .{ .unavailable = .invalid_manifest };
    const shutdown = profile.shutdown_profile orelse
        return .{ .unavailable = .invalid_manifest };
    if (!eligiblePrevious(exact, profile, shutdown))
        return .{ .unavailable = .invalid_manifest };
    const endpoint = allocator.dupeZ(u8, exact.endpoint) catch
        return .{ .unavailable = .out_of_memory };
    defer allocator.free(endpoint);
    var client = client_mod.Client.connectFrozenShutdownUntil(
        allocator,
        endpoint,
        @intCast(exact.protocol_major),
        shutdown.artifact_sha256,
        deadline,
    ) catch |err| return .{ .unavailable = unavailableFor(err) };
    errdefer client.deinit();
    if (client.host_id != exact.host_id or client.wire_major != exact.protocol_major or
        client.screen_codec_version != exact.screen_codec_version)
        return .{ .unavailable = .protocol_error };
    return .{ .connected = client };
}

pub fn exactPreviousManifestEligible(exact: host_manifest.Descriptor) bool {
    const profile = compatibility.profileForMajor(@intCast(exact.protocol_major)) orelse return false;
    const shutdown = profile.shutdown_profile orelse return false;
    return eligiblePrevious(exact, profile, shutdown);
}

/// N-1 destructive request는 exact connection 하나에서 한 번만 전송한다. 응답 publication 이후 proof를 잃으면
/// inventory나 두 번째 terminate로 추측하지 않고 terminal ambiguous로 닫는다.
pub fn terminateExactPreviousUntil(
    allocator: std.mem.Allocator,
    authority: *shutdown_attempt.ShutdownAttemptAuthority,
    exact: host_manifest.Descriptor,
    runtime_id: []const u8,
    now_ns: u64,
    connection_identity: u64,
    deadline: client_deadline.AbsoluteDeadline,
) PreviousTerminateResult {
    var client = switch (connectExactPreviousUntil(allocator, exact, deadline)) {
        .connected => |value| value,
        .unavailable => return .not_executed,
    };
    defer client.deinit();
    var params_buf: [64]u8 = undefined;
    const params = std.fmt.bufPrint(&params_buf, "{{\"runtime_id\":\"{s}\"}}", .{runtime_id}) catch
        return .not_executed;
    var storage: client_mod.PreparedBlockingRpcStorage = .{};
    _ = client.prepareBlockingRpcStorage(&storage, "runtime.terminate", params) catch
        return .not_executed;
    var receipt: shutdown_wire.ShutdownConnectionReceipt = .{};
    shutdown_attempt.issueConnection(
        authority,
        &receipt,
        now_ns,
        connection_identity,
        .terminate,
        .none,
        shutdown_n1_baseline.terminate_semantics_sha256,
    ) catch {
        client.abortPreparedBlockingRpcStorage(&storage) catch {};
        return .not_executed;
    };

    if (builtin.is_test and reject_previous_response_publication) {
        reject_previous_response_publication = false;
        var rejector: RejectPreviousResponse = .{};
        return finishPreviousExecution(
            &client,
            authority,
            &receipt,
            &storage,
            client.executePreparedBlockingRpcStorageWithAllocatorObserved(
                &storage,
                allocator,
                rejector.observer(),
            ),
        );
    }
    return finishPreviousDeadlineExecution(
        &client,
        authority,
        &receipt,
        &storage,
        client.executePreparedBlockingRpcStorageUntil(&storage, allocator, deadline),
    );
}

fn finishPreviousDeadlineExecution(
    client: *client_mod.Client,
    authority: *shutdown_attempt.ShutdownAttemptAuthority,
    receipt: *shutdown_wire.ShutdownConnectionReceipt,
    storage: *client_mod.PreparedBlockingRpcStorage,
    execution: anytype,
) PreviousTerminateResult {
    return switch (execution) {
        .accepted => |accepted| blk: {
            defer accepted.payload_allocator.free(accepted.payload);
            const confirmed = std.mem.indexOf(u8, accepted.payload, "\"terminated\":true") != null;
            shutdown_attempt.consumeConnection(authority, receipt, true) catch
                process_seal.fatalIntegrity(.proof_loss);
            break :blk if (confirmed) .confirmed else .sent_ambiguous;
        },
        .not_executed => {
            client.abortPreparedBlockingRpcStorage(storage) catch
                process_seal.fatalIntegrity(.proof_loss);
            shutdown_attempt.consumeConnection(authority, receipt, false) catch
                process_seal.fatalIntegrity(.proof_loss);
            return .not_executed;
        },
        .uncertain => {
            shutdown_attempt.consumeConnection(authority, receipt, true) catch
                process_seal.fatalIntegrity(.proof_loss);
            return .sent_ambiguous;
        },
    };
}

fn finishPreviousExecution(
    client: *client_mod.Client,
    authority: *shutdown_attempt.ShutdownAttemptAuthority,
    receipt: *shutdown_wire.ShutdownConnectionReceipt,
    storage: *client_mod.PreparedBlockingRpcStorage,
    execution: anytype,
) PreviousTerminateResult {
    return switch (execution) {
        .accepted => |accepted| blk: {
            defer accepted.payload_allocator.free(accepted.payload);
            const confirmed = std.mem.indexOf(u8, accepted.payload, "\"terminated\":true") != null;
            shutdown_attempt.consumeConnection(authority, receipt, true) catch
                process_seal.fatalIntegrity(.proof_loss);
            break :blk if (confirmed) .confirmed else .sent_ambiguous;
        },
        .not_executed => {
            client.abortPreparedBlockingRpcStorage(storage) catch
                process_seal.fatalIntegrity(.proof_loss);
            shutdown_attempt.consumeConnection(authority, receipt, false) catch
                process_seal.fatalIntegrity(.proof_loss);
            return .not_executed;
        },
        .uncertain => {
            shutdown_attempt.consumeConnection(authority, receipt, true) catch
                process_seal.fatalIntegrity(.proof_loss);
            return .sent_ambiguous;
        },
    };
}

const RejectPreviousResponse = struct {
    fn observer(self: *RejectPreviousResponse) framing.PayloadAllocationObserver {
        return .{ .context = self, .reserve_fn = reserve, .commit_fn = commit, .abort_fn = abort, .discard_fn = discard };
    }

    fn reserve(_: *anyopaque, _: usize, _: std.mem.Allocator) error{ OutOfMemory, IdentityExhausted, ProtocolError }!u64 {
        return 1;
    }
    fn commit(_: *anyopaque, _: u64, _: []u8, _: std.mem.Allocator) error{ProtocolError}!void {
        return error.ProtocolError;
    }
    fn abort(_: *anyopaque, _: u64) void {}
    fn discard(_: *anyopaque, _: u64) void {}
};

pub const testing = if (builtin.is_test) struct {
    pub fn rejectNextPreviousResponsePublication() void {
        std.debug.assert(!reject_previous_response_publication);
        reject_previous_response_publication = true;
    }
} else struct {};

fn eligibleCurrent(exact: host_manifest.Descriptor) bool {
    return exact.lifecycle == .ready and
        exact.protocol_major == protocol.version_major and
        exact.screen_codec_version == screen_stream.codec_version and
        exact.host_id != 0 and
        exact.endpoint.len != 0 and
        exact.build_id.len != 0;
}

fn eligiblePrevious(
    exact: host_manifest.Descriptor,
    profile: compatibility.Profile,
    shutdown: compatibility.ShutdownProfile,
) bool {
    return profile.kind == .previous and shutdown.complete() and
        exact.lifecycle == .ready and exact.protocol_major == shutdown.wire_major and
        exact.screen_codec_version == profile.screen_codec_version and exact.host_id != 0 and
        exact.endpoint.len != 0 and buildIdMatchesDigest(exact.build_id, shutdown.artifact_sha256);
}

fn buildIdMatchesDigest(build_id: []const u8, digest: [32]u8) bool {
    if (!std.mem.startsWith(u8, build_id, "sha256:") or build_id.len != "sha256:".len + 64)
        return false;
    const expected = std.fmt.bytesToHex(digest, .lower);
    return std.mem.eql(u8, build_id["sha256:".len..], &expected);
}

fn clientMatchesManifest(client: *const client_mod.Client, exact: host_manifest.Descriptor) bool {
    return client.host_id == exact.host_id and
        client.wire_major == exact.protocol_major and
        client.screen_codec_version == exact.screen_codec_version and
        client.upgrade_epoch == exact.upgrade_epoch and
        client.build_id != null and
        std.mem.eql(u8, client.build_id.?, exact.build_id) and
        std.mem.eql(u8, client.lifecycle, @tagName(exact.lifecycle));
}

fn unavailableFor(err: client_mod.DeadlineClientError) Unavailable {
    return switch (err) {
        error.EndpointAbsent => .endpoint_absent,
        error.EndpointDenied, error.Unauthorized => .denied,
        error.EndpointTransient, error.ConnectionClosed => .transient,
        error.IncompatibleVersion => .unsupported,
        error.AdminBusy => .busy,
        error.OutOfMemory => .out_of_memory,
        error.DeadlineExceeded => .deadline,
        else => .protocol_error,
    };
}

fn fixture() host_manifest.Descriptor {
    return .{
        .host_id = 1,
        .build_id = "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        .protocol_major = protocol.version_major,
        .screen_codec_version = screen_stream.codec_version,
        .upgrade_epoch = 1,
        .lifecycle = .ready,
        .endpoint = "/tmp/maru-shutdown-connector-missing.sock",
    };
}

test "C3-3b6 current admin connector는 exact current ready manifest만 연결 대상으로 인정한다" {
    var row = fixture();
    row.protocol_major -= 1;
    try std.testing.expectEqual(Unavailable.invalid_manifest, connectExactCurrent(std.testing.allocator, row).unavailable);
    row = fixture();
    row.lifecycle = .draining;
    try std.testing.expectEqual(Unavailable.invalid_manifest, connectExactCurrent(std.testing.allocator, row).unavailable);
}

test "C3-3b6 current admin connector는 exact endpoint 부재를 다른 host discovery로 우회하지 않는다" {
    try std.testing.expectEqual(Unavailable.endpoint_absent, connectExactCurrent(std.testing.allocator, fixture()).unavailable);
}

test "C3-3b6 current admin connector는 공통 deadline이 끝나면 socket 연결을 시작하지 않는다" {
    const Clock = struct {
        fn now(_: *anyopaque) i128 {
            return 100;
        }
    };
    var context: u8 = 0;
    const deadline = client_deadline.AbsoluteDeadline.fromInjected(.{
        .context = &context,
        .now_ns = Clock.now,
    }, 100);
    try std.testing.expectEqual(
        Unavailable.deadline,
        connectExactCurrentUntil(std.testing.allocator, fixture(), deadline).unavailable,
    );
}

test "C3-3b6 actual socket은 current pre-write deadline 복구 뒤 terminate confirmed를 증명한다" {
    try verifyAfterWriteDeadlineClassification();
    try runActualTerminate(false);
}

test "C3-3b6 actual socket은 current ambiguous 뒤 barrier inventory를 제품 경로로 증명한다" {
    try runActualTerminate(true);
}

test "C3-3b6 실제 이전 wire 기준은 ambiguous 뒤 destructive retry를 하지 않는다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    try shutdown_attempt.testing.ensureSealReady();

    const baseline = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        "tests/fixtures/session_host_n1/maru",
        allocator,
    );
    defer allocator.free(baseline);
    const baseline_z = try allocator.dupeZ(u8, baseline);
    defer allocator.free(baseline_z);
    const identity = try staged_image.inspect(baseline_z);
    try std.testing.expectEqualSlices(u8, &shutdown_n1_baseline.artifact_sha256, &identity.sha256);

    const source_patch = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "tests/fixtures/session_host_n1/source.patch",
        allocator,
        .limited(64 * 1024),
    );
    defer allocator.free(source_patch);
    var source_patch_digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(source_patch, &source_patch_digest, .{});
    try std.testing.expectEqualSlices(u8, &shutdown_n1_baseline.source_patch_sha256, &source_patch_digest);

    var base_buf: [192]u8 = undefined;
    const base = try std.fmt.bufPrintZ(&base_buf, "/tmp/maru-c3b6-n1-{d}", .{c.getpid()});
    std.Io.Dir.cwd().deleteTree(std.testing.io, base) catch {};
    _ = c.mkdir(base.ptr, 0o700);
    var session_buf: [256]u8 = undefined;
    const session_dir = try discovery.sessionHostDirPath(&session_buf, base);
    _ = c.mkdir(session_dir.ptr, 0o700);
    const host_id = (@as(u128, @intCast(c.getpid())) << 64) | 0xC3B6_0001;
    // **이 테스트만 uid 기준 공용 socket 을 쓴다.** 전역 환경(`MARU_SESSION_HOST_ROOT`)은 건드리지 않는다.
    //
    // N-1 baseline 은 저장소에 커밋된 고정 이미지(sha256 고정)라 registry 격리 코드가 없고, 그 daemon 은
    // socket 을 `socketDirPathIn(uid)` 기준으로 bind 검증한다. 격리 root 아래 socket 을 넘기면 bind 가
    // 거부되어 host 자체가 뜨지 않는다 — 환경을 어떻게 맞춰도 그 바이너리의 uid 기준은 바뀌지 않는다.
    //
    // 전역 unsetenv/setenv 로 격리를 껐다 켜는 방법은 **쓰지 않는다**. 프로세스 전역 상태라 뒤따르는
    // 테스트까지 오염시켜, 실측에서 실패가 1 개에서 7 개로 번졌다. 순수 함수로 이 한 경로만 공용을 짚는다.
    // 아래 `defer` 가 socket 을 지우므로 잔해는 남지 않는다.
    var pub_dir_buf: [160]u8 = undefined;
    const pub_dir = try short_endpoint.socketDirPathIn(&pub_dir_buf, c.getuid());
    _ = c.mkdir(pub_dir.ptr, 0o700);
    var socket_buf: [160]u8 = undefined;
    const socket_path = try short_endpoint.socketPathIn(&socket_buf, c.getuid(), host_id);
    const child = try launcher.spawnSessionHostSupervisedForTest(
        allocator,
        baseline_z,
        session_dir,
        socket_path,
        host_id,
    );
    defer {
        _ = c.kill(child, posix.SIG.TERM);
        var status: c_int = 0;
        while (true) {
            const waited = c.waitpid(child, &status, 0);
            if (waited == child) break;
            if (waited < 0 and posix.errno(waited) == .INTR) continue;
            break;
        }
        _ = c.unlink(socket_path.ptr);
        host_manifest.removeEmptyHostDirectories(session_dir, host_id);
        std.Io.Dir.cwd().deleteTree(std.testing.io, base) catch {};
    }

    var manifest = try waitForN1Manifest(allocator, session_dir, host_id, socket_path);
    defer manifest.deinit();
    const descriptor = manifest.descriptor();
    try std.testing.expect(exactPreviousManifestEligible(descriptor));
    try std.testing.expectEqual(@as(u16, 1), descriptor.protocol_major);
    try std.testing.expectEqual(@as(u16, 1), descriptor.screen_codec_version);

    const deadline = try client_deadline.AbsoluteDeadline.after(std.testing.io, 5 * std.time.ns_per_s);
    var setup = switch (connectExactPreviousUntil(allocator, descriptor, deadline)) {
        .connected => |value| value,
        .unavailable => return error.TestUnexpectedResult,
    };
    const spawn = try setup.call(
        "runtime.spawn",
        "{\"argv\":[\"/bin/sh\",\"-c\",\"sleep 30\"],\"cols\":40,\"rows\":10}",
    );
    defer allocator.free(spawn);
    const runtime_id = client_mod.extractRuntimeId(spawn) orelse return error.TestUnexpectedResult;
    const list_before = try setup.call("runtime.list", null);
    defer allocator.free(list_before);
    try std.testing.expect(std.mem.indexOf(u8, list_before, &runtime_id) != null);
    setup.deinit();

    var authority: shutdown_attempt.ShutdownAttemptAuthority = .{};
    try shutdown_attempt.prepare(
        &authority,
        1,
        shutdown_n1_baseline.artifact_sha256,
        .terminate_host,
        @intCast(deadline.expires_at_ns),
    );
    testing.rejectNextPreviousResponsePublication();
    try std.testing.expectEqual(
        PreviousTerminateResult.sent_ambiguous,
        terminateExactPreviousUntil(
            allocator,
            &authority,
            descriptor,
            &runtime_id,
            @intCast(deadline.nowNs()),
            1,
            deadline,
        ),
    );
    try std.testing.expectEqual(@as(u64, 1), authority.attempt_generation);
    try std.testing.expectEqual(@as(u8, 3), authority.lifecycle_raw);

    // 새 연결은 테스트 oracle로 runtime 부재만 관측한다. 제품 경로는 ambiguous 뒤 terminate를 다시 보내지 않는다.
    var oracle = switch (connectExactPreviousUntil(allocator, descriptor, deadline)) {
        .connected => |value| value,
        .unavailable => return error.TestUnexpectedResult,
    };
    defer oracle.deinit();
    const list_after = try oracle.call("runtime.list", null);
    defer allocator.free(list_after);
    try std.testing.expect(std.mem.indexOf(u8, list_after, &runtime_id) == null);
    try std.testing.expectEqual(@as(u64, 1), authority.attempt_generation);
}

/// **`host_manifest.load` 를 쓰지 않는다.** 그 경로는 endpoint 가 *이 프로세스의* namespace 안에
/// 있는지(`validateCurrentSocketPath`) 를 함께 재는데, 여기 peer 는 그 정책보다 앞선 **동결 이미지**다
/// (2026-08-12 커밋, `MARU_SESSION_HOST_ROOT` 문자열이 아예 없다). 그 daemon 은 socket 을 언제나
/// `/tmp/maru-<uid>/sh` 에 열고 그 경로를 manifest 에 적는데, test 빌드의 registry 는 프로세스별로
/// 격리돼 있어 둘이 영영 어긋난다 — 실제로 `load` 가 매번 `InvalidManifest` 를 돌려주어 250 회 재시도가
/// 통째로 헛돌았다(CI: observer 가 아니라 이 대기가 먼저 죽는다).
///
/// 전역 `setenv` 로 이 프로세스를 uid namespace 로 되돌리는 방법은 **쓰지 않는다** — 프로세스 전역
/// 상태라 뒤따르는 테스트까지 오염시킨다. 대신 정책 대신 **이 테스트가 daemon 에게 직접 건넨 경로**로
/// endpoint 를 고정한다. 정책보다 좁은 검사라 N-1 호환성이라는 취지도 그대로 남는다.
fn waitForN1Manifest(
    allocator: std.mem.Allocator,
    session_dir: [:0]const u8,
    host_id: u128,
    expected_endpoint: []const u8,
) !host_manifest.Manifest {
    var path_buf: [512]u8 = undefined;
    const path = host_manifest.manifestPathIn(&path_buf, session_dir, host_id) catch
        return error.TestUnexpectedResult;
    var retry: usize = 0;
    while (retry < 250) : (retry += 1) {
        // 아직 없거나 쓰는 중일 수 있다. 부분 파일은 decode 가 걸러내므로 둘 다 재시도로 접는다.
        const bytes = std.Io.Dir.cwd().readFileAlloc(
            std.testing.io,
            path,
            allocator,
            .limited(64 * 1024),
        ) catch {
            _ = usleep(20_000);
            continue;
        };
        defer allocator.free(bytes);
        var manifest = host_manifest.decode(allocator, bytes) catch {
            _ = usleep(20_000);
            continue;
        };
        errdefer manifest.deinit();
        if (manifest.host_id != host_id) return error.TestUnexpectedResult;
        if (!std.mem.eql(u8, manifest.descriptor().endpoint, expected_endpoint))
            return error.TestUnexpectedResult;
        return manifest;
    }
    return error.TestUnexpectedResult;
}

fn verifyAfterWriteDeadlineClassification() !void {
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    socket_server.setNoSigPipe(fds[0]);
    var client: client_mod.Client = .{
        .allocator = std.testing.allocator,
        .fd = fds[0],
        .host_id = 1,
        .parser = framing.FrameParser.init(std.testing.allocator),
    };
    defer client.deinit();
    var storage: client_mod.PreparedBlockingRpcStorage = .{};
    _ = try client.prepareBlockingRpcStorage(&storage, "runtime.terminate", "{\"runtime_id\":\"00000000000000000000000000000001\"}");
    var request_observed = false;
    var peer = try std.Thread.spawn(.{}, deadlineAfterWritePeer, .{ fds[1], &request_observed });
    // peer가 read 대기 상태에 들어갈 기회를 준 뒤 deadline을 시작해야 thread 생성 지연을 pre-write timeout으로
    // 오분류하지 않는다. 실제 제품 경계는 full request write 뒤 응답 부재만 uncertain으로 분류해야 한다.
    const deadline = try client_deadline.AbsoluteDeadline.after(std.testing.io, 10 * std.time.ns_per_ms);
    const execution = client.executePreparedBlockingRpcStorageUntil(&storage, std.testing.allocator, deadline);
    peer.join();
    switch (execution) {
        .uncertain => |err| try std.testing.expectEqual(error.DeadlineExceeded, err),
        .accepted, .not_executed => return error.TestUnexpectedResult,
    }
    try std.testing.expect(request_observed);
    try std.testing.expect(client_mod.Client.preparedBlockingRpcStorageSettled(&storage));
    try std.testing.expect(client.unusable and client.fd == -1);
}

fn deadlineAfterWritePeer(fd: c.fd_t, observed: *bool) void {
    defer _ = c.close(fd);
    var header_bytes: [protocol.header_size]u8 = undefined;
    readExactDeadlineFixture(fd, &header_bytes) catch return;
    const header = protocol.Header.decode(&header_bytes) catch return;
    if (header.kind != .request or header.payload_len == 0 or header.payload_len > protocol.max_control_json) return;
    var remaining: usize = header.payload_len;
    var scratch: [256]u8 = undefined;
    while (remaining != 0) {
        const take = @min(remaining, scratch.len);
        readExactDeadlineFixture(fd, scratch[0..take]) catch return;
        remaining -= take;
    }
    observed.* = true;
    // scheduler 지연이 10 ms deadline을 넘어도 peer EOF가 먼저 원인이 되지 않도록 충분히 오래 writer를 유지한다.
    _ = usleep(500_000);
}

fn readExactDeadlineFixture(fd: c.fd_t, bytes: []u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = c.read(fd, bytes.ptr + offset, bytes.len - offset);
        if (count < 0) {
            if (posix.errno(count) == .INTR) continue;
            return error.ReadFailed;
        }
        if (count == 0) return error.ReadFailed;
        offset += @intCast(count);
    }
}

fn runActualTerminate(inject_response_proof_loss: bool) !void {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var base_buf: [192]u8 = undefined;
    const base = try std.fmt.bufPrintZ(&base_buf, "/tmp/maru-c3b6-admin-{d}", .{c.getpid()});
    std.Io.Dir.cwd().deleteTree(std.testing.io, base) catch {};
    _ = c.mkdir(base.ptr, 0o700);
    var session_buf: [256]u8 = undefined;
    const session_dir = try discovery.sessionHostDirPath(&session_buf, base);
    _ = c.mkdir(session_dir.ptr, 0o700);
    const host_id = (@as(u128, @intCast(c.getpid())) << 64) | 0xC3B6;
    try short_endpoint.prepareCurrentUserNamespace();
    var socket_buf: [128]u8 = undefined;
    const socket_path = try short_endpoint.currentSocketPathIn(&socket_buf, host_id);
    const child = c.fork();
    if (child < 0) return error.SkipZigTest;
    if (child == 0) {
        daemon.runSessionHostWithIdentity(
            std.heap.page_allocator,
            std.testing.io,
            session_dir,
            socket_path,
            host_id,
        ) catch {};
        std.c._exit(0);
    }
    defer {
        _ = c.kill(child, posix.SIG.TERM);
        var status: c_int = 0;
        while (true) {
            const waited = c.waitpid(child, &status, 0);
            if (waited == child) break;
            if (waited < 0 and posix.errno(waited) == .INTR) continue;
            break;
        }
        _ = c.unlink(socket_path.ptr);
        host_manifest.removeEmptyHostDirectories(session_dir, host_id);
        std.Io.Dir.cwd().deleteTree(std.testing.io, base) catch {};
    }

    var gui: client_mod.Client = blk: {
        var retry: usize = 0;
        while (retry < 150) : (retry += 1) {
            if (client_mod.Client.connect(allocator, socket_path, .gui)) |value| break :blk value else |_| {
                _ = usleep(20_000);
            }
        }
        return error.TestUnexpectedResult;
    };
    defer gui.deinit();
    const spawn = try gui.call("runtime.spawn", "{\"argv\":[\"/bin/sh\",\"-c\",\"sleep 30\"],\"cols\":40,\"rows\":10}");
    defer allocator.free(spawn);
    const runtime_id = client_mod.extractRuntimeId(spawn) orelse return error.TestUnexpectedResult;
    var manifest = try host_manifest.load(allocator, session_dir, host_id);
    defer manifest.deinit();
    var admin = switch (connectExactCurrent(allocator, manifest.descriptor())) {
        .connected => |value| value,
        .unavailable => return error.TestUnexpectedResult,
    };
    var admin_live = true;
    defer if (admin_live) admin.deinit();

    if (!inject_response_proof_loss) {
        const Clock = struct {
            fn now(_: *anyopaque) i128 {
                return 100;
            }
        };
        var clock_context: u8 = 0;
        const expired = client_deadline.AbsoluteDeadline.fromInjected(.{
            .context = &clock_context,
            .now_ns = Clock.now,
        }, 100);
        const flags_before = c.fcntl(admin.fd, c.F.GETFL, @as(c_int, 0));
        if (flags_before < 0) return error.TestUnexpectedResult;
        switch (admin.runtimeInventoryUntil(expired)) {
            .not_executed => |err| try std.testing.expectEqual(error.DeadlineExceeded, err),
            .inventory, .uncertain => return error.TestUnexpectedResult,
        }
        try std.testing.expectEqual(flags_before, c.fcntl(admin.fd, c.F.GETFL, @as(c_int, 0)));
        try std.testing.expect(admin.fd >= 0 and !admin.unusable);
    }

    var params_buf: [64]u8 = undefined;
    const params = try std.fmt.bufPrint(&params_buf, "{{\"runtime_id\":\"{s}\"}}", .{&runtime_id});
    var storage: client_mod.PreparedBlockingRpcStorage = .{};
    _ = try admin.prepareBlockingRpcStorage(&storage, "runtime.terminate", params);
    if (!inject_response_proof_loss) {
        const execution = admin.executePreparedBlockingRpcStorageWithAllocator(&storage, allocator);
        const accepted = switch (execution) {
            .accepted => |value| value,
            .not_executed, .uncertain => return error.TestUnexpectedResult,
        };
        defer accepted.payload_allocator.free(accepted.payload);
        try std.testing.expect(std.mem.indexOf(u8, accepted.payload, "\"terminated\":true") != null);
    } else {
        var rejector: RejectResponsePublication = .{};
        const execution = admin.executePreparedBlockingRpcStorageWithAllocatorObserved(
            &storage,
            allocator,
            rejector.observer(),
        );
        switch (execution) {
            .uncertain => {},
            .accepted, .not_executed => return error.TestUnexpectedResult,
        }
        try std.testing.expectEqual(@as(u8, 1), rejector.reserve_count);
        try std.testing.expectEqual(@as(u8, 1), rejector.commit_count);

        // 첫 connection을 canonical deinit한 뒤에만 새 admin hello가 host-global barrier를 획득한다.
        admin.deinit();
        admin_live = false;
        var inventory_admin: client_mod.Client = barrier: {
            var retry: usize = 0;
            while (retry < 150) : (retry += 1) switch (connectExactCurrent(allocator, manifest.descriptor())) {
                .connected => |value| break :barrier value,
                .unavailable => |reason| switch (reason) {
                    .busy, .transient => _ = usleep(20_000),
                    else => return error.TestUnexpectedResult,
                },
            };
            return error.TestUnexpectedResult;
        };
        defer inventory_admin.deinit();
        var inventory = try inventory_admin.runtimeInventory();
        switch (inventory) {
            .unavailable => return error.TestUnexpectedResult,
            .complete => |*complete| {
                defer complete.deinit(allocator);
                const runtime_value = try std.fmt.parseInt(u128, &runtime_id, 16);
                for (complete.runtime_ids) |candidate|
                    if (candidate == runtime_value) return error.TestUnexpectedResult;
            },
        }
    }
    try std.testing.expect(client_mod.Client.preparedBlockingRpcStorageSettled(&storage));
}

const RejectResponsePublication = struct {
    reserve_count: u8 = 0,
    commit_count: u8 = 0,

    fn observer(self: *RejectResponsePublication) @import("framing.zig").PayloadAllocationObserver {
        return .{
            .context = self,
            .reserve_fn = reserve,
            .commit_fn = commit,
            .abort_fn = abort,
            .discard_fn = discard,
        };
    }

    fn reserve(context: *anyopaque, _: usize, _: std.mem.Allocator) error{ OutOfMemory, IdentityExhausted, ProtocolError }!u64 {
        const self: *RejectResponsePublication = @ptrCast(@alignCast(context));
        self.reserve_count += 1;
        return 1;
    }

    fn commit(context: *anyopaque, _: u64, _: []u8, _: std.mem.Allocator) error{ProtocolError}!void {
        const self: *RejectResponsePublication = @ptrCast(@alignCast(context));
        self.commit_count += 1;
        return error.ProtocolError;
    }

    fn abort(_: *anyopaque, _: u64) void {}
    fn discard(_: *anyopaque, _: u64) void {}
};

test "C3-3b6 actual socket은 detach host EOF 뒤 fresh GUI 재접속을 증명한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var base_buf: [192]u8 = undefined;
    const base = try std.fmt.bufPrintZ(&base_buf, "/tmp/maru-c3b6-reconnect-{d}", .{c.getpid()});
    std.Io.Dir.cwd().deleteTree(std.testing.io, base) catch {};
    _ = c.mkdir(base.ptr, 0o700);
    var session_buf: [256]u8 = undefined;
    const session_dir = try discovery.sessionHostDirPath(&session_buf, base);
    _ = c.mkdir(session_dir.ptr, 0o700);
    const host_id = (@as(u128, @intCast(c.getpid())) << 64) | 0xC3B7;
    try short_endpoint.prepareCurrentUserNamespace();
    var socket_buf: [128]u8 = undefined;
    const socket_path = try short_endpoint.currentSocketPathIn(&socket_buf, host_id);
    const child = c.fork();
    if (child < 0) return error.SkipZigTest;
    if (child == 0) {
        daemon.runSessionHostWithIdentity(
            std.heap.page_allocator,
            std.testing.io,
            session_dir,
            socket_path,
            host_id,
        ) catch {};
        std.c._exit(0);
    }
    defer {
        _ = c.kill(child, posix.SIG.TERM);
        var status: c_int = 0;
        while (true) {
            const waited = c.waitpid(child, &status, 0);
            if (waited == child) break;
            if (waited < 0 and posix.errno(waited) == .INTR) continue;
            break;
        }
        _ = c.unlink(socket_path.ptr);
        host_manifest.removeEmptyHostDirectories(session_dir, host_id);
        std.Io.Dir.cwd().deleteTree(std.testing.io, base) catch {};
    }

    var first: client_mod.Client = first_connection: {
        var retry: usize = 0;
        while (retry < 150) : (retry += 1) {
            if (client_mod.Client.connect(allocator, socket_path, .gui)) |value| break :first_connection value else |_| {
                _ = usleep(20_000);
            }
        }
        return error.TestUnexpectedResult;
    };
    var first_live = true;
    defer if (first_live) first.deinit();
    const spawn = try first.call("runtime.spawn", "{\"argv\":[\"/bin/cat\"],\"cols\":40,\"rows\":10}");
    defer allocator.free(spawn);
    const runtime_id = client_mod.extractRuntimeId(spawn) orelse return error.TestUnexpectedResult;
    var original: remote_runtime.RemoteRuntime = undefined;
    try original.attachExisting(&first, allocator, std.testing.io, 77, runtime_id, .{ .cols = 40, .rows = 10 });
    original.detachClientSide();
    first.deinit();
    first_live = false;

    var fresh: client_mod.Client = fresh_connection: {
        var retry: usize = 0;
        while (retry < 150) : (retry += 1) {
            if (client_mod.Client.connect(allocator, socket_path, .gui)) |value| break :fresh_connection value else |_| {
                _ = usleep(20_000);
            }
        }
        return error.TestUnexpectedResult;
    };
    defer fresh.deinit();
    var reconnected: remote_runtime.RemoteRuntime = undefined;
    try reconnected.attachExisting(&fresh, allocator, std.testing.io, 78, runtime_id, .{ .cols = 40, .rows = 10 });
    try std.testing.expectEqual(runtime_id, reconnected.runtimeIdHex());
    try reconnected.sendInput("reconnected\n");
    reconnected.deinit();
}
