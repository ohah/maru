//! Canonical durable evidence for signed persistent session-host release upgrades.
//!
//! Product harness leaves are staging inputs. This module is their only JSON consumer and rewrites
//! their typed observations into one canonical, attested aggregate; filenames and caller booleans
//! never become release authority.

const std = @import("std");
const manifest = @import("release_manifest");
const upgrade_limits = @import("upgrade_limits.zig");

pub const canonicalReleaseTestUuid = upgrade_limits.canonicalReleaseTestUuid;

pub const schema = "maru.session-host-release-evidence.v1";
pub const default_false_leaf_schema = upgrade_limits.default_false_leaf_schema;
pub const signed_app_quit_leaf_schema = upgrade_limits.signed_app_quit_leaf_schema;
pub const signed_upgrade_leaf_schema = upgrade_limits.signed_upgrade_leaf_schema;
pub const max_evidence_bytes = manifest.max_evidence_bytes;
pub const max_scalar_string_bytes = manifest.max_scalar_string_bytes;
pub const near_max_runtime_count: u64 = upgrade_limits.max_runtime_count - 1;

pub const Role = enum { a, b };
pub const Profile = enum { baseline_a, upgrade_b };
pub const Result = enum { passed };
pub const StatusReason = enum { none };

pub const Repository = struct {
    id: u64,
    owner: []const u8,
    name: []const u8,
};

pub const Release = struct {
    id: u64,
    tag: []const u8,
    version: []const u8,
};

pub const Source = struct {
    commit: []const u8,
    tree: []const u8,
};

pub const Build = struct {
    workflow_ref: []const u8,
    run_id: u64,
    run_attempt: u64,
};

pub const Candidate = struct {
    dmg_sha256: []const u8,
    executable_sha256: []const u8,
};

pub const Common = struct {
    test_uuid: []const u8,
    repository: Repository,
    release: Release,
    source: Source,
    build: Build,
    candidate: Candidate,
};

pub const Predecessor = struct {
    release_id: u64,
    tag: []const u8,
    commit: []const u8,
    manifest_sha256: []const u8,
    dmg_sha256: []const u8,
    executable_sha256: []const u8,
};

pub const DefaultFalseGate = struct {
    schema: []const u8,
    test_uuid: []const u8,
    result: Result,
    candidate_dmg_sha256: []const u8,
    candidate_executable_sha256: []const u8,
    resolved_default: bool,
    explicit_override_present: bool,
    signed_product: bool,
};

pub const SignedAppQuitGate = struct {
    schema: []const u8,
    test_uuid: []const u8,
    result: Result,
    candidate_dmg_sha256: []const u8,
    candidate_executable_sha256: []const u8,
    runtime_count: u64,
    same_host_pid: bool,
    all_runtime_pids_preserved: bool,
    gui_exact_reattach: bool,
    runtime_screen_before_preserved: bool,
    runtime_screen_after_writable: bool,
    cleanup_complete: bool,
};

pub const SignedUpgradeGate = struct {
    schema: []const u8,
    test_uuid: []const u8,
    result: Result,
    predecessor_executable_sha256: []const u8,
    candidate_executable_sha256: []const u8,
    signer_requirement_sha256: []const u8,
    runtime_count: u64,
    runtime_set_sha256: []const u8,
    same_host_pid: bool,
    all_runtime_pids_preserved: bool,
    runtime_screen_before_preserved: bool,
    runtime_screen_after_writable: bool,
    gui_exact_reattach: bool,
    runtime_reaped_after_exit: bool,
    runtime_inventory_absent_observations: u64,
    status_committed: bool,
    status_reason: StatusReason,
    upgrade_capability_preserved: bool,
    epoch_before: u64,
    epoch_after: u64,
};

pub const BaselineGates = struct {
    default_false_baseline: DefaultFalseGate,
    signed_app_quit_reattach: SignedAppQuitGate,
};

pub const UpgradeGates = struct {
    signed_upgrade_one: SignedUpgradeGate,
    signed_upgrade_near_max: SignedUpgradeGate,
};

pub const BaselineRoot = struct {
    schema: []const u8,
    profile: Profile,
    role: Role,
    test_uuid: []const u8,
    repository: Repository,
    release: Release,
    source: Source,
    build: Build,
    candidate: Candidate,
    gates: BaselineGates,
    result: Result,
};

pub const UpgradeRoot = struct {
    schema: []const u8,
    profile: Profile,
    role: Role,
    test_uuid: []const u8,
    repository: Repository,
    release: Release,
    source: Source,
    build: Build,
    candidate: Candidate,
    predecessor: Predecessor,
    gates: UpgradeGates,
    result: Result,
};

pub const Value = union(Profile) {
    baseline_a: *const BaselineRoot,
    upgrade_b: *const UpgradeRoot,
};

pub const UpgradeExpected = struct {
    common: Common,
    predecessor: Predecessor,
    designated_requirement_sha256: []const u8,
};

pub const Expected = union(Profile) {
    baseline_a: Common,
    upgrade_b: UpgradeExpected,
};

const ParsedInner = union(Profile) {
    baseline_a: std.json.Parsed(BaselineRoot),
    upgrade_b: std.json.Parsed(UpgradeRoot),
};

pub const Parsed = struct {
    inner: ParsedInner,

    pub fn deinit(self: *Parsed) void {
        switch (self.inner) {
            inline else => |*parsed| parsed.deinit(),
        }
    }

    pub fn value(self: *const Parsed) Value {
        return switch (self.inner) {
            .baseline_a => |*parsed| .{ .baseline_a = &parsed.value },
            .upgrade_b => |*parsed| .{ .upgrade_b = &parsed.value },
        };
    }

    pub fn schema(self: *const Parsed) []const u8 {
        return switch (self.inner) {
            inline else => |*parsed| parsed.value.schema,
        };
    }

    pub fn profile(self: *const Parsed) Profile {
        return std.meta.activeTag(self.inner);
    }
};

pub const Error = error{
    EvidenceTooLarge,
    ScalarTooLarge,
    InvalidJson,
    NonCanonical,
    InvalidSchema,
    InvalidUuid,
    InvalidIdentity,
    InvalidProfile,
    InvalidLeaf,
    LeafMismatch,
    InvalidRuntimeCount,
    BindingMismatch,
} || std.mem.Allocator.Error;

const Header = struct {
    profile: Profile,
};

pub fn assembleBaseline(
    allocator: std.mem.Allocator,
    common: Common,
    default_leaf_bytes: []const u8,
    quit_leaf_bytes: []const u8,
) Error![]u8 {
    try validateCommon(common);
    var default_leaf = try parseLeaf(DefaultFalseGate, allocator, default_leaf_bytes);
    defer default_leaf.deinit();
    var quit_leaf = try parseLeaf(SignedAppQuitGate, allocator, quit_leaf_bytes);
    defer quit_leaf.deinit();
    try validateDefaultLeaf(default_leaf.value);
    try validateQuitLeaf(quit_leaf.value);
    try bindBaselineLeaves(common, default_leaf.value, quit_leaf.value);
    return writeBaseline(allocator, .{
        .schema = schema,
        .profile = .baseline_a,
        .role = .a,
        .test_uuid = common.test_uuid,
        .repository = common.repository,
        .release = common.release,
        .source = common.source,
        .build = common.build,
        .candidate = common.candidate,
        .gates = .{
            .default_false_baseline = default_leaf.value,
            .signed_app_quit_reattach = quit_leaf.value,
        },
        .result = .passed,
    });
}

pub fn assembleUpgrade(
    allocator: std.mem.Allocator,
    common: Common,
    predecessor: Predecessor,
    one_leaf_bytes: []const u8,
    near_max_leaf_bytes: []const u8,
) Error![]u8 {
    try validateCommon(common);
    try validatePredecessor(predecessor);
    var one = try parseLeaf(SignedUpgradeGate, allocator, one_leaf_bytes);
    defer one.deinit();
    var near_max = try parseLeaf(SignedUpgradeGate, allocator, near_max_leaf_bytes);
    defer near_max.deinit();
    try validateUpgradeLeaf(one.value);
    try validateUpgradeLeaf(near_max.value);
    if (one.value.runtime_count != 1 or near_max.value.runtime_count != near_max_runtime_count)
        return error.InvalidRuntimeCount;
    try bindUpgradeLeaf(common, predecessor, one.value);
    try bindUpgradeLeaf(common, predecessor, near_max.value);
    if (!std.mem.eql(u8, one.value.signer_requirement_sha256, near_max.value.signer_requirement_sha256))
        return error.LeafMismatch;
    return writeUpgrade(allocator, .{
        .schema = schema,
        .profile = .upgrade_b,
        .role = .b,
        .test_uuid = common.test_uuid,
        .repository = common.repository,
        .release = common.release,
        .source = common.source,
        .build = common.build,
        .candidate = common.candidate,
        .predecessor = predecessor,
        .gates = .{
            .signed_upgrade_one = one.value,
            .signed_upgrade_near_max = near_max.value,
        },
        .result = .passed,
    });
}

pub fn parseCanonical(allocator: std.mem.Allocator, bytes: []const u8) Error!Parsed {
    if (bytes.len > max_evidence_bytes) return error.EvidenceTooLarge;
    if (bytes.len == 0 or bytes[bytes.len - 1] != '\n') return error.NonCanonical;
    try preflight(allocator, bytes);
    var header = std.json.parseFromSlice(Header, allocator, bytes, .{
        .duplicate_field_behavior = .@"error",
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    defer header.deinit();
    return switch (header.value.profile) {
        .baseline_a => blk: {
            var parsed = try parseRoot(BaselineRoot, allocator, bytes);
            errdefer parsed.deinit();
            try validateBaseline(parsed.value);
            const canonical = try writeBaseline(allocator, parsed.value);
            defer allocator.free(canonical);
            if (!std.mem.eql(u8, bytes, canonical)) return error.NonCanonical;
            break :blk .{ .inner = .{ .baseline_a = parsed } };
        },
        .upgrade_b => blk: {
            var parsed = try parseRoot(UpgradeRoot, allocator, bytes);
            errdefer parsed.deinit();
            try validateUpgrade(parsed.value);
            const canonical = try writeUpgrade(allocator, parsed.value);
            defer allocator.free(canonical);
            if (!std.mem.eql(u8, bytes, canonical)) return error.NonCanonical;
            break :blk .{ .inner = .{ .upgrade_b = parsed } };
        },
    };
}

pub fn bind(value: Value, expected: Expected) Error!void {
    switch (value) {
        .baseline_a => |actual| switch (expected) {
            .baseline_a => |wanted| if (!equalCommon(rootCommon(actual.*), wanted)) return error.BindingMismatch,
            else => return error.BindingMismatch,
        },
        .upgrade_b => |actual| switch (expected) {
            .upgrade_b => |wanted| if (!equalCommon(rootCommon(actual.*), wanted.common) or
                !equalPredecessor(actual.predecessor, wanted.predecessor) or
                !lowerHex(wanted.designated_requirement_sha256, 64) or
                !std.mem.eql(u8, actual.gates.signed_upgrade_one.signer_requirement_sha256, wanted.designated_requirement_sha256) or
                !std.mem.eql(u8, actual.gates.signed_upgrade_near_max.signer_requirement_sha256, wanted.designated_requirement_sha256)) return error.BindingMismatch,
            else => return error.BindingMismatch,
        },
    }
}

fn parseRoot(comptime T: type, allocator: std.mem.Allocator, bytes: []const u8) Error!std.json.Parsed(T) {
    return std.json.parseFromSlice(T, allocator, bytes, .{
        .duplicate_field_behavior = .@"error",
        .ignore_unknown_fields = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidJson,
    };
}

fn parseLeaf(comptime T: type, allocator: std.mem.Allocator, bytes: []const u8) Error!std.json.Parsed(T) {
    if (bytes.len > max_evidence_bytes) return error.EvidenceTooLarge;
    if (bytes.len == 0 or bytes[bytes.len - 1] != '\n') return error.InvalidLeaf;
    preflight(allocator, bytes) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidLeaf,
    };
    var parsed = std.json.parseFromSlice(T, allocator, bytes, .{
        .duplicate_field_behavior = .@"error",
        .ignore_unknown_fields = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidLeaf,
    };
    errdefer parsed.deinit();
    const canonical = try writeJson(allocator, parsed.value);
    defer allocator.free(canonical);
    if (!std.mem.eql(u8, bytes, canonical)) return error.InvalidLeaf;
    return parsed;
}

fn writeBaseline(allocator: std.mem.Allocator, root: BaselineRoot) Error![]u8 {
    try validateBaseline(root);
    return writeJson(allocator, root);
}

fn writeUpgrade(allocator: std.mem.Allocator, root: UpgradeRoot) Error![]u8 {
    try validateUpgrade(root);
    return writeJson(allocator, root);
}

fn writeJson(allocator: std.mem.Allocator, value: anytype) Error![]u8 {
    var count_buffer: [1024]u8 = undefined;
    var discarding: std.Io.Writer.Discarding = .init(&count_buffer);
    var counter: std.json.Stringify = .{ .writer = &discarding.writer, .options = .{} };
    counter.write(value) catch return error.OutOfMemory;
    discarding.writer.writeByte('\n') catch return error.OutOfMemory;
    if (discarding.fullCount() > max_evidence_bytes) return error.EvidenceTooLarge;

    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer, .options = .{} };
    json.write(value) catch return error.OutOfMemory;
    output.writer.writeByte('\n') catch return error.OutOfMemory;
    return output.toOwnedSlice();
}

fn validateBaseline(root: BaselineRoot) Error!void {
    if (!std.mem.eql(u8, root.schema, schema)) return error.InvalidSchema;
    if (root.profile != .baseline_a or root.role != .a or root.result != .passed)
        return error.InvalidProfile;
    const common = rootCommon(root);
    try validateCommon(common);
    try validateDefaultLeaf(root.gates.default_false_baseline);
    try validateQuitLeaf(root.gates.signed_app_quit_reattach);
    try bindBaselineLeaves(common, root.gates.default_false_baseline, root.gates.signed_app_quit_reattach);
}

fn validateUpgrade(root: UpgradeRoot) Error!void {
    if (!std.mem.eql(u8, root.schema, schema)) return error.InvalidSchema;
    if (root.profile != .upgrade_b or root.role != .b or root.result != .passed)
        return error.InvalidProfile;
    const common = rootCommon(root);
    try validateCommon(common);
    try validatePredecessor(root.predecessor);
    try validateUpgradeLeaf(root.gates.signed_upgrade_one);
    try validateUpgradeLeaf(root.gates.signed_upgrade_near_max);
    if (root.gates.signed_upgrade_one.runtime_count != 1 or
        root.gates.signed_upgrade_near_max.runtime_count != near_max_runtime_count)
        return error.InvalidRuntimeCount;
    try bindUpgradeLeaf(common, root.predecessor, root.gates.signed_upgrade_one);
    try bindUpgradeLeaf(common, root.predecessor, root.gates.signed_upgrade_near_max);
    if (!std.mem.eql(
        u8,
        root.gates.signed_upgrade_one.signer_requirement_sha256,
        root.gates.signed_upgrade_near_max.signer_requirement_sha256,
    )) return error.LeafMismatch;
}

pub fn validateCommon(common: Common) Error!void {
    try scalar(common.test_uuid);
    if (!canonicalUuidV4(common.test_uuid)) return error.InvalidUuid;
    try scalar(common.repository.owner);
    try scalar(common.repository.name);
    try scalar(common.release.tag);
    try scalar(common.release.version);
    try scalar(common.build.workflow_ref);
    if (common.repository.id == 0 or !std.mem.eql(u8, common.repository.owner, "ohah") or
        !std.mem.eql(u8, common.repository.name, "maru") or common.release.id == 0 or
        common.release.version.len == 0 or common.release.tag.len != common.release.version.len + 1 or
        common.release.tag[0] != 'v' or !std.mem.eql(u8, common.release.tag[1..], common.release.version) or
        !lowerHex(common.source.commit, 40) or !lowerHex(common.source.tree, 40) or
        common.build.workflow_ref.len == 0 or common.build.run_id == 0 or common.build.run_attempt == 0 or
        !lowerHex(common.candidate.dmg_sha256, 64) or !lowerHex(common.candidate.executable_sha256, 64))
        return error.InvalidIdentity;
}

fn validatePredecessor(value: Predecessor) Error!void {
    try scalar(value.tag);
    if (value.release_id == 0 or value.tag.len < 2 or value.tag[0] != 'v' or
        !lowerHex(value.commit, 40) or !lowerHex(value.manifest_sha256, 64) or
        !lowerHex(value.dmg_sha256, 64) or !lowerHex(value.executable_sha256, 64))
        return error.InvalidIdentity;
}

fn validateDefaultLeaf(leaf: DefaultFalseGate) Error!void {
    if (!std.mem.eql(u8, leaf.schema, default_false_leaf_schema) or leaf.result != .passed or
        !canonicalUuidV4(leaf.test_uuid) or !lowerHex(leaf.candidate_dmg_sha256, 64) or
        !lowerHex(leaf.candidate_executable_sha256, 64) or leaf.resolved_default or
        leaf.explicit_override_present or !leaf.signed_product) return error.InvalidLeaf;
}

fn validateQuitLeaf(leaf: SignedAppQuitGate) Error!void {
    if (!std.mem.eql(u8, leaf.schema, signed_app_quit_leaf_schema) or leaf.result != .passed or
        !canonicalUuidV4(leaf.test_uuid) or !lowerHex(leaf.candidate_dmg_sha256, 64) or
        !lowerHex(leaf.candidate_executable_sha256, 64) or leaf.runtime_count != 1 or
        !leaf.same_host_pid or !leaf.all_runtime_pids_preserved or !leaf.gui_exact_reattach or
        !leaf.runtime_screen_before_preserved or !leaf.runtime_screen_after_writable or
        !leaf.cleanup_complete) return error.InvalidLeaf;
}

fn validateUpgradeLeaf(leaf: SignedUpgradeGate) Error!void {
    const next_epoch = std.math.add(u64, leaf.epoch_before, 1) catch return error.InvalidLeaf;
    if (!std.mem.eql(u8, leaf.schema, signed_upgrade_leaf_schema) or leaf.result != .passed or
        !canonicalUuidV4(leaf.test_uuid) or !lowerHex(leaf.predecessor_executable_sha256, 64) or
        !lowerHex(leaf.candidate_executable_sha256, 64) or
        !lowerHex(leaf.signer_requirement_sha256, 64) or leaf.runtime_count == 0 or
        !lowerHex(leaf.runtime_set_sha256, 64) or !leaf.same_host_pid or
        !leaf.all_runtime_pids_preserved or !leaf.runtime_screen_before_preserved or
        !leaf.runtime_screen_after_writable or !leaf.gui_exact_reattach or
        !leaf.runtime_reaped_after_exit or leaf.runtime_inventory_absent_observations != 2 or
        !leaf.status_committed or leaf.status_reason != .none or !leaf.upgrade_capability_preserved or
        leaf.epoch_before == 0 or leaf.epoch_after != next_epoch) return error.InvalidLeaf;
}

fn bindBaselineLeaves(common: Common, default_leaf: DefaultFalseGate, quit_leaf: SignedAppQuitGate) Error!void {
    if (!std.mem.eql(u8, common.test_uuid, default_leaf.test_uuid) or
        !std.mem.eql(u8, common.test_uuid, quit_leaf.test_uuid) or
        !std.mem.eql(u8, common.candidate.dmg_sha256, default_leaf.candidate_dmg_sha256) or
        !std.mem.eql(u8, common.candidate.executable_sha256, default_leaf.candidate_executable_sha256) or
        !std.mem.eql(u8, common.candidate.dmg_sha256, quit_leaf.candidate_dmg_sha256) or
        !std.mem.eql(u8, common.candidate.executable_sha256, quit_leaf.candidate_executable_sha256))
        return error.LeafMismatch;
}

fn bindUpgradeLeaf(common: Common, predecessor: Predecessor, leaf: SignedUpgradeGate) Error!void {
    if (!std.mem.eql(u8, common.test_uuid, leaf.test_uuid) or
        !std.mem.eql(u8, common.candidate.executable_sha256, leaf.candidate_executable_sha256) or
        !std.mem.eql(u8, predecessor.executable_sha256, leaf.predecessor_executable_sha256))
        return error.LeafMismatch;
}

fn rootCommon(root: anytype) Common {
    return .{
        .test_uuid = root.test_uuid,
        .repository = root.repository,
        .release = root.release,
        .source = root.source,
        .build = root.build,
        .candidate = root.candidate,
    };
}

fn equalCommon(a: Common, b: Common) bool {
    return std.mem.eql(u8, a.test_uuid, b.test_uuid) and a.repository.id == b.repository.id and
        std.mem.eql(u8, a.repository.owner, b.repository.owner) and
        std.mem.eql(u8, a.repository.name, b.repository.name) and a.release.id == b.release.id and
        std.mem.eql(u8, a.release.tag, b.release.tag) and
        std.mem.eql(u8, a.release.version, b.release.version) and
        std.mem.eql(u8, a.source.commit, b.source.commit) and
        std.mem.eql(u8, a.source.tree, b.source.tree) and
        std.mem.eql(u8, a.build.workflow_ref, b.build.workflow_ref) and
        a.build.run_id == b.build.run_id and a.build.run_attempt == b.build.run_attempt and
        std.mem.eql(u8, a.candidate.dmg_sha256, b.candidate.dmg_sha256) and
        std.mem.eql(u8, a.candidate.executable_sha256, b.candidate.executable_sha256);
}

fn equalPredecessor(a: Predecessor, b: Predecessor) bool {
    return a.release_id == b.release_id and std.mem.eql(u8, a.tag, b.tag) and
        std.mem.eql(u8, a.commit, b.commit) and std.mem.eql(u8, a.manifest_sha256, b.manifest_sha256) and
        std.mem.eql(u8, a.dmg_sha256, b.dmg_sha256) and
        std.mem.eql(u8, a.executable_sha256, b.executable_sha256);
}

fn preflight(allocator: std.mem.Allocator, bytes: []const u8) Error!void {
    var scanner = std.json.Scanner.initCompleteInput(allocator, bytes);
    defer scanner.deinit();
    while (true) {
        const token = scanner.nextAllocMax(
            allocator,
            .alloc_if_needed,
            max_scalar_string_bytes,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ValueTooLong => return error.ScalarTooLarge,
            else => return error.InvalidJson,
        };
        if (token == .end_of_document) return;
    }
}

fn scalar(value: []const u8) Error!void {
    if (value.len > max_scalar_string_bytes) return error.ScalarTooLarge;
}

fn lowerHex(value: []const u8, exact_len: usize) bool {
    if (value.len != exact_len) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    return true;
}

fn canonicalUuidV4(value: []const u8) bool {
    return upgrade_limits.canonicalReleaseTestUuid(value);
}
