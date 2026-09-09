//! Credential-free final binding of GitHub timing and immutable Release observations.

const std = @import("std");
const context_mod = @import("release_adapter_context");
const timing_mod = @import("release_adapter_live_timing_artifact");
const release_mod = @import("release_adapter_remote_release_observation");
const evidence = @import("release_evidence");

pub const View = struct {
    profile: evidence.Profile,
    release_id: u64,
    timing_artifact_id: u64,
    run_id: u64,
    run_attempt: u64,
    source_commit: []const u8,
    duration_ms: u64,
};

pub const Verdict = struct {
    owner: ?*@This() = null,
    context_owner: ?*const context_mod.Context = null,
    timing_owner: ?*const timing_mod.Provenance = null,
    release_owner: ?*const release_mod.Observation = null,
    context_seal: [32]u8 = @splat(0),
    seal: [32]u8 = @splat(0),

    pub fn value(self: *const @This()) ?View {
        if (self.owner != self or !std.crypto.timing_safe.eql([32]u8, self.seal, ownerSeal(self))) return null;
        const context = self.context_owner orelse return null;
        const timing_owner = self.timing_owner orelse return null;
        const release_owner = self.release_owner orelse return null;
        context_mod.validateTrusted(context.*) catch return null;
        if (!std.crypto.timing_safe.eql([32]u8, self.context_seal, contextSeal(context.*))) return null;
        const timing = timing_owner.value() orelse return null;
        const release = release_owner.value() orelse return null;
        if (timing_owner.repository_id != context.repository.id or
            timing.timing.run_id != context.build.run_id or timing.timing.run_attempt != context.build.run_attempt or
            !std.mem.eql(u8, timing.timing.source_sha, context.source_commit) or
            release.repository_id != context.repository.id or release.run_id != context.build.run_id or
            release.run_attempt != context.build.run_attempt or !std.mem.eql(u8, release.source_commit, context.source_commit)) return null;
        return .{
            .profile = release.profile,
            .release_id = release.release_id,
            .timing_artifact_id = timing.artifact_id,
            .run_id = timing.timing.run_id,
            .run_attempt = timing.timing.run_attempt,
            .source_commit = context.source_commit,
            .duration_ms = timing.timing.duration_ms,
        };
    }

    pub fn deinit(self: *@This()) !void {
        if (self.owner != self or !std.crypto.timing_safe.eql([32]u8, self.seal, ownerSeal(self))) return error.InvalidOwner;
        self.* = .{};
    }
};

pub fn bind(context: *const context_mod.Context, timing: *const timing_mod.Provenance, release: *const release_mod.Observation, result: *Verdict) !void {
    if (!pristine(result) or aliases(context, timing, release, result)) return error.InvalidOwner;
    try context_mod.validateTrusted(context.*);
    const initial_context = contextSeal(context.*);
    if (timing.value() == null or release.value() == null) return error.InvalidObservation;
    result.context_owner = context;
    result.timing_owner = timing;
    result.release_owner = release;
    result.context_seal = initial_context;
    result.owner = result;
    result.seal = ownerSeal(result);
    if (result.value() == null) {
        result.* = .{};
        return error.BindingMismatch;
    }
}

fn pristine(result: *const Verdict) bool {
    return result.owner == null and result.context_owner == null and result.timing_owner == null and
        result.release_owner == null and std.mem.allEqual(u8, &result.context_seal, 0) and
        std.mem.allEqual(u8, &result.seal, 0);
}

fn aliases(context: *const context_mod.Context, timing: *const timing_mod.Provenance, release: *const release_mod.Observation, result: *const Verdict) bool {
    const inputs = [_][]const u8{
        std.mem.asBytes(context), std.mem.asBytes(timing),    std.mem.asBytes(release),
        context.repository.owner, context.repository.name,    context.tag,
        context.source_commit,    context.build.workflow_ref,
    };
    const output = std.mem.asBytes(result);
    for (inputs, 0..) |input, index| {
        if (overlaps(output, input)) return true;
        for (inputs[0..index]) |prior| if (overlaps(input, prior)) return true;
    }
    return false;
}

fn ownerSeal(result: *const Verdict) [32]u8 {
    var hash = std.crypto.hash.Blake3.init(.{});
    hash.update("maru.session-host.remote-release-verdict.v1");
    const addresses = [_]usize{
        @intFromPtr(result),
        if (result.context_owner) |value| @intFromPtr(value) else 0,
        if (result.timing_owner) |value| @intFromPtr(value) else 0,
        if (result.release_owner) |value| @intFromPtr(value) else 0,
    };
    hash.update(std.mem.asBytes(&addresses));
    hash.update(&result.context_seal);
    var seal: [32]u8 = undefined;
    hash.final(&seal);
    return seal;
}

fn contextSeal(context: context_mod.Context) [32]u8 {
    var hash = std.crypto.hash.Blake3.init(.{});
    hash.update("maru.session-host.remote-release-verdict.context.v1");
    hash.update(std.mem.asBytes(&context.repository.id));
    hashPart(&hash, context.repository.owner);
    hashPart(&hash, context.repository.name);
    hashPart(&hash, context.tag);
    hashPart(&hash, context.source_commit);
    hashPart(&hash, context.build.workflow_ref);
    hash.update(std.mem.asBytes(&context.build.run_id));
    hash.update(std.mem.asBytes(&context.build.run_attempt));
    hash.update(std.mem.asBytes(&context.protected_tag));
    var seal: [32]u8 = undefined;
    hash.final(&seal);
    return seal;
}

fn hashPart(hash: *std.crypto.hash.Blake3, bytes: []const u8) void {
    hash.update(std.mem.asBytes(&bytes.len));
    hash.update(bytes);
}

fn overlaps(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    return @intFromPtr(a.ptr) < @intFromPtr(b.ptr) + b.len and @intFromPtr(b.ptr) < @intFromPtr(a.ptr) + a.len;
}
