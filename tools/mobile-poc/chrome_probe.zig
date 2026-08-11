//! PoC 6: **maru 의 실제 chrome 컴포넌트**로 UI 를 조립해 모바일 GPU 로 그린다.
//!
//! 앞 단계들은 색 격자를 손으로 그렸다. 여기서는 `chrome.ui.tree` 로 UiNode 를 조립하고
//! `tree.build` 로 레이아웃을 돌린 뒤 `paint` 로 ChromeDraw 를 얻는다 — **데스크톱이 쓰는
//! 바로 그 경로**다. 플랫폼은 나온 op 을 그리기만 한다.
const std = @import("std");
// **모듈 루트는 `maru.zig` 하나다.** chrome·renderer 를 따로 주면 둘 다 `icons.zig` 를
// 상대 경로로 끌어와 "file exists in two modules" 로 깨진다(실측). 배럴 하나로 받으면
// 상대 import 가 전부 같은 모듈 안에서 풀린다.
const maru = @import("maru");
const chrome = maru.chrome;
const icon_glyph = maru.renderer.icon_glyph;

const tree = chrome.ui.tree;
const layout = chrome.ui.layout;
const paint_mod = chrome.ui.paint;
const draw = chrome.draw;
const tokens = chrome.tokens;

/// 플랫폼이 그릴 수 있는 최소 형태로 평탄화한 quad. ChromeDraw 의 op 은 union 이라
/// C 에서 다루기 번거로우니, 여기서 rect + 색 + radius 로 낮춰 넘긴다.
pub const CQuad = extern struct {
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

var quad_buf: [512]CQuad = undefined;
var quad_count: usize = 0;

/// 데스크톱 기본 테마에 가까운 값. 실제 제품은 config 에서 오지만 PoC 는 고정한다.
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
        .accent = .{ .r = 0xDD, .g = 0xA1, .b = 0x5E },   // maru 앰버
    };
}

fn push(rect: draw.Rect, rgb: anytype, alpha: u8, radius: u16, kind: u32) void {
    if (quad_count == quad_buf.len) return;
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
var atlas_cp: [256]u32 = undefined;
var atlas_col: [256]u32 = undefined;
var atlas_row: [256]u32 = undefined;
var atlas_adv: [256]u32 = undefined;
var atlas_n: usize = 0;
/// 아틀라스 셀 크기(px). 종횡비를 지켜 그려야 글자가 안 늘어난다.
var atlas_cell_w: u32 = 24;
var atlas_cell_h: u32 = 32;

export fn maru_atlas_geometry(cell_w: u32, cell_h: u32) void {
    atlas_cell_w = cell_w;
    atlas_cell_h = cell_h;
}

export fn maru_atlas_add(cp: u32, col: u32, row: u32, advance: u32) void {
    if (atlas_n == atlas_cp.len) return;
    atlas_cp[atlas_n] = cp;
    atlas_col[atlas_n] = col;
    atlas_row[atlas_n] = row;
    atlas_adv[atlas_n] = advance;
    atlas_n += 1;
}

fn atlasCell(cp: u21) ?struct { col: u32, row: u32, adv: u32 } {
    for (0..atlas_n) |i| if (atlas_cp[i] == cp)
        return .{ .col = atlas_col[i], .row = atlas_row[i], .adv = atlas_adv[i] };
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
                if (quad_count < quad_buf.len) {
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

export fn maru_icon_atlas() [*]const u8 {
    return &icon_pixels;
}
export fn maru_icon_slot_px() u32 {
    return icon_slot_px;
}
export fn maru_icon_count() u32 {
    return icon_slots;
}

/// 아이콘 coverage 를 채우고, 실제로 잉크가 있는 슬롯 수를 돌려준다(0이면 자산 이식 실패).
export fn maru_icon_build() u32 {
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
        tree.card(.{ .id = 101, .style = .{ .flex = .{ .grow = 1 }, .height = .{ .px = 34.0 },
                                            .margin = .{ .right = 6.0 } },
                     .variant = .selected }, &tab_kids[0]),
        tree.card(.{ .id = 102, .style = .{ .flex = .{ .grow = 1 }, .height = .{ .px = 34.0 },
                                            .margin = .{ .right = 6.0 } },
                     .variant = .surface }, &tab_kids[1]),
        tree.card(.{ .id = 103, .style = .{ .flex = .{ .grow = 1 }, .height = .{ .px = 34.0 } },
                     .variant = .surface }, &tab_kids[2]),
    };
    const tab_bar = tree.container(.{ .id = 100, .direction = .row,
                                      .style = .{ .height = .{ .px = 46.0 },
                                                  .padding = .{ .left = 12.0, .right = 12.0, .top = 6.0, .bottom = 6.0 } } },
                                   &tabs);

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
            .style = .{ .width = .{ .percent = 1.0 }, .height = .{ .px = 52.0 },
                        .margin = .{ .bottom = 8.0 } },
            .variant = if (i == 1) .selected else .surface,
        }, &side_kids[i]);
    }
    const sidebar = tree.container(.{ .id = 200, .direction = .column,
                                      .style = .{ .width = .{ .percent = 0.34 },
                                                  .padding = .{ .left = 10.0, .right = 10.0, .top = 10.0, .bottom = 10.0 } } },
                                   &side_children);

    // ── 본문: 터미널 영역(카드 하나) + 그 안의 텍스트 줄들
    const output = [_][]const u8{
        "$ zig build test",
        "  All 11 passed.",
        "$ git status --short",
        "  M src/chrome/ui/tree.zig",
        "  한글 터미널 세션",
        "$ maru 0.1.0 (arm64)",
        "  목록 설정 검색 알림",
    };
    var lines: [7]tree.UiNode = undefined;
    for (&lines, 0..) |*l, i| {
        l.* = tree.text(.{
            .id = @intCast(310 + i),
            // column 안에서 width 는 cross axis 다 — `.fill` 은 main axis 전용이라 거부된다
            // (FillOnCrossAxis). 폭을 화면에 맞추려면 percent 를 쓴다.
            .style = .{ .width = .{ .percent = 1.0 },
                        .height = .{ .px = 15.0 }, .margin = .{ .bottom = 7.0 } },
            .value = output[i],
            .tone = if (output[i][0] == '$') .accent else .primary,
        });
    }
    const body = tree.container(.{ .id = 300, .direction = .column,
                                   .style = .{ .flex = .{ .grow = 1 },
                                               .padding = .{ .left = 16.0, .right = 16.0, .top = 14.0, .bottom = 14.0 } } },
                                &lines);

    const middle = tree.container(.{ .id = 20, .direction = .row, .style = .{ .flex = .{ .grow = 1 } } },
                                  &.{ sidebar, body });

    // ── 상태바
    const status = tree.container(.{ .id = 400, .direction = .row,
                                     .style = .{ .height = .{ .px = 26.0 },
                                                 .padding = .{ .left = 12.0, .right = 12.0, .top = 5.0, .bottom = 5.0 } } },
                                  &.{
        tree.card(.{ .id = 401, .style = .{ .flex = .{ .grow = 1 }, .height = .{ .px = 16.0 },
                                            .margin = .{ .right = 10.0 } },
                     .variant = .raised }, &.{}),
        tree.card(.{ .id = 402, .style = .{ .flex = .{ .grow = 1.4 }, .height = .{ .px = 16.0 } },
                     .variant = .raised }, &.{}),
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
        .rule => |r| push(.{ .x = r.from.x, .y = r.from.y,
                             .w = @intCast(@max(1, r.to.x - r.from.x)),
                             .h = @intCast(@max(1, r.to.y - r.from.y)) }, tk.get(r.role), 0xFF, 0, 0),
        // 글리프 아틀라스가 없으므로 텍스트는 **글자 수에 비례한 박스**로 자리만 표시한다.
        // 실제 이식에서는 CoreText/FreeType 로 래스터한 아틀라스를 샘플링한다.
        .text => |tx| {
            var chars: u32 = 0;
            for (tx.runs) |run| chars += @intCast(run.text.len);
            push(.{ .x = tx.origin.x, .y = tx.origin.y, .w = chars * 7 + 2, .h = 13 },
                 tk.get(tx.role), 0xC0, 2, 0);
        },
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

    // **SVG 아이콘**: maru 의 등록 아이콘을 그대로 얹는다. coverage 는 Zig 가 만들고
    // (renderer/icon_glyph) 플랫폼은 텍스처로 올려 샘플링만 한다 — 자산이 이식된다는 증거다.
    const icon_y: i32 = @intFromFloat(@max(0, height_f - 24));
    const icon_step: i32 = 26;
    const icon_x0: i32 = @as(i32, @intCast(width)) - icon_step * 6 - 12;
    for (0..6) |i| {
        if (quad_count == quad_buf.len) break;
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
        310 => "$ zig build test",
        311 => "  All 11 passed.",
        312 => "$ git status --short",
        313 => "  M src/chrome/ui/tree.zig",
        314 => "  한글 터미널 세션",
        315 => "$ maru 0.1.0 (arm64)",
        316 => "  목록 설정 검색 알림",
        else => null,
    };
}

/// 플랫폼이 부른다: UI 를 조립하고 quad 개수를 돌려준다.
/// 마지막 오류 이름. 0 quads 가 나왔을 때 **무엇이 실패했는지** 플랫폼이 볼 수 있어야 한다 —
/// catch 로 삼키면 화면이 비어 있는 이유를 알 수 없다(실측: 처음에 그렇게 짰다가 헤맸다).
var last_error: [64]u8 = [_]u8{0} ** 64;

export fn maru_chrome_build(width: u32, height: u32) u32 {
    quad_count = 0;
    @memset(&last_error, 0);
    const tk = tokens.Tokens.rich(themeColors());
    buildUi(width, height, &tk) catch |err| {
        const name = @errorName(err);
        const n = @min(name.len, last_error.len - 1);
        @memcpy(last_error[0..n], name[0..n]);
        return 0;
    };
    return @intCast(quad_count);
}

export fn maru_chrome_last_error() [*:0]const u8 {
    return @ptrCast(&last_error);
}

export fn maru_chrome_quads() [*]const CQuad {
    return &quad_buf;
}
