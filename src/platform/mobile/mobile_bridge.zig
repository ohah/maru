//! L4 모바일 어댑터의 **코어 쪽 절반**. iOS·Android host 가 공유한다.
//!
//! 플랫폼은 배치를 모른다 — 쓸 수 있는 크기를 논리 px 로 받고 quad 목록을 돌려준다.
//! 셀 판정(`maru_mobile_hit_cell`)도 여기가 한다. C 쪽 계약은 `mobile_host_abi.h` 가
//! 단일 출처이고, 이 파일의 export 와 **필드 순서·타입을 함께** 바꿔야 한다(한쪽만
//! 고치면 링크는 되고 동작만 어긋난다).
//!
//! **OS 호출이 없다.** 있으면 `platform/ios`·`platform/android` 로 내려야 한다 — 그
//! 규칙이 "공통분모" 를 파일 내용으로 판정 가능하게 만든다(docs/mobile-platform.md §2).
const std = @import("std");
// **모듈 루트는 `maru.zig` 하나다.** chrome·renderer 를 따로 주면 둘 다 `icons.zig` 를
// 상대 경로로 끌어와 "file exists in two modules" 로 깨진다(실측). 배럴 하나로 받으면
// 상대 import 가 전부 같은 모듈 안에서 풀린다.
const maru = @import("maru");

/// **iOS 에서 ReleaseSafe 를 쓰려면 이게 필요하다.** 기본 panic 핸들러는 스택 트레이스를
/// 찍으려고 `_dyld_get_image_header_containing_address` 를 부르는데 그 심볼이 시뮬레이터
/// SDK 에 없어 링크가 깨진다(실측). `simple_panic` 은 메시지만 내고 그 경로를 안 들여온다
/// — **안전 검사(overflow·bounds)는 그대로 산다**.
pub const panic = std.debug.simple_panic;

const chrome = maru.chrome;
const icon_glyph = maru.renderer.icon_glyph;

const tree = chrome.ui.tree;
const layout = chrome.ui.layout;
const paint_mod = chrome.ui.paint;
const draw = chrome.draw;
const tokens = chrome.tokens;

/// 플랫폼이 그릴 수 있는 최소 형태로 평탄화한 quad. ChromeDraw 의 op 은 union 이라
/// C 에서 다루기 번거로우니, 여기서 rect + 색 + radius 로 낮춰 넘긴다.
pub const MaruQuad = extern struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    r: f32,
    g: f32,
    b: f32,
    a: f32,
    radius: f32,
    /// 0=단색 quad · 1=아틀라스 글리프 · 2=아이콘 coverage
    kind: u32,
    /// kind=1 일 때 아틀라스 셀 좌표(열, 행). kind=2 면 아이콘 슬롯 인덱스.
    cell_x: u32,
    cell_y: u32,
};

/// 격자 상한. 본문 cols/rows 를 여기로 자르고, quad 버퍼도 **여기서 계산한다** — 둘을 따로
/// 두면 조용히 어긋난다(2048 로 박아 뒀을 때 태블릿 크기에서 격자만으로 넘쳤다. 폰 세로도
/// 1828/2048 로 아슬아슬했다 — 헤드리스 실측).
const max_cols: u16 = 200;
const max_rows: u16 = 60;
/// 본문 밖에서 나오는 quad: 배경 1 + chrome op(`ops` 배열 상한 512) + 라벨 글자 + 아이콘 6.
/// 본문이 압도적이라 여유는 넉넉히 잡아 둔다.
const chrome_quad_slack = 768;
var quad_buf: [@as(usize, max_cols) * max_rows + chrome_quad_slack]MaruQuad = undefined;
var quad_count: usize = 0;

// ── 본문용 터미널 코어 ────────────────────────────────────────────────────────
// 앞 단계 본문은 하드코딩 문자열이었다. 여기서는 **VT 파서를 실제로 태운다** — 색은
// SGR 에서, 한글 2셀 폭은 코어의 EAW 판정에서 나온다. 즉 화면에 보이는 본문이
// "maru 터미널이 실제로 계산한 격자"다.
const terminal = maru.terminal;
const color = maru.color;

// **고정 버퍼로는 resize 를 못 버틴다.** `FixedBufferAllocator` 는 마지막 할당 말고는
// free 가 no-op 이라, 격자가 바뀔 때마다 옛 격자를 영영 못 돌려받는다 — 512KB 로 **resize
// 7번**이면 OutOfMemory 였다(헤드리스 실측). 키보드를 서너 번 올렸다 내리면 닿는 수다.
//
// `page_allocator` 를 쓴다: 전역 싱글턴이 없고(우리는 남의 앱 프로세스 안에 들어가는
// 라이브러리다) free 가 실제로 메모리를 돌려준다. 페이지 단위 반올림 손실은 코어 할당이
// 몇 개뿐이라 작다 — 원격 세션(M3)이 붙어 처리량이 생기면 그때 재보고 정한다.
const term_allocator = std.heap.page_allocator;
var term_core: ?terminal.core.TerminalCore = null;
var term_cols: u16 = 0;
var term_rows: u16 = 0;

/// 실제 셸 세션이 낼 법한 바이트열. 색·굵기·한글이 섞여 있어야 코어를 통과했다는 게
/// 화면에서 드러난다.
const term_feed =
    "$ zig build test\r\n" ++
    "\x1b[32mAll 11 passed.\x1b[0m\r\n" ++
    "$ git status --short\r\n" ++
    "\x1b[33m M \x1b[0msrc/chrome/ui/tree.zig\r\n" ++
    "$ maru \x1b[36m0.1.0\x1b[0m (arm64)\r\n" ++
    "\x1b[35m한글 터미널\x1b[0m 세션 목록\r\n" ++
    "$ \x1b[1m설정 검색 알림\x1b[0m\r\n" ++
    // TUI 한 줄. 박스 드로잉·블록·브라유는 maru 가 **폰트 대신 절차 합성**하는 것들이라
    // (renderer.synthesizeGlyph) 화면에 이게 제대로 나오는지가 곧 합성 경로가 서 있는지다.
    "┌──┬──┐ █▄▀░ ⠿⠇\r\n" ++
    "│ab│cd│\r\n";

// ── 입력 ─────────────────────────────────────────────────────────────────────
// 플랫폼이 키를 받아 **바이트로** 넘긴다. 코어는 그것을 PTY 에서 온 것과 구분하지 않는다 —
// 그게 터미널의 계약이고, 모바일에서도 같은 계약이 서는지 보는 자리다.
/// **코어에 실제로 전달한** 누적 바이트. 반환값이 기록 길이였을 때는 버퍼가 찬 뒤에도
/// 같은 수가 계속 나와서, 입력이 죽은 것을 로그로 알아챌 수 없었다.
var delivered_len: usize = 0;

// **조합 중 문자열은 코어에 안 넣는다.** 확정 전에 PTY 로 흘리면 셸이 `ㅎ` 같은 자모를
// 명령어 일부로 받는다. 화면에만 흐리게 그릴 겉치레라 별도 상태로 둔다 — 데스크톱 maru 의
// IME 계약(삽입형 + dim 고스트)과 같은 모양이다.
var preedit_buf: [128]u8 = undefined;
var preedit_len: usize = 0;

pub export fn maru_mobile_set_preedit(ptr: [*]const u8, len: usize) void {
    // **UTF-8 경계에서 자른다.** 바이트 수로만 자르면 조합 중 한글이 반토막 나고, 그리는
    // 쪽의 `Utf8View.init` 이 실패해 **조합 문자열 전체가 사라진다** — 화면이 멈춘 것처럼 보인다.
    var n = @min(len, preedit_buf.len);
    while (n > 0 and (ptr[n - 1] & 0xC0) == 0x80) n -= 1; // continuation byte 위로 올라간다
    if (n > 0) {
        const lead = ptr[n - 1];
        const need: usize = if (lead & 0x80 == 0) 1 else if (lead & 0xE0 == 0xC0) 2 else if (lead & 0xF0 == 0xE0) 3 else 4;
        if (n - 1 + need > @min(len, preedit_buf.len)) n -= 1; // 마지막 글자가 잘렸다
    }
    @memcpy(preedit_buf[0..n], ptr[0..n]);
    preedit_len = n;
}

/// 코어가 만들었지만 **모바일에 아직 가져갈 사람이 없는 것**들을 치운다. 데스크톱은 매
/// 프레임 이걸 한다 — 답은 PTY 로 흘리고(`app/runtime.zig`·`app/pty_reader.zig`), 셸
/// 이벤트는 소비한 뒤 비운다(`clearShellEvents`).
///
/// 안 치우면 이렇게 된다(둘 다 실측):
///   * **답**(DA·DSR·커서 위치)은 쌓이기만 한다 — 질의 3000번에 15005바이트.
///   * **셸 이벤트**(OSC 133)는 상한 4096 에 닿고 그 뒤로 전부 드롭되며 overflow 가 영원히
///     선다 — 프롬프트 사이클 2000회면 닿는다. 코어 주석이 "프레임마다 drain 되면 닿을 일이
///     없다" 고 전제하는 바로 그 자리다.
///
/// 답을 버리는 것은 **의미의 손실**이라 신호를 남기고(§5), 셸 이벤트는 관측용이라 조용히
/// 비운다. 소비자가 생기면(에이전트 상태·프롬프트 표시) 비우기 **전에** 읽으면 된다.
fn drainUnconsumed(core: *terminal.core.TerminalCore) void {
    if (core.pendingResponse().len > 0) {
        setLastError("response_dropped");
        core.clearResponse();
    }
    if (core.shellEvents().len > 0) core.clearShellEvents();
}

pub export fn maru_mobile_input(ptr: [*]const u8, len: usize) u32 {
    preedit_len = 0; // 확정됐으니 겉치레를 지운다
    // **닿은 것만 센다.** 반환값이 "코어에 전달한 누적 바이트" 라고 헤더에 적어 놓고,
    // 코어가 없거나 write 가 실패해도 그냥 더하고 있었다 — 그 값으로 입력이 죽은 것을
    // 판정하라고 해 놓고 값이 거짓말을 했다.
    const core = &(term_core orelse {
        setLastError("input_before_core");
        return @intCast(delivered_len);
    });
    // 실패를 삼키지 않는다 — 키가 사라지는데 신호가 없던 것이 리뷰 최상위 결함이었다.
    core.write(ptr[0..len]) catch {
        setLastError("core_write_input");
        return @intCast(delivered_len);
    };
    delivered_len += len;
    drainUnconsumed(core);
    return @intCast(delivered_len);
}

// ── 포인터 조회 ───────────────────────────────────────────────────────────────
// 논리 좌표를 본문의 셀 좌표로 바꾼다. **배치를 아는 쪽이 답한다** — 플랫폼은 점만 넘긴다.
// 본문 rect·셀 크기는 마지막 build 가 정한 값을 그대로 쓴다(별도 상수를 두면 어긋난다).
var body_rect: struct { x: f32 = 0, y: f32 = 0, w: f32 = 0, h: f32 = 0 } = .{};
var body_cell_w: i32 = 1;
var body_line_h: i32 = 1;
/// 본문 사각형 안에 **실제로 있는** 격자 크기. 사각형은 격자보다 클 수 있다(나머지 여백,
/// cols/rows 상한). 그 여백을 셀로 답하면 없는 셀을 가리키게 된다.
var body_cols: u16 = 0;
var body_rows: u16 = 0;

/// 상위 16비트=열, 하위 16비트=행. 본문 밖이거나 **격자 밖이면** 0xFFFFFFFF.
pub export fn maru_mobile_hit_cell(x: f32, y: f32) u32 {
    if (body_rect.w <= 0 or body_rect.h <= 0) return 0xFFFFFFFF;
    if (x < body_rect.x or y < body_rect.y or
        x >= body_rect.x + body_rect.w or y >= body_rect.y + body_rect.h) return 0xFFFFFFFF;
    const col = @divTrunc(@as(i32, @intFromFloat(x - body_rect.x)), @max(1, body_cell_w));
    const row = @divTrunc(@as(i32, @intFromFloat(y - body_rect.y)), @max(1, body_line_h));
    if (col < 0 or row < 0 or col >= body_cols or row >= body_rows) return 0xFFFFFFFF;
    return (@as(u32, @intCast(col)) << 16) | @as(u32, @intCast(row));
}

/// 셀 색을 RGB 로 푼다. indexed 는 maru 자체 팔레트(`color.xterm256`)를 쓴다 —
/// 모바일용으로 색표를 새로 만들지 않는다.
fn cellRgb(style: terminal.types.Style, tk: anytype) color.Rgb {
    return switch (style.foreground) {
        .default => tk.get(.surface_fg),
        .indexed => |i| color.xterm256(i),
        .rgb => |c| c,
    };
}

/// 본문 사각형을 터미널 격자로 채운다.
fn pushTerminal(rect: anytype, tk: anytype) void {
    const font_px: i32 = 15;
    const scale = @as(f32, @floatFromInt(font_px)) / @as(f32, @floatFromInt(atlas_cell_h));
    const cw: i32 = @intFromFloat(@as(f32, @floatFromInt(atlas_cell_w)) * scale);
    const line_h: i32 = font_px + 7;
    const cols_f = @divTrunc(@as(i32, @intFromFloat(rect.width)), @max(1, @divTrunc(cw, 2)));
    const rows_f = @divTrunc(@as(i32, @intFromFloat(rect.height)), line_h);
    const cols: u16 = @intCast(@max(8, @min(max_cols, cols_f)));
    const rows: u16 = @intCast(@max(2, @min(max_rows, rows_f)));

    // **크기가 바뀌면 코어를 다시 세우지 않고 `resize` 한다.** 새로 만들면 스크롤백과 화면
    // 상태가 통째로 날아간다 — 키보드를 올렸다 내리기만 해도 그렇게 된다(창이 리사이즈된다).
    // 지금은 고정 대본을 먹이고 있어 눈에 안 띄지만, 원격 세션이 붙으면 곧바로 드러난다.
    if (term_core != null and (term_cols != cols or term_rows != rows)) {
        // **실패했으면 기록도 안 바꾼다.** 예전에는 catch 로 오류만 적고 term_cols/rows 를
        // 새 값으로 덮어, 코어는 옛 크기인데 아래 격자 순회는 새 크기로 돌았다 — 없는 셀을
        // 읽는다(ReleaseSafe 범위 검사에 걸려 앱이 죽는다).
        if (term_core.?.resize(cols, rows)) {
            term_cols = cols;
            term_rows = rows;
        } else |_| setLastError("core_resize");
    }
    if (term_core == null) {
        term_core = terminal.core.TerminalCore.init(term_allocator, .{ .cols = cols, .rows = rows }) catch {
            // 조용히 비우면 본문만 사라진 채 아무 신호가 없다.
            setLastError("terminal_core_init");
            term_core = null;
            return;
        };
        term_cols = cols;
        term_rows = rows;
        term_core.?.write(term_feed) catch setLastError("core_write_feed");
        drainUnconsumed(&term_core.?);
    }
    const core = &(term_core orelse return);
    // **격자를 도는 기준은 코어가 실제로 들고 있는 크기다.** 우리가 요청한 크기를 쓰면
    // resize 가 실패했을 때 없는 셀을 읽는다. 요청값과 갈릴 수 있는 자리를 아예 없앤다.
    const grid_cols = core.size.cols;
    const grid_rows = core.size.rows;

    // 포인터 조회가 **같은 값**을 쓰도록 기록한다 — 렌더와 판정이 갈리면 셀이 어긋난다.
    body_rect = .{ .x = rect.x, .y = rect.y, .w = rect.width, .h = rect.height };
    body_cell_w = @max(1, @divTrunc(cw, 2));
    body_line_h = line_h;
    body_cols = grid_cols;
    body_rows = grid_rows;

    var row: u16 = 0;
    while (row < grid_rows) : (row += 1) {
        var col: u16 = 0;
        while (col < grid_cols) : (col += 1) {
            const cell = core.screen.cells[core.index(row, col)];
            if (cell.continuation) continue; // 2셀 글자의 뒷칸은 앞칸이 이미 그렸다
            if (cell.codepoint == ' ' or cell.codepoint == 0) continue;
            const glyph = atlasCell(cell.codepoint) orelse continue;
            if (!reserveQuad()) return;
            const rgb = cellRgb(cell.style, tk);
            // 진행 폭은 코어가 정한 셀 폭을 따른다 — 한글이 2셀이라는 판정이 코어 것이다.
            const x = @as(i32, @intFromFloat(rect.x)) + @as(i32, col) * @divTrunc(cw, 2);
            const y = @as(i32, @intFromFloat(rect.y)) + @as(i32, row) * line_h;
            quad_buf[quad_count] = .{
                .x = @floatFromInt(x),
                .y = @floatFromInt(y),
                // **셀 종횡비를 지킨다.** 셰이더가 아틀라스 셀 *전체* 를 quad 에 매핑하므로
                // 폭을 줄이면 글자가 가로로 눌린다. 단폭·양폭 모두 같은 셀 하나를 그리고,
                // 다른 것은 **다음 칸까지의 거리**(아래 x 계산)뿐이다.
                .w = @floatFromInt(cw),
                .h = @floatFromInt(font_px),
                .r = @as(f32, @floatFromInt(rgb.r)) / 255.0,
                .g = @as(f32, @floatFromInt(rgb.g)) / 255.0,
                .b = @as(f32, @floatFromInt(rgb.b)) / 255.0,
                .a = 1.0,
                .radius = 0,
                .kind = 1,
                .cell_x = glyph.col,
                .cell_y = glyph.row,
            };
            quad_count += 1;
        }
    }

    // 조합 중 문자열을 커서 자리에 **흐리게** 얹는다. **격자를 다 그린 뒤**라야 그 위에
    // 올라간다 — 앞에 두면 커서 자리에 글자가 있을 때 그 글자가 조합을 덮는다(주석은 "위에
    // 그려진다" 라고 적혀 있었는데 순서는 반대였다).
    if (preedit_len > 0) {
        const cur = core.screen.cursor;
        const px = @as(i32, @intFromFloat(rect.x)) + @as(i32, cur.col) * @divTrunc(cw, 2);
        const py = @as(i32, @intFromFloat(rect.y)) + @as(i32, cur.row) * line_h;
        const dim = tk.get(.muted_fg);
        pushText(preedit_buf[0..preedit_len], px, py, font_px, dim);
    }
}

/// 데스크톱 기본 테마에 가까운 값. **아직 config 를 안 읽는다** — 모바일이 config 를
/// 어디서 받을지가 원격 연결(M3)과 함께 정해진다.
fn themeColors() tokens.ThemeColors {
    return .{
        .foreground = .{ .r = 0xE6, .g = 0xE6, .b = 0xEA },
        .sidebar_background = .{ .r = 0x24, .g = 0x24, .b = 0x2E },
        .sidebar_foreground = .{ .r = 0xD0, .g = 0xD0, .b = 0xD8 },
        .sidebar_active = .{ .r = 0x3A, .g = 0x3A, .b = 0x4A },
        .search_match = .{ .r = 0x4A, .g = 0x4A, .b = 0x20 },
        .search_match_current = .{ .r = 0x8A, .g = 0x7A, .b = 0x20 },
        .selection = .{ .r = 0x30, .g = 0x40, .b = 0x60 },
        .cursor = .{ .r = 0xE6, .g = 0xE6, .b = 0xEA },
        .accent = .{ .r = 0xDD, .g = 0xA1, .b = 0x5E }, // maru 앰버
    };
}

/// quad 자리를 하나 잡는다. **넘치면 알린다** — 조용히 자르면 화면 일부가 사라진 채
/// 아무 신호도 없다(본문만 알리고 chrome·아이콘은 조용하던 것을 한곳으로 모았다).
fn reserveQuad() bool {
    if (quad_count == quad_buf.len) {
        setLastError("quad_buffer_full");
        return false;
    }
    return true;
}

fn push(rect: draw.Rect, rgb: anytype, alpha: u8, radius: u16, kind: u32) void {
    if (!reserveQuad()) return;
    quad_buf[quad_count] = .{
        .x = @floatFromInt(rect.x),
        .y = @floatFromInt(rect.y),
        .w = @floatFromInt(rect.w),
        .h = @floatFromInt(rect.h),
        .r = @as(f32, @floatFromInt(rgb.r)) / 255.0,
        .g = @as(f32, @floatFromInt(rgb.g)) / 255.0,
        .b = @as(f32, @floatFromInt(rgb.b)) / 255.0,
        .a = @as(f32, @floatFromInt(alpha)) / 255.0,
        .radius = @floatFromInt(radius),
        .kind = kind,
        .cell_x = 0,
        .cell_y = 0,
    };
    quad_count += 1;
}

/// 아틀라스 인덱스(호스트가 만든 atlas.idx)를 코드포인트→셀로 들고 있는다.
/// 아틀라스 격자. **여기가 용량의 단일 출처다** — 헤더 매크로로 두면 등록부보다 큰 슬롯을
/// 약속하게 되고, 남는 슬롯은 등록이 안 된 채 매 프레임 다시 구워진다(실측 위험).
const atlas_cols_n: u32 = 16;
const atlas_rows_n: u32 = 32;
const atlas_cap: usize = atlas_cols_n * atlas_rows_n;

pub export fn maru_mobile_atlas_cols() u32 {
    return atlas_cols_n;
}

pub export fn maru_mobile_atlas_rows() u32 {
    return atlas_rows_n;
}

var atlas_cp: [atlas_cap]u32 = undefined;
var atlas_col: [atlas_cap]u32 = undefined;
var atlas_row: [atlas_cap]u32 = undefined;
var atlas_adv: [atlas_cap]u32 = undefined;
var atlas_n: usize = 0;
/// 아틀라스 셀 크기(px). 종횡비를 지켜 그려야 글자가 안 늘어난다.
var atlas_cell_w: u32 = 24;
var atlas_cell_h: u32 = 32;

pub export fn maru_mobile_atlas_geometry(cell_w: u32, cell_h: u32) void {
    atlas_cell_w = cell_w;
    atlas_cell_h = cell_h;
}

pub export fn maru_mobile_atlas_add(cp: u32, col: u32, row: u32, advance: u32) void {
    // 등록되면 "없음" 목록에서 뺀다. 안 그러면 아틀라스가 서기 **전에** 한 번 돈 build 가
    // 남긴 목록 때문에 이미 있는 글자를 슬롯만 축내며 다시 굽는다(실측: grew=15 가 전부
    // 'z' 같은 ASCII 중복이었다).
    var i: usize = 0;
    while (i < miss_n) : (i += 1) {
        if (miss_cp[i] == cp) {
            miss_cp[i] = miss_cp[miss_n - 1];
            miss_n -= 1;
            break;
        }
    }
    for (0..atlas_n) |j| if (atlas_cp[j] == cp) return; // 이미 있으면 슬롯을 안 쓴다
    if (atlas_n == atlas_cp.len) return;
    atlas_cp[atlas_n] = cp;
    atlas_col[atlas_n] = col;
    atlas_row[atlas_n] = row;
    atlas_adv[atlas_n] = advance;
    atlas_n += 1;
}

// **아틀라스는 자란다.** 처음 보는 글자는 그릴 글리프가 없어 조용히 안 그려진다 — 고정
// 집합으로 두면 입력·원격 출력의 새 글자가 전부 사라진다(실측으로 드러났다: 키를 넣었더니
// 코어엔 들어왔는데 화면이 그대로였다).
// 여기서는 **놓친 코드포인트를 모아** 플랫폼이 그것만 구워 넣게 한다. 슬롯 추가는
// 아틀라스 부분 업데이트(여섯 기능 4번)를 그대로 쓴다.
var miss_cp: [64]u32 = undefined;
var miss_n: usize = 0;

fn noteMiss(cp: u21) void {
    for (0..miss_n) |i| if (miss_cp[i] == cp) return;
    if (miss_n == miss_cp.len) return;
    miss_cp[miss_n] = cp;
    miss_n += 1;
}

/// 플랫폼이 부른다: 아직 아틀라스에 없는 코드포인트 개수.
pub export fn maru_mobile_missing_count() u32 {
    return @intCast(miss_n);
}

/// i번째 놓친 코드포인트. 플랫폼이 이걸 구워 `maru_atlas_add` 로 넣는다.
pub export fn maru_mobile_missing_cp(i: u32) u32 {
    if (i >= miss_n) return 0;
    return miss_cp[i];
}

/// 다음 빈 슬롯의 (열, 행) — 상위 16비트=열, 하위 16비트=행.
/// 다음 빈 슬롯. **꽉 차면 0xFFFFFFFF 를 돌려준다** — 예전에는 같은 자리를 계속 돌려줘,
/// 등록되지 못한 글자가 매 프레임 다시 구워지며 CPU·GPU 만 먹었다.
pub export fn maru_mobile_next_slot(cols: u32) u32 {
    if (atlas_n >= atlas_cap) return 0xFFFFFFFF;
    const idx: u32 = @intCast(atlas_n);
    return ((idx % cols) << 16) | (idx / cols);
}

/// 플랫폼이 다 구운 뒤 부른다. 목록을 비워 다음 프레임에 다시 쌓이게 한다.
pub export fn maru_mobile_missing_clear() void {
    miss_n = 0;
}

fn atlasCell(cp: u21) ?struct { col: u32, row: u32, adv: u32 } {
    for (0..atlas_n) |i| if (atlas_cp[i] == cp)
        return .{ .col = atlas_col[i], .row = atlas_row[i], .adv = atlas_adv[i] };
    noteMiss(cp);
    return null;
}

/// 문자열을 글자 quad 로 분해한다. **폭은 maru 의 EAW 규칙을 따른다** — 한글은 2셀이다.
fn pushText(text: []const u8, x0: i32, y0: i32, font_px: i32, rgb: anytype) void {
    // 셀 종횡비를 지킨다 — 임의 크기 상자에 셀을 넣으면 글자가 늘어난다.
    const scale = @as(f32, @floatFromInt(font_px)) / @as(f32, @floatFromInt(atlas_cell_h));
    const draw_w: i32 = @intFromFloat(@as(f32, @floatFromInt(atlas_cell_w)) * scale);
    var pen = x0;
    var view = std.unicode.Utf8View.init(text) catch return;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        const cell = atlasCell(cp);
        // 진행 폭은 **폰트 advance** 다. 셀 폭을 쓰면 자간이 벌어진다(실측).
        const adv_px: i32 = if (cell) |c|
            @intFromFloat(@as(f32, @floatFromInt(c.adv)) * scale)
        else
            @divTrunc(draw_w, 2);
        if (cp != ' ') {
            if (cell) |c| {
                if (reserveQuad()) {
                    quad_buf[quad_count] = .{
                        .x = @floatFromInt(pen),
                        .y = @floatFromInt(y0),
                        .w = @floatFromInt(draw_w),
                        .h = @floatFromInt(font_px),
                        .r = @as(f32, @floatFromInt(rgb.r)) / 255.0,
                        .g = @as(f32, @floatFromInt(rgb.g)) / 255.0,
                        .b = @as(f32, @floatFromInt(rgb.b)) / 255.0,
                        .a = 1.0,
                        .radius = 0,
                        .kind = 1,
                        .cell_x = c.col,
                        .cell_y = c.row,
                    };
                    quad_count += 1;
                }
            }
        }
        pen += @max(1, adv_px);
    }
}

/// 등록된 SVG 아이콘의 coverage 를 Zig 에서 만든다 — 두 플랫폼이 같은 코드를 쓴다.
const icon_slot_px = 32;
const icon_slots = 6;
/// **RGBA8** 이어야 한다 — `glyph_pixels.slotFits` 가 `bytes_per_row >= width*4` 를 요구한다
/// (단일 채널을 주면 조용히 0을 돌려준다. 실측: filled=0/6 으로 헤맸다). 셰이더는 alpha 를
/// coverage 로 읽는다.
var icon_pixels: [icon_slots * icon_slot_px * icon_slot_px * 4]u8 = undefined;

pub export fn maru_mobile_icon_atlas() [*]const u8 {
    return &icon_pixels;
}
pub export fn maru_mobile_icon_slot_px() u32 {
    return icon_slot_px;
}
pub export fn maru_mobile_icon_count() u32 {
    return icon_slots;
}

/// 아이콘 coverage 를 채우고, 실제로 잉크가 있는 슬롯 수를 돌려준다(0이면 자산 이식 실패).
pub export fn maru_mobile_icon_build() u32 {
    @memset(&icon_pixels, 0);
    const cps = [icon_slots]u32{ 0xF0001, 0xF0002, 0xF0003, 0xF0004, 0xF0005, 0xF0006 };
    var filled: u32 = 0;
    for (cps, 0..) |cp, i| {
        const stride = icon_slot_px * 4;
        const base = i * icon_slot_px * stride;
        const slot = icon_pixels[base .. base + icon_slot_px * stride];
        const n = icon_glyph.fillCoverage(cp, icon_slot_px, icon_slot_px, stride, slot) orelse continue;
        if (n > 0) filled += 1;
    }
    return filled;
}

/// 터미널 창 chrome 을 실제 컴포넌트로 조립한다 — 탭 바, 사이드바 카드 목록, 본문, 상태바.
fn buildUi(width: u32, height: u32, tk: *const tokens.Tokens) !void {
    const height_f: f32 = @floatFromInt(height);
    var entries: [256]tree.RectEntry = undefined;
    var items: [256]layout.Item = undefined;
    var flex_scratch: [256]layout.FlexScratch = undefined;
    var child_rects: [256]layout.UiRect = undefined;

    // ── 탭 바: 탭 세 개를 가로로
    const tab_label_style: layout.UiStyle = .{ .width = .{ .px = 34.0 }, .height = .{ .px = 13.0 }, .margin = .{ .left = 12.0, .top = 11.0 } };
    // 자식 슬라이스는 **함수 스코프 변수**를 가리켜야 한다. `&.{...}` 는 임시 배열이라
    // statement 를 벗어나면 dangling 이고, build 가 그 쓰레기를 읽는다(실측).
    var tab_kids: [3][1]tree.UiNode = .{
        .{tree.text(.{ .id = 111, .style = tab_label_style, .value = "zsh", .tone = .primary })},
        .{tree.text(.{ .id = 112, .style = tab_label_style, .value = "vim", .tone = .muted })},
        .{tree.text(.{ .id = 113, .style = tab_label_style, .value = "logs", .tone = .muted })},
    };
    const tabs = [_]tree.UiNode{
        tree.card(.{ .id = 101, .style = .{ .flex = .{ .grow = 1 }, .height = .{ .px = 34.0 }, .margin = .{ .right = 6.0 } }, .variant = .selected }, &tab_kids[0]),
        tree.card(.{ .id = 102, .style = .{ .flex = .{ .grow = 1 }, .height = .{ .px = 34.0 }, .margin = .{ .right = 6.0 } }, .variant = .surface }, &tab_kids[1]),
        tree.card(.{ .id = 103, .style = .{ .flex = .{ .grow = 1 }, .height = .{ .px = 34.0 } }, .variant = .surface }, &tab_kids[2]),
    };
    const tab_bar = tree.container(.{ .id = 100, .direction = .row, .style = .{ .height = .{ .px = 46.0 }, .padding = .{ .left = 12.0, .right = 12.0, .top = 6.0, .bottom = 6.0 } } }, &tabs);

    // ── 사이드바: 워크스페이스 카드 다섯 개(세로)
    const names = [_][]const u8{ "maru", "web", "docs", "infra", "scratch" };
    var side_kids: [5][1]tree.UiNode = undefined;
    var side_children: [5]tree.UiNode = undefined;
    for (&side_children, 0..) |*c, i| {
        side_kids[i] = .{tree.text(.{
            .id = @intCast(230 + i),
            .style = .{ .width = .{ .px = 58.0 }, .height = .{ .px = 13.0 }, .margin = .{ .left = 12.0, .top = 19.0 } },
            .value = names[i],
            .tone = if (i == 1) .accent else .primary,
        })};
        c.* = tree.card(.{
            .id = @intCast(210 + i),
            .style = .{ .width = .{ .percent = 1.0 }, .height = .{ .px = 52.0 }, .margin = .{ .bottom = 8.0 } },
            .variant = if (i == 1) .selected else .surface,
        }, &side_kids[i]);
    }
    const sidebar = tree.container(.{ .id = 200, .direction = .column, .style = .{ .width = .{ .percent = 0.34 }, .padding = .{ .left = 10.0, .right = 10.0, .top = 10.0, .bottom = 10.0 } } }, &side_children);

    // ── 본문: **진짜 터미널 화면**이다. 자식 없이 자리만 잡고, 그 사각형을
    // `TerminalCore` 의 셀 격자로 채운다(아래 `pushTerminal`). 앞 단계의 하드코딩
    // 문자열과 달리 VT 파서를 실제로 태우므로 SGR 색·한글 2셀 폭이 코어에서 나온다.
    const body = tree.container(.{ .id = 300, .direction = .column, .style = .{ .flex = .{ .grow = 1 }, .padding = .{ .left = 16.0, .right = 16.0, .top = 14.0, .bottom = 14.0 } } }, &.{});

    const middle = tree.container(.{ .id = 20, .direction = .row, .style = .{ .flex = .{ .grow = 1 } } }, &.{ sidebar, body });

    // ── 상태바
    const status = tree.container(.{ .id = 400, .direction = .row, .style = .{ .height = .{ .px = 26.0 }, .padding = .{ .left = 12.0, .right = 12.0, .top = 5.0, .bottom = 5.0 } } }, &.{
        tree.card(.{ .id = 401, .style = .{ .flex = .{ .grow = 1 }, .height = .{ .px = 16.0 }, .margin = .{ .right = 10.0 } }, .variant = .raised }, &.{}),
        tree.card(.{ .id = 402, .style = .{ .flex = .{ .grow = 1.4 }, .height = .{ .px = 16.0 } }, .variant = .raised }, &.{}),
    });

    const root = tree.container(.{ .id = 1, .direction = .column }, &.{ tab_bar, middle, status });

    const built = try tree.build(root, .{
        .root_size = .{ .width = @floatFromInt(width), .height = @floatFromInt(height) },
        .max_entries = entries.len,
        .max_depth = 16,
    }, .{ .entries = &entries, .items = &items, .flex_scratch = &flex_scratch, .child_rects = &child_rects });

    // ── paint: 실제 컴포넌트 경로가 내는 ChromeDraw
    var ops: [512]draw.Op = undefined;
    const cd = try paint_mod.paint(built, .{}, tk, .sidebar, .{ .ops = &ops });

    // 배경 먼저
    push(.{ .x = 0, .y = 0, .w = width, .h = height }, tk.get(.surface_bg), 0xFF, 0, 0);
    for (cd.ops) |op| switch (op) {
        .quad => |q| push(q.rect, tk.get(q.fill_role), q.alpha, q.corner_radii[0], 0),
        .fill => |f| push(f.rect, tk.get(f.role), f.alpha, 0, 0),
        .border => |b| push(b.rect, tk.get(b.role), 0x60, 0, 0),
        .rule => |r| push(.{ .x = r.from.x, .y = r.from.y, .w = @intCast(@max(1, r.to.x - r.from.x)), .h = @intCast(@max(1, r.to.y - r.from.y)) }, tk.get(r.role), 0xFF, 0, 0),
        // **텍스트는 여기서 그리지 않는다.** `ui.paint` 는 `resolveText` 결과를 버려서
        // 이 분기가 실제로는 안 온다(`_ = paint_style.resolveText(visual)`). 글자는 아래
        // 레이아웃 entry 를 훑어 아틀라스로 그린다 — 혹시 이 op 이 오더라도 여기서 또
        // 그리면 같은 자리에 두 번 그려진다.
        .text => {},
        else => {},
    };

    // `ui.paint` 는 텍스트 op 을 내지 않는다(resolveText 결과를 버린다 — 실측). 텍스트 렌더는
    // typography/lowering 이 따로 맡는 구조라, 레이아웃이 잡은 자리에 **실제 글자**를 그린다.
    for (built.entries) |entry| {
        if (entry.kind != .text) continue;
        const label = labelFor(entry.id) orelse continue;
        const tone_role: tokens.ColorRole = switch (entry.visual) {
            .text => |tv| switch (tv.tone) {
                .accent => .accent_bar,
                .muted => .muted_fg,
                else => .surface_fg,
            },
            else => .surface_fg,
        };
        pushText(label, @intFromFloat(entry.rect.x), @intFromFloat(entry.rect.y), 15, tk.get(tone_role));
    }

    // **본문은 진짜 터미널 코어다.** 레이아웃이 잡아 준 본문 사각형에 셀 격자를 채운다.
    for (built.entries) |entry| {
        if (entry.id != 300) continue;
        pushTerminal(entry.rect, tk);
        break;
    }

    // **SVG 아이콘**: maru 의 등록 아이콘을 그대로 얹는다. coverage 는 Zig 가 만들고
    // (renderer/icon_glyph) 플랫폼은 텍스처로 올려 샘플링만 한다 — 자산이 이식된다는 증거다.
    const icon_y: i32 = @intFromFloat(@max(0, height_f - 24));
    const icon_step: i32 = 26;
    const icon_x0: i32 = @as(i32, @intCast(width)) - icon_step * 6 - 12;
    for (0..6) |i| {
        if (!reserveQuad()) break;
        const rgb = tk.get(if (i == 0) .accent_bar else .surface_fg);
        quad_buf[quad_count] = .{
            .x = @floatFromInt(icon_x0 + icon_step * @as(i32, @intCast(i))),
            .y = @floatFromInt(icon_y),
            .w = 18,
            .h = 18,
            .r = @as(f32, @floatFromInt(rgb.r)) / 255.0,
            .g = @as(f32, @floatFromInt(rgb.g)) / 255.0,
            .b = @as(f32, @floatFromInt(rgb.b)) / 255.0,
            .a = 1.0,
            .radius = 0,
            .kind = 2,
            .cell_x = 0,
            .cell_y = @intCast(i),
        };
        quad_count += 1;
    }
}

/// UiId → 문자열. `RectEntry` 는 문자열을 들고 있지 않으므로(레이아웃만 담는다) 조립할 때
/// 쓴 값을 여기서 되찾는다.
fn labelFor(id: u64) ?[]const u8 {
    return switch (id) {
        111 => "zsh",
        112 => "vim",
        113 => "logs",
        230 => "maru",
        231 => "web",
        232 => "docs",
        233 => "infra",
        234 => "scratch",
        // 본문 줄은 여기 없다 — TerminalCore 격자가 소유한다(pushTerminal).
        else => null,
    };
}

/// 플랫폼이 부른다: UI 를 조립하고 quad 개수를 돌려준다.
/// 마지막 오류 이름. 0 quads 가 나왔을 때 **무엇이 실패했는지** 플랫폼이 볼 수 있어야 한다 —
/// catch 로 삼키면 화면이 비어 있는 이유를 알 수 없다(실측: 처음에 그렇게 짰다가 헤맸다).
var last_error: [64]u8 = [_]u8{0} ** 64;

/// 플랫폼이 `maru_mobile_last_error` 로 읽는 자리. 조용한 실패를 남기지 않기 위한 것이라
/// **덮어쓰지 않는다** — 먼저 난 원인이 더 쓸모 있다.
fn setLastError(name: []const u8) void {
    if (last_error[0] != 0) return;
    const n = @min(name.len, last_error.len - 1);
    @memcpy(last_error[0..n], name[0..n]);
}

pub export fn maru_mobile_build(width: u32, height: u32) u32 {
    quad_count = 0;
    // **여기서 비우지 않는다.** 프레임 시작마다 비우면 프레임 **사이**에 난 실패
    // (`maru_mobile_input` 의 core write)가 아무도 읽기 전에 지워진다 — 키가 조용히
    // 사라지던 것이 이번 리뷰 최상위 결함이었는데, 그 신호가 딱 그 경로에서만 안 남았다.
    // 비우는 것은 **읽은 쪽**이 한다(`maru_mobile_clear_error`).
    const tk = tokens.Tokens.rich(themeColors());
    buildUi(width, height, &tk) catch |err| {
        setLastError(@errorName(err));
        return 0;
    };
    return @intCast(quad_count);
}

pub export fn maru_mobile_last_error() [*:0]const u8 {
    return @ptrCast(&last_error);
}

/// 플랫폼이 읽고 나서 부른다. 비우는 자리를 읽는 쪽에 두어야 **프레임 사이에 난 실패**도
/// 반드시 한 번은 눈에 띈다. 같은 오류가 계속 나면 호스트의 "바뀔 때만 로그"가 걸러 준다.
pub export fn maru_mobile_clear_error() void {
    @memset(&last_error, 0);
}

pub export fn maru_mobile_quads() [*]const MaruQuad {
    return &quad_buf;
}

/// build 가 낼 수 있는 **최대** quad 수. 플랫폼이 GPU 버퍼를 이만큼 잡으면 잘릴 일이 없다.
/// 상한을 host 마다 손으로 적어 두면 어긋난다 — 실제로 iOS 는 늘리고 Android 는 4096 에서
/// **조용히 자르고** 있었다. 아는 쪽이 답한다.
pub export fn maru_mobile_max_quads() u32 {
    return @intCast(quad_buf.len);
}
