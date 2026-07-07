//! Trace fixture + CI: 커밋된 replay trace fixture가 (1) **redaction 가드를 통과**하고(민감정보 없음 — git에 안전),
//! (2) `replayTrace`로 재생하면 **golden 화면과 byte-for-byte 일치**함을 CI에서 고정한다. 실제 세션(또는 손수 만든)
//! trace를 회귀 자산으로 승격하는 경로 — replay 결정성·화면 재구성이 깨지면 여기서 잡힌다.
//!
//! golden 갱신: `MARU_UPDATE_GOLDEN=1 zig build test-replay` (fixture를 바꿨을 때 actual을 golden으로 다시 쓴다).
//! fixture는 사람이 읽도록 `\r\n` escape·UTF-8로 쓴다(리터럴 제어바이트 없이). 커밋 전 반드시 guardFixture로 sanitize.

const std = @import("std");
const maru = @import("maru");
const artifacts = @import("test_support");

const Case = struct {
    name: []const u8,
    fixture_path: []const u8,
    golden_path: []const u8,
    /// 첫 resize 전 `TerminalCore.init` 값 — fixture의 첫 resize 이벤트가 곧 실제 크기로 덮어쓴다(trace self-contained).
    init_size: maru.terminal.Size,
};

const cases = [_]Case{
    .{
        .name = "basic-session",
        .fixture_path = "tests/fixtures/traces/basic-session.trace.txt",
        .golden_path = "tests/golden/screen/replay/basic-session.txt",
        .init_size = .{ .cols = 10, .rows = 4 },
    },
};

test "replay trace fixtures: guardFixture 통과 + golden 화면 재구성" {
    for (cases) |case| try compareCase(case);
}

// 증분 flush(크래시 복원)의 파일 경로 검증: TraceRecorder를 실제 file writer에 물려 이벤트마다 flush하면,
// **clean close/sync 없이도**(크래시 시뮬 — 별도 핸들로 되읽음) 디스크에 남아 replay된다. in-memory 유닛 테스트가
// 못 잡는 File.Writer flush→disk 경로를 여기서 확인한다.
test "증분 flush: 파일에 이벤트마다 flush돼 clean close 없이도 재생된다(크래시 복원)" {
    const a = std.testing.allocator;
    const path = ".zig-cache/maru-trace-flush-e2e.trace";
    var buf: [4096]u8 = undefined; // File.Writer 버퍼(테스트 로컬 — writer가 이동하지 않아 안정)

    const file = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{});
    var fw = file.writer(std.testing.io, &buf);
    var rec = maru.app.trace_recorder.TraceRecorder.init(&fw.interface);
    rec.recordResize(1, 10, 4); // 두 줄이 스크롤 없이 다 보이게
    rec.recordOutput(1, "hello\r\n");
    rec.recordOutput(1, "world\r\n");
    // clean close/sync를 **하지 않고**(크래시) 별도 핸들로 읽는다 — 이벤트마다 flush됐으므로 OS에 남아 있다.
    const content = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(64 * 1024));
    defer a.free(content);

    var replayed = try maru.observability.replay.replayTrace(a, content, .{ .cols = 10, .rows = 4 });
    defer replayed.deinit();
    const screen = try replayed.dumpUtf8(a);
    defer a.free(screen);
    try std.testing.expect(std.mem.indexOf(u8, screen, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, screen, "world") != null);

    file.close(std.testing.io); // 정리
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
}

// 가드가 실제로 커밋을 막는지 — 민감 데이터가 든 trace는 fixture로 저장되기 전 거부돼야 한다(위 compareCase가
// clean fixture를 통과시키는 것과 대칭). 여기 fixture로 커밋하지 않고 인라인으로 확인한다.
test "fixture redaction 가드: 민감 데이터가 있는 trace는 거부된다" {
    const a = std.testing.allocator;
    const dirty =
        "maru.trace.v1\n" ++
        "event 0 output surface=1 bytes=\"$ export API_TOKEN=sk-live-abc\\r\\n\"\n";
    try std.testing.expectError(error.SensitiveContent, maru.observability.trace.guardFixture(a, dirty));
}

fn compareCase(case: Case) !void {
    const a = std.testing.allocator;

    const fixture = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, case.fixture_path, a, .limited(64 * 1024));
    defer a.free(fixture);

    // 커밋된 fixture는 민감정보가 없어야 한다 — 재조립 가드가 통과해야 commit-safe.
    maru.observability.trace.guardFixture(a, fixture) catch |e| {
        std.debug.print("fixture가 redaction 가드에 걸림(민감정보 제거 필요): {s} — {s}\n", .{ case.fixture_path, @errorName(e) });
        return e;
    };

    // 재생 → 화면.
    var core = try maru.observability.replay.replayTrace(a, fixture, case.init_size);
    defer core.deinit();
    const actual = try core.dumpUtf8(a);
    defer a.free(actual);

    if (std.c.getenv("MARU_UPDATE_GOLDEN") != null) {
        try artifacts.writeTextWithFinalNewline(a, case.golden_path, actual);
        return;
    }

    const expected = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, case.golden_path, a, .limited(64 * 1024));
    defer a.free(expected);
    errdefer std.debug.print("replay fixture mismatch: {s} (MARU_UPDATE_GOLDEN=1로 갱신)\n", .{case.name});
    try std.testing.expectEqualStrings(goldenText(expected), actual);
}

/// golden 파일은 에디터 친화적으로 끝에 개행 하나를 두지만, dumpUtf8은 행을 개행으로만 잇는다 — 마지막 파일 개행
/// 하나만 떼고 셀의 의미 있는 trailing space는 보존한다(recorded.zig와 같은 규칙).
fn goldenText(text: []const u8) []const u8 {
    if (text.len > 0 and text[text.len - 1] == '\n') return text[0 .. text.len - 1];
    return text;
}
