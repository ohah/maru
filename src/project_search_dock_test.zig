//! 프로젝트 검색 표시 모델과 실제 도크 컴포넌트를 함께 검사한다.
test {
    _ = @import("session/editor/search/presentation.zig");
    _ = @import("session/editor/search/results.zig");
    _ = @import("chrome/components/project_search/tests.zig");
}
