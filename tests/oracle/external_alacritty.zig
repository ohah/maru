const std = @import("std");
const artifacts = @import("test_support");

// 외부 오라클(Alacritty): 동일한 fixture를 alacritty_terminal에 먹여 최종 화면을
// 덤프하고, 커밋된 golden과 비교한다. libvterm/Ghostty 오라클과 같은 역할이며,
// Alacritty는 빠른 parser/state machine 구현 계열의 reference다.
//
// alacritty_terminal은 Rust 크레이트라 in-process 링크가 어렵다. 그래서 작은 Rust
// dumper 바이너리(tests/oracle/alacritty-dumper)를 빌드해 두고, 이 테스트가
// subprocess로 호출한다. opt-in/환경 의존 테스트다(`mise run oracle-alacritty`):
//   cd tests/oracle/alacritty-dumper && cargo build --release
// 기본 `check`에는 넣지 않는다.

const dumper_bin = "tests/oracle/alacritty-dumper/target/release/alacritty-dumper";

const Case = struct {
    name: []const u8,
    cols: u16,
    rows: u16,
    input_fixture_path: []const u8,
    golden_path: []const u8,
};

const cases = [_]Case{
    .{
        .name = "basic_crlf",
        .cols = 12,
        .rows = 3,
        .input_fixture_path = "tests/fixtures/ansi/basic_crlf.ansi",
        .golden_path = "tests/golden/screen/xterm/basic_crlf.txt",
    },
    .{
        .name = "scroll_crlf",
        .cols = 8,
        .rows = 2,
        .input_fixture_path = "tests/fixtures/ansi/scroll_crlf.ansi",
        .golden_path = "tests/golden/screen/xterm/scroll_crlf.txt",
    },
    .{
        .name = "scroll_region",
        .cols = 4,
        .rows = 4,
        .input_fixture_path = "tests/fixtures/ansi/scroll_region.ansi",
        .golden_path = "tests/golden/screen/xterm/scroll_region.txt",
    },
    .{
        .name = "alt_screen",
        .cols = 8,
        .rows = 3,
        .input_fixture_path = "tests/fixtures/ansi/alt_screen.ansi",
        .golden_path = "tests/golden/screen/xterm/alt_screen.txt",
    },
};

test "committed goldens match Alacritty alacritty_terminal" {
    inline for (cases) |case| {
        try compareCase(case);
    }
}

fn compareCase(case: Case) !void {
    const allocator = std.testing.allocator;

    const input_fixture = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        case.input_fixture_path,
        allocator,
        .limited(64 * 1024),
    );
    defer allocator.free(input_fixture);

    const input = try decodeEscapedFixture(allocator, input_fixture);
    defer allocator.free(input);

    // 디코딩된 입력 바이트를 임시 파일로 남기고, 그 경로를 dumper에 넘긴다.
    const input_path = try std.fmt.allocPrint(
        allocator,
        "tests/artifacts/oracle-alacritty/{s}/input.bin",
        .{case.name},
    );
    defer allocator.free(input_path);
    try artifacts.writeText(input_path, input);

    const cols_str = try std.fmt.allocPrint(allocator, "{d}", .{case.cols});
    defer allocator.free(cols_str);
    const rows_str = try std.fmt.allocPrint(allocator, "{d}", .{case.rows});
    defer allocator.free(rows_str);

    const result = std.process.run(allocator, std.testing.io, .{
        .argv = &.{ dumper_bin, cols_str, rows_str, input_path },
    }) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print(
                "alacritty-dumper not built. Run: (cd tests/oracle/alacritty-dumper && cargo build --release)\n",
                .{},
            );
            return error.SkipZigTest;
        },
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("alacritty-dumper exited {d}: {s}\n", .{ code, result.stderr });
            return error.DumperFailed;
        },
        else => return error.DumperFailed,
    }

    const reference = result.stdout;

    const reference_path = try std.fmt.allocPrint(
        allocator,
        "tests/artifacts/oracle-alacritty/{s}/alacritty.actual.txt",
        .{case.name},
    );
    defer allocator.free(reference_path);
    try artifacts.writeTextWithFinalNewline(allocator, reference_path, reference);

    const expected_file = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        case.golden_path,
        allocator,
        .limited(64 * 1024),
    );
    defer allocator.free(expected_file);

    errdefer std.debug.print(
        "alacritty oracle mismatch: case={s} reference=alacritty_terminal golden={s}\n",
        .{ case.name, case.golden_path },
    );
    try std.testing.expectEqualStrings(goldenText(expected_file), reference);
}

fn goldenText(text: []const u8) []const u8 {
    if (text.len > 0 and text[text.len - 1] == '\n') {
        return text[0 .. text.len - 1];
    }
    return text;
}

fn decodeEscapedFixture(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
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
