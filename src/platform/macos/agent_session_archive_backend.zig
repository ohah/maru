//! Codex·Claude session archive의 macOS worker backend.
//!
//! AppSession frame tick은 submit/takeResult만 호출한다. provider history는 사용자 데이터이므로 worker가
//! 만든 summary 외 raw JSONL은 main actor로 넘기지 않는다.

const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const archive = maru.session.agent_session_archive;

pub const max_candidates_per_provider: usize = 4096;
pub const max_records: usize = 500;
/// The archive itself displays at most 500 verified records, so retaining more
/// parse summaries would increase lookup cost without improving a refresh.
pub const max_cache_entries: usize = max_records;
pub const max_file_bytes: usize = 128 * 1024 * 1024;
/// 한 refresh가 사용자 history를 전부 다시 해석해 UI를 장시간 막지 않게 하는 누적 read 상한.
pub const max_total_bytes: usize = 512 * 1024 * 1024;

pub const Record = struct {
    parsed: archive.Parsed,
    /// Absolute provider-log pathname kept only in the in-process snapshot.
    /// It is paired with the discovery identity so a later explicit reveal can
    /// reject a replacement instead of opening an arbitrary new file.
    source_path: []u8,
    mtime_ns: i96,
    inode: std.Io.File.INode,
    device: u64,

    pub fn deinit(self: *Record, allocator: std.mem.Allocator) void {
        self.parsed.deinit(allocator);
        allocator.free(self.source_path);
        self.* = undefined;
    }
};

pub const Result = struct {
    records: std.ArrayList(Record) = .empty,
    partial: bool = false,
    /// Each worker job publishes exactly one completed immutable snapshot. It
    /// lets the UI retain its prior list while a refresh scans privately.
    complete: bool = false,
    /// The worker completed but could not enqueue an immutable replacement
    /// (for example because the result queue allocation failed). The main
    /// actor must clear its spinner yet retain the prior completed snapshot.
    retain_previous: bool = false,
    /// A cancelled generation is never allowed to replace the visible snapshot. The host uses
    /// this truthful completion to clear its spinner and, if the dock was reopened, request the
    /// newest generation after this worker has released its descriptors and allocations.
    cancelled: bool = false,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        for (self.records.items) |*record| record.deinit(allocator);
        self.records.deinit(allocator);
        self.* = undefined;
    }
};

const State = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    refs: std.atomic.Value(usize) = .init(1),
    results: std.ArrayList(Result) = .empty,
    cache: std.ArrayList(CacheEntry) = .empty,
    inflight: bool = false,
    inflight_generation: u64 = 0,
    next_generation: u64 = 1,
    cancelled_generation: u64 = 0,
    completion_without_snapshot: bool = false,
    completion_cancelled: bool = false,
    shutting_down: bool = false,
    // Production never arms this. The dedicated AppKit archive fixture uses the gate to hold a
    // refresh before discovery so it can replace the old source between a real pointer down and
    // the immutable replacement publication. The worker owns the wait; the main actor continues
    // rendering the retained snapshot throughout.
    test_gate_enabled: std.atomic.Value(bool) = .init(false),
    test_gate_reached: std.atomic.Value(bool) = .init(false),
    test_gate_released: std.atomic.Value(bool) = .init(true),

    fn release(self: *State) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        std.debug.assert(!self.inflight);
        std.debug.assert(self.results.items.len == 0);
        self.results.deinit(self.allocator);
        for (self.cache.items) |*entry| entry.deinit(self.allocator);
        self.cache.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

const Job = struct { state: *State, home: []u8, generation: u64 };

/// A bounded, metadata-only candidate.  We collect these before reading JSONL so
/// traversal order cannot make an old, large transcript spend the refresh budget
/// ahead of a newer session.
const Candidate = struct {
    provider: archive.Provider,
    open_path: []u8,
    source_path: []u8,
    mtime_ns: i96,
    size: usize,
    inode: std.Io.File.INode,
    device: u64,

    fn deinit(self: *Candidate, allocator: std.mem.Allocator) void {
        allocator.free(self.open_path);
        allocator.free(self.source_path);
        self.* = undefined;
    }
};

/// Process-lifetime only: an identical provider, path, device, inode, mtime,
/// and size can reuse the already-redacted summary, but never writes history
/// metadata to disk.
const CacheEntry = struct {
    provider: archive.Provider,
    source_path: []u8,
    mtime_ns: i96,
    size: usize,
    inode: std.Io.File.INode,
    device: u64,
    parsed: archive.Parsed,

    fn deinit(self: *CacheEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.source_path);
        self.parsed.deinit(allocator);
        self.* = undefined;
    }
};

pub const Backend = struct {
    state: ?*State,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !Backend {
        const state = try allocator.create(State);
        state.* = .{ .allocator = allocator, .io = io };
        return .{ .state = state };
    }

    /// caller owns home on false; worker owns it on true.
    pub fn submit(self: *Backend, home: []u8) bool {
        const state = self.state orelse return false;
        state.mutex.lockUncancelable(state.io);
        if (state.shutting_down or state.inflight) {
            state.mutex.unlock(state.io);
            return false;
        }
        state.inflight = true;
        const generation = state.next_generation;
        state.next_generation +%= 1;
        if (state.next_generation == 0) state.next_generation = 1;
        state.inflight_generation = generation;
        state.completion_without_snapshot = false;
        state.completion_cancelled = false;
        _ = state.refs.fetchAdd(1, .monotonic);
        state.mutex.unlock(state.io);

        const job = state.allocator.create(Job) catch {
            finishWithoutResult(state);
            return false;
        };
        job.* = .{ .state = state, .home = home, .generation = generation };
        const thread = std.Thread.spawn(.{}, worker, .{job}) catch {
            state.allocator.destroy(job);
            finishWithoutResult(state);
            return false;
        };
        thread.detach();
        return true;
    }

    /// Cooperative only: filesystem calls already in progress are allowed to return, but every
    /// later candidate/file boundary observes this generation and discards its staged result.
    /// The caller retains the current completed snapshot; it never receives an empty replacement.
    pub fn cancel(self: *Backend) bool {
        const state = self.state orelse return false;
        state.mutex.lockUncancelable(state.io);
        defer state.mutex.unlock(state.io);
        if (!state.inflight or state.cancelled_generation == state.inflight_generation) return false;
        state.cancelled_generation = state.inflight_generation;
        return true;
    }

    /// Test-only synchronization for the isolated AppKit archive fixture. A caller must arm it
    /// before the ordinary refresh input submits a worker; no environment/config path enables it.
    pub fn setTestGate(self: *Backend, blocked: bool) void {
        const state = self.state orelse return;
        state.test_gate_reached.store(false, .release);
        state.test_gate_released.store(!blocked, .release);
        state.test_gate_enabled.store(blocked, .release);
    }

    pub fn testGateReached(self: *const Backend) bool {
        const state = self.state orelse return false;
        return state.test_gate_reached.load(.acquire);
    }

    pub fn takeResult(self: *Backend) ?Result {
        const state = self.state orelse return null;
        state.mutex.lockUncancelable(state.io);
        defer state.mutex.unlock(state.io);
        if (state.results.items.len == 0) {
            if (!state.completion_without_snapshot) return null;
            state.completion_without_snapshot = false;
            return .{ .complete = true, .retain_previous = true, .cancelled = state.completion_cancelled };
        }
        return state.results.orderedRemove(0);
    }

    pub fn deinit(self: *Backend) void {
        const state = self.state orelse return;
        self.state = null;
        state.mutex.lockUncancelable(state.io);
        state.shutting_down = true;
        state.cancelled_generation = state.inflight_generation;
        for (state.results.items) |*result| result.deinit(state.allocator);
        state.results.deinit(state.allocator);
        state.results = .empty;
        for (state.cache.items) |*entry| entry.deinit(state.allocator);
        state.cache.deinit(state.allocator);
        state.cache = .empty;
        state.mutex.unlock(state.io);
        state.release();
    }
};

fn finishWithoutResult(state: *State) void {
    state.mutex.lockUncancelable(state.io);
    state.inflight = false;
    state.inflight_generation = 0;
    state.completion_without_snapshot = true;
    state.completion_cancelled = false;
    state.mutex.unlock(state.io);
    state.release();
}

fn worker(job: *Job) void {
    const state = job.state;
    const generation = job.generation;
    waitForTestGate(state, generation);
    const published = scan(state, job.home, generation);
    state.allocator.free(job.home);
    state.allocator.destroy(job);

    state.mutex.lockUncancelable(state.io);
    state.inflight = false;
    state.inflight_generation = 0;
    const was_cancelled = state.cancelled_generation == generation;
    if (!published and !state.shutting_down) {
        state.completion_without_snapshot = true;
        state.completion_cancelled = was_cancelled;
    }
    state.mutex.unlock(state.io);
    state.release();
}

fn waitForTestGate(state: *State, generation: u64) void {
    if (!state.test_gate_enabled.load(.acquire)) return;
    state.test_gate_reached.store(true, .release);
    while (!state.test_gate_released.load(.acquire)) {
        if (cancelled(state, generation)) break;
        // This is a detached scanner only. The main actor keeps the completed list and can
        // release the gate without waiting for filesystem discovery or JSON parsing.
        std.Io.sleep(state.io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }
    state.test_gate_reached.store(false, .release);
}

fn publish(state: *State, generation: u64, result: *Result) bool {
    state.mutex.lockUncancelable(state.io);
    defer state.mutex.unlock(state.io);
    if (state.shutting_down or state.cancelled_generation == generation) {
        result.deinit(state.allocator);
        return false;
    }
    state.results.append(state.allocator, result.*) catch {
        result.deinit(state.allocator);
        return false;
    };
    result.* = .{};
    return true;
}

fn cachedRecord(state: *State, candidate: Candidate) ?Record {
    state.mutex.lockUncancelable(state.io);
    defer state.mutex.unlock(state.io);
    if (state.shutting_down) return null;
    for (state.cache.items) |entry| {
        if (!sameCacheIdentity(entry, candidate)) continue;
        const parsed = entry.parsed.clone(state.allocator) catch return null;
        const path = state.allocator.dupe(u8, candidate.open_path) catch {
            var owned = parsed;
            owned.deinit(state.allocator);
            return null;
        };
        return .{ .parsed = parsed, .source_path = path, .mtime_ns = candidate.mtime_ns, .inode = candidate.inode, .device = candidate.device };
    }
    return null;
}

fn sameCacheIdentity(entry: CacheEntry, candidate: Candidate) bool {
    return entry.provider == candidate.provider and
        entry.device == candidate.device and
        entry.inode == candidate.inode and
        entry.mtime_ns == candidate.mtime_ns and
        entry.size == candidate.size and
        std.mem.eql(u8, entry.source_path, candidate.source_path);
}

fn cacheParsed(state: *State, candidate: Candidate, parsed: *const archive.Parsed) void {
    const parsed_copy = parsed.clone(state.allocator) catch return;
    const path = state.allocator.dupe(u8, candidate.source_path) catch {
        var owned = parsed_copy;
        owned.deinit(state.allocator);
        return;
    };
    state.mutex.lockUncancelable(state.io);
    defer state.mutex.unlock(state.io);
    if (state.shutting_down) {
        state.allocator.free(path);
        var owned = parsed_copy;
        owned.deinit(state.allocator);
        return;
    }
    var index: usize = 0;
    while (index < state.cache.items.len) {
        const entry = state.cache.items[index];
        if (entry.provider == candidate.provider and std.mem.eql(u8, entry.source_path, candidate.source_path)) {
            var stale = state.cache.orderedRemove(index);
            stale.deinit(state.allocator);
        } else index += 1;
    }
    if (state.cache.items.len == max_cache_entries) {
        // A cache miss must never turn a bounded scan into an unbounded
        // process-lifetime metadata store. Existing warm entries remain valid.
        state.allocator.free(path);
        var owned = parsed_copy;
        owned.deinit(state.allocator);
        return;
    }
    state.cache.append(state.allocator, .{ .provider = candidate.provider, .source_path = path, .mtime_ns = candidate.mtime_ns, .size = candidate.size, .inode = candidate.inode, .device = candidate.device, .parsed = parsed_copy }) catch {
        state.allocator.free(path);
        var owned = parsed_copy;
        owned.deinit(state.allocator);
    };
}

fn scan(state: *State, home: []const u8, generation: u64) bool {
    const allocator = state.allocator;
    const io = state.io;
    var result: Result = .{};
    errdefer result.deinit(allocator);
    var claude_candidates: std.ArrayList(Candidate) = .empty;
    defer {
        for (claude_candidates.items) |*candidate| candidate.deinit(allocator);
        claude_candidates.deinit(allocator);
    }
    var codex_candidates: std.ArrayList(Candidate) = .empty;
    defer {
        for (codex_candidates.items) |*candidate| candidate.deinit(allocator);
        codex_candidates.deinit(allocator);
    }

    scanClaude(allocator, io, home, &claude_candidates, &result.partial);
    if (cancelled(state, generation)) return false;
    scanCodex(allocator, io, home, &codex_candidates, &result.partial);
    if (cancelled(state, generation)) return false;
    claude_candidates.appendSlice(allocator, codex_candidates.items) catch return false;
    codex_candidates.clearRetainingCapacity(); // ownership moved into claude_candidates
    std.mem.sort(Candidate, claude_candidates.items, {}, struct {
        fn lessThan(_: void, a: Candidate, b: Candidate) bool {
            return a.mtime_ns > b.mtime_ns;
        }
    }.lessThan);

    var remaining_bytes = max_total_bytes;
    for (claude_candidates.items) |candidate| {
        if (cancelled(state, generation)) return false;
        if (result.records.items.len == max_records) {
            result.partial = true;
            break;
        }
        if (cachedRecord(state, candidate)) |record| {
            result.records.append(allocator, record) catch {
                var owned = record;
                owned.deinit(allocator);
            };
        } else appendCandidateFile(state, candidate, generation, &result, &remaining_bytes);
    }
    std.mem.sort(Record, result.records.items, {}, struct {
        fn lessThan(_: void, a: Record, b: Record) bool {
            return a.mtime_ns > b.mtime_ns;
        }
    }.lessThan);
    if (result.records.items.len > max_records) {
        for (result.records.items[max_records..]) |*record| record.deinit(allocator);
        result.records.shrinkRetainingCapacity(max_records);
        result.partial = true;
    }
    result.complete = true;
    if (cancelled(state, generation)) return false;
    return publish(state, generation, &result);
}

fn cancelled(state: *State, generation: u64) bool {
    state.mutex.lockUncancelable(state.io);
    defer state.mutex.unlock(state.io);
    return state.shutting_down or state.cancelled_generation == generation;
}

fn scanClaude(allocator: std.mem.Allocator, io: std.Io, home: []const u8, candidates: *std.ArrayList(Candidate), partial: *bool) void {
    const root_path = std.fs.path.join(allocator, &.{ home, ".claude", "projects" }) catch return;
    defer allocator.free(root_path);
    var root = std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true, .follow_symlinks = false }) catch return;
    defer root.close(io);
    var projects = root.iterate();
    while (true) {
        const project = (projects.next(io) catch return) orelse break;
        if (project.kind != .directory) continue;
        var dir = openChildDirectoryNoFollow(io, root, project.name) orelse continue;
        defer dir.close(io);
        var files = dir.iterate();
        while (true) {
            const entry = (files.next(io) catch break) orelse break;
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
            const relative = std.fmt.allocPrint(allocator, "{s}/{s}", .{ project.name, entry.name }) catch continue;
            const open_path = std.fs.path.join(allocator, &.{ root_path, relative }) catch {
                allocator.free(relative);
                continue;
            };
            appendCandidate(allocator, io, &dir, entry.name, .claude, open_path, relative, candidates, partial);
        }
    }
}

fn scanCodex(allocator: std.mem.Allocator, io: std.Io, home: []const u8, candidates: *std.ArrayList(Candidate), partial: *bool) void {
    const root_path = std.fs.path.join(allocator, &.{ home, ".codex", "sessions" }) catch return;
    defer allocator.free(root_path);
    var root = std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true, .follow_symlinks = false }) catch return;
    defer root.close(io);
    var years = root.iterate();
    while (true) {
        const year = (years.next(io) catch return) orelse break;
        if (year.kind != .directory) continue;
        var year_dir = openChildDirectoryNoFollow(io, root, year.name) orelse continue;
        defer year_dir.close(io);
        var months = year_dir.iterate();
        while (true) {
            const month = (months.next(io) catch break) orelse break;
            if (month.kind != .directory) continue;
            var month_dir = openChildDirectoryNoFollow(io, year_dir, month.name) orelse continue;
            defer month_dir.close(io);
            var days = month_dir.iterate();
            while (true) {
                const day = (days.next(io) catch break) orelse break;
                if (day.kind != .directory) continue;
                var day_dir = openChildDirectoryNoFollow(io, month_dir, day.name) orelse continue;
                defer day_dir.close(io);
                var files = day_dir.iterate();
                while (true) {
                    const entry = (files.next(io) catch break) orelse break;
                    if (entry.kind != .file or !std.mem.startsWith(u8, entry.name, "rollout-") or !std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
                    const relative = std.fmt.allocPrint(allocator, "{s}/{s}/{s}/{s}", .{ year.name, month.name, day.name, entry.name }) catch continue;
                    const open_path = std.fs.path.join(allocator, &.{ root_path, relative }) catch {
                        allocator.free(relative);
                        continue;
                    };
                    appendCandidate(allocator, io, &day_dir, entry.name, .codex, open_path, relative, candidates, partial);
                }
            }
        }
    }
}

/// Each history-path component is opened from the preceding directory handle.
/// `iterate` reports a symlink in the usual case; the no-follow open closes the
/// enumerate-to-open replacement race as well.
fn openChildDirectoryNoFollow(io: std.Io, parent: std.Io.Dir, name: []const u8) ?std.Io.Dir {
    return parent.openDir(io, name, .{ .iterate = true, .follow_symlinks = false }) catch null;
}

fn appendCandidate(allocator: std.mem.Allocator, io: std.Io, dir: *std.Io.Dir, open_name: []const u8, provider: archive.Provider, open_path: []u8, source_path: []u8, candidates: *std.ArrayList(Candidate), partial: *bool) void {
    var candidate: Candidate = .{
        .provider = provider,
        .open_path = open_path,
        .source_path = source_path,
        .mtime_ns = 0,
        .size = 0,
        .inode = 0,
        .device = 0,
    };
    var transferred = false;
    defer if (!transferred) candidate.deinit(allocator);
    const stat = dir.statFile(io, open_name, .{ .follow_symlinks = false }) catch return;
    if (stat.kind != .file or stat.size == 0) return;
    if (stat.size > max_file_bytes) {
        partial.* = true;
        return;
    }
    candidate.mtime_ns = stat.mtime.nanoseconds;
    candidate.size = @intCast(stat.size);
    candidate.inode = stat.inode;
    candidate.device = fileDevice(allocator, dir.*, open_name) orelse return;
    if (candidates.items.len < max_candidates_per_provider) {
        candidates.append(allocator, candidate) catch return;
        transferred = true;
        return;
    }
    // Keep the newest 4096 candidates, regardless of directory iteration order.
    var oldest_index: usize = 0;
    for (candidates.items[1..], 1..) |existing, index| {
        if (existing.mtime_ns < candidates.items[oldest_index].mtime_ns) oldest_index = index;
    }
    if (candidate.mtime_ns <= candidates.items[oldest_index].mtime_ns) {
        partial.* = true;
        return;
    }
    candidates.items[oldest_index].deinit(allocator);
    candidates.items[oldest_index] = candidate;
    transferred = true;
    partial.* = true;
}

fn fileDevice(allocator: std.mem.Allocator, dir: std.Io.Dir, name: []const u8) ?u64 {
    if (comptime builtin.os.tag != .macos) return 0;
    const name_z = allocator.dupeZ(u8, name) catch return null;
    defer allocator.free(name_z);
    var stat: std.posix.Stat = undefined;
    if (std.c.fstatat(dir.handle, name_z.ptr, &stat, std.posix.AT.SYMLINK_NOFOLLOW) != 0) return null;
    return @intCast(stat.dev);
}

fn appendCandidateFile(state: *State, candidate: Candidate, generation: u64, result: *Result, remaining_bytes: *usize) void {
    const allocator = state.allocator;
    const io = state.io;
    if (cancelled(state, generation)) return;
    const file = std.Io.Dir.cwd().openFile(io, candidate.open_path, .{ .follow_symlinks = false }) catch return;
    defer file.close(io);
    const stat = file.stat(io) catch return;
    if (stat.inode != candidate.inode or openedDevice(file) != candidate.device) return;
    if (stat.kind != .file or stat.size == 0 or stat.size > max_file_bytes) {
        if (stat.size > max_file_bytes) result.partial = true;
        return;
    }
    const size: usize = @intCast(stat.size);
    if (size > remaining_bytes.*) {
        result.partial = true;
        return;
    }
    // Budget is charged before allocation/read so malformed input cannot turn a bounded refresh into an
    // unbounded sequence of expensive parse attempts.
    remaining_bytes.* -= size;
    const bytes = allocator.alloc(u8, size) catch return;
    defer allocator.free(bytes);
    const n = file.readPositionalAll(io, bytes, 0) catch return;
    if (cancelled(state, generation)) return;
    var parsed = archive.parse(allocator, candidate.provider, bytes[0..n]) catch return orelse return;
    errdefer parsed.deinit(allocator);
    if (cancelled(state, generation)) return;
    canonicalizeParsedCwd(state, &parsed);
    cacheParsed(state, candidate, &parsed);
    const path = allocator.dupe(u8, candidate.open_path) catch return;
    result.records.append(allocator, .{ .parsed = parsed, .source_path = path, .mtime_ns = candidate.mtime_ns, .inode = candidate.inode, .device = candidate.device }) catch {
        allocator.free(path);
        return;
    };
}

/// Provider JSONL may retain a lexical cwd reached through a symlink.  Scope
/// filtering compares that cwd with explorer/git roots, so normalize it while
/// this worker already owns filesystem work.  A missing, remote, or otherwise
/// unresolvable cwd deliberately remains unchanged; the UI then fail-closes it
/// out of workspace/project scope instead of guessing containment.
fn canonicalizeParsedCwd(state: *State, parsed: *archive.Parsed) void {
    if (!std.fs.path.isAbsolute(parsed.cwd) or parsed.cwd.len == 0) return;
    var dir = std.Io.Dir.cwd().openDir(state.io, parsed.cwd, .{}) catch return;
    dir.close(state.io);
    var canonical_buf: [std.fs.max_path_bytes]u8 = undefined;
    const canonical_len = std.Io.Dir.realPathFileAbsolute(state.io, parsed.cwd, &canonical_buf) catch return;
    const replacement = state.allocator.dupe(u8, canonical_buf[0..canonical_len]) catch return;
    state.allocator.free(parsed.cwd);
    parsed.cwd = replacement;
    parsed.cwd_canonical = true;
}

fn openedDevice(file: std.Io.File) u64 {
    if (comptime builtin.os.tag != .macos) return 0;
    var stat: std.posix.Stat = undefined;
    if (std.c.fstat(file.handle, &stat) != 0) return std.math.maxInt(u64);
    return @intCast(stat.dev);
}

test "archive cache identity rejects replaced or changed source files" {
    var entry: CacheEntry = undefined;
    entry.provider = .codex;
    entry.source_path = @constCast("2026/08/02/rollout.jsonl");
    entry.mtime_ns = 10;
    entry.size = 20;
    entry.inode = 30;
    entry.device = 40;
    const candidate = Candidate{
        .provider = .codex,
        .open_path = @constCast("/tmp/rollout.jsonl"),
        .source_path = @constCast("2026/08/02/rollout.jsonl"),
        .mtime_ns = 10,
        .size = 20,
        .inode = 30,
        .device = 40,
    };
    try std.testing.expect(sameCacheIdentity(entry, candidate));
    var replaced = candidate;
    replaced.inode = 31;
    try std.testing.expect(!sameCacheIdentity(entry, replaced));
    var changed = candidate;
    changed.mtime_ns = 11;
    try std.testing.expect(!sameCacheIdentity(entry, changed));
    changed = candidate;
    changed.device = 41;
    try std.testing.expect(!sameCacheIdentity(entry, changed));
    changed = candidate;
    changed.size = 21;
    try std.testing.expect(!sameCacheIdentity(entry, changed));
    changed = candidate;
    changed.provider = .claude;
    try std.testing.expect(!sameCacheIdentity(entry, changed));
    changed = candidate;
    changed.source_path = @constCast("other/rollout.jsonl");
    try std.testing.expect(!sameCacheIdentity(entry, changed));
}

test "archive backend reports an enqueue failure without manufacturing an empty snapshot" {
    var state = State{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer state.results.deinit(std.testing.allocator);
    var backend = Backend{ .state = &state };
    state.completion_without_snapshot = true;
    const result = backend.takeResult() orelse return error.TestUnexpectedResult;
    defer {
        var owned = result;
        owned.deinit(std.testing.allocator);
    }
    try std.testing.expect(result.complete);
    try std.testing.expect(result.retain_previous);
    try std.testing.expectEqual(@as(usize, 0), result.records.items.len);
    try std.testing.expect(backend.takeResult() == null);
}

test "archive cancellation fences only the inflight generation and reports a retain-previous completion" {
    var state = State{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer state.results.deinit(std.testing.allocator);
    var backend = Backend{ .state = &state };
    state.inflight = true;
    state.inflight_generation = 7;
    try std.testing.expect(backend.cancel());
    try std.testing.expectEqual(@as(u64, 7), state.cancelled_generation);
    try std.testing.expect(!backend.cancel());

    state.inflight = false;
    state.inflight_generation = 0;
    state.completion_without_snapshot = true;
    state.completion_cancelled = true;
    const result = backend.takeResult() orelse return error.TestUnexpectedResult;
    defer {
        var owned = result;
        owned.deinit(std.testing.allocator);
    }
    try std.testing.expect(result.complete and result.retain_previous and result.cancelled);
}

test "archive worker smoke gate waits without blocking the releasing actor" {
    var backend = try Backend.init(std.testing.allocator, std.testing.io);
    defer backend.deinit();
    backend.setTestGate(true);

    const Probe = struct {
        backend: *Backend,
        finished: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            waitForTestGate(self.backend.state.?, 1);
            self.finished.store(true, .release);
        }
    };
    var probe = Probe{ .backend = &backend };
    const thread = try std.Thread.spawn(.{}, Probe.run, .{&probe});
    defer thread.join();

    var spins: usize = 0;
    while (!backend.testGateReached() and spins < 1_000) : (spins += 1) {
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expect(backend.testGateReached());
    try std.testing.expect(!probe.finished.load(.acquire));

    backend.setTestGate(false);
    spins = 0;
    while (!probe.finished.load(.acquire) and spins < 1_000) : (spins += 1) {
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expect(probe.finished.load(.acquire));
}

test "cancelled archive generation cannot publish a replacement snapshot" {
    var state = State{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer {
        for (state.results.items) |*result| result.deinit(std.testing.allocator);
        state.results.deinit(std.testing.allocator);
    }
    state.cancelled_generation = 9;
    var cancelled_result = Result{ .complete = true };
    try std.testing.expect(!publish(&state, 9, &cancelled_result));
    try std.testing.expectEqual(@as(usize, 0), state.results.items.len);

    var latest_result = Result{ .complete = true };
    try std.testing.expect(publish(&state, 10, &latest_result));
    try std.testing.expectEqual(@as(usize, 1), state.results.items.len);
}

test "archive scanner refuses a symlinked history directory" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "history", .default_dir);
    try tmp.dir.createDir(io, "outside", .default_dir);
    try tmp.dir.symLink(io, "outside", "history/project-link", .{ .is_directory = true });
    var history = try tmp.dir.openDir(io, "history", .{ .iterate = true, .follow_symlinks = false });
    defer history.close(io);
    try std.testing.expect(openChildDirectoryNoFollow(io, history, "project-link") == null);
}
