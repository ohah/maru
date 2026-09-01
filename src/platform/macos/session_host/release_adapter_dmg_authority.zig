//! Release candidate DMG의 pathname, mount, 고정 제품 경로 수명을 한 owner로 묶는다.
//!
//! `hdiutil`에는 caller pathname이 아니라 no-follow source fd에서 만든 private 0600 copy만 준다.
//! Apple 관측이 끝날 때까지 mount와 제품 inode를 재검증하고, 결과를 반환하기 전에 반드시 detach한다.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;
const safe_open = @import("safe_open");
const release_files = @import("release_adapter_files");
const bounded_process = @import("bounded_process");
const apple_product = @import("release_adapter_apple_product");
const apple_transport = @import("release_adapter_apple_transport");
const darwin = @cImport({
    @cInclude("sys/mount.h");
});

pub const max_dmg_bytes = release_files.max_release_asset_bytes;
pub const max_path_bytes: usize = 4 * 1024;
pub const max_args: usize = 7;
pub const cleanup_budget_ns: i128 = 4 * std.time.ns_per_min;
pub const ArgsStorage = [max_args][]const u8;
const command_output_bytes: usize = 16 * 1024;

pub const ExpectedDmg = struct {
    size: u64,
    sha256: [64]u8,
};

pub const MountProbe = struct {
    source_storage: [max_path_bytes]u8 = undefined,
    source_len: usize,
    fsid: [2]i32,
    read_only: bool,

    pub fn init(source_value: []const u8, fsid: [2]i32, read_only: bool) Error!MountProbe {
        if (source_value.len == 0 or source_value.len > max_path_bytes) return error.InvalidDevice;
        var result: MountProbe = .{ .source_len = source_value.len, .fsid = fsid, .read_only = read_only };
        @memcpy(result.source_storage[0..source_value.len], source_value);
        return result;
    }

    pub fn source(self: *const MountProbe) []const u8 {
        return self.source_storage[0..self.source_len];
    }
};

pub const Plan = struct {
    executable: []const u8,
    args: []const []const u8,
};

pub const Error = error{
    InvalidExpected,
    InvalidPath,
    SourceInvalid,
    SourceChanged,
    SourceMismatch,
    CreateFailed,
    CopyFailed,
    SyncFailed,
    AttachFailed,
    NotMounted,
    WritableMount,
    InvalidDevice,
    MountChanged,
    InvalidProduct,
    DetachFailed,
    CleanupFailed,
} || std.mem.Allocator.Error || apple_product.Error;

pub fn validateExpected(expected: ExpectedDmg) Error!void {
    if (expected.size == 0 or expected.size > max_dmg_bytes or !lowerHex(&expected.sha256))
        return error.InvalidExpected;
}

pub fn planAttach(storage: *ArgsStorage, mount_dir: []const u8, private_dmg: []const u8) Error!Plan {
    try absolutePath(mount_dir);
    try absolutePath(private_dmg);
    const values = [_][]const u8{
        "attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount_dir, private_dmg,
    };
    @memcpy(storage[0..values.len], &values);
    return .{ .executable = "/usr/bin/hdiutil", .args = storage[0..values.len] };
}

pub fn planDetach(storage: *ArgsStorage, device: []const u8) Error!Plan {
    if (!validDevice(device)) return error.InvalidDevice;
    return planDetachTarget(storage, device);
}

/// Runs the complete authority lifetime. `ops` owns command execution and mount probing, while the
/// filesystem staging/traversal remains real even in component tests.
pub fn observeWith(
    allocator: std.mem.Allocator,
    io: std.Io,
    ops: anytype,
    apple_runner: anytype,
    candidate_path: [:0]const u8,
    work_path: [:0]const u8,
    expected: ExpectedDmg,
    expected_version: []const u8,
    apple_storage: *apple_transport.Storage,
    budget_ns: i128,
) !apple_product.Observed {
    _ = io;
    try validateExpected(expected);
    if (budget_ns <= 0) return error.InvalidExpected;
    var staged = try Staged.create(candidate_path, work_path, expected);
    var cleanup_needed = true;
    defer if (cleanup_needed) staged.cleanup(false) catch {};

    const baseline = ops.probe(staged.mountPath()) catch return error.NotMounted;
    var args: ArgsStorage = undefined;
    var output: [command_output_bytes]u8 = undefined;
    const attach = try planAttach(&args, staged.mountPath(), staged.privateDmgPath());
    const attach_result = ops.capture(attach.executable, attach.args, &.{}, &output, budget_ns);
    const after_attach = ops.probe(staged.mountPath()) catch {
        if (attach_result) |_| {} else |_| {}
        return error.AttachFailed;
    };
    const changed = !sameFilesystem(baseline, after_attach);
    if (!changed) {
        if (attach_result) |_| {} else |_| return error.AttachFailed;
        return error.NotMounted;
    }
    var device_buf: [max_path_bytes]u8 = undefined;
    if (after_attach.source().len > device_buf.len) return error.InvalidDevice;
    @memcpy(device_buf[0..after_attach.source().len], after_attach.source());
    const device = device_buf[0..after_attach.source().len];
    if (!after_attach.read_only) {
        const detach_target = if (validDevice(device)) device else staged.mountPath();
        detachAndCleanup(ops, &staged, detach_target, baseline, budget_ns) catch |err| return err;
        cleanup_needed = false;
        return error.WritableMount;
    }
    if (!validDevice(device)) {
        detachAndCleanup(ops, &staged, staged.mountPath(), baseline, budget_ns) catch |err| return err;
        cleanup_needed = false;
        return error.InvalidDevice;
    }
    if (attach_result) |_| {} else |_| {
        detachAndCleanup(ops, &staged, device, baseline, budget_ns) catch |err| return err;
        cleanup_needed = false;
        return error.AttachFailed;
    }

    var product = Product.open(staged.mountPath()) catch |err| {
        detachAndCleanup(ops, &staged, device, baseline, budget_ns) catch |cleanup_err| return cleanup_err;
        cleanup_needed = false;
        return err;
    };
    var product_open = true;
    defer if (product_open) product.close();
    const before_apple = ops.probe(staged.mountPath()) catch {
        product.close();
        product_open = false;
        detachAndCleanup(ops, &staged, device, baseline, budget_ns) catch |cleanup_err| return cleanup_err;
        cleanup_needed = false;
        return error.MountChanged;
    };
    if (!sameFilesystem(after_attach, before_apple) or !product.revalidate()) {
        product.close();
        product_open = false;
        detachAndCleanup(ops, &staged, device, baseline, budget_ns) catch |cleanup_err| return cleanup_err;
        cleanup_needed = false;
        return error.MountChanged;
    }
    var executable_digest: [32]u8 = undefined;
    hashFd(product.executable_fd, &executable_digest) catch |err| {
        product.close();
        product_open = false;
        detachAndCleanup(ops, &staged, device, baseline, budget_ns) catch |cleanup_err| return cleanup_err;
        cleanup_needed = false;
        return err;
    };
    const executable_hex: [64]u8 = std.fmt.bytesToHex(executable_digest, .lower);
    var app_path_buf: [max_path_bytes]u8 = undefined;
    var plist_path_buf: [max_path_bytes]u8 = undefined;
    var executable_path_buf: [max_path_bytes]u8 = undefined;
    const app_path = std.fmt.bufPrint(&app_path_buf, "{s}/Maru.app", .{staged.mountPath()}) catch {
        product.close();
        product_open = false;
        detachAndCleanup(ops, &staged, device, baseline, budget_ns) catch |cleanup_err| return cleanup_err;
        cleanup_needed = false;
        return error.InvalidPath;
    };
    const plist_path = std.fmt.bufPrint(&plist_path_buf, "{s}/Maru.app/Contents/Info.plist", .{staged.mountPath()}) catch {
        product.close();
        product_open = false;
        detachAndCleanup(ops, &staged, device, baseline, budget_ns) catch |cleanup_err| return cleanup_err;
        cleanup_needed = false;
        return error.InvalidPath;
    };
    const executable_path = std.fmt.bufPrint(&executable_path_buf, "{s}/Maru.app/Contents/MacOS/maru-macos-app", .{staged.mountPath()}) catch {
        product.close();
        product_open = false;
        detachAndCleanup(ops, &staged, device, baseline, budget_ns) catch |cleanup_err| return cleanup_err;
        cleanup_needed = false;
        return error.InvalidPath;
    };
    const captures = apple_transport.collectWith(
        apple_runner,
        .{
            .app_bundle = app_path,
            .info_plist = plist_path,
            .product_executable = executable_path,
            .dmg = staged.privateDmgPath(),
        },
        &executable_hex,
        apple_storage,
        budget_ns,
    ) catch |err| {
        product.close();
        product_open = false;
        detachAndCleanup(ops, &staged, device, baseline, budget_ns) catch |cleanup_err| return cleanup_err;
        cleanup_needed = false;
        return err;
    };
    const after_apple = ops.probe(staged.mountPath()) catch {
        product.close();
        product_open = false;
        detachAndCleanup(ops, &staged, device, baseline, budget_ns) catch |cleanup_err| return cleanup_err;
        cleanup_needed = false;
        return error.MountChanged;
    };
    if (!sameFilesystem(after_attach, after_apple) or !product.revalidate()) {
        product.close();
        product_open = false;
        detachAndCleanup(ops, &staged, device, baseline, budget_ns) catch return error.DetachFailed;
        cleanup_needed = false;
        return error.MountChanged;
    }
    var observed = apple_product.parseAndBind(allocator, captures, expected_version) catch |err| {
        product.close();
        product_open = false;
        detachAndCleanup(ops, &staged, device, baseline, budget_ns) catch |cleanup_err| return cleanup_err;
        cleanup_needed = false;
        return err;
    };
    errdefer observed.deinit(allocator);
    product.close();
    product_open = false;
    detachAndCleanup(ops, &staged, device, baseline, budget_ns) catch |err| return err;
    cleanup_needed = false;
    return observed;
}

pub fn observe(
    allocator: std.mem.Allocator,
    io: std.Io,
    candidate_path: [:0]const u8,
    work_path: [:0]const u8,
    expected: ExpectedDmg,
    expected_version: []const u8,
    apple_storage: *apple_transport.Storage,
    budget_ns: i128,
) !apple_product.Observed {
    var ops = SystemOps{ .io = io };
    var apple_runner = AppleRunner{ .io = io };
    return observeWith(
        allocator,
        io,
        &ops,
        &apple_runner,
        candidate_path,
        work_path,
        expected,
        expected_version,
        apple_storage,
        budget_ns,
    );
}

/// Runs product-admission commands against one absolute phase deadline. Once a mount exists,
/// detach is the only command allowed to use the separate bounded cleanup reserve.
pub fn observeUntil(
    allocator: std.mem.Allocator,
    io: std.Io,
    candidate_path: [:0]const u8,
    work_path: [:0]const u8,
    expected: ExpectedDmg,
    expected_version: []const u8,
    apple_storage: *apple_transport.Storage,
    deadline: anytype,
) !apple_product.Observed {
    var system = SystemOps{ .io = io };
    var apple_runner = AppleRunner{ .io = io };
    return observeUntilInner(allocator, io, &system, &apple_runner, candidate_path, work_path, expected, expected_version, apple_storage, deadline);
}

pub fn observeUntilWithForTest(
    allocator: std.mem.Allocator,
    io: std.Io,
    ops: anytype,
    apple_runner: anytype,
    candidate_path: [:0]const u8,
    work_path: [:0]const u8,
    expected: ExpectedDmg,
    expected_version: []const u8,
    apple_storage: *apple_transport.Storage,
    deadline: anytype,
) !apple_product.Observed {
    if (!builtin.is_test) @compileError("deadline-aware DMG authority seam is test-only");
    return observeUntilInner(allocator, io, ops, apple_runner, candidate_path, work_path, expected, expected_version, apple_storage, deadline);
}

fn observeUntilInner(
    allocator: std.mem.Allocator,
    io: std.Io,
    ops: anytype,
    apple_runner: anytype,
    candidate_path: [:0]const u8,
    work_path: [:0]const u8,
    expected: ExpectedDmg,
    expected_version: []const u8,
    apple_storage: *apple_transport.Storage,
    deadline: anytype,
) !apple_product.Observed {
    const GuardedOps = struct {
        inner: @TypeOf(ops),
        deadline: @TypeOf(deadline),

        fn capture(self: *@This(), executable: []const u8, args: []const []const u8, environment: []const []const u8, output: []u8, _: i128) ![]const u8 {
            return self.inner.capture(executable, args, environment, output, try self.deadline.remaining());
        }

        fn captureCleanup(self: *@This(), executable: []const u8, args: []const []const u8, environment: []const []const u8, output: []u8, _: i128) ![]const u8 {
            return self.inner.capture(executable, args, environment, output, cleanup_budget_ns);
        }

        fn probe(self: *@This(), path: []const u8) !MountProbe {
            return self.inner.probe(path);
        }
    };
    const GuardedAppleRunner = struct {
        inner: @TypeOf(apple_runner),
        deadline: @TypeOf(deadline),

        pub fn capture(self: *@This(), executable: []const u8, args: []const []const u8, environment: []const []const u8, output: []u8, _: i128) ![]const u8 {
            return self.inner.capture(executable, args, environment, output, try self.deadline.remaining());
        }
    };
    var guarded_ops = GuardedOps{ .inner = ops, .deadline = deadline };
    var guarded_apple = GuardedAppleRunner{ .inner = apple_runner, .deadline = deadline };
    return observeWith(allocator, io, &guarded_ops, &guarded_apple, candidate_path, work_path, expected, expected_version, apple_storage, 1);
}

/// Actual hdiutil/filesystem E2E만 Apple command 의미를 대체한다. 제품 artifact가 이 seam을 호출하면 컴파일을 막는다.
pub fn observeWithAppleRunnerForTest(
    allocator: std.mem.Allocator,
    io: std.Io,
    apple_runner: anytype,
    candidate_path: [:0]const u8,
    work_path: [:0]const u8,
    expected: ExpectedDmg,
    expected_version: []const u8,
    apple_storage: *apple_transport.Storage,
    budget_ns: i128,
) !apple_product.Observed {
    if (!builtin.is_test) @compileError("DMG authority Apple runner seam is test-only");
    var ops = SystemOps{ .io = io };
    return observeWith(
        allocator,
        io,
        &ops,
        apple_runner,
        candidate_path,
        work_path,
        expected,
        expected_version,
        apple_storage,
        budget_ns,
    );
}

const Staged = struct {
    parent_fd: c.fd_t,
    work_fd: c.fd_t,
    source_fd: c.fd_t,
    work_leaf: [std.fs.max_name_bytes:0]u8,
    work_leaf_len: usize,
    work_stat: posix.Stat,
    mount_stat: posix.Stat,
    cleanup_started: bool,
    private_len: usize,
    mount_len: usize,
    private_buf: [max_path_bytes:0]u8,
    mount_buf: [max_path_bytes:0]u8,

    fn create(candidate: [:0]const u8, work: [:0]const u8, expected: ExpectedDmg) Error!Staged {
        try absolutePath(candidate);
        try absolutePath(work);
        const source_fd = safe_open.openAbsoluteNoFollow(candidate, false) catch return error.SourceInvalid;
        errdefer _ = c.close(source_fd);
        var source_before: posix.Stat = undefined;
        if (c.fstat(source_fd, &source_before) != 0 or !posix.S.ISREG(source_before.mode) or
            source_before.size < 0 or @as(u64, @intCast(source_before.size)) != expected.size)
            return error.SourceMismatch;

        const parent = try openParent(work);
        errdefer _ = c.close(parent.fd);
        if (c.mkdirat(parent.fd, parent.leaf().ptr, 0o700) != 0) return error.CreateFailed;
        var work_created = true;
        errdefer {
            if (work_created) _ = c.unlinkat(parent.fd, parent.leaf().ptr, posix.AT.REMOVEDIR);
        }
        const work_fd = c.openat(parent.fd, parent.leaf().ptr, .{
            .ACCMODE = .RDONLY,
            .CLOEXEC = true,
            .DIRECTORY = true,
            .NOFOLLOW = true,
        }, @as(c.mode_t, 0));
        if (work_fd < 0) return error.CreateFailed;
        errdefer _ = c.close(work_fd);
        var work_stat: posix.Stat = undefined;
        if (c.fstat(work_fd, &work_stat) != 0 or !posix.S.ISDIR(work_stat.mode) or
            work_stat.mode & 0o777 != 0o700) return error.CreateFailed;
        if (c.mkdirat(work_fd, "mount", 0o700) != 0) return error.CreateFailed;
        errdefer _ = c.unlinkat(work_fd, "mount", posix.AT.REMOVEDIR);
        var mount_stat: posix.Stat = undefined;
        if (c.fstatat(work_fd, "mount", &mount_stat, posix.AT.SYMLINK_NOFOLLOW) != 0 or
            !posix.S.ISDIR(mount_stat.mode) or mount_stat.mode & 0o777 != 0o700) return error.CreateFailed;
        const private_fd = c.openat(work_fd, "candidate.dmg", .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .EXCL = true,
            .CLOEXEC = true,
            .NOFOLLOW = true,
        }, @as(c.mode_t, 0o600));
        if (private_fd < 0) return error.CreateFailed;
        var private_open = true;
        errdefer {
            if (private_open) _ = c.close(private_fd);
            _ = c.unlinkat(work_fd, "candidate.dmg", 0);
        }
        var digest = std.crypto.hash.sha2.Sha256.init(.{});
        var copied: u64 = 0;
        var buffer: [64 * 1024]u8 = undefined;
        while (copied < expected.size) {
            const wanted: usize = @intCast(@min(buffer.len, expected.size - copied));
            const read_count = c.pread(source_fd, &buffer, wanted, @intCast(copied));
            if (read_count < 0 and posix.errno(-1) == .INTR) continue;
            if (read_count <= 0) return error.CopyFailed;
            const count: usize = @intCast(read_count);
            digest.update(buffer[0..count]);
            var written: usize = 0;
            while (written < count) {
                const n = c.write(private_fd, buffer[written..count].ptr, count - written);
                if (n < 0 and posix.errno(-1) == .INTR) continue;
                if (n <= 0) return error.CopyFailed;
                written += @intCast(n);
            }
            copied += count;
        }
        var extra: [1]u8 = undefined;
        while (true) {
            const extra_count = c.pread(source_fd, &extra, 1, @intCast(copied));
            if (extra_count < 0 and posix.errno(-1) == .INTR) continue;
            if (extra_count != 0) return error.SourceChanged;
            break;
        }
        if (c.fchmod(private_fd, 0o600) != 0 or c.fsync(private_fd) != 0) return error.SyncFailed;
        if (c.close(private_fd) != 0) return error.SyncFailed;
        private_open = false;
        var actual_digest: [32]u8 = undefined;
        digest.final(&actual_digest);
        const actual_hex: [64]u8 = std.fmt.bytesToHex(actual_digest, .lower);
        if (!std.mem.eql(u8, &actual_hex, &expected.sha256)) return error.SourceMismatch;
        var source_after: posix.Stat = undefined;
        if (c.fstat(source_fd, &source_after) != 0 or !sameStat(source_before, source_after))
            return error.SourceChanged;
        var private_stat: posix.Stat = undefined;
        if (c.fstatat(work_fd, "candidate.dmg", &private_stat, posix.AT.SYMLINK_NOFOLLOW) != 0 or
            !posix.S.ISREG(private_stat.mode) or private_stat.mode & 0o777 != 0o600 or
            private_stat.size < 0 or @as(u64, @intCast(private_stat.size)) != expected.size)
            return error.SourceMismatch;
        if (c.fsync(work_fd) != 0 or c.fsync(parent.fd) != 0) return error.SyncFailed;
        var result: Staged = undefined;
        result.parent_fd = parent.fd;
        result.work_fd = work_fd;
        result.source_fd = source_fd;
        result.work_leaf_len = parent.leaf_len;
        @memcpy(result.work_leaf[0..parent.leaf_len], parent.leaf());
        result.work_leaf[parent.leaf_len] = 0;
        result.work_stat = work_stat;
        result.mount_stat = mount_stat;
        result.cleanup_started = false;
        result.private_len = (std.fmt.bufPrintZ(&result.private_buf, "{s}/candidate.dmg", .{work}) catch
            return error.InvalidPath).len;
        result.mount_len = (std.fmt.bufPrintZ(&result.mount_buf, "{s}/mount", .{work}) catch
            return error.InvalidPath).len;
        work_created = false;
        return result;
    }

    fn privateDmgPath(self: *const Staged) [:0]const u8 {
        return self.private_buf[0..self.private_len :0];
    }

    fn mountPath(self: *const Staged) [:0]const u8 {
        return self.mount_buf[0..self.mount_len :0];
    }

    fn cleanup(self: *Staged, require_empty_mount: bool) Error!void {
        _ = require_empty_mount;
        if (self.cleanup_started) return error.CleanupFailed;
        self.cleanup_started = true;
        var failed = false;
        if (c.unlinkat(self.work_fd, "candidate.dmg", 0) != 0) failed = true;
        var mount_now: posix.Stat = undefined;
        if (c.fstatat(self.work_fd, "mount", &mount_now, posix.AT.SYMLINK_NOFOLLOW) != 0 or
            mount_now.dev != self.mount_stat.dev or mount_now.ino != self.mount_stat.ino or
            c.unlinkat(self.work_fd, "mount", posix.AT.REMOVEDIR) != 0) failed = true;
        if (c.fsync(self.work_fd) != 0) failed = true;
        _ = c.close(self.source_fd);
        _ = c.close(self.work_fd);
        var work_now: posix.Stat = undefined;
        if (c.fstatat(self.parent_fd, self.work_leaf[0..self.work_leaf_len :0].ptr, &work_now, posix.AT.SYMLINK_NOFOLLOW) != 0 or
            work_now.dev != self.work_stat.dev or work_now.ino != self.work_stat.ino or
            c.unlinkat(self.parent_fd, self.work_leaf[0..self.work_leaf_len :0].ptr, posix.AT.REMOVEDIR) != 0) failed = true;
        if (c.fsync(self.parent_fd) != 0) failed = true;
        _ = c.close(self.parent_fd);
        if (failed) return error.CleanupFailed;
    }
};

const Product = struct {
    app_fd: c.fd_t,
    plist_fd: c.fd_t,
    executable_fd: c.fd_t,
    app_stat: posix.Stat,
    plist_stat: posix.Stat,
    executable_stat: posix.Stat,
    fn open(mount_path: []const u8) Error!Product {
        var mount_buf: [max_path_bytes:0]u8 = undefined;
        const mount_z = std.fmt.bufPrintZ(&mount_buf, "{s}", .{mount_path}) catch return error.InvalidPath;
        const mount_fd = safe_open.openAbsoluteNoFollow(mount_z, true) catch return error.InvalidProduct;
        defer _ = c.close(mount_fd);
        var root_stat: posix.Stat = undefined;
        if (c.fstat(mount_fd, &root_stat) != 0 or !posix.S.ISDIR(root_stat.mode)) return error.InvalidProduct;
        const app_fd = openDirAt(mount_fd, "Maru.app") catch return error.InvalidProduct;
        errdefer _ = c.close(app_fd);
        const contents_fd = openDirAt(app_fd, "Contents") catch return error.InvalidProduct;
        defer _ = c.close(contents_fd);
        const macos_fd = openDirAt(contents_fd, "MacOS") catch return error.InvalidProduct;
        defer _ = c.close(macos_fd);
        const plist_fd = openFileAt(contents_fd, "Info.plist") catch return error.InvalidProduct;
        errdefer _ = c.close(plist_fd);
        const executable_fd = openFileAt(macos_fd, "maru-macos-app") catch return error.InvalidProduct;
        errdefer _ = c.close(executable_fd);
        var result: Product = undefined;
        result.app_fd = app_fd;
        result.plist_fd = plist_fd;
        result.executable_fd = executable_fd;
        if (c.fstat(app_fd, &result.app_stat) != 0 or c.fstat(plist_fd, &result.plist_stat) != 0 or
            c.fstat(executable_fd, &result.executable_stat) != 0 or
            result.app_stat.dev != root_stat.dev or result.plist_stat.dev != root_stat.dev or
            result.executable_stat.dev != root_stat.dev or result.executable_stat.nlink != 1)
            return error.InvalidProduct;
        return result;
    }

    fn revalidate(self: *const Product) bool {
        var app: posix.Stat = undefined;
        var plist: posix.Stat = undefined;
        var executable: posix.Stat = undefined;
        return c.fstat(self.app_fd, &app) == 0 and c.fstat(self.plist_fd, &plist) == 0 and
            c.fstat(self.executable_fd, &executable) == 0 and sameStat(self.app_stat, app) and
            sameStat(self.plist_stat, plist) and sameStat(self.executable_stat, executable);
    }

    fn close(self: *Product) void {
        _ = c.close(self.executable_fd);
        _ = c.close(self.plist_fd);
        _ = c.close(self.app_fd);
    }
};

fn detachAndCleanup(ops: anytype, staged: *Staged, device: []const u8, baseline: MountProbe, budget_ns: i128) Error!void {
    var args: ArgsStorage = undefined;
    var output: [command_output_bytes]u8 = undefined;
    const detach = try planDetachTarget(&args, device);
    const capture = if (@hasDecl(@TypeOf(ops.*), "captureCleanup"))
        ops.captureCleanup(detach.executable, detach.args, &.{}, &output, budget_ns)
    else
        ops.capture(detach.executable, detach.args, &.{}, &output, budget_ns);
    _ = capture catch return error.DetachFailed;
    const after = ops.probe(staged.mountPath()) catch return error.DetachFailed;
    if (!sameFilesystem(baseline, after)) return error.DetachFailed;
    staged.cleanup(true) catch return error.CleanupFailed;
}

const SystemOps = struct {
    io: std.Io,

    fn capture(self: *@This(), executable: []const u8, args: []const []const u8, environment: []const []const u8, output: []u8, budget_ns: i128) ![]const u8 {
        if (environment.len != 0 or args.len > max_args) return error.InvalidPath;
        var executable_buf: [max_path_bytes + 1]u8 = undefined;
        const executable_z = try sentinel(&executable_buf, executable);
        var arg_bufs: [max_args][max_path_bytes + 1]u8 = undefined;
        var argv: [max_args + 2:null]?[*:0]const u8 = @splat(null);
        argv[0] = executable_z.ptr;
        for (args, 0..) |arg, index| argv[index + 1] = (try sentinel(&arg_bufs[index], arg)).ptr;
        const env = [_:null]?[*:0]const u8{null};
        return bounded_process.runCaptureEnvironment(self.io, executable_z, &argv, &env, output, budget_ns);
    }

    fn probe(_: *@This(), path: []const u8) !MountProbe {
        var path_buf: [max_path_bytes + 1]u8 = undefined;
        const path_z = try sentinel(&path_buf, path);
        var info: darwin.struct_statfs = undefined;
        if (darwin.statfs(path_z.ptr, &info) != 0) return error.NotMounted;
        const source = std.mem.sliceTo(&info.f_mntfromname, 0);
        return MountProbe.init(
            source,
            .{ info.f_fsid.val[0], info.f_fsid.val[1] },
            info.f_flags & darwin.MNT_RDONLY != 0,
        );
    }
};

const AppleRunner = struct {
    io: std.Io,

    // apple_transport owns the generic runner protocol in another module, so
    // the real product wrapper must expose this one protocol method to it.
    pub fn capture(self: *@This(), executable: []const u8, args: []const []const u8, environment: []const []const u8, output: []u8, budget_ns: i128) ![]const u8 {
        var ops = SystemOps{ .io = self.io };
        return ops.capture(executable, args, environment, output, budget_ns);
    }
};

const Parent = struct {
    fd: c.fd_t,
    leaf_len: usize,
    leaf_buf: [std.fs.max_name_bytes:0]u8,

    fn leaf(self: *const Parent) [:0]const u8 {
        return self.leaf_buf[0..self.leaf_len :0];
    }
};

fn openParent(path: [:0]const u8) Error!Parent {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return error.InvalidPath;
    const leaf = path[slash + 1 ..];
    if (leaf.len == 0 or leaf.len > std.fs.max_name_bytes or std.mem.eql(u8, leaf, ".") or std.mem.eql(u8, leaf, ".."))
        return error.InvalidPath;
    var result: Parent = undefined;
    @memcpy(result.leaf_buf[0..leaf.len], leaf);
    result.leaf_buf[leaf.len] = 0;
    result.leaf_len = leaf.len;
    var parent_buf: [max_path_bytes:0]u8 = undefined;
    const parent = if (slash == 0) "/" else std.fmt.bufPrintZ(&parent_buf, "{s}", .{path[0..slash]}) catch return error.InvalidPath;
    result.fd = safe_open.openAbsoluteNoFollow(parent, true) catch return error.InvalidPath;
    return result;
}

fn openDirAt(parent: c.fd_t, leaf: [:0]const u8) !c.fd_t {
    const fd = c.openat(parent, leaf.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .DIRECTORY = true, .NOFOLLOW = true }, @as(c.mode_t, 0));
    if (fd < 0) return error.InvalidProduct;
    return fd;
}

fn openFileAt(parent: c.fd_t, leaf: [:0]const u8) !c.fd_t {
    const fd = c.openat(parent, leaf.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, @as(c.mode_t, 0));
    if (fd < 0) return error.InvalidProduct;
    var stat: posix.Stat = undefined;
    if (c.fstat(fd, &stat) != 0 or !posix.S.ISREG(stat.mode)) {
        _ = c.close(fd);
        return error.InvalidProduct;
    }
    return fd;
}

fn hashFd(fd: c.fd_t, digest: *[32]u8) Error!void {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var offset: usize = 0;
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const count = c.pread(fd, &buffer, buffer.len, @intCast(offset));
        if (count < 0 and posix.errno(-1) == .INTR) continue;
        if (count < 0) return error.InvalidProduct;
        if (count == 0) break;
        const len: usize = @intCast(count);
        hash.update(buffer[0..len]);
        offset += len;
    }
    hash.final(digest);
}

fn sameFilesystem(left: MountProbe, right: MountProbe) bool {
    return left.fsid[0] == right.fsid[0] and left.fsid[1] == right.fsid[1] and
        std.mem.eql(u8, left.source(), right.source()) and left.read_only == right.read_only;
}

fn sameStat(left: posix.Stat, right: posix.Stat) bool {
    return left.dev == right.dev and left.ino == right.ino and left.mode == right.mode and
        left.size == right.size and left.mtimespec.sec == right.mtimespec.sec and
        left.mtimespec.nsec == right.mtimespec.nsec and left.ctimespec.sec == right.ctimespec.sec and
        left.ctimespec.nsec == right.ctimespec.nsec;
}

fn validDevice(device: []const u8) bool {
    if (!std.mem.startsWith(u8, device, "/dev/disk")) return false;
    const suffix = device["/dev/disk".len..];
    if (suffix.len == 0 or !std.ascii.isDigit(suffix[0])) return false;
    var saw_s = false;
    var after_s_digit = false;
    for (suffix) |byte| {
        if (std.ascii.isDigit(byte)) {
            if (saw_s) after_s_digit = true;
        } else if (byte == 's' and !saw_s) {
            saw_s = true;
        } else return false;
    }
    return !saw_s or after_s_digit;
}

fn planDetachTarget(storage: *ArgsStorage, target: []const u8) Error!Plan {
    if (!validDevice(target)) try absolutePath(target);
    const values = [_][]const u8{ "detach", target };
    @memcpy(storage[0..values.len], &values);
    return .{ .executable = "/usr/bin/hdiutil", .args = storage[0..values.len] };
}

fn lowerHex(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |byte| if (!(std.ascii.isDigit(byte) or byte >= 'a' and byte <= 'f')) return false;
    return true;
}

fn absolutePath(path: []const u8) Error!void {
    if (path.len < 2 or path.len > max_path_bytes or path[0] != '/' or
        std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
    for (path) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidPath;
}

fn sentinel(storage: []u8, value: []const u8) Error![:0]const u8 {
    if (value.len == 0 or value.len + 1 > storage.len or std.mem.indexOfScalar(u8, value, 0) != null)
        return error.InvalidPath;
    @memcpy(storage[0..value.len], value);
    storage[value.len] = 0;
    return storage[0..value.len :0];
}
