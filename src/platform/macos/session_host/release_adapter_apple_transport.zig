//! Closed Apple command execution for release product observations.
//!
//! Callers provide only paths established by the future DMG authority boundary. Executable names,
//! options, child environment, capture bounds, and command order are fixed here.

const std = @import("std");
const process = @import("bounded_process");
const product = @import("release_adapter_apple_product");

pub const max_path_bytes: usize = 4 * 1024;
pub const max_args: usize = 7;
pub const ArgsStorage = [max_args][]const u8;

pub const Paths = struct {
    app_bundle: []const u8,
    info_plist: []const u8,
    product_executable: []const u8,
    dmg: []const u8,
};

pub const Command = enum {
    plist_json,
    codesign_detail,
    designated_requirement,
    architectures,
    strict_signature,
    app_staple,
    dmg_staple,
    dmg_gatekeeper,
};

const command_order = [_]Command{
    .plist_json,
    .codesign_detail,
    .designated_requirement,
    .architectures,
    .strict_signature,
    .app_staple,
    .dmg_staple,
    .dmg_gatekeeper,
};

pub const Plan = struct {
    executable: []const u8,
    args: []const []const u8,
    capture: bool,
};

pub const Storage = struct {
    buffers: [command_order.len][product.max_capture_bytes]u8,
};

pub const Error = error{
    InvalidPath,
    InvalidBudget,
    ArgumentTooLong,
    InvalidCapture,
};

pub fn plan(storage: *ArgsStorage, command: Command, paths: Paths) Error!Plan {
    try validatePaths(paths);
    return switch (command) {
        .plist_json => make(storage, "/usr/bin/plutil", &.{ "-convert", "json", "-o", "-", paths.info_plist }, true),
        .codesign_detail => make(storage, "/usr/bin/codesign", &.{ "-d", "--verbose=4", paths.app_bundle }, true),
        .designated_requirement => make(storage, "/usr/bin/codesign", &.{ "-d", "-r-", "--verbose=0", paths.app_bundle }, true),
        .architectures => make(storage, "/usr/bin/lipo", &.{ "-archs", paths.product_executable }, true),
        .strict_signature => make(storage, "/usr/bin/codesign", &.{ "--verify", "--strict", "--deep", paths.app_bundle }, false),
        .app_staple => make(storage, "/usr/bin/xcrun", &.{ "stapler", "validate", paths.app_bundle }, false),
        .dmg_staple => make(storage, "/usr/bin/xcrun", &.{ "stapler", "validate", paths.dmg }, false),
        .dmg_gatekeeper => make(storage, "/usr/sbin/spctl", &.{ "-a", "-t", "open", "--context", "context:primary-signature", "-v", paths.dmg }, false),
    };
}

fn make(storage: *ArgsStorage, executable: []const u8, values: []const []const u8, capture: bool) Plan {
    for (values, 0..) |value, index| storage[index] = value;
    return .{ .executable = executable, .args = storage[0..values.len], .capture = capture };
}

/// Publishes no result until every capture and receipt command has succeeded.
pub fn collectWith(
    runner: anytype,
    paths: Paths,
    executable_sha256: []const u8,
    storage: *Storage,
    budget_ns: i128,
) !product.Captures {
    if (budget_ns <= 0) return error.InvalidBudget;
    var values: [command_order.len][]const u8 = undefined;
    for (command_order, 0..) |command, index| {
        var args_storage: ArgsStorage = undefined;
        const command_plan = try plan(&args_storage, command, paths);
        const captured = try runner.capture(
            command_plan.executable,
            command_plan.args,
            &.{},
            &storage.buffers[index],
            budget_ns,
        );
        if (!borrowedFrom(captured, &storage.buffers[index])) return error.InvalidCapture;
        values[index] = captured;
    }
    return .{
        .executable_sha256 = executable_sha256,
        .plist_json = values[0],
        .codesign_detail = values[1],
        .designated_requirement = values[2],
        .architectures = values[3],
        .strict_signature_verified = true,
        .app_staple_verified = true,
        .dmg_staple_verified = true,
        .dmg_gatekeeper_verified = true,
    };
}

fn borrowedFrom(captured: []const u8, supplied: []const u8) bool {
    const supplied_start = @intFromPtr(supplied.ptr);
    const supplied_end = std.math.add(usize, supplied_start, supplied.len) catch return false;
    const captured_start = @intFromPtr(captured.ptr);
    const captured_end = std.math.add(usize, captured_start, captured.len) catch return false;
    return captured_start >= supplied_start and captured_end <= supplied_end;
}

pub fn collect(
    io: std.Io,
    paths: Paths,
    executable_sha256: []const u8,
    storage: *Storage,
    budget_ns: i128,
) !product.Captures {
    var runner = MacRunner{ .io = io };
    return collectWith(&runner, paths, executable_sha256, storage, budget_ns);
}

const MacRunner = struct {
    io: std.Io,

    fn capture(
        self: *@This(),
        executable: []const u8,
        args: []const []const u8,
        environment: []const []const u8,
        output: []u8,
        budget_ns: i128,
    ) ![]const u8 {
        if (environment.len != 0 or args.len > max_args) return error.InvalidPath;
        var executable_storage: [max_path_bytes + 1]u8 = undefined;
        const executable_z = try sentinel(&executable_storage, executable);
        var argument_storage: [max_args][max_path_bytes + 1]u8 = undefined;
        var argv: [max_args + 2:null]?[*:0]const u8 = @splat(null);
        argv[0] = executable_z.ptr;
        for (args, 0..) |arg, index| {
            const arg_z = try sentinel(&argument_storage[index], arg);
            argv[index + 1] = arg_z.ptr;
        }
        const empty_environment = [_:null]?[*:0]const u8{null};
        return process.runCaptureEnvironment(
            self.io,
            executable_z,
            &argv,
            &empty_environment,
            output,
            budget_ns,
        );
    }
};

fn sentinel(storage: *[max_path_bytes + 1]u8, value: []const u8) Error![:0]const u8 {
    if (value.len == 0 or value.len > max_path_bytes) return error.ArgumentTooLong;
    if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidPath;
    @memcpy(storage[0..value.len], value);
    storage[value.len] = 0;
    return storage[0..value.len :0];
}

fn validatePaths(paths: Paths) Error!void {
    const values = [_][]const u8{ paths.app_bundle, paths.info_plist, paths.product_executable, paths.dmg };
    for (values) |value| {
        if (value.len < 2 or value.len > max_path_bytes or value[0] != '/') return error.InvalidPath;
        for (value) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidPath;
    }
}
