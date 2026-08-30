//! session-host **실 runtime 소유자**(`RuntimeManager`) — server.zig의 `RuntimeOps` seam을 실제 PTY runtime으로
//! 구현한다(§4·§13) — P3-e2b.
//!
//! P2에서 만든 `app.InProcessTermBackend`(=`TermRuntimeBackend` 계약의 in-process 구현)를 **그대로 재사용**한다.
//! host는 앱 프로세스가 아니지만 runtime 소유(PTY fork·reader·surface 코어)는 앱과 동일한 자원이라, `LiveSurfaceRegistry`+
//! `SurfaceRuntime`+`LivePtySession` 스택을 새로 만들지 않고 계약 뒤로 재사용한다(layering-and-portability.md §3.1
//! "src/app = 이식 시 재사용하는 OS 중립 공통 runtime"; SSOT — reader 동시성·수명 로직을 복제하지 않는다).
//!
//! ID 매핑(§4): server/wire는 128-bit `runtime_id`로 runtime을 가리키고, in-process backend는 u64 `RuntimeHandle`
//! (=surface handle)로 가리킨다. 이 매니저가 그 경계를 잇는다 — spawn마다 단조 증가 handle을 발급해 backend에 넘기고,
//! 무작위 `runtime_id`를 발급해 host `TerminalRuntimeRegistry`(재접속 조회·capability state)에 등록한 뒤, 그 entry의
//! opaque `runtime` 슬롯(그 목적이 "실 runtime handle 보관")에 handle을 실어 둔다. terminate는 그 슬롯에서 handle을
//! 되읽어 backend 수명을 끝낸다. 별도 side map이 없다.
//!
//! macOS 전용(실 forkpty·arc4random). server.zig(codec·순수)는 이 파일을 모르고 `RuntimeOps` 중립 vtable만 안다 —
//! 그래서 codec은 platform-import-0로 남고, 실 runtime 소유는 이 platform 경계 파일에 갇힌다. `maru`는 named module
//! import라(exe/test 모듈이 maru를 의존) codec 순수성과 무관하다.
//!
//! e2b 범위: spawn(실 PTY + reader) + terminate(clean teardown)까지다. attach 입력/resize(e2c)와 snapshot/delta
//! stream demux(e2d), host-backed `TermRuntimeBackend`(e2e)는 후속이다. 그래서 spawn은 output을 core에 반영하는
//! reader만 시작하고(process_in_reader=true), 화면 stream은 아직 내보내지 않는다.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;
const maru = @import("maru");
const server = @import("server.zig");
const reg = @import("registry.zig");
const core_command_wire = @import("core_command_wire.zig");
const screen_snapshot = @import("screen_snapshot.zig");
const screen_stream = @import("maru").session.screen_stream;
const protocol = @import("protocol.zig");
const handoff_codec = @import("handoff_codec.zig");
const notification_admission = @import("notification_admission.zig");
const notification_journal = @import("notification_journal.zig");
const notification_delivery = @import("notification_delivery.zig");
const notification_os_delivery = @import("notification_os_delivery.zig");
const agent_hook_logs = @import("agent_hook_logs.zig");
const runtime_observation_cache = @import("runtime_observation_cache.zig");
const runtime_metadata_sampler = @import("runtime_metadata_sampler.zig");

comptime {
    if (@import("protocol.zig").max_inventory_runtimes != maru.session.workspace.max_runtime_bindings)
        @compileError("session host inventory cap must equal workspace runtime binding cap");
    if (protocol.max_viewport_snapshot != screen_stream.max_record_stream_bytes)
        @compileError("MRSH viewport cap must equal screen record-stream cap");
}
const upgrade_fd_layout = @import("upgrade_fd_layout.zig");
const upgrade_limits = @import("upgrade_limits.zig");
const core_command = maru.session.core_command; // §6a 원격 스크롤 명령을 host core에 적용
const terminal = maru.terminal; // §6c 원격 검색(Match) 등

const InProcessTermBackend = maru.app.InProcessTermBackend;
const LiveRegistry = maru.app.in_process_term_backend.LiveRegistry;
const SurfaceRuntime = maru.app.SurfaceRuntime;
const RuntimeHandle = maru.app.TermRuntimeHandle;
const LivePtySession = maru.app.LivePtySession;
const ForegroundProcessName = maru.pty.types.ForegroundProcessName;

/// Product caps are named here with their owner. Documentation refers to these names rather than
/// duplicating values. Resident bytes exclude ArrayList bookkeeping and count owned display fields.
pub const notification_limits: notification_journal.Limits = .{
    .max_events = 256,
    .max_resident_bytes = 1024 * 1024,
    .max_title_bytes = 4 * 1024,
    .max_body_bytes = 64 * 1024,
    .max_label_bytes = 256,
};

// host runtime의 PTY→core 이벤트 큐 용량. 제품 경로(app_session.default_queue_capacity)와 같은 16으로 맞춰
// 재접속한 GUI가 in-process와 같은 backpressure를 보게 한다(e2d stream이 이 큐를 소비).
const default_queue_capacity: usize = 16;
/// control frame(`max_control_json` 256 KiB)에 base64(4/3배)로 담을 수 있는 원본 바이트 상한. 여유를 두고 잡는다 —
/// 초과하는 복사는 host가 `too_large`로 알려 client가 로컬과 같은 안내를 띄운다(조용한 유실 금지).
pub const max_clipboard_wire_bytes: usize = 160 * 1024;

/// OSC 52 read 요청의 target(Pc) 상한. 표준 Pc는 `c`/`p`/`s` 같은 한 글자 선택자지만 파서는 길이를 제한하지 않아
/// (OSC 52는 대용량 cap을 쓴다) 수백 KB짜리 Pc가 올 수 있다. 그걸 관측에 그대로 실으면 metadata JSON이
/// `max_control_json`을 넘겨 **attach 응답과 metadata 이벤트가 영구히 실패**한다(runtime이 접속 불가가 된다).
const max_clipboard_target_bytes: usize = 32;

const foreground_refresh_ns: i128 = 500 * std.time.ns_per_ms;
const kernel_cwd_refresh_ns: i128 = 500 * std.time.ns_per_ms;

/// One daemon-global nonblocking self-pipe. PTY readers only publish a byte; the sole poll owner
/// drains runtime queues and projects deltas. This keeps core/socket ownership on the owner thread.
const OutputWake = struct {
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    notify_attempts: std.atomic.Value(u64) = .init(0),
    published_writes: std.atomic.Value(u64) = .init(0),
    coalesced_writes: std.atomic.Value(u64) = .init(0),
    drain_turns: std.atomic.Value(u64) = .init(0),

    const WriteDisposition = enum { retry, published, coalesced, unavailable };

    fn classifyWriteResult(written: isize, err: posix.E) WriteDisposition {
        if (written == 1) return .published;
        if (written < 0 and err == .INTR) return .retry;
        if (written < 0 and err == .AGAIN) return .coalesced;
        return .unavailable;
    }

    fn init() !OutputWake {
        var fds: [2]c_int = undefined;
        if (c.pipe(&fds) != 0) return error.OutputWakeUnavailable;
        errdefer {
            _ = c.close(fds[0]);
            _ = c.close(fds[1]);
        }
        for (fds) |fd| {
            const descriptor_flags = c.fcntl(fd, c.F.GETFD, @as(c_int, 0));
            const status_flags = c.fcntl(fd, c.F.GETFL, @as(c_int, 0));
            const nonblocking: c_int = @bitCast(posix.O{ .NONBLOCK = true });
            if (descriptor_flags < 0 or status_flags < 0 or
                c.fcntl(fd, c.F.SETFD, descriptor_flags | c.FD_CLOEXEC) < 0 or
                c.fcntl(fd, c.F.SETFL, status_flags | nonblocking) < 0)
                return error.OutputWakeUnavailable;
        }
        // A lifecycle bug or hostile fd close must become an observable EPIPE/fallback, never
        // process-wide SIGPIPE termination from a PTY reader thread.
        if (c.fcntl(fds[1], c.F.SETNOSIGPIPE, @as(c_int, 1)) < 0)
            return error.OutputWakeUnavailable;
        return .{ .read_fd = fds[0], .write_fd = fds[1] };
    }

    fn deinit(self: *OutputWake) void {
        _ = c.close(self.read_fd);
        _ = c.close(self.write_fd);
        self.* = undefined;
    }

    fn notify(ctx: *anyopaque) void {
        const self: *OutputWake = @ptrCast(@alignCast(ctx));
        _ = self.notify_attempts.fetchAdd(1, .monotonic);
        const bytes = [_]u8{1};
        while (true) {
            const written = c.write(self.write_fd, bytes[0..].ptr, bytes.len);
            switch (classifyWriteResult(written, if (written < 0) posix.errno(written) else .SUCCESS)) {
                .retry => continue,
                // EAGAIN means an unread wake is already resident. Other failures are observed by
                // the owner-side read fd and lifecycle gates; the reader must never block or own
                // teardown.
                .published => {
                    _ = self.published_writes.fetchAdd(1, .monotonic);
                    return;
                },
                .coalesced => {
                    _ = self.coalesced_writes.fetchAdd(1, .monotonic);
                    return;
                },
                .unavailable => return,
            }
        }
    }

    fn drain(self: *OutputWake) bool {
        var bytes: [256]u8 = undefined;
        var observed = false;
        while (true) {
            const read_count = c.read(self.read_fd, &bytes, bytes.len);
            if (read_count > 0) {
                observed = true;
                continue;
            }
            if (read_count == 0) return false;
            switch (posix.errno(read_count)) {
                .INTR => continue,
                .AGAIN => {
                    if (observed) _ = self.drain_turns.fetchAdd(1, .monotonic);
                    return true;
                },
                else => return false,
            }
        }
    }
};

/// host가 drain해 보관하는 OSC 52 요청 상태(runtime별). client는 관측의 seq 증가로 요청을 알아채고,
/// write 내용만 별도 RPC로 가져간다(텍스트가 커 관측 full-state에 실을 수 없다).
const ClipboardState = struct {
    write_seq: u64 = 0,
    read_seq: u64 = 0,
    /// 마지막 write 요청 텍스트(host 소유 — 다음 요청이 덮어쓴다). client가 가져가면 비운다.
    write_text: std.ArrayListUnmanaged(u8) = .empty,
    /// 마지막 read 요청의 target(Pc). 응답 echo에 쓰이며 짧아서 관측에 그대로 싣는다.
    read_target: std.ArrayListUnmanaged(u8) = .empty,

    fn deinit(self: *ClipboardState, allocator: std.mem.Allocator) void {
        self.write_text.deinit(allocator);
        self.read_target.deinit(allocator);
    }
};

const ForegroundCache = struct {
    names: [64]ForegroundProcessName = undefined,
    count: usize = 0,
    pgid: ?i32 = null,
    refreshed_at_ns: i128 = 0,
    generation: u64 = 0,
};

const KernelCwdCache = struct {
    cwd: [posix.PATH_MAX]u8 = undefined,
    cwd_len: usize = 0,
    hostname: [posix.HOST_NAME_MAX]u8 = undefined,
    hostname_len: usize = 0,
    refreshed_at_ns: i128 = 0,
    generation: u64 = 0,

    fn cwdSlice(self: *const KernelCwdCache) []const u8 {
        return self.cwd[0..self.cwd_len];
    }

    fn hostnameSlice(self: *const KernelCwdCache) []const u8 {
        return self.hostname[0..self.hostname_len];
    }

    fn replace(
        self: *KernelCwdCache,
        cwd: []const u8,
        hostname: []const u8,
        now_ns: i128,
    ) error{ InvalidKernelCwd, KernelCwdTooLong, KernelCwdGenerationExhausted }!bool {
        if (cwd.len == 0 or hostname.len == 0 or cwd.len > self.cwd.len or hostname.len > self.hostname.len)
            return error.KernelCwdTooLong;
        if (cwd[0] != '/' or
            !std.unicode.utf8ValidateSlice(cwd) or
            !std.unicode.utf8ValidateSlice(hostname))
            return error.InvalidKernelCwd;
        const changed = !std.mem.eql(u8, self.cwdSlice(), cwd) or
            !std.mem.eql(u8, self.hostnameSlice(), hostname);
        const next_generation = if (changed)
            std.math.add(u64, self.generation, 1) catch
                return error.KernelCwdGenerationExhausted
        else
            self.generation;
        @memcpy(self.cwd[0..cwd.len], cwd);
        @memcpy(self.hostname[0..hostname.len], hostname);
        self.cwd_len = cwd.len;
        self.hostname_len = hostname.len;
        self.refreshed_at_ns = now_ns;
        self.generation = next_generation;
        return changed;
    }

    fn clear(self: *KernelCwdCache, now_ns: i128) error{KernelCwdGenerationExhausted}!bool {
        const changed = self.cwd_len != 0 or self.hostname_len != 0;
        const next_generation = if (changed)
            std.math.add(u64, self.generation, 1) catch
                return error.KernelCwdGenerationExhausted
        else
            self.generation;
        self.cwd_len = 0;
        self.hostname_len = 0;
        self.refreshed_at_ns = now_ns;
        self.generation = next_generation;
        return changed;
    }
};

const ObservationCacheRecord = struct {
    cache: runtime_observation_cache.Cache,
    refreshed_at_ns: i128 = 0,
    cadence_epoch: ?u64 = null,
    observer_generation: u64 = 0,
    title_generation: u32 = 0,
    // Foreground sampling owns a separate generation from TerminalCore. The 100ms sampler may
    // advance it before cachedObservation materializes JSON, so a transient `changed` bool is not
    // enough: the record must remember which exact foreground generation its bytes contain.
    foreground_generation: u64 = 0,
    /// Kernel cwd is another non-core source. Its fixed cache changes independently of OSC/title,
    /// so canonical metadata must remember the exact paired generation it serialized.
    cwd_generation: u64 = 0,

    fn deinit(self: *ObservationCacheRecord, allocator: std.mem.Allocator) void {
        self.cache.deinit() catch @panic("runtime observation cache retained a prepared value");
        allocator.destroy(self);
    }
};

const ScreenChangeRecord = struct {
    token: server.ScreenChangeToken = .{ .incarnation = 1, .revision = 1 },

    fn advance(self: *ScreenChangeRecord) error{ScreenChangeTokenExhausted}!void {
        self.token.revision = std.math.add(u64, self.token.revision, 1) catch {
            self.token.incarnation = std.math.add(u64, self.token.incarnation, 1) catch
                return error.ScreenChangeTokenExhausted;
            self.token.revision = 1;
            return;
        };
    }
};

// macOS libc CSPRNG(std.posix 미노출 — 이 파일은 macOS 전용). runtime_id 발급용.
extern "c" fn arc4random_buf(buf: [*]u8, nbytes: usize) void;
extern "c" fn usleep(usec: c_uint) c_int;

/// hex 문자열을 바이트로 디코드해 `out`에 채우고 채운 길이를 돌려준다(§6c 검색어 — 임의 텍스트라 hex로 실어 escape 회피).
/// 홀수/잘못된 hex나 `out` 초과는 거기서 멈춘다(best-effort — 검색어는 부가 기능).
fn hexDecodeInto(hex: []const u8, out: []u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i + 2 <= hex.len and n < out.len) : (i += 2) {
        out[n] = std.fmt.parseInt(u8, hex[i .. i + 2], 16) catch break;
        n += 1;
    }
    return n;
}

fn decodeWordSeparators(hex: []const u8, out: *[64]u8) ?[]const u8 {
    if (hex.len > out.len * 2 or hex.len % 2 != 0) return null;
    const decoded = out[0..hexDecodeInto(hex, out)];
    if (decoded.len * 2 != hex.len or !std.unicode.utf8ValidateSlice(decoded)) return null;
    return decoded;
}

test "word separator wire decoder is bounded strict hex and valid UTF-8" {
    var out: [64]u8 = undefined;
    try std.testing.expectEqualStrings("./\xc2\xb7", decodeWordSeparators("2e2fc2b7", &out).?);
    try std.testing.expect(decodeWordSeparators("2", &out) == null);
    try std.testing.expect(decodeWordSeparators("zz", &out) == null);
    try std.testing.expect(decodeWordSeparators("ff", &out) == null);
    try std.testing.expect(decodeWordSeparators("00" ** 65, &out) == null);
}

/// host가 소유하는 실 terminal runtime 표. `RuntimeOps`를 통해 server.zig가 이걸 구동한다. self-referential이라
/// **in-place `init`**을 쓴다(caller가 `var m: RuntimeManager = undefined; m.init(...)`) — backend가 아래 두 registry의
/// 안정 주소를 캡처하므로 init 후 매니저를 이동하면 안 된다.
/// host 가 소유하는 훅 로그 칸의 신원 — **id 와 경로는 함께여야 뜻이 있다**(id 만으로는 어디에 만들지
/// 모르고, 경로만으로는 이름을 못 짓는다). base 를 env 에서 읽지 않고 daemon 이 정해 넘기는 이유는
/// `agent_hook_logs` 의 머리말이 소유한다.
pub const HookIdentity = struct {
    host_id: u128,
    /// `<cache>/maru` — 이 아래에 `agent-turn-events/host_<hex>/` 를 만든다. 호출자 소유이고 manager 보다
    /// 오래 살아야 한다(daemon 이 그 수명을 갖는다).
    log_base: []const u8,
};

pub const RuntimeManager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// 앱과 동일한 소유 스택 — 이 매니저가 **소유**한다(host 수명). backend가 아래 두 필드의 주소를 든다.
    live_registry: LiveRegistry,
    surface_runtime: SurfaceRuntime,
    backend_impl: InProcessTermBackend,
    /// host의 runtime_id 키드 표. 이 매니저가 아니라 daemon이 소유한다(SocketServer도 참조) — 여기선 등록/해제만 한다.
    host_registry: *reg.TerminalRuntimeRegistry,
    /// Stable OSC delivery state belongs to the host, not to any GUI connection. It is final-address
    /// for the same reason as RuntimeManager itself and is mutated only by the daemon owner tick.
    notification_journal: notification_journal.Journal,
    notification_metadata: notification_delivery.MetadataStore,
    notification_os_machine: notification_os_delivery.Machine,
    notification_os_adapter: ?notification_os_delivery.Adapter = null,
    notification_permanent_drops: u64 = 0,
    observed_reaped_children: u64 = 0,
    observed_last_child_exit_status: i32 = -1,
    output_metrics_enabled: bool = false,
    observed_output_bytes: std.atomic.Value(u64) = .init(0),
    observation_materializations: u64 = 0,
    observation_metrics_enabled: bool = false,
    observation_core_lock_acquisitions: u64 = 0,
    observation_core_lock_hold_total_ns: u64 = 0,
    observation_core_lock_hold_max_ns: u64 = 0,
    screen_metrics_enabled: bool = false,
    screen_snapshot_calls: u64 = 0,
    screen_delta_calls: u64 = 0,
    screen_owned_allocations: u64 = 0,
    screen_core_lock_acquisitions: u64 = 0,
    /// 다음 in-process handle. 1부터 발급한다 — 0은 opaque 슬롯의 null과 겹치므로 handle로 쓰지 않는다.
    next_handle: RuntimeHandle = 1,
    /// observation은 client/창/stream마다 100ms cadence로 호출될 수 있지만 OS process 열거는 runtime당 최대 2Hz다.
    /// cwd/title/OSC 상태는 계속 100ms full-state로 읽고, 비싼 foreground syscall 결과만 공유 cache한다.
    foreground_cache: std.AutoHashMapUnmanaged(RuntimeHandle, ForegroundCache) = .empty,
    /// OSC 7이 없는 local runtime만 쓰는 fixed-buffer kernel cwd pair. 값 변화는 metadata source
    /// generation으로 승격하며 syscall은 runtime당 최대 2 Hz다.
    kernel_cwd_cache: std.AutoHashMapUnmanaged(RuntimeHandle, KernelCwdCache) = .empty,
    /// Heap-pinned runtime-global canonical metadata. Hash-map growth moves only pointers, never a
    /// cache owner while a prepared transaction or borrowed view exists.
    observation_caches: std.AutoHashMapUnmanaged(RuntimeHandle, *ObservationCacheRecord) = .empty,
    /// Runtime-scoped E3b source tokens. Streams retain only an admission-owned delivery copy.
    metadata_samplers: std.AutoHashMapUnmanaged(u128, runtime_metadata_sampler.Record) = .empty,
    next_metadata_sample_ns: u64 = 0,
    metadata_sampler_visits: u64 = 0,
    metadata_sampler_changes: u64 = 0,
    metadata_sampler_failures: u64 = 0,
    metadata_producer_visits: u64 = 0,
    /// Owner-thread screen mutation tokens. They let the socket producer reject an unchanged
    /// cadence before opening the core lock, projector, or screen-owned allocator.
    screen_changes: std.AutoHashMapUnmanaged(u128, ScreenChangeRecord) = .empty,
    /// runtime별 BEL 누적 횟수. core의 `takeBell()`은 **소비형 bool**이라 관측(full-state, "이전과 같으면 미전송")에
    /// 그대로 실으면 true→true 전이를 잃어 둘째 벨을 놓친다. 그래서 host가 drain할 때마다 여기서 단조 증가시키고,
    /// client는 마지막에 본 값과의 **차이**로 울릴지 정한다(로컬이 bool을 소비하는 것과 결과 동일).
    bell_counts: std.AutoHashMapUnmanaged(RuntimeHandle, u64) = .empty,
    /// runtime별 OSC 52 상태. 벨과 같은 이유로 **누적 seq**를 쓴다(full-state 관측은 같은 값을 다시 안 보내므로
    /// 소비형 플래그로는 둘째 요청을 놓친다). write 텍스트는 클 수 있어 관측에 싣지 않고 여기 보관했다가 client가
    /// `runtime.clipboard_write`로 가져간다. read는 target(Pc)만 짧아 관측에 함께 싣는다.
    clipboards: std.AutoHashMapUnmanaged(RuntimeHandle, ClipboardState) = .empty,
    output_wake: ?OutputWake = null,
    /// 훅 로그의 host 신원(`init` 이 받는다 — 제품 경로가 잊을 수 없게). null 이면 자식에 훅 신원을
    /// 싣지 않고 칸도 만들지 않는다 — fail-closed.
    hook_identity: ?HookIdentity = null,

    /// self-referential 필드를 안정 주소로 세운다. caller가 준 `*RuntimeManager` 슬롯을 채운다(반환 이동 없음).
    /// `hook_identity` 는 **이 host 의 `host_id` 와 훅 로그 base 경로**다 — spawn 이 자식에게 훅 로그
    /// 경로의 두 칸을 실어 주고, 그 칸을 만들어 둔다(docs/agent-hooks.md §4). `null` 이면 훅 신원을 아예
    /// 안 싣고 칸도 안 만든다(fail-closed — 훅은 디렉터리를 만들지 않으므로 그 자식의 훅은 조용히 나간다).
    ///
    /// **왜 인자인가**: 예전에는 `setHookInstanceHost` 를 따로 부르게 했는데, 업그레이드 후계자 경로
    /// (`restore_activation`)가 그 호출을 빠뜨려 **업그레이드 뒤 새 자식이 훅 신원을 못 받는** 결함이 났다.
    /// 증상은 「그 터미널만 관측 모드로 조용히 강등」이라 알아채기 어렵다. 인자로 만들면 새 제품 경로가
    /// 생겨도 컴파일이 그 결정을 강제한다(테스트는 `null` 을 명시해 «훅 없는 host» 를 뜻한다).
    pub fn init(self: *RuntimeManager, allocator: std.mem.Allocator, io: std.Io, host_registry: *reg.TerminalRuntimeRegistry, hook_identity: ?HookIdentity) void {
        // Unit fixtures predating N2 do not model discovery identity. Product construction must use
        // initWithHostId; the non-zero sentinel keeps those fixtures explicit and deterministic.
        self.initWithHostId(allocator, io, host_registry, if (hook_identity) |identity| identity.host_id else 1, hook_identity);
    }

    pub fn initWithHostId(
        self: *RuntimeManager,
        allocator: std.mem.Allocator,
        io: std.Io,
        host_registry: *reg.TerminalRuntimeRegistry,
        host_id: u128,
        hook_identity: ?HookIdentity,
    ) void {
        std.debug.assert(host_id != 0);
        if (hook_identity) |identity| std.debug.assert(identity.host_id == host_id);
        self.allocator = allocator;
        self.io = io;
        self.live_registry = LiveRegistry.init(allocator);
        self.surface_runtime = SurfaceRuntime.init(allocator);
        self.backend_impl = InProcessTermBackend.init(allocator, io, &self.live_registry, &self.surface_runtime);
        self.host_registry = host_registry;
        self.notification_journal.initInPlace(allocator, host_id, notification_limits) catch unreachable;
        self.notification_metadata = notification_delivery.MetadataStore.init(allocator);
        self.notification_os_machine.initInPlace();
        self.notification_os_adapter = null;
        self.notification_permanent_drops = 0;
        self.observed_reaped_children = 0;
        self.observed_last_child_exit_status = -1;
        self.output_metrics_enabled = false;
        self.observed_output_bytes = .init(0);
        self.observation_materializations = 0;
        self.observation_metrics_enabled = false;
        self.observation_core_lock_acquisitions = 0;
        self.observation_core_lock_hold_total_ns = 0;
        self.observation_core_lock_hold_max_ns = 0;
        self.screen_metrics_enabled = false;
        self.screen_snapshot_calls = 0;
        self.screen_delta_calls = 0;
        self.screen_owned_allocations = 0;
        self.screen_core_lock_acquisitions = 0;
        self.next_handle = 1;
        self.foreground_cache = .empty;
        self.kernel_cwd_cache = .empty;
        self.observation_caches = .empty;
        self.metadata_samplers = .empty;
        self.next_metadata_sample_ns = 0;
        self.metadata_sampler_visits = 0;
        self.metadata_sampler_changes = 0;
        self.metadata_sampler_failures = 0;
        self.metadata_producer_visits = 0;
        self.screen_changes = .empty;
        self.bell_counts = .empty;
        self.clipboards = .empty;
        self.output_wake = null;
        self.hook_identity = hook_identity;
        if (hook_identity) |identity| agent_hook_logs.ensureInstanceDir(io, identity.log_base, identity.host_id);
    }

    /// Product daemon/restore calls this before any runtime exists. Tests that do not exercise the
    /// poll wake may keep the manager pipe-free, so their fd inventories remain stable.
    pub fn enableOutputWake(self: *RuntimeManager) !void {
        std.debug.assert(self.host_registry.count() == 0 and self.output_wake == null);
        self.output_wake = try OutputWake.init();
    }

    pub fn outputWakeReadFd(self: *const RuntimeManager) ?c.fd_t {
        return if (self.output_wake) |wake| wake.read_fd else null;
    }

    pub fn drainOutputWake(self: *RuntimeManager) bool {
        return if (self.output_wake) |*wake| wake.drain() else false;
    }

    pub const OutputWakeEvidence = struct {
        notify_attempts: u64,
        published_writes: u64,
        coalesced_writes: u64,
        drain_turns: u64,
    };

    pub fn fixtureOutputWakeEvidence(self: *const RuntimeManager) OutputWakeEvidence {
        if (self.output_wake) |*wake| return .{
            .notify_attempts = wake.notify_attempts.load(.acquire),
            .published_writes = wake.published_writes.load(.acquire),
            .coalesced_writes = wake.coalesced_writes.load(.acquire),
            .drain_turns = wake.drain_turns.load(.acquire),
        };
        return .{
            .notify_attempts = 0,
            .published_writes = 0,
            .coalesced_writes = 0,
            .drain_turns = 0,
        };
    }

    pub fn fixtureObservationMaterializations(self: *const RuntimeManager) u64 {
        return self.observation_materializations;
    }

    pub const ObservationPerformanceEvidence = struct {
        materializations: u64,
        core_lock_acquisitions: u64,
        core_lock_hold_total_ns: u64,
        core_lock_hold_max_ns: u64,
    };

    pub fn fixtureEnableObservationPerformanceEvidence(self: *RuntimeManager) void {
        self.observation_metrics_enabled = true;
        self.observation_materializations = 0;
        self.observation_core_lock_acquisitions = 0;
        self.observation_core_lock_hold_total_ns = 0;
        self.observation_core_lock_hold_max_ns = 0;
    }

    pub fn fixtureObservationPerformanceEvidence(self: *const RuntimeManager) ObservationPerformanceEvidence {
        return .{
            .materializations = self.observation_materializations,
            .core_lock_acquisitions = self.observation_core_lock_acquisitions,
            .core_lock_hold_total_ns = self.observation_core_lock_hold_total_ns,
            .core_lock_hold_max_ns = self.observation_core_lock_hold_max_ns,
        };
    }

    pub const MetadataSamplerEvidence = struct {
        visits: u64,
        changes: u64,
        failures: u64,
        producer_visits: u64,
    };

    pub fn fixtureMetadataSamplerEvidence(self: *const RuntimeManager) MetadataSamplerEvidence {
        return .{
            .visits = self.metadata_sampler_visits,
            .changes = self.metadata_sampler_changes,
            .failures = self.metadata_sampler_failures,
            .producer_visits = self.metadata_producer_visits,
        };
    }

    pub const ScreenPerformanceEvidence = struct {
        snapshot_calls: u64,
        delta_calls: u64,
        owned_allocations: u64,
        core_lock_acquisitions: u64,
    };

    pub fn fixtureEnableScreenPerformanceEvidence(self: *RuntimeManager) void {
        self.screen_metrics_enabled = true;
        self.screen_snapshot_calls = 0;
        self.screen_delta_calls = 0;
        self.screen_owned_allocations = 0;
        self.screen_core_lock_acquisitions = 0;
    }

    pub fn fixtureScreenPerformanceEvidence(self: *const RuntimeManager) ScreenPerformanceEvidence {
        return .{
            .snapshot_calls = self.screen_snapshot_calls,
            .delta_calls = self.screen_delta_calls,
            .owned_allocations = self.screen_owned_allocations,
            .core_lock_acquisitions = self.screen_core_lock_acquisitions,
        };
    }

    fn recordObservationCoreLockHold(self: *RuntimeManager, started_at_ns: i128) void {
        if (!self.observation_metrics_enabled) return;
        const ended_at_ns = std.Io.Clock.awake.now(self.io).nanoseconds;
        const elapsed: u64 = if (ended_at_ns > started_at_ns)
            @intCast(@min(ended_at_ns - started_at_ns, std.math.maxInt(u64)))
        else
            0;
        self.observation_core_lock_acquisitions +|= 1;
        self.observation_core_lock_hold_total_ns +|= elapsed;
        self.observation_core_lock_hold_max_ns = @max(self.observation_core_lock_hold_max_ns, elapsed);
    }

    /// 소유 registry를 해제한다. **호출 전 모든 runtime이 terminate돼 있어야** 한다(reader join·슬롯 회수가 terminate에서
    /// 일어난다) — 남은 runtime이 있으면 reader 스레드가 join되지 않은 채 슬롯이 사라진다. graceful 종료 경로(§6)가 붙기
    /// 전까지 host는 SIGTERM으로 내려가 OS가 자식·스레드를 회수하므로 이 deinit은 clean-return 경로용이다.
    pub fn deinit(self: *RuntimeManager) void {
        self.foreground_cache.deinit(self.allocator);
        self.kernel_cwd_cache.deinit(self.allocator);
        {
            var it = self.observation_caches.valueIterator();
            while (it.next()) |record| record.*.deinit(self.allocator);
            self.observation_caches.deinit(self.allocator);
        }
        self.metadata_samplers.deinit(self.allocator);
        self.screen_changes.deinit(self.allocator);
        self.bell_counts.deinit(self.allocator);
        self.notification_journal.deinit() catch @panic("notification journal owner moved");
        self.notification_metadata.deinit();
        {
            var it = self.clipboards.valueIterator();
            while (it.next()) |state| state.deinit(self.allocator);
            self.clipboards.deinit(self.allocator);
        }
        self.surface_runtime.deinit();
        self.live_registry.deinit();
        if (self.output_wake) |*wake| wake.deinit();
        self.* = undefined;
    }

    /// server.zig가 dispatch에 넘길 중립 vtable. `ctx`는 이 매니저다.
    pub fn runtimeOps(self: *RuntimeManager) server.RuntimeOps {
        return .{ .ctx = self, .spawn = spawnOp, .terminate = terminateOp, .write_input = writeInputOp, .resize = resizeOp, .snapshot = snapshotOp, .delta = deltaOp, .screen_change_token = screenChangeTokenOp, .metadata_change_token = metadataChangeTokenOp, .sample_metadata_sources = sampleMetadataSourcesOp, .notification_peek = notificationPeekOp, .notification_commit = notificationCommitOp, .notification_config_update = notificationConfigUpdateOp, .core_command = coreCommandOp, .selected_text = selectedTextOp, .select_op = selectOpOp, .find = findOp, .observation = observationOp, .cached_observation = cachedObservationOp, .report_mouse = reportMouseOp, .link_at = linkAtOp, .clipboard_write = clipboardWriteOp, .observation_urgent = observationUrgentOp };
    }

    pub const OwnerDrainSummary = struct {
        visited: usize = 0,
        output_events: usize = 0,
        exited: usize = 0,
        read_errors: usize = 0,
        failures: usize = 0,
    };

    pub const QuiesceError = error{
        TooManyRuntimes,
        Attached,
        RuntimeMissing,
        RuntimeNotLive,
        PauseFailed,
        ResumeFailed,
        UnsafeFrontier,
    };

    const UpgradeItem = struct {
        handle: RuntimeHandle,
        entry: *reg.RuntimeEntry,
        terminal_slot: *maru.app.live_pty.LiveSurface.Terminal,
    };

    pub const UpgradeResource = struct {
        runtime_id: u128,
        source_fd: std.c.fd_t,
        inherited_slot: u16,
    };

    pub const EncodedUpgradePlan = struct {
        allocator: std.mem.Allocator,
        bytes: []u8,
        resources: []UpgradeResource,

        pub fn deinit(self: *EncodedUpgradePlan) void {
            self.allocator.free(self.resources);
            self.allocator.free(self.bytes);
            self.* = undefined;
        }
    };

    pub const UpgradeHandoffPreview = struct {
        encoded_bytes_without_attempt: usize,
        membership_generation: u64,
        runtime_ids: [upgrade_limits.max_runtime_count]u128 = undefined,
        runtime_count: usize,

        pub fn sortedRuntimeIds(self: *const UpgradeHandoffPreview) []const u128 {
            return self.runtime_ids[0..self.runtime_count];
        }

        pub fn totalBytesWithAttempt(self: UpgradeHandoffPreview, attempt_record_len: usize) !usize {
            const attempt_section = handoff_codec.encodedAttemptSectionBytes(attempt_record_len) catch
                return error.LimitExceeded;
            const total = std.math.add(
                usize,
                self.encoded_bytes_without_attempt,
                attempt_section,
            ) catch return error.LimitExceeded;
            if (total > upgrade_limits.max_handoff_commit_bytes) return error.LimitExceeded;
            return total;
        }
    };

    /// U5 pre-quiesce admission preview. This is a read-only encode of the current graph: it does
    /// not request a reader pause, adopt an fd, or mutate admission. The authoritative encode still
    /// happens after quiesce and must fit the resulting reservation.
    pub fn previewUpgradeHandoff(
        self: *RuntimeManager,
        allocator: std.mem.Allocator,
        host_id: u128,
        upgrade_epoch: u64,
        authority_generation: u64,
        first_fd_slot: u16,
    ) (QuiesceError || handoff_codec.Error)!UpgradeHandoffPreview {
        _ = self.drainOwnedEvents();
        const layout = upgrade_fd_layout.Layout.init(first_fd_slot) catch return error.LimitExceeded;
        if (self.host_registry.count() > upgrade_limits.max_runtime_count) return error.TooManyRuntimes;

        var items: [upgrade_limits.max_runtime_count]UpgradeItem = undefined;
        const count = try self.collectLiveUpgradeItems(&items);
        std.mem.sort(UpgradeItem, items[0..count], {}, struct {
            fn lessThan(_: void, a: UpgradeItem, b: UpgradeItem) bool {
                return a.handle < b.handle;
            }
        }.lessThan);

        var views: [upgrade_limits.max_runtime_count]handoff_codec.RuntimeView = undefined;
        var preview: UpgradeHandoffPreview = .{
            .encoded_bytes_without_attempt = 0,
            .membership_generation = self.host_registry.membershipGeneration() catch
                return error.UnsafeFrontier,
            .runtime_count = count,
        };
        const notification_handoff = self.notification_journal.encodeHandoff(
            allocator,
            self.notification_permanent_drops,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.LimitExceeded => return error.LimitExceeded,
            error.InvalidOwner => return error.UnsafeFrontier,
        };
        defer allocator.free(notification_handoff);
        const notification_metadata_handoff = self.notification_metadata.encodeHandoff(allocator) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.UnsafeFrontier,
        };
        defer allocator.free(notification_metadata_handoff);

        var locked: usize = 0;
        defer for (items[0..locked]) |item| item.terminal_slot.surface.unlockCore(self.io);
        for (items[0..count], 0..) |item, index| {
            if (item.entry.controller != null or item.entry.observers.items.len != 0)
                return error.Attached;
            if (!item.terminal_slot.live_pty.upgradeEligible()) return error.RuntimeNotLive;
            item.terminal_slot.surface.lockCore(self.io);
            locked += 1;
            const session = item.terminal_slot.live_pty.session;
            const size = session.canonicalSize();
            const identity = session.masterIdentity() catch return error.UnsafeFrontier;
            if (size.cols != item.entry.cols or size.rows != item.entry.rows) return error.UnsafeFrontier;
            const inherited_slot: u16 = @intCast(layout.runtimeSlot(index) orelse return error.LimitExceeded);
            preview.runtime_ids[index] = item.entry.id;
            views[index] = .{
                .runtime_id = item.entry.id,
                .surface_id = item.handle,
                .child_pid = session.childPid(),
                .cols = item.entry.cols,
                .rows = item.entry.rows,
                .resize_generation = item.entry.resize_generation,
                .fd_slot = inherited_slot,
                .pty_dev = identity.dev,
                .pty_ino = identity.ino,
                .pty_rdev = identity.rdev,
                .core = &item.terminal_slot.surface.core,
            };
        }
        std.mem.sort(u128, preview.runtime_ids[0..count], {}, std.sort.asc(u128));
        const encoded = try handoff_codec.encodeHostWithMaxBytes(allocator, .{
            .host_id = host_id,
            .upgrade_epoch = upgrade_epoch,
            .authority_generation = authority_generation,
            .membership_generation = preview.membership_generation,
            .next_handle = self.next_handle,
            .runtimes = views[0..count],
            .notification_handoff = notification_handoff,
            .notification_metadata_handoff = notification_metadata_handoff,
        }, upgrade_limits.max_handoff_commit_bytes);
        defer allocator.free(encoded);
        preview.encoded_bytes_without_attempt = encoded.len;
        return preview;
    }

    /// 한 번 열거한 paused graph의 logical views와 실제 PTY fd mapping. Attempt record의 sorted runtime set과
    /// outer handoff를 이 candidate 하나에서 만들어 두 결과가 서로 다른 registry snapshot을 보지 않게 한다.
    pub const QuiescedCapture = struct {
        allocator: std.mem.Allocator,
        host_id: u128,
        upgrade_epoch: u64,
        authority_generation: u64 = 1,
        membership_generation: u64 = 1,
        next_handle: u64,
        resources: []UpgradeResource,
        views: []handoff_codec.RuntimeView,
        notification_handoff: []u8,
        notification_digest: notification_journal.LogicalDigest,
        notification_metadata_handoff: []u8,
        notification_metadata_digest: notification_delivery.LogicalDigest,

        pub fn deinit(self: *QuiescedCapture) void {
            self.allocator.free(self.views);
            self.allocator.free(self.resources);
            self.allocator.free(self.notification_handoff);
            self.allocator.free(self.notification_metadata_handoff);
            self.* = undefined;
        }

        pub fn sortedRuntimeIds(
            self: *const QuiescedCapture,
            out: *[upgrade_limits.max_runtime_count]u128,
        ) []const u128 {
            std.debug.assert(self.resources.len <= out.len);
            for (self.resources, 0..) |resource, index| out[index] = resource.runtime_id;
            std.mem.sort(u128, out[0..self.resources.len], {}, std.sort.asc(u128));
            return out[0..self.resources.len];
        }

        pub fn encode(self: *const QuiescedCapture, attempt_record: ?[]const u8) handoff_codec.Error![]u8 {
            if (self.resources.len != self.views.len) return error.InvalidValue;
            for (self.resources, self.views) |resource, view| {
                if (resource.runtime_id != view.runtime_id or
                    resource.inherited_slot != view.fd_slot)
                    return error.InvalidValue;
            }
            return handoff_codec.encodeHost(self.allocator, .{
                .host_id = self.host_id,
                .upgrade_epoch = self.upgrade_epoch,
                .authority_generation = self.authority_generation,
                .membership_generation = self.membership_generation,
                .next_handle = self.next_handle,
                .runtimes = self.views,
                .attempt_record = attempt_record,
                .notification_handoff = self.notification_handoff,
                .notification_metadata_handoff = self.notification_metadata_handoff,
            });
        }

        pub fn intoPlan(
            self: *QuiescedCapture,
            attempt_record: ?[]const u8,
        ) handoff_codec.Error!EncodedUpgradePlan {
            const bytes = try self.encode(attempt_record);
            const allocator = self.allocator;
            const resources = self.resources;
            allocator.free(self.views);
            allocator.free(self.notification_handoff);
            allocator.free(self.notification_metadata_handoff);
            self.* = undefined;
            return .{ .allocator = allocator, .bytes = bytes, .resources = resources };
        }
    };

    /// GUI attachment가 0이어도 host가 reader event queue의 수명 owner다. daemon tick이 이 함수를 호출해
    /// coalesced output 신호를 비우고, 검증된 `.exited`만 exact-once reap/remove한다. `.read_error`는 child
    /// 종료 증거가 아니므로 reader thread만 join하고 runtime/child를 보존한다.
    ///
    /// HashMap iterator 중 unregister하지 않도록 먼저 bounded ID/handle snapshot을 만들고 두 번째 단계에서
    /// 제거한다. 한 tick에 256개를 넘으면 다음 tick이 나머지를 처리한다(U1/U2 upgrade runtime cap과 동일).
    pub fn drainOwnedEvents(self: *RuntimeManager) OwnerDrainSummary {
        const Item = struct { runtime_id: u128, handle: RuntimeHandle };
        var items: [upgrade_limits.max_runtime_count]Item = undefined;
        var item_count: usize = 0;
        var it = self.host_registry.entries.iterator();
        while (it.next()) |entry| {
            if (item_count == items.len) break;
            const slot = entry.value_ptr.*.runtime orelse continue;
            items[item_count] = .{ .runtime_id = entry.key_ptr.*, .handle = @intFromPtr(slot) };
            item_count += 1;
        }

        var remove_ids: [upgrade_limits.max_runtime_count]u128 = undefined;
        var remove_count: usize = 0;
        var result: OwnerDrainSummary = .{};
        for (items[0..item_count]) |item| {
            const terminal_slot = self.backend_impl.terminalForHostLifecycle(item.handle) orelse {
                result.failures += 1;
                continue;
            };
            result.visited += 1;
            var pump = terminal_slot.live_pty.pump(&self.surface_runtime);
            const drained = pump.drainAvailable() catch {
                result.failures += 1;
                continue;
            };
            result.output_events += drained.output_events;
            if (drained.output_events != 0) {
                self.advanceScreenChange(item.runtime_id) catch {
                    result.failures += 1;
                    continue;
                };
                const sampled_at = std.Io.Clock.awake.now(self.io).nanoseconds;
                self.sampleMetadataSource(
                    item.runtime_id,
                    item.handle,
                    if (sampled_at <= 0) 0 else @intCast(@min(sampled_at, std.math.maxInt(u64))),
                );
            }
            self.admitPendingNotification(item.runtime_id, terminal_slot);
            self.takeRejectedNotification(terminal_slot);
            if (drained.ended) |ended| switch (ended) {
                .exited => |status| {
                    result.exited += 1;
                    self.observed_reaped_children +|= 1;
                    self.observed_last_child_exit_status = switch (status) {
                        .exited => |code| code,
                        .signaled => |signal| 128 + @as(i32, signal),
                        .unknown => |raw| raw,
                    };
                    remove_ids[remove_count] = item.runtime_id;
                    remove_count += 1;
                },
                .read_error => {
                    result.read_errors += 1;
                    terminal_slot.live_pty.finishAfterReadError();
                },
            };
        }
        for (remove_ids[0..remove_count]) |runtime_id| self.terminateRuntime(runtime_id);
        if (self.notification_os_adapter) |adapter| {
            const now = std.Io.Clock.awake.now(self.io).nanoseconds;
            _ = self.notification_os_machine.tick(
                if (now <= 0) 0 else @intCast(@min(now, std.math.maxInt(u64))),
                &self.notification_journal,
                adapter,
            );
        }
        return result;
    }

    /// Product daemon installs exactly one process-local platform adapter before publication. The
    /// journal and retry machine remain host-owned; the adapter carries no MRSH/AppSession state.
    pub fn installNotificationOsAdapter(self: *RuntimeManager, adapter: notification_os_delivery.Adapter) void {
        std.debug.assert(self.notification_os_adapter == null and self.host_registry.count() == 0);
        self.notification_os_adapter = adapter;
    }

    pub fn notificationOsCounters(self: *const RuntimeManager) notification_os_delivery.Counters {
        return self.notification_os_machine.typedCounters();
    }

    /// Product owner-tick transaction: copy the current core generation, normalize untrusted bytes,
    /// admit the stable row, then clear only that exact generation. Allocation/transient journal
    /// failure leaves the core slot for retry. Permanent presentation rejection is consumed once so
    /// one hostile OSC cannot pin every later notification in that runtime's single core slot.
    fn admitPendingNotification(self: *RuntimeManager, runtime_id: u128, terminal_slot: anytype) void {
        const surface = &terminal_slot.surface;
        surface.lockCore(self.io);
        const pending = surface.core.pendingNotification() orelse {
            surface.unlockCore(self.io);
            return;
        };
        const generation = pending.generation;
        const raw_title = self.allocator.dupe(u8, pending.title) catch {
            surface.unlockCore(self.io);
            return;
        };
        const raw_body = self.allocator.dupe(u8, pending.body) catch {
            self.allocator.free(raw_title);
            surface.unlockCore(self.io);
            return;
        };
        surface.unlockCore(self.io);
        defer self.allocator.free(raw_title);
        defer self.allocator.free(raw_body);

        const title = notification_admission.sanitizeOwned(
            self.allocator,
            raw_title,
            .single_line,
            notification_limits.max_title_bytes,
        ) catch |err| return self.finishRejectedNotification(surface, generation, err);
        defer self.allocator.free(title);
        const display_title = notification_admission.titleOrFallback(title);
        const body = notification_admission.sanitizeOwned(
            self.allocator,
            raw_body,
            .multi_line,
            notification_limits.max_body_bytes,
        ) catch |err| return self.finishRejectedNotification(surface, generation, err);
        defer self.allocator.free(body);
        const metadata = self.notification_metadata.get(runtime_id) orelse return;
        if (!metadata.notifications_osc) return self.clearNotificationGeneration(surface, generation);
        const label = metadata.display_label;
        const occurred = std.Io.Clock.awake.now(self.io).nanoseconds;
        _ = self.notification_journal.admit(
            runtime_id,
            if (occurred <= 0) 0 else @intCast(@min(occurred, std.math.maxInt(u64))),
            display_title,
            body,
            label,
        ) catch |err| switch (err) {
            error.FieldTooLarge, error.ResidentLimit, error.EventIdExhausted => return self.finishRejectedNotification(surface, generation, err),
            error.OutOfMemory => return,
            error.InvalidOwner => @panic("notification journal owner moved"),
        };
        surface.lockCore(self.io);
        defer surface.unlockCore(self.io);
        _ = surface.core.clearNotificationIfGeneration(generation);
    }

    fn finishRejectedNotification(self: *RuntimeManager, surface: anytype, generation: u64, err: anyerror) void {
        if (err == error.OutOfMemory) return;
        surface.lockCore(self.io);
        defer surface.unlockCore(self.io);
        if (surface.core.clearNotificationIfGeneration(generation)) self.notification_permanent_drops +|= 1;
    }

    fn clearNotificationGeneration(self: *RuntimeManager, surface: anytype, generation: u64) void {
        surface.lockCore(self.io);
        defer surface.unlockCore(self.io);
        _ = surface.core.clearNotificationIfGeneration(generation);
    }

    fn takeRejectedNotification(self: *RuntimeManager, terminal_slot: anytype) void {
        const surface = &terminal_slot.surface;
        surface.lockCore(self.io);
        defer surface.unlockCore(self.io);
        if (surface.core.takeNotificationWriteRejected()) self.notification_permanent_drops +|= 1;
    }

    pub fn oldestNotification(self: *const RuntimeManager, consumer: notification_journal.Consumer) ?notification_journal.View {
        return self.notification_journal.oldestPending(consumer);
    }

    pub fn acknowledgeNotification(
        self: *RuntimeManager,
        key: notification_journal.Key,
        consumer: notification_journal.Consumer,
    ) notification_journal.AckResult {
        return self.notification_journal.ack(key, consumer);
    }

    /// 현재 host가 소유한 실제 PTY reader들의 누적 raw output bytes. test fixture가
    /// controller input bytes를 PTY output으로 재명명하는 false-green 없이 제품 reader
    /// 경계를 계측하도록 제공하는 owner-only 관측값이다.
    pub fn enableOutputMetrics(self: *RuntimeManager) void {
        std.debug.assert(self.host_registry.count() == 0);
        self.output_metrics_enabled = true;
    }

    pub fn totalPtyOutputBytes(self: *const RuntimeManager) u64 {
        if (!self.output_metrics_enabled) return 0;
        return self.observed_output_bytes.load(.acquire);
    }

    pub const ChildExitEvidence = struct {
        live_child_pid: std.c.pid_t,
        reaped_children: u64,
        last_exit_status: i32,
    };

    pub fn fixtureChildExitEvidence(self: *RuntimeManager) ChildExitEvidence {
        var live_child_pid: std.c.pid_t = 0;
        var it = self.host_registry.entries.iterator();
        while (it.next()) |entry| {
            const slot = entry.value_ptr.*.runtime orelse continue;
            const terminal_slot = self.backend_impl.terminalForHostLifecycle(
                @intFromPtr(slot),
            ) orelse continue;
            if (live_child_pid != 0) return .{
                .live_child_pid = -1,
                .reaped_children = self.observed_reaped_children,
                .last_exit_status = self.observed_last_child_exit_status,
            };
            live_child_pid = terminal_slot.live_pty.childPid();
        }
        return .{
            .live_child_pid = live_child_pid,
            .reaped_children = self.observed_reaped_children,
            .last_exit_status = self.observed_last_child_exit_status,
        };
    }

    /// U2 phase 1: owner event를 먼저 drain한 뒤 attachment/lifecycle을 재검사하고 모든 reader에 pause를 요청한다.
    /// 하나라도 실패하면 이미 요청한 reader의 request flag를 취소해 serving 상태를 보존한다.
    pub fn requestUpgradeQuiesce(self: *RuntimeManager) QuiesceError!usize {
        _ = self.drainOwnedEvents();
        if (self.host_registry.count() > upgrade_limits.max_runtime_count) return error.TooManyRuntimes;

        var items: [upgrade_limits.max_runtime_count]UpgradeItem = undefined;
        var count: usize = 0;
        var it = self.host_registry.entries.valueIterator();
        while (it.next()) |entry_ptr| {
            const entry = entry_ptr.*;
            if (entry.controller != null or entry.observers.items.len != 0) return error.Attached;
            const slot = entry.runtime orelse return error.RuntimeMissing;
            const handle: RuntimeHandle = @intFromPtr(slot);
            const terminal_slot = self.backend_impl.terminalForHostLifecycle(handle) orelse return error.RuntimeMissing;
            if (!terminal_slot.live_pty.upgradeEligible()) return error.RuntimeNotLive;
            items[count] = .{ .handle = handle, .entry = entry, .terminal_slot = terminal_slot };
            count += 1;
        }

        var requested: usize = 0;
        for (items[0..count]) |item| {
            item.terminal_slot.live_pty.requestUpgradePause() catch {
                self.resumeUpgradeItems(items[0..requested]) catch return error.ResumeFailed;
                return error.PauseFailed;
            };
            requested += 1;
        }
        return count;
    }

    /// U2 phase 2: 모든 reader가 safe-point를 publish했는지 관찰한다. 일부만 도달했을 때 join하지 않아
    /// deadline rollback이 모든 reader를 signal-only cancel할 수 있게 한다.
    pub fn upgradeQuiesceReached(self: *RuntimeManager) bool {
        var it = self.host_registry.entries.valueIterator();
        while (it.next()) |entry_ptr| {
            const slot = entry_ptr.*.runtime orelse return false;
            const terminal_slot = self.backend_impl.terminalForHostLifecycle(@intFromPtr(slot)) orelse return false;
            if (!terminal_slot.live_pty.upgradePauseReached()) return false;
        }
        return true;
    }

    /// U2 phase 3: 모든 reader가 reached인 것이 확인된 뒤 thread를 join하고 queue/lifecycle frontier를 전량 검증한다.
    /// false면 caller가 `resumeUpgradeQuiesce`로 원상복구한다.
    pub fn joinAndValidateUpgradeQuiesce(self: *RuntimeManager) QuiesceError!void {
        if (!self.upgradeQuiesceReached()) return error.PauseFailed;
        var lives: [upgrade_limits.max_runtime_count]*LivePtySession = undefined;
        var live_count: usize = 0;
        var it = self.host_registry.entries.valueIterator();
        while (it.next()) |entry_ptr| {
            const entry = entry_ptr.*;
            if (entry.controller != null or entry.observers.items.len != 0) return error.Attached;
            const slot = entry.runtime orelse return error.RuntimeMissing;
            const terminal_slot = self.backend_impl.terminalForHostLifecycle(@intFromPtr(slot)) orelse return error.RuntimeMissing;
            lives[live_count] = &terminal_slot.live_pty;
            live_count += 1;
        }
        // Validation 중간 return으로 뒤 reader가 reached-but-unjoined에 남지 않도록 join은 전량 먼저 수행한다.
        var all_safe = true;
        for (lives[0..live_count]) |live|
            if (!live.joinUpgradePause()) {
                all_safe = false;
            };
        if (!all_safe) return error.UnsafeFrontier;
        for (lives[0..live_count]) |live| {
            if (!live.session.upgradeEligible()) return error.RuntimeNotLive;
            if (live.session.childExitedWithoutReap() catch return error.UnsafeFrontier)
                return error.RuntimeNotLive;
        }
        // Reader가 마지막 core write 뒤 coalesced output 신호를 enqueue했을 수 있다. 모든 thread가 join된 뒤 owner가
        // 이를 한 번 더 drain한다. Exit/read_error가 관측되면 status를 버리지 않고 정상 lifecycle로 넘기고 upgrade는 abort.
        const drained = self.drainOwnedEvents();
        if (drained.exited != 0 or drained.read_errors != 0 or drained.failures != 0) return error.RuntimeNotLive;
        var verify = self.host_registry.entries.valueIterator();
        while (verify.next()) |entry_ptr| {
            const slot = entry_ptr.*.runtime orelse return error.RuntimeMissing;
            const terminal_slot = self.backend_impl.terminalForHostLifecycle(@intFromPtr(slot)) orelse return error.RuntimeMissing;
            if (!terminal_slot.live_pty.upgradePausedAndSafe()) return error.UnsafeFrontier;
        }
    }

    pub const ResumeError = error{ResumeFailed};

    pub const PreparedResume = struct {
        lives: [upgrade_limits.max_runtime_count]*LivePtySession = undefined,
        count: usize = 0,
        active: bool = true,

        pub fn release(self: *PreparedResume) void {
            std.debug.assert(self.active);
            for (self.lives[0..self.count]) |live| live.releasePreparedUpgradeResume();
            self.active = false;
        }

        pub fn discard(self: *PreparedResume) void {
            if (!self.active) return;
            for (self.lives[0..self.count]) |live| live.discardPreparedUpgradeResume();
            self.active = false;
        }
    };

    const RestoredGraphItem = struct {
        runtime_id: u128,
        handle: RuntimeHandle,
        terminal: *maru.app.live_pty.LiveSurface.Terminal,
        expected_master: maru.pty.PtySession.MasterIdentity,
        expected_size: maru.terminal.Size,
        expected_resize_generation: u64,
    };

    const RestoreGraphPhase = enum {
        prepared,
        validated,
        ownership_committed,
        readers_released,
    };

    /// Target/rollback restore의 host-global all-or-none graph guard.
    ///
    /// 각 LivePtySession은 heap-pinned final registry slot에서 조립되지만
    /// child lifecycle owner는 아직 아니다. Reader thread도 start gate에서
    /// 대기한다. `discard`는 working fd/thread/allocation만 회수하고 inherited
    /// slots 및 child에는 손대지 않으므로 rollback exec가 가능하다.
    pub const PreparedRestoredGraph = struct {
        manager: *RuntimeManager,
        items: [upgrade_limits.max_runtime_count]RestoredGraphItem = undefined,
        count: usize = 0,
        expected_next_handle: RuntimeHandle,
        phase: RestoreGraphPhase = .prepared,

        pub fn allReadersPrepared(self: *const PreparedRestoredGraph) bool {
            for (self.items[0..self.count]) |item|
                if (!item.terminal.live_pty.preparedStartReached()) return false;
            return true;
        }

        /// Authority commit 직전의 마지막 fallible frontier. 모든 runtime을
        /// 먼저 검증하고 이 함수 안에서는 ownership을 하나도 바꾸지 않는다.
        pub fn revalidateAll(self: *PreparedRestoredGraph) !ValidatedRestoredGraph {
            if (self.phase != .prepared or
                self.manager.next_handle != self.expected_next_handle or
                self.manager.live_registry.count() != self.count or
                self.manager.host_registry.count() != self.count or
                self.manager.surface_runtime.links.items.len != self.count)
                return error.RestoreGraphChanged;
            for (self.items[0..self.count]) |item| {
                const entry = self.manager.host_registry.get(item.runtime_id) orelse
                    return error.RestoreGraphChanged;
                if (entry.runtime == null or @intFromPtr(entry.runtime.?) != item.handle or
                    entry.cols != item.expected_size.cols or
                    entry.rows != item.expected_size.rows or
                    entry.resize_generation != item.expected_resize_generation)
                    return error.RestoreGraphChanged;
                const terminal_slot = self.manager.backend_impl.terminalForHostLifecycle(item.handle) orelse
                    return error.RestoreGraphChanged;
                if (terminal_slot != item.terminal or terminal_slot.surface.id != item.handle or
                    terminal_slot.live_pty.pty_id != item.handle or
                    terminal_slot.surface.core.size.cols != item.expected_size.cols or
                    terminal_slot.surface.core.size.rows != item.expected_size.rows)
                    return error.RestoreGraphChanged;
                const link = terminal_slot.live_pty.link orelse
                    return error.RestoreGraphChanged;
                const pty_io = terminal_slot.live_pty.ptyIo(true);
                if (link.surface_id != item.handle or link.pty_id != item.handle or
                    !self.manager.surface_runtime.linkMatches(
                        item.handle,
                        &terminal_slot.surface,
                        item.handle,
                        pty_io.ctx,
                    ))
                    return error.RestoreGraphChanged;
                const actual_master = terminal_slot.live_pty.session.masterIdentity() catch
                    return error.RestoreGraphChanged;
                if (actual_master.dev != item.expected_master.dev or
                    actual_master.ino != item.expected_master.ino or
                    actual_master.rdev != item.expected_master.rdev)
                    return error.RestoreGraphChanged;
                const actual_size = terminal_slot.live_pty.session.currentSize() catch
                    return error.RestoreGraphChanged;
                if (actual_size.cols != item.expected_size.cols or
                    actual_size.rows != item.expected_size.rows)
                    return error.RestoreGraphChanged;
                terminal_slot.live_pty.revalidatePreparedOwnership() catch
                    return error.RestoreGraphChanged;
            }
            self.phase = .validated;
            return .{ .graph = self };
        }

        pub fn discard(self: *PreparedRestoredGraph) void {
            // Irreversible ownership commit 뒤 stale errdefer/defer가 남아 있어도
            // child를 종료하지 않는다. Committed graph teardown은 정상 manager
            // lifetime만 소유한다.
            if (self.phase == .ownership_committed or self.phase == .readers_released)
                return;
            while (self.count > 0) {
                self.count -= 1;
                const item = self.items[self.count];
                self.manager.discardRestoredItem(item);
            }
            self.manager.next_handle = 1;
        }
    };

    /// `PreparedRestoredGraph.revalidateAll`만 만들 수 있는 commit token.
    /// Durable manifest authority가 성공한 뒤 이 token을 소비하는 전환에는
    /// allocation/syscall이 없다.
    pub const ValidatedRestoredGraph = struct {
        graph: *PreparedRestoredGraph,

        pub fn commitOwnership(self: *ValidatedRestoredGraph) CommittedRestoredGraph {
            // 단일-thread bootstrap에서 같은 token 복사본이 재사용돼도 child
            // ownership store를 중복하지 않고 같은 committed view만 돌려준다.
            if (self.graph.phase == .validated) {
                for (self.graph.items[0..self.graph.count]) |item|
                    item.terminal.live_pty.commitPreparedOwnership();
                self.graph.phase = .ownership_committed;
            }
            std.debug.assert(self.graph.phase == .ownership_committed);
            return .{ .graph = self.graph };
        }
    };

    pub const CommittedRestoredGraph = struct {
        graph: *PreparedRestoredGraph,

        /// Inherited slot cleanup과 non-CLOEXEC-empty 검증 뒤 전량 release한다.
        /// 호출은 idempotent라 stale cleanup/token copy도 reader를 두 번 시작하지 않는다.
        pub fn releaseReaders(self: *CommittedRestoredGraph) void {
            if (self.graph.phase == .readers_released) return;
            std.debug.assert(self.graph.phase == .ownership_committed);
            for (self.graph.items[0..self.graph.count]) |item|
                item.terminal.live_pty.releasePreparedStart();
            self.graph.phase = .readers_released;
        }
    };

    /// Decoded handoff를 final manager graph에 한 번만 결합하는 SSOT.
    /// Caller는 empty, stable-address manager를 제공하고 반환 guard가
    /// release되기 전까지 manager를 이동하거나 외부 server에 publish하지 않는다.
    pub fn prepareRestoredGraph(
        self: *RuntimeManager,
        host: *handoff_codec.HostState,
    ) !PreparedRestoredGraph {
        if (self.live_registry.count() != 0 or self.host_registry.count() != 0 or
            self.surface_runtime.links.items.len != 0 or self.next_handle != 1)
            return error.RestoreDestinationNotEmpty;
        if (host.next_handle == 0 or
            host.next_handle == std.math.maxInt(RuntimeHandle) or
            host.runtimes.len > upgrade_limits.max_runtime_count)
            return error.InvalidRestoreGraph;
        var restore_sizes: [upgrade_limits.max_runtime_count]reg.GridSize = undefined;
        for (host.runtimes, 0..) |runtime, index|
            restore_sizes[index] = .{ .cols = runtime.cols, .rows = runtime.rows };
        try self.host_registry.canRegisterBatch(restore_sizes[0..host.runtimes.len]);

        var prepared = PreparedRestoredGraph{
            .manager = self,
            .expected_next_handle = host.next_handle,
        };
        errdefer prepared.discard();

        for (host.runtimes) |*runtime| {
            if (runtime.surface_id == 0 or runtime.surface_id >= host.next_handle)
                return error.InvalidRestoreGraph;
            var adoption = try maru.pty.PtySession.PreparedAdoption.prepareExact(
                runtime.fd_slot,
                runtime.child_pid,
                .{ .cols = runtime.cols, .rows = runtime.rows },
                .{
                    .dev = runtime.pty_dev,
                    .ino = runtime.pty_ino,
                    .rdev = runtime.pty_rdev,
                },
            );
            errdefer adoption.discard();

            const slot = try self.live_registry.create(runtime.surface_id, 0);
            slot.* = .{ .terminal = .{ .internal_allocator = self.allocator } };
            var surface_initialized = false;
            var live_initialized = false;
            var reader_prepared = false;
            var entry_registered = false;
            errdefer {
                if (entry_registered) self.host_registry.unregister(runtime.runtime_id);
                if (reader_prepared) {
                    slot.terminal.live_pty.discardPreparedAdoption(&self.surface_runtime);
                    live_initialized = false;
                }
                if (live_initialized) slot.terminal.live_pty.deinit();
                if (surface_initialized) slot.terminal.surface.deinit();
                self.live_registry.removeUninitialized(runtime.surface_id) catch {};
            }

            slot.terminal.surface = try maru.session.Surface.initRestored(
                self.allocator,
                runtime.surface_id,
                &runtime.core,
            );
            surface_initialized = true;
            try slot.terminal.live_pty.initPreparedAdoption(
                self.io,
                self.allocator,
                runtime.surface_id,
                &adoption,
                default_queue_capacity,
            );
            live_initialized = true;
            if (self.output_wake) |*wake| slot.terminal.live_pty.eventQueue().setWakeNotifier(.{
                .ctx = wake,
                .notify = OutputWake.notify,
            });
            _ = try slot.terminal.live_pty.attachSurfacePrepared(
                &self.surface_runtime,
                &slot.terminal.surface,
            );
            reader_prepared = true;
            _ = try self.host_registry.registerRestored(
                runtime.runtime_id,
                runtime.cols,
                runtime.rows,
                runtime.resize_generation,
                @ptrFromInt(runtime.surface_id),
            );
            entry_registered = true;
            try self.screen_changes.putNoClobber(
                self.allocator,
                runtime.runtime_id,
                .{},
            );
            errdefer _ = self.screen_changes.remove(runtime.runtime_id);
            const sampled_at = std.Io.Clock.awake.now(self.io).nanoseconds;
            try self.installMetadataSampler(
                runtime.runtime_id,
                runtime.surface_id,
                if (sampled_at <= 0) 0 else @intCast(@min(sampled_at, std.math.maxInt(u64))),
            );
            errdefer _ = self.metadata_samplers.remove(runtime.runtime_id);

            prepared.items[prepared.count] = .{
                .runtime_id = runtime.runtime_id,
                .handle = runtime.surface_id,
                .terminal = &slot.terminal,
                .expected_master = .{
                    .dev = runtime.pty_dev,
                    .ino = runtime.pty_ino,
                    .rdev = runtime.pty_rdev,
                },
                .expected_size = .{ .cols = runtime.cols, .rows = runtime.rows },
                .expected_resize_generation = runtime.resize_generation,
            };
            prepared.count += 1;
            entry_registered = false;
            reader_prepared = false;
            live_initialized = false;
            surface_initialized = false;
        }
        if (host.notification_handoff) |notification_bytes| {
            self.notification_permanent_drops = try self.notification_journal.restoreHandoff(notification_bytes);
        }
        if (host.notification_metadata_handoff) |metadata_bytes| {
            try self.notification_metadata.restoreHandoff(metadata_bytes);
        } else {
            for (host.runtimes) |runtime| try self.notification_metadata.install(runtime.runtime_id, null);
        }
        if (self.notification_metadata.count() != host.runtimes.len) return error.InvalidRestoreGraph;
        for (host.runtimes) |runtime| if (self.notification_metadata.get(runtime.runtime_id) == null)
            return error.InvalidRestoreGraph;
        try self.host_registry.restoreMembershipGeneration(host.membership_generation);
        self.next_handle = host.next_handle;
        return prepared;
    }

    fn discardRestoredItem(self: *RuntimeManager, item: RestoredGraphItem) void {
        _ = self.metadata_samplers.remove(item.runtime_id);
        _ = self.foreground_cache.remove(item.handle);
        _ = self.kernel_cwd_cache.remove(item.handle);
        _ = self.screen_changes.remove(item.runtime_id);
        self.host_registry.unregister(item.runtime_id);
        item.terminal.live_pty.discardPreparedAdoption(&self.surface_runtime);
        item.terminal.surface.deinit();
        self.live_registry.removeUninitialized(item.handle) catch {};
    }

    /// Fully quiesced product rollback용 2-phase resume. Thread 생성만 전량 성공시키고 실제 PTY 접근 release는 caller가
    /// authority를 ready로 durable commit한 뒤 수행한다.
    pub fn prepareUpgradeResume(self: *RuntimeManager) ResumeError!PreparedResume {
        var prepared: PreparedResume = .{};
        errdefer prepared.discard();
        var it = self.host_registry.entries.valueIterator();
        while (it.next()) |entry_ptr| {
            const slot = entry_ptr.*.runtime orelse return error.ResumeFailed;
            const terminal_slot = self.backend_impl.terminalForHostLifecycle(@intFromPtr(slot)) orelse
                return error.ResumeFailed;
            if (!terminal_slot.live_pty.upgradePausedAndSafe()) return error.ResumeFailed;
            terminal_slot.live_pty.prepareResumeAfterUpgradePause() catch return error.ResumeFailed;
            prepared.lives[prepared.count] = &terminal_slot.live_pty;
            prepared.count += 1;
        }
        return prepared;
    }

    /// U2 rollback/resume. Join된 reader는 전부 prepared-start gate에 먼저 세우고, 모든 thread 생성이 성공한 뒤에만
    /// 한꺼번에 release한다. 중간 spawn 실패면 준비된 thread를 전부 폐기하고 admission caller가 fail-stop할 수 있게
    /// error를 돌려준다. 일부 reader만 재개된 상태로 gate를 열지 않는다.
    pub fn resumeUpgradeQuiesce(self: *RuntimeManager) ResumeError!void {
        var items: [upgrade_limits.max_runtime_count]UpgradeItem = undefined;
        const count = self.collectLiveUpgradeItems(&items) catch return error.ResumeFailed;
        return self.resumeUpgradeItems(items[0..count]);
    }

    fn resumeUpgradeItems(self: *RuntimeManager, items: []const UpgradeItem) ResumeError!void {
        _ = self;
        var prepared: [upgrade_limits.max_runtime_count]*LivePtySession = undefined;
        var prepared_count: usize = 0;
        errdefer for (prepared[0..prepared_count]) |live| live.discardPreparedUpgradeResume();
        for (items) |item| {
            const terminal_slot = item.terminal_slot;
            if (!terminal_slot.live_pty.upgradePausedAndSafe()) {
                if (terminal_slot.live_pty.upgradePauseReached()) {
                    if (!terminal_slot.live_pty.joinUpgradePause()) return error.ResumeFailed;
                } else if (!terminal_slot.live_pty.cancelUpgradePause()) {
                    // cancel CAS보다 reader ACK 또는 terminal publish가 먼저였다. reached면 join 뒤 아래
                    // prepared-resume으로 합류하고, terminal이면 join 검증이 실패해 fail-stop으로 올린다.
                    if (!terminal_slot.live_pty.joinUpgradePause()) return error.ResumeFailed;
                }
            }
            if (terminal_slot.live_pty.upgradePausedAndSafe()) {
                terminal_slot.live_pty.prepareResumeAfterUpgradePause() catch return error.ResumeFailed;
                prepared[prepared_count] = &terminal_slot.live_pty;
                prepared_count += 1;
            }
        }
        for (prepared[0..prepared_count]) |live| live.releasePreparedUpgradeResume();
    }

    fn collectLiveUpgradeItems(
        self: *RuntimeManager,
        out: *[upgrade_limits.max_runtime_count]UpgradeItem,
    ) ResumeError!usize {
        if (self.host_registry.count() > out.len) return error.ResumeFailed;
        var count: usize = 0;
        var it = self.host_registry.entries.valueIterator();
        while (it.next()) |entry_ptr| {
            const entry = entry_ptr.*;
            const slot = entry.runtime orelse return error.ResumeFailed;
            const handle: RuntimeHandle = @intFromPtr(slot);
            const terminal_slot = self.backend_impl.terminalForHostLifecycle(handle) orelse
                return error.ResumeFailed;
            out[count] = .{ .handle = handle, .entry = entry, .terminal_slot = terminal_slot };
            count += 1;
        }
        return count;
    }

    /// U1/U2 bridge: 모든 reader가 join된 safe frontier에서 host/runtime logical DTO를 원자적으로 encode한다.
    /// HashMap 순서는 wire 순서가 아니므로 stable in-process handle 순으로 정렬한다. fd slot은 caller가 예약한
    /// 연속 범위의 logical 번호만 기록하며 여기서는 실제 dup/CLOEXEC를 건드리지 않는다(U3 소유).
    pub fn encodeQuiescedHost(
        self: *RuntimeManager,
        allocator: std.mem.Allocator,
        host_id: u128,
        upgrade_epoch: u64,
        first_fd_slot: u16,
    ) (QuiesceError || handoff_codec.Error)![]u8 {
        const plan = try self.encodeQuiescedPlan(allocator, host_id, upgrade_epoch, first_fd_slot);
        allocator.free(plan.resources);
        return plan.bytes;
    }

    /// Handoff bytes와 그 bytes의 stable fd_slot 순서에 대응하는 실제 master fd를 한 owner로 만든다. Exec 준비가
    /// registry를 다시 열거해 다른 순서를 추론하지 않게 하는 SSOT다.
    pub fn encodeQuiescedPlan(
        self: *RuntimeManager,
        allocator: std.mem.Allocator,
        host_id: u128,
        upgrade_epoch: u64,
        first_fd_slot: u16,
    ) (QuiesceError || handoff_codec.Error)!EncodedUpgradePlan {
        return self.encodeQuiescedPlanWithAttempt(allocator, host_id, upgrade_epoch, first_fd_slot, null);
    }

    pub fn encodeQuiescedPlanWithAttempt(
        self: *RuntimeManager,
        allocator: std.mem.Allocator,
        host_id: u128,
        upgrade_epoch: u64,
        first_fd_slot: u16,
        attempt_record: ?[]const u8,
    ) (QuiesceError || handoff_codec.Error)!EncodedUpgradePlan {
        var capture = try self.prepareQuiescedCapture(
            allocator,
            host_id,
            upgrade_epoch,
            1,
            first_fd_slot,
        );
        errdefer capture.deinit();
        return capture.intoPlan(attempt_record);
    }

    pub fn prepareQuiescedCapture(
        self: *RuntimeManager,
        allocator: std.mem.Allocator,
        host_id: u128,
        upgrade_epoch: u64,
        authority_generation: u64,
        first_fd_slot: u16,
    ) (QuiesceError || handoff_codec.Error)!QuiescedCapture {
        const layout = upgrade_fd_layout.Layout.init(first_fd_slot) catch return error.LimitExceeded;
        if (!self.upgradeQuiesceReached() or self.host_registry.count() > handoff_codec.max_runtime_count)
            return error.UnsafeFrontier;
        var items: [handoff_codec.max_runtime_count]UpgradeItem = undefined;
        const count = try self.collectQuiescedItems(&items);
        std.mem.sort(UpgradeItem, items[0..count], {}, struct {
            fn lessThan(_: void, a: UpgradeItem, b: UpgradeItem) bool {
                return a.handle < b.handle;
            }
        }.lessThan);
        if (@as(usize, first_fd_slot) + count > std.math.maxInt(u16)) return error.LimitExceeded;

        const resources = allocator.alloc(UpgradeResource, count) catch return error.OutOfMemory;
        errdefer allocator.free(resources);
        const views = allocator.alloc(handoff_codec.RuntimeView, count) catch return error.OutOfMemory;
        errdefer allocator.free(views);
        const notification_handoff = self.notification_journal.encodeHandoff(
            allocator,
            self.notification_permanent_drops,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.LimitExceeded => return error.LimitExceeded,
            error.InvalidOwner => return error.UnsafeFrontier,
        };
        errdefer allocator.free(notification_handoff);
        if (notification_handoff.len > handoff_codec.max_notification_handoff_bytes) return error.LimitExceeded;
        const notification_metadata_handoff = self.notification_metadata.encodeHandoff(allocator) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.UnsafeFrontier,
        };
        errdefer allocator.free(notification_metadata_handoff);
        if (notification_metadata_handoff.len > handoff_codec.max_notification_metadata_handoff_bytes) return error.LimitExceeded;
        var locked: usize = 0;
        defer for (items[0..locked]) |item| item.terminal_slot.surface.unlockCore(self.io);
        for (items[0..count], 0..) |item, index| {
            item.terminal_slot.surface.lockCore(self.io);
            locked += 1;
            const session = item.terminal_slot.live_pty.session;
            const size = session.canonicalSize();
            const identity = session.masterIdentity() catch return error.UnsafeFrontier;
            if (size.cols != item.entry.cols or size.rows != item.entry.rows) return error.UnsafeFrontier;
            const inherited_slot: u16 = @intCast(layout.runtimeSlot(index) orelse return error.LimitExceeded);
            resources[index] = .{
                .runtime_id = item.entry.id,
                .source_fd = session.inheritedMasterFd() orelse return error.UnsafeFrontier,
                .inherited_slot = inherited_slot,
            };
            views[index] = .{
                .runtime_id = item.entry.id,
                .surface_id = item.handle,
                .child_pid = session.childPid(),
                .cols = item.entry.cols,
                .rows = item.entry.rows,
                .resize_generation = item.entry.resize_generation,
                .fd_slot = inherited_slot,
                .pty_dev = identity.dev,
                .pty_ino = identity.ino,
                .pty_rdev = identity.rdev,
                .core = &item.terminal_slot.surface.core,
            };
        }
        return .{
            .allocator = allocator,
            .host_id = host_id,
            .upgrade_epoch = upgrade_epoch,
            .authority_generation = authority_generation,
            .membership_generation = self.host_registry.membershipGeneration() catch return error.UnsafeFrontier,
            .next_handle = self.next_handle,
            .resources = resources,
            .views = views,
            .notification_handoff = notification_handoff,
            .notification_digest = self.notification_journal.logicalDigest(self.notification_permanent_drops),
            .notification_metadata_handoff = notification_metadata_handoff,
            .notification_metadata_digest = self.notification_metadata.logicalDigest(),
        };
    }

    /// Store/preflight 동안 paused child/fd/graph가 바뀌지 않았는지 destructive exec 직전에 같은 capture로 다시
    /// 검증한다. waitpid status는 소비하지 않으며 한 runtime이라도 달라지면 전체 attempt가 old graph로 복귀한다.
    pub fn revalidateQuiescedCapture(
        self: *RuntimeManager,
        capture: *const QuiescedCapture,
    ) QuiesceError!void {
        if (capture.next_handle != self.next_handle or
            capture.resources.len != capture.views.len or
            capture.resources.len != self.host_registry.count())
            return error.UnsafeFrontier;
        const current_notification_digest = self.notification_journal.logicalDigest(self.notification_permanent_drops);
        if (!std.mem.eql(u8, &capture.notification_digest, &current_notification_digest))
            return error.UnsafeFrontier;
        const current_metadata_digest = self.notification_metadata.logicalDigest();
        if (!std.mem.eql(u8, &capture.notification_metadata_digest, &current_metadata_digest))
            return error.UnsafeFrontier;
        for (capture.resources, capture.views) |resource, view| {
            if (resource.runtime_id != view.runtime_id or resource.inherited_slot != view.fd_slot)
                return error.UnsafeFrontier;
            const entry = self.host_registry.get(resource.runtime_id) orelse return error.RuntimeMissing;
            const slot = entry.runtime orelse return error.RuntimeMissing;
            const handle: RuntimeHandle = @intFromPtr(slot);
            if (view.surface_id != handle or entry.cols != view.cols or entry.rows != view.rows or
                entry.resize_generation != view.resize_generation)
                return error.UnsafeFrontier;
            const terminal_slot = self.backend_impl.terminalForHostLifecycle(handle) orelse
                return error.RuntimeMissing;
            const session = terminal_slot.live_pty.session;
            if (!terminal_slot.live_pty.upgradePausedAndSafe() or
                session.inheritedMasterFd() != resource.source_fd or
                session.childPid() != view.child_pid or
                session.childExitedWithoutReap() catch return error.UnsafeFrontier)
                return error.RuntimeNotLive;
            const size = session.canonicalSize();
            const identity = session.masterIdentity() catch return error.UnsafeFrontier;
            if (size.cols != view.cols or size.rows != view.rows or
                identity.dev != view.pty_dev or identity.ino != view.pty_ino or identity.rdev != view.pty_rdev)
                return error.UnsafeFrontier;
        }
    }

    fn collectQuiescedItems(
        self: *RuntimeManager,
        out: *[handoff_codec.max_runtime_count]UpgradeItem,
    ) QuiesceError!usize {
        var count: usize = 0;
        var it = self.host_registry.entries.valueIterator();
        while (it.next()) |entry_ptr| {
            const entry = entry_ptr.*;
            const slot = entry.runtime orelse return error.RuntimeMissing;
            const handle: RuntimeHandle = @intFromPtr(slot);
            const terminal_slot = self.backend_impl.terminalForHostLifecycle(handle) orelse return error.RuntimeMissing;
            if (!terminal_slot.live_pty.upgradePausedAndSafe() or !terminal_slot.live_pty.session.upgradeEligible())
                return error.UnsafeFrontier;
            if (terminal_slot.live_pty.session.childExitedWithoutReap() catch return error.UnsafeFrontier)
                return error.RuntimeNotLive;
            out[count] = .{ .handle = handle, .entry = entry, .terminal_slot = terminal_slot };
            count += 1;
        }
        return count;
    }

    fn spawnOp(ctx: *anyopaque, params: server.RuntimeSpawnParams) anyerror!u128 {
        const self: *RuntimeManager = @ptrCast(@alignCast(ctx));
        return self.spawnRuntime(params);
    }

    fn terminateOp(ctx: *anyopaque, runtime_id: u128) void {
        const self: *RuntimeManager = @ptrCast(@alignCast(ctx));
        self.terminateRuntime(runtime_id);
    }

    fn writeInputOp(ctx: *anyopaque, runtime_id: u128, bytes: []const u8) anyerror!void {
        const self: *RuntimeManager = @ptrCast(@alignCast(ctx));
        const handle = self.handleFor(runtime_id) orelse return error.RuntimeNotFound;
        return self.backend_impl.backend().writeInput(handle, bytes);
    }

    fn resizeOp(ctx: *anyopaque, runtime_id: u128, cols: u16, rows: u16) anyerror!void {
        const self: *RuntimeManager = @ptrCast(@alignCast(ctx));
        try self.resizeWithApply(runtime_id, cols, rows, self, backendResizeApply);
        try self.publishScreenChange(runtime_id);
    }

    fn backendResizeApply(ctx: *anyopaque, handle: RuntimeHandle, size: maru.terminal.Size, io: std.Io) anyerror!void {
        const self: *RuntimeManager = @ptrCast(@alignCast(ctx));
        return self.backend_impl.backend().resize(handle, size, io);
    }

    fn resizeWithApply(
        self: *RuntimeManager,
        runtime_id: u128,
        cols: u16,
        rows: u16,
        apply_ctx: *anyopaque,
        apply: *const fn (*anyopaque, RuntimeHandle, maru.terminal.Size, std.Io) anyerror!void,
    ) anyerror!void {
        const handle = self.handleFor(runtime_id) orelse return error.RuntimeNotFound;
        apply(apply_ctx, handle, .{ .cols = cols, .rows = rows }, self.io) catch |err| {
            // SurfaceRuntime resize는 core mutation 뒤 PTY ioctl에서 실패할 수 있어 rollback으로 원래 크기를 보장할 수
            // 없다. 부분 적용 runtime을 살려 ledger보다 큰 heap을 숨기지 말고 fail-stop으로 실제 resource를 전량 회수한다.
            self.terminateRuntime(runtime_id);
            return err;
        };
    }

    /// host 실제 core/PTY에서 화면 외 runtime 관측을 한 번에 owned copy한다. foreground syscall은 runtime별 500ms
    /// cache로 core lock 밖에서 수행하고, cwd/title/semantic/input modes/OSC5379는 reader와 같은 core lock 아래에서 복사한다.
    /// 1회성 agent progress는 multi-subscriber wire에서 제외한다.
    fn observationOp(ctx: *anyopaque, runtime_id: u128, allocator: std.mem.Allocator) anyerror!server.RuntimeObservation {
        const self: *RuntimeManager = @ptrCast(@alignCast(ctx));
        const handle = self.handleFor(runtime_id) orelse return error.RuntimeNotFound;
        const surface = self.backend_impl.surfaceFor(handle) orelse return error.RuntimeNotFound;

        // BEL drain은 관측을 만드는 **모든 경로**(주기 push·RPC pull·attach)에서 일어나지만, takeBell이 소비형이라
        // 벨 1회당 카운터는 정확히 1 증가한다(중복 없음). 카운터는 단조 증가라 client가 delta로 판정한다.
        const bell_gop = try self.bell_counts.getOrPut(self.allocator, handle);
        if (!bell_gop.found_existing) bell_gop.value_ptr.* = 0;
        {
            surface.lockCore(self.io);
            const lock_started_at_ns = if (self.observation_metrics_enabled)
                std.Io.Clock.awake.now(self.io).nanoseconds
            else
                0;
            defer {
                self.recordObservationCoreLockHold(lock_started_at_ns);
                surface.unlockCore(self.io);
            }
            if (surface.core.takeBell()) bell_gop.value_ptr.* +%= 1;
        }
        const bell_count = bell_gop.value_ptr.*;

        // OSC 52: 벨과 같은 자리에서 drain한다. 요청은 core가 파싱하지만 **정책 판정과 OS 클립보드 접근은 client**가
        // 하므로(§기능 배치 규칙) host는 사실만 모아 둔다. write 텍스트는 관측에 싣기엔 커서 여기 보관하고,
        // read는 target만 관측에 함께 실어 client가 RPC 없이 판정할 수 있게 한다.
        const clip_gop = try self.clipboards.getOrPut(self.allocator, handle);
        if (!clip_gop.found_existing) clip_gop.value_ptr.* = .{};
        const clip = clip_gop.value_ptr;
        {
            surface.lockCore(self.io);
            const lock_started_at_ns = if (self.observation_metrics_enabled)
                std.Io.Clock.awake.now(self.io).nanoseconds
            else
                0;
            defer {
                self.recordObservationCoreLockHold(lock_started_at_ns);
                surface.unlockCore(self.io);
            }
            const pending_write = surface.core.pendingClipboardWrite();
            if (pending_write.len > 0) {
                clip.write_text.clearRetainingCapacity();
                // 저장에 성공했을 때만 seq를 올리고 core pending을 비운다 — OOM을 삼키면서 둘 다 하면 원본이
                // 어디에도 남지 않은 채 client에는 "요청 있음"만 전해져 사용자의 복사가 조용히 파괴된다.
                if (clip.write_text.appendSlice(self.allocator, pending_write)) |_| {
                    clip.write_seq +%= 1;
                    surface.core.clearClipboardWrite();
                } else |_| {
                    clip.write_text.clearRetainingCapacity(); // 부분 복사분 폐기 — 다음 관측에서 다시 시도한다
                }
            }
            if (surface.core.clipboardReadPending()) {
                clip.read_target.clearRetainingCapacity();
                const target = surface.core.clipboardReadTarget();
                // 상한 초과 Pc는 자른다 — 관측이 control frame을 넘겨 runtime이 attach 불가가 되는 것을 막는다.
                clip.read_target.appendSlice(self.allocator, target[0..@min(target.len, max_clipboard_target_bytes)]) catch {};
                clip.read_seq +%= 1;
                surface.core.clearClipboardRead(); // 정책과 무관하게 소비(로컬과 같은 규율 — 재트리거 방지)
            }
        }

        const now_ns = std.Io.Clock.awake.now(self.io).nanoseconds;
        _ = try self.refreshForegroundCache(handle, now_ns);
        _ = try self.refreshKernelCwdCache(handle, now_ns, true);
        const foreground = self.foreground_cache.getPtr(handle) orelse
            return error.TransientObservationUnavailable;
        const process_count = foreground.count;
        const foreground_pgid = foreground.pgid;
        const processes = try allocator.alloc(server.RuntimeObservation.Process, process_count);
        var process_names_initialized: usize = 0;
        errdefer {
            for (processes[0..process_names_initialized]) |p| allocator.free(p.name);
            allocator.free(processes);
        }
        for (foreground.names[0..process_count], 0..) |p, i| {
            processes[i] = .{ .pid = p.pid, .name = try allocator.dupe(u8, p.slice()) };
            process_names_initialized += 1;
        }

        // PTY 자식 뿌리 pid — 없으면(비-터미널 arm·이미 회수) 0이고 GUI는 그 탭을 `—`로 둔다.
        const child_pid: i32 = if (self.backend_impl.terminalForHostLifecycle(handle)) |t|
            @intCast(t.live_pty.childPid())
        else
            0;

        surface.lockCore(self.io);
        const lock_started_at_ns = if (self.observation_metrics_enabled)
            std.Io.Clock.awake.now(self.io).nanoseconds
        else
            0;
        defer {
            self.recordObservationCoreLockHold(lock_started_at_ns);
            surface.unlockCore(self.io);
        }
        const core = &surface.core;
        const osc_cwd = core.currentCwd();
        const kernel_cwd = self.kernel_cwd_cache.getPtr(handle);
        const use_kernel_cwd = osc_cwd.len == 0 and core.sshRemoteDest() == null and
            kernel_cwd != null and kernel_cwd.?.cwd_len != 0;
        const cwd_source = if (use_kernel_cwd) kernel_cwd.?.cwdSlice() else osc_cwd;
        const cwd_host_source = if (use_kernel_cwd) kernel_cwd.?.hostnameSlice() else core.currentCwdHost();
        const cwd = try allocator.dupe(u8, cwd_source);
        errdefer allocator.free(cwd);
        const cwd_host = try allocator.dupe(u8, cwd_host_source);
        errdefer allocator.free(cwd_host);
        const title = try allocator.dupe(u8, core.windowTitle());
        errdefer allocator.free(title);
        const ssh_dest: ?[]u8 = if (core.sshRemoteDest()) |dest| try allocator.dupe(u8, dest) else null;
        errdefer if (ssh_dest) |dest| allocator.free(dest);
        const result = server.RuntimeObservation{
            .cwd = cwd,
            .cwd_host = cwd_host,
            .window_title = title,
            .ssh_remote_dest = ssh_dest,
            .semantic_state = @intFromEnum(core.semantic_state),
            .alt_active = core.alt_active,
            .app_cursor_keys = core.application_cursor_keys,
            // §입력 패리티: host-backed 일반 key 인코딩(DECKPAM numpad·kitty keyboard)이 placeholder core 기본값이 아니라
            // host의 실제 모드를 쓰도록 관측으로 나른다(DECCKM app_cursor_keys 형제). kitty_flags는 스택 최상단 u5.
            .app_keypad = core.application_keypad,
            .kitty_flags = core.kitty_flags.current().int(),
            .alternate_scroll = core.alternate_scroll,
            .mouse_tracking = core.mouse_tracking != .none,
            .mouse_tracking_mode = @intFromEnum(core.mouse_tracking), // 모드 단일 출처(위 bool은 구 client 미러)
            .bracketed_paste = core.bracketed_paste,
            .bell_count = bell_count,
            .clipboard_write_seq = clip.write_seq,
            .clipboard_read_seq = clip.read_seq,
            .clipboard_read_target = try allocator.dupe(u8, clip.read_target.items),
            .observer_generation = core.observerGeneration(),
            .title_generation = core.title_generation.load(.monotonic),
            .cols = core.size.cols,
            .rows = core.size.rows,
            .foreground_available = true,
            .foreground_pgid = foreground_pgid,
            // GUI 상태바가 host-backed 터미널을 재려면 **뿌리 pid**가 필요하다. host만 그것을 알고 있고
            // (PTY가 이 프로세스 안에 있다), 값은 runtime 수명 동안 안 바뀐다 — 그래서 full-state 관측에
            // 그냥 싣는다(별도 RPC를 두면 같은 사실에 왕복이 하나 더 생긴다).
            .child_pid = child_pid,
            // 데몬 자신의 pid. 관측마다 같은 값이지만 **자기 pid를 아는 쪽이 host뿐**이라 여기서 싣는다.
            // 커널 인증(LOCAL_PEERPID)을 쓰지 않는 이유는 신뢰 경계가 늘지 않기 때문이다 — `child_pid`를
            // 이미 이 출처에서 받아 그 트리를 재므로, 같은 출처의 `host_pid`가 새 신뢰를 요구하지 않는다.
            .host_pid = @intCast(c.getpid()),
            .processes = processes,
        };
        return result;
    }

    /// Refreshing the cheap fixed foreground cache is not itself an observation source change.
    /// Compare the sampled process identity first so an idle 500ms poll does not force a core lock,
    /// heap copies, canonical JSON serialization, or a cache transaction.
    fn refreshForegroundCache(self: *RuntimeManager, handle: RuntimeHandle, now_ns: i128) !bool {
        const gop = try self.foreground_cache.getOrPut(self.allocator, handle);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        const foreground = gop.value_ptr;
        const due = foreground.refreshed_at_ns == 0 or
            now_ns < foreground.refreshed_at_ns or
            now_ns - foreground.refreshed_at_ns >= foreground_refresh_ns;
        if (!due) return false;

        var names: [64]ForegroundProcessName = undefined;
        const be = self.backend_impl.backend();
        const count = be.foregroundProcessNames(handle, &names);
        const pgid = be.foregroundProcessGroup(handle);
        var changed = foreground.refreshed_at_ns == 0 or
            foreground.count != count or foreground.pgid != pgid;
        if (!changed) for (names[0..count], 0..) |name, index| {
            const old = &foreground.names[index];
            if (old.pid != name.pid or !std.mem.eql(u8, old.slice(), name.slice())) {
                changed = true;
                break;
            }
        };
        const next_generation = if (changed)
            std.math.add(u64, foreground.generation, 1) catch
                return error.ForegroundGenerationExhausted
        else
            foreground.generation;
        @memcpy(foreground.names[0..count], names[0..count]);
        foreground.count = count;
        foreground.pgid = pgid;
        foreground.refreshed_at_ns = now_ns;
        foreground.generation = next_generation;
        return changed;
    }

    fn kernelCwdEligible(self: *RuntimeManager, handle: RuntimeHandle) !bool {
        const surface = self.backend_impl.surfaceFor(handle) orelse return error.RuntimeNotFound;
        surface.lockCore(self.io);
        defer surface.unlockCore(self.io);
        return surface.core.currentCwd().len == 0 and surface.core.sshRemoteDest() == null;
    }

    fn refreshKernelCwdCache(
        self: *RuntimeManager,
        handle: RuntimeHandle,
        now_ns: i128,
        force_eligibility_check: bool,
    ) !bool {
        if (!force_eligibility_check) if (self.kernel_cwd_cache.get(handle)) |cache| {
            const due = cache.refreshed_at_ns == 0 or
                now_ns < cache.refreshed_at_ns or
                now_ns - cache.refreshed_at_ns >= kernel_cwd_refresh_ns;
            if (!due) return false;
        };
        const eligible = try self.kernelCwdEligible(handle);
        if (!eligible) {
            const cache = self.kernel_cwd_cache.getPtr(handle) orelse return false;
            return cache.clear(now_ns);
        }

        // A product materialization must fail closed immediately when OSC/SSH takes precedence,
        // but it must not turn an output wake into a proc_pidinfo/gethostname sampling point. Once
        // the eligible cache exists, the independent 500ms metadata cadence remains its sole
        // refresher. The no-cache initial observation still falls through and seeds the pair.
        if (force_eligibility_check and self.kernel_cwd_cache.contains(handle)) return false;

        const gop = try self.kernel_cwd_cache.getOrPut(self.allocator, handle);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        const cache = gop.value_ptr;
        const due = cache.refreshed_at_ns == 0 or
            now_ns < cache.refreshed_at_ns or
            now_ns - cache.refreshed_at_ns >= kernel_cwd_refresh_ns;
        if (!due) return false;

        var cwd_buffer: [posix.PATH_MAX]u8 = undefined;
        const cwd = self.backend_impl.backend().processCwd(handle, &cwd_buffer) orelse
            return cache.clear(now_ns);
        var hostname_buffer: [posix.HOST_NAME_MAX]u8 = undefined;
        const hostname = posix.gethostname(&hostname_buffer) catch
            return cache.clear(now_ns);
        if (hostname.len == 0) return cache.clear(now_ns);
        return cache.replace(cwd, hostname, now_ns) catch |err| switch (err) {
            error.InvalidKernelCwd, error.KernelCwdTooLong => cache.clear(now_ns),
            error.KernelCwdGenerationExhausted => error.KernelCwdGenerationExhausted,
        };
    }

    fn metadataSource(
        self: *RuntimeManager,
        handle: RuntimeHandle,
        now_ns: u64,
    ) !runtime_metadata_sampler.Source {
        _ = try self.refreshForegroundCache(handle, now_ns);
        _ = try self.refreshKernelCwdCache(handle, now_ns, false);
        const foreground = self.foreground_cache.getPtr(handle) orelse
            return error.RuntimeNotFound;
        const kernel_cwd = self.kernel_cwd_cache.get(handle);
        const surface = self.backend_impl.surfaceFor(handle) orelse
            return error.RuntimeNotFound;
        return .{
            .observer_generation = surface.core.observerGeneration(),
            .title_generation = surface.core.title_generation.load(.monotonic),
            .foreground_generation = foreground.generation,
            .cwd_generation = if (kernel_cwd) |cache| cache.generation else 0,
        };
    }

    fn installMetadataSampler(
        self: *RuntimeManager,
        runtime_id: u128,
        handle: RuntimeHandle,
        now_ns: u64,
    ) !void {
        const source = try self.metadataSource(handle, now_ns);
        try self.metadata_samplers.putNoClobber(
            self.allocator,
            runtime_id,
            runtime_metadata_sampler.Record.init(source, now_ns),
        );
    }

    fn sampleMetadataSource(
        self: *RuntimeManager,
        runtime_id: u128,
        handle: RuntimeHandle,
        now_ns: u64,
    ) void {
        const record = self.metadata_samplers.getPtr(runtime_id) orelse {
            self.metadata_sampler_failures +|= 1;
            return;
        };
        if (record.terminal) return;
        const source = self.metadataSource(handle, now_ns) catch {
            self.metadata_sampler_failures +|= 1;
            return;
        };
        self.metadata_sampler_visits +|= 1;
        switch (record.sample(source, now_ns) catch {
            record.terminal = true;
            self.metadata_sampler_failures +|= 1;
            return;
        }) {
            .changed => self.metadata_sampler_changes +|= 1,
            .stale, .unchanged => {},
        }
    }

    fn sampleMetadataSources(self: *RuntimeManager, now_ns: u64) void {
        const deadline_ns = 100 * std.time.ns_per_ms;
        if (self.next_metadata_sample_ns != 0 and now_ns < self.next_metadata_sample_ns)
            return;
        self.next_metadata_sample_ns = now_ns +| deadline_ns;
        var items: [upgrade_limits.max_runtime_count]struct {
            runtime_id: u128,
            handle: RuntimeHandle,
        } = undefined;
        var count: usize = 0;
        var it = self.host_registry.entries.iterator();
        while (it.next()) |entry| {
            if (count == items.len) break;
            const slot = entry.value_ptr.*.runtime orelse continue;
            items[count] = .{
                .runtime_id = entry.key_ptr.*,
                .handle = @intFromPtr(slot),
            };
            count += 1;
        }
        for (items[0..count]) |item|
            self.sampleMetadataSource(item.runtime_id, item.handle, now_ns);
    }

    fn metadataChangeTokenOp(
        ctx: *anyopaque,
        runtime_id: u128,
    ) anyerror!server.MetadataChangeToken {
        const self: *RuntimeManager = @ptrCast(@alignCast(ctx));
        const record = self.metadata_samplers.get(runtime_id) orelse
            return error.RuntimeNotFound;
        if (record.terminal) return error.MetadataChangeTokenExhausted;
        return .{
            .incarnation = record.token.incarnation,
            .revision = record.token.revision,
        };
    }

    fn sampleMetadataSourcesOp(ctx: *anyopaque, now_ns: u64) void {
        const self: *RuntimeManager = @ptrCast(@alignCast(ctx));
        self.sampleMetadataSources(now_ns);
    }

    fn cachedObservationOp(
        ctx: *anyopaque,
        runtime_id: u128,
        request: server.ObservationRequest,
    ) anyerror!server.CachedRuntimeObservation {
        const self: *RuntimeManager = @ptrCast(@alignCast(ctx));
        switch (request) {
            .cadence_epoch => self.metadata_producer_visits +|= 1,
            .current, .fresh => {},
        }
        const handle = self.handleFor(runtime_id) orelse return error.RuntimeNotFound;
        const gop = try self.observation_caches.getOrPut(self.allocator, handle);
        if (!gop.found_existing) {
            errdefer _ = self.observation_caches.remove(handle);
            const record = self.allocator.create(ObservationCacheRecord) catch {
                return error.OutOfMemory;
            };
            errdefer self.allocator.destroy(record);
            record.* = .{
                .cache = try runtime_observation_cache.Cache.init(
                    self.allocator,
                    protocol.max_control_json,
                ),
            };
            gop.value_ptr.* = record;
        }
        const record = gop.value_ptr.*;
        const now_ns = std.Io.Clock.awake.now(self.io).nanoseconds;
        const surface = self.backend_impl.surfaceFor(handle) orelse return error.RuntimeNotFound;
        const cadence_epoch_advanced = switch (request) {
            .cadence_epoch => |epoch| record.cadence_epoch == null or epoch > record.cadence_epoch.?,
            else => false,
        };
        // A cadence is only a sampling opportunity. It must not itself become a source change:
        // otherwise N idle runtimes still take N core locks and serialize N observations every
        // 100ms. TerminalCore publishes both generations atomically, so this preflight is lock-free.
        // Foreground process identity and kernel cwd are the two non-core sources. Both retain an
        // independent 500ms refresh deadline. Equal/older epochs reuse the first view chosen for
        // that producer sweep.
        const may_sample_source = switch (request) {
            .current => true,
            .cadence_epoch => cadence_epoch_advanced,
            .fresh => false,
        };
        var foreground_changed = false;
        var kernel_cwd_changed = false;
        if (may_sample_source and record.cache.view() != null) {
            foreground_changed = try self.refreshForegroundCache(handle, now_ns);
            kernel_cwd_changed = try self.refreshKernelCwdCache(handle, now_ns, false);
        }
        const foreground_generation = if (self.foreground_cache.get(handle)) |foreground|
            foreground.generation
        else
            return error.RuntimeNotFound;
        const cwd_generation = if (self.kernel_cwd_cache.get(handle)) |cache| cache.generation else 0;
        const source_changed = may_sample_source and record.cache.view() != null and
            (surface.core.observerGeneration() != record.observer_generation or
                surface.core.title_generation.load(.monotonic) != record.title_generation or
                foreground_changed or
                foreground_generation != record.foreground_generation or
                kernel_cwd_changed or
                cwd_generation != record.cwd_generation);
        const refresh = switch (request) {
            .fresh => true,
            .current => record.cache.view() == null or
                now_ns < record.refreshed_at_ns or
                (now_ns - record.refreshed_at_ns >= 100 * std.time.ns_per_ms and
                    source_changed),
            .cadence_epoch => record.cache.view() == null or source_changed,
        };
        if (refresh) {
            const next_materialization_count = self.observation_materializations +| 1;
            var observation = try observationOp(self, runtime_id, self.allocator);
            defer observation.deinit(self.allocator);
            const canonical = server.canonicalizeObservation(self.allocator, observation) catch |err| switch (err) {
                error.InvalidObservation => return error.InvalidObservation,
                error.OutOfMemory => return error.OutOfMemory,
            };
            defer self.allocator.free(canonical);
            var prepared = record.cache.prepare(canonical) catch |err| switch (err) {
                error.CandidateTooLarge => return error.InvalidObservation,
                error.ChangeTokenExhausted => return error.ObservationTokenExhausted,
                error.TooManyPrepared => return error.ObservationTransactionCorrupt,
                error.OutOfMemory => return error.OutOfMemory,
            };
            var settled = false;
            defer if (!settled) prepared.discard();
            _ = record.cache.commit(&prepared) catch
                return error.ObservationTransactionCorrupt;
            settled = true;
            self.observation_materializations = next_materialization_count;
            record.refreshed_at_ns = now_ns;
            record.observer_generation = observation.observer_generation;
            record.title_generation = observation.title_generation;
            record.foreground_generation = foreground_generation;
            record.cwd_generation = if (self.kernel_cwd_cache.get(handle)) |cache| cache.generation else 0;
            switch (request) {
                .cadence_epoch => |epoch| {
                    if (record.cadence_epoch == null or epoch > record.cadence_epoch.?)
                        record.cadence_epoch = epoch;
                },
                else => {},
            }
        } else if (cadence_epoch_advanced) switch (request) {
            .cadence_epoch => |epoch| record.cadence_epoch = epoch,
            else => unreachable,
        };
        const view = record.cache.view() orelse return error.TransientObservationUnavailable;
        return .{ .canonical_json = view.bytes, .change_token = view.change_token };
    }

    /// runtime의 현재 화면을 screen_stream 레코드 스트림으로 투영한다(§12, P3-e2d). reader 스레드가 core를 쓰므로
    /// **core_mutex를 잡은 채** 투영하고(투영이 grapheme·색을 소유 버퍼로 복사), 반환된 소유 바이트만 unlock 뒤 caller가
    /// snapshot_chunk로 나눠 보낸다(io-render-threading.md — snapshot 슬라이스는 core alias라 lock 밖으로 새면 안 됨).
    fn snapshotOp(ctx: *anyopaque, runtime_id: u128, sequence: u64, allocator: std.mem.Allocator) anyerror!server.ProjectedSnapshot {
        const self: *RuntimeManager = @ptrCast(@alignCast(ctx));
        const handle = self.handleFor(runtime_id) orelse return error.RuntimeNotFound;
        const surface = self.backend_impl.surfaceFor(handle) orelse return error.RuntimeNotFound;
        const generation = if (self.host_registry.get(runtime_id)) |e| e.resize_generation else 0;
        if (self.screen_metrics_enabled) {
            self.screen_snapshot_calls +|= 1;
            self.screen_core_lock_acquisitions +|= 1;
        }
        surface.lockCore(self.io);
        defer surface.unlockCore(self.io);
        const bytes = try screen_snapshot.projectSnapshotBounded(
            allocator,
            &surface.core,
            .{ .generation = generation, .sequence = sequence },
            protocol.max_viewport_snapshot,
        );
        if (self.screen_metrics_enabled) self.screen_owned_allocations +|= 1;
        return .{ .bytes = bytes, .frontier = .{ .generation = generation, .sequence = sequence } };
    }

    /// `base`(client가 마지막으로 받은 full snapshot) 대비 현재 화면 변화를 계산한다(§9 delta). core lock 아래에서 현재
    /// full snapshot(다음 base)과 delta를 함께 만든다. grid/alt-screen 변화면 delta 대신 fresh snapshot을 보낸다(client가
    /// 화면 교체). `send`와 `new_base`는 항상 별개 버퍼다(caller가 둘 다 free해도 안전).
    fn deltaOp(ctx: *anyopaque, runtime_id: u128, base: []const u8, sequence: u64, allocator: std.mem.Allocator) anyerror!server.StreamUpdate {
        const self: *RuntimeManager = @ptrCast(@alignCast(ctx));
        const handle = self.handleFor(runtime_id) orelse return error.RuntimeNotFound;
        const surface = self.backend_impl.surfaceFor(handle) orelse return error.RuntimeNotFound;
        const generation = if (self.host_registry.get(runtime_id)) |e| e.resize_generation else 0;
        const opts = screen_snapshot.ProjectOptions{ .generation = generation, .sequence = sequence };
        if (self.screen_metrics_enabled) {
            self.screen_delta_calls +|= 1;
            self.screen_core_lock_acquisitions +|= 1;
        }
        surface.lockCore(self.io);
        defer surface.unlockCore(self.io);

        // computeDelta가 delta와 새 base(현재 full snapshot)를 **한 번의 row build로** 함께 준다(재투영 없음).
        const result = screen_snapshot.computeDeltaBounded(
            allocator,
            base,
            &surface.core,
            opts,
            protocol.max_viewport_snapshot,
        ) catch |e| switch (e) {
            error.SnapshotRequired => {
                // grid/alt 변화 → delta 불가, fresh snapshot을 보낸다. send는 new_base와 별개 버퍼여야 하므로 복사한다.
                const snap = try screen_snapshot.projectSnapshotBounded(
                    allocator,
                    &surface.core,
                    opts,
                    protocol.max_viewport_snapshot,
                );
                errdefer allocator.free(snap);
                const send = allocator.dupe(u8, snap) catch return error.OutOfMemory;
                if (self.screen_metrics_enabled) self.screen_owned_allocations +|= 2;
                return .{
                    .send = send,
                    .is_snapshot = true,
                    .new_base = snap,
                    .frontier = .{ .generation = generation, .sequence = sequence },
                };
            },
            else => return e,
        };
        if (self.screen_metrics_enabled) self.screen_owned_allocations +|= 2;
        return .{
            .send = result.delta,
            .is_snapshot = false,
            .new_base = result.snapshot,
            .frontier = .{
                .generation = generation,
                .sequence = if (result.delta.len == 0) sequence - 1 else sequence,
            },
        };
    }

    /// N2a journal의 이 runtime용 GUI row를 직렬화하되 아직 ack하지 않는다. server가 response frame을
    /// owner control queue에 admission한 뒤 notificationCommitOp가 같은 stable event만 ack해 backpressure
    /// 소실을 막는다. wire body는 기존 client 호환을 위해 title/body 그대로이며 generation 칸에 event_id를 싣는다.
    fn notificationPeekOp(
        ctx: *anyopaque,
        runtime_id: u128,
        stable_delivery: bool,
        allocator: std.mem.Allocator,
    ) anyerror!server.NotificationSnapshot {
        const self: *RuntimeManager = @ptrCast(@alignCast(ctx));
        if (self.handleFor(runtime_id) == null) return error.RuntimeNotFound;
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        var generation: ?u64 = null;
        if (self.notification_journal.oldestPendingForRuntime(.gui, runtime_id)) |row| {
            if (stable_delivery) {
                var host_buf: [32]u8 = undefined;
                var runtime_buf: [32]u8 = undefined;
                const hid = std.fmt.bufPrint(&host_buf, "{x:0>32}", .{row.key.host_id}) catch unreachable;
                const rid = std.fmt.bufPrint(&runtime_buf, "{x:0>32}", .{row.runtime_id}) catch unreachable;
                js.write(.{ .event = .{
                    .hid = hid,
                    .rid = rid,
                    .eid = row.key.event_id,
                    .occurred_at_ns = row.occurred_at_ns,
                    .title = row.title,
                    .body = row.body,
                    .display_label = row.display_label,
                } }) catch return error.OutOfMemory;
            } else {
                js.write(.{ .title = row.title, .body = row.body }) catch return error.OutOfMemory;
            }
            generation = row.key.event_id;
        } else {
            if (stable_delivery)
                js.write(.{ .event = @as(?u8, null) }) catch return error.OutOfMemory
            else
                js.write(.{ .title = "", .body = "" }) catch return error.OutOfMemory;
        }
        return .{
            .body = allocator.dupe(u8, out.written()) catch return error.OutOfMemory,
            .generation = generation,
        };
    }

    fn notificationCommitOp(
        ctx: *anyopaque,
        runtime_id: u128,
        generation: ?u64,
    ) bool {
        const expected = generation orelse return true;
        const self: *RuntimeManager = @ptrCast(@alignCast(ctx));
        if (self.handleFor(runtime_id) == null) return false;
        const host_id = self.notification_journal.hostId() orelse return false;
        const key: notification_journal.Key = .{ .host_id = host_id, .event_id = expected };
        const row = self.notification_journal.peek(key) orelse return false;
        if (row.runtime_id != runtime_id) return false;
        return switch (self.notification_journal.ack(key, .gui)) {
            .acknowledged, .already_acknowledged => true,
            .not_found, .invalid_owner => false,
        };
    }

    fn notificationConfigUpdateOp(
        ctx: *anyopaque,
        runtime_id: u128,
        current_controller_generation: u64,
        snapshot: server.NotificationConfigSnapshot,
    ) anyerror!bool {
        const self: *RuntimeManager = @ptrCast(@alignCast(ctx));
        return switch (try self.notification_metadata.update(runtime_id, current_controller_generation, .{
            .expected_controller_generation = current_controller_generation,
            .config_generation = snapshot.config_generation,
            .notifications_osc = snapshot.notifications_osc,
            .display_label = snapshot.display_label,
        })) {
            .applied => true,
            .runtime_not_found => error.RuntimeNotFound,
            .stale_controller, .stale_config => false,
        };
    }

    /// 검증된 wire command를 내부 `CoreCommand`로 명시 변환한다. PTY 응답·parser/config를 건드리는 명령은 host reader
    /// queue에 넣어 reader가 유일한 mutator/writer로 남는다. 반면 negotiated selection-state 명령은 PTY 응답을 만들지
    /// 않는 presentation state이고, 뒤따르는 `selected_text(authoritative)`가 적용 완료 fence를 필요로 한다. 이 닫힌 다섯
    /// 명령만 dispatch 순서대로 core lock 아래 적용해 RPC 응답 자체를 completion fence로 삼는다.
    fn coreCommandOp(ctx: *anyopaque, runtime_id: u128, wire_command: core_command_wire.Command) anyerror!void {
        const self: *RuntimeManager = @ptrCast(@alignCast(ctx));
        const handle = self.handleFor(runtime_id) orelse return error.RuntimeNotFound;
        const command = try coreCommandFromWire(wire_command);
        switch (wire_command) {
            .selection_start,
            .selection_extend,
            .selection_extend_or_collapse,
            .selection_scroll_and_extend,
            .selection_clear,
            => {
                const surface = self.backend_impl.surfaceFor(handle) orelse return error.RuntimeNotFound;
                surface.lockCore(self.io);
                defer surface.unlockCore(self.io);
                _ = core_command.apply(&surface.core, command);
                try self.publishScreenChange(runtime_id);
                return;
            },
            else => {},
        }
        return self.backend_impl.backend().enqueueCoreCommand(handle, command, self.io);
    }

    /// host-backed 마우스 리포트(§ 입력 패리티): client 마우스 이벤트를 host의 **reader에 report_mouse core command로
    /// enqueue**한다 — reader가 적용하면 core가 자기 mouse_tracking/format으로 SGR/x10 응답을 만들고, reader가 그
    /// pendingResponse를 PTY로 흘린다(로컬 휠·클릭 경로와 **동형**: enqueueCoreCommand→reader 적용+flush). dispatch
    /// 스레드가 직접 apply+writeInput하면 reader의 response PTY-write와 같은 자식-stdin fd에 동시 쓰기(race)가 되므로,
    /// 모든 PTY 입력 쓰기를 reader 단일 스레드로 모은다(§io-render-threading).
    fn reportMouseOp(ctx: *anyopaque, runtime_id: u128, report: server.MouseReport) anyerror!void {
        const self: *RuntimeManager = @ptrCast(@alignCast(ctx));
        const handle = self.handleFor(runtime_id) orelse return error.RuntimeNotFound;
        return self.backend_impl.backend().enqueueCoreCommand(handle, .{ .report_mouse = .{
            .button = report.button,
            .col = report.col,
            .row = report.row,
            .x_px = report.x_px,
            .y_px = report.y_px,
            .pressed = report.pressed,
            .motion = report.motion,
            .mods = report.mods,
        } }, self.io);
    }

    /// 원격 client가 보낸 뷰포트 선택 span을 host core에 적용해 텍스트를 뽑는다(§6b 원격 선택 복사). **로컬과 같은
    /// `extractSelection`** 을 재사용하므로 soft-wrap 이음·블록·스크롤백 걸친 선택까지 충실하다(선택 의미론 단일 출처). host
    /// legacy viewport/all 요청은 core lock 아래 transient set-extract-clear하고, negotiated authoritative 요청은 앞선
    /// selection-state fence가 남긴 host anchor/head를 변경 없이 추출한다. span의 뷰포트 좌표는 host의 현재 view_offset
    /// 기준으로 abs 변환된다(selectionStart/Extend가 내부에서). JSON `{text}`(임의
    /// 바이트라 실 encoder로 escape). 추출 실패/빈 선택은 `{text:""}`.
    fn selectedTextOp(ctx: *anyopaque, runtime_id: u128, span: server.SelectSpan, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *RuntimeManager = @ptrCast(@alignCast(ctx));
        const handle = self.handleFor(runtime_id) orelse return error.RuntimeNotFound;
        const surface = self.backend_impl.surfaceFor(handle) orelse return error.RuntimeNotFound;
        surface.lockCore(self.io);
        defer surface.unlockCore(self.io);
        const extracted = blk: {
            if (span.authoritative) {
                break :blk surface.core.extractSelection(allocator) catch null;
            } else if (span.all) {
                surface.core.selectAll();
            } else {
                surface.core.selectionStart(span.sr, span.sc);
                if (span.block) surface.core.setSelectionBlock(true);
                surface.core.selectionExtend(span.er, span.ec);
            }
            const value = surface.core.extractSelection(allocator) catch null;
            surface.core.selectionClear(); // transient — host core 선택 원복.
            break :blk value;
        };
        defer if (extracted) |e| allocator.free(e);
        const text: []const u8 = extracted orelse "";
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        js.write(.{ .text = text }) catch return error.OutOfMemory;
        return allocator.dupe(u8, out.written()) catch return error.OutOfMemory;
    }

    /// 원격 Cmd+클릭 링크 열기: host가 **콘텐츠·cwd·파일시스템을 아는 자기 core**로 `extractUrlAt`(로컬과 같은 함수)을
    /// 돌려 열 대상을 준다 — 추출은 soft-wrap 이음·스크롤백까지 충실하고, file_path는 host의 cwd/$HOME으로 resolve해
    /// **host FS에서 존재를 확인**한 절대 경로만 돌려준다(client가 자기 FS로 stat하면 원격 경로를 잘못 판정한다).
    /// `scopes`는 client의 `input.link-detection` 비트 — hover 필터와 같은 값이라 "밑줄 보이는 곳 = 열리는 곳"이 유지된다.
    /// 링크가 없거나 미존재 경로면 `{text:""}`(client는 일반 클릭으로 처리). 텍스트는 임의 바이트라 실 encoder로 escape.
    fn linkAtOp(ctx: *anyopaque, runtime_id: u128, row: u16, col: u16, scopes: u8, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *RuntimeManager = @ptrCast(@alignCast(ctx));
        const handle = self.handleFor(runtime_id) orelse return error.RuntimeNotFound;
        const surface = self.backend_impl.surfaceFor(handle) orelse return error.RuntimeNotFound;
        surface.lockCore(self.io);
        defer surface.unlockCore(self.io);
        // extractUrlAt은 스크롤백을 읽고 cwd(OSC 7)를 참조하며 존재 stat까지 한다 — 로컬 클릭 경로와 같은 함수라
        // 분류·다듬기·:line:col 처리가 자동으로 일치한다.
        const extracted = (surface.core.extractUrlAt(allocator, row, col, unpackLinkScopes(scopes)) catch null) orelse
            return allocator.dupe(u8, "{\"text\":\"\"}") catch return error.OutOfMemory;
        defer allocator.free(extracted.text);
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        js.write(.{ .text = extracted.text, .kind = @intFromEnum(extracted.kind) }) catch return error.OutOfMemory;
        return allocator.dupe(u8, out.written()) catch return error.OutOfMemory;
    }

    /// 즉시 관측이 필요한가 — core에 BEL이나 OSC 52 요청이 대기 중이면 true. **소비하지 않는다**(관측을 만들 때
    /// observationOp가 drain한다). 상태 폴링 주기(약 100ms)를 기다리면 소리·클립보드 지연이 그대로 체감되므로,
    /// 이벤트가 있을 때만 다음 serve tick(약 20ms)으로 앞당기는 트리거다.
    fn observationUrgentOp(ctx: *anyopaque, runtime_id: u128) bool {
        const self: *RuntimeManager = @ptrCast(@alignCast(ctx));
        const handle = self.handleFor(runtime_id) orelse return false;
        const surface = self.backend_impl.surfaceFor(handle) orelse return false;
        surface.lockCore(self.io);
        defer surface.unlockCore(self.io);
        return surface.core.bellPending() or
            surface.core.pendingClipboardWrite().len > 0 or
            surface.core.clipboardReadPending();
    }

    /// OSC 52 write 텍스트를 client에 넘긴다. **base64로 싣는다** — OSC 52 데이터는 임의 바이트(0x80~0xFF 포함)라
    /// JSON 문자열로 그대로 보내면 client의 strict 디코더가 UTF-8 검증에서 거부하고 connection을 fail-close한다
    /// (복사 한 번에 앱 전역 host 연결이 끊긴다). `runtime.find`의 검색어 hex와 같은 규율이다.
    ///
    /// `too_large`는 0/1 정수다 — strict 응답 디코더가 string/number만 다루므로 bool을 쓰면 파싱이 깨진다.
    /// 크기: control frame은 `max_control_json`(256 KiB)이라 그보다 큰 복사는 애초에 실을 수 없다. host가 **미리
    /// 판정해** 초과분은 텍스트 없이 `too_large`로 알려 client가 로컬과 같은 안내를 띄우게 한다(조용한 유실 금지).
    /// 가져간 뒤에만 버퍼를 비운다 — 인코딩/전송이 실패했는데 원본을 버리면 복구할 수 없다.
    fn clipboardWriteOp(ctx: *anyopaque, runtime_id: u128, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *RuntimeManager = @ptrCast(@alignCast(ctx));
        const handle = self.handleFor(runtime_id) orelse return error.RuntimeNotFound;
        const clip = self.clipboards.getPtr(handle) orelse
            return allocator.dupe(u8, "{\"b64\":\"\",\"too_large\":0}") catch return error.OutOfMemory;
        const raw = clip.write_text.items;
        if (raw.len == 0) return allocator.dupe(u8, "{\"b64\":\"\",\"too_large\":0}") catch return error.OutOfMemory;
        if (raw.len > max_clipboard_wire_bytes) {
            clip.write_text.clearRetainingCapacity(); // 못 보낼 것은 붙들지 않는다(다음 복사를 위해 비움)
            return allocator.dupe(u8, "{\"b64\":\"\",\"too_large\":1}") catch return error.OutOfMemory;
        }
        const enc = std.base64.standard.Encoder;
        const b64 = allocator.alloc(u8, enc.calcSize(raw.len)) catch return error.OutOfMemory;
        defer allocator.free(b64);
        _ = enc.encode(b64, raw);
        const body = std.fmt.allocPrint(allocator, "{{\"b64\":\"{s}\",\"too_large\":0}}", .{b64}) catch return error.OutOfMemory;
        clip.write_text.clearRetainingCapacity(); // 성공적으로 인코딩한 뒤에만 소비한다
        return body;
    }

    /// client가 보낸 scope 비트를 `LinkScopes`로 푼다(비트 위치는 `terminal.LinkScope`의 `@intFromEnum` — wire 약속).
    /// 링크 감지 정책은 client config 소유라 host는 받은 값을 그대로 적용만 한다(host 해석 / client 정책 분리).
    fn unpackLinkScopes(bits: u8) terminal.LinkScopes {
        const bit = struct {
            fn on(v: u8, scope: terminal.LinkScope) bool {
                return (v & (@as(u8, 1) << @intCast(@intFromEnum(scope)))) != 0;
            }
        }.on;
        return .{
            .web = bit(bits, .web),
            .extra_schemes = bit(bits, .extra_schemes),
            .absolute_path = bit(bits, .absolute_path),
            .home_path = bit(bits, .home_path),
            .dot_relative = bit(bits, .dot_relative),
            .bare_relative = bit(bits, .bare_relative),
        };
    }

    /// 단어/줄/전체 선택(§6b-2): host가 **콘텐츠를 아는 자기 core**로 경계를 계산해 결과 뷰포트 선택
    /// span을 JSON으로 준다. 빈 client placeholder는 경계를 모르므로 host가 계산(선택 의미론 host 단일 출처). 계산한
    /// 선택은 host core에도 남겨 `runtime_selection_state_v1`의 후속 확장/권위 복사가 같은 anchor/head를 이어받는다.
    /// client는 반환 span을 placeholder에 적용해 즉시 하이라이트한다.
    /// word op의 separators_hex는 64-byte strict hex/UTF-8로 닫고 현재 config 값을 그대로 적용한다.
    /// 필드가 없는 구 client는 빈 구분자(공백 경계)로 호환된다. 미지원 op·빈 선택은 `{sel:false}`.
    fn selectOpOp(ctx: *anyopaque, runtime_id: u128, op: []const u8, row: u16, col: u16, separators_hex: []const u8, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *RuntimeManager = @ptrCast(@alignCast(ctx));
        const handle = self.handleFor(runtime_id) orelse return error.RuntimeNotFound;
        const surface = self.backend_impl.surfaceFor(handle) orelse return error.RuntimeNotFound;
        surface.lockCore(self.io);
        defer surface.unlockCore(self.io);
        if (std.mem.eql(u8, op, "word")) {
            var separators_buf: [64]u8 = undefined;
            const separators = decodeWordSeparators(separators_hex, &separators_buf) orelse return error.InvalidRequest;
            surface.core.selectWordAt(row, col, separators);
        } else if (std.mem.eql(u8, op, "line")) {
            surface.core.selectLineAt(row);
        } else if (std.mem.eql(u8, op, "all")) {
            surface.core.selectAll();
        } else {
            return allocator.dupe(u8, "{\"sel\":false}") catch return error.OutOfMemory;
        }
        try self.publishScreenChange(runtime_id);
        const maybe = surface.core.selectionViewportSpan();
        if (maybe) |sp| {
            return std.fmt.allocPrint(allocator, "{{\"sel\":true,\"sr\":{d},\"sc\":{d},\"er\":{d},\"ec\":{d},\"block\":{}}}", .{ sp.start.row, sp.start.col, sp.end.row, sp.end.col, sp.block }) catch return error.OutOfMemory;
        }
        return allocator.dupe(u8, "{\"sel\":false}") catch return error.OutOfMemory;
    }

    /// 원격 검색(§6c): client가 보낸 검색어(hex)로 host가 **콘텐츠·스크롤백을 아는 자기 core**에서 `findMatches`(로컬과 같은
    /// 함수)로 매치를 찾고, 보이는 매치를 `matchViewportSpan`으로 클립해 `{count, spans:[sr,sc,er,ec,...]}`로 준다(선택과 같이
    /// 검색 의미론 host 단일 출처). count=전체 매치 수, spans=현재 뷰포트에 보이는 매치의 flat 좌표. core lock 아래(findMatches가
    /// 스크롤백 rewrap으로 core mutate).
    fn findOp(ctx: *anyopaque, runtime_id: u128, query_hex: []const u8, cur_index: u32, scroll: bool, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *RuntimeManager = @ptrCast(@alignCast(ctx));
        const handle = self.handleFor(runtime_id) orelse return error.RuntimeNotFound;
        const surface = self.backend_impl.surfaceFor(handle) orelse return error.RuntimeNotFound;
        var qbuf: [512]u8 = undefined;
        const query = qbuf[0..hexDecodeInto(query_hex, &qbuf)];

        surface.lockCore(self.io);
        defer surface.unlockCore(self.io);
        var matches: std.ArrayList(terminal.Match) = .empty;
        defer matches.deinit(allocator);
        surface.core.findMatches(allocator, query, &matches) catch {}; // 실패 시 빈 매치(best-effort).
        // §6c-2 네비: scroll이면 현재 매치(cur_index)의 abs 위치로 host 화면을 이동한다 — client가 그 매치를 보게(view_offset
        // 변화 → 다음 delta로 스크롤 화면 투영). 그 뒤 클립하므로 현재 매치가 보이게 된다.
        if (scroll and cur_index < matches.items.len) {
            surface.core.scrollToAbs(matches.items[cur_index].start.row);
            // Search navigation changes the authoritative viewport without passing through the
            // PTY reader queue, so it must publish the same screen-change edge explicitly.
            try self.publishScreenChange(runtime_id);
        }

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        var buf: [96]u8 = undefined;
        // voff=아래 span들을 계산한 기준 view_offset. 위 scroll 분기가 host 화면을 옮겼으면 client는 그 스크롤을
        // **아직 delta로 못 받은 상태**라, 응답 span을 그대로 그리면 좌표계가 다른 화면에 하이라이트를 찍는다
        // (= 이전 하이라이트가 남아 보이는 증상). client가 자기 화면과 이 값을 대조해 정합할 때만 적용한다.
        // cur=현재 매치의 뷰포트 span(보이면 4정수, 안 보이면 빈 배열).
        try out.appendSlice(allocator, try std.fmt.bufPrint(&buf, "{{\"count\":{d},\"voff\":{d},\"cur\":[", .{ matches.items.len, surface.core.viewOffset() }));
        if (cur_index < matches.items.len) {
            if (surface.core.matchViewportSpan(matches.items[cur_index])) |cs| {
                try out.appendSlice(allocator, try std.fmt.bufPrint(&buf, "{d},{d},{d},{d}", .{ cs.start.row, cs.start.col, cs.end.row, cs.end.col }));
            }
        }
        // spans=보이는 **비현재** 매치.
        try out.appendSlice(allocator, "],\"spans\":[");
        var first = true;
        for (matches.items, 0..) |m, mi| {
            if (mi == cur_index) continue; // 현재는 cur에 담았다.
            const span = surface.core.matchViewportSpan(m) orelse continue; // 뷰포트 밖 매치는 렌더 안 함.
            if (!first) try out.append(allocator, ',');
            first = false;
            try out.appendSlice(allocator, try std.fmt.bufPrint(&buf, "{d},{d},{d},{d}", .{ span.start.row, span.start.col, span.end.row, span.end.col }));
        }
        try out.appendSlice(allocator, "]}");
        return out.toOwnedSlice(allocator);
    }

    /// runtime_id → in-process handle. registry entry의 opaque 슬롯에서 되읽는다(spawn이 심어 둔 값). 없으면 null.
    fn handleFor(self: *RuntimeManager, runtime_id: u128) ?RuntimeHandle {
        const entry = self.host_registry.get(runtime_id) orelse return null;
        const slot = entry.runtime orelse return null;
        return @intFromPtr(slot);
    }

    fn screenChangeTokenOp(ctx: *anyopaque, runtime_id: u128) anyerror!server.ScreenChangeToken {
        const self: *RuntimeManager = @ptrCast(@alignCast(ctx));
        if (self.handleFor(runtime_id) == null) return error.RuntimeNotFound;
        return (self.screen_changes.get(runtime_id) orelse return error.RuntimeNotFound).token;
    }

    fn advanceScreenChange(self: *RuntimeManager, runtime_id: u128) error{
        RuntimeNotFound,
        ScreenChangeTokenExhausted,
    }!void {
        if (self.handleFor(runtime_id) == null) return error.RuntimeNotFound;
        const record = self.screen_changes.getPtr(runtime_id) orelse return error.RuntimeNotFound;
        try record.advance();
    }

    /// Owner-side mutations use the same coalescing pipe as reader output. Publication precedes
    /// notify, so a full pipe means an unread wake already owns the obligation.
    fn publishScreenChange(self: *RuntimeManager, runtime_id: u128) !void {
        try self.advanceScreenChange(runtime_id);
        if (self.output_wake) |*wake| OutputWake.notify(wake);
    }

    /// 실 PTY runtime을 띄운다: backend.spawn(forkpty) → attach(reader 시작) → host registry 등록. `runtime_id`를 돌려준다.
    /// argv/cwd 슬라이스는 backend.spawn이 동기적으로 복사하므로(PtySession.spawn이 dupeZ) transient여도 안전하다.
    /// 에러 집합은 backend(anyerror)를 그대로 전파한다 — `error.EmptyArgv`/`error.IdSpaceExhausted`는 이 매니저 고유.
    fn spawnRuntime(self: *RuntimeManager, params: server.RuntimeSpawnParams) anyerror!u128 {
        if (params.argv.len == 0) return error.EmptyArgv; // server가 이미 거르지만 방어(handle 낭비 방지).
        // daemon-wide runtime/grid 예산은 registry가 SSOT다. forkpty/core allocation 전에 확인하고 실제 publish에서
        // 같은 검사를 반복해, 거부된 same-UID spawn이 child/FD/heap을 잠시라도 만들지 않게 한다.
        try self.host_registry.canRegister(params.cols, params.rows);
        // maxInt handle을 발급하면 성공 뒤 cursor 증가가 wrap/trap한다. PTY를
        // 만들기 전에 거부해 live child를 띄운 뒤 실패하는 경로도 없앤다.
        if (self.next_handle == std.math.maxInt(RuntimeHandle))
            return error.IdSpaceExhausted;
        const handle = self.next_handle;
        // **runtime_id 를 spawn 보다 먼저 발급한다.** 자식 env 는 spawn 시점에 굳으므로, 훅 로그의 pane 칸
        // (=`runtime_id`)을 실으려면 이 순서여야 한다. 등록은 여전히 spawn **성공 뒤**다 — 실패한 spawn 이
        // registry 에 자리를 남기면 재접속 조회가 없는 runtime 을 가리킨다.
        //
        // 충돌은 128-bit 무작위라 사실상 불가능하지만, 등록 전에 한 번 물어 방어한다(옛 코드의 8회 재시도
        // 루프가 하던 일 — 다만 그때는 spawn 뒤였으므로 재시도가 공짜였고, 지금은 자식이 이미 그 값을
        // 들고 있으므로 «다시 뽑기» 가 성립하지 않는다. 그래서 뽑기 전에 비어 있음을 확인한다).
        var runtime_id = newRuntimeId();
        var mint_attempts: usize = 0;
        while (self.host_registry.get(runtime_id) != null) : (mint_attempts += 1) {
            if (mint_attempts >= 8) return error.IdSpaceExhausted; // 도달 불가
            runtime_id = newRuntimeId();
        }

        try self.notification_metadata.install(runtime_id, if (params.initial_notification) |snapshot| .{
            .config_generation = snapshot.config_generation,
            .notifications_osc = snapshot.notifications_osc,
            .display_label = snapshot.display_label,
        } else null);
        errdefer std.debug.assert(self.notification_metadata.remove(runtime_id));

        // 훅 로그 경로의 두 칸(docs/agent-hooks.md §4). 모양의 단일 출처는 계약 모듈이다 — host 가 심는
        // 이름과 GUI 가 읽는 이름이 갈리면 그 Term 은 자기 이벤트를 못 읽는다.
        //
        // ⚠️ 버퍼는 이 함수 스택에 둔다. `be.spawn` 안에서 env 가 owned 사본으로 굳으므로 그 호출까지만
        // 살아 있으면 된다(`PtySession.spawn` → `EnvStorage`).
        const hook_command = maru.session.agent_hook_command;
        var hook_instance_buf: [hook_command.instance_token_max]u8 = undefined;
        var hook_pane_buf: [hook_command.pane_token_max]u8 = undefined;
        const hook_instance: ?[]const u8 = if (self.hook_identity) |identity|
            hook_command.formatHostInstance(&hook_instance_buf, identity.host_id)
        else
            null;
        const hook_pane: ?[]const u8 = if (self.hook_identity != null)
            hook_command.formatRuntimePane(&hook_pane_buf, runtime_id)
        else
            null; // 인스턴스 칸이 없으면 pane 칸만 실어도 훅은 경로를 못 만든다 — 둘을 함께 다룬다.
        // **칸이 없으면 훅은 조용히 나간다**(계약 §4.1 — 훅은 mkdir 하지 않는다). init 에서 한 번 만들지만
        // 그 사이 사용자가 캐시를 비웠을 수 있어 spawn 마다 확인한다(이미 있으면 EEXIST 로 no-op).
        if (self.hook_identity) |identity|
            agent_hook_logs.ensureInstanceDir(self.io, identity.log_base, identity.host_id);

        const be = self.backend_impl.backend();
        const size = maru.terminal.Size{ .cols = params.cols, .rows = params.rows };
        const args: []const []const u8 = if (params.argv.len > 1) params.argv[1..] else &.{};
        const initial_config: ?core_command.RuntimeConfig = if (params.initial_config) |config| blk: {
            const command = try coreCommandFromWire(.{ .set_runtime_config = config });
            break :blk command.set_runtime_config;
        } else null;

        _ = try be.spawn(.{
            .handle = handle,
            .request = .{
                .command = params.argv[0],
                .args = args,
                .cwd = params.cwd,
                .login = params.login,
                .env = params.env,
                .parent_env = params.parent_env,
                .env_overrides = params.env_overrides,
                .term = params.term,
                .shell_integration = if (params.shell_integration_dir) |dir| .{ .assets_dir = dir } else null,
                .ssh_integration_bin = params.ssh_integration_bin,
                .pane_id = params.pane_id,
                .hook_instance = hook_instance,
                .hook_pane = hook_pane,
                .size = size,
            },
            .size = size,
            .queue_capacity = default_queue_capacity,
            // backend seam이 pre-reader bootstrap의 단일 소유자다. 새 backend도 이 필드를 무시하면 first-output
            // parity 계약을 만족하지 못하며, RuntimeManager가 surface 구현을 알아 직접 mutate하지 않는다.
            .initial_config = initial_config,
        });
        // 여기부터 실패하면 방금 만든 runtime을 회수한다(closeAndDetach로 PTY/자식/reader 종료 → remove로 reader join+슬롯 해제).
        errdefer {
            if (be.closeAndDetach(handle) == .event_pending)
                @panic("runtime manager teardown reached pending close state");
            if (be.remove(handle) != .removed)
                @panic("runtime manager teardown lost its runtime");
        }
        if (self.output_metrics_enabled) {
            const terminal_slot = self.backend_impl.terminalForHostLifecycle(handle) orelse
                return error.RuntimeNotFound;
            terminal_slot.live_pty.setOutputByteCounter(&self.observed_output_bytes);
        }
        if (self.output_wake) |*wake| {
            const terminal_slot = self.backend_impl.terminalForHostLifecycle(handle) orelse
                return error.RuntimeNotFound;
            terminal_slot.live_pty.eventQueue().setWakeNotifier(.{
                .ctx = wake,
                .notify = OutputWake.notify,
            });
        }
        _ = try be.attach(handle, true); // backend가 initial_config를 적용한 뒤 reader 시작 — 첫 output부터 host 설정 사용.

        // **위에서 뽑아 자식에게 실어 보낸 그 id** 로 등록한다. 여기서 다시 뽑으면 자식 env 의 pane 칸과
        // 갈려, 그 터미널은 자기 훅 로그를 영영 못 읽는다.
        const entry = try self.host_registry.register(runtime_id, params.cols, params.rows);
        errdefer self.host_registry.unregister(runtime_id);
        entry.runtime = @ptrFromInt(handle); // opaque 슬롯에 handle 보관(그 목적: 실 runtime handle). handle>=1이라 non-null.
        try self.screen_changes.putNoClobber(self.allocator, runtime_id, .{});
        errdefer _ = self.screen_changes.remove(runtime_id);
        const sampled_at = std.Io.Clock.awake.now(self.io).nanoseconds;
        try self.installMetadataSampler(
            runtime_id,
            handle,
            if (sampled_at <= 0) 0 else @intCast(@min(sampled_at, std.math.maxInt(u64))),
        );
        self.next_handle += 1;
        return runtime_id;
    }

    /// runtime을 종료한다(§8 `runtime end`). 멱등 — 없는 id/handle 미기록은 무시한다. registry entry의 opaque 슬롯에서
    /// handle을 되읽어 backend 수명을 끝내고(closeAndDetach → remove), registry에서 뗀다.
    fn terminateRuntime(self: *RuntimeManager, runtime_id: u128) void {
        const entry = self.host_registry.get(runtime_id) orelse return; // 없는 id — 멱등 no-op.
        // 그 이름(`runtime_id`)은 다시 쓰이지 않으므로 남기면 아무도 읽지 않는 파일이 쌓인다. GUI 는 이
        // 칸의 소유자가 아니라 정리하지 않는다(docs/agent-hooks.md §4).
        if (self.hook_identity) |identity|
            agent_hook_logs.removeRuntimeLog(identity.log_base, identity.host_id, runtime_id);
        const slot = entry.runtime orelse {
            self.host_registry.unregister(runtime_id); // handle 미기록(비정상) — registry만 정리.
            _ = self.metadata_samplers.remove(runtime_id);
            _ = self.screen_changes.remove(runtime_id);
            _ = self.notification_metadata.remove(runtime_id);
            return;
        };
        const handle: RuntimeHandle = @intFromPtr(slot);
        const be = self.backend_impl.backend();
        if (be.closeAndDetach(handle) == .event_pending)
            @panic("runtime manager teardown reached pending close state"); // PTY/자식/reader 종료 + routing detach(멱등).
        if (be.remove(handle) != .removed)
            @panic("runtime manager teardown lost its runtime"); // reader join → surface/live_pty 번들 deinit → 슬롯 회수.
        _ = self.foreground_cache.remove(handle);
        _ = self.kernel_cwd_cache.remove(handle);
        if (self.observation_caches.fetchRemove(handle)) |kv|
            kv.value.deinit(self.allocator);
        _ = self.bell_counts.remove(handle);
        // 클립보드 텍스트는 최대 160 KiB라 닫힌 runtime마다 남기면 영속 데몬 메모리가 단조 증가한다(버퍼도 해제).
        if (self.clipboards.fetchRemove(handle)) |kv| {
            var state = kv.value;
            state.deinit(self.allocator);
        }
        _ = self.screen_changes.remove(runtime_id);
        _ = self.metadata_samplers.remove(runtime_id);
        self.host_registry.unregister(runtime_id);
        _ = self.notification_metadata.remove(runtime_id);
    }
};

fn coreCommandFromWire(command: core_command_wire.Command) error{InvalidCommand}!core_command.CoreCommand {
    return switch (command) {
        .scroll => |delta| .{ .scroll = std.math.cast(isize, delta) orelse return error.InvalidCommand },
        .scroll_to_bottom => .scroll_to_bottom,
        .scroll_to_abs => |row| .{ .scroll_to_abs = std.math.cast(usize, row) orelse return error.InvalidCommand },
        .scroll_to_offset => |offset| .{ .scroll_to_offset = std.math.cast(usize, offset) orelse return error.InvalidCommand },
        .report_focus => |gained| .{ .report_focus = gained },
        .set_cell_metrics => |metrics| .{ .set_cell_metrics = .{ .width = metrics.width, .height = metrics.height } },
        .set_default_colors => |colors| .{ .set_default_colors = .{
            .foreground = rgbFromWire(colors.foreground),
            .background = rgbFromWire(colors.background),
        } },
        .set_config_palette => |wire_palette| blk: {
            var palette: [16]?terminal.Rgb = .{null} ** 16;
            for (wire_palette, 0..) |maybe_rgb, index| {
                palette[index] = if (maybe_rgb) |rgb| rgbFromWire(rgb) else null;
            }
            break :blk .{ .set_config_palette = palette };
        },
        .set_max_scrollback => |lines| .{ .set_max_scrollback = std.math.cast(usize, lines) orelse return error.InvalidCommand },
        .set_ambiguous_wide => |wide| .{ .set_ambiguous_wide = wide },
        .set_emoji_wide => |wide| .{ .set_emoji_wide = wide },
        .set_default_cursor_shape => |shape| if (shape <= 2)
            .{ .set_default_cursor_shape = @enumFromInt(shape) }
        else
            return error.InvalidCommand,
        .set_runtime_config => |config| .{
            .set_runtime_config = .{
                .max_scrollback = std.math.cast(usize, config.max_scrollback) orelse return error.InvalidCommand,
                .ambiguous_wide = config.ambiguous_wide,
                .emoji_wide = config.emoji_wide,
                .palette = paletteFromWire(config.palette),
                .default_colors = .{
                    .foreground = rgbFromWire(config.default_colors.foreground),
                    .background = rgbFromWire(config.default_colors.background),
                },
                .cell_metrics = if (config.cell_metrics) |metrics| .{
                    .width = metrics.width,
                    .height = metrics.height,
                } else null,
                // wire는 0=block/1=underline/2=bar. decode가 이미 범위를 좁혔지만 여기서도 닫아 둔다 —
                // 다른 wire 소비처(paletteFromWire·cast)와 같은 fail-close 규율.
                .default_cursor_shape = if (config.cursor_shape <= 2)
                    @enumFromInt(config.cursor_shape)
                else
                    return error.InvalidCommand,
            },
        },
        .jump_to_prompt => |direction| .{ .jump_to_prompt = direction },
        .clear_screen => .clear_screen,
        .reset_input_modes => .reset_input_modes,
        .selection_start => |point| .{ .select_start = .{
            .row = point.row,
            .col = point.col,
            .block = point.block,
        } },
        .selection_extend => |point| .{ .select_extend = .{ .row = point.row, .col = point.col } },
        .selection_extend_or_collapse => |point| .{ .select_extend_or_collapse = .{ .row = point.row, .col = point.col } },
        .selection_scroll_and_extend => |step| .{ .scroll_and_extend = .{ .delta = step.delta, .row = step.row, .col = step.col } },
        .selection_clear => .select_clear,
    };
}

fn rgbFromWire(rgb: u32) terminal.Rgb {
    return .{
        .r = @truncate(rgb >> 16),
        .g = @truncate(rgb >> 8),
        .b = @truncate(rgb),
    };
}

test "P4 N2b2 daemon owner tick delivers OS notification through typed adapter without GUI" {
    const Probe = struct {
        calls: usize = 0,
        route: notification_os_delivery.Route = undefined,

        fn submit(context: *anyopaque, request: notification_os_delivery.Request) notification_os_delivery.AdapterResult {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            self.route = request.route;
            return .accepted;
        }
    };
    const allocator = std.testing.allocator;
    const host_id: u128 = 0x11223344556677889900aabbccddeeff;
    var host_registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer host_registry.deinit();
    var manager: RuntimeManager = undefined;
    manager.initWithHostId(allocator, std.testing.io, &host_registry, host_id, null);
    defer manager.deinit();
    var probe: Probe = .{};
    manager.installNotificationOsAdapter(.{ .context = &probe, .submitFn = Probe.submit });
    const key = try manager.notification_journal.admit(0xaa, 7, "title", "body", "workspace");

    _ = manager.drainOwnedEvents();
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(notification_os_delivery.Route{
        .hid = host_id,
        .rid = 0xaa,
        .eid = key.event_id,
    }, probe.route);
    try std.testing.expect(manager.notification_journal.oldestPending(.os) == null);
    try std.testing.expect(manager.notification_journal.peek(key).?.pending_gui);
    try std.testing.expectEqual(@as(u64, 1), manager.notificationOsCounters().accepted);
}

test "U5 budget preview is read-only and includes every non-attempt section" {
    const allocator = std.testing.allocator;
    var host_registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer host_registry.deinit();
    var manager: RuntimeManager = undefined;
    manager.initWithHostId(allocator, std.testing.io, &host_registry, 0xAB, null);
    defer manager.deinit();

    const before_count = host_registry.count();
    const preview = try manager.previewUpgradeHandoff(allocator, 0xAB, 3, 1, 40);
    try std.testing.expectEqual(before_count, host_registry.count());
    try std.testing.expectEqual(@as(usize, 0), preview.runtime_count);
    try std.testing.expect(preview.encoded_bytes_without_attempt > 0);
    try std.testing.expectEqual(
        preview.encoded_bytes_without_attempt + try handoff_codec.encodedAttemptSectionBytes(128),
        try preview.totalBytesWithAttempt(128),
    );
}

test "P4 N2a product owner admits real PTY OSC into stable host journal" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const host_id: u128 = 0x11223344556677889900aabbccddeeff;
    var host_registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer host_registry.deinit();
    var manager: RuntimeManager = undefined;
    manager.initWithHostId(allocator, std.testing.io, &host_registry, host_id, null);
    defer manager.deinit();
    const ops = manager.runtimeOps();
    const runtime_id = try ops.spawn(ops.ctx, .{
        .argv = &.{
            "/bin/sh",
            "-c",
            "printf '\\033]777;notify; Build\\nTitle ;done\\377\\007\\n'; " ++
                "read trigger; printf '\\033]9;legacy body\\007\\n'; sleep 30",
        },
        .cols = 40,
        .rows = 8,
        .initial_notification = .{ .config_generation = 1, .notifications_osc = true, .display_label = "test" },
    });
    defer ops.terminate(ops.ctx, runtime_id);

    // The child emits the hostile OSC bytes itself. Feeding them through a canonical-mode `cat`
    // races terminal echo against the child's second copy and does not define one stable PTY
    // producer transcript under aggregate scheduler pressure.
    // Keep a bounded 10 s product deadline; the 1 ms poll still makes the normal path immediate.
    var attempts: usize = 0;
    while (attempts < 10_000 and manager.oldestNotification(.gui) == null) : (attempts += 1) {
        _ = manager.drainOwnedEvents();
        _ = usleep(1000);
    }
    const row = manager.oldestNotification(.gui) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(host_id, row.key.host_id);
    try std.testing.expectEqual(runtime_id, row.runtime_id);
    try std.testing.expectEqual(@as(u64, 1), row.key.event_id);
    try std.testing.expectEqualStrings("Build Title", row.title);
    try std.testing.expectEqualStrings("done\xef\xbf\xbd", row.body);
    try std.testing.expect(std.unicode.utf8ValidateSlice(row.title));
    try std.testing.expect(std.unicode.utf8ValidateSlice(row.body));
    const stable_snapshot = try ops.notification_peek(ops.ctx, runtime_id, true, allocator);
    defer allocator.free(stable_snapshot.body);
    try std.testing.expectEqual(row.key.event_id, stable_snapshot.generation.?);
    try std.testing.expect(std.mem.indexOf(u8, stable_snapshot.body, "\"hid\":\"11223344556677889900aabbccddeeff\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stable_snapshot.body, "\"rid\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, stable_snapshot.body, "\"eid\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, stable_snapshot.body, "\"display_label\":\"test\"") != null);
    const snapshot = try ops.notification_peek(ops.ctx, runtime_id, false, allocator);
    defer allocator.free(snapshot.body);
    try std.testing.expectEqual(row.key.event_id, snapshot.generation.?);
    try std.testing.expectEqualStrings("{\"title\":\"Build Title\",\"body\":\"done\xef\xbf\xbd\"}", snapshot.body);
    try std.testing.expect(ops.notification_commit(ops.ctx, runtime_id, snapshot.generation));
    try std.testing.expect(manager.oldestNotification(.gui) == null);
    try std.testing.expectEqual(row.key.event_id, manager.oldestNotification(.os).?.key.event_id);

    try ops.write_input(ops.ctx, runtime_id, "next\n");
    attempts = 0;
    while (attempts < 10_000 and manager.notification_journal.oldestPendingForRuntime(.gui, runtime_id) == null) : (attempts += 1) {
        _ = manager.drainOwnedEvents();
        _ = usleep(1000);
    }
    const osc9 = manager.notification_journal.oldestPendingForRuntime(.gui, runtime_id) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Maru", osc9.title);
    try std.testing.expectEqualStrings("legacy body", osc9.body);
}

test "P4 N2a product owner retries allocation failure and consumes permanent rejection" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var host_registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer host_registry.deinit();
    var manager: RuntimeManager = undefined;
    manager.initWithHostId(allocator, std.testing.io, &host_registry, 0x2233, null);
    defer manager.deinit();
    const ops = manager.runtimeOps();
    const retry_runtime = try ops.spawn(ops.ctx, .{ .argv = &.{"/bin/cat"}, .cols = 40, .rows = 8, .initial_notification = .{ .config_generation = 1, .notifications_osc = true, .display_label = "retry" } });
    defer ops.terminate(ops.ctx, retry_runtime);
    const retry_handle = manager.handleFor(retry_runtime) orelse return error.TestUnexpectedResult;
    const retry_slot = manager.backend_impl.terminalForHostLifecycle(retry_handle) orelse return error.TestUnexpectedResult;
    retry_slot.surface.lockCore(manager.io);
    retry_slot.surface.core.write("\x1b]777;notify;retry;body\x07") catch |err| {
        retry_slot.surface.unlockCore(manager.io);
        return err;
    };
    retry_slot.surface.unlockCore(manager.io);

    var reached_success = false;
    for (0..16) |fail_offset| {
        var failing = std.testing.FailingAllocator.init(allocator, .{});
        failing.fail_index = fail_offset;
        manager.allocator = failing.allocator();
        manager.admitPendingNotification(retry_runtime, retry_slot);
        manager.allocator = allocator;
        failing.fail_index = std.math.maxInt(usize);
        if (manager.oldestNotification(.gui) != null) {
            reached_success = true;
            retry_slot.surface.lockCore(manager.io);
            const pending = retry_slot.surface.core.pendingNotification();
            retry_slot.surface.unlockCore(manager.io);
            try std.testing.expect(pending == null);
            break;
        }
        retry_slot.surface.lockCore(manager.io);
        const pending = retry_slot.surface.core.pendingNotification();
        retry_slot.surface.unlockCore(manager.io);
        try std.testing.expect(pending != null);
        try std.testing.expectEqual(@as(u64, 0), manager.notification_permanent_drops);
    }
    try std.testing.expect(reached_success);
    try std.testing.expectEqual(@as(u64, 1), manager.oldestNotification(.gui).?.key.event_id);

    const rejected_runtime = try ops.spawn(ops.ctx, .{ .argv = &.{"/bin/cat"}, .cols = 40, .rows = 8, .initial_notification = .{ .config_generation = 1, .notifications_osc = true, .display_label = "rejected" } });
    defer ops.terminate(ops.ctx, rejected_runtime);
    const rejected_handle = manager.handleFor(rejected_runtime) orelse return error.TestUnexpectedResult;
    const rejected_slot = manager.backend_impl.terminalForHostLifecycle(rejected_handle) orelse return error.TestUnexpectedResult;
    const oversized = try allocator.alloc(u8, notification_limits.max_title_bytes + 1);
    defer allocator.free(oversized);
    @memset(oversized, 'x');
    rejected_slot.surface.lockCore(manager.io);
    rejected_slot.surface.core.write("\x1b]777;notify;") catch |err| {
        rejected_slot.surface.unlockCore(manager.io);
        return err;
    };
    rejected_slot.surface.core.write(oversized) catch |err| {
        rejected_slot.surface.unlockCore(manager.io);
        return err;
    };
    rejected_slot.surface.core.write(";body\x07") catch |err| {
        rejected_slot.surface.unlockCore(manager.io);
        return err;
    };
    rejected_slot.surface.unlockCore(manager.io);

    const fair_runtime = try ops.spawn(ops.ctx, .{ .argv = &.{"/bin/cat"}, .cols = 40, .rows = 8, .initial_notification = .{ .config_generation = 1, .notifications_osc = true, .display_label = "fair" } });
    defer ops.terminate(ops.ctx, fair_runtime);
    const fair_handle = manager.handleFor(fair_runtime) orelse return error.TestUnexpectedResult;
    const fair_slot = manager.backend_impl.terminalForHostLifecycle(fair_handle) orelse return error.TestUnexpectedResult;
    fair_slot.surface.lockCore(manager.io);
    fair_slot.surface.core.write("\x1b]777;notify;fair;admitted\x07") catch |err| {
        fair_slot.surface.unlockCore(manager.io);
        return err;
    };
    fair_slot.surface.unlockCore(manager.io);

    _ = manager.drainOwnedEvents();
    rejected_slot.surface.lockCore(manager.io);
    const rejected_pending = rejected_slot.surface.core.pendingNotification();
    rejected_slot.surface.unlockCore(manager.io);
    try std.testing.expect(rejected_pending == null);
    try std.testing.expectEqual(@as(u64, 1), manager.notification_permanent_drops);
    try std.testing.expect(manager.notification_journal.oldestPendingForRuntime(.gui, rejected_runtime) == null);
    const fair = manager.notification_journal.oldestPendingForRuntime(.gui, fair_runtime) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("fair", fair.title);
    try std.testing.expectEqualStrings("admitted", fair.body);
    try std.testing.expectEqual(@as(u64, 2), fair.key.event_id);
}

test "P4 N2a outer handoff restores journal before successor publication" {
    const allocator = std.testing.allocator;
    const host_id: u128 = 0x1234;
    var source_registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer source_registry.deinit();
    var source: RuntimeManager = undefined;
    source.initWithHostId(allocator, std.testing.io, &source_registry, host_id, null);
    defer source.deinit();
    const first = try source.notification_journal.admit(7, 10, "one", "body", "label");
    _ = try source.notification_journal.admit(8, 11, "two", "body", "label");
    try std.testing.expectEqual(notification_journal.AckResult.acknowledged, source.notification_journal.ack(first, .os));
    source.notification_permanent_drops = 9;

    const resources = try allocator.alloc(RuntimeManager.UpgradeResource, 0);
    const views = try allocator.alloc(handoff_codec.RuntimeView, 0);
    const notification_bytes = try source.notification_journal.encodeHandoff(allocator, source.notification_permanent_drops);
    const notification_metadata_bytes = try source.notification_metadata.encodeHandoff(allocator);
    var capture: RuntimeManager.QuiescedCapture = .{
        .allocator = allocator,
        .host_id = host_id,
        .upgrade_epoch = 2,
        .next_handle = 1,
        .resources = resources,
        .views = views,
        .notification_handoff = notification_bytes,
        .notification_digest = source.notification_journal.logicalDigest(source.notification_permanent_drops),
        .notification_metadata_handoff = notification_metadata_bytes,
        .notification_metadata_digest = source.notification_metadata.logicalDigest(),
    };
    defer capture.deinit();
    const encoded = try capture.encode(null);
    defer allocator.free(encoded);
    _ = try source.notification_journal.admit(10, 13, "late", "mutation", "label");
    try std.testing.expectError(error.UnsafeFrontier, source.revalidateQuiescedCapture(&capture));
    var decoded = try handoff_codec.decodeHost(allocator, encoded);
    defer decoded.deinit();

    var target_registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer target_registry.deinit();
    var target: RuntimeManager = undefined;
    target.initWithHostId(allocator, std.testing.io, &target_registry, host_id, null);
    defer target.deinit();
    var graph = try target.prepareRestoredGraph(&decoded);
    defer graph.discard();
    try std.testing.expectEqual(@as(u64, 9), target.notification_permanent_drops);
    try std.testing.expect(!target.notification_journal.peek(first).?.pending_os);
    try std.testing.expect(target.notification_journal.peek(first).?.pending_gui);
    const next = try target.notification_journal.admit(9, 12, "three", "body", "label");
    try std.testing.expectEqual(@as(u64, 3), next.event_id);
}

fn paletteFromWire(wire_palette: core_command_wire.Command.Palette) [16]?terminal.Rgb {
    var palette: [16]?terminal.Rgb = .{null} ** 16;
    for (wire_palette, 0..) |maybe_rgb, index| {
        palette[index] = if (maybe_rgb) |rgb| rgbFromWire(rgb) else null;
    }
    return palette;
}

test "quiesced capture derives one sorted runtime authority set and rejects divergent outer views" {
    const allocator = std.testing.allocator;
    const resources = try allocator.alloc(RuntimeManager.UpgradeResource, 3);
    @memcpy(resources, &[_]RuntimeManager.UpgradeResource{
        .{ .runtime_id = 9, .source_fd = 30, .inherited_slot = 40 },
        .{ .runtime_id = 2, .source_fd = 31, .inherited_slot = 41 },
        .{ .runtime_id = 5, .source_fd = 32, .inherited_slot = 42 },
    });
    const views = try allocator.alloc(handoff_codec.RuntimeView, 0);
    var capture: RuntimeManager.QuiescedCapture = .{
        .allocator = allocator,
        .host_id = 1,
        .upgrade_epoch = 2,
        .next_handle = 4,
        .resources = resources,
        .views = views,
        .notification_handoff = try allocator.alloc(u8, 0),
        .notification_digest = [_]u8{0} ** 32,
        .notification_metadata_handoff = try allocator.dupe(u8, "metadata"),
        .notification_metadata_digest = [_]u8{0} ** 32,
    };
    defer capture.deinit();
    var ids: [upgrade_limits.max_runtime_count]u128 = undefined;
    try std.testing.expectEqualSlices(u128, &.{ 2, 5, 9 }, capture.sortedRuntimeIds(&ids));
    try std.testing.expectError(error.InvalidValue, capture.encode(null));
}

test "runtime manager maps every bounded wire command without silent variants" {
    var wire_palette: core_command_wire.Command.Palette = .{null} ** 16;
    wire_palette[3] = 0x12_34_56;
    const mapped = try coreCommandFromWire(.{ .set_config_palette = wire_palette });
    try std.testing.expect(mapped == .set_config_palette);
    try std.testing.expectEqual(terminal.Rgb{ .r = 0x12, .g = 0x34, .b = 0x56 }, mapped.set_config_palette[3].?);

    const focus = try coreCommandFromWire(.{ .report_focus = true });
    try std.testing.expect(focus == .report_focus);
    try std.testing.expect(focus.report_focus);

    const defaults = try coreCommandFromWire(.{ .set_default_colors = .{
        .foreground = 0xAA_BB_CC,
        .background = 0x01_02_03,
    } });
    try std.testing.expectEqual(terminal.Rgb{ .r = 0xAA, .g = 0xBB, .b = 0xCC }, defaults.set_default_colors.foreground);
    try std.testing.expectEqual(terminal.Rgb{ .r = 0x01, .g = 0x02, .b = 0x03 }, defaults.set_default_colors.background);
}

/// 128-bit runtime_id를 발급한다(§4 opaque random). macOS `arc4random_buf`는 실패하지 않는 CSPRNG다(daemon.newHostId 대칭).
fn newRuntimeId() u128 {
    var id: u128 = 0;
    while (id == 0) {
        var bytes: [16]u8 = undefined;
        arc4random_buf(&bytes, bytes.len);
        id = std.mem.readInt(u128, &bytes, .big);
    }
    return id;
}

// ─────────────────────────────────────────────────────────────────────────────
// process smoke (실 macOS PTY: RuntimeOps로 실 runtime을 띄우고 내린다)
//
// 이 테스트가 증명하는 것(그리고 터미널에서 왜 중요한가): 영속 host의 핵심은 GUI 밖에서 **실 PTY runtime을 소유**하는
// 것이다. server.zig의 read-only 조회를 넘어, `RuntimeOps.spawn`이 실제 forkpty로 셸을 띄워 host registry에 재접속
// 조회 대상으로 노출하고, `terminate`가 그 PTY/자식/reader를 누수 없이 회수하는지 고정한다. testing.allocator가
// 누수를(reader join 실패·슬롯 미회수) 잡는다. 실 forkpty라 macOS opt-in(non-macOS는 barrel에서 제외돼 test 자체가 없다).
// ─────────────────────────────────────────────────────────────────────────────

test "runtime manager: output wake is nonblocking CLOEXEC and coalesces queue publication" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var host_registry = reg.TerminalRuntimeRegistry.init(std.testing.allocator);
    defer host_registry.deinit();
    var manager: RuntimeManager = undefined;
    manager.init(std.testing.allocator, std.testing.io, &host_registry, null);
    defer manager.deinit();
    try manager.enableOutputWake();

    const wake_fd = manager.outputWakeReadFd().?;
    const wake_write_fd = manager.output_wake.?.write_fd;
    const descriptor_flags = c.fcntl(wake_fd, c.F.GETFD, @as(c_int, 0));
    const status_flags = c.fcntl(wake_fd, c.F.GETFL, @as(c_int, 0));
    const nonblocking: c_int = @bitCast(posix.O{ .NONBLOCK = true });
    try std.testing.expect(descriptor_flags >= 0 and descriptor_flags & c.FD_CLOEXEC != 0);
    try std.testing.expect(status_flags >= 0 and status_flags & nonblocking != 0);
    try std.testing.expectEqual(@as(c_int, 1), c.fcntl(wake_write_fd, c.F.GETNOSIGPIPE, @as(c_int, 0)));

    var queue = try maru.app.PtyEventQueue.init(std.testing.io, std.testing.allocator, 2);
    defer queue.deinit();
    queue.setWakeNotifier(.{
        .ctx = &manager.output_wake.?,
        .notify = OutputWake.notify,
    });
    try queue.tryPush(.{ .output = .{ .pty_id = 1, .bytes = &.{} } });
    try queue.tryPush(.{ .output = .{ .pty_id = 1, .bytes = &.{} } });

    var ready = c.pollfd{ .fd = wake_fd, .events = c.POLL.IN, .revents = 0 };
    try std.testing.expect(c.poll(@ptrCast(&ready), 1, 100) > 0);
    try std.testing.expect(manager.drainOutputWake());
    ready.revents = 0;
    try std.testing.expectEqual(@as(c_int, 0), c.poll(@ptrCast(&ready), 1, 0));
}

test "P4 E3a screen token advances only after owned output drain and committed owner mutation" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var rollover: ScreenChangeRecord = .{
        .token = .{ .incarnation = 7, .revision = std.math.maxInt(u64) },
    };
    try rollover.advance();
    try std.testing.expectEqual(server.ScreenChangeToken{
        .incarnation = 8,
        .revision = 1,
    }, rollover.token);

    var host_registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer host_registry.deinit();
    var manager: RuntimeManager = undefined;
    manager.init(allocator, std.testing.io, &host_registry, null);
    defer manager.deinit();
    try manager.enableOutputWake();
    const ops = manager.runtimeOps();
    const read_token = ops.screen_change_token.?;
    const rid = try ops.spawn(ops.ctx, .{
        .argv = &.{"/bin/cat"},
        .cols = 40,
        .rows = 10,
    });
    defer ops.terminate(ops.ctx, rid);

    const initial = try read_token(ops.ctx, rid);
    try ops.write_input(ops.ctx, rid, "E3A\n");
    var ready = c.pollfd{
        .fd = manager.outputWakeReadFd().?,
        .events = c.POLL.IN,
        .revents = 0,
    };
    try std.testing.expect(c.poll(@ptrCast(&ready), 1, 1000) > 0);
    try std.testing.expect(manager.drainOutputWake());
    var output_events: usize = 0;
    var attempts: usize = 0;
    while (attempts < 100 and output_events == 0) : (attempts += 1) {
        output_events += manager.drainOwnedEvents().output_events;
        if (output_events == 0) _ = usleep(1000);
    }
    try std.testing.expect(output_events != 0);
    var after_output = try read_token(ops.ctx, rid);
    try std.testing.expect(!std.meta.eql(initial, after_output));

    // A PTY can publish terminal echo and child output as two adjacent queue events. Wait for one
    // bounded quiet window before asserting the idle invariant; an immediately repeated drain is
    // a race with the second legitimate publication, not evidence that idle polling advanced.
    var quiet = false;
    for (0..100) |_| {
        ready.revents = 0;
        const poll_result = c.poll(@ptrCast(&ready), 1, 20);
        try std.testing.expect(poll_result >= 0);
        if (poll_result == 0) {
            quiet = true;
            break;
        }
        try std.testing.expect(manager.drainOutputWake());
        const adjacent = manager.drainOwnedEvents();
        if (adjacent.output_events != 0)
            after_output = try read_token(ops.ctx, rid);
    }
    try std.testing.expect(quiet);

    const idle = manager.drainOwnedEvents();
    try std.testing.expectEqual(@as(usize, 0), idle.output_events);
    try std.testing.expectEqual(after_output, try read_token(ops.ctx, rid));

    try ops.resize(ops.ctx, rid, 41, 11);
    const after_resize = try read_token(ops.ctx, rid);
    try std.testing.expect(!std.meta.eql(after_output, after_resize));
    ready.revents = 0;
    try std.testing.expect(c.poll(@ptrCast(&ready), 1, 100) > 0);
    try std.testing.expect(manager.drainOutputWake());
}

test "runtime manager: output wake saturates into nonblocking coalescing and drains reusable" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var wake = try OutputWake.init();
    defer wake.deinit();

    const byte = [_]u8{1};
    var published: usize = 0;
    while (published < 16 * 1024 * 1024) : (published += 1) {
        const written = c.write(wake.write_fd, &byte, byte.len);
        if (written == 1) continue;
        try std.testing.expect(written < 0);
        try std.testing.expectEqual(posix.E.AGAIN, posix.errno(written));
        break;
    } else return error.TestUnexpectedResult;
    try std.testing.expect(published != 0);

    // The production callback must return while the pipe is full: the resident byte already owns
    // the wake obligation. A successful drain then makes the same pipe reusable.
    OutputWake.notify(&wake);
    try std.testing.expect(wake.drain());
    try std.testing.expectEqual(@as(isize, 1), c.write(wake.write_fd, &byte, byte.len));
    try std.testing.expect(wake.drain());
    var idle = c.pollfd{ .fd = wake.read_fd, .events = c.POLL.IN, .revents = 0 };
    try std.testing.expectEqual(@as(c_int, 0), c.poll(@ptrCast(&idle), 1, 50));
}

test "runtime manager: output wake write disposition retries only EINTR" {
    try std.testing.expectEqual(OutputWake.WriteDisposition.published, OutputWake.classifyWriteResult(1, .SUCCESS));
    try std.testing.expectEqual(OutputWake.WriteDisposition.retry, OutputWake.classifyWriteResult(-1, .INTR));
    try std.testing.expectEqual(OutputWake.WriteDisposition.coalesced, OutputWake.classifyWriteResult(-1, .AGAIN));
    try std.testing.expectEqual(OutputWake.WriteDisposition.unavailable, OutputWake.classifyWriteResult(-1, .PIPE));
    try std.testing.expectEqual(OutputWake.WriteDisposition.unavailable, OutputWake.classifyWriteResult(0, .SUCCESS));
}

test "runtime manager: broken output wake read end cannot raise SIGPIPE and deinit closes writer" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var wake = try OutputWake.init();
    const write_fd = wake.write_fd;
    try std.testing.expectEqual(@as(c_int, 0), c.close(wake.read_fd));
    wake.read_fd = -1;

    // Without F_SETNOSIGPIPE this call terminates the entire test process instead of returning.
    OutputWake.notify(&wake);
    try std.testing.expect(c.fcntl(write_fd, c.F.GETFD, @as(c_int, 0)) >= 0);
    wake.deinit();
    try std.testing.expect(c.fcntl(write_fd, c.F.GETFD, @as(c_int, 0)) < 0);
    try std.testing.expectEqual(posix.E.BADF, posix.errno(-1));
}

test "K2 kernel cwd cache owns a checked paired generation and clears atomically" {
    var cache: KernelCwdCache = .{};
    try std.testing.expect(try cache.replace("/repo", "devbox", 100));
    try std.testing.expectEqual(@as(u64, 1), cache.generation);
    try std.testing.expectEqualStrings("/repo", cache.cwdSlice());
    try std.testing.expectEqualStrings("devbox", cache.hostnameSlice());
    try std.testing.expect(!try cache.replace("/repo", "devbox", 200));
    try std.testing.expectEqual(@as(u64, 1), cache.generation);
    try std.testing.expect(try cache.clear(300));
    try std.testing.expectEqual(@as(u64, 2), cache.generation);
    try std.testing.expectEqualStrings("", cache.cwdSlice());
    try std.testing.expectEqualStrings("", cache.hostnameSlice());

    try std.testing.expectError(error.InvalidKernelCwd, cache.replace("relative", "devbox", 350));
    try std.testing.expectError(error.InvalidKernelCwd, cache.replace("/repo", "\xff", 350));

    cache.generation = std.math.maxInt(u64);
    const before = cache;
    try std.testing.expectError(
        error.KernelCwdGenerationExhausted,
        cache.replace("/next", "devbox", 400),
    );
    try std.testing.expectEqualDeep(before, cache);
}

test "K2 runtime manager publishes bounded kernel cwd only for local OSC-empty runtimes" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cwd_buffer: [posix.PATH_MAX]u8 = undefined;
    const expected_cwd_len = try tmp.dir.realPath(std.testing.io, &cwd_buffer);
    const expected_cwd = cwd_buffer[0..expected_cwd_len];

    var host_registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer host_registry.deinit();
    var mgr: RuntimeManager = undefined;
    mgr.init(allocator, std.testing.io, &host_registry, null);
    defer mgr.deinit();
    const ops = mgr.runtimeOps();

    const local_rid = try ops.spawn(ops.ctx, .{
        .argv = &.{"/bin/cat"},
        .cwd = expected_cwd,
        .cols = 40,
        .rows = 10,
    });
    const local_handle = mgr.handleFor(local_rid) orelse return error.TestUnexpectedResult;
    var hostname_buffer: [posix.HOST_NAME_MAX]u8 = undefined;
    const expected_hostname = try posix.gethostname(&hostname_buffer);
    // forkpty returns before the child necessarily completes its chdir. Exercise the product
    // cadence until the kernel reports the requested directory instead of making scheduler order
    // part of K2's contract.
    const cwd_deadline = std.Io.Clock.awake.now(std.testing.io).nanoseconds +
        5 * std.time.ns_per_s;
    while (true) {
        const current = mgr.kernel_cwd_cache.get(local_handle) orelse KernelCwdCache{};
        _ = try mgr.refreshKernelCwdCache(
            local_handle,
            current.refreshed_at_ns + kernel_cwd_refresh_ns,
            false,
        );
        const cached = mgr.kernel_cwd_cache.get(local_handle) orelse
            return error.TestUnexpectedResult;
        if (std.mem.eql(u8, expected_cwd, cached.cwdSlice()) and
            std.mem.eql(u8, expected_hostname, cached.hostnameSlice())) break;
        if (std.Io.Clock.awake.now(std.testing.io).nanoseconds >= cwd_deadline)
            return error.KernelCwdTestDeadlineExceeded;
        try std.Io.sleep(
            std.testing.io,
            std.Io.Duration.fromMilliseconds(10),
            .awake,
        );
    }
    var local = try ops.observation(ops.ctx, local_rid, allocator);
    defer local.deinit(allocator);
    try std.testing.expectEqualStrings(expected_cwd, local.cwd);
    try std.testing.expectEqualStrings(expected_hostname, local.cwd_host);

    const sampled = mgr.kernel_cwd_cache.get(local_handle) orelse return error.TestUnexpectedResult;
    const sampled_at = sampled.refreshed_at_ns;
    const sampled_generation = sampled.generation;
    try std.testing.expect(!try mgr.refreshKernelCwdCache(
        local_handle,
        sampled_at + 100 * std.time.ns_per_ms,
        false,
    ));
    const throttled = mgr.kernel_cwd_cache.get(local_handle) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(sampled_at, throttled.refreshed_at_ns);
    try std.testing.expectEqual(sampled_generation, throttled.generation);

    // Materialization must recheck OSC/SSH eligibility, but an existing eligible cache remains
    // the cadence sampler's responsibility. Otherwise the first output wake after 500ms can block
    // on proc_pidinfo/gethostname and violate the slow-observer latency budget.
    try std.testing.expect(!try mgr.refreshKernelCwdCache(
        local_handle,
        sampled_at + 600 * std.time.ns_per_ms,
        true,
    ));
    const materialized = mgr.kernel_cwd_cache.get(local_handle) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(sampled_at, materialized.refreshed_at_ns);
    try std.testing.expectEqual(sampled_generation, materialized.generation);

    const first_cached = try ops.cached_observation(ops.ctx, local_rid, .fresh);
    const cache_now = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
    const cache = mgr.kernel_cwd_cache.getPtr(local_handle) orelse return error.TestUnexpectedResult;
    try std.testing.expect(try cache.replace("/synthetic-k2-change", expected_hostname, cache_now));
    const changed_cached = try ops.cached_observation(ops.ctx, local_rid, .{ .cadence_epoch = 1 });
    try std.testing.expect(changed_cached.change_token != first_cached.change_token);
    try std.testing.expect(std.mem.indexOf(u8, changed_cached.canonical_json, "/synthetic-k2-change") != null);

    const surface = mgr.backend_impl.surfaceFor(local_handle) orelse return error.TestUnexpectedResult;
    surface.lockCore(std.testing.io);
    surface.core.write("\x1b]7;file://remote.example/remote/repo\x07") catch |err| {
        surface.unlockCore(std.testing.io);
        return err;
    };
    surface.unlockCore(std.testing.io);
    var remote_osc = try ops.observation(ops.ctx, local_rid, allocator);
    defer remote_osc.deinit(allocator);
    try std.testing.expectEqualStrings("/remote/repo", remote_osc.cwd);
    try std.testing.expectEqualStrings("remote.example", remote_osc.cwd_host);
    const hidden = mgr.kernel_cwd_cache.get(local_handle) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 0), hidden.cwd_len);
    try std.testing.expect(hidden.generation > sampled_generation);

    ops.terminate(ops.ctx, local_rid);
    try std.testing.expect(mgr.kernel_cwd_cache.get(local_handle) == null);

    const ssh_rid = try ops.spawn(ops.ctx, .{
        .argv = &.{"/bin/cat"},
        .cwd = expected_cwd,
        .cols = 40,
        .rows = 10,
    });
    defer ops.terminate(ops.ctx, ssh_rid);
    const ssh_handle = mgr.handleFor(ssh_rid) orelse return error.TestUnexpectedResult;
    const ssh_surface = mgr.backend_impl.surfaceFor(ssh_handle) orelse return error.TestUnexpectedResult;
    ssh_surface.lockCore(std.testing.io);
    ssh_surface.core.write("\x1b]5379;ssh;user@remote.example\x07") catch |err| {
        ssh_surface.unlockCore(std.testing.io);
        return err;
    };
    ssh_surface.unlockCore(std.testing.io);
    var ssh = try ops.observation(ops.ctx, ssh_rid, allocator);
    defer ssh.deinit(allocator);
    try std.testing.expectEqualStrings("", ssh.cwd);
    try std.testing.expectEqualStrings("", ssh.cwd_host);
    try std.testing.expectEqualStrings("user@remote.example", ssh.ssh_remote_dest.?);
}

test "runtime manager: spawns a real PTY runtime through RuntimeOps and terminates it" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var host_registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer host_registry.deinit();

    var mgr: RuntimeManager = undefined;
    mgr.init(allocator, std.testing.io, &host_registry, null);
    defer mgr.deinit();

    const ops = mgr.runtimeOps();
    // 짧게 종료하는 controlled command를 RuntimeOps.spawn으로 띄운다(실 forkpty). argv는 transient(스택) — spawn이 복사한다.
    const rid = try ops.spawn(ops.ctx, .{
        .argv = &.{ "/bin/sh", "-c", "exit 0" },
        .cwd = null,
        .cols = 40,
        .rows = 10,
    });

    // host registry가 이 runtime을 재접속 조회 대상으로 노출한다(runtime.list/get이 이걸 읽는다).
    try std.testing.expectEqual(@as(usize, 1), host_registry.count());
    const entry = host_registry.get(rid) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 40), entry.cols);
    try std.testing.expect(entry.runtime != null); // opaque 슬롯에 handle이 실려 있다.

    // terminate: PTY/자식/reader를 정리하고 registry에서 제거한다.
    ops.terminate(ops.ctx, rid);
    try std.testing.expectEqual(@as(usize, 0), host_registry.count());
    try std.testing.expectEqual(@as(usize, 0), host_registry.liveGridCells());
    // 두 번째 terminate는 no-op(없는 id 무시) — 멱등.
    ops.terminate(ops.ctx, rid);
}

test "runtime manager: host 가 자식에게 심는 훅 신원이 GUI 가 읽을 이름과 정확히 같다" {
    // 이 테스트가 AH7 의 매듭이다(docs/agent-hooks.md §4). host 가 띄운 자식의 env 에 실제로 들어간 값을
    // **자식이 스스로 적게** 해서 읽고, 계약 모듈이 만드는 이름과 대조한다. 두 이름이 갈리면 그 터미널은
    // 훅 파일을 «만들되» GUI 가 못 찾는 자리에 만든다 — 훅은 도는데 이벤트가 0 인 최악의 상태다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cwd_buf: [4096]u8 = undefined;
    _ = std.c.getcwd(&cwd_buf, cwd_buf.len);
    const proc_cwd = std.mem.sliceTo(&cwd_buf, 0);
    const result_path = try std.fs.path.join(allocator, &.{ proc_cwd, ".zig-cache/tmp", &tmp.sub_path, "hook_env" });
    defer allocator.free(result_path);
    // 자식이 자기 env 를 그대로 적는다. maru 코드를 한 줄도 안 지나므로 «주입됐다» 의 증거가 된다.
    const script = try std.fmt.allocPrint(
        allocator,
        "printf '%s|%s' \"$MARU_HOOK_INSTANCE\" \"$MARU_HOOK_PANE\" > '{s}'; exit 0",
        .{result_path},
    );
    defer allocator.free(script);

    var host_registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer host_registry.deinit();
    var mgr: RuntimeManager = undefined;
    const host_id: u128 = 0xa11ce_0000_0000_0000_0000_0000_0000_0f;
    // 로그 base 는 이 테스트의 tmp 다 — 여기서 보려는 것은 **자식 env 에 실린 이름**이지 파일이 아니지만,
    // 신원은 «id + base» 가 함께여야 성립한다(그 묶음이 반쪽 상태를 타입에서 없앤다).
    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(std.testing.io, &base_buf);
    mgr.init(allocator, std.testing.io, &host_registry, .{
        .host_id = host_id,
        .log_base = base_buf[0..base_len],
    });
    defer mgr.deinit();

    const ops = mgr.runtimeOps();
    const rid = try ops.spawn(ops.ctx, .{ .argv = &.{ "/bin/sh", "-c", script }, .cwd = null, .cols = 40, .rows = 10 });
    defer ops.terminate(ops.ctx, rid);

    const hook_command = maru.session.agent_hook_command;
    var instance_buf: [hook_command.instance_token_max]u8 = undefined;
    var pane_buf: [hook_command.pane_token_max]u8 = undefined;
    const expected = try std.fmt.allocPrint(allocator, "{s}|{s}", .{
        hook_command.formatHostInstance(&instance_buf, host_id),
        hook_command.formatRuntimePane(&pane_buf, rid),
    });
    defer allocator.free(expected);

    var observed: ?[]u8 = null;
    defer if (observed) |bytes| allocator.free(bytes);
    var attempts: usize = 0;
    while (attempts < 200) : (attempts += 1) {
        if (tmp.dir.readFileAlloc(std.testing.io, "hook_env", allocator, .limited(4096)) catch null) |bytes| {
            if (bytes.len > 0) {
                observed = bytes;
                break;
            }
            allocator.free(bytes);
        }
        _ = usleep(10 * 1000);
    }
    try std.testing.expectEqualStrings(expected, observed orelse return error.TestUnexpectedResult);

    // **pane 칸은 등록된 runtime_id 와 같은 값이어야 한다.** spawn 전에 뽑아 자식에게 실은 뒤 등록에서
    // 다시 뽑으면 여기서 갈린다(그 회귀가 이 슬라이스의 유일한 위험이다).
    try std.testing.expect(host_registry.get(rid) != null);
    var pane_check: [hook_command.pane_token_max]u8 = undefined;
    const pane_token = hook_command.formatRuntimePane(&pane_check, rid);
    try std.testing.expect(std.mem.endsWith(u8, observed.?, pane_token));
    // 그리고 그 이름은 커맨드의 가드를 통과해야 한다 — 통과 못하면 훅이 조용히 나간다.
    try std.testing.expect(hook_command.pane_token_class.accepts(pane_token));
    try std.testing.expect(hook_command.instance_token_class.accepts(
        hook_command.formatHostInstance(&instance_buf, host_id),
    ));
}

test "runtime manager: 훅 로그 칸을 만들고, runtime 이 끝나면 그 파일을 거둔다" {
    // 훅은 **디렉터리를 만들지 않는다**(계약 §4.1). 그래서 이 칸이 없으면 host-backed 자식의 훅은 매번
    // 조용히 나가고 파일도 안 남긴다 — 즉 이 칸의 존재가 곧 «그 pane 의 훅 on/off» 다. 그리고 그 이름은
    // `runtime_id` 라 다시 쓰이지 않으므로, 종료 때 거두지 않으면 아무도 읽지 않는 파일이 쌓인다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(std.testing.io, &base_buf);
    const cache_base = base_buf[0..base_len];

    var host_registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer host_registry.deinit();
    var mgr: RuntimeManager = undefined;
    const host_id: u128 = 0xfeed_0000_0000_0000_0000_0000_0000_01;
    mgr.init(allocator, std.testing.io, &host_registry, .{ .host_id = host_id, .log_base = cache_base });
    defer mgr.deinit();

    // ① init 이 칸을 만든다 — **살아 있는 동안 계속** 있어야 한다(시작 직후 지워 버리는 회귀를 잡는다).
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const inst_dir = try agent_hook_logs.instanceDirPathIn(&dir_buf, cache_base, host_id);
    var st: posix.Stat = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.fstatat(posix.AT.FDCWD, inst_dir.ptr, &st, posix.AT.SYMLINK_NOFOLLOW));
    try std.testing.expect(posix.S.ISDIR(st.mode));
    // payload 에는 소스와 셸 명령 원문이 실린다(계약 §7) — 칸이 넓으면 이름만으로도 무엇이 도는지 샌다.
    try std.testing.expectEqual(@as(u32, 0o700), st.mode & 0o777);

    const ops = mgr.runtimeOps();
    const rid = try ops.spawn(ops.ctx, .{ .argv = &.{ "/bin/sh", "-c", "exit 0" }, .cwd = null, .cols = 40, .rows = 10 });

    // ② 훅이 적을 자리에 파일을 놓는다(훅 대신 우리가 놓는다 — 여기서 보려는 것은 **수명**이다).
    var log_buf: [std.fs.max_path_bytes]u8 = undefined;
    const log_path = try agent_hook_logs.runtimeLogPathIn(&log_buf, cache_base, host_id, rid);
    {
        const fd = c.open(log_path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c.mode_t, 0o600));
        try std.testing.expect(fd >= 0);
        _ = c.close(fd);
    }
    try std.testing.expectEqual(@as(c_int, 0), c.fstatat(posix.AT.FDCWD, log_path.ptr, &st, posix.AT.SYMLINK_NOFOLLOW));

    // ③ terminate 가 그 파일을 거둔다. 칸 자체는 남는다 — 다른 runtime 이 아직 쓴다.
    ops.terminate(ops.ctx, rid);
    try std.testing.expect(c.fstatat(posix.AT.FDCWD, log_path.ptr, &st, posix.AT.SYMLINK_NOFOLLOW) != 0);
    try std.testing.expectEqual(@as(c_int, 0), c.fstatat(posix.AT.FDCWD, inst_dir.ptr, &st, posix.AT.SYMLINK_NOFOLLOW));
}

test "runtime manager: 훅 신원이 없으면 칸도 안 만든다 — fail-closed" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(std.testing.io, &base_buf);
    const cache_base = base_buf[0..base_len];

    var host_registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer host_registry.deinit();
    var mgr: RuntimeManager = undefined;
    mgr.init(allocator, std.testing.io, &host_registry, null);
    defer mgr.deinit();

    // 로그 디렉터리 자체가 없어야 한다 — 신원이 없으면 그 자식의 훅은 어차피 아무것도 못 쓴다.
    var log_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const log_dir = try std.fmt.bufPrintZ(&log_dir_buf, "{s}/{s}", .{
        cache_base,
        maru.session.agent_hook_command.log_dir_rel,
    });
    var st: posix.Stat = undefined;
    try std.testing.expect(c.fstatat(posix.AT.FDCWD, log_dir.ptr, &st, posix.AT.SYMLINK_NOFOLLOW) != 0);
}

test "runtime manager: 실 자식이 **진짜 훅 커맨드**를 돌리면 우리 칸에 이벤트가 남는다" {
    // **이것이 host 쪽 사슬의 끝이다.** 자식 env(AH7-2) → 칸 생성(AH7-3a) → 이름 규칙(AH7-3b) 은 각각
    // 봤지만, 그 셋이 이어져 «훅이 실제로 파일을 남기는가» 는 아무도 안 봤다. 여기서는 maru 가 provider
    // 설정에 심는 **바로 그 커맨드 문자열**을 자식이 실행한다 — 우리가 흉내 낸 스크립트가 아니다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const hook_command = maru.session.agent_hook_command;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(std.testing.io, &base_buf);
    const cache_base = base_buf[0..base_len];

    // 훅이 쓸 로그 디렉터리(계약 §4.1 — 훅은 mkdir 을 안 한다). 커맨드에는 **절대 경로**가 박힌다.
    const log_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cache_base, hook_command.log_dir_rel });
    defer allocator.free(log_dir);
    var cmd: std.ArrayListUnmanaged(u8) = .empty;
    defer cmd.deinit(allocator);
    try hook_command.build(&cmd, allocator, "claude", log_dir, .local);

    // 자식은 payload 를 stdin 으로 흘려 그 커맨드를 돌린다(provider 가 하는 그대로 — 계약 §4.1).
    //
    // ⚠️ **커맨드를 한 줄 안에 감싸면 안 된다.** 끝이 표식 주석(`# MARU_HOOK_V3 …`)이라 `{ … ; }` 로 싸면
    // **닫는 괄호가 주석에 먹혀** 셸이 syntax error 로 죽는다(실측: `unexpected end of file`). 실제 provider
    // 는 이 문자열을 설정의 한 항목으로 그대로 실행하므로 그 함정이 없다 — 그러니 테스트도 파일에 그대로
    // 두고 실행해 **제품과 같은 모양**으로 돌린다.
    const hook_script_path = try std.fmt.allocPrint(allocator, "{s}/hook.sh", .{cache_base});
    defer allocator.free(hook_script_path);
    {
        const zpath = try allocator.dupeZ(u8, hook_script_path);
        defer allocator.free(zpath);
        const fd = c.open(zpath.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c.mode_t, 0o700));
        try std.testing.expect(fd >= 0);
        _ = c.write(fd, cmd.items.ptr, cmd.items.len);
        _ = c.write(fd, "\n", 1);
        _ = c.close(fd);
    }
    const payload = "{\"hook_event_name\":\"Stop\",\"last_assistant_message\":\"끝났다\"}";
    const script = try std.fmt.allocPrint(
        allocator,
        "printf '%s\\n' '{s}' | /bin/sh '{s}'; exit 0",
        .{ payload, hook_script_path },
    );
    defer allocator.free(script);

    var host_registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer host_registry.deinit();
    var mgr: RuntimeManager = undefined;
    const host_id: u128 = 0xf00d_0000_0000_0000_0000_0000_0000_09;
    mgr.init(allocator, std.testing.io, &host_registry, .{ .host_id = host_id, .log_base = cache_base });
    defer mgr.deinit();

    // **사용자가 캐시를 비운 상태를 만든다.** `init` 이 만든 칸을 지우고 spawn 한다 — spawn 마다 칸을
    // 확인하지 않으면 그 자식의 훅은 조용히 나가고 파일이 안 생긴다(훅은 mkdir 을 안 한다). 이 한 줄이
    // 없으면 「init 이 이미 만들었으니 됐다」로 보여 그 호출이 시험되지 않는다(뮤테이션이 그것을 잡았다).
    {
        var seg_buf: [std.fs.max_path_bytes]u8 = undefined;
        const seg = try agent_hook_logs.instanceDirPathIn(&seg_buf, cache_base, host_id);
        var marker_buf: [std.fs.max_path_bytes]u8 = undefined;
        const marker = try std.fmt.bufPrintZ(&marker_buf, "{s}/owner.pid", .{seg});
        _ = c.unlink(marker.ptr);
        try std.testing.expectEqual(@as(c_int, 0), c.rmdir(seg.ptr));
    }

    const ops = mgr.runtimeOps();
    const rid = try ops.spawn(ops.ctx, .{ .argv = &.{ "/bin/sh", "-c", script }, .cwd = null, .cols = 40, .rows = 10 });
    defer ops.terminate(ops.ctx, rid);

    // 그 자식이 남긴 파일은 **GUI 가 읽을 바로 그 이름**이어야 한다.
    var log_buf: [std.fs.max_path_bytes]u8 = undefined;
    const log_path = try agent_hook_logs.runtimeLogPathIn(&log_buf, cache_base, host_id, rid);

    var body: ?[]u8 = null;
    defer if (body) |bytes| allocator.free(bytes);
    // CI 러너는 이 왕복(실 host + forkpty + 셸 + 훅)이 느리다. 상한을 넉넉히 둔다 — 이 테스트가 간헐로
    // 빨개지면 그것이 곧 게이트 신뢰를 깎는다.
    var attempts: usize = 0;
    while (attempts < 1000) : (attempts += 1) {
        if (std.Io.Dir.cwd().readFileAlloc(std.testing.io, log_path, allocator, .limited(64 * 1024)) catch null) |bytes| {
            if (std.mem.indexOfScalar(u8, bytes, '\n') != null) {
                body = bytes;
                break;
            }
            allocator.free(bytes);
        }
        _ = usleep(10 * 1000);
    }
    const line = body orelse return error.TestUnexpectedResult;

    // 파서가 그 줄을 **턴 끝**으로 읽어야 한다 — 파일만 생기고 파싱이 안 되면 배지는 그대로 멈춘다.
    const event = maru.session.agent_hook_event;
    const parsed = event.parseLine(std.mem.trimEnd(u8, line, "\n")) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(event.Kind.stop, parsed.kind);
    try std.testing.expectEqualStrings("claude", parsed.provider);

    // 그리고 그 파일 권한은 0600 이어야 한다(계약 §7 — payload 에 소스와 명령 원문이 실린다).
    var st: posix.Stat = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.fstatat(posix.AT.FDCWD, log_path.ptr, &st, posix.AT.SYMLINK_NOFOLLOW));
    try std.testing.expectEqual(@as(u32, 0o600), st.mode & 0o777);
}

test "runtime manager: host_id 를 모르면 훅 신원을 싣지 않는다 — fail-closed" {
    // 인스턴스 칸이 없으면 훅은 경로를 만들 수 없다. 그때 pane 칸만 실으면 «반쪽 신원» 이 남아, 나중에
    // 인스턴스 칸이 생겼을 때 어느 자리에 쓰였는지 알 수 없다. 그래서 둘을 함께 다룬다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cwd_buf: [4096]u8 = undefined;
    _ = std.c.getcwd(&cwd_buf, cwd_buf.len);
    const proc_cwd = std.mem.sliceTo(&cwd_buf, 0);
    const result_path = try std.fs.path.join(allocator, &.{ proc_cwd, ".zig-cache/tmp", &tmp.sub_path, "hook_env" });
    defer allocator.free(result_path);
    const script = try std.fmt.allocPrint(
        allocator,
        "printf 'i=[%s] p=[%s] done' \"$MARU_HOOK_INSTANCE\" \"$MARU_HOOK_PANE\" > '{s}'; exit 0",
        .{result_path},
    );
    defer allocator.free(script);

    var host_registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer host_registry.deinit();
    var mgr: RuntimeManager = undefined;
    mgr.init(allocator, std.testing.io, &host_registry, null); // host 신원 없음 — 훅을 못 싣는 상태
    defer mgr.deinit();

    const ops = mgr.runtimeOps();
    const rid = try ops.spawn(ops.ctx, .{ .argv = &.{ "/bin/sh", "-c", script }, .cwd = null, .cols = 40, .rows = 10 });
    defer ops.terminate(ops.ctx, rid);

    var observed: ?[]u8 = null;
    defer if (observed) |bytes| allocator.free(bytes);
    var attempts: usize = 0;
    while (attempts < 200) : (attempts += 1) {
        if (tmp.dir.readFileAlloc(std.testing.io, "hook_env", allocator, .limited(4096)) catch null) |bytes| {
            if (std.mem.endsWith(u8, bytes, "done")) {
                observed = bytes;
                break;
            }
            allocator.free(bytes);
        }
        _ = usleep(10 * 1000);
    }
    try std.testing.expectEqualStrings("i=[] p=[] done", observed orelse return error.TestUnexpectedResult);
}

test "runtime manager: daemon budget rejection happens before backend allocation" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var count_registry = reg.TerminalRuntimeRegistry.initWithLimits(allocator, .{
        .max_live_runtimes = 1,
        .max_aggregate_grid_cells = reg.max_aggregate_grid_cells,
    });
    defer count_registry.deinit();
    _ = try count_registry.register(1, 80, 24);
    var count_manager: RuntimeManager = undefined;
    count_manager.init(allocator, std.testing.io, &count_registry, null);
    defer count_manager.deinit();
    const count_ops = count_manager.runtimeOps();
    try std.testing.expectError(
        error.RuntimeLimitReached,
        count_ops.spawn(count_ops.ctx, .{ .argv = &.{"/bin/cat"}, .cwd = null, .cols = 2, .rows = 1 }),
    );
    try std.testing.expectEqual(@as(usize, 0), count_manager.live_registry.count());
    try std.testing.expectEqual(@as(RuntimeHandle, 1), count_manager.next_handle);
    try std.testing.expectEqual(@as(usize, 80 * 24), count_registry.liveGridCells());

    var grid_registry = reg.TerminalRuntimeRegistry.initWithLimits(allocator, .{
        .max_live_runtimes = 2,
        .max_aggregate_grid_cells = 80 * 24,
    });
    defer grid_registry.deinit();
    _ = try grid_registry.register(1, 80, 24);
    var grid_manager: RuntimeManager = undefined;
    grid_manager.init(allocator, std.testing.io, &grid_registry, null);
    defer grid_manager.deinit();
    const grid_ops = grid_manager.runtimeOps();
    try std.testing.expectError(
        error.AggregateGridLimitReached,
        grid_ops.spawn(grid_ops.ctx, .{ .argv = &.{"/bin/cat"}, .cwd = null, .cols = 2, .rows = 1 }),
    );
    try std.testing.expectEqual(@as(usize, 0), grid_manager.live_registry.count());
    try std.testing.expectEqual(@as(RuntimeHandle, 1), grid_manager.next_handle);
    try std.testing.expectEqual(@as(usize, 80 * 24), grid_registry.liveGridCells());
}

test "runtime manager: owner drain reaps an exited runtime with zero GUI attachments exactly once" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var host_registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer host_registry.deinit();
    var mgr: RuntimeManager = undefined;
    mgr.init(allocator, std.testing.io, &host_registry, null);
    defer mgr.deinit();

    const ops = mgr.runtimeOps();
    _ = try ops.spawn(ops.ctx, .{ .argv = &.{ "/bin/sh", "-c", "exit 7" }, .cwd = null, .cols = 20, .rows = 4 });
    var total_exited: usize = 0;
    var attempts: usize = 0;
    while (attempts < 300 and host_registry.count() != 0) : (attempts += 1) {
        const drained = mgr.drainOwnedEvents();
        total_exited += drained.exited;
        if (host_registry.count() != 0) _ = usleep(10 * 1000);
    }
    try std.testing.expectEqual(@as(usize, 0), host_registry.count());
    try std.testing.expectEqual(@as(usize, 0), host_registry.liveGridCells());
    try std.testing.expectEqual(@as(usize, 1), total_exited);
    const after = mgr.drainOwnedEvents();
    try std.testing.expectEqual(@as(usize, 0), after.exited);
}

test "runtime manager: U2 quiesce encodes and resumes the same live PTY without attachments" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var host_registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer host_registry.deinit();
    var mgr: RuntimeManager = undefined;
    mgr.init(allocator, std.testing.io, &host_registry, null);
    defer mgr.deinit();

    const ops = mgr.runtimeOps();
    const rid = try ops.spawn(ops.ctx, .{ .argv = &.{"/bin/cat"}, .cwd = null, .cols = 24, .rows = 6 });
    defer ops.terminate(ops.ctx, rid);
    const handle = mgr.handleFor(rid) orelse return error.TestUnexpectedResult;
    const terminal_slot = mgr.backend_impl.terminalForHostLifecycle(handle) orelse return error.TestUnexpectedResult;
    const child_before = terminal_slot.live_pty.session.childPid();
    const fd_before = terminal_slot.live_pty.session.inheritedMasterFd() orelse return error.TestUnexpectedResult;

    try ops.write_input(ops.ctx, rid, "before\n");
    try std.testing.expectEqual(@as(usize, 1), try mgr.requestUpgradeQuiesce());
    var attempts: usize = 0;
    while (attempts < 500 and !mgr.upgradeQuiesceReached()) : (attempts += 1) _ = usleep(1000);
    try std.testing.expect(mgr.upgradeQuiesceReached());
    try mgr.joinAndValidateUpgradeQuiesce();

    const encoded = try mgr.encodeQuiescedHost(allocator, 0xCAFE, 3, 40);
    defer allocator.free(encoded);
    var decoded = try handoff_codec.decodeHost(allocator, encoded);
    defer decoded.deinit();
    try std.testing.expectEqual(try host_registry.membershipGeneration(), decoded.membership_generation);

    try mgr.resumeUpgradeQuiesce();
    try std.testing.expectEqual(child_before, terminal_slot.live_pty.session.childPid());
    try std.testing.expectEqual(fd_before, terminal_slot.live_pty.session.inheritedMasterFd().?);
    try ops.write_input(ops.ctx, rid, "after\n");
}

test "runtime manager: restored graph discard preserves inherited PTY and original child" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var source_registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer source_registry.deinit();
    var source: RuntimeManager = undefined;
    source.init(allocator, std.testing.io, &source_registry, null);
    defer source.deinit();
    const source_ops = source.runtimeOps();
    const runtime_id = try source_ops.spawn(source_ops.ctx, .{
        .argv = &.{"/bin/cat"},
        .cwd = null,
        .cols = 24,
        .rows = 6,
    });
    defer source_ops.terminate(source_ops.ctx, runtime_id);
    const source_handle = source.handleFor(runtime_id) orelse return error.TestUnexpectedResult;
    const source_terminal = source.backend_impl.terminalForHostLifecycle(source_handle) orelse
        return error.TestUnexpectedResult;
    const child_pid = source_terminal.live_pty.session.childPid();

    try std.testing.expectEqual(@as(usize, 1), try source.requestUpgradeQuiesce());
    var attempts: usize = 0;
    while (attempts < 1000 and !source.upgradeQuiesceReached()) : (attempts += 1)
        _ = usleep(1000);
    try std.testing.expect(source.upgradeQuiesceReached());
    try source.joinAndValidateUpgradeQuiesce();

    const exec_fd_set = @import("exec_fd_set.zig");
    var first_slot: std.c.fd_t = 40;
    while (first_slot < 1000 and exec_fd_set.isOpen(first_slot)) : (first_slot += 1) {}
    if (first_slot >= 1000) return error.SkipZigTest;
    var capture = try source.prepareQuiescedCapture(
        allocator,
        0xCAFE,
        3,
        1,
        @intCast(first_slot),
    );
    defer capture.deinit();
    var inherited: exec_fd_set.PreparedSlots = .{};
    defer inherited.rollback();
    try inherited.prepare(capture.resources[0].source_fd, first_slot);
    const encoded = try capture.encode(null);
    defer allocator.free(encoded);
    var decoded = try handoff_codec.decodeHost(allocator, encoded);
    defer decoded.deinit();

    var target_registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer target_registry.deinit();
    var target: RuntimeManager = undefined;
    target.init(allocator, std.testing.io, &target_registry, null);
    defer target.deinit();
    try target.enableOutputWake();
    var graph = try target.prepareRestoredGraph(&decoded);
    var graph_active = true;
    defer if (graph_active) graph.discard();
    attempts = 0;
    while (attempts < 1000 and !graph.allReadersPrepared()) : (attempts += 1)
        _ = usleep(1000);
    try std.testing.expect(graph.allReadersPrepared());
    var restored_cells: usize = 0;
    for (decoded.runtimes) |runtime|
        restored_cells += @as(usize, runtime.cols) * @as(usize, runtime.rows);
    try std.testing.expectEqual(restored_cells, target_registry.liveGridCells());
    const restored_entry = target_registry.get(runtime_id) orelse
        return error.TestUnexpectedResult;
    restored_entry.cols += 1;
    try std.testing.expectError(error.RestoreGraphChanged, graph.revalidateAll());
    restored_entry.cols -= 1;
    _ = try graph.revalidateAll();
    try std.testing.expectEqual(@as(usize, 1), target_registry.count());
    try std.testing.expectEqual(@as(usize, 1), target.live_registry.count());

    // Restore must bind the target process's fresh self-pipe before any reader can be released.
    // Publishing through that reconstructed queue proves the notifier does not retain old-image
    // pointer/fd authority and that the new poll owner will observe the first restored event.
    const target_handle = target.handleFor(runtime_id) orelse return error.TestUnexpectedResult;
    const target_terminal = target.backend_impl.terminalForHostLifecycle(target_handle) orelse
        return error.TestUnexpectedResult;
    try target_terminal.live_pty.eventQueue().tryPush(.{
        .output = .{ .pty_id = target_handle, .bytes = &.{} },
    });
    var restored_wake = c.pollfd{
        .fd = target.outputWakeReadFd().?,
        .events = c.POLL.IN,
        .revents = 0,
    };
    try std.testing.expect(c.poll(@ptrCast(&restored_wake), 1, 100) > 0);
    try std.testing.expect(target.drainOutputWake());
    var restored_event = target_terminal.live_pty.eventQueue().tryPop().?;
    restored_event.deinit(allocator);

    graph.discard();
    graph_active = false;
    try std.testing.expectEqual(@as(usize, 0), target_registry.count());
    try std.testing.expectEqual(@as(usize, 0), target_registry.liveGridCells());
    try std.testing.expectEqual(@as(usize, 0), target.live_registry.count());
    try std.testing.expect(exec_fd_set.isOpen(first_slot));
    try std.testing.expectEqual(child_pid, source_terminal.live_pty.session.childPid());
    try std.testing.expect(!(try source_terminal.live_pty.session.childExitedWithoutReap()));

    try source.resumeUpgradeQuiesce();
    try source_ops.write_input(source_ops.ctx, runtime_id, "still-owned-by-source\n");
}

test "runtime manager: second restored runtime failure rolls back the entire non-owning graph" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var source_registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer source_registry.deinit();
    var source: RuntimeManager = undefined;
    source.init(allocator, std.testing.io, &source_registry, null);
    defer source.deinit();
    const source_ops = source.runtimeOps();
    var runtime_ids: [2]u128 = undefined;
    var child_pids: [2]std.c.pid_t = undefined;
    for (&runtime_ids, 0..) |*runtime_id, index| {
        runtime_id.* = try source_ops.spawn(source_ops.ctx, .{
            .argv = &.{"/bin/cat"},
            .cwd = null,
            .cols = @intCast(30 + index),
            .rows = 8,
        });
        const handle = source.handleFor(runtime_id.*) orelse return error.TestUnexpectedResult;
        const terminal_slot = source.backend_impl.terminalForHostLifecycle(handle) orelse
            return error.TestUnexpectedResult;
        child_pids[index] = terminal_slot.live_pty.session.childPid();
    }
    defer for (runtime_ids) |runtime_id| source_ops.terminate(source_ops.ctx, runtime_id);

    try std.testing.expectEqual(@as(usize, 2), try source.requestUpgradeQuiesce());
    var attempts: usize = 0;
    while (attempts < 1000 and !source.upgradeQuiesceReached()) : (attempts += 1)
        _ = usleep(1000);
    try std.testing.expect(source.upgradeQuiesceReached());
    try source.joinAndValidateUpgradeQuiesce();

    const exec_fd_set = @import("exec_fd_set.zig");
    var first_slot: std.c.fd_t = 40;
    while (first_slot < 999 and
        (exec_fd_set.isOpen(first_slot) or exec_fd_set.isOpen(first_slot + 1))) : (first_slot += 1)
    {}
    if (first_slot >= 999) return error.SkipZigTest;
    var capture = try source.prepareQuiescedCapture(
        allocator,
        0xCAFE,
        3,
        1,
        @intCast(first_slot),
    );
    defer capture.deinit();
    var inherited: exec_fd_set.PreparedSlots = .{};
    defer inherited.rollback();
    for (capture.resources) |resource|
        try inherited.prepare(resource.source_fd, resource.inherited_slot);
    const encoded = try capture.encode(null);
    defer allocator.free(encoded);
    var decoded = try handoff_codec.decodeHost(allocator, encoded);
    defer decoded.deinit();
    try std.testing.expectEqual(@as(usize, 2), decoded.runtimes.len);

    // Codec가 거부하는 wire corruption이 아니라 target graph 조립 중 두 번째
    // registry publish 실패를 주입한다. 첫 runtime과 두 번째 reader까지 모두
    // 준비된 뒤에도 전체 cleanup이 child/fd ownership을 건드리지 않아야 한다.
    decoded.runtimes[1].runtime_id = decoded.runtimes[0].runtime_id;

    var target_registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer target_registry.deinit();
    var target: RuntimeManager = undefined;
    target.init(allocator, std.testing.io, &target_registry, null);
    defer target.deinit();
    try std.testing.expectError(error.DuplicateRuntime, target.prepareRestoredGraph(&decoded));
    try std.testing.expectEqual(@as(usize, 0), target_registry.count());
    try std.testing.expectEqual(@as(usize, 0), target_registry.liveGridCells());
    try std.testing.expectEqual(@as(usize, 0), target.live_registry.count());
    try std.testing.expectEqual(@as(usize, 0), target.surface_runtime.links.items.len);
    try std.testing.expectEqual(@as(RuntimeHandle, 1), target.next_handle);
    for (capture.resources, 0..) |resource, index| {
        try std.testing.expect(exec_fd_set.isOpen(resource.inherited_slot));
        const handle = source.handleFor(runtime_ids[index]) orelse return error.TestUnexpectedResult;
        const terminal_slot = source.backend_impl.terminalForHostLifecycle(handle) orelse
            return error.TestUnexpectedResult;
        try std.testing.expectEqual(child_pids[index], terminal_slot.live_pty.session.childPid());
        try std.testing.expect(!(try terminal_slot.live_pty.session.childExitedWithoutReap()));
    }

    try source.resumeUpgradeQuiesce();
    for (runtime_ids) |runtime_id|
        try source_ops.write_input(source_ops.ctx, runtime_id, "still-source-owned\n");
}

test "runtime manager: empty restored graph commits and releases without fallible work" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var host_registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer host_registry.deinit();
    var manager: RuntimeManager = undefined;
    manager.init(allocator, std.testing.io, &host_registry, null);
    defer manager.deinit();
    var host: handoff_codec.HostState = .{
        .allocator = allocator,
        .host_id = 0xAA,
        .upgrade_epoch = 4,
        .next_handle = 9,
        .runtimes = try allocator.alloc(handoff_codec.RuntimeState, 0),
        .attempt_record = null,
    };
    defer host.deinit();

    var graph = try manager.prepareRestoredGraph(&host);
    try std.testing.expect(graph.allReadersPrepared());
    var validated = try graph.revalidateAll();
    var committed = validated.commitOwnership();
    committed.releaseReaders();
    try std.testing.expectEqual(@as(u64, 9), manager.next_handle);
    try std.testing.expect(graph.phase == .readers_released);
}

test "runtime manager: resize backend failure fail-stops runtime and releases daemon ledger" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var host_registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer host_registry.deinit();
    var manager: RuntimeManager = undefined;
    manager.init(allocator, std.testing.io, &host_registry, null);
    defer manager.deinit();
    const ops = manager.runtimeOps();
    const runtime_id = try ops.spawn(ops.ctx, .{
        .argv = &.{"/bin/cat"},
        .cwd = null,
        .cols = 80,
        .rows = 24,
    });
    try std.testing.expectEqual(@as(usize, 1), host_registry.count());
    try std.testing.expectEqual(@as(usize, 80 * 24), host_registry.liveGridCells());
    try std.testing.expectEqual(@as(usize, 1), manager.live_registry.count());

    const Injected = struct {
        fn apply(ctx: *anyopaque, handle: RuntimeHandle, size: maru.terminal.Size, io: std.Io) anyerror!void {
            // 실제 SurfaceRuntime과 같은 순서로 core를 먼저 mutate한 뒤 PTY 단계 실패를 주입한다.
            const owner: *RuntimeManager = @ptrCast(@alignCast(ctx));
            const terminal_slot = owner.backend_impl.terminalForHostLifecycle(handle) orelse
                return error.TestUnexpectedResult;
            terminal_slot.surface.lockCore(io);
            defer terminal_slot.surface.unlockCore(io);
            try terminal_slot.surface.core.resize(size.cols, size.rows);
            return error.InjectedPartialResizeFailure;
        }
    };
    try std.testing.expectError(
        error.InjectedPartialResizeFailure,
        manager.resizeWithApply(runtime_id, 120, 40, &manager, Injected.apply),
    );
    try std.testing.expectEqual(@as(usize, 0), host_registry.count());
    try std.testing.expectEqual(@as(usize, 0), host_registry.liveGridCells());
    try std.testing.expectEqual(@as(usize, 0), manager.live_registry.count());
    try std.testing.expect(manager.handleFor(runtime_id) == null);
}

test "runtime manager: exhausted restored handle cursor rejects spawn before creating a child" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var host_registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer host_registry.deinit();
    var manager: RuntimeManager = undefined;
    manager.init(allocator, std.testing.io, &host_registry, null);
    defer manager.deinit();
    manager.next_handle = std.math.maxInt(RuntimeHandle);
    const ops = manager.runtimeOps();
    try std.testing.expectError(error.IdSpaceExhausted, ops.spawn(ops.ctx, .{
        .argv = &.{"/bin/cat"},
        .cwd = null,
        .cols = 20,
        .rows = 4,
    }));
    try std.testing.expectEqual(@as(usize, 0), host_registry.count());
    try std.testing.expectEqual(@as(usize, 0), manager.live_registry.count());
}

test "runtime manager: resume joins every reached reader before reopening a two-runtime frontier" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var host_registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer host_registry.deinit();
    var mgr: RuntimeManager = undefined;
    mgr.init(allocator, std.testing.io, &host_registry, null);
    defer mgr.deinit();

    const ops = mgr.runtimeOps();
    const first = try ops.spawn(ops.ctx, .{ .argv = &.{"/bin/cat"}, .cwd = null, .cols = 24, .rows = 6 });
    defer ops.terminate(ops.ctx, first);
    const second = try ops.spawn(ops.ctx, .{ .argv = &.{"/bin/cat"}, .cwd = null, .cols = 24, .rows = 6 });
    defer ops.terminate(ops.ctx, second);

    try std.testing.expectEqual(@as(usize, 2), try mgr.requestUpgradeQuiesce());
    var attempts: usize = 0;
    while (attempts < 1000 and !mgr.upgradeQuiesceReached()) : (attempts += 1) _ = usleep(1000);
    try std.testing.expect(mgr.upgradeQuiesceReached());
    // joinAndValidate를 일부러 호출하지 않는다. resume이 reached-but-unjoined thread를 cancel 성공으로 오인하면
    // pause flag와 종료된 thread가 남으므로 이 두 runtime은 다시 usable frontier가 되지 못한다.
    try mgr.resumeUpgradeQuiesce();
    try std.testing.expect(!mgr.upgradeQuiesceReached());
    try ops.write_input(ops.ctx, first, "first-alive\n");
    try ops.write_input(ops.ctx, second, "second-alive\n");
}

test "runtime manager: U2 quiesce refuses attached runtimes without pausing their reader" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var host_registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer host_registry.deinit();
    var mgr: RuntimeManager = undefined;
    mgr.init(allocator, std.testing.io, &host_registry, null);
    defer mgr.deinit();

    const ops = mgr.runtimeOps();
    const rid = try ops.spawn(ops.ctx, .{ .argv = &.{"/bin/cat"}, .cwd = null, .cols = 24, .rows = 6 });
    defer ops.terminate(ops.ctx, rid);
    _ = try host_registry.attachSubscription(rid, .{ .value = 99 }, .observer);
    try std.testing.expectError(error.Attached, mgr.requestUpgradeQuiesce());
    _ = try host_registry.detachSubscription(rid, .{ .value = 99 });

    try ops.write_input(ops.ctx, rid, "still-live\n");
}

test "runtime manager: U2 pause reaches a safe frontier under continuous PTY output and resumes" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var host_registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer host_registry.deinit();
    var mgr: RuntimeManager = undefined;
    mgr.init(allocator, std.testing.io, &host_registry, null);
    defer mgr.deinit();
    const ops = mgr.runtimeOps();
    const rid = try ops.spawn(ops.ctx, .{
        .argv = &.{ "/bin/sh", "-c", "while :; do printf x; done" },
        .cwd = null,
        .cols = 20,
        .rows = 4,
    });
    defer ops.terminate(ops.ctx, rid);

    try std.testing.expectEqual(@as(usize, 1), try mgr.requestUpgradeQuiesce());
    var attempts: usize = 0;
    while (attempts < 5000 and !mgr.upgradeQuiesceReached()) : (attempts += 1) _ = usleep(1000);
    try std.testing.expect(mgr.upgradeQuiesceReached());
    try mgr.joinAndValidateUpgradeQuiesce();
    try mgr.resumeUpgradeQuiesce();
    try ops.write_input(ops.ctx, rid, "ignored-but-admitted");
}

test "runtime manager: child exit while quiesced aborts without consuming status and retry can proceed" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var host_registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer host_registry.deinit();
    var mgr: RuntimeManager = undefined;
    mgr.init(allocator, std.testing.io, &host_registry, null);
    defer mgr.deinit();

    const ops = mgr.runtimeOps();
    const rid = try ops.spawn(ops.ctx, .{
        .argv = &.{"/bin/cat"},
        .cwd = null,
        .cols = 20,
        .rows = 4,
    });
    const handle = mgr.handleFor(rid) orelse return error.TestUnexpectedResult;
    const terminal_slot = mgr.backend_impl.terminalForHostLifecycle(handle) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), try mgr.requestUpgradeQuiesce());
    var attempts: usize = 0;
    while (attempts < 1000 and !mgr.upgradeQuiesceReached()) : (attempts += 1) _ = usleep(1000);
    try std.testing.expect(mgr.upgradeQuiesceReached());
    // Reader가 safe-point에 도달한 뒤에만 child exit를 유발해 scheduler 속도와 무관하게 "quiesce 중 exit"를 만든다.
    try std.testing.expect(std.c.kill(terminal_slot.live_pty.session.childPid(), std.posix.SIG.TERM) == 0);
    attempts = 0;
    while (attempts < 2000 and !(try terminal_slot.live_pty.session.childExitedWithoutReap())) : (attempts += 1)
        _ = usleep(1000);
    try std.testing.expect(try terminal_slot.live_pty.session.childExitedWithoutReap());
    try std.testing.expectError(error.RuntimeNotLive, mgr.joinAndValidateUpgradeQuiesce());

    // waitid(WNOWAIT)는 status를 소비하지 않았다. Reader를 재개하면 EOF/exit를 owner queue로 넘기고,
    // owner drain이 한 번만 runtime을 제거한다.
    try mgr.resumeUpgradeQuiesce();
    var total_exited: usize = 0;
    attempts = 0;
    while (attempts < 500 and host_registry.count() != 0) : (attempts += 1) {
        total_exited += mgr.drainOwnedEvents().exited;
        if (host_registry.count() != 0) _ = usleep(1000);
    }
    try std.testing.expectEqual(@as(usize, 0), host_registry.count());
    try std.testing.expectEqual(@as(usize, 1), total_exited);
    try std.testing.expectEqual(@as(usize, 0), mgr.drainOwnedEvents().exited);

    const replacement = try ops.spawn(ops.ctx, .{ .argv = &.{"/bin/cat"}, .cwd = null, .cols = 20, .rows = 4 });
    defer ops.terminate(ops.ctx, replacement);
    try std.testing.expectEqual(@as(usize, 1), try mgr.requestUpgradeQuiesce());
    attempts = 0;
    while (attempts < 1000 and !mgr.upgradeQuiesceReached()) : (attempts += 1) _ = usleep(1000);
    try std.testing.expect(mgr.upgradeQuiesceReached());
    try mgr.joinAndValidateUpgradeQuiesce();
    try mgr.resumeUpgradeQuiesce();
}

test "runtime manager: owner drain consumes a quiesced read error exactly once and blocks upgrade" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var host_registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer host_registry.deinit();
    var mgr: RuntimeManager = undefined;
    mgr.init(allocator, std.testing.io, &host_registry, null);
    defer mgr.deinit();

    const ops = mgr.runtimeOps();
    const rid = try ops.spawn(ops.ctx, .{ .argv = &.{"/bin/cat"}, .cwd = null, .cols = 20, .rows = 4 });
    defer ops.terminate(ops.ctx, rid);
    const handle = mgr.handleFor(rid) orelse return error.TestUnexpectedResult;
    const terminal_slot = mgr.backend_impl.terminalForHostLifecycle(handle) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(@as(usize, 1), try mgr.requestUpgradeQuiesce());
    var attempts: usize = 0;
    while (attempts < 1000 and !mgr.upgradeQuiesceReached()) : (attempts += 1) _ = usleep(1000);
    try std.testing.expect(mgr.upgradeQuiesceReached());
    try terminal_slot.live_pty.eventQueue().tryPush(.{ .read_error = .{
        .pty_id = handle,
        .message = "injected-quiesced-read-error",
    } });
    try std.testing.expectError(error.RuntimeNotLive, mgr.joinAndValidateUpgradeQuiesce());
    const second = mgr.drainOwnedEvents();
    try std.testing.expectEqual(@as(usize, 0), second.read_errors);
    try std.testing.expectEqual(@as(usize, 1), host_registry.count());
    try std.testing.expectError(error.RuntimeNotLive, mgr.requestUpgradeQuiesce());
}

test "runtime manager: initial config is applied before fast first output reaches the host core" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var host_registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer host_registry.deinit();
    var mgr: RuntimeManager = undefined;
    mgr.init(allocator, std.testing.io, &host_registry, null);
    defer mgr.deinit();

    var palette: core_command_wire.Command.Palette = .{null} ** 16;
    palette[1] = 0x11_22_33;
    const ops = mgr.runtimeOps();
    const script = "i=0; while [ $i -lt 1100 ]; do echo x; i=$((i+1)); done; sleep 2";
    const rid = try ops.spawn(ops.ctx, .{
        .argv = &.{ "/bin/sh", "-c", script },
        .cwd = null,
        .cols = 20,
        .rows = 5,
        .initial_config = .{
            .max_scrollback = 1200,
            .ambiguous_wide = true,
            .emoji_wide = false,
            .palette = palette,
            .default_colors = .{ .foreground = 0xAA_BB_CC, .background = 0x01_02_03 },
            .cell_metrics = .{ .width = 9, .height = 18 },
        },
    });
    defer ops.terminate(ops.ctx, rid);
    const handle = mgr.handleFor(rid) orelse return error.TestUnexpectedResult;
    const surface = mgr.backend_impl.surfaceFor(handle) orelse return error.TestUnexpectedResult;

    // spawn이 돌아온 시점에는 reader가 시작됐지만 config는 그보다 먼저 적용돼 있어야 한다.
    surface.lockCore(std.testing.io);
    try std.testing.expectEqual(@as(usize, 1200), surface.core.maxScrollback());
    try std.testing.expect(surface.core.ambiguous_wide);
    try std.testing.expectEqual(@as(u8, 0x22), surface.core.config_palette[1].?.g);
    surface.unlockCore(std.testing.io);

    // 기본 cap(1000)보다 많은 첫 burst를 보존한다. config가 attach 뒤 RPC였다면 앞부분이 기본 cap에서 먼저 evict될 수 있다.
    var retained = false;
    var attempts: usize = 0;
    while (attempts < 300 and !retained) : (attempts += 1) {
        surface.lockCore(std.testing.io);
        retained = surface.core.scrollbackLen() > 1000;
        surface.unlockCore(std.testing.io);
        if (!retained) _ = usleep(10 * 1000);
    }
    try std.testing.expect(retained);
}

test "runtime manager: writeInput and resize reach a real runtime through RuntimeOps" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var host_registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer host_registry.deinit();
    var mgr: RuntimeManager = undefined;
    mgr.init(allocator, std.testing.io, &host_registry, null);
    defer mgr.deinit();

    const ops = mgr.runtimeOps();
    // cat은 입력 EOF까지 살아 있어 writeInput/resize를 적용할 실 runtime을 준다.
    const rid = try ops.spawn(ops.ctx, .{ .argv = &.{"/bin/cat"}, .cwd = null, .cols = 40, .rows = 10 });
    const handle = mgr.handleFor(rid) orelse return error.TestUnexpectedResult;
    const surface = mgr.backend_impl.surfaceFor(handle) orelse return error.TestUnexpectedResult;

    // writeInput/resize가 실 backend에 에러 없이 위임된다(실제 화면 반영은 e2d stream이 검증). 매니저 resizeOp는 backend
    // 적용만 하고 canonical(registry) 갱신은 server.dispatchResize의 몫이라, 여기선 backend 위임 성공만 본다.
    try ops.write_input(ops.ctx, rid, "hello\n");
    try ops.resize(ops.ctx, rid, 100, 30);

    var saw_echo = false;
    var attempts: usize = 0;
    while (attempts < 300 and !saw_echo) : (attempts += 1) {
        surface.lockCore(std.testing.io);
        const text = surface.core.dumpRecentTextUtf8(allocator, 10, 4096) catch null;
        surface.unlockCore(std.testing.io);
        if (text) |owned| {
            saw_echo = std.mem.indexOf(u8, owned, "hello") != null;
            allocator.free(owned);
        }
        if (!saw_echo) _ = usleep(10 * 1000);
    }
    try std.testing.expect(saw_echo);

    // 없는 runtime_id는 RuntimeNotFound(다른 runtime으로 새지 않는다).
    try std.testing.expectError(error.RuntimeNotFound, ops.write_input(ops.ctx, 0xDEADBEEF, "x"));
    try std.testing.expectError(error.RuntimeNotFound, ops.resize(ops.ctx, 0xDEADBEEF, 10, 10));

    ops.terminate(ops.ctx, rid);
    try std.testing.expectEqual(@as(usize, 0), host_registry.count());
}

test "runtime manager: bounded core config commands reach the real host reader core" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var host_registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer host_registry.deinit();
    var mgr: RuntimeManager = undefined;
    mgr.init(allocator, std.testing.io, &host_registry, null);
    defer mgr.deinit();

    const ops = mgr.runtimeOps();
    const rid = try ops.spawn(ops.ctx, .{ .argv = &.{"/bin/cat"}, .cwd = null, .cols = 40, .rows = 10 });
    defer ops.terminate(ops.ctx, rid);
    const handle = mgr.handleFor(rid) orelse return error.TestUnexpectedResult;
    const surface = mgr.backend_impl.surfaceFor(handle) orelse return error.TestUnexpectedResult;

    var wire_palette: core_command_wire.Command.Palette = .{null} ** 16;
    wire_palette[2] = 0x12_34_56;
    try ops.core_command(ops.ctx, rid, .{ .set_runtime_config = .{
        .max_scrollback = 321,
        .ambiguous_wide = true,
        .emoji_wide = false,
        .palette = wire_palette,
        .default_colors = .{
            .foreground = 0xAA_BB_CC,
            .background = 0x01_02_03,
        },
        .cell_metrics = .{ .width = 9, .height = 18 },
    } });

    // RuntimeOps 응답은 command admission을 뜻한다. 실제 reader 적용도 bounded하게 기다려 host core 상태로 증명한다.
    var applied = false;
    var attempts: usize = 0;
    while (attempts < 100 and !applied) : (attempts += 1) {
        surface.lockCore(std.testing.io);
        applied = surface.core.maxScrollback() == 321 and
            surface.core.ambiguous_wide and
            !surface.core.emoji_wide and
            surface.core.cell_width_px == 9 and
            surface.core.cell_height_px == 18 and
            surface.core.default_fg_rgb.r == 0xAA and
            surface.core.default_bg_rgb.b == 0x03 and
            surface.core.config_palette[2] != null and
            surface.core.config_palette[2].?.g == 0x34;
        surface.unlockCore(std.testing.io);
        if (!applied) _ = usleep(10 * 1000);
    }
    try std.testing.expect(applied);
}

test "runtime manager: host selection scroll-and-extend is fenced before authoritative copy" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var host_registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer host_registry.deinit();
    var mgr: RuntimeManager = undefined;
    mgr.init(allocator, std.testing.io, &host_registry, null);
    defer mgr.deinit();

    const ops = mgr.runtimeOps();
    const script = "i=0; while [ $i -lt 30 ]; do printf 'L%02d\\n' $i; i=$((i+1)); done; exec cat";
    const rid = try ops.spawn(ops.ctx, .{ .argv = &.{ "/bin/sh", "-c", script }, .cwd = null, .cols = 20, .rows = 5 });
    defer ops.terminate(ops.ctx, rid);
    const handle = mgr.handleFor(rid) orelse return error.TestUnexpectedResult;
    const surface = mgr.backend_impl.surfaceFor(handle) orelse return error.TestUnexpectedResult;

    var ready = false;
    var attempts: usize = 0;
    while (attempts < 300 and !ready) : (attempts += 1) {
        surface.lockCore(std.testing.io);
        ready = surface.core.scrollbackLen() >= 20;
        surface.unlockCore(std.testing.io);
        if (!ready) _ = usleep(10 * 1000);
    }
    try std.testing.expect(ready);

    // 각 RuntimeOps 응답은 이 selection presentation-state가 이미 core에 적용됐다는 fence다.
    try ops.core_command(ops.ctx, rid, .{ .selection_start = .{ .row = 4, .col = 2, .block = false } });
    try ops.core_command(ops.ctx, rid, .{ .selection_scroll_and_extend = .{ .row = 0, .col = 0, .delta = 1 } });
    try ops.core_command(ops.ctx, rid, .{ .selection_scroll_and_extend = .{ .row = 0, .col = 0, .delta = 1 } });

    const body = try ops.selected_text(ops.ctx, rid, .{
        .sr = 0,
        .sc = 0,
        .er = 0,
        .ec = 0,
        .block = false,
        .authoritative = true,
    }, allocator);
    defer allocator.free(body);
    try std.testing.expectEqualStrings("{\"text\":\"L24\\nL25\\nL26\\nL27\\nL28\\nL29\\n\"}", body);
}

test "runtime manager: focus report is written back to the real PTY by the host reader" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cwd_buf: [4096]u8 = undefined;
    _ = std.c.getcwd(&cwd_buf, cwd_buf.len);
    const proc_cwd = std.mem.sliceTo(&cwd_buf, 0);
    const result_path = try std.fs.path.join(allocator, &.{ proc_cwd, ".zig-cache/tmp", &tmp.sub_path, "focus.hex" });
    defer allocator.free(result_path);
    const script = try std.fmt.allocPrint(
        allocator,
        "stty raw -echo; printf '\\033[?1004h'; dd bs=1 count=5 2>/dev/null | od -An -tx1 | tr -d ' \\n' > '{s}'",
        .{result_path},
    );
    defer allocator.free(script);

    var host_registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer host_registry.deinit();
    var mgr: RuntimeManager = undefined;
    mgr.init(allocator, std.testing.io, &host_registry, null);
    defer mgr.deinit();

    const ops = mgr.runtimeOps();
    const rid = try ops.spawn(ops.ctx, .{ .argv = &.{ "/bin/sh", "-c", script }, .cwd = null, .cols = 40, .rows = 10 });
    defer ops.terminate(ops.ctx, rid);
    const handle = mgr.handleFor(rid) orelse return error.TestUnexpectedResult;
    const surface = mgr.backend_impl.surfaceFor(handle) orelse return error.TestUnexpectedResult;

    // 자식이 DECSET 1004를 출력해 host core가 focus report를 요청할 때까지 기다린다.
    var focus_enabled = false;
    var attempts: usize = 0;
    while (attempts < 200 and !focus_enabled) : (attempts += 1) {
        surface.lockCore(std.testing.io);
        focus_enabled = surface.core.focus_events;
        surface.unlockCore(std.testing.io);
        if (!focus_enabled) _ = usleep(10 * 1000);
    }
    try std.testing.expect(focus_enabled);

    // 별도 input/command queue가 실제 PTY에서도 호출 순서를 보존해야 한다. reader는 A를 fence까지 쓴 뒤
    // focus command가 만든 CSI I를 우선 쓰고, 그 뒤 suffix B를 쓴다.
    try ops.write_input(ops.ctx, rid, "A");
    try ops.core_command(ops.ctx, rid, .{ .report_focus = true });
    try ops.write_input(ops.ctx, rid, "B");

    // reader가 `A`, `CSI I`, `B` 다섯 바이트를 정확한 순서로 PTY에 쓰면 자식이 별도 파일에 hex로 남긴다.
    // 단순 core mutation이나 command/input 순서가 뒤집힌 구현으로는 이 값이 생기지 않는다.
    var saw_ordered_bytes = false;
    attempts = 0;
    while (attempts < 200 and !saw_ordered_bytes) : (attempts += 1) {
        const result = tmp.dir.readFileAlloc(std.testing.io, "focus.hex", allocator, .limited(4096)) catch null;
        if (result) |bytes| {
            saw_ordered_bytes = std.mem.indexOf(u8, bytes, "411b5b4942") != null;
            allocator.free(bytes);
        }
        if (!saw_ordered_bytes) _ = usleep(10 * 1000);
    }
    try std.testing.expect(saw_ordered_bytes);
}

test "P4 input parity: host reader writes DECSET 1003 motion to the real PTY" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cwd_buf: [4096]u8 = undefined;
    const cwd_ptr = std.c.getcwd(&cwd_buf, cwd_buf.len) orelse return error.SkipZigTest;
    const proc_cwd = std.mem.span(@as([*:0]u8, @ptrCast(cwd_ptr)));
    const result_path = try std.fs.path.join(allocator, &.{ proc_cwd, ".zig-cache/tmp", &tmp.sub_path, "motion.hex" });
    defer allocator.free(result_path);
    const script = try std.fmt.allocPrint(
        allocator,
        "stty raw -echo; printf '\\033[?1003h\\033[?1006h'; dd bs=1 count=10 2>/dev/null | od -An -tx1 | tr -d ' \\n' > '{s}'",
        .{result_path},
    );
    defer allocator.free(script);

    var host_registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer host_registry.deinit();
    var mgr: RuntimeManager = undefined;
    mgr.init(allocator, std.testing.io, &host_registry, null);
    defer mgr.deinit();

    const ops = mgr.runtimeOps();
    const rid = try ops.spawn(ops.ctx, .{ .argv = &.{ "/bin/sh", "-c", script }, .cwd = null, .cols = 40, .rows = 10 });
    defer ops.terminate(ops.ctx, rid);
    const handle = mgr.handleFor(rid) orelse return error.TestUnexpectedResult;
    const surface = mgr.backend_impl.surfaceFor(handle) orelse return error.TestUnexpectedResult;

    var ready = false;
    var attempts: usize = 0;
    while (attempts < 200 and !ready) : (attempts += 1) {
        surface.lockCore(std.testing.io);
        ready = surface.core.mouse_tracking == .any and surface.core.mouse_format == .sgr;
        surface.unlockCore(std.testing.io);
        if (!ready) _ = usleep(10 * 1000);
    }
    try std.testing.expect(ready);

    // AppSession의 0-based cell `(4,2)`와 no-button 3을 그대로 보낸다. host core만 현재
    // DECSET/format을 알고 있으므로 reader가 `Cb=3+32`, 1-based 좌표로 인코딩해야 한다.
    try ops.report_mouse(ops.ctx, rid, .{
        .button = 3,
        .col = 4,
        .row = 2,
        .x_px = 0,
        .y_px = 0,
        .pressed = true,
        .motion = true,
        .mods = 0,
    });

    var saw_motion = false;
    attempts = 0;
    while (attempts < 200 and !saw_motion) : (attempts += 1) {
        const result = tmp.dir.readFileAlloc(std.testing.io, "motion.hex", allocator, .limited(4096)) catch null;
        if (result) |bytes| {
            // ESC [ < 35 ; 5 ; 3 M == xterm SGR no-button motion at cell (4,2).
            saw_motion = std.mem.eql(u8, bytes, "1b5b3c33353b353b334d");
            allocator.free(bytes);
        }
        if (!saw_motion) _ = usleep(10 * 1000);
    }
    try std.testing.expect(saw_motion);
}

test "runtime manager: clear and reset commands reach the authoritative host reader" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cwd_buf: [4096]u8 = undefined;
    _ = std.c.getcwd(&cwd_buf, cwd_buf.len);
    const proc_cwd = std.mem.sliceTo(&cwd_buf, 0);
    const result_path = try std.fs.path.join(allocator, &.{ proc_cwd, ".zig-cache/tmp", &tmp.sub_path, "clear.hex" });
    defer allocator.free(result_path);
    const script = try std.fmt.allocPrint(
        allocator,
        "stty raw -echo; printf '\\033]133;A\\033\\\\prompt\\033[?1004h\\033[?1003h'; dd bs=1 count=3 2>/dev/null | od -An -tx1 | tr -d ' \\n' > '{s}'",
        .{result_path},
    );
    defer allocator.free(script);

    var host_registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer host_registry.deinit();
    var mgr: RuntimeManager = undefined;
    mgr.init(allocator, std.testing.io, &host_registry, null);
    defer mgr.deinit();

    const ops = mgr.runtimeOps();
    const rid = try ops.spawn(ops.ctx, .{ .argv = &.{ "/bin/sh", "-c", script }, .cwd = null, .cols = 40, .rows = 10 });
    defer ops.terminate(ops.ctx, rid);
    const handle = mgr.handleFor(rid) orelse return error.TestUnexpectedResult;
    const surface = mgr.backend_impl.surfaceFor(handle) orelse return error.TestUnexpectedResult;

    var ready = false;
    var attempts: usize = 0;
    while (attempts < 200 and !ready) : (attempts += 1) {
        surface.lockCore(std.testing.io);
        ready = surface.core.cursorIsAtPrompt() and surface.core.focus_events and surface.core.mouse_tracking == .any;
        surface.unlockCore(std.testing.io);
        if (!ready) _ = usleep(10 * 1000);
    }
    try std.testing.expect(ready);

    // A 이전 fence 뒤 clear가 권위 prompt를 보고 ^L을 만들고, B는 그 뒤에 와야 한다.
    try ops.write_input(ops.ctx, rid, "A");
    try ops.core_command(ops.ctx, rid, .clear_screen);
    try ops.write_input(ops.ctx, rid, "B");
    try ops.core_command(ops.ctx, rid, .reset_input_modes);

    var reset_applied = false;
    attempts = 0;
    while (attempts < 200 and !reset_applied) : (attempts += 1) {
        surface.lockCore(std.testing.io);
        reset_applied = !surface.core.focus_events and surface.core.mouse_tracking == .none;
        surface.unlockCore(std.testing.io);
        if (!reset_applied) _ = usleep(10 * 1000);
    }
    try std.testing.expect(reset_applied);

    var saw_ordered_bytes = false;
    attempts = 0;
    while (attempts < 200 and !saw_ordered_bytes) : (attempts += 1) {
        const result = tmp.dir.readFileAlloc(std.testing.io, "clear.hex", allocator, .limited(4096)) catch null;
        if (result) |bytes| {
            saw_ordered_bytes = std.mem.indexOf(u8, bytes, "410c42") != null;
            allocator.free(bytes);
        }
        if (!saw_ordered_bytes) _ = usleep(10 * 1000);
    }
    try std.testing.expect(saw_ordered_bytes);
}

test "runtime manager: snapshot projects the runtime's live screen through RuntimeOps" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var host_registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer host_registry.deinit();
    var mgr: RuntimeManager = undefined;
    mgr.init(allocator, std.testing.io, &host_registry, null);
    defer mgr.deinit();

    const ops = mgr.runtimeOps();
    const rid = try ops.spawn(ops.ctx, .{ .argv = &.{"/bin/cat"}, .cwd = null, .cols = 24, .rows = 6 });

    // snapshot이 실 core를 lock한 채 투영해 첫 record(screen_meta)에 spawn 크기(24x6)를 담는다.
    const snap = try ops.snapshot(ops.ctx, rid, 0, allocator);
    defer allocator.free(snap.bytes);
    try std.testing.expectEqual(@as(u64, 0), snap.frontier.sequence);
    var rs = screen_stream.RecordStream{ .bytes = snap.bytes };
    const first = (try rs.next()).?;
    const s = try screen_stream.RecordStream.split(first);
    try std.testing.expectEqual(screen_stream.RecordKind.screen_meta, s.header.kind);
    const meta = try screen_stream.decodeScreenMeta(s.body);
    try std.testing.expectEqual(@as(u16, 24), meta.cols);
    try std.testing.expectEqual(@as(u16, 6), meta.rows);

    // 없는 runtime_id는 RuntimeNotFound(다른 runtime으로 새지 않는다).
    try std.testing.expectError(error.RuntimeNotFound, ops.snapshot(ops.ctx, 0xDEADBEEF, 0, allocator));

    ops.terminate(ops.ctx, rid);
}

// host-backed Find의 좌표계 계약. findOp는 scroll 요청을 받으면 host 화면을 먼저 옮기고 **그 스크롤된 화면**
// 기준으로 span을 계산한다. client는 그 스크롤을 delta로 받기 전이므로, 응답에 기준 view_offset(voff)을 실어
// client가 자기 화면과 대조해 정합할 때만 그리게 한다 — 안 그러면 좌표계가 다른 화면에 하이라이트를 찍는다.
test "runtime manager: find는 span을 계산한 기준 view_offset을 응답에 싣는다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var host_registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer host_registry.deinit();
    var mgr: RuntimeManager = undefined;
    mgr.init(allocator, std.testing.io, &host_registry, null);
    defer mgr.deinit();

    const ops = mgr.runtimeOps();
    const rid = try ops.spawn(ops.ctx, .{ .argv = &.{"/bin/cat"}, .cwd = null, .cols = 20, .rows = 4 });
    defer ops.terminate(ops.ctx, rid);

    // host core에 직접 써 넣는다(PTY 왕복 없이 결정적으로 — 화면 소유자는 host다). 매치는 스크롤백 위쪽에 둬
    // 바닥 뷰포트에서는 안 보이게 한다.
    const handle = mgr.handleFor(rid).?;
    const surface = mgr.backend_impl.surfaceFor(handle).?;
    {
        surface.lockCore(mgr.io);
        defer surface.unlockCore(mgr.io);
        try surface.core.write("l0\r\nMARUFIND\r\nl2\r\nl3\r\nl4\r\nl5\r\nl6\r\nl7\r\nl8\r\nl9\r\nl10\r\nl11");
    }
    const query_hex = "4d41525546494e44"; // "MARUFIND"

    // scroll=false: host 화면이 그대로(바닥)라 voff=0이고, 뷰포트 밖 매치라 그릴 span도 없다.
    {
        const body = try ops.find(ops.ctx, rid, query_hex, 0, false, allocator);
        defer allocator.free(body);
        try std.testing.expect(std.mem.indexOf(u8, body, "\"count\":1") != null);
        try std.testing.expect(std.mem.indexOf(u8, body, "\"voff\":0") != null);
        try std.testing.expect(std.mem.indexOf(u8, body, "\"cur\":[]") != null);
    }

    // scroll=true: host가 매치로 스크롤한 뒤 **그 화면 기준**으로 span을 낸다 — voff가 0이 아니게 되고, 그 값이
    // 곧 client가 자기 화면과 대조해야 할 기준이다(같아지기 전에 그리면 엉뚱한 줄이 하이라이트된다).
    {
        const body = try ops.find(ops.ctx, rid, query_hex, 0, true, allocator);
        defer allocator.free(body);
        try std.testing.expect(std.mem.indexOf(u8, body, "\"voff\":0") == null);
        try std.testing.expect(std.mem.indexOf(u8, body, "\"cur\":[]") == null); // 스크롤 후엔 현재 매치가 보인다
        const voff = blk: {
            const at = std.mem.indexOf(u8, body, "\"voff\":").? + "\"voff\":".len;
            var v: usize = 0;
            var i: usize = at;
            while (i < body.len and body[i] >= '0' and body[i] <= '9') : (i += 1) v = v * 10 + (body[i] - '0');
            break :blk v;
        };
        surface.lockCore(mgr.io);
        defer surface.unlockCore(mgr.io);
        try std.testing.expectEqual(surface.core.viewOffset(), voff); // 응답 voff = span을 계산한 실제 화면 위치
    }
}

// 원격 Cmd+클릭은 host가 여는 대상을 정한다 — client core는 빈 placeholder라 추출이 불가능하고, file_path의
// cwd resolve·존재 stat은 host 파일시스템에서 해야 정확하다. host가 자기 core의 extractUrlAt(로컬과 같은 함수)을
// 돌려 URL을 돌려주는지, client가 보낸 scope 비트를 실제로 적용하는지(web만 켜면 경로는 안 열림) 고정한다.
test "runtime manager: link_at extracts a URL from the host core and honors client scopes" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var host_registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer host_registry.deinit();
    var mgr: RuntimeManager = undefined;
    mgr.init(allocator, std.testing.io, &host_registry, null);
    defer mgr.deinit();

    const ops = mgr.runtimeOps();
    const rid = try ops.spawn(ops.ctx, .{ .argv = &.{"/bin/cat"}, .cwd = null, .cols = 40, .rows = 4 });
    defer ops.terminate(ops.ctx, rid);

    // host core에 직접 써 넣는다(PTY 왕복 없이 결정적으로 — 화면 소유자는 host다).
    const handle = mgr.handleFor(rid).?;
    const surface = mgr.backend_impl.surfaceFor(handle).?;
    {
        surface.lockCore(mgr.io);
        defer surface.unlockCore(mgr.io);
        try surface.core.write("go https://example.com/page now");
    }

    const full_bits: u8 = 0b0011_1111; // web|extra|absolute|home|dot|bare — client의 link-detection=full
    {
        const body = try ops.link_at(ops.ctx, rid, 0, 10, full_bits, allocator);
        defer allocator.free(body);
        try std.testing.expect(std.mem.indexOf(u8, body, "https://example.com/page") != null);
    }
    // 링크가 없는 셀은 빈 text(client는 일반 클릭으로 흘린다).
    {
        const body = try ops.link_at(ops.ctx, rid, 0, 0, full_bits, allocator);
        defer allocator.free(body);
        try std.testing.expect(std.mem.indexOf(u8, body, "https://") == null);
    }
    // scopes=0(osc8-only)이면 자동 감지가 꺼져 같은 셀도 안 열린다 — client 정책이 host까지 전달되는지.
    {
        const body = try ops.link_at(ops.ctx, rid, 0, 10, 0, allocator);
        defer allocator.free(body);
        try std.testing.expect(std.mem.indexOf(u8, body, "https://") == null);
    }
    // 없는 runtime_id는 RuntimeNotFound(다른 runtime으로 새지 않는다).
    try std.testing.expectError(error.RuntimeNotFound, ops.link_at(ops.ctx, 0xDEADBEEF, 0, 0, full_bits, allocator));
}

test "P4 E2b runtime manager shares one canonical observation per cadence epoch" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var host_registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer host_registry.deinit();
    var mgr: RuntimeManager = undefined;
    mgr.init(allocator, std.testing.io, &host_registry, null);
    defer mgr.deinit();

    const ops = mgr.runtimeOps();
    const rid = try ops.spawn(ops.ctx, .{ .argv = &.{"/bin/cat"}, .cwd = null, .cols = 24, .rows = 6 });
    defer ops.terminate(ops.ctx, rid);
    const handle = mgr.handleFor(rid) orelse return error.TestUnexpectedResult;
    const surface = mgr.backend_impl.surfaceFor(handle) orelse return error.TestUnexpectedResult;
    surface.lockCore(std.testing.io);
    surface.core.write(
        "\x1b]7;file://localhost/tmp/metadata-repo\x07" ++
            "\x1b]2;metadata-title\x07" ++
            "\x1b]5379;ssh;user@workbox\x07" ++
            "\x1b]133;C\x07",
    ) catch |err| {
        surface.unlockCore(std.testing.io);
        return err;
    };
    surface.unlockCore(std.testing.io);

    var observation = try ops.observation(ops.ctx, rid, allocator);
    defer observation.deinit(allocator);
    try std.testing.expectEqualStrings("/tmp/metadata-repo", observation.cwd);
    try std.testing.expectEqualStrings("metadata-title", observation.window_title);
    try std.testing.expectEqualStrings("user@workbox", observation.ssh_remote_dest.?);
    try std.testing.expectEqual(@as(u8, @intFromEnum(terminal.SemanticPrompt.command)), observation.semantic_state);
    try std.testing.expect(observation.foreground_available);

    const first_cached = try ops.cached_observation(ops.ctx, rid, .{ .cadence_epoch = 100 });
    try std.testing.expect(std.mem.indexOf(u8, first_cached.canonical_json, "metadata-title") != null);
    try std.testing.expectEqual(@as(u64, 1), mgr.fixtureObservationMaterializations());
    const sibling_cached = try ops.cached_observation(ops.ctx, rid, .{ .cadence_epoch = 100 });
    try std.testing.expectEqual(first_cached.change_token, sibling_cached.change_token);
    try std.testing.expectEqual(@as(u64, 1), mgr.fixtureObservationMaterializations());
    const next_epoch = try ops.cached_observation(ops.ctx, rid, .{ .cadence_epoch = 101 });
    try std.testing.expectEqual(first_cached.change_token, next_epoch.change_token);
    try std.testing.expectEqual(@as(u64, 1), mgr.fixtureObservationMaterializations());
    _ = try ops.cached_observation(ops.ctx, rid, .{ .cadence_epoch = 99 });
    try std.testing.expectEqual(@as(u64, 1), mgr.fixtureObservationMaterializations());

    surface.lockCore(std.testing.io);
    surface.core.write("changed") catch |err| {
        surface.unlockCore(std.testing.io);
        return err;
    };
    surface.unlockCore(std.testing.io);
    const changed_epoch = try ops.cached_observation(ops.ctx, rid, .{ .cadence_epoch = 102 });
    try std.testing.expect(changed_epoch.change_token != first_cached.change_token);
    try std.testing.expectEqual(@as(u64, 2), mgr.fixtureObservationMaterializations());
    _ = try ops.cached_observation(ops.ctx, rid, .fresh);
    try std.testing.expectEqual(@as(u64, 3), mgr.fixtureObservationMaterializations());
}

test "P4 E2c observation materialization follows runtime source changes at 1 10 100 scale" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    for ([_]usize{ 1, 10, 100 }) |runtime_count| {
        var host_registry = reg.TerminalRuntimeRegistry.init(allocator);
        var mgr: RuntimeManager = undefined;
        mgr.init(allocator, std.testing.io, &host_registry, null);
        const ops = mgr.runtimeOps();
        var runtime_ids: [100]u128 = undefined;
        var spawned: usize = 0;
        errdefer {
            while (spawned != 0) {
                spawned -= 1;
                ops.terminate(ops.ctx, runtime_ids[spawned]);
            }
            mgr.deinit();
            host_registry.deinit();
        }
        while (spawned < runtime_count) : (spawned += 1) {
            runtime_ids[spawned] = try ops.spawn(ops.ctx, .{
                .argv = &.{"/bin/cat"},
                .cwd = null,
                .cols = 24,
                .rows = 6,
            });
        }
        mgr.fixtureEnableObservationPerformanceEvidence();

        // **첫 훑기는 runtime 당 정확히 한 번이다** — 캐시가 비어 있으므로 source 상태와 무관하게
        // refresh 한다. 이 단언만이 spawn 직후에도 결정적이다.
        var settle_epoch: u64 = 1;
        for (runtime_ids[0..runtime_count]) |rid|
            _ = try ops.cached_observation(ops.ctx, rid, .{ .cadence_epoch = settle_epoch });
        try std.testing.expectEqual(@as(u64, @intCast(runtime_count)), mgr.fixtureObservationMaterializations());

        // **그 다음 판정은 source 가 가라앉은 뒤라야 한다.** 갓 spawn 한 `/bin/cat` 은 exec 를 마칠
        // 때까지 foreground pgid·cwd·title generation 이 아직 움직이고, 그 움직임이 `source_changed`
        // 를 참으로 만들어 **두 번째·세 번째 호출도 materialize 한다**. 그것은 캐시 결함이 아니라
        // 아직 안 정해진 것을 잰 것이다 — 실측으로 100 을 기대한 자리에 101·102·103 이 나왔고
        // (세 세션이 각자 겪었다), 러너가 느릴수록 잦았다.
        //
        // **기다리지 않고 «가라앉았음» 을 확인한다.** 한 훑기가 아무것도 materialize 하지 않으면
        // 그 순간 모든 runtime 의 source 가 캐시와 같다는 뜻이다. 시간을 재는 대신 그 사실을 본다.
        const settle_pass_max = 16;
        while (settle_epoch < settle_pass_max) {
            settle_epoch += 1;
            mgr.fixtureEnableObservationPerformanceEvidence(); // 카운터 0 — 이 훑기만 센다
            for (runtime_ids[0..runtime_count]) |rid|
                _ = try ops.cached_observation(ops.ctx, rid, .{ .cadence_epoch = settle_epoch });
            if (mgr.fixtureObservationMaterializations() == 0) break;
        } else return error.TestUnexpectedResult; // 열여섯 번을 훑어도 안 가라앉으면 그건 결함이다

        mgr.fixtureEnableObservationPerformanceEvidence(); // 여기서부터가 판정 창이다

        // **구독자 수도 cadence tick 수도 materialize 를 안 늘린다**(이 테스트의 주제). 같은 epoch 를
        // 두 번, 그리고 다음 epoch 를 한 번 물어도 캐시가 답해야 한다.
        for (runtime_ids[0..runtime_count]) |rid| {
            _ = try ops.cached_observation(ops.ctx, rid, .{ .cadence_epoch = 100 });
            _ = try ops.cached_observation(ops.ctx, rid, .{ .cadence_epoch = 100 });
            _ = try ops.cached_observation(ops.ctx, rid, .{ .cadence_epoch = 101 });
        }
        try std.testing.expectEqual(@as(u64, 0), mgr.fixtureObservationMaterializations());

        // Exactly one changed runtime adds exactly one materialization on the following sweep.
        const changed_handle = mgr.handleFor(runtime_ids[runtime_count - 1]) orelse
            return error.TestUnexpectedResult;
        const changed_surface = mgr.backend_impl.surfaceFor(changed_handle) orelse
            return error.TestUnexpectedResult;
        changed_surface.lockCore(std.testing.io);
        changed_surface.core.write("source-change") catch |err| {
            changed_surface.unlockCore(std.testing.io);
            return err;
        };
        changed_surface.unlockCore(std.testing.io);
        for (runtime_ids[0..runtime_count]) |rid|
            _ = try ops.cached_observation(ops.ctx, rid, .{ .cadence_epoch = 102 });
        // **바뀐 하나만 늘어난다.** 판정 창이 위에서 0 이었으므로 이 값이 곧 «그 훑기가 만든 것» 이다.
        try std.testing.expectEqual(@as(u64, 1), mgr.fixtureObservationMaterializations());
        const evidence = mgr.fixtureObservationPerformanceEvidence();
        // **코어 잠금은 materialize 한 번당 셋이고, 캐시가 답한 호출은 아예 안 잡는다.**
        // 판정 창의 materialize 는 하나(바뀐 runtime)이므로 셋이고, **규모와 무관하다** — 1·10·100
        // 어디서나 3 이다. 그것이 이 게이트의 요점이다: 구독자와 tick 이 늘어도 코어를 더 잠그지 않는다.
        //
        // 옛 단언 `3 × (N + 1)` 이 바로 이 곱이었다(첫 훑기의 N 번 + 바뀐 하나). 판정 창을 첫 훑기
        // 뒤로 옮기면서 그 N 이 빠졌다. 실측으로 확인했다 — 규모 1 과 10 에서 둘 다 3 이다.
        try std.testing.expectEqual(@as(u64, 3), evidence.core_lock_acquisitions);
        try std.testing.expect(evidence.core_lock_hold_total_ns >= evidence.core_lock_hold_max_ns);

        while (spawned != 0) {
            spawned -= 1;
            ops.terminate(ops.ctx, runtime_ids[spawned]);
        }
        mgr.deinit();
        host_registry.deinit();
    }
}

test "P4 E3b runtime sampler visits once per deadline and advances only the changed runtime" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var host_registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer host_registry.deinit();
    var mgr: RuntimeManager = undefined;
    mgr.init(allocator, std.testing.io, &host_registry, null);
    defer mgr.deinit();

    const ops = mgr.runtimeOps();
    const first = try ops.spawn(ops.ctx, .{ .argv = &.{"/bin/cat"}, .cwd = null, .cols = 24, .rows = 6 });
    defer ops.terminate(ops.ctx, first);
    const second = try ops.spawn(ops.ctx, .{ .argv = &.{"/bin/cat"}, .cwd = null, .cols = 24, .rows = 6 });
    defer ops.terminate(ops.ctx, second);
    const first_before = try ops.metadata_change_token.?(ops.ctx, first);
    const second_before = try ops.metadata_change_token.?(ops.ctx, second);
    const base_epoch = @max(
        mgr.metadata_samplers.get(first).?.last_epoch_ns,
        mgr.metadata_samplers.get(second).?.last_epoch_ns,
    );

    ops.sample_metadata_sources.?(ops.ctx, base_epoch +| 100 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(u64, 2), mgr.fixtureMetadataSamplerEvidence().visits);
    ops.sample_metadata_sources.?(ops.ctx, base_epoch +| 101 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(u64, 2), mgr.fixtureMetadataSamplerEvidence().visits);

    const handle = mgr.handleFor(second) orelse return error.TestUnexpectedResult;
    const surface = mgr.backend_impl.surfaceFor(handle) orelse return error.TestUnexpectedResult;
    surface.lockCore(std.testing.io);
    surface.core.write("metadata-source-change") catch |err| {
        surface.unlockCore(std.testing.io);
        return err;
    };
    surface.unlockCore(std.testing.io);
    ops.sample_metadata_sources.?(ops.ctx, base_epoch +| 200 * std.time.ns_per_ms);

    const evidence = mgr.fixtureMetadataSamplerEvidence();
    try std.testing.expectEqual(@as(u64, 4), evidence.visits);
    try std.testing.expectEqual(@as(u64, 1), evidence.changes);
    try std.testing.expectEqual(@as(u64, 0), evidence.failures);
    try std.testing.expectEqual(first_before, try ops.metadata_change_token.?(ops.ctx, first));
    try std.testing.expect(!std.meta.eql(second_before, try ops.metadata_change_token.?(ops.ctx, second)));

    const second_record = mgr.metadata_samplers.getPtr(second) orelse
        return error.TestUnexpectedResult;
    second_record.token = .{
        .incarnation = std.math.maxInt(u64),
        .revision = std.math.maxInt(u64),
    };
    surface.lockCore(std.testing.io);
    surface.core.write("terminal-source-change") catch |err| {
        surface.unlockCore(std.testing.io);
        return err;
    };
    surface.unlockCore(std.testing.io);
    ops.sample_metadata_sources.?(ops.ctx, base_epoch +| 300 * std.time.ns_per_ms);
    try std.testing.expectError(
        error.MetadataChangeTokenExhausted,
        ops.metadata_change_token.?(ops.ctx, second),
    );
    try std.testing.expectEqual(first_before, try ops.metadata_change_token.?(ops.ctx, first));
    try std.testing.expectEqual(@as(u64, 1), mgr.fixtureMetadataSamplerEvidence().failures);
}

test "runtime manager: empty argv is rejected before allocating a handle" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var host_registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer host_registry.deinit();
    var mgr: RuntimeManager = undefined;
    mgr.init(allocator, std.testing.io, &host_registry, null);
    defer mgr.deinit();

    const ops = mgr.runtimeOps();
    try std.testing.expectError(error.EmptyArgv, ops.spawn(ops.ctx, .{ .argv = &.{}, .cwd = null, .cols = 80, .rows = 24 }));
    try std.testing.expectEqual(@as(usize, 0), host_registry.count()); // 실패라 registry에 아무것도 안 남는다.
}
