//! Chrome 디자인 시스템 facade(L3). **플랫폼 중립** — 컴포넌트는 semantic `ChromeDraw`만 뱉고, session을
//! `props`로만 읽으며, NativeMetalCell·Metal·CoreText·atlas를 모른다. ChromeDraw → 플랫폼 셀 lowering은
//! platform 어댑터(예: platform/macos/chrome_tui_backend)가 소유한다. 테마 = 토큰셋(tui|rich, 컴포넌트 불변).
//!
//! 의존: chrome → (session core를 props로) → renderer 중립 계약. chrome은 pty/platform/terminal/renderer를
//! import하지 않는다(tests/boundary/imports.zig가 강제). 단일 출처: docs/layering-and-portability.md,
//! docs/chrome-strategy.md.

pub const draw = @import("chrome/draw.zig");
pub const tokens = @import("chrome/tokens.zig");
pub const props = @import("chrome/props.zig");
pub const input = @import("chrome/input.zig");
pub const state = @import("chrome/state.zig");
pub const host = @import("chrome/host.zig");

pub const ChromeHost = host.ChromeHost;
pub const ChromeState = state.ChromeState;
pub const ChromeDraw = draw.ChromeDraw;
pub const ChromeProps = props.ChromeProps;
pub const Tokens = tokens.Tokens;

pub const components = struct {
    pub const overlay_input = @import("chrome/components/overlay_input.zig"); // find·palette 공유 기반(컴포넌트 아님)
    pub const notice = @import("chrome/components/notice.zig");
    pub const find = @import("chrome/components/find.zig");
    pub const palette = @import("chrome/components/palette.zig");
    pub const divider = @import("chrome/components/divider.zig"); // 마우스 hit-test 컴포넌트(State 없는 순수 함수)
    pub const sidebar = @import("chrome/components/sidebar.zig"); // 마우스 hit-test 컴포넌트(워크스페이스 사이드바)
    pub const tabbar = @import("chrome/components/tabbar.zig"); // 마우스 hit-test 컴포넌트(pane 탭 바)
};

test {
    // 자식 파일 테스트를 빌드에 집계한다(app.zig와 같은 관용구 — refAllDecls는 한 단계라, 네임스페이스로
    // 감싼 components의 자식도 별도로 ref한다).
    const testing = @import("std").testing;
    testing.refAllDecls(@This());
    testing.refAllDecls(components);
}
