//! 파일 패널 트리의 macOS L4 디렉터리 열거 backend.
//!
//! render tick은 `submit`/`takeResult`만 호출하며 둘 다 메모리 queue 조작뿐이다. 실제 open/readdir/stat은
//! detached worker thread에서 실행한다. 요청·완료·in-flight를 모두 bound해 watcher burst가 frame loop나
//! 메모리를 무제한 점유하지 않게 한다(docs/file-panel.md §7).

const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const path_shape = maru.path_shape;
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
    kind: ResultKind = .directory,
    path: []u8,
    entries: std.ArrayList(OwnedEntry) = .empty,
    file_hash: u64 = 0,
    identity: ?file_tree.Identity = null,
    ok: bool = false,
    request_id: u64 = 0,
    expected_root_generation: u64 = 0,
    root_operation: u32 = 0,
    root_validation_round: u8 = 0,
    validated_dir: ?std.Io.Dir = null,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator, io: std.Io) void {
        if (self.validated_dir) |dir| dir.close(io);
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
    request_id: u64 = 0,
    expected_root_generation: u64 = 0,
    root_operation: u32 = 0,
    root_validation_round: u8 = 0,
    validated_dir: ?std.Io.Dir = null,
};

pub const ResultKind = enum { directory, file_hash, root_validation };

pub const ValidatedRoot = struct {
    path: []u8,
    identity: file_tree.Identity,
    dir: ?std.Io.Dir,

    pub fn deinit(self: *ValidatedRoot, allocator: std.mem.Allocator, io: std.Io) void {
        if (self.dir) |dir| dir.close(io);
        allocator.free(self.path);
        self.* = undefined;
    }
};

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
    pub fn submit(self: *Backend, path: []u8, expected_root_generation: u64) bool {
        return self.submitJobMeta(path, .directory, 0, expected_root_generation, 0, 0, null);
    }

    /// Successful root publish transfers its still-open no-follow directory capability to the first
    /// scan. On false the caller retains both path and dir ownership.
    pub fn submitValidatedRootScan(self: *Backend, path: []u8, expected_root_generation: u64, dir: std.Io.Dir) bool {
        return self.submitJobMeta(path, .directory, 0, expected_root_generation, 0, 0, dir);
    }

    pub fn submitFileHash(self: *Backend, path: []u8) bool {
        return self.submitJob(path, .file_hash);
    }

    pub fn submitRootValidation(
        self: *Backend,
        path: []u8,
        request_id: u64,
        expected_root_generation: u64,
        root_operation: u32,
        root_validation_round: u8,
    ) bool {
        return self.submitJobMeta(path, .root_validation, request_id, expected_root_generation, root_operation, root_validation_round, null);
    }

    fn submitJob(self: *Backend, path: []u8, kind: ResultKind) bool {
        return self.submitJobMeta(path, kind, 0, 0, 0, 0, null);
    }

    fn submitJobMeta(
        self: *Backend,
        path: []u8,
        kind: ResultKind,
        request_id: u64,
        expected_root_generation: u64,
        root_operation: u32,
        root_validation_round: u8,
        validated_dir: ?std.Io.Dir,
    ) bool {
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
        job.* = .{
            .state = state,
            .path = path,
            .kind = kind,
            .request_id = request_id,
            .expected_root_generation = expected_root_generation,
            .root_operation = root_operation,
            .root_validation_round = root_validation_round,
            .validated_dir = validated_dir,
        };
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
            .directory => if (job.validated_dir) |dir|
                scanOpenedDirectory(state.allocator, state.io, job.path, dir)
            else
                scanDirectory(state.allocator, state.io, job.path),
            .file_hash => hashFile(state.allocator, state.io, job.path),
            .root_validation => validateRoot(state.allocator, state.io, job.path),
        };
        result.request_id = job.request_id;
        result.expected_root_generation = job.expected_root_generation;
        result.root_operation = job.root_operation;
        result.root_validation_round = job.root_validation_round;
        state.allocator.destroy(job);

        state.mutex.lockUncancelable(state.io);
        if (!state.shutting_down and state.results_len < max_results) {
            // max_inflight(4) < max_results(16)이고 submit 전마다 frame이 결과를 전부 비우므로 정상 운용에서
            // overflow하지 않는다. 고정 queue를 써서 allocator OOM이 완료 신호를 삼켜 node를 영구 loading으로
            // 남기는 경로 자체를 없앤다.
            state.results[state.results_len] = result;
            state.results_len += 1;
        } else {
            result.deinit(state.allocator, state.io);
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

    pub fn isIdleForTest(self: *Backend) bool {
        if (!builtin.is_test) @compileError("isIdleForTest is test-only");
        const state = self.state orelse return true;
        state.mutex.lockUncancelable(state.io);
        defer state.mutex.unlock(state.io);
        return state.inflight == 0 and state.results_len == 0;
    }

    pub fn resultCountForTest(self: *Backend) usize {
        if (!builtin.is_test) @compileError("resultCountForTest is test-only");
        const state = self.state orelse return 0;
        state.mutex.lockUncancelable(state.io);
        defer state.mutex.unlock(state.io);
        return state.results_len;
    }

    pub fn deinit(self: *Backend) void {
        const state = self.state orelse return;
        self.state = null;
        state.mutex.lockUncancelable(state.io);
        state.shutting_down = true;
        for (state.results[0..state.results_len]) |*result| result.deinit(state.allocator, state.io);
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

fn validateRoot(allocator: std.mem.Allocator, io: std.Io, owned_path: []u8) Result {
    var result = Result{ .kind = .root_validation, .path = owned_path };
    const validated = (validateRootSnapshot(allocator, io, owned_path) catch return result) orelse return result;
    allocator.free(result.path);
    result.path = validated.path;
    result.identity = validated.identity;
    result.validated_dir = validated.dir;
    result.ok = true;
    return result;
}

/// Workspace restore uses the same canonical directory+identity policy as the async picker before
/// publishing a replacement session. Invalid/missing/inaccessible roots are explorer-local damage and
/// return null; allocator failure remains transactional and aborts the whole restore.
pub fn validateRootSnapshot(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !?ValidatedRoot {
    return validateRootSnapshotImpl(allocator, io, path, false);
}

fn validateRootSnapshotImpl(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    force_identity_failure: bool,
) !?ValidatedRoot {
    if (path.len == 0 or path.len > std.fs.max_path_bytes or !std.fs.path.isAbsolute(path) or
        !std.unicode.utf8ValidateSlice(path)) return null;
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_len = std.Io.Dir.realPathFileAbsolute(io, path, &real_buf) catch return null;
    var dir = openCanonicalDirectoryNoFollow(io, real_buf[0..real_len]) orelse return null;
    var transferred = false;
    defer if (!transferred) dir.close(io);
    if (builtin.is_test and force_identity_failure) return null;
    const identity = directoryIdentity(io, dir) catch return null;
    if (identity.kind != @intFromEnum(file_tree.IdentityKind.directory)) return null;
    // **입구 정규화**(계약 §5 규칙 1, 입구 Ⓑ = OS API). `realPath` 는 native 를 준다 — Windows 에서는
    // 역슬래시 경로다. 그대로 들고 있으면 이 값을 중립 레이어의 `/` 경로와 비교하는 소비자가 전부
    // 어긋난다. 실측: `openValidatedFileTreeRow` 가 정상 파일에도 null 을 냈다(W8.1) —
    // `std.mem.eql(validated.path, root_path)` 가 native 와 정규화본을 비교하고 있었다.
    const owned_path = try path_shape.normalizeSeparatorsFor(builtin.os.tag, allocator, real_buf[0..real_len]);
    transferred = true;
    return .{ .path = owned_path, .identity = identity, .dir = dir };
}

/// 절대경로를 **한 칸씩** 내려가며 연다 — 매 칸이 `follow_symlinks = false` 다. 중간 어느 칸이든
/// 링크면 거기서 멈춘다(루트 밖으로 새는 것을 막는 규율).
///
/// **루트가 OS 마다 다르다.** POSIX 는 `/` 하나지만 Windows 는 드라이브(`C:/`)와 UNC
/// (`//server/share`)가 각각 루트다. 한때 `openDirAbsolute(io, "/")` 로 시작하고 `path[1..]` 를
/// `/` 로만 잘랐는데 Windows 에서는 **셋 다 틀린다** — 그런 루트가 없고, `D:/x` 는 첫 글자가 `/` 가
/// 아니며, `realPath` 가 주는 것은 native 라 `/` 로만 자르면 통째로 한 조각이 된다.
/// 실측: `validateRootSnapshot` 이 Windows 에서 늘 `null` 이었다(W8.1).
///
/// 루트 접두 판정은 `path_shape.rootPrefixLenFor(os_tag, …)` 가 소유한다 — 순수 함수라 두 갈래가
/// **모든 타깃에서** 테스트된다.
fn openCanonicalDirectoryNoFollow(io: std.Io, absolute_path: []const u8) ?std.Io.Dir {
    const root_len = path_shape.rootPrefixLenFor(builtin.os.tag, absolute_path) orelse return null;
    var current = std.Io.Dir.openDirAbsolute(io, absolute_path[0..root_len], .{ .follow_symlinks = false }) catch return null;
    var transferred = false;
    defer if (!transferred) current.close(io);
    // **구분자 집합을 `path_shape` 에서 받는다.** 여기 `"/" ++ 역슬래시` 를 박으면 POSIX 에서
    // 역슬래시가 든 **하나의 디렉터리 이름**이 두 칸으로 갈린다 — W1.5 가 낸 회귀를 여기서
    // 또 한 번 냈고 적대적 검증이 잡았다. 판정은 `separatorsFor` 가 단일 출처다.
    var it = std.mem.tokenizeAny(u8, absolute_path[root_len..], path_shape.separatorsFor(builtin.os.tag));
    while (it.next()) |component| {
        if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return null;
        const next = current.openDir(io, component, .{ .follow_symlinks = false }) catch return null;
        current.close(io);
        current = next;
    }
    transferred = true;
    return current;
}

pub const ValidatedFileTreeRow = struct {
    file: std.Io.File,

    pub fn deinit(self: *ValidatedFileTreeRow, io: std.Io) void {
        self.file.close(io);
        self.* = undefined;
    }
};

/// Materialized tree row activation is authorized by the exact root and regular-file identities that
/// produced the row. Every parent component and the leaf are opened descriptor-relative without
/// following symlinks; the returned leaf fd remains live through the caller's open transaction.
pub fn openValidatedFileTreeRow(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_path: []const u8,
    expected_root_identity: file_tree.Identity,
    path: []const u8,
    expected_leaf_identity: file_tree.Identity,
) ?ValidatedFileTreeRow {
    if (expected_leaf_identity.kind != @intFromEnum(file_tree.IdentityKind.regular)) return null;
    if (!file_tree.Tree.pathWithinRoot(path, root_path) or std.mem.eql(u8, path, root_path)) return null;
    var validated = (validateRootSnapshot(allocator, io, root_path) catch return null) orelse return null;
    defer validated.deinit(allocator, io);
    if (!std.mem.eql(u8, validated.path, root_path) or !validated.identity.eql(expected_root_identity)) return null;

    var current = validated.dir orelse return null;
    validated.dir = null;
    defer current.close(io);
    // **구분자를 한 바이트로 가정하지 않는다.** 루트가 `/`·`C:/`·`C:/repo/` 처럼 구분자로 끝나면
    // `root_path.len + 1` 이 첫 세그먼트를 먹어 **다른 파일을 연다**(`C:/a/b` → `/b` → `C:/b`).
    // 규칙은 `path_shape.relativeUnderRoot` 가 단일 출처다(계약 §5.2 ⒝).
    const relative = path_shape.relativeUnderRoot(path, root_path) orelse return null;
    const leaf = std.fs.path.basename(relative);
    if (leaf.len == 0 or std.mem.eql(u8, leaf, ".") or std.mem.eql(u8, leaf, "..")) return null;
    if (std.fs.path.dirname(relative)) |parent| {
        var components = std.mem.tokenizeScalar(u8, parent, '/');
        while (components.next()) |component| {
            if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return null;
            const next = current.openDir(io, component, .{ .follow_symlinks = false }) catch return null;
            current.close(io);
            current = next;
        }
    }
    var file = openLeafNoFollow(allocator, io, current, leaf) catch return null;
    var file_transferred = false;
    defer if (!file_transferred) file.close(io);
    const actual = identityOfFile(io, file) catch return null;
    if (!actual.eql(expected_leaf_identity)) return null;
    file_transferred = true;
    return .{ .file = file };
}

/// 열린 디렉터리 핸들 **아래의 리프 하나**를 심볼릭 링크를 따라가지 않고 연다.
///
/// **`NOFOLLOW` 가 이 함수의 존재 이유다.** 부모 순회는 이미 `openDir(.follow_symlinks = false)` 로
/// 내려오는데, 마지막 한 칸만 링크를 따라가면 그 위의 규율이 통째로 무의미해진다 — 루트 밖 파일을
/// 열어 주는 자리가 된다.
///
/// **OS 로 갈린다. macOS 갈래는 한 글자도 안 바꿨다.**
///
/// - **macOS**: `openat` + `O_NONBLOCK`. 그 플래그가 필요한 이유는 **FIFO** 다 — 읽기로 여는 순간
///   쓰는 쪽이 붙을 때까지 **멈춘다**. 리프 종류 검사(`expected_leaf_identity.kind == regular`)는
///   **연 뒤에** 하므로, 그 사이에 멈추면 검사에 닿지도 못한다. 그래서 먼저 검사하고 열 수도 없다
///   (검사와 열기 사이가 갈리는 것이 이 파일이 `*at` 로 피하는 바로 그 경합이다).
/// - **macOS 외**: `std.Io.Dir.openFile`. Windows 에서 `std.posix.openat` 의 플래그 타입이 `void` 라
///   컴파일 자체가 안 된다(W8.1 실측). `follow_symlinks = false` 가 같은 규율을 주고,
///   `allow_directory = false` 는 오히려 한 겹 더 조인다(전에는 디렉터리가 열린 뒤 identity 비교에서
///   걸렸다 — 결과는 같고 syscall 이 하나 준다).
///
/// **`NONBLOCK` 을 못 넘기는 것이 이 갈래의 한계다.** `OpenFileOptions` 에 그 축이 없다. Windows 는
/// 이름 있는 파이프가 파일 트리 경로에 안 나타나므로(`\.\pipe\` 네임스페이스가 따로다) 실질
/// 노출이 없다. Linux 는 지금 컴파일 대상이지 제품 호스트가 아니다 — 거기서 제품을 띄우게 되면
/// 이 자리를 다시 봐야 한다.
fn openLeafNoFollow(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    leaf: []const u8,
) !std.Io.File {
    if (comptime builtin.os.tag != .macos) {
        return dir.openFile(io, leaf, .{
            .mode = .read_only,
            .follow_symlinks = false,
            .allow_directory = false,
        });
    }
    const leaf_z = try allocator.dupeZ(u8, leaf);
    defer allocator.free(leaf_z);
    const fd = try std.posix.openat(dir.handle, leaf_z, .{
        .ACCMODE = .RDONLY,
        .NONBLOCK = true,
        .NOFOLLOW = true,
        .CLOEXEC = true,
    }, 0);
    return .{ .handle = fd, .flags = .{ .nonblocking = true } };
}

fn identityAt(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, leaf: []const u8) !file_tree.Identity {
    if (comptime builtin.os.tag != .macos) {
        const stat = try dir.statFile(io, leaf, .{ .follow_symlinks = false });
        return .{ .device = 0, .inode = @intCast(stat.inode), .kind = kindTag(stat.kind) };
    }
    const leaf_z = try allocator.dupeZ(u8, leaf);
    defer allocator.free(leaf_z);
    var stat: std.posix.Stat = undefined;
    if (std.c.fstatat(dir.handle, leaf_z.ptr, &stat, std.posix.AT.SYMLINK_NOFOLLOW) != 0) return error.StatFailed;
    return identityFromStat(stat);
}

fn identityOfFile(io: std.Io, file: std.Io.File) !file_tree.Identity {
    if (comptime builtin.os.tag == .macos) {
        var stat: std.posix.Stat = undefined;
        if (std.c.fstat(file.handle, &stat) != 0) return error.StatFailed;
        return identityFromStat(stat);
    }
    const stat = try file.stat(io);
    return .{ .device = 0, .inode = @intCast(stat.inode), .kind = kindTag(stat.kind) };
}

fn scanDirectory(allocator: std.mem.Allocator, io: std.Io, owned_path: []u8) Result {
    const result = Result{ .path = owned_path };
    const dir = std.Io.Dir.cwd().openDir(io, owned_path, .{ .iterate = true }) catch return result;
    return scanOpenedDirectory(allocator, io, owned_path, dir);
}

fn scanOpenedDirectory(allocator: std.mem.Allocator, io: std.Io, owned_path: []u8, dir: std.Io.Dir) Result {
    var result = Result{ .path = owned_path };
    var owned_dir = dir;
    defer owned_dir.close(io);
    const dir_identity = directoryIdentity(io, owned_dir) catch return result;
    result.identity = dir_identity;

    result.entries.ensureTotalCapacity(allocator, file_tree.max_children_per_directory) catch return result;
    var it = owned_dir.iterate();
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
    defer result.deinit(allocator, io);
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

test "file tree root validation canonicalizes a directory alias and rejects a regular file" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "actual", .default_dir);
    try tmp.dir.symLink(io, "actual", "alias", .{ .is_directory = true });
    try tmp.dir.writeFile(io, .{ .sub_path = "plain.txt", .data = "not a directory" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    const alias = try std.fs.path.join(allocator, &.{ root, "alias" });
    const actual = try std.fs.path.join(allocator, &.{ root, "actual" });
    defer allocator.free(actual);
    var valid = validateRoot(allocator, io, alias);
    defer valid.deinit(allocator, io);
    try std.testing.expect(valid.ok);
    try std.testing.expectEqualStrings(actual, valid.path);
    try std.testing.expectEqual(@as(u8, @intFromEnum(file_tree.IdentityKind.directory)), valid.identity.?.kind);

    const file = try std.fs.path.join(allocator, &.{ root, "plain.txt" });
    var invalid = validateRoot(allocator, io, file);
    defer invalid.deinit(allocator, io);
    try std.testing.expect(!invalid.ok);
}

fn openFdCountForTest() usize {
    var count: usize = 0;
    for (0..4096) |raw_fd| {
        const fd: c_int = @intCast(raw_fd);
        if (std.c.fcntl(fd, std.c.F.GETFD, @as(c_int, 0)) >= 0) count += 1;
    }
    return count;
}

test "nullable root validation closes descriptors on component and identity failures" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "actual", .default_dir);
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    const missing = try std.fs.path.join(allocator, &.{ root, "actual/missing/child" });
    defer allocator.free(missing);
    const actual = try std.fs.path.join(allocator, &.{ root, "actual" });
    defer allocator.free(actual);

    const before = openFdCountForTest();
    for (0..64) |_| try std.testing.expect(openCanonicalDirectoryNoFollow(io, missing) == null);
    for (0..64) |_| try std.testing.expect((try validateRootSnapshotImpl(allocator, io, actual, true)) == null);
    try std.testing.expectEqual(before, openFdCountForTest());
}

test "validated root directory capability binds the first scan across namespace replacement" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "selected", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "selected/original.md", .data = "old" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    const selected = try std.fs.path.join(allocator, &.{ tmp_root, "selected" });
    defer allocator.free(selected);

    var validated = (try validateRootSnapshot(allocator, io, selected)).?;
    defer validated.deinit(allocator, io);
    const retained_dir = validated.dir.?;
    validated.dir = null;

    try tmp.dir.rename("selected", tmp.dir, "moved", io);
    try tmp.dir.createDir(io, "selected", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "selected/replacement.md", .data = "new" });

    const owned_path = try allocator.dupe(u8, validated.path);
    var result = scanOpenedDirectory(allocator, io, owned_path, retained_dir);
    defer result.deinit(allocator, io);
    try std.testing.expect(result.ok);
    var saw_original = false;
    var saw_replacement = false;
    for (result.entries.items) |entry| {
        if (std.mem.eql(u8, entry.name, "original.md")) saw_original = true;
        if (std.mem.eql(u8, entry.name, "replacement.md")) saw_replacement = true;
    }
    try std.testing.expect(saw_original);
    try std.testing.expect(!saw_replacement);
}

test "validated file tree row capability remains bound across leaf replacement and rejects symlinks" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "root", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "root/same.md", .data = "old" });
    try tmp.dir.symLink(io, "same.md", "root/link.md", .{});
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_root = tmp_buf[0..try tmp.dir.realPath(io, &tmp_buf)];
    const root = try std.fs.path.join(allocator, &.{ tmp_root, "root" });
    defer allocator.free(root);
    const same = try std.fs.path.join(allocator, &.{ root, "same.md" });
    defer allocator.free(same);
    const link = try std.fs.path.join(allocator, &.{ root, "link.md" });
    defer allocator.free(link);

    var validated_root = (try validateRootSnapshot(allocator, io, root)).?;
    defer validated_root.deinit(allocator, io);
    const old_file = try std.Io.Dir.cwd().openFile(io, same, .{ .follow_symlinks = false });
    defer old_file.close(io);
    const old_identity = try identityOfFile(io, old_file);
    var capability = openValidatedFileTreeRow(
        allocator,
        io,
        root,
        validated_root.identity,
        same,
        old_identity,
    ) orelse return error.TestUnexpectedResult;
    defer capability.deinit(io);

    try tmp.dir.rename("root/same.md", tmp.dir, "root/moved.md", io);
    try tmp.dir.writeFile(io, .{ .sub_path = "root/same.md", .data = "new" });
    try std.testing.expect((try identityOfFile(io, capability.file)).eql(old_identity));
    const replacement = try std.Io.Dir.cwd().openFile(io, same, .{ .follow_symlinks = false });
    defer replacement.close(io);
    try std.testing.expect(!(try identityOfFile(io, replacement)).eql(old_identity));

    const link_z = try allocator.dupeZ(u8, link);
    defer allocator.free(link_z);
    var link_stat: std.posix.Stat = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.fstatat(std.posix.AT.FDCWD, link_z.ptr, &link_stat, std.posix.AT.SYMLINK_NOFOLLOW));
    try std.testing.expect(openValidatedFileTreeRow(
        allocator,
        io,
        root,
        validated_root.identity,
        link,
        identityFromStat(link_stat),
    ) == null);
}

// W8.1 — 리프 열기가 **모든 호스트에서** 같은 것을 지키는가.
//
// 위 macOS 전용 테스트와 같은 성질을 보되 `std.posix.Stat`·`fstatat` 을 안 쓴다(Windows 에서
// 그 타입이 없다). 그래서 이 테스트는 **macOS 와 Windows 양쪽에서 돈다.**
//
// **Windows 에서 `NOFOLLOW` 의 의미가 다르다 — 실측했다.** POSIX 는 링크를 만나면 open 자체가
// 실패하는데, Windows 의 `openFile(.follow_symlinks = false)` 는 **링크 자신을 연다**(거부하지
// 않는다). 그래도 가드가 서는 이유는 그 핸들의 identity 가 기대값과 **다르기** 때문이다 —
// 실측: 링크 핸들 inode 3377699722174903 vs 바깥 파일 3940649675596210.
//
// **그래서 identity 비교를 "NOFOLLOW 가 있으니 없어도 된다" 고 지우면 안 된다.** Windows 에서는
// 그 비교가 유일한 방벽이다. 이 테스트가 그 사실을 고정한다.
test "leaf open: 링크로 바꿔치기하면 capability 가 거부된다 (macOS·Windows 공통)" {
    if (builtin.os.tag != .macos and builtin.os.tag != .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "outside.txt", .data = "SECRET-OUTSIDE" });
    try tmp.dir.createDir(io, "root", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "root/leaf.md", .data = "inside" });

    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_root_native = tmp_buf[0..try tmp.dir.realPath(io, &tmp_buf)];
    // 중립 레이어 규약대로 `/` 로 정규화한다(계약 §5 규칙 1) — `pathWithinRoot` 가 그 모양을 본다.
    const tmp_root = try path_shape.normalizeSeparators(allocator, tmp_root_native);
    defer allocator.free(tmp_root);
    // **`std.fs.path.join` 을 쓰지 않는다.** Windows 에서 그것은 **native `\`** 로 잇는다 — 정규화한
    // `D:/…/tmp` 에 붙이면 백슬래시가 섞인 경로가 나오고, 중립 레이어의 `pathWithinRoot`
    // 가 그것을 루트 밖으로 본다(실측: `validateRootSnapshot` 이 null). 계약 §5 가 경고한 모양이
    // 표준 라이브러리 헬퍼에서 나오는 자리다.
    const root = try std.fmt.allocPrint(allocator, "{s}/root", .{tmp_root});
    defer allocator.free(root);
    const leaf = try std.fmt.allocPrint(allocator, "{s}/leaf.md", .{root});
    defer allocator.free(leaf);

    var validated_root = (try validateRootSnapshot(allocator, io, root)) orelse return error.TestUnexpectedResult;
    defer validated_root.deinit(allocator, io);

    const opened = try std.Io.Dir.cwd().openFile(io, leaf, .{ .follow_symlinks = false });
    defer opened.close(io);
    const leaf_identity = try identityOfFile(io, opened);

    // ⓐ 정상 경로 — capability 가 선다.
    var capability = openValidatedFileTreeRow(
        allocator,
        io,
        root,
        validated_root.identity,
        leaf,
        leaf_identity,
    ) orelse return error.TestUnexpectedResult;
    capability.deinit(io);

    // ⓑ 리프를 **루트 밖을 가리키는 링크**로 바꿔치기한다. 만들 수 없는 기기(개발자 모드 꺼짐)면
    //    여기서 멈춘다 — 조용히 통과시키지 않고 건너뛴다는 것을 이름으로 남긴다.
    try tmp.dir.deleteFile(io, "root/leaf.md");
    tmp.dir.symLink(io, "../outside.txt", "root/leaf.md", .{}) catch |e| {
        // **SKIP 은 조용한 통과라 위험하다.** 이 기기가 링크를 못 만들면 이 테스트는 아무것도
        // 검증하지 않는데, 이유가 안 남으면 초록과 구분되지 않는다(Windows 는 개발자 모드나
        // 관리자 권한이 필요하다). 그래서 왜 건너뛰는지 찍고 나간다.
        std.debug.print("[skip] symLink failed ({s}) - symlink guard unverified on this host\n", .{@errorName(e)});
        return error.SkipZigTest;
    };

    // 같은 기대 identity(원래 regular 파일의 것)로 다시 요구하면 **거부되어야** 한다.
    try std.testing.expect(openValidatedFileTreeRow(
        allocator,
        io,
        root,
        validated_root.identity,
        leaf,
        leaf_identity,
    ) == null);
}

// **위 테스트가 "옳은 이유로" 통과하는지 가른다.** 링크로 바꿔치기하면 null 인 것은 맞는데,
// 그 null 이 "링크를 막아서" 인지 "그 전 단계에서 이미 걸려서" 인지 구분되지 않는다.
//
// 그래서 여기서는 **루트 밖 파일의 identity 를 그대로 요구한다.** 링크가 따라가진다면 열린 핸들의
// identity 가 그 바깥 파일과 같아져 **capability 가 선다** — 그것이 곧 유출이다. 서면 안 된다.
test "leaf open: 루트 밖 identity 를 요구해도 링크로는 못 연다" {
    if (builtin.os.tag != .macos and builtin.os.tag != .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "outside.txt", .data = "SECRET" });
    try tmp.dir.createDir(io, "root", .default_dir);

    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const native = tmp_buf[0..try tmp.dir.realPath(io, &tmp_buf)];
    const tmp_root = try path_shape.normalizeSeparators(allocator, native);
    defer allocator.free(tmp_root);
    const root = try std.fmt.allocPrint(allocator, "{s}/root", .{tmp_root});
    defer allocator.free(root);
    const leaf = try std.fmt.allocPrint(allocator, "{s}/escape.txt", .{root});
    defer allocator.free(leaf);

    // root/escape.txt -> ../outside.txt
    tmp.dir.symLink(io, "../outside.txt", "root/escape.txt", .{}) catch |e| {
        // **SKIP 은 조용한 통과라 위험하다.** 이 기기가 링크를 못 만들면 이 테스트는 아무것도
        // 검증하지 않는데, 이유가 안 남으면 초록과 구분되지 않는다(Windows 는 개발자 모드나
        // 관리자 권한이 필요하다). 그래서 왜 건너뛰는지 찍고 나간다.
        std.debug.print("[skip] symLink failed ({s}) - symlink guard unverified on this host\n", .{@errorName(e)});
        return error.SkipZigTest;
    };

    var validated_root = (try validateRootSnapshot(allocator, io, root)) orelse return error.TestUnexpectedResult;
    defer validated_root.deinit(allocator, io);

    // **루트 밖 파일의 identity** — 링크가 따라가지면 이것과 일치해 capability 가 선다.
    const outside = try tmp.dir.openFile(io, "outside.txt", .{ .mode = .read_only });
    defer outside.close(io);
    const outside_identity = try identityOfFile(io, outside);

    try std.testing.expect(openValidatedFileTreeRow(
        allocator,
        io,
        root,
        validated_root.identity,
        leaf,
        outside_identity,
    ) == null);

    // **대조군 — 같은 루트에서 평범한 파일은 정상적으로 선다.** 이게 없으면 위 null 이 "링크를
    // 막아서" 인지 "이 경로가 애초에 아무것도 못 열어서" 인지 갈리지 않는다.
    try tmp.dir.writeFile(io, .{ .sub_path = "root/plain.txt", .data = "inside" });
    const plain = try std.fmt.allocPrint(allocator, "{s}/plain.txt", .{root});
    defer allocator.free(plain);
    const opened = try std.Io.Dir.cwd().openFile(io, plain, .{ .follow_symlinks = false });
    defer opened.close(io);
    var cap = openValidatedFileTreeRow(
        allocator,
        io,
        root,
        validated_root.identity,
        plain,
        try identityOfFile(io, opened),
    ) orelse return error.TestUnexpectedResult;
    cap.deinit(io);
}

extern "kernel32" fn GetCurrentProcess() callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcessHandleCount(process: ?*anyopaque, count: *u32) callconv(.winapi) i32;

fn windowsHandleCount() u32 {
    var n: u32 = 0;
    if (GetProcessHandleCount(GetCurrentProcess(), &n) == 0) return 0;
    return n;
}

// 위 `nullable root validation closes descriptors …` 의 **Windows 쪽 대칭**이다. 그쪽은
// `std.c.fcntl(F.GETFD)` 로 fd 를 세는데 Windows 에 그 축이 없어, 같은 성질이 여기서는 한 번도
// 검증되지 않고 있었다 — 실패 경로에서 디렉터리 핸들 하나가 새면 파일 트리 스캔마다 쌓인다.
//
// `GetProcessHandleCount` 가 이 기기에서 **흔들리지 않는 것**을 먼저 쟀다(무작업 구간 drift 0).
// 그래도 다른 스레드가 핸들을 열 수 있으므로 여유를 둔다 — 200 회에 하나씩만 새도 200 이 느는
// 반면, 여유는 8 이다. "새는가" 와 "잡음" 이 그 간격으로 갈린다.
test "windows: 루트 검증이 실패·성공 어느 쪽에서도 핸들을 안 남긴다" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const rounds = 200;
    const slack = 8;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "root", .default_dir);

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const native = buf[0..try tmp.dir.realPath(io, &buf)];
    const tmp_root = try path_shape.normalizeSeparators(allocator, native);
    defer allocator.free(tmp_root);
    const root = try std.fmt.allocPrint(allocator, "{s}/root", .{tmp_root});
    defer allocator.free(root);
    // 중간 칸이 없는 경로 — `openCanonicalDirectoryNoFollow` 의 실패 경로를 탄다.
    const missing = try std.fmt.allocPrint(allocator, "{s}/no_such_dir/child", .{root});
    defer allocator.free(missing);

    // **macOS 대칭 테스트와 같은 두 갈래를 쓴다.** 처음엔 존재하지 않는 경로로만 돌렸는데,
    // 그것은 `realPath` 에서 먼저 끝나 **핸들을 열지도 않는다** — 실패 경로에서 안 닫도록 고의로
    // 망가뜨려도 이 테스트가 통과했다(적대적 검증이 잡았다). 실제로 여는 갈래는 둘이다:
    // ⓐ 중간 칸이 없는 경로를 `openCanonicalDirectoryNoFollow` 에 **직접** 넣는다(루트는 열린다).
    // ⓑ `validateRootSnapshotImpl(…, force_identity_failure = true)` — 디렉터리를 연 **뒤에** 실패한다.
    const before_a = windowsHandleCount();
    var i: usize = 0;
    while (i < rounds) : (i += 1) try std.testing.expect(openCanonicalDirectoryNoFollow(io, missing) == null);
    try std.testing.expect(windowsHandleCount() <= before_a + slack);

    const before_b = windowsHandleCount();
    i = 0;
    while (i < rounds) : (i += 1) try std.testing.expect((try validateRootSnapshotImpl(allocator, io, root, true)) == null);
    try std.testing.expect(windowsHandleCount() <= before_b + slack);

    // ⓒ 성공 경로도 반복해서 연다 — 열고 닫는 쪽이 새면 여기서 걸린다.
    const before_c = windowsHandleCount();
    i = 0;
    while (i < rounds) : (i += 1) {
        var v = (try validateRootSnapshot(allocator, io, root)) orelse return error.TestUnexpectedResult;
        v.deinit(allocator, io);
    }
    try std.testing.expect(windowsHandleCount() <= before_c + slack);
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
    defer result.deinit(allocator, io);
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
