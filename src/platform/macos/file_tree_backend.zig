//! 파일 패널 트리의 macOS L4 디렉터리 열거 backend.
//!
//! render tick은 `submit`/`takeResult`만 호출하며 둘 다 메모리 queue 조작뿐이다. 실제 open/readdir/stat은
//! detached worker thread에서 실행한다. 요청·완료·in-flight를 모두 bound해 watcher burst가 frame loop나
//! 메모리를 무제한 점유하지 않게 한다(docs/file-panel.md §7).

const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const file_tree = maru.session.file_tree;
const c = std.c;

var test_tmp_counter: std.atomic.Value(u64) = .init(0);

pub const max_inflight: usize = 4;
pub const max_results: usize = 16;

pub const OwnedEntry = struct {
    name: []u8,
    kind: file_tree.Kind,
    identity: file_tree.Identity,
};

pub const Result = struct {
    kind: enum { directory, file_hash } = .directory,
    path: []u8,
    entries: std.ArrayList(OwnedEntry) = .empty,
    file_hash: u64 = 0,
    identity: ?file_tree.Identity = null,
    ok: bool = false,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        for (self.entries.items) |entry| allocator.free(entry.name);
        self.entries.deinit(allocator);
        self.* = undefined;
    }
};

const Job = struct {
    state: *State,
    path: []u8,
    kind: ResultKind,
};

const ResultKind = enum { directory, file_hash };

const State = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    refs: std.atomic.Value(usize) = .init(1), // Backend owner + detached workers
    inflight: usize = 0,
    results: [max_results]Result = undefined,
    results_len: usize = 0,
    shutting_down: bool = false,

    fn release(self: *State) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        std.debug.assert(self.inflight == 0);
        std.debug.assert(self.results_len == 0);
        const allocator = self.allocator;
        allocator.destroy(self);
    }
};

pub const Backend = struct {
    state: ?*State,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !Backend {
        const state = try allocator.create(State);
        state.* = .{ .allocator = allocator, .io = io };
        return .{ .state = state };
    }

    /// true일 때만 path 소유권이 backend로 이동한다. false면 호출자가 tree에 재예약한 뒤 free한다.
    pub fn submit(self: *Backend, path: []u8) bool {
        return self.submitJob(path, .directory);
    }

    pub fn submitFileHash(self: *Backend, path: []u8) bool {
        return self.submitJob(path, .file_hash);
    }

    fn submitJob(self: *Backend, path: []u8, kind: ResultKind) bool {
        const state = self.state orelse return false;
        state.mutex.lockUncancelable(state.io);
        if (state.shutting_down or state.inflight >= max_inflight) {
            state.mutex.unlock(state.io);
            return false;
        }
        state.inflight += 1;
        _ = state.refs.fetchAdd(1, .monotonic);
        state.mutex.unlock(state.io);

        const job = state.allocator.create(Job) catch {
            finishWithoutResult(state);
            return false;
        };
        job.* = .{ .state = state, .path = path, .kind = kind };
        const thread = std.Thread.spawn(.{}, worker, .{job}) catch {
            state.allocator.destroy(job);
            finishWithoutResult(state);
            return false;
        };
        thread.detach();
        return true;
    }

    fn finishWithoutResult(state: *State) void {
        state.mutex.lockUncancelable(state.io);
        state.inflight -= 1;
        state.mutex.unlock(state.io);
        state.release();
    }

    fn worker(job: *Job) void {
        const state = job.state;
        var result = switch (job.kind) {
            .directory => scanDirectory(state.allocator, state.io, job.path),
            .file_hash => hashFile(state.allocator, state.io, job.path),
        };
        state.allocator.destroy(job);

        state.mutex.lockUncancelable(state.io);
        if (!state.shutting_down and state.results_len < max_results) {
            // max_inflight(4) < max_results(16)이고 submit 전마다 frame이 결과를 전부 비우므로 정상 운용에서
            // overflow하지 않는다. 고정 queue를 써서 allocator OOM이 완료 신호를 삼켜 node를 영구 loading으로
            // 남기는 경로 자체를 없앤다.
            state.results[state.results_len] = result;
            state.results_len += 1;
        } else {
            result.deinit(state.allocator);
        }
        state.inflight -= 1;
        state.mutex.unlock(state.io);
        state.release();
    }

    /// 완료 result 하나의 소유권을 호출자에게 넘긴다. frame tick에서 호출해도 syscall은 없다.
    pub fn takeResult(self: *Backend) ?Result {
        const state = self.state orelse return null;
        state.mutex.lockUncancelable(state.io);
        defer state.mutex.unlock(state.io);
        if (state.results_len == 0) return null;
        const result = state.results[0];
        for (state.results[1..state.results_len], 0..) |remaining, i| state.results[i] = remaining;
        state.results_len -= 1;
        return result;
    }

    pub fn deinit(self: *Backend) void {
        const state = self.state orelse return;
        self.state = null;
        state.mutex.lockUncancelable(state.io);
        state.shutting_down = true;
        for (state.results[0..state.results_len]) |*result| result.deinit(state.allocator);
        state.results_len = 0;
        state.mutex.unlock(state.io);
        // worker는 heap State ref를 보유한다. 느리거나 멈춘 FS I/O를 main actor에서 기다리지 않고 마지막 worker가 정리한다.
        state.release();
    }
};

/// 파일을 열 때 한 번만 수행하는 root 결정. 가장 가까운 `.git` file/dir이 있으면 그 ancestor, 없으면 파일 부모다.
/// frame tick에서는 호출하지 않는다.
pub fn projectRootForFile(allocator: std.mem.Allocator, io: std.Io, file_path: []const u8) ![]u8 {
    const parent = std.fs.path.dirname(file_path) orelse return error.InvalidPath;
    var cursor = try allocator.dupe(u8, parent);
    defer allocator.free(cursor);
    while (true) {
        const marker = try std.fs.path.join(allocator, &.{ cursor, ".git" });
        defer allocator.free(marker);
        if (std.Io.Dir.cwd().statFile(io, marker, .{})) |_| return allocator.dupe(u8, cursor) else |_| {}
        const next = std.fs.path.dirname(cursor) orelse break;
        if (std.mem.eql(u8, next, cursor)) break;
        const replacement = try allocator.dupe(u8, next);
        allocator.free(cursor);
        cursor = replacement;
    }
    return allocator.dupe(u8, parent);
}

fn scanDirectory(allocator: std.mem.Allocator, io: std.Io, owned_path: []u8) Result {
    var result = Result{ .path = owned_path };
    var dir = std.Io.Dir.cwd().openDir(io, owned_path, .{ .iterate = true }) catch return result;
    defer dir.close(io);
    const dir_identity = directoryIdentity(io, dir) catch return result;
    result.identity = dir_identity;

    result.entries.ensureTotalCapacity(allocator, file_tree.max_children_per_directory) catch return result;
    var it = dir.iterate();
    while (result.entries.items.len < file_tree.max_children_per_directory) {
        const entry = (it.next(io) catch return result) orelse break;
        if (file_tree.Tree.shouldExcludeName(entry.name) or !std.unicode.utf8ValidateSlice(entry.name)) continue;
        const name = allocator.dupe(u8, entry.name) catch return result;
        const kind = kindForEntry(allocator, io, owned_path, entry.name, entry.kind);
        result.entries.appendAssumeCapacity(.{
            .name = name,
            .kind = kind,
            .identity = .{
                .device = dir_identity.device,
                .inode = @intCast(entry.inode),
                .kind = kindTag(entry.kind),
            },
        });
    }
    result.ok = true;
    return result;
}

fn directoryIdentity(io: std.Io, dir: std.Io.Dir) !file_tree.Identity {
    if (comptime builtin.os.tag == .macos) {
        var stat: std.posix.Stat = undefined;
        if (std.c.fstat(dir.handle, &stat) != 0) return error.StatFailed;
        return identityFromStat(stat);
    }
    const stat = try dir.stat(io);
    return .{ .device = 0, .inode = @intCast(stat.inode), .kind = @intFromEnum(file_tree.IdentityKind.directory) };
}

fn kindTag(kind: std.Io.File.Kind) u8 {
    return @intFromEnum(switch (kind) {
        .file => file_tree.IdentityKind.regular,
        .directory => file_tree.IdentityKind.directory,
        .sym_link => file_tree.IdentityKind.symlink,
        else => file_tree.IdentityKind.other,
    });
}

fn identityFromStat(stat: std.posix.Stat) file_tree.Identity {
    const kind: file_tree.IdentityKind = if (std.posix.S.ISREG(stat.mode))
        .regular
    else if (std.posix.S.ISDIR(stat.mode))
        .directory
    else if (std.posix.S.ISLNK(stat.mode))
        .symlink
    else
        .other;
    return .{
        .device = @intCast(stat.dev),
        .inode = @intCast(stat.ino),
        .kind = @intFromEnum(kind),
    };
}

fn hashFile(allocator: std.mem.Allocator, io: std.Io, owned_path: []u8) Result {
    var result = Result{ .kind = .file_hash, .path = owned_path };
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, owned_path, allocator, .limited(8 * 1024 * 1024)) catch return result;
    defer allocator.free(bytes);
    result.file_hash = std.hash.Wyhash.hash(0, bytes);
    result.ok = true;
    return result;
}

fn kindForEntry(
    allocator: std.mem.Allocator,
    io: std.Io,
    parent: []const u8,
    name: []const u8,
    kind: std.Io.File.Kind,
) file_tree.Kind {
    return switch (kind) {
        .directory => .directory,
        .file => .file,
        .sym_link => blk: {
            const full = std.fs.path.join(allocator, &.{ parent, name }) catch break :blk .symlink_file;
            defer allocator.free(full);
            const followed = std.Io.Dir.cwd().statFile(io, full, .{}) catch break :blk .symlink_file;
            if (followed.kind != .directory) break :blk .symlink_file;
            // lexical expansion 경로의 각 ancestor를 canonicalize해 비교한다. 현재 디렉터리만 비교하면
            // a/to-b -> b, b/to-a -> a 같은 상호 cycle이 materialized-node cap까지 복제될 수 있다.
            var target_real_buf: [std.fs.max_path_bytes]u8 = undefined;
            const target_len = std.Io.Dir.realPathFileAbsolute(io, full, &target_real_buf) catch break :blk .symlink_file;
            const target_real = target_real_buf[0..target_len];
            if (canonicalAncestorContains(io, parent, target_real)) break :blk .symlink_file;
            break :blk .symlink_directory;
        },
        else => .other,
    };
}

fn canonicalAncestorContains(io: std.Io, lexical_parent: []const u8, target_real: []const u8) bool {
    var cursor = lexical_parent;
    while (true) {
        var real_buf: [std.fs.max_path_bytes]u8 = undefined;
        const real_len = std.Io.Dir.realPathFileAbsolute(io, cursor, &real_buf) catch return true;
        if (std.mem.eql(u8, real_buf[0..real_len], target_real)) return true;
        const next = std.fs.path.dirname(cursor) orelse break;
        if (std.mem.eql(u8, next, cursor)) break;
        cursor = next;
    }
    return false;
}

test "file tree backend scans off-model with exclusions and symlink kinds" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "docs", .default_dir);
    try tmp.dir.createDir(io, ".git", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "readme.md", .data = "# hi" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".env", .data = "A=1" });
    try tmp.dir.symLink(io, "docs", "docs-link", .{ .is_directory = true });
    try tmp.dir.symLink(io, ".", "loop", .{ .is_directory = true });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    const owned = try allocator.dupe(u8, root);
    var result = scanDirectory(allocator, io, owned);
    defer result.deinit(allocator);
    try std.testing.expect(result.ok);
    var saw_git = false;
    var saw_env = false;
    var saw_symlink_dir = false;
    var loop_expandable = false;
    for (result.entries.items) |entry| {
        if (std.mem.eql(u8, entry.name, ".git")) saw_git = true;
        if (std.mem.eql(u8, entry.name, ".env")) saw_env = true;
        if (std.mem.eql(u8, entry.name, "docs-link")) saw_symlink_dir = entry.kind == .symlink_directory;
        if (std.mem.eql(u8, entry.name, "loop")) loop_expandable = entry.kind == .symlink_directory;
    }
    try std.testing.expect(!saw_git);
    try std.testing.expect(saw_env);
    try std.testing.expect(saw_symlink_dir);
    try std.testing.expect(!loop_expandable);
}

test "file tree backend chooses nearest git ancestor and otherwise parent" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "repo", .default_dir);
    var repo = try tmp.dir.openDir(io, "repo", .{});
    defer repo.close(io);
    try repo.createDir(io, ".git", .default_dir);
    try repo.createDir(io, "docs", .default_dir);
    try repo.writeFile(io, .{ .sub_path = "docs/readme.md", .data = "# hi" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    const nested_file = try std.fs.path.join(allocator, &.{ root, "repo/docs/readme.md" });
    defer allocator.free(nested_file);

    // std.testing.tmpDir은 저장소의 .zig-cache 아래라 상위 Maru `.git`을 만난다. no-git fallback은
    // 저장소 밖 /tmp에 pid+counter 고유 디렉터리를 만들어 실제 ancestor 부재를 검증한다.
    var plain_root_buf: [256]u8 = undefined;
    const counter = test_tmp_counter.fetchAdd(1, .monotonic);
    const plain_parent = try std.fmt.bufPrintZ(&plain_root_buf, "/tmp/maru-file-tree-{d}-{d}", .{ c.getpid(), counter });
    if (c.mkdir(plain_parent.ptr, 0o700) != 0) return error.Unexpected;
    defer _ = c.rmdir(plain_parent.ptr);
    const plain_file = try std.fs.path.join(allocator, &.{ plain_parent, "page.md" });
    defer allocator.free(plain_file);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = plain_file, .data = "# plain" });
    defer std.Io.Dir.cwd().deleteFile(io, plain_file) catch {};
    const repo_root = try projectRootForFile(allocator, io, nested_file);
    defer allocator.free(repo_root);
    const plain_root = try projectRootForFile(allocator, io, plain_file);
    defer allocator.free(plain_root);
    try std.testing.expectEqualStrings(std.fs.path.dirname(std.fs.path.dirname(nested_file).?).?, repo_root);
    try std.testing.expectEqualStrings(plain_parent, plain_root);
}

test "file tree backend rejects mutual directory symlink cycles" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "a", .default_dir);
    try tmp.dir.createDir(io, "b", .default_dir);
    try tmp.dir.symLink(io, "../b", "a/to-b", .{ .is_directory = true });
    try tmp.dir.symLink(io, "../a", "b/to-a", .{ .is_directory = true });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    const expanded_b = try std.fs.path.join(allocator, &.{ root, "a/to-b" });
    var result = scanDirectory(allocator, io, expanded_b);
    defer result.deinit(allocator);
    try std.testing.expect(result.ok);
    for (result.entries.items) |entry| if (std.mem.eql(u8, entry.name, "to-a")) {
        try std.testing.expectEqual(file_tree.Kind.symlink_file, entry.kind);
        return;
    };
    return error.TestExpectedEqual;
}

test "file tree backend retirement releases owner without waiting for worker generation" {
    const allocator = std.testing.allocator;
    var backend = try Backend.init(allocator, std.testing.io);
    const state = backend.state.?;
    state.inflight = 1;
    _ = state.refs.fetchAdd(1, .monotonic);
    backend.deinit();
    try std.testing.expect(backend.state == null);
    try std.testing.expect(state.shutting_down);
    state.inflight = 0;
    state.release();
}
