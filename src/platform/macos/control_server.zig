//! control_server — 세션 컨트롤 플레인 **라이브 서버**(Track C A2b). 앱 인스턴스 전역 소켓을 열고, accept 스레드가
//! 요청을 **메인 프레임루프로 marshal**해 실 collector/dispatch로 응답하게 배선한다. 단일 출처:
//! docs/control-plane.md §5(단일 디스패치=메인 marshal·출력 직송 제외)·§8.4(A2b auth 한계)·§16, docs/
//! docs/plans/io-render-threading.md §8.8(lock-order·교차큐 데드락 선례).
//!
//! **범위(A2b = 라이브 서버 + marshal, 이 파일):**
//!  - 앱 전역 unix socket bind + accept 스레드(heap-pin — 스레드가 &self를 잡으므로 caller가 주소를 고정).
//!  - **accept 스레드**(5f-0b-2a부터)는 **accept + peer-cred(same-uid, 1b acceptOne) + hello + 연결당 스레드 spawn만**
//!    한다(직렬 인라인 serve 폐기 = head-of-line 블로킹 제거, §9.5.1). 연결당 **reader+writer 2-스레드**(5f-0b-2b-2 §9.5.1):
//!    **reader**(serveConnection)가 parse/framing/marshal(§5) — auth 프레임 1회 + **요청 루프**(지속 세션 2b-1) →
//!    `PendingRequest`를 **메인 marshal 큐**에 push → 메인이 채운 응답을 기다렸다가(waitResolved) **연결의 outbound 큐에
//!    push**(직접 소켓 write 안 함). **writer**(writerThread)가 그 outbound 큐(=응답+이벤트 통합)를 `popWait`로 drain해
//!    **소켓에 write**(단일 writer 불변 — reader는 절대 소켓에 안 씀 → 이벤트 write와 경합 없음). 이벤트 push(메인→outbound)·
//!    registry·revoke는 5f-0b-3. 코어·트리·collector·dispatch는 **절대 연결 스레드가 만지지 않는다**.
//!  - 메인 drain(app_host_abi가 tick마다 호출): `tryPopRequest`로 요청을 꺼내 실 collector + auth + dispatch(1d)로
//!    응답 바이트를 만들고 `resolveRequest`로 pending에 채워 그 연결 스레드를 깨운다.
//!
//! **범위 밖:** subscribeOutput 출력 직송(§5, 별도), full self-origin tty 검증(1g), capability fd 실 발급/상속
//!  (1e-confirm — 이 서버는 auth 프레임의 `cap_nonce`를 `parseAuthFrame`으로 파싱해 `PendingRequest.cap_nonces`로 메인
//!  marshal까지만 하고, resolve·store는 app_host_abi가 소유), 실 collector 조립·auth 판정(그건 app_host_abi가
//!  AppSession을 알기에 거기서 — 이 모듈은 AppSession 비의존 generic).
//!
//! **§8.8 lock-order 불변식 엄수:** **연결 스레드**(및 wait-group `conns_mutex`)는 `core_mutex`를 보유하지 않은 채로만
//!  marshal 큐에 push/wait한다. 메인은 collectSessionInto 안에서만 core_mutex를 (짧게) 잡고, 그 락을 쥔 채 marshal
//!  큐에 push/wait하지 않는다. 응답 write는 연결 스레드에서 락 없이 한다(§5). 교차-큐 순환대기 없음(요청 큐 drainer=
//!  메인, pending signal도 메인, 연결 스레드는 아무 코어 락도 안 쥔 채 대기; conns_mutex는 wait-group 전용 leaf lock).
//!
//! **cross-thread 할당:** 요청/응답 바이트는 연결 스레드↔메인을 오가므로 **thread-safe allocator**(`cross_gpa`,
//!  제품은 `std.heap.c_allocator` — libc 링크됨)로만 다룬다. collector arena는 메인 전용(app allocator).
//!
//! **베이스와 결정(docs/document-basis-and-decision):**
//!  - accept 스레드 수명 = poll-gated blocking accept(`Server.pollReady`) + `closing` 플래그. self-connect 트릭
//!    없이 poll timeout으로 주기적으로 closing을 확인해 결정론적으로 종료한다(§5 accept 스레드 수명).
//!  - marshal 큐 = `PtyEventQueue`(docs/io-render-threading.md) 패턴 재사용 — bounded FIFO + Io.Mutex/Condition,
//!    close가 대기 pending을 cancel. 요청/응답 rendezvous는 pending 자체의 mutex+cond+state로 한다.

const builtin = @import("builtin");
const std = @import("std");
const c = std.c;
const posix = std.posix;
const maru = @import("maru");
const cs = @import("control_socket.zig");
const cp = maru.session.control_plane;
const cap = maru.session.control_capability;
const co = maru.session.control_outbound; // 5f-0b-2b: per-connection outbound 프레임 큐(순수 5f-0b-1)
const control_browser = maru.session.control_browser;
const cev = maru.session.control_events; // 5f-0b-3: browser 이벤트 채널 코어(EventBroker 구독 레지스트리·매칭·직렬화, §9.5.2)

// auth 프레임 cap_nonce의 wire 길이(1a)와 capability nonce 길이(1e)가 어긋나면 fd payload↔auth 프레임이 안 맞는다.
// 1a는 capability를 import하지 않으므로(레이어 base) 두 상수를 각자 두되, 둘 다 import하는 이 L4에서 comptime으로 못박는다.
comptime {
    std.debug.assert(cp.auth_cap_nonce_len == cap.nonce_len);
    std.debug.assert(OutboundChannel.terminal_reserve_bytes == control_browser.execute_script_terminal_wire_bytes);
}

/// 메인이 연결 스레드에 응답을 돌려주는 rendezvous 단위. 연결 스레드의 serve 스택에 살며(대기 동안 유효),
/// marshal 큐는 `*PendingRequest`만 담는다. `request_bytes`는 연결 스레드가 `cross_gpa`로 소유(serve 끝에 해제),
/// 메인 drain은 **빌려 읽기만** 한다. `response`는 메인 drain이 `cross_gpa`로 채우고 연결 스레드가 해제한다.
pub const PendingRequest = struct {
    /// 프로세스 수명 동안 재사용하지 않는 연결 ID. async registry는 연결 스택 주소 대신 이 값으로
    /// 결과가 원래 요청 연결에 남아 있는지 교차 확인한다.
    connection_id: u64 = 0,
    connection_fd: c.fd_t = -1,
    /// 요청 프레임 바이트(개행 제외). 연결 스레드 소유(cross_gpa), 메인은 read-only.
    request_bytes: []const u8,
    /// caller가 주장한 self surface_id(auth.self 셀렉터, §8.4). 없으면 null(maru 밖 shell 등).
    selector: ?u64,
    /// 세션 누적 capability nonce **집합**(auth.self `cap_nonce` + 이후 `auth.grant` 프레임들, §9.5.6 ③ 5f-4a). 메인
    /// drain(dispatchAuthenticated)이 각 nonce를 CapabilityStore로 resolve해 **하나라도** 인가하면 통과시킨다(빈=cap 없음=
    /// metadata:self만). 연결 스레드의 **세션 cap 배열을 빌린 슬라이스**(serveConnection 스택 소유, 대기 동안 유효). 실 fd
    /// 상속은 1e-core 범위 밖이라 라이브에선 대개 빈·store 빈=default-deny.
    cap_nonces: []const [cp.auth_cap_nonce_len]u8 = &.{},
    /// 이 요청을 낸 연결의 outbound(5f-0b-3b). `browser.subscribe` dispatch가 메인에서 SubscriberRegistry에 등록할 때
    /// 이 연결을 식별·라우팅한다. serveConnection이 세팅(연결 스레드 스택 소유). subscribe 외 요청은 안 읽어 null 무방(직접
    /// 구성 테스트는 기본 null). **연결 수명 안에서만 유효** — registry 등록은 메인이 하고, 연결 drop 시 purgeOutbound가 뺀다.
    outbound: ?*OutboundChannel = null,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    state: State = .pending,
    /// 메인 drain이 채우는 응답 바이트(cross_gpa 소유). 연결 스레드가 write 후 해제. cancelled면 null.
    response: ?[]u8 = null,

    pub const State = enum { pending, done, enqueued, cancelled };

    /// 연결 스레드: 메인이 resolve/cancel할 때까지 대기하고 최종 상태를 돌려준다.
    fn waitResolved(self: *PendingRequest) State {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (self.state == .pending) self.cond.waitUncancelable(self.io, &self.mutex);
        return self.state;
    }

    /// 메인 drain: 응답을 채우고 연결 스레드를 깨운다(response = cross_gpa 소유, 연결 스레드가 해제).
    /// response=null이면 연결 스레드가 응답 없이 연결을 닫는다(예: 메인 drain의 OOM — pending을 반드시 깨워야
    /// 연결 스레드가 무한 대기하지 않는다).
    fn resolve(self: *PendingRequest, response: ?[]u8) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.state == .pending) {
            self.state = .done;
            self.response = response;
            self.cond.broadcast(self.io);
            return true;
        }
        self.cond.broadcast(self.io);
        return false;
    }

    /// close: 서버 종료로 이 요청을 버린다(연결 스레드가 응답 없이 abandon). response는 안 채운다.
    fn cancel(self: *PendingRequest) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.state == .pending) self.state = .cancelled;
        self.cond.broadcast(self.io);
    }

    /// 메인이 terminal frame을 요청 연결 outbound에 직접 enqueue한 뒤 reader를 깨운다. reader는 같은 응답을
    /// 다시 push하지 않고 다음 요청으로 넘어간다.
    fn resolveEnqueued(self: *PendingRequest) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.state != .pending) return false;
        self.state = .enqueued;
        self.cond.broadcast(self.io);
        return true;
    }
};

pub const QueueError = error{ QueueClosed, ZeroCapacity, OutOfMemory };

/// 연결 스레드 → 메인 marshal 큐(bounded FIFO of `*PendingRequest`). `PtyEventQueue` 결. 연결 스레드가 push,
/// 메인이 `tryPop`. `close`는 대기 중 pending을 전부 cancel해 연결 스레드를 깨운다(종료 시 무한 대기 방지).
///
/// **설계 노트(#6/#8)**: 옛 A2b는 accept가 serial(한 연결을 끝까지 serve 후 다음 accept)이라 marshal in-flight ≤1이었고
/// ring FIFO는 그때 over-built였다. **5f-0b-2a부터 연결당 detached 스레드**(§9.5.1 — head-of-line 블로킹 폐기)라 **여러
/// 연결 스레드가 동시에 push**하므로(MPSC) 이 bounded-FIFO가 이제 **정당하다** — mutex가 push를 직렬화하고 FIFO가 도착
/// 순서를 보존한다. 용량은 `max_pending ≥ max_connections`로 잡아(app_host_abi.start) **포화가 실질적으로 안 일어나게**
/// 한다(각 연결 스레드는 push→waitResolved 블로킹→메인 pop 후에야 다음 push라, len이 max_connections를 못 넘는다). 즉
/// `not_full` backpressure 대기는 정상 사이징에선 도달 안 하는 안전망이다(오사이징 방어; 18차 [8]). `PtyEventQueue`(docs/
/// io-render-threading.md)의 검증된 bounded-FIFO + Io.Mutex/Condition +
/// close-cancel 패턴을 그대로 재사용한다. `PtyEventQueue`를 generic
/// `BoundedQueue(T)`로 일반화해 이 큐와 통합하는 것은 tracked follow-up이다(범위 밖 — docs/verification-matrix.md).
pub const ControlRequestQueue = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    items: []?*PendingRequest,
    head: usize = 0,
    len: usize = 0,
    closed: bool = false,
    mutex: std.Io.Mutex = .init,
    not_empty: std.Io.Condition = .init,
    not_full: std.Io.Condition = .init,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, max_pending: usize) QueueError!ControlRequestQueue {
        if (max_pending == 0) return error.ZeroCapacity;
        return .{ .io = io, .allocator = allocator, .items = try allocator.alloc(?*PendingRequest, max_pending) };
    }

    pub fn deinit(self: *ControlRequestQueue) void {
        self.close();
        self.allocator.free(self.items);
        self.* = undefined;
    }

    /// 연결 스레드(5f-0b-2a): 포화면 backpressure 대기(§8.8: **core_mutex 미보유** 상태라 blocking push 안전 — 연결
    /// 스레드는 어떤 락도 안 쥔다). 여러 연결 스레드가 동시에 push할 수 있다(MPSC — mutex가 직렬화). closed면
    /// QueueClosed(호출자가 요청을 abandon).
    pub fn push(self: *ControlRequestQueue, pending: *PendingRequest) QueueError!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (!self.closed and self.len == self.items.len) self.not_full.waitUncancelable(self.io, &self.mutex);
        if (self.closed) return error.QueueClosed;
        const tail = (self.head + self.len) % self.items.len;
        self.items[tail] = pending;
        self.len += 1;
        self.not_empty.signal(self.io);
    }

    /// 메인 drain: 대기 요청 하나를 꺼낸다(비차단). 없으면 null.
    pub fn tryPop(self: *ControlRequestQueue) ?*PendingRequest {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.len == 0) return null;
        const item = self.items[self.head].?;
        self.head = (self.head + 1) % self.items.len;
        self.len -= 1;
        self.not_full.signal(self.io);
        return item;
    }

    /// 값싼 pending 유무 확인(짧은 락, #4). len>0이면 true. 메인이 매 tick refs 배열을 짓기 **전에** 이걸 봐 pending이
    /// 없으면 early return(렌더 핫패스 0-할당). drain 자체가 여전히 권위 있는 소비 지점이라, 확인 직후 pending이 도착해도
    /// 다음 tick에서 처리된다(연결 스레드는 그동안 waitResolved에서 대기 — 손실 없음).
    pub fn hasPending(self: *ControlRequestQueue) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.len > 0;
    }

    /// 종료: 새 push를 막고, **큐에 남은 pending을 전부 cancel**해 대기 중 연결 스레드를 깨운다. lock 순서는
    /// queue.mutex → pending.mutex 단방향(pending.mutex를 쥔 채 queue.mutex를 잡는 경로는 없다 — 데드락 없음).
    pub fn close(self: *ControlRequestQueue) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.closed = true;
        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            const slot = (self.head + i) % self.items.len;
            self.items[slot].?.cancel();
        }
        self.len = 0;
        self.head = 0;
        self.not_empty.broadcast(self.io);
        self.not_full.broadcast(self.io);
    }
};

/// 5f-0b-2b-2: 연결당 **스레드-안전 outbound 채널**(응답 + 이벤트 통합, §9.5.1). 순수 `OutboundQueue`(5f-0b-1 —
/// coalesce/purge/bounded mechanism)를 `Io.Mutex` + `not_empty` condition + `closed` 플래그로 감싼다. **메인**이 응답/
/// 이벤트를 `push`(coalesce)·`purge`(revoke)하고, 연결의 **writer 스레드**가 `popWait`로 블록-대기하며 프레임을 꺼내
/// 소켓에 write한다(β 배선). `close`가 대기 writer를 깨워 종료시킨다.
///
/// **설계(§9.5.1 realization)**: 초판 §9.5.1은 "연결 스레드 1개 + poll([socket, wakeup self-pipe])"을 스케치했으나,
/// 구현은 **reader+writer 2-스레드**로 realize한다 — writer가 이 채널의 condition에 블록-대기(popWait)해 socket-read와
/// outbound-write를 각 스레드가 나눠 맡는다. self-pipe/poll fd 저글링보다 **검증된 `ControlRequestQueue`의 Io.Mutex/
/// Condition/close-cancel 패턴을 outbound 방향으로 재사용**하는 게 안전하다(2b-2-β가 두 스레드를 배선; α는 이 primitive만).
/// 순수 `OutboundQueue`가 mechanism(coalesce/purge/bounded)을, wrapper가 스레드 안전·블로킹 수명을 소유한다.
/// 아래 process budget은 여러 wrapper의 admission을 한 hard cap 아래 직렬화한다.
pub const ProcessOutboundBudget = struct {
    pub const default_max_wire_bytes: usize = 32 * 1024 * 1024;
    pub const default_terminal_reserve_bytes: usize = 1024 * 1024;

    io: std.Io,
    max_wire_bytes: usize,
    terminal_reserve_bytes: usize,
    used_wire_bytes: usize = 0,
    terminal_wire_bytes: usize = 0,
    mutex: std.Io.Mutex = .init,

    pub fn init(io: std.Io, max_wire_bytes: usize, terminal_reserve_bytes: usize) ProcessOutboundBudget {
        std.debug.assert(terminal_reserve_bytes <= max_wire_bytes);
        return .{ .io = io, .max_wire_bytes = max_wire_bytes, .terminal_reserve_bytes = terminal_reserve_bytes };
    }

    fn replace(self: *ProcessOutboundBudget, old: co.QueueAccounting, new: co.QueueAccounting) error{Full}!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const base_total = self.used_wire_bytes - old.total_bytes;
        const base_terminal = self.terminal_wire_bytes - old.terminal_bytes;
        if (new.total_bytes > self.max_wire_bytes -| base_total) return error.Full;
        if (new.terminal_bytes > self.terminal_reserve_bytes -| base_terminal) return error.Full;
        const base_general = base_total - base_terminal;
        const max_general = self.max_wire_bytes - self.terminal_reserve_bytes;
        if (new.generalBytes() > max_general -| base_general) return error.Full;
        self.used_wire_bytes = base_total + new.total_bytes;
        self.terminal_wire_bytes = base_terminal + new.terminal_bytes;
    }

    fn release(self: *ProcessOutboundBudget, accounting: co.QueueAccounting) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        std.debug.assert(accounting.total_bytes <= self.used_wire_bytes);
        std.debug.assert(accounting.terminal_bytes <= self.terminal_wire_bytes);
        self.used_wire_bytes -= accounting.total_bytes;
        self.terminal_wire_bytes -= accounting.terminal_bytes;
    }

    pub fn snapshot(self: *ProcessOutboundBudget) co.QueueAccounting {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return .{ .total_bytes = self.used_wire_bytes, .terminal_bytes = self.terminal_wire_bytes };
    }
};

pub const PurgeResult = struct {
    queued_frames: usize,
    writer_owned: bool,
};

/// 한 연결의 queue와 writer-owned frame을 같은 byte-accounting 수명으로 묶는 thread-safe wrapper.
pub const OutboundChannel = struct {
    pub const default_max_wire_bytes: usize = 4 * 1024 * 1024;
    pub const terminal_reserve_bytes: usize = 64 * 1024;
    pub const terminal_reserve_frames: usize = 2;
    io: std.Io,
    q: co.OutboundQueue,
    mutex: std.Io.Mutex = .init,
    not_empty: std.Io.Condition = .init,
    closed: bool = false,
    aborted: bool = false,
    writer_owned: ?WriterOwned = null,
    max_wire_bytes: usize,
    terminal_wire_reserve: usize = 0,
    terminal_frame_reserve: usize = 0,
    process_budget: ?*ProcessOutboundBudget = null,

    const WriterOwned = struct {
        wire_bytes: usize,
        purge_key: co.PurgeKey,
        class: co.FrameClass,
    };

    pub fn init(io: std.Io, max: usize) OutboundChannel {
        return .{ .io = io, .q = co.OutboundQueue.init(max), .max_wire_bytes = std.math.maxInt(usize) };
    }

    pub fn initWithByteLimit(io: std.Io, max: usize, max_wire_bytes: usize) OutboundChannel {
        return .{ .io = io, .q = co.OutboundQueue.initWithByteLimit(max, max_wire_bytes), .max_wire_bytes = max_wire_bytes };
    }

    pub fn initWithProcessBudget(io: std.Io, max: usize, process_budget: *ProcessOutboundBudget) OutboundChannel {
        return initWithLimits(io, max, default_max_wire_bytes, terminal_reserve_bytes, terminal_reserve_frames, process_budget);
    }

    fn initWithLimits(
        io: std.Io,
        max: usize,
        max_wire_bytes: usize,
        terminal_wire_reserve: usize,
        terminal_frame_reserve: usize,
        process_budget: *ProcessOutboundBudget,
    ) OutboundChannel {
        std.debug.assert(terminal_wire_reserve <= max_wire_bytes);
        std.debug.assert(terminal_frame_reserve <= max);
        return .{
            .io = io,
            .q = co.OutboundQueue.init(max),
            .max_wire_bytes = max_wire_bytes,
            .terminal_wire_reserve = terminal_wire_reserve,
            .terminal_frame_reserve = terminal_frame_reserve,
            .process_budget = process_budget,
        };
    }

    pub fn deinit(self: *OutboundChannel, gpa: std.mem.Allocator) void {
        std.debug.assert(self.writer_owned == null);
        if (self.process_budget) |budget| budget.release(self.q.accounting());
        self.q.deinit(gpa); // 남은 프레임 bytes free
        self.* = undefined;
    }

    /// 메인: 프레임 push(coalesce). `closed`면 QueueClosed(호출처가 frame.bytes free). `Full`이면 error(호출처 정책:
    /// 응답=연결 종료·이벤트=drop/subscriber-lagged, §9.5.6). 성공 시 대기 writer를 깨운다.
    pub fn push(self: *OutboundChannel, gpa: std.mem.Allocator, frame: co.Frame) error{ Full, InvalidFrame, OutOfMemory, QueueClosed }!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return error.QueueClosed;
        // Queue가 거부할 deterministic validation은 global reservation을 바꾸기 전에 끝낸다. 특히 더 작은 invalid
        // coalesce replacement로 budget을 잠깐 풀었다 rollback하면 다른 연결 push와 경합해 복원이 실패할 수 있다.
        if (frame.class == .terminal and frame.coalesce_key != null) return error.InvalidFrame;
        const old = self.accountingLocked();
        const queued_new = self.q.prospectiveAccounting(frame);
        var new = queued_new;
        if (self.writer_owned) |owned| addWriterOwned(&new, owned);
        if (!fitsConnection(self.q.max, self.max_wire_bytes, self.terminal_wire_reserve, self.terminal_frame_reserve, new)) return error.Full;
        if (self.process_budget) |budget| try budget.replace(old, new);
        self.q.push(gpa, frame) catch |err| {
            if (self.process_budget) |budget| budget.replace(new, old) catch unreachable;
            return err;
        };
        self.not_empty.signal(self.io);
    }

    /// 메인: revoke/surface-close 시 tag 매칭 프레임 폐기(§8.5). 폐기 개수 반환.
    pub fn purge(self: *OutboundChannel, gpa: std.mem.Allocator, key: co.PurgeKey) usize {
        return self.purgeDetailed(gpa, key).queued_frames;
    }

    pub fn purgeDetailed(self: *OutboundChannel, gpa: std.mem.Allocator, key: co.PurgeKey) PurgeResult {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const before = self.accountingLocked();
        const removed = self.q.purge(gpa, key);
        const after = self.accountingLocked();
        if (self.process_budget) |budget| budget.replace(before, after) catch unreachable;
        return .{
            .queued_frames = removed,
            .writer_owned = if (self.writer_owned) |owned| owned.purge_key.eql(key) else false,
        };
    }

    /// writer 스레드: 프레임이 있으면 pop, 없으면 `not_empty` 대기. **closed + 빈** 이면 null(writer 종료 신호). 반환
    /// Frame.bytes 소유권=writer(socket write 후 free). closed여도 남은 프레임은 다 drain한 뒤 null(응답 유실 방지).
    pub fn popWait(self: *OutboundChannel) ?co.Frame {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (self.q.len() == 0 and !self.closed) self.not_empty.waitUncancelable(self.io, &self.mutex);
        if (self.q.len() == 0) return null; // closed + 빈 → 종료
        const frame = self.q.pop().?;
        std.debug.assert(self.writer_owned == null);
        self.writer_owned = .{ .wire_bytes = co.wireBytes(frame.bytes), .purge_key = frame.purge_key, .class = frame.class };
        return frame;
    }

    pub fn writeComplete(self: *OutboundChannel, frame_bytes: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const owned = self.writer_owned orelse unreachable;
        std.debug.assert(owned.wire_bytes == co.wireBytes(frame_bytes));
        const before = self.accountingLocked();
        self.writer_owned = null;
        const after = self.accountingLocked();
        if (self.process_budget) |budget| budget.replace(before, after) catch unreachable;
    }

    pub fn totalWireBytes(self: *OutboundChannel) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.accountingLocked().total_bytes;
    }

    pub fn isClosed(self: *OutboundChannel) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.closed;
    }

    /// 메인: 채널 종료 — 대기 writer를 깨워(broadcast) 남은 프레임 drain 후 종료(null)하게 한다.
    pub fn close(self: *OutboundChannel) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.closed = true;
        self.not_empty.broadcast(self.io);
    }

    /// graceful close와 달리 queued frame을 즉시 폐기한다. writer-owned는 writer defer가 반환하므로 여기서
    /// 해제하지 않는다. caller가 이어서 socket shutdown을 호출해 partial write를 끝낸다.
    pub fn abort(self: *OutboundChannel, gpa: std.mem.Allocator) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.aborted) return;
        const before = self.accountingLocked();
        self.aborted = true;
        self.closed = true;
        _ = self.q.purgeAll(gpa);
        const after = self.accountingLocked();
        if (self.process_budget) |budget| budget.replace(before, after) catch unreachable;
        self.not_empty.broadcast(self.io);
    }

    /// 메인: push 전 정책 판단용(§9.5.6 — 응답 push 전 Full 임박이면 연결 종료 선제).
    pub fn isFull(self: *OutboundChannel) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.q.isFull();
    }

    pub fn shouldPause(self: *OutboundChannel) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const local = self.accountingLocked();
        const local_general_bytes = self.max_wire_bytes - self.terminal_wire_reserve;
        const local_general_frames = self.q.max - self.terminal_frame_reserve;
        if (local.generalBytes() >= local_general_bytes - local_general_bytes / 4) return true;
        if (local.generalFrames() >= local_general_frames) return true;
        if (self.process_budget) |budget| {
            const global = budget.snapshot();
            const global_general_bytes = budget.max_wire_bytes - budget.terminal_reserve_bytes;
            return global.generalBytes() >= global_general_bytes - global_general_bytes / 4;
        }
        return false;
    }

    pub fn shouldResume(self: *OutboundChannel) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const local = self.accountingLocked();
        const local_general_bytes = self.max_wire_bytes - self.terminal_wire_reserve;
        const local_general_frames = self.q.max - self.terminal_frame_reserve;
        if (local.generalBytes() > local_general_bytes / 2 or local.generalFrames() > local_general_frames / 2) return false;
        if (self.process_budget) |budget| {
            const global = budget.snapshot();
            const global_general_bytes = budget.max_wire_bytes - budget.terminal_reserve_bytes;
            return global.generalBytes() <= global_general_bytes / 2;
        }
        return true;
    }

    fn accountingLocked(self: *OutboundChannel) co.QueueAccounting {
        var result = self.q.accounting();
        if (self.writer_owned) |owned| addWriterOwned(&result, owned);
        return result;
    }

    fn addWriterOwned(accounting: *co.QueueAccounting, owned: WriterOwned) void {
        accounting.total_bytes += owned.wire_bytes;
        accounting.total_frames += 1;
        if (owned.class == .terminal) {
            accounting.terminal_bytes += owned.wire_bytes;
            accounting.terminal_frames += 1;
        }
    }

    fn fitsConnection(max_frames: usize, max_wire_bytes: usize, terminal_bytes: usize, terminal_frames: usize, accounting: co.QueueAccounting) bool {
        if (accounting.total_frames > max_frames) return false;
        if (accounting.total_bytes > max_wire_bytes) return false;
        if (accounting.terminal_bytes > terminal_bytes) return false;
        if (accounting.terminal_frames > terminal_frames) return false;
        if (accounting.generalFrames() > max_frames -| terminal_frames) return false;
        return accounting.generalBytes() <= max_wire_bytes - terminal_bytes;
    }
};

/// 한 (surface,kind) 이벤트가 fan-out될 수 있는 구독자 수 상한(pushEvent의 comptime 매칭 버퍼). 각 연결=구독자 1이고 한
/// surface를 구독하는 연결 ≤ 동시 연결(=max_connections=max_pending)이라 실질 상한은 max_pending이다. **start()가
/// `max_pending <= max_event_fanout`를 assert**(20차 [5])해 이 결합을 명시 — 그 불변식 하에 matching truncate(구독자 이벤트
/// 유실)가 구조적으로 불가하다(라이브 max_pending=16 << 64). max_pending을 64 초과로 늘리려면 이 상수도 함께 키운다.
const max_event_fanout: usize = 64;

/// 5f-0b-3 구독 레지스트리(§9.5.2). L2 순수 `EventBroker`(구독 (subscriber_id, surface, filter)·매칭·수명)에, L4 전용인
/// **`subscriber_id → *OutboundChannel` 매핑**과 id 발급기를 더해 "이벤트를 매칭 구독자의 연결 outbound로 push"·"연결 drop/
/// surface close 시 정리"를 소유한다. **leaf-mutex 보호**(§9.5.6 realization pivot — 전제(v)의 "메인 전용·락 없음"을
/// leaf-mutex로 realize): 초판은 메인 전용 + 연결-drop 통지였으나, 연결 churn 시 outbound 무한 누적(same-uid DoS)/stop 교착
/// 위험이라, **메인(pushEvent/subscribe)과 연결 스레드(종료 시 self-`purgeOutbound`)가 이 leaf lock서 직렬화**한다.
/// UAF 없음: purge와 pushEvent가 같은 락서 배타 → purge 후 메인은 그 outbound를 다시 조회 못 하고(제거됨), free는 purge 후.
/// **§8.8 준수**: 이 락=leaf(core_mutex 보유 중 미접근 — 이벤트=KVO·구독=요청 dispatch 둘 다 core_mutex 밖), lock 순서
/// registry→outbound 단방향(pushEvent만 nested; writer/reader는 outbound만 잡음). 구조체 alloc(broker.subs·맵)은 소유
/// `gpa`, 이벤트 프레임 **바이트**는 writer 스레드가 free하므로 `pushEvent`가 별도 `cross_gpa`로 만든다(소유권 교차).
pub const SubscriberRegistry = struct {
    io: std.Io,
    /// leaf lock — 메인 pushEvent/subscribe/purgeSurface ∥ 연결 스레드 purgeOutbound를 직렬화(§9.5.6 realization).
    mutex: std.Io.Mutex = .init,
    /// broker.subs + outbound_of 맵 alloc(소유 — items_gpa 결). 이벤트 프레임 바이트는 이게 아니라 pushEvent의 cross_gpa.
    gpa: std.mem.Allocator,
    broker: cev.EventBroker = .{},
    /// 각 연결(=구독자)의 outbound. subscribe가 outbound당 subscriber_id를 **1:1**로 잡아(재구독=id 재사용) 넣고, drop이 뺀다.
    outbound_of: std.AutoHashMapUnmanaged(cev.SubscriberId, *OutboundChannel) = .empty,
    id_alloc: cev.SubscriberIdAllocator = .{},

    pub fn init(io: std.Io, gpa: std.mem.Allocator) SubscriberRegistry {
        return .{ .io = io, .gpa = gpa };
    }

    /// stop 시 호출(모든 연결 스레드 join 후 = 동시 접근 없음)이라 락 없이 해제한다.
    pub fn deinit(self: *SubscriberRegistry) void {
        self.broker.deinit(self.gpa);
        self.outbound_of.deinit(self.gpa);
        self.* = undefined;
    }

    /// 메인(요청 dispatch): `(surface_id, filter)`를 이 연결(`outbound`)로 구독한다. 한 연결은 subscriber_id **하나**를
    /// 재사용하므로(재구독=필터 갱신, broker가 (id,surface)당 1개 유지), 이미 이 outbound에 발급된 id가 있으면 재사용하고
    /// 없으면 새로 발급해 매핑한다. 반환=그 연결의 subscriber_id(5f-0b-3b가 응답에 실어 client가 unsubscribe에 쓴다). OOM만 error.
    pub fn subscribe(self: *SubscriberRegistry, surface_id: u64, filter: cev.EventFilter, outbound: *OutboundChannel) std.mem.Allocator.Error!cev.SubscriberId {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const existing = self.idForOutbound(outbound);
        const id = existing orelse self.id_alloc.next();
        if (existing == null) try self.outbound_of.put(self.gpa, id, outbound);
        errdefer if (existing == null) {
            _ = self.outbound_of.remove(id); // 새 매핑을 넣었는데 broker.subscribe가 OOM이면 dangling 매핑 제거
        };
        try self.broker.subscribe(self.gpa, id, surface_id, filter);
        return id;
    }

    /// 메인(KVO 이벤트): 이벤트를 `(surface_id, kind)`에 매칭하는 구독자들의 연결 outbound에 push한다(§9.5.2 이벤트 흐름).
    /// **매칭 먼저**(락 아래) — 구독자 0이면 직렬화 없이 조기 반환(20차 [4]: KVO 핫패스에서 구독자 없는 흔한 경우 alloc·JSON
    /// 인코딩 회피). 구독자 있으면 바이트를 `cross_gpa`로 **한 번** 직렬화하고 구독자별 **dupe+push**(각 outbound 프레임이 bytes
    /// 소유·writer가 free). coalescible(navigated·loadState)은 `(surface,kind)` coalesce_key로 같은 큐서 최신이 옛것 대체
    /// (백프레셔), 이산(dialog)은 key 없음. tag=surface_id(§8.5 surface-close/revoke purge 대상). 개별 push 실패(Full=느린
    /// 구독자 drop·QueueClosed=닫히는 연결)는 그 구독자만 건너뛴다. 반환=실제 push 성공 수. 직렬화는 락 아래이나 구독자 있을
    /// 때만이라 흔한 무구독 경우엔 락+matching만(짧음).
    pub fn pushEvent(self: *SubscriberRegistry, cross_gpa: std.mem.Allocator, surface_id: u64, event: cev.Event) usize {
        const kind = std.meta.activeTag(event);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var buf: [max_event_fanout]cev.SubscriberId = undefined;
        const n = self.broker.matching(surface_id, kind, &buf);
        if (n == 0) return 0; // 구독자 없음 → 직렬화 없이 조기 반환(핫패스 alloc 회피, 20차 [4])
        std.debug.assert(n <= max_event_fanout); // n은 matching이 out.len(=max_event_fanout)까지만 채움. 정확 상한=max_pending(≤
        // max_event_fanout, start assert)이라 truncate 없음. 21차 [0]: max_pending=64서 n==64가 정상이라 `<`가 아니라 `<=`(경계 오abort 방지).
        const coalesce_key: ?u64 = if (kind.isCoalescible()) coalesceKey(surface_id, kind) else null;
        const template = cev.serializeEvent(cross_gpa, surface_id, event) catch return 0; // OOM=아무도 못 받음
        defer cross_gpa.free(template);
        var pushed: usize = 0;
        for (buf[0..n]) |id| {
            const ch = self.outbound_of.get(id) orelse continue; // 매핑 없는 id(구조적 불가)면 skip
            const bytes = cross_gpa.dupe(u8, template) catch continue; // 구독자별 소유 복사(OOM=이 구독자만 skip)
            ch.push(cross_gpa, .{ .bytes = bytes, .coalesce_key = coalesce_key, .purge_key = .{ .surface_event = surface_id } }) catch {
                cross_gpa.free(bytes); // Full(느린 구독자)·QueueClosed(닫히는 연결) → 소유권 반환·해제 후 skip
                continue;
            };
            pushed += 1;
        }
        return pushed;
    }

    /// **연결 스레드**(종료): 이 `outbound`에 묶인 구독자의 **모든** 구독을 broker·매핑에서 제거한다(§9.5.6). 반환=제거된
    /// (surface별) 구독 수. 연결 스레드가 **outbound free 전에** leaf lock 아래 호출 → 메인 pushEvent와 배타라 dangling·UAF
    /// 없음(purge 후 메인은 이 outbound를 못 찾음). 구독 없는 연결이면 no-op(0).
    pub fn purgeOutbound(self: *SubscriberRegistry, outbound: *OutboundChannel) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const id = self.idForOutbound(outbound) orelse return 0;
        const removed = self.broker.removeSubscriber(id);
        _ = self.outbound_of.remove(id);
        return removed;
    }

    /// 메인: surface close(§9.5.2 수명) — 그 surface의 모든 구독 제거 **+ 각 연결 outbound 큐의 그 surface 잔여 이벤트 프레임
    /// purge**(20차 [3] — §9.5.2/§8.5 규범: revoke 후 이미 enqueue된 프레임이 계속 나가면 죽은 surface 이벤트를 client가 받음).
    /// 이벤트 프레임 tag=surface_id라 `outbound.purge(cross_gpa, surface_id)`로 폐기(응답=tag 0 보호). 반환=제거 구독 수.
    /// (browser.closed 브로드캐스트 후 호출은 5f-0b-3c; outbound_of 매핑은 연결이 살아 있으면 유지 = 다른 surface 구독 무영향.)
    pub fn purgeSurface(self: *SubscriberRegistry, cross_gpa: std.mem.Allocator, surface_id: u64) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var it = self.outbound_of.iterator();
        while (it.next()) |e| _ = e.value_ptr.*.purge(cross_gpa, .{ .surface_event = surface_id }); // 그 surface 잔여 이벤트 프레임 폐기
        return self.broker.removeSurface(surface_id);
    }

    /// 5f-3d **surface close**: `browser.closed`를 그 surface의 **모든 구독자**(필터 **무관** — closed는 구독 종료 마커라
    /// opt-out 불가; 21차 [0]/[3])에게 push한 **뒤** broker 구독을 제거한다(원자 — 락 아래 push+remove). closed 프레임은
    /// 큐에 남아 writer가 배달하고, remove는 큐를 안 건드린다(cap revoke의 `purgeSurface`[프레임 폐기]와 구분). 개별 push가
    /// **Full**(느린 구독자)/QueueClosed면 그 구독자 outbound를 `close`해 연결을 teardown한다(21차 [5]: 종료 마커를 silent
    /// drop하면 구독자가 죽은 surface를 영영 살아있다 여김 → §9.5.2 subscriber-lagged=강제 해제, client는 EOF로 종료 인지).
    /// 반환=closed push 성공 수. **메인 스레드 전용**.
    pub fn pushSurfaceClosed(self: *SubscriberRegistry, cross_gpa: std.mem.Allocator, surface_id: u64) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var buf: [max_event_fanout]cev.SubscriberId = undefined;
        const n = self.broker.matchingSurfaceAny(surface_id, &buf); // 필터 무관 전체 구독자
        var pushed: usize = 0;
        if (n > 0) {
            const template = cev.serializeEvent(cross_gpa, surface_id, .closed) catch {
                _ = self.broker.removeSurface(surface_id); // 직렬화 OOM이어도 구독은 정리(dangling 방지)
                return 0;
            };
            defer cross_gpa.free(template);
            for (buf[0..n]) |id| {
                const ch = self.outbound_of.get(id) orelse continue;
                const bytes = cross_gpa.dupe(u8, template) catch continue; // 이 구독자만 skip(OOM)
                ch.push(cross_gpa, .{ .bytes = bytes, .coalesce_key = null, .purge_key = .{ .surface_event = surface_id } }) catch {
                    cross_gpa.free(bytes);
                    ch.close(); // Full/QueueClosed → 종료 마커 못 줌 → outbound close(subscriber-lagged teardown, client EOF)
                    continue;
                };
                pushed += 1;
            }
        }
        _ = self.broker.removeSurface(surface_id); // 구독 제거(closed 프레임은 큐에 남아 배달 — purge 안 함)
        return pushed;
    }

    /// 비-locking 내부 헬퍼(호출처가 이미 mutex 보유) + 헤드리스 단위 테스트(단일 스레드)용. 라이브 경로는 절대 락 없이 안 부른다.
    /// subscribe·purgeOutbound가 outbound→id 역참조에 쓴다. O(연결수) 선형 스캔이나 **유계 연결 상한(≤max_pending=16)에서
    /// 무시 가능**이라 유지한다(20차 [6] 검토): O(1) 대안(OutboundChannel에 subscriber_id 필드 저장)은 generic outbound
    /// primitive를 이벤트 개념에 결합시키고, 별도 역맵은 상태 이중화라 이 규모에선 정당화되지 않는다.
    fn idForOutbound(self: *SubscriberRegistry, outbound: *OutboundChannel) ?cev.SubscriberId {
        var it = self.outbound_of.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.* == outbound) return e.key_ptr.*;
        }
        return null;
    }

    /// coalescible 이벤트의 큐 coalesce_key: 같은 (surface,kind)면 같은 값(최신이 옛것 대체), 다르면 다른 값. surface_id는
    /// 앱-전역 순차 소형 정수라 3비트 kind와 겹쳐도 충돌 없다(surface_id ≥ 2^61이면 이론상 충돌이나 도달 불가).
    fn coalesceKey(surface_id: u64, kind: cev.EventKind) u64 {
        return (surface_id << 3) | @intFromEnum(kind);
    }
};

pub const StartError = cs.BindError || std.Thread.SpawnError || QueueError;

/// Swift callback id는 서버 stop/start를 넘어 재사용하지 않는다. 예전 WebKit callback이 재시작한 서버의 새 요청을
/// 완료하는 ABA를 막기 위한 process-lifetime 원자 발급기다(0은 sentinel이라 건너뜀).
var process_next_async_id: std.atomic.Value(u64) = .init(1);
var process_next_connection_id: std.atomic.Value(u64) = .init(1);

fn nextAsyncId() u64 {
    while (true) {
        const id = process_next_async_id.fetchAdd(1, .monotonic);
        if (id != 0) return id;
    }
}

fn nextConnectionId() u64 {
    while (true) {
        const id = process_next_connection_id.fetchAdd(1, .monotonic);
        if (id != 0) return id;
    }
}

/// §5-async: async 응답을 나중에 되돌릴 **in-flight 요청** 하나(deferred marshal). 메인 drain이 즉시 resolve 대신
/// `deferRequest`로 등록하면, 나중에 `completeInFlight`(콜백)이 resolve한다. `pending`은 연결 스레드 serve 스택에
/// 살며(waitResolved 대기 중) resolve/cancel까지 유효하다.
pub const InFlight = struct {
    /// 이 async 요청의 상관 id(서버 발급, monotonic). Swift 콜백이 이 id로 complete한다.
    id: u64,
    /// 붙잡은 pending(연결 스레드 소유, resolve/cancel 대상).
    pending: *PendingRequest,
    /// 모노토닉 awake ns 마감 — `reapExpiredInFlight`가 지나면 timeout으로 resolve(hung async op 방어).
    deadline_ns: i128,
};

/// A2b 라이브 서버. **start() 후 절대 이동/복사 금지**(accept·연결 스레드가 `&self`를 잡는다 — LivePtySession 핀 선례).
/// caller가 global static 또는 heap로 주소를 고정한다.
pub const ControlServer = struct {
    io: std.Io,
    /// cross-thread(요청/응답) 전용 thread-safe allocator(제품 = c_allocator).
    cross_gpa: std.mem.Allocator,
    server: cs.Server,
    queue: ControlRequestQueue,
    hello_version: []const u8,
    hello_caps: []const []const u8,
    thread: ?std.Thread = null,
    closing: std.atomic.Value(bool) = .init(false),
    /// reader 스레드가 stuck client에 무한 대기하지 않게 하는 read 타임아웃(2b-1 지속 세션 요청 루프의 inter-request read +
    /// stop() 시 readInto 블로킹의 ≤5s 깨끗한 join). 2b-2는 §9.5.6④의 poll-루프 전환을 채택하지 않고 **blocking read +
    /// SO_RCVTIMEO를 유지**했다(reader+writer 2-스레드 realization, §9.5.6 realization note (b) — 이벤트는 writer로 독립해 흐름).
    read_timeout_ms: u32 = 5000,
    /// accept blocking을 gate하는 poll 간격(종료 시 이 간격 안에 closing 확인 → join). 짧을수록 종료 빠름·wakeup 잦음.
    poll_interval_ms: i32 = 200,
    // ── §5-async: deferred marshal(in-flight 레지스트리 — **메인 스레드 전용**, 락 없음: deferRequest·completeInFlight·
    //    reapExpiredInFlight·stop이 전부 메인. pending.resolve/cancel만 cross-thread지만 그건 이미 thread-safe) ──
    /// in-flight async 요청 목록(items_gpa 소유). 5f-0b-2a 연결당 스레드로 여러 연결이 동시에 browser op을 defer할 수
    /// 있어(최대 max_in_flight) bounded가 이제 실질적으로 쓰인다(초과=TooManyInFlight). **메인 전용**(아래 주석).
    in_flight: std.ArrayList(InFlight) = .empty,
    /// items/socket alloc(in_flight 리스트도 이걸로 — start가 채운다).
    items_gpa: std.mem.Allocator = undefined,
    /// 동시 in-flight 상한(§11 안정성 게이트 — bounded). 초과 defer는 TooManyInFlight(호출자가 에러 resolve).
    max_in_flight: usize = 8,
    // ── 5f-0b-2a: 연결당 스레드 wait-group(§9.5.1 — head-of-line 블로킹 폐기). accept 루프가 연결마다 detached 스레드를
    //    spawn하고, 이 카운터로 stop()이 self.*=undefined 전에 전부 끝날 때까지 대기한다(use-after-free 방지). handle을
    //    저장·join하는 대신 카운터+condition = 무제한 handle 누적 없이 "전부 종료" 대기. accept 스레드(self.thread)와 별개. ──
    conns_mutex: std.Io.Mutex = .init,
    conns_done: std.Io.Condition = .init,
    /// 현재 살아있는 연결 스레드 수(conns_mutex 아래). acceptOne 성공→spawn 전 +1, connThread 종료 시 -1+broadcast.
    active_conns: usize = 0,
    /// 동시 연결 상한(bounded — 스레드 폭주 방어). 초과 연결은 accept 후 즉시 close(reject). **start()가 `max_pending`과
    /// 동일하게 파생**(19차 [1][2][3][4]): 직렬 reader라 각 연결이 marshal 큐에 항목 ≤1개(push→waitResolved→pop 후에야
    /// 다음 push)를 넣으므로, 동시 연결 = 큐 최대 점유다. 따라서 `max_connections == max_pending`이 tight·park-free 사이징
    /// (초과 push backpressure park가 구조적으로 불가 — 옛 debug-assert 방어가 불필요해짐). 기본값은 start 전 잠깐만 유효.
    max_connections: usize = 0,
    /// 5f-0b-2b-2: 연결당 outbound 큐(응답+이벤트) 용량. 직렬 reader라 응답은 depth ~1이고, 실 소비자는 5f-0b-3 이벤트
    /// 버스트다(초과 push=Full → 이벤트 drop=subscriber-lagged, §9.5.6; 응답은 Full이면 연결 abandon). 64면 여유.
    outbound_capacity: usize = 64,
    /// activation 뒤 모든 연결이 공유할 wire-byte 상한. 채널 락→이 budget 락 순서만 허용하며 역방향 호출은 없다.
    process_outbound_budget: ProcessOutboundBudget = undefined,
    /// 5f-0b-3a-2: browser 이벤트 구독 레지스트리(leaf-mutex). 메인(pushEvent — 5f-0b-3c KVO 주입·subscribe — 5f-0b-3b
    /// dispatch)과 연결 스레드(종료 시 self-`purgeOutbound`)가 공유한다. start가 init, connThread가 종료 시 purge, stop이 deinit.
    subscriber_reg: SubscriberRegistry = undefined,

    /// 소켓을 bind하고 accept 스레드를 띄운다. **self는 이미 최종 주소에 있어야 한다.** bind 실패면 스레드 없이 에러.
    pub fn start(
        self: *ControlServer,
        io: std.Io,
        cross_gpa: std.mem.Allocator,
        items_gpa: std.mem.Allocator,
        base_dir: []const u8,
        key: []const u8,
        hello_version: []const u8,
        hello_caps: []const []const u8,
        max_pending: usize,
    ) StartError!void {
        const server = try cs.Server.bind(items_gpa, base_dir, key);
        errdefer {
            var s = server;
            s.deinit();
        }
        const queue = try ControlRequestQueue.init(io, items_gpa, max_pending);
        self.* = .{
            .io = io,
            .cross_gpa = cross_gpa,
            .server = server,
            .queue = queue,
            .hello_version = hello_version,
            .hello_caps = hello_caps,
            .items_gpa = items_gpa, // §5-async in_flight 리스트 alloc
            // 19차 [1][2][3][4]: 동시 연결 상한을 큐 용량과 동일하게 파생한다(직렬 reader라 연결당 큐 항목 ≤1 → tight·
            // park-free, 위 필드 주석). 이 초기화가 유일한 max_connections 설정 지점 — start 후 필드 변경 금지(acceptLoop가
            // conns_mutex 아래 읽으므로 무동기 변경은 데이터 레이스). 라이브=16(app_host_abi max_pending), 테스트=각자 max_pending.
            .max_connections = max_pending,
            .process_outbound_budget = ProcessOutboundBudget.init(
                io,
                ProcessOutboundBudget.default_max_wire_bytes,
                ProcessOutboundBudget.default_terminal_reserve_bytes,
            ),
            // 5f-0b-3a-2: 이벤트 구독 레지스트리(leaf-mutex). 구조체 alloc은 items_gpa(메인 소유), 이벤트 바이트는 pushEvent가 cross_gpa로.
            .subscriber_reg = SubscriberRegistry.init(io, items_gpa),
        };
        // 20차 [5]: pushEvent의 fan-out 버퍼(max_event_fanout)는 comptime 크기라, 한 surface 구독자(≤max_connections=max_pending)가
        // 그 버퍼를 못 넘어야 matching truncate(구독자 이벤트 유실)가 없다. 이 assert가 그 결합을 명시(라이브 max_pending=16 << 64).
        std.debug.assert(max_pending <= max_event_fanout);
        errdefer self.queue.deinit();
        self.thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
    }

    /// 메인 drain: 대기 요청 하나를 꺼낸다(없으면 null). caller(app_host_abi)가 실 collector+auth+dispatch로 응답을
    /// 만든 뒤 `resolveRequest`로 채운다. per-tick 처리량은 caller가 제한한다(§5 per-tick 예산).
    pub fn tryPopRequest(self: *ControlServer) ?*PendingRequest {
        return self.queue.tryPop();
    }

    /// 메인 drain 게이트(#4): 대기 요청이 하나라도 있으면 true(값싼 짧은 락). caller(app_host_abi/Swift)가 refs 배열
    /// 힙 할당·창별 copy 전에 이걸 봐 pending이 없으면 즉시 반환한다(렌더 핫패스 0-할당).
    pub fn hasPendingRequest(self: *ControlServer) bool {
        return self.queue.hasPending();
    }

    /// 메인 drain: 응답 바이트(`cross_gpa` 소유 — dispatchReadOnly에 `self.cross_gpa`를 넘겨 만든 것)를 pending에
    /// 채우고 연결 스레드를 깨운다. 연결 스레드가 소켓에 write 후 해제한다. response=null이면 응답 없이 종료
    /// (메인 OOM 등 — pending은 반드시 resolve해야 연결 스레드가 무한 대기하지 않는다).
    pub fn resolveRequest(self: *ControlServer, pending: *PendingRequest, response: ?[]u8) void {
        if (!pending.resolve(response)) if (response) |r| self.cross_gpa.free(r);
    }

    /// **§5-async(메인 전용)**: 응답이 나중에 오는 요청을 in-flight로 등록한다(즉시 resolve 안 함). drain이 async
    /// 메서드(browser.* — 5e)에 대해 `resolveRequest` 대신 이걸 호출해 pending을 붙잡으면, WKWebView 콜백 완료 시
    /// `completeInFlight(반환 id, ...)`이 resolve한다. 연결 스레드는 그동안 waitResolved에서 대기(pending 유효).
    /// bounded — `max_in_flight` 초과면 `TooManyInFlight`(호출자가 에러로 즉시 resolve해야 accept 무한 대기 방지).
    /// `deadline_ns`=모노토닉 awake ns 마감(호출자가 now+timeout 계산). 반환=async 상관 id(>=1). **메인 스레드 전용**.
    pub fn deferRequest(self: *ControlServer, pending: *PendingRequest, deadline_ns: i128) error{ TooManyInFlight, OutOfMemory }!u64 {
        if (self.in_flight.items.len >= self.max_in_flight) return error.TooManyInFlight;
        const id = nextAsyncId();
        try self.in_flight.append(self.items_gpa, .{ .id = id, .pending = pending, .deadline_ns = deadline_ns });
        return id;
    }

    /// **§5-async(메인 전용)**: `async_id`의 in-flight 요청을 `response`(**cross_gpa 소유** 또는 null)로 resolve하고
    /// 레지스트리에서 제거한다. 찾으면 true, 없으면 false. **completeInFlight는 어느 경로든 `response` 소유권을
    /// 인수**한다(대칭 소유 — 리뷰 [1]): 찾으면 `pending.resolve`가 연결 스레드로 넘겨 거기서 free, **못 찾으면**
    /// (옛/이미 완료/reap된 id — 늦은/중복 콜백) 여기서 `cross_gpa.free`한다. 안 그러면 reap된 async op의 결과 버퍼가
    /// 누수한다(hit=이전, miss=drop의 비대칭 함정). Swift async 콜백이 ABI를 거쳐 부른다(메인 스레드).
    pub fn completeInFlight(self: *ControlServer, async_id: u64, response: ?[]u8) bool {
        for (self.in_flight.items, 0..) |e, i| {
            if (e.id == async_id) {
                if (!e.pending.resolve(response)) if (response) |r| self.cross_gpa.free(r);
                _ = self.in_flight.swapRemove(i);
                return true;
            }
        }
        // 미발견: 늦은/중복 콜백이 넘긴 버퍼를 여기서 해제(소유권 인수 — 누수 방지, 리뷰 [1]).
        if (response) |r| self.cross_gpa.free(r);
        return false;
    }

    /// terminal을 caller가 같은 outbound FIFO에 직접 넣은 경우 pending 수명만 끝낸다.
    pub fn completeInFlightEnqueued(self: *ControlServer, async_id: u64) bool {
        for (self.in_flight.items, 0..) |e, i| {
            if (e.id == async_id) {
                if (!e.pending.resolveEnqueued()) return false;
                _ = self.in_flight.swapRemove(i);
                return true;
            }
        }
        return false;
    }

    /// 현재 in-flight가 붙잡은 안정 연결을 abort한다. pending이 resolve되기 전에는 connection stack/fd가
    /// 살아 있으므로 raw 포인터를 tick 사이 저장하지 않고 이 호출 안에서만 사용한다.
    pub fn abortInFlightConnection(self: *ControlServer, async_id: u64) bool {
        const pending = self.inFlightPending(async_id) orelse return false;
        const outbound = pending.outbound orelse return false;
        outbound.abort(self.cross_gpa);
        if (pending.connection_fd >= 0) cs.shutdownBoth(pending.connection_fd);
        return true;
    }

    /// **§5-async/5e-2b(메인 전용)**: `async_id`의 in-flight pending을 **제거 없이** 돌려준다(없으면 null). 5e-2b
    /// complete가 응답 직렬화에 필요한 원 `request_bytes`(pending 소유, resolve 전이라 유효)를 재파싱하려고 조회한다.
    pub fn inFlightPending(self: *ControlServer, async_id: u64) ?*PendingRequest {
        for (self.in_flight.items) |e| {
            if (e.id == async_id) return e.pending;
        }
        return null;
    }

    /// grant prompt에서 실제 browser 실행으로 넘어갈 때 execution timeout을 새로 시작한다.
    pub fn updateInFlightDeadline(self: *ControlServer, async_id: u64, deadline_ns: i128) bool {
        for (self.in_flight.items) |*e| {
            if (e.id == async_id) {
                e.deadline_ns = deadline_ns;
                return true;
            }
        }
        return false;
    }

    /// 아직 제거/resolve하지 않고 만료 id만 관찰한다. L4가 method별 timeout 응답을 만들 기회를 준 뒤 generic reaper를
    /// 호출한다. 반환은 기록한 id 수(out 길이로 bounded).
    pub fn expiredInFlightIds(self: *ControlServer, now_ns: i128, out_ids: []u64) usize {
        var count: usize = 0;
        for (self.in_flight.items) |e| {
            if (e.deadline_ns <= now_ns and count < out_ids.len) {
                out_ids[count] = e.id;
                count += 1;
            }
        }
        return count;
    }

    /// **§5-async(메인 전용)**: `now_ns`(모노토닉 awake) 기준 마감이 지난 in-flight를 timeout으로 정리한다 — 응답 없이
    /// (`resolve(null)`) 연결 스레드를 깨워 연결을 닫게 하고(client read 타임아웃이 받음, OOM 경로와 동형 계약)
    /// 레지스트리에서 제거한다. drain이 매 tick 부른다(hung WKWebView async op가 연결 스레드를 영구 붙잡는 것 방어).
    /// 반환=reap 개수. proper timeout **에러 응답**(요청 id 파싱 + 직렬화)은 후속 — 지금은 null 종료로 단순·일관.
    pub fn reapExpiredInFlight(self: *ControlServer, now_ns: i128) usize {
        return self.reapExpiredInFlightIds(now_ns, &.{});
    }

    /// timeout된 id를 caller-owned 버퍼에 함께 기록한다. caller는 queued/running backend 수명을 id로 reconcile한다.
    /// 반환은 실제 reap 수이며 out이 작으면 앞부분만 기록된다.
    pub fn reapExpiredInFlightIds(self: *ControlServer, now_ns: i128, out_ids: []u64) usize {
        var reaped: usize = 0;
        var i: usize = 0;
        while (i < self.in_flight.items.len) {
            if (self.in_flight.items[i].deadline_ns <= now_ns) {
                if (reaped < out_ids.len) out_ids[reaped] = self.in_flight.items[i].id;
                _ = self.in_flight.items[i].pending.resolve(null);
                _ = self.in_flight.swapRemove(i); // 마지막을 i로 당김 → i 재검사(증가 안 함)
                reaped += 1;
            } else i += 1;
        }
        return reaped;
    }

    /// 종료: accept 스레드에 closing을 알리고 join한 뒤 소켓/큐/in-flight를 해제한다(deinit 계약: 스레드 join·소켓 close).
    pub fn stop(self: *ControlServer) void {
        self.closing.store(true, .release);
        self.queue.close(); // 대기 pending cancel → 연결 스레드가 wait에서 깨어나 abandon
        // §5-async: in-flight로 붙잡힌 async 요청도 cancel(queue.close와 대칭 — 콜백이 영영 안 오는 요청의 accept
        // 스레드를 깨워 abandon시킨다). join 전에 해 blocked 연결 스레드가 빠져나오게 한다.
        for (self.in_flight.items) |e| e.pending.cancel();
        if (self.thread) |thread| {
            thread.join(); // accept 루프: poll_interval 안에 closing을 봐 나온다 → 이후 새 연결 스레드 spawn 없음
            self.thread = null;
        }
        // 5f-0b-2a: 살아있는 연결 스레드(detached)가 전부 끝날 때까지 대기 — self.*=undefined 전이라야 use-after-free
        // 없음. queue.close()+in-flight cancel이 waitResolved 블로킹을 깨웠고, readFrame 블로킹은 read_timeout(5s)까지.
        self.conns_mutex.lockUncancelable(self.io);
        while (self.active_conns > 0) self.conns_done.waitUncancelable(self.io, &self.conns_mutex);
        self.conns_mutex.unlock(self.io);
        self.server.deinit();
        self.queue.deinit();
        self.in_flight.deinit(self.items_gpa);
        self.subscriber_reg.deinit(); // 5f-0b-3a-2: 모든 연결 스레드 join 후(위) = 동시 접근 없음 → 락 없이 해제
        std.debug.assert(self.process_outbound_budget.snapshot().total_bytes == 0);
        self.* = undefined;
    }

    // ── accept 스레드(§5: accept + 연결당 스레드 spawn만; parse/framing/write는 연결 스레드) ──────────────────────────────────────────────────────
    fn acceptLoop(self: *ControlServer) void {
        while (!self.closing.load(.acquire)) {
            // blocking accept를 poll로 gate해 종료 시 poll_interval 안에 closing을 확인한다. #5: broken(listen fd가
            // POLLERR/HUP/NVAL로 회복 불가)은 재-poll(tight-spin·100% CPU) 대신 루프를 종료한다 — listen fd가 죽으면
            // 새 연결을 받을 방법이 없으므로 accept 중단이 올바르다(stop이 join한다).
            switch (self.server.pollReady(self.poll_interval_ms)) {
                .ready => {},
                .timeout => continue,
                .broken => {
                    if (std.c.getenv("MARU_DEBUG") != null)
                        std.debug.print("[maru control] listen fd broken (POLLERR/HUP/NVAL) — accept 루프 종료\n", .{});
                    break;
                },
            }
            if (self.closing.load(.acquire)) break;
            // acceptOne: peer-cred(same-uid, §8.2) + hello 전송. hello 직렬화는 transient cross_gpa.
            const conn = self.server.acceptOne(self.cross_gpa, .{
                .server_version = self.hello_version,
                .capabilities = self.hello_caps,
            }) catch continue; // peer uid 불일치·accept 실패 등은 그 연결만 버리고 계속.
            // 5f-0b-2a: 연결당 detached 스레드에서 serve(§9.5.1 — 직렬 인라인 폐기로 head-of-line 블로킹 제거). bound
            // 초과면 reject(즉시 close). 스레드가 conn 소유(값 복사=fd 하나라 안전, 스레드가 deinit=close; acceptLoop는
            // 안 함). 카운터는 spawn 전에 올려 stop()이 잃지 않게 한다(spawn 실패면 되돌림).
            self.conns_mutex.lockUncancelable(self.io);
            if (self.active_conns >= self.max_connections) {
                self.conns_mutex.unlock(self.io);
                conn.deinit(); // reject: 연결만 닫고 계속(client는 EOF)
                continue;
            }
            self.active_conns += 1;
            self.conns_mutex.unlock(self.io);
            const t = std.Thread.spawn(.{}, connThread, .{ self, conn }) catch {
                self.connDone(); // spawn 실패 → +1한 카운터 되돌림(connThread 종료 경로와 동일 헬퍼 — 19차 [6])
                conn.deinit();
                continue;
            };
            t.detach();
        }
    }

    /// 5f-0b-2a: 한 연결을 서브하는 detached 스레드 본체. 5f-0b-2b-2부터 **reader+writer 2-스레드**(§9.5.1): 이 스레드가
    /// **reader**(serveConnection)를 돌리고, **writer**(writerThread)를 spawn해 outbound 큐를 drain시킨다. serve(2b-1
    /// 지속 세션=auth 1회+요청 루프·waitResolved — 5e async 경로 불변)가 끝나면 outbound를 close해 writer를 종료·join한
    /// **뒤에** conn을 닫고(writer의 fd write와 close 경합 방지) wait-group 카운터를 내린다. conn은 값 소유(fd 하나).
    fn connThread(self: *ControlServer, conn_in: cs.Connection) void {
        var conn = conn_in;
        // 연결당 통합 outbound 큐(응답+이벤트). reader가 응답 push, writer가 drain→소켓 write(단일 writer 불변).
        // screenshot/executeScript가 같은 progressive pump를 쓰므로 queued+writer-owned를 connection/process
        // byte cap 아래 원자 회계한다. terminal carve-out은 취소/완료가 일반 chunk에 막히지 않게 남긴다.
        var outbound = OutboundChannel.initWithProcessBudget(self.io, self.outbound_capacity, &self.process_outbound_budget);
        const connection_id = nextConnectionId();
        const writer = std.Thread.spawn(.{}, writerThread, .{ self, conn.fd, &outbound }) catch {
            // writer spawn 실패 → 응답 write 경로 없음 → 이 연결 포기(reader 안 돌림). 정리 후 카운터 감소.
            _ = self.subscriber_reg.purgeOutbound(&outbound); // serve 전이라 구독 0(no-op)이나 free 전 정리 불변식 유지
            outbound.deinit(self.cross_gpa);
            conn.deinit();
            self.connDone();
            return;
        };
        self.serveConnection(&conn, connection_id, &outbound); // reader: auth 1회 + 요청 루프(응답을 outbound에 push)
        outbound.close(); // reader 종료 → writer가 남은 프레임 drain 후 popWait null로 종료
        writer.join(); // conn.fd write가 끝난 뒤에만 close(아래) — writer의 fd 사용과 경합 방지
        // 5f-0b-3a-2: 연결 drop — 이 연결의 구독을 registry에서 제거(leaf lock). **outbound free 전에** 해야 메인
        // pushEvent가 free된 outbound를 조회하는 UAF가 없다(purge와 pushEvent가 같은 leaf lock서 배타 — §9.5.6 realization).
        _ = self.subscriber_reg.purgeOutbound(&outbound);
        outbound.deinit(self.cross_gpa); // writer가 다 drain했으면 no-op, 아니면 남은 프레임 bytes free
        conn.deinit();
        self.connDone();
    }

    /// wait-group 카운터 감소 + stop() 대기 해제(connThread 종료 경로 공통).
    fn connDone(self: *ControlServer) void {
        self.conns_mutex.lockUncancelable(self.io);
        self.active_conns -= 1;
        self.conns_done.broadcast(self.io);
        self.conns_mutex.unlock(self.io);
    }

    /// 5f-0b-2b-2 **writer 스레드**: 연결의 outbound 큐를 `popWait`로 블록-drain해 프레임(응답+이벤트)을 소켓에 write한다
    /// (**이 스레드가 유일한 소켓 writer** — reader는 절대 안 씀). 각 프레임 뒤에 `\n` 프레이밍을 붙이고 bytes를 free한다
    /// (소유권=writer). **write 실패(broken pipe/SO_SNDTIMEO)면 `outbound.close()`로 즉시 teardown 신호**(19차 [0]):
    /// close가 reader의 다음 `outbound.push`를 `QueueClosed`로 만들어 reader가 연결을 abandon한다(응답을 안 읽는 client에
    /// 대해 옛 inline write `catch return`의 즉시-abandon 계약 복원 — sticky-broken drain은 최대 큐용량(64)사이클을 낭비하며
    /// marshal한 뒤에야 접혔다). 현재 프레임은 defer가 free하고, close 시점에 큐에 남은 프레임은 connThread의 `outbound.deinit`이
    /// free한다(close 후 reader는 push 불가라 누수 없음). conn.deinit(close)는 connThread가 join 후 한다.
    fn writerThread(self: *ControlServer, fd: c.fd_t, outbound: *OutboundChannel) void {
        while (outbound.popWait()) |frame| {
            defer self.cross_gpa.free(frame.bytes);
            defer outbound.writeComplete(frame.bytes);
            cs.writeAll(fd, frame.bytes) catch return outbound.close();
            cs.writeAll(fd, "\n") catch return outbound.close();
        }
    }

    /// 한 연결의 **reader**를 serve(5f-0b-2b-2 2-스레드): read 타임아웃 → auth 프레임 1회 → **요청 루프**(각 요청=frame
    /// 읽기 → marshal → 메인 응답 대기 → **outbound에 push**, 순차). 5f-0b-2b-1 **지속 세션**(§9.5.1 D1): auth 1회 후
    /// 같은 연결로 다중 요청. 요청은 순차(현 요청 응답을 push한 뒤 다음 read) — 응답 소켓 write는 writer 스레드가 한다
    /// (reader는 소켓에 안 씀 = 단일 writer 불변). EOF/타임아웃/에러/종료면 루프를 나오고, connThread가 outbound close→
    /// writer join→conn close를 한다. 코어/트리/collector 접근 0(전부 메인 marshal). cross_gpa만 쓴다.
    fn serveConnection(self: *ControlServer, conn: *cs.Connection, connection_id: u64, outbound: *OutboundChannel) void {
        cs.setReadTimeoutMs(conn.fd, self.read_timeout_ms);
        cs.setWriteTimeoutMs(conn.fd, self.read_timeout_ms); // #2: 응답을 안 읽는 client에 writer write가 무한 블록하지 않게(read와 대칭).
        var framer: cp.Framer = .{};
        defer framer.deinit(self.cross_gpa);

        // 프레임 1 = auth.self 셀렉터 + 선택적 cap_nonce(§8.4·§8.5 1e). 없거나 손상이면 빈 AuthFrame(self 안 줌·cap 없음).
        // AuthFrame은 값 타입(selector·cap_nonce 복사본)이라 framer 슬라이스 무효화와 무관하게 세션 내내 유효하다(auth 1회).
        const auth_line = self.readFrame(conn, &framer, outbound) orelse return;
        const auth = cp.parseAuthFrame(self.cross_gpa, auth_line);

        // 5f-4a-2 **세션 cap 집합**(§9.5.6 ③): auth.self의 cap_nonce가 있으면 첫 원소. 이후 요청 루프서 `auth.grant` 프레임을
        // 만나면 여기에 누적한다(bounded max_session_caps — 초과는 조용히 무시). serveConnection 스택 소유라 세션 내내 유효 →
        // PendingRequest.cap_nonces가 `session_caps[0..n]` 슬라이스를 빌린다(대기 동안 유효). 값 복사(framer 무효화 무관).
        var session_caps: [cap.max_session_caps][cp.auth_cap_nonce_len]u8 = undefined;
        var n_caps: usize = 0;
        if (auth.cap_nonce) |cn| {
            session_caps[0] = cn;
            n_caps = 1;
        }

        // 요청 루프(지속 세션): 각 iteration이 요청 한 개를 처리한다. readFrame null(EOF/타임아웃/에러/oversize)이면 종료.
        while (true) {
            // Framer 슬라이스는 다음 read에 무효화되므로 marshal 전에 dupe(대기 동안 유효 보장). defer로 iteration 끝에 해제.
            const req_line = self.readFrame(conn, &framer, outbound) orelse return;

            // 5f-4a-2: auth.grant 프레임이면 요청 아니라 **cap 누적** — 세션 집합에 추가하고 marshal 안 하고 다음 프레임으로.
            if (cp.parseAuthGrant(self.cross_gpa, req_line)) |grant_nonce| {
                if (n_caps < session_caps.len) {
                    session_caps[n_caps] = grant_nonce;
                    n_caps += 1;
                } // 초과(>max_session_caps=8)는 조용히 무시(bounded). **22차 [4] 한계**: cap은 per-(surface,scope)라
                // 다중 surface 세션은 8을 넘을 수 있는데, 넘친 grant는 드롭돼 그 cap 대상 요청이 균일 unauthorized로
                // 접혀 실 권한거부와 구별 안 된다. auth.grant는 **응답 없는 notification**이라 여기서 에러 회신도 불가.
                // 지금은 라이브 fd 발급이 미배선(테스트 훅만 1개 발급)이라 도달 불가 — 라이브 발급 착수 시 상한 재검토
                // (연결당 surface 수 기반 동적 상한 or auth.grant를 응답형으로 승격)한다. 단일 출처=control-plane §9.5.6 ④.
                continue;
            }

            const req_copy = self.cross_gpa.dupe(u8, req_line) catch return;
            defer self.cross_gpa.free(req_copy); // done/cancelled/에러 모두 이 iteration 끝(대기 후)에 해제

            var pending: PendingRequest = .{ .connection_id = connection_id, .connection_fd = conn.fd, .request_bytes = req_copy, .selector = auth.selector, .cap_nonces = session_caps[0..n_caps], .outbound = outbound, .io = self.io };
            self.queue.push(&pending) catch return; // QueueClosed(종료) → abandon(req_copy는 defer가 해제)

            switch (pending.waitResolved()) {
                .cancelled => return, // 서버 종료 — 응답 없이 abandon
                .pending => return, // 도달 불가(waitResolved는 pending에서 안 나감)
                .enqueued => continue, // 메인이 terminal을 같은 FIFO에 직접 넣음 — 중복 push 금지
                .done => {
                    // **null 응답 = "종료" 계약(§5-async)**: reap timeout(hung browser op)·메인 collect OOM·browser
                    // setup 실패가 `resolve(null)`로 온다 → 응답 없이 **연결을 닫는다**(옛 one-shot과 동형). 지속 루프에서
                    // return 없이 다음 readFrame으로 falling through하면 client가 응답도 EOF도 못 받아 stream이 desync되고
                    // (파이프라인한 후속 요청 응답을 timeout된 op에 오귀속), ~5s SO_RCVTIMEO까지 stranded된다(18차 [0]).
                    const resp = pending.response orelse return;
                    // 응답 바이트 소유권을 outbound 프레임으로 이전(writer가 write 후 free). `\n` 프레이밍은 writer가 붙인다.
                    // tag 0 = 응답(§8.5 purge 보호 — revoke는 이벤트만 지운다). 응답은 coalesce/유실 불가 → coalesce_key=null.
                    outbound.push(self.cross_gpa, .{ .bytes = resp, .coalesce_key = null, .purge_key = .none }) catch {
                        self.cross_gpa.free(resp); // push 실패(Full=writer 정체/broken, QueueClosed=종료) → 소유권 반환·해제 후 abandon
                        return;
                    };
                    // 응답 enqueue 완료 → 다음 요청 read(루프 계속). writer가 비동기로 소켓에 write. req_copy는 defer가 해제.
                },
            }
        }
    }

    /// 완결 프레임 하나를 조립해 돌려준다(1a Framer + 1b Connection.readInto 재사용). 슬라이스는 다음 read/next까지
    /// 유효. null = EOF/read 에러(타임아웃 포함)/OOM/payload-too-large → serve 중단(연결 abandon).
    fn readFrame(self: *ControlServer, conn: *cs.Connection, framer: *cp.Framer, outbound: *OutboundChannel) ?[]const u8 {
        while (true) {
            const maybe = framer.next() catch {
                // #3 §4.3: frame이 max를 초과하면 조용히 버리지 않고 payload_too_large(-32001) 응답을 보낸 뒤 연결을 버린다
                // (serveReadOnly와 동일 계약). 5f-0b-2b-2: 직접 소켓 write는 writer 스레드의 write와 경합(단일 writer 불변
                // 위반)하므로 **outbound에 push**(writer가 write). best-effort — 직렬화/push 실패는 무시(abandon 우선). 바이트는
                // `serializeErrorDefault`(id 파싱 전 거부 응답 단일 출처, 19차 [5])로 — writeErrorResponse와 형태가 안 갈린다.
                const err_bytes = cp.serializeErrorDefault(self.cross_gpa, .payload_too_large) catch return null;
                outbound.push(self.cross_gpa, .{ .bytes = err_bytes, .coalesce_key = null, .purge_key = .none }) catch self.cross_gpa.free(err_bytes);
                return null;
            };
            if (maybe) |line| return line;
            const n = conn.readInto(self.cross_gpa, framer) catch return null; // ReadFailed(타임아웃 포함)/OOM → null
            if (n == 0) return null; // EOF
        }
    }
};

// ══ 테스트(macOS-gated — 실제 unix socket + 스레드) ═══════════════════════════════════════════════════════════
const testing = std.testing;

// ── ControlRequestQueue 단위(스레드 없이) ──
test "queue: FIFO push/tryPop 순서 + 빈 큐 null" {
    var q = try ControlRequestQueue.init(std.testing.io, testing.allocator, 4);
    defer q.deinit();
    try testing.expect(q.tryPop() == null);
    var p1: PendingRequest = .{ .request_bytes = "a", .selector = null, .io = std.testing.io };
    var p2: PendingRequest = .{ .request_bytes = "b", .selector = null, .io = std.testing.io };
    try q.push(&p1);
    try q.push(&p2);
    try testing.expect(q.tryPop() == &p1);
    try testing.expect(q.tryPop() == &p2);
    try testing.expect(q.tryPop() == null);
}

test "queue(#4): hasPending가 큐 상태를 반영(빈=false, push 후 true, pop 후 false)" {
    var q = try ControlRequestQueue.init(std.testing.io, testing.allocator, 4);
    defer q.deinit();
    try testing.expect(!q.hasPending()); // 빈 큐
    var p1: PendingRequest = .{ .request_bytes = "a", .selector = null, .io = std.testing.io };
    try q.push(&p1);
    try testing.expect(q.hasPending()); // push 후
    _ = q.tryPop();
    try testing.expect(!q.hasPending()); // 비워진 뒤
}

test "queue: close는 대기 pending을 cancel하고 이후 push를 거부한다" {
    var q = try ControlRequestQueue.init(std.testing.io, testing.allocator, 4);
    defer q.deinit();
    var p1: PendingRequest = .{ .request_bytes = "a", .selector = null, .io = std.testing.io };
    try q.push(&p1);
    q.close();
    try testing.expectEqual(PendingRequest.State.cancelled, p1.state); // 큐에 남아 있던 pending은 cancel됨
    var p2: PendingRequest = .{ .request_bytes = "b", .selector = null, .io = std.testing.io };
    try testing.expectError(error.QueueClosed, q.push(&p2)); // closed 후 push 거부
}

fn obFrame(gpa: std.mem.Allocator, s: []const u8, key: ?u64, tag: u64) !co.Frame {
    return .{ .bytes = try gpa.dupe(u8, s), .coalesce_key = key, .purge_key = if (tag == 0) .none else .{ .surface_event = tag } };
}

test "OutboundChannel: push/popWait FIFO + coalesce + push-after-close QueueClosed" {
    var ch = OutboundChannel.init(std.testing.io, 8);
    defer ch.deinit(testing.allocator);
    try ch.push(testing.allocator, try obFrame(testing.allocator, "r1", null, 0)); // 응답(tag 0)
    try ch.push(testing.allocator, try obFrame(testing.allocator, "url=a", 100, 5)); // 이벤트(coalesce 100)
    try ch.push(testing.allocator, try obFrame(testing.allocator, "url=b", 100, 5)); // coalesce → 위치0 replace
    const f1 = ch.popWait().?;
    defer testing.allocator.free(f1.bytes);
    ch.writeComplete(f1.bytes);
    try testing.expectEqualStrings("r1", f1.bytes); // FIFO
    const f2 = ch.popWait().?;
    defer testing.allocator.free(f2.bytes);
    ch.writeComplete(f2.bytes);
    try testing.expectEqualStrings("url=b", f2.bytes); // coalesce된 최신
    // close 후 push는 QueueClosed(frame 소유권 호출자 유지).
    ch.close();
    const f = try obFrame(testing.allocator, "x", null, 0);
    try testing.expectError(error.QueueClosed, ch.push(testing.allocator, f));
    testing.allocator.free(f.bytes);
}

test "OutboundChannel: writer가 popWait서 블록→메인 push로 소비·close시 남은 것 drain 후 종료(cross-thread)" {
    const gpa = std.heap.c_allocator; // cross-thread
    var ch = OutboundChannel.init(std.testing.io, 8);
    defer ch.deinit(gpa);
    const Writer = struct {
        ch: *OutboundChannel,
        got: usize = 0,
        done: std.atomic.Value(bool) = .init(false),
        fn run(self: *@This()) void {
            defer self.done.store(true, .release);
            while (self.ch.popWait()) |f| { // 프레임 있으면 소비, closed+빈이면 null로 종료
                self.ch.writeComplete(f.bytes);
                std.heap.c_allocator.free(f.bytes);
                self.got += 1;
            }
        }
    };
    var w = Writer{ .ch = &ch };
    const th = try std.Thread.spawn(.{}, Writer.run, .{&w});
    try ch.push(gpa, try obFrame(gpa, "a", null, 0)); // writer가 블록서 깨어나 소비
    try ch.push(gpa, try obFrame(gpa, "b", null, 0));
    try ch.push(gpa, try obFrame(gpa, "c", null, 0));
    ch.close(); // 남은 것 drain 후 null 종료(close가 큐 유실 안 함)
    th.join();
    try testing.expect(w.done.load(.acquire));
    try testing.expectEqual(@as(usize, 3), w.got); // 3개 전부 소비
}

test "OutboundChannel: queued→writer-owned 이동은 writeComplete 전까지 byte cap을 유지" {
    var ch = OutboundChannel.initWithByteLimit(std.testing.io, 8, 6);
    defer ch.deinit(testing.allocator);
    try ch.push(testing.allocator, try obFrame(testing.allocator, "12345", null, 0)); // newline 포함 6
    const frame = ch.popWait().?;
    defer testing.allocator.free(frame.bytes);
    try testing.expectEqual(@as(usize, 6), ch.totalWireBytes());
    const blocked = try obFrame(testing.allocator, "x", null, 0);
    try testing.expectError(error.Full, ch.push(testing.allocator, blocked));
    testing.allocator.free(blocked.bytes);
    ch.writeComplete(frame.bytes);
    try testing.expectEqual(@as(usize, 0), ch.totalWireBytes());
}

test "OutboundChannel: general 프레임은 연결 terminal carve-out을 침범하지 않는다" {
    var process = ProcessOutboundBudget.init(std.testing.io, 64, 16);
    var ch = OutboundChannel.initWithLimits(std.testing.io, 8, 10, 3, 2, &process);
    defer ch.deinit(testing.allocator);

    try ch.push(testing.allocator, .{ .bytes = try testing.allocator.dupe(u8, "123456") }); // wire 7 = general exact
    const blocked = co.Frame{ .bytes = try testing.allocator.dupe(u8, "") }; // wire 1 would consume reserve
    try testing.expectError(error.Full, ch.push(testing.allocator, blocked));
    testing.allocator.free(blocked.bytes);
    try ch.push(testing.allocator, .{ .bytes = try testing.allocator.dupe(u8, "xy"), .class = .terminal }); // wire 3
    try testing.expectEqual(@as(usize, 10), ch.totalWireBytes());
}

test "OutboundChannel: general frame은 terminal 두 슬롯을 실제로 남긴다" {
    var process = ProcessOutboundBudget.init(std.testing.io, 64, 16);
    var ch = OutboundChannel.initWithLimits(std.testing.io, 4, 32, 8, 2, &process);
    defer ch.deinit(testing.allocator);
    try ch.push(testing.allocator, .{ .bytes = try testing.allocator.dupe(u8, "") });
    try ch.push(testing.allocator, .{ .bytes = try testing.allocator.dupe(u8, "") });
    const third_general: co.Frame = .{ .bytes = try testing.allocator.dupe(u8, "") };
    try testing.expectError(error.Full, ch.push(testing.allocator, third_general));
    testing.allocator.free(third_general.bytes);
    try ch.push(testing.allocator, .{ .bytes = try testing.allocator.dupe(u8, ""), .class = .terminal });
    try ch.push(testing.allocator, .{ .bytes = try testing.allocator.dupe(u8, ""), .class = .terminal });
    const third_terminal: co.Frame = .{ .bytes = try testing.allocator.dupe(u8, ""), .class = .terminal };
    try testing.expectError(error.Full, ch.push(testing.allocator, third_terminal));
    testing.allocator.free(third_terminal.bytes);
}

test "OutboundChannel: 여러 연결은 process general/terminal carve-out을 함께 지킨다" {
    var process = ProcessOutboundBudget.init(std.testing.io, 12, 4); // general 8 + terminal 4
    var a = OutboundChannel.initWithLimits(std.testing.io, 8, 12, 4, 2, &process);
    defer a.deinit(testing.allocator);
    var b = OutboundChannel.initWithLimits(std.testing.io, 8, 12, 4, 2, &process);
    defer b.deinit(testing.allocator);

    try a.push(testing.allocator, .{ .bytes = try testing.allocator.dupe(u8, "123456") }); // general wire 7
    try b.push(testing.allocator, .{ .bytes = try testing.allocator.dupe(u8, "") }); // general wire 1 = global exact
    const general_overflow = co.Frame{ .bytes = try testing.allocator.dupe(u8, "") };
    try testing.expectError(error.Full, b.push(testing.allocator, general_overflow));
    testing.allocator.free(general_overflow.bytes);
    try b.push(testing.allocator, .{ .bytes = try testing.allocator.dupe(u8, "abc"), .class = .terminal }); // terminal wire 4
    try testing.expectEqual(@as(usize, 12), process.snapshot().total_bytes);
    try testing.expectEqual(@as(usize, 4), process.snapshot().terminal_bytes);
}

test "OutboundChannel: writer-owned purge key는 queued purge와 별도로 연결 중단 필요를 알린다" {
    var process = ProcessOutboundBudget.init(std.testing.io, 64, 16);
    var ch = OutboundChannel.initWithLimits(std.testing.io, 8, 32, 8, 2, &process);
    defer ch.deinit(testing.allocator);
    const key: co.PurgeKey = .{ .browser_result = 9 };
    try ch.push(testing.allocator, .{ .bytes = try testing.allocator.dupe(u8, "first"), .purge_key = key });
    try ch.push(testing.allocator, .{ .bytes = try testing.allocator.dupe(u8, "second"), .purge_key = key });
    const writing = ch.popWait().?;
    defer testing.allocator.free(writing.bytes);

    const purged = ch.purgeDetailed(testing.allocator, key);
    try testing.expectEqual(@as(usize, 1), purged.queued_frames);
    try testing.expect(purged.writer_owned);
    try testing.expectEqual(co.wireBytes(writing.bytes), process.snapshot().total_bytes);
    ch.writeComplete(writing.bytes);
    try testing.expectEqual(@as(usize, 0), process.snapshot().total_bytes);
}

test "OutboundChannel: abort는 queued를 즉시 버리고 writer-owned 회계만 writeComplete까지 유지" {
    var process = ProcessOutboundBudget.init(std.testing.io, 64, 16);
    var ch = OutboundChannel.initWithLimits(std.testing.io, 8, 32, 8, 2, &process);
    defer ch.deinit(testing.allocator);
    try ch.push(testing.allocator, .{ .bytes = try testing.allocator.dupe(u8, "writing") });
    try ch.push(testing.allocator, .{ .bytes = try testing.allocator.dupe(u8, "queued") });
    const writing = ch.popWait().?;
    defer testing.allocator.free(writing.bytes);

    ch.abort(testing.allocator);
    try testing.expect(ch.isClosed());
    try testing.expectEqual(@as(usize, 0), ch.q.len());
    try testing.expectEqual(co.wireBytes(writing.bytes), ch.totalWireBytes());
    const rejected = co.Frame{ .bytes = try testing.allocator.dupe(u8, "rejected") };
    try testing.expectError(error.QueueClosed, ch.push(testing.allocator, rejected));
    testing.allocator.free(rejected.bytes);
    ch.writeComplete(writing.bytes);
    try testing.expectEqual(@as(usize, 0), process.snapshot().total_bytes);
    try testing.expect(ch.popWait() == null);
}

test "OutboundChannel: chunk watermark는 terminal byte와 frame carve-out을 미리 보존" {
    var process = ProcessOutboundBudget.init(std.testing.io, 200, 40);
    var frames = OutboundChannel.initWithLimits(std.testing.io, 8, 100, 20, 2, &process);
    defer frames.deinit(testing.allocator);
    for (0..6) |_| try frames.push(testing.allocator, .{ .bytes = try testing.allocator.dupe(u8, "x") });
    try testing.expect(frames.shouldPause()); // general frame cap=8-2
    for (0..4) |_| {
        const frame = frames.popWait().?;
        frames.writeComplete(frame.bytes);
        testing.allocator.free(frame.bytes);
    }
    try testing.expect(frames.shouldResume()); // general frames=2 <= cap/2

    var bytes = OutboundChannel.initWithLimits(std.testing.io, 8, 100, 20, 2, &process);
    defer bytes.deinit(testing.allocator);
    try bytes.push(testing.allocator, .{ .bytes = try testing.allocator.dupe(u8, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ12345678") });
    try testing.expect(bytes.shouldPause()); // wire 61 >= 75% of general byte cap 80
    const frame = bytes.popWait().?;
    bytes.writeComplete(frame.bytes);
    testing.allocator.free(frame.bytes);
}

test "ProcessOutboundBudget: 동시 연결 push도 global hard cap을 넘지 않는다" {
    const N = 8;
    const gpa = std.heap.c_allocator;
    var process = ProcessOutboundBudget.init(std.testing.io, 10, 2); // general 8 bytes
    var channels: [N]OutboundChannel = undefined;
    for (&channels) |*channel| channel.* = OutboundChannel.initWithLimits(std.testing.io, 2, 8, 2, 1, &process);
    defer for (&channels) |*channel| channel.deinit(gpa);
    var successes = std.atomic.Value(usize).init(0);
    const Worker = struct {
        fn run(allocator: std.mem.Allocator, channel: *OutboundChannel, count: *std.atomic.Value(usize)) void {
            const frame: co.Frame = .{ .bytes = allocator.dupe(u8, "x") catch return }; // wire 2
            channel.push(allocator, frame) catch {
                allocator.free(frame.bytes);
                return;
            };
            _ = count.fetchAdd(1, .acq_rel);
        }
    };
    var threads: [N]std.Thread = undefined;
    for (&threads, &channels) |*thread, *channel| thread.* = try std.Thread.spawn(.{}, Worker.run, .{ gpa, channel, &successes });
    for (threads) |thread| thread.join();
    try testing.expectEqual(@as(usize, 4), successes.load(.acquire));
    try testing.expectEqual(@as(usize, 8), process.snapshot().total_bytes);
}

test "OutboundChannel: queue append OOM은 process reservation과 frame 소유권을 rollback한다" {
    var process = ProcessOutboundBudget.init(std.testing.io, 16, 4);
    var ch = OutboundChannel.initWithLimits(std.testing.io, 4, 12, 4, 1, &process);
    defer ch.deinit(testing.allocator);
    const frame: co.Frame = .{ .bytes = try testing.allocator.dupe(u8, "abc") };
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, ch.push(failing.allocator(), frame));
    try testing.expectEqual(@as(usize, 0), ch.q.len());
    try testing.expectEqual(@as(usize, 0), process.snapshot().total_bytes);
    // 실패 시 bytes는 호출자 소유 그대로라 정상 allocator로 같은 frame을 재시도할 수 있다.
    try ch.push(testing.allocator, frame);
    try testing.expectEqual(@as(usize, 4), process.snapshot().total_bytes);
}

test "OutboundChannel: invalid terminal coalesce는 process budget을 건드리기 전에 거부한다" {
    var process = ProcessOutboundBudget.init(std.testing.io, 32, 8);
    var ch = OutboundChannel.initWithLimits(std.testing.io, 4, 24, 8, 2, &process);
    defer ch.deinit(testing.allocator);
    try ch.push(testing.allocator, .{ .bytes = try testing.allocator.dupe(u8, "123456"), .coalesce_key = 1 });
    const before = process.snapshot();
    const invalid: co.Frame = .{ .bytes = try testing.allocator.dupe(u8, ""), .coalesce_key = 1, .class = .terminal };
    try testing.expectError(error.InvalidFrame, ch.push(testing.allocator, invalid));
    testing.allocator.free(invalid.bytes);
    try testing.expectEqualDeep(before, process.snapshot());
    try testing.expectEqual(@as(usize, 1), ch.q.len());
}

test "OutboundChannel: local/global 75 percent pause와 50 percent resume 경계" {
    var process = ProcessOutboundBudget.init(std.testing.io, 16, 4);
    var ch = OutboundChannel.initWithLimits(std.testing.io, 8, 16, 4, 2, &process);
    defer ch.deinit(testing.allocator);
    try ch.push(testing.allocator, .{ .bytes = try testing.allocator.dupe(u8, "12345678901") }); // wire 12 = 75%
    try testing.expect(ch.shouldPause());
    try testing.expect(!ch.shouldResume());
    const frame = ch.popWait().?;
    defer testing.allocator.free(frame.bytes);
    ch.writeComplete(frame.bytes);
    try testing.expect(ch.shouldResume());
}

// ── SubscriberRegistry 단위(5f-0b-3a — 메인 전용·헤드리스, 스레드 없이 순수 로직) ──
test "SubscriberRegistry: 매칭 fan-out + 필터 + 비매칭 surface 미전달 + notification 형태" {
    var reg = SubscriberRegistry.init(std.testing.io, testing.allocator);
    defer reg.deinit();
    var ch_a = OutboundChannel.init(std.testing.io, 8);
    defer ch_a.deinit(testing.allocator);
    var ch_b = OutboundChannel.init(std.testing.io, 8);
    defer ch_b.deinit(testing.allocator);

    // A는 surface 10을 navigated만, B는 surface 20을 전체 구독.
    const id_a = try reg.subscribe(10, cev.EventFilter.only(&[_]cev.EventKind{.navigated}), &ch_a);
    const id_b = try reg.subscribe(20, cev.EventFilter.all, &ch_b);
    try testing.expect(id_a != id_b);

    try testing.expectEqual(@as(usize, 1), reg.pushEvent(testing.allocator, 10, .{ .navigated = "https://a" })); // A만
    try testing.expectEqual(@as(usize, 0), reg.pushEvent(testing.allocator, 10, .{ .load_state = .idle })); // A 필터 제외 → 0
    try testing.expectEqual(@as(usize, 1), reg.pushEvent(testing.allocator, 20, .{ .load_state = .loading })); // B만
    try testing.expectEqual(@as(usize, 0), reg.pushEvent(testing.allocator, 99, .{ .navigated = "x" })); // 구독 없는 surface → 0

    try testing.expectEqual(@as(usize, 1), ch_a.q.len());
    const fa = ch_a.popWait().?;
    defer testing.allocator.free(fa.bytes);
    ch_a.writeComplete(fa.bytes);
    try testing.expect(std.mem.indexOf(u8, fa.bytes, "browser.navigated") != null);
    try testing.expect(std.mem.indexOf(u8, fa.bytes, "https://a") != null);
    try testing.expect(std.mem.indexOf(u8, fa.bytes, "\"surface_id\":10") != null);

    try testing.expectEqual(@as(usize, 1), ch_b.q.len());
    const fb = ch_b.popWait().?;
    defer testing.allocator.free(fb.bytes);
    ch_b.writeComplete(fb.bytes);
    try testing.expect(std.mem.indexOf(u8, fb.bytes, "browser.loadState") != null);
    try testing.expect(std.mem.indexOf(u8, fb.bytes, "loading") != null);
}

test "SubscriberRegistry: coalescible은 큐서 최신이 옛것 대체(coalesce), 이산(dialog)은 누적" {
    var reg = SubscriberRegistry.init(std.testing.io, testing.allocator);
    defer reg.deinit();
    var ch = OutboundChannel.init(std.testing.io, 8);
    defer ch.deinit(testing.allocator);
    _ = try reg.subscribe(10, cev.EventFilter.all, &ch);

    // navigated 2연발(coalescible, coalesce_key=(10,navigated) 동일) → 큐엔 최신 1개.
    _ = reg.pushEvent(testing.allocator, 10, .{ .navigated = "https://old" });
    _ = reg.pushEvent(testing.allocator, 10, .{ .navigated = "https://new" });
    try testing.expectEqual(@as(usize, 1), ch.q.len()); // coalesce
    const f = ch.popWait().?;
    defer testing.allocator.free(f.bytes);
    ch.writeComplete(f.bytes);
    try testing.expect(std.mem.indexOf(u8, f.bytes, "https://new") != null); // 최신 유지
    try testing.expect(std.mem.indexOf(u8, f.bytes, "https://old") == null); // 옛것 대체됨

    // dialog 2연발(비coalescible) → 2개 누적.
    _ = reg.pushEvent(testing.allocator, 10, .{ .dialog = .{ .kind = .alert, .message = "m1" } });
    _ = reg.pushEvent(testing.allocator, 10, .{ .dialog = .{ .kind = .confirm, .message = "m2" } });
    try testing.expectEqual(@as(usize, 2), ch.q.len()); // 누적(coalesce 안 함)
}

test "SubscriberRegistry: 같은 outbound 재구독은 subscriber_id 재사용 + 필터 갱신 + 다중 surface 1매핑" {
    var reg = SubscriberRegistry.init(std.testing.io, testing.allocator);
    defer reg.deinit();
    var ch = OutboundChannel.init(std.testing.io, 8);
    defer ch.deinit(testing.allocator);
    const id1 = try reg.subscribe(10, cev.EventFilter.only(&[_]cev.EventKind{.navigated}), &ch);
    const id2 = try reg.subscribe(10, cev.EventFilter.all, &ch); // 같은 (conn,surface) 재구독 → id 재사용·필터 갱신
    try testing.expectEqual(id1, id2);
    try testing.expectEqual(@as(usize, 1), reg.broker.len()); // 중복 엔트리 없음
    try testing.expectEqual(@as(usize, 1), reg.pushEvent(testing.allocator, 10, .{ .load_state = .idle })); // 필터 all로 갱신 → 전달
    const f = ch.popWait().?;
    ch.writeComplete(f.bytes);
    testing.allocator.free(f.bytes);

    // 같은 연결이 다른 surface도 구독 → 같은 id·매핑 1개(1 연결 다중 surface).
    _ = try reg.subscribe(20, cev.EventFilter.all, &ch);
    try testing.expectEqual(id1, reg.idForOutbound(&ch).?);
    try testing.expectEqual(@as(u32, 1), reg.outbound_of.count()); // 1 연결 = 매핑 1
    try testing.expectEqual(@as(usize, 2), reg.broker.len()); // (id,10)+(id,20)
}

test "SubscriberRegistry: purgeOutbound가 그 연결의 모든 구독·매핑 제거(다른 연결 무영향)" {
    var reg = SubscriberRegistry.init(std.testing.io, testing.allocator);
    defer reg.deinit();
    var ch_a = OutboundChannel.init(std.testing.io, 8);
    defer ch_a.deinit(testing.allocator);
    var ch_b = OutboundChannel.init(std.testing.io, 8);
    defer ch_b.deinit(testing.allocator);
    _ = try reg.subscribe(10, cev.EventFilter.all, &ch_a);
    _ = try reg.subscribe(20, cev.EventFilter.all, &ch_a); // A: 2 surface
    _ = try reg.subscribe(10, cev.EventFilter.all, &ch_b); // B: surface 10

    try testing.expectEqual(@as(usize, 2), reg.purgeOutbound(&ch_a)); // A의 (10)+(20) 제거
    try testing.expect(reg.idForOutbound(&ch_a) == null); // 매핑 제거
    try testing.expectEqual(@as(usize, 1), reg.broker.len()); // B만 남음

    try testing.expectEqual(@as(usize, 1), reg.pushEvent(testing.allocator, 10, .{ .navigated = "x" })); // surface10엔 B 남아 1
    const fb = ch_b.popWait().?;
    ch_b.writeComplete(fb.bytes);
    testing.allocator.free(fb.bytes);
    try testing.expectEqual(@as(usize, 0), reg.pushEvent(testing.allocator, 20, .{ .navigated = "y" })); // A 뺐으니 surface20 구독 0
    try testing.expectEqual(@as(usize, 0), ch_a.q.len()); // A outbound엔 아무것도 안 옴
}

test "SubscriberRegistry: purgeSurface가 그 surface 구독만 제거(연결 매핑·다른 surface 유지)" {
    var reg = SubscriberRegistry.init(std.testing.io, testing.allocator);
    defer reg.deinit();
    var ch = OutboundChannel.init(std.testing.io, 8);
    defer ch.deinit(testing.allocator);
    _ = try reg.subscribe(10, cev.EventFilter.all, &ch);
    _ = try reg.subscribe(20, cev.EventFilter.all, &ch);
    // surface 10에 이벤트를 하나 큐에 쌓아두고 purgeSurface(10)이 그 잔여 프레임까지 폐기하는지 확인(20차 [3]).
    try testing.expectEqual(@as(usize, 1), reg.pushEvent(testing.allocator, 10, .{ .navigated = "queued" }));
    try testing.expectEqual(@as(usize, 1), reg.pushEvent(testing.allocator, 20, .{ .navigated = "keep" }));
    try testing.expectEqual(@as(usize, 1), reg.purgeSurface(testing.allocator, 10)); // surface 10 구독 제거 + 잔여 프레임 폐기
    try testing.expectEqual(@as(usize, 1), reg.broker.len()); // surface 20 남음
    try testing.expect(reg.idForOutbound(&ch) != null); // 연결 매핑 유지(연결 살아 있음)
    try testing.expectEqual(@as(usize, 1), ch.q.len()); // surface 10 프레임 폐기됨 → surface 20 프레임 하나만 남음
    try testing.expectEqual(@as(usize, 0), reg.pushEvent(testing.allocator, 10, .{ .navigated = "x" })); // 10 구독 제거됨
    try testing.expectEqual(@as(usize, 1), reg.pushEvent(testing.allocator, 20, .{ .navigated = "y" })); // 20 유지
    // 남은 프레임(surface 20의 keep→y coalesce 최신 1개) drain.
    while (ch.q.len() > 0) {
        const f = ch.popWait().?;
        ch.writeComplete(f.bytes);
        testing.allocator.free(f.bytes);
    }
}

test "SubscriberRegistry(21차 [0]/[3]): pushSurfaceClosed는 필터 무관 전체 구독자에 closed 배달 + 구독 제거(프레임 유지)" {
    var reg = SubscriberRegistry.init(std.testing.io, testing.allocator);
    defer reg.deinit();
    var ch = OutboundChannel.init(std.testing.io, 8);
    defer ch.deinit(testing.allocator);
    // surface 10을 **navigated만** 구독(closed 필터 아웃). closed는 종료 마커라 필터로 opt-out 못 하고 배달돼야 한다.
    _ = try reg.subscribe(10, cev.EventFilter.only(&[_]cev.EventKind{.navigated}), &ch);
    _ = try reg.subscribe(20, cev.EventFilter.all, &ch);
    // 대조(21차 [0] 버그): pushEvent(.closed)는 필터 존중이라 navigated-only 구독엔 0(closed 못 받음 → hang).
    try testing.expectEqual(@as(usize, 0), reg.pushEvent(testing.allocator, 10, .closed));
    // pushSurfaceClosed는 **필터 무관** → surface 10 구독자에 배달(1) + 구독 제거.
    try testing.expectEqual(@as(usize, 1), reg.pushSurfaceClosed(testing.allocator, 10));
    try testing.expectEqual(@as(usize, 1), reg.broker.len()); // surface 20만 남음(10 제거)
    try testing.expect(reg.idForOutbound(&ch) != null); // 연결 매핑 유지(연결 살아 있음)
    try testing.expectEqual(@as(usize, 1), ch.q.len()); // closed 프레임 **유지**(배달용 — remove는 프레임 안 건드림)
    const f = ch.popWait().?;
    defer testing.allocator.free(f.bytes);
    ch.writeComplete(f.bytes);
    try testing.expect(std.mem.indexOf(u8, f.bytes, "browser.closed") != null);
    try testing.expectEqual(@as(usize, 0), reg.pushEvent(testing.allocator, 10, .{ .navigated = "after" })); // 10 구독 제거됨 → 이후 이벤트 0
}

test "SubscriberRegistry(3a-2): 메인 pushEvent ∥ 연결 purgeOutbound/subscribe 동시 broker mutation 무크래시(leaf-mutex)" {
    const gpa = std.heap.c_allocator; // cross-thread
    var reg = SubscriberRegistry.init(std.testing.io, gpa);
    defer reg.deinit();
    // **채널은 테스트 내내 살아있고**(free 안 함), 한 스레드는 purge+재구독 반복(broker.subs·맵 mutation), 메인은 계속 push.
    // 이 테스트가 잡는 것은 **broker/맵 동시 mutation 레이스**(leaf-mutex 직렬화 실패)다. free-after-purge 순서(UAF)는
    // 아래 별도 테스트가 채널을 실제로 free하며 검증한다(20차 [2] — 이 테스트만으로는 UAF 순서를 안 태운다).
    const N = 4;
    var chans: [N]OutboundChannel = undefined;
    for (0..N) |i| chans[i] = OutboundChannel.init(std.testing.io, 64);
    defer for (0..N) |i| chans[i].deinit(gpa);
    for (0..N) |i| _ = try reg.subscribe(@intCast(10 + i), cev.EventFilter.all, &chans[i]);

    const Churner = struct {
        reg: *SubscriberRegistry,
        chans: [*]OutboundChannel,
        n: usize,
        done: std.atomic.Value(bool) = .init(false),
        fn run(self: *@This()) void {
            defer self.done.store(true, .release);
            var r: usize = 0;
            while (r < 3000) : (r += 1) {
                const i = r % self.n;
                _ = self.reg.purgeOutbound(&self.chans[i]); // 연결 drop 모사
                _ = self.reg.subscribe(@intCast(10 + i), cev.EventFilter.all, &self.chans[i]) catch {}; // 재구독
            }
        }
    };
    var churner = Churner{ .reg = &reg, .chans = &chans, .n = N };
    const th = try std.Thread.spawn(.{}, Churner.run, .{&churner});
    var k: usize = 0;
    while (!churner.done.load(.acquire)) : (k += 1) {
        _ = reg.pushEvent(gpa, @intCast(10 + (k % N)), .{ .navigated = "https://x" });
    }
    th.join();
    try testing.expect(churner.done.load(.acquire)); // 무크래시 완주 = leaf-mutex 직렬화 성립
}

test "SubscriberRegistry(20차 [2]): 연결 스레드 purge→free ∥ 메인 pushEvent — free-after-purge UAF 없음(cross-thread)" {
    const gpa = std.heap.c_allocator; // cross-thread
    var reg = SubscriberRegistry.init(std.testing.io, gpa);
    defer reg.deinit();
    // 연결 수명을 실제로 모사한다: 스레드가 매 iteration **heap outbound를 alloc→subscribe→purge→(deinit+free)**한다
    // (connThread의 purge-before-free 순서). 메인은 그 surface로 계속 pushEvent. leaf-mutex가 purge와 pushEvent를
    // 배타로 만들어, 메인이 push하는 outbound는 늘 아직 등록돼(=살아있음) 있고 free는 purge 뒤라 UAF가 없다. 만약 free가
    // purge보다 앞서는 회귀가 생기면 메인 push가 free된 outbound의 mutex/큐를 만져 크래시/손상(3000×반복+메모리 재사용).
    const Churner = struct {
        reg: *SubscriberRegistry,
        gpa: std.mem.Allocator,
        done: std.atomic.Value(bool) = .init(false),
        fn run(self: *@This()) void {
            defer self.done.store(true, .release);
            var r: usize = 0;
            while (r < 3000) : (r += 1) {
                const ch = self.gpa.create(OutboundChannel) catch return;
                ch.* = OutboundChannel.init(std.testing.io, 8);
                _ = self.reg.subscribe(30, cev.EventFilter.all, ch) catch {};
                _ = self.reg.purgeOutbound(ch); // registry서 제거(leaf lock) → 이후 메인은 이 ch를 못 찾음
                ch.deinit(self.gpa); // **purge 뒤에만** free — 순서가 뒤집히면 메인 push가 UAF
                self.gpa.destroy(ch);
            }
        }
    };
    var churner = Churner{ .reg = &reg, .gpa = gpa };
    const th = try std.Thread.spawn(.{}, Churner.run, .{&churner});
    while (!churner.done.load(.acquire)) {
        _ = reg.pushEvent(gpa, 30, .{ .navigated = "https://x" }); // 등록된 ch(있으면)에 push — free된 ch면 UAF
    }
    th.join();
    try testing.expect(churner.done.load(.acquire)); // 완주 = purge-before-free 순서로 UAF 없음
}

test "pending rendezvous: producer가 대기, consumer가 resolve하면 응답을 받는다(cross-thread)" {
    const Ctx = struct {
        pending: PendingRequest,
        got: ?[]u8 = null,
        fn producer(ctxp: *@This()) void {
            _ = ctxp.pending.waitResolved();
            ctxp.got = ctxp.pending.response;
        }
    };
    var ctx = Ctx{ .pending = .{ .request_bytes = "req", .selector = null, .io = std.testing.io } };
    const th = try std.Thread.spawn(.{}, Ctx.producer, .{&ctx});
    // consumer(이 스레드) — 짧게 양보한 뒤 resolve.
    std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(2), .awake) catch {};
    const resp = try testing.allocator.dupe(u8, "the-response");
    _ = ctx.pending.resolve(resp);
    th.join();
    try testing.expect(ctx.got != null);
    try testing.expectEqualStrings("the-response", ctx.got.?);
    testing.allocator.free(resp);
}

// ── §5-async: deferred marshal(in-flight 레지스트리 — 메인 전용, 스레드 없이 단위) ──
// 최소 srv(in_flight/items_gpa/max_in_flight만 세팅) — deferRequest/completeInFlight/reapExpiredInFlight는
// 이 필드들만 만지고 소켓·스레드를 안 탄다(readFrame 단위 테스트가 cross_gpa만 세팅한 것과 같은 결).
fn inflightSrv(max: usize) ControlServer {
    var srv: ControlServer = undefined;
    srv.in_flight = .empty;
    srv.items_gpa = testing.allocator;
    srv.cross_gpa = testing.allocator; // completeInFlight 미발견 경로가 response를 free(리뷰 [1])
    srv.max_in_flight = max;
    return srv;
}

test "§5-async deferRequest→completeInFlight: 응답을 나중에 되돌린다(pending 즉시 resolve 안 됨)" {
    var srv = inflightSrv(8);
    defer srv.in_flight.deinit(testing.allocator);
    var p: PendingRequest = .{ .request_bytes = "req", .selector = null, .io = std.testing.io };
    const id = try srv.deferRequest(&p, std.math.maxInt(i128)); // 마감 먼 미래
    try testing.expect(id != 0);
    try testing.expectEqual(PendingRequest.State.pending, p.state); // in-flight — 아직 resolve 안 됨
    try testing.expectEqual(@as(usize, 1), srv.in_flight.items.len);

    const resp = try testing.allocator.dupe(u8, "async-response");
    try testing.expect(srv.completeInFlight(id, resp)); // 콜백이 나중에 완료
    try testing.expectEqual(PendingRequest.State.done, p.state);
    try testing.expectEqualStrings("async-response", p.response.?);
    try testing.expectEqual(@as(usize, 0), srv.in_flight.items.len); // 제거됨
    testing.allocator.free(resp);
    // 이미 완료/미지 id 재-complete는 false(늦은 중복 콜백·옛 id 안전).
    try testing.expect(!srv.completeInFlight(id, null));
    try testing.expect(!srv.completeInFlight(999, null));
    // 리뷰 [1]: 미발견 경로가 넘긴 **response 버퍼를 소유 인수해 free**한다(안 하면 누수 — testing.allocator가 잡음).
    const late = try testing.allocator.dupe(u8, "late-callback-result");
    try testing.expect(!srv.completeInFlight(id, late)); // reap/완료된 id에 늦은 콜백 → false + late free됨(누수 없음)
}

test "§5-async 직접 enqueue 완료는 pending을 enqueued로 깨우고 registry에서 한 번만 제거" {
    var srv = inflightSrv(8);
    defer srv.in_flight.deinit(testing.allocator);
    var pending: PendingRequest = .{ .connection_id = 17, .request_bytes = "req", .selector = null, .io = std.testing.io };
    const id = try srv.deferRequest(&pending, std.math.maxInt(i128));
    try testing.expect(srv.completeInFlightEnqueued(id));
    try testing.expectEqual(PendingRequest.State.enqueued, pending.state);
    try testing.expectEqual(@as(usize, 0), srv.in_flight.items.len);
    try testing.expect(!srv.completeInFlightEnqueued(id));
}

test "§5-async deferRequest bounded: max_in_flight 초과 → TooManyInFlight(호출자가 에러 resolve)" {
    var srv = inflightSrv(2);
    defer srv.in_flight.deinit(testing.allocator);
    var p1: PendingRequest = .{ .request_bytes = "a", .selector = null, .io = std.testing.io };
    var p2: PendingRequest = .{ .request_bytes = "b", .selector = null, .io = std.testing.io };
    var p3: PendingRequest = .{ .request_bytes = "c", .selector = null, .io = std.testing.io };
    const id1 = try srv.deferRequest(&p1, std.math.maxInt(i128));
    _ = try srv.deferRequest(&p2, std.math.maxInt(i128));
    try testing.expectError(error.TooManyInFlight, srv.deferRequest(&p3, std.math.maxInt(i128)));
    try testing.expectEqual(@as(usize, 2), srv.in_flight.items.len);
    // 하나 완료하면 슬롯이 나 다시 defer 가능.
    try testing.expect(srv.completeInFlight(id1, null));
    _ = try srv.deferRequest(&p3, std.math.maxInt(i128));
}

test "§5-async reapExpiredInFlight: 마감 지난 것만 timeout(null) resolve+제거, 나머지 유지" {
    var srv = inflightSrv(8);
    defer srv.in_flight.deinit(testing.allocator);
    var expired: PendingRequest = .{ .request_bytes = "old", .selector = null, .io = std.testing.io };
    var live: PendingRequest = .{ .request_bytes = "new", .selector = null, .io = std.testing.io };
    const expired_id = try srv.deferRequest(&expired, 100); // 마감 100
    const live_id = try srv.deferRequest(&live, 10_000); // 마감 먼 미래
    try testing.expect(srv.updateInFlightDeadline(live_id, 20_000));
    try testing.expect(!srv.updateInFlightDeadline(std.math.maxInt(u64), 1));
    var reaped_ids: [2]u64 = undefined;
    try testing.expectEqual(@as(usize, 1), srv.expiredInFlightIds(500, &reaped_ids));
    try testing.expectEqual(expired_id, reaped_ids[0]);
    try testing.expectEqual(@as(usize, 1), srv.reapExpiredInFlightIds(500, &reaped_ids)); // now=500: expired만
    try testing.expectEqual(expired_id, reaped_ids[0]);
    try testing.expectEqual(PendingRequest.State.done, expired.state); // timeout resolve
    try testing.expect(expired.response == null); // 응답 없음(연결 닫힘 → client read 타임아웃)
    try testing.expectEqual(PendingRequest.State.pending, live.state); // 유지
    try testing.expectEqual(@as(usize, 1), srv.in_flight.items.len);
    // live도 마감 지나면 reap.
    try testing.expectEqual(@as(usize, 1), srv.reapExpiredInFlight(20_000));
    try testing.expectEqual(PendingRequest.State.done, live.state);
    try testing.expectEqual(@as(usize, 0), srv.in_flight.items.len);
}

test "§5-async process-lifetime id와 cancelled pending response 소유권" {
    var first = inflightSrv(1);
    defer first.in_flight.deinit(testing.allocator);
    var second = inflightSrv(1);
    defer second.in_flight.deinit(testing.allocator);
    var p1: PendingRequest = .{ .request_bytes = "a", .selector = null, .io = std.testing.io };
    var p2: PendingRequest = .{ .request_bytes = "b", .selector = null, .io = std.testing.io };
    const id1 = try first.deferRequest(&p1, std.math.maxInt(i128));
    const id2 = try second.deferRequest(&p2, std.math.maxInt(i128));
    try testing.expect(id1 != id2); // stop/start에 해당하는 별도 server에서도 ABA 없음

    p1.cancel();
    const rejected = try testing.allocator.dupe(u8, "cancelled-response");
    try testing.expect(first.completeInFlight(id1, rejected)); // response는 Pending이 거부해도 server가 free
    try testing.expectEqual(PendingRequest.State.cancelled, p1.state);
    try testing.expect(second.completeInFlight(id2, null));
}

test "§5-async stop: in-flight 요청을 cancel한다(콜백 영영 안 오는 요청의 accept를 깨워 abandon)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var bb: [256]u8 = undefined;
    const base = srvTmpBase(&bb, "inflight-stop");
    defer srvRmBase(base);
    var server: ControlServer = undefined;
    try server.start(std.testing.io, std.heap.c_allocator, testing.allocator, base, "k1", "0.1.0-test", &test_caps, 8);
    // 실 연결 없이 fake pending을 in-flight로 등록(메인 전용 API) — stop이 cancel해야 한다.
    var p: PendingRequest = .{ .request_bytes = "req", .selector = null, .io = std.testing.io };
    _ = try server.deferRequest(&p, std.math.maxInt(i128));
    server.stop(); // in-flight cancel + join + deinit
    try testing.expectEqual(PendingRequest.State.cancelled, p.state);
}

// ── 전체 라이브 서버 왕복(accept 스레드 + marshal + 메인 drain + 응답) ──
const cd = maru.session.control_dispatch;
const cb = maru.session.control_browser; // 5f-0b-3b: browser.subscribe end-to-end 테스트(BrowserSubscribe·serializeSubscribeResponse)
const cpg = maru.session.control_pane_grant; // 1e-confirm-1b: pane-bound confirm-grant store(drain 테스트는 빈 grant)
const csurf = maru.session.control_surface;
const wm = maru.session.window_membership;

var srv_tmp_counter: std.atomic.Value(u64) = .init(0);
fn srvTmpBase(buf: []u8, tag: []const u8) [:0]u8 {
    const n = srv_tmp_counter.fetchAdd(1, .monotonic);
    const p = std.fmt.bufPrintZ(buf, "/tmp/maru-cs-{d}-{s}-{d}", .{ c.getpid(), tag, n }) catch unreachable;
    _ = c.mkdir(p.ptr, 0o700);
    return p;
}
fn srvRmBase(base: [:0]const u8) void {
    var b: [512]u8 = undefined;
    const ctl = cs.controlDirPath(&b, base) catch return;
    _ = c.rmdir(ctl.ptr);
    _ = c.rmdir(base.ptr);
}

// fake collector snapshot(control_socket 왕복 테스트와 같은 결).
const rt_surfaces = [_]csurf.SurfaceDto{
    .{ .surface_id = 10, .title = "shell-a", .window = 1, .focused = true, .detail = .{ .terminal = .{ .cwd = "/home/a", .at_prompt = .not_at_prompt } } },
    .{ .surface_id = 20, .title = "shell-b", .window = 2, .detail = .{ .terminal = .{ .at_prompt = .at_prompt } } },
};
const rt_a = [_]u64{10};
const rt_b = [_]u64{20};
const rt_windows = [_]wm.WindowMembershipSnapshot{
    .{ .window_id = 1, .window_kind = .normal, .surface_ids = &rt_a },
    .{ .window_id = 2, .window_kind = .normal, .surface_ids = &rt_b },
};
const rt_snapshot: csurf.CollectorSnapshot = .{ .surfaces = &rt_surfaces, .windows = &rt_windows };
const test_caps = [_][]const u8{ "sessions.list", "session.get" };

// 5f-0b-3b: browser.subscribe 왕복용 web surface 스냅샷(browserOpFromRequest는 대상이 web이어야 authz 통과). surface 30=web.
const web_surfaces = [_]csurf.SurfaceDto{
    .{ .surface_id = 30, .title = "browser", .window = 3, .detail = .{ .web = .{ .url = "https://ex/", .panel_kind = .browser, .loading = false, .trust = .untrusted } } },
};
const web_ids = [_]u64{30};
const web_windows = [_]wm.WindowMembershipSnapshot{.{ .window_id = 3, .window_kind = .normal, .surface_ids = &web_ids }};
const web_snapshot: csurf.CollectorSnapshot = .{ .surfaces = &web_surfaces, .windows = &web_windows };

/// 테스트 client: connect → auth.self(surface_id [+ cap_nonce]) → 요청 → hello skip → 응답 한 줄(owned).
fn clientReq(gpa: std.mem.Allocator, base: []const u8, key: []const u8, selector: ?u64, cap_nonce: ?[cap.nonce_len]u8, request: []const u8) ![]u8 {
    var db: [512]u8 = undefined;
    const dir = try cs.controlDirPath(&db, base);
    var sb: [512]u8 = undefined;
    const sp = try cs.socketPathIn(&sb, dir, key);
    const fd = c.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    if (fd < 0) return error.ClientSocket;
    defer _ = c.close(fd);
    var addr = posix.sockaddr.un{ .family = posix.AF.UNIX, .path = undefined };
    @memset(&addr.path, 0);
    @memcpy(addr.path[0..sp.len], sp);
    if (c.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) != 0) return error.ClientConnect;

    const auth = try cp.serializeAuthSelf(gpa, selector, cap_nonce);
    defer gpa.free(auth);
    try cs.writeAll(fd, auth);
    try cs.writeAll(fd, "\n");
    try cs.writeAll(fd, request);
    try cs.writeAll(fd, "\n");

    var framer: cp.Framer = .{};
    defer framer.deinit(gpa);
    while (true) {
        while (framer.next() catch null) |line| {
            var pm = cp.parseMessage(gpa, line) catch return gpa.dupe(u8, line);
            const is_notif = pm.message == .notification;
            pm.deinit();
            if (!is_notif) return gpa.dupe(u8, line); // hello(notification) skip, 응답 반환
        }
        var rb: [1024]u8 = undefined;
        const n = c.read(fd, &rb, rb.len);
        if (n <= 0) break;
        try framer.push(gpa, rb[0..@intCast(n)]);
    }
    return error.NoResponse;
}

/// 지속 세션 테스트 client(5f-0b-2b-1): **한 연결**로 auth 1회 + 요청 N개 전송 → 응답 N개(hello skip) 수신. `out[i]`=
/// owned 응답(요청 순서대로). 응답이 부족하면(연결 닫힘) NoResponse.
fn clientReqPersistent(gpa: std.mem.Allocator, base: []const u8, key: []const u8, selector: ?u64, requests: []const []const u8, out: [][]u8) !void {
    std.debug.assert(out.len == requests.len);
    var db: [512]u8 = undefined;
    const dir = try cs.controlDirPath(&db, base);
    var sb: [512]u8 = undefined;
    const sp = try cs.socketPathIn(&sb, dir, key);
    const fd = c.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    if (fd < 0) return error.ClientSocket;
    defer _ = c.close(fd);
    var addr = posix.sockaddr.un{ .family = posix.AF.UNIX, .path = undefined };
    @memset(&addr.path, 0);
    @memcpy(addr.path[0..sp.len], sp);
    if (c.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) != 0) return error.ClientConnect;
    cs.setReadTimeoutMs(fd, 5000); // 18차 [3]: 서버가 기대 응답을 안 보내면 read가 무한 hang(+ th.join 무한) 대신 ReadFailed로 접힘

    const auth = try cp.serializeAuthSelf(gpa, selector, null);
    defer gpa.free(auth);
    try cs.writeAll(fd, auth);
    try cs.writeAll(fd, "\n");
    for (requests) |req| { // 요청 N개를 한 번에 보낸다(서버는 순차 처리·순서대로 응답)
        try cs.writeAll(fd, req);
        try cs.writeAll(fd, "\n");
    }

    var framer: cp.Framer = .{};
    defer framer.deinit(gpa);
    var got: usize = 0;
    while (got < out.len) {
        while (framer.next() catch null) |line| {
            var pm = cp.parseMessage(gpa, line) catch {
                out[got] = try gpa.dupe(u8, line); // parse 실패도 응답으로 취급(clientReq 결)
                got += 1;
                if (got == out.len) return;
                continue;
            };
            const is_notif = pm.message == .notification;
            pm.deinit();
            if (!is_notif) { // hello(notification) skip, 응답만 수집
                out[got] = try gpa.dupe(u8, line);
                got += 1;
                if (got == out.len) return;
            }
        }
        var rb: [1024]u8 = undefined;
        const n = c.read(fd, &rb, rb.len);
        if (n <= 0) return error.NoResponse; // 응답 부족(연결 닫힘)
        try framer.push(gpa, rb[0..@intCast(n)]);
    }
}

/// 메인 drain 흉내(app_host_abi가 할 일): pending을 꺼내 fake snapshot + capability auth(1e `dispatchAuthenticated`)로
/// 응답을 만들어 resolve. 실제 collector 대신 rt_snapshot, 실 CapabilityStore 대신 주입 store를 쓴다(라이브 배선은
/// app_host_abi 테스트가 커버). store가 빈이면 nonce 없는 요청은 self, nonce 있는 요청은 default-deny(unauthorized).
// 1e-confirm-1b: 이 fake drain 테스트는 browser 실행을 배선 안 하고 metadata/non-browser만 검증하므로 grant는 항상 빈.
const test_no_grants: cpg.PaneGrantStore = .{};

fn drainWithFakeSnapshot(server: *ControlServer, store: *const cap.CapabilityStore, snapshot: csurf.CollectorSnapshot) !usize {
    var handled: usize = 0;
    while (server.tryPopRequest()) |pending| {
        // 5f-4a-2: 세션 누적 cap 집합(serveConnection이 채운 슬라이스)을 그대로 넘긴다.
        switch (try cd.dispatchAuthenticated(server.cross_gpa, pending.request_bytes, snapshot, pending.selector, pending.cap_nonces, store, &test_no_grants, 0)) {
            .immediate => |resp| server.resolveRequest(pending, resp),
            // 이 fake drain은 browser 실행을 배선 안 함(라이브 marshal은 app_host_abi 5e-2a) — metadata 테스트는 .browser가
            // 안 온다. 방어: op.arg 해제 + null resolve(도달 시 test가 응답 없음으로 실패).
            .browser => |op| {
                server.cross_gpa.free(op.arg);
                server.resolveRequest(pending, null);
            },
            // 5f-0b-3b: browser.subscribe — app_host_abi.handleSubscribe와 동형(연결 outbound를 registry에 등록 + 응답).
            .subscribe => |s| {
                if (pending.outbound) |ob| {
                    const sid = server.subscriber_reg.subscribe(s.surface_id, s.filter, ob) catch {
                        server.resolveRequest(pending, null);
                        handled += 1;
                        continue;
                    };
                    const resp = cb.serializeSubscribeResponse(server.cross_gpa, pending.request_bytes, sid) catch null;
                    server.resolveRequest(pending, resp);
                } else server.resolveRequest(pending, null);
            },
            // 1e-confirm-1c: 미grant valid 요청 — app_host_abi와 동형으로 균일 unauthorized collapse(1c-1, held는 1c-2).
            .needs_grant => {
                const resp = cb.serializeUnauthorized(server.cross_gpa, pending.request_bytes) catch null;
                server.resolveRequest(pending, resp);
            },
        }
        handled += 1;
    }
    return handled;
}

/// 테스트 drain 루프(왕복 테스트 공통, 18차 [10] dedup): client 스레드가 완료를 `done`(atomic, release)로 알릴 때까지
/// 메인 drain을 돌린다. **atomic으로 완료를 관측**해 client 상태의 무동기 cross-thread read UB를 피한다(18차 [4]). guard
/// 상한으로 무한 방지. done 관측 뒤 caller가 join하고 결과 바이트를 읽는다(join happens-before라 그 read는 안전).
fn drainUntil(server: *ControlServer, store: *const cap.CapabilityStore, done: *std.atomic.Value(bool), snapshot: csurf.CollectorSnapshot) !void {
    var guard: usize = 0;
    while (!done.load(.acquire) and guard < 5000) : (guard += 1) {
        _ = try drainWithFakeSnapshot(server, store, snapshot);
        if (!done.load(.acquire)) std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }
}

test "server 왕복: client가 auth.self(10)+sessions.list → 메인 drain이 응답 → self scope로 10만" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const gpa = std.heap.c_allocator; // cross-thread — thread-safe
    var bb: [256]u8 = undefined;
    const base = srvTmpBase(&bb, "roundtrip");
    defer srvRmBase(base);

    var server: ControlServer = undefined;
    try server.start(std.testing.io, gpa, testing.allocator, base, "k1", "0.1.0-test", &test_caps, 8);
    defer server.stop();

    // client 스레드: auth.self(10) + sessions.list.
    const ClientT = struct {
        base: []const u8,
        resp: ?[]u8 = null,
        err: ?anyerror = null,
        done: std.atomic.Value(bool) = .init(false), // 18차 [4]: 완료 atomic
        fn run(self: *@This()) void {
            defer self.done.store(true, .release);
            const req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sessions.list\"}";
            self.resp = clientReq(std.heap.c_allocator, self.base, "k1", 10, null, req) catch |e| { // cap_nonce 없음 = self
                self.err = e;
                return;
            };
        }
    };
    var ct = ClientT{ .base = base };
    const th = try std.Thread.spawn(.{}, ClientT.run, .{&ct});

    var store: cap.CapabilityStore = .{}; // 빈 store — nonce 없는 요청은 self 경로.
    defer store.deinit(testing.allocator);
    try drainUntil(&server, &store, &ct.done, rt_snapshot); // 응답이 나올 때까지 메인 drain(실제 앱은 frame tick이 부른다)
    th.join();
    try testing.expect(ct.err == null);
    try testing.expect(ct.resp != null);
    defer std.heap.c_allocator.free(ct.resp.?);

    var pm = try cp.parseMessage(gpa, ct.resp.?);
    defer pm.deinit();
    try testing.expect(pm.message == .response);
    const arr = pm.message.response.result.?.array;
    try testing.expectEqual(@as(usize, 1), arr.items.len); // self scope(caller=10) → 10만
    try testing.expectEqual(@as(i64, 10), arr.items[0].object.get("id").?.object.get("surface_id").?.integer);
}

test "server 동시 연결(5f-0b-2a): 여러 client가 동시에 붙어도 각자 응답 + wait-group stop 깨끗" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const gpa = std.heap.c_allocator; // cross-thread
    var bb: [256]u8 = undefined;
    const base = srvTmpBase(&bb, "concurrent");
    defer srvRmBase(base);

    var server: ControlServer = undefined;
    try server.start(std.testing.io, gpa, testing.allocator, base, "k1", "0.1.0-test", &test_caps, 8);
    defer server.stop(); // wait-group이 3개 연결 스레드를 전부 join(use-after-free 없이)

    const N = 3;
    const ClientT = struct {
        base: []const u8,
        resp: ?[]u8 = null,
        err: ?anyerror = null,
        done: std.atomic.Value(bool) = .init(false), // 18차 [4]: 완료 atomic
        fn run(self: *@This()) void {
            defer self.done.store(true, .release);
            const req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sessions.list\"}";
            self.resp = clientReq(std.heap.c_allocator, self.base, "k1", 10, null, req) catch |e| { // caller=10(self scope)
                self.err = e;
                return;
            };
        }
    };
    var cts: [N]ClientT = undefined;
    var ths: [N]std.Thread = undefined;
    for (0..N) |i| cts[i] = .{ .base = base };
    for (0..N) |i| ths[i] = try std.Thread.spawn(.{}, ClientT.run, .{&cts[i]}); // 3개 동시 connect

    var store: cap.CapabilityStore = .{};
    defer store.deinit(testing.allocator);
    var all_done = false;
    var guard: usize = 0;
    while (!all_done and guard < 5000) : (guard += 1) {
        _ = try drainWithFakeSnapshot(&server, &store, rt_snapshot); // 메인 drain이 여러 연결의 pending을 처리
        all_done = true;
        for (0..N) |i| { // atomic acquire read(무동기 UB 없음)
            if (!cts[i].done.load(.acquire)) all_done = false;
        }
        if (!all_done) std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }
    for (0..N) |i| ths[i].join();

    // 셋 다 self scope 응답(surface 10 하나) — 연결당 스레드가 각자 serve, head-of-line 블로킹 없음.
    for (0..N) |i| {
        try testing.expect(cts[i].err == null);
        try testing.expect(cts[i].resp != null);
        defer std.heap.c_allocator.free(cts[i].resp.?);
        var pm = try cp.parseMessage(gpa, cts[i].resp.?);
        defer pm.deinit();
        try testing.expect(pm.message == .response);
        try testing.expectEqual(@as(usize, 1), pm.message.response.result.?.array.items.len);
    }
}

test "server 지속 세션(5f-0b-2b-1): 한 연결로 auth 1회 + 요청 2개 → 응답 2개(재연결·재auth 없이)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const gpa = std.heap.c_allocator;
    var bb: [256]u8 = undefined;
    const base = srvTmpBase(&bb, "persistent");
    defer srvRmBase(base);

    var server: ControlServer = undefined;
    try server.start(std.testing.io, gpa, testing.allocator, base, "k1", "0.1.0-test", &test_caps, 8);
    defer server.stop();

    const ClientT = struct {
        base: []const u8,
        resps: [2][]u8 = undefined,
        ok: bool = false,
        err: ?anyerror = null,
        done: std.atomic.Value(bool) = .init(false), // 18차 [4]: 완료를 atomic으로 알려 무동기 read UB 제거
        fn run(self: *@This()) void {
            defer self.done.store(true, .release); // 성공/에러 모두 완료 표시(release=이후 join의 acquire와 짝)
            const reqs = [_][]const u8{
                "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sessions.list\"}",
                "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"sessions.list\"}",
            };
            clientReqPersistent(std.heap.c_allocator, self.base, "k1", 10, &reqs, &self.resps) catch |e| {
                self.err = e;
                return;
            };
            self.ok = true;
        }
    };
    var ct = ClientT{ .base = base };
    const th = try std.Thread.spawn(.{}, ClientT.run, .{&ct});

    var store: cap.CapabilityStore = .{};
    defer store.deinit(testing.allocator);
    try drainUntil(&server, &store, &ct.done, rt_snapshot); // 순차 요청 2개를 메인 drain이 처리(완료는 atomic)
    th.join();
    try testing.expect(ct.err == null);
    try testing.expect(ct.ok);

    // 두 응답 모두 self scope(surface 10 하나) — 한 연결·재auth 없이 순차 2회 처리됐다.
    for (0..2) |i| {
        defer std.heap.c_allocator.free(ct.resps[i]);
        var pm = try cp.parseMessage(gpa, ct.resps[i]);
        defer pm.deinit();
        try testing.expect(pm.message == .response);
        try testing.expectEqual(@as(usize, 1), pm.message.response.result.?.array.items.len);
    }
}

test "server max_connections(18차 [1]): 슬롯 초과 연결은 reject(hello 후 close)·wait-group 카운터 정확·stop 깨끗" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const gpa = std.heap.c_allocator;
    var bb: [256]u8 = undefined;
    const base = srvTmpBase(&bb, "maxconn");
    defer srvRmBase(base);

    var server: ControlServer = undefined;
    // 19차 [3][4]: max_connections를 start 후 무동기 변경하면 acceptLoop(conns_mutex 아래 읽음)와 데이터 레이스다.
    // max_connections는 max_pending에서 파생되므로(start), max_pending=1을 넘겨 슬롯 1개를 만든다 — 둘째 연결은 accept 후
    // active_conns>=max_connections reject 분기를 탄다. Holder는 요청을 안 보내 큐(용량 1)를 안 쓰므로 pending=1이라도 무해.
    try server.start(std.testing.io, gpa, testing.allocator, base, "k1", "0.1.0-test", &test_caps, 1);
    defer server.stop(); // reject된 연결은 active_conns를 안 올렸어야 stop이 이 홀더 하나만 기다린다

    // Holder: connect + auth만 보내고 요청은 안 보내 hold(server connThread가 readFrame서 블록 → 슬롯 1개 점유). release
    // 후 fd close → server readFrame EOF → connThread 종료 → active_conns 0.
    const Holder = struct {
        base: []const u8,
        release: std.atomic.Value(bool) = .init(false),
        done: std.atomic.Value(bool) = .init(false),
        fn run(self: *@This()) void {
            defer self.done.store(true, .release);
            var db: [512]u8 = undefined;
            const dir = cs.controlDirPath(&db, self.base) catch return;
            var sb: [512]u8 = undefined;
            const sp = cs.socketPathIn(&sb, dir, "k1") catch return;
            const fd = c.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
            if (fd < 0) return;
            defer _ = c.close(fd);
            var addr = posix.sockaddr.un{ .family = posix.AF.UNIX, .path = undefined };
            @memset(&addr.path, 0);
            @memcpy(addr.path[0..sp.len], sp);
            if (c.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) != 0) return;
            const auth = cp.serializeAuthSelf(std.heap.c_allocator, 10, null) catch return;
            defer std.heap.c_allocator.free(auth);
            cs.writeAll(fd, auth) catch return;
            cs.writeAll(fd, "\n") catch return; // 요청은 안 보냄 → 서버가 슬롯 점유한 채 readFrame 블록
            while (!self.release.load(.acquire)) std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
        }
    };
    var holder = Holder{ .base = base };
    const hth = try std.Thread.spawn(.{}, Holder.run, .{&holder});

    // Holder가 슬롯을 잡을 때까지 대기(accept 순서 보장 — 그래야 다음 연결이 reject된다).
    var w: usize = 0;
    while (w < 1000) : (w += 1) {
        server.conns_mutex.lockUncancelable(server.io);
        const active = server.active_conns;
        server.conns_mutex.unlock(server.io);
        if (active >= 1) break;
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }

    // B: 슬롯 없음 → reject(acceptOne이 hello를 보낸 뒤 close). Peer close가 마지막 request
    // write보다 먼저 관측되면 WriteFailed, read에서 먼저 관측되면 NoResponse다. 둘 다 같은
    // "응답 없는 거부"이며 server-side slot/accounting 계약에는 차이가 없다.
    const req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sessions.list\"}";
    if (clientReq(gpa, base, "k1", 10, null, req)) |response| {
        defer gpa.free(response);
        return error.TestUnexpectedResult;
    } else |err| {
        try testing.expect(err == error.NoResponse or err == error.WriteFailed);
    }

    holder.release.store(true, .release); // Holder hold 해제 → run return → fd close → server connThread EOF 종료
    hth.join();
    // defer server.stop()이 남은 연결 스레드(Holder의 것)를 active_conns==0까지 기다려 join한다(reject된 B는 카운터
    // 안 올렸으니 무한 대기 없음 — 카운터 정확성 검증).
}

test "server 왕복: 셀렉터 없음(폰의 중계·maru 밖 shell)면 metadata:all 로 전체가 보인다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var bb: [256]u8 = undefined;
    const base = srvTmpBase(&bb, "noselector");
    defer srvRmBase(base);

    var server: ControlServer = undefined;
    try server.start(std.testing.io, std.heap.c_allocator, testing.allocator, base, "k1", "0.1.0-test", &test_caps, 8);
    defer server.stop();

    const ClientT = struct {
        base: []const u8,
        resp: ?[]u8 = null,
        err: ?anyerror = null,
        done: std.atomic.Value(bool) = .init(false), // 18차 [4]: 완료 atomic
        fn run(self: *@This()) void {
            defer self.done.store(true, .release);
            const req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sessions.list\"}";
            self.resp = clientReq(std.heap.c_allocator, self.base, "k1", null, null, req) catch |e| { // 셀렉터·cap 없음
                self.err = e;
                return;
            };
        }
    };
    var ct = ClientT{ .base = base };
    const th = try std.Thread.spawn(.{}, ClientT.run, .{&ct});

    var store: cap.CapabilityStore = .{};
    defer store.deinit(testing.allocator);
    try drainUntil(&server, &store, &ct.done, rt_snapshot);
    th.join();
    try testing.expect(ct.err == null);
    try testing.expect(ct.resp != null);
    defer std.heap.c_allocator.free(ct.resp.?);

    var pm = try cp.parseMessage(std.heap.c_allocator, ct.resp.?);
    defer pm.deinit();
    try testing.expect(pm.message == .response);
    // **앵커를 안 대면 넓다**(2026-08-29 — [보안 §8.4](../../../docs/control-plane-security.md)).
    // 예전에는 여기서 빈 목록을 기대했는데, 그 좁힘은 보호가 아니라 **폰을 막고 있었다**: 중계는
    // `MARU_PANE_ID` 가 없어 셀렉터를 못 대고, 그러면 anchor 0 으로 아무것도 안 맞아 폰 화면에
    // "세션이 없다" 만 떴다(실측). 좁힘 자체도 실효가 없었다 — 셀렉터를 훑으면 같은 것이 나온다.
    try testing.expectEqual(@as(usize, 2), pm.message.response.result.?.array.items.len);
}

// 1e-core 라이브 e2e: auth 프레임에 cap_nonce를 실으면(주입 store에 metadata:all cap) 서버가 self보다 넓은 scope로
// 응답한다 — 소켓→auth 프레임→parseAuthFrame→PendingRequest.cap_nonces→dispatchAuthenticated→resolve→scope 발급의
// 전 경로를 실 소켓 왕복으로 증명. 대조(위 "auth.self(10)" 테스트)는 cap 없이 self만 봤다.
test "server 왕복(1e): auth 프레임 cap_nonce(metadata:all) → sessions.list가 전체(10,20) 조회" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var bb: [256]u8 = undefined;
    const base = srvTmpBase(&bb, "capnonce");
    defer srvRmBase(base);

    var server: ControlServer = undefined;
    try server.start(std.testing.io, std.heap.c_allocator, testing.allocator, base, "k1", "0.1.0-test", &test_caps, 8);
    defer server.stop();

    const cap_nonce: [cap.nonce_len]u8 = [_]u8{0x5A} ** cap.nonce_len;
    const ClientT = struct {
        base: []const u8,
        nonce: [cap.nonce_len]u8,
        resp: ?[]u8 = null,
        err: ?anyerror = null,
        done: std.atomic.Value(bool) = .init(false), // 18차 [4]: 완료 atomic
        fn run(self: *@This()) void {
            defer self.done.store(true, .release);
            const req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sessions.list\"}";
            self.resp = clientReq(std.heap.c_allocator, self.base, "k1", 10, self.nonce, req) catch |e| { // anchor 10 + cap
                self.err = e;
                return;
            };
        }
    };
    var ct = ClientT{ .base = base, .nonce = cap_nonce };
    const th = try std.Thread.spawn(.{}, ClientT.run, .{&ct});

    // 주입 store: anchor 10에 묶인 metadata:all cap(라이브 앱에선 1e fd 발급이 채운다 — 여기선 하니스가 직접 주입).
    var store: cap.CapabilityStore = .{};
    defer store.deinit(testing.allocator);
    try store.issueForFd(testing.allocator, cap_nonce, .{ .surface_id = 10, .generation = 0, .scope = .{ .metadata = .all } });

    try drainUntil(&server, &store, &ct.done, rt_snapshot);
    th.join();
    try testing.expect(ct.err == null);
    try testing.expect(ct.resp != null);
    defer std.heap.c_allocator.free(ct.resp.?);

    var pm = try cp.parseMessage(std.heap.c_allocator, ct.resp.?);
    defer pm.deinit();
    try testing.expect(pm.message == .response);
    const arr = pm.message.response.result.?.array;
    try testing.expectEqual(@as(usize, 2), arr.items.len); // metadata:all → rt_snapshot 전체(10,20)
}

// 5f-4a-2 라이브 e2e: auth.self(**cap 없음**) + auth.grant(metadata:all) → 세션이 granted cap을 누적 → sessions.list가
// 그 cap으로 인가돼 **전체**(rt_snapshot 10,20 두 개)를 반환한다. auth.grant가 없었다면 self-scope(selector 10)라 1개만.
// 소켓→auth.self+auth.grant 축적→dispatchAuthenticated의 전 경로를 실 왕복으로 증명(navigate/browser cap 누적은 fake drain이
// browser op을 실행 안 해 연결을 닫으므로 여기 대신 5f-4a-1 헤드리스가 dispatch any-cap을 커버).
test "server 왕복(5f-4a-2): auth.grant로 metadata cap 누적 → sessions.list가 그 cap으로 전체 인가(누적)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const gpa = std.heap.c_allocator;
    var bb: [256]u8 = undefined;
    const base = srvTmpBase(&bb, "capgrant");
    defer srvRmBase(base);
    var server: ControlServer = undefined;
    try server.start(std.testing.io, gpa, testing.allocator, base, "k1", "0.1.0-test", &test_caps, 8);
    defer server.stop();

    const meta_nonce: [cap.nonce_len]u8 = [_]u8{0x3A} ** cap.nonce_len;
    var store: cap.CapabilityStore = .{};
    defer store.deinit(testing.allocator);
    try store.issueForFd(testing.allocator, meta_nonce, .{ .surface_id = 10, .generation = 0, .scope = .{ .metadata = .all } });

    const Client = struct {
        base: []const u8,
        m_nonce: [cap.nonce_len]u8,
        list_len: usize = 0,
        err: ?anyerror = null,
        done: std.atomic.Value(bool) = .init(false),
        fn run(self: *@This()) void {
            defer self.done.store(true, .release);
            var db: [512]u8 = undefined;
            const dir = cs.controlDirPath(&db, self.base) catch return;
            var sb: [512]u8 = undefined;
            const sp = cs.socketPathIn(&sb, dir, "k1") catch return;
            const fd = c.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
            if (fd < 0) return;
            defer _ = c.close(fd);
            var addr = posix.sockaddr.un{ .family = posix.AF.UNIX, .path = undefined };
            @memset(&addr.path, 0);
            @memcpy(addr.path[0..sp.len], sp);
            if (c.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) != 0) return;
            cs.setReadTimeoutMs(fd, 5000);
            // auth.self(surface 10, **cap 없음**) + auth.grant(metadata:all cap) + sessions.list.
            const auth = cp.serializeAuthSelf(gpa, 10, null) catch return;
            defer gpa.free(auth);
            const grant = cp.serializeAuthGrant(gpa, self.m_nonce) catch return;
            defer gpa.free(grant);
            for ([_][]const u8{ auth, grant, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sessions.list\"}" }) |frame| {
                cs.writeAll(fd, frame) catch return;
                cs.writeAll(fd, "\n") catch return;
            }
            var framer: cp.Framer = .{};
            defer framer.deinit(gpa);
            while (true) {
                while (framer.next() catch null) |line| {
                    var pm = cp.parseMessage(gpa, line) catch continue;
                    defer pm.deinit();
                    if (pm.message != .response) continue; // hello notification skip
                    if (pm.message.response.result) |r| {
                        if (r == .array) self.list_len = r.array.items.len;
                    }
                    return; // sessions.list 응답 받음
                }
                var rb: [1024]u8 = undefined;
                const n = c.read(fd, &rb, rb.len);
                if (n <= 0) {
                    self.err = error.NoResponse;
                    return;
                }
                framer.push(gpa, rb[0..@intCast(n)]) catch return;
            }
        }
    };
    var ct = Client{ .base = base, .m_nonce = meta_nonce };
    const th = try std.Thread.spawn(.{}, Client.run, .{&ct});

    var guard: usize = 0;
    while (!ct.done.load(.acquire) and guard < 5000) : (guard += 1) {
        _ = try drainWithFakeSnapshot(&server, &store, rt_snapshot);
        if (!ct.done.load(.acquire)) std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }
    th.join();
    try testing.expect(ct.err == null);
    // metadata:all cap(auth.grant로 누적)이 sessions.list를 인가 → rt_snapshot 전체(10,20) 2개. 누적 없었으면 self=1개.
    try testing.expectEqual(@as(usize, 2), ct.list_len);
}

// 5f-0b-3b 라이브 e2e: browser cap으로 auth한 client가 browser.subscribe → 서버가 SubscriberRegistry에 등록하고
// {subscriber_id} 응답. 연결을 hold해 구독 살아있음(broker.len==1) 확인 후, client가 닫으면 연결 스레드가 purgeOutbound로
// 구독을 정리(broker.len==0)한다 — subscribe dispatch + registry 등록 + 연결-drop purge의 전 경로를 실 소켓 왕복으로 증명.
test "server 왕복(5f-0b-3b): browser.subscribe → subscriber_id 응답 + 연결 drop 시 registry purge" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const gpa = std.heap.c_allocator;
    var bb: [256]u8 = undefined;
    const base = srvTmpBase(&bb, "subscribe");
    defer srvRmBase(base);

    var server: ControlServer = undefined;
    try server.start(std.testing.io, gpa, testing.allocator, base, "k1", "0.1.0-test", &test_caps, 8);
    defer server.stop();

    // 주입 store: surface 30(web_snapshot의 web surface)에 묶인 browser cap.
    const cap_nonce: [cap.nonce_len]u8 = [_]u8{0x3C} ** cap.nonce_len;
    var store: cap.CapabilityStore = .{};
    defer store.deinit(testing.allocator);
    try store.issueForFd(testing.allocator, cap_nonce, .{ .surface_id = 30, .generation = 0, .scope = .browser });

    // Client: auth(browser cap) + subscribe(surface 30, events 없음=전체) → 응답 읽고 release까지 **hold**(구독 유지).
    // clientReq는 응답 후 즉시 close라 hold를 못 해 소켓을 직접 다룬다(maxconn Holder 결).
    const Client = struct {
        base: []const u8,
        nonce: [cap.nonce_len]u8,
        resp: ?[]u8 = null,
        err: ?anyerror = null,
        subscribed: std.atomic.Value(bool) = .init(false),
        release: std.atomic.Value(bool) = .init(false),
        done: std.atomic.Value(bool) = .init(false),
        fn run(self: *@This()) void {
            defer self.done.store(true, .release);
            var db: [512]u8 = undefined;
            const dir = cs.controlDirPath(&db, self.base) catch return;
            var sb: [512]u8 = undefined;
            const sp = cs.socketPathIn(&sb, dir, "k1") catch return;
            const fd = c.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
            if (fd < 0) return;
            defer _ = c.close(fd);
            var addr = posix.sockaddr.un{ .family = posix.AF.UNIX, .path = undefined };
            @memset(&addr.path, 0);
            @memcpy(addr.path[0..sp.len], sp);
            if (c.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) != 0) return;
            cs.setReadTimeoutMs(fd, 5000);
            const auth = cp.serializeAuthSelf(std.heap.c_allocator, 30, self.nonce) catch return;
            defer std.heap.c_allocator.free(auth);
            cs.writeAll(fd, auth) catch return;
            cs.writeAll(fd, "\n") catch return;
            cs.writeAll(fd, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.subscribe\",\"params\":{\"id\":30}}") catch return;
            cs.writeAll(fd, "\n") catch return;
            var framer: cp.Framer = .{};
            defer framer.deinit(std.heap.c_allocator);
            self.resp = readResp(fd, &framer) catch |e| {
                self.err = e;
                return;
            };
            self.subscribed.store(true, .release);
            while (!self.release.load(.acquire)) std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
        }
        fn readResp(fd: c.fd_t, framer: *cp.Framer) ![]u8 {
            while (true) {
                while (framer.next() catch null) |line| {
                    var pm = cp.parseMessage(std.heap.c_allocator, line) catch return std.heap.c_allocator.dupe(u8, line);
                    const is_notif = pm.message == .notification;
                    pm.deinit();
                    if (!is_notif) return std.heap.c_allocator.dupe(u8, line); // hello skip, 응답 반환
                }
                var rb: [1024]u8 = undefined;
                const n = c.read(fd, &rb, rb.len);
                if (n <= 0) return error.NoResponse;
                try framer.push(std.heap.c_allocator, rb[0..@intCast(n)]);
            }
        }
    };
    var ct = Client{ .base = base, .nonce = cap_nonce };
    const th = try std.Thread.spawn(.{}, Client.run, .{&ct});

    // web_snapshot으로 drain(surface 30이 web이라야 browser authz 통과) — 응답이 client에 갈 때까지.
    var guard: usize = 0;
    while (!ct.subscribed.load(.acquire) and guard < 5000) : (guard += 1) {
        _ = try drainWithFakeSnapshot(&server, &store, web_snapshot);
        if (!ct.subscribed.load(.acquire)) std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }
    try testing.expect(ct.subscribed.load(.acquire));
    try testing.expect(ct.err == null);
    try testing.expect(ct.resp != null);

    // 응답 = {subscriber_id: N>=1}.
    var pm = try cp.parseMessage(gpa, ct.resp.?);
    defer pm.deinit();
    try testing.expect(pm.message == .response);
    try testing.expect(pm.message.response.result.?.object.get("subscriber_id").?.integer >= 1);

    // 연결 held → 구독 1개 살아있음(연결 스레드는 readFrame 블록 중 = purge 없음 → broker.len 무경합 read 안전).
    try testing.expectEqual(@as(usize, 1), server.subscriber_reg.broker.len());

    // release → client close → 연결 스레드 EOF → purgeOutbound → connDone. active_conns 0까지 폴링(purge 완료 보장).
    ct.release.store(true, .release);
    th.join();
    std.heap.c_allocator.free(ct.resp.?);
    var w: usize = 0;
    while (w < 5000) : (w += 1) {
        server.conns_mutex.lockUncancelable(server.io);
        const active = server.active_conns;
        server.conns_mutex.unlock(server.io);
        if (active == 0) break;
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }
    try testing.expectEqual(@as(usize, 0), server.subscriber_reg.broker.len()); // 연결 drop → 구독 purge(연결 스레드 종료 후 무경합 read)
}

// 5f-0b-3c 라이브 e2e: 구독한 client가 메인의 pushEvent(browser.navigated)를 **서버-발신 notification**으로 실제 소켓에서
// 받는지 — KVO→pushEvent→outbound→writer→소켓의 이벤트 전달 전 경로를 증명(KVO 소스만 fake=메인이 직접 pushEvent).
// 요청 없이 서버가 먼저 프레임을 미는 것(재아키텍처 β writer의 목적)을 실 왕복으로 확인.
test "server 왕복(5f-0b-3c): 구독 client가 pushEvent(navigated)를 browser.navigated notification으로 수신" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const gpa = std.heap.c_allocator;
    var bb: [256]u8 = undefined;
    const base = srvTmpBase(&bb, "event");
    defer srvRmBase(base);

    var server: ControlServer = undefined;
    try server.start(std.testing.io, gpa, testing.allocator, base, "k1", "0.1.0-test", &test_caps, 8);
    defer server.stop();

    const cap_nonce: [cap.nonce_len]u8 = [_]u8{0x3E} ** cap.nonce_len;
    var store: cap.CapabilityStore = .{};
    defer store.deinit(testing.allocator);
    try store.issueForFd(testing.allocator, cap_nonce, .{ .surface_id = 30, .generation = 0, .scope = .browser });

    const Client = struct {
        base: []const u8,
        nonce: [cap.nonce_len]u8,
        err: ?anyerror = null,
        subscribed: std.atomic.Value(bool) = .init(false),
        event_url: ?[]u8 = null,
        got_event: std.atomic.Value(bool) = .init(false),
        release: std.atomic.Value(bool) = .init(false),
        done: std.atomic.Value(bool) = .init(false),
        fn run(self: *@This()) void {
            defer self.done.store(true, .release);
            var db: [512]u8 = undefined;
            const dir = cs.controlDirPath(&db, self.base) catch return;
            var sb: [512]u8 = undefined;
            const sp = cs.socketPathIn(&sb, dir, "k1") catch return;
            const fd = c.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
            if (fd < 0) return;
            defer _ = c.close(fd);
            var addr = posix.sockaddr.un{ .family = posix.AF.UNIX, .path = undefined };
            @memset(&addr.path, 0);
            @memcpy(addr.path[0..sp.len], sp);
            if (c.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) != 0) return;
            cs.setReadTimeoutMs(fd, 5000);
            const auth = cp.serializeAuthSelf(std.heap.c_allocator, 30, self.nonce) catch return;
            defer std.heap.c_allocator.free(auth);
            cs.writeAll(fd, auth) catch return;
            cs.writeAll(fd, "\n") catch return;
            cs.writeAll(fd, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.subscribe\",\"params\":{\"id\":30,\"events\":[\"navigated\"]}}") catch return;
            cs.writeAll(fd, "\n") catch return;
            var framer: cp.Framer = .{};
            defer framer.deinit(std.heap.c_allocator);
            // phase 1: 구독 응답(response) 수신 → subscribed. phase 2: browser.navigated notification 수신 → event_url.
            var phase2 = false;
            while (true) {
                const line = nextLine(fd, &framer) catch |e| {
                    self.err = e;
                    return;
                } orelse return; // EOF
                defer std.heap.c_allocator.free(line);
                var pm = cp.parseMessage(std.heap.c_allocator, line) catch continue;
                defer pm.deinit();
                if (!phase2) {
                    if (pm.message == .response) {
                        self.subscribed.store(true, .release);
                        phase2 = true;
                    } // 그 외(hello notification)는 skip
                } else if (pm.message == .notification and std.mem.eql(u8, pm.message.notification.method, "browser.navigated")) {
                    if (pm.message.notification.params) |p| {
                        if (p == .object) {
                            if (p.object.get("url")) |u| {
                                if (u == .string) self.event_url = std.heap.c_allocator.dupe(u8, u.string) catch null;
                            }
                        }
                    }
                    self.got_event.store(true, .release);
                    break;
                }
            }
            while (!self.release.load(.acquire)) std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
        }
        fn nextLine(fd: c.fd_t, framer: *cp.Framer) !?[]u8 {
            while (true) {
                if (framer.next() catch null) |line| return try std.heap.c_allocator.dupe(u8, line);
                var rb: [1024]u8 = undefined;
                const n = c.read(fd, &rb, rb.len);
                if (n <= 0) return null;
                try framer.push(std.heap.c_allocator, rb[0..@intCast(n)]);
            }
        }
    };
    var ct = Client{ .base = base, .nonce = cap_nonce };
    const th = try std.Thread.spawn(.{}, Client.run, .{&ct});

    // drain until 구독 완료.
    var guard: usize = 0;
    while (!ct.subscribed.load(.acquire) and guard < 5000) : (guard += 1) {
        _ = try drainWithFakeSnapshot(&server, &store, web_snapshot);
        if (!ct.subscribed.load(.acquire)) std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }
    try testing.expect(ct.subscribed.load(.acquire));

    // 메인이 KVO 대신 직접 pushEvent(navigated) — 구독 client에 서버-발신 notification으로 흘러야 한다.
    var w: usize = 0;
    while (!ct.got_event.load(.acquire) and w < 5000) : (w += 1) {
        _ = server.subscriber_reg.pushEvent(gpa, 30, .{ .navigated = "https://newpage/" });
        if (!ct.got_event.load(.acquire)) std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }
    try testing.expect(ct.got_event.load(.acquire));
    try testing.expect(ct.err == null);
    try testing.expect(ct.event_url != null);
    defer if (ct.event_url) |u| std.heap.c_allocator.free(u);
    try testing.expectEqualStrings("https://newpage/", ct.event_url.?); // 그 url이 실제로 실려 왔다

    ct.release.store(true, .release);
    th.join();
}

test "server: start 실패 없이 즉시 stop해도 accept 스레드가 깨끗이 join(요청 0건)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var bb: [256]u8 = undefined;
    const base = srvTmpBase(&bb, "quickstop");
    defer srvRmBase(base);
    var server: ControlServer = undefined;
    try server.start(std.testing.io, std.heap.c_allocator, testing.allocator, base, "k1", "0.1.0-test", &test_caps, 8);
    server.stop(); // poll_interval(200ms) 안에 join — 무한 대기 없음(테스트가 hang하면 실패)
}

test "readFrame(#3): oversize 프레임 → payload_too_large를 outbound에 push, writer가 소켓에 전달(end-to-end 왕복)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const gpa = std.heap.c_allocator; // writer 스레드가 cross-thread로 frame.bytes free
    // socketpair로 양방향 연결(서버측=fds[0], 클라이언트측=fds[1]) — accept-loop 없이 readFrame+writer 계약을 결정론적 검증.
    var fds: [2]c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    defer _ = c.close(fds[0]);
    defer _ = c.close(fds[1]);

    // 클라이언트측이 max_frame(16)을 넘는 완결 프레임을 보낸다(20B + \n).
    try cs.writeAll(fds[1], "0123456789abcdefghij\n");

    // readFrame은 too_large 에러를 **outbound에 push**한다(직접 소켓 write는 writer 스레드와 경합=단일 writer 불변 위반).
    var srv: ControlServer = undefined;
    srv.cross_gpa = gpa;
    var conn = cs.Connection{ .fd = fds[0] };
    var framer: cp.Framer = .{ .max_frame = 16 };
    defer framer.deinit(gpa);
    var outbound = OutboundChannel.init(std.testing.io, 8);
    defer outbound.deinit(gpa);
    try testing.expect(srv.readFrame(&conn, &framer, &outbound) == null); // 프레임 버림(sticky too_large) + 에러 push

    // 19차 [oversize 왕복 복원]: writer 스레드가 outbound를 drain해 fds[0]에 write하면 클라이언트측 fds[1]이
    // payload_too_large **한 줄(+개행 프레이밍)**을 받는다 — readFrame push → writer 직렬화·전달까지 end-to-end. close로
    // writer가 1프레임 drain 후 종료하고, join으로 write 완료를 기다린 뒤 읽어 결정론적(타이밍 레이스 없음).
    const writer = try std.Thread.spawn(.{}, ControlServer.writerThread, .{ &srv, fds[0], &outbound });
    outbound.close();
    writer.join();

    cs.setReadTimeoutMs(fds[1], 1000); // 회귀(안 씀) 시 무한 블록 대신 즉시 실패
    var cf: cp.Framer = .{};
    defer cf.deinit(gpa);
    var resp_line: ?[]const u8 = null;
    var guard: usize = 0;
    while (resp_line == null and guard < 100) : (guard += 1) {
        if (try cf.next()) |line| {
            resp_line = line;
            break;
        }
        var rb: [512]u8 = undefined;
        const n = c.read(fds[1], &rb, rb.len);
        if (n <= 0) break;
        try cf.push(gpa, rb[0..@intCast(n)]);
    }
    var pm = try cp.parseMessage(gpa, resp_line.?);
    defer pm.deinit();
    try testing.expect(pm.message == .response);
    try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.payload_too_large)), pm.message.response.err.?.code);
}
