//! action 번호는 공유 표가 발급한다. 인덱스는 세대 검증 뒤에만 해석한다.
pub const Intent = union(enum) { navigate: usize, toggle: usize };
pub const Table = @import("../../ui/intent_table.zig").IntentTable(Intent);
pub const Entry = Table.Entry;
