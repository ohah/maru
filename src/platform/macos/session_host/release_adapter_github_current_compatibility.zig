//! Frozen product executable의 compiled compatibility를 current manifest에 결속한다.

const std = @import("std");
const manifest = @import("release_manifest");
const bounded = @import("bounded_process");
const current_input = @import("release_adapter_github_current_manifest_input");
const current_product = @import("release_adapter_github_current_product");
const deadline_mod = @import("release_adapter_deadline");
const compatibility_probe = @import("release_adapter_compatibility_probe");

pub const max_probe_bytes = compatibility_probe.max_probe_bytes;

pub const Error = error{
    InvalidOwner,
    InvalidCurrent,
    InvalidBudget,
    InvalidProbe,
    FrozenChanged,
    CompatibilityMismatch,
};

pub const View = struct {
    executable_sha256: [64]u8,
    compatibility: manifest.Compatibility,
};

pub const CurrentCompatibility = struct {
    owner: ?*CurrentCompatibility = null,
    executable_sha256: [64]u8 = @splat(0),
    compatibility: manifest.Compatibility = .{ .mrsh_major = 0, .screen_codec = 0, .handoff_reader_min = 0, .handoff_reader_max = 0, .app_host_abi = 0 },

    pub fn value(self: *const @This()) ?View {
        if (self.owner != self) return null;
        return .{ .executable_sha256 = self.executable_sha256, .compatibility = self.compatibility };
    }

    pub fn deinit(self: *@This()) Error!void {
        if (self.owner != self) return error.InvalidOwner;
        self.* = .{};
    }
};

pub fn parse(bytes_with_newline: []const u8) Error!manifest.Compatibility {
    return compatibility_probe.parse(bytes_with_newline) catch return error.InvalidProbe;
}

const RealProbe = struct {
    pub fn run(_: *@This(), io: std.Io, executable: [:0]const u8, directory_fd: std.c.fd_t, relative_executable: [:0]const u8, output: []u8, budget_ns: i128) ![]const u8 {
        const argv = [_:null]?[*:0]const u8{ executable.ptr, "__session-host", "--release-compatibility", null };
        const environment = [_:null]?[*:0]const u8{null};
        return bounded.runCaptureEnvironmentStdoutHeldExecutable(io, relative_executable, &argv, &environment, directory_fd, output, budget_ns);
    }
};

pub fn compose(
    io: std.Io,
    current: *const current_input.CurrentManifestInput,
    product: *current_product.CurrentProduct,
    frozen_path: [:0]const u8,
    output: []u8,
    budget_ns: i128,
    result: *CurrentCompatibility,
) !void {
    var probe = RealProbe{};
    return composeWith(&probe, io, current, product, frozen_path, output, budget_ns, result);
}

pub fn composeUntil(
    io: std.Io,
    current: *const current_input.CurrentManifestInput,
    product: *current_product.CurrentProduct,
    frozen_path: [:0]const u8,
    output: []u8,
    deadline: *deadline_mod.Deadline,
    result: *CurrentCompatibility,
) !void {
    var probe = RealProbe{};
    return composeUntilWith(&probe, deadline, io, current, product, frozen_path, output, result);
}

pub fn composeWith(
    probe: anytype,
    io: std.Io,
    current: anytype,
    product: anytype,
    frozen_path: [:0]const u8,
    output: []u8,
    budget_ns: i128,
    result: *CurrentCompatibility,
) !void {
    var fixed = FixedBudget{ .value = budget_ns };
    return composeUntilWith(probe, &fixed, io, current, product, frozen_path, output, result);
}

pub fn composeUntilWith(
    probe: anytype,
    deadline: anytype,
    io: std.Io,
    current: anytype,
    product: anytype,
    frozen_path: [:0]const u8,
    output: []u8,
    result: *CurrentCompatibility,
) !void {
    const deadline_bytes = std.mem.asBytes(deadline);
    if (rangesOverlap(deadline_bytes, std.mem.asBytes(result)) or
        rangesOverlap(deadline_bytes, std.mem.asBytes(current)) or
        rangesOverlap(deadline_bytes, std.mem.asBytes(product)) or
        rangesOverlap(deadline_bytes, frozen_path) or
        rangesOverlap(deadline_bytes, output))
        return error.InvalidOwner;
    if (!pristine(result) or rangesOverlap(std.mem.asBytes(result), output) or
        rangesOverlap(std.mem.asBytes(current), output) or
        rangesOverlap(std.mem.asBytes(product), output) or
        rangesOverlap(frozen_path, output))
        return error.InvalidOwner;
    if (output.len == 0 or output.len > max_probe_bytes) return error.InvalidBudget;
    const authenticated = current.value() orelse return error.InvalidCurrent;
    current.revalidate() catch return error.InvalidCurrent;
    _ = try deadline.remaining();
    const before = product.revalidate(frozen_path) catch return error.FrozenChanged;
    const directory_fd = product.executableDirectoryDescriptor() catch return error.FrozenChanged;
    var relative_storage: [std.fs.max_name_bytes + 3:0]u8 = undefined;
    const basename = std.fs.path.basename(frozen_path);
    if (basename.len == 0 or basename.len > std.fs.max_name_bytes) return error.FrozenChanged;
    const relative_executable = std.fmt.bufPrintZ(&relative_storage, "./{s}", .{basename}) catch return error.FrozenChanged;
    const path_seal = product.pathMutationSeal() catch return error.FrozenChanged;
    const budget_ns = try deadline.remaining();
    const probe_bytes = try probe.run(io, frozen_path, directory_fd, relative_executable, output, budget_ns);
    if (probe_bytes.ptr != output.ptr or probe_bytes.len > output.len) return error.InvalidProbe;
    const observed = try parse(probe_bytes);
    product.validatePathMutationSeal(path_seal) catch return error.FrozenChanged;
    const after = product.revalidate(frozen_path) catch return error.FrozenChanged;
    if (before.frozen.identity.device != after.frozen.identity.device or
        before.frozen.identity.inode != after.frozen.identity.inode or
        before.frozen.size != after.frozen.size or before.frozen.mode != after.frozen.mode or
        !std.mem.eql(u8, &before.frozen.sha256, &after.frozen.sha256))
        return error.FrozenChanged;
    current.revalidate() catch return error.InvalidCurrent;
    if (!manifest.equalCompatibility(authenticated.manifest.compatibility, observed))
        return error.CompatibilityMismatch;
    _ = try deadline.remaining();
    result.executable_sha256 = before.frozen.sha256;
    result.compatibility = observed;
    result.owner = result;
}

const FixedBudget = struct {
    value: i128,
    pub fn remaining(self: *@This()) Error!i128 {
        if (self.value <= 0) return error.InvalidBudget;
        return self.value;
    }
};

fn pristine(result: *const CurrentCompatibility) bool {
    return result.owner == null and std.mem.allEqual(u8, &result.executable_sha256, 0) and
        result.compatibility.mrsh_major == 0 and result.compatibility.screen_codec == 0 and
        result.compatibility.handoff_reader_min == 0 and result.compatibility.handoff_reader_max == 0 and
        result.compatibility.app_host_abi == 0;
}

fn rangesOverlap(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_end = std.math.add(usize, @intFromPtr(left.ptr), left.len) catch return true;
    const right_end = std.math.add(usize, @intFromPtr(right.ptr), right.len) catch return true;
    return @intFromPtr(left.ptr) < right_end and @intFromPtr(right.ptr) < left_end;
}
