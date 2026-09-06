//! **헬퍼 `mv` ↔ 코덱 파서 왕복 게이트**(RF6a — [계획](../docs/plans/remote-file-tree.md) §2.3 ⑶).
//!
//! `remote_file_listing_roundtrip.zig` 와 같은 자리·같은 이유다: wire 의 단일 출처는
//! `session/remote_file_mutation.zig` 인데 헬퍼는 std 만 임포트해 **사본**을 든다. 그 사본이 갈리는
//! 것을 «빌드가 만든 실물 바이너리를 실제로 돌려» 막는다.
//!
//! 여기서 더 재는 것이 하나 있다 — **계약이 실제로 지켜지는가**. 이 모드의 존재 이유는
//! 「저쪽 한 프로세스 안에서 stat → 비교 → 비대체 rename」이므로, 신원이 어긋난 경우와 대상이 이미
//! 있는 경우가 **각각 다른 결말**로 와야 한다. 셸 조합으로는 못 만드는 보장이 그것이다.
//!
//! 바이너리 경로는 빌드가 `MARU_REMOTE_WATCH_BIN` 으로 넣는다. env 가 없으면 skip 인데, 빌드 등록의
//! `--maru-expect-passed` 가 그 침묵을 막는다.

const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const mutation = maru.session.remote_file_mutation;

fn helperBin() ?[]const u8 {
    if (builtin.os.tag == .windows) return null;
    const raw = std.c.getenv("MARU_REMOTE_WATCH_BIN") orelse return null;
    return std.mem.span(raw);
}

fn sh(gpa: std.mem.Allocator, io: std.Io, script: []const u8, arg: []const u8) !void {
    const made = try std.process.run(gpa, io, .{ .argv = &.{ "/bin/sh", "-c", script, "fixture", arg } });
    defer gpa.free(made.stdout);
    defer gpa.free(made.stderr);
    switch (made.term) {
        .exited => |code| if (code != 0) return error.FixtureFailed,
        else => return error.FixtureFailed,
    }
}

fn identityOf(io: std.Io, path: []const u8) !struct { dev: u64, ino: u64 } {
    const st = try std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    // ⚠️ **dev 는 여기서 안 쓴다** — 헬퍼(리눅스)는 `statx` 의 major/minor 를 접어 만들고 이쪽 std 는
    // 다른 표현을 줄 수 있다. wire 계약은 「같은 기계 안에서 같으면 같다」뿐이라, 이 판정자는
    // 헬퍼가 준 dev 를 **되돌려 준다**(아래 `listDev`). ino 는 두 축이 같아 그대로 쓴다.
    return .{ .dev = 0, .ino = @intCast(st.inode) };
}

/// 헬퍼 자신이 본 dev 를 얻는다 — `list` 의 `D` 레코드가 그 값이다(같은 바이너리·같은 축).
fn listDev(gpa: std.mem.Allocator, io: std.Io, bin: []const u8, dir: []const u8, name: []const u8) !struct { dev: u64, ino: u64 } {
    const out = try std.process.run(gpa, io, .{ .argv = &.{ bin, "list", dir } });
    defer gpa.free(out.stdout);
    defer gpa.free(out.stderr);
    var parser = maru.session.remote_file_listing.Parser.init(out.stdout);
    _ = try parser.next(); // D 레코드
    while (try parser.next()) |ev| {
        const entry = ev.entry;
        if (std.mem.eql(u8, entry.name, name)) return .{ .dev = entry.dev, .ino = entry.ino };
    }
    return error.TestUnexpectedResult;
}

fn runMv(
    gpa: std.mem.Allocator,
    io: std.Io,
    bin: []const u8,
    parent: []const u8,
    old_name: []const u8,
    new_name: []const u8,
    dev: u64,
    ino: u64,
) !mutation.Parsed {
    var dev_buf: [24]u8 = undefined;
    var ino_buf: [24]u8 = undefined;
    const dev_text = try std.fmt.bufPrint(&dev_buf, "{d}", .{dev});
    const ino_text = try std.fmt.bufPrint(&ino_buf, "{d}", .{ino});
    const out = try std.process.run(gpa, io, .{
        .argv = &.{ bin, "mv", parent, old_name, new_name, dev_text, ino_text },
    });
    defer gpa.free(out.stdout);
    defer gpa.free(out.stderr);
    switch (out.term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code), // 결말은 wire 로 말한다
        else => return error.TestUnexpectedResult,
    }
    // 파서가 빌린 바이트가 여기서 죽으므로 outcome 만 꺼내 돌려준다(메시지는 자리에서 본다).
    const parsed = try mutation.parse(out.stdout);
    return .{ .outcome = parsed.outcome, .message = &.{} };
}

test "헬퍼 mv 왕복: 신원이 맞으면 바꾸고, 어긋나면 stale 로 말한다 (RF6a)" {
    const bin = helperBin() orelse return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var dir_buf: [64]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "/tmp/maru-rfmv-rt.{d}", .{std.c.getpid()});
    try sh(gpa, io,
        \\set -eu
        \\rm -rf "$1"
        \\mkdir -p "$1"
        \\printf hello > "$1/old.txt"
        \\printf other > "$1/taken.txt"
    , dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var path_buf: [128]u8 = undefined;
    const old_path = try std.fmt.bufPrint(&path_buf, "{s}/old.txt", .{dir});
    const id = try listDev(gpa, io, bin, dir, "old.txt");
    _ = try identityOf(io, old_path); // 존재 확인(축이 다른 dev 는 위 주석 참조)

    // ── ① 대상이 이미 있으면 **비대체**가 막는다. 미리 물어보면 그 사이가 창이라 여기서 판정한다.
    {
        const got = try runMv(gpa, io, bin, dir, "old.txt", "taken.txt", id.dev, id.ino);
        try std.testing.expectEqual(mutation.Outcome.collision, got.outcome);
        // 막혔으니 **덮어쓰지 않았다** — 남의 내용이 그대로다(이 판정이 fail-closed 의 증거다).
        var taken_buf: [128]u8 = undefined;
        const taken = try std.fmt.bufPrint(&taken_buf, "{s}/taken.txt", .{dir});
        const kept = try std.Io.Dir.cwd().readFileAlloc(io, taken, gpa, .limited(64));
        defer gpa.free(kept);
        try std.testing.expectEqualStrings("other", kept);
    }

    // ── ② 신원이 어긋나면 **안 바꾸고** stale 로 말한다(§2.3 ⑶ 의 재확인이 이것이다).
    {
        const got = try runMv(gpa, io, bin, dir, "old.txt", "new.txt", id.dev, id.ino +% 1);
        try std.testing.expectEqual(mutation.Outcome.stale, got.outcome);
        try std.testing.expect(std.Io.Dir.cwd().statFile(io, old_path, .{}) catch null != null);
    }

    // ── ③ 원본이 없으면 not_found.
    {
        const got = try runMv(gpa, io, bin, dir, "ghost.txt", "new.txt", id.dev, id.ino);
        try std.testing.expectEqual(mutation.Outcome.not_found, got.outcome);
    }

    // ── ④ 이름이 이름일 수 없으면 invalid — `..` 하나가 부모 밖을 가리키는 일이 없다.
    {
        const got = try runMv(gpa, io, bin, dir, "old.txt", "..", id.dev, id.ino);
        try std.testing.expectEqual(mutation.Outcome.invalid, got.outcome);
        const got2 = try runMv(gpa, io, bin, dir, "old.txt", "a/b", id.dev, id.ino);
        try std.testing.expectEqual(mutation.Outcome.invalid, got2.outcome);
    }

    // ── ⑤ 신원이 맞으면 실제로 바뀐다. **이름에 개행이 들어도** 된다(목록 wire 가 그것을 보증하므로
    //     변경 쪽도 같은 이름을 받을 수 있어야 한다 — 인자로 넘어가니 셸 인용과 무관하다).
    {
        const got = try runMv(gpa, io, bin, dir, "old.txt", "nl\nname.txt", id.dev, id.ino);
        try std.testing.expectEqual(mutation.Outcome.ok, got.outcome);
        var moved_buf: [128]u8 = undefined;
        const moved = try std.fmt.bufPrint(&moved_buf, "{s}/nl\nname.txt", .{dir});
        const body = try std.Io.Dir.cwd().readFileAlloc(io, moved, gpa, .limited(64));
        defer gpa.free(body);
        try std.testing.expectEqualStrings("hello", body);
        try std.testing.expect(std.Io.Dir.cwd().statFile(io, old_path, .{}) catch null == null);
    }
}

test "헬퍼 mv: 절대경로가 아니면 wire 오류로 완결된다 — 침묵이 아니다 (RF6a)" {
    const bin = helperBin() orelse return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const got = try runMv(gpa, io, bin, "relative/dir", "a", "b", 1, 2);
    try std.testing.expectEqual(mutation.Outcome.invalid, got.outcome);
}
