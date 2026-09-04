//! Official GitHub Release validator executable.
//!
//! Success is observable only through the command's exclusive summary pathname. This process does
//! not emit credentials or validation JSON on stdout and never falls back between phase drivers.

const std = @import("std");
const manifest = @import("release_manifest");
const bootstrap_mod = @import("release_adapter_executable_bootstrap");
const token_environment = @import("release_adapter_token_environment");
const github_transport = @import("release_adapter_github_transport");
const attestation = @import("release_adapter_github_attestation");
const compatibility = @import("release_adapter_github_current_compatibility");
const apple_transport = @import("release_adapter_apple_transport");
const pre_publish_product = @import("release_adapter_pre_publish_product");
const verify_predecessor_product = @import("release_adapter_verify_predecessor_product");
const builtin = @import("builtin");

pub const phase_budget_ns: i128 = 20 * std.time.ns_per_min;
pub const github_capture_bytes: usize = github_transport.max_capture_bytes;
pub const manifest_capture_bytes: usize = manifest.max_manifest_bytes;
pub const attestation_capture_bytes: usize = attestation.max_response_bytes;
pub const compatibility_capture_bytes: usize = compatibility.max_probe_bytes;

pub const Storage = struct {
    github_response: [github_capture_bytes]u8 = undefined,
    manifest_download: [manifest_capture_bytes]u8 = undefined,
    attestation: [attestation_capture_bytes]u8 = undefined,
    compatibility: [compatibility_capture_bytes]u8 = undefined,
    apple: apple_transport.Storage = undefined,
};

const CurrentBootstrapper = struct {
    pub fn load(_: *@This(), allocator: std.mem.Allocator, args: []const []const u8, result: *bootstrap_mod.Bootstrap) !void {
        try bootstrap_mod.current(allocator, args, result);
    }
};

const CurrentTokenReader = struct {
    pub fn read(_: *@This()) ![]const u8 {
        return token_environment.readCurrent();
    }
};

const ProductDrivers = struct {
    pub fn prePublish(
        _: *@This(),
        io: std.Io,
        allocator: std.mem.Allocator,
        bootstrap: *bootstrap_mod.Bootstrap,
        token: []const u8,
        budget_ns: i128,
        storage: *Storage,
    ) !void {
        var execution: pre_publish_product.Execution = .{};
        pre_publish_product.run(io, allocator, bootstrap, token, budget_ns, .{
            .github_response = &storage.github_response,
            .manifest_download = &storage.manifest_download,
            .attestation = &storage.attestation,
            .compatibility = &storage.compatibility,
        }, &storage.apple, &execution) catch |err| {
            return settleProductFailure(&execution, err);
        };
    }

    pub fn verifyPredecessor(
        _: *@This(),
        io: std.Io,
        allocator: std.mem.Allocator,
        bootstrap: *bootstrap_mod.Bootstrap,
        token: []const u8,
        budget_ns: i128,
        storage: *Storage,
    ) !void {
        var execution: verify_predecessor_product.Execution = .{};
        verify_predecessor_product.run(io, allocator, bootstrap, token, budget_ns, .{
            .github_response = &storage.github_response,
            .attestation = &storage.attestation,
        }, &execution) catch |err| {
            return settleProductFailure(&execution, err);
        };
    }
};

fn settleProductFailure(execution: anytype, original: anyerror) anyerror {
    if (execution.owner != null) execution.retryCleanup() catch return error.CleanupFailed;
    return original;
}

pub const testing_api = if (builtin.is_test) struct {
    pub fn settleFailure(execution: anytype, original: anyerror) anyerror {
        return settleProductFailure(execution, original);
    }
} else struct {};

pub fn executeWith(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    storage: *Storage,
    bootstrapper: anytype,
    tokens: anytype,
    drivers: anytype,
) !void {
    var bootstrap: bootstrap_mod.Bootstrap = .{};
    try bootstrapper.load(allocator, args, &bootstrap);
    if (bootstrap.owner != &bootstrap) return error.InvalidBootstrap;
    if (bootstrap.command == .publish_candidate) return error.UnsupportedCommand;
    const token = try tokens.read();
    switch (bootstrap.command) {
        .pre_publish => try drivers.prePublish(io, allocator, &bootstrap, token, phase_budget_ns, storage),
        .verify_predecessor => try drivers.verifyPredecessor(io, allocator, &bootstrap, token, phase_budget_ns, storage),
        .publish_candidate => unreachable,
    }
}

pub fn runCurrent(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
    var storage: Storage = .{};
    var bootstrapper = CurrentBootstrapper{};
    var tokens = CurrentTokenReader{};
    var drivers = ProductDrivers{};
    try executeWith(io, allocator, args, &storage, &bootstrapper, &tokens, &drivers);
}

pub fn main(init: std.process.Init) !void {
    const max_args: usize = 32;
    var values: [max_args][]const u8 = undefined;
    var count: usize = 0;
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    while (args.next()) |value| {
        if (count == values.len) return error.TooManyArguments;
        values[count] = value;
        count += 1;
    }
    try runCurrent(init.io, init.gpa, values[0..count]);
}
