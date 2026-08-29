//! Public attach의 secure discovery와 transport probe 사이의 순수 deterministic reduction seam.
//! Registry/path syscall과 one-shot `runtime.get` wire는 제품 adapter가 소유한다.

const std = @import("std");
const attach_cli = @import("maru").cli.attach;
const compatibility = @import("compatibility.zig");
const host_manifest = @import("host_manifest.zig");
const recovery_discovery = @import("recovery_discovery.zig");

pub const ProbeOps = struct {
    context: *anyopaque,
    probe: *const fn (
        context: *anyopaque,
        descriptor: host_manifest.Descriptor,
        runtime_id: u128,
    ) attach_cli.Probe,
};

pub const Result = union(enum) {
    /// Index into the caller-owned discovery slice. This reducer intentionally does not return a
    /// Descriptor because its build_id/endpoint slices borrow the Manifest. The product resolver
    /// must clone and stat-pin it while discovery remains alive.
    selected_index: usize,
    failed: attach_cli.ExitCode,
};

pub fn resolve(
    entries: []const recovery_discovery.Entry,
    runtime_id: u128,
    ops: ProbeOps,
) Result {
    // **죽은 줄은 세지 않는다.** 상한은 "살아 있을 수 있는 host" 를 세는 것이고, 그 예산은 discovery 가
    // 이미 매긴다(`recovery_discovery` — owner lease 가 free 인 줄은 예산을 안 쓴다: 그것들은 정리할 코드가
    // 없어 반드시 쌓이므로, 세면 산 host 를 밀어낸다). 여기서 **emit 된 줄 전체**를 그 상한에 다시 대면 그
    // 설계를 그대로 뒤집는다 — 실측: 레지스트리에 host 줄 99 개(대부분 죽음)가 쌓인 기계에서 `runtime list`
    // 는 산 runtime 을 그대로 냈는데 `attach` 는 **모든** runtime 에 대해 `denied` 였다. 폰에서는 그것이
    // "화면이 안 온다" 로만 보였다.
    //
    // 상한 자체는 남는다 — 아래 `eligible` 이 후보 배열을 넘기 전에 fail-closed 로 접는다.
    if (runtime_id == 0) return .{ .failed = .denied };

    var descriptors: [recovery_discovery.max_hosts]host_manifest.Descriptor = undefined;
    var entry_indices: [recovery_discovery.max_hosts]usize = undefined;
    var eligible: usize = 0;
    var previous_host_id: u128 = 0;
    for (entries, 0..) |entry, entry_index| switch (entry) {
        .unavailable => |unavailable| {
            if (unavailable.host_id <= previous_host_id) return .{ .failed = .denied };
            previous_host_id = unavailable.host_id;
            // A free owner lease proves this registry row is not live. Invalid manifest or an
            // indeterminate lease can still hide a supported live host, so absence is unproven.
            if (unavailable.reason != .lease_free) return .{ .failed = .denied };
        },
        .candidate => |candidate| {
            const descriptor = candidate.manifest.descriptor();
            if (descriptor.host_id <= previous_host_id or descriptor.lifecycle != .ready)
                return .{ .failed = .denied };
            previous_host_id = descriptor.host_id;
            const profile = compatibility.profileForMajor(descriptor.protocol_major) orelse
                continue;
            if (profile.screen_codec_version != descriptor.screen_codec_version)
                return .{ .failed = .protocol };
            // discovery 예산(`max_hosts`)이 후보 수를 이미 묶지만, 그 계약이 깨지면 여기서 버퍼를 넘는다.
            // 넘길 바에는 거절한다 — 자르면 "그 host 에 없다" 를 증명 못 한 채 없다고 말하게 된다.
            if (eligible == descriptors.len) return .{ .failed = .denied };
            descriptors[eligible] = descriptor;
            entry_indices[eligible] = entry_index;
            eligible += 1;
        },
    };

    // Structural/authority preflight is all-or-none. Probing a prefix before discovering an
    // unsorted/uncertain suffix makes observable admin connections for a request we must reject.
    var evidence: [recovery_discovery.max_hosts]attach_cli.Probe = undefined;
    for (descriptors[0..eligible], 0..) |descriptor, index|
        evidence[index] = ops.probe(ops.context, descriptor, runtime_id);
    const reduced = attach_cli.resolve(evidence[0..eligible]);
    return switch (reduced) {
        .failed => |code| .{ .failed = code },
        .selected => |index| .{ .selected_index = entry_indices[index] },
    };
}

const TestProbe = struct {
    evidence: []const attach_cli.Probe,
    calls: usize = 0,

    fn call(
        context: *anyopaque,
        _: host_manifest.Descriptor,
        _: u128,
    ) attach_cli.Probe {
        const self: *TestProbe = @ptrCast(@alignCast(context));
        const result = self.evidence[self.calls];
        self.calls += 1;
        return result;
    }

    fn ops(self: *TestProbe) ProbeOps {
        return .{ .context = self, .probe = call };
    }
};

fn manifest(host_id: u128, major: u16, codec: u16) host_manifest.Manifest {
    return .{
        .allocator = std.testing.allocator,
        .host_id = host_id,
        .build_id = @constCast("sha256:test"),
        .protocol_major = major,
        .screen_codec_version = codec,
        .upgrade_epoch = 1,
        .lifecycle = .ready,
        .endpoint = @constCast("/tmp/test.sock"),
    };
}

test "attach resolver probes every supported live descriptor and selects exact one" {
    const first = manifest(1, 1, 1);
    const second = manifest(2, 2, 2);
    const entries = [_]recovery_discovery.Entry{
        .{ .candidate = .{ .manifest = first } },
        .{ .candidate = .{ .manifest = second } },
    };
    var probe = TestProbe{ .evidence = &.{ .runtime_not_found, .match } };
    const result = resolve(&entries, 0xaa, probe.ops());
    try std.testing.expectEqual(@as(usize, 1), result.selected_index);
    try std.testing.expectEqual(@as(usize, 2), probe.calls);
}

test "attach resolver never publishes partial membership evidence" {
    const first = manifest(1, 1, 1);
    const second = manifest(2, 2, 2);
    const entries = [_]recovery_discovery.Entry{
        .{ .candidate = .{ .manifest = first } },
        .{ .candidate = .{ .manifest = second } },
    };
    var probe = TestProbe{ .evidence = &.{ .match, .busy } };
    try std.testing.expectEqual(
        attach_cli.ExitCode.busy,
        resolve(&entries, 0xaa, probe.ops()).failed,
    );
    try std.testing.expectEqual(@as(usize, 2), probe.calls);
}

test "attach resolver distinguishes no compatible host and confirmed runtime absence" {
    const unsupported = manifest(1, 77, 77);
    const unsupported_entries = [_]recovery_discovery.Entry{
        .{ .candidate = .{ .manifest = unsupported } },
    };
    var no_probe = TestProbe{ .evidence = &.{} };
    try std.testing.expectEqual(
        attach_cli.ExitCode.host_unavailable,
        resolve(&unsupported_entries, 0xaa, no_probe.ops()).failed,
    );
    try std.testing.expectEqual(@as(usize, 0), no_probe.calls);

    const current = manifest(1, 2, 2);
    const current_entries = [_]recovery_discovery.Entry{
        .{ .candidate = .{ .manifest = current } },
    };
    var absent = TestProbe{ .evidence = &.{.runtime_not_found} };
    try std.testing.expectEqual(
        attach_cli.ExitCode.runtime_not_found,
        resolve(&current_entries, 0xaa, absent.ops()).failed,
    );
}

test "attach resolver rejects uncertain or noncanonical registry evidence before probe" {
    const uncertain = [_]recovery_discovery.Entry{
        .{ .unavailable = .{ .host_id = 1, .reason = .lease_unknown } },
    };
    var no_probe = TestProbe{ .evidence = &.{} };
    try std.testing.expectEqual(
        attach_cli.ExitCode.denied,
        resolve(&uncertain, 0xaa, no_probe.ops()).failed,
    );

    const second = manifest(2, 2, 2);
    const first = manifest(1, 2, 2);
    const unsorted = [_]recovery_discovery.Entry{
        .{ .candidate = .{ .manifest = second } },
        .{ .candidate = .{ .manifest = first } },
    };
    try std.testing.expectEqual(
        attach_cli.ExitCode.denied,
        resolve(&unsorted, 0xaa, no_probe.ops()).failed,
    );
    try std.testing.expectEqual(@as(usize, 0), no_probe.calls);
}

test "죽은 host 줄이 상한을 넘어도 산 host 는 찾는다 — 쌓인 시체가 attach 를 못 막는다" {
    // 실측 재현: 레지스트리에 host 줄이 오래 쌓인 기계(99 개, 대부분 owner lease free)에서 `attach` 가
    // 모든 runtime 에 대해 denied 였다. 여기서는 상한(16) 을 넘기는 최소 모양 — 죽은 줄 16 + 산 host 1.
    var entries: [recovery_discovery.max_hosts + 1]recovery_discovery.Entry = undefined;
    for (0..recovery_discovery.max_hosts) |i|
        entries[i] = .{ .unavailable = .{ .host_id = @intCast(i + 1), .reason = .lease_free } };
    const live = manifest(recovery_discovery.max_hosts + 1, 2, 2);
    entries[recovery_discovery.max_hosts] = .{ .candidate = .{ .manifest = live } };

    var probe = TestProbe{ .evidence = &.{.match} };
    const result = resolve(&entries, 0xaa, probe.ops());
    try std.testing.expectEqual(@as(usize, recovery_discovery.max_hosts), result.selected_index);
    // **산 host 하나만 두드린다** — 죽은 줄은 연결을 만들지 않는다.
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
}

test "죽은 줄이 많아도 확실치 않은 줄 하나면 여전히 전부 거절이다 — 완화한 것은 상한뿐" {
    var entries: [recovery_discovery.max_hosts + 2]recovery_discovery.Entry = undefined;
    for (0..recovery_discovery.max_hosts) |i|
        entries[i] = .{ .unavailable = .{ .host_id = @intCast(i + 1), .reason = .lease_free } };
    // 이 줄은 산 host 를 가리고 있을 수 있다(§ 죽음의 증거가 아님) → all-or-none.
    entries[recovery_discovery.max_hosts] = .{ .unavailable = .{
        .host_id = recovery_discovery.max_hosts + 1,
        .reason = .lease_unknown,
    } };
    const live = manifest(recovery_discovery.max_hosts + 2, 2, 2);
    entries[recovery_discovery.max_hosts + 1] = .{ .candidate = .{ .manifest = live } };

    var no_probe = TestProbe{ .evidence = &.{} };
    try std.testing.expectEqual(
        attach_cli.ExitCode.denied,
        resolve(&entries, 0xaa, no_probe.ops()).failed,
    );
    try std.testing.expectEqual(@as(usize, 0), no_probe.calls);
}
