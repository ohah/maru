//! Daemon-owned bounded OS notification delivery state machine (P4 N2b2).
//!
//! This leaf is OS-neutral. It receives a borrowed presentation plus a typed stable route and calls
//! one platform adapter seam. It never creates an MRSH client or imports AppSession. Only an adapter
//! `accepted` result acknowledges `.os`; terminal degraded and retry exhaustion use the journal's
//! explicit abandon path and retain `.gui` ownership.

pub const journal_api = @import("notification_journal.zig");
const journal_mod = journal_api;

pub const Route = struct {
    hid: journal_mod.HostId,
    rid: journal_mod.RuntimeId,
    eid: u64,
};

pub const Request = struct {
    route: Route,
    occurred_at_ns: u64,
    title: []const u8,
    body: []const u8,
    display_label: []const u8,
};

pub const AdapterResult = enum {
    accepted,
    denied,
    bundle_missing,
    entitlement_missing,
    transient,
    pending,
};

pub const Adapter = struct {
    context: *anyopaque,
    submitFn: *const fn (*anyopaque, Request) AdapterResult,
    expireFn: ?*const fn (*anyopaque, Route) void = null,

    fn submit(self: Adapter, request: Request) AdapterResult {
        return self.submitFn(self.context, request);
    }

    fn expire(self: Adapter, route: Route) void {
        if (self.expireFn) |expireFn| expireFn(self.context, route);
    }
};

pub const TickResult = enum {
    idle,
    waiting,
    accepted,
    degraded,
    retry_scheduled,
    retry_exhausted,
    deferred,
    stale,
    invalid_owner,
};

pub const Counters = struct {
    accepted: u64 = 0,
    denied: u64 = 0,
    bundle_missing: u64 = 0,
    entitlement_missing: u64 = 0,
    transient_failures: u64 = 0,
    retries_scheduled: u64 = 0,
    retry_exhausted: u64 = 0,

    pub fn terminalDegraded(self: Counters) u64 {
        return self.denied +| self.bundle_missing +| self.entitlement_missing;
    }
};

const Retry = struct {
    const State = enum { backoff, inflight };
    key: journal_mod.Key,
    route: Route,
    attempts: u8,
    due_ns: u64,
    state: State,
    started_ns: u64,
    sibling_attempted: bool,
};

const SiblingInflight = struct {
    key: journal_mod.Key,
    route: Route,
    due_ns: u64,
    started_ns: u64,
};

const first_backoff_ns: u64 = 250_000_000;
const max_backoff_ns: u64 = 8_000_000_000;
const max_retries: u8 = 6;
const inflight_poll_ns: u64 = 50_000_000;
const inflight_timeout_ns: u64 = 10_000_000_000;

pub const Machine = struct {
    owner_addr: usize,
    retry: ?Retry = null,
    sibling_inflight: ?SiblingInflight = null,
    fairness_cursor: u64 = 0,
    delivery_counters: Counters = .{},

    pub fn initInPlace(self: *Machine) void {
        self.* = .{ .owner_addr = @intFromPtr(self) };
    }

    pub fn counters(self: *const Machine) struct {
        accepted: u64,
        terminal_degraded: u64,
        transient_failures: u64,
        retries_scheduled: u64,
        retry_exhausted: u64,
    } {
        return .{
            .accepted = self.delivery_counters.accepted,
            .terminal_degraded = self.delivery_counters.terminalDegraded(),
            .transient_failures = self.delivery_counters.transient_failures,
            .retries_scheduled = self.delivery_counters.retries_scheduled,
            .retry_exhausted = self.delivery_counters.retry_exhausted,
        };
    }

    pub fn typedCounters(self: *const Machine) Counters {
        return self.delivery_counters;
    }

    pub fn tick(
        self: *Machine,
        now_ns: u64,
        journal: *journal_mod.Journal,
        adapter: Adapter,
    ) TickResult {
        if (self.owner_addr != @intFromPtr(self)) return .invalid_owner;

        // The platform adapter has one process-local asynchronous slot. If a sibling started an
        // async request during the primary row's backoff, that exact sibling must remain the sole
        // poll owner until settlement; otherwise the primary identifier would collide with an
        // untracked framework request.
        if (self.sibling_inflight) |inflight| {
            if (now_ns -| inflight.started_ns >= inflight_timeout_ns) {
                if (journal.peek(inflight.key) == null) {
                    adapter.expire(inflight.route);
                    self.sibling_inflight = null;
                    return .stale;
                }
                adapter.expire(inflight.route);
                self.sibling_inflight = null;
                self.delivery_counters.transient_failures +|= 1;
                return .deferred;
            }
            if (now_ns >= inflight.due_ns) return self.submitSiblingInflight(now_ns, journal, adapter, inflight);
            return .waiting;
        }

        if (self.retry) |retry| {
            // The absolute callback limit outranks the 50 ms poll cadence. Otherwise a poll just
            // before the limit could push observation beyond the documented 10-second bound.
            if (retry.state == .inflight and now_ns -| retry.started_ns >= inflight_timeout_ns) {
                const row = journal.peek(retry.key) orelse {
                    adapter.expire(retry.route);
                    self.retry = null;
                    return .stale;
                };
                adapter.expire(retry.route);
                return self.scheduleTransient(now_ns, journal, row, true, retry.attempts);
            }
            if (now_ns >= retry.due_ns) return self.submitPinned(now_ns, journal, adapter, retry);
            if (retry.state == .inflight) return .waiting;
            // There is only one final-address retry owner. Give one sibling a chance during this
            // backoff window, but do not hot-loop a transient sibling without its own retry state.
            if (retry.sibling_attempted) return .waiting;
        }

        const excluded: ?journal_mod.Key = if (self.retry) |retry| retry.key else null;
        const row = journal.nextPendingExcluding(.os, self.fairness_cursor, excluded) orelse
            return if (self.retry == null) .idle else .waiting;
        self.fairness_cursor = row.key.event_id;
        if (self.retry) |*retry| retry.sibling_attempted = true;
        return self.submitFresh(now_ns, journal, adapter, row);
    }

    fn submitFresh(
        self: *Machine,
        now_ns: u64,
        journal: *journal_mod.Journal,
        adapter: Adapter,
        row: journal_mod.View,
    ) TickResult {
        const result = adapter.submit(requestOf(row));
        if (result == .pending and self.retry != null) {
            self.sibling_inflight = .{
                .key = row.key,
                .route = requestOf(row).route,
                .due_ns = now_ns +| inflight_poll_ns,
                .started_ns = now_ns,
            };
            return .waiting;
        }
        return self.applyResult(now_ns, journal, row, result, false, 1);
    }

    fn submitSiblingInflight(
        self: *Machine,
        now_ns: u64,
        journal: *journal_mod.Journal,
        adapter: Adapter,
        inflight: SiblingInflight,
    ) TickResult {
        const row = journal.peek(inflight.key) orelse {
            adapter.expire(inflight.route);
            self.sibling_inflight = null;
            return .stale;
        };
        if (!row.pending_os) {
            adapter.expire(inflight.route);
            self.sibling_inflight = null;
            return .stale;
        }
        const result = adapter.submit(requestOf(row));
        if (result == .pending) {
            self.sibling_inflight.?.due_ns = now_ns +| inflight_poll_ns;
            return .waiting;
        }
        self.sibling_inflight = null;
        return self.applyResult(now_ns, journal, row, result, false, 1);
    }

    fn submitPinned(
        self: *Machine,
        now_ns: u64,
        journal: *journal_mod.Journal,
        adapter: Adapter,
        retry: Retry,
    ) TickResult {
        const row = journal.peek(retry.key) orelse {
            if (retry.state == .inflight) adapter.expire(retry.route);
            self.retry = null;
            return .stale;
        };
        if (!row.pending_os) {
            if (retry.state == .inflight) adapter.expire(retry.route);
            self.retry = null;
            return .stale;
        }
        // Polling an already submitted asynchronous request is not another retry attempt. Only a
        // backoff expiry creates a fresh submission and advances the bounded retry budget.
        const attempts = if (retry.state == .backoff) retry.attempts + 1 else retry.attempts;
        return self.applyResult(now_ns, journal, row, adapter.submit(requestOf(row)), true, attempts);
    }

    fn applyResult(
        self: *Machine,
        now_ns: u64,
        journal: *journal_mod.Journal,
        row: journal_mod.View,
        result: AdapterResult,
        was_pinned: bool,
        attempts: u8,
    ) TickResult {
        switch (result) {
            .accepted => {
                if (journal.ack(row.key, .os) != .acknowledged) {
                    if (was_pinned) self.retry = null;
                    return .stale;
                }
                if (was_pinned) self.retry = null;
                self.delivery_counters.accepted +|= 1;
                return .accepted;
            },
            .denied, .bundle_missing, .entitlement_missing => {
                if (journal.abandonOs(row.key) != .acknowledged) {
                    if (was_pinned) self.retry = null;
                    return .stale;
                }
                if (was_pinned) self.retry = null;
                switch (result) {
                    .denied => self.delivery_counters.denied +|= 1,
                    .bundle_missing => self.delivery_counters.bundle_missing +|= 1,
                    .entitlement_missing => self.delivery_counters.entitlement_missing +|= 1,
                    else => unreachable,
                }
                return .degraded;
            },
            .transient => {
                return self.scheduleTransient(now_ns, journal, row, was_pinned, attempts);
            },
            .pending => {
                if (!was_pinned and self.retry != null) return .deferred;
                const started_ns = if (was_pinned and self.retry.?.state == .inflight)
                    self.retry.?.started_ns
                else
                    now_ns;
                if (was_pinned) {
                    const current = self.retry orelse return .stale;
                    if (current.state == .inflight and now_ns -| current.started_ns >= inflight_timeout_ns)
                        return self.scheduleTransient(now_ns, journal, row, true, attempts);
                }
                self.retry = .{
                    .key = row.key,
                    .route = requestOf(row).route,
                    .attempts = attempts,
                    .due_ns = now_ns +| inflight_poll_ns,
                    .state = .inflight,
                    .started_ns = started_ns,
                    .sibling_attempted = false,
                };
                return .waiting;
            },
        }
    }

    fn scheduleTransient(
        self: *Machine,
        now_ns: u64,
        journal: *journal_mod.Journal,
        row: journal_mod.View,
        was_pinned: bool,
        attempts: u8,
    ) TickResult {
        self.delivery_counters.transient_failures +|= 1;
        if (!was_pinned and self.retry != null) return .deferred;
        const retries_already_scheduled: u8 = attempts - 1;
        if (retries_already_scheduled >= max_retries) {
            _ = journal.abandonOs(row.key);
            self.retry = null;
            self.delivery_counters.retry_exhausted +|= 1;
            return .retry_exhausted;
        }
        const delay = retryDelay(retries_already_scheduled);
        self.retry = .{
            .key = row.key,
            .route = requestOf(row).route,
            .attempts = attempts,
            .due_ns = now_ns +| delay,
            .state = .backoff,
            .started_ns = now_ns,
            .sibling_attempted = false,
        };
        self.delivery_counters.retries_scheduled +|= 1;
        return .retry_scheduled;
    }
};

fn requestOf(row: journal_mod.View) Request {
    return .{
        .route = .{ .hid = row.key.host_id, .rid = row.runtime_id, .eid = row.key.event_id },
        .occurred_at_ns = row.occurred_at_ns,
        .title = row.title,
        .body = row.body,
        .display_label = row.display_label,
    };
}

fn retryDelay(retries_already_scheduled: u8) u64 {
    const shift: u6 = @intCast(@min(retries_already_scheduled, 63));
    return @min(first_backoff_ns << shift, max_backoff_ns);
}
