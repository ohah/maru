//! U5 old-image transaction coordinator.
//!
//! 이 모듈은 daemon capability를 스스로 켜지 않는다. Daemon이 fully prepared controller를 설치한 뒤 socket의 armed
//! marker를 소비했을 때만 호출한다. 성공한 `exec`는 반환하지 않으며, 반환한 모든 경로는 같은 old runtime graph를
//! 재개하거나 authority-poisoned terminal 상태를 기록한다.

const builtin = @import("builtin");
const host_log = @import("host_log.zig");
const std = @import("std");
const c = std.c;
const posix = std.posix;
const entrypoint = @import("entrypoint.zig");
const exec_fd_set = @import("exec_fd_set.zig");
const handoff_store = @import("handoff_store.zig");
const host_manifest = @import("host_manifest.zig");
const owner_lease = @import("owner_lease.zig");
const rollback_image = @import("rollback_image.zig");
const runtime_manager = @import("runtime_manager.zig");
const upgrade_attempt = @import("upgrade_attempt.zig");
const budget_admission = @import("upgrade_budget_admission.zig");
const upgrade_deadline = @import("upgrade_deadline.zig");
const upgrade_fd_layout = @import("upgrade_fd_layout.zig");
const upgrade_limits = @import("upgrade_limits.zig");
const upgrade_owner = @import("upgrade_owner.zig");
const upgrade_wire = @import("upgrade_wire.zig");

extern "c" fn getdtablesize() c_int;
extern "c" fn usleep(useconds: c_uint) c_int;

pub const Authority = struct {
    ctx: *anyopaque,
    snapshot: *const fn (ctx: *anyopaque) AuthoritySnapshot,
    begin_restoring: *const fn (ctx: *anyopaque, expected: AuthoritySnapshot) AuthorityTransition,
    rollback_ready: *const fn (ctx: *anyopaque, expected: AuthoritySnapshot) AuthorityTransition,
    fail_stop: *const fn (ctx: *anyopaque, expected: AuthoritySnapshot) AuthorityTransition,
};

/// `unchanged_retryable`은 authority가 확실히 이전 상태 그대로일 때만 허용한다. 적용 여부가 불명인 실패는
/// `indeterminate_poisoned`로 fail-stop해야 old graph와 discovery manifest가 서로 다른 세대를 가리키지 않는다.
pub const AuthorityTransition = enum { applied, unchanged_retryable, indeterminate_poisoned };

pub const AuthoritySnapshot = struct {
    host_id: u128,
    upgrade_epoch: u64,
    authority_generation: u64 = 0,
    lifecycle: host_manifest.Lifecycle,
};

pub const Executor = struct {
    ctx: *anyopaque,
    preflight: *const fn (
        ctx: *anyopaque,
        target: upgrade_owner.VerifiedTarget,
        primary_fd: c.fd_t,
        deadline: upgrade_deadline.Deadline,
    ) PreflightError!void,
    /// 실제 구현은 `execv` 성공 시 반환하지 않는다. 반환 또는 error는 모두 old image의 exec 실패다.
    execute: *const fn (ctx: *anyopaque, request: ExecuteRequest) ExecError!void,
};

pub const PreflightError = error{ DeadlineExceeded, InvalidTarget, ResourceExhausted, Failed };
pub const ExecError = error{ExecFailed};

pub const ExecuteRequest = struct {
    target_path: [:0]const u8,
    restore: entrypoint.RestoreInvocation,
    runtime_slots: []const runtime_manager.RuntimeManager.UpgradeResource,
    deadline: upgrade_deadline.Deadline,
};

pub const Layout = upgrade_fd_layout.Layout;

/// 현재 source/host fd 위에서 259개 연속 free namespace를 찾는다. 실제 reserve가 다시 전량 검사하므로 이
/// snapshot 뒤 다른 thread가 fd를 열어도 잘못된 slot을 덮지 않고 attempt가 fail-closed한다.
pub fn findAvailableLayout(start: c.fd_t) ?Layout {
    var first = @max(start, 3);
    const max_fd = getdtablesize();
    while (@as(i64, first) + exec_fd_set.max_slots <= max_fd) : (first += 1) {
        var offset: usize = 0;
        while (offset < exec_fd_set.max_slots and
            !exec_fd_set.isOpen(first + @as(c.fd_t, @intCast(offset)))) : (offset += 1)
        {}
        if (offset == exec_fd_set.max_slots)
            return Layout.init(first) catch return null;
        first += @intCast(offset);
    }
    return null;
}

pub const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    owner: *upgrade_owner.UpgradeOwner,
    manager: *runtime_manager.RuntimeManager,
    gate: *@import("upgrade_coordinator.zig").AdmissionGate,
    lifetime_owner: *owner_lease.OwnerLease,
    rollback_image: *rollback_image.Authority,
    authority: Authority,
    executor: Executor,
    owner_dir: [:0]const u8,
    session_dir: []const u8,
    socket_path: []const u8,
    layout: Layout,
};

pub const Outcome = union(enum) {
    not_armed,
    invariant_violation,
    terminal: upgrade_wire.AttemptReport,
};

const max_authority_rollback_attempts: usize = 3;

fn processArmed(
    ctx: Context,
    attempt_id: u128,
) Outcome {
    return processArmedMode(ctx, attempt_id, false);
}

/// Readiness reactor가 accepted reply를 전량 flush하고 admission gate를 이미 닫은 typed marker 전용 경로.
pub fn processArmedPreclosed(
    ctx: Context,
    attempt_id: u128,
) Outcome {
    return processArmedMode(ctx, attempt_id, true);
}

/// Process E2E 전용이다. 제품 `Context`를 넓히지 않고 실제 preclosed coordinator에서 reservation
/// pathname identity 충돌을 만든다. 비-test artifact가 이 선언을 참조하면 컴파일 단계에서 닫힌다.
pub fn processArmedPreclosedCleanupCollisionFixture(
    ctx: Context,
    attempt_id: u128,
) Outcome {
    if (!builtin.is_test) @compileError("cleanup collision fixture is test-only");
    const deadline = upgrade_deadline.Deadline.after(ctx.io, upgrade_limits.pause_budget_ns) catch
        return .invariant_violation;
    return processArmedWithDeadlineHooks(ctx, attempt_id, deadline, true, null, replaceReservedPrimaryForFixture);
}

/// 실제 kernel permission/non-empty cleanup 실패를 만드는 process E2E 전용 경로다.
pub fn processArmedPreclosedKernelCleanupFaultFixture(
    ctx: Context,
    attempt_id: u128,
) Outcome {
    if (!builtin.is_test) @compileError("kernel cleanup fault fixture is test-only");
    const deadline = upgrade_deadline.Deadline.after(ctx.io, upgrade_limits.pause_budget_ns) catch
        return .invariant_violation;
    return processArmedWithDeadlineHooks(ctx, attempt_id, deadline, true, null, makeReservedAttemptReadOnlyForFixture);
}

/// Target staging 뒤 실제 owner filesystem을 ENOSPC까지 채우는 process E2E 전용 경로다.
pub fn processArmedPreclosedDiskFullAdmissionFixture(
    ctx: Context,
    attempt_id: u128,
) Outcome {
    if (!builtin.is_test) @compileError("disk full admission fixture is test-only");
    const deadline = upgrade_deadline.Deadline.after(ctx.io, upgrade_limits.pause_budget_ns) catch
        return .invariant_violation;
    return processArmedWithDeadlineHooks(
        ctx,
        attempt_id,
        deadline,
        true,
        fillOwnerVolumeUntilEnospcForFixture,
        null,
    );
}

fn processArmedMode(ctx: Context, attempt_id: u128, gate_preclosed: bool) Outcome {
    const deadline = upgrade_deadline.Deadline.after(ctx.io, upgrade_limits.pause_budget_ns) catch
        return .invariant_violation;
    return processArmedWithDeadline(ctx, attempt_id, deadline, gate_preclosed);
}

fn processArmedWithDeadline(
    ctx: Context,
    attempt_id: u128,
    deadline: upgrade_deadline.Deadline,
    gate_preclosed: bool,
) Outcome {
    return processArmedWithDeadlineHooks(ctx, attempt_id, deadline, gate_preclosed, null, null);
}

const BeforeBudgetPrepare = *const fn (owner_dir: [:0]const u8, attempt_id: u128) error{HookFailed}!void;

const AfterBudgetPrepare = *const fn (
    reservation: *budget_admission.Reservation,
) error{HookFailed}!void;

fn diskFullFixturePath(
    buffer: []u8,
    owner_dir: [:0]const u8,
    attempt_id: u128,
) error{HookFailed}![:0]const u8 {
    return std.fmt.bufPrintZ(
        buffer,
        "{s}/.disk-full-fixture-{x:0>32}",
        .{ owner_dir, attempt_id },
    ) catch error.HookFailed;
}

fn fillOwnerVolumeUntilEnospcForFixture(
    owner_dir: [:0]const u8,
    attempt_id: u128,
) error{HookFailed}!void {
    if (!builtin.is_test) @compileError("disk full fill is test-only");
    var path_buf: [1024]u8 = undefined;
    const path = try diskFullFixturePath(&path_buf, owner_dir, attempt_id);
    _ = c.unlink(path.ptr);
    const fd = c.open(
        path.ptr,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true, .NOFOLLOW = true },
        @as(c.mode_t, 0o600),
    );
    if (fd < 0) return error.HookFailed;
    defer _ = c.close(fd);

    var bytes: [64 * 1024]u8 = undefined;
    var state: u64 = @truncate(attempt_id ^ (attempt_id >> 64));
    if (state == 0) state = 0x9E3779B97F4A7C15;
    for (&bytes) |*byte| {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        byte.* = @truncate(state);
    }
    var written: usize = 0;
    const max_fixture_bytes: usize = 256 * 1024 * 1024;
    var chunk_len: usize = bytes.len;
    while (written < max_fixture_bytes) {
        const result = c.write(fd, &bytes, chunk_len);
        if (result > 0) {
            written += @intCast(result);
            continue;
        }
        if (result < 0 and posix.errno(result) == .INTR) continue;
        if (result < 0 and posix.errno(result) == posix.E.NOSPC) {
            if (chunk_len > 4096) {
                chunk_len = 4096;
                continue;
            }
            return;
        }
        return error.HookFailed;
    }
    return error.HookFailed;
}

fn removeDiskFullFixture(owner_dir: [:0]const u8, attempt_id: u128) void {
    var path_buf: [1024]u8 = undefined;
    const path = diskFullFixturePath(&path_buf, owner_dir, attempt_id) catch return;
    _ = c.unlink(path.ptr);
}

fn replaceReservedPrimaryForFixture(
    reservation: *budget_admission.Reservation,
) error{HookFailed}!void {
    const attempt_fd = reservation.store.attempt_fd;
    if (c.renameat(attempt_fd, "primary", attempt_fd, "saved") != 0)
        return error.HookFailed;
    const replacement_fd = c.openat(
        attempt_fd,
        "primary",
        .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true, .CLOEXEC = true, .NOFOLLOW = true },
        @as(c.mode_t, 0o600),
    );
    if (replacement_fd < 0) return error.HookFailed;
    _ = c.close(replacement_fd);
}

fn makeReservedAttemptReadOnlyForFixture(
    reservation: *budget_admission.Reservation,
) error{HookFailed}!void {
    if (c.fchmod(reservation.store.attempt_fd, 0o500) != 0) return error.HookFailed;
}

fn processArmedWithDeadlineHooks(
    ctx: Context,
    attempt_id: u128,
    deadline: upgrade_deadline.Deadline,
    gate_preclosed: bool,
    before_budget_prepare: ?BeforeBudgetPrepare,
    after_budget_prepare: ?AfterBudgetPrepare,
) Outcome {
    const execution = ctx.owner.beginExecution(attempt_id) orelse {
        const report = ctx.owner.status(attempt_id) orelse return .not_armed;
        if (report.status == .pending) return .not_armed;
        if (gate_preclosed and report.status == .resumed) ctx.gate.cancelClose();
        return .{ .terminal = report };
    };
    if (!ctx.rollback_image.revalidate()) {
        noteUpgradeStage("rollback_image_revalidate_pre_freeze");
        return finishBeforeFreeze(ctx, attempt_id, gate_preclosed, .{
            .status = .resumed,
            .reason = .handoff_failed,
        });
    }
    if (deadline.expired())
        return finishBeforeFreeze(ctx, attempt_id, gate_preclosed, .{
            .status = .resumed,
            .reason = .deadline_exceeded,
        });

    const ready_authority = ctx.authority.snapshot(ctx.authority.ctx);
    if (ready_authority.host_id == 0 or ready_authority.lifecycle != .ready)
        return finishBeforeFreeze(ctx, attempt_id, gate_preclosed, .{
            .status = .resumed,
            .reason = .runtime_changed,
        });

    const preview = ctx.manager.previewUpgradeHandoff(
        ctx.allocator,
        ready_authority.host_id,
        ready_authority.upgrade_epoch,
        ready_authority.authority_generation,
        @intCast(ctx.layout.first_runtime_slot),
    ) catch |err| return finishBeforeFreeze(
        ctx,
        attempt_id,
        gate_preclosed,
        reportForCaptureError(err),
    );
    const record = ctx.owner.encodeRunningRecordWithDeadline(
        ctx.allocator,
        execution,
        ready_authority.host_id,
        ready_authority.upgrade_epoch,
        ctx.rollback_image.record(),
        preview.sortedRuntimeIds(),
        deadline.expiresAtNs(),
    ) catch {
        noteUpgradeStage("attempt_record_build");
        return finishBeforeFreeze(ctx, attempt_id, gate_preclosed, .{
            .status = .resumed,
            .reason = .handoff_failed,
        });
    };
    defer ctx.allocator.free(record);
    const preview_bytes = preview.totalBytesWithAttempt(record.len) catch
        return finishBeforeFreeze(ctx, attempt_id, gate_preclosed, .{
            .status = .resumed,
            .reason = .state_too_large,
        });
    var disk_full_fixture_active = false;
    defer if (disk_full_fixture_active) removeDiskFullFixture(ctx.owner_dir, attempt_id);
    if (before_budget_prepare) |hook| {
        hook(ctx.owner_dir, attempt_id) catch return .invariant_violation;
        disk_full_fixture_active = true;
    }
    var budget_reservation = budget_admission.prepare(
        ctx.allocator,
        ctx.owner_dir,
        attempt_id,
        .{
            .bytes = preview_bytes,
            .membership_generation = preview.membership_generation,
            .runtime_ids = preview.sortedRuntimeIds(),
        },
        deadline,
    ) catch |err| return finishBeforeFreeze(
        ctx,
        attempt_id,
        gate_preclosed,
        reportForBudgetError(err),
    );
    if (after_budget_prepare) |hook| hook(&budget_reservation) catch {
        budget_reservation.cancel() catch {};
        return .invariant_violation;
    };
    const outcome = processBudgetReserved(
        ctx,
        attempt_id,
        execution,
        ready_authority,
        record,
        deadline,
        gate_preclosed,
        &budget_reservation,
    );
    budget_reservation.cancel() catch return .invariant_violation;
    return outcome;
}

fn processBudgetReserved(
    ctx: Context,
    attempt_id: u128,
    execution: upgrade_owner.Execution,
    ready_authority: AuthoritySnapshot,
    record: []const u8,
    deadline: upgrade_deadline.Deadline,
    gate_preclosed: bool,
    budget_reservation: *budget_admission.Reservation,
) Outcome {
    const requested = ctx.layout.requested() orelse
        return finishBeforeFreeze(ctx, attempt_id, gate_preclosed, .{
            .status = .resumed,
            .reason = .state_too_large,
        });
    assertNoUnexpectedInherited() catch {
        noteUpgradeStage("unexpected_inherited_fd");
        return finishBeforeFreeze(ctx, attempt_id, gate_preclosed, .{
            .status = .resumed,
            .reason = .handoff_failed,
        });
    };
    var reservation: exec_fd_set.SlotReservation = .{};
    reservation.reserve(&requested) catch {
        noteUpgradeStage("fd_slot_reserve");
        return finishBeforeFreeze(ctx, attempt_id, gate_preclosed, .{
            .status = .resumed,
            .reason = .handoff_failed,
        });
    };

    var frozen = (if (gate_preclosed)
        upgrade_attempt.freezePreclosed(ctx.manager, ctx.gate, deadline)
    else
        upgrade_attempt.freeze(ctx.manager, ctx.gate, deadline)) catch |err| {
        reservation.rollback();
        const report = reportForFreezeError(err);
        return if (report.reason == .runtime_resume_failed)
            finishRuntimeFailStop(ctx, attempt_id, deadline)
        else
            finish(ctx.owner, attempt_id, report);
    };
    defer reservation.rollback();
    const frozen_authority = ctx.authority.snapshot(ctx.authority.ctx);
    if (!std.meta.eql(frozen_authority, ready_authority))
        return resumeAndFinish(ctx, &frozen, attempt_id, .{ .status = .resumed, .reason = .runtime_changed }, deadline);

    var capture = frozen.prepareCapture(
        ctx.allocator,
        ready_authority.host_id,
        ready_authority.upgrade_epoch,
        ready_authority.authority_generation,
        @intCast(ctx.layout.first_runtime_slot),
    ) catch |err| return resumeAndFinish(ctx, &frozen, attempt_id, reportForCaptureError(err), deadline);
    defer capture.deinit();
    var runtime_id_buf: [upgrade_limits.max_runtime_count]u128 = undefined;
    const runtime_ids = capture.sortedRuntimeIds(&runtime_id_buf);
    const next_handle = capture.next_handle;
    const handoff_bytes = capture.encode(record) catch
        return resumeAndFinish(ctx, &frozen, attempt_id, .{
            .status = .resumed,
            .reason = .handoff_failed,
        }, deadline);
    defer ctx.allocator.free(handoff_bytes);
    if (deadline.expired())
        return resumeAndFinish(ctx, &frozen, attempt_id, .{
            .status = .resumed,
            .reason = .deadline_exceeded,
        }, deadline);

    if (!budget_reservation.matches(
        capture.membership_generation,
        runtime_ids,
        handoff_bytes.len,
    )) return resumeAndFinish(ctx, &frozen, attempt_id, .{
        .status = .resumed,
        .reason = .runtime_changed,
    }, deadline);

    var pair = budget_reservation.commit(
        ctx.allocator,
        .{
            .host_id = ready_authority.host_id,
            .attempt_id = attempt_id,
            .upgrade_epoch = ready_authority.upgrade_epoch,
            .next_handle = next_handle,
            .runtime_ids = runtime_ids,
            .request_path = execution.request_path,
            .staged_path = execution.target.artifact.path,
            .build_id = execution.target.build_id,
            .sha256 = execution.target.artifact.sha256,
            .dev = execution.target.artifact.dev,
            .ino = execution.target.artifact.ino,
            .size = execution.target.artifact.size,
            .rollback_image = ctx.rollback_image.record(),
            .reader_min = execution.target.reader_min,
            .reader_max = execution.target.reader_max,
        },
        handoff_bytes,
        deadline,
    ) catch |err| return resumeAndFinish(ctx, &frozen, attempt_id, reportForStoreError(err), deadline);
    defer pair.deinit();

    ctx.executor.preflight(
        ctx.executor.ctx,
        execution.target,
        pair.primary_fd,
        deadline,
    ) catch |err| return resumeAndFinish(ctx, &frozen, attempt_id, reportForPreflightError(err), deadline);
    if (deadline.expired())
        return resumeAndFinish(ctx, &frozen, attempt_id, .{
            .status = .resumed,
            .reason = .deadline_exceeded,
        }, deadline);
    if (!ctx.owner.revalidateExecution(execution))
        return resumeAndFinish(ctx, &frozen, attempt_id, .{
            .status = .resumed,
            .reason = .target_invalid,
        }, deadline);
    if (!ctx.rollback_image.revalidate()) {
        noteUpgradeStage("rollback_image_revalidate_post_freeze");
        return resumeAndFinish(ctx, &frozen, attempt_id, .{
            .status = .resumed,
            .reason = .handoff_failed,
        }, deadline);
    }
    ctx.manager.revalidateQuiescedCapture(&capture) catch
        return resumeAndFinish(ctx, &frozen, attempt_id, .{
            .status = .resumed,
            .reason = .runtime_changed,
        }, deadline);

    switch (ctx.authority.begin_restoring(ctx.authority.ctx, ready_authority)) {
        .applied => {},
        .unchanged_retryable => return resumeAndFinish(ctx, &frozen, attempt_id, .{
            .status = .resumed,
            .reason = .handoff_failed,
        }, deadline),
        .indeterminate_poisoned => {
            frozen.active = false;
            return finish(ctx.owner, attempt_id, .{
                .status = .failed_nonretryable,
                .reason = .authority_poisoned,
            });
        },
    }
    // begin_restoring 자체가 authority의 한 변경이다. ready 시점의 generation을 lifecycle만 바꿔 재사용하면
    // ready→restoring→ready ABA를 구분하려고 추가한 CAS가 정상 rollback까지 거부한다. 전환 직후 fresh snapshot을
    // 잡아 이후 모든 rollback의 exact restoring authority로 사용한다.
    const restoring_authority = ctx.authority.snapshot(ctx.authority.ctx);
    const expected_generation = std.math.add(u64, ready_authority.authority_generation, 1) catch {
        frozen.active = false;
        return finish(ctx.owner, attempt_id, .{
            .status = .failed_nonretryable,
            .reason = .authority_poisoned,
        });
    };
    if (restoring_authority.host_id != ready_authority.host_id or
        restoring_authority.upgrade_epoch != ready_authority.upgrade_epoch or
        restoring_authority.lifecycle != .restoring or
        restoring_authority.authority_generation != expected_generation)
    {
        frozen.active = false;
        return finish(ctx.owner, attempt_id, .{
            .status = .failed_nonretryable,
            .reason = .authority_poisoned,
        });
    }
    if (!replaceAll(&reservation, capture.resources, pair, ctx.lifetime_owner, ctx.layout))
        return rollbackAuthority(ctx, &frozen, restoring_authority, attempt_id, .handoff_failed, deadline);
    reservation.assertExactNonCloexec(&.{}) catch
        return rollbackAuthority(ctx, &frozen, restoring_authority, attempt_id, .handoff_failed, deadline);
    if (deadline.expired())
        return rollbackAuthority(ctx, &frozen, restoring_authority, attempt_id, .deadline_exceeded, deadline);
    // Manifest republish와 FD replacement 사이에도 child/fd graph는 변할 수 있다. pathname exec 바로 전 같은 capture를
    // 다시 대조하고 달라졌으면 restoring authority를 rollback한 뒤 old graph만 재개한다.
    ctx.manager.revalidateQuiescedCapture(&capture) catch
        return rollbackAuthority(ctx, &frozen, restoring_authority, attempt_id, .runtime_changed, deadline);
    if (!ctx.rollback_image.revalidate())
        return rollbackAuthority(ctx, &frozen, restoring_authority, attempt_id, .handoff_failed, deadline);

    ctx.executor.execute(ctx.executor.ctx, .{
        .target_path = execution.target.artifact.path,
        .restore = .{
            .role = .target,
            .session_dir = ctx.session_dir,
            .socket_path = ctx.socket_path,
            .host_id = ready_authority.host_id,
            .attempt_id = attempt_id,
            .layout = ctx.layout,
        },
        .runtime_slots = capture.resources,
        .deadline = deadline,
    }) catch {};
    return rollbackAuthority(ctx, &frozen, restoring_authority, attempt_id, .exec_failed, deadline);
}

/// The readiness owner closes admission before publishing its typed marker. Any retryable failure
/// before runtime quiesce therefore owns the matching reopen; after `freezePreclosed` succeeds the
/// Frozen rollback guard becomes the sole owner instead.
fn finishBeforeFreeze(
    ctx: Context,
    attempt_id: u128,
    gate_preclosed: bool,
    report: upgrade_wire.AttemptReport,
) Outcome {
    const outcome = finish(ctx.owner, attempt_id, report);
    if (gate_preclosed) switch (outcome) {
        .terminal => |terminal| if (terminal.status == .resumed) ctx.gate.cancelClose(),
        else => {},
    };
    return outcome;
}

test "preclosed retryable failure reopens admission before runtime freeze" {
    var owner = upgrade_owner.UpgradeOwner.init(std.testing.allocator, TestStager.ops(), null);
    defer owner.deinit();
    const attempt_id: u128 = 0xD1;
    try std.testing.expectEqual(upgrade_wire.PrepareDecision.accepted, owner.stagePending(.{
        .attempt_id = attempt_id,
        .target_path = "/Applications/Maru.app/Contents/MacOS/maru",
        .target_build_id = "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
        .target_sha256 = [_]u8{0xDD} ** 32,
        .handoff_reader_min = 1,
        .handoff_reader_max = 1,
    }));
    try std.testing.expectEqual(upgrade_wire.ArmDecision.armed, owner.armAccepted(attempt_id));
    _ = owner.beginExecution(attempt_id) orelse return error.TestUnexpectedResult;
    var gate = @import("upgrade_coordinator.zig").AdmissionGate.init(std.testing.io);
    try std.testing.expect(gate.close());
    var ctx: Context = undefined;
    ctx.owner = &owner;
    ctx.gate = &gate;
    const outcome = finishBeforeFreeze(ctx, attempt_id, true, .{
        .status = .resumed,
        .reason = .handoff_failed,
    });
    const report = switch (outcome) {
        .terminal => |terminal| terminal,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(upgrade_wire.AttemptStatus.resumed, report.status);
    try std.testing.expect(gate.snapshot().open);
}

test "preclosed target revalidation failure reopens admission through product entrypoint" {
    const MutableStager = struct {
        valid: bool = true,

        fn stage(
            _: *anyopaque,
            allocator: std.mem.Allocator,
            request: upgrade_wire.PrepareRequest,
        ) upgrade_owner.StageDecision {
            const path = std.fmt.allocPrintSentinel(
                allocator,
                "/staged/{x:0>32}",
                .{request.attempt_id},
                0,
            ) catch return .resource_exhausted;
            const build_id = allocator.dupe(u8, request.target_build_id) catch {
                allocator.free(path);
                return .resource_exhausted;
            };
            return .{ .verified = .{
                .artifact = .{
                    .path = path,
                    .exec_fd = -1,
                    .sha256 = request.target_sha256,
                    .dev = 1,
                    .ino = 1,
                    .size = 1,
                },
                .build_id = build_id,
                .reader_min = request.handoff_reader_min,
                .reader_max = request.handoff_reader_max,
            } };
        }
        fn restore(
            _: *anyopaque,
            _: std.mem.Allocator,
            _: upgrade_owner.RecordedTarget,
        ) upgrade_owner.StageDecision {
            return .unsupported;
        }
        fn release(
            _: *anyopaque,
            allocator: std.mem.Allocator,
            artifact: *upgrade_owner.StagedArtifact,
        ) void {
            allocator.free(artifact.path);
            artifact.* = undefined;
        }
        fn verify(ctx: *anyopaque, _: upgrade_owner.VerifiedTarget) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.valid;
        }
        fn ops(self: *@This()) upgrade_owner.TargetStager {
            return .{
                .ctx = self,
                .stage = stage,
                .restore = restore,
                .release_artifact = release,
                .verify = verify,
            };
        }
    };
    var stager: MutableStager = .{};
    var owner = upgrade_owner.UpgradeOwner.init(std.testing.allocator, stager.ops(), null);
    defer owner.deinit();
    const attempt_id: u128 = 0xD2;
    try std.testing.expectEqual(upgrade_wire.PrepareDecision.accepted, owner.stagePending(.{
        .attempt_id = attempt_id,
        .target_path = "/Applications/Maru.app/Contents/MacOS/maru",
        .target_build_id = "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
        .target_sha256 = [_]u8{0xEE} ** 32,
        .handoff_reader_min = 1,
        .handoff_reader_max = 1,
    }));
    try std.testing.expectEqual(upgrade_wire.ArmDecision.armed, owner.armAccepted(attempt_id));
    stager.valid = false;
    var gate = @import("upgrade_coordinator.zig").AdmissionGate.init(std.testing.io);
    try std.testing.expect(gate.close());
    var ctx: Context = undefined;
    ctx.owner = &owner;
    ctx.gate = &gate;
    const outcome = processArmedWithDeadline(
        ctx,
        attempt_id,
        upgrade_deadline.Deadline.testingNever(),
        true,
    );
    const report = switch (outcome) {
        .terminal => |terminal| terminal,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(upgrade_wire.AttemptStatus.resumed, report.status);
    try std.testing.expectEqual(upgrade_wire.AttemptReason.target_invalid, report.reason);
    try std.testing.expect(gate.snapshot().open);
}

fn replaceAll(
    reservation: *exec_fd_set.SlotReservation,
    resources: []const runtime_manager.RuntimeManager.UpgradeResource,
    pair: handoff_store.Pair,
    lifetime_owner: *owner_lease.OwnerLease,
    layout: Layout,
) bool {
    for (resources) |resource|
        reservation.replace(resource.source_fd, resource.inherited_slot) catch return false;
    reservation.replace(pair.primary_fd, layout.primarySlot()) catch return false;
    reservation.replace(pair.backup_fd, layout.backupSlot()) catch return false;
    reservation.replace(lifetime_owner.descriptor(), layout.ownerSlot()) catch return false;
    return true;
}

/// upgrade 가 **어느 단계에서** 되돌려졌는지 남긴다.
///
/// `handoff_failed` 하나가 이 파일에서 12 곳에 쓰인다. 그래서 `logUpgradeRollback` 이 사유를 남겨도
/// 「exec 준비 중 어딘가」까지만 좁혀지고, rollback 이미지 검증인지 fd 슬롯 확보인지 상속 fd 검사인지는
/// 갈리지 않는다. 2026-08-30 실측: 사용자 PTY 25 개를 쥔 host 가 업그레이드에 반복 실패해 빌드마다 새
/// host 가 뜨고 세션이 고아가 됐는데, 이 구분이 없어 원인을 특정하지 못했다.
fn noteUpgradeStage(stage: []const u8) void {
    if (builtin.is_test) return;
    host_log.line("session host upgrade stage failed: stage={s}", .{stage});
}

/// upgrade 가 **왜 되돌려졌는지** host 로그에 남긴다.
///
/// 이 파일에는 `std.log` 가 한 줄도 없었다. 그래서 `redirectStderrToHostLog` 가 만든
/// `host-<id>.log` 가 **전부 0 바이트**였고, exec 가 실패해도 host 쪽에는 아무 흔적이 남지 않았다.
/// 2026-08-27 실측: upgrade 가 manifest 를 새 build_id 로 갱신한 뒤 exec 에서 끊겨, 구 host 가
/// **거짓 build_id 를 광고하는 상태로 굳었다**(실체는 옛 이미지). 그 결과 앱은 붙을 때마다
/// `stale_manifest` 를 만나 새 host 를 띄웠고, 사용자 PTY 6 개를 쥔 구 host 는 고아가 됐다.
/// 되돌림 사유 한 줄이 있었다면 exec 실패인지 target 문제인지 즉시 갈렸다.
fn logUpgradeRollback(attempt_id: u128, reason: upgrade_wire.AttemptReason) void {
    if (builtin.is_test) return;
    // 2026-08-27 에 `std.log.err` 로 들어왔으나 그 호출이 host 를 SIGSEGV 로 죽여 로그는 계속
    // 0 바이트였다. 이유와 대안은 `host_log` 참고.
    host_log.line(
        "session host upgrade rolled back: attempt={x:0>32} reason={s}",
        .{ attempt_id, @tagName(reason) },
    );
}

fn rollbackAuthority(
    ctx: Context,
    frozen: *upgrade_attempt.Frozen,
    expected_restoring: AuthoritySnapshot,
    attempt_id: u128,
    reason: upgrade_wire.AttemptReason,
    deadline: upgrade_deadline.Deadline,
) Outcome {
    logUpgradeRollback(attempt_id, reason);
    std.debug.assert(frozen.active);
    const actual = ctx.authority.snapshot(ctx.authority.ctx);
    if (expected_restoring.lifecycle != .restoring or
        !std.meta.eql(actual, expected_restoring))
    {
        frozen.active = false;
        return finish(ctx.owner, attempt_id, .{
            .status = .failed_nonretryable,
            .reason = .authority_poisoned,
        });
    }
    var prepared = frozen.prepareRollbackToServing() catch {
        frozen.active = false;
        return finish(ctx.owner, attempt_id, .{
            .status = .failed_nonretryable,
            .reason = .runtime_resume_failed,
        });
    };
    defer prepared.discard();
    switch (rollbackReadyBounded(ctx.authority, expected_restoring, deadline)) {
        .applied => {
            frozen.commitPreparedRollback(&prepared);
            return finish(ctx.owner, attempt_id, .{ .status = .resumed, .reason = reason });
        },
        .unchanged_retryable, .indeterminate_poisoned => {},
    }
    frozen.active = false;
    return finish(ctx.owner, attempt_id, .{
        .status = .failed_nonretryable,
        .reason = .authority_poisoned,
    });
}

fn rollbackReadyBounded(
    authority: Authority,
    expected: AuthoritySnapshot,
    deadline: upgrade_deadline.Deadline,
) AuthorityTransition {
    var attempts: usize = 0;
    while (attempts < max_authority_rollback_attempts) : (attempts += 1) {
        if (attempts != 0 and deadline.expired()) break;
        switch (authority.rollback_ready(authority.ctx, expected)) {
            .applied => return .applied,
            .unchanged_retryable => {
                // Authority CAS/I/O의 일시 실패는 같은 transaction deadline 안에서만 제한적으로 재시도한다. 첫 rollback은
                // deadline이 이미 지난 exec-failure 경로에서도 반드시 시도하고, 그 뒤에는 무한 정지 대신 fail-stop한다.
            },
            .indeterminate_poisoned => return .indeterminate_poisoned,
        }
    }
    return .unchanged_retryable;
}

fn resumeAndFinish(
    ctx: Context,
    frozen: *upgrade_attempt.Frozen,
    attempt_id: u128,
    report: upgrade_wire.AttemptReport,
    deadline: upgrade_deadline.Deadline,
) Outcome {
    frozen.rollbackToServing() catch {
        // Reader thread를 전부 준비하지 못했으면 admission을 열거나 `resumed`를 기록하지 않고 runtime-specific
        // terminal reason으로 남긴다. Disk authority poison과 구분돼 운영자가 올바른 fail-stop 원인을 볼 수 있다.
        frozen.active = false;
        return finishRuntimeFailStop(ctx, attempt_id, deadline);
    };
    return finish(ctx.owner, attempt_id, report);
}

fn finishRuntimeFailStop(
    ctx: Context,
    attempt_id: u128,
    deadline: upgrade_deadline.Deadline,
) Outcome {
    const expected = ctx.authority.snapshot(ctx.authority.ctx);
    if (expected.lifecycle != .ready or failStopBounded(ctx.authority, expected, deadline) != .applied)
        return .invariant_violation;
    return finish(ctx.owner, attempt_id, .{
        .status = .failed_nonretryable,
        .reason = .runtime_resume_failed,
    });
}

fn failStopBounded(
    authority: Authority,
    expected: AuthoritySnapshot,
    deadline: upgrade_deadline.Deadline,
) AuthorityTransition {
    var attempts: usize = 0;
    while (attempts < max_authority_rollback_attempts) : (attempts += 1) {
        if (attempts != 0 and deadline.expired()) break;
        switch (authority.fail_stop(authority.ctx, expected)) {
            .applied => return .applied,
            .unchanged_retryable => {},
            .indeterminate_poisoned => return .indeterminate_poisoned,
        }
    }
    return .unchanged_retryable;
}

fn finish(
    owner: *upgrade_owner.UpgradeOwner,
    attempt_id: u128,
    report: upgrade_wire.AttemptReport,
) Outcome {
    if (!owner.finish(attempt_id, report)) return .invariant_violation;
    return .{ .terminal = report };
}

fn reportForFreezeError(err: upgrade_attempt.Error) upgrade_wire.AttemptReport {
    return switch (err) {
        error.ResumeFailed => .{ .status = .failed_nonretryable, .reason = .runtime_resume_failed },
        error.DeadlineExceeded => .{ .status = .resumed, .reason = .deadline_exceeded },
        error.TooManyRuntimes, error.LimitExceeded => .{ .status = .resumed, .reason = .state_too_large },
        else => .{ .status = .resumed, .reason = .runtime_changed },
    };
}

fn reportForCaptureError(
    err: (runtime_manager.RuntimeManager.QuiesceError || @import("handoff_codec.zig").Error),
) upgrade_wire.AttemptReport {
    return switch (err) {
        error.TooManyRuntimes, error.LimitExceeded => .{ .status = .resumed, .reason = .state_too_large },
        error.OutOfMemory => blk: {
            noteUpgradeStage("exec_prepare_out_of_memory");
            break :blk .{ .status = .resumed, .reason = .handoff_failed };
        },
        else => .{ .status = .resumed, .reason = .runtime_changed },
    };
}

fn reportForStoreError(err: handoff_store.Error) upgrade_wire.AttemptReport {
    return switch (err) {
        error.DeadlineExceeded => .{ .status = .resumed, .reason = .deadline_exceeded },
        error.LimitExceeded, error.InsufficientSpace => .{ .status = .resumed, .reason = .state_too_large },
        else => .{ .status = .resumed, .reason = .handoff_failed },
    };
}

fn reportForBudgetError(err: budget_admission.Error) upgrade_wire.AttemptReport {
    return switch (err) {
        error.DeadlineExceeded => .{ .status = .resumed, .reason = .deadline_exceeded },
        error.LimitExceeded, error.InsufficientSpace, error.InsufficientIoBudget => .{ .status = .resumed, .reason = .state_too_large },
        else => .{ .status = .resumed, .reason = .handoff_failed },
    };
}

fn reportForPreflightError(err: PreflightError) upgrade_wire.AttemptReport {
    return switch (err) {
        error.DeadlineExceeded => .{ .status = .resumed, .reason = .deadline_exceeded },
        error.InvalidTarget => .{ .status = .resumed, .reason = .target_invalid },
        error.ResourceExhausted => .{ .status = .resumed, .reason = .state_too_large },
        error.Failed => blk: {
            noteUpgradeStage("exec_failed");
            break :blk .{ .status = .resumed, .reason = .handoff_failed };
        },
    };
}

fn assertNoUnexpectedInherited() exec_fd_set.Error!void {
    var open: [exec_fd_set.max_slots]c.fd_t = undefined;
    if (try exec_fd_set.collectNonCloexec(&open) != 0) return error.UnexpectedInheritedFd;
}

fn snapshotContainsText(
    allocator: std.mem.Allocator,
    snapshot: []const u8,
    needle: []const u8,
) !bool {
    const screen_stream = @import("maru").session.screen_stream;
    var records: screen_stream.RecordStream = .{ .bytes = snapshot };
    var row_text: std.ArrayListUnmanaged(u8) = .empty;
    defer row_text.deinit(allocator);
    while (try records.next()) |record| {
        const split = try screen_stream.RecordStream.split(record);
        if (split.header.kind != .row) continue;
        const row = try screen_stream.decodeRow(allocator, split.body);
        defer row.deinit(allocator);
        row_text.clearRetainingCapacity();
        for (row.runs) |run| {
            var repeat: u32 = 0;
            while (repeat < run.count) : (repeat += 1)
                try row_text.appendSlice(allocator, run.grapheme);
        }
        if (std.mem.indexOf(u8, row_text.items, needle) != null) return true;
    }
    return false;
}

test "product coordinator layout reserves 256 runtime and three fixed roles without overlap" {
    const layout = try Layout.init(40);
    const requested = layout.requested().?;
    try std.testing.expectEqual(@as(c.fd_t, 40), requested[0]);
    try std.testing.expectEqual(@as(c.fd_t, 295), requested[upgrade_limits.max_runtime_count - 1]);
    try std.testing.expectEqual(@as(c.fd_t, 296), layout.primarySlot());
    try std.testing.expectEqual(@as(c.fd_t, 297), layout.backupSlot());
    try std.testing.expectEqual(@as(c.fd_t, 298), layout.ownerSlot());
    try std.testing.expectEqual(layout.ownerSlot(), requested[requested.len - 1]);
}

test "authority rollback boundary is three total attempts one poisoned call and one expired mandatory call" {
    const Fake = struct {
        calls: usize = 0,
        result: AuthorityTransition,

        fn snapshot(_: *anyopaque) AuthoritySnapshot {
            return .{ .host_id = 1, .upgrade_epoch = 2, .lifecycle = .restoring };
        }

        fn begin(_: *anyopaque, _: AuthoritySnapshot) AuthorityTransition {
            return .applied;
        }

        fn rollback(ctx: *anyopaque, _: AuthoritySnapshot) AuthorityTransition {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            return self.result;
        }

        fn failStop(ctx: *anyopaque, expected: AuthoritySnapshot) AuthorityTransition {
            return rollback(ctx, expected);
        }

        fn authority(self: *@This()) Authority {
            return .{
                .ctx = self,
                .snapshot = snapshot,
                .begin_restoring = begin,
                .rollback_ready = rollback,
                .fail_stop = failStop,
            };
        }
    };
    const expected: AuthoritySnapshot = .{ .host_id = 1, .upgrade_epoch = 2, .lifecycle = .restoring };

    var exhausted: Fake = .{ .result = .unchanged_retryable };
    try std.testing.expectEqual(
        AuthorityTransition.unchanged_retryable,
        rollbackReadyBounded(exhausted.authority(), expected, .testingNever()),
    );
    try std.testing.expectEqual(@as(usize, 3), exhausted.calls);

    var poisoned: Fake = .{ .result = .indeterminate_poisoned };
    try std.testing.expectEqual(
        AuthorityTransition.indeterminate_poisoned,
        rollbackReadyBounded(poisoned.authority(), expected, .testingNever()),
    );
    try std.testing.expectEqual(@as(usize, 1), poisoned.calls);

    const ExpiredClock = struct {
        fn now(_: *anyopaque) i128 {
            return 10;
        }
    };
    const expired = upgrade_deadline.Deadline.fromInjected(.{
        .ctx = @ptrFromInt(1),
        .now_ns = ExpiredClock.now,
    }, 10);
    var expired_retry: Fake = .{ .result = .unchanged_retryable };
    try std.testing.expectEqual(
        AuthorityTransition.unchanged_retryable,
        rollbackReadyBounded(expired_retry.authority(), expected, expired),
    );
    try std.testing.expectEqual(@as(usize, 1), expired_retry.calls);
}

test "product coordinator rejects any preexisting inherited descriptor" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    // Test runner 자체 protocol fd만 잠시 CLOEXEC로 숨긴 뒤, 제품 host에는 존재하면 안 되는 임의 inherited fd 하나를
    // 남긴다. 이 gate가 allowlist를 느슨하게 바꾸면 exec가 unrelated socket/file까지 새 image로 유출한다.
    var runner_fds: [exec_fd_set.max_slots]c.fd_t = undefined;
    const runner_fd_count = try exec_fd_set.collectNonCloexec(&runner_fds);
    for (runner_fds[0..runner_fd_count]) |fd| {
        const flags = c.fcntl(fd, c.F.GETFD, @as(c_int, 0));
        if (flags < 0 or c.fcntl(fd, c.F.SETFD, flags | c.FD_CLOEXEC) < 0)
            return error.SkipZigTest;
    }
    defer for (runner_fds[0..runner_fd_count]) |fd| {
        const flags = c.fcntl(fd, c.F.GETFD, @as(c_int, 0));
        if (flags >= 0) _ = c.fcntl(fd, c.F.SETFD, flags & ~@as(c_int, c.FD_CLOEXEC));
    };

    var pipe_fds: [2]c.fd_t = undefined;
    if (c.pipe(&pipe_fds) != 0) return error.SkipZigTest;
    defer {
        _ = c.close(pipe_fds[0]);
        _ = c.close(pipe_fds[1]);
    }
    for (pipe_fds) |fd| {
        const flags = c.fcntl(fd, c.F.GETFD, @as(c_int, 0));
        if (flags < 0 or c.fcntl(fd, c.F.SETFD, flags & ~@as(c_int, c.FD_CLOEXEC)) < 0)
            return error.SkipZigTest;
    }
    try std.testing.expectError(error.UnexpectedInheritedFd, assertNoUnexpectedInherited());
}

const TestStager = struct {
    fn ops() upgrade_owner.TargetStager {
        return .{
            .ctx = @ptrFromInt(1),
            .stage = stage,
            .restore = restore,
            .release_artifact = releaseArtifact,
            .verify = verify,
        };
    }

    fn stage(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        request: upgrade_wire.PrepareRequest,
    ) upgrade_owner.StageDecision {
        const path = std.fmt.allocPrintSentinel(
            allocator,
            "/staged/{x:0>32}",
            .{request.attempt_id},
            0,
        ) catch return .resource_exhausted;
        const build_id = allocator.dupe(u8, request.target_build_id) catch {
            allocator.free(path);
            return .resource_exhausted;
        };
        return .{ .verified = .{
            .artifact = .{
                .path = path,
                .exec_fd = -1,
                .sha256 = request.target_sha256,
                .dev = 7,
                .ino = @truncate(request.attempt_id),
                .size = 4096,
            },
            .build_id = build_id,
            .reader_min = request.handoff_reader_min,
            .reader_max = request.handoff_reader_max,
        } };
    }

    fn restore(
        _: *anyopaque,
        _: std.mem.Allocator,
        _: upgrade_owner.RecordedTarget,
    ) upgrade_owner.StageDecision {
        return .unsupported;
    }

    fn releaseArtifact(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        artifact: *upgrade_owner.StagedArtifact,
    ) void {
        allocator.free(artifact.path);
        artifact.* = undefined;
    }

    fn verify(_: *anyopaque, _: upgrade_owner.VerifiedTarget) bool {
        return true;
    }
};

fn runProductCoordinatorTest(cleanup_collision: bool) !void {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const product_raw = c.getenv("MARU_SESSION_HOST_PRODUCT_EXE") orelse return error.SkipZigTest;
    const product_raw_path = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        std.mem.span(product_raw),
        allocator,
    );
    defer allocator.free(product_raw_path);
    const product = try allocator.dupeZ(u8, product_raw_path);
    defer allocator.free(product);
    const product_identity = try @import("staged_image.zig").inspect(product);
    var dir_buf: [192]u8 = undefined;
    const owner_dir = std.fmt.bufPrintZ(
        &dir_buf,
        "/tmp/maru-product-coordinator-{d}-{d}",
        .{ c.getpid(), std.Io.Clock.awake.now(std.testing.io).nanoseconds },
    ) catch return error.SkipZigTest;
    _ = c.rmdir(owner_dir.ptr);
    if (c.mkdir(owner_dir.ptr, 0o700) != 0) return error.TestUnexpectedResult;
    var owner_path_buf: [224]u8 = undefined;
    const owner_path = try std.fmt.bufPrintZ(&owner_path_buf, "{s}/owner.lock", .{owner_dir});
    var lifetime_owner = owner_lease.OwnerLease.acquire(owner_path) catch return error.SkipZigTest;
    defer {
        _ = lifetime_owner.unlinkOwnedWhileLocked(owner_path) catch {};
        lifetime_owner.deinit();
        std.Io.Dir.cwd().deleteTree(std.testing.io, owner_dir) catch {};
    }
    var rollback_authority = rollback_image.Authority.prepare(
        allocator,
        product,
        product_identity,
        owner_dir,
    ) catch return error.SkipZigTest;
    defer rollback_authority.deinit();

    const reg = @import("registry.zig");
    var registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer registry.deinit();
    var manager: runtime_manager.RuntimeManager = undefined;
    manager.init(allocator, std.testing.io, &registry, null);
    defer manager.deinit();
    const runtime_ops = manager.runtimeOps();
    const runtime_id = try runtime_ops.spawn(runtime_ops.ctx, .{
        .argv = &.{"/bin/cat"},
        .cwd = null,
        .cols = 20,
        .rows = 4,
    });
    defer runtime_ops.terminate(runtime_ops.ctx, runtime_id);

    var owner = upgrade_owner.UpgradeOwner.init(allocator, TestStager.ops(), null);
    defer owner.deinit();
    const attempt_id: u128 = if (cleanup_collision) 0xA2 else 0xA1;
    const request: upgrade_wire.PrepareRequest = .{
        .attempt_id = attempt_id,
        .target_path = "/Applications/Maru.app/Contents/MacOS/maru",
        .target_build_id = "sha256:abababababababababababababababababababababababababababababababab",
        .target_sha256 = [_]u8{0xAB} ** 32,
        .handoff_reader_min = 1,
        .handoff_reader_max = 1,
    };
    try std.testing.expectEqual(upgrade_wire.PrepareDecision.accepted, owner.stagePending(request));
    try std.testing.expectEqual(upgrade_wire.ArmDecision.armed, owner.armAccepted(attempt_id));

    const FakeAuthority = struct {
        begin_count: usize = 0,
        rollback_count: usize = 0,
        lifecycle: host_manifest.Lifecycle = .ready,
        authority_generation: u64 = 1,

        fn snapshot(ctx: *anyopaque) AuthoritySnapshot {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return .{
                .host_id = 0xB2,
                .upgrade_epoch = 4,
                .authority_generation = self.authority_generation,
                .lifecycle = self.lifecycle,
            };
        }

        fn begin(ctx: *anyopaque, expected: AuthoritySnapshot) AuthorityTransition {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.begin_count += 1;
            if (expected.host_id != 0xB2 or
                expected.upgrade_epoch != 4 or
                expected.authority_generation != self.authority_generation or
                expected.lifecycle != .ready)
                return .indeterminate_poisoned;
            self.lifecycle = .restoring;
            self.authority_generation += 1;
            return .applied;
        }

        fn rollback(ctx: *anyopaque, expected: AuthoritySnapshot) AuthorityTransition {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.rollback_count += 1;
            if (expected.host_id != 0xB2 or
                expected.upgrade_epoch != 4 or
                expected.authority_generation != self.authority_generation or
                expected.lifecycle != .restoring)
                return .indeterminate_poisoned;
            if (self.rollback_count == 1) return .unchanged_retryable;
            self.lifecycle = .ready;
            self.authority_generation += 1;
            return .applied;
        }

        fn failStop(ctx: *anyopaque, expected: AuthoritySnapshot) AuthorityTransition {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (expected.host_id != 0xB2 or
                expected.upgrade_epoch != 4 or
                expected.authority_generation != self.authority_generation or
                expected.lifecycle != .ready)
                return .indeterminate_poisoned;
            self.lifecycle = .draining;
            self.authority_generation += 1;
            return .applied;
        }
    };
    const FakeExecutor = struct {
        preflight_count: usize = 0,
        execute_count: usize = 0,

        fn preflight(
            ctx: *anyopaque,
            _: upgrade_owner.VerifiedTarget,
            primary_fd: c.fd_t,
            deadline: upgrade_deadline.Deadline,
        ) PreflightError!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.preflight_count += 1;
            if (c.fcntl(primary_fd, c.F.GETFD, @as(c_int, 0)) < 0 or deadline.expired())
                return error.InvalidTarget;
        }

        fn execute(ctx: *anyopaque, request_value: ExecuteRequest) ExecError!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.execute_count += 1;
            if (request_value.runtime_slots.len != 1 or
                request_value.runtime_slots[0].runtime_id == 0 or
                request_value.restore.role != .target or
                request_value.restore.attempt_id == 0)
                return error.ExecFailed;
            var buffers: entrypoint.RestoreArgBuffers = .{};
            const args = entrypoint.formatRestoreArgs(request_value.restore, &buffers) catch
                return error.ExecFailed;
            if ((entrypoint.parse(&args) catch return error.ExecFailed) != .restore)
                return error.ExecFailed;
            // Test executor intentionally returns: coordinator must treat this exactly like execv failure.
        }
    };
    var fake_authority: FakeAuthority = .{};
    var fake_executor: FakeExecutor = .{};
    var gate = @import("upgrade_coordinator.zig").AdmissionGate.init(std.testing.io);
    // Zig test protocol/cache fd는 exec fixture의 detached host와 달리 non-CLOEXEC일 수 있다. 이 test는 실제 exec를
    // 하지 않으므로 잠시 CLOEXEC로 바꿔 product의 baseline-empty gate를 그대로 통과시키고 종료 전에 exact 복구한다.
    var runner_fds: [exec_fd_set.max_slots]c.fd_t = undefined;
    const runner_fd_count = try exec_fd_set.collectNonCloexec(&runner_fds);
    for (runner_fds[0..runner_fd_count]) |fd| {
        const flags = c.fcntl(fd, c.F.GETFD, @as(c_int, 0));
        if (flags < 0 or c.fcntl(fd, c.F.SETFD, flags | c.FD_CLOEXEC) < 0)
            return error.SkipZigTest;
    }
    defer for (runner_fds[0..runner_fd_count]) |fd| {
        const flags = c.fcntl(fd, c.F.GETFD, @as(c_int, 0));
        if (flags >= 0) _ = c.fcntl(fd, c.F.SETFD, flags & ~@as(c_int, c.FD_CLOEXEC));
    };
    const layout = findAvailableLayout(40) orelse return error.SkipZigTest;
    const requested_slots = layout.requested().?;
    const context: Context = .{
        .allocator = allocator,
        .io = std.testing.io,
        .owner = &owner,
        .manager = &manager,
        .gate = &gate,
        .lifetime_owner = &lifetime_owner,
        .rollback_image = &rollback_authority,
        .authority = .{
            .ctx = &fake_authority,
            .snapshot = FakeAuthority.snapshot,
            .begin_restoring = FakeAuthority.begin,
            .rollback_ready = FakeAuthority.rollback,
            .fail_stop = FakeAuthority.failStop,
        },
        .executor = .{
            .ctx = &fake_executor,
            .preflight = FakeExecutor.preflight,
            .execute = FakeExecutor.execute,
        },
        .owner_dir = owner_dir,
        .session_dir = owner_dir,
        .socket_path = "/tmp/maru-0/sh/000000000000000000000000000000b2.sock",
        .layout = layout,
    };
    const outcome = if (cleanup_collision)
        processArmedWithDeadlineHooks(
            context,
            attempt_id,
            try upgrade_deadline.Deadline.after(std.testing.io, upgrade_limits.pause_budget_ns),
            false,
            null,
            replaceReservedPrimaryForFixture,
        )
    else
        processArmed(context, attempt_id);
    if (cleanup_collision) {
        try std.testing.expectEqual(Outcome.invariant_violation, outcome);
        const report = owner.status(attempt_id) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(upgrade_wire.AttemptStatus.resumed, report.status);
        try std.testing.expectEqual(upgrade_wire.AttemptReason.handoff_failed, report.reason);
        try std.testing.expectEqual(@as(usize, 0), fake_authority.begin_count);
        try std.testing.expectEqual(@as(usize, 0), fake_authority.rollback_count);
        try std.testing.expectEqual(@as(usize, 0), fake_executor.preflight_count);
        try std.testing.expectEqual(@as(usize, 0), fake_executor.execute_count);
    } else {
        const report = switch (outcome) {
            .terminal => |value| value,
            .not_armed, .invariant_violation => return error.TestUnexpectedResult,
        };
        try std.testing.expectEqual(upgrade_wire.AttemptStatus.resumed, report.status);
        try std.testing.expectEqual(upgrade_wire.AttemptReason.exec_failed, report.reason);
        try std.testing.expectEqual(@as(usize, 1), fake_authority.begin_count);
        try std.testing.expectEqual(@as(usize, 2), fake_authority.rollback_count);
        try std.testing.expectEqual(@as(usize, 1), fake_executor.preflight_count);
        try std.testing.expectEqual(@as(usize, 1), fake_executor.execute_count);
    }
    try std.testing.expect(gate.snapshot().open);
    try std.testing.expect(!manager.upgradeQuiesceReached());
    for (requested_slots) |slot| try std.testing.expect(!exec_fd_set.isOpen(slot));
    try runtime_ops.write_input(runtime_ops.ctx, runtime_id, "still-alive\n");
    var saw_output = false;
    var attempts: usize = 0;
    while (attempts < 200 and !saw_output) : (attempts += 1) {
        const snapshot = try runtime_ops.snapshot(runtime_ops.ctx, runtime_id, 0, allocator);
        defer allocator.free(snapshot.bytes);
        saw_output = try snapshotContainsText(allocator, snapshot.bytes, "still-alive");
        if (!saw_output) _ = usleep(10 * 1000);
    }
    try std.testing.expect(saw_output);
}

test "product coordinator uses one graph capture then rolls back exact slots and authority on exec return" {
    try runProductCoordinatorTest(false);
}

test "product coordinator cleanup identity failure overrides resumed report with invariant violation" {
    try runProductCoordinatorTest(true);
}
