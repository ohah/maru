const std = @import("std");
const maru = @import("maru");
const artifacts = @import("test_support");
const case_manifest = @import("cases.zig");

const RecordedOracle = struct {
    name: []const u8,
    source: []const u8,
    expected_screen: []const u8,
};

const Case = struct {
    name: []const u8,
    size: maru.terminal.Size,
    input_fixture_path: []const u8,
    write_chunks: ?[]const usize = null,
    oracles: []const RecordedOracle,
};

test "recorded terminal oracle snapshots match Maru output" {
    // This POC compares Maru against recorded oracle snapshots instead of
    // running xterm/libvterm/Alacritty directly. That keeps the default test
    // path deterministic while preserving the shape we need for real oracle
    // runners later.
    const cases = [_]Case{
        .{
            .name = "split_utf8",
            .size = .{ .cols = 12, .rows = 1 },
            .input_fixture_path = "tests/fixtures/ansi/split_utf8.ansi",
            .write_chunks = &.{ 1, 2, 1, 3, 4, 1 },
            .oracles = &.{
                .{
                    .name = "xterm-compatible",
                    .source = "recorded expectation for UTF-8 text split across process read boundaries",
                    .expected_screen = "tests/golden/screen/xterm/split_utf8.txt",
                },
            },
        },
        .{
            .name = "mixed_width",
            .size = .{ .cols = 4, .rows = 1 },
            .input_fixture_path = "tests/fixtures/ansi/mixed_width.ansi",
            .oracles = &.{
                .{
                    .name = "xterm-compatible",
                    .source = "recorded expectation for mixed ASCII and double-width Hangul cells",
                    .expected_screen = "tests/golden/screen/xterm/mixed_width.txt",
                },
            },
        },
        .{
            .name = "combining_mark",
            .size = .{ .cols = 2, .rows = 1 },
            .input_fixture_path = "tests/fixtures/ansi/combining_mark.ansi",
            .oracles = &.{
                .{
                    .name = "xterm-compatible",
                    .source = "recorded expectation for zero-width combining mark cursor behavior",
                    .expected_screen = "tests/golden/screen/xterm/combining_mark.txt",
                },
            },
        },
        .{
            // macOS 파일명 NFD 시나리오(HG4): `ls`가 '한글'을 conjoining 자모(초성 U+1112·중성 U+1161·
            // 종성 U+11AB / U+1100·U+1173·U+11AF)로 보낸다. 두 음절이 각각 한 셀(width 2)로 묶여 cols=4에
            // 꼭 맞고, dumpUtf8가 원본 NFD 자모 6개를 무손실로 복원한다(잘림 금지 — 클립보드·재출력 일치).
            // 외부 oracle(libvterm/Alacritty)은 conjoining 자모를 다르게 다룰 수 있어 cases.zig가 아니라
            // maru-vs-golden(recorded)으로만 고정한다(설계 §6 — NFD 클러스터는 maru/Ghostty 동작).
            .name = "nfd_hangul",
            .size = .{ .cols = 4, .rows = 1 },
            .input_fixture_path = "tests/fixtures/ansi/nfd_hangul.ansi",
            .oracles = &.{
                .{
                    .name = "xterm-compatible",
                    .source = "recorded expectation for NFD Hangul conjoining jamo clustered into syllable cells",
                    .expected_screen = "tests/golden/screen/xterm/nfd_hangul.txt",
                },
            },
        },
    };

    inline for (cases) |case| {
        try compareCase(case);
    }

    // 공유 매니페스트(cases.zig)의 케이스도 같은 비교를 돈다 — libvterm/Alacritty 오라클과
    // 동일한 목록을 보장해, 한 파일에만 케이스를 추가해 다른 오라클이 조용히 빠지는 일을 막는다.
    inline for (case_manifest.cases) |case| {
        try compareCase(.{
            .name = case.name,
            .size = .{ .cols = case.cols, .rows = case.rows },
            .input_fixture_path = case.input_fixture_path,
            .oracles = &.{.{
                .name = "xterm-compatible",
                .source = "shared oracle manifest (cases.zig)",
                .expected_screen = case.golden_path,
            }},
        });
    }
}

fn compareCase(case: Case) !void {
    const allocator = std.testing.allocator;

    var core = try maru.terminal.TerminalCore.init(allocator, case.size);
    defer core.deinit();

    const input_fixture = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        case.input_fixture_path,
        allocator,
        .limited(64 * 1024),
    );
    defer allocator.free(input_fixture);

    const input = try decodeEscapedFixture(allocator, input_fixture);
    defer allocator.free(input);

    try writeInput(&core, input, case.write_chunks);

    const actual = try core.dumpUtf8(allocator);
    defer allocator.free(actual);

    const snapshot = try maru.observability.snapshot.renderTerminalSnapshot(allocator, core.snapshot());
    defer allocator.free(snapshot);

    const snapshot_path = try std.fmt.allocPrint(
        allocator,
        "tests/artifacts/oracle/{s}/maru.snapshot.txt",
        .{case.name},
    );
    defer allocator.free(snapshot_path);
    try artifacts.writeText(snapshot_path, snapshot);

    const actual_path = try std.fmt.allocPrint(
        allocator,
        "tests/artifacts/oracle/{s}/maru.actual.txt",
        .{case.name},
    );
    defer allocator.free(actual_path);
    try artifacts.writeTextWithFinalNewline(allocator, actual_path, actual);

    const input_path = try std.fmt.allocPrint(
        allocator,
        "tests/artifacts/oracle/{s}/input.decoded.txt",
        .{case.name},
    );
    defer allocator.free(input_path);
    try artifacts.writeText(input_path, input);

    for (case.oracles) |oracle| {
        const expected_file = try std.Io.Dir.cwd().readFileAlloc(
            std.testing.io,
            oracle.expected_screen,
            allocator,
            .limited(64 * 1024),
        );
        defer allocator.free(expected_file);

        const expected_path = try std.fmt.allocPrint(
            allocator,
            "tests/artifacts/oracle/{s}/{s}.expected.txt",
            .{ case.name, oracle.name },
        );
        defer allocator.free(expected_path);
        try artifacts.writeTextWithFinalNewline(allocator, expected_path, goldenText(expected_file));

        errdefer std.debug.print(
            "oracle mismatch: case={s} oracle={s} source={s}\n",
            .{ case.name, oracle.name, oracle.source },
        );
        try std.testing.expectEqualStrings(goldenText(expected_file), actual);
    }
}

fn writeInput(core: *maru.terminal.TerminalCore, input: []const u8, chunks: ?[]const usize) !void {
    const chunk_pattern = chunks orelse {
        try core.write(input);
        return;
    };

    // Recorded oracle cases normally write all bytes at once. This optional
    // path proves stream behavior: process reads may cut text at any byte, and
    // the terminal core must still end at the same screen snapshot.
    var offset: usize = 0;
    var chunk_index: usize = 0;
    while (offset < input.len) {
        const wanted = chunk_pattern[chunk_index % chunk_pattern.len];
        const end = @min(input.len, offset + wanted);
        try core.write(input[offset..end]);
        offset = end;
        chunk_index += 1;
    }
}

fn goldenText(text: []const u8) []const u8 {
    // Golden files are normal text files, so they usually end with a final
    // newline for editor friendliness. TerminalCore.dumpUtf8 returns only the
    // screen rows joined by newlines, so we remove exactly one final file
    // newline without trimming meaningful trailing spaces from screen cells.
    if (text.len > 0 and text[text.len - 1] == '\n') {
        return text[0 .. text.len - 1];
    }
    return text;
}

fn decodeEscapedFixture(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    // ANSI fixtures are stored as readable escaped text rather than literal
    // control bytes. That keeps reviews understandable while still feeding the
    // terminal core the exact bytes a reference terminal would receive.
    const text = fileText(raw);
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        const byte = text[index];
        if (byte != '\\') {
            try output.append(allocator, byte);
            continue;
        }

        index += 1;
        if (index >= text.len) return error.InvalidFixtureEscape;

        try output.append(allocator, switch (text[index]) {
            'e' => 0x1b,
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            '\\' => '\\',
            else => return error.InvalidFixtureEscape,
        });
    }

    return output.toOwnedSlice(allocator);
}

fn fileText(text: []const u8) []const u8 {
    if (text.len > 0 and text[text.len - 1] == '\n') {
        return text[0 .. text.len - 1];
    }
    return text;
}
