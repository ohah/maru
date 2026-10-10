//! macOS Chrome Metal lowering — backend-neutral `ChromeDraw`를 제품 Metal frame 입력으로 바꾼다.
//!
//! 이 leaf는 세션·PTY·provider·`AppSession`을 모른다. 일반 Chrome과 Chrome Lab이 같은
//! 변환을 공유하도록, semantic draw를 cell/quad/shadow 입력으로만 투영한다.

const std = @import("std");
const maru = @import("maru");
const chrome = maru.chrome;
const renderer = maru.renderer;
const terminal = maru.terminal;
const Rgb = maru.color.Rgb;
const metal_frame = renderer.metal_frame;

/// 한 셀 격자에 내린 오버레이 묶음 — **연속한, 칸 위상이 같은 draw 들**이다(`lower` 주석). 격자 원점은 그 묶음의 좌상단이다.
pub const OverlayPart = struct {
    cells: std.ArrayList(renderer.DrawCell),
    cols: u16,
    rows: u16,
    origin_x: u32,
    origin_y: u32,
    cursor: ?terminal.Cursor = null,
    clip_rect: ?chrome.draw.Rect = null,
};

/// 한 Chrome overlay를 제품 frame에 합성하기 직전의 소유 버퍼.
///
/// 셀 필드(`cells`·`cols`·`rows`·`origin_*`·`cursor`·`clip_rect`)는 **첫 묶음**이고, 위상이 다른 뒤 묶음은 `extra_parts` 에
/// painter 순서대로 든다(대부분의 프레임은 묶음 하나라 비어 있다 — 그때는 예전과 같은 격자 한 장이다). caret 은 프레임에 하나이고,
/// 그것을 그린 묶음의 `cursor` 에만 선다. GPU quad·그림자는 묶음과 무관하게 픽셀 그대로라 한 목록이다.
pub const OverlayRaster = struct {
    cells: std.ArrayList(renderer.DrawCell),
    gpu_quads: std.ArrayList(metal_frame.GpuQuad),
    gpu_shadows: std.ArrayList(metal_frame.GpuShadow),
    cols: u16,
    rows: u16,
    origin_x: u32,
    origin_y: u32,
    cursor: ?terminal.Cursor = null,
    clip_rect: ?chrome.draw.Rect = null,
    extra_parts: std.ArrayList(OverlayPart) = .empty,

    pub fn deinit(self: *OverlayRaster, allocator: std.mem.Allocator) void {
        self.cells.deinit(allocator);
        self.gpu_quads.deinit(allocator);
        self.gpu_shadows.deinit(allocator);
        self.deinitExtraParts(allocator);
    }

    /// 뒤 묶음만 놓는다 — 첫 묶음의 셀·quad 는 호출자가 따로 옮겨 갔을 때 쓴다.
    pub fn deinitExtraParts(self: *OverlayRaster, allocator: std.mem.Allocator) void {
        for (self.extra_parts.items) |*part| part.cells.deinit(allocator);
        self.extra_parts.deinit(allocator);
    }
};

/// 한 묶음의 셀 격자(작업 버퍼). 셀마다 「마지막으로 쓴 draw」(`owner`)를 들고, 뒤 draw 의 패널이 앞 draw 의 셀을 덮게 하는 데 쓴다.
const Grid = struct {
    bg: []terminal.Color,
    fg: []terminal.Color,
    cp: []u21,
    cwid: []u2,
    owner: []u16,
    cols: u16,
    rows: u16,
    origin_x: u32,
    origin_y: u32,
    frame_clip: bool,
    clip_rect: ?chrome.draw.Rect = null,
};

/// draw 하나가 내는 사각형(fill·border·quad)의 합집합과 `.clip` 유무.
const DrawBox = struct {
    have: bool = false,
    min_x: i32 = std.math.maxInt(i32),
    min_y: i32 = std.math.maxInt(i32),
    max_x: i32 = std.math.minInt(i32),
    max_y: i32 = std.math.minInt(i32),
    clip: bool = false,

    fn add(self: *DrawBox, r: chrome.draw.Rect) void {
        self.have = true;
        self.min_x = @min(self.min_x, r.x);
        self.min_y = @min(self.min_y, r.y);
        self.max_x = @max(self.max_x, r.x + @as(i32, @intCast(r.w)));
        self.max_y = @max(self.max_y, r.y + @as(i32, @intCast(r.h)));
    }

    fn merge(self: *DrawBox, o: DrawBox) void {
        if (!o.have) {
            self.clip = self.clip or o.clip;
            return;
        }
        self.add(.{ .x = o.min_x, .y = o.min_y, .w = @intCast(o.max_x - o.min_x), .h = @intCast(o.max_y - o.min_y) });
        self.clip = self.clip or o.clip;
    }

    /// 격자 원점 — 화면 밖(음수)이면 0 으로 붙인다(예전과 같은 규칙).
    fn originX(self: DrawBox) u32 {
        return if (self.min_x < 0) 0 else @intCast(self.min_x);
    }
    fn originY(self: DrawBox) u32 {
        return if (self.min_y < 0) 0 else @intCast(self.min_y);
    }
};

fn drawBox(d: chrome.ChromeDraw, cw: u32, ch: u32) DrawBox {
    var b: DrawBox = .{};
    for (d.ops) |op| {
        if (op == .clip) b.clip = true;
        const rect: ?chrome.draw.Rect = switch (op) {
            .fill => |f| f.rect,
            .border => |bo| bo.rect,
            .quad => |q| q.rect,
            else => null,
        };
        if (rect) |rr| b.add(rr);
    }
    // **사각형이 없는 draw(글자만)는 글자가 차지하는 칸으로 잰다** — 그래야 자기 위상·자기 격자를 가져 글자가 원점에 선다.
    // 앞 묶음에 붙이면 그 묶음의 격자 밖 글자가 통째로 버려졌다(예전 단일 격자에서는 합집합이 덮어 보였다 — 적대적 검증 2026-10-10).
    if (!b.have) for (d.ops) |op| switch (op) {
        .text => |t| b.add(.{ .x = t.origin.x, .y = t.origin.y, .w = @max(textCells(t), 1) * cw, .h = ch }),
        else => {},
    };
    return b;
}

/// text op 이 셀 격자에서 차지하는 칸 수 — `placeText` 와 같은 디코더·같은 폭 규칙이다.
fn textCells(t: chrome.draw.Op.Text) u32 {
    var n: u32 = 0;
    for (t.runs) |run| {
        var bi: usize = 0;
        while (bi < run.text.len) {
            const d = chrome.text_layout.decodeCodepoint(run.text, bi);
            bi += d.advance;
            const width: u32 = if (t.wide_icons and renderer.icon_glyph.isRegisteredIcon(d.cp))
                chrome.ui.icon.chrome_run_span
            else
                @max(1, terminal.width.cellWidth(d.cp));
            n += width;
        }
    }
    return n;
}

/// ChromeDraw의 painter order를 보존하며 셀과 rich GPU primitives로 투영한다.
/// `transparent_default`는 흩어진 단축키 배지가 하위 chrome/terminal을 가리지 않게 한다.
///
/// **글자는 컴포넌트가 낸 픽셀 자리에 선다**(2026-10-10) — **연속한, 칸 위상이 같은 draw** 끼리 격자 한 장으로 묶고 묶음마다 자기 원점을
/// 둔다(첫 묶음은 셀 필드, 나머지는 `extra_parts`). `.clip` 을 내는 draw 는 늘 자기 묶음이다. 단위는 draw 다. 계약·이유·한계의 단일 출처:
/// `docs/chrome-strategy.md` §5.3 「오버레이 글자는 컴포넌트가 낸 픽셀 자리에 선다」.
pub fn lower(
    allocator: std.mem.Allocator,
    draws: []const chrome.ChromeDraw,
    tk: *const chrome.Tokens,
    cw: u32,
    ch: u32,
    transparent_default: bool,
) !OverlayRaster {
    if (cw == 0 or ch == 0) return error.NoMetrics;

    var gpu_quads: std.ArrayList(metal_frame.GpuQuad) = .empty;
    errdefer gpu_quads.deinit(allocator);
    var gpu_shadows: std.ArrayList(metal_frame.GpuShadow) = .empty;
    errdefer gpu_shadows.deinit(allocator);

    // 1. draw 마다 사각형 합집합 — 묶음의 위상과 격자 범위가 여기서 나온다.
    const boxes = try allocator.alloc(DrawBox, draws.len);
    defer allocator.free(boxes);
    var have_box = false;
    for (draws, boxes) |d, *b| {
        b.* = drawBox(d, cw, ch);
        have_box = have_box or b.have;
    }
    if (!have_box) return error.NoBox;

    // 2. 묶음 — 연속한, 칸 위상이 같은 draw 끼리. 아무것도 내지 않는 draw(사각형도 글자도 없음 — `.clip`·`.rule` 만)는 위상이 없으므로
    // 앞 묶음에 붙는다(맨 앞이면 다음 것에).
    const part_of = try allocator.alloc(usize, draws.len);
    defer allocator.free(part_of);
    var part_boxes: std.ArrayList(DrawBox) = .empty;
    defer part_boxes.deinit(allocator);
    //
    // **`.clip` 을 내는 draw 는 늘 자기 묶음이다**(앞뒤와 위상이 같아도) — clip 은 그 묶음 격자 전체의 셀에 걸리므로, 같은 위상의
    // 이웃 오버레이와 묶이면 그 이웃의 글자까지 잘랐다(알림 패널 + 실패한 마커 프리뷰 등 — 적대적 검증 2026-10-10).
    {
        var phase: ?[2]u32 = null;
        var after_clip = false;
        for (boxes, 0..) |b, i| {
            if (b.have) {
                const p = [2]u32{ b.originX() % cw, b.originY() % ch };
                if (phase == null or !std.mem.eql(u32, &phase.?, &p) or b.clip or after_clip) {
                    // 맨 앞의 글자만 draw 들이 이미 묶음 0 을 열었으면 그 묶음에 위상을 준다.
                    if (phase != null or part_boxes.items.len == 0) try part_boxes.append(allocator, .{});
                    phase = p;
                }
                after_clip = b.clip;
            } else if (part_boxes.items.len == 0) try part_boxes.append(allocator, .{});
            part_of[i] = part_boxes.items.len - 1;
            part_boxes.items[part_of[i]].merge(b);
        }
    }

    // 3. 묶음마다 격자. 행 수는 보통 내림이다(상자 밖으로 셀을 안 낸다). **프레임 clip 이 있으면 올림** — 그 overlay 는 마지막 걸친 행을
    // clip 이 픽셀로 잘라 보이게 하는 계약이다(알림 패널: 뷰포트 바닥에 걸친 카드 줄, `docs/notifications.md`). 내림이면 그
    // 행이 격자에 없어 글자가 통째로 사라졌다 — 예전엔 패널 밖에 잘못 그어지던 구분선이 상자를 우연히 늘려 줘서만 보였다.
    // 넘친 몫은 같은 clip(셀 scissor, v169)이 자르므로 상자 밖에 그려지지 않는다.
    const grids = try allocator.alloc(Grid, part_boxes.items.len);
    var grids_made: usize = 0;
    defer {
        for (grids[0..grids_made]) |g| {
            allocator.free(g.bg);
            allocator.free(g.fg);
            allocator.free(g.cp);
            allocator.free(g.cwid);
            allocator.free(g.owner);
        }
        allocator.free(grids);
    }
    const surface_bg = terminal.Color{ .rgb = tk.get(.surface_bg) };
    const surface_fg = terminal.Color{ .rgb = tk.get(.surface_fg) };
    for (part_boxes.items, grids) |pb, *g| {
        const cols_u = @as(u32, @intCast(@max(pb.max_x - pb.min_x, 0))) / cw;
        const span_y: u32 = @intCast(@max(pb.max_y - pb.min_y, 0));
        const rows_u = if (pb.clip) std.math.divCeil(u32, span_y, ch) catch unreachable else span_y / ch;
        // 묶음이 하나면 예전과 같이 격자가 비면 실패다. 여럿이면 셀이 못 서는 얇은 묶음(헤어라인뿐 등)도 GPU 몫은 그려야 하므로 빈 격자로 둔다.
        if ((cols_u == 0 or rows_u == 0) and part_boxes.items.len == 1) return error.TooSmall;
        const cols: u16 = @intCast(@min(cols_u, @as(u32, std.math.maxInt(u16))));
        const rows: u16 = @intCast(@min(rows_u, @as(u32, std.math.maxInt(u16))));
        const n = @as(usize, cols) * @as(usize, rows);
        const bg = try allocator.alloc(terminal.Color, n);
        errdefer allocator.free(bg);
        const fg = try allocator.alloc(terminal.Color, n);
        errdefer allocator.free(fg);
        const cp = try allocator.alloc(u21, n);
        errdefer allocator.free(cp);
        const cwid = try allocator.alloc(u2, n);
        errdefer allocator.free(cwid);
        const owner = try allocator.alloc(u16, n);
        @memset(owner, no_owner);
        @memset(bg, surface_bg);
        @memset(fg, surface_fg);
        @memset(cp, ' ');
        @memset(cwid, 1);
        g.* = .{ .bg = bg, .fg = fg, .cp = cp, .cwid = cwid, .owner = owner, .cols = cols, .rows = rows, .origin_x = pb.originX(), .origin_y = pb.originY(), .frame_clip = pb.clip };
        grids_made += 1;
    }

    // 첫 rounded quad는 overlay의 배경·shadow이고, 그 뒤 rounded quad는 선택 행 위에 떠야 하는 widget이다.
    // 이 painter-order 규칙을 lowerer 한 곳에 둬 cell과 GPU pass의 z-order가 갈라지지 않게 한다.
    //
    // **「첫」은 draw(= 오버레이 하나)마다 센다**(2026-10-07). 예전에는 프레임 전체에서 한 번만 셌다 — 그래서 찾기 막대가
    // 열린 채 편집기를 우클릭하면 먼저 모인 찾기 막대가 그 자리를 가져가, 우클릭 메뉴의 패널이 패딩·그림자 없는 widget 으로
    // 내려가 첫 줄이 윗 테두리에 겹쳤다(실제 앱 1배율 캡처로 재현). 배치(`popup_box.visible_outset_px`)는 패딩이 있다고
    // 가정하므로 둘이 갈렸다. host 의 수집 함수는 **패널 하나당** draw 하나를 내므로(`ChromeHost.collect*Draws` — 완성 목록 옆 문서 패널도
    // 자기 draw, `SGD3`) draw 가 곧 패널 단위다(docs/chrome-strategy.md §5.4 「패널마다 draw 하나」). `independent_panel` 은 이제 「모서리 0 인 첫 quad 도 GPU 패널로 친다」만 가른다(각 열의 찾기 · 직각 완성 목록).
    var cursor: ?terminal.Cursor = null;
    var cursor_part: usize = 0;
    var cursor_owner: u16 = no_owner;
    var modal_bg_quad = false;
    for (draws, 0..) |d, draw_index| {
        const who: u16 = @intCast(@min(draw_index, no_owner - 1));
        const g = &grids[part_of[draw_index]];
        var panel_bg_quad = false;
        const background_seen = &panel_bg_quad;
        for (d.ops) |op| switch (op) {
            .fill => |f| {
                if (f.role == .cursor) {
                    const col = @divTrunc(f.rect.x - @as(i32, @intCast(g.origin_x)), @as(i32, @intCast(cw)));
                    const row = @divTrunc(f.rect.y - @as(i32, @intCast(g.origin_y)), @as(i32, @intCast(ch)));
                    if (col >= 0 and col < g.cols and row >= 0 and row < g.rows) {
                        cursor = .{ .row = @intCast(row), .col = @intCast(col), .visible = true };
                        cursor_part = part_of[draw_index];
                        cursor_owner = who;
                    }
                } else if (isHairline(f.rect, cw, ch)) {
                    // 셀보다 얇은 fill(구분선 등)은 **셀 격자로 표현할 수 없다.** paintRectBg는 픽셀 rect를
                    // `trunc(y/ch) .. trunc((y+h)/ch)` 행 범위로 내리므로, 1px이 행 마지막 픽셀에 걸리면 그 행이
                    // **통째로** 칠해지고(알림 카드 구분선이 18px 회색 밴드로 보이던 결함) 행 중간에 걸리면
                    // r0==r1이라 **아예 안 보인다**. 위치에 따라 둘 중 하나라 규율로 피할 수도 없다.
                    //
                    // 그래서 헤어라인만 GPU quad로 내린다 — `.swatch`/`.quad`가 "둥근 모서리는 셀로 못 그리니
                    // quad로"와 같은 규칙이고, 여기서는 '두께'가 그 이유다. 모달 배경 quad보다 **뒤에** append돼
                    // 같은 over 버킷 안에서 위에 그려진다(배경이 먼저 나오는 것은 lowerer의 painter 규칙).
                    appendHairline(&gpu_quads, allocator, f.rect, f.role, tk);
                } else paintRectBg(g, who, cw, ch, f.rect, .{ .rgb = tk.get(f.role) }, null);
            },
            .border => |b| if (!background_seen.*) paintRectBg(g, who, cw, ch, b.rect, .{ .rgb = tk.get(b.role) }, b.sides),
            .text => |t| placeText(g, who, cw, ch, t, tk),
            .swatch => |sw| {
                const rounded = sw.corner_radii[0] != 0 or sw.corner_radii[1] != 0 or sw.corner_radii[2] != 0 or sw.corner_radii[3] != 0;
                if (!rounded) {
                    paintRectBg(g, who, cw, ch, sw.rect, .{ .rgb = sw.rgb }, null);
                } else appendSwatch(&gpu_quads, allocator, sw);
            },
            .rule => {},
            .clip => |rect| g.clip_rect = rect,
            .quad => |q| {
                const rounded = q.corner_radii[0] != 0 or q.corner_radii[1] != 0 or q.corner_radii[2] != 0 or q.corner_radii[3] != 0;
                if (!rounded and (!d.independent_panel or background_seen.*)) {
                    paintRectBg(g, who, cw, ch, q.rect, .{ .rgb = tk.get(q.fill_role) }, null);
                } else if (background_seen.*) {
                    appendWidgetQuad(&gpu_quads, allocator, q, tk);
                } else {
                    appendModalQuad(&gpu_quads, &gpu_shadows, allocator, q, tk);
                    background_seen.* = true;
                    modal_bg_quad = true;
                    // **이 패널 아래의 앞 오버레이 셀을 지운다**(2026-10-08). 렌더러는 오버레이의 모든 패널을 그린 **뒤** 모든 셀을
                    // 그리므로(`maru_draw_overlay_layer`), 찾기 막대 위로 우클릭 메뉴가 열리면 찾기 막대의 글자가 메뉴 패널을
                    // 뚫고 보였다(실제 앱 1배율 캡처로 재현). 셀이 패널 순서를 따르게, 보이는 패널(패딩 포함) 안에 중심이 든
                    // 앞 draw 의 셀을 비운다 — 패널은 그 draw 의 첫 op 이라 이 draw 의 셀은 아직 없다. **앞 묶음의 격자도 본다**
                    // (2026-10-10) — 위상이 다른 앞 오버레이는 다른 격자에 있고, 판정은 셀마다 자기 격자 원점으로 픽셀 중심을 잰다.
                    const p = panelPadding(q, tk);
                    const box = q.rect.outset(.{ .left = p, .right = p, .top = p, .bottom = p });
                    for (grids[0 .. part_of[draw_index] + 1]) |*hg| hideCellsUnder(hg, who, cw, ch, box, surface_bg, surface_fg);
                    if (cursor) |c| {
                        const cg = &grids[cursor_part];
                        if (cursor_owner != who and cellCenterIn(c.col, c.row, cg.origin_x, cg.origin_y, cw, ch, box)) {
                            cursor = null; // 앞 오버레이의 caret 도 셀 다음에 그려진다 — 덮인 caret 은 안 그린다
                            cursor_owner = no_owner;
                        }
                    }
                }
            },
        };
    }

    // 4. 묶음마다 셀을 낸다. 빈 칸 투명 처리는 프레임 단위다(패널 quad 가 하나라도 있으면 — 예전과 같다).
    var extra_parts: std.ArrayList(OverlayPart) = .empty;
    errdefer {
        for (extra_parts.items) |*part| part.cells.deinit(allocator);
        extra_parts.deinit(allocator);
    }
    var first_cells: std.ArrayList(renderer.DrawCell) = .empty;
    errdefer first_cells.deinit(allocator);
    for (grids, 0..) |*g, gi| {
        var cells: std.ArrayList(renderer.DrawCell) = .empty;
        errdefer cells.deinit(allocator);
        try cells.ensureTotalCapacity(allocator, @as(usize, g.cols) * @as(usize, g.rows));
        var row: u16 = 0;
        while (row < g.rows) : (row += 1) {
            var col: u16 = 0;
            while (col < g.cols) {
                const idx = @as(usize, row) * @as(usize, g.cols) + col;
                const width = g.cwid[idx];
                if ((modal_bg_quad or transparent_default) and g.cp[idx] == ' ' and std.meta.eql(g.bg[idx], surface_bg)) {
                    col += if (width == 2) 2 else 1;
                    continue;
                }
                const cell_bg: terminal.Color = if ((modal_bg_quad or transparent_default) and std.meta.eql(g.bg[idx], surface_bg)) .default else g.bg[idx];
                cells.appendAssumeCapacity(.{ .row = row, .col = col, .codepoint = g.cp[idx], .width = width, .style = .{ .foreground = g.fg[idx], .background = cell_bg } });
                col += if (width == 2) 2 else 1;
            }
        }
        const part_cursor: ?terminal.Cursor = if (cursor_part == gi) cursor else null;
        if (gi == 0) {
            first_cells = cells;
        } else if (cells.items.len == 0 and part_cursor == null) {
            // 그릴 셀도 caret 도 없는 뒤 묶음(헤어라인·둥근 quad 뿐 — 그 몫은 위 GPU 목록에 있다)은 내지 않는다. 내면 빈 DrawList 가
            // 셰이핑·배치·셀 투영을 헛돈다(적대적 검증 2026-10-10).
            cells.deinit(allocator);
        } else {
            try extra_parts.append(allocator, .{ .cells = cells, .cols = g.cols, .rows = g.rows, .origin_x = g.origin_x, .origin_y = g.origin_y, .cursor = part_cursor, .clip_rect = g.clip_rect });
        }
    }
    const g0 = grids[0];
    return .{ .cells = first_cells, .gpu_quads = gpu_quads, .gpu_shadows = gpu_shadows, .cols = g0.cols, .rows = g0.rows, .origin_x = g0.origin_x, .origin_y = g0.origin_y, .cursor = if (cursor_part == 0) cursor else null, .clip_rect = g0.clip_rect, .extra_parts = extra_parts };
}

/// 셀 격자로 표현할 수 없는 얇은 rect인가 — 한 축이라도 셀보다 얇으면 그렇다(가로선 h<ch·세로선 w<cw).
/// 셀 하나가 최소 단위라 이보다 얇은 것은 반올림되어 **행/열 전체**가 되거나 사라진다.
fn isHairline(rect: chrome.draw.Rect, cw: u32, ch: u32) bool {
    return rect.h < ch or rect.w < cw;
}

/// 헤어라인 fill을 픽셀 그대로의 GPU quad로 낸다(모서리 곡률·테두리 없음). layer 1 = 모달 위젯 층 —
/// 모달 배경 quad와 같은 층이되 뒤에 append되므로 그 위에 그려진다.
fn appendHairline(quads: *std.ArrayList(metal_frame.GpuQuad), allocator: std.mem.Allocator, rect: chrome.draw.Rect, role: chrome.tokens.ColorRole, tk: *const chrome.Tokens) void {
    appendQuad(quads, allocator, rect, .{ 0, 0, 0, 0 }, .{ 0, 0, 0, 0 }, role, null, tk, 1, null);
}

fn appendSwatch(quads: *std.ArrayList(metal_frame.GpuQuad), allocator: std.mem.Allocator, sw: chrome.draw.Op.Swatch) void {
    const fill = packOpaqueRgb(sw.rgb);
    quads.append(allocator, .{ .x = @floatFromInt(sw.rect.x), .y = @floatFromInt(sw.rect.y), .w = @floatFromInt(sw.rect.w), .h = @floatFromInt(sw.rect.h), .corner_radii = .{ @floatFromInt(sw.corner_radii[0]), @floatFromInt(sw.corner_radii[1]), @floatFromInt(sw.corner_radii[2]), @floatFromInt(sw.corner_radii[3]) }, .border_widths = .{ 0, 0, 0, 0 }, .fill_color0 = fill, .fill_color1 = fill, .border_color = 0, .gradient_kind = 0, .layer = 3 }) catch {};
}

fn appendWidgetQuad(quads: *std.ArrayList(metal_frame.GpuQuad), allocator: std.mem.Allocator, q: chrome.draw.Op.Quad, tk: *const chrome.Tokens) void {
    appendQuad(quads, allocator, q.rect, q.corner_radii, q.border_widths, q.fill_role, q.border_role, tk, 3, q.clip);
}

/// 패널이 사방으로 커지는 폭 — 컴포넌트가 정했으면 그것(`Quad.panel_padding_px`), 아니면 토큰. 그림·가림(`hideCellsUnder`)이 같은 값을 쓴다.
fn panelPadding(q: chrome.draw.Op.Quad, tk: *const chrome.Tokens) u16 {
    return q.panel_padding_px orelse tk.space.modal_padding_px;
}

fn appendModalQuad(quads: *std.ArrayList(metal_frame.GpuQuad), shadows: *std.ArrayList(metal_frame.GpuShadow), allocator: std.mem.Allocator, q: chrome.draw.Op.Quad, tk: *const chrome.Tokens) void {
    // content rect와 box shadow가 같은 outset box를 공유해야 padding·border·shadow의 가장자리가 어긋나지 않는다.
    const p = panelPadding(q, tk);
    const box = q.rect.outset(.{ .left = p, .right = p, .top = p, .bottom = p });
    // **여기만 clip을 전달하지 않는다.** 위에서 rect를 padding만큼 **키웠으므로** component가 실은 clip
    // (키우기 전 rect 기준)과 좌표계가 어긋난다. 그대로 적용하면 방금 더한 padding과 그 그림자가 잘린다.
    // clip을 함께 키우는 것도 답이 아니다 — clip은 "여기까지만 그린다"는 약속이라 넓히면 그 약속이 깨진다
    // (`ui/tree.zig`가 스크롤바 gutter에서 같은 이유로 상한을 함께 본다). 모달은 최상위 오버레이라 자를
    // 컨테이너가 없으므로 null이 맞다. clip을 존중해야 하는 것은 outset이 없는 widget quad 쪽이다.
    appendQuad(quads, allocator, box, q.corner_radii, q.border_widths, q.fill_role, q.border_role, tk, 1, null);
    shadows.append(allocator, .{ .x = @floatFromInt(box.x), .y = @as(f32, @floatFromInt(box.y)) + @as(f32, @floatFromInt(tk.space.shadow_offset_y_px)), .w = @floatFromInt(box.w), .h = @floatFromInt(box.h), .corner_radii = .{ @floatFromInt(q.corner_radii[0]), @floatFromInt(q.corner_radii[1]), @floatFromInt(q.corner_radii[2]), @floatFromInt(q.corner_radii[3]) }, .blur_radius = @floatFromInt(tk.space.shadow_blur_px), .color = @as(u32, tk.space.shadow_alpha) << 24 }) catch {};
}

fn appendQuad(quads: *std.ArrayList(metal_frame.GpuQuad), allocator: std.mem.Allocator, rect: chrome.draw.Rect, radii: [4]u16, widths: [4]u16, fill_role: chrome.tokens.ColorRole, border_role: ?chrome.tokens.ColorRole, tk: *const chrome.Tokens, layer: u32, clip: ?chrome.draw.Rect) void {
    // 면적 0 clip은 "한 픽셀도 안 보인다"인데 shader 규약은 폭 0을 **"클립 없음"**으로 읽는다
    // (maru_metal_shader.h). 제품 lowerer(`chrome_draw_lowering`)와 같은 판정을 여기서도 해야 Lab
    // 골든이 제품과 같은 그림을 증명한다 — 이 경로가 clip을 통째로 버리고 있어서, 스크롤로 뷰포트를
    // 벗어난 카드 배경이 고정 chrome 위에 그려진 사용자 보고를 골든이 **재현조차 못 했다**.
    if (clip) |c| if (c.w == 0 or c.h == 0) return;
    const fill = packOpaqueRgb(tk.get(fill_role));
    const border = if (border_role) |role| packOpaqueRgb(tk.get(role)) else 0;
    quads.append(allocator, .{ .x = @floatFromInt(rect.x), .y = @floatFromInt(rect.y), .w = @floatFromInt(rect.w), .h = @floatFromInt(rect.h), .corner_radii = .{ @floatFromInt(radii[0]), @floatFromInt(radii[1]), @floatFromInt(radii[2]), @floatFromInt(radii[3]) }, .border_widths = .{ @floatFromInt(widths[0]), @floatFromInt(widths[1]), @floatFromInt(widths[2]), @floatFromInt(widths[3]) }, .fill_color0 = fill, .fill_color1 = fill, .border_color = border, .gradient_kind = 0, .layer = layer, .clip_x = if (clip) |c| @floatFromInt(c.x) else 0, .clip_y = if (clip) |c| @floatFromInt(c.y) else 0, .clip_w = if (clip) |c| @floatFromInt(c.w) else 0, .clip_h = if (clip) |c| @floatFromInt(c.h) else 0 }) catch {};
}

const no_owner = std.math.maxInt(u16);

/// 셀 (col,row) 의 중심이 `box`(px) 안인가.
fn cellCenterIn(col: u16, row: u16, origin_x: u32, origin_y: u32, cw: u32, ch: u32, box: chrome.draw.Rect) bool {
    const cx: i64 = @as(i64, origin_x) + @as(i64, col) * cw + @divTrunc(@as(i64, cw), 2);
    const cy: i64 = @as(i64, origin_y) + @as(i64, row) * ch + @divTrunc(@as(i64, ch), 2);
    return cx >= box.x and cx < @as(i64, box.x) + box.w and cy >= box.y and cy < @as(i64, box.y) + box.h;
}

/// `box` 안에 중심이 든 셀 중 **다른 draw(`who` 가 아닌)** 가 쓴 것을 비운다 — 뒤 오버레이의 패널이 앞 오버레이의 글자·배경을
/// 덮는 painter 순서를 셀 격자에 옮긴다. 비운 셀은 「아무도 안 쓴」 상태로 돌아간다(패널 위라 투명 처리된다).
fn hideCellsUnder(g: *Grid, who: u16, cw: u32, ch: u32, box: chrome.draw.Rect, surface_bg: terminal.Color, surface_fg: terminal.Color) void {
    var row: u16 = 0;
    while (row < g.rows) : (row += 1) {
        var col: u16 = 0;
        while (col < g.cols) : (col += 1) {
            const idx = @as(usize, row) * @as(usize, g.cols) + col;
            if (g.owner[idx] == no_owner or g.owner[idx] == who) continue;
            if (!cellCenterIn(col, row, g.origin_x, g.origin_y, cw, ch, box)) continue;
            g.bg[idx] = surface_bg;
            g.fg[idx] = surface_fg;
            g.cp[idx] = ' ';
            g.cwid[idx] = 1;
            g.owner[idx] = no_owner;
        }
    }
}

fn paintRectBg(g: *Grid, who: u16, cw: u32, ch: u32, rect: chrome.draw.Rect, color: terminal.Color, sides: ?chrome.draw.Sides) void {
    const bg = g.bg;
    const owner = g.owner;
    const cols = g.cols;
    const rows = g.rows;
    const ox: i32 = @intCast(g.origin_x);
    const oy: i32 = @intCast(g.origin_y);
    const c0 = std.math.clamp(@divTrunc(rect.x - ox, @as(i32, @intCast(cw))), 0, @as(i32, cols));
    const r0 = std.math.clamp(@divTrunc(rect.y - oy, @as(i32, @intCast(ch))), 0, @as(i32, rows));
    const c1 = std.math.clamp(@divTrunc(rect.x + @as(i32, @intCast(rect.w)) - ox, @as(i32, @intCast(cw))), 0, @as(i32, cols));
    const r1 = std.math.clamp(@divTrunc(rect.y + @as(i32, @intCast(rect.h)) - oy, @as(i32, @intCast(ch))), 0, @as(i32, rows));
    var row: i32 = r0;
    while (row < r1) : (row += 1) {
        var col: i32 = c0;
        while (col < c1) : (col += 1) {
            const on_edge = if (sides) |s| (s.top and row == r0) or (s.bottom and row == r1 - 1) or (s.left and col == c0) or (s.right and col == c1 - 1) else true;
            if (on_edge) {
                const idx = @as(usize, @intCast(row)) * @as(usize, cols) + @as(usize, @intCast(col));
                bg[idx] = color;
                owner[idx] = who;
            }
        }
    }
}

fn placeText(g: *Grid, who: u16, cw: u32, ch: u32, t: chrome.draw.Op.Text, tk: *const chrome.Tokens) void {
    // 타입을 적어 둔다 — `tests/boundary/chrome_text_clusters.zig`(CG1)가 「셀을 만드는 함수」를 이 신호로 찾는다.
    const cp: []u21 = g.cp;
    const fg = g.fg;
    const cwid = g.cwid;
    const owner = g.owner;
    const cols = g.cols;
    const rows = g.rows;
    const origin_x = g.origin_x;
    const origin_y = g.origin_y;
    // 이 경로는 셀 격자에 찍으므로 부분 클립이 불가능하다. 대신 셀 단위로 판정한다 — 같은 행의 배경
    // quad는 GPU가 픽셀 단위로 자르는데 글자만 그대로 남으면 배경 반쪽에 글자가 떠 있는 그림이 된다.
    // ⚠️ 이 남김/버림 규칙(origin 이 clip 안 · 행 = trunc)을 알림 패널이 **그대로 옮겨 쓴다**
    // (`components/notifications.zig` `placedRow` — 강조 배경·카드 구분선·클릭/호버 hitTest 가 모두 그것을 부른다). 바꾸면
    // 그쪽도 함께 — 판정자 「알림 패널: 걸친 카드의 강조 배경은 …」이 실제 배치된 글자 행과 비교해 셋의 어긋남을 잡는다.
    if (t.clip) |clip| {
        if (t.origin.y < clip.y or t.origin.y >= clip.y + @as(i32, @intCast(clip.h))) return;
        if (t.origin.x < clip.x or t.origin.x >= clip.x + @as(i32, @intCast(clip.w))) return;
    }
    const row_i = @divTrunc(t.origin.y - @as(i32, @intCast(origin_y)), @as(i32, @intCast(ch)));
    if (row_i < 0 or row_i >= rows) return;
    const row: usize = @intCast(row_i);
    var col_i = @divTrunc(t.origin.x - @as(i32, @intCast(origin_x)), @as(i32, @intCast(cw)));
    for (t.runs) |run| {
        // **run 이 제 색을 가지면 그것이 이긴다**(`run.role orelse text.role`) — 제품 lowering
        // (`chrome_draw_lowering.zig`)이 쓰는 것과 **같은 규칙**이다.
        //
        // 이 줄이 없어서 Lab 캡처가 무색이었다: 구문 색이 op 의 run 까지 흘렀는데 여기서
        // op 색 하나로 덮였다. **캡처 하네스가 그 기능을 원리상 못 밟는 상태**였고, 그래서
        // 골든 게이트도 색 회귀를 잡을 수 없었다(2026-08-28 실측).
        const color: terminal.Color = .{ .rgb = tk.get(run.role orelse t.role) };
        // **깨진 바이트는 하나당 U+FFFD 한 칸으로 그린다**(`text_layout.decodeCodepoint` — 도크 rich 경로와 같은
        // 디코더). 예전에는 `Utf8View.init` 이 실패한 run 을 통째로 버리고 열도 안 밀어, 깨진 바이트가 섞인
        // 라벨(OSC 0/2 제목은 바이트 그대로다)이 메뉴·모달에서 사라지고 같은 줄의 뒤 run 이 그 자리로 당겨졌다.
        var bi: usize = 0;
        while (bi < run.text.len) {
            const d = chrome.text_layout.decodeCodepoint(run.text, bi);
            bi += d.advance;
            const codepoint = d.cp;
            // wide 문자는 한 DrawCell의 width=2로 남기고 continuation cell은 emit하지 않는다. 그렇지 않으면
            // continuation의 배경 quad가 CoreText glyph의 오른쪽 절반을 덮어 한글/CJK가 잘린다.
            const width: u2 = if (t.wide_icons and renderer.icon_glyph.isRegisteredIcon(codepoint))
                chrome.ui.icon.chrome_run_span
            else
                @max(1, terminal.width.cellWidth(codepoint));
            if (col_i >= 0 and col_i < cols) {
                const idx = row * @as(usize, cols) + @as(usize, @intCast(col_i));
                owner[idx] = who;
                cp[idx] = codepoint;
                fg[idx] = color;
                cwid[idx] = @intCast(@min(width, 2));
            }
            col_i += width;
        }
    }
}

fn packOpaqueRgb(rgb: Rgb) u32 {
    return 0xFF000000 | (@as(u32, rgb.r) << 16) | (@as(u32, rgb.g) << 8) | rgb.b;
}

test "Lab lowering carries the component clip and drops a quad whose clip has zero area" {
    // 적대적 검증에서 찾은 갭(2026-08-12): 이 경로는 `Op.Quad.clip`을 통째로 버리고 있었다. 제품
    // lowerer(`chrome_draw_lowering`)는 같은 값을 GpuQuad에 실어 shader가 자르게 한다. 두 host가
    // 갈리면 Lab 골든은 **제품과 다른 그림**을 증명한다 — 실제로 "스크롤로 뷰포트를 벗어난 카드 배경이
    // 고정 chrome 위에 그려진다"는 사용자 보고를 이 경로로는 재현조차 할 수 없었다.
    const tk = chrome.Tokens{ .palette = std.EnumArray(chrome.tokens.ColorRole, Rgb).initFill(.{ .r = 9, .g = 9, .b = 9 }) };
    const ops = [_]chrome.draw.Op{
        // 첫 rounded quad는 modal 배경 경로다(padding outset + shadow).
        .{ .quad = .{
            .rect = .{ .x = 0, .y = 0, .w = 160, .h = 64 },
            .fill_role = .surface_bg,
            .corner_radii = .{ 8, 8, 8, 8 },
            .clip = .{ .x = 0, .y = 0, .w = 160, .h = 32 },
        } },
        // 그 뒤는 widget 경로다. 면적이 있는 clip은 그대로 실려야 한다.
        .{ .quad = .{
            .rect = .{ .x = 0, .y = 0, .w = 160, .h = 64 },
            .fill_role = .surface_bg,
            .corner_radii = .{ 8, 8, 8, 8 },
            .clip = .{ .x = 0, .y = 0, .w = 160, .h = 24 },
        } },
        // 면적 0 clip은 "한 픽셀도 안 보인다"이므로 아예 나가면 안 된다 — shader는 폭 0을
        // "클립 없음"으로 읽어 정반대로 자르지 않은 quad를 그린다.
        .{ .quad = .{
            .rect = .{ .x = 0, .y = -400, .w = 160, .h = 64 },
            .fill_role = .surface_bg,
            .corner_radii = .{ 8, 8, 8, 8 },
            .clip = .{ .x = 0, .y = 0, .w = 160, .h = 0 },
        } },
    };

    var raster = try lower(std.testing.allocator, &.{.{ .layer = .sidebar, .ops = &ops }}, &tk, 8, 16, true);
    defer raster.deinit(std.testing.allocator);

    // modal 배경(첫 rounded quad)은 padding만큼 **키운** box를 그리므로 clip을 전달하지 않는다 — 키우기
    // 전 rect 기준의 clip을 적용하면 그 padding이 잘린다. 그래서 남는 것은 widget quad 하나뿐이고,
    // 그 quad가 component의 clip을 그대로 들고 있어야 한다.
    try std.testing.expectEqual(@as(usize, 2), raster.gpu_quads.items.len);
    try std.testing.expectEqual(@as(f32, 0), raster.gpu_quads.items[0].clip_w);
    const widget = raster.gpu_quads.items[1];
    try std.testing.expectEqual(@as(f32, 160), widget.clip_w);
    try std.testing.expectEqual(@as(f32, 24), widget.clip_h);
}

test "EF31 independent find panels each retain their background and shadow" {
    const tk = chrome.Tokens{ .palette = std.EnumArray(chrome.tokens.ColorRole, Rgb).initFill(.{ .r = 9, .g = 9, .b = 9 }) };
    for ([_]u16{ 0, 8 }) |radius| {
        const left = [_]chrome.draw.Op{.{ .quad = .{ .rect = .{ .x = 0, .y = 0, .w = 160, .h = 64 }, .fill_role = .surface_bg, .corner_radii = .{ radius, radius, radius, radius } } }};
        const right = [_]chrome.draw.Op{.{ .quad = .{ .rect = .{ .x = 320, .y = 0, .w = 160, .h = 64 }, .fill_role = .surface_bg, .corner_radii = .{ radius, radius, radius, radius } } }};
        var raster = try lower(std.testing.allocator, &.{
            .{ .layer = .modal, .ops = &left, .independent_panel = true },
            .{ .layer = .modal, .ops = &right, .independent_panel = true },
        }, &tk, 8, 16, false);
        defer raster.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 2), raster.gpu_quads.items.len);
        try std.testing.expectEqual(@as(usize, 2), raster.gpu_shadows.items.len);
        try std.testing.expectEqual(raster.gpu_quads.items[0].w, raster.gpu_quads.items[1].w);
        try std.testing.expectEqual(raster.gpu_quads.items[0].h, raster.gpu_quads.items[1].h);
        try std.testing.expectEqual(@as(usize, 0), raster.cells.items.len);
    }
}

// 찾기 막대가 열린 채 우클릭하면 메뉴가 패딩·그림자 없이 그려졌다(2026-10-07 실제 앱 재현) — 「첫 둥근 quad」를 프레임 전체에서
// 한 번만 셌기 때문이다. 오버레이 둘이 한 프레임에 모여도 **각자** 패널(사방 패딩 + 그림자)을 갖는다. 한 draw 안의 둘째 둥근 quad 는
// 여전히 widget 이다(선택 행 위 강조 등).
test "ML4 오버레이 둘이 한 프레임에 모여도 각자 패널(패딩·그림자)을 갖고, 한 draw 안의 둘째 둥근 quad 는 widget 이다" {
    var tk = chrome.Tokens{ .palette = std.EnumArray(chrome.tokens.ColorRole, Rgb).initFill(.{ .r = 9, .g = 9, .b = 9 }) };
    tk.space.modal_padding_px = 12;
    const r: u16 = 8;
    // 먼저 모이는 찾기 막대(패널 하나) — 그 뒤 우클릭 메뉴(패널 + 그 안의 둥근 강조 하나).
    const find_ops = [_]chrome.draw.Op{.{ .quad = .{ .rect = .{ .x = 400, .y = 40, .w = 200, .h = 32 }, .fill_role = .surface_bg, .corner_radii = .{ r, r, r, r } } }};
    const menu_ops = [_]chrome.draw.Op{
        .{ .quad = .{ .rect = .{ .x = 100, .y = 200, .w = 160, .h = 64 }, .fill_role = .surface_bg, .corner_radii = .{ r, r, r, r } } },
        .{ .quad = .{ .rect = .{ .x = 100, .y = 216, .w = 160, .h = 16 }, .fill_role = .tab_active_bg, .corner_radii = .{ r, r, r, r } } },
    };
    var raster = try lower(std.testing.allocator, &.{
        .{ .layer = .modal, .ops = &find_ops },
        .{ .layer = .modal, .ops = &menu_ops },
    }, &tk, 8, 16, false);
    defer raster.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), raster.gpu_quads.items.len);
    try std.testing.expectEqual(@as(usize, 2), raster.gpu_shadows.items.len); // 패널마다 그림자 — 예전에는 하나
    const find_panel = raster.gpu_quads.items[0];
    const menu_panel = raster.gpu_quads.items[1];
    const menu_row = raster.gpu_quads.items[2];
    // 두 패널 모두 사방 12px 커지고 over 버킷(layer 1)이다 — 예전에는 메뉴 패널이 커지지 않은 widget(layer 3)이었다.
    try std.testing.expectEqual([4]f32{ 400 - 12, 40 - 12, 200 + 24, 32 + 24 }, [4]f32{ find_panel.x, find_panel.y, find_panel.w, find_panel.h });
    try std.testing.expectEqual([4]f32{ 100 - 12, 200 - 12, 160 + 24, 64 + 24 }, [4]f32{ menu_panel.x, menu_panel.y, menu_panel.w, menu_panel.h });
    try std.testing.expectEqual(@as(u32, 1), find_panel.layer);
    try std.testing.expectEqual(@as(u32, 1), menu_panel.layer);
    // 메뉴 draw 안의 둘째 둥근 quad 는 widget 그대로 — 키우지 않고 layer 3.
    try std.testing.expectEqual([4]f32{ 100, 216, 160, 16 }, [4]f32{ menu_row.x, menu_row.y, menu_row.w, menu_row.h });
    try std.testing.expectEqual(@as(u32, 3), menu_row.layer);
}

// 찾기 막대 위로 우클릭 메뉴가 열리면 찾기 막대의 글자가 메뉴 패널을 뚫고 보였다(2026-10-08 실제 앱 재현) — 렌더러가 모든 패널 뒤에
// 모든 셀을 그리기 때문이다. 뒤 오버레이의 패널(패딩 포함) 아래에 중심이 든 앞 오버레이의 셀·caret 은 지워지고, 덮이지 않은 셀과
// 뒤 오버레이 자신의 셀은 남는다.
test "ML5 뒤 오버레이의 패널은 그 아래 앞 오버레이의 글자·caret 을 가린다 — 덮이지 않은 것과 자기 글자는 남는다" {
    var tk = chrome.Tokens{ .palette = std.EnumArray(chrome.tokens.ColorRole, Rgb).initFill(.{ .r = 9, .g = 9, .b = 9 }) };
    tk.space.modal_padding_px = 12;
    const r: u16 = 8;
    // 찾기 막대: 패널 x[0..320) y[0..16) · 글자 「FFFFFFFFFF」 열 0..9 · caret 열 2.
    const find_runs = [_]chrome.draw.Run{.{ .text = "FFFFFFFFFF" }};
    const find_ops = [_]chrome.draw.Op{
        .{ .quad = .{ .rect = .{ .x = 0, .y = 0, .w = 320, .h = 16 }, .fill_role = .surface_bg, .corner_radii = .{ r, r, r, r } } },
        .{ .text = .{ .origin = .{ .x = 0, .y = 0 }, .runs = &find_runs, .role = .surface_fg } },
        .{ .fill = .{ .rect = .{ .x = 16, .y = 0, .w = 8, .h = 16 }, .role = .cursor } },
    };
    // 메뉴: 패널 x[16..96) y[16..48) — 패딩 12 를 더하면 x[4..108) y[4..60) 이라 찾기 글자 행(y 0..16, 중심 8)을 열 1..12 에서 덮는다.
    const menu_runs = [_]chrome.draw.Run{.{ .text = "MM" }};
    const menu_ops = [_]chrome.draw.Op{
        .{ .quad = .{ .rect = .{ .x = 16, .y = 16, .w = 80, .h = 32 }, .fill_role = .surface_bg, .corner_radii = .{ r, r, r, r } } },
        .{ .text = .{ .origin = .{ .x = 16, .y = 16 }, .runs = &menu_runs, .role = .surface_fg } },
    };
    var raster = try lower(std.testing.allocator, &.{
        .{ .layer = .modal, .ops = &find_ops },
        .{ .layer = .modal, .ops = &menu_ops },
    }, &tk, 8, 16, false);
    defer raster.deinit(std.testing.allocator);
    var seen_f = [_]bool{false} ** 10;
    var seen_m: usize = 0;
    for (raster.cells.items) |c| {
        if (c.codepoint == 'F' and c.row == 0 and c.col < 10) seen_f[c.col] = true;
        if (c.codepoint == 'M' and c.row == 1) seen_m += 1;
    }
    // 열 0 의 중심(x=4)은 메뉴 패널 x[4..108) 의 경계 위라 덮인다 — 열 0 부터 9 까지 모두 덮인다(중심 4..76 < 108, 행 중심 8 ≥ 4).
    for (seen_f) |v| try std.testing.expect(!v);
    try std.testing.expectEqual(@as(usize, 2), seen_m); // 메뉴 자기 글자는 남는다
    try std.testing.expect(raster.cursor == null); // 덮인 caret 은 안 그린다
}

// 덮이지 않은 앞 오버레이 글자는 그대로다 — 패널이 덮는 자리만 가린다.
test "ML5b 뒤 패널이 닿지 않는 앞 오버레이 글자·caret 은 그대로 남는다" {
    var tk = chrome.Tokens{ .palette = std.EnumArray(chrome.tokens.ColorRole, Rgb).initFill(.{ .r = 9, .g = 9, .b = 9 }) };
    tk.space.modal_padding_px = 12;
    const r: u16 = 8;
    const find_runs = [_]chrome.draw.Run{.{ .text = "FFFFFFFFFFFFFFFFFFFF" }}; // 열 0..19
    const find_ops = [_]chrome.draw.Op{
        .{ .quad = .{ .rect = .{ .x = 0, .y = 0, .w = 320, .h = 16 }, .fill_role = .surface_bg, .corner_radii = .{ r, r, r, r } } },
        .{ .text = .{ .origin = .{ .x = 0, .y = 0 }, .runs = &find_runs, .role = .surface_fg } },
        .{ .fill = .{ .rect = .{ .x = 152, .y = 0, .w = 8, .h = 16 }, .role = .cursor } }, // 열 19
    };
    // 메뉴 패널 x[16..96) → 보이는 x[4..108): 열 0(중심 4)…열 12(중심 100) 를 덮고 열 13(중심 108)부터는 안 덮는다.
    const menu_ops = [_]chrome.draw.Op{.{ .quad = .{ .rect = .{ .x = 16, .y = 16, .w = 80, .h = 32 }, .fill_role = .surface_bg, .corner_radii = .{ r, r, r, r } } }};
    var raster = try lower(std.testing.allocator, &.{
        .{ .layer = .modal, .ops = &find_ops },
        .{ .layer = .modal, .ops = &menu_ops },
    }, &tk, 8, 16, false);
    defer raster.deinit(std.testing.allocator);
    var seen = [_]bool{false} ** 20;
    for (raster.cells.items) |c| if (c.codepoint == 'F' and c.row == 0 and c.col < 20) {
        seen[c.col] = true;
    };
    for (seen, 0..) |v, col| try std.testing.expectEqual(col >= 13, v);
    try std.testing.expect(raster.cursor != null); // 열 19 caret 은 덮이지 않았다
    try std.testing.expectEqual(@as(u16, 19), raster.cursor.?.col);
}

// ML3b 경계: 알림 패널을 스크롤해 카드가 뷰포트 경계(위·아래)에 걸치면, 그 카드의 강조 배경(선택·호버)은 **헤더와
// 뷰포트 밖을 칠하지 않고**, 칠한 행은 그 카드의 글자가 놓인 행과 **같아야** 한다. `.fill` 은 셀 행 단위(`trunc`)로
// 내려가고 카드 프레임 clip 은 패널 전체(헤더 포함)라, 컴포넌트가 배경을 글자와 같은 규칙(줄마다, origin 이 뷰포트
// 안일 때만)으로 내지 않으면 위로 걸친 카드의 첫 행이 헤더 행으로 내림돼 헤더 한 줄이 통째로 카드색이 됐다(2026-10-06
// 실측 — 1px 만 밀려도). 뷰포트 사각형으로 자르면 이번엔 아래로 걸친 줄의 배경이 빠진다. 제품과 같은 lowering 을 탄다.
test "알림 패널: 걸친 카드의 강조 배경은 헤더·뷰포트 밖을 칠하지 않고, 그 카드 글자가 놓인 행만 칠한다 (ML3b)" {
    const notifications = chrome.components.notifications;
    var pal = std.EnumArray(chrome.tokens.ColorRole, Rgb).initFill(.{ .r = 10, .g = 10, .b = 10 });
    pal.set(.tab_active_bg, .{ .r = 200, .g = 0, .b = 0 });
    pal.set(.tab_hover_bg, .{ .r = 0, .g = 200, .b = 0 });
    const tk = chrome.Tokens{ .palette = pal };
    const cw: u32 = 8;
    const gutter_px: u32 = 24; // 카드 폭 < 패널 폭 — 강조가 gutter 까지 칠하면 잡힌다
    // 넘치게 — 카드를 실제로 걸치게 하려면 스크롤 상한이 카드 한 장보다 커야 한다.
    const count = 40;
    // **카드마다 다른 글자**다(제목 U+0100+i, 본문 U+0180+i). 모두 같은 글자면 구분선이 «남의 카드» 본문 행 바닥에
    // 있어도 통과한다. 출력 셀에서 카드별 제목·본문 행을 읽어 «선이 있어야 할 자리»를 제품 공식과 **따로** 구한다.
    var title_utf8: [count][4]u8 = undefined;
    var body_utf8: [count][4]u8 = undefined;
    var title_len: [count]u3 = undefined;
    var body_len: [count]u3 = undefined;
    for (0..count) |i| {
        title_len[i] = try std.unicode.utf8Encode(@intCast(0x100 + i), &title_utf8[i]);
        body_len[i] = try std.unicode.utf8Encode(@intCast(0x180 + i), &body_utf8[i]);
    }
    // 경계마다 «그 카드 글자가 실제로 보인» 경우를 센다 — 둘 다 빈 집합이면 `lit == text` 는 그냥 참이다.
    var seen_top: usize = 0;
    var seen_bottom: usize = 0;
    var dividers_checked: usize = 0;
    var hits_checked: usize = 0;
    var empty_rows_checked: usize = 0;
    // 기하를 바꿔 돈다 — 패널 y 가 0 이고 셀 높이·뷰포트가 한 가지면 «rect.y 를 빼먹은» 공식이나 바닥 경계 off-by-one 이
    // 출력 바이트까지 같아 통과했다(적대적 검증). 제품 패널 y 는 `2ch + modal padding` 이라 행 배수가 아니다.
    for ([_]u32{ 16, 17 }) |ch| for ([_]i32{ 0, 7 }) |anchor_y| for ([_]u32{ 300, 303, 305 }) |backing_h| for ([_]i32{ 0, 13 }) |anchor_x| {
        const p = chrome.props.ChromeProps{ .metrics = .{ .cell_width_px = cw, .cell_height_px = ch, .sidebar_width_px = 0, .backing_width_px = 800, .backing_height_px = backing_h, .overlay_scroll_gutter_px = gutter_px } };
        const card_px: u32 = 2 * ch;
        var shift: u32 = 0;
        while (shift < card_px) : (shift += 1) {
            // 위(맨 위 카드)와 아래(맨 아래 카드) 경계를 따로 본다.
            for ([_]bool{ true, false }) |top_edge| {
                // 0 = 선택, 1 = 호버, 2 = 강조 없음(강조 fill 이 상자를 늘려 걸친 행을 «우연히» 살리는 일이 없는 경우 —
                // 사용자가 가장 흔히 보는 상태다).
                for ([_]u8{ 0, 1, 2 }) |mode| {
                    var s: notifications.State = .{};
                    var items_buf: [count]notifications.Item = undefined;
                    for (&items_buf, 0..) |*it, i| it.* = .{ .title = title_utf8[i][0..title_len[i]], .body = body_utf8[i][0..body_len[i]], .relative_time = "now", .is_read = true, .is_alive = true };
                    s.show(anchor_x, anchor_y, count);
                    s.scroll.offset_y_px = card_px + shift;
                    const sv = notifications.scrollView(&s, &items_buf, p) orelse return error.NotScrollable;
                    try std.testing.expectEqual(card_px + shift, sv.offset_px); // 상한에 안 깎였다(전제)
                    const target: usize = if (top_edge) 1 else (card_px + shift + sv.viewport.h - 1) / card_px; // 걸친 카드
                    items_buf[target].title = "Q";
                    items_buf[target].body = "W";
                    s.selected = 0; // 화면 위로 지나간 카드 — 선택색이 다른 경우의 판정에 섞이지 않게
                    switch (mode) {
                        0 => s.selected = target,
                        1 => s.hovered = target,
                        else => {},
                    }
                    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
                    defer arena_state.deinit();
                    var out: std.ArrayList(chrome.draw.Op) = .empty;
                    try notifications.view(&s, &items_buf, p, &tk, arena_state.allocator(), &out);
                    var raster = try lower(std.testing.allocator, &.{.{ .layer = .modal, .ops = out.items }}, &tk, cw, ch, false);
                    defer raster.deinit(std.testing.allocator);
                    try std.testing.expectEqual(@as(u32, @intCast(anchor_y)), raster.origin_y); // 격자 원점 = 패널 y(전제 — 행 배수가 아닐 수 있다)
                    const ch_i: i32 = @intCast(ch);
                    const ox: i32 = @intCast(raster.origin_x);
                    const oy: i32 = @intCast(raster.origin_y);
                    const vp_bottom = sv.viewport.y + @as(i32, @intCast(sv.viewport.h));
                    const first_row = @divTrunc(sv.viewport.y - oy, ch_i); // 헤더 바로 아래 행
                    const end_row = @divTrunc(vp_bottom - oy, ch_i);
                    var lit_rows = std.StaticBitSet(64).initEmpty();
                    var text_rows = std.StaticBitSet(64).initEmpty();
                    // 카드별로 출력에 실제로 놓인 제목·본문 행(없으면 null).
                    var title_row: [count]?u16 = @splat(null);
                    var body_row: [count]?u16 = @splat(null);
                    var close_col: ?u16 = null; // ✕ 칸(본문줄 우측 끝) — 클릭 판정을 «그린 자리»에서 잰다
                    for (raster.cells.items) |c| {
                        if (c.codepoint == 0x2715) close_col = c.col;
                        const bg = c.style.background;
                        const lit = bg == .rgb and bg.rgb.b == 0 and (bg.rgb.r == 200 or bg.rgb.g == 200);
                        if (lit) {
                            try std.testing.expect(@as(i32, c.row) >= first_row); // 헤더를 칠하지 않는다
                            try std.testing.expect(@as(i32, c.row) <= end_row); // 뷰포트 아래로 안 나간다
                            // gutter(스크롤바 자리)를 칠하지 않는다 — 카드 폭은 패널 폭에서 gutter 를 뺀 것 이하다.
                            try std.testing.expect(ox + (@as(i32, c.col) + 1) * @as(i32, @intCast(cw)) <= sv.viewport.x + @as(i32, @intCast(sv.viewport.w - gutter_px)));
                            lit_rows.set(c.row);
                        }
                        switch (c.codepoint) {
                            'Q' => {
                                text_rows.set(c.row);
                                title_row[target] = c.row;
                            },
                            'W' => {
                                text_rows.set(c.row);
                                body_row[target] = c.row;
                            },
                            0x100...0x100 + count - 1 => title_row[c.codepoint - 0x100] = c.row,
                            0x180...0x180 + count - 1 => body_row[c.codepoint - 0x180] = c.row,
                            else => {},
                        }
                    }
                    // 칠한 행 == 그 카드 글자가 놓인 행(둘 다 같은 뷰포트로 잘린다). 걸친 몫이 셀보다 작아 글자가
                    // 하나도 안 남으면 칠한 행도 없다.
                    if (mode == 2) {
                        try std.testing.expectEqual(@as(usize, 0), lit_rows.count()); // 강조 없음
                    } else try std.testing.expect(lit_rows.eql(text_rows));
                    // 뷰포트 안에 origin 이 있는 그 카드의 줄은 **실제로 그려진다** — 바닥에 걸친 반쪽 줄 포함(프레임 clip 이
                    // 픽셀로 자른다). 격자가 그 행을 안 덮으면 글자가 통째로 사라진다.
                    {
                        const card_y: i32 = sv.viewport.y + @as(i32, @intCast(target * card_px)) - @as(i32, @intCast(card_px + shift));
                        var expected: usize = 0;
                        for ([_]i32{ card_y, card_y + ch_i }) |line_y| {
                            if (line_y >= sv.viewport.y and line_y < vp_bottom) expected += 1;
                        }
                        try std.testing.expectEqual(expected, text_rows.count());
                    }
                    // 카드 구분선(1px GPU quad — 셀 scissor 를 안 받는다)은 **두 카드의 글자 줄 사이에, 정확히 하나씩**
                    // 그어진다: 카드 i 의 본문 행과 카드 i+1 의 제목 행이 **둘 다** 출력에 놓였으면 그 사이 픽셀(제목 행 바로 위)에.
                    // 기대 집합은 제품 공식이 아니라 출력 셀에서 구한다. 예전엔 선이 카드 픽셀 바닥이라 걸친 만큼 제목줄을
                    // 가로질렀고(2026-10-06 사용자 지적, 「● Maru」 취소선), 아래 줄이 뷰포트 밖이면 패널 밖·바닥 테두리에 붙었다.
                    var expected_lines: [count]i32 = undefined;
                    var expected_n: usize = 0;
                    for (0..count - 1) |i| {
                        const b = body_row[i] orelse continue;
                        const t = title_row[i + 1] orelse continue;
                        try std.testing.expectEqual(b + 1, t); // 줄이 행에 빈틈없이 놓인다(전제)
                        expected_lines[expected_n] = oy + @as(i32, t) * ch_i - 1;
                        expected_n += 1;
                    }
                    var actual_lines: [count]i32 = undefined;
                    var actual_n: usize = 0;
                    var header_lines: usize = 0;
                    for (raster.gpu_quads.items) |q| {
                        if (q.h != 1) continue;
                        const qy: i32 = @intFromFloat(q.y);
                        if (qy == sv.viewport.y - 1) { // 헤더 구분선 — 위로 지나간 카드의 선이 이 자리에 겹쳐 그어지면 안 된다
                            header_lines += 1;
                            continue;
                        }
                        try std.testing.expect(qy >= sv.viewport.y and qy < vp_bottom); // 뷰포트 안
                        if (actual_n == count) return error.TooManyDividers;
                        actual_lines[actual_n] = qy;
                        actual_n += 1;
                    }
                    try std.testing.expectEqual(@as(usize, 1), header_lines);
                    std.mem.sort(i32, actual_lines[0..actual_n], {}, std.sort.asc(i32));
                    try std.testing.expectEqualSlices(i32, expected_lines[0..expected_n], actual_lines[0..actual_n]);
                    dividers_checked += expected_n;
                    // **보이는 줄 == 눌리는 줄** — 뷰포트 안 모든 픽셀 행에서 `hitTest` 가 그 행에 실제로 놓인 줄의 카드를
                    // 돌려주고(✕ 칸은 본문줄일 때만 ✕), 아무 줄도 안 놓인 행(바닥에 걸쳐 글자를 안 그린 줄)은 background
                    // 다. 기대값은 출력 셀에서 구한다. 예전엔 픽셀 카드 경계로 풀어, 걸친 상태에서 다음 카드 제목줄 위쪽
                    // 띠가 앞 카드로 잡혔다(그 자리 우측 끝 클릭 = 앞 카드 삭제). 강조 유무와 무관하니 강조 없음에서만 잰다.
                    if (mode == 2 and top_edge) { // 화면이 강조·대상 글자와 무관하므로 한 번만 잰다
                        const Owner = struct { card: usize, line: u1 };
                        var owner: [64]?Owner = @splat(null);
                        for (0..count) |i| {
                            if (title_row[i]) |r| {
                                try std.testing.expect(owner[r] == null);
                                owner[r] = .{ .card = i, .line = 0 };
                            }
                            if (body_row[i]) |r| {
                                try std.testing.expect(owner[r] == null);
                                owner[r] = .{ .card = i, .line = 1 };
                            }
                        }
                        // 열 경계도 **그린 것**에서 구한다: ✕ 글자 칸, 카드 폭 = 헤더 구분선 폭(카드 배경·구분선과 같은 값),
                        // 그 오른쪽은 스크롤바 gutter(막대만 그려진 자리 — 카드가 아니다).
                        const cw_i: i32 = @intCast(cw);
                        const close_c: i32 = close_col orelse return error.NoCloseGlyph;
                        var card_right: ?i32 = null;
                        for (raster.gpu_quads.items) |q| if (q.h == 1 and @as(i32, @intFromFloat(q.y)) == sv.viewport.y - 1) {
                            card_right = @divTrunc(@as(i32, @intFromFloat(q.w)), cw_i);
                        };
                        const card_cols: i32 = card_right orelse return error.NoHeaderDivider;
                        const panel_cols: i32 = @divTrunc(@as(i32, @intCast(sv.viewport.w)), cw_i);
                        try std.testing.expect(close_c + 1 < card_cols and card_cols < panel_cols); // 전제: ✕ 오른쪽 여백·gutter 가 있다
                        // 본문 끝·✕ 바로 왼쪽·✕·카드 끝 칸·gutter 첫 칸·패널 끝 칸.
                        const cols = [_]i32{ 0, close_c - 1, close_c, card_cols - 1, card_cols, panel_cols - 1 };
                        var y: i32 = sv.viewport.y;
                        while (y < vp_bottom) : (y += 1) {
                            const o = owner[@intCast(@divTrunc(y - oy, ch_i))];
                            if (o == null) empty_rows_checked += 1;
                            // 정수 좌표와 반 픽셀(트랙패드는 소수 좌표를 준다).
                            for ([_]f64{ 0, 0.5 }) |dy| for (cols) |c| {
                                const xf: f64 = @as(f64, @floatFromInt(ox + c * cw_i)) + 0.5;
                                const yf: f64 = @as(f64, @floatFromInt(y)) + dy;
                                const hit = notifications.hitTest(&s, &items_buf, p, xf, yf) orelse return error.HitOutsidePanel;
                                const want: notifications.Hit = if (c >= card_cols)
                                    .background
                                else if (o) |ow|
                                    (if (ow.line == 1 and c >= close_c) notifications.Hit{ .close = ow.card } else notifications.Hit{ .card = ow.card })
                                else
                                    .background;
                                try std.testing.expectEqual(want, hit);
                                hits_checked += 1;
                            };
                        }
                    }
                    if (text_rows.count() > 0) {
                        if (top_edge) seen_top += 1 else seen_bottom += 1;
                    }
                }
            }
        }
    };
    // 기하 24 가지(패널 x 0·13 포함) × 위 걸침이 글자를 남기는 걸침(0..ch) × 선택/호버/없음 — 대략 24 × 17 × 3.
    try std.testing.expect(seen_top >= 24 * 16 * 3);
    try std.testing.expect(seen_bottom >= 24 * 32 * 3); // 아래 경계 카드는 늘 무언가 보인다
    // 화면마다 카드 사이 선이 여러 개 실제로 있었다(빈 집합이면 위 집합 비교는 공짜다).
    try std.testing.expect(dividers_checked >= 24 * 32 * 2 * 3 * 5);
    // 클릭 판정을 실제로 쟀다 — 뷰포트 픽셀 행 전부, 그중 «줄이 안 놓인 빈 띠»도 있었다(없으면 background 단언은 공짜).
    try std.testing.expect(hits_checked >= 24 * 32 * 200 * 2 * 6);
    try std.testing.expect(empty_rows_checked > 0);
}

test "오버레이 셀 경로: 깨진 UTF-8 은 건너뛰지 않고 U+FFFD 로 그리며, 뒤 run 의 열을 밀지 않는다" {
    // 이 경로는 `Utf8View.init` 이 실패한 run 을 **통째로 버렸고 열도 안 밀었다** — 깨진 바이트가 하나라도
    // 섞인 라벨(OSC 0/2 제목은 바이트 그대로 저장된다)이 메뉴·모달에서 **사라지고**, 같은 줄의 뒤 run 이
    // 그 자리로 당겨졌다. 도크 rich 경로(`text_layout.decodeCodepoint`)는 같은 문자열을 「�」 섞어 그린다 —
    // 두 경로가 같은 규칙(깨진 바이트 하나 = U+FFFD 한 칸)을 쓴다.
    const tk = chrome.Tokens{ .palette = std.EnumArray(chrome.tokens.ColorRole, Rgb).initFill(.{ .r = 9, .g = 9, .b = 9 }) };
    const runs = [_]chrome.draw.Run{ .{ .text = "ab\xffcd" }, .{ .text = "Z" } };
    const ops = [_]chrome.draw.Op{
        .{ .fill = .{ .rect = .{ .x = 0, .y = 0, .w = 80, .h = 16 }, .role = .surface_bg } },
        .{ .text = .{ .origin = .{ .x = 0, .y = 0 }, .runs = &runs, .role = .surface_fg } },
    };
    var raster = try lower(std.testing.allocator, &.{.{ .layer = .modal, .ops = &ops }}, &tk, 8, 16, false);
    defer raster.deinit(std.testing.allocator);
    var at: [10]u21 = .{0} ** 10;
    for (raster.cells.items) |c| if (c.row == 0 and c.col < at.len) {
        at[c.col] = c.codepoint;
    };
    try std.testing.expectEqualSlices(u21, &.{ 'a', 'b', 0xFFFD, 'c', 'd', 'Z' }, at[0..6]);
}

test "오버레이 셀 경로가 전진한 칸 수는 `overlay_input.displayCols` 와 같다 — 깨진 바이트가 섞여도" {
    // 컴포넌트는 `displayCols` 로 상자·패딩·버튼 자리를 재고, 이 경로는 글자를 그 칸에 놓는다. 둘이 다른 셈법을
    // 쓰면 깨진 라벨 하나가 같은 줄의 다음 run 을 밀거나 당긴다(예전: 셈은 바이트 수, 그림은 run 생략).
    const tk = chrome.Tokens{ .palette = std.EnumArray(chrome.tokens.ColorRole, Rgb).initFill(.{ .r = 9, .g = 9, .b = 9 }) };
    var prng = std.Random.DefaultPrng.init(11);
    const r = prng.random();
    const pieces = [_][]const u8{ "a", "한", "e\u{301}", "…", "\xff", "\xc3", "\xe2\x80", "\x80", "ｗ" };
    var invalid_seen: usize = 0;
    for (0..400) |_| {
        var src: [120]u8 = undefined;
        var n: usize = 0;
        for (0..r.intRangeAtMost(usize, 0, 20)) |_| {
            const pc = pieces[r.intRangeLessThan(usize, 0, pieces.len)];
            if (n + pc.len > src.len) break;
            @memcpy(src[n..][0..pc.len], pc);
            n += pc.len;
        }
        if (!std.unicode.utf8ValidateSlice(src[0..n])) invalid_seen += 1;
        const runs = [_]chrome.draw.Run{ .{ .text = src[0..n] }, .{ .text = "Z" } };
        const ops = [_]chrome.draw.Op{
            .{ .fill = .{ .rect = .{ .x = 0, .y = 0, .w = 8 * 64, .h = 16 }, .role = .surface_bg } },
            .{ .text = .{ .origin = .{ .x = 0, .y = 0 }, .runs = &runs, .role = .surface_fg } },
        };
        var raster = try lower(std.testing.allocator, &.{.{ .layer = .modal, .ops = &ops }}, &tk, 8, 16, false);
        defer raster.deinit(std.testing.allocator);
        var z_col: ?u16 = null;
        for (raster.cells.items) |c| if (c.row == 0 and c.codepoint == 'Z') {
            z_col = c.col;
        };
        try std.testing.expectEqual(@as(?u16, @intCast(chrome.components.overlay_input.displayCols(src[0..n]))), z_col);
    }
    try std.testing.expect(invalid_seen > 200);
}

/// 그 글자가 화면에 서는 픽셀(셀 좌상단) — 첫 묶음과 뒤 묶음을 모두 본다. 없으면 null.
fn glyphPixel(raster: *const OverlayRaster, cp: u21, cw: u32, ch: u32) ?[2]i64 {
    for (raster.cells.items) |c| if (c.codepoint == cp) return .{ @as(i64, raster.origin_x) + @as(i64, c.col) * cw, @as(i64, raster.origin_y) + @as(i64, c.row) * ch };
    for (raster.extra_parts.items) |part| for (part.cells.items) |c| if (c.codepoint == cp) return .{ @as(i64, part.origin_x) + @as(i64, c.col) * cw, @as(i64, part.origin_y) + @as(i64, c.row) * ch };
    return null;
}

// 2026-10-09 실제 앱 실측(찾기 막대와 완성 목록을 함께 그리게 한 실험 빌드): 찾기 막대(pane 모서리 기준 — 460,90)와 완성 목록(편집기
// 글자 기준 — 288,228)을 한 격자(원점 288,90)에 올리자 찾기 글자는 21.5칸 → 21칸으로 4px 왼쪽, 목록은 7.67행 → 7행으로 12px 위에
// 섰다(클릭 판정은 컴포넌트 자리를 써 그림과 갈렸다). main 에서 도달하는 같은 꼴은 찾기 막대 + 우클릭 메뉴다(`OVF5`).
// 칸 위상이 다르면 묶음을 나눠, 둘 다 컴포넌트가 낸 픽셀에 선다.
test "ML6 칸 위상이 다른 오버레이 둘 — 둘 다 컴포넌트가 낸 픽셀 자리에 글자가 선다(찾기 막대 + 완성 목록 실측 좌표)" {
    var tk = chrome.Tokens{ .palette = std.EnumArray(chrome.tokens.ColorRole, Rgb).initFill(.{ .r = 9, .g = 9, .b = 9 }) };
    tk.space.modal_padding_px = 12;
    const r: u16 = 8;
    const find_runs = [_]chrome.draw.Run{.{ .text = "Find: total" }};
    const find_ops = [_]chrome.draw.Op{
        .{ .quad = .{ .rect = .{ .x = 460, .y = 90, .w = 480, .h = 18 }, .fill_role = .surface_bg, .corner_radii = .{ r, r, r, r } } },
        .{ .text = .{ .origin = .{ .x = 460, .y = 90 }, .runs = &find_runs, .role = .surface_fg } },
    };
    // 완성 목록은 자기 직각 패널 quad(패딩 = 테두리 폭 1 — `Quad.panel_padding_px`, `independent_panel`) · 폭 가득한 선택 셀 배경 · 행 글자를 낸다
    // (`suggest_box.view` — §8.2g-e).
    // label 은 아이콘 2·간격 1 의 3칸 뒤(`label_col`).
    const row1 = [_]chrome.draw.Run{.{ .text = "print_count" }};
    const row2 = [_]chrome.draw.Run{.{ .text = "qrint_total" }};
    const list_ops = [_]chrome.draw.Op{
        .{ .quad = .{ .rect = .{ .x = 288, .y = 228, .w = 120, .h = 36 }, .fill_role = .surface_bg, .panel_padding_px = 1 } },
        .{ .fill = .{ .rect = .{ .x = 288, .y = 228, .w = 120, .h = 18 }, .role = .tab_active_bg } },
        .{ .text = .{ .origin = .{ .x = 288 + 24, .y = 228 }, .runs = &row1, .role = .surface_fg } },
        .{ .text = .{ .origin = .{ .x = 288 + 24, .y = 246 }, .runs = &row2, .role = .surface_fg } },
    };
    var raster = try lower(std.testing.allocator, &.{
        .{ .layer = .modal, .ops = &find_ops },
        .{ .layer = .modal, .ops = &list_ops, .independent_panel = true },
    }, &tk, 8, 18, false);
    defer raster.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), raster.extra_parts.items.len); // 위상이 달라 두 장
    try std.testing.expectEqual([2]i64{ 460, 90 }, glyphPixel(&raster, 'F', 8, 18).?); // 예전: 456
    try std.testing.expectEqual([2]i64{ 288 + 24, 228 }, glyphPixel(&raster, 'p', 8, 18).?); // 예전: y 216
    try std.testing.expectEqual([2]i64{ 288 + 24, 246 }, glyphPixel(&raster, 'q', 8, 18).?); // 둘째 행도
    // GPU quad 는 묶음과 무관하게 픽셀 그대로다 — 패널 둘(찾기·목록 — 목록은 직각이지만 `independent_panel` 이라 패널). 선택은 셀 배경이다.
    try std.testing.expectEqual(@as(usize, 2), raster.gpu_quads.items.len);
    try std.testing.expectEqual(@as(u32, 1), raster.gpu_quads.items[1].layer); // 목록 패널 — 사방 **자기** 패딩(1)만큼 커진다
    try std.testing.expectEqual(@as(f32, 288 - 1), raster.gpu_quads.items[1].x); // 토큰 12 가 아니다(패널마다 패딩 — `Quad.panel_padding_px`)
    try std.testing.expectEqual(@as(f32, 120 + 2), raster.gpu_quads.items[1].w);
    try std.testing.expectEqual(@as(f32, 460 - 12), raster.gpu_quads.items[0].x); // 찾기 막대는 토큰 그대로
    try std.testing.expectEqual(@as(f32, 288 - 1), raster.gpu_shadows.items[1].x); // 그림자도 같은 상자
}

// 위상이 같으면 예전과 같은 격자 한 장이다 — 원점도 셀도 그대로(`ML5` 의 프레임이 그 경우다).
test "ML6b 칸 위상이 같은 오버레이 둘은 격자 한 장 — 원점은 전체 좌상단, 칸은 예전과 같다" {
    var tk = chrome.Tokens{ .palette = std.EnumArray(chrome.tokens.ColorRole, Rgb).initFill(.{ .r = 9, .g = 9, .b = 9 }) };
    tk.space.modal_padding_px = 12;
    const r: u16 = 8;
    const a_runs = [_]chrome.draw.Run{.{ .text = "A" }};
    const b_runs = [_]chrome.draw.Run{.{ .text = "B" }};
    const a_ops = [_]chrome.draw.Op{
        .{ .quad = .{ .rect = .{ .x = 404, .y = 90, .w = 80, .h = 18 }, .fill_role = .surface_bg, .corner_radii = .{ r, r, r, r } } },
        .{ .text = .{ .origin = .{ .x = 404, .y = 90 }, .runs = &a_runs, .role = .surface_fg } },
    };
    // (404 − 300) = 104 = 13칸, (90 − 18) = 72 = 4행 — 같은 위상.
    const b_ops = [_]chrome.draw.Op{
        .{ .quad = .{ .rect = .{ .x = 300, .y = 18, .w = 80, .h = 18 }, .fill_role = .surface_bg, .corner_radii = .{ r, r, r, r } } },
        .{ .text = .{ .origin = .{ .x = 300, .y = 18 }, .runs = &b_runs, .role = .surface_fg } },
    };
    var raster = try lower(std.testing.allocator, &.{
        .{ .layer = .modal, .ops = &a_ops },
        .{ .layer = .modal, .ops = &b_ops },
    }, &tk, 8, 18, false);
    defer raster.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), raster.extra_parts.items.len);
    try std.testing.expectEqual([2]u32{ 300, 18 }, [2]u32{ raster.origin_x, raster.origin_y });
    try std.testing.expectEqual([2]i64{ 404, 90 }, glyphPixel(&raster, 'A', 8, 18).?);
    try std.testing.expectEqual([2]i64{ 300, 18 }, glyphPixel(&raster, 'B', 8, 18).?);
}

// 묶음은 **연속한** draw 끼리다 — 렌더러가 묶음을 이어 붙인 순서대로 그리므로, 위상이 같아도 사이에 다른 위상이 끼면 따로 묶어야
// 맨 뒤 draw 가 가운데 draw 위에 선다.
test "ML7 위상 p·q·p 로 이어진 오버레이 셋은 세 장이다 — 묶음 순서가 painter 순서" {
    const tk = chrome.Tokens{ .palette = std.EnumArray(chrome.tokens.ColorRole, Rgb).initFill(.{ .r = 9, .g = 9, .b = 9 }) };
    const x_runs = [_]chrome.draw.Run{.{ .text = "X" }};
    const y_runs = [_]chrome.draw.Run{.{ .text = "Y" }};
    const z_runs = [_]chrome.draw.Run{.{ .text = "Z" }};
    const x_ops = [_]chrome.draw.Op{ .{ .fill = .{ .rect = .{ .x = 0, .y = 0, .w = 16, .h = 16 }, .role = .tab_active_bg } }, .{ .text = .{ .origin = .{ .x = 0, .y = 0 }, .runs = &x_runs, .role = .surface_fg } } };
    const y_ops = [_]chrome.draw.Op{ .{ .fill = .{ .rect = .{ .x = 4, .y = 4, .w = 16, .h = 16 }, .role = .tab_active_bg } }, .{ .text = .{ .origin = .{ .x = 4, .y = 4 }, .runs = &y_runs, .role = .surface_fg } } };
    const z_ops = [_]chrome.draw.Op{ .{ .fill = .{ .rect = .{ .x = 8, .y = 0, .w = 16, .h = 16 }, .role = .tab_active_bg } }, .{ .text = .{ .origin = .{ .x = 8, .y = 0 }, .runs = &z_runs, .role = .surface_fg } } };
    var raster = try lower(std.testing.allocator, &.{
        .{ .layer = .modal, .ops = &x_ops },
        .{ .layer = .modal, .ops = &y_ops },
        .{ .layer = .modal, .ops = &z_ops },
    }, &tk, 8, 16, false);
    defer raster.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), raster.extra_parts.items.len);
    var z_part: ?usize = null;
    for (raster.extra_parts.items, 0..) |part, i| for (part.cells.items) |c| if (c.codepoint == 'Z') {
        z_part = i;
    };
    try std.testing.expectEqual(@as(?usize, 1), z_part); // 맨 뒤 장(가운데 Y 의 장 뒤)
    try std.testing.expectEqual([2]i64{ 4, 4 }, glyphPixel(&raster, 'Y', 8, 16).?);
    try std.testing.expectEqual([2]i64{ 8, 0 }, glyphPixel(&raster, 'Z', 8, 16).?);
}

// 뒤 오버레이의 패널은 위상이 다른(= 다른 격자의) 앞 오버레이의 글자·caret 도 가린다 — 판정은 셀마다 자기 격자 원점으로 픽셀 중심을 잰다.
// 패널마다 패딩(`Quad.panel_padding_px`, 2026-10-10 — chrome-strategy §5.4): 가림도 그 패널이 **실제로 그려지는** 상자로 잰다. 토큰(12)으로 재면
// 촘촘한 목록(패딩 1)이 보이지도 않는 바깥 11px 의 앞 글자까지 지웠다.
test "ML14 패널마다 패딩 — 그림·그림자·앞 글자 가림이 모두 그 패널의 패딩(토큰이 아니라)으로 잰다" {
    var tk = chrome.Tokens{ .palette = std.EnumArray(chrome.tokens.ColorRole, Rgb).initFill(.{ .r = 9, .g = 9, .b = 9 }) };
    tk.space.modal_padding_px = 12;
    const r: u16 = 8;
    const find_runs = [_]chrome.draw.Run{.{ .text = "FFFFFFFFFFFFFFFFFFFF" }};
    const find_ops = [_]chrome.draw.Op{
        .{ .quad = .{ .rect = .{ .x = 0, .y = 0, .w = 320, .h = 16 }, .fill_role = .surface_bg, .corner_radii = .{ r, r, r, r } } },
        .{ .text = .{ .origin = .{ .x = 0, .y = 0 }, .runs = &find_runs, .role = .surface_fg } },
    };
    // 목록: x[19..99) y[5..37), 패딩 1 → 보이는 x[18..100) y[4..38).
    const list_runs = [_]chrome.draw.Run{.{ .text = "M" }};
    const list_ops = [_]chrome.draw.Op{
        .{ .quad = .{ .rect = .{ .x = 19, .y = 5, .w = 80, .h = 32 }, .fill_role = .surface_bg, .corner_radii = .{ r, r, r, r }, .panel_padding_px = 1 } },
        .{ .text = .{ .origin = .{ .x = 19, .y = 5 }, .runs = &list_runs, .role = .surface_fg } },
    };
    var raster = try lower(std.testing.allocator, &.{
        .{ .layer = .modal, .ops = &find_ops },
        .{ .layer = .modal, .ops = &list_ops },
    }, &tk, 8, 16, false);
    defer raster.deinit(std.testing.allocator);
    // 찾기 글자 열 c 의 중심 x = 8c+4 — c=2(20)…c=11(92) 만 덮이고, c=1(12)·c=12(100) 은 남는다(토큰 12 면 c=1…13 이 덮였다).
    var seen = [_]bool{false} ** 20;
    for (raster.cells.items) |c| if (c.codepoint == 'F' and c.row == 0 and c.col < 20) {
        seen[c.col] = true;
    };
    for (seen, 0..) |v, col| try std.testing.expectEqual(col < 2 or col >= 12, v);
    // 그림과 그림자 — 찾기 막대는 토큰 12, 목록은 1.
    try std.testing.expectEqual(@as(f32, -12), raster.gpu_quads.items[0].x);
    try std.testing.expectEqual(@as(f32, 18), raster.gpu_quads.items[1].x);
    try std.testing.expectEqual(@as(f32, 82), raster.gpu_quads.items[1].w);
    try std.testing.expectEqual(@as(f32, 18), raster.gpu_shadows.items[1].x);
}

test "ML8 위상이 다른 뒤 패널도 앞 오버레이의 글자·caret 을 가리고, 닿지 않는 글자는 남긴다" {
    var tk = chrome.Tokens{ .palette = std.EnumArray(chrome.tokens.ColorRole, Rgb).initFill(.{ .r = 9, .g = 9, .b = 9 }) };
    tk.space.modal_padding_px = 12;
    const r: u16 = 8;
    // 찾기 막대: x[0..320) — 글자 20칸(픽셀 0..160), caret 열 2(픽셀 16).
    const find_runs = [_]chrome.draw.Run{.{ .text = "FFFFFFFFFFFFFFFFFFFF" }};
    const find_ops = [_]chrome.draw.Op{
        .{ .quad = .{ .rect = .{ .x = 0, .y = 0, .w = 320, .h = 16 }, .fill_role = .surface_bg, .corner_radii = .{ r, r, r, r } } },
        .{ .text = .{ .origin = .{ .x = 0, .y = 0 }, .runs = &find_runs, .role = .surface_fg } },
        .{ .fill = .{ .rect = .{ .x = 16, .y = 0, .w = 8, .h = 16 }, .role = .cursor } },
    };
    // 메뉴: x[19..99) y[5..37) — (19 mod 8, 5 mod 16) = (3, 5) 로 찾기 막대(0, 0)와 위상이 다르다. 패딩 12 → 보이는 x[7..111) y[-7..49).
    // 메뉴 글자 하나 — 셀이 있어야 뒤 묶음이 조각으로 나온다(셀 없는 묶음은 버린다 — `ML13`). 열 0 이라 찾기 글자 판정과 겹치지 않는다.
    const menu_runs = [_]chrome.draw.Run{.{ .text = "M" }};
    const menu_ops = [_]chrome.draw.Op{
        .{ .quad = .{ .rect = .{ .x = 19, .y = 5, .w = 80, .h = 32 }, .fill_role = .surface_bg, .corner_radii = .{ r, r, r, r } } },
        .{ .text = .{ .origin = .{ .x = 19, .y = 5 }, .runs = &menu_runs, .role = .surface_fg } },
    };
    var raster = try lower(std.testing.allocator, &.{
        .{ .layer = .modal, .ops = &find_ops },
        .{ .layer = .modal, .ops = &menu_ops },
    }, &tk, 8, 16, false);
    defer raster.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), raster.extra_parts.items.len);
    // 메뉴 보이는 상자 x[7..111) y[-7..49): 찾기 글자 열 c 의 중심 x = 8c+4 — c=1(12)…c=13(108) 이 덮이고 c=0(4)·c≥14(116) 는 남는다.
    var seen = [_]bool{false} ** 20;
    for (raster.cells.items) |c| if (c.codepoint == 'F' and c.row == 0 and c.col < 20) {
        seen[c.col] = true;
    };
    for (seen, 0..) |v, col| try std.testing.expectEqual(col == 0 or col >= 14, v);
    try std.testing.expect(raster.cursor == null); // 열 2 caret(중심 20)은 덮였다
}

// caret 가림은 caret 이 든 격자의 원점으로 잰다 — 뒤(메뉴) 격자 원점으로 재면 덮이지 않은 caret 을 지운다.
test "ML8b 위상이 다른 뒤 패널이 닿지 않는 앞 묶음의 caret 은 남는다 — 판정은 caret 자기 격자의 원점으로" {
    var tk = chrome.Tokens{ .palette = std.EnumArray(chrome.tokens.ColorRole, Rgb).initFill(.{ .r = 9, .g = 9, .b = 9 }) };
    tk.space.modal_padding_px = 12;
    const r: u16 = 8;
    const find_runs = [_]chrome.draw.Run{.{ .text = "FFFF" }};
    const find_ops = [_]chrome.draw.Op{
        .{ .quad = .{ .rect = .{ .x = 0, .y = 0, .w = 320, .h = 16 }, .fill_role = .surface_bg, .corner_radii = .{ r, r, r, r } } },
        .{ .text = .{ .origin = .{ .x = 0, .y = 0 }, .runs = &find_runs, .role = .surface_fg } },
        .{ .fill = .{ .rect = .{ .x = 0, .y = 0, .w = 8, .h = 16 }, .role = .cursor } }, // 열 0 — 중심 x=4
    };
    // ML8 의 메뉴: 보이는 상자 x[7..111) y[-7..49). 찾기 격자 원점(0,0)으로 열 0 중심은 4 라 밖이다. 메뉴 격자 원점(19,5)으로 재면
    // 23 이라 안으로 잘못 든다.
    // 메뉴 글자 하나 — 셀이 있어야 뒤 묶음이 조각으로 나온다(셀 없는 묶음은 버린다 — `ML13`). 열 0 이라 찾기 글자 판정과 겹치지 않는다.
    const menu_runs = [_]chrome.draw.Run{.{ .text = "M" }};
    const menu_ops = [_]chrome.draw.Op{
        .{ .quad = .{ .rect = .{ .x = 19, .y = 5, .w = 80, .h = 32 }, .fill_role = .surface_bg, .corner_radii = .{ r, r, r, r } } },
        .{ .text = .{ .origin = .{ .x = 19, .y = 5 }, .runs = &menu_runs, .role = .surface_fg } },
    };
    var raster = try lower(std.testing.allocator, &.{
        .{ .layer = .modal, .ops = &find_ops },
        .{ .layer = .modal, .ops = &menu_ops },
    }, &tk, 8, 16, false);
    defer raster.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), raster.extra_parts.items.len);
    try std.testing.expect(raster.cursor != null);
    try std.testing.expectEqual(@as(u16, 0), raster.cursor.?.col);
}

// caret 이 뒤 묶음에 들면 그 묶음에만 선다(첫 묶음엔 없다) — 토스트가 떠 있는 채 찾기 입력에 포커스가 있으면 그렇다(collectDraws 순서가
// notice → confirm → find). 행·열은 그 묶음 격자 기준이다.
test "ML9 caret 이 뒤 묶음에 있으면 그 묶음의 cursor 에만 서고 첫 묶음엔 없다" {
    var tk = chrome.Tokens{ .palette = std.EnumArray(chrome.tokens.ColorRole, Rgb).initFill(.{ .r = 9, .g = 9, .b = 9 }) };
    tk.space.modal_padding_px = 12;
    const r: u16 = 8;
    const toast_runs = [_]chrome.draw.Run{.{ .text = "T" }};
    const toast_ops = [_]chrome.draw.Op{
        .{ .quad = .{ .rect = .{ .x = 0, .y = 0, .w = 80, .h = 16 }, .fill_role = .surface_bg, .corner_radii = .{ r, r, r, r } } },
        .{ .text = .{ .origin = .{ .x = 0, .y = 0 }, .runs = &toast_runs, .role = .surface_fg } },
    };
    const find_runs = [_]chrome.draw.Run{.{ .text = "Find: q" }};
    const find_ops = [_]chrome.draw.Op{
        .{ .quad = .{ .rect = .{ .x = 403, .y = 205, .w = 160, .h = 16 }, .fill_role = .surface_bg, .corner_radii = .{ r, r, r, r } } },
        .{ .text = .{ .origin = .{ .x = 403, .y = 205 }, .runs = &find_runs, .role = .surface_fg } },
        .{ .fill = .{ .rect = .{ .x = 403 + 7 * 8, .y = 205, .w = 8, .h = 16 }, .role = .cursor } }, // 「Find: q」 뒤 열 7
    };
    var raster = try lower(std.testing.allocator, &.{
        .{ .layer = .modal, .ops = &toast_ops },
        .{ .layer = .modal, .ops = &find_ops },
    }, &tk, 8, 16, false);
    defer raster.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), raster.extra_parts.items.len);
    try std.testing.expect(raster.cursor == null); // 첫 묶음(토스트)엔 caret 이 없다 — 있으면 caret 이 둘이 된다
    const c = raster.extra_parts.items[0].cursor orelse return error.CaretLost;
    try std.testing.expectEqual(@as(u16, 0), c.row);
    try std.testing.expectEqual(@as(u16, 7), c.col);
}

// 위상은 가로·세로 **각각** 본다 — 한 축만 달라도 묶음을 나눈다(OVF5 의 넓은 메뉴는 창 오른쪽에 붙어 가로 위상이 고정됐다).
test "ML10 한 축만 다른 위상도 묶음을 나눈다 — 가로만·세로만 다른 둘 다 각자 픽셀에 선다" {
    const tk = chrome.Tokens{ .palette = std.EnumArray(chrome.tokens.ColorRole, Rgb).initFill(.{ .r = 9, .g = 9, .b = 9 }) };
    const a_runs = [_]chrome.draw.Run{.{ .text = "A" }};
    const b_runs = [_]chrome.draw.Run{.{ .text = "B" }};
    const c_runs = [_]chrome.draw.Run{.{ .text = "C" }};
    const a_ops = [_]chrome.draw.Op{ .{ .fill = .{ .rect = .{ .x = 0, .y = 0, .w = 16, .h = 16 }, .role = .tab_active_bg } }, .{ .text = .{ .origin = .{ .x = 0, .y = 0 }, .runs = &a_runs, .role = .surface_fg } } };
    // 이웃한 두 쌍이 각각 **한 축만** 다르다 — A→B 는 가로만(83 mod 8 = 3, 64 = 4행), B→C 는 세로만(123 mod 8 = 3, 101 mod 16 = 5).
    const b_ops = [_]chrome.draw.Op{ .{ .fill = .{ .rect = .{ .x = 83, .y = 64, .w = 16, .h = 16 }, .role = .tab_active_bg } }, .{ .text = .{ .origin = .{ .x = 83, .y = 64 }, .runs = &b_runs, .role = .surface_fg } } };
    const c_ops = [_]chrome.draw.Op{ .{ .fill = .{ .rect = .{ .x = 123, .y = 101, .w = 16, .h = 16 }, .role = .tab_active_bg } }, .{ .text = .{ .origin = .{ .x = 123, .y = 101 }, .runs = &c_runs, .role = .surface_fg } } };
    var raster = try lower(std.testing.allocator, &.{
        .{ .layer = .modal, .ops = &a_ops },
        .{ .layer = .modal, .ops = &b_ops },
        .{ .layer = .modal, .ops = &c_ops },
    }, &tk, 8, 16, false);
    defer raster.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), raster.extra_parts.items.len);
    try std.testing.expectEqual([2]i64{ 0, 0 }, glyphPixel(&raster, 'A', 8, 16).?);
    try std.testing.expectEqual([2]i64{ 83, 64 }, glyphPixel(&raster, 'B', 8, 16).?);
    try std.testing.expectEqual([2]i64{ 123, 101 }, glyphPixel(&raster, 'C', 8, 16).?);
}

// `.clip` 과 그 행 올림은 그 op 을 낸 draw 의 묶음에만 걸린다 — 다른 위상의 오버레이 셀을 자르거나 늘리지 않는다.
test "ML11 clip 과 행 올림은 자기 묶음에만 — 위상이 다른 앞 오버레이는 clip 없이 내림 행 수다" {
    const tk = chrome.Tokens{ .palette = std.EnumArray(chrome.tokens.ColorRole, Rgb).initFill(.{ .r = 9, .g = 9, .b = 9 }) };
    // A: 높이 20(=1.25행) — clip 이 없으니 내림 1행. B: 같은 높이에 clip — 올림 2행.
    const a_ops = [_]chrome.draw.Op{.{ .fill = .{ .rect = .{ .x = 0, .y = 0, .w = 16, .h = 20 }, .role = .tab_active_bg } }};
    const b_ops = [_]chrome.draw.Op{
        .{ .clip = .{ .x = 203, .y = 101, .w = 16, .h = 20 } },
        .{ .fill = .{ .rect = .{ .x = 203, .y = 101, .w = 16, .h = 20 }, .role = .tab_active_bg } },
    };
    var raster = try lower(std.testing.allocator, &.{
        .{ .layer = .modal, .ops = &a_ops },
        .{ .layer = .modal, .ops = &b_ops },
    }, &tk, 8, 16, false);
    defer raster.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), raster.extra_parts.items.len);
    try std.testing.expect(raster.clip_rect == null);
    try std.testing.expectEqual(@as(u16, 1), raster.rows);
    const b = raster.extra_parts.items[0];
    try std.testing.expectEqual(@as(?chrome.draw.Rect, .{ .x = 203, .y = 101, .w = 16, .h = 20 }), b.clip_rect);
    try std.testing.expectEqual(@as(u16, 2), b.rows);
}

// 사각형 없이 글자만 내는 draw 는 글자가 차지하는 칸으로 위상·범위를 잰다 — 앞 묶음에 붙이면 그 격자 밖 글자가 통째로 버려졌다.
test "ML12 글자만 있는 draw 는 자기 자리에 선다 — 앞 묶음 격자 밖이어도 버려지지 않는다" {
    const tk = chrome.Tokens{ .palette = std.EnumArray(chrome.tokens.ColorRole, Rgb).initFill(.{ .r = 9, .g = 9, .b = 9 }) };
    const a_ops = [_]chrome.draw.Op{.{ .fill = .{ .rect = .{ .x = 0, .y = 0, .w = 80, .h = 32 }, .role = .tab_active_bg } }};
    const t_runs = [_]chrome.draw.Run{.{ .text = "TU" }};
    const t_ops = [_]chrome.draw.Op{.{ .text = .{ .origin = .{ .x = 203, .y = 100 }, .runs = &t_runs, .role = .surface_fg } }};
    var raster = try lower(std.testing.allocator, &.{
        .{ .layer = .modal, .ops = &a_ops },
        .{ .layer = .modal, .ops = &t_ops },
    }, &tk, 8, 16, false);
    defer raster.deinit(std.testing.allocator);
    try std.testing.expectEqual([2]i64{ 203, 100 }, glyphPixel(&raster, 'T', 8, 16) orelse return error.TextDropped);
    try std.testing.expectEqual([2]i64{ 211, 100 }, glyphPixel(&raster, 'U', 8, 16) orelse return error.TextDropped); // 두 칸 다
}

// 글자 칸은 `placeText` 와 같은 폭 규칙으로 잰다 — 넓은 글자는 2칸, 깨진 바이트는 U+FFFD 1칸. 칸을 적게 세면 끝 글자가 격자 밖으로 버려진다.
test "ML12b 글자만 있는 draw 의 범위는 넓은 글자·깨진 바이트까지 placeText 와 같은 칸으로 잰다" {
    const tk = chrome.Tokens{ .palette = std.EnumArray(chrome.tokens.ColorRole, Rgb).initFill(.{ .r = 9, .g = 9, .b = 9 }) };
    const t_runs = [_]chrome.draw.Run{.{ .text = "가\xffZ" }}; // 2 + 1 + 1 칸
    const t_ops = [_]chrome.draw.Op{.{ .text = .{ .origin = .{ .x = 40, .y = 32 }, .runs = &t_runs, .role = .surface_fg } }};
    var raster = try lower(std.testing.allocator, &.{.{ .layer = .modal, .ops = &t_ops }}, &tk, 8, 16, false);
    defer raster.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 4), raster.cols);
    try std.testing.expectEqual([2]i64{ 40 + 3 * 8, 32 }, glyphPixel(&raster, 'Z', 8, 16) orelse return error.TextDropped);
}

// clip 은 그것을 낸 draw 의 묶음 격자 전체에 걸리므로, clip 을 내는 draw 는 위상이 같은 이웃과도 묶지 않는다 — 묶으면 이웃 글자를 잘랐다.
test "ML11b clip 을 내는 draw 는 위상이 같은 앞뒤 draw 와 묶이지 않는다 — 이웃은 clip 없이 남는다" {
    const tk = chrome.Tokens{ .palette = std.EnumArray(chrome.tokens.ColorRole, Rgb).initFill(.{ .r = 9, .g = 9, .b = 9 }) };
    const a_runs = [_]chrome.draw.Run{.{ .text = "A" }};
    const c_runs = [_]chrome.draw.Run{.{ .text = "C" }};
    // 셋 다 위상 (0,0). 가운데만 clip 을 낸다.
    const a_ops = [_]chrome.draw.Op{ .{ .fill = .{ .rect = .{ .x = 0, .y = 0, .w = 16, .h = 16 }, .role = .tab_active_bg } }, .{ .text = .{ .origin = .{ .x = 0, .y = 0 }, .runs = &a_runs, .role = .surface_fg } } };
    const b_ops = [_]chrome.draw.Op{
        .{ .clip = .{ .x = 64, .y = 64, .w = 16, .h = 16 } },
        .{ .fill = .{ .rect = .{ .x = 64, .y = 64, .w = 16, .h = 16 }, .role = .tab_active_bg } },
    };
    const c_ops = [_]chrome.draw.Op{ .{ .fill = .{ .rect = .{ .x = 128, .y = 128, .w = 16, .h = 16 }, .role = .tab_active_bg } }, .{ .text = .{ .origin = .{ .x = 128, .y = 128 }, .runs = &c_runs, .role = .surface_fg } } };
    var raster = try lower(std.testing.allocator, &.{
        .{ .layer = .modal, .ops = &a_ops },
        .{ .layer = .modal, .ops = &b_ops },
        .{ .layer = .modal, .ops = &c_ops },
    }, &tk, 8, 16, false);
    defer raster.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), raster.extra_parts.items.len); // A | B | C
    try std.testing.expect(raster.clip_rect == null); // A 는 clip 밖
    try std.testing.expect(raster.extra_parts.items[0].clip_rect != null); // B 만
    try std.testing.expect(raster.extra_parts.items[1].clip_rect == null); // C 도 clip 밖
    try std.testing.expectEqual([2]i64{ 128, 128 }, glyphPixel(&raster, 'C', 8, 16).?);
}

// 셀도 caret 도 없는 뒤 묶음(둥근 패널 quad 뿐)은 내지 않는다 — 그 몫은 GPU 목록에 있고, 내면 빈 DrawList 가 셰이핑을 헛돈다.
test "ML13 셀이 없는 뒤 묶음은 조각으로 내지 않는다 — 패널 quad 는 그대로 GPU 목록에 있다" {
    var tk = chrome.Tokens{ .palette = std.EnumArray(chrome.tokens.ColorRole, Rgb).initFill(.{ .r = 9, .g = 9, .b = 9 }) };
    tk.space.modal_padding_px = 12;
    const r: u16 = 8;
    const a_runs = [_]chrome.draw.Run{.{ .text = "A" }};
    const a_ops = [_]chrome.draw.Op{ .{ .fill = .{ .rect = .{ .x = 0, .y = 0, .w = 16, .h = 16 }, .role = .tab_active_bg } }, .{ .text = .{ .origin = .{ .x = 0, .y = 0 }, .runs = &a_runs, .role = .surface_fg } } };
    const b_ops = [_]chrome.draw.Op{.{ .quad = .{ .rect = .{ .x = 203, .y = 101, .w = 80, .h = 32 }, .fill_role = .surface_bg, .corner_radii = .{ r, r, r, r } } }};
    var raster = try lower(std.testing.allocator, &.{
        .{ .layer = .modal, .ops = &a_ops },
        .{ .layer = .modal, .ops = &b_ops },
    }, &tk, 8, 16, false);
    defer raster.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), raster.extra_parts.items.len);
    try std.testing.expectEqual(@as(usize, 1), raster.gpu_quads.items.len); // 패널은 GPU 로 그려진다
    try std.testing.expectEqual([2]i64{ 0, 0 }, glyphPixel(&raster, 'A', 8, 16).?);
}
