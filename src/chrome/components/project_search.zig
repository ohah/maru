//! 프로젝트 검색 도크의 표시·입력 기하. 문서와 파일 I/O는 연결하지 않는다.
pub const types = @import("project_search/types.zig");
pub const ids = @import("project_search/ids.zig");
pub const build = @import("project_search/build.zig");
pub const view = @import("project_search/view.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("project_search/tests.zig");
}
