const std = @import("std");
const maru = @import("maru");
const artifacts = @import("test_support");

const c = @cImport({
    @cInclude("vterm.h");
    @cInclude("vterm_shim.h");
});

// 외부 오라클: 동일한 fixture를 실제 reference VT 엔진(libvterm)에 먹여 최종 화면을
// 덤프하고, 커밋된 golden과 비교한다.
//
// tests/oracle/recorded.zig는 "Maru == golden"을 증명하고, 이 테스트는
// "golden == libvterm"을 증명한다. 둘을 합치면 "Maru == libvterm"이 transitively
// 성립한다. 이렇게 하면 앞으로 escape sequence fixture가 늘어날 때 golden을 손으로
// 적지 않고 실제 reference로 검증할 수 있다.
//
// 이 테스트는 시스템 libvterm을 링크하는 opt-in/환경 의존 테스트다
// (`mise run oracle-ext`). 기본 경로(`mise run check`)에 외부 의존성을 끌어들이지
// 않으려고 일부러 `check`에 넣지 않는다. libvterm은 `brew install libvterm`
// (또는 배포판 패키지)으로 설치한다.

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
    .{
        .name = "insert_delete_lines",
        .cols = 4,
        .rows = 4,
        .input_fixture_path = "tests/fixtures/ansi/insert_delete_lines.ansi",
        .golden_path = "tests/golden/screen/xterm/insert_delete_lines.txt",
    },
};

test "committed goldens match a real libvterm reference" {
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

    const reference = try renderWithLibvterm(allocator, case.cols, case.rows, input);
    defer allocator.free(reference);

    const reference_path = try std.fmt.allocPrint(
        allocator,
        "tests/artifacts/oracle-ext/{s}/libvterm.actual.txt",
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
        "external oracle mismatch: case={s} reference=libvterm golden={s}\n",
        .{ case.name, case.golden_path },
    );
    try std.testing.expectEqualStrings(goldenText(expected_file), reference);
}

fn renderWithLibvterm(allocator: std.mem.Allocator, cols: u16, rows: u16, input: []const u8) ![]u8 {
    const vt = c.vterm_new(@intCast(rows), @intCast(cols)) orelse return error.VTermInitFailed;
    defer c.vterm_free(vt);
    c.vterm_set_utf8(vt, 1);

    const screen = c.vterm_obtain_screen(vt) orelse return error.VTermScreenFailed;
    // libvterm은 alt screen(DECSET 1049/47)이 기본 비활성이라 켜야 실제 터미널처럼 동작한다.
    // 안 켜면 1049가 무시돼 alt 출력이 primary에 그대로 남아 오라클 비교가 어긋난다.
    c.vterm_screen_enable_altscreen(screen, 1);
    c.vterm_screen_reset(screen, 1);

    _ = c.vterm_input_write(vt, input.ptr, input.len);
    c.vterm_screen_flush_damage(screen);

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    var row: c_int = 0;
    while (row < @as(c_int, @intCast(rows))) : (row += 1) {
        if (row != 0) try output.append(allocator, '\n');
        var col: c_int = 0;
        while (col < @as(c_int, @intCast(cols))) : (col += 1) {
            const codepoint = c.maru_vterm_cell_codepoint(screen, row, col);
            // 빈 셀(chars[0] == 0)은 space로 덤프한다. 이는 maru.terminal의 dumpUtf8
            // 규약(각 row를 정확히 cols개 셀로 직렬화)과 맞춘다. wide-char 처리는
            // 양쪽(libvterm/Maru) 모두 step 3에서 정렬한다.
            if (codepoint == 0) {
                try output.append(allocator, ' ');
            } else {
                var buffer: [4]u8 = undefined;
                const len = try std.unicode.utf8Encode(@intCast(codepoint), &buffer);
                try output.appendSlice(allocator, buffer[0..len]);
            }
        }
    }

    return output.toOwnedSlice(allocator);
}

fn goldenText(text: []const u8) []const u8 {
    // golden 파일은 에디터 편의를 위해 보통 마지막에 newline 하나가 있다. 화면 cell의
    // trailing space는 의미 있는 데이터이므로 trim하지 않고, 파일 끝 newline 하나만
    // 제거한다. (recorded.zig와 동일한 규약.)
    if (text.len > 0 and text[text.len - 1] == '\n') {
        return text[0 .. text.len - 1];
    }
    return text;
}

fn decodeEscapedFixture(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    // ANSI fixture는 control byte 대신 읽기 쉬운 escaped text로 저장한다.
    // (recorded.zig와 동일한 디코더.)
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
