//! U5 non-empty product rollback lifecycle E2E.
//!
//! PTY를 test runner가 만든 뒤 fd만 넘기면 rollback host는 terminal child의 parent가 아니어서
//! waitpid 소유권을 증명할 수 없다. supervised source-host child가 실제 RuntimeManager로 PTY를
//! 만들고 quiesced handoff를 구성한 뒤 같은 PID에서 target→canonical product rollback exec한다.

const std = @import("std");
const c = std.c;
const posix = std.posix;
const sh = @import("session_host");

const marker_before = "MARU_ROLLBACK_BEFORE";
const marker_after = "MARU_ROLLBACK_AFTER";
const marker_exit = "MARU_ROLLBACK_EXIT_23";
const sol_local: c_int = 0;
const local_peerpid: c_int = 0x002;

extern "c" fn getdtablesize() c_int;
extern "c" fn execv(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;
extern "c" fn usleep(usec: c_uint) c_int;
extern "c" fn proc_listchildpids(ppid: c.pid_t, buffer: ?*anyopaque, buffersize: c_int) c_int;

const SourceEvidence = extern struct {
    runtime_id_hi: u64,
    runtime_id_lo: u64,
    child_pid: c.pid_t,
};

test "product rollback preserves one real PTY through exit" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const gate = c.getenv("MARU_SESSION_HOST_NONEMPTY_PRODUCT_ROLLBACK_GATE") orelse
        return error.SkipZigTest;
    if (!std.mem.eql(u8, std.mem.span(gate), "maru-test-only-v1"))
        return error.SkipZigTest;
    const product_raw = c.getenv("MARU_SESSION_HOST_PRODUCT_EXE") orelse
        return error.SkipZigTest;
    const product_real = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        std.mem.span(product_raw),
        std.testing.allocator,
    );
    defer std.testing.allocator.free(product_real);
    const product = try std.testing.allocator.dupeZ(u8, product_real);
    defer std.testing.allocator.free(product);
    const product_identity = try sh.staged_image.inspect(product);
    const digest_hex = std.fmt.bytesToHex(product_identity.sha256, .lower);
    const product_build_id = try std.fmt.allocPrint(
        std.testing.allocator,
        "sha256:{s}",
        .{&digest_hex},
    );
    defer std.testing.allocator.free(product_build_id);

    const now = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
    const host_id: u128 = (@as(u128, @intCast(c.getpid())) << 64) |
        @as(u128, @intCast(if (now <= 0) 1 else now));
    const attempt_id: u128 = 0xA11CE;
    var session_buf: [224]u8 = undefined;
    const session_dir = try std.fmt.bufPrintZ(
        &session_buf,
        "/tmp/maru-nr-{d}",
        .{c.getpid()},
    );
    if (c.mkdir(session_dir.ptr, 0o700) != 0) return error.TestUnexpectedResult;
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, session_dir) catch {};

    const previous_root = if (c.getenv("MARU_SESSION_HOST_ROOT")) |value|
        try std.testing.allocator.dupeZ(u8, std.mem.span(value))
    else
        null;
    defer {
        if (previous_root) |value| {
            _ = setenv("MARU_SESSION_HOST_ROOT", value.ptr, 1);
            std.testing.allocator.free(value);
        } else {
            _ = unsetenv("MARU_SESSION_HOST_ROOT");
        }
    }
    if (setenv("MARU_SESSION_HOST_ROOT", session_dir.ptr, 1) != 0)
        return error.TestUnexpectedResult;
    try sh.short_endpoint.prepareCurrentUserNamespace();
    var socket_dir_buf: [272]u8 = undefined;
    const socket_dir = try sh.short_endpoint.currentSocketDirPathIn(&socket_dir_buf);
    defer _ = c.rmdir(socket_dir.ptr);
    try sh.host_manifest.prepareHostDirectory(session_dir, host_id);
    var host_dir_buf: [768]u8 = undefined;
    const host_dir = try sh.host_manifest.hostDirPathIn(&host_dir_buf, session_dir, host_id);
    var owner_path_buf: [832]u8 = undefined;
    const owner_path = try sh.host_manifest.ownerLockPathIn(&owner_path_buf, session_dir, host_id);
    var rollback = try sh.rollback_image.Authority.prepare(
        std.testing.allocator,
        product,
        product_identity,
        host_dir,
    );
    defer rollback.deinit();
    var target = try sh.staged_image.stageExclusive(
        std.testing.allocator,
        product,
        host_dir,
        "nonempty-target",
    );
    defer target.deinit();
    const rollback_record = rollback.record();
    try std.testing.expect(!std.mem.eql(u8, target.path, rollback_record.path));
    try std.testing.expect(target.identity.dev != rollback_record.dev or
        target.identity.ino != rollback_record.ino);
    const layout = sh.upgrade_product_coordinator.findAvailableLayout(40) orelse
        return error.SkipZigTest;
    var socket_buf: [128]u8 = undefined;
    const socket_path = try sh.short_endpoint.currentSocketPathIn(&socket_buf, host_id);
    _ = c.unlink(socket_path.ptr);
    defer _ = c.unlink(socket_path.ptr);
    var activation_buf: [192]u8 = undefined;
    const activation_marker = try std.fmt.bufPrintZ(
        &activation_buf,
        "/tmp/maru-restore-activation-{d}",
        .{c.getpid()},
    );
    _ = c.unlink(activation_marker.ptr);
    defer _ = c.unlink(activation_marker.ptr);

    var evidence_pipe: [2]c.fd_t = undefined;
    if (c.pipe(&evidence_pipe) != 0) return error.TestUnexpectedResult;
    var read_open = true;
    var write_open = true;
    defer {
        if (read_open) _ = c.close(evidence_pipe[0]);
    }
    defer {
        if (write_open) _ = c.close(evidence_pipe[1]);
    }
    const source_pid = c.fork();
    if (source_pid < 0) return error.TestUnexpectedResult;
    if (source_pid == 0) {
        _ = c.close(evidence_pipe[0]);
        runSourceHost(
            product,
            product_build_id,
            target,
            rollback_record,
            session_dir,
            host_dir,
            socket_path,
            activation_marker,
            host_id,
            attempt_id,
            layout,
            owner_path,
            evidence_pipe[1],
        ) catch |err| {
            std.debug.print("non-empty rollback source-host failed: {s}\n", .{@errorName(err)});
            c._exit(2);
        };
    }
    _ = c.close(evidence_pipe[1]);
    write_open = false;
    var source_reaped = false;
    defer if (!source_reaped) stopChild(source_pid);
    var source_evidence: SourceEvidence = undefined;
    try readExact(evidence_pipe[0], std.mem.asBytes(&source_evidence));
    _ = c.close(evidence_pipe[0]);
    read_open = false;
    const runtime_id = (@as(u128, source_evidence.runtime_id_hi) << 64) |
        source_evidence.runtime_id_lo;
    try std.testing.expect(runtime_id != 0);
    try std.testing.expect(source_evidence.child_pid > 0);

    try waitForFile(activation_marker, source_pid);
    var client = try connectExact(socket_path);
    try std.testing.expectEqual(source_pid, try peerPid(client.fd));
    try std.testing.expectEqual(host_id, client.host_id);
    try std.testing.expectEqual(@as(u64, 4), client.upgrade_epoch);
    try std.testing.expect(client.build_id != null);
    try std.testing.expectEqualStrings(product_build_id, client.build_id.?);
    try std.testing.expect(client.host_exec_upgrade_v1);
    const report = (try client.upgradeStatus(attempt_id)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(sh.upgrade_wire.AttemptStatus.rolled_back, report.status);
    try std.testing.expectEqual(sh.upgrade_wire.AttemptReason.restore_failed, report.reason);
    try expectOnlyRuntime(&client, runtime_id);
    try std.testing.expect(directChildPresent(source_pid, source_evidence.child_pid));

    var runtime_hex_buf: [32]u8 = undefined;
    const runtime_hex = try std.fmt.bufPrint(&runtime_hex_buf, "{x:0>32}", .{runtime_id});
    const stream_id = try attachRuntime(&client, runtime_hex);
    var screen = sh.screen_assembler.ScreenAssembler.initForCodec(
        std.testing.allocator,
        client.screen_codec_version,
    );
    defer screen.deinit();
    const snapshot = try client.readSnapshot(stream_id);
    defer std.testing.allocator.free(snapshot);
    try screen.applySnapshot(snapshot);
    if (!screenContains(&screen, marker_before)) return error.TestUnexpectedResult;
    try client.sendInput(stream_id, marker_after ++ "\r");
    try waitForMarker(&client, stream_id, &screen, marker_after);
    try client.sendInput(stream_id, marker_exit ++ "\r");
    try waitForRuntimeGone(&client, runtime_id, source_pid, source_evidence.child_pid);
    client.deinit();
    try waitChild(source_pid, true);
    source_reaped = true;
}

fn runSourceHost(
    product: [:0]const u8,
    product_build_id: []const u8,
    target: sh.staged_image.StagedImage,
    rollback: sh.upgrade_attempt_record.ImageView,
    session_dir: [:0]const u8,
    host_dir: [:0]const u8,
    socket_path: [:0]const u8,
    activation_marker: [:0]const u8,
    host_id: u128,
    attempt_id: u128,
    layout: sh.upgrade_fd_layout.Layout,
    owner_path: [:0]const u8,
    evidence_fd: c.fd_t,
) !noreturn {
    const allocator = std.heap.page_allocator;
    const lease = try sh.owner_lease.OwnerLease.acquire(owner_path);
    var registry = sh.registry.TerminalRuntimeRegistry.init(allocator);
    var manager: sh.runtime_manager.RuntimeManager = undefined;
    manager.initWithHostId(allocator, std.testing.io, &registry, host_id, null);
    const ops = manager.runtimeOps();
    const runtime_id = try ops.spawn(ops.ctx, .{
        .argv = &.{
            "/bin/sh",
            "-c",
            "stty -echo || exit 70; while IFS= read -r line; do " ++
                "if [ \"$line\" = " ++ marker_exit ++ " ]; then exit 23; fi; " ++
                "printf '%s\\r\\n' \"$line\"; done",
        },
        .cwd = null,
        .cols = 80,
        .rows = 12,
    });
    const entry = registry.get(runtime_id) orelse return error.TestUnexpectedResult;
    const handle = @intFromPtr(entry.runtime orelse return error.TestUnexpectedResult);
    const terminal = manager.backend_impl.terminalForHostLifecycle(handle) orelse
        return error.TestUnexpectedResult;
    const child_pid = terminal.live_pty.session.childPid();
    try ops.write_input(ops.ctx, runtime_id, marker_before ++ "\r");
    var marker_seen = false;
    var attempt: usize = 0;
    while (attempt < 5_000) : (attempt += 1) {
        _ = manager.drainOwnedEvents();
        const text = try terminal.surface.core.dumpRecentTextUtf8(allocator, 12, 16 * 1024);
        defer allocator.free(text);
        if (std.mem.indexOf(u8, text, marker_before) != null) {
            marker_seen = true;
            break;
        }
        _ = usleep(1000);
    }
    if (!marker_seen) return error.TestUnexpectedResult;
    const evidence = SourceEvidence{
        .runtime_id_hi = @truncate(runtime_id >> 64),
        .runtime_id_lo = @truncate(runtime_id),
        .child_pid = child_pid,
    };
    try writeExact(evidence_fd, std.mem.asBytes(&evidence));
    _ = c.close(evidence_fd);

    if (try manager.requestUpgradeQuiesce() != 1) return error.TestUnexpectedResult;
    attempt = 0;
    while (attempt < 5_000 and !manager.upgradeQuiesceReached()) : (attempt += 1)
        _ = usleep(1000);
    if (!manager.upgradeQuiesceReached()) return error.TestUnexpectedResult;
    try manager.joinAndValidateUpgradeQuiesce();
    var capture = try manager.prepareQuiescedCapture(
        allocator,
        host_id,
        4,
        1,
        @intCast(layout.first_runtime_slot),
    );
    var ids_buf: [sh.upgrade_limits.max_runtime_count]u128 = undefined;
    const runtime_ids = capture.sortedRuntimeIds(&ids_buf);
    const record = try sh.upgrade_attempt_record.encode(allocator, .{
        .host_id = host_id,
        .attempt_id = attempt_id,
        .epoch_before = 4,
        .expected_epoch_after = 5,
        .rollback_budget = 1,
        .deadline_expires_at_ns = std.math.maxInt(i128),
        .request_path = product,
        .staged_path = target.path,
        .build_id = product_build_id,
        .sha256 = target.identity.sha256,
        .dev = target.identity.dev,
        .ino = target.identity.ino,
        .size = target.identity.size,
        .rollback_image = rollback,
        .reader_min = sh.handoff_codec.reader_min,
        .reader_max = sh.handoff_codec.reader_max,
        .runtime_ids = runtime_ids,
        .completed = &.{},
    });
    const handoff = try capture.encode(record);
    const pair = try sh.handoff_store.commit(
        allocator,
        host_dir,
        .{
            .host_id = host_id,
            .attempt_id = attempt_id,
            .upgrade_epoch = 4,
            .next_handle = capture.next_handle,
            .runtime_ids = runtime_ids,
            .request_path = product,
            .staged_path = target.path,
            .build_id = product_build_id,
            .sha256 = target.identity.sha256,
            .dev = target.identity.dev,
            .ino = target.identity.ino,
            .size = target.identity.size,
            .rollback_image = rollback,
            .reader_min = sh.handoff_codec.reader_min,
            .reader_max = sh.handoff_codec.reader_max,
        },
        handoff,
        .{ .deadline = .testingNever() },
    );
    var slots: sh.exec_fd_set.PreparedSlots = .{};
    for (capture.resources) |resource|
        try slots.prepare(resource.source_fd, resource.inherited_slot);
    const corrupt_primary = try openTruncatedUnlinkedCopy(host_dir, handoff);
    try slots.prepare(corrupt_primary, layout.primarySlot());
    try slots.prepare(pair.backup_fd, layout.backupSlot());
    try slots.prepare(lease.descriptor(), layout.ownerSlot());
    // 성공 경로는 바로 exec하므로 Published의 heap/path authority는 새 image가 manifest에서
    // 재채택한다. 여기서 deinit하면 exec 직전에 restoring manifest를 철거하게 된다.
    _ = try sh.host_manifest.publish(allocator, session_dir, .{
        .host_id = host_id,
        .build_id = product_build_id,
        .protocol_major = sh.protocol.version_major,
        .screen_codec_version = sh.screen_stream.codec_version,
        .upgrade_epoch = 4,
        .lifecycle = .restoring,
        .endpoint = socket_path,
    });
    if (setenv("MARU_SESSION_HOST_TEST_ONESHOT", "maru-test-only-v1", 1) != 0 or
        setenv("MARU_SESSION_HOST_ACTIVATION_MARKER", activation_marker.ptr, 1) != 0)
        return error.TestUnexpectedResult;
    closeExceptRestore(layout, capture.resources.len);
    const invocation: sh.entrypoint.RestoreInvocation = .{
        .role = .target,
        .session_dir = session_dir,
        .socket_path = socket_path,
        .host_id = host_id,
        .attempt_id = attempt_id,
        .layout = layout,
    };
    var buffers: sh.entrypoint.RestoreArgBuffers = .{};
    const raw = try sh.entrypoint.formatRestoreArgs(invocation, &buffers);
    var owned: [sh.entrypoint.max_invocation_args][:0]u8 = undefined;
    for (raw, 0..) |arg, index| owned[index] = try allocator.dupeZ(u8, arg);
    const argv = [_:null]?[*:0]const u8{
        target.path.ptr,
        sh.entrypoint.subcommand,
        owned[0].ptr,
        owned[1].ptr,
        owned[2].ptr,
        owned[3].ptr,
        owned[4].ptr,
        owned[5].ptr,
        owned[6].ptr,
    };
    _ = execv(target.path.ptr, &argv);
    return error.TestUnexpectedResult;
}

fn closeExceptRestore(layout: sh.upgrade_fd_layout.Layout, runtime_count: usize) void {
    var fd: c.fd_t = 3;
    while (fd < getdtablesize()) : (fd += 1) {
        var keep = fd == layout.primarySlot() or fd == layout.backupSlot() or
            fd == layout.ownerSlot();
        var index: usize = 0;
        while (!keep and index < runtime_count) : (index += 1)
            keep = fd == layout.runtimeSlot(index).?;
        if (!keep) _ = c.close(fd);
    }
}

fn openTruncatedUnlinkedCopy(owner_dir: [:0]const u8, bytes: []const u8) !c.fd_t {
    var path_buf: [1024]u8 = undefined;
    const path = try std.fmt.bufPrintZ(
        &path_buf,
        "{s}/nonempty-corrupt-primary",
        .{owner_dir},
    );
    _ = c.unlink(path.ptr);
    const writer = c.open(
        path.ptr,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true, .NOFOLLOW = true },
        @as(c.mode_t, 0o600),
    );
    if (writer < 0) return error.TestUnexpectedResult;
    var writer_open = true;
    defer {
        if (writer_open) _ = c.close(writer);
    }
    try writeExact(writer, bytes);
    if (c.ftruncate(writer, 0) != 0 or c.fsync(writer) != 0)
        return error.TestUnexpectedResult;
    _ = c.close(writer);
    writer_open = false;
    const reader = c.open(
        path.ptr,
        .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true },
        @as(c.mode_t, 0),
    );
    if (reader < 0) return error.TestUnexpectedResult;
    errdefer _ = c.close(reader);
    if (c.unlink(path.ptr) != 0) return error.TestUnexpectedResult;
    return reader;
}

fn connectExact(socket_path: [:0]const u8) !sh.client.Client {
    var attempt: usize = 0;
    while (attempt < 2_000) : (attempt += 1) {
        if (sh.client.Client.connect(std.testing.allocator, socket_path, .gui)) |client|
            return client
        else |_|
            _ = usleep(1000);
    }
    return error.TestUnexpectedResult;
}

fn expectOnlyRuntime(client: *sh.client.Client, runtime_id: u128) !void {
    var inventory = try client.runtimeInventory();
    switch (inventory) {
        .complete => |*complete| {
            defer complete.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(usize, 1), complete.runtime_ids.len);
            try std.testing.expectEqual(runtime_id, complete.runtime_ids[0]);
        },
        .unavailable => return error.TestUnexpectedResult,
    }
}

fn attachRuntime(client: *sh.client.Client, runtime_id: []const u8) !u64 {
    const params = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"runtime_id\":\"{s}\",\"mode\":\"controller\"}}",
        .{runtime_id},
    );
    defer std.testing.allocator.free(params);
    const response = try client.call("runtime.attach", params);
    defer std.testing.allocator.free(response);
    return sh.client.extractU64Field(response, "\"stream_id\":") orelse
        error.TestUnexpectedResult;
}

fn waitForMarker(
    client: *sh.client.Client,
    stream_id: u64,
    screen: *sh.screen_assembler.ScreenAssembler,
    marker: []const u8,
) !void {
    var attempt: usize = 0;
    while (attempt < 5_000) : (attempt += 1) {
        if (screenContains(screen, marker)) return;
        if (try client.readStreamBatch(stream_id)) |batch| {
            defer batch.deinit();
            if (batch.is_snapshot)
                try screen.applySnapshot(batch.bytes)
            else
                try screen.applyDelta(batch.bytes);
        }
        _ = usleep(1000);
    }
    return error.TestUnexpectedResult;
}

fn screenContains(screen: *const sh.screen_assembler.ScreenAssembler, marker: []const u8) bool {
    var row: u16 = 0;
    while (row < screen.rows_count) : (row += 1) {
        var bytes: [4096]u8 = undefined;
        var used: usize = 0;
        for (screen.rowRuns(row)) |run| {
            var count: u32 = 0;
            while (count < run.count) : (count += 1) {
                if (run.grapheme.len > bytes.len - used) break;
                @memcpy(bytes[used..][0..run.grapheme.len], run.grapheme);
                used += run.grapheme.len;
            }
        }
        if (std.mem.indexOf(u8, bytes[0..used], marker) != null) return true;
    }
    return false;
}

fn waitForRuntimeGone(
    client: *sh.client.Client,
    runtime_id: u128,
    host_pid: c.pid_t,
    child_pid: c.pid_t,
) !void {
    var attempt: usize = 0;
    while (attempt < 5_000) : (attempt += 1) {
        var inventory = try client.runtimeInventory();
        const empty = switch (inventory) {
            .complete => |*complete| blk: {
                defer complete.deinit(std.testing.allocator);
                if (std.mem.indexOfScalar(u128, complete.runtime_ids, runtime_id) != null)
                    break :blk false;
                break :blk complete.runtime_ids.len == 0;
            },
            .unavailable => false,
        };
        if (empty and !directChildPresent(host_pid, child_pid)) return;
        _ = usleep(1000);
    }
    return error.TestUnexpectedResult;
}

fn waitForFile(path: [:0]const u8, child: c.pid_t) !void {
    var attempt: usize = 0;
    while (attempt < 10_000) : (attempt += 1) {
        var status: c_int = undefined;
        const waited = c.waitpid(child, &status, c.W.NOHANG);
        if (waited == child) return error.TestUnexpectedResult;
        if (waited < 0 and posix.errno(waited) != .INTR)
            return error.TestUnexpectedResult;
        if (c.access(path.ptr, c.F_OK) == 0) return;
        _ = usleep(1000);
    }
    return error.TestUnexpectedResult;
}

fn directChildPresent(parent: c.pid_t, child: c.pid_t) bool {
    var children: [64]c.pid_t = undefined;
    @memset(&children, 0);
    const count = proc_listchildpids(parent, &children, @intCast(@sizeOf(@TypeOf(children))));
    if (count <= 0) return false;
    const len = @min(children.len, @as(usize, @intCast(count)));
    return std.mem.indexOfScalar(c.pid_t, children[0..len], child) != null;
}

fn peerPid(fd: c.fd_t) !c.pid_t {
    var pid: c.pid_t = 0;
    var len: c.socklen_t = @sizeOf(c.pid_t);
    if (c.getsockopt(fd, sol_local, local_peerpid, &pid, &len) != 0 or
        len != @sizeOf(c.pid_t) or pid <= 0)
        return error.TestUnexpectedResult;
    return pid;
}

fn readExact(fd: c.fd_t, out: []u8) !void {
    var used: usize = 0;
    while (used < out.len) {
        const count = c.read(fd, out.ptr + used, out.len - used);
        if (count < 0 and posix.errno(count) == .INTR) continue;
        if (count <= 0) return error.TestUnexpectedResult;
        used += @intCast(count);
    }
}

fn writeExact(fd: c.fd_t, bytes: []const u8) !void {
    var used: usize = 0;
    while (used < bytes.len) {
        const count = c.write(fd, bytes.ptr + used, bytes.len - used);
        if (count < 0 and posix.errno(count) == .INTR) continue;
        if (count <= 0) return error.TestUnexpectedResult;
        used += @intCast(count);
    }
}

fn waitChild(pid: c.pid_t, expect_success: bool) !void {
    var status: c_int = undefined;
    while (true) {
        const waited = c.waitpid(pid, &status, 0);
        if (waited == pid) break;
        if (waited < 0 and posix.errno(waited) == .INTR) continue;
        return error.TestUnexpectedResult;
    }
    if (expect_success) try std.testing.expectEqual(@as(c_int, 0), status);
}

fn stopChild(pid: c.pid_t) void {
    _ = c.kill(pid, posix.SIG.TERM);
    var status: c_int = undefined;
    while (true) {
        const waited = c.waitpid(pid, &status, 0);
        if (waited == pid) return;
        if (waited < 0 and posix.errno(waited) == .INTR) continue;
        return;
    }
}
