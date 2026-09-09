//! Contract tests for the held-file to Release-semantics bridge.

const std = @import("std");
const bridge = @import("release_adapter_remote_release_semantic_files");
const semantics = @import("release_adapter_remote_release_semantics");
const evidence = @import("release_evidence");
const assets = @import("release_adapter_remote_release_assets");
const metadata = @import("release_adapter_remote_release_metadata");
const asset_tests = @import("session_host_release_adapter_remote_release_assets.zig");
const semantic_tests = @import("session_host_release_adapter_remote_release_semantics.zig");

test "held APFS manifest and evidence publish baseline semantic owner" {
    var semantic_fixture = try semantic_tests.Fixture.init(.baseline_a);
    defer semantic_fixture.deinit();
    var fixture: asset_tests.Fixture = undefined;
    try fixture.initWithPayloads(.{ "dmg", "host", semantic_fixture.evidence_bytes, semantic_fixture.manifest_bytes });
    defer fixture.deinit();
    try fixture.run();
    var result: semantics.Owner = .{};
    try bridge.bind(std.testing.allocator, asset_tests.context(), &fixture.result, &result);
    defer result.deinit(std.testing.allocator) catch {};
    try std.testing.expectEqual(evidence.Profile.baseline_a, result.value().?.profile);
    try std.testing.expectEqual(@as(u64, 88), result.value().?.release_id);
}

test "held APFS manifest and evidence publish upgrade semantic owner" {
    var semantic_fixture = try semantic_tests.Fixture.init(.upgrade_b);
    defer semantic_fixture.deinit();
    var fixture: asset_tests.Fixture = undefined;
    try fixture.initWithPayloadsNamed(.{ "dmg", "host", semantic_fixture.evidence_bytes, semantic_fixture.manifest_bytes }, "upgrade-evidence.json");
    defer fixture.deinit();
    try fixture.run();
    var result: semantics.Owner = .{};
    try bridge.bind(std.testing.allocator, asset_tests.context(), &fixture.result, &result);
    defer result.deinit(std.testing.allocator) catch {};
    try std.testing.expectEqual(evidence.Profile.upgrade_b, result.value().?.profile);
}

test "held APFS descriptors are read before invalid semantic bytes fail closed" {
    var fixture: asset_tests.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.run();
    var result: semantics.Owner = .{};
    try std.testing.expectError(error.NonCanonical, bridge.bind(std.testing.allocator, asset_tests.context(), &fixture.result, &result));
    try std.testing.expect(result.value() == null);
}

test "reader failure publishes no semantic owner and leaves downloaded assets caller-owned" {
    var fixture: asset_tests.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.run();
    const open_fds = try countOpenFds();
    var reader = FailingReader{};
    var result: semantics.Owner = .{};
    try std.testing.expectError(error.InjectedReadFailure, bridge.bindWith(&reader, std.testing.allocator, asset_tests.context(), &fixture.result, &result));
    try std.testing.expect(result.value() == null);
    try std.testing.expect(fixture.result.value() != null);
    try std.testing.expectEqual(open_fds, try countOpenFds());
}

test "fence drift during descriptor read fails closed without leaking the borrowed fd" {
    var fixture: asset_tests.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.run();
    const open_fds = try countOpenFds();
    var reader = DriftingReader{ .fence = &fixture.fence };
    var result: semantics.Owner = .{};
    try std.testing.expectError(error.InvalidFence, bridge.bindWith(&reader, std.testing.allocator, asset_tests.context(), &fixture.result, &result));
    fixture.fence.before.release_id -= 1;
    try std.testing.expect(result.value() == null);
    try std.testing.expect(fixture.result.value() != null);
    try std.testing.expectEqual(open_fds, try countOpenFds());
}

test "preowned semantic result fails before held-file IO" {
    var fixture: asset_tests.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.run();
    var reader = CountingReader{};
    var result: semantics.Owner = .{ .release_id = 1 };
    try std.testing.expectError(error.InvalidOwner, bridge.bindWith(&reader, std.testing.allocator, asset_tests.context(), &fixture.result, &result));
    try std.testing.expectEqual(@as(usize, 0), reader.calls);
}

test "every bridge allocation failure unwinds without publishing" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationPath, .{});
}

test "oversized canonical role is rejected before allocation or descriptor IO" {
    var source = FakeAssets.init();
    source.view.assets[@intFromEnum(metadata.Role.manifest)].size = @import("release_manifest").max_manifest_bytes + 1;
    var reader = CountingReader{};
    var result: semantics.Owner = .{};
    try std.testing.expectError(error.AssetTooLarge, bridge.bindWith(&reader, std.testing.allocator, asset_tests.context(), &source, &result));
    try std.testing.expectEqual(@as(usize, 0), reader.calls);
    try std.testing.expect(result.value() == null);
}

test "overlapping source and result are rejected before source observation" {
    var storage: [@max(@sizeOf(FakeAssets), @sizeOf(semantics.Owner))]u8 align(@max(@alignOf(FakeAssets), @alignOf(semantics.Owner))) = @splat(0);
    const source: *FakeAssets = @ptrCast(&storage);
    const result: *semantics.Owner = @ptrCast(&storage);
    var reader = CountingReader{};
    try std.testing.expectError(error.InvalidOwner, bridge.bindWith(&reader, std.testing.allocator, asset_tests.context(), source, result));
    try std.testing.expectEqual(@as(usize, 0), reader.calls);
}

fn allocationPath(allocator: std.mem.Allocator) !void {
    var semantic_fixture = try semantic_tests.Fixture.init(.baseline_a);
    defer semantic_fixture.deinit();
    var fixture: asset_tests.Fixture = undefined;
    try fixture.initWithPayloads(.{ "dmg", "host", semantic_fixture.evidence_bytes, semantic_fixture.manifest_bytes });
    defer fixture.deinit();
    try fixture.run();
    var result: semantics.Owner = .{};
    try bridge.bind(allocator, asset_tests.context(), &fixture.result, &result);
    try result.deinit(allocator);
}

const FailingReader = struct {
    pub fn readExact(_: *@This(), _: std.c.fd_t, _: []u8) !void {
        return error.InjectedReadFailure;
    }
};

const CountingReader = struct {
    calls: usize = 0,
    pub fn readExact(self: *@This(), _: std.c.fd_t, _: []u8) !void {
        self.calls += 1;
    }
};

const DriftingReader = struct {
    fence: *@import("release_adapter_remote_release_fence").Fence,
    calls: usize = 0,
    pub fn readExact(self: *@This(), fd: std.c.fd_t, bytes: []u8) !void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            const amount = std.c.pread(fd, bytes[offset..].ptr, bytes.len - offset, @intCast(offset));
            if (amount <= 0) return error.FileChanged;
            offset += @intCast(amount);
        }
        if (self.calls == 0) self.fence.before.release_id += 1;
        self.calls += 1;
    }
};

const FakeAssets = struct {
    observations: usize = 0,
    view: assets.View,
    remote: metadata.Owner = .{},

    fn init() @This() {
        var view: assets.View = undefined;
        for (&view.assets, 0..) |*asset, index| asset.* = .{
            .role = @enumFromInt(index),
            .id = 1000 + index,
            .name = "asset",
            .path = "/tmp/asset",
            .device = 1,
            .inode = 100 + index,
            .size = 1,
            .sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        };
        return .{ .view = view };
    }
    pub fn remaining(self: *@This()) !i128 {
        self.observations += 1;
        return 1;
    }
    pub fn revalidate(self: *@This()) !assets.View {
        self.observations += 1;
        return self.view;
    }
    pub fn openAssetDescriptor(_: *@This(), _: metadata.Role) !std.c.fd_t {
        return error.UnexpectedDescriptorOpen;
    }
    pub fn metadataOwner(self: *@This()) !*const metadata.Owner {
        return &self.remote;
    }
};

fn countOpenFds() !usize {
    var dir = try std.Io.Dir.openDirAbsolute(std.testing.io, "/dev/fd", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var iterator = dir.iterate();
    var count: usize = 0;
    while (try iterator.next(std.testing.io)) |_| count += 1;
    return count;
}
