//! control_server — 세션 컨트롤 플레인 **라이브 서버**(Track C A2b). 앱 인스턴스 전역 소켓을 열고, accept 스레드가
//! 요청을 **메인 프레임루프로 marshal**해 실 collector/dispatch로 응답하게 배선한다. 단일 출처:
//! docs/control-plane.md §5(단일 디스패치=메인 marshal·출력 직송 제외)·§8.4(A2b auth 한계)·§16, docs/
//! io-render-threading.md §8.8(lock-order·교차큐 데드락 선례).
//!
//! **범위(A2b = 라이브 서버 + marshal, 이 파일):**
//!  - 앱 전역 unix socket bind + accept 스레드(heap-pin — 스레드가 &self를 잡으므로 caller가 주소를 고정).
//!  - accept 스레드는 **accept/parse/framing/write만**(§5): 연결마다 peer-cred(same-uid, 1b acceptOne) + hello →
//!    auth 셀렉터 프레임 + 요청 프레임 읽기 → `PendingRequest`를 **메인 marshal 큐**에 push → 메인이 채운 응답을
//!    기다렸다가 소켓에 write(락 밖). 코어·트리·collector·dispatch는 **절대 accept 스레드가 만지지 않는다**.
//!  - 메인 drain(app_host_abi가 tick마다 호출): `tryPopRequest`로 요청을 꺼내 실 collector + auth + dispatch(1d)로
//!    응답 바이트를 만들고 `resolveRequest`로 pending에 채워 accept 스레드를 깨운다.
//!
//! **범위 밖:** subscribeOutput 출력 직송(§5, 별도), full self-origin tty 검증(1g), capability fd 실 발급(1e),
//!  실 collector 조립·auth 판정(그건 app_host_abi가 AppSession을 알기에 거기서 — 이 모듈은 AppSession 비의존 generic).
//!
//! **§8.8 lock-order 불변식 엄수:** accept 스레드는 `core_mutex`를 보유하지 않은 채로만 marshal 큐에 push/wait한다.
//!  메인은 collectSessionInto 안에서만 core_mutex를 (짧게) 잡고, 그 락을 쥔 채 marshal 큐에 push/wait하지 않는다.
//!  응답 write는 accept 스레드에서 락 없이 한다(§5). 교차-큐 순환대기 없음(요청 큐 drainer=메인, pending signal도
//!  메인, accept 스레드는 아무 락도 안 쥔 채 대기).
//!
//! **cross-thread 할당:** 요청/응답 바이트는 accept 스레드↔메인을 오가므로 **thread-safe allocator**(`cross_gpa`,
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

/// 메인이 accept 스레드에 응답을 돌려주는 rendezvous 단위. accept 스레드의 serve 스택에 살며(대기 동안 유효),
/// marshal 큐는 `*PendingRequest`만 담는다. `request_bytes`는 accept 스레드가 `cross_gpa`로 소유(serve 끝에 해제),
/// 메인 drain은 **빌려 읽기만** 한다. `response`는 메인 drain이 `cross_gpa`로 채우고 accept 스레드가 해제한다.
pub const PendingRequest = struct {
    /// 요청 프레임 바이트(개행 제외). accept 스레드 소유(cross_gpa), 메인은 read-only.
    request_bytes: []const u8,
    /// caller가 주장한 self surface_id(auth.self 셀렉터, §8.4). 없으면 null(maru 밖 shell 등).
    selector: ?u64,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    state: State = .pending,
    /// 메인 drain이 채우는 응답 바이트(cross_gpa 소유). accept 스레드가 write 후 해제. cancelled면 null.
    response: ?[]u8 = null,

    pub const State = enum { pending, done, cancelled };

    /// accept 스레드: 메인이 resolve/cancel할 때까지 대기하고 최종 상태를 돌려준다.
    fn waitResolved(self: *PendingRequest) State {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (self.state == .pending) self.cond.waitUncancelable(self.io, &self.mutex);
        return self.state;
    }

    /// 메인 drain: 응답을 채우고 accept 스레드를 깨운다(response = cross_gpa 소유, accept 스레드가 해제).
    /// response=null이면 accept 스레드가 응답 없이 연결을 닫는다(예: 메인 drain의 OOM — pending을 반드시 깨워야
    /// accept 스레드가 무한 대기하지 않는다).
    fn resolve(self: *PendingRequest, response: ?[]u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.state == .pending) {
            self.state = .done;
            self.response = response;
        }
        self.cond.broadcast(self.io);
    }

    /// close: 서버 종료로 이 요청을 버린다(accept 스레드가 응답 없이 abandon). response는 안 채운다.
    fn cancel(self: *PendingRequest) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.state == .pending) self.state = .cancelled;
        self.cond.broadcast(self.io);
    }
};

pub const QueueError = error{ QueueClosed, ZeroCapacity, OutOfMemory };

/// accept 스레드 → 메인 marshal 큐(bounded FIFO of `*PendingRequest`). `PtyEventQueue` 결. accept 스레드가 push,
/// 메인이 `tryPop`. `close`는 대기 중 pending을 전부 cancel해 accept 스레드를 깨운다(종료 시 무한 대기 방지).
///
/// **설계 노트(#6/#8 — 의도적 재사용, tracked follow-up)**: accept가 serial(단일 스레드가 한 연결을 끝까지 serve한 뒤
/// 다음을 accept)이라 marshal in-flight는 항상 ≤1이다 → 이론상 단일 슬롯이면 충분하고 ring FIFO는 over-built다. 그럼에도
/// (a) `PtyEventQueue`(docs/io-render-threading.md)의 **검증된** bounded-FIFO + Io.Mutex/Condition + close-cancel 스레딩
/// 패턴을 재구현 없이 그대로 재사용하는 게 안전하고, (b) per-tick drain 예산(§5)이 여러 요청을 파이프라인할 여지를 남기며,
/// (c) 재작성은 검증된 스레딩 코드를 흔드는 리스크라 **의도적으로** FIFO를 유지한다. `PtyEventQueue`를 generic
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

    /// accept 스레드: 포화면 backpressure 대기(§8.8: **core_mutex 미보유** 상태라 blocking push 안전 — accept 스레드는
    /// 어떤 락도 안 쥔다). closed면 QueueClosed(호출자가 요청을 abandon).
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
    /// 다음 tick에서 처리된다(accept 스레드는 그동안 waitResolved에서 대기 — 손실 없음).
    pub fn hasPending(self: *ControlRequestQueue) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.len > 0;
    }

    /// 종료: 새 push를 막고, **큐에 남은 pending을 전부 cancel**해 대기 중 accept 스레드를 깨운다. lock 순서는
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

pub const StartError = cs.BindError || std.Thread.SpawnError || QueueError;

/// A2b 라이브 서버. **start() 후 절대 이동/복사 금지**(accept 스레드가 `&self`를 잡는다 — LivePtySession 핀 선례).
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
    /// accept 스레드가 stuck client에 무한 대기하지 않게 하는 read 타임아웃(serial serve + 깨끗한 join 요건).
    read_timeout_ms: u32 = 5000,
    /// accept blocking을 gate하는 poll 간격(종료 시 이 간격 안에 closing 확인 → join). 짧을수록 종료 빠름·wakeup 잦음.
    poll_interval_ms: i32 = 200,

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
        };
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
    /// 채우고 accept 스레드를 깨운다. accept 스레드가 소켓에 write 후 해제한다. response=null이면 응답 없이 종료
    /// (메인 OOM 등 — pending은 반드시 resolve해야 accept 스레드가 무한 대기하지 않는다).
    pub fn resolveRequest(self: *ControlServer, pending: *PendingRequest, response: ?[]u8) void {
        _ = self;
        pending.resolve(response);
    }

    /// 종료: accept 스레드에 closing을 알리고 join한 뒤 소켓/큐를 해제한다(deinit 계약: 스레드 join·소켓 close).
    pub fn stop(self: *ControlServer) void {
        self.closing.store(true, .release);
        self.queue.close(); // 대기 pending cancel → accept 스레드가 wait에서 깨어나 abandon
        if (self.thread) |thread| {
            thread.join(); // poll_interval 안에 closing을 봐 루프를 나온다(mid-serve면 read_timeout까지)
            self.thread = null;
        }
        self.server.deinit();
        self.queue.deinit();
        self.* = undefined;
    }

    // ── accept 스레드(§5: accept/parse/framing/write만) ──────────────────────────────────────────────────────
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
            var conn = self.server.acceptOne(self.cross_gpa, .{
                .server_version = self.hello_version,
                .capabilities = self.hello_caps,
            }) catch continue; // peer uid 불일치·accept 실패 등은 그 연결만 버리고 계속.
            self.serveConnection(&conn);
            conn.deinit();
        }
    }

    /// 한 연결을 serve: read 타임아웃 → auth 셀렉터 프레임 + 요청 프레임 읽기 → marshal → 메인 응답 대기 → write.
    /// 코어/트리/collector 접근 0(전부 메인 marshal). cross_gpa만 쓴다(thread-safe).
    fn serveConnection(self: *ControlServer, conn: *cs.Connection) void {
        cs.setReadTimeoutMs(conn.fd, self.read_timeout_ms);
        cs.setWriteTimeoutMs(conn.fd, self.read_timeout_ms); // #2: 응답을 안 읽는 client에 write가 무한 블록하지 않게(read와 대칭).
        var framer: cp.Framer = .{};
        defer framer.deinit(self.cross_gpa);

        // 프레임 1 = auth.self 셀렉터(§8.4 1단계). 없거나 손상이면 selector=null(서버가 self를 안 줌).
        const auth_line = self.readFrame(conn, &framer) orelse return;
        const selector = cp.parseAuthSelector(self.cross_gpa, auth_line);

        // 프레임 2 = 요청. Framer 슬라이스는 다음 read에 무효화되므로 marshal 전에 dupe(대기 동안 유효 보장).
        const req_line = self.readFrame(conn, &framer) orelse return;
        const req_copy = self.cross_gpa.dupe(u8, req_line) catch return;
        defer self.cross_gpa.free(req_copy); // done/cancelled/에러 모두 이 스택 프레임 끝에서 해제(대기 후라 안전)

        var pending: PendingRequest = .{ .request_bytes = req_copy, .selector = selector, .io = self.io };
        self.queue.push(&pending) catch return; // QueueClosed(종료) → abandon

        switch (pending.waitResolved()) {
            .cancelled => return, // 서버 종료 — 응답 없이 abandon
            .pending => return, // 도달 불가(waitResolved는 pending에서 안 나감)
            .done => {
                if (pending.response) |resp| {
                    defer self.cross_gpa.free(resp);
                    cs.writeAll(conn.fd, resp) catch return;
                    cs.writeAll(conn.fd, "\n") catch return;
                }
            },
        }
    }

    /// 완결 프레임 하나를 조립해 돌려준다(1a Framer + 1b Connection.readInto 재사용). 슬라이스는 다음 read/next까지
    /// 유효. null = EOF/read 에러(타임아웃 포함)/OOM/payload-too-large → serve 중단(연결 abandon).
    fn readFrame(self: *ControlServer, conn: *cs.Connection, framer: *cp.Framer) ?[]const u8 {
        while (true) {
            const maybe = framer.next() catch {
                // #3 §4.3: frame이 max를 초과하면 조용히 버리지 않고 payload_too_large(-32001) 응답을 쓴 뒤 연결을 버린다
                // (serveReadOnly와 동일 계약 — 응답 write는 cross_gpa·소켓 스레드, best-effort로 실패는 무시). id는 아직
                // 못 읽었으므로 `.null`(JSON-RPC 관례). 응답 후에도 이 연결은 abandon한다(sticky too_large라 재조립 불가).
                cs.writeErrorResponse(conn.fd, self.cross_gpa, .payload_too_large) catch {};
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
    ctx.pending.resolve(resp);
    th.join();
    try testing.expect(ctx.got != null);
    try testing.expectEqualStrings("the-response", ctx.got.?);
    testing.allocator.free(resp);
}

// ── 전체 라이브 서버 왕복(accept 스레드 + marshal + 메인 drain + 응답) ──
const cd = maru.session.control_dispatch;
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

/// 테스트 client: connect → auth.self(surface_id) → 요청 → hello skip → 응답 한 줄(owned).
fn clientReq(gpa: std.mem.Allocator, base: []const u8, key: []const u8, selector: ?u64, request: []const u8) ![]u8 {
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

    const auth = try cp.serializeAuthSelf(gpa, selector);
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

/// 메인 drain 흉내(app_host_abi가 할 일): pending을 꺼내 fake snapshot + selector auth(scope=self) + dispatch로
/// 응답을 만들어 resolve. 실제 collector 대신 rt_snapshot을 쓴다(collector 배선은 app_host_abi 테스트가 커버).
fn drainWithFakeSnapshot(server: *ControlServer) !usize {
    var handled: usize = 0;
    while (server.tryPopRequest()) |pending| {
        const caller = pending.selector orelse 0;
        const resp = try cd.dispatchReadOnly(server.cross_gpa, pending.request_bytes, rt_snapshot, caller, .self);
        server.resolveRequest(pending, resp);
        handled += 1;
    }
    return handled;
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
        fn run(self: *@This()) void {
            const req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sessions.list\"}";
            self.resp = clientReq(std.heap.c_allocator, self.base, "k1", 10, req) catch |e| {
                self.err = e;
                return;
            };
        }
    };
    var ct = ClientT{ .base = base };
    const th = try std.Thread.spawn(.{}, ClientT.run, .{&ct});

    // 메인 drain 루프(응답이 나올 때까지 짧게 폴링 — 실제 앱은 frame tick이 부른다).
    var got = false;
    var guard: usize = 0;
    while (!got and guard < 2000) : (guard += 1) {
        _ = try drainWithFakeSnapshot(&server);
        got = ct.resp != null or ct.err != null;
        if (!got) std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }
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

test "server 왕복: 셀렉터 없음(maru 밖 shell)면 self scope로 아무것도 안 보인다(빈 목록)" {
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
        fn run(self: *@This()) void {
            const req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sessions.list\"}";
            self.resp = clientReq(std.heap.c_allocator, self.base, "k1", null, req) catch |e| { // 셀렉터 없음
                self.err = e;
                return;
            };
        }
    };
    var ct = ClientT{ .base = base };
    const th = try std.Thread.spawn(.{}, ClientT.run, .{&ct});

    var guard: usize = 0;
    while (ct.resp == null and ct.err == null and guard < 2000) : (guard += 1) {
        _ = try drainWithFakeSnapshot(&server);
        if (ct.resp == null and ct.err == null) std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }
    th.join();
    try testing.expect(ct.err == null);
    try testing.expect(ct.resp != null);
    defer std.heap.c_allocator.free(ct.resp.?);

    var pm = try cp.parseMessage(std.heap.c_allocator, ct.resp.?);
    defer pm.deinit();
    try testing.expect(pm.message == .response);
    try testing.expectEqual(@as(usize, 0), pm.message.response.result.?.array.items.len); // 셀렉터 0 → self 필터로 빈 목록
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

test "readFrame(#3): oversize 프레임은 payload_too_large(-32001) 응답을 쓴 뒤 null(연결 abandon, 왕복)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    // socketpair로 양방향 연결(서버측=fds[0], 클라이언트측=fds[1]) — accept-loop 없이 readFrame 계약만 결정론적으로 검증.
    var fds: [2]c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    defer _ = c.close(fds[0]);
    defer _ = c.close(fds[1]);

    // 클라이언트측이 max_frame(16)을 넘는 완결 프레임을 보낸다(20B + \n).
    try cs.writeAll(fds[1], "0123456789abcdefghij\n");

    // readFrame은 self.cross_gpa만 읽으므로(나머지 필드 미접근) 최소 구성으로 계약만 태운다.
    var srv: ControlServer = undefined;
    srv.cross_gpa = testing.allocator;
    var conn = cs.Connection{ .fd = fds[0] };
    var framer: cp.Framer = .{ .max_frame = 16 };
    defer framer.deinit(testing.allocator);
    try testing.expect(srv.readFrame(&conn, &framer) == null); // 프레임 버림(sticky too_large)

    // 클라이언트측이 payload_too_large(-32001) 응답을 받는다(왕복 — 조용히 abandon하지 않는다는 증거). 응답도
    // 2-write(bytes, `\n`)라 완결 프레임까지 read 루프로 재조립한다(단일 read가 개행 앞에서 끊길 수 있음). read
    // 타임아웃을 걸어, 응답을 안 쓰는 회귀(수정 제거) 시 무한 블록 대신 read가 즉시 빠져 resp_line==null로 깨끗이 실패한다.
    cs.setReadTimeoutMs(fds[1], 1000);
    var cf: cp.Framer = .{};
    defer cf.deinit(testing.allocator);
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
        try cf.push(testing.allocator, rb[0..@intCast(n)]);
    }
    var pm = try cp.parseMessage(testing.allocator, resp_line.?);
    defer pm.deinit();
    try testing.expect(pm.message == .response);
    try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.payload_too_large)), pm.message.response.err.?.code);
}
