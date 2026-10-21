//! W9d③ 6 차 적대 검증(A6 — 56c752cdb 를 친 판)의 순수 탐침과 6 차 고침(getProperties 를 읽기 목록에서 뺐다)의 단언. 모형 탐침은 실측과 갈리므로
//! 모형의 답을 고정하는 시험으로 둔다(결함의 재현이 아니다).

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const nb = protocol.net_block;
const msg = protocol.message;
const table_mod = @import("net_block_table.zig");
const dt = @import("devtools_table.zig");
const sw_share = @import("sw_share.zig");
const testing = std.testing;

fn compiled(gpa: std.mem.Allocator, browser: msg.BrowserId, gen: u32, rules: []const msg.NetBlockRule) !?*table_mod.RuleSet {
    var v: msg.NetBlock = .{ .browser = browser, .generation = gen, .count = @intCast(rules.len) };
    for (rules, 0..) |rr, i| v.rules[i] = rr;
    const c = try table_mod.compile(gpa, v);
    return c.set;
}

test "A6-ro: startsNavigationCall 인자 꼴 — Chromium 이 참으로 읽을 수 있는 꼴은 모두 거두고, Chromium 이 무시하는 꼴만 남긴다" {
    const gpa = testing.allocator;
    const big_pad = try gpa.alloc(u8, 1 << 20);
    defer gpa.free(big_pad);
    @memset(big_pad, 'a');
    const big = try std.fmt.allocPrint(gpa, "{{\"pad\":\"{s}\",\"captureBeyondViewport\":true}}", .{big_pad});
    defer gpa.free(big);
    var deep_buf: [600]u8 = undefined;
    var dw: std.Io.Writer = .fixed(&deep_buf);
    try dw.writeAll("{\"x\":");
    for (0..200) |_| try dw.writeByte('[');
    for (0..200) |_| try dw.writeByte(']');
    try dw.writeAll(",\"captureBeyondViewport\":true}");
    const deep = dw.buffered();
    for ([_][]const u8{
        "{\"captureBeyondViewport\":\"true\"}",
        "{\"captureBeyondViewport\":1}",
        "{\"captureBeyondViewport\":true,\"captureBeyondViewport\":false}",
        "{\"captureBeyondViewport\":false,\"captureBeyondViewport\":true}",
        "{\"\\u0063aptureBeyondViewport\":true}",
        "{\"captureBeyondViewport\":tr",
        "  {\"captureBeyondViewport\" : true }  ",
        "{\"captureBeyondViewport\":true,}",
        "{\"s\":\"\xff\",\"captureBeyondViewport\":true}",
        big,
        deep,
    }) |p| {
        if (!dt.startsNavigationCall(gpa, "Page.captureScreenshot", p)) std.debug.print("A6-ro kept: {s}\n", .{p[0..@min(p.len, 80)]});
        try testing.expect(dt.startsNavigationCall(gpa, "Page.captureScreenshot", p));
    }
    // Chromium(crdtp)도 무시하는 꼴 — 중첩·대소문자 다른 열쇠: 남긴다(보기 크기를 바꾸지 않는다).
    for ([_][]const u8{
        "{\"clip\":{\"x\":0,\"y\":0,\"width\":10,\"height\":10,\"scale\":1,\"captureBeyondViewport\":true}}",
        "{\"CaptureBeyondViewport\":true}",
    }) |p| try testing.expect(!dt.startsNavigationCall(gpa, "Page.captureScreenshot", p));
    // 메서드 이름에 따옴표를 넣어 바깥 JSON 을 바꾸는 꼴은 목록에 없다 — 거둔다.
    try testing.expect(dt.startsNavigationCall(gpa, "Page.captureScreenshot\",\"params\":{\"captureBeyondViewport\":true},\"x\":\"", "{}"));
}

// iframe 하나가 오류 페이지(열쇠 err)와 다른 사이트 진짜 문서(열쇠 good — 새 렌더 프레임)를 오간다. 순수 모형에 떠난 열쇠의 떨어져 나감을 주지 않으면
// (CEF 가 렌더 프레임 바꿈에 on_frame_detached 를 부르지 않는다고 치면) 자리가 찬다 — 살아 있는 프레임은 늘 하나인데도.
// **모형의 답이다 — 실측은 닿지 않는다**: 같은 꼴을 실제 CEF 154 로 70 번 돌린 판정 `A6-stale-err-keys`(오류 페이지 갈래 둘)는 끝에도 규칙 없는 탭의
// 거부권이 그대로였다(CEF 가 떠난 렌더 프레임 열쇠를 떨어뜨린다). 그래서 이 시험은 모형의 답(65 번째에 err_unsure → 「보일지도」 → 규칙 없는 탭은
// 빠진다 — 넘치는 쪽, 새지 않는다)을 고정할 뿐이고, 결함의 재현이 아니다.
test "A6-R6 모형 답(실측 A6-stale-err-keys 로 닿지 않음): 떨어져 나감 없이 iframe 하나를 65 번 오가게 하면 err_unsure — 규칙 없는 탭은 빠진다(넘침 쪽)" {
    var t: table_mod.Table = .{};
    defer t.deinit(testing.allocator);
    const tab = t.ensure(7, 70).?;
    t.committed(7, 70, "localhost", 0);
    const bad = table_mod.canonHash(u8, "http://127.0.0.1:1/refused");
    const good = table_mod.canonHash(u8, "http://127.0.0.1:9/x/blank");
    for (0..table_mod.max_err_frames + 1) |i| {
        t.subframeEnded(70, 0x10_000 + i * 2, bad, true); // 오류 페이지(새 렌더 프레임)
        t.subframeStarted(70, 0x10_001 + i * 2, good); // 다른 사이트 진짜 문서(또 새 렌더 프레임) — 떠난 0x10_000+2i 의 떨어져 나감은 없다
        // 자리 수(64)까지는 다 안다 — 65 번째 오류 프레임에서 자리가 모자라 「모름」 이 된다.
        try testing.expectEqual(i >= table_mod.max_err_frames, tab.err_unsure);
    }
    const v = tab.errSnapshot().view(false, true);
    try testing.expectEqual(table_mod.FrameView.maybe, v);
    // 규칙 없는 탭의 「보일지도」 는 빠진다(거부권 없음 — 실제로 보이면 다른 탭의 규칙이 그 몫도 막는다, 넘침), 규칙을 쥐면 덮는다.
    try testing.expectEqual(sw_share.Role.skip, sw_share.role(v == .shows, false, false, v == .maybe));
    try testing.expectEqual(sw_share.Role.shows, sw_share.role(v == .shows, false, true, v == .maybe));
}

// 6 차 검증 LOW(실측 2/2 — 판정 `A6-R10-read-only-error-stack`): `Runtime.getProperties` 는 Error 값의 설명(`stack` 의 늦은 꼴 만들기)으로 페이지의
// `Error.prepareStackTrace` 를 Error 마다 한 번 돌렸다(`ownProperties`·`generatePreview` 와 무관, `window` 에도). 고침: 읽기 목록에서 뺐다 — 토큰을 거둔다
// (실제 CEF 판정 `A6-R10-getproperties-token`). maru 의 흐름(snapshot·찾기·화면 찍기·저장소 읽기)은 getProperties 를 쓰지 않는다.
test "A6-R10 LOW 고침: Runtime.getProperties 는 읽기 목록 밖 — 인자와 무관하게 사용자 토큰을 거둔다" {
    const gpa = testing.allocator;
    try testing.expect(dt.startsNavigation("Runtime.getProperties"));
    for ([_][]const u8{
        "",
        "{}",
        "{\"objectId\":\"1\",\"ownProperties\":true}",
        "{\"objectId\":\"1\",\"ownProperties\":true,\"generatePreview\":true}",
        "{\"objectId\":\"1\",\"ownProperties\":false,\"accessorPropertiesOnly\":true,\"generatePreview\":true}",
        "{\"objectId\":\"1\",\"nonIndexedPropertiesOnly\":true}",
        "not json",
    }) |p| try testing.expect(dt.startsNavigationCall(gpa, "Runtime.getProperties", p));
    // 목록에 남은 Runtime 메서드는 페이지 값을 설명하지 않는 셋(놓기·멈춤)뿐이다 — 값의 설명을 만드는 메서드가 다시 들어오면 여기서 걸린다.
    for (dt.read_only_methods) |m| {
        if (!std.mem.startsWith(u8, m, "Runtime.")) continue;
        const allowed = std.mem.eql(u8, m, "Runtime.releaseObject") or std.mem.eql(u8, m, "Runtime.releaseObjectGroup") or std.mem.eql(u8, m, "Runtime.terminateExecution");
        if (!allowed) std.debug.print("A6: read list has {s}\n", .{m});
        try testing.expect(allowed);
    }
    // 목록에 남은 읽기(실측 `A6-R10-read-list-lazy-accessors` 로 marks 0)는 그대로 남긴다.
    for ([_][]const u8{ "DOM.resolveNode", "DOM.describeNode", "Accessibility.getFullAXTree", "Accessibility.queryAXTree", "Page.captureScreenshot" }) |m|
        try testing.expect(!dt.startsNavigationCall(gpa, m, "{}"));
}

test "A6-R6 문서화된 대가: 같은 사이트 다른 호스트로 가는 서비스 워커 범위 이동은 ambiguous — 목적지 호스트에만 묶인 규칙은 막지 못한다" {
    const gpa = testing.allocator;
    var t: table_mod.Table = .{};
    defer t.deinit(gpa);
    const tab = t.ensure(7, 70).?;
    try t.swap(gpa, tab, try compiled(gpa, 7, 1, &.{.{ .id = 7, .site = "b.example.test", .pattern = "*://b.example.test/admin*" }}), "", 1);
    t.committed(7, 70, "a.example.test", 0);
    const nav = "https://b.example.test/admin";
    var nb16: [nav.len]u16 = undefined;
    for (nav, 0..) |ch, i| nb16[i] = ch;
    const canon = table_mod.canonHash(u16, &nb16);
    const dest = table_mod.urlOriginHash(u16, &nb16);
    _ = t.beforeBrowse(7, 70, true, false, .other, 0, canon, dest, "b.example.test", 100);
    try testing.expectEqual(table_mod.SwNav.ambiguous, table_mod.swNavItself(tab, canon, dest, "example.test"));
    var hb: [2][]const u8 = undefined;
    const hs = table_mod.swHosts(tab, canon, dest, "example.test", &hb);
    try testing.expectEqual(@as(usize, 2), hs.len);
    var bg: nb.Budget = .{};
    try testing.expect(table_mod.serviceWorkerRule(tab.set.?, nb.splitUrl(u16, &nb16).?, hs, &bg) == null);
}
