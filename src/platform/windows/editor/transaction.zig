//! Experimental local NTFS save transaction. Not a production save permit.
//! TxF availability, failed-commit outcome reconciliation and crash recovery must
//! be resolved before GUI adoption. Microsoft recommends alternatives to TxF.
const std = @import("std");
const builtin = @import("builtin");
const w = std.os.windows;
const maru = @import("maru");
const abi = maru.win32_abi;
const identity_mod = @import("identity.zig");
extern "ktmw32" fn CreateTransaction(?*anyopaque, ?*anyopaque, u32, u32, u32, u32, ?[*:0]const u16) callconv(abi.winapi) w.HANDLE;
extern "ktmw32" fn CommitTransaction(w.HANDLE) callconv(abi.winapi) w.BOOL;
extern "ktmw32" fn RollbackTransaction(w.HANDLE) callconv(abi.winapi) w.BOOL;
extern "kernel32" fn CreateFileTransactedW([*:0]const u16, u32, u32, ?*anyopaque, u32, u32, ?w.HANDLE, w.HANDLE, ?*u16, ?*anyopaque) callconv(abi.winapi) w.HANDLE;
extern "kernel32" fn GetFinalPathNameByHandleW(w.HANDLE, [*]u16, u32, u32) callconv(abi.winapi) u32;
extern "kernel32" fn ReOpenFile(w.HANDLE, u32, u32, u32) callconv(abi.winapi) w.HANDLE;
extern "kernel32" fn GetLastError() callconv(abi.winapi) u32;
extern "advapi32" fn LookupPrivilegeValueW(?[*:0]const u16, [*:0]const u16, *Luid) callconv(abi.winapi) w.BOOL;
extern "advapi32" fn AdjustTokenPrivileges(w.HANDLE, w.BOOL, *const Privileges, u32, ?*anyopaque, ?*u32) callconv(abi.winapi) w.BOOL;
extern "advapi32" fn SetFileSecurityW([*:0]const u16, u32, *const anyopaque) callconv(abi.winapi) w.BOOL;
const Luid = extern struct { low: u32, high: i32 };
const Privileges = extern struct { count: u32 = 1, luid: Luid, attributes: u32 };

const Native = struct {
    fn commit(handle: w.HANDLE) bool {
        return CommitTransaction(handle).toBool();
    }
    fn write(file: std.Io.File, io: std.Io, bytes: []const u8) !void {
        try file.writePositionalAll(io, bytes, 0);
        try file.setLength(io, bytes.len);
    }
    fn sync(file: std.Io.File, io: std.Io) !void {
        try file.sync(io);
    }
};

// A volume-GUID path avoids drive-letter remapping. It is only a transport to
// CreateFileTransactedW: pinned parent handles + full ID validation are authority.
// https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-getfinalpathnamebyhandlew
fn transportPath(a: std.mem.Allocator, pinned: *const maru.win32_relative_file.Pinned) ![:0]u16 {
    try maru.win32_relative_file.validateBasename(pinned.basename);
    var parent: [32768]u16 = undefined;
    const n = GetFinalPathNameByHandleW(pinned.parent().handle, &parent, parent.len, 1);
    if (n == 0 or n >= parent.len) return error.PathQueryFailed;
    const name = try std.unicode.utf8ToUtf16LeAlloc(a, pinned.basename);
    defer a.free(name);
    const sep: usize = if (parent[n - 1] == '\\') 0 else 1;
    if (n + sep + name.len >= parent.len) return error.PathTooLong;
    const path = try a.allocSentinel(u16, n + sep + name.len, 0);
    @memcpy(path[0..n], parent[0..n]);
    if (sep != 0) path[n] = '\\';
    @memcpy(path[n + sep ..], name);
    return path;
}

fn standard(handle: w.HANDLE) !w.FILE.STANDARD_INFORMATION {
    var status: w.IO_STATUS_BLOCK = undefined;
    var info: w.FILE.STANDARD_INFORMATION = undefined;
    if (w.ntdll.NtQueryInformationFile(handle, &status, &info, @sizeOf(@TypeOf(info)), .Standard) != .SUCCESS)
        return error.QueryFailed;
    return info;
}

fn checkBinding(a: std.mem.Allocator, io: std.Io, pinned: *const maru.win32_relative_file.Pinned, identity: identity_mod.Identity) !void {
    // An absolute transport can traverse an ancestor whose reparse tag changed.
    // Recheck all pinned objects, then reopen through the actual parent handle.
    // The transaction's write fence already prevents moving the selected leaf.
    for (pinned.directories.items) |directory| {
        var status: w.IO_STATUS_BLOCK = undefined;
        var tag: w.FILE.ATTRIBUTE_TAG_INFO = undefined;
        if (w.ntdll.NtQueryInformationFile(directory, &status, &tag, @sizeOf(@TypeOf(tag)), .AttributeTag) != .SUCCESS)
            return error.QueryFailed;
        if (tag.FileAttributes & 0x400 != 0) return error.NamespaceChanged;
    }
    var binding = try maru.win32_relative_file.open(a, pinned.parent(), pinned.basename);
    defer binding.deinit(io);
    if (!identity.eql(try identity_mod.Identity.capture(binding.original.handle))) return error.NamespaceChanged;
}

fn diskHash(file: std.Io.File, io: std.Io, limit: usize) !u64 {
    const info = try standard(file.handle);
    if (info.Directory.toBool() or info.NumberOfLinks != 1 or info.DeletePending.toBool()) return error.UnsupportedFile;
    if (info.EndOfFile < 0 or info.EndOfFile > limit) return error.FileTooLarge;
    var hash = std.hash.Wyhash.init(0);
    var buffer: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    const size: u64 = @intCast(info.EndOfFile);
    while (offset < size) {
        const count: usize = @intCast(@min(buffer.len, size - offset));
        const n = try file.readPositionalAll(io, buffer[0..count], offset);
        if (n != count) return error.SourceChanged;
        hash.update(buffer[0..n]);
        offset += n;
    }
    return hash.final();
}

pub const Phase = enum { active, prepared, poisoned, uncertain, committed, rolled_back, closed };

pub const Transaction = struct {
    transaction: w.HANDLE,
    file: std.Io.File,
    file_open: bool = true,
    identity: identity_mod.Identity,
    phase: Phase = .active,

    /// Caller keeps every pinned parent alive until close. The original basename,
    /// not the leaf's possibly renamed final path, selects the binding to verify.
    /// No write occurs before the entire file ID and expected raw-byte hash match.
    // https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-createfiletransactedw
    pub fn beginExperimental(a: std.mem.Allocator, io: std.Io, pinned: *const maru.win32_relative_file.Pinned, expected_hash: u64, limit: usize) !Transaction {
        if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
        const expected_id = try identity_mod.Identity.capture(pinned.original.handle);
        const path = try transportPath(a, pinned);
        defer a.free(path);
        const transaction = CreateTransaction(null, null, 0, 0, 0, 0, null);
        if (transaction == w.INVALID_HANDLE_VALUE) return error.TransactionUnavailable;
        errdefer {
            _ = RollbackTransaction(transaction);
            _ = w.ntdll.NtClose(transaction);
        }
        const handle = CreateFileTransactedW(path, 0xc0000000, 7, null, 3, 0x80200000, null, transaction, null, null);
        if (handle == w.INVALID_HANDLE_VALUE) {
            const code = GetLastError();
            if (builtin.is_test) std.debug.print("transaction open error={d}\n", .{code});
            // Sharing violations and native transaction conflicts occur before
            // any data is written; they are a busy source, not a save result.
            if (code == 32 or code == 6800) return error.SourceBusy;
            return error.TransactionOpenFailed;
        }
        errdefer _ = w.ntdll.NtClose(handle);
        const identity = try identity_mod.Identity.capture(handle);
        if (!expected_id.eql(identity)) return error.IdentityChanged;
        const file: std.Io.File = .{ .handle = handle, .flags = .{ .nonblocking = false } };
        try checkBinding(a, io, pinned, identity);
        if (try diskHash(file, io, limit) != expected_hash) return error.SourceChanged;
        return .{ .transaction = transaction, .file = file, .identity = identity };
    }

    pub fn write(self: *Transaction, io: std.Io, bytes: []const u8) !void {
        try self.writeWith(io, bytes, Native);
    }
    fn writeWith(self: *Transaction, io: std.Io, bytes: []const u8, comptime Api: type) !void {
        if (self.phase != .active) return error.InvalidState;
        // Partial writes and failed flushes must never become a commit permit.
        self.phase = .poisoned;
        try Api.write(self.file, io, bytes);
        try Api.sync(self.file, io);
        self.phase = .prepared;
    }

    pub fn commit(self: *Transaction, io: std.Io) !void {
        try self.commitWith(io, Native);
    }
    // A failed request does not prove rollback. Refuse writes/retries/"saved"
    // until a separate native outcome query or confirmed rollback resolves it.
    // https://learn.microsoft.com/en-us/windows/win32/api/ktmw32/nf-ktmw32-committransaction
    fn commitWith(self: *Transaction, io: std.Io, comptime Api: type) !void {
        if (self.phase != .prepared) return error.InvalidState;
        // SDK guidance closes transacted file handles before the request. The
        // transaction itself must keep the write fence across this handoff.
        // https://learn.microsoft.com/en-us/windows/win32/fileio/programming-considerations-for-transacted-fileio-
        self.file.close(io);
        self.file_open = false;
        self.phase = .uncertain;
        if (!Api.commit(self.transaction)) return error.CommitUncertain;
        self.phase = .committed;
    }

    pub fn rollback(self: *Transaction) !void {
        if (self.phase == .committed or self.phase == .rolled_back or self.phase == .closed) return error.InvalidState;
        self.phase = .uncertain;
        if (!RollbackTransaction(self.transaction).toBool()) return error.RollbackUncertain;
        self.phase = .rolled_back;
    }

    /// Close releases both handles even when rollback cannot be confirmed. The
    /// error remains observable: closing is not evidence that a save was undone.
    pub fn close(self: *Transaction, io: std.Io) !void {
        if (self.phase == .closed) return error.InvalidState;
        defer {
            if (self.file_open) self.file.close(io);
            self.file_open = false;
            _ = w.ntdll.NtClose(self.transaction);
            self.phase = .closed;
        }
        if (self.phase != .committed and self.phase != .rolled_back) try self.rollback();
    }
};

fn beginFixture(a: std.mem.Allocator, io: std.Io, pinned: *const maru.win32_relative_file.Pinned) !Transaction {
    return Transaction.beginExperimental(a, io, pinned, maru.session.editor.document_state.contentHash("original-long-content"), 64);
}

test "Windows safe save transaction publishes exact bytes atomically and keeps object ID" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "original.txt", .data = "original-long-content" });
    var pinned = try maru.win32_relative_file.open(std.testing.allocator, tmp.dir, "original.txt");
    defer pinned.deinit(io);
    var tx = try beginFixture(std.testing.allocator, io, &pinned);
    defer tx.close(io) catch @panic("transaction close failed");
    try std.testing.expectError(error.InvalidState, tx.commit(io));
    try tx.write(io, "new");
    var bytes: [64]u8 = undefined;
    try std.testing.expectEqualStrings("original-long-content", bytes[0..try pinned.original.readPositionalAll(io, &bytes, 0)]);
    try tx.commit(io);
    try std.testing.expectEqual(Phase.committed, tx.phase);
    try std.testing.expectEqualStrings("new", bytes[0..try pinned.original.readPositionalAll(io, &bytes, 0)]);
    try std.testing.expect(tx.identity.eql(try identity_mod.Identity.capture(pinned.original.handle)));
    try std.testing.expectError(error.InvalidState, tx.commit(io));
    try std.testing.expectError(error.InvalidState, tx.write(io, "late"));
}

test "Windows safe save transaction rollback and close preserve original data" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    for ([_]bool{ true, false }) |explicit| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(io, .{ .sub_path = "original.txt", .data = "original-long-content" });
        var pinned = try maru.win32_relative_file.open(std.testing.allocator, tmp.dir, "original.txt");
        defer pinned.deinit(io);
        var tx = try beginFixture(std.testing.allocator, io, &pinned);
        try tx.write(io, "uncommitted");
        if (explicit) try tx.rollback();
        try tx.close(io);
        try std.testing.expectEqual(Phase.closed, tx.phase);
        try std.testing.expectError(error.InvalidState, tx.close(io));
        var bytes: [64]u8 = undefined;
        try std.testing.expectEqualStrings("original-long-content", bytes[0..try pinned.original.readPositionalAll(io, &bytes, 0)]);
    }
}

test "Windows safe save transaction rejects a changed disk hash before writing" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "original.txt", .data = "changed externally" });
    var pinned = try maru.win32_relative_file.open(std.testing.allocator, tmp.dir, "original.txt");
    defer pinned.deinit(io);
    if (beginFixture(std.testing.allocator, io, &pinned)) |value| {
        var unexpected = value;
        try unexpected.close(io);
        return error.TestUnexpectedResult;
    } else |err| try std.testing.expectEqual(error.SourceChanged, err);
    var bytes: [64]u8 = undefined;
    try std.testing.expectEqualStrings("changed externally", bytes[0..try pinned.original.readPositionalAll(io, &bytes, 0)]);
}

test "Windows safe save transaction flush failure poisons the commit permit" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "original.txt", .data = "original-long-content" });
    var pinned = try maru.win32_relative_file.open(std.testing.allocator, tmp.dir, "original.txt");
    defer pinned.deinit(io);
    var tx = try beginFixture(std.testing.allocator, io, &pinned);
    defer tx.close(io) catch @panic("transaction close failed");
    const Fault = struct {
        const write = Native.write;
        fn sync(_: std.Io.File, _: std.Io) !void {
            return error.InjectedFlushFailure;
        }
    };
    try std.testing.expectError(error.InjectedFlushFailure, tx.writeWith(io, "partial", Fault));
    try std.testing.expectEqual(Phase.poisoned, tx.phase);
    try std.testing.expectError(error.InvalidState, tx.commit(io));
    try tx.rollback();
    var bytes: [64]u8 = undefined;
    try std.testing.expectEqualStrings("original-long-content", bytes[0..try pinned.original.readPositionalAll(io, &bytes, 0)]);
}

test "Windows safe save transaction failed commit remains uncertain until rollback" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "original.txt", .data = "original-long-content" });
    var pinned = try maru.win32_relative_file.open(std.testing.allocator, tmp.dir, "original.txt");
    defer pinned.deinit(io);
    var tx = try beginFixture(std.testing.allocator, io, &pinned);
    defer tx.close(io) catch @panic("transaction close failed");
    try tx.write(io, "prepared");
    const Fault = struct {
        fn commit(_: w.HANDLE) bool {
            return false;
        }
    };
    try std.testing.expectError(error.CommitUncertain, tx.commitWith(io, Fault));
    try std.testing.expectEqual(Phase.uncertain, tx.phase);
    try std.testing.expectError(error.InvalidState, tx.commit(io));
    try tx.rollback();
    try std.testing.expectEqual(Phase.rolled_back, tx.phase);
}

test "Windows safe save transaction refuses a same-content competitor at the original name" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "original.txt", .data = "original-long-content" });
    var pinned = try maru.win32_relative_file.open(std.testing.allocator, tmp.dir, "original.txt");
    defer pinned.deinit(io);
    try tmp.dir.rename("original.txt", tmp.dir, "moved.txt", io);
    try tmp.dir.writeFile(io, .{ .sub_path = "original.txt", .data = "original-long-content" });
    if (beginFixture(std.testing.allocator, io, &pinned)) |value| {
        var unexpected = value;
        try unexpected.close(io);
        return error.TestUnexpectedResult;
    } else |err| try std.testing.expectEqual(error.IdentityChanged, err);
    var bytes: [64]u8 = undefined;
    try std.testing.expectEqualStrings("original-long-content", bytes[0..try pinned.original.readPositionalAll(io, &bytes, 0)]);
}

test "Windows safe save transaction fences outside writers before the first write" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "original.txt", .data = "original-long-content" });
    var pinned = try maru.win32_relative_file.open(std.testing.allocator, tmp.dir, "original.txt");
    defer pinned.deinit(io);
    var tx = try beginFixture(std.testing.allocator, io, &pinned);
    defer tx.close(io) catch @panic("transaction close failed");
    const other = ReOpenFile(pinned.original.handle, 0x40000000, 7, 0);
    if (other != w.INVALID_HANDLE_VALUE) {
        _ = w.ntdll.NtClose(other);
        return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(@as(u32, 32), GetLastError());
}

test "Windows safe save transaction keeps the write fence after closing its file for commit" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "original.txt", .data = "original-long-content" });
    var pinned = try maru.win32_relative_file.open(std.testing.allocator, tmp.dir, "original.txt");
    defer pinned.deinit(io);
    var tx = try beginFixture(std.testing.allocator, io, &pinned);
    defer tx.close(io) catch @panic("transaction close failed");
    try tx.write(io, "committed");
    const Probe = struct {
        var original: w.HANDLE = undefined;
        var fenced: bool = false;
        fn commit(handle: w.HANDLE) bool {
            const outside = ReOpenFile(original, 0x40000000, 7, 0);
            if (outside != w.INVALID_HANDLE_VALUE) {
                _ = w.ntdll.NtClose(outside);
            } else fenced = GetLastError() == 32;
            return Native.commit(handle);
        }
    };
    Probe.original = pinned.original.handle;
    Probe.fenced = false;
    try tx.commitWith(io, Probe);
    try std.testing.expect(Probe.fenced);
    try std.testing.expect(!tx.file_open);
    var bytes: [64]u8 = undefined;
    try std.testing.expectEqualStrings("committed", bytes[0..try pinned.original.readPositionalAll(io, &bytes, 0)]);
}

fn testBeginAllocation(a: std.mem.Allocator, pinned: *const maru.win32_relative_file.Pinned) !void {
    var tx = try beginFixture(a, std.testing.io, pinned);
    try tx.close(std.testing.io);
}

test "Windows safe save transaction unwinds every transport path allocation failure" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "original.txt", .data = "original-long-content" });
    var pinned = try maru.win32_relative_file.open(std.testing.allocator, tmp.dir, "original.txt");
    defer pinned.deinit(io);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testBeginAllocation, .{&pinned});
}

test "Windows safe save transaction rejects transport namespace mutation and explicit read limit" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "original.txt", .data = "original-long-content" });
    try tmp.dir.writeFile(io, .{ .sub_path = "original.txt:alias", .data = "original-long-content" });
    var pinned = try maru.win32_relative_file.open(std.testing.allocator, tmp.dir, "original.txt");
    defer pinned.deinit(io);
    if (Transaction.beginExperimental(std.testing.allocator, io, &pinned, maru.session.editor.document_state.contentHash("original-long-content"), 2)) |value| {
        var unexpected = value;
        try unexpected.close(io);
        return error.TestUnexpectedResult;
    } else |err| try std.testing.expectEqual(error.FileTooLarge, err);
    const original_name = pinned.basename;
    pinned.basename = try std.testing.allocator.dupe(u8, "original.txt:alias");
    defer {
        std.testing.allocator.free(pinned.basename);
        pinned.basename = original_name;
    }
    if (beginFixture(std.testing.allocator, io, &pinned)) |value| {
        var unexpected = value;
        try unexpected.close(io);
        return error.TestUnexpectedResult;
    } else |err| try std.testing.expectEqual(error.InvalidPath, err);
}

fn testAuditPrivilege(token: w.HANDLE, enabled: bool) !void {
    var luid: Luid = undefined;
    if (!LookupPrivilegeValueW(null, std.unicode.utf8ToUtf16LeStringLiteral("SeSecurityPrivilege"), &luid).toBool()) return error.PrivilegeFailed;
    const privileges: Privileges = .{ .luid = luid, .attributes = if (enabled) 2 else 0 };
    if (!AdjustTokenPrivileges(token, .FALSE, &privileges, 0, null, null).toBool() or GetLastError() != 0) return error.PrivilegeFailed;
}

test "Windows safe save transaction preserves protected audit metadata with audit privilege disabled" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var scope = @import("audit_scope.zig").Scope.enter() catch |err| switch (err) {
        error.Unavailable => return error.SkipZigTest,
        else => return err,
    };
    defer scope.leave() catch @panic("audit token restoration failed");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "original.txt", .data = "original-long-content" });
    try tmp.dir.writeFile(io, .{ .sub_path = "original.txt:keep", .data = "named stream" });
    var pinned = try maru.win32_relative_file.open(a, tmp.dir, "original.txt");
    defer pinned.deinit(io);
    // Self-relative protected SACL with success/failure read auditing for Everyone.
    var sd: [48]u8 align(4) = @splat(0);
    sd[0] = 1;
    std.mem.writeInt(u16, sd[2..4], 0xa010, .little);
    std.mem.writeInt(u32, sd[12..16], 20, .little);
    sd[20] = 2;
    std.mem.writeInt(u16, sd[22..24], 28, .little);
    std.mem.writeInt(u16, sd[24..26], 1, .little);
    sd[28] = 2;
    sd[29] = 0xc0;
    std.mem.writeInt(u16, sd[30..32], 20, .little);
    std.mem.writeInt(u32, sd[32..36], 1, .little);
    sd[36] = 1;
    sd[37] = 1;
    sd[43] = 1;
    const fixture_path = try transportPath(a, &pinned);
    defer a.free(fixture_path);
    if (!SetFileSecurityW(fixture_path, 0x40000008, &sd).toBool()) return error.AuditSetFailed;
    const security = @import("security.zig");
    var before = try security.Snapshot.capture(a, pinned.original);
    var before_live = true;
    defer if (before_live) before.deinit();
    if (beginFixture(a, io, &pinned)) |value| {
        var unexpected = value;
        try unexpected.close(io);
        return error.TestUnexpectedResult;
    } else |err| try std.testing.expectEqual(error.SourceBusy, err);
    // Snapshot intentionally retains a backup-intent authority handle. TxF
    // refuses that concurrent authority (6800); keep only its owned bytes here.
    const before_bytes = try a.dupe(u8, before.bytes);
    before.deinit();
    before_live = false;
    defer a.free(before_bytes);
    // Disable only Scope's duplicate, including on a host whose primary token
    // already enables the privilege. The production transaction adjusts no token.
    try testAuditPrivilege(scope.duplicate, false);
    if (security.Snapshot.capture(a, pinned.original)) |value| {
        var unexpected = value;
        unexpected.deinit();
        return error.TestUnexpectedResult;
    } else |err| try std.testing.expectEqual(error.SecurityUnavailable, err);
    var tx = try beginFixture(a, io, &pinned);
    defer tx.close(io) catch @panic("transaction close failed");
    try tx.write(io, "new");
    try tx.commit(io);
    try testAuditPrivilege(scope.duplicate, true);
    var after = try security.Snapshot.capture(a, pinned.original);
    defer after.deinit();
    try std.testing.expectEqualSlices(u8, before_bytes, after.bytes);
    const stream = try tmp.dir.readFileAlloc(io, "original.txt:keep", a, .limited(64));
    defer a.free(stream);
    try std.testing.expectEqualStrings("named stream", stream);
    std.debug.print("native transaction: audit query denied during write; full security and ADS preserved\n", .{});
}
