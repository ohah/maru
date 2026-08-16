//! Session Dock의 frame-local action table이다.
//!
//! pointer hit test는 `UiActionId`만 돌려준다. 이 표는 그 짝이 되는 나머지 절반으로, 범용 UI
//! interaction 층에 archive record를 가르치지 않고도 도메인 의미를 되살린다.

const intent_table = @import("../../ui/intent_table.zig");
const types = @import("types.zig");

pub const Intent = union(enum) {
    refresh,
    scope: types.Scope,
    /// 정렬 방향을 뒤집는다. 어느 방향으로 갈지는 intent가 아니라 host의 현재 상태가 정한다 — 두 곳이
    /// 방향을 알면 published tree와 host 상태가 어긋날 수 있다.
    toggle_sort,
    focus_search,
    toggle_group: u64,
    select_card: u64,
    resume_session,
    reveal_log,
    focus_live,
    /// Scrollbar thumb/track. 목표 offset은 pointer 좌표의 함수이므로 intent에 실을 수 없다 —
    /// host가 같은 published 기하로 좌표를 offset으로 바꾼다. 이 intent가 하는 일은 "눌린 곳이
    /// 스크롤바의 어느 부분인가"를 알리는 것뿐이다.
    scroll_thumb,
    scroll_track,
};

/// 표 자체는 generic이다(`ui/intent_table.zig`). 이 파일이 소유하는 것은 **어떤 intent가 있는가**
/// 하나뿐이며, ID 발급·세대 검증·disabled 거부는 공용 구현이 한 곳에서 한다.
pub const Table = intent_table.IntentTable(Intent);
pub const Entry = Table.Entry;
