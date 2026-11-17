//! 페이지 찾기의 답(P0-2 — docs/plans/web-osr-backend.md P0-2). CEF 의 찾기 처리기(`cef_find_handler_t.on_find_result`, UI 스레드)가
//! 부른다. 이 파일은 CEF 콜백을 받아 순수 규칙(`protocol.find.Session.accept` — 지금 부름의 identifier 인가, 값 정리, 되풀이 거르기)에
//! 넘기고 남은 답만 `find_result` 로 보낸다. 명령(`find`·`find_stop`)은 `browsers.zig` 가 처리한다.

const protocol = @import("web_sidecar_protocol");
const c = @import("cef.zig").c;
const object = @import("object.zig");
const browsers = @import("browsers.zig");

/// `find_handler.on_find_result` — 선택 사각형(창 좌표)은 쓰지 않는다(maru 의 오버레이는 수와 차례만 그린다).
pub fn onFindResult(
    _: [*c]c.cef_find_handler_t,
    browser: [*c]c.cef_browser_t,
    identifier: c_int,
    count: c_int,
    _: [*c]const c.cef_rect_t,
    active: c_int,
    final: c_int,
) callconv(.c) void {
    defer object.releaseArg(browser);
    if (browser == null) return;
    const entry = browsers.state.registry.byCefId(browser.*.get_identifier.?(browser)) orelse return;
    if (entry.closing) return;
    const reply = entry.find.accept(&browsers.state.find_counter, identifier, count, active, final != 0) orelse return;
    browsers.state.writer.send(.{ .find_result = protocol.find.resultMessage(entry.id, reply) }) catch {};
}
