//! quick terminal(전역 토글 오버레이 패널)의 보임/숨김 사각형 계산 — 위치별 두께·가장자리 슬라이드 방향·center
//! 페이드를 한곳에 모은 단일 출처. `app_session.zig`(거대 단일 파일)에서 순수 위치 기하(`compute`)를 떼어내
//! 세션·AppKit 없이 단위 테스트로 고정한다(session/layout_math.zig가 grid·hit-test 순수 기하를 떼어낸 것과
//! 같은 결이나, 여기 좌표는 음수 오프스크린 f64라 정수 SplitRect를 못 쓰고 config enum에 의존하므로 platform
//! 계층에 둔다). `compute`는 순수 함수이고, 그 **결과 POD(`Frames`, C ABI 레이아웃)**도 함께 정의해 계산·결과
//! 타입을 co-locate한다 — app_session이 `QuickTerminalFrames`로 re-export하고 `AppSession.quickTerminalFrames`가
//! 매 토글마다 이 결과를 라이브로 받아(설정 변경 즉시 반영) Swift에 넘긴다. `Frames` 필드 순서·패딩은 C
//! `MaruAppHostQuickTerminalFrames`와 묶인 ABI 계약이라(app_host_abi 크기 대조 테스트가 고정) 임의 변경 금지.
//! 단일 출처: docs/config-gui.md §6.10, docs/macos-app-host-boundary.md.

const std = @import("std");
const maru = @import("maru");
const config = maru.config;

/// quick 패널의 보임/숨김 사각형(C ABI). Swift가 화면 visibleFrame(minX/minY/width/height)을 넘겨
/// `maru_macos_app_session_quick_terminal_frames`로 받아 슬라이드/페이드 애니메이션에 쓴다. 좌표는 macOS 관례
/// (원점 좌하단, y 위로 증가)라 Swift가 NSRect로 그대로 되읽는다. is_centered=1이면 center(가장자리 없음 →
/// 보임=숨김 같은 사각형, 슬라이드 대신 알파 페이드). 순수 POD. Swift가 매 토글마다 이 값을 라이브로 받아
/// (설정 변경 즉시 반영) config 스냅샷 캐시 없이 그린다. app_session이 `QuickTerminalFrames`로 re-export한다.
pub const Frames = extern struct {
    shown_x: f64,
    shown_y: f64,
    shown_w: f64,
    shown_h: f64,
    hidden_x: f64,
    hidden_y: f64,
    hidden_w: f64,
    hidden_h: f64,
    is_centered: u32,
    _reserved: u32 = 0, // extern struct 정렬 패딩(f64 8개 뒤 u32 2개 = 8바이트 배수 유지)
};

/// quick 패널의 보임/숨김 사각형을 화면 visibleFrame(vf_*)과 config로 계산한다 — 위치별 두께·가장자리 슬라이드
/// 방향을 한곳에 모은 단일 출처. 순수 함수(세션 불요)라 위치 기하를 단위 테스트로 고정한다. Swift
/// `quickPanelFrames()`가 매 토글마다 이 결과를 라이브로 받아 애니메이션한다(설정 변경 즉시 반영 — 세션-불변
/// 캐시 제거). height_fraction/width_fraction은 loader가 범위 검증한 값을 그대로 쓴다.
pub fn compute(qt: config.theme.QuickTerminalConfig, vf_x: f64, vf_y: f64, vf_w: f64, vf_h: f64) Frames {
    // '두께' 비율(가장자리에 수직) — top/bottom이면 높이, left/right면 폭에 적용. loader가 0.1~1.0 검증한 값.
    const hf: f64 = qt.height_fraction;
    return switch (qt.position) {
        .top => blk: {
            // 상단 전폭에 붙고(보임), 같은 크기로 위(화면 밖)로 빠짐(숨김). y 위로 증가하는 macOS 좌표.
            const h = @round(vf_h * hf);
            break :blk .{ .shown_x = vf_x, .shown_y = vf_y + vf_h - h, .shown_w = vf_w, .shown_h = h, .hidden_x = vf_x, .hidden_y = vf_y + vf_h, .hidden_w = vf_w, .hidden_h = h, .is_centered = 0 };
        },
        .bottom => blk: {
            // 하단 전폭에 붙고, 아래로 빠짐.
            const h = @round(vf_h * hf);
            break :blk .{ .shown_x = vf_x, .shown_y = vf_y, .shown_w = vf_w, .shown_h = h, .hidden_x = vf_x, .hidden_y = vf_y - h, .hidden_w = vf_w, .hidden_h = h, .is_centered = 0 };
        },
        .left => blk: {
            // 좌측 전고에 붙고(두께=hf×폭), 왼쪽으로 빠짐.
            const w = @round(vf_w * hf);
            break :blk .{ .shown_x = vf_x, .shown_y = vf_y, .shown_w = w, .shown_h = vf_h, .hidden_x = vf_x - w, .hidden_y = vf_y, .hidden_w = w, .hidden_h = vf_h, .is_centered = 0 };
        },
        .right => blk: {
            // 우측 전고에 붙고, 오른쪽으로 빠짐.
            const w = @round(vf_w * hf);
            break :blk .{ .shown_x = vf_x + vf_w - w, .shown_y = vf_y, .shown_w = w, .shown_h = vf_h, .hidden_x = vf_x + vf_w, .hidden_y = vf_y, .hidden_w = w, .hidden_h = vf_h, .is_centered = 0 };
        },
        .center => blk: {
            // 가장자리가 없어 화면 중앙에 가로=width_fraction(미설정 0이면 height_fraction 폴백=정사각)·세로=
            // height_fraction 비율로 띄우고, 슬라이드 대신 페이드라 보임=숨김(같은 사각형).
            const wfrac: f64 = if (qt.width_fraction > 0) qt.width_fraction else hf;
            const w = @round(vf_w * wfrac);
            const h = @round(vf_h * hf);
            const x = @round(vf_x + vf_w / 2.0 - w / 2.0);
            const y = @round(vf_y + vf_h / 2.0 - h / 2.0);
            break :blk .{ .shown_x = x, .shown_y = y, .shown_w = w, .shown_h = h, .hidden_x = x, .hidden_y = y, .hidden_w = w, .hidden_h = h, .is_centered = 1 };
        },
    };
}

test "compute: 가장자리 위치별 보임/숨김 사각형(top/bottom/left/right)" {
    // 이 테스트가 증명하는 것: quick terminal 드롭다운 패널의 가장자리 슬라이드 기하 — 보임 사각형은 지정
    // 가장자리에 정확한 두께로 붙고, 숨김 사각형은 같은 폭·높이로 그 가장자리 바깥으로만 빠진다(슬라이드 축만
    // 다름). 터미널에서 top/bottom/left/right 설정이 실제로 그 변에서 내려와야 사용자가 기대한 위치에 뜬다.
    const vf_w: f64 = 1000;
    const vf_h: f64 = 800;
    // top(기본 두께 0.45): 상단에 붙고 위(전체 높이)로 빠짐. h=round(800*0.45)=360.
    {
        const f = compute(.{ .position = .top, .height_fraction = 0.45 }, 0, 0, vf_w, vf_h);
        try std.testing.expectEqual(@as(f64, 0), f.shown_x);
        try std.testing.expectEqual(@as(f64, 440), f.shown_y); // vf_y + vf_h - h = 800-360
        try std.testing.expectEqual(@as(f64, 1000), f.shown_w);
        try std.testing.expectEqual(@as(f64, 360), f.shown_h);
        try std.testing.expectEqual(@as(f64, 800), f.hidden_y); // 위로 빠짐(vf_y + vf_h)
        try std.testing.expectEqual(@as(u32, 0), f.is_centered);
    }
    // bottom: 하단에 붙고 아래로 빠짐.
    {
        const f = compute(.{ .position = .bottom, .height_fraction = 0.45 }, 0, 0, vf_w, vf_h);
        try std.testing.expectEqual(@as(f64, 0), f.shown_y);
        try std.testing.expectEqual(@as(f64, 360), f.shown_h);
        try std.testing.expectEqual(@as(f64, -360), f.hidden_y); // 아래로 빠짐(vf_y - h)
    }
    // left: 좌측 전고, 두께는 height_fraction×폭(=450). 왼쪽으로 빠짐.
    {
        const f = compute(.{ .position = .left, .height_fraction = 0.45 }, 0, 0, vf_w, vf_h);
        try std.testing.expectEqual(@as(f64, 0), f.shown_x);
        try std.testing.expectEqual(@as(f64, 450), f.shown_w);
        try std.testing.expectEqual(@as(f64, 800), f.shown_h);
        try std.testing.expectEqual(@as(f64, -450), f.hidden_x); // 왼쪽으로 빠짐(vf_x - w)
    }
    // right: 우측 전고, 오른쪽으로 빠짐.
    {
        const f = compute(.{ .position = .right, .height_fraction = 0.45 }, 0, 0, vf_w, vf_h);
        try std.testing.expectEqual(@as(f64, 550), f.shown_x); // vf_x + vf_w - w = 1000-450
        try std.testing.expectEqual(@as(f64, 450), f.shown_w);
        try std.testing.expectEqual(@as(f64, 1000), f.hidden_x); // 오른쪽 바깥(vf_x + vf_w)
    }
}

test "compute: center는 보임=숨김(페이드) + width 폴백/독립" {
    // 이 테스트가 증명하는 것: center 위치는 가장자리가 없어 슬라이드 대신 페이드라 보임=숨김(같은 사각형)이고,
    // width_fraction=0이면 세로 비율(height_fraction)을 가로에도 써 정사각, 설정하면 가로/세로가 독립이며 화면
    // 중앙 정렬이 맞아야 한다 — center 설정이 실제로 중앙 패널로 뜨는지 보장.
    const vf_w: f64 = 1000;
    const vf_h: f64 = 800;
    // width 미설정(0) → height(0.45) 폴백: w=450, h=360, 중앙 (275, 220), 보임=숨김.
    {
        const f = compute(.{ .position = .center, .height_fraction = 0.45, .width_fraction = 0 }, 0, 0, vf_w, vf_h);
        try std.testing.expectEqual(@as(u32, 1), f.is_centered);
        try std.testing.expectEqual(@as(f64, 450), f.shown_w);
        try std.testing.expectEqual(@as(f64, 360), f.shown_h);
        try std.testing.expectEqual(@as(f64, 275), f.shown_x); // midX - w/2 = 500-225
        try std.testing.expectEqual(@as(f64, 220), f.shown_y); // midY - h/2 = 400-180
        try std.testing.expectEqual(f.shown_x, f.hidden_x); // 페이드 — 보임=숨김
        try std.testing.expectEqual(f.shown_y, f.hidden_y);
    }
    // width 설정(0.8) → 가로 독립: w=800, 중앙 x=100.
    {
        const f = compute(.{ .position = .center, .height_fraction = 0.45, .width_fraction = 0.8 }, 0, 0, vf_w, vf_h);
        try std.testing.expectEqual(@as(f64, 800), f.shown_w);
        try std.testing.expectEqual(@as(f64, 100), f.shown_x); // 500 - 400
    }
}

test "compute: 오프셋 원점 화면(멀티 모니터 보조 디스플레이) 로컬 배치" {
    // 이 테스트가 증명하는 것: 보조 모니터처럼 visibleFrame 원점이 (0,0)이 아닌 화면에서도 사각형이 그 화면의
    // 로컬 좌표로 정확히 배치된다(x/y 오프셋 보존). 멀티 모니터에서 패널이 원점 화면으로 새거나 좌표가 밀리지
    // 않게 하는 회귀 가드 — Swift가 넘긴 대상 화면 visibleFrame 안에 그대로 앉아야 한다.
    const f = compute(.{ .position = .top, .height_fraction = 0.5 }, 1440, 100, 1000, 800);
    try std.testing.expectEqual(@as(f64, 1440), f.shown_x); // 화면 x 오프셋 보존
    try std.testing.expectEqual(@as(f64, 500), f.shown_y); // vf_y + vf_h - h = 100 + 800 - 400
    try std.testing.expectEqual(@as(f64, 400), f.shown_h);
    try std.testing.expectEqual(@as(f64, 900), f.hidden_y); // vf_y + vf_h = 100 + 800
}
