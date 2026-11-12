//! 기기 흉내의 명령 열(W9e① — docs/plans/web-osr-backend.md 「W9e① 결정·실측」 §7). CEF 를 모른다 — 탭마다 maru 가 바란 상태(`want` —
//! `emulation` frame 그대로), Chromium 에 걸어 둔 것(`sent` — 명령 종류마다 인자 JSON 의 해시), 렌더러가 살아 있는가(`alive`), 맨 위 페이지가
//! grant 사이트 안인가(`on_site`), pane 크기(`pane_w`·`pane_h` DIP)를 쥐고 **무엇을 보낼지**(명령과 그 인자 JSON)만 정한다. 보내기·답 받기는
//! `emulation.zig` 가 한다(`net_domain.zig` 와 `blocking.zig` 의 나눔과 같다).
//!
//! 규칙(실측 근거는 계획 §1):
//!   - **바뀐 것만** 보낸다 — 종류마다 지금 바라는 인자 JSON 의 해시가 건 것과 다를 때만(같은 값을 다시 보내지 않는다 — E20 비용은 작지만
//!     metrics 를 다시 걸면 그 문서가 다시 배치된다).
//!   - **렌더러가 없으면 아무것도 보내지 않는다**(빈 열). 렌더러가 죽은 탭에 `setDeviceMetricsOverride` 를 보내면 sidecar 가 통째로 죽었다
//!     (E11 — 세 번). 이미 건 흉내는 Chromium 이 새 렌더러에 다시 건다(E4) — 되살아나면 그동안 쌓인 **차이만** 보낸다.
//!   - 사이트에 묶인 탭(사용자 탭 — 사용자 결정 Q1)이 사이트 밖이면 **모두 지운다**(돌아오면 다시 건다).
//!   - 사이트 밖 문서에서 사이트 안으로 가는 이동은 **커밋까지 탭 전체에 아무것도 걸지 않는다**(`hold` — `heldUntilCommit`): 그 홉의 주 프레임 문서
//!     요청 하나에만 흉내 `User-Agent`·`Accept-Language`·client hints 를 직접 넣고(`injection` — `emu_inject.zig` 가 IO 스레드에서), 모든 무리는 새
//!     문서의 커밋(`navigate`)에서 건다. 화면 흉내를 홉에서 걸면 응답을 기다리는 동안 옛(밖의) 문서가 흉내 폭·배율을 봤고(옮긴 판 검증 2 회차), UA
//!     호출을 홉에서 걸면 그 옛 문서가 만든 iframe·form 대상·Worker 의 요청이 허락하지 않은 사이트로 흉내 UA·Accept-Language 를 실었다(집중 검증
//!     1 회차 — 밖의 페이지는 느린 주소로 그 기다림을 늘릴 수 있다; 사용자 결정 2026-11-12 「그 한 요청만 머리를 직접 넣기」).
//!   - 지움의 꼴: 미디어는 네 기능 이름을 모두 빈 값으로(`{}` 는 forced-colors 를 지우지 않았다 — E17), UA 는 `{"userAgent":""}`, 시간대는
//!     `{"timezoneId":""}`, 언어는 `{}`, 색각은 `{"type":"none"}`, 화면은 `Emulation.clearDeviceMetricsOverride`, 터치는 `{"enabled":false}`.
//!   - UA 와 언어의 머리 쪽(`Accept-Language`)은 **한 호출**이다(`setUserAgentOverride` — 뒤 호출에 acceptLanguage 가 없으면 기본으로 돌아간다,
//!     E7). UA 흉내가 없으면 `userAgent:""` 에 acceptLanguage 만 — 기본 UA·client hints 를 그대로 둔다(E7).
//!   - 화면은 pane 에 맞춰 줄인다(사용자 결정 Q3 — Chromium 의 `scale`): fit = min(1, pane 폭 / 흉내 폭, pane 높이 / 흉내 높이). pane 크기가
//!     바뀌면 다시 셈해 다시 보낸다(Chromium 은 셈하지 않는다 — E2).
//!   - 위치는 CDP 를 여기서 보내지 않는다 — W5b2 와 한 칸(`permissions.zig`)이 건다. 이 표는 「무엇을 바라는가」 만 정한다.
//!
//! 시험이 증명하는 것: 바뀐 것만 명령, 지움 꼴(미디어 네 이름 빈 값·UA ""·시간대 ""·언어 {}·색각 none), 죽은 동안 빈 열·되살아나면 쌓인 차이만,
//! metrics 는 살아 있을 때만(변이: 이 검사를 지우면 시험이 실패한다), 사이트 밖 모두 지움·돌아오면 다시, 밖→안 홉의 기다림(탭 전체에 아무것도·상태는 밖,
//! 그 홉의 문서 요청에 넣을 머리 — 넣지 않는 경우·client hints 의 꼴·Accept-Language 의 q 값), fit 셈과 resize, 답 받기의 마스크·까닭, 번호 대역.

const std = @import("std");
const protocol = @import("web_sidecar_protocol");

const msg = protocol.message;
const emu_fields = protocol.emu_fields;
const net_policy = protocol.net_policy;

/// 흉내의 CDP 번호 대역 — 다른 사용처와 겹치지 않는다(권한·알림 수만 번대, 엄격 [1<<27, 1<<27 + 1<<20), 본문 [1<<28, 1<<29),
/// DevTools [1<<29, 1<<30), 미디어 [1<<30, ..)). 계획 v2 §5 는 [1<<28, 1<<29) 라 적었지만 그 자리는 `net_body_table` 의 대역이다(코드).
pub const id_base: i32 = 1 << 26;
pub const id_end: i32 = (1 << 26) + (1 << 20);

/// 명령 종류 — 차례가 보내는 차례다(화면 → 터치 → 머리 → 언어 → 시간대 → 미디어 → 색각 → 위치).
pub const Kind = enum(u3) { metrics, touch, ua, locale, timezone, media, vision, geo };
pub const kind_count = 8;

/// 걸어 둔 값이 무엇인지 모른다(답을 받기 전에 DevTools 가 떨어졌다) — 다음 계획이 다시 보낸다.
const unknown_hash: u64 = std.math.maxInt(u64);

pub const Cmd = struct {
    kind: Kind,
    /// 참 = 건다(`set`), 거짓 = 지운다.
    set: bool,
    /// CDP 메서드(위치는 빈 글 — `permissions.zig` 가 건다).
    method: []const u8,
    /// 인자 JSON(`Cmds.buf` 를 빌린다). 위치는 `geo` 를 본다.
    params: []const u8,
    /// 위치: 좌표(`unavailable` 이면 「없음」). set 거짓이면 maru 의 W5b2 상태로 돌린다.
    geo: struct { unavailable: bool = false, latitude: f64 = 0, longitude: f64 = 0, accuracy: f64 = 0 } = .{},
};

pub const Cmds = struct {
    items: [kind_count]Cmd = undefined,
    len: usize = 0,
    buf: [6 * 1024]u8 = undefined,
    used: usize = 0,

    pub fn slice(self: *const Cmds) []const Cmd {
        return self.items[0..self.len];
    }
};

/// 명령 종류의 무리(마스크 — `emulation_state`). UA 호출은 UA 흉내가 없으면 언어 무리다(Accept-Language 만 실었다).
pub fn groupOf(kind: Kind, ua_set: bool) msg.EmuGroup {
    return switch (kind) {
        .metrics, .touch => .viewport,
        .ua => if (ua_set) .user_agent else .locale,
        .locale => .locale,
        .timezone => .timezone,
        .media => .media,
        .vision => .vision,
        .geo => .geolocation,
    };
}

pub const Status = enum { idle, pending, ok, failed };

/// 사이트 안으로 가는 이동이 커밋되기 전(사이트 밖 문서가 아직 보인다) 미루는 종류인가 — **모두**. 실측(CEF 154, 판정 `emu-site-bound-slow-hop`):
/// 화면을 홉에서 걸면 옛 문서가 기다림 내내 화면·배율 흉내를 봤고(시간대·언어·터치·미디어는 보지 않았다 — DevTools 가 커밋까지 렌더러 쪽 명령을
/// 붙잡는 것으로 보인다), UA 호출(`.ua` — UA·client hints·Accept-Language)을 홉에서 걸면 렌더러 쪽(navigator·옛 문서의 fetch)은 붙잡혔지만
/// 브라우저 쪽에서 만드는 이동 요청 — 옛 문서가 만든 iframe 문서·form 대상·dedicated Worker 스크립트 — 이 곧 흉내 머리를 싣고 허락하지 않은
/// 사이트로 갔다(집중 검증 1 회차 SEVERE). 그 홉의 문서 요청 하나는 `Tab.injection` 이 머리로 직접 채운다(사용자 결정 2026-11-12). 모두 미뤄도 새
/// 문서의 첫 스크립트는 모든 무리를 봤다(같은 판정의 `T0` — 커밋 알림 `on_load_start` 가 문서의 스크립트보다 먼저다).
pub fn heldUntilCommit(kind: Kind) bool {
    _ = kind;
    return true;
}

/// fit 셈의 단일 출처는 `emu_fields.fitScale`(maru 도 같은 셈으로 결과의 `fit_scale` 을 미리 보인다).
pub const fitScale = emu_fields.fitScale;

/// maru 가 바란 상태의 사본 — `emulation` 몸통을 그대로 쥔다(풀면 글은 이 버퍼를 빌린다).
const Stored = struct {
    bytes: [emu_fields.max_emulation_body_bytes]u8 = undefined,
    len: usize = 0,

    fn put(self: *Stored, v: msg.Emulation) !void {
        var cursor = protocol.wire.Cursor.init(&self.bytes);
        try emu_fields.writeEmulation(&cursor, v);
        self.len = cursor.pos;
    }

    fn get(self: *const Stored) ?msg.Emulation {
        if (self.len == 0) return null;
        var cursor = protocol.wire.ReadCursor.init(self.bytes[0..self.len]);
        return emu_fields.readEmulation(&cursor) catch null;
    }
};

pub const Tab = struct {
    want: Stored = .{},
    generation: u32 = 0,
    /// 종류마다 Chromium 에 걸어 둔 인자 JSON 의 해시(0 = 지움 — 처음 상태, `unknown_hash` = 모름).
    sent: [kind_count]u64 = @splat(0),
    status: [kind_count]Status = @splat(.idle),
    /// 종류마다 그 무리가 UA 흉내였는가(UA 호출의 무리 — 걸 때의 것).
    ua_was_set: bool = false,
    reason: msg.EmuFailReason = .none,
    alive: bool = true,
    on_site: bool = true,
    /// 사이트 안으로 가는 주 프레임 이동이 커밋 전이고 지금 보이는 문서는 사이트 밖이다 — 탭 전체에는 아무것도 걸지 않고(`heldUntilCommit`) 그 홉의
    /// 문서 요청에만 머리를 넣는다(`injection`). 상태는 사이트 밖으로 알린다(maru 의 입력 줄임·테두리는 옛 문서에 걸리지 않는다). 커밋·끊김·오류
    /// 페이지(`navigate`)가 끈다.
    hold: bool = false,
    pane_w: u32 = 0,
    pane_h: u32 = 0,
    /// 마지막으로 보낸 metrics 의 fit(상태가 싣는다).
    fit: f32 = 1,

    /// maru 의 새 상태. 사이트가 바뀌었을 수 있다 — `on_site` 는 부른 쪽이 지금 맨 위 호스트로 다시 정한다(`siteCovers`).
    pub fn setWant(self: *Tab, v: msg.Emulation) !void {
        try self.want.put(v);
        self.generation = v.generation;
    }

    pub fn wanted(self: *const Tab) ?msg.Emulation {
        return self.want.get();
    }

    /// 사이트에 묶였으면 그 호스트를 덮는가(묶이지 않았으면 늘 참). 호스트를 모르면(http(s) 가 아니다) 밖이다.
    pub fn siteCovers(self: *const Tab, host: ?[]const u8) bool {
        const w = self.want.get() orelse return true;
        if (!w.flags.site_bound) return true;
        return net_policy.hostCovers(w.site, host orelse return false);
    }

    /// 지금 걸려야 하는 상태(사이트 밖이면 빈 상태).
    fn target(self: *const Tab) msg.Emulation {
        const w = self.want.get() orelse return .{ .browser = 0 };
        if (w.flags.site_bound and !self.on_site) return .{ .browser = w.browser };
        return w;
    }

    /// 그 종류에 지금 걸려야 하는 상태 — 커밋을 기다리는 동안(`hold`) 미루는 종류(지금은 모두 — `heldUntilCommit`)는 빈 상태.
    fn targetFor(self: *const Tab, kind: Kind) msg.Emulation {
        if (self.hold and heldUntilCommit(kind)) return .{ .browser = if (self.want.get()) |w| w.browser else 0 };
        return self.target();
    }

    /// 무엇을 보낼지 — 바뀐 종류만. 렌더러가 없으면 빈 열(E11). 보낸다고 정한 종류는 `sent` 를 그 값으로 두고 `pending` 이다.
    pub fn plan(self: *Tab, out: *Cmds) void {
        out.* = .{};
        if (!self.alive) return;
        const tm = self.targetFor(.metrics);
        self.fit = if (tm.flags.viewport) fitScale(self.pane_w, self.pane_h, tm.width, tm.height) else 1;
        inline for (@import("type_info_fields").fields(Kind)) |f| {
            const kind: Kind = @fromBackingInt(@intCast(f.value));
            self.planKind(kind, self.targetFor(kind), out);
        }
    }

    fn planKind(self: *Tab, kind: Kind, t: msg.Emulation, out: *Cmds) void {
        const i = @backingInt(kind);
        var cmd: Cmd = .{ .kind = kind, .set = false, .method = "", .params = "" };
        const rest = out.buf[out.used..];
        const params = buildParams(kind, t, self.fit, rest, &cmd) catch return; // 버퍼는 가장 큰 인자를 담는다(시험) — 못 담으면 보내지 않는다
        const h: u64 = if (!cmd.set) 0 else blk: {
            // 위치는 값의 바이트로(구조체 그대로는 채움 바이트가 정해지지 않아 같은 값이 다른 해시가 된다).
            var gb: [25]u8 = undefined;
            if (kind == .geo) {
                std.mem.writeInt(u64, gb[0..8], @bitCast(cmd.geo.latitude), .little);
                std.mem.writeInt(u64, gb[8..16], @bitCast(cmd.geo.longitude), .little);
                std.mem.writeInt(u64, gb[16..24], @bitCast(cmd.geo.accuracy), .little);
                gb[24] = @intFromBool(cmd.geo.unavailable);
            }
            const raw = std.hash.Wyhash.hash(@backingInt(kind), if (kind == .geo) &gb else params);
            break :blk if (raw == 0 or raw == unknown_hash) 1 else raw;
        };
        if (h == self.sent[i]) return;
        cmd.params = params;
        out.used += params.len;
        out.items[out.len] = cmd;
        out.len += 1;
        self.sent[i] = h;
        self.status[i] = if (cmd.set) .pending else .idle;
        if (kind == .ua) self.ua_was_set = t.flags.ua;
        if (kind == .geo) self.status[i] = if (cmd.set) .ok else .idle; // 위치는 답을 기다리지 않는다(`permissions.zig` 가 곧 건다)
    }

    /// 보내지 못했다(`send_dev_tools_message` 가 0) — 그 종류는 실패, 다음 바뀜에 다시.
    pub fn sendFailed(self: *Tab, kind: Kind) void {
        self.status[@backingInt(kind)] = .failed;
        if (self.reason == .none) self.reason = .cdp_error;
    }

    /// CDP 의 답. `err_json` 은 실패의 오류 객체(까닭을 가른다 — 「already in effect」 는 같은 프로세스의 팝업이 쥔 것: E13).
    pub fn answered(self: *Tab, kind: Kind, ok: bool, err_json: []const u8) void {
        const i = @backingInt(kind);
        if (self.status[i] != .pending) return;
        if (ok) {
            self.status[i] = .ok;
            return;
        }
        self.status[i] = .failed;
        const why: msg.EmuFailReason = if (std.mem.indexOf(u8, err_json, "already in effect") != null)
            .process_shared_conflict
        else if (kind == .timezone and std.ascii.findIgnoreCase(err_json, "invalid timezone") != null)
            .timezone_unknown
        else
            .cdp_error;
        if (self.reason == .none) self.reason = why;
    }

    /// DevTools 가 떨어졌다(렌더러가 죽음 등) — 답을 기다리던 종류는 걸렸는지 모른다: 다음 계획이 다시 보낸다.
    pub fn detached(self: *Tab) void {
        for (&self.status, &self.sent) |*st, *s| if (st.* == .pending) {
            st.* = .idle;
            s.* = unknown_hash;
        };
    }

    pub fn rendererGone(self: *Tab) void {
        self.alive = false;
        self.detached();
    }

    /// 새 렌더러(주 프레임 `on_load_start`) — 참이면 부른 쪽이 계획을 다시 돌린다.
    pub fn rendererBack(self: *Tab) bool {
        if (self.alive) return false;
        self.alive = true;
        return true;
    }

    /// 맨 위 문서가 섰다(커밋 — `on_load_start`) 또는 이동이 끊겨 옛 문서가 남았다: 그 문서의 호스트로 사이트 안팎을 정하고 커밋 기다림을 끝낸다.
    /// 바뀌었으면 참(부른 쪽이 계획을 다시 돌린다).
    pub fn navigate(self: *Tab, host: ?[]const u8) bool {
        const now = self.siteCovers(host);
        const changed = now != self.on_site or self.hold;
        self.on_site = now;
        self.hold = false;
        return changed;
    }

    /// 주 프레임 이동 홉(`on_before_browse` — 커밋 전, 리다이렉트마다)의 호스트와 지금 보이는(커밋된) 문서의 호스트. 사이트 밖 문서에서 사이트 안으로
    /// 가면 커밋까지 탭 전체에 아무것도 걸지 않고 그 홉의 문서 요청에만 머리(`hold` — `injection`), 안에서 안이면 모두, 밖으로 가면 곧 모두 지운다.
    /// 바뀌었으면 참.
    pub fn hop(self: *Tab, host: ?[]const u8, shown: ?[]const u8) bool {
        const now = self.siteCovers(host);
        const hold = now and !self.siteCovers(shown);
        if (now == self.on_site and hold == self.hold) return false;
        self.on_site = now;
        self.hold = hold;
        return true;
    }

    /// 밖→안 홉을 기다리는 동안(`hold`) 그 홉의 주 프레임 문서 요청 하나에 넣을 머리 — UA·언어 흉내가 있을 때만(아니면 거짓, `out` 은 그대로).
    /// 탭 전체의 걸기는 커밋까지 미루므로(`heldUntilCommit`) 허락한 사이트로 가는 그 요청만 흉내 머리를 싣는다(사용자 결정 2026-11-12). 지움·철회·
    /// 다른 사이트로 바뀐 `emulation`(부른 쪽이 `hop` 을 다시 돌린다)·커밋·끊김은 `hold` 를 내리거나 흉내를 비워 거짓이 된다.
    pub fn injection(self: *const Tab, out: *Inject) bool {
        if (!self.hold or !self.on_site) return false;
        const w = self.want.get() orelse return false;
        if (!w.flags.site_bound or !(w.flags.ua or w.flags.locale)) return false;
        out.* = Inject.build(w) catch return false; // 버퍼는 가장 큰 흉내를 담는다(시험) — 못 담으면 넣지 않는다(흉내 머리가 한 요청 늦을 뿐)
        return true;
    }

    /// pane 크기(DIP) — 흉내 화면이 있고 fit 이 바뀌면 참.
    pub fn resize(self: *Tab, w: u32, h: u32) bool {
        self.pane_w = w;
        self.pane_h = h;
        const t = self.targetFor(.metrics);
        if (!t.flags.viewport) return false;
        return fitScale(w, h, t.width, t.height) != self.fit;
    }

    /// 아직 답을 기다리는 종류가 있는가.
    pub fn waiting(self: *const Tab) bool {
        for (self.status) |s| if (s == .pending) return true;
        return false;
    }

    /// 죽은 동안 쌓인 바뀜이 있는가(상태 `waiting_renderer`) — 계획을 돌려 보지 않고, 바라는 것과 건 것이 다른 종류가 있는지만.
    pub fn held(self: *const Tab) bool {
        if (self.alive) return false;
        var copy = self.*;
        copy.alive = true;
        var cmds: Cmds = .{};
        copy.plan(&cmds);
        return cmds.len > 0;
    }

    /// `emulation_state` — 무리마다 걸림(걸린 종류가 모두 답 `ok`)·실패(하나라도 실패), 지운 종류는 셈하지 않는다.
    pub fn state(self: *const Tab, browser: msg.BrowserId) msg.EmulationState {
        var active: u16 = 0;
        var failed: u16 = 0;
        var pending: u16 = 0;
        for (self.status, 0..) |st, i| {
            const kind: Kind = @fromBackingInt(@intCast(i));
            if (self.sent[i] == 0 and st != .failed) continue;
            const bit: u16 = @as(u16, 1) << @backingInt(groupOf(kind, self.ua_was_set));
            switch (st) {
                .ok => active |= bit,
                .failed => failed |= bit,
                .pending => pending |= bit,
                .idle => {},
            }
        }
        active &= ~(failed | pending);
        const t = self.targetFor(.metrics);
        return .{
            .browser = browser,
            .generation = self.generation,
            .on_site = self.on_site and !self.hold,
            .alive = self.alive,
            .pending = pending != 0 or self.held(),
            .fit_scale = if (t.flags.viewport and self.alive) self.fit else if (t.flags.viewport) fitScale(self.pane_w, self.pane_h, t.width, t.height) else 1,
            .active_mask = active,
            .failed_mask = failed,
            .reason = if (failed != 0) (if (self.reason == .none) .cdp_error else self.reason) else .none,
        };
    }

    /// 새 세대를 받으면 앞 세대의 실패 까닭을 지운다(실패한 종류는 값이 바뀌면 다시 보낸다).
    pub fn newGeneration(self: *Tab) void {
        self.reason = .none;
        for (&self.status, &self.sent) |*st, *s| if (st.* == .failed) {
            st.* = .idle;
            s.* = unknown_hash; // 같은 값이어도 한 번 더 해 본다(같은 세대 안에서는 다시 보내지 않는다)
        };
    }
};

// ── 인자 JSON ───────────────────────────────────────────────────────────────────────────────────────────

const Writer = std.Io.Writer;

fn mediaTypeName(v: msg.EmuMediaType) []const u8 {
    return switch (v) {
        .none => "",
        .screen => "screen",
        .print => "print",
    };
}

fn visionName(v: msg.EmuVision) []const u8 {
    return switch (v) {
        .none => "none",
        .blurred_vision => "blurredVision",
        .reduced_contrast => "reducedContrast",
        .achromatopsia => "achromatopsia",
        .deuteranopia => "deuteranopia",
        .protanopia => "protanopia",
        .tritanopia => "tritanopia",
    };
}

fn schemeName(v: msg.EmuColorScheme) []const u8 {
    return switch (v) {
        .none => "",
        .light => "light",
        .dark => "dark",
    };
}

fn motionName(v: msg.EmuReducedMotion) []const u8 {
    return switch (v) {
        .none => "",
        .reduce => "reduce",
        .no_preference => "no-preference",
    };
}

fn forcedName(v: msg.EmuForcedColors) []const u8 {
    return switch (v) {
        .none => "",
        .active => "active",
        .off => "none",
    };
}

fn contrastName(v: msg.EmuContrast) []const u8 {
    return switch (v) {
        .none => "",
        .more => "more",
        .less => "less",
        .no_preference => "no-preference",
    };
}

fn writeBrandList(s: *std.json.Stringify, list: []const msg.EmuBrand) !void {
    try s.beginArray();
    for (list) |b| {
        try s.beginObject();
        try s.objectField("brand");
        try s.write(b.brand);
        try s.objectField("version");
        try s.write(b.version);
        try s.endObject();
    }
    try s.endArray();
}

/// 그 종류의 인자 JSON 을 `buf` 에 쓴다(지움이면 지움 꼴) — `cmd.set`·`cmd.method`·`cmd.geo` 를 채운다.
pub fn buildParams(kind: Kind, t: msg.Emulation, fit: f32, buf: []u8, cmd: *Cmd) ![]const u8 {
    var w: Writer = .fixed(buf);
    var s: std.json.Stringify = .{ .writer = &w, .options = .{} };
    switch (kind) {
        .metrics => if (t.flags.viewport) {
            cmd.set = true;
            cmd.method = "Emulation.setDeviceMetricsOverride";
            try s.beginObject();
            try s.objectField("width");
            try s.write(t.width);
            try s.objectField("height");
            try s.write(t.height);
            try s.objectField("deviceScaleFactor");
            try s.print("{d}", .{t.dsf});
            try s.objectField("mobile");
            try s.write(t.flags.mobile);
            try s.objectField("scale");
            try s.print("{d:.4}", .{fit});
            try s.objectField("screenOrientation");
            try s.print("{s}", .{if (t.flags.landscape) "{\"type\":\"landscapePrimary\",\"angle\":90}" else "{\"type\":\"portraitPrimary\",\"angle\":0}"});
            try s.endObject();
        } else {
            cmd.method = "Emulation.clearDeviceMetricsOverride";
            try w.writeAll("{}");
        },
        .touch => {
            cmd.method = "Emulation.setTouchEmulationEnabled";
            if (t.flags.viewport and t.flags.touch) {
                cmd.set = true;
                try w.writeAll("{\"enabled\":true,\"maxTouchPoints\":5}");
            } else try w.writeAll("{\"enabled\":false}");
        },
        .ua => {
            cmd.method = "Emulation.setUserAgentOverride";
            if (t.flags.ua or t.flags.locale) {
                cmd.set = true;
                try s.beginObject();
                try s.objectField("userAgent");
                try s.write(if (t.flags.ua) t.ua else "");
                if (t.flags.locale) {
                    try s.objectField("acceptLanguage");
                    try s.write(t.accept_language);
                }
                if (t.flags.ua and t.platform.len != 0) {
                    try s.objectField("platform");
                    try s.write(t.platform);
                }
                if (t.flags.ua and t.flags.hints) {
                    const h = t.hints;
                    try s.objectField("userAgentMetadata");
                    try s.beginObject();
                    try s.objectField("brands");
                    try writeBrandList(&s, h.brands[0..h.brand_count]);
                    if (h.full_count > 0) {
                        try s.objectField("fullVersionList");
                        try writeBrandList(&s, h.full_list[0..h.full_count]);
                    }
                    try s.objectField("platform");
                    try s.write(h.platform);
                    try s.objectField("platformVersion");
                    try s.write(h.platform_version);
                    try s.objectField("architecture");
                    try s.write(h.architecture);
                    try s.objectField("model");
                    try s.write(h.model);
                    try s.objectField("mobile");
                    try s.write(h.mobile);
                    if (h.bitness.len != 0) {
                        try s.objectField("bitness");
                        try s.write(h.bitness);
                    }
                    try s.endObject();
                }
                try s.endObject();
            } else try w.writeAll("{\"userAgent\":\"\"}");
        },
        .locale => {
            cmd.method = "Emulation.setLocaleOverride";
            if (t.flags.locale) {
                cmd.set = true;
                try s.beginObject();
                try s.objectField("locale");
                try s.write(t.icu_locale);
                try s.endObject();
            } else try w.writeAll("{}");
        },
        .timezone => {
            cmd.method = "Emulation.setTimezoneOverride";
            if (t.flags.timezone) {
                cmd.set = true;
                try s.beginObject();
                try s.objectField("timezoneId");
                try s.write(t.timezone);
                try s.endObject();
            } else try w.writeAll("{\"timezoneId\":\"\"}");
        },
        .media => {
            cmd.method = "Emulation.setEmulatedMedia";
            // 지움도 네 기능 이름을 다 싣는다 — `{}` 는 forced-colors 를 지우지 않았다(E17).
            const m: msg.EmuMedia = if (t.flags.media) t.media else .{};
            cmd.set = t.flags.media;
            try s.beginObject();
            try s.objectField("media");
            try s.write(mediaTypeName(m.type));
            try s.objectField("features");
            try s.beginArray();
            const names = [_][]const u8{ "prefers-color-scheme", "prefers-reduced-motion", "forced-colors", "prefers-contrast" };
            const values = [_][]const u8{ schemeName(m.color_scheme), motionName(m.reduced_motion), forcedName(m.forced_colors), contrastName(m.contrast) };
            for (names, values) |n, v| {
                try s.beginObject();
                try s.objectField("name");
                try s.write(n);
                try s.objectField("value");
                try s.write(v);
                try s.endObject();
            }
            try s.endArray();
            try s.endObject();
        },
        .vision => {
            cmd.method = "Emulation.setEmulatedVisionDeficiency";
            cmd.set = t.flags.vision;
            try s.beginObject();
            try s.objectField("type");
            try s.write(visionName(if (t.flags.vision) t.vision else .none));
            try s.endObject();
        },
        .geo => {
            cmd.method = "";
            if (t.flags.geo) {
                cmd.set = true;
                cmd.geo = if (t.flags.geo_unavailable) .{ .unavailable = true } else .{ .latitude = t.latitude, .longitude = t.longitude, .accuracy = t.accuracy };
            }
        },
    }
    return w.buffered();
}

// ── 밖→안 홉의 문서 요청 하나에 넣는 머리(사용자 결정 2026-11-12 「그 한 요청만 머리를 직접 넣기」) ─────────────────────

/// client hints 머리 중 흉내 metadata 로 값을 셀 수 있는 것(소문자). 이 밖의 `sec-ch-ua*`(full-version·form-factors 등)는 맞출 값을 모르므로
/// 고쳐 쓸 때 뺀다(그 요청 하나는 그 머리가 없다 — 커밋 뒤 요청부터 Chromium 이 흉내 metadata 로 셈한다).
pub const hint_names = [_][]const u8{
    "sec-ch-ua",
    "sec-ch-ua-mobile",
    "sec-ch-ua-platform",
    "sec-ch-ua-platform-version",
    "sec-ch-ua-arch",
    "sec-ch-ua-model",
    "sec-ch-ua-bitness",
    "sec-ch-ua-full-version-list",
    "sec-ch-ua-wow64",
};

/// 가장 큰 흉내(UA 512·Accept-Language 128 의 q 값·브랜드 넷 둘·글 다섯 — 모두 이스케이프 두 배)를 담는다(시험).
const inject_buf_bytes = 6 * 1024;

/// 그 요청에 넣을 머리. 값은 `buf` 의 자리(`Span`)로 쥔다 — IO 스레드의 표(`emu_inject.zig`)가 구조체를 복사해 가도 맞게. `Accept-Language` 는
/// 넣어도 CEF 154 가 그 요청을 진짜 값으로 냈다(실측 — 그 한 요청의 언어는 늦다, `emu_inject.zig`).
pub const Inject = struct {
    const Span = struct { off: u16 = 0, len: u16 = 0 };
    pub const Hints = enum(u8) {
        /// 건드리지 않는다(UA 흉내가 없다 — 언어만이면 기본 UA·client hints 그대로: E7).
        keep,
        /// 모두 뺀다(UA 흉내에 metadata 가 없다 — Chromium 도 그 흉내 아래에서는 client hints 를 보내지 않았다: `emu-ua-none-safari`).
        drop,
        /// 요청에 있는 것만 흉내 metadata 의 값으로(낮은 엔트로피 셋은 믿을 만한 출처에만, 높은 것은 그 사이트가 Accept-CH 로 청했을 때만 실린다 —
        /// 없는 머리를 더하지 않는다), 셀 수 없는 것은 뺀다.
        rewrite,
    };
    pub const Action = union(enum) { keep, drop, set: []const u8 };

    ua: ?Span = null,
    accept_language: ?Span = null,
    hints: Hints = .keep,
    /// `hints == .rewrite` 일 때 `hint_names` 마다의 값(null = 뺀다).
    hint_values: [hint_names.len]?Span = @splat(null),
    buf: [inject_buf_bytes]u8 = undefined,
    used: usize = 0,

    fn text(self: *const Inject, s: Span) []const u8 {
        return self.buf[s.off..][0..s.len];
    }

    pub fn userAgent(self: *const Inject) ?[]const u8 {
        return if (self.ua) |s| self.text(s) else null;
    }

    pub fn acceptLanguage(self: *const Inject) ?[]const u8 {
        return if (self.accept_language) |s| self.text(s) else null;
    }

    /// 요청에 있는 머리 하나를 어떻게 하나(이름은 대소문자 무시). `User-Agent`·`Accept-Language` 는 요청에 없어도 부른 쪽이 더한다(`userAgent`·
    /// `acceptLanguage`).
    pub fn action(self: *const Inject, name: []const u8) Action {
        if (std.ascii.eqlIgnoreCase(name, "user-agent")) return if (self.userAgent()) |v| .{ .set = v } else .keep;
        if (std.ascii.eqlIgnoreCase(name, "accept-language")) return if (self.acceptLanguage()) |v| .{ .set = v } else .keep;
        if (name.len < 9 or !std.ascii.eqlIgnoreCase(name[0..9], "sec-ch-ua")) return .keep;
        switch (self.hints) {
            .keep => return .keep,
            .drop => return .drop,
            .rewrite => {
                for (hint_names, self.hint_values) |n, v| if (std.ascii.eqlIgnoreCase(name, n)) return if (v) |s| .{ .set = self.text(s) } else .drop;
                return .drop;
            },
        }
    }

    fn put(self: *Inject, comptime f: anytype, args: anytype) !Span {
        var w: Writer = .fixed(self.buf[self.used..]);
        try f(&w, args);
        const n = w.buffered().len;
        const s: Span = .{ .off = @intCast(self.used), .len = @intCast(n) };
        self.used += n;
        return s;
    }

    /// 흉내 상태에서 — Chromium 이 커밋 뒤 탭 전체의 `setUserAgentOverride` 로 낼 머리와 같은 꼴(판정 `emu-site-bound-slow-hop` 이 커밋 뒤
    /// 요청의 머리와 견준다).
    pub fn build(w: msg.Emulation) !Inject {
        var out: Inject = .{};
        if (w.flags.ua) out.ua = try out.put(writeRaw, w.ua);
        if (w.flags.locale) out.accept_language = try out.put(writeAcceptLanguage, w.accept_language);
        if (w.flags.ua) {
            if (!w.flags.hints) {
                out.hints = .drop;
            } else {
                out.hints = .rewrite;
                const h = w.hints;
                out.hint_values[0] = try out.put(writeBrandHeader, h.brands[0..h.brand_count]);
                out.hint_values[1] = try out.put(writeRaw, if (h.mobile) "?1" else "?0");
                out.hint_values[2] = try out.put(writeSfString, h.platform);
                out.hint_values[3] = try out.put(writeSfString, h.platform_version);
                out.hint_values[4] = try out.put(writeSfString, h.architecture);
                out.hint_values[5] = try out.put(writeSfString, h.model);
                out.hint_values[6] = try out.put(writeSfString, h.bitness);
                // 전체 목록을 주지 않은 흉내면 Chromium 이 무엇을 셀지 재지 않았다 — 뺀다.
                if (h.full_count > 0) out.hint_values[7] = try out.put(writeBrandHeader, h.full_list[0..h.full_count]);
                out.hint_values[8] = try out.put(writeRaw, "?0"); // metadata 의 wow64 를 보내지 않는다 — 거짓
            }
        }
        return out;
    }
};

fn writeRaw(w: *Writer, v: []const u8) !void {
    try w.writeAll(v);
}

/// Chromium 이 `setUserAgentOverride` 의 `acceptLanguage` 목록에 붙이는 q 값과 같은 꼴(`fr-FR,fr` → `fr-FR,fr;q=0.9` — 실측 E7·이 판정의
/// 커밋 뒤 요청): 첫째는 q 없이, 다음부터 0.9 에서 0.1 씩 내려 0.1 에서 멈춘다, 빈 항목은 건너뛴다.
fn writeAcceptLanguage(w: *Writer, list: []const u8) !void {
    var q: u8 = 10;
    var it = std.mem.tokenizeScalar(u8, list, ',');
    while (it.next()) |lang| {
        if (q == 10) try w.writeAll(lang) else try w.print(",{s};q=0.{d}", .{ lang, q });
        if (q > 1) q -= 1;
    }
}

/// 구조화 머리(RFC 8941)의 문자열 — `"` 와 `\` 만 이스케이프(글은 인쇄 가능한 ASCII 로 검사를 지났다 — `emu_fields.printable`).
fn writeSfString(w: *Writer, v: []const u8) !void {
    try w.writeByte('"');
    for (v) |ch| {
        if (ch == '"' or ch == '\\') try w.writeByte('\\');
        try w.writeByte(ch);
    }
    try w.writeByte('"');
}

/// `Sec-CH-UA`·`Sec-CH-UA-Full-Version-List` — `"브랜드";v="버전"` 을 `, ` 로 잇는다(버전이 비면 `;v=` 없이).
fn writeBrandHeader(w: *Writer, list: []const msg.EmuBrand) !void {
    for (list, 0..) |b, i| {
        if (i > 0) try w.writeAll(", ");
        try writeSfString(w, b.brand);
        if (b.version.len != 0) {
            try w.writeAll(";v=");
            try writeSfString(w, b.version);
        }
    }
}

// ── 시험 ────────────────────────────────────────────────────────────────────────────────────────────────

const testing = std.testing;
const array_repeat = @import("array_repeat");

fn phone() msg.Emulation {
    return .{ .browser = 1, .generation = 1, .flags = .{ .viewport = true, .mobile = true, .touch = true }, .width = 390, .height = 844, .dsf = 3 };
}

fn kinds(c: *const Cmds) [kind_count]?bool {
    var out: [kind_count]?bool = @splat(null);
    for (c.slice()) |x| out[@backingInt(x.kind)] = x.set;
    return out;
}

fn find(c: *const Cmds, kind: Kind) ?Cmd {
    for (c.slice()) |x| if (x.kind == kind) return x;
    return null;
}

test "W9e①: 바뀐 것만 명령 — 화면·터치를 걸고, 같은 상태는 다시 보내지 않고, 시간대만 더하면 시간대만, 무리를 빼면 그 지움만" {
    var t: Tab = .{ .pane_w = 640, .pane_h = 400 };
    try t.setWant(phone());
    var c: Cmds = .{};
    t.plan(&c);
    try testing.expectEqual(@as(usize, 2), c.len);
    const m = find(&c, .metrics).?;
    try testing.expect(m.set);
    try testing.expectEqualStrings("Emulation.setDeviceMetricsOverride", m.method);
    try testing.expectEqualStrings("{\"width\":390,\"height\":844,\"deviceScaleFactor\":3,\"mobile\":true,\"scale\":0.4739,\"screenOrientation\":{\"type\":\"portraitPrimary\",\"angle\":0}}", m.params);
    try testing.expectEqualStrings("{\"enabled\":true,\"maxTouchPoints\":5}", find(&c, .touch).?.params);
    t.plan(&c);
    try testing.expectEqual(@as(usize, 0), c.len); // 같은 상태
    var v = phone();
    v.generation = 2;
    v.flags.timezone = true;
    v.timezone = "Asia/Kolkata";
    try t.setWant(v);
    t.plan(&c);
    try testing.expectEqual(@as(usize, 1), c.len);
    try testing.expectEqualStrings("{\"timezoneId\":\"Asia/Kolkata\"}", find(&c, .timezone).?.params);
    v.flags.touch = false;
    try t.setWant(v);
    t.plan(&c);
    try testing.expectEqual(@as(usize, 1), c.len);
    try testing.expectEqualStrings("{\"enabled\":false}", find(&c, .touch).?.params);
}

test "W9e①: 지움 꼴 — 미디어는 네 이름을 빈 값으로(E17), UA 는 \"\", 시간대 \"\", 언어 {}, 색각 none, 화면은 clear" {
    var t: Tab = .{ .pane_w = 2000, .pane_h = 2000 };
    var v = phone();
    v.flags.ua = true;
    v.ua = "UA/1";
    v.flags.locale = true;
    v.accept_language = "fr-FR,fr";
    v.icu_locale = "fr_FR";
    v.flags.timezone = true;
    v.timezone = "UTC";
    v.flags.media = true;
    v.media = .{ .forced_colors = .active };
    v.flags.vision = true;
    v.vision = .achromatopsia;
    try t.setWant(v);
    var c: Cmds = .{};
    t.plan(&c);
    try testing.expectEqual(@as(usize, 7), c.len);
    try testing.expectEqualStrings("{\"userAgent\":\"UA/1\",\"acceptLanguage\":\"fr-FR,fr\"}", find(&c, .ua).?.params);
    try testing.expectEqualStrings("{\"locale\":\"fr_FR\"}", find(&c, .locale).?.params);
    try testing.expectEqualStrings("{\"media\":\"\",\"features\":[{\"name\":\"prefers-color-scheme\",\"value\":\"\"},{\"name\":\"prefers-reduced-motion\",\"value\":\"\"},{\"name\":\"forced-colors\",\"value\":\"active\"},{\"name\":\"prefers-contrast\",\"value\":\"\"}]}", find(&c, .media).?.params);
    try testing.expectEqualStrings("{\"type\":\"achromatopsia\"}", find(&c, .vision).?.params);
    try testing.expect(std.mem.indexOf(u8, find(&c, .metrics).?.params, "\"scale\":1.0000") != null); // pane 이 크면 1
    try t.setWant(.{ .browser = 1, .generation = 2 }); // 모두 지움
    t.plan(&c);
    try testing.expectEqual(@as(usize, 7), c.len);
    for (c.slice()) |x| try testing.expect(!x.set);
    try testing.expectEqualStrings("{}", find(&c, .metrics).?.params);
    try testing.expectEqualStrings("Emulation.clearDeviceMetricsOverride", find(&c, .metrics).?.method);
    try testing.expectEqualStrings("{\"userAgent\":\"\"}", find(&c, .ua).?.params);
    try testing.expectEqualStrings("{}", find(&c, .locale).?.params);
    try testing.expectEqualStrings("{\"timezoneId\":\"\"}", find(&c, .timezone).?.params);
    try testing.expectEqualStrings("{\"media\":\"\",\"features\":[{\"name\":\"prefers-color-scheme\",\"value\":\"\"},{\"name\":\"prefers-reduced-motion\",\"value\":\"\"},{\"name\":\"forced-colors\",\"value\":\"\"},{\"name\":\"prefers-contrast\",\"value\":\"\"}]}", find(&c, .media).?.params);
    try testing.expectEqualStrings("{\"type\":\"none\"}", find(&c, .vision).?.params);
    try testing.expectEqualStrings("{\"enabled\":false}", find(&c, .touch).?.params);
    t.plan(&c);
    try testing.expectEqual(@as(usize, 0), c.len); // 처음 상태로 돌아왔다
}

test "W9e①: 언어만이면 UA 를 건드리지 않고 Accept-Language 만(E7) — 무리는 언어, UA 를 더하면 한 호출에 둘, client hints 와 platform" {
    var t: Tab = .{};
    try t.setWant(.{ .browser = 1, .generation = 1, .flags = .{ .locale = true }, .accept_language = "fr-FR,fr", .icu_locale = "fr_FR" });
    var c: Cmds = .{};
    t.plan(&c);
    try testing.expectEqualStrings("{\"userAgent\":\"\",\"acceptLanguage\":\"fr-FR,fr\"}", find(&c, .ua).?.params);
    t.answered(.ua, true, "");
    t.answered(.locale, true, "");
    const st = t.state(1);
    try testing.expectEqual(@as(u16, 1 << @backingInt(msg.EmuGroup.locale)), st.active_mask);
    var v: msg.Emulation = .{ .browser = 1, .generation = 2, .flags = .{ .locale = true, .ua = true, .hints = true }, .accept_language = "fr-FR,fr", .icu_locale = "fr_FR", .ua = "Mozilla/5.0 \"x\" Chrome/154.0.0.0", .platform = "Linux armv8l" };
    v.hints.brand_count = 1;
    v.hints.brands[0] = .{ .brand = "Chromium", .version = "154" };
    v.hints.platform = "Android";
    v.hints.mobile = true;
    try t.setWant(v);
    t.plan(&c);
    try testing.expectEqual(@as(usize, 1), c.len); // 언어(Intl)는 그대로 — UA 호출만
    try testing.expectEqualStrings("{\"userAgent\":\"Mozilla/5.0 \\\"x\\\" Chrome/154.0.0.0\",\"acceptLanguage\":\"fr-FR,fr\",\"platform\":\"Linux armv8l\",\"userAgentMetadata\":{\"brands\":[{\"brand\":\"Chromium\",\"version\":\"154\"}],\"platform\":\"Android\",\"platformVersion\":\"\",\"architecture\":\"\",\"model\":\"\",\"mobile\":true}}", find(&c, .ua).?.params);
    t.answered(.ua, true, "");
    try testing.expect(t.state(1).active_mask & (1 << @backingInt(msg.EmuGroup.user_agent)) != 0);
}

test "W9e①: 렌더러가 죽은 동안은 빈 열 — 화면·시간대를 바꿔도 보내지 않고, 되살아나면 쌓인 차이만(E11·E4)" {
    var t: Tab = .{ .pane_w = 640, .pane_h = 400 };
    try t.setWant(phone());
    var c: Cmds = .{};
    t.plan(&c);
    t.answered(.metrics, true, "");
    t.answered(.touch, true, "");
    t.rendererGone();
    var v = phone();
    v.generation = 2;
    v.width = 412;
    v.flags.timezone = true;
    v.timezone = "UTC";
    try t.setWant(v);
    t.plan(&c);
    try testing.expectEqual(@as(usize, 0), c.len); // 죽은 탭에 metrics 를 보내지 않는다
    try testing.expect(t.held());
    try testing.expect(t.state(1).pending and !t.state(1).alive);
    try testing.expect(t.resize(800, 500) or true); // 죽은 동안의 resize 도 보내지 않는다
    t.plan(&c);
    try testing.expectEqual(@as(usize, 0), c.len);
    try testing.expect(t.rendererBack());
    try testing.expect(!t.rendererBack());
    t.plan(&c);
    try testing.expectEqual(@as(usize, 2), c.len); // 화면(폭·fit 바뀜)·시간대 — 터치는 그대로라 보내지 않는다
    try testing.expect(find(&c, .metrics) != null and find(&c, .timezone) != null and find(&c, .touch) == null);
}

test "W9e①: 답을 받기 전에 DevTools 가 떨어지면 그 종류는 모른다 — 되살아난 뒤 다시 보낸다" {
    var t: Tab = .{ .pane_w = 640, .pane_h = 400 };
    try t.setWant(phone());
    var c: Cmds = .{};
    t.plan(&c);
    t.answered(.touch, true, "");
    t.rendererGone(); // metrics 의 답이 오지 않았다
    try testing.expect(t.rendererBack());
    t.plan(&c);
    try testing.expectEqual(@as(usize, 1), c.len);
    try testing.expect(find(&c, .metrics).?.set);
}

test "W9e①: 사이트에 묶인 탭 — 사이트 밖이면 모두 지우고(위치도) 돌아오면 다시, 하위 도메인은 안, 호스트 모름은 밖" {
    var t: Tab = .{};
    try t.setWant(.{ .browser = 1, .generation = 1, .flags = .{ .site_bound = true, .timezone = true, .geo = true }, .site = "a.test", .timezone = "UTC", .latitude = 1, .longitude = 2, .accuracy = 3 });
    try testing.expect(!t.navigate("www.a.test")); // 안 → 안
    var c: Cmds = .{};
    t.plan(&c);
    try testing.expectEqual(@as(usize, 2), c.len);
    try testing.expectEqual(@as(f64, 2), find(&c, .geo).?.geo.longitude);
    var again: Cmds = .{};
    t.plan(&again);
    try testing.expectEqual(@as(usize, 0), again.len); // 같은 위치를 다시 보내지 않는다(해시가 값의 바이트로)
    t.answered(.timezone, true, "");
    try testing.expect(t.navigate("bank.test"));
    t.plan(&c);
    try testing.expectEqual(@as(usize, 2), c.len);
    try testing.expect(!find(&c, .timezone).?.set and !find(&c, .geo).?.set);
    try testing.expect(!t.state(1).on_site);
    try testing.expectEqual(@as(u16, 0), t.state(1).active_mask);
    try testing.expect(!t.navigate(null)); // about:blank — 여전히 밖
    t.plan(&c);
    try testing.expectEqual(@as(usize, 0), c.len); // 같은 상태 — 위치도 다시 보내지 않는다
    try testing.expect(t.navigate("a.test"));
    t.plan(&c);
    try testing.expectEqual(@as(usize, 2), c.len);
    try testing.expect(find(&c, .timezone).?.set);
    // 묶이지 않은 탭(에이전트 탭)은 어디서든 안이다.
    var agent: Tab = .{};
    try agent.setWant(.{ .browser = 2, .generation = 1, .flags = .{ .timezone = true }, .timezone = "UTC" });
    try testing.expect(!agent.navigate("bank.test") and agent.on_site);
}

test "W9e①: 밖의 문서에서 사이트 안으로 가는 홉은 커밋까지 탭 전체에 아무것도 걸지 않는다 — 상태는 밖·기다림 없음, 그 홉의 문서 요청에만 머리, 커밋이 모두 건다, 끊김·안→밖은 머리를 거둔다" {
    var t: Tab = .{ .pane_w = 640, .pane_h = 400 };
    var v = phone();
    v.flags.site_bound = true;
    v.site = "a.test";
    v.flags.ua = true;
    v.ua = "UA/1";
    v.flags.timezone = true;
    v.timezone = "UTC";
    try t.setWant(v);
    try testing.expect(t.navigate("bank.test")); // 밖의 문서
    var c: Cmds = .{};
    t.plan(&c);
    try testing.expectEqual(@as(usize, 0), c.len);
    var inj: Inject = .{};
    try testing.expect(!t.injection(&inj)); // 밖의 문서 — 넣지 않는다
    // 밖 → 안 홉: 탭 전체에는 아무것도(UA 호출도 — 옛 문서의 iframe·Worker 요청이 흉내 UA 를 실었다: 집중 검증 1 회차), 상태는 밖이고 기다리는
    // 답이 없다(옮긴 판 검증 L1 — 전에는 UA 의 답이 커밋 뒤에 와 기다림 내내 pending 이었다). 그 홉의 문서 요청에만 흉내 머리.
    try testing.expect(t.hop("www.a.test", "bank.test"));
    try testing.expect(t.hold);
    t.plan(&c);
    try testing.expectEqual(@as(usize, 0), c.len);
    const mid = t.state(1);
    try testing.expect(!mid.on_site and mid.fit_scale == 1 and mid.active_mask == 0 and !mid.pending);
    try testing.expect(t.injection(&inj));
    try testing.expectEqualStrings("UA/1", inj.userAgent().?);
    try testing.expect(inj.acceptLanguage() == null);
    try testing.expect(!t.hop("a.test", "bank.test")); // 안 → 안 리다이렉트 — 그대로 기다리고 그 홉에도 넣는다
    try testing.expect(t.injection(&inj));
    try testing.expect(!t.resize(320, 200)); // 기다리는 동안 화면 흉내는 없다
    _ = t.resize(640, 400);
    // 커밋: 모두 건다(UA 도 — 새 문서의 첫 스크립트가 본다), 머리 넣기는 끝.
    try testing.expect(t.navigate("a.test"));
    try testing.expect(!t.hold and !t.injection(&inj));
    t.plan(&c);
    try testing.expectEqual(@as(usize, 4), c.len);
    try testing.expect(find(&c, .metrics).?.set and find(&c, .touch).?.set and find(&c, .ua).?.set and find(&c, .timezone).?.set);
    try testing.expect(t.state(1).on_site);
    // 안의 문서에서 안으로 가는 홉은 기다리지 않는다(이미 걸려 있다), 밖으로 가는 홉은 곧 모두 지운다.
    try testing.expect(!t.hop("a.test", "a.test"));
    try testing.expect(!t.injection(&inj));
    try testing.expect(t.hop("bank.test", "a.test"));
    try testing.expect(!t.hold);
    t.plan(&c);
    try testing.expectEqual(@as(usize, 4), c.len);
    for (c.slice()) |x| try testing.expect(!x.set);
    // 안의 문서 → 밖(리다이렉트) → 다시 안: 보이는 문서가 안이라 곧 모두(머리는 넣지 않는다 — 탭 전체가 이미 싣는다).
    try testing.expect(t.hop("a.test", "a.test"));
    try testing.expect(!t.hold and !t.injection(&inj));
    t.plan(&c);
    try testing.expectEqual(@as(usize, 4), c.len);
    // 끊긴 홉(204·다운로드): 밖의 문서에서 안으로 — 아무것도 걸지 않았으니 지울 것도 없고, 머리 넣기가 끝난다.
    try testing.expect(t.hop("bank.test", "a.test"));
    t.plan(&c);
    try testing.expect(t.navigate("bank.test") == false); // 커밋된 밖의 문서 — 이미 밖
    try testing.expect(t.hop("a.test", "bank.test") and t.hold);
    t.plan(&c);
    try testing.expectEqual(@as(usize, 0), c.len);
    try testing.expect(t.navigate("bank.test")); // 끊김 — 옛 문서(밖)
    try testing.expect(!t.hold and !t.on_site and !t.injection(&inj));
    t.plan(&c);
    try testing.expectEqual(@as(usize, 0), c.len);
    // 밖 → 안(302) → 밖: 밖으로 가는 홉에는 넣지 않는다.
    try testing.expect(t.hop("a.test", "bank.test") and t.injection(&inj));
    try testing.expect(t.hop("bank.test", "bank.test"));
    try testing.expect(!t.hold and !t.injection(&inj));
    // 보이는 문서를 모르면(about:blank 등) 밖과 같이 기다린다; 묶이지 않은 탭은 기다리지 않는다.
    try testing.expect(t.hop("a.test", null) and t.hold);
    var agent: Tab = .{};
    try agent.setWant(.{ .browser = 2, .generation = 1, .flags = .{ .timezone = true }, .timezone = "UTC" });
    try testing.expect(!agent.hop("a.test", "bank.test") and !agent.hold and !agent.injection(&inj));
}

test "W9e①: 머리 넣기 — 기다리는 동안 지움·철회·다른 사이트·UA 없는 흉내는 넣지 않는다, 언어만이면 UA·client hints 를 그대로, metadata 없는 UA 는 client hints 를 뺀다" {
    var t: Tab = .{};
    var v: msg.Emulation = .{ .browser = 1, .generation = 1, .flags = .{ .site_bound = true, .ua = true, .locale = true }, .site = "a.test", .ua = "UA/1", .accept_language = "fr-FR,fr", .icu_locale = "fr_FR" };
    try t.setWant(v);
    _ = t.navigate("bank.test");
    try testing.expect(t.hop("a.test", "bank.test"));
    var inj: Inject = .{};
    try testing.expect(t.injection(&inj));
    try testing.expectEqualStrings("UA/1", inj.action("User-Agent").set);
    try testing.expectEqualStrings("fr-FR,fr;q=0.9", inj.action("accept-language").set);
    // metadata 없는 UA — Chromium 도 그 흉내 아래에서는 client hints 를 보내지 않는다(`emu-ua-none-safari`): 모두 뺀다.
    try testing.expect(inj.action("Sec-CH-UA") == .drop and inj.action("sec-ch-ua-platform") == .drop and inj.action("Sec-CH-UA-Mobile") == .drop and inj.action("sec-ch-ua-form-factors") == .drop);
    try testing.expect(inj.action("Accept") == .keep and inj.action("Cookie") == .keep and inj.action("sec-ch-u") == .keep and inj.action("Sec-Fetch-Mode") == .keep);
    // 언어만: UA 와 client hints 는 그대로(E7 — 빈 userAgent + acceptLanguage 와 같다).
    v.generation = 2;
    v.flags.ua = false;
    v.ua = "";
    try t.setWant(v);
    try testing.expect(t.injection(&inj));
    try testing.expect(inj.action("User-Agent") == .keep and inj.action("Sec-CH-UA") == .keep and inj.userAgent() == null);
    try testing.expectEqualStrings("fr-FR,fr;q=0.9", inj.acceptLanguage().?);
    // UA·언어가 없는 흉내(화면만) — 넣을 머리가 없다.
    try t.setWant(.{ .browser = 1, .generation = 3, .flags = .{ .site_bound = true, .timezone = true }, .site = "a.test", .timezone = "UTC" });
    try testing.expect(!t.injection(&inj));
    // 기다리는 동안 지움(철회와 같은 빈 frame) — 부른 쪽이 `hop` 을 다시 돌린다: 묶이지 않아 기다리지 않고 넣지 않는다.
    try t.setWant(v);
    try testing.expect(t.injection(&inj));
    try t.setWant(.{ .browser = 1, .generation = 4 });
    _ = t.hop("a.test", "bank.test");
    try testing.expect(!t.hold and !t.injection(&inj));
    // 기다리는 동안 다른 사이트로 바뀐 grant — 그 홉은 이제 밖이다.
    var other = v;
    other.generation = 5;
    other.site = "c.test";
    try t.setWant(other);
    _ = t.hop("a.test", "bank.test");
    try testing.expect(!t.hold and !t.on_site and !t.injection(&inj));
}

test "W9e①: 머리 넣기의 값 — client hints 는 흉내 metadata 의 구조화 머리(이스케이프·빈 버전), 요청에 있는 것만 고치고 셀 수 없는 것은 뺀다, Accept-Language 의 q 값, 가장 큰 흉내도 담는다" {
    var v: msg.Emulation = .{ .browser = 1, .generation = 1, .flags = .{ .site_bound = true, .ua = true, .hints = true }, .site = "a.test", .ua = "Mozilla/5.0 Android" };
    v.hints.brand_count = 3;
    v.hints.brands[0] = .{ .brand = "Chromium", .version = "154" };
    v.hints.brands[1] = .{ .brand = "Not A(Brand", .version = "99" };
    v.hints.brands[2] = .{ .brand = "a\"b\\c", .version = "" };
    v.hints.platform = "Android";
    v.hints.platform_version = "14.0.0";
    v.hints.model = "Pixel 8";
    v.hints.mobile = true;
    var inj = try Inject.build(v);
    try testing.expectEqualStrings("\"Chromium\";v=\"154\", \"Not A(Brand\";v=\"99\", \"a\\\"b\\\\c\"", inj.action("sec-ch-ua").set);
    try testing.expectEqualStrings("?1", inj.action("Sec-CH-UA-Mobile").set);
    try testing.expectEqualStrings("\"Android\"", inj.action("Sec-CH-UA-Platform").set);
    try testing.expectEqualStrings("\"14.0.0\"", inj.action("sec-ch-ua-platform-version").set);
    try testing.expectEqualStrings("\"Pixel 8\"", inj.action("sec-ch-ua-model").set);
    try testing.expectEqualStrings("\"\"", inj.action("sec-ch-ua-arch").set);
    try testing.expectEqualStrings("?0", inj.action("sec-ch-ua-wow64").set);
    try testing.expect(inj.action("sec-ch-ua-full-version-list") == .drop); // 전체 목록을 주지 않았다 — Chromium 의 값을 모른다
    try testing.expect(inj.action("sec-ch-ua-full-version") == .drop and inj.action("sec-ch-ua-form-factors") == .drop);
    try testing.expect(inj.acceptLanguage() == null and inj.action("Accept-Language") == .keep);
    v.hints.full_count = 1;
    v.hints.full_list[0] = .{ .brand = "Chromium", .version = "154.0.1.2" };
    v.hints.mobile = false;
    inj = try Inject.build(v);
    try testing.expectEqualStrings("\"Chromium\";v=\"154.0.1.2\"", inj.action("Sec-CH-UA-Full-Version-List").set);
    try testing.expectEqualStrings("?0", inj.action("sec-ch-ua-mobile").set);
    // 구조체를 복사해도 값이 맞다(IO 스레드의 표가 복사해 간다 — 값을 자리로 쥔다).
    const copy = inj;
    try testing.expectEqualStrings("Mozilla/5.0 Android", copy.userAgent().?);
    // q 값: 0.1 씩 내려 0.1 에서 멈춘다, 빈 항목은 건너뛴다.
    var al: msg.Emulation = .{ .browser = 1, .flags = .{ .locale = true }, .accept_language = "a,,b,c,d,e,f,g,h,i,j,k,l", .icu_locale = "a" };
    inj = try Inject.build(al);
    try testing.expectEqualStrings("a,b;q=0.9,c;q=0.8,d;q=0.7,e;q=0.6,f;q=0.5,g;q=0.4,h;q=0.3,i;q=0.2,j;q=0.1,k;q=0.1,l;q=0.1", inj.acceptLanguage().?);
    al.accept_language = "fr";
    inj = try Inject.build(al);
    try testing.expectEqualStrings("fr", inj.acceptLanguage().?);
    // 가장 큰 흉내 — UA 512, 언어 128(항목 64 개), 브랜드 넷 둘·글 다섯 모두 이스케이프 두 배.
    const hint = array_repeat.repeat("\"", 64);
    var big: msg.Emulation = .{ .browser = 1, .flags = .{ .ua = true, .hints = true, .locale = true }, .ua = array_repeat.repeat("u", 512), .accept_language = "a" ++ array_repeat.repeat(",a", 63) ++ "a", .icu_locale = "a" };
    big.hints = .{ .brand_count = 4, .full_count = 4, .platform = hint, .platform_version = hint, .architecture = hint, .model = hint, .bitness = hint, .mobile = true };
    for (0..4) |i| {
        big.hints.brands[i] = .{ .brand = hint, .version = hint };
        big.hints.full_list[i] = .{ .brand = hint, .version = hint };
    }
    inj = try Inject.build(big);
    try testing.expect(inj.action("sec-ch-ua-full-version-list").set.len > 4 * 2 * 128);
    try testing.expect(inj.acceptLanguage().?.len > 128);
}

test "W9e①: fit — pane 보다 작으면 1, 크면 줄이고 만분의 일로 내린다, pane 크기가 바뀌면 다시 보낸다(E2), 크기를 모르면 1" {
    try testing.expectEqual(@as(f32, 1), fitScale(1280, 900, 390, 844));
    try testing.expectEqual(@as(f32, 0.4739), fitScale(640, 400, 390, 844));
    try testing.expectEqual(@as(f32, 0.5), fitScale(640, 400, 1280, 800));
    try testing.expectEqual(@as(f32, 1), fitScale(0, 0, 390, 844));
    var t: Tab = .{ .pane_w = 640, .pane_h = 400 };
    try t.setWant(phone());
    var c: Cmds = .{};
    t.plan(&c);
    try testing.expect(!t.resize(640, 400));
    try testing.expect(t.resize(800, 500));
    t.plan(&c);
    try testing.expectEqual(@as(usize, 1), c.len);
    try testing.expect(std.mem.indexOf(u8, find(&c, .metrics).?.params, "\"scale\":0.5924") != null);
    try testing.expectEqual(@as(f32, 0.5924), t.fit);
    var none: Tab = .{};
    try testing.expect(!none.resize(1, 1)); // 흉내 화면이 없으면 다시 셈할 것이 없다
}

test "W9e①: 답의 마스크와 까닭 — 시간대를 모르면 timezone_unknown, 「already in effect」 는 process_shared_conflict(E13), 그 밖은 cdp_error, 새 세대는 실패를 지운다" {
    var t: Tab = .{};
    try t.setWant(.{ .browser = 1, .generation = 1, .flags = .{ .timezone = true, .locale = true }, .timezone = "Mars/Base", .accept_language = "fr", .icu_locale = "fr" });
    var c: Cmds = .{};
    t.plan(&c);
    try testing.expect(t.state(1).pending);
    t.answered(.timezone, false, "{\"code\":-32000,\"message\":\"Invalid timezone id\"}");
    t.answered(.ua, true, "");
    t.answered(.locale, false, "{\"code\":-32000,\"message\":\"Another locale override is already in effect\"}");
    var st = t.state(1);
    try testing.expect(!st.pending);
    try testing.expectEqual(@as(u16, (1 << @backingInt(msg.EmuGroup.timezone)) | (1 << @backingInt(msg.EmuGroup.locale))), st.failed_mask);
    try testing.expectEqual(msg.EmuFailReason.timezone_unknown, st.reason); // 첫 까닭
    try testing.expectEqual(@as(u16, 0), st.active_mask & (1 << @backingInt(msg.EmuGroup.locale))); // 언어 무리의 한쪽이 실패면 실패
    try emu_fields.checkState(st);
    t.newGeneration();
    t.plan(&c);
    try testing.expectEqual(@as(usize, 2), c.len); // 실패한 둘을 한 번 더
    t.answered(.timezone, false, "{\"message\":\"boom\"}");
    st = t.state(1);
    try testing.expectEqual(msg.EmuFailReason.cdp_error, st.reason);
    t.sendFailed(.locale);
    try emu_fields.checkState(t.state(1));
}

test "W9e①: 가장 큰 인자(UA 512·client hints 상한)도 명령 버퍼에 들고, 번호 대역은 다른 사용처와 겹치지 않는다" {
    const hint = array_repeat.repeat("x", 64);
    var v: msg.Emulation = .{ .browser = 1, .generation = 1, .flags = .{ .ua = true, .hints = true, .locale = true, .viewport = true, .touch = true, .landscape = true, .timezone = true, .media = true, .vision = true, .geo = true }, .ua = array_repeat.repeat("\"", 512), .platform = array_repeat.repeat("p", 64), .accept_language = array_repeat.repeat("a", 128), .icu_locale = array_repeat.repeat("i", 40), .timezone = array_repeat.repeat("t", 64), .width = 1, .height = 1, .dsf = 1, .media = .{ .type = .print, .color_scheme = .dark, .reduced_motion = .no_preference, .forced_colors = .off, .contrast = .no_preference }, .vision = .tritanopia, .latitude = 1 };
    v.hints = .{ .brand_count = 4, .full_count = 4, .platform = hint, .platform_version = hint, .architecture = hint, .model = hint, .bitness = hint, .mobile = true };
    for (0..4) |i| {
        v.hints.brands[i] = .{ .brand = array_repeat.repeat("\\", 64), .version = hint };
        v.hints.full_list[i] = .{ .brand = hint, .version = hint };
    }
    var t: Tab = .{};
    try t.setWant(v);
    var c: Cmds = .{};
    t.plan(&c);
    try testing.expectEqual(@as(usize, kind_count), c.len); // 아무것도 버퍼 때문에 빠지지 않았다
    try testing.expect(std.mem.indexOf(u8, find(&c, .metrics).?.params, "landscapePrimary") != null);
    try testing.expect(id_base > 0 and id_end <= (1 << 27)); // 엄격 [1<<27, ..)·본문 [1<<28, ..)·DevTools [1<<29, ..)·미디어 [1<<30, ..) 아래
    try testing.expect(id_base > 1_000_000); // 권한·알림의 작은 번호(+1 씩)와도
}

// ── W9e① 변이 시험(변이 캠페인이 찾은 빈틈) ──
// 시험이 증명하는 것: 위치는 경도·정확도만 바뀌어도, 좌표 (0,0,0) 과 「없음」 사이를 오가도 다시 건다(해시가 값의 칸마다), 지운 종류는 답을
// 기다리지 않고(지움은 답을 쫓지 않는다 — 기다리면 상태를 영영 보내지 않는다) 위치는 걸자마자 걸림이다, 지운 뒤 늦게 온 옛 답은 버린다,
// 「already in effect」 하나만이면 까닭은 process_shared_conflict, 살아 있는 탭은 쌓인 것이 없다(DevTools 가 떨어져도 pending 이 아니다),
// 보내지 못한 지움도 실패로 보인다, 죽은 동안 바꾼 화면의 줄임은 새 크기로 셈한다.
test "W9e① 변이: 위치 해시는 값의 칸마다·지움은 기다리지 않는다·늦은 옛 답·까닭 하나·살아 있는 탭·보내지 못한 지움·죽은 동안의 줄임" {
    // 위치 — 경도만·정확도만 바꿔도 다시 건다(EP06), 좌표 (0,0,0) ↔ 「없음」 도(EP07).
    var t: Tab = .{};
    var v: msg.Emulation = .{ .browser = 1, .generation = 1, .flags = .{ .geo = true }, .latitude = 1, .longitude = 2, .accuracy = 3 };
    try t.setWant(v);
    var c: Cmds = .{};
    t.plan(&c);
    try testing.expectEqual(@as(usize, 1), c.len);
    // 위치는 답을 기다리지 않는다 — 곧 걸림(EP10).
    try testing.expect(!t.waiting());
    var st = t.state(1);
    try testing.expect(!st.pending);
    try testing.expectEqual(@as(u16, 1 << @backingInt(msg.EmuGroup.geolocation)), st.active_mask);
    v.generation = 2;
    v.longitude = 5;
    try t.setWant(v);
    t.plan(&c);
    try testing.expectEqual(@as(usize, 1), c.len);
    try testing.expectEqual(@as(f64, 5), find(&c, .geo).?.geo.longitude);
    v.generation = 3;
    v.accuracy = 9;
    try t.setWant(v);
    t.plan(&c);
    try testing.expectEqual(@as(usize, 1), c.len);
    v = .{ .browser = 1, .generation = 4, .flags = .{ .geo = true } }; // 좌표 (0,0,0)
    try t.setWant(v);
    t.plan(&c);
    try testing.expectEqual(@as(usize, 1), c.len);
    try testing.expect(!find(&c, .geo).?.geo.unavailable);
    v.generation = 5;
    v.flags.geo_unavailable = true;
    try t.setWant(v);
    t.plan(&c);
    try testing.expectEqual(@as(usize, 1), c.len);
    try testing.expect(find(&c, .geo).?.geo.unavailable);

    // 지움은 답을 기다리지 않는다(EP09), 지운 뒤 늦게 온 옛 답은 버린다(EP12).
    var z: Tab = .{};
    try z.setWant(.{ .browser = 1, .generation = 1, .flags = .{ .timezone = true }, .timezone = "UTC" });
    z.plan(&c);
    z.answered(.timezone, true, "");
    try z.setWant(.{ .browser = 1, .generation = 2 });
    z.plan(&c);
    try testing.expectEqual(@as(usize, 1), c.len);
    try testing.expect(!c.items[0].set);
    try testing.expect(!z.waiting());
    z.answered(.timezone, false, "{\"message\":\"late\"}");
    st = z.state(1);
    try testing.expect(!st.pending);
    try testing.expectEqual(@as(u16, 0), st.failed_mask);
    try testing.expectEqual(msg.EmuFailReason.none, st.reason);
    // 보내지 못한 지움(호스트 없음)도 실패로 보인다(EP23).
    z.sendFailed(.timezone);
    try testing.expectEqual(@as(u16, 1 << @backingInt(msg.EmuGroup.timezone)), z.state(1).failed_mask);

    // 「already in effect」 하나만 — process_shared_conflict(EP13).
    var p: Tab = .{};
    try p.setWant(.{ .browser = 1, .generation = 1, .flags = .{ .timezone = true }, .timezone = "UTC" });
    p.plan(&c);
    p.answered(.timezone, false, "{\"code\":-32000,\"message\":\"Timezone override is already in effect\"}");
    try testing.expectEqual(msg.EmuFailReason.process_shared_conflict, p.state(1).reason);

    // 살아 있는 탭은 쌓인 것이 없다 — DevTools 가 떨어져 모르게 된 종류가 있어도 pending 이 아니다(EP21).
    var a: Tab = .{ .pane_w = 640, .pane_h = 400 };
    try a.setWant(phone());
    a.plan(&c);
    a.detached();
    try testing.expect(!a.held());
    try testing.expect(!a.state(1).pending);

    // 죽은 동안 바꾼 화면 — 상태의 줄임은 새 크기로(EP24).
    var d: Tab = .{ .pane_w = 640, .pane_h = 400 };
    try d.setWant(phone());
    d.plan(&c);
    d.rendererGone();
    var wide = phone();
    wide.generation = 2;
    wide.height = 400;
    try d.setWant(wide);
    try testing.expectEqual(fitScale(640, 400, 390, 400), d.state(1).fit_scale);
}
