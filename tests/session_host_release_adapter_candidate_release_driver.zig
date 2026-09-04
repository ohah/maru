const std = @import("std");
const driver = @import("release_adapter_candidate_release_driver");

const Event = enum { preflight, source, zig, product, cleanup_product, retry_product, cleanup_zig, cleanup_source, finish };
const Failure = enum { none, preflight, source, zig, product, cleanup_product, retry_product, cleanup_zig, cleanup_source };

const Harness = struct {
    events: [16]Event = undefined,
    count: usize = 0,
    failure: Failure = .none,
    product_error: bool = false,
    product_state: driver.testing_api.ProductState = .pristine,
    source_live: bool = false,
    zig_live: bool = false,
    finished: bool = false,

    fn push(self: *@This(), event: Event) void {
        self.events[self.count] = event;
        self.count += 1;
    }
    pub fn validatePreflight(self: *@This()) !void {
        self.push(.preflight);
        if (self.failure == .preflight) return error.Injected;
    }
    pub fn prepareSource(self: *@This()) !void {
        self.push(.source);
        if (self.failure == .source) return error.Injected;
        self.source_live = true;
    }
    pub fn prepareToolchain(self: *@This()) !void {
        self.push(.zig);
        if (self.failure == .zig) return error.Injected;
        self.zig_live = true;
    }
    pub fn runProduct(self: *@This()) !void {
        self.push(.product);
        if (self.product_error or self.failure == .product) return error.ProductInjected;
        self.product_state = .complete;
    }
    pub fn productState(self: *@This()) driver.testing_api.ProductState {
        return self.product_state;
    }
    pub fn cleanupProduct(self: *@This()) !void {
        self.push(.cleanup_product);
        if (self.failure == .cleanup_product) return error.Injected;
        self.product_state = .pristine;
    }
    pub fn retryProduct(self: *@This()) !void {
        self.push(.retry_product);
        if (self.failure == .retry_product) return error.Injected;
        self.product_state = .pristine;
    }
    pub fn cleanupToolchain(self: *@This()) !void {
        if (!self.zig_live) return;
        self.push(.cleanup_zig);
        if (self.failure == .cleanup_zig) return error.Injected;
        self.zig_live = false;
    }
    pub fn cleanupSource(self: *@This()) !void {
        if (!self.source_live) return;
        self.push(.cleanup_source);
        self.source_live = false;
        if (self.failure == .cleanup_source) return error.Injected;
    }
    pub fn finish(self: *@This()) void {
        self.push(.finish);
        self.finished = true;
    }
};

test "candidate driver exposes one final-address production owner" {
    std.testing.refAllDecls(driver);
    var execution: driver.Execution = .{};
    try std.testing.expect(execution.isPristineForComposition());
    try std.testing.expect(!execution.needsAudit());
    try std.testing.expectError(error.InvalidOwner, execution.retryCleanup());
}

test "dirty nested authority is not erased as a pristine result" {
    var execution: driver.Execution = .{};
    execution.source.identity.inode = 7;
    try std.testing.expect(!execution.isPristineForComposition());
}

test "production entry rejects pre-owned dirty and foreign-command results before authority work" {
    var invalid_bootstrap: driver.Bootstrap = undefined;
    var preowned: driver.Execution = .{};
    preowned.owner = &preowned;
    var scratch: [64]u8 = undefined;
    try std.testing.expectError(error.InvalidOwner, driver.run(std.testing.io, std.testing.allocator, &invalid_bootstrap, "token", &scratch, std.time.ns_per_s, &preowned));
    try std.testing.expect(preowned.owner == &preowned);

    var dirty: driver.Execution = .{};
    dirty.source.identity.inode = 9;
    try std.testing.expectError(error.InvalidOwner, driver.run(std.testing.io, std.testing.allocator, &invalid_bootstrap, "token", &scratch, std.time.ns_per_s, &dirty));
    try std.testing.expectEqual(@as(u64, 9), dirty.source.identity.inode);

    var foreign: driver.Bootstrap = undefined;
    foreign.owner = &foreign;
    foreign.cli_path_len = 0;
    foreign.cli_path_storage[0] = 0;
    foreign.command = .{ .pre_publish = undefined };
    var pristine: driver.Execution = .{};
    try std.testing.expectError(error.InvalidCommand, driver.run(std.testing.io, std.testing.allocator, &foreign, "token", &scratch, std.time.ns_per_s, &pristine));
    try std.testing.expect(pristine.isPristineForComposition());
}

test "success acquires source then Zig then product and releases in reverse" {
    var harness = Harness{};
    try driver.testing_api.driveWith(&harness);
    try std.testing.expectEqualSlices(Event, &.{ .preflight, .source, .zig, .product, .cleanup_product, .cleanup_zig, .cleanup_source, .finish }, harness.events[0..harness.count]);
}

test "pristine and cleanup-required product failures clean dependencies and preserve original error" {
    var pristine = Harness{ .failure = .product };
    try std.testing.expectError(error.ProductInjected, driver.testing_api.driveWith(&pristine));
    try std.testing.expectEqualSlices(Event, &.{ .preflight, .source, .zig, .product, .cleanup_zig, .cleanup_source, .finish }, pristine.events[0..pristine.count]);
    var retry = Harness{ .product_error = true, .product_state = .cleanup_required };
    try std.testing.expectError(error.ProductInjected, driver.testing_api.driveWith(&retry));
    try std.testing.expectEqualSlices(Event, &.{ .preflight, .source, .zig, .product, .retry_product, .cleanup_zig, .cleanup_source, .finish }, retry.events[0..retry.count]);
}

test "audit-required failure preserves dependencies and original error" {
    var harness = Harness{ .product_error = true, .product_state = .audit_required };
    try std.testing.expectError(error.ProductInjected, driver.testing_api.driveWith(&harness));
    try std.testing.expectEqualSlices(Event, &.{ .preflight, .source, .zig, .product }, harness.events[0..harness.count]);
    try std.testing.expect(harness.source_live and harness.zig_live and !harness.finished);
}

test "cleanup failure attempts later dependencies and retry touches retained owners" {
    var harness = Harness{ .failure = .retry_product, .product_error = true, .product_state = .cleanup_required };
    try std.testing.expectError(error.CleanupFailed, driver.testing_api.driveWith(&harness));
    try std.testing.expectEqualSlices(Event, &.{ .preflight, .source, .zig, .product, .retry_product, .cleanup_zig, .cleanup_source }, harness.events[0..harness.count]);
    try std.testing.expectEqual(driver.testing_api.ProductState.cleanup_required, harness.product_state);
    harness.failure = .none;
    try driver.testing_api.retryWith(&harness);
    try std.testing.expectEqualSlices(Event, &.{ .retry_product, .finish }, harness.events[harness.count - 2 .. harness.count]);
}

test "preflight and authority preparation failures never start later work" {
    var preflight = Harness{ .failure = .preflight };
    try std.testing.expectError(error.Injected, driver.testing_api.driveWith(&preflight));
    try std.testing.expectEqualSlices(Event, &.{.preflight}, preflight.events[0..preflight.count]);
    var zig = Harness{ .failure = .zig };
    try std.testing.expectError(error.Injected, driver.testing_api.driveWith(&zig));
    try std.testing.expectEqualSlices(Event, &.{ .preflight, .source, .zig, .cleanup_source, .finish }, zig.events[0..zig.count]);
}

test "production driver has one concrete leaf callsite and no generic settlement" {
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/platform/macos/session_host/release_adapter_candidate_release_driver.zig", std.testing.allocator, .limited(256 * 1024));
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "source_authority.prepareCurrent("));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "zig_authority.bind("));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "candidate_product.run("));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, source, "settleProductFailure"));
}
