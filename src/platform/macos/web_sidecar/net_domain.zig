//! 탭마다 CDP Network 도메인의 주인 하나(W9d③ — docs/plans/web-osr-backend.md 「W9d③ 결정·실측」 §6.4, W9e② 「결정·실측」). CEF 를 모른다 —
//! 무엇을 보낼지(명령 열)만 정하고 보내기는 `blocking.zig` 가 한다.
//!
//! Network 도메인을 쓰는 이가 셋이다: W9d② 의 본문 기록(`net_body.zig` — 버퍼 2 MiB·8 MiB 로 켠다), W9d③ 의 엄격 모드(서비스 워커 우회 —
//! `Network.setBypassServiceWorker` 는 `Network.enable` 없이는 듣지 않는다, 실측 D3(ii)), W9e② 의 네트워크 조건(`emulateNetworkConditionsByRule`
//! 도 enable 이 있어야 듣는다 — 실측 n1). 셋이 따로 켜고 끄면:
//!   - 기록이 끄는 `Network.disable` 이 엄격을 말없이 멈추고(실측 sw2 — 서비스 워커가 다시 다스린다), 조건(ByRule·온라인 여부)도 지운다(n1),
//!   - 그런데 우회 **표시는 남아** 다음 `Network.enable{}` 에 엄격이 저절로 되살아난다(실측 sw2 — 끈 엄격이 돌아온다).
//! 그래서 이 표가 셋의 바람을 합쳐 명령을 낸다:
//!   - 엄격 켬: 꺼져 있으면 `enable_light`(`{maxTotalBufferSize:0,maxResourceBufferSize:0,maxPostDataSize:1}` — 이벤트는 받기만), 지금 사이트를
//!     덮으면 `bypass_on`.
//!   - 엄격 끔(끔·grant 철회·탭 닫힘): **먼저** `bypass_off`(표시를 지운다), 그다음 기록이 없으면 `disable`.
//!   - 기록 켬: `enable_record`(기록의 상한 — 우회는 그대로 유지된다, 실측). 기록 끔: 엄격·조건이 있으면 `disable` 대신 `enable_light`(버퍼를 내린다).
//!   - 쏟아짐 밸브(W9d② 5000/s × 2 s): 엄격·조건이 도메인을 쥐고 있으면 기록만 멈추고 도메인은 끄지 않는다(말없이 꺼지지 않게).
//!   - 사이트 묶기: 주 프레임 `on_before_browse`(홉마다)에서 바라는 우회 값이 바뀌면 보낸다(실측 latch — 그 이동에 듣는다).
//!   - W9e② 조건(`condSync`): 켬은 도메인(꺼졌거나 모르면 `enable_light`) → ByRule(`cond_set` — 값이 바뀔 때만) → 오프라인이면 온라인 여부
//!     (`online_off` — 사용자 결정 3: 요청 막기 + `navigator.onLine`). 끔은 온라인 되돌림(`online_on`) → ByRule 비움(`cond_clear`) → 기록·엄격이
//!     없으면 `disable`. 조건이 있는 동안은 `disable` 이 없다.
//!
//!   - 실패한 엄격 CDP 뒤에는 브라우저의 우회 표시·도메인을 **모른다**(`unknown` — 4 차 검증 B-LOW-2: 실패한 짝 중 `bypass_on` 이 닿았는지
//!     모르는데 「꺼짐」 으로 두어, 덮지 않는 곳의 다시 켬·엄격 끔이 `bypass_off` 를 보내지 않았다 — 남은 표시를 기록의 `Network.enable` 이
//!     되살려 엄격을 끈 탭이 서비스 워커를 건너뛰었다). 모르면 바라는 값을 늘 명시해 보낸다.
//!   - 엄격 켬의 답 셈(`Batch` — `blocking.zig` 의 탭마다): 보낸 켬 명령이 모두 답해야 `on`, 하나라도 실패면 `failed`.
//!   - 렌더러 죽음(9 차 — W9e② 실측 a3_dead3·`--review-block-v20h` A9): 렌더러가 죽은 동안 보낸 명령은 새 렌더러에 닿지 않는다. 새 렌더러는 죽기 전
//!     렌더러 쪽 상태(우회·도메인 켜짐)를 되받고, 죽은 동안 보낸 명령은 되살리는 이동이 시작할 때 한꺼번에 실패로 답한다(브라우저 쪽 몫 — 이동의
//!     우회 — 만 듣는다). 그래서 끈 엄격·끈 기록이 되살아난 탭에 남았다(하위 자원이 서비스 워커를 건너뛰고, 에이전트가 끈 기록의 본문을
//!     `getResponseBody` 로 읽었다). `Renderer` 가 죽은 동안 보낸 명령을 표시하고, 그 첫 답에 `Batch.resync` 가 **마지막으로 바란 상태**를 명시해
//!     다시 보낸다(끔은 `bypass_off` 먼저 — 위 차례 그대로, 꺼진 것을 다시 켜지 않는다). 보내는 때는 그 실패 묶음이 끝난 뒤다(`blocking.zig` 의
//!     task — 묶음 안에서 보낸 명령은 함께 실패했고, 묶음 뒤에 보낸 명령은 새 렌더러가 붙기를 기다려 닿았다, 실측).
//!   - 10 차(`Tab`): 살아 있을 때 보냈어도 바쁜 렌더러가 처리하지 못한 채 죽은 명령도 새 렌더러에 닿지 않는다 — **모든** 명령의 답을 짝지어 죽을 때
//!     답을 기다리던 것을 표시한다(MED-1). 짝 자리는 탭마다 종류(도메인·우회)마다 하나 — 같은 종류의 새 명령이 앞 자리를 덮는다(LOW-1: 모든 탭이
//!     나눈 256 자리를 죽은 탭 하나가 다 썼다). 다시 보낸 값은 되살린 문서의 머리 하위 자원(css·script·img)보다 늦게 닿는다 — 그것들은 옛 우회로
//!     나간다(LOW-2 — 남는 틈, 늘 「더 우회」 쪽).
//!   - W9e② 조건도 이 길을 탄다(main 위로 옮김 2026-11-12 — 옛 W9e② 는 죽은 동안 렌더러 쪽 명령을 쌓았다가 새 문서에서 냈는데, 9 차·10 차의 이 길이
//!     같은 출시 버그(a3_dead2·a3_dead3)를 살아 있을 때 보낸 채 죽은 명령까지 덮어 고쳤다). 온라인 여부(`online_*` — 렌더러 쪽)는 짝 자리 하나를
//!     더 쥐고 죽음에 표시되며, 다시 맞추기가 오프라인 바람을 명시해 다시 보낸다(`forgetRenderer` — 온라인 여부를 쓴 탭만 「모름」). ByRule
//!     (`cond_*`)은 **브라우저 쪽**이라(죽은 동안에도 곧 답한다 — 실측 a3_dead) 죽음에 표시하지 않는다: 표시하면 렌더러가 서기 전에 온 그 답이
//!     다시 맞추기를 일찍 걸어, 맞추는 명령이 표시 없이 죽은 렌더러로 나가 사라진다. 조건 켬의 답 셈은 `Tab` 의 `cond_*`(도메인 켬·ByRule·오프라인).
//!
//! 시험이 증명하는 것: 각 차례의 명령 열 — 끔은 `bypass_off` 가 늘 먼저, 기록 끔은 엄격·조건이 있으면 `enable_light`, 밸브는 엄격·조건이 있으면
//! 도메인을 두고, 사이트 묶기는 값이 바뀔 때만, 엄격이 없으면 우회를 보내지 않는다, 모르는 우회는 명시해 보낸다; 답 셈의 차례(`Batch`); 렌더러 죽음 뒤
//! 다시 보내기의 명령 열과 그 때(`Renderer` — 죽은 동안 보낸 명령의 첫 답에 한 번). W9e②: 조건이 있는 동안 `disable` 이 없다, 오프라인은 ByRule 과
//! 온라인 여부 둘, 같은 조건은 다시 보내지 않는다, ByRule 은 죽음에 표시하지 않고 온라인 여부는 표시해 다시 맞춘다, 조건 켬의 답 셈.

const std = @import("std");

pub const Cmd = enum {
    /// `Network.enable{maxTotalBufferSize:0,maxResourceBufferSize:0,maxPostDataSize:1}`.
    enable_light,
    /// `Network.enable{maxResourceBufferSize:2097152,maxTotalBufferSize:8388608,maxPostDataSize:1}`(W9d② 의 값 — 보내기는 `net_body` 가 한다:
    /// 그 답으로 기록의 켜짐을 알린다).
    enable_record,
    disable,
    bypass_on,
    bypass_off,
    /// W9e②: `Network.emulateNetworkConditionsByRule` — 규칙 하나(`urlPattern:""`)와 오프라인(인자는 `blocking.zig` 가 바람에서 만든다).
    cond_set,
    /// W9e②: `Network.emulateNetworkConditionsByRule{matchedNetworkConditions:[]}`.
    cond_clear,
    /// W9e②: `Network.overrideNetworkState{offline:true,…}` — `navigator.onLine` false(사용자 결정 3 — 같은 렌더러 프로세스의 프레임 모두).
    online_off,
    /// W9e②: `Network.overrideNetworkState{offline:false,…}` — 되돌림.
    online_on,

    /// 렌더러 쪽 명령인가(죽은 동안 보내면 새 렌더러에 닿지 않는다 — 9 차). ByRule 은 브라우저 쪽이다(a3_dead).
    pub fn rendererSide(self: Cmd) bool {
        return switch (self) {
            .cond_set, .cond_clear => false,
            else => true,
        };
    }
};

/// 명령 열(많아야 여섯 — 우회·온라인·ByRule·도메인 … 한 번의 바뀜에 여섯을 넘지 않는다).
pub const Cmds = struct {
    items: [6]Cmd = undefined,
    len: u8 = 0,

    fn push(self: *Cmds, c: Cmd) void {
        self.items[self.len] = c;
        self.len += 1;
    }

    pub fn slice(self: *const Cmds) []const Cmd {
        return self.items[0..self.len];
    }
};

/// 도메인 상태 — `unknown` 은 엄격 CDP 가 실패해 가벼운 enable 이 닿았는지 모른다(켬은 다시 보내고 끔은 `disable` 을 보낸다).
pub const Enabled = enum { off, light, record, unknown };

/// 브라우저의 우회 표시(`Network.setBypassServiceWorker`) — `unknown` 은 보낸 값이 닿았는지 모른다(실패한 엄격 CDP 뒤 — 4 차 검증 B-LOW-2).
pub const Bypass = enum {
    off,
    on,
    unknown,

    fn of(want: bool) Bypass {
        return if (want) .on else .off;
    }
};

pub const Domain = struct {
    /// 본문 기록이 도메인을 바란다(밸브로 멈춘 기록은 거짓).
    recording: bool = false,
    /// 엄격 모드가 켜져 있다(사이트에 묶였다 — 지금 사이트가 덮이는가는 `bypass`).
    strict: bool = false,
    enabled: Enabled = .off,
    /// 브라우저의 우회 표시(마지막으로 보낸 값 — 실패 뒤에는 `unknown`).
    bypass: Bypass = .off,
    /// W9e②: 네트워크 조건의 바람 — 걸 것인가, 그 인자의 해시(0 아님), 오프라인인가.
    cond: bool = false,
    cond_hash: u64 = 0,
    offline: bool = false,
    /// W9e②: 걸어 둔 ByRule 의 해시(0 = 없음 — 브라우저 쪽이라 렌더러 죽음에 「모름」 이 되지 않는다).
    applied_cond: u64 = 0,
    /// W9e②: `navigator.onLine` 덮어쓰기 — `on` 은 오프라인으로 덮어 두었다(마지막으로 보낸 값), `unknown` 은 렌더러 죽음 뒤 닿았는지 모른다.
    online: Bypass = .off,
    /// W9e②: 온라인 여부 명령을 보낸 적이 있다 — 렌더러 쪽 상태를 모르게 되면(`forgetRenderer`) 이 탭만 온라인 여부를 「모름」 으로 둔다(쓴 적 없는
    /// 탭에 명령을 더하지 않는다).
    online_used: bool = false,

    /// 지금 우회 중인가(보낸 값이 `on` — 모르면 거짓).
    pub fn bypassing(self: *const Domain) bool {
        return self.bypass == .on;
    }

    /// 엄격 켬 — `covers_now` 는 지금 맨 위 호스트를 엄격 사이트가 덮는가. 우회를 모르면 바라는 값을 명시해 보낸다.
    pub fn strictOn(self: *Domain, covers_now: bool) Cmds {
        var out: Cmds = .{};
        self.strict = true;
        if (self.enabled == .off or self.enabled == .unknown) {
            out.push(.enable_light);
            self.enabled = .light;
        }
        if (self.bypass != Bypass.of(covers_now)) {
            out.push(if (covers_now) .bypass_on else .bypass_off);
            self.bypass = Bypass.of(covers_now);
        }
        self.condSync(&out);
        return out;
    }

    /// W9e②: 조건의 바람과 걸어 둔 것의 차이(머리 주석의 차례) — 끔 쪽(온라인 되돌림·ByRule 비움)을 먼저, 그다음 켬 쪽(도메인·ByRule·온라인 여부).
    /// 모르는 온라인 여부(렌더러 죽음 뒤)는 바라는 값을 명시해 보낸다. 도메인 끔(`disable`)은 부른 쪽이 정한다(기록·엄격도 본다).
    fn condSync(self: *Domain, out: *Cmds) void {
        const want_online_off = self.cond and self.offline;
        if (self.online != .off and !want_online_off) {
            out.push(.online_on);
            self.online = .off;
        }
        if (self.applied_cond != 0 and !self.cond) {
            out.push(.cond_clear);
            self.applied_cond = 0;
        }
        if (!self.cond) return;
        if (self.enabled == .off or self.enabled == .unknown) {
            out.push(.enable_light);
            self.enabled = .light;
        }
        if (self.applied_cond != self.cond_hash) {
            out.push(.cond_set);
            self.applied_cond = self.cond_hash;
        }
        if (want_online_off and self.online != .on) {
            out.push(.online_off);
            self.online = .on;
        }
    }

    /// 기록·엄격·조건 어느 것도 도메인을 바라지 않으면 끈다(`disable` 이 ByRule·온라인 여부도 지운다 — n1; 그 전에 condSync 가 이미 되돌렸다).
    fn offIfUnused(self: *Domain, out: *Cmds) void {
        if (self.recording or self.strict or self.cond or self.enabled == .off) return;
        out.push(.disable);
        self.enabled = .off;
    }

    /// 엄격 끔 — 우회를 먼저 지우고(표시가 `Network.disable` 뒤에도 남는다 — sw2 — 모르면 그래도 보낸다), 기록·조건이 없으면 도메인을 끈다.
    pub fn strictOff(self: *Domain) Cmds {
        var out: Cmds = .{};
        if (!self.strict and self.bypass == .off) return out;
        self.strict = false;
        if (self.bypass != .off) {
            out.push(.bypass_off);
            self.bypass = .off;
        }
        self.condSync(&out);
        self.offIfUnused(&out);
        return out;
    }

    /// 주 프레임 이동 홉(`on_before_browse`) — 엄격이면 바라는 우회 값(그 홉의 호스트를 엄격 사이트가 덮는가)이 보낸 값과 다를 때만(모르면 늘).
    pub fn navigate(self: *Domain, covers_target: bool) Cmds {
        var out: Cmds = .{};
        if (!self.strict or self.bypass == Bypass.of(covers_target)) return out;
        out.push(if (covers_target) .bypass_on else .bypass_off);
        self.bypass = Bypass.of(covers_target);
        return out;
    }

    /// 우회 명령이 닿았는지 모르게 됐다(보내기 실패·답의 실패·답을 짝지을 자리가 없음·DevTools 떨어짐) — 다음 켬·끔·이동이 명시해 보낸다.
    pub fn bypassUnknown(self: *Domain) void {
        self.bypass = .unknown;
    }

    /// 본문 기록 켬 — 늘 기록의 상한으로 다시 켠다(답이 기록의 켜짐이다). 엄격이 꺼져 있는데 우회를 모르면(엄격 밖 `bypass_off` 의 실패·DevTools
    /// 떨어짐) 그 뒤 `bypass_off` 를 명시한다(5 차 검증 NIT: 기록의 `Network.enable` 이 남았을 수 있는 우회 표시를 되살렸고, 엄격이 꺼진 동안은
    /// `navigate` 도 보내지 않아 다음 엄격 켬·끔까지 서비스 워커를 건너뛰었다). 우회는 enable 뒤에만 듣는다(실측 D3(ii)) — 그래서 enable 다음. 엄격이
    /// 켜져 있으면 다음 이동(`navigate`)·켬이 바라는 값을 명시한다(그 사이트를 덮는지는 여기서 모른다).
    pub fn recordOn(self: *Domain) Cmds {
        var out: Cmds = .{};
        self.recording = true;
        out.push(.enable_record);
        self.enabled = .record;
        if (!self.strict and self.bypass != .off) {
            out.push(.bypass_off);
            self.bypass = .off;
        }
        return out;
    }

    /// 본문 기록 끔 — 엄격·조건이 있으면 가벼운 enable 로 버퍼를 내리고, 없으면 끈다.
    pub fn recordOff(self: *Domain) Cmds {
        var out: Cmds = .{};
        if (!self.recording and self.enabled != .record) return out;
        self.recording = false;
        if (self.strict or self.cond) {
            out.push(.enable_light);
            self.enabled = .light;
        } else {
            self.condSync(&out);
            self.offIfUnused(&out);
        }
        return out;
    }

    /// 쏟아짐 밸브 — 기록은 멈춘다. 엄격·조건이 도메인을 쥐고 있으면 끄지 않는다(기록의 버퍼만 가벼운 값으로).
    pub fn valve(self: *Domain) Cmds {
        return self.recordOff();
    }

    /// W9e②: 네트워크 조건을 건다(`hash` — 인자 JSON 의 해시, 0 이 아니다). 오프라인이면 ByRule 과 온라인 여부 둘(사용자 결정 3).
    pub fn conditionsOn(self: *Domain, hash: u64, offline: bool) Cmds {
        std.debug.assert(hash != 0);
        var out: Cmds = .{};
        self.cond = true;
        self.cond_hash = hash;
        self.offline = offline;
        if (offline) self.online_used = true;
        self.condSync(&out);
        return out;
    }

    /// W9e②: 조건을 푼다 — 온라인 여부를 되돌리고 ByRule 을 비우고, 기록·엄격이 없으면 도메인을 끈다.
    pub fn conditionsOff(self: *Domain) Cmds {
        var out: Cmds = .{};
        if (!self.cond and self.applied_cond == 0 and self.online == .off) return out;
        self.cond = false;
        self.cond_hash = 0;
        self.offline = false;
        self.condSync(&out);
        self.offIfUnused(&out);
        return out;
    }

    /// 본문 기록의 DevTools 가 떨어졌다·브라우저가 닫힌다 — 명령 없이 기록 몫만 내린다(엄격·조건이 없으면 도메인은 꺼진 것으로).
    pub fn recordingGone(self: *Domain) void {
        self.recording = false;
        if (!self.strict and !self.cond) self.enabled = .off;
    }

    /// 엄격의 CDP 가 실패했다(`setBypassServiceWorker`·`Network.enable` 의 답이 실패·DevTools 떨어짐) — 보냈다고 적은 값을 믿지 않는다: 다음
    /// `strictOn`·`strictOff`·`navigate` 가 다시 보낸다(3 차 검증 N-B3-a: 보내기 전에 「보냈다」 로 적어 두어 다음 규칙 바꾸기가 아무것도 보내지
    /// 않고 엄격 `on` 으로 답했다 — 실패가 말없이 지워졌다). 우회·가벼운 도메인은 「꺼짐」 이 아니라 「모름」(4 차 검증 B-LOW-2 — 실패한 짝의 어느
    /// 것이 닿았는지 모른다). 기록이 켠 도메인(`record`)은 그대로 둔다(기록의 상한을 가벼운 값으로 내리지 않게).
    pub fn forgetStrictSent(self: *Domain) void {
        self.bypass = .unknown;
        if (self.enabled == .light) self.enabled = .unknown;
    }

    /// 렌더러 쪽 상태를 모른다(9 차 — 렌더러가 죽은 동안 보낸 명령은 새 렌더러에 닿지 않고, 새 렌더러는 죽기 전 상태를 되받는다) — 다음 켬·끔이
    /// 우회와 도메인을 모두 명시해 보낸다(`strictOff` 도 `disable` 을 — 조건이 있으면 `enable_light`, W9e② 온라인 여부도). 기록이 켠 도메인(`record`)은 그대로 둔다 — 기록의 켬은 `net_body` 가 보내고
    /// 그 답이 기록의 켜짐이다(죽은 동안 보낸 켬은 실패로 답하고 `recordFailed` 가 내린다).
    pub fn forgetRenderer(self: *Domain) void {
        self.bypass = .unknown;
        if (self.enabled != .record) self.enabled = .unknown;
        if (self.online_used) self.online = .unknown; // W9e②: 죽은 동안 보낸 온라인 여부도 닿지 않았다 — 오프라인 바람을 명시해 다시
    }

    /// 본문 기록의 켬이 실패했다(9 차 — 죽은 동안 보낸 켬은 되살리는 이동에 실패로 답하는데 새 렌더러는 죽기 전 상태를 되받는다) — 기록 몫을 내리고
    /// 렌더러 쪽 도메인을 모른다고 적는다(다음 `Batch.resync` 가 바라는 상태 — 엄격이면 가벼운 enable, 아니면 우회를 먼저 지우고 끔 — 를 명시한다).
    pub fn dropRecording(self: *Domain) void {
        self.recording = false;
        if (self.enabled == .record) self.enabled = .unknown;
    }

    /// 탭이 닫힌다·지켜보기가 꺼졌다 — 엄격·기록·조건 모두(우회 먼저, 온라인 되돌림·ByRule 비움, 도메인).
    pub fn closeAll(self: *Domain) Cmds {
        var out: Cmds = .{};
        if (self.bypass != .off) out.push(.bypass_off);
        if (self.online != .off) out.push(.online_on);
        if (self.applied_cond != 0) out.push(.cond_clear);
        if (self.enabled != .off) out.push(.disable);
        self.* = .{};
        return out;
    }
};

/// 엄격 켬의 답 셈(탭마다 — `blocking.zig` 의 `Strict` 가 쥔다; CDP 를 모른다). 켬 명령(`enable_light`·우회)을 보낼 때마다 `sent`(그 차례
/// `epoch` 를 답의 짝에 적는다), 답마다 `answered` — 그 차례의 명령이 모두 답하면 `on`·`failed` 를 낸다.
pub const Batch = struct {
    pub const State = enum { off, on, failed };

    state: State = .off,
    /// 답을 기다리는 켬 명령 수(이 차례의 것).
    waiting: u16 = 0,
    /// 이 차례에 실패가 있었다(보내기·답·자리 없음).
    failed: bool = false,
    /// 차례 번호 — 모두 다시 보내거나 끄면 오른다(앞 차례의 늦은 답은 세지 않는다).
    epoch: u32 = 0,

    /// 엄격 켬(`net_block` 의 엄격 사이트) — 보낼 명령. 앞 실패가 있으면(끝난 차례의 `failed` **또는** 답을 기다리는 차례에 이미 온 실패 답 —
    /// 4 차 검증 B-LOW-3: 두 답 사이에 온 `net_block` 이 그 실패 표시를 지우고 남은 답의 성공으로 `on` 을 냈다) 보냈다는 표시를 믿지 않고 모두
    /// 다시 보내 새 차례를 연다 — 그 실패는 다시 보낸 명령의 답이 판정한다. 실패가 없으면 기다리는 답과 실패 표시를 그대로 둔다(지우지 않는다).
    pub fn on(self: *Batch, d: *Domain, covers_now: bool) Cmds {
        const resend = self.state == .failed or self.failed;
        if (resend) {
            d.forgetStrictSent();
            self.newEpoch();
        }
        const cmds = d.strictOn(covers_now);
        if (resend or self.state != .on or cmds.len > 0) self.state = .off;
        return cmds;
    }

    /// 엄격 끔 — 기다리던 켬의 답은 더 셀 것이 없다(곧 `off` 로 답한다 — 전에는 켬의 답을 기다리는 동안 끄면 그 세대의 상태를 영영 보내지 않았다).
    pub fn off(self: *Batch, d: *Domain) Cmds {
        self.newEpoch();
        self.state = .off;
        return d.strictOff();
    }

    fn newEpoch(self: *Batch) void {
        self.epoch +%= 1;
        self.waiting = 0;
        self.failed = false;
    }

    /// 켬 명령 하나를 보냈다 — `ok` 는 보내기가 받아들여졌는가(짝 자리는 탭마다 종류마다 하나라 늘 있다 — 10 차 LOW-1; 4 차 검증 B-NIT 의 「자리
    /// 없음」 은 사라졌다).
    pub fn sent(self: *Batch, ok: bool) void {
        if (ok) {
            self.waiting += 1;
        } else self.failed = true;
    }

    /// 짝지은 켬 명령(`epoch` — 보낼 때의 차례)의 자리를 같은 종류의 새 명령이 덮었다(10 차 LOW-1 — `Tab.sent`) — 그 답은 셈에서 빠진다. 그 종류의
    /// 결과는 새 명령의 답이 낸다(한 세션의 명령은 차례로 처리된다 — 마지막 명령이 그 값을 정한다). 앞 차례의 것이면 셀 것이 없다.
    pub fn superseded(self: *Batch, epoch: u32) void {
        if (epoch == self.epoch and self.waiting > 0) self.waiting -= 1;
    }

    /// 짝지은 켬 명령의 답(`epoch` — 보낼 때의 차례) — 그 차례의 명령이 모두 답했으면 낼 상태. 앞 차례의 답은 세지 않는다.
    pub fn answered(self: *Batch, epoch: u32, ok: bool) ?State {
        if (epoch != self.epoch or self.waiting == 0) return null;
        self.waiting -= 1;
        if (!ok) self.failed = true;
        return self.settle();
    }

    /// 기다릴 답이 없으면 낼 상태(`on`·`failed`).
    pub fn settle(self: *Batch) ?State {
        if (self.waiting != 0) return null;
        self.state = if (self.failed) .failed else .on;
        return self.state;
    }

    /// 렌더러 쪽 상태를 다시 맞춘다(9 차 — 죽은 동안 보낸 명령이 되살린 렌더러에 닿지 않았다; 기록의 켬이 실패했다). **마지막으로 바란
    /// 상태**를 명시해 보낸다: 엄격이면 도메인과 우회(마지막으로 보낸 우회 값 — 그 값이 이동 홉마다 정한 바람이다; 모르면 `covers_now`), 아니면
    /// `bypass_off` 먼저 그다음 기록이 없으면 `disable`(꺼진 엄격을 다시 켜지 않는다). 새 차례를 연다 — 죽은 동안 보낸 명령의 늦은 답은 세지
    /// 않는다; 엄격이면 다시 보낸 명령의 답이 `on`·`failed` 를 정한다.
    pub fn resync(self: *Batch, d: *Domain, covers_now: bool) Cmds {
        const want = switch (d.bypass) {
            .on => true,
            .off => false,
            .unknown => covers_now,
        };
        d.forgetRenderer();
        self.newEpoch();
        self.state = .off;
        return if (d.strict) d.strictOn(want) else d.strictOff();
    }

    /// DevTools 가 떨어졌다 — 기다리던 답은 오지 않는다(실패).
    pub fn detached(self: *Batch) ?State {
        if (self.waiting == 0) return null;
        self.waiting = 0;
        self.failed = true;
        return self.settle();
    }
};

/// 렌더러의 삶(탭마다 — CDP 를 모른다; 9 차·10 차). 렌더러가 죽으면 그때 답을 기다리던 명령과 그 뒤 보내는 명령을 표시한다 — 그 답은 되살리는 이동이
/// 시작할 때 한꺼번에 온다(실측: 실패로). 표시한 명령의 **첫 답**에 한 번 다시 맞춘다(`Batch.resync` — 그 묶음 뒤에) — 같은 묶음의 나머지 답은 버린다
/// (다시 보낼 명령이 그 뒤에 선다 — 한 세션의 차례). 죽음을 맞은 명령이 하나도 없으면 새 렌더러가 되받는 상태가 곧 마지막으로 보낸 상태라 맞출 것이 없다.
///
/// 10 차(MED-1): 바쁜 렌더러는 살아 있을 때 보낸 명령을 처리하지 못한 채 죽을 수 있다 — 그 명령도 새 렌더러에 닿지 않는다. 그래서 「죽음을 맞은
/// 명령이 있다」(`stale`)를 따로 쥔다: 표시한 명령의 답을 끝내 못 받으면(DevTools 떨어짐·보내기 실패) 주 프레임 새 문서(`committed`)에서라도 다시 맞춘다.
pub const Renderer = struct {
    dead: bool = false,
    /// 죽음을 맞은 명령이 있다(죽을 때 답을 기다리던 것·죽은 동안 보낸 것) — 새 렌더러가 되받는 상태가 마지막으로 바란 상태가 아닐 수 있다.
    stale: bool = false,

    /// 렌더러가 죽었다(`on_render_process_terminated`) — `in_flight` 는 답을 기다리던 명령이 있는가(살아 있을 때 보냈어도 렌더러가 받았는지 모른다).
    pub fn gone(self: *Renderer, in_flight: bool) void {
        self.dead = true;
        if (in_flight) self.stale = true;
    }

    /// 지금 보내는 명령을 표시하는가(죽은 렌더러로 간다) — 표시하면 죽음을 맞은 명령이 생긴다.
    pub fn tagSend(self: *Renderer) bool {
        if (self.dead) self.stale = true;
        return self.dead;
    }

    /// 표시한 명령의 답이 왔다 — 되살리는 이동이 시작됐다. 처음 한 번만 참(그때 다시 맞추기를 건다).
    pub fn answeredDead(self: *Renderer) bool {
        if (!self.dead) return false;
        self.dead = false;
        self.stale = false;
        return true;
    }

    /// 주 프레임에 새 문서가 섰다(`on_load_start`) — 답을 기다리는 표시한 명령이 있으면(`dead_pending`) 그 답을 기다린다. 없으면 표시를 그치고, 죽음을
    /// 맞은 명령이 있었는데 그 답을 못 받았으면(10 차 — 떨어짐·보내기 실패로 짝이 사라졌다) 참: 지금 다시 맞춘다(늦어도 닫는다 — fail-safe).
    pub fn committed(self: *Renderer, dead_pending: bool) bool {
        if (!self.dead or dead_pending) return false;
        self.dead = false;
        defer self.stale = false;
        return self.stale;
    }
};

/// 명령의 종류 — 같은 종류는 마지막 명령이 렌더러 쪽 값을 정한다(한 세션의 명령은 보낸 차례로 처리된다): 도메인(`Network.enable`·`disable`)과 우회,
/// W9e② 의 온라인 여부(렌더러 쪽)와 ByRule(브라우저 쪽 — 죽음에 표시하지 않는다).
pub const Kind = enum(u2) {
    domain,
    bypass,
    online,
    cond,

    pub fn of(cmd: Cmd) Kind {
        return switch (cmd) {
            .enable_light, .enable_record, .disable => .domain,
            .bypass_on, .bypass_off => .bypass,
            .online_off, .online_on => .online,
            .cond_set, .cond_clear => .cond,
        };
    }
};

/// 답을 기다리는 명령 하나. `counted` — 켬의 답 셈(`Batch`)에 든다(그 차례 `epoch`), `dead` — 렌더러가 죽은 동안 보냈다(또는 답을 기다리는 동안
/// 렌더러가 죽었다) — 그 답은 새 렌더러가 붙을 때 온다.
pub const Pending = struct {
    id: i32 = 0,
    epoch: u32 = 0,
    counted: bool = false,
    dead: bool = false,
    /// W9e②: 조건 켬의 답 셈에 든다(그 차례 `cond_epoch`).
    cond_counted: bool = false,
    cond_epoch: u32 = 0,
};

/// 짝지은 답이 낸 일(`Tab.answered`).
pub const Answer = struct {
    /// 다시 맞추기를 건다(죽음을 맞은 명령의 첫 답 — 되살리는 이동이 시작됐다).
    resync: bool = false,
    /// 엄격 켬의 답 셈이 끝났다 — 낼 상태.
    state: ?Batch.State = null,
    /// W9e②: 조건 켬의 답 셈이 끝났다(`Tab.condStatus` 가 바뀌었다 — 흉내 상태를 다시 보낸다).
    cond: bool = false,
};

/// 탭 하나의 렌더러 쪽 명령 길(10 차 — `blocking.zig` 의 `Strict` 가 쥔다; CDP 를 모른다): 바람(`Domain`)·켬의 답 셈(`Batch`)·렌더러의 삶(`Renderer`)·
/// 답을 기다리는 명령.
///
/// 10 차가 고친 둘:
///   - MED-1: 전에는 엄격 켬 쪽 명령과 우회만 답을 짝지었다 — 엄격 없는 탭의 기록 끔(`disable` 하나)은 살아 있을 때 보내면 짝이 없었고, 바쁜 렌더러가
///     그것을 처리하지 못한 채 죽으면 죽음에 표시할 것이 없어 새 렌더러가 기록의 버퍼로 켠 도메인을 되받았다(에이전트가 끈 기록의 본문을 읽었다 4/4).
///     이제 **모든** 명령의 답을 짝짓는다 — 죽을 때 답을 기다리던 명령이 있으면 다시 맞춘다.
///   - LOW-1: 짝 자리는 모든 탭이 나눈 256 이었다 — 죽은 탭 하나가 엄격 켬·끔을 쏟아 다 쓰면 다른 탭의 엄격 켬이 거짓 `failed`, 다른 탭의 죽은 동안
///     끈 기록이 다시 맞추기를 몰랐다(2/2). 이제 **탭마다 종류마다 한 자리**다: 같은 종류의 새 명령이 앞 명령의 자리를 덮는다(마지막 명령이 그 종류의
///     렌더러 쪽 값을 정한다 — 앞 명령의 답은 더 알릴 것이 없다). 자리가 모자라는 일이 없다 — 끄기의 짝을 잃지 않는다.
pub const Tab = struct {
    domain: Domain = .{},
    batch: Batch = .{},
    life: Renderer = .{},
    slots: [4]Pending = @splat(.{}),
    /// W9e②: 조건 켬의 답 셈(도메인 켬·ByRule·오프라인 — 조건이 있을 때 보낸 것) — 기다리는 수·실패·차례(다시 맞추면 오른다).
    cond_waiting: u16 = 0,
    cond_failed: bool = false,
    cond_epoch: u32 = 0,

    /// 명령 하나를 보냈다(`id` — CDP 번호, `ok` — 보내기가 받아들여졌는가; 보낼 길이 없으면 거짓). 받아들여졌으면 같은 종류의 앞 명령 자리를 덮는다 —
    /// 그것이 이 차례의 셈에 들었으면 셈에서 뺀다(그 몫의 결과는 이 명령의 답이 낸다). 받아들여지지 않았으면 앞 자리는 그대로 둔다(그 답은 여전히 온다 —
    /// 죽음 표시도 그것으로 안다).
    pub fn sent(self: *Tab, cmd: Cmd, id: i32, ok: bool) void {
        // 엄격 켬 쪽 명령(도메인·우회)의 답은 엄격 상태에 쓴다(`Batch`).
        const counted = self.domain.strict and (cmd == .enable_light or cmd == .bypass_on or cmd == .bypass_off);
        // W9e②: 조건 켬 쪽 명령(도메인 켬·ByRule·오프라인)의 답은 조건 상태에 쓴다.
        const cond_counted = self.domain.cond and (cmd == .enable_light or cmd == .cond_set or cmd == .online_off);
        // 죽은 렌더러로 가는 명령은 표시한다 — 그 답이 새 렌더러가 붙은 때다. 보내기는 그대로 한다(브라우저 쪽 몫 — 이동의 서비스 워커 우회 — 은 죽은
        // 동안에도 듣는다, 실측). 보내지 못했어도 표시는 남는다(`life.stale` — 새 문서가 다시 맞춘다). W9e②: ByRule 은 브라우저 쪽이라 표시하지 않는다
        // (그 답은 죽은 동안에도 곧 온다 — 표시하면 렌더러가 서기 전에 다시 맞추기를 건다).
        const dead = cmd.rendererSide() and self.life.tagSend();
        const k = Kind.of(cmd);
        if (counted) self.batch.sent(ok);
        if (cond_counted) {
            if (ok) self.cond_waiting += 1 else self.cond_failed = true;
        }
        if (!ok) {
            // 우회 명령이 닿았는지 모른다 — 다음 켬·끔이 명시해 보낸다.
            if (k == .bypass) self.domain.bypassUnknown();
            return;
        }
        const old = self.slots[@backingInt(k)];
        if (old.id != 0 and old.counted) self.batch.superseded(old.epoch);
        if (old.id != 0 and old.cond_counted and old.cond_epoch == self.cond_epoch) self.cond_waiting -|= 1;
        self.slots[@backingInt(k)] = .{ .id = id, .epoch = self.batch.epoch, .counted = counted, .dead = dead, .cond_counted = cond_counted, .cond_epoch = self.cond_epoch };
    }

    /// W9e②: 먼저 적은 브라우저 쪽 명령(`cond_*` — 보내는 자리에서 곧 답한다, `blocking.sendCmd`)을 보내지 못했다 — 그 자리를 거두고(아직 이 명령의
    /// 것이면) 조건 켬의 셈이면 실패로. 엄격 켬의 셈(`counted`)에는 들지 않는 종류다.
    pub fn unsent(self: *Tab, cmd: Cmd, id: i32) void {
        std.debug.assert(!cmd.rendererSide());
        const p = &self.slots[@backingInt(Kind.of(cmd))];
        if (p.id != id) return; // 이미 답했다(그럴 수 없다 — 보내지 못했다) 또는 덮였다
        if (p.cond_counted and p.cond_epoch == self.cond_epoch) {
            self.cond_waiting -|= 1;
            self.cond_failed = true;
        }
        p.* = .{};
    }

    /// 짝지은 명령의 답 — 이 탭의 것이 아니면 null.
    pub fn answered(self: *Tab, id: i32, ok: bool) ?Answer {
        if (id == 0) return null;
        for (&self.slots, 0..) |*p, i| if (p.id == id) {
            const done = p.*;
            p.* = .{};
            // 죽은 렌더러로 간 명령의 답 — 되살리는 이동이 시작됐다(실측: 그때 한꺼번에 실패로 온다 — 새 렌더러는 죽기 전 상태를 되받는다). 첫 답에 다시
            // 맞추기를 걸고, 나머지 답은 버린다(다시 보낼 명령이 그 뒤에 선다 — 우회 「모름」·답 셈에 넣지 않는다).
            if (done.dead) return .{ .resync = self.life.answeredDead() };
            if (!ok and i == @backingInt(Kind.bypass)) self.domain.bypassUnknown();
            var a: Answer = .{};
            if (done.counted) a.state = self.batch.answered(done.epoch, ok);
            if (done.cond_counted and done.cond_epoch == self.cond_epoch and self.cond_waiting > 0) {
                self.cond_waiting -= 1;
                if (!ok) self.cond_failed = true;
                a.cond = self.cond_waiting == 0;
            }
            return a;
        };
        return null;
    }

    /// 렌더러가 죽었다 — 답을 기다리던 명령을 표시하고 그 뒤 보내는 명령도 표시한다.
    pub fn gone(self: *Tab) void {
        var in_flight = false;
        for (&self.slots, 0..) |*p, i| if (p.id != 0 and i != @backingInt(Kind.cond)) { // ByRule 은 브라우저 쪽(W9e②)
            p.dead = true;
            in_flight = true;
        };
        self.life.gone(in_flight);
    }

    /// 주 프레임에 새 문서가 섰다 — 참이면 지금 다시 맞춘다(`Renderer.committed`).
    pub fn committed(self: *Tab) bool {
        var dead_pending = false;
        for (self.slots) |p| if (p.id != 0 and p.dead) {
            dead_pending = true;
        };
        return self.life.committed(dead_pending);
    }

    /// DevTools 가 떨어졌다 — 기다리던 답은 오지 않는다. 우회 명령을 기다렸으면 우회를 모른다; 엄격 켬의 셈이 끝났으면 낼 상태.
    pub fn detached(self: *Tab) ?Batch.State {
        if (self.slots[@backingInt(Kind.bypass)].id != 0) self.domain.bypassUnknown();
        self.slots = @splat(.{});
        return self.batch.detached();
    }

    /// W9e②: DevTools 가 떨어졌다 — 조건 켬의 답을 기다렸으면 오지 않는다(실패 — 에이전트가 다시 걸 수 있다). 참이면 조건 상태가 바뀌었다.
    /// `detached` 보다 먼저 부른다(짝 자리를 그것이 비운다).
    pub fn condDetached(self: *Tab) bool {
        if (self.cond_waiting == 0) return false;
        self.cond_waiting = 0;
        self.cond_failed = true;
        return true;
    }

    /// W9e②: 렌더러 쪽 상태를 다시 맞춘다(`Batch.resync` — 조건 켬의 답 셈도 새 차례: 죽음을 맞은 켬의 늦은 답은 세지 않는다, 실패 표시는 남긴다).
    pub fn resync(self: *Tab, covers_now: bool) Cmds {
        self.cond_epoch +%= 1;
        self.cond_waiting = 0;
        return self.batch.resync(&self.domain, covers_now);
    }

    /// W9e②: 조건의 상태(흉내 상태의 network 무리) — 렌더러가 죽은 동안·답을 기다리면 `pending`.
    pub fn condStatus(self: *const Tab) CondStatus {
        if (!self.domain.cond) return .off;
        if (self.cond_failed) return .failed;
        if (self.cond_waiting > 0 or self.life.dead) return .pending;
        return .on;
    }

    /// 답을 기다리는 명령 수(시험·로그 — 많아야 넷).
    pub fn inFlight(self: *const Tab) usize {
        var n: usize = 0;
        for (self.slots) |p| n += @intFromBool(p.id != 0);
        return n;
    }
};

/// W9e②: 네트워크 조건의 상태.
pub const CondStatus = enum { off, pending, on, failed };

/// 짝지은 답과 그 주인(`answerFrom`).
pub fn Routed(comptime Owner: type) type {
    return struct { owner: *Owner, answer: Answer };
}

/// 답 하나를 **그 답이 온 탭**(CEF 브라우저 번호 `cef_id`)의 짝에서만 찾는다(11 차 LOW-1 — `blocking.onResult`). `Owner` 는 `cef_id` 와 `tab: Tab` 을
/// 가진다. 번호(`id`)는 모든 탭이 나누는 1 Mi 대역에서 돈다(`blocking.strict_id_base`). 번호만으로 모든 탭을 훑으면, 죽은 채 되살리지 않은 탭이 영영
/// 쥔 「죽음」 자리를 한 바퀴 돈 남의 같은 번호 답이 풀 수 있다 — 그러면 `answeredDead` 가 표시를 그쳐 그 탭의 다시 맞추기가 표시 없이 죽은 렌더러로
/// 나가고(그 답은 되살릴 때 실패로 버려진다), 새 문서도 맞추지 않는다: 10 차 MED-1 의 노출(끈 기록의 본문·끈 엄격의 우회)이 되살아난다. 답을 빼앗긴
/// 탭의 셈도 끝나지 않는다. 결과는 그 브라우저의 관찰자에게만 오므로(CEF — 관찰자는 브라우저 host 마다 단다) 답이 온 브라우저가 곧 보낸 탭이다.
pub fn answerFrom(comptime Owner: type, owners: []?Owner, cef_id: c_int, id: i32, ok: bool) ?Routed(Owner) {
    for (owners) |*slot| if (slot.*) |*o| if (o.cef_id == cef_id) if (o.tab.answered(id, ok)) |a| return .{ .owner = o, .answer = a };
    return null;
}

// ── 시험 ────────────────────────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn expectCmds(got: Cmds, want: []const Cmd) !void {
    try testing.expectEqualSlices(Cmd, want, got.slice());
}

test "W9d③: 엄격 켬·끔 — 꺼진 도메인은 가볍게 켜고 덮으면 우회, 끔은 우회를 먼저 지우고 기록이 없으면 끈다" {
    var d: Domain = .{};
    try expectCmds(d.strictOn(true), &.{ .enable_light, .bypass_on });
    try expectCmds(d.strictOn(true), &.{}); // 다시 켜도 같다
    try expectCmds(d.strictOff(), &.{ .bypass_off, .disable });
    try expectCmds(d.strictOff(), &.{});
    // 덮지 않는 사이트에서 켜면 도메인만(우회는 그 사이트로 갈 때).
    try expectCmds(d.strictOn(false), &.{.enable_light});
    try expectCmds(d.navigate(true), &.{.bypass_on});
    try expectCmds(d.navigate(true), &.{}); // 같은 값은 다시 보내지 않는다
    try expectCmds(d.navigate(false), &.{.bypass_off});
    try expectCmds(d.strictOff(), &.{.disable});
}

test "W9d③: 기록과 엄격이 도메인 하나를 나눈다 — 기록 끔은 엄격이 있으면 가벼운 enable, 엄격 끔은 기록이 있으면 도메인을 둔다, 밸브는 엄격이 있으면 끄지 않는다" {
    var d: Domain = .{};
    try expectCmds(d.recordOn(), &.{.enable_record});
    try expectCmds(d.strictOn(true), &.{.bypass_on}); // 이미 켜졌다 — 우회만
    try expectCmds(d.recordOff(), &.{.enable_light}); // disable 이면 엄격이 말없이 멈춘다
    try expectCmds(d.recordOn(), &.{.enable_record}); // 우회는 유지된다(실측)
    try expectCmds(d.strictOff(), &.{.bypass_off}); // 기록이 도메인을 쓴다 — 끄지 않는다
    try expectCmds(d.valve(), &.{.disable}); // 엄격이 없으면 밸브는 끈다
    try expectCmds(d.strictOn(true), &.{ .enable_light, .bypass_on });
    try expectCmds(d.recordOn(), &.{.enable_record});
    try expectCmds(d.valve(), &.{.enable_light}); // 엄격이 쥐고 있다 — 끄지 않는다
    try expectCmds(d.closeAll(), &.{ .bypass_off, .disable });
    try expectCmds(d.navigate(true), &.{}); // 엄격이 없으면 우회를 보내지 않는다
}

test "W9d③ 변이: 엄격을 다시 보낼 때 지금 사이트를 덮지 않으면 켜 둔 우회를 지운다(다른 사이트로 옮긴 뒤의 net_block)" {
    var d: Domain = .{};
    try expectCmds(d.strictOn(true), &.{ .enable_light, .bypass_on });
    try expectCmds(d.strictOn(false), &.{.bypass_off});
    try expectCmds(d.strictOn(false), &.{});
    try expectCmds(d.strictOn(true), &.{.bypass_on});
}

test "W9d③ 3 차 검증 N-B3-a: 엄격 CDP 가 실패한 뒤의 켬은 다시 보낸다 — 가벼운 enable·우회 모두, 기록이 켠 도메인은 다시 켜지 않는다" {
    var d: Domain = .{};
    try expectCmds(d.strictOn(true), &.{ .enable_light, .bypass_on });
    try expectCmds(d.strictOn(true), &.{}); // 실패를 모르면 아무것도 보내지 않는다(전의 결함)
    d.forgetStrictSent();
    try expectCmds(d.strictOn(true), &.{ .enable_light, .bypass_on });
    // 덮지 않는 곳에서 실패했으면 도메인과 우회 끔을 명시해(우회는 모른다 — 4 차 검증 B-LOW-2), 그 뒤 이동에서 우회.
    d.forgetStrictSent();
    try expectCmds(d.strictOn(false), &.{ .enable_light, .bypass_off });
    try expectCmds(d.navigate(true), &.{.bypass_on});
    // 기록이 도메인을 켰다 — 실패 뒤에도 기록의 enable 을 가벼운 값으로 바꾸지 않고 우회만 다시.
    var r: Domain = .{};
    try expectCmds(r.recordOn(), &.{.enable_record});
    try expectCmds(r.strictOn(true), &.{.bypass_on});
    r.forgetStrictSent();
    try expectCmds(r.strictOn(true), &.{.bypass_on});
}

test "W9d③ 9 차: 렌더러가 죽은 동안 끈 엄격 — 다시 맞추기는 우회를 먼저 지우고 도메인을 끈다(이미 「꺼짐」 으로 적었어도), 꺼진 엄격을 다시 켜지 않는다" {
    var d: Domain = .{};
    var b: Batch = .{};
    try expectCmds(b.on(&d, true), &.{ .enable_light, .bypass_on });
    b.sent(true);
    b.sent(true);
    try testing.expectEqual(@as(?Batch.State, null), b.answered(b.epoch, true));
    try testing.expectEqual(@as(?Batch.State, .on), b.answered(b.epoch, true));
    // 렌더러가 죽은 동안 끔 — 명령은 나가지만 새 렌더러에 닿지 않는다(표는 「꺼짐」 으로 적는다).
    try expectCmds(b.off(&d), &.{ .bypass_off, .disable });
    try testing.expect(d.bypass == .off and d.enabled == .off);
    // 되살림: 지금 사이트를 덮어도(covers_now) 꺼진 엄격은 켜지 않는다 — 끔을 명시해, 우회 먼저.
    try expectCmds(b.resync(&d, true), &.{ .bypass_off, .disable });
    try testing.expect(!d.strict and b.state == .off);
    // 다시 맞춘 뒤의 끔·이동은 더 보낼 것이 없다.
    try expectCmds(d.strictOff(), &.{});
    try expectCmds(d.navigate(true), &.{});
}

test "W9d③ 9 차: 렌더러가 죽은 동안 켠 엄격 — 다시 맞추기가 도메인과 우회를 명시하고 새 차례를 연다(죽은 동안 보낸 켬의 늦은 답은 세지 않는다)" {
    var d: Domain = .{};
    var b: Batch = .{};
    try expectCmds(b.on(&d, true), &.{ .enable_light, .bypass_on });
    b.sent(true);
    b.sent(true);
    const dead_epoch = b.epoch;
    try expectCmds(b.resync(&d, true), &.{ .enable_light, .bypass_on });
    try testing.expect(b.epoch != dead_epoch and b.state == .off and b.waiting == 0);
    // 죽은 동안 보낸 켬의 실패 답 — 앞 차례라 셈에 들지 않는다(실패로 `failed` 를 내지 않는다).
    try testing.expectEqual(@as(?Batch.State, null), b.answered(dead_epoch, false));
    b.sent(true);
    b.sent(true);
    try testing.expectEqual(@as(?Batch.State, null), b.answered(b.epoch, true));
    try testing.expectEqual(@as(?Batch.State, .on), b.answered(b.epoch, true));
}

test "W9d③ 9 차: 다시 맞추기의 우회는 마지막으로 바란 값이다 — 이동 홉이 정한 값을 지금 맨 위 호스트로 덮지 않고, 모를 때만 그것을 쓴다" {
    var d: Domain = .{};
    var b: Batch = .{};
    _ = b.on(&d, true);
    try expectCmds(d.navigate(false), &.{.bypass_off}); // 덮지 않는 사이트로 가는 홉(죽은 동안이어도 브라우저 쪽은 듣는다)
    try expectCmds(b.resync(&d, true), &.{ .enable_light, .bypass_off });
    d.bypassUnknown();
    try expectCmds(b.resync(&d, true), &.{ .enable_light, .bypass_on });
    d.bypassUnknown();
    try expectCmds(b.resync(&d, false), &.{ .enable_light, .bypass_off });
}

test "W9d③ 9 차: 기록과 나눈 도메인 — 죽은 동안 끈 기록은 다시 맞추기가 끄고, 켠 기록이 쥔 도메인은 다시 켜지 않는다, 기록의 켬 실패는 내린다" {
    // 엄격 없음: 기록 켬 → (죽음) → 기록 끔 → 되살림: 우회를 먼저 지우고 끈다.
    var d: Domain = .{};
    var b: Batch = .{};
    try expectCmds(d.recordOn(), &.{.enable_record});
    try expectCmds(d.recordOff(), &.{.disable});
    try expectCmds(b.resync(&d, false), &.{ .bypass_off, .disable });
    // 엄격 + 기록: 되살림은 우회만(기록의 enable 은 net_body 의 것 — 새 렌더러가 되받는다).
    var e: Domain = .{};
    var eb: Batch = .{};
    try expectCmds(e.recordOn(), &.{.enable_record});
    try expectCmds(eb.on(&e, true), &.{.bypass_on});
    try expectCmds(eb.resync(&e, true), &.{.bypass_on});
    try testing.expect(e.enabled == .record);
    // 기록의 켬이 실패했다(죽은 동안 보낸 켬) — 엄격이 있으면 가벼운 enable 로(기록의 상한을 내린다), 없으면 끈다.
    e.dropRecording();
    try expectCmds(eb.resync(&e, true), &.{ .enable_light, .bypass_on });
    var f: Domain = .{};
    var fb: Batch = .{};
    try expectCmds(f.recordOn(), &.{.enable_record});
    f.dropRecording();
    try expectCmds(fb.resync(&f, false), &.{ .bypass_off, .disable });
    try testing.expect(!f.recording and f.enabled == .off);
}

test "W9d③ 9 차: 렌더러의 삶 — 죽은 동안 보낸 명령만 표시하고, 그 첫 답에 한 번만 다시 맞추며, 표시한 명령이 없으면 새 문서에서 그친다" {
    var r: Renderer = .{};
    try testing.expect(!r.tagSend());
    try testing.expect(!r.answeredDead()); // 살아 있는 렌더러의 답은 다시 맞추지 않는다
    r.gone(false);
    try testing.expect(r.tagSend());
    try testing.expect(!r.committed(true)); // 표시한 명령의 답을 기다린다 — 그대로
    try testing.expect(r.tagSend());
    try testing.expect(r.answeredDead());
    try testing.expect(!r.answeredDead()); // 같은 묶음의 나머지 답
    try testing.expect(!r.tagSend()); // 다시 맞추는 명령은 표시하지 않는다(그 실패는 보통 실패다 — 되풀이하지 않는다)
    r.gone(false);
    try testing.expect(!r.committed(false)); // 죽음을 맞은 명령이 없다 — 새 렌더러가 되받은 상태가 곧 마지막 상태
    try testing.expect(!r.tagSend() and !r.answeredDead());
}

/// 시험용: 보낸 명령 열을 차례 번호로 `Tab` 에 적는다(모두 보내기 성공) — 첫 번호를 돌려준다.
fn sendAll(t: *Tab, cmds: Cmds, next: *i32) i32 {
    const first = next.*;
    for (cmds.slice()) |c| {
        t.sent(c, next.*, true);
        next.* += 1;
    }
    return first;
}

test "W9d③ 10 차 MED-1: 엄격 없는 탭의 기록 끔(`disable` 하나)도 답을 짝짓는다 — 답 전에 렌더러가 죽으면 그 답에 다시 맞추고(`bypass_off`·`disable`), 답 뒤에 죽으면 맞출 것이 없다" {
    // 고치기 전: `disable` 은 엄격 밖이라 짝이 없었다 — 죽음에 표시할 것이 없어 새 렌더러가 기록의 버퍼로 켠 도메인을 되받았다(4/4).
    var t: Tab = .{};
    var id: i32 = 1;
    try expectCmds(t.domain.recordOn(), &.{.enable_record}); // 켬은 net_body 가 보낸다(그 답이 기록의 켜짐)
    const off = sendAll(&t, t.domain.recordOff(), &id);
    try testing.expectEqual(@as(usize, 1), t.inFlight());
    t.gone(); // 바쁜 렌더러 — 답을 못 받은 채 죽음(kill -9·Page.crash)
    try testing.expect(t.life.stale);
    const a = t.answered(off, false).?; // 되살리는 이동이 시작할 때 실패로
    try testing.expect(a.resync and a.state == null);
    try expectCmds(t.batch.resync(&t.domain, false), &.{ .bypass_off, .disable });
    try testing.expect(!t.committed()); // 이미 맞췄다 — 새 문서에서 또 하지 않는다
    // 대조: 답을 받은 뒤 죽으면(렌더러가 처리했다 — 새 렌더러는 꺼진 상태를 되받는다) 맞출 것이 없다.
    var u: Tab = .{};
    _ = u.domain.recordOn();
    const off2 = sendAll(&u, u.domain.recordOff(), &id);
    try testing.expect(!u.answered(off2, true).?.resync);
    u.gone();
    try testing.expect(!u.life.stale);
    try testing.expect(!u.committed());
}

test "W9d③ 10 차 MED-1 같은 꼴: 모든 명령 종류(가벼운 enable·disable·우회 켬·끔)가 짝지어지고 죽음에 표시된다 — 엄격 켬·끔·기록 끔·이동 홉 어느 것이든" {
    const all = [_]Cmd{ .enable_light, .disable, .bypass_on, .bypass_off, .enable_record };
    for (all) |c| {
        var t: Tab = .{};
        t.sent(c, 7, true);
        try testing.expectEqual(@as(usize, 1), t.inFlight());
        t.gone();
        const a = t.answered(7, false).?;
        try testing.expect(a.resync);
        try testing.expect(t.answered(7, false) == null); // 한 번만
    }
    // 엄격 끔(엄격 켬 정착 뒤 — 우회 먼저): 둘 다 답 전에 죽으면 첫 답에 한 번만 다시 맞춘다.
    var t: Tab = .{};
    var id: i32 = 100;
    const on = sendAll(&t, t.batch.on(&t.domain, true), &id);
    _ = t.answered(on, true);
    try testing.expectEqual(@as(?Batch.State, .on), t.answered(on + 1, true).?.state);
    const off = sendAll(&t, t.batch.off(&t.domain), &id);
    t.gone();
    try testing.expect(t.answered(off, false).?.resync);
    try testing.expect(!t.answered(off + 1, false).?.resync); // 같은 묶음의 나머지 답은 버린다
    try expectCmds(t.batch.resync(&t.domain, true), &.{ .bypass_off, .disable }); // 꺼진 엄격을 다시 켜지 않는다
}

test "W9d③ 10 차 LOW-1 자리 몫: 죽은 탭이 엄격 켬·끔을 70 번 보내도 그 탭의 짝 자리는 둘이다 — 다른 탭은 자리를 잃지 않고, 되살리면 마지막 바람을 한 번 다시 보낸다" {
    var hog: Tab = .{};
    var vic: Tab = .{};
    var third: Tab = .{};
    var id: i32 = 1;
    hog.gone();
    var i: usize = 0;
    while (i < 70) : (i += 1) {
        _ = sendAll(&hog, hog.batch.on(&hog.domain, true), &id);
        _ = sendAll(&hog, hog.batch.off(&hog.domain), &id);
        try testing.expect(hog.inFlight() <= 2);
    }
    // 셋째 탭(살아 있음)의 엄격 켬 — 자리를 다른 탭과 나누지 않는다: on(전에는 자리가 없어 `failed`).
    const t0 = sendAll(&third, third.batch.on(&third.domain, true), &id);
    try testing.expectEqual(@as(?Batch.State, null), third.answered(t0, true).?.state);
    try testing.expectEqual(@as(?Batch.State, .on), third.answered(t0 + 1, true).?.state);
    // 피해 탭: 기록 켬 → 죽음 → 죽은 동안 끔 — 끔이 짝을 얻어 되살릴 때 다시 맞춘다(전에는 자리가 없어 `forgetRenderer` 만 하고 몰랐다).
    _ = vic.domain.recordOn();
    vic.gone();
    const voff = sendAll(&vic, vic.domain.recordOff(), &id);
    try testing.expect(vic.answered(voff, false).?.resync);
    try expectCmds(vic.batch.resync(&vic.domain, false), &.{ .bypass_off, .disable });
    // hog 를 되살림: 마지막 둘(끔의 `bypass_off`·`disable`)만 자리를 쥐었다 — 첫 답에 한 번 다시 맞추고, 덮인 앞 명령들의 늦은 답은 짝이 없다.
    try testing.expect(hog.answered(1, false) == null);
    var resyncs: usize = 0;
    var k: i32 = 1;
    while (k < id) : (k += 1) if (hog.answered(k, false)) |a| {
        resyncs += @intFromBool(a.resync);
    };
    try testing.expectEqual(@as(usize, 1), resyncs);
    try expectCmds(hog.batch.resync(&hog.domain, true), &.{ .bypass_off, .disable });
}

test "W9d③ 10 차 LOW-1 덮기: 같은 종류의 새 명령이 앞 자리를 덮으면 앞 것은 셈에서 빠지고 새 답이 그 몫을 낸다 — 성공이면 on, 실패면 failed" {
    var t: Tab = .{};
    var id: i32 = 1;
    const on = sendAll(&t, t.batch.on(&t.domain, true), &id); // enable_light(1)·bypass_on(2)
    const hop = sendAll(&t, t.domain.navigate(false), &id); // bypass_off(3) — 2 의 자리를 덮는다
    try testing.expectEqual(@as(u16, 2), t.batch.waiting);
    try testing.expect(t.answered(on + 1, true) == null); // 덮인 명령의 답은 짝이 없다
    try testing.expectEqual(@as(?Batch.State, null), t.answered(on, true).?.state);
    try testing.expectEqual(@as(?Batch.State, .on), t.answered(hop, true).?.state);
    // 새 명령이 실패하면 그 몫은 실패다(앞 명령의 성공으로 덮지 않는다).
    var f: Tab = .{};
    const fon = sendAll(&f, f.batch.on(&f.domain, true), &id);
    const fhop = sendAll(&f, f.domain.navigate(false), &id);
    try testing.expectEqual(@as(?Batch.State, null), f.answered(fon, true).?.state);
    try testing.expectEqual(@as(?Batch.State, .failed), f.answered(fhop, false).?.state);
    try testing.expect(f.domain.bypass == .unknown);
    // 앞 차례의 명령을 덮어도 이 차례의 셈은 그대로다.
    var g: Tab = .{};
    _ = sendAll(&g, g.batch.on(&g.domain, true), &id);
    _ = sendAll(&g, g.batch.off(&g.domain), &id); // 새 차례(off) — 앞 켬 둘을 덮는다
    try testing.expectEqual(@as(u16, 0), g.batch.waiting);
    const gon = sendAll(&g, g.batch.on(&g.domain, true), &id);
    try testing.expectEqual(@as(u16, 2), g.batch.waiting);
    _ = g.answered(gon, true);
    try testing.expectEqual(@as(?Batch.State, .on), g.answered(gon + 1, true).?.state);
}

test "W9d③ 10 차 fail-safe: 죽음을 맞은 명령의 짝이 사라지면(DevTools 떨어짐·죽은 동안 보내기 실패) 새 문서에서라도 다시 맞춘다 — 죽음을 맞은 명령이 없으면 맞추지 않는다" {
    var t: Tab = .{};
    var id: i32 = 1;
    _ = t.domain.recordOn();
    _ = sendAll(&t, t.domain.recordOff(), &id);
    t.gone();
    try testing.expectEqual(@as(?Batch.State, null), t.detached());
    try testing.expect(t.committed()); // 답은 오지 않는다 — 새 문서에서 맞춘다
    try testing.expect(!t.committed());
    // 죽은 동안 보내기 실패(보낼 길이 없음) — 짝은 없지만 죽음을 맞은 명령이 있다.
    var u: Tab = .{};
    u.gone();
    u.sent(.disable, id, false);
    try testing.expectEqual(@as(usize, 0), u.inFlight());
    try testing.expect(u.committed());
    // 아무것도 기다리지 않던 채 죽고 아무것도 보내지 않았다 — 맞출 것이 없다.
    var v: Tab = .{};
    v.gone();
    try testing.expect(!v.committed());
    // 표시한 명령의 답을 기다리는 동안의 새 문서는 기다린다(그 답이 곧 다시 맞추기를 건다).
    var w: Tab = .{};
    w.gone();
    w.sent(.disable, 9, true);
    try testing.expect(!w.committed());
    try testing.expect(w.answered(9, false).?.resync);
}

test "W9d③ 10 차 변이: 앞 차례의 명령을 덮어도 이 차례의 셈은 줄지 않는다 — 실패 뒤 다시 보낸 켬은 다시 보낸 명령이 모두 답해야 on" {
    var t: Tab = .{};
    var id: i32 = 1;
    const first = sendAll(&t, t.batch.on(&t.domain, true), &id); // enable_light(1)·bypass_on(2) — 차례 E1
    try testing.expectEqual(@as(?Batch.State, null), t.answered(first, false).?.state); // 1 실패 — 2 는 아직
    // 두 답 사이의 net_block — 앞 실패를 보고 모두 다시 보내 새 차례(E2)를 연다. 새 bypass_on 이 E1 의 2 를 덮는다(셈은 E2 의 것만).
    const again = sendAll(&t, t.batch.on(&t.domain, true), &id);
    try testing.expectEqual(@as(u16, 2), t.batch.waiting);
    try testing.expect(t.answered(first + 1, true) == null); // 덮인 E1 명령
    try testing.expectEqual(@as(?Batch.State, null), t.answered(again, true).?.state); // 하나 남았다 — 일찍 on 을 내지 않는다
    try testing.expectEqual(@as(?Batch.State, .on), t.answered(again + 1, true).?.state);
}

test "W9d③ 10 차 변이: 보내지 못한 명령은 앞 명령의 짝을 지우지 않는다 — 그 답이 여전히 오고 죽음 표시도 그것으로 안다" {
    var t: Tab = .{};
    t.sent(.disable, 1, true); // 살아 있을 때 보냄 — 답을 기다린다
    t.sent(.enable_light, 0, false); // 같은 종류, 보낼 길이 없음
    try testing.expectEqual(@as(usize, 1), t.inFlight());
    t.gone();
    try testing.expect(t.answered(1, false).?.resync);
}

test "W9d③ 10 차 변이: 엄격 켬 쪽 명령(셈에 드는 것)도 죽음을 맞으면 그 답은 셈이 아니라 다시 맞추기다 — failed 를 내지 않고 마지막 바람을 다시 보낸다" {
    var t: Tab = .{};
    var id: i32 = 1;
    const on = sendAll(&t, t.batch.on(&t.domain, true), &id); // 바쁜 렌더러 — 답 전에 죽음
    t.gone();
    const a = t.answered(on, false).?; // 되살리는 이동이 시작할 때 실패로
    try testing.expect(a.resync and a.state == null);
    try testing.expect(t.answered(on + 1, false).?.state == null);
    try expectCmds(t.batch.resync(&t.domain, true), &.{ .enable_light, .bypass_on });
}

test "W9d③ 11 차 LOW-1: 번호가 한 바퀴 돌아 겹쳐도 다른 탭의 답은 죽은 탭의 자리를 풀지 못한다 — 그 탭의 답만 다시 맞추기를 건다" {
    const Owner = struct { cef_id: c_int, tab: Tab = .{} };
    var owners: [3]?Owner = .{ .{ .cef_id = 7 }, null, .{ .cef_id = 9 } };
    const dead = &owners[0].?.tab;
    const live = &owners[2].?.tab;
    const x: i32 = 42;
    // 죽은 탭(앞 자리 — 번호만으로 훑으면 먼저 걸린다): 기록 켬 → 바쁜 채 끔(`disable` 의 답을 기다림) → 죽음, 되살리지 않는다.
    _ = dead.domain.recordOn();
    for (dead.domain.recordOff().slice()) |cmd| dead.sent(cmd, x, true);
    dead.gone();
    // 1 Mi 뒤 같은 번호가 살아 있는 탭의 명령에 돌아왔다.
    live.sent(.disable, x, true);
    // 살아 있는 탭의 답: 그 탭의 짝만 푼다 — 죽은 탭의 자리·표시는 그대로.
    const r = answerFrom(Owner, &owners, 9, x, true).?;
    try testing.expectEqual(@as(c_int, 9), r.owner.cef_id);
    try testing.expect(!r.answer.resync);
    try testing.expectEqual(@as(usize, 0), live.inFlight());
    try testing.expectEqual(@as(usize, 1), dead.inFlight());
    try testing.expect(dead.life.dead and dead.life.stale);
    // 모르는 브라우저의 같은 번호 답도 아무 자리도 풀지 못한다.
    try testing.expect(answerFrom(Owner, &owners, 8, x, false) == null);
    try testing.expectEqual(@as(usize, 1), dead.inFlight());
    // 죽은 탭을 되살리면 그 탭의 답이 다시 맞추기를 건다(마지막 바람 — 끈 기록은 끈다).
    const d = answerFrom(Owner, &owners, 7, x, false).?;
    try testing.expectEqual(@as(c_int, 7), d.owner.cef_id);
    try testing.expect(d.answer.resync);
    try expectCmds(dead.batch.resync(&dead.domain, false), &.{ .bypass_off, .disable });
    // 엄격 켬의 셈도 남의 답으로 끝나지 않는다.
    var o2: [2]?Owner = .{ .{ .cef_id = 1 }, .{ .cef_id = 2 } };
    const a = &o2[0].?.tab;
    const b = &o2[1].?.tab;
    for (a.batch.on(&a.domain, true).slice(), 0..) |cmd, i| a.sent(cmd, 100 + @as(i32, @intCast(i)), true);
    b.sent(.disable, 100, true);
    b.sent(.bypass_off, 101, true);
    _ = answerFrom(Owner, &o2, 2, 100, true).?;
    try testing.expectEqual(@as(?Batch.State, null), answerFrom(Owner, &o2, 2, 101, true).?.answer.state);
    try testing.expectEqual(@as(u16, 2), a.batch.waiting);
    _ = answerFrom(Owner, &o2, 1, 100, true).?;
    try testing.expectEqual(@as(?Batch.State, .on), answerFrom(Owner, &o2, 1, 101, true).?.answer.state);
}

// ── 12 차 LOW-2: 11 차 고침(답을 그 답이 온 탭에서만 찾는다)의 적대 검증 탐침을 시험으로 남긴다 ─────────────────────────────────
// 위 11 차 시험은 겹침을 「같은 번호를 손으로 넣어」 만든다. 아래 V1 은 번호를 실제로 한 바퀴 돌려 겹침이 저절로 나게 하고, 고치기 전 꼴(번호만 훑기)도
// 같은 판에 돌려 시험이 둘을 가르는지까지 본다. V2·V3 은 살아 있는 탭의 셈·죽은 동안 보낸 켬, V4 는 살아남은 변이를 같은 변이로 본 까닭의 전제다.

/// 고치기 전 꼴(번호만으로 모든 탭을 훑는다) — V1 이 고침 전후를 가르는지 보려는 대조. 제품에는 없다.
fn byIdOnlyForTest(comptime Owner: type, owners: []?Owner, id: i32, ok: bool) ?Routed(Owner) {
    for (owners) |*slot| if (slot.*) |*o| if (o.tab.answered(id, ok)) |a| return .{ .owner = o, .answer = a };
    return null;
}

/// `blocking.takeId` 의 꼴 — 대역 1 Mi 에서 돈다. `blocking.zig` 는 CEF 를 import 해 순수 시험에 들지 않으므로 값을 같게 적었다
/// (`strict_id_base` = 1 << 27, 폭 1 << 20). 시험이 재는 것은 도는 꼴이 아니라 겹친 번호의 답이 어느 탭에 가는가(`answerFrom`)다.
const rot_base: i32 = 1 << 27;
const rot_end: i32 = rot_base + (1 << 20);
fn rotTake(next: *i32) i32 {
    const id = next.*;
    next.* = if (next.* + 1 >= rot_end) rot_base else next.* + 1;
    return id;
}

test "W9d③ 12 차 LOW-2 V1: 번호를 실제로 한 바퀴 돌린다 — 죽은 탭의 두 종류 자리가 남의 같은 번호 답에 풀리지 않는다(앞·뒤 자리 모두); 번호만 보는 꼴은 죽은 탭이 앞이면 푼다" {
    const Owner = struct { cef_id: c_int, tab: Tab = .{} };
    inline for (.{ false, true }) |dead_first| inline for (.{ false, true }) |old_routing| {
        var owners: [3]?Owner = if (dead_first) .{ .{ .cef_id = 4 }, null, .{ .cef_id = 11 } } else .{ .{ .cef_id = 11 }, null, .{ .cef_id = 4 } };
        const dead = if (dead_first) &owners[0].?.tab else &owners[2].?.tab;
        const live = if (dead_first) &owners[2].?.tab else &owners[0].?.tab;
        var next: i32 = rot_base;
        // 죽은 탭: 엄격 켬(가벼운 enable·우회 켬 — 두 종류 자리 모두)을 바쁜 렌더러에 보내고 답 전에 죽음, 되살리지 않는다.
        const d0 = next;
        for (dead.batch.on(&dead.domain, true).slice()) |cmd| dead.sent(cmd, rotTake(&next), true);
        dead.gone();
        try testing.expectEqual(@as(usize, 2), dead.inFlight());
        // 산 탭이 명령 1 Mi 개를 보내고 실패 답을 받는다(이동 홉의 우회 — 켬·끔을 번갈아) — 번호가 한 바퀴 돌아 죽은 탭의 번호 둘이 돌아온다.
        _ = live.batch.on(&live.domain, true); // 엄격(우회 명령이 셈에 들게)
        var k: u32 = 0;
        var hit: u32 = 0;
        while (k < (1 << 20)) : (k += 1) {
            const id = rotTake(&next);
            live.sent(if (k % 2 == 0) .bypass_off else .bypass_on, id, true);
            _ = if (old_routing) byIdOnlyForTest(Owner, &owners, id, false) else answerFrom(Owner, &owners, 11, id, false);
            if (id == d0 or id == d0 + 1) hit += 1;
        }
        try testing.expectEqual(@as(u32, 2), hit); // 겹침이 실제로 일어났다(빈 판이 아니다)
        if (old_routing and dead_first) {
            // 고치기 전 꼴: 남의 답이 죽은 탭의 「죽음」 자리를 풀었다 — 다시 맞추기 표시가 그쳤다(11 차 LOW-1 의 재현).
            try testing.expect(!dead.life.dead);
            try testing.expectEqual(@as(usize, 0), dead.inFlight());
        } else {
            try testing.expectEqual(@as(usize, 2), dead.inFlight());
            try testing.expect(dead.life.dead and dead.life.stale);
            try testing.expectEqual(@as(u16, 2), dead.batch.waiting); // 셈도 그대로(남의 실패 답이 failed 를 만들지 않았다)
            try testing.expect(!dead.batch.failed);
            // 새 문서가 서도 제 답을 기다린다(되살리는 이동의 첫 답이 맞춘다).
            try testing.expect(!dead.committed());
            if (!old_routing) {
                // 되살림: 제 답의 첫 것이 다시 맞추기를 걸고, 둘째는 버린다 — 거짓 failed 없음.
                const a = answerFrom(Owner, &owners, 4, d0, false).?;
                try testing.expect(a.answer.resync and a.answer.state == null);
                const b2 = answerFrom(Owner, &owners, 4, d0 + 1, false).?;
                try testing.expect(!b2.answer.resync and b2.answer.state == null);
                try expectCmds(dead.batch.resync(&dead.domain, true), &.{ .enable_light, .bypass_on });
            }
        }
    };
}

test "W9d③ 12 차 LOW-2 V2: 살아 있는 탭의 엄격 켬 셈 — 남의 같은 번호 실패 답은 셈을 끝내지도 failed 로 만들지도 않는다, 제 답이 on 을 낸다" {
    const Owner = struct { cef_id: c_int, tab: Tab = .{} };
    var owners: [2]?Owner = .{ .{ .cef_id = 2 }, .{ .cef_id = 3 } };
    const other = &owners[0].?.tab;
    const mine = &owners[1].?.tab;
    for (mine.batch.on(&mine.domain, true).slice(), 0..) |cmd, i| mine.sent(cmd, 500 + @as(i32, @intCast(i)), true);
    // 남(앞 자리)도 같은 번호의 엄격 켬을 기다린다 — 그 답은 실패.
    for (other.batch.on(&other.domain, true).slice(), 0..) |cmd, i| other.sent(cmd, 500 + @as(i32, @intCast(i)), true);
    try testing.expectEqual(@as(?Batch.State, null), answerFrom(Owner, &owners, 2, 500, false).?.answer.state);
    try testing.expectEqual(@as(?Batch.State, .failed), answerFrom(Owner, &owners, 2, 501, false).?.answer.state);
    try testing.expectEqual(@as(u16, 2), mine.batch.waiting);
    try testing.expect(!mine.batch.failed);
    // 이미 풀린 남의 번호로 한 번 더 와도(같은 cef 의 같은 번호 — 자리가 없다) 내 자리로 넘어오지 않는다.
    try testing.expect(answerFrom(Owner, &owners, 2, 500, true) == null);
    try testing.expectEqual(@as(u16, 2), mine.batch.waiting);
    try testing.expectEqual(@as(?Batch.State, null), answerFrom(Owner, &owners, 3, 500, true).?.answer.state);
    try testing.expectEqual(@as(?Batch.State, .on), answerFrom(Owner, &owners, 3, 501, true).?.answer.state);
}

test "W9d③ 12 차 LOW-2 V3: 죽은 동안 보낸(표시한) 켬 — 남의 같은 번호 답 뒤에도 표시가 남고, DevTools 가 떨어지면 새 문서가 맞춘다(fail-safe 가 살아 있다)" {
    const Owner = struct { cef_id: c_int, tab: Tab = .{} };
    var owners: [2]?Owner = .{ .{ .cef_id = 20 }, .{ .cef_id = 21 } };
    const dead = &owners[0].?.tab;
    const live = &owners[1].?.tab;
    dead.gone(); // 기다리는 것 없이 죽음
    for (dead.batch.on(&dead.domain, true).slice(), 0..) |cmd, i| dead.sent(cmd, 900 + @as(i32, @intCast(i)), true); // 죽은 동안 켬 — 표시
    for (live.domain.recordOn().slice(), 0..) |cmd, i| live.sent(cmd, 900 + @as(i32, @intCast(i)), true);
    try testing.expect(!answerFrom(Owner, &owners, 21, 900, false).?.answer.resync);
    try testing.expect(dead.life.dead and dead.life.stale);
    try testing.expectEqual(@as(usize, 2), dead.inFlight());
    try testing.expectEqual(@as(?Batch.State, .failed), dead.detached()); // 떨어짐 — 기다리던 켬은 실패로 센다(기존 동작)
    try testing.expect(dead.committed());
}

test "W9d③ 12 차 LOW-2 V4: cef_id 가 같은 주인이 둘이면(엄격 표에서는 생기지 않는다 — strictEnsure) 둘째 주인의 짝은 찾는다 — 살아남은 변이 「첫 주인에서 그침」 을 같은 변이로 본 까닭의 전제" {
    const Owner = struct { cef_id: c_int, tab: Tab = .{} };
    var owners: [2]?Owner = .{ .{ .cef_id = 5 }, .{ .cef_id = 5 } };
    owners[1].?.tab.sent(.disable, 77, true);
    const r = answerFrom(Owner, &owners, 5, 77, true).?;
    try testing.expect(r.owner == &owners[1].?);
}

test "W9e②: 조건 — 꺼진 도메인은 가볍게 켜고 ByRule, 오프라인은 온라인 여부까지, 같은 조건은 다시 보내지 않는다, 끔은 온라인 되돌림·ByRule 비움·도메인 끔" {
    var d: Domain = .{};
    try expectCmds(d.conditionsOn(11, false), &.{ .enable_light, .cond_set });
    try expectCmds(d.conditionsOn(11, false), &.{}); // 같은 조건
    try expectCmds(d.conditionsOn(12, false), &.{.cond_set}); // 값이 바뀌면 그것만
    try expectCmds(d.conditionsOn(13, true), &.{ .cond_set, .online_off }); // 오프라인 = 요청 막기 + navigator.onLine
    try expectCmds(d.conditionsOn(14, false), &.{ .online_on, .cond_set }); // 오프라인에서 지연으로 — 되돌림이 먼저
    try expectCmds(d.conditionsOn(15, true), &.{ .cond_set, .online_off });
    try expectCmds(d.conditionsOff(), &.{ .online_on, .cond_clear, .disable });
    try expectCmds(d.conditionsOff(), &.{});
}

test "W9e②: 조건이 있는 동안 disable 은 없다 — 기록 끔·엄격 끔·밸브 모두 도메인을 두고, 조건 끔이 마지막이면 끈다" {
    var d: Domain = .{};
    try expectCmds(d.conditionsOn(7, true), &.{ .enable_light, .cond_set, .online_off });
    try expectCmds(d.recordOn(), &.{.enable_record}); // 조건은 그대로(n1 N4 — enable 다시는 조건을 지우지 않는다)
    try expectCmds(d.valve(), &.{.enable_light}); // 조건이 쥐고 있다 — 끄지 않는다(끄면 ByRule·오프라인이 사라진다, n1)
    try expectCmds(d.strictOn(true), &.{.bypass_on});
    try expectCmds(d.strictOff(), &.{.bypass_off}); // 조건이 도메인을 쓴다
    try expectCmds(d.conditionsOff(), &.{ .online_on, .cond_clear, .disable });
    // 엄격이 있으면 조건 끔은 도메인을 둔다.
    _ = d.strictOn(true);
    _ = d.conditionsOn(8, false);
    try expectCmds(d.conditionsOff(), &.{.cond_clear});
}

test "W9e②: 렌더러 쪽 명령의 가름 — ByRule 둘만 브라우저 쪽" {
    for ([_]Cmd{ .enable_light, .enable_record, .disable, .bypass_on, .bypass_off, .online_off, .online_on }) |c| try testing.expect(c.rendererSide());
    try testing.expect(!Cmd.cond_set.rendererSide() and !Cmd.cond_clear.rendererSide());
}

test "W9e② main 위로 옮김: 렌더러가 죽은 동안의 조건 — 온라인 되돌림·도메인 끔은 죽음에 표시해 첫 답에 다시 맞추고(오프라인 바람을 명시), ByRule 은 표시하지 않는다(브라우저 쪽)" {
    var t: Tab = .{};
    var id: i32 = 1;
    _ = sendAll(&t, t.batch.on(&t.domain, true), &id);
    const c0 = sendAll(&t, t.domain.conditionsOn(5, true), &id); // cond_set·online_off (도메인은 이미 켜졌다)
    try testing.expectEqual(@as(u16, 2), t.cond_waiting);
    try testing.expectEqual(CondStatus.pending, t.condStatus());
    try testing.expect(!t.answered(c0, true).?.cond);
    try testing.expect(t.answered(c0 + 1, true).?.cond);
    try testing.expectEqual(CondStatus.on, t.condStatus());
    t.gone();
    try testing.expectEqual(CondStatus.pending, t.condStatus()); // 죽은 동안
    // 죽은 동안 조건을 끈다 — ByRule 비움(브라우저 쪽)은 표시하지 않고, 온라인 되돌림은 표시한다.
    const off = sendAll(&t, t.domain.conditionsOff(), &id); // online_on·cond_clear
    try testing.expect(!t.answered(off + 1, true).?.resync); // ByRule 의 답은 곧 온다 — 다시 맞추기를 일찍 걸지 않는다
    try testing.expect(t.life.dead);
    try testing.expect(t.answered(off, false).?.resync); // 되살리는 이동이 시작할 때 실패로 온 온라인 되돌림
    try expectCmds(t.resync(true), &.{ .enable_light, .bypass_on, .online_on }); // 오프라인을 푼 바람을 명시
    try testing.expectEqual(CondStatus.off, t.condStatus());
    // 죽은 동안 오프라인을 건 탭 — 다시 맞추기가 오프라인을 명시하고 그 답이 조건 상태를 정한다.
    var u: Tab = .{};
    u.gone();
    const on = sendAll(&u, u.domain.conditionsOn(6, true), &id); // enable_light·cond_set·online_off
    try testing.expect(!u.answered(on + 1, true).?.resync); // ByRule
    try testing.expect(u.answered(on, false).?.resync);
    try testing.expect(u.answered(on + 2, false).?.state == null); // 같은 묶음의 나머지
    const again = sendAll(&u, u.resync(false), &id);
    try testing.expectEqual(@as(u16, 2), u.cond_waiting); // enable_light·online_off(ByRule 은 이미 걸렸다 — 브라우저 쪽)
    try testing.expectEqual(CondStatus.pending, u.condStatus());
    _ = u.answered(again + 1, true);
    try testing.expect(u.answered(again + 2, true).?.cond);
    try testing.expectEqual(CondStatus.on, u.condStatus());
    // 답을 기다리던 ByRule 이 렌더러 죽음을 맞아도 표시하지 않는다 — 그 답(브라우저 쪽 — 곧 온다)은 다시 맞추기를 걸지 않고 조건의 셈을 끝낸다.
    var w: Tab = .{};
    const w0 = sendAll(&w, w.domain.conditionsOn(8, false), &id); // enable_light·cond_set
    try testing.expect(!w.answered(w0, true).?.resync);
    w.gone(); // cond_set 은 아직 답을 기다린다
    try testing.expect(!w.life.stale); // 렌더러 쪽 명령은 답을 받았다 — 맞출 것이 없다
    const wa = w.answered(w0 + 1, true).?;
    try testing.expect(!wa.resync and wa.cond);
    try testing.expect(w.life.dead); // 렌더러는 아직 서지 않았다
    // 온라인 여부를 쓴 적 없는 탭은 다시 맞추기에 온라인 명령을 더하지 않는다(W9d③ 의 명령 열 그대로).
    var v: Tab = .{};
    _ = v.domain.conditionsOn(7, false);
    try expectCmds(v.resync(false), &.{ .bypass_off, .enable_light });
}

test "W9e② main 위로 옮김: 브라우저 쪽 ByRule 은 보내기 전에 짝을 적는다 — 보내는 자리의 곧 온 답이 셈을 끝내고, 보내지 못하면 거둬 실패로" {
    var t: Tab = .{};
    const cmds = t.domain.conditionsOn(3, false); // enable_light·cond_set
    try expectCmds(cmds, &.{ .enable_light, .cond_set });
    t.sent(.enable_light, 1, true); // 렌더러 쪽 — 보낸 뒤 적는다
    t.sent(.cond_set, 2, true); // 브라우저 쪽 — 보내기 전에 적는다(`blocking.sendCmd`)
    try testing.expect(!t.answered(2, true).?.cond); // 보내는 자리에서 곧 온 답
    try testing.expect(t.answered(1, true).?.cond);
    try testing.expectEqual(CondStatus.on, t.condStatus());
    // 보내지 못했다 — 자리를 거두고 실패.
    _ = t.domain.conditionsOn(4, false);
    t.sent(.cond_set, 3, true);
    t.unsent(.cond_set, 3);
    try testing.expectEqual(@as(usize, 0), t.inFlight());
    try testing.expectEqual(CondStatus.failed, t.condStatus());
    try testing.expect(t.answered(3, true) == null);
}
