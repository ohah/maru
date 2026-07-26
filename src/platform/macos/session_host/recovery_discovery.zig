//! R2b recovery discovery: secure host registry 열거와 격리된 read-only inventory 수집.
//!
//! 이 모듈은 spawn/adopt/attach/terminate/checkpoint API를 노출하지 않는다. 따라서 실패나 partial 결과가
//! canonical 연결과 runtime 수명에 영향을 줄 수 없고, 제품 coordinator는 `complete`만 publish할 수 있다.

const std = @import("std");
const c = std.c;
const posix = std.posix;
const client_mod = @import("client.zig");
const host_connect = @import("host_connect.zig");
const host_manifest = @import("host_manifest.zig");
const owner_lease = @import("owner_lease.zig");
const protocol = @import("protocol.zig");
const reconcile = @import("maru").session.runtime_reconcile;
extern "c" fn __error() *c_int;

pub const max_hosts = reconcile.max_inventory_hosts;
pub const max_total_pages: usize = 31;

pub const Candidate = struct {
    manifest: host_manifest.Manifest,

    pub fn deinit(self: *Candidate) void {
        self.manifest.deinit();
        self.* = undefined;
    }
};

pub const EntryUnavailable = enum { invalid_manifest, lease_free, lease_unknown };

pub const Entry = union(enum) {
    candidate: Candidate,
    unavailable: struct {
        host_id: u128,
        reason: EntryUnavailable,
    },

    fn deinit(self: *Entry) void {
        switch (self.*) {
            .candidate => |*value| value.deinit(),
            .unavailable => {},
        }
        self.* = undefined;
    }
};

pub const DiscoveryUnavailable = enum {
    registry_unavailable,
    too_many_hosts,
    out_of_memory,
};

pub const Discovery = union(enum) {
    unavailable: DiscoveryUnavailable,
    complete: []Entry,

    pub fn deinit(self: *Discovery, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .unavailable => {},
            .complete => |items| {
                for (items) |*item| item.deinit();
                allocator.free(items);
            },
        }
        self.* = undefined;
    }
};

/// Current-UID secure registry에서 살아 있는 exact manifest만 canonical host_id 순서로 반환한다.
/// 잘못된 entry는 cap 안에서 다른 host를 가리지 않지만, 17번째 canonical entry부터는 prefix 전체를 폐기한다.
pub fn discover(allocator: std.mem.Allocator, session_dir: [:0]const u8) Discovery {
    host_manifest.validateRegistryRoot(session_dir) catch return .{ .unavailable = .registry_unavailable };
    var hosts_buf: [640]u8 = undefined;
    const hosts_root = host_manifest.hostsRootPathIn(&hosts_buf, session_dir) catch
        return .{ .unavailable = .registry_unavailable };
    const directory = c.opendir(hosts_root.ptr) orelse return .{ .unavailable = .registry_unavailable };
    defer _ = c.closedir(directory);

    var entries: std.ArrayListUnmanaged(Entry) = .empty;
    var entries_transferred = false;
    defer if (!entries_transferred) deinitEntryList(allocator, &entries);
    var entry_count: usize = 0;
    while (true) {
        __error().* = 0;
        const entry = c.readdir(directory) orelse {
            if (__error().* != 0) return .{ .unavailable = .registry_unavailable };
            break;
        };
        const name = std.mem.sliceTo(entry.name[0..], 0);
        if (!isCanonicalHostName(name)) continue;
        const host_id = std.fmt.parseInt(u128, name, 16) catch continue;
        if (!reserveRegistryEntry(&entry_count))
            return .{ .unavailable = .too_many_hosts };
        var manifest = host_manifest.load(allocator, session_dir, host_id) catch |err| switch (err) {
            error.OutOfMemory => return .{ .unavailable = .out_of_memory },
            else => {
                entries.append(allocator, .{ .unavailable = .{
                    .host_id = host_id,
                    .reason = .invalid_manifest,
                } }) catch return .{ .unavailable = .out_of_memory };
                continue;
            },
        };
        if (manifest.lifecycle != .ready) {
            manifest.deinit();
            entries.append(allocator, .{ .unavailable = .{
                .host_id = host_id,
                .reason = .invalid_manifest,
            } }) catch return .{ .unavailable = .out_of_memory };
            continue;
        }
        const lease = leaseObservation(session_dir, host_id);
        if (lease != .held) {
            manifest.deinit();
            entries.append(allocator, .{ .unavailable = .{
                .host_id = host_id,
                .reason = if (lease == .free) .lease_free else .lease_unknown,
            } }) catch return .{ .unavailable = .out_of_memory };
            continue;
        }
        entries.append(allocator, .{ .candidate = .{ .manifest = manifest } }) catch {
            manifest.deinit();
            return .{ .unavailable = .out_of_memory };
        };
    }
    std.mem.sort(Entry, entries.items, {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            return entryHostId(a) < entryHostId(b);
        }
    }.lessThan);
    const owned = entries.toOwnedSlice(allocator) catch
        return .{ .unavailable = .out_of_memory };
    entries_transferred = true;
    return .{ .complete = owned };
}

fn reserveRegistryEntry(count: *usize) bool {
    if (count.* == max_hosts) return false;
    count.* += 1;
    return true;
}

fn entryHostId(entry: Entry) u128 {
    return switch (entry) {
        .candidate => |value| value.manifest.host_id,
        .unavailable => |value| value.host_id,
    };
}

fn isCanonicalHostName(name: []const u8) bool {
    if (name.len != 32 or std.mem.eql(u8, name, "00000000000000000000000000000000")) return false;
    for (name) |byte| if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f')) return false;
    return true;
}

fn leaseObservation(session_dir: [:0]const u8, host_id: u128) owner_lease.Observation {
    var path_buf: [832]u8 = undefined;
    const path = host_manifest.ownerLockPathIn(&path_buf, session_dir, host_id) catch return .unknown;
    return owner_lease.observe(path);
}

pub const CollectionUnavailable = enum {
    too_many_hosts,
    too_many_runtimes,
    too_many_pages,
    out_of_memory,
    invalid_authority,
    invalid_candidate,
};

pub const Collection = union(enum) {
    unavailable: CollectionUnavailable,
    complete: []reconcile.HostInventory,

    pub fn deinit(self: *Collection, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .unavailable => {},
            .complete => |items| {
                for (items) |item| switch (item) {
                    .unavailable => {},
                    .complete => |value| allocator.free(value.runtimes),
                };
                allocator.free(items);
            },
        }
        self.* = undefined;
    }
};

const AggregateBudget = struct {
    runtimes: usize = 0,
    pages: usize = 0,

    fn add(self: *AggregateBudget, runtime_count: usize, page_count: usize) Error!void {
        const next_runtimes = std.math.add(usize, self.runtimes, runtime_count) catch
            return error.TooManyRuntimes;
        const next_pages = std.math.add(usize, self.pages, page_count) catch
            return error.TooManyPages;
        if (next_runtimes > protocol.max_inventory_runtimes) return error.TooManyRuntimes;
        if (next_pages > max_total_pages) return error.TooManyPages;
        self.runtimes = next_runtimes;
        self.pages = next_pages;
    }

    const Error = error{ TooManyRuntimes, TooManyPages };
};

/// 후보별 새 connection을 열고 닫는다. 반환 Client를 pool에 넣지 않으므로 malformed/OOM/transport가 canonical
/// adapter를 poison할 수 없다. `adapter_generations`는 discovery 시점 HostPool snapshot과 1:1이어야 한다.
pub fn collect(
    allocator: std.mem.Allocator,
    base_cache_dir: []const u8,
    candidates: []const Candidate,
    adapter_generations: []const u64,
    workspace_generation: u64,
) Collection {
    if (candidates.len > max_hosts or candidates.len != adapter_generations.len)
        return .{ .unavailable = .too_many_hosts };
    if (workspace_generation == 0) return .{ .unavailable = .invalid_authority };
    var previous_host_id: u128 = 0;
    for (candidates, adapter_generations) |candidate, adapter_generation| {
        if (adapter_generation == 0) return .{ .unavailable = .invalid_authority };
        const descriptor = candidate.manifest.descriptor();
        if (descriptor.host_id == 0 or descriptor.lifecycle != .ready or
            descriptor.host_id <= previous_host_id)
            return .{ .unavailable = .invalid_candidate };
        previous_host_id = descriptor.host_id;
    }
    var out: std.ArrayListUnmanaged(reconcile.HostInventory) = .empty;
    var out_transferred = false;
    defer if (!out_transferred) deinitInventoryList(allocator, &out);
    var budget: AggregateBudget = .{};
    for (candidates, adapter_generations) |candidate, adapter_generation| {
        const host_id = candidate.manifest.host_id;
        const outcome = host_connect.connectDiscoveredHost(
            allocator,
            base_cache_dir,
            candidate.manifest.descriptor(),
        );
        var client = switch (outcome) {
            .connected => |value| value,
            .failed => |reason| {
                out.append(allocator, unavailableInventory(host_id, connectReason(reason))) catch
                    return .{ .unavailable = .out_of_memory };
                continue;
            },
        };
        defer client.deinit();
        var consumed_pages: u8 = 0;
        const inventory = client.runtimeInventoryBounded(
            max_total_pages - budget.pages,
            &consumed_pages,
        ) catch |err| {
            budget.add(0, consumed_pages) catch return .{ .unavailable = .too_many_pages };
            out.append(allocator, unavailableInventory(
                host_id,
                if (err == error.OutOfMemory) .out_of_memory else .protocol,
            )) catch return .{ .unavailable = .out_of_memory };
            continue;
        };
        budget.add(0, consumed_pages) catch return .{ .unavailable = .too_many_pages };
        switch (inventory) {
            .unavailable => |value| {
                out.append(allocator, unavailableInventory(host_id, inventoryReason(value.reason))) catch
                    return .{ .unavailable = .out_of_memory };
            },
            .complete => |complete_value| {
                var complete = complete_value;
                defer complete.deinit(allocator);
                budget.add(complete.runtime_ids.len, 0) catch |err| return .{
                    .unavailable = if (err == error.TooManyRuntimes) .too_many_runtimes else .too_many_pages,
                };
                const runtimes = allocator.alloc(reconcile.Runtime, complete.runtime_ids.len) catch
                    return .{ .unavailable = .out_of_memory };
                for (runtimes, complete.runtime_ids) |*dst, runtime_id| dst.* = .{ .runtime_id = runtime_id };
                out.append(allocator, .{ .complete = .{
                    .authority = .{
                        .host_id = host_id,
                        .adapter_generation = adapter_generation,
                        .upgrade_epoch = complete.upgrade_epoch,
                        .authority_generation = complete.authority_generation,
                        .membership_generation = complete.membership_generation,
                        .workspace_generation = workspace_generation,
                    },
                    .runtimes = runtimes,
                } }) catch {
                    allocator.free(runtimes);
                    return .{ .unavailable = .out_of_memory };
                };
            },
        }
    }
    const owned = out.toOwnedSlice(allocator) catch
        return .{ .unavailable = .out_of_memory };
    out_transferred = true;
    return .{ .complete = owned };
}

fn unavailableInventory(host_id: u128, reason: reconcile.UnavailableReason) reconcile.HostInventory {
    return .{ .unavailable = .{ .host_id = host_id, .reason = reason } };
}

fn connectReason(reason: host_connect.FailureReason) reconcile.UnavailableReason {
    return switch (reason) {
        .out_of_memory => .out_of_memory,
        .invalid_endpoint, .endpoint_denied, .launch_failed, .startup_timeout, .host_gone, .resource_exhausted, .transient_timeout => .endpoint,
        .invalid_manifest, .stale_manifest => .stale,
        .incompatible_version, .handshake_failed, .protocol_error, .unauthorized => .protocol,
    };
}

fn inventoryReason(reason: client_mod.InventoryUnavailable) reconcile.UnavailableReason {
    return switch (reason) {
        .unsupported, .unauthorized, .host_rejected, .protocol_rejected => .protocol,
        .authority_changed, .generation_changed => .generation_changed,
        .lifecycle_changed => .lifecycle,
        .cap_exceeded => .cap_exceeded,
        .malformed => .malformed,
    };
}

fn deinitInventoryList(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(reconcile.HostInventory),
) void {
    for (list.items) |item| switch (item) {
        .unavailable => {},
        .complete => |value| allocator.free(value.runtimes),
    };
    list.deinit(allocator);
}

fn deinitEntryList(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged(Entry)) void {
    for (list.items) |*item| item.deinit();
    list.deinit(allocator);
}

test "recovery discovery host 이름은 exact lower hex만 허용한다" {
    try std.testing.expect(isCanonicalHostName("00000000000000000000000000000001"));
    try std.testing.expect(!isCanonicalHostName("00000000000000000000000000000000"));
    try std.testing.expect(!isCanonicalHostName("0000000000000000000000000000000A"));
    try std.testing.expect(!isCanonicalHostName("0000000000000000000000000000000g"));
    try std.testing.expect(!isCanonicalHostName("1"));
}

test "recovery discovery는 held exact manifest만 정렬하고 filesystem을 변경하지 않는다" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    var dir_buf: [192]u8 = undefined;
    const dir = std.fmt.bufPrintZ(&dir_buf, "/tmp/maru-recovery-discovery-{d}", .{c.getpid()}) catch
        return error.SkipZigTest;
    _ = c.mkdir(dir.ptr, 0o700);
    defer _ = c.rmdir(dir.ptr);

    const ids = [_]u128{ 0x20, 0x10 };
    var publications: [ids.len]host_manifest.Published = undefined;
    var leases: [ids.len]owner_lease.OwnerLease = undefined;
    var initialized: usize = 0;
    defer {
        var i: usize = 0;
        while (i < initialized) : (i += 1) {
            var owner_buf: [832]u8 = undefined;
            if (host_manifest.ownerLockPathIn(&owner_buf, dir, ids[i])) |path|
                _ = leases[i].unlinkOwnedWhileLocked(path) catch .absent
            else |_| {}
            leases[i].deinit();
            publications[i].deinit();
            host_manifest.removeEmptyHostDirectories(dir, ids[i]);
        }
    }
    for (ids, 0..) |host_id, i| {
        var endpoint_buf: [128]u8 = undefined;
        const endpoint = try @import("short_endpoint.zig").currentSocketPathIn(&endpoint_buf, host_id);
        publications[i] = try host_manifest.publish(testing.allocator, dir, .{
            .host_id = host_id,
            .build_id = "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            .protocol_major = protocol.version_major,
            .screen_codec_version = @import("screen_stream.zig").codec_version,
            .upgrade_epoch = 1,
            .lifecycle = .ready,
            .endpoint = endpoint,
        });
        var owner_buf: [832]u8 = undefined;
        const owner_path = try host_manifest.ownerLockPathIn(&owner_buf, dir, host_id);
        leases[i] = try owner_lease.OwnerLease.acquire(owner_path);
        initialized += 1;
    }
    const malformed_host_id: u128 = 0x30;
    try host_manifest.prepareHostDirectory(dir, malformed_host_id);
    defer host_manifest.removeEmptyHostDirectories(dir, malformed_host_id);

    var before: [ids.len]posix.Stat = undefined;
    for (ids, 0..) |host_id, i| {
        var path_buf: [832]u8 = undefined;
        const path = try host_manifest.manifestPathIn(&path_buf, dir, host_id);
        try testing.expectEqual(
            @as(c_int, 0),
            c.fstatat(posix.AT.FDCWD, path.ptr, &before[i], posix.AT.SYMLINK_NOFOLLOW),
        );
    }
    var result = discover(testing.allocator, dir);
    defer result.deinit(testing.allocator);
    const entries = switch (result) {
        .complete => |items| items,
        .unavailable => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(@as(usize, 3), entries.len);
    try testing.expectEqual(@as(u128, 0x10), entryHostId(entries[0]));
    try testing.expectEqual(@as(u128, 0x20), entryHostId(entries[1]));
    try testing.expectEqual(malformed_host_id, entryHostId(entries[2]));
    try testing.expectEqual(EntryUnavailable.invalid_manifest, entries[2].unavailable.reason);
    for (ids, 0..) |host_id, i| {
        var path_buf: [832]u8 = undefined;
        const path = try host_manifest.manifestPathIn(&path_buf, dir, host_id);
        var after: posix.Stat = undefined;
        try testing.expectEqual(
            @as(c_int, 0),
            c.fstatat(posix.AT.FDCWD, path.ptr, &after, posix.AT.SYMLINK_NOFOLLOW),
        );
        try testing.expectEqual(before[i].dev, after.dev);
        try testing.expectEqual(before[i].ino, after.ino);
    }
}

test "recovery inventory aggregate budget는 4096 runtime과 31 page exact만 허용한다" {
    var budget: AggregateBudget = .{};
    try budget.add(protocol.max_inventory_runtimes, max_total_pages);
    try std.testing.expectError(error.TooManyRuntimes, budget.add(1, 0));

    var page_budget: AggregateBudget = .{};
    try page_budget.add(1, max_total_pages);
    try std.testing.expectError(error.TooManyPages, page_budget.add(0, 1));
}

test "recovery discovery registry entry cap은 exact 16만 허용하고 17번째 prefix를 거부한다" {
    var count: usize = 0;
    for (0..max_hosts) |_| try std.testing.expect(reserveRegistryEntry(&count));
    try std.testing.expectEqual(max_hosts, count);
    try std.testing.expect(!reserveRegistryEntry(&count));
    try std.testing.expectEqual(max_hosts, count);
}

test "recovery collector는 빈 plan을 complete로 만들고 invalid authority를 fail-close한다" {
    var empty = collect(std.testing.allocator, "/tmp", &.{}, &.{}, 1);
    defer empty.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), empty.complete.len);

    const bytes =
        "{\"schema\":1,\"host_id\":\"00000000000000000000000000000001\",\"build_id\":\"sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\",\"protocol_major\":2,\"screen_codec_version\":2,\"upgrade_epoch\":1,\"lifecycle\":\"ready\",\"endpoint\":\"/tmp/maru-0/sh/00000000000000000000000000000001.sock\"}";
    var manifest = try host_manifest.decode(std.testing.allocator, bytes);
    defer manifest.deinit();
    const candidates = [_]Candidate{.{ .manifest = manifest }};
    const result = collect(std.testing.allocator, "/tmp", &candidates, &.{0}, 1);
    try std.testing.expectEqual(CollectionUnavailable.invalid_authority, result.unavailable);
}
