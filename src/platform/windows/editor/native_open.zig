//! Native initial-read ownership, independent of any document Registry.
//! The caller publishes only after this complete handle-relative snapshot exists.
const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const editor = maru.session.editor;
const relative = maru.win32_relative_file;
const identity_mod = @import("identity.zig");
const transaction_mod = @import("transaction.zig");
const w = std.os.windows;
extern "kernel32" fn GetVolumeInformationByHandleW(w.HANDLE, ?[*]u16, u32, ?*u32, ?*u32, ?*u32, ?[*]u16, u32) callconv(maru.win32_abi.winapi) w.BOOL;
extern "kernel32" fn ReOpenFile(w.HANDLE, u32, u32, u32) callconv(maru.win32_abi.winapi) w.HANDLE;
extern "kernel32" fn DuplicateHandle(w.HANDLE, w.HANDLE, w.HANDLE, *w.HANDLE, u32, w.BOOL, u32) callconv(maru.win32_abi.winapi) w.BOOL;
extern "kernel32" fn OpenFileById(w.HANDLE, *const FileIdDescriptor, u32, u32, ?*anyopaque, u32) callconv(maru.win32_abi.winapi) w.HANDLE;

// SDK FILE_ID_DESCRIPTOR: retain the full 128-bit selector. No legacy-ID
// fallback may turn an unsupported volume into a weaker identity grant.
// https://learn.microsoft.com/en-us/windows/win32/api/winbase/ns-winbase-file_id_descriptor
const FileIdDescriptor = extern struct {
    size: u32 = @sizeOf(FileIdDescriptor),
    kind: u32 = 2, // ExtendedFileIdType
    data: extern union { extended: [16]u8, legacy_alignment: i64 },
};
comptime {
    if (@sizeOf(FileIdDescriptor) != 24 or @offsetOf(FileIdDescriptor, "data") != 8) @compileError("FILE_ID_DESCRIPTOR ABI mismatch");
}

fn duplicate(handle: w.HANDLE) !w.HANDLE {
    var owned: w.HANDLE = undefined;
    // Duplicate the selected object without reopening a pathname or changing its
    // sharing policy. The caller can close its handle independently of the grant.
    // https://learn.microsoft.com/en-us/windows/win32/api/handleapi/nf-handleapi-duplicatehandle
    if (!DuplicateHandle(w.GetCurrentProcess(), handle, w.GetCurrentProcess(), &owned, 0, .FALSE, 2).toBool()) return error.HandleDuplicateFailed;
    return owned;
}

pub fn acceptsVolume(flags: u32, filesystem: []const u16) bool {
    // The SDK flags describe the selected handle's volume, never a drive-letter
    // assumption. Network/other filesystems must not acquire an NTFS save grant.
    // https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-getvolumeinformationbyhandlew
    return flags & 0x00200000 != 0 and flags & 0x00080000 == 0 and std.mem.eql(u16, filesystem, std.unicode.utf8ToUtf16LeStringLiteral("NTFS"));
}

/// Shared Windows namespace policy for synchronous and worker initial opens.
/// Selecting the root does not authorize traversal of any reparse point below it.
pub fn rootForPath(path: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
    const parsed = std.fs.path.parsePathWindows(u8, path);
    if (parsed.kind != .drive_absolute and parsed.kind != .unc_absolute) return error.InvalidPath;
    if (parsed.kind == .unc_absolute) {
        var components = std.mem.tokenizeAny(u8, parsed.root, "/\\");
        try relative.validateBasename(components.next() orelse return error.InvalidPath);
        try relative.validateBasename(components.next() orelse return error.InvalidPath);
    }
    return parsed.root;
}

pub const Snapshot = struct {
    allocator: std.mem.Allocator,
    root: std.Io.Dir,
    relative_path: []u8,
    original: std.Io.File,
    identity: identity_mod.Identity,
    path: []u8,
    bytes: []u8,
    raw_hash: u64,
    owned: bool = true,
    capability_verified: bool = false,

    pub fn openPath(a: std.mem.Allocator, io: std.Io, path: []const u8, limit: usize) !Snapshot {
        if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
        const root_path = try rootForPath(path);
        var root = try std.Io.Dir.openDirAbsolute(io, root_path, .{ .follow_symlinks = false });
        defer root.close(io);
        return open(a, io, root, path[root_path.len..], limit);
    }

    pub fn open(a: std.mem.Allocator, io: std.Io, root: std.Io.Dir, name: []const u8, limit: usize) !Snapshot {
        if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
        var owned_root: std.Io.Dir = .{ .handle = try duplicate(root.handle) };
        errdefer owned_root.close(io);
        const owned_name = try a.dupe(u8, name);
        errdefer a.free(owned_name);
        var pinned = try relative.open(a, owned_root, name);
        defer pinned.deinit(io);
        const identity = try identity_mod.Identity.capture(pinned.original.handle);
        // A name-opened witness, even attributes-only, prevents ordinary NTFS
        // containing-directory rename. Opening by full ID keeps the object alive
        // without that name dependency. This is an identity witness, never path
        // authority: reading/writing still enters through selected-root traversal.
        // https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-openfilebyid
        const descriptor: FileIdDescriptor = .{ .data = .{ .extended = identity.file } };
        const witness = OpenFileById(pinned.original.handle, &descriptor, 0x80, 7, null, 0x00200000);
        if (witness == w.INVALID_HANDLE_VALUE) return error.IdentityWitnessFailed;
        const original: std.Io.File = .{ .handle = witness, .flags = .{ .nonblocking = false } };
        errdefer original.close(io);
        if (!identity.eql(try identity_mod.Identity.capture(witness))) return error.IdentityChanged;
        // ReOpenFile preserves object identity and applies a read-time write
        // sharing fence. Never reread through a path after checking its ID.
        // https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-reopenfile
        const handle = ReOpenFile(pinned.original.handle, 0x80000000, 5, 0x00200000);
        if (handle == w.INVALID_HANDLE_VALUE) return error.SourceBusy;
        const snapshot: std.Io.File = .{ .handle = handle, .flags = .{ .nonblocking = false } };
        defer snapshot.close(io);
        if (!identity.eql(try identity_mod.Identity.capture(handle))) return error.IdentityChanged;
        const size = (try snapshot.stat(io)).size;
        if (size > limit) return error.FileTooLarge;
        const bytes = try a.alloc(u8, @intCast(size));
        errdefer a.free(bytes);
        if (try snapshot.readPositionalAll(io, bytes, 0) != size) return error.SourceChanged;
        var root_path: [std.fs.max_path_bytes]u8 = undefined;
        const root_len = try root.realPath(io, &root_path);
        const path = try std.fs.path.join(a, &.{ root_path[0..root_len], name });
        errdefer a.free(path);
        return .{ .allocator = a, .root = owned_root, .relative_path = owned_name, .original = original, .identity = identity, .path = path, .bytes = bytes, .raw_hash = editor.document_state.contentHash(bytes) };
    }

    pub fn probe(self: *Snapshot, io: std.Io, limit: usize) !void {
        // A failed retry must not retain the permit from an earlier probe.
        self.capability_verified = false;
        try self.validate();
        var flags: u32 = 0;
        var filesystem: [16]u16 = @splat(0);
        if (!GetVolumeInformationByHandleW(self.original.handle, null, 0, null, null, &flags, &filesystem, filesystem.len).toBool()) return error.SaveCapabilityUnavailable;
        const end = std.mem.indexOfScalar(u16, &filesystem, 0) orelse return error.SaveCapabilityUnavailable;
        if (!acceptsVolume(flags, filesystem[0..end])) return error.SaveCapabilityUnavailable;
        var pinned = try maru.win32_relative_file.open(self.allocator, self.root, self.relative_path);
        defer pinned.deinit(io);
        if (!self.identity.eql(try identity_mod.Identity.capture(pinned.original.handle))) return error.IdentityChanged;
        var tx = try transaction_mod.Transaction.beginExperimental(self.allocator, io, &pinned, self.raw_hash, limit);
        // This probe never writes or commits. Even a cleanup failure is reported as
        // unsupported, rather than enabling edits with an unproved native permit.
        defer if (tx.phase != .closed) tx.close(io) catch {};
        try tx.rollback();
        if (try tx.queryOutcome() != .aborted) return error.SaveCapabilityUnavailable;
        try tx.close(io);
        self.capability_verified = true;
    }

    pub fn validate(self: *const Snapshot) !void {
        if (!self.owned) return error.OpenSnapshotConsumed;
        // Publication must retain the raw source CAS, including BOM/line ends.
        if (editor.document_state.contentHash(self.bytes) != self.raw_hash) return error.OpenImageChanged;
    }

    pub fn deinit(self: *Snapshot, io: std.Io) void {
        if (!self.owned) return;
        self.original.close(io);
        self.root.close(io);
        self.allocator.free(self.relative_path);
        self.allocator.free(self.path);
        self.allocator.free(self.bytes);
        self.owned = false;
    }
};
