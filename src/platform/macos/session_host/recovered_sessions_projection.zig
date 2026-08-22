//! CR6a Recovered Sessions의 app-global 파생 projection owner.
//!
//! Workspace binding과 완결된 inventory snapshot만 받아 inert virtual row를 만든다. socket/attach/spawn/
//! terminate/checkpoint API는 소유하지 않으며 refresh 실패 시 기존 projection을 보존한다.

const std = @import("std");
const maru = @import("maru");
const reconcile = maru.session.runtime_reconcile;
const workspace = maru.session.workspace;

pub const SystemGroup = enum { recovered_sessions };
pub const CandidateKind = enum { orphan, ended_present_conflict };

pub const Row = struct {
    system_group: SystemGroup = .recovered_sessions,
    kind: CandidateKind,
    host_id: u128,
    runtime_id: u128,
    manifest_index: ?usize,
    authority: reconcile.Authority,
    projection_generation: u64,
    label: [8]u8,
};

pub const Context = struct {
    keep_alive: bool,
    primary_window: bool,
    quick_window: bool,
    workspace_generation: u64,
};

pub const Projection = struct {
    rows: []Row = &.{},
    storage: []Row = &.{},
    generation: u64 = 0,

    pub fn deinit(self: *Projection, allocator: std.mem.Allocator) void {
        if (self.storage.len != 0) allocator.free(self.storage);
        self.* = .{};
    }

    pub fn refresh(self: *Projection, allocator: std.mem.Allocator, context: Context, ws: workspace.Workspace, inventories: []const reconcile.HostInventory) !void {
        // 비소유 Window/opt-out은 "빈 결과로 교체"가 아니라 publication 자체가 0이다. secondary가 늦게 호출돼
        // primary의 app-global rows를 지우는 것을 구조적으로 막는다.
        if (!context.keep_alive or !context.primary_window or context.quick_window) return;
        if (context.workspace_generation == 0) return error.InvalidAuthority;
        const next_generation = std.math.add(u64, self.generation, 1) catch return error.GenerationOverflow;
        var next_rows: []Row = &.{};
        errdefer if (next_rows.len != 0) allocator.free(next_rows);
        next_rows = try buildRows(allocator, context.workspace_generation, next_generation, ws, inventories);

        const old_storage = self.storage;
        self.rows = next_rows;
        self.storage = next_rows;
        self.generation = next_generation;
        if (old_storage.len != 0) allocator.free(old_storage);
    }

    /// Fresh authority 검증과 topology commit이 모두 끝난 정확한 action만 목록에서 제거한다. caller가 들고 있던
    /// index는 rebuild/refresh 사이에 stale할 수 있으므로 전체 row를 다시 대조하고, 성공 suffix는 allocation-free다.
    pub fn validateExact(self: *const Projection, index: usize, expected: Row) !u64 {
        if (index >= self.rows.len or self.generation == 0 or
            self.generation != expected.projection_generation or
            !std.meta.eql(self.rows[index], expected))
            return error.InvalidAuthority;
        return std.math.add(u64, self.generation, 1) catch error.GenerationOverflow;
    }

    pub fn consumeExactNoFail(self: *Projection, index: usize, expected: Row, next_generation: u64) void {
        const recomputed = self.validateExact(index, expected) catch
            @panic("recovered sessions projection authority drift after topology commit");
        if (recomputed != next_generation)
            @panic("recovered sessions projection generation drift after topology commit");
        var cursor = index;
        while (cursor + 1 < self.rows.len) : (cursor += 1)
            self.rows[cursor] = self.rows[cursor + 1];
        self.rows = self.rows[0 .. self.rows.len - 1];
        self.generation = next_generation;
        for (self.rows) |*row| row.projection_generation = next_generation;
    }
};

fn buildRows(allocator: std.mem.Allocator, workspace_generation: u64, projection_generation: u64, ws: workspace.Workspace, inventories: []const reconcile.HostInventory) ![]Row {
    var bindings = try collectBindings(allocator, ws);
    defer bindings.deinit(allocator);
    // Dead registry entries are retained by discovery as evidence for exact saved bindings, but an
    // unreferenced dead host cannot produce an orphan row. Do not let crash/SIGKILL residue consume
    // the live-host reconciliation cap a second time. Complete inventories always remain; an
    // unavailable inventory remains only when an exact workspace binding needs its terminal proof.
    const relevant_hosts = try allocator.alloc(reconcile.HostInventory, inventories.len);
    defer allocator.free(relevant_hosts);
    var relevant_len: usize = 0;
    for (inventories) |inventory| {
        const relevant = switch (inventory) {
            .complete => |value| blk: {
                if (value.authority.workspace_generation != workspace_generation)
                    return error.InvalidAuthority;
                break :blk true;
            },
            .unavailable => |value| blk: {
                for (bindings.items) |binding| {
                    if (binding.exact and binding.host_id == value.host_id) break :blk true;
                }
                break :blk false;
            },
        };
        if (relevant) {
            relevant_hosts[relevant_len] = inventory;
            relevant_len += 1;
        }
    }
    const relations = try allocator.alloc(reconcile.BindingRelation, bindings.items.len);
    defer allocator.free(relations);
    const candidates = try allocator.alloc(reconcile.RecoveryCandidate, reconcile.max_runtime_bindings);
    defer allocator.free(candidates);
    const result = try reconcile.reconcile(bindings.items, relevant_hosts[0..relevant_len], relations, candidates);
    const rows = try allocator.alloc(Row, result.candidates.len);
    errdefer allocator.free(rows);
    for (result.candidates, rows) |candidate, *row| row.* = switch (candidate) {
        .orphan => |value| makeRow(.orphan, value.authority, value.runtime_id, null, workspace_generation, projection_generation),
        .ended_present_conflict => |value| makeRow(.ended_present_conflict, value.authority, value.runtime_id, value.manifest_index, workspace_generation, projection_generation),
    };
    return rows;
}

fn makeRow(kind: CandidateKind, authority: reconcile.Authority, runtime_id: u128, manifest_index: ?usize, workspace_generation: u64, projection_generation: u64) Row {
    var label: [8]u8 = undefined;
    _ = std.fmt.bufPrint(&label, "{x:0>8}", .{@as(u32, @truncate(runtime_id))}) catch unreachable;
    std.debug.assert(authority.workspace_generation == workspace_generation);
    return .{ .kind = kind, .host_id = authority.host_id, .runtime_id = runtime_id, .manifest_index = manifest_index, .authority = authority, .projection_generation = projection_generation, .label = label };
}

fn collectBindings(allocator: std.mem.Allocator, ws: workspace.Workspace) !std.ArrayListUnmanaged(reconcile.Binding) {
    var out: std.ArrayListUnmanaged(reconcile.Binding) = .empty;
    errdefer out.deinit(allocator);
    var manifest_index: usize = 0;
    for (ws.windows) |window| for (window.tabs) |tab| for (tab.panes) |pane| for (pane.surfaces) |surface| {
        if (surface.runtime_id.len == 0) continue;
        if (manifest_index == reconcile.max_runtime_bindings) return error.TooManyBindings;
        const runtime_id = parseCanonicalId(surface.runtime_id) orelse return error.InvalidBinding;
        const exact = surface.runtime_host_id.len != 0;
        const host_id = if (exact) parseCanonicalId(surface.runtime_host_id) orelse return error.InvalidBinding else 0;
        try out.append(allocator, .{ .host_id = host_id, .runtime_id = runtime_id, .state = surface.runtime_state, .exact = exact, .manifest_index = manifest_index });
        manifest_index += 1;
    };
    std.mem.sort(reconcile.Binding, out.items, {}, struct {
        fn lessThan(_: void, a: reconcile.Binding, b: reconcile.Binding) bool {
            return a.host_id < b.host_id or (a.host_id == b.host_id and a.runtime_id < b.runtime_id);
        }
    }.lessThan);
    return out;
}

fn parseCanonicalId(bytes: []const u8) ?u128 {
    if (bytes.len != 32) return null;
    for (bytes) |byte| if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f')) return null;
    const value = std.fmt.parseInt(u128, bytes, 16) catch return null;
    return if (value == 0) null else value;
}

fn testAuthority(host_id: u128, workspace_generation: u64) reconcile.Authority {
    return .{ .host_id = host_id, .adapter_generation = 2, .upgrade_epoch = 3, .authority_generation = 4, .membership_generation = 5, .workspace_generation = workspace_generation };
}

test "CR6a recovered projection은 primary에 orphan과 ended conflict만 inert row로 게시한다" {
    const surfaces = [_]workspace.Surface{
        .{ .runtime_host_id = "00000000000000000000000000000001", .runtime_id = "0000000000000000000000000000000a", .runtime_state = .ended },
        .{ .runtime_host_id = "00000000000000000000000000000001", .runtime_id = "0000000000000000000000000000000b" },
    };
    const panes = [_]workspace.Pane{.{ .surfaces = &surfaces }};
    const tabs = [_]workspace.Tab{.{ .tree = &.{.{ .leaf = 0 }}, .panes = &panes }};
    const windows = [_]workspace.Window{.{ .tabs = &tabs }};
    const runtimes = [_]reconcile.Runtime{ .{ .runtime_id = 10 }, .{ .runtime_id = 11 }, .{ .runtime_id = 12 } };
    const hosts = [_]reconcile.HostInventory{.{ .complete = .{ .authority = testAuthority(1, 7), .runtimes = &runtimes } }};
    var projection: Projection = .{};
    defer projection.deinit(std.testing.allocator);
    try projection.refresh(std.testing.allocator, .{ .keep_alive = true, .primary_window = true, .quick_window = false, .workspace_generation = 7 }, .{ .windows = &windows }, &hosts);
    try std.testing.expectEqual(@as(u64, 1), projection.generation);
    try std.testing.expectEqual(@as(usize, 2), projection.rows.len);
    try std.testing.expectEqual(CandidateKind.ended_present_conflict, projection.rows[0].kind);
    try std.testing.expectEqual(@as(?usize, 0), projection.rows[0].manifest_index);
    try std.testing.expectEqual(CandidateKind.orphan, projection.rows[1].kind);
    try std.testing.expectEqual(@as(u128, 12), projection.rows[1].runtime_id);
    try std.testing.expectEqualStrings("0000000c", &projection.rows[1].label);
}

test "CR6a recovered projection은 unreferenced dead host residue가 live orphan을 가리지 않게 한다" {
    const dead_count = reconcile.max_inventory_hosts + 4;
    var hosts: [dead_count + 1]reconcile.HostInventory = undefined;
    for (hosts[0..dead_count], 0..) |*host, index| host.* = .{ .unavailable = .{
        .host_id = @as(u128, index) + 1,
        .reason = .lifecycle,
    } };
    const runtimes = [_]reconcile.Runtime{.{ .runtime_id = 0xabc }};
    hosts[dead_count] = .{ .complete = .{
        .authority = testAuthority(0x100, 7),
        .runtimes = &runtimes,
    } };

    var projection: Projection = .{};
    defer projection.deinit(std.testing.allocator);
    try projection.refresh(std.testing.allocator, .{
        .keep_alive = true,
        .primary_window = true,
        .quick_window = false,
        .workspace_generation = 7,
    }, .{ .windows = &.{} }, &hosts);
    try std.testing.expectEqual(@as(usize, 1), projection.rows.len);
    try std.testing.expectEqual(@as(u128, 0x100), projection.rows[0].host_id);
    try std.testing.expectEqual(@as(u128, 0xabc), projection.rows[0].runtime_id);
}

test "CR6a recovered projection은 opt-out secondary quick과 refresh 실패에서 권위를 보존한다" {
    var projection: Projection = .{};
    defer projection.deinit(std.testing.allocator);
    const empty: workspace.Workspace = .{ .windows = &.{} };
    inline for ([_]Context{
        .{ .keep_alive = false, .primary_window = true, .quick_window = false, .workspace_generation = 1 },
        .{ .keep_alive = true, .primary_window = false, .quick_window = false, .workspace_generation = 1 },
        .{ .keep_alive = true, .primary_window = true, .quick_window = true, .workspace_generation = 1 },
    }) |context| {
        try projection.refresh(std.testing.allocator, context, empty, &.{});
        try std.testing.expectEqual(@as(usize, 0), projection.rows.len);
        try std.testing.expectEqual(@as(u64, 0), projection.generation);
    }
    const before = projection;
    try std.testing.expectError(error.InvalidAuthority, projection.refresh(std.testing.allocator, .{ .keep_alive = true, .primary_window = true, .quick_window = false, .workspace_generation = 0 }, empty, &.{}));
    try std.testing.expectEqual(before.generation, projection.generation);
    try std.testing.expectEqual(before.rows.ptr, projection.rows.ptr);
}

test "CR6a recovered projection은 OOM과 noncanonical binding authority drift에서 기존 snapshot을 보존한다" {
    const initial = try std.testing.allocator.alloc(Row, 1);
    var projection: Projection = .{ .rows = initial, .storage = initial, .generation = 9 };
    defer projection.deinit(std.testing.allocator);
    projection.rows[0] = makeRow(.orphan, testAuthority(1, 1), 2, null, 1, 9);
    const before_ptr = projection.rows.ptr;

    const runtimes = [_]reconcile.Runtime{.{ .runtime_id = 3 }};
    const hosts = [_]reconcile.HostInventory{.{ .complete = .{ .authority = testAuthority(1, 1), .runtimes = &runtimes } }};
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, projection.refresh(failing.allocator(), .{
        .keep_alive = true,
        .primary_window = true,
        .quick_window = false,
        .workspace_generation = 1,
    }, .{ .windows = &.{} }, &hosts));
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(@as(u64, 9), projection.generation);
    try std.testing.expectEqual(before_ptr, projection.rows.ptr);

    const bad_surface = [_]workspace.Surface{.{ .runtime_host_id = "00000000000000000000000000000001", .runtime_id = "0000000000000000000000000000000A" }};
    const bad_pane = [_]workspace.Pane{.{ .surfaces = &bad_surface }};
    const bad_tab = [_]workspace.Tab{.{ .tree = &.{.{ .leaf = 0 }}, .panes = &bad_pane }};
    const bad_window = [_]workspace.Window{.{ .tabs = &bad_tab }};
    try std.testing.expectError(error.InvalidBinding, projection.refresh(std.testing.allocator, .{
        .keep_alive = true,
        .primary_window = true,
        .quick_window = false,
        .workspace_generation = 1,
    }, .{ .windows = &bad_window }, &hosts));
    try std.testing.expectEqual(@as(u64, 9), projection.generation);
    try std.testing.expectEqual(before_ptr, projection.rows.ptr);

    var drift_hosts = hosts;
    drift_hosts[0].complete.authority.workspace_generation = 2;
    try std.testing.expectError(error.InvalidAuthority, projection.refresh(std.testing.allocator, .{
        .keep_alive = true,
        .primary_window = true,
        .quick_window = false,
        .workspace_generation = 1,
    }, .{ .windows = &.{} }, &drift_hosts));
    try std.testing.expectEqual(@as(u64, 9), projection.generation);
    try std.testing.expectEqual(before_ptr, projection.rows.ptr);

    projection.generation = std.math.maxInt(u64);
    try std.testing.expectError(error.GenerationOverflow, projection.refresh(std.testing.allocator, .{
        .keep_alive = true,
        .primary_window = true,
        .quick_window = false,
        .workspace_generation = 1,
    }, .{ .windows = &.{} }, &hosts));
    try std.testing.expectEqual(std.math.maxInt(u64), projection.generation);
    try std.testing.expectEqual(before_ptr, projection.rows.ptr);
}

test "CR6b recovered projection exact consume은 sibling을 보존하고 세대를 함께 전진한다" {
    const runtimes = [_]reconcile.Runtime{ .{ .runtime_id = 10 }, .{ .runtime_id = 11 } };
    const hosts = [_]reconcile.HostInventory{.{ .complete = .{
        .authority = testAuthority(1, 7),
        .runtimes = &runtimes,
    } }};
    var projection: Projection = .{};
    defer projection.deinit(std.testing.allocator);
    try projection.refresh(std.testing.allocator, .{
        .keep_alive = true,
        .primary_window = true,
        .quick_window = false,
        .workspace_generation = 7,
    }, .{ .windows = &.{} }, &hosts);
    try std.testing.expectEqual(@as(usize, 2), projection.rows.len);
    const consumed = projection.rows[0];
    const sibling_runtime = projection.rows[1].runtime_id;
    const next = try projection.validateExact(0, consumed);
    projection.consumeExactNoFail(0, consumed, next);
    try std.testing.expectEqual(@as(usize, 1), projection.rows.len);
    try std.testing.expectEqual(sibling_runtime, projection.rows[0].runtime_id);
    try std.testing.expectEqual(next, projection.rows[0].projection_generation);
    try std.testing.expectError(error.InvalidAuthority, projection.validateExact(0, consumed));
}
