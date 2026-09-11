//! **헬퍼 `activity` ↔ 코덱 파서 왕복 게이트**(RAV2 — [계획](../docs/plans/remote-agent-activity.md) §5).
//!
//! [목록 왕복 게이트](remote_file_listing_roundtrip.zig)와 같은 자리·같은 이유지만 **막는 것이 다르다.**
//! 그쪽은 헬퍼가 인코더의 **사본**을 들어서 생기는 드리프트를 잡는다. 이쪽은 헬퍼가 모듈을 **물므로**
//! 인코더 드리프트가 원리적으로 없다 — 대신 이 게이트가 잡는 것은 **배선**이다.
//!
//! - 빌드가 헬퍼에 모듈을 안 물리면? 컴파일이 깨진다(그건 빌드가 잡는다).
//! - 헬퍼가 스캔은 하는데 **라벨을 안 만들면**? 컴파일은 통과하고 화면만 빈다.
//! - 헬퍼가 **절대경로 가드**를 빠뜨리면? 통과하고 남의 파일을 연다.
//! - 헬퍼가 꼬리를 **못 실은 것까지 세면**? 통과하고 활동이 조용히 사라진다(§6.1 이 막으려던 것).
//!
//! 그래서 여기서는 **의미**를 단언한다: 같은 픽스처를 로컬 스캐너로도 훑어 **같은 결과가 나오는지**
//! 본다. 원격과 로컬이 다른 것을 보여 주는 것이 이 뷰의 최악 실패이고(계약 §2.3), 그 불변식을
//! 바이트 수준에서 못박는 자리가 여기다.
//!
//! 바이너리 경로는 빌드가 `MARU_REMOTE_WATCH_BIN` 으로 넣는다(`test-remote-activity`). env 가 없으면
//! skip 인데, **빌드 등록이 `--maru-expect-passed` 로 그 침묵을 막는다**.

const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const wire = maru.session.remote_activity_wire;

fn helperBin() ?[]const u8 {
    if (builtin.os.tag == .windows) return null;
    const raw = std.c.getenv("MARU_REMOTE_WATCH_BIN") orelse return null;
    return std.mem.span(raw);
}

/// Claude·Codex 두 모양을 한 파일에 섞은 합성 트랜스크립트.
///
/// ⚠️ **합성이라 계약값을 대표하지 못한다**(스캐너 처리량 프로브가 그것으로 한 번 틀렸다). 여기서
/// 재는 것은 **크기가 아니라 의미**다 — 이 줄들이 어떤 활동으로, 어떤 라벨로, 어떤 결말로 읽히는가.
///
/// ⚠️ **시각은 provider 마다 반대편이다**(계약 §2.2 · AV2b). Claude 는 `tool_use` 마커 **뒤**이고
/// (실측 40,676/40,676) Codex 는 줄 **머리**다. 초안 픽스처는 Claude 쪽도 머리에 뒀는데, 그러면
/// 스캐너가 `time_rel = 0`(모른다)을 내고 **이 게이트가 시각 배선을 못 본다** — 합성 픽스처가
/// 실제 모양을 안 닮으면 판정자가 그만큼 눈을 감는다.
///
/// ⚠️ **같은 함정이 결말에서도 났다.** `"is_error":true` 는 실측 **715/715 가 `content` 값 뒤**라
/// 스캐너가 그 자리에서만 찾는다. 초안은 앞에 뒀고, 그래서 실패 결말이 안 붙었다. 필드 **순서까지**
/// 실제를 닮아야 하는 자리가 둘이다.
const fixture_lines =
    \\{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_01","name":"Bash","input":{"command":"zig build test","description":"판정자를 돌린다"}}]},"timestamp":"2026-09-11T01:02:03.000Z"}
    \\{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"boom\nsecond line","is_error":true,"tool_use_id":"toolu_01"}]}}
    \\{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_02","name":"Read","input":{"file_path":"/srv/app/src/main.zig"}}]},"timestamp":"2026-09-11T01:02:05.000Z"}
    \\{"timestamp":"2026-09-11T01:02:07.000Z","type":"function_call","name":"shell","call_id":"call_9","arguments":"{\"command\":\"ls -la\"}"}
;

fn writeFixture(io: std.Io, path: []const u8) !void {
    const f = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer f.close(io);
    var at: u64 = 0;
    at += try f.writePositional(io, &.{fixture_lines}, at);
    _ = try f.writePositional(io, &.{"\n"}, at);
}

/// 로컬에서 같은 파일을 **제품 스캐너**로 훑어 원격 결과와 맞댈 기준선을 만든다.
fn scanLocally(gpa: std.mem.Allocator, io: std.Io, path: []const u8, out: *std.ArrayList(wire.Hit)) !void {
    const f = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    defer f.close(io);
    var scanner: wire.Scanner = .{};
    defer scanner.deinit(gpa);
    var buf: [4096]u8 = undefined;
    var at: u64 = 0;
    while (true) {
        const n = try f.readPositional(io, &.{&buf}, at);
        if (n == 0) break;
        at += n;
        try scanner.feed(gpa, buf[0..n], out);
    }
}

fn runHelper(gpa: std.mem.Allocator, io: std.Io, bin: []const u8, path: []const u8) !std.process.RunResult {
    return std.process.run(gpa, io, .{
        .argv = &.{ bin, "activity", path },
        .stdout_limit = .limited(wire.max_wire_bytes),
    });
}

test "헬퍼 activity 왕복: 저쪽이 훑은 자리·라벨·결말이 파서로 그대로 되읽힌다" {
    const bin = helperBin() orelse return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/maru-rav-rt.{d}.jsonl", .{std.c.getpid()});
    try writeFixture(io, path);
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const out = try runHelper(gpa, io, bin, path);
    defer gpa.free(out.stdout);
    defer gpa.free(out.stderr);
    switch (out.term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.TestUnexpectedResult,
    }

    // ── 로컬 기준선 ────────────────────────────────────────────────────────────────────────
    var local: std.ArrayList(wire.Hit) = .empty;
    defer local.deinit(gpa);
    try scanLocally(gpa, io, path, &local);
    try std.testing.expect(local.items.len >= 3); // Bash · Read · shell

    // ── 원격 wire 를 되읽어 맞댄다 ─────────────────────────────────────────────────────────
    var parser = wire.Parser.init(out.stdout);
    var saw_file = false;
    var saw_flags = false;
    var i: usize = 0;
    var labels: std.ArrayList(wire.Label) = .empty;
    defer labels.deinit(gpa);

    while (try parser.next()) |ev| switch (ev) {
        .file => |cf| {
            try std.testing.expectEqual(@as(u8, 0), cf.index);
            try std.testing.expectEqualStrings(path, cf.path);
            saw_file = true;
        },
        .flags => |fl| {
            // 픽스처는 작아서 상한에 안 닿는다 — 「다 봤다」가 참이어야 한다.
            try std.testing.expect(!fl.partial);
            try std.testing.expect(!fl.activity_partial);
            try std.testing.expect(fl.scanned_bytes > 0);
            saw_flags = true;
        },
        .record => |rec| {
            try std.testing.expect(i < local.items.len);
            // **자리가 바이트 단위로 같다.** 하나라도 다르면 원격 펼침이 엉뚱한 바이트를 읽는다.
            try std.testing.expectEqual(local.items[i], rec.hit);
            try labels.append(gpa, rec.label);
            i += 1;
        },
        .remote_error => |msg| {
            std.debug.print("원격이 실패를 보고했다: {s}\n", .{msg});
            return error.TestUnexpectedResult;
        },
    };

    // **꼬리를 봤어야 한다** — 못 보면 잘린 것이고, 잘린 목록을 그리면 활동이 사라진 것처럼 보인다.
    try std.testing.expect(parser.complete());
    try std.testing.expect(saw_file);
    try std.testing.expect(saw_flags);
    try std.testing.expectEqual(local.items.len, i);

    // ── 라벨이 **실제로 만들어졌는지** ─────────────────────────────────────────────────────
    // 헬퍼가 스캔만 하고 라벨 패스를 빠뜨려도 위까지는 전부 통과한다(라벨이 빈 것은 오류가 아니다).
    // 그 침묵을 여기서 막는다.
    try std.testing.expectEqualStrings("판정자를 돌린다", labels.items[0].text()); // description 이 이긴다(계약 §2.2)
    try std.testing.expectEqualStrings("main.zig", labels.items[1].text()); // 읽기는 basename
    try std.testing.expectEqualStrings("ls -la", labels.items[2].text()); // Codex 는 arguments 안
    // 시각도 저쪽에서 읽는다 — 0 이면 화면이 시각을 안 그린다.
    try std.testing.expect(labels.items[0].time_s > 0);

    // ── 결말(AV2)도 국경을 건넜는지 ────────────────────────────────────────────────────────
    try std.testing.expect(local.items[0].result.found);
    try std.testing.expect(local.items[0].result.failed); // `is_error: true`
}

test "헬퍼 activity: 상대경로는 원격이 거부한다 — 저쪽 cwd 의 다른 파일을 안 연다" {
    const bin = helperBin() orelse return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const out = try runHelper(gpa, io, bin, "relative.jsonl");
    defer gpa.free(out.stdout);
    defer gpa.free(out.stderr);

    var parser = wire.Parser.init(out.stdout);
    var why: ?[]const u8 = null;
    while (try parser.next()) |ev| switch (ev) {
        .remote_error => |msg| why = msg,
        else => {},
    };
    // **「못 읽는다」는 「비었다」와 다르다**(계약 §2.2) — 그 사실이 wire 로 와야 화면이 말할 수 있다.
    //
    // ⚠️ **사유를 구분한다.** 「사유가 있다」만 보면 가드를 빼도 통과한다 — 상대경로는 `openFile` 이
    // 실패해서도 사유가 나기 때문이다(뮤테이션이 그 빈틈을 잡았다 · 적대적 J1). 가드가 **먼저**
    // 막았는지를 묻는다.
    try std.testing.expect(why != null);
    try std.testing.expectEqualStrings("path is not absolute", why.?);
    try std.testing.expect(parser.complete());
}

test "헬퍼 activity: 없는 파일도 사유를 남긴다" {
    const bin = helperBin() orelse return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/maru-rav-missing.{d}.jsonl", .{std.c.getpid()});

    const out = try runHelper(gpa, io, bin, path);
    defer gpa.free(out.stdout);
    defer gpa.free(out.stderr);

    var parser = wire.Parser.init(out.stdout);
    var said_why = false;
    while (try parser.next()) |ev| switch (ev) {
        .remote_error => said_why = true,
        else => {},
    };
    try std.testing.expect(said_why);
    try std.testing.expect(parser.complete());
}
