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

    ready: ?Result = null,
    inflight: bool = false,
    next_generation: u64 = 1,
    /// 이 값 **이하**의 generation 은 취소됐다. 스캔 워커와 같은 규율이며 같은 함정을 피한다 —
    /// `next_generation` 을 넣으면 바로 뒤에 거는 요청까지 죽는다.
    cancelled_upto: std.atomic.Value(u64) = .init(0),
    shutting_down: std.atomic.Value(bool) = .init(false),

    fn release(self: *State) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        if (self.ready) |*r| r.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

const Job = struct {
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
        self.state.cancelled_upto.store(std.math.maxInt(u64), .release);
        self.state.release();
        self.* = undefined;
    }

    /// 한 장을 풀라고 건다. 이미 도는 것이 있으면 `null` — 호출자가 다음 tick 에 다시 건다.
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
        if (state.inflight or state.ready != null) {
            // 아직 안 가져간 완료본이 있으면 새로 걸지 않는다 — 덮어쓰면 그 칸이 영영 안 찬다.
            state.mutex.unlock(state.io);
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
        job.* = .{
            .state = state,
            .path = owned,
            .data_offset = data_offset,
            .data_len = data_len,
            .target_side = target_side,
            .hit_index = hit_index,
            .generation = generation,
        };
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

    /// 완료본이 있으면 **소유를 가져간다**.
    pub fn take(self: *Backend) ?Result {
        const state = self.state;
        state.mutex.lockUncancelable(state.io);
        defer state.mutex.unlock(state.io);
        const out = state.ready;
        state.ready = null;
        return out;
    }

    pub fn busy(self: *const Backend) bool {
        const state = self.state;
        state.mutex.lockUncancelable(state.io);
        defer state.mutex.unlock(state.io);
        return state.inflight;
    }

    /// 도는 것과 아직 안 가져간 것을 버린다(소스가 갈렸을 때). 결과가 와도 generation 으로 버려진다.
    pub fn cancel(self: *Backend) void {
        const state = self.state;
        state.mutex.lockUncancelable(state.io);
        const upto = state.next_generation -| 1;
        if (state.ready) |*r| {
            r.deinit(state.allocator);
            state.ready = null;
        }
        state.mutex.unlock(state.io);
        state.cancelled_upto.store(upto, .release);
    }
};

fn finish(state: *State, result: ?Result) void {
    state.mutex.lockUncancelable(state.io);
    defer state.mutex.unlock(state.io);
    state.inflight = false;
    if (result) |r| {
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
