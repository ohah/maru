//! CEF C API 헤더(W1b). 헤더는 저장소에 없다 — 빌드가 `-Dcef-sdk` 로 받은 SDK 의 include 를 넘긴다(프로젝트 규칙
//! 예외 ③). 여기서는 **타입만** 쓴다: 함수는 링크하지 않고 `library.zig` 가 dlopen 한 프레임워크에서 찾는다.

pub const c = @cImport({
    // SDK 가 고정한 API 버전(154.0.23). 첫 `cef_api_hash` 호출이 이 값을 라이브러리에 등록한다.
    @cDefine("CEF_API_VERSION", "15400");
    @cInclude("include/cef_api_hash.h");
    @cInclude("include/capi/cef_app_capi.h");
    @cInclude("include/capi/cef_command_line_capi.h");
    @cInclude("include/capi/cef_task_capi.h");
});

pub const api_version: c_int = 15400;
