//! Single-thread daemon poll owner for one listener and at most 32 readiness clients.
//!
//! Kernel fd readiness, PTY-output wakeups, and periodic metadata cadence enter the same
//! `ReactorCore.nextReady` round-robin selector. One iteration services at most one client turn, so a readable flood,
//! blocked writer, or many attached streams cannot monopolize the host owner.

const std = @import("std");
const builtin = @import("builtin");
const host_log = @import("host_log.zig");
const c = std.c;
const posix = std.posix;
const connection_slot = @import("connection_slot.zig");
const connection_turn = @import("connection_turn.zig");
const process_seal_service = @import("process_seal_service.zig");
const server_mod = @import("server.zig");
const socket_server = @import("socket_server.zig");

extern "c" fn usleep(usec: c_uint) c_int;

pub const max_clients: usize = connection_slot.max_connections;
pub const cadence_ns: u64 = @as(u64, @intCast(socket_server.SocketServer.delta_tick_ms)) *
    std.time.ns_per_ms;

pub const Outcome = enum {
    idle,
    progress,
    listener_broken,
    authority_lost,
    upgrade_ready,
};

pub const TelemetrySnapshot = struct {
    accounting: connection_slot.ReactorCore.AccountingSnapshot,
    pressure_reclaims: usize,
    stalled_clients: usize,
    active_clients: usize,
    total_admitted: usize,
    pollout_absent_count: usize,
    first_stall_connection_id: u64,
    first_stall_ns: u64,
    first_stall_send_buffer_bytes: u64,
    stale_client_observations: usize,
};

/// host가 client 연결을 닫는 이유. **예상되지 않은 종료만 로그로 남긴다** — 클라이언트가 스스로 닫거나 host가
/// 내려가는 것은 정상 경로라, 그것까지 찍으면 CLI가 붙었다 끊을 때마다 한 줄씩 쌓여(실측: `maru host status`
/// 한 번에 한 줄) 정작 봐야 할 backpressure 희생이 노이즈에 묻힌다.
pub const ClientCloseReason = enum {
    /// 클라이언트가 스스로 연결을 닫았다(GUI 종료, CLI 명령 완료). 정상.
    client_closing,
    /// **소켓이 끊겨** host 가 그것을 감지하고 닫았다. GUI 는 살아 있는데 연결만 사라진 경우다.
    ///
    /// 전에는 이것이 `client_closing` 과 한 사유로 뭉쳐 있었고, 그 사유가 `isExpected()` 라 host 는
    /// 아무것도 남기지 않았다. 그래서 GUI 가 `connection_eof` incident 를 남긴 사건을 host 쪽에서
    /// 대조할 수단이 없었다 — **양쪽이 서로 «상대가 닫았다»고 기록하는** 모양이 되어 원인을 좁히지
    /// 못했다(2026-09-04 실측, GUI last_success_request_id=136440 뒤 끊김).
    peer_broken,
    /// host 자신이 내려간다. 정상.
    host_shutdown,
    /// 메모리 압박으로 이 연결의 화면 큐를 회수하다 닫았다. 사용자에게는 **갑작스러운 세션 단절**로 보인다.
    screen_pressure,
    /// 화면을 받아가지 못해 다른 client를 막던 observer를 끊었다.
    observer_offender,
    /// 테스트 전용 경로.
    testing,

    fn isExpected(self: ClientCloseReason) bool {
        return switch (self) {
            .client_closing, .host_shutdown, .testing => true,
            .peer_broken, .screen_pressure, .observer_offender => false,
        };
    }
};

pub const Owner = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    server: *socket_server.SocketServer,
    reactor: *connection_slot.ReactorCore,
    clients: [max_clients]?*connection_turn.Client = [_]?*connection_turn.Client{null} ** max_clients,
    producer_remaining: [max_clients]usize = [_]usize{0} ** max_clients,
    next_cadence_ns: u64,
    next_overflow_accept_ns: u64 = 0,
    accept_retry_after_ns: u64 = 0,
    admin_admission: server_mod.AdminAdmission = .{},
    armed_upgrade: ?connection_turn.ArmedUpgrade = null,
    total_admitted: usize = 0,
    overflow_rejected: usize = 0,
    total_pressure_reclaims: usize = 0,
    pollout_absent_count: usize = 0,
    first_stall_connection_id: u64 = 0,
    first_stall_ns: u64 = 0,
    first_stall_send_buffer_bytes: u64 = 0,
    controller_transition_admission_fail_once: bool = false,
    resize_admission_fail_once: bool = false,
    process_identity: ?process_seal_service.ReadyIdentity,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        server: *socket_server.SocketServer,
    ) error{ OutOfMemory, ProcessIdentityUnavailable }!Owner {
        // Shipping owners cannot exist without the daemon-ready process seal. Tests that exercise
        // unrelated poll mechanics may omit it, but then only the test build accepts that owner.
        const process_identity = process_seal_service.currentReadyIdentity() catch
            if (builtin.is_test) null else return error.ProcessIdentityUnavailable;
        const reactor = try connection_slot.ReactorCore.create(allocator);
        const now_ns = monotonicNow(io);
        return .{
            .allocator = allocator,
            .io = io,
            .server = server,
            .reactor = reactor,
            .process_identity = process_identity,
            .next_cadence_ns = now_ns +| cadence_ns,
        };
    }

    pub fn deinit(self: *Owner) void {
        self.destroyAll();
        self.reactor.destroy();
        self.* = undefined;
    }

    pub fn activeCount(self: *const Owner) usize {
        return self.reactor.activeCount();
    }

    /// Product owner-turn fence. The fatal leaf is intentionally shared by daemon and restore so
    /// a fork child cannot unwind inherited socket/path/runtime cleanup.
    pub fn requireCurrentProcessOrFatal(self: *const Owner) void {
        if (!self.validateProcessIdentity())
            process_seal_service.fatalIntegrity(.proof_loss);
    }

    /// Private process-fixture telemetry. 제품 wire/CLI를 넓히지 않고도 실제 poll owner가
    /// 관측한 stall과 canonical ledger를 같은 owner turn에서 읽게 한다.
    pub fn telemetrySnapshot(self: *const Owner) TelemetrySnapshot {
        var stalled: usize = 0;
        var stale: usize = 0;
        for (self.clients) |maybe_client| {
            const client = maybe_client orelse continue;
            const slot = self.reactor.get(client.admission) catch {
                stale += 1;
                continue;
            };
            if (slot.writeStallObserved()) stalled += 1;
        }
        return .{
            .accounting = self.reactor.accountingSnapshot(),
            .pressure_reclaims = self.total_pressure_reclaims,
            .stalled_clients = stalled,
            .active_clients = self.activeCount(),
            .total_admitted = self.total_admitted,
            .pollout_absent_count = self.pollout_absent_count,
            .first_stall_connection_id = self.first_stall_connection_id,
            .first_stall_ns = self.first_stall_ns,
            .first_stall_send_buffer_bytes = self.first_stall_send_buffer_bytes,
            .stale_client_observations = stale,
        };
    }

    pub fn resetFixtureStallTelemetry(self: *Owner) void {
        self.pollout_absent_count = 0;
        self.first_stall_connection_id = 0;
        self.first_stall_ns = 0;
        self.first_stall_send_buffer_bytes = 0;
        self.reactor.resetFixturePeaksToCurrent();
    }

    /// Private daemon-fixture fault seam. The caller is an in-process `FixtureProbe`, never a
    /// wire method: close every currently admitted peer through the canonical owner teardown so
    /// an actual GUI observes EOF while the daemon, PTYs, registry, and listener stay alive.
    pub fn disconnect_fixture_clients(self: *Owner) void {
        self.destroyAll();
    }

    fn syncClientCount(self: *Owner) void {
        self.server.host_status.client_count = self.activeCount();
    }

    pub fn takeArmedUpgrade(self: *Owner) ?connection_turn.ArmedUpgrade {
        const marker = self.armed_upgrade;
        self.armed_upgrade = null;
        return marker;
    }

    /// Polls the listener and all current clients once. The timeout is capped by the next producer
    /// cadence; pending synthetic work forces a zero-time poll so the cursor sweep finishes without
    /// another 20 ms delay.
    pub fn pollOnce(self: *Owner, outer_timeout_ms: i32) error{OutOfMemory}!Outcome {
        // This must precede clock, gate, reactor, listener and client access. A fork child inherits
        // all of them and must not consume a parent connection before its PID mismatch is noticed.
        if (!self.validateProcessIdentity()) return .authority_lost;
        if (self.armed_upgrade != null) return .upgrade_ready;
        // **폴 회차마다 본다 — 출력이 있을 때가 아니라.** 선언은 client 갈래로 오는데 조정을
        // 출력 wake 갈래에 두었더니, 출력이 없는 세션은 폰이 알려도 영영 안 좁아졌다. 폰은
        // 읽기 전용이라 스스로 출력을 만들 수도 없다(적대적 검증 4회차, 실측으로 잡았다).
        // 조정할 것이 없으면 정수 하나만 보고 나온다(`viewportDirty`).
        reconcileViewports(self);
        const before_poll_ns = monotonicNow(self.io);
        self.scheduleCadence(before_poll_ns);

        var poll_fds: [max_clients + 2]c.pollfd = undefined;
        var poll_slots: [max_clients]?usize = [_]?usize{null} ** max_clients;
        // Once an upgrade closes admission, the listener must leave the readiness set. Accepting
        // and immediately rejecting peers would still consume fd/client budgets while the upgrade
        // reply is draining.
        const gate_open = if (self.server.admission_gate) |gate| gate.snapshot().open else true;
        const admission_open = acceptAllowed(
            gate_open,
            self.reactor.activeCount(),
            before_poll_ns,
            self.accept_retry_after_ns,
            self.next_overflow_accept_ns,
        );
        poll_fds[0] = .{
            .fd = if (admission_open) self.server.listen_fd else -1,
            .events = if (admission_open) c.POLL.IN else 0,
            .revents = 0,
        };
        poll_fds[1] = .{
            .fd = self.server.owner_wake_fd,
            .events = if (self.server.owner_wake_fd >= 0) c.POLL.IN else 0,
            .revents = 0,
        };
        var poll_count: usize = 2;
        for (self.clients, 0..) |maybe_client, slot_index| {
            const client = maybe_client orelse continue;
            if (!gate_open and !client.isUpgradeDraining()) continue;
            var events: c_short = c.POLL.IN;
            if (client.wantsWrite()) events |= c.POLL.OUT;
            poll_fds[poll_count] = .{ .fd = client.fd, .events = events, .revents = 0 };
            poll_slots[poll_count - 2] = slot_index;
            poll_count += 1;
        }
        const timeout_ms = self.pollTimeout(before_poll_ns, outer_timeout_ms);
        const rc = c.poll(&poll_fds, @intCast(poll_count), timeout_ms);
        if (rc < 0) {
            if (posix.errno(rc) == .INTR) return .idle;
            return .listener_broken;
        }
        const now_ns = monotonicNow(self.io);
        self.scheduleCadence(now_ns);

        var progressed = false;
        if (poll_fds[0].revents & c.POLL.IN != 0) {
            try self.acceptOne(now_ns);
            progressed = true;
        } else if (poll_fds[0].revents != 0) {
            return .listener_broken;
        }

        if (poll_fds[1].revents & c.POLL.IN != 0) {
            if (!self.server.drainOwnerWake()) return .listener_broken;
            self.server.tickOwner();
            self.scheduleProducerNow(now_ns);
            progressed = true;
        } else if (poll_fds[1].revents != 0) {
            return .listener_broken;
        }

        var ready: [max_clients]bool = [_]bool{false} ** max_clients;
        var read_ready: [max_clients]bool = [_]bool{false} ** max_clients;
        var write_ready: [max_clients]bool = [_]bool{false} ** max_clients;
        var peer_broken: [max_clients]bool = [_]bool{false} ** max_clients;
        var poll_index: usize = 2;
        while (poll_index < poll_count) : (poll_index += 1) {
            const slot_index = poll_slots[poll_index - 2].?;
            const revents = poll_fds[poll_index].revents;
            if (revents & c.POLL.IN != 0) read_ready[slot_index] = true;
            if (revents & c.POLL.OUT != 0) write_ready[slot_index] = true;
            peer_broken[slot_index] =
                revents & (c.POLL.ERR | c.POLL.HUP | c.POLL.NVAL) != 0;
            if (peer_broken[slot_index] and
                self.clients[slot_index].?.wantsWrite())
                write_ready[slot_index] = true;
            if (peer_broken[slot_index] and
                !read_ready[slot_index] and !write_ready[slot_index])
                read_ready[slot_index] = true;
            ready[slot_index] = read_ready[slot_index] or
                write_ready[slot_index] or self.producer_remaining[slot_index] != 0;
        }
        // Newly accepted clients are not in this poll snapshot, but cadence work for existing
        // clients must remain schedulable even when no kernel fd was ready.
        for (self.clients, 0..) |maybe_client, slot_index| {
            const client = maybe_client orelse continue;
            if (!gate_open and !client.isUpgradeDraining()) continue;
            if (client.hasBufferedReadWork()) {
                read_ready[slot_index] = true;
                ready[slot_index] = true;
            }
            if (self.producer_remaining[slot_index] != 0) ready[slot_index] = true;
            if (client.wantsWrite()) {
                if (write_ready[slot_index])
                    client.noteWriteReady()
                else {
                    client.noteWriteStalled(now_ns);
                    self.pollout_absent_count +|= 1;
                    if (self.first_stall_connection_id == 0) {
                        self.first_stall_connection_id =
                            client.admission.key.monotonic_id;
                        self.first_stall_ns = now_ns;
                        var bytes: c_int = 0;
                        var bytes_len: c.socklen_t = @sizeOf(c_int);
                        if (c.getsockopt(
                            client.fd,
                            c.SOL.SOCKET,
                            c.SO.SNDBUF,
                            &bytes,
                            &bytes_len,
                        ) == 0 and bytes > 0)
                            self.first_stall_send_buffer_bytes = @intCast(bytes);
                    }
                }
            }
        }

        const admission = self.reactor.nextReady(&ready) orelse
            return if (progressed) .progress else .idle;
        const slot_index = admission.index;
        const client = self.clients[slot_index] orelse return .listener_broken;
        if (read_ready[slot_index]) client.readReady(now_ns);
        if (!client.isClosing() and write_ready[slot_index]) client.writeReady(now_ns);
        var closed_by_peer = false;
        if (!client.isClosing() and peer_broken[slot_index] and !client.wantsWrite()) {
            client.peerBroken();
            closed_by_peer = true;
        }
        if (!client.isClosing() and self.producer_remaining[slot_index] != 0) {
            self.producer_remaining[slot_index] -= 1;
            client.tick(now_ns);
        }
        progressed = true;
        if (client.isClosing()) {
            const marker = client.takeArmedUpgrade();
            self.destroyClient(slot_index, if (closed_by_peer) .peer_broken else .client_closing);
            if (marker) |armed| {
                self.destroyAll();
                if (!self.upgradeTeardownDrained()) {
                    if (self.repairEmptyUpgradeTeardown(armed)) return .progress;
                    host_log.line(
                        "upgrade teardown retained non-repairable authority; refusing handoff",
                        .{},
                    );
                    return .listener_broken;
                }
                self.armed_upgrade = armed;
                return .upgrade_ready;
            }
        }
        return if (progressed) .progress else .idle;
    }

    fn validateProcessIdentity(self: *const Owner) bool {
        const expected = self.process_identity orelse return builtin.is_test;
        const current = process_seal_service.currentReadyIdentity() catch return false;
        return std.meta.eql(expected, current);
    }

    fn acceptOne(self: *Owner, now_ns: u64) error{OutOfMemory}!void {
        const fd = switch (self.server.acceptOneResult()) {
            .accepted => |fd| fd,
            .fd_exhausted => {
                self.accept_retry_after_ns = now_ns +| cadence_ns;
                return;
            },
            .would_block, .denied, .failed => return,
        };
        const process_identity = process_seal_service.currentReadyIdentity() catch {
            _ = c.close(fd);
            return;
        };
        if (self.process_identity == null or !std.meta.eql(self.process_identity.?, process_identity)) {
            _ = c.close(fd);
            return;
        }
        const client = connection_turn.Client.create(
            self.allocator,
            fd,
            self.reactor,
            self.server.host_id,
            self.server.registry,
            &self.server.subscriptions,
            .{
                .runtime_ops = self.server.runtime_ops,
                .process_identity = process_identity,
                .upgrade_ops = self.server.upgrade_ops,
                .admission_gate = self.server.admission_gate,
                .host_status = self.server.host_status,
                .live_host_status = &self.server.host_status,
                .admin_admission = &self.admin_admission,
                .upgrade_preflight = .{
                    .ctx = self,
                    .check = upgradePreflight,
                },
                .pressure_reclaim = .{
                    .ctx = self,
                    .reclaim = reclaimScreenPressure,
                },
                .controller_transition = .{
                    .ctx = self,
                    .apply = applyControllerTransition,
                },
                .resize = .{
                    .ctx = self,
                    .apply = applyResize,
                },
                .now_ns = now_ns,
            },
        ) catch |err| switch (err) {
            // Admission is a sibling-isolated boundary: allocation pressure rejects only this fd;
            // the owner and every already admitted PTY/client remain live.
            error.Full => {
                self.overflow_rejected += 1;
                self.next_overflow_accept_ns = now_ns +| cadence_ns;
                return;
            },
            error.Exhausted, error.SocketSetupFailed, error.OutOfMemory => return,
        };
        const index = client.admission.index;
        std.debug.assert(self.clients[index] == null);
        self.clients[index] = client;
        self.total_admitted += 1;
        self.syncClientCount();
    }

    /// host가 client 연결을 닫을 때 **왜** 닫았는지 남긴다. GUI 쪽에는 이것이 `error=ConnectionClosed`로만
    /// 보이는데, 그 값만으로는 정상 종료인지 backpressure로 희생된 것인지 구분할 수 없다 — 실제로 "host는 살아
    /// 있는데 그 연결만 끊겼다"를 만났을 때 이유를 알 수단이 없어 추적이 막혔다. host stderr는
    /// `redirectStderrToHostLog`가 `<session_dir>/host-<id>.log`로 돌린다.
    /// `pending_out` 은 이 연결로 아직 밀어내지 못한 producer turn 수다. 0 이 아닌 채 끊겼다면 host 가
    /// **보낼 것을 들고 있는 상태**에서 연결이 사라진 것이라, GUI 가 남긴 `pending_request_count` 와 짝을
    /// 맞춰 읽을 수 있다. `clients` 는 남은 연결 수로, 한 연결만 끊겼는지 전부 무너졌는지를 가른다.
    ///
    /// ⚠️ **`isExpected()` 만으로 침묵하면 이 진단이 필요한 바로 그 경우에 스스로 입을 다문다.**
    /// `peer_broken` 은 세 조건이 **동시에** 성립해야 붙는다 — 닫는 중이 아니고, poll 이 peer 깨짐을
    /// 보고했고, **보낼 것이 남아 있지 않다**(`!client.wantsWrite()`). 즉 host 가 **보낼 것을 든 채**
    /// 연결이 깨지면 그것은 `client_closing` 으로 분류되고, `isExpected()` 가 참이라 한 줄도 안 남는다.
    ///
    /// 그 침묵이 실제로 추적을 두 번 막았다 — 2026-09-04 실측(GUI `last_success_request_id=136440` 뒤
    /// 끊김)과 2026-09-07 실측(GUI `stage=runtime_death error=ConnectionClosed`, host 로그 0 줄,
    /// host 는 `ready` 로 살아 있고 listener 도 정상). 두 번 다 **양쪽이 서로 「상대가 닫았다」로 기록**해
    /// 원인을 좁히지 못했다. 위 주석이 대조 지점으로 지목한 `pending_out` 이 정작 그 경우에 안 찍힌 것이다.
    ///
    /// 그래서 **「정상」으로 분류돼도 보낼 것이 남았으면 남긴다.** 진짜 정상 종료(`pending_out == 0`)는
    /// 그대로 침묵한다 — 연결이 닫힐 때마다 찍으면 그 소음이 다시 이 로그를 못 읽게 만든다.
    fn logClientClosed(self: *const Owner, index: usize, reason: ClientCloseReason) void {
        if (builtin.is_test) return;
        if (reason.isExpected() and self.producer_remaining[index] == 0) return;
        host_log.line(
            "session host closed client connection: slot={d} reason={s} pending_out={d} clients={d}",
            .{ index, @tagName(reason), self.producer_remaining[index], self.activeCount() },
        );
    }

    fn destroyClient(self: *Owner, index: usize, reason: ClientCloseReason) void {
        const client = self.clients[index] orelse return;
        self.logClientClosed(index, reason);
        self.clients[index] = null;
        self.producer_remaining[index] = 0;
        client.destroy();
        self.syncClientCount();
    }

    fn destroyAll(self: *Owner) void {
        for (0..max_clients) |index| self.destroyClient(index, .host_shutdown);
    }

    fn upgradeTeardownDrained(self: *const Owner) bool {
        if (!self.reactor.drainedForUpgrade() or
            self.server.subscriptions.count() != 0 or
            self.server.registry.attachmentCount() != 0 or
            self.admin_admission.active) return false;
        for (self.clients, self.producer_remaining) |maybe_client, remaining|
            if (maybe_client != null or remaining != 0) return false;
        return true;
    }

    /// Canonical client teardown 뒤 connection authority는 모두 사라졌지만 empty reactor의 aggregate
    /// counters만 남은 경우에만 key allocator를 보존한 채 aggregate budget을 고친다.
    /// Subscription/attachment/admin/active authority를 추측해 지우거나 mid-drain exec하지 않는다.
    fn repairEmptyUpgradeTeardown(
        self: *Owner,
        armed: connection_turn.ArmedUpgrade,
    ) bool {
        if (self.server.subscriptions.count() != 0 or
            self.server.registry.attachmentCount() != 0 or
            self.admin_admission.active or
            self.reactor.activeCount() != 0) return false;
        for (self.clients, self.producer_remaining) |maybe_client, remaining|
            if (maybe_client != null or remaining != 0) return false;

        const ops = self.server.upgrade_ops orelse return false;
        const gate = self.server.admission_gate orelse return false;
        if (!gate.closedAndDrained()) return false;
        if (!self.reactor.repairEmptyBudget()) return false;
        if (!self.upgradeTeardownDrained()) return false;
        if (!ops.abort_armed(ops.ctx, armed.attempt_id, .{
            .status = .resumed,
            .reason = .handoff_failed,
        })) return false;
        gate.reopen();
        self.syncClientCount();
        // This is an operator-visible recovery signal in the product. The Zig build runner
        // treats expected warning output from a passing test as a warned/failed test step, so
        // keep the production diagnostic without making the deterministic repair fixture noisy.
        if (!@import("builtin").is_test)
            host_log.line(
                "repaired empty upgrade reactor accounting and resumed serving",
                .{},
            );
        return true;
    }

    fn scheduleCadence(self: *Owner, now_ns: u64) void {
        if (now_ns < self.next_cadence_ns) return;
        self.next_cadence_ns = now_ns +| cadence_ns;
        self.server.sampleMetadataSources(now_ns);
        const gate_open = if (self.server.admission_gate) |gate| gate.snapshot().open else true;
        for (self.clients, 0..) |maybe_client, index| {
            const client = maybe_client orelse continue;
            if (!gate_open and !client.isUpgradeDraining()) continue;
            // A large sweep may span the next cadence. Resetting it to the full tracker count on
            // every timer edge would keep it permanently nonzero and revisit the same prefix.
            if (self.producer_remaining[index] == 0)
                self.producer_remaining[index] = client.beginProducerSweep(now_ns);
        }
    }

    fn scheduleProducerNow(self: *Owner, now_ns: u64) void {
        const gate_open = if (self.server.admission_gate) |gate| gate.snapshot().open else true;
        for (self.clients, 0..) |maybe_client, index| {
            const client = maybe_client orelse continue;
            if (!gate_open and !client.isUpgradeDraining()) continue;
            if (self.producer_remaining[index] == 0)
                self.producer_remaining[index] = client.beginProducerSweep(now_ns);
        }
    }

    fn upgradePreflight(ctx: *anyopaque, requester: *connection_turn.Client) bool {
        const self: *Owner = @ptrCast(@alignCast(ctx));
        if (self.server.subscriptions.count() != 0 or
            self.server.registry.attachmentCount() != 0) return false;
        var requester_membership: usize = 0;
        for (self.clients) |maybe_client| {
            const client = maybe_client orelse continue;
            if (client == requester) {
                requester_membership += 1;
                if (!client.requesterReadyForUpgrade() or
                    !client.socketQuiescentForUpgrade()) return false;
                continue;
            }
            if (!client.idleForUpgrade() or
                !client.socketQuiescentForUpgrade()) return false;
        }
        return requester_membership == 1;
    }

    fn reclaimScreenPressure(
        ctx: *anyopaque,
        requester: connection_slot.ConnectionKey,
        required_bytes: usize,
    ) bool {
        const self: *Owner = @ptrCast(@alignCast(ctx));
        _ = required_bytes;
        const requester_client = for (self.clients) |maybe_client| {
            const client = maybe_client orelse continue;
            if (std.meta.eql(client.admission.key, requester)) break client;
        } else return false;
        if (!requester_client.acceptsPressureReclaim()) return false;
        var victim_index: ?usize = null;
        var victim_candidate: ?connection_turn.ScreenPressureCandidate = null;
        var victim_key: ?connection_slot.ConnectionKey = null;
        for (self.clients, 0..) |maybe_client, index| {
            const client = maybe_client orelse continue;
            if (std.meta.eql(client.admission.key, requester)) continue;
            const candidate = client.largestScreenPressure() orelse continue;
            if (victim_candidate == null or
                candidate.queued_bytes > victim_candidate.?.queued_bytes or
                (candidate.queued_bytes == victim_candidate.?.queued_bytes and
                    (candidate.reclaimable_bytes > victim_candidate.?.reclaimable_bytes or
                        (candidate.reclaimable_bytes == victim_candidate.?.reclaimable_bytes and
                            client.admission.key.monotonic_id < victim_key.?.monotonic_id))))
            {
                victim_index = index;
                victim_candidate = candidate;
                victim_key = client.admission.key;
            }
        }
        const index = victim_index orelse return false;
        const victim = self.clients[index].?;
        if (!victim.reclaimScreenPressure(victim_candidate.?)) return false;
        if (victim.isClosing()) self.destroyClient(index, .screen_pressure);
        self.total_pressure_reclaims += 1;
        return true;
    }

    fn applyControllerTransition(
        ctx: *anyopaque,
        requester: *connection_turn.Client,
        transition: server_mod.Action.ControllerTransitionRequested,
    ) bool {
        const self: *Owner = @ptrCast(@alignCast(ctx));
        var owned_transition = transition;
        var success_owned = true;
        var stale_owned = true;
        var exhausted_owned = true;
        var revocation_owned = owned_transition.revocation != null;
        var transition_owned = true;
        defer if (success_owned) self.allocator.free(owned_transition.success_reply);
        defer if (stale_owned) self.allocator.free(owned_transition.stale_reply);
        defer if (exhausted_owned)
            self.allocator.free(owned_transition.exhausted_reply);
        defer if (revocation_owned)
            self.allocator.free(owned_transition.revocation.?.frame);
        defer if (transition_owned)
            self.server.registry.discardControllerTransition(
                &owned_transition.prepared,
            );

        self.server.registry.validateControllerTransition(
            &owned_transition.prepared,
        ) catch {
            if (!self.enqueueControllerFailure(
                requester,
                owned_transition.stale_reply,
            )) return false;
            stale_owned = false;
            return true;
        };
        const requester_record = self.server.subscriptions.resolveGlobal(
            owned_transition.prepared.target,
        ) orelse {
            if (!self.enqueueControllerFailure(
                requester,
                owned_transition.stale_reply,
            )) return false;
            stale_owned = false;
            return true;
        };
        if (!std.meta.eql(requester_record.connection, requester.admission.key) or
            requester_record.runtime_id != owned_transition.prepared.runtime_id)
        {
            if (!self.enqueueControllerFailure(
                requester,
                owned_transition.stale_reply,
            )) return false;
            stale_owned = false;
            return true;
        }

        var items: [2]connection_slot.ReactorCore.OwnedControlItem = undefined;
        var item_count: usize = 0;
        if (owned_transition.revocation) |revocation| {
            if (owned_transition.prepared.kind != .takeover or
                owned_transition.prepared.expected_controller == null or
                revocation.subscription.value !=
                    owned_transition.prepared.expected_controller.?.value)
                return self.rejectControllerTransitionResource(
                    requester,
                    owned_transition.exhausted_reply,
                    &exhausted_owned,
                );
            const old_record = self.server.subscriptions.resolveGlobal(
                revocation.subscription,
            ) orelse return self.rejectControllerTransitionResource(
                requester,
                owned_transition.exhausted_reply,
                &exhausted_owned,
            );
            if (old_record.runtime_id != owned_transition.prepared.runtime_id)
                return self.rejectControllerTransitionResource(
                    requester,
                    owned_transition.exhausted_reply,
                    &exhausted_owned,
                );
            const old_client = self.clientForKey(old_record.connection) orelse
                return self.rejectControllerTransitionResource(
                    requester,
                    owned_transition.exhausted_reply,
                    &exhausted_owned,
                );
            // Revoking a same-major legacy GUI that never negotiated the event would leave it
            // silently typing into a server-side deny path. Refuse the transition instead; after
            // that GUI reconnects with current capabilities, takeover can be retried explicitly.
            if (!old_client.connection.controller_transfer_v1)
                return self.rejectControllerTransitionResource(
                    requester,
                    owned_transition.exhausted_reply,
                    &exhausted_owned,
                );
            items[item_count] = .{
                .admission = old_client.admission,
                .bytes = revocation.frame,
            };
            item_count += 1;
        } else if (owned_transition.prepared.kind == .takeover and
            owned_transition.prepared.expected_controller != null)
            return self.rejectControllerTransitionResource(
                requester,
                owned_transition.exhausted_reply,
                &exhausted_owned,
            );

        items[item_count] = .{
            .admission = requester.admission,
            .bytes = owned_transition.success_reply,
        };
        item_count += 1;
        if (self.controller_transition_admission_fail_once) {
            self.controller_transition_admission_fail_once = false;
            return self.rejectControllerTransitionResource(
                requester,
                owned_transition.exhausted_reply,
                &exhausted_owned,
            );
        }
        self.reactor.enqueueOwnedControlBatch(items[0..item_count]) catch
            return self.rejectControllerTransitionResource(
                requester,
                owned_transition.exhausted_reply,
                &exhausted_owned,
            );
        success_owned = false;
        revocation_owned = false;
        _ = self.server.registry.commitControllerTransition(
            &owned_transition.prepared,
        ) catch unreachable;
        transition_owned = false;
        return true;
    }

    fn applyResize(
        ctx: *anyopaque,
        requester: *connection_turn.Client,
        resize_value: server_mod.Action.ResizeRequested,
    ) bool {
        const self: *Owner = @ptrCast(@alignCast(ctx));
        var resize = resize_value;
        var success_owned = true;
        var internal_owned = true;
        var exhausted_owned = true;
        const event_body_owned = resize.event_body != null;
        var screen_items: []connection_slot.ReactorCore.OwnedScreenItem = &.{};
        var screen_items_owned = false;
        var screen_frames_owned: usize = 0;
        var publication: ?connection_slot.ReactorCore.PreparedControlAndScreenBatch = null;
        defer {
            if (publication) |*prepared|
                self.reactor.cancelPreparedControlAndScreenBatch(prepared) catch
                    @panic("stale resize publication reservation");
            if (success_owned) self.allocator.free(resize.success_reply);
            if (internal_owned) self.allocator.free(resize.internal_reply);
            if (exhausted_owned) self.allocator.free(resize.exhausted_reply);
            if (event_body_owned) self.allocator.free(resize.event_body.?);
            for (screen_items[0..screen_frames_owned]) |item|
                self.allocator.free(item.bytes);
            if (screen_items_owned) self.allocator.free(screen_items);
        }

        if (resize.event_body) |event_body| {
            while (true) {
                const records = self.server.subscriptions.collectRuntimeRecords(
                    self.allocator,
                    resize.runtime_id,
                ) catch return self.rejectResize(
                    requester,
                    resize.exhausted_reply,
                    &exhausted_owned,
                );
                defer self.allocator.free(records);
                screen_items = self.allocator.alloc(
                    connection_slot.ReactorCore.OwnedScreenItem,
                    records.len,
                ) catch return self.rejectResize(
                    requester,
                    resize.exhausted_reply,
                    &exhausted_owned,
                );
                screen_items_owned = true;
                var offending_observer: ?usize = null;
                for (records) |record| {
                    const client = self.clientForKey(record.connection) orelse
                        return self.rejectResize(
                            requester,
                            resize.exhausted_reply,
                            &exhausted_owned,
                        );
                    const tracker = client.screenTracker(record.stream_id) orelse
                        return self.rejectResize(
                            requester,
                            resize.exhausted_reply,
                            &exhausted_owned,
                        );
                    const frame = framing.encodeFrame(self.allocator, .{
                        .kind = .event,
                        .stream_id = record.stream_id,
                    }, event_body) catch return self.rejectResize(
                        requester,
                        resize.exhausted_reply,
                        &exhausted_owned,
                    );
                    screen_items[screen_frames_owned] = .{
                        .admission = client.admission,
                        .tracker = tracker,
                        .bytes = frame,
                    };
                    screen_frames_owned += 1;
                }
                if (self.reactor.firstLocallyUnadmissibleScreenConnection(
                    screen_items[0..screen_frames_owned],
                    requester.admission,
                )) |offender| offending_observer = offender.index;
                if (offending_observer == null) break;

                // A locally invalid/full observer cannot hold the runtime's canonical resize
                // authority hostage. Drop its whole connection (and thus every subscription),
                // then rebuild from the registry's new complete target snapshot.
                for (screen_items[0..screen_frames_owned]) |item|
                    self.allocator.free(item.bytes);
                screen_frames_owned = 0;
                self.allocator.free(screen_items);
                screen_items = &.{};
                screen_items_owned = false;
                self.destroyClient(offending_observer.?, .observer_offender);
            }
        }

        const control = connection_slot.ReactorCore.OwnedControlItem{
            .admission = requester.admission,
            .bytes = resize.success_reply,
        };
        self.server.registry.validatePreparedResize(&resize.prepared) catch
            return self.rejectResize(
                requester,
                resize.internal_reply,
                &internal_owned,
            );
        if (self.resize_admission_fail_once) {
            self.resize_admission_fail_once = false;
            return self.rejectResize(
                requester,
                resize.exhausted_reply,
                &exhausted_owned,
            );
        }
        publication = self.reactor.prepareOwnedControlAndScreenBatch(
            control,
            screen_items[0..screen_frames_owned],
        ) catch return self.rejectResize(
            requester,
            resize.exhausted_reply,
            &exhausted_owned,
        );

        const preview = resize.prepared.preview();
        switch (preview) {
            .stale => unreachable,
            .applied => |applied| if (applied.changed) {
                const ops = self.server.runtime_ops orelse
                    return self.rejectResize(
                        requester,
                        resize.internal_reply,
                        &internal_owned,
                    );
                ops.resize(
                    ops.ctx,
                    resize.runtime_id,
                    applied.cols,
                    applied.rows,
                ) catch return self.rejectResize(
                    requester,
                    resize.internal_reply,
                    &internal_owned,
                );
            },
        }

        self.reactor.commitPreparedControlAndScreenBatch(&publication.?) catch
            @panic("stale resize publication reservation");
        publication = null;
        success_owned = false;
        screen_frames_owned = 0;
        _ = self.server.registry.commitResizeSubscription(&resize.prepared) catch
            unreachable;
        return true;
    }

    fn rejectResize(
        self: *Owner,
        requester: *connection_turn.Client,
        frame: []u8,
        owned: *bool,
    ) bool {
        if (!self.enqueueControllerFailure(requester, frame)) return false;
        owned.* = false;
        return true;
    }

    fn enqueueControllerFailure(
        self: *Owner,
        requester: *connection_turn.Client,
        frame: []u8,
    ) bool {
        var item = connection_slot.ReactorCore.OwnedControlItem{
            .admission = requester.admission,
            .bytes = frame,
        };
        self.reactor.enqueueOwnedControlBatch((&item)[0..1]) catch return false;
        return true;
    }

    fn rejectControllerTransitionResource(
        self: *Owner,
        requester: *connection_turn.Client,
        frame: []u8,
        owned: *bool,
    ) bool {
        if (!self.enqueueControllerFailure(requester, frame)) return false;
        owned.* = false;
        return true;
    }

    fn clientForKey(
        self: *Owner,
        key: connection_slot.ConnectionKey,
    ) ?*connection_turn.Client {
        for (self.clients) |maybe_client| {
            const client = maybe_client orelse continue;
            if (std.meta.eql(client.admission.key, key)) return client;
        }
        return null;
    }

    fn pollTimeout(self: *const Owner, now_ns: u64, outer_timeout_ms: i32) i32 {
        const gate_open = if (self.server.admission_gate) |gate| gate.snapshot().open else true;
        // Parser-resident complete frames have no corresponding kernel POLLIN edge.
        for (self.clients) |maybe_client|
            if (maybe_client) |client|
                if ((gate_open or client.isUpgradeDraining()) and client.hasBufferedReadWork())
                    return 0;
        for (self.clients, self.producer_remaining) |maybe_client, remaining| {
            const client = maybe_client orelse continue;
            if ((gate_open or client.isUpgradeDraining()) and remaining != 0) return 0;
        }
        var timeout_ms = outer_timeout_ms;
        if (now_ns < self.accept_retry_after_ns)
            timeout_ms = capTimeoutAt(now_ns, self.accept_retry_after_ns, timeout_ms);
        // Preserve the daemon's outer idle/oneshot accounting when no producer exists.
        if (self.reactor.activeCount() == 0) return timeout_ms;
        if (self.reactor.activeCount() == max_clients and now_ns < self.next_overflow_accept_ns) {
            timeout_ms = capTimeoutAt(now_ns, self.next_overflow_accept_ns, timeout_ms);
        }
        if (now_ns >= self.next_cadence_ns) return 0;
        const until_ns = self.next_cadence_ns - now_ns;
        const until_ms = @max(@as(u64, 1), (until_ns + std.time.ns_per_ms - 1) / std.time.ns_per_ms);
        return @min(timeout_ms, std.math.cast(i32, until_ms) orelse std.math.maxInt(i32));
    }
};

fn capTimeoutAt(now_ns: u64, deadline_ns: u64, outer_timeout_ms: i32) i32 {
    if (now_ns >= deadline_ns) return 0;
    const until_ns = deadline_ns - now_ns;
    const until_ms = @max(
        @as(u64, 1),
        (until_ns + std.time.ns_per_ms - 1) / std.time.ns_per_ms,
    );
    return @min(
        outer_timeout_ms,
        std.math.cast(i32, until_ms) orelse std.math.maxInt(i32),
    );
}

fn acceptAllowed(
    gate_open: bool,
    active_count: usize,
    now_ns: u64,
    retry_after_ns: u64,
    overflow_after_ns: u64,
) bool {
    return gate_open and now_ns >= retry_after_ns and
        (active_count < max_clients or now_ns >= overflow_after_ns);
}

fn monotonicNow(io: std.Io) u64 {
    const ns = std.Io.Clock.awake.now(io).nanoseconds;
    return if (ns <= 0) 0 else std.math.cast(u64, ns) orelse std.math.maxInt(u64);
}

test "poll owner: fd-pressure retry deadline caps an otherwise idle outer poll" {
    try std.testing.expectEqual(@as(i32, 20), capTimeoutAt(100, 20 * std.time.ns_per_ms, 1_000));
    try std.testing.expectEqual(@as(i32, 0), capTimeoutAt(20 * std.time.ns_per_ms, 20 * std.time.ns_per_ms, 1_000));
    const retry_capped = capTimeoutAt(0, 20 * std.time.ns_per_ms, 1_000);
    const cadence_capped = capTimeoutAt(0, 1 * std.time.ns_per_ms, retry_capped);
    try std.testing.expectEqual(@as(i32, 1), cadence_capped);
    try std.testing.expect(!acceptAllowed(true, 0, 10, 20, 0));
    try std.testing.expect(acceptAllowed(true, 0, 20, 20, 0));
    try std.testing.expect(!acceptAllowed(true, max_clients, 20, 20, 21));
    try std.testing.expect(!acceptAllowed(false, 0, 20, 20, 0));
}

const testing = std.testing;
const framing = @import("framing.zig");
const protocol = @import("protocol.zig");
const registry = @import("registry.zig");
const subscription_identity = @import("subscription_identity.zig");
const upgrade = @import("upgrade_coordinator.zig");
const upgrade_wire = @import("upgrade_wire.zig");

fn connectTestClient(path: [:0]const u8) !c.fd_t {
    const fd = c.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    if (fd < 0) return error.TestUnexpectedResult;
    errdefer _ = c.close(fd);
    var addr = posix.sockaddr.un{ .family = posix.AF.UNIX, .path = undefined };
    @memset(&addr.path, 0);
    @memcpy(addr.path[0..path.len], path);
    if (c.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) != 0)
        return error.TestUnexpectedResult;
    return fd;
}

test "CR4a poll owner는 fork process seal을 listener 접근 전에 거부한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    _ = process_seal_service.currentReadyIdentity() catch |err| switch (err) {
        error.NotReady => ready: {
            const pid = process_seal_service.currentProcessId();
            const nonce = try process_seal_service.generateProcessNonce();
            process_seal_service.commitReady(try process_seal_service.prepare(pid, nonce));
            break :ready try process_seal_service.currentReadyIdentity();
        },
        else => return err,
    };

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const dir_raw = dir_buf[0..dir_len];
    const dir_path = try testing.allocator.dupeZ(u8, dir_raw);
    defer testing.allocator.free(dir_path);
    const socket_path = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "{s}/cr4a-process-seal.sock",
        .{dir_raw},
        0,
    );
    defer testing.allocator.free(socket_path);
    var runtime_registry = registry.TerminalRuntimeRegistry.init(testing.allocator);
    defer runtime_registry.deinit();
    var server = try socket_server.SocketServer.bind(
        testing.allocator,
        dir_path,
        socket_path,
        0xB2,
        &runtime_registry,
    );
    defer server.deinit();
    var owner = try Owner.init(testing.allocator, testing.io, &server);
    defer owner.deinit();
    owner.next_cadence_ns = std.math.maxInt(u64);

    const peer = try connectTestClient(socket_path);
    defer _ = c.close(peer);
    const child = c.fork();
    if (child < 0) return error.TestUnexpectedResult;
    if (child == 0) {
        owner.requireCurrentProcessOrFatal();
        c._exit(87);
    }
    var status: c_int = 0;
    var reaped = false;
    var attempts: usize = 0;
    while (attempts < 2000) : (attempts += 1) {
        const waited = c.waitpid(child, &status, posix.W.NOHANG);
        if (waited == child) {
            reaped = true;
            break;
        }
        if (waited < 0 and posix.errno(waited) != .INTR) break;
        _ = usleep(1000);
    }
    if (!reaped) {
        _ = c.kill(child, c.SIG.KILL);
        while (true) {
            const waited = c.waitpid(child, &status, 0);
            if (waited == child) break;
            if (waited >= 0 or posix.errno(waited) != .INTR) break;
        }
        return error.TestUnexpectedResult;
    }
    const unsigned_status: u32 = @bitCast(status);
    try testing.expect(c.W.IFEXITED(unsigned_status));
    try testing.expectEqual(@as(u32, 86), c.W.EXITSTATUS(unsigned_status));
    try testing.expectEqual(@as(usize, 0), owner.activeCount());
    _ = try owner.pollOnce(0);
    try testing.expectEqual(@as(usize, 1), owner.activeCount());
    const ready_identity = try process_seal_service.currentReadyIdentity();
    var injected = false;
    for (owner.clients) |maybe_client| {
        const client = maybe_client orelse continue;
        try testing.expectEqualDeep(ready_identity, client.process_identity.?);
        injected = true;
    }
    try testing.expect(injected);
}

fn sendTestRequest(fd: c.fd_t, kind: protocol.Kind, request_id: u64, payload: []const u8) !void {
    const bytes = try framing.encodeFrame(testing.allocator, .{
        .kind = kind,
        .request_id = request_id,
    }, payload);
    defer testing.allocator.free(bytes);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const rc = c.send(fd, bytes.ptr + offset, bytes.len - offset, 0);
        if (rc <= 0) return error.TestUnexpectedResult;
        offset += @intCast(rc);
    }
}

fn sendTestStream(fd: c.fd_t, kind: protocol.Kind, stream_id: u64, payload: []const u8) !void {
    const bytes = try framing.encodeFrame(testing.allocator, .{
        .kind = kind,
        .stream_id = stream_id,
    }, payload);
    defer testing.allocator.free(bytes);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const rc = c.send(fd, bytes.ptr + offset, bytes.len - offset, 0);
        if (rc <= 0) return error.TestUnexpectedResult;
        offset += @intCast(rc);
    }
}

const AttachedTestClient = struct {
    fd: c.fd_t,
    index: usize,
};

const BatchProjectorProbe = struct {
    owner: *Owner,
    requester_index: usize,
    first_victim_index: usize,
    second_victim_index: usize,
    reclaim_before: usize,
    requester_retained: usize,
    call_count: usize = 0,
    first_entered_at_batch_stage: bool = false,
    second_entered_at_batch_stage: bool = false,
};

fn observeBatchProjector(ctx: *anyopaque) void {
    const probe: *BatchProjectorProbe = @ptrCast(@alignCast(ctx));
    probe.call_count += 1;
    if (probe.call_count > 2) return;
    const requester = probe.owner.clients[probe.requester_index] orelse return;
    const first = probe.owner.clients[probe.first_victim_index] orelse return;
    const second = probe.owner.clients[probe.second_victim_index] orelse return;
    const requester_slot = probe.owner.reactor.get(requester.admission) catch return;
    const requester_tracker = requester.trackers.get(1) orelse return;
    const accounting = probe.owner.reactor.accountingSnapshot();
    const prepared =
        (requester_slot.preparedBaseBytes(requester_tracker) catch return) ==
        connection_slot.base_update_max_bytes and
        accounting.prepared_base_bytes == connection_slot.base_update_max_bytes and
        accounting.prepared_reclaim_bytes == probe.requester_retained;
    if (probe.call_count == 1) {
        probe.first_entered_at_batch_stage =
            prepared and
            probe.owner.total_pressure_reclaims == probe.reclaim_before and
            first.largestScreenPressure() != null and
            second.largestScreenPressure() != null;
    } else {
        probe.second_entered_at_batch_stage =
            prepared and
            probe.owner.total_pressure_reclaims == probe.reclaim_before + 1 and
            first.largestScreenPressure() == null and
            second.largestScreenPressure() != null;
    }
}

fn connectAttachedTestClient(
    owner: *Owner,
    path: [:0]const u8,
    mode: []const u8,
) !AttachedTestClient {
    return connectAttachedTestClientForRuntime(owner, path, "aa", mode);
}

fn connectAttachedTestClientForRuntime(
    owner: *Owner,
    path: [:0]const u8,
    runtime_hex: []const u8,
    mode: []const u8,
) !AttachedTestClient {
    var occupied: [max_clients]bool = undefined;
    for (owner.clients, 0..) |client, index| occupied[index] = client != null;
    const fd = try connectTestClient(path);
    errdefer _ = c.close(fd);
    _ = try owner.pollOnce(5);
    try sendTestRequest(
        fd,
        .hello,
        1,
        "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"gui\",\"capabilities\":[\"controller_transfer_v1\"]}",
    );
    try pumpUntilResponse(owner, fd, "host_id");
    const request = try std.fmt.allocPrint(
        testing.allocator,
        "{{\"method\":\"runtime.attach\",\"params\":{{\"runtime_id\":\"{s}\",\"mode\":\"{s}\"}}}}",
        .{ runtime_hex, mode },
    );
    defer testing.allocator.free(request);
    try sendTestRequest(fd, .request, 2, request);
    try pumpUntilLocalStreamOneSnapshot(owner, fd);
    for (owner.clients, 0..) |client, index|
        if (!occupied[index] and client != null) return .{ .fd = fd, .index = index };
    return error.TestUnexpectedResult;
}

fn fillServerSendBuffer(fd: c.fd_t) !void {
    const tiny: c_int = 1024;
    try testing.expectEqual(
        @as(c_int, 0),
        c.setsockopt(
            fd,
            posix.SOL.SOCKET,
            posix.SO.SNDBUF,
            @ptrCast(&tiny),
            @sizeOf(c_int),
        ),
    );
    var bytes: [4096]u8 = [_]u8{'P'} ** 4096;
    for (0..4096) |_| {
        const rc = c.send(fd, &bytes, bytes.len, posix.MSG.DONTWAIT);
        if (rc < 0 and posix.errno(rc) == .AGAIN) return;
        if (rc <= 0) return error.TestUnexpectedResult;
    }
    return error.TestUnexpectedResult;
}

fn setTinySocketBuffers(server_fd: c.fd_t, peer_fd: c.fd_t) !void {
    const tiny: c_int = 1024;
    try testing.expectEqual(
        @as(c_int, 0),
        c.setsockopt(
            server_fd,
            posix.SOL.SOCKET,
            posix.SO.SNDBUF,
            @ptrCast(&tiny),
            @sizeOf(c_int),
        ),
    );
    try testing.expectEqual(
        @as(c_int, 0),
        c.setsockopt(
            peer_fd,
            posix.SOL.SOCKET,
            posix.SO.RCVBUF,
            @ptrCast(&tiny),
            @sizeOf(c_int),
        ),
    );
}

fn pumpUntilResponse(owner: *Owner, fd: c.fd_t, needle: []const u8) !void {
    var parser = framing.FrameParser.init(testing.allocator);
    defer parser.deinit();
    var buf: [4096]u8 = undefined;
    var attempts: usize = 0;
    while (attempts < 1000) : (attempts += 1) {
        _ = try owner.pollOnce(5);
        const rc = c.recv(fd, &buf, buf.len, posix.MSG.DONTWAIT);
        if (rc < 0) {
            if (posix.errno(rc) == .AGAIN) continue;
            return error.TestUnexpectedResult;
        }
        if (rc == 0) return error.TestUnexpectedResult;
        try parser.push(buf[0..@intCast(rc)]);
        while (try parser.next()) |frame| {
            defer frame.deinit(testing.allocator);
            if (std.mem.indexOf(u8, frame.payload, needle) != null) return;
        }
    }
    return error.TestUnexpectedResult;
}

fn pumpUntilEitherResponse(
    owner: *Owner,
    fd: c.fd_t,
    first: []const u8,
    second: []const u8,
) !bool {
    var parser = framing.FrameParser.init(testing.allocator);
    defer parser.deinit();
    var buf: [4096]u8 = undefined;
    for (0..1000) |_| {
        _ = try owner.pollOnce(5);
        const rc = c.recv(fd, &buf, buf.len, posix.MSG.DONTWAIT);
        if (rc < 0) {
            if (posix.errno(rc) == .AGAIN) continue;
            return error.TestUnexpectedResult;
        }
        if (rc == 0) return error.TestUnexpectedResult;
        try parser.push(buf[0..@intCast(rc)]);
        while (try parser.next()) |frame| {
            defer frame.deinit(testing.allocator);
            if (std.mem.indexOf(u8, frame.payload, first) != null) return true;
            if (std.mem.indexOf(u8, frame.payload, second) != null) return false;
        }
    }
    return error.TestUnexpectedResult;
}

fn pumpResponseCount(owner: *Owner, fd: c.fd_t, first_request_id: u64, expected: usize) !void {
    var parser = framing.FrameParser.init(testing.allocator);
    defer parser.deinit();
    var buf: [16 * 1024]u8 = undefined;
    var count: usize = 0;
    var attempts: usize = 0;
    while (count < expected and attempts < 4000) : (attempts += 1) {
        _ = try owner.pollOnce(2);
        const rc = c.recv(fd, &buf, buf.len, posix.MSG.DONTWAIT);
        if (rc < 0) {
            if (posix.errno(rc) == .AGAIN) continue;
            return error.TestUnexpectedResult;
        }
        if (rc == 0) return error.TestUnexpectedResult;
        try parser.push(buf[0..@intCast(rc)]);
        while (try parser.next()) |frame| {
            defer frame.deinit(testing.allocator);
            if (frame.header.request_id >= first_request_id) count += 1;
        }
    }
    try testing.expectEqual(expected, count);
}

fn pumpUntilClosed(owner: *Owner, fd: c.fd_t) !void {
    var byte: [1]u8 = undefined;
    for (0..1000) |_| {
        _ = try owner.pollOnce(2);
        const rc = c.recv(fd, &byte, byte.len, posix.MSG.DONTWAIT);
        if (rc == 0) return;
        if (rc < 0 and posix.errno(rc) != .AGAIN) return error.TestUnexpectedResult;
    }
    return error.TestUnexpectedResult;
}

fn pumpUntilLocalStreamOneSnapshot(owner: *Owner, fd: c.fd_t) !void {
    var parser = framing.FrameParser.init(testing.allocator);
    defer parser.deinit();
    var buf: [4096]u8 = undefined;
    var saw_response = false;
    var saw_snapshot_end = false;
    var attempts: usize = 0;
    while ((!saw_response or !saw_snapshot_end) and attempts < 1000) : (attempts += 1) {
        _ = try owner.pollOnce(5);
        const rc = c.recv(fd, &buf, buf.len, posix.MSG.DONTWAIT);
        if (rc < 0) {
            if (posix.errno(rc) == .AGAIN) continue;
            return error.TestUnexpectedResult;
        }
        if (rc == 0) return error.TestUnexpectedResult;
        try parser.push(buf[0..@intCast(rc)]);
        while (try parser.next()) |frame| {
            defer frame.deinit(testing.allocator);
            if (frame.header.kind == .response and
                std.mem.indexOf(u8, frame.payload, "\"stream_id\":1") != null)
                saw_response = true;
            if (frame.header.kind == .snapshot_chunk and
                frame.header.stream_id == 1 and
                frame.header.flags & protocol.Flags.end_stream != 0)
                saw_snapshot_end = true;
        }
    }
    try testing.expect(saw_response);
    try testing.expect(saw_snapshot_end);
}

fn drainQueuedTestOutput(
    owner: *Owner,
    fd: c.fd_t,
    admission: connection_slot.ReactorCore.Admission,
) !void {
    var buf: [4096]u8 = undefined;
    for (0..1000) |_| {
        _ = try owner.pollOnce(0);
        while (true) {
            const rc = c.recv(fd, &buf, buf.len, posix.MSG.DONTWAIT);
            if (rc > 0) continue;
            if (rc == 0) return error.TestUnexpectedResult;
            if (posix.errno(rc) == .AGAIN) break;
            return error.TestUnexpectedResult;
        }
        if ((try owner.reactor.get(admission)).pending_bytes == 0) return;
    }
    return error.TestUnexpectedResult;
}

fn drainAttachedPairOutputAndProducers(
    owner: *Owner,
    first: AttachedTestClient,
    second: AttachedTestClient,
) !void {
    var buf: [4096]u8 = undefined;
    for (0..1000) |_| {
        _ = try owner.pollOnce(0);
        for ([_]c.fd_t{ first.fd, second.fd }) |fd| {
            while (true) {
                const rc = c.recv(fd, &buf, buf.len, posix.MSG.DONTWAIT);
                if (rc > 0) continue;
                if (rc == 0) return error.TestUnexpectedResult;
                if (posix.errno(rc) == .AGAIN) break;
                return error.TestUnexpectedResult;
            }
        }
        const first_admission = owner.clients[first.index].?.admission;
        const second_admission = owner.clients[second.index].?.admission;
        if ((try owner.reactor.get(first_admission)).pending_bytes == 0 and
            (try owner.reactor.get(second_admission)).pending_bytes == 0 and
            owner.producer_remaining[first.index] == 0 and
            owner.producer_remaining[second.index] == 0)
            return;
    }
    return error.TestUnexpectedResult;
}

fn admittedKeyExcept(
    owner: *Owner,
    excluded: ?connection_slot.ConnectionKey,
) !connection_slot.ReactorCore.Admission {
    for (owner.clients) |maybe_client| {
        const client = maybe_client orelse continue;
        if (excluded) |key| {
            if (std.meta.eql(client.admission.key, key)) continue;
        }
        return client.admission;
    }
    return error.TestUnexpectedResult;
}

test "poll owner reclaims one observer offender and preserves controller and healthy producer" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const dir_raw = dir_buf[0..dir_len];
    const dir_path = try testing.allocator.dupeZ(u8, dir_raw);
    defer testing.allocator.free(dir_path);
    const socket_path = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "{s}/global-pressure.sock",
        .{dir_raw},
        0,
    );
    defer testing.allocator.free(socket_path);
    var runtime_registry = registry.TerminalRuntimeRegistry.init(testing.allocator);
    defer runtime_registry.deinit();
    _ = try runtime_registry.register(0xAA, 80, 24);
    var server = try socket_server.SocketServer.bind(
        testing.allocator,
        dir_path,
        socket_path,
        0xB2,
        &runtime_registry,
    );
    defer server.deinit();
    server.host_status = .{ .manifest_capable = true };
    var fake_runtime: server_mod.FakeRuntimeOps = .{};
    server.runtime_ops = fake_runtime.ops();
    var owner = try Owner.init(testing.allocator, testing.io, &server);
    defer owner.deinit();
    owner.next_cadence_ns = std.math.maxInt(u64);

    var fds: [12]c.fd_t = undefined;
    var fd_count: usize = 0;
    defer {
        for (fds[0..fd_count]) |fd| {
            if (fd >= 0) _ = c.close(fd);
        }
    }
    const controller = try connectAttachedTestClient(&owner, socket_path, "controller");
    fds[fd_count] = controller.fd;
    fd_count += 1;
    const healthy = try connectAttachedTestClient(&owner, socket_path, "observer");
    fds[fd_count] = healthy.fd;
    fd_count += 1;
    var slow_indices: [10]usize = undefined;
    for (&slow_indices) |*slow_index| {
        const slow = try connectAttachedTestClient(&owner, socket_path, "observer");
        fds[fd_count] = slow.fd;
        fd_count += 1;
        slow_index.* = slow.index;
    }
    for (slow_indices) |slow_index| {
        const slow_client = owner.clients[slow_index].?;
        try fillServerSendBuffer(slow_client.fd);
        const slot = try owner.reactor.get(slow_client.admission);
        const tracker = slow_client.trackers.get(1).?;
        const pressure = try testing.allocator.alloc(u8, connection_slot.screen_soft_bytes);
        @memset(pressure, 'Q');
        slot.enqueueOwnedScreen(tracker, pressure) catch |err| {
            testing.allocator.free(pressure);
            return err;
        };
    }
    _ = try owner.pollOnce(0);
    for (slow_indices) |slow_index| {
        const slow_client = owner.clients[slow_index].?;
        const slot = try owner.reactor.get(slow_client.admission);
        try testing.expect(slot.writeBackpressured());
        try testing.expectEqual(connection_slot.screen_soft_bytes, slot.firstPending().?.bytes.len);
    }

    const before = owner.reactor.accountingSnapshot();
    try testing.expect(before.shared_bytes >= 80 * 1024 * 1024);
    const healthy_client = owner.clients[healthy.index].?;
    const healthy_tracker = healthy_client.trackers.get(1).?;
    const now_ns = monotonicNow(testing.io);
    owner.next_cadence_ns = std.math.maxInt(u64);
    owner.producer_remaining[healthy.index] = healthy_client.beginProducerSweep(now_ns);
    const delta_before = fake_runtime.delta_calls;
    var producer_attempts: usize = 0;
    while (fake_runtime.delta_calls == delta_before and producer_attempts < 100) : (producer_attempts += 1)
        _ = try owner.pollOnce(0);
    try testing.expect(fake_runtime.delta_calls > delta_before);
    try pumpUntilResponse(&owner, healthy.fd, "DELTA-BYTES");
    try testing.expectEqual(
        connection_slot.ScreenState.valid,
        try (try owner.reactor.get(healthy_client.admission)).screenState(healthy_tracker),
    );

    var invalidated: usize = 0;
    for (slow_indices) |index| {
        const client = owner.clients[index] orelse continue;
        const tracker = client.trackers.get(1).?;
        if ((try (try owner.reactor.get(client.admission)).screenState(tracker)) ==
            .invalidated) invalidated += 1;
    }
    try testing.expectEqual(@as(usize, 1), invalidated);
    const selected_victim = owner.clients[slow_indices[0]].?;
    try testing.expectEqual(
        connection_slot.ScreenState.invalidated,
        try (try owner.reactor.get(selected_victim.admission)).screenState(
            selected_victim.trackers.get(1).?,
        ),
    );
    try testing.expectEqual(@as(usize, 1), owner.total_pressure_reclaims);
    try testing.expect(owner.clients[controller.index] != null);
    try sendTestStream(controller.fd, .input_bytes, 1, "CTRL-AFTER-PRESSURE");
    var input_attempts: usize = 0;
    while (fake_runtime.last_input_len == 0 and input_attempts < 1000) : (input_attempts += 1)
        _ = try owner.pollOnce(0);
    try testing.expectEqualStrings(
        "CTRL-AFTER-PRESSURE",
        fake_runtime.last_input[0..fake_runtime.last_input_len],
    );

    const peak = owner.reactor.accountingSnapshot();
    try testing.expect(peak.peak_resident_bytes <= connection_slot.global_bytes);
    try testing.expect(peak.peak_shared_bytes > 0);
    try testing.expect(peak.peak_shared_bytes <= connection_slot.shared_hard_bytes);
    try testing.expect(peak.peak_prepared_base_bytes > 0);
    try testing.expect(
        peak.peak_prepared_base_bytes <= connection_slot.base_replacement_headroom_bytes,
    );
    try testing.expect(peak.peak_prepared_reclaim_bytes > 0);
    try testing.expect(peak.peak_prepared_reclaim_bytes <= connection_slot.shared_hard_bytes);
    try testing.expect(peak.peak_slot_queue_bytes <= connection_slot.per_slot_bytes);
    try testing.expect(peak.peak_slot_base_bytes <= connection_slot.base_per_slot_bytes);
    try testing.expect(peak.peak_slot_control_bytes > 0);
    try testing.expect(
        peak.peak_slot_control_bytes <= connection_slot.per_slot_bytes,
    );
    try testing.expect(peak.peak_slot_total_bytes <= connection_slot.total_per_slot_bytes);

    for (fds[0..fd_count]) |*fd| {
        _ = c.shutdown(fd.*, c.SHUT.RDWR);
        _ = c.close(fd.*);
        fd.* = -1;
    }
    var close_attempts: usize = 0;
    while (owner.activeCount() != 0 and close_attempts < 4000) : (close_attempts += 1)
        _ = try owner.pollOnce(0);
    try testing.expectEqual(@as(usize, 0), owner.activeCount());
    for (owner.clients, owner.producer_remaining) |client, remaining| {
        try testing.expect(client == null);
        try testing.expectEqual(@as(usize, 0), remaining);
    }
    try testing.expectEqual(@as(usize, 0), server.subscriptions.count());
    try testing.expectEqual(@as(usize, 0), runtime_registry.attachmentCount());
    try testing.expectEqual(@as(usize, 0), server.host_status.client_count);
    try testing.expect(!owner.admin_admission.active);
    const final = owner.reactor.accountingSnapshot();
    try testing.expectEqual(@as(usize, 0), final.resident_bytes);
    try testing.expectEqual(@as(usize, 0), final.shared_bytes);
    try testing.expectEqual(@as(usize, 0), final.prepared_base_bytes);
    try testing.expectEqual(@as(usize, 0), final.prepared_reclaim_bytes);
}

test "poll owner preserves requester and backs off when only partial controllers pin global budget" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const dir_raw = dir_buf[0..dir_len];
    const dir_path = try testing.allocator.dupeZ(u8, dir_raw);
    defer testing.allocator.free(dir_path);
    const socket_path = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "{s}/pressure-backoff.sock",
        .{dir_raw},
        0,
    );
    defer testing.allocator.free(socket_path);
    var runtime_registry = registry.TerminalRuntimeRegistry.init(testing.allocator);
    defer runtime_registry.deinit();
    _ = try runtime_registry.register(0xAA, 80, 24);
    for (0..10) |index| _ = try runtime_registry.register(0x100 + index, 80, 24);
    var server = try socket_server.SocketServer.bind(
        testing.allocator,
        dir_path,
        socket_path,
        0xB3,
        &runtime_registry,
    );
    defer server.deinit();
    server.host_status = .{ .manifest_capable = true };
    var fake_runtime: server_mod.FakeRuntimeOps = .{};
    server.runtime_ops = fake_runtime.ops();
    var owner = try Owner.init(testing.allocator, testing.io, &server);
    defer owner.deinit();
    owner.next_cadence_ns = std.math.maxInt(u64);

    var fds: [11]c.fd_t = undefined;
    var fd_count: usize = 0;
    defer {
        for (fds[0..fd_count]) |fd| {
            if (fd >= 0) _ = c.close(fd);
        }
    }
    const healthy = try connectAttachedTestClient(&owner, socket_path, "observer");
    fds[fd_count] = healthy.fd;
    fd_count += 1;
    var controller_indices: [10]usize = undefined;
    for (&controller_indices, 0..) |*controller_index, index| {
        const runtime_hex = try std.fmt.allocPrint(testing.allocator, "{x}", .{0x100 + index});
        defer testing.allocator.free(runtime_hex);
        const controller = try connectAttachedTestClientForRuntime(
            &owner,
            socket_path,
            runtime_hex,
            "controller",
        );
        fds[fd_count] = controller.fd;
        fd_count += 1;
        controller_index.* = controller.index;
    }
    for (controller_indices) |controller_index| {
        const controller = owner.clients[controller_index].?;
        try fillServerSendBuffer(controller.fd);
        const slot = try owner.reactor.get(controller.admission);
        const tracker = controller.trackers.get(1).?;
        const pressure = try testing.allocator.alloc(u8, connection_slot.screen_soft_bytes);
        @memset(pressure, 'C');
        slot.enqueueOwnedScreen(tracker, pressure) catch |err| {
            testing.allocator.free(pressure);
            return err;
        };
        try slot.consumeWritten(1);
        controller.noteWriteStalled(10);
        try testing.expect(slot.writeBackpressured());
        try testing.expect(try slot.trackerHasWrittenPrefix(tracker));
        try testing.expect(controller.largestScreenPressure() == null);
    }

    const healthy_client = owner.clients[healthy.index].?;
    const healthy_slot = try owner.reactor.get(healthy_client.admission);
    const healthy_tracker = healthy_client.trackers.get(1).?;
    const base_before = try healthy_slot.retainedBaseBytes(healthy_tracker);
    const delta_before = fake_runtime.delta_calls;
    owner.producer_remaining[healthy.index] = healthy_client.beginProducerSweep(100);
    owner.next_cadence_ns = std.math.maxInt(u64);
    var attempts: usize = 0;
    while ((try healthy_slot.globalPressureRetryAfter(healthy_tracker)) == 0 and attempts < 100) : (attempts += 1)
        _ = try owner.pollOnce(0);
    const retry_at = try healthy_slot.globalPressureRetryAfter(healthy_tracker);
    try testing.expect(retry_at != 0);
    try testing.expectEqual(@as(usize, 0), owner.total_pressure_reclaims);
    try testing.expectEqual(delta_before, fake_runtime.delta_calls);
    try testing.expectEqual(
        connection_slot.ScreenState.valid,
        try healthy_slot.screenState(healthy_tracker),
    );
    try testing.expectEqual(base_before, try healthy_slot.retainedBaseBytes(healthy_tracker));

    _ = healthy_client.beginProducerSweep(retry_at - 1);
    healthy_client.tick(retry_at - 1);
    try testing.expectEqual(retry_at, try healthy_slot.globalPressureRetryAfter(healthy_tracker));
    try testing.expectEqual(delta_before, fake_runtime.delta_calls);
    _ = healthy_client.beginProducerSweep(retry_at);
    healthy_client.tick(retry_at);
    try testing.expect(
        (try healthy_slot.globalPressureRetryAfter(healthy_tracker)) > retry_at,
    );
    try testing.expectEqual(delta_before, fake_runtime.delta_calls);
    try testing.expectEqual(@as(usize, 0), owner.total_pressure_reclaims);
    try testing.expectEqual(
        connection_slot.ScreenState.valid,
        try healthy_slot.screenState(healthy_tracker),
    );
    try testing.expectEqual(base_before, try healthy_slot.retainedBaseBytes(healthy_tracker));

    for (fds[0..fd_count]) |*fd| {
        _ = c.shutdown(fd.*, c.SHUT.RDWR);
        _ = c.close(fd.*);
        fd.* = -1;
    }
    var close_attempts: usize = 0;
    while (owner.activeCount() != 0 and close_attempts < 4000) : (close_attempts += 1)
        _ = try owner.pollOnce(0);
    try testing.expectEqual(@as(usize, 0), owner.activeCount());
    try testing.expectEqual(@as(usize, 0), server.subscriptions.count());
    try testing.expectEqual(@as(usize, 0), runtime_registry.attachmentCount());
    const final = owner.reactor.accountingSnapshot();
    try testing.expectEqual(@as(usize, 0), final.resident_bytes);
    try testing.expectEqual(@as(usize, 0), final.shared_bytes);
}

test "poll owner backs off when one observer reclaim is insufficient for base reservation" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const dir_raw = dir_buf[0..dir_len];
    const dir_path = try testing.allocator.dupeZ(u8, dir_raw);
    defer testing.allocator.free(dir_path);
    const socket_path = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "{s}/insufficient-base-reclaim.sock",
        .{dir_raw},
        0,
    );
    defer testing.allocator.free(socket_path);
    var runtime_registry = registry.TerminalRuntimeRegistry.init(testing.allocator);
    defer runtime_registry.deinit();
    _ = try runtime_registry.register(0xAA, 80, 24);
    for (0..10) |index| _ = try runtime_registry.register(0x300 + index, 80, 24);
    var server = try socket_server.SocketServer.bind(
        testing.allocator,
        dir_path,
        socket_path,
        0xB5,
        &runtime_registry,
    );
    defer server.deinit();
    server.host_status = .{ .manifest_capable = true };
    var fake_runtime: server_mod.FakeRuntimeOps = .{};
    server.runtime_ops = fake_runtime.ops();
    var owner = try Owner.init(testing.allocator, testing.io, &server);
    defer owner.deinit();
    owner.next_cadence_ns = std.math.maxInt(u64);

    var fds: [13]c.fd_t = undefined;
    var fd_count: usize = 0;
    defer {
        for (fds[0..fd_count]) |fd| {
            if (fd >= 0) _ = c.close(fd);
        }
    }
    const healthy = try connectAttachedTestClient(&owner, socket_path, "observer");
    fds[fd_count] = healthy.fd;
    fd_count += 1;
    const victim = try connectAttachedTestClient(&owner, socket_path, "observer");
    fds[fd_count] = victim.fd;
    fd_count += 1;
    const second_victim = try connectAttachedTestClient(&owner, socket_path, "observer");
    fds[fd_count] = second_victim.fd;
    fd_count += 1;
    var pin_indices: [10]usize = undefined;
    var controller_peer: c.fd_t = -1;
    for (&pin_indices, 0..) |*pin_index, index| {
        const runtime_hex = try std.fmt.allocPrint(testing.allocator, "{x}", .{0x300 + index});
        defer testing.allocator.free(runtime_hex);
        const pin = try connectAttachedTestClientForRuntime(
            &owner,
            socket_path,
            runtime_hex,
            "controller",
        );
        fds[fd_count] = pin.fd;
        fd_count += 1;
        if (index == 0) controller_peer = pin.fd;
        pin_index.* = pin.index;
    }
    for (pin_indices) |pin_index| {
        const pin = owner.clients[pin_index].?;
        try fillServerSendBuffer(pin.fd);
        const slot = try owner.reactor.get(pin.admission);
        const tracker = pin.trackers.get(1).?;
        const pressure = try testing.allocator.alloc(u8, connection_slot.screen_soft_bytes);
        @memset(pressure, 'P');
        slot.enqueueOwnedScreen(tracker, pressure) catch |err| {
            testing.allocator.free(pressure);
            return err;
        };
        try slot.consumeWritten(1);
        pin.noteWriteStalled(10);
        try testing.expect(pin.largestScreenPressure() == null);
    }

    const victim_client = owner.clients[victim.index].?;
    try fillServerSendBuffer(victim_client.fd);
    const victim_slot = try owner.reactor.get(victim_client.admission);
    const victim_tracker = victim_client.trackers.get(1).?;
    const small_pressure = try testing.allocator.alloc(u8, 1024 * 1024);
    @memset(small_pressure, 'V');
    victim_slot.enqueueOwnedScreen(victim_tracker, small_pressure) catch |err| {
        testing.allocator.free(small_pressure);
        return err;
    };
    _ = try owner.pollOnce(0);
    try testing.expect(victim_slot.writeStallObserved());
    const victim_candidate = victim_client.largestScreenPressure().?;
    try testing.expect(victim_candidate.reclaimable_bytes > 0);
    try testing.expect(
        victim_candidate.reclaimable_bytes < connection_slot.base_update_max_bytes,
    );
    const second_victim_client = owner.clients[second_victim.index].?;
    try fillServerSendBuffer(second_victim_client.fd);
    const second_victim_slot = try owner.reactor.get(second_victim_client.admission);
    const second_victim_tracker = second_victim_client.trackers.get(1).?;
    const second_pressure = try testing.allocator.alloc(u8, 1024 * 1024);
    @memset(second_pressure, 'W');
    second_victim_slot.enqueueOwnedScreen(second_victim_tracker, second_pressure) catch |err| {
        testing.allocator.free(second_pressure);
        return err;
    };
    _ = try owner.pollOnce(0);
    const second_victim_candidate = second_victim_client.largestScreenPressure().?;
    const pressure_before = owner.reactor.accountingSnapshot();

    const healthy_client = owner.clients[healthy.index].?;
    const healthy_slot = try owner.reactor.get(healthy_client.admission);
    const healthy_tracker = healthy_client.trackers.get(1).?;
    const base_before = try healthy_slot.retainedBaseBytes(healthy_tracker);
    try testing.expect(
        pressure_before.shared_bytes - victim_candidate.reclaimable_bytes - base_before +
            connection_slot.base_update_max_bytes >
            connection_slot.shared_steady_bytes,
    );
    try testing.expect(
        pressure_before.shared_bytes - victim_candidate.reclaimable_bytes -
            second_victim_candidate.reclaimable_bytes - base_before +
            connection_slot.base_update_max_bytes >
            connection_slot.shared_steady_bytes,
    );
    const pending_before = healthy_slot.pending_bytes;
    const screen_before = try healthy_slot.screenResidentBytes(healthy_tracker);
    const attachment_before = healthy_client.connection.attachments.get(1).?;
    const base_bytes_before = try testing.allocator.dupe(u8, attachment_before.base.?);
    defer testing.allocator.free(base_bytes_before);
    try testing.expect(attachment_before.observation_token == null);
    const observation_revision_before = attachment_before.observation_revision;
    const observation_ticks_before = attachment_before.observation_ticks;
    const delta_before = fake_runtime.delta_calls;
    const reclaim_before = owner.total_pressure_reclaims;
    owner.producer_remaining[healthy.index] = healthy_client.beginProducerSweep(100);
    var attempts: usize = 0;
    while ((try healthy_slot.globalPressureRetryAfter(healthy_tracker)) == 0 and
        attempts < 100) : (attempts += 1)
        _ = try owner.pollOnce(0);
    const retry_at = try healthy_slot.globalPressureRetryAfter(healthy_tracker);
    try testing.expect(retry_at != 0);
    try testing.expectEqual(reclaim_before + 1, owner.total_pressure_reclaims);
    try testing.expectEqual(delta_before, fake_runtime.delta_calls);
    try testing.expectEqual(
        connection_slot.ScreenState.invalidated,
        try victim_slot.screenState(victim_tracker),
    );
    try testing.expectEqual(@as(usize, 0), try victim_slot.screenResidentBytes(victim_tracker));
    try testing.expectEqual(@as(usize, 0), try victim_slot.retainedBaseBytes(victim_tracker));
    try testing.expectEqual(@as(usize, 0), try victim_slot.preparedBaseBytes(victim_tracker));
    try testing.expectEqual(
        connection_slot.ScreenState.valid,
        try second_victim_slot.screenState(second_victim_tracker),
    );
    try testing.expectEqual(
        connection_slot.ScreenState.valid,
        try healthy_slot.screenState(healthy_tracker),
    );
    try testing.expectEqual(base_before, try healthy_slot.retainedBaseBytes(healthy_tracker));
    try testing.expectEqual(pending_before, healthy_slot.pending_bytes);
    try testing.expectEqual(screen_before, try healthy_slot.screenResidentBytes(healthy_tracker));
    const attachment_after = healthy_client.connection.attachments.get(1).?;
    try testing.expectEqualSlices(u8, base_bytes_before, attachment_after.base.?);
    try testing.expect(attachment_after.observation_token == null);
    try testing.expectEqual(observation_revision_before, attachment_after.observation_revision);
    try testing.expectEqual(observation_ticks_before, attachment_after.observation_ticks);
    try testing.expectEqual(@as(usize, 0), try healthy_slot.preparedBaseBytes(healthy_tracker));
    const failed_attempt = owner.reactor.accountingSnapshot();
    try testing.expectEqual(@as(usize, 0), failed_attempt.prepared_base_bytes);
    try testing.expectEqual(@as(usize, 0), failed_attempt.prepared_reclaim_bytes);
    try sendTestStream(controller_peer, .input_bytes, 1, "INPUT-DURING-BASE-BACKOFF");
    var input_attempts: usize = 0;
    while (fake_runtime.last_input_len == 0 and input_attempts < 1000) : (input_attempts += 1)
        _ = try owner.pollOnce(0);
    try testing.expectEqualStrings(
        "INPUT-DURING-BASE-BACKOFF",
        fake_runtime.last_input[0..fake_runtime.last_input_len],
    );
    try testing.expectEqual(retry_at, try healthy_slot.globalPressureRetryAfter(healthy_tracker));
    try testing.expectEqual(reclaim_before + 1, owner.total_pressure_reclaims);
    try testing.expectEqual(
        connection_slot.ScreenState.valid,
        try second_victim_slot.screenState(second_victim_tracker),
    );

    _ = healthy_client.beginProducerSweep(retry_at - 1);
    healthy_client.tick(retry_at - 1);
    try testing.expectEqual(retry_at, try healthy_slot.globalPressureRetryAfter(healthy_tracker));
    try testing.expectEqual(delta_before, fake_runtime.delta_calls);
    try testing.expectEqual(reclaim_before + 1, owner.total_pressure_reclaims);
    try testing.expectEqual(
        connection_slot.ScreenState.valid,
        try second_victim_slot.screenState(second_victim_tracker),
    );
    try testing.expectEqual(
        connection_slot.ScreenState.valid,
        try healthy_slot.screenState(healthy_tracker),
    );
    try testing.expectEqual(base_before, try healthy_slot.retainedBaseBytes(healthy_tracker));
    try testing.expectEqual(pending_before, healthy_slot.pending_bytes);
    try testing.expectEqual(screen_before, try healthy_slot.screenResidentBytes(healthy_tracker));
    const attachment_before_boundary = healthy_client.connection.attachments.get(1).?;
    try testing.expectEqualSlices(u8, base_bytes_before, attachment_before_boundary.base.?);
    try testing.expectEqual(
        observation_revision_before,
        attachment_before_boundary.observation_revision,
    );
    try testing.expectEqual(observation_ticks_before, attachment_before_boundary.observation_ticks);
    try testing.expectEqual(@as(usize, 0), try healthy_slot.preparedBaseBytes(healthy_tracker));
    const boundary_failure = owner.reactor.accountingSnapshot();
    try testing.expectEqual(@as(usize, 0), boundary_failure.prepared_base_bytes);
    try testing.expectEqual(@as(usize, 0), boundary_failure.prepared_reclaim_bytes);
    _ = healthy_client.beginProducerSweep(retry_at);
    healthy_client.tick(retry_at);
    try testing.expectEqual(
        retry_at + connection_slot.resync_retry_backoff_ns,
        try healthy_slot.globalPressureRetryAfter(healthy_tracker),
    );
    try testing.expectEqual(delta_before, fake_runtime.delta_calls);
    try testing.expectEqual(reclaim_before + 2, owner.total_pressure_reclaims);
    try testing.expectEqual(
        connection_slot.ScreenState.invalidated,
        try second_victim_slot.screenState(second_victim_tracker),
    );
    try testing.expectEqual(
        @as(usize, 0),
        try second_victim_slot.screenResidentBytes(second_victim_tracker),
    );
    try testing.expectEqual(
        connection_slot.ScreenState.valid,
        try healthy_slot.screenState(healthy_tracker),
    );
    try testing.expectEqual(base_before, try healthy_slot.retainedBaseBytes(healthy_tracker));
    try testing.expectEqual(pending_before, healthy_slot.pending_bytes);
    try testing.expectEqual(screen_before, try healthy_slot.screenResidentBytes(healthy_tracker));
    const attachment_exact = healthy_client.connection.attachments.get(1).?;
    try testing.expectEqualSlices(u8, base_bytes_before, attachment_exact.base.?);
    try testing.expect(attachment_exact.observation_token == null);
    try testing.expectEqual(observation_revision_before, attachment_exact.observation_revision);
    try testing.expectEqual(observation_ticks_before, attachment_exact.observation_ticks);
    try testing.expectEqual(@as(usize, 0), try healthy_slot.preparedBaseBytes(healthy_tracker));
    const exact_boundary_failure = owner.reactor.accountingSnapshot();
    try testing.expectEqual(@as(usize, 0), exact_boundary_failure.prepared_base_bytes);
    try testing.expectEqual(@as(usize, 0), exact_boundary_failure.prepared_reclaim_bytes);

    for (fds[0..fd_count]) |*fd| {
        _ = c.shutdown(fd.*, c.SHUT.RDWR);
        _ = c.close(fd.*);
        fd.* = -1;
    }
    var close_attempts: usize = 0;
    while (owner.activeCount() != 0 and close_attempts < 4000) : (close_attempts += 1)
        _ = try owner.pollOnce(0);
    try testing.expectEqual(@as(usize, 0), owner.activeCount());
    for (owner.clients, owner.producer_remaining) |client, remaining| {
        try testing.expect(client == null);
        try testing.expectEqual(@as(usize, 0), remaining);
    }
    try testing.expectEqual(@as(usize, 0), server.subscriptions.count());
    try testing.expectEqual(@as(usize, 0), runtime_registry.attachmentCount());
    try testing.expectEqual(@as(usize, 0), server.host_status.client_count);
    try testing.expect(!owner.admin_admission.active);
    const final = owner.reactor.accountingSnapshot();
    try testing.expectEqual(@as(usize, 0), final.resident_bytes);
    try testing.expectEqual(@as(usize, 0), final.shared_bytes);
    try testing.expectEqual(@as(usize, 0), final.prepared_base_bytes);
    try testing.expectEqual(@as(usize, 0), final.prepared_reclaim_bytes);
}

test "poll owner rolls back a batch when one reclaim is insufficient and retries atomically" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const dir_raw = dir_buf[0..dir_len];
    const dir_path = try testing.allocator.dupeZ(u8, dir_raw);
    defer testing.allocator.free(dir_path);
    const socket_path = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "{s}/insufficient-batch-reclaim.sock",
        .{dir_raw},
        0,
    );
    defer testing.allocator.free(socket_path);
    var runtime_registry = registry.TerminalRuntimeRegistry.init(testing.allocator);
    defer runtime_registry.deinit();
    _ = try runtime_registry.register(0xAA, 80, 24);
    for (0..9) |index| _ = try runtime_registry.register(0x400 + index, 80, 24);
    var server = try socket_server.SocketServer.bind(
        testing.allocator,
        dir_path,
        socket_path,
        0xB6,
        &runtime_registry,
    );
    defer server.deinit();
    server.host_status = .{ .manifest_capable = true };
    var fake_runtime: server_mod.FakeRuntimeOps = .{
        .new_base_len = 1024 * 1024,
        .delta_send_len = 7 * 1024 * 1024,
    };
    server.runtime_ops = fake_runtime.ops();
    var owner = try Owner.init(testing.allocator, testing.io, &server);
    defer owner.deinit();
    owner.next_cadence_ns = std.math.maxInt(u64);

    var fds: [12]c.fd_t = undefined;
    var fd_count: usize = 0;
    defer {
        for (fds[0..fd_count]) |fd| {
            if (fd >= 0) _ = c.close(fd);
        }
    }
    const requester = try connectAttachedTestClient(&owner, socket_path, "observer");
    fds[fd_count] = requester.fd;
    fd_count += 1;
    const first_victim = try connectAttachedTestClient(&owner, socket_path, "observer");
    fds[fd_count] = first_victim.fd;
    fd_count += 1;
    const second_victim = try connectAttachedTestClient(&owner, socket_path, "observer");
    fds[fd_count] = second_victim.fd;
    fd_count += 1;
    var pin_indices: [9]usize = undefined;
    var controller_peer: c.fd_t = -1;
    for (&pin_indices, 0..) |*pin_index, index| {
        const runtime_hex = try std.fmt.allocPrint(testing.allocator, "{x}", .{0x400 + index});
        defer testing.allocator.free(runtime_hex);
        const pin = try connectAttachedTestClientForRuntime(
            &owner,
            socket_path,
            runtime_hex,
            "controller",
        );
        fds[fd_count] = pin.fd;
        fd_count += 1;
        if (index == 0) controller_peer = pin.fd;
        pin_index.* = pin.index;
    }
    for (pin_indices) |pin_index| {
        const pin = owner.clients[pin_index].?;
        try fillServerSendBuffer(pin.fd);
        const slot = try owner.reactor.get(pin.admission);
        const tracker = pin.trackers.get(1).?;
        const pressure = try testing.allocator.alloc(u8, connection_slot.screen_soft_bytes);
        @memset(pressure, 'P');
        slot.enqueueOwnedScreen(tracker, pressure) catch |err| {
            testing.allocator.free(pressure);
            return err;
        };
        try slot.consumeWritten(1);
        pin.noteWriteStalled(10);
        try testing.expect(pin.largestScreenPressure() == null);
    }

    const victim_bytes = 1024 * 1024;
    const first_victim_client = owner.clients[first_victim.index].?;
    try fillServerSendBuffer(first_victim_client.fd);
    const first_victim_slot = try owner.reactor.get(first_victim_client.admission);
    const first_victim_tracker = first_victim_client.trackers.get(1).?;
    const first_pressure = try testing.allocator.alloc(u8, victim_bytes);
    @memset(first_pressure, 'V');
    first_victim_slot.enqueueOwnedScreen(first_victim_tracker, first_pressure) catch |err| {
        testing.allocator.free(first_pressure);
        return err;
    };
    _ = try owner.pollOnce(0);
    const first_candidate = first_victim_client.largestScreenPressure().?;

    const second_victim_client = owner.clients[second_victim.index].?;
    try fillServerSendBuffer(second_victim_client.fd);
    const second_victim_slot = try owner.reactor.get(second_victim_client.admission);
    const second_victim_tracker = second_victim_client.trackers.get(1).?;
    const second_pressure = try testing.allocator.alloc(u8, victim_bytes);
    @memset(second_pressure, 'W');
    second_victim_slot.enqueueOwnedScreen(second_victim_tracker, second_pressure) catch |err| {
        testing.allocator.free(second_pressure);
        return err;
    };
    _ = try owner.pollOnce(0);
    const second_candidate = second_victim_client.largestScreenPressure().?;

    const requester_client = owner.clients[requester.index].?;
    const requester_slot = try owner.reactor.get(requester_client.admission);
    const requester_tracker = requester_client.trackers.get(1).?;
    const attachment_before = requester_client.connection.attachments.get(1).?;
    const base_before = try testing.allocator.dupe(u8, attachment_before.base.?);
    defer testing.allocator.free(base_before);
    try testing.expect(attachment_before.observation_token == null);
    const retained_before = try requester_slot.retainedBaseBytes(requester_tracker);
    const pending_before = requester_slot.pending_bytes;
    const chunks_before = requester_slot.chunk_len;
    const screen_before = try requester_slot.screenResidentBytes(requester_tracker);
    const revision_before = attachment_before.observation_revision;
    const ticks_before = attachment_before.observation_ticks;
    const pressure_before = owner.reactor.accountingSnapshot();
    const encoded_batch_bytes =
        7 * 1024 * 1024 + 7 * protocol.header_size;
    const prepared_shared = pressure_before.shared_bytes - retained_before +
        connection_slot.base_update_max_bytes;
    try testing.expect(prepared_shared <= connection_slot.shared_steady_bytes);
    try testing.expect(
        prepared_shared + encoded_batch_bytes > connection_slot.shared_steady_bytes,
    );
    try testing.expect(
        prepared_shared - first_candidate.reclaimable_bytes + encoded_batch_bytes >
            connection_slot.shared_steady_bytes,
    );
    try testing.expect(
        prepared_shared - first_candidate.reclaimable_bytes -
            second_candidate.reclaimable_bytes + encoded_batch_bytes <=
            connection_slot.shared_steady_bytes,
    );

    const delta_before = fake_runtime.delta_calls;
    const reclaim_before = owner.total_pressure_reclaims;
    var projector_probe: BatchProjectorProbe = .{
        .owner = &owner,
        .requester_index = requester.index,
        .first_victim_index = first_victim.index,
        .second_victim_index = second_victim.index,
        .reclaim_before = reclaim_before,
        .requester_retained = retained_before,
    };
    fake_runtime.delta_probe_ctx = &projector_probe;
    fake_runtime.delta_probe = observeBatchProjector;
    owner.producer_remaining[requester.index] = requester_client.beginProducerSweep(100);
    var attempts: usize = 0;
    while ((try requester_slot.globalPressureRetryAfter(requester_tracker)) == 0 and
        attempts < 100) : (attempts += 1)
        _ = try owner.pollOnce(0);
    const retry_at = try requester_slot.globalPressureRetryAfter(requester_tracker);
    try testing.expect(retry_at != 0);
    try testing.expectEqual(@as(usize, 1), projector_probe.call_count);
    try testing.expect(projector_probe.first_entered_at_batch_stage);
    try testing.expectEqual(delta_before + 1, fake_runtime.delta_calls);
    try testing.expectEqualSlices(u8, base_before, fake_runtime.delta_base_seen[0..fake_runtime.delta_base_seen_len]);
    try testing.expectEqual(reclaim_before + 1, owner.total_pressure_reclaims);
    try testing.expectEqual(
        connection_slot.ScreenState.invalidated,
        try first_victim_slot.screenState(first_victim_tracker),
    );
    try testing.expectEqual(
        connection_slot.ScreenState.valid,
        try second_victim_slot.screenState(second_victim_tracker),
    );
    try testing.expectEqual(@as(usize, 0), try first_victim_slot.screenResidentBytes(first_victim_tracker));
    try testing.expectEqual(
        pressure_before.shared_bytes - first_candidate.reclaimable_bytes,
        owner.reactor.accountingSnapshot().shared_bytes,
    );
    try testing.expectEqual(connection_slot.ScreenState.valid, try requester_slot.screenState(requester_tracker));
    try testing.expectEqual(retained_before, try requester_slot.retainedBaseBytes(requester_tracker));
    try testing.expectEqual(pending_before, requester_slot.pending_bytes);
    try testing.expectEqual(chunks_before, requester_slot.chunk_len);
    try testing.expectEqual(screen_before, try requester_slot.screenResidentBytes(requester_tracker));
    const attachment_failed = requester_client.connection.attachments.get(1).?;
    try testing.expectEqualSlices(u8, base_before, attachment_failed.base.?);
    try testing.expect(attachment_failed.observation_token == null);
    try testing.expectEqual(revision_before, attachment_failed.observation_revision);
    try testing.expectEqual(ticks_before, attachment_failed.observation_ticks);
    try testing.expectEqual(@as(usize, 0), try requester_slot.preparedBaseBytes(requester_tracker));
    const failed = owner.reactor.accountingSnapshot();
    try testing.expectEqual(@as(usize, 0), failed.prepared_base_bytes);
    try testing.expectEqual(@as(usize, 0), failed.prepared_reclaim_bytes);
    var no_prefix: [1]u8 = undefined;
    const no_prefix_rc = c.recv(requester.fd, &no_prefix, no_prefix.len, posix.MSG.DONTWAIT);
    try testing.expect(no_prefix_rc < 0 and posix.errno(no_prefix_rc) == .AGAIN);

    try sendTestStream(controller_peer, .input_bytes, 1, "INPUT-DURING-BATCH-BACKOFF");
    var input_attempts: usize = 0;
    while (fake_runtime.last_input_len == 0 and input_attempts < 1000) : (input_attempts += 1)
        _ = try owner.pollOnce(0);
    try testing.expectEqualStrings(
        "INPUT-DURING-BATCH-BACKOFF",
        fake_runtime.last_input[0..fake_runtime.last_input_len],
    );
    try testing.expectEqual(retry_at, try requester_slot.globalPressureRetryAfter(requester_tracker));
    try testing.expectEqual(reclaim_before + 1, owner.total_pressure_reclaims);

    _ = requester_client.beginProducerSweep(retry_at - 1);
    requester_client.tick(retry_at - 1);
    try testing.expectEqual(delta_before + 1, fake_runtime.delta_calls);
    try testing.expectEqual(reclaim_before + 1, owner.total_pressure_reclaims);
    try testing.expectEqual(pending_before, requester_slot.pending_bytes);
    try testing.expectEqual(
        connection_slot.ScreenState.valid,
        try second_victim_slot.screenState(second_victim_tracker),
    );

    _ = requester_client.beginProducerSweep(retry_at);
    requester_client.tick(retry_at);
    try testing.expectEqual(delta_before + 2, fake_runtime.delta_calls);
    try testing.expectEqual(@as(usize, 2), projector_probe.call_count);
    try testing.expect(projector_probe.second_entered_at_batch_stage);
    try testing.expectEqual(reclaim_before + 2, owner.total_pressure_reclaims);
    try testing.expectEqual(
        retry_at,
        try requester_slot.globalPressureRetryAfter(requester_tracker),
    );
    try testing.expectEqual(
        connection_slot.ScreenState.invalidated,
        try second_victim_slot.screenState(second_victim_tracker),
    );
    try testing.expectEqual(connection_slot.ScreenState.valid, try requester_slot.screenState(requester_tracker));
    try testing.expectEqual(@as(usize, 1024 * 1024), try requester_slot.retainedBaseBytes(requester_tracker));
    try testing.expectEqual(@as(usize, encoded_batch_bytes), requester_slot.pending_bytes - pending_before);
    try testing.expectEqual(chunks_before + 7, requester_slot.chunk_len);
    try testing.expectEqual(
        screen_before + encoded_batch_bytes,
        try requester_slot.screenResidentBytes(requester_tracker),
    );
    const attachment_succeeded = requester_client.connection.attachments.get(1).?;
    try testing.expectEqual(@as(usize, 1024 * 1024), attachment_succeeded.base.?.len);
    try testing.expect(attachment_succeeded.base.?[0] == 'N');
    try testing.expect(attachment_succeeded.base.?[attachment_succeeded.base.?.len - 1] == 'N');
    try testing.expectEqual(@as(usize, 0), try requester_slot.preparedBaseBytes(requester_tracker));
    const succeeded = owner.reactor.accountingSnapshot();
    try testing.expectEqual(
        pressure_before.shared_bytes - first_candidate.reclaimable_bytes -
            second_candidate.reclaimable_bytes - retained_before +
            1024 * 1024 + encoded_batch_bytes,
        succeeded.shared_bytes,
    );
    try testing.expectEqual(@as(usize, 0), succeeded.prepared_base_bytes);
    try testing.expectEqual(@as(usize, 0), succeeded.prepared_reclaim_bytes);

    var parser = framing.FrameParser.init(testing.allocator);
    defer parser.deinit();
    var wire_buf: [64 * 1024]u8 = undefined;
    var wire_frames: usize = 0;
    var wire_payload_bytes: usize = 0;
    var wire_end_streams: usize = 0;
    var wire_attempts: usize = 0;
    while (wire_frames < 7 and wire_attempts < 4000) : (wire_attempts += 1) {
        _ = try owner.pollOnce(0);
        const rc = c.recv(requester.fd, &wire_buf, wire_buf.len, posix.MSG.DONTWAIT);
        if (rc < 0 and posix.errno(rc) == .AGAIN) continue;
        if (rc <= 0) return error.TestUnexpectedResult;
        try parser.push(wire_buf[0..@intCast(rc)]);
        while (try parser.next()) |frame| {
            defer frame.deinit(testing.allocator);
            try testing.expectEqual(protocol.Kind.delta_chunk, frame.header.kind);
            try testing.expectEqual(@as(u64, 1), frame.header.stream_id);
            try testing.expect(frame.payload.len != 0);
            try testing.expect(frame.payload[0] == 'D');
            try testing.expect(frame.payload[frame.payload.len - 1] == 'D');
            wire_frames += 1;
            wire_payload_bytes += frame.payload.len;
            if (frame.header.flags & protocol.Flags.end_stream != 0) {
                wire_end_streams += 1;
                try testing.expectEqual(@as(usize, 7), wire_frames);
            }
        }
    }
    try testing.expectEqual(@as(usize, 7), wire_frames);
    try testing.expectEqual(@as(usize, 7 * 1024 * 1024), wire_payload_bytes);
    try testing.expectEqual(@as(usize, 1), wire_end_streams);
    try testing.expectEqual(pending_before, requester_slot.pending_bytes);
    try testing.expectEqual(chunks_before, requester_slot.chunk_len);
    try testing.expectEqual(connection_slot.ScreenState.valid, try requester_slot.screenState(requester_tracker));

    for (fds[0..fd_count]) |*fd| {
        _ = c.shutdown(fd.*, c.SHUT.RDWR);
        _ = c.close(fd.*);
        fd.* = -1;
    }
    var close_attempts: usize = 0;
    while (owner.activeCount() != 0 and close_attempts < 4000) : (close_attempts += 1)
        _ = try owner.pollOnce(0);
    try testing.expectEqual(@as(usize, 0), owner.activeCount());
    for (owner.clients, owner.producer_remaining) |client, remaining| {
        try testing.expect(client == null);
        try testing.expectEqual(@as(usize, 0), remaining);
    }
    try testing.expectEqual(@as(usize, 0), server.subscriptions.count());
    try testing.expectEqual(@as(usize, 0), runtime_registry.attachmentCount());
    try testing.expectEqual(@as(usize, 0), server.host_status.client_count);
    try testing.expect(!owner.admin_admission.active);
    const final = owner.reactor.accountingSnapshot();
    try testing.expectEqual(@as(usize, 0), final.resident_bytes);
    try testing.expectEqual(@as(usize, 0), final.shared_bytes);
    try testing.expectEqual(@as(usize, 0), final.prepared_base_bytes);
    try testing.expectEqual(@as(usize, 0), final.prepared_reclaim_bytes);
}

test "poll owner closes only the observer whose valid screen frame reached a kernel partial write" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const dir_raw = dir_buf[0..dir_len];
    const dir_path = try testing.allocator.dupeZ(u8, dir_raw);
    defer testing.allocator.free(dir_path);
    const socket_path = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "{s}/actual-partial-pressure.sock",
        .{dir_raw},
        0,
    );
    defer testing.allocator.free(socket_path);
    var runtime_registry = registry.TerminalRuntimeRegistry.init(testing.allocator);
    defer runtime_registry.deinit();
    _ = try runtime_registry.register(0xAA, 80, 24);
    for (0..9) |index| _ = try runtime_registry.register(0x200 + index, 80, 24);
    var server = try socket_server.SocketServer.bind(
        testing.allocator,
        dir_path,
        socket_path,
        0xB4,
        &runtime_registry,
    );
    defer server.deinit();
    server.host_status = .{ .manifest_capable = true };
    var fake_runtime: server_mod.FakeRuntimeOps = .{};
    server.runtime_ops = fake_runtime.ops();
    var owner = try Owner.init(testing.allocator, testing.io, &server);
    defer owner.deinit();
    owner.next_cadence_ns = std.math.maxInt(u64);

    var fds: [12]c.fd_t = undefined;
    var fd_count: usize = 0;
    defer {
        for (fds[0..fd_count]) |fd| {
            if (fd >= 0) _ = c.close(fd);
        }
    }
    const controller = try connectAttachedTestClient(&owner, socket_path, "controller");
    fds[fd_count] = controller.fd;
    fd_count += 1;
    const healthy = try connectAttachedTestClient(&owner, socket_path, "observer");
    fds[fd_count] = healthy.fd;
    fd_count += 1;
    const partial = try connectAttachedTestClient(&owner, socket_path, "observer");
    fds[fd_count] = partial.fd;
    fd_count += 1;
    try setTinySocketBuffers(owner.clients[partial.index].?.fd, partial.fd);

    var pin_indices: [9]usize = undefined;
    for (&pin_indices, 0..) |*pin_index, index| {
        const runtime_hex = try std.fmt.allocPrint(testing.allocator, "{x}", .{0x200 + index});
        defer testing.allocator.free(runtime_hex);
        const pin = try connectAttachedTestClientForRuntime(
            &owner,
            socket_path,
            runtime_hex,
            "controller",
        );
        fds[fd_count] = pin.fd;
        fd_count += 1;
        pin_index.* = pin.index;
    }
    for (pin_indices) |pin_index| {
        const pin = owner.clients[pin_index].?;
        try fillServerSendBuffer(pin.fd);
        const slot = try owner.reactor.get(pin.admission);
        const tracker = pin.trackers.get(1).?;
        const pressure = try testing.allocator.alloc(u8, connection_slot.screen_soft_bytes);
        @memset(pressure, 'C');
        slot.enqueueOwnedScreen(tracker, pressure) catch |err| {
            testing.allocator.free(pressure);
            return err;
        };
        try slot.consumeWritten(1);
        pin.noteWriteStalled(10);
        try testing.expect(pin.largestScreenPressure() == null);
    }

    const partial_client = owner.clients[partial.index].?;
    const partial_admission = partial_client.admission;
    const partial_slot = try owner.reactor.get(partial_client.admission);
    const partial_tracker = partial_client.trackers.get(1).?;
    const payload = try testing.allocator.alloc(u8, protocol.max_binary_chunk);
    defer testing.allocator.free(payload);
    @memset(payload, 'S');
    var first_wire: ?[]u8 = null;
    defer if (first_wire) |bytes| testing.allocator.free(bytes);
    for (0..8) |index| {
        const frame_payload = if (index == 0)
            payload
        else
            payload[0 .. protocol.max_binary_chunk - 8192];
        const wire = try framing.encodeFrame(testing.allocator, .{
            .kind = .delta_chunk,
            .stream_id = 1,
            .flags = if (index == 7) protocol.Flags.end_stream else 0,
        }, frame_payload);
        if (index == 0) first_wire = try testing.allocator.dupe(u8, wire);
        partial_slot.enqueueOwnedScreen(partial_tracker, wire) catch |err| {
            testing.allocator.free(wire);
            return err;
        };
    }
    const first_len = first_wire.?.len;
    try testing.expect(first_len > connection_slot.turn_bytes);
    const pending_before = partial_slot.pending_bytes;
    var partial_attempts: usize = 0;
    while (!(try partial_slot.trackerHasWrittenPrefix(partial_tracker)) and
        partial_attempts < 100) : (partial_attempts += 1)
        _ = try owner.pollOnce(0);
    try testing.expect(try partial_slot.trackerHasWrittenPrefix(partial_tracker));
    try testing.expect(partial_slot.writeBackpressured());
    const remaining = partial_slot.firstPending().?.bytes.len;
    const initial_written = first_len - remaining;
    try testing.expect(initial_written > 0);
    // A frame larger than one write turn remains partial even when send(2) accepts the whole
    // allowance. Less than the allowance proves that the kernel itself short-wrote.
    try testing.expect(initial_written < @min(first_len, connection_slot.turn_bytes));
    try testing.expectEqual(pending_before - initial_written, partial_slot.pending_bytes);
    try testing.expect(!partial_slot.writeStallObserved());
    try testing.expect(partial_client.largestScreenPressure() == null);
    const stalled_pending = partial_slot.pending_bytes;
    _ = try owner.pollOnce(0);
    try testing.expectEqual(stalled_pending, partial_slot.pending_bytes);
    try testing.expect(partial_slot.writeStallObserved());
    try testing.expect(partial_client.largestScreenPressure() != null);
    try testing.expect(owner.clients[partial.index] != null);

    // Make the peer writable again. The next poll snapshot must clear stale stall eligibility
    // before another requester's pressure turn can select this connection.
    const early_received = try testing.allocator.alloc(u8, initial_written);
    defer testing.allocator.free(early_received);
    var early_len: usize = 0;
    var early_attempts: usize = 0;
    while (early_len < early_received.len and early_attempts < 1000) : (early_attempts += 1) {
        const rc = c.recv(
            partial.fd,
            early_received.ptr + early_len,
            early_received.len - early_len,
            posix.MSG.DONTWAIT,
        );
        if (rc < 0 and posix.errno(rc) == .AGAIN) continue;
        if (rc <= 0) return error.TestUnexpectedResult;
        early_len += @intCast(rc);
    }
    try testing.expectEqual(early_received.len, early_len);
    var ready_attempts: usize = 0;
    while (partial_slot.writeStallObserved() and ready_attempts < 100) : (ready_attempts += 1)
        _ = try owner.pollOnce(0);
    try testing.expect(!partial_slot.writeStallObserved());
    try testing.expect(partial_client.largestScreenPressure() == null);
    var restall_attempts: usize = 0;
    while (!partial_slot.writeStallObserved() and restall_attempts < 100) : (restall_attempts += 1)
        _ = try owner.pollOnce(0);
    try testing.expect(partial_slot.writeStallObserved());
    try testing.expect(partial_client.largestScreenPressure() != null);
    const written = first_len - partial_slot.firstPending().?.bytes.len;
    try testing.expect(written > initial_written);

    const healthy_client = owner.clients[healthy.index].?;
    const delta_before = fake_runtime.delta_calls;
    const active_before_reclaim = owner.activeCount();
    owner.producer_remaining[healthy.index] =
        healthy_client.beginProducerSweep(monotonicNow(testing.io));
    var pressure_attempts: usize = 0;
    while (owner.clients[partial.index] != null and pressure_attempts < 1000) : (pressure_attempts += 1)
        _ = try owner.pollOnce(0);
    try testing.expect(owner.clients[partial.index] == null);
    try testing.expectError(error.Stale, owner.reactor.get(partial_admission));
    try testing.expectEqual(active_before_reclaim - 1, owner.activeCount());
    for (pin_indices) |pin_index| try testing.expect(owner.clients[pin_index] != null);
    try testing.expectEqual(@as(usize, 1), owner.total_pressure_reclaims);

    // Drain only after canonical close. Exact incomplete prefix followed by EOF proves reclaim
    // appended no invalidation suffix that could splice the peer's MRSH stream.
    const received = try testing.allocator.alloc(u8, written);
    defer testing.allocator.free(received);
    @memcpy(received[0..early_len], early_received);
    var received_len: usize = early_len;
    var eof_attempts: usize = 0;
    var saw_eof = false;
    while (!saw_eof and eof_attempts < 1000) : (eof_attempts += 1) {
        var extra: [1]u8 = undefined;
        const target = if (received_len < received.len)
            received[received_len..]
        else
            extra[0..];
        const rc = c.recv(partial.fd, target.ptr, target.len, posix.MSG.DONTWAIT);
        if (rc < 0 and posix.errno(rc) == .AGAIN) continue;
        if (rc < 0) return error.TestUnexpectedResult;
        if (rc == 0) {
            saw_eof = true;
            break;
        }
        if (received_len == received.len) return error.TestUnexpectedResult;
        received_len += @intCast(rc);
    }
    try testing.expect(saw_eof);
    try testing.expectEqual(written, received_len);
    try testing.expectEqualSlices(u8, first_wire.?[0..written], received);
    var incomplete_parser = framing.FrameParser.init(testing.allocator);
    defer incomplete_parser.deinit();
    try incomplete_parser.push(received);
    try testing.expect((try incomplete_parser.next()) == null);

    owner.producer_remaining[healthy.index] =
        healthy_client.beginProducerSweep(monotonicNow(testing.io));
    try pumpUntilResponse(&owner, healthy.fd, "DELTA-BYTES");
    try testing.expect(fake_runtime.delta_calls > delta_before);
    const first_healthy_delta = fake_runtime.delta_calls;
    owner.producer_remaining[healthy.index] =
        healthy_client.beginProducerSweep(monotonicNow(testing.io));
    try pumpUntilResponse(&owner, healthy.fd, "DELTA-BYTES");
    try testing.expect(fake_runtime.delta_calls > first_healthy_delta);
    try testing.expect(owner.clients[controller.index] != null);
    try sendTestStream(controller.fd, .input_bytes, 1, "CTRL-AFTER-PARTIAL");
    var input_attempts: usize = 0;
    while (fake_runtime.last_input_len == 0 and input_attempts < 1000) : (input_attempts += 1)
        _ = try owner.pollOnce(0);
    try testing.expectEqualStrings(
        "CTRL-AFTER-PARTIAL",
        fake_runtime.last_input[0..fake_runtime.last_input_len],
    );

    for (fds[0..fd_count]) |*fd| {
        _ = c.shutdown(fd.*, c.SHUT.RDWR);
        _ = c.close(fd.*);
        fd.* = -1;
    }
    var close_attempts: usize = 0;
    while (owner.activeCount() != 0 and close_attempts < 4000) : (close_attempts += 1)
        _ = try owner.pollOnce(0);
    try testing.expectEqual(@as(usize, 0), owner.activeCount());
    try testing.expectEqual(@as(usize, 0), server.subscriptions.count());
    try testing.expectEqual(@as(usize, 0), runtime_registry.attachmentCount());
    const final = owner.reactor.accountingSnapshot();
    try testing.expectEqual(@as(usize, 0), final.resident_bytes);
    try testing.expectEqual(@as(usize, 0), final.shared_bytes);
    try testing.expectEqual(@as(usize, 0), final.prepared_base_bytes);
    try testing.expectEqual(@as(usize, 0), final.prepared_reclaim_bytes);
}

test "poll owner keeps connection-local stream one distinct across live slot reuse" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const dir_raw = dir_buf[0..dir_len];
    const dir_path = try testing.allocator.dupeZ(u8, dir_raw);
    defer testing.allocator.free(dir_path);
    const socket_path = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "{s}/subscriptions.sock",
        .{dir_raw},
        0,
    );
    defer testing.allocator.free(socket_path);
    var runtime_registry = registry.TerminalRuntimeRegistry.init(testing.allocator);
    defer runtime_registry.deinit();
    _ = try runtime_registry.register(0xAA, 80, 24);
    var server = try socket_server.SocketServer.bind(
        testing.allocator,
        dir_path,
        socket_path,
        0xB1,
        &runtime_registry,
    );
    defer server.deinit();
    server.host_status = .{ .manifest_capable = true };
    var fake_runtime: server_mod.FakeRuntimeOps = .{};
    server.runtime_ops = fake_runtime.ops();
    var owner = try Owner.init(testing.allocator, testing.io, &server);
    defer owner.deinit();

    var first_fd = try connectTestClient(socket_path);
    defer {
        if (first_fd >= 0) _ = c.close(first_fd);
    }
    _ = try owner.pollOnce(5);
    try sendTestRequest(first_fd, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"gui\"}");
    try pumpUntilResponse(&owner, first_fd, "host_id");
    const first_admission = try admittedKeyExcept(&owner, null);
    const first_key = first_admission.key;
    var second_fd = try connectTestClient(socket_path);
    defer {
        if (second_fd >= 0) _ = c.close(second_fd);
    }
    _ = try owner.pollOnce(5);
    try sendTestRequest(second_fd, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"gui\"}");
    try pumpUntilResponse(&owner, second_fd, "host_id");
    const second_admission = try admittedKeyExcept(&owner, first_key);
    const second_key = second_admission.key;

    try sendTestRequest(
        first_fd,
        .request,
        2,
        "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"observer\"}}",
    );
    try pumpUntilLocalStreamOneSnapshot(&owner, first_fd);
    try sendTestRequest(
        second_fd,
        .request,
        2,
        "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"observer\"}}",
    );
    try pumpUntilLocalStreamOneSnapshot(&owner, second_fd);

    try testing.expect(!std.meta.eql(first_key, second_key));
    const first_subscription = server.subscriptions.resolveLocal(.{
        .connection = first_key,
        .stream_id = 1,
    }).?;
    const second_subscription = server.subscriptions.resolveLocal(.{
        .connection = second_key,
        .stream_id = 1,
    }).?;
    try testing.expect(first_subscription.value != second_subscription.value);
    try testing.expectEqual(@as(usize, 2), server.subscriptions.count());
    try testing.expectEqual(@as(usize, 2), runtime_registry.attachmentCount());
    try testing.expectEqual(first_key, server.subscriptions.resolveGlobal(first_subscription).?.connection);
    try testing.expectEqual(second_key, server.subscriptions.resolveGlobal(second_subscription).?.connection);

    _ = c.shutdown(first_fd, c.SHUT.RDWR);
    _ = c.close(first_fd);
    first_fd = -1;
    var attempts: usize = 0;
    while (owner.activeCount() != 1 and attempts < 1000) : (attempts += 1)
        _ = try owner.pollOnce(2);
    try testing.expectEqual(@as(usize, 1), owner.activeCount());
    try testing.expect(server.subscriptions.resolveLocal(.{
        .connection = first_key,
        .stream_id = 1,
    }) == null);
    try testing.expect(server.subscriptions.resolveGlobal(first_subscription) == null);
    try testing.expectEqual(second_subscription, server.subscriptions.resolveLocal(.{
        .connection = second_key,
        .stream_id = 1,
    }).?);
    try testing.expectEqual(second_key, server.subscriptions.resolveGlobal(second_subscription).?.connection);
    try testing.expectEqual(@as(usize, 1), server.subscriptions.count());
    try testing.expectEqual(@as(usize, 1), runtime_registry.attachmentCount());

    try sendTestRequest(second_fd, .request, 3, "{\"method\":\"host.info\"}");
    try pumpUntilResponse(&owner, second_fd, "runtime_count");

    var reused_fd = try connectTestClient(socket_path);
    defer {
        if (reused_fd >= 0) _ = c.close(reused_fd);
    }
    _ = try owner.pollOnce(5);
    try sendTestRequest(reused_fd, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"gui\"}");
    try pumpUntilResponse(&owner, reused_fd, "host_id");
    try sendTestRequest(
        reused_fd,
        .request,
        2,
        "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"observer\"}}",
    );
    try pumpUntilLocalStreamOneSnapshot(&owner, reused_fd);
    const reused_admission = try admittedKeyExcept(&owner, second_key);
    const reused_key = reused_admission.key;
    const reused_subscription = server.subscriptions.resolveLocal(.{
        .connection = reused_key,
        .stream_id = 1,
    }).?;
    try testing.expectEqual(first_admission.index, reused_admission.index);
    try testing.expect(first_key.slot_generation != reused_key.slot_generation);
    try testing.expectEqual(
        reused_key,
        server.subscriptions.resolveGlobal(reused_subscription).?.connection,
    );
    try testing.expect(!std.meta.eql(first_key, reused_key));
    try testing.expect(reused_subscription.value != first_subscription.value);
    try testing.expect(server.subscriptions.resolveLocal(.{
        .connection = first_key,
        .stream_id = 1,
    }) == null);
    try testing.expect(server.subscriptions.resolveGlobal(first_subscription) == null);
    try testing.expectEqual(@as(usize, 2), server.subscriptions.count());
    try testing.expectEqual(@as(usize, 2), runtime_registry.attachmentCount());

    _ = c.shutdown(reused_fd, c.SHUT.RDWR);
    _ = c.close(reused_fd);
    reused_fd = -1;
    _ = c.shutdown(second_fd, c.SHUT.RDWR);
    _ = c.close(second_fd);
    second_fd = -1;
    attempts = 0;
    while (owner.activeCount() != 0 and attempts < 1000) : (attempts += 1)
        _ = try owner.pollOnce(2);
    try testing.expectEqual(@as(usize, 0), owner.activeCount());
    try testing.expectEqual(@as(usize, 0), server.subscriptions.count());
    try testing.expectEqual(@as(usize, 0), runtime_registry.attachmentCount());
}

test "poll owner atomically transfers controller across local stream one peers" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const dir_raw = dir_buf[0..dir_len];
    const dir_path = try testing.allocator.dupeZ(u8, dir_raw);
    defer testing.allocator.free(dir_path);
    const socket_path = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "{s}/controller-takeover.sock",
        .{dir_raw},
        0,
    );
    defer testing.allocator.free(socket_path);

    var runtime_registry = registry.TerminalRuntimeRegistry.init(testing.allocator);
    defer runtime_registry.deinit();
    _ = try runtime_registry.register(0xAA, 80, 24);
    var server = try socket_server.SocketServer.bind(
        testing.allocator,
        dir_path,
        socket_path,
        0xB3,
        &runtime_registry,
    );
    defer server.deinit();
    server.host_status = .{ .manifest_capable = true, .upgrade_capable = true };
    var fake_runtime: server_mod.FakeRuntimeOps = .{};
    server.runtime_ops = fake_runtime.ops();
    var gate = upgrade.AdmissionGate.init(testing.io);
    server.admission_gate = &gate;
    var upgrade_owner: TestUpgradeOwner = .{};
    server.upgrade_ops = upgrade_owner.ops();
    var owner = try Owner.init(testing.allocator, testing.io, &server);
    defer owner.deinit();

    var old = try connectAttachedTestClient(&owner, socket_path, "controller");
    defer {
        if (old.fd >= 0) _ = c.close(old.fd);
    }
    var next = try connectAttachedTestClient(&owner, socket_path, "observer");
    defer {
        if (next.fd >= 0) _ = c.close(next.fd);
    }
    var third = try connectAttachedTestClient(&owner, socket_path, "observer");
    defer {
        if (third.fd >= 0) _ = c.close(third.fd);
    }
    var upgrade_fd = try connectTestClient(socket_path);
    defer {
        if (upgrade_fd >= 0) _ = c.close(upgrade_fd);
    }
    _ = try owner.pollOnce(5);
    try sendTestRequest(
        upgrade_fd,
        .hello,
        1,
        "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"gui\"}",
    );
    try pumpUntilResponse(&owner, upgrade_fd, "host_id");
    const old_key = owner.clients[old.index].?.admission.key;
    const next_key = owner.clients[next.index].?.admission.key;
    const old_subscription = server.subscriptions.resolveLocal(.{
        .connection = old_key,
        .stream_id = 1,
    }).?;
    const next_subscription = server.subscriptions.resolveLocal(.{
        .connection = next_key,
        .stream_id = 1,
    }).?;
    try testing.expect(old_subscription.value != next_subscription.value);
    try sendTestRequest(
        third.fd,
        .request,
        3,
        "{\"method\":\"controller.status\",\"params\":{\"stream_id\":1}}",
    );
    try pumpUntilResponse(&owner, third.fd, "\"controller_generation\":1");

    // Put upgrade and takeover into two kernel receive queues before polling. Either readiness
    // order must leave upgrade unstaged and let the authority transition complete in one turn.
    try sendTestRequest(
        upgrade_fd,
        .request,
        2,
        "{\"method\":\"host.upgrade.prepare\",\"params\":{\"attempt_id\":\"0000000000000000000000000000b301\",\"target_path\":\"/Applications/Maru.app/Contents/MacOS/maru\",\"target_build_id\":\"sha256:build\",\"target_sha256\":\"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\",\"handoff_reader_min\":1,\"handoff_reader_max\":1}}",
    );
    try sendTestRequest(
        next.fd,
        .request,
        3,
        "{\"method\":\"controller.takeover\",\"params\":{\"stream_id\":1,\"expected_controller_generation\":1}}",
    );
    // Do not read the old peer yet: socket delivery is not the authority linearization point.
    try pumpUntilResponse(&owner, next.fd, "\"controller_generation\":2");
    try pumpUntilResponse(&owner, upgrade_fd, "upgrade_busy");
    try testing.expectEqual(@as(usize, 0), upgrade_owner.staged);
    try testing.expect(gate.snapshot().open);
    try testing.expectEqual(
        registry.Capability.observe,
        runtime_registry.capabilitiesOfSubscription(0xAA, old_subscription),
    );
    try testing.expect(registry.Capability.has(
        runtime_registry.capabilitiesOfSubscription(0xAA, next_subscription),
        registry.Capability.input,
    ));
    try testing.expect(!Owner.upgradePreflight(
        &owner,
        owner.clients[next.index].?,
    ));
    // A third long-lived observer's pre-transfer intent is stale, but it can refresh generation
    // without detach/reattach and require a new explicit user confirmation before retrying.
    try sendTestRequest(
        third.fd,
        .request,
        4,
        "{\"method\":\"controller.takeover\",\"params\":{\"stream_id\":1,\"expected_controller_generation\":1}}",
    );
    try pumpUntilResponse(&owner, third.fd, "\"invalid_generation\"");
    try sendTestRequest(
        third.fd,
        .request,
        5,
        "{\"method\":\"controller.status\",\"params\":{\"stream_id\":1}}",
    );
    try pumpUntilResponse(&owner, third.fd, "\"controller_generation\":2");

    fake_runtime.last_input_len = 0;
    try sendTestStream(old.fd, .input_bytes, 1, "OLD-DENIED");
    for (0..16) |_| _ = try owner.pollOnce(0);
    try testing.expectEqual(@as(usize, 0), fake_runtime.last_input_len);
    try sendTestStream(next.fd, .input_bytes, 1, "NEW-ALLOWED");
    var attempts: usize = 0;
    while (fake_runtime.last_input_len == 0 and attempts < 1000) : (attempts += 1)
        _ = try owner.pollOnce(0);
    try testing.expectEqualStrings(
        "NEW-ALLOWED",
        fake_runtime.last_input[0..fake_runtime.last_input_len],
    );
    try pumpUntilResponse(&owner, old.fd, "controller.revoked");

    // Post-commit old EOF removes only its observer lease and cannot restore it as controller.
    _ = c.shutdown(old.fd, c.SHUT.RDWR);
    _ = c.close(old.fd);
    old.fd = -1;
    attempts = 0;
    while (owner.clients[old.index] != null and attempts < 1000) : (attempts += 1)
        _ = try owner.pollOnce(0);
    try testing.expect(owner.clients[old.index] == null);
    try testing.expect(registry.Capability.has(
        runtime_registry.capabilitiesOfSubscription(0xAA, next_subscription),
        registry.Capability.input,
    ));

    // Reverse the enqueue order for release versus upgrade. Attachments and the transition's
    // dispatch/control authority keep upgrade fail-closed without starving release.
    try sendTestRequest(
        next.fd,
        .request,
        4,
        "{\"method\":\"controller.release\",\"params\":{\"stream_id\":1,\"expected_controller_generation\":2}}",
    );
    try sendTestRequest(
        upgrade_fd,
        .request,
        3,
        "{\"method\":\"host.upgrade.prepare\",\"params\":{\"attempt_id\":\"0000000000000000000000000000b302\",\"target_path\":\"/Applications/Maru.app/Contents/MacOS/maru\",\"target_build_id\":\"sha256:build\",\"target_sha256\":\"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\",\"handoff_reader_min\":1,\"handoff_reader_max\":1}}",
    );
    try pumpUntilResponse(&owner, next.fd, "\"controller_generation\":3");
    try pumpUntilResponse(&owner, upgrade_fd, "upgrade_busy");
    try testing.expectEqual(@as(usize, 0), upgrade_owner.staged);
    try testing.expect(gate.snapshot().open);
    try testing.expectEqual(
        registry.Capability.observe,
        runtime_registry.capabilitiesOfSubscription(0xAA, next_subscription),
    );
    fake_runtime.last_input_len = 0;
    try sendTestStream(next.fd, .input_bytes, 1, "RELEASED-DENIED");
    for (0..16) |_| _ = try owner.pollOnce(0);
    try testing.expectEqual(@as(usize, 0), fake_runtime.last_input_len);

    _ = c.shutdown(next.fd, c.SHUT.RDWR);
    _ = c.close(next.fd);
    next.fd = -1;
    _ = c.shutdown(third.fd, c.SHUT.RDWR);
    _ = c.close(third.fd);
    third.fd = -1;
    _ = c.shutdown(upgrade_fd, c.SHUT.RDWR);
    _ = c.close(upgrade_fd);
    upgrade_fd = -1;
    attempts = 0;
    while (owner.activeCount() != 0 and attempts < 1000) : (attempts += 1)
        _ = try owner.pollOnce(0);
    try testing.expectEqual(@as(usize, 0), owner.activeCount());
    try testing.expectEqual(@as(usize, 0), server.subscriptions.count());
    try testing.expectEqual(@as(usize, 0), runtime_registry.attachmentCount());
    const final = owner.reactor.accountingSnapshot();
    try testing.expectEqual(@as(usize, 0), final.resident_bytes);
    try testing.expectEqual(@as(usize, 0), final.shared_bytes);
    try testing.expectEqual(@as(usize, 0), final.prepared_base_bytes);
    try testing.expectEqual(@as(usize, 0), final.prepared_reclaim_bytes);
}

test "poll owner takeover admission failure preserves the old controller exactly" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const dir_raw = dir_buf[0..dir_len];
    const dir_path = try testing.allocator.dupeZ(u8, dir_raw);
    defer testing.allocator.free(dir_path);
    const socket_path = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "{s}/controller-takeover-full.sock",
        .{dir_raw},
        0,
    );
    defer testing.allocator.free(socket_path);
    var runtime_registry = registry.TerminalRuntimeRegistry.init(testing.allocator);
    defer runtime_registry.deinit();
    _ = try runtime_registry.register(0xAA, 80, 24);
    var server = try socket_server.SocketServer.bind(
        testing.allocator,
        dir_path,
        socket_path,
        0xB4,
        &runtime_registry,
    );
    defer server.deinit();
    var fake_runtime: server_mod.FakeRuntimeOps = .{};
    server.runtime_ops = fake_runtime.ops();
    var owner = try Owner.init(testing.allocator, testing.io, &server);
    defer owner.deinit();

    var old = try connectAttachedTestClient(&owner, socket_path, "controller");
    defer {
        if (old.fd >= 0) _ = c.close(old.fd);
    }
    var next = try connectAttachedTestClient(&owner, socket_path, "observer");
    defer {
        if (next.fd >= 0) _ = c.close(next.fd);
    }
    const old_client = owner.clients[old.index].?;
    const old_subscription = server.subscriptions.resolveLocal(.{
        .connection = old_client.admission.key,
        .stream_id = 1,
    }).?;
    const next_client = owner.clients[next.index].?;
    const next_subscription = server.subscriptions.resolveLocal(.{
        .connection = next_client.admission.key,
        .stream_id = 1,
    }).?;
    const generation_before = runtime_registry.get(0xAA).?.controller_generation;
    owner.controller_transition_admission_fail_once = true;

    try sendTestRequest(
        next.fd,
        .request,
        3,
        "{\"method\":\"controller.takeover\",\"params\":{\"stream_id\":1,\"expected_controller_generation\":1}}",
    );
    try pumpUntilResponse(&owner, next.fd, "\"resource_exhausted\"");
    try testing.expect(owner.clients[next.index] != null);
    try testing.expectEqual(
        generation_before,
        runtime_registry.get(0xAA).?.controller_generation,
    );
    try testing.expect(registry.Capability.has(
        runtime_registry.capabilitiesOfSubscription(0xAA, old_subscription),
        registry.Capability.input,
    ));
    try testing.expectEqual(
        registry.Capability.observe,
        runtime_registry.capabilitiesOfSubscription(0xAA, next_subscription),
    );
    try testing.expectEqual(@as(usize, 2), server.subscriptions.count());
    try testing.expectEqual(@as(usize, 2), runtime_registry.attachmentCount());

    try sendTestRequest(
        next.fd,
        .request,
        4,
        "{\"method\":\"controller.takeover\",\"params\":{\"stream_id\":1,\"expected_controller_generation\":1}}",
    );
    try pumpUntilResponse(&owner, next.fd, "\"controller_generation\":2");
    try pumpUntilResponse(&owner, old.fd, "controller.revoked");
    owner.controller_transition_admission_fail_once = true;
    try sendTestRequest(
        next.fd,
        .request,
        5,
        "{\"method\":\"controller.release\",\"params\":{\"stream_id\":1,\"expected_controller_generation\":2}}",
    );
    try pumpUntilResponse(&owner, next.fd, "\"resource_exhausted\"");
    try testing.expectEqual(
        @as(u64, 2),
        runtime_registry.get(0xAA).?.controller_generation,
    );
    try testing.expect(registry.Capability.has(
        runtime_registry.capabilitiesOfSubscription(0xAA, next_subscription),
        registry.Capability.input,
    ));

    _ = c.shutdown(old.fd, c.SHUT.RDWR);
    _ = c.close(old.fd);
    old.fd = -1;
    _ = c.shutdown(next.fd, c.SHUT.RDWR);
    _ = c.close(next.fd);
    next.fd = -1;
    var attempts: usize = 0;
    while (owner.activeCount() != 0 and attempts < 2000) : (attempts += 1)
        _ = try owner.pollOnce(0);
    try testing.expectEqual(@as(usize, 0), owner.activeCount());
    try testing.expectEqual(@as(usize, 0), server.subscriptions.count());
    try testing.expectEqual(@as(usize, 0), runtime_registry.attachmentCount());
    const final = owner.reactor.accountingSnapshot();
    try testing.expectEqual(@as(usize, 0), final.resident_bytes);
    try testing.expectEqual(@as(usize, 0), final.shared_bytes);
}

test "poll owner controller transition converges across old and requester EOF linearization" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const Scenario = enum {
        old_eof_before_request,
        requester_eof_before_owner_poll,
        requester_eof_after_commit,
    };
    inline for (std.meta.tags(Scenario)) |scenario| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
        const dir_raw = dir_buf[0..dir_len];
        const dir_path = try testing.allocator.dupeZ(u8, dir_raw);
        defer testing.allocator.free(dir_path);
        const socket_path = try std.fmt.allocPrintSentinel(
            testing.allocator,
            "{s}/ce{d}.sock",
            .{ dir_raw, @intFromEnum(scenario) },
            0,
        );
        defer testing.allocator.free(socket_path);
        var runtime_registry = registry.TerminalRuntimeRegistry.init(testing.allocator);
        defer runtime_registry.deinit();
        _ = try runtime_registry.register(0xAA, 80, 24);
        var server = try socket_server.SocketServer.bind(
            testing.allocator,
            dir_path,
            socket_path,
            0xB5,
            &runtime_registry,
        );
        defer server.deinit();
        var fake_runtime: server_mod.FakeRuntimeOps = .{};
        server.runtime_ops = fake_runtime.ops();
        var owner = try Owner.init(testing.allocator, testing.io, &server);
        defer owner.deinit();
        var old = try connectAttachedTestClient(&owner, socket_path, "controller");
        defer {
            if (old.fd >= 0) _ = c.close(old.fd);
        }
        var next = try connectAttachedTestClient(&owner, socket_path, "observer");
        defer {
            if (next.fd >= 0) _ = c.close(next.fd);
        }
        const old_subscription = server.subscriptions.resolveLocal(.{
            .connection = owner.clients[old.index].?.admission.key,
            .stream_id = 1,
        }).?;
        const next_subscription = server.subscriptions.resolveLocal(.{
            .connection = owner.clients[next.index].?.admission.key,
            .stream_id = 1,
        }).?;

        if (scenario == .old_eof_before_request) {
            _ = c.shutdown(old.fd, c.SHUT.RDWR);
            _ = c.close(old.fd);
            old.fd = -1;
            var attempts: usize = 0;
            while (owner.clients[old.index] != null and attempts < 1000) : (attempts += 1)
                _ = try owner.pollOnce(0);
            try testing.expect(runtime_registry.get(0xAA).?.controller == null);
            try testing.expectEqual(
                @as(u64, 1),
                runtime_registry.get(0xAA).?.controller_generation,
            );
            try sendTestRequest(
                next.fd,
                .request,
                3,
                "{\"method\":\"controller.takeover\",\"params\":{\"stream_id\":1,\"expected_controller_generation\":1}}",
            );
            try pumpUntilResponse(&owner, next.fd, "\"controller_generation\":2");
            try testing.expect(registry.Capability.has(
                runtime_registry.capabilitiesOfSubscription(
                    0xAA,
                    next_subscription,
                ),
                registry.Capability.input,
            ));
        } else if (scenario == .requester_eof_before_owner_poll) {
            try sendTestRequest(
                next.fd,
                .request,
                3,
                "{\"method\":\"controller.takeover\",\"params\":{\"stream_id\":1,\"expected_controller_generation\":1}}",
            );
            _ = c.shutdown(next.fd, c.SHUT.RDWR);
            _ = c.close(next.fd);
            next.fd = -1;
            var attempts: usize = 0;
            while (owner.clients[next.index] != null and attempts < 1000) : (attempts += 1)
                _ = try owner.pollOnce(0);
            try testing.expect(owner.clients[next.index] == null);
            const runtime = runtime_registry.get(0xAA).?;
            try testing.expect(
                (runtime.controller_generation == 1 and
                    runtime.controller != null and
                    runtime.controller.? == old_subscription.value and
                    registry.Capability.has(
                        runtime_registry.capabilitiesOfSubscription(
                            0xAA,
                            old_subscription,
                        ),
                        registry.Capability.input,
                    )) or
                    (runtime.controller_generation == 2 and
                        runtime.controller == null and
                        runtime_registry.capabilitiesOfSubscription(
                            0xAA,
                            old_subscription,
                        ) == registry.Capability.observe),
            );
            try testing.expect(
                runtime_registry.capabilitiesOfSubscription(
                    0xAA,
                    next_subscription,
                ) == 0,
            );
        } else {
            try sendTestRequest(
                next.fd,
                .request,
                3,
                "{\"method\":\"controller.takeover\",\"params\":{\"stream_id\":1,\"expected_controller_generation\":1}}",
            );
            var attempts: usize = 0;
            while (!registry.Capability.has(
                runtime_registry.capabilitiesOfSubscription(
                    0xAA,
                    next_subscription,
                ),
                registry.Capability.input,
            ) and attempts < 1000) : (attempts += 1)
                _ = try owner.pollOnce(0);
            try testing.expect(registry.Capability.has(
                runtime_registry.capabilitiesOfSubscription(
                    0xAA,
                    next_subscription,
                ),
                registry.Capability.input,
            ));
            _ = c.shutdown(next.fd, c.SHUT.RDWR);
            _ = c.close(next.fd);
            next.fd = -1;
            attempts = 0;
            while (owner.clients[next.index] != null and attempts < 1000) : (attempts += 1)
                _ = try owner.pollOnce(0);
            try testing.expect(runtime_registry.get(0xAA).?.controller == null);
            try testing.expectEqual(
                registry.Capability.observe,
                runtime_registry.capabilitiesOfSubscription(
                    0xAA,
                    old_subscription,
                ),
            );
            try testing.expectEqual(
                @as(u64, 2),
                runtime_registry.get(0xAA).?.controller_generation,
            );
        }

        if (old.fd >= 0) {
            _ = c.shutdown(old.fd, c.SHUT.RDWR);
            _ = c.close(old.fd);
            old.fd = -1;
        }
        if (next.fd >= 0) {
            _ = c.shutdown(next.fd, c.SHUT.RDWR);
            _ = c.close(next.fd);
            next.fd = -1;
        }
        var close_attempts: usize = 0;
        while (owner.activeCount() != 0 and close_attempts < 1000) : (close_attempts += 1)
            _ = try owner.pollOnce(0);
        try testing.expectEqual(@as(usize, 0), owner.activeCount());
        try testing.expectEqual(@as(usize, 0), server.subscriptions.count());
        try testing.expectEqual(@as(usize, 0), runtime_registry.attachmentCount());
    }
}

test "poll owner keeps committed controller after partial revocation write and old close" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const dir_raw = dir_buf[0..dir_len];
    const dir_path = try testing.allocator.dupeZ(u8, dir_raw);
    defer testing.allocator.free(dir_path);
    const socket_path = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "{s}/cp.sock",
        .{dir_raw},
        0,
    );
    defer testing.allocator.free(socket_path);
    var runtime_registry = registry.TerminalRuntimeRegistry.init(testing.allocator);
    defer runtime_registry.deinit();
    _ = try runtime_registry.register(0xAA, 80, 24);
    var server = try socket_server.SocketServer.bind(
        testing.allocator,
        dir_path,
        socket_path,
        0xB6,
        &runtime_registry,
    );
    defer server.deinit();
    var fake_runtime: server_mod.FakeRuntimeOps = .{};
    server.runtime_ops = fake_runtime.ops();
    var owner = try Owner.init(testing.allocator, testing.io, &server);
    defer owner.deinit();
    var old = try connectAttachedTestClient(&owner, socket_path, "controller");
    defer {
        if (old.fd >= 0) _ = c.close(old.fd);
    }
    var next = try connectAttachedTestClient(&owner, socket_path, "observer");
    defer {
        if (next.fd >= 0) _ = c.close(next.fd);
    }
    // The attach helper proves that the peer received the response and final snapshot chunk, but
    // a platform scheduling boundary may still leave cadence/sibling output resident or scheduled
    // in either server slot. This fixture starts specifically at the revocation partial-write
    // boundary, so freeze unrelated producer cadence and establish an exact quiescent precondition
    // before issuing the takeover.
    owner.next_cadence_ns = std.math.maxInt(u64);
    try drainAttachedPairOutputAndProducers(&owner, old, next);
    try testing.expectEqual(
        @as(usize, 0),
        (try owner.reactor.get(owner.clients[old.index].?.admission)).pending_bytes,
    );
    try testing.expectEqual(
        @as(usize, 0),
        (try owner.reactor.get(owner.clients[next.index].?.admission)).pending_bytes,
    );
    try testing.expectEqual(@as(usize, 0), owner.producer_remaining[old.index]);
    try testing.expectEqual(@as(usize, 0), owner.producer_remaining[next.index]);
    const next_subscription = server.subscriptions.resolveLocal(.{
        .connection = owner.clients[next.index].?.admission.key,
        .stream_id = 1,
    }).?;

    try sendTestRequest(
        next.fd,
        .request,
        3,
        "{\"method\":\"controller.takeover\",\"params\":{\"stream_id\":1,\"expected_controller_generation\":1}}",
    );
    var attempts: usize = 0;
    while (runtime_registry.get(0xAA).?.controller_generation != 2 and attempts < 1000) : (attempts += 1)
        _ = try owner.pollOnce(0);
    try testing.expectEqual(@as(u64, 2), runtime_registry.get(0xAA).?.controller_generation);
    const old_client = owner.clients[old.index].?;
    const old_slot = try owner.reactor.get(old_client.admission);
    const revocation = old_slot.firstPending().?;
    try testing.expect(
        std.mem.indexOf(u8, revocation.bytes, "controller.revoked") != null,
    );
    const first_revocation_byte = revocation.bytes[0];
    try testing.expectEqual(
        @as(isize, 1),
        c.send(old_client.fd, revocation.bytes.ptr, 1, 0),
    );
    try old_slot.consumeWritten(1);
    // SOCK_STREAM may coalesce this byte with data already made readable by the preceding poll.
    // Bound recv itself to the exact prefix under test instead of asserting a packet boundary.
    var partial: [1]u8 = undefined;
    try testing.expectEqual(@as(isize, 1), c.recv(old.fd, &partial, partial.len, 0));
    try testing.expectEqual(first_revocation_byte, partial[0]);
    _ = c.shutdown(old.fd, c.SHUT.RDWR);
    attempts = 0;
    while (owner.clients[old.index] != null and attempts < 1000) : (attempts += 1)
        _ = try owner.pollOnce(0);
    try testing.expect(owner.clients[old.index] == null);
    try testing.expect(registry.Capability.has(
        runtime_registry.capabilitiesOfSubscription(0xAA, next_subscription),
        registry.Capability.input,
    ));
    try testing.expectEqual(
        next_subscription.value,
        runtime_registry.get(0xAA).?.controller.?,
    );
    try pumpUntilResponse(&owner, next.fd, "\"controller_generation\":2");

    _ = c.close(old.fd);
    old.fd = -1;
    _ = c.shutdown(next.fd, c.SHUT.RDWR);
    _ = c.close(next.fd);
    next.fd = -1;
    attempts = 0;
    while (owner.activeCount() != 0 and attempts < 1000) : (attempts += 1)
        _ = try owner.pollOnce(0);
    try testing.expectEqual(@as(usize, 0), owner.activeCount());
    try testing.expectEqual(@as(usize, 0), server.subscriptions.count());
    try testing.expectEqual(@as(usize, 0), runtime_registry.attachmentCount());
    const final = owner.reactor.accountingSnapshot();
    try testing.expectEqual(@as(usize, 0), final.resident_bytes);
    try testing.expectEqual(@as(usize, 0), final.shared_bytes);
}

test "poll owner publishes changed resize to controller and observer all or none" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const dir_raw = dir_buf[0..dir_len];
    const dir_path = try testing.allocator.dupeZ(u8, dir_raw);
    defer testing.allocator.free(dir_path);
    const socket_path = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "{s}/resize.sock",
        .{dir_raw},
        0,
    );
    defer testing.allocator.free(socket_path);
    var runtime_registry = registry.TerminalRuntimeRegistry.init(testing.allocator);
    defer runtime_registry.deinit();
    const runtime = try runtime_registry.register(0xAA, 80, 24);
    var server = try socket_server.SocketServer.bind(
        testing.allocator,
        dir_path,
        socket_path,
        0xB9,
        &runtime_registry,
    );
    defer server.deinit();
    var fake_runtime: server_mod.FakeRuntimeOps = .{};
    server.runtime_ops = fake_runtime.ops();
    var owner = try Owner.init(testing.allocator, testing.io, &server);
    defer owner.deinit();
    const controller = try connectAttachedTestClient(&owner, socket_path, "controller");
    defer _ = c.close(controller.fd);
    const observer = try connectAttachedTestClient(&owner, socket_path, "observer");
    defer _ = c.close(observer.fd);

    try sendTestRequest(
        controller.fd,
        .request,
        3,
        "{\"method\":\"runtime.resize\",\"params\":{\"stream_id\":1,\"cols\":100,\"rows\":30,\"client_sequence\":1}}",
    );
    try pumpUntilResponse(&owner, controller.fd, "\"changed\":true");
    try pumpUntilResponse(&owner, observer.fd, "\"event\":\"runtime.resized\"");
    try testing.expectEqual(@as(u16, 100), fake_runtime.resized_cols);
    try testing.expectEqual(@as(u16, 30), fake_runtime.resized_rows);
    try testing.expectEqual(@as(u16, 100), runtime.cols);
    try testing.expectEqual(@as(u64, 1), runtime.resize_generation);

    // Exhaust every owner-side allocation boundary in records/items/per-subscription frame
    // construction. Each failed prefix owns and frees everything, publishes no backend/registry
    // mutation, and leaves the same sequence retryable; the first non-failing index succeeds.
    var first_success: ?usize = null;
    for (0..32) |fail_index| {
        var failing = testing.FailingAllocator.init(
            testing.allocator,
            .{ .fail_index = fail_index },
        );
        owner.allocator = failing.allocator();
        try sendTestRequest(
            controller.fd,
            .request,
            40 + fail_index,
            "{\"method\":\"runtime.resize\",\"params\":{\"stream_id\":1,\"cols\":105,\"rows\":32,\"client_sequence\":2}}",
        );
        const succeeded = pumpUntilEitherResponse(
            &owner,
            controller.fd,
            "\"cols\":105",
            "\"resource_exhausted\"",
        ) catch |err| {
            owner.allocator = testing.allocator;
            return err;
        };
        owner.allocator = testing.allocator;
        if (succeeded) {
            try testing.expectEqual(@as(u64, 2), runtime.controller_sequence);
            first_success = fail_index;
            break;
        }
        try testing.expectEqual(@as(u16, 100), runtime.cols);
        try testing.expect(owner.reactor.active_mixed_batch_reservation_id == null);
    }
    try testing.expect(first_success != null);
    try testing.expectEqual(@as(u16, 105), runtime.cols);

    // A locally invalid observer is fail-closed and removed from the rebuilt target set; it
    // cannot permanently veto the controller's next canonical resize.
    const observer_client = owner.clients[observer.index].?;
    const observer_tracker = observer_client.screenTracker(1).?;
    try (try owner.reactor.get(observer_client.admission)).invalidateScreen(observer_tracker);
    try sendTestRequest(
        controller.fd,
        .request,
        31,
        "{\"method\":\"runtime.resize\",\"params\":{\"stream_id\":1,\"cols\":110,\"rows\":35,\"client_sequence\":3}}",
    );
    try pumpUntilResponse(&owner, controller.fd, "\"cols\":110");
    try testing.expect(owner.clients[observer.index] == null);
    try testing.expectEqual(@as(u16, 110), runtime.cols);
    try testing.expectEqual(@as(u64, 3), runtime.resize_generation);

    // Backend failure cancels the opaque reactor publication reservation and leaves the same
    // client sequence retryable.
    fake_runtime.resize_fail_count = 1;
    try sendTestRequest(
        controller.fd,
        .request,
        32,
        "{\"method\":\"runtime.resize\",\"params\":{\"stream_id\":1,\"cols\":115,\"rows\":36,\"client_sequence\":4}}",
    );
    try pumpUntilResponse(&owner, controller.fd, "\"internal\"");
    try testing.expect(owner.reactor.active_mixed_batch_reservation_id == null);
    try testing.expectEqual(@as(u16, 110), runtime.cols);
    try testing.expectEqual(@as(u64, 3), runtime.controller_sequence);

    // Injected owner admission failure must reject the complete publication before the backend
    // or canonical registry changes. Reactor cap+1 rollback is covered independently above.
    owner.resize_admission_fail_once = true;
    fake_runtime.resized_cols = 0;
    fake_runtime.resized_rows = 0;
    try sendTestRequest(
        controller.fd,
        .request,
        4,
        "{\"method\":\"runtime.resize\",\"params\":{\"stream_id\":1,\"cols\":120,\"rows\":40,\"client_sequence\":4}}",
    );
    try pumpUntilResponse(&owner, controller.fd, "\"resource_exhausted\"");
    try testing.expectEqual(@as(u16, 0), fake_runtime.resized_cols);
    try testing.expectEqual(@as(u16, 110), runtime.cols);
    try testing.expectEqual(@as(u16, 35), runtime.rows);
    try testing.expectEqual(@as(u64, 3), runtime.resize_generation);
    try testing.expectEqual(@as(u64, 3), runtime.controller_sequence);
}

test "poll owner rejects a prepared transition after requester slot ABA reuse" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const dir_raw = dir_buf[0..dir_len];
    const dir_path = try testing.allocator.dupeZ(u8, dir_raw);
    defer testing.allocator.free(dir_path);
    const socket_path = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "{s}/ca.sock",
        .{dir_raw},
        0,
    );
    defer testing.allocator.free(socket_path);
    var runtime_registry = registry.TerminalRuntimeRegistry.init(testing.allocator);
    defer runtime_registry.deinit();
    _ = try runtime_registry.register(0xAA, 80, 24);
    var server = try socket_server.SocketServer.bind(
        testing.allocator,
        dir_path,
        socket_path,
        0xB7,
        &runtime_registry,
    );
    defer server.deinit();
    var fake_runtime: server_mod.FakeRuntimeOps = .{};
    server.runtime_ops = fake_runtime.ops();
    var owner = try Owner.init(testing.allocator, testing.io, &server);
    defer owner.deinit();
    var old = try connectAttachedTestClient(&owner, socket_path, "controller");
    defer {
        if (old.fd >= 0) _ = c.close(old.fd);
    }
    var stale_requester = try connectAttachedTestClient(&owner, socket_path, "observer");
    defer {
        if (stale_requester.fd >= 0) _ = c.close(stale_requester.fd);
    }
    const old_subscription = server.subscriptions.resolveLocal(.{
        .connection = owner.clients[old.index].?.admission.key,
        .stream_id = 1,
    }).?;
    const stale_key = owner.clients[stale_requester.index].?.admission.key;
    const stale_subscription = server.subscriptions.resolveLocal(.{
        .connection = stale_key,
        .stream_id = 1,
    }).?;
    const prepared = try runtime_registry.prepareControllerTakeover(
        0xAA,
        stale_subscription,
    );
    const action = server_mod.Action.ControllerTransitionRequested{
        .prepared = prepared,
        .success_reply = try testing.allocator.dupe(u8, "success"),
        .stale_reply = try testing.allocator.dupe(u8, "stale"),
        .exhausted_reply = try testing.allocator.dupe(u8, "exhausted"),
        .revocation = .{
            .subscription = old_subscription,
            .frame = try testing.allocator.dupe(u8, "revoked"),
        },
    };
    owner.destroyClient(stale_requester.index, .testing);
    try testing.expect(owner.clients[stale_requester.index] == null);

    var replacement = try connectAttachedTestClient(&owner, socket_path, "observer");
    defer {
        if (replacement.fd >= 0) _ = c.close(replacement.fd);
    }
    const replacement_client = owner.clients[replacement.index].?;
    const replacement_key = replacement_client.admission.key;
    const replacement_subscription = server.subscriptions.resolveLocal(.{
        .connection = replacement_key,
        .stream_id = 1,
    }).?;
    try testing.expectEqual(stale_requester.index, replacement.index);
    try testing.expect(!std.meta.eql(stale_key, replacement_key));
    try testing.expect(stale_subscription.value != replacement_subscription.value);
    // The attach helper proves that the initial snapshot reached the peer, but a producer delta
    // may already be queued behind it. Make the ABA assertion's empty-queue precondition explicit
    // instead of depending on socket scheduling and expecting the stale control reply at the head.
    try drainQueuedTestOutput(
        &owner,
        replacement.fd,
        replacement_client.admission,
    );
    try testing.expect(Owner.applyControllerTransition(
        &owner,
        replacement_client,
        action,
    ));
    try testing.expectEqualStrings(
        "stale",
        (try owner.reactor.get(replacement_client.admission)).firstPending().?.bytes,
    );
    try testing.expectEqual(@as(u64, 1), runtime_registry.get(0xAA).?.controller_generation);
    try testing.expectEqual(
        old_subscription.value,
        runtime_registry.get(0xAA).?.controller.?,
    );
    try testing.expect(registry.Capability.has(
        runtime_registry.capabilitiesOfSubscription(0xAA, old_subscription),
        registry.Capability.input,
    ));
    try testing.expectEqual(
        registry.Capability.observe,
        runtime_registry.capabilitiesOfSubscription(0xAA, replacement_subscription),
    );
    try (try owner.reactor.get(replacement_client.admission)).consumeWritten("stale".len);

    _ = c.shutdown(stale_requester.fd, c.SHUT.RDWR);
    _ = c.close(stale_requester.fd);
    stale_requester.fd = -1;
    _ = c.shutdown(old.fd, c.SHUT.RDWR);
    _ = c.close(old.fd);
    old.fd = -1;
    _ = c.shutdown(replacement.fd, c.SHUT.RDWR);
    _ = c.close(replacement.fd);
    replacement.fd = -1;
    var attempts: usize = 0;
    while (owner.activeCount() != 0 and attempts < 1000) : (attempts += 1)
        _ = try owner.pollOnce(0);
    try testing.expectEqual(@as(usize, 0), owner.activeCount());
    try testing.expectEqual(@as(usize, 0), server.subscriptions.count());
    try testing.expectEqual(@as(usize, 0), runtime_registry.attachmentCount());
    const final = owner.reactor.accountingSnapshot();
    try testing.expectEqual(@as(usize, 0), final.resident_bytes);
    try testing.expectEqual(@as(usize, 0), final.shared_bytes);
}

test "poll owner keeps canonical GUI connection while ephemeral inventory completes" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const dir_raw = dir_buf[0..dir_len];
    const dir_path = try testing.allocator.dupeZ(u8, dir_raw);
    defer testing.allocator.free(dir_path);
    const socket_path = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "{s}/owner.sock",
        .{dir_raw},
        0,
    );
    defer testing.allocator.free(socket_path);
    var runtime_registry = registry.TerminalRuntimeRegistry.init(testing.allocator);
    defer runtime_registry.deinit();
    var server = try socket_server.SocketServer.bind(
        testing.allocator,
        dir_path,
        socket_path,
        0xAA,
        &runtime_registry,
    );
    defer server.deinit();
    server.host_status = .{ .manifest_capable = true };
    var owner = try Owner.init(testing.allocator, testing.io, &server);
    defer owner.deinit();
    const idle_now = monotonicNow(testing.io);
    try testing.expectEqual(@as(i32, 200), owner.pollTimeout(idle_now, 200));

    const gui_fd = try connectTestClient(socket_path);
    defer _ = c.close(gui_fd);
    _ = try owner.pollOnce(5);
    try sendTestRequest(gui_fd, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"gui\"}");
    try pumpUntilResponse(&owner, gui_fd, "host_id");
    try testing.expectEqual(@as(usize, 1), owner.activeCount());

    var inventory_fd = try connectTestClient(socket_path);
    defer {
        if (inventory_fd >= 0) _ = c.close(inventory_fd);
    }
    _ = try owner.pollOnce(5);
    try sendTestRequest(inventory_fd, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"cli\"}");
    try pumpUntilResponse(&owner, inventory_fd, "host_id");
    try sendTestRequest(
        inventory_fd,
        .request,
        2,
        "{\"method\":\"runtime.inventory\",\"params\":{\"cursor\":\"\",\"limit\":256,\"membership_generation\":0}}",
    );
    try pumpUntilResponse(&owner, inventory_fd, "runtime_ids");
    _ = c.close(inventory_fd);
    inventory_fd = -1;
    var attempts: usize = 0;
    while (owner.activeCount() != 1 and attempts < 100) : (attempts += 1)
        _ = try owner.pollOnce(5);
    try testing.expectEqual(@as(usize, 1), owner.activeCount());

    try sendTestRequest(gui_fd, .request, 3, "{\"method\":\"host.info\"}");
    try pumpUntilResponse(&owner, gui_fd, "runtime_count");
    try testing.expectEqual(@as(usize, 1), owner.activeCount());

    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    const rejected_fd = try connectTestClient(socket_path);
    defer _ = c.close(rejected_fd);
    owner.allocator = failing.allocator();
    _ = try owner.pollOnce(5);
    owner.allocator = testing.allocator;
    var byte: [1]u8 = undefined;
    var rejected_closed = false;
    for (0..100) |_| {
        const rc = c.recv(rejected_fd, &byte, byte.len, posix.MSG.DONTWAIT);
        if (rc == 0) {
            rejected_closed = true;
            break;
        }
        if (rc < 0 and posix.errno(rc) != .AGAIN) return error.TestUnexpectedResult;
        _ = try owner.pollOnce(1);
    }
    try testing.expect(rejected_closed);
    try testing.expectEqual(@as(usize, 1), owner.activeCount());
    try sendTestRequest(gui_fd, .request, 4, "{\"method\":\"host.info\"}");
    try pumpUntilResponse(&owner, gui_fd, "runtime_count");
}

test "poll owner admits one one-shot admin without displacing canonical GUI" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const dir_raw = dir_buf[0..dir_len];
    const dir_path = try testing.allocator.dupeZ(u8, dir_raw);
    defer testing.allocator.free(dir_path);
    const socket_path = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "{s}/admin.sock",
        .{dir_raw},
        0,
    );
    defer testing.allocator.free(socket_path);
    var runtime_registry = registry.TerminalRuntimeRegistry.init(testing.allocator);
    defer runtime_registry.deinit();
    var server = try socket_server.SocketServer.bind(
        testing.allocator,
        dir_path,
        socket_path,
        0xAD,
        &runtime_registry,
    );
    defer server.deinit();
    server.host_status = .{ .manifest_capable = true };
    var owner = try Owner.init(testing.allocator, testing.io, &server);
    defer owner.deinit();

    const gui_fd = try connectTestClient(socket_path);
    defer _ = c.close(gui_fd);
    _ = try owner.pollOnce(5);
    try sendTestRequest(gui_fd, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"gui\"}");
    try pumpUntilResponse(&owner, gui_fd, "host_id");

    const first_admin_fd = try connectTestClient(socket_path);
    defer _ = c.close(first_admin_fd);
    _ = try owner.pollOnce(5);
    try sendTestRequest(first_admin_fd, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"admin\"}");
    try pumpUntilResponse(&owner, first_admin_fd, "host_id");
    try testing.expect(owner.admin_admission.active);

    const second_admin_fd = try connectTestClient(socket_path);
    defer _ = c.close(second_admin_fd);
    _ = try owner.pollOnce(5);
    try sendTestRequest(second_admin_fd, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"admin\"}");
    try pumpUntilResponse(&owner, second_admin_fd, "resource_exhausted");
    try pumpUntilClosed(&owner, second_admin_fd);
    try testing.expect(owner.admin_admission.active);

    try sendTestRequest(first_admin_fd, .request, 2, "{\"method\":\"runtime.list\",\"params\":{}}");
    try pumpUntilResponse(&owner, first_admin_fd, "runtimes");
    try pumpUntilClosed(&owner, first_admin_fd);
    try testing.expect(!owner.admin_admission.active);
    try testing.expectEqual(@as(usize, 1), owner.activeCount());

    try sendTestRequest(gui_fd, .request, 2, "{\"method\":\"host.info\"}");
    try pumpUntilResponse(&owner, gui_fd, "runtime_count");
    try testing.expectEqual(@as(usize, 1), owner.activeCount());

    const replacement_admin_fd = try connectTestClient(socket_path);
    defer _ = c.close(replacement_admin_fd);
    _ = try owner.pollOnce(5);
    try sendTestRequest(replacement_admin_fd, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"admin\"}");
    try pumpUntilResponse(&owner, replacement_admin_fd, "host_id");
    try sendTestRequest(replacement_admin_fd, .request, 2, "{\"method\":\"runtime.terminate\",\"params\":{\"runtime_id\":\"1\"}}");
    try pumpUntilResponse(&owner, replacement_admin_fd, "unauthorized");
    try pumpUntilClosed(&owner, replacement_admin_fd);
    try testing.expect(!owner.admin_admission.active);

    try sendTestRequest(gui_fd, .request, 3, "{\"method\":\"host.info\"}");
    try pumpUntilResponse(&owner, gui_fd, "runtime_count");

    const idle_admin_fd = try connectTestClient(socket_path);
    defer _ = c.close(idle_admin_fd);
    _ = try owner.pollOnce(5);
    try sendTestRequest(idle_admin_fd, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"admin\"}");
    try pumpUntilResponse(&owner, idle_admin_fd, "host_id");
    const now_ns = monotonicNow(testing.io);
    for (owner.clients) |maybe_client| {
        const client = maybe_client orelse continue;
        if (client.connection.isAdmin())
            client.tick(now_ns +| connection_turn.admin_request_deadline_ns);
    }
    owner.next_cadence_ns = 0;
    try pumpUntilClosed(&owner, idle_admin_fd);
    try testing.expect(!owner.admin_admission.active);
    try sendTestRequest(gui_fd, .request, 4, "{\"method\":\"host.info\"}");
    try pumpUntilResponse(&owner, gui_fd, "runtime_count");

    const eof_admin_fd = try connectTestClient(socket_path);
    _ = try owner.pollOnce(5);
    try sendTestRequest(eof_admin_fd, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"admin\"}");
    try pumpUntilResponse(&owner, eof_admin_fd, "host_id");
    _ = c.close(eof_admin_fd);
    var eof_attempts: usize = 0;
    while (owner.activeCount() != 1 and eof_attempts < 1000) : (eof_attempts += 1)
        _ = try owner.pollOnce(2);
    try testing.expectEqual(@as(usize, 1), owner.activeCount());
    try testing.expect(!owner.admin_admission.active);

    const half_close_fd = try connectTestClient(socket_path);
    defer _ = c.close(half_close_fd);
    _ = try owner.pollOnce(5);
    try sendTestRequest(half_close_fd, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"admin\"}");
    try pumpUntilResponse(&owner, half_close_fd, "host_id");
    try sendTestRequest(half_close_fd, .request, 2, "{\"method\":\"runtime.list\",\"params\":{}}");
    try testing.expectEqual(@as(c_int, 0), c.shutdown(half_close_fd, c.SHUT.WR));
    try pumpUntilResponse(&owner, half_close_fd, "runtimes");
    try pumpUntilClosed(&owner, half_close_fd);
    try testing.expect(!owner.admin_admission.active);

    const peer_close_fd = try connectTestClient(socket_path);
    _ = try owner.pollOnce(5);
    try sendTestRequest(peer_close_fd, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"admin\"}");
    try pumpUntilResponse(&owner, peer_close_fd, "host_id");
    try sendTestRequest(peer_close_fd, .request, 2, "{\"method\":\"runtime.list\",\"params\":{}}");
    _ = c.close(peer_close_fd);
    var close_attempts: usize = 0;
    while (owner.activeCount() != 1 and close_attempts < 1000) : (close_attempts += 1)
        _ = try owner.pollOnce(2);
    try testing.expectEqual(@as(usize, 1), owner.activeCount());
    try testing.expect(!owner.admin_admission.active);
}

test "poll owner drains parser-resident frames past one 64-frame read turn" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const dir_raw = dir_buf[0..dir_len];
    const dir_path = try testing.allocator.dupeZ(u8, dir_raw);
    defer testing.allocator.free(dir_path);
    const socket_path = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "{s}/buffered.sock",
        .{dir_raw},
        0,
    );
    defer testing.allocator.free(socket_path);
    var runtime_registry = registry.TerminalRuntimeRegistry.init(testing.allocator);
    defer runtime_registry.deinit();
    var server = try socket_server.SocketServer.bind(
        testing.allocator,
        dir_path,
        socket_path,
        0xAB,
        &runtime_registry,
    );
    defer server.deinit();
    var owner = try Owner.init(testing.allocator, testing.io, &server);
    defer owner.deinit();

    const fd = try connectTestClient(socket_path);
    defer _ = c.close(fd);
    _ = try owner.pollOnce(5);
    try sendTestRequest(fd, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"gui\"}");
    try pumpUntilResponse(&owner, fd, "host_id");
    for (0..65) |index|
        try sendTestRequest(fd, .request, 100 + index, "{\"method\":\"host.info\"}");
    // No further client write occurs. The second owner turn must be driven solely by parser state.
    try pumpResponseCount(&owner, fd, 100, 65);
}

test "partial sibling cannot block a ready metadata request" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const dir_raw = dir_buf[0..dir_len];
    const dir_path = try testing.allocator.dupeZ(u8, dir_raw);
    defer testing.allocator.free(dir_path);
    const socket_path = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "{s}/partial.sock",
        .{dir_raw},
        0,
    );
    defer testing.allocator.free(socket_path);
    var runtime_registry = registry.TerminalRuntimeRegistry.init(testing.allocator);
    defer runtime_registry.deinit();
    var server = try socket_server.SocketServer.bind(
        testing.allocator,
        dir_path,
        socket_path,
        0xAC,
        &runtime_registry,
    );
    defer server.deinit();
    var owner = try Owner.init(testing.allocator, testing.io, &server);
    defer owner.deinit();

    const partial_fd = try connectTestClient(socket_path);
    defer _ = c.close(partial_fd);
    _ = try owner.pollOnce(5);
    const one_byte = [_]u8{'M'};
    try testing.expectEqual(@as(isize, 1), c.send(partial_fd, &one_byte, 1, 0));

    const healthy_fd = try connectTestClient(socket_path);
    defer _ = c.close(healthy_fd);
    _ = try owner.pollOnce(5);
    try sendTestRequest(
        healthy_fd,
        .hello,
        1,
        "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"gui\"}",
    );
    try pumpUntilResponse(&owner, healthy_fd, "host_id");
    try sendTestRequest(healthy_fd, .request, 2, "{\"method\":\"host.info\"}");
    try pumpUntilResponse(&owner, healthy_fd, "runtime_count");
    try testing.expectEqual(@as(usize, 2), owner.activeCount());

    var partial_slot: ?usize = null;
    for (owner.clients, 0..) |maybe_client, index|
        if (maybe_client) |client| if (!client.connection.handshakeComplete()) {
            partial_slot = index;
            break;
        };
    const stale_index = partial_slot orelse return error.TestUnexpectedResult;
    owner.producer_remaining[stale_index] = 3;
    owner.next_cadence_ns = 0;
    const now_ns = monotonicNow(testing.io);
    owner.scheduleCadence(now_ns);
    // Crossing another cadence cannot refill an unfinished epoch.
    try testing.expectEqual(@as(usize, 3), owner.producer_remaining[stale_index]);

    owner.clients[stale_index].?.created_ns = now_ns - connection_turn.handshake_deadline_ns;
    owner.next_cadence_ns = 0;
    var deadline_attempts: usize = 0;
    while (owner.activeCount() != 1 and deadline_attempts < 100) : (deadline_attempts += 1)
        _ = try owner.pollOnce(0);
    try testing.expectEqual(@as(usize, 1), owner.activeCount());

    // Reuse the middle admission hole and prove compact pollfd indices still route to the new slot.
    const replacement_fd = try connectTestClient(socket_path);
    defer _ = c.close(replacement_fd);
    _ = try owner.pollOnce(5);
    try sendTestRequest(
        replacement_fd,
        .hello,
        1,
        "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"cli\"}",
    );
    try pumpUntilResponse(&owner, replacement_fd, "host_id");
    try sendTestRequest(replacement_fd, .request, 2, "{\"method\":\"host.info\"}");
    try pumpUntilResponse(&owner, replacement_fd, "runtime_count");

    var occupied_before_slow: [max_clients]bool = undefined;
    for (owner.clients, 0..) |maybe_client, index|
        occupied_before_slow[index] = maybe_client != null;
    const slow_fd = try connectTestClient(socket_path);
    defer _ = c.close(slow_fd);
    _ = try owner.pollOnce(5);
    try sendTestRequest(
        slow_fd,
        .hello,
        1,
        "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"cli\"}",
    );
    try pumpUntilResponse(&owner, slow_fd, "host_id");
    var slow_slot: ?usize = null;
    for (owner.clients, 0..) |maybe_client, index| {
        if (!occupied_before_slow[index] and maybe_client != null) {
            slow_slot = index;
            break;
        }
    }
    const slow_index = slow_slot orelse return error.TestUnexpectedResult;
    const tiny_send_buffer: c_int = 1024;
    try testing.expectEqual(
        @as(c_int, 0),
        c.setsockopt(
            owner.clients[slow_index].?.fd,
            posix.SOL.SOCKET,
            posix.SO.SNDBUF,
            @ptrCast(&tiny_send_buffer),
            @sizeOf(c_int),
        ),
    );
    var blocked = false;
    var slow_request_id: u64 = 100;
    for (0..32) |_| {
        for (0..64) |_| {
            try sendTestRequest(slow_fd, .request, slow_request_id, "{\"method\":\"host.info\"}");
            slow_request_id += 1;
        }
        for (0..128) |_| _ = try owner.pollOnce(0);
        if (owner.clients[slow_index]) |slow_client| {
            if (slow_client.wantsWrite()) {
                blocked = true;
                break;
            }
        } else break;
    }
    try testing.expect(blocked);

    try sendTestRequest(healthy_fd, .request, 3, "{\"method\":\"host.info\"}");
    try pumpUntilResponse(&owner, healthy_fd, "runtime_count");
}

test "poll owner closes cap plus one without disturbing 32 admitted clients" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const dir_raw = dir_buf[0..dir_len];
    const dir_path = try testing.allocator.dupeZ(u8, dir_raw);
    defer testing.allocator.free(dir_path);
    const socket_path = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "{s}/cap.sock",
        .{dir_raw},
        0,
    );
    defer testing.allocator.free(socket_path);
    var runtime_registry = registry.TerminalRuntimeRegistry.init(testing.allocator);
    defer runtime_registry.deinit();
    var server = try socket_server.SocketServer.bind(
        testing.allocator,
        dir_path,
        socket_path,
        0xBB,
        &runtime_registry,
    );
    defer server.deinit();
    var owner = try Owner.init(testing.allocator, testing.io, &server);
    defer owner.deinit();

    var client_fds: [max_clients]c.fd_t = undefined;
    var count: usize = 0;
    defer {
        for (client_fds[0..count]) |fd| _ = c.close(fd);
    }
    while (count < max_clients) : (count += 1) {
        client_fds[count] = try connectTestClient(socket_path);
        var attempts: usize = 0;
        while (owner.activeCount() != count + 1 and attempts < 100) : (attempts += 1)
            _ = try owner.pollOnce(5);
        try testing.expectEqual(count + 1, owner.activeCount());
    }
    const rejected_fd = try connectTestClient(socket_path);
    defer _ = c.close(rejected_fd);
    _ = try owner.pollOnce(5);
    try testing.expectEqual(max_clients, owner.activeCount());
    try testing.expectEqual(@as(usize, 1), owner.overflow_rejected);

    var flood_fds: [8]c.fd_t = undefined;
    var flood_count: usize = 0;
    defer {
        for (flood_fds[0..flood_count]) |fd| _ = c.close(fd);
    }
    while (flood_count < flood_fds.len) : (flood_count += 1)
        flood_fds[flood_count] = try connectTestClient(socket_path);
    const rejected_before_flood = owner.overflow_rejected;
    const flood_start_ns = monotonicNow(testing.io);
    for (0..100) |_| _ = try owner.pollOnce(0);
    const flood_elapsed_ns = monotonicNow(testing.io) - flood_start_ns;
    const max_rejections = flood_elapsed_ns / cadence_ns + 1;
    try testing.expect(
        owner.overflow_rejected - rejected_before_flood <= max_rejections,
    );
    try testing.expectEqual(max_clients, owner.activeCount());

    var byte: [1]u8 = undefined;
    var closed = false;
    var attempts: usize = 0;
    while (!closed and attempts < 100) : (attempts += 1) {
        const rc = c.recv(rejected_fd, &byte, byte.len, posix.MSG.DONTWAIT);
        if (rc == 0) closed = true else if (rc < 0 and posix.errno(rc) != .AGAIN)
            return error.TestUnexpectedResult;
        if (!closed) _ = try owner.pollOnce(1);
    }
    try testing.expect(closed);

    try sendTestRequest(client_fds[0], .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"gui\"}");
    try pumpUntilResponse(&owner, client_fds[0], "host_id");
    try testing.expectEqual(max_clients, owner.activeCount());
}

const TestUpgradeOwner = struct {
    attempt_id: u128 = 0,
    staged: usize = 0,
    armed: usize = 0,
    aborted: usize = 0,
    abort_reject: bool = false,
    canceled: usize = 0,
    reject_next: bool = false,

    fn stage(ctx: *anyopaque, request: upgrade_wire.PrepareRequest) upgrade_wire.PrepareDecision {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (self.reject_next) {
            self.reject_next = false;
            return .busy;
        }
        self.attempt_id = request.attempt_id;
        self.staged += 1;
        return .accepted;
    }
    fn cancel(ctx: *anyopaque, attempt_id: u128) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (self.attempt_id == attempt_id) self.canceled += 1;
    }
    fn arm(ctx: *anyopaque, attempt_id: u128) upgrade_wire.ArmDecision {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (self.attempt_id != attempt_id) return .conflict;
        self.armed += 1;
        return .armed;
    }
    fn status(ctx: *anyopaque, attempt_id: u128) ?upgrade_wire.AttemptReport {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (self.attempt_id != attempt_id) return null;
        return .{ .status = .pending };
    }
    fn abortArmed(
        ctx: *anyopaque,
        attempt_id: u128,
        report: upgrade_wire.AttemptReport,
    ) bool {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (self.abort_reject or self.attempt_id != attempt_id or self.armed == 0 or
            report.status != .resumed or report.reason != .handoff_failed) return false;
        self.aborted += 1;
        return true;
    }
    fn ops(self: *@This()) upgrade_wire.Ops {
        return .{
            .ctx = self,
            .probe_prepare = upgrade_wire.requiresPreflight,
            .stage_pending = stage,
            .cancel_unaccepted = cancel,
            .arm_accepted = arm,
            .abort_armed = abortArmed,
            .status = status,
        };
    }
};

test "poll owner repairs only empty reactor accounting and strictly reopens gate" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const dir_raw = dir_buf[0..dir_len];
    const dir_path = try testing.allocator.dupeZ(u8, dir_raw);
    defer testing.allocator.free(dir_path);
    const socket_path = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "{s}/upgrade-repair.sock",
        .{dir_raw},
        0,
    );
    defer testing.allocator.free(socket_path);
    var runtime_registry = registry.TerminalRuntimeRegistry.init(testing.allocator);
    defer runtime_registry.deinit();
    _ = try runtime_registry.register(0xAA, 80, 24);
    var server = try socket_server.SocketServer.bind(
        testing.allocator,
        dir_path,
        socket_path,
        0xCD,
        &runtime_registry,
    );
    defer server.deinit();
    var gate = upgrade.AdmissionGate.init(testing.io);
    server.admission_gate = &gate;
    var upgrade_owner: TestUpgradeOwner = .{ .attempt_id = 0x77, .armed = 1 };
    server.upgrade_ops = upgrade_owner.ops();
    var owner = try Owner.init(testing.allocator, testing.io, &server);
    defer owner.deinit();

    try testing.expect(gate.close());
    owner.reactor.budget.resident_bytes = 1;
    try testing.expect(owner.repairEmptyUpgradeTeardown(.{ .attempt_id = 0x77 }));
    try testing.expectEqual(@as(usize, 1), upgrade_owner.aborted);
    try testing.expect(owner.reactor.drainedForUpgrade());
    try testing.expect(gate.snapshot().open);
    try testing.expect(runtime_registry.get(0xAA) != null);
    const resumed_admission = try owner.reactor.admit();
    try owner.reactor.closeConnection(resumed_admission);

    try testing.expect(gate.close());
    owner.reactor.budget.shared_bytes = 1;
    owner.admin_admission.active = true;
    try testing.expect(!owner.repairEmptyUpgradeTeardown(.{ .attempt_id = 0x77 }));
    try testing.expectEqual(@as(usize, 1), upgrade_owner.aborted);
    try testing.expect(!gate.snapshot().open);
    owner.admin_admission.active = false;
    owner.reactor.budget = .{};
    gate.reopen();

    try testing.expect(gate.close());
    owner.reactor.budget.resident_bytes = 1;
    const local_key: connection_slot.ConnectionKey = .{ .monotonic_id = 41, .slot_generation = 1 };
    _ = try server.subscriptions.register(.{ .connection = local_key, .stream_id = 1 }, 0xAA);
    try testing.expect(!owner.repairEmptyUpgradeTeardown(.{ .attempt_id = 0x77 }));
    try testing.expectEqual(@as(usize, 1), upgrade_owner.aborted);
    _ = server.subscriptions.revokeConnection(local_key);
    owner.reactor.budget = .{};
    gate.reopen();

    try testing.expect(gate.close());
    owner.reactor.budget.resident_bytes = 1;
    const orphan_subscription: subscription_identity.SubscriptionId = .{ .value = 99 };
    _ = try runtime_registry.attachSubscription(0xAA, orphan_subscription, .observer);
    try testing.expect(!owner.repairEmptyUpgradeTeardown(.{ .attempt_id = 0x77 }));
    try testing.expectEqual(@as(usize, 1), upgrade_owner.aborted);
    _ = try runtime_registry.detachSubscription(0xAA, orphan_subscription);
    owner.reactor.budget = .{};
    gate.reopen();

    try testing.expect(gate.close());
    owner.reactor.budget.resident_bytes = 1;
    const active = try owner.reactor.admit();
    try testing.expect(!owner.repairEmptyUpgradeTeardown(.{ .attempt_id = 0x77 }));
    try testing.expectEqual(@as(usize, 1), upgrade_owner.aborted);
    try owner.reactor.closeConnection(active);
    owner.reactor.budget = .{};
    gate.reopen();

    try testing.expect(gate.close());
    owner.reactor.budget.resident_bytes = 1;
    owner.producer_remaining[0] = 1;
    try testing.expect(!owner.repairEmptyUpgradeTeardown(.{ .attempt_id = 0x77 }));
    try testing.expectEqual(@as(usize, 1), upgrade_owner.aborted);
    owner.producer_remaining[0] = 0;
    owner.reactor.budget = .{};
    gate.reopen();

    var lease = gate.tryEnter().?;
    try testing.expect(gate.close());
    owner.reactor.budget.resident_bytes = 1;
    try testing.expect(!owner.repairEmptyUpgradeTeardown(.{ .attempt_id = 0x77 }));
    try testing.expectEqual(@as(usize, 1), upgrade_owner.aborted);
    lease.release();
    owner.reactor.budget = .{};
    gate.reopen();

    try testing.expect(gate.close());
    owner.reactor.budget.resident_bytes = 1;
    upgrade_owner.abort_reject = true;
    try testing.expect(!owner.repairEmptyUpgradeTeardown(.{ .attempt_id = 0x77 }));
    try testing.expectEqual(@as(usize, 1), upgrade_owner.aborted);
    try testing.expect(owner.reactor.drainedForUpgrade());
    try testing.expect(!gate.snapshot().open);
    upgrade_owner.abort_reject = false;
    gate.reopen();
}

test "poll owner drains every client before publishing typed preclosed upgrade marker" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const dir_raw = dir_buf[0..dir_len];
    const dir_path = try testing.allocator.dupeZ(u8, dir_raw);
    defer testing.allocator.free(dir_path);
    const socket_path = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "{s}/upgrade.sock",
        .{dir_raw},
        0,
    );
    defer testing.allocator.free(socket_path);
    var runtime_registry = registry.TerminalRuntimeRegistry.init(testing.allocator);
    defer runtime_registry.deinit();
    var server = try socket_server.SocketServer.bind(
        testing.allocator,
        dir_path,
        socket_path,
        0xCC,
        &runtime_registry,
    );
    defer server.deinit();
    server.host_status = .{ .manifest_capable = true, .upgrade_capable = true };
    var fake_runtime: server_mod.FakeRuntimeOps = .{};
    server.runtime_ops = fake_runtime.ops();
    _ = try runtime_registry.register(0xAA, 80, 24);
    var gate = upgrade.AdmissionGate.init(testing.io);
    server.admission_gate = &gate;
    var upgrade_owner: TestUpgradeOwner = .{};
    server.upgrade_ops = upgrade_owner.ops();
    var owner = try Owner.init(testing.allocator, testing.io, &server);
    defer owner.deinit();

    const upgrade_fd = try connectTestClient(socket_path);
    defer _ = c.close(upgrade_fd);
    _ = try owner.pollOnce(5);
    try sendTestRequest(upgrade_fd, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"gui\"}");
    try pumpUntilResponse(&owner, upgrade_fd, "host_id");
    const sibling_fd = try connectTestClient(socket_path);
    defer _ = c.close(sibling_fd);
    _ = try owner.pollOnce(5);
    try sendTestRequest(sibling_fd, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"cli\"}");
    try pumpUntilResponse(&owner, sibling_fd, "host_id");
    try testing.expectEqual(@as(usize, 2), owner.activeCount());

    const partial = [_]u8{'M'};
    try testing.expectEqual(@as(isize, 1), c.send(sibling_fd, &partial, partial.len, 0));
    for (0..4) |_| _ = try owner.pollOnce(1);
    try sendTestRequest(
        upgrade_fd,
        .request,
        20,
        "{\"method\":\"host.upgrade.prepare\",\"params\":{\"attempt_id\":\"0000000000000000000000000000aa01\",\"target_path\":\"/Applications/Maru.app/Contents/MacOS/maru\",\"target_build_id\":\"sha256:build\",\"target_sha256\":\"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\",\"handoff_reader_min\":1,\"handoff_reader_max\":1}}",
    );
    try pumpUntilResponse(&owner, upgrade_fd, "upgrade_busy");
    try testing.expectEqual(@as(usize, 0), upgrade_owner.staged);
    try testing.expect(gate.snapshot().open);
    try testing.expectEqual(@as(usize, 2), owner.activeCount());
    _ = c.shutdown(sibling_fd, c.SHUT.RDWR);
    var sibling_close_attempts: usize = 0;
    while (owner.activeCount() != 1 and sibling_close_attempts < 1000) : (sibling_close_attempts += 1)
        _ = try owner.pollOnce(2);
    try testing.expectEqual(@as(usize, 1), owner.activeCount());
    try sendTestRequest(upgrade_fd, .request, 21, "{\"method\":\"host.info\"}");
    try pumpUntilResponse(&owner, upgrade_fd, "runtime_count");

    const pipelined_prepare = try framing.encodeFrame(
        testing.allocator,
        .{ .kind = .request, .request_id = 30 },
        "{\"method\":\"host.upgrade.prepare\",\"params\":{\"attempt_id\":\"0000000000000000000000000000aa02\",\"target_path\":\"/Applications/Maru.app/Contents/MacOS/maru\",\"target_build_id\":\"sha256:build\",\"target_sha256\":\"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\",\"handoff_reader_min\":1,\"handoff_reader_max\":1}}",
    );
    defer testing.allocator.free(pipelined_prepare);
    const pipelined_info = try framing.encodeFrame(
        testing.allocator,
        .{ .kind = .request, .request_id = 31 },
        "{\"method\":\"host.info\"}",
    );
    defer testing.allocator.free(pipelined_info);
    const pipelined = try testing.allocator.alloc(
        u8,
        pipelined_prepare.len + pipelined_info.len,
    );
    defer testing.allocator.free(pipelined);
    @memcpy(pipelined[0..pipelined_prepare.len], pipelined_prepare);
    @memcpy(pipelined[pipelined_prepare.len..], pipelined_info);
    var pipeline_offset: usize = 0;
    while (pipeline_offset < pipelined.len) {
        const rc = c.send(
            upgrade_fd,
            pipelined.ptr + pipeline_offset,
            pipelined.len - pipeline_offset,
            0,
        );
        if (rc <= 0) return error.TestUnexpectedResult;
        pipeline_offset += @intCast(rc);
    }
    try pumpResponseCount(&owner, upgrade_fd, 30, 2);
    try testing.expectEqual(@as(usize, 0), upgrade_owner.staged);
    try testing.expect(gate.snapshot().open);

    var requester: ?*connection_turn.Client = null;
    for (owner.clients) |maybe_client| {
        if (maybe_client) |client| requester = client;
    }
    const queued_fd = try connectTestClient(socket_path);
    defer _ = c.close(queued_fd);
    _ = try owner.pollOnce(5);
    try sendTestRequest(queued_fd, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"cli\"}");
    try pumpUntilResponse(&owner, queued_fd, "host_id");
    var queued: ?*connection_turn.Client = null;
    for (owner.clients) |maybe_client| {
        const client = maybe_client orelse continue;
        if (client != requester.?) queued = client;
    }
    // A real prepare dispatch must close admission before peeking the sibling kernel queue, reject
    // the upgrade, reopen admission, and leave the sibling request untouched.
    try sendTestRequest(queued_fd, .request, 2, "{\"method\":\"host.info\"}");
    try sendTestRequest(
        upgrade_fd,
        .request,
        32,
        "{\"method\":\"host.upgrade.prepare\",\"params\":{\"attempt_id\":\"0000000000000000000000000000aa03\",\"target_path\":\"/Applications/Maru.app/Contents/MacOS/maru\",\"target_build_id\":\"sha256:build\",\"target_sha256\":\"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\",\"handoff_reader_min\":1,\"handoff_reader_max\":1}}",
    );
    try pumpUntilResponse(&owner, upgrade_fd, "upgrade_busy");
    try testing.expectEqual(@as(usize, 0), upgrade_owner.staged);
    try testing.expect(gate.snapshot().open);
    try pumpUntilResponse(&owner, queued_fd, "runtime_count");

    const requester_slot = try owner.reactor.get(requester.?.admission);
    upgrade_owner.reject_next = true;
    try sendTestRequest(
        upgrade_fd,
        .request,
        33,
        "{\"method\":\"host.upgrade.prepare\",\"params\":{\"attempt_id\":\"0000000000000000000000000000aa04\",\"target_path\":\"/Applications/Maru.app/Contents/MacOS/maru\",\"target_build_id\":\"sha256:build\",\"target_sha256\":\"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\",\"handoff_reader_min\":1,\"handoff_reader_max\":1}}",
    );
    try pumpUntilResponse(&owner, upgrade_fd, "upgrade_busy");
    try testing.expectEqual(@as(usize, 0), upgrade_owner.staged);
    try testing.expect(gate.snapshot().open);
    try sendTestRequest(queued_fd, .request, 3, "{\"method\":\"host.info\"}");
    try pumpUntilResponse(&owner, queued_fd, "runtime_count");

    try sendTestRequest(
        queued_fd,
        .request,
        4,
        "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"observer\"}}",
    );
    try pumpUntilResponse(&owner, queued_fd, "\"observe\":true");
    try testing.expectEqual(@as(usize, 1), server.registry.attachmentCount());
    try testing.expectEqual(@as(usize, 1), server.subscriptions.count());
    try sendTestRequest(
        upgrade_fd,
        .request,
        34,
        "{\"method\":\"host.upgrade.prepare\",\"params\":{\"attempt_id\":\"0000000000000000000000000000aa05\",\"target_path\":\"/Applications/Maru.app/Contents/MacOS/maru\",\"target_build_id\":\"sha256:build\",\"target_sha256\":\"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\",\"handoff_reader_min\":1,\"handoff_reader_max\":1}}",
    );
    try pumpUntilResponse(&owner, upgrade_fd, "upgrade_busy");
    try testing.expectEqual(@as(usize, 0), upgrade_owner.staged);
    try testing.expect(gate.snapshot().open);

    const queued_bytes = try testing.allocator.dupe(u8, "queued-reply");
    try (try owner.reactor.get(queued.?.admission)).enqueueOwnedControl(queued_bytes);
    try requester_slot.beginDispatch();
    try testing.expect(!Owner.upgradePreflight(&owner, requester.?));
    try requester_slot.endDispatch();
    _ = c.shutdown(queued_fd, c.SHUT.RDWR);
    var queued_close_attempts: usize = 0;
    while (owner.activeCount() != 1 and queued_close_attempts < 1000) : (queued_close_attempts += 1)
        _ = try owner.pollOnce(2);
    try testing.expectEqual(@as(usize, 1), owner.activeCount());

    try sendTestRequest(
        upgrade_fd,
        .request,
        2,
        "{\"method\":\"host.upgrade.prepare\",\"params\":{\"attempt_id\":\"0000000000000000000000000000aabb\",\"target_path\":\"/Applications/Maru.app/Contents/MacOS/maru\",\"target_build_id\":\"sha256:build\",\"target_sha256\":\"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\",\"handoff_reader_min\":1,\"handoff_reader_max\":1}}",
    );
    // The prepare dispatch closes admission before its accepted reply is fully drained. A peer
    // arriving in that window must remain in the listener backlog, not become a host client.
    var gate_attempts: usize = 0;
    while (gate.snapshot().open and gate_attempts < 100) : (gate_attempts += 1)
        _ = try owner.pollOnce(1);
    try testing.expect(!gate.snapshot().open);
    const late_fd = try connectTestClient(socket_path);
    defer _ = c.close(late_fd);
    const admitted_before_close = owner.total_admitted;
    for (0..5) |_| _ = try owner.pollOnce(1);
    try testing.expectEqual(admitted_before_close, owner.total_admitted);

    var outcome: Outcome = .idle;
    var attempts: usize = 0;
    while (outcome != .upgrade_ready and attempts < 1000) : (attempts += 1)
        outcome = try owner.pollOnce(5);
    try testing.expectEqual(Outcome.upgrade_ready, outcome);
    try testing.expectEqual(@as(usize, 0), owner.activeCount());
    try testing.expectEqual(@as(usize, 0), server.subscriptions.count());
    try testing.expectEqual(@as(usize, 1), upgrade_owner.staged);
    try testing.expectEqual(@as(usize, 1), upgrade_owner.armed);
    try testing.expectEqual(@as(usize, 0), upgrade_owner.canceled);
    try testing.expect(!gate.snapshot().open);
    const marker = owner.takeArmedUpgrade().?;
    try testing.expectEqual(@as(u128, 0xAABB), marker.attempt_id);
    try testing.expect(marker.gate_preclosed);
    try testing.expect(owner.takeArmedUpgrade() == null);
}

test "failed accepted upgrade reopens admission and preserves frozen sibling input" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const dir_raw = dir_buf[0..dir_len];
    const dir_path = try testing.allocator.dupeZ(u8, dir_raw);
    defer testing.allocator.free(dir_path);
    const socket_path = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "{s}/upgrade-rollback.sock",
        .{dir_raw},
        0,
    );
    defer testing.allocator.free(socket_path);
    var runtime_registry = registry.TerminalRuntimeRegistry.init(testing.allocator);
    defer runtime_registry.deinit();
    var server = try socket_server.SocketServer.bind(
        testing.allocator,
        dir_path,
        socket_path,
        0xCD,
        &runtime_registry,
    );
    defer server.deinit();
    server.host_status = .{ .manifest_capable = true, .upgrade_capable = true };
    var gate = upgrade.AdmissionGate.init(testing.io);
    server.admission_gate = &gate;
    var upgrade_owner: TestUpgradeOwner = .{};
    server.upgrade_ops = upgrade_owner.ops();
    var owner = try Owner.init(testing.allocator, testing.io, &server);
    defer owner.deinit();

    var requester_fd = try connectTestClient(socket_path);
    defer {
        if (requester_fd >= 0) _ = c.close(requester_fd);
    }
    _ = try owner.pollOnce(5);
    try sendTestRequest(requester_fd, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"gui\"}");
    try pumpUntilResponse(&owner, requester_fd, "host_id");
    const sibling_fd = try connectTestClient(socket_path);
    defer _ = c.close(sibling_fd);
    _ = try owner.pollOnce(5);
    try sendTestRequest(sibling_fd, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"cli\"}");
    try pumpUntilResponse(&owner, sibling_fd, "host_id");

    var requester: ?*connection_turn.Client = null;
    for (owner.clients) |maybe_client| {
        const client = maybe_client orelse continue;
        if (requester == null) requester = client;
    }
    var filler: [64 * 1024]u8 = [_]u8{0xA5} ** (64 * 1024);
    while (true) {
        const rc = c.send(requester.?.fd, &filler, filler.len, posix.MSG.DONTWAIT);
        if (rc < 0 and posix.errno(rc) == .AGAIN) break;
        if (rc <= 0) return error.TestUnexpectedResult;
    }
    try sendTestRequest(
        requester_fd,
        .request,
        2,
        "{\"method\":\"host.upgrade.prepare\",\"params\":{\"attempt_id\":\"0000000000000000000000000000bbcc\",\"target_path\":\"/Applications/Maru.app/Contents/MacOS/maru\",\"target_build_id\":\"sha256:build\",\"target_sha256\":\"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\",\"handoff_reader_min\":1,\"handoff_reader_max\":1}}",
    );
    var stage_attempts: usize = 0;
    while (upgrade_owner.staged == 0 and stage_attempts < 100) : (stage_attempts += 1)
        _ = try owner.pollOnce(1);
    try testing.expectEqual(@as(usize, 1), upgrade_owner.staged);
    try testing.expect(!gate.snapshot().open);

    var sibling_index: ?usize = null;
    for (owner.clients, 0..) |maybe_client, index| {
        const client = maybe_client orelse continue;
        if (client != requester.?) sibling_index = index;
    }
    owner.producer_remaining[sibling_index.?] = 3;
    try sendTestRequest(sibling_fd, .request, 2, "{\"method\":\"host.info\"}");
    for (0..5) |_| _ = try owner.pollOnce(1);
    try testing.expectEqual(@as(usize, 3), owner.producer_remaining[sibling_index.?]);
    _ = c.close(requester_fd);
    requester_fd = -1;
    var rollback_attempts: usize = 0;
    while ((!gate.snapshot().open or owner.activeCount() != 1) and
        rollback_attempts < 1000) : (rollback_attempts += 1)
        _ = try owner.pollOnce(2);
    try testing.expect(gate.snapshot().open);
    try testing.expectEqual(@as(usize, 1), owner.activeCount());
    try testing.expectEqual(@as(usize, 1), upgrade_owner.canceled);
    try testing.expectEqual(@as(usize, 0), upgrade_owner.armed);
    try testing.expect(owner.takeArmedUpgrade() == null);
    try pumpUntilResponse(&owner, sibling_fd, "runtime_count");
    try testing.expect(owner.producer_remaining[sibling_index.?] < 3);

    const admission_fail_fd = try connectTestClient(socket_path);
    defer _ = c.close(admission_fail_fd);
    _ = try owner.pollOnce(5);
    try sendTestRequest(admission_fail_fd, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"gui\"}");
    try pumpUntilResponse(&owner, admission_fail_fd, "host_id");
    var admission_fail_client: ?*connection_turn.Client = null;
    for (owner.clients) |maybe_client| {
        const client = maybe_client orelse continue;
        if (client.admission.index != sibling_index.?) admission_fail_client = client;
    }
    admission_fail_client.?.control_admission_fail_once = true;
    try sendTestRequest(
        admission_fail_fd,
        .request,
        2,
        "{\"method\":\"host.upgrade.prepare\",\"params\":{\"attempt_id\":\"0000000000000000000000000000bbdd\",\"target_path\":\"/Applications/Maru.app/Contents/MacOS/maru\",\"target_build_id\":\"sha256:build\",\"target_sha256\":\"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\",\"handoff_reader_min\":1,\"handoff_reader_max\":1}}",
    );
    var admission_fail_attempts: usize = 0;
    while ((owner.activeCount() != 1 or upgrade_owner.canceled != 2) and
        admission_fail_attempts < 1000) : (admission_fail_attempts += 1)
        _ = try owner.pollOnce(2);
    try testing.expect(gate.snapshot().open);
    try testing.expectEqual(@as(usize, 2), upgrade_owner.staged);
    try testing.expectEqual(@as(usize, 2), upgrade_owner.canceled);
    try testing.expectEqual(@as(usize, 0), upgrade_owner.armed);
    try testing.expect(owner.takeArmedUpgrade() == null);
    try sendTestRequest(sibling_fd, .request, 3, "{\"method\":\"host.info\"}");
    try pumpUntilResponse(&owner, sibling_fd, "runtime_count");
}

// 이 테스트가 증명하는 것(그리고 터미널에서 왜 중요한가): host가 client 연결을 닫는 이유 중 **정상 경로**
// (클라이언트가 스스로 닫음, host 종료)와 **비정상 경로**(backpressure로 희생시킴)를 갈라야 한다. 정상까지
// 로그로 남기면 `maru host status` 한 번에 한 줄씩 쌓여, 정작 추적해야 할 화면 압박 희생이 노이즈에 묻힌다 —
// 실제로 그렇게 만들었다가 로그가 `client_closing`으로만 채워졌다. 반대로 비정상을 안 남기면 사용자에게는
// `error=ConnectionClosed` 하나만 보이고 host가 왜 끊었는지 영영 알 수 없다. 이 분류가 그 경계다.
test "client 종료 이유: 정상 경로만 조용하고 backpressure 희생은 남긴다" {
    try testing.expect(ClientCloseReason.client_closing.isExpected());
    try testing.expect(ClientCloseReason.host_shutdown.isExpected());
    try testing.expect(ClientCloseReason.testing.isExpected());
    // 아래 둘은 사용자 세션이 갑자기 끊기는 경로다 — 반드시 흔적을 남겨야 한다.
    try testing.expect(!ClientCloseReason.screen_pressure.isExpected());
    try testing.expect(!ClientCloseReason.observer_offender.isExpected());
}

/// 선언이 바뀐 runtime 들을 이 tick 에 한 번씩 조정하고, **구독자에게 알린다**(S11-6).
///
/// 알리는 것이 이 자리에 있는 이유: client 는 `runtime.resized` 로 크기를 배운다
/// (`client_external_pump` 의 owner resize 경로). 안 알리고 줄이면 화면은 다음 delta 가
/// grid 변화를 보고 **fresh snapshot** 으로 스스로 낫지만, 맥 앱의 «크기 모델» 은 낡은 채 남아
/// 창이 잘못된 열 수로 그린다.
///
/// **최선 노력이다.** 어느 client 의 큐가 차서 못 넣어도 조정 자체를 물리지 않는다 — 크기는 이미
/// 바뀌었고, 그 client 는 다음 resize 나 재연결에서 따라잡는다. 여기서 client 를 끊는 것은
/// 사용자가 부탁하지도 않은 대가다(controller 가 «요청한» resize 와 다른 점이다).
fn reconcileViewports(self: *Owner) void {
    if (!self.server.registry.viewportDirty()) return;
    const ops = self.server.runtime_ops orelse return;
    while (socket_server.reconcileOneViewport(self.server.registry, ops)) |done|
        announceViewportResize(self, done);
}

/// `runtime.resized` 본문을 만든다. **wire 어휘를 늘리지 않는다.**
///
/// client 의 strict decoder 는 `data` 필드가 **정확히 다섯**이고 `reason` 이 **문자 그대로
/// `"controller"`** 여야 통과한다(`runtime_event_wire`: `data.count != 5`,
/// `reason_controller != true`). 그래서 `"viewport"` 같은 새 사유를 쓰면 **모든 조정이 client 에
/// malformed 로 도착한다** — 알리려던 것이 오히려 스트림을 깬다(적대적 검증 3회차에 실제로 그렇게
/// 썼다가 잡았다). 사유를 늘리려면 옛 client 가 먼저 사라져야 하는데, attach 는 같은 major 의 옛
/// client 를 정상 경로로 받아들인다. `reason` 은 판정에만 쓰이고 동작을 바꾸지 않으므로 그대로 쓴다.
fn viewportResizedBody(
    allocator: std.mem.Allocator,
    done: socket_server.ViewportReconciled,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"event\":\"runtime.resized\",\"data\":{{\"runtime_id\":\"{x:0>32}\"," ++
            "\"cols\":{d},\"rows\":{d},\"resize_generation\":{d},\"reason\":\"controller\"}}}}",
        .{ done.runtime_id, done.cols, done.rows, done.resize_generation },
    );
}

fn announceViewportResize(self: *Owner, done: socket_server.ViewportReconciled) void {
    const records = self.server.subscriptions.collectRuntimeRecords(
        self.allocator,
        done.runtime_id,
    ) catch return;
    defer self.allocator.free(records);
    for (records) |record| {
        const client = self.clientForKey(record.connection) orelse continue;
        const body = viewportResizedBody(self.allocator, done) catch continue;
        defer self.allocator.free(body);
        const frame = framing.encodeFrame(
            self.allocator,
            .{ .kind = .event, .stream_id = record.stream_id },
            body,
        ) catch continue;
        var owned = true;
        defer if (owned) self.allocator.free(frame);
        self.reactor.enqueueOwnedControlBatch(&.{.{
            .admission = client.admission,
            .bytes = frame,
        }}) catch continue;
        owned = false;
    }
}

test "S11-6 선언은 «출력이 없어도» 조정된다 — serve 루프가 그 자리를 지난다" {
    // **이 판정자가 없으면 이 축은 조용히 죽는다.** 조정 자체는 `socket_server` 판정자가 순수
    // 헬퍼로 재고, 알림 본문은 아래 판정자가 잰다. 그런데 「그 조정을 **serve 루프가 실제로
    // 부르는가**」는 아무도 안 봤다 — 처음에 그 호출이 **PTY 출력 wake 갈래 안**에 있어서,
    // 출력이 없는 세션에서는 폰이 선언해도 영영 안 좁아졌다. 폰은 읽기 전용이라 스스로 출력을
    // 만들 수도 없다(적대적 검증 4회차).
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const dir_raw = dir_buf[0..dir_len];
    const dir_path = try testing.allocator.dupeZ(u8, dir_raw);
    defer testing.allocator.free(dir_path);
    const socket_path = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "{s}/idle.sock",
        .{dir_raw},
        0,
    );
    defer testing.allocator.free(socket_path);

    var runtime_registry = registry.TerminalRuntimeRegistry.init(testing.allocator);
    defer runtime_registry.deinit();
    const runtime = try runtime_registry.register(0xAA, 80, 24);
    var server = try socket_server.SocketServer.bind(
        testing.allocator,
        dir_path,
        socket_path,
        0xB9,
        &runtime_registry,
    );
    defer server.deinit();
    var fake_runtime: server_mod.FakeRuntimeOps = .{};
    server.runtime_ops = fake_runtime.ops();
    var owner = try Owner.init(testing.allocator, testing.io, &server);
    defer owner.deinit();

    const observer = try connectAttachedTestClient(&owner, socket_path, "observer");
    defer _ = c.close(observer.fd);

    // 폰이 「나는 50열을 그린다」고 알린다. **그 뒤로 PTY 출력은 한 바이트도 없다.**
    try sendTestRequest(
        observer.fd,
        .request,
        7,
        "{\"method\":\"runtime.declare_viewport\",\"params\":{\"stream_id\":1,\"cols\":50,\"rows\":20}}",
    );
    try pumpUntilResponse(&owner, observer.fd, "\"declared\"");

    // 출력 wake 없이 루프를 돌린다 — 여기서 세션이 좁아져야 한다.
    var spins: usize = 0;
    while (spins < 64 and runtime.cols != 50) : (spins += 1) _ = try owner.pollOnce(5);

    try testing.expectEqual(@as(u16, 50), runtime.cols);
    try testing.expectEqual(@as(u16, 50), fake_runtime.resized_cols);
    // 행은 안 바꾼다(계약) — 폰이 20 을 알려도 그대로다.
    try testing.expectEqual(@as(u16, 24), runtime.rows);
}

test "S11-6 조정 알림은 client 의 strict decoder 를 통과한다" {
    const runtime_event_wire = @import("runtime_event_wire.zig");
    const body = try viewportResizedBody(std.testing.allocator, .{
        .runtime_id = 0xaa,
        .cols = 50,
        .rows = 24,
        .resize_generation = 3,
    });
    defer std.testing.allocator.free(body);

    // **여기가 이 판정자의 전부다.** client 는 `data` 필드가 정확히 다섯이고 `reason` 이 문자
    // 그대로 `"controller"` 여야 받는다. 사유를 `"viewport"` 로 적었더니 이 한 줄이 `.malformed`
    // 로 떨어졌다 — 알리려던 것이 스트림을 깨는 셈이었다(적대적 검증 3회차).
    const verdict = runtime_event_wire.preflightEventObserved(body, .{ .runtime_id = 0xaa }, null);
    const preflight = switch (verdict) {
        .accepted => |value| value,
        else => {
            std.debug.print("S11-6 알림 verdict={s}\n", .{@tagName(std.meta.activeTag(verdict))});
            return error.TestUnexpectedResult;
        },
    };
    switch (preflight.event) {
        .resized => |event| {
            try std.testing.expectEqual(@as(u16, 50), event.cols);
            try std.testing.expectEqual(@as(u16, 24), event.rows);
            try std.testing.expectEqual(@as(u64, 3), event.resize_generation);
        },
        else => return error.TestUnexpectedResult,
    }
}
