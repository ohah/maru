const std = @import("std");
const manifest = @import("release_manifest");
const candidate_files = @import("release_adapter_candidate_files");
const candidate_product = @import("release_adapter_candidate_product");
const deadline_mod = @import("release_adapter_deadline");
const compatibility = @import("release_adapter_candidate_compatibility");

const expected: manifest.Compatibility = .{ .mrsh_major = 2, .screen_codec = 2, .handoff_reader_min = 1, .handoff_reader_max = 1, .app_host_abi = 180 };
const sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa".*;
const Authority = struct {
    owner: ?*@This() = null,
    calls: usize = 0,
    drift: bool = false,
    parent_drift: bool = false,
    fn init(self: *@This()) void {
        self.* = .{};
        self.owner = self;
    }
    pub fn revalidate(self: *@This()) !compatibility.AuthorityView {
        if (self.owner != self) return error.InvalidOwner;
        self.calls += 1;
        var observed = sha;
        if (self.drift and self.calls >= 2) observed[0] = 'b';
        return .{ .release_id = 44, .tag = "v1.2.3", .source_commit = "1111111111111111111111111111111111111111", .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3", .run_id = 8, .run_attempt = 2, .frozen_sha256 = observed };
    }
    pub fn executableDirectoryDescriptor(_: *@This()) !std.c.fd_t {
        return 77;
    }
    pub fn pathMutationSeal(_: *@This()) !usize {
        return 1;
    }
    pub fn validatePathMutationSeal(self: *@This(), seal: usize) !void {
        if (self.parent_drift or seal != 1) return error.FileChanged;
    }
};
const Probe = struct {
    output: []const u8 = "{\"mrsh_major\":2,\"screen_codec\":2,\"handoff_reader_min\":1,\"handoff_reader_max\":1,\"app_host_abi\":180}\n",
    foreign: ?[]const u8 = null,
    calls: usize = 0,
    budget: i128 = 0,
    pub fn run(self: *@This(), _: std.Io, executable: [:0]const u8, fd: std.c.fd_t, relative: [:0]const u8, buffer: []u8, budget: i128) ![]const u8 {
        try std.testing.expectEqualStrings("/tmp/frozen-maru", executable);
        try std.testing.expectEqual(@as(std.c.fd_t, 77), fd);
        try std.testing.expectEqualStrings("./frozen-maru", relative);
        self.calls += 1;
        self.budget = budget;
        if (self.foreign) |bytes| return bytes;
        @memcpy(buffer[0..self.output.len], self.output);
        return buffer[0..self.output.len];
    }
};
const Deadline = struct {
    values: []const i128,
    cursor: usize = 0,
    pub fn remaining(self: *@This()) !i128 {
        if (self.cursor == self.values.len) return error.Exhausted;
        const value = self.values[self.cursor];
        self.cursor += 1;
        if (value <= 0) return error.TimedOut;
        return value;
    }
};

test "canonical probe publishes candidate identity and compatibility" {
    var authority: Authority = undefined;
    authority.init();
    var probe = Probe{};
    var deadline = Deadline{ .values = &.{ 100, 70, 40 } };
    var output: [compatibility.max_probe_bytes]u8 = undefined;
    var result: compatibility.CandidateCompatibility = .{};
    try compatibility.composeUntilWith(&probe, &deadline, std.testing.io, &authority, "/tmp/frozen-maru", &output, &result);
    const view = result.value().?;
    try std.testing.expect(manifest.equalCompatibility(expected, view.compatibility));
    try std.testing.expectEqualSlices(u8, &sha, view.executable_sha256);
    try std.testing.expectEqual(@as(usize, 2), authority.calls);
    try result.deinit();
}
test "shared deadline brackets probe and final publication" {
    var authority: Authority = undefined;
    authority.init();
    var probe = Probe{};
    var deadline = Deadline{ .values = &.{ 100, 70, 0 } };
    var output: [compatibility.max_probe_bytes]u8 = undefined;
    var result: compatibility.CandidateCompatibility = .{};
    try std.testing.expectError(error.TimedOut, compatibility.composeUntilWith(&probe, &deadline, std.testing.io, &authority, "/tmp/frozen-maru", &output, &result));
    try std.testing.expectEqual(@as(i128, 70), probe.budget);
    try std.testing.expect(result.value() == null);
}
test "candidate and parent drift publish nothing" {
    inline for (.{ false, true }) |parent| {
        var authority: Authority = undefined;
        authority.init();
        authority.drift = !parent;
        authority.parent_drift = parent;
        var probe = Probe{};
        var deadline = Deadline{ .values = &.{ 100, 70, 40 } };
        var output: [compatibility.max_probe_bytes]u8 = undefined;
        var result: compatibility.CandidateCompatibility = .{};
        try std.testing.expectError(error.CandidateChanged, compatibility.composeUntilWith(&probe, &deadline, std.testing.io, &authority, "/tmp/frozen-maru", &output, &result));
        try std.testing.expect(result.value() == null);
    }
}
test "strict shared parser rejects malformed and noncanonical output" {
    for ([_][]const u8{ "{}", "{\"mrsh_major\":02,\"screen_codec\":2,\"handoff_reader_min\":1,\"handoff_reader_max\":1,\"app_host_abi\":180}", "{\"mrsh_major\":2,\"screen_codec\":2,\"handoff_reader_min\":2,\"handoff_reader_max\":1,\"app_host_abi\":180}" }) |bytes| try std.testing.expectError(error.InvalidProbe, compatibility.parse(bytes));
}
test "copied preowned alias and foreign capture fail closed" {
    var authority: Authority = undefined;
    authority.init();
    var copied = authority;
    var probe = Probe{};
    var deadline = Deadline{ .values = &.{ 100, 70, 40 } };
    var output: [compatibility.max_probe_bytes]u8 = undefined;
    var result: compatibility.CandidateCompatibility = .{};
    try std.testing.expectError(error.InvalidCandidate, compatibility.composeUntilWith(&probe, &deadline, std.testing.io, &copied, "/tmp/frozen-maru", &output, &result));
    result.owner = &result;
    try std.testing.expectError(error.InvalidOwner, compatibility.composeUntilWith(&probe, &deadline, std.testing.io, &authority, "/tmp/frozen-maru", &output, &result));
    result = .{};
    result.tag[0] = 'x';
    try std.testing.expectError(error.InvalidOwner, compatibility.composeUntilWith(&probe, &deadline, std.testing.io, &authority, "/tmp/frozen-maru", &output, &result));
    result = .{};
    const alias = std.mem.asBytes(&result)[0..1];
    try std.testing.expectError(error.InvalidOwner, compatibility.composeUntilWith(&probe, &deadline, std.testing.io, &authority, "/tmp/frozen-maru", alias, &result));
    probe.foreign = "{\"mrsh_major\":2,\"screen_codec\":2,\"handoff_reader_min\":1,\"handoff_reader_max\":1,\"app_host_abi\":180}\n";
    deadline = .{ .values = &.{ 100, 70, 40 } };
    try std.testing.expectError(error.InvalidProbe, compatibility.composeUntilWith(&probe, &deadline, std.testing.io, &authority, "/tmp/frozen-maru", &output, &result));
}
test "production candidate owner types instantiate boundary" {
    var files: candidate_files.CandidateFiles = .{};
    var product: candidate_product.CandidateProduct = .{};
    var deadline: deadline_mod.Deadline = .{};
    try deadline_mod.start(std.time.ns_per_s, &deadline);
    defer deadline.deinit() catch unreachable;
    var output: [compatibility.max_probe_bytes]u8 = undefined;
    var result: compatibility.CandidateCompatibility = .{};
    try std.testing.expectError(error.InvalidCandidate, compatibility.composeUntil(std.testing.io, &files, &product, .{ .dmg = "/tmp/candidate.dmg", .frozen_executable = "/tmp/frozen-maru", .dmg_work = "/tmp/work" }, &output, &deadline, &result));
}
