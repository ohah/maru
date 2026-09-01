//! Single-read authority for the current release manifest pathname.
//!
//! The candidate keeps the no-follow input bytes alive beside their canonical parse until current
//! GitHub authority has bound that exact manifest. Its input can then be consumed once without
//! reopening the caller pathname.

const std = @import("std");
const manifest = @import("release_manifest");
const files = @import("release_adapter_files");
const context_mod = @import("release_adapter_context");

pub const Error = error{
    InvalidOwner,
    InvalidManifestPath,
    InvalidManifestInput,
} || std.mem.Allocator.Error;

pub const CurrentManifestCandidate = struct {
    owner: ?*CurrentManifestCandidate = null,
    input: ?files.Input = null,
    parsed: ?manifest.Parsed = null,

    pub fn value(self: *const @This()) ?*const manifest.Manifest {
        if (self.owner != self) return null;
        return if (self.parsed) |*parsed| parsed.value() else null;
    }

    pub fn bytes(self: *const @This()) ?[]const u8 {
        if (self.owner != self) return null;
        return if (self.input) |input| input.bytes else null;
    }

    pub fn takeInput(self: *@This()) Error!files.Input {
        if (self.owner != self or self.parsed == null or self.input == null)
            return error.InvalidOwner;
        self.parsed.?.deinit();
        self.parsed = null;
        const input = self.input.?;
        self.input = null;
        self.* = .{};
        return input;
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) Error!void {
        if (self.owner != self or self.parsed == null or self.input == null)
            return error.InvalidOwner;
        self.parsed.?.deinit();
        self.input.?.deinit(allocator);
        self.* = .{};
    }
};

pub fn read(
    allocator: std.mem.Allocator,
    context: context_mod.Context,
    path: [:0]const u8,
    result: *CurrentManifestCandidate,
) Error!void {
    if (result.owner != null or result.input != null or result.parsed != null)
        return error.InvalidOwner;
    var name_storage: [manifest.max_asset_name_bytes]u8 = undefined;
    const name = canonicalName(context.tag, &name_storage) catch
        return error.InvalidManifestPath;
    if (!std.fs.path.isAbsolute(path) or !std.mem.eql(u8, std.fs.path.basename(path), name))
        return error.InvalidManifestPath;

    result.input = files.readInputAlloc(allocator, path, manifest.max_manifest_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidManifestInput,
    };
    errdefer {
        result.input.?.deinit(allocator);
        result.input = null;
    }
    if (result.input.?.bytes.len == 0) return error.InvalidManifestInput;
    result.parsed = manifest.parseCanonical(allocator, result.input.?.bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidManifestInput,
    };
    result.owner = result;
}

fn canonicalName(tag: []const u8, storage: *[manifest.max_asset_name_bytes]u8) ![]const u8 {
    if (tag.len < 2 or tag[0] != 'v') return error.InvalidManifestPath;
    return std.fmt.bufPrint(storage, "Maru-{s}-session-host-release.json", .{tag[1..]}) catch
        return error.InvalidManifestPath;
}
