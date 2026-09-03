//! Pure, address-bound authority proof for one external whole-turn suffix.
//!
//! This leaf receives only immutable scalar projections and opaque digests. It does not own or
//! dereference the storage, parser, lease, or drain objects whose identities it seals.

const std = @import("std");
const external_owner_seal = @import("external_owner_seal.zig");

pub const AuthorityGeneration = union(enum) {
    untracked,
    tracked: u64,
};

pub const FinalParserReadiness = enum(u8) {
    empty = 0,
    incomplete = 1,
    complete_or_error = 2,
};

pub const FinishedDrainLifecycle = enum(u8) {
    finished = 0,
};

pub const AttachmentRole = enum(u8) {
    observer = 0,
    controller = 1,
};

pub const OwnerAuthorityFlow = enum(u8) {
    initial_fence = 0,
    clear = 1,
};

pub const Seed = struct {
    permit_addr: usize,
    cleanup_seed_addr: usize,
    storage_addr: usize,
    owner_incarnation: u64,
    owner_incarnation_digest: external_owner_seal.Digest,
    scratch_addr: usize,
    scratch_turn_generation: u64,
    lease_addr: usize,
    operation_generation: u64,
    lease_digest: external_owner_seal.Digest,
    client_addr: usize,
    parser_addr: usize,
    parser_generation: u64,
    parser_seal_digest: external_owner_seal.Digest,
    rx_provenance_digest: external_owner_seal.Digest,
    rx_absolute_next: u64,
    drain_evidence_addr: usize,
    drain_read_attempt_generation: u64,
    drain_evidence_digest: external_owner_seal.Digest,
    inherited_blocker_snapshot_digest: external_owner_seal.Digest,
    final_owner_snapshot_digest: external_owner_seal.Digest,
    final_parser_readiness: FinalParserReadiness,
    drain_evidence_lifecycle: FinishedDrainLifecycle,
    final_blockers_clear: bool,
    read_budget_remaining: bool,
    frame_budget_remaining: bool,
    work_budget_remaining: bool,
    terminal_or_revoke: bool,
    semantic_active: bool,
    reentry_clear: bool,
    attachment_role: AttachmentRole,
    observer_control_only: bool,
    authority_flow: OwnerAuthorityFlow,
    owner_authority_seal_digest: external_owner_seal.Digest,
    authority_generation: AuthorityGeneration,
};

pub const CurrentView = Seed;

comptime {
    const expected_seed_fields = [_][]const u8{
        "permit_addr",
        "cleanup_seed_addr",
        "storage_addr",
        "owner_incarnation",
        "owner_incarnation_digest",
        "scratch_addr",
        "scratch_turn_generation",
        "lease_addr",
        "operation_generation",
        "lease_digest",
        "client_addr",
        "parser_addr",
        "parser_generation",
        "parser_seal_digest",
        "rx_provenance_digest",
        "rx_absolute_next",
        "drain_evidence_addr",
        "drain_read_attempt_generation",
        "drain_evidence_digest",
        "inherited_blocker_snapshot_digest",
        "final_owner_snapshot_digest",
        "final_parser_readiness",
        "drain_evidence_lifecycle",
        "final_blockers_clear",
        "read_budget_remaining",
        "frame_budget_remaining",
        "work_budget_remaining",
        "terminal_or_revoke",
        "semantic_active",
        "reentry_clear",
        "attachment_role",
        "observer_control_only",
        "authority_flow",
        "owner_authority_seal_digest",
        "authority_generation",
    };
    const actual = std.meta.fields(Seed);
    if (actual.len != expected_seed_fields.len)
        @compileError("Seed schema changed without updating its canonical seal transcript");
    for (actual, expected_seed_fields) |field, expected|
        if (!std.mem.eql(u8, field.name, expected))
            @compileError("Seed field order changed without updating its canonical seal transcript");
}

pub const FrozenCleanupSeed = struct {
    saved_self_addr: usize = 0,
    permit_addr: usize = 0,
    scratch_addr: usize = 0,
    seed: Seed = zeroSeed(),
    lifecycle: CleanupLifecycle = .empty,
    digest: external_owner_seal.Digest = zero_digest,
};

pub const PreparedAuthorityPermit = struct {
    domain: [8]u8 = zero_domain,
    version: u16 = 0,
    saved_self_addr: usize = 0,
    cleanup_seed_addr: usize = 0,
    seed: Seed = zeroSeed(),
    lifecycle: PermitLifecycle = .empty,
    digest: external_owner_seal.Digest = zero_digest,
};

pub const PrepareResult = enum {
    prepared,
    ineligible,
    invalid_seed,
    destination_not_empty,
};

pub const AbortResult = enum {
    aborted,
    invalid_authority,
};

pub const ConsumeResult = enum {
    consumed,
    invalid_authority,
};

pub const CleanupAbortResult = enum {
    aborted,
    invalid_authority,
};

pub const PermitLifecycle = enum(u8) {
    empty = 0,
    prepared = 1,
    consumed = 2,
    aborted = 3,
};

pub const CleanupLifecycle = enum(u8) {
    empty = 0,
    prepared = 1,
    consumed = 2,
};

const domain = [8]u8{ 'M', 'A', 'R', 'U', 'D', '2', 'D', '1' };
const zero_domain = [_]u8{0} ** 8;
const version: u16 = 1;
const zero_digest = [_]u8{0} ** 32;

pub fn prepare(
    out: *PreparedAuthorityPermit,
    cleanup: *FrozenCleanupSeed,
    seed: Seed,
) PrepareResult {
    if (!rangesDisjoint(
        @intFromPtr(out),
        @sizeOf(PreparedAuthorityPermit),
        @intFromPtr(cleanup),
        @sizeOf(FrozenCleanupSeed),
    )) return .invalid_seed;
    if (!std.meta.eql(out.*, PreparedAuthorityPermit{}) or
        !std.meta.eql(cleanup.*, FrozenCleanupSeed{}))
        return .destination_not_empty;
    if (!validSeedShape(seed, out, cleanup)) return .invalid_seed;
    if (!eligible(seed)) return .ineligible;

    var next_permit = PreparedAuthorityPermit{
        .domain = domain,
        .version = version,
        .saved_self_addr = @intFromPtr(out),
        .cleanup_seed_addr = @intFromPtr(cleanup),
        .seed = seed,
        .lifecycle = .prepared,
    };
    next_permit.digest = sealPermit(&next_permit);
    var next_cleanup = FrozenCleanupSeed{
        .saved_self_addr = @intFromPtr(cleanup),
        .permit_addr = @intFromPtr(out),
        .scratch_addr = seed.scratch_addr,
        .seed = seed,
        .lifecycle = .prepared,
    };
    next_cleanup.digest = sealCleanup(&next_cleanup);
    out.* = next_permit;
    cleanup.* = next_cleanup;
    return .prepared;
}

fn rangesDisjoint(a_addr: usize, a_len: usize, b_addr: usize, b_len: usize) bool {
    if (a_len == 0 or b_len == 0) return false;
    const a_end = std.math.add(usize, a_addr, a_len) catch return false;
    const b_end = std.math.add(usize, b_addr, b_len) catch return false;
    return a_end <= b_addr or b_end <= a_addr;
}

pub fn validate(
    permit: *const PreparedAuthorityPermit,
    current: CurrentView,
) bool {
    return permitMatchesCurrent(permit, current, .prepared);
}

pub fn abort(
    permit: *PreparedAuthorityPermit,
    current: CurrentView,
) AbortResult {
    if (!permitMatchesCurrent(permit, current, .prepared))
        return .invalid_authority;
    permit.lifecycle = .aborted;
    permit.digest = sealPermit(permit);
    return .aborted;
}

pub fn consume(
    permit: *PreparedAuthorityPermit,
    current: CurrentView,
) ConsumeResult {
    if (!permitMatchesCurrent(permit, current, .prepared))
        return .invalid_authority;
    permit.lifecycle = .consumed;
    permit.digest = sealPermit(permit);
    return .consumed;
}

pub fn validateConsumed(
    permit: *const PreparedAuthorityPermit,
    current: CurrentView,
) bool {
    return permitMatchesCurrent(permit, current, .consumed);
}

pub fn abortForCleanup(
    permit: *PreparedAuthorityPermit,
    cleanup: *FrozenCleanupSeed,
) CleanupAbortResult {
    if (!validCleanup(cleanup, permit) or
        !permitMatchesCurrent(permit, cleanup.seed, .prepared))
        return .invalid_authority;
    permit.lifecycle = .aborted;
    permit.digest = sealPermit(permit);
    cleanup.lifecycle = .consumed;
    cleanup.digest = sealCleanup(cleanup);
    return .aborted;
}

/// Irreversibly closes a scalar prepared capability when its sibling cleanup descriptor cannot
/// be trusted. A malformed permit is already unusable and remains untouched; an intact permit
/// owns no resource or executable hook, so changing only its sealed lifecycle is bounded.
pub fn poisonPreparedForTerminal(
    permit: *PreparedAuthorityPermit,
) bool {
    if (!permitMatchesCurrent(permit, permit.seed, .prepared))
        return true;
    permit.lifecycle = .aborted;
    permit.digest = sealPermit(permit);
    return !permitMatchesCurrent(permit, permit.seed, .prepared);
}

pub fn resetSpent(
    permit: *PreparedAuthorityPermit,
    cleanup: *FrozenCleanupSeed,
    current: CurrentView,
) bool {
    if (!validCleanup(cleanup, permit) or
        !(permitMatchesCurrent(permit, current, .aborted) or
            permitMatchesCurrent(permit, current, .consumed)) or
        !std.meta.eql(cleanup.seed, current))
        return false;
    permit.* = .{};
    cleanup.* = .{};
    return true;
}

/// Resets a consumed TX suffix after the write leaf has validated the live RX authority around
/// every external call. TX queue retirement legitimately changes the broader owner inventory, so the
/// consumed permit is closed against its frozen cleanup seed rather than a reconstructed pre-TX
/// view.
pub fn resetConsumedAfterTx(
    permit: *PreparedAuthorityPermit,
    cleanup: *FrozenCleanupSeed,
) bool {
    if (!validCleanup(cleanup, permit) or
        !permitMatchesCurrent(permit, cleanup.seed, .consumed))
        return false;
    permit.* = .{};
    cleanup.* = .{};
    return true;
}

fn validSeedShape(
    seed: Seed,
    permit: *const PreparedAuthorityPermit,
    cleanup: *const FrozenCleanupSeed,
) bool {
    if (seed.permit_addr != @intFromPtr(permit) or
        seed.cleanup_seed_addr != @intFromPtr(cleanup) or
        seed.storage_addr == 0 or
        seed.owner_incarnation == 0 or
        seed.scratch_addr == 0 or
        seed.scratch_turn_generation == 0 or
        seed.scratch_turn_generation == std.math.maxInt(u64) or
        seed.lease_addr == 0 or
        seed.operation_generation == 0 or
        seed.operation_generation == std.math.maxInt(u64) or
        seed.client_addr == 0 or
        seed.parser_addr == 0 or
        seed.parser_generation == 0 or
        seed.parser_generation == std.math.maxInt(u64) or
        seed.rx_absolute_next == std.math.maxInt(u64) or
        seed.drain_evidence_addr == 0 or
        seed.drain_read_attempt_generation == 0 or
        seed.drain_read_attempt_generation == std.math.maxInt(u64))
        return false;
    const required_digests = [_]external_owner_seal.Digest{
        seed.owner_incarnation_digest,
        seed.lease_digest,
        seed.parser_seal_digest,
        seed.rx_provenance_digest,
        seed.drain_evidence_digest,
        seed.inherited_blocker_snapshot_digest,
        seed.final_owner_snapshot_digest,
        seed.owner_authority_seal_digest,
    };
    for (required_digests) |digest|
        if (std.mem.eql(u8, &digest, &zero_digest)) return false;
    return true;
}

fn eligible(seed: Seed) bool {
    // **관측자도 control 을 낸다.** 예전에는 이 자리가 `detach` 하나만 인정했고(필드 이름도
    // `terminal_detach_only` 였다), 그래서 S11-6 이 더한 `declare_viewport` 는 큐에 실린 채
    // 영영 안 나갔다 — 실기에서 `prepareAuthority=pristine` → `invariant_failure` 로 잡았다.
    // 「관측자가 낼 수 있는가」의 단일 출처는 `ControlKind.requiresController()` 이고, 이 필드는
    // 그 술어를 통과한 control 하나가 홀로 실려 있음을 뜻한다.
    const role_eligible = seed.attachment_role == .controller or
        (seed.attachment_role == .observer and seed.observer_control_only);
    if (!role_eligible or
        seed.authority_flow != .clear or
        seed.final_parser_readiness != .empty or
        !seed.final_blockers_clear or
        !seed.read_budget_remaining or
        !seed.frame_budget_remaining or
        !seed.work_budget_remaining or
        seed.terminal_or_revoke or
        !seed.semantic_active or
        !seed.reentry_clear)
        return false;
    return switch (seed.authority_generation) {
        .untracked => false,
        .tracked => |generation| generation != 0 and
            generation != std.math.maxInt(u64),
    };
}

fn validCleanup(
    cleanup: *const FrozenCleanupSeed,
    permit: *const PreparedAuthorityPermit,
) bool {
    return cleanup.lifecycle == .prepared and
        cleanup.saved_self_addr == @intFromPtr(cleanup) and
        cleanup.permit_addr == @intFromPtr(permit) and
        cleanup.scratch_addr == cleanup.seed.scratch_addr and
        cleanup.seed.permit_addr == @intFromPtr(permit) and
        cleanup.seed.cleanup_seed_addr == @intFromPtr(cleanup) and
        std.mem.eql(u8, &cleanup.digest, &sealCleanup(cleanup));
}

fn permitMatchesCurrent(
    permit: *const PreparedAuthorityPermit,
    current: CurrentView,
    expected_lifecycle: PermitLifecycle,
) bool {
    return std.mem.eql(u8, &permit.domain, &domain) and
        permit.version == version and
        permit.saved_self_addr == @intFromPtr(permit) and
        permit.cleanup_seed_addr == current.cleanup_seed_addr and
        permit.lifecycle == expected_lifecycle and
        std.meta.eql(permit.seed, current) and
        std.mem.eql(u8, &permit.digest, &sealPermit(permit));
}

fn sealPermit(permit: *const PreparedAuthorityPermit) external_owner_seal.Digest {
    var writer = external_owner_seal.Writer.init("external-turn-authority-permit.v1");
    writer.writeBytes(&permit.domain);
    writer.writeU16(permit.version);
    writer.writeUsize(permit.saved_self_addr);
    writer.writeUsize(permit.cleanup_seed_addr);
    writeSeed(&writer, permit.seed);
    writer.writeU8(@intFromEnum(permit.lifecycle));
    return writer.finish();
}

fn sealCleanup(cleanup: *const FrozenCleanupSeed) external_owner_seal.Digest {
    var writer = external_owner_seal.Writer.init("external-turn-authority-cleanup.v1");
    writer.writeUsize(cleanup.saved_self_addr);
    writer.writeUsize(cleanup.permit_addr);
    writer.writeUsize(cleanup.scratch_addr);
    writeSeed(&writer, cleanup.seed);
    writer.writeU8(@intFromEnum(cleanup.lifecycle));
    return writer.finish();
}

fn writeSeed(writer: *external_owner_seal.Writer, seed: Seed) void {
    inline for (std.meta.fields(Seed)) |field|
        writeCanonical(field.type, writer, @field(seed, field.name));
}

fn writeCanonical(
    comptime T: type,
    writer: *external_owner_seal.Writer,
    value: T,
) void {
    if (T == usize) {
        writer.writeUsize(value);
    } else if (T == u64) {
        writer.writeU64(value);
    } else if (T == bool) {
        writer.writeBool(value);
    } else if (T == AuthorityGeneration) {
        switch (value) {
            .untracked => writer.writeU8(0),
            .tracked => |generation| {
                writer.writeU8(1);
                writer.writeU64(generation);
            },
        }
    } else switch (@typeInfo(T)) {
        .@"enum" => writer.writeU8(@intCast(@intFromEnum(value))),
        .array => |array| {
            if (array.child != u8)
                @compileError("unsupported authority seed array type");
            writer.writeBytes(&value);
        },
        else => @compileError("unsupported authority seed field type"),
    }
}

fn zeroSeed() Seed {
    return .{
        .permit_addr = 0,
        .cleanup_seed_addr = 0,
        .storage_addr = 0,
        .owner_incarnation = 0,
        .owner_incarnation_digest = zero_digest,
        .scratch_addr = 0,
        .scratch_turn_generation = 0,
        .lease_addr = 0,
        .operation_generation = 0,
        .lease_digest = zero_digest,
        .client_addr = 0,
        .parser_addr = 0,
        .parser_generation = 0,
        .parser_seal_digest = zero_digest,
        .rx_provenance_digest = zero_digest,
        .rx_absolute_next = 0,
        .drain_evidence_addr = 0,
        .drain_read_attempt_generation = 0,
        .drain_evidence_digest = zero_digest,
        .inherited_blocker_snapshot_digest = zero_digest,
        .final_owner_snapshot_digest = zero_digest,
        .final_parser_readiness = .empty,
        .drain_evidence_lifecycle = .finished,
        .final_blockers_clear = false,
        .read_budget_remaining = false,
        .frame_budget_remaining = false,
        .work_budget_remaining = false,
        .terminal_or_revoke = false,
        .semantic_active = false,
        .reentry_clear = false,
        .attachment_role = .observer,
        .observer_control_only = false,
        .authority_flow = .initial_fence,
        .owner_authority_seal_digest = zero_digest,
        .authority_generation = .untracked,
    };
}

fn testSeed(
    permit: *PreparedAuthorityPermit,
    cleanup: *FrozenCleanupSeed,
) Seed {
    return .{
        .permit_addr = @intFromPtr(permit),
        .cleanup_seed_addr = @intFromPtr(cleanup),
        .storage_addr = 0x1000,
        .owner_incarnation = 2,
        .owner_incarnation_digest = filledDigest(0xa1),
        .scratch_addr = 0x2000,
        .scratch_turn_generation = 3,
        .lease_addr = 0x3000,
        .operation_generation = 4,
        .lease_digest = filledDigest(0xa2),
        .client_addr = 0x4000,
        .parser_addr = 0x5000,
        .parser_generation = 5,
        .parser_seal_digest = filledDigest(0xa3),
        .rx_provenance_digest = filledDigest(0xa4),
        .rx_absolute_next = 6,
        .drain_evidence_addr = 0x6000,
        .drain_read_attempt_generation = 7,
        .drain_evidence_digest = filledDigest(0xa5),
        .inherited_blocker_snapshot_digest = filledDigest(0xa6),
        .final_owner_snapshot_digest = filledDigest(0xa7),
        .final_parser_readiness = .empty,
        .drain_evidence_lifecycle = .finished,
        .final_blockers_clear = true,
        .read_budget_remaining = true,
        .frame_budget_remaining = true,
        .work_budget_remaining = true,
        .terminal_or_revoke = false,
        .semantic_active = true,
        .reentry_clear = true,
        .attachment_role = .controller,
        .observer_control_only = false,
        .authority_flow = .clear,
        .owner_authority_seal_digest = filledDigest(0xa8),
        .authority_generation = .{ .tracked = 8 },
    };
}

fn filledDigest(byte: u8) external_owner_seal.Digest {
    return [1]u8{byte} ** 32;
}

const SeedDrift = enum {
    permit_addr,
    cleanup_seed_addr,
    storage_addr,
    owner_incarnation,
    owner_incarnation_digest,
    scratch_addr,
    scratch_turn_generation,
    lease_addr,
    operation_generation,
    lease_digest,
    client_addr,
    parser_addr,
    parser_generation,
    parser_seal_digest,
    rx_provenance_digest,
    rx_absolute_next,
    drain_evidence_addr,
    drain_read_attempt_generation,
    drain_evidence_digest,
    inherited_blocker_snapshot_digest,
    final_owner_snapshot_digest,
    final_parser_readiness,
    final_blockers_clear,
    read_budget_remaining,
    frame_budget_remaining,
    work_budget_remaining,
    terminal_or_revoke,
    semantic_active,
    reentry_clear,
    attachment_role,
    observer_control_only,
    authority_flow,
    owner_authority_seal_digest,
    authority_generation,
};

comptime {
    const seed_fields = std.meta.fields(Seed);
    const drift_fields = std.meta.fields(SeedDrift);
    if (drift_fields.len + 1 != seed_fields.len)
        @compileError("Seed drift matrix must cover every independently mutable field");
    var drift_index: usize = 0;
    for (seed_fields) |field| {
        if (std.mem.eql(u8, field.name, "drain_evidence_lifecycle")) continue;
        if (!std.mem.eql(u8, field.name, drift_fields[drift_index].name))
            @compileError("Seed drift matrix field order does not match Seed");
        drift_index += 1;
    }
    if (drift_index != drift_fields.len)
        @compileError("Seed drift matrix contains an unpaired field");
    const drain_fields = @typeInfo(FinishedDrainLifecycle).@"enum".fields;
    if (drain_fields.len != 1 or
        !std.mem.eql(u8, drain_fields[0].name, "finished") or
        drain_fields[0].value != 0)
        @compileError("finished drain lifecycle changed without a drift fixture");
}

fn driftSeed(seed: *Seed, field: SeedDrift) void {
    switch (field) {
        .permit_addr => seed.permit_addr +%= 8,
        .cleanup_seed_addr => seed.cleanup_seed_addr +%= 8,
        .storage_addr => seed.storage_addr += 8,
        .owner_incarnation => seed.owner_incarnation += 1,
        .owner_incarnation_digest => seed.owner_incarnation_digest = filledDigest(0xc1),
        .scratch_addr => seed.scratch_addr += 8,
        .scratch_turn_generation => seed.scratch_turn_generation += 1,
        .lease_addr => seed.lease_addr += 8,
        .operation_generation => seed.operation_generation += 1,
        .lease_digest => seed.lease_digest = filledDigest(0xc2),
        .client_addr => seed.client_addr += 8,
        .parser_addr => seed.parser_addr += 8,
        .parser_generation => seed.parser_generation += 1,
        .parser_seal_digest => seed.parser_seal_digest = filledDigest(0xc3),
        .rx_provenance_digest => seed.rx_provenance_digest = filledDigest(0xc4),
        .rx_absolute_next => seed.rx_absolute_next += 1,
        .drain_evidence_addr => seed.drain_evidence_addr += 8,
        .drain_read_attempt_generation => seed.drain_read_attempt_generation += 1,
        .drain_evidence_digest => seed.drain_evidence_digest = filledDigest(0xc5),
        .inherited_blocker_snapshot_digest => seed.inherited_blocker_snapshot_digest =
            filledDigest(0xc6),
        .final_owner_snapshot_digest => seed.final_owner_snapshot_digest =
            filledDigest(0xc7),
        .final_parser_readiness => seed.final_parser_readiness = .incomplete,
        .final_blockers_clear => seed.final_blockers_clear = !seed.final_blockers_clear,
        .read_budget_remaining => seed.read_budget_remaining = !seed.read_budget_remaining,
        .frame_budget_remaining => seed.frame_budget_remaining = !seed.frame_budget_remaining,
        .work_budget_remaining => seed.work_budget_remaining = !seed.work_budget_remaining,
        .terminal_or_revoke => seed.terminal_or_revoke = !seed.terminal_or_revoke,
        .semantic_active => seed.semantic_active = !seed.semantic_active,
        .reentry_clear => seed.reentry_clear = !seed.reentry_clear,
        .attachment_role => seed.attachment_role = .observer,
        .observer_control_only => seed.observer_control_only = !seed.observer_control_only,
        .authority_flow => seed.authority_flow = .initial_fence,
        .owner_authority_seal_digest => seed.owner_authority_seal_digest =
            filledDigest(0xc8),
        .authority_generation => seed.authority_generation = .{ .tracked = 9 },
    }
}

test "prepare abort and reset form one address-bound lifecycle" {
    var permit = PreparedAuthorityPermit{};
    var cleanup = FrozenCleanupSeed{};
    const seed = testSeed(&permit, &cleanup);
    try std.testing.expectEqual(PrepareResult.prepared, prepare(&permit, &cleanup, seed));
    try std.testing.expect(validate(&permit, seed));
    try std.testing.expectEqual(AbortResult.aborted, abort(&permit, seed));
    try std.testing.expect(!validate(&permit, seed));
    try std.testing.expect(resetSpent(&permit, &cleanup, seed));
    try std.testing.expectEqualDeep(PreparedAuthorityPermit{}, permit);
    try std.testing.expectEqualDeep(FrozenCleanupSeed{}, cleanup);
}

test "ineligible seed and occupied destinations mutate nothing" {
    var permit = PreparedAuthorityPermit{};
    var cleanup = FrozenCleanupSeed{};
    var seed = testSeed(&permit, &cleanup);
    seed.authority_generation = .untracked;
    try std.testing.expectEqual(PrepareResult.ineligible, prepare(&permit, &cleanup, seed));
    try std.testing.expectEqualDeep(PreparedAuthorityPermit{}, permit);
    try std.testing.expectEqualDeep(FrozenCleanupSeed{}, cleanup);
    seed.authority_generation = .{ .tracked = 0 };
    try std.testing.expectEqual(PrepareResult.ineligible, prepare(&permit, &cleanup, seed));
    permit.version = 9;
    const before = permit;
    try std.testing.expectEqual(
        PrepareResult.destination_not_empty,
        prepare(&permit, &cleanup, seed),
    );
    try std.testing.expectEqualDeep(before, permit);
    try std.testing.expectEqualDeep(FrozenCleanupSeed{}, cleanup);
}

test "observer authority is eligible only for one sealed terminal detach" {
    var permit = PreparedAuthorityPermit{};
    var cleanup = FrozenCleanupSeed{};
    var seed = testSeed(&permit, &cleanup);
    seed.attachment_role = .observer;
    try std.testing.expectEqual(
        PrepareResult.ineligible,
        prepare(&permit, &cleanup, seed),
    );
    seed.observer_control_only = true;
    try std.testing.expectEqual(
        PrepareResult.prepared,
        prepare(&permit, &cleanup, seed),
    );
    try std.testing.expectEqual(AbortResult.aborted, abort(&permit, seed));
    try std.testing.expect(resetSpent(&permit, &cleanup, seed));
}

test "stale copied and cross-generation permits cannot mutate" {
    var permit = PreparedAuthorityPermit{};
    var cleanup = FrozenCleanupSeed{};
    var seed = testSeed(&permit, &cleanup);
    try std.testing.expectEqual(PrepareResult.prepared, prepare(&permit, &cleanup, seed));
    var stale = seed;
    stale.parser_generation += 1;
    const before = permit;
    try std.testing.expectEqual(AbortResult.invalid_authority, abort(&permit, stale));
    try std.testing.expectEqualDeep(before, permit);
    var copied = permit;
    try std.testing.expect(!validate(&copied, seed));
    try std.testing.expectEqual(AbortResult.aborted, abort(&permit, seed));
    seed.scratch_turn_generation += 1;
    try std.testing.expect(!resetSpent(&permit, &cleanup, seed));
}

test "frozen cleanup abort is exact and terminal" {
    var permit = PreparedAuthorityPermit{};
    var cleanup = FrozenCleanupSeed{};
    const seed = testSeed(&permit, &cleanup);
    try std.testing.expectEqual(PrepareResult.prepared, prepare(&permit, &cleanup, seed));
    try std.testing.expectEqual(
        CleanupAbortResult.aborted,
        abortForCleanup(&permit, &cleanup),
    );
    try std.testing.expect(!resetSpent(&permit, &cleanup, seed));
    const permit_before = permit;
    const cleanup_before = cleanup;
    try std.testing.expectEqual(
        CleanupAbortResult.invalid_authority,
        abortForCleanup(&permit, &cleanup),
    );
    try std.testing.expectEqualDeep(permit_before, permit);
    try std.testing.expectEqualDeep(cleanup_before, cleanup);
}

test "every authority blocker is ineligible without destination mutation" {
    const Blocker = enum {
        observer,
        initial_fence,
        parser_incomplete,
        parser_complete,
        final_blocker,
        read_budget,
        frame_budget,
        work_budget,
        terminal,
        semantic_inactive,
        reentry,
        authority_untracked,
        authority_zero,
        authority_exhausted,
    };
    const blockers = std.enums.values(Blocker);
    for (blockers) |blocker| {
        var permit = PreparedAuthorityPermit{};
        var cleanup = FrozenCleanupSeed{};
        var seed = testSeed(&permit, &cleanup);
        switch (blocker) {
            .observer => seed.attachment_role = .observer,
            .initial_fence => seed.authority_flow = .initial_fence,
            .parser_incomplete => seed.final_parser_readiness = .incomplete,
            .parser_complete => seed.final_parser_readiness = .complete_or_error,
            .final_blocker => seed.final_blockers_clear = false,
            .read_budget => seed.read_budget_remaining = false,
            .frame_budget => seed.frame_budget_remaining = false,
            .work_budget => seed.work_budget_remaining = false,
            .terminal => seed.terminal_or_revoke = true,
            .semantic_inactive => seed.semantic_active = false,
            .reentry => seed.reentry_clear = false,
            .authority_untracked => seed.authority_generation = .untracked,
            .authority_zero => seed.authority_generation = .{ .tracked = 0 },
            .authority_exhausted => seed.authority_generation =
                .{ .tracked = std.math.maxInt(u64) },
        }
        try std.testing.expectEqual(
            PrepareResult.ineligible,
            prepare(&permit, &cleanup, seed),
        );
        try std.testing.expectEqualDeep(PreparedAuthorityPermit{}, permit);
        try std.testing.expectEqualDeep(FrozenCleanupSeed{}, cleanup);
    }
}

test "invalid identity generation and digest seeds mutate nothing" {
    const Invalid = enum {
        permit_address,
        cleanup_address,
        storage_address,
        owner_incarnation,
        scratch_address,
        scratch_generation_zero,
        scratch_generation_exhausted,
        lease_address,
        operation_generation_zero,
        operation_generation_exhausted,
        client_address,
        parser_address,
        parser_generation_zero,
        parser_generation_exhausted,
        absolute_next_exhausted,
        drain_address,
        drain_generation_zero,
        drain_generation_exhausted,
        owner_digest,
        lease_digest,
        parser_digest,
        provenance_digest,
        drain_digest,
        inherited_digest,
        final_owner_digest,
        authority_digest,
    };
    const invalid_cases = std.enums.values(Invalid);
    for (invalid_cases) |invalid| {
        var permit = PreparedAuthorityPermit{};
        var cleanup = FrozenCleanupSeed{};
        var seed = testSeed(&permit, &cleanup);
        switch (invalid) {
            .permit_address => seed.permit_addr = 0,
            .cleanup_address => seed.cleanup_seed_addr = 0,
            .storage_address => seed.storage_addr = 0,
            .owner_incarnation => seed.owner_incarnation = 0,
            .scratch_address => seed.scratch_addr = 0,
            .scratch_generation_zero => seed.scratch_turn_generation = 0,
            .scratch_generation_exhausted => seed.scratch_turn_generation =
                std.math.maxInt(u64),
            .lease_address => seed.lease_addr = 0,
            .operation_generation_zero => seed.operation_generation = 0,
            .operation_generation_exhausted => seed.operation_generation =
                std.math.maxInt(u64),
            .client_address => seed.client_addr = 0,
            .parser_address => seed.parser_addr = 0,
            .parser_generation_zero => seed.parser_generation = 0,
            .parser_generation_exhausted => seed.parser_generation =
                std.math.maxInt(u64),
            .absolute_next_exhausted => seed.rx_absolute_next =
                std.math.maxInt(u64),
            .drain_address => seed.drain_evidence_addr = 0,
            .drain_generation_zero => seed.drain_read_attempt_generation = 0,
            .drain_generation_exhausted => seed.drain_read_attempt_generation =
                std.math.maxInt(u64),
            .owner_digest => seed.owner_incarnation_digest = zero_digest,
            .lease_digest => seed.lease_digest = zero_digest,
            .parser_digest => seed.parser_seal_digest = zero_digest,
            .provenance_digest => seed.rx_provenance_digest = zero_digest,
            .drain_digest => seed.drain_evidence_digest = zero_digest,
            .inherited_digest => seed.inherited_blocker_snapshot_digest = zero_digest,
            .final_owner_digest => seed.final_owner_snapshot_digest = zero_digest,
            .authority_digest => seed.owner_authority_seal_digest = zero_digest,
        }
        try std.testing.expectEqual(
            PrepareResult.invalid_seed,
            prepare(&permit, &cleanup, seed),
        );
        try std.testing.expectEqualDeep(PreparedAuthorityPermit{}, permit);
        try std.testing.expectEqualDeep(FrozenCleanupSeed{}, cleanup);
    }
}

test "cleanup drift cannot overwrite either authority record" {
    var permit = PreparedAuthorityPermit{};
    var cleanup = FrozenCleanupSeed{};
    const seed = testSeed(&permit, &cleanup);
    try std.testing.expectEqual(PrepareResult.prepared, prepare(&permit, &cleanup, seed));
    cleanup.seed.parser_generation += 1;
    const permit_before = permit;
    const cleanup_before = cleanup;
    try std.testing.expectEqual(
        CleanupAbortResult.invalid_authority,
        abortForCleanup(&permit, &cleanup),
    );
    try std.testing.expectEqualDeep(permit_before, permit);
    try std.testing.expectEqualDeep(cleanup_before, cleanup);
}

test "permit and cleanup destinations must be overflow-safe disjoint ranges" {
    const max = std.math.maxInt(usize);
    try std.testing.expect(!rangesDisjoint(max - 3, 8, 16, 8));
    try std.testing.expect(!rangesDisjoint(16, 8, max - 3, 8));
    try std.testing.expect(!rangesDisjoint(16, 8, 20, 8));
    try std.testing.expect(!rangesDisjoint(20, 8, 16, 8));
    try std.testing.expect(rangesDisjoint(16, 8, 24, 8));

    const alignment = @max(
        @alignOf(PreparedAuthorityPermit),
        @alignOf(FrozenCleanupSeed),
    );
    var backing: [
        @sizeOf(PreparedAuthorityPermit) +
            @sizeOf(FrozenCleanupSeed) + alignment
    ]u8 align(alignment) =
        [_]u8{0} ** (@sizeOf(PreparedAuthorityPermit) +
            @sizeOf(FrozenCleanupSeed) + alignment);
    const permit: *PreparedAuthorityPermit = @ptrCast(@alignCast(&backing[0]));
    const exact_cleanup: *FrozenCleanupSeed = @ptrCast(@alignCast(&backing[0]));
    var seed = testSeed(permit, exact_cleanup);
    const before = backing;
    try std.testing.expectEqual(
        PrepareResult.invalid_seed,
        prepare(permit, exact_cleanup, seed),
    );
    try std.testing.expectEqualSlices(u8, &before, &backing);

    const partial_offset = alignment;
    const partial_cleanup: *FrozenCleanupSeed =
        @ptrCast(@alignCast(&backing[partial_offset]));
    seed = testSeed(permit, partial_cleanup);
    try std.testing.expectEqual(
        PrepareResult.invalid_seed,
        prepare(permit, partial_cleanup, seed),
    );
    try std.testing.expectEqualSlices(u8, &before, &backing);
}

test "every opaque digest occupies a distinct sealed transcript slot" {
    var permit = PreparedAuthorityPermit{};
    var cleanup = FrozenCleanupSeed{};
    const seed = testSeed(&permit, &cleanup);
    try std.testing.expectEqual(PrepareResult.prepared, prepare(&permit, &cleanup, seed));
    const baseline = permit.digest;
    const DigestField = enum {
        owner,
        lease,
        parser,
        provenance,
        drain,
        inherited,
        final_owner,
        authority,
    };
    for (std.enums.values(DigestField)) |field| {
        var changed = permit;
        switch (field) {
            .owner => changed.seed.owner_incarnation_digest = filledDigest(0xb1),
            .lease => changed.seed.lease_digest = filledDigest(0xb2),
            .parser => changed.seed.parser_seal_digest = filledDigest(0xb3),
            .provenance => changed.seed.rx_provenance_digest = filledDigest(0xb4),
            .drain => changed.seed.drain_evidence_digest = filledDigest(0xb5),
            .inherited => changed.seed.inherited_blocker_snapshot_digest = filledDigest(0xb6),
            .final_owner => changed.seed.final_owner_snapshot_digest = filledDigest(0xb7),
            .authority => changed.seed.owner_authority_seal_digest = filledDigest(0xb8),
        }
        try std.testing.expect(!std.mem.eql(u8, &baseline, &sealPermit(&changed)));
    }
}

test "every mutable Seed field is sealed by permit and cleanup transcripts" {
    var permit = PreparedAuthorityPermit{};
    var cleanup = FrozenCleanupSeed{};
    const seed = testSeed(&permit, &cleanup);
    try std.testing.expectEqual(PrepareResult.prepared, prepare(&permit, &cleanup, seed));
    const permit_digest = permit.digest;
    const cleanup_digest = cleanup.digest;
    for (std.enums.values(SeedDrift)) |field| {
        var changed_permit = permit;
        driftSeed(&changed_permit.seed, field);
        try std.testing.expect(!std.mem.eql(
            u8,
            &permit_digest,
            &sealPermit(&changed_permit),
        ));
        var changed_cleanup = cleanup;
        driftSeed(&changed_cleanup.seed, field);
        try std.testing.expect(!std.mem.eql(
            u8,
            &cleanup_digest,
            &sealCleanup(&changed_cleanup),
        ));

        var current = seed;
        driftSeed(&current, field);
        const before = permit;
        try std.testing.expect(!validate(&permit, current));
        try std.testing.expectEqual(AbortResult.invalid_authority, abort(&permit, current));
        try std.testing.expectEqualDeep(before, permit);
    }
}

test "permit envelope tamper and double transitions mutate nothing" {
    const Tamper = enum {
        domain,
        version,
        saved_self,
        cleanup_address,
        lifecycle,
        digest,
    };
    for (std.enums.values(Tamper)) |tamper| {
        var permit = PreparedAuthorityPermit{};
        var cleanup = FrozenCleanupSeed{};
        const seed = testSeed(&permit, &cleanup);
        try std.testing.expectEqual(PrepareResult.prepared, prepare(&permit, &cleanup, seed));
        switch (tamper) {
            .domain => permit.domain[0] ^= 1,
            .version => permit.version += 1,
            .saved_self => permit.saved_self_addr += 8,
            .cleanup_address => permit.cleanup_seed_addr += 8,
            .lifecycle => permit.lifecycle = .consumed,
            .digest => permit.digest[0] ^= 1,
        }
        const before = permit;
        try std.testing.expect(!validate(&permit, seed));
        try std.testing.expectEqual(AbortResult.invalid_authority, abort(&permit, seed));
        try std.testing.expectEqualDeep(before, permit);
    }

    var permit = PreparedAuthorityPermit{};
    var cleanup = FrozenCleanupSeed{};
    const seed = testSeed(&permit, &cleanup);
    try std.testing.expectEqual(PrepareResult.prepared, prepare(&permit, &cleanup, seed));
    try std.testing.expectEqual(AbortResult.aborted, abort(&permit, seed));
    const aborted = permit;
    try std.testing.expectEqual(AbortResult.invalid_authority, abort(&permit, seed));
    try std.testing.expectEqualDeep(aborted, permit);
    try std.testing.expect(resetSpent(&permit, &cleanup, seed));
    try std.testing.expect(!resetSpent(&permit, &cleanup, seed));
}

test "cleanup envelope copies and tamper cannot change either record" {
    const Tamper = enum {
        saved_self,
        permit_address,
        scratch_address,
        lifecycle,
        digest,
    };
    for (std.enums.values(Tamper)) |tamper| {
        var permit = PreparedAuthorityPermit{};
        var cleanup = FrozenCleanupSeed{};
        const seed = testSeed(&permit, &cleanup);
        try std.testing.expectEqual(PrepareResult.prepared, prepare(&permit, &cleanup, seed));
        switch (tamper) {
            .saved_self => cleanup.saved_self_addr += 8,
            .permit_address => cleanup.permit_addr += 8,
            .scratch_address => cleanup.scratch_addr += 8,
            .lifecycle => cleanup.lifecycle = .consumed,
            .digest => cleanup.digest[0] ^= 1,
        }
        const permit_before = permit;
        const cleanup_before = cleanup;
        try std.testing.expectEqual(
            CleanupAbortResult.invalid_authority,
            abortForCleanup(&permit, &cleanup),
        );
        try std.testing.expectEqualDeep(permit_before, permit);
        try std.testing.expectEqualDeep(cleanup_before, cleanup);
    }

    var permit = PreparedAuthorityPermit{};
    var cleanup = FrozenCleanupSeed{};
    const seed = testSeed(&permit, &cleanup);
    try std.testing.expectEqual(PrepareResult.prepared, prepare(&permit, &cleanup, seed));
    var copied_permit = permit;
    var copied_cleanup = cleanup;
    try std.testing.expectEqual(
        CleanupAbortResult.invalid_authority,
        abortForCleanup(&copied_permit, &copied_cleanup),
    );
    try std.testing.expectEqual(AbortResult.aborted, abort(&permit, seed));
    try std.testing.expect(resetSpent(&permit, &cleanup, seed));
}

test "terminal poison invalidates intact permit when cleanup descriptor is untrusted" {
    var permit = PreparedAuthorityPermit{};
    var cleanup = FrozenCleanupSeed{};
    const seed = testSeed(&permit, &cleanup);
    try std.testing.expectEqual(
        PrepareResult.prepared,
        prepare(&permit, &cleanup, seed),
    );
    cleanup.digest[0] ^= 1;
    try std.testing.expectEqual(
        CleanupAbortResult.invalid_authority,
        abortForCleanup(&permit, &cleanup),
    );
    try std.testing.expect(validate(&permit, seed));
    try std.testing.expect(poisonPreparedForTerminal(&permit));
    try std.testing.expect(!validate(&permit, seed));
    try std.testing.expectEqual(PermitLifecycle.aborted, permit.lifecycle);
}

test "occupied cleanup or both destinations preserve both records" {
    var permit = PreparedAuthorityPermit{};
    var cleanup = FrozenCleanupSeed{};
    cleanup.lifecycle = .consumed;
    var seed = testSeed(&permit, &cleanup);
    const cleanup_before = cleanup;
    try std.testing.expectEqual(
        PrepareResult.destination_not_empty,
        prepare(&permit, &cleanup, seed),
    );
    try std.testing.expectEqualDeep(PreparedAuthorityPermit{}, permit);
    try std.testing.expectEqualDeep(cleanup_before, cleanup);

    permit.version = 7;
    seed = testSeed(&permit, &cleanup);
    const permit_before = permit;
    try std.testing.expectEqual(
        PrepareResult.destination_not_empty,
        prepare(&permit, &cleanup, seed),
    );
    try std.testing.expectEqualDeep(permit_before, permit);
    try std.testing.expectEqualDeep(cleanup_before, cleanup);
}
