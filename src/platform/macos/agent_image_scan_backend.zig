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
const context = maru.session.agent_image_context;

/// worker 가 만들어 main actor 로 넘기는 완료본. **소유가 통째로 이동한다** — 받은 쪽이 푼다.
pub const Result = struct {
    hits: std.ArrayList(index.Hit) = .empty,
    /// `hits` 와 **같은 순서·같은 길이**의 라벨. 「이 이미지가 무엇이었는지」(§2.2)를 스캔과 한 번에
    /// 만든다 — 필터가 **전부**의 라벨을 필요로 하는데, main actor 에서 읽으면 실측 40.2 ms 다.
    ///
    /// 길이가 어긋나면 라벨이 남의 이미지에 붙는다. 그래서 `hits` 를 건드리는 자리는 이것도 같이 건든다.
    labels: std.ArrayList(context.Label) = .empty,
    partial: bool = false,
    scanned_bytes: u64 = 0,
    scan_ns: u64 = 0,
    /// 이 결과를 만든 요청. main actor 가 「지금 보고 있는 것」과 대조해 늦게 온 것을 버린다.
    generation: u64 = 0,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        self.hits.deinit(allocator);
        self.labels.deinit(allocator);
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
    /// 마지막으로 띄운 워커. **detach 하지 않는다** — 떼어 놓으면 그 스레드가 들고 있는 할당(경로 사본)이
    /// 세션보다 오래 살 수 있고, 그러면 테스트의 누수 검사가 그것을 «샜다» 로 보고한다. 실제로 CI 에서
    /// `dupe` 한 경로가 leaked 로 잡혔다(로컬은 경합이라 통과했다).
    ///
    /// 한 번에 하나만 도므로(`inflight`) 핸들도 하나면 된다. 다음 제출 전과 `deinit` 에서 join 한다.
    worker_thread: ?std.Thread = null,

    fn release(self: *State) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        if (self.ready) |*r| r.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

/// 워커가 훑을 **파일 묶음**. 재개 세션이면 부모까지다(계약 §3.3).
///
/// 경로 사본을 든다 — 워커는 `AppSession` 을 모른다. `Chain` 은 고정 배열이라 그대로 복사한다.
const Job = struct { state: *State, chain: index.Chain, generation: u64 };

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
        // **워커를 거두고 나간다.** 남겨 두면 그 스레드의 경로 사본이 우리 할당자보다 오래 살아
        // 누수로 보고된다(그리고 실제로 그 메모리를 아무도 안 푼다).
        //
        // 먼저 취소를 걸어 두므로 기다리는 시간은 **청크 하나**다 — 스캔 루프가 64 KiB 마다 취소를
        // 보기 때문이다. 1.6 GB 를 끝까지 기다리지 않는다.
        if (self.state.worker_thread) |t| {
            self.state.cancelled_upto.store(std.math.maxInt(u64), .release);
            t.join();
            self.state.worker_thread = null;
        }
        self.state.cancelled_upto.store(std.math.maxInt(u64), .release);
        self.state.release();
        self.* = undefined;
    }

    /// 새 스캔을 건다. 돌려주는 것은 **이 요청의 generation** 이다 — 호출자가 그것을 들고 있다가
    /// `take` 로 온 결과와 대조해 **늦게 온 것을 버린다**(소스가 그 사이 바뀌었을 수 있다).
    ///
    /// 이미 도는 job 이 있으면 새로 띄우지 않고 취소만 걸고 `null` 을 돌려준다 — 3.6 초짜리를 둘 돌리면
    /// CPU 만 두 배 먹는다. 호출자는 다음 tick 에 다시 건다.
    pub fn submit(self: *Backend, chain: index.Chain) ?u64 {
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

        // 앞 워커가 남아 있으면 먼저 거둔다. `inflight` 가 false 라 그 스레드는 이미 끝났거나
        // 끝나는 중이므로 여기서 멈추는 시간은 사실상 0 이다.
        if (state.worker_thread) |t| {
            t.join();
            state.worker_thread = null;
        }
        const job = state.allocator.create(Job) catch {
            finish(state, null);
            return null;
        };
        job.* = .{ .state = state, .chain = chain, .generation = generation };
        _ = state.refs.fetchAdd(1, .monotonic);
        const thread = std.Thread.spawn(.{}, worker, .{job}) catch {
            _ = state.refs.fetchSub(1, .acq_rel);
            state.allocator.destroy(job);
            finish(state, null);
            return null;
        };
        state.worker_thread = thread;
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

/// 그 hit 의 라벨을 **두 조각만** 읽어 만든다 — 이미지 줄의 base64 앞부분과 그 앞선 줄들.
/// base64 는 수 MB 라 절대 안 읽는다. 실패는 **빈 라벨**이다(없는 설명을 지어내지 않는다).
fn readLabel(io: std.Io, file: std.Io.File, hit: index.Hit, allocator: std.mem.Allocator) context.Label {
    const prefix_len: usize = @intCast(@min(
        hit.data_offset -| hit.line_offset,
        @as(u64, context.max_prefix_bytes),
    ));
    const back: u64 = @min(hit.line_offset, @as(u64, context.max_prev_line_bytes));
    const buf = allocator.alloc(u8, prefix_len + @as(usize, @intCast(back))) catch return .{};
    defer allocator.free(buf);

    var prev: []const u8 = &.{};
    if (back > 0) {
        const window = buf[0..@intCast(back)];
        if (readAllAt(io, file, window, hit.line_offset - back)) {
            prev = if (window.len > 0 and window[window.len - 1] == '\n') window[0 .. window.len - 1] else window;
        }
    }
    var prefix: []const u8 = &.{};
    if (prefix_len > 0) {
        const slot = buf[@intCast(back)..];
        if (readAllAt(io, file, slot, hit.line_offset)) prefix = slot;
    }
    return context.label(prefix, prev);
}

fn readAllAt(io: std.Io, file: std.Io.File, dest: []u8, offset: u64) bool {
    var got: usize = 0;
    while (got < dest.len) {
        const n = file.readPositional(io, &.{dest[got..]}, offset + got) catch return false;
        if (n == 0) return false;
        got += n;
    }
    return true;
}

fn worker(job: *Job) void {
    const state = job.state;
    defer {
        state.allocator.destroy(job);
        state.release();
    }

    var result: Result = .{ .generation = job.generation };
    var ok = true;
    var scanner: index.StreamScanner = .{};
    defer scanner.deinit(state.allocator);

    const io = state.io;
    const started_ns: i128 = std.Io.Clock.real.now(io).nanoseconds;
    // **파일마다 처음부터 다시 센다.** 오프셋은 파일 절대값이고, 어느 파일인지는 `Hit.file_index` 가
    // 든다 — 그 둘을 섞으면 디코드가 엉뚱한 바이트를 읽는다.
    scan: for (0..job.chain.len) |fi| {
        const path = job.chain.get(fi) orelse continue;
        // 파일이 바뀌면 스캐너의 이월 버퍼도 새로 시작해야 한다 — 앞 파일의 잘린 꼬리가 다음 파일의
        // 첫 줄에 이어 붙으면 없던 이미지가 생긴다.
        scanner.deinit(state.allocator);
        scanner = .{};
        const first_hit = result.hits.items.len;

        const file = std.Io.Dir.cwd().openFile(io, path, .{
            .mode = .read_only,
            .follow_symlinks = false,
            .allow_directory = false,
        }) catch {
            result.partial = true;
            continue; // 부모가 지워졌을 수 있다 — 그 파일만 건너뛴다
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
                break;
            };
            if (n == 0) break;
            offset += n;
            scanner.feed(state.allocator, buf[0..n], &result.hits) catch {
                result.partial = true;
                break;
            };
        }
        result.scanned_bytes += offset;
        // 이 파일에서 나온 것들에 **누가 준 오프셋인지** 표시한다.
        for (result.hits.items[first_hit..]) |*h| h.file_index = @intCast(fi);
        if (scanner.partial) result.partial = true;
    }
    // ── 라벨 패스 ────────────────────────────────────────────────────────────────────────────
    // 스캔이 끝난 뒤 **같은 워커에서** 만든다. 파일별로 한 번만 열고 positional read 로 창을 읽는다 —
    // hit 마다 열면 151 번 여는 셈이다.
    if (ok) labels: {
        result.labels.ensureTotalCapacity(state.allocator, result.hits.items.len) catch {
            result.partial = true;
            break :labels;
        };
        var open_index: ?usize = null;
        var open_file: ?std.Io.File = null;
        defer if (open_file) |f| f.close(io);

        for (result.hits.items) |hit| {
            if (state.cancelled_upto.load(.acquire) >= job.generation) {
                ok = false;
                break :labels;
            }
            // 파일이 바뀔 때만 다시 연다(체인은 앞에서부터 순서대로 나온다).
            if (open_index == null or open_index.? != hit.file_index) {
                if (open_file) |f| f.close(io);
                open_file = null;
                open_index = hit.file_index;
                const path = job.chain.get(hit.file_index) orelse {
                    result.labels.appendAssumeCapacity(.{});
                    continue;
                };
                open_file = std.Io.Dir.cwd().openFile(io, path, .{
                    .mode = .read_only,
                    .follow_symlinks = false,
                    .allow_directory = false,
                }) catch null;
            }
            const file = open_file orelse {
                result.labels.appendAssumeCapacity(.{});
                continue;
            };
            result.labels.appendAssumeCapacity(readLabel(io, file, hit, state.allocator));
        }
    }

    const ended_ns: i128 = std.Io.Clock.real.now(io).nanoseconds;
    result.scan_ns = @intCast(@max(0, ended_ns - started_ns));

    if (!ok) {
        result.deinit(state.allocator);
        finish(state, null);
        return;
    }
    finish(state, result);
}
