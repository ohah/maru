//! W9d③ 7 차 적대 검증(A7 — 2baa301cd 를 친 판)의 순수 탐침: 메서드 이름 꼴로 읽기 목록을 지나 Chromium 에서 다른 메서드(특히
//! `Runtime.getProperties`)로 처리되게 할 수 있는가. 브라우저 탭에서 중요한 이유: 읽기 목록은 사용자의 이동 토큰을 남기는 유일한 문이라,
//! 이름 꼴 하나가 그 문을 지나 페이지 스크립트를 돌리면 토큰을 거두지 않은 채 페이지가 이동을 시작할 수 있다.
//! 7 차 고침(LOW-1)의 단언도 여기 둔다 — 건너뛴 하위 트리의 스타일·배치를 강제하는 둘은 목록 밖, maru 의 흐름이 쓰는 읽기는 목록 안.

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const msg = protocol.message;
const fields = protocol.fields;
const codec = protocol.codec;
const dt = @import("devtools_table.zig");
const testing = std.testing;

fn inList(m: []const u8) bool {
    for (dt.read_only_methods) |x| if (std.mem.eql(u8, x, m)) return true;
    return false;
}

test "A7-name: getProperties 의 이름 꼴(대소문자·앞뒤 공백·NUL·유니코드 동형·매우 긴 이름)은 wire 가 거절하거나, 지나도 읽기 목록 밖이라 거둔다" {
    const gpa = testing.allocator;
    const long = "Runtime.getProperties" ++ "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; // 128 B — wire 상한 안
    const too_long = "Runtime.getProperties" ++ "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; // 129 B
    const forms = [_][]const u8{
        "runtime.getProperties",  "Runtime.GetProperties",  "Runtime.getproperties",     "RUNTIME.GETPROPERTIES",
        " Runtime.getProperties", "Runtime.getProperties ", "Runtime.getProperties\x00", "\x00Runtime.getProperties",
        "Runtime.getPropertie\xd1\x95", // Cyrillic ѕ
        "Runtime\xe2\x80\xa4getProperties", // ONE DOT LEADER
        "Runtime.getProperties.",
        ".Runtime.getProperties",
        "Runtime..getProperties",
        "Runtime.getProperties\t",
        "Runtime.getProperties\"",
        long,
        too_long,
    };
    var wire_ok: usize = 0;
    for (forms) |m| {
        const valid = if (fields.checkDevtoolsMethod(m)) |_| true else |_| false;
        if (valid) {
            wire_ok += 1;
            // wire 를 지나는 꼴은 영숫자와 `.` 뿐 — 목록과 바이트가 같지 않으면 거둔다(Chromium 의 이름 찾기도 바이트 비교다).
            try testing.expect(!inList(m));
            try testing.expect(dt.startsNavigationCall(gpa, m, "{\"objectId\":\"1\"}"));
        } else {
            // 거절되는 꼴은 codec 의 decode 도 거절한다(인코드한 frame 을 손으로 만들 수 없다 — encode 도 같은 검사).
            var buf: [512]u8 = undefined;
            const enc = codec.encode(.{ .devtools_call = .{ .browser = 1, .call = 1, .method = m, .params_size = 0 } }, &buf);
            try testing.expect(std.meta.isError(enc));
        }
    }
    // 대소문자 넷·`..`·긴 이름(128) 만 wire 를 지난다 — 모두 목록 밖이다.
    try testing.expectEqual(@as(usize, 6), wire_ok);
    // 손으로 만든 frame(인코드한 뒤 이름 바이트를 공백·NUL·0x80 으로 바꾼다)도 decode 가 거절한다 — sidecar 의 검사 앞에서 끊긴다.
    var fb: [512]u8 = undefined;
    const name = "Runtime.getPropertiesZ";
    const len = try codec.encode(.{ .devtools_call = .{ .browser = 1, .call = 1, .method = name, .params_size = 0 } }, &fb);
    const at = std.mem.indexOf(u8, fb[0..len], name).?;
    _ = try codec.decodeExact(fb[0..len]);
    for ([_]u8{ ' ', 0, 0x80, '"', '\\' }) |bad| {
        var copy = fb;
        copy[at + name.len - 1] = bad;
        try testing.expect(std.meta.isError(codec.decodeExact(copy[0..len])));
    }
}

test "A7-name: 목록의 28 개 각각 — 한 글자 대소문자만 바꾼 꼴·잘린 꼴·덧붙인 꼴은 모두 거둔다(목록의 다른 이름과 겹치지 않는다)" {
    // 7 차 고침으로 30 → 28(`DOM.getBoxModel`·`CSS.getComputedStyleForNode` 를 뺐다 — 아래 `A7-R1 LOW-1 고침`).
    try testing.expectEqual(@as(usize, 28), dt.read_only_methods.len);
    var buf: [msg.max_devtools_method_bytes]u8 = undefined;
    var n_forms: usize = 0;
    for (dt.read_only_methods) |m| {
        for (0..m.len) |i| {
            if (!std.ascii.isAlphabetic(m[i])) continue;
            @memcpy(buf[0..m.len], m);
            buf[i] = if (std.ascii.isUpper(m[i])) std.ascii.toLower(m[i]) else std.ascii.toUpper(m[i]);
            try testing.expect(dt.startsNavigation(buf[0..m.len]));
            n_forms += 1;
        }
        try testing.expect(dt.startsNavigation(m[0 .. m.len - 1]));
        @memcpy(buf[0..m.len], m);
        buf[m.len] = 'X';
        try testing.expect(dt.startsNavigation(buf[0 .. m.len + 1]));
    }
    try testing.expect(n_forms > 500);
}

test "A7-quality: getProperties 를 목록에 되돌리는 변이를 A6 의 순수 단언이 잡는가 — 목록 안의 Runtime 메서드는 정확히 셋" {
    var runtime: usize = 0;
    for (dt.read_only_methods) |m| {
        if (std.mem.startsWith(u8, m, "Runtime.")) runtime += 1;
        // 값의 설명을 만드는 다른 Runtime 메서드(이름 꼴로)도 없다.
        try testing.expect(std.mem.indexOf(u8, m, "Propert") == null);
        try testing.expect(std.mem.indexOf(u8, m, "evaluate") == null);
        try testing.expect(std.mem.indexOf(u8, m, "callFunction") == null);
    }
    try testing.expectEqual(@as(usize, 3), runtime);
}

// 7 차 검증 LOW-1: `DOM.getBoxModel` 이 `content-visibility:hidden` 하위 트리의 스타일·배치를 강제해 그 안의 글꼴·그림·`<object>` 를 요청하고 페이지의
// fonts·onload·PerformanceObserver 처리기를 돌렸다(실측 +10 2/2). 같은 갈래를 목록의 다른 메서드에 쟀더니 `CSS.getComputedStyleForNode` 도 +10 —
// 둘 다 뺐다(실제 CEF 판정 `A7-R1-read-list-token`·`A7-R1b-read-list-skipped-subtree`). 브라우저 탭에서 중요한 이유: 목록 안의 호출은 사용자의 이동
// 토큰을 남기므로, 처리기를 돌리는 호출이 남아 있으면 그 처리기가 토큰이 살아 있는 동안 이동을 시작할 수 있다.
test "A7-R1 LOW-1 고침: 건너뛴 하위 트리를 강제하는 둘은 읽기 목록 밖(인자와 무관하게 거둔다) — maru 의 흐름이 쓰는 읽기는 그대로 목록 안" {
    const gpa = testing.allocator;
    for ([_][]const u8{ "DOM.getBoxModel", "CSS.getComputedStyleForNode" }) |m| {
        try testing.expect(!inList(m));
        for ([_][]const u8{ "", "{}", "{\"nodeId\":15}", "{\"backendNodeId\":3}", "{\"objectId\":\"1\"}" }) |p|
            try testing.expect(dt.startsNavigationCall(gpa, m, p));
    }
    // 대가의 경계: maru 의 흐름(web_cdp_ops·web_cdp_snapshot·web_cdp_locate·web_cdp_page·web_osr 의 kick)이 보내는 읽기는 목록에 남아 사용자 토큰을
    // 거두지 않는다 — 이것이 빠지면 사용자 이동이 더 자주 막힌다(사용자 결정이 필요한 변경).
    for ([_][]const u8{
        "DOM.getContentQuads",        "DOM.describeNode",          "DOM.getDocument",             "DOM.querySelector",
        "DOM.resolveNode",            "Accessibility.queryAXTree", "Accessibility.getFullAXTree", "Page.getLayoutMetrics",
        "Page.captureScreenshot",     "Page.getFrameTree",         "Page.getNavigationHistory",   "Runtime.releaseObjectGroup",
        "Runtime.terminateExecution", "Network.getCookies",
    }) |m| try testing.expect(inList(m));
    try testing.expect(!dt.startsNavigationCall(gpa, msg.devtools_kick_method, msg.devtools_kick_params));
    // 7 차 LOW-3: 놓기(maru 의 정리)는 남는다 — GC 뒤 FinalizationRegistry 콜백은 문서화된 틈이다.
    try testing.expect(inList("Runtime.releaseObject"));
}
