//! 편집기 뷰의 **바탕** — §4.1b
//! ([native-editor-visual-mapping.md](../../../../docs/native-editor-visual-mapping.md)).
//!
//! **뷰가 자기 배경을 소유한다.** 그 전에는 편집기가 글자와 막대만 냈고, 화면에 보이던 어두운 색은
//! **렌더러의 clear color**였다. 그러면 셋이 어긋난다:
//!
//! - **뷰 경계가 보이지 않는다.** 뷰포트가 화면보다 작을 때(분할 pane, 캡처 픽스처) 어디까지가
//!   편집기인지 알 수 없다 — 실제로 "화면이 안 찼는데 스크롤바가 있다"는 오해가 캡처에서 나왔다.
//! - **테마를 따르지 않는다.** clear color는 토큰이 아니라 라이트 테마에서도 그대로다.
//! - **pane 합성에서 아래가 비친다.**
//!
//! **gutter와 본문이 같은 배경이다.** VSCode도 기본 테마에서 `editorGutter.background`가
//! `editor.background`와 같다 — 둘을 가르면 폰트 크기가 바뀔 때마다 경계가 움직여 눈에 띈다.

const std = @import("std");
const chrome = @import("../../../chrome.zig");

const draw = chrome.draw;
const tokens = chrome.tokens;

/// 바탕색. **터미널 본문과 같은 색**이다(`terminal_bg`) — 도크·사이드바의 `surface_bg`가 아니다.
///
/// 편집기는 도크가 아니라 **터미널이 있던 그 자리**를 채운다. 같은 pane에서 탭을 오갈 때 바탕이
/// 밝아졌다 어두워지면 두 뷰가 서로 다른 곳처럼 보인다(2026-08-13 사용자 결정). 테마를 따르는 성질은
/// 그대로다 — 라이트 테마에서는 이 토큰도 함께 밝아진다.
pub const background_role: tokens.ColorRole = .terminal_bg;

pub const Props = struct {
    /// 편집기 뷰가 차지하는 픽셀 사각. **gutter·본문·스크롤바 gutter를 한 사각으로 덮는다** —
    /// 영역마다 나누면 사이에 clear color가 새는 1px 틈이 생긴다.
    rect: draw.Rect,
};

pub const Written = struct {
    ops: usize,
};

/// 배경 op을 채운다. **호출자는 이것을 맨 처음에 넣어야 한다**(painter) — 나중에 오면 글자를 덮는다.
pub fn build(props: Props, out: []draw.Op) Written {
    if (props.rect.w == 0 or props.rect.h == 0) return .{ .ops = 0 };
    if (out.len == 0) return .{ .ops = 0 };

    // **`quad`다.** `fill`은 셀 격자로 내려가는데(`metal_lowering.paintRectBg`) 뷰 사각은 스크롤바
    // gutter까지 덮어 격자 밖으로 나간다 — 스크롤바가 같은 이유로 quad를 쓴다(§4.1a).
    out[0] = .{ .quad = .{ .rect = props.rect, .fill_role = background_role } };
    return .{ .ops = 1 };
}

const testing = std.testing;

test "뷰 사각을 한 op으로 덮는다" {
    var ops: [2]draw.Op = undefined;
    const w = build(.{ .rect = .{ .x = 0, .y = 0, .w = 480, .h = 96 } }, &ops);
    try testing.expectEqual(@as(usize, 1), w.ops);
    try testing.expectEqual(@as(u32, 480), ops[0].quad.rect.w);
    try testing.expectEqual(@as(u32, 96), ops[0].quad.rect.h);
    // **리터럴로 판정한다.** `background_role`과 비교하면 그 상수를 무엇으로 바꿔도 통과하는
    // 항등식이다 — 실제로 그런 상태였고, Chrome Lab 캡처도 이것을 못 잡는다(Lab 픽스처가
    // `sidebar_background`를 터미널 배경과 같은 값으로 뭉개 둬서 두 역할이 같은 색으로 나온다).
    // 그래서 이 한 줄이 "편집기 바탕 = 터미널 바탕" 계약의 유일한 자동 판정이다.
    try testing.expectEqual(tokens.ColorRole.terminal_bg, ops[0].quad.fill_role);
}

test "빈 사각이면 그리지 않는다" {
    var ops: [2]draw.Op = undefined;
    try testing.expectEqual(@as(usize, 0), build(.{ .rect = .{ .x = 0, .y = 0, .w = 0, .h = 96 } }, &ops).ops);
    try testing.expectEqual(@as(usize, 0), build(.{ .rect = .{ .x = 0, .y = 0, .w = 480, .h = 0 } }, &ops).ops);
}

test "op 저장소가 없으면 아무것도 하지 않는다" {
    var none: [0]draw.Op = undefined;
    try testing.expectEqual(@as(usize, 0), build(.{ .rect = .{ .x = 0, .y = 0, .w = 480, .h = 96 } }, &none).ops);
}
