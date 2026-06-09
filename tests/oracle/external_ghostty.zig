const std = @import("std");
const artifacts = @import("test_support");
const maru = @import("maru");

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

// reflow 오라클: 같은 입력을 같은 초기 크기로 처리한 뒤 같은 새 크기로 resize(reflow)했을 때,
// Maru의 TerminalCore 결과(그리드 + 커서)가 Ghostty libghostty-vt와 일치하는지 직접 비교한다.
// 그리드 덤프엔 커서가 없으므로 Ghostty의 cursor_x/cursor_y도 함께 질의해 커서 재배치까지 본다.
const ReflowCase = struct {
    name: []const u8,
    cols0: u16,
    rows0: u16,
    cols1: u16,
    rows1: u16,
    // 이미 디코드된 raw 바이트(Zig 문자열 리터럴의 \x1b 등이 그대로 들어간다).
    input: []const u8,
};

const reflow_cases = [_]ReflowCase{
    .{ .name = "widen joins a wrapped line", .cols0 = 10, .rows0 = 6, .cols1 = 20, .rows1 = 6, .input = "abcdefghijklmnopqrstuvwxyz0123456789" },
    .{ .name = "narrow splits a line", .cols0 = 20, .rows0 = 6, .cols1 = 10, .rows1 = 6, .input = "abcdefghijklmnopqrstuvwxyz0123456789" },
    .{ .name = "narrow to a tiny width", .cols0 = 20, .rows0 = 8, .cols1 = 6, .rows1 = 8, .input = "abcdefghijklmnopqrstuvwxyz0123456789" },
    .{ .name = "hard newlines stay separate", .cols0 = 12, .rows0 = 6, .cols1 = 24, .rows1 = 6, .input = "alpha\r\nbeta\r\ngamma" },
    .{ .name = "cursor past trailing blanks then narrow", .cols0 = 12, .rows0 = 4, .cols1 = 5, .rows1 = 8, .input = "abc\x1b[1;9H" },
    .{ .name = "prompt then long command narrowed", .cols0 = 40, .rows0 = 8, .cols1 = 28, .rows1 = 10, .input = "user@host maru % echo abcdefghijklmnopqrstuvwxyz0123456789" },
    .{ .name = "live prompt+long cmd 113->71", .cols0 = 113, .rows0 = 33, .cols1 = 71, .rows1 = 33, .input = "yoon@ip-10-10-10-185 maru % dsafdsafsdfadsfasdfasdfasdfasdfasdfadsfasdfasdfadsfadsfadsfadsfdasfadsfdasfdsafdsafggeqgqgqegeqggasdgasdgasdgdassadf" },
    .{ .name = "live 120->51 prompt+cmd", .cols0 = 120, .rows0 = 33, .cols1 = 51, .rows1 = 19, .input = "yoon@ip-10-10-10-185 maru % asdfasdfadsfadsfadsfads456fas1d56f15ads6f156sadf156asd1f56sd1f56ads15f6ads156f1asd56f1a5s6df165asdf156" },
    // NOTE: 극소 폭(예: 5x3 -> 2x2)으로의 resize는 libghostty-vt의 ghostty_terminal_resize가
    // integer overflow로 패닉한다(Ghostty 측 edge). 유효한 오라클 비교가 안 되므로 제외한다.
};

// 스크롤백 기반 reflow(3b)가 들어와 재활성화한다. 활성 화면을 새 폭에 다시 wrap하고 넘치는 위쪽
// 행은 스크롤백으로 민다. 아래 케이스는 모두 스크롤백이 안 차는 단일 resize라 활성-only reflow가
// Ghostty와 일치한다(그리드 + 커서).
test "reflow matches Ghostty libghostty-vt" {
    inline for (reflow_cases) |case| {
        try compareReflowCase(case);
    }
}

fn compareReflowCase(case: ReflowCase) !void {
    const allocator = std.testing.allocator;

    const out_cap = @as(usize, case.cols1) * @as(usize, case.rows1) * 4 + case.rows1 + 16;
    const out = try allocator.alloc(u8, out_cap);
    defer allocator.free(out);

    var gx: u16 = 0;
    var gy: u16 = 0;
    var gpw: c_int = 0;
    const written = c.maru_ghostty_dump_resize(
        case.cols0,
        case.rows0,
        case.cols1,
        case.rows1,
        case.input.ptr,
        case.input.len,
        out.ptr,
        out.len,
        &gx,
        &gy,
        &gpw,
    );
    if (written < 0) return error.GhosttyDumpFailed;
    const ghostty_grid = out[0..@intCast(written)];

    var core = try maru.terminal.TerminalCore.init(allocator, .{ .cols = case.cols0, .rows = case.rows0 });
    defer core.deinit();
    try core.write(case.input);
    try core.resize(case.cols1, case.rows1);
    const maru_grid = try core.dumpUtf8(allocator);
    defer allocator.free(maru_grid);

    errdefer std.debug.print(
        "\nreflow mismatch: {s} ({d}x{d} -> {d}x{d})\n" ++
            "--- Ghostty ---\n{s}\ncursor=(row {d}, col {d}) pending_wrap={d}\n" ++
            "--- Maru ---\n{s}\ncursor=(row {d}, col {d}) pending_wrap={}\n",
        .{
            case.name,       case.cols0,      case.rows0,        case.cols1, case.rows1,
            ghostty_grid,    gy,              gx,                gpw,        maru_grid,
            core.cursor.row, core.cursor.col, core.pending_wrap,
        },
    );

    try std.testing.expectEqualStrings(ghostty_grid, maru_grid);
    try std.testing.expectEqual(gy, core.cursor.row);
    try std.testing.expectEqual(gx, core.cursor.col);
}
