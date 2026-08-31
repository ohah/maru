//! One-shot, no-follow detail reader for a dock-local archive disclosure.
//!
//! Archive list discovery already proved a source identity.  A disclosure must prove
//! that identity again before it reads any user transcript, because a pathname
//! can be replaced between list publication and a later click.  This backend
//! owns the blocking open/stat/read/JSON work; AppSession only drains immutable
//! results on its frame path.

const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const archive = maru.session.agent_session_archive;
const detail = maru.session.agent_session_archive_detail;
const scan_backend = @import("agent_session_archive_backend.zig");
const redact = maru.redact;

pub const max_tail_bytes: usize = 512 * 1024;

pub const Source = struct {
    provider: archive.Provider,
    source_path: []u8,
    inode: std.Io.File.INode,
    device: u64,

    pub fn deinit(self: *Source, allocator: std.mem.Allocator) void {
        allocator.free(self.source_path);
        self.* = undefined;
    }
};

pub const State = enum { ready, stale, unavailable };

pub const Result = struct {
    request_id: u64,
    state: State,
    detail: ?detail.Detail = null,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        if (self.detail) |*parsed| parsed.deinit(allocator);
        self.* = undefined;
    }
};

const WorkerState = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    refs: std.atomic.Value(usize) = .init(1),
    results: std.ArrayList(Result) = .empty,
    inflight: bool = false,
    shutting_down: bool = false,
    // The production path never arms this.  The AppKit archive smoke uses it
    // to hold a detached detail read after the tab has published loading, so
    // the test observes a state transition rather than racing a fast local
    // filesystem.  Atomics keep the worker's wait independent of the main
    // actor and `shutting_down` remains the escape hatch for teardown.
    test_gate_enabled: std.atomic.Value(bool) = .init(false),
    test_gate_reached: std.atomic.Value(bool) = .init(false),
    test_gate_released: std.atomic.Value(bool) = .init(true),

    fn release(self: *WorkerState) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        std.debug.assert(!self.inflight);
        for (self.results.items) |*result| result.deinit(self.allocator);
        self.results.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

const Job = struct {
    state: *WorkerState,
    source: Source,
    request_id: u64,
};

pub const Backend = struct {
    state: ?*WorkerState,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !Backend {
        const state = try allocator.create(WorkerState);
        state.* = .{ .allocator = allocator, .io = io };
        return .{ .state = state };
    }

    /// Caller owns source on false; the detached worker owns it on true.
    /// One in-flight detail read is intentionally enough: a later disclosure can show loading
    /// immediately and retry after this bounded read publishes. `request_id` is the only
    /// completion authority; no UI surface is created or carried across this boundary.
    pub fn submit(self: *Backend, source: Source, request_id: u64) bool {
        const state = self.state orelse return false;
        state.mutex.lockUncancelable(state.io);
        if (state.shutting_down or state.inflight) {
            state.mutex.unlock(state.io);
            return false;
        }
        state.inflight = true;
        _ = state.refs.fetchAdd(1, .monotonic);
        state.mutex.unlock(state.io);

        const job = state.allocator.create(Job) catch {
            finishWithoutResult(state);
            return false;
        };
        job.* = .{ .state = state, .source = source, .request_id = request_id };
        const thread = std.Thread.spawn(.{}, worker, .{job}) catch {
            state.allocator.destroy(job);
            finishWithoutResult(state);
            return false;
        };
        thread.detach();
        return true;
    }

    pub fn takeResult(self: *Backend) ?Result {
        const state = self.state orelse return null;
        state.mutex.lockUncancelable(state.io);
        defer state.mutex.unlock(state.io);
        if (state.results.items.len == 0) return null;
        return state.results.orderedRemove(0);
    }

    /// Test-only synchronization for the AppKit archive fixture.  It has no
    /// environment/config reader: a caller must explicitly arm it before
    /// submitting a detail job, and normal product code never does.
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

    pub fn deinit(self: *Backend) void {
        const state = self.state orelse return;
        self.state = null;
        state.mutex.lockUncancelable(state.io);
        state.shutting_down = true;
        for (state.results.items) |*result| result.deinit(state.allocator);
        state.results.clearRetainingCapacity();
        state.mutex.unlock(state.io);
        state.release();
    }
};

fn finishWithoutResult(state: *WorkerState) void {
    state.mutex.lockUncancelable(state.io);
    state.inflight = false;
    state.mutex.unlock(state.io);
    state.release();
}

fn worker(job: *Job) void {
    const state = job.state;
    waitForTestGate(state);
    var result = readSource(state, job.source, job.request_id);
    job.source.deinit(state.allocator);
    state.allocator.destroy(job);

    state.mutex.lockUncancelable(state.io);
    if (state.shutting_down) {
        state.mutex.unlock(state.io);
        result.deinit(state.allocator);
    } else {
        state.results.append(state.allocator, result) catch result.deinit(state.allocator);
        state.mutex.unlock(state.io);
    }
    state.mutex.lockUncancelable(state.io);
    state.inflight = false;
    state.mutex.unlock(state.io);
    state.release();
}

fn waitForTestGate(state: *WorkerState) void {
    if (!state.test_gate_enabled.load(.acquire)) return;
    state.test_gate_reached.store(true, .release);
    while (!state.test_gate_released.load(.acquire)) {
        state.mutex.lockUncancelable(state.io);
        const shutting_down = state.shutting_down;
        state.mutex.unlock(state.io);
        if (shutting_down) break;
        // This is a detached worker only.  The main actor continues to paint
        // the loading panel and can release the gate without waiting on I/O.
        std.Io.sleep(state.io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }
    state.test_gate_reached.store(false, .release);
}

fn readSource(state: *WorkerState, source: Source, request_id: u64) Result {
    const opened = std.Io.Dir.cwd().openFile(state.io, source.source_path, .{ .follow_symlinks = false }) catch
        return .{ .request_id = request_id, .state = .unavailable };
    // **Windows 에서 핸들 모드와 플래그가 어긋난다** — 그대로 positional read 를 하면 `PENDING` 을
    // `unreachable` 로 받아 **프로세스가 죽는다**. 옆 백엔드가 2026-08-25 에 같은 자리에서 겪고 규약을
    // 적어 뒀는데 이 파일은 그것을 안 쓰고 있었다(실측: 카드를 펼치는 순간 패닉, §2m.97).
    const file = scan_backend.positionalReadable(opened);
    defer file.close(state.io);
    const stat = file.stat(state.io) catch return .{ .request_id = request_id, .state = .unavailable };
    if (stat.kind != .file) return .{ .request_id = request_id, .state = .unavailable };
    if (stat.inode != source.inode or openedDevice(file) != source.device)
        return .{ .request_id = request_id, .state = .stale };
    const size: usize = @intCast(stat.size);
    const take = @min(size, max_tail_bytes);
    const start = size - take;
    const bytes = state.allocator.alloc(u8, take) catch return .{ .request_id = request_id, .state = .unavailable };
    defer state.allocator.free(bytes);
    const n = file.readPositionalAll(state.io, bytes, start) catch return .{ .request_id = request_id, .state = .unavailable };
    var parsed = detail.parseTail(state.allocator, source.provider, bytes[0..n], start == 0) catch
        return .{ .request_id = request_id, .state = .unavailable };
    errdefer parsed.deinit(state.allocator);
    redactTurns(state.allocator, &parsed);
    return .{ .request_id = request_id, .state = .ready, .detail = parsed };
}

/// Detail text crosses the worker/main boundary only after the repository-wide
/// sensitive-content guard and PII anonymizer.  Ambiguous sensitive text is
/// replaced rather than partially shown; tool payloads never reach this point.
fn redactTurns(allocator: std.mem.Allocator, parsed: *detail.Detail) void {
    const home = if (std.c.getenv("HOME")) |value| std.mem.span(value) else null;
    const username = if (std.c.getenv("USER")) |value| std.mem.span(value) else null;
    for (parsed.turns.items) |*turn| {
        // 가려야 하는 턴은 **플래그만** 세우고 문장은 안 만든다. 이 함수는 떼어낸 워커에서 돌고, 여기서
        // `i18n.t()` 로 만든 문장은 그 시점의 언어에 얼어붙어 캐시된다 — 사용자가 나중에 화면 언어를
        // 바꾸면 이 줄만 옛 언어로 남아 계약 §5.2 를 깬다. 문구는 그리는 쪽(UI 스레드)이 키에서 푼다.
        if (redact.hasSensitiveContent(turn.text)) {
            allocator.free(turn.text);
            turn.text = &.{};
            turn.redacted = true;
            continue;
        }
        const next = redact.anonymizeAlloc(allocator, turn.text, .{ .home = home, .username = username }) catch continue;
        allocator.free(turn.text);
        turn.text = next;
    }
}

fn openedDevice(file: std.Io.File) u64 {
    if (comptime builtin.os.tag != .macos) return 0;
    var stat: std.posix.Stat = undefined;
    if (std.c.fstat(file.handle, &stat) != 0) return std.math.maxInt(u64);
    return @intCast(stat.dev);
}

test "detail worker smoke gate waits without blocking the releasing actor" {
    var backend = try Backend.init(std.testing.allocator, std.testing.io);
    defer backend.deinit();
    backend.setTestGate(true);

    const Probe = struct {
        backend: *Backend,
        finished: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            waitForTestGate(self.backend.state.?);
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

test "detail worker redacts sensitive turns before publication" {
    var parsed = try detail.parseTail(std.testing.allocator, .codex,
        \\{"type":"event_msg","payload":{"type":"user_message","message":"API_TOKEN=fixture-value"}}
        \\{"type":"event_msg","payload":{"type":"agent_message","message":"at /Users/alice/project"}}
    , true);
    defer parsed.deinit(std.testing.allocator);
    redactTurns(std.testing.allocator, &parsed);
    // 가려진 턴은 **플래그**로 표시되고 원문은 사라진다. 문구를 여기서 만들지 않는 것이 계약이다 —
    // 만들면 이 워커가 돈 시점의 언어에 얼어붙어, 나중에 화면 언어를 바꿔도 이 줄만 옛 언어로 남는다.
    // 빈 문자열이라는 것이 곧 **민감한 원문이 남지 않았다**는 뜻이다 — 이 테스트가 원래 지키던 것.
    try std.testing.expect(parsed.turns.items[0].redacted);
    try std.testing.expectEqualStrings("", parsed.turns.items[0].text);
    // 가릴 필요가 없는 턴은 익명화만 거치고 플래그가 안 선다.
    try std.testing.expect(!parsed.turns.items[1].redacted);
    try std.testing.expectEqualStrings("at /Users/user/project", parsed.turns.items[1].text);
}
