//! typed Chrome UI namespace만 좁혀서 도는 test root다.
//!
//! 제품 `chrome.zig` facade는 의도적으로 모든 Chrome component를 import한다. 이 build entrypoint를
//! 따로 두면 `zig build test-chrome-ui`가 자식 모듈 import를 실제 `src/` 경계에서 풀면서도 build →
//! layout → interaction → paint seam만 증명한다.

const layout = @import("chrome/ui/layout.zig");
const style = @import("chrome/ui/style.zig");
const tree = @import("chrome/ui/tree.zig");
const ui_button = @import("chrome/ui/button.zig");
const ui_badge = @import("chrome/ui/badge.zig");
const interaction = @import("chrome/ui/interaction.zig");
const intent_table = @import("chrome/ui/intent_table.zig");
const continuous_drag = @import("chrome/ui/continuous_drag.zig");
const provisional_order = @import("chrome/ui/provisional_order.zig");
const paint_style = @import("chrome/ui/paint_style.zig");
const paint = @import("chrome/ui/paint.zig");
const divider = @import("chrome/components/divider.zig");
// pane 탭 바 hit-test(§5.4 "보이는 탭 = 클릭되는 탭")도 이 seam 위에 있다. 빠져 있는 동안 스크롤된
// 탭 바에서 **어떤 탭을 눌러도 탭 0 이 열리는** 회귀가 이 게이트를 초록으로 통과했다(2026-08-18).
const tabbar = @import("chrome/components/tabbar.zig");
const session_dock = @import("chrome/components/session_dock.zig");
const archive_detail = @import("chrome/components/archive_detail.zig");
// 소스 컨트롤 도크도 이 seam 위에 있다. 여기에 없으면 `test-chrome-ui`가 초록인 채로 그 컴포넌트의
// 예산·기하 회귀가 통과한다 — 실제로 그 상태에서 빈 저장소 도크가 통째로 사라졌다(2026-08-16).
const scm_dock_build = @import("chrome/components/scm_dock/build.zig");
const scm_dock_view = @import("chrome/components/scm_dock/view.zig");

test {
    // `refAllDecls` is intentionally explicit: imports alone do not make this focused artifact's
    // scope obvious to a reader, and each namespace owns the tests for its one responsibility.
    const testing = @import("std").testing;
    testing.refAllDecls(layout);
    testing.refAllDecls(ui_button);
    testing.refAllDecls(ui_badge);
    testing.refAllDecls(style);
    testing.refAllDecls(tree);
    testing.refAllDecls(interaction);
    testing.refAllDecls(intent_table);
    testing.refAllDecls(continuous_drag);
    testing.refAllDecls(provisional_order);
    testing.refAllDecls(divider);
    testing.refAllDecls(tabbar);
    testing.refAllDecls(paint_style);
    testing.refAllDecls(paint);
    testing.refAllDecls(session_dock);
    testing.refAllDecls(archive_detail);
    testing.refAllDecls(scm_dock_build);
    testing.refAllDecls(scm_dock_view);
}
