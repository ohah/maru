//! 파싱 runtime의 테스트 진입점. editor 루트 안의 뷰 상태를 상대 import할 수 있게 한다.
comptime {
    _ = @import("parse/judges.zig");
}
