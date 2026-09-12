//! 본문 검색 워커(BS1) — 계약 [docs/agent-activity-view.md](../../../docs/agent-activity-view.md) §2.1.1.
//!
//! **왜 워커인가 — 실측이 동기 검색을 기각했다.** 라벨만 보는 지금 검색은 세션의 **2.9%** 만 본다
//! (라벨 3.1 MB · 명령 전문 58.4 MB · 결과 전문 45.3 MB). 나머지를 보려면 가장 큰 세션에서 **17.7 MB**
//! 를 읽어 풀어야 하고, 그것은 프레임 예산 16.7 ms 안에 절대 안 들어간다.
//!
//! **파일 전체를 안 훑는다.** 인덱스가 이미 자리를 안다(`Hit.cmd_rel` · `ResultSummary.body.offset`) —
//! 그 조각만 읽으면 **파일의 12.0%** 다(실측 821 MB 중 99 MB). 그래서 `Enter` 한 번의 대가가 초가
//! 아니라 수백 ms 다.
//!
//! 구조는 [스캔 워커](agent_image_scan_backend.zig)를 그대로 따른다 — refcount 로 워커를 붙들고,
//! generation 으로 늦게 온 결과를 버리고, main actor 는 완료본만 가져간다. 워커는 `AppSession` 을
//! 모른다: 넘기는 것은 allocator·io·경로 사본·검색어 사본·읽을 자리 목록뿐이다.
//!
//! ⚠️ **`deinit` 이 워커를 거둔다**(detach 하지 않는다). 남겨 두면 그 스레드가 든 사본이 우리
//! 할당자보다 오래 살아 누수로 보고되고, `tests/boundary/detached_worker_quiesce_axis.zig` 가 바로
//! 그 규율을 잰다.

const std = @import("std");
const maru = @import("maru");

const index = maru.session.agent_image_index;
const context = maru.session.agent_image_context;

/// 조각 하나에서 읽어 볼 최대 바이트. **실측이 정했다**(2026-09-09, 최근 60 세션 · 명령 61,528 ·
/// 결과 60,442): 명령은 중앙 354 B · p99 7.9 KB · **최대 44.5 KB**, 결과는 중앙 318 B · p99 6.2 KB ·
/// **최대 46.8 KB** 다. 64 KiB 면 실측 조각을 **전부 통째로** 덮고, 8 KiB 로 줄여도 읽는 양은
/// 0.1 MB 아래로만 준다 — 아낄 것이 없으니 「덜 본 조각」을 안 만드는 쪽을 고른다.
///
/// 펼침의 상한(`agent_activity.max_detail_bytes` = 8 KiB)과 **다른 값인 것이 맞다.** 펼침은 화면에
/// 그릴 만큼만 읽으면 되지만, 검색은 「있나 없나」라 끝까지 봐야 답이 참이다.
/// 🔥 **단일 출처는 wire 다**(RAV8b). 원격 헬퍼가 같은 값으로 읽어야 「원격과 로컬이 같은 것을
/// 보여 준다」가 선다(계약 §2.3) — 두 곳에 손으로 두면 한쪽만 바뀌고, 그 차이는 「끝까지 못 봤다」의
/// **경계가 갈리는** 것이라 같은 파일에서 다른 답이 나온다(적대적 Y3).
pub const max_probe_bytes: usize = maru.session.remote_activity_wire.max_probe_bytes;

/// 한 호출에서 **어디를 읽을 것인가**. main actor 가 인덱스에서 뽑아 넘긴다.
pub const Probe = struct {
    /// 이 결과를 되짚을 **키**. 「`Hit` 배열의 몇 번째」가 아니라 파일 안에서 변하지 않는 값이다 —
    /// 배열은 퇴출과 화면의 뒤집기로 움직이므로(이 스택에서 이미 셋을 그렇게 만들었다) 자리를
    /// 값으로 들면 넷째 remap 이 생긴다.
    data_offset: u64,
    /// 명령 전문의 시작(파일 절대). 0 이면 읽지 않는다.
    cmd_offset: u64 = 0,
    /// **호출 입력(`input`) 객체**의 자리(§2.1.1). 0 이면 없다.
    ///
    /// `cmd_offset` 이 보는 것은 라벨이 고른 **한 조각**이라 같은 `input` 안의 다른 필드가 두 층
    /// 어디에도 안 걸린다 — 실측 `input` 85.5 MB 중 **26.2%(11.2 MB)** 가 그 사각이었고 그중
    /// `Write.content` 가 7.56 MB 다.
    input_offset: u64 = 0,
    /// 결과 본문의 시작(파일 절대). 0 이면 읽지 않는다.
    body_offset: u64 = 0,
    /// 그 본문이 **배열**인가(Codex `output`) — 참이면 원소들의 `text` 를 이어 읽는다.
    /// 스캐너가 이미 판정한 사실을 그대로 나른다(`ResultSummary.body.is_array`).
    body_is_array: bool = false,
    file: u8 = 0,
};

/// 검색어가 걸린 호출 하나. **어디서 맞았는지**까지 든다 — 「내가 친 말이 명령에 있었나 결과에
/// 있었나」를 못 가르면 사용자는 다음 검색어를 고를 수 없다(계약 §2.1.1).
pub const Match = struct {
    data_offset: u64,
    file: u8 = 0,
    in_command: bool = false,
    in_result: bool = false,
};

/// `(file, data_offset)` 오름차순. main actor 가 이분 탐색으로 되짚는다.
pub fn lessThan(_: void, a: Match, b: Match) bool {
    if (a.file != b.file) return a.file < b.file;
    return a.data_offset < b.data_offset;
}

/// worker 가 만들어 main actor 로 넘기는 완료본. **소유가 통째로 이동한다** — 받은 쪽이 푼다.
pub const Result = struct {
    /// `lessThan` 순으로 정렬돼 있다.
    matches: std.ArrayList(Match) = .empty,
    /// 이 결과를 만든 요청. main actor 가 「지금 물어본 것」과 대조해 늦게 온 것을 버린다.
    generation: u64 = 0,
    read_bytes: u64 = 0,
    search_ns: u64 = 0,
    /// **다 못 봤다.** 파일을 못 열었거나, 조각이 `max_probe_bytes` 에 걸려 끝까지 안 읽혔다.
    /// 「걸린 것이 없다」와 **다른 사실**이라 따로 든다.
    partial: bool = false,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        self.matches.deinit(allocator);
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
    /// 이 값 **이하**의 generation 은 취소됐다. 워커가 락 없이 읽으므로 atomic 이다.
    /// `next_generation` 이 아니라 `next_generation - 1` 인 이유는 스캔 워커의 주석과 같다 —
    /// 다음에 발급할 번호를 넣으면 뒤이어 거는 요청이 자기 자신을 취소한다.
    cancelled_upto: std.atomic.Value(u64) = .init(0),
    shutting_down: std.atomic.Value(bool) = .init(false),
    /// 마지막으로 띄운 워커. **detach 하지 않는다**(파일 첫머리 ⚠️).
    worker_thread: ?std.Thread = null,

    fn release(self: *State) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        if (self.ready) |*r| r.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

/// 워커가 가져가는 것. **전부 사본이다** — 세션이 먼저 죽어도 use-after-free 가 안 난다.
const Job = struct {
    state: *State,
    chain: index.Chain,
    /// 검색어 사본. 워커가 소유하고 워커가 푼다.
    query: []u8,
    /// 읽을 자리 목록. 워커가 소유하고 워커가 푼다.
    probes: []Probe,
    generation: u64,
};

pub const Backend = struct {
    state: *State,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !Backend {
        const state = try allocator.create(State);
        state.* = .{ .allocator = allocator, .io = io };
        return .{ .state = state };
    }

    /// 세션이 놓는다. **워커를 거두고 나간다** — 먼저 취소를 걸어 두므로 기다리는 시간은
    /// 조각 하나(64 KiB)다.
    pub fn deinit(self: *Backend) void {
        self.state.shutting_down.store(true, .release);
        if (self.state.worker_thread) |t| {
            self.state.cancelled_upto.store(std.math.maxInt(u64), .release);
            t.join();
            self.state.worker_thread = null;
        }
        self.state.cancelled_upto.store(std.math.maxInt(u64), .release);
        self.state.release();
        self.* = undefined;
    }

    /// 본문 검색을 건다. 돌려주는 것은 **이 요청의 generation** 이다.
    ///
    /// `query` 와 `probes` 는 **여기서 복사한다** — 호출자의 것은 다음 프레임에 사라진다.
    /// 이미 도는 것이 있으면 취소를 걸고 `null` 을 준다(호출자가 다시 건다).
    pub fn submit(
        self: *Backend,
        chain: index.Chain,
        query: []const u8,
        probes: []const Probe,
    ) ?u64 {
        const state = self.state;
        if (state.shutting_down.load(.acquire)) return null;
        // 빈 검색어는 「전부」라 훑을 것이 없고, 볼 자리가 없으면 워커를 띄울 이유가 없다.
        if (query.len == 0 or probes.len == 0) return null;

        state.mutex.lockUncancelable(state.io);
        if (state.inflight) {
            const upto = state.next_generation -| 1;
            state.mutex.unlock(state.io);
            state.cancelled_upto.store(upto, .release);
            return null;
        }
        const generation = state.next_generation;
        state.next_generation += 1;
        state.inflight = true;
        state.mutex.unlock(state.io);

        // 앞 워커가 남아 있으면 먼저 거둔다. `inflight` 가 false 였으므로 사실상 0 이다.
        if (state.worker_thread) |t| {
            t.join();
            state.worker_thread = null;
        }

        const query_copy = state.allocator.dupe(u8, query) catch {
            finish(state, null);
            return null;
        };
        const probe_copy = state.allocator.dupe(Probe, probes) catch {
            state.allocator.free(query_copy);
            finish(state, null);
            return null;
        };
        const job = state.allocator.create(Job) catch {
            state.allocator.free(probe_copy);
            state.allocator.free(query_copy);
            finish(state, null);
            return null;
        };
        job.* = .{
            .state = state,
            .chain = chain,
            .query = query_copy,
            .probes = probe_copy,
            .generation = generation,
        };
        _ = state.refs.fetchAdd(1, .monotonic);
        const thread = std.Thread.spawn(.{}, worker, .{job}) catch {
            _ = state.refs.fetchSub(1, .acq_rel);
            state.allocator.destroy(job);
            state.allocator.free(probe_copy);
            state.allocator.free(query_copy);
            finish(state, null);
            return null;
        };
        state.worker_thread = thread;
        return generation;
    }

    /// 완료본이 있으면 **소유를 가져간다**. 없으면 null.
    pub fn take(self: *Backend) ?Result {
        const state = self.state;
        state.mutex.lockUncancelable(state.io);
        defer state.mutex.unlock(state.io);
        const out = state.ready;
        state.ready = null;
        return out;
    }

    /// 지금 훑는 중인가. 화면이 「본문을 훑는 중」이라고 말하는 근거다 — 수백 ms 동안
    /// 「찾은 것이 없습니다」라고 하면 거짓말이다.
    pub fn busy(self: *const Backend) bool {
        const state = self.state;
        state.mutex.lockUncancelable(state.io);
        defer state.mutex.unlock(state.io);
        return state.inflight;
    }

    /// 도는 검색을 취소한다(검색어가 바뀌었다 · 뷰를 떠났다).
    pub fn cancel(self: *Backend) void {
        const state = self.state;
        state.mutex.lockUncancelable(state.io);
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
        if (state.ready) |*old| old.deinit(state.allocator);
        state.ready = r;
    }
}

/// 조각 하나를 읽어 **풀어서** 검색어와 대조한다.
///
/// **푼 뒤에 본다.** 트랜스크립트의 본문은 JSON 문자열이라 줄바꿈이 `\n` **두 바이트**로 적혀
/// 있는데, 날것으로 대조하면 사용자가 친 「a b」가 `a\nb` 에 안 걸리고 `\u` 로 적힌 글자는 통째로
/// 어긋난다. 푸는 규칙은 펼침(`unescapeBlock`)과 **같은 하나**를 쓴다 — 두 벌이 되면 「검색에는
/// 걸리는데 펼치면 없는」 자리가 생긴다.
/// 프로브가 가리키는 자리의 **모양**. 세 가지가 각각 다른 푸는 규칙을 쓴다.
const ProbeShape = enum {
    /// 값 하나(`"…"`) — 명령·대상.
    value,
    /// 배열 안 `text` 들을 이어 읽는다(Codex `output`).
    text_array,
    /// 객체 안 **모든 문자열 값**을 이어 읽는다(호출 입력 `input`).
    object,
};

fn probeMatches(
    io: std.Io,
    file: std.Io.File,
    offset: u64,
    query: []const u8,
    raw: []u8,
    out: []u8,
    read_bytes: *u64,
    /// 이 자리를 **어떻게 읽나**.
    shape: ProbeShape,
    /// 상한(`max_probe_bytes`)에 걸려 **끝까지 못 본** 조각이 있었나. 실측상 0 건이지만(최대
    /// 46.8 KB < 64 KiB) 그 사실을 안 들면 화면이 「없다」와 「못 봤다」를 섞는다 — 이 뷰의 계약
    /// §2 가 금하는 바로 그 혼동이고, 여기가 그것을 아는 유일한 자리다(적대적 2회차).
    truncated: *bool,
) bool {
    if (offset == 0) return false;
    var got: usize = 0;
    while (got < raw.len) {
        const n = file.readPositional(io, &.{raw[got..]}, offset + got) catch break;
        if (n == 0) break;
        got += n;
    }
    if (got == 0) return false;
    read_bytes.* +|= got;
    const block = switch (shape) {
        .value => context.unescapeBlock(out, raw[0..got]),
        .text_array => context.unescapeTextArray(out, raw[0..got]),
        .object => context.unescapeObjectValues(out, raw[0..got]),
    };
    // 값의 끝을 못 봤다 = 이 조각은 **끝까지 안 봤다**. 뒤에 검색어가 있었을 수 있다.
    if (!block.complete) truncated.* = true;
    if (block.len == 0) return false;
    return context.matches(out[0..block.len], query);
}

/// 취소를 몇 조각마다 보나. 조각 하나가 최대 64 KiB 라 **4 MB 마다**다 — 검색어를 한 글자 더
/// 쳤을 때 앞 검색이 멈추는 데 걸리는 시간이 그만큼이다.
const cancel_check_stride: usize = 64;

fn worker(job: *Job) void {
    const state = job.state;
    defer {
        state.allocator.free(job.probes);
        state.allocator.free(job.query);
        state.allocator.destroy(job);
        state.release();
    }

    var result: Result = .{ .generation = job.generation };
    const io = state.io;
    const started_ns: i128 = std.Io.Clock.real.now(io).nanoseconds;

    const raw = state.allocator.alloc(u8, max_probe_bytes) catch {
        finish(state, null);
        return;
    };
    defer state.allocator.free(raw);
    // 푼 결과는 날것보다 길어질 수 없다(`\n` 두 바이트 → 한 바이트, `\uXXXX` 여섯 → 최대 넉 바이트).
    const out = state.allocator.alloc(u8, max_probe_bytes) catch {
        finish(state, null);
        return;
    };
    defer state.allocator.free(out);

    var ok = true;
    var open_index: ?u8 = null;
    var open_file: ?std.Io.File = null;
    defer if (open_file) |f| f.close(io);

    for (job.probes, 0..) |probe, i| {
        if (i % cancel_check_stride == 0 and state.cancelled_upto.load(.acquire) >= job.generation) {
            ok = false;
            break;
        }
        // 파일이 바뀔 때만 다시 연다 — 조각마다 열면 16,384 번 여는 셈이다.
        if (open_index == null or open_index.? != probe.file) {
            if (open_file) |f| f.close(io);
            open_file = null;
            open_index = probe.file;
            if (job.chain.get(probe.file)) |path| {
                open_file = std.Io.Dir.cwd().openFile(io, path, .{
                    .mode = .read_only,
                    .follow_symlinks = false,
                    .allow_directory = false,
                }) catch null;
            }
            // 못 열었으면 그 파일의 조각들은 「못 봤다」다 — 「없다」로 뭉개지 않는다.
            if (open_file == null) result.partial = true;
        }
        const file = open_file orelse continue;

        // 명령은 언제나 **값 하나**다 — 배열은 결과 쪽에만 온다.
        // **입력이 있으면 그것만 본다**(§2.1.1 · 적대적 1회차). `command` 도 대상도 `input` **안**에
        // 있으므로 명령 프로브를 따로 돌면 같은 바이트를 두 번 읽는다 — 실측 Claude 1,417 MB 에서
        // 읽는 몫이 **56.8 → 129.4 MB(2.28 배)** 로 뛰었고, 그 차이의 대부분이 그 중복이었다.
        // 건너뛰면 **72.6 MB** 다(전 대비 +28%).
        //
        // ⚠️ 안전하게 건너뛸 수 있는 근거는 실측이다: `input` 은 **최대 38.1 KiB** 로 조각 상한
        // (64 KiB)을 넘는 것이 **0 건**이라, 입력 프로브가 언제나 `command` 까지 본다. 그래도
        // 상한에 걸린 날에는 명령 조각이라도 봐야 하므로 아래 폴백을 둔다 — 「없다」와 「못 봤다」를
        // 섞지 않는 것이 이 뷰의 계약이다.
        const in_command = blk: {
            if (probe.input_offset == 0) {
                break :blk probeMatches(io, file, probe.cmd_offset, job.query, raw, out, &result.read_bytes, .value, &result.partial);
            }
            var cut = false;
            const hit = probeMatches(io, file, probe.input_offset, job.query, raw, out, &result.read_bytes, .object, &cut);
            if (cut) result.partial = true;
            if (hit or !cut) break :blk hit;
            // 입력을 다 못 봤다 — 명령 조각이라도 본다.
            break :blk probeMatches(io, file, probe.cmd_offset, job.query, raw, out, &result.read_bytes, .value, &result.partial);
        };
        const in_result = probeMatches(io, file, probe.body_offset, job.query, raw, out, &result.read_bytes, if (probe.body_is_array) .text_array else .value, &result.partial);
        if (!in_command and !in_result) continue;
        result.matches.append(state.allocator, .{
            .data_offset = probe.data_offset,
            .file = probe.file,
            .in_command = in_command,
            .in_result = in_result,
        }) catch {
            result.partial = true;
            break;
        };
    }

    if (!ok) {
        result.deinit(state.allocator);
        finish(state, null);
        return;
    }
    // main actor 가 이분 탐색으로 되짚는다 — 화면은 최신을 앞에 놓으려 뒤집으므로 들어온 순서가
    // 오름차순이 아니다.
    std.mem.sort(Match, result.matches.items, {}, lessThan);

    const ended_ns: i128 = std.Io.Clock.real.now(io).nanoseconds;
    result.search_ns = @intCast(@max(0, ended_ns - started_ns));
    finish(state, result);
}
