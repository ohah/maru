//! 그림자 사본을 위한 **파일 읽기**(L4). 보관 정책은 [`session/turn_capture.zig`](../../session/turn_capture.zig)가 갖는다.
//!
//! 이 모듈이 답하는 것은 하나다 — 「지금 이 경로의 내용은 무엇인가」를 `turn_capture.Side` 로.
//!
//! **symlink 규율의 단일 출처가 여기다.** `openNoFollow` 는 원래 `git_backend` 안의 private 함수였는데,
//! 캡처가 같은 적대 조건(훅이 준 경로를 그대로 연다)에 놓이면서 두 벌이 될 뻔했다. 복사 대신 올렸다 —
//! 이 저장소가 반복해서 지적하는 실패 방식이 「같은 규율이 두 자리에 있다」다.

const std = @import("std");
const maru = @import("maru");
const repo_path = maru.session.repo_path;
const diff_payload = maru.session.diff_payload;
const turn_capture = maru.session.turn_capture;

/// 저장소 루트에서 시작해 경로 요소를 하나씩 `openat`으로 내려가며 연다. **각 단계가 `O_NOFOLLOW`**라
/// 어느 요소든 symlink면 그 자리에서 실패한다(ELOOP). 마지막 요소만 파일로 연다.
///
/// **마지막 요소만 막으면 안 되는 이유**: 중간 디렉터리가 링크면 저장소 밖이 열린다.
///
/// `error.NotFound` 를 따로 낸다 — 「그때 없었다」와 「못 읽었다」는 화면에서 다른 말이 되어야 한다
/// (`Write` 로 새 파일을 만드는 흐름이 전자다).
pub fn openNoFollow(root: []const u8, rel_path: []const u8) !c_int {
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_z = std.fmt.bufPrintZ(&root_buf, "{s}", .{root}) catch return error.PathTooLong;
    // 루트 자체는 사용자가 연 폴더라 따라가도 된다(그 경로를 고른 것이 사용자다) — 그 **아래**부터 막는다.
    var dir_fd = std.c.open(root_z.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .DIRECTORY = true });
    if (dir_fd < 0) return error.OpenFailed;

    var it = std.mem.splitScalar(u8, rel_path, '/');
    var pending: ?[]const u8 = it.next();
    while (pending) |segment| {
        const next = it.next();
        var seg_buf: [std.fs.max_path_bytes]u8 = undefined;
        const seg_z = std.fmt.bufPrintZ(&seg_buf, "{s}", .{segment}) catch {
            _ = std.c.close(dir_fd);
            return error.PathTooLong;
        };
        const is_last = next == null;
        const flags: std.c.O = if (is_last)
            .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }
        else
            .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true, .DIRECTORY = true };
        const opened = std.c.openat(dir_fd, seg_z.ptr, flags, @as(std.c.mode_t, 0));
        // **errno 를 close 전에 읽는다** — close 가 실패하면 errno 를 덮어써 «없다»가 «못 읽었다»로 바뀐다.
        const err = std.c._errno().*;
        _ = std.c.close(dir_fd);
        if (opened < 0) {
            return if (err == @intFromEnum(std.c.E.NOENT) or err == @intFromEnum(std.c.E.NOTDIR))
                error.NotFound
            else
                error.OpenFailed;
        }
        if (is_last) return opened;
        dir_fd = opened;
        pending = next;
    }
    _ = std.c.close(dir_fd);
    return error.OpenFailed; // rel_path가 비어 있었다(isSafeRelative가 이미 막지만 경로를 열어 두지 않는다)
}

/// 그 경로의 **지금 내용**을 `Side` 로. 소유권은 호출자에게 넘어간다(`turn_capture` 가 가져간다).
///
/// 규율 넷:
///
/// 1. **루트 밖은 경로만 알고 내용은 안 읽는다**(§7). 계약 M4 가 「provider 기록에는 절대경로가 그대로
///    온다」를 실측했다 — 에이전트가 `Read` 한 `~/.ssh/id_rsa` 가 링 8턴 동안 RAM 에 남는 것은
///    터미널이 할 일이 아니다.
/// 2. **바이너리는 첫 청크에서 접는다.** `looksBinary` 는 앞 8000 바이트만 보므로 곧바로 판정되고,
///    `diff_payload.decide` 가 **계약상 반드시 거절할** 바이트를 최대 64벌 들 이유가 없다.
/// 3. **상한을 넘으면 보관은 버리되 EOF 까지 읽어 전문을 해시한다.** 앞부분만 해시하면 뒷부분만 다른
///    두 큰 파일이 **거짓으로 같아져** 「순변경 없음」이 거짓으로 선다.
/// 4. **없음·빔·모름을 셋으로 가른다**(`Side` 주석).
pub fn readSide(gpa: std.mem.Allocator, root: []const u8, abs_path: []const u8) turn_capture.Side {
    if (!repo_path.underRoot(abs_path, root)) return .{ .unknown = .outside_root };
    const rel = repo_path.displayRelative(abs_path, root);
    if (!repo_path.isSafeRelative(rel)) return .{ .unknown = .unreadable };

    const fd = openNoFollow(root, rel) catch |err| return switch (err) {
        error.NotFound => .absent,
        else => .{ .unknown = .unreadable },
    };
    defer _ = std.c.close(fd);

    var kept: std.ArrayList(u8) = .empty;
    defer kept.deinit(gpa);
    var hasher = std.hash.Wyhash.init(0);
    var total: u64 = 0;
    var fold: ?turn_capture.Fold = null;
    var probed = false;
    var tmp: [16 * 1024]u8 = undefined;

    while (true) {
        const n = std.posix.read(fd, &tmp) catch return .{ .unknown = .unreadable };
        if (n == 0) break; // EOF
        const chunk = tmp[0..n];
        hasher.update(chunk);
        total += n;

        if (fold == null) {
            if (kept.appendSlice(gpa, chunk)) |_| {} else |_| return .{ .unknown = .unreadable };
            if (!probed and kept.items.len >= diff_payload.binary_probe_bytes) {
                probed = true;
                if (diff_payload.looksBinary(kept.items)) fold = .binary;
            }
            if (fold == null and kept.items.len > turn_capture.max_capture_bytes) fold = .too_large;
            // 접기로 정했으면 **보관만 버린다** — 해시는 계속 먹어야 전문에 걸린다.
            if (fold != null) kept.clearAndFree(gpa);
        }
    }

    // EOF 가 8000 바이트 전에 왔으면 여기서 판정한다(짧은 파일).
    if (fold == null and !probed and diff_payload.looksBinary(kept.items)) fold = .binary;

    if (fold) |why| return .{ .folded = .{ .hash = hasher.final(), .size = total, .why = why } };
    if (total == 0) return .empty;
    const owned = kept.toOwnedSlice(gpa) catch return .{ .unknown = .unreadable };
    return .{ .text = owned };
}

const testing = std.testing;
const fixture_io = std.Io.Threaded.global_single_threaded.io();

/// 임시 루트 하나에 파일을 놓고 `readSide` 를 부른다.
const Fixture = struct {
    dir: std.testing.TmpDir,
    root_buf: [std.fs.max_path_bytes]u8 = undefined,
    root_len: usize = 0,

    fn init() !Fixture {
        var self: Fixture = .{ .dir = std.testing.tmpDir(.{}) };
        self.root_len = try self.dir.dir.realPath(fixture_io, &self.root_buf);
        return self;
    }
    fn deinit(self: *Fixture) void {
        self.dir.cleanup();
    }
    fn root(self: *const Fixture) []const u8 {
        return self.root_buf[0..self.root_len];
    }
    fn write(self: *Fixture, name: []const u8, data: []const u8) !void {
        try self.dir.dir.writeFile(fixture_io, .{ .sub_path = name, .data = data });
    }
    fn read(self: *Fixture, gpa: std.mem.Allocator, name: []const u8) !turn_capture.Side {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const abs = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ self.root(), name });
        return readSide(gpa, self.root(), abs);
    }
};

fn freeSideForTest(gpa: std.mem.Allocator, side: *turn_capture.Side) void {
    switch (side.*) {
        .text => |t| gpa.free(t),
        else => {},
    }
}

test "readSide: 없는 파일은 absent, 빈 파일은 empty — 둘을 가른다" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const gpa = testing.allocator;

    // **없다**(`Write` 로 새로 만드는 흐름의 before 가 이것이다).
    var missing = try fx.read(gpa, "nope.txt");
    defer freeSideForTest(gpa, &missing);
    try testing.expect(missing == .absent);

    // **0바이트로 있다** — `absent` 와 다른 사실이다. 한 값으로 접는 구현이 여기서 죽는다.
    try fx.write("empty.txt", "");
    var empty = try fx.read(gpa, "empty.txt");
    defer freeSideForTest(gpa, &empty);
    try testing.expect(empty == .empty);
}

test "readSide: 보통 파일은 바이트 그대로 든다" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const gpa = testing.allocator;
    try fx.write("a.zig", "const x = 1;\n");
    var side = try fx.read(gpa, "a.zig");
    defer freeSideForTest(gpa, &side);
    try testing.expectEqualStrings("const x = 1;\n", side.text);
}

test "readSide: NUL 이 있으면 바이너리로 접고 내용을 안 든다" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const gpa = testing.allocator;

    var blob: [32 * 1024]u8 = undefined;
    @memset(&blob, 'a');
    blob[10] = 0; // 탐침 범위 안의 NUL
    try fx.write("bin.dat", &blob);

    var side = try fx.read(gpa, "bin.dat");
    defer freeSideForTest(gpa, &side);
    try testing.expectEqual(turn_capture.Fold.binary, side.folded.why);
    // **크기는 실제 크기**여야 한다 — 자른 크기를 적는 구현이 여기서 죽는다.
    try testing.expectEqual(@as(u64, blob.len), side.folded.size);
    try testing.expect(side.folded.hash != 0);
}

test "readSide: 상한 초과는 접히고 해시가 **전문**에 걸린다" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const gpa = testing.allocator;

    const big = turn_capture.max_capture_bytes + 4096;
    const a = try gpa.alloc(u8, big);
    defer gpa.free(a);
    @memset(a, 'x');
    const b = try gpa.alloc(u8, big);
    defer gpa.free(b);
    @memset(b, 'x');
    // **앞부분은 완전히 같고 뒤만 다르다.** 앞부분만 해시하는 구현은 이 하나에서만 죽는다 — 그 버그는
    // 「순변경 없음」이 거짓으로 설 때까지 안 보인다.
    b[big - 1] = 'y';

    try fx.write("big_a.txt", a);
    try fx.write("big_b.txt", b);

    var sa = try fx.read(gpa, "big_a.txt");
    defer freeSideForTest(gpa, &sa);
    var sb = try fx.read(gpa, "big_b.txt");
    defer freeSideForTest(gpa, &sb);

    try testing.expectEqual(turn_capture.Fold.too_large, sa.folded.why);
    try testing.expectEqual(@as(u64, big), sa.folded.size);
    try testing.expect(sa.folded.hash != sb.folded.hash);
    // 같은 내용이면 같다고 답한다(`Side.sameAs` 가 이 값을 쓴다).
    var sa2 = try fx.read(gpa, "big_a.txt");
    defer freeSideForTest(gpa, &sa2);
    try testing.expectEqual(@as(?bool, true), sa.sameAs(sa2));
}

test "readSide: 루트 밖은 내용을 읽지 않는다" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const gpa = testing.allocator;
    var side = readSide(gpa, fx.root(), "/etc/hosts");
    defer freeSideForTest(gpa, &side);
    try testing.expectEqual(turn_capture.Unknown.outside_root, side.unknown);
}

test "readSide: `..` 로 루트를 빠져나가는 경로는 내용을 얻지 못한다" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const gpa = testing.allocator;

    // ⚠️ **`underRoot` 만으로는 안 막힌다.** `<root>/../etc/hosts` 는 루트로 시작하고 다음 글자가 `/` 라
    // 경계 검사를 **통과한다** — 막는 것은 그 뒤의 `isSafeRelative`(`..` 세그먼트 거부)다. 두 관문이
    // 각각 다른 것을 막으므로 어느 하나를 빼도 여기서 죽는다.
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const escaping = try std.fmt.bufPrint(&buf, "{s}/../etc/hosts", .{fx.root()});
    var side = readSide(gpa, fx.root(), escaping);
    defer freeSideForTest(gpa, &side);
    // 내용을 **얻지 못했다**를 직접 잰다("ok 가 아니다" 만으로는 약하다).
    try testing.expect(side != .text);
}

test "readSide: 중간 디렉터리가 심링크면 대상 바이트를 얻지 못한다" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const gpa = testing.allocator;

    fx.dir.dir.symLink(fixture_io, "/etc", "link", .{}) catch return error.SkipZigTest;
    var side = try fx.read(gpa, "link/hosts");
    defer freeSideForTest(gpa, &side);
    // **「ok 가 아니다」만 보면 약하다** — 바이트를 얻지 못했음을 직접 잰다.
    try testing.expect(side != .text);
}
