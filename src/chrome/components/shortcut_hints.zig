//! ShortcutHints — 모디파이어 홀드 시 각 chrome 요소(사이드바 워크스페이스 카드·새 워크스페이스 버튼·탭바·활성
//! pane 등)의 **우상단에 그 요소를 동작시키는 단축키 배지**를 그린다(한 박스 목록이 아니라 요소별 배지 — 사용자
//! 요청: "각 단축키로 동작되는 아이콘/위치에, div로 치면 relative parent에 absolute right:0 top:0"). chrome 컴포넌트
//! 계약 중 **State + view만 — handle 없음**(입력 비소비 — 사용자가 모디파이어를 누른 채 실제 키를 눌러야 하므로).
//! 가시성은 platform이 ABI로 토글하고(host.key_hints.visible), 배지 목록(요소 rect + 단축키 chord)은 platform이
//! 요소 레이아웃에서 빌드해 주입한다(중립 chrome은 세션/카탈로그를 모름 — find/palette의 row 주입과 동형).
//!
//! 배지 렌더: 요소 rect **우상단**에 셀 배경 fill(keycap_bg role) + chord glyph text(surface_fg). platform이 이 ops를
//! transparent_default로 rasterize해 배지 외 영역은 chrome/터미널이 비친다(요소 위 흩어진 배지라 패널 박스가 없다 —
//! rasterizeOverlayCells가 bbox 전체를 surface_bg로 덮는 모달 패널 경로와 다르다). 단일 출처: docs/keybind-hints.md.

const std = @import("std");
const draw = @import("../draw.zig");
const tokens = @import("../tokens.zig");
const props = @import("../props.zig");
const ui_badge = @import("../ui/badge.zig");
const overlay_input = @import("overlay_input.zig"); // displayCols(EAW 표시폭)

/// 이 컴포넌트가 그리는 레이어(최상위 오버레이 — 시각만, 입력 라우팅엔 없다).
pub const layer = draw.Layer.modal;

/// 순수 상태 — 가시성만. platform 홀드 머신(keyhint_hold)이 ABI(key_hint_on_flags/on_timer/cancel) 경유로 토글한다.
pub const State = struct { visible: bool = false };

/// 한 배지 = 요소의 backing px rect + 그 요소를 동작시키는 단축키 chord 문자열(예: 카드엔 "⌘1", 새 워크스페이스
/// 버튼엔 "⌘⇧T"). platform이 요소 레이아웃에서 rect를, command_catalog에서 chord를 빌드해 채운다.
pub const Badge = struct { rect: draw.Rect, chord: []const u8 };

/// 각 배지를 요소 rect **우상단**(right:0 top:0)에 그린다 — 셀 배경 fill(keycap_bg) + chord glyph text. 안 보이거나
/// 배지가 없으면 무동작. 순수: state·badges·metrics만 읽는다(색은 ColorRole로 ops에 실어 백엔드가 해석 — tk 직접 안 씀).
pub fn view(
    state: *const State,
    badges: []const Badge,
    p: props.ChromeProps,
    tk: *const tokens.Tokens,
    arena: std.mem.Allocator,
    out: *std.ArrayList(draw.Op),
) !void {
    _ = tk;
    if (!state.visible) return;
    const cw = @max(p.metrics.cell_width_px, 1);
    const ch = @max(p.metrics.cell_height_px, 1);
    for (badges) |b| {
        // 자리·크기(우상단 정렬, 요소보다 넓으면 좌단 clamp)는 badge 프리미티브가 소유한다.
        const key = ui_badge.keycap(b.rect, overlay_input.displayCols(b.chord), cw, ch) orelse continue;
        try out.append(arena, .{ .fill = .{ .rect = key.box, .role = .keycap_bg } });
        const runs = try arena.alloc(draw.Run, 1);
        runs[0] = .{ .text = b.chord };
        try out.append(arena, .{ .text = .{ .origin = .{ .x = key.box.x, .y = key.box.y }, .runs = runs, .role = .surface_fg } });
    }
}

// ── 테스트 ──────────────────────────────────────────────────────────────────────
// 패시브 배지라 입력(handle)이 없으니, (1) visible 게이트 (2) 각 배지가 요소 rect 우상단에 fill(keycap_bg)+chord text를
// 내는지 (3) 요소보다 넓은 chord는 좌단 clamp를 헤드리스로 증명한다 — macOS·렌더 없이.

fn testTokens() tokens.Tokens {
    const Rgb = @import("../../color.zig").Rgb;
    return tokens.Tokens{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
}

test "shortcut_hints view: visible=false면 ops 0" {
    const tk = testTokens();
    const p = props.ChromeProps{ .metrics = .{ .cell_width_px = 8, .cell_height_px = 16, .sidebar_width_px = 200, .backing_width_px = 800, .backing_height_px = 600 } };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.ArrayList(draw.Op) = .empty;

    const badges = [_]Badge{.{ .rect = .{ .x = 0, .y = 48, .w = 200, .h = 70 }, .chord = "⌘1" }};
    var s = State{};
    try view(&s, &badges, p, &tk, arena, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "shortcut_hints view: 각 배지가 요소 우상단에 fill(keycap_bg)+chord text" {
    const tk = testTokens();
    const p = props.ChromeProps{ .metrics = .{ .cell_width_px = 8, .cell_height_px = 16, .sidebar_width_px = 200, .backing_width_px = 800, .backing_height_px = 600 } };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.ArrayList(draw.Op) = .empty;

    // 사이드바 카드(x=0..200, y=48..118)에 ⌘1 배지. 배지는 카드 우상단.
    const badges = [_]Badge{.{ .rect = .{ .x = 0, .y = 48, .w = 200, .h = 70 }, .chord = "⌘1" }};
    var s = State{ .visible = true };
    try view(&s, &badges, p, &tk, arena, &out);

    // fill(배경) + text(chord) = 2 ops.
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expect(out.items[0] == .fill);
    try std.testing.expect(out.items[0].fill.role == .keycap_bg);
    // "⌘1" = 2칸 = 16px. 우단 200에서 왼쪽 → x = 200-16 = 184. y = 카드 상단 48.
    try std.testing.expectEqual(@as(i32, 184), out.items[0].fill.rect.x);
    try std.testing.expectEqual(@as(i32, 48), out.items[0].fill.rect.y);
    try std.testing.expectEqual(@as(u32, 16), out.items[0].fill.rect.w);
    try std.testing.expect(out.items[1] == .text);
    try std.testing.expectEqualStrings("⌘1", out.items[1].text.runs[0].text);
    try std.testing.expectEqual(@as(i32, 184), out.items[1].text.origin.x);
}

test "shortcut_hints view: chord가 요소보다 넓으면 좌단 clamp + 여러 배지" {
    const tk = testTokens();
    const p = props.ChromeProps{ .metrics = .{ .cell_width_px = 8, .cell_height_px = 16, .sidebar_width_px = 200, .backing_width_px = 800, .backing_height_px = 600 } };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.ArrayList(draw.Op) = .empty;

    const badges = [_]Badge{
        .{ .rect = .{ .x = 100, .y = 0, .w = 8, .h = 16 }, .chord = "⌘⇧T" }, // 요소 8px < chord 3칸(24px) → 좌단 clamp
        .{ .rect = .{ .x = 400, .y = 32, .w = 400, .h = 568 }, .chord = "⌘D" }, // 활성 pane
    };
    var s = State{ .visible = true };
    try view(&s, &badges, p, &tk, arena, &out);

    // 배지 2개 × (fill+text) = 4 ops.
    try std.testing.expectEqual(@as(usize, 4), out.items.len);
    // 첫 배지: 요소(8px)보다 chord(24px) 넓음 → 좌단(x=100)으로 clamp(밖으로 안 나감).
    try std.testing.expectEqual(@as(i32, 100), out.items[0].fill.rect.x);
    // 둘째 배지(pane): ⌘D=2칸=16px, 우단 800에서 → x=784.
    try std.testing.expectEqual(@as(i32, 784), out.items[2].fill.rect.x);
    try std.testing.expectEqual(@as(i32, 32), out.items[2].fill.rect.y);
    try std.testing.expectEqualStrings("⌘D", out.items[3].text.runs[0].text);
}
