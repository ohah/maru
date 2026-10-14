//! 브라우저 하나의 콘솔 줄 조절(W9c① — CEF `on_console_message`, docs/plans/web-osr-backend.md W9c). CEF 를 모른다 — 시각·글은
//! 호출자가 준다(그래서 CEF SDK 없이 기본 test 에서 시험이 돈다).
//!
//! 왜 조절하나: 페이지는 콘솔에 제한 없이 쓴다(실측: 3 초에 1 M 줄). 처리기는 sidecar 의 UI 스레드 하나에서 돌고 maru 로 가는 쓰기는
//! 막히는 쓰기라(`events.Writer` — 관이 차면 maru 가 읽을 때까지 UI 스레드가 선다, 실측 3.6 초), 줄마다 글로 바꿔 보내면 다른 탭의
//! DevTools 까지 0.7–2.2 초 멈췄다. 그래서 **글로 바꾸기 전에** 탭마다 두 갈래(오류·경고 / 그 밖)의 줄 수 양동이와 전체 양동이를 보고,
//! 바꾼 뒤에는 실제 바이트를 빚으로 단다(바이트 양동이 — 큰 줄 하나가 그 갈래를 잠시 막는다). 넘친 줄은 버리고 수만 세어 다음 줄
//! (또는 `flush_delay_ms` 뒤 버린 수만 실은 frame)에 싣는다.
//!
//! 앞 문서의 줄(`docs_back`): 다른 사이트로 옮길 때 앞 문서의 unload 줄은 새 문서의 시작 **뒤에** 온다(실측 5/5, 늦게는 +492 ms).
//! 줄의 `source`(부른 스크립트 주소)의 출처가 방금 떠난 출처들(`Recent` — 떠난 주 프레임과 그 문서의 하위 프레임, 1 초) 중 하나이고 새
//! 주 프레임 출처가 아니면 그 출처를 떠난 지 몇 문서인지 단다 — maru 는 그 수로 줄이 **어느 문서에서 왔는지** 안다(2 회차: 「앞 문서」
//! 표시 하나로는 A → B → C 에서 C 에 온 A 의 줄을 B 의 것과 가르지 못해 B 에서 묶인 쪽에게 보였다). 그 줄은 새 문서의 양동이를 쓰지
//! 않는다(새 문서의 줄을 밀어내지 않게) — 대신 탭마다 따로 둔 작은 앞 문서 양동이와 전체 양동이를 지난다(관이 막히는 길을 열지 않게,
//! 3 회차: 두 출처를 오가는 페이지가 제 줄을 앞 문서의 줄로 만들어 탭의 상한을 넘고 전체 양동이로 다른 탭의 오류를 굶겼다). 전체 바이트는
//! 가장 낮은 차례로 — 넉넉할 때만 쓴다(4 회차 B). 거기서 버린 수는 새 문서의 수와 따로 세고 가장 앞 문서의 `docs_back` 과 함께 보낸다 —
//! maru 는 그 문서의 표지로 두어 처음 읽는 쪽에게는 보이지 않는다(4 회차 A: 전에는 세지 않아 묶인 쪽이 빠진 줄을 몰랐다).

const std = @import("std");
const protocol = @import("web_sidecar_protocol");

const ConsoleLevel = protocol.message.ConsoleLevel;
const max_text = protocol.wire.max_console_text_bytes;

/// 버린 수만 실은 frame 을 보내기까지 — 쏟아짐이 끝난 뒤에도 마지막 버린 수가 남지 않게(title flush 와 같은 task 하나).
pub const flush_delay_ms: u64 = 250;
/// 줄 글로 바꾸는 UTF-16 앞부분 상한 — 1e8 글자 줄을 통째로 바꾸면 UI 스레드에서 83 ms 였다(실측). 8192 바이트 상한을 넘기에 넉넉하다.
pub const max_message_units: usize = max_text;
/// `source` 에서 바꾸는 앞부분 — 출처와 「Uncaught」 꼬리에만 쓴다.
pub const max_source_units: usize = 2048;
/// 「Uncaught」 꼬리에 싣는 `source` 상한(바이트).
pub const max_suffix_source_bytes: usize = 256;
/// 앞 문서 판정의 창 — 떠난 뒤 이만큼. 실측한 앞 문서의 늦은 줄은 +492 ms 까지였고(Chromium 이 unload 를 끊는다) 두 배쯤 둔다.
pub const recent_window_ms: u64 = 1000;
/// 보내기가 막혔으면(관이 찼다) 창을 이만큼 늘린다 — 막힌 동안 줄이 쌓여 늦게 온다.
pub const blocked_extend_ms: u64 = 500;
/// 「막혔다」 의 기준 — 보내기가 이보다 오래 걸렸다.
pub const blocked_send_ms: u64 = 20;

pub const Class = enum(u1) {
    /// error·warn.
    important,
    other,
};

/// CEF 심각도(`cef_log_severity_t` — DEFAULT 0, VERBOSE·DEBUG 1, INFO 2, WARNING 3, ERROR 4, FATAL 5) → wire 수준. 실측: log·info 는
/// INFO, debug·count·timeEnd 는 VERBOSE, warn 은 WARNING, error·assert·잡히지 않은 예외는 ERROR.
pub fn levelOf(severity: c_int) ConsoleLevel {
    return switch (severity) {
        1 => .debug,
        3 => .warn,
        4, 5 => .@"error",
        else => .log,
    };
}

pub fn classOf(level: ConsoleLevel) Class {
    return switch (level) {
        .@"error", .warn => .important,
        .log, .info, .debug => .other,
    };
}

/// 토큰 양동이 — 잔고는 단위 × 1000(정수), 빚(음수)을 허용한다.
const Bucket = struct {
    /// 초당 채우는 단위.
    rate: i64,
    burst: i64,
    balance: i64,
    at_ms: u64 = 0,

    fn init(rate: i64, burst: i64) Bucket {
        return .{ .rate = rate, .burst = burst, .balance = burst * 1000 };
    }

    fn refill(self: *Bucket, now: u64) void {
        if (now <= self.at_ms) return;
        const dt: i64 = @intCast(@min(now - self.at_ms, 60_000));
        self.at_ms = now;
        self.balance = @min(self.burst * 1000, self.balance + dt * self.rate);
    }

    /// 줄 하나 — 한 단위가 있어야 한다.
    fn hasOne(self: *const Bucket) bool {
        return self.balance >= 1000;
    }

    /// 바이트 — 잔고가 양수면 지나고 실제 바이트를 빚으로 단다.
    fn positive(self: *const Bucket) bool {
        return self.balance > 0;
    }

    fn take(self: *Bucket, units: usize) void {
        const u: i64 = @intCast(@min(units, 1 << 40));
        self.balance -= u * 1000;
    }
};

/// 탭마다의 양동이 — 오류·경고 20/s(버스트 100)·16 KiB/s(버스트 24 KiB), 그 밖 50/s(200)·32 KiB/s(24 KiB). 바이트 수치는 계획 공격
/// 2 회차 모의(실제 React/Vite 개발 페이지의 시작 줄 222 개 중 178 개를 지키고, 1.2 KB 로그가 흐르는 중의 3 KB 오류도 지킨다).
fn tabCount() [2]Bucket {
    return .{ Bucket.init(20, 100), Bucket.init(50, 200) };
}
fn tabBytes() [2]Bucket {
    return .{ Bucket.init(16 * 1024, 24 * 1024), Bucket.init(32 * 1024, 24 * 1024) };
}

/// 탭마다의 앞 문서 양동이(두 갈래 함께) — 줄 5/s(버스트 80)·2 KiB/s(버스트 8 KiB). 떠나며 남기는 줄은 실측으로 이동마다 몇 줄이다(unload·
/// pagehide 3–7 줄, 400 ms 바쁜 꼬리 5 줄 — 계획 공격 2 회차·적대 리뷰 1·2 회차) — 버스트가 그것을 넉넉히 지키고, 채우기는 느려 이동을
/// 거듭해도 탭 하나가 내는 양은 앞 문서 몫을 더해도 전체 양동이 아래다(줄 20 + 50 + 5 /s ≪ 1000, 16 + 32 + 2 KiB/s < 64 KiB) — 3 회차.
/// 4 회차 B: 바이트는 8 KiB/s·버스트 32 KiB 였는데 버스트의 합(24 + 24 + 32 KiB)이 전체 버스트(48 KiB)를 넘고 잔고가 양수면 8 KiB 줄이
/// 지나(빚) 8 KiB 줄로 세 갈래를 채우는 탭이 전체를 다 썼다 — 그래서 줄였고, 전체 바이트에도 남길 몫(`old_global_reserve_bytes`)을 둔다.
fn oldCount() Bucket {
    return Bucket.init(5, 80);
}
fn oldBytes() Bucket {
    return Bucket.init(2 * 1024, 8 * 1024);
}

/// 쌓인 앞 문서의 버린 수를 다른 문서의 버림을 세기 전에 먼저 보내는 frame(`splitOld` — 5 회차 A)의 탭 몫 — 초당 5(버스트 10). 빠른 사슬
/// A → B → C 의 늦은 줄은 문서 둘셋에서 오므로 버스트가 넉넉하고, 떠난 출처 둘의 스크립트를 번갈아 부르는 페이지가 버린 줄마다 frame 을
/// 만들어 관을 막지는 못한다(몫이 없으면 합친다 — 가장 앞 문서로, 더 숨기는 쪽).
fn oldSplit() Bucket {
    return Bucket.init(5, 10);
}

/// 앞 문서의 줄은 전체 바이트 잔고가 그 줄을 단 뒤에도 이만큼 **남을** 때만 지난다(4 회차 B) — 줄의 바이트는 바꾼 뒤에야 알아 그 상한
/// (`textBound`)으로 본다. 앞 문서의 줄은 가장 낮은 차례다: 다른 탭의 새 문서 줄(오류)이 쓸 몫을 남긴다.
pub const old_global_reserve_bytes: usize = 24 * 1024;

/// UTF-16 `units` 단위의 줄을 바꾼 글의 바이트 상한 — 한 단위는 UTF-8 로 3 바이트까지, 「Uncaught」 꼬리까지 더하고 `max_text` 에서 멈춘다.
pub fn textBound(units: usize) usize {
    return @min(max_text, units *| 3 +| (max_suffix_source_bytes + 32));
}

/// 모든 탭이 함께 쓰는 양동이 — 1000 줄/s, 64 KiB/s(버스트 48 KiB — maru 가 한 tick 에 관 하나(64 KiB)만 비워도 막히지 않게).
pub const Global = struct {
    count: Bucket = Bucket.init(1000, 1000),
    bytes: Bucket = Bucket.init(64 * 1024, 48 * 1024),
};

pub const Gate = struct {
    count: [2]Bucket = tabCount(),
    bytes: [2]Bucket = tabBytes(),
    /// 앞 문서의 줄(`old_document`)만 쓰는 양동이 — 새 문서의 양동이와 따로다(새 문서의 줄을 밀어내지 않게).
    old_count: Bucket = oldCount(),
    old_bytes: Bucket = oldBytes(),
    /// 앞 문서의 버린 수를 문서마다 나눠 보내는 frame 의 몫(`splitOld`).
    old_split: Bucket = oldSplit(),
    /// 아직 알리지 않은 버린 수(오류·경고, 그 밖) — 지금 문서의 줄.
    dropped: [2]u32 = .{ 0, 0 },
    /// 아직 알리지 않은 앞 문서의 줄을 버린 수(두 갈래 함께)와 그 가운데 가장 큰 `docs_back`(4 회차 A). 새 문서의 시작 앞에 보내므로 그
    /// `docs_back` 은 보낼 때의 문서에서 센 것이다.
    dropped_old: u32 = 0,
    dropped_old_back: u8 = 0,
    recent: Recent = .{},

    /// 글로 바꾸기 전에 — 지나면 줄 수를 단다(바이트는 바꾼 뒤 `charge`). 못 지나면 버린 수를 센다. `docs_back` 이 0 이 아니면 앞 문서의 줄,
    /// `bound` 는 바꿀 글의 바이트 상한(`textBound` — 앞 문서의 줄의 남길 몫에만 쓴다).
    pub fn admit(self: *Gate, global: *Global, class: Class, docs_back: u8, bound: usize, now: u64) bool {
        const i = @intFromEnum(class);
        const old_document = docs_back != 0;
        global.count.refill(now);
        global.bytes.refill(now);
        self.count[i].refill(now);
        self.bytes[i].refill(now);
        self.old_count.refill(now);
        self.old_bytes.refill(now);
        // 앞 문서의 줄은 새 문서의 양동이를 보지 않는다 — 제 양동이(앞 문서)와 전체 양동이, 그것도 남길 몫을 남길 때만(4 회차 B).
        const tab_ok = if (old_document)
            self.old_count.hasOne() and self.old_bytes.positive() and
                global.bytes.balance >= @as(i64, @intCast(old_global_reserve_bytes + @min(bound, max_text))) * 1000
        else
            self.count[i].hasOne() and self.bytes[i].positive();
        if (!tab_ok or !global.count.hasOne() or !global.bytes.positive()) {
            // 앞 문서의 줄은 따로 센다 — 새 문서의 표지에 실리면 처음 읽는 쪽에게 앞 사이트의 양이 드러난다(2 회차).
            if (old_document) {
                self.dropped_old +|= 1;
                self.dropped_old_back = @max(self.dropped_old_back, docs_back);
            } else self.dropped[i] +|= 1;
            return false;
        }
        global.count.take(1);
        if (old_document) self.old_count.take(1) else self.count[i].take(1);
        return true;
    }

    /// 앞 문서의 줄(`docs_back`)을 보기 **전에** — 쌓인 앞 문서의 버린 수가 다른 문서의 것이면 참: 호출자가 그것을 먼저 보낸다(`sendDrops`).
    /// wire 는 (수, 가장 앞 `docs_back`) 한 쌍이라 합치면 새 쪽 문서에서 버린 수가 더 앞 문서의 표지로 가, 그 새 문서에 묶인 쪽이 빠진 줄을
    /// 몰랐다(5 회차 A: A → B → C 에서 A 의 줄 하나와 B 의 줄 넷을 버리면 다섯이 A 의 표지로 — B 에 묶인 쪽에게 표지가 없었다). 보내는 frame
    /// 도 관을 쓰므로 탭 몫(`old_split`)과 전체 줄 수 몫을 쓴다. 몫이 없으면 거짓 — `admit` 이 전처럼 가장 앞 문서로 합친다(더 숨기는 쪽).
    pub fn splitOld(self: *Gate, global: *Global, docs_back: u8, now: u64) bool {
        if (docs_back == 0 or self.dropped_old == 0 or docs_back == self.dropped_old_back) return false;
        global.count.refill(now);
        self.old_split.refill(now);
        if (!self.old_split.hasOne() or !global.count.hasOne()) return false;
        self.old_split.take(1);
        global.count.take(1);
        return true;
    }

    /// 바꾼 글의 실제 바이트를 빚으로 단다.
    pub fn charge(self: *Gate, global: *Global, class: Class, old_document: bool, bytes: usize) void {
        global.bytes.take(bytes);
        if (old_document) self.old_bytes.take(bytes) else self.bytes[@intFromEnum(class)].take(bytes);
    }

    pub fn hasDrops(self: *const Gate) bool {
        return self.dropped[0] != 0 or self.dropped[1] != 0 or self.dropped_old != 0;
    }

    /// 보냈다 — 버린 수를 비운다.
    pub fn clearDrops(self: *Gate) void {
        self.dropped = .{ 0, 0 };
        self.dropped_old = 0;
        self.dropped_old_back = 0;
    }
};

/// 출처 하나(`scheme://host[:port]`).
pub const Origin = struct {
    buf: [protocol.fields.max_origin_bytes]u8 = undefined,
    len: u8 = 0,

    pub fn slice(self: *const Origin) []const u8 {
        return self.buf[0..self.len];
    }
};

/// 줄 `source`·프레임 주소의 출처를 `out` 에 — http(s) 의 스킴과 호스트(포트), `blob:` 은 안의 주소. 그 밖(빈 주소·`data:`·
/// `about:srcdoc`·`webpack://` 같은 개발 도구 주소)은 출처가 없다 — 그런 줄은 앞 문서로 표시하지 않는다.
pub fn originOf(url: []const u8, out: *Origin) bool {
    const inner = if (std.mem.startsWith(u8, url, "blob:")) url["blob:".len..] else url;
    const origin = protocol.new_tab.originOf(inner) orelse return false;
    if (origin.len > out.buf.len) return false;
    @memcpy(out.buf[0..origin.len], origin);
    out.len = @intCast(origin.len);
    return true;
}

/// 방금 떠난 출처들과 문서 번호(브라우저 하나).
pub const Recent = struct {
    /// 떠난 주 프레임 출처의 자리와 하위 프레임 출처의 자리는 따로다 — 한 줄에 두면 떠난 문서의 다른 출처 iframe 셋이 그 앞 주
    /// 프레임 출처를 밀어내, A → B(iframe 셋) → C 에서 A 의 늦은 줄이 지금 문서의 줄이 되었다(2 회차).
    pub const main_slots = 3;
    pub const subframe_slots = 3;
    pub const max_subframes = 3;

    /// `left_doc` — 그 출처를 떠난 문서의 번호.
    const Slot = struct { origin: Origin = .{}, until_ms: u64 = 0, left_doc: u32 = 0 };

    /// 지금 문서의 주 프레임 출처(없으면 len 0).
    current: Origin = .{},
    /// 지금 문서의 하위 프레임 출처 — 떠날 때 `subframe_slot` 로 간다.
    subframes: [max_subframes]Origin = @splat(.{}),
    subframe_len: usize = 0,
    main_slot: [main_slots]Slot = @splat(.{}),
    subframe_slot: [subframe_slots]Slot = @splat(.{}),
    /// 지금 문서의 번호 — 주 프레임의 새 문서(`mainStarted`·`errorPage`)마다 올린다. maru 의 링도 같은 경계(`page_started`·
    /// `error_page`)로 세므로 차(`docsBack`)만 wire 로 간다 — 엔진이 다시 떠 0 부터 세어도 맞다.
    doc: u32 = 0,

    /// 주 프레임에 새 문서가 시작됐다(`on_load_start`) — 앞 문서의 출처들을 기억하고 새 출처로.
    pub fn mainStarted(self: *Recent, url: []const u8, now: u64) void {
        self.leave(now);
        if (!originOf(url, &self.current)) self.current.len = 0;
    }

    /// 실패한 이동이 오류 페이지로 문서를 바꿨다 — 떠난 것은 같고 새 출처는 없다.
    pub fn errorPage(self: *Recent, now: u64) void {
        self.leave(now);
        self.current.len = 0;
    }

    /// 하위 프레임에 문서가 시작됐다 — 지금 문서가 떠날 때 함께 기억한다(`max_subframes` 까지 — 넘치면 앞의 것들로).
    pub fn subframeStarted(self: *Recent, url: []const u8) void {
        var o: Origin = .{};
        if (!originOf(url, &o)) return;
        if (std.mem.eql(u8, o.slice(), self.current.slice())) return;
        for (self.subframes[0..self.subframe_len]) |*f| if (std.mem.eql(u8, f.slice(), o.slice())) return;
        if (self.subframe_len == max_subframes) return;
        self.subframes[self.subframe_len] = o;
        self.subframe_len += 1;
    }

    /// 창 안에 기억한 출처가 있는가 — 없으면 줄의 `source` 를 바꾸지도 않는다(대부분의 줄).
    pub fn active(self: *const Recent, now: u64) bool {
        for (self.groups()) |slots| for (slots) |slot| if (slot.origin.len != 0 and slot.until_ms >= now) return true;
        return false;
    }

    /// 출처 `origin` 의 줄이 몇 문서 앞의 것인가(0 — 지금 문서의 줄, 앞 문서의 줄이면 1 이상, 255 에서 멈춘다). 창 안의 여러 자리에
    /// 있으면 가장 앞 문서로 — 어느 문서의 줄인지 모를 때는 앞의 것으로 보아 묶인 쪽에게도 숨긴다.
    pub fn docsBack(self: *const Recent, origin: []const u8, now: u64) u8 {
        if (origin.len == 0 or std.mem.eql(u8, origin, self.current.slice())) return 0;
        var back: u32 = 0;
        for (self.groups()) |slots| for (slots) |slot| {
            if (slot.origin.len != 0 and slot.until_ms >= now and std.mem.eql(u8, slot.origin.slice(), origin))
                back = @max(back, self.doc -% slot.left_doc);
        };
        return @intCast(@min(back, std.math.maxInt(u8)));
    }

    fn groups(self: *const Recent) [2][]const Slot {
        return .{ &self.main_slot, &self.subframe_slot };
    }

    /// 보내기가 막혔다 — 창 안의 출처를 `blocked_extend_ms` 더 기억한다.
    pub fn sendBlocked(self: *Recent, now: u64) void {
        for ([_][]Slot{ &self.main_slot, &self.subframe_slot }) |slots| for (slots) |*slot| {
            if (slot.origin.len != 0 and slot.until_ms >= now) slot.until_ms = @max(slot.until_ms, now + blocked_extend_ms);
        };
    }

    /// 지금 문서를 떠난다 — 하위 프레임 출처는 제 자리에, 주 프레임 출처는 제 자리에 기억하고 문서 번호를 올린다.
    fn leave(self: *Recent, now: u64) void {
        const until = now + recent_window_ms;
        for (self.subframes[0..self.subframe_len]) |*f| self.remember(&self.subframe_slot, f, until, now);
        self.subframe_len = 0;
        if (self.current.len != 0) self.remember(&self.main_slot, &self.current, until, now);
        self.doc +%= 1;
    }

    fn remember(self: *const Recent, slots: []Slot, origin: *const Origin, until: u64, now: u64) void {
        const slot = &slots[slotFor(slots, origin, now)];
        if (slot.origin.len != 0 and slot.until_ms >= now and std.mem.eql(u8, slot.origin.slice(), origin.slice())) {
            // 창 안의 같은 출처 — 늦은 줄이 어느 문서의 것인지 모른다. 앞 문서의 번호를 지킨다(`docsBack`).
            slot.until_ms = @max(slot.until_ms, until);
        } else slot.* = .{ .origin = origin.*, .until_ms = until, .left_doc = self.doc };
    }

    /// 같은 출처의 자리, 빈 자리, 창이 지난 자리, 그도 없으면 가장 먼저 끝나는 자리(같은 갈래 안에서만 — 다른 갈래를 밀어내지 않는다).
    fn slotFor(slots: []const Slot, origin: *const Origin, now: u64) usize {
        for (slots, 0..) |slot, i| if (slot.origin.len != 0 and std.mem.eql(u8, slot.origin.slice(), origin.slice())) return i;
        for (slots, 0..) |slot, i| if (slot.origin.len == 0 or slot.until_ms < now) return i;
        var best: usize = 0;
        for (slots, 0..) |slot, i| {
            if (slot.until_ms < slots[best].until_ms) best = i;
        }
        return best;
    }
};

/// UTF-16 앞부분의 길이 — `max` 단위까지, 짝을 가르지 않게 마지막이 높은 대리(0xD800–0xDBFF)면 하나 물린다.
pub fn prefixUnits(units: []const u16, max: usize) usize {
    if (units.len <= max) return units.len;
    const last = units[max - 1];
    return if (last >= 0xD800 and last <= 0xDBFF) max - 1 else max;
}

/// 「Uncaught」 꼬리(부른 곳)를 달 줄인가 — 오류 수준이고 「Uncaught」 로 시작할 때만(적대 리뷰 1 회차: `console.log('Uncaught x')` 에도
/// 붙었다). CEF 처리기에서 꺼내 둔 것은 시험하려고다(5 회차 변이 — 처리기 안에서는 수준 검사를 지워도 아무 시험도 몰랐다).
pub fn uncaughtError(level: ConsoleLevel, text: []const u8) bool {
    return level == .@"error" and std.mem.startsWith(u8, text, "Uncaught");
}

/// 보낼 글을 만든다. `raw` 는 앞부분을 UTF-8 로 바꾼 것(제자리로 다듬는다 — 제어 문자는 공백, CRLF·CR 은 LF), `truncated` 는 앞부분만
/// 바꿨는가. 상한(8192 바이트)을 넘거나 앞부분만이면 글자 경계에서 자르고 「…」 을 단다 — 상한 **안**에서. 「Uncaught」 로 시작하고
/// `source` 가 있으면 ` (source:line)` 을 붙인다(그것도 상한 안, source 는 256 바이트까지).
pub fn finishText(raw: []u8, truncated: bool, source: []const u8, line: i64, out: *[max_text]u8) []const u8 {
    protocol.text.replaceControlKeepLines(raw);
    const text = raw[0..protocol.text.normalizeNewlines(raw)];
    // 꼬리 — 잡히지 않은 예외에만, 부른 곳을 알 때만.
    var suffix_buf: [max_suffix_source_bytes + 32]u8 = undefined;
    var suffix: []const u8 = "";
    if (std.mem.startsWith(u8, text, "Uncaught") and source.len != 0) {
        var src_buf: [max_suffix_source_bytes]u8 = undefined;
        const src = protocol.text.clampUtf8(source, max_suffix_source_bytes);
        @memcpy(src_buf[0..src.len], src);
        protocol.text.replaceControl(src_buf[0..src.len]);
        suffix = std.fmt.bufPrint(&suffix_buf, " ({s}:{d})", .{ src_buf[0..src.len], line }) catch "";
    }
    const ellipsis = "…";
    const room = max_text - suffix.len;
    var body = protocol.text.clampUtf8(text, room);
    const cut = truncated or body.len < text.len;
    if (cut) body = protocol.text.clampUtf8(body, room - ellipsis.len);
    var n: usize = 0;
    for ([_][]const u8{ body, if (cut) ellipsis else "", suffix }) |part| {
        @memcpy(out[n .. n + part.len], part);
        n += part.len;
    }
    return out[0..n];
}

// ── 시험 ────────────────────────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "W9c①: CEF severities map to wire levels — VERBOSE debug, INFO log, WARNING warn, ERROR and FATAL error; error and warn are the important class" {
    try testing.expectEqual(ConsoleLevel.debug, levelOf(1));
    try testing.expectEqual(ConsoleLevel.log, levelOf(2));
    try testing.expectEqual(ConsoleLevel.warn, levelOf(3));
    try testing.expectEqual(ConsoleLevel.@"error", levelOf(4));
    try testing.expectEqual(ConsoleLevel.@"error", levelOf(5));
    try testing.expectEqual(ConsoleLevel.log, levelOf(0));
    try testing.expectEqual(ConsoleLevel.log, levelOf(99));
    try testing.expectEqual(Class.important, classOf(.@"error"));
    try testing.expectEqual(Class.important, classOf(.warn));
    for ([_]ConsoleLevel{ .log, .info, .debug }) |l| try testing.expectEqual(Class.other, classOf(l));
}

test "W9c①: a log flood keeps the burst then the rate, errors keep their own budget meanwhile, and drops are counted per class" {
    var g: Gate = .{};
    var global: Global = .{};
    var passed: usize = 0;
    const t0: u64 = 1_000_000;
    for (0..1000) |_| {
        if (g.admit(&global, .other, 0, max_text, t0)) passed += 1;
    }
    try testing.expectEqual(@as(usize, 200), passed); // 버스트
    try testing.expectEqual(@as(u32, 800), g.dropped[1]);
    try testing.expectEqual(@as(u32, 0), g.dropped[0]);
    // 같은 순간에도 오류는 제 양동이로 지난다.
    try testing.expect(g.admit(&global, .important, 0, max_text, t0));
    // 1 초 뒤 그 갈래는 50 줄만 더.
    passed = 0;
    for (0..1000) |_| {
        if (g.admit(&global, .other, 0, max_text, t0 + 1000)) passed += 1;
    }
    try testing.expectEqual(@as(usize, 50), passed);
    // 오류·경고 갈래는 버스트 100, 그 뒤 20/s.
    passed = 0;
    for (0..1000) |_| {
        if (g.admit(&global, .important, 0, max_text, t0 + 1000)) passed += 1;
    }
    try testing.expectEqual(@as(usize, 100), passed); // 위에서 쓴 하나는 그사이 다시 찼다
    passed = 0;
    for (0..1000) |_| {
        if (g.admit(&global, .important, 0, max_text, t0 + 2000)) passed += 1;
    }
    try testing.expectEqual(@as(usize, 20), passed);
    // 버린 수는 보낸 뒤 비운다.
    try testing.expect(g.hasDrops());
    g.dropped = .{ 0, 0 };
    try testing.expect(!g.hasDrops());
}

test "W9c①: the byte budget is a debt — a big line passes while the balance is positive, then blocks its class until paid back, and a 3 KB error passes while small logs stream" {
    var g: Gate = .{};
    var global: Global = .{};
    const t0: u64 = 5_000_000;
    try testing.expect(g.admit(&global, .other, 0, max_text, t0));
    g.charge(&global, .other, false, 8192 * 4); // 32 KiB — 버스트(24 KiB)보다 크지만 잔고가 양수였다
    try testing.expect(!g.admit(&global, .other, 0, max_text, t0 + 1)); // 빚 — 그 갈래는 막힌다
    try testing.expect(g.admit(&global, .important, 0, max_text, t0 + 1)); // 다른 갈래는 아니다
    // 빚(8 KiB)을 32 KiB/s 로 갚는다 — 250 ms 쯤.
    try testing.expect(!g.admit(&global, .other, 0, max_text, t0 + 200));
    try testing.expect(g.admit(&global, .other, 0, max_text, t0 + 300));
    // 잔고가 꼭 0 이면 막힌다(양수여야 지난다).
    var z: Gate = .{};
    var zg: Global = .{};
    try testing.expect(z.admit(&zg, .important, 0, max_text, t0));
    z.charge(&zg, .important, false, 24 * 1024);
    try testing.expect(!z.admit(&zg, .important, 0, max_text, t0));
    // 1.2 KB 로그가 30/s 로 흐르는 중(계획 공격 2 회차 dev2) — 3 KB 오류는 지난다.
    var h: Gate = .{};
    var hg: Global = .{};
    var t: u64 = t0;
    var error_passed = false;
    for (0..120) |i| {
        t += 33;
        if (h.admit(&hg, .other, 0, max_text, t)) h.charge(&hg, .other, false, 1200);
        if (i == 90) {
            error_passed = h.admit(&hg, .important, 0, max_text, t);
            if (error_passed) h.charge(&hg, .important, false, 3000);
        }
    }
    try testing.expect(error_passed);
}

test "W9c①: old-document lines skip the new document's budgets for a small budget of their own, still pass the global ones, and their drops are counted apart from the new document's with the largest docs_back" {
    var g: Gate = .{};
    var global: Global = .{};
    const t0: u64 = 9_000_000;
    // 새 문서의 그 밖 갈래를 다 썼다.
    for (0..1000) |_| if (!g.admit(&global, .other, 0, max_text, t0)) break;
    // 앞 문서의 줄은 새 문서의 양동이를 보지 않는다 — 지나고, 새 문서의 잔고를 쓰지 않는다.
    try testing.expect(g.admit(&global, .other, 1, max_text, t0));
    g.charge(&global, .other, true, 100);
    try testing.expectEqual(Bucket.init(32 * 1024, 24 * 1024).balance, g.bytes[1].balance);
    // 거꾸로 앞 문서의 줄이 쏟아져도 새 문서의 오류는 제 양동이로 지난다.
    var n: Gate = .{};
    var ng: Global = .{};
    for (0..500) |_| _ = n.admit(&ng, .important, 1, max_text, t0);
    try testing.expect(n.admit(&ng, .important, 0, max_text, t0));
    // 앞 문서의 줄은 탭마다 버스트 80 줄, 그 뒤 5/s(3 회차) — 실측한 이동마다의 unload 줄(3–7)은 넉넉히 지난다(바이트를 줄인 4 회차 뒤에도 —
    // 아래 「W9c① 적대 리뷰 4 회차 B」).
    var h: Gate = .{};
    var hg: Global = .{};
    var passed: usize = 0;
    for (0..1500) |_| {
        if (h.admit(&hg, .other, 1, max_text, t0)) passed += 1;
    }
    try testing.expectEqual(@as(usize, 80), passed);
    passed = 0;
    for (0..100) |_| {
        if (h.admit(&hg, .important, 1, max_text, t0 + 1000)) passed += 1;
    }
    try testing.expectEqual(@as(usize, 5), passed); // 두 갈래가 함께 쓴다
    // 버린 앞 문서의 줄은 새 문서의 수에 넣지 않는다 — 새 문서의 표지에 실리면 앞 사이트의 양이 드러난다(2 회차). 따로 세고 가장 앞
    // 문서의 `docs_back` 을 단다(4 회차 A — maru 는 그 문서의 표지로 둔다).
    try testing.expectEqual(@as(u32, 0), h.dropped[1]);
    try testing.expectEqual(@as(u32, 0), h.dropped[0]);
    try testing.expectEqual(@as(u32, 1420 + 95), h.dropped_old);
    try testing.expectEqual(@as(u8, 1), h.dropped_old_back);
    try testing.expect(!h.admit(&hg, .other, 3, max_text, t0 + 1000));
    try testing.expect(!h.admit(&hg, .other, 2, max_text, t0 + 1000));
    try testing.expectEqual(@as(u8, 3), h.dropped_old_back); // 가장 앞 문서의 것
    try testing.expect(h.hasDrops());
    h.clearDrops();
    try testing.expect(!h.hasDrops());
    try testing.expectEqual(@as(u8, 0), h.dropped_old_back);
    // 앞 문서 바이트도 빚이다 — 버스트(8 KiB)를 넘게 지면 그 탭의 앞 문서 줄이 막힌다.
    var b: Gate = .{};
    var bg: Global = .{};
    try testing.expect(b.admit(&bg, .other, 1, max_text, t0));
    b.charge(&bg, .other, true, 40 * 1024);
    bg = .{}; // 전체는 막히지 않았다고 친다
    try testing.expect(!b.admit(&bg, .other, 1, max_text, t0 + 1));
    try testing.expect(b.admit(&bg, .other, 0, max_text, t0 + 1)); // 새 문서의 줄은 아니다
    // 전체 양동이도 지난다 — 여러 탭의 앞 문서 줄도 합해 1000 줄에서, 48 KiB 빚을 지면 다른 탭의 앞 문서 줄도 막힌다.
    var tabs: [20]Gate = @splat(.{});
    var tg: Global = .{};
    passed = 0;
    for (&tabs) |*t| for (0..80) |_| {
        if (t.admit(&tg, .other, 1, max_text, t0)) passed += 1;
    };
    try testing.expectEqual(@as(usize, 1000), passed);
    var k: Gate = .{};
    var k2: Gate = .{};
    var kg: Global = .{};
    try testing.expect(k.admit(&kg, .other, 1, max_text, t0));
    k.charge(&kg, .other, true, 64 * 1024);
    try testing.expect(!k2.admit(&kg, .other, 1, max_text, t0));
}

test "W9c①: the global buckets cap all tabs together" {
    var tabs: [8]Gate = @splat(.{});
    var global: Global = .{};
    const t0: u64 = 12_000_000;
    var passed: usize = 0;
    for (0..200) |_| for (&tabs) |*g| {
        if (g.admit(&global, .other, 0, max_text, t0)) passed += 1;
    };
    try testing.expectEqual(@as(usize, 1000), passed); // 탭마다 200 이어도 합은 1000
    // 전체 바이트도 빚이다 — 한 탭이 48 KiB 를 넘게 지면 다른 탭의 새 문서 줄도 막힌다.
    var a: Gate = .{};
    var b: Gate = .{};
    var bg: Global = .{};
    try testing.expect(a.admit(&bg, .other, 0, max_text, t0));
    a.charge(&bg, .other, false, 48 * 1024);
    try testing.expect(!b.admit(&bg, .important, 0, max_text, t0));
    try testing.expectEqual(@as(u32, 1), b.dropped[0]);
}

test "W9c①: a source's origin is the http(s) scheme and authority, blob: unwraps, and other sources have none" {
    var o: Origin = .{};
    try testing.expect(originOf("https://a.example:8443/app.js?v=1", &o));
    try testing.expectEqualStrings("https://a.example:8443", o.slice());
    try testing.expect(originOf("blob:http://127.0.0.1:5000/9f3c-uuid", &o));
    try testing.expectEqualStrings("http://127.0.0.1:5000", o.slice());
    try testing.expect(originOf("http://u:p@h.example/x", &o));
    try testing.expectEqualStrings("http://h.example", o.slice());
    for ([_][]const u8{ "", "data:text/html,x", "about:srcdoc", "webpack://app/./src/index.js", "file:///a.html", "blob:null/x" }) |url|
        try testing.expect(!originOf(url, &o));
}

test "W9c①: recent origins — the main origin left at a new document and that document's subframe origins flag lines for 1 s with how many documents back, never the new main origin" {
    var r: Recent = .{};
    const t0: u64 = 100_000;
    r.mainStarted("http://a.test/", t0);
    try testing.expect(!r.active(t0)); // 처음 문서 — 떠난 것이 없다
    r.subframeStarted("https://frame.test/x");
    r.subframeStarted("https://frame.test/y"); // 같은 출처는 한 번
    r.mainStarted("http://b.test/", t0 + 10_000);
    const t1 = t0 + 10_000;
    try testing.expect(r.active(t1));
    try testing.expectEqual(@as(u8, 1), r.docsBack("http://a.test", t1));
    try testing.expectEqual(@as(u8, 1), r.docsBack("https://frame.test", t1 + 999));
    try testing.expectEqual(@as(u8, 0), r.docsBack("http://b.test", t1)); // 새 주 프레임 출처
    try testing.expectEqual(@as(u8, 0), r.docsBack("https://cdn.test", t1));
    try testing.expectEqual(@as(u8, 1), r.docsBack("http://a.test", t1 + recent_window_ms)); // 창의 끝까지
    try testing.expect(r.active(t1 + recent_window_ms));
    try testing.expectEqual(@as(u8, 0), r.docsBack("http://a.test", t1 + recent_window_ms + 1)); // 창이 지났다
    try testing.expect(!r.active(t1 + recent_window_ms + 1));
    // 같은 출처 안의 이동 — 떠난 출처가 곧 새 출처라 표시하지 않는다.
    r.mainStarted("http://b.test/2", t1 + 5000);
    try testing.expectEqual(@as(u8, 0), r.docsBack("http://b.test", t1 + 5001));
    // 빠른 사슬 A → B → C(160 ms) — A 의 늦은 unload 도 표시하고(계획 공격 2 회차: 앞 출처 하나만 보면 샜다), 두 문서 앞이라고 단다.
    var q: Recent = .{};
    q.mainStarted("http://a.test/", t0);
    q.mainStarted("http://b.test/", t0 + 100);
    q.mainStarted("http://c.test/", t0 + 260);
    try testing.expectEqual(@as(u8, 2), q.docsBack("http://a.test", t0 + 331));
    try testing.expectEqual(@as(u8, 1), q.docsBack("http://b.test", t0 + 331));
    // 오류 페이지도 문서 하나로 센다(maru 의 링이 `error_page` 로 세는 것과 같게).
    q.errorPage(t0 + 400);
    try testing.expectEqual(@as(u8, 3), q.docsBack("http://a.test", t0 + 401));
    try testing.expectEqual(@as(u8, 1), q.docsBack("http://c.test", t0 + 401));
}

test "W9c①: subframe origins cannot evict main origins, a main origin evicts only the earliest-ending main origin, an error page leaves the old origin too, and a blocked send extends the window" {
    var r: Recent = .{};
    const t0: u64 = 200_000;
    r.mainStarted("http://a.test/", t0);
    for ([_][]const u8{ "https://f1.test/", "https://f2.test/", "https://f3.test/", "https://f4.test/" }) |u| r.subframeStarted(u);
    r.mainStarted("http://b.test/", t0 + 100);
    try testing.expectEqual(@as(u8, 1), r.docsBack("http://a.test", t0 + 101)); // 주 프레임 출처는 자리를 지킨다
    // 주 프레임과 같은 출처의 하위 프레임은 하위 프레임 자리를 쓰지 않는다 — 다른 출처 셋이 다 남는다.
    var s: Recent = .{};
    s.mainStarted("http://a.test/", t0);
    for ([_][]const u8{ "http://a.test/frame", "https://f1.test/", "https://f2.test/", "https://f3.test/" }) |u| s.subframeStarted(u);
    s.mainStarted("http://b.test/", t0 + 100);
    try testing.expectEqual(@as(u8, 1), s.docsBack("https://f3.test", t0 + 101));
    try testing.expectEqual(@as(u8, 0), r.docsBack("https://f4.test", t0 + 101)); // 넷째 하위 프레임은 기억하지 않는다(문서마다 셋)
    // 다음 문서의 하위 프레임이 많아도 앞 주 프레임 출처들(a, b)을 밀어내지 않는다.
    for ([_][]const u8{ "https://g1.test/", "https://g2.test/", "https://g3.test/" }) |u| r.subframeStarted(u);
    r.mainStarted("http://c.test/", t0 + 200);
    try testing.expectEqual(@as(u8, 1), r.docsBack("http://b.test", t0 + 201));
    try testing.expectEqual(@as(u8, 2), r.docsBack("http://a.test", t0 + 201));
    try testing.expectEqual(@as(u8, 1), r.docsBack("https://g3.test", t0 + 201));
    // 주 프레임 출처의 자리가 차면 가장 먼저 끝나는 주 프레임 출처(a)만 나간다.
    r.mainStarted("http://d.test/", t0 + 300); // c 를 떠났다 — a·b·c 로 찼다
    r.mainStarted("http://e.test/", t0 + 400); // d 가 a 를 밀어낸다
    try testing.expectEqual(@as(u8, 0), r.docsBack("http://a.test", t0 + 401));
    try testing.expectEqual(@as(u8, 3), r.docsBack("http://b.test", t0 + 401));
    try testing.expectEqual(@as(u8, 1), r.docsBack("http://d.test", t0 + 401));
    // 하위 프레임만 쌓여도(빈 문서를 거쳐) 주 프레임 출처는 남는다.
    var e: Recent = .{};
    e.mainStarted("http://a.test/", t0);
    e.mainStarted("about:blank", t0 + 100); // a 를 떠났다(until t0+1100) — 새 출처는 없다
    for ([_][]const u8{ "https://x.test/", "https://y.test/", "https://z.test/" }) |u| e.subframeStarted(u);
    e.mainStarted("about:blank", t0 + 150); // 하위 프레임 셋만 떠난다(until t0+1150) — 하위 프레임 자리가 찼다
    e.subframeStarted("https://p.test/");
    e.errorPage(t0 + 200); // p 하나 — 하위 프레임 자리에서 x 가 나간다
    try testing.expectEqual(@as(u8, 3), e.docsBack("http://a.test", t0 + 201));
    try testing.expectEqual(@as(u8, 1), e.docsBack("https://p.test", t0 + 201));
    try testing.expectEqual(@as(u8, 0), e.docsBack("https://x.test", t0 + 201));
    // 오류 페이지 — 앞 출처(e)는 기억하고 새 출처는 없다.
    r.errorPage(t0 + 500);
    try testing.expectEqual(@as(u8, 1), r.docsBack("http://e.test", t0 + 501));
    // 막힌 보내기는 창을 늘린다 — 창 안의 출처만.
    r.sendBlocked(t0 + 1400);
    try testing.expect(r.docsBack("http://e.test", t0 + 1800) != 0);
    try testing.expectEqual(@as(u8, 0), r.docsBack("http://e.test", t0 + 2000));
}

test "W9c①: the same origin left twice inside the window keeps the older document, and docs_back stops at 255" {
    var r: Recent = .{};
    const t0: u64 = 400_000;
    r.mainStarted("http://a.test/1", t0);
    r.mainStarted("http://b.test/", t0 + 100); // a 를 떠났다(문서 1)
    r.mainStarted("http://a.test/2", t0 + 200);
    r.mainStarted("http://c.test/", t0 + 300); // a 를 또 떠났다(문서 3) — 늦은 줄이 1 의 것인지 3 의 것인지 모른다
    try testing.expectEqual(@as(u8, 3), r.docsBack("http://a.test", t0 + 301));
    // 창이 지난 뒤 다시 떠나면 그 문서로.
    r.mainStarted("http://a.test/3", t0 + 5000);
    r.mainStarted("http://d.test/", t0 + 5100);
    try testing.expectEqual(@as(u8, 1), r.docsBack("http://a.test", t0 + 5101));
    var far: Recent = .{};
    far.mainStarted("http://a.test/", t0);
    far.mainStarted("http://b.test/", t0 + 1);
    for (0..300) |_| far.errorPage(t0 + 2);
    try testing.expectEqual(@as(u8, 255), far.docsBack("http://a.test", t0 + 3));
}

test "W9c①: the UTF-16 prefix stops at max units and never ends on a high surrogate" {
    const units = [_]u16{ 'a', 'b', 0xD83D, 0xDE00, 'c' };
    try testing.expectEqual(@as(usize, 5), prefixUnits(&units, 8));
    try testing.expectEqual(@as(usize, 2), prefixUnits(&units, 3)); // 짝의 앞에서 멈춘다
    try testing.expectEqual(@as(usize, 4), prefixUnits(&units, 4));
    try testing.expectEqual(@as(usize, 2), prefixUnits(&units, 2));
    const lone = [_]u16{0xD83D};
    try testing.expectEqual(@as(usize, 1), prefixUnits(&lone, 4)); // 끝까지면 그대로(CEF 가 U+FFFD 로 바꾼다)
}

test "W9c①: text is cleaned (control characters blanked, CRLF and CR to LF), clamped to 8192 bytes at a character with … inside the cap, and Uncaught gets (source:line)" {
    var out: [max_text]u8 = undefined;
    var a = "a\x1b[31mred\r\nnext\rlast\tok".*;
    try testing.expectEqualStrings("a [31mred\nnext\nlast\tok", finishText(&a, false, "", 0, &out));
    // 앞부분만 바꿨다 — 맞아도 「…」.
    var b = "short".*;
    try testing.expectEqualStrings("short…", finishText(&b, true, "", 0, &out));
    // 상한을 넘으면 글자 경계에서 자르고 「…」 을 상한 안에.
    var big: [max_text + 10]u8 = undefined;
    @memset(&big, 'x');
    @memcpy(big[max_text - 4 .. max_text - 1], "가"); // 경계에 걸친 3 바이트 글자
    const clamped = finishText(&big, false, "", 0, &out);
    try testing.expect(clamped.len <= max_text);
    try testing.expect(std.mem.endsWith(u8, clamped, "…"));
    try testing.expect(std.unicode.utf8ValidateSlice(clamped));
    try testing.expectEqualStrings("x" ** 8, clamped[0..8]);
    // 잡히지 않은 예외 — 꼬리에 source:line, source 는 256 바이트까지.
    var u = "Uncaught Error: boom".*;
    try testing.expectEqualStrings("Uncaught Error: boom (https://a.test/app.js:42)", finishText(&u, false, "https://a.test/app.js", 42, &out));
    var uu = "Uncaught Error: boom".*;
    const long_src = "https://a.test/" ++ "p" ** 400;
    const with_long = finishText(&uu, false, long_src, 7, &out);
    try testing.expectEqualStrings("Uncaught Error: boom (" ++ long_src[0..max_suffix_source_bytes] ++ ":7)", with_long);
    // source 가 없으면(eval 등) 꼬리가 없다. 「Uncaught」 가 아니면 붙이지 않는다.
    var no_src = "Uncaught Error: boom".*;
    try testing.expectEqualStrings("Uncaught Error: boom", finishText(&no_src, false, "", 3, &out));
    // 꼬리는 오류 수준의 「Uncaught」 에만 — 페이지가 `console.log('Uncaught x')` 를 남겨도 부른 곳을 달지 않는다.
    try testing.expect(uncaughtError(.@"error", "Uncaught Error: boom"));
    for ([_]ConsoleLevel{ .log, .info, .warn, .debug }) |lv| try testing.expect(!uncaughtError(lv, "Uncaught Error: boom"));
    try testing.expect(!uncaughtError(.@"error", "Error: Uncaught"));
    var l = "plain".*;
    try testing.expectEqualStrings("plain", finishText(&l, false, "https://a.test/app.js", 3, &out));
    // 꼬리가 있어도 상한 안 — 글을 잘라 자리를 낸다.
    @memcpy(big[0..8], "Uncaught");
    const both = finishText(&big, false, "https://a.test/a.js", 9, &out);
    try testing.expect(both.len <= max_text);
    try testing.expect(std.mem.endsWith(u8, both, "… (https://a.test/a.js:9)"));
    try protocol.fields.checkConsoleText(both);
}

test "W9c① 적대 리뷰 2 회차 재현 F2: A → B(다른 출처 iframe 셋) → C 에서 B 의 출처들이 A 의 주 프레임 출처를 밀어내지 않는다(두 문서 앞) — 전에는 A 의 늦은 줄이 지금 문서의 줄이 되었다" {
    var q: Recent = .{};
    const t0: u64 = 300_000;
    q.mainStarted("http://localhost:1/secret.html", t0);
    q.mainStarted("http://127.0.0.1:1/con3.html", t0 + 100); // A 를 떠난다
    for ([_][]const u8{ "http://127.0.0.1:2/f.html", "http://127.0.0.1:3/f.html", "http://127.0.0.1:4/f.html" }) |u| q.subframeStarted(u);
    q.mainStarted("http://127.0.0.1:1/con.html?c", t0 + 200); // B 와 그 iframe 출처 셋을 떠난다
    try testing.expectEqual(@as(u8, 1), q.docsBack("http://127.0.0.1:2", t0 + 300));
    try testing.expectEqual(@as(u8, 2), q.docsBack("http://localhost:1", t0 + 300)); // C 가 시작한 뒤 +100 ms 에 온 A 의 unload 줄
}

test "W9c① 적대 리뷰 3 회차 재현 F3: 두 출처를 오가며 방금 떠난 출처에서 로거를 부르는 페이지도 탭 상한 안이고 다른 탭의 오류는 다 지난다 — 전에는 제 줄이 앞 문서의 줄이 되어 탭 양동이를 건너뛰고(3 초에 3159 줄) 전체 양동이로 다른 탭의 오류를 굶겼다(24/60)" {
    var attacker: Gate = .{};
    var victim: Gate = .{};
    var global: Global = .{};
    const t0: u64 = 20_000_000;
    attacker.recent.mainStarted("http://x.test/pp.html", t0);
    var attacker_passed: usize = 0;
    var victim_errors: usize = 0;
    var victim_passed: usize = 0;
    var t: u64 = t0;
    var here_x = true;
    // 3 초: 페이지는 900 ms 마다 출처를 바꾸고, 그 사이 ms 마다 64 바이트 줄 넷을 **다른** 출처(1 초 안에 떠난 주 프레임 출처)의 스크립트로
    // 남긴다. 다른 탭은 50 ms 마다 오류 하나(20/s — 제 오류 양동이 몫).
    while (t < t0 + 3000) : (t += 1) {
        if ((t - t0) % 900 == 899) {
            attacker.recent.mainStarted(if (here_x) "http://y.test/pp.html" else "http://x.test/pp.html", t);
            here_x = !here_x;
        }
        const src_origin: []const u8 = if (here_x) "http://y.test" else "http://x.test";
        const back = attacker.recent.docsBack(src_origin, t);
        for (0..4) |_| {
            if (attacker.admit(&global, .other, back, max_text, t)) {
                attacker.charge(&global, .other, back != 0, 64);
                attacker_passed += 1;
            }
        }
        if ((t - t0) % 50 == 0) {
            victim_errors += 1;
            if (victim.admit(&global, .important, 0, max_text, t)) {
                victim.charge(&global, .important, false, 40);
                victim_passed += 1;
            }
        }
    }
    // 첫 900 ms 는 새 문서의 그 밖 갈래(버스트 200 + 50/s)를, 그 뒤는 앞 문서 양동이(버스트 80 + 5/s)만 쓴다 — 탭 상한(200 + 3 × 50) 안이다.
    try testing.expect(attacker_passed <= 350);
    try testing.expectEqual(victim_errors, victim_passed);
}

test "W9c① 적대 리뷰 4 회차 재현 A: 사이트의 모든 페이지가 담는 다른 출처 위젯 iframe — 이동마다 처음 1 초의 줄은 앞 문서의 줄로 가려 작은 앞 문서 양동이에서 버려지고, 버린 수는 가장 앞 문서의 `docs_back` 과 함께 남는다 — 전에는 세지 않아 표지가 없었다(374/600, 오류 8/30)" {
    // shop.test 의 모든 페이지가 widget.test iframe(채팅·결제 위젯)을 담는다. 2 초마다 같은 사이트 안에서 문서를 옮기고(에이전트가 누르며
    // 다닌다), 새 문서의 위젯은 처음 1 초에 20 줄을 남기고 그 가운데 하나는 오류다. 위젯 출처는 방금 떠난 문서의 하위 프레임 출처라
    // `docsBack` 이 1 — 새 문서의 줄인데도 앞 문서 양동이(5/s·버스트 80)를 쓴다. 묶인 쪽(에이전트가 연 탭은 태어날 때 묶인다)에게
    // 이 줄은 보이는 줄이다(origin_doc ≥ latched_doc).
    var g: Gate = .{};
    var global: Global = .{};
    const t0: u64 = 30_000_000;
    g.recent.mainStarted("https://shop.test/p0", t0);
    g.recent.subframeStarted("https://widget.test/frame");
    var offered: usize = 0;
    var admitted: usize = 0;
    var errors_offered: usize = 0;
    var errors_admitted: usize = 0;
    var t: u64 = t0;
    var nav: usize = 0;
    while (nav < 30) : (nav += 1) {
        t += 2000;
        g.recent.mainStarted("https://shop.test/next", t);
        g.recent.subframeStarted("https://widget.test/frame");
        for (0..20) |k| {
            const at = t + 50 * k;
            const back = g.recent.docsBack("https://widget.test", at);
            try testing.expect(back == 1); // 새 문서의 위젯 줄이 앞 문서의 줄로 분류된다(문서화된 1 초 창)
            const class: Class = if (k == 10) .important else .other;
            offered += 1;
            if (k == 10) errors_offered += 1;
            if (g.admit(&global, class, back, textBound(40), at)) {
                g.charge(&global, class, true, 120);
                admitted += 1;
                if (k == 10) errors_admitted += 1;
            }
        }
    }
    // 다 지나지는 않는다(앞 문서 양동이는 그대로 — 작성자 선택) — 대신 버린 수가 모두 세어져 표지가 된다.
    try testing.expect(admitted < offered);
    try testing.expect(errors_admitted < errors_offered);
    try testing.expectEqual(@as(u32, @intCast(offered - admitted)), g.dropped_old);
    try testing.expectEqual(@as(u8, 1), g.dropped_old_back);
    try testing.expectEqual([2]u32{ 0, 0 }, g.dropped); // 새 문서의 수에는 섞이지 않는다
    try testing.expect(g.hasDrops());
}

test "W9c① 적대 리뷰 4 회차 재현 B: 3 회차의 두 출처를 오가는 페이지가 모든 갈래를 8 KiB 줄로 채워도 다른 탭의 오류는 그냥 쏟아내는 탭을 상대할 때만큼 지난다 — 전에는 앞 문서 갈래의 버스트와 빚이 전체 바이트를 다 써 114/200(대조 191/200)이었다" {
    // 비교: 같은 탭이 옮겨 다니지 않고 제 두 갈래만 8 KiB 줄로 채운다(3 회차 전에도 있던 기준) / 3 회차 재현 F3 처럼 두 출처를 오가며
    // 떠난 출처의 스크립트로도 남긴다(앞 문서 갈래 8 KiB/s·버스트 32 KiB 가 더해진다). 다른 탭은 50 ms 마다 100 바이트 오류.
    var results: [2]usize = undefined;
    var taken: [2]usize = undefined;
    for ([_]bool{ false, true }, 0..) |ping_pong, idx| {
        var attacker: Gate = .{};
        var victim: Gate = .{};
        var global: Global = .{};
        const t0: u64 = 40_000_000;
        attacker.recent.mainStarted("http://x.test/pp.html", t0);
        var here_x = true;
        var t: u64 = t0;
        var victim_passed: usize = 0;
        var victim_offered: usize = 0;
        var attacker_bytes: usize = 0;
        while (t < t0 + 10_000) : (t += 1) {
            if (ping_pong and (t - t0) % 900 == 899) {
                attacker.recent.mainStarted(if (here_x) "http://y.test/pp.html" else "http://x.test/pp.html", t);
                here_x = !here_x;
            }
            const here: []const u8 = if (here_x) "http://x.test" else "http://y.test";
            const left: []const u8 = if (here_x) "http://y.test" else "http://x.test";
            for ([_]Class{ .important, .other }) |cl| {
                const back = attacker.recent.docsBack(here, t);
                if (attacker.admit(&global, cl, back, max_text, t)) {
                    attacker.charge(&global, cl, back != 0, 8192);
                    attacker_bytes += 8192;
                }
            }
            if (ping_pong) {
                const back = attacker.recent.docsBack(left, t);
                if (back != 0 and attacker.admit(&global, .other, back, max_text, t)) {
                    attacker.charge(&global, .other, true, 8192);
                    attacker_bytes += 8192;
                }
            }
            if ((t - t0) % 50 == 0) {
                victim_offered += 1;
                if (victim.admit(&global, .important, 0, max_text, t)) {
                    victim.charge(&global, .important, false, 100);
                    victim_passed += 1;
                }
            }
        }
        results[idx] = victim_passed;
        taken[idx] = attacker_bytes;
        try testing.expectEqual(@as(usize, 200), victim_offered);
    }
    // 오가는 페이지가 더 가져가는 것은 앞 문서 갈래의 작은 몫뿐이다(전에는 528 → 640 KiB — 10 초 동안 전체 바이트 전부).
    try testing.expect(taken[1] <= taken[0] + 32 * 1024);
    // 앞 문서의 줄은 전체 바이트가 넉넉할 때만 지나 오가는 페이지도 그냥 쏟아내는 탭보다 다른 탭을 더 굶기지 못한다.
    try testing.expect(results[0] >= 180);
    try testing.expect(results[1] >= results[0]);

    // 남길 몫은 줄의 상한으로 본다 — 새 페이지가 시작 줄로 전체 바이트를 20 KiB 쓴 중에도 앞 문서의 짧은 unload 줄(실측 이동마다 3–7 줄)은
    // 지나고, 8 KiB 일 수 있는 줄은 남길 몫을 깎아 버려진다(세어진다).
    var g: Gate = .{};
    var global: Global = .{};
    const t1: u64 = 50_000_000;
    try testing.expect(g.admit(&global, .other, 0, max_text, t1));
    g.charge(&global, .other, false, 20 * 1024);
    for (0..7) |_| {
        try testing.expect(g.admit(&global, .other, 1, textBound(100), t1));
        g.charge(&global, .other, true, 200);
    }
    try testing.expect(!g.admit(&global, .important, 1, max_text, t1));
    try testing.expectEqual(@as(u32, 1), g.dropped_old);
    try testing.expectEqual(@as(usize, 300 + max_suffix_source_bytes + 32), textBound(100));
    try testing.expectEqual(max_text, textBound(1 << 40));
}

test "W9c① 적대 리뷰 5 회차 재현 A: 한 보내기 사이에 두 문서에서 버린 앞 문서의 줄은 문서마다 따로 보낸다 — 전에는 다섯이 가장 앞 문서(A)의 수로 합쳐져 B 에 묶인 쪽에게 B 의 버림 넷이 보이지 않았다, 번갈아 부르는 페이지도 frame 을 몫만큼만 만든다" {
    // A → B → C, 이동마다 300 ms(1 초 창 안). 탭은 C 에서 조용하다(지난 줄이 버린 수를 실어 가지 않는다). 다른 탭이 바빠 전체 바이트가
    // 남길 몫 아래라 앞 문서의 줄은 모두 버린다.
    var g: Gate = .{};
    var global: Global = .{};
    const t0: u64 = 60_000_000;
    g.recent.mainStarted("https://a.test/", t0);
    g.recent.mainStarted("https://b.test/", t0 + 300); // A 를 떠난다
    g.clearDrops(); // `mainFrameStarted` 가 경계 앞에 보냈다
    g.recent.mainStarted("https://c.test/", t0 + 600); // B 를 떠난다 — A 는 아직 창 안
    g.clearDrops();
    global.bytes.refill(t0 + 650);
    global.bytes.balance = 10 * 1024 * 1000; // 10 KiB — 남길 몫(24 KiB) 아래
    const now = t0 + 650;
    const back_a = g.recent.docsBack("https://a.test", now);
    const back_b = g.recent.docsBack("https://b.test", now);
    try testing.expectEqual(@as(u8, 2), back_a);
    try testing.expectEqual(@as(u8, 1), back_b);
    // console.zig 의 차례 — `splitOld` 가 참이면 쌓인 수를 먼저 보내고(여기서는 적어 두고 비운다) 그 줄을 본다.
    const Sent = struct { count: u32, back: u8 };
    var sent: [64]Sent = undefined;
    var n: usize = 0;
    const offer = struct {
        fn f(gate_: *Gate, global_: *Global, back: u8, class: Class, at: u64, out: []Sent, len: *usize) !void {
            if (gate_.splitOld(global_, back, at)) {
                out[len.*] = .{ .count = gate_.dropped_old, .back = gate_.dropped_old_back };
                len.* += 1;
                gate_.clearDrops();
            }
            try testing.expect(!gate_.admit(global_, class, back, textBound(40), at));
        }
    }.f;
    // A 의 늦은 unload 줄 하나(두 문서 앞)와 B 의 넷(한 문서 앞).
    try offer(&g, &global, back_a, .other, now, &sent, &n);
    for (0..4) |_| try offer(&g, &global, back_b, .important, now, &sent, &n);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(Sent{ .count = 1, .back = 2 }, sent[0]);
    try testing.expectEqual(@as(u32, 4), g.dropped_old);
    try testing.expectEqual(@as(u8, 1), g.dropped_old_back); // maru 는 B 의 표지로 — B 에 묶인 쪽이 본다
    // 같은 문서의 버림은 나누지 않는다.
    try testing.expect(!g.splitOld(&global, back_b, now));
    // 떠난 출처 둘의 스크립트를 번갈아 부르는 페이지 — 나누는 frame 은 버스트 10 에 초당 5 만큼만, 그 밖은 가장 앞 문서로 합친다(더 숨기는 쪽).
    var h: Gate = .{};
    var hg: Global = .{};
    h.recent = g.recent;
    var m: usize = 0;
    var t: u64 = now;
    while (t < now + 1000) : (t += 1) {
        hg.bytes.refill(t);
        hg.bytes.balance = 0; // 다른 탭이 늘 전체 바이트를 다 쓴다
        try offer(&h, &hg, if (t % 2 == 0) back_a else back_b, .other, t, &sent, &m);
        if (m == sent.len) break;
    }
    try testing.expect(m >= 10 and m <= 10 + 5 + 1);
    try testing.expect(h.dropped_old_back == back_a); // 몫이 없을 때 합친 수는 가장 앞 문서로
}
