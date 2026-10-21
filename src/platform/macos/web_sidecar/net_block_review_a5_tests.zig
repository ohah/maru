//! W9d③ 5 차 적대 검증(A5 — 7f0333fa9 를 친 판)의 순수 탐침을 고친 뒤의 단언으로 둔 것(docs/plans/web-osr-backend.md 「W9d③ 5 차 재검증」).
//! 오류 표시 자리 넘침(MED — 넘치면 막는 쪽으로 닫힌다), 서비스 워커 길의 이동 자체 판정(LOW-1), 같은 주소로 막힌 두 iframe(NIT), 엄격 밖의 모르는
//! 우회와 기록 켬(NIT), 예산의 속성(새는 쪽 없음), 그리고 실측과 모형이 갈리는 기록 토큰 하나(문서화된 틈).

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const nb = protocol.net_block;
const msg = protocol.message;
const table_mod = @import("net_block_table.zig");
const net_domain = @import("net_domain.zig");
const sw_share = @import("sw_share.zig");
const testing = std.testing;

fn compiled(gpa: std.mem.Allocator, browser: msg.BrowserId, gen: u32, rules: []const msg.NetBlockRule) !?*table_mod.RuleSet {
    var v: msg.NetBlock = .{ .browser = browser, .generation = gen, .count = @intCast(rules.len) };
    for (rules, 0..) |rr, i| v.rules[i] = rr;
    const c = try table_mod.compile(gpa, v);
    return c.set;
}

fn a5Tab(t: *table_mod.Table) !*table_mod.Tab {
    const tab = t.ensure(7, 70).?;
    const set1 = try compiled(testing.allocator, 7, 1, &.{ .{ .id = 41, .site = "localhost", .pattern = "*://*/s/swlate*" }, .{ .id = 42, .site = "localhost", .pattern = "*://*/blkifr*" } });
    try t.swap(testing.allocator, tab, set1, "", 1);
    t.committed(7, 70, "localhost", 0);
    return tab;
}

/// 하위 프레임 이동 하나를 규칙 42 로 막는다(진행 중 기록 → IO 고르기 → 표시).
fn blockSub(t: *table_mod.Table, frame: u64, url: []const u8, req: u64, at: i64) !u64 {
    const o = table_mod.originHash("http://127.0.0.1:9");
    const canon = table_mod.canonHash(u8, url);
    _ = t.beforeBrowse(7, 70, false, false, .other, frame, canon, o, "127.0.0.1", at);
    var ub: [128]u16 = undefined;
    for (url, 0..) |ch, i| ub[i] = ch;
    const a = t.acquire(70, req, false, 0, at + 1).?;
    const v = table_mod.decideTab(&a, ub[0..url.len], 1, false, "localhost");
    t.releaseNav(70, &a, v, false, true, canon);
    try testing.expectEqual(table_mod.Verdict{ .block = 42 }, v);
    return canon;
}

test "A5-R6 MED: 막힌 iframe 아홉·열둘의 오류 페이지 — 표시를 하나도 잊지 않는다(전에는 8 자리가 넘쳐 첫 오류 프레임이 실패 주소의 출처를 「보인다」 로 나열됐다)" {
    for ([_]usize{ 9, 12 }) |n| {
        var t: table_mod.Table = .{};
        defer t.deinit(testing.allocator);
        const tab = try a5Tab(&t);
        var keys: [12]u64 = undefined;
        for (0..n) |i| {
            // 사이트가 다른 iframe — 오류 페이지는 새 렌더 프레임 열쇠로 선다(실측 CEF 154).
            const u = try blockSub(&t, 0x100 + i, "http://127.0.0.1:9/blkifr?a5", 300 + i, @intCast(1000 + i * 10));
            keys[i] = 0x200 + i;
            t.subframeEnded(70, keys[i], u, true);
        }
        for (keys[0..n]) |k| try testing.expect(tab.isErrFrame(k));
        try testing.expect(!tab.err_unsure);
        const snap = tab.errSnapshot();
        for (keys[0..n]) |k| try testing.expect(snap.isErr(k));
    }
}

/// 오류 표시 자리를 넘치게 채운 탭(떠난 프레임의 열쇠가 남아 찬 꼴 — `max_err_frames` + 1 개).
fn overflowTab(t: *table_mod.Table) !*table_mod.Tab {
    const tab = try a5Tab(t);
    const u = table_mod.canonHash(u8, "http://127.0.0.1:9/blkifr?ov");
    for (0..table_mod.max_err_frames + 1) |i| t.subframeEnded(70, 0x1000 + i, u, true);
    return tab;
}

test "A5-R6 MED: 오류 표시 자리가 넘치면 잊지 않고 「다 알지 못함」 — 그 탭의 O 주소 하위 프레임은 「보일지도」, 주 프레임은 그대로 「보인다」, 주 프레임의 새 문서가 지운다" {
    var t: table_mod.Table = .{};
    defer t.deinit(testing.allocator);
    const tab = try overflowTab(&t);
    try testing.expect(tab.err_unsure);
    for (0..table_mod.max_err_frames) |i| try testing.expect(tab.isErrFrame(0x1000 + i)); // 덮지 않았다
    const snap = tab.errSnapshot();
    try testing.expectEqual(table_mod.FrameView.maybe, snap.view(false, true));
    try testing.expectEqual(table_mod.FrameView.shows, snap.view(true, true));
    try testing.expectEqual(table_mod.FrameView.other, snap.view(false, false));
    // 넘치지 않은 탭은 전과 같다.
    try testing.expectEqual(table_mod.FrameView.shows, (table_mod.ErrSnapshot{}).view(false, true));
    t.frameSettled(70, true, 0);
    try testing.expect(!tab.err_unsure and !tab.isErrFrame(0x1000));
}

test "A5-R6 MED: 막은 하위 프레임 표시 자리가 넘쳐도 「다 알지 못함」(표시를 잃은 막힘의 오류 페이지를 「보인다」 로 치지 않게)" {
    var t: table_mod.Table = .{};
    defer t.deinit(testing.allocator);
    const tab = try a5Tab(&t);
    for (0..table_mod.max_blocked_sub) |i| _ = try blockSub(&t, 0x100 + i, "http://127.0.0.1:9/blkifr?bs", 300 + i, @intCast(1000 + i));
    try testing.expect(!tab.err_unsure);
    _ = try blockSub(&t, 0x900, "http://127.0.0.1:9/blkifr?bs", 900, 2000);
    try testing.expect(tab.err_unsure);
    // 실측 꼴(A5-R6-err-frames-overflow n=12): 열둘이 함께 막혀 끝을 기다려도 자리가 남는다(넘침이 아니다 — 판정은 정확하게).
    var t2: table_mod.Table = .{};
    defer t2.deinit(testing.allocator);
    const tab2 = try a5Tab(&t2);
    for (0..12) |i| _ = try blockSub(&t2, 0x100 + i, "http://127.0.0.1:9/blkifr?bs12", 300 + i, @intCast(1000 + i));
    try testing.expect(!tab2.err_unsure);
}

test "A5-R6 MED: 넘쳤을 때 서비스 워커 길은 막는 쪽으로 닫힌다 — 규칙을 쥔 「보일지도」 탭은 덮고(아무도 보이지 않으면 넘치게 막힌다), 규칙 없는 「보일지도」 탭은 거부하지 않는다(정말 보이는 탭의 규칙이 막는다 — 전에는 「적용 안 됨」 으로 샜다)" {
    // 판정에 넣는 것은 부른 쪽(`blocking.serviceWorkerSelect`)이 `role` 로 고른다 — 그 고르기를 그대로 흉내 낸다.
    const Cand = struct { browser: msg.BrowserId, shows: bool = false, maybe: bool = false, unknown: bool = false, rule: u32 = 0 };
    const pick = struct {
        fn f(cs: []const Cand, out: []sw_share.TabFacts) []sw_share.TabFacts {
            var n: usize = 0;
            for (cs) |c| {
                const role = sw_share.role(c.shows, c.unknown, c.rule != 0, c.maybe);
                if (role == .skip) continue;
                out[n] = .{ .browser = c.browser, .unknown = c.unknown, .rule_id = if (role == .veto) 0 else c.rule };
                n += 1;
            }
            return out[0..n];
        }
    }.f;
    var buf: [4]sw_share.TabFacts = undefined;
    // 표에서 나열의 몫까지: 넘친 탭의 O 주소 하위 프레임은 「보일지도」.
    var t: table_mod.Table = .{};
    defer t.deinit(testing.allocator);
    const tab = try overflowTab(&t);
    const v = tab.errSnapshot().view(false, true);
    try testing.expectEqual(table_mod.FrameView.maybe, v);
    const maybe = v == .maybe;
    // 넘치는 쪽 실측 꼴(A5-R6-err-frames-overflow): A 는 맞는 규칙 41 을 쥐고 오류 iframe 뿐, 아무 탭도 127.0.0.1 을 보이지 않는다 — 덮어서 막는다(넘침).
    try testing.expectEqual(sw_share.Outcome.block, sw_share.decide(pick(&.{.{ .browser = 1, .maybe = maybe, .rule = 41 }}, &buf)));
    // 새는 쪽 실측 꼴(A5-R6-err-frames-overflow-leak): A 는 맞는 규칙이 없고, Y 가 127.0.0.1 을 보이며 규칙 51 을 쥔다 — A 는 빠져 Y 의 규칙이 막는다.
    try testing.expectEqual(sw_share.Outcome.block, sw_share.decide(pick(&.{ .{ .browser = 1, .maybe = maybe }, .{ .browser = 2, .shows = true, .rule = 51 } }, &buf)));
    // 대조 — 전의 동작(잊힌 오류 프레임을 「보인다」 로)은 Y 의 규칙을 「적용 안 됨」 으로 만들었다(샘).
    try testing.expectEqual(sw_share.Outcome.not_applied, sw_share.decide(pick(&.{ .{ .browser = 1, .shows = true }, .{ .browser = 2, .shows = true, .rule = 51 } }, &buf)));
    // 「보일지도」 인데 A 가 정말 보이는 경우: 규칙 없는 A 는 빠진다 — 덮는 다른 탭의 규칙이 A 몫의 요청도 막는다(넘침 — 막는 쪽).
    try testing.expectEqual(sw_share.Outcome.block, sw_share.decide(pick(&.{ .{ .browser = 1, .maybe = maybe }, .{ .browser = 2, .shows = true, .rule = 51 } }, &buf)));
    // 「모름」 의 거부권은 그대로(「보일지도」 와 함께여도 규칙이 없으면).
    try testing.expectEqual(sw_share.Outcome.not_applied, sw_share.decide(pick(&.{ .{ .browser = 1, .maybe = maybe, .unknown = true }, .{ .browser = 2, .shows = true, .rule = 51 } }, &buf)));
}

test "A5-R6 NIT: 같은 주소로 막힌 두 iframe — 한 프레임의 끝(on_load_error)은 표시 하나만 지운다(다른 프레임이 on_load_error 없이 서는 방어 갈래는 그대로 오류 페이지)" {
    var t: table_mod.Table = .{};
    defer t.deinit(testing.allocator);
    const tab = try a5Tab(&t);
    const u = try blockSub(&t, 0x20, "http://127.0.0.1:9/blkifr?same", 300, 1000);
    _ = try blockSub(&t, 0x21, "http://127.0.0.1:9/blkifr?same", 301, 1010);
    // 프레임 0x20 의 막힘은 실측 길(on_load_error -20)로 끝난다.
    t.subframeEnded(70, 0x30, u, true);
    // 프레임 0x21 은 on_load_error 없이 그 주소로 문서가 선다(방어 갈래 — 이 갈래면 오류 페이지여야 한다).
    t.subframeStarted(70, 0x31, u);
    try testing.expect(tab.isErrFrame(0x31));
    // 같은 사이트 iframe(끝의 열쇠가 막을 때와 같다)은 제 표시만 지운다 — 주소가 같은 다른 프레임의 것은 남는다.
    var t2: table_mod.Table = .{};
    defer t2.deinit(testing.allocator);
    const tab2 = try a5Tab(&t2);
    const ub2 = try blockSub(&t2, 0x40, "http://127.0.0.1:9/blkifr?same2", 400, 1000);
    _ = try blockSub(&t2, 0x41, "http://127.0.0.1:9/blkifr?same2", 401, 1010);
    t2.subframeEnded(70, 0x41, ub2, true);
    try testing.expect(tab2.isErrFrame(0x41));
    var left: usize = 0;
    for (tab2.blocked_sub) |b| if (b.url != 0) {
        left += 1;
        try testing.expectEqual(@as(u64, 0x40), b.frame); // 꺼낸 것은 0x41 제 표시다
    };
    try testing.expectEqual(@as(usize, 1), left);
    t2.subframeStarted(70, 0x40, ub2); // 0x40 의 표시는 남았다 — 그 프레임이 on_load_error 없이 서면 오류 페이지
    try testing.expect(tab2.isErrFrame(0x40));
    // 표시가 다 쓰인 뒤 같은 주소로 선 진짜 문서는 오류 페이지가 아니다(4 차 A-MED 그대로).
    t2.subframeStarted(70, 0x42, ub2);
    try testing.expect(!tab2.isErrFrame(0x42));
    // 떨어져 나간 프레임의 표시는 그 프레임과 함께 지운다 — 같은 주소로 뒤에 선 진짜 문서는 오류 페이지가 아니다.
    var t3: table_mod.Table = .{};
    defer t3.deinit(testing.allocator);
    const tab3 = try a5Tab(&t3);
    const ub3 = try blockSub(&t3, 0x50, "http://127.0.0.1:9/blkifr?gone", 500, 1000);
    t3.subframeGone(70, 0x50);
    t3.subframeStarted(70, 0x51, ub3);
    try testing.expect(!tab3.isErrFrame(0x51));
    // 프레임을 모르고 적힌 표시(진행 중 기록 없음 — 0)는 그 주소의 새 이동이 지운다(프레임으로 가를 수 없다).
    var t4: table_mod.Table = .{};
    defer t4.deinit(testing.allocator);
    const tab4 = try a5Tab(&t4);
    const u4_text = "http://127.0.0.1:9/blkifr?frameless";
    var ufl: [u4_text.len]u16 = undefined;
    for (u4_text, 0..) |ch, i| ufl[i] = ch;
    const c4 = table_mod.canonHash(u16, &ufl);
    const a4 = t4.acquire(70, 600, false, 0, 1000).?;
    const v4 = table_mod.decideTab(&a4, &ufl, 1, false, "localhost");
    t4.releaseNav(70, &a4, v4, false, true, c4);
    try testing.expect(tab4.blocked_sub[0].url == c4 and tab4.blocked_sub[0].frame == 0);
    _ = t4.beforeBrowse(7, 70, false, false, .other, 0x60, c4, 1, "127.0.0.1", 1100);
    try testing.expectEqual(@as(u64, 0), tab4.blocked_sub[0].url);
}

test "A5-R6 LOW-1: 서비스 워커 길의 이동 자체 판정은 요청의 쿠키 첫 사이트로 가른다 — 다른 사이트 옛 문서 안의 목적지 출처 iframe(분할 저장소 — 첫 사이트 빈 글)은 두 호스트, 목적지의 맨 위 서비스 워커는 이동 호스트 하나, 같은 사이트 옛 문서면 가를 수 없어 두 호스트(귀속은 남긴다)" {
    const gpa = testing.allocator;
    var t: table_mod.Table = .{};
    defer t.deinit(gpa);
    const tab = t.ensure(7, 70).?;
    try t.swap(gpa, tab, try compiled(gpa, 7, 1, &.{.{ .id = 93, .site = "localhost", .pattern = "http://localhost:9/s4/hang*" }}), "", 1);
    const set = tab.set.?;
    t.committed(7, 70, "127.0.0.1", 0);
    const nav = "http://localhost:9/s4/hang?a5navs";
    var nb16: [nav.len]u16 = undefined;
    for (nav, 0..) |ch, i| nb16[i] = ch;
    const canon = table_mod.canonHash(u16, &nb16);
    const dest = table_mod.urlOriginHash(u16, &nb16);
    _ = t.beforeBrowse(7, 70, true, false, .other, 0, canon, dest, "localhost", 100);
    const parts = nb.splitUrl(u16, &nb16).?;
    var hb: [2][]const u8 = undefined;
    var bg: nb.Budget = .{};
    // 실측 A5-R6-sw-iframe-dest-origin 의 iframe 요청: 출처·주소는 이동과 같지만 첫 사이트가 비었다 — 이동 자체가 아니다(탭 길이면 페이지 호스트라 지나간다).
    try testing.expectEqual(table_mod.SwNav.no, table_mod.swNavItself(tab, canon, dest, ""));
    const ifr = table_mod.swHosts(tab, canon, dest, "", &hb);
    try testing.expect(ifr.len == 2);
    try testing.expect(table_mod.serviceWorkerRule(set, parts, ifr, &bg) == null); // 전에는 규칙 93 이 막았다(실측 rej +1)
    // 이동 자체(목적지 localhost 의 맨 위 서비스 워커 — 첫 사이트 localhost): 이동 호스트 하나(MED-A3-2 그대로).
    try testing.expectEqual(table_mod.SwNav.yes, table_mod.swNavItself(tab, canon, dest, "localhost"));
    const itself = table_mod.swHosts(tab, canon, dest, "localhost", &hb);
    try testing.expect(itself.len == 1 and std.mem.eql(u8, itself[0], "localhost"));
    try testing.expectEqual(@as(u32, 93), table_mod.serviceWorkerRule(set, parts, itself, &bg).?.id);
    // 첫 사이트가 목적지 사이트가 아니면(다른 사이트의 맨 위 서비스 워커) 이동 자체가 아니다.
    try testing.expectEqual(table_mod.SwNav.no, table_mod.swNavItself(tab, canon, dest, "127.0.0.1"));
    // 같은 사이트 옛 문서: 그 안의 목적지 출처 iframe 도 같은 첫 사이트를 싣는다 — 가를 근거가 없어 두 호스트(이동 자체로 치지 않는다).
    // (주소 확정은 진행 중 주 프레임 이동을 지운다 — 맨 위 호스트만 바꾼 꼴로 잰다: 같은 사이트 a.localhost 의 문서가 localhost 로 옮기는 중.)
    @memcpy(tab.top_buf[0.."a.localhost".len], "a.localhost");
    tab.top_len = "a.localhost".len;
    try testing.expectEqual(table_mod.SwNav.ambiguous, table_mod.swNavItself(tab, canon, dest, "localhost"));
    try testing.expect(table_mod.swHosts(tab, canon, dest, "localhost", &hb).len == 2);
    // 옛 문서가 없으면(맨 위를 모른다 — 첫 이동) 이동 자체다.
    tab.top_len = 0;
    try testing.expectEqual(table_mod.SwNav.yes, table_mod.swNavItself(tab, canon, dest, "localhost"));
    // 다른 주소·다른 출처의 요청은 이동이 아니다(귀속도 없다 — 부른 쪽이 `no` 를 거른다).
    try testing.expectEqual(table_mod.SwNav.no, table_mod.swNavItself(tab, table_mod.canonHash(u8, "http://localhost:9/s4/other"), dest, "localhost"));
    try testing.expectEqual(table_mod.SwNav.no, table_mod.swNavItself(tab, canon, table_mod.originHash("http://127.0.0.1:9"), "localhost"));
}

test "A5-R10 문서화된 틈: 사용자의 뒤로가 같은 문서의 다른 주소 항목이고 페이지가 그 이동을 취소하면(확정·on_before_browse 없음) 모형에서는 기록 토큰이 30 초 남는다 — 실측은 그 뒤 페이지의 기록 이동이 시작되지 않는다(판정 A5-R10-traverse-cancel-steal 이 지킨다)" {
    var t: table_mod.Table = .{};
    defer t.deinit(testing.allocator);
    _ = try a5Tab(&t);
    const H = table_mod.HistoryAt;
    const A = table_mod.canonHash(u8, "http://localhost:9/a5/nc");
    const B = table_mod.canonHash(u8, "http://localhost:9/a5/nc?b");
    const blk = table_mod.canonHash(u8, "http://localhost:9/blk/target");
    // [blk, A, B(몸짓 있는 pushState — 같은 문서)] — 사용자 뒤로: 대상 A(주소가 다르다) → 남긴다.
    t.userNavAction(7, 70, .history, 1000);
    const stays = table_mod.historyTokenStays(H{ .index = 2, .url = B, .step_url = A }, H{ .index = 1, .url = A });
    try testing.expect(stays);
    // 페이지가 navigate 사건으로 그 같은 문서 기록 이동을 취소했다 — 확정(주소 바뀜)이 없다. 20 초 뒤 페이지의 history.go(-2)(전이 FORWARD_BACK).
    // 모형은 그 이동을 사용자의 것으로 친다 — 이 단언이 바뀌면(토큰을 거두게 되면) 계획 문서의 틈도 고친다.
    const user = t.beforeBrowse(7, 70, true, false, .history, 0, blk, 1, "localhost", 21_000);
    try testing.expect(user);
}

test "A5-B NIT: 엄격 밖의 bypass_off 가 실패하면(우회 모름) 그 뒤 기록 켬은 enable_record 다음 bypass_off 를 명시한다(기록의 enable 이 남은 우회 표시를 되살리지 않게), 한 번만" {
    var d: net_domain.Domain = .{};
    _ = d.strictOn(true); // enable_light, bypass_on
    const off = d.strictOff(); // bypass_off, disable
    try testing.expectEqualSlices(net_domain.Cmd, &.{ .bypass_off, .disable }, off.slice());
    d.bypassUnknown(); // bypass_off 의 실패 답·DevTools 떨어짐
    const rec = d.recordOn();
    try testing.expectEqualSlices(net_domain.Cmd, &.{ .enable_record, .bypass_off }, rec.slice());
    const again = d.recordOn();
    try testing.expectEqualSlices(net_domain.Cmd, &.{.enable_record}, again.slice());
    // 엄격이 켜져 있으면 기록 켬은 우회를 건드리지 않는다(바라는 값은 다음 이동·켬이 명시한다).
    var e: net_domain.Domain = .{};
    _ = e.strictOn(true);
    e.bypassUnknown();
    try testing.expectEqualSlices(net_domain.Cmd, &.{.enable_record}, e.recordOn().slice());
    try testing.expectEqualSlices(net_domain.Cmd, &.{.bypass_on}, e.navigate(true).slice());
}

test "A5-B: 엄격 켬→끔→켬을 빠르게 — 앞 차례의 늦은 답(실패 포함)은 지금 차례를 바꾸지 않고, 지금 차례가 모두 답해야 on" {
    var d: net_domain.Domain = .{};
    var b: net_domain.Batch = .{};
    // 차례 0: 켬 둘.
    const c1 = b.on(&d, true);
    try testing.expectEqualSlices(net_domain.Cmd, &.{ .enable_light, .bypass_on }, c1.slice());
    const e0 = b.epoch;
    b.sent(true);
    b.sent(true);
    // 끔 — 차례가 바뀐다.
    const c2 = b.off(&d);
    try testing.expectEqualSlices(net_domain.Cmd, &.{ .bypass_off, .disable }, c2.slice());
    // 다시 켬.
    const c3 = b.on(&d, true);
    try testing.expectEqualSlices(net_domain.Cmd, &.{ .enable_light, .bypass_on }, c3.slice());
    const e1 = b.epoch;
    try testing.expect(e1 != e0);
    b.sent(true);
    b.sent(true);
    try testing.expect(b.settle() == null);
    // 앞 차례의 늦은 답 — 실패.
    try testing.expect(b.answered(e0, false) == null);
    try testing.expect(b.answered(e0, false) == null);
    // 지금 차례.
    try testing.expect(b.answered(e1, true) == null);
    try testing.expectEqual(net_domain.Batch.State.on, b.answered(e1, true).?);
    // 지금 차례의 하나가 실패하면 failed, 다음 켬은 모두 다시 보낸다.
    _ = b.on(&d, false);
    const c4 = b.on(&d, false);
    _ = c4;
    var d2: net_domain.Domain = .{};
    var b2: net_domain.Batch = .{};
    _ = b2.on(&d2, true);
    b2.sent(true);
    b2.sent(true);
    _ = b2.answered(b2.epoch, false);
    const st = b2.answered(b2.epoch, true).?;
    try testing.expectEqual(net_domain.Batch.State.failed, st);
    const again = b2.on(&d2, true);
    try testing.expectEqualSlices(net_domain.Cmd, &.{ .enable_light, .bypass_on }, again.slice());
}

// ── 예산(B-LOW-4 의 고침): 예산이 다한 맞추기는 늘 정확한 맞추기 이상(새는 쪽 없음) ─────────────────────────────────────

fn randPattern(rnd: std.Random, buf: []u8) []const u8 {
    const head = "http://a.test/";
    @memcpy(buf[0..head.len], head);
    var n: usize = head.len;
    var stars: usize = 0;
    const len = rnd.intRangeAtMost(usize, 1, 14);
    for (0..len) |_| {
        const r = rnd.intRangeLessThan(u8, 0, 10);
        const ch: u8 = if (r < 3 and stars < nb.max_stars) '*' else if (r < 6) 'a' else if (r < 8) 'b' else if (r < 9) '/' else '%';
        if (ch == '*') stars += 1;
        if (ch == '%') {
            // 퍼센트 인코딩 꼴(대문자 — 정규형).
            const e = if (rnd.boolean()) "%2F" else "%41";
            @memcpy(buf[n..][0..3], e);
            n += 3;
            continue;
        }
        buf[n] = ch;
        n += 1;
    }
    return buf[0..n];
}

fn randUrl(rnd: std.Random, buf: []u8) []const u8 {
    const head = "http://a.test/";
    @memcpy(buf[0..head.len], head);
    var n: usize = head.len;
    const long = rnd.intRangeLessThan(u8, 0, 20) == 0;
    const len = if (long) rnd.intRangeAtMost(usize, 60_000, 70_000) else rnd.intRangeAtMost(usize, 0, 300);
    var i: usize = 0;
    while (i < len and n + 3 < buf.len) : (i += 1) {
        const r = rnd.intRangeLessThan(u8, 0, 10);
        if (r == 9) {
            const e = if (rnd.boolean()) "%2F" else "%41";
            @memcpy(buf[n..][0..3], e);
            n += 3;
            continue;
        }
        buf[n] = if (r < 5) 'a' else if (r < 8) 'b' else '/';
        n += 1;
    }
    return buf[0..n];
}

test "A5-R20: 예산 맞추기는 정확한 맞추기를 덮는다 — 무작위 패턴(별·퍼센트)·주소(긴 것 포함)·예산 경계, 규칙 여럿이 예산 하나를 나눔" {
    var prng = std.Random.DefaultPrng.init(0xa5b0d6e7);
    const rnd = prng.random();
    const ubuf = try testing.allocator.alloc(u8, 72_000);
    defer testing.allocator.free(ubuf);
    var pbufs: [4][160]u8 = undefined;
    var leaks: usize = 0;
    var over: usize = 0;
    var cases: usize = 0;
    for (0..30_000) |_| {
        const nr = rnd.intRangeAtMost(usize, 1, 4);
        var pats: [4]nb.Pattern = undefined;
        var np: usize = 0;
        for (0..nr) |k| {
            switch (nb.parse(randPattern(rnd, &pbufs[k]))) {
                .ok => |p| {
                    pats[np] = p;
                    np += 1;
                },
                .err => {},
            }
        }
        if (np == 0) continue;
        const url = randUrl(rnd, ubuf);
        const parts = nb.splitUrl(u8, url) orelse continue;
        // 예산은 경계 근처를 고른다(0, 작은 값, 주소 길이 ± 작은 값, 기본).
        const choice = rnd.intRangeLessThan(u8, 0, 5);
        const start: usize = switch (choice) {
            0 => 0,
            1 => rnd.intRangeAtMost(usize, 0, 20),
            2 => parts.path.len -| rnd.intRangeAtMost(usize, 0, 8),
            3 => parts.path.len + rnd.intRangeAtMost(usize, 0, 8),
            else => nb.request_scan_budget,
        };
        var budget: nb.Budget = .{ .left = start };
        var exact_any = false;
        var got_any = false;
        for (pats[0..np]) |*p| {
            const e = nb.matchParts(u8, p, parts);
            const g = nb.matchPartsBudget(u8, p, parts, &budget);
            cases += 1;
            if (e and !g) {
                leaks += 1;
                if (leaks <= 5) std.debug.print("A5-R20 새는 쪽: pattern {s} url len {d} budget {d}\n", .{ p.norm(), url.len, start });
            }
            if (g and !e) over += 1;
            exact_any = exact_any or e;
            got_any = got_any or g;
            if (budget.left > start) return error.TestUnexpectedResult; // 예산이 늘지 않는다
        }
        if (exact_any and !got_any) leaks += 1;
    }
    try testing.expect(cases > 10_000 and over > 0); // 예산 경계를 실제로 쳤다(넘치는 쪽은 있다)
    try testing.expectEqual(@as(usize, 0), leaks);
}

test "A5-R20: 서비스 워커 길의 예산은 탭들이 나눈다 — 앞 탭의 규칙이 예산을 다 써도 뒤 탭의 정확히 맞는 규칙은 맞는다(새지 않음), 맞지 않는 규칙이 넘치게 맞을 수는 있다" {
    const gpa = testing.allocator;
    var t: table_mod.Table = .{};
    defer t.deinit(gpa);
    const ta = t.ensure(7, 70).?;
    const tb = t.ensure(8, 80).?;
    var rules_a: [32]msg.NetBlockRule = undefined;
    var pb: [32][64]u8 = undefined;
    for (0..32) |i| {
        rules_a[i] = .{ .id = @intCast(100 + i), .site = "a.test", .pattern = std.fmt.bufPrint(&pb[i], "*://*/*zz{d}*q", .{i}) catch unreachable };
    }
    try t.swap(gpa, ta, try compiled(gpa, 7, 1, &rules_a), "", 1);
    try t.swap(gpa, tb, try compiled(gpa, 8, 1, &.{.{ .id = 7, .site = "a.test", .pattern = "*://*/*nomatch*q" }}), "", 1);
    const url_text = "http://a.test/" ++ @import("array_repeat").repeat("a", 4000) ++ "q";
    var ub: [url_text.len]u16 = undefined;
    for (url_text, 0..) |ch, i| ub[i] = ch;
    const parts = nb.splitUrl(u16, &ub).?;
    var budget: nb.Budget = .{};
    const hosts = [_][]const u8{"a.test"};
    const ra = table_mod.serviceWorkerRule(ta.set.?, parts, &hosts, &budget);
    const rb = table_mod.serviceWorkerRule(tb.set.?, parts, &hosts, &budget);
    // 정확히는 둘 다 맞지 않는다 — 예산이 다해 A 의 뒤 규칙과 B 의 규칙이 넘치게 맞는다(막는 쪽, 계획 문서의 대가: 예산은 그 출처를 보이는 탭 모두가
    // 나눈다 — 「규칙 32 개도 1 KiB 주소면 정확」 은 탭 하나일 때만).
    try testing.expect(ra != null and ra.?.id > 100 and rb != null and rb.?.id == 7);
    try testing.expectEqual(@as(usize, 0), budget.left);
    // 탭 하나(A 만)·1 KiB 주소면 정확하다 — 맞지 않는다.
    const short_text = "http://a.test/" ++ @import("array_repeat").repeat("a", 1000) ++ "q";
    var sb: [short_text.len]u16 = undefined;
    for (short_text, 0..) |ch, i| sb[i] = ch;
    var b1: nb.Budget = .{};
    try testing.expect(table_mod.serviceWorkerRule(ta.set.?, nb.splitUrl(u16, &sb).?, &hosts, &b1) == null);
}
