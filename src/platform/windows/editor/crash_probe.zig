//! Separate-process save durability gate. The parent kills the worker only after
//! a native checkpoint handshake, then independently reads disk and identity.
//! This executable is not installed or called by the app. It proves process
//! termination behavior, not power-loss durability or unsaved-buffer recovery.
const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const editor = maru.session.editor;
const grants = @import("document_grant.zig");
const controller = @import("save_controller.zig");
const backups = @import("backup_store.zig");
const identity = @import("identity.zig");
const w = std.os.windows;
const abi = maru.win32_abi;
extern "kernel32" fn PeekNamedPipe(w.HANDLE, ?*anyopaque, u32, ?*u32, ?*u32, ?*u32) callconv(abi.winapi) w.BOOL;
extern "kernel32" fn WaitForSingleObject(w.HANDLE, u32) callconv(abi.winapi) u32;
extern "kernel32" fn TerminateProcess(w.HANDLE, u32) callconv(abi.winapi) w.BOOL;
extern "kernel32" fn GetExitCodeProcess(w.HANDLE, *u32) callconv(abi.winapi) w.BOOL;
extern "kernel32" fn GetTickCount64() callconv(abi.winapi) u64;
extern "kernel32" fn Sleep(u32) callconv(abi.winapi) void;
extern "kernel32" fn ReOpenFile(w.HANDLE, u32, u32, u32) callconv(abi.winapi) w.HANDLE;
extern "ntdll" fn NtQuerySecurityObject(w.HANDLE, u32, *anyopaque, u32, *u32) callconv(abi.winapi) w.NTSTATUS;

const Checkpoint = enum { opened, partial, prepared, file_closed, committed, settled };
const original = "\xef\xbb\xbforiginal-long-content\r\n";
const bodies = [_][]const u8{ "X\r\n", "replacement-longer-than-the-original-한글\r\n" };
const stream = "separate named stream";
const exit_code = 73;
const deadline_ms = 10_000;

pub fn main(init: std.process.Init) !void {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    const executable = args.next() orelse return error.MissingExecutable;
    if (args.next()) |mode| {
        const backup_worker = std.mem.eql(u8, mode, "backup-worker");
        if (!backup_worker and !std.mem.eql(u8, mode, "worker")) return error.InvalidMode;
        const path = args.next() orelse return error.MissingRoot;
        const checkpoint = std.meta.stringToEnum(Checkpoint, args.next() orelse return error.MissingCheckpoint) orelse return error.InvalidCheckpoint;
        const variant = try std.fmt.parseInt(usize, args.next() orelse return error.MissingVariant, 10);
        if (args.next() != null or variant >= bodies.len) return error.InvalidArguments;
        if (backup_worker) try backupWorker(init, path, bodies[variant]) else try worker(init, path, checkpoint, bodies[variant]);
        return error.WorkerReturned;
    }
    const child_exe = try std.Io.Dir.cwd().realPathFileAlloc(init.io, executable, init.gpa);
    defer init.gpa.free(child_exe);
    var total: usize = 0;
    for (0..bodies.len) |variant| for (std.enums.values(Checkpoint)) |checkpoint| {
        try runOnce(init, child_exe, checkpoint, variant);
        total += 1;
    };
    std.debug.print("win32_save_crash_ok=true killed_processes={d} checkpoints=6 variants=2 identity=true security=true streams=true retry=true\n", .{total});
    for (0..bodies.len) |variant| try runBackupOnce(init, child_exe, variant);
    std.debug.print("win32_backup_crash_ok=true killed_processes=2 recovered_dirty=true original_untouched=true native_save=true external_cas=true\n", .{});
}

fn backupWorker(init: std.process.Init, path: []const u8, body: []const u8) !void {
    var root = try std.Io.Dir.openDirAbsolute(init.io, path, .{});
    defer root.close(init.io);
    var registry: editor.document_registry.Registry = .{ .allocator = init.gpa };
    defer registry.deinit() catch unreachable;
    var opened = try grants.Grant.openExperimental(init.gpa, init.io, root, "file.txt", &registry, 4096);
    defer opened.grant.deinit(init.io);
    defer _ = registry.release(opened.view) catch unreachable;
    try replaceBody(init.gpa, &registry, opened.view, body);
    var store = try backups.Store.open(init.gpa, root, "backups", 4096);
    defer store.deinit(init.io);
    const state = registry.get(opened.view).?;
    try store.write(init.io, .{ .path = .{ .path = opened.grant.path, .disk_hash = state.opened.?.disk_hash } }, state.opened.?.file.content);
    stop(init.io, .prepared);
}

fn runBackupOnce(init: std.process.Init, child_exe: []const u8, variant: usize) !void {
    const a = init.gpa;
    const io = init.io;
    var random: [16]u8 = undefined;
    try io.randomSecure(&random);
    var name_buffer: [128]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buffer, ".zig-cache/win32-backup-crash-{s}", .{std.fmt.bytesToHex(random, .lower)});
    const cwd = std.Io.Dir.cwd();
    try cwd.createDir(io, name, .default_dir);
    defer cwd.deleteDir(io, name) catch unreachable;
    var root = try cwd.openDir(io, name, .{});
    defer root.close(io);
    try root.writeFile(io, .{ .sub_path = "file.txt", .data = original });
    defer root.deleteFile(io, "file.txt") catch unreachable;
    var initial_store = try backups.Store.open(a, root, "backups", 4096);
    initial_store.deinit(io);
    defer root.deleteDir(io, "backups") catch unreachable;
    var root_path: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try root.realPath(io, &root_path);
    const path = try std.fs.path.join(a, &.{ root_path[0..root_len], "file.txt" });
    defer a.free(path);
    const doc: editor.backup.Doc = .{ .path = .{ .path = path, .disk_hash = editor.document_state.contentHash(original) } };
    var record_name: [editor.backup.max_file_name_len]u8 = undefined;
    const cleanup_name = try std.fs.path.join(a, &.{ "backups", editor.backup.fileName(&record_name, doc) });
    defer a.free(cleanup_name);
    defer root.deleteFile(io, cleanup_name) catch |err| {
        if (err != error.FileNotFound) unreachable;
    };
    var variant_buffer: [8]u8 = undefined;
    const variant_text = try std.fmt.bufPrint(&variant_buffer, "{d}", .{variant});
    try killAt(io, &.{ child_exe, "backup-worker", root_path[0..root_len], "prepared", variant_text }, .prepared);
    const untouched = try root.readFileAlloc(io, "file.txt", a, .limited(4096));
    defer a.free(untouched);
    if (!std.mem.eql(u8, original, untouched)) return error.BackupWroteOriginal;
    const external = "\xef\xbb\xbfexternal-after-crash\r\n";
    if (variant == 1) try root.writeFile(io, .{ .sub_path = "file.txt", .data = external });
    var store = try backups.Store.open(a, root, "backups", 4096);
    defer store.deinit(io);
    var record = (try store.read(io, doc)) orelse return error.BackupMissingAfterCrash;
    defer record.deinit();
    if (!std.mem.eql(u8, bodies[variant], record.parsed.content)) return error.BackupBodyMismatch;
    var registry: editor.document_registry.Registry = .{ .allocator = a };
    defer registry.deinit() catch unreachable;
    var opened = try grants.Grant.openExperimental(a, io, root, "file.txt", &registry, 4096);
    defer _ = registry.release(opened.view) catch unreachable;
    var saving = controller.Controller.take(&opened.grant);
    defer saving.deinit(io) catch unreachable;
    var view: editor.view_navigation.View = .{};
    defer view.deinit(a);
    const views = [_]editor.edit_commands.Participant{.{ .view = &view, .id = opened.view.id }};
    const state = registry.get(opened.view).?;
    try backups.restorePath(a, state, &record, &views, 0, 4096);
    if (!state.opened.?.isDirty() or !std.mem.eql(u8, bodies[variant], state.opened.?.file.content) or state.opened.?.disk_hash != doc.path.disk_hash) return error.BackupRestoreMismatch;
    if (variant == 0) {
        try saving.prepare(io, opened.view, 4096);
        const receipt = try saving.commit(io);
        if (receipt.decision != .committed or receipt.acknowledgment_error != null or receipt.cleanup_error != null or state.opened.?.isDirty()) return error.BackupSaveMismatch;
        const expected = try std.mem.concat(a, u8, &.{ "\xef\xbb\xbf", bodies[variant] });
        defer a.free(expected);
        const disk = try root.readFileAlloc(io, "file.txt", a, .limited(4096));
        defer a.free(disk);
        if (!std.mem.eql(u8, expected, disk)) return error.BackupSaveDiskMismatch;
        try store.drop(io, doc);
        if (try store.read(io, doc) != null) return error.BackupNotDropped;
    } else {
        if (saving.prepare(io, opened.view, 4096)) |_| return error.BackupOverwroteExternal else |err| {
            if (err != error.SourceChanged) return err;
        }
        if (saving.status() != .idle or !state.opened.?.isDirty()) return error.BackupConflictStateMismatch;
        var retained = (try store.read(io, doc)) orelse return error.BackupConflictLostRecord;
        defer retained.deinit();
        const disk = try root.readFileAlloc(io, "file.txt", a, .limited(4096));
        defer a.free(disk);
        if (!std.mem.eql(u8, external, disk)) return error.BackupOverwroteExternal;
        // Fixture cleanup only: ordinary conflict handling retains this record.
        try store.drop(io, doc);
    }
    std.debug.print("win32_backup_crash_variant={d} killed=true restored_dirty=true original_untouched=true save_or_conflict=true\n", .{variant});
}

fn killAt(io: std.Io, argv: []const []const u8, checkpoint: Checkpoint) !void {
    var child = try std.process.spawn(io, .{ .argv = argv, .stdin = .close, .stdout = .pipe, .stderr = .inherit });
    defer child.kill(io);
    try waitCheckpoint(&child, checkpoint);
    const handle = child.id orelse return error.MissingChild;
    if (!TerminateProcess(handle, exit_code).toBool()) return error.TerminationFailed;
    if (WaitForSingleObject(handle, deadline_ms) != 0) return error.TerminationTimeout;
    var code: u32 = 0;
    if (!GetExitCodeProcess(handle, &code).toBool() or code != exit_code) return error.WrongExitCode;
    const term = try child.wait(io);
    if (term != .exited or term.exited != exit_code) return error.WrongTermination;
}

fn replaceBody(a: std.mem.Allocator, registry: *editor.document_registry.Registry, lease: editor.document_registry.Lease, body: []const u8) !void {
    const state = registry.get(lease) orelse return error.MissingDocument;
    var view: editor.view_navigation.View = .{};
    defer view.deinit(a);
    try view.move(a, &state.opened.?.file, .select_all, false);
    const participants = [_]editor.edit_commands.Participant{.{ .view = &view, .id = lease.id }};
    _ = try editor.edit_commands.run(a, state, &participants, 0, .{ .insert = body }, .{ .now_ms = 100 });
    if (!state.opened.?.isDirty()) return error.EditNotDirty;
}

fn worker(init: std.process.Init, path: []const u8, checkpoint: Checkpoint, body: []const u8) !void {
    const a = init.gpa;
    const io = init.io;
    var root = try std.Io.Dir.openDirAbsolute(io, path, .{});
    defer root.close(io);
    var registry: editor.document_registry.Registry = .{ .allocator = a };
    defer registry.deinit() catch unreachable;
    var opened = try grants.Grant.openExperimental(a, io, root, "file.txt", &registry, 4096);
    defer _ = registry.release(opened.view) catch unreachable;
    var saving = controller.Controller.take(&opened.grant);
    defer saving.deinit(io) catch unreachable;
    try replaceBody(a, &registry, opened.view, body);
    if (checkpoint == .settled) {
        try saving.prepare(io, opened.view, 4096);
        const receipt = try saving.commit(io);
        if (receipt.decision != .committed or receipt.acknowledgment_error != null or receipt.cleanup_error != null or saving.status() != .idle or registry.get(opened.view).?.opened.?.isDirty()) return error.BadReceipt;
        stop(io, checkpoint);
    }
    var request = try editor.save_request.Request.begin(a, &registry, opened.view, 4096);
    defer request.deinit();
    var attempt = try saving.grant.beginExperimental(io, &request, 4096);
    defer attempt.close(io) catch unreachable;
    const tx = &attempt.transaction;
    if (checkpoint == .opened) stop(io, checkpoint);
    if (checkpoint == .partial) {
        // Real differing bytes and EOF change, deliberately without a complete
        // image or commit permit. TerminateProcess bypasses every Zig defer.
        tx.phase = .poisoned;
        try tx.file.writePositionalAll(io, "partial", 0);
        try tx.file.setLength(io, 7);
        try tx.file.sync(io);
        stop(io, checkpoint);
    }
    try tx.writeDocument(io, &request);
    if (tx.phase != .prepared or try tx.queryOutcome() != .undetermined) return error.BadPreparedCheckpoint;
    if (checkpoint == .prepared) stop(io, checkpoint);
    if (checkpoint == .file_closed) {
        // Commit's handoff window: close the transacted file, but issue no KTM
        // decision. Local uncertainty is never evidence of an on-disk commit.
        tx.file.close(io);
        tx.file_open = false;
        tx.phase = .uncertain;
        if (try tx.queryOutcome() != .undetermined) return error.BadHandoffCheckpoint;
        stop(io, checkpoint);
    }
    try saving.grant.commit(io, &attempt, &request);
    if (tx.phase != .committed or try tx.queryOutcome() != .committed or !registry.get(opened.view).?.opened.?.isDirty()) return error.BadCommittedCheckpoint;
    stop(io, checkpoint);
}

fn stop(io: std.Io, checkpoint: Checkpoint) noreturn {
    var buffer: [32]u8 = undefined;
    var output: std.Io.File.Writer = .init(.stdout(), io, &buffer);
    output.interface.writeByte(@intFromEnum(checkpoint) + 1) catch std.process.exit(74);
    output.interface.flush() catch std.process.exit(74);
    while (true) Sleep(1000);
}

const Metadata = struct {
    id: identity.Identity,
    creation: i64,
    attributes: u32,
    security: [64 * 1024]u8 align(4),
    security_len: usize,
};

fn capture(file: std.Io.File) !Metadata {
    var result: Metadata = undefined;
    result.id = try identity.Identity.capture(file.handle);
    var status: w.IO_STATUS_BLOCK = undefined;
    var basic: w.FILE.BASIC_INFORMATION = undefined;
    if (w.ntdll.NtQueryInformationFile(file.handle, &status, &basic, @sizeOf(@TypeOf(basic)), .Basic) != .SUCCESS) return error.MetadataQueryFailed;
    result.creation = basic.CreationTime;
    result.attributes = @bitCast(basic.FileAttributes);
    const handle = ReOpenFile(file.handle, 0x20000, 7, 0x00200000);
    if (handle == w.INVALID_HANDLE_VALUE) return error.SecurityOpenFailed;
    defer _ = w.ntdll.NtClose(handle);
    var len: u32 = 0;
    // Owner/group/DACL without privilege elevation. Full audit SACL preservation
    // remains independently covered by the native safe-save gate.
    if (NtQuerySecurityObject(handle, 7, &result.security, result.security.len, &len) != .SUCCESS or len < 20 or len > result.security.len) return error.SecurityQueryFailed;
    result.security_len = len;
    return result;
}

fn runOnce(init: std.process.Init, child_exe: []const u8, checkpoint: Checkpoint, variant: usize) !void {
    const io = init.io;
    const a = init.gpa;
    // Exclusive random directory under the gate's cache. Cleanup deletes only
    // our known file (including its ADS) and this empty directory, never a tree.
    var random: [16]u8 = undefined;
    try io.randomSecure(&random);
    var name_buffer: [128]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buffer, ".zig-cache/win32-save-crash-{x}", .{std.fmt.bytesToHex(random, .lower)});
    const cwd = std.Io.Dir.cwd();
    try cwd.createDir(io, name, .default_dir);
    defer cwd.deleteDir(io, name) catch unreachable;
    var root = try cwd.openDir(io, name, .{});
    defer root.close(io);
    try root.writeFile(io, .{ .sub_path = "file.txt", .data = original });
    defer root.deleteFile(io, "file.txt") catch unreachable;
    try root.writeFile(io, .{ .sub_path = "file.txt:keep", .data = stream });
    const before = block: {
        var pinned = try maru.win32_relative_file.open(a, root, "file.txt");
        defer pinned.deinit(io);
        break :block try capture(pinned.original);
    };
    var root_path: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try root.realPath(io, &root_path);
    var variant_buffer: [8]u8 = undefined;
    const variant_text = try std.fmt.bufPrint(&variant_buffer, "{d}", .{variant});
    var child = try std.process.spawn(io, .{ .argv = &.{ child_exe, "worker", root_path[0..root_len], @tagName(checkpoint), variant_text }, .stdin = .close, .stdout = .pipe, .stderr = .inherit });
    defer child.kill(io);
    try waitCheckpoint(&child, checkpoint);
    // TerminateProcess is asynchronous: wait for actual termination before any
    // disk verdict. Microsoft's process termination contract requires waiting
    // for the process object to become signaled, rather than trusting the call.
    // https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-terminateprocess
    const handle = child.id orelse return error.MissingChild;
    if (!TerminateProcess(handle, exit_code).toBool()) return error.TerminationFailed;
    if (WaitForSingleObject(handle, deadline_ms) != 0) return error.TerminationTimeout;
    var code: u32 = 0;
    if (!GetExitCodeProcess(handle, &code).toBool() or code != exit_code) return error.WrongExitCode;
    const term = try child.wait(io);
    if (term != .exited or term.exited != exit_code) return error.WrongTermination;
    const expected = if (checkpoint == .committed or checkpoint == .settled)
        try std.mem.concat(a, u8, &.{ "\xef\xbb\xbf", bodies[variant] })
    else
        try a.dupe(u8, original);
    defer a.free(expected);
    const disk = try root.readFileAlloc(io, "file.txt", a, .limited(4096));
    defer a.free(disk);
    if (!std.mem.eql(u8, expected, disk)) return error.CrashDiskMismatch;
    const ads = try root.readFileAlloc(io, "file.txt:keep", a, .limited(4096));
    defer a.free(ads);
    if (!std.mem.eql(u8, stream, ads)) return error.CrashStreamMismatch;
    {
        var pinned = try maru.win32_relative_file.open(a, root, "file.txt");
        defer pinned.deinit(io);
        const after = try capture(pinned.original);
        if (!before.id.eql(after.id)) return error.CrashIdentityMismatch;
        if (before.creation != after.creation or before.attributes != after.attributes or !std.mem.eql(u8, before.security[0..before.security_len], after.security[0..after.security_len])) return error.CrashMetadataMismatch;
    }
    // Fresh process-state authority must be usable after the dead worker's
    // handles disappear. Prepare/abort proves no lingering writer/parent fence.
    var registry: editor.document_registry.Registry = .{ .allocator = a };
    defer registry.deinit() catch unreachable;
    var opened = try grants.Grant.openExperimental(a, io, root, "file.txt", &registry, 4096);
    defer _ = registry.release(opened.view) catch unreachable;
    var saving = controller.Controller.take(&opened.grant);
    defer saving.deinit(io) catch unreachable;
    if (registry.get(opened.view).?.opened.?.isDirty()) return error.ReopenNotClean;
    try replaceBody(a, &registry, opened.view, "retry\r\n");
    try saving.prepare(io, opened.view, 4096);
    const aborted = try saving.abort(io);
    if (aborted.decision != .aborted or aborted.acknowledgment_error != null or aborted.cleanup_error != null or saving.status() != .idle) return error.RetryFailed;
    const unchanged = try root.readFileAlloc(io, "file.txt", a, .limited(4096));
    defer a.free(unchanged);
    if (!std.mem.eql(u8, expected, unchanged)) return error.RetryChangedDisk;
    std.debug.print("win32_save_crash_checkpoint={s} variant={d} killed=true disk=true metadata=true retry=true\n", .{ @tagName(checkpoint), variant });
}

fn waitCheckpoint(child: *std.process.Child, checkpoint: Checkpoint) !void {
    const handle = child.id orelse return error.MissingChild;
    const pipe = child.stdout orelse return error.MissingPipe;
    const start = GetTickCount64();
    while (GetTickCount64() - start < deadline_ms) {
        var marker: u8 = 0;
        var count: u32 = 0;
        var available: u32 = 0;
        // Anonymous pipe peeking observes availability without consuming or
        // blocking on a worker that never reaches the checkpoint.
        // https://learn.microsoft.com/en-us/windows/win32/api/namedpipeapi/nf-namedpipeapi-peeknamedpipe
        if (!PeekNamedPipe(pipe.handle, &marker, 1, &count, &available, null).toBool()) return error.CheckpointPipeFailed;
        if (available != 0) {
            if (count != 1 or available != 1 or marker != @intFromEnum(checkpoint) + 1 or WaitForSingleObject(handle, 0) != 258) return error.BadCheckpointMarker;
            return;
        }
        if (WaitForSingleObject(handle, 0) != 258) return error.WorkerExitedBeforeCheckpoint;
        Sleep(5);
    }
    return error.CheckpointTimeout;
}
