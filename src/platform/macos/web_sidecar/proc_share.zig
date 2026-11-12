//! CPU 줄이기의 「프로세스 나눔」 판정(W9e② — docs/plans/web-osr-backend.md 「W9e② 결정·실측」 §4.3). CEF 를 모른다 — 부른 쪽(`emulation.zig`)이
//! 모든 탭의 프레임을 (탭, 주/하위, 사이트, 연 탭)으로 넘기고, 이 파일은 「이 탭(T)에 CPU 줄이기를 걸면 T 가족 밖의 프레임도 느려지는가」 만 정한다.
//!
//! 왜: `Emulation.setCPUThrottlingRate` 는 **렌더러 프로세스 전체**에 걸린다(실측 c1·o1 — T 가 연 팝업 645 ms, **사용자 탭 안의 T 와 같은 사이트
//! iframe 이 658 ms** 로 6 배 느려졌다; 바깥 사용자 페이지·따로 연 같은 사이트 탭은 102 ms). Chromium 은 같은 사이트의 하위 프레임(OOPIF)을 이미 있는
//! 그 사이트 프로세스에 다시 쓰고, 연 탭(팝업)은 연 프레임의 프로세스를 함께 쓴다. 그래서 위험은:
//!   - T 가족(T 와 T 가 연 탭들 — 연 탭 사슬) **밖**의 하위 프레임이 T 맨 위 사이트와 같은 사이트,
//!   - T 가족 밖의 **연 탭**(opener 가 있는 탭)의 주 프레임이 T 맨 위 사이트와 같은 사이트(사용자 탭 안의 같은 사이트 iframe 이 연 팝업 — a1_pop).
//! 따로 연 같은 사이트 탭(opener 없음)은 다른 프로세스였다(c1) — 위험이 아니다. 서비스 워커는 CPU 를 나누지 않았다(a1_sw — 뺀다).
//! 사이트는 어림이다: 공개 접미사 목록 없이 호스트의 마지막 두 마디(IP 주소·한 마디 호스트는 통째) — `a.example.com` 과 `b.example.com` 을 같은
//! 사이트로 보고(Chromium 의 사이트), `x.co.uk` 와 `y.co.uk` 도 같다고 본다(더 거절하는 쪽 — 이유는 늘 공개된다, 사용자 결정 6). 스킴은 보지 않는다.
//! `blob:`·`filesystem:` 주소는 **안쪽 주소의 호스트**로 정한다(`innerUrl16` — Chromium 은 그 문서를 만든 출처의 프로세스에 둔다).
//! **사이트를 모르는 가족 밖 프레임**(`data:`·불투명 출처의 blob 등 — 사이트 0)은 위험으로 친다(W9e② 적대 검증 7 회차 A7-1 HIGH): Chromium 은 그런
//! 문서를 그것을 시작한 쪽(제 앞 문서·부모·연 쪽)의 프로세스에 둔다 — 사용자 탭 안의 T 와 같은 사이트 iframe 이 제 문서를 `blob:`·`data:` 로
//! 바꾸자 사이트가 0 이 되어 안전으로 쳤고, 그 iframe 이 101 → 417 ms 로 함께 느려졌다(실측).
//! **출처를 물려받는 하위 프레임**(`about:blank`·`about:srcdoc`·`javascript:`·빈 주소 — `inheritsOrigin16`)은 사이트 0 으로 두지 않는다(W9e② 적대
//! 검증 v20b A7 V-A7 — 다른 사이트 사용자 탭의 흔한 광고·분석 꼴 다섯(src 없는 숨은 iframe·GPT 의 about:blank+document.write·srcdoc·`javascript:''`·
//! `sandbox srcdoc`)이 모두 `process_shared` 로 거절됐다). 웹 규칙상 그 문서는 만든 쪽의 출처를 물려받고 Chromium 은 그 쪽의 프로세스에 둔다 —
//! 만든 쪽은 부모(첫 빈 문서·srcdoc·document.write) 아니면 그 프레임 자신(제 문서를 `about:blank` 로 바꿈)이다(다른 프레임은 그 프레임이나 그
//! 조상과 같은 출처일 때만 그것을 옮길 수 있다 — HTML 「allowed to navigate」). 그래서 부른 쪽이 (1) 제 주소가 있는 가장 가까운 조상(주 프레임이면
//! 그 주 프레임과 같은 자리 — `inherited`)으로 정하고, (2) 물려받는 하위 프레임이 있는 탭은 그 탭의 하위 프레임이 가졌던 사이트들의 하위 프레임도
//! 있는 것으로 친다(`taint` — 제 문서를 `about:blank` 로 바꾸는 이동은 `on_before_browse` 를 지나지 않아 어느 프레임이 그랬는지 모른다, 실측; 그
//! 주 문서 동안 — A7-1 의 「제 문서를 바꾼 iframe」 이 `about:blank` 로 가도 막는다. 기록은 `SubSites` — 커밋한 문서만, 주 문서마다, 넘치면 다시
//! 센다: v20c N2). `sandbox` 문서는 불투명 출처지만 프로세스는 부모 쪽이다(또는 Chromium 이 따로 둔다 — 어느 쪽이든 T 의 프로세스가 아니면 위험이 아니다).
//! `data:` 는 그대로 위험이다(제가 연 것은 부모와 다를 수 있다 — 7 회차). CEF 는 프레임의 프로세스 번호를 주지 않는다 — 그래서 출처 규칙으로 가른다.
//!
//! 시험이 증명하는 것: 가족 밖 같은 사이트 하위 프레임·가족 밖 연 탭의 같은 사이트 주 프레임은 위험, 따로 연 같은 사이트 탭·T 의 다른 사이트
//! iframe·가족 안의 팝업과 그 하위 프레임·다른 사이트는 위험이 아니다, 연 탭 사슬(손자 팝업)도 가족, 사이트 어림(두 마디·IP·한 마디·대소문자·끝 점),
//! 사이트를 모르는 가족 밖 하위 프레임·연 탭은 위험이고 가족 안·연 탭 없는 주 프레임은 아니다, `blob:`·`filesystem:` 의 안쪽 주소(대소문자), 출처를
//! 물려받는 주소의 가름, 물려받는 하위 프레임은 조상 자리(다른 사이트 사용자 탭이면 위험이 아니다), 하위 프레임이 가졌던 사이트의 표시·모름은 위험,
//! 그 기록은 주 문서마다(새 문서는 새 기록·뒤로·앞으로는 옛 기록 또는 모름·같은 주소는 잇는다·주소 넷), 넘치면 열린 탭의 맨 위 사이트를 먼저 남기고
//! 지금 있는 프레임으로 다시 센다(「모름」 으로 굳지 않는다), 연 탭 사슬의 뿌리(손자 팝업·닫힌 연 탭·고리).

const std = @import("std");

/// 한 프레임. `browser`·`opener` 는 CEF 브라우저 번호(opener 0 = 연 탭이 없다). `site` 는 `siteKey` 의 해시(0 = 사이트를 모름 — `data:`·`about:`·
/// 불투명 출처 등; `blob:`·`filesystem:` 은 부른 쪽이 `innerUrl16` 으로 안쪽 주소를 넘긴다).
pub const Frame = struct {
    browser: c_int,
    main: bool,
    site: u64,
    opener: c_int = 0,
};

/// `blob:`·`filesystem:` 주소의 안쪽 주소(`blob:https://a.test/uuid` → `https://a.test/uuid` — 스킴은 대소문자 무시), 아니면 그대로. 그 문서의
/// 출처는 안쪽 주소의 출처이고 Chromium 은 그 출처의 프로세스에 둔다 — 겉 스킴만 보면 호스트가 없어 사이트를 모른다(A7-1).
pub fn innerUrl16(units: []const u16) []const u16 {
    for ([_][]const u8{ "blob:", "filesystem:" }) |prefix| {
        if (units.len < prefix.len) continue;
        const same = for (prefix, units[0..prefix.len]) |p, u| {
            if (u > 0x7f or std.ascii.toLower(@intCast(u)) != p) break false;
        } else true;
        if (same) return units[prefix.len..];
    }
    return units;
}

/// 그 문서가 만든 쪽의 출처를 물려받는 주소인가 — `about:blank`·`about:srcdoc`(뒤에 `?`·`#` 가 붙어도), `javascript:`, 빈 주소(아직 문서가 없는
/// iframe). 스킴은 대소문자 무시. `data:`·다른 `about:` 은 아니다(사이트 0 — 위험).
pub fn inheritsOrigin16(units: []const u16) bool {
    if (units.len == 0) return true;
    if (startsWithAscii16(units, "javascript:")) return true;
    for ([_][]const u8{ "about:blank", "about:srcdoc" }) |u| {
        if (!startsWithAscii16(units, u)) continue;
        if (units.len == u.len) return true;
        const next = units[u.len];
        if (next == '?' or next == '#') return true;
    }
    return false;
}

fn startsWithAscii16(units: []const u16, prefix: []const u8) bool {
    if (units.len < prefix.len) return false;
    for (prefix, units[0..prefix.len]) |p, u| {
        if (u > 0x7f or std.ascii.toLower(@intCast(u)) != p) return false;
    }
    return true;
}

/// 출처를 물려받는 하위 프레임의 자리 — 부른 쪽이 위로 따라가 처음 만난 「제 주소가 있는」 조상(`ancestor_main` 이면 그 탭의 주 프레임)을 넘긴다.
/// 주 프레임에서 물려받았으면 그 주 프레임과 같은 프로세스다 — 주 프레임처럼 친다(연 탭이 없는 사용자 탭의 빈 iframe 은 그 탭의 프로세스).
pub fn inherited(browser: c_int, ancestor_main: bool, ancestor_site: u64, opener: c_int) Frame {
    return .{ .browser = browser, .main = ancestor_main, .site = ancestor_site, .opener = if (ancestor_main) opener else 0 };
}

/// 물려받는 하위 프레임이 있는 탭의, 그 탭 하위 프레임이 가졌던 사이트 `site` — 그 사이트의 하위 프레임이 남아 있는 것으로 친다(제 문서를
/// `about:blank` 로 바꾼 프레임은 제 프로세스에 남는다). 모르게 된 탭(기록이 넘쳤다)은 사이트 0 — 위험.
pub fn taint(browser: c_int, site: u64) Frame {
    return .{ .browser = browser, .main = false, .site = site };
}

/// 한 탭의 「하위 프레임이 가졌던 사이트」 기록(V-A7 — `taint` 로 넘긴다). 적대 검증 v20c N2: 예전 기록(탭마다 8 칸, 이동 홉마다 적고 탭이 닫힐
/// 때까지)은 쿠키 맞추기 iframe 의 리다이렉트 홉 아홉만으로 넘쳐 「모름 → 위험」 으로 굳었고, 에이전트 사이트를 한 번 적으면 주 문서가 바뀌어도
/// 남아 그 탭을 닫을 때까지 **모든** CPU 조건이 `process_shared` 로 거절됐다(5/5). 그래서:
///   - **커밋한 문서만** 적는다(`on_load_start` — 리다이렉트 홉은 문서를 만들지 않는다).
///   - 기록은 **주 문서마다**다: 주 프레임이 다른 문서로 커밋하면 새 기록을 연다. bfcache 되살림은 옛 하위 프레임(제 문서를 `about:blank` 로
///     바꾼 것까지)을 그 프로세스째 되돌리므로, 뒤로·앞으로(`back_forward`)의 커밋은 그 주소의 옛 기록으로 돌아가고 없으면(밀려났다)
///     「모름」 으로 시작한다. 같은 주소로 다시 가면(새로고침·같은 주소 이동) 그 주소의 기록을 잇는다(같은 주소의 옛 문서가 기록에 남아
///     되살아날 수 있다 — 더 거절하는 쪽). 주소 `docs` 개를 기억하고 가장 오래 쓰지 않은 것을 민다.
///   - 칸(`per_doc`)이 넘치면 **지금 있는 프레임 기준으로 다시 센다**: 열린 탭의 맨 위 사이트와 같은 기록(CPU 를 거는 탭 T 의 사이트가 될 수 있는
///     것 — A7-1 의 「제 문서를 바꾼 같은 사이트 iframe」 은 이것이다)을 먼저 남기고, 남은 칸에 지금 있는 하위 프레임의 사이트를 넣는다. 열린
///     탭의 맨 위 사이트가 아닌 기록은 버려도 된다 — 따로 연 탭의 주 프레임은 같은 사이트여도 다른 프로세스였다(c1, 상한을 넘긴 116 프로세스
///     에서도 — v20c c12). 그 사이트들만으로도 넘칠 때만 「모름」 이고, 다음 커밋·주 문서 커밋이 다시 센다.
pub const SubSites = struct {
    pub const per_doc = 16;
    pub const docs = 4;

    const Doc = struct {
        /// 주 문서 주소의 해시(0 = 빈 칸).
        url: u64 = 0,
        sites: [per_doc]u64 = @splat(0),
        len: u8 = 0,
        /// 뒤로·앞으로로 왔는데 그 주소의 기록이 없었다 — 되살아난 하위 프레임이 가졌던 사이트를 모른다(그 문서 동안).
        history_lost: bool = false,
        /// 마지막으로 다시 셀 때 열린 탭의 맨 위 사이트와 같은 기록만으로도 칸이 넘쳤다(다음 커밋이 다시 센다).
        overflow: bool = false,
        used: u32 = 0,
    };

    slots: [docs]Doc = @splat(.{}),
    cur: ?usize = null,
    tick: u32 = 0,

    /// 지금 주 문서의 기록(없으면 빈 것).
    pub fn sites(self: *const SubSites) []const u64 {
        const i = self.cur orelse return &.{};
        return self.slots[i].sites[0..self.slots[i].len];
    }

    /// 지금 주 문서에서 놓친 사이트가 있을 수 있다(위험으로 친다 — `taint(_, 0)`).
    pub fn lost(self: *const SubSites) bool {
        const i = self.cur orelse return false;
        return self.slots[i].history_lost or self.slots[i].overflow;
    }

    /// 주 프레임이 새 문서를 커밋했다(`url` — 그 주소의 해시, 0 이 아니게). `back_forward` 면 기록에서 되살아날 수 있다.
    pub fn mainCommitted(self: *SubSites, url: u64, back_forward: bool) void {
        self.tick +%= 1;
        for (&self.slots, 0..) |*d, i| if (d.url != 0 and d.url == url) {
            d.used = self.tick;
            self.cur = i;
            return;
        };
        // 빈 칸, 없으면 가장 오래 쓰지 않은 칸.
        var victim: usize = 0;
        var best_age: u32 = 0;
        for (self.slots, 0..) |d, i| {
            if (d.url == 0) {
                victim = i;
                break;
            }
            const age = self.tick -% d.used;
            if (age > best_age) {
                best_age = age;
                victim = i;
            }
        }
        // 뒤로·앞으로인데 그 주소의 기록이 없다(밀려났다) — 되살아난 하위 프레임이 가졌던 사이트를 모른다.
        self.slots[victim] = .{ .url = url, .used = self.tick, .history_lost = back_forward };
        self.cur = victim;
    }

    /// 하위 프레임이 사이트 `site`(0 이 아니게)의 문서를 커밋했다. `present` 는 그 탭에 지금 있는 하위 프레임의 사이트들, `tops` 는 열린 탭들의
    /// 맨 위 사이트들(넘칠 때 다시 세는 데만 쓴다).
    pub fn subCommitted(self: *SubSites, site: u64, present: []const u64, tops: []const u64) void {
        if (site == 0) return;
        if (self.cur == null) self.mainCommitted(1, false); // 주 문서 커밋을 못 봤다(첫 문서 — 등록 전) — 이름 없는 기록 하나
        const d = &self.slots[self.cur.?];
        if (std.mem.indexOfScalar(u64, d.sites[0..d.len], site) != null) return;
        if (d.len < per_doc) {
            d.sites[d.len] = site;
            d.len += 1;
            return;
        }
        // 넘친다 — 지금 있는 프레임 기준으로 다시 센다(열린 탭의 맨 위 사이트와 같은 기록이 먼저).
        var next: [per_doc]u64 = undefined;
        var n: usize = 0;
        var over = false;
        const Add = struct {
            fn add(buf: *[per_doc]u64, len: *usize, x: u64) bool {
                if (x == 0 or std.mem.indexOfScalar(u64, buf[0..len.*], x) != null) return true;
                if (len.* == per_doc) return false;
                buf[len.*] = x;
                len.* += 1;
                return true;
            }
        };
        for (d.sites[0..d.len]) |x| if (std.mem.indexOfScalar(u64, tops, x) != null) {
            if (!Add.add(&next, &n, x)) over = true;
        };
        if (std.mem.indexOfScalar(u64, tops, site) != null and !Add.add(&next, &n, site)) over = true;
        // 아래는 칸이 남는 만큼만(못 넣어도 「모름」 이 아니다 — 열린 탭의 맨 위 사이트가 아니다).
        _ = Add.add(&next, &n, site);
        for (present) |x| _ = Add.add(&next, &n, x);
        @memcpy(d.sites[0..n], next[0..n]);
        d.len = @intCast(n);
        d.overflow = over;
    }
};

/// 호스트의 사이트 어림(소문자로 본다 — 부른 쪽이 해시에 넣기 전에 `siteHash`).
pub fn siteKey(host: []const u8) []const u8 {
    var h = host;
    while (h.len > 0 and h[h.len - 1] == '.') h = h[0 .. h.len - 1];
    if (h.len == 0) return h;
    if (h[0] == '[' or isIpv4(h)) return h; // IP 주소는 통째
    var dots: usize = 0;
    var i = h.len;
    while (i > 0) : (i -= 1) {
        if (h[i - 1] == '.') {
            dots += 1;
            if (dots == 2) return h[i..];
        }
    }
    return h;
}

fn isIpv4(h: []const u8) bool {
    var parts: usize = 0;
    var it = std.mem.splitScalar(u8, h, '.');
    while (it.next()) |p| {
        if (p.len == 0 or p.len > 3) return false;
        for (p) |c| if (!std.ascii.isDigit(c)) return false;
        parts += 1;
    }
    return parts == 4;
}

/// 사이트 해시(0 아님 — 0 은 「모름」). 빈 호스트는 0.
pub fn siteHash(host: []const u8) u64 {
    const key = siteKey(host);
    if (key.len == 0) return 0;
    var buf: [256]u8 = undefined;
    const n = @min(key.len, buf.len);
    for (key[0..n], buf[0..n]) |c, *o| o.* = std.ascii.toLower(c);
    const h = std.hash.Wyhash.hash(0x9e2, buf[0..n]);
    return if (h == 0) 1 else h;
}

/// `b` 가 T 가족인가 — T 자신이거나 연 탭 사슬이 T 에 닿는다(깊이 상한 32 — 고리를 끊는다).
pub fn inFamily(frames: []const Frame, t: c_int, b: c_int) bool {
    var cur = b;
    var depth: usize = 0;
    while (depth < 32) : (depth += 1) {
        if (cur == t) return true;
        const opener = openerOf(frames, cur) orelse return false;
        if (opener == 0) return false;
        cur = opener;
    }
    return false;
}

/// `b` 가 든 연 탭 사슬의 뿌리(연 탭이 없거나 목록에 없는 탭 — 깊이 상한 32). 같은 뿌리면 한 가족이다(적대 검증 v20c N4 — 사람이 가족의 한 탭을
/// 몰면 그 가족 어느 탭에 걸린 CPU 조건이든 같은 렌더러 프로세스로 그 탭을 느리게 한다).
pub fn familyRoot(frames: []const Frame, b: c_int) c_int {
    var path: [32]c_int = undefined;
    var n: usize = 0;
    var cur = b;
    while (n < path.len) {
        path[n] = cur;
        n += 1;
        const opener = openerOf(frames, cur) orelse return cur;
        if (opener == 0) return cur;
        // 고리(연 탭 번호가 되돌아온다) — 고리 위의 가장 작은 번호를 뿌리로(어느 탭에서 시작해도 같게).
        if (std.mem.indexOfScalar(c_int, path[0..n], opener)) |at| return std.mem.min(c_int, path[at..n]);
        cur = opener;
    }
    return cur;
}

fn openerOf(frames: []const Frame, b: c_int) ?c_int {
    for (frames) |f| if (f.browser == b and f.main) return f.opener;
    return null;
}

/// T(맨 위 사이트 `t_site`)에 CPU 줄이기를 걸면 가족 밖의 프레임이 함께 느려질 수 있는가. 사이트를 모르면(0) 가를 수 없다 — T 의 것이든 가족
/// 밖 프레임의 것이든 위험으로 본다.
pub fn risky(frames: []const Frame, t: c_int, t_site: u64) bool {
    if (t_site == 0) return true;
    for (frames) |f| {
        if (f.site != 0 and f.site != t_site) continue;
        if (inFamily(frames, t, f.browser)) continue;
        if (f.site == 0) {
            // 사이트를 모르는 가족 밖 하위 프레임·연 탭 — 그 문서를 시작한 쪽의 프로세스에 든다(T 의 사이트였을 수 있다 — A7-1). 연 탭이 없는 주
            // 프레임(사용자가 새로 연 빈 탭·data: 탭)은 제 프로세스다.
            if (!f.main or f.opener != 0) return true;
            continue;
        }
        if (!f.main) return true; // 가족 밖 같은 사이트 하위 프레임 — T 의 프로세스에 들 수 있다(o1)
        if (f.opener != 0) return true; // 가족 밖 연 탭의 같은 사이트 주 프레임 — 연 프레임의 프로세스를 함께 쓸 수 있다(a1_pop)
    }
    return false;
}

const testing = std.testing;

test "W9e②: 사이트 어림 — 마지막 두 마디, IP·한 마디는 통째, 대소문자·끝 점 무시" {
    try testing.expectEqualStrings("example.com", siteKey("a.b.example.com"));
    try testing.expectEqualStrings("example.com", siteKey("example.com."));
    try testing.expectEqualStrings("127.0.0.1", siteKey("127.0.0.1"));
    try testing.expectEqualStrings("localhost", siteKey("localhost"));
    try testing.expectEqualStrings("[::1]", siteKey("[::1]"));
    try testing.expectEqual(siteHash("A.Example.COM"), siteHash("b.example.com"));
    try testing.expect(siteHash("a.test") != siteHash("b.test"));
    try testing.expectEqual(@as(u64, 0), siteHash(""));
    try testing.expectEqual(siteHash("1.2.3"), siteHash("9.2.3")); // 넷이 아닌 숫자 마디는 IP 가 아니다 — 두 마디 어림(2.3)
    try testing.expect(siteHash("1.2.3.4") != siteHash("9.2.3.4")); // IP 는 통째
}

test "W9e②: 위험 — 가족 밖 같은 사이트 하위 프레임(사용자 탭의 iframe), 가족 밖 연 탭의 같은 사이트 주 프레임" {
    const a = siteHash("127.0.0.1");
    const b = siteHash("localhost");
    // T=1(a), 사용자 탭 2(b) 안에 a iframe.
    const user_iframe = [_]Frame{
        .{ .browser = 1, .main = true, .site = a },
        .{ .browser = 2, .main = true, .site = b },
        .{ .browser = 2, .main = false, .site = a },
    };
    try testing.expect(risky(&user_iframe, 1, a));
    // 사용자 탭 2(b)의 a iframe 이 연 팝업 3(a, opener 2).
    const user_popup = [_]Frame{
        .{ .browser = 1, .main = true, .site = a },
        .{ .browser = 2, .main = true, .site = b },
        .{ .browser = 3, .main = true, .site = a, .opener = 2 },
    };
    try testing.expect(risky(&user_popup, 1, a));
    // 모르는 사이트의 T 는 가를 수 없다.
    try testing.expect(risky(&user_iframe, 1, 0));
}

test "W9e②: 위험이 아님 — 따로 연 같은 사이트 탭, T 의 다른 사이트 iframe, T 가 연 팝업(손자까지)과 그 하위 프레임, 다른 사이트" {
    const a = siteHash("a.test");
    const b = siteHash("b.test");
    const frames = [_]Frame{
        .{ .browser = 1, .main = true, .site = a },
        .{ .browser = 1, .main = false, .site = b }, // T 의 다른 사이트 OOPIF(느려지지 않는다 — c1)
        .{ .browser = 4, .main = true, .site = a }, // 따로 연 같은 사이트 탭(다른 프로세스 — c1)
        .{ .browser = 5, .main = true, .site = a, .opener = 1 }, // T 가 연 팝업
        .{ .browser = 6, .main = true, .site = a, .opener = 5 }, // 팝업이 연 팝업(가족)
        .{ .browser = 6, .main = false, .site = a }, // 가족의 하위 프레임
        .{ .browser = 7, .main = true, .site = b, .opener = 4 }, // 다른 사이트 연 탭
        .{ .browser = 7, .main = false, .site = b },
    };
    try testing.expect(!risky(&frames, 1, a));
    try testing.expect(inFamily(&frames, 1, 6));
    try testing.expect(!inFamily(&frames, 1, 4));
    // 연 탭 고리는 끊는다.
    const loop = [_]Frame{ .{ .browser = 8, .main = true, .site = a, .opener = 9 }, .{ .browser = 9, .main = true, .site = a, .opener = 8 } };
    try testing.expect(!inFamily(&loop, 1, 8));
}

test "W9e② A7-1: 사이트를 모르는 가족 밖 하위 프레임·연 탭은 위험(blob·data 로 바뀐 사용자 iframe), 가족 안·연 탭 없는 주 프레임은 아니다" {
    const a = siteHash("127.0.0.1");
    const b = siteHash("localhost");
    // 사용자 탭 2(b) 안의 iframe 이 제 문서를 data: 로 바꿨다(사이트 0) — T 의 프로세스에 남아 있을 수 있다.
    const data_iframe = [_]Frame{
        .{ .browser = 1, .main = true, .site = a },
        .{ .browser = 2, .main = true, .site = b },
        .{ .browser = 2, .main = false, .site = 0 },
    };
    try testing.expect(risky(&data_iframe, 1, a));
    // 가족 밖 연 탭의 주 프레임이 사이트 0(about:blank 팝업) — 연 쪽의 프로세스.
    const blank_popup = [_]Frame{
        .{ .browser = 1, .main = true, .site = a },
        .{ .browser = 3, .main = true, .site = 0, .opener = 2 },
        .{ .browser = 2, .main = true, .site = b },
    };
    try testing.expect(risky(&blank_popup, 1, a));
    // 가족 안의 사이트 0 하위 프레임·팝업, 연 탭 없는 사이트 0 주 프레임(사용자가 연 빈 탭)은 위험이 아니다.
    const fine = [_]Frame{
        .{ .browser = 1, .main = true, .site = a },
        .{ .browser = 1, .main = false, .site = 0 },
        .{ .browser = 5, .main = true, .site = 0, .opener = 1 },
        .{ .browser = 5, .main = false, .site = 0 },
        .{ .browser = 6, .main = true, .site = 0 },
        .{ .browser = 7, .main = true, .site = b },
        .{ .browser = 7, .main = false, .site = b },
    };
    try testing.expect(!risky(&fine, 1, a));
}

test "W9e② A7-1: blob:·filesystem: 은 안쪽 주소(스킴 대소문자 무시), 다른 스킴·짧은 글은 그대로" {
    const u16s = std.unicode.utf8ToUtf16LeStringLiteral;
    try testing.expectEqualSlices(u16, u16s("http://127.0.0.1:9/x"), innerUrl16(u16s("blob:http://127.0.0.1:9/x")));
    try testing.expectEqualSlices(u16, u16s("https://a.test/temporary/f"), innerUrl16(u16s("FileSystem:https://a.test/temporary/f")));
    try testing.expectEqualSlices(u16, u16s("BLOB:"), innerUrl16(u16s("BLOB:BLOB:"))); // 한 겹만
    try testing.expectEqualSlices(u16, u16s("data:text/html,x"), innerUrl16(u16s("data:text/html,x")));
    try testing.expectEqualSlices(u16, u16s("blob"), innerUrl16(u16s("blob")));
    try testing.expectEqualSlices(u16, u16s("xblob:"), innerUrl16(u16s("xblob:"))); // 앞에서만
}

test "W9e② V-A7: 출처를 물려받는 주소 — about:blank·about:srcdoc(뒤 ?·#)·javascript:·빈 주소, 대소문자 무시; data:·다른 about:·http 는 아니다" {
    const u16s = std.unicode.utf8ToUtf16LeStringLiteral;
    for ([_][]const u16{ u16s(""), u16s("about:blank"), u16s("ABOUT:BLANK"), u16s("about:blank#x"), u16s("about:blank?a"), u16s("about:srcdoc"), u16s("javascript:''"), u16s("JavaScript:void(0)") }) |u| try testing.expect(inheritsOrigin16(u));
    for ([_][]const u16{ u16s("data:text/html,x"), u16s("about:blankx"), u16s("about:version"), u16s("http://a.test/"), u16s("blob:http://a.test/x"), u16s("about:"), u16s("javascript") }) |u| try testing.expect(!inheritsOrigin16(u));
}

test "W9e② V-A7: 다른 사이트 사용자 탭의 물려받는 iframe 은 위험이 아니다 — 주 프레임에서 물려받으면 그 주 프레임 자리, 남의 OOPIF 에서 물려받으면 그 사이트" {
    const a = siteHash("127.0.0.1");
    const b = siteHash("localhost");
    // T=1(a). 사용자 탭 2(b)의 빈 iframe·srcdoc·about:blank+document.write(부모 = 주 프레임 b).
    const blank_in_user = [_]Frame{
        .{ .browser = 1, .main = true, .site = a },
        .{ .browser = 2, .main = true, .site = b },
        inherited(2, true, b, 0),
        inherited(2, true, b, 0),
    };
    try testing.expect(!risky(&blank_in_user, 1, a));
    // 같은 사이트(a) 사용자 탭(연 탭 없음 — 다른 프로세스, c1)의 빈 iframe 도 그 탭 자리다.
    const blank_in_same_site_tab = [_]Frame{
        .{ .browser = 1, .main = true, .site = a },
        .{ .browser = 3, .main = true, .site = a },
        inherited(3, true, a, 0),
    };
    try testing.expect(!risky(&blank_in_same_site_tab, 1, a));
    // 사용자 탭 안의 a iframe(가족 밖 — 이미 위험)이 품은 빈 iframe 도 a 의 하위 프레임 — 그 iframe 을 지워도(바깥 a iframe 없이) 위험으로 남는다.
    const blank_under_a = [_]Frame{
        .{ .browser = 1, .main = true, .site = a },
        .{ .browser = 2, .main = true, .site = b },
        inherited(2, false, a, 0),
    };
    try testing.expect(risky(&blank_under_a, 1, a));
    // 가족 밖 연 탭(about:blank 팝업 — opener 있음)에서 물려받은 빈 iframe 은 그 연 탭의 주 프레임처럼 — 사이트 0 이면 위험.
    const blank_in_popup = [_]Frame{
        .{ .browser = 1, .main = true, .site = a },
        .{ .browser = 4, .main = true, .site = 0, .opener = 2 },
        inherited(4, true, 0, 2),
    };
    try testing.expect(risky(&blank_in_popup, 1, a));
}

test "W9e② V-A7: 제 문서를 물려받는 주소로 바꾼 a iframe 이 있던 탭은 a 하위 프레임이 남은 것으로(A7-1 이 about:blank 로 새지 않게), 다른 사이트면 아니다, 모르면 위험" {
    const a = siteHash("127.0.0.1");
    const b = siteHash("localhost");
    const self_blank = [_]Frame{
        .{ .browser = 1, .main = true, .site = a },
        .{ .browser = 2, .main = true, .site = b },
        inherited(2, true, b, 0), // 지금은 about:blank — 부모 자리로 보이지만
        taint(2, a), // 앞 문서가 a 였다
    };
    try testing.expect(risky(&self_blank, 1, a));
    const other_blank = [_]Frame{
        .{ .browser = 1, .main = true, .site = a },
        .{ .browser = 2, .main = true, .site = b },
        inherited(2, true, b, 0),
        taint(2, b), // 같은 사이트 iframe 이 제 문서를 지웠다 — 사용자 탭 자리
    };
    try testing.expect(!risky(&other_blank, 1, a));
    const unknown = [_]Frame{
        .{ .browser = 1, .main = true, .site = a },
        .{ .browser = 2, .main = true, .site = b },
        taint(2, 0), // 기록이 넘쳤다
    };
    try testing.expect(risky(&unknown, 1, a));
    // 가족(T 자신)의 표시는 상관없다.
    const own = [_]Frame{ .{ .browser = 1, .main = true, .site = a }, taint(1, a), inherited(1, true, a, 0) };
    try testing.expect(!risky(&own, 1, a));
}

test "W9e② v20c N2: 하위 프레임 기록은 주 문서마다 — 새 문서는 새 기록, 뒤로·앞으로는 그 주소의 옛 기록(없으면 모름), 같은 주소는 잇는다" {
    const a = siteHash("127.0.0.1");
    const x = siteHash("x.test");
    var t: SubSites = .{};
    try testing.expectEqual(@as(usize, 0), t.sites().len);
    try testing.expect(!t.lost());
    t.mainCommitted(100, false);
    t.subCommitted(a, &.{a}, &.{a});
    try testing.expectEqualSlices(u64, &.{a}, t.sites());
    // 다른 문서로 — 새 기록(에이전트 사이트 표시가 남지 않는다).
    t.mainCommitted(200, false);
    try testing.expectEqual(@as(usize, 0), t.sites().len);
    t.subCommitted(x, &.{x}, &.{a});
    // 뒤로 — 옛 문서의 기록이 돌아온다(bfcache 가 제 문서를 about:blank 로 바꾼 a iframe 을 되살릴 수 있다).
    t.mainCommitted(100, true);
    try testing.expectEqualSlices(u64, &.{a}, t.sites());
    try testing.expect(!t.lost());
    // 같은 주소로 다시(새로고침) — 그 기록을 잇는다.
    t.mainCommitted(200, false);
    try testing.expectEqualSlices(u64, &.{x}, t.sites());
    // 기억하는 주소는 넷 — 밀려난 주소로 뒤로 가면 모름(위험), 새로 간 주소는 아니다.
    t.mainCommitted(300, false);
    t.mainCommitted(400, false);
    t.mainCommitted(500, false); // 가장 오래 쓰지 않은 100 이 밀린다
    t.mainCommitted(100, true);
    try testing.expect(t.lost());
    try testing.expectEqual(@as(usize, 0), t.sites().len);
    t.mainCommitted(600, false);
    try testing.expect(!t.lost());
    // 같은 사이트는 한 칸, 사이트 0 은 적지 않는다.
    t.subCommitted(x, &.{}, &.{});
    t.subCommitted(x, &.{}, &.{});
    t.subCommitted(0, &.{}, &.{});
    try testing.expectEqualSlices(u64, &.{x}, t.sites());
    // 주 문서 커밋을 못 본 첫 문서도 기록한다.
    var u: SubSites = .{};
    u.subCommitted(a, &.{}, &.{});
    try testing.expectEqualSlices(u64, &.{a}, u.sites());
}

test "W9e② v20c N2: 칸이 넘치면 지금 있는 프레임 기준으로 다시 센다 — 열린 탭의 맨 위 사이트와 같은 기록을 먼저 남기고 「모름」 으로 굳지 않는다" {
    const a = siteHash("127.0.0.1");
    var t: SubSites = .{};
    t.mainCommitted(1, false);
    // 에이전트 사이트 iframe 하나(제 문서를 about:blank 로 바꿨다 — 지금 있는 사이트 목록에는 없다) + 다른 사이트 하위 프레임 15 개.
    t.subCommitted(a, &.{}, &.{a});
    var others: [40]u64 = undefined;
    for (&others, 0..) |*o, i| {
        var hb: [32]u8 = undefined;
        o.* = siteHash(std.fmt.bufPrint(&hb, "s{d}.test", .{i}) catch unreachable);
    }
    for (others[0 .. SubSites.per_doc - 1]) |o| t.subCommitted(o, &.{}, &.{a});
    try testing.expectEqual(@as(usize, SubSites.per_doc), t.sites().len);
    // 열일곱째 — 지금 있는 것은 그 셋뿐이다. 다시 센 기록: 에이전트 사이트(열린 탭의 맨 위) + 새 사이트 + 지금 있는 셋.
    const present = [_]u64{ others[0], others[1], others[20] };
    t.subCommitted(others[20], &present, &.{a});
    try testing.expect(!t.lost());
    try testing.expect(std.mem.indexOfScalar(u64, t.sites(), a) != null);
    try testing.expect(std.mem.indexOfScalar(u64, t.sites(), others[20]) != null);
    try testing.expect(std.mem.indexOfScalar(u64, t.sites(), others[5]) == null); // 지나간 사이트는 버렸다
    try testing.expectEqual(@as(usize, 4), t.sites().len);
    // 지금 있는 것이 칸보다 많아도 「모름」 이 아니다 — 열린 탭의 맨 위 사이트가 아닌 것은 넣을 수 있는 만큼만.
    t.mainCommitted(2, false);
    for (others[0..SubSites.per_doc]) |o| t.subCommitted(o, &.{}, &.{a});
    t.subCommitted(others[30], &others, &.{a});
    try testing.expect(!t.lost());
    try testing.expectEqual(@as(usize, SubSites.per_doc), t.sites().len);
    // 열린 탭의 맨 위 사이트와 같은 기록만으로도 넘치면 모름 — 다음 커밋에 다시 센다(열린 탭이 줄면 풀린다).
    t.mainCommitted(3, false);
    for (others[0..SubSites.per_doc]) |o| t.subCommitted(o, &.{}, &others);
    t.subCommitted(others[30], &.{}, &others);
    try testing.expect(t.lost());
    t.subCommitted(others[31], &.{}, &.{a});
    try testing.expect(!t.lost());
}

test "W9e② v20c N4: 연 탭 사슬의 뿌리 — 팝업·손자 팝업은 연 탭과 같은 뿌리, 따로 연 탭·닫힌 연 탭·고리" {
    const frames = [_]Frame{
        .{ .browser = 1, .main = true, .site = 1 },
        .{ .browser = 5, .main = true, .site = 1, .opener = 1 }, // 1 이 연 팝업
        .{ .browser = 6, .main = true, .site = 1, .opener = 5 }, // 팝업이 연 팝업
        .{ .browser = 7, .main = true, .site = 1, .opener = 1 }, // 1 의 다른 팝업
        .{ .browser = 4, .main = true, .site = 1 }, // 따로 연 탭
        .{ .browser = 9, .main = true, .site = 1, .opener = 3 }, // 연 탭(3)이 이미 닫혔다
        .{ .browser = 8, .main = true, .site = 1, .opener = 10 },
        .{ .browser = 10, .main = true, .site = 1, .opener = 8 }, // 고리
    };
    try testing.expectEqual(@as(c_int, 1), familyRoot(&frames, 1));
    try testing.expectEqual(@as(c_int, 1), familyRoot(&frames, 6));
    try testing.expectEqual(@as(c_int, 1), familyRoot(&frames, 7));
    try testing.expectEqual(@as(c_int, 4), familyRoot(&frames, 4));
    try testing.expectEqual(@as(c_int, 3), familyRoot(&frames, 9)); // 닫힌 연 탭의 번호가 뿌리 — 같은 연 탭의 다른 팝업과 한 가족
    try testing.expectEqual(@as(c_int, 8), familyRoot(&frames, 8)); // 고리는 끊는다 — 어느 쪽에서 시작해도 같은 뿌리
    try testing.expectEqual(@as(c_int, 8), familyRoot(&frames, 10));
}
