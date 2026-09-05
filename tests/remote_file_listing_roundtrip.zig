//! **헬퍼 `list` ↔ 코덱 파서 왕복 게이트**(RF2a — [계획](../docs/plans/remote-file-tree.md) §2.2·§10).
//!
//! wire 의 단일 출처는 `session/remote_file_listing.zig` 인데, 헬퍼 바이너리는 std 만 임포트하므로
//! (크기·자기완결) 인코더를 모듈로 못 물고 **사본**을 든다. 그 사본이 갈리는 것을 막는 자리가
//! 여기다 — RW 가 `version_line` 을 **문자열로 대조**하는 것보다 강하게, **빌드가 만든 실물
//! 바이너리를 실제로 돌려** 그 출력을 파서로 되읽는다. 바이트 하나가 갈려도 파서가 죽는다.
//!
//! 바이너리 경로는 빌드가 `MARU_REMOTE_WATCH_BIN` 으로 넣는다(`test-remote-file-listing`). env 가
//! 없으면 skip 인데, **빌드 등록이 `--maru-expect-passed` 로 그 침묵을 막는다** — 조용히 skip 으로
//! 초록이 되는 것이 이 저장소가 가장 나쁘다고 적어 둔 실패 모드다.

const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const listing = maru.session.remote_file_listing;

fn helperBin() ?[]const u8 {
    if (builtin.os.tag == .windows) return null;
    const raw = std.c.getenv("MARU_REMOTE_WATCH_BIN") orelse return null;
    return std.mem.span(raw);
}

/// 함정 이름이 든 픽스처를 sh 로 만든다 — 개행 이름·심링크를 std FS API 판올림과 무관하게 만드는
/// 가장 결정적인 길이다(이 테스트는 POSIX 전용이고 그 사실을 skip 으로 말한다).
fn makeFixture(gpa: std.mem.Allocator, io: std.Io, dir: []const u8) !void {
    const script =
        \\set -eu
        \\rm -rf "$1"
        \\mkdir -p "$1/sub"
        \\: > "$1/plain.txt"
        \\printf x > "$1/has space.txt"
        \\ln -s plain.txt "$1/link.txt"
        \\ln -s sub "$1/dirlink"
        \\ln -s nowhere "$1/broken"
        \\touch "$1/$(printf 'nl\nname.txt')"
    ;
    const made = try std.process.run(gpa, io, .{ .argv = &.{ "/bin/sh", "-c", script, "fixture", dir } });
    defer gpa.free(made.stdout);
    defer gpa.free(made.stderr);
    switch (made.term) {
        .exited => |code| if (code != 0) return error.FixtureFailed,
        else => return error.FixtureFailed,
    }
}

fn runList(gpa: std.mem.Allocator, io: std.Io, bin: []const u8, dir: []const u8) !std.process.RunResult {
    return std.process.run(gpa, io, .{ .argv = &.{ bin, "list", dir } });
}

test "헬퍼 list 왕복: 함정 이름·심링크 구분·신원이 파서로 그대로 되읽힌다" {
    const bin = helperBin() orelse return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // ⚠️ 경로는 짧게(/tmp) — 그리고 pid 픽스처는 **양쪽에서** deleteTree 한다(pid 재사용이 만드는
    // 간헐 실패의 처방). 실제 정리는 sh 의 `rm -rf` 가 이미 만들기 앞에서 한다.
    var dir_buf: [64]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "/tmp/maru-rfls-rt.{d}", .{std.c.getpid()});
    try makeFixture(gpa, io, dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const out = try runList(gpa, io, bin, dir);
    defer gpa.free(out.stdout);
    defer gpa.free(out.stderr);
    switch (out.term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.TestUnexpectedResult,
    }

    var parser = listing.Parser.init(out.stdout);
    const first = (try parser.next()).?;
    // 디렉터리 자신의 신원은 **열린 핸들의 fstat 축**이다 — 같은 디렉터리를 이쪽에서 재도 같아야 한다.
    const dir_stat = try std.Io.Dir.cwd().statFile(io, dir, .{});
    try std.testing.expectEqual(@as(u64, @intCast(dir_stat.inode)), first.dir.ino);

    const Expected = struct { kind: maru.session.file_tree.Kind, seen: bool = false };
    var expected = std.StringHashMap(Expected).init(gpa);
    defer expected.deinit();
    try expected.put("plain.txt", .{ .kind = .file });
    try expected.put("has space.txt", .{ .kind = .file });
    try expected.put("nl\nname.txt", .{ .kind = .file }); // 이 wire 의 존재 이유 — 개행 이름
    try expected.put("sub", .{ .kind = .directory });
    try expected.put("link.txt", .{ .kind = .symlink_file });
    try expected.put("dirlink", .{ .kind = .symlink_directory }); // 가리키는 곳까지 갈랐는가
    try expected.put("broken", .{ .kind = .symlink_file }); // 끊긴 링크는 파일 쪽으로

    var count: usize = 0;
    while (try parser.next()) |ev| {
        const entry = ev.entry; // dir 는 이미 나왔다 — 다른 variant 면 여기서 죽는 것이 맞다
        const slot = expected.getPtr(entry.name) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(slot.kind, entry.kind);
        try std.testing.expect(!slot.seen); // 같은 이름 두 번 = 헬퍼 결함
        slot.seen = true;
        try std.testing.expect(entry.ino != 0);
        count += 1;

        // 항목 신원은 lstat 축 — 이쪽에서 no-follow 로 재도 같아야 한다(심링크가 갈리는 자리다).
        var path_buf: [128]u8 = undefined;
        const full = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, entry.name });
        const st = try std.Io.Dir.cwd().statFile(io, full, .{ .follow_symlinks = false });
        try std.testing.expectEqual(@as(u64, @intCast(st.inode)), entry.ino);
    }
    try std.testing.expect(parser.complete()); // 꼬리까지 봤다 — 잘린 목록이 아니다
    try std.testing.expectEqual(@as(usize, 7), count);
    var it = expected.iterator();
    while (it.next()) |kv| try std.testing.expect(kv.value_ptr.seen);
}

test "헬퍼 list: 상대경로는 wire 오류로 완결된다 — 침묵이 아니다" {
    const bin = helperBin() orelse return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const out = try runList(gpa, std.testing.io, bin, "relative/path");
    defer gpa.free(out.stdout);
    defer gpa.free(out.stderr);

    var parser = listing.Parser.init(out.stdout);
    const ev = (try parser.next()).?;
    try std.testing.expect(std.mem.indexOf(u8, ev.remote_error, "not absolute") != null);
    try std.testing.expectEqual(@as(?listing.Event, null), try parser.next());
    try std.testing.expect(parser.complete()); // 오류도 완결된 답이다(§2.5)
}

test "헬퍼 list: 없는 디렉터리는 opendir 실패를 wire 로 말한다" {
    const bin = helperBin() orelse return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const out = try runList(gpa, std.testing.io, bin, "/maru-rfls-no-such-dir-e2e");
    defer gpa.free(out.stdout);
    defer gpa.free(out.stderr);

    var parser = listing.Parser.init(out.stdout);
    const ev = (try parser.next()).?;
    try std.testing.expect(std.mem.startsWith(u8, ev.remote_error, "opendir failed"));
    try std.testing.expect(parser.complete());
}
