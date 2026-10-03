//! Unpublished safe-save file. Cleanup follows the opened object, never a pathname.
const std = @import("std");
const builtin = @import("builtin");
const w = std.os.windows;
const pinned_path = @import("maru").win32_relative_file;
const abi = @import("maru").win32_abi;
const identity_mod = @import("identity.zig");
extern "kernel32" fn ReOpenFile(w.HANDLE, u32, u32, u32) callconv(abi.winapi) w.HANDLE;
extern "kernel32" fn GetCurrentProcess() callconv(abi.winapi) w.HANDLE;
extern "kernel32" fn GetLastError() callconv(abi.winapi) u32;
extern "kernel32" fn GetProcessHandleCount(w.HANDLE, *u32) callconv(abi.winapi) w.BOOL;
extern "kernel32" fn LocalFree(?*anyopaque) callconv(abi.winapi) ?*anyopaque;
extern "advapi32" fn ConvertStringSecurityDescriptorToSecurityDescriptorW([*:0]const u16, u32, *?*anyopaque, ?*u32) callconv(abi.winapi) w.BOOL;
extern "ntdll" fn NtSetSecurityObject(w.HANDLE, u32, *const anyopaque) callconv(abi.winapi) w.NTSTATUS;

pub const Error = std.mem.Allocator.Error || identity_mod.Error || error{ UnsupportedPlatform, InvalidName, CreateFailed, NameCollision, RandomFailed, DispositionFailed, WitnessFailed, IdentityChanged };

// ON_CLOSE clears the per-handle delete-on-close state. Rearming is not supported
// on every filesystem; cancellation then marks the exact owned object for deletion.
// This is a primitive, not a publish permit.
// https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ntddk/ns-ntddk-_file_disposition_information_ex
fn setOnClose(file: std.Io.File, enabled: bool) Error!void {
    var info: w.FILE.DISPOSITION.INFORMATION.EX = .{ .Flags = .{
        .ON_CLOSE = true,
        .DELETE = enabled,
        .IGNORE_READONLY_ATTRIBUTE = true,
    } };
    var status: w.IO_STATUS_BLOCK = undefined;
    const result = w.ntdll.NtSetInformationFile(file.handle, &status, &info, @sizeOf(@TypeOf(info)), .DispositionEx);
    if (result == .NOT_SUPPORTED and enabled) return markOwnedForDeletion(file.handle);
    if (result != .SUCCESS) {
        if (builtin.is_test) std.debug.print("on_close enabled={} status=0x{X}\n", .{ enabled, @intFromEnum(result) });
        return error.DispositionFailed;
    }
}

// Metadata-only access does not prevent a later exclusive replacement open. The
// handle still binds the exact object after its original name has been reused.
fn retainWitness(file: std.Io.File) Error!std.Io.File {
    const handle = ReOpenFile(file.handle, 0x00020080, 7, 0x02200000);
    if (handle == w.INVALID_HANDLE_VALUE) return error.WitnessFailed;
    return .{ .handle = handle, .flags = .{ .nonblocking = false } };
}

fn deleteOwned(witness: std.Io.File) Error!void {
    const handle = ReOpenFile(witness.handle, 0x00010000, 7, 0x02200000);
    if (handle == w.INVALID_HANDLE_VALUE) return error.WitnessFailed;
    defer _ = w.ntdll.NtClose(handle);
    try markOwnedForDeletion(handle);
}

fn retainCleanupControl(file: std.Io.File) Error!std.Io.File {
    // Capture WRITE_DAC before copying a source ACL that can deny later opens.
    // These metadata rights permit an exclusive publisher data open afterwards.
    const handle = ReOpenFile(file.handle, 0x00060080, 7, 0x02200000);
    if (handle == w.INVALID_HANDLE_VALUE) return error.WitnessFailed;
    return .{ .handle = handle, .flags = .{ .nonblocking = false } };
}

fn allowOwnedCleanupDelete(witness: std.Io.File) Error!void {
    // Native user-mode counterpart of the WDK security setter:
    // https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ntifs/nf-ntifs-zwsetsecurityobject
    // Cancellation only: restrict this owned candidate to deletion and metadata.
    // Grant no data access. The already-held WRITE_DAC authority survives a
    // cloned restrictive ACL; neither the original nor a reused name is changed.
    var sd: [48]u8 align(4) = .{0} ** 48;
    sd[0] = 1;
    std.mem.writeInt(u16, sd[2..4], 0x9004, .little); // self-relative, protected DACL
    std.mem.writeInt(u32, sd[16..20], 20, .little);
    sd[20] = 2;
    std.mem.writeInt(u16, sd[22..24], 28, .little);
    std.mem.writeInt(u16, sd[24..26], 1, .little);
    std.mem.writeInt(u16, sd[30..32], 20, .little); // ACCESS_ALLOWED_ACE
    std.mem.writeInt(u32, sd[32..36], 0x00110080, .little); // DELETE, SYNCHRONIZE, READ_ATTRIBUTES; no data
    sd[36] = 1;
    sd[37] = 1;
    sd[43] = 1; // Everyone S-1-1-0
    if (NtSetSecurityObject(witness.handle, 0x80000004, &sd) != .SUCCESS) return error.DispositionFailed;
}

fn markOwnedForDeletion(handle: w.HANDLE) Error!void {
    var info: w.FILE.DISPOSITION.INFORMATION.EX = .{ .Flags = .{
        .DELETE = true,
        .POSIX_SEMANTICS = true,
        .IGNORE_READONLY_ATTRIBUTE = true,
    } };
    var status: w.IO_STATUS_BLOCK = undefined;
    if (w.ntdll.NtSetInformationFile(handle, &status, &info, @sizeOf(@TypeOf(info)), .DispositionEx) != .SUCCESS)
        return error.DispositionFailed;
}

pub const Stage = struct {
    allocator: std.mem.Allocator,
    name: []u8,
    file: std.Io.File,
    cleanup_control: std.Io.File,

    pub fn deinit(self: *Stage, io: std.Io) void {
        // DELETE_ON_CLOSE owns this exact object even if an attempted operation failed.
        self.cleanup_control.close(io);
        self.file.close(io);
        self.allocator.free(self.name);
        self.* = undefined;
    }

    pub fn write(self: *Stage, io: std.Io, text: []const u8) !void {
        // Metadata cloning can leave an old primary stream. Positional replacement
        // plus exact length removes its suffix while leaving named streams alone.
        try self.file.writePositionalAll(io, text, 0);
        try self.file.setLength(io, text.len);
        try self.file.sync(io);
    }

    /// Success consumes Stage; failure leaves its delete-on-close ownership intact.
    pub fn handoff(self: *Stage, io: std.Io) Error!Prepared {
        return self.handoffFor(io, NativeHandoff);
    }

    fn handoffFor(self: *Stage, io: std.Io, comptime Api: type) Error!Prepared {
        const identity = try identity_mod.Identity.capture(self.file.handle);
        const witness = self.cleanup_control;
        try Api.clearDeletion(self.file);
        // No fallible work follows clearing auto-deletion: ownership must always
        // reach Prepared, which binds cleanup to the exact object after rename.
        self.file.close(io);
        const prepared: Prepared = .{ .allocator = self.allocator, .name = self.name, .witness = witness, .identity = identity };
        self.* = undefined;
        return prepared;
    }
};

const NativeHandoff = struct {
    fn clearDeletion(file: std.Io.File) Error!void {
        try setOnClose(file, false);
    }
};

/// Owns an unpublished candidate after its data handle is closed. A publisher
/// must keep this owner alive until it has validated publication or rollback.
pub const Prepared = struct {
    allocator: std.mem.Allocator,
    name: []u8,
    witness: std.Io.File,
    identity: identity_mod.Identity,

    /// Failure keeps ownership available for retry or recovery; never erase a
    /// pathname that may now name a competitor. Success consumes Prepared.
    pub fn cancel(self: *Prepared, io: std.Io) Error!void {
        if (!self.identity.eql(try identity_mod.Identity.capture(self.witness.handle))) return error.IdentityChanged;
        deleteOwned(self.witness) catch |err| {
            if (err != error.WitnessFailed or GetLastError() != 5) return err;
            try allowOwnedCleanupDelete(self.witness);
            try deleteOwned(self.witness);
        };
        self.witness.close(io);
        self.allocator.free(self.name);
        self.* = undefined;
    }
};

// Microsoft NtCreateFile: CREATE rejects collisions; RootDirectory avoids reopening
// authority by string; DELETE_ON_CLOSE requires DELETE and removes the owned object.
// https://learn.microsoft.com/en-us/windows/win32/api/winternl/nf-winternl-ntcreatefile
fn createNamed(allocator: std.mem.Allocator, parent: std.Io.Dir, name: []const u8) Error!Stage {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.InvalidName;
    for (name) |ch| if (ch == 0 or ch == ':' or ch == '/' or ch == '\\') return error.InvalidName;
    const wide = std.unicode.utf8ToUtf16LeAlloc(allocator, name) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidName,
    };
    defer allocator.free(wide);
    if (wide.len > std.math.maxInt(u16) / 2) return error.InvalidName;
    var unicode: w.UNICODE_STRING = .{ .Length = @intCast(wide.len * 2), .MaximumLength = @intCast(wide.len * 2), .Buffer = wide.ptr };
    const attrs: w.OBJECT.ATTRIBUTES = .{ .RootDirectory = parent.handle, .ObjectName = &unicode };
    var status: w.IO_STATUS_BLOCK = undefined;
    var handle: w.HANDLE = undefined;
    const result = w.ntdll.NtCreateFile(&handle, .{
        .SPECIFIC = .{ .FILE = .{ .READ_DATA = true, .WRITE_DATA = true, .READ_EA = true, .WRITE_EA = true, .READ_ATTRIBUTES = true, .WRITE_ATTRIBUTES = true } },
        // A future metadata restore needs these rights on the already-owned file.
        .STANDARD = .{ .RIGHTS = .REQUIRED, .SYNCHRONIZE = true },
    }, &attrs, &status, null, .{}, .{}, .CREATE, .{
        .NON_DIRECTORY_FILE = true,
        .IO = .SYNCHRONOUS_NONALERT,
        .OPEN_REPARSE_POINT = true,
        .DELETE_ON_CLOSE = true,
    }, null, 0);
    if (result == .OBJECT_NAME_COLLISION) return error.NameCollision;
    if (result != .SUCCESS) return error.CreateFailed;
    errdefer _ = w.ntdll.NtClose(handle);
    const file: std.Io.File = .{ .handle = handle, .flags = .{ .nonblocking = false } };
    const cleanup_control = try retainCleanupControl(file);
    errdefer _ = w.ntdll.NtClose(cleanup_control.handle);
    return .{ .allocator = allocator, .name = try allocator.dupe(u8, name), .file = file, .cleanup_control = cleanup_control };
}

/// The caller keeps the path pins alive through staging and the eventual commit.
pub fn create(allocator: std.mem.Allocator, io: std.Io, pinned: *const pinned_path.Pinned) Error!Stage {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
    for (0..16) |_| {
        var random: [16]u8 = undefined;
        io.randomSecure(&random) catch return error.RandomFailed;
        const hex = std.fmt.bytesToHex(random, .lower);
        var name_buf: [64]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, ".maru-save-{s}.tmp", .{hex}) catch unreachable;
        return createNamed(allocator, pinned.parent(), name) catch |err| switch (err) {
            error.NameCollision => continue,
            else => return err,
        };
    }
    return error.NameCollision;
}

fn expectAbsent(dir: std.Io.Dir, name: []const u8) !void {
    if (dir.statFile(std.testing.io, name, .{})) |_| return error.TestUnexpectedResult else |err| try std.testing.expectEqual(error.FileNotFound, err);
}

test "Windows safe save managed handoff transfers name and permits exclusive replacement access" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var stage = try createNamed(std.testing.allocator, tmp.dir, "prepared.tmp");
    var transferred = false;
    defer if (!transferred) stage.deinit(io);
    try stage.write(io, "candidate");
    var prepared = try stage.handoff(io);
    transferred = true;
    defer prepared.cancel(io) catch @panic("prepared cleanup failed");
    try std.testing.expectEqualStrings("prepared.tmp", prepared.name);
    {
        const exclusive = ReOpenFile(prepared.witness.handle, 0xc0010000, 0, 0x02200000);
        try std.testing.expect(exclusive != w.INVALID_HANDLE_VALUE);
        defer _ = w.ntdll.NtClose(exclusive);
        try std.testing.expect(prepared.identity.eql(try identity_mod.Identity.capture(exclusive)));
    }
    const bytes = try tmp.dir.readFileAlloc(io, prepared.name, std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("candidate", bytes);
}

test "Windows safe save managed handoff cancellation preserves the reused name competitor" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var stage = try createNamed(std.testing.allocator, tmp.dir, "prepared.tmp");
    var transferred = false;
    defer if (!transferred) stage.deinit(io);
    var prepared = try stage.handoff(io);
    transferred = true;
    var cancelled = false;
    defer if (!cancelled) prepared.cancel(io) catch @panic("prepared cleanup failed");
    try tmp.dir.rename("prepared.tmp", tmp.dir, "moved.tmp", io);
    try tmp.dir.writeFile(io, .{ .sub_path = "prepared.tmp", .data = "competitor" });
    try prepared.cancel(io);
    cancelled = true;
    try expectAbsent(tmp.dir, "moved.tmp");
    const bytes = try tmp.dir.readFileAlloc(io, "prepared.tmp", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("competitor", bytes);
}

test "Windows safe save failed managed handoff retains staging ownership and closes witnesses" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    var cleanup_tree = true;
    defer if (cleanup_tree) tmp.cleanup() else {
        // A deliberate handle-leak mutant keeps a delete-pending child alive.
        // Recursive fixture cleanup would spin; report the leak and let process
        // termination close those leaked handles instead of hiding the failure.
        tmp.dir.close(io);
        tmp.parent_dir.close(io);
    };
    var stage = try createNamed(std.testing.allocator, tmp.dir, "failure.tmp");
    var closed = false;
    defer if (!closed) stage.deinit(io);
    try stage.write(io, "candidate");
    const Failure = struct {
        fn clearDeletion(_: std.Io.File) Error!void {
            return error.DispositionFailed;
        }
    };
    var before: u32 = 0;
    try std.testing.expect(GetProcessHandleCount(GetCurrentProcess(), &before).toBool());
    for (0..100) |_| try std.testing.expectError(error.DispositionFailed, stage.handoffFor(io, Failure));
    var after: u32 = 0;
    try std.testing.expect(GetProcessHandleCount(GetCurrentProcess(), &after).toBool());
    if (before != after) cleanup_tree = false;
    try std.testing.expectEqual(before, after);
    try std.testing.expectEqual(@as(u64, 9), (try stage.file.stat(io)).size);
    stage.deinit(io);
    closed = true;
    try expectAbsent(tmp.dir, "failure.tmp");
}

test "Windows safe save prepared cancellation refuses a mismatched identity and permits retry" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var stage = try createNamed(std.testing.allocator, tmp.dir, "retry.tmp");
    var transferred = false;
    defer if (!transferred) stage.deinit(io);
    var prepared = try stage.handoff(io);
    transferred = true;
    const identity = prepared.identity;
    var cancelled = false;
    defer if (!cancelled) {
        prepared.identity = identity;
        prepared.cancel(io) catch @panic("prepared cleanup failed");
    };
    prepared.identity.file[15] ^= 1;
    if (prepared.cancel(io)) |_| {
        // A broken cancellation implementation may consume the owner. Do not
        // let fixture cleanup access it again and conceal the original failure.
        cancelled = true;
        return error.TestUnexpectedResult;
    } else |err| try std.testing.expectEqual(error.IdentityChanged, err);
    try std.testing.expectEqualStrings("retry.tmp", prepared.name);
    _ = try tmp.dir.statFile(io, prepared.name, .{});
    prepared.identity = identity;
    try prepared.cancel(io);
    cancelled = true;
    try expectAbsent(tmp.dir, "retry.tmp");
}

fn setTestDacl(handle: w.HANDLE, comptime sddl: []const u8) Error!void {
    var sd: ?*anyopaque = null;
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(std.unicode.utf8ToUtf16LeStringLiteral(sddl), 1, &sd, null).toBool()) return error.DispositionFailed;
    defer _ = LocalFree(sd);
    if (NtSetSecurityObject(handle, 0x80000004, sd.?) != .SUCCESS) return error.DispositionFailed;
}

test "Windows safe save managed handoff cancels with retained control when both delete authorities are denied" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // ReOpenFile is a file API; reopen this directory relative to its handle.
    var empty: [1]u16 = .{0};
    var name: w.UNICODE_STRING = .{ .Length = 0, .MaximumLength = 0, .Buffer = &empty };
    const attrs: w.OBJECT.ATTRIBUTES = .{ .RootDirectory = tmp.dir.handle, .ObjectName = &name };
    var status: w.IO_STATUS_BLOCK = undefined;
    var parent: w.HANDLE = undefined;
    try std.testing.expectEqual(w.NTSTATUS.SUCCESS, w.ntdll.NtCreateFile(&parent, @bitCast(@as(u32, 0x00140000)), &attrs, &status, null, .{}, .{ .READ = true, .WRITE = true, .DELETE = true }, .OPEN, .{ .DIRECTORY_FILE = true, .IO = .SYNCHRONOUS_NONALERT, .OPEN_REPARSE_POINT = true }, null, 0));
    defer _ = w.ntdll.NtClose(parent);
    defer setTestDacl(parent, "D:P(A;;FA;;;OW)") catch @panic("fixture parent ACL restoration failed");
    var stage = try createNamed(std.testing.allocator, tmp.dir, "denied.tmp");
    var closed = false;
    defer if (!closed) stage.deinit(io);
    try stage.write(io, "candidate");
    // Everyone DELETE deny on the child plus DELETE_CHILD deny on the parent.
    // OWNER_RIGHTS grants remaining rights so the fixture can restore its DACL.
    try setTestDacl(stage.file.handle, "D:P(D;;SD;;;WD)(A;;FA;;;OW)");
    try setTestDacl(parent, "D:P(D;;0x40;;;WD)(A;;FA;;;OW)");
    var prepared = try stage.handoff(io);
    closed = true;
    var cancelled = false;
    defer if (!cancelled) {
        setTestDacl(parent, "D:P(A;;FA;;;OW)") catch @panic("fixture parent ACL restoration failed");
        setTestDacl(prepared.witness.handle, "D:P(A;;FA;;;OW)") catch {};
        prepared.cancel(io) catch @panic("prepared cleanup failed");
    };
    try std.testing.expectEqual(@as(u64, 9), (try prepared.witness.stat(io)).size);
    try prepared.cancel(io);
    cancelled = true;
    try expectAbsent(tmp.dir, "denied.tmp");
}

test "Windows safe save stage handoff clears on-close deletion while retaining the object" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var stage = try createNamed(std.testing.allocator, tmp.dir, "handoff.tmp");
    var closed = false;
    defer if (!closed) stage.deinit(io);
    try stage.write(io, "candidate");
    const witness = try retainWitness(stage.file);
    defer witness.close(io);
    try setOnClose(stage.file, false);
    stage.deinit(io);
    closed = true;
    const bytes = try tmp.dir.readFileAlloc(io, "handoff.tmp", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("candidate", bytes);
    try std.testing.expectEqual(@as(u64, 9), (try witness.stat(io)).size);
    // The publisher must be able to open the candidate exclusively while the
    // metadata-only witness continues to bind it.
    const exclusive = ReOpenFile(witness.handle, 0xc0010000, 0, 0x02200000);
    if (exclusive == w.INVALID_HANDLE_VALUE) return error.WitnessFailed;
    _ = w.ntdll.NtClose(exclusive);
    try deleteOwned(witness);
    try expectAbsent(tmp.dir, "handoff.tmp");
}

test "Windows safe save stage handoff survives closing the final witness" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var stage = try createNamed(std.testing.allocator, tmp.dir, "survives.tmp");
    var closed = false;
    defer if (!closed) stage.deinit(io);
    const witness = try retainWitness(stage.file);
    var witness_closed = false;
    defer if (!witness_closed) witness.close(io);
    try setOnClose(stage.file, false);
    stage.deinit(io);
    closed = true;
    witness.close(io);
    witness_closed = true;
    try std.testing.expectEqual(@as(u64, 0), (try tmp.dir.statFile(io, "survives.tmp", .{})).size);
}

test "Windows safe save stage cancelled handoff removes its readonly object" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var stage = try createNamed(std.testing.allocator, tmp.dir, "cancel.tmp");
    var closed = false;
    defer if (!closed) stage.deinit(io);
    try setOnClose(stage.file, false);
    var basic: w.FILE.BASIC_INFORMATION = .{
        .CreationTime = 0,
        .LastAccessTime = 0,
        .LastWriteTime = 0,
        .ChangeTime = 0,
        .FileAttributes = .{ .READONLY = true },
    };
    var status: w.IO_STATUS_BLOCK = undefined;
    try std.testing.expectEqual(w.NTSTATUS.SUCCESS, w.ntdll.NtSetInformationFile(stage.file.handle, &status, &basic, @sizeOf(@TypeOf(basic)), .Basic));
    try setOnClose(stage.file, true);
    stage.deinit(io);
    closed = true;
    try expectAbsent(tmp.dir, "cancel.tmp");
}

test "Windows safe save stage disposition refuses a handle without delete authority" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "original.txt", .data = "original" });
    const file = try tmp.dir.openFile(io, "original.txt", .{});
    defer file.close(io);
    try std.testing.expectError(error.DispositionFailed, setOnClose(file, true));
    try std.testing.expectEqual(@as(u64, 8), (try file.stat(io)).size);
}

test "Windows safe save stage witness cleanup preserves a competitor at the reused name" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var stage = try createNamed(std.testing.allocator, tmp.dir, "owned.tmp");
    var closed = false;
    defer if (!closed) stage.deinit(io);
    const witness = try retainWitness(stage.file);
    defer witness.close(io);
    try setOnClose(stage.file, false);
    stage.deinit(io);
    closed = true;
    try tmp.dir.rename("owned.tmp", tmp.dir, "moved.tmp", io);
    try tmp.dir.writeFile(io, .{ .sub_path = "owned.tmp", .data = "competitor" });
    try deleteOwned(witness);
    try expectAbsent(tmp.dir, "moved.tmp");
    const bytes = try tmp.dir.readFileAlloc(io, "owned.tmp", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("competitor", bytes);
}

test "Windows safe save stage writes exact content and cleans the unpublished object" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "original.txt", .data = "original" });
    var pinned = try pinned_path.open(std.testing.allocator, tmp.dir, "original.txt");
    defer pinned.deinit(io);
    var stage = try create(std.testing.allocator, io, &pinned);
    var closed = false;
    defer if (!closed) stage.deinit(io);
    const name = try std.testing.allocator.dupe(u8, stage.name);
    defer std.testing.allocator.free(name);
    try stage.write(io, "long text to truncate");
    try stage.write(io, "new");
    var bytes: [64]u8 = undefined;
    const n = try stage.file.readPositionalAll(io, &bytes, 0);
    try std.testing.expectEqualStrings("new", bytes[0..n]);
    try std.testing.expectEqual(@as(u64, 3), (try stage.file.stat(io)).size);
    const old_n = try pinned.original.readPositionalAll(io, &bytes, 0);
    try std.testing.expectEqualStrings("original", bytes[0..old_n]);
    stage.deinit(io);
    closed = true;
    try expectAbsent(pinned.parent(), name);
}

test "Windows safe save stage collision does not open or truncate an existing file" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "collision.tmp", .data = "foreign" });
    try std.testing.expectError(error.NameCollision, createNamed(std.testing.allocator, tmp.dir, "collision.tmp"));
    var bytes: [64]u8 = undefined;
    const file = try tmp.dir.openFile(std.testing.io, "collision.tmp", .{});
    defer file.close(std.testing.io);
    try std.testing.expectEqualStrings("foreign", bytes[0..try file.readPositionalAll(std.testing.io, &bytes, 0)]);
}

fn allocationPrefix(allocator: std.mem.Allocator, parent: std.Io.Dir) !void {
    var stage = createNamed(allocator, parent, "allocation.tmp") catch |err| {
        try expectAbsent(parent, "allocation.tmp");
        return err;
    };
    stage.deinit(std.testing.io);
    try expectAbsent(parent, "allocation.tmp");
}

test "Windows safe save stage unwinds kernel objects at every allocation failure" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationPrefix, .{tmp.dir});
}

test "Windows safe save stage rejects traversal and cannot be reopened by another reader" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "", ".", "..", "../outside", "bad:stream", "a/b", "a\\b" }) |name| {
        try std.testing.expectError(error.InvalidName, createNamed(std.testing.allocator, tmp.dir, name));
    }
    var stage = try createNamed(std.testing.allocator, tmp.dir, "exclusive.tmp");
    defer stage.deinit(std.testing.io);
    if (tmp.dir.openFile(std.testing.io, "exclusive.tmp", .{})) |file| {
        file.close(std.testing.io);
        return error.TestUnexpectedResult;
    } else |_| {}
}

test "Windows safe save stage carries native metadata restore access on its owned handle" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var stage = try createNamed(std.testing.allocator, tmp.dir, "metadata.tmp");
    defer stage.deinit(std.testing.io);
    var status: w.IO_STATUS_BLOCK = undefined;
    var access: w.FILE.ACCESS_INFORMATION = undefined;
    try std.testing.expectEqual(w.NTSTATUS.SUCCESS, w.ntdll.NtQueryInformationFile(stage.file.handle, &status, &access, @sizeOf(@TypeOf(access)), .Access));
    try std.testing.expect(access.AccessFlags.STANDARD.RIGHTS.READ_CONTROL);
    try std.testing.expect(access.AccessFlags.STANDARD.RIGHTS.WRITE_DAC);
    try std.testing.expect(access.AccessFlags.STANDARD.RIGHTS.WRITE_OWNER);
    try std.testing.expect(access.AccessFlags.SPECIFIC.FILE.READ_EA);
    try std.testing.expect(access.AccessFlags.SPECIFIC.FILE.WRITE_EA);
}

test "Windows safe save stage flush failure propagates and leaves the original unchanged" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "original.txt", .data = "original" });
    var pinned = try pinned_path.open(std.testing.allocator, tmp.dir, "original.txt");
    defer pinned.deinit(io);
    var stage = try createNamed(std.testing.allocator, pinned.parent(), "flush.tmp");
    var closed = false;
    defer if (!closed) stage.deinit(io);
    const Failure = struct {
        fn sync(_: ?*anyopaque, _: std.Io.File) std.Io.File.SyncError!void {
            return error.InputOutput;
        }
    };
    // Every write still goes to the real native file. Only the durability operation fails.
    var vtable = io.vtable.*;
    vtable.fileSync = Failure.sync;
    var failing_io = io;
    failing_io.vtable = &vtable;
    try std.testing.expectError(error.InputOutput, stage.write(failing_io, "candidate"));
    var bytes: [64]u8 = undefined;
    const n = try pinned.original.readPositionalAll(io, &bytes, 0);
    try std.testing.expectEqualStrings("original", bytes[0..n]);
    stage.deinit(io);
    closed = true;
    try expectAbsent(pinned.parent(), "flush.tmp");
}
