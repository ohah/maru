//! Chromium 탭의 가짜 응답 규칙을 maru 가 쥐는 자리(W9d④ — docs/plans/web-osr-backend.md 「W9d④ 결정·실측」) — L2 순수.
//!
//! 탭 하나에 규칙은 모두 32 개(pane 마다 주인 — 다른 pane 의 규칙은 수만 보인다, 막기 32 와 따로). 규칙은 정규형 패턴·종류·메서드·**사이트**
//! (추가한 때의 페이지 호스트 — 에이전트 탭, 또는 grant 호스트 — 사용자 탭)·**실행 사이트**(사이트에 묶인 grant 의 호스트 — 문서 가짜는 그
//! 주소의 출처로 돈다: 그 사이트를 grant 가 덮을 때만, 실측 M25)·사람의 누름 예외(`human_nav_real` — 사용자 탭의 규칙, 사용자 결정 Q2)와 응답
//! (상태·content_type·Location·허용 목록 머리·본문)을 쥔다. **본문의 원본은 maru 가 쥔다**(탭 4 MiB·앱 32 MiB — 규칙과 함께 지운다) — sidecar 로는
//! 본문 번호로 따로 보내고(`web_osr_mock_pump`), sidecar 가 다시 뜨거나 브라우저가 새로 만들어지면 새 번호로 다시 보낸다. 바뀔 때마다 세대(`gen`)가
//! 오르고 web_osr 가 규칙을 하나씩(`net_mock_rule`) 보내고 맺는다(`net_mock_commit`). 수는 sidecar 가 차이로 보내 여기서 누적한다. 주인의 mock·
//! network·browser grant 중 하나라도 사라지거나 그 호스트가 규칙의 사이트를 더 덮지 않으면 그 규칙·엄격은 버린다(`sync` — 계획 §3·§10).
//!
//! 시험이 증명하는 것: add(같은 (패턴·종류·메서드)면 응답을 바꾸고 번호는 그대로 — replaced, 32 개, 탭 4 MiB·앱 32 MiB, 사이트 없는 페이지),
//! remove(번호·패턴, 남의 규칙 — unknown_rule), clear(제 규칙만 — 엄격은 그대로), 엄격(사이트에 묶임), 초당 10 번, sync 의 버림 표(mock·network·
//! browser grant·호스트), 본문 바이트 셈(바꾸기·지우기·sync 가 앱 셈을 돌려준다), sidecar 상태·수의 누적, wire 꼴(닫힌 칸을 지난다 — 머리·
//! Location·본문 번호), 새 번호로 다시 보내기, 결과 JSON(다른 pane 은 수만, 설정 끔이면 서비스 워커 수를 숨긴다, 경고).

const std = @import("std");
const ws = @import("web_sidecar/root.zig");
const cpg = @import("control_pane_grant.zig");

const nb = ws.net_block;
const mr = ws.net_mock_rules;
const msg = ws.message;
const nf = ws.net_fields;
const policy = ws.net_policy;

pub const max_rules = mr.max_rules;
/// 탭마다 1 초에 받는 바꾸기 수(막기와 같다 — 바꿀 때마다 sidecar 가 규칙을 다시 푼다).
pub const max_changes_per_s: usize = 10;

pub const Rule = struct {
    id: u32,
    owner: u64,
    pattern_buf: [nb.max_pattern_bytes]u8 = undefined,
    pattern_len: u16 = 0,
    types: u32 = 0,
    methods: u8 = 0,
    site: cpg.GrantHost = .{},
    /// 실행 사이트(빈 = 어느 호스트든 grant — 묻지 않는다).
    exec_site: cpg.GrantHost = .{},
    human_nav_real: bool = false,
    status: u16 = 200,
    /// 이 규칙이 쥔다(`freeResponse`).
    content_type: []u8 = &.{},
    location: []u8 = &.{},
    headers: []u8 = &.{},
    header_count: u8 = 0,
    body: []u8 = &.{},
    /// sidecar 로 보낼 본문 번호(0 = 빈 본문). 보낼 때마다(다시 뜬 sidecar·새 브라우저) 새 번호다 — 늦은 확인이 섞이지 않게.
    body_id: u32 = 0,
    /// 이 번호의 본문을 보내기 줄에 넣었다.
    body_queued: bool = false,
    hits: u64 = 0,
    sw_not_mocked: u64 = 0,
    /// 맞았지만 그 가짜가 돌 출처(다른 사이트 iframe·워커가 낸 요청, 다른 사이트 문서)를 주인의 grant 가 덮지 않아 진짜로 간 수(v1 SEVERE-1 —
    /// 사용자 결정 2026-11-11 「허락 밖 iframe 요청은 모두 진짜」).
    frame_not_mocked: u64 = 0,

    pub fn pattern(self: *const Rule) []const u8 {
        return self.pattern_buf[0..self.pattern_len];
    }

    pub fn headerBlock(self: *const Rule) msg.NetHeaderBlock {
        return .{ .count = self.header_count, .bytes = self.headers };
    }

    fn freeResponse(self: *Rule, gpa: std.mem.Allocator) void {
        gpa.free(self.content_type);
        gpa.free(self.location);
        gpa.free(self.headers);
        gpa.free(self.body);
        self.content_type = &.{};
        self.location = &.{};
        self.headers = &.{};
        self.body = &.{};
    }
};

pub const StrictState = enum { off, sent, on, failed };

pub const Action = enum { add, remove, clear, list, strict };

/// 응답(인자 검사를 지난 것 — 본문은 디코드했다).
pub const Response = struct {
    status: u16 = 200,
    content_type: []const u8 = mr.default_text_type,
    headers: []const mr.Header = &.{},
    body: []const u8 = "",
};

/// 한 번의 `browser.networkMock`(정규형 인자 — control_browser 가 이미 풀었다).
pub const Call = struct {
    owner: u64,
    action: Action,
    pattern: []const u8 = "",
    types: u32 = 0,
    methods: u8 = 0,
    response: Response = .{},
    rules: []const u32 = &.{},
    on: ?bool = null,
    /// add·엄격 켬의 사이트(소문자 호스트) — 빈 글이면 http(s) 페이지가 아니다(`no_site`).
    site: []const u8 = "",
    /// 사이트에 묶인 grant 의 호스트(실행 사이트) — 어느 호스트든 grant 면 빈 글.
    exec_site: []const u8 = "",
    /// 주인의 mock grant 가 탭과 함께 생긴 것이 아니다(사용자 탭 — Q2).
    human_nav_real: bool = false,
    now_ms: i64 = 0,
};

/// 앱 전체의 본문 셈과 본문 번호(web_osr 가 쥔다).
pub const Budget = struct {
    app_bytes: usize = 0,
    next_body_id: u32 = 1,

    pub fn takeBodyId(self: *Budget) u32 {
        const id = self.next_body_id;
        self.next_body_id +%= 1;
        if (self.next_body_id == 0) self.next_body_id = 1;
        return id;
    }
};

/// 거절의 까닭(`{"reason","message","index"?,"resource"?}` — control_browser 가 코드를 고른다).
pub const Failure = struct { reason: []const u8, message: []const u8, index: ?usize = null, resource: ?[]const u8 = null };

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
    added: ?u32 = null,
    replaced: ?u32 = null,
    removed: IdList = .{},
    changed: bool = false,
};

/// 그 탭의 grant 하나(`sync` — 주인 pane·어느 호스트든·묶인 호스트).
pub const OwnerGrant = struct { pane: u64, any_host: bool = false, host: []const u8 = "" };

pub const Tab = struct {
    rules: std.ArrayList(Rule) = .empty,
    next_id: u32 = 1,
    strict_on: bool = false,
    strict_owner: u64 = 0,
    strict_site: cpg.GrantHost = .{},
    strict_state: StrictState = .off,
    gen: u32 = 0,
    sent_gen: u32 = 0,
    acked_gen: u32 = 0,
    acked_ok: bool = true,
    unrecorded: u64 = 0,
    busy: u64 = 0,
    skipped_unknown_page: u64 = 0,
    /// 이 문서에서 sidecar 가 서비스 워커 길의 맞음을 알렸다(새 문서마다 지운다).
    page_controlled_doc: bool = false,
    changes: [max_changes_per_s]i64 = @splat(std.math.minInt(i64) / 2),
    change_next: usize = 0,
    noticed_gen: u32 = 0,

    pub fn deinit(self: *Tab, gpa: std.mem.Allocator, budget: *Budget) void {
        for (self.rules.items) |*r| {
            budget.app_bytes -|= r.body.len;
            r.freeResponse(gpa);
        }
        self.rules.deinit(gpa);
        self.* = .{};
    }

    /// 규칙이나 엄격이 있다(탭 제목의 ▣ — 잠든 규칙만 있어도, sidecar 확인 전에도).
    pub fn active(self: *const Tab) bool {
        return self.rules.items.len > 0 or self.strict_on;
    }

    pub fn ownerRules(self: *const Tab, owner: u64) usize {
        var n: usize = 0;
        for (self.rules.items) |r| n += @intFromBool(r.owner == owner);
        return n;
    }

    /// 이 탭의 본문 합(모든 pane).
    pub fn bodyBytes(self: *const Tab) usize {
        var n: usize = 0;
        for (self.rules.items) |r| n += r.body.len;
        return n;
    }

    fn bump(self: *Tab) void {
        self.gen +%= 1;
        if (self.gen == 0) self.gen = 1;
    }

    fn rateOk(self: *Tab, now_ms: i64) bool {
        const oldest = self.changes[self.change_next];
        if (now_ms - oldest < 1000) return false;
        self.changes[self.change_next] = now_ms;
        self.change_next = (self.change_next + 1) % max_changes_per_s;
        return true;
    }

    fn findOwned(self: *Tab, owner: u64, id: u32) ?usize {
        for (self.rules.items, 0..) |r, i| if (r.owner == owner and r.id == id) return i;
        return null;
    }

    fn existing(self: *const Tab, owner: u64, pat: []const u8, types: u32, methods: u8, site: *const cpg.GrantHost) ?usize {
        for (self.rules.items, 0..) |*r, i| if (r.owner == owner and r.types == types and r.methods == methods and r.site.eql(site) and std.mem.eql(u8, r.pattern(), pat)) return i;
        return null;
    }

    /// 한 번의 바꾸기·보기. 거절이면 `fail` 에 까닭(아무것도 바뀌지 않는다).
    pub fn apply(self: *Tab, gpa: std.mem.Allocator, budget: *Budget, call: Call, fail: *Failure) error{ Rejected, OutOfMemory }!Outcome {
        var out: Outcome = .{};
        // 엄격 모드도 규칙처럼 켠 pane 의 것이다 — 다른 pane 은 끄지도 가져가지도 못한다(W9d④ v2 검증 R13 SEVERE: 막기의 W9d③ v20b DEF-3 고침이
        // 가짜로 오지 않아, 다른 pane 이 끄거나 다시 켜 주인이 됐고 그 pane 이 grant 를 잃자 처음 pane 의 엄격이 사라졌다). 주인의 grant 가 사라지면
        // `sync` 가 거둔다. 거절은 1 초 10 번 자리를 쓰지 않는다(막기의 v20b2 R14 N2 와 같다 — 그래서 `rateOk` 앞).
        if (call.action == .strict and self.strict_on and self.strict_owner != call.owner) {
            fail.* = .{ .reason = "other_pane", .message = "strict mode on this tab was turned on by another pane — only that pane can change it" };
            return error.Rejected;
        }
        if (call.action != .list and !self.rateOk(call.now_ms)) {
            fail.* = .{ .reason = "resource_busy", .message = "too many mocking changes on this tab — at most 10 a second" };
            return error.Rejected;
        }
        switch (call.action) {
            .list => {},
            .add => try self.add(gpa, budget, call, fail, &out),
            .remove => {
                for (call.rules, 0..) |id, i| if (self.findOwned(call.owner, id) == null) {
                    fail.* = .{ .reason = "unknown_rule", .message = "no such rule of yours on this tab — list them with maru browser network-mock --list", .index = i };
                    return error.Rejected;
                };
                var i: usize = 0;
                while (i < self.rules.items.len) {
                    const r = &self.rules.items[i];
                    const by_id = std.mem.indexOfScalar(u32, call.rules, r.id) != null;
                    const by_pattern = call.pattern.len != 0 and std.mem.eql(u8, call.pattern, r.pattern());
                    if (r.owner == call.owner and (by_id or by_pattern)) {
                        out.removed.push(r.id);
                        self.drop(gpa, budget, i);
                        out.changed = true;
                    } else i += 1;
                }
            },
            .clear => {
                var i: usize = 0;
                while (i < self.rules.items.len) {
                    if (self.rules.items[i].owner == call.owner) {
                        out.removed.push(self.rules.items[i].id);
                        self.drop(gpa, budget, i);
                        out.changed = true;
                    } else i += 1;
                }
            },
            .strict => {
                const on = call.on orelse false;
                if (on) {
                    if (call.site.len == 0) {
                        fail.* = .{ .reason = "no_site", .message = "the tab is not showing an http(s) page — navigate first (strict mode is bound to the site it was turned on on)" };
                        return error.Rejected;
                    }
                    const site: cpg.GrantHost = .init(call.site);
                    // 여기 오면 엄격이 꺼졌거나 이 pane 이 주인이다(위의 `other_pane`) — 켜기·다른 사이트로 옮기기만.
                    if (!self.strict_on or !self.strict_site.eql(&site)) {
                        self.strict_on = true;
                        self.strict_owner = call.owner;
                        self.strict_site = site;
                        self.strict_state = .sent;
                        out.changed = true;
                    }
                } else if (self.strict_on) {
                    self.strictOff();
                    out.changed = true;
                }
            },
        }
        if (out.changed) self.bump();
        return out;
    }

    fn add(self: *Tab, gpa: std.mem.Allocator, budget: *Budget, call: Call, fail: *Failure, out: *Outcome) error{ Rejected, OutOfMemory }!void {
        if (call.site.len == 0) {
            fail.* = .{ .reason = "no_site", .message = "the tab is not showing an http(s) page — navigate first (rules work on the site they were added on)" };
            return error.Rejected;
        }
        const site: cpg.GrantHost = .init(call.site);
        const prev = self.existing(call.owner, call.pattern, call.types, call.methods, &site);
        if (prev == null and self.rules.items.len >= max_rules) {
            fail.* = .{ .reason = "too_many_rules", .message = "a tab holds at most 32 mock rules (all panes together)" };
            return error.Rejected;
        }
        const old_len: usize = if (prev) |i| self.rules.items[i].body.len else 0;
        const body_len = call.response.body.len;
        if (self.bodyBytes() - old_len + body_len > mr.max_tab_body_bytes) {
            fail.* = .{ .reason = "tab_bytes_exceeded", .message = "mock bodies on one tab add up to at most 4 MiB — remove rules or use smaller bodies" };
            return error.Rejected;
        }
        if (budget.app_bytes - old_len + body_len > mr.max_app_body_bytes) {
            fail.* = .{ .reason = "resource_busy", .message = "mock bodies of all tabs add up to at most 32 MiB — remove rules on other tabs", .resource = "browser-mock-bytes" };
            return error.Rejected;
        }
        // 응답을 만든다(Location 은 제 칸으로, 나머지 머리는 덩어리로).
        var hb: nf.HeaderBuilder = .{};
        var location: []const u8 = "";
        for (call.response.headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "location")) {
                location = h.value;
                continue;
            }
            _ = hb.add(h.name, h.value);
        }
        const content_type = try gpa.dupe(u8, call.response.content_type);
        errdefer gpa.free(content_type);
        const loc = try gpa.dupe(u8, location);
        errdefer gpa.free(loc);
        const headers = try gpa.dupe(u8, hb.block().bytes);
        errdefer gpa.free(headers);
        const body = try gpa.dupe(u8, call.response.body);
        errdefer gpa.free(body);
        var r: Rule = .{
            .id = 0,
            .owner = call.owner,
            .types = call.types,
            .methods = call.methods,
            .site = site,
            .exec_site = .init(call.exec_site),
            .human_nav_real = call.human_nav_real,
            .status = call.response.status,
            .content_type = content_type,
            .location = loc,
            .headers = headers,
            .header_count = hb.count,
            .body = body,
            .body_id = if (body.len == 0) 0 else budget.takeBodyId(),
        };
        const n = @min(call.pattern.len, r.pattern_buf.len);
        @memcpy(r.pattern_buf[0..n], call.pattern[0..n]);
        r.pattern_len = @intCast(n);
        if (prev) |i| {
            const old = &self.rules.items[i];
            r.id = old.id;
            r.hits = old.hits;
            r.sw_not_mocked = old.sw_not_mocked;
            r.frame_not_mocked = old.frame_not_mocked;
            budget.app_bytes -|= old.body.len;
            old.freeResponse(gpa);
            old.* = r;
            out.replaced = r.id;
        } else {
            r.id = self.next_id;
            try self.rules.append(gpa, r);
            self.next_id +%= 1;
            if (self.next_id == 0) self.next_id = 1;
            out.added = r.id;
        }
        budget.app_bytes += body.len;
        out.changed = true;
    }

    fn drop(self: *Tab, gpa: std.mem.Allocator, budget: *Budget, i: usize) void {
        const r = &self.rules.items[i];
        budget.app_bytes -|= r.body.len;
        r.freeResponse(gpa);
        _ = self.rules.orderedRemove(i);
    }

    fn strictOff(self: *Tab) void {
        self.strict_on = false;
        self.strict_owner = 0;
        self.strict_site = .{};
        self.strict_state = .off;
    }

    /// 주인이 grant 를 잃은 규칙·엄격을 버린다 — 주인의 mock grant 가 없거나(철회·pane 닫힘) 묶인 호스트가 규칙의 사이트를 더 덮지 않거나(다른
    /// 호스트로 다시 허용), 주인의 네트워크 grant(`net_panes`)나 그 탭의 `browser` grant(`browser_panes` — 가짜는 eval 위에 선다, §13 P1-4)가
    /// 없다. 바꿨으면 참.
    pub fn sync(self: *Tab, gpa: std.mem.Allocator, budget: *Budget, mock_grants: []const OwnerGrant, net_panes: []const u64, browser_panes: []const u64) bool {
        var changed = false;
        var i: usize = 0;
        while (i < self.rules.items.len) {
            const r = &self.rules.items[i];
            if (!keeps(mock_grants, net_panes, browser_panes, r.owner, r.site.slice())) {
                self.drop(gpa, budget, i);
                changed = true;
            } else i += 1;
        }
        if (self.strict_on and !keeps(mock_grants, net_panes, browser_panes, self.strict_owner, self.strict_site.slice())) {
            self.strictOff();
            changed = true;
        }
        if (changed) self.bump();
        return changed;
    }

    /// 모두 버린다(지켜보기가 끝났다·탭이 닫힌다).
    pub fn clearAll(self: *Tab, gpa: std.mem.Allocator, budget: *Budget) bool {
        if (!self.active()) return false;
        while (self.rules.items.len > 0) self.drop(gpa, budget, self.rules.items.len - 1);
        self.strictOff();
        self.bump();
        return true;
    }

    /// 다시 뜬 sidecar·새 브라우저 — 본문마다 새 번호(늦은 확인이 새 전송에 섞이지 않게)로 다시 보낼 차례에 둔다. 세대도 다시 보낸다.
    pub fn resendAll(self: *Tab, budget: *Budget) void {
        for (self.rules.items) |*r| {
            if (r.body.len != 0) r.body_id = budget.takeBodyId();
            r.body_queued = false;
        }
        self.sent_gen = 0;
        self.acked_gen = 0;
    }

    /// sidecar 의 답(`net_mock_state`) — 그 세대의 것만.
    pub fn onState(self: *Tab, v: msg.NetMockState) void {
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

    /// sidecar 의 수(차이) — 번호로 누적한다(지운 규칙의 늦은 수는 버린다).
    /// sidecar 의 수(차이)를 더한다. `full` — 설정 `browser.agent-network-full`: 꺼졌으면 서비스 워커 수(`sw_not_mocked`)를 적지 않는다(W9d③ 2 차 검증
    /// NEW-2 와 같은 꼴 — main 위로 옮기며 맞춤: 숨기기만 하면 다시 켤 때 꺼진 동안의 수가 보였다).
    pub fn onHits(self: *Tab, v: msg.NetMockHits, full: bool) void {
        self.unrecorded +|= v.unrecorded;
        self.busy +|= v.busy;
        self.skipped_unknown_page +|= v.skipped_unknown_page;
        if (v.page_controlled) self.page_controlled_doc = true;
        for (v.entries[0..v.count]) |e| for (self.rules.items) |*r| if (r.id == e.rule_id) {
            r.hits +|= e.hits;
            r.frame_not_mocked +|= e.frame_not_mocked; // 이 탭의 요청 — 맞음 수와 같은 오라클이라 설정과 무관
            if (full) r.sw_not_mocked +|= e.sw_not_mocked;
        };
    }

    /// 설정 `browser.agent-network-full` 이 꺼졌다 — 켜졌을 때만 보이는 서비스 워커 수를 지운다(막기의 `forgetFullCounts` 와 같다).
    pub fn forgetFullCounts(self: *Tab) void {
        for (self.rules.items) |*r| r.sw_not_mocked = 0;
    }

    pub fn newDocument(self: *Tab) void {
        self.page_controlled_doc = false;
    }

    /// 보낼 규칙 frame(`index` 번째 — 글은 이 탭을 빌린다).
    pub fn ruleWire(self: *const Tab, browser: u64, index: usize) msg.NetMockRule {
        const r = &self.rules.items[index];
        return .{
            .browser = browser,
            .generation = self.gen,
            .index = @intCast(index),
            .id = r.id,
            .types = r.types,
            .methods = r.methods,
            .flags = .{ .exec_site_bound = r.exec_site.slice().len != 0, .human_nav_real = r.human_nav_real },
            .site = r.site.slice(),
            .exec_site = r.exec_site.slice(),
            .pattern = r.pattern(),
            .status = r.status,
            .body_id = r.body_id,
            .body_len = @intCast(r.body.len),
            .content_type = r.content_type,
            .location = r.location,
            .headers = r.headerBlock(),
        };
    }

    pub fn commitWire(self: *const Tab, browser: u64) msg.NetMockCommit {
        return .{ .browser = browser, .generation = self.gen, .count = @intCast(@min(self.rules.items.len, max_rules)), .strict_site = if (self.strict_on) self.strict_site.slice() else "" };
    }

    pub fn wantsNotice(self: *Tab) bool {
        if (!self.active() or self.noticed_gen == self.gen) return false;
        self.noticed_gen = self.gen;
        return true;
    }

    /// 규칙 번호의 본문(그 번호의 본문이 지금도 그 번호면 — 기록의 `body_state:"mocked"`). 없으면 null.
    pub fn bodyOf(self: *const Tab, rule_id: u32, body_id: u32) ?[]const u8 {
        for (self.rules.items) |*r| if (r.id == rule_id) return if (r.body_id == body_id) r.body else null;
        return null;
    }

    pub fn ruleById(self: *const Tab, rule_id: u32) ?*const Rule {
        for (self.rules.items) |*r| if (r.id == rule_id) return r;
        return null;
    }

    /// 결과 JSON(`browser.networkMock`) — 제 규칙은 모두, 다른 pane 의 규칙은 수만. 설정(`full`)이 꺼졌으면 서비스 워커 수를 숨기고 다스림
    /// 표시만(§13 P1-9 — 수가 사용자 요청의 오라클이 된다).
    pub fn resultJson(self: *const Tab, out: std.mem.Allocator, owner: u64, outcome: Outcome, page_site: []const u8, full: bool, app_bytes: usize) std.mem.Allocator.Error![]u8 {
        var aw: std.Io.Writer.Allocating = .init(out);
        defer aw.deinit();
        var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
        self.writeResult(&s, owner, outcome, page_site, full, app_bytes) catch return error.OutOfMemory;
        return aw.toOwnedSlice();
    }

    fn writeResult(self: *const Tab, s: *std.json.Stringify, owner: u64, outcome: Outcome, page_site: []const u8, full: bool, app_bytes: usize) !void {
        var other: usize = 0;
        var dormant = false;
        var no_acao = false;
        var frames_bound = false;
        var frames_not_mocked = false;
        var no_charset = false;
        var sw_total: u64 = 0;
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
            }
            if (r.methods != 0) {
                var names: [mr.method_names.len][]const u8 = undefined;
                try s.objectField("methods");
                try s.write(mr.methodNames(r.methods, &names));
            }
            try s.objectField("site");
            try s.write(r.site.slice());
            try s.objectField("status");
            try s.write(r.status);
            try s.objectField("content_type");
            try s.write(r.content_type);
            try s.objectField("body_bytes");
            try s.write(r.body.len);
            try s.objectField("headers");
            try s.beginArray();
            if (r.location.len != 0) try s.write("Location");
            var it = nf.HeaderIterator.init(r.headerBlock());
            while (it.next()) |h| try s.write(h.name);
            try s.endArray();
            try s.objectField("hits");
            try s.write(r.hits);
            if (full) {
                try s.objectField("sw_not_mocked");
                try s.write(r.sw_not_mocked);
            }
            sw_total +|= r.sw_not_mocked;
            if (r.frame_not_mocked != 0) {
                try s.objectField("frame_not_mocked");
                try s.write(r.frame_not_mocked);
                frames_not_mocked = true;
            }
            if (page_site.len != 0 and !policy.hostCovers(r.site.slice(), page_site)) {
                try s.objectField("dormant");
                try s.write(true);
                dormant = true;
            }
            try s.endObject();
            if (crossOriginWithoutAcao(r, page_site)) no_acao = true;
            if (r.exec_site.slice().len != 0 and mr.documentCapable(r.types)) frames_bound = true;
            if (mr.textWithoutCharset(r.content_type)) no_charset = true;
        }
        try s.endArray();
        try s.objectField("other_rules");
        try s.write(other);
        try s.objectField("total");
        try s.write(self.rules.items.len);
        try s.objectField("max");
        try s.write(max_rules);
        try s.objectField("bytes");
        try s.beginObject();
        try s.objectField("tab");
        try s.write(self.bodyBytes());
        try s.objectField("tab_max");
        try s.write(mr.max_tab_body_bytes);
        try s.objectField("app");
        try s.write(app_bytes);
        try s.objectField("app_max");
        try s.write(mr.max_app_body_bytes);
        try s.endObject();
        if (outcome.added) |id| {
            try s.objectField("added");
            try s.write(id);
        }
        if (outcome.replaced) |id| {
            try s.objectField("replaced");
            try s.write(id);
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
        try s.endObject();
        try s.objectField("page_site");
        try s.write(page_site);
        try s.objectField("unrecorded");
        try s.write(self.unrecorded);
        try s.objectField("busy");
        try s.write(self.busy);
        try s.objectField("skipped_unknown_page");
        try s.write(self.skipped_unknown_page);
        const controlled = self.page_controlled_doc or sw_total > 0;
        try s.objectField("service_worker");
        try s.beginObject();
        try s.objectField("page_controlled");
        try s.write(self.page_controlled_doc);
        if (full) {
            try s.objectField("not_mocked_total");
            try s.write(sw_total);
        }
        try s.endObject();
        const sw_warn = controlled and !self.strict_on;
        if (sw_warn or dormant or no_acao or frames_bound or frames_not_mocked or no_charset) {
            try s.objectField("warnings");
            try s.beginArray();
            if (sw_warn) try s.write("service_worker_not_mocked");
            if (dormant) try s.write("dormant_other_site");
            if (no_acao) try s.write("cross_origin_without_acao");
            if (frames_bound) try s.write("frame_types_site_bound");
            if (frames_not_mocked) try s.write("cross_site_frame_not_mocked");
            if (no_charset) try s.write("text_without_charset");
            try s.endArray();
        }
        try s.endObject();
    }
};

/// 패턴의 호스트가 정확한 호스트이고 페이지 사이트와 다른데(다른 출처) `Access-Control-Allow-Origin` 이 없다 — fetch·XHR 은 CORS 로 떨어진다(M6).
fn crossOriginWithoutAcao(r: *const Rule, page_site: []const u8) bool {
    if (page_site.len == 0) return false;
    const p = switch (nb.parse(r.pattern())) {
        .ok => |v| v,
        .err => return false,
    };
    if (p.host_kind != .exact) return false;
    if (std.ascii.eqlIgnoreCase(p.host(), page_site)) return false;
    var it = nf.HeaderIterator.init(r.headerBlock());
    while (it.next()) |h| if (std.ascii.eqlIgnoreCase(h.name, "access-control-allow-origin")) return false;
    return true;
}

fn keeps(mock_grants: []const OwnerGrant, net_panes: []const u64, browser_panes: []const u64, owner: u64, site: []const u8) bool {
    if (std.mem.indexOfScalar(u64, net_panes, owner) == null) return false;
    if (std.mem.indexOfScalar(u64, browser_panes, owner) == null) return false;
    for (mock_grants) |g| if (g.pane == owner) {
        if (g.any_host or policy.hostCovers(g.host, site)) return true;
    };
    return false;
}

// ── 시험 ────────────────────────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn mkCall(owner: u64, action: Action, opts: struct { pattern: []const u8 = "", types: u32 = 0, methods: u8 = 0, response: Response = .{}, rules: []const u32 = &.{}, on: ?bool = null, site: []const u8 = "a.test", exec_site: []const u8 = "", human: bool = false, now_ms: i64 = 0 }) Call {
    return .{ .owner = owner, .action = action, .pattern = opts.pattern, .types = opts.types, .methods = opts.methods, .response = opts.response, .rules = opts.rules, .on = opts.on, .site = opts.site, .exec_site = opts.exec_site, .human_nav_real = opts.human, .now_ms = opts.now_ms };
}

test "W9d④: add — 같은 (패턴·종류·메서드)면 응답을 바꾸고 번호는 그대로(replaced), 다른 pane·메서드는 따로, 32 개, 사이트 없는 페이지는 no_site" {
    var t: Tab = .{};
    var b: Budget = .{};
    defer t.deinit(testing.allocator, &b);
    var fail: Failure = undefined;
    const a = try t.apply(testing.allocator, &b, mkCall(5, .add, .{ .pattern = "https://a.test/api", .response = .{ .body = "one" } }), &fail);
    try testing.expectEqual(@as(?u32, 1), a.added);
    const first_body = t.rules.items[0].body_id;
    try testing.expect(first_body != 0);
    t.rules.items[0].hits = 7;
    const r = try t.apply(testing.allocator, &b, mkCall(5, .add, .{ .pattern = "https://a.test/api", .response = .{ .status = 404, .body = "two!" }, .now_ms = 1 }), &fail);
    try testing.expectEqual(@as(?u32, 1), r.replaced);
    try testing.expectEqual(@as(usize, 1), t.rules.items.len);
    try testing.expectEqual(@as(u16, 404), t.rules.items[0].status);
    try testing.expect(t.rules.items[0].body_id != first_body); // 새 본문은 새 번호
    try testing.expectEqual(@as(u64, 7), t.rules.items[0].hits);
    try testing.expectEqual(@as(usize, 4), b.app_bytes);
    _ = try t.apply(testing.allocator, &b, mkCall(5, .add, .{ .pattern = "https://a.test/api", .methods = 1, .now_ms = 2 }), &fail);
    _ = try t.apply(testing.allocator, &b, mkCall(6, .add, .{ .pattern = "https://a.test/api", .now_ms = 3 }), &fail);
    try testing.expectEqual(@as(usize, 3), t.rules.items.len);
    try testing.expectError(error.Rejected, t.apply(testing.allocator, &b, mkCall(5, .add, .{ .pattern = "https://b.test/", .site = "", .now_ms = 4 }), &fail));
    try testing.expectEqualStrings("no_site", fail.reason);
    var bufs: [32][32]u8 = undefined;
    var now: i64 = 1000;
    for (0..29) |i| {
        now += 200;
        _ = try t.apply(testing.allocator, &b, mkCall(5, .add, .{ .pattern = std.fmt.bufPrint(&bufs[i], "https://a.test/{d}", .{i}) catch unreachable, .now_ms = now }), &fail);
    }
    try testing.expectEqual(@as(usize, 32), t.rules.items.len);
    try testing.expectError(error.Rejected, t.apply(testing.allocator, &b, mkCall(5, .add, .{ .pattern = "https://a.test/x", .now_ms = now + 200 }), &fail));
    try testing.expectEqualStrings("too_many_rules", fail.reason);
    // 같은 규칙의 바꾸기는 32 개여도 된다.
    _ = try t.apply(testing.allocator, &b, mkCall(5, .add, .{ .pattern = "https://a.test/api", .response = .{ .body = "3" }, .now_ms = now + 400 }), &fail);
}

test "W9d④: 본문 셈 — 탭 4 MiB(tab_bytes_exceeded)·앱 32 MiB(resource_busy browser-mock-bytes), 바꾸기·지우기·clear 가 앱 셈을 돌려준다" {
    var t: Tab = .{};
    var b: Budget = .{};
    defer t.deinit(testing.allocator, &b);
    var fail: Failure = undefined;
    const half = try testing.allocator.alloc(u8, mr.max_body_bytes);
    defer testing.allocator.free(half);
    @memset(half, 'x');
    var bufs: [9][32]u8 = undefined;
    for (0..8) |i| _ = try t.apply(testing.allocator, &b, mkCall(5, .add, .{ .pattern = std.fmt.bufPrint(&bufs[i], "https://a.test/{d}", .{i}) catch unreachable, .response = .{ .body = half }, .now_ms = @as(i64, @intCast(i)) * 200 }), &fail);
    try testing.expectEqual(mr.max_tab_body_bytes, t.bodyBytes());
    try testing.expectError(error.Rejected, t.apply(testing.allocator, &b, mkCall(5, .add, .{ .pattern = "https://a.test/9", .response = .{ .body = "y" }, .now_ms = 5000 }), &fail));
    try testing.expectEqualStrings("tab_bytes_exceeded", fail.reason);
    // 같은 규칙을 같은 크기로 바꾸는 것은 된다.
    _ = try t.apply(testing.allocator, &b, mkCall(5, .add, .{ .pattern = "https://a.test/0", .response = .{ .body = half }, .now_ms = 6000 }), &fail);
    try testing.expectEqual(mr.max_tab_body_bytes, b.app_bytes);
    var other: Tab = .{};
    defer other.deinit(testing.allocator, &b);
    b.app_bytes = mr.max_app_body_bytes - 1;
    try testing.expectError(error.Rejected, other.apply(testing.allocator, &b, mkCall(6, .add, .{ .pattern = "https://a.test/z", .response = .{ .body = "ab" } }), &fail));
    try testing.expectEqualStrings("resource_busy", fail.reason);
    try testing.expectEqualStrings("browser-mock-bytes", fail.resource.?);
    b.app_bytes = mr.max_tab_body_bytes;
    _ = try t.apply(testing.allocator, &b, mkCall(5, .remove, .{ .rules = &.{1}, .now_ms = 7000 }), &fail);
    try testing.expectEqual(mr.max_tab_body_bytes - mr.max_body_bytes, b.app_bytes);
    _ = try t.apply(testing.allocator, &b, mkCall(5, .clear, .{ .now_ms = 8000 }), &fail);
    try testing.expectEqual(@as(usize, 0), b.app_bytes);
}

test "W9d④: remove·clear·엄격·초당 10 번 — 남의 규칙은 지우지 못한다(index), 패턴으로, clear 는 제 것만(엄격 그대로), 엄격은 사이트에 묶임" {
    var t: Tab = .{};
    var b: Budget = .{};
    defer t.deinit(testing.allocator, &b);
    var fail: Failure = undefined;
    _ = try t.apply(testing.allocator, &b, mkCall(5, .add, .{ .pattern = "https://a.test/x" }), &fail);
    _ = try t.apply(testing.allocator, &b, mkCall(5, .add, .{ .pattern = "https://a.test/y", .now_ms = 1 }), &fail);
    _ = try t.apply(testing.allocator, &b, mkCall(6, .add, .{ .pattern = "https://a.test/z", .now_ms = 2 }), &fail);
    _ = try t.apply(testing.allocator, &b, mkCall(5, .strict, .{ .on = true, .now_ms = 3 }), &fail);
    try testing.expect(t.strict_on and t.strict_state == .sent);
    try testing.expectError(error.Rejected, t.apply(testing.allocator, &b, mkCall(5, .remove, .{ .rules = &.{ 1, 3 }, .now_ms = 4 }), &fail));
    try testing.expectEqualStrings("unknown_rule", fail.reason);
    try testing.expectEqual(@as(?usize, 1), fail.index);
    const r = try t.apply(testing.allocator, &b, mkCall(5, .remove, .{ .pattern = "https://a.test/y", .now_ms = 5 }), &fail);
    try testing.expectEqualSlices(u32, &.{2}, r.removed.slice());
    const c = try t.apply(testing.allocator, &b, mkCall(5, .clear, .{ .now_ms = 6 }), &fail);
    try testing.expectEqualSlices(u32, &.{1}, c.removed.slice());
    try testing.expect(t.strict_on);
    t.onState(.{ .browser = 1, .generation = t.gen, .ok = true, .strict = .on });
    try testing.expect(t.strict_state == .on);
    _ = try t.apply(testing.allocator, &b, mkCall(5, .strict, .{ .on = false, .now_ms = 7 }), &fail);
    try testing.expect(!t.strict_on);
    for (0..2) |_| _ = try t.apply(testing.allocator, &b, mkCall(5, .strict, .{ .on = true, .now_ms = 8 }), &fail); // 1 초 안의 열째까지(거절된 remove 도 센다)
    try testing.expectError(error.Rejected, t.apply(testing.allocator, &b, mkCall(5, .clear, .{ .now_ms = 9 }), &fail));
    try testing.expectEqualStrings("resource_busy", fail.reason);
    _ = try t.apply(testing.allocator, &b, mkCall(5, .list, .{ .now_ms = 9 }), &fail); // 보기는 세지 않는다
}

test "W9d④: sync — 주인의 mock·network·browser grant 중 하나라도 사라지거나 묶인 호스트가 사이트를 더 덮지 않으면 규칙·엄격을 버리고 앱 셈을 돌려준다" {
    var t: Tab = .{};
    var b: Budget = .{};
    defer t.deinit(testing.allocator, &b);
    var fail: Failure = undefined;
    _ = try t.apply(testing.allocator, &b, mkCall(5, .add, .{ .pattern = "https://a.test/x", .site = "app.a.test", .response = .{ .body = "abc" } }), &fail);
    _ = try t.apply(testing.allocator, &b, mkCall(6, .add, .{ .pattern = "https://b.test/y", .site = "bank.test", .now_ms = 1 }), &fail);
    _ = try t.apply(testing.allocator, &b, mkCall(6, .strict, .{ .on = true, .site = "bank.test", .now_ms = 2 }), &fail);
    const grants = [_]OwnerGrant{ .{ .pane = 5, .host = "a.test" }, .{ .pane = 6, .any_host = true } };
    try testing.expect(!t.sync(testing.allocator, &b, &grants, &.{ 5, 6 }, &.{ 5, 6 }));
    try testing.expect(t.sync(testing.allocator, &b, &grants, &.{ 5, 6 }, &.{5})); // pane 6 의 browser grant 가 사라졌다(eval 위에 선다)
    try testing.expectEqual(@as(usize, 1), t.rules.items.len);
    try testing.expect(!t.strict_on);
    try testing.expect(t.sync(testing.allocator, &b, &grants, &.{6}, &.{ 5, 6 })); // pane 5 의 네트워크 grant
    try testing.expect(!t.active());
    try testing.expectEqual(@as(usize, 0), b.app_bytes);
    _ = try t.apply(testing.allocator, &b, mkCall(5, .add, .{ .pattern = "https://a.test/x", .site = "app.a.test", .now_ms = 3 }), &fail);
    try testing.expect(t.sync(testing.allocator, &b, &.{.{ .pane = 5, .host = "other.test" }}, &.{5}, &.{5})); // 다른 호스트로 다시 허용
}

test "W9d④: wire 꼴 — 규칙 frame 들과 맺음은 닫힌 칸을 지난다(Location·머리·본문 번호·실행 사이트·사람 표시), 다시 보내면 본문마다 새 번호" {
    var t: Tab = .{};
    var b: Budget = .{};
    defer t.deinit(testing.allocator, &b);
    var fail: Failure = undefined;
    _ = try t.apply(testing.allocator, &b, mkCall(5, .add, .{ .pattern = "https://a.test/r", .types = 1 << 13, .response = .{ .status = 302, .headers = &.{ .{ .name = "Location", .value = "/next" }, .{ .name = "X-Mock", .value = "1" } } }, .exec_site = "a.test", .human = true }), &fail);
    _ = try t.apply(testing.allocator, &b, mkCall(5, .add, .{ .pattern = "https://a.test/doc", .response = .{ .content_type = "text/html; charset=utf-8", .body = "<p>x" }, .now_ms = 1 }), &fail);
    var buf: [ws.wire.max_frame_bytes]u8 = undefined;
    for (0..t.rules.items.len) |i| _ = try ws.codec.encode(.{ .net_mock_rule = t.ruleWire(7, i) }, &buf);
    const w0 = t.ruleWire(7, 0);
    try testing.expectEqualStrings("/next", w0.location);
    try testing.expectEqual(@as(u8, 1), w0.headers.count); // Location 은 제 칸으로
    try testing.expect(w0.flags.exec_site_bound and w0.flags.human_nav_real);
    _ = try ws.codec.encode(.{ .net_mock_commit = t.commitWire(7) }, &buf);
    const old = t.rules.items[1].body_id;
    t.rules.items[1].body_queued = true;
    t.resendAll(&b);
    try testing.expect(t.rules.items[1].body_id != old and !t.rules.items[1].body_queued);
    try testing.expectEqual(@as(u32, 0), t.rules.items[0].body_id); // 빈 본문은 번호가 없다
    try testing.expectEqualStrings("<p>x", t.bodyOf(2, t.rules.items[1].body_id).?);
    try testing.expect(t.bodyOf(2, old) == null); // 바뀐 번호 — 그때의 본문이 아니다
}

test "W9d④: 수의 누적과 결과 JSON — 다른 pane 은 수만, 설정 끔이면 서비스 워커 수를 숨긴다, 경고(서비스 워커·잠듦·ACAO 없음·실행 사이트·charset)" {
    var t: Tab = .{};
    var b: Budget = .{};
    defer t.deinit(testing.allocator, &b);
    var fail: Failure = undefined;
    _ = try t.apply(testing.allocator, &b, mkCall(5, .add, .{ .pattern = "https://api.other.test/v1/*", .types = 1 << 13, .response = .{ .content_type = "text/plain" } }), &fail);
    _ = try t.apply(testing.allocator, &b, mkCall(5, .add, .{ .pattern = "https://a.test/doc", .site = "b.test", .exec_site = "b.test", .response = .{ .content_type = "text/html; charset=utf-8" }, .now_ms = 1 }), &fail);
    _ = try t.apply(testing.allocator, &b, mkCall(6, .add, .{ .pattern = "https://a.test/z", .now_ms = 2 }), &fail);
    var h: msg.NetMockHits = .{ .browser = 1, .unrecorded = 2, .busy = 3, .page_controlled = true, .count = 2 };
    h.entries[0] = .{ .rule_id = 1, .hits = 3, .sw_not_mocked = 4 };
    h.entries[1] = .{ .rule_id = 99, .hits = 1 };
    t.onHits(h, true);
    t.onHits(h, true);
    try testing.expectEqual(@as(u64, 6), t.rules.items[0].hits);
    try testing.expectEqual(@as(u64, 6), t.busy);
    for ([_]bool{ true, false }) |full| {
        const json = try t.resultJson(testing.allocator, 5, .{}, "a.test", full, 123);
        defer testing.allocator.free(json);
        const p = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
        defer p.deinit();
        const o = p.value.object;
        try testing.expectEqual(@as(usize, 2), o.get("rules").?.array.items.len);
        try testing.expectEqual(@as(i64, 1), o.get("other_rules").?.integer);
        try testing.expectEqual(@as(i64, 123), o.get("bytes").?.object.get("app").?.integer);
        try testing.expectEqualStrings("sent", o.get("state").?.string);
        const r0 = o.get("rules").?.array.items[0].object;
        try testing.expectEqual(full, r0.get("sw_not_mocked") != null);
        try testing.expectEqual(full, o.get("service_worker").?.object.get("not_mocked_total") != null);
        try testing.expect(o.get("service_worker").?.object.get("page_controlled").?.bool);
        try testing.expect(o.get("rules").?.array.items[1].object.get("dormant").?.bool);
        var names: std.ArrayList(u8) = .empty;
        defer names.deinit(testing.allocator);
        for (o.get("warnings").?.array.items) |w| try names.appendSlice(testing.allocator, w.string);
        for ([_][]const u8{ "service_worker_not_mocked", "dormant_other_site", "cross_origin_without_acao", "frame_types_site_bound", "text_without_charset" }) |want| try testing.expect(std.mem.indexOf(u8, names.items, want) != null);
    }
    t.newDocument();
    try testing.expect(!t.page_controlled_doc);
    try testing.expect(t.wantsNotice());
    try testing.expect(!t.wantsNotice());
}

test "W9d④ 변이: 패턴으로 지우기는 제 규칙만, 엄격 켬은 사이트가 있어야·다른 pane·사이트로 옮긴다, 바꾸기는 앱 셈이 찬 때도 같은 크기면 된다, 지난 세대의 상태는 버린다, 적용 못 한 세대의 엄격은 failed, clearAll 은 엄격도 끈다" {
    var t: Tab = .{};
    var b: Budget = .{};
    defer t.deinit(testing.allocator, &b);
    var fail: Failure = undefined;
    _ = try t.apply(testing.allocator, &b, mkCall(5, .add, .{ .pattern = "https://a.test/x", .response = .{ .body = "ab" } }), &fail);
    _ = try t.apply(testing.allocator, &b, mkCall(6, .add, .{ .pattern = "https://a.test/x", .now_ms = 1 }), &fail);
    const r = try t.apply(testing.allocator, &b, mkCall(5, .remove, .{ .pattern = "https://a.test/x", .now_ms = 2 }), &fail);
    try testing.expectEqualSlices(u32, &.{1}, r.removed.slice());
    try testing.expectEqual(@as(usize, 1), t.rules.items.len);
    try testing.expectEqual(@as(u64, 6), t.rules.items[0].owner); // 다른 pane 의 같은 패턴은 남는다
    try testing.expectError(error.Rejected, t.apply(testing.allocator, &b, mkCall(5, .strict, .{ .on = true, .site = "", .now_ms = 3 }), &fail));
    try testing.expectEqualStrings("no_site", fail.reason);
    try testing.expect(!t.strict_on);
    _ = try t.apply(testing.allocator, &b, mkCall(5, .strict, .{ .on = true, .now_ms = 4 }), &fail);
    // 다른 pane 은 가져가지 못하고(v2 R13 — `other_pane`), 주인은 다른 사이트로 옮긴다.
    try testing.expectError(error.Rejected, t.apply(testing.allocator, &b, mkCall(6, .strict, .{ .on = true, .site = "b.test", .now_ms = 5 }), &fail));
    try testing.expectEqualStrings("other_pane", fail.reason);
    _ = try t.apply(testing.allocator, &b, mkCall(5, .strict, .{ .on = true, .site = "b.test", .now_ms = 5 }), &fail);
    try testing.expectEqual(@as(u64, 5), t.strict_owner);
    try testing.expectEqualStrings("b.test", t.strict_site.slice());
    // 지난 세대의 답은 버린다, 적용하지 못한 세대(ok 거짓)의 엄격은 failed.
    const gen = t.gen;
    t.onState(.{ .browser = 1, .generation = gen -% 1, .ok = true, .strict = .on });
    try testing.expect(t.acked_gen != gen and t.strict_state == .sent);
    t.onState(.{ .browser = 1, .generation = gen, .ok = false, .strict = .off });
    try testing.expect(t.strict_state == .failed);
    try testing.expect(t.clearAll(testing.allocator, &b));
    try testing.expect(!t.strict_on and !t.active());
    // 앱 셈이 상한까지 찼어도 같은 크기로 바꾸기는 된다(제 몫을 빼고 센다).
    const half = try testing.allocator.alloc(u8, mr.max_body_bytes);
    defer testing.allocator.free(half);
    @memset(half, 'x');
    _ = try t.apply(testing.allocator, &b, mkCall(5, .add, .{ .pattern = "https://a.test/big", .response = .{ .body = half }, .now_ms = 2000 }), &fail);
    b.app_bytes = mr.max_app_body_bytes;
    _ = try t.apply(testing.allocator, &b, mkCall(5, .add, .{ .pattern = "https://a.test/big", .response = .{ .body = half }, .now_ms = 2001 }), &fail);
    try testing.expectEqual(mr.max_app_body_bytes, b.app_bytes);
    b.app_bytes = mr.max_body_bytes;
    // 같은 패턴이라도 다른 사이트에서 더하면 따로 둔다(바꾸지 않는다 — 규칙은 더한 사이트에 묶인다).
    _ = try t.apply(testing.allocator, &b, mkCall(5, .add, .{ .pattern = "https://c.test/p", .now_ms = 4000 }), &fail);
    const o = try t.apply(testing.allocator, &b, mkCall(5, .add, .{ .pattern = "https://c.test/p", .site = "b.test", .now_ms = 4001 }), &fail);
    try testing.expect(o.added != null and o.replaced == null);
}

test "W9d④ 변이: 결과 JSON 의 경고는 그때만 — 엄격이 켜졌으면 서비스 워커 경고 없음, 페이지를 모르면 잠듦 없음, 와일드카드 호스트는 ACAO 경고 없음, 문서가 아닌 종류는 실행 사이트 경고 없음" {
    var t: Tab = .{};
    var b: Budget = .{};
    defer t.deinit(testing.allocator, &b);
    var fail: Failure = undefined;
    _ = try t.apply(testing.allocator, &b, mkCall(5, .add, .{ .pattern = "https://*.other.test/*", .types = 1 << 13, .site = "b.test", .exec_site = "b.test", .response = .{ .content_type = "application/json" } }), &fail);
    _ = try t.apply(testing.allocator, &b, mkCall(5, .strict, .{ .on = true, .now_ms = 1 }), &fail);
    t.onHits(.{ .browser = 1, .page_controlled = true }, true);
    for ([_][]const u8{ "", "a.test" }) |page| {
        const json = try t.resultJson(testing.allocator, 5, .{}, page, true, 0);
        defer testing.allocator.free(json);
        const p = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
        defer p.deinit();
        const o = p.value.object;
        try testing.expectEqual(page.len != 0, o.get("rules").?.array.items[0].object.get("dormant") != null);
        var names: std.ArrayList(u8) = .empty;
        defer names.deinit(testing.allocator);
        if (o.get("warnings")) |ws_| for (ws_.array.items) |w| try names.appendSlice(testing.allocator, w.string);
        for ([_][]const u8{ "service_worker_not_mocked", "cross_origin_without_acao", "frame_types_site_bound" }) |no| try testing.expect(std.mem.indexOf(u8, names.items, no) == null);
    }
}

test "W9d④ main 위로 옮김: 설정이 꺼지면 서비스 워커 수를 지우고, 꺼진 동안 온 수는 적지 않는다(W9d③ NEW-2 와 같은 꼴) — 맞음 수는 그대로" {
    var t: Tab = .{};
    var b: Budget = .{};
    defer t.deinit(testing.allocator, &b);
    var fail: Failure = undefined;
    _ = try t.apply(testing.allocator, &b, mkCall(5, .add, .{ .pattern = "https://a.test/api/*", .types = 1 << 13, .response = .{ .content_type = "text/plain" } }), &fail);
    var h: msg.NetMockHits = .{ .browser = 1, .count = 1 };
    h.entries[0] = .{ .rule_id = 1, .hits = 2, .sw_not_mocked = 3 };
    t.onHits(h, true);
    try testing.expectEqual(@as(u64, 3), t.rules.items[0].sw_not_mocked);
    t.forgetFullCounts();
    try testing.expectEqual(@as(u64, 0), t.rules.items[0].sw_not_mocked);
    t.onHits(h, false);
    try testing.expectEqual(@as(u64, 0), t.rules.items[0].sw_not_mocked);
    try testing.expectEqual(@as(u64, 4), t.rules.items[0].hits);
}

test "W9d④ v2 R13: 가짜 엄격은 켠 pane 의 것 — 다른 pane 의 끔·켬(다른 사이트로도)은 other_pane(1 초 10 번 자리를 쓰지 않는다), 그 pane 이 grant 를 잃어도 남고, 주인이 잃으면 사라진다, 꺼진 뒤에는 누구든" {
    var t: Tab = .{};
    var b: Budget = .{};
    defer t.deinit(testing.allocator, &b);
    var fail: Failure = undefined;
    _ = try t.apply(testing.allocator, &b, mkCall(5, .strict, .{ .on = true }), &fail);
    const g0 = t.gen;
    var now: i64 = 1;
    for ([_]Call{
        mkCall(6, .strict, .{ .on = false }),
        mkCall(6, .strict, .{ .on = true }),
        mkCall(6, .strict, .{ .on = true, .site = "b.test" }),
    }) |c0| {
        // 1 초 안에 열 번을 넘겨 보낸다 — 거절이 자리를 쓰면 주인의 다음 바꾸기가 resource_busy 가 된다.
        for (0..4) |_| {
            var c = c0;
            c.now_ms = now;
            try testing.expectError(error.Rejected, t.apply(testing.allocator, &b, c, &fail));
            try testing.expectEqualStrings("other_pane", fail.reason);
        }
        now += 1;
        try testing.expect(t.strict_on and t.strict_owner == 5 and t.gen == g0);
        try testing.expectEqualStrings("a.test", t.strict_site.slice());
    }
    // pane 6 의 결과는 other_pane, pane 5 는 아니다.
    const j6 = try t.resultJson(testing.allocator, 6, .{}, "a.test", true, 0);
    defer testing.allocator.free(j6);
    try testing.expect(std.mem.indexOf(u8, j6, "\"other_pane\":true") != null);
    const j5 = try t.resultJson(testing.allocator, 5, .{}, "a.test", true, 0);
    defer testing.allocator.free(j5);
    try testing.expect(std.mem.indexOf(u8, j5, "other_pane") == null);
    // pane 6 이 mock grant 를 잃어도(sync) pane 5 의 엄격은 남는다.
    const both = [_]OwnerGrant{ .{ .pane = 5, .any_host = true }, .{ .pane = 6, .any_host = true } };
    try testing.expect(!t.sync(testing.allocator, &b, &both, &.{ 5, 6 }, &.{ 5, 6 }));
    try testing.expect(!t.sync(testing.allocator, &b, &.{.{ .pane = 5, .any_host = true }}, &.{ 5, 6 }, &.{ 5, 6 }));
    try testing.expect(t.strict_on and t.strict_owner == 5);
    // 주인은 1 초 안에도 바꿀 수 있다(거절이 자리를 쓰지 않았다) — 다른 사이트로 옮긴다.
    _ = try t.apply(testing.allocator, &b, mkCall(5, .strict, .{ .on = true, .site = "b.test", .now_ms = now }), &fail);
    try testing.expect(t.strict_owner == 5);
    try testing.expectEqualStrings("b.test", t.strict_site.slice());
    // 주인이 grant 를 잃으면 사라지고, 그 뒤에는 pane 6 이 켠다(주인이 된다).
    try testing.expect(t.sync(testing.allocator, &b, &.{.{ .pane = 6, .any_host = true }}, &.{ 5, 6 }, &.{ 5, 6 }));
    try testing.expect(!t.strict_on);
    _ = try t.apply(testing.allocator, &b, mkCall(6, .strict, .{ .on = true, .now_ms = now + 1 }), &fail);
    try testing.expect(t.strict_on and t.strict_owner == 6);
}

test "W9d④ v1 SEVERE-1: 허락 밖 프레임의 수(frame_not_mocked)는 주인 규칙에 누적되고(설정과 무관 — 이 탭의 요청), 바꾸기가 지키며, 결과에 그 수와 경고 cross_site_frame_not_mocked — 다른 pane 은 보지 않는다" {
    var t: Tab = .{};
    var b: Budget = .{};
    defer t.deinit(testing.allocator, &b);
    var fail: Failure = undefined;
    _ = try t.apply(testing.allocator, &b, mkCall(5, .add, .{ .pattern = "https://a.test/m/*", .types = 1 << 2, .exec_site = "a.test", .response = .{ .content_type = "text/javascript" } }), &fail);
    {
        const j = try t.resultJson(testing.allocator, 5, .{}, "a.test", true, 0);
        defer testing.allocator.free(j);
        try testing.expect(std.mem.indexOf(u8, j, "frame_not_mocked") == null); // 없으면 싣지 않는다
    }
    var h: msg.NetMockHits = .{ .browser = 1, .count = 1 };
    h.entries[0] = .{ .rule_id = 1, .frame_not_mocked = 2 };
    t.onHits(h, false);
    _ = try t.apply(testing.allocator, &b, mkCall(5, .add, .{ .pattern = "https://a.test/m/*", .types = 1 << 2, .exec_site = "a.test", .response = .{ .content_type = "text/javascript", .body = "x" }, .now_ms = 1 }), &fail);
    try testing.expectEqual(@as(u64, 2), t.rules.items[0].frame_not_mocked); // 응답 바꾸기가 지킨다
    const j5 = try t.resultJson(testing.allocator, 5, .{}, "a.test", false, 0);
    defer testing.allocator.free(j5);
    const p = try std.json.parseFromSlice(std.json.Value, testing.allocator, j5, .{});
    defer p.deinit();
    try testing.expectEqual(@as(i64, 2), p.value.object.get("rules").?.array.items[0].object.get("frame_not_mocked").?.integer);
    var names: std.ArrayList(u8) = .empty;
    defer names.deinit(testing.allocator);
    for (p.value.object.get("warnings").?.array.items) |w| try names.appendSlice(testing.allocator, w.string);
    try testing.expect(std.mem.indexOf(u8, names.items, "cross_site_frame_not_mocked") != null);
    const j6 = try t.resultJson(testing.allocator, 6, .{}, "a.test", true, 0);
    defer testing.allocator.free(j6);
    try testing.expect(std.mem.indexOf(u8, j6, "frame_not_mocked") == null);
}
