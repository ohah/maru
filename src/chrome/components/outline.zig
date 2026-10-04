//! 활성 문서의 계층 목록. 문서·플랫폼을 몰라도 같은 tree로 그리기와 입력을 판정한다.
pub const types = @import("outline/types.zig");
pub const ids = @import("outline/ids.zig");
pub const build = @import("outline/build.zig");
pub const view = @import("outline/view.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("outline/tests.zig");
}
