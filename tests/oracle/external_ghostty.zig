const std = @import("std");
const artifacts = @import("test_support");

const c = @cImport({
    @cInclude("ghostty_shim.h");
});

// 외부 오라클(Ghostty): 동일한 fixture를 Ghostty의 VT 엔진(libghostty-vt)에 먹여
// 최종 화면을 덤프하고, 커밋된 golden과 비교한다. libvterm 오라클(external.zig)과
// 같은 역할이며, Ghostty는 Maru의 구조 레퍼런스이자 실전 검증이 두꺼운 reference다.
//
// opt-in/환경 의존 테스트다(`mise run oracle-ghostty`). references/ghostty에서
// `mise exec zig@0.15.2 -- zig build -Demit-lib-vt=true`로 빌드한
// libghostty-vt.a + include/ghostty 헤더를 링크한다. 기본 `check`에는 넣지 않는다.

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
};

test "committed goldens match Ghostty libghostty-vt" {
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

    // 그리드 한 셀당 최대 4바이트(UTF-8) + 행마다 '\n' + 여유.
    const out_cap = @as(usize, case.cols) * @as(usize, case.rows) * 4 + case.rows + 16;
    const out = try allocator.alloc(u8, out_cap);
    defer allocator.free(out);

    const written = c.maru_ghostty_dump(case.cols, case.rows, input.ptr, input.len, out.ptr, out.len);
    if (written < 0) return error.GhosttyDumpFailed;
    const reference = out[0..@intCast(written)];

    const reference_path = try std.fmt.allocPrint(
        allocator,
        "tests/artifacts/oracle-ghostty/{s}/ghostty.actual.txt",
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
        "ghostty oracle mismatch: case={s} reference=libghostty-vt golden={s}\n",
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
