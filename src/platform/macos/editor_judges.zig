//! **편집기 판정자만 모으는 진입점** — `zig build test-editor`가 이 파일을 뿌리로 삼는다.
//!
//! `zig build test`는 3,995개를 전부 돌려 20~30분이 걸리는데 그 대부분은 소켓·프로세스·타임아웃을
//! 실제로 쓰는 `session_host` 계열이다. 편집기를 고치는 동안 매번 그것을 기다리면 적대적 검증이
//! 사실상 막힌다 — 뮤턴트 하나 판정에 20분이 들었다(2026-08-25).
//!
//! **`app_session.zig`에 필터를 걸어서는 안 됐다.** `const editor_ops = @import(...)`는 참조되지
//! 않으면 분석되지 않고, 그러면 그 파일의 판정자가 **애초에 바이너리에 없다.** 실제로 `EDIT6`
//! 필터가 0개를 고르고도 `exit=0`으로 통과했다 — **거짓 초록**이다. 그래서 필터가 아니라
//! **import로** 끌어온다: 여기 적힌 파일의 판정자는 반드시 컴파일된다.
//!
//! **`test`를 대신하지 않는다.** 합류 전에는 `mise run check`가 전부 돈다.
//!
//! **구문 트리 판정자(`TS*`)는 여기 없다.** `src/syntax/`는 별도 모듈이라 이 파일의 모듈 경로
//! 밖이고(`error: import of file outside module path`), 설령 모듈 이름으로 들여와도 `zig test`는
//! **루트 모듈의 test만** 싣는다 — `LANG`이 그렇게 0개를 돌았다. `build.zig`가 그 모듈을 뿌리로
//! 하는 실행을 따로 걸어 `test-editor`에 매단다.

test {
    _ = @import("app_session/editor.zig");
    _ = @import("app_session/editor_syntax.zig");
    _ = @import("app_session/editor_diff.zig");
    _ = @import("symbol_picker.zig");
}
