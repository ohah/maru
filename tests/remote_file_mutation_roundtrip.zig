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

fn runRm(
    gpa: std.mem.Allocator,
    io: std.Io,
    bin: []const u8,
    parent: []const u8,
    name: []const u8,
    dev: u64,
    ino: u64,
) !mutation.Parsed {
    var dev_buf: [24]u8 = undefined;
    var ino_buf: [24]u8 = undefined;
    const dev_text = try std.fmt.bufPrint(&dev_buf, "{d}", .{dev});
    const ino_text = try std.fmt.bufPrint(&ino_buf, "{d}", .{ino});
    const out = try std.process.run(gpa, io, .{ .argv = &.{ bin, "rm", parent, name, dev_text, ino_text } });
    defer gpa.free(out.stdout);
    defer gpa.free(out.stderr);
    switch (out.term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.TestUnexpectedResult,
    }
    const parsed = try mutation.parse(out.stdout);
    return .{ .outcome = parsed.outcome, .message = &.{} };
}

test "헬퍼 rm 왕복: 신원이 맞아야 지우고, 빈 디렉터리만 간다 (RF6c)" {
    const bin = helperBin() orelse return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var dir_buf: [64]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "/tmp/maru-rfrm-rt.{d}", .{std.c.getpid()});
    try sh(gpa, io,
        \\set -eu
        \\rm -rf "$1"
        \\mkdir -p "$1/empty" "$1/full"
        \\printf keep > "$1/keep.txt"
        \\printf gone > "$1/gone.txt"
        \\printf inside > "$1/full/inside.txt"
    , dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var keep_buf: [128]u8 = undefined;
    const keep_path = try std.fmt.bufPrint(&keep_buf, "{s}/keep.txt", .{dir});

    // ── ① 신원이 어긋나면 **안 지운다**(§2.3 ⑶ — 이 모드의 안전은 여기서 온다).
    {
        const id = try listDev(gpa, io, bin, dir, "keep.txt");
        const got = try runRm(gpa, io, bin, dir, "keep.txt", id.dev, id.ino +% 1);
        try std.testing.expectEqual(mutation.Outcome.stale, got.outcome);
        const body = try std.Io.Dir.cwd().readFileAlloc(io, keep_path, gpa, .limited(64));
        defer gpa.free(body);
        try std.testing.expectEqualStrings("keep", body); // 그대로 있다
    }

    // ── ② 안 빈 디렉터리는 안 지운다(재귀 삭제를 안 한다 — 되돌리기가 없는 곳에서 사고가 커진다).
    {
        const id = try listDev(gpa, io, bin, dir, "full");
        const got = try runRm(gpa, io, bin, dir, "full", id.dev, id.ino);
        try std.testing.expectEqual(mutation.Outcome.collision, got.outcome);
        var inside_buf: [128]u8 = undefined;
        const inside = try std.fmt.bufPrint(&inside_buf, "{s}/full/inside.txt", .{dir});
        try std.testing.expect(std.Io.Dir.cwd().statFile(io, inside, .{}) catch null != null);
    }

    // ── ③ 빈 디렉터리는 지운다.
    {
        const id = try listDev(gpa, io, bin, dir, "empty");
        const got = try runRm(gpa, io, bin, dir, "empty", id.dev, id.ino);
        try std.testing.expectEqual(mutation.Outcome.ok, got.outcome);
        var empty_buf: [128]u8 = undefined;
        const empty = try std.fmt.bufPrint(&empty_buf, "{s}/empty", .{dir});
        try std.testing.expect(std.Io.Dir.cwd().statFile(io, empty, .{}) catch null == null);
    }

    // ── ④ 신원이 맞으면 실제로 지워진다 — 그리고 **옆 파일은 그대로다**.
    {
        const id = try listDev(gpa, io, bin, dir, "gone.txt");
        const got = try runRm(gpa, io, bin, dir, "gone.txt", id.dev, id.ino);
        try std.testing.expectEqual(mutation.Outcome.ok, got.outcome);
        var gone_buf: [128]u8 = undefined;
        const gone = try std.fmt.bufPrint(&gone_buf, "{s}/gone.txt", .{dir});
        try std.testing.expect(std.Io.Dir.cwd().statFile(io, gone, .{}) catch null == null);
        try std.testing.expect(std.Io.Dir.cwd().statFile(io, keep_path, .{}) catch null != null);
    }

    // ── ⑤ 이름이 이름일 수 없으면 invalid — `..` 로 부모를 지우는 일이 없다.
    {
        const got = try runRm(gpa, io, bin, dir, "..", 1, 2);
        try std.testing.expectEqual(mutation.Outcome.invalid, got.outcome);
    }
}

fn runMk(
    gpa: std.mem.Allocator,
    io: std.Io,
    bin: []const u8,
    parent: []const u8,
    name: []const u8,
    kind: []const u8,
    dev: u64,
    ino: u64,
) !mutation.Parsed {
    var dev_buf: [24]u8 = undefined;
    var ino_buf: [24]u8 = undefined;
    const dev_text = try std.fmt.bufPrint(&dev_buf, "{d}", .{dev});
    const ino_text = try std.fmt.bufPrint(&ino_buf, "{d}", .{ino});
    const out = try std.process.run(gpa, io, .{ .argv = &.{ bin, "mk", parent, name, kind, dev_text, ino_text } });
    defer gpa.free(out.stdout);
    defer gpa.free(out.stderr);
    switch (out.term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.TestUnexpectedResult,
    }
    const parsed = try mutation.parse(out.stdout);
    return .{ .outcome = parsed.outcome, .message = &.{} };
}

/// 디렉터리 **자신**의 신원(헬퍼가 `D` 레코드로 내는 그 값 — 같은 축이어야 비교가 성립한다).
fn listSelf(gpa: std.mem.Allocator, io: std.Io, bin: []const u8, dir: []const u8) !struct { dev: u64, ino: u64 } {
    const out = try std.process.run(gpa, io, .{ .argv = &.{ bin, "list", dir } });
    defer gpa.free(out.stdout);
    defer gpa.free(out.stderr);
    var parser = maru.session.remote_file_listing.Parser.init(out.stdout);
    const first = (try parser.next()) orelse return error.TestUnexpectedResult;
    return .{ .dev = first.dir.dev, .ino = first.dir.ino };
}

test "헬퍼 mk 왕복: 부모 신원이 맞아야 만들고, 배타라 덮어쓰지 않는다 (RF6d)" {
    const bin = helperBin() orelse return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var dir_buf: [64]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "/tmp/maru-rfmk-rt.{d}", .{std.c.getpid()});
    try sh(gpa, io,
        \\set -eu
        \\rm -rf "$1"
        \\mkdir -p "$1"
        \\printf mine > "$1/taken.txt"
    , dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const id = try listSelf(gpa, io, bin, dir);

    // ── ① 부모 신원이 어긋나면 **안 만든다**(엉뚱한 곳에 만들지 않는다).
    {
        const got = try runMk(gpa, io, bin, dir, "nope.txt", "f", id.dev, id.ino +% 1);
        try std.testing.expectEqual(mutation.Outcome.stale, got.outcome);
        var p: [128]u8 = undefined;
        const path = try std.fmt.bufPrint(&p, "{s}/nope.txt", .{dir});
        try std.testing.expect(std.Io.Dir.cwd().statFile(io, path, .{}) catch null == null);
    }

    // ── ② 배타 생성: 이름이 있으면 **덮어쓰지 않는다**(남의 내용이 그대로다).
    {
        const got = try runMk(gpa, io, bin, dir, "taken.txt", "f", id.dev, id.ino);
        try std.testing.expectEqual(mutation.Outcome.collision, got.outcome);
        var p: [128]u8 = undefined;
        const path = try std.fmt.bufPrint(&p, "{s}/taken.txt", .{dir});
        const kept = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64));
        defer gpa.free(kept);
        try std.testing.expectEqualStrings("mine", kept);
    }

    // ── ③ 파일을 만든다 — **빈 파일**이고 개행 이름도 된다(인자로 가므로 셸 인용과 무관하다).
    {
        const got = try runMk(gpa, io, bin, dir, "nl\nmade.txt", "f", id.dev, id.ino);
        try std.testing.expectEqual(mutation.Outcome.ok, got.outcome);
        var p: [128]u8 = undefined;
        const path = try std.fmt.bufPrint(&p, "{s}/nl\nmade.txt", .{dir});
        const body = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64));
        defer gpa.free(body);
        try std.testing.expectEqual(@as(usize, 0), body.len);
    }

    // ── ④ 디렉터리를 만든다.
    {
        const got = try runMk(gpa, io, bin, dir, "made-dir", "d", id.dev, id.ino);
        try std.testing.expectEqual(mutation.Outcome.ok, got.outcome);
        var p: [128]u8 = undefined;
        const path = try std.fmt.bufPrint(&p, "{s}/made-dir", .{dir});
        const st = try std.Io.Dir.cwd().statFile(io, path, .{});
        try std.testing.expectEqual(std.Io.File.Kind.directory, st.kind);
        // 같은 이름을 또 만들면 배타가 막는다.
        const again = try runMk(gpa, io, bin, dir, "made-dir", "d", id.dev, id.ino);
        try std.testing.expectEqual(mutation.Outcome.collision, again.outcome);
    }

    // ── ⑤ 이름·종류가 이름·종류일 수 없으면 invalid.
    {
        try std.testing.expectEqual(mutation.Outcome.invalid, (try runMk(gpa, io, bin, dir, "..", "f", id.dev, id.ino)).outcome);
        try std.testing.expectEqual(mutation.Outcome.invalid, (try runMk(gpa, io, bin, dir, "a/b", "f", id.dev, id.ino)).outcome);
        try std.testing.expectEqual(mutation.Outcome.invalid, (try runMk(gpa, io, bin, dir, "ok.txt", "x", id.dev, id.ino)).outcome);
    }
}

/// **`write` 러너** — 형제들과 달리 내용이 **stdin** 으로 간다(U3). `std.process.run` 은 stdin 을 못
/// 주므로 `sh` 로 파일을 물려 준다: `"$BIN" write … < body > out`. 그 우회가 곧 이 갈래의 사실이다.
fn runWrite(
    gpa: std.mem.Allocator,
    io: std.Io,
    bin: []const u8,
    parent: []const u8,
    name: []const u8,
    mode: []const u8,
    dev: u64,
    ino: u64,
    body: []const u8,
) !mutation.Parsed {
    var tmp_buf: [96]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, "/tmp/maru-rfwrite-io.{d}", .{std.c.getpid()});
    var body_buf: [96]u8 = undefined;
    const body_path = try std.fmt.bufPrint(&body_buf, "{s}.body", .{tmp});
    var out_buf: [96]u8 = undefined;
    const out_path = try std.fmt.bufPrint(&out_buf, "{s}.out", .{tmp});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = body_path, .data = body });
    defer std.Io.Dir.cwd().deleteFile(io, body_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, out_path) catch {};

    var dev_buf: [24]u8 = undefined;
    var ino_buf: [24]u8 = undefined;
    const dev_text = try std.fmt.bufPrint(&dev_buf, "{d}", .{dev});
    const ino_text = try std.fmt.bufPrint(&ino_buf, "{d}", .{ino});
    const run = try std.process.run(gpa, io, .{ .argv = &.{
        "/bin/sh",
        "-c",
        "exec \"$1\" write \"$2\" \"$3\" \"$4\" \"$5\" \"$6\" < \"$7\" > \"$8\"",
        "fixture",
        bin,
        parent,
        name,
        mode,
        dev_text,
        ino_text,
        body_path,
        out_path,
    } });
    defer gpa.free(run.stdout);
    defer gpa.free(run.stderr);
    switch (run.term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.TestUnexpectedResult,
    }
    const out = try std.Io.Dir.cwd().readFileAlloc(io, out_path, gpa, .limited(4096));
    defer gpa.free(out);
    const parsed = try mutation.parse(out);
    return .{ .outcome = parsed.outcome, .message = &.{} };
}

test "헬퍼 write 왕복: 내용이 stdin 으로 가고, 비대체가 남의 파일을 지키며, 덮어쓰기는 원자다 (U3)" {
    const bin = helperBin() orelse return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var dir_buf: [64]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "/tmp/maru-rfwrite-rt.{d}", .{std.c.getpid()});
    try sh(gpa, io,
        \\set -eu
        \\rm -rf "$1"
        \\mkdir -p "$1"
        \\printf theirs > "$1/taken.txt"
    , dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const id = try listSelf(gpa, io, bin, dir);

    // ── ① **새 파일에 내용이 들어간다**(`mk` 는 빈 파일만 만들었다 — 그 구멍이 이 하위 명령의 이유다).
    {
        const got = try runWrite(gpa, io, bin, dir, "notes.md", "x", id.dev, id.ino, "hello\nbody\n");
        try std.testing.expectEqual(mutation.Outcome.ok, got.outcome);
        var p: [128]u8 = undefined;
        const path = try std.fmt.bufPrint(&p, "{s}/notes.md", .{dir});
        const body = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64));
        defer gpa.free(body);
        try std.testing.expectEqualStrings("hello\nbody\n", body);
    }

    // ── ② **비대체(`x`)는 남의 파일을 지킨다** — `collision` 이고 내용이 그대로다.
    {
        const got = try runWrite(gpa, io, bin, dir, "taken.txt", "x", id.dev, id.ino, "mine");
        try std.testing.expectEqual(mutation.Outcome.collision, got.outcome);
        var p: [128]u8 = undefined;
        const path = try std.fmt.bufPrint(&p, "{s}/taken.txt", .{dir});
        const kept = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64));
        defer gpa.free(kept);
        try std.testing.expectEqualStrings("theirs", kept);
    }

    // ── ③ **덮어쓰기(`o`)는 바꿔 끼운다** — 사용자가 답한 뒤의 그 모드다.
    {
        const got = try runWrite(gpa, io, bin, dir, "taken.txt", "o", id.dev, id.ino, "mine");
        try std.testing.expectEqual(mutation.Outcome.ok, got.outcome);
        var p: [128]u8 = undefined;
        const path = try std.fmt.bufPrint(&p, "{s}/taken.txt", .{dir});
        const now = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64));
        defer gpa.free(now);
        try std.testing.expectEqualStrings("mine", now);
    }

    // ── ④ **신원이 0·0 이면 「비교할 과거가 없다」** — 문서 저장이 그 자리다(목록을 거치지 않는다).
    //     여기서 `stale` 이 나오면 **모든 저쪽 저장이** 그렇게 된다.
    {
        const got = try runWrite(gpa, io, bin, dir, "no-identity.txt", "x", 0, 0, "ok");
        try std.testing.expectEqual(mutation.Outcome.ok, got.outcome);
    }

    // ── ⑤ **신원이 어긋나면 안 쓴다**(0·0 이 아닌 값을 주면 그 관문은 살아 있다).
    {
        const got = try runWrite(gpa, io, bin, dir, "nope.txt", "x", id.dev, id.ino +% 1, "x");
        try std.testing.expectEqual(mutation.Outcome.stale, got.outcome);
        var p: [128]u8 = undefined;
        const path = try std.fmt.bufPrint(&p, "{s}/nope.txt", .{dir});
        try std.testing.expect(std.Io.Dir.cwd().statFile(io, path, .{}) catch null == null);
    }

    // ── ⑥ **이름·모드가 이름·모드일 수 없으면 invalid** — 그리고 **임시 파일을 남기지 않는다**
    //     (남기면 다음 저장이 「이미 있다」를 만난다).
    {
        try std.testing.expectEqual(mutation.Outcome.invalid, (try runWrite(gpa, io, bin, dir, "..", "x", id.dev, id.ino, "x")).outcome);
        try std.testing.expectEqual(mutation.Outcome.invalid, (try runWrite(gpa, io, bin, dir, "a/b", "x", id.dev, id.ino, "x")).outcome);
        try std.testing.expectEqual(mutation.Outcome.invalid, (try runWrite(gpa, io, bin, dir, "ok.txt", "z", id.dev, id.ino, "x")).outcome);
        var d = try std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true });
        defer d.close(io);
        var it = d.iterate();
        while (try it.next(io)) |e| {
            try std.testing.expect(!std.mem.startsWith(u8, e.name, ".maru-write-"));
        }
    }
}

test "헬퍼 mv: 절대경로가 아니면 wire 오류로 완결된다 — 침묵이 아니다 (RF6a)" {
    const bin = helperBin() orelse return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const got = try runMv(gpa, io, bin, "relative/dir", "a", "b", 1, 2);
    try std.testing.expectEqual(mutation.Outcome.invalid, got.outcome);
}
