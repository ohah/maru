//! 이미지 갤러리 스캔 워커(IG1-e) — 계약 [docs/agent-image-gallery.md](../../../docs/agent-image-gallery.md) §4.1.1.
//!
//! **왜 워커인가 — 실측이 동기 스캔을 기각했다.** 제품 스캐너로 최악 파일을 재니 1,680 MB / **3,599.9 ms**
//! (467 MB/s)였다. 프레임 예산 16.7 ms 의 **216배**다. 「전형 파일은 3 ms 라 괜찮다」로 넘길 수 없는 것이,
//! 이 기계의 **활성 세션이 실제로 1.68 GB** 였기 때문이다(계약 §9).
//!
//! 구조는 [아카이브 스캐너](agent_session_archive_backend.zig)를 그대로 따른다 — refcount 로 detached
//! worker 를 붙들고, generation 으로 늦게 온 결과를 버리고, main actor 는 완료본만 가져간다.
//! 다른 점은 대상이 **파일 하나**라는 것뿐이라(디렉터리 순회가 없다) 후보 수집·캐시가 없다.
//!
//! **worker 는 `AppSession` 을 모른다.** 넘기는 것은 allocator·io·경로 사본·generation 뿐이다 —
//! 세션이 먼저 죽어도 use-after-free 가 나지 않는다.

const std = @import("std");
const maru = @import("maru");

const index = maru.session.agent_image_index;

/// worker 가 만들어 main actor 로 넘기는 완료본. **소유가 통째로 이동한다** — 받은 쪽이 푼다.
pub const Result = struct {
    hits: std.ArrayList(index.Hit) = .empty,
    partial: bool = false,
    scanned_bytes: u64 = 0,
    scan_ns: u64 = 0,
    /// 이 결과를 만든 요청. main actor 가 「지금 보고 있는 것」과 대조해 늦게 온 것을 버린다.
    generation: u64 = 0,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        self.hits.deinit(allocator);
        self.* = .{};
    }
};

const State = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    refs: std.atomic.Value(usize) = .init(1),

    /// 아직 안 가져간 완료본. 새 결과가 오면 옛것을 버린다 — 목록은 늘 **최신 하나**다.
    ready: ?Result = null,
    inflight: bool = false,
    next_generation: u64 = 1,
    /// 이 값 **이하**의 generation 은 취소됐다. worker 가 청크마다 락 없이 읽으므로 atomic 이다.
    ///
    /// **`next_generation` 이 아니라 `next_generation - 1` 을 넣는다.** `next_generation` 은 «다음에 발급할»
    /// 번호라 그것을 넣으면 **바로 뒤에 거는 요청까지 취소된다** — `refresh` 가 `cancel` 다음에 `submit`
    /// 하므로 모든 작업이 자기 자신을 취소하고, 결과가 영영 안 온다(실제로 그렇게 걸렸다).
    cancelled_upto: std.atomic.Value(u64) = .init(0),
    shutting_down: std.atomic.Value(bool) = .init(false),

    fn release(self: *State) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        if (self.ready) |*r| r.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

const Job = struct { state: *State, path: []u8, generation: u64 };

pub const Backend = struct {
    state: *State,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !Backend {
        const state = try allocator.create(State);
        state.* = .{ .allocator = allocator, .io = io };
        return .{ .state = state };
    }

    /// 세션이 놓는다. **detached worker 가 아직 돌 수 있으므로 여기서 파괴하지 않는다** — refcount 가
    /// 마지막 하나를 파괴한다. 도는 job 에는 취소를 건다(3.6 초짜리를 끝까지 돌릴 이유가 없다).
    pub fn deinit(self: *Backend) void {
        self.state.shutting_down.store(true, .release);
        self.state.cancelled_upto.store(std.math.maxInt(u64), .release);
        self.state.release();
        self.* = undefined;
    }

    /// 새 스캔을 건다. 돌려주는 것은 **이 요청의 generation** 이다 — 호출자가 그것을 들고 있다가
    /// `take` 로 온 결과와 대조해 **늦게 온 것을 버린다**(소스가 그 사이 바뀌었을 수 있다).
    ///
    /// 이미 도는 job 이 있으면 새로 띄우지 않고 취소만 걸고 `null` 을 돌려준다 — 3.6 초짜리를 둘 돌리면
    /// CPU 만 두 배 먹는다. 호출자는 다음 tick 에 다시 건다.
    pub fn submit(self: *Backend, path: []const u8) ?u64 {
        const state = self.state;
        if (state.shutting_down.load(.acquire)) return null;

        state.mutex.lockUncancelable(state.io);
        if (state.inflight) {
            // 도는 것을 취소만 하고 물러난다. 다음 tick 이 다시 건다.
            const upto = state.next_generation -| 1;
            state.mutex.unlock(state.io);
            state.cancelled_upto.store(upto, .release);
            return null;
        }
        const generation = state.next_generation;
        state.next_generation += 1;
        state.inflight = true;
        state.mutex.unlock(state.io);

        const owned = state.allocator.dupe(u8, path) catch {
            finish(state, null);
            return null;
        };
        const job = state.allocator.create(Job) catch {
            state.allocator.free(owned);
            finish(state, null);
            return null;
        };
        job.* = .{ .state = state, .path = owned, .generation = generation };
        _ = state.refs.fetchAdd(1, .monotonic);
        const thread = std.Thread.spawn(.{}, worker, .{job}) catch {
            _ = state.refs.fetchSub(1, .acq_rel);
            state.allocator.free(owned);
            state.allocator.destroy(job);
            finish(state, null);
            return null;
        };
        thread.detach();
        return generation;
    }

    /// 완료본이 있으면 **소유를 가져간다**. 없으면 null. main actor 가 tick 에서 부른다.
    pub fn take(self: *Backend) ?Result {
        const state = self.state;
        state.mutex.lockUncancelable(state.io);
        defer state.mutex.unlock(state.io);
        const out = state.ready;
        state.ready = null;
        return out;
    }

    /// 지금 도는 스캔이 있는가. 「아직 세는 중」을 화면에 말하기 위한 것이다 —
    /// 3.6 초 동안 「이미지가 없습니다」라고 거짓말하지 않으려면 이 구분이 필요하다.
    pub fn busy(self: *const Backend) bool {
        const state = self.state;
        state.mutex.lockUncancelable(state.io);
        defer state.mutex.unlock(state.io);
        return state.inflight;
    }

    /// 도는 스캔을 취소한다(뷰를 떠났을 때). 결과가 와도 generation 으로 버려진다.
    pub fn cancel(self: *Backend) void {
        const state = self.state;
        state.mutex.lockUncancelable(state.io);
        // **이미 발급한 것까지만** 취소한다(`next_generation - 1`). `next_generation` 을 넣으면 바로 뒤에
        // 거는 요청까지 죽어 결과가 영영 안 온다 — `refresh` 가 `cancel` 다음에 `submit` 하기 때문이다.
        const upto = state.next_generation -| 1;
        state.mutex.unlock(state.io);
        state.cancelled_upto.store(upto, .release);
    }
};

fn finish(state: *State, result: ?Result) void {
    state.mutex.lockUncancelable(state.io);
    defer state.mutex.unlock(state.io);
    state.inflight = false;
    if (result) |r| {
        // 새 결과가 오면 아직 안 가져간 옛것을 버린다 — 늘 최신 하나만 든다.
        if (state.ready) |*old| old.deinit(state.allocator);
        state.ready = r;
    }
}

fn worker(job: *Job) void {
    const state = job.state;
    defer {
        state.allocator.free(job.path);
        state.allocator.destroy(job);
        state.release();
    }

    var result: Result = .{ .generation = job.generation };
    var ok = true;
    var scanner: index.StreamScanner = .{};
    defer scanner.deinit(state.allocator);

    const io = state.io;
    const started_ns: i128 = std.Io.Clock.real.now(io).nanoseconds;
    scan: {
        const file = std.Io.Dir.cwd().openFile(io, job.path, .{
            .mode = .read_only,
            .follow_symlinks = false,
            .allow_directory = false,
        }) catch {
            result.partial = true;
            break :scan;
        };
        defer file.close(io);

        var buf: [64 * 1024]u8 = undefined;
        var offset: u64 = 0;
        while (true) {
            // **청크마다 취소를 본다.** 뷰를 떠났는데 3.6 초를 끝까지 돌 이유가 없다.
            if (state.cancelled_upto.load(.acquire) >= job.generation) {
                ok = false;
                break :scan;
            }
            const n = file.readPositional(io, &.{&buf}, offset) catch {
                result.partial = true;
                break :scan;
            };
            if (n == 0) break;
            offset += n;
            scanner.feed(state.allocator, buf[0..n], &result.hits) catch {
                result.partial = true;
                break :scan;
            };
        }
        result.scanned_bytes = offset;
    }
    const ended_ns: i128 = std.Io.Clock.real.now(io).nanoseconds;
    result.scan_ns = @intCast(@max(0, ended_ns - started_ns));
    if (scanner.partial) result.partial = true;

    if (!ok) {
        result.deinit(state.allocator);
        finish(state, null);
        return;
    }
    finish(state, result);
}
