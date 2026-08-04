//! Frame-local action table for Session Dock.
//!
//! Pointer hit testing returns only `UiActionId`; this table is the deliberate second half that
//! restores domain meaning without teaching the generic UI interaction layer about archive records.

const intent_table = @import("../../ui/intent_table.zig");
const types = @import("types.zig");

pub const Intent = union(enum) {
    refresh,
    scope: types.Scope,
    focus_search,
    toggle_group: u64,
    select_card: u64,
    resume_session,
    reveal_log,
    focus_live,
};

/// 표 자체는 generic이다(`ui/intent_table.zig`). 이 파일이 소유하는 것은 **어떤 intent가 있는가**
/// 하나뿐이며, ID 발급·세대 검증·disabled 거부는 공용 구현이 한 곳에서 한다.
pub const Table = intent_table.IntentTable(Intent);
pub const Entry = Table.Entry;
