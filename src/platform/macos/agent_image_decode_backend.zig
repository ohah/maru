//! 이미지 갤러리 **디코드 워커**(IG3-d) — 계약 [docs/agent-image-gallery.md](../../../docs/agent-image-gallery.md) §5.2.
//!
//! **왜 워커인가.** 디코드는 장당 ~20 ms 다(실측, 2830×1662). 프레임 예산이 16.7 ms 이므로 한 장만 풀어도
//! 넘고, 격자 24칸이면 480 ms 다. IG3-c2 는 「tick 당 한 장」으로 버텼지만 그것은 **각 프레임이 20 ms 를
//! 쓴다**는 뜻이라 스크롤·타이핑이 그동안 끊긴다. 여기서 main actor 는 요청만 걸고 완료본을 가져간다.
//!
//! 구조는 [스캔 워커](agent_image_scan_backend.zig)와 같다 — refcount·generation·완료본 하나.
//! 다른 점은 **작업 단위가 파일이 아니라 이미지 한 장**이라, 어느 칸의 것인지(`hit_index`)를 함께 실어
//! 돌려준다는 것이다.
//!
//! **한 번에 한 장만 푼다.** 여러 스레드를 띄우면 24칸이 빨리 차지만 CPU 를 그만큼 먹고, 사용자가 뷰를
//! 떠나면 그 일이 전부 버려진다. 순차로도 480 ms 면 격자가 눈앞에서 차오르는 속도다.

const std = @import("std");
const maru = @import("maru");

const image_decode = @import("image_decode.zig");
const image_scale = maru.session.image_scale;

/// 동시에 푸는 최대 장수.
///
/// **근거는 실측이다**(2026-08-31): 장당 평균 4.36 ms 이고 프레임 예산이 16.7 ms 라, 넷이면 프레임당
/// 넷 — 측정한 워커 상한(초당 229 장)과 맞는다. 스레드 부대비용은 회당 0.039 ms 로 무시할 수준이다.
pub const max_inflight: usize = 4;

/// worker 가 main actor 로 넘기는 완료본. **픽셀 소유가 통째로 이동한다** — 받은 쪽이 푼다.
pub const Result = struct {
    /// 인덱스의 몇 번째 이미지인가. 격자 자리와 잇는 유일한 키다.
    hit_index: usize = 0,
    width: u32 = 0,
    height: u32 = 0,
    /// RGBA8. **길이 0 이면 「못 풀었다」**는 뜻이고, 그 칸은 그리지 않는다(자리는 차지한다).
    pixels: []u8 = &.{},
    generation: u64 = 0,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
        self.* = .{};
    }
};

const State = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    refs: std.atomic.Value(usize) = .init(1),

    /// 아직 안 가져간 완료본들. **버리지 않는다** — 예전에는 슬롯이 하나라 새 결과가 오면 옛것을
    /// 버렸고(`old.deinit`), 그래서 여러 장을 동시에 풀 수 없었다.
    ready: std.ArrayList(Result) = .empty,
    /// 지금 도는 워커 수. 예전에는 `bool` 이었다 — 「한 번에 하나」가 **워커가 생기기 전** 설계였고,
    /// 워커가 붙은 뒤에도 남아 처리량을 틱 주기(초당 60 장)로 묶고 있었다.
    inflight: usize = 0,
    next_generation: u64 = 1,
    /// 이 값 **이하**의 generation 은 취소됐다. 스캔 워커와 같은 규율이며 같은 함정을 피한다 —
    /// `next_generation` 을 넣으면 바로 뒤에 거는 요청까지 죽는다.
    cancelled_upto: std.atomic.Value(u64) = .init(0),
    shutting_down: std.atomic.Value(bool) = .init(false),
    /// 띄운 워커들. **detach 하지 않는다** — 떼어 놓으면 그 스레드가 들고 있는 할당(경로 사본)이
    /// 세션보다 오래 살 수 있고, 그러면 테스트의 누수 검사가 그것을 «샜다» 로 보고한다. 실제로 CI 에서
    /// `dupe` 한 경로가 leaked 로 잡혔다(로컬은 경합이라 통과했다).
    ///
    /// **고정 배열이고 끝났는지를 함께 든다.** 늘어나는 배열 + 「도는 것이 없을 때만 전부 join」으로
    /// 두었더니 `submit` 이 `inflight` 를 올린 **뒤에** 거두는 바람에 조건이 영영 참이 안 돼 핸들이
    /// 무한히 쌓였다(적대적 검증). 상한이 `max_inflight` 이므로 자리를 재사용하면 그 문제가 없고,
    /// 각 워커가 끝나며 자기 자리를 표시하면 **끝난 것만 골라** join 할 수 있다.
    slots: [max_inflight]Slot = [_]Slot{.{}} ** max_inflight,

    fn release(self: *State) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        for (self.ready.items) |*r| r.deinit(self.allocator);
        self.ready.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// 쓸 수 있는 슬롯 하나. 끝난 스레드는 여기서 거둔다(join 은 즉시 돌아온다).
    ///
    /// **`null` 이 올 수 있다.** 워커는 `finish`(`inflight--`) 를 부른 **뒤에** `done` 을 세우므로,
    /// 그 사이에는 `inflight` 가 상한 아래인데 슬롯이 다 안 끝난 것으로 보인다. 순서를 뒤집으면
    /// 안 된다 — `done` 을 먼저 세우면 뮤텍스를 쥔 채 join 하는 이쪽과 `finish` 에서 그 뮤텍스를
    /// 기다리는 워커가 **교착**한다. 그 틈에 걸린 제출은 한 틱 미뤄질 뿐이라 이대로 둔다.
    ///
    /// 도는 스레드는 절대 join 하지 않는다(그러면 프레임이 그 자리에서 멈춘다).
    fn freeSlot(self: *State) ?usize {
        for (&self.slots, 0..) |*slot, i| {
            if (slot.thread == null) return i;
            if (!slot.done.load(.acquire)) continue;
            slot.thread.?.join(); // 이미 끝났다
            slot.thread = null;
            slot.done.store(false, .release);
            return i;
        }
        return null;
    }
};

/// 워커 슬롯 하나. `done` 은 **워커가 마지막에** 세우고 main actor 가 읽는다 — 그래야
/// 도는 스레드를 join 해 프레임이 멈추는 일이 없다.
const Slot = struct {
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
};

const Job = struct {
    /// 이 워커가 쓴 슬롯. 끝나며 여기에 «끝났다» 를 세운다.
    slot: usize = 0,
    state: *State,
    /// 경로 사본 — worker 는 `AppSession` 을 모른다.
    path: []u8,
    data_offset: u64,
    data_len: u32,
    target_side: u32,
    hit_index: usize,
    generation: u64,
};

pub const Backend = struct {
    state: *State,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !Backend {
        const state = try allocator.create(State);
        state.* = .{ .allocator = allocator, .io = io };
        return .{ .state = state };
    }

    pub fn deinit(self: *Backend) void {
        self.state.shutting_down.store(true, .release);
        // **워커를 거두고 나간다.** 남겨 두면 그 스레드의 경로 사본이 우리 할당자보다 오래 살아
        // 누수로 보고된다(그리고 실제로 그 메모리를 아무도 안 푼다).
        //
        // 기다리는 시간은 **한 장 디코드**로 한정된다(실측 평균 4.4 ms). 이 워커는 시작에서만 취소를
        // 보므로 이미 도는 것은 그 한 장을 끝낸다 — 중간에 끊을 수는 없지만 상한이 작다. 아직 시작
        // 안 한 것은 이 취소를 보고 그냥 빠진다.
        self.state.cancelled_upto.store(std.math.maxInt(u64), .release);
        // 슬롯을 전부 거둔다. 넷이 **동시에** 도니 벽시계로 기다리는 시간은 한 장 몫에 가깝다.
        for (&self.state.slots) |*slot| {
            if (slot.thread) |t| {
                t.join();
                slot.thread = null;
            }
        }
        self.state.release();
        self.* = undefined;
    }

    /// 한 장을 풀라고 건다. 상한(`max_inflight`)에 닿았으면 `null` — 호출자가 다음 tick 에 다시 건다.
    /// **취소를 걸지 않는다**(스캔과 다른 점): 도는 장은 어차피 곧 끝나고, 그 결과도 쓸모가 있다.
    pub fn submit(
        self: *Backend,
        path: []const u8,
        data_offset: u64,
        data_len: u32,
        target_side: u32,
        hit_index: usize,
    ) ?u64 {
        const state = self.state;
        if (state.shutting_down.load(.acquire)) return null;

        state.mutex.lockUncancelable(state.io);
        // **상한까지 동시에 건다.** 예전에는 「하나라도 돌거나 안 가져간 결과가 있으면」 물러났는데,
        // 그것이 처리량을 틱 주기로 묶었다. 이제는 `max_inflight` 만큼 겹쳐 건다.
        if (state.inflight >= max_inflight) {
            state.mutex.unlock(state.io);
            return null;
        }
        const generation = state.next_generation;
        state.next_generation += 1;
        state.inflight += 1;
        state.mutex.unlock(state.io);

        // 쓸 슬롯을 잡는다. 못 잡으면(`finish` 와 `done` 사이의 틈) 이 한 장을 미룬다 — 되돌리고
        // `null` 을 내면 호출자가 다음 틱에 다시 건다.
        state.mutex.lockUncancelable(state.io);
        const slot = state.freeSlot();
        state.mutex.unlock(state.io);
        if (slot == null) {
            finish(state, null);
            return null;
        }
        const owned = state.allocator.dupe(u8, path) catch {
            finish(state, null);
            return null;
        };
        const job = state.allocator.create(Job) catch {
            state.allocator.free(owned);
            finish(state, null);
            return null;
        };
        job.* = .{
            .state = state,
            .path = owned,
            .data_offset = data_offset,
            .data_len = data_len,
            .target_side = target_side,
            .hit_index = hit_index,
            .generation = generation,
            .slot = slot.?,
        };
        _ = state.refs.fetchAdd(1, .monotonic);
        const thread = std.Thread.spawn(.{}, worker, .{job}) catch {
            _ = state.refs.fetchSub(1, .acq_rel);
            state.allocator.free(owned);
            state.allocator.destroy(job);
            finish(state, null);
            return null;
        };
        state.mutex.lockUncancelable(state.io);
        state.slots[slot.?].thread = thread;
        state.mutex.unlock(state.io);
        return generation;
    }

    /// 완료본이 있으면 **소유를 가져간다**.
    /// 완료본 하나를 가져간다. **호출자는 `null` 이 올 때까지 반복해 비운다** — 한 번만 부르면
    /// 나머지가 다음 틱까지 기다려 처리량이 다시 틱에 묶인다.
    pub fn take(self: *Backend) ?Result {
        const state = self.state;
        state.mutex.lockUncancelable(state.io);
        defer state.mutex.unlock(state.io);
        if (state.ready.items.len == 0) return null;
        return state.ready.orderedRemove(0);
    }

    /// 도는 것과 아직 안 가져간 것을 버린다(소스가 갈렸을 때). 결과가 와도 generation 으로 버려진다.
    pub fn cancel(self: *Backend) void {
        const state = self.state;
        state.mutex.lockUncancelable(state.io);
        const upto = state.next_generation -| 1;
        for (state.ready.items) |*r| r.deinit(state.allocator);
        state.ready.clearRetainingCapacity();
        state.mutex.unlock(state.io);
        state.cancelled_upto.store(upto, .release);
    }
};

fn finish(state: *State, result: ?Result) void {
    state.mutex.lockUncancelable(state.io);
    defer state.mutex.unlock(state.io);
    if (state.inflight > 0) state.inflight -= 1;
    if (result) |r| {
        var owned = r;
        // **버리지 않는다.** 예전에는 슬롯이 하나라 새 결과가 옛것을 덮었고, 그래서 여러 장을
        // 동시에 풀 수 없었다. 담지 못하면 그 한 장만 버린다(그 칸은 다음에 다시 걸린다).
        state.ready.append(state.allocator, owned) catch owned.deinit(state.allocator);
    }
}

fn worker(job: *Job) void {
    const slot = job.slot;
    const state = job.state;
    defer {
        state.allocator.free(job.path);
        state.allocator.destroy(job);
        // **«끝났다» 를 `release` 보다 먼저 세운다.** main actor 는 이것을 보고 join 하므로 도는
        // 스레드를 join 해 프레임이 멈추는 일이 없다. 순서가 중요하다 — `release` 는 마지막
        // 참조면 `State` 를 **해제**하므로, 뒤에 두면 해제된 메모리에 쓴다(defer 는 선언 역순이라
        // 따로 두면 정확히 그 순서가 된다).
        state.slots[slot].done.store(true, .release);
        state.release();
    }

    // 취소됐으면 시작도 하지 않는다 — 20 ms 를 버릴 이유가 없다.
    if (state.cancelled_upto.load(.acquire) >= job.generation) {
        finish(state, null);
        return;
    }

    var result: Result = .{ .hit_index = job.hit_index, .generation = job.generation };
    decode: {
        const io = state.io;
        const file = std.Io.Dir.cwd().openFile(io, job.path, .{
            .mode = .read_only,
            .follow_symlinks = false,
            .allow_directory = false,
        }) catch break :decode;
        defer file.close(io);

        const b64 = state.allocator.alloc(u8, job.data_len) catch break :decode;
        defer state.allocator.free(b64);
        var got: usize = 0;
        while (got < b64.len) {
            const n = file.readPositional(io, &.{b64[got..]}, job.data_offset + got) catch break :decode;
            if (n == 0) break :decode; // 파일이 그 사이 잘렸다
            got += n;
        }

        const dec = std.base64.standard.Decoder;
        const raw_len = dec.calcSizeForSlice(b64) catch break :decode;
        const raw = state.allocator.alloc(u8, raw_len) catch break :decode;
        defer state.allocator.free(raw);
        dec.decode(raw, b64) catch break :decode;

        const size = image_decode.probeSize(raw) catch break :decode;
        // **상한을 못 맞추면 안 푼다.** 억지로 올리면 텍스처 생성에서 프로세스가 abort 한다(계약 §5.3).
        const fit = image_scale.fitToThumbnail(
            size.width,
            size.height,
            job.target_side,
            image_scale.default_max_side,
            image_scale.default_max_pixels,
        ) orelse break :decode;
        const img = image_decode.decode(state.allocator, raw, fit.subsample) catch break :decode;
        result.width = img.width;
        result.height = img.height;
        result.pixels = img.pixels; // 소유 이동
    }
    finish(state, result);
}
