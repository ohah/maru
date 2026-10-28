//! 파싱 실행 모듈의 진입점. 뷰 구문 상태까지 같은 editor 루트 안에서 참조한다.
pub const dispatch = @import("parse/dispatch.zig");
