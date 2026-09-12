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

/// ⚠️ **여기의 stdin 이 곧 제품 전송의 모양이다.** `std.process.run` 은 자식에게 stdin 을 안 준다
/// (`/dev/null` 상당). 이 축의 전송(`ssh_upload.runArgvCapped`)도 자식의 fd 0 을 **닫는다** — 그래서
/// 「stdin 이 말하면 채널이 끊긴 것」으로 읽는 순진한 구현은 **정상 호출에서 레코드를 0 개** 낸다
/// (적대적 M2 · 리눅스 실측 3.6 MB → 33 B). 아래 `expectEqual(local.items.len, i)` 가 그 회귀를 잡는다.
///
/// ⚠️ **그런데 macOS 에서는 안 잡힌다**(적대적 M3): 이 플랫폼의 `/dev/null` 은 `POLL.IN` 을 안 세워
/// 오탐이 애초에 안 난다. **이 게이트의 그 단언은 리눅스 CI 에서만 문다** — 로컬 초록을 「봤다」로
/// 읽지 말 것.
fn runHelper(gpa: std.mem.Allocator, io: std.Io, bin: []const u8, path: []const u8) !std.process.RunResult {
    return std.process.run(gpa, io, .{
        .argv = &.{ bin, "activity", path },
        .stdout_limit = .limited(wire.max_wire_bytes),
    });
}

/// **이어읽기 요청**(RAV7b-3 · 판 12) — 그 자리부터 머리 파일만 훑는다.
fn runHelperFrom(gpa: std.mem.Allocator, io: std.Io, bin: []const u8, path: []const u8, from: u64) !std.process.RunResult {
    var buf: [24]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{d}", .{from});
    return std.process.run(gpa, io, .{
        .argv = &.{ bin, "activity", path, "--from", text },
        .stdout_limit = .limited(wire.max_wire_bytes),
    });
}

/// wire 를 통째로 되읽어 자리·라벨·플래그를 모은다. 이어읽기 판정자들이 **두 답을 맞대기** 위해 쓴다.
const Parsed = struct {
    hits: std.ArrayList(wire.Hit) = .empty,
    labels: std.ArrayList(wire.Label) = .empty,
    flags: wire.ScanFlags = .{},
    files: usize = 0,

    fn deinit(self: *Parsed, gpa: std.mem.Allocator) void {
        self.hits.deinit(gpa);
        self.labels.deinit(gpa);
    }
};

fn parseAll(gpa: std.mem.Allocator, bytes: []const u8) !Parsed {
    var out: Parsed = .{};
    errdefer out.deinit(gpa);
    var parser = wire.Parser.init(bytes);
    while (try parser.next()) |ev| switch (ev) {
        .file => out.files += 1,
        .flags => |fl| out.flags = fl,
        .record => |rec| {
            try out.hits.append(gpa, rec.hit);
            try out.labels.append(gpa, rec.label);
        },
        .remote_error => |msg| {
            std.debug.print("원격이 실패를 보고했다: {s}\n", .{msg});
            return error.TestUnexpectedResult;
        },
    };
    if (!parser.complete()) return error.TestUnexpectedResult;
    return out;
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
    var flags: wire.ScanFlags = .{};
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
            flags = fl;
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

    // ── 판 2 의 자국 둘(RAV7b) ────────────────────────────────────────────────────────────
    // **머리 파일이 읽힌 바이트**. 체인이 하나라 `scanned_bytes` 와 같지만, **다른 값으로 실려야**
    // 한다 — 헬퍼가 이 칸을 안 채우면 0 이고 신선도가 통째로 꺼진다(RAV7a 적대적 S1).
    const size = (try std.Io.Dir.cwd().statFile(io, path, .{})).size;
    try std.testing.expectEqual(size, flags.head_bytes);

    // **이어읽기 자국이 미결 호출까지 되돌아야 한다.** 픽스처의 셋째 줄(`toolu_02` Read)은 결과가
    // 없다 — 자국이 파일 끝이면 다음 회차가 그 결말을 영영 못 붙이고 「진행중」이 남는다(§19.2).
    try std.testing.expect(flags.resume_offset < flags.head_bytes);
    try std.testing.expectEqual(local.items[1].line_offset, flags.resume_offset);
}

test "헬퍼 activity: 미결 호출이 없으면 자국이 곧 읽은 데까지다 (RAV7b)" {
    // 🔥 적대적 C2: 위 왕복 판정자는 **미결 호출이 있는** 픽스처만 태운다 — 그러면 헬퍼가 자국을
    // 「언제나 가장 이른 활동 줄」로 내도 안 걸리고, **자랄 때마다 파일을 통째로 다시 훑는다**
    // (이 슬라이스가 없애려던 그것). 되돌릴 이유가 없을 때 **안 되돌리는지**를 여기서 본다.
    const bin = helperBin() orelse return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/maru-rav7b-done.{d}.jsonl", .{std.c.getpid()});
    const f = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    // 호출 하나 · 그 결말 하나 — **기다리는 것이 없다**.
    const body =
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_01","name":"Bash","input":{"command":"echo hi"}}]}}
        \\{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"hi","tool_use_id":"toolu_01"}]}}
        \\
    ;
    _ = try f.writePositional(io, &.{body}, 0);
    f.close(io);

    const out = try runHelper(gpa, io, bin, path);
    defer gpa.free(out.stdout);
    defer gpa.free(out.stderr);

    var parser = wire.Parser.init(out.stdout);
    var flags: wire.ScanFlags = .{};
    while (try parser.next()) |ev| switch (ev) {
        .flags => |fl| flags = fl,
        .remote_error => |msg| {
            std.debug.print("원격이 실패를 보고했다: {s}\n", .{msg});
            return error.TestUnexpectedResult;
        },
        else => {},
    };
    try std.testing.expect(parser.complete());

    const size = (try std.Io.Dir.cwd().statFile(io, path, .{})).size;
    try std.testing.expectEqual(size, flags.head_bytes);
    // **되돌리지 않았다.** 마지막 줄이 개행으로 끝나므로 `consumed` 가 곧 파일 끝이다.
    try std.testing.expectEqual(size, flags.resume_offset);
}

test "헬퍼 activity: 미완 줄은 자국 밖이다 — 반쪽 줄을 활동으로 세지 않는다 (RAV7b)" {
    // 마지막 줄이 개행 없이 끝나면 그 줄은 **아직 안 본 것**이다. 자국이 파일 끝이면 다음 회차가
    // 그 줄을 건너뛰어 **그 활동이 영영 사라진다**(§4.2 의 `last_offset` 규율).
    const bin = helperBin() orelse return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/maru-rav7b-partial.{d}.jsonl", .{std.c.getpid()});
    const f = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    const complete =
        \\{"type":"assistant","message":{"content":[{"type":"text","text":"a"}]}}
    ;
    const half = "{\"type\":\"assis";
    var at: u64 = 0;
    at += try f.writePositional(io, &.{complete}, at);
    at += try f.writePositional(io, &.{"\n"}, at);
    _ = try f.writePositional(io, &.{half}, at);
    f.close(io);

    const out = try runHelper(gpa, io, bin, path);
    defer gpa.free(out.stdout);
    defer gpa.free(out.stderr);

    var parser = wire.Parser.init(out.stdout);
    var flags: wire.ScanFlags = .{};
    while (try parser.next()) |ev| switch (ev) {
        .flags => |fl| flags = fl,
        else => {},
    };
    try std.testing.expect(parser.complete());

    // **읽기는 파일 끝까지 갔지만** 자국은 개행 다음에서 멈춘다.
    try std.testing.expectEqual(@as(u64, complete.len + 1 + half.len), flags.head_bytes);
    try std.testing.expectEqual(@as(u64, complete.len + 1), flags.resume_offset);
}

test "헬퍼 activity --from: 이어읽은 자리가 통째로 훑은 것과 «바이트까지» 같다 (RAV7b-3)" {
    // 🔥 **이 슬라이스의 핵심 계약이다.** 이어읽기가 통째 스캔과 다른 자리를 내면 펼침이 엉뚱한
    // 바이트를 읽고 그림이 깨진다(계약 §2.1 — 오프셋은 파일 절대값이다). 같은 파일을 두 번 물어
    // **자국 뒤의 히트가 바이트까지 일치**하는지 본다.
    const bin = helperBin() orelse return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/maru-rav7b3-eq.{d}.jsonl", .{std.c.getpid()});
    try writeFixture(io, path);
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    // ── ① 통째로 훑어 기준선을 만든다.
    const full_out = try runHelper(gpa, io, bin, path);
    defer gpa.free(full_out.stdout);
    defer gpa.free(full_out.stderr);
    var full = try parseAll(gpa, full_out.stdout);
    defer full.deinit(gpa);
    try std.testing.expect(full.hits.items.len >= 3);
    try std.testing.expectEqual(@as(u64, 0), full.flags.resumed_from); // 처음부터 읽었다

    // ── ② 첫 히트의 줄 자리부터 이어 읽는다. 그 앞은 안 읽으므로 히트가 **하나 이상 줄어야** 한다.
    const from = full.hits.items[1].line_offset;
    const part_out = try runHelperFrom(gpa, io, bin, path, from);
    defer gpa.free(part_out.stdout);
    defer gpa.free(part_out.stderr);
    var part = try parseAll(gpa, part_out.stdout);
    defer part.deinit(gpa);

    // **요청을 지켰다.**
    try std.testing.expectEqual(from, part.flags.resumed_from);
    // **체인 줄은 그대로 전부 낸다**(§20.2) — 안 그러면 부모 히트의 `file_index` 가 갈 곳을 잃는다.
    try std.testing.expectEqual(full.files, part.files);
    // **머리 파일 크기는 같다** — 시작점을 더해야 신선도(RAV7a)가 산다.
    try std.testing.expectEqual(full.flags.head_bytes, part.flags.head_bytes);
    // **읽은 바이트는 줄었다** — 그것이 이 슬라이스의 값이다.
    try std.testing.expect(part.flags.scanned_bytes < full.flags.scanned_bytes);

    // ── ③ 🔥 **자국 뒤의 히트가 바이트까지 같다.**
    //
    // ⚠️ **이 픽스처에는 이미지가 없다** — 그래서 `fold_owner`(접기 주인)가 안 갈린다. 그 값은
    // **배열 자리**라 이어읽기에서 반드시 달라지고, 그 축은 아래 판정자가 따로 문다(적대적 9).
    try std.testing.expectEqual(full.hits.items.len - 1, part.hits.items.len);
    for (part.hits.items, 0..) |h, i| {
        try std.testing.expectEqual(full.hits.items[i + 1], h);
        try std.testing.expectEqualStrings(full.labels.items[i + 1].text(), part.labels.items[i].text());
    }
}

test "헬퍼 activity --from: 접기 주인은 «배열 자리»라 달라진다 — 오프셋은 같다 (RAV7b-3)" {
    // 🔥 적대적 9: 위 판정자는 「바이트까지 같다」고 단언하는데 **이미지가 있으면 그것이 거짓**이다.
    // `fold_owner` 는 `out` 배열의 **인덱스**이고(스캐너 `fold_owner = idx`), 이어읽기는 배열이
    // 짧으므로 같은 이미지가 **다른 값**을 받는다.
    //
    // **그래서 RAV7b-3b 가 병합할 때 remap 해야 한다** — 안 하면 접힌 이미지가 **엉뚱한 호출로
    // 접히거나** 「전체」에서 통째로 사라진다(퇴출이 같은 이유로 `remapFoldsAfterEvict` 를 둔다).
    // 이 판정자는 그 사실을 **계약으로 고정**한다: 자리는 갈리고 **오프셋은 안 갈린다**.
    const bin = helperBin() orelse return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/maru-rav7b3-fold.{d}.jsonl", .{std.c.getpid()});
    const f = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    const first =
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_X","name":"Bash","input":{"command":"first"}}]}}
    ;
    const rest =
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_A","name":"Read","input":{"file_path":"/x.png"}}]}}
        \\{"type":"user","message":{"content":[{"tool_use_id":"toolu_A","type":"tool_result","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"AAAA"}}]}]}}
        \\
    ;
    var at: u64 = 0;
    at += try f.writePositional(io, &.{first}, at);
    at += try f.writePositional(io, &.{"\n"}, at);
    const from = at; // 둘째 줄이 시작하는 자리
    _ = try f.writePositional(io, &.{rest}, at);
    f.close(io);

    const full_out = try runHelper(gpa, io, bin, path);
    defer gpa.free(full_out.stdout);
    defer gpa.free(full_out.stderr);
    var full = try parseAll(gpa, full_out.stdout);
    defer full.deinit(gpa);

    const part_out = try runHelperFrom(gpa, io, bin, path, from);
    defer gpa.free(part_out.stdout);
    defer gpa.free(part_out.stderr);
    var part = try parseAll(gpa, part_out.stdout);
    defer part.deinit(gpa);

    try std.testing.expectEqual(from, part.flags.resumed_from);
    try std.testing.expectEqual(@as(usize, 3), full.hits.items.len); // Bash · Read · 이미지
    try std.testing.expectEqual(@as(usize, 2), part.hits.items.len); //        Read · 이미지

    // 이미지는 마지막이다. **주인은 갈린다** — 통째에서는 자리 1, 이어읽기에서는 자리 0.
    const full_img = full.hits.items[2];
    const part_img = part.hits.items[1];
    try std.testing.expect(full_img.fold_owner != part_img.fold_owner);
    try std.testing.expectEqual(@as(u32, 1), full_img.fold_owner);
    try std.testing.expectEqual(@as(u32, 0), part_img.fold_owner);

    // 🔥 **오프셋은 안 갈린다.** 파일 절대값이므로 — 이것이 깨지면 펼침·디코드가 엉뚱한 바이트를
    // 읽는다(계약 §2.1).
    try std.testing.expectEqual(full_img.line_offset, part_img.line_offset);
    try std.testing.expectEqual(full_img.data_offset, part_img.data_offset);
    try std.testing.expectEqual(full_img.data_len, part_img.data_len);
    // 주인 호출의 결과(이미지 자리)도 같은 바이트를 가리킨다.
    try std.testing.expectEqual(full.hits.items[1].result.image_offset, part.hits.items[0].result.image_offset);
}

test "헬퍼 activity --from: 자란 구간에 활동이 없으면 «0 건»이다 — 못 읽은 것이 아니다 (RAV7b-3)" {
    // 적대적 11: 자란 구간이 텍스트뿐이면 히트가 0 이다. 그것은 **「활동이 없다」**이지 실패가
    // 아니고, `resumed_from` 이 그 사실을 말한다 — 받는 쪽은 **앞 히트를 그대로 두고** 0 건을
    // 더해야 한다. 목록을 갈아 끼우면 화면이 **빈다**(RAV7b-3b 가 지킬 계약이다).
    const bin = helperBin() orelse return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/maru-rav7b3-empty.{d}.jsonl", .{std.c.getpid()});
    const f = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    const call =
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_X","name":"Bash","input":{"command":"first"}}]}}
    ;
    const text =
        \\{"type":"assistant","message":{"content":[{"type":"text","text":"활동이 아닌 줄"}]}}
    ;
    var at: u64 = 0;
    at += try f.writePositional(io, &.{call}, at);
    at += try f.writePositional(io, &.{"\n"}, at);
    const from = at;
    at += try f.writePositional(io, &.{text}, at);
    _ = try f.writePositional(io, &.{"\n"}, at);
    f.close(io);

    const out = try runHelperFrom(gpa, io, bin, path, from);
    defer gpa.free(out.stdout);
    defer gpa.free(out.stderr);
    var got = try parseAll(gpa, out.stdout);
    defer got.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), got.hits.items.len); // 0 건
    try std.testing.expectEqual(from, got.flags.resumed_from); // **이어읽었다**
    try std.testing.expect(!got.flags.partial); // 「못 봤다」가 아니다
    // 파일 크기는 그대로 — 신선도가 여기서 1 바이트를 청한다.
    const size = (try std.Io.Dir.cwd().statFile(io, path, .{})).size;
    try std.testing.expectEqual(size, got.flags.head_bytes);
}

test "헬퍼 activity --from: 파일보다 뒤를 청하면 처음부터 훑는다 — 빈 목록을 만들지 않는다 (RAV7b-3)" {
    // 🔥 적대적: 저쪽에서 파일이 잘리면 자국이 파일보다 커진다. 그 자리에서 읽으면 **0 바이트**이고
    // 받는 쪽은 그것을 「활동이 없다」로 읽어 **화면이 빈 목록**이 된다(계약 §2.2 가 금지하는 거짓).
    // 헬퍼가 요청을 **거절하고** 처음부터 훑어야 하며, `resumed_from = 0` 이 그 사실을 말한다.
    const bin = helperBin() orelse return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/maru-rav7b3-past.{d}.jsonl", .{std.c.getpid()});
    try writeFixture(io, path);
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const size = (try std.Io.Dir.cwd().statFile(io, path, .{})).size;
    const out = try runHelperFrom(gpa, io, bin, path, size + 4096);
    defer gpa.free(out.stdout);
    defer gpa.free(out.stderr);
    var got = try parseAll(gpa, out.stdout);
    defer got.deinit(gpa);

    try std.testing.expectEqual(@as(u64, 0), got.flags.resumed_from); // 거절했다
    try std.testing.expect(got.hits.items.len >= 3); // 그래서 목록이 비지 않는다
    try std.testing.expectEqual(size, got.flags.head_bytes);
}

test "헬퍼 activity --from: 이어읽기는 부모를 안 연다 — 그래도 체인 줄은 전부 낸다 (RAV7b-3)" {
    // **이득의 절반이 여기 있다**(부모 크기 중앙 338 MB · 최대 1.8 GB). 그런데 `F` 줄까지 빼면
    // 받는 쪽의 체인이 부모를 잃고 **부모 히트의 `file_index` 가 가리킬 자리가 없어진다**(§20.2).
    const bin = helperBin() orelse return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var home_buf: [64]u8 = undefined;
    const home = try std.fmt.bufPrint(&home_buf, "/tmp/maru-rav7b3.{d}", .{std.c.getpid()});
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
    std.Io.Dir.cwd().deleteTree(io, home) catch {};

    var day_buf: [96]u8 = undefined;
    const day = try std.fmt.bufPrint(&day_buf, "{s}/.codex/sessions/2026/09/11", .{home});
    try std.Io.Dir.cwd().createDirPath(io, day);
    var dir = try std.Io.Dir.cwd().openDir(io, day, .{});
    defer dir.close(io);

    var parent_name_buf: [128]u8 = undefined;
    const parent_name = try std.fmt.bufPrint(&parent_name_buf, "rollout-2026-09-11T01-00-00-{s}.jsonl", .{parent_id});
    try writeRollout(io, dir, parent_name, parent_lines);
    var child_name_buf: [128]u8 = undefined;
    const child_name = try std.fmt.bufPrint(&child_name_buf, "rollout-2026-09-11T02-00-00-{s}.jsonl", .{child_id});
    try writeRollout(io, dir, child_name, child_lines);

    var child_path_buf: [256]u8 = undefined;
    const child_path = try std.fmt.bufPrint(&child_path_buf, "{s}/{s}", .{ day, child_name });

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("HOME", home);
    try env.put("PATH", "/usr/bin:/bin");

    const out = try std.process.run(gpa, io, .{
        .argv = &.{ bin, "activity", child_path, "--from", "1" },
        .stdout_limit = .limited(wire.max_wire_bytes),
        .environ_map = &env,
    });
    defer gpa.free(out.stdout);
    defer gpa.free(out.stderr);
    var got = try parseAll(gpa, out.stdout);
    defer got.deinit(gpa);

    // **체인 줄 둘은 그대로 온다.**
    try std.testing.expectEqual(@as(usize, 2), got.files);
    try std.testing.expectEqual(@as(u64, 1), got.flags.resumed_from);
    // **부모 자리(1)의 히트는 하나도 없다** — 안 열었으니까.
    for (got.hits.items) |h| try std.testing.expectEqual(@as(u8, 0), h.file_index);
    // **`scanned_bytes` 는 자식만큼이다** — 부모를 훑었으면 그보다 컸다.
    const child_size = (try std.Io.Dir.cwd().statFile(io, child_path, .{})).size;
    try std.testing.expect(got.flags.scanned_bytes < child_size);
    // 머리 크기는 여전히 자식 파일 전체다(신선도가 그것으로 판정한다).
    try std.testing.expectEqual(child_size, got.flags.head_bytes);
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

// ── RAV4: 체인 ──────────────────────────────────────────────────────────────────────────────────

const parent_id = "01a06c6f-f62e-7122-a3ee-fb6ed992f2d1";
const child_id = "01a070f0-3d4d-7ca3-8fcc-509b99ed18f0";

/// 부모 rollout — 활동 하나가 여기 있고, **자식에는 없다**. 체인이 안 풀리면 이 활동이 통째로 사라진다.
const parent_lines =
    \\{"timestamp":"2026-09-11T01:00:00.000Z","ordinal":0,"type":"session_meta","payload":{"session_id":"01a06c6f-f62e-7122-a3ee-fb6ed992f2d1","id":"01a06c6f-f62e-7122-a3ee-fb6ed992f2d1"}}
    \\{"timestamp":"2026-09-11T01:00:01.000Z","type":"function_call","name":"shell","call_id":"call_parent","arguments":"{\"command\":\"부모에서 돌린 것\"}"}
;

/// 자식 rollout — `session_meta` 가 부모를 가리킨다(실측 모양: `forked_from_id` 와 `parent_thread_id`
/// 가 같은 값으로 함께 온다).
const child_lines =
    \\{"timestamp":"2026-09-11T02:00:00.000Z","ordinal":0,"type":"session_meta","payload":{"session_id":"01a070f0-3d4d-7ca3-8fcc-509b99ed18f0","forked_from_id":"01a06c6f-f62e-7122-a3ee-fb6ed992f2d1","parent_thread_id":"01a06c6f-f62e-7122-a3ee-fb6ed992f2d1"}}
    \\{"timestamp":"2026-09-11T02:00:01.000Z","type":"function_call","name":"shell","call_id":"call_child","arguments":"{\"command\":\"자식에서 돌린 것\"}"}
;

fn writeRollout(io: std.Io, dir: std.Io.Dir, name: []const u8, body: []const u8) !void {
    const f = try dir.createFile(io, name, .{ .truncate = true });
    defer f.close(io);
    var at: u64 = 0;
    at += try f.writePositional(io, &.{body}, at);
    _ = try f.writePositional(io, &.{"\n"}, at);
}

test "헬퍼 activity: 재개 세션은 부모 rollout 까지 훑는다 (RAV4)" {
    // **체인이 안 풀리면 부모의 활동이 통째로 사라진다**(계약 §3.3 — 로컬에서 실측 90 파일 중 20 개가
    // 그랬다). 저쪽 파일시스템을 훑는 일이라 **헬퍼가** 푼다 — 로컬 `buildChain` 을 원격 경로에 대고
    // 부르면 이쪽 디렉터리를 뒤진다(계약 §2.1).
    const bin = helperBin() orelse return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // 헬퍼는 `$HOME/.codex/sessions` 를 본다 — 가짜 HOME 을 준다.
    var home_buf: [64]u8 = undefined;
    const home = try std.fmt.bufPrint(&home_buf, "/tmp/maru-rav4.{d}", .{std.c.getpid()});
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
    std.Io.Dir.cwd().deleteTree(io, home) catch {};

    var day_buf: [96]u8 = undefined;
    const day = try std.fmt.bufPrint(&day_buf, "{s}/.codex/sessions/2026/09/11", .{home});
    try std.Io.Dir.cwd().createDirPath(io, day);
    var dir = try std.Io.Dir.cwd().openDir(io, day, .{});
    defer dir.close(io);

    var parent_name_buf: [128]u8 = undefined;
    const parent_name = try std.fmt.bufPrint(&parent_name_buf, "rollout-2026-09-11T01-00-00-{s}.jsonl", .{parent_id});
    try writeRollout(io, dir, parent_name, parent_lines);

    var child_name_buf: [128]u8 = undefined;
    const child_name = try std.fmt.bufPrint(&child_name_buf, "rollout-2026-09-11T02-00-00-{s}.jsonl", .{child_id});
    try writeRollout(io, dir, child_name, child_lines);

    var child_path_buf: [256]u8 = undefined;
    const child_path = try std.fmt.bufPrint(&child_path_buf, "{s}/{s}", .{ day, child_name });

    // `HOME` 을 갈아 끼워 헬퍼를 돌린다.
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("HOME", home);
    try env.put("PATH", "/usr/bin:/bin");
    const out = try std.process.run(gpa, io, .{
        .argv = &.{ bin, "activity", child_path },
        .stdout_limit = .limited(wire.max_wire_bytes),
        .environ_map = &env,
    });
    defer gpa.free(out.stdout);
    defer gpa.free(out.stderr);

    var parser = wire.Parser.init(out.stdout);
    var files: usize = 0;
    var saw_parent_file = false;
    var saw_parent_activity = false;
    var saw_child_activity = false;
    var flags: wire.ScanFlags = .{};
    while (try parser.next()) |ev| switch (ev) {
        .flags => |fl| flags = fl,
        .file => |cf| {
            files += 1;
            if (std.mem.endsWith(u8, cf.path, parent_name)) {
                saw_parent_file = true;
                // **자리 번호가 곧 `file_index` 다** — 머리가 0, 부모가 1 이어야 한다.
                try std.testing.expectEqual(@as(u8, 1), cf.index);
            }
        },
        .record => |rec| {
            if (std.mem.eql(u8, rec.label.text(), "부모에서 돌린 것")) {
                saw_parent_activity = true;
                // 부모의 활동은 **부모 자리**를 가리켜야 한다. 첫 파일로 고정하면 소비자가 엉뚱한
                // 바이트를 읽는다.
                try std.testing.expectEqual(@as(u8, 1), rec.hit.file_index);
            }
            if (std.mem.eql(u8, rec.label.text(), "자식에서 돌린 것")) {
                saw_child_activity = true;
                try std.testing.expectEqual(@as(u8, 0), rec.hit.file_index);
            }
        },
        .remote_error => |msg| {
            std.debug.print("원격이 실패를 보고했다: {s}\n", .{msg});
            return error.TestUnexpectedResult;
        },
    };

    try std.testing.expect(parser.complete());
    try std.testing.expectEqual(@as(usize, 2), files);
    try std.testing.expect(saw_parent_file);
    try std.testing.expect(saw_child_activity);
    try std.testing.expect(saw_parent_activity);

    // ── 🔥 **자국은 머리 파일의 것이다**(RAV7b — RAV7a 적대적 S1 을 고치는 자리) ──────────────
    // `scanned_bytes` 는 **체인 전체의 합**이라 자식보다 크다. 신선도가 그 값으로 자식 파일의 그
    // 자리를 물으면 **영영 빈 답**이고, 재개 세션(실측 58%)은 신선도가 통째로 죽는다.
    var child_size_buf: [256]u8 = undefined;
    const child_abs = try std.fmt.bufPrint(&child_size_buf, "{s}/{s}", .{ day, child_name });
    const child_size = (try std.Io.Dir.cwd().statFile(io, child_abs, .{})).size;
    try std.testing.expectEqual(child_size, flags.head_bytes);
    try std.testing.expect(flags.scanned_bytes > flags.head_bytes); // 부모까지 훑었다
}

test "헬퍼 activity: 부모 id 로 «끝나기만» 하는 파일에는 안 속는다 (RAV4)" {
    // 🔥 `findCodexByThreadId` 는 단순 `endsWith` 다. 그대로 믿으면 `…-Xparent-id.jsonl` 이
    // `parent-id` 의 것으로 잡혀 **엉뚱한 파일이 부모가 된다** — 헬퍼 주석이 그 위험을 적어 두었는데
    // 판정자가 그 상황을 **안 만들고 있었다**(적대적 O1: 가드를 없애도 4/4 가 통과했다).
    //
    // 여기서는 **진짜 부모를 안 만든다.** 함정만 둔다 — 가드가 있으면 체인이 안 늘고(`F` 하나),
    // 없으면 함정을 부모로 잡는다(`F` 둘).
    const bin = helperBin() orelse return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var home_buf: [64]u8 = undefined;
    const home = try std.fmt.bufPrint(&home_buf, "/tmp/maru-rav4t.{d}", .{std.c.getpid()});
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
    std.Io.Dir.cwd().deleteTree(io, home) catch {};

    var day_buf: [96]u8 = undefined;
    const day = try std.fmt.bufPrint(&day_buf, "{s}/.codex/sessions/2026/09/11", .{home});
    try std.Io.Dir.cwd().createDirPath(io, day);
    var dir = try std.Io.Dir.cwd().openDir(io, day, .{});
    defer dir.close(io);

    // **구분자가 아닌 글자**가 부모 id 앞에 붙은 함정. `endsWith` 만으로는 못 가린다.
    var trap_buf: [128]u8 = undefined;
    const trap_name = try std.fmt.bufPrint(&trap_buf, "rollout-2026-09-11T00-00-00-X{s}.jsonl", .{parent_id});
    try writeRollout(io, dir, trap_name, parent_lines);

    var child_name_buf: [128]u8 = undefined;
    const child_name = try std.fmt.bufPrint(&child_name_buf, "rollout-2026-09-11T02-00-00-{s}.jsonl", .{child_id});
    try writeRollout(io, dir, child_name, child_lines);

    var child_path_buf: [256]u8 = undefined;
    const child_path = try std.fmt.bufPrint(&child_path_buf, "{s}/{s}", .{ day, child_name });

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("HOME", home);
    try env.put("PATH", "/usr/bin:/bin");
    const out = try std.process.run(gpa, io, .{
        .argv = &.{ bin, "activity", child_path },
        .stdout_limit = .limited(wire.max_wire_bytes),
        .environ_map = &env,
    });
    defer gpa.free(out.stdout);
    defer gpa.free(out.stderr);

    var parser = wire.Parser.init(out.stdout);
    var files: usize = 0;
    var saw_trap = false;
    while (try parser.next()) |ev| switch (ev) {
        .file => |cf| {
            files += 1;
            if (std.mem.endsWith(u8, cf.path, trap_name)) saw_trap = true;
        },
        else => {},
    };

    try std.testing.expect(parser.complete());
    try std.testing.expect(!saw_trap);
    try std.testing.expectEqual(@as(usize, 1), files); // 머리 하나 — 함정은 부모가 아니다
}

// ── RAV5: 구간 읽기 ─────────────────────────────────────────────────────────────────────────────

fn runRead(gpa: std.mem.Allocator, io: std.Io, bin: []const u8, path: []const u8, off: u64, len: u64) !std.process.RunResult {
    var off_buf: [24]u8 = undefined;
    var len_buf: [24]u8 = undefined;
    return std.process.run(gpa, io, .{
        .argv = &.{
            bin,
            "read",
            path,
            try std.fmt.bufPrint(&off_buf, "{d}", .{off}),
            try std.fmt.bufPrint(&len_buf, "{d}", .{len}),
        },
        .stdout_limit = .limited(wire.max_range_wire_bytes),
    });
}

/// 범위 답에서 바이트를 꺼낸다. 완결이 아니면 null — 잘린 답을 온전한 척 읽지 않는다.
fn rangeBytes(out: []const u8) ??[]const u8 {
    var p = wire.RangeParser.init(out);
    var found: ?[]const u8 = null;
    while (p.next() catch return null) |ev| switch (ev) {
        .bytes => |b| found = b,
        .remote_error => return @as(??[]const u8, null),
    };
    if (!p.complete()) return null;
    return found;
}

test "헬퍼 read: 그 구간의 바이트만 돌려준다 (RAV5)" {
    // 활동 wire 는 **자리만** 싣는다(계약 §2.4) — 펼침이 보여 줄 바이트는 이 문으로 당겨온다.
    const bin = helperBin() orelse return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/maru-rav5.{d}.txt", .{std.c.getpid()});
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    // **개행과 NUL 을 넣는다** — 길이 접두가 그것을 견디는지가 이 wire 의 존재 이유다.
    const body = "0123456789\nabc\x00def";
    {
        const f = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
        defer f.close(io);
        _ = try f.writePositional(io, &.{body}, 0);
    }

    {
        const out = try runRead(gpa, io, bin, path, 11, 7); // "abc\x00def"의 앞 7 바이트
        defer gpa.free(out.stdout);
        defer gpa.free(out.stderr);
        const got = rangeBytes(out.stdout) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings("abc\x00def", got.?);
    }

    // **요청보다 짧은 답은 오류가 아니다** — 파일 끝이다. 그 차이로 받는 쪽이 「그새 잘렸다」를 안다.
    {
        const out = try runRead(gpa, io, bin, path, 11, 9999);
        defer gpa.free(out.stdout);
        defer gpa.free(out.stderr);
        const got = rangeBytes(out.stdout) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(usize, 7), got.?.len);
    }

    // **파일 끝 뒤를 물으면 빈 답이다** — 「없다」이지 「못 읽었다」가 아니다.
    {
        const out = try runRead(gpa, io, bin, path, 9999, 8);
        defer gpa.free(out.stdout);
        defer gpa.free(out.stderr);
        const got = rangeBytes(out.stdout) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(usize, 0), got.?.len);
    }
}

test "헬퍼 read: 못 읽는 것은 사유를 남긴다 (RAV5)" {
    const bin = helperBin() orelse return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var missing_buf: [64]u8 = undefined;
    const missing = try std.fmt.bufPrint(&missing_buf, "/tmp/maru-rav5-none.{d}", .{std.c.getpid()});

    const cases = [_]struct { path: []const u8, off: u64, len: u64, want: []const u8 }{
        // 상대경로 — 저쪽 cwd 의 **다른 파일**을 안 연다(`activity` 와 같은 규율).
        .{ .path = "rel.txt", .off = 0, .len = 4, .want = "path is not absolute" },
        // 상한 초과는 **거절한다** — 잘라서 주면 받는 쪽이 「파일 끝」과 구분하지 못한다.
        .{ .path = "/etc/hosts", .off = 0, .len = wire.max_range_bytes + 1, .want = "length above limit" },
        .{ .path = missing, .off = 0, .len = 4, .want = "open failed: FileNotFound" },
    };

    for (cases) |c| {
        const out = try runRead(gpa, io, bin, c.path, c.off, c.len);
        defer gpa.free(out.stdout);
        defer gpa.free(out.stderr);

        var p = wire.RangeParser.init(out.stdout);
        var why: ?[]const u8 = null;
        while (try p.next()) |ev| switch (ev) {
            .remote_error => |msg| why = msg,
            .bytes => return error.TestUnexpectedResult, // 못 읽는데 바이트를 주면 안 된다
        };
        try std.testing.expect(why != null);
        try std.testing.expectEqualStrings(c.want, why.?);
        try std.testing.expect(p.complete());
    }
}
