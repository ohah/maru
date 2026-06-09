//! 오라클 케이스의 단일 매니페스트. recorded(Maru vs golden)·external(libvterm)·
//! external_alacritty(Alacritty)가 모두 이 목록을 순회한다 — 세 파일에 케이스를 복붙하면
//! 한 곳에 누락됐을 때 그 오라클만 조용히 미검증이 된다("oracle pass"로 보이면서).
//! 새 VT 기능의 fixture/golden은 여기에만 추가하면 세 검증이 함께 돈다.

pub const Case = struct {
    name: []const u8,
    cols: u16,
    rows: u16,
    input_fixture_path: []const u8,
    golden_path: []const u8,
};

pub const cases = [_]Case{
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
    .{
        .name = "cursor_save_restore",
        .cols = 8,
        .rows = 4,
        .input_fixture_path = "tests/fixtures/ansi/cursor_save_restore.ansi",
        .golden_path = "tests/golden/screen/xterm/cursor_save_restore.txt",
    },
};
