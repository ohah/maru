//! Chrome 디자인 시스템 facade(L3). **플랫폼 중립** — 컴포넌트는 semantic `ChromeDraw`만 뱉고, session을
//! `props`로만 읽으며, NativeMetalCell·Metal·CoreText·atlas를 모른다. ChromeDraw → 플랫폼 셀 lowering은
//! platform 어댑터가 소유한다(현재 `platform/macos/chrome/metal_lowering.zig` — AppSession은 호출·frame 합성만).
//! 테마 = 토큰셋이며, 사용자 진입점은 Chrome만 제공한다. legacy `tui` 표기는 셀 lowering 호환 경로의 내부 이름이다.
//!
//! 의존: chrome → (session core를 props로) → renderer 중립 계약. chrome은 pty/platform/terminal/renderer를
//! import하지 않는다(tests/boundary/imports.zig가 강제). 단일 출처: docs/layering-and-portability.md,
//! docs/chrome-strategy.md.

pub const draw = @import("chrome/draw.zig");
pub const tokens = @import("chrome/tokens.zig");
pub const props = @import("chrome/props.zig");
pub const input = @import("chrome/input.zig");
pub const ui = struct {
    /// 논리 줄 하나를 시각 행으로 나누는 랩 계산(CJK 정확). 편집기와 커밋 메시지 상자가 함께 쓴다.
    pub const visual_map = @import("chrome/ui/visual_map.zig");
    pub const layout = @import("chrome/ui/layout.zig");
    pub const style = @import("chrome/ui/style.zig");
    pub const typography = @import("chrome/ui/typography.zig");
    pub const semantics = @import("chrome/ui/semantics.zig"); // 접근성 서술자 계약(role/label/state) 단일 출처 — docs/chrome-interaction-migration.md §3
    pub const tree = @import("chrome/ui/tree.zig");
    pub const interaction = @import("chrome/ui/interaction.zig");
    pub const intent_table = @import("chrome/ui/intent_table.zig");
    pub const continuous_drag = @import("chrome/ui/continuous_drag.zig");
    pub const scroll_area = @import("chrome/ui/scroll_area.zig"); // 스크롤 컨테이너 좌표계 단일 출처 — docs/scroll-area.md
    pub const gesture = @import("chrome/ui/gesture.zig"); // 한 제스처의 뜻(탭/스크롤/길게 누름) 단일 출처 — docs/mobile-platform.md 3.1
    pub const provisional_order = @import("chrome/ui/provisional_order.zig");
    pub const paint_style = @import("chrome/ui/paint_style.zig");
    pub const paint = @import("chrome/ui/paint.zig");
    pub const icon = @import("chrome/ui/icon.zig"); // 아이콘 크기 토큰(슬롯 pt·셀 래스터 배율·run 셀 수) 단일 출처
};
pub const state = @import("chrome/state.zig");
pub const host = @import("chrome/host.zig");
pub const file_tree_icon = @import("chrome/file_tree_icon.zig");
pub const text_layout = @import("chrome/text_layout.zig"); // 텍스트 셀 배치(분절·폭·말줄임) 단일 출처 — docs/layering-and-portability.md §7.9

pub const ChromeHost = host.ChromeHost;
pub const ChromeState = state.ChromeState;
pub const ChromeDraw = draw.ChromeDraw;
pub const ChromeProps = props.ChromeProps;
pub const Tokens = tokens.Tokens;

pub const components = struct {
    pub const overlay_input = @import("chrome/components/overlay_input.zig"); // find·palette 공유 기반(컴포넌트 아님)
    pub const text_field = @import("chrome/components/text_field.zig");
    pub const text_area = @import("chrome/components/text_area.zig"); // 멀티라인 세로 축(커밋 메시지 상자 — text-field-editor.md §12) // 주소창 omnibox 인라인 편집(caret·선택·마우스) — docs/text-field-editor.md
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
    pub const dock_view_bar = @import("chrome/components/dock_view_bar.zig"); // 도크 뷰 스위처 한 행 render/hit 공용 순수 geometry
    pub const status_bar = @import("chrome/components/status_bar.zig"); // 창 바닥 상태표시줄 좌/우 슬롯 순수 배치(SB1-S3)
    /// N1: 네이티브 편집기 L3 뷰(docs/native-editor-visual-mapping.md §4.1). 본문·gutter는 셀 격자 경로이고
    /// measured 이관 대상이 아니다(§2.0) — 등폭 정렬과 폰트 크기 연동이 기능 요구다.
    pub const editor_view = struct {
        pub const geometry = @import("chrome/components/editor_view/geometry.zig");
        pub const gutter = @import("chrome/components/editor_view/gutter.zig");
        pub const content = @import("chrome/components/editor_view/content.zig");
        /// 구문 스팬 → 줄별 색 구간. **역할이 이미 정해진 채로** 들어온다(캡처 이름 → 역할은
        /// `maru.syntax_colors` 가 잇는다 — chrome 은 session 을 안 본다).
        pub const syntax_colors = @import("chrome/components/editor_view/syntax_colors.zig");
        pub const viewport = @import("chrome/components/editor_view/viewport.zig");
        pub const hit = @import("chrome/components/editor_view/hit.zig"); // 화면 좌표 → (행·논리 줄·줄 안 byte). 플랫폼이 굳힌 기하만 대 준다
        pub const selection_marks = @import("chrome/components/editor_view/selection_marks.zig"); // 문서 offset 선택 → 행마다의 Mark. 축(행→문서 줄)은 호출자가 푼다
        /// **`ui/visual_map`으로 옮겼다**(커밋 메시지 상자가 두 번째 소비자가 되면서 — docs/text-field-editor.md
        /// §12.4). 랩은 편집기 전용 개념이 아니라 공용 텍스트 레이아웃이고, `components/editor_view/`에 두면
        /// 그 디렉터리가 "편집기 뷰 것"이라고 하는 선언이 거짓이 된다. 이 별칭은 기존 호출부를 위해 남긴다.
        pub const visual_map = ui.visual_map;
        pub const scrollbar = @import("chrome/components/editor_view/scrollbar.zig");
        pub const surface = @import("chrome/components/editor_view/surface.zig");
        pub const frame = @import("chrome/components/editor_view/frame.zig"); // 위 넷의 조립 — Lab과 제품이 같은 순서·저장소 규칙을 쓴다
        pub const diff_frame = @import("chrome/components/editor_view/diff_frame.zig"); // 나란한 비교 — `frame`을 두 번 부르는 조합(§7)
    };
    pub const session_dock = @import("chrome/components/session_dock.zig"); // archive session dock typed layout/action/view facade
    pub const scm_dock = @import("chrome/components/scm_dock.zig"); // 소스 컨트롤 도크 typed layout/action/view facade(도크 2판)
    pub const archive_detail = @import("chrome/components/archive_detail.zig"); // redacted archive detail typed layout/action/view facade
    pub const file_tree = @import("chrome/components/file_tree.zig"); // 파일 탐색기 트리 행 typed layout/view facade(FT1)
};

test {
    // 자식 파일 테스트를 빌드에 집계한다(app.zig와 같은 관용구 — refAllDecls는 한 단계라, 네임스페이스로
    // 감싼 components의 자식도 별도로 ref한다).
    const testing = @import("std").testing;
    testing.refAllDecls(@This());
    // **`ui` 도 별도로 ref 한다.** `refAllDecls` 는 한 단계라 `ui` 자체만 닿고 그 자식은
    // **다른 코드가 우연히 참조할 때만** 집계에 들어온다 — 소비처가 아직 없는 새 컴포넌트는
    // 테스트를 써 놔도 CI 에서 안 돈다(`gesture` 가 실제로 그랬다: 12개가 집계 밖이었고
    // 변이 검사가 `zig test <파일>` 로 직접 돌렸을 때만 잡혔다).
    testing.refAllDecls(ui);
    testing.refAllDecls(components);
    testing.refAllDecls(components.editor_view);
}
