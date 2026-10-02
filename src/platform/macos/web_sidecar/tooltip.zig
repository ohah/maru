//! 페이지 툴팁(W6b — HTML `title`, docs/plans/web-osr-backend.md W6). CEF 는 창 없는 모드에서 툴팁을 그리지 않고 글만
//! 넘긴다 — sidecar 는 그 글을 정리해 `tooltip_changed` 로 보내고, maru 는 macOS 의 툴팁으로 띄운다(지연·위치·모양은
//! macOS 가 정한다 — Mac 의 Chrome 과 같다, 실측).
//!
//! 규칙(실측에서): CEF 는 요소에 들어오면 곧바로(지연 없이) 글을, 요소 안에서 움직일 때마다 같은 글을 다시, 요소를 떠나거나
//! 포인터가 view 를 떠나면 빈 글을 부른다. 누름에는 부르지 않는다. 포인터를 멈춘 채 페이지가 `title` 을 바꾸거나
//! `pushState` 를 하거나 새 문서로 옮겨 가도 부르지 않는다 — 다음 움직임에 같은 글을 다시 부른다.
//! - 연달아 같은 글은 보내지 않는다(빈 글도 값이다).
//! - 새 문서를 불러오기 시작할 때·주 프레임 이동이 실패해 오류 페이지가 될 때·포인터가 떠날 때 기억한 글을 비우고, 비어 있지 않았으면 빈 글을 한 번 보낸다 — 그래야 새
//!   페이지의 같은 글이 다음 움직임에 다시 오고(실측: 새 문서는 옛 글과 같은 글을 다시 보냈다), 옛 페이지의 툴팁이 남지 않는다.
//! - 같은 문서 안에서 주소만 바뀔 때(`pushState`·`replaceState`·해시)는 비우지 않는다 — 포인터 아래 요소는 그대로라 툴팁도
//!   그대로다. 비우면 1 초마다 `replaceState` 하는 페이지(영상 시각 등)에서 첫 표시 지연(약 1.55 초)을 못 넘겨 툴팁이 영영 안
//!   뜬다(W6b 적대 검증). Chrome 에서 이 경우는 재지 않았다.

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const c = @import("cef.zig").c;
const object = @import("object.zig");
const library = @import("library.zig");
const browsers = @import("browsers.zig");
const registry_mod = @import("registry.zig");

const BrowserId = protocol.message.BrowserId;

/// `display.on_tooltip` — 글을 정리해(제어 문자 → 공백, 4 KiB 안 UTF-8, CRLF·CR → LF) 바뀌었으면 보낸다. 1 을 돌려준다
/// (창 없는 모드에서는 돌려준 값을 보지 않는다 — CEF 헤더).
pub fn onTooltip(_: [*c]c.cef_display_handler_t, browser: [*c]c.cef_browser_t, text: [*c]c.cef_string_t) callconv(.c) c_int {
    defer object.releaseArg(browser);
    if (browser == null) return 1;
    const entry = browsers.state.registry.byCefId(browser.*.get_identifier.?(browser)) orelse return 1;
    if (entry.closing) return 1;
    var buf: [protocol.wire.max_text_bytes]u8 = undefined;
    const read = library.readDialogString(browsers.state.api, text, &buf);
    const len = protocol.text.normalizeNewlines(buf[0..read.len]);
    offer(entry, buf[0..len]);
    return 1;
}

fn offer(entry: *registry_mod.Entry, text: []const u8) void {
    const hash = std.hash.Wyhash.hash(0, text);
    const nonempty = text.len != 0;
    if (nonempty == entry.tooltip_nonempty and (!nonempty or hash == entry.tooltip_hash)) return;
    entry.tooltip_hash = hash;
    entry.tooltip_nonempty = nonempty;
    browsers.state.writer.send(.{ .tooltip_changed = .{ .browser = entry.id, .text = text } }) catch {};
}

/// 기억한 글을 비운다 — 비어 있지 않았으면 빈 글을 한 번 보낸다(새 문서·오류 페이지·포인터 떠남).
pub fn reset(id: BrowserId) void {
    const entry = browsers.state.registry.byId(id) orelse return;
    offer(entry, "");
}
