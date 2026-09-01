const std = @import("std");
const manifest = @import("release_manifest");
const deadline_mod = @import("release_adapter_deadline");
const composition = @import("release_adapter_github_current_compatibility");
const current_input = @import("release_adapter_github_current_manifest_input");
const current_product = @import("release_adapter_github_current_product");

const expected: manifest.Compatibility = .{ .mrsh_major = 2, .screen_codec = 2, .handoff_reader_min = 1, .handoff_reader_max = 1, .app_host_abi = 180 };
const sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa".*;

const Current = struct {
    copied: bool = false,
    drift: bool = false,
    invalid: bool = false,
    revalidations: usize = 0,
    const Candidate = struct { compatibility: manifest.Compatibility };
    const View = struct { manifest: *const Candidate };
    const candidate = Candidate{ .compatibility = expected };
    const drifted = Candidate{ .compatibility = .{ .mrsh_major = 3, .screen_codec = 2, .handoff_reader_min = 1, .handoff_reader_max = 1, .app_host_abi = 180 } };
    pub fn value(self: *const @This()) ?View {
        if (self.copied) return null;
        return .{ .manifest = if (self.drift) &drifted else &candidate };
    }
    pub fn revalidate(self: *@This()) !void {
        self.revalidations += 1;
        if (self.copied or self.invalid) return error.InvalidOwner;
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
    budget_ns: i128 = 0,
    mutate_current: ?*Current = null,
    foreign_output: ?[]const u8 = null,
    pub fn run(self: *@This(), _: std.Io, executable: [:0]const u8, directory_fd: std.c.fd_t, relative_executable: [:0]const u8, buffer: []u8, budget_ns: i128) ![]const u8 {
        try std.testing.expectEqualStrings("/tmp/frozen-maru", executable);
        try std.testing.expectEqual(@as(std.c.fd_t, 77), directory_fd);
        try std.testing.expectEqualStrings("./frozen-maru", relative_executable);
        try std.testing.expect(budget_ns > 0);
        self.calls += 1;
        self.budget_ns = budget_ns;
        if (self.mutate_current) |current| current.invalid = true;
        if (self.foreign_output) |foreign| return foreign;
        if (self.output.len > buffer.len) return error.OutputTooLarge;
        @memcpy(buffer[0..self.output.len], self.output);
        return buffer[0..self.output.len];
    }
};

const SharedDeadline = struct {
    values: []const i128,
    cursor: usize = 0,
    pub fn remaining(self: *@This()) !i128 {
        if (self.cursor == self.values.len) return error.DeadlineExhausted;
        const value = self.values[self.cursor];
        self.cursor += 1;
        if (value <= 0) return error.TimedOut;
        return value;
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

test "shared deadline brackets product authority probe and final publication" {
    var probe = Probe{};
    var current = Current{};
    var product = Product{};
    var deadline = SharedDeadline{ .values = &.{ 100, 70, 40 } };
    var result: composition.CurrentCompatibility = .{};
    var output: [composition.max_probe_bytes]u8 = undefined;
    try composition.composeUntilWith(&probe, &deadline, std.testing.io, &current, &product, "/tmp/frozen-maru", &output, &result);
    try std.testing.expectEqual(@as(usize, 3), deadline.cursor);
    try std.testing.expectEqual(@as(i128, 70), probe.budget_ns);
    try std.testing.expectEqual(@as(usize, 2), current.revalidations);
    try result.deinit();

    probe = .{};
    product = .{};
    deadline = .{ .values = &.{ 100, 70, 0 } };
    try std.testing.expectError(error.TimedOut, composition.composeUntilWith(&probe, &deadline, std.testing.io, &current, &product, "/tmp/frozen-maru", &output, &result));
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(@as(usize, 2), product.calls);
    try std.testing.expect(result.value() == null);

    probe = .{};
    product = .{};
    deadline = .{ .values = &.{ 100, 0 } };
    try std.testing.expectError(error.TimedOut, composition.composeUntilWith(&probe, &deadline, std.testing.io, &current, &product, "/tmp/frozen-maru", &output, &result));
    try std.testing.expectEqual(@as(usize, 0), probe.calls);
    try std.testing.expectEqual(@as(usize, 1), product.calls);
    try std.testing.expect(result.value() == null);

    probe = .{};
    product = .{};
    deadline = .{ .values = &.{0} };
    try std.testing.expectError(error.TimedOut, composition.composeUntilWith(&probe, &deadline, std.testing.io, &current, &product, "/tmp/frozen-maru", &output, &result));
    try std.testing.expectEqual(@as(usize, 0), probe.calls);
    try std.testing.expectEqual(@as(usize, 0), product.calls);
    try std.testing.expect(result.value() == null);

    current = .{};
    probe = .{ .mutate_current = &current };
    product = .{};
    deadline = .{ .values = &.{ 100, 70, 40 } };
    try std.testing.expectError(error.InvalidCurrent, composition.composeUntilWith(&probe, &deadline, std.testing.io, &current, &product, "/tmp/frozen-maru", &output, &result));
    try std.testing.expectEqual(@as(usize, 2), deadline.cursor);
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expect(result.value() == null);

    var copied = Current{ .copied = true };
    var untouched = SharedDeadline{ .values = &.{100} };
    try std.testing.expectError(error.InvalidCurrent, composition.composeUntilWith(&probe, &untouched, std.testing.io, &copied, &product, "/tmp/frozen-maru", &output, &result));
    try std.testing.expectEqual(@as(usize, 0), untouched.cursor);

    const result_deadline: *SharedDeadline = @ptrCast(&result);
    try std.testing.expectError(error.InvalidOwner, composition.composeUntilWith(&probe, result_deadline, std.testing.io, &current, &product, "/tmp/frozen-maru", &output, &result));

    const current_deadline: *SharedDeadline = @ptrCast(@alignCast(&current));
    try std.testing.expectError(error.InvalidOwner, composition.composeUntilWith(&probe, current_deadline, std.testing.io, &current, &product, "/tmp/frozen-maru", &output, &result));

    const product_deadline: *SharedDeadline = @ptrCast(@alignCast(&product));
    try std.testing.expectError(error.InvalidOwner, composition.composeUntilWith(&probe, product_deadline, std.testing.io, &current, &product, "/tmp/frozen-maru", &output, &result));

    var output_deadline_storage: [@sizeOf(SharedDeadline)]u8 align(@alignOf(SharedDeadline)) = undefined;
    const output_deadline: *SharedDeadline = @ptrCast(&output_deadline_storage);
    output_deadline.* = .{ .values = &.{100} };
    try std.testing.expectError(error.InvalidOwner, composition.composeUntilWith(&probe, output_deadline, std.testing.io, &current, &product, "/tmp/frozen-maru", &output_deadline_storage, &result));
    try std.testing.expectEqual(@as(usize, 0), output_deadline.cursor);

    var path_deadline_storage: [@sizeOf(SharedDeadline) + 1]u8 align(@alignOf(SharedDeadline)) =
        .{0} ** (@sizeOf(SharedDeadline) + 1);
    const path_deadline: *SharedDeadline = @ptrCast(&path_deadline_storage);
    path_deadline.* = .{ .values = &.{100} };
    try std.testing.expectError(error.InvalidOwner, composition.composeUntilWith(&probe, path_deadline, std.testing.io, &current, &product, path_deadline_storage[0..@sizeOf(SharedDeadline) :0], &output, &result));
    try std.testing.expectEqual(@as(usize, 0), path_deadline.cursor);

    var real_deadline: deadline_mod.Deadline = .{};
    try deadline_mod.start(100, &real_deadline);
    defer real_deadline.deinit() catch unreachable;
    var empty_current: current_input.CurrentManifestInput = .{};
    var empty_product: current_product.CurrentProduct = .{};
    try std.testing.expectError(error.InvalidCurrent, composition.composeUntil(std.testing.io, &empty_current, &empty_product, "/tmp/frozen-maru", &output, &real_deadline, &result));
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

    probe = .{ .foreign_output = "{\"mrsh_major\":2,\"screen_codec\":2,\"handoff_reader_min\":1,\"handoff_reader_max\":1,\"app_host_abi\":180}\n" };
    var output: [composition.max_probe_bytes]u8 = undefined;
    try std.testing.expectError(error.InvalidProbe, composition.composeWith(&probe, std.testing.io, &current_value, &product, "/tmp/frozen-maru", &output, 1, &result));
    try std.testing.expect(result.value() == null);
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
}

test "production owner types instantiate the compatibility boundary" {
    var probe = Probe{};
    var current: current_input.CurrentManifestInput = .{};
    var product: current_product.CurrentProduct = .{};
    var result: composition.CurrentCompatibility = .{};
    var output: [composition.max_probe_bytes]u8 = undefined;
    try std.testing.expectError(error.InvalidCurrent, composition.composeWith(&probe, std.testing.io, &current, &product, "/tmp/frozen-maru", &output, 1, &result));
}
