//! C3-3b2b1 neutral cleanup-seal contract tests.
//!
//! These tests pin the pointer-free ABI and canonical hashing before process-secret integration.
//! The session host relies on this layer to reject ambiguous cleanup ownership without importing
//! RuntimeObservation or PTY types into the process-seal service.

const std = @import("std");
const builtin = @import("builtin");
const seal = @import("event_cleanup_seal");

fn emptyDecisionProgress() seal.CleanupProgressInput {
    var value: seal.CleanupProgressInput = undefined;
    value.retained_observation_digest = [_]u8{0} ** 32;
    value.decision = .{};
    return value;
}

fn descriptor(address: u64) seal.CleanupDescriptor {
    return .{
        .present = 1,
        .address = address,
        .length_bytes = 8,
        .capacity_bytes = 8,
        .alignment_log2 = 3,
        .allocator_ptr = 0x8000,
        .allocator_vtable = 0x9000,
    };
}

fn observationInput() seal.ObservationCleanupDigestInput {
    var graph: seal.ObservationCleanupGraph = .{};
    graph.cwd = descriptor(0x1000);
    return .{
        .availability = 1,
        .revision = 2,
        .observer_generation = 3,
        .title_generation = 4,
        .cols = 80,
        .rows = 24,
        .ssh_remote_dest_present = 0,
        .semantic_state = 1,
        .alt_active = 0,
        .app_cursor_keys = 0,
        .app_keypad = 0,
        .kitty_flags = 0,
        .alternate_scroll = 0,
        .mouse_tracking = 0,
        .mouse_tracking_mode = 0,
        .bracketed_paste = 1,
        .bell_count = 5,
        .clipboard_write_seq = 6,
        .clipboard_read_seq = 7,
        .foreground_available = 0,
        .foreground_pgid_present = 0,
        .foreground_pgid = 0,
        .foreground_process_count = 0,
        .graph = graph,
        .cwd_digest = seal.observationStringDigest(.cwd, "/tmp"),
        .cwd_host_digest = [_]u8{0} ** 32,
        .window_title_digest = [_]u8{0} ** 32,
        .ssh_remote_dest_digest = [_]u8{0} ** 32,
        .clipboard_read_target_digest = [_]u8{0} ** 32,
        .foreground_processes_digest = [_]u8{0} ** 32,
        .agent_progress_digest = [_]u8{0} ** 32,
    };
}

test "C3-3b2b1 cleanup seal ABI and role domains are deterministic" {
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(seal.CleanupSeal));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(seal.CleanupPhase.preparation));
    try std.testing.expectEqual(@as(u8, 8), @intFromEnum(seal.CleanupRole.agent_progress));

    const cwd = seal.observationStringDigest(.cwd, "same");
    try std.testing.expectEqualSlices(u8, &cwd, &seal.observationStringDigest(.cwd, "same"));
    try std.testing.expect(!std.mem.eql(
        u8,
        &cwd,
        &seal.observationStringDigest(.cwd_host, "same"),
    ));
}

test "C3-3b2b1 cleanup seal foreground projection hashes active bytes only" {
    var input: seal.ForegroundProcessesDigestInput = .{};
    input.count = 1;
    input.entries[0].pid = 41;
    input.entries[0].len = 5;
    @memcpy(input.entries[0].bytes[0..5], "codex");
    const first = seal.foregroundProcessesDigest(input);
    try std.testing.expectEqualSlices(u8, &first, &seal.foregroundProcessesDigest(input));

    input.entries[0].bytes[5] = 1;
    try std.testing.expect(!seal.testing.foregroundProcessesInputCanonical(input));
    input.entries[0].bytes[5] = 0;
    input.entries[0].len = 129;
    try std.testing.expect(!seal.testing.foregroundProcessesInputCanonical(input));
    input = .{};
    input.count = 65;
    try std.testing.expect(!seal.testing.foregroundProcessesInputCanonical(input));
    input = .{};
    input.entries[63].pid = 1;
    try std.testing.expect(!seal.testing.foregroundProcessesInputCanonical(input));
}

test "C3-3b2b1 cleanup seal descriptor graph rejects ambiguous ownership" {
    const absent: seal.CleanupDescriptor = .{};
    try std.testing.expect(seal.testing.cleanupDescriptorCanonical(absent));

    var present: seal.CleanupDescriptor = .{
        .present = 1,
        .address = 0x1000,
        .length_bytes = 8,
        .capacity_bytes = 8,
        .alignment_log2 = 3,
        .allocator_ptr = 0x2000,
        .allocator_vtable = 0x3000,
    };
    try std.testing.expect(seal.testing.cleanupDescriptorCanonical(present));
    present.capacity_bytes = 9;
    try std.testing.expect(!seal.testing.cleanupDescriptorCanonical(present));
    present.capacity_bytes = 8;
    present.address = std.math.maxInt(u64) - 3;
    try std.testing.expect(!seal.testing.cleanupDescriptorCanonical(present));
    present = descriptor(0x1000);
    present.present = 2;
    try std.testing.expect(!seal.testing.cleanupDescriptorCanonical(present));
    present = descriptor(0x1000);
    present.allocator_ptr = 0;
    try std.testing.expect(!seal.testing.cleanupDescriptorCanonical(present));
    present = descriptor(0x1001);
    try std.testing.expect(!seal.testing.cleanupDescriptorCanonical(present));
    present = descriptor(0x1000);
    present.alignment_log2 = 64;
    try std.testing.expect(!seal.testing.cleanupDescriptorCanonical(present));
    var forged_absent = absent;
    forged_absent.allocator_vtable = 1;
    try std.testing.expect(!seal.testing.cleanupDescriptorCanonical(forged_absent));
}

test "C3-3b2b1 cleanup seal progress follows descriptor-derived reverse schedule" {
    var graph: seal.ObservationCleanupGraph = .{};
    graph.cwd = .{
        .present = 1,
        .address = 0x1000,
        .length_bytes = 1,
        .capacity_bytes = 1,
        .alignment_log2 = 0,
        .allocator_ptr = 0x2000,
        .allocator_vtable = 0x3000,
    };
    const plan: seal.CleanupPlanInput = .{ .committed_observation = .{
        .old_observation = graph,
    } };
    const initial = seal.initialProgress(plan);
    try std.testing.expectEqual(seal.CleanupStep.ready, initial.step);
    try std.testing.expectEqual(seal.CleanupRole.cwd, initial.next_role);
    try std.testing.expectEqual(@as(u8, 0x7e), initial.completed_mask);
    try std.testing.expect(seal.testing.progressCanonical(plan, initial));

    var forged = initial;
    forged.completed_mask = 0;
    try std.testing.expect(!seal.testing.progressCanonical(plan, forged));
}

test "C3-3b2b1 cleanup seal progress accepts only the exact sparse reverse prefix" {
    var graph: seal.ObservationCleanupGraph = .{};
    graph.cwd = descriptor(0x1000);
    graph.window_title = descriptor(0x2000);
    graph.agent_progress = descriptor(0x3000);
    const plan: seal.CleanupPlanInput = .{ .committed_observation = .{
        .old_observation = graph,
    } };

    var state = seal.initialProgress(plan);
    try std.testing.expectEqual(seal.CleanupRole.agent_progress, state.next_role);
    try std.testing.expect(seal.testing.progressCanonical(plan, state));

    // Completing a lower role before the advertised highest role is not a prefix.
    var forged = state;
    forged.step = .freed;
    try std.testing.expect(!seal.testing.progressCanonical(plan, forged));
    forged = state;
    forged.completed_mask |= 1 << 0;
    try std.testing.expect(!seal.testing.progressCanonical(plan, forged));
    forged = state;
    forged.completed_mask |= 1 << 2;
    try std.testing.expect(!seal.testing.progressCanonical(plan, forged));

    state.completed_mask |= 1 << 6;
    state.step = .freed;
    state.next_role = .window_title;
    try std.testing.expect(seal.testing.progressCanonical(plan, state));
    state.completed_mask |= 1 << 2;
    state.next_role = .cwd;
    try std.testing.expect(seal.testing.progressCanonical(plan, state));
    state.completed_mask |= 1 << 0;
    state.next_role = .none;
    try std.testing.expect(seal.testing.progressCanonical(plan, state));
    state.step = .finished;
    try std.testing.expect(seal.testing.progressCanonical(plan, state));

    const empty: seal.CleanupPlanInput = .{ .committed_observation = .{
        .old_observation = .{},
    } };
    var forged_empty = seal.initialProgress(empty);
    try std.testing.expectEqual(seal.CleanupStep.finished, forged_empty.step);
    forged_empty.step = .freed;
    try std.testing.expect(!seal.testing.progressCanonical(empty, forged_empty));

    // These literals are the stable raw ABI oracle. Semantic PreparedDecision parity is exercised
    // separately through the typed sealProjection path in pending_event_preparation.zig.
    const canonical_decisions = [_]struct {
        retained_observation: bool = false,
        decision: @TypeOf(emptyDecisionProgress().decision),
    }{
        .{ .decision = .{} },
        .{ .decision = .{ .bound_raw = 1, .prepared_tag_raw = 0 } },
        .{ .decision = .{ .bound_raw = 1, .prepared_tag_raw = 1 } },
        .{ .decision = .{ .bound_raw = 1, .prepared_tag_raw = 2 } },
        .{ .decision = .{ .bound_raw = 1, .prepared_tag_raw = 3 } },
        .{ .decision = .{ .bound_raw = 1, .prepared_tag_raw = 4, .cols = 80, .rows = 24, .semantic_generation = 1 } },
        .{ .decision = .{ .bound_raw = 1, .prepared_tag_raw = 5 } },
        .{ .retained_observation = true, .decision = .{ .bound_raw = 1, .prepared_tag_raw = 6 } },
        .{ .decision = .{ .bound_raw = 1, .prepared_tag_raw = 7, .effect_tag_raw = 2, .semantic_generation = 1 } },
        .{ .decision = .{ .bound_raw = 1, .prepared_tag_raw = 8, .effect_tag_raw = 1, .failure_raw = 1, .connection_reason_raw = 9 } },
        .{ .decision = .{ .bound_raw = 1, .prepared_tag_raw = 8, .effect_tag_raw = 1, .failure_raw = 2, .connection_reason_raw = 9 } },
        .{ .decision = .{ .bound_raw = 1, .prepared_tag_raw = 8, .effect_tag_raw = 1, .failure_raw = 3, .connection_reason_raw = 12 } },
        .{ .decision = .{ .bound_raw = 1, .prepared_tag_raw = 8, .failure_raw = 4 } },
    };
    for (canonical_decisions) |entry| {
        var decision = emptyDecisionProgress();
        decision.decision = entry.decision;
        if (entry.retained_observation) decision.retained_observation_digest[0] = 1;
        try std.testing.expect(seal.testing.decisionProjectionCanonical(decision));
    }

    var decision = emptyDecisionProgress();
    decision.decision.bound_raw = 2;
    try std.testing.expect(!seal.testing.decisionProjectionCanonical(decision));
    decision.decision = .{ .bound_raw = 1, .prepared_tag_raw = 4, .cols = 1, .rows = 24 };
    try std.testing.expect(!seal.testing.decisionProjectionCanonical(decision));
    decision.decision.cols = 80;
    decision.decision.rows = 0;
    try std.testing.expect(!seal.testing.decisionProjectionCanonical(decision));
    decision.decision = .{ .bound_raw = 1, .prepared_tag_raw = 8, .effect_tag_raw = 1, .failure_raw = 1, .connection_reason_raw = 12 };
    try std.testing.expect(!seal.testing.decisionProjectionCanonical(decision));
    decision.decision = .{ .bound_raw = 1, .prepared_tag_raw = 7, .effect_tag_raw = 2 };
    try std.testing.expect(!seal.testing.decisionProjectionCanonical(decision));
    decision.decision = .{ .bound_raw = 1, .prepared_tag_raw = 6 };
    try std.testing.expect(!seal.testing.decisionProjectionCanonical(decision));
    decision.retained_observation_digest[0] = 1;
    decision.decision.prepared_tag_raw = 5;
    try std.testing.expect(!seal.testing.decisionProjectionCanonical(decision));
}

test "C3-3b2b1 cleanup seal observation couples every owner and digest" {
    const baseline = observationInput();
    try std.testing.expect(seal.testing.observationCleanupInputCanonical(baseline));
    const digest = seal.observationCleanupDigest(baseline);
    try std.testing.expectEqualSlices(u8, &digest, &seal.observationCleanupDigest(baseline));

    inline for (std.meta.fields(seal.ObservationCleanupGraph)) |field| {
        var missing_digest = baseline;
        @field(missing_digest.graph, field.name) = descriptor(0x4000);
        @field(missing_digest, field.name ++ "_digest") = [_]u8{0} ** 32;
        if (comptime std.mem.eql(u8, field.name, "ssh_remote_dest"))
            missing_digest.ssh_remote_dest_present = 1;
        if (comptime std.mem.eql(u8, field.name, "foreground_processes"))
            missing_digest.foreground_process_count = 1;
        try std.testing.expect(!seal.testing.observationCleanupInputCanonical(missing_digest));

        var digest_without_owner = baseline;
        @field(digest_without_owner.graph, field.name) = .{};
        @field(digest_without_owner, field.name ++ "_digest") = [_]u8{9} ** 32;
        try std.testing.expect(!seal.testing.observationCleanupInputCanonical(digest_without_owner));
    }

    inline for (.{ "ssh_remote_dest_present", "alt_active", "app_cursor_keys", "app_keypad", "alternate_scroll", "mouse_tracking", "bracketed_paste", "foreground_available", "foreground_pgid_present" }) |field_name| {
        var invalid = baseline;
        @field(invalid, field_name) = 2;
        try std.testing.expect(!seal.testing.observationCleanupInputCanonical(invalid));
    }
    var invalid = baseline;
    invalid.availability = 3;
    try std.testing.expect(!seal.testing.observationCleanupInputCanonical(invalid));
    invalid = baseline;
    invalid.semantic_state = 4;
    try std.testing.expect(!seal.testing.observationCleanupInputCanonical(invalid));
    invalid = baseline;
    invalid.foreground_pgid = 7;
    try std.testing.expect(!seal.testing.observationCleanupInputCanonical(invalid));
}

test "C3-3b2b1 cleanup seal neutral codecs have independent golden digests" {
    const string_digest = seal.observationStringDigest(.cwd, "/tmp");
    var foreground: seal.ForegroundProcessesDigestInput = .{};
    foreground.count = 1;
    foreground.entries[0].pid = 41;
    foreground.entries[0].len = 5;
    @memcpy(foreground.entries[0].bytes[0..5], "codex");
    const foreground_digest = seal.foregroundProcessesDigest(foreground);
    const observation_digest = seal.observationCleanupDigest(observationInput());
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0x7a, 0xd9, 0x91, 0xbc, 0x90, 0x3c, 0x8a, 0x90,
        0xa5, 0x96, 0x20, 0x96, 0xcb, 0x49, 0xe2, 0xd2,
        0xfd, 0x63, 0x0d, 0x77, 0xb3, 0x1d, 0x26, 0xf9,
        0x7b, 0x24, 0x0d, 0xdf, 0xbe, 0x45, 0x6e, 0xab,
    }, &string_digest);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0x82, 0xa4, 0xe6, 0x1a, 0x22, 0xdf, 0x0a, 0xf3,
        0x6e, 0x41, 0xdd, 0xef, 0x0a, 0xc1, 0x65, 0x80,
        0xf5, 0x58, 0xb3, 0x1e, 0xd9, 0x94, 0x6a, 0x9e,
        0x12, 0x0c, 0xf7, 0x53, 0x12, 0xc4, 0xa3, 0x2a,
    }, &foreground_digest);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0x69, 0xa5, 0xe1, 0x9f, 0xe0, 0xd5, 0x5c, 0x54,
        0x27, 0x78, 0x98, 0x80, 0x07, 0x0c, 0xf0, 0xae,
        0xf9, 0x47, 0xe8, 0x0e, 0x41, 0xa4, 0xe3, 0x0e,
        0x4f, 0x11, 0xfa, 0xce, 0x39, 0x00, 0x53, 0xda,
    }, &observation_digest);
}

test "C3-3b2b1 cleanup seal observation encoder binds every scalar descriptor and digest" {
    const baseline_input = observationInput();
    const baseline = seal.testing.observationCleanupDigestUnchecked(baseline_input);
    inline for (std.meta.fields(seal.ObservationCleanupDigestInput)) |field| {
        if (comptime std.mem.eql(u8, field.name, "graph")) continue;
        var changed = baseline_input;
        switch (@typeInfo(field.type)) {
            .int => @field(changed, field.name) +%= 1,
            .array => @field(changed, field.name)[0] ^= 1,
            else => @compileError("unhandled observation cleanup field: " ++ field.name),
        }
        try std.testing.expect(!std.mem.eql(
            u8,
            &baseline,
            &seal.testing.observationCleanupDigestUnchecked(changed),
        ));
    }
    inline for (std.meta.fields(seal.ObservationCleanupGraph)) |owner_field| {
        inline for (std.meta.fields(seal.CleanupDescriptor)) |descriptor_field| {
            var changed = baseline_input;
            @field(@field(changed.graph, owner_field.name), descriptor_field.name) +%= 1;
            try std.testing.expect(!std.mem.eql(
                u8,
                &baseline,
                &seal.testing.observationCleanupDigestUnchecked(changed),
            ));
        }
    }
}

test "C3-3b2b1 cleanup seal neutral digest rejection is fixed fatal" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    var case_id: u8 = 0;
    while (case_id < 2) : (case_id += 1) {
        const child = std.c.fork();
        if (child < 0) return error.TestUnexpectedResult;
        if (child == 0) {
            if (case_id == 0) {
                var foreground: seal.ForegroundProcessesDigestInput = .{};
                foreground.count = 65;
                _ = seal.foregroundProcessesDigest(foreground);
            } else {
                var observation = observationInput();
                observation.availability = 3;
                _ = seal.observationCleanupDigest(observation);
            }
            std.c._exit(124);
        }
        var status: c_int = 0;
        try std.testing.expectEqual(child, std.c.waitpid(child, &status, 0));
        const unsigned_status: u32 = @bitCast(status);
        try std.testing.expect(std.c.W.IFEXITED(unsigned_status));
        try std.testing.expectEqual(
            @as(u8, 70),
            @as(u8, @intCast(std.c.W.EXITSTATUS(unsigned_status))),
        );
    }
}
