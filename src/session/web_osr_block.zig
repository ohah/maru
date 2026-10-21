//! Chromium 탭의 요청 막기 규칙과 엄격 모드를 maru 가 쥐는 자리(W9d③ — docs/plans/web-osr-backend.md 「W9d③ 결정·실측」) — L2 순수.
//!
//! 탭 하나에 규칙은 모두 32 개(pane 마다 주인이 다르다 — 다른 pane 의 규칙은 수만 보인다). 규칙은 정규형 패턴(`net_block`)·종류 마스크·**사이트**
//! (추가한 때의 페이지 호스트 — 에이전트 탭, 또는 grant 호스트 — 사용자 탭: 그 사이트의 페이지에서만 일한다)를 쥔다. 엄격 모드(그 탭·그 사이트의
//! 서비스 워커 우회)는 탭에 하나 — 켠 pane 이 주인이다. 바뀔 때마다 세대(`gen`)가 오르고 web_osr 가 sidecar 에 **통째로** 보낸다(`net_block` —
//! 다시 보내도 같다, sidecar 가 다시 뜨면 재생 이동 앞에). 수(`hits`·`sw_hits`·`sw_not_applied`)는 sidecar 가 차이로 보내 여기서 누적한다(규칙을
//! 지우면 함께 사라진다). 주인의 block grant 가 사라지거나 그 호스트가 규칙의 사이트를 더 덮지 않거나 주인의 네트워크 grant 가 사라지면 그 규칙·
//! 엄격은 버린다(`sync` — 계획 §2·§10).
//!
//! 시험이 증명하는 것: add(정규형으로 같으면 already, 32 개 넘음은 too_many_rules — 몇 번째인지), remove(패턴·번호, 남의 규칙은 지우지 못한다 —
//! unknown_rule), clear(제 규칙만 — 엄격은 그대로), 엄격 켬·끔(사이트에 묶임), 초당 10 번(resource_busy), sync 의 버림 표, sidecar 상태·수의 누적,
//! wire 꼴(`net_block` 의 닫힌 칸을 지난다), 결과 JSON(다른 pane 은 수만, 설정이 꺼지면 서비스 워커 수를 숨긴다, 경고).

const std = @import("std");
const ws = @import("web_sidecar/root.zig");
const cpg = @import("control_pane_grant.zig");

const nb = ws.net_block;
const msg = ws.message;
const policy = ws.net_policy;

pub const max_rules = nb.max_rules;
/// 탭마다 1 초에 받는 바꾸기 수(계획 §3·§12 P2-5 — 통째 바꾸기마다 sidecar 가 패턴을 다시 푼다).
pub const max_changes_per_s: usize = 10;

pub const Rule = struct {
    id: u32,
    /// 규칙을 둔 pane(그 pane 의 block grant 가 사라지면 함께 사라진다).
    owner: u64,
    pattern_buf: [nb.max_pattern_bytes]u8 = undefined,
    pattern_len: u16 = 0,
    types: u32 = 0,
    site: cpg.GrantHost = .{},
    hits: u64 = 0,
    sw_hits: u64 = 0,
    sw_not_applied: u64 = 0,

    pub fn pattern(self: *const Rule) []const u8 {
        return self.pattern_buf[0..self.pattern_len];
    }
};

pub const StrictState = enum { off, sent, on, failed };

pub const Action = enum { add, remove, clear, list, strict };

/// 한 번의 `browser.networkBlock`(정규형 인자 — control_browser 가 이미 풀었다).
pub const Call = struct {
    owner: u64,
    action: Action,
    patterns: []const []const u8 = &.{},
    types: u32 = 0,
    rules: []const u32 = &.{},
    on: ?bool = null,
    /// add·엄격 켬의 사이트(소문자 호스트) — 빈 글이면 http(s) 페이지가 아니다(`no_site`).
    site: []const u8 = "",
    now_ms: i64 = 0,
};

/// 거절의 까닭(`{"reason","message","index"?}` 로 간다 — control_browser 가 코드를 고른다).
pub const Failure = struct { reason: []const u8, message: []const u8, index: ?usize = null };

pub const IdList = struct {
    ids: [max_rules]u32 = undefined,
    len: usize = 0,

    fn push(self: *IdList, id: u32) void {
        if (self.len == self.ids.len) return;
        self.ids[self.len] = id;
        self.len += 1;
    }

    pub fn slice(self: *const IdList) []const u32 {
        return self.ids[0..self.len];
    }
};

pub const Outcome = struct {
    added: IdList = .{},
    already: IdList = .{},
    removed: IdList = .{},
    changed: bool = false,
};

/// 그 탭의 block grant 하나(`sync` — 주인 pane·어느 호스트든·묶인 호스트).
pub const OwnerGrant = struct { pane: u64, any_host: bool = false, host: []const u8 = "" };

pub const Tab = struct {
    rules: std.ArrayList(Rule) = .empty,
    next_id: u32 = 1,
    strict_on: bool = false,
    strict_owner: u64 = 0,
    strict_site: cpg.GrantHost = .{},
    strict_state: StrictState = .off,
    /// 바뀔 때마다 오른다 — sidecar 의 답(`net_block_state`)이 그 세대를 싣는다.
    gen: u32 = 0,
    sent_gen: u32 = 0,
    acked_gen: u32 = 0,
    acked_ok: bool = true,
    unrecorded: u64 = 0,
    skipped_unknown_page: u64 = 0,
    /// 엄격 모드의 사이트 묶기가 리다이렉트로 어긋난 문서 수(sidecar 가 센다 — 20 회 검증 A MED-1: 엄격 사이트로 들어온 리다이렉트는 서비스 워커가
    /// 다스리는 채 닿고, 엄격 사이트에서 나간 리다이렉트는 다른 사이트의 서비스 워커를 건너뛴 채 닿는다 — Chromium 은 우회 값을 이동이 시작할 때만
    /// 읽는다). 말없이 두지 않고 결과(`strict.redirects_not_covered`·`redirects_bypassed_other_site`)에 싣는다.
    strict_redirect_missed: u64 = 0,
    strict_redirect_bypassed: u64 = 0,
    /// 이 세대보다 앞선 sidecar 수는 버린다(모두 버린 뒤 늦게 온 수 — 20 회 검증 B N4: 지켜보기가 끝나 지운 뒤 온 수가 `unrecorded` 에 쌓여 규칙을
    /// 다시 넣으면 보였다). 탭이 비면 올린다(`clearAll`·`sync`·`clear` — 2 차 검증 NEW-3: grant 철회로 규칙이 사라진 길은 올리지 않아 다음 pane 의
    /// 결과에 옛 수가 보였다).
    hits_floor: u32 = 0,
    /// 엄격의 리다이렉트 수는 이 세대부터 받는다(엄격이 꺼진 세대 — 2 차 검증 N-a: 끈 뒤에도 수·경고·CLI 줄이 남았다).
    strict_floor: u32 = 0,
    /// 이 문서에서 sidecar 가 「적용 안 됨」 을 알렸다(새 문서마다 지운다 — `newDocument`).
    sw_shared_doc: bool = false,
    changes: [max_changes_per_s]i64 = @splat(std.math.minInt(i64) / 2),
    change_next: usize = 0,
    /// 사용자에게 알린 세대(탭·세대마다 한 번 — `wantsNotice`).
    noticed_gen: u32 = 0,
    /// 걸린 알림(창이 꺼내 보인다 — `takeNotice`). 탭이 비면(철회·지우기) 거둔다 — 그 알림의 규칙은 사라졌다(2 차 검증 N-e; 3 차 검증 N-B3-c: 같은
    /// 틱에 다른 pane 이 규칙을 넣으면 옛 알림이 보이고 다음 몸짓에 새 세대의 알림이 또 떠 둘이었다).
    notice_pending: bool = false,

    pub fn deinit(self: *Tab, gpa: std.mem.Allocator) void {
        self.rules.deinit(gpa);
        self.* = .{};
    }

    /// 규칙이나 엄격이 있다(탭 제목의 ⊘ — 잠든 규칙만 있어도: 「이 탭에 규칙이 있다」, sidecar 확인 전에도).
    pub fn active(self: *const Tab) bool {
        return self.rules.items.len > 0 or self.strict_on;
    }

    pub fn ownerRules(self: *const Tab, owner: u64) usize {
        var n: usize = 0;
        for (self.rules.items) |r| n += @intFromBool(r.owner == owner);
        return n;
    }

    fn bump(self: *Tab) void {
        self.gen +%= 1;
        if (self.gen == 0) self.gen = 1;
        // 새 세대는 다시 보낸다 — 앞 세대의 `failed` 는 이 세대의 것이 아니다(2 차 검증 N-d: 규칙은 `sent` 인데 엄격은 `failed` 로 남았다).
        if (self.strict_on and self.strict_state == .failed) self.strict_state = .sent;
    }

    /// 탭에 남은 것이 없다 — 수는 버린 규칙·엄격의 것이니 지우고, 지금 세대보다 앞선 늦은 수는 버린다(`clearAll`·`sync`·`clear` 가 함께 쓴다 — 2 차
    /// 검증 NEW-3).
    fn forgetCounts(self: *Tab, floor: u32) void {
        self.notice_pending = false;
        self.unrecorded = 0;
        self.skipped_unknown_page = 0;
        self.strict_redirect_missed = 0;
        self.strict_redirect_bypassed = 0;
        self.sw_shared_doc = false;
        self.hits_floor = floor;
    }

    /// 엄격이 꺼졌다 — 그 리다이렉트 수는 엄격의 것이다(지우고 그 세대 앞의 늦은 수는 버린다). `bump` 뒤에 부른다.
    fn strictGone(self: *Tab) void {
        self.strict_redirect_missed = 0;
        self.strict_redirect_bypassed = 0;
        self.strict_floor = self.gen;
    }

    /// `browser.agent-network-full` 이 꺼졌다 — 켜졌을 때만 보이는 수(서비스 워커 길·다른 사이트 리다이렉트)를 지운다(2 차 검증 NEW-2 — W9d② 가
    /// 끔에 본문을 지우는 것과 같다; 꺼진 동안은 `onHits` 가 받지 않는다).
    pub fn forgetFullCounts(self: *Tab) void {
        for (self.rules.items) |*r| {
            r.sw_hits = 0;
            r.sw_not_applied = 0;
        }
        self.strict_redirect_bypassed = 0;
        self.sw_shared_doc = false;
    }

    /// 1 초 안의 바꾸기가 상한 안인가(세지 않는다 — 받은 바꾸기만 `rateCharge` 가 센다: 거절된 바꾸기가 자리를 쓰면 에이전트가 고친 다음 호출이
    /// 까닭 없이 `resource_busy` 를 받았다 — 20 회 검증 B N2).
    fn rateRoom(self: *const Tab, now_ms: i64) bool {
        return now_ms - self.changes[self.change_next] >= 1000;
    }

    fn rateCharge(self: *Tab, now_ms: i64) void {
        self.changes[self.change_next] = now_ms;
        self.change_next = (self.change_next + 1) % max_changes_per_s;
    }

    fn findOwned(self: *Tab, owner: u64, id: u32) ?usize {
        for (self.rules.items, 0..) |r, i| if (r.owner == owner and r.id == id) return i;
        return null;
    }

    /// 한 번의 바꾸기·보기. 거절이면 `fail` 에 까닭.
    pub fn apply(self: *Tab, gpa: std.mem.Allocator, call: Call, fail: *Failure) error{ Rejected, OutOfMemory }!Outcome {
        var out: Outcome = .{};
        var strict_reset = false;
        const changes = call.action != .list;
        if (changes and !self.rateRoom(call.now_ms)) {
            fail.* = .{ .reason = "resource_busy", .message = "too many blocking changes on this tab — at most 10 a second" };
            return error.Rejected;
        }
        switch (call.action) {
            .list => {},
            .add => {
                const site = try siteOf(call.site, fail, "the tab is not showing an http(s) page — navigate first (rules work on the site they were added on)");
                // 먼저 자리를 본다 — 하나라도 넘치면 아무것도 넣지 않는다. 같은 호출 안의 같은 패턴(정규형)은 한 자리다(20 회 검증 B DEF-1: 31 개가
                // 있는 탭에 `[p, p]` 가 둘로 세여 too_many_rules — 넣었으면 하나였다).
                var new_count: usize = 0;
                for (call.patterns, 0..) |p, i| {
                    if (self.existing(call.owner, p, call.types, &site) != null) continue;
                    const earlier = for (call.patterns[0..i]) |q| {
                        if (std.mem.eql(u8, q, p)) break true;
                    } else false;
                    if (earlier) continue;
                    new_count += 1;
                    // `index` 는 넘치는 패턴의 자리(2 차 검증 N-b: 남은 자리 수를 실었다).
                    if (self.rules.items.len + new_count > max_rules) {
                        fail.* = .{ .reason = "too_many_rules", .message = "a tab holds at most 32 blocking rules (all panes together)", .index = i };
                        return error.Rejected;
                    }
                }
                for (call.patterns) |p| {
                    if (self.existing(call.owner, p, call.types, &site)) |id| {
                        // `already` 는 이 호출 전에 있던 것만, 한 번씩(2 차 검증 N-c: 같은 호출의 겹친 패턴이 방금 넣은 번호를 `already` 에 다시 실었다).
                        if (std.mem.indexOfScalar(u32, out.added.slice(), id) == null and std.mem.indexOfScalar(u32, out.already.slice(), id) == null) out.already.push(id);
                        continue;
                    }
                    var r: Rule = .{ .id = self.next_id, .owner = call.owner, .types = call.types, .site = site };
                    const n = @min(p.len, r.pattern_buf.len);
                    @memcpy(r.pattern_buf[0..n], p[0..n]);
                    r.pattern_len = @intCast(n);
                    try self.rules.append(gpa, r);
                    self.next_id +%= 1;
                    if (self.next_id == 0) self.next_id = 1;
                    out.added.push(r.id);
                    out.changed = true;
                }
            },
            .remove => {
                for (call.rules, 0..) |id, i| if (self.findOwned(call.owner, id) == null) {
                    fail.* = .{ .reason = "unknown_rule", .message = "no such rule of yours on this tab — list them with maru browser network-block --list", .index = i };
                    return error.Rejected;
                };
                var i: usize = 0;
                while (i < self.rules.items.len) {
                    const r = self.rules.items[i];
                    const by_id = std.mem.indexOfScalar(u32, call.rules, r.id) != null;
                    const by_pattern = for (call.patterns) |p| {
                        if (std.mem.eql(u8, p, r.pattern())) break true;
                    } else false;
                    if (r.owner == call.owner and (by_id or by_pattern)) {
                        out.removed.push(r.id);
                        _ = self.rules.orderedRemove(i);
                        out.changed = true;
                    } else i += 1;
                }
            },
            .clear => {
                var i: usize = 0;
                while (i < self.rules.items.len) {
                    if (self.rules.items[i].owner == call.owner) {
                        out.removed.push(self.rules.items[i].id);
                        _ = self.rules.orderedRemove(i);
                        out.changed = true;
                    } else i += 1;
                }
            },
            .strict => {
                const on = call.on orelse false;
                // 엄격 모드도 규칙처럼 켠 pane 의 것이다 — 다른 pane 은 끄지도 가져가지도 못한다(20 회 검증 B DEF-3: 끔에 주인 확인이 없어 다른 pane 이
                // 끄거나 다시 켜 주인이 됐고, 그 pane 이 grant 를 잃자 처음 pane 의 엄격이 사라졌다). 주인의 grant 가 사라지면 `sync` 가 거둔다.
                if (self.strict_on and self.strict_owner != call.owner) {
                    fail.* = .{ .reason = "other_pane", .message = "strict mode on this tab was turned on by another pane — only that pane can change it" };
                    return error.Rejected;
                }
                if (on) {
                    const site = try siteOf(call.site, fail, "the tab is not showing an http(s) page — navigate first (strict mode is bound to the site it was turned on on)");
                    if (!self.strict_on or !self.strict_site.eql(&site)) {
                        // 다른 사이트로 옮긴다 — 옛 사이트의 리다이렉트 수·경고는 그 사이트의 것이다(3 차 검증 N-B3-b: 끄지 않고 옮기면 남았다).
                        strict_reset = self.strict_on;
                        self.strict_on = true;
                        self.strict_owner = call.owner;
                        self.strict_site = site;
                        self.strict_state = .sent;
                        out.changed = true;
                    }
                } else if (self.strict_on) {
                    self.strict_on = false;
                    self.strict_owner = 0;
                    self.strict_site = .{};
                    self.strict_state = .off;
                    out.changed = true;
                }
            },
        }
        if (changes) self.rateCharge(call.now_ms);
        if (out.changed) {
            self.bump();
            if (call.action == .strict and (!self.strict_on or strict_reset)) self.strictGone();
            if (!self.active()) self.forgetCounts(self.gen);
        }
        return out;
    }

    /// add·엄격 켬의 사이트 — wire 의 호스트 검사(`net_fields.checkHost`)를 여기서 먼저 한다. 지나지 못하는 사이트를 받아 두면 그 탭의 `net_block`
    /// 이 영영 만들어지지 않는다(20 회 검증 B DEF-2: 254 바이트 호스트 — `GrantHost.init` 이 빈 값을 주고, 빈 사이트의 frame 은 codec 이 거절해
    /// 버려졌는데 보낸 것으로 적혀, 그 뒤 모든 바꾸기가 sidecar 에 가지 않았다 — 화면은 ⊘·「sent」 인데 막지 않았다).
    fn siteOf(text: []const u8, fail: *Failure, no_site_message: []const u8) error{Rejected}!cpg.GrantHost {
        if (text.len == 0) {
            fail.* = .{ .reason = "no_site", .message = no_site_message };
            return error.Rejected;
        }
        if (text.len > nb.max_host_bytes) {
            fail.* = .{ .reason = "page_host_too_long", .message = "this page's host is longer than 253 bytes — blocking cannot be bound to it" };
            return error.Rejected;
        }
        const site: cpg.GrantHost = .init(text);
        ws.net_fields.checkHost(site.slice()) catch {
            fail.* = .{ .reason = "page_host_invalid", .message = "this page's host cannot be used as a blocking site" };
            return error.Rejected;
        };
        return site;
    }

    fn existing(self: *const Tab, owner: u64, pattern: []const u8, types: u32, site: *const cpg.GrantHost) ?u32 {
        for (self.rules.items) |*r| if (r.owner == owner and r.types == types and r.site.eql(site) and std.mem.eql(u8, r.pattern(), pattern)) return r.id;
        return null;
    }

    /// 주인이 grant 를 잃은 규칙·엄격을 버린다 — 주인의 block grant 가 없거나(철회·pane 닫힘), 묶인 호스트가 규칙의 사이트를 더 덮지 않거나(다른
    /// 호스트로 다시 허용), 주인의 네트워크 grant 가 없다(`net_panes` — 막기는 네트워크 지켜보기 위에 선다). 바꿨으면 참.
    pub fn sync(self: *Tab, block_grants: []const OwnerGrant, net_panes: []const u64) bool {
        var changed = false;
        var i: usize = 0;
        while (i < self.rules.items.len) {
            const r = &self.rules.items[i];
            if (!keeps(block_grants, net_panes, r.owner, r.site.slice())) {
                _ = self.rules.orderedRemove(i);
                changed = true;
            } else i += 1;
        }
        var strict_dropped = false;
        if (self.strict_on and !keeps(block_grants, net_panes, self.strict_owner, self.strict_site.slice())) {
            self.strict_on = false;
            self.strict_owner = 0;
            self.strict_site = .{};
            self.strict_state = .off;
            changed = true;
            strict_dropped = true;
        }
        if (changed) {
            self.bump();
            if (strict_dropped) self.strictGone();
            if (!self.active()) self.forgetCounts(self.gen); // 2 차 검증 NEW-3 — clearAll 과 같다
        }
        return changed;
    }

    /// 모두 버린다(지켜보기가 끝났다 — 마지막 네트워크 grant 가 사라졌다·탭이 닫힌다).
    pub fn clearAll(self: *Tab) bool {
        // 수는 버린 규칙들의 것이다 — 규칙이 없어도 남은 수는 지운다(다음 규칙의 결과에 옛 수가 보이지 않게).
        if (!self.active()) {
            // 바꿀 것은 없지만 sidecar 가 지금 세대로 늦게 보낼 수도 버린다(다음 바꾸기의 세대부터 받는다).
            self.forgetCounts(if (self.gen +% 1 == 0) 1 else self.gen +% 1);
            return false;
        }
        self.rules.clearRetainingCapacity();
        const strict_was = self.strict_on;
        self.strict_on = false;
        self.strict_owner = 0;
        self.strict_site = .{};
        self.strict_state = .off;
        self.bump();
        if (strict_was) self.strictGone();
        self.forgetCounts(self.gen);
        return true;
    }

    /// sidecar 가 다시 떴다 — 지금 세대를 다시 보낸다(확인 전에는 규칙도 엄격도 `sent` — 20 회 검증 B N3: 옛 프로세스의 `on` 이 남아 규칙의
    /// `sent` 와 어긋났다).
    pub fn resend(self: *Tab) void {
        self.sent_gen = 0;
        self.acked_gen = 0;
        if (self.strict_on) self.strict_state = .sent;
    }

    /// 지금 세대의 `net_block` 을 만들지 못했다(codec 이 거절 — 닿지 않아야 하는 갈래: 사이트는 넣을 때 검사한다). 보낸 것으로 적지 않고
    /// 결과에 `failed` 로 보인다(20 회 검증 B DEF-2 — 말없이 「sent」 로 남아 막지 않았다). 다음 바꾸기가 다시 해 본다.
    pub fn markUnsendable(self: *Tab) void {
        self.acked_gen = self.gen;
        self.acked_ok = false;
        if (self.strict_on) self.strict_state = .failed;
    }

    /// sidecar 의 답(`net_block_state`) — 그 세대의 것만.
    pub fn onState(self: *Tab, v: msg.NetBlockState) void {
        if (v.generation != self.gen) return;
        self.acked_gen = v.generation;
        self.acked_ok = v.ok;
        if (!self.strict_on) return;
        self.strict_state = switch (v.strict) {
            .on => .on,
            .failed => .failed,
            .off => if (v.ok) .sent else .failed,
        };
    }

    /// sidecar 의 수(차이) — 번호로 누적한다(지운 규칙의 늦은 수는 버린다). `full` — 설정 `browser.agent-network-full`: 꺼졌으면 켜졌을 때만
    /// 보이는 수(서비스 워커 길·「적용 안 됨」·다른 사이트 리다이렉트)를 **적지 않는다**(2 차 검증 NEW-2: 숨기기만 해 나중에 켜면 꺼진 동안의 수 —
    /// 사용자 탭 요청의 오라클 — 가 보였다; W9d① 은 sidecar 에서 덜고 W9d② 는 끔에 지운다).
    pub fn onHits(self: *Tab, v: msg.NetBlockHits, full: bool) void {
        if (genBefore(v.generation, self.hits_floor)) return; // 모두 버린 세대의 늦은 수(B N4)
        self.unrecorded +|= v.unrecorded;
        self.skipped_unknown_page +|= v.skipped_unknown_page;
        // 엄격의 리다이렉트 수는 엄격이 켜진 세대의 것만(2 차 검증 N-a).
        if (self.strict_on and !genBefore(v.generation, self.strict_floor)) {
            self.strict_redirect_missed +|= v.strict_redirect_missed;
            if (full) self.strict_redirect_bypassed +|= v.strict_redirect_bypassed;
        }
        if (full and v.sw_shared_with_unruled_tab) self.sw_shared_doc = true;
        for (v.entries[0..v.count]) |e| for (self.rules.items) |*r| if (r.id == e.rule_id) {
            r.hits +|= e.hits;
            if (full) {
                r.sw_hits +|= e.sw_hits;
                r.sw_not_applied +|= e.sw_not_applied;
            }
        };
    }

    /// 새 문서 — 「적용 안 됨」 표시는 문서마다다.
    pub fn newDocument(self: *Tab) void {
        self.sw_shared_doc = false;
    }

    /// 보낼 `net_block`(규칙의 글은 이 탭을 빌린다 — 보내기 전에 바꾸지 않는다).
    pub fn toWire(self: *const Tab, browser: u64) msg.NetBlock {
        var v: msg.NetBlock = .{ .browser = browser, .generation = self.gen, .strict_site = if (self.strict_on) self.strict_site.slice() else "" };
        for (self.rules.items) |*r| {
            if (v.count == v.rules.len) break;
            v.rules[v.count] = .{ .id = r.id, .types = r.types, .site = r.site.slice(), .pattern = r.pattern() };
            v.count += 1;
        }
        return v;
    }

    /// 사용자에게 알릴까(탭·규칙 세대마다 한 번) — 알렸다고 적고 알림을 건다(`takeNotice`).
    pub fn wantsNotice(self: *Tab) bool {
        if (!self.active() or self.noticed_gen == self.gen) return false;
        self.noticed_gen = self.gen;
        self.notice_pending = true;
        return true;
    }

    /// 걸린 알림을 꺼낸다(한 번). 걸린 뒤 탭이 비었으면 `forgetCounts` 가 이미 거뒀다 — 그 뒤 다른 pane 이 규칙을 넣었어도 옛 알림은 띄우지 않고 새
    /// 세대는 다음 몸짓이 알린다(N-B3-c — 한 번).
    pub fn takeNotice(self: *Tab) bool {
        defer self.notice_pending = false;
        return self.notice_pending and self.active();
    }

    /// 그 pane 의 규칙 번호·패턴(네트워크 기록의 `block_pattern` — 주인에게만).
    pub fn ownerPatterns(self: *const Tab, owner: u64, out: []ws_block_pattern) []ws_block_pattern {
        var n: usize = 0;
        for (self.rules.items) |*r| {
            if (r.owner != owner or n == out.len) continue;
            out[n] = .{ .id = r.id, .pattern = r.pattern() };
            n += 1;
        }
        return out[0..n];
    }

    /// 결과 JSON(`browser.networkBlock`) — 제 규칙은 모두, 다른 pane 의 규칙은 수만. 설정(`full`)이 꺼졌으면 서비스 워커 수를 숨기고 「규칙 없는
    /// 탭과 나눔」 참·거짓만(§12 P1-8 — 수가 사용자 요청의 오라클이 된다). `shared` — 같은 출처를 보이는 다른 탭이 규칙이 없다(web_osr 가 탭 집합으로).
    pub fn resultJson(self: *const Tab, out: std.mem.Allocator, owner: u64, outcome: Outcome, page_site: []const u8, full: bool, shared: bool) std.mem.Allocator.Error![]u8 {
        var aw: std.Io.Writer.Allocating = .init(out);
        defer aw.deinit();
        var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
        self.writeResult(&s, owner, outcome, page_site, full, shared) catch return error.OutOfMemory;
        return aw.toOwnedSlice();
    }

    fn writeResult(self: *const Tab, s: *std.json.Stringify, owner: u64, outcome: Outcome, page_site: []const u8, full: bool, shared: bool) !void {
        var other: usize = 0;
        var dormant = false;
        var typed = false;
        var not_applied: u64 = 0;
        try s.beginObject();
        try s.objectField("rules");
        try s.beginArray();
        for (self.rules.items) |*r| {
            if (r.owner != owner) {
                other += 1;
                continue;
            }
            try s.beginObject();
            try s.objectField("id");
            try s.write(r.id);
            try s.objectField("pattern");
            try s.write(r.pattern());
            if (r.types != 0) {
                var names: [24][]const u8 = undefined;
                try s.objectField("types");
                try s.write(nb.typeNames(r.types, &names));
                typed = true;
            }
            try s.objectField("site");
            try s.write(r.site.slice());
            try s.objectField("hits");
            try s.write(r.hits);
            if (full) {
                try s.objectField("sw_hits");
                try s.write(r.sw_hits);
                try s.objectField("sw_not_applied");
                try s.write(r.sw_not_applied);
            }
            if (page_site.len != 0 and !policy.hostCovers(r.site.slice(), page_site)) {
                try s.objectField("dormant");
                try s.write(true);
                dormant = true;
            }
            not_applied +|= r.sw_not_applied;
            try s.endObject();
        }
        try s.endArray();
        try s.objectField("other_rules");
        try s.write(other);
        try s.objectField("total");
        try s.write(self.rules.items.len);
        try s.objectField("max");
        try s.write(max_rules);
        if (outcome.added.len > 0) {
            try s.objectField("added");
            try s.write(outcome.added.slice());
        }
        if (outcome.already.len > 0) {
            try s.objectField("already");
            try s.write(outcome.already.slice());
        }
        if (outcome.removed.len > 0) {
            try s.objectField("removed");
            try s.write(outcome.removed.slice());
        }
        try s.objectField("state");
        try s.write(if (self.acked_gen != self.gen) "sent" else if (!self.acked_ok) "failed" else "active");
        try s.objectField("strict");
        try s.beginObject();
        try s.objectField("on");
        try s.write(self.strict_on);
        if (self.strict_on) {
            try s.objectField("site");
            try s.write(self.strict_site.slice());
            if (self.strict_owner != owner) {
                try s.objectField("other_pane");
                try s.write(true);
            }
        }
        try s.objectField("state");
        try s.write(@tagName(self.strict_state));
        try s.objectField("covers_cross_site_iframes");
        try s.write(false);
        // 리다이렉트로 엄격 사이트에 들어와 서비스 워커가 다스린 채 닿은 문서 수(그 문서에서는 엄격이 듣지 않았다 — 다음 이동부터) — 엄격이 켜진
        // 사이트 일이라 늘 싣는다. 다른 사이트의 일(엄격 사이트에서 나간 리다이렉트가 그 사이트의 서비스 워커를 건너뜀)은 설정이 켜졌을 때만.
        try s.objectField("redirects_not_covered");
        try s.write(self.strict_redirect_missed);
        if (full) {
            try s.objectField("redirects_bypassed_other_site");
            try s.write(self.strict_redirect_bypassed);
        }
        try s.endObject();
        try s.objectField("page_site");
        try s.write(page_site);
        try s.objectField("unrecorded");
        try s.write(self.unrecorded);
        try s.objectField("skipped_unknown_page");
        try s.write(self.skipped_unknown_page);
        const shared_any = shared or (full and self.sw_shared_doc);
        try s.objectField("service_worker");
        try s.beginObject();
        try s.objectField("shared_with_unruled_tab");
        try s.write(shared_any);
        if (full) {
            try s.objectField("not_applied_total");
            try s.write(not_applied);
        }
        try s.endObject();
        const redirect_gap = self.strict_redirect_missed > 0 or (full and self.strict_redirect_bypassed > 0);
        if (shared_any or dormant or typed or redirect_gap) {
            try s.objectField("warnings");
            try s.beginArray();
            if (shared_any) try s.write("service_worker_shared");
            if (dormant) try s.write("dormant_other_site");
            if (typed) try s.write("types_skip_service_worker");
            if (redirect_gap) try s.write("strict_redirect_gap");
            try s.endArray();
        }
        try s.endObject();
    }
};

const ws_block_pattern = @import("web_osr_network.zig").BlockPattern;

/// 세대 a 가 바닥 floor 보다 앞인가 — u32 가 돌아도(세대는 0 을 건너뛰며 돈다; 3 차 검증 N-A3-4: `<` 는 돈 뒤 늦은 수 거르기를 뒤집었다). 바닥 0 은
/// 「버린 것 없음」.
fn genBefore(a: u32, floor: u32) bool {
    if (floor == 0) return false;
    return @as(i32, @bitCast(a -% floor)) < 0;
}

fn keeps(block_grants: []const OwnerGrant, net_panes: []const u64, owner: u64, site: []const u8) bool {
    if (std.mem.indexOfScalar(u64, net_panes, owner) == null) return false;
    for (block_grants) |g| if (g.pane == owner) {
        if (g.any_host or policy.hostCovers(g.host, site)) return true;
    };
    return false;
}

// ── 시험 ────────────────────────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn mkCall(owner: u64, action: Action, opts: struct { patterns: []const []const u8 = &.{}, types: u32 = 0, rules: []const u32 = &.{}, on: ?bool = null, site: []const u8 = "a.test", now_ms: i64 = 0 }) Call {
    return .{ .owner = owner, .action = action, .patterns = opts.patterns, .types = opts.types, .rules = opts.rules, .on = opts.on, .site = opts.site, .now_ms = opts.now_ms };
}

test "W9d③: add — 정규형으로 같으면 already, 32 개 넘으면 아무것도 넣지 않고 too_many_rules, 사이트 없는 페이지는 no_site, 세대가 오른다" {
    var t: Tab = .{};
    defer t.deinit(testing.allocator);
    var fail: Failure = undefined;
    const a = try t.apply(testing.allocator, mkCall(5, .add, .{ .patterns = &.{ "https://a.test/x", "*://*.t.test/*" } }), &fail);
    try testing.expectEqualSlices(u32, &.{ 1, 2 }, a.added.slice());
    try testing.expectEqual(@as(u32, 1), t.gen);
    const b = try t.apply(testing.allocator, mkCall(5, .add, .{ .patterns = &.{"https://a.test/x"}, .now_ms = 1 }), &fail);
    try testing.expectEqualSlices(u32, &.{1}, b.already.slice());
    try testing.expect(!b.changed);
    try testing.expectEqual(@as(u32, 1), t.gen);
    // 다른 pane 의 같은 패턴은 따로다(그 pane 의 grant 에 묶인다).
    _ = try t.apply(testing.allocator, mkCall(6, .add, .{ .patterns = &.{"https://a.test/x"}, .now_ms = 2 }), &fail);
    try testing.expectEqual(@as(usize, 3), t.rules.items.len);
    try testing.expectError(error.Rejected, t.apply(testing.allocator, mkCall(5, .add, .{ .patterns = &.{"https://b.test/"}, .site = "", .now_ms = 3 }), &fail));
    try testing.expectEqualStrings("no_site", fail.reason);
    var many: [30][]const u8 = undefined;
    var bufs: [30][32]u8 = undefined;
    for (&many, 0..) |*m, i| m.* = std.fmt.bufPrint(&bufs[i], "https://a.test/{d}", .{i}) catch unreachable;
    try testing.expectError(error.Rejected, t.apply(testing.allocator, mkCall(5, .add, .{ .patterns = &many, .now_ms = 4 }), &fail));
    try testing.expectEqualStrings("too_many_rules", fail.reason);
    try testing.expectEqual(@as(usize, 3), t.rules.items.len); // 하나도 넣지 않았다
    try testing.expect(t.active());
}

test "W9d③: remove·clear — 남의 규칙은 지우지 못하고(unknown_rule — 몇 번째), 패턴·번호로, clear 는 제 규칙만(엄격은 그대로)" {
    var t: Tab = .{};
    defer t.deinit(testing.allocator);
    var fail: Failure = undefined;
    _ = try t.apply(testing.allocator, mkCall(5, .add, .{ .patterns = &.{ "https://a.test/x", "https://a.test/y" } }), &fail);
    _ = try t.apply(testing.allocator, mkCall(6, .add, .{ .patterns = &.{"https://a.test/z"}, .now_ms = 1 }), &fail);
    _ = try t.apply(testing.allocator, mkCall(5, .strict, .{ .on = true, .now_ms = 2 }), &fail);
    try testing.expectError(error.Rejected, t.apply(testing.allocator, mkCall(5, .remove, .{ .rules = &.{ 1, 3 }, .now_ms = 3 }), &fail));
    try testing.expectEqualStrings("unknown_rule", fail.reason);
    try testing.expectEqual(@as(?usize, 1), fail.index);
    const r = try t.apply(testing.allocator, mkCall(5, .remove, .{ .patterns = &.{"https://a.test/y"}, .now_ms = 4 }), &fail);
    try testing.expectEqualSlices(u32, &.{2}, r.removed.slice());
    const c = try t.apply(testing.allocator, mkCall(5, .clear, .{ .now_ms = 5 }), &fail);
    try testing.expectEqualSlices(u32, &.{1}, c.removed.slice());
    try testing.expectEqual(@as(usize, 1), t.rules.items.len); // pane 6 의 것은 남는다
    try testing.expect(t.strict_on); // clear 는 엄격을 끄지 않는다
}

test "W9d③: 엄격 — 켜면 사이트에 묶이고 sent, 같은 것을 다시 켜면 바뀌지 않는다, 끄면 off, sidecar 의 답(그 세대만)으로 on·failed" {
    var t: Tab = .{};
    defer t.deinit(testing.allocator);
    var fail: Failure = undefined;
    _ = try t.apply(testing.allocator, mkCall(5, .strict, .{ .on = true }), &fail);
    try testing.expect(t.strict_on and t.strict_state == .sent);
    try testing.expectEqualStrings("a.test", t.strict_site.slice());
    t.onState(.{ .browser = 1, .generation = t.gen + 1, .ok = true, .strict = .on }); // 다른 세대 — 버린다
    try testing.expect(t.strict_state == .sent);
    t.onState(.{ .browser = 1, .generation = t.gen, .ok = true, .strict = .on });
    try testing.expect(t.strict_state == .on);
    const again = try t.apply(testing.allocator, mkCall(5, .strict, .{ .on = true, .now_ms = 1 }), &fail);
    try testing.expect(!again.changed);
    t.onState(.{ .browser = 1, .generation = t.gen, .ok = true, .strict = .failed });
    try testing.expect(t.strict_state == .failed);
    _ = try t.apply(testing.allocator, mkCall(5, .strict, .{ .on = false, .now_ms = 2 }), &fail);
    try testing.expect(!t.strict_on and t.strict_state == .off and !t.active());
    try testing.expectError(error.Rejected, t.apply(testing.allocator, mkCall(5, .strict, .{ .on = true, .site = "", .now_ms = 3 }), &fail));
    try testing.expectEqualStrings("no_site", fail.reason);
}

test "W9d③: 초당 10 번 — 열한째 바꾸기는 resource_busy, 보기(list)는 세지 않는다, 1 초 뒤 다시" {
    var t: Tab = .{};
    defer t.deinit(testing.allocator);
    var fail: Failure = undefined;
    for (0..10) |i| _ = try t.apply(testing.allocator, mkCall(5, .strict, .{ .on = i % 2 == 0, .now_ms = 100 }), &fail);
    try testing.expectError(error.Rejected, t.apply(testing.allocator, mkCall(5, .clear, .{ .now_ms = 500 }), &fail));
    try testing.expectEqualStrings("resource_busy", fail.reason);
    _ = try t.apply(testing.allocator, mkCall(5, .list, .{ .now_ms = 500 }), &fail);
    _ = try t.apply(testing.allocator, mkCall(5, .clear, .{ .now_ms = 1100 }), &fail);
}

test "W9d③: sync — 주인의 block grant·네트워크 grant 가 사라지거나 묶인 호스트가 사이트를 더 덮지 않으면 규칙·엄격을 버린다" {
    var t: Tab = .{};
    defer t.deinit(testing.allocator);
    var fail: Failure = undefined;
    _ = try t.apply(testing.allocator, mkCall(5, .add, .{ .patterns = &.{"https://a.test/x"}, .site = "app.a.test" }), &fail);
    _ = try t.apply(testing.allocator, mkCall(6, .add, .{ .patterns = &.{"https://a.test/y"}, .site = "bank.test", .now_ms = 1 }), &fail);
    _ = try t.apply(testing.allocator, mkCall(6, .strict, .{ .on = true, .site = "bank.test", .now_ms = 2 }), &fail);
    const grants = [_]OwnerGrant{ .{ .pane = 5, .host = "a.test" }, .{ .pane = 6, .any_host = true } };
    try testing.expect(!t.sync(&grants, &.{ 5, 6 })); // 모두 덮인다
    try testing.expect(t.sync(&grants, &.{5})); // pane 6 의 네트워크 grant 가 사라졌다
    try testing.expectEqual(@as(usize, 1), t.rules.items.len);
    try testing.expect(!t.strict_on);
    try testing.expect(t.sync(&.{.{ .pane = 5, .host = "other.test" }}, &.{5})); // 다른 호스트로 다시 허용
    try testing.expect(!t.active());
}

test "W9d③: 수는 sidecar 의 차이를 번호로 누적한다, 결과 JSON — 다른 pane 은 수만, 설정 끔이면 서비스 워커 수를 숨긴다, 경고, wire 꼴은 닫힌 칸을 지난다" {
    var t: Tab = .{};
    defer t.deinit(testing.allocator);
    var fail: Failure = undefined;
    _ = try t.apply(testing.allocator, mkCall(5, .add, .{ .patterns = &.{"*://*.t.test/*"} }), &fail);
    _ = try t.apply(testing.allocator, mkCall(5, .add, .{ .patterns = &.{"https://a.test/img/*"}, .types = nb.typeBits("image").?, .site = "b.test", .now_ms = 1 }), &fail);
    _ = try t.apply(testing.allocator, mkCall(6, .add, .{ .patterns = &.{"https://a.test/z"}, .now_ms = 2 }), &fail);
    var h: msg.NetBlockHits = .{ .browser = 1, .unrecorded = 2, .sw_shared_with_unruled_tab = true, .count = 2 };
    h.entries[0] = .{ .rule_id = 1, .hits = 3, .sw_not_applied = 4 };
    h.entries[1] = .{ .rule_id = 99, .hits = 1 }; // 지운 규칙의 늦은 수 — 버린다
    t.onHits(h, true);
    t.onHits(h, true);
    try testing.expectEqual(@as(u64, 6), t.rules.items[0].hits);
    try testing.expectEqual(@as(u64, 4), t.unrecorded);
    var wire_buf: [ws.wire.max_frame_bytes]u8 = undefined;
    _ = try ws.codec.encode(.{ .net_block = t.toWire(7) }, &wire_buf);
    for ([_]bool{ true, false }) |full| {
        const json = try t.resultJson(testing.allocator, 5, .{}, "a.test", full, false);
        defer testing.allocator.free(json);
        const p = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
        defer p.deinit();
        const o = p.value.object;
        try testing.expectEqual(@as(usize, 2), o.get("rules").?.array.items.len);
        try testing.expectEqual(@as(i64, 1), o.get("other_rules").?.integer);
        try testing.expectEqual(@as(i64, 3), o.get("total").?.integer);
        try testing.expectEqualStrings("sent", o.get("state").?.string);
        const r0 = o.get("rules").?.array.items[0].object;
        try testing.expectEqual(full, r0.get("sw_not_applied") != null);
        try testing.expectEqual(full, o.get("service_worker").?.object.get("not_applied_total") != null);
        // 설정 끔 — sidecar 의 표시(요청이 고른다)가 아니라 탭 집합만으로(`shared` 거짓) 나눔을 말한다.
        try testing.expectEqual(full, o.get("service_worker").?.object.get("shared_with_unruled_tab").?.bool);
        const r1 = o.get("rules").?.array.items[1].object;
        try testing.expect(r1.get("dormant").?.bool); // b.test 사이트 — a.test 페이지에서 잠든다
        try testing.expectEqualStrings("image", r1.get("types").?.array.items[0].string);
        const warns = o.get("warnings").?.array.items;
        try testing.expect(warns.len >= 2);
    }
    t.newDocument();
    try testing.expect(!t.sw_shared_doc);
    t.onState(.{ .browser = 1, .generation = t.gen, .ok = true });
    const json = try t.resultJson(testing.allocator, 5, .{}, "a.test", true, false);
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"state\":\"active\"") != null);
    try testing.expect(t.wantsNotice());
    try testing.expect(!t.wantsNotice()); // 세대마다 한 번
}

test "W9d③ 변이: 32 개째까지 받고 이미 있는 패턴은 자리를 세지 않는다, 패턴으로 지우기는 제 규칙만, 엄격을 다른 사이트에서 다시 켜면 그 사이트로, 패턴 목록은 주인 것만, 페이지를 모르면 잠듦 표시 없음, 적용 못 한 세대는 failed" {
    var t: Tab = .{};
    defer t.deinit(testing.allocator);
    var fail: Failure = undefined;
    var pats: [max_rules][]const u8 = undefined;
    var bufs: [max_rules][32]u8 = undefined;
    for (&pats, 0..) |*p, i| p.* = std.fmt.bufPrint(&bufs[i], "https://a.test/{d}", .{i}) catch unreachable;
    const full = try t.apply(testing.allocator, mkCall(5, .add, .{ .patterns = &pats }), &fail);
    try testing.expectEqual(@as(usize, max_rules), full.added.len); // 32 개째도 받는다
    const again = try t.apply(testing.allocator, mkCall(5, .add, .{ .patterns = pats[0..1], .now_ms = 1000 }), &fail); // 찼어도 이미 있는 것은 already
    try testing.expectEqualSlices(u32, &.{1}, again.already.slice());
    try testing.expectError(error.Rejected, t.apply(testing.allocator, mkCall(5, .add, .{ .patterns = &.{"https://a.test/new"}, .now_ms = 2000 }), &fail));
    try testing.expectEqualStrings("too_many_rules", fail.reason);
    _ = try t.apply(testing.allocator, mkCall(5, .clear, .{ .now_ms = 3000 }), &fail);
    // 같은 패턴을 두 pane 이 두었다 — 패턴으로 지우면 제 것만.
    _ = try t.apply(testing.allocator, mkCall(5, .add, .{ .patterns = &.{"https://a.test/x"}, .now_ms = 4000 }), &fail);
    _ = try t.apply(testing.allocator, mkCall(6, .add, .{ .patterns = &.{"https://a.test/x"}, .now_ms = 5000 }), &fail);
    const rm = try t.apply(testing.allocator, mkCall(5, .remove, .{ .patterns = &.{"https://a.test/x"}, .now_ms = 6000 }), &fail);
    try testing.expectEqual(@as(usize, 1), rm.removed.len);
    try testing.expectEqual(@as(usize, 1), t.rules.items.len);
    try testing.expectEqual(@as(u64, 6), t.rules.items[0].owner);
    // 패턴 목록(`block_pattern`)은 그 pane 의 규칙만.
    var bp: [max_rules]ws_block_pattern = undefined;
    try testing.expectEqual(@as(usize, 0), t.ownerPatterns(5, &bp).len);
    try testing.expectEqual(@as(usize, 1), t.ownerPatterns(6, &bp).len);
    // 엄격 — 같은 pane 이 다른 사이트에서 다시 켜면 그 사이트로 묶인다(세대가 올라 sidecar 에 다시 간다).
    _ = try t.apply(testing.allocator, mkCall(5, .strict, .{ .on = true, .site = "a.test", .now_ms = 7000 }), &fail);
    const moved = try t.apply(testing.allocator, mkCall(5, .strict, .{ .on = true, .site = "b.test", .now_ms = 8000 }), &fail);
    try testing.expect(moved.changed);
    try testing.expectEqualStrings("b.test", t.strict_site.slice());
    // sidecar 가 그 세대를 적용하지 못했다(ok 거짓 — 엄격도 없다) — failed.
    t.onState(.{ .browser = 1, .generation = t.gen, .ok = false, .strict = .off });
    try testing.expect(t.strict_state == .failed);
    // 페이지를 모르면(빈 사이트) 잠듦을 말하지 않는다.
    const json = try t.resultJson(testing.allocator, 6, .{}, "", true, false);
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "dormant") == null);
}

// ── W9d③ 20 회 적대 검증 11–20 회차(검증자 B — 재현이 고친 뒤의 답을 고정한다) ──

test "W9d③ v20b R14a DEF-1: 한 번의 add 에 같은 패턴이 둘 — 31 개가 있으면 하나만 들어간다(같은 정규형 둘을 새 자리 둘로 세지 않는다)" {
    var t: Tab = .{};
    defer t.deinit(testing.allocator);
    var fail: Failure = undefined;
    var pats: [31][]const u8 = undefined;
    var bufs: [31][32]u8 = undefined;
    for (&pats, 0..) |*p, i| p.* = std.fmt.bufPrint(&bufs[i], "https://a.test/{d}", .{i}) catch unreachable;
    _ = try t.apply(testing.allocator, mkCall(5, .add, .{ .patterns = &pats }), &fail);
    try testing.expectEqual(@as(usize, 31), t.rules.items.len);
    // 대조: 다른 패턴 둘은 33 개라 거절이 맞다.
    try testing.expectError(error.Rejected, t.apply(testing.allocator, mkCall(5, .add, .{ .patterns = &.{ "https://a.test/x", "https://a.test/y" }, .now_ms = 2000 }), &fail));
    // 같은 패턴 둘 — 32 개째 하나만 들어갈 자리가 있다.
    const r = t.apply(testing.allocator, mkCall(5, .add, .{ .patterns = &.{ "https://a.test/x", "https://a.test/x" }, .now_ms = 4000 }), &fail);
    if (r) |out| {
        try testing.expectEqual(@as(usize, 1), out.added.len);
        try testing.expectEqual(@as(usize, 0), out.already.len); // 방금 넣은 번호는 already 가 아니다(2 차 검증 N-c)
        try testing.expectEqual(@as(usize, 32), t.rules.items.len);
    } else |_| return error.V20bDupOvercount;
}

test "W9d③ v20b R14b N2: 초당 10 번 — 거절된 바꾸기(no_site·unknown_rule)는 자리를 쓰지 않는다, 경계 999·1000 ms" {
    var t: Tab = .{};
    defer t.deinit(testing.allocator);
    var fail: Failure = undefined;
    // 경계: 같은 시각 10 번 → 11 번째는 999 ms 뒤 거절, 1000 ms 뒤 허용.
    for (0..10) |_| _ = try t.apply(testing.allocator, mkCall(5, .clear, .{ .now_ms = 10_000 }), &fail);
    try testing.expectError(error.Rejected, t.apply(testing.allocator, mkCall(5, .clear, .{ .now_ms = 10_999 }), &fail));
    try testing.expectEqualStrings("resource_busy", fail.reason);
    _ = try t.apply(testing.allocator, mkCall(5, .clear, .{ .now_ms = 11_000 }), &fail);
    // 거절된 바꾸기 10 번(사이트 없음) 뒤 정상 add — 자리를 썼다면 resource_busy.
    var u: Tab = .{};
    defer u.deinit(testing.allocator);
    for (0..10) |_| try testing.expectError(error.Rejected, u.apply(testing.allocator, mkCall(5, .add, .{ .patterns = &.{"https://a.test/"}, .site = "", .now_ms = 50_000 }), &fail));
    _ = try u.apply(testing.allocator, mkCall(5, .add, .{ .patterns = &.{"https://a.test/"}, .now_ms = 50_001 }), &fail);
    for (0..10) |_| try testing.expectError(error.Rejected, u.apply(testing.allocator, mkCall(5, .remove, .{ .rules = &.{99}, .now_ms = 50_002 }), &fail));
    try testing.expectEqualStrings("unknown_rule", fail.reason);
    // 받은 바꾸기는 센다 — 9 번 더(모두 10) 뒤 열한째는 resource_busy.
    for (0..9) |_| _ = try u.apply(testing.allocator, mkCall(5, .clear, .{ .now_ms = 50_003 }), &fail);
    try testing.expectError(error.Rejected, u.apply(testing.allocator, mkCall(5, .clear, .{ .now_ms = 50_004 }), &fail));
    try testing.expectEqualStrings("resource_busy", fail.reason);
}

test "W9d③ v20b R16a DEF-3: 엄격은 켠 pane 의 것 — 다른 pane 은 끄지도 가져가지도 못하고(other_pane), 그 pane 이 grant 를 잃어도 남는다, 주인이 잃으면 사라진다" {
    var t: Tab = .{};
    defer t.deinit(testing.allocator);
    var fail: Failure = undefined;
    _ = try t.apply(testing.allocator, mkCall(5, .add, .{ .patterns = &.{"https://a.test/x"} }), &fail);
    _ = try t.apply(testing.allocator, mkCall(5, .strict, .{ .on = true, .now_ms = 1 }), &fail);
    // 대조: pane 6 의 clear 는 pane 5 의 규칙·엄격을 건드리지 않는다.
    const c = try t.apply(testing.allocator, mkCall(6, .clear, .{ .now_ms = 2 }), &fail);
    try testing.expect(!c.changed and t.rules.items.len == 1 and t.strict_on and t.strict_owner == 5);
    // pane 6 이 결과에서 other_pane 을 본다.
    const j = try t.resultJson(testing.allocator, 6, .{}, "a.test", true, false);
    defer testing.allocator.free(j);
    try testing.expect(std.mem.indexOf(u8, j, "\"other_pane\":true") != null);
    // pane 6 의 strict off — 거절(other_pane), 그대로.
    const g0 = t.gen;
    try testing.expectError(error.Rejected, t.apply(testing.allocator, mkCall(6, .strict, .{ .on = false, .now_ms = 3 }), &fail));
    try testing.expectEqualStrings("other_pane", fail.reason);
    try testing.expect(t.strict_on and t.strict_owner == 5 and t.gen == g0);
    // pane 6 이 켜서 주인을 가져가지 못한다.
    try testing.expectError(error.Rejected, t.apply(testing.allocator, mkCall(6, .strict, .{ .on = true, .now_ms = 5 }), &fail));
    try testing.expect(t.strict_owner == 5);
    // pane 6 이 grant 를 잃어도 pane 5 의 엄격은 남는다.
    try testing.expect(!t.sync(&.{.{ .pane = 5, .any_host = true }}, &.{5}));
    try testing.expect(t.strict_on and t.strict_owner == 5);
    // 주인(pane 5)은 끌 수 있고, 꺼진 뒤에는 다른 pane 이 켤 수 있다(주인이 된다).
    _ = try t.apply(testing.allocator, mkCall(5, .strict, .{ .on = false, .now_ms = 6 }), &fail);
    _ = try t.apply(testing.allocator, mkCall(6, .strict, .{ .on = true, .now_ms = 7 }), &fail);
    try testing.expect(t.strict_on and t.strict_owner == 6);
    // 주인이 grant 를 잃으면 사라진다.
    try testing.expect(t.sync(&.{.{ .pane = 5, .any_host = true }}, &.{5}));
    try testing.expect(!t.strict_on);
}

test "W9d③ v20b R16b: remove 에 제 번호와 남의 번호를 섞으면 아무것도 지우지 않는다(원자성), 패턴 지우기는 사이트·종류가 달라도 제 것 모두" {
    var t: Tab = .{};
    defer t.deinit(testing.allocator);
    var fail: Failure = undefined;
    _ = try t.apply(testing.allocator, mkCall(5, .add, .{ .patterns = &.{"https://a.test/x"} }), &fail); // 1
    _ = try t.apply(testing.allocator, mkCall(6, .add, .{ .patterns = &.{"https://a.test/y"}, .now_ms = 1 }), &fail); // 2
    _ = try t.apply(testing.allocator, mkCall(5, .add, .{ .patterns = &.{"https://a.test/x"}, .types = nb.typeBits("image").?, .now_ms = 2 }), &fail); // 3 (같은 패턴, 종류 다름)
    _ = try t.apply(testing.allocator, mkCall(5, .add, .{ .patterns = &.{"https://a.test/x"}, .site = "b.test", .now_ms = 3 }), &fail); // 4 (같은 패턴, 사이트 다름)
    try testing.expectEqual(@as(usize, 4), t.rules.items.len);
    try testing.expectError(error.Rejected, t.apply(testing.allocator, mkCall(5, .remove, .{ .rules = &.{ 1, 2 }, .now_ms = 4 }), &fail));
    try testing.expectEqualStrings("unknown_rule", fail.reason);
    try testing.expectEqual(@as(?usize, 1), fail.index);
    try testing.expectEqual(@as(usize, 4), t.rules.items.len); // 하나도 지우지 않았다
    const r = try t.apply(testing.allocator, mkCall(5, .remove, .{ .patterns = &.{"https://a.test/x"}, .now_ms = 5 }), &fail);
    try testing.expectEqualSlices(u32, &.{ 1, 3, 4 }, r.removed.slice());
    try testing.expectEqual(@as(usize, 1), t.rules.items.len);
    try testing.expectEqual(@as(u64, 6), t.rules.items[0].owner);
    // 없는 패턴 지우기 — 오류 없이 아무것도(번호와 다르다).
    const none = try t.apply(testing.allocator, mkCall(5, .remove, .{ .patterns = &.{"https://zzz.test/"}, .now_ms = 6 }), &fail);
    try testing.expect(!none.changed and none.removed.len == 0);
}

test "W9d③ v20b R12a: sync — 엄격 주인만 네트워크 grant 를 잃으면 엄격만, 규칙 주인만 잃으면 그 규칙만, 둘 다 있으면 바뀌지 않는다(대조)" {
    var t: Tab = .{};
    defer t.deinit(testing.allocator);
    var fail: Failure = undefined;
    _ = try t.apply(testing.allocator, mkCall(5, .add, .{ .patterns = &.{"https://a.test/x"} }), &fail);
    _ = try t.apply(testing.allocator, mkCall(6, .strict, .{ .on = true, .now_ms = 1 }), &fail);
    const both = [_]OwnerGrant{ .{ .pane = 5, .host = "a.test" }, .{ .pane = 6, .host = "a.test" } };
    const g0 = t.gen;
    try testing.expect(!t.sync(&both, &.{ 5, 6 }));
    try testing.expectEqual(g0, t.gen); // 대조: 세대가 오르지 않는다(다시 보내지 않는다)
    try testing.expect(t.sync(&both, &.{5}));
    try testing.expect(!t.strict_on and t.rules.items.len == 1 and t.strict_state == .off);
    _ = try t.apply(testing.allocator, mkCall(6, .strict, .{ .on = true, .now_ms = 2 }), &fail);
    try testing.expect(t.sync(&both, &.{6}));
    try testing.expect(t.strict_on and t.rules.items.len == 0);
    // 하위 도메인 grant 는 상위 사이트 규칙을 덮지 않는다(규칙 사이트 a.test, grant app.a.test).
    _ = try t.apply(testing.allocator, mkCall(5, .add, .{ .patterns = &.{"https://a.test/z"}, .now_ms = 3 }), &fail);
    try testing.expect(t.sync(&.{ .{ .pane = 5, .host = "app.a.test" }, .{ .pane = 6, .host = "a.test" } }, &.{ 5, 6 }));
    try testing.expectEqual(@as(usize, 0), t.rules.items.len);
}

test "W9d③ v20b R13a: 설정 끔(full 거짓) — 규칙마다 sw 수·합계가 빠지고, sidecar 의 문서 표시(sw_shared_doc)는 나눔을 말하지 않는다, 탭 집합(shared)만 말한다" {
    var t: Tab = .{};
    defer t.deinit(testing.allocator);
    var fail: Failure = undefined;
    _ = try t.apply(testing.allocator, mkCall(5, .add, .{ .patterns = &.{"https://a.test/sw/*"} }), &fail);
    var h: msg.NetBlockHits = .{ .browser = 1, .sw_shared_with_unruled_tab = true, .count = 1 };
    h.entries[0] = .{ .rule_id = 1, .hits = 1, .sw_hits = 7, .sw_not_applied = 9 };
    t.onHits(h, true);
    for ([_]bool{ false, true }) |shared| {
        const j = try t.resultJson(testing.allocator, 5, .{}, "a.test", false, shared);
        defer testing.allocator.free(j);
        try testing.expect(std.mem.indexOf(u8, j, "sw_hits") == null);
        try testing.expect(std.mem.indexOf(u8, j, "sw_not_applied") == null);
        try testing.expect(std.mem.indexOf(u8, j, "not_applied_total") == null);
        try testing.expect(std.mem.indexOf(u8, j, "\"7\"") == null and std.mem.indexOf(u8, j, ":9") == null);
        const want = if (shared) "\"shared_with_unruled_tab\":true" else "\"shared_with_unruled_tab\":false";
        try testing.expect(std.mem.indexOf(u8, j, want) != null);
        try testing.expectEqual(shared, std.mem.indexOf(u8, j, "service_worker_shared") != null);
    }
    // 대조: 켬이면 수가 보이고 문서 표시가 나눔을 말한다.
    const j = try t.resultJson(testing.allocator, 5, .{}, "a.test", true, false);
    defer testing.allocator.free(j);
    try testing.expect(std.mem.indexOf(u8, j, "\"sw_not_applied\":9") != null and std.mem.indexOf(u8, j, "\"shared_with_unruled_tab\":true") != null);
}

test "W9d③ v20b R14c DEF-2: 사이트가 253 바이트를 넘는 페이지(에이전트 탭) — add·엄격 켬은 page_host_too_long 으로 거절하고 아무것도 넣지 않는다, wire 꼴이 늘 닫힌 칸을 지난다" {
    var t: Tab = .{};
    defer t.deinit(testing.allocator);
    var fail: Failure = undefined;
    const ar = @import("array_repeat");
    const long = ar.repeat("a", 60) ++ "." ++ ar.repeat("b", 60) ++ "." ++ ar.repeat("c", 60) ++ "." ++ ar.repeat("d", 61) ++ ".localhost"; // 254 바이트 — 253 넘음
    try testing.expect(long.len > 253);
    try testing.expectError(error.Rejected, t.apply(testing.allocator, mkCall(5, .add, .{ .patterns = &.{"http://127.0.0.1/x"}, .site = long }), &fail));
    try testing.expectEqualStrings("page_host_too_long", fail.reason);
    try testing.expectError(error.Rejected, t.apply(testing.allocator, mkCall(5, .strict, .{ .on = true, .site = long, .now_ms = 1 }), &fail));
    try testing.expectEqualStrings("page_host_too_long", fail.reason);
    try testing.expect(t.rules.items.len == 0 and !t.strict_on and t.gen == 0);
    // wire 검사가 거절하는 글자의 호스트도(page_host_invalid) — 넣으면 그 탭의 net_block 이 만들어지지 않는다.
    try testing.expectError(error.Rejected, t.apply(testing.allocator, mkCall(5, .add, .{ .patterns = &.{"http://127.0.0.1/x"}, .site = "a b.test", .now_ms = 2 }), &fail));
    try testing.expectEqualStrings("page_host_invalid", fail.reason);
    // 대조: 정상 사이트는 받고 wire 꼴이 만들어진다.
    _ = try t.apply(testing.allocator, mkCall(5, .add, .{ .patterns = &.{"http://127.0.0.1/y"}, .site = "a.test", .now_ms = 3 }), &fail);
    _ = try t.apply(testing.allocator, mkCall(5, .strict, .{ .on = true, .site = "a.test", .now_ms = 4 }), &fail);
    var wire_buf: [ws.wire.max_frame_bytes]u8 = undefined;
    _ = try ws.codec.encode(.{ .net_block = t.toWire(7) }, &wire_buf);
    // 만들지 못한 세대(닿지 않아야 하는 갈래)는 결과에 failed 로 보인다 — 보낸 것으로 적지 않는다.
    t.markUnsendable();
    try testing.expect(t.strict_state == .failed);
    const j = try t.resultJson(testing.allocator, 5, .{}, "a.test", true, false);
    defer testing.allocator.free(j);
    try testing.expect(std.mem.indexOf(u8, j, "\"state\":\"failed\"") != null);
}

test "W9d③ 20 회 검증 B N3·N4, A MED-1: 모두 버린 세대의 늦은 수는 버린다, sidecar 가 다시 뜨면 엄격도 sent, 엄격의 리다이렉트 어긋남 수를 싣는다(설정 끔이면 다른 사이트 쪽은 숨김)" {
    var t: Tab = .{};
    defer t.deinit(testing.allocator);
    var fail: Failure = undefined;
    _ = try t.apply(testing.allocator, mkCall(5, .add, .{ .patterns = &.{"https://a.test/x"} }), &fail);
    _ = try t.apply(testing.allocator, mkCall(5, .strict, .{ .on = true, .now_ms = 1 }), &fail);
    const g_live = t.gen;
    t.onState(.{ .browser = 1, .generation = g_live, .ok = true, .strict = .on });
    try testing.expect(t.strict_state == .on);
    // N3: 다시 뜸 — 확인 전에는 규칙도 엄격도 sent.
    t.resend();
    try testing.expect(t.strict_state == .sent and t.sent_gen == 0 and t.acked_gen == 0);
    t.onState(.{ .browser = 1, .generation = g_live, .ok = true, .strict = .on });
    // MED-1: 엄격의 리다이렉트 어긋남.
    t.onHits(.{ .browser = 1, .generation = g_live, .unrecorded = 2, .strict_redirect_missed = 1, .strict_redirect_bypassed = 3 }, true);
    const full = try t.resultJson(testing.allocator, 5, .{}, "a.test", true, false);
    defer testing.allocator.free(full);
    try testing.expect(std.mem.indexOf(u8, full, "\"redirects_not_covered\":1") != null and std.mem.indexOf(u8, full, "\"redirects_bypassed_other_site\":3") != null);
    try testing.expect(std.mem.indexOf(u8, full, "strict_redirect_gap") != null);
    const off = try t.resultJson(testing.allocator, 5, .{}, "a.test", false, false);
    defer testing.allocator.free(off);
    try testing.expect(std.mem.indexOf(u8, off, "\"redirects_not_covered\":1") != null and std.mem.indexOf(u8, off, "redirects_bypassed_other_site") == null);
    // N4: 지켜보기가 끝나 모두 버렸다 — 수도 지운다, 그 뒤 옛 세대로 온 수는 버린다.
    try testing.expect(t.clearAll());
    try testing.expect(t.unrecorded == 0 and t.strict_redirect_missed == 0);
    t.onHits(.{ .browser = 1, .generation = g_live, .unrecorded = 4 }, true);
    try testing.expectEqual(@as(u64, 0), t.unrecorded);
    // 다시 규칙을 넣은 세대의 수는 받는다.
    _ = try t.apply(testing.allocator, mkCall(5, .add, .{ .patterns = &.{"https://a.test/y"}, .now_ms = 2 }), &fail);
    t.onHits(.{ .browser = 1, .generation = t.gen, .unrecorded = 1 }, true);
    try testing.expectEqual(@as(u64, 1), t.unrecorded);
    // 규칙이 없을 때 지워도 지금 세대의 늦은 수는 버린다.
    var u: Tab = .{};
    defer u.deinit(testing.allocator);
    u.gen = 7;
    try testing.expect(!u.clearAll());
    u.onHits(.{ .browser = 1, .generation = 7, .unrecorded = 5 }, true);
    try testing.expectEqual(@as(u64, 0), u.unrecorded);
}

// ── W9d③ 2 차 20 회 검증 11–20 회차(검증자 B2 — 6077ecc4c 를 다시 친 시험을 고친 뒤의 답으로 단언) ──

test "W9d③ v20b2 R14 DEF-1·N-b·N-c: 한 호출 안의 같은 패턴 — 이미 있는 것·새것·셋 겹침, 다른 pane, 거절 index 는 넘치는 패턴의 자리, already 는 앞서 있던 것만 한 번" {
    var t: Tab = .{};
    defer t.deinit(testing.allocator);
    var fail: Failure = undefined;
    var pats: [31][]const u8 = undefined;
    var bufs: [31][32]u8 = undefined;
    for (&pats, 0..) |*p, i| p.* = std.fmt.bufPrint(&bufs[i], "https://a.test/{d}", .{i}) catch unreachable;
    _ = try t.apply(testing.allocator, mkCall(5, .add, .{ .patterns = &pats }), &fail);
    // [이미 있는 것, 새것, 새것(같음), 이미 있는 것] — 새 자리 하나: 받는다.
    const a = try t.apply(testing.allocator, mkCall(5, .add, .{ .patterns = &.{ "https://a.test/0", "https://a.test/n", "https://a.test/n", "https://a.test/0" }, .now_ms = 2000 }), &fail);
    try testing.expectEqual(@as(usize, 1), a.added.len);
    try testing.expectEqual(@as(usize, 32), t.rules.items.len);
    try testing.expectEqualSlices(u32, &.{32}, a.added.slice());
    try testing.expectEqualSlices(u32, &.{1}, a.already.slice()); // 겹친 새것(32)도, 두 번 쓴 1 도 한 번만
    // 꽉 찼다 — [이미 있는 것, 새것] 은 거절. index 는 몇인가(넘치는 것은 1 번째 패턴).
    try testing.expectError(error.Rejected, t.apply(testing.allocator, mkCall(5, .add, .{ .patterns = &.{ "https://a.test/0", "https://a.test/z" }, .now_ms = 4000 }), &fail));
    try testing.expectEqualStrings("too_many_rules", fail.reason);
    try testing.expectEqual(@as(?usize, 1), fail.index);
    // 대조: 꽉 찬 탭에 이미 있는 것만 둘 — already.
    const b = try t.apply(testing.allocator, mkCall(5, .add, .{ .patterns = &.{ "https://a.test/0", "https://a.test/0" }, .now_ms = 6000 }), &fail);
    try testing.expect(!b.changed and std.mem.eql(u32, b.already.slice(), &.{1})); // 한 번씩(N-c)
    // 다른 pane 의 같은 패턴 둘 — 그 pane 에는 새 자리 하나(탭이 찼으니 거절).
    try testing.expectError(error.Rejected, t.apply(testing.allocator, mkCall(6, .add, .{ .patterns = &.{ "https://a.test/0", "https://a.test/0" }, .now_ms = 8000 }), &fail));
    try testing.expectEqualStrings("too_many_rules", fail.reason);
    // 31 개에서 pane 6 의 같은 패턴 둘 — 하나만 들어간다.
    _ = try t.apply(testing.allocator, mkCall(5, .remove, .{ .rules = &.{1}, .now_ms = 10_000 }), &fail);
    const c = try t.apply(testing.allocator, mkCall(6, .add, .{ .patterns = &.{ "https://a.test/0", "https://a.test/0" }, .now_ms = 12_000 }), &fail);
    try testing.expectEqual(@as(usize, 1), c.added.len);
    try testing.expectEqual(@as(usize, 32), t.rules.items.len);
}

test "W9d③ v20b2 R14 N2: 거절된 바꾸기(other_pane·page_host_too_long·page_host_invalid·too_many_rules·unknown_rule·no_site)는 1 초 10 번 자리를 쓰지 않는다, 받은 것은 이미 있던 add 도 센다" {
    var t: Tab = .{};
    defer t.deinit(testing.allocator);
    var fail: Failure = undefined;
    const long = @import("array_repeat").repeat("a", 250) ++ ".test"; // 255 바이트
    _ = try t.apply(testing.allocator, mkCall(5, .strict, .{ .on = true, .now_ms = 0 }), &fail); // 받음 1
    const rejects = [_]Call{
        mkCall(6, .strict, .{ .on = false, .now_ms = 100 }),
        mkCall(6, .strict, .{ .on = true, .now_ms = 100 }),
        mkCall(5, .add, .{ .patterns = &.{"https://a.test/"}, .site = long, .now_ms = 100 }),
        mkCall(5, .add, .{ .patterns = &.{"https://a.test/"}, .site = "a!b.test", .now_ms = 100 }),
        mkCall(5, .strict, .{ .on = true, .site = long, .now_ms = 100 }),
        mkCall(5, .remove, .{ .rules = &.{77}, .now_ms = 100 }),
        mkCall(5, .add, .{ .patterns = &.{"https://a.test/"}, .site = "", .now_ms = 100 }),
    };
    for (0..3) |_| for (rejects) |c| {
        try testing.expectError(error.Rejected, t.apply(testing.allocator, c, &fail));
    };
    // 받은 바꾸기 9 번 더(이미 있는 add 포함) — 모두 받는다.
    _ = try t.apply(testing.allocator, mkCall(5, .add, .{ .patterns = &.{"https://a.test/k"}, .now_ms = 200 }), &fail);
    for (0..8) |_| {
        const o = try t.apply(testing.allocator, mkCall(5, .add, .{ .patterns = &.{"https://a.test/k"}, .now_ms = 200 }), &fail);
        try testing.expect(!o.changed);
    }
    // 열한째(받은 것 10 개 뒤) — resource_busy.
    try testing.expectError(error.Rejected, t.apply(testing.allocator, mkCall(5, .clear, .{ .now_ms = 300 }), &fail));
    try testing.expectEqualStrings("resource_busy", fail.reason);
}

test "W9d③ v20b2 R14 DEF-2: 페이지 호스트 경계 — 253 받음·254·255·256 page_host_too_long, 대문자는 소문자로, punycode·IPv6·IPv4·밑줄·끝 점 받음, wire 가 거절하는 글자는 page_host_invalid, 받은 사이트는 늘 frame 이 된다" {
    const ar = @import("array_repeat");
    const h253 = ar.repeat("a", 63) ++ "." ++ ar.repeat("b", 63) ++ "." ++ ar.repeat("c", 63) ++ "." ++ ar.repeat("d", 51) ++ ".localhost";
    try testing.expectEqual(@as(usize, 253), h253.len);
    const Case = struct { site: []const u8, want: ?[]const u8 };
    const cases = [_]Case{
        .{ .site = h253, .want = null },
        .{ .site = h253 ++ ".", .want = "page_host_too_long" },
        .{ .site = h253 ++ "xy", .want = "page_host_too_long" },
        .{ .site = h253 ++ "xyz", .want = "page_host_too_long" },
        .{ .site = "APP.Test", .want = null },
        .{ .site = "xn--3e0b707e.localhost", .want = null },
        .{ .site = "[::1]", .want = null },
        .{ .site = "127.0.0.1", .want = null },
        .{ .site = "a_b.test", .want = null },
        .{ .site = "localhost.", .want = null },
        .{ .site = "a!b.test", .want = "page_host_invalid" },
        .{ .site = "a~b.test", .want = "page_host_invalid" },
        .{ .site = "a$b.test", .want = "page_host_invalid" },
        .{ .site = "a%20b.test", .want = "page_host_invalid" },
        .{ .site = "한국.test", .want = "page_host_invalid" },
        .{ .site = "a\x00b", .want = "page_host_invalid" },
    };
    var wire_buf: [ws.wire.max_frame_bytes]u8 = undefined;
    for (cases, 0..) |c, i| {
        for ([_]Action{ .add, .strict }) |act| {
            var t: Tab = .{};
            defer t.deinit(testing.allocator);
            var fail: Failure = undefined;
            const call = if (act == .add) mkCall(5, .add, .{ .patterns = &.{"http://127.0.0.1/x"}, .site = c.site }) else mkCall(5, .strict, .{ .on = true, .site = c.site });
            const r = t.apply(testing.allocator, call, &fail);
            if (c.want) |w| {
                try testing.expectError(error.Rejected, r);
                testing.expectEqualStrings(w, fail.reason) catch |e| {
                    std.debug.print("v20b2 R14 DEF-2 case {d} ({s}) {s}: got {s}\n", .{ i, c.site, @tagName(act), fail.reason });
                    return e;
                };
                try testing.expect(!t.active() and t.gen == 0);
            } else {
                _ = try r;
                const n = ws.codec.encode(.{ .net_block = t.toWire(7) }, &wire_buf) catch |e| {
                    std.debug.print("v20b2 R14 DEF-2 case {d} ({s}) {s}: accepted but encode {s}\n", .{ i, c.site, @tagName(act), @errorName(e) });
                    return e;
                };
                const back = try ws.codec.decodeExact(wire_buf[0..n]);
                const site = if (act == .add) back.net_block.rules[0].site else back.net_block.strict_site;
                var lower: [300]u8 = undefined;
                try testing.expectEqualStrings(std.ascii.lowerString(&lower, c.site), site);
            }
        }
    }
}

test "W9d③ v20b2 R14 DEF-2 모형: 무작위 6 만 걸음(add·remove·clear·list·strict·sync·clearAll·resend·state·hits, 이상한 사이트 포함) — 받은 상태는 늘 frame 이 되고 왕복하며, 거절은 아무것도 바꾸지 않고(세대·규칙·엄격·바꾸기 자리), 1 초 10 번은 받은 바꾸기의 참조 모형과 같다" {
    const gpa = testing.allocator;
    const ar = @import("array_repeat");
    const h253 = ar.repeat("a", 63) ++ "." ++ ar.repeat("b", 63) ++ "." ++ ar.repeat("c", 63) ++ "." ++ ar.repeat("d", 51) ++ ".localhost";
    const sites = [_][]const u8{ "a.test", "b.test", "sub.a.test", h253, h253 ++ ".", "APP.test", "[::1]", "127.0.0.1", "a.test.", "", "a b.test", "a!b.test", "xn--3e0b707e.localhost" };
    // 정규형 패턴 풀(control_browser 처럼 net_block.parse 로).
    const raw = [_][]const u8{ "https://a.test/x", "*://*.t.test/*", "http://127.0.0.1:8080/v/*", "https://[::1]/a?b", "*://*/f*a*b*c*d*e*g", "HTTPS://A.TEST:443/%2f", "https://a.test", "*://a.test" };
    var norm_bufs: [raw.len + 1 + 40][nb.max_pattern_bytes]u8 = undefined;
    var pool: [raw.len + 1 + 40][]const u8 = undefined;
    for (0..40) |i| {
        var tb: [64]u8 = undefined;
        const p = nb.parse(std.fmt.bufPrint(&tb, "https://a.test/p{d}/*", .{i}) catch unreachable).ok;
        @memcpy(norm_bufs[raw.len + 1 + i][0..p.norm().len], p.norm());
        pool[raw.len + 1 + i] = norm_bufs[raw.len + 1 + i][0..p.norm().len];
    }
    for (raw, 0..) |r, i| {
        const p = nb.parse(r).ok;
        @memcpy(norm_bufs[i][0..p.norm().len], p.norm());
        pool[i] = norm_bufs[i][0..p.norm().len];
    }
    {
        var long: [512]u8 = undefined;
        @memcpy(long[0..15], "https://a.test/");
        @memset(long[15..], 'q');
        const p = nb.parse(&long).ok;
        @memcpy(norm_bufs[raw.len][0..p.norm().len], p.norm());
        pool[raw.len] = norm_bufs[raw.len][0..p.norm().len];
    }
    const type_names = [_][]const u8{ "image", "script", "xhr", "stylesheet", "font" };
    var prng = std.Random.DefaultPrng.init(0x20b2_14de);
    const rnd = prng.random();
    var t: Tab = .{};
    defer t.deinit(gpa);
    var now: i64 = 0;
    var accepted: std.ArrayList(i64) = .empty;
    defer accepted.deinit(gpa);
    var wire_buf: [ws.wire.max_frame_bytes]u8 = undefined;
    var counts: [8]usize = @splat(0); // ok · busy · site · rules · unknown · other_pane · encodes · rejected-unchanged
    var step: usize = 0;
    while (step < 60_000) : (step += 1) {
        now += rnd.intRangeAtMost(i64, 0, 160);
        const pick = rnd.uintLessThan(u32, 100);
        if (pick < 3) {
            var grants: [3]OwnerGrant = undefined;
            var gn: usize = 0;
            var panes: [3]u64 = undefined;
            var pn: usize = 0;
            for ([_]u64{ 5, 6, 7 }) |pane| {
                if (rnd.boolean()) {
                    grants[gn] = if (rnd.boolean()) .{ .pane = pane, .any_host = true } else .{ .pane = pane, .host = sites[rnd.uintLessThan(usize, 4)] };
                    gn += 1;
                }
                if (rnd.uintLessThan(u8, 4) != 0) {
                    panes[pn] = pane;
                    pn += 1;
                }
            }
            _ = t.sync(grants[0..gn], panes[0..pn]);
        } else if (pick < 4) {
            _ = t.clearAll();
        } else if (pick < 9) {
            t.resend();
        } else if (pick < 13) {
            t.onState(.{ .browser = 1, .generation = if (rnd.boolean()) t.gen else t.gen -% 1, .ok = rnd.boolean(), .strict = if (rnd.boolean()) .on else .off });
        } else if (pick < 17) {
            var h: msg.NetBlockHits = .{ .browser = 1, .generation = t.gen -% rnd.uintLessThan(u32, 3), .unrecorded = rnd.uintLessThan(u32, 3), .count = 1 };
            h.entries[0] = .{ .rule_id = rnd.intRangeAtMost(u32, 1, 40), .hits = 1 };
            t.onHits(h, true);
        } else {
            const owner: u64 = 5 + rnd.uintLessThan(u64, 3);
            const ap = rnd.uintLessThan(u8, 100);
            const action: Action = if (ap < 55) .add else if (ap < 65) .remove else if (ap < 67) .clear else if (ap < 77) .list else .strict;
            var pats: [6][]const u8 = undefined;
            const np = rnd.intRangeAtMost(usize, 1, 6);
            for (pats[0..np]) |*p| p.* = pool[rnd.uintLessThan(usize, pool.len)];
            var ids: [3]u32 = undefined;
            const ni = rnd.intRangeAtMost(usize, 1, 3);
            for (ids[0..ni]) |*id| id.* = rnd.intRangeAtMost(u32, 1, t.next_id + 1);
            var types: u32 = 0;
            if (rnd.uintLessThan(u8, 3) == 0) types = nb.typeBits(type_names[rnd.uintLessThan(usize, type_names.len)]).?;
            const call: Call = .{
                .owner = owner,
                .action = action,
                .patterns = if (action == .add or (action == .remove and rnd.boolean())) pats[0..np] else &.{},
                .rules = if (action == .remove) ids[0..ni] else &.{},
                .types = if (action == .add) types else 0,
                .on = if (action == .strict) rnd.boolean() else null,
                .site = sites[rnd.uintLessThan(usize, sites.len)],
                .now_ms = now,
            };
            const before_gen = t.gen;
            const before_len = t.rules.items.len;
            const before_strict = .{ t.strict_on, t.strict_owner, t.strict_state };
            const before_rate = t.changes;
            const before_next = t.change_next;
            // 참조 모형: 1 초 안의 받은 바꾸기 수.
            var recent: usize = 0;
            for (accepted.items) |ts| recent += @intFromBool(now - ts < 1000);
            var fail: Failure = undefined;
            if (t.apply(gpa, call, &fail)) |_| {
                counts[0] += 1;
                if (action != .list) {
                    try testing.expect(recent < 10);
                    try accepted.append(gpa, now);
                }
            } else |e| {
                try testing.expect(e == error.Rejected);
                if (std.mem.eql(u8, fail.reason, "resource_busy")) {
                    counts[1] += 1;
                    try testing.expect(recent >= 10);
                } else if (std.mem.startsWith(u8, fail.reason, "page_host") or std.mem.eql(u8, fail.reason, "no_site")) counts[2] += 1 else if (std.mem.eql(u8, fail.reason, "too_many_rules")) counts[3] += 1 else if (std.mem.eql(u8, fail.reason, "unknown_rule")) counts[4] += 1 else if (std.mem.eql(u8, fail.reason, "other_pane")) counts[5] += 1 else return error.UnexpectedReason;
                if (!std.mem.eql(u8, fail.reason, "resource_busy")) try testing.expect(recent < 10);
                try testing.expect(t.gen == before_gen and t.rules.items.len == before_len);
                try testing.expect(t.strict_on == before_strict[0] and t.strict_owner == before_strict[1] and t.strict_state == before_strict[2]);
                try testing.expect(std.mem.eql(i64, &t.changes, &before_rate) and t.change_next == before_next);
                counts[7] += 1;
            }
        }
        // 불변식.
        try testing.expect(t.rules.items.len <= max_rules);
        try testing.expectEqual(t.strict_on, t.strict_owner != 0);
        if (t.strict_on) try testing.expect(t.strict_site.len > 0);
        for (t.rules.items, 0..) |r, i| for (t.rules.items[0..i]) |q| try testing.expect(q.id != r.id);
        const n = ws.codec.encode(.{ .net_block = t.toWire(1) }, &wire_buf) catch |e| {
            std.debug.print("v20b2 model step {d}: reachable state does not encode: {s}\n", .{ step, @errorName(e) });
            return e;
        };
        _ = try ws.codec.decodeExact(wire_buf[0..n]);
        counts[6] += 1;
    }
    try testing.expect(counts[1] > 0 and counts[2] > 0 and counts[3] > 0 and counts[5] > 0);
}

test "W9d③ v20b2 R16 DEF-3: 엄격의 주인 — 다른 pane 은 다른 사이트로도 켜지 못하고 끄지 못한다, clear·remove 는 엄격을 건드리지 않는다, 주인이 다른 사이트로 옮긴다, 꺼진 뒤에는 누구든, sync 로 주인이 사라지면 다른 pane 이 켠다" {
    var t: Tab = .{};
    defer t.deinit(testing.allocator);
    var fail: Failure = undefined;
    _ = try t.apply(testing.allocator, mkCall(5, .strict, .{ .on = true, .site = "a.test" }), &fail);
    for ([_]Call{
        mkCall(6, .strict, .{ .on = true, .site = "b.test", .now_ms = 1 }),
        mkCall(6, .strict, .{ .on = true, .site = "a.test", .now_ms = 1 }),
        mkCall(6, .strict, .{ .on = false, .now_ms = 1 }),
    }) |c| {
        try testing.expectError(error.Rejected, t.apply(testing.allocator, c, &fail));
        try testing.expectEqualStrings("other_pane", fail.reason);
        try testing.expect(t.strict_owner == 5);
        try testing.expectEqualStrings("a.test", t.strict_site.slice());
    }
    _ = try t.apply(testing.allocator, mkCall(6, .clear, .{ .now_ms = 2 }), &fail);
    try testing.expect(t.strict_on);
    // 주인이 다른 사이트로 옮긴다.
    const moved = try t.apply(testing.allocator, mkCall(5, .strict, .{ .on = true, .site = "b.test", .now_ms = 3 }), &fail);
    try testing.expect(moved.changed and t.strict_owner == 5);
    // 결과 — pane 6 은 other_pane, pane 5 는 아니다; Grants 의 엄격은 주인 것.
    const j6 = try t.resultJson(testing.allocator, 6, .{}, "b.test", true, false);
    defer testing.allocator.free(j6);
    try testing.expect(std.mem.indexOf(u8, j6, "\"other_pane\":true") != null);
    const j5 = try t.resultJson(testing.allocator, 5, .{}, "b.test", true, false);
    defer testing.allocator.free(j5);
    try testing.expect(std.mem.indexOf(u8, j5, "other_pane") == null);
    // 주인이 네트워크 grant 를 잃었다 — 엄격이 사라지고 pane 6 이 켤 수 있다.
    try testing.expect(t.sync(&.{ .{ .pane = 5, .any_host = true }, .{ .pane = 6, .any_host = true } }, &.{6}));
    try testing.expect(!t.strict_on);
    _ = try t.apply(testing.allocator, mkCall(6, .strict, .{ .on = true, .site = "b.test", .now_ms = 4 }), &fail);
    try testing.expect(t.strict_owner == 6);
}

test "W9d③ v20b2 R12 NEW-3: block grant 철회로 규칙이 모두 사라진(sync) 뒤의 수 — clearAll 길처럼 지우고 늦은 수를 버린다, 다음 pane 의 결과에 옛 수·경고가 없다" {
    var t: Tab = .{};
    defer t.deinit(testing.allocator);
    var fail: Failure = undefined;
    _ = try t.apply(testing.allocator, mkCall(5, .add, .{ .patterns = &.{"https://a.test/x"} }), &fail);
    _ = try t.apply(testing.allocator, mkCall(5, .strict, .{ .on = true, .now_ms = 1 }), &fail);
    const g1 = t.gen;
    t.onHits(.{ .browser = 1, .generation = g1, .unrecorded = 4, .skipped_unknown_page = 2, .strict_redirect_missed = 1 }, true);
    // pane 5 의 block grant 철회(네트워크 grant 는 남음) — 규칙·엄격 모두 사라진다.
    try testing.expect(t.sync(&.{}, &.{5}));
    try testing.expect(!t.active());
    // 늦은 수(옛 세대).
    t.onHits(.{ .browser = 1, .generation = g1, .unrecorded = 3 }, true);
    // 다른 pane 이 새로 규칙을 넣는다.
    _ = try t.apply(testing.allocator, mkCall(6, .add, .{ .patterns = &.{"https://a.test/y"}, .now_ms = 2 }), &fail);
    const j = try t.resultJson(testing.allocator, 6, .{}, "a.test", true, false);
    defer testing.allocator.free(j);
    try testing.expect(t.unrecorded == 0 and t.skipped_unknown_page == 0 and t.strict_redirect_missed == 0);
    try testing.expect(std.mem.indexOf(u8, j, "strict_redirect_gap") == null);
    // 규칙이 남은 sync(일부만 철회)는 탭의 수를 지우지 않는다(남은 규칙의 것일 수 있다).
    var w: Tab = .{};
    defer w.deinit(testing.allocator);
    _ = try w.apply(testing.allocator, mkCall(5, .add, .{ .patterns = &.{"https://a.test/x"} }), &fail);
    _ = try w.apply(testing.allocator, mkCall(6, .add, .{ .patterns = &.{"https://a.test/y"}, .now_ms = 1 }), &fail);
    w.onHits(.{ .browser = 1, .generation = w.gen, .unrecorded = 2 }, true);
    try testing.expect(w.sync(&.{.{ .pane = 6, .any_host = true }}, &.{ 5, 6 }));
    try testing.expect(w.active() and w.unrecorded == 2);
    // 대조(clearAll 길): 같은 수가 지워지고 늦은 수는 버려진다.
    var u: Tab = .{};
    defer u.deinit(testing.allocator);
    _ = try u.apply(testing.allocator, mkCall(5, .add, .{ .patterns = &.{"https://a.test/x"} }), &fail);
    const ug = u.gen;
    u.onHits(.{ .browser = 1, .generation = ug, .unrecorded = 4 }, true);
    try testing.expect(u.clearAll());
    u.onHits(.{ .browser = 1, .generation = ug, .unrecorded = 3 }, true);
    try testing.expectEqual(@as(u64, 0), u.unrecorded);
}

test "W9d③ v20b2 R18 N-a: 엄격을 끄면 리다이렉트 어긋남 수·경고가 지워지고(규칙이 남아도) 끈 뒤의 수·그 앞 세대의 늦은 수는 받지 않는다, 알림은 세대마다(에이전트의 바꾸기마다 다시 — 설계)" {
    var t: Tab = .{};
    defer t.deinit(testing.allocator);
    var fail: Failure = undefined;
    // 규칙이 남는 탭(엄격만 꺼진다 — 탭이 비지 않아 `forgetCounts` 가 돌지 않는다).
    _ = try t.apply(testing.allocator, mkCall(5, .add, .{ .patterns = &.{"https://a.test/x"} }), &fail);
    _ = try t.apply(testing.allocator, mkCall(5, .strict, .{ .on = true, .now_ms = 1 }), &fail);
    const g_on = t.gen;
    t.onHits(.{ .browser = 1, .generation = g_on, .strict_redirect_missed = 1 }, true);
    try testing.expectEqual(@as(u64, 1), t.strict_redirect_missed);
    _ = try t.apply(testing.allocator, mkCall(5, .strict, .{ .on = false, .now_ms = 2 }), &fail);
    try testing.expect(t.active() and t.strict_redirect_missed == 0);
    // 끈 뒤의 세대로 온 수(엄격이 꺼졌다)도 받지 않는다.
    t.onHits(.{ .browser = 1, .generation = t.gen, .strict_redirect_missed = 1, .strict_redirect_bypassed = 1 }, true);
    try testing.expect(t.strict_redirect_missed == 0 and t.strict_redirect_bypassed == 0);
    const j = try t.resultJson(testing.allocator, 5, .{}, "a.test", true, false);
    defer testing.allocator.free(j);
    try testing.expect(std.mem.indexOf(u8, j, "strict_redirect_gap") == null and std.mem.indexOf(u8, j, "\"redirects_not_covered\":0") != null);
    // 다시 켠 뒤 끈 앞 세대의 늦은 수는 버리고(엄격의 바닥 — 탭의 바닥은 오르지 않았다), 다시 켠 세대의 수는 받는다.
    _ = try t.apply(testing.allocator, mkCall(5, .strict, .{ .on = true, .now_ms = 3 }), &fail);
    t.onHits(.{ .browser = 1, .generation = g_on, .strict_redirect_missed = 1, .unrecorded = 1 }, true);
    try testing.expect(t.strict_redirect_missed == 0 and t.unrecorded == 1);
    t.onHits(.{ .browser = 1, .generation = t.gen, .strict_redirect_missed = 1 }, true);
    try testing.expectEqual(@as(u64, 1), t.strict_redirect_missed);
    _ = try t.apply(testing.allocator, mkCall(5, .strict, .{ .on = false, .now_ms = 4 }), &fail);
    var notices: usize = 0;
    var now: i64 = 1000;
    for (0..20) |i| {
        now += 1000;
        _ = try t.apply(testing.allocator, mkCall(5, if (i % 2 == 0) .remove else .add, .{ .patterns = &.{"https://a.test/x"}, .now_ms = now }), &fail);
        notices += @intFromBool(t.wantsNotice());
        notices += @intFromBool(t.wantsNotice());
    }
    try testing.expectEqual(@as(usize, 10), notices); // 규칙이 있는 세대(add 뒤)마다 한 번 — 문서의 「세대마다 한 번」
}

test "W9d③ v20b2 R14 N-g: 규칙 번호가 u32 를 돌아 1 로 오면 남은 1 번과 겹친다 — 그 frame 은 만들어지지 않는다(닿기: 받은 add 42 억 번 — 문서화된 틈, 결과는 failed)" {
    var t: Tab = .{};
    defer t.deinit(testing.allocator);
    var fail: Failure = undefined;
    _ = try t.apply(testing.allocator, mkCall(5, .add, .{ .patterns = &.{"https://a.test/1"} }), &fail);
    t.next_id = std.math.maxInt(u32);
    _ = try t.apply(testing.allocator, mkCall(5, .add, .{ .patterns = &.{ "https://a.test/2", "https://a.test/3" }, .now_ms = 1 }), &fail);
    var ids: [4]u32 = undefined;
    for (t.rules.items, 0..) |r, i| ids[i] = r.id;
    var wire_buf: [ws.wire.max_frame_bytes]u8 = undefined;
    const enc = ws.codec.encode(.{ .net_block = t.toWire(1) }, &wire_buf);
    try testing.expectEqualSlices(u32, &.{ 1, std.math.maxInt(u32), 1 }, ids[0..t.rules.items.len]);
    try testing.expect(std.meta.isError(enc));
}

// ── W9d③ 3 차 검증 11–20 회차(검증자 B3 — 8485a891e 의 2 차 고침을 친다). 「관찰」 은 지금 동작을 박고 결함·NIT 를 출력으로 남긴다. ──

test "W9d③ v20c R12: 탭을 비우는 길마다(sync — block grant·네트워크 pane·호스트 좁힘, clear, 마지막 remove, 엄격만 끔, clearAll) 수·경고를 지우고 옛 세대의 늦은 수는 버린다 — 다음 pane 의 결과는 깨끗하다" {
    const Path = enum { sync_block_gone, sync_net_gone, sync_host_narrow, clear, remove_last, strict_off_only, clear_all, clear_all_strict_only };
    for (std.enums.values(Path)) |path| {
        var t: Tab = .{};
        defer t.deinit(testing.allocator);
        var fail: Failure = undefined;
        const strict_only = path == .strict_off_only or path == .clear_all_strict_only;
        const with_strict = path != .clear and path != .remove_last;
        if (!strict_only) _ = try t.apply(testing.allocator, mkCall(5, .add, .{ .patterns = &.{"https://a.test/x/*"}, .now_ms = 0 }), &fail);
        if (with_strict) _ = try t.apply(testing.allocator, mkCall(5, .strict, .{ .on = true, .now_ms = 0 }), &fail);
        var h: msg.NetBlockHits = .{ .browser = 1, .generation = t.gen, .unrecorded = 4, .skipped_unknown_page = 2, .strict_redirect_missed = 1, .strict_redirect_bypassed = 1, .sw_shared_with_unruled_tab = true, .count = 1 };
        h.entries[0] = .{ .rule_id = 1, .hits = 3, .sw_hits = 2 };
        t.onHits(h, true);
        try testing.expect(t.unrecorded == 4 and t.skipped_unknown_page == 2 and t.sw_shared_doc);
        try testing.expectEqual(@as(u64, if (with_strict) 1 else 0), t.strict_redirect_missed);
        const old = t.gen;
        switch (path) {
            .sync_block_gone => try testing.expect(t.sync(&.{}, &.{5})),
            .sync_net_gone => try testing.expect(t.sync(&.{.{ .pane = 5, .any_host = true }}, &.{6})),
            .sync_host_narrow => try testing.expect(t.sync(&.{.{ .pane = 5, .host = "b.test" }}, &.{5})),
            .clear => _ = try t.apply(testing.allocator, mkCall(5, .clear, .{ .now_ms = 2000 }), &fail),
            .remove_last => _ = try t.apply(testing.allocator, mkCall(5, .remove, .{ .rules = &.{1}, .now_ms = 2000 }), &fail),
            .strict_off_only => _ = try t.apply(testing.allocator, mkCall(5, .strict, .{ .on = false, .now_ms = 2000 }), &fail),
            .clear_all, .clear_all_strict_only => try testing.expect(t.clearAll()),
        }
        testing.expect(!t.active() and t.unrecorded == 0 and t.skipped_unknown_page == 0 and t.strict_redirect_missed == 0 and t.strict_redirect_bypassed == 0 and !t.sw_shared_doc and t.hits_floor == t.gen and t.gen != old) catch |e| {
            std.debug.print("v20c R12 path {s}: active {} unrecorded {d} skipped {d} missed {d} bypassed {d} shared {} floor {d} gen {d}\n", .{ @tagName(path), t.active(), t.unrecorded, t.skipped_unknown_page, t.strict_redirect_missed, t.strict_redirect_bypassed, t.sw_shared_doc, t.hits_floor, t.gen });
            return e;
        };
        // 옛 세대(규칙이 있던 세대)의 늦은 수 — 모두 버린다.
        t.onHits(h, true);
        try testing.expect(t.unrecorded == 0 and t.skipped_unknown_page == 0 and t.strict_redirect_missed == 0 and !t.sw_shared_doc);
        // 다음 pane 이 규칙을 넣는다 — 그 결과에 옛 수·경고가 없다.
        _ = try t.apply(testing.allocator, mkCall(6, .add, .{ .patterns = &.{"https://a.test/y/*"}, .now_ms = 4000 }), &fail);
        const j = try t.resultJson(testing.allocator, 6, .{}, "a.test", true, false);
        defer testing.allocator.free(j);
        testing.expect(std.mem.indexOf(u8, j, "\"unrecorded\":0,\"skipped_unknown_page\":0") != null and std.mem.indexOf(u8, j, "\"redirects_not_covered\":0") != null and std.mem.indexOf(u8, j, "strict_redirect_gap") == null and std.mem.indexOf(u8, j, "service_worker_shared") == null) catch |e| {
            std.debug.print("v20c R12 path {s}: next pane {s}\n", .{ @tagName(path), j });
            return e;
        };
    }
}

test "W9d③ v20c R12 대조: 규칙이 남는 길(다른 pane 의 규칙이 남은 sync·엄격만 거둔 sync) — 탭의 수는 지우지 않고, 엄격을 거두면 엄격의 리다이렉트 수만 지운다" {
    var t: Tab = .{};
    defer t.deinit(testing.allocator);
    var fail: Failure = undefined;
    _ = try t.apply(testing.allocator, mkCall(5, .add, .{ .patterns = &.{"https://a.test/x/*"} }), &fail);
    _ = try t.apply(testing.allocator, mkCall(6, .add, .{ .patterns = &.{"https://a.test/z/*"} }), &fail);
    _ = try t.apply(testing.allocator, mkCall(5, .strict, .{ .on = true }), &fail);
    t.onHits(.{ .browser = 1, .generation = t.gen, .unrecorded = 4, .skipped_unknown_page = 2, .strict_redirect_missed = 3 }, true);
    // pane 5 가 block grant 를 잃는다 — pane 6 의 규칙이 남는다(엄격도 5 의 것이라 거둔다).
    try testing.expect(t.sync(&.{.{ .pane = 6, .any_host = true }}, &.{ 5, 6 }));
    try testing.expect(t.active() and t.rules.items.len == 1 and !t.strict_on);
    try testing.expect(t.unrecorded == 4 and t.skipped_unknown_page == 2 and t.strict_redirect_missed == 0 and t.strict_floor == t.gen);
}

test "W9d③ 3 차 검증 NEW-B3-1(B3 R12 LATE-RETAG): sidecar 는 수를 센 때의 세대로 보낸다 — 탭을 비우기 전에 센 늦은 수(옛 세대)는 버려 다음 pane 의 결과가 깨끗하다, 엄격을 끄고 다시 켠 뒤 온 켬 a 의 수도 버린다, 비운 뒤 센 수는 받는다" {
    var t: Tab = .{};
    defer t.deinit(testing.allocator);
    var fail: Failure = undefined;
    _ = try t.apply(testing.allocator, mkCall(5, .add, .{ .patterns = &.{"https://a.test/x/*"} }), &fail);
    _ = try t.apply(testing.allocator, mkCall(5, .strict, .{ .on = true }), &fail);
    const ruled_gen = t.gen;
    try testing.expect(t.sync(&.{}, &.{5})); // 철회 — 탭이 빈다(세대 E)
    // sidecar 가 철회 앞에 센 수(보내기 task 는 10 ms 뒤)는 빈 net_block(E) 을 받은 뒤에 나가도 센 때의 세대(ruled_gen)를 단다(sidecar 시험
    // `net_block_table` 의 NEW-B3-1 — 전에는 E 를 달아 받혔다).
    t.onHits(.{ .browser = 1, .generation = ruled_gen, .unrecorded = 5, .skipped_unknown_page = 1, .strict_redirect_missed = 2 }, true);
    _ = try t.apply(testing.allocator, mkCall(6, .add, .{ .patterns = &.{"https://a.test/y/*"}, .now_ms = 2000 }), &fail);
    const j = try t.resultJson(testing.allocator, 6, .{}, "a.test", true, false);
    defer testing.allocator.free(j);
    try testing.expect(std.mem.indexOf(u8, j, "\"unrecorded\":0,\"skipped_unknown_page\":0") != null and std.mem.indexOf(u8, j, "\"redirects_not_covered\":0") != null);
    // 새 pane 의 세대에 센 수는 받는다(대조).
    t.onHits(.{ .browser = 1, .generation = t.gen, .unrecorded = 1 }, true);
    try testing.expectEqual(@as(u64, 1), t.unrecorded);
    // 엄격: 켬(세대 a) → 끔(b, strict_floor=b) → 켬(c). 켬 a 동안 센 리다이렉트 수는 a 를 달고 와 버려진다.
    var u: Tab = .{};
    defer u.deinit(testing.allocator);
    _ = try u.apply(testing.allocator, mkCall(5, .add, .{ .patterns = &.{"https://a.test/x/*"} }), &fail);
    _ = try u.apply(testing.allocator, mkCall(5, .strict, .{ .on = true }), &fail);
    const on_gen = u.gen;
    _ = try u.apply(testing.allocator, mkCall(5, .strict, .{ .on = false, .now_ms = 1 }), &fail);
    _ = try u.apply(testing.allocator, mkCall(5, .strict, .{ .on = true, .now_ms = 2 }), &fail);
    u.onHits(.{ .browser = 1, .generation = on_gen, .strict_redirect_missed = 2 }, true);
    try testing.expectEqual(@as(u64, 0), u.strict_redirect_missed);
    u.onHits(.{ .browser = 1, .generation = u.gen, .strict_redirect_missed = 1 }, true);
    try testing.expectEqual(@as(u64, 1), u.strict_redirect_missed);
}

test "W9d③ 3 차 검증 N-B3-b: 엄격을 다른 사이트로 옮기면(끄지 않고 켬) 옛 사이트의 리다이렉트 수·경고를 지우고 그 앞 세대의 늦은 수는 버린다, 같은 사이트로 다시 켬은 바꾸지 않는다" {
    var t: Tab = .{};
    defer t.deinit(testing.allocator);
    var fail: Failure = undefined;
    _ = try t.apply(testing.allocator, mkCall(5, .strict, .{ .on = true, .site = "a.test" }), &fail);
    const a_gen = t.gen;
    t.onHits(.{ .browser = 1, .generation = t.gen, .strict_redirect_missed = 2 }, true);
    const same = try t.apply(testing.allocator, mkCall(5, .strict, .{ .on = true, .site = "a.test", .now_ms = 1 }), &fail);
    try testing.expect(!same.changed and t.strict_redirect_missed == 2); // 대조: 같은 사이트 — 그대로
    _ = try t.apply(testing.allocator, mkCall(5, .strict, .{ .on = true, .site = "b.test", .now_ms = 2 }), &fail);
    const j = try t.resultJson(testing.allocator, 5, .{}, "b.test", true, false);
    defer testing.allocator.free(j);
    try testing.expect(t.strict_redirect_missed == 0 and t.strict_floor == t.gen and std.mem.indexOf(u8, j, "strict_redirect_gap") == null);
    t.onHits(.{ .browser = 1, .generation = a_gen, .strict_redirect_missed = 3 }, true); // 옛 사이트의 늦은 수
    try testing.expectEqual(@as(u64, 0), t.strict_redirect_missed);
    t.onHits(.{ .browser = 1, .generation = t.gen, .strict_redirect_missed = 1 }, true);
    try testing.expectEqual(@as(u64, 1), t.strict_redirect_missed);
}

test "W9d③ 3 차 검증 변이(N-A3-4): 바닥 0 은 「버린 세대 없음」 — 한 번도 빈 적 없는 탭은 세대가 2^31 을 넘어도 수를 받는다" {
    var t: Tab = .{};
    defer t.deinit(testing.allocator);
    var fail: Failure = undefined;
    t.gen = (1 << 31) + 5;
    _ = try t.apply(testing.allocator, mkCall(5, .add, .{ .patterns = &.{"https://a.test/x/*"} }), &fail);
    try testing.expect(t.hits_floor == 0 and t.gen > (1 << 31));
    t.onHits(.{ .browser = 1, .generation = t.gen, .unrecorded = 2 }, true);
    try testing.expectEqual(@as(u64, 2), t.unrecorded);
}

test "W9d③ 3 차 검증 N-A3-4: 세대가 u32 를 돌아도 늦은 수 거르기가 뒤집히지 않는다 — 바닥 근처에서 돈 뒤의 새 세대는 받고, 돌기 전의 옛 세대는 버린다" {
    var t: Tab = .{};
    defer t.deinit(testing.allocator);
    var fail: Failure = undefined;
    t.gen = std.math.maxInt(u32) - 1;
    t.next_id = 1;
    _ = try t.apply(testing.allocator, mkCall(5, .add, .{ .patterns = &.{"https://a.test/x/*"} }), &fail); // gen max
    _ = try t.apply(testing.allocator, mkCall(5, .strict, .{ .on = true }), &fail); // gen 1(0 을 건너뜀)
    try testing.expectEqual(@as(u32, 1), t.gen);
    _ = try t.apply(testing.allocator, mkCall(5, .clear, .{ .now_ms = 1 }), &fail); // 규칙만 지움 — 엄격이 남아 탭은 비지 않는다
    try testing.expect(t.clearAll()); // 탭이 빈다 — 바닥 = 지금 세대(3)
    const floor = t.hits_floor;
    try testing.expectEqual(@as(u32, 3), floor);
    t.onHits(.{ .browser = 1, .generation = std.math.maxInt(u32), .unrecorded = 9 }, true); // 돌기 전의 옛 세대 — 버린다(전에는 `>=` 로 받았다)
    try testing.expectEqual(@as(u64, 0), t.unrecorded);
    _ = try t.apply(testing.allocator, mkCall(6, .add, .{ .patterns = &.{"https://a.test/y/*"}, .now_ms = 2000 }), &fail);
    t.onHits(.{ .browser = 1, .generation = t.gen, .unrecorded = 1 }, true);
    try testing.expectEqual(@as(u64, 1), t.unrecorded);
    // 엄격 바닥도 같다.
    var u: Tab = .{};
    defer u.deinit(testing.allocator);
    u.gen = std.math.maxInt(u32) - 2;
    _ = try u.apply(testing.allocator, mkCall(5, .strict, .{ .on = true }), &fail);
    const old = u.gen;
    _ = try u.apply(testing.allocator, mkCall(5, .strict, .{ .on = false, .now_ms = 1 }), &fail);
    _ = try u.apply(testing.allocator, mkCall(5, .strict, .{ .on = true, .now_ms = 2 }), &fail);
    _ = try u.apply(testing.allocator, mkCall(5, .add, .{ .patterns = &.{"https://a.test/x/*"}, .now_ms = 3 }), &fail);
    try testing.expect(u.gen < old); // 돌았다
    u.onHits(.{ .browser = 1, .generation = old, .strict_redirect_missed = 4 }, true);
    try testing.expectEqual(@as(u64, 0), u.strict_redirect_missed);
    u.onHits(.{ .browser = 1, .generation = u.gen, .strict_redirect_missed = 1 }, true);
    try testing.expectEqual(@as(u64, 1), u.strict_redirect_missed);
}

test "W9d③ v20c R14: too_many_rules index 는 넘치는 패턴의 자리(앞의 겹침·이미 있는 것을 건너뛰고), 다른 pane 의 같은 패턴은 새것, 종류가 다르면 새 규칙, 많은 이미 있는 패턴은 already 한 번씩" {
    var t: Tab = .{};
    defer t.deinit(testing.allocator);
    var fail: Failure = undefined;
    var pats: [31][]const u8 = undefined;
    var bufs: [31][32]u8 = undefined;
    for (&pats, 0..) |*p, i| p.* = std.fmt.bufPrint(&bufs[i], "https://a.test/{d}", .{i}) catch unreachable;
    _ = try t.apply(testing.allocator, mkCall(5, .add, .{ .patterns = &pats }), &fail);
    // [new1, new1, 이미 있는 0, new2] — 넘치는 것은 3 번째 자리(index 3).
    try testing.expectError(error.Rejected, t.apply(testing.allocator, mkCall(5, .add, .{ .patterns = &.{ "https://a.test/n1", "https://a.test/n1", "https://a.test/0", "https://a.test/n2" }, .now_ms = 1000 }), &fail));
    try testing.expect(std.mem.eql(u8, fail.reason, "too_many_rules") and fail.index.? == 3);
    try testing.expectEqual(@as(usize, 31), t.rules.items.len);
    // 다른 pane 의 같은 패턴 [0, 1] — pane 6 에는 둘 다 새것, 넘치는 것은 index 1.
    try testing.expectError(error.Rejected, t.apply(testing.allocator, mkCall(6, .add, .{ .patterns = &.{ "https://a.test/0", "https://a.test/1" }, .now_ms = 2000 }), &fail));
    try testing.expectEqual(@as(?usize, 1), fail.index);
    // 종류만 다른 같은 패턴 — 새 규칙(32 번째) — already 가 아니다.
    const typed = try t.apply(testing.allocator, mkCall(5, .add, .{ .patterns = &.{"https://a.test/0"}, .types = nb.typeBits("image").?, .now_ms = 3000 }), &fail);
    try testing.expect(typed.added.len == 1 and typed.already.len == 0);
    // 이미 있는 패턴 40 개(31 개를 겹쳐 쓴다) — 받고(바꿈 없음) already 는 겹치지 않게 31 개.
    var many: [40][]const u8 = undefined;
    for (&many, 0..) |*p, i| p.* = pats[i % 31];
    const m = try t.apply(testing.allocator, mkCall(5, .add, .{ .patterns = &many, .now_ms = 4000 }), &fail);
    try testing.expect(!m.changed and m.added.len == 0 and m.already.len == 31);
    for (m.already.slice(), 0..) |id, i| for (m.already.slice()[0..i]) |prev| try testing.expect(prev != id);
}

test "W9d③ v20c R14: 1 초 10 번의 경계 — 받은 10 번 뒤 999 ms 는 resource_busy, 1000 ms 는 받는다, list 는 세지 않는다" {
    var t: Tab = .{};
    defer t.deinit(testing.allocator);
    var fail: Failure = undefined;
    for (0..10) |i| _ = try t.apply(testing.allocator, mkCall(5, if (i % 2 == 0) .add else .remove, .{ .patterns = &.{"https://a.test/r"}, .rules = &.{}, .now_ms = @intCast(i) }), &fail);
    for (0..20) |_| _ = try t.apply(testing.allocator, mkCall(5, .list, .{ .now_ms = 500 }), &fail);
    try testing.expectError(error.Rejected, t.apply(testing.allocator, mkCall(5, .clear, .{ .now_ms = 999 }), &fail));
    try testing.expectEqualStrings("resource_busy", fail.reason);
    _ = try t.apply(testing.allocator, mkCall(5, .clear, .{ .now_ms = 1000 }), &fail);
    try testing.expectError(error.Rejected, t.apply(testing.allocator, mkCall(5, .clear, .{ .now_ms = 1000 }), &fail)); // 두 번째 자리(1 ms)는 아직
    _ = try t.apply(testing.allocator, mkCall(5, .clear, .{ .now_ms = 1001 }), &fail);
}

test "W9d③ v20c R14·R15 N-d: failed 의 차례 — 만들지 못함(규칙·엄격 failed), 거절된 바꾸기·list 는 그대로, 바른 바꾸기는 둘 다 sent, 옛 세대의 답은 무시, 지금 세대의 답은 active·on; 엄격이 꺼진 탭의 만들지 못함은 엄격 off 그대로; sidecar 의 strict failed 뒤 바꾸기는 sent" {
    var t: Tab = .{};
    defer t.deinit(testing.allocator);
    var fail: Failure = undefined;
    _ = try t.apply(testing.allocator, mkCall(5, .add, .{ .patterns = &.{"https://a.test/x"} }), &fail);
    _ = try t.apply(testing.allocator, mkCall(5, .strict, .{ .on = true }), &fail);
    t.markUnsendable();
    const state = struct {
        fn of(tab: *Tab) ![2][]const u8 {
            const j = try tab.resultJson(testing.allocator, 5, .{}, "a.test", true, false);
            defer testing.allocator.free(j);
            const top: []const u8 = if (std.mem.indexOf(u8, j, "\"state\":\"failed\",\"strict\"") != null) "failed" else if (std.mem.indexOf(u8, j, "\"state\":\"sent\",\"strict\"") != null) "sent" else if (std.mem.indexOf(u8, j, "\"state\":\"active\",\"strict\"") != null) "active" else "?";
            const st: []const u8 = @tagName(tab.strict_state);
            return .{ top, st };
        }
    }.of;
    var s = try state(&t);
    try testing.expect(std.mem.eql(u8, s[0], "failed") and std.mem.eql(u8, s[1], "failed"));
    try testing.expectError(error.Rejected, t.apply(testing.allocator, mkCall(5, .remove, .{ .rules = &.{77}, .now_ms = 1 }), &fail));
    _ = try t.apply(testing.allocator, mkCall(5, .list, .{ .now_ms = 1 }), &fail);
    s = try state(&t);
    try testing.expect(std.mem.eql(u8, s[0], "failed") and std.mem.eql(u8, s[1], "failed"));
    const before = t.gen;
    _ = try t.apply(testing.allocator, mkCall(5, .add, .{ .patterns = &.{"https://a.test/y"}, .now_ms = 2 }), &fail);
    s = try state(&t);
    try testing.expect(std.mem.eql(u8, s[0], "sent") and std.mem.eql(u8, s[1], "sent"));
    t.onState(.{ .browser = 1, .generation = before, .ok = true, .strict = .on }); // 옛 세대
    s = try state(&t);
    try testing.expect(std.mem.eql(u8, s[0], "sent") and std.mem.eql(u8, s[1], "sent"));
    t.onState(.{ .browser = 1, .generation = t.gen, .ok = true, .strict = .on });
    s = try state(&t);
    try testing.expect(std.mem.eql(u8, s[0], "active") and std.mem.eql(u8, s[1], "on"));
    // sidecar 가 엄격 CDP 실패를 알렸다(ok 참, strict failed) — 다음 규칙 바꾸기는 엄격을 sent 로(다시 보낸다는 뜻).
    t.onState(.{ .browser = 1, .generation = t.gen, .ok = true, .strict = .failed });
    try testing.expect(t.strict_state == .failed);
    _ = try t.apply(testing.allocator, mkCall(5, .add, .{ .patterns = &.{"https://a.test/z"}, .now_ms = 3 }), &fail);
    try testing.expect(t.strict_state == .sent);
    // 엄격이 꺼진 탭의 만들지 못함 — 엄격은 off 그대로.
    var u: Tab = .{};
    defer u.deinit(testing.allocator);
    _ = try u.apply(testing.allocator, mkCall(5, .add, .{ .patterns = &.{"https://a.test/x"} }), &fail);
    u.markUnsendable();
    try testing.expect(u.strict_state == .off);
    _ = try u.apply(testing.allocator, mkCall(5, .add, .{ .patterns = &.{"https://a.test/y"}, .now_ms = 1 }), &fail);
    try testing.expect(u.strict_state == .off and u.acked_gen != u.gen);
}

test "W9d③ v20c R14: 가장 큰 net_block — 규칙 32 개 모두 512 바이트 패턴·253 바이트 사이트·종류, 엄격 사이트 253 바이트 — maru 가 받은 상태는 frame 이 되고 왕복한다" {
    const ar = @import("array_repeat");
    const h253 = ar.repeat("a", 63) ++ "." ++ ar.repeat("b", 63) ++ "." ++ ar.repeat("c", 63) ++ "." ++ ar.repeat("d", 51) ++ ".localhost";
    var t: Tab = .{};
    defer t.deinit(testing.allocator);
    var fail: Failure = undefined;
    var norm: [32][nb.max_pattern_bytes]u8 = undefined;
    var pats: [32][]const u8 = undefined;
    for (0..32) |i| {
        var raw: [nb.max_pattern_bytes]u8 = undefined;
        const head = std.fmt.bufPrint(&raw, "https://a.test/{d:0>2}/", .{i}) catch unreachable;
        @memset(raw[head.len..], 'q');
        const p = nb.parse(&raw).ok;
        @memcpy(norm[i][0..p.norm().len], p.norm());
        pats[i] = norm[i][0..p.norm().len];
        try testing.expectEqual(@as(usize, nb.max_pattern_bytes), pats[i].len);
    }
    _ = try t.apply(testing.allocator, mkCall(5, .add, .{ .patterns = &pats, .types = nb.typeBits("image").? | nb.typeBits("script").?, .site = h253 }), &fail);
    _ = try t.apply(testing.allocator, mkCall(5, .strict, .{ .on = true, .site = h253, .now_ms = 1 }), &fail);
    try testing.expectEqual(@as(usize, 32), t.rules.items.len);
    var wire_buf: [ws.wire.max_frame_bytes]u8 = undefined;
    const n = try ws.codec.encode(.{ .net_block = t.toWire(std.math.maxInt(u32)) }, &wire_buf);
    const back = try ws.codec.decodeExact(wire_buf[0..n]);
    try testing.expectEqual(@as(u8, 32), back.net_block.count);
    try testing.expectEqualStrings(h253, back.net_block.strict_site);
    for (back.net_block.rules[0..32], 0..) |r, i| try testing.expectEqualStrings(pats[i], r.pattern);
    std.debug.print("v20c R14 largest net_block frame {d} bytes (max {d})\n", .{ n, ws.wire.max_frame_bytes });
}
