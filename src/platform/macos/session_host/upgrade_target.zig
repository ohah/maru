//! `host.upgrade.prepare`가 승인할 실행 이미지를 요청 경로와 분리해 owner-only inode로 고정한다.
//!
//! UpgradeOwner는 OS syscall을 모르고 이 모듈의 vtable만 사용한다. 성공한 `VerifiedTarget.artifact.path`는 요청자가
//! 가리킨 bundle 경로가 아니라, exact attempt ID로 만든 immutable staged leaf다.

const std = @import("std");
const c = std.c;
const posix = std.posix;
const staged_image = @import("staged_image.zig");
const handoff_codec = @import("handoff_codec.zig");
const upgrade_owner = @import("upgrade_owner.zig");
const attempt_record = @import("upgrade_attempt_record.zig");
const wire = @import("upgrade_wire.zig");

pub const Authorizer = struct {
    ctx: *anyopaque,
    allowed: *const fn (ctx: *anyopaque, staged_path: [:0]const u8) bool,
};

pub const Stager = struct {
    owner_dir: [:0]const u8,
    authorizer: Authorizer,

    pub fn ops(self: *Stager) upgrade_owner.TargetStager {
        return .{
            .ctx = self,
            .stage = stageOpaque,
            .restore = restoreOpaque,
            .release_artifact = releaseArtifactOpaque,
            .verify = verifyOpaque,
        };
    }

    fn stageOpaque(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        request: wire.PrepareRequest,
    ) upgrade_owner.StageDecision {
        const self: *Stager = @ptrCast(@alignCast(ctx));
        if (request.handoff_reader_min > handoff_codec.schema_v1 or
            request.handoff_reader_max < handoff_codec.schema_v1)
            return .unsupported;

        const source = allocator.dupeZ(u8, request.target_path) catch return .resource_exhausted;
        defer allocator.free(source);
        var leaf_buf: [80]u8 = undefined;
        const leaf = std.fmt.bufPrint(&leaf_buf, "target-{x:0>32}.image", .{request.attempt_id}) catch
            return .resource_exhausted;
        var staged = staged_image.stageExclusive(allocator, source, self.owner_dir, leaf) catch |err| return switch (err) {
            error.OutOfMemory, error.StorageUnavailable, error.InvalidDirectory => .resource_exhausted,
            else => .invalid_target,
        };

        if (!std.mem.eql(u8, &staged.identity.sha256, &request.target_sha256) or
            !buildIdMatches(request.target_build_id, staged.identity.sha256))
        {
            staged.deinit();
            return .invalid_target;
        }
        if (!self.authorizer.allowed(self.authorizer.ctx, staged.path)) {
            staged.deinit();
            return .invalid_target;
        }
        const build_id = allocator.dupe(u8, request.target_build_id) catch {
            staged.deinit();
            return .resource_exhausted;
        };
        const exec_fd = c.open(
            staged.path.ptr,
            .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true },
            @as(c.mode_t, 0),
        );
        if (exec_fd < 0) {
            allocator.free(build_id);
            staged.deinit();
            return .resource_exhausted;
        }
        const pinned_identity = staged_image.inspectFd(exec_fd) catch {
            _ = c.close(exec_fd);
            allocator.free(build_id);
            staged.deinit();
            return .invalid_target;
        };
        if (!staged_image.identityEqual(staged.identity, pinned_identity)) {
            _ = c.close(exec_fd);
            allocator.free(build_id);
            staged.deinit();
            return .invalid_target;
        }
        const result: upgrade_owner.VerifiedTarget = .{
            .artifact = .{
                .path = staged.path,
                .exec_fd = exec_fd,
                .sha256 = staged.identity.sha256,
                .dev = staged.identity.dev,
                .ino = staged.identity.ino,
                .size = staged.identity.size,
            },
            .build_id = build_id,
            .reader_min = request.handoff_reader_min,
            .reader_max = request.handoff_reader_max,
        };
        staged = undefined; // path ownership moved to VerifiedTarget/releaseArtifactOpaque.
        return .{ .verified = result };
    }

    fn restoreOpaque(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        recorded: upgrade_owner.RecordedTarget,
    ) upgrade_owner.StageDecision {
        if (recorded.reader_min == 0 or recorded.reader_min > handoff_codec.schema_v1 or
            recorded.reader_max < handoff_codec.schema_v1 or
            !buildIdMatches(recorded.build_id, recorded.sha256))
            return .invalid_target;
        const path = allocator.dupeZ(u8, recorded.staged_path) catch return .resource_exhausted;
        var path_owned = true;
        defer if (path_owned) allocator.free(path);
        const build_id = allocator.dupe(u8, recorded.build_id) catch return .resource_exhausted;
        var build_owned = true;
        defer if (build_owned) allocator.free(build_id);
        const exec_fd = c.open(
            path.ptr,
            .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true },
            @as(c.mode_t, 0),
        );
        if (exec_fd < 0) return .invalid_target;
        var fd_owned = true;
        defer if (fd_owned) {
            _ = c.close(exec_fd);
        };
        const actual = staged_image.inspectFd(exec_fd) catch return .invalid_target;
        const expected: staged_image.Identity = .{
            .dev = recorded.dev,
            .ino = recorded.ino,
            .size = recorded.size,
            .sha256 = recorded.sha256,
        };
        if (!staged_image.identityEqual(expected, actual)) return .invalid_target;
        const path_identity = staged_image.inspect(path) catch return .invalid_target;
        if (!staged_image.identityEqual(expected, path_identity)) return .invalid_target;
        path_owned = false;
        build_owned = false;
        fd_owned = false;
        return .{ .verified = .{
            .artifact = .{
                .path = path,
                .exec_fd = exec_fd,
                .sha256 = actual.sha256,
                .dev = actual.dev,
                .ino = actual.ino,
                .size = actual.size,
            },
            .build_id = build_id,
            .reader_min = recorded.reader_min,
            .reader_max = recorded.reader_max,
        } };
    }

    fn releaseArtifactOpaque(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        artifact: *upgrade_owner.StagedArtifact,
    ) void {
        const exec_fd = artifact.exec_fd;
        var staged: staged_image.StagedImage = .{
            .allocator = allocator,
            .path = artifact.path,
            .identity = .{
                .dev = artifact.dev,
                .ino = artifact.ino,
                .size = artifact.size,
                .sha256 = artifact.sha256,
            },
        };
        // Tomb의 dev/ino를 대조해 제거할 때까지 pinned fd를 열어 둔다. 먼저 닫으면 unlink된 inode 번호가 재사용돼
        // replacement generation을 같은 object로 오인할 수 있다.
        staged.deinit();
        if (exec_fd >= 0) _ = c.close(exec_fd);
        artifact.* = undefined;
    }

    fn verifyOpaque(_: *anyopaque, target: upgrade_owner.VerifiedTarget) bool {
        const expected: staged_image.Identity = .{
            .dev = target.artifact.dev,
            .ino = target.artifact.ino,
            .size = target.artifact.size,
            .sha256 = target.artifact.sha256,
        };
        const pinned = staged_image.inspectFd(target.artifact.exec_fd) catch return false;
        if (!staged_image.identityEqual(expected, pinned)) return false;
        const path = staged_image.inspect(target.artifact.path) catch return false;
        return staged_image.identityEqual(expected, path);
    }
};

fn buildIdMatches(build_id: []const u8, digest: [32]u8) bool {
    if (build_id.len != "sha256:".len + 64 or !std.mem.startsWith(u8, build_id, "sha256:")) return false;
    const expected = std.fmt.bytesToHex(digest, .lower);
    return std.mem.eql(u8, build_id["sha256:".len..], &expected);
}

fn testAuthorizer() Authorizer {
    return .{
        .ctx = @ptrFromInt(1),
        .allowed = struct {
            fn allowed(_: *anyopaque, _: [:0]const u8) bool {
                return true;
            }
        }.allowed,
    };
}

fn rejectingAuthorizer() Authorizer {
    return .{
        .ctx = @ptrFromInt(1),
        .allowed = struct {
            fn allowed(_: *anyopaque, _: [:0]const u8) bool {
                return false;
            }
        }.allowed,
    };
}

fn writeFixture(path: [:0]const u8, bytes: []const u8, mode: c.mode_t) !void {
    const fd = c.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, mode);
    if (fd < 0) return error.TestUnexpectedResult;
    defer _ = c.close(fd);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = c.write(fd, bytes.ptr + offset, bytes.len - offset);
        if (n <= 0) return error.TestUnexpectedResult;
        offset += @intCast(n);
    }
}

test "upgrade target stages an exact executable inode and cancellation removes it" {
    var dir_buf: [192]u8 = undefined;
    const dir = std.fmt.bufPrintZ(&dir_buf, "/tmp/maru-upgrade-target-{d}", .{c.getpid()}) catch
        return error.SkipZigTest;
    if (c.mkdir(dir.ptr, 0o700) != 0) return error.SkipZigTest;
    defer _ = c.rmdir(dir.ptr);
    var source_buf: [224]u8 = undefined;
    const source = try std.fmt.bufPrintZ(&source_buf, "{s}/source", .{dir});
    defer _ = c.unlink(source.ptr);
    try writeFixture(source, "new-image", 0o700);
    const identity = try staged_image.inspect(source);
    const hex = std.fmt.bytesToHex(identity.sha256, .lower);
    var build_buf: [71]u8 = undefined;
    const build_id = try std.fmt.bufPrint(&build_buf, "sha256:{s}", .{&hex});
    var stager = Stager{ .owner_dir = dir, .authorizer = testAuthorizer() };
    const ops = stager.ops();
    const request: wire.PrepareRequest = .{
        .attempt_id = 0xA1,
        .target_path = source,
        .target_build_id = build_id,
        .target_sha256 = identity.sha256,
        .handoff_reader_min = handoff_codec.reader_min,
        .handoff_reader_max = handoff_codec.reader_max,
    };
    var rejecting = Stager{ .owner_dir = dir, .authorizer = rejectingAuthorizer() };
    const rejecting_ops = rejecting.ops();
    try std.testing.expect(
        rejecting_ops.stage(rejecting_ops.ctx, std.testing.allocator, request) == .invalid_target,
    );
    const decision = ops.stage(ops.ctx, std.testing.allocator, request);
    try std.testing.expect(decision == .verified);
    var target = decision.verified;
    defer std.testing.allocator.free(target.build_id);
    try std.testing.expect(!std.mem.eql(u8, target.artifact.path, source));
    try std.testing.expect(staged_image.identityEqual(.{
        .dev = target.artifact.dev,
        .ino = target.artifact.ino,
        .size = target.artifact.size,
        .sha256 = target.artifact.sha256,
    }, try staged_image.inspect(target.artifact.path)));
    try std.testing.expect(std.mem.eql(u8, &identity.sha256, &target.artifact.sha256));
    // A stale or concurrently published leaf for this attempt is never overwritten.
    try std.testing.expect(ops.stage(ops.ctx, std.testing.allocator, request) == .resource_exhausted);
    try std.testing.expect(staged_image.identityEqual(.{
        .dev = target.artifact.dev,
        .ino = target.artifact.ino,
        .size = target.artifact.size,
        .sha256 = target.artifact.sha256,
    }, try staged_image.inspect(target.artifact.path)));
    const owned_path = try std.testing.allocator.dupeZ(u8, target.artifact.path);
    defer std.testing.allocator.free(owned_path);
    ops.release_artifact(ops.ctx, std.testing.allocator, &target.artifact);
    try std.testing.expect(c.access(owned_path.ptr, c.F_OK) != 0);
}

test "upgrade target rejects hash build reader and executable mismatches without residue" {
    var dir_buf: [192]u8 = undefined;
    const dir = std.fmt.bufPrintZ(&dir_buf, "/tmp/maru-upgrade-target-invalid-{d}", .{c.getpid()}) catch
        return error.SkipZigTest;
    if (c.mkdir(dir.ptr, 0o700) != 0) return error.SkipZigTest;
    defer _ = c.rmdir(dir.ptr);
    var source_buf: [224]u8 = undefined;
    const source = try std.fmt.bufPrintZ(&source_buf, "{s}/source", .{dir});
    defer _ = c.unlink(source.ptr);
    try writeFixture(source, "new-image", 0o700);
    const identity = try staged_image.inspect(source);
    const hex = std.fmt.bytesToHex(identity.sha256, .lower);
    var build_buf: [71]u8 = undefined;
    const build_id = try std.fmt.bufPrint(&build_buf, "sha256:{s}", .{&hex});
    var stager = Stager{ .owner_dir = dir, .authorizer = testAuthorizer() };
    const ops = stager.ops();

    var bad_hash = identity.sha256;
    bad_hash[0] ^= 0xFF;
    try std.testing.expect(ops.stage(ops.ctx, std.testing.allocator, .{
        .attempt_id = 1,
        .target_path = source,
        .target_build_id = build_id,
        .target_sha256 = bad_hash,
        .handoff_reader_min = 1,
        .handoff_reader_max = 1,
    }) == .invalid_target);
    try std.testing.expect(ops.stage(ops.ctx, std.testing.allocator, .{
        .attempt_id = 2,
        .target_path = source,
        .target_build_id = "sha256:not-the-image",
        .target_sha256 = identity.sha256,
        .handoff_reader_min = 1,
        .handoff_reader_max = 1,
    }) == .invalid_target);
    try std.testing.expect(ops.stage(ops.ctx, std.testing.allocator, .{
        .attempt_id = 3,
        .target_path = source,
        .target_build_id = build_id,
        .target_sha256 = identity.sha256,
        .handoff_reader_min = handoff_codec.schema_v1 + 1,
        .handoff_reader_max = handoff_codec.schema_v1 + 1,
    }) == .unsupported);

    _ = c.chmod(source.ptr, 0o600);
    try std.testing.expect(ops.stage(ops.ctx, std.testing.allocator, .{
        .attempt_id = 4,
        .target_path = source,
        .target_build_id = build_id,
        .target_sha256 = identity.sha256,
        .handoff_reader_min = 1,
        .handoff_reader_max = 1,
    }) == .invalid_target);
}

test "real target stager and upgrade owner release cancel and terminal artifacts" {
    var dir_buf: [192]u8 = undefined;
    const dir = std.fmt.bufPrintZ(&dir_buf, "/tmp/maru-upgrade-owner-real-{d}", .{c.getpid()}) catch
        return error.SkipZigTest;
    if (c.mkdir(dir.ptr, 0o700) != 0) return error.SkipZigTest;
    defer _ = c.rmdir(dir.ptr);
    var source_buf: [224]u8 = undefined;
    const source = try std.fmt.bufPrintZ(&source_buf, "{s}/source", .{dir});
    defer _ = c.unlink(source.ptr);
    try writeFixture(source, "real-owner-image", 0o700);
    const identity = try staged_image.inspect(source);
    const hex = std.fmt.bytesToHex(identity.sha256, .lower);
    var build_buf: [71]u8 = undefined;
    const build_id = try std.fmt.bufPrint(&build_buf, "sha256:{s}", .{&hex});

    var stager = Stager{ .owner_dir = dir, .authorizer = testAuthorizer() };
    var owner = upgrade_owner.UpgradeOwner.init(std.testing.allocator, stager.ops(), null);
    defer owner.deinit(); // Stager must outlive UpgradeOwner; init contract documents this borrowed ctx.
    const cancelled: wire.PrepareRequest = .{
        .attempt_id = 0x31,
        .target_path = source,
        .target_build_id = build_id,
        .target_sha256 = identity.sha256,
        .handoff_reader_min = 1,
        .handoff_reader_max = 1,
    };
    try std.testing.expectEqual(wire.PrepareDecision.accepted, owner.stagePending(cancelled));
    owner.cancelUnaccepted(cancelled.attempt_id);
    var cancelled_path_buf: [272]u8 = undefined;
    const cancelled_path = try std.fmt.bufPrintZ(
        &cancelled_path_buf,
        "{s}/target-{x:0>32}.image",
        .{ dir, cancelled.attempt_id },
    );
    try std.testing.expect(c.access(cancelled_path.ptr, c.F_OK) != 0);

    var completed = cancelled;
    completed.attempt_id = 0x32;
    try std.testing.expectEqual(wire.PrepareDecision.accepted, owner.stagePending(completed));
    try std.testing.expectEqual(wire.ArmDecision.armed, owner.armAccepted(completed.attempt_id));
    const execution = owner.beginExecution(completed.attempt_id).?;
    const borrowed_exec_fd = execution.target.artifact.exec_fd;
    try std.testing.expect(c.fcntl(borrowed_exec_fd, c.F.GETFD, @as(c_int, 0)) >= 0);
    try std.testing.expect(owner.revalidateExecution(execution));
    try std.testing.expect(owner.finish(completed.attempt_id, .{
        .status = .resumed,
        .reason = .exec_failed,
    }));
    try std.testing.expect(c.fcntl(borrowed_exec_fd, c.F.GETFD, @as(c_int, 0)) < 0);
    try std.testing.expectEqual(posix.E.BADF, posix.errno(-1));
    var completed_path_buf: [272]u8 = undefined;
    const completed_path = try std.fmt.bufPrintZ(
        &completed_path_buf,
        "{s}/target-{x:0>32}.image",
        .{ dir, completed.attempt_id },
    );
    try std.testing.expect(c.access(completed_path.ptr, c.F_OK) != 0);
    const replay = owner.stagePending(completed);
    try std.testing.expect(replay == .completed);
    try std.testing.expectEqual(wire.AttemptStatus.resumed, replay.completed.status);
}

test "real target restore reopens a CLOEXEC pin and terminal finish closes it exactly once" {
    var dir_buf: [192]u8 = undefined;
    const dir = std.fmt.bufPrintZ(&dir_buf, "/tmp/maru-upgrade-target-restore-{d}", .{c.getpid()}) catch
        return error.SkipZigTest;
    if (c.mkdir(dir.ptr, 0o700) != 0) return error.SkipZigTest;
    defer _ = c.rmdir(dir.ptr);
    var source_buf: [224]u8 = undefined;
    const source = try std.fmt.bufPrintZ(&source_buf, "{s}/source", .{dir});
    defer _ = c.unlink(source.ptr);
    try writeFixture(source, "restore-image", 0o700);
    const identity = try staged_image.inspect(source);
    const hex = std.fmt.bytesToHex(identity.sha256, .lower);
    var build_buf: [71]u8 = undefined;
    const build_id = try std.fmt.bufPrint(&build_buf, "sha256:{s}", .{&hex});
    var stager = Stager{ .owner_dir = dir, .authorizer = testAuthorizer() };
    var old = upgrade_owner.UpgradeOwner.init(std.testing.allocator, stager.ops(), null);
    defer old.deinit();
    const request: wire.PrepareRequest = .{
        .attempt_id = 0x41,
        .target_path = source,
        .target_build_id = build_id,
        .target_sha256 = identity.sha256,
        .handoff_reader_min = 1,
        .handoff_reader_max = 1,
    };
    try std.testing.expectEqual(wire.PrepareDecision.accepted, old.stagePending(request));
    try std.testing.expectEqual(wire.ArmDecision.armed, old.armAccepted(request.attempt_id));
    const execution = old.beginExecution(request.attempt_id).?;
    const record_bytes = try old.encodeRunningRecord(std.testing.allocator, execution, 0xAA, 2, &.{});
    defer std.testing.allocator.free(record_bytes);
    var state = try attempt_record.decode(std.testing.allocator, record_bytes);
    defer state.deinit();

    var restored = upgrade_owner.UpgradeOwner.init(std.testing.allocator, stager.ops(), null);
    defer restored.deinit();
    try restored.restoreRunningRecord(state, .{
        .host_id = 0xAA,
        .host_epoch = 2,
        .runtime_ids = &.{},
        .token = upgrade_owner.validateRestoreEntry(
            state,
            "target",
            "00000000000000000000000000000041",
            .primary,
        ).?,
    });
    const restored_execution = restored.runningExecution(request.attempt_id) orelse
        return error.TestUnexpectedResult;
    const restored_fd = restored_execution.target.artifact.exec_fd;
    try std.testing.expect(restored_fd >= 3);
    try std.testing.expect(c.fcntl(restored_fd, c.F.GETFD, @as(c_int, 0)) & c.FD_CLOEXEC != 0);
    try std.testing.expect(restored.finish(request.attempt_id, .{ .status = .committed }));
    try std.testing.expect(c.fcntl(restored_fd, c.F.GETFD, @as(c_int, 0)) < 0);
    try std.testing.expectEqual(posix.E.BADF, posix.errno(-1));
    var staged_buf: [272]u8 = undefined;
    const staged_path = try std.fmt.bufPrintZ(
        &staged_buf,
        "{s}/target-{x:0>32}.image",
        .{ dir, request.attempt_id },
    );
    try std.testing.expect(c.access(staged_path.ptr, c.F_OK) != 0);
}

test "pinned target fd keeps the approved inode while path replacement is rejected and preserved" {
    var dir_buf: [192]u8 = undefined;
    const dir = std.fmt.bufPrintZ(&dir_buf, "/tmp/maru-upgrade-target-swap-{d}", .{c.getpid()}) catch
        return error.SkipZigTest;
    if (c.mkdir(dir.ptr, 0o700) != 0) return error.SkipZigTest;
    defer _ = c.rmdir(dir.ptr);
    var source_buf: [224]u8 = undefined;
    const source = try std.fmt.bufPrintZ(&source_buf, "{s}/source", .{dir});
    defer _ = c.unlink(source.ptr);
    try writeFixture(source, "approved-image", 0o700);
    const identity = try staged_image.inspect(source);
    const hex = std.fmt.bytesToHex(identity.sha256, .lower);
    var build_buf: [71]u8 = undefined;
    const build_id = try std.fmt.bufPrint(&build_buf, "sha256:{s}", .{&hex});
    var stager = Stager{ .owner_dir = dir, .authorizer = testAuthorizer() };
    const ops = stager.ops();
    const decision = ops.stage(ops.ctx, std.testing.allocator, .{
        .attempt_id = 0x41,
        .target_path = source,
        .target_build_id = build_id,
        .target_sha256 = identity.sha256,
        .handoff_reader_min = 1,
        .handoff_reader_max = 1,
    });
    try std.testing.expect(decision == .verified);
    var target = decision.verified;
    defer std.testing.allocator.free(target.build_id);
    const staged_path = try std.testing.allocator.dupeZ(u8, target.artifact.path);
    defer std.testing.allocator.free(staged_path);
    var approved_buf: [272]u8 = undefined;
    const approved_path = try std.fmt.bufPrintZ(&approved_buf, "{s}.approved", .{staged_path});
    defer _ = c.unlink(approved_path.ptr);
    defer _ = c.unlink(staged_path.ptr);

    try std.testing.expect(c.rename(staged_path.ptr, approved_path.ptr) == 0);
    try writeFixture(staged_path, "replacement-image", 0o700);
    const pinned = try staged_image.inspectFd(target.artifact.exec_fd);
    try std.testing.expectEqual(target.artifact.ino, pinned.ino);
    try std.testing.expect(!ops.verify(ops.ctx, target));
    ops.release_artifact(ops.ctx, std.testing.allocator, &target.artifact);
    try std.testing.expect(c.access(staged_path.ptr, c.F_OK) == 0);
}
