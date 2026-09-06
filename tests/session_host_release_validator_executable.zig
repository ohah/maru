const std = @import("std");
const validator = @import("release_validator");

const Event = enum { bootstrap, token, pre_publish, verify_predecessor, publish_candidate, prepare_candidate, prepare_aggregate, finalize_aggregate, resume_publication };
const Phase = enum { pre_publish, verify_predecessor, publish_candidate, prepare_candidate, prepare_aggregate, finalize_aggregate, resume_publication };

const Harness = struct {
    events: [8]Event = undefined,
    count: usize = 0,
    phase: Phase = .pre_publish,
    bootstrap_error: bool = false,
    token_error: bool = false,
    product_error: bool = false,

    fn push(self: *@This(), event: Event) void {
        self.events[self.count] = event;
        self.count += 1;
    }

    fn Bootstrapper(comptime Self: type) type {
        return struct {
            harness: *Self,
            pub fn load(self: *@This(), _: std.mem.Allocator, _: []const []const u8, result: anytype) !void {
                self.harness.push(.bootstrap);
                if (self.harness.bootstrap_error) return error.BootstrapInjected;
                result.command = switch (self.harness.phase) {
                    .pre_publish => .{ .pre_publish = .{
                        .repo = "ohah/maru",
                        .tag = "v1.2.3",
                        .manifest = "/tmp/Maru-1.2.3-session-host-release.json",
                        .evidence = "/tmp/evidence",
                        .dmg = "/tmp/dmg",
                        .frozen_executable = "/tmp/exe",
                        .work_dir = "/tmp/work",
                        .summary_out = "/tmp/summary",
                    } },
                    .verify_predecessor => .{ .verify_predecessor = .{
                        .repo = "ohah/maru",
                        .tag = "v1.2.3",
                        .manifest = "/tmp/Maru-1.2.3-session-host-release.json",
                        .work_dir = "/tmp/work",
                        .summary_out = "/tmp/summary",
                    } },
                    .publish_candidate => .{ .publish_candidate = .{
                        .repo = "ohah/maru",
                        .tag = "v1.2.3",
                        .test_uuid = "123e4567-e89b-42d3-a456-426614174000",
                        .dmg = "/tmp/dmg",
                        .frozen_executable = "/tmp/exe",
                        .candidate_dmg_bundle = "/tmp/candidate-dmg-bundle",
                        .candidate_frozen_bundle = "/tmp/candidate-frozen-bundle",
                        .dmg_work = "/tmp/dmg-work",
                        .baseline_workspace = "/tmp/baseline",
                        .app_main_executable = "/tmp/app-main",
                        .app_cli_executable = "/tmp/app-cli",
                        .manifest = "/tmp/Maru-1.2.3-session-host-release.json",
                        .source_root = "/tmp/source",
                        .zig = "/tmp/zig",
                        .zig_size = 123,
                        .zig_sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
                    } },
                    .prepare_candidate => .{ .prepare_candidate = .{
                        .repo = "ohah/maru",
                        .tag = "v1.2.3",
                        .test_uuid = "123e4567-e89b-42d3-a456-426614174000",
                        .dmg = "/tmp/dmg",
                        .frozen_executable = "/tmp/exe",
                        .candidate_dmg_bundle = "/tmp/candidate-dmg-bundle",
                        .candidate_frozen_bundle = "/tmp/candidate-frozen-bundle",
                        .dmg_work = "/tmp/dmg-work",
                        .baseline_workspace = "/tmp/baseline",
                        .app_main_executable = "/tmp/app-main",
                        .app_cli_executable = "/tmp/app-cli",
                        .manifest = "/tmp/Maru-1.2.3-session-host-release.json",
                        .source_root = "/tmp/source",
                        .zig = "/tmp/zig",
                        .zig_size = 123,
                        .zig_sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
                        .durable_preparation = "/tmp/durable-stage3",
                    } },
                    .prepare_aggregate => .{ .prepare_candidate_aggregate = .{
                        .repo = "ohah/maru",
                        .tag = "v1.2.3",
                        .evidence = "/tmp/evidence",
                        .candidate_dmg_bundle = "/tmp/candidate-dmg",
                        .candidate_frozen_bundle = "/tmp/candidate-frozen",
                        .evidence_bundle = "/tmp/evidence-bundle",
                        .manifest_bundle = "/tmp/manifest-bundle",
                        .aggregate = "/tmp/aggregate",
                    } },
                    .finalize_aggregate => .{ .finalize_candidate_aggregate = .{
                        .repo = "ohah/maru",
                        .tag = "v1.2.3",
                        .aggregate = "/tmp/aggregate",
                        .dmg = "/tmp/dmg",
                        .frozen_executable = "/tmp/exe",
                        .manifest = "/tmp/manifest",
                    } },
                    .resume_publication => .{ .resume_candidate_publication = .{
                        .repo = "ohah/maru",
                        .tag = "v1.2.3",
                        .preparation = "/tmp/preparation",
                        .aggregate = "/tmp/aggregate",
                        .dmg = "/tmp/dmg",
                        .frozen_executable = "/tmp/exe",
                    } },
                };
                result.owner = result;
            }
        };
    }

    fn TokenReader(comptime Self: type) type {
        return struct {
            harness: *Self,
            pub fn read(self: *@This()) ![]const u8 {
                self.harness.push(.token);
                if (self.harness.token_error) return error.TokenInjected;
                return "token";
            }
        };
    }

    fn Drivers(comptime Self: type) type {
        return struct {
            harness: *Self,
            pub fn prePublish(self: *@This(), _: std.Io, _: std.mem.Allocator, _: anytype, token: []const u8, budget: i128, storage: *validator.Storage) !void {
                self.harness.push(.pre_publish);
                try std.testing.expectEqualStrings("token", token);
                try std.testing.expectEqual(validator.phase_budget_ns, budget);
                try std.testing.expectEqual(validator.github_capture_bytes, storage.github_response.len);
                if (self.harness.product_error) return error.ProductInjected;
            }
            pub fn verifyPredecessor(self: *@This(), _: std.Io, _: std.mem.Allocator, _: anytype, token: []const u8, budget: i128, storage: *validator.Storage) !void {
                self.harness.push(.verify_predecessor);
                try std.testing.expectEqualStrings("token", token);
                try std.testing.expectEqual(validator.phase_budget_ns, budget);
                try std.testing.expectEqual(validator.attestation_capture_bytes, storage.attestation.len);
                if (self.harness.product_error) return error.ProductInjected;
            }
            pub fn publishCandidate(self: *@This(), _: std.Io, _: std.mem.Allocator, _: anytype, token: []const u8, budget: i128, storage: *validator.Storage) !void {
                self.harness.push(.publish_candidate);
                try std.testing.expectEqualStrings("token", token);
                try std.testing.expectEqual(validator.phase_budget_ns, budget);
                try std.testing.expectEqual(validator.github_capture_bytes, storage.github_response.len);
                if (self.harness.product_error) return error.ProductInjected;
            }
            pub fn prepareCandidate(self: *@This(), _: std.Io, _: std.mem.Allocator, _: anytype, token: []const u8, budget: i128, storage: *validator.Storage) !void {
                self.harness.push(.prepare_candidate);
                try std.testing.expectEqualStrings("token", token);
                try std.testing.expectEqual(validator.phase_budget_ns, budget);
                try std.testing.expectEqual(validator.github_capture_bytes, storage.github_response.len);
                if (self.harness.product_error) return error.ProductInjected;
            }
            pub fn prepareCandidateAggregate(self: *@This(), _: std.Io, _: std.mem.Allocator, _: anytype, budget: i128, _: *validator.Storage) !void {
                self.harness.push(.prepare_aggregate);
                try std.testing.expectEqual(validator.phase_budget_ns, budget);
                if (self.harness.product_error) return error.ProductInjected;
            }
            pub fn finalizeCandidateAggregate(self: *@This(), _: std.Io, _: std.mem.Allocator, _: anytype, budget: i128, _: *validator.Storage) !void {
                self.harness.push(.finalize_aggregate);
                try std.testing.expectEqual(validator.phase_budget_ns, budget);
                if (self.harness.product_error) return error.ProductInjected;
            }
            pub fn resumeCandidatePublication(self: *@This(), _: std.Io, _: std.mem.Allocator, _: anytype, token: []const u8, budget: i128, storage: *validator.Storage) !void {
                self.harness.push(.resume_publication);
                try std.testing.expectEqualStrings("token", token);
                try std.testing.expectEqual(validator.phase_budget_ns, budget);
                try std.testing.expectEqual(validator.github_capture_bytes, storage.github_response.len);
                if (self.harness.product_error) return error.ProductInjected;
            }
        };
    }

    fn run(self: *@This(), storage: *validator.Storage) !void {
        var bootstrapper = Bootstrapper(@This()){ .harness = self };
        var tokens = TokenReader(@This()){ .harness = self };
        var drivers = Drivers(@This()){ .harness = self };
        try validator.executeWith(std.testing.io, std.testing.allocator, &.{}, storage, &bootstrapper, &tokens, &drivers);
    }
};

test "validator authenticates bootstrap and token before exact pre-publish dispatch" {
    var storage: validator.Storage = undefined;
    var harness = Harness{};
    try harness.run(&storage);
    try std.testing.expectEqualSlices(Event, &.{ .bootstrap, .token, .pre_publish }, harness.events[0..harness.count]);
}

test "verify-predecessor failure propagates without fallback or second phase" {
    var storage: validator.Storage = undefined;
    var harness = Harness{ .phase = .verify_predecessor, .product_error = true };
    try std.testing.expectError(error.ProductInjected, harness.run(&storage));
    try std.testing.expectEqualSlices(Event, &.{ .bootstrap, .token, .verify_predecessor }, harness.events[0..harness.count]);
}

test "bootstrap and token failures start no product and storage caps stay component-owned" {
    var storage: validator.Storage = undefined;
    var bootstrap_failure = Harness{ .bootstrap_error = true };
    try std.testing.expectError(error.BootstrapInjected, bootstrap_failure.run(&storage));
    try std.testing.expectEqualSlices(Event, &.{.bootstrap}, bootstrap_failure.events[0..bootstrap_failure.count]);
    var token_failure = Harness{ .token_error = true };
    try std.testing.expectError(error.TokenInjected, token_failure.run(&storage));
    try std.testing.expectEqualSlices(Event, &.{ .bootstrap, .token }, token_failure.events[0..token_failure.count]);
    try std.testing.expectEqual(@as(i128, 20 * std.time.ns_per_min), validator.phase_budget_ns);
    try std.testing.expectEqual(validator.manifest_capture_bytes, storage.manifest_download.len);
    try std.testing.expectEqual(validator.compatibility_capture_bytes, storage.compatibility.len);
    const ranges = [_][]const u8{
        &storage.github_response,
        &storage.manifest_download,
        &storage.attestation,
        &storage.compatibility,
        std.mem.asBytes(&storage.apple),
    };
    for (ranges, 0..) |left, index| for (ranges[index + 1 ..]) |right| {
        const left_end = @intFromPtr(left.ptr) + left.len;
        const right_end = @intFromPtr(right.ptr) + right.len;
        try std.testing.expect(left_end <= @intFromPtr(right.ptr) or right_end <= @intFromPtr(left.ptr));
    };
}

test "publish-candidate dispatches exactly once after bootstrap and token" {
    var storage: validator.Storage = undefined;
    var harness = Harness{ .phase = .publish_candidate };
    try harness.run(&storage);
    try std.testing.expectEqualSlices(Event, &.{ .bootstrap, .token, .publish_candidate }, harness.events[0..harness.count]);
    var failure = Harness{ .phase = .publish_candidate, .product_error = true };
    try std.testing.expectError(error.ProductInjected, failure.run(&storage));
    try std.testing.expectEqualSlices(Event, &.{ .bootstrap, .token, .publish_candidate }, failure.events[0..failure.count]);

    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "tools/session-host/validate_release_manifest.zig",
        std.testing.allocator,
        .limited(128 * 1024),
    );
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "candidate_release_driver.run("));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "storage.github_response[0..candidate_release_driver.max_scratch_bytes]"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, source, "settleProductFailure(&storage.candidate"));
}

test "prepare-candidate dispatches exactly once after bootstrap and token" {
    var storage: validator.Storage = undefined;
    var harness = Harness{ .phase = .prepare_candidate };
    try harness.run(&storage);
    try std.testing.expectEqualSlices(Event, &.{ .bootstrap, .token, .prepare_candidate }, harness.events[0..harness.count]);
}

test "argv collector accepts the contract bound and rejects only bound plus one" {
    var values: [validator.max_command_args][]const u8 = undefined;
    var count: usize = 0;
    for (0..values.len) |_| try validator.testing_api.appendArgument(&values, &count, "value");
    try std.testing.expectEqual(values.len, count);
    try std.testing.expectError(error.TooManyArguments, validator.testing_api.appendArgument(&values, &count, "overflow"));
    try std.testing.expectEqual(values.len, count);
}

test "aggregate commands dispatch exactly once without reading GitHub token" {
    var storage: validator.Storage = undefined;
    var prepare = Harness{ .phase = .prepare_aggregate, .token_error = true };
    try prepare.run(&storage);
    try std.testing.expectEqualSlices(Event, &.{ .bootstrap, .prepare_aggregate }, prepare.events[0..prepare.count]);

    var finalize = Harness{ .phase = .finalize_aggregate, .token_error = true };
    try finalize.run(&storage);
    try std.testing.expectEqualSlices(Event, &.{ .bootstrap, .finalize_aggregate }, finalize.events[0..finalize.count]);

    var failure = Harness{ .phase = .finalize_aggregate, .token_error = true, .product_error = true };
    try std.testing.expectError(error.ProductInjected, failure.run(&storage));
    try std.testing.expectEqualSlices(Event, &.{ .bootstrap, .finalize_aggregate }, failure.events[0..failure.count]);
}

test "resume publication dispatches exactly once after bootstrap and token" {
    var storage: validator.Storage = undefined;
    var harness = Harness{ .phase = .resume_publication };
    try harness.run(&storage);
    try std.testing.expectEqualSlices(Event, &.{ .bootstrap, .token, .resume_publication }, harness.events[0..harness.count]);
    var failure = Harness{ .phase = .resume_publication, .product_error = true };
    try std.testing.expectError(error.ProductInjected, failure.run(&storage));
    try std.testing.expectEqualSlices(Event, &.{ .bootstrap, .token, .resume_publication }, failure.events[0..failure.count]);
}

test "production failure cleanup retries at most once and retry failure wins" {
    const FakeExecution = struct {
        owner: ?*@This() = null,
        retries: usize = 0,
        fail_retry: bool = false,
        pub fn retryCleanup(self: *@This()) !void {
            self.retries += 1;
            if (self.fail_retry) return error.RetryInjected;
            self.owner = null;
        }
    };
    var empty = FakeExecution{};
    try std.testing.expectEqual(error.ProductInjected, validator.testing_api.settleFailure(&empty, error.ProductInjected));
    try std.testing.expectEqual(@as(usize, 0), empty.retries);
    var retained = FakeExecution{};
    retained.owner = &retained;
    try std.testing.expectEqual(error.ProductInjected, validator.testing_api.settleFailure(&retained, error.ProductInjected));
    try std.testing.expectEqual(@as(usize, 1), retained.retries);
    var failed = FakeExecution{ .fail_retry = true };
    failed.owner = &failed;
    try std.testing.expectEqual(error.CleanupFailed, validator.testing_api.settleFailure(&failed, error.ProductInjected));
    try std.testing.expectEqual(@as(usize, 1), failed.retries);
}
