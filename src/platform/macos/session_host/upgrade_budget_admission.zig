//! U5 pre-quiesce handoff-size, disk, and I/O budget admission.

const std = @import("std");
const handoff_store = @import("handoff_store.zig");
const upgrade_deadline = @import("upgrade_deadline.zig");
const upgrade_limits = @import("upgrade_limits.zig");
const test_scratch = @import("test_scratch.zig");

pub const safety_factor: u128 = 4;
const max_probe_bytes: usize = 1024 * 1024;

/// 예약에 두는 **최소** 여유. 미리보기와 freeze 사이가 아무리 짧아도 0 은 아니다.
pub const min_headroom_bytes: usize = 64 * 1024;
/// 큰 handoff 일수록 그 구간에 더 많이 쓰이므로 여유도 크기에 비례해 둔다.
pub const headroom_divisor: usize = 16;

/// 미리보기 `preview_bytes` 에 대해 **실제로 예약할** 바이트 수.
///
/// 미리보기는 `freeze` **전**에 잡힌다(`upgrade_product_coordinator` 가 그 순서를 강제하고
/// 경계 판정자가 못 박는다 — 그래야 디스크·I/O 부족을 세션을 멈추기 전에 거절한다). 그 대가로
/// 미리보기와 freeze 사이에 세션이 계속 쓰므로 **실제 handoff 는 미리보기보다 커질 수 있다.**
///
/// 예약을 미리보기와 똑같이 잡으면 그 증가분이 곧바로 `MismatchAxis.bytes` 가 되어 승계가
/// 통째로 취소된다. 2026-09-28 실측: 셸 17 개가 붙은 host 가
/// `axis=bytes gen=35->35 count=20->20 bytes=13103944->13103947` — 런타임 집합은 멀쩡한데
/// **3 바이트** 때문에 실패했고, 앱은 승계를 포기하고 새 host 를 띄웠다(host 누적).
///
/// 여유분은 **파일에 남지 않는다.** `handoff_store.writeReservedFile` 이 쓰기 뒤
/// `ftruncate(fd, bytes.len)` 으로 실제 길이에 맞춰 자르므로, 예약이 커도 커밋된 handoff 는
/// 정확히 실제 크기다. 늘어나는 것은 시도 중에만 잡히는 디스크뿐이다(primary·backup 두 벌).
///
/// 상한에서는 여유를 **포기한다** — `max_handoff_commit_bytes` 를 넘겨 예약하면
/// `handoff_store.validateLength` 가 거절해 승계가 아예 시작도 못 한다.
pub fn reservedBytesFor(preview_bytes: usize) usize {
    const cap = upgrade_limits.max_handoff_commit_bytes;
    if (preview_bytes >= cap) return cap;
    const slack = @max(min_headroom_bytes, preview_bytes / headroom_divisor);
    return preview_bytes + @min(slack, cap - preview_bytes);
}

pub const Error = handoff_store.Error || error{InsufficientIoBudget};

pub const Preview = struct {
    bytes: usize,
    membership_generation: u64,
    runtime_ids: []const u128,
};

pub const Reservation = struct {
    store: handoff_store.Reservation,
    reserved_bytes: usize,
    membership_generation: u64,
    runtime_ids: [upgrade_limits.max_runtime_count]u128 = undefined,
    runtime_count: usize,

    pub fn deinit(self: *Reservation) void {
        self.store.deinit();
        self.* = undefined;
    }

    pub fn cancel(self: *Reservation) handoff_store.Error!void {
        try self.store.cancel();
        self.* = undefined;
    }

    /// 예약과 실제가 **어느 축에서** 어긋났는가. `matches` 가 `false` 를 내던 이유 넷을 가른다.
    ///
    /// 2026-09-18 실측: 세션 27 개가 붙은 host 의 업그레이드가 반복 실패했는데 host 로그는
    /// `stage=budget_reservation_mismatch` 한 줄이었다. 그 이름은 네 조건 **공통**이고 wire
    /// `reason` 도 전부 `.runtime_changed` 라, 「런타임이 바뀌었다」로 읽힌다 — 그런데 그게
    /// 참인지 알 방법이 없었다. 실제로 그 한 줄을 근거로 원인을 **두 번 틀리게** 짚었다.
    ///
    /// `bytes` 축은 **예약분을 넘었다**는 뜻이지 런타임이 바뀌었다는 뜻이 아니다. 미리보기는
    /// freeze **전에** 잡히므로 그 사이 세션이 더 쓰면 실제 handoff 가 커진다 — 그래서
    /// `prepare` 는 `reservedBytesFor` 로 여유를 얹어 예약한다. 즉 「예약분 안에서 커지는 건
    /// 괜찮다」가 이제 실제 의미이고, 이 축이 뜨는 것은 **여유마저 넘겼을 때**다.
    ///
    /// 2026-09-28 이전에는 여유가 0 이라 3 바이트 증가에도 이 축이 떴다 — `reservedBytesFor`
    /// 참조. 축을 남기지 않으면 그 경우를 「런타임이 바뀌었다」와 영영 못 가른다.
    pub const MismatchAxis = enum {
        /// 어긋나지 않았다.
        none,
        /// 런타임이 등록/제거됐다(`registry.membership_generation` 이 올랐다).
        membership,
        /// 런타임 **수**가 달라졌다.
        count,
        /// handoff 가 예약분(= 미리보기 크기)을 넘었다.
        bytes,
        /// 수는 같은데 **id 집합**이 달라졌다(교체).
        ids,
    };

    /// 축을 먼저 정하고, `matches` 는 「축이 없음」으로 정의한다 — 두 판정이 갈리지 않게.
    pub fn mismatchAxis(
        self: *const Reservation,
        membership_generation: u64,
        runtime_ids: []const u128,
        authoritative_bytes: usize,
    ) MismatchAxis {
        if (membership_generation != self.membership_generation) return .membership;
        if (runtime_ids.len != self.runtime_count) return .count;
        if (authoritative_bytes > self.reserved_bytes) return .bytes;
        if (!std.mem.eql(u128, runtime_ids, self.runtime_ids[0..self.runtime_count])) return .ids;
        return .none;
    }

    pub fn matches(
        self: *const Reservation,
        membership_generation: u64,
        runtime_ids: []const u128,
        authoritative_bytes: usize,
    ) bool {
        return self.mismatchAxis(membership_generation, runtime_ids, authoritative_bytes) == .none;
    }

    pub fn commit(
        self: *Reservation,
        allocator: std.mem.Allocator,
        expected: handoff_store.ExpectedAuthority,
        bytes: []const u8,
        deadline: upgrade_deadline.Deadline,
    ) handoff_store.Error!handoff_store.Pair {
        return handoff_store.commitReserved(
            allocator,
            &self.store,
            expected,
            bytes,
            .{ .deadline = deadline, .max_bytes = self.reserved_bytes },
        );
    }
};

pub fn prepare(
    allocator: std.mem.Allocator,
    owner_dir: [:0]const u8,
    attempt_id: u128,
    preview: Preview,
    deadline: upgrade_deadline.Deadline,
) Error!Reservation {
    if (preview.bytes == 0 or preview.bytes > upgrade_limits.max_handoff_commit_bytes or
        preview.membership_generation == 0 or
        preview.runtime_ids.len > upgrade_limits.max_runtime_count)
        return error.LimitExceeded;
    // **미리보기 그대로가 아니라 여유를 얹어 잡는다.** 그 이유와 대가는 `reservedBytesFor` 에.
    const reserved_bytes = reservedBytesFor(preview.bytes);
    var reservation: Reservation = .{
        .store = try handoff_store.reserve(owner_dir, attempt_id, reserved_bytes, deadline),
        .reserved_bytes = reserved_bytes,
        .membership_generation = preview.membership_generation,
        .runtime_count = preview.runtime_ids.len,
    };
    @memcpy(reservation.runtime_ids[0..preview.runtime_ids.len], preview.runtime_ids);

    const sample_len = @min(preview.bytes, max_probe_bytes);
    const sample = allocator.alloc(u8, sample_len) catch {
        reservation.store.cancel() catch return error.CleanupFailed;
        return error.OutOfMemory;
    };
    defer allocator.free(sample);
    fillProbe(sample, attempt_id);
    const elapsed_ns = handoff_store.probeReservation(&reservation.store, sample, deadline) catch |err| {
        reservation.store.cancel() catch return error.CleanupFailed;
        return err;
    };
    if (!fitsPauseBudget(preview.bytes, sample_len, elapsed_ns, deadline.remainingNs())) {
        reservation.store.cancel() catch return error.CleanupFailed;
        return error.InsufficientIoBudget;
    }
    return reservation;
}

fn fitsPauseBudget(
    handoff_bytes: usize,
    probe_bytes: usize,
    probe_elapsed_ns: i128,
    remaining_ns: i128,
) bool {
    if (handoff_bytes == 0 or probe_bytes == 0 or probe_elapsed_ns <= 0 or remaining_ns <= 0)
        return false;
    // Product commit performs two writes and two read-backs. The probe performs one of each and
    // includes one fsync; the safety factor covers the second fsync and filesystem variance.
    const projected_work = std.math.mul(u128, @as(u128, handoff_bytes), 4) catch return false;
    const guarded_work = std.math.mul(u128, projected_work, safety_factor) catch return false;
    const lhs = std.math.mul(u128, guarded_work, @intCast(probe_elapsed_ns)) catch return false;
    const probe_work = std.math.mul(u128, @as(u128, probe_bytes), 2) catch return false;
    const rhs = std.math.mul(u128, probe_work, @intCast(remaining_ns)) catch return false;
    return lhs <= rhs;
}

fn fillProbe(bytes: []u8, attempt_id: u128) void {
    var state: u64 = @truncate(attempt_id ^ (attempt_id >> 64));
    if (state == 0) state = 0x9E3779B97F4A7C15;
    for (bytes) |*byte| {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        byte.* = @truncate(state);
    }
}

test "budget projection is fail-closed and includes two-copy I/O" {
    try std.testing.expect(fitsPauseBudget(1024, 1024, 1, 8));
    try std.testing.expect(!fitsPauseBudget(1024, 1024, 2, 7));
    try std.testing.expect(!fitsPauseBudget(0, 1024, 1, 8));
    try std.testing.expect(!fitsPauseBudget(1024, 0, 1, 8));
    try std.testing.expect(!fitsPauseBudget(1024, 1024, 0, 8));
    try std.testing.expect(!fitsPauseBudget(1024, 1024, 1, 0));
}

test "budget admission durable probe reserves and cleans before quiesce" {
    var dir_buf: [192]u8 = undefined;
    const dir = try test_scratch.open(std.testing.io, &dir_buf, "upgrade-budget-admission");
    defer test_scratch.close(std.testing.io, dir);
    const deadline = try upgrade_deadline.Deadline.after(std.testing.io, 5 * std.time.ns_per_s);
    var reservation = try prepare(
        std.testing.allocator,
        dir,
        0xB7,
        .{
            .bytes = 64 * 1024,
            .membership_generation = 4,
            .runtime_ids = &.{ 2, 9 },
        },
        deadline,
    );
    try std.testing.expect(reservation.matches(4, &.{ 2, 9 }, 64 * 1024));
    try reservation.cancel();
    var attempt_buf: [256]u8 = undefined;
    const attempt_path = try std.fmt.bufPrintZ(
        &attempt_buf,
        "{s}/attempt-{x:0>32}",
        .{ dir, @as(u128, 0xB7) },
    );
    try std.testing.expect(std.c.access(attempt_path.ptr, std.c.F_OK) != 0);
}

test "reservation membership and reserved length are exact" {
    var reservation: Reservation = undefined;
    reservation.reserved_bytes = 100;
    reservation.membership_generation = 7;
    reservation.runtime_count = 2;
    reservation.runtime_ids[0] = 3;
    reservation.runtime_ids[1] = 9;
    try std.testing.expect(reservation.matches(7, &.{ 3, 9 }, 100));
    try std.testing.expect(!reservation.matches(8, &.{ 3, 9 }, 100));
    try std.testing.expect(!reservation.matches(7, &.{ 3, 10 }, 100));
    try std.testing.expect(!reservation.matches(7, &.{ 3, 9 }, 101));
}

test "예약 여유: 미리보기보다 크게 잡고, 상한에서 멈춘다" {
    // 여유가 **있다**는 것부터. 0 이면 이 고침이 통째로 무의미하다.
    try std.testing.expect(reservedBytesFor(1) > 1);
    try std.testing.expect(reservedBytesFor(64 * 1024) > 64 * 1024);

    // 2026-09-28 실측 그 숫자. 미리보기 13103944 에 대해 실제 13103947 이 **들어가야** 한다.
    try std.testing.expect(reservedBytesFor(13_103_944) >= 13_103_947);

    // 여유는 크기에 비례하되 최소값이 있다.
    try std.testing.expectEqual(
        @as(usize, 1024 + min_headroom_bytes),
        reservedBytesFor(1024),
    );
    const big: usize = min_headroom_bytes * headroom_divisor * 4;
    try std.testing.expectEqual(big + big / headroom_divisor, reservedBytesFor(big));

    // **상한에서는 여유를 포기한다.** 넘겨 잡으면 `validateLength` 가 거절해 승계가 시작도 못 한다.
    const cap = upgrade_limits.max_handoff_commit_bytes;
    try std.testing.expectEqual(cap, reservedBytesFor(cap));
    try std.testing.expectEqual(cap, reservedBytesFor(cap - 1));
    try std.testing.expectEqual(cap, reservedBytesFor(cap + 1));
}

test "예약 여유: prepare 가 그 여유를 실제로 쓴다 — 3 바이트 증가가 더는 승계를 취소하지 않는다" {
    // `reservedBytesFor` 가 옳아도 `prepare` 가 안 쓰면 아무것도 안 고쳐진다. 그래서 **진짜
    // prepare 를 통과시켜** 그 결과가 미리보기보다 큰지, 그리고 그만큼 자란 handoff 가
    // `.none` 으로 통과하는지 잰다.
    var dir_buf: [192]u8 = undefined;
    const dir = try test_scratch.open(std.testing.io, &dir_buf, "upgrade-budget-headroom");
    defer test_scratch.close(std.testing.io, dir);
    const deadline = try upgrade_deadline.Deadline.after(std.testing.io, 5 * std.time.ns_per_s);
    const preview_bytes: usize = 64 * 1024;
    var reservation = try prepare(
        std.testing.allocator,
        dir,
        0xC5,
        .{
            .bytes = preview_bytes,
            .membership_generation = 35,
            .runtime_ids = &.{ 2, 9 },
        },
        deadline,
    );
    defer reservation.cancel() catch {};

    try std.testing.expect(reservation.reserved_bytes > preview_bytes);

    // 실측 사건의 모양: 런타임 집합은 그대로인데 크기만 3 바이트 늘었다. 고치기 전에는 `.bytes`.
    try std.testing.expectEqual(
        Reservation.MismatchAxis.none,
        reservation.mismatchAxis(35, &.{ 2, 9 }, preview_bytes + 3),
    );

    // **양쪽을 다 잰다.** 「3 바이트를 봐준다」만 재면 가드를 통째로 없애도 통과한다 —
    // 여유를 넘긴 순간에는 여전히 `.bytes` 로 막혀야 한다.
    try std.testing.expectEqual(
        Reservation.MismatchAxis.bytes,
        reservation.mismatchAxis(35, &.{ 2, 9 }, reservation.reserved_bytes + 1),
    );

    // 그리고 여유가 **다른 세 축을 가려서는 안 된다.** 크기가 여유 안에 들어와도 런타임 집합이
    // 움직였으면 그대로 잡혀야 한다.
    try std.testing.expectEqual(
        Reservation.MismatchAxis.membership,
        reservation.mismatchAxis(36, &.{ 2, 9 }, preview_bytes + 3),
    );
    try std.testing.expectEqual(
        Reservation.MismatchAxis.count,
        reservation.mismatchAxis(35, &.{2}, preview_bytes + 3),
    );
    try std.testing.expectEqual(
        Reservation.MismatchAxis.ids,
        reservation.mismatchAxis(35, &.{ 2, 10 }, preview_bytes + 3),
    );
}

test "예약 대조는 어긋난 축을 가린다 — 넷이 한 이름으로 뭉치지 않는다" {
    // 2026-09-18 실측이 만든 판정자. host 로그가 `stage=budget_reservation_mismatch` 한 줄뿐이라
    // 네 원인이 구분되지 않았고, 그 줄을 근거로 원인을 **두 번 틀리게** 짚었다(처음엔 「크기가
    // 움직여서」, 다음엔 「멤버십 변화」). 축이 없으면 사람이 추측하게 된다.
    var reservation: Reservation = undefined;
    reservation.reserved_bytes = 100;
    reservation.membership_generation = 7;
    reservation.runtime_count = 2;
    reservation.runtime_ids[0] = 3;
    reservation.runtime_ids[1] = 9;

    try std.testing.expectEqual(
        Reservation.MismatchAxis.none,
        reservation.mismatchAxis(7, &.{ 3, 9 }, 100),
    );
    try std.testing.expectEqual(
        Reservation.MismatchAxis.membership,
        reservation.mismatchAxis(8, &.{ 3, 9 }, 100),
    );
    try std.testing.expectEqual(
        Reservation.MismatchAxis.count,
        reservation.mismatchAxis(7, &.{3}, 100),
    );
    // **`bytes` 축은 «예약분을 1 바이트만 넘어도» 어긋난다.** 여기 `reserved_bytes` 는 손으로
    // 100 을 넣은 값이라 여유가 없다 — 실제 `prepare` 가 얹는 여유는 `reservedBytesFor` 판정자가
    // 따로 잰다. 이 자리는 **비교 자체**가 느슨해지지 않았는지만 본다.
    try std.testing.expectEqual(
        Reservation.MismatchAxis.bytes,
        reservation.mismatchAxis(7, &.{ 3, 9 }, 101),
    );
    // 수는 같은데 id 가 바뀐 경우(교체) — `count` 가 아니라 `ids` 로 갈려야 한다.
    try std.testing.expectEqual(
        Reservation.MismatchAxis.ids,
        reservation.mismatchAxis(7, &.{ 3, 10 }, 100),
    );

    // **판정 순서가 축을 결정한다.** 둘이 동시에 어긋나면 먼저 검사한 축이 나온다 —
    // 그 우선순위를 못 박아, 다음 사람이 로그를 읽을 때 무엇이 가려졌는지 알 수 있게 한다.
    try std.testing.expectEqual(
        Reservation.MismatchAxis.membership,
        reservation.mismatchAxis(8, &.{ 3, 10 }, 101),
    );

    // `matches` 는 「축이 없음」과 **같은 판정**이어야 한다. 두 경로가 갈리면 로그와 동작이 어긋난다.
    try std.testing.expectEqual(
        reservation.matches(7, &.{ 3, 9 }, 100),
        reservation.mismatchAxis(7, &.{ 3, 9 }, 100) == .none,
    );
    try std.testing.expectEqual(
        reservation.matches(7, &.{ 3, 9 }, 101),
        reservation.mismatchAxis(7, &.{ 3, 9 }, 101) == .none,
    );
}
