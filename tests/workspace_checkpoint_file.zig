//! P4 C2는 capture가 만든 전체 manifest 하나를 이전 완전본을 깨뜨리지 않고 게시하는 파일 경계다.

const std = @import("std");
const checkpoint_file = @import("workspace_checkpoint_file");

const FakeBackend = struct {
    const Error = error{Injected};

    fail_index: ?usize = null,
    call_index: usize = 0,
    write_limit: usize = std.math.maxInt(usize),
    old: []const u8 = "old-complete",
    temp: [64]u8 = undefined,
    temp_len: usize = 0,
    final: [64]u8 = undefined,
    final_len: usize = 0,
    temp_open: bool = false,
    parent_open: bool = false,

    fn init(fail_index: ?usize, write_limit: usize) FakeBackend {
        var self: FakeBackend = .{ .fail_index = fail_index, .write_limit = write_limit };
        @memcpy(self.final[0..self.old.len], self.old);
        self.final_len = self.old.len;
        return self;
    }

    fn step(self: *FakeBackend) Error!void {
        self.call_index += 1;
        if (self.fail_index == self.call_index) return error.Injected;
    }

    pub fn openParent(self: *FakeBackend) Error!void {
        try self.step();
        self.parent_open = true;
    }

    pub fn removeStale(self: *FakeBackend) Error!void {
        try self.step();
        self.temp_len = 0;
    }

    pub fn createTemp(self: *FakeBackend) Error!void {
        try self.step();
        self.temp_open = true;
        self.temp_len = 0;
    }

    pub fn chmodTemp(self: *FakeBackend) Error!void {
        try self.step();
    }

    pub fn writeTemp(self: *FakeBackend, bytes: []const u8) Error!usize {
        try self.step();
        const count = @min(bytes.len, self.write_limit);
        @memcpy(self.temp[self.temp_len..][0..count], bytes[0..count]);
        self.temp_len += count;
        return count;
    }

    pub fn closeTemp(self: *FakeBackend) Error!void {
        const result = self.step();
        self.temp_open = false;
        try result;
    }

    pub fn replace(self: *FakeBackend) Error!void {
        try self.step();
        @memcpy(self.final[0..self.temp_len], self.temp[0..self.temp_len]);
        self.final_len = self.temp_len;
        self.temp_len = 0;
    }

    pub fn cleanupTemp(self: *FakeBackend) void {
        self.temp_open = false;
        self.temp_len = 0;
    }

    pub fn closeParent(self: *FakeBackend) void {
        self.parent_open = false;
    }

    fn finalBytes(self: *const FakeBackend) []const u8 {
        return self.final[0..self.final_len];
    }
};

test "P4 C2 every syscall fail-index preserves the previous complete manifest" {
    const snapshot = "new-complete-manifest";
    var probe = FakeBackend.init(null, 3);
    try std.testing.expectEqual(checkpoint_file.Result.committed, checkpoint_file.testing.publishUsingForTest(&probe, snapshot));
    const operation_count = probe.call_index;
    try std.testing.expect(operation_count > 7);
    try std.testing.expectEqualStrings(snapshot, probe.finalBytes());

    for (1..operation_count + 1) |fail_index| {
        var backend = FakeBackend.init(fail_index, 3);
        try std.testing.expect(checkpoint_file.testing.publishUsingForTest(&backend, snapshot) != .committed);
        try std.testing.expectEqualStrings("old-complete", backend.finalBytes());
        try std.testing.expectEqual(@as(usize, 0), backend.temp_len);
        try std.testing.expect(!backend.temp_open);
        try std.testing.expect(!backend.parent_open);
    }
}

test "P4 C2 rejects an empty snapshot before filesystem mutation" {
    var backend = FakeBackend.init(null, 3);
    try std.testing.expectEqual(checkpoint_file.Result.invalid_snapshot, checkpoint_file.testing.publishUsingForTest(&backend, ""));
    try std.testing.expectEqual(@as(usize, 0), backend.call_index);
    try std.testing.expectEqualStrings("old-complete", backend.finalBytes());
}

test "P4 C2 typed results identify the failed publication phase" {
    const expected = [_]checkpoint_file.Result{
        .open_parent_failed,
        .remove_stale_failed,
        .create_temp_failed,
        .chmod_failed,
        .write_failed,
        .close_failed,
        .replace_failed,
    };
    for (expected, 1..) |result, fail_index| {
        var backend = FakeBackend.init(fail_index, 64);
        try std.testing.expectEqual(result, checkpoint_file.testing.publishUsingForTest(&backend, "new"));
    }
}

fn tempParentPath(tmp: *std.testing.TmpDir, out: *[std.fs.max_path_bytes:0]u8) ![:0]const u8 {
    var resolved: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &resolved);
    return std.fmt.bufPrintZ(out, "{s}", .{resolved[0..len]});
}

fn readLeaf(tmp: *std.testing.TmpDir, leaf: []const u8, out: []u8) ![]const u8 {
    const file = try tmp.dir.openFile(std.testing.io, leaf, .{});
    defer file.close(std.testing.io);
    const count = try file.readPositionalAll(std.testing.io, out, 0);
    return out[0..count];
}

test "P4 C2 product adapter publishes one complete 0600 file and removes stale temp" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "workspace.v1", .data = "old-complete" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".workspace.v1.tmp", .data = "stale-prefix" });
    var parent_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const parent = try tempParentPath(&tmp, &parent_buf);

    try std.testing.expectEqual(checkpoint_file.Result.committed, checkpoint_file.publish(parent, "new-complete"));
    var read_buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("new-complete", try readLeaf(&tmp, "workspace.v1", &read_buf));
    const stat = try tmp.dir.statFile(std.testing.io, "workspace.v1", .{});
    try std.testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(stat.permissions.toMode() & 0o777)));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, ".workspace.v1.tmp", .{}));

    // stale temp가 symlink여도 target을 따라 쓰지 않고 link 자체만 회수한다.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "victim", .data = "do-not-touch" });
    try tmp.dir.symLink(std.testing.io, "victim", ".workspace.v1.tmp", .{});
    try std.testing.expectEqual(checkpoint_file.Result.committed, checkpoint_file.publish(parent, "third-complete"));
    try std.testing.expectEqualStrings("do-not-touch", try readLeaf(&tmp, "victim", &read_buf));
    try std.testing.expectEqualStrings("third-complete", try readLeaf(&tmp, "workspace.v1", &read_buf));
}

const Pause = struct {
    ready_fd: std.c.fd_t,
    release_fd: std.c.fd_t,
    phase: checkpoint_file.testing.Phase,
};

fn pauseAt(context: ?*anyopaque, phase: checkpoint_file.testing.Phase) void {
    const pause: *Pause = @ptrCast(@alignCast(context.?));
    if (phase != pause.phase) return;
    const byte = [_]u8{1};
    _ = std.c.write(pause.ready_fd, &byte, byte.len);
    var release: [1]u8 = undefined;
    _ = std.c.read(pause.release_fd, &release, release.len);
}

fn waitOne(fd: std.c.fd_t) !void {
    var byte: [1]u8 = undefined;
    if (std.c.read(fd, &byte, byte.len) != 1) return error.ReadFailed;
}

fn crashAtPhase(tmp: *std.testing.TmpDir, parent: [:0]const u8, phase: checkpoint_file.testing.Phase) !void {
    var ready: [2]std.c.fd_t = undefined;
    var release: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&ready) != 0 or std.c.pipe(&release) != 0) return error.PipeFailed;
    const child = std.c.fork();
    if (child < 0) return error.ForkFailed;
    if (child == 0) {
        _ = std.c.close(ready[0]);
        _ = std.c.close(release[1]);
        var pause: Pause = .{ .ready_fd = ready[1], .release_fd = release[0], .phase = phase };
        const result = checkpoint_file.testing.publishObservedForTest(parent, "new-complete", .{
            .context = &pause,
            .callback = pauseAt,
        });
        std.c._exit(if (result == .committed) 0 else 3);
    }
    _ = std.c.close(ready[1]);
    _ = std.c.close(release[0]);
    defer _ = std.c.close(ready[0]);
    defer _ = std.c.close(release[1]);
    try waitOne(ready[0]);
    if (std.c.kill(child, std.c.SIG.KILL) != 0) return error.KillFailed;
    var status: c_int = undefined;
    if (std.c.waitpid(child, &status, 0) != child) return error.WaitFailed;
    const unsigned: c_uint = @bitCast(status);
    if (!std.c.W.IFSIGNALED(unsigned) or std.c.W.TERMSIG(unsigned) != std.c.SIG.KILL)
        return error.ChildWasNotKilledAtCheckpoint;
    _ = tmp;
}

test "P4 C2 SIGKILL before rename preserves old complete and next publish reclaims temp" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "workspace.v1", .data = "old-complete" });
    var parent_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const parent = try tempParentPath(&tmp, &parent_buf);
    try crashAtPhase(&tmp, parent, .temp_closed);

    var read_buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("old-complete", try readLeaf(&tmp, "workspace.v1", &read_buf));
    _ = try tmp.dir.statFile(std.testing.io, ".workspace.v1.tmp", .{});
    try std.testing.expectEqual(checkpoint_file.Result.committed, checkpoint_file.publish(parent, "after-crash"));
    try std.testing.expectEqualStrings("after-crash", try readLeaf(&tmp, "workspace.v1", &read_buf));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, ".workspace.v1.tmp", .{}));
}

test "P4 C2 SIGKILL after rename leaves only the new complete manifest" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "workspace.v1", .data = "old-complete" });
    var parent_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const parent = try tempParentPath(&tmp, &parent_buf);
    try crashAtPhase(&tmp, parent, .replaced);

    var read_buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("new-complete", try readLeaf(&tmp, "workspace.v1", &read_buf));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, ".workspace.v1.tmp", .{}));
}
