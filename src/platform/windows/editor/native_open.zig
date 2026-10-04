//! Native initial-read ownership, independent of any document Registry.
//! The caller publishes only after this complete handle-relative snapshot exists.
const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const editor = maru.session.editor;
const relative = maru.win32_relative_file;
const identity_mod = @import("identity.zig");
const w = std.os.windows;
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
