//! App-global Mermaid admission, fairness, capability, deadline, and failure-budget policy.
//!
//! OS process/pipe work is intentionally absent. A platform adapter may only drain `Action` values and
//! return terminal completions; it must not repeat queue limits, coalescing, or failure decisions.

const std = @import("std");
const protocol = @import("mermaid_protocol.zig");

pub const max_pending_jobs: usize = 32;
pub const max_pending_source_bytes: usize = 1024 * 1024;
pub const max_accepted_svg_bytes: usize = 2 * 1024 * 1024;
pub const max_line_bytes: usize = 512;
pub const response_deadline_ms: u64 = 2_000;
pub const failure_window_ms: u64 = 60_000;
pub const failure_limit: usize = 3;
pub const max_completion_drain_per_tick: usize = 8;

const slot_count = max_pending_jobs + 1; // pending 32개와 실행 중 1개를 동시에 보존한다.

pub const AdmissionError = error{
    Disabled,
    InvalidCapability,
    EmptySource,
    SourceTooLarge,
    LineTooLong,
    InvalidUtf8,
    QueueFull,
    PendingSourceFull,
};

pub const RendererCapability = protocol.RendererCapability;
pub const JobCapability = protocol.JobCapability;

pub const JobRequest = struct {
    window_id: u64,
    renderer: RendererCapability,
    fence_id: u64,
    source: []const u8,
};

pub const StartJob = struct {
    capability: JobCapability,
    /// Zig codec이 만든 opaque request frame. Platform은 이 bytes를 해석하지 않고 소유 copy를
    /// 만든 뒤 `completeActionHandoff`를 ack해야 한다. ack 전에는 storage를 재사용하지 않는다.
    request_frame: []const u8,
    deadline_ms: u64,
    hello_nonce: u64,
    spawn_helper: bool,
};

pub const Action = union(enum) {
    terminate_helper: u64,
    start_job: StartJob,
};

pub const CompletionOutcome = enum {
    accepted,
    render_error,
    stale,
    invalid_body,
    deadline_expired,
    accepted_capacity_exceeded,
};

pub const AcceptedResult = struct {
    capability: JobCapability,
    svg_len: usize,
};

pub const Snapshot = struct {
    pending_jobs: usize,
    pending_source_bytes: usize,
    accepted_results: usize,
    accepted_svg_bytes: usize,
    helper_instance: u64,
    in_flight: bool,
    disabled: bool,
    helper_starts: u64,
    deadline_expirations: u64,
    admission_copies: u64,
    action_handoff_pending: bool,
    termination_in_progress: bool,
};

const SlotState = enum { free, pending, in_flight };

const JobSlot = struct {
    state: SlotState = .free,
    window_id: u64 = 0,
    enqueue_sequence: u64 = 0,
    job_id: u64 = 0,
    renderer: RendererCapability = std.mem.zeroes(RendererCapability),
    fence_id: u64 = 0,
    source_hash: [32]u8 = [_]u8{0} ** 32,
    source_len: usize = 0,
    source: [protocol.max_source_bytes]u8 = undefined,

    fn capability(self: *const JobSlot, helper_instance: u64) JobCapability {
        return .{
            .helper_instance = helper_instance,
            .job_id = self.job_id,
            .renderer = self.renderer,
            .fence_id = self.fence_id,
            .source_hash = self.source_hash,
        };
    }

    fn clear(self: *JobSlot) void {
        self.state = .free;
        self.window_id = 0;
        self.enqueue_sequence = 0;
        self.job_id = 0;
        self.renderer = std.mem.zeroes(RendererCapability);
        self.fence_id = 0;
        self.source_hash = [_]u8{0} ** 32;
        self.source_len = 0;
    }
};

const Accepted = struct {
    window_id: u64,
    capability: JobCapability,
    offset: usize,
    len: usize,
};

/// Queue storage is fixed (pending source 1 MiB + accepted SVG 2 MiB), so cap+1 can fail before
/// allocation and repeated hostile input cannot grow the app heap. This is an app-lifetime L4-owned value.
pub const MermaidCoordinatorState = struct {
    slots: [slot_count]JobSlot = [_]JobSlot{.{}} ** slot_count,
    pending_jobs: usize = 0,
    pending_source_bytes: usize = 0,
    in_flight_index: ?usize = null,
    in_flight_deadline_ms: u64 = 0,

    next_enqueue_sequence: u64 = 1,
    next_job_id: u64 = 1,
    next_helper_instance: u64 = 1,
    next_hello_nonce: u64 = 1,
    helper_instance: u64 = 0,
    helper_nonce: u64 = 0,
    helper_starts: u64 = 0,
    deadline_expirations: u64 = 0,
    last_window_id: u64 = 0,
    terminate_pending: u64 = 0,
    termination_in_progress: u64 = 0,

    // Async platform executor가 빌린 source pointer를 보지 않게 request wire bytes를 별도 fixed
    // lease에 둔다. timeout/revoke가 slot을 회수해도 handoff ack 전까지 이 bytes는 불변이다.
    action_frame: [protocol.max_request_frame_bytes]u8 = undefined,
    action_frame_len: usize = 0,
    action_lease_helper: u64 = 0,
    action_lease_job: u64 = 0,

    failure_times: [failure_limit]u64 = [_]u64{0} ** failure_limit,
    failure_count: usize = 0,
    disabled: bool = false,

    accepted: [slot_count]Accepted = undefined,
    accepted_count: usize = 0,
    accepted_bytes: [max_accepted_svg_bytes]u8 = undefined,
    accepted_len: usize = 0,

    // 테스트/summary가 cap+1에서 source copy가 0임을 직접 확인하는 관측값이다.
    admission_copies: u64 = 0,

    pub fn snapshot(self: *const MermaidCoordinatorState) Snapshot {
        return .{
            .pending_jobs = self.pending_jobs,
            .pending_source_bytes = self.pending_source_bytes,
            .accepted_results = self.accepted_count,
            .accepted_svg_bytes = self.accepted_len,
            .helper_instance = self.helper_instance,
            .in_flight = self.in_flight_index != null,
            .disabled = self.disabled,
            .helper_starts = self.helper_starts,
            .deadline_expirations = self.deadline_expirations,
            .admission_copies = self.admission_copies,
            .action_handoff_pending = self.action_lease_helper != 0,
            .termination_in_progress = self.termination_in_progress != 0,
        };
    }

    /// 같은 widget의 아직 실행되지 않은 job은 제자리에서 latest로 교체한다. 모든 상한과 identity를
    /// 먼저 검사하므로 거부 경로는 기존 queue와 source bytes를 바꾸지 않는다.
    pub fn admit(self: *MermaidCoordinatorState, request: JobRequest) AdmissionError!u64 {
        if (self.disabled) return error.Disabled;
        if (!validRenderer(request.window_id, request.renderer, request.fence_id)) return error.InvalidCapability;
        if (request.source.len == 0) return error.EmptySource;
        if (request.source.len > protocol.max_source_bytes) return error.SourceTooLarge;
        if (!std.unicode.utf8ValidateSlice(request.source)) return error.InvalidUtf8;
        if (hasLongLine(request.source)) return error.LineTooLong;

        const replacement = self.findPendingWidget(request.window_id, request.renderer.widget_id);
        const old_len = if (replacement) |index| self.slots[index].source_len else 0;
        const projected_bytes = self.pending_source_bytes - old_len + request.source.len;
        if (projected_bytes > max_pending_source_bytes) return error.PendingSourceFull;
        if (replacement == null and self.pending_jobs >= max_pending_jobs) return error.QueueFull;

        const index = replacement orelse self.findFreeSlot() orelse return error.QueueFull;
        const job_id = self.takeJobId();
        const sequence = self.takeSequence();
        const slot = &self.slots[index];
        slot.state = .pending;
        slot.window_id = request.window_id;
        slot.enqueue_sequence = sequence;
        slot.job_id = job_id;
        slot.renderer = request.renderer;
        slot.fence_id = request.fence_id;
        slot.source_hash = protocol.sourceHash(request.source);
        slot.source_len = request.source.len;
        @memcpy(slot.source[0..request.source.len], request.source);
        self.admission_copies +%= 1;
        self.pending_source_bytes = projected_bytes;
        if (replacement == null) self.pending_jobs += 1;
        return job_id;
    }

    /// terminate는 항상 start보다 먼저 drain된다. start commit 시점의 `now_ms`가 2초 end-to-end
    /// deadline의 유일한 시작점이며 platform 대기/spawn/handshake를 모두 포함한다.
    pub fn drainAction(self: *MermaidCoordinatorState, now_ms: u64) ?Action {
        if (self.terminate_pending != 0) {
            const helper = self.terminate_pending;
            self.terminate_pending = 0;
            self.termination_in_progress = helper;
            return .{ .terminate_helper = helper };
        }
        if (self.disabled or self.in_flight_index != null or self.termination_in_progress != 0 or self.action_lease_helper != 0) return null;
        const index = self.choosePending() orelse return null;
        const slot = &self.slots[index];
        self.pending_jobs -= 1;
        self.pending_source_bytes -= slot.source_len;
        slot.state = .in_flight;
        self.in_flight_index = index;
        self.last_window_id = slot.window_id;
        self.in_flight_deadline_ms = now_ms +| response_deadline_ms;

        const spawn = self.helper_instance == 0;
        if (spawn) {
            self.helper_instance = self.takeHelperInstance();
            self.helper_nonce = self.takeHelloNonce();
            self.helper_starts +%= 1;
        }
        const capability = slot.capability(self.helper_instance);
        self.action_frame_len = protocol.encode(.{ .request = .{
            .capability = capability,
            .source = slot.source[0..slot.source_len],
        } }, &self.action_frame) catch unreachable;
        self.action_lease_helper = capability.helper_instance;
        self.action_lease_job = capability.job_id;
        return .{ .start_job = .{
            .capability = capability,
            .request_frame = self.action_frame[0..self.action_frame_len],
            .deadline_ms = self.in_flight_deadline_ms,
            .hello_nonce = self.helper_nonce,
            .spawn_helper = spawn,
        } };
    }

    pub fn expireDeadline(self: *MermaidCoordinatorState, now_ms: u64) bool {
        if (self.in_flight_index == null or now_ms <= self.in_flight_deadline_ms) return false;
        self.deadline_expirations +%= 1;
        self.failRunning(now_ms, false);
        return true;
    }

    pub fn completeResult(
        self: *MermaidCoordinatorState,
        capability: JobCapability,
        status: protocol.ResultStatus,
        body: []const u8,
        arrival_ms: u64,
    ) CompletionOutcome {
        const index = self.in_flight_index orelse return .stale;
        const slot = &self.slots[index];
        if (!std.meta.eql(slot.capability(self.helper_instance), capability)) return .stale;
        if (arrival_ms > self.in_flight_deadline_ms) {
            self.deadline_expirations +%= 1;
            self.failRunning(arrival_ms, false);
            return .deadline_expired;
        }

        if (status == .render_error) {
            if (body.len != 0) {
                self.failRunning(arrival_ms, false);
                return .invalid_body;
            }
            self.releaseRunning();
            return .render_error;
        }
        if (body.len > protocol.max_svg_bytes or !std.unicode.utf8ValidateSlice(body)) {
            self.failRunning(arrival_ms, false);
            return .invalid_body;
        }
        if (self.accepted_count >= self.accepted.len or body.len > self.accepted_bytes.len - self.accepted_len) {
            self.releaseRunning();
            return .accepted_capacity_exceeded;
        }

        const offset = self.accepted_len;
        @memcpy(self.accepted_bytes[offset..][0..body.len], body);
        self.accepted[self.accepted_count] = .{
            .window_id = slot.window_id,
            .capability = capability,
            .offset = offset,
            .len = body.len,
        };
        self.accepted_count += 1;
        self.accepted_len += body.len;
        self.releaseRunning();
        return .accepted;
    }

    /// caller buffer로 한 결과를 넘긴 뒤 arena를 압축한다. 반환 capability와 SVG는 한 번만 소비된다.
    pub fn takeAccepted(self: *MermaidCoordinatorState, out: []u8) error{OutputTooSmall}!?AcceptedResult {
        if (self.accepted_count == 0) return null;
        const first = self.accepted[0];
        if (out.len < first.len) return error.OutputTooSmall;
        @memcpy(out[0..first.len], self.accepted_bytes[first.offset..][0..first.len]);

        const removed_end = first.offset + first.len;
        std.mem.copyForwards(u8, self.accepted_bytes[0 .. self.accepted_len - removed_end], self.accepted_bytes[removed_end..self.accepted_len]);
        var i: usize = 1;
        while (i < self.accepted_count) : (i += 1) {
            self.accepted[i - 1] = self.accepted[i];
            self.accepted[i - 1].offset -= removed_end;
        }
        self.accepted_count -= 1;
        self.accepted_len -= removed_end;
        return .{ .capability = first.capability, .svg_len = first.len };
    }

    /// I/O/crash/malformed 같은 재시도 가능한 실패. 60초 rolling window의 세 번째 실패가 모든
    /// queue/result/helper를 회수하고 app-lifetime disabled latch를 건다.
    pub fn transientFailure(self: *MermaidCoordinatorState, helper_instance: u64, now_ms: u64) bool {
        if (self.disabled or helper_instance == 0 or helper_instance != self.helper_instance) return false;
        self.failRunning(now_ms, false);
        return true;
    }

    /// bundle/path/signature/protocol/Hello mismatch는 재시도로 회복되지 않으므로 첫 회에 latch한다.
    pub fn integrityFailure(self: *MermaidCoordinatorState, helper_instance: u64) bool {
        if (self.disabled or helper_instance == 0 or helper_instance != self.helper_instance) return false;
        self.disableAndReclaim();
        return true;
    }

    /// navigation/widget revoke는 공격 실패가 아니라 capability 수명 종료다. 실행 중이면 old result를
    /// 물리적으로 막기 위해 helper만 교체하고 failure budget은 소비하지 않는다.
    pub fn revokeWidget(self: *MermaidCoordinatorState, window_id: u64, widget_id: u64) void {
        for (&self.slots, 0..) |*slot, index| {
            if (slot.state == .pending and slot.window_id == window_id and slot.renderer.widget_id == widget_id) {
                self.pending_jobs -= 1;
                self.pending_source_bytes -= slot.source_len;
                slot.clear();
            } else if (slot.state == .in_flight and slot.window_id == window_id and slot.renderer.widget_id == widget_id) {
                std.debug.assert(self.in_flight_index == index);
                self.releaseRunning();
                self.retireHelper();
            }
        }
        self.dropAcceptedWidget(window_id, widget_id);
    }

    /// App termination의 최종 model barrier. Platform executor/process가 먼저 quiesce된 뒤 호출하므로
    /// leased frame과 retirement token까지 즉시 회수해도 빌린 pointer 사용자가 남지 않는다.
    pub fn shutdown(self: *MermaidCoordinatorState) void {
        self.disableAndReclaim();
        self.terminate_pending = 0;
        self.termination_in_progress = 0;
        self.action_lease_helper = 0;
        self.action_lease_job = 0;
        self.action_frame_len = 0;
    }

    /// Swift Process termination handler의 exact ack. 이전 helper의 늦은 handler는 새 helper start를
    /// 풀지 못한다. 이 ack 뒤에만 다음 `start_job` action이 나와 물리 helper≤1을 보장한다.
    pub fn completeTermination(self: *MermaidCoordinatorState, helper_instance: u64) bool {
        if (helper_instance == 0 or self.termination_in_progress != helper_instance) return false;
        self.termination_in_progress = 0;
        return true;
    }

    /// Platform executor가 opaque request frame을 owned bytes로 복사했다는 exact ack다. deadline이나
    /// revoke 뒤에도 stale ack가 다른 lease를 풀 수 없으며, 이 ack 전에는 다음 start를 내보내지 않는다.
    pub fn completeActionHandoff(self: *MermaidCoordinatorState, helper_instance: u64, job_id: u64) bool {
        if (helper_instance == 0 or job_id == 0 or self.action_lease_helper != helper_instance or self.action_lease_job != job_id) return false;
        self.action_lease_helper = 0;
        self.action_lease_job = 0;
        self.action_frame_len = 0;
        return true;
    }

    fn failRunning(self: *MermaidCoordinatorState, now_ms: u64, permanent: bool) void {
        if (self.in_flight_index != null) self.releaseRunning();
        self.retireHelper();
        if (permanent or self.recordFailure(now_ms)) self.disableAndReclaim();
    }

    fn recordFailure(self: *MermaidCoordinatorState, now_ms: u64) bool {
        var kept: [failure_limit]u64 = [_]u64{0} ** failure_limit;
        var kept_len: usize = 0;
        for (self.failure_times[0..self.failure_count]) |timestamp| {
            if (now_ms >= timestamp and now_ms - timestamp <= failure_window_ms) {
                kept[kept_len] = timestamp;
                kept_len += 1;
            }
        }
        if (kept_len < kept.len) {
            kept[kept_len] = now_ms;
            kept_len += 1;
        }
        self.failure_times = kept;
        self.failure_count = kept_len;
        return kept_len >= failure_limit;
    }

    fn disableAndReclaim(self: *MermaidCoordinatorState) void {
        self.disabled = true;
        if (self.in_flight_index != null) self.releaseRunning();
        self.retireHelper();
        for (&self.slots) |*slot| slot.clear();
        self.pending_jobs = 0;
        self.pending_source_bytes = 0;
        self.accepted_count = 0;
        self.accepted_len = 0;
    }

    fn retireHelper(self: *MermaidCoordinatorState) void {
        if (self.helper_instance == 0) return;
        std.debug.assert(self.termination_in_progress == 0);
        self.terminate_pending = self.helper_instance;
        self.helper_instance = 0;
        self.helper_nonce = 0;
    }

    fn releaseRunning(self: *MermaidCoordinatorState) void {
        const index = self.in_flight_index orelse return;
        self.slots[index].clear();
        self.in_flight_index = null;
        self.in_flight_deadline_ms = 0;
    }

    fn dropAcceptedWidget(self: *MermaidCoordinatorState, window_id: u64, widget_id: u64) void {
        var write_index: usize = 0;
        var write_offset: usize = 0;
        var read_index: usize = 0;
        while (read_index < self.accepted_count) : (read_index += 1) {
            const item = self.accepted[read_index];
            if (item.window_id == window_id and item.capability.renderer.widget_id == widget_id) continue;
            if (item.offset != write_offset) {
                std.mem.copyForwards(u8, self.accepted_bytes[write_offset..][0..item.len], self.accepted_bytes[item.offset..][0..item.len]);
            }
            self.accepted[write_index] = item;
            self.accepted[write_index].offset = write_offset;
            write_index += 1;
            write_offset += item.len;
        }
        self.accepted_count = write_index;
        self.accepted_len = write_offset;
    }

    fn findPendingWidget(self: *const MermaidCoordinatorState, window_id: u64, widget_id: u64) ?usize {
        for (&self.slots, 0..) |*slot, index| {
            if (slot.state == .pending and slot.window_id == window_id and slot.renderer.widget_id == widget_id) return index;
        }
        return null;
    }

    fn findFreeSlot(self: *const MermaidCoordinatorState) ?usize {
        for (&self.slots, 0..) |*slot, index| if (slot.state == .free) return index;
        return null;
    }

    fn choosePending(self: *const MermaidCoordinatorState) ?usize {
        var next_window: ?u64 = null;
        var wrapped_window: ?u64 = null;
        for (&self.slots) |*slot| {
            if (slot.state != .pending) continue;
            if (slot.window_id > self.last_window_id and (next_window == null or slot.window_id < next_window.?)) next_window = slot.window_id;
            if (wrapped_window == null or slot.window_id < wrapped_window.?) wrapped_window = slot.window_id;
        }
        const chosen_window = next_window orelse wrapped_window orelse return null;
        var chosen: ?usize = null;
        for (&self.slots, 0..) |*slot, index| {
            if (slot.state != .pending or slot.window_id != chosen_window) continue;
            if (chosen == null or slot.enqueue_sequence < self.slots[chosen.?].enqueue_sequence) chosen = index;
        }
        return chosen;
    }

    fn takeJobId(self: *MermaidCoordinatorState) u64 {
        const value = self.next_job_id;
        self.next_job_id +%= 1;
        if (self.next_job_id == 0) self.next_job_id = 1;
        return value;
    }

    fn takeSequence(self: *MermaidCoordinatorState) u64 {
        const value = self.next_enqueue_sequence;
        self.next_enqueue_sequence +%= 1;
        if (self.next_enqueue_sequence == 0) self.next_enqueue_sequence = 1;
        return value;
    }

    fn takeHelperInstance(self: *MermaidCoordinatorState) u64 {
        const value = self.next_helper_instance;
        self.next_helper_instance +%= 1;
        if (self.next_helper_instance == 0) self.next_helper_instance = 1;
        return value;
    }

    fn takeHelloNonce(self: *MermaidCoordinatorState) u64 {
        const value = self.next_hello_nonce;
        self.next_hello_nonce +%= 1;
        if (self.next_hello_nonce == 0) self.next_hello_nonce = 1;
        return value;
    }
};

fn validRenderer(window_id: u64, renderer: RendererCapability, fence_id: u64) bool {
    return window_id != 0 and fence_id != 0 and renderer.document_revision != 0 and renderer.projection_generation != 0 and
        renderer.widget_id != 0 and renderer.widget_generation != 0 and renderer.renderer_instance != 0;
}

fn hasLongLine(source: []const u8) bool {
    var line_len: usize = 0;
    for (source) |byte| {
        if (byte == '\n') {
            line_len = 0;
        } else {
            line_len += 1;
            if (line_len > max_line_bytes) return true;
        }
    }
    return false;
}

fn testRequest(window_id: u64, widget_id: u64, source: []const u8) JobRequest {
    return .{
        .window_id = window_id,
        .renderer = .{
            .document_revision = 1,
            .projection_generation = 1,
            .widget_id = widget_id,
            .widget_generation = 1,
            .renderer_instance = widget_id + 100,
        },
        .fence_id = widget_id + 200,
        .source = source,
    };
}

test "admission coalesces latest per widget and schedules windows round robin" {
    var state: MermaidCoordinatorState = .{};
    _ = try state.admit(testRequest(1, 1, "old"));
    const replacement_id = try state.admit(testRequest(1, 1, "latest"));
    _ = try state.admit(testRequest(1, 2, "same-window"));
    _ = try state.admit(testRequest(2, 3, "other-window"));
    try std.testing.expectEqual(@as(usize, 3), state.snapshot().pending_jobs);
    try std.testing.expectEqual(@as(usize, 29), state.snapshot().pending_source_bytes);

    const first = state.drainAction(100).?.start_job;
    try std.testing.expectEqual(replacement_id, first.capability.job_id);
    const first_message = try protocol.decodeExact(first.request_frame);
    try std.testing.expectEqualStrings("latest", first_message.request.source);
    try std.testing.expect(state.completeActionHandoff(first.capability.helper_instance, first.capability.job_id));
    try std.testing.expect(first.spawn_helper);
    try std.testing.expectEqual(.render_error, state.completeResult(first.capability, .render_error, "", 101));

    const second = state.drainAction(200).?.start_job;
    try std.testing.expectEqual(@as(u64, 3), second.capability.renderer.widget_id);
    try std.testing.expect(!second.spawn_helper);
    try std.testing.expect(state.completeActionHandoff(second.capability.helper_instance, second.capability.job_id));
    try std.testing.expectEqual(.render_error, state.completeResult(second.capability, .render_error, "", 201));

    const third = state.drainAction(300).?.start_job;
    try std.testing.expectEqual(@as(u64, 2), third.capability.renderer.widget_id);
}

test "queue and source cap plus one do not copy or mutate admission" {
    var state: MermaidCoordinatorState = .{};
    const long_source = [_]u8{'a'} ** (protocol.max_source_bytes + 1);
    try std.testing.expectError(error.SourceTooLarge, state.admit(testRequest(1, 1, &long_source)));
    try std.testing.expectEqual(@as(u64, 0), state.snapshot().admission_copies);
    try std.testing.expectEqual(@as(usize, 0), state.snapshot().pending_jobs);

    const source = "x";
    var i: u64 = 0;
    while (i < max_pending_jobs) : (i += 1) _ = try state.admit(testRequest(1, i + 1, source));
    const before = state.snapshot();
    try std.testing.expectError(error.QueueFull, state.admit(testRequest(1, 1000, source)));
    try std.testing.expectEqualDeep(before, state.snapshot());
}

test "admission rejects overlong lines and invalid UTF-8 before copying" {
    var state: MermaidCoordinatorState = .{};
    const long_line = [_]u8{'a'} ** (max_line_bytes + 1);
    try std.testing.expectError(error.LineTooLong, state.admit(testRequest(1, 1, &long_line)));
    try std.testing.expectError(error.InvalidUtf8, state.admit(testRequest(1, 2, &.{ 0xc3, 0x28 })));
    try std.testing.expectEqual(@as(u64, 0), state.snapshot().admission_copies);
}

test "deadline failures restart at most three helpers then latch" {
    var state: MermaidCoordinatorState = .{};
    var iteration: u64 = 0;
    while (iteration < 100) : (iteration += 1) {
        _ = state.admit(testRequest(1, iteration + 1, "hang")) catch |err| {
            try std.testing.expectEqual(error.Disabled, err);
            continue;
        };
        const action = state.drainAction(iteration * 10_000);
        if (action) |value| switch (value) {
            .terminate_helper => |helper_instance| {
                try std.testing.expect(state.completeTermination(helper_instance));
                const start = state.drainAction(iteration * 10_000).?.start_job;
                try std.testing.expect(state.completeActionHandoff(start.capability.helper_instance, start.capability.job_id));
                try std.testing.expect(state.expireDeadline(start.deadline_ms + 1));
            },
            .start_job => |start| {
                try std.testing.expect(state.completeActionHandoff(start.capability.helper_instance, start.capability.job_id));
                try std.testing.expect(state.expireDeadline(start.deadline_ms + 1));
            },
        };
    }
    const snap = state.snapshot();
    try std.testing.expect(snap.disabled);
    try std.testing.expectEqual(@as(u64, 3), snap.helper_starts);
    try std.testing.expectEqual(@as(usize, 0), snap.pending_jobs);
}

test "integrity failure latches once and stale result cannot mutate accepted bytes" {
    var state: MermaidCoordinatorState = .{};
    _ = try state.admit(testRequest(1, 1, "graph TD"));
    const start = state.drainAction(10).?.start_job;
    try std.testing.expect(state.completeActionHandoff(start.capability.helper_instance, start.capability.job_id));
    var stale = start.capability;
    stale.helper_instance += 1;
    try std.testing.expectEqual(.stale, state.completeResult(stale, .ok, "<svg/>", 11));
    try std.testing.expect(state.snapshot().in_flight);

    try std.testing.expect(!state.integrityFailure(stale.helper_instance));
    try std.testing.expect(state.integrityFailure(start.capability.helper_instance));
    const snap = state.snapshot();
    try std.testing.expect(snap.disabled);
    try std.testing.expectEqual(@as(usize, 0), snap.accepted_svg_bytes);
    try std.testing.expectError(error.Disabled, state.admit(testRequest(1, 2, "later")));
    try std.testing.expect(state.drainAction(11).? == .terminate_helper);
    try std.testing.expect(state.drainAction(12) == null);
}

test "accepted SVG quota is one-shot and widget revoke removes matching result" {
    var state: MermaidCoordinatorState = .{};
    _ = try state.admit(testRequest(1, 1, "one"));
    const first = state.drainAction(0).?.start_job;
    try std.testing.expect(state.completeActionHandoff(first.capability.helper_instance, first.capability.job_id));
    try std.testing.expectEqual(.accepted, state.completeResult(first.capability, .ok, "<svg id='one'/>", 1));
    _ = try state.admit(testRequest(1, 2, "two"));
    const second = state.drainAction(1).?.start_job;
    try std.testing.expect(state.completeActionHandoff(second.capability.helper_instance, second.capability.job_id));
    try std.testing.expectEqual(.accepted, state.completeResult(second.capability, .ok, "<svg id='two'/>", 2));
    state.revokeWidget(1, 1);
    try std.testing.expectEqual(@as(usize, 1), state.snapshot().accepted_results);

    var out: [64]u8 = undefined;
    const accepted = (try state.takeAccepted(&out)).?;
    try std.testing.expectEqual(second.capability.job_id, accepted.capability.job_id);
    try std.testing.expectEqualStrings("<svg id='two'/>", out[0..accepted.svg_len]);
    try std.testing.expect((try state.takeAccepted(&out)) == null);
}

test "widget revoke retires running helper without charging failure budget" {
    var state: MermaidCoordinatorState = .{};
    _ = try state.admit(testRequest(1, 1, "running"));
    const first = state.drainAction(0).?.start_job;
    try std.testing.expect(state.completeActionHandoff(first.capability.helper_instance, first.capability.job_id));
    state.revokeWidget(1, 1);
    try std.testing.expectEqual(first.capability.helper_instance, state.drainAction(1).?.terminate_helper);
    try std.testing.expect(state.completeTermination(first.capability.helper_instance));
    _ = try state.admit(testRequest(1, 2, "next"));
    const next = state.drainAction(2).?.start_job;
    try std.testing.expect(next.spawn_helper);
    try std.testing.expect(next.capability.helper_instance != first.capability.helper_instance);
    try std.testing.expect(!state.snapshot().disabled);
}

test "stale termination ack cannot release a current physical retirement" {
    var state: MermaidCoordinatorState = .{};
    _ = try state.admit(testRequest(1, 1, "running"));
    const start = state.drainAction(0).?.start_job;
    try std.testing.expect(state.completeActionHandoff(start.capability.helper_instance, start.capability.job_id));
    state.revokeWidget(1, 1);
    const helper = state.drainAction(1).?.terminate_helper;
    try std.testing.expectEqual(start.capability.helper_instance, helper);
    try std.testing.expect(!state.completeTermination(helper + 1));
    _ = try state.admit(testRequest(1, 2, "waiting"));
    try std.testing.expect(state.drainAction(2) == null);
    try std.testing.expect(state.completeTermination(helper));
    try std.testing.expect(state.drainAction(3).?.start_job.spawn_helper);
}

test "request frame lease survives timeout and slot reuse until exact handoff ack" {
    var state: MermaidCoordinatorState = .{};
    _ = try state.admit(testRequest(1, 1, "old-source"));
    const old = state.drainAction(0).?.start_job;
    var old_frame: [protocol.max_request_frame_bytes]u8 = undefined;
    @memcpy(old_frame[0..old.request_frame.len], old.request_frame);
    const old_len = old.request_frame.len;

    try std.testing.expect(state.expireDeadline(old.deadline_ms + 1));
    _ = try state.admit(testRequest(1, 2, "new-source"));
    const helper = state.drainAction(old.deadline_ms + 1).?.terminate_helper;
    try std.testing.expect(state.completeTermination(helper));
    try std.testing.expect(state.drainAction(old.deadline_ms + 2) == null);
    try std.testing.expectEqualSlices(u8, old_frame[0..old_len], old.request_frame);
    try std.testing.expect(!state.completeActionHandoff(old.capability.helper_instance, old.capability.job_id + 1));
    try std.testing.expect(state.completeActionHandoff(old.capability.helper_instance, old.capability.job_id));

    const next = state.drainAction(old.deadline_ms + 3).?.start_job;
    const next_message = try protocol.decodeExact(next.request_frame);
    try std.testing.expectEqualStrings("new-source", next_message.request.source);
}

test "result arrival deadline is inclusive and late result retires helper" {
    var state: MermaidCoordinatorState = .{};
    _ = try state.admit(testRequest(1, 1, "exact"));
    const exact = state.drainAction(10).?.start_job;
    try std.testing.expect(state.completeActionHandoff(exact.capability.helper_instance, exact.capability.job_id));
    try std.testing.expectEqual(.render_error, state.completeResult(exact.capability, .render_error, "", exact.deadline_ms));

    _ = try state.admit(testRequest(1, 2, "late"));
    const late = state.drainAction(20).?.start_job;
    try std.testing.expect(state.completeActionHandoff(late.capability.helper_instance, late.capability.job_id));
    try std.testing.expectEqual(.deadline_expired, state.completeResult(late.capability, .render_error, "", late.deadline_ms + 1));
    try std.testing.expectEqual(@as(u64, 1), state.snapshot().deadline_expirations);
    try std.testing.expectEqual(late.capability.helper_instance, state.drainAction(late.deadline_ms + 1).?.terminate_helper);
}

test "app shutdown reclaims model queue result helper and action lease" {
    var state: MermaidCoordinatorState = .{};
    _ = try state.admit(testRequest(1, 1, "running"));
    _ = try state.admit(testRequest(2, 2, "pending"));
    const start = state.drainAction(0).?.start_job;
    try std.testing.expect(state.snapshot().action_handoff_pending);
    try std.testing.expectEqual(.accepted, state.completeResult(start.capability, .ok, "<svg/>", 1));

    state.shutdown();
    const snap = state.snapshot();
    try std.testing.expect(snap.disabled);
    try std.testing.expectEqual(@as(usize, 0), snap.pending_jobs);
    try std.testing.expectEqual(@as(usize, 0), snap.pending_source_bytes);
    try std.testing.expectEqual(@as(usize, 0), snap.accepted_results);
    try std.testing.expectEqual(@as(usize, 0), snap.accepted_svg_bytes);
    try std.testing.expectEqual(@as(u64, 0), snap.helper_instance);
    try std.testing.expect(!snap.in_flight);
    try std.testing.expect(!snap.action_handoff_pending);
    try std.testing.expect(!snap.termination_in_progress);
    try std.testing.expect(state.drainAction(2) == null);
}

test "failures outside the rolling window do not latch" {
    var state: MermaidCoordinatorState = .{};
    var now: u64 = 0;
    var index: u64 = 0;
    while (index < 5) : (index += 1) {
        _ = try state.admit(testRequest(1, index + 1, "hang"));
        const start = state.drainAction(now).?.start_job;
        try std.testing.expect(state.completeActionHandoff(start.capability.helper_instance, start.capability.job_id));
        try std.testing.expect(state.expireDeadline(start.deadline_ms + 1));
        const helper = state.drainAction(start.deadline_ms + 1).?.terminate_helper;
        try std.testing.expect(state.completeTermination(helper));
        try std.testing.expect(!state.snapshot().disabled);
        now += failure_window_ms + response_deadline_ms + 1;
    }
}
