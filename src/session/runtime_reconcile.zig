//! Persistent runtime manifest와 complete host inventory의 순수 reconciliation.
//!
//! partial prefix를 complete empty snapshot으로 오인하지 못하게 host별 snapshot 자체를 tagged union으로 받는다.
//! socket/attach/UI는 이 모듈 밖이며, 결과는 candidate일 뿐 live→ended나 runtime adoption을 commit하지 않는다.

const std = @import("std");
const workspace = @import("workspace.zig");

pub const max_runtime_bindings = workspace.max_runtime_bindings;
pub const max_inventory_hosts: usize = 16;

pub const BindingState = workspace.RuntimeState;

/// Coordinator가 workspace surface 위치와 함께 canonical `(host_id,runtime_id)` 순서로 만든 binding.
/// legacy bare ID는 current host가 exact하면 그 ID+`exact=false`, 아니면 host_id=0+`exact=false`다.
pub const Binding = struct {
    host_id: u128,
    runtime_id: u128,
    state: BindingState,
    exact: bool,
    /// R2a validator가 canonical workspace traversal 순서로 부여한 dense ordinal(정확히 0..bindings.len-1).
    /// 실제 tab/pane array index가 아니며 상위 coordinator가 이 ordinal과 UI slot을 별도로 대응한다.
    manifest_index: usize,
};

pub const Runtime = struct {
    runtime_id: u128,
};

/// Delayed page/result/action의 ABA를 막는 app-local+host authority. 모든 필드는 commit 때 재검증한다.
pub const Authority = struct {
    host_id: u128,
    adapter_generation: u64,
    upgrade_epoch: u64,
    authority_generation: u64,
    membership_generation: u64,
    workspace_generation: u64,
};

pub const UnavailableReason = enum {
    endpoint,
    protocol,
    lifecycle,
    malformed,
    stale,
    cap_exceeded,
    generation_changed,
    out_of_memory,
};

pub const HostInventory = union(enum) {
    unavailable: struct {
        host_id: u128,
        reason: UnavailableReason,
    },
    complete: struct {
        authority: Authority,
        /// Strict ascending runtime_id, duplicate 없음. Adapter가 모든 page를 같은 generation으로 모은 뒤에만 만든다.
        runtimes: []const Runtime,
    },

    pub fn hostId(self: HostInventory) u128 {
        return switch (self) {
            .unavailable => |v| v.host_id,
            .complete => |v| v.authority.host_id,
        };
    }
};

pub const RelationKind = enum {
    live_present_candidate,
    live_missing_candidate,
    ended_absent,
    ended_present_conflict,
    host_unavailable,
    legacy_unresolved,
};

pub const BindingRelation = struct {
    manifest_index: usize,
    kind: RelationKind,
    authority: ?Authority = null,
};

pub const RecoveryCandidate = union(enum) {
    /// R2a canonical placement가 이미 있으므로 generic orphan tab이 아니라 tombstone 제자리 부활 후보다.
    ended_present_conflict: struct {
        manifest_index: usize,
        runtime_id: u128,
        authority: Authority,
    },
    /// Manifest 어느 exact/bare placement에도 없는 inert virtual row 후보다.
    orphan: struct {
        runtime_id: u128,
        authority: Authority,
    },
};

pub const Result = struct {
    relations: []BindingRelation,
    candidates: []RecoveryCandidate,
};

pub const Error = error{
    TooManyBindings,
    TooManyHosts,
    TooManyInventoryRuntimes,
    InvalidBinding,
    DuplicateOrUnsortedBinding,
    DuplicateManifestIndex,
    DuplicateOrUnsortedHost,
    DuplicateOrUnsortedRuntime,
    InvalidAuthority,
    MissingOutputCapacity,
};

/// 입력과 출력은 caller-owned다. 성공해도 host attach/spawn/terminate/checkpoint 효과는 없다.
/// `bindings`와 `hosts`는 canonical ascending, complete snapshot의 runtimes도 ascending이어야 한다.
pub fn reconcile(
    bindings: []const Binding,
    hosts: []const HostInventory,
    relation_out: []BindingRelation,
    candidate_out: []RecoveryCandidate,
) Error!Result {
    if (bindings.len > max_runtime_bindings) return error.TooManyBindings;
    if (hosts.len > max_inventory_hosts) return error.TooManyHosts;
    if (relation_out.len < bindings.len) return error.MissingOutputCapacity;
    try validateBindings(bindings);
    var total_runtimes: usize = 0;
    try validateHosts(hosts, &total_runtimes);
    if (total_runtimes > max_runtime_bindings) return error.TooManyInventoryRuntimes;
    if (candidate_out.len < total_runtimes) return error.MissingOutputCapacity;

    var candidate_len: usize = 0;
    for (bindings, 0..) |binding, i| {
        var relation: BindingRelation = .{
            .manifest_index = binding.manifest_index,
            .kind = undefined,
        };
        if (!binding.exact and binding.host_id == 0) {
            relation.kind = .legacy_unresolved;
            relation_out[i] = relation;
            continue;
        }
        const host = findHost(hosts, binding.host_id) orelse {
            relation.kind = if (binding.exact) .host_unavailable else .legacy_unresolved;
            relation_out[i] = relation;
            continue;
        };
        switch (host) {
            .unavailable => {
                relation.kind = if (binding.exact) .host_unavailable else .legacy_unresolved;
            },
            .complete => |snapshot| {
                const present = findRuntime(snapshot.runtimes, binding.runtime_id);
                relation.authority = snapshot.authority;
                if (!binding.exact) {
                    // bare는 present일 때만 기존 attach 후보다. absent를 host 없는 durable ended로 만들 수 없다.
                    relation.kind = if (present) .live_present_candidate else .legacy_unresolved;
                } else if (binding.state == .live) {
                    relation.kind = if (present) .live_present_candidate else .live_missing_candidate;
                } else if (present) {
                    relation.kind = .ended_present_conflict;
                    candidate_out[candidate_len] = .{ .ended_present_conflict = .{
                        .manifest_index = binding.manifest_index,
                        .runtime_id = binding.runtime_id,
                        .authority = snapshot.authority,
                    } };
                    candidate_len += 1;
                } else {
                    relation.kind = .ended_absent;
                }
            },
        }
        relation_out[i] = relation;
    }

    // complete inventory만 recovery 후보를 낸다. ended exact도 placement를 예약하므로 generic orphan에서 제외한다.
    for (hosts) |host| switch (host) {
        .unavailable => {},
        .complete => |snapshot| for (snapshot.runtimes) |runtime| {
            if (bindingClaimsRuntime(bindings, snapshot.authority.host_id, runtime.runtime_id)) continue;
            candidate_out[candidate_len] = .{ .orphan = .{
                .runtime_id = runtime.runtime_id,
                .authority = snapshot.authority,
            } };
            candidate_len += 1;
        },
    };
    return .{
        .relations = relation_out[0..bindings.len],
        .candidates = candidate_out[0..candidate_len],
    };
}

fn validateBindings(bindings: []const Binding) Error!void {
    var manifest_indices = [_]bool{false} ** max_runtime_bindings;
    for (bindings, 0..) |binding, i| {
        if (binding.runtime_id == 0 or
            (binding.exact and binding.host_id == 0) or
            (!binding.exact and binding.state == .ended))
            return error.InvalidBinding;
        if (binding.manifest_index >= bindings.len or manifest_indices[binding.manifest_index])
            return error.DuplicateManifestIndex;
        manifest_indices[binding.manifest_index] = true;
        if (i == 0) continue;
        const prior = bindings[i - 1];
        if (binding.host_id < prior.host_id or
            (binding.host_id == prior.host_id and binding.runtime_id <= prior.runtime_id))
            return error.DuplicateOrUnsortedBinding;
    }
}

fn validateHosts(hosts: []const HostInventory, total_runtimes: *usize) Error!void {
    var workspace_generation: ?u64 = null;
    for (hosts, 0..) |host, i| {
        const host_id = host.hostId();
        if (host_id == 0 or (i > 0 and host_id <= hosts[i - 1].hostId()))
            return error.DuplicateOrUnsortedHost;
        switch (host) {
            .unavailable => {},
            .complete => |snapshot| {
                if (snapshot.authority.adapter_generation == 0 or
                    snapshot.authority.authority_generation == 0 or
                    snapshot.authority.membership_generation == 0 or
                    snapshot.authority.workspace_generation == 0)
                    return error.InvalidAuthority;
                if (workspace_generation) |expected| {
                    if (snapshot.authority.workspace_generation != expected)
                        return error.InvalidAuthority;
                } else workspace_generation = snapshot.authority.workspace_generation;
                total_runtimes.* = std.math.add(usize, total_runtimes.*, snapshot.runtimes.len) catch
                    return error.TooManyInventoryRuntimes;
                for (snapshot.runtimes, 0..) |runtime, runtime_index| {
                    if (runtime.runtime_id == 0 or
                        (runtime_index > 0 and runtime.runtime_id <= snapshot.runtimes[runtime_index - 1].runtime_id))
                        return error.DuplicateOrUnsortedRuntime;
                }
            },
        }
    }
}

fn findHost(hosts: []const HostInventory, wanted: u128) ?HostInventory {
    var lo: usize = 0;
    var hi = hosts.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const id = hosts[mid].hostId();
        if (id < wanted) {
            lo = mid + 1;
        } else if (id > wanted) {
            hi = mid;
        } else return hosts[mid];
    }
    return null;
}

fn findRuntime(runtimes: []const Runtime, wanted: u128) bool {
    var lo: usize = 0;
    var hi = runtimes.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const id = runtimes[mid].runtime_id;
        if (id < wanted) {
            lo = mid + 1;
        } else if (id > wanted) {
            hi = mid;
        } else return true;
    }
    return false;
}

fn bindingClaimsRuntime(bindings: []const Binding, host_id: u128, runtime_id: u128) bool {
    // bindings도 canonical ascending이라 lower-bound lookup. exact ended도 예약 placement이고,
    // current host로 resolve된 bare도 generic orphan 중복을 막는다.
    var lo: usize = 0;
    var hi = bindings.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const binding = bindings[mid];
        if (binding.host_id < host_id or
            (binding.host_id == host_id and binding.runtime_id < runtime_id))
        {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    if (lo < bindings.len and bindings[lo].host_id == host_id and bindings[lo].runtime_id == runtime_id)
        return true;
    // unresolved legacy bare ID는 어느 exact host를 뜻하는지 아직 모른다. 같은 runtime ID를 어느 host에서든
    // generic orphan으로 노출하면 잘못된 두 번째 canonical placement를 만들 수 있어 resolve 전까지 suppress한다.
    for (bindings) |binding| {
        if (binding.host_id != 0) break; // canonical sort상 unresolved bare는 prefix다.
        if (!binding.exact and binding.runtime_id == runtime_id) return true;
    }
    return false;
}

/// Delayed row/action이 수집 당시 authority와 정확히 같은지 commit 경계에서 쓰는 단일 비교점.
pub fn authorityMatches(expected: Authority, current: Authority) bool {
    return std.meta.eql(expected, current);
}

fn authority(host_id: u128, membership_generation: u64) Authority {
    return .{
        .host_id = host_id,
        .adapter_generation = 1,
        .upgrade_epoch = 2,
        .authority_generation = 1,
        .membership_generation = membership_generation,
        .workspace_generation = 3,
    };
}

test "runtime reconcile: ended present는 tombstone conflict이고 generic orphan이 아니다" {
    const a = authority(1, 10);
    const bindings = [_]Binding{
        .{ .host_id = 1, .runtime_id = 10, .state = .live, .exact = true, .manifest_index = 0 },
        .{ .host_id = 1, .runtime_id = 20, .state = .ended, .exact = true, .manifest_index = 1 },
    };
    const runtimes = [_]Runtime{ .{ .runtime_id = 10 }, .{ .runtime_id = 20 }, .{ .runtime_id = 30 } };
    const hosts = [_]HostInventory{.{ .complete = .{ .authority = a, .runtimes = &runtimes } }};
    var relations: [bindings.len]BindingRelation = undefined;
    var candidates: [runtimes.len]RecoveryCandidate = undefined;
    const result = try reconcile(&bindings, &hosts, &relations, &candidates);
    try std.testing.expectEqual(RelationKind.live_present_candidate, result.relations[0].kind);
    try std.testing.expectEqual(RelationKind.ended_present_conflict, result.relations[1].kind);
    try std.testing.expectEqual(@as(usize, 2), result.candidates.len);
    try std.testing.expectEqual(@as(usize, 1), result.candidates[0].ended_present_conflict.manifest_index);
    try std.testing.expectEqual(@as(u128, 30), result.candidates[1].orphan.runtime_id);
}

test "runtime reconcile: complete miss는 candidate이고 unavailable/legacy miss는 영구 종료가 아니다" {
    const bindings = [_]Binding{
        .{ .host_id = 0, .runtime_id = 1, .state = .live, .exact = false, .manifest_index = 0 },
        .{ .host_id = 1, .runtime_id = 2, .state = .live, .exact = true, .manifest_index = 1 },
        .{ .host_id = 2, .runtime_id = 3, .state = .live, .exact = true, .manifest_index = 2 },
    };
    const hosts = [_]HostInventory{
        .{ .complete = .{ .authority = authority(1, 1), .runtimes = &.{} } },
        .{ .unavailable = .{ .host_id = 2, .reason = .endpoint } },
    };
    var relations: [bindings.len]BindingRelation = undefined;
    var candidates: [0]RecoveryCandidate = undefined;
    const result = try reconcile(&bindings, &hosts, &relations, &candidates);
    try std.testing.expectEqual(RelationKind.legacy_unresolved, result.relations[0].kind);
    try std.testing.expectEqual(RelationKind.live_missing_candidate, result.relations[1].kind);
    try std.testing.expectEqual(RelationKind.host_unavailable, result.relations[2].kind);
}

test "runtime reconcile: resolved bare는 present만 candidate이고 absent면 unresolved다" {
    const bindings = [_]Binding{
        .{ .host_id = 1, .runtime_id = 4, .state = .live, .exact = false, .manifest_index = 0 },
        .{ .host_id = 1, .runtime_id = 5, .state = .live, .exact = false, .manifest_index = 1 },
    };
    const hosts = [_]HostInventory{.{ .complete = .{
        .authority = authority(1, 1),
        .runtimes = &.{.{ .runtime_id = 4 }},
    } }};
    var relations: [bindings.len]BindingRelation = undefined;
    var candidates: [1]RecoveryCandidate = undefined;
    const result = try reconcile(&bindings, &hosts, &relations, &candidates);
    try std.testing.expectEqual(RelationKind.live_present_candidate, result.relations[0].kind);
    try std.testing.expectEqual(RelationKind.legacy_unresolved, result.relations[1].kind);
}

test "runtime reconcile: partial/unsorted/duplicate snapshots는 표현되거나 publish될 수 없다" {
    var relations: [1]BindingRelation = undefined;
    var candidates: [2]RecoveryCandidate = undefined;
    const bad_runtime_order = [_]Runtime{ .{ .runtime_id = 2 }, .{ .runtime_id = 1 } };
    try std.testing.expectError(
        error.DuplicateOrUnsortedRuntime,
        reconcile(
            &.{},
            &.{.{ .complete = .{ .authority = authority(1, 1), .runtimes = &bad_runtime_order } }},
            &relations,
            &candidates,
        ),
    );
    try std.testing.expectError(
        error.InvalidAuthority,
        reconcile(
            &.{},
            &.{.{ .complete = .{
                .authority = .{
                    .host_id = 1,
                    .adapter_generation = 0,
                    .upgrade_epoch = 0,
                    .authority_generation = 1,
                    .membership_generation = 1,
                    .workspace_generation = 1,
                },
                .runtimes = &.{},
            } }},
            &relations,
            &candidates,
        ),
    );
}

test "runtime reconcile: unresolved bare는 같은 ID를 어느 host에서도 orphan으로 노출하지 않는다" {
    const bindings = [_]Binding{
        .{ .host_id = 0, .runtime_id = 7, .state = .live, .exact = false, .manifest_index = 0 },
    };
    const hosts = [_]HostInventory{
        .{ .complete = .{ .authority = authority(1, 1), .runtimes = &.{.{ .runtime_id = 7 }} } },
        .{ .complete = .{ .authority = authority(2, 1), .runtimes = &.{.{ .runtime_id = 7 }} } },
    };
    var relations: [1]BindingRelation = undefined;
    var candidates: [2]RecoveryCandidate = undefined;
    const result = try reconcile(&bindings, &hosts, &relations, &candidates);
    try std.testing.expectEqual(RelationKind.legacy_unresolved, result.relations[0].kind);
    try std.testing.expectEqual(@as(usize, 0), result.candidates.len);
}

test "runtime reconcile: invalid identity와 duplicate manifest ordinal은 fail closed다" {
    var relations: [2]BindingRelation = undefined;
    var candidates: [0]RecoveryCandidate = undefined;
    try std.testing.expectError(
        error.InvalidBinding,
        reconcile(
            &.{.{ .host_id = 0, .runtime_id = 1, .state = .live, .exact = true, .manifest_index = 0 }},
            &.{},
            &relations,
            &candidates,
        ),
    );
    try std.testing.expectError(
        error.InvalidBinding,
        reconcile(
            &.{.{ .host_id = 1, .runtime_id = 1, .state = .ended, .exact = false, .manifest_index = 0 }},
            &.{},
            &relations,
            &candidates,
        ),
    );
    try std.testing.expectError(
        error.DuplicateManifestIndex,
        reconcile(
            &.{
                .{ .host_id = 1, .runtime_id = 1, .state = .live, .exact = true, .manifest_index = 0 },
                .{ .host_id = 1, .runtime_id = 2, .state = .live, .exact = true, .manifest_index = 0 },
            },
            &.{},
            &relations,
            &candidates,
        ),
    );
}

test "runtime reconcile: host cap과 authority ABA 비교를 고정한다" {
    var hosts: [max_inventory_hosts + 1]HostInventory = undefined;
    for (&hosts, 0..) |*host, i| host.* = .{ .unavailable = .{
        .host_id = i + 1,
        .reason = .endpoint,
    } };
    var relations: [0]BindingRelation = undefined;
    var candidates: [0]RecoveryCandidate = undefined;
    _ = try reconcile(&.{}, hosts[0..max_inventory_hosts], &relations, &candidates);
    try std.testing.expectError(
        error.TooManyHosts,
        reconcile(&.{}, &hosts, &relations, &candidates),
    );
    const before = authority(1, 1);
    var after = before;
    try std.testing.expect(authorityMatches(before, after));
    after.authority_generation += 1;
    try std.testing.expect(!authorityMatches(before, after));
    after = before;
    after.membership_generation += 1;
    try std.testing.expect(!authorityMatches(before, after));

    var other_authority = authority(2, 1);
    other_authority.workspace_generation += 1;
    const mixed = [_]HostInventory{
        .{ .complete = .{ .authority = before, .runtimes = &.{} } },
        .{ .complete = .{ .authority = other_authority, .runtimes = &.{} } },
    };
    try std.testing.expectError(
        error.InvalidAuthority,
        reconcile(&.{}, &mixed, &relations, &candidates),
    );
}

test "runtime reconcile: exact global cap과 cap+1을 workspace SSOT로 제한한다" {
    const allocator = std.testing.allocator;
    const runtimes = try allocator.alloc(Runtime, max_runtime_bindings + 1);
    defer allocator.free(runtimes);
    for (runtimes, 0..) |*runtime, i| runtime.* = .{ .runtime_id = i + 1 };
    var relations: [0]BindingRelation = undefined;
    const candidates = try allocator.alloc(RecoveryCandidate, max_runtime_bindings + 1);
    defer allocator.free(candidates);
    const exact = try reconcile(
        &.{},
        &.{.{ .complete = .{
            .authority = authority(1, 1),
            .runtimes = runtimes[0..max_runtime_bindings],
        } }},
        &relations,
        candidates,
    );
    try std.testing.expectEqual(max_runtime_bindings, exact.candidates.len);
    try std.testing.expectError(
        error.TooManyInventoryRuntimes,
        reconcile(
            &.{},
            &.{.{ .complete = .{ .authority = authority(1, 1), .runtimes = runtimes } }},
            &relations,
            candidates,
        ),
    );
}
