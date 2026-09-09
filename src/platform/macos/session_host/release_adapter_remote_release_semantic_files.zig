//! Filesystem-to-semantic bridge for exact-ID downloaded Release assets.

const std = @import("std");
const c = std.c;
const posix = std.posix;
const manifest = @import("release_manifest");
const evidence = @import("release_evidence");
const context_mod = @import("release_adapter_context");
const metadata = @import("release_adapter_remote_release_metadata");
const assets_mod = @import("release_adapter_remote_release_assets");
const semantics = @import("release_adapter_remote_release_semantics");

pub fn bind(allocator: std.mem.Allocator, context: context_mod.Context, assets: *assets_mod.Assets, result: *semantics.Owner) !void {
    var reader = SystemReader{};
    return bindWith(&reader, allocator, context, assets, result);
}

pub fn bindWith(reader: anytype, allocator: std.mem.Allocator, context: context_mod.Context, assets: anytype, result: *semantics.Owner) !void {
    if (!result.isPristineForComposition() or aliasesInputs(context, assets, result)) return error.InvalidOwner;
    try context_mod.validateTrusted(context);
    _ = try assets.remaining();
    const initial = try assets.revalidate();
    const manifest_asset = initial.assets[@intFromEnum(metadata.Role.manifest)];
    const evidence_asset = initial.assets[@intFromEnum(metadata.Role.evidence_candidate)];
    if (manifest_asset.size > manifest.max_manifest_bytes or evidence_asset.size > evidence.max_evidence_bytes) return error.AssetTooLarge;

    const manifest_bytes = try allocator.alloc(u8, @intCast(manifest_asset.size));
    defer allocator.free(manifest_bytes);
    const evidence_bytes = try allocator.alloc(u8, @intCast(evidence_asset.size));
    defer allocator.free(evidence_bytes);

    try readRole(reader, assets, .manifest, manifest_bytes);
    try readRole(reader, assets, .evidence_candidate, evidence_bytes);
    const final = try assets.revalidate();
    if (!sameAsset(manifest_asset, final.assets[@intFromEnum(metadata.Role.manifest)]) or
        !sameAsset(evidence_asset, final.assets[@intFromEnum(metadata.Role.evidence_candidate)])) return error.FileChanged;
    const remote_owner = try assets.metadataOwner();
    try semantics.bind(allocator, context, remote_owner, manifest_bytes, evidence_bytes, result);
    _ = assets.remaining() catch |err| {
        result.deinit(allocator) catch return error.CleanupFailed;
        return err;
    };
}

fn readRole(reader: anytype, assets: anytype, role: metadata.Role, bytes: []u8) !void {
    const fd = try assets.openAssetDescriptor(role);
    defer _ = c.close(fd);
    try reader.readExact(fd, bytes);
    _ = try assets.revalidate();
}

const SystemReader = struct {
    fn readExact(_: *@This(), fd: c.fd_t, bytes: []u8) !void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            const amount = c.pread(fd, bytes[offset..].ptr, bytes.len - offset, @intCast(offset));
            if (amount < 0 and posix.errno(amount) == .INTR) continue;
            if (amount <= 0) return error.FileChanged;
            offset += @intCast(amount);
        }
        var extra: [1]u8 = undefined;
        while (true) {
            const amount = c.pread(fd, &extra, 1, @intCast(offset));
            if (amount < 0 and posix.errno(amount) == .INTR) continue;
            if (amount < 0) return error.FileChanged;
            if (amount != 0) return error.FileChanged;
            break;
        }
    }
};

fn sameAsset(a: anytype, b: @TypeOf(a)) bool {
    return a.role == b.role and a.id == b.id and a.device == b.device and a.inode == b.inode and a.size == b.size and
        std.mem.eql(u8, a.name, b.name) and std.mem.eql(u8, a.path, b.path) and std.mem.eql(u8, a.sha256, b.sha256);
}

fn overlaps(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const a_end = @intFromPtr(a.ptr) + a.len;
    const b_end = @intFromPtr(b.ptr) + b.len;
    return @intFromPtr(a.ptr) < b_end and @intFromPtr(b.ptr) < a_end;
}

fn aliasesInputs(context: context_mod.Context, assets: anytype, result: *const semantics.Owner) bool {
    const inputs = [_][]const u8{
        std.mem.asBytes(assets),
        context.repository.owner,
        context.repository.name,
        context.tag,
        context.source_commit,
        context.build.workflow_ref,
    };
    const output = std.mem.asBytes(result);
    for (inputs, 0..) |input, index| {
        if (overlaps(output, input)) return true;
        for (inputs[0..index]) |prior| if (overlaps(input, prior)) return true;
    }
    return false;
}
