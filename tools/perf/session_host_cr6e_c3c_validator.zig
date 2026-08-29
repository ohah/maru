//! CR6e-c3c actual-AppKit automatic reconnect strict artifact validator.

const std = @import("std");

const Identity = struct {
    host_id_before: []const u8,
    host_id_after: []const u8,
    runtime_id_before: []const u8,
    runtime_id_after: []const u8,
    host_pid_before: i32,
    host_pid_after: i32,
    child_pid_before: i32,
    child_pid_after: i32,
};

const Continuity = struct {
    historical_before_count: u32,
    historical_after_count: u32,
    disconnect_after_count: u32,
    input_count: u32,
    copy_count: u32,
    resize_count: u32,
};

const Sibling = struct {
    runtime_id: []const u8,
    live_before: bool,
    live_after: bool,
    controller_before: bool,
    controller_after: bool,
};

const Frame = struct {
    blocking_operations: u32,
    max_stall_ns: u64,
};

const Cleanup = struct {
    worker: u32,
    jobs: u32,
    completion: u32,
    cr5_jobs: u32,
    admissions: u32,
    resident_leases: u32,
    backend_runtimes: u32,
    clients: u32,
    fds: u32,
    fd_before: u32,
    fd_after: u32,
    child_processes_remaining: u32,
    daemon_reaped: bool,
    socket_removed: bool,
    host_artifacts_removed: bool,
};

const Artifact = struct {
    schema: []const u8,
    build_mode: []const u8,
    identity: Identity,
    continuity: Continuity,
    sibling: Sibling,
    frame: Frame,
    cleanup: Cleanup,
};

fn canonicalId(text: []const u8) bool {
    if (text.len != 32) return false;
    for (text) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    return true;
}

fn validateArtifact(artifact: Artifact) !void {
    if (!std.mem.eql(u8, artifact.schema, "maru.session-host-cr6e-c3c-appkit.v1") or
        !std.mem.eql(u8, artifact.build_mode, "ReleaseFast"))
        return error.InvalidEnvelope;
    const identity = artifact.identity;
    if (!canonicalId(identity.host_id_before) or !canonicalId(identity.host_id_after) or
        !canonicalId(identity.runtime_id_before) or !canonicalId(identity.runtime_id_after) or
        !std.mem.eql(u8, identity.host_id_before, identity.host_id_after) or
        !std.mem.eql(u8, identity.runtime_id_before, identity.runtime_id_after) or
        identity.host_pid_before <= 0 or identity.host_pid_before != identity.host_pid_after or
        identity.child_pid_before <= 0 or identity.child_pid_before != identity.child_pid_after)
        return error.IdentityDrift;
    const continuity = artifact.continuity;
    if (continuity.historical_before_count != 1 or continuity.historical_after_count != 1 or
        continuity.disconnect_after_count != 1 or continuity.input_count != 1 or
        continuity.copy_count != 1 or continuity.resize_count != 1)
        return error.ContinuityIncomplete;
    const sibling = artifact.sibling;
    if (!canonicalId(sibling.runtime_id) or
        std.mem.eql(u8, sibling.runtime_id, identity.runtime_id_before) or
        !sibling.live_before or !sibling.live_after or
        !sibling.controller_before or !sibling.controller_after)
        return error.SiblingAuthorityDrift;
    if (artifact.frame.blocking_operations != 0 or artifact.frame.max_stall_ns == 0)
        return error.FrameStall;
    const cleanup = artifact.cleanup;
    if (cleanup.worker != 0 or cleanup.jobs != 0 or cleanup.completion != 0 or
        cleanup.cr5_jobs != 0 or cleanup.admissions != 0 or cleanup.resident_leases != 0 or
        cleanup.backend_runtimes != 0 or cleanup.clients != 0 or cleanup.fds != 0 or
        cleanup.fd_before != cleanup.fd_after or cleanup.child_processes_remaining != 0 or
        !cleanup.daemon_reaped or !cleanup.socket_removed or !cleanup.host_artifacts_removed)
        return error.CleanupIncomplete;
}

pub fn validateBytes(allocator: std.mem.Allocator, bytes: []const u8) !void {
    var parsed = std.json.parseFromSlice(Artifact, allocator, bytes, .{
        .duplicate_field_behavior = .@"error",
        .ignore_unknown_fields = false,
    }) catch return error.InvalidJsonSchema;
    defer parsed.deinit();
    try validateArtifact(parsed.value);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();
    _ = args.next();
    const path = args.next() orelse return error.MissingArtifactPath;
    if (args.next() != null) return error.TooManyArguments;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(bytes);
    try validateBytes(allocator, bytes);
}

test "CR6e-c3c validator rejects identity continuity sibling frame and cleanup drift" {
    var artifact = validFixture();
    try validateArtifact(artifact);
    artifact.identity.child_pid_after += 1;
    try std.testing.expectError(error.IdentityDrift, validateArtifact(artifact));
    artifact = validFixture();
    artifact.continuity.copy_count = 0;
    try std.testing.expectError(error.ContinuityIncomplete, validateArtifact(artifact));
    artifact = validFixture();
    artifact.sibling.controller_after = false;
    try std.testing.expectError(error.SiblingAuthorityDrift, validateArtifact(artifact));
    artifact = validFixture();
    artifact.frame.blocking_operations = 1;
    try std.testing.expectError(error.FrameStall, validateArtifact(artifact));
    artifact = validFixture();
    artifact.cleanup.clients = 1;
    try std.testing.expectError(error.CleanupIncomplete, validateArtifact(artifact));
}

test "CR6e-c3c validator rejects unknown duplicate and missing JSON fields" {
    const valid =
        \\{"schema":"maru.session-host-cr6e-c3c-appkit.v1","build_mode":"ReleaseFast","identity":{"host_id_before":"00000000000000000000000000000001","host_id_after":"00000000000000000000000000000001","runtime_id_before":"00000000000000000000000000000002","runtime_id_after":"00000000000000000000000000000002","host_pid_before":10,"host_pid_after":10,"child_pid_before":11,"child_pid_after":11},"continuity":{"historical_before_count":1,"historical_after_count":1,"disconnect_after_count":1,"input_count":1,"copy_count":1,"resize_count":1},"sibling":{"runtime_id":"00000000000000000000000000000003","live_before":true,"live_after":true,"controller_before":true,"controller_after":true},"frame":{"blocking_operations":0,"max_stall_ns":1},"cleanup":{"worker":0,"jobs":0,"completion":0,"cr5_jobs":0,"admissions":0,"resident_leases":0,"backend_runtimes":0,"clients":0,"fds":0,"fd_before":4,"fd_after":4,"child_processes_remaining":0,"daemon_reaped":true,"socket_removed":true,"host_artifacts_removed":true}}
    ;
    try validateBytes(std.testing.allocator, valid);
    const unknown = try std.mem.replaceOwned(u8, std.testing.allocator, valid, "\"build_mode\":", "\"unknown\":0,\"build_mode\":");
    defer std.testing.allocator.free(unknown);
    try std.testing.expectError(error.InvalidJsonSchema, validateBytes(std.testing.allocator, unknown));
    const duplicate = try std.mem.replaceOwned(u8, std.testing.allocator, valid, "\"schema\":", "\"schema\":\"maru.session-host-cr6e-c3c-appkit.v1\",\"schema\":");
    defer std.testing.allocator.free(duplicate);
    try std.testing.expectError(error.InvalidJsonSchema, validateBytes(std.testing.allocator, duplicate));
    const missing = try std.mem.replaceOwned(u8, std.testing.allocator, valid, "\"copy_count\":1,", "");
    defer std.testing.allocator.free(missing);
    try std.testing.expectError(error.InvalidJsonSchema, validateBytes(std.testing.allocator, missing));
}

fn validFixture() Artifact {
    return .{
        .schema = "maru.session-host-cr6e-c3c-appkit.v1",
        .build_mode = "ReleaseFast",
        .identity = .{
            .host_id_before = "00000000000000000000000000000001",
            .host_id_after = "00000000000000000000000000000001",
            .runtime_id_before = "00000000000000000000000000000002",
            .runtime_id_after = "00000000000000000000000000000002",
            .host_pid_before = 10,
            .host_pid_after = 10,
            .child_pid_before = 11,
            .child_pid_after = 11,
        },
        .continuity = .{
            .historical_before_count = 1,
            .historical_after_count = 1,
            .disconnect_after_count = 1,
            .input_count = 1,
            .copy_count = 1,
            .resize_count = 1,
        },
        .sibling = .{
            .runtime_id = "00000000000000000000000000000003",
            .live_before = true,
            .live_after = true,
            .controller_before = true,
            .controller_after = true,
        },
        .frame = .{ .blocking_operations = 0, .max_stall_ns = 1 },
        .cleanup = .{
            .worker = 0,
            .jobs = 0,
            .completion = 0,
            .cr5_jobs = 0,
            .admissions = 0,
            .resident_leases = 0,
            .backend_runtimes = 0,
            .clients = 0,
            .fds = 0,
            .fd_before = 4,
            .fd_after = 4,
            .child_processes_remaining = 0,
            .daemon_reaped = true,
            .socket_removed = true,
            .host_artifacts_removed = true,
        },
    };
}
