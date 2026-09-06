//! Canonical append-only handoff for the live release workflow reducer.
//!
//! The file is progress evidence, never release authority. Its context digest prevents a valid
//! state from another tag or Actions attempt from being selected by a later process.

const std = @import("std");
const context = @import("release_adapter_context");
const files = @import("release_adapter_files");
const identity = @import("release_adapter_identity");
const phase = @import("release_adapter_live_workflow_phase");

pub const max_document_bytes: usize = 192;
const schema = "maru.session-host-release-workflow-state.v1";
const v1_outcomes = [_]phase.Outcome{ .active, .succeeded, .local_failure, .audit_required, .cleanup_required };

pub const Error = phase.Error || files.Error || std.mem.Allocator.Error || error{
    BufferTooSmall,
    ContextMismatch,
    InvalidContext,
    InvalidDocument,
    UnsafeFile,
    UnsafeMode,
};

pub fn encode(storage: []u8, state: phase.State, workflow: context.Context) Error![]const u8 {
    try validateContext(workflow);
    if (!state.isCanonical()) return error.InvalidState;
    const digest_hex = std.fmt.bytesToHex(contextDigest(workflow), .lower);
    return std.fmt.bufPrint(storage,
        \\{s}
        \\context_blake3={s}
        \\next_index={d}
        \\outcome={s}
        \\flags={d}{d}{d}
        \\
    , .{ schema, &digest_hex, state.next_index, @tagName(state.outcome), @intFromBool(state.draft_mutation_started), @intFromBool(state.aggregate_present), @intFromBool(state.published) }) catch return error.BufferTooSmall;
}

pub fn decode(bytes: []const u8, workflow: context.Context) Error!phase.State {
    try validateContext(workflow);
    if (bytes.len == 0 or bytes.len > max_document_bytes or bytes[bytes.len - 1] != '\n') return error.InvalidDocument;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    const schema_line = lines.next() orelse return error.InvalidDocument;
    const digest_line = lines.next() orelse return error.InvalidDocument;
    const index_line = lines.next() orelse return error.InvalidDocument;
    const outcome_line = lines.next() orelse return error.InvalidDocument;
    const flags_line = lines.next() orelse return error.InvalidDocument;
    if (lines.next() == null or lines.next() != null or !std.mem.eql(u8, schema_line, schema)) return error.InvalidDocument;

    const digest_prefix = "context_blake3=";
    if (!std.mem.startsWith(u8, digest_line, digest_prefix) or digest_line.len != digest_prefix.len + 64) return error.InvalidDocument;
    const expected_hex = std.fmt.bytesToHex(contextDigest(workflow), .lower);
    if (!std.mem.eql(u8, digest_line[digest_prefix.len..], &expected_hex)) return error.ContextMismatch;

    const index_prefix = "next_index=";
    if (!std.mem.startsWith(u8, index_line, index_prefix) or index_line.len != index_prefix.len + 1 or !std.ascii.isDigit(index_line[index_prefix.len])) return error.InvalidDocument;
    const next_index = index_line[index_prefix.len] - '0';

    const outcome_prefix = "outcome=";
    if (!std.mem.startsWith(u8, outcome_line, outcome_prefix)) return error.InvalidDocument;
    const outcome_bytes = outcome_line[outcome_prefix.len..];
    const outcome: phase.Outcome = inline for (v1_outcomes) |candidate| {
        if (std.mem.eql(u8, outcome_bytes, @tagName(candidate))) break candidate;
    } else return error.InvalidDocument;

    const flags_prefix = "flags=";
    if (!std.mem.startsWith(u8, flags_line, flags_prefix) or flags_line.len != flags_prefix.len + 3) return error.InvalidDocument;
    const flags = flags_line[flags_prefix.len..];
    for (flags) |flag| if (flag != '0' and flag != '1') return error.InvalidDocument;
    const state: phase.State = .{ .next_index = next_index, .outcome = outcome, .draft_mutation_started = flags[0] == '1', .aggregate_present = flags[1] == '1', .published = flags[2] == '1' };
    if (!state.isCanonical()) return error.InvalidState;
    var canonical: [max_document_bytes]u8 = undefined;
    if (!std.mem.eql(u8, bytes, try encode(&canonical, state, workflow))) return error.InvalidDocument;
    return state;
}

pub fn publish(path: [:0]const u8, state: phase.State, workflow: context.Context) Error!void {
    var storage: [max_document_bytes]u8 = undefined;
    try files.publishSummaryExclusive(path, try encode(&storage, state, workflow));
}

pub fn reopen(allocator: std.mem.Allocator, path: [:0]const u8, workflow: context.Context) Error!phase.State {
    var pinned: files.PinnedReleaseFile = .{};
    files.pinReleaseFileObserved(&pinned, path, false, max_document_bytes) catch return error.UnsafeFile;
    defer pinned.deinit() catch {};
    const observation = pinned.value() orelse return error.UnsafeFile;
    if (observation.mode & 0o777 != 0o600) return error.UnsafeMode;
    var input = pinned.readHeldAlloc(allocator, path, max_document_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.UnsafeFile,
    };
    defer input.deinit(allocator);
    return decode(input.bytes, workflow);
}

fn contextDigest(workflow: context.Context) [32]u8 {
    var hash = std.crypto.hash.Blake3.init(.{});
    hash.update("maru.session-host-release-workflow-context.v1");
    hashU64(&hash, workflow.repository.id);
    hashField(&hash, workflow.repository.owner);
    hashField(&hash, workflow.repository.name);
    hashField(&hash, workflow.tag);
    hashField(&hash, workflow.source_commit);
    hashField(&hash, workflow.build.workflow_ref);
    hashU64(&hash, workflow.build.run_id);
    hashU64(&hash, workflow.build.run_attempt);
    hash.update(&.{@intFromBool(workflow.protected_tag)});
    var result: [32]u8 = undefined;
    hash.final(&result);
    return result;
}

fn validateContext(workflow: context.Context) error{InvalidContext}!void {
    if (workflow.repository.id == 0 or
        !std.mem.eql(u8, workflow.repository.owner, "ohah") or
        !std.mem.eql(u8, workflow.repository.name, "maru") or
        !identity.canonicalTag(workflow.tag) or
        !identity.lowerHex(workflow.source_commit, 40) or
        workflow.build.run_id == 0 or
        workflow.build.run_attempt == 0 or
        !workflow.protected_tag) return error.InvalidContext;
    var expected_storage: [context.max_value_bytes]u8 = undefined;
    const expected = std.fmt.bufPrint(
        &expected_storage,
        "ohah/maru/.github/workflows/release.yml@refs/tags/{s}",
        .{workflow.tag},
    ) catch return error.InvalidContext;
    if (!std.mem.eql(u8, workflow.build.workflow_ref, expected)) return error.InvalidContext;
}

fn hashField(hash: *std.crypto.hash.Blake3, value: []const u8) void {
    hashU64(hash, value.len);
    hash.update(value);
}

fn hashU64(hash: *std.crypto.hash.Blake3, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .big);
    hash.update(&bytes);
}

comptime {
    if (@typeInfo(phase.Outcome).@"enum".fields.len != v1_outcomes.len)
        @compileError("workflow state v1 outcome inventory drift");
    if (@typeInfo(phase.State).@"struct".fields.len != 5)
        @compileError("workflow state v1 field inventory drift");
    for (v1_outcomes, 0..) |outcome, index| {
        const field = @typeInfo(phase.Outcome).@"enum".fields[index];
        if (@intFromEnum(outcome) != field.value or !std.mem.eql(u8, @tagName(outcome), field.name))
            @compileError("workflow state v1 outcome order drift");
    }
}
