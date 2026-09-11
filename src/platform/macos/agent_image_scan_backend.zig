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
const builtin = @import("builtin");
const maru = @import("maru");
const ssh_upload = @import("ssh_upload.zig");

const index = maru.session.agent_image_index;
const context = maru.session.agent_image_context;
const wire = maru.session.remote_activity_wire;

/// 원격 세션의 왕복에 필요한 것 — ControlMaster 소켓과 ssh 목적지(RAV3).
///
/// **문자열은 호출자가 소유하고 job 수명 동안 살아 있어야 한다.** 워커가 백그라운드에서 읽는다.
pub const RemoteTarget = struct {
    ctl: []const u8,
    dest: []const u8,
};

/// worker 가 만들어 main actor 로 넘기는 완료본. **소유가 통째로 이동한다** — 받은 쪽이 푼다.
pub const Result = struct {
    hits: std.ArrayList(index.Hit) = .empty,
    /// `hits` 와 **같은 순서·같은 길이**의 라벨. 「이 이미지가 무엇이었는지」(§2.2)를 스캔과 한 번에
    /// 만든다 — 필터가 **전부**의 라벨을 필요로 하는데, main actor 에서 읽으면 실측 40.2 ms 다.
    ///
    /// 길이가 어긋나면 라벨이 남의 이미지에 붙는다. 그래서 `hits` 를 건드리는 자리는 이것도 같이 건든다.
    labels: std.ArrayList(context.Label) = .empty,
    partial: bool = false,
    /// 종류별로 나눈 「다 못 봤다」 — 활동만 잘렸는데 이미지 필터에서 그 문구를 내면 거짓말이다.
    image_partial: bool = false,
    activity_partial: bool = false,
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
const Job = struct {
    state: *State,
    chain: index.Chain,
    generation: u64,
    /// 원격이면 그 목적지. **null 이 로컬이다** — 이 하나가 워커의 갈림을 정한다.
    remote: ?OwnedRemote = null,
};

/// job 이 **소유하는** 원격 목적지 사본. 세션이 먼저 죽어도 워커가 안전하게 읽는다(이 파일의
/// 머리말 규율 — worker 는 `AppSession` 을 모른다).
const OwnedRemote = struct {
    ctl: []u8,
    dest: []u8,

    fn deinit(self: *OwnedRemote, allocator: std.mem.Allocator) void {
        allocator.free(self.ctl);
        allocator.free(self.dest);
    }
};

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
    /// 원격 스캔을 건다 — `remote` 가 null 이면 로컬이다(RAV3).
    ///
    /// ⚠️ **슬롯은 로컬과 같은 하나를 쓴다.** 계획 §6.2·열린 질문 ④ 가 정한 「자기 상한 1」이 이
    /// 구조에서 저절로 선다 — `inflight` 가 하나라 원격 왕복이 도는 동안 새 job 이 안 뜬다.
    pub fn submit(self: *Backend, chain: index.Chain, remote: ?RemoteTarget) ?u64 {
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
        var owned: ?OwnedRemote = null;
        if (remote) |r| {
            const ctl = state.allocator.dupe(u8, r.ctl) catch {
                state.allocator.destroy(job);
                finish(state, null);
                return null;
            };
            const dest = state.allocator.dupe(u8, r.dest) catch {
                state.allocator.free(ctl);
                state.allocator.destroy(job);
                finish(state, null);
                return null;
            };
            owned = .{ .ctl = ctl, .dest = dest };
        }
        job.* = .{ .state = state, .chain = chain, .generation = generation, .remote = owned };
        _ = state.refs.fetchAdd(1, .monotonic);
        const thread = std.Thread.spawn(.{}, worker, .{job}) catch {
            _ = state.refs.fetchSub(1, .acq_rel);
            // **원격 사본도 여기서 푼다**(적대적 N2). 워커가 안 떴으므로 그 `defer` 가 안 돈다 —
            // 로컬 갈래에는 없던 자리이고, job 이 값만 들던 시절의 `destroy` 하나로는 모자란다.
            if (job.remote) |*r| r.deinit(state.allocator);
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
/// 활동(도구 호출)의 라벨. **이미지보다 단순하다** — 스캐너가 이미 대상의 자리를 정했으므로
/// (활동 뷰 계약 §2.2) 그 구간만 읽어 다듬는다. 이미지처럼 앞선 줄들을 뒤질 일이 없다.
///
/// 시각은 **아직 안 붙인다**(`time_s = 0` = 「모른다」 = 안 그린다). 활동 레코드에서 timestamp 의
/// 자리는 이미지 줄과 다르고, 그것을 확인하지 않은 채 이미지 경로를 재사용하면 **남의 시각**이
/// 붙는다. 시각은 결과 요약과 함께 AV2 가 붙인다.
fn readActivityLabel(io: std.Io, file: std.Io.File, hit: index.Hit, allocator: std.mem.Allocator) context.Label {
    if (hit.data_len == 0) return .{};
    const buf = allocator.alloc(u8, hit.data_len) catch return .{};
    defer allocator.free(buf);
    if (!readAllAt(io, file, buf, hit.data_offset)) return .{};
    var out = context.activityLabel(buf, hit.activity == .read);
    out.time_s = readActivityTime(io, file, hit);
    return out;
}

/// 이 호출이 적힌 **시각**. 스캐너가 **자리**를 적어 뒀으므로(`Hit.time_rel`) 그 자리에서 창 하나만
/// 읽는다 — 이미지처럼 payload 앞뒤를 뒤질 필요가 없다(provider 마다 반대편이라 그 방식이 안 통한다).
///
/// 못 읽으면 0(모른다)이고, 그때 화면은 시각을 **안 그린다** — 지어내지 않는다.
fn readActivityTime(io: std.Io, file: std.Io.File, hit: index.Hit) i64 {
    if (hit.time_rel == 0) return 0;
    var buf: [activity_time_window]u8 = undefined;
    const got = readUpTo(io, file, &buf, hit.line_offset + hit.time_rel);
    if (got == 0) return 0;
    return context.timestampSeconds(buf[0..got]);
}

/// 시각 값 하나가 들어갈 창 — **단일 출처는 `agent_image_context`** 다(원격 헬퍼가 같은 값을 써야
/// 한다. 두 벌이면 한쪽만 늘었을 때 시각이 조용히 사라진다).
const activity_time_window: usize = context.timestamp_window_bytes;

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
    var out = context.label(prefix, prev);
    out.time_s = readTime(io, file, hit, prefix, allocator);
    return out;
}

/// 이 이미지가 적힌 **시각**. 못 찾으면 0(모름) — 지어내지 않는다.
///
/// **창을 앞뒤 둘 다 본다**(IG12-a 실측): Claude 는 payload 뒤, Codex 는 앞이다. 앞창은 라벨이 이미
/// 읽어 둔 `prefix` 에 들어 있을 때가 많아 그것부터 보고, 없을 때만 payload 바로 앞을 따로 읽는다.
fn readTime(
    io: std.Io,
    file: std.Io.File,
    hit: index.Hit,
    prefix: []const u8,
    allocator: std.mem.Allocator,
) i64 {
    // ① payload **뒤** — Claude. 파일 끝에 걸릴 수 있어 「읽힌 만큼」을 쓴다.
    {
        var buf: [context.time_window_after]u8 = undefined;
        const got = readUpTo(io, file, &buf, hit.data_offset +| hit.data_len);
        if (got > 0) {
            // **줄 끝에서 자른다.** 안 자르면 창이 다음 항목으로 넘어가 **남의 시각**을 읽는다 —
            // 실측 Codex 이미지 줄의 2.4%(313/13,200)가 payload 뒤 256 B 안에서 끝난다.
            const window = buf[0..got];
            const line_end = std.mem.indexOfScalar(u8, window, '\n') orelse window.len;
            const t = context.timestampSeconds(window[0..line_end]);
            if (t != 0) return t;
        }
    }
    // ② payload **앞** — Codex. 라벨이 읽어 둔 앞부분에 이미 있으면 읽지 않는다.
    {
        const t = context.timestampSeconds(prefix);
        if (t != 0) return t;
    }
    // ③ 그래도 없으면 payload 바로 앞 창을 따로 읽는다(긴 줄이라 `prefix` 가 그 자리까지 못 간 경우).
    const back: u64 = @min(hit.data_offset -| hit.line_offset, @as(u64, context.time_window_before));
    if (back == 0) return 0;
    const win = allocator.alloc(u8, @intCast(back)) catch return 0;
    defer allocator.free(win);
    if (!readAllAt(io, file, win, hit.data_offset - back)) return 0;
    return context.timestampSeconds(win);
}

/// `readAllAt` 과 달리 **짧게 읽혀도 성공**이다 — 파일 끝에 닿는 창에 쓴다. 읽은 바이트 수를 준다.
fn readUpTo(io: std.Io, file: std.Io.File, dest: []u8, offset: u64) usize {
    var got: usize = 0;
    while (got < dest.len) {
        const n = file.readPositional(io, &.{dest[got..]}, offset + got) catch break;
        if (n == 0) break;
        got += n;
    }
    return got;
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
        if (job.remote) |*r| r.deinit(state.allocator);
        state.allocator.destroy(job);
        state.release();
    }

    // **원격은 저쪽이 훑는다**(RAV3). 자리도 라벨도 wire 로 오므로 이 아래의 로컬 스캔·라벨 패스를
    // 통째로 지나친다 — §2.1 의 「저쪽 오프셋은 이쪽 syscall 에 안 간다」가 여기서 지켜진다.
    if (job.remote) |r| {
        const result = remoteScan(state.allocator, job.chain, r, job.generation);
        finish(state, result);
        return;
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
        // **파일 번호는 스캐너가 찍는다**(`StreamScanner.file_index`). 예전에는 여기서 자리를
        // 잡아 두고 스캔 뒤에 찍었는데, 퇴출이 배열을 앞으로 당기면 그 자리가 낡아 이 파일의
        // 앞부분이 번호를 못 받았다 — 실측 프로브에서 앞 파일 51 개 중 50 개가 버려지자 이 파일의
        // 앞 50 개가 첫 파일 번호(0)로 남았다.
        scanner = .{ .file_index = @intCast(fi) };

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
        if (scanner.partial) result.partial = true;
        if (scanner.image_partial) result.image_partial = true;
        if (scanner.activity_partial) result.activity_partial = true;
    }
    // ── 라벨 패스 ────────────────────────────────────────────────────────────────────────────
    // 스캔이 끝난 뒤 **같은 워커에서** 만든다. 파일별로 한 번만 열고 positional read 로 창을 읽는다 —
    // hit 마다 열면 151 번 여는 셈이다.
    if (ok) labels: {
        // **`partial` 을 세우지 않는다.** 그 깃발은 「이미지를 다 못 봤다」는 뜻이고, 여기서 실패한
        // 것은 라벨(덧붙임)뿐이다. 세우면 이미지를 다 읽고도 「다 읽지 못했습니다」라고 말하게 된다.
        result.labels.ensureTotalCapacity(state.allocator, result.hits.items.len) catch break :labels;
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
            result.labels.appendAssumeCapacity(if (hit.kind.isImage())
                readLabel(io, file, hit, state.allocator)
            else
                readActivityLabel(io, file, hit, state.allocator));
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

// ── 원격 스캔(RAV3) ─────────────────────────────────────────────────────────────────────────────
//
// **전송과 매핑을 가른다**(RF2b 가 세운 그 모양). 전송은 얇은 껍데기가 하고, wire→`Result` 매핑은
// 순수 함수라 ssh 없이 단위로 겨눈다.

/// 원격에서 헬퍼를 돌려 wire 를 받아 `Result` 로 옮긴다.
///
/// **여기는 백그라운드 스레드다** — `std.Io` 를 안 만지고(`ssh_upload` 규율) **로컬 파일시스템도 안
/// 만진다**. 이 함수 안에 open/stat 이 생기면 그것이 계약 §2.1 위반이고, 경계 게이트가 그 자리를 센다.
///
/// ⚠️ **취소를 못 본다 — 로컬과의 비대칭**(적대적 N3). 로컬 워커는 청크마다 `cancelled_upto` 를
/// 읽어 3.6 초짜리를 곧바로 접지만, 이쪽은 `runRemoteCapped` 한 번에 갇힌다(전송이 블로킹이다).
/// 그래서 pane 을 옮겨도 **왕복이 끝날 때까지 새 스캔이 안 걸린다**(`inflight` 가 하나다).
///
/// **정확성은 안 깨진다** — 늦게 온 결과는 `generation` 대조에서 버려진다. 잃는 것은 **지연**뿐이고
/// (실측 3.82 GB 에서 6.3 초), 그 대가로 전송 층을 안 건드린다. 취소 가능한 전송은 RAV7 의 일이다.
fn remoteScan(allocator: std.mem.Allocator, chain: index.Chain, remote: OwnedRemote, generation: u64) Result {
    if (comptime builtin.os.tag != .macos) unreachable; // submit 이 이미 막는다

    // 체인의 **첫 파일**만 본다 — 부모 rollout 을 저쪽에서 푸는 것은 RAV4 다.
    const head = chain.head();
    if (head.len == 0) return .{ .generation = generation, .partial = true };

    var out: []u8 = &.{};
    const code = ssh_upload.runRemoteCapped(
        allocator,
        remote.ctl,
        remote.dest,
        ssh_upload.activity_script,
        &.{head},
        wire.max_wire_bytes,
        &out,
    ) catch {
        // 전송 자체를 못 세웠다(fork/pipe). wire 가 없으니 매핑도 없다 — 「못 봤다」로 돌려준다.
        return .{ .generation = generation, .partial = true };
    };
    defer allocator.free(out);
    return remoteResultFromWire(allocator, out, code, generation);
}

/// wire 바이트 → `Result` 의 **순수 매핑**(RAV3). OS 중립이라 어느 호스트에서든 단위로 돈다.
///
/// 「다 봤다」는 **완결된 정상 답**일 때만이다: 파서가 꼬리까지 봤고(`complete`), 원격 오류가 없고,
/// 종료 코드가 0 일 때. 그 밖은 전부 `partial` 이다 — 원격 오류·비정상 종료(127 = 헬퍼가 없다)·
/// 잘림·오독. 「비었다」와 「못 봤다」를 가르는 것이 계약 §2.2 이고, 그 갈림이 여기서 정해진다.
///
/// ⚠️ **부분성 플래그는 원격이 준 것을 그대로 싣되 `or` 로만 더한다.** 원격이 「다 봤다」고 해도
/// 전송이 잘렸으면 우리는 못 본 것이다.
fn remoteResultFromWire(allocator: std.mem.Allocator, bytes: []const u8, exit_code: c_int, generation: u64) Result {
    var result: Result = .{ .generation = generation };
    var parser = wire.Parser.init(bytes);
    var malformed = false;
    var said_error = false;

    while (parser.next() catch blk: {
        malformed = true;
        break :blk null;
    }) |event| switch (event) {
        .file => {},
        .flags => |flags| {
            result.partial = result.partial or flags.partial;
            result.image_partial = result.image_partial or flags.image_partial;
            result.activity_partial = result.activity_partial or flags.activity_partial;
            result.scanned_bytes = flags.scanned_bytes;
        },
        .record => |rec| {
            result.hits.append(allocator, rec.hit) catch {
                malformed = true;
                break;
            };
            result.labels.append(allocator, rec.label) catch {
                // **길이가 어긋나면 라벨이 남의 활동에 붙는다**(`Result` 주석) — 방금 넣은 자리를 뺀다.
                _ = result.hits.pop();
                malformed = true;
                break;
            };
        },
        .remote_error => said_error = true,
    };

    if (malformed or said_error or exit_code != 0 or !parser.complete()) result.partial = true;
    return result;
}

const testing = std.testing;

/// 판정자용 wire 를 짓는다 — 헬퍼가 내는 것과 같은 순서(머리말·파일·플래그·레코드·꼬리).
fn buildWire(buf: []u8, flags: wire.ScanFlags, records: []const wire.Record) []const u8 {
    var n = wire.appendHeader(buf, 0).?;
    n = wire.appendFile(buf, n, 0, "/home/u/.claude/projects/p/s.jsonl").?;
    n = wire.appendFlags(buf, n, flags).?;
    for (records) |rec| n = wire.appendRecord(buf, n, rec).?;
    n = wire.appendTail(buf, n, records.len).?;
    return buf[0..n];
}

fn sampleRecord() wire.Record {
    var label: wire.Label = .{ .time_s = 1_757_500_000 };
    const text = "zig build test";
    @memcpy(label.buf[0..text.len], text);
    label.len = text.len;
    return .{
        .hit = .{
            .line_offset = 4096,
            .data_offset = 4196,
            .data_len = 14,
            .kind = .claude_tool_use,
            .mime = .unknown,
            .activity = .exec,
            .file_index = 0,
        },
        .label = label,
    };
}

test "원격 매핑: 완결된 답은 자리와 라벨을 그대로 싣고 「다 봤다」로 둔다" {
    var buf: [4096]u8 = undefined;
    const bytes = buildWire(&buf, .{ .scanned_bytes = 261_533_353 }, &.{sampleRecord()});

    var result = remoteResultFromWire(testing.allocator, bytes, 0, 7);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(u64, 7), result.generation);
    try testing.expectEqual(@as(usize, 1), result.hits.items.len);
    try testing.expectEqual(@as(usize, 1), result.labels.items.len);
    try testing.expectEqualStrings("zig build test", result.labels.items[0].text());
    try testing.expectEqual(@as(i64, 1_757_500_000), result.labels.items[0].time_s);
    try testing.expectEqual(@as(u64, 261_533_353), result.scanned_bytes);
    try testing.expect(!result.partial);
}

test "원격 매핑: 원격이 「다 못 봤다」고 하면 그대로 전한다" {
    var buf: [4096]u8 = undefined;
    const bytes = buildWire(&buf, .{ .activity_partial = true }, &.{sampleRecord()});

    var result = remoteResultFromWire(testing.allocator, bytes, 0, 1);
    defer result.deinit(testing.allocator);

    try testing.expect(result.activity_partial);
    try testing.expect(!result.image_partial);
}

test "원격 매핑: 종료 코드가 0 이 아니면 「못 봤다」다 — 127 은 헬퍼가 없다는 뜻이다" {
    var buf: [4096]u8 = undefined;
    const bytes = buildWire(&buf, .{}, &.{sampleRecord()});

    var result = remoteResultFromWire(testing.allocator, bytes, 127, 1);
    defer result.deinit(testing.allocator);

    try testing.expect(result.partial);
}

test "원격 매핑: 꼬리가 없으면 「못 봤다」다 — 잘린 답을 온전한 척 읽지 않는다" {
    var buf: [4096]u8 = undefined;
    var n = wire.appendHeader(&buf, 0).?;
    n = wire.appendFile(&buf, n, 0, "/a/b.jsonl").?;
    n = wire.appendFlags(&buf, n, .{}).?;
    n = wire.appendRecord(&buf, n, sampleRecord()).?;
    // 꼬리를 안 붙인다(전송 상한에서 잘린 모양).

    var result = remoteResultFromWire(testing.allocator, buf[0..n], 0, 1);
    defer result.deinit(testing.allocator);

    try testing.expect(result.partial);
    try testing.expectEqual(@as(usize, 1), result.hits.items.len); // 본 것은 남긴다
}

test "원격 매핑: 원격 오류는 「비었다」가 아니라 「못 봤다」다" {
    var buf: [1024]u8 = undefined;
    var n = wire.appendHeader(&buf, 0).?;
    n = wire.appendRemoteError(&buf, n, "open failed: FileNotFound").?;

    var result = remoteResultFromWire(testing.allocator, buf[0..n], 0, 1);
    defer result.deinit(testing.allocator);

    try testing.expect(result.partial);
    try testing.expectEqual(@as(usize, 0), result.hits.items.len);
}

test "원격 매핑: 자리와 라벨의 길이는 언제나 같다" {
    var buf: [8192]u8 = undefined;
    const recs = [_]wire.Record{ sampleRecord(), sampleRecord(), sampleRecord() };
    const bytes = buildWire(&buf, .{}, &recs);

    var result = remoteResultFromWire(testing.allocator, bytes, 0, 1);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(result.hits.items.len, result.labels.items.len);
    try testing.expectEqual(@as(usize, 3), result.hits.items.len);
}
