//! 소스 컨트롤 도크의 frame-local action 표.
//!
//! 포인터 히트테스트는 `UiActionId`만 돌려주고, 이 표가 그 ID에 도메인 의미를 다시 붙인다 — 그래야
//! 일반 interaction 계층이 git이나 행 인덱스를 알 필요가 없다(Session Dock과 같은 구조).

const intent_table = @import("../../ui/intent_table.zig");
const types = @import("types.zig");

pub const Intent = union(enum) {
    /// 그룹 헤더 클릭 = 접기/펴기.
    toggle_section: types.Section,
    /// 그 그룹의 일괄 동작(`모두 스테이지`/`모두 언스테이지`). **무엇을 할지는 host가 현재 상태로
    /// 다시 정한다** — intent가 방향까지 실으면 published tree와 host 상태가 어긋날 수 있다.
    section_action: types.Section,
    /// "모두 보기" — 그 그룹만 전부 편다.
    expand_section: types.Section,
    /// 행 클릭 = 그 비교 열기. **인덱스는 화면 창(virtualized window) 기준이 아니라 모델 인덱스**다 —
    /// host가 같은 스냅샷 세대의 모델에서 그 행을 다시 찾는다.
    open_row: u32,
    /// 행 호버의 `+`/`−`. 어느 방향인지는 그 행이 선 그룹이 정하므로 여기서는 행만 가리킨다.
    row_action: u32,
    /// 스크롤바. 목표 offset은 포인터 좌표의 함수라 intent에 실을 수 없다 — host가 같은 published
    /// 기하로 좌표를 offset으로 바꾼다.
    scroll_thumb,
    scroll_track,
};

pub const Table = intent_table.IntentTable(Intent);
pub const Entry = Table.Entry;
