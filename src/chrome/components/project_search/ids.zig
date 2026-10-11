//! 숫자 action은 세대 표를 통해서만 입력 의도로 복원한다.
pub const Intent = union(enum) { field: usize, option: usize, run, cancel, retry_save: usize, toggle_selection: usize, row: usize };
pub const Table = @import("../../ui/intent_table.zig").IntentTable(Intent);
pub const Entry = Table.Entry;
