//! Authenticated current manifest와 local DMG/frozen executable의 Apple product composition.

const std = @import("std");
const c = std.c;
const posix = std.posix;
const manifest = @import("release_manifest");
const files = @import("release_adapter_files");
const apple = @import("release_adapter_apple_product");
const apple_transport = @import("release_adapter_apple_transport");
const dmg_authority = @import("release_adapter_dmg_authority");
const current_input = @import("release_adapter_github_current_manifest_input");

pub const DmgExpected = dmg_authority.ExpectedDmg;

pub const Paths = struct {
    dmg: [:0]const u8,
    dmg_work: [:0]const u8,
    frozen_executable: [:0]const u8,
};

pub const Error = error{
    InvalidOwner,
    InvalidCurrent,
    InvalidPath,
    InvalidAsset,
    FrozenChanged,
    ProductMismatch,
};

pub const View = struct {
    frozen: files.ExecutableObservation,
    apple: *const apple.Observed,
};

pub const CurrentProduct = struct {
    owner: ?*CurrentProduct = null,
    frozen: files.PinnedExecutableFile = .{},
    apple_observed: ?apple.Observed = null,

    pub fn value(self: *const @This()) ?View {
        if (self.owner != self) return null;
        const frozen = self.frozen.value() orelse return null;
        const observed = if (self.apple_observed) |*observed_value| observed_value else return null;
        return .{ .frozen = frozen, .apple = observed };
    }

    pub fn revalidate(self: *const @This(), frozen_path: [:0]const u8) !View {
        const current = self.value() orelse return error.InvalidOwner;
        const frozen = files.revalidateExecutable(&self.frozen, frozen_path) catch return error.FrozenChanged;
        return .{ .frozen = frozen, .apple = current.apple };
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) Error!void {
        if (self.owner != self or self.frozen.value() == null or self.apple_observed == null)
            return error.InvalidOwner;
        self.apple_observed.?.deinit(allocator);
        self.apple_observed = null;
        self.frozen.deinit() catch return error.InvalidOwner;
        self.* = .{};
    }
};

const RealObserver = struct {
    storage: *apple_transport.Storage,

    fn observe(
        self: *@This(),
        allocator: std.mem.Allocator,
        io: std.Io,
        paths: Paths,
        expected: DmgExpected,
        version: []const u8,
        budget_ns: i128,
    ) !apple.Observed {
        return dmg_authority.observe(
            allocator,
            io,
            paths.dmg,
            paths.dmg_work,
            expected,
            version,
            self.storage,
            budget_ns,
        );
    }
};

pub fn observe(
    allocator: std.mem.Allocator,
    io: std.Io,
    current: *const current_input.CurrentManifestInput,
    paths: Paths,
    storage: *apple_transport.Storage,
    budget_ns: i128,
    result: *CurrentProduct,
) !void {
    var observer = RealObserver{ .storage = storage };
    return observeWith(&observer, allocator, io, current, paths, budget_ns, result);
}

pub fn observeWith(
    observer: anytype,
    allocator: std.mem.Allocator,
    io: std.Io,
    current: *const current_input.CurrentManifestInput,
    paths: Paths,
    budget_ns: i128,
    result: *CurrentProduct,
) !void {
    if (result.owner != null or result.frozen.owner != null or result.frozen.fd >= 0 or
        result.apple_observed != null) return error.InvalidOwner;
    const authenticated = current.value() orelse return error.InvalidCurrent;
    const private_manifest = current.file.revalidate() catch return error.InvalidCurrent;
    try validatePaths(paths, private_manifest);
    if (budget_ns <= 0) return error.InvalidAsset;

    const dmg_asset = assetForRole(authenticated.manifest.assets, .universal_dmg) orelse
        return error.InvalidAsset;
    const frozen_asset = assetForRole(authenticated.manifest.assets, .frozen_product_executable) orelse
        return error.InvalidAsset;
    if (dmg_asset.size > files.max_release_asset_bytes or
        frozen_asset.size > files.max_release_asset_bytes) return error.InvalidAsset;
    if (!std.mem.eql(u8, std.fs.path.basename(paths.dmg), dmg_asset.name) or
        !std.mem.eql(u8, std.fs.path.basename(paths.frozen_executable), frozen_asset.name))
        return error.InvalidPath;

    var frozen_sha: [64]u8 = undefined;
    @memcpy(&frozen_sha, frozen_asset.sha256);
    files.pinExecutable(&result.frozen, paths.frozen_executable, .{
        .size = frozen_asset.size,
        .sha256 = frozen_sha,
    }, files.max_release_asset_bytes) catch |err| return err;
    var frozen_owned = true;
    defer if (frozen_owned) result.frozen.deinit() catch {};
    _ = files.revalidateExecutable(&result.frozen, paths.frozen_executable) catch
        return error.FrozenChanged;

    var dmg_sha_value: [64]u8 = undefined;
    @memcpy(&dmg_sha_value, dmg_asset.sha256);
    var observed = try observer.observe(allocator, io, paths, .{
        .size = dmg_asset.size,
        .sha256 = dmg_sha_value,
    }, authenticated.manifest.release.version, budget_ns);
    var observed_owned = true;
    defer if (observed_owned) observed.deinit(allocator);

    const frozen_after = files.revalidateExecutable(&result.frozen, paths.frozen_executable) catch
        return error.FrozenChanged;
    if (!std.mem.eql(u8, &frozen_after.sha256, observed.executableSha256()) or
        !manifest.equalSigning(authenticated.manifest.signing, observed.signing()))
        return error.ProductMismatch;

    result.apple_observed = observed;
    result.owner = result;
    observed_owned = false;
    frozen_owned = false;
}

fn validatePaths(paths: Paths, private_manifest: anytype) Error!void {
    const values = [_][]const u8{ paths.dmg, paths.dmg_work, paths.frozen_executable, private_manifest.path };
    for (values) |value| if (!std.fs.path.isAbsolute(value)) return error.InvalidPath;
    for (values, 0..) |left, index| {
        for (values[index + 1 ..]) |right| if (std.mem.eql(u8, left, right)) return error.InvalidPath;
    }
    var dmg_stat: posix.Stat = undefined;
    var frozen_stat: posix.Stat = undefined;
    if (c.fstatat(posix.AT.FDCWD, paths.dmg.ptr, &dmg_stat, posix.AT.SYMLINK_NOFOLLOW) != 0 or
        c.fstatat(posix.AT.FDCWD, paths.frozen_executable.ptr, &frozen_stat, posix.AT.SYMLINK_NOFOLLOW) != 0)
        return error.InvalidPath;
    if ((dmg_stat.dev == frozen_stat.dev and dmg_stat.ino == frozen_stat.ino) or
        (@as(u64, @intCast(dmg_stat.dev)) == private_manifest.device and @as(u64, @intCast(dmg_stat.ino)) == private_manifest.inode) or
        (@as(u64, @intCast(frozen_stat.dev)) == private_manifest.device and @as(u64, @intCast(frozen_stat.ino)) == private_manifest.inode))
        return error.InvalidPath;
}

fn assetForRole(assets: []const manifest.Asset, role: manifest.AssetRole) ?manifest.Asset {
    var found: ?manifest.Asset = null;
    for (assets) |asset| {
        if (asset.role != role) continue;
        if (found != null) return null;
        found = asset;
    }
    return found;
}
