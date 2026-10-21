//! W9d③ 4 차 적대 검증(검증자 B4 — 12·13·14·20 회차)의 순수 시험 — 검증자의 탐침을 고친 뒤의 답으로 단언한다(B-LOW-1·2·3·4·B-NIT).
//! CEF 를 쓰지 않는다 — 막기 표(`net_block_table` — 세대·켬 몫·맞추기 예산), Network 도메인 주인(`net_domain` — 우회 모름·답 셈), wire 23(`codec`).

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const nb = protocol.net_block;
const msg = protocol.message;
const codec = protocol.codec;
const table_mod = @import("net_block_table.zig");
const net_domain = @import("net_domain.zig");

const testing = std.testing;
const Table = table_mod.Table;

fn netBlock(gen: u32, ids: []const u32) msg.NetBlock {
    const pats = [_][]const u8{ "https://a.test/blk", "https://a.test/two", "https://a.test/three", "https://a.test/four" };
    var v: msg.NetBlock = .{ .browser = 7, .generation = gen, .count = @intCast(ids.len) };
    for (ids, 0..) |id, i| v.rules[i] = .{ .id = id, .site = "a.test", .pattern = pats[(id - 1) % pats.len] };
    return v;
}

fn installGen(t: *Table, gen: u32, ids: []const u32) !void {
    const c = try table_mod.compile(testing.allocator, netBlock(gen, ids));
    try t.swap(testing.allocator, t.ensure(7, 70).?, c.set, "", gen);
}

// ── 13 설정 — N-B3-d 의 은퇴 묶음 갈래 ──────────────────────────────────────────────────────────────

test "B4-R13 B-LOW-1: 설정 끔은 은퇴 묶음의 서비스 워커 수도 버린다 — 규칙을 더해 묶음이 바뀐 뒤 보내기 전(10 ms)에 끄고 다시 켜도 끌 때 maru 가 지운 켬 몫이 되살아나지 않는다" {
    var t: Table = .{};
    defer t.deinit(testing.allocator);
    try installGen(&t, 1, &.{1});
    t.setFull(7, 70, true);
    const tab = t.findCef(70).?;
    table_mod.bump(&tab.set.?.rules[0].sw_hits); // 켬 동안 센 서비스 워커 막음
    table_mod.bump(&tab.set.?.rules[0].sw_not_applied);
    try installGen(&t, 2, &.{ 1, 2 }); // 에이전트가 규칙을 더했다 — 세대 1 묶음은 은퇴 목록으로(수는 아직 보내지 않았다)
    t.setFull(7, 70, false); // 사용자가 끈다 — maru 는 켬 몫을 지웠다(forgetFullCounts)
    t.setFull(7, 70, true); // 곧 다시 켠다(보내기 task 전)
    var out: [table_mod.max_frames]msg.NetBlockHits = undefined;
    const n = t.takeHits(7, &out);
    var sw: u32 = 0;
    for (out[0..n]) |f| for (f.entries[0..f.count]) |e| {
        sw += e.sw_hits + e.sw_not_applied;
    };
    try testing.expectEqual(@as(u32, 0), sw); // 전에는 2(세대 1 frame 의 규칙 1 — maru 의 규칙 1 은 그대로라 받았다)
    // 다시 켠 뒤에 센 수는 간다(끔은 그때까지의 것만 버린다).
    table_mod.bump(&t.retired.items[0].rules[0].sw_hits);
    const n2 = t.takeHits(7, &out);
    try testing.expect(n2 == 1 and out[0].generation == 1 and out[0].entries[0].sw_hits == 1);
    t.reap(testing.allocator);
}

test "B4-R13 대조: 지금 묶음의 같은 갈래는 버린다(3 차 고침 그대로)" {
    var t: Table = .{};
    defer t.deinit(testing.allocator);
    try installGen(&t, 1, &.{1});
    t.setFull(7, 70, true);
    table_mod.bump(&t.findCef(70).?.set.?.rules[0].sw_hits);
    t.setFull(7, 70, false);
    t.setFull(7, 70, true);
    try testing.expect(table_mod.takeOne(&t, 7) == null);
}

// ── 14 상한 — N-B3-a 의 다시 보내기 ──────────────────────────────────────────────────────────────────

test "B4-R14 B-LOW-2: 엄격 CDP 실패 뒤(forgetStrictSent) 우회는 「모름」 — 덮지 않는 페이지의 다시 켬·엄격 끔이 bypass_off 를 먼저 보낸다(브라우저에 남았을 수 있는 표시를 지운다)" {
    // 우회 표시는 `Network.disable` 뒤에도 남고 다음 `Network.enable` 이 되살린다(실측 sw2). 실패한 짝(enable_light·bypass_on) 중 bypass_on 이
    // 브라우저에 닿았는지 sidecar 는 모른다 — DevTools 가 떨어진 갈래(onDetached)는 답이 오지 않을 뿐 브라우저 쪽 명령은 들었을 수 있다.
    var d: net_domain.Domain = .{};
    _ = d.strictOn(true); // enable_light, bypass_on — 답 전에 실패로 끝났다
    d.forgetStrictSent();
    // 다음 net_block(사용자가 다른 사이트로 옮긴 뒤 규칙을 더함) — 전에는 { .enable_light } 뿐이었다.
    try testing.expectEqualSlices(net_domain.Cmd, &.{ .enable_light, .bypass_off }, d.strictOn(false).slice());
    try testing.expectEqualSlices(net_domain.Cmd, &.{}, d.strictOn(false).slice()); // 이제 안다 — 다시 보내지 않는다
    // 다시 실패 — 그 뒤의 엄격 끔은 bypass_off 가 먼저, 가벼운 도메인도 닿았을지 모르니 끈다(전에는 { .disable } 뿐 — 표시가 남아 기록의
    // Network.enable 이 우회를 되살렸다).
    d.forgetStrictSent();
    try testing.expectEqualSlices(net_domain.Cmd, &.{ .bypass_off, .disable }, d.strictOff().slice());
    try testing.expectEqualSlices(net_domain.Cmd, &.{}, d.strictOff().slice());
    // 이동 홉도 모르는 우회는 명시해 보낸다(같은 값이라도).
    var e: net_domain.Domain = .{};
    _ = e.strictOn(false);
    e.forgetStrictSent();
    try testing.expectEqualSlices(net_domain.Cmd, &.{.bypass_off}, e.navigate(false).slice());
    try testing.expectEqualSlices(net_domain.Cmd, &.{}, e.navigate(false).slice());
    // 기록이 켠 도메인은 실패 뒤에도 끄지 않는다 — 우회만 지운다.
    var r: net_domain.Domain = .{};
    _ = r.recordOn();
    _ = r.strictOn(true);
    r.forgetStrictSent();
    try testing.expectEqualSlices(net_domain.Cmd, &.{.bypass_off}, r.strictOff().slice());
}

test "B4-R14 B-LOW-3·B-NIT: 엄격 켬의 답 셈 — 두 답 사이의 net_block 이 앞 실패를 지우지 않고 모두 다시 보낸다, 보내기가 실패하면 실패, 끄면 기다리지 않고 곧 off, 앞 차례의 늦은 답은 세지 않는다" {
    const B = net_domain.Batch;
    // 켬 — 명령 둘, 첫 답 실패, 둘째 답 전에 다음 net_block(같은 사이트 — 보낼 것이 없다고 믿는다).
    var d: net_domain.Domain = .{};
    var b: B = .{};
    const first = b.on(&d, true);
    try testing.expectEqualSlices(net_domain.Cmd, &.{ .enable_light, .bypass_on }, first.slice());
    const e1 = b.epoch;
    b.sent(true);
    b.sent(true);
    try testing.expect(b.settle() == null);
    try testing.expect(b.answered(e1, false) == null); // 실패 — 아직 하나 남았다
    // 다음 net_block: 전에는 실패 표시를 지우고 남은 답의 성공으로 `on` 을 냈다. 이제 모두 다시 보낸다(새 차례).
    const again = b.on(&d, true);
    try testing.expectEqualSlices(net_domain.Cmd, &.{ .enable_light, .bypass_on }, again.slice());
    b.sent(true);
    b.sent(true);
    try testing.expect(b.answered(e1, true) == null); // 앞 차례의 늦은 성공 — 세지 않는다
    try testing.expect(b.answered(b.epoch, true) == null);
    try testing.expectEqual(B.State.on, b.answered(b.epoch, true).?);
    // 대조: 실패가 없으면 기다리는 답을 그대로 둔다 — 같은 사이트의 net_block 이 답 전에 와도 `on` 은 모든 답 뒤에.
    var d2: net_domain.Domain = .{};
    var b2: B = .{};
    _ = b2.on(&d2, true);
    b2.sent(true);
    b2.sent(true);
    try testing.expectEqualSlices(net_domain.Cmd, &.{}, b2.on(&d2, true).slice());
    try testing.expect(b2.settle() == null);
    try testing.expect(b2.answered(b2.epoch, true) == null);
    try testing.expectEqual(B.State.on, b2.answered(b2.epoch, true).?);
    // 실패한 차례가 끝난 뒤(state failed)의 net_block 도 모두 다시(N-B3-a 그대로).
    var d3: net_domain.Domain = .{};
    var b3: B = .{};
    _ = b3.on(&d3, false);
    b3.sent(true);
    try testing.expectEqual(B.State.failed, b3.answered(b3.epoch, false).?);
    try testing.expectEqualSlices(net_domain.Cmd, &.{ .enable_light, .bypass_off }, b3.on(&d3, false).slice());
    // B-NIT: 보내기가 실패하면 실패 — 모른 채 `on` 으로 답하지 않는다(짝 자리는 10 차부터 탭마다 종류마다 하나라 늘 있다 — 「자리 없음」 은 사라졌다).
    var d4: net_domain.Domain = .{};
    var b4: B = .{};
    _ = b4.on(&d4, true);
    b4.sent(true);
    b4.sent(false);
    try testing.expectEqual(B.State.failed, b4.answered(b4.epoch, true).?);
    var b5: B = .{};
    var d5: net_domain.Domain = .{};
    _ = b5.on(&d5, true);
    b5.sent(false);
    try testing.expectEqual(B.State.failed, b5.settle().?);
    // 끔 — 기다리던 켬의 답은 세지 않는다(곧 off — 전에는 그 세대의 상태를 영영 보내지 않았다).
    var d6: net_domain.Domain = .{};
    var b6: B = .{};
    _ = b6.on(&d6, true);
    const e6 = b6.epoch;
    b6.sent(true);
    try testing.expectEqualSlices(net_domain.Cmd, &.{ .bypass_off, .disable }, b6.off(&d6).slice());
    try testing.expectEqual(B.State.off, b6.state);
    try testing.expect(b6.answered(e6, true) == null);
    try testing.expectEqual(B.State.off, b6.state);
    // 떨어짐 — 기다리던 답이 있으면 실패, 없으면 아무것도.
    var d7: net_domain.Domain = .{};
    var b7: B = .{};
    _ = b7.on(&d7, true);
    b7.sent(true);
    try testing.expectEqual(B.State.failed, b7.detached().?);
    try testing.expect(b7.detached() == null);
}

// ── 12 철회 — 세대 무작위 걸음(속성: 어떤 수도 센 세대보다 **새** 세대를 달고 나가지 않는다) ─────────────

test "B4-R12: 세대 무작위 걸음 4 천 판 — 바꾸기·비우기·IO 의 잡기·놓기·문 넘김·보내기를 섞어도 수는 센 세대 또는 그보다 앞선 세대로만 나간다(바닥이 버리는 쪽), 잃지 않는다" {
    var prng = std.Random.DefaultPrng.init(0xb4_12);
    const rnd = prng.random();
    const max_gen = 64;
    var walks: usize = 0;
    var merged_down: usize = 0;
    while (walks < 4000) : (walks += 1) {
        var t: Table = .{};
        defer t.deinit(testing.allocator);
        var truth: [max_gen + 2]u64 = @splat(0); // 센 세대마다(탭 몫·규칙 수 합)
        var sent: [max_gen + 2]u64 = @splat(0); // 단 세대마다
        var gen: u32 = 1;
        try installGen(&t, gen, &.{1});
        t.committed(7, 70, "a.test", 0);
        var held: [6]table_mod.Acquired = undefined;
        var held_gen: [6]u32 = undefined;
        var nh: usize = 0;
        const url = std.unicode.utf8ToUtf16LeStringLiteral("https://a.test/blk/x");
        var steps: usize = 0;
        while (steps < 200) : (steps += 1) {
            switch (rnd.uintLessThan(u8, 10)) {
                0, 1 => if (gen < max_gen) {
                    gen += 1;
                    if (rnd.uintLessThan(u8, 3) == 0) {
                        try t.swap(testing.allocator, t.findCef(70).?, null, "", gen); // 비움
                    } else try installGen(&t, gen, if (rnd.boolean()) &.{1} else &.{ 1, 2 });
                },
                2, 3 => if (nh < held.len) {
                    if (t.acquire(70, 100 + steps, false, 0, 0)) |a| {
                        held[nh] = a;
                        held_gen[nh] = a.set.generation;
                        nh += 1;
                    }
                },
                4, 5 => if (nh > 0) {
                    const i = rnd.uintLessThan(usize, nh);
                    var a = held[i];
                    const page: []const u8 = if (rnd.boolean()) "a.test" else "";
                    const v = table_mod.decideTab(&a, url, 4, false, page);
                    t.release(70, &a, v, false, 0);
                    switch (v) {
                        .block, .unknown_page => truth[held_gen[i]] += 1,
                        else => {},
                    }
                    if (v == .block and rnd.boolean()) {
                        t.noteUnrecorded(70, held_gen[i]); // 문이 넘긴 막음 — 잡은 묶음의 세대
                        truth[held_gen[i]] += 1;
                    }
                    held[i] = held[nh - 1];
                    held_gen[i] = held_gen[nh - 1];
                    nh -= 1;
                },
                6 => {
                    // 엄격 리다이렉트 셈(문서 확정 때 — 지금 세대).
                    t.findCef(70).?.counts.strict_redirect_missed +|= 1;
                    truth[t.findCef(70).?.generation] += 1;
                },
                else => {
                    var out: [table_mod.max_frames]msg.NetBlockHits = undefined;
                    const n = t.takeHits(7, &out);
                    for (out[0..n]) |f| {
                        var s: u64 = f.unrecorded + f.skipped_unknown_page + f.strict_redirect_missed;
                        for (f.entries[0..f.count]) |e| s += e.hits;
                        sent[f.generation] += s;
                    }
                    t.reap(testing.allocator);
                },
            }
        }
        // 남은 것을 놓고 모두 보낸다.
        while (nh > 0) : (nh -= 1) {
            var a = held[nh - 1];
            t.release(70, &a, .pass, false, 0);
        }
        var out: [table_mod.max_frames]msg.NetBlockHits = undefined;
        const n = t.takeHits(7, &out);
        for (out[0..n]) |f| {
            var s: u64 = f.unrecorded + f.skipped_unknown_page + f.strict_redirect_missed;
            for (f.entries[0..f.count]) |e| s += e.hits;
            sent[f.generation] += s;
        }
        t.reap(testing.allocator);
        // 속성: 세대 G 이상을 단 수의 합 ≤ 세대 G 이상에서 센 수의 합(새 세대로 오르지 않는다), 모두 합은 같다(잃지 않는다).
        var tt: u64 = 0;
        var ss: u64 = 0;
        var g: usize = max_gen + 1;
        while (g > 0) : (g -= 1) {
            tt += truth[g];
            ss += sent[g];
            if (ss > tt) {
                std.debug.print("B4-R12 판 {d}: 세대 ≥{d} 를 단 수 {d} > 그 세대들에서 센 수 {d}\n", .{ walks, g, ss, tt });
                return error.TestUnexpectedResult;
            }
            if (ss < tt) merged_down += 1;
        }
        tt += truth[0];
        ss += sent[0];
        try testing.expectEqual(tt, ss);
    }
    std.debug.print("B4-R12: 4000 판 통과(앞선 세대로 합쳐진 경계 {d} 곳 — 문서화된 버리는 쪽)\n", .{merged_down});
}

// ── 14 wire 23 — 무작위 걸음과 frame 경계 ───────────────────────────────────────────────────────────

fn eqHits(a: msg.NetBlockHits, b: msg.NetBlockHits) bool {
    if (a.browser != b.browser or a.generation != b.generation or a.unrecorded != b.unrecorded or a.skipped_unknown_page != b.skipped_unknown_page) return false;
    if (a.strict_redirect_missed != b.strict_redirect_missed or a.strict_redirect_bypassed != b.strict_redirect_bypassed or a.sw_shared_with_unruled_tab != b.sw_shared_with_unruled_tab or a.count != b.count) return false;
    for (a.entries[0..a.count], b.entries[0..b.count]) |x, y| if (x.rule_id != y.rule_id or x.hits != y.hits or x.sw_hits != y.sw_hits or x.sw_not_applied != y.sw_not_applied) return false;
    return true;
}

test "B4-R14: wire 23 무작위 걸음 3 만 — 받는 값이면 왕복이 같고, 모든 잘린 길이·한 바이트 덧붙임·길이 칸 ±1 은 거절한다(net_block·net_block_state·net_block_hits)" {
    var prng = std.Random.DefaultPrng.init(0xb4_14);
    const rnd = prng.random();
    var buf: [protocol.wire.max_frame_bytes + 8]u8 = undefined;
    const pats = [_][]const u8{ "https://a.test/api", "*://*.track.test/*", "http://127.0.0.1:5555/blk/*", "https://b.test/", "*://*/ads*" };
    const hosts = [_][]const u8{ "a.test", "b.test", "127.0.0.1", "x" };
    var accepted: usize = 0;
    var max_len: usize = 0;
    var i: usize = 0;
    while (i < 30_000) : (i += 1) {
        var m: msg.Message = undefined;
        switch (rnd.uintLessThan(u8, 3)) {
            0 => {
                var v: msg.NetBlock = .{ .browser = 1 + rnd.uintLessThan(u64, 1 << 40), .generation = rnd.int(u32), .count = rnd.uintLessThan(u8, 33) };
                if (rnd.boolean()) v.strict_site = hosts[rnd.uintLessThan(usize, hosts.len)];
                for (v.rules[0..v.count], 0..) |*r, k| r.* = .{ .id = @intCast(k + 1 + rnd.uintLessThan(u32, 3) * 100), .types = if (rnd.boolean()) 0 else @as(u32, 1) << rnd.uintLessThan(u5, 5), .site = hosts[rnd.uintLessThan(usize, hosts.len)], .pattern = pats[rnd.uintLessThan(usize, pats.len)] };
                m = .{ .net_block = v };
            },
            1 => m = .{ .net_block_state = .{ .browser = 1 + rnd.uintLessThan(u64, 1 << 40), .generation = rnd.int(u32), .ok = rnd.boolean(), .strict = @fromBackingInt(@intCast(rnd.uintLessThan(u8, 3))) } },
            else => {
                var h: msg.NetBlockHits = .{ .browser = 1 + rnd.uintLessThan(u64, 1 << 40), .generation = rnd.int(u32), .unrecorded = rnd.uintLessThan(u32, 3), .skipped_unknown_page = rnd.uintLessThan(u32, 2), .strict_redirect_missed = rnd.uintLessThan(u32, 2), .strict_redirect_bypassed = rnd.uintLessThan(u32, 2), .sw_shared_with_unruled_tab = rnd.boolean(), .count = rnd.uintLessThan(u8, 33) };
                for (h.entries[0..h.count], 0..) |*e, k| e.* = .{ .rule_id = @intCast(k + 1), .hits = if (rnd.boolean()) rnd.int(u32) else 0, .sw_hits = rnd.uintLessThan(u32, 2), .sw_not_applied = rnd.uintLessThan(u32, 2) };
                m = .{ .net_block_hits = h };
            },
        }
        const len = codec.encode(m, &buf) catch continue; // 닫힌 칸(빈 차이·0 수 항목·중복 번호·ok 거짓의 on 등) — 보내는 쪽이 거절
        accepted += 1;
        max_len = @max(max_len, len);
        const back = try codec.decodeExact(buf[0..len]);
        switch (m) {
            .net_block => |v| {
                const b = back.net_block;
                try testing.expect(b.browser == v.browser and b.generation == v.generation and b.count == v.count);
                try testing.expectEqualStrings(v.strict_site, b.strict_site);
                for (v.rules[0..v.count], b.rules[0..b.count]) |x, y| {
                    try testing.expect(x.id == y.id and x.types == y.types);
                    try testing.expectEqualStrings(x.site, y.site);
                    try testing.expectEqualStrings(x.pattern, y.pattern);
                }
            },
            .net_block_state => |v| try testing.expect(std.meta.eql(v, back.net_block_state)),
            .net_block_hits => |v| try testing.expect(eqHits(v, back.net_block_hits)),
            else => unreachable,
        }
        // 잘린 길이(머리 길이 칸 그대로) — 모두 거절.
        var cut = rnd.uintLessThan(usize, len);
        while (cut < len) : (cut += 1 + rnd.uintLessThan(usize, 7)) try testing.expect(std.meta.isError(codec.decodeExact(buf[0..cut])));
        // 덧붙인 한 바이트.
        buf[len] = rnd.int(u8);
        try testing.expect(std.meta.isError(codec.decodeExact(buf[0 .. len + 1])));
        // 길이 칸 ±1(같은 바이트 수) — 거절.
        const total = std.mem.readInt(u32, buf[0..4], .big);
        std.mem.writeInt(u32, buf[0..4], total +% 1, .big);
        try testing.expect(std.meta.isError(codec.decodeExact(buf[0..len])));
        std.mem.writeInt(u32, buf[0..4], total -% 1, .big);
        try testing.expect(std.meta.isError(codec.decodeExact(buf[0..len])));
    }
    std.debug.print("B4-R14 wire: 받은 {d} / 30000, 가장 큰 frame {d} B\n", .{ accepted, max_len });
    try testing.expect(accepted > 10_000);
}

// ── 20 비용 — 규칙이 많을 때 한 요청의 맞추기 ─────────────────────────────────────────────────────────

test "B4-R20 B-LOW-4: 한 요청의 맞추기 예산 — 별 많은 규칙 32 개 × 64 KiB 주소도 한 요청은 예산(규칙 하나의 최악 한 번)만큼만 훑고, 다 보지 못한 규칙은 막는 쪽, 짧은 주소는 그대로 정확하다" {
    const gpa = testing.allocator;
    var v: msg.NetBlock = .{ .browser = 7, .generation = 1, .count = 32 };
    var pat_bufs: [32][nb.max_pattern_bytes]u8 = undefined;
    for (v.rules[0..32], 0..) |*r, k| {
        // `*://*/a*a*a*a*a*zz<k>*b` — 끝 조각 `b` 는 맞고 가운데 `zz<k>` 가 없어 주소 끝까지 훑는다(가장 나쁜 꼴).
        const p = try std.fmt.bufPrint(&pat_bufs[k], "*://*/a*a*a*a*a*zz{d}*b", .{k});
        const norm = switch (nb.parse(p)) {
            .ok => |x| x.norm(),
            .err => return error.TestUnexpectedResult,
        };
        @memcpy(pat_bufs[k][0..norm.len], norm);
        r.* = .{ .id = @intCast(k + 1), .site = "a.test", .pattern = pat_bufs[k][0..norm.len] };
    }
    const c = try table_mod.compile(gpa, v);
    defer if (c.set) |s| gpa.destroy(s);
    const set = c.set.?;
    var a: table_mod.Acquired = .{ .set = set, .user_exempt = false };
    @memcpy(a.top_buf[0..6], "a.test");
    a.top_len = 6;
    const head = "https://a.test/";
    // 64 KiB 주소 — 첫 규칙이 예산을 거의 다 쓰고 둘째 규칙은 다 보지 못한다: 막는 쪽(규칙 2). 전에는 규칙 32 개가 저마다 끝까지 훑었다
    // (ReleaseFast 1.5 ms — 실제 CEF 에서 다른 탭의 fetch 가 98 → 539 ms).
    const url = try gpa.alloc(u16, 64 * 1024);
    defer gpa.free(url);
    for (head, 0..) |ch, k| url[k] = ch;
    for (url[head.len..], 0..) |*u, k| u.* = if (k % 3 == 0) 'a' else 'b';
    url[url.len - 1] = 'b';
    var budget: nb.Budget = .{};
    try testing.expectEqual(table_mod.Verdict{ .block = 2 }, table_mod.decideTabBudget(&a, url, 4, false, "a.test", &budget));
    try testing.expectEqual(@as(usize, 0), budget.left); // 쓴 것은 예산까지
    // 예산이 넉넉하면(모두 훑으면) 막지 않는다 — 넘치게 막는 것은 예산의 대가뿐이다.
    var unlimited: nb.Budget = .{ .left = std.math.maxInt(usize) };
    try testing.expectEqual(table_mod.Verdict.pass, table_mod.decideTabBudget(&a, url, 4, false, "a.test", &unlimited));
    // 짧은 주소(1 KiB) — 32 규칙을 모두 훑어도 예산 안이다: 정확하다(막지 않는다).
    const short = url[0..1024];
    short[short.len - 1] = 'b';
    try testing.expectEqual(table_mod.Verdict.pass, table_mod.decideTab(&a, short, 4, false, "a.test"));
    // 잠든 규칙(다른 사이트 페이지)은 주소를 훑지 않는다 — 예산을 쓰지 않는다.
    var b2: nb.Budget = .{};
    try testing.expectEqual(table_mod.Verdict.pass, table_mod.decideTabBudget(&a, url, 4, false, "b.test", &b2));
    try testing.expectEqual(nb.request_scan_budget, b2.left);
    // 시간: 한 요청은 예산만큼 — 규칙 32 개의 64 KiB 주소도 넉넉히 50 ms 안(디버그). 전에는 규칙 수만큼 늘었다.
    const t0 = nowNs();
    for (0..4) |_| _ = table_mod.decideTab(&a, url, 4, false, "a.test");
    const per = (nowNs() - t0) / 4;
    try testing.expect(per < 50 * std.time.ns_per_ms);
    // 서비스 워커 길도 같은 예산(모든 탭이 한 요청에 함께 쓴다) — 사이트를 덮지 않는 규칙은 훑지 않는다.
    const parts = nb.splitUrl(u16, url).?;
    var b3: nb.Budget = .{};
    try testing.expect(table_mod.serviceWorkerRule(set, parts, &.{"b.test"}, &b3) == null);
    try testing.expectEqual(nb.request_scan_budget, b3.left);
    try testing.expectEqual(@as(u32, 2), table_mod.serviceWorkerRule(set, parts, &.{"a.test"}, &b3).?.id);
    try testing.expect(table_mod.serviceWorkerRule(set, parts, &.{"a.test"}, &b3).?.id == 1); // 예산이 다했다 — 첫 규칙부터 막는 쪽
}

fn nowNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}
