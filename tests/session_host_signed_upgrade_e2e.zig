//! 서명된 실제 Maru N-1/current 실행 파일 사이의 session-host live-upgrade E2E.
//!
//! 기본 테스트는 개발용 fixture로 same-PID exec/rollback을 검증하지만 Apple release signer
//! 경계를 통과하지 않는다. 이 실행 파일은 릴리스 후보 두 개를 명시적으로 받아 제품
//! `__session-host`를 띄우고, non-empty PTY graph가 같은 host PID에서 이어지는지 검증한다.

const std = @import("std");
const c = std.c;
const posix = std.posix;
const session_host = @import("session_host");

const connect_attempts: usize = 500;
const marker_attempts: usize = 240;
const poll_delay_us: c_uint = 20 * 1000;
const marker_exit = "MARU_SIGNED_UPGRADE_EXIT_23";
const runtime_spawn_params =
    "{\"argv\":[\"/bin/sh\",\"-c\",\"/bin/stty -echo || exit 70; " ++
    "printf MARU_SIGNED_UPGRADE_READY; while IFS= read -r line; do if [ \\\"$line\\\" = " ++
    marker_exit ++
    " ]; then exit 23; fi; printf '%s\\\\r\\\\n' \\\"$line\\\"; done\"],\"cols\":80,\"rows\":12}";
const sol_local: c_int = 0;
const local_peerpid: c_int = 0x002;

extern "c" fn arc4random_buf(buf: [*]u8, nbytes: usize) void;
extern "c" fn usleep(usec: c_uint) c_int;
extern "c" fn proc_listchildpids(ppid: c.pid_t, buffer: ?*anyopaque, buffersize: c_int) c_int;
extern "c" fn proc_name(pid: c_int, buffer: [*]u8, buffersize: u32) c_int;

const Config = struct {
    n1_executable: [:0]u8,
    current_executable: [:0]u8,
    artifact_path: []u8,

    fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.n1_executable);
        allocator.free(self.current_executable);
        allocator.free(self.artifact_path);
        self.* = undefined;
    }
};

const Evidence = struct {
    host_id: u128,
    runtime_id: [32]u8,
    attempt_id: u128,
    host_pid_before: c.pid_t,
    host_pid_after: c.pid_t,
    runtime_pid_before: c.pid_t,
    runtime_pid_after: c.pid_t,
    epoch_before: u64,
    epoch_after: u64,
    old_sha256: [32]u8,
    current_sha256: [32]u8,
    signer_requirement_sha256: [32]u8,
    duration_ms: u64 = 0,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;

    var config = parseConfig(init, stderr) catch |err| {
        try stderr.print("signed session-host E2E 설정 오류: {s}\n", .{@errorName(err)});
        try stderr.flush();
        std.process.exit(2);
    };
    defer config.deinit(allocator);

    const started_ns = std.Io.Clock.awake.now(io).nanoseconds;
    var evidence = run(allocator, io, config) catch |err| {
        try stderr.print("signed session-host E2E 실패: {s}\n", .{@errorName(err)});
        try stderr.flush();
        return err;
    };
    evidence.duration_ms = @intCast(@divTrunc(
        std.Io.Clock.awake.now(io).nanoseconds - started_ns,
        std.time.ns_per_ms,
    ));
    try writeArtifact(allocator, io, config.artifact_path, evidence);
}

fn parseConfig(init: std.process.Init, stderr: *std.Io.Writer) !Config {
    const allocator = init.gpa;
    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();
    _ = args.next();
    const n1_raw = args.next() orelse return usage(stderr);
    const current_raw = args.next() orelse return usage(stderr);
    const artifact_raw = args.next() orelse return usage(stderr);
    if (args.next() != null or artifact_raw.len == 0)
        return usage(stderr);
    const artifact_path = try allocator.dupe(u8, artifact_raw);
    errdefer allocator.free(artifact_path);
    try invalidateArtifact(allocator, artifact_path);
    if (n1_raw.len == 0 or current_raw.len == 0) return usage(stderr);

    const n1_real = try std.Io.Dir.cwd().realPathFileAlloc(init.io, n1_raw, allocator);
    defer allocator.free(n1_real);
    const current_real = try std.Io.Dir.cwd().realPathFileAlloc(init.io, current_raw, allocator);
    defer allocator.free(current_real);
    if (!std.fs.path.isAbsolute(n1_real) or !std.fs.path.isAbsolute(current_real))
        return error.AbsoluteExecutableRequired;
    const n1_executable = try allocator.dupeZ(u8, n1_real);
    errdefer allocator.free(n1_executable);
    const current_executable = try allocator.dupeZ(u8, current_real);

    return .{
        .n1_executable = n1_executable,
        .current_executable = current_executable,
        .artifact_path = artifact_path,
    };
}

fn usage(stderr: *std.Io.Writer) anyerror {
    try stderr.writeAll(
        "usage: maru-session-host-signed-upgrade-e2e " ++
            "<signed-n1-maru> <signed-current-maru> <artifact.json>\n",
    );
    return error.MissingSignedArtifact;
}

fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: Config,
) !Evidence {
    const old_identity = try session_host.staged_image.inspect(config.n1_executable);
    const target_identity = try session_host.staged_image.inspect(config.current_executable);
    if (std.mem.eql(u8, &old_identity.sha256, &target_identity.sha256))
        return error.IdenticalExecutables;
    if (!session_host.code_signature.sameReleaseSigner(
        io,
        config.n1_executable,
        config.current_executable,
    )) return error.ReleaseSignerMismatch;
    const old_requirement = session_host.code_signature.releaseRequirementDigest(
        io,
        config.n1_executable,
    ) orelse return error.ReleaseSignerMismatch;
    const current_requirement = session_host.code_signature.releaseRequirementDigest(
        io,
        config.current_executable,
    ) orelse return error.ReleaseSignerMismatch;
    if (!std.mem.eql(u8, &old_requirement, &current_requirement))
        return error.ReleaseSignerMismatch;
    const old_build_id = try session_host.host_manifest.buildIdForExecutable(
        allocator,
        config.n1_executable,
    );
    defer allocator.free(old_build_id);
    const target_build_id = try session_host.host_manifest.buildIdForExecutable(
        allocator,
        config.current_executable,
    );
    defer allocator.free(target_build_id);

    var nonce: u64 = 0;
    arc4random_buf(std.mem.asBytes(&nonce).ptr, @sizeOf(@TypeOf(nonce)));
    var leaf_buf: [128]u8 = undefined;
    const leaf = try std.fmt.bufPrint(
        &leaf_buf,
        "maru-session-host-signed-upgrade-{d}-{x:0>16}",
        .{ c.getpid(), nonce },
    );
    var base_buf: [160]u8 = undefined;
    const base = try std.fmt.bufPrintZ(&base_buf, "/tmp/{s}", .{leaf});
    var session_dir_buf: [192]u8 = undefined;
    const session_dir = try std.fmt.bufPrintZ(&session_dir_buf, "{s}/session-host", .{base});

    var tmp = try std.Io.Dir.openDirAbsolute(io, "/tmp", .{});
    defer tmp.close(io);
    try tmp.createDirPath(io, leaf);
    defer tmp.deleteTree(io, leaf) catch {};
    if (c.chmod(base.ptr, 0o700) != 0) return error.TempDirectoryFailed;
    if (c.mkdir(session_dir.ptr, 0o700) != 0) return error.TempDirectoryFailed;

    var host_id = randomNonZeroU128();
    if (host_id == 0) host_id = 1;
    try session_host.short_endpoint.prepareCurrentUserNamespace();
    var socket_buf: [128]u8 = undefined;
    const socket_path = try session_host.short_endpoint.currentSocketPathIn(&socket_buf, host_id);
    _ = c.unlink(socket_path.ptr);

    const supervised_pid = try session_host.launcher.spawnSessionHostSupervisedForTest(
        allocator,
        config.n1_executable,
        session_dir,
        socket_path,
        host_id,
    );
    defer {
        stopSupervisedChild(supervised_pid);
        _ = c.unlink(socket_path.ptr);
    }

    var before = try connectExact(allocator, base, host_id);
    var before_open = true;
    defer if (before_open) before.deinit();
    const host_pid_before = try peerPid(before.fd);
    if (host_pid_before != supervised_pid) return error.UnexpectedHostProcess;
    if (!before.host_exec_upgrade_v1) return error.UpgradeCapabilityMissing;
    if (before.build_id == null or !std.mem.eql(u8, before.build_id.?, old_build_id))
        return error.SourceBuildMismatch;
    const epoch_before = before.upgrade_epoch;

    var children_before: [64]c.pid_t = undefined;
    const children_before_len = try listChildren(host_pid_before, &children_before);
    const spawn_response = try before.call("runtime.spawn", runtime_spawn_params);
    defer allocator.free(spawn_response);
    const runtime_id = session_host.client.extractRuntimeId(spawn_response) orelse
        return error.RuntimeSpawnFailed;
    const runtime_pid_before = try waitForNewChild(
        host_pid_before,
        children_before[0..children_before_len],
    );

    const stream_before = try attachRuntime(allocator, &before, &runtime_id);
    var screen_before = session_host.screen_assembler.ScreenAssembler.initForCodec(
        allocator,
        before.screen_codec_version,
    );
    defer screen_before.deinit();
    const initial = try before.readSnapshot(stream_before);
    defer allocator.free(initial);
    try screen_before.applySnapshot(initial);
    try waitForMarker(
        &before,
        stream_before,
        &screen_before,
        "MARU_SIGNED_UPGRADE_READY",
    );
    try waitForProcessName(runtime_pid_before, "sh");
    const marker_before = "MARU_SIGNED_UPGRADE_BEFORE";
    try before.sendInput(stream_before, marker_before ++ "\r");
    try waitForMarker(&before, stream_before, &screen_before, marker_before);
    try detachRuntime(allocator, &before, stream_before);
    before.deinit();
    before_open = false;

    const attempt_id = randomNonZeroU128();

    var prepare_client = try connectExact(allocator, base, host_id);
    var prepare_open = true;
    defer if (prepare_open) prepare_client.deinit();
    const outcome = try prepare_client.prepareUpgrade(.{
        .attempt_id = attempt_id,
        .target_path = config.current_executable,
        .target_build_id = target_build_id,
        .target_sha256 = target_identity.sha256,
        .handoff_reader_min = session_host.handoff_codec.reader_min,
        .handoff_reader_max = session_host.handoff_codec.reader_max,
    });
    switch (outcome) {
        .accepted_reconnect_required => {},
        .completed, .rejected => return error.UpgradeNotAccepted,
    }
    prepare_client.deinit();
    prepare_open = false;

    var after = try connectExact(allocator, base, host_id);
    defer after.deinit();
    const host_pid_after = try peerPid(after.fd);
    if (host_pid_after != host_pid_before) return error.HostPidChanged;
    if (after.host_id != host_id) return error.HostIdentityChanged;
    if (after.upgrade_epoch != epoch_before + 1) return error.UpgradeEpochMismatch;
    if (after.build_id == null or !std.mem.eql(u8, after.build_id.?, target_build_id))
        return error.TargetBuildMismatch;
    if (!after.host_exec_upgrade_v1) return error.UpgradeCapabilityLost;
    const runtime_pid_after = if (try childStillPresent(host_pid_after, runtime_pid_before))
        runtime_pid_before
    else
        return error.RuntimePidChanged;

    const list_response = try after.call("runtime.list", null);
    defer allocator.free(list_response);
    if (std.mem.indexOf(u8, list_response, &runtime_id) == null)
        return error.RuntimeIdentityLost;

    const report = try waitForCommitted(allocator, &after, attempt_id);
    if (report.status != .committed or report.reason != .none)
        return error.UpgradeNotCommitted;

    const stream_after = try attachRuntime(allocator, &after, &runtime_id);
    var screen_after = session_host.screen_assembler.ScreenAssembler.initForCodec(
        allocator,
        after.screen_codec_version,
    );
    defer screen_after.deinit();
    const restored = try after.readSnapshot(stream_after);
    defer allocator.free(restored);
    try screen_after.applySnapshot(restored);
    if (!screenContains(&screen_after, marker_before)) return error.PreUpgradeScreenLost;

    const marker_after = "MARU_SIGNED_UPGRADE_AFTER";
    try after.sendInput(stream_after, marker_after ++ "\r");
    try waitForMarker(&after, stream_after, &screen_after, marker_after);
    try after.sendInput(stream_after, marker_exit ++ "\r");
    try waitForRuntimeGone(allocator, &after, &runtime_id, host_pid_after, runtime_pid_after);

    return .{
        .host_id = host_id,
        .runtime_id = runtime_id,
        .attempt_id = attempt_id,
        .host_pid_before = host_pid_before,
        .host_pid_after = host_pid_after,
        .runtime_pid_before = runtime_pid_before,
        .runtime_pid_after = runtime_pid_after,
        .epoch_before = epoch_before,
        .epoch_after = after.upgrade_epoch,
        .old_sha256 = old_identity.sha256,
        .current_sha256 = target_identity.sha256,
        .signer_requirement_sha256 = old_requirement,
    };
}

fn connectExact(
    allocator: std.mem.Allocator,
    base: []const u8,
    host_id: u128,
) !session_host.client.Client {
    var attempt: usize = 0;
    while (attempt < connect_attempts) : (attempt += 1) {
        switch (session_host.host_connect.connectExistingHost(allocator, base, host_id)) {
            .connected => |client| return client,
            .failed => |reason| switch (reason) {
                .startup_timeout, .handshake_failed => {},
                else => return error.HostConnectFailed,
            },
        }
        _ = usleep(poll_delay_us);
    }
    return error.HostConnectTimeout;
}

fn attachRuntime(
    allocator: std.mem.Allocator,
    client: *session_host.client.Client,
    runtime_id: *const [32]u8,
) !u64 {
    const params = try std.fmt.allocPrint(
        allocator,
        "{{\"runtime_id\":\"{s}\",\"mode\":\"controller\"}}",
        .{runtime_id},
    );
    defer allocator.free(params);
    const response = try client.call("runtime.attach", params);
    defer allocator.free(response);
    return session_host.client.extractU64Field(response, "\"stream_id\":") orelse
        error.RuntimeAttachFailed;
}

fn detachRuntime(
    allocator: std.mem.Allocator,
    client: *session_host.client.Client,
    stream_id: u64,
) !void {
    const params = try std.fmt.allocPrint(allocator, "{{\"stream_id\":{d}}}", .{stream_id});
    defer allocator.free(params);
    const response = try client.call("runtime.detach", params);
    allocator.free(response);
}

fn waitForRuntimeGone(
    allocator: std.mem.Allocator,
    client: *session_host.client.Client,
    runtime_id: *const [32]u8,
    host_pid: c.pid_t,
    runtime_pid: c.pid_t,
) !void {
    var consecutive_absent: u8 = 0;
    var attempt: usize = 0;
    while (attempt < marker_attempts) : (attempt += 1) {
        var inventory = try client.runtimeInventory();
        const absent = switch (inventory) {
            .complete => |*complete| blk: {
                defer complete.deinit(allocator);
                const runtime_numeric = std.fmt.parseInt(u128, runtime_id, 16) catch
                    return error.RuntimeIdentityInvalid;
                break :blk std.mem.indexOfScalar(u128, complete.runtime_ids, runtime_numeric) == null;
            },
            .unavailable => false,
        };
        if (absent and !try childStillPresent(host_pid, runtime_pid)) {
            consecutive_absent += 1;
            if (consecutive_absent == 2) return;
        } else {
            consecutive_absent = 0;
        }
        _ = usleep(poll_delay_us);
    }
    return error.RuntimeReapTimeout;
}

fn waitForMarker(
    client: *session_host.client.Client,
    stream_id: u64,
    assembler: *session_host.screen_assembler.ScreenAssembler,
    marker: []const u8,
) !void {
    var attempt: usize = 0;
    while (attempt < marker_attempts) : (attempt += 1) {
        if (screenContains(assembler, marker)) return;
        if (try client.readStreamBatch(stream_id)) |batch| {
            defer batch.deinit();
            if (batch.is_snapshot)
                try assembler.applySnapshot(batch.bytes)
            else
                try assembler.applyDelta(batch.bytes);
        }
        _ = usleep(poll_delay_us);
    }
    return error.MarkerTimeout;
}

fn screenContains(
    assembler: *const session_host.screen_assembler.ScreenAssembler,
    marker: []const u8,
) bool {
    var row: u16 = 0;
    while (row < assembler.rows_count) : (row += 1) {
        var bytes: [4096]u8 = undefined;
        var used: usize = 0;
        for (assembler.rowRuns(row)) |cell_run| {
            var repeat: u32 = 0;
            while (repeat < cell_run.count) : (repeat += 1) {
                if (cell_run.grapheme.len > bytes.len - used) break;
                @memcpy(bytes[used..][0..cell_run.grapheme.len], cell_run.grapheme);
                used += cell_run.grapheme.len;
            }
        }
        if (std.mem.indexOf(u8, bytes[0..used], marker) != null) return true;
    }
    return false;
}

fn peerPid(fd: c.fd_t) !c.pid_t {
    var pid: c.pid_t = 0;
    var len: c.socklen_t = @sizeOf(c.pid_t);
    if (c.getsockopt(fd, sol_local, local_peerpid, &pid, &len) != 0 or
        len != @sizeOf(c.pid_t) or pid <= 0)
        return error.PeerPidUnavailable;
    return pid;
}

fn listChildren(parent: c.pid_t, buffer: *[64]c.pid_t) !usize {
    @memset(buffer, 0);
    // libproc returns a PID count here, not the number of bytes written. Keep
    // this oracle aligned with the product process-tree walker so one live PTY
    // child cannot be mistaken for zero children during an upgrade.
    const count = proc_listchildpids(parent, buffer, @intCast(@sizeOf(@TypeOf(buffer.*))));
    if (count < 0) return error.ChildInventoryUnavailable;
    if (count == 0) return 0;
    return @min(buffer.len, @as(usize, @intCast(count)));
}

fn waitForNewChild(parent: c.pid_t, before: []const c.pid_t) !c.pid_t {
    var attempt: usize = 0;
    while (attempt < marker_attempts) : (attempt += 1) {
        var current: [64]c.pid_t = undefined;
        const count = try listChildren(parent, &current);
        for (current[0..count]) |pid| {
            if (pid > 0 and std.mem.indexOfScalar(c.pid_t, before, pid) == null) return pid;
        }
        _ = usleep(poll_delay_us);
    }
    return error.RuntimePidUnavailable;
}

fn childStillPresent(parent: c.pid_t, child: c.pid_t) !bool {
    var current: [64]c.pid_t = undefined;
    const count = try listChildren(parent, &current);
    return std.mem.indexOfScalar(c.pid_t, current[0..count], child) != null;
}

fn waitForProcessName(pid: c.pid_t, expected: []const u8) !void {
    var attempt: usize = 0;
    while (attempt < marker_attempts) : (attempt += 1) {
        var name_buf: [256]u8 = undefined;
        const count = proc_name(pid, &name_buf, name_buf.len);
        if (count > 0 and std.mem.eql(u8, name_buf[0..@intCast(count)], expected)) return;
        _ = usleep(poll_delay_us);
    }
    return error.RuntimeProcessMismatch;
}

fn waitForCommitted(
    allocator: std.mem.Allocator,
    client: *session_host.client.Client,
    attempt_id: u128,
) !session_host.upgrade_wire.AttemptReport {
    _ = allocator;
    var attempt: usize = 0;
    while (attempt < marker_attempts) : (attempt += 1) {
        if (try client.upgradeStatus(attempt_id)) |report| switch (report.status) {
            .pending => {},
            else => return report,
        };
        _ = usleep(poll_delay_us);
    }
    return error.UpgradeStatusTimeout;
}

fn stopSupervisedChild(pid: c.pid_t) void {
    var attempt: usize = 0;
    while (attempt < 250) : (attempt += 1) {
        var status: c_int = undefined;
        const waited = c.waitpid(pid, &status, c.W.NOHANG);
        if (waited == pid or (waited < 0 and posix.errno(waited) == .CHILD)) return;
        if (attempt == 0) _ = c.kill(pid, posix.SIG.TERM);
        _ = usleep(poll_delay_us);
    }
    _ = c.kill(pid, posix.SIG.KILL);
    while (true) {
        var status: c_int = undefined;
        const waited = c.waitpid(pid, &status, 0);
        if (waited == pid or (waited < 0 and posix.errno(waited) == .CHILD)) return;
        if (waited < 0 and posix.errno(waited) == .INTR) continue;
        return;
    }
}

fn randomNonZeroU128() u128 {
    var value: u128 = 0;
    arc4random_buf(std.mem.asBytes(&value).ptr, @sizeOf(@TypeOf(value)));
    return if (value == 0) 1 else value;
}

fn invalidateArtifact(allocator: std.mem.Allocator, path: []const u8) !void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const rc = c.unlink(path_z.ptr);
    if (rc != 0 and posix.errno(rc) != .NOENT) return error.ArtifactInvalidationFailed;
}

fn writeArtifact(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    evidence: Evidence,
) !void {
    if (std.fs.path.dirname(path)) |parent| {
        // Build step의 artifact는 workspace-relative라 parent를 만든다. 직접 실행에서
        // absolute output을 주면 caller가 고른 기존 parent 아래 exact leaf만 쓴다.
        if (!std.fs.path.isAbsolute(parent))
            try std.Io.Dir.cwd().createDirPath(io, parent);
    }
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var json: std.json.Stringify = .{
        .writer = &out.writer,
        .options = .{ .whitespace = .indent_2 },
    };
    var host_buf: [32]u8 = undefined;
    const host = try std.fmt.bufPrint(&host_buf, "{x:0>32}", .{evidence.host_id});
    var attempt_buf: [32]u8 = undefined;
    const attempt = try std.fmt.bufPrint(&attempt_buf, "{x:0>32}", .{evidence.attempt_id});
    const old_sha = std.fmt.bytesToHex(evidence.old_sha256, .lower);
    const current_sha = std.fmt.bytesToHex(evidence.current_sha256, .lower);
    const signer_sha = std.fmt.bytesToHex(evidence.signer_requirement_sha256, .lower);
    const old_build_id = try std.fmt.allocPrint(allocator, "sha256:{s}", .{&old_sha});
    defer allocator.free(old_build_id);
    const current_build_id = try std.fmt.allocPrint(allocator, "sha256:{s}", .{&current_sha});
    defer allocator.free(current_build_id);
    try json.write(.{
        .schema = "maru.session-host-signed-upgrade-e2e.v1",
        .host_id = host,
        .runtime_id = &evidence.runtime_id,
        .attempt_id = attempt,
        .old_sha256 = &old_sha,
        .current_sha256 = &current_sha,
        .old_build_id = old_build_id,
        .current_build_id = current_build_id,
        .signer_requirement_sha256 = &signer_sha,
        .same_host_pid = evidence.host_pid_before == evidence.host_pid_after,
        .same_runtime_pid = evidence.runtime_pid_before == evidence.runtime_pid_after,
        .runtime_screen_before_preserved = true,
        .runtime_screen_after_writable = true,
        .runtime_reaped_after_exit = true,
        .runtime_inventory_absent_observations = 2,
        .status_committed = true,
        .status_reason = "none",
        .upgrade_capability_preserved = true,
        .epoch_before = evidence.epoch_before,
        .epoch_after = evidence.epoch_after,
        .duration_ms = evidence.duration_ms,
    });
    try out.writer.writeByte('\n');
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = out.written(),
        .flags = .{ .truncate = true },
    });
}

test "signed upgrade E2E helper rejects a marker absent from empty screen" {
    var assembler = session_host.screen_assembler.ScreenAssembler.init(std.testing.allocator);
    defer assembler.deinit();
    try std.testing.expect(!screenContains(&assembler, "missing"));
}

test "signed upgrade runtime command is valid JSON and owns the exit marker once" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        runtime_spawn_params,
        .{},
    );
    defer parsed.deinit();
    const argv = parsed.value.object.get("argv").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), argv.len);
    try std.testing.expectEqualStrings("/bin/sh", argv[0].string);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, argv[2].string, marker_exit));
    try std.testing.expect(std.mem.indexOf(u8, argv[2].string, "then exit 23") != null);
}

test "signed upgrade artifact invalidates stale success and pins auditable identities" {
    const allocator = std.testing.allocator;
    var path_buf: [160]u8 = undefined;
    const path = try std.fmt.bufPrintZ(
        &path_buf,
        "/tmp/maru-signed-upgrade-artifact-{d}.json",
        .{c.getpid()},
    );
    defer _ = c.unlink(path.ptr);
    const fd = c.open(
        path.ptr,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true },
        @as(c.mode_t, 0o600),
    );
    try std.testing.expect(fd >= 0);
    _ = c.close(fd);
    try invalidateArtifact(allocator, path);
    try std.testing.expect(c.access(path.ptr, c.F_OK) != 0);

    try writeArtifact(allocator, std.testing.io, path, .{
        .host_id = 1,
        .runtime_id = [_]u8{'a'} ** 32,
        .attempt_id = 2,
        .host_pid_before = 10,
        .host_pid_after = 10,
        .runtime_pid_before = 11,
        .runtime_pid_after = 11,
        .epoch_before = 3,
        .epoch_after = 4,
        .old_sha256 = [_]u8{0x11} ** 32,
        .current_sha256 = [_]u8{0x22} ** 32,
        .signer_requirement_sha256 = [_]u8{0x33} ** 32,
        .duration_ms = 5,
    });
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(64 * 1024),
    );
    defer allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expectEqualStrings(
        "maru.session-host-signed-upgrade-e2e.v1",
        object.get("schema").?.string,
    );
    try std.testing.expectEqualStrings(
        "sha256:1111111111111111111111111111111111111111111111111111111111111111",
        object.get("old_build_id").?.string,
    );
    try std.testing.expectEqualStrings(
        "3333333333333333333333333333333333333333333333333333333333333333",
        object.get("signer_requirement_sha256").?.string,
    );
    try std.testing.expect(object.get("upgrade_capability_preserved").?.bool);
    try std.testing.expect(object.get("runtime_reaped_after_exit").?.bool);
    try std.testing.expectEqual(
        @as(i64, 2),
        object.get("runtime_inventory_absent_observations").?.integer,
    );
    try std.testing.expectEqual(@as(i64, 5), object.get("duration_ms").?.integer);
}
