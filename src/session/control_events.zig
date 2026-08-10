//! control_events — browser 이벤트 채널 코어(L2 순수, 헤드리스). Track C 5f-0.
//! 단일 출처: docs/control-plane-browser-session.md §9.5.2(EventBroker)·§9.5.6(revoke/close 수명)·§9.4 D2·§7(events).
//!
//! **역할**: 서버→클라 push 이벤트(`browser.navigated`/`loadState`/`dialog`/`crashed`/`closed`)의 **구독 레지스트리 +
//! 매칭 + notification 직렬화 + coalesce 분류**를 순수하게 소유한다. 실 이벤트 소스(WKWebView KVO/delegate)는 L4가
//! 이 코어에 주입하고, per-subscriber 전달·outbound 큐·연결 스레드는 L4(§9.5.1·§9.5.6)가 소유한다.
//!
//! **seam(§9.5.2)**: 이 코어는 L4 connection을 모른다 → **opaque `SubscriberId`(u64)** 로만 구독을 식별한다. L4가
//! `SubscriberId ↔ OutboundQueue` 매핑을 소유한다. 연결 drop / surface close / cap revoke 시 L4가
//! `removeSubscriber`/`removeSurface`를 부르면 이 코어가 레지스트리를 정리한다(§9.5.6 수명).
//!
//! **coalesce(§9.5.2)**: 상태-스냅샷 이벤트(navigated·loadState)는 최신만 의미 있어 `isCoalescible`로 분류한다. 실
//! coalesce 버퍼링은 outbound 큐(L4)가 이 분류로 수행 — 이 코어는 **정책만** 소유한다.
//!
//! **범위 밖(구현 금지)**: network/pageError 이벤트(비신뢰 콘텐츠 주입 world 필요 = §9.4 D3 미룸), outbound
//! 큐·연결 스레드·실 WKWebView 소스(L4), backpressure drop 실행(큐). 여긴 레지스트리·매칭·직렬화·분류만.
//! (**console은 이벤트가 아니라 pull 메서드** `browser.console`로 구현 — 서버 버퍼+proactive drain, §9.5.9. 여기 EventKind 아님.)
//!
//! **L2 순수**: std + control_plane(1a)만 import(app/pty/platform 0 — tests/boundary/imports.zig 강제). OS 타입 0.

const std = @import("std");
const cp = @import("control_plane.zig");

// ── 이벤트 종류(§9.4 관측 축, 5f-0/5f-3 주입불요분) ──────────────────────────────────────────────────────────
/// server→client push 이벤트 종류. network/pageError는 비신뢰 콘텐츠 주입 world가 필요해 여기 없다(§9.4 D3 미룸).
/// console은 이벤트가 아니라 pull 메서드(`browser.console`, §9.5.9)라 여기 없다.
pub const EventKind = enum {
    /// 상태: 새 문서 URL(KVO `\.url`). coalescible.
    navigated,
    /// 상태: loading↔idle(nav delegate/KVO). coalescible.
    load_state,
    /// 이산: JS alert/confirm/prompt(`WKUIDelegate`).
    dialog,
    /// 이산: 웹 콘텐츠 프로세스 종료(`webViewWebContentProcessDidTerminate`).
    crashed,
    /// 이산: surface 파괴 → 구독 종료 마커(§9.5.2 수명).
    closed,

    /// notification method 이름(`browser.*`). §9.5.2 — `panel.navigated`를 흡수·통일.
    pub fn method(self: EventKind) []const u8 {
        return switch (self) {
            .navigated => "browser.navigated",
            .load_state => "browser.loadState",
            .dialog => "browser.dialog",
            .crashed => "browser.crashed",
            .closed => "browser.closed",
        };
    }

    /// 상태-스냅샷 이벤트만 coalescible(최신만 의미). 이산 이벤트는 각각 전달(§9.5.2 백프레셔 규범).
    pub fn isCoalescible(self: EventKind) bool {
        return self == .navigated or self == .load_state;
    }

    /// `browser.subscribe {events:[...]}`의 이벤트 이름(method suffix — `method()`와 대칭: "browser.navigated"→"navigated")을
    /// `EventKind`로 매핑한다(§9.5.2). 미지 이름 → null(호출자가 invalid_params). wire↔내부 격리(§3 정신).
    pub fn fromWire(name: []const u8) ?EventKind {
        if (std.mem.eql(u8, name, "navigated")) return .navigated;
        if (std.mem.eql(u8, name, "loadState")) return .load_state;
        if (std.mem.eql(u8, name, "dialog")) return .dialog;
        if (std.mem.eql(u8, name, "crashed")) return .crashed;
        if (std.mem.eql(u8, name, "closed")) return .closed;
        return null;
    }
};

/// 구독 이벤트 필터(관심 EventKind 비트마스크). `all`=전부. `wants`로 판정.
pub const EventFilter = struct {
    mask: u8,

    pub const all: EventFilter = .{ .mask = 0xFF };
    /// 아무 이벤트도 관심 없음(빈 필터). `with`로 종류를 누적하는 빌더 시작점(5f-0b-3b subscribe 파싱 — mask는 idempotent라
    /// 중복 이름을 자연히 dedup, 고정 버퍼/길이 제한 없이 임의 길이 events 배열을 처리).
    pub const none: EventFilter = .{ .mask = 0 };

    /// 지정한 종류만 관심.
    pub fn only(kinds: []const EventKind) EventFilter {
        var m: u8 = 0;
        for (kinds) |k| m |= bit(k);
        return .{ .mask = m };
    }

    /// 이 필터에 한 종류를 더한 새 필터(누적 빌더). 이미 있으면 무변(bitmask idempotent = 중복 dedup).
    pub fn with(self: EventFilter, k: EventKind) EventFilter {
        return .{ .mask = self.mask | bit(k) };
    }

    pub fn wants(self: EventFilter, k: EventKind) bool {
        return (self.mask & bit(k)) != 0;
    }

    fn bit(k: EventKind) u8 {
        return @as(u8, 1) << @intCast(@intFromEnum(k));
    }
};

/// opaque 구독자 식별자(L4 connection↔OutboundQueue 매핑의 키). L2는 값으로만 다룬다.
pub const SubscriberId = u64;

/// SubscriberId 단조 발급기(1부터·비재사용 — surface/capture id allocator 선례).
pub const SubscriberIdAllocator = struct {
    next_id: u64 = 1,

    pub fn next(self: *SubscriberIdAllocator) SubscriberId {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }
};

/// 한 구독(§9.5.2 `(connection→subscriber_id, surface_id, filter)`). capability는 L4가 발급 시점에 검사하므로 여긴 없다.
pub const Subscription = struct {
    subscriber_id: SubscriberId,
    surface_id: u64,
    filter: EventFilter,
};

/// 구독 레지스트리(§9.5.2). subscribe/매칭/수명 정리만 — **자체는 thread-safe가 아니다**(락 없는 순수 자료구조). 5f-0b-3a-2
/// 부터 메인(pushEvent/subscribe)과 **연결 스레드**(종료 시 self-purge)가 둘 다 호출하므로, L4 `SubscriberRegistry`가 이 broker를
/// **leaf-mutex로 감싸 호출을 직렬화**한다(§9.5.6 realization). 즉 이 struct의 스레드 안전은 caller(SubscriberRegistry)가 소유 —
/// broker에 메인-전용 가정을 새로 넣거나 그 leaf-mutex를 제거하면 pushEvent∥purgeOutbound 데이터 레이스가 재발한다. 실 전달은 L4.
pub const EventBroker = struct {
    subs: std.ArrayList(Subscription) = .empty,

    pub fn deinit(self: *EventBroker, gpa: std.mem.Allocator) void {
        self.subs.deinit(gpa);
    }

    /// 구독 등록. 같은 `(subscriber, surface)` 재구독은 필터를 **갱신**(중복 엔트리 안 만듦).
    pub fn subscribe(self: *EventBroker, gpa: std.mem.Allocator, subscriber_id: SubscriberId, surface_id: u64, filter: EventFilter) std.mem.Allocator.Error!void {
        for (self.subs.items) |*s| {
            if (s.subscriber_id == subscriber_id and s.surface_id == surface_id) {
                s.filter = filter;
                return;
            }
        }
        try self.subs.append(gpa, .{ .subscriber_id = subscriber_id, .surface_id = surface_id, .filter = filter });
    }

    /// 특정 `(subscriber, surface)` 구독 해제. 매치 있으면 true.
    pub fn unsubscribe(self: *EventBroker, subscriber_id: SubscriberId, surface_id: u64) bool {
        for (self.subs.items, 0..) |s, i| {
            if (s.subscriber_id == subscriber_id and s.surface_id == surface_id) {
                _ = self.subs.swapRemove(i);
                return true;
            }
        }
        return false;
    }

    /// 연결 drop(§9.5.6): 그 subscriber의 **모든** 구독 제거. 제거 개수 반환.
    pub fn removeSubscriber(self: *EventBroker, subscriber_id: SubscriberId) usize {
        return self.removeWhere(.subscriber, subscriber_id);
    }

    /// surface close(§9.5.2 수명): 그 surface의 **모든** 구독 제거. 제거 개수 반환. (L4가 이 전에 `closed`를
    /// 브로드캐스트로 보낸 뒤 정리한다 — `matching(surface, .closed, ...)`로 대상 조회 후 remove.)
    pub fn removeSurface(self: *EventBroker, surface_id: u64) usize {
        return self.removeWhere(.surface, surface_id);
    }

    const RemoveBy = enum { subscriber, surface };
    fn removeWhere(self: *EventBroker, by: RemoveBy, id: u64) usize {
        var removed: usize = 0;
        var i = self.subs.items.len;
        while (i > 0) {
            i -= 1;
            const s = self.subs.items[i];
            const hit = switch (by) {
                .subscriber => s.subscriber_id == id,
                .surface => s.surface_id == id,
            };
            if (hit) {
                _ = self.subs.swapRemove(i);
                removed += 1;
            }
        }
        return removed;
    }

    /// `(surface_id, kind)`에 관심 있는 subscriber_id들을 `out`에 채우고 개수 반환(§9.5.2 매칭). `out`이 작으면 채운
    /// 만큼만(초과 드롭 — 방어적; L4는 `len()` 기준 충분 크기를 준다). 각 subscriber는 `(subscriber,surface)`당 구독이
    /// 하나라 중복 없이 최대 1회 등장.
    pub fn matching(self: *const EventBroker, surface_id: u64, kind: EventKind, out: []SubscriberId) usize {
        var n: usize = 0;
        for (self.subs.items) |s| {
            if (s.surface_id == surface_id and s.filter.wants(kind)) {
                if (n < out.len) {
                    out[n] = s.subscriber_id;
                    n += 1;
                }
            }
        }
        return n;
    }

    /// surface의 **모든** 구독자를 필터 **무관**하게 `out`에 채운다(5f-3d `browser.closed` — 구독 종료 마커라 filter로
    /// opt-out 불가; `matching`과 달리 `filter.wants` 검사 안 함). 각 subscriber는 `(subscriber,surface)`당 1회라 중복 없음.
    /// `out` 작으면 채운 만큼만(방어). 반환=개수.
    pub fn matchingSurfaceAny(self: *const EventBroker, surface_id: u64, out: []SubscriberId) usize {
        var n: usize = 0;
        for (self.subs.items) |s| {
            if (s.surface_id == surface_id) {
                if (n < out.len) {
                    out[n] = s.subscriber_id;
                    n += 1;
                }
            }
        }
        return n;
    }

    /// 현재 구독 수(테스트/버퍼 크기 산정용).
    pub fn len(self: *const EventBroker) usize {
        return self.subs.items.len;
    }
};

// ── 이벤트 payload + 직렬화(§9.5.2 notification) ────────────────────────────────────────────────────────────
/// JS dialog 종류(`WKUIDelegate`). wire 문자열은 `browser.dialog` params의 `kind`.
pub const DialogKind = enum {
    alert,
    confirm,
    prompt,

    pub fn wire(self: DialogKind) []const u8 {
        return switch (self) {
            .alert => "alert",
            .confirm => "confirm",
            .prompt => "prompt",
        };
    }
};

/// 로드 상태(`browser.loadState` params의 `state`).
pub const LoadState = enum {
    loading,
    idle,

    pub fn wire(self: LoadState) []const u8 {
        return switch (self) {
            .loading => "loading",
            .idle => "idle",
        };
    }
};

/// kind-분기 이벤트 payload(surface_id는 직렬화 시 별도 주입). navigated=url·load_state=상태·dialog=종류+메시지·
/// crashed/closed=추가 필드 없음.
pub const Event = union(EventKind) {
    navigated: []const u8,
    load_state: LoadState,
    dialog: Dialog,
    crashed: void,
    closed: void,

    pub const Dialog = struct { kind: DialogKind, message: []const u8 };
};

/// 이벤트를 notification `{"jsonrpc":"2.0","method":"browser.<kind>","params":{"surface_id":<id>, ...}}` 바이트로
/// 직렬화한다(§9.5.2, gpa 소유). OOM만 error. 슬라이스(url/message)는 caller 소유 — 여기서 복사·escape는 std.json이.
pub fn serializeEvent(gpa: std.mem.Allocator, surface_id: u64, event: Event) std.mem.Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    (writeEvent(&s, surface_id, event)) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn writeEvent(s: *std.json.Stringify, surface_id: u64, event: Event) !void {
    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write(cp.jsonrpc_version);
    try s.objectField("method");
    try s.write(std.meta.activeTag(event).method());
    try s.objectField("params");
    try s.beginObject();
    try s.objectField("surface_id");
    try s.write(surface_id);
    switch (event) {
        .navigated => |url| {
            try s.objectField("url");
            try s.write(url);
        },
        .load_state => |st| {
            try s.objectField("state");
            try s.write(st.wire());
        },
        .dialog => |d| {
            try s.objectField("kind");
            try s.write(d.kind.wire());
            try s.objectField("message");
            try s.write(d.message);
        },
        .crashed, .closed => {},
    }
    try s.endObject();
    try s.endObject();
}

// ── 테스트(헤드리스, 순수) ──────────────────────────────────────────────────────────────────────────────────
const testing = std.testing;

test "SubscriberIdAllocator: 단조 증가·비재사용(1부터)" {
    var alloc: SubscriberIdAllocator = .{};
    try testing.expectEqual(@as(u64, 1), alloc.next());
    try testing.expectEqual(@as(u64, 2), alloc.next());
    try testing.expectEqual(@as(u64, 3), alloc.next());
}

test "EventKind: method 이름·coalescible 분류" {
    try testing.expectEqualStrings("browser.navigated", EventKind.navigated.method());
    try testing.expectEqualStrings("browser.closed", EventKind.closed.method());
    // 상태 이벤트만 coalescible.
    try testing.expect(EventKind.navigated.isCoalescible());
    try testing.expect(EventKind.load_state.isCoalescible());
    try testing.expect(!EventKind.dialog.isCoalescible());
    try testing.expect(!EventKind.crashed.isCoalescible());
    try testing.expect(!EventKind.closed.isCoalescible());
}

test "EventFilter: all은 전부·only는 지정만" {
    try testing.expect(EventFilter.all.wants(.navigated));
    try testing.expect(EventFilter.all.wants(.crashed));
    const f = EventFilter.only(&.{ .navigated, .dialog });
    try testing.expect(f.wants(.navigated));
    try testing.expect(f.wants(.dialog));
    try testing.expect(!f.wants(.load_state));
    try testing.expect(!f.wants(.crashed));
}

test "EventBroker: subscribe + matching(surface·filter)" {
    var b: EventBroker = .{};
    defer b.deinit(testing.allocator);
    try b.subscribe(testing.allocator, 1, 100, EventFilter.all); // 구독자1 → surface 100 전부
    try b.subscribe(testing.allocator, 2, 100, EventFilter.only(&.{.dialog})); // 구독자2 → surface 100 dialog만
    try b.subscribe(testing.allocator, 3, 200, EventFilter.all); // 구독자3 → surface 200

    var out: [8]SubscriberId = undefined;
    // surface 100 navigated → 구독자1만(2는 dialog만, 3은 다른 surface).
    var n = b.matching(100, .navigated, &out);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(u64, 1), out[0]);
    // surface 100 dialog → 구독자1(all)+구독자2.
    n = b.matching(100, .dialog, &out);
    try testing.expectEqual(@as(usize, 2), n);
    // surface 300(구독 없음) → 0.
    try testing.expectEqual(@as(usize, 0), b.matching(300, .navigated, &out));
}

test "EventBroker: 재구독은 필터 갱신(중복 없음)" {
    var b: EventBroker = .{};
    defer b.deinit(testing.allocator);
    try b.subscribe(testing.allocator, 1, 100, EventFilter.only(&.{.navigated}));
    try b.subscribe(testing.allocator, 1, 100, EventFilter.only(&.{.dialog})); // 같은 (1,100) → 갱신
    try testing.expectEqual(@as(usize, 1), b.len()); // 중복 엔트리 없음
    var out: [4]SubscriberId = undefined;
    try testing.expectEqual(@as(usize, 0), b.matching(100, .navigated, &out)); // 옛 필터 사라짐
    try testing.expectEqual(@as(usize, 1), b.matching(100, .dialog, &out)); // 새 필터
}

test "EventBroker: unsubscribe·removeSubscriber·removeSurface 수명" {
    var b: EventBroker = .{};
    defer b.deinit(testing.allocator);
    try b.subscribe(testing.allocator, 1, 100, EventFilter.all);
    try b.subscribe(testing.allocator, 1, 200, EventFilter.all); // 구독자1 = surface 2개
    try b.subscribe(testing.allocator, 2, 100, EventFilter.all);
    try testing.expectEqual(@as(usize, 3), b.len());

    // 특정 (1,100) 하나만 해제.
    try testing.expect(b.unsubscribe(1, 100));
    try testing.expect(!b.unsubscribe(1, 100)); // 이미 없음
    try testing.expectEqual(@as(usize, 2), b.len());

    // 연결 drop: 구독자1의 남은 (1,200) 제거.
    try testing.expectEqual(@as(usize, 1), b.removeSubscriber(1));
    try testing.expectEqual(@as(usize, 1), b.len()); // (2,100)만 남음

    // surface close: surface 100의 (2,100) 제거.
    try testing.expectEqual(@as(usize, 1), b.removeSurface(100));
    try testing.expectEqual(@as(usize, 0), b.len());
}

test "serializeEvent: navigated·dialog·load_state·crashed 각 notification 형태" {
    // navigated: url 포함.
    const nav = try serializeEvent(testing.allocator, 42, .{ .navigated = "https://a/" });
    defer testing.allocator.free(nav);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"method\":\"browser.navigated\",\"params\":{\"surface_id\":42,\"url\":\"https://a/\"}}", nav);

    // dialog: kind + message.
    const dlg = try serializeEvent(testing.allocator, 7, .{ .dialog = .{ .kind = .confirm, .message = "ok?" } });
    defer testing.allocator.free(dlg);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"method\":\"browser.dialog\",\"params\":{\"surface_id\":7,\"kind\":\"confirm\",\"message\":\"ok?\"}}", dlg);

    // load_state: state.
    const ls = try serializeEvent(testing.allocator, 1, .{ .load_state = .idle });
    defer testing.allocator.free(ls);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"method\":\"browser.loadState\",\"params\":{\"surface_id\":1,\"state\":\"idle\"}}", ls);

    // crashed: 추가 params 없음(surface_id만).
    const cr = try serializeEvent(testing.allocator, 9, .crashed);
    defer testing.allocator.free(cr);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"method\":\"browser.crashed\",\"params\":{\"surface_id\":9}}", cr);
}

test "serializeEvent: url의 특수문자는 std.json이 escape" {
    const nav = try serializeEvent(testing.allocator, 1, .{ .navigated = "data:text/html,<h1>\"x\"</h1>" });
    defer testing.allocator.free(nav);
    // `"` → `\"`, `<`/`>`는 그대로(JSON은 escape 안 함) — parse 왕복으로 무결성만 확인.
    var pm = try cp.parseMessage(testing.allocator, nav);
    defer pm.deinit();
    try testing.expect(pm.message == .notification);
    try testing.expectEqualStrings("browser.navigated", pm.message.notification.method);
}
