//! Codex·Claude session archive의 macOS worker backend.
//!
//! AppSession frame tick은 submit/takeResult만 호출한다. provider history는 사용자 데이터이므로 worker가
//! 만든 summary 외 raw JSONL은 main actor로 넘기지 않는다.

const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const archive = maru.session.agent_session_archive;

/// 후보 수집은 디렉터리 순회와 `stat`뿐이라 개수 상한을 두지 않는다(실측 351개에 2.4 ms). 다만 손상된
/// 트리에서 무한히 모으지 않도록 방어선만 둔다 — 실사용 규모의 수십 배다.
pub const max_candidates_per_provider: usize = 65_536;
/// 표시 상한도 같은 성격의 방어선이다. 예전 값 500은 목록을 실제로 자르는 값이 아니었고(실측: 도달조차
/// 하지 않았다) 자르는 것은 read budget이었다.
pub const max_records: usize = 65_536;
/// 레코드당 요약이 약 250 B라 후보 전부를 담아도 수십 KB다(실측 351개 = 88 KB). 조회는 스캔 전체에서
/// 3 ms 미만이라 상한을 낮게 둘 이유가 없다.
pub const max_cache_entries: usize = max_records;
/// 한 줄이 이보다 길면 그 줄만 버린다. 손상된 파일이 줄 버퍼를 무한히 키우는 것만 막는 방어이며,
/// 정상 파일은 전부 통과한다(실측 최장 줄 6.85 MB).
pub const max_line_bytes: usize = 16 * 1024 * 1024;
/// 스트리밍 읽기 청크. 파일 크기와 무관하게 이 버퍼 하나만 쓴다.
const read_chunk_bytes: usize = 64 * 1024;
/// 첫 진입에서 부분 목록을 발행하는 최소 간격. 발행마다 main actor가 filter/projection/anchor 복원을
/// 다시 하므로 너무 잦으면 그 자체가 비용이다. 실측 채움 속도는 첫 카드 6 ms, 20개 약 2초다.
const progress_publish_interval_ms: i96 = 250;
/// 그 간격 안이라도 이만큼 쌓이면 발행한다 — 초반이 촘촘해야 첫 화면이 빨리 찬다.
const progress_publish_records: usize = 12;

/// Codex worker 확정 경계. 여기까지 읽고도 `user` 신호를 한 번도 못 보면 worker로 보고 읽기를 멈춘다.
/// 실측 `user` 메타 최대 위치(18.6 KiB)의 27배 여유다 — 좁게 잡으면 미래에 세션이 조용히 사라진다.
const codex_worker_verdict_bytes: usize = 512 * 1024;

/// Claude 세션이 돌린 서브에이전트 transcript 수의 상한. 디렉터리 항목만 세므로 비용은 순회뿐이지만,
/// 손상되거나 비정상적으로 많은 디렉터리에서 무한히 세지 않도록 끊는다. UI는 초과를 `999+`로 보인다.
pub const max_subagent_count: u32 = 999;

/// **std 가 Windows 에서 핸들 모드와 플래그를 어긋나게 준다.** `dirOpenFileWindows` 는
/// `follow_symlinks = false` 일 때 `NtCreateFile` 을 `.IO = .ASYNCHRONOUS` 로 부르면서도 언제나
/// `.flags = .{ .nonblocking = false }` 를 돌려준다(zig 0.16.0 `std/Io/Threaded.zig:5033` 과
/// 그 함수의 두 return). 그러면 `readFilePositionalWindows` 가 동기 분기로 가고, 비동기 핸들이
/// 낸 `PENDING` 을 `unreachable` 로 받아 **프로세스가 죽는다**. 어느 값이 맞는지는 std 자신이
/// 정해 뒀다 — `File.Flags.nonblocking` 의 doc 이 `true` 를 *"windows: opened with
/// MODE.IO.ASYNCHRONOUS"* 로 정의한다. 즉 아래가 그 규약이고, 어긴 것은 반환값이다. 이 경로가 Windows 에서 처음
/// 돌자 그 자리에서 패닉했다(실측 2026-08-25). 그 함수의 비동기 분기는 `PENDING` 을 제대로
/// 기다리므로, **실제 핸들 모드에 플래그를 맞춰** 그쪽으로 보낸다. `follow_symlinks` 를 켜서
/// 동기 핸들을 받는 길도 있지만 그것은 위 대조를 무력화하므로 택하지 않는다.
///
/// **이 규약을 쓰는 자리가 둘이다** — 목록 스캔과 펼침 상세. 두 벌로 적으면 한쪽만 고쳐지고, 그
/// 증상은 "그 기능만 쓰면 프로세스가 죽는다" 라 눈으로 잘 안 걸린다(실측: 상세 백엔드가 정확히 그
/// 상태였다 — Windows 에서 카드를 펼치는 순간 패닉했다, §2m.97).
pub fn positionalReadable(opened: std.Io.File) std.Io.File {
    if (builtin.os.tag != .windows) return opened;
    return .{ .handle = opened.handle, .flags = .{ .nonblocking = true } };
}

pub const Record = struct {
    parsed: archive.Parsed,
    /// Absolute provider-log pathname kept only in the in-process snapshot.
    /// It is paired with the discovery identity so a later explicit reveal can
    /// reject a replacement instead of opening an arbitrary new file.
    source_path: []u8,
    mtime_ns: i96,
    inode: std.Io.File.INode,
    device: u64,
    /// 이 세션이 돌린 서브에이전트 transcript 수(Claude 전용, 없으면 0). **파일을 열지 않고 디렉터리
    /// 항목만 세므로** parse 결과가 아니라 스캔 메타데이터다 — 그래서 `Parsed`가 아니라 여기 있고,
    /// 파싱 방식이 바뀌어도 값이 정확하다. Codex는 worker가 별도 파일이 아니라 같은 rollout 트리에
    /// 섞여 있어 부모와 연결할 규칙이 없으므로 항상 0이다(docs/agent-session-list.md §2.3).
    subagent_count: u32 = 0,

    pub fn deinit(self: *Record, allocator: std.mem.Allocator) void {
        self.parsed.deinit(allocator);
        allocator.free(self.source_path);
        self.* = undefined;
    }
};

/// 한 worker job이 main actor에게 돌려주는 **배타적** 결말. 예전에는 `complete`·`retain_previous`·
/// `cancelled` bool 셋이었는데, 그 조합 여덟 가지 중 유효한 것은 아래 셋뿐이라 `assert(result.complete)`
/// 같은 방어가 필요했다. 종류를 하나로 모으면 조합 폭발이 사라지고, 새 결말을 더해도 기존 불변식이
/// 조용히 깨지지 않는다.
pub const Outcome = enum {
    /// 스캔이 끝나 새 immutable snapshot을 만들었다. `records` 소유권이 main actor로 넘어간다.
    completed,
    /// 스캔은 끝났지만 교체본을 enqueue하지 못했다(결과 큐 allocation 실패 등). main actor는 spinner를
    /// 끄되 **이전 목록을 유지**한다.
    retain_previous,
    /// 취소된 세대다. 보이는 snapshot을 대체할 자격이 없다. main actor는 spinner를 끄고, 도크가 다시
    /// 보이면 이 worker가 자원을 모두 놓은 뒤 최신 세대를 재요청한다.
    cancelled,
    /// **진행 중** 부분 목록이다(첫 진입에만 발행된다 — §4.1). 목록이 위에서부터 차오르게 하려는
    /// 것이므로 main actor는 records를 그대로 반영하되 **완료로 취급하면 안 된다**:
    /// TTL(`completed_ns`)을 갱신하면 재스캔이 막혀 목록이 불완전한 채 고정되고, "이전 snapshot 있음"
    /// 판정에 쓰면 취소로 남은 부분 목록을 완성본으로 오인해 다음 진입이 점진 경로를 타지 않는다.
    partial_progress,
};

pub const Result = struct {
    records: std.ArrayList(Record) = .empty,
    /// 스캔이 사용자 이력의 일부만 훑었다. `outcome`과 **직교**한다 — 완료됐지만 일부만 본 경우가
    /// 정상적으로 존재한다. **정책적 제외(worker 판정)는 여기 포함하지 않는다** — 정상 동작이 상시
    /// 경고로 보이면 경고가 무의미해진다.
    partial: bool = false,
    outcome: Outcome = .completed,

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
    /// 이번 job이 부분 진행을 발행해도 되는가. main actor가 `submit` 시점에 "보여 줄 이전 완료 목록이
    /// 없다"를 알려 준다. worker가 락 없이 읽으므로 atomic이다.
    wants_progress: std.atomic.Value(bool) = .init(false),
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
    subagent_count: u32 = 0,

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

    /// In production `allocator` must be process-lifetime: `deinit` is intentionally nonblocking
    /// and a filesystem call already in progress may keep the detached worker's final State ref
    /// alive after the AppSession releases its Backend handle. Test builds enforce quiescence
    /// before returning so a per-test allocator cannot be observed after its lifetime.
    pub fn init(allocator: std.mem.Allocator, io: std.Io) !Backend {
        const state = try allocator.create(State);
        state.* = .{ .allocator = allocator, .io = io };
        return .{ .state = state };
    }

    /// caller owns home on false; worker owns it on true.
    /// `wants_progress`는 "이 스캔이 끝나기 전에도 부분 목록을 보여 달라"는 요청이다. 보여 줄 이전
    /// 완료 목록이 없는 첫 진입에서만 켠다 — 이미 목록이 있으면 완성본 하나로 교체하는 편이 흔들림이
    /// 없다(§4.1).
    pub fn submit(self: *Backend, home: []u8, wants_progress: bool) bool {
        const state = self.state orelse return false;
        state.mutex.lockUncancelable(state.io);
        if (state.shutting_down or state.inflight) {
            state.mutex.unlock(state.io);
            return false;
        }
        state.wants_progress.store(wants_progress, .release);
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
            return .{ .outcome = if (state.completion_cancelled) .cancelled else .retain_previous };
        }
        return state.results.orderedRemove(0);
    }

    pub fn deinit(self: *Backend) void {
        const state = self.state orelse return;
        self.state = null;
        state.mutex.lockUncancelable(state.io);
        state.shutting_down = true;
        state.cancelled_generation = state.inflight_generation;
        state.test_gate_released.store(true, .release);
        for (state.results.items) |*result| result.deinit(state.allocator);
        state.results.deinit(state.allocator);
        state.results = .empty;
        for (state.cache.items) |*entry| entry.deinit(state.allocator);
        state.cache.deinit(state.allocator);
        state.cache = .empty;
        state.mutex.unlock(state.io);
        // Production teardown stays nonblocking: the detached worker owns its State ref until its
        // current filesystem call returns. Tests, however, commonly pass DebugAllocator storage
        // whose lifetime ends with the test, so they must prove that no detached allocation
        // survives that boundary. The finite test-only drain turns a stuck fixture into an
        // explicit failure without making an unavailable provider mount hang app Quit.
        if (builtin.is_test) {
            var attempts: usize = 0;
            while (attempts < 10_000) : (attempts += 1) {
                state.mutex.lockUncancelable(state.io);
                const inflight = state.inflight;
                state.mutex.unlock(state.io);
                if (!inflight) break;
                std.Io.sleep(state.io, std.Io.Duration.fromMilliseconds(1), .awake) catch
                    @panic("archive test worker drain sleep failed");
            } else @panic("archive test worker did not stop within 10 seconds");
        }
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

/// 지금까지 모은 records의 **복사본**을 부분 진행으로 발행한다. 원본은 계속 쌓여야 하므로 소유권을
/// 넘기지 않고 clone한다(레코드당 약 250 B라 복사가 싸다).
///
/// 발행에 실패하면 조용히 넘어간다 — 부분 진행은 최적화이지 계약이 아니다. 최종 `.completed`가 전체
/// 목록을 싣는다.
fn publishProgress(state: *State, generation: u64, result: *const Result) void {
    var snapshot: Result = .{ .outcome = .partial_progress, .partial = result.partial };
    snapshot.records.ensureTotalCapacity(state.allocator, result.records.items.len) catch return;
    for (result.records.items) |record| {
        const parsed = record.parsed.clone(state.allocator) catch break;
        const path = state.allocator.dupe(u8, record.source_path) catch {
            var owned = parsed;
            owned.deinit(state.allocator);
            break;
        };
        snapshot.records.appendAssumeCapacity(.{
            .parsed = parsed,
            .source_path = path,
            .mtime_ns = record.mtime_ns,
            .inode = record.inode,
            .device = record.device,
            .subagent_count = record.subagent_count,
        });
    }
    // 후보는 mtime 순으로 처리되지만 목록의 순서는 활동 시각이 정한다. 부분 목록도 같은 키로 정렬해야
    // 완성본으로 바뀔 때 카드가 재배치되지 않는다.
    std.mem.sort(Record, snapshot.records.items, {}, newestFirst);
    state.mutex.lockUncancelable(state.io);
    defer state.mutex.unlock(state.io);
    if (state.shutting_down or state.cancelled_generation == generation) {
        snapshot.deinit(state.allocator);
        return;
    }
    // 아직 안 가져간 부분 진행이 있으면 **쌓지 않고 대체한다**. 부분 진행은 최신 하나만 의미가 있고,
    // 쌓이면 main actor가 낡은 목록마다 filter/projection/anchor 복원을 다시 한다. 첫 진입인데 캐시가
    // 이미 따뜻한 경우(도크를 열자마자 닫고 다시 열면 그렇게 된다) 12개 누적 조건이 수 ms 안에 수십 번
    // 걸리므로 가정이 아니라 실제로 도달하는 경로다.
    if (state.results.items.len > 0) {
        const last = &state.results.items[state.results.items.len - 1];
        if (last.outcome == .partial_progress) {
            last.deinit(state.allocator);
            last.* = snapshot;
            return;
        }
    }
    state.results.append(state.allocator, snapshot) catch snapshot.deinit(state.allocator);
}

fn publish(state: *State, generation: u64, result: *Result) bool {
    state.mutex.lockUncancelable(state.io);
    defer state.mutex.unlock(state.io);
    if (state.shutting_down or state.cancelled_generation == generation) {
        result.deinit(state.allocator);
        result.* = .{}; // 호출자의 defer가 다시 deinit해도 안전하도록 **빈 값**으로 남긴다.
        return false;
    }
    state.results.append(state.allocator, result.*) catch {
        result.deinit(state.allocator);
        result.* = .{};
        return false;
    };
    result.* = .{};
    return true;
}

/// 이 세션의 마지막 활동 시각. transcript가 스스로 말하는 값을 쓰고, 그 값을 못 읽은 파일만 mtime으로
/// 폴백한다(docs/agent-session-list.md §2.3). mtime은 복사·도구의 메타 갱신으로도 밀리므로 실측 362개
/// 중 257개(70%)가 mtime 정렬에서 제자리가 아니었다.
///
/// **정렬과 카드의 "N분 전"이 같은 값을 써야 한다.** 다르면 "3일 전" 카드가 목록 맨 위에 앉는다.
pub fn lastActivityNs(record: Record) i96 {
    return if (record.parsed.last_activity_ns != 0) record.parsed.last_activity_ns else record.mtime_ns;
}

fn newestFirst(_: void, a: Record, b: Record) bool {
    return lastActivityNs(a) > lastActivityNs(b);
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
        return .{ .parsed = parsed, .source_path = path, .mtime_ns = candidate.mtime_ns, .inode = candidate.inode, .device = candidate.device, .subagent_count = candidate.subagent_count };
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
        //
        // 축출이 아니라 **새 항목을 버리는** 정책이다. 상한이 후보 수보다 훨씬 크므로(실사용 337개 vs
        // 65,536) 실제로 도달하지 않는다. 삭제된 세션의 항목은 프로세스 수명 동안 남지만 레코드당
        // 약 250 B라 수천 개여도 MB 미만이고, 앱을 다시 켜면 사라진다. 상한에 실제로 닿는 규모가
        // 나오면 그때 LRU를 도입한다 — 지금 넣으면 검증할 수 없는 코드가 된다.
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
    // `scan`은 error가 아니라 `bool`을 돌려주므로 **errdefer가 한 번도 실행되지 않는다**. 취소 확인마다
    // 있는 `return false`는 error가 아니기 때문이다. 그래서 도크를 닫아 취소가 걸리면 그때까지 모은
    // record가 통째로 누수됐다(도크를 여닫을 때마다 반복). `publish`는 성공하면 `result`를 빈 값으로
    // 비우고 실패해도 빈 값으로 남기므로, 여기 `defer`는 어느 경로에서도 정확히 한 번만 해제한다.
    defer result.deinit(allocator);
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
    // **스캔 순서**는 mtime이다. 활동 시각은 파일을 열어 봐야 알 수 있으므로 여기서는 쓸 수 없고,
    // 목록 순서는 파싱을 마친 뒤 `newestFirst`가 다시 정한다(docs/agent-session-list.md §2.3).
    std.mem.sort(Candidate, claude_candidates.items, {}, struct {
        fn lessThan(_: void, a: Candidate, b: Candidate) bool {
            return a.mtime_ns > b.mtime_ns;
        }
    }.lessThan);

    // 첫 진입(main actor가 보여 줄 이전 완료 목록이 없을 때)에만 목록이 위에서부터 차오르게 한다.
    // 이전 완료본이 있으면 지금처럼 완성본 하나로만 교체해 refresh가 목록을 흔들지 않는다(§4.1).
    const wants_progress = state.wants_progress.load(.acquire);
    var last_publish_ns = std.Io.Clock.awake.now(io).nanoseconds;
    var published_len: usize = 0;

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
        } else appendCandidateFile(state, candidate, generation, &result);

        if (!wants_progress) continue;
        const grown = result.records.items.len - published_len;
        if (grown == 0) continue;
        const now_ns = std.Io.Clock.awake.now(io).nanoseconds;
        const elapsed_ms = @divFloor(now_ns - last_publish_ns, std.time.ns_per_ms);
        if (grown >= progress_publish_records or elapsed_ms >= progress_publish_interval_ms) {
            publishProgress(state, generation, &result);
            published_len = result.records.items.len;
            last_publish_ns = now_ns;
        }
    }
    std.mem.sort(Record, result.records.items, {}, newestFirst);
    if (result.records.items.len > max_records) {
        for (result.records.items[max_records..]) |*record| record.deinit(allocator);
        result.records.shrinkRetainingCapacity(max_records);
        result.partial = true;
    }
    result.outcome = .completed;
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
            const before = candidates.items.len;
            appendCandidate(allocator, io, &dir, entry.name, .claude, open_path, relative, candidates, partial);
            // 세션 파일 `<uuid>.jsonl`과 **같은 이름의 디렉터리** 아래 `subagents/`가 그 세션이 돌린
            // 서브에이전트 transcript다. 목록에는 넣지 않지만(§3 표: 하위 계층 재귀 금지) 개수는
            // 부모 세션의 정보이므로 카드에 보인다. 파일을 열지 않고 항목만 센다.
            if (candidates.items.len > before) {
                candidates.items[candidates.items.len - 1].subagent_count =
                    countClaudeSubagents(io, &dir, entry.name);
            }
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

/// `<project>/<session>.jsonl`의 형제 디렉터리 `<session>/subagents/`에 있는 transcript 수를 센다.
/// 파일을 열지 않고 디렉터리 항목만 세므로 read budget과 무관하고, 순회 비용은 이미 지불한 것이다.
/// 디렉터리가 없으면 0이며, 그것이 정상이다(실측: 95개 세션 중 37개만 보유).
fn countClaudeSubagents(io: std.Io, project_dir: *std.Io.Dir, file_name: []const u8) u32 {
    const stem = if (std.mem.lastIndexOfScalar(u8, file_name, '.')) |dot| file_name[0..dot] else file_name;
    if (stem.len == 0) return 0;
    var session_dir = openChildDirectoryNoFollow(io, project_dir.*, stem) orelse return 0;
    defer session_dir.close(io);
    var subagents = openChildDirectoryNoFollow(io, session_dir, "subagents") orelse return 0;
    defer subagents.close(io);
    var count: u32 = 0;
    var it = subagents.iterate();
    while (count < max_subagent_count) {
        const entry = (it.next(io) catch break) orelse break;
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
        count += 1;
    }
    return count;
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

/// 후보 파일 하나를 **줄 단위로 스트리밍**해 레코드로 만든다.
///
/// 예전에는 `allocator.alloc(u8, stat.size)`로 파일을 통째로 올렸다(피크 463 MB 실측). 그 할당을
/// 방어하려고 파일당 128 MiB·refresh당 512 MiB read cap이 있었고, **그 cap이 목록을 잘랐다** — 게다가
/// 캐시 히트는 budget을 쓰지 않으므로 refresh를 반복할수록 보이는 세션이 늘어나 결과가 비결정적이었다.
/// 고정 64 KiB 버퍼로 바꾸면 메모리가 파일 크기와 무관해지고 그 cap들의 존재 이유가 사라진다.
fn appendCandidateFile(state: *State, candidate: Candidate, generation: u64, result: *Result) void {
    const allocator = state.allocator;
    const io = state.io;
    if (cancelled(state, generation)) return;
    // `follow_symlinks = false` 는 **아래 inode·device 대조와 한 쌍**이다(심링크를 갈아끼워 다른
    // 파일을 읽히는 것을 막는다). `allow_directory = false` 도 같은 뜻 — 후보는 파일이어야 한다.
    const opened = std.Io.Dir.cwd().openFile(io, candidate.open_path, .{
        .mode = .read_only,
        .follow_symlinks = false,
        .allow_directory = false,
    }) catch return;
    const file = positionalReadable(opened);
    defer file.close(io);
    const stat = file.stat(io) catch return;
    if (stat.inode != candidate.inode or openedDevice(file) != candidate.device) return;
    if (stat.kind != .file or stat.size == 0) return;

    var parser = archive.Parser.init(allocator, candidate.provider);
    var parsed = (streamFileIntoParser(state, file, generation, &parser, result, max_line_bytes) catch return) orelse return;
    // `errdefer`가 아니라 `defer`+플래그다. 이 함수는 `void`를 돌려주므로 `errdefer`는 **결코 실행되지
    // 않는다** — 취소나 할당 실패로 빠져나갈 때마다 요약 하나가 통째로 샜다(도크를 닫을 때 발생하는
    // 실사용 경로다).
    var moved_to_result = false;
    defer if (!moved_to_result) parsed.deinit(allocator);

    if (cancelled(state, generation)) return;
    canonicalizeParsedCwd(state, &parsed);
    cacheParsed(state, candidate, &parsed);
    const path = allocator.dupe(u8, candidate.open_path) catch return;
    result.records.append(allocator, .{ .parsed = parsed, .source_path = path, .mtime_ns = candidate.mtime_ns, .inode = candidate.inode, .device = candidate.device, .subagent_count = candidate.subagent_count }) catch {
        allocator.free(path);
        return;
    };
    moved_to_result = true;
}

/// 파일을 64 KiB씩 읽어 개행으로 잘라 파서에 넘긴다. 청크 경계에 걸친 줄만 `pending`에 누적한다.
///
/// 취소 확인은 **청크 경계에서만** 한다 — 줄마다 확인하면 수십만 번 락을 잡아 main actor의
/// `takeResult`를 굶긴다.
fn streamFileIntoParser(
    state: *State,
    file: std.Io.File,
    generation: u64,
    parser: *archive.Parser,
    result: *Result,
    /// 한 줄의 상한. 제품은 항상 `max_line_bytes`를 넘긴다 — 파라미터인 것은 테스트가 수십 MB fixture
    /// 없이 상한 분기를 재현하기 위해서다.
    line_cap: usize,
) !?archive.Parsed {
    const allocator = state.allocator;
    const io = state.io;
    var buf: [read_chunk_bytes]u8 = undefined;
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(allocator);
    var offset: u64 = 0;
    var dropped_line = false;
    var worked_verdict = false;
    // 상한을 넘겨 버린 줄의 **나머지**를 다음 개행까지 건너뛴다. 이 상태가 없으면 버린 줄의 뒷부분이
    // 다음 청크에서 `pending`이 빈 채로 개행을 만나 **독립된 줄로 오인**된다.
    var skipping_rest_of_line = false;

    while (true) {
        // 읽기 실패는 partial로 올리지 않는다. 스캔 도중 파일이 지워지거나 잘리는 것은 정상이고,
        // 정상 동작이 상시 경고로 보이면 경고가 무의미해진다(§4). 진짜 누락인 요약 할당 실패는
        // 아래 `finish` 경로에서 표시한다.
        const n = file.readPositional(io, &.{&buf}, offset) catch return null;
        if (n == 0) break;
        offset += n;
        var rest: []const u8 = buf[0..n];
        while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
            const piece = rest[0..nl];
            rest = rest[nl + 1 ..];
            if (skipping_rest_of_line) {
                skipping_rest_of_line = false; // 버린 줄이 여기서 끝났다
                continue;
            }
            // 상한은 **붙이기 전에** 본다. 이 검사를 개행 없는 경로에만 두면 줄의 끝이 청크 안에 있는
            // 순간 `pending`이 상한 없이 커져 방어선이 실효를 잃는다.
            if (pending.items.len + piece.len > line_cap) {
                pending.clearRetainingCapacity();
                dropped_line = true;
                continue; // 줄이 여기서 끝났으니 건너뛸 나머지가 없다
            }
            if (pending.items.len == 0) {
                parser.consumeLine(piece);
            } else {
                pending.appendSlice(allocator, piece) catch {
                    pending.clearRetainingCapacity();
                    dropped_line = true;
                    continue;
                };
                parser.consumeLine(pending.items);
                pending.clearRetainingCapacity();
            }
        }
        if (rest.len > 0 and !skipping_rest_of_line) {
            if (pending.items.len + rest.len > line_cap) {
                // 손상 파일 방어. 그 줄만 버리고 **다음 개행까지 건너뛴 뒤** 다시 잇는다.
                pending.clearRetainingCapacity();
                dropped_line = true;
                skipping_rest_of_line = true;
            } else pending.appendSlice(allocator, rest) catch {
                pending.clearRetainingCapacity();
                dropped_line = true;
                skipping_rest_of_line = true;
            };
        }
        // Codex worker 조기 중단은 **경계를 지난 뒤 한 번만** 판정한다. 그 전에 판정하면
        // `첫=subagent 마지막=user`인 정상 세션을 잘못 버린다(실측 256개 중 118개).
        if (!worked_verdict and offset >= codex_worker_verdict_bytes) {
            worked_verdict = true;
            if (parser.isWorkerSoFar()) return null;
        }
        if (cancelled(state, generation)) return null;
    }
    // 마지막 줄에 개행이 없어도 값을 잃지 않는다(버리는 중이던 줄은 제외).
    if (pending.items.len > 0 and !skipping_rest_of_line) parser.consumeLine(pending.items);
    if (dropped_line) {
        result.partial = true;
    }
    return parser.finish() catch {
        // 요약 할당 실패도 누락이다 — 조용히 사라지지 않게 표시한다(§4).
        result.partial = true;
        return null;
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
    try std.testing.expectEqual(Outcome.retain_previous, result.outcome);
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
    try std.testing.expectEqual(Outcome.cancelled, result.outcome);
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

test "archive backend deinit releases a gated detached worker before allocator return" {
    var backend = try Backend.init(std.testing.allocator, std.testing.io);
    backend.setTestGate(true);
    const home = try std.testing.allocator.dupe(u8, "/nonexistent-maru-archive-home");
    try std.testing.expect(backend.submit(home, false));
    var spins: usize = 0;
    while (!backend.testGateReached() and spins < 1_000) : (spins += 1) {
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expect(backend.testGateReached());
    backend.deinit();
    try std.testing.expect(backend.state == null);
}

test "cancelled archive generation cannot publish a replacement snapshot" {
    var state = State{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer {
        for (state.results.items) |*result| result.deinit(std.testing.allocator);
        state.results.deinit(std.testing.allocator);
    }
    state.cancelled_generation = 9;
    var cancelled_result = Result{ .outcome = .completed };
    try std.testing.expect(!publish(&state, 9, &cancelled_result));
    try std.testing.expectEqual(@as(usize, 0), state.results.items.len);

    var latest_result = Result{ .outcome = .completed };
    try std.testing.expect(publish(&state, 10, &latest_result));
    try std.testing.expectEqual(@as(usize, 1), state.results.items.len);
}

// 세션 카드가 보이는 `서브에이전트 N`의 출처. 목록에는 서브에이전트 transcript를 넣지 않지만
// (§3 표: 하위 계층 재귀 금지) 그 개수는 부모 세션의 정보라 카드에 싣는다. **파일을 열지 않고
// 디렉터리 항목만 세므로** read budget과 무관하고, 파싱 방식이 바뀌어도 값이 정확하다.
test "Claude 서브에이전트 개수: 형제 디렉터리 항목만 세고 없으면 0" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // <project>/<uuid>.jsonl 과 그 형제 <project>/<uuid>/subagents/*.jsonl
    try tmp.dir.createDirPath(io, "project/sess-a/subagents");
    try tmp.dir.writeFile(io, .{ .sub_path = "project/sess-a.jsonl", .data = "{}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "project/sess-a/subagents/w1.jsonl", .data = "{}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "project/sess-a/subagents/w2.jsonl", .data = "{}\n" });
    // .jsonl이 아닌 항목과 디렉터리는 세지 않는다.
    try tmp.dir.writeFile(io, .{ .sub_path = "project/sess-a/subagents/notes.txt", .data = "x" });
    try tmp.dir.createDirPath(io, "project/sess-a/subagents/nested");
    // 서브에이전트를 안 돌린 세션.
    try tmp.dir.writeFile(io, .{ .sub_path = "project/sess-b.jsonl", .data = "{}\n" });
    // subagents 디렉터리가 비어 있는 세션.
    try tmp.dir.createDirPath(io, "project/sess-c/subagents");
    try tmp.dir.writeFile(io, .{ .sub_path = "project/sess-c.jsonl", .data = "{}\n" });

    var project = try tmp.dir.openDir(io, "project", .{ .iterate = true, .follow_symlinks = false });
    defer project.close(io);

    try std.testing.expectEqual(@as(u32, 2), countClaudeSubagents(io, &project, "sess-a.jsonl"));
    try std.testing.expectEqual(@as(u32, 0), countClaudeSubagents(io, &project, "sess-b.jsonl"));
    try std.testing.expectEqual(@as(u32, 0), countClaudeSubagents(io, &project, "sess-c.jsonl"));
    // 없는 세션과 stem이 빈 이름은 찾을 디렉터리가 없다. (호출자는 `.jsonl`로 끝나는 이름만 넘기므로
    // 확장자 없는 입력은 제품 경로에 없다 — `sess-a`를 그대로 stem으로 보는 것이 자연스러운 동작이다.)
    try std.testing.expectEqual(@as(u32, 0), countClaudeSubagents(io, &project, "missing.jsonl"));
    try std.testing.expectEqual(@as(u32, 0), countClaudeSubagents(io, &project, ".jsonl"));
}

// 상한을 넘긴 줄을 버릴 때 **그 줄의 나머지까지** 건너뛰는가. 건너뛰지 않으면 뒷부분이 다음 청크에서
// `pending`이 빈 채로 개행을 만나 독립된 줄로 오인된다 — 그 조각이 우연히 JSON 객체 모양이면 없는
// 레코드를 만들어낼 수 있다. 적대적 검증 1회차에서 찾았다.
/// 상한 초과 fixture를 만들어 스트리밍시킨다. `filler_bytes`가 상한을 얼마나 넘느냐에 따라 초과가
/// **개행이 있는 청크**에서 걸리는지(줄 끝이 보이는 경우) **개행 없는 청크**에서 걸리는지가 갈리며,
/// 둘은 서로 다른 분기다. 두 경우 모두 뒤따르는 정상 줄은 온전히 읽혀야 한다.
fn expectOversizedLineDropped(line_cap: usize, filler_bytes: usize) !void {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // 거대한 줄의 **뒤쪽이 유효한 JSON처럼 보이게** 한다. 버린 줄의 나머지를 건너뛰지 않으면 그 조각이
    // 독립된 줄로 파싱돼 sessionId가 잘못 잡힌다.
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(allocator);
    try big.appendSlice(allocator, "{\"filler\":\"");
    try big.appendNTimes(allocator, 'x', filler_bytes);
    try big.appendSlice(allocator, "\"}{\"sessionId\":\"leaked\",\"type\":\"user\",\"message\":{\"role\":\"user\",\"text\":\"침입\"}}\n");
    try big.appendSlice(allocator, "{\"sessionId\":\"real\",\"cwd\":\"/repo\",\"type\":\"user\",\"message\":{\"role\":\"user\",\"text\":\"정상 요청\"}}\n");
    try tmp.dir.writeFile(io, .{ .sub_path = "big.jsonl", .data = big.items });

    const file = try tmp.dir.openFile(io, "big.jsonl", .{});
    defer file.close(io);

    var state_storage: State = .{ .allocator = allocator, .io = io };
    var parser = archive.Parser.init(allocator, .claude);
    var result: Result = .{};
    defer result.deinit(allocator);
    // generation은 0이 아니어야 한다 — `State.cancelled_generation` 기본값이 0이라 0을 넘기면 첫 청크
    // 경계에서 취소로 판정된다.
    const parsed_opt = try streamFileIntoParser(&state_storage, file, 1, &parser, &result, line_cap);

    // 긴 줄을 버렸다는 사실이 남는다.
    try std.testing.expect(result.partial);
    // 그리고 버린 줄의 뒷부분("leaked")이 아니라 **그다음 정상 줄**만 읽혔다.
    var parsed = parsed_opt.?;
    defer parsed.deinit(allocator);
    try std.testing.expectEqualStrings("real", parsed.session_id);
    try std.testing.expectEqualStrings("정상 요청", parsed.summary);
}

// 줄의 끝(개행)이 초과를 감지한 그 청크 안에 있는 경우. 이 분기에 상한 검사가 없으면 `pending`이
// 상한과 무관하게 커져 방어선 자체가 무의미해진다.
test "스트리밍: 줄 끝이 같은 청크에 보여도 상한 초과 줄은 버린다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    // 줄 전체가 첫 청크(64 KiB) 안에 들어가므로 개행이 보이는 상태에서 초과가 걸린다.
    try expectOversizedLineDropped(1024, 2048);
}

// 초과가 개행 없는 청크에서 걸리는 경우. 버린 줄의 **나머지**를 다음 개행까지 건너뛰지 않으면 그 꼬리가
// 독립된 줄로 오인돼 "leaked"가 결과에 섞인다.
test "스트리밍: 상한 초과가 줄 중간에서 걸리면 그 줄의 나머지까지 건너뛴다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    // filler가 청크보다 커서 첫 개행을 만나기 전에 초과가 걸린다.
    try expectOversizedLineDropped(1024, read_chunk_bytes * 3);
}

// 요약(`Parsed`)은 파싱된 뒤 `result.records`로 넘어가기 전까지 이 함수가 소유한다. 그 사이 어느
// 할당이 실패해도 소유권이 공중에 뜨면 안 된다 — 예전 코드는 `void` 반환 함수에 `errdefer`를 걸어
// 두었고, `errdefer`는 error 반환에만 동작하므로 **한 번도 실행되지 않았다**. 실패 지점을 하나씩 옮겨
// 가며 전 구간을 훑는다.
test "appendCandidateFile: 어느 할당이 실패해도 요약이 새지 않는다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "s.jsonl", .data =
        \\{"sessionId":"s-1","cwd":"/repo","type":"user","message":{"role":"user","content":[{"type":"text","text":"요청"}]}}
        \\{"type":"assistant","message":{"role":"assistant","model":"m","content":[{"type":"text","text":"응답"}]}}
        \\
    });

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buf);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root_buf[0..root_len], "s.jsonl" });
    defer std.testing.allocator.free(path);
    const probe = try std.Io.Dir.cwd().openFile(io, path, .{ .follow_symlinks = false });
    const probe_stat = try probe.stat(io);
    const probe_device = openedDevice(probe);
    probe.close(io);

    const candidate: Candidate = .{
        .provider = .claude,
        .source_path = path,
        .open_path = path,
        .mtime_ns = probe_stat.mtime.nanoseconds,
        .size = probe_stat.size,
        .inode = probe_stat.inode,
        .device = probe_device,
        .subagent_count = 0,
    };

    var fail_index: usize = 0;
    while (fail_index < 48) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        var state: State = .{ .allocator = failing.allocator(), .io = io };
        var result: Result = .{};
        appendCandidateFile(&state, candidate, 1, &result);
        result.deinit(state.allocator);
        for (state.cache.items) |*entry| entry.deinit(state.allocator);
        state.cache.deinit(state.allocator);
        state.results.deinit(state.allocator);
        // 실패를 주입할 할당이 더 없으면 전 구간을 훑은 것이다.
        if (failing.has_induced_failure == false and fail_index > 0) break;
    }
}

// 정렬 키가 목록 순서를 정한다. 폴백 규칙이 깨지면 timestamp 없는 파일만 조용히 목록 끝으로 밀리거나
// (키 0) 엉뚱한 자리에 앉는다 — 눈으로 잡기 어려운 종류라 규칙을 그대로 고정한다.
test "정렬 키는 활동 시각을 쓰고, 없을 때만 mtime으로 폴백한다" {
    // 문자열 필드는 읽히지 않는다. deinit하지 않으므로 정적 리터럴로 채운다.
    const blank = archive.Parsed{
        .provider = .claude,
        .session_id = @constCast(""),
        .title = @constCast(""),
        .summary = @constCast(""),
        .cwd = @constCast(""),
        .model = @constCast(""),
        .message_count = 0,
        .verified_user = true,
    };
    const make = struct {
        fn record(base: archive.Parsed, activity_ns: i96, mtime_ns: i96) Record {
            var parsed = base;
            parsed.last_activity_ns = activity_ns;
            return .{ .parsed = parsed, .source_path = @constCast(""), .mtime_ns = mtime_ns, .inode = 0, .device = 0 };
        }
    };

    // 활동 시각이 있으면 mtime을 무시한다. mtime이 훨씬 최신이어도 그렇다 — 실측에서 mtime이 실제
    // 마지막 활동보다 144시간 앞선 파일이 있었다.
    const activity_wins = make.record(blank, 100, 999_999);
    try std.testing.expectEqual(@as(i96, 100), lastActivityNs(activity_wins));

    // 못 읽었을 때만 mtime을 쓴다.
    const fallback = make.record(blank, 0, 42);
    try std.testing.expectEqual(@as(i96, 42), lastActivityNs(fallback));

    // 두 종류가 섞여도 하나의 눈금으로 비교된다(둘 다 Unix epoch 나노초다).
    var records = [_]Record{
        make.record(blank, 0, 200), // 폴백만 있는 오래된 것
        make.record(blank, 500, 1), // 활동 시각이 가장 늦은 것
        make.record(blank, 0, 400), // 폴백만 있는 중간 것
        make.record(blank, 300, 999_999), // mtime은 최신이지만 활동은 세 번째
    };
    std.mem.sort(Record, &records, {}, newestFirst);
    try std.testing.expectEqual(@as(i96, 500), lastActivityNs(records[0]));
    try std.testing.expectEqual(@as(i96, 400), lastActivityNs(records[1]));
    try std.testing.expectEqual(@as(i96, 300), lastActivityNs(records[2]));
    try std.testing.expectEqual(@as(i96, 200), lastActivityNs(records[3]));
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
