//! Chrome 디자인 시스템 facade(L3). **플랫폼 중립** — 컴포넌트는 semantic `ChromeDraw`만 뱉고, session을
//! `props`로만 읽으며, NativeMetalCell·Metal·CoreText·atlas를 모른다. ChromeDraw → 플랫폼 셀 lowering은
//! platform 어댑터가 소유한다(현재 app_session.zig의 rasterizeOverlayCells — 별도 chrome_tui_backend 분리는
//! docs/chrome-strategy.md §5.3의 계획). 테마 = 토큰셋(tui|rich, 컴포넌트 불변).
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
    pub const text_field = @import("chrome/components/text_field.zig"); // 주소창 omnibox 인라인 편집(caret·선택·마우스) — docs/text-field-editor.md
    pub const modal_box = @import("chrome/components/modal_box.zig"); // notice·confirm 공유 박스 레이아웃/렌더(컴포넌트 아님)
    pub const notice = @import("chrome/components/notice.zig");
    pub const confirm = @import("chrome/components/confirm.zig"); // 예/아니오 확인 모달(닫기 전 실행 중 명령 확인)
    pub const find = @import("chrome/components/find.zig");
    pub const palette = @import("chrome/components/palette.zig");
    pub const divider = @import("chrome/components/divider.zig"); // 마우스 hit-test 컴포넌트(State 없는 순수 함수)
    pub const sidebar = @import("chrome/components/sidebar.zig"); // 마우스 hit-test 컴포넌트(워크스페이스 사이드바)
    pub const tabbar = @import("chrome/components/tabbar.zig"); // 마우스 hit-test 컴포넌트(pane 탭 바)
    pub const context_menu = @import("chrome/components/context_menu.zig"); // 우클릭 컨텍스트 메뉴(오버레이 모달)
    pub const notifications = @import("chrome/components/notifications.zig"); // 인앱 알림 센터 패널(2줄 카드 오버레이 모달)
    pub const toggle = @import("chrome/components/toggle.zig"); // 설정 폼 위젯 — on/off 스위치(CS-4-1, leaf 컴포넌트)
    pub const dropdown = @import("chrome/components/dropdown.zig"); // 설정 폼 위젯 — enum 드롭다운(축소 표시 + 열리는 팝업 목록)
    pub const input_box = @import("chrome/components/input_box.zig"); // 설정 폼 위젯 — 숫자 입력 박스(슬라이더 대체)
    pub const color = @import("chrome/components/color.zig"); // 설정 폼 위젯 — 색 스와치 + 16색 프리셋(CS-4-2)
    pub const settings = @import("chrome/components/settings.zig"); // schema-주도 세팅 모달(CS-4-4)
    pub const shortcut_hints = @import("chrome/components/shortcut_hints.zig"); // 모디파이어 홀드 단축키 힌트 HUD(패시브 — 입력 비소비, KH-1)
};

test {
    // 자식 파일 테스트를 빌드에 집계한다(app.zig와 같은 관용구 — refAllDecls는 한 단계라, 네임스페이스로
    // 감싼 components의 자식도 별도로 ref한다).
    const testing = @import("std").testing;
    testing.refAllDecls(@This());
    testing.refAllDecls(components);
}
