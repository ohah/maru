//! Allocation-free control request/response correlation policy.
//!
//! Tests are written first for the 2b2f2 contract. The product adapter will own the final-address
//! seal and payload; this leaf owns only pointer-free transition truth.

const std = @import("std");
const client_pump = @import("client_pump.zig");
const control_response_wire = @import("control_response_wire.zig");

pub const timeout_ns: i128 = 5 * std.time.ns_per_s;
pub const ControlKind = client_pump.ControlKind;
pub const ControlExpectation = control_response_wire.ControlExpectation;

pub const Target = struct {
    stream_id: u64,
    controller_generation: u64,

    pub fn isCanonical(self: Target) bool {
        return self.stream_id != 0 and self.controller_generation != 0;
    }

    /// **controller generation 을 요구하는 것은 controller 자격이 필요한 control 뿐이다.**
    /// 예전에는 `.detach` 만 예외였는데, observer 가 보낼 수 있는 control 이 둘로 늘었다(S11-6).
    /// controller 가 없는 세션(headless keep-alive)에 붙은 observer 는 이 값이 **0** 이라, 예외에
    /// 안 들면 요청이 `.invalid` 로 떨어지고 그 결과가 `admitControl` 의 **기본값**인
    /// `invariant_failure` 로 나온다 — 「선언이 그냥 안 먹는다」로만 보이는 조용한 실패다.
    pub fn isCanonicalFor(self: Target, kind: ControlKind) bool {
        return self.stream_id != 0 and
            (self.controller_generation != 0 or !kind.requiresController());
    }
};

pub const Progress = enum {
    queued,
    partial,
    response_wait,
};

pub const InFlight = struct {
    kind: ControlKind,
    expectation: ControlExpectation,
    target: Target,
    request_id: u64,
    wire_len: usize,
    deadline_ns: i128,
    progress: Progress = .queued,
};

pub const Completed = struct {
    kind: ControlKind,
    expectation: ControlExpectation,
    target: Target,
    request_id: u64,
    wire_len: usize,
};

pub const State = union(enum) {
    idle,
    in_flight: InFlight,
    completed: Completed,
    terminal,
};

pub const AdmissionResult = union(enum) {
    admitted: InFlight,
    backpressure,
    invalid,
    deadline_overflow,
};

/// Computes the semantic half of control admission before the owning adapter allocates or queues
/// wire bytes. The caller publishes this value only in the no-fail suffix of the f1 transaction.
pub fn prepareAdmission(
    state: State,
    kind: ControlKind,
    expectation: ControlExpectation,
    target: Target,
    request_id: u64,
    wire_len: usize,
    now_ns: i128,
) AdmissionResult {
    switch (state) {
        .idle => {},
        .in_flight, .completed => return .backpressure,
        .terminal => return .invalid,
    }
    if (!target.isCanonicalFor(kind) or request_id == 0 or wire_len == 0 or
        !expectation.isCanonical() or !expectationMatchesKind(expectation, kind))
        return .invalid;
    const deadline_ns = std.math.add(i128, now_ns, timeout_ns) catch
        return .deadline_overflow;
    return .{ .admitted = .{
        .kind = kind,
        .expectation = expectation,
        .target = target,
        .request_id = request_id,
        .wire_len = wire_len,
        .deadline_ns = deadline_ns,
    } };
}

/// 기대와 종류가 같은 control 을 가리키는가. **한 자리에 둔다** — admission 과 TX 자격 판정이
/// 각자 이 대조를 적으면 새 control 이 생길 때 한쪽만 고쳐진다(S11-6 이 실제로 그렇게 났다).
pub fn expectationMatchesKind(expectation: ControlExpectation, kind: ControlKind) bool {
    return switch (expectation) {
        .resize => kind == .resize,
        .resync => kind == .resync,
        .detach => kind == .detach,
        .declare_viewport => kind == .declare_viewport,
    };
}

pub const ProgressResult = union(enum) {
    updated: InFlight,
    stale,
    invalid_transition,
};

/// Applies only sealed TX evidence. A response-wait completion is monotonic; duplicate or stale
/// evidence never rewinds correlation state.
pub fn observeProgress(
    in_flight: InFlight,
    next: Progress,
    request_id: u64,
    target: Target,
) ProgressResult {
    if (request_id != in_flight.request_id or
        !std.meta.eql(target, in_flight.target))
        return .stale;
    const allowed = switch (in_flight.progress) {
        .queued => next == .partial or next == .response_wait,
        .partial => next == .partial or next == .response_wait,
        .response_wait => false,
    };
    if (!allowed) return .invalid_transition;
    var updated = in_flight;
    updated.progress = next;
    return .{ .updated = updated };
}

pub const ResponseDisposition = enum {
    accept,
    early,
    wrong_request,
    deadline_exceeded,
    unsolicited,
};

/// Deadline-first means a matching response at the exact boundary cannot win by ordering its ID
/// comparison or payload work ahead of the clock.
pub fn classifyResponse(
    in_flight: InFlight,
    request_id: u64,
    now_ns: i128,
) ResponseDisposition {
    if (now_ns >= in_flight.deadline_ns) return .deadline_exceeded;
    if (request_id != in_flight.request_id) return .wrong_request;
    if (in_flight.progress != .response_wait) return .early;
    return .accept;
}

pub fn deadlineExpired(in_flight: InFlight, now_ns: i128) bool {
    return now_ns >= in_flight.deadline_ns;
}

pub fn classifyStateResponse(
    state: State,
    request_id: u64,
    now_ns: i128,
) ResponseDisposition {
    return switch (state) {
        .in_flight => |in_flight| classifyResponse(
            in_flight,
            request_id,
            now_ns,
        ),
        .idle, .completed, .terminal => .unsolicited,
    };
}

pub fn completeResponse(
    in_flight: InFlight,
    request_id: u64,
    now_ns: i128,
) State {
    if (classifyResponse(in_flight, request_id, now_ns) != .accept)
        return .terminal;
    return .{ .completed = .{
        .kind = in_flight.kind,
        .expectation = in_flight.expectation,
        .target = in_flight.target,
        .request_id = in_flight.request_id,
        .wire_len = in_flight.wire_len,
    } };
}

const test_resize_expectation: ControlExpectation = .{
    .resize = .{ .client_sequence = 1 },
};
const test_resync_expectation: ControlExpectation = .{ .resync = .{
    .owner_incarnation = 1,
    .origin = .client,
    .recovery_epoch = 1,
} };

test "control correlation admits only one outstanding request without wrapping deadline" {
    const target = Target{
        .stream_id = 7,
        .controller_generation = 11,
    };
    const admitted = prepareAdmission(
        .idle,
        .resize,
        test_resize_expectation,
        target,
        41,
        80,
        100,
    );
    try std.testing.expect(admitted == .admitted);
    try std.testing.expectEqual(@as(i128, 100 + timeout_ns), admitted.admitted.deadline_ns);
    try std.testing.expectEqual(@as(u64, 41), admitted.admitted.request_id);
    try std.testing.expect(
        prepareAdmission(
            .{ .in_flight = admitted.admitted },
            .resync,
            test_resync_expectation,
            target,
            42,
            80,
            101,
        ) == .backpressure,
    );
    try std.testing.expect(
        prepareAdmission(.idle, .resize, test_resize_expectation, target, 1, 80, std.math.maxInt(i128)) ==
            .deadline_overflow,
    );
}

test "control correlation permits zero generation only for detach" {
    const untracked = Target{ .stream_id = 7, .controller_generation = 0 };
    try std.testing.expect(prepareAdmission(
        .idle,
        .detach,
        .detach,
        untracked,
        1,
        64,
        1,
    ) == .admitted);
    try std.testing.expect(prepareAdmission(
        .idle,
        .resize,
        test_resize_expectation,
        untracked,
        1,
        64,
        1,
    ) == .invalid);
    try std.testing.expect(prepareAdmission(
        .idle,
        .resync,
        test_resync_expectation,
        untracked,
        1,
        64,
        1,
    ) == .invalid);
}

test "control correlation accepts response only after exact completion and before deadline" {
    const target = Target{
        .stream_id = 7,
        .controller_generation = 11,
    };
    const admitted = prepareAdmission(
        .idle,
        .resize,
        test_resize_expectation,
        target,
        41,
        80,
        100,
    ).admitted;

    try std.testing.expectEqual(
        ResponseDisposition.early,
        classifyResponse(admitted, 41, 101),
    );
    const partial = observeProgress(admitted, .partial, 41, target);
    try std.testing.expect(partial == .updated);
    try std.testing.expectEqual(
        ResponseDisposition.early,
        classifyResponse(partial.updated, 41, 102),
    );
    const waiting = observeProgress(partial.updated, .response_wait, 41, target);
    try std.testing.expect(waiting == .updated);
    try std.testing.expectEqual(
        ResponseDisposition.accept,
        classifyResponse(waiting.updated, 41, waiting.updated.deadline_ns - 1),
    );
    try std.testing.expectEqual(
        ResponseDisposition.wrong_request,
        classifyResponse(waiting.updated, 42, waiting.updated.deadline_ns - 1),
    );
    try std.testing.expectEqual(
        ResponseDisposition.deadline_exceeded,
        classifyResponse(waiting.updated, 41, waiting.updated.deadline_ns),
    );
}

test "control correlation rejects stale completion and duplicate response" {
    const target = Target{
        .stream_id = 7,
        .controller_generation = 11,
    };
    const in_flight = prepareAdmission(
        .idle,
        .resync,
        test_resync_expectation,
        target,
        std.math.maxInt(u64),
        80,
        0,
    ).admitted;
    try std.testing.expect(
        observeProgress(in_flight, .response_wait, 9, target) == .stale,
    );
    const waiting = observeProgress(
        in_flight,
        .response_wait,
        std.math.maxInt(u64),
        target,
    ).updated;
    const completed = completeResponse(waiting, std.math.maxInt(u64), 1);
    try std.testing.expect(completed == .completed);
    try std.testing.expectEqual(
        ResponseDisposition.unsolicited,
        classifyStateResponse(completed, std.math.maxInt(u64), 1),
    );
}

test "control deadline is live through deadline minus one and expires exactly at boundary" {
    const target = Target{ .stream_id = 7, .controller_generation = 11 };
    const in_flight = prepareAdmission(
        .idle,
        .resize,
        test_resize_expectation,
        target,
        1,
        80,
        100,
    ).admitted;
    try std.testing.expect(!deadlineExpired(in_flight, in_flight.deadline_ns - 1));
    try std.testing.expect(deadlineExpired(in_flight, in_flight.deadline_ns));
    try std.testing.expect(deadlineExpired(in_flight, in_flight.deadline_ns + 1));
}

test "S11-6 controller 가 없어도(generation 0) observer 의 control 은 정규형이다" {
    const T = std.testing;
    // **controller 가 없는 세션에 붙은 observer 는 이 값이 0 이다** — 폰만 붙는 headless
    // keep-alive 가 정확히 그 모양이다. 예전에는 `.detach` 만 예외라, 뷰포트 선언이 여기서
    // `.invalid` 로 떨어지고 그 결과가 `admitControl` 의 **기본값**인 `invariant_failure` 로
    // 나왔다 — client 는 그것을 terminal 로 읽어 선언 채널을 영영 닫았다(실 host attach 로 확인,
    // 2026-09-02). 「선언이 그냥 안 먹는다」로만 보이는 조용한 실패다.
    const no_controller = Target{ .stream_id = 7, .controller_generation = 0 };
    try T.expect(no_controller.isCanonicalFor(.declare_viewport));
    try T.expect(no_controller.isCanonicalFor(.detach));
    // **크기를 바꾸는 것은 여전히 controller generation 을 요구한다.**
    try T.expect(!no_controller.isCanonicalFor(.resize));
    try T.expect(!no_controller.isCanonicalFor(.resync));

    // controller 가 있으면 넷 다 정규형이다.
    const with_controller = Target{ .stream_id = 7, .controller_generation = 3 };
    inline for (.{ .declare_viewport, .detach, .resize, .resync }) |kind|
        try T.expect(with_controller.isCanonicalFor(kind));

    // stream_id 0 은 어느 종류로도 아니다.
    const no_stream = Target{ .stream_id = 0, .controller_generation = 3 };
    try T.expect(!no_stream.isCanonicalFor(.declare_viewport));
}
