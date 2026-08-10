//! control_capability — 컨트롤 플레인 **capability fd 인가 코어**(L2 순수, OS-중립).
//! Track C slice 1e. 단일 출처: docs/control-plane-security.md §8.3(capability 종류 + §6 line 111 method↔scope 매핑)·
//! §8.5(capability 발급: `hash(nonce) -> {surface_id, generation, scopes, expires_at?, revoked}`, constant-time
//! 비교, fd payload magic/version, **headline 위협: capability fd는 셸 서브트리 ambient grant**)·§11(slice 1e).
//!
//! **1a/1c/1d와의 관계**: 1a(control_plane.zig)=wire 프리미티브, 1c(control_surface.zig)=Surface 엔티티 DTO +
//! read-only 응답 직렬화 + `MetadataScope` 판정, 1d(control_dispatch.zig)=바이트→바이트 라우터가 `(caller_surface_id,
//! scope)`를 **인자 주입**받아 판정만 한다. **1e는 그 주입값을 채우는 코어**다: capability nonce → `(surface_id,
//! generation, scope)`로 resolve. 즉 1d의 순수 라우터가 소비할 `caller_surface_id`·`MetadataScope`를 1e가 발급 판정한다.
//!
//! **범위(1e 헤드리스 코어 = 순수 L2 인가, fd 상속 실측은 제외)**:
//!   1. capability 레코드/store: `hash(nonce)` 키로 `Capability{surface_id, generation, scope, expires_at?, revoked}`
//!      저장. **raw nonce는 저장 안 함**(SHA-256 hash만). insert(fd 발급 정책 게이트)·`lookupByNonce`(constant-time
//!      hash 비교)·revoke(surface close·명시·TTL·generation).
//!   2. 인가 판정(순수): `authorize(cap, requested_surface_id, requested_generation, method, now) -> Decision`.
//!      scope↔method 매핑(§8.3/§6 line 111), surface·generation 일치, TTL 만료, revoked. deny는 이유별(내부).
//!   3. scope→MetadataScope 연결: capability의 `metadata:{self|window|all}`을 `window_membership.MetadataScope`로
//!      resolve해 1c/1d가 소비. `resolve(...) -> Resolution{granted{surface_id,generation,scope}|unauthorized}`.
//!   4. fd payload 포맷(순수 파싱/직렬화): magic/version/nonce header. 정상·손상·버전불일치 → 명확한 에러(§8.5
//!      "capability-fd-invalid").
//!   5. §8.5 정책 인코딩(타입/함수 레벨): read-output은 default grant 아님(TTL 필수)·single-scope 강제(`Scope`는
//!      단일 값)·write/lifecycle은 이 상속 fd 경로로 발급 금지(`allowedViaInheritedFd`).
//!
//! **이 순수 코어의 범위 밖(다른 레이어가 소유)**: 실제 fd 발급/상속(0600 unlinked fd·MARU_CONTROL_CAP_FD·pread·
//! CLOEXEC·셸별 상속 실측 = 1e-confirm/후속), nonce 랜덤 생성의 실 crypto(테스트는 고정 nonce), self-origin(§8.4=1g),
//! redaction 실측. **auth handshake 라이브 배선은 1e-core에서 완료**: 첫 auth 프레임의 `cap_nonce`(control_plane
//! `parseAuthFrame`) → `control_dispatch.dispatchAuthenticated`가 이 코어의 `resolve`를 호출 → `(caller, scope)` 발급
//! (control_server가 nonce를 메인 marshal로 나르고 app_host_abi가 라이브 store로 resolve). 이 파일은 그 배선이 소비하는
//! **순수 인가 판정**만 소유한다(소켓/fd/스레드는 L4). fd/socket이 얽히면 코어는 순수로 둔다.
//!
//! **§8.5 headline 위협(주석 인용)**: capability fd는 CLI만이 아니라 **셸이 exec하는 모든 명령**(사용자가 실행한
//! curl·python·untrusted 자동화 포함 — 위협모델이 격리하려던 바로 그 저권한 코드)이 `pread(MARU_CONTROL_CAP_FD, 0)`
//! 로 같은 nonce를 얻는 **서브트리 전체 ambient grant**다. nonce는 bytes라 SCM_RIGHTS 없이 forward도 된다. 따라서
//! "fd 상속 = 프로세스 신원 증명"을 폐기한다: read-output은 짧은 TTL만, write/lifecycle은 이 경로로 **절대** 발급 금지.
//!
//! **L2 순수:** std + control_plane(1a) + window_membership(M0b)만 import한다(app/pty/platform import 0 —
//! tests/boundary/imports.zig가 강제). OS 타입 0. crypto는 std.crypto(SHA-256·timing_safe)만.

const std = @import("std");
const cp = @import("control_plane.zig");
const wm = @import("window_membership.zig");

// ── nonce·hash 상수(§8.5) ─────────────────────────────────────────────────────────────────────────────────
/// capability nonce = 256-bit random(§8.5). **실 crypto-random 생성은 1e 범위 밖**(L4/후속) — 이 순수 코어는
/// 주입된 nonce를 hash·비교만 한다(테스트는 고정 nonce).
pub const nonce_len = 32;
pub const Nonce = [nonce_len]u8;

/// 5f-4a 세션 cap 누적 상한(§9.5.6 ③). 한 지속 세션이 `auth.grant`로 축적할 수 있는 cap 수 — 실무상 scope 수만큼(browser·
/// browser_storage·metadata 등 소수)이라 8이면 충분. 연결(serveConnection)이 이 상한으로 bound하고, dispatch의 resolve 버퍼도 이 크기.
pub const max_session_caps: usize = 8;
/// server-side 저장 키 = SHA-256(nonce). **raw nonce는 절대 저장하지 않는다**(§8.5).
pub const Hash = [std.crypto.hash.sha2.Sha256.digest_length]u8;

/// nonce의 SHA-256을 계산한다. store는 이 hash만 보관한다(raw nonce 미저장 — §8.5).
pub fn hashNonce(nonce: Nonce) Hash {
    var out: Hash = undefined;
    std.crypto.hash.sha2.Sha256.hash(&nonce, &out, .{});
    return out;
}

// ── scope 모델(§8.3) ──────────────────────────────────────────────────────────────────────────────────────
/// capability scope 분류(§8.3). method↔scope 매핑(§6 line 111)이 이 category로 판정한다. metadata의 sub-scope
/// (self|window|all)는 `Scope.metadata`가 `wm.MetadataScope`로 실어 나른다(1c/1d가 소비하는 그 타입).
pub const ScopeClass = enum { metadata, bind, read_output, write, lifecycle, browser, browser_storage };

/// 단일 capability scope(§8.5 **single-scope 강제**: capability는 정확히 하나의 scope만 싣는다 — 이 union은 한
/// 값이라 write+lifecycle 같은 복합 grant를 타입 수준에서 만들 수 없다). metadata는 `wm.MetadataScope`를 실어
/// 1c/1d의 scope 판정과 단일 출처를 공유한다(§8.3 "metadata:{self|window|all}").
pub const Scope = union(enum) {
    /// `metadata:{self|window|all}`(§8.3). sub-scope는 1c/1d가 소비하는 `wm.MetadataScope` 그대로.
    metadata: wm.MetadataScope,
    /// `bind`(§8.3 `panel.bindSession`).
    bind,
    /// `read-output`(§8.3 `capture`/`subscribeOutput`). **default grant 아님**(§8.5) — fd 발급 시 TTL 필수.
    read_output,
    /// `write`(§8.3 `send*`). **상속 fd 경로로 발급 금지**(§8.5).
    write,
    /// `lifecycle`(§8.3 `spawn`/`close`/`resize`/`focus`/`panel.open`). **상속 fd 경로로 발급 금지**(§8.5).
    lifecycle,
    /// `browser`(§8.3 `browser.*` — navigate·loadUrl·screenshot·act·subscribe 등 **페이지 조작/관찰**).
    browser,
    /// `browser-storage`(§8.3 D5 — `browser.getCookies` 등 **쿠키/스토리지 열람**). `browser`와 **분리된 peer
    /// scope**(D5): 페이지를 몰 수 있는 cap이 쿠키(인증 토큰)까지 자동으로 새면 안 되므로 별도 grant를 강제한다.
    /// single-scope(§8.5)라 세션이 둘 다 쓰려면 cap 두 개를 누적(§9.5.6 ③ auth.grant).
    browser_storage,

    pub fn class(self: Scope) ScopeClass {
        return switch (self) {
            .metadata => .metadata,
            .bind => .bind,
            .read_output => .read_output,
            .write => .write,
            .lifecycle => .lifecycle,
            .browser => .browser,
            .browser_storage => .browser_storage,
        };
    }

    /// §8.5 **핵심 정책**: 상속 fd 경로로 발급 가능한 scope인가. write/lifecycle은 **절대 금지**(상속 fd로 write가
    /// 새면 same-uid untrusted 코드가 셸에 키 주입 = macOS `TIOCSTI` 제거 후 새로 생기는 권한 — §8.5). 이 둘은
    /// per-request `SCM_RIGHTS` fd-passing 또는 명시 확인 UX로만(1e 범위 밖). metadata·read-output·bind·browser는
    /// 허용하되 read-output은 짧은 TTL을 추가로 요구한다(`validateFdIssuance`). **browser_storage는 금지**(D5):
    /// 쿠키=인증 토큰이라 상속 fd로 새면 same-uid untrusted 코드가 세션 자격증명을 탈취(write/lifecycle과 동급 위험).
    pub fn allowedViaInheritedFd(self: Scope) bool {
        return switch (self.class()) {
            .write, .lifecycle, .browser_storage => false,
            .metadata, .read_output, .bind, .browser => true,
        };
    }
};

// ── method↔scope 매핑(§8.3 / §6 line 111 단일 출처) ────────────────────────────────────────────────────────
/// method 문자열이 요구하는 scope category를 돌려준다(§6 line 111 단일 출처). 알 수 없는/미매핑 method는 null
/// (authorize가 `unknown_method` deny로 접는다 — 미지 method에 grant가 새지 않게). 1a `parseMethod`로 파싱한다.
///
/// 매핑(§6 line 111): `list`/`get`/`subscribe`=metadata, `panel.bindSession`=bind, `capture`/`subscribeOutput`=
/// read-output, `send*`=write, `resize`/`focus`/`close`/`spawn`/`panel.open`=lifecycle, `browser.getCookies`=
/// browser-storage(D5), 나머지 `browser.*`=browser.
pub fn methodRequiredScope(method: []const u8) ?ScopeClass {
    const m = cp.parseMethod(method);
    const rest = m.rest;
    // metadata: sessions.list / session.get / events.subscribe(§7). "events"는 코어 예약 네임스페이스가 아니라
    // (1a CoreNamespace={sessions,session,panel,browser}) namespace 문자열로 매칭한다.
    if (m.core == .sessions and eq(rest, "list")) return .metadata;
    if (m.core == .session and eq(rest, "get")) return .metadata;
    if (eq(m.namespace, "events") and eq(rest, "subscribe")) return .metadata;
    // read-output: session.capture / session.subscribeOutput (send* 프리픽스 검사보다 먼저 — subscribeOutput 보호).
    if (m.core == .session and eq(rest, "capture")) return .read_output;
    if (m.core == .session and eq(rest, "subscribeOutput")) return .read_output;
    // write: session.send*(§6 line 111 와일드카드). sendText/sendKeys 등.
    if (m.core == .session and std.mem.startsWith(u8, rest, "send")) return .write;
    // lifecycle: session.{resize,focus,close,spawn} / panel.open.
    if (m.core == .session and (eq(rest, "resize") or eq(rest, "focus") or eq(rest, "close") or eq(rest, "spawn"))) return .lifecycle;
    if (m.core == .panel and eq(rest, "open")) return .lifecycle;
    // bind: panel.bindSession.
    if (m.core == .panel and eq(rest, "bindSession")) return .bind;
    // browser-storage: browser.getCookies/setCookie/deleteCookie(D4/D5 — 쿠키 read+write는 browser와 분리된 peer
    // scope, 사용자 결정 2026-07-13 read+write 동일 scope). 아래 generic `browser.*`보다 **먼저** 검사해야 쿠키가
    // browser scope로 새지 않는다(§8.3 D5 laundering-hole 방지).
    // clearStorage도 browser_storage(쿠키=토큰까지 comprehensive 삭제라 민감). localStorage(get/set/remove)는 eval 백엔드라
    // exec와 같은 도달=base browser(D5 laundering-hole 불변)로 아래 catch-all에 떨어진다 — 여기 안 넣는다.
    if (m.core == .browser and (eq(rest, "getCookies") or eq(rest, "setCookie") or eq(rest, "deleteCookie") or eq(rest, "clearStorage"))) return .browser_storage;
    // browser.*(§6 line 111 와일드카드) — 나머지 페이지 조작/관찰.
    if (m.core == .browser) return .browser;
    return null;
}

inline fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// ── capability 레코드(§8.5 저장 스키마) ───────────────────────────────────────────────────────────────────
/// server-side capability 레코드(§8.5 `hash(nonce) -> {surface_id, generation, scopes, expires_at?, revoked}`).
/// **§8.5 single-scope 강제**로 `scopes`(복수)가 아니라 단일 `scope`를 담는다 — 1e가 구현하는 fd 경로는 §8.5가
/// single-scope를 못박기 때문(복합 scope는 fd 경로에 없다). store는 `hashNonce(nonce)`를 키로 이 레코드를 보관하고
/// **raw nonce는 저장하지 않는다**.
pub const Capability = struct {
    /// capability가 묶인 surface(앱 전역 unique opaque u64, §3). 발급 시 고정.
    surface_id: u64,
    /// capability가 묶인 generation(defense-in-depth, §3). surface respawn 시 authorize의 generation 검사로 무효화.
    generation: u64,
    /// 단일 scope(§8.5 single-scope). metadata면 sub-scope(self|window|all) 포함.
    scope: Scope,
    /// 절대 만료 시각(주입 `now`와 같은 단위, §8.5). null=만료 없음. read-output은 fd 발급 시 non-null 필수(§8.5).
    expires_at: ?u64 = null,
    /// 취소됨(§8.5 surface close·명시 revoke·generation 변경 시 즉시 무효). authorize가 최우선 확인.
    revoked: bool = false,
};

// ── fd payload 포맷(§8.5 magic/version/nonce) ─────────────────────────────────────────────────────────────
/// fd payload magic(§8.5 "magic/version/header"). 셸 startup script가 같은 fd 번호를 닫거나 재사용해 임의 데이터가
/// 실려도 CLI가 nonce로 오해하지 않게 하는 sentinel(§8.5 "capability-fd-invalid").
pub const fd_magic = [4]u8{ 'M', 'C', 'A', 'P' }; // Maru CAPability
/// fd payload 포맷 버전(§8.5). 버전 skew는 `CapabilityFdVersionMismatch`로 명확히 구별한다.
pub const fd_version: u16 = 1;
/// payload 총 길이 = magic(4) + version(2, LE) + nonce(32) = 38 바이트.
pub const fd_payload_len = fd_magic.len + @sizeOf(u16) + nonce_len;

/// fd payload 파싱 실패(§8.5). 손상/재사용 fd(bad magic·잘못된 길이)와 버전 skew를 구별한다.
pub const FdParseError = error{
    /// magic 불일치 또는 잘못된 길이 → "capability-fd-invalid"(§8.5). 셸이 fd를 닫거나 재사용해 임의 데이터가
    /// 실린 경우. CLI는 이걸 nonce로 오해하지 않고 실패해야 한다.
    CapabilityFdInvalid,
    /// magic은 맞으나 version이 다름 → 버전 skew(GUI↔CLI). invalid와 별개 진단.
    CapabilityFdVersionMismatch,
};

/// nonce를 fd payload 바이트(magic|version|nonce)로 직렬화한다(§8.5). server가 0600 unlinked fd에 쓸 바이트
/// (실 fd 쓰기는 1e 범위 밖 — 이 함수는 순수 바이트만).
pub fn serializeFdPayload(nonce: Nonce) [fd_payload_len]u8 {
    var buf: [fd_payload_len]u8 = undefined;
    @memcpy(buf[0..fd_magic.len], fd_magic[0..]);
    std.mem.writeInt(u16, buf[fd_magic.len..][0..@sizeOf(u16)], fd_version, .little);
    @memcpy(buf[fd_magic.len + @sizeOf(u16) ..], &nonce);
    return buf;
}

/// fd payload 바이트에서 nonce를 파싱한다(§8.5). CLI가 `pread(MARU_CONTROL_CAP_FD, offset 0)`로 읽은 바이트를
/// 검증하는 순수 함수(실 pread는 1e 범위 밖). 길이/magic 불일치 → `CapabilityFdInvalid`(셸이 fd를 닫고 임의
/// 데이터가 실린 경우 nonce로 오해 금지), version 불일치 → `CapabilityFdVersionMismatch`(GUI↔CLI skew). 정상이면
/// nonce 32바이트. **정확한 길이만 허용**(trailing garbage=재사용 fd 신호라 거부).
pub fn parseFdPayload(bytes: []const u8) FdParseError!Nonce {
    if (bytes.len != fd_payload_len) return error.CapabilityFdInvalid;
    var buf: [fd_payload_len]u8 = undefined;
    @memcpy(&buf, bytes[0..fd_payload_len]);
    if (!std.mem.eql(u8, buf[0..fd_magic.len], fd_magic[0..])) return error.CapabilityFdInvalid;
    const version = std.mem.readInt(u16, buf[fd_magic.len..][0..@sizeOf(u16)], .little);
    if (version != fd_version) return error.CapabilityFdVersionMismatch;
    var nonce: Nonce = undefined;
    @memcpy(&nonce, buf[fd_magic.len + @sizeOf(u16) ..]);
    return nonce;
}

// ── §8.5 fd 발급 정책 게이트(타입/함수 레벨 인코딩) ────────────────────────────────────────────────────────
/// fd 경로 발급 정책 위반(§8.5). 상속 fd로 발급하면 안 되는 scope 조합을 store insert 이전에 거부한다.
pub const FdIssueError = error{
    /// write/lifecycle을 상속 fd 경로로 발급 시도(§8.5 절대 금지 — 서브트리 ambient grant + 키 주입 위험).
    ScopeForbiddenViaInheritedFd,
    /// read-output을 TTL 없이 발급 시도(§8.5 read-output은 짧은 TTL one-shot만 — 과거 스크롤백 history 유출 방어).
    ReadOutputRequiresTtl,
    /// nonce는 capability identity다. 같은 nonce 재발급은 stale in-flight가 새 authority로 재인가되는 ABA를 만든다.
    DuplicateNonce,
};

/// §8.5 fd 발급 정책을 한 곳에서 강제한다(store `issueForFd`의 유일한 게이트). (1) write/lifecycle은 상속 fd로
/// 발급 금지, (2) read-output은 expires_at(TTL) 필수, (3) single-scope는 `Scope`가 단일 값이라 구조적으로 강제됨.
pub fn validateFdIssuance(scope: Scope, expires_at: ?u64) FdIssueError!void {
    if (!scope.allowedViaInheritedFd()) return error.ScopeForbiddenViaInheritedFd;
    if (scope.class() == .read_output and expires_at == null) return error.ReadOutputRequiresTtl;
}

// ── capability store(§8.5, constant-time lookup) ──────────────────────────────────────────────────────────
/// `hash(nonce) -> Capability` 저장소(§8.5). raw nonce는 저장하지 않는다(hash만). lookup은 **constant-time**로
/// 모든 엔트리를 비교한다(early-out 없음 — nonce 유효성 timing oracle 방어). capability 수는 per-surface grant라
/// 작아 O(n) 선형 스캔이 적절하다(hashmap 키 조회는 버킷 probing으로 timing이 새므로 배제).
pub const CapabilityStore = struct {
    const Entry = struct { hash: Hash, cap: Capability };

    entries: std.ArrayList(Entry) = .empty,

    pub fn deinit(self: *CapabilityStore, gpa: std.mem.Allocator) void {
        self.entries.deinit(gpa);
    }

    /// **fd 경로 발급 chokepoint**(§8.5). `validateFdIssuance`(정책 게이트)를 통과한 뒤에만 `hashNonce(nonce)`를
    /// 키로 레코드를 저장한다. raw nonce는 저장하지 않는다. 정책 위반은 store에 아무것도 남기지 않고 에러 반환.
    pub fn issueForFd(
        self: *CapabilityStore,
        gpa: std.mem.Allocator,
        nonce: Nonce,
        cap: Capability,
    ) (FdIssueError || std.mem.Allocator.Error)!void {
        try validateFdIssuance(cap.scope, cap.expires_at);
        const hash = hashNonce(nonce);
        var duplicate = false;
        for (self.entries.items) |e| {
            if (std.crypto.timing_safe.eql(Hash, hash, e.hash)) duplicate = true;
        }
        if (duplicate) return error.DuplicateNonce;
        try self.entries.append(gpa, .{ .hash = hash, .cap = cap });
    }

    /// nonce로 capability를 constant-time 조회한다(§8.5). nonce의 SHA-256을 모든 엔트리 hash와 `timing_safe.eql`로
    /// 비교하되 **일치해도 조기 종료하지 않는다**(항상 전체 스캔 — 매치 위치·존재가 timing으로 새지 않게).
    /// revoked/expired 레코드도 그대로 돌려준다(유효성 판정은 `authorize`가 — 없음과 revoked를 구별해 균일
    /// unauthorized로 접기 위해). 없으면 null.
    pub fn lookupByNonce(self: *const CapabilityStore, nonce: Nonce) ?Capability {
        const h = hashNonce(nonce);
        var found: ?Capability = null;
        for (self.entries.items) |e| {
            // timing_safe.eql: 32바이트 hash를 상수 시간 비교(early-out·바이트별 분기 없음).
            if (std.crypto.timing_safe.eql(Hash, h, e.hash)) found = e.cap;
        }
        return found;
    }

    /// 명시 revoke(§8.5 "grant 취소"): nonce에 대응하는 레코드를 revoked로 표시한다. 전체 스캔(early-out 없음).
    /// 매치가 있으면 true. 존재하지 않는 nonce는 false(무동작).
    pub fn revokeByNonce(self: *CapabilityStore, nonce: Nonce) bool {
        const h = hashNonce(nonce);
        var revoked_any = false;
        for (self.entries.items) |*e| {
            if (std.crypto.timing_safe.eql(Hash, h, e.hash)) {
                e.cap.revoked = true;
                revoked_any = true;
            }
        }
        return revoked_any;
    }

    /// surface close revoke(§8.5 "surface close 시 capability는 즉시 무효"): 그 surface에 묶인 모든 capability를
    /// revoked로 표시한다. surface_id는 비밀이 아니므로(§3 monotonic) constant-time 불요. revoke한 개수를 반환.
    pub fn revokeSurface(self: *CapabilityStore, surface_id: u64) usize {
        var n: usize = 0;
        for (self.entries.items) |*e| {
            if (e.cap.surface_id == surface_id and !e.cap.revoked) {
                e.cap.revoked = true;
                n += 1;
            }
        }
        return n;
    }

    /// 현재 저장된 엔트리 수(테스트/관측용).
    pub fn len(self: *const CapabilityStore) usize {
        return self.entries.items.len;
    }
};

// ── 인가 판정(§8.3, 순수 함수) ────────────────────────────────────────────────────────────────────────────
/// deny 이유(§8.3). **내부 진단·테스트 전용** — wire로 나가지 않는다. 균일 `unauthorized`(§8.3 oracle 방지)는
/// `resolve`가 모든 deny를 하나로 접어 만든다.
pub const DenyReason = enum {
    /// revoked=true(§8.5). 최우선 확인.
    revoked,
    /// TTL 만료(now >= expires_at, §8.5).
    expired,
    /// 제시된 anchor surface_id가 capability의 surface_id와 불일치(다른 surface capability 도용 방지).
    surface_mismatch,
    /// 제시된 generation이 capability의 generation과 불일치(§3 respawn 후 옛 capability 무효 — defense-in-depth).
    generation_mismatch,
    /// scope↔method 매핑 불충족(§6 line 111). 예: metadata cap으로 send*(write) 시도.
    scope_insufficient,
    /// method가 어떤 scope에도 매핑되지 않음(미지 method) — grant가 새지 않게 deny.
    unknown_method,
};

/// authorize 결과(§8.3). granted 또는 이유 있는 deny. wire로 나가는 균일 unauthorized는 `resolve`가 만든다.
pub const Decision = union(enum) {
    granted,
    deny: DenyReason,
};

/// capability 하나가 `method` 요청을 인가하는지 판정한다(§8.3, 순수). `requested_surface_id`/`requested_generation`
/// 은 호출자가 제시한 **anchor**(예: `$MARU_SESSION` selector가 가리키는 자기 surface)로, capability가 묶인
/// surface·generation과 일치해야 한다(§8.4의 self-origin selector가 이 값을 채운다 — 실 발급은 1g). session.get의
/// **target** surface(§6 `{id}`)는 여기서 검사하지 않는다 — 그건 1c/1d가 resolved `MetadataScope`로 필터한다.
///
/// 확인 순서(모두 wire에선 균일 unauthorized라 순서가 oracle을 만들지 않는다; 내부 진단만 이유별): revoked →
/// TTL 만료 → surface 일치 → generation 일치 → scope↔method.
pub fn authorize(
    cap: Capability,
    requested_surface_id: u64,
    requested_generation: u64,
    method: []const u8,
    now: u64,
) Decision {
    if (cap.revoked) return .{ .deny = .revoked };
    if (cap.expires_at) |exp| {
        if (now >= exp) return .{ .deny = .expired };
    }
    if (requested_surface_id != cap.surface_id) return .{ .deny = .surface_mismatch };
    if (requested_generation != cap.generation) return .{ .deny = .generation_mismatch };
    const required = methodRequiredScope(method) orelse return .{ .deny = .unknown_method };
    if (cap.scope.class() != required) return .{ .deny = .scope_insufficient };
    return .granted;
}

// ── resolve(§8.3, capability → 주입값) ────────────────────────────────────────────────────────────────────
/// 인가된 grant(§8.3). `surface_id`/`generation`은 capability에서, `scope`는 그대로. 1c/1d는 metadata 메서드에서
/// `metadataScope()`로 `wm.MetadataScope`를 뽑아 `caller_surface_id`(=`surface_id`)와 함께 소비한다.
pub const Granted = struct {
    surface_id: u64,
    generation: u64,
    scope: Scope,

    /// scope가 metadata면 sub-scope(`wm.MetadataScope`), 아니면 null. 1c/1d의 read-only 디스패치가 소비한다
    /// (item 3: capability metadata:{self|window|all} → control_surface MetadataScope 연결).
    pub fn metadataScope(self: Granted) ?wm.MetadataScope {
        return switch (self.scope) {
            .metadata => |m| m,
            else => null,
        };
    }
};

/// resolve 결과(§8.3). granted 또는 **균일 unauthorized**(deny 이유를 노출하지 않는다 — oracle 방지). store 부재·
/// revoked·만료·surface/generation 불일치·scope 불충족·미지 method가 전부 하나의 `.unauthorized`로 접힌다.
pub const Resolution = union(enum) {
    granted: Granted,
    unauthorized,
};

/// nonce + 제시 anchor(surface_id·generation) + method + now로 capability를 resolve한다(§8.3). store lookup
/// (constant-time) → authorize → grant면 `{surface_id, generation, scope}`, 아니면 **균일 unauthorized**. 실
/// 시스템에서 1b 소켓 auth frame이 nonce·selector를 나르고, 이 함수가 1d에 주입할 `(caller_surface_id, scope)`를 만든다.
pub fn resolve(
    store: *const CapabilityStore,
    nonce: Nonce,
    requested_surface_id: u64,
    requested_generation: u64,
    method: []const u8,
    now: u64,
) Resolution {
    const cap = store.lookupByNonce(nonce) orelse return .unauthorized;
    return switch (authorize(cap, requested_surface_id, requested_generation, method, now)) {
        .granted => .{ .granted = .{ .surface_id = cap.surface_id, .generation = cap.generation, .scope = cap.scope } },
        .deny => .unauthorized, // 이유를 버리고 균일 unauthorized로 접는다(§8.3 oracle 방지).
    };
}

/// 5f-4a cap 누적(§9.5.6 ③): 세션이 보유한 **여러** nonce 중 **하나라도 인가하면 granted**(첫 granted 반환). 지속 세션이
/// `auth.grant`로 cap을 누적해 다중 scope(navigate=`browser`+getCookies=`browser_storage`)를 쓰되, **각 cap은 single-scope
/// 불변 유지**(union은 여전히 한 scope). 미인가는 **균일 unauthorized**(어느 cap이 왜 deny됐는지·존재 여부 노출 안 함 — §8.3
/// oracle 방지, `resolve`와 동형). `nonces` 빈=cap 없음=unauthorized. anchor/gen/method/now는 모든 cap에 동일 적용.
///
/// **⚠️ 22차 [2] 한계**: 인가 cap이 여럿이면 **첫** granted를 반환한다(scope 넓이 비교 안 함). browser처럼 같은 surface의
/// 동종 cap은 등가라 무해하나, metadata:all·metadata:self를 **둘 다** 누적한 세션은 grant 순서에 따라 좁은 sub-scope가
/// 이겨 **인가된 것보다 좁은** 뷰를 받는다(order-dependent). 방향이 **fail-closed**(절대 over-grant 아님 — authorize는
/// class만 보므로 어떤 granted든 그 method 자체는 정당히 인가됨)이고 다중 metadata cap 누적은 라이브 fd 다중발급(미배선)
/// 이 있어야 도달하므로, 최광-선택(broadest sub-scope pick)은 그 발급 경로 착수 시 함께 배선한다(지금은 도달 불가).
pub fn resolveAny(
    store: *const CapabilityStore,
    nonces: []const Nonce,
    requested_surface_id: u64,
    requested_generation: u64,
    method: []const u8,
    now: u64,
) Resolution {
    for (nonces) |nonce| {
        switch (resolve(store, nonce, requested_surface_id, requested_generation, method, now)) {
            .granted => |g| return .{ .granted = g },
            .unauthorized => {}, // 이 cap은 인가 못 함 → 다음 cap 시도
        }
    }
    return .unauthorized;
}

// ══ 테스트(헤드리스, Linux CI 포함 — 순수 로직·소켓/fd/실 crypto-random 0. 고정 nonce) ═════════════════════
const testing = std.testing;

// 고정 테스트 nonce(§ "테스트는 고정 nonce"). 실 crypto-random 생성은 1e 범위 밖.
const nonce_a: Nonce = [_]u8{0xA1} ** nonce_len;
const nonce_b: Nonce = [_]u8{0xB2} ** nonce_len;
const nonce_unknown: Nonce = [_]u8{0xFF} ** nonce_len;

fn metaCap(sid: u64, gen: u64, sub: wm.MetadataScope) Capability {
    return .{ .surface_id = sid, .generation = gen, .scope = .{ .metadata = sub } };
}

// ── 1) hash: 결정적 + raw nonce 미저장 ──
test "hashNonce: 결정적이고 nonce와 다르다(store는 hash만 — raw nonce 미저장, §8.5)" {
    const h1 = hashNonce(nonce_a);
    const h2 = hashNonce(nonce_a);
    try testing.expect(std.crypto.timing_safe.eql(Hash, h1, h2)); // 같은 nonce → 같은 hash
    try testing.expect(!std.mem.eql(u8, h1[0..], nonce_a[0..])); // hash != raw nonce
    // 서로 다른 nonce → 다른 hash.
    try testing.expect(!std.crypto.timing_safe.eql(Hash, hashNonce(nonce_a), hashNonce(nonce_b)));
}

test "store는 raw nonce를 저장하지 않는다(엔트리 hash에서 nonce 바이트가 나오지 않음, §8.5)" {
    var store: CapabilityStore = .{};
    defer store.deinit(testing.allocator);
    try store.issueForFd(testing.allocator, nonce_a, metaCap(10, 0, .self));
    try testing.expectEqual(@as(usize, 1), store.len());
    // 저장된 유일한 키가 raw nonce와 다르다(= hash가 저장됨).
    const stored = store.entries.items[0].hash;
    try testing.expect(!std.mem.eql(u8, stored[0..], nonce_a[0..]));
    try testing.expect(std.crypto.timing_safe.eql(Hash, stored, hashNonce(nonce_a)));
}

// ── 2) fd payload 직렬화/파싱 왕복 + 손상/버전 엣지(§8.5) ──
test "fd payload: serialize→parse 왕복(고정 nonce 보존)" {
    const bytes = serializeFdPayload(nonce_a);
    try testing.expectEqual(@as(usize, 38), bytes.len);
    try testing.expect(std.mem.eql(u8, bytes[0..4], fd_magic[0..])); // magic
    const got = try parseFdPayload(bytes[0..]);
    try testing.expect(std.mem.eql(u8, got[0..], nonce_a[0..]));
}

test "fd payload: 잘못된 magic → CapabilityFdInvalid(재사용·손상 fd, §8.5)" {
    var bytes = serializeFdPayload(nonce_a);
    bytes[0] = 'X'; // magic 손상 — 셸이 fd를 닫고 임의 데이터가 실린 상황.
    try testing.expectError(error.CapabilityFdInvalid, parseFdPayload(bytes[0..]));
}

test "fd payload: 잘못된 길이(짧음/김) → CapabilityFdInvalid" {
    const bytes = serializeFdPayload(nonce_a);
    try testing.expectError(error.CapabilityFdInvalid, parseFdPayload(bytes[0 .. fd_payload_len - 1])); // 짧음
    var long: [fd_payload_len + 1]u8 = undefined;
    @memcpy(long[0..fd_payload_len], bytes[0..]);
    long[fd_payload_len] = 0;
    try testing.expectError(error.CapabilityFdInvalid, parseFdPayload(long[0..])); // 김(trailing garbage)
    try testing.expectError(error.CapabilityFdInvalid, parseFdPayload(&[_]u8{})); // 빈
}

test "fd payload: magic OK·version 불일치 → CapabilityFdVersionMismatch(버전 skew, invalid와 구별)" {
    var bytes = serializeFdPayload(nonce_a);
    std.mem.writeInt(u16, bytes[4..6], fd_version + 1, .little); // 다른 버전.
    try testing.expectError(error.CapabilityFdVersionMismatch, parseFdPayload(bytes[0..]));
}

// ── 3) §8.5 fd 발급 정책: write/lifecycle 금지, read-output TTL 필수 ──
test "fd 발급 정책: write scope는 상속 fd로 발급 금지(§8.5 키 주입 위험)" {
    var store: CapabilityStore = .{};
    defer store.deinit(testing.allocator);
    const cap: Capability = .{ .surface_id = 10, .generation = 0, .scope = .write };
    try testing.expectError(error.ScopeForbiddenViaInheritedFd, store.issueForFd(testing.allocator, nonce_a, cap));
    try testing.expectEqual(@as(usize, 0), store.len()); // 정책 위반은 store에 아무것도 안 남긴다.
    // 순수 게이트도 직접 거부.
    try testing.expectError(error.ScopeForbiddenViaInheritedFd, validateFdIssuance(.write, null));
    try testing.expect(!Scope.allowedViaInheritedFd(.write));
}

test "fd 발급 정책: lifecycle scope는 상속 fd로 발급 금지(§8.5)" {
    var store: CapabilityStore = .{};
    defer store.deinit(testing.allocator);
    const cap: Capability = .{ .surface_id = 10, .generation = 0, .scope = .lifecycle };
    try testing.expectError(error.ScopeForbiddenViaInheritedFd, store.issueForFd(testing.allocator, nonce_a, cap));
    try testing.expectError(error.ScopeForbiddenViaInheritedFd, validateFdIssuance(.lifecycle, 100));
    try testing.expect(!Scope.allowedViaInheritedFd(.lifecycle));
}

test "fd 발급 정책: read-output은 TTL 없으면 발급 금지, 있으면 허용(§8.5 default grant 아님)" {
    var store: CapabilityStore = .{};
    defer store.deinit(testing.allocator);
    // TTL 없음 → 거부.
    const no_ttl: Capability = .{ .surface_id = 10, .generation = 0, .scope = .read_output };
    try testing.expectError(error.ReadOutputRequiresTtl, store.issueForFd(testing.allocator, nonce_a, no_ttl));
    try testing.expectError(error.ReadOutputRequiresTtl, validateFdIssuance(.read_output, null));
    try testing.expectEqual(@as(usize, 0), store.len());
    // TTL 있음 → 허용.
    const with_ttl: Capability = .{ .surface_id = 10, .generation = 0, .scope = .read_output, .expires_at = 1000 };
    try store.issueForFd(testing.allocator, nonce_a, with_ttl);
    try testing.expectEqual(@as(usize, 1), store.len());
}

test "fd 발급 정책: metadata·bind·browser는 상속 fd 허용(§8.5 write/lifecycle만 금지)" {
    try testing.expect(Scope.allowedViaInheritedFd(.{ .metadata = .self }));
    try testing.expect(Scope.allowedViaInheritedFd(.{ .metadata = .all }));
    try testing.expect(Scope.allowedViaInheritedFd(.bind));
    try testing.expect(Scope.allowedViaInheritedFd(.browser));
    try validateFdIssuance(.{ .metadata = .window }, null); // metadata는 TTL 없이도 OK.
    try validateFdIssuance(.bind, null);
    try validateFdIssuance(.browser, null);
}

test "fd 발급 정책: browser_storage는 상속 fd로 발급 금지(D5 쿠키=인증 토큰 탈취 위험)" {
    try testing.expect(!Scope.allowedViaInheritedFd(.browser_storage));
    try testing.expectError(error.ScopeForbiddenViaInheritedFd, validateFdIssuance(.browser_storage, null));
}

// ── 4) method↔scope 매핑 전수(§6 line 111 단일 출처) ──
test "method↔scope 매핑: §6 line 111의 모든 메서드가 올바른 category로 매핑된다" {
    const cases = [_]struct { m: []const u8, want: ?ScopeClass }{
        // metadata
        .{ .m = "sessions.list", .want = .metadata },
        .{ .m = "session.get", .want = .metadata },
        .{ .m = "events.subscribe", .want = .metadata },
        // read-output
        .{ .m = "session.capture", .want = .read_output },
        .{ .m = "session.subscribeOutput", .want = .read_output },
        // write (send*)
        .{ .m = "session.sendText", .want = .write },
        .{ .m = "session.sendKeys", .want = .write },
        // lifecycle
        .{ .m = "session.resize", .want = .lifecycle },
        .{ .m = "session.focus", .want = .lifecycle },
        .{ .m = "session.close", .want = .lifecycle },
        .{ .m = "session.spawn", .want = .lifecycle },
        .{ .m = "panel.open", .want = .lifecycle },
        // bind
        .{ .m = "panel.bindSession", .want = .bind },
        // browser.* (페이지 조작/관찰)
        .{ .m = "browser.navigate", .want = .browser },
        .{ .m = "browser.executeScript", .want = .browser },
        // browser-storage(D4/D5) — getCookies/setCookie/deleteCookie(쿠키 read+write) 분리 scope, 나머지 browser.*는 browser
        .{ .m = "browser.getCookies", .want = .browser_storage },
        .{ .m = "browser.setCookie", .want = .browser_storage },
        .{ .m = "browser.deleteCookie", .want = .browser_storage },
        .{ .m = "browser.clearStorage", .want = .browser_storage }, // comprehensive clear=쿠키 건드림
        // localStorage는 eval 백엔드=base browser(exec와 동일 도달, D5 laundering-hole 불변)
        .{ .m = "browser.getLocalStorage", .want = .browser },
        .{ .m = "browser.setLocalStorage", .want = .browser },
        // 미지/미매핑 → null(grant 안 샘)
        .{ .m = "session.unknownVerb", .want = null },
        .{ .m = "sessions.foo", .want = null },
        .{ .m = "plugin.x.y", .want = null },
        .{ .m = "session.subscribe", .want = null }, // events.subscribe만 metadata; session.subscribe는 미매핑
    };
    for (cases) |c| {
        try testing.expectEqual(c.want, methodRequiredScope(c.m));
    }
}

// ── 5) lookup: 알려진/미지 nonce ──
test "lookupByNonce: 발급된 nonce는 찾고 미지 nonce는 null(constant-time 전체 스캔)" {
    var store: CapabilityStore = .{};
    defer store.deinit(testing.allocator);
    try store.issueForFd(testing.allocator, nonce_a, metaCap(10, 3, .self));
    const found = store.lookupByNonce(nonce_a).?;
    try testing.expectEqual(@as(u64, 10), found.surface_id);
    try testing.expectEqual(@as(u64, 3), found.generation);
    try testing.expect(store.lookupByNonce(nonce_unknown) == null);
}

test "issueForFd: 같은 nonce 재발급은 capability identity ABA 방지로 거부" {
    var store: CapabilityStore = .{};
    defer store.deinit(testing.allocator);
    try store.issueForFd(testing.allocator, nonce_a, metaCap(10, 3, .self));
    try testing.expectError(error.DuplicateNonce, store.issueForFd(testing.allocator, nonce_a, metaCap(11, 4, .all)));
    try testing.expectEqual(@as(usize, 1), store.len());
    try testing.expectEqual(@as(u64, 10), store.lookupByNonce(nonce_a).?.surface_id);
}

// ── 6) authorize grant(정상) ──
test "authorize grant: 유효 metadata cap + 일치 anchor + 매핑 method → granted" {
    const cap = metaCap(10, 0, .self);
    try testing.expect(authorize(cap, 10, 0, "sessions.list", 0) == .granted);
    try testing.expect(authorize(cap, 10, 0, "session.get", 0) == .granted);
}

// ── 7) authorize deny: revoked ──
test "authorize deny: revoked cap → deny(.revoked)" {
    var cap = metaCap(10, 0, .self);
    cap.revoked = true;
    const d = authorize(cap, 10, 0, "sessions.list", 0);
    try testing.expect(d == .deny and d.deny == .revoked);
}

// ── 8) authorize deny: TTL 만료(경계 포함) ──
test "authorize deny: TTL 만료 — now<exp 유효, now==exp·now>exp 만료" {
    var cap = metaCap(10, 0, .self);
    cap.expires_at = 100;
    try testing.expect(authorize(cap, 10, 0, "sessions.list", 99) == .granted); // 아직 유효
    const at = authorize(cap, 10, 0, "sessions.list", 100); // 경계: 만료
    try testing.expect(at == .deny and at.deny == .expired);
    const after = authorize(cap, 10, 0, "sessions.list", 200);
    try testing.expect(after == .deny and after.deny == .expired);
    // null expires_at은 절대 만료 안 함.
    const cap2 = metaCap(10, 0, .self);
    try testing.expect(authorize(cap2, 10, 0, "sessions.list", std.math.maxInt(u64)) == .granted);
}

// ── 9) authorize deny: surface/generation 불일치 ──
test "authorize deny: 제시 anchor surface_id 불일치 → deny(.surface_mismatch)" {
    const cap = metaCap(10, 0, .self);
    const d = authorize(cap, 11, 0, "sessions.list", 0); // 다른 surface를 anchor로 주장
    try testing.expect(d == .deny and d.deny == .surface_mismatch);
}

test "authorize deny: generation 불일치 → deny(.generation_mismatch, §3 respawn 방어)" {
    const cap = metaCap(10, 5, .self);
    const d = authorize(cap, 10, 4, "sessions.list", 0); // 옛/틀린 generation
    try testing.expect(d == .deny and d.deny == .generation_mismatch);
    try testing.expect(authorize(cap, 10, 5, "sessions.list", 0) == .granted); // 일치는 통과
}

// ── 10) authorize deny: scope↔method 불충족 ──
test "authorize deny: scope↔method 불충족 — metadata cap으로 write/read-output 시도" {
    const meta = metaCap(10, 0, .self);
    // metadata cap으로 send*(write) → deny.
    var d = authorize(meta, 10, 0, "session.sendText", 0);
    try testing.expect(d == .deny and d.deny == .scope_insufficient);
    // metadata cap으로 capture(read-output) → deny.
    d = authorize(meta, 10, 0, "session.capture", 0);
    try testing.expect(d == .deny and d.deny == .scope_insufficient);

    // read-output cap으로 capture → grant, sessions.list(metadata) → deny.
    const ro: Capability = .{ .surface_id = 10, .generation = 0, .scope = .read_output, .expires_at = 1000 };
    try testing.expect(authorize(ro, 10, 0, "session.capture", 0) == .granted);
    d = authorize(ro, 10, 0, "sessions.list", 0);
    try testing.expect(d == .deny and d.deny == .scope_insufficient);

    // write cap으로 sendKeys → grant(순수 authorize는 write cap 자체는 유효; fd 발급만 금지).
    const wr: Capability = .{ .surface_id = 10, .generation = 0, .scope = .write };
    try testing.expect(authorize(wr, 10, 0, "session.sendKeys", 0) == .granted);
}

// ── 11) authorize deny: 미지 method ──
test "authorize deny: 미지/미매핑 method → deny(.unknown_method, grant 안 샘)" {
    const cap = metaCap(10, 0, .self);
    const d = authorize(cap, 10, 0, "session.doesNotExist", 0);
    try testing.expect(d == .deny and d.deny == .unknown_method);
}

// ── 12) resolve: 정상 grant + MetadataScope 추출 ──
test "resolve grant: 발급된 metadata cap → granted{surface_id,generation,scope}, metadataScope 추출" {
    var store: CapabilityStore = .{};
    defer store.deinit(testing.allocator);
    try store.issueForFd(testing.allocator, nonce_a, metaCap(10, 2, .window));
    const r = resolve(&store, nonce_a, 10, 2, "sessions.list", 0);
    try testing.expect(r == .granted);
    try testing.expectEqual(@as(u64, 10), r.granted.surface_id);
    try testing.expectEqual(@as(u64, 2), r.granted.generation);
    // item 3: metadata:{window} → wm.MetadataScope.window(1c/1d가 소비).
    try testing.expectEqual(wm.MetadataScope.window, r.granted.metadataScope().?);
}

test "resolve: read-output grant는 metadataScope가 null(metadata 아님)" {
    var store: CapabilityStore = .{};
    defer store.deinit(testing.allocator);
    try store.issueForFd(testing.allocator, nonce_a, .{ .surface_id = 10, .generation = 0, .scope = .read_output, .expires_at = 1000 });
    const r = resolve(&store, nonce_a, 10, 0, "session.capture", 0);
    try testing.expect(r == .granted);
    try testing.expect(r.granted.metadataScope() == null);
}

// ── 13) resolve: 모든 deny 경로가 균일 unauthorized(oracle 방지) ──
test "resolve: 미지 nonce·revoked·만료·surface/generation 불일치·scope 불충족·미지 method → 전부 균일 unauthorized" {
    var store: CapabilityStore = .{};
    defer store.deinit(testing.allocator);
    try store.issueForFd(testing.allocator, nonce_a, .{ .surface_id = 10, .generation = 1, .scope = .{ .metadata = .self }, .expires_at = 100 });

    // 미지 nonce.
    try testing.expect(resolve(&store, nonce_unknown, 10, 1, "sessions.list", 0) == .unauthorized);
    // surface 불일치.
    try testing.expect(resolve(&store, nonce_a, 11, 1, "sessions.list", 0) == .unauthorized);
    // generation 불일치.
    try testing.expect(resolve(&store, nonce_a, 10, 2, "sessions.list", 0) == .unauthorized);
    // scope 불충족(metadata cap으로 write).
    try testing.expect(resolve(&store, nonce_a, 10, 1, "session.sendText", 0) == .unauthorized);
    // 미지 method.
    try testing.expect(resolve(&store, nonce_a, 10, 1, "bogus.method", 0) == .unauthorized);
    // TTL 만료.
    try testing.expect(resolve(&store, nonce_a, 10, 1, "sessions.list", 100) == .unauthorized);
    // 정상은 grant(대조).
    try testing.expect(resolve(&store, nonce_a, 10, 1, "sessions.list", 0) == .granted);
}

// ── 14) revoke: 명시(nonce) ──
test "revokeByNonce: 취소 후 resolve/authorize가 deny(.revoked); 미지 nonce는 무동작" {
    var store: CapabilityStore = .{};
    defer store.deinit(testing.allocator);
    try store.issueForFd(testing.allocator, nonce_a, metaCap(10, 0, .self));
    try testing.expect(resolve(&store, nonce_a, 10, 0, "sessions.list", 0) == .granted);

    try testing.expect(store.revokeByNonce(nonce_a)); // true = 매치
    try testing.expect(resolve(&store, nonce_a, 10, 0, "sessions.list", 0) == .unauthorized);
    const d = authorize(store.lookupByNonce(nonce_a).?, 10, 0, "sessions.list", 0);
    try testing.expect(d == .deny and d.deny == .revoked);

    // 미지 nonce revoke는 false·무동작.
    try testing.expect(!store.revokeByNonce(nonce_unknown));
}

// ── 15) revoke: surface close(그 surface의 모든 cap, 타 surface는 불변) ──
test "revokeSurface: surface close 시 그 surface cap만 무효, 다른 surface cap은 유지(§8.5)" {
    var store: CapabilityStore = .{};
    defer store.deinit(testing.allocator);
    try store.issueForFd(testing.allocator, nonce_a, metaCap(10, 0, .self)); // surface 10
    try store.issueForFd(testing.allocator, nonce_b, metaCap(20, 0, .self)); // surface 20

    const n = store.revokeSurface(10);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expect(resolve(&store, nonce_a, 10, 0, "sessions.list", 0) == .unauthorized); // 닫힌 surface
    try testing.expect(resolve(&store, nonce_b, 20, 0, "sessions.list", 0) == .granted); // 다른 surface는 유지

    // 이미 revoked면 재-close는 0(중복 카운트 안 함).
    try testing.expectEqual(@as(usize, 0), store.revokeSurface(10));
}

// ── 16) end-to-end: fd payload → parse → resolve ──
test "end-to-end: serialize fd payload → parse → resolve granted(1e 순수 경로 전부)" {
    var store: CapabilityStore = .{};
    defer store.deinit(testing.allocator);
    try store.issueForFd(testing.allocator, nonce_a, metaCap(10, 0, .self));

    // server가 fd에 쓸 바이트를 만들고(순수), CLI가 그 바이트에서 nonce를 파싱(순수).
    const payload = serializeFdPayload(nonce_a);
    const parsed_nonce = try parseFdPayload(payload[0..]);
    // 그 nonce로 resolve → granted.
    const r = resolve(&store, parsed_nonce, 10, 0, "session.get", 0);
    try testing.expect(r == .granted);
    try testing.expectEqual(@as(u64, 10), r.granted.surface_id);
    try testing.expectEqual(wm.MetadataScope.self, r.granted.metadataScope().?);
}

// ── 17) metadata sub-scope 보존(self/window/all이 resolve까지 그대로) ──
test "metadata sub-scope: self/window/all이 발급→resolve까지 그대로 보존(1c/1d 소비)" {
    const subs = [_]wm.MetadataScope{ .self, .window, .all };
    for (subs, 0..) |sub, i| {
        var store: CapabilityStore = .{};
        defer store.deinit(testing.allocator);
        const n: Nonce = [_]u8{@intCast(i + 1)} ** nonce_len;
        try store.issueForFd(testing.allocator, n, metaCap(10, 0, sub));
        const r = resolve(&store, n, 10, 0, "sessions.list", 0);
        try testing.expect(r == .granted);
        try testing.expectEqual(sub, r.granted.metadataScope().?);
    }
}

// ── 커버리지 보강(test/foundation-coverage-gaps) ──────────────────────────────────────────────────────────

// authorize의 scope↔method 일치(grant) 경로는 지금까지 metadata·read_output·write cap만 밟혔다. bind·lifecycle·
// browser cap이 자기 category의 method를 실제로 인가하는지(매핑 대칭성)는 안 밟혔다 — validateFdIssuance는
// lifecycle/write를 fd 발급에서 막지만, 순수 authorize 자체는 이 scope들도 인가해야 한다(§8.5 "authorize는
// scope 자체 유효; fd 발급만 금지"). 그 grant 대칭을 못박고, resolve의 non-metadata grant는 metadataScope=null.
test "authorize grant: bind/lifecycle/browser cap이 각자 category method를 인가한다(매핑 대칭)" {
    const bind_cap: Capability = .{ .surface_id = 10, .generation = 0, .scope = .bind };
    try testing.expect(authorize(bind_cap, 10, 0, "panel.bindSession", 0) == .granted);
    // bind cap으로 lifecycle(panel.open)은 거부.
    const bd = authorize(bind_cap, 10, 0, "panel.open", 0);
    try testing.expect(bd == .deny and bd.deny == .scope_insufficient);

    const life_cap: Capability = .{ .surface_id = 10, .generation = 0, .scope = .lifecycle };
    for ([_][]const u8{ "session.resize", "session.focus", "session.close", "session.spawn", "panel.open" }) |m| {
        try testing.expect(authorize(life_cap, 10, 0, m, 0) == .granted);
    }

    const br_cap: Capability = .{ .surface_id = 10, .generation = 0, .scope = .browser };
    try testing.expect(authorize(br_cap, 10, 0, "browser.navigate", 0) == .granted);
    try testing.expect(authorize(br_cap, 10, 0, "browser.executeScript", 0) == .granted);
    // D5: browser cap은 getCookies를 인가하지 **않는다**(쿠키=별도 browser_storage scope, laundering-hole 방지).
    const bg = authorize(br_cap, 10, 0, "browser.getCookies", 0);
    try testing.expect(bg == .deny and bg.deny == .scope_insufficient);

    // 대칭: browser_storage cap은 getCookies만 인가, 페이지 조작(navigate)은 거부(single-scope §8.5).
    const stor_cap: Capability = .{ .surface_id = 10, .generation = 0, .scope = .browser_storage };
    try testing.expect(authorize(stor_cap, 10, 0, "browser.getCookies", 0) == .granted);
    const sn = authorize(stor_cap, 10, 0, "browser.navigate", 0);
    try testing.expect(sn == .deny and sn.deny == .scope_insufficient);
}

test "resolve: non-metadata grant(bind)는 metadataScope가 null(1c/1d가 metadata 아님을 구별)" {
    var store: CapabilityStore = .{};
    defer store.deinit(testing.allocator);
    try store.issueForFd(testing.allocator, nonce_a, .{ .surface_id = 10, .generation = 0, .scope = .bind });
    const r = resolve(&store, nonce_a, 10, 0, "panel.bindSession", 0);
    try testing.expect(r == .granted);
    try testing.expect(r.granted.metadataScope() == null);
}

test {
    testing.refAllDecls(@This());
}
