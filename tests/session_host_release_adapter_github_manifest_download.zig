//! Predecessor manifest bootstrap이 unauthenticated bytes를 bounded caller storage에만 두는지 검증한다.

const std = @import("std");
const manifest = @import("release_manifest");
const bootstrap = @import("release_adapter_github_manifest_download");
const deadline_mod = @import("release_adapter_deadline");
const cli_authority = @import("release_adapter_github_cli_authority");

const bytes = "manifest-bytes";
const digest = "7abe730d8933f3f50dfd2b5e4d8be28fb52cad62481446b6f59860f6be7bed09";

const Mode = enum { success, empty, corrupt, foreign, too_long, timeout };

const Fake = struct {
    mode: Mode = .success,
    calls: usize = 0,
    budget: i128 = 0,

    pub fn capture(self: *@This(), executable: []const u8, args: []const []const u8, environment: []const []const u8, output: []u8, budget_ns: i128) ![]const u8 {
        if (!std.mem.eql(u8, executable, "/opt/trusted/gh") or args.len != 9 or
            !std.mem.eql(u8, args[0], "release") or !std.mem.eql(u8, args[1], "download") or
            !std.mem.eql(u8, args[2], "v1.2.3") or !std.mem.eql(u8, args[3], "--repo") or
            !std.mem.eql(u8, args[4], "ohah/maru") or !std.mem.eql(u8, args[5], "--pattern") or
            !std.mem.eql(u8, args[6], "Maru-1.2.3-session-host-release.json") or
            !std.mem.eql(u8, args[7], "--output") or !std.mem.eql(u8, args[8], "-") or
            environment.len != 2 or !std.mem.eql(u8, environment[0], "GH_TOKEN=secret-token") or
            !std.mem.eql(u8, environment[1], "GH_PROMPT_DISABLED=1") or budget_ns <= 0)
            return error.CaptureFailed;
        self.calls += 1;
        self.budget = budget_ns;
        return switch (self.mode) {
            .success => copied(output, bytes),
            .empty => output[0..0],
            .corrupt => copied(output, "manifest-byteS"),
            .foreign => bytes,
            .too_long => error.OutputTooLarge,
            .timeout => error.TimedOut,
        };
    }
};

const Authority = struct {
    calls: usize = 0,
    pub fn revalidate(self: *@This(), _: std.mem.Allocator, _: [:0]const u8) !void {
        self.calls += 1;
    }
};

const Deadline = struct {
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

fn copied(output: []u8, value: []const u8) []const u8 {
    @memcpy(output[0..value.len], value);
    return output[0..value.len];
}

fn expected() bootstrap.Expected {
    return .{ .tag = "v1.2.3", .sha256 = digest };
}

test "manifest bootstrap derives exact name and closed stdout command" {
    var storage: bootstrap.PlanStorage = undefined;
    const plan = try bootstrap.plan(&storage, expected());
    try std.testing.expectEqualStrings("Maru-1.2.3-session-host-release.json", plan.name);
    const want = [_][]const u8{ "release", "download", "v1.2.3", "--repo", "ohah/maru", "--pattern", "Maru-1.2.3-session-host-release.json", "--output", "-" };
    try std.testing.expectEqual(want.len, plan.args.len);
    for (want, plan.args) |left, right| try std.testing.expectEqualStrings(left, right);

    @memcpy(storage.name[0.."v1.2.3".len], "v1.2.3");
    try std.testing.expectError(error.InvalidOwner, bootstrap.plan(&storage, .{
        .tag = storage.name[0.."v1.2.3".len],
        .sha256 = digest,
    }));
}

test "manifest bootstrap rejects malformed predecessor identity before capture" {
    var storage: bootstrap.PlanStorage = undefined;
    try std.testing.expectError(error.InvalidExpected, bootstrap.plan(&storage, .{ .tag = "latest", .sha256 = digest }));
    try std.testing.expectError(error.InvalidExpected, bootstrap.plan(&storage, .{ .tag = "v1.2.3", .sha256 = "ABC" }));

    var fake = Fake{};
    var output: [manifest.max_manifest_bytes]u8 = undefined;
    try std.testing.expectError(error.InvalidExecutable, bootstrap.fetchWith(&fake, &storage, "gh", "secret-token", expected(), &output, std.time.ns_per_s));
    try std.testing.expectError(error.InvalidToken, bootstrap.fetchWith(&fake, &storage, "/opt/trusted/gh", "bad\ntoken", expected(), &output, std.time.ns_per_s));
    try std.testing.expectError(error.InvalidBudget, bootstrap.fetchWith(&fake, &storage, "/opt/trusted/gh", "secret-token", expected(), &output, 0));
    var oversized: [manifest.max_manifest_bytes + 1]u8 = undefined;
    try std.testing.expectError(error.InvalidOutput, bootstrap.fetchWith(&fake, &storage, "/opt/trusted/gh", "secret-token", expected(), &oversized, std.time.ns_per_s));
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
}

test "manifest bootstrap returns exact supplied-buffer bytes name and digest" {
    var fake = Fake{};
    var storage: bootstrap.PlanStorage = undefined;
    var output: [manifest.max_manifest_bytes]u8 = undefined;
    const observed = try bootstrap.fetchWith(&fake, &storage, "/opt/trusted/gh", "secret-token", expected(), &output, std.time.ns_per_s);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqualStrings(bytes, observed.bytes);
    try std.testing.expect(observed.bytes.ptr == output[0..].ptr);
    try std.testing.expectEqualStrings("Maru-1.2.3-session-host-release.json", observed.name);
    try std.testing.expectEqualStrings(digest, observed.sha256);
}

test "manifest bootstrap rejects empty output" {
    try expectMode(.empty, error.EmptyManifest);
}

test "manifest bootstrap rejects digest mismatch" {
    try expectMode(.corrupt, error.DigestMismatch);
}

test "manifest bootstrap rejects foreign and oversized capture" {
    try expectMode(.foreign, error.InvalidCapture);
    try expectMode(.too_long, error.OutputTooLarge);
    try expectMode(.timeout, error.TimedOut);
}

test "manifest bootstrap product child failure is terminal" {
    var output: [manifest.max_manifest_bytes]u8 = undefined;
    var storage: bootstrap.PlanStorage = undefined;
    try std.testing.expectError(error.ChildFailed, bootstrap.fetch(std.testing.io, &storage, "/usr/bin/false", "secret-token", expected(), &output, std.time.ns_per_s));
}

test "shared deadline crosses CLI manifest child and final observation publication" {
    var authority = Authority{};
    var fake = Fake{};
    var deadline = Deadline{ .values = &.{ 100, 97, 90 } };
    var storage: bootstrap.PlanStorage = undefined;
    var output: [manifest.max_manifest_bytes]u8 = undefined;
    const observed = try bootstrap.fetchUntilWith(&authority, &fake, &deadline, std.testing.allocator, &storage, "/opt/trusted/gh", "secret-token", expected(), &output);
    try std.testing.expectEqualStrings(bytes, observed.bytes);
    try std.testing.expectEqual(@as(usize, 3), deadline.cursor);
    try std.testing.expectEqual(@as(usize, 1), authority.calls);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqual(@as(i128, 97), fake.budget);

    authority = .{};
    fake = .{};
    deadline = .{ .values = &.{ 100, 97, 0 } };
    try std.testing.expectError(error.TimedOut, bootstrap.fetchUntilWith(&authority, &fake, &deadline, std.testing.allocator, &storage, "/opt/trusted/gh", "secret-token", expected(), &output));
    try std.testing.expectEqual(@as(usize, 1), authority.calls);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
}

test "preflight and revalidation expiry start no manifest child" {
    var authority = Authority{};
    var fake = Fake{};
    var deadline = Deadline{ .values = &.{ 100, 0 } };
    var storage: bootstrap.PlanStorage = undefined;
    var output: [manifest.max_manifest_bytes]u8 = undefined;
    try std.testing.expectError(error.InvalidToken, bootstrap.fetchUntilWith(&authority, &fake, &deadline, std.testing.allocator, &storage, "/opt/trusted/gh", "bad\ntoken", expected(), &output));
    try std.testing.expectEqual(@as(usize, 0), deadline.cursor);
    try std.testing.expectEqual(@as(usize, 0), authority.calls);
    try std.testing.expectError(error.TimedOut, bootstrap.fetchUntilWith(&authority, &fake, &deadline, std.testing.allocator, &storage, "/opt/trusted/gh", "secret-token", expected(), &output));
    try std.testing.expectEqual(@as(usize, 1), authority.calls);
    try std.testing.expectEqual(@as(usize, 0), fake.calls);

    authority = .{};
    fake = .{};
    deadline = .{ .values = &.{0} };
    try std.testing.expectError(error.TimedOut, bootstrap.fetchUntilWith(&authority, &fake, &deadline, std.testing.allocator, &storage, "/opt/trusted/gh", "secret-token", expected(), &output));
    try std.testing.expectEqual(@as(usize, 0), authority.calls);
    try std.testing.expectEqual(@as(usize, 0), fake.calls);

    var real_deadline: deadline_mod.Deadline = .{};
    var pinned: cli_authority.PinnedExecutable = undefined;
    try std.testing.expectError(error.InvalidOutput, bootstrap.fetchUntil(std.testing.io, std.testing.allocator, &storage, .{ .path = "/opt/trusted/gh", .pinned = &pinned }, "secret-token", expected(), &.{}, &real_deadline));
}

test "mutable capture deadline and pinned storage remain disjoint" {
    var authority = Authority{};
    var fake = Fake{};
    var deadline = Deadline{ .values = &.{ 100, 97, 90 } };
    var storage: bootstrap.PlanStorage = undefined;
    const storage_output = std.mem.asBytes(&storage);
    try std.testing.expectError(error.InvalidOwner, bootstrap.fetchUntilWith(&authority, &fake, &deadline, std.testing.allocator, &storage, "/opt/trusted/gh", "secret-token", expected(), storage_output));
    try std.testing.expectEqual(@as(usize, 0), deadline.cursor);

    var token_output: [64]u8 = @splat('x');
    @memcpy(token_output[0.."secret-token".len], "secret-token");
    deadline = .{ .values = &.{ 100, 97, 90 } };
    try std.testing.expectError(error.InvalidOwner, bootstrap.fetchUntilWith(&authority, &fake, &deadline, std.testing.allocator, &storage, "/opt/trusted/gh", token_output[0.."secret-token".len], expected(), &token_output));
    try std.testing.expectEqual(@as(usize, 0), deadline.cursor);

    var sha_output: [manifest.max_manifest_bytes]u8 = undefined;
    @memcpy(sha_output[0..digest.len], digest);
    deadline = .{ .values = &.{ 100, 97, 90 } };
    try std.testing.expectError(error.InvalidOwner, bootstrap.fetchUntilWith(&authority, &fake, &deadline, std.testing.allocator, &storage, "/opt/trusted/gh", "secret-token", .{ .tag = "v1.2.3", .sha256 = sha_output[0..digest.len] }, &sha_output));
    try std.testing.expectEqual(@as(usize, 0), deadline.cursor);

    var deadline_output_storage: [@sizeOf(Deadline)]u8 align(@alignOf(Deadline)) = undefined;
    const output_deadline: *Deadline = @ptrCast(&deadline_output_storage);
    output_deadline.* = .{ .values = &.{ 100, 97, 90 } };
    try std.testing.expectError(error.InvalidOwner, bootstrap.fetchUntilWith(&authority, &fake, output_deadline, std.testing.allocator, &storage, "/opt/trusted/gh", "secret-token", expected(), &deadline_output_storage));

    var real_deadline: deadline_mod.Deadline = .{};
    try deadline_mod.start(std.time.ns_per_s, &real_deadline);
    defer real_deadline.deinit() catch unreachable;
    var output: [manifest.max_manifest_bytes]u8 = undefined;
    try std.testing.expectError(error.InvalidOwner, bootstrap.fetchUntil(std.testing.io, std.testing.allocator, &storage, .{ .path = "/opt/trusted/gh", .pinned = @ptrCast(@alignCast(&real_deadline)) }, "secret-token", expected(), &output, &real_deadline));

    var pinned: cli_authority.PinnedExecutable = undefined;
    const pinned_bytes = std.mem.asBytes(&pinned);
    @memset(pinned_bytes, 'x');
    try std.testing.expectError(error.InvalidOwner, bootstrap.fetchUntil(std.testing.io, std.testing.allocator, &storage, .{ .path = "/opt/trusted/gh", .pinned = &pinned }, pinned_bytes[0.."secret".len], expected(), &output, &real_deadline));
    @memcpy(pinned_bytes[0.."v1.2.3".len], "v1.2.3");
    try std.testing.expectError(error.InvalidOwner, bootstrap.fetchUntil(std.testing.io, std.testing.allocator, &storage, .{ .path = "/opt/trusted/gh", .pinned = &pinned }, "secret-token", .{ .tag = pinned_bytes[0.."v1.2.3".len], .sha256 = digest }, &output, &real_deadline));
    @memset(pinned_bytes[0..digest.len], 'a');
    try std.testing.expectError(error.InvalidOwner, bootstrap.fetchUntil(std.testing.io, std.testing.allocator, &storage, .{ .path = "/opt/trusted/gh", .pinned = &pinned }, "secret-token", .{ .tag = "v1.2.3", .sha256 = pinned_bytes[0..digest.len] }, &output, &real_deadline));
}

fn expectMode(mode: Mode, expected_error: anyerror) !void {
    var fake = Fake{ .mode = mode };
    var storage: bootstrap.PlanStorage = undefined;
    var output: [manifest.max_manifest_bytes]u8 = undefined;
    try std.testing.expectError(expected_error, bootstrap.fetchWith(&fake, &storage, "/opt/trusted/gh", "secret-token", expected(), &output, std.time.ns_per_s));
}
