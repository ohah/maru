//! ShortcutHints — 모디파이어 홀드 시 **활성 pane 우상단**에 뜨는 패시브 힌트 오버레이(HUD). 현재 바인딩된
//! 단축키를 카테고리별 **키캡(keycap)**으로 보여 준다. chrome 컴포넌트 계약 중 **State + view만 — handle이 없다**:
//! 입력을 절대 소비하지 않는다(사용자가 Cmd를 누른 채 그 단축키 키를 실제로 눌러야 하므로 — find/palette 같은
//! 모달과 정반대). 가시성은 platform이 ABI로 토글하고(host.key_hints.visible), 내용 rows는 platform이
//! command_catalog로 빌드해 주입한다(palette/context_menu와 동형 — 중립 chrome은 catalog를 import 못 함).
//!
//! 키캡 렌더: 키 1개 = 셀 배경 fill(keycap_bg role) + 중앙 글리프 text. fill이라 글리프가 그 셀 배경 **위에**
//! 그려져 키 배경색이 보인다(palette 선택행과 같은 합성). keycap_bg는 패널 대비(명암 기준 밝게/어둡게)라 tui·rich·
//! light·dark 모두 또렷하다. 컴포넌트는 if(rich) 없이 keycap_bg role만 읽는다(토큰셋 교체). 둥근 GPU quad 키캡은
//! 셀-그리드서 불가(글리프 셀 배경에 가리거나 글리프를 덮음) — 평탄 색 셀이 한계. 단일 출처: docs/keybind-hints.md.

const std = @import("std");
const draw = @import("../draw.zig");
const tokens = @import("../tokens.zig");
const props = @import("../props.zig");
const overlay_input = @import("overlay_input.zig"); // displayCols(EAW) + paneTopRightBox(활성 pane 우상단 멀티행)

/// 이 컴포넌트가 그리는 레이어(find와 같은 최상위 오버레이 Z — **시각만**, 입력 라우팅엔 없다).
pub const layer = draw.Layer.modal;

/// 레이아웃 상수(view ↔ 폭 계산이 공유하는 단일 출처): 캡 사이 1칸, 캡 묶음과 제목 사이 2칸, 박스 안쪽 좌우 1칸.
const cap_gap_cols: u32 = 1;
const title_gap_cols: u32 = 2;
const inner_pad_cols: u32 = 1;

/// 순수 상태 — 가시성만. platform이 ABI(set_key_hints)로 토글한다. 입력 라우팅 대상이 아니라 open이 아니라 visible.
pub const State = struct { visible: bool = false };

/// 한 행 = 카테고리 헤더 또는 바인딩(키캡들 + 제목). platform이 빌드해 주입한다(중립 chrome은 catalog/액션을 모름).
pub const Row = union(enum) {
    header: []const u8,
    binding: Binding,

    /// caps = 키별 글리프(예: `["⌘","T"]` — command_catalog.chordKeycaps가 chord를 키별로 편 것). title = 사람이 읽는 액션명.
    pub const Binding = struct { caps: []const []const u8, title: []const u8 };
};

/// 키캡 한 칸의 표시 폭(칸) — 글리프 EAW. (rich 시각 패딩은 lowering ±pad라 셀 폭은 불변.)
fn capCols(cap: []const u8) u32 {
    return overlay_input.displayCols(cap);
}

/// 한 바인딩 행의 표시 폭(칸) = 캡들 + 캡간격 + 제목간격 + 제목. view의 좌표 진행과 **같은 식**이라 폭과 배치가 어긋나지 않는다.
fn bindingCols(b: Row.Binding) u32 {
    var c: u32 = 0;
    for (b.caps, 0..) |cap, i| {
        if (i > 0) c += cap_gap_cols;
        c += capCols(cap);
    }
    return c + title_gap_cols + overlay_input.displayCols(b.title);
}

fn rowCols(row: Row) u32 {
    return switch (row) {
        .header => |h| overlay_input.displayCols(h),
        .binding => |b| bindingCols(b),
    };
}

/// rows를 활성 pane 우상단 멀티행 박스로 그린다. 안 보이거나(visible=false)·rows 0·영역 0칸이면 무동작.
/// 순수: state·rows·props·shape 토큰만 읽는다(색은 ColorRole로 ops에 실어 백엔드가 토큰으로 해석 — tk 직접 안 씀).
/// ops·runs 슬라이스는 호출자 frame arena가 소유한다.
pub fn view(
    state: *const State,
    rows: []const Row,
    p: props.ChromeProps,
    tk: *const tokens.Tokens,
    arena: std.mem.Allocator,
    out: *std.ArrayList(draw.Op),
) !void {
    _ = tk; // 색은 ColorRole로 흐른다(find와 동일) — 토큰 해석은 백엔드.
    if (!state.visible or rows.len == 0) return;

    // 박스 크기 = 가장 넓은 행 + 안쪽 좌우 패딩, 행 수 = rows. paneTopRightBox가 pane 폭/높이로 clamp한다.
    var max_cols: u32 = 0;
    for (rows) |row| max_cols = @max(max_cols, rowCols(row));
    const content_cols = max_cols + 2 * inner_pad_cols;
    const box = overlay_input.paneTopRightBox(p, content_cols, @intCast(rows.len)) orelse return;
    const cw = box.cw;
    const ch = box.ch;
    const bg_r = p.shape.corner_radius_px; // tui=0(직각·셀 배경) / rich>0(둥근)
    const bw = p.shape.border_width_px;

    // 패널 배경(find와 같은 surface_bg quad + focus_accent 테두리 — 모양은 p.shape 토큰).
    try out.append(arena, .{ .quad = .{
        .rect = .{ .x = box.x, .y = box.y, .w = box.cols * cw, .h = box.rows * ch },
        .fill_role = .surface_bg,
        .corner_radii = .{ bg_r, bg_r, bg_r, bg_r },
        .border_widths = .{ bw, bw, bw, bw },
        .border_role = .focus_accent,
    } });

    const x0 = box.x + @as(i32, @intCast(inner_pad_cols * cw)); // 안쪽 좌측 패딩
    const n = @min(rows.len, @as(usize, box.rows)); // 박스 높이 초과분은 안 그린다(짧은 pane — 나머지는 클립)
    for (rows[0..n], 0..) |row, i| {
        const y = box.y + @as(i32, @intCast(@as(u32, @intCast(i)) * ch));
        switch (row) {
            .header => |h| {
                // 카테고리 제목(굵게, 흐린 색) — 스코프 구분(Workspace / Pane …).
                const runs = try arena.alloc(draw.Run, 1);
                runs[0] = .{ .text = h, .bold = true };
                try out.append(arena, .{ .text = .{ .origin = .{ .x = x0, .y = y }, .runs = runs, .role = .muted_fg } });
            },
            .binding => |b| {
                var col: u32 = 0;
                // 키캡들: 각 캡 = 셀 배경 fill(keycap_bg) + 중앙 글리프 text(surface_fg). **fill(셀 배경)이라 글리프가
                // 그 위에 그려져 키 배경색이 보인다**(palette 선택행과 같은 합성). rich는 keycap_bg가 패널보다 밝아 또렷한
                // 키 박스로, tui는 keycap_bg=패널색이라 평탄(글리프만 — 기존 룩 보존). 셀 정렬(정수 칸).
                // 베이스/결정: 둥근 GPU quad는 글리프 셀의 불투명 배경에 가려지거나(layer 1) 글리프를 덮으므로(layer 3),
                // 셀-그리드 오버레이의 per-key 키캡은 **평탄 색 셀**이 한계다(둥근 키캡은 셀 텍스트 모델 밖 — 후속).
                for (b.caps, 0..) |cap, ci| {
                    if (ci > 0) col += cap_gap_cols;
                    const w = capCols(cap);
                    const cx = x0 + @as(i32, @intCast(col * cw));
                    try out.append(arena, .{ .fill = .{ .rect = .{ .x = cx, .y = y, .w = w * cw, .h = ch }, .role = .keycap_bg } });
                    const cap_runs = try arena.alloc(draw.Run, 1);
                    cap_runs[0] = .{ .text = cap };
                    try out.append(arena, .{ .text = .{ .origin = .{ .x = cx, .y = y }, .runs = cap_runs, .role = .surface_fg } });
                    col += w;
                }
                // 제목: 캡 묶음 뒤 title_gap_cols 띄우고 좌측 정렬.
                col += title_gap_cols;
                const title_runs = try arena.alloc(draw.Run, 1);
                title_runs[0] = .{ .text = b.title };
                try out.append(arena, .{ .text = .{ .origin = .{ .x = x0 + @as(i32, @intCast(col * cw)), .y = y }, .runs = title_runs, .role = .surface_fg } });
            },
        }
    }
}

// ── 테스트 ──────────────────────────────────────────────────────────────────────
// 패시브 HUD라 입력(handle)이 없으니, (1) visible 게이트 (2) view가 활성 pane 우상단에 패널 + 카테고리 헤더 +
// 키캡(fill 셀배경+글리프) + 제목 ops를 내는지 (3) 높이 초과 시 행 클램프를 헤드리스로 증명한다 — macOS·렌더 없이.

fn testTokens() tokens.Tokens {
    const Rgb = @import("../../color.zig").Rgb;
    return tokens.Tokens{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
}

test "shortcut_hints view: visible=false면 ops 0" {
    const tk = testTokens();
    const p = props.ChromeProps{ .metrics = .{ .cell_width_px = 8, .cell_height_px = 16, .sidebar_width_px = 40, .backing_width_px = 800, .backing_height_px = 600 } };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.ArrayList(draw.Op) = .empty;

    const rows = [_]Row{ .{ .header = "Workspace" }, .{ .binding = .{ .caps = &.{ "⌘", "T" }, .title = "New Terminal" } } };
    var s = State{};
    try view(&s, &rows, p, &tk, arena, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len); // 안 보임
}

test "shortcut_hints view: 헤더 + 키캡 바인딩 → 패널 quad + 헤더 text + 캡(fill+글리프) + 제목 text" {
    const tk = testTokens();
    // 활성 pane = 창 오른쪽 절반(x=400..800, top=32) — 패널이 그 pane 우상단에 붙는다.
    const p = props.ChromeProps{
        .metrics = .{ .cell_width_px = 8, .cell_height_px = 16, .sidebar_width_px = 40, .backing_width_px = 800, .backing_height_px = 600 },
        .active_pane = .{ .x = 400, .y = 32, .w = 400, .h = 568 },
    };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.ArrayList(draw.Op) = .empty;

    const rows = [_]Row{
        .{ .header = "Workspace" },
        .{ .binding = .{ .caps = &.{ "⌘", "T" }, .title = "New Terminal" } },
    };
    var s = State{ .visible = true };
    try view(&s, &rows, p, &tk, arena, &out);

    // 패널 quad(1) + 헤더 text(1) + 캡 ⌘(fill+text=2) + 캡 T(fill+text=2) + 제목 text(1) = 7.
    try std.testing.expectEqual(@as(usize, 7), out.items.len);
    try std.testing.expect(out.items[0] == .quad); // 패널 배경
    try std.testing.expect(out.items[0].quad.rect.x >= 400); // 활성 pane 안(왼쪽 pane 비침범)
    try std.testing.expectEqual(@as(i32, 800), out.items[0].quad.rect.x + @as(i32, @intCast(out.items[0].quad.rect.w))); // 우단 = pane 우단
    try std.testing.expectEqual(@as(i32, 48), out.items[0].quad.rect.y); // pane top(32) + 한 줄(16)

    // 헤더(굵게).
    try std.testing.expect(out.items[1] == .text);
    try std.testing.expectEqualStrings("Workspace", out.items[1].text.runs[0].text);
    try std.testing.expect(out.items[1].text.runs[0].bold);

    // 첫 캡 = 셀 배경 fill(keycap_bg) + 글리프 "⌘"(글리프가 fill 위에 그려져 키 배경색이 보인다).
    try std.testing.expect(out.items[2] == .fill);
    try std.testing.expect(out.items[2].fill.role == .keycap_bg);
    try std.testing.expect(out.items[3] == .text);
    try std.testing.expectEqualStrings("⌘", out.items[3].text.runs[0].text);
    // 둘째 캡 = fill + 글리프 "T", 첫 캡보다 오른쪽(캡 간격).
    try std.testing.expect(out.items[4] == .fill);
    try std.testing.expectEqualStrings("T", out.items[5].text.runs[0].text);
    try std.testing.expect(out.items[4].fill.rect.x > out.items[2].fill.rect.x);
    // 제목 = 캡 묶음 뒤.
    try std.testing.expectEqualStrings("New Terminal", out.items[6].text.runs[0].text);
    try std.testing.expect(out.items[6].text.origin.x > out.items[4].fill.rect.x);
}

test "shortcut_hints view: 행이 pane 높이를 넘으면 클램프 (짧은 pane)" {
    const tk = testTokens();
    // pane 높이 48px = 3행, 상단 1행 오프셋 → 가용 2행. 헤더 1 + 바인딩 3 = 4행 콘텐츠지만 2행만 그린다.
    const p = props.ChromeProps{
        .metrics = .{ .cell_width_px = 8, .cell_height_px = 16, .sidebar_width_px = 0, .backing_width_px = 800, .backing_height_px = 600 },
        .active_pane = .{ .x = 0, .y = 0, .w = 400, .h = 48 },
    };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.ArrayList(draw.Op) = .empty;

    const rows = [_]Row{
        .{ .header = "Workspace" },
        .{ .binding = .{ .caps = &.{"⌘"}, .title = "a" } },
        .{ .binding = .{ .caps = &.{"⌘"}, .title = "b" } },
        .{ .binding = .{ .caps = &.{"⌘"}, .title = "c" } },
    };
    var s = State{ .visible = true };
    try view(&s, &rows, p, &tk, arena, &out);

    // 패널 quad(1) + 2행만: 헤더 text(1) + 바인딩 1행(캡 quad+글리프 + 제목 = 3) = 5 ops. 3·4번째 행은 클립.
    try std.testing.expectEqual(@as(usize, 5), out.items.len);
    try std.testing.expectEqual(@as(u32, 32), out.items[0].quad.rect.h); // 박스 높이 = 2행(2×16)
    // 마지막 그려진 제목은 "a"(둘째 행) — "b"/"c"는 안 그려짐.
    try std.testing.expectEqualStrings("a", out.items[4].text.runs[0].text);
}
