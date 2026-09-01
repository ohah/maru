const std = @import("std");
const manifest = @import("release_manifest");
const composition = @import("release_adapter_github_current_compatibility");
const current_input = @import("release_adapter_github_current_manifest_input");
const current_product = @import("release_adapter_github_current_product");

const expected: manifest.Compatibility = .{ .mrsh_major = 2, .screen_codec = 2, .handoff_reader_min = 1, .handoff_reader_max = 1, .app_host_abi = 180 };
const sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa".*;

const Current = struct {
    copied: bool = false,
    drift: bool = false,
    const Candidate = struct { compatibility: manifest.Compatibility };
    const View = struct { manifest: *const Candidate };
    const candidate = Candidate{ .compatibility = expected };
    const drifted = Candidate{ .compatibility = .{ .mrsh_major = 3, .screen_codec = 2, .handoff_reader_min = 1, .handoff_reader_max = 1, .app_host_abi = 180 } };
    pub fn value(self: *const @This()) ?View {
        if (self.copied) return null;
        return .{ .manifest = if (self.drift) &drifted else &candidate };
    }
};

const Product = struct {
    copied: bool = false,
    calls: usize = 0,
    mutate_after_probe: bool = false,
    mutate_parent: bool = false,
    seal_checks: usize = 0,
    const Identity = struct { device: u64, inode: u64 };
    const Frozen = struct { identity: Identity, size: u64, mode: u32, sha256: [64]u8 };
    const View = struct { frozen: Frozen };
    pub fn revalidate(self: *@This(), path: [:0]const u8) !View {
        try std.testing.expectEqualStrings("/tmp/frozen-maru", path);
        if (self.copied) return error.InvalidOwner;
        self.calls += 1;
        var observed_sha = sha;
        if (self.mutate_after_probe and self.calls == 2) observed_sha[0] = 'b';
        return .{ .frozen = .{ .identity = .{ .device = 7, .inode = 9 }, .size = 11, .mode = 0o100755, .sha256 = observed_sha } };
    }
    const Seal = struct { generation: usize };
    pub fn pathMutationSeal(self: *@This()) !Seal {
        return .{ .generation = self.seal_checks };
    }
    pub fn executableDirectoryDescriptor(_: *@This()) !std.c.fd_t {
        return 77;
    }
    pub fn validatePathMutationSeal(self: *@This(), seal: Seal) !void {
        self.seal_checks += 1;
        if (self.mutate_parent or seal.generation != 0) return error.PathChanged;
    }
};

const Probe = struct {
    output: []const u8 = "{\"mrsh_major\":2,\"screen_codec\":2,\"handoff_reader_min\":1,\"handoff_reader_max\":1,\"app_host_abi\":180}\n",
    calls: usize = 0,
    pub fn run(self: *@This(), _: std.Io, executable: [:0]const u8, directory_fd: std.c.fd_t, relative_executable: [:0]const u8, buffer: []u8, budget_ns: i128) ![]const u8 {
        try std.testing.expectEqualStrings("/tmp/frozen-maru", executable);
        try std.testing.expectEqual(@as(std.c.fd_t, 77), directory_fd);
        try std.testing.expectEqualStrings("./frozen-maru", relative_executable);
        try std.testing.expect(budget_ns > 0);
        self.calls += 1;
        if (self.output.len > buffer.len) return error.OutputTooLarge;
        @memcpy(buffer[0..self.output.len], self.output);
        return buffer[0..self.output.len];
    }
};

test "canonical frozen probe publishes exact manifest compatibility and sha" {
    var probe = Probe{};
    var current = Current{};
    var product = Product{};
    var result: composition.CurrentCompatibility = .{};
    var output: [composition.max_probe_bytes]u8 = undefined;
    try composition.composeWith(&probe, std.testing.io, &current, &product, "/tmp/frozen-maru", &output, 1_000_000, &result);
    const view = result.value() orelse return error.TestUnexpectedResult;
    try std.testing.expect(manifest.equalCompatibility(expected, view.compatibility));
    try std.testing.expectEqualSlices(u8, &sha, &view.executable_sha256);
    try std.testing.expectEqual(@as(usize, 2), product.calls);
    var copied = result;
    try std.testing.expect(copied.value() == null);
    try result.deinit();
}

test "strict probe parser rejects field shape canonical and range drift" {
    for ([_][]const u8{
        "{}",
        "{\"mrsh_major\":2,\"mrsh_major\":2,\"screen_codec\":2,\"handoff_reader_min\":1,\"handoff_reader_max\":1,\"app_host_abi\":180}",
        "{\"mrsh_major\":2,\"screen_codec\":2,\"handoff_reader_min\":1,\"handoff_reader_max\":1,\"app_host_abi\":180,\"extra\":1}",
        "{\"mrsh_major\":02,\"screen_codec\":2,\"handoff_reader_min\":1,\"handoff_reader_max\":1,\"app_host_abi\":180}",
        "{\"mrsh_major\":2,\"screen_codec\":2,\"handoff_reader_min\":2,\"handoff_reader_max\":1,\"app_host_abi\":180}",
        "{\"mrsh_major\":2,\"screen_codec\":2,\"handoff_reader_min\":1,\"handoff_reader_max\":1,\"app_host_abi\":180} null",
    }) |bytes| try std.testing.expectError(error.InvalidProbe, composition.parse(bytes));
}

test "owner manifest product and post-probe executable drift publish nothing" {
    inline for (.{ "current", "manifest", "product", "mutation", "parent" }) |failure| {
        var probe = Probe{};
        var current = Current{ .copied = std.mem.eql(u8, failure, "current"), .drift = std.mem.eql(u8, failure, "manifest") };
        var product = Product{ .copied = std.mem.eql(u8, failure, "product"), .mutate_after_probe = std.mem.eql(u8, failure, "mutation"), .mutate_parent = std.mem.eql(u8, failure, "parent") };
        var result: composition.CurrentCompatibility = .{};
        var output: [composition.max_probe_bytes]u8 = undefined;
        const wanted = if (std.mem.eql(u8, failure, "current")) error.InvalidCurrent else if (std.mem.eql(u8, failure, "manifest")) error.CompatibilityMismatch else error.FrozenChanged;
        try std.testing.expectError(wanted, composition.composeWith(&probe, std.testing.io, &current, &product, "/tmp/frozen-maru", &output, 1_000_000, &result));
        try std.testing.expect(result.value() == null);
    }
}

test "malformed probe preowned result and nonpositive budget fail closed" {
    var current = Current{};
    var product = Product{};
    var output: [composition.max_probe_bytes]u8 = undefined;
    var malformed = Probe{ .output = "not-json" };
    var result: composition.CurrentCompatibility = .{};
    try std.testing.expectError(error.InvalidProbe, composition.composeWith(&malformed, std.testing.io, &current, &product, "/tmp/frozen-maru", &output, 1, &result));
    result.owner = &result;
    var probe = Probe{};
    try std.testing.expectError(error.InvalidOwner, composition.composeWith(&probe, std.testing.io, &current, &product, "/tmp/frozen-maru", &output, 1, &result));
    result = .{};
    try std.testing.expectError(error.InvalidBudget, composition.composeWith(&probe, std.testing.io, &current, &product, "/tmp/frozen-maru", &output, 0, &result));
    result.executable_sha256[0] = 'a';
    try std.testing.expectError(error.InvalidOwner, composition.composeWith(&probe, std.testing.io, &current, &product, "/tmp/frozen-maru", &output, 1, &result));
    result = .{};
    const alias = std.mem.asBytes(&result)[0..1];
    try std.testing.expectError(error.InvalidOwner, composition.composeWith(&probe, std.testing.io, &current, &product, "/tmp/frozen-maru", alias, 1, &result));
}

test "capture storage cannot overlap current product or frozen pathname authority" {
    var probe = Probe{};
    var product = Product{};
    var result: composition.CurrentCompatibility = .{};

    var current_storage: [@sizeOf(Current)]u8 align(@alignOf(Current)) = @splat(0);
    const current: *Current = @ptrCast(&current_storage);
    current.* = .{};
    try std.testing.expectError(error.InvalidOwner, composition.composeWith(&probe, std.testing.io, current, &product, "/tmp/frozen-maru", &current_storage, 1, &result));

    var current_value = Current{};
    var product_storage: [@sizeOf(Product)]u8 align(@alignOf(Product)) = @splat(0);
    const product_alias: *Product = @ptrCast(&product_storage);
    product_alias.* = .{};
    try std.testing.expectError(error.InvalidOwner, composition.composeWith(&probe, std.testing.io, &current_value, product_alias, "/tmp/frozen-maru", &product_storage, 1, &result));

    var pathname_storage: ["/tmp/frozen-maru".len:0]u8 = "/tmp/frozen-maru".*;
    try std.testing.expectError(error.InvalidOwner, composition.composeWith(&probe, std.testing.io, &current_value, &product, &pathname_storage, pathname_storage[0..], 1, &result));
    try std.testing.expectEqual(@as(usize, 0), probe.calls);
}

test "production owner types instantiate the compatibility boundary" {
    var probe = Probe{};
    var current: current_input.CurrentManifestInput = .{};
    var product: current_product.CurrentProduct = .{};
    var result: composition.CurrentCompatibility = .{};
    var output: [composition.max_probe_bytes]u8 = undefined;
    try std.testing.expectError(error.InvalidCurrent, composition.composeWith(&probe, std.testing.io, &current, &product, "/tmp/frozen-maru", &output, 1, &result));
}
