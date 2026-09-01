//! Authenticated current release assets를 attestation 전용 immutable private leaves로 고정한다.
//!
//! 외부 verifier의 후속 descriptor lease가 소비할 exact-name private leaves와 held directory를 소유한다.

const std = @import("std");
const c = std.c;
const posix = std.posix;
const manifest = @import("release_manifest");
const files = @import("release_adapter_files");
const safe_open = @import("safe_open");
const current_input = @import("release_adapter_github_current_manifest_input");
const current_product = @import("release_adapter_github_current_product");
const current_evidence = @import("release_adapter_github_current_evidence");

pub const Error = error{
    InvalidOwner,
    InvalidCurrent,
    InvalidProduct,
    InvalidEvidence,
    InvalidPath,
    InvalidAsset,
    SourceChanged,
    DestinationExists,
    CreateFailed,
    CopyFailed,
    SyncFailed,
    CleanupFailed,
};

pub const Paths = struct {
    dmg: [:0]const u8,
    frozen_executable: [:0]const u8,
    workdir: [:0]const u8,
};

pub const AssetObservation = struct {
    role: manifest.AssetRole,
    name: []const u8,
    path: []const u8,
    identity: files.Identity,
    size: u64,
    mode: u32,
    link_count: u64,
    sha256: []const u8,
};

const PrivateFile = struct {
    role: manifest.AssetRole = .universal_dmg,
    name: [std.fs.max_name_bytes:0]u8 = @splat(0),
    path: [std.fs.max_path_bytes:0]u8 = @splat(0),
    identity: files.Identity = .{ .device = 0, .inode = 0 },
    size: u64 = 0,
    mode: u32 = 0,
    sha256: [64]u8 = @splat(0),
    present: bool = false,

    fn observation(self: *const @This()) ?AssetObservation {
        if (!self.present) return null;
        return .{
            .role = self.role,
            .name = std.mem.sliceTo(&self.name, 0),
            .path = std.mem.sliceTo(&self.path, 0),
            .identity = self.identity,
            .size = self.size,
            .mode = self.mode,
            .link_count = 1,
            .sha256 = &self.sha256,
        };
    }
};

pub const View = struct {
    owner: *const CurrentAssetFiles,
    directory_fd: c.fd_t,

    pub fn asset(self: View, role: manifest.AssetRole) ?AssetObservation {
        var found: ?AssetObservation = null;
        for (&self.owner.private_files) |*file| {
            if (file.role != role) continue;
            if (found != null) return null;
            found = file.observation() orelse return null;
        }
        return found;
    }
};

pub const CurrentAssetFiles = struct {
    owner: ?*CurrentAssetFiles = null,
    parent_fd: c.fd_t = -1,
    dir_fd: c.fd_t = -1,
    work_path: [std.fs.max_path_bytes:0]u8 = @splat(0),
    dir_name: [std.fs.max_name_bytes:0]u8 = @splat(0),
    parent_identity: files.Identity = .{ .device = 0, .inode = 0 },
    dir_identity: files.Identity = .{ .device = 0, .inode = 0 },
    private_files: [3]PrivateFile = .{ .{}, .{}, .{} },
    dir_present: bool = false,
    complete: bool = false,

    pub fn value(self: *const @This()) ?View {
        if (self.owner != self or !self.complete or !self.dir_present or self.dir_fd < 0)
            return null;
        for (&self.private_files) |*file| if (!file.present) return null;
        return .{ .owner = self, .directory_fd = self.dir_fd };
    }

    pub fn revalidate(self: *@This()) Error!View {
        const view = self.value() orelse return error.InvalidOwner;
        const directory = fingerprint(self.dir_fd) catch return error.SourceChanged;
        if (!posix.S.ISDIR(directory.mode) or directory.identity.device != self.dir_identity.device or
            directory.identity.inode != self.dir_identity.inode or directory.mode & 0o777 != 0o700)
            return error.SourceChanged;
        for (&self.private_files) |*file| {
            const fd = c.openat(self.dir_fd, file.name[0..].ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, @as(c.mode_t, 0));
            if (fd < 0) return error.SourceChanged;
            defer _ = c.close(fd);
            const observed = fingerprint(fd) catch return error.SourceChanged;
            const digest = hashExact(fd, observed.size) catch return error.SourceChanged;
            if (!posix.S.ISREG(observed.mode) or observed.identity.device != file.identity.device or
                observed.identity.inode != file.identity.inode or observed.mode & 0o777 != 0o400 or
                observed.link_count != 1 or observed.size != file.size or !std.mem.eql(u8, &digest, &file.sha256))
                return error.SourceChanged;
        }
        return view;
    }

    pub fn deinit(self: *@This()) Error!void {
        if (self.owner != self) return error.InvalidOwner;
        try cleanup(self, true);
    }
};

const Fingerprint = struct {
    identity: files.Identity,
    size: u64,
    mode: u32,
    link_count: u64,
    modified_sec: i64,
    modified_nsec: i64,
    changed_sec: i64,
    changed_nsec: i64,
};

pub fn compose(
    current: *const current_input.CurrentManifestInput,
    product: *const current_product.CurrentProduct,
    evidence: *const current_evidence.CurrentEvidence,
    paths: Paths,
    result: *CurrentAssetFiles,
) Error!void {
    if (!pristine(result)) return error.InvalidOwner;
    const current_view = current.value() orelse return error.InvalidCurrent;
    const current_file = if (current.input) |*input| input else return error.InvalidCurrent;
    const evidence_view = evidence.value() orelse return error.InvalidEvidence;
    const evidence_input = if (evidence.input) |*input| input else return error.InvalidEvidence;
    const current_manifest = current_view.manifest;
    if (current_manifest.role != .b) return error.InvalidCurrent;

    const dmg_asset = assetForRole(current_manifest.assets, .universal_dmg) orelse return error.InvalidAsset;
    const frozen_asset = assetForRole(current_manifest.assets, .frozen_product_executable) orelse return error.InvalidAsset;
    const summary_asset = assetForRole(current_manifest.assets, .evidence_summary) orelse return error.InvalidAsset;
    if (!validPaths(paths, dmg_asset.name, frozen_asset.name)) return error.InvalidPath;
    const product_view = product.revalidate(paths.frozen_executable) catch return error.InvalidProduct;
    if (!equalAssetObservation(frozen_asset, product_view.frozen.size, &product_view.frozen.sha256) or
        !equalAssetObservation(summary_asset, evidence_view.summary_size, evidence_view.summary_sha256) or
        evidence_input.size != evidence_view.summary_size or
        !std.mem.eql(u8, &evidence_input.sha256, evidence_view.summary_sha256) or
        evidence_input.identity.device != evidence_view.summary_identity.device or
        evidence_input.identity.inode != evidence_view.summary_identity.inode)
        return error.InvalidAsset;

    const dmg_fd = safe_open.openAbsoluteNoFollow(paths.dmg, false) catch return error.InvalidPath;
    defer _ = c.close(dmg_fd);
    const dmg_before = fingerprint(dmg_fd) catch return error.InvalidAsset;
    const dmg_sha = hashExact(dmg_fd, dmg_before.size) catch return error.InvalidAsset;
    if (!posix.S.ISREG(dmg_before.mode) or
        !equalAssetObservation(dmg_asset, dmg_before.size, &dmg_sha))
        return error.InvalidAsset;
    files.requireDistinct(&.{
        current_file.identity,
        dmg_before.identity,
        product_view.frozen.identity,
        evidence_view.summary_identity,
    }) catch return error.InvalidPath;

    createDirectory(result, paths.workdir) catch |err| return err;
    var success = false;
    defer if (!success) abort(result) catch {};
    copyFd(result, 0, dmg_fd, dmg_asset) catch |err| return fail(result, err);
    copyFd(result, 1, product.frozen.fd, frozen_asset) catch |err| return fail(result, err);
    copyBytes(result, 2, evidence_input.bytes, summary_asset) catch |err| return fail(result, err);
    files.requireDistinct(&.{
        result.private_files[0].identity,
        result.private_files[1].identity,
        result.private_files[2].identity,
    }) catch return fail(result, error.CreateFailed);
    if (c.fsync(result.dir_fd) != 0 or c.fsync(result.parent_fd) != 0)
        return fail(result, error.SyncFailed);

    revalidateSource(dmg_fd, paths.dmg, dmg_before, dmg_asset) catch |err| return fail(result, err);
    _ = product.revalidate(paths.frozen_executable) catch return fail(result, error.SourceChanged);
    result.complete = true;
    success = true;
}

fn fail(result: *CurrentAssetFiles, err: Error) Error {
    abort(result) catch return error.CleanupFailed;
    return err;
}

fn pristine(result: *const CurrentAssetFiles) bool {
    return result.owner == null and result.parent_fd < 0 and result.dir_fd < 0 and
        !result.dir_present and !result.complete;
}

fn validPaths(paths: Paths, dmg_name: []const u8, frozen_name: []const u8) bool {
    return std.fs.path.isAbsolute(paths.dmg) and std.fs.path.isAbsolute(paths.frozen_executable) and
        std.fs.path.isAbsolute(paths.workdir) and
        std.mem.eql(u8, std.fs.path.basename(paths.dmg), dmg_name) and
        std.mem.eql(u8, std.fs.path.basename(paths.frozen_executable), frozen_name) and
        !std.mem.eql(u8, paths.dmg, paths.frozen_executable) and
        !std.mem.eql(u8, paths.dmg, paths.workdir) and
        !std.mem.eql(u8, paths.frozen_executable, paths.workdir);
}

fn equalAssetObservation(asset: manifest.Asset, size: u64, sha: []const u8) bool {
    return asset.size != 0 and asset.size <= files.max_release_asset_bytes and asset.size == size and
        std.mem.eql(u8, asset.sha256, sha);
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

fn createDirectory(result: *CurrentAssetFiles, path: [:0]const u8) Error!void {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return error.InvalidPath;
    const leaf = path[slash + 1 ..];
    if (leaf.len == 0 or leaf.len > std.fs.max_name_bytes or std.mem.eql(u8, leaf, ".") or std.mem.eql(u8, leaf, ".."))
        return error.InvalidPath;
    _ = std.fmt.bufPrintZ(&result.work_path, "{s}", .{path}) catch return error.InvalidPath;
    _ = std.fmt.bufPrintZ(&result.dir_name, "{s}", .{leaf}) catch return error.InvalidPath;
    var parent_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const parent_path = if (slash == 0) "/" else std.fmt.bufPrintZ(&parent_storage, "{s}", .{path[0..slash]}) catch return error.InvalidPath;
    result.parent_fd = safe_open.openAbsoluteNoFollow(parent_path, true) catch return error.InvalidPath;
    result.owner = result;
    var parent_stat: posix.Stat = undefined;
    if (c.fstat(result.parent_fd, &parent_stat) != 0 or !posix.S.ISDIR(parent_stat.mode))
        return fail(result, error.CreateFailed);
    result.parent_identity = identity(parent_stat);
    if (c.mkdirat(result.parent_fd, result.dir_name[0..].ptr, 0o700) != 0) {
        const err: Error = if (posix.errno(-1) == .EXIST) error.DestinationExists else error.CreateFailed;
        _ = c.close(result.parent_fd);
        result.* = .{};
        return err;
    }
    result.dir_present = true;
    result.dir_fd = c.openat(result.parent_fd, result.dir_name[0..].ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .DIRECTORY = true, .NOFOLLOW = true }, @as(c.mode_t, 0));
    if (result.dir_fd < 0) return fail(result, error.CreateFailed);
    var dir_stat: posix.Stat = undefined;
    var named_stat: posix.Stat = undefined;
    if (c.fstat(result.dir_fd, &dir_stat) != 0 or
        c.fstatat(result.parent_fd, result.dir_name[0..].ptr, &named_stat, posix.AT.SYMLINK_NOFOLLOW) != 0 or
        !posix.S.ISDIR(dir_stat.mode) or !posix.S.ISDIR(named_stat.mode) or
        dir_stat.dev != named_stat.dev or dir_stat.ino != named_stat.ino or
        dir_stat.mode & 0o777 != 0o700 or named_stat.mode & 0o777 != 0o700 or
        c.fsync(result.parent_fd) != 0)
        return fail(result, error.SyncFailed);
    result.dir_identity = identity(dir_stat);
}

fn copyFd(result: *CurrentAssetFiles, index: usize, source_fd: c.fd_t, asset: manifest.Asset) Error!void {
    const source_before = fingerprint(source_fd) catch return error.SourceChanged;
    if (!posix.S.ISREG(source_before.mode) or source_before.size != asset.size) return error.InvalidAsset;
    const destination = try createLeaf(result, index, asset);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var offset: u64 = 0;
    var buffer: [64 * 1024]u8 = undefined;
    while (offset < asset.size) {
        const wanted: usize = @intCast(@min(@as(u64, buffer.len), asset.size - offset));
        const count = c.pread(source_fd, &buffer, wanted, @intCast(offset));
        if (count < 0 and posix.errno(-1) == .INTR) continue;
        if (count <= 0) return error.CopyFailed;
        const len: usize = @intCast(count);
        hash.update(buffer[0..len]);
        try writeAll(destination, buffer[0..len]);
        offset += len;
    }
    var extra: [1]u8 = undefined;
    while (true) {
        const count = c.pread(source_fd, &extra, 1, @intCast(asset.size));
        if (count < 0 and posix.errno(-1) == .INTR) continue;
        if (count != 0) return error.SourceChanged;
        break;
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &hex, asset.sha256)) return error.InvalidAsset;
    try finishLeaf(result, index, destination, asset);
    const source_after = fingerprint(source_fd) catch return error.SourceChanged;
    if (!sameFingerprint(source_before, source_after)) return error.SourceChanged;
}

fn copyBytes(result: *CurrentAssetFiles, index: usize, bytes: []const u8, asset: manifest.Asset) Error!void {
    if (bytes.len != asset.size or !std.mem.eql(u8, &shaBytes(bytes), asset.sha256)) return error.InvalidAsset;
    const destination = try createLeaf(result, index, asset);
    try writeAll(destination, bytes);
    try finishLeaf(result, index, destination, asset);
}

fn createLeaf(result: *CurrentAssetFiles, index: usize, asset: manifest.Asset) Error!c.fd_t {
    if (index >= result.private_files.len or asset.name.len == 0 or asset.name.len > std.fs.max_name_bytes or
        !std.mem.eql(u8, std.fs.path.basename(asset.name), asset.name)) return error.InvalidAsset;
    var file = &result.private_files[index];
    file.role = asset.role;
    _ = std.fmt.bufPrintZ(&file.name, "{s}", .{asset.name}) catch return error.InvalidAsset;
    _ = std.fmt.bufPrintZ(&file.path, "{s}/{s}", .{ std.mem.sliceTo(&result.work_path, 0), asset.name }) catch return error.InvalidPath;
    const fd = c.openat(result.dir_fd, file.name[0..].ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true, .NOFOLLOW = true }, @as(c.mode_t, 0o400));
    if (fd < 0) return if (posix.errno(-1) == .EXIST) error.DestinationExists else error.CreateFailed;
    file.present = true;
    return fd;
}

fn writeAll(fd: c.fd_t, bytes: []const u8) Error!void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = c.write(fd, bytes[offset..].ptr, bytes.len - offset);
        if (count < 0 and posix.errno(-1) == .INTR) continue;
        if (count <= 0) return error.CopyFailed;
        offset += @intCast(count);
    }
}

fn finishLeaf(result: *CurrentAssetFiles, index: usize, fd: c.fd_t, asset: manifest.Asset) Error!void {
    var open = true;
    defer if (open) {
        _ = c.close(fd);
    };
    if (c.fchmod(fd, 0o400) != 0 or c.fsync(fd) != 0) return error.SyncFailed;
    open = false;
    if (c.close(fd) != 0) return error.SyncFailed;
    const file = &result.private_files[index];
    const read_fd = c.openat(result.dir_fd, file.name[0..].ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, @as(c.mode_t, 0));
    if (read_fd < 0) return error.CreateFailed;
    defer _ = c.close(read_fd);
    const observed = fingerprint(read_fd) catch return error.CreateFailed;
    const digest = hashExact(read_fd, observed.size) catch return error.CopyFailed;
    if (!posix.S.ISREG(observed.mode) or observed.mode & 0o777 != 0o400 or observed.link_count != 1 or
        observed.size != asset.size or !std.mem.eql(u8, &digest, asset.sha256)) return error.CopyFailed;
    file.identity = observed.identity;
    file.size = observed.size;
    file.mode = observed.mode;
    file.sha256 = digest;
}

fn revalidateSource(fd: c.fd_t, path: [:0]const u8, before: Fingerprint, asset: manifest.Asset) Error!void {
    const held = fingerprint(fd) catch return error.SourceChanged;
    if (!sameFingerprint(before, held)) return error.SourceChanged;
    const reopened_fd = safe_open.openAbsoluteNoFollow(path, false) catch return error.SourceChanged;
    defer _ = c.close(reopened_fd);
    const reopened = fingerprint(reopened_fd) catch return error.SourceChanged;
    if (!sameFingerprint(before, reopened)) return error.SourceChanged;
    const digest = hashExact(reopened_fd, reopened.size) catch return error.SourceChanged;
    if (!std.mem.eql(u8, &digest, asset.sha256)) return error.SourceChanged;
}

fn fingerprint(fd: c.fd_t) Error!Fingerprint {
    var stat: posix.Stat = undefined;
    if (fd < 0 or c.fstat(fd, &stat) != 0 or stat.size < 0) return error.SourceChanged;
    return .{
        .identity = identity(stat),
        .size = @intCast(stat.size),
        .mode = @intCast(stat.mode),
        .link_count = @intCast(stat.nlink),
        .modified_sec = stat.mtimespec.sec,
        .modified_nsec = stat.mtimespec.nsec,
        .changed_sec = stat.ctimespec.sec,
        .changed_nsec = stat.ctimespec.nsec,
    };
}

fn identity(stat: posix.Stat) files.Identity {
    return .{ .device = @intCast(stat.dev), .inode = @intCast(stat.ino) };
}

fn sameFingerprint(left: Fingerprint, right: Fingerprint) bool {
    return left.identity.device == right.identity.device and left.identity.inode == right.identity.inode and
        left.size == right.size and left.mode == right.mode and left.link_count == right.link_count and
        left.modified_sec == right.modified_sec and left.modified_nsec == right.modified_nsec and
        left.changed_sec == right.changed_sec and left.changed_nsec == right.changed_nsec;
}

fn hashExact(fd: c.fd_t, size: u64) Error![64]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var offset: u64 = 0;
    var buffer: [64 * 1024]u8 = undefined;
    while (offset < size) {
        const wanted: usize = @intCast(@min(@as(u64, buffer.len), size - offset));
        const count = c.pread(fd, &buffer, wanted, @intCast(offset));
        if (count < 0 and posix.errno(-1) == .INTR) continue;
        if (count <= 0) return error.CopyFailed;
        const len: usize = @intCast(count);
        hash.update(buffer[0..len]);
        offset += len;
    }
    var extra: [1]u8 = undefined;
    while (true) {
        const count = c.pread(fd, &extra, 1, @intCast(size));
        if (count < 0 and posix.errno(-1) == .INTR) continue;
        if (count != 0) return error.CopyFailed;
        break;
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

fn shaBytes(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn abort(result: *CurrentAssetFiles) Error!void {
    if (result.owner != result) return;
    cleanup(result, false) catch return error.CleanupFailed;
}

fn cleanup(result: *CurrentAssetFiles, strict_preflight: bool) Error!void {
    if (strict_preflight) {
        for (&result.private_files) |*file| {
            if (!file.present) continue;
            var stat: posix.Stat = undefined;
            if (result.dir_fd < 0 or c.fstatat(result.dir_fd, file.name[0..].ptr, &stat, posix.AT.SYMLINK_NOFOLLOW) != 0 or
                stat.dev != file.identity.device or stat.ino != file.identity.inode)
                return error.CleanupFailed;
        }
    }
    for (&result.private_files) |*file| {
        if (!file.present) continue;
        if (result.dir_fd < 0 or c.unlinkat(result.dir_fd, file.name[0..].ptr, 0) != 0)
            return error.CleanupFailed;
        file.present = false;
        result.complete = false;
    }
    if (result.dir_fd >= 0) {
        if (c.fsync(result.dir_fd) != 0) return error.CleanupFailed;
        _ = c.close(result.dir_fd);
        result.dir_fd = -1;
    }
    if (result.dir_present) {
        var stat: posix.Stat = undefined;
        if (result.parent_fd < 0 or c.fstatat(result.parent_fd, result.dir_name[0..].ptr, &stat, posix.AT.SYMLINK_NOFOLLOW) != 0 or
            stat.dev != result.dir_identity.device or stat.ino != result.dir_identity.inode or
            c.unlinkat(result.parent_fd, result.dir_name[0..].ptr, posix.AT.REMOVEDIR) != 0 or c.fsync(result.parent_fd) != 0)
            return error.CleanupFailed;
        result.dir_present = false;
    }
    if (result.parent_fd >= 0) {
        _ = c.close(result.parent_fd);
        result.parent_fd = -1;
    }
    result.* = .{};
}
