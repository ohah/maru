//! `platform/macos/chrome/system_text.zig` 를 **Windows 에서 컴파일하고 실행**하기 위한 얇은 루트.
//!
//! 그 파일을 직접 테스트 루트로 걸면 모듈 경로가 `src/platform/macos/chrome/` 이 되어 `../../../*.zig`
//! 상대 import 가 모듈 밖이 된다(`win32_process_test_root.zig` 와 같은 이유). 여기서 가져오면 모듈
//! 루트가 `src/` 다.
//!
//! **왜 별도 스텝인가.** 이 파일의 macOS 테스트들은 CoreText 를 링크하는 아티팩트 안에 있어서
//! Windows 에서는 하나도 안 돈다 — 이음매 배선이 컴파일만 되고 **실행된 적이 없는** 상태가 된다.

test {
    _ = @import("platform/macos/chrome/system_text.zig");
}
