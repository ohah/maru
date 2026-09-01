//! 편집기 **세로 스크롤바** — §4.1a
//! ([native-editor-visual-mapping.md](../../../../docs/native-editor-visual-mapping.md)).
//!
//! **기하는 `ui/scroll_area.zig`를 재활용한다**(§2 레이어 표가 그렇게 정했다). 여기 있는 것은 편집기
//! 고유 규칙 둘뿐이다:
//!
//! 1. **범위가 시각 행 기준이다.** 논리 줄 수를 쓰면 랩된 문서에서 thumb 크기가 실제와 어긋난다 —
//!    한 줄이 화면 열 개를 덮어도 논리 줄로는 하나이므로 막대가 실제보다 길어 보인다.
//! 2. **셀 격자가 아니라 픽셀이다.** gutter는 폰트를 키우면 함께 커지지만(§4.1) 스크롤바는 사이드바·
//!    도크의 것과 같아 보여야 하므로 편집기 폰트와 무관하다.
//!
//! **track은 그리지 않는다.** 배경과 거의 같은 색이라 화면에 보태는 것이 없고, VSCode도 기본
//! 테마에서 track이 사실상 보이지 않는다. 잡는 자리(`hit_x`/`hit_w`)는 기하가 여전히 돌려주므로
//! 드래그를 붙일 때 track 없이도 성립한다.

const std = @import("std");
const chrome = @import("../../../chrome.zig");
const scroll_area = @import("../../ui/scroll_area.zig");
const continuous_drag = @import("../../ui/continuous_drag.zig");

const draw = chrome.draw;
const tokens = chrome.tokens;

/// thumb 색과 불투명도. **본문 글자색 계열을 흐리게** 얹는다 — 배경과 반대 방향이라 어느 테마에서든
/// 대비가 서고(다크면 밝은 막대, 라이트면 어두운 막대), 알파가 그것을 "읽는 것을 방해하지 않을 만큼"
/// 낮춘다. VSCode 다크 테마의 `#79797966`이 같은 구조다.
///
/// **배경 계열 색(`divider`)으로는 안 된다** — 배경과 같은 방향이라 대비가 테마 명암차에 좌우된다.
/// 실제로 그렇게 그렸더니 배경 20 위에 35라 캡처에서 거의 보이지 않았다.
///
/// **테마 전환 자체는 검증되지 않았다.** Lab 토큰이 의도적으로 고정이라(골든이 테마 변경으로 통째
/// 갱신되는 것을 막는 장치) 다크 캡처만 있다. 값이 토큰에서 오므로 따라가기는 하며, 라이트 토큰을
/// 임시로 넣어 보면 이 막대가 실제로 어두워진다(실측 81 → 12).
pub const thumb_role: tokens.ColorRole = .muted_fg;
pub const thumb_alpha: u8 = 0x66;

pub const Props = struct {
    /// 본문 영역의 픽셀 사각. **스크롤바는 이 오른쪽 gutter 안에 선다**(본문 위에 겹치지 않는다).
    content: scroll_area.ContentRect,
    /// 문서 전체의 **시각 행** 수(`visual_map.RowIndex.totalRows`).
    total_visual_rows: u32,
    /// 맨 위에 보이는 시각 행.
    first_visual_row: u32,
    cell_h_px: u16,
    metrics: scroll_area.ScrollbarMetrics,
    /// 검색 결과의 **시각 행** 목록(§4.1a 「검색 결과 마커」). 오름차순일 필요는 없다.
    /// 비어 있으면 마커를 안 그린다 — 찾기가 닫히면 호출자가 빈 조각을 준다.
    match_rows: []const u32 = &.{},
    /// `match_rows` 안에서 **현재 일치**의 인덱스. 그 하나만 다른 색으로 그린다.
    current_match: ?usize = null,
};

/// 마커 색 — 본문 강조와 **같은 role** 을 쓴다(§4.1a). 다른 색을 쓰면 「이 표시가 그 매치」라는
/// 연결이 끊어진다.
pub const marker_role: tokens.ColorRole = .search_match;
pub const marker_current_role: tokens.ColorRole = .search_match_current;
/// 마커 하나의 높이(px). 1px 이면 레티나에서 사실상 안 보이고, 두꺼우면 이웃과 뭉친다.
pub const marker_h_px: i32 = 2;
/// 그릴 마커 수의 상한. 픽셀 행으로 합쳐도 남으면 그 위는 안 그린다 — 막대 높이를 넘는 마커는
/// 어차피 구별되지 않는다(§4.1a).
pub const marker_budget: usize = 256;

pub const Written = struct {
    ops: usize,
    /// 그린 막대의 기하. 드래그·클릭을 붙일 때 호출자가 쓴다(`offsetForPointer`). 스크롤이 필요
    /// 없으면 `null`이고, 그때는 op도 0이다.
    geometry: ?scroll_area.ScrollbarGeometry = null,
};

/// 스크롤바 draw op을 채우고 쓴 양을 돌려준다. **할당하지 않는다.**
///
/// 문서가 화면에 다 들어가면 아무것도 그리지 않는다(`scrollbarGeometry`가 `null`을 준다) — 스크롤할
/// 것이 없는데 막대를 두면 사용자가 더 있는 줄 안다.
pub fn build(props: Props, out: []draw.Op) Written {
    const content_h_px = std.math.mul(u32, props.total_visual_rows, props.cell_h_px) catch
        std.math.maxInt(u32);
    const offset_px = std.math.mul(u32, props.first_visual_row, props.cell_h_px) catch
        std.math.maxInt(u32);

    const bar = scroll_area.scrollbarGeometry(
        props.content,
        content_h_px,
        offset_px,
        props.metrics,
    ) orelse return .{ .ops = 0 };

    if (out.len == 0) return .{ .ops = 0, .geometry = bar };

    // **마커를 thumb 보다 먼저 깐다.** thumb 이 반투명이라 아래에 깔면 겹쳐도 비쳐 보인다(§4.1a) —
    // 위에 그리면 thumb 이 지나갈 때 마커가 그것을 가려 막대가 어디 있는지 알 수 없다.
    //
    // **슬롯에 표시한 뒤 한 번에 낸다.** 목록을 그대로 훑으며 그리면 상한에 걸렸을 때 **문서 앞부분만**
    // 찍혀 아래쪽이 비고, 그것은 「거기엔 매치가 없다」는 거짓말이 된다. 막대를 `marker_budget` 칸으로
    // 나눠 표시하면 매치가 몇 개든 **전 구간이 고르게** 덮인다(§4.1a 「같은 픽셀 행은 하나로 합친다」).
    var n: usize = 0;
    // 목록이 비면 아래 순회가 아무것도 표시하지 않아 op 도 0 이다 — 앞질러 막지 않는다
    // (막아 봐야 뜻이 같아 판정자가 그 줄을 못 지킨다). `total_visual_rows` 는 나눗셈의 분모라 필요하다.
    if (props.total_visual_rows > 0) {
        const track_y: i32 = @intFromFloat(@round(bar.track_y));
        const track_h: i32 = @intFromFloat(@round(bar.track_h));
        const usable = @max(track_h - marker_h_px, 0);
        const slots = @min(@as(usize, @intCast(@max(@divTrunc(usable, marker_h_px), 1))), marker_budget);

        var hit = [_]u8{0} ** marker_budget; // 0=없음 1=매치 2=현재
        for (props.match_rows, 0..) |row, i| {
            // 슬롯을 `slots - 1` 로 clamp 하므로 행을 따로 clamp 하지 않는다 — 문서 밖 행이
            // 와도 마지막 슬롯에 떨어질 뿐이다(둘 다 막으면 뒤엣것이 판정자에 안 잡힌다).
            const slot = @min(
                (@as(usize, row) * slots) / @as(usize, props.total_visual_rows),
                slots - 1,
            );
            const is_current = props.current_match != null and props.current_match.? == i;
            // **현재 일치가 이긴다.** 같은 슬롯에 여럿이 겹치면 그 하나는 반드시 보여야 한다 —
            // 사용자가 지금 어디를 보고 있는지가 이 표시의 첫 질문이다.
            if (is_current or hit[slot] == 0) hit[slot] = if (is_current) 2 else 1;
        }
        for (hit[0..slots], 0..) |mark, slot| {
            if (mark == 0) continue;
            // **thumb 자리를 남긴다**(`n + 1`). 마커가 버퍼를 다 먹으면 막대 자체가 안 그려져
            // 스크롤할 것이 있는지조차 화면이 말하지 못한다 — 마커는 부가 표시고 thumb 은 조작의 근거다.
            // `slots <= marker_budget` 이므로 상한은 슬롯 수가 이미 지킨다 — 여기서는
            // **op 자리**만 본다. thumb 자리를 남긴다(`n + 1`): 마커가 버퍼를 다 먹으면 막대가
            // 안 그려져 스크롤할 것이 있는지조차 화면이 말하지 못한다.
            if (n + 1 >= out.len) break;
            out[n] = .{ .quad = .{
                .rect = .{
                    .x = @intFromFloat(@round(bar.track_x)),
                    .y = track_y + @divTrunc(@as(i32, @intCast(slot)) * usable, @as(i32, @intCast(slots))),
                    .w = @intFromFloat(@round(bar.track_w)),
                    .h = marker_h_px,
                },
                .fill_role = if (mark == 2) marker_current_role else marker_role,
            } };
            n += 1;
        }
    }

    // **`fill`이 아니라 `quad`다.** `fill`은 셀 격자로 내려가는데(`metal_lowering.paintRectBg`)
    // 스크롤바는 §4.1a대로 **격자 밖**(본문 오른쪽 gutter)에 서므로 열 인덱스가 범위를 벗어나
    // **조용히 버려진다** — 실제로 그 상태로 캡처가 나왔고 픽셀이 하나도 없었다. `quad`는 GPU로
    // 직접 내려가 격자와 무관하다(둥근 모서리·헤어라인이 같은 이유로 이 길을 쓴다).
    out[n] = .{
        .quad = .{
            .rect = .{
                .x = @intFromFloat(@round(bar.track_x)),
                .y = @intFromFloat(@round(bar.thumb_y)),
                .w = @intFromFloat(@round(bar.track_w)),
                .h = @intFromFloat(@round(bar.thumb_h)),
            },
            .fill_role = thumb_role,
            .alpha = thumb_alpha,
            // 막대 끝을 둥글린다 — 도크·사이드바 스크롤바와 같아 보여야 한다(§2).
            .corner_radii = .{ 4, 4, 4, 4 },
        },
    };
    return .{ .ops = n + 1, .geometry = bar };
}

/// **가로 막대의 기하.** 세로(`scroll_area.ScrollbarGeometry`)와 축이 뒤집혀 있어 이름을 따로 둔다 —
/// 같은 타입에 담으면 `thumb_y`가 사실은 x라는 식이 되어, 읽는 쪽이 매번 축을 되짚어야 한다.
///
/// 잡는 자리(`hit_y`/`hit_h`)가 그리는 자리보다 두꺼운 이유는 세로와 같다(§ScrollbarGeometry 주석 —
/// 보이는 띠가 얇은 것은 디자인이고 조준 난이도까지 그 값에 묶을 이유는 없다).
pub const HorizontalGeometry = struct {
    track_x: f32,
    track_y: f32,
    track_w: f32,
    track_h: f32,
    /// 잡는 자리(거터 전체). 가로 범위는 track과 같으므로 y축만 따로 든다.
    hit_y: f32,
    hit_h: f32,
    thumb_x: f32,
    thumb_w: f32,
    max_offset_px: u32,

    /// thumb을 잡은 지점(`grab_dx` = 누른 x - thumb left)을 유지한 채 pointer를 따라가는 offset.
    ///
    /// **세로(`scroll_area.ScrollbarGeometry.offsetForPointer`)와 같은 식이고 축만 뒤집혔다.** 그것을
    /// 재사용하지 않는 이유는 이 타입이 별도인 이유와 같다 — 같은 함수에 담으면 `thumb_y`가 사실은 x라는
    /// 식이 되어, 읽는 쪽이 매번 축을 되짚어야 한다.
    pub fn offsetForPointer(self: HorizontalGeometry, pointer_x: f64, grab_dx: f32) u32 {
        if (!std.math.isFinite(pointer_x) or !std.math.isFinite(grab_dx)) return 0;
        const travel = self.track_w - self.thumb_w;
        if (travel <= 0 or self.max_offset_px == 0) return 0;
        const thumb_left = std.math.clamp(
            pointer_x - @as(f64, grab_dx),
            @as(f64, self.track_x),
            @as(f64, self.track_x + travel),
        );
        const ratio = (thumb_left - @as(f64, self.track_x)) / @as(f64, travel);
        const scaled = @round(ratio * @as(f64, @floatFromInt(self.max_offset_px)));
        return @intFromFloat(std.math.clamp(scaled, 0, @as(f64, @floatFromInt(self.max_offset_px))));
    }

    /// thumb 바깥 track click은 그 지점에 thumb 중앙을 놓는다(세로와 같은 규칙).
    pub fn offsetForTrackClick(self: HorizontalGeometry, pointer_x: f64) u32 {
        return self.offsetForPointer(pointer_x, self.thumb_w / 2);
    }

    pub fn thumbContains(self: HorizontalGeometry, x: f64) bool {
        return x >= self.thumb_x and x < self.thumb_x + self.thumb_w;
    }

    /// 같은 track에서 offset만 바뀐 기하(세로 `withOffset`의 짝). track click이 화면을 옮긴 **직후**의
    /// thumb 자리를 알아야 이어지는 드래그의 grab 지점이 튀지 않는데, 그 시점에는 아직 새 프레임이
    /// 그려지지 않았다.
    pub fn withOffset(self: HorizontalGeometry, offset_px: u32) HorizontalGeometry {
        if (self.max_offset_px == 0) return self;
        var next = self;
        const travel = self.track_w - self.thumb_w;
        const ratio = @as(f32, @floatFromInt(@min(offset_px, self.max_offset_px))) / @as(f32, @floatFromInt(self.max_offset_px));
        next.thumb_x = self.track_x + travel * ratio;
        return next;
    }

    /// 포인터가 가로 막대를 잡는가 — **보이는 막대가 아니라 아래 거터 전체**로 판정한다(세로가 좌우
    /// 거터로 판정하는 것과 같다). 축이 뒤집혀 여기서는 `hit_y`/`hit_h`가 그 띠다.
    pub fn trackContains(self: HorizontalGeometry, x: f64, y: f64) bool {
        return y >= self.hit_y and y < self.hit_y + self.hit_h and
            x >= self.track_x and x < self.track_x + self.track_w;
    }
};

/// 가로 막대 드래그의 수명(세로 `scroll_area.Drag`의 축 뒤집힌 짝).
///
/// **흡수·중복 억제 규율도 같다**(CIM2 §4.3) — move는 좌표를 덮어쓰기만 하고 tick이 최종 하나를
/// 적용하며, clamp 결과가 같으면 effect를 재실행하지 않는다. 그것을 `Coalescer`가 소유한다.
pub const HorizontalDrag = struct {
    active: bool = false,
    coalescer: continuous_drag.Coalescer(u32) = .{},
    /// 누른 x - thumb left. 이것을 유지해야 손가락과 막대가 어긋나지 않는다.
    grab_dx: f32 = 0,
    geometry: HorizontalGeometry = .{
        .track_x = 0,
        .track_y = 0,
        .track_w = 0,
        .track_h = 0,
        .hit_y = 0,
        .hit_h = 0,
        .thumb_x = 0,
        .thumb_w = 0,
        .max_offset_px = 0,
    },

    /// 누른 자리가 thumb 밖이면 **먼저 그 지점으로 뛴 뒤** 그 위치를 잡은 것으로 친다(세로와 같은
    /// 규칙 — 그래야 눌렀다 끌기 시작하는 순간 위치가 튀지 않는다). 뛴 offset을 돌려준다.
    pub fn begin(self: *HorizontalDrag, bar: HorizontalGeometry, x: f64, y: f64) ?u32 {
        if (!bar.trackContains(x, y)) return null;
        if (bar.thumbContains(x)) {
            self.* = .{ .grab_dx = @floatCast(x - @as(f64, bar.thumb_x)), .geometry = bar, .active = true };
            return null;
        }
        const jumped = bar.offsetForTrackClick(x);
        self.* = .{ .grab_dx = bar.thumb_w / 2, .geometry = bar.withOffset(jumped), .active = true };
        return jumped;
    }

    /// move 하나를 흡수한다(tick이 최종 하나만 적용한다).
    pub fn absorb(self: *HorizontalDrag, x_px: f64, y_px: f64) void {
        if (!self.active) return;
        self.coalescer.absorb(x_px, y_px);
    }

    /// tick이 소비한다. clamp 결과가 직전과 같으면 `null` — 경계에 닿은 채 미는 동안 effect가
    /// 반복되지 않는다.
    pub fn takeOffset(self: *HorizontalDrag) ?u32 {
        if (!self.active) return null;
        const point = self.coalescer.take() orelse return null;
        const offset = self.geometry.offsetForPointer(point.x_px, self.grab_dx);
        if (!self.coalescer.commitIfChanged(offset)) return null;
        return offset;
    }

    pub fn end(self: *HorizontalDrag) void {
        self.* = .{};
    }
};

pub const HorizontalProps = struct {
    /// 본문 영역의 픽셀 사각. **막대는 이 아래 거터 안에 선다**(본문 위에 겹치지 않는다).
    /// `gutter_w`는 그 **아래 여백의 높이**다 — 축이 뒤집힌 자리라 이름과 뜻이 갈리는 유일한 곳이고,
    /// `ContentRect`를 그대로 쓰려고 감수한다(타입을 또 만들면 세로와 갈린다).
    content: scroll_area.ContentRect,
    /// 문서에서 **가장 긴 줄**의 표시 폭(열). 보이는 줄만 보면 세로로 굴릴 때마다 상한이 출렁인다
    /// (`editor_max_cols`가 같은 이유로 문서 전체를 본다).
    total_cols: u32,
    /// 맨 왼쪽에 보이는 열.
    first_col: u32,
    cell_w_px: u16,
    metrics: scroll_area.ScrollbarMetrics,
};

/// 가로 스크롤바를 그린다. §4.1a가 *"가로 스크롤바는 세로와 짝이다"*라고 정한 그 짝이다.
///
/// **랩이 켜지면 호출하지 않는다** — 랩은 넘칠 것을 없애므로 가로 축 자체가 없다(§4). 그 판정은
/// 호출자가 한다(랩 여부를 아는 쪽이다).
///
/// 길이·위치 계산은 세로와 **같은 헬퍼**(`scroll_area.thumbSpan`)를 쓴다. 축만 다르고 규칙은 하나다.
/// `buildHorizontal`이 쓴 양과 기하. **익명 struct를 반환하지 않는다** — 호출자가 `if/else`로
/// 분기하면 두 가지의 타입이 서로 다른 익명 struct가 되어 컴파일이 안 된다(실제로 그렇게 막혔다).
pub const HorizontalWritten = struct {
    ops: usize,
    geometry: ?HorizontalGeometry = null,
};

pub fn buildHorizontal(props: HorizontalProps, out: []draw.Op) HorizontalWritten {
    if (props.content.w <= 0 or props.content.h <= 0 or props.metrics.width_px == 0) return .{ .ops = 0 };
    const thickness: f32 = @floatFromInt(props.metrics.width_px);
    if (props.content.gutter_w < thickness) return .{ .ops = 0 };

    const content_w_px = std.math.mul(u32, props.total_cols, props.cell_w_px) catch std.math.maxInt(u32);
    const offset_px = std.math.mul(u32, props.first_col, props.cell_w_px) catch std.math.maxInt(u32);

    const span = scroll_area.thumbSpan(props.content.w, content_w_px, offset_px, props.metrics.min_thumb_px) orelse
        return .{ .ops = 0 };

    const bar: HorizontalGeometry = .{
        // 아래 여백 안에서 가운데 — 세로가 오른쪽 여백에서 하는 것과 같다.
        .track_x = props.content.x,
        .track_y = props.content.y + props.content.h + (props.content.gutter_w - thickness) / 2,
        .track_w = props.content.w,
        .track_h = thickness,
        .hit_y = props.content.y + props.content.h,
        .hit_h = props.content.gutter_w,
        .thumb_x = props.content.x + span.start_offset,
        .thumb_w = span.len,
        .max_offset_px = span.max_offset_px,
    };
    if (out.len == 0) return .{ .ops = 0, .geometry = bar };

    // `quad`인 이유는 세로와 같다 — 셀 격자 밖이라 `fill`은 조용히 버려진다.
    out[0] = .{ .quad = .{
        .rect = .{
            .x = @intFromFloat(@round(bar.thumb_x)),
            .y = @intFromFloat(@round(bar.track_y)),
            .w = @intFromFloat(@round(bar.thumb_w)),
            .h = @intFromFloat(@round(bar.track_h)),
        },
        .fill_role = thumb_role,
        .alpha = thumb_alpha,
        .corner_radii = .{ 4, 4, 4, 4 },
    } };
    return .{ .ops = 1, .geometry = bar };
}

const testing = std.testing;

fn testProps(total: u32, first: u32) Props {
    return .{
        .content = .{ .x = 0, .y = 0, .w = 400, .h = 160, .gutter_w = 12 },
        .total_visual_rows = total,
        .first_visual_row = first,
        .cell_h_px = 16,
        .metrics = .{ .width_px = 8, .inset_x_px = 4, .min_thumb_px = 24 },
    };
}

test "SBM1 마커는 thumb 아래에 깔린다 — 겹쳐도 비쳐 보인다 (§4.1a)" {
    // thumb 이 반투명이라 **먼저 그린 것이 비친다.** 순서가 뒤집히면 thumb 이 지나갈 때 마커가
    // 가려져, 정작 「지금 보는 자리 근처에 매치가 있나」를 답하지 못한다.
    var ops: [8]draw.Op = undefined;
    var p = testProps(100, 0);
    const rows = [_]u32{ 10, 50, 90 };
    p.match_rows = &rows;
    const w = build(p, &ops);
    try testing.expectEqual(@as(usize, 4), w.ops); // 마커 셋 + thumb 하나

    // 마지막 op 이 thumb 이다.
    try testing.expectEqual(thumb_role, ops[3].quad.fill_role);
    try testing.expectEqual(thumb_alpha, ops[3].quad.alpha);
    // 앞의 셋은 마커다.
    for (ops[0..3]) |op| {
        try testing.expectEqual(marker_role, op.quad.fill_role);
        try testing.expectEqual(@as(u32, @intCast(marker_h_px)), op.quad.rect.h);
    }

    // **막대와 같은 x·폭이다** — 옆에 열을 내면 본문이 그만큼 좁아진다(§4.1a).
    try testing.expectEqual(ops[3].quad.rect.x, ops[0].quad.rect.x);
    try testing.expectEqual(ops[3].quad.rect.w, ops[0].quad.rect.w);
}

test "SBM2 마커 자리는 thumb 과 같은 축에서 나온다 — 위/가운데/아래 (§4.1a)" {
    // 논리 줄로 내면 랩된 문서에서 마커와 thumb 이 **다른 자리를 가리킨다** — 마커로 겨냥해
    // thumb 을 끌면 엉뚱한 데로 간다. 둘 다 시각 행 / totalRows 를 쓴다는 것이 이 표시의 전제다.
    var ops: [8]draw.Op = undefined;
    var p = testProps(100, 0);
    const rows = [_]u32{ 0, 50, 99 };
    p.match_rows = &rows;
    const w = build(p, &ops);
    const bar = w.geometry.?;
    const track_y: i32 = @intFromFloat(@round(bar.track_y));
    const track_h: i32 = @intFromFloat(@round(bar.track_h));

    try testing.expectEqual(track_y, ops[0].quad.rect.y); // 첫 행 → 맨 위
    try testing.expect(ops[1].quad.rect.y > ops[0].quad.rect.y);
    try testing.expect(ops[2].quad.rect.y > ops[1].quad.rect.y);
    try testing.expect(ops[2].quad.rect.y + marker_h_px <= track_y + track_h); // 밖으로 안 나간다

    // **나눗셈의 분모는 `usable`(= track_h - marker_h_px)이다.** `track_h` 로 나누면 마지막 슬롯이
    // 마커 높이만큼 아래로 밀려 막대 끝을 넘본다 — 위 부등식만으로는 그 차이가 안 잡힌다.
    const usable = track_h - marker_h_px;
    const slots: i32 = @intCast(@min(@as(usize, @intCast(@max(@divTrunc(usable, marker_h_px), 1))), marker_budget));
    const last_slot = @divTrunc(@as(i32, 99) * slots, 100);
    try testing.expectEqual(track_y + @divTrunc(last_slot * usable, slots), ops[2].quad.rect.y);
}

test "SBM3 현재 일치는 다른 색이고 겹쳐도 살아남는다 (§4.1a)" {
    // 같은 슬롯에 여럿이 겹치면 **현재 하나는 반드시 보여야 한다** — 사용자가 지금 어디를 보고
    // 있는지가 이 표시의 첫 질문이다.
    var ops: [8]draw.Op = undefined;
    var p = testProps(100, 0);
    const near = [_]u32{ 50, 50, 50 }; // 셋이 같은 자리
    p.match_rows = &near;
    p.current_match = 2;
    const w = build(p, &ops);
    try testing.expectEqual(@as(usize, 2), w.ops); // 합쳐서 마커 하나 + thumb
    try testing.expectEqual(marker_current_role, ops[0].quad.fill_role);
}

test "SBM4 매치가 아무리 많아도 전 구간을 고르게 덮는다 — 앞부분만 찍지 않는다 (§4.1a)" {
    // **상한에 걸렸을 때가 위험하다.** 목록을 그대로 훑으며 그리면 문서 앞부분만 찍히고
    // 아래쪽이 비어 「거기엔 매치가 없다」는 거짓말이 된다.
    var ops: [marker_budget + 4]draw.Op = undefined;
    var rows: [4000]u32 = undefined;
    for (&rows, 0..) |*r, i| r.* = @intCast(i * 2); // 0..7998 에 고루 퍼진 매치 4000개
    var p = testProps(8000, 0);
    p.match_rows = &rows;
    const w = build(p, &ops);
    try testing.expect(w.ops <= marker_budget + 1);

    const bar = w.geometry.?;
    const track_y: i32 = @intFromFloat(@round(bar.track_y));
    const track_h: i32 = @intFromFloat(@round(bar.track_h));

    // **마지막 마커가 막대 아래쪽에 있다** — 앞부분만 찍었다면 여기서 위에 몰려 있다.
    const last = ops[w.ops - 2].quad.rect.y; // 끝에서 둘째(마지막은 thumb)
    try testing.expect(last > track_y + @divTrunc(track_h, 2));

    // 마커가 하나도 안 빠진 것은 아니다 — 첫 마커는 맨 위다.
    try testing.expectEqual(track_y, ops[0].quad.rect.y);
}

test "SBM7 문서 밖 행이 와도 넘치지 않는다 — 마지막 슬롯에 떨어진다 (§4.1a)" {
    // **목록이 문서보다 낡을 수 있다.** 편집을 하면 매치 목록은 다음 재검색까지 옛 문서의 것이고,
    // 그 사이 문서가 짧아지면 행 번호가 범위를 넘는다. 슬롯을 clamp 하지 않으면 `hit[slot]` 이
    // 배열 밖을 짚어 **패닉**한다 — 화면이 틀리는 것이 아니라 앱이 죽는다.
    var ops: [8]draw.Op = undefined;
    var p = testProps(100, 0);
    const rows = [_]u32{ 100, 500, 99999 }; // 전부 문서 밖
    p.match_rows = &rows;
    const w = build(p, &ops);

    const bar = w.geometry.?;
    const track_y: i32 = @intFromFloat(@round(bar.track_y));
    const track_h: i32 = @intFromFloat(@round(bar.track_h));
    // 셋이 같은 마지막 슬롯으로 합쳐진다 — 마커 하나 + thumb.
    try testing.expectEqual(@as(usize, 2), w.ops);
    try testing.expect(ops[0].quad.rect.y + marker_h_px <= track_y + track_h);
    // **막대 아래쪽이다** — 문서 밖이면 「끝」으로 치는 것이 사용자가 읽는 뜻과 가깝다.
    try testing.expect(ops[0].quad.rect.y > track_y + @divTrunc(track_h, 2));
}

test "SBM6 자리가 모자라면 마커를 줄이고 thumb 을 지킨다 (§4.1a)" {
    // **여기가 뒤바뀌면 막대가 통째로 사라진다.** 마커가 op 버퍼를 다 먹으면 thumb 이 안 그려지고,
    // 그러면 스크롤할 것이 있는지조차 화면이 말하지 못한다 — 마커는 부가 표시이고 thumb 은
    // 조작의 근거다. 넉넉한 버퍼만 쓰는 판정자로는 이 경계가 한 번도 안 밟힌다.
    var rows: [64]u32 = undefined;
    for (&rows, 0..) |*r, i| r.* = @intCast(i * 10);
    var p = testProps(1000, 0);
    p.match_rows = &rows;

    // 자리가 셋뿐이면 마커 둘 + thumb 하나다.
    var tight: [3]draw.Op = undefined;
    const w = build(p, &tight);
    try testing.expectEqual(@as(usize, 3), w.ops);
    try testing.expectEqual(thumb_role, tight[2].quad.fill_role); // 마지막은 언제나 thumb

    // 자리가 하나뿐이면 마커는 못 그려도 **thumb 은 그려진다.**
    var one: [1]draw.Op = undefined;
    const w1 = build(p, &one);
    try testing.expectEqual(@as(usize, 1), w1.ops);
    try testing.expectEqual(thumb_role, one[0].quad.fill_role);
}

test "SBM5 목록이 비면 마커를 안 그린다 — 찾기가 닫히면 표시도 없다 (§4.1a)" {
    var ops: [8]draw.Op = undefined;
    const w = build(testProps(100, 0), &ops); // match_rows 기본값 = 빈 조각
    try testing.expectEqual(@as(usize, 1), w.ops); // thumb 만
    try testing.expectEqual(thumb_role, ops[0].quad.fill_role);
}

test "문서가 화면에 다 들어가면 그리지 않는다" {
    var ops: [4]draw.Op = undefined;
    // 화면 160px = 10행. 문서가 10행 이하면 스크롤할 것이 없다.
    try testing.expectEqual(@as(usize, 0), build(testProps(10, 0), &ops).ops);
    try testing.expectEqual(@as(usize, 0), build(testProps(3, 0), &ops).ops);
    try testing.expect(build(testProps(10, 0), &ops).geometry == null);
}

test "넘치면 thumb을 그리고 길이가 비율을 따른다" {
    var ops: [4]draw.Op = undefined;
    const w = build(testProps(20, 0), &ops); // 20행 중 10행이 보인다 → 절반
    try testing.expectEqual(@as(usize, 1), w.ops);
    const bar = w.geometry.?;
    try testing.expectApproxEqAbs(@as(f32, 80), bar.thumb_h, 1); // 160 × (10/20)
    try testing.expectApproxEqAbs(@as(f32, 0), bar.thumb_y, 1); // 맨 위
}

test "스크롤하면 thumb이 비례해서 내려간다" {
    var ops: [4]draw.Op = undefined;
    const top = build(testProps(20, 0), &ops).geometry.?;
    const mid = build(testProps(20, 5), &ops).geometry.?;
    const bottom = build(testProps(20, 10), &ops).geometry.?;

    try testing.expect(mid.thumb_y > top.thumb_y);
    try testing.expect(bottom.thumb_y > mid.thumb_y);
    // 맨 아래에서는 thumb 바닥이 track 바닥에 닿는다.
    try testing.expectApproxEqAbs(bottom.track_h, bottom.thumb_y + bottom.thumb_h, 1);
}

test "범위는 시각 행이다 — 랩된 문서에서 논리 줄로 세면 막대가 길어진다" {
    // 논리 줄 10개짜리 문서가 랩으로 시각 행 40개가 됐다고 하자.
    var ops: [4]draw.Op = undefined;
    const wrapped = build(testProps(40, 0), &ops).geometry.?;
    const logical = build(testProps(10, 0), &ops); // 논리 줄로 셌다면

    // 시각 행으로 세면 thumb이 1/4이고, 논리 줄로 세면 **아예 안 그려진다**(10행 = 화면 높이).
    try testing.expectApproxEqAbs(@as(f32, 40), wrapped.thumb_h, 1);
    try testing.expectEqual(@as(usize, 0), logical.ops);
}

test "thumb이 최소 길이보다 짧아지지 않는다 — 집을 수 없는 막대는 affordance가 아니다" {
    var ops: [4]draw.Op = undefined;
    // 10만 행이면 비례 계산으로는 0.016px다.
    const bar = build(testProps(100_000, 0), &ops).geometry.?;
    try testing.expectApproxEqAbs(@as(f32, 24), bar.thumb_h, 0.01); // min_thumb_px
}

test "행 수 × 셀 높이가 u32를 넘어도 죽지 않는다" {
    var ops: [4]draw.Op = undefined;
    // u32max 행 × 16px는 u32를 한참 넘는다 — 곱셈을 그대로 하면 오버플로로 죽는다.
    const w = build(testProps(std.math.maxInt(u32), 0), &ops);
    try testing.expectEqual(@as(usize, 1), w.ops);
    try testing.expect(w.geometry != null);
}

test "op 저장소가 없어도 기하는 돌려준다 — 호출자가 잡는 자리를 알 수 있다" {
    var none: [0]draw.Op = undefined;
    const w = build(testProps(20, 0), &none);
    try testing.expectEqual(@as(usize, 0), w.ops);
    try testing.expect(w.geometry != null);
}

fn testHProps(total_cols: u32, first_col: u32) HorizontalProps {
    return .{
        .content = .{ .x = 0, .y = 0, .w = 400, .h = 160, .gutter_w = 12 },
        .total_cols = total_cols,
        .first_col = first_col,
        .cell_w_px = 8,
        .metrics = .{ .width_px = 8, .inset_x_px = 4, .min_thumb_px = 24 },
    };
}

test "가로: 가장 긴 줄이 화면에 다 들어가면 안 그린다" {
    var ops: [4]draw.Op = undefined;
    // 본문 400px / 셀 8px = 50열. 문서가 50열 이하면 밀 것이 없다.
    try testing.expectEqual(@as(usize, 0), buildHorizontal(testHProps(50, 0), &ops).ops);
    try testing.expect(buildHorizontal(testHProps(20, 0), &ops).geometry == null);
}

test "가로: 넘치면 thumb 길이가 비율을 따르고 오른쪽 끝에서 track 끝에 닿는다" {
    var ops: [4]draw.Op = undefined;
    const w = buildHorizontal(testHProps(100, 0), &ops); // 100열 중 50열이 보인다 → 절반
    try testing.expectEqual(@as(usize, 1), w.ops);
    const bar = w.geometry.?;
    try testing.expectApproxEqAbs(@as(f32, 200), bar.thumb_w, 1); // 400 × (50/100)
    try testing.expectApproxEqAbs(@as(f32, 0), bar.thumb_x, 1);

    // 끝까지 밀면 thumb 오른쪽이 track 오른쪽에 닿는다 — 세로가 바닥에서 그러는 것과 같다.
    const end = buildHorizontal(testHProps(100, 50), &ops).geometry.?;
    try testing.expectApproxEqAbs(bar.track_x + bar.track_w, end.thumb_x + end.thumb_w, 1);
}

test "가로: 막대가 본문 아래 거터 안에 서고 본문을 덮지 않는다" {
    var ops: [4]draw.Op = undefined;
    const p = testHProps(100, 0);
    const bar = buildHorizontal(p, &ops).geometry.?;
    // 본문 바닥(y + h) 아래에서 시작한다 — 겹치면 마지막 줄 글자가 막대에 가린다.
    try testing.expect(bar.track_y >= p.content.y + p.content.h);
    try testing.expect(bar.track_y + bar.track_h <= p.content.y + p.content.h + p.content.gutter_w);
    // 잡는 자리는 거터 전체다.
    try testing.expectApproxEqAbs(p.content.y + p.content.h, bar.hit_y, 0.01);
    try testing.expectApproxEqAbs(p.content.gutter_w, bar.hit_h, 0.01);
}

test "가로: thumb이 최소 길이보다 짧아지지 않는다" {
    var ops: [4]draw.Op = undefined;
    const bar = buildHorizontal(testHProps(100_000, 0), &ops).geometry.?;
    try testing.expectApproxEqAbs(@as(f32, 24), bar.thumb_w, 0.01);
}

test "가로: 열 수 × 셀 폭이 u32를 넘어도 죽지 않는다" {
    var ops: [4]draw.Op = undefined;
    const w = buildHorizontal(testHProps(std.math.maxInt(u32), 0), &ops);
    try testing.expectEqual(@as(usize, 1), w.ops);
}

test "가로와 세로가 같은 규칙을 쓴다 — 축만 바꾸면 같은 답이 나온다" {
    // **규칙이 갈리지 않는지 본다.** 둘 다 `thumbSpan`을 쓰므로, 같은 비율·같은 최소 두께를 주면
    // 길이가 같아야 한다. 한쪽만 고치는 회귀가 여기서 걸린다.
    var ops: [4]draw.Op = undefined;
    const v = build(.{
        .content = .{ .x = 0, .y = 0, .w = 400, .h = 400, .gutter_w = 12 },
        .total_visual_rows = 100,
        .first_visual_row = 0,
        .cell_h_px = 8,
        .metrics = .{ .width_px = 8, .inset_x_px = 4, .min_thumb_px = 24 },
    }, &ops).geometry.?;
    const h = buildHorizontal(.{
        .content = .{ .x = 0, .y = 0, .w = 400, .h = 400, .gutter_w = 12 },
        .total_cols = 100,
        .first_col = 0,
        .cell_w_px = 8,
        .metrics = .{ .width_px = 8, .inset_x_px = 4, .min_thumb_px = 24 },
    }, &ops).geometry.?;
    try testing.expectApproxEqAbs(v.thumb_h, h.thumb_w, 0.01);
    try testing.expectEqual(v.max_offset_px, h.max_offset_px);
}
