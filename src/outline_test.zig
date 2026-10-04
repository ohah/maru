//! 아웃라인의 중립 모델과 실제 Chrome 컴포넌트 판정자를 함께 실행하는 빠른 입구다.
test {
    _ = @import("session/editor/outline.zig");
    _ = @import("chrome/components/outline/tests.zig");
}
