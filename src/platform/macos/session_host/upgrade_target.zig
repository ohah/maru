//! `host.upgrade.prepare`가 승인할 실행 이미지를 요청 경로와 분리해 owner-only inode로 고정한다.
//!
//! UpgradeOwner는 OS syscall을 모르고 이 모듈의 vtable만 사용한다. 성공한 `VerifiedTarget.artifact.path`는 요청자가
//! 가리킨 bundle 경로가 아니라, exact attempt ID로 만든 immutable staged leaf다.

const std = @import("std");
const c = std.c;
const staged_image = @import("staged_image.zig");
const handoff_codec = @import("handoff_codec.zig");
const upgrade_owner = @import("upgrade_owner.zig");
const wire = @import("upgrade_wire.zig");

pub const Stager = struct {
    owner_dir: [:0]const u8,

    pub fn ops(self: *Stager) upgrade_owner.TargetStager {
        return .{
            .ctx = self,
            .stage = stageOpaque,
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

    fn releaseArtifactOpaque(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        artifact: *upgrade_owner.StagedArtifact,
    ) void {
        if (artifact.exec_fd >= 0) _ = c.close(artifact.exec_fd);
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
        staged.deinit();
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
    var stager = Stager{ .owner_dir = dir };
    const ops = stager.ops();
    const request: wire.PrepareRequest = .{
        .attempt_id = 0xA1,
        .target_path = source,
        .target_build_id = build_id,
        .target_sha256 = identity.sha256,
        .handoff_reader_min = handoff_codec.reader_min,
        .handoff_reader_max = handoff_codec.reader_max,
    };
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
    var stager = Stager{ .owner_dir = dir };
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

    var stager = Stager{ .owner_dir = dir };
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
    try std.testing.expect(c.fcntl(execution.target.artifact.exec_fd, c.F.GETFD, @as(c_int, 0)) >= 0);
    try std.testing.expect(owner.revalidateExecution(execution));
    try std.testing.expect(owner.finish(completed.attempt_id, .{ .status = .committed }));
    var completed_path_buf: [272]u8 = undefined;
    const completed_path = try std.fmt.bufPrintZ(
        &completed_path_buf,
        "{s}/target-{x:0>32}.image",
        .{ dir, completed.attempt_id },
    );
    try std.testing.expect(c.access(completed_path.ptr, c.F_OK) != 0);
    const replay = owner.stagePending(completed);
    try std.testing.expect(replay == .completed);
    try std.testing.expectEqual(wire.AttemptStatus.committed, replay.completed.status);
}
