//! 실제 hdiutil read-only mount에서 고정 Maru.app 경로를 열고 device identity로 detach하는지 검증한다.
//!
//! 서명 의미는 앞선 Apple transport gate가 소유하므로 이 fixture는 command output만 대체하고 mount/filesystem은 실제다.

const std = @import("std");
const builtin = @import("builtin");
const authority = @import("release_adapter_dmg_authority");
const apple_transport = @import("release_adapter_apple_transport");

const FakeApple = struct {
    call: usize = 0,
    fail_at: ?usize = null,

    pub fn capture(self: *@This(), _: []const u8, _: []const []const u8, environment: []const []const u8, output: []u8, _: i128) ![]const u8 {
        try std.testing.expectEqual(@as(usize, 0), environment.len);
        if (self.fail_at == self.call) return error.ChildFailed;
        const captures = [_][]const u8{
            "{\"CFBundleIdentifier\":\"dev.maru.apphost\",\"CFBundleShortVersionString\":\"1.2.3\",\"CFBundleVersion\":\"1\"}",
            "Identifier=dev.maru.apphost\nTeamIdentifier=ABCDEFGHIJ\n",
            "designated => identifier \"dev.maru.apphost\" and anchor apple generic and certificate leaf[subject.OU] = \"ABCDEFGHIJ\"\n",
            "arm64 x86_64\n",
            "",
            "",
            "",
            "",
        };
        const value = captures[self.call];
        self.call += 1;
        @memcpy(output[0..value.len], value);
        return output[0..value.len];
    }
};

test "actual DMG authority mounts read-only fixed product and leaves zero residue" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const candidate_raw = std.c.getenv("MARU_DMG_AUTHORITY_CANDIDATE") orelse return error.SkipZigTest;
    const work_root_raw = std.c.getenv("MARU_DMG_AUTHORITY_WORK") orelse return error.SkipZigTest;
    const size_raw = std.c.getenv("MARU_DMG_AUTHORITY_SIZE") orelse return error.SkipZigTest;
    const sha_raw = std.c.getenv("MARU_DMG_AUTHORITY_SHA256") orelse return error.SkipZigTest;
    const candidate = std.mem.span(candidate_raw);
    const work_root = std.mem.span(work_root_raw);
    const sha = std.mem.span(sha_raw);
    if (sha.len != 64) return error.TestUnexpectedResult;
    var expected_sha: [64]u8 = undefined;
    @memcpy(&expected_sha, sha);
    var candidate_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const candidate_z = try std.fmt.bufPrintZ(&candidate_buf, "{s}", .{candidate});
    const expected = authority.ExpectedDmg{
        .size = try std.fmt.parseInt(u64, std.mem.span(size_raw), 10),
        .sha256 = expected_sha,
    };
    for ([_]?usize{ null, 3 }) |fail_at| {
        var work_buf: [std.fs.max_path_bytes:0]u8 = undefined;
        const work_z = try std.fmt.bufPrintZ(&work_buf, "{s}-{s}", .{ work_root, if (fail_at == null) "success" else "failure" });
        var fake = FakeApple{ .fail_at = fail_at };
        var storage: apple_transport.Storage = undefined;
        if (fail_at == null) {
            var observed = try authority.observeWithAppleRunnerForTest(
                std.testing.allocator,
                std.testing.io,
                &fake,
                candidate_z,
                work_z,
                expected,
                "1.2.3",
                &storage,
                30 * std.time.ns_per_s,
            );
            observed.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(usize, 8), fake.call);
        } else {
            try std.testing.expectError(error.ChildFailed, authority.observeWithAppleRunnerForTest(
                std.testing.allocator,
                std.testing.io,
                &fake,
                candidate_z,
                work_z,
                expected,
                "1.2.3",
                &storage,
                30 * std.time.ns_per_s,
            ));
        }
        try std.testing.expectEqual(@as(c_int, -1), std.c.access(work_z.ptr, std.c.F_OK));
        try std.testing.expectEqual(std.posix.E.NOENT, std.posix.errno(-1));
    }
}
