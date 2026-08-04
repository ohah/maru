//! Opaque action identities for ArchiveSessionDetailPanel.

const intent_table = @import("../../ui/intent_table.zig");

pub const Intent = enum { resume_session, reveal_log, focus_live };

/// 표 자체는 generic이다(`ui/intent_table.zig`). 이 파일이 소유하는 것은 **어떤 intent가 있는가**
/// 하나뿐이며, ID 발급·세대 검증·disabled 거부는 공용 구현이 한 곳에서 한다.
pub const Table = intent_table.IntentTable(Intent);
pub const Entry = Table.Entry;
