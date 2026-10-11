//! `session/screen_assembler.zig` 의 판정자만 고르기 위한 얇은 루트(이미지 채널 IC3a).
//!
//! 그 파일을 직접 테스트 루트로 걸면 모듈 경로가 `src/session/` 이 되어 `../image_reconciliation.zig` 상대 import 가 모듈 밖이
//! 된다. `session.zig` 를 루트로 걸면 거기서 닿는 이름 없는 참조 테스트(`test { _ = … }`)가 필터와 무관하게 함께 컴파일되어,
//! 무관한 파일에 참조 테스트 하나가 늘 때마다 개수 가드가 깨진다. 여기서 가져오면 모듈 루트가 `src/` 이고 이름 없는 테스트는
//! 이 파일의 하나뿐이다.

test {
    _ = @import("session/screen_assembler.zig");
}
