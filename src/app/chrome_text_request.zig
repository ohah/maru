//! Owned semantic chrome text requests shared by native shaping adapters.
const std = @import("std");
const maru = @import("../maru.zig");
const chrome = maru.chrome;
const icons = maru.icons;
pub const Request = struct {
    fingerprint: u64,
    runs: []Run,
    /// 이 요청 전체가 쓸 face. run이 아니라 요청 단위인 이유는 한 프레임의 모든 chrome 텍스트가 같은
    /// 폰트를 쓰기 때문이다 — run마다 들면 같은 문자열이 run 수만큼 복사될 뿐이고, 브리지의 face 캐시도
    /// run마다 키를 다시 만들게 된다. 빈 슬라이스면 system UI face(레거시 경로).
    /// 소유권은 `Request`에 있다(worker 이송 가능성을 유지하려면 borrow가 아니어야 한다).
    font_family: []u8 = &.{},
    /// 터미널과 같은 `font.fallback` CSV. 이걸 함께 넘기지 않으면 주 폰트에 없는 글리프(한글·이모지)가
    /// 사이드바와 다른 폰트로 떨어져 face를 맞춘 의미가 사라진다.
    font_fallback: []u8 = &.{},

    pub const Run = struct {
        text: []u8,
        role: chrome.ui.typography.ChromeTextRole,
        origin: chrome.draw.Px,
        max_width_px: u32,
        foreground: u32,
        /// 넘칠 때 어느 쪽을 자르는가. 입력 줄은 `.tail`이어야 caret과 방금 친 글자가 남는다 —
        /// 셀 경로가 `overlay_input.inputLineView`(tail 창)로 풀던 규칙을 CoreText truncation이 대신한다.
        anchor: chrome.text_layout.Anchor = .head,
        placement: chrome.draw.TextPlacement = .origin,
        scroll_clipped: bool = false,
        above_clip: ?chrome.draw.Rect = null,
        /// 편집기 폰트 크기(device px, §2.0). null이면 기존 토큰 폰트 크기 그대로다.
        font_px: ?u16 = null,
        /// 편집기 줄 높이(device px, §2.0). `font_px`와 짝이다.
        line_height_px: ?u16 = null,
        /// 편집기 셀 폭(device px, §2.0). 글자 x를 **셀 인덱스**로 놓을 때 쓴다.
        cell_w_px: ?u16 = null,
        /// 같은 op 의 앞 run 에 **이어서** 놓는가(`chrome.draw.Run` 계약). 컴포넌트는 비례 폰트의
        /// advance 를 모르므로 한 줄 안에서 색이 바뀌는 구간을 스스로 이어 붙일 수 없다 — 셀 격자로
        /// 추정해 op 을 나누면 구간 사이가 눈에 띄게 벌어진다. 그 이음은 **측정값을 가진 이쪽**이 한다.
        continues_previous: bool = false,
    };

    pub fn deinit(self: *Request, allocator: std.mem.Allocator) void {
        for (self.runs) |run| allocator.free(run.text);
        allocator.free(self.runs);
        allocator.free(self.font_family);
        allocator.free(self.font_fallback);
        self.* = undefined;
    }
};

pub fn shapesTextOp(text: chrome.draw.Op.Text) bool {
    // 등록 SVG/PUA 아이콘은 icon draw list가 그린다 — spinner phase가 매 프레임 바뀌므로 셰이핑 키에
    // 넣으면 모든 결과가 도착 전에 stale이 된다.
    return !text.wide_icons;
}

/// op 안의 한 run이 셰이핑 대상인지. op 단위 판정과 같은 이유로 단일 출처다.
pub fn shapesRun(text: chrome.draw.Op.Text, run: chrome.draw.Run, max_width_px: u32) bool {
    if (max_width_px == 0) return false;
    // 순수 등록 SVG placement는 CoreText source bytes가 없다. 그 semantic run은 유지한다(worker가
    // 셰이핑을 건너뛰고 논리 rect에서 SVG를 직접 해석한다). 그 밖의 빈 텍스트는 inert다.
    return run.text.len != 0 or text.placement == .icon_in_rect;
}

/// `max_cols`/`max_width_px`에서 이 op의 픽셀 폭 예산을 푼다. 키와 request가 같은 값을 봐야 하므로
/// 이것도 단일 출처다.
pub fn opMaxWidthPx(text: chrome.draw.Op.Text, cell_width_px: u32) ?u32 {
    return text.max_width_px orelse (std.math.mul(u32, text.max_cols, cell_width_px) catch null);
}

/// 이 요청이 쓸 face. platform이 resolved appearance에서 채운다 — chrome 컴포넌트는 여전히 face를 모르고
/// role만 고른다(`chrome/ui/typography.zig` 헤더 계약). 기본값(빈 family)은 system UI face라, resolved
/// appearance가 없는 호출자(Chrome Lab·단위 테스트)가 예전 동작을 그대로 얻는다.
/// 단일 출처: docs/font-strategy.md "Chrome 텍스트 face".
pub const Face = struct {
    family: []const u8 = &.{},
    fallback: []const u8 = &.{},
};

/// Copies only non-icon semantic text out of the frame-local draw list.  This is intentionally
/// cheap enough for the frame path; CoreText shaping is performed only by `shapeRequest`.
pub fn prepareRequest(
    allocator: std.mem.Allocator,
    fingerprint: u64,
    ops: []const chrome.draw.Op,
    tk: *const chrome.Tokens,
    cell_width_px: u32,
    face: Face,
) !Request {
    var runs: std.ArrayList(Request.Run) = .empty;
    errdefer {
        for (runs.items) |run| allocator.free(run.text);
        runs.deinit(allocator);
    }
    for (ops) |op| switch (op) {
        .text => |text| {
            // 좌표(특히 음수 origin)는 여기서 거르지 않는다. 좌표는 shaping 입력이 아니라 placement
            // 계산에만 쓰이고, 화면 밖 여부는 backend의 뷰포트 클립이 판단한다. 거르면 셰이핑 키와 집합이
            // 갈라져 캐시가 그 줄을 영구히 잃는다(`shapesTextOp` 주석).
            if (!shapesTextOp(text)) continue;
            const max_width = opMaxWidthPx(text, cell_width_px) orelse continue;
            var first_run = true;
            for (text.runs) |run| {
                if (!shapesRun(text, run, max_width)) continue;
                // Reserve before copying: a failed append must not orphan the text.
                try runs.ensureUnusedCapacity(allocator, 1);
                runs.appendAssumeCapacity(.{
                    .text = try allocator.dupe(u8, run.text),
                    .role = text.text_role,
                    .origin = text.origin,
                    .max_width_px = max_width,
                    // run 이 자기 role 을 들면 그 구간만 다른 색이다(한 줄 안의 위계). 없으면 op 색.
                    .foreground = packRgb(tk.get(run.role orelse text.role)),
                    // **한 op 의 두 번째 run 부터**는 앞 run 끝에 이어 붙인다. 셰이핑에서 걸러진 run 은
                    // 여기 오지 않으므로, 이 표시는 실제로 발행되는 run 들의 순서를 따른다.
                    .continues_previous = !first_run,
                    .anchor = text.anchor,
                    .placement = text.placement,
                    .font_px = text.font_px,
                    .line_height_px = text.line_height_px,
                    .cell_w_px = text.cell_w_px,
                    .scroll_clipped = text.scroll_clipped,
                    .above_clip = if (text.above_scroll) text.clip else null,
                });
                first_run = false;
            }
        },
        else => {},
    };
    const family = try allocator.dupe(u8, face.family);
    errdefer allocator.free(family);
    const fallback = try allocator.dupe(u8, face.fallback);
    errdefer allocator.free(fallback);
    return .{
        .fingerprint = fingerprint,
        .runs = try runs.toOwnedSlice(allocator),
        .font_family = family,
        .font_fallback = fallback,
    };
}

test "prepareRequest keeps a Korean button label and an icon-in-rect on the measured path" {
    const allocator = std.testing.allocator;
    const icon_runs = [_]chrome.draw.Run{.{ .text = icons.utf8(.recent) }};
    const label_runs = [_]chrome.draw.Run{.{ .text = "터미널에서 이어하기" }};
    const utility_runs = [_]chrome.draw.Run{.{ .text = "" }};
    const ops = [_]chrome.draw.Op{
        .{ .text = .{
            .origin = .{ .x = 24, .y = 8 },
            .runs = &icon_runs,
            .role = .surface_fg,
            .text_role = .button_label,
            .max_cols = 2,
            .wide_icons = true,
        } },
        .{ .text = .{
            .origin = .{ .x = 48, .y = 8 },
            .runs = &label_runs,
            .role = .surface_fg,
            .text_role = .button_label,
            .max_cols = 18,
        } },
        .{ .text = .{
            .origin = .{ .x = 80, .y = 8 },
            .runs = &utility_runs,
            .role = .surface_fg,
            .text_role = .control,
            .max_cols = 1,
            .max_width_px = 20,
            .placement = .{ .icon_in_rect = .{
                .content_rect = .{ .x = 80, .y = 8, .w = 20, .h = 20 },
                .icon_codepoint = icons.codepointFit(.reset, .tight),
                .icon_extent_px = 18,
            } },
        } },
    };
    const tk = chrome.Tokens.rich(.{
        .diff_added = .{ .r = 64, .g = 160, .b = 64 }, // 픽스처: 비교 밴드 입력(§7)
        .diff_removed = .{ .r = 176, .g = 64, .b = 64 },
        .foreground = .{ .r = 240, .g = 240, .b = 240 },
        .sidebar_background = .{ .r = 20, .g = 20, .b = 20 },
        .sidebar_foreground = .{ .r = 220, .g = 220, .b = 220 },
        .sidebar_active = .{ .r = 80, .g = 80, .b = 80 },
        .search_match = .{ .r = 1, .g = 2, .b = 3 },
        .search_match_current = .{ .r = 4, .g = 5, .b = 6 },
        .selection = .{ .r = 7, .g = 8, .b = 9 },
        .cursor = .{ .r = 10, .g = 11, .b = 12 },
        .terminal_background = .{ .r = 10, .g = 11, .b = 12 }, // 픽스처: 터미널 배경 입력(§4.1b terminal_bg)
        .accent = .{ .r = 13, .g = 14, .b = 15 },
    });
    var request = try prepareRequest(allocator, 17, &ops, &tk, 8, .{});
    defer request.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), request.runs.len);
    try std.testing.expectEqualStrings("터미널에서 이어하기", request.runs[0].text);
    try std.testing.expectEqual(chrome.ui.typography.ChromeTextRole.button_label, request.runs[0].role);
    try std.testing.expectEqual(@as(u32, 18 * 8), request.runs[0].max_width_px);
    try std.testing.expectEqual(@as(usize, 0), request.runs[1].text.len);
    try std.testing.expectEqual(icons.codepointFit(.reset, .tight), request.runs[1].placement.icon_in_rect.icon_codepoint);
}

// 코드리뷰 회귀: 셰이핑 키가 스크롤 평행이동에 불변이 되면서, 같은 키가 "그 줄이 화면 위로 나가 있던
// 프레임"과 "그 줄이 보이는 프레임" 양쪽을 가리킬 수 있게 됐다. 그런데 request는 음수 origin을 버리고
// 있었으므로, 전자에서 만든 artifact에는 그 run이 없고 후자에서 그 artifact가 재사용되며 그 줄이 영구히
// 빈 채로 남았다(확장 카드를 위로 밀었다 되돌리면 제목과 첫 turn이 사라진다). 좌표는 shaping 입력이
// 아니므로 음수여도 셰이핑해야 하고, 화면 밖 여부는 backend의 뷰포트 클립이 판단한다.
test "prepareRequest keeps runs scrolled above the pane so a translated cache stays complete" {
    const allocator = std.testing.allocator;
    const above_runs = [_]chrome.draw.Run{.{ .text = "scrolled-above" }};
    const visible_runs = [_]chrome.draw.Run{.{ .text = "visible" }};
    const ops = [_]chrome.draw.Op{
        .{ .text = .{ .origin = .{ .x = 20, .y = -48 }, .runs = &above_runs, .role = .surface_fg, .text_role = .card_heading, .max_cols = 20, .scroll_clipped = true } },
        .{ .text = .{ .origin = .{ .x = 20, .y = 120 }, .runs = &visible_runs, .role = .surface_fg, .text_role = .body, .max_cols = 20, .scroll_clipped = true } },
    };
    const tk = chrome.Tokens.rich(.{
        .diff_added = .{ .r = 64, .g = 160, .b = 64 }, // 픽스처: 비교 밴드 입력(§7)
        .diff_removed = .{ .r = 176, .g = 64, .b = 64 },
        .foreground = .{ .r = 240, .g = 240, .b = 240 },
        .sidebar_background = .{ .r = 20, .g = 20, .b = 20 },
        .sidebar_foreground = .{ .r = 220, .g = 220, .b = 220 },
        .sidebar_active = .{ .r = 80, .g = 80, .b = 80 },
        .search_match = .{ .r = 1, .g = 2, .b = 3 },
        .search_match_current = .{ .r = 4, .g = 5, .b = 6 },
        .selection = .{ .r = 7, .g = 8, .b = 9 },
        .cursor = .{ .r = 10, .g = 11, .b = 12 },
        .terminal_background = .{ .r = 10, .g = 11, .b = 12 }, // 픽스처: 터미널 배경 입력(§4.1b terminal_bg)
        .accent = .{ .r = 13, .g = 14, .b = 15 },
    });
    var request = try prepareRequest(allocator, 5, &ops, &tk, 8, .{});
    defer request.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), request.runs.len);
    try std.testing.expectEqualStrings("scrolled-above", request.runs[0].text);
    try std.testing.expectEqual(@as(i32, -48), request.runs[0].origin.y);
}

// 이 테스트가 증명하는 것: face 바이트를 `Request`가 **소유**한다.
//
// 왜 터미널에서 중요한가 — `Request`는 detached worker로 건널 수 있다는 전제로 설계돼 있고(위 타입
// 주석), 지금도 셰이핑은 호출자의 `ResolvedAppearance`가 config arena에 살아 있는지와 무관하게
// 끝나야 한다. face만 borrow로 두면 config 재로드가 arena를 갈아끼운 프레임에서 해제된 문자열로
// CTFont를 만들게 된다. 소유 여부는 "원본을 덮어써도 request가 그대로인가"로만 증명할 수 있다.
test "prepareRequest owns the face bytes instead of borrowing the caller's appearance" {
    const allocator = std.testing.allocator;
    const runs = [_]chrome.draw.Run{.{ .text = "owned" }};
    const ops = [_]chrome.draw.Op{
        .{ .text = .{ .origin = .{ .x = 0, .y = 0 }, .runs = &runs, .role = .surface_fg, .text_role = .body, .max_cols = 20 } },
    };
    const tk = chrome.Tokens.rich(.{
        .diff_added = .{ .r = 64, .g = 160, .b = 64 }, // 픽스처: 비교 밴드 입력(§7)
        .diff_removed = .{ .r = 176, .g = 64, .b = 64 },
        .foreground = .{ .r = 240, .g = 240, .b = 240 },
        .sidebar_background = .{ .r = 20, .g = 20, .b = 20 },
        .sidebar_foreground = .{ .r = 220, .g = 220, .b = 220 },
        .sidebar_active = .{ .r = 80, .g = 80, .b = 80 },
        .search_match = .{ .r = 1, .g = 2, .b = 3 },
        .search_match_current = .{ .r = 4, .g = 5, .b = 6 },
        .selection = .{ .r = 7, .g = 8, .b = 9 },
        .cursor = .{ .r = 10, .g = 11, .b = 12 },
        .terminal_background = .{ .r = 10, .g = 11, .b = 12 }, // 픽스처: 터미널 배경 입력(§4.1b terminal_bg)
        .accent = .{ .r = 13, .g = 14, .b = 15 },
    });
    var family_buf = "JetBrains Mono".*;
    var fallback_buf = "Jetendard".*;
    var request = try prepareRequest(allocator, 7, &ops, &tk, 8, .{ .family = &family_buf, .fallback = &fallback_buf });
    defer request.deinit(allocator);
    @memset(&family_buf, 'x');
    @memset(&fallback_buf, 'x');
    try std.testing.expectEqualStrings("JetBrains Mono", request.font_family);
    try std.testing.expectEqualStrings("Jetendard", request.font_fallback);
}

// 이 테스트가 증명하는 것: chrome 텍스트가 **요청한 family로** 셰이핑되고, family를 안 주면 예전처럼
// system UI face로 셰이핑된다.
//
// 왜 터미널에서 중요한가 — 도크와 사이드바가 한 화면에 보이므로 face가 갈리면 사용자가 고른 폰트를
// 앱이 절반만 따르게 된다(docs/font-strategy.md "Chrome 텍스트 face"). 판정을 PostScript 이름으로 두는
// 이유는 그것이 실제로 래스터에 쓰일 face의 identity이기 때문이다 — 요청만 흘려보내고 CoreText가
// 다른 face를 돌려주는 회귀는 요청 문자열로는 잡히지 않는다. Menlo를 쓰는 것은 macOS 기본 설치라
// 번들 폰트 등록 여부에 흔들리지 않기 때문이다.
fn packRgb(rgb: maru.color.Rgb) u32 {
    return (@as(u32, rgb.r) << 16) | (@as(u32, rgb.g) << 8) | rgb.b;
}

fn allocationFailureRequest(allocator: std.mem.Allocator) !void {
    const runs = [_]chrome.draw.Run{.{ .text = "owned text" }} ** 24;
    const ops = [_]chrome.draw.Op{.{ .text = .{
        .origin = .{ .x = 0, .y = 0 }, .runs = &runs,
        .role = .surface_fg, .text_role = .body, .max_cols = 20,
    } }};
    const tk = std.mem.zeroes(chrome.Tokens);
    var request = try prepareRequest(allocator, 11, &ops, &tk, 8, .{
        .family = "primary", .fallback = "fallback",
    });
    defer request.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 24), request.runs.len);
    try std.testing.expectEqualStrings("owned text", request.runs[23].text);
}

test "prepareRequest cleans every allocation failure including run capacity growth" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailureRequest, .{});
}
