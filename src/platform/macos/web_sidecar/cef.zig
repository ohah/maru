//! CEF C API 헤더(W1b). 헤더는 저장소에 없다 — 빌드가 `-Dcef-sdk` 로 받은 SDK 의 include 를 넘긴다(프로젝트 규칙
//! 예외 ⑤). 여기서는 **타입만** 쓴다: 함수는 링크하지 않고 `library.zig` 가 dlopen 한 프레임워크에서 찾는다.

pub const c = @import("cef_c");

pub const api_version: c_int = 15400;
