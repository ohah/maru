//! 제품 설정(W1c) — 프로필 설정 중 sidecar 가 늘 정하는 값. `cef_initialize` 뒤, 브라우저를 만들기 전에 UI 스레드에서
//! 한 번 넣는다.
//!
//! **인쇄를 끈다**: 창 없는 브라우저라도 `window.print()` 의 기본 동작은 네이티브 인쇄 창이고, 그 창이 뜬 host 는 종료
//! 요청에도 끝나지 않았다(적대 검증 — 사용자 제스처 없이 페이지가 스스로 연다). 인쇄 처리기(`get_print_handler`)는
//! Linux 전용이라 macOS 에서는 설정으로 막는다. maru 가 인쇄를 다루게 되면 이 값을 푼다.

const std = @import("std");
const c = @import("cef.zig").c;
const object = @import("object.zig");
const library = @import("library.zig");

const Preference = struct { name: []const u8, value: bool };

pub const product = [_]Preference{
    .{ .name = "printing.enabled", .value = false },
};

/// 넣지 못한 설정의 수를 돌려준다(호출자가 알린다 — 설정 하나 때문에 브라우저를 막지는 않는다).
pub fn apply(api: *const library.Api) usize {
    const context = api.request_context_get_global_context();
    if (context == null) return product.len;
    const manager: *c.cef_preference_manager_t = &context.*.base;
    // request context 의 참조 카운트는 두 겹 아래(preference manager → base)에 있다.
    defer _ = manager.base.release.?(&manager.base);
    var failed: usize = 0;
    for (product) |pref| {
        const value = api.value_create();
        if (value == null) {
            failed += 1;
            continue;
        }
        // 넘긴 값의 참조는 CEF 로 옮겨 간다(object.zig) — 넘긴 뒤 풀지 않는다.
        _ = value.*.set_bool.?(value, @intFromBool(pref.value));
        var name = std.mem.zeroes(c.cef_string_t);
        library.setString(api, &name, pref.name);
        defer api.string_utf16_clear(&name);
        var err = std.mem.zeroes(c.cef_string_t);
        defer api.string_utf16_clear(&err);
        if (manager.set_preference.?(manager, &name, value, &err) == 0) {
            var buf: [256]u8 = undefined;
            std.debug.print("maru-web-host: cannot set {s}: {s}\n", .{ pref.name, library.readString(api, &err, &buf) });
            failed += 1;
        }
    }
    return failed;
}
