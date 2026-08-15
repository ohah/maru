const std = @import("std");

test "CR3a-2c3d C3-3b2a process seal migration boundary" {
    const allocator = std.testing.allocator;
    const service = try readSource(allocator, "src/platform/macos/session_host/process_seal_service.zig");
    defer allocator.free(service);
    const identity = try readSource(allocator, "src/platform/macos/session_host/operation_thread_identity.zig");
    defer allocator.free(identity);
    const slot = try readSource(allocator, "src/platform/macos/session_host/client_slot.zig");
    defer allocator.free(slot);
    const process_identity = try readSource(allocator, "src/platform/macos/session_host/process_identity.zig");
    defer allocator.free(process_identity);
    const client = try readSource(allocator, "src/platform/macos/session_host/client.zig");
    defer allocator.free(client);
    const transport = try readSource(allocator, "src/platform/macos/session_host/generation_transport.zig");
    defer allocator.free(transport);
    const snapshot_owner = try readSource(allocator, "src/platform/macos/session_host/initial_snapshot_owner.zig");
    defer allocator.free(snapshot_owner);
    const batch_registry = try readSource(allocator, "src/platform/macos/session_host/generation_batch_registry.zig");
    defer allocator.free(batch_registry);
    const quarantine = try readSource(allocator, "src/platform/macos/session_host/ended_purge_quarantine.zig");
    defer allocator.free(quarantine);
    const shutdown_attempt = try readSource(allocator, "src/platform/macos/session_host/shutdown_attempt_authority.zig");
    defer allocator.free(shutdown_attempt);
    const shutdown_connector = try readSource(allocator, "src/platform/macos/session_host/shutdown_admin_connector.zig");
    defer allocator.free(shutdown_connector);
    const fresh_exec_helper = try readSource(allocator, "tests/session_host_process_seal_fresh_exec_helper.zig");
    defer allocator.free(fresh_exec_helper);
    const fresh_exec_oracle = try readSource(allocator, "tests/session_host_process_seal_fresh_exec_oracle.zig");
    defer allocator.free(fresh_exec_oracle);

    try std.testing.expectEqual(@as(usize, 0), count(identity, "capability_key_secret"));
    try std.testing.expectEqual(@as(usize, 0), count(identity, "capability_key_secret_initialized"));
    try std.testing.expectEqual(@as(usize, 0), try countSessionHostSources(allocator, "maru.capability.registry-key.v1"));
    try std.testing.expectEqual(@as(usize, 0), try countSessionHostSources(allocator, "pid) ^"));
    try std.testing.expectEqual(@as(usize, 1), count(identity, "return process_seal_service.currentProcessId();"));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "return process_seal_service.currentProcessId();"));
    try std.testing.expectEqual(@as(usize, 1), count(service, "return process_identity.currentProcessId();"));
    try std.testing.expectEqual(@as(usize, 1), count(process_identity, ".macos, .linux => @intCast(std.c.getpid()),"));
    try std.testing.expectEqual(@as(usize, 7), try countSessionHostSources(allocator, "@import(\"process_identity.zig\")"));
    try std.testing.expectEqual(@as(usize, 1), count(service, "@import(\"process_identity.zig\")"));
    try std.testing.expectEqual(@as(usize, 1), count(transport, "@import(\"process_identity.zig\")"));
    try std.testing.expectEqual(@as(usize, 1), count(snapshot_owner, "@import(\"process_identity.zig\")"));
    try std.testing.expectEqual(@as(usize, 1), count(batch_registry, "@import(\"process_identity.zig\")"));
    try std.testing.expectEqual(@as(usize, 1), count(quarantine, "@import(\"process_identity.zig\")"));
    const fence_identity = client[std.mem.indexOf(u8, client, "fn identityMatches(") orelse
        return error.TestUnexpectedResult ..];
    const fence_identity_end = std.mem.indexOf(u8, fence_identity, "\n    }\n};") orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(
        @as(usize, 1),
        count(fence_identity[0..fence_identity_end], "operation_thread_identity.currentProcessId()"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        count(client, "const actual_pid = operation_thread_identity.currentProcessId();"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        count(client, "const actual_pid: u64 = operation_thread_identity.currentProcessId();"),
    );
    inline for (.{ client, transport, snapshot_owner, batch_registry, quarantine }) |authority_source| {
        try std.testing.expectEqual(@as(usize, 0), count(authority_source, "if (builtin.os.tag == .macos) @intCast(c.getpid()) else 1"));
        try std.testing.expectEqual(@as(usize, 0), count(authority_source, "if (builtin.os.tag == .macos) @intCast(std.c.getpid()) else 1"));
    }
    try std.testing.expectEqual(@as(usize, 0), count(quarantine, "std.c.getpid()"));
    // b2b3 adds the neutral inline runtime lifetime owner as the third typed consumer.
    // b2b3 adds pending preparation, lifetime, and runtime consumers to the three b2a owners.
    // C3-3b3의 final-address receipt/permit owner 7개도 service를 모듈당 한 번만 가져오며 inline 중복은 허용하지 않는다.
    // C3-3b5 close authority, backend admission, window close graph가 같은 process-seal 경계를 직접 사용한다.
    // C3-3b6 shutdown owner와 2d2 terminal handoff registry도 같은 process domain을 직접 검증한다.
    // CR0b HostAdapter·publisher registry·runtime·composite coordinator·GUI process owner와 daemon bootstrap이 같은 process domain을 직접 검증한다.
    // CR1 reconnect scheduler가 prepared dispatch의 post-claim fail-stop을 같은 process seal owner에 추가한다.
    try std.testing.expectEqual(@as(usize, 28), try countSessionHostSources(allocator, "@import(\"process_seal_service.zig\")"));
    const publisher_registry = try readSource(allocator, "src/platform/macos/session_host/incident_publisher_registry.zig");
    defer allocator.free(publisher_registry);
    try std.testing.expectEqual(@as(usize, 1), count(publisher_registry, "@import(\"process_seal_service.zig\")"));
    try std.testing.expectEqual(@as(usize, 0), count(publisher_registry, "client.zig"));
    try std.testing.expectEqual(@as(usize, 0), count(publisher_registry, "incident_runtime.zig"));
    const incident_runtime = try readSource(allocator, "src/platform/macos/session_host/incident_runtime.zig");
    defer allocator.free(incident_runtime);
    try std.testing.expectEqual(@as(usize, 1), count(incident_runtime, "@import(\"process_seal_service.zig\")"));
    // aggregate issuer와 runtime/service generation issuer가 각각 자기 publication 전에 fail-stop한다.
    try std.testing.expectEqual(@as(usize, 2), count(incident_runtime, "fatalIntegrity(.counter_exhausted)"));
    const daemon = try readSource(allocator, "src/platform/macos/session_host/daemon.zig");
    defer allocator.free(daemon);
    try std.testing.expectEqual(@as(usize, 1), count(daemon, "@import(\"process_seal_service.zig\")"));
    try std.testing.expectEqual(@as(usize, 1), count(batch_registry, "@import(\"process_seal_service.zig\")"));
    try std.testing.expectEqual(@as(usize, 1), count(shutdown_attempt, "@import(\"process_seal_service.zig\")"));
    try std.testing.expectEqual(@as(usize, 1), count(shutdown_connector, "@import(\"process_seal_service.zig\")"));
    try std.testing.expectEqual(@as(usize, 1), count(identity, "@import(\"process_seal_service.zig\")"));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "@import(\"process_seal_service.zig\")"));
    try std.testing.expectEqual(@as(usize, 0), count(service, "pub fn raw"));
    try std.testing.expectEqual(@as(usize, 0), count(service, "RemoteRuntime"));
    try std.testing.expectEqual(@as(usize, 0), count(service, "PendingEventOwner"));
    try std.testing.expectEqual(@as(usize, 0), count(service, "EventCorrelation"));
    try std.testing.expectEqual(@as(usize, 0), count(service, "std.mem.Allocator"));
    try std.testing.expectEqual(@as(usize, 0), count(service, "@panic"));
    try std.testing.expectEqual(@as(usize, 0), count(service, "MARU_PROCESS_SEAL_FRESH_EXEC"));
    try std.testing.expectEqual(@as(usize, 0), count(service, "std.c.getenv"));
    inline for (.{
        "pub fn generateProcessNonce()",
        "pub fn prepare(pid:",
        "pub fn commitReady(receipt:",
        "pub fn validateReady(pid:",
        "pub fn capabilityRegistryKey(",
    }) |signature| try std.testing.expectEqual(@as(usize, 1), count(service, signature));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "process_seal_service.generateProcessNonce()"));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "process_seal_service.prepare(pid, nonce)"));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "process_seal_service.validateReady(pid,"));
    try std.testing.expect(count(slot, "process_seal_service.commitReady(prepared_seal)") == 1);
    try std.testing.expect(count(identity, "process_seal_service.capabilityRegistryKey(") == 1);
    inline for (.{
        "process_seal_service.generateProcessNonce()",
        "process_seal_service.prepare(pid, nonce)",
        "process_seal_service.commitReady(receipt)",
        "process_seal_service.validateReady(pid, nonce)",
        "process_seal_service.capabilityRegistryKey(pid, nonce, input)",
    }) |marker| try std.testing.expect(count(fresh_exec_helper, marker) >= 1);
    try std.testing.expectEqual(@as(usize, 2), count(fresh_exec_oracle, "@embedFile("));
    try std.testing.expectEqual(@as(usize, 1), count(fresh_exec_oracle, "first != second"));
}

fn countSessionHostSources(allocator: std.mem.Allocator, needle: []const u8) !usize {
    var dir = try std.Io.Dir.cwd().openDir(
        std.testing.io,
        "src/platform/macos/session_host",
        .{ .iterate = true },
    );
    defer dir.close(std.testing.io);
    var walker = try posixWalk(dir, allocator);
    defer walker.deinit();
    var total: usize = 0;
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const path = try std.fmt.allocPrint(
            allocator,
            "src/platform/macos/session_host/{s}",
            .{entry.path},
        );
        defer allocator.free(path);
        const source = try readSource(allocator, path);
        defer allocator.free(source);
        total += count(source, needle);
    }
    return total;
}

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![:0]u8 {
    return std.Io.Dir.cwd().readFileAllocOptions(
        std.testing.io,
        path,
        allocator,
        .limited(8 * 1024 * 1024),
        .of(u8),
        0,
    );
}

fn count(haystack: []const u8, needle: []const u8) usize {
    var total: usize = 0;
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, offset, needle)) |found| {
        total += 1;
        offset = found + needle.len;
    }
    return total;
}

// ── 경로 구분자 정규화 (호스트 이식) ─────────────────────────────────────────────────────────────
// `std.Io.Dir.Walker`의 `entry.path`는 **호스트 native 구분자**를 쓴다 — Windows에서는 `platform\macos\x.zig`.
// 이 파일의 스캐너들은 그 경로를 `"platform/macos/x.zig"` 같은 **`/` 리터럴과 비교**하므로, 그대로 두면 제외
// 목록과 매칭이 조용히 전부 빗나간다(실측: 제외됐어야 할 파일이 집계에 섞여 boundary 카운트가 부풀었다 —
// 컴파일도 통과하고 macOS CI도 초록인 채로 Windows에서만 틀렸다). 그래서 walker를 감싸 경로를 `/`로 정규화한다.
// POSIX 호스트에서는 native 구분자가 이미 `/`라 `next`가 std walker를 그대로 통과시킨다(무동작·무비용).
const PosixWalker = struct {
    inner: std.Io.Dir.Walker,
    path_buf: [std.fs.max_path_bytes]u8 = undefined,

    fn next(self: *PosixWalker, io: std.Io) !?std.Io.Dir.Walker.Entry {
        var entry = (try self.inner.next(io)) orelse return null;
        if (std.fs.path.sep == '/') return entry;
        // 잘라내면 "제외 목록에 없는 경로"로 조용히 바뀌어 게이트가 거짓 초록이 된다 — 시끄럽게 실패시킨다.
        if (entry.path.len >= self.path_buf.len) return error.NameTooLong;
        for (entry.path, 0..) |byte, i|
            self.path_buf[i] = if (byte == std.fs.path.sep) '/' else byte;
        self.path_buf[entry.path.len] = 0;
        entry.path = self.path_buf[0..entry.path.len :0];
        return entry;
    }

    fn deinit(self: *PosixWalker) void {
        self.inner.deinit();
    }
};

fn posixWalk(dir: std.Io.Dir, allocator: std.mem.Allocator) !PosixWalker {
    return .{ .inner = try dir.walk(allocator) };
}
