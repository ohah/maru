//! control_dispatch — 컨트롤 플레인 **read-only 바이트→바이트 디스패치 라우터**(L2 순수, OS-중립).
//! Track C slice 1d. 단일 출처: docs/control-plane-protocol.md §4.1(네임스페이스)·§6(sessions.list·session.get)·
//! §8.3(균일 unauthorized)·§11(slice 1d·CLI help gate·코드 배치 gate)·§16(코어 L2 = src/session/).
//!
//! **1a/1c와의 관계**: 1a(control_plane.zig)는 wire 프리미티브(JSON-RPC parse/serialize/framer/error-model),
//! 1c(control_surface.zig)는 Surface 엔티티 DTO + **메서드 수준** 응답 직렬화(serializeSessionsList·
//! serializeSessionGet + scope 판정). 1d는 그 위에 **요청 바이트 한 줄 + 주입 snapshot → 응답 바이트 한 줄**의
//! 최상위 라우터를 얹는다: parseMessage(1a) → parseMethod(1a) 라우팅 → 1c 직렬화 위임. 별도 모듈로 두는 이유:
//! 1a는 "봉투", 1c는 "엔티티+scope", 1d는 "요청→응답 라우팅"이라 관심사가 다르다(파일도 목적별로 나눈다 —
//! docs/project-rules.md). 에러 코드/스키마는 1a·1c를 재사용하고 여기서 재구현하지 않는다.
//!
//! **순수 경계(범위 애매점 결정)**: 이 라우터는 **바이트→바이트 + 주입 snapshot + 주입(caller_surface_id,
//! scope)** 이다. `caller_surface_id`·`scope`는 실제 시스템에서 capability auth(1e)·self-origin(1g)이 발급하지만,
//! 1d는 그걸 **인자로 주입**받아 read-only 판정만 한다(auth 발급·소켓 accept-loop 스레드·메인 marshal(§5)은
//! 범위 밖 — L4 1b/1e/1g가 나중에 이 순수 함수를 호출해 배선한다). 그래서 헤드리스 단위 테스트가 전부 커버한다.
//!
//! **범위(1d 라우터):** 요청 한 줄 parse → 최상위 라우팅. 지원 메서드:
//!   - `sessions.list {window?}` → 1c `serializeSessionsListFiltered`(scope 필터 + 선택적 window_id 좁힘).
//!   - `session.get {id}` → 1c `serializeSessionGet`(§8.3 존재검사 이전 scope 판정 → unauthorized/process_exited).
//!   - `session.capture {id, scrollback?}`(1f) → 이 read-only 라우터는 metadata scope만 나르는데 capture는
//!     **read-output** capability를 요구하므로(§8.3) 여기선 **항상 §8.3 균일 unauthorized**로 접는다(존재검사 이전,
//!     oracle 방지). 실 read-output grant + chunk 스트리밍은 control_capture(1f) `dispatchCaptureAck` + `Capture`가
//!     소유하고, L4가 1e fd·1g self-origin으로 read-output을 발급한 뒤 그 경로로 배선한다(이 metadata 라우터 밖).
//! 그 밖: 미지 method → method_not_found(-32601), malformed JSON → parse_error(-32700), 유효 JSON이나 유효
//! request 아님 → invalid_request(-32600), 잘못된 params(id 부재/비정수/음수, window 비정수/음수) → invalid_params(-32602).
//!
//! **범위 밖(구현 금지):** write/lifecycle 메서드(2·3), capability/auth 발급(1e/1g), 실 collector(Swift 트리
//! 순회·core_mutex read), accept-loop 스레드·메인 marshal(§5). 이 라우터에 그것들이 얽히면 넓히지 않는다.
//!
//! **session.get 셀렉터 결정(document-basis-and-decision)**: 요청 params의 `id`는 **surface_id(정수 u64)** 다.
//! 응답 Surface의 외부 ID는 `{surface_id, generation}` 객체지만(§3), 1d 셀렉터는 surface_id만으로 조회한다
//! (generation 한정 in-flight 거부는 M1 — control_surface.zig·window_membership.zig 헤더와 동일한 결정). 요청은
//! bare 정수, 응답은 객체라는 비대칭은 1d 범위이고, generation 셀렉터는 후속이다.
//!
//! **비-request message 결정**: read-only 조회 메서드는 응답에 request `id`가 필요하므로 **request만** 디스패치한다.
//! notification(id 없음)/response가 오면 invalid_request(-32600, id=null)로 돌려준다 — 로컬 컨트롤 플레인이라
//! "무응답"보다 명시적 오류가 클라이언트 디버깅에 유용하다(JSON-RPC notification 무응답 관례의 의도적 이탈, 문서화).
//!
//! **L2 순수:** std + control_plane(1a) + control_surface(1c) + window_membership(M0b)만 import한다
//! (app/pty/platform/chrome import 0 — tests/boundary/imports.zig가 강제). OS 타입 0.

const std = @import("std");
const cp = @import("control_plane.zig");
const cs = @import("control_surface.zig");
const wm = @import("window_membership.zig");
const cap = @import("control_capability.zig");
const cb = @import("control_browser.zig"); // 5e: browser.* op 산출(dispatchAuthenticated가 위임)
const cpg = @import("control_pane_grant.zig"); // 1e-confirm-1b: pane-bound confirm-grant store(browser.* authz 가법)

/// read-only 조회 요청 한 줄(ndjson frame, 개행 제외)을 주입 snapshot으로 처리해 **응답 한 줄 바이트**를 만든다.
/// 성공/에러 모두 유효한 JSON-RPC 응답 바이트(개행 없음, 프레이밍은 L4가 붙임)를 돌려준다 — OOM만 error로 전파한다
/// (응답 자체를 만들 메모리도 없을 때). caller가 반환 슬라이스를 free한다.
///
/// `caller_surface_id`·`scope`는 auth(1e/1g)가 발급한 값을 L4가 주입한다(1d는 판정만). `snapshot`은 collector(L4)가
/// 주입한 중립 스냅샷(1d 테스트는 fake).
pub fn dispatchReadOnly(
    gpa: std.mem.Allocator,
    request_bytes: []const u8,
    snapshot: cs.CollectorSnapshot,
    caller_surface_id: u64,
    scope: wm.MetadataScope,
) std.mem.Allocator.Error![]u8 {
    // ── 1a parse. 실패는 JSON-RPC 관례대로 id=null 에러 응답으로 접는다(OOM만 전파). ──
    var pm = cp.parseMessage(gpa, request_bytes) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return errorResponse(gpa, .null, cp.parseFailureCode(e)),
    };
    defer pm.deinit();

    // read-only 조회는 응답에 request id가 필요하므로 request만 디스패치한다(비-request → invalid_request, 헤더 참조).
    const req = switch (pm.message) {
        .request => |r| r,
        else => return errorResponse(gpa, .null, .invalid_request),
    };
    return routeReadOnly(gpa, req, snapshot, caller_surface_id, scope);
}

/// **파싱된** request를 read-only 라우팅한다(§4.1). `dispatchReadOnly`(바이트 파싱)와 `dispatchAuthenticated`
/// (cap resolve 후 metadata grant)가 공유하는 **단일 라우팅 진입점** — 후자는 이미 파싱한 req를 넘겨 이중 파싱을 피한다
/// (리뷰 [10]). 코어 read-only 둘(list/get)만 지원, capture는 §8.3 균일 unauthorized, 그 밖은 method_not_found.
fn routeReadOnly(
    gpa: std.mem.Allocator,
    req: cp.Request,
    snapshot: cs.CollectorSnapshot,
    caller_surface_id: u64,
    scope: wm.MetadataScope,
) std.mem.Allocator.Error![]u8 {
    const method = cp.parseMethod(req.method);
    if (method.core == .sessions and std.mem.eql(u8, method.rest, "list")) {
        const window_filter = readWindowParam(req.params) catch return errorResponse(gpa, req.id, .invalid_params);
        return cs.serializeSessionsListFiltered(gpa, req.id, snapshot, caller_surface_id, scope, window_filter);
    }
    if (method.core == .session and std.mem.eql(u8, method.rest, "get")) {
        const requested = readIdParam(req.params) catch return errorResponse(gpa, req.id, .invalid_params);
        // §8.3 균일 unauthorized/process_exited 판정·직렬화는 1c가 단일 출처로 소유(재구현 금지).
        return cs.serializeSessionGet(gpa, req.id, snapshot, caller_surface_id, scope, requested);
    }
    if (method.core == .session and std.mem.eql(u8, method.rest, "capture")) {
        // session.capture는 **read-output** capability를 요구한다(§8.3). 이 라우터는 **metadata scope만** 나르고
        // (caller가 주입받는 `scope`는 `MetadataScope`), metadata는 read-output을 **절대** 만족하지 못하므로 §8.3
        // **균일 unauthorized**로 접는다(존재검사 이전 — target 존재 무관, surface_id 열거 oracle 방지). 실 read-output
        // grant + chunk 스트리밍은 control_capture(1f) `dispatchCaptureAck`가 소유하고, L4가 read-output을 발급한 뒤
        // **그 경로로** 배선한다(이 metadata 라우터가 아니라). **주의**: `dispatchAuthenticated`는 read_output cap이
        // capture를 실제로 인가해도 여기로 보내지 **않는다**(non-metadata granted는 method_not_found로 접음, 리뷰 [4])
        // — 이 unauthorized는 오직 metadata scope가 capture를 시도할 때만(구조적 미충족).
        return errorResponse(gpa, req.id, .unauthorized);
    }
    return errorResponse(gpa, req.id, .method_not_found);
}

/// 코드의 default message로 에러 응답 한 줄을 만든다(1a serializeError 재사용). 편의 wrapper.
fn errorResponse(gpa: std.mem.Allocator, id: cp.Id, code: cp.ErrorCode) std.mem.Allocator.Error![]u8 {
    return cp.serializeError(gpa, id, code, code.defaultMessage(), null);
}

/// **1e-core: capability 인가 배선.** auth 프레임의 selector + **세션 누적 cap 집합**(`cap_nonces`, 5f-4a — §9.5.6 ③
/// `auth.self` cap + 반복 `auth.grant`)과 라이브 `CapabilityStore`(L4가 소유·주입)로 요청의 `(caller_surface_id, scope)`를
/// 판정한 뒤 read-only 라우터에 넘긴다. `dispatchReadOnly`가 auth를 **인자로 주입**받던 것을, 그 인자를 capability로
/// **발급**하는 상위 래퍼다(1d 헤더 §범위).
///
/// 경로(먼저 파싱 → method로 분기):
///  - **`browser.*`(cap 유무 무관, 5e)**: 세션 cap 집합을 `Capability` 집합으로 lookup해 `control_browser.
///    browserOpFromRequest`에 위임(**하나라도** target+method 인가하면 통과 — 5f-4a 누적). browser cap의 anchor는
///    selector가 아니라 target web surface(params.id). cap 부재/deny 전부 **균일 unauthorized**(리뷰 [2] — §8.3 위배 +
///    browser.* 존재 oracle 방지). 게이트 통과면 `.browser` op / `.subscribe`(5f-0b-3b).
///  - **비-browser**: **ambient self-origin(§8.4 A2b — `scope=.self`, anchor=selector)은 세션 내내 항상 유효**하고, 누적
///    cap이 권한을 *더한다*(cap 제시가 self-access를 revoke하지 않음 — **22차 [1]**; 옛 singular 모델은 cap 제시 시
///    self 폴백을 잃었다). `resolveAny`(store lookup → authorize → 균일 unauthorized)로 집합 중 하나라도 이 method를
///    인가하면 그 `(surface_id, scope)`로 라우팅(metadata=라우터·non-metadata 미배선=method_not_found), 아무 cap도
///    인가 못 하면 **self-origin 폴백**(no-cap 세션과 바이트 동일 — over-grant 없음). deny 이유는 절대 노출 안 됨(§8.3).
///    resolve는 method↔scope를 검사하므로 method가 필요해 1a로 한 번 파싱한다(라우터가 다시 파싱하지만 로컬 소켓이라 무시할 비용).
///
/// **⚠️ 22차 [2] 알려진 한계(미배선 게이트·fail-closed)**: `resolveAny`는 집합에서 **첫** 인가 cap의 scope를 반환한다
/// (최광 아님). 한 세션이 metadata:all·metadata:self를 **둘 다** 누적하면(라이브 fd 다중발급 필요 — 미배선) grant 순서에
/// 따라 좁은 scope가 이겨 sessions.list가 인가된 것보다 **적게** 반환할 수 있다. 방향이 **fail-closed**(절대 over-grant
/// 아님)이고 다중 metadata cap 누적 경로가 아직 없어 지금 도달 불가라, 최광-선택은 라이브 발급 착수 시 함께 배선한다.
///
/// **non-metadata cap(browser/write/read-output/bind)**: resolve는 인가하지만 그 method의 **라이브 dispatch가 아직
/// 없다**(browser=5e·write=2a·read-output capture=1f 배선 대기). 이 경우 **균일 `method_not_found`**로 접는다 —
/// read-only 라우터(metadata 전용)로 보내지 않는다. 특히 `session.capture`는 라우터가 unauthorized로 특수처리하므로
/// (구조적 metadata 미충족) read_output cap이 실제로 인가해도 거기로 보내면 `unauthorized`로 오접힌다 → 그래서
/// non-metadata granted는 라우터 우회로 직접 method_not_found를 낸다(리뷰 [4]). 즉 "cap resolve됨 but 미배선"은
/// **모든** non-metadata method에서 `method_not_found`, "cap scope 불충족"은 `unauthorized`로 일관 구별된다.
///
/// **generation anchor**: 현재 전 시스템이 generation 0(§3 respawn 경로 미구현)이라 anchor generation을 0으로 고정한다
/// (auth.self 셀렉터는 surface_id만 나름). generation 셀렉터·respawn 무효화는 후속(cap의 generation 검사는 이미 순수
/// 코어에 있음 — 발급 시 0으로 묶이면 0 anchor와 일치).
///
/// **5e: browser.* 라우팅**. method가 `browser.*`면 metadata resolve(anchor=selector)를 **안 타고** `control_browser.
/// browserOpFromRequest`에 위임한다 — browser cap의 anchor는 selector(에이전트 자기 surface)가 아니라 target web
/// surface(params.id)라, 그 함수가 target을 앵커로 authz·validate한다(§9.3). 반환은 `AuthDispatch{immediate|browser}`:
/// 게이트 실패/비-browser는 `.immediate`(응답 바이트, L4가 즉시 resolve), browser op은 `.browser`(L4가 §5-async marshal).
pub const AuthDispatch = union(enum) {
    /// 즉시 소켓에 resolve할 응답 바이트(gpa-owned). metadata·에러·비-browser 전부.
    immediate: []u8,
    /// L4가 marshal할 browser 실행 op(op.arg는 gpa-owned — L4가 큐로 소유 이전 후 free).
    browser: cb.BrowserOp,
    /// L4가 동기 등록할 browser 구독(5f-0b-3b — SubscriberRegistry.subscribe + `{subscriber_id}` 응답). 연결 outbound는 L4가 주입.
    subscribe: cb.BrowserSubscribe,
    /// **1e-confirm-1c**: 미grant valid browser 요청(§9.2 Model B). L4가 §5-async로 붙잡고 확인 모달을 띄운다(1c-2) —
    /// 승인 시 grant 기록 후 재구동, 거부 시 unauthorized. 1c-1은 L4가 우선 unauthorized로 collapse(behavior-preserving).
    needs_grant: cb.GrantRequest,
};

pub fn dispatchAuthenticated(
    gpa: std.mem.Allocator,
    request_bytes: []const u8,
    snapshot: cs.CollectorSnapshot,
    selector: ?u64,
    cap_nonces: []const cap.Nonce, // 5f-4a: 세션 누적 cap 집합(§9.5.6 ③). 빈=cap 없음. 하나라도 인가하면 통과.
    store: *const cap.CapabilityStore,
    grants: *const cpg.PaneGrantStore, // 1e-confirm-1b: pane-bound confirm-grant(§9.2 Model B). browser.* authz 가법 조회.
    now: u64,
) std.mem.Allocator.Error!AuthDispatch {
    // **먼저 파싱**한다 — browser.* 라우팅은 nonce 유무와 무관하게 method로 판정해야 한다(리뷰 [2]: cap_nonce 없는
    // browser.*가 옛날엔 dispatchReadOnly로 새 method_not_found였고, nonce 있으면 unauthorized라 갈렸다 — §8.3 균일
    // unauthorized 위배 + browser.* 존재 oracle). parse 실패/비-request는 기존 관례(id=null 에러)로 접는다. 파싱한
    // req를 아래 모든 경로가 재사용해 재파싱이 없다(리뷰 [10]).
    var pm = cp.parseMessage(gpa, request_bytes) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .immediate = try errorResponse(gpa, .null, cp.parseFailureCode(e)) },
    };
    defer pm.deinit();
    const req = switch (pm.message) {
        .request => |r| r,
        else => return .{ .immediate = try errorResponse(gpa, .null, .invalid_request) },
    };

    // ── 5e: browser.*는 **cap 유무 무관** control_browser에 위임(anchor=target web surface, selector 무관). 세션 cap
    //       집합의 각 nonce를 lookup해 **Capability 집합**을 만들고(5f-4a 누적), browserOpFromRequest가 그중 하나라도
    //       인가하면 통과·아니면 **균일 unauthorized**(cap 부재도 동일). ──
    if (cp.parseMethod(req.method).core == .browser) {
        // **browser.list — ungated 발견(§9.6)**: 인스턴스의 web surface를 나열한다. 제어 op(navigate/screenshot 등)과
        //   달리 cap/grant/모달이 필요 없다(사용자 결정: 같은 uid = 사용자 자신의 브라우저라 URL 노출 수용). control은
        //   여전히 §9.2 Model B 모달 게이트를 거친다. cap 로직 진입 전에 접어 nonce 유무와 무관하게 균일 동작.
        if (std.mem.eql(u8, cp.parseMethod(req.method).rest, "list"))
            return .{ .immediate = try cb.serializeBrowserListResult(gpa, req.id, snapshot) };
        var caps_buf: [cap.max_session_caps]cap.Capability = undefined;
        var ncaps: usize = 0;
        for (cap_nonces) |n| {
            if (store.lookupByNonce(n)) |c| {
                if (ncaps < caps_buf.len) {
                    caps_buf[ncaps] = c;
                    ncaps += 1;
                }
            }
        }
        return switch (try cb.browserOpFromRequest(gpa, req, request_bytes, snapshot, caps_buf[0..ncaps], selector, grants, now)) {
            .err => |e| .{ .immediate = e },
            .op => |raw_op| blk: {
                var op = raw_op;
                if (op.pane_grant == null) {
                    for (cap_nonces) |nonce| {
                        const c = store.lookupByNonce(nonce) orelse continue;
                        if (cap.authorize(c, op.surface_id, c.generation, req.method, now) == .granted) {
                            op.capability_nonce = nonce;
                            op.capability_generation = c.generation;
                            break;
                        }
                    }
                }
                break :blk .{ .browser = op };
            },
            .subscribe => |s| .{ .subscribe = s }, // 5f-0b-3b: 동기 구독 지시 — L4가 registry 등록
            .needs_grant => |g| .{ .needs_grant = g }, // 1e-confirm-1c: 확인 대기(L4가 held-request·모달)
        };
    }

    // ── 비-browser. **ambient self-origin(§8.4 A2b)은 세션 내내 항상 유효하고, 누적 cap이 권한을 *더한다*(cap 제시가
    //    self-access를 revoke하지 않음 — 22차 [1]).** 누적 cap 중 하나가 이 method를 인가하면 그 (surface, scope)로
    //    라우팅하고, 아무 cap도 인가 못 하면(빈 집합 포함) ambient 폴백. 폴백 scope 는 `ambientScope` 가 정한다 —
    //    셀렉터를 댔으면 그 surface 하나(종전), **안 댔으면 전체**(§4a 원격). 어느 쪽도 metadata 를 넘지 않는다. ──
    const anchor = selector orelse 0;
    const ambient = ambientScope(selector);
    if (cap_nonces.len > 0) {
        switch (cap.resolveAny(store, cap_nonces, anchor, 0, req.method, now)) {
            .granted => |g| {
                // metadata → 파싱한 req로 read-only 라우팅(재파싱 없음). non-metadata(write/read-output/bind) → 미배선이라
                // method_not_found(라우터 우회 — capture unauthorized 특수처리 회피, 리뷰 [4]). browser는 위에서 이미 분기.
                if (g.metadataScope()) |ms| return .{ .immediate = try routeReadOnly(gpa, req, snapshot, g.surface_id, ms) };
                return .{ .immediate = try errorResponse(gpa, req.id, .method_not_found) };
            },
            .unauthorized => {}, // 어떤 cap도 이 method를 인가 못 함 → ambient self-origin 폴백(아래). deny로 접지 않음(22차 [1]).
        }
    }
    // ambient 폴백: no-cap이거나 누적 cap이 이 method를 인가 못 함. scope 는 **앵커를 댔는가**가 정한다(위 헬퍼).
    return .{ .immediate = try routeReadOnly(gpa, req, snapshot, anchor, ambient) };
}

/// **앵커를 안 댄 연결의 metadata scope.** 셀렉터가 있으면 그 surface 하나(`.self` — 종전 그대로), 없으면 전체
/// (`.all`).
///
/// **왜 없는 쪽이 넓은가.** 셀렉터는 권한이 아니라 **주장**이다("나는 이 surface 다"). 그 주장의 출처는
/// `MARU_PANE_ID` 인데, 폰이 SSH 로 연 `exec` 채널에는 그 환경이 **없다**([컨트롤 플레인 §4a](../../docs/control-plane.md))
/// — 그래서 원격은 앵커를 못 댄다. 앵커 없는 연결을 `.self` 로 두면 `anchor=0` 이라 **아무것도 안 맞아** 목록이
/// 언제나 빈다. 그것이 폰에서 "세션이 하나도 없다" 로 보였다.
///
/// **왜 그래도 되는가**(단일 출처 = [보안 §8.4](../../docs/control-plane-security.md)). 이 소켓은 same-uid
/// peer-cred + 0700 이라 붙은 쪽은 **그 사용자 자신**이다. SSH 로 붙은 폰도 같은 등급이다 — 그 사용자로 아무
/// 명령이나 돌릴 수 있으므로 목록이 권한을 넓히지 않는다. 좁은 scope 가 보호처럼 보였지만 실효가 없었다:
/// `surface_id` 가 1부터 단조 증가라 셀렉터를 훑으면 같은 메타데이터가 그대로 나온다(§8.4 가 그 한계를 이미
/// 적어 뒀고, 실측으로 확인했다). `browser.*`·`session.capture`(read-output)·write 는 이 헬퍼가 안 건드린다 —
/// 그것들은 cap 이나 target 앵커가 따로 있다.
fn ambientScope(selector: ?u64) wm.MetadataScope {
    return if (selector == null) .all else .self;
}

/// params 오류(shape/타입/범위)를 하나로 접는 sentinel — 호출자가 invalid_params로 매핑한다.
const ParamError = error{InvalidParams};

/// `session.get {id}`의 필수 `id`(surface_id, u64)를 읽는다. params 부재/객체 아님/id 부재/비정수/음수 → InvalidParams.
/// 셀렉터는 surface_id만(generation 한정은 후속 — 모듈 헤더 참조).
fn readIdParam(params: ?std.json.Value) ParamError!u64 {
    const obj = switch (params orelse return error.InvalidParams) {
        .object => |o| o,
        else => return error.InvalidParams,
    };
    return switch (obj.get("id") orelse return error.InvalidParams) {
        .integer => |i| if (i < 0) error.InvalidParams else @intCast(i),
        else => error.InvalidParams,
    };
}

/// `sessions.list {window?}`의 **선택적** `window`(window_id, u64)를 읽는다. params 부재/params가 null이면 필터 없음(null).
/// params가 있으나 객체가 아니거나, window가 있으나 비정수/음수면 InvalidParams. window 부재는 필터 없음.
fn readWindowParam(params: ?std.json.Value) ParamError!?u64 {
    const obj = switch (params orelse return null) {
        .object => |o| o,
        else => return error.InvalidParams,
    };
    return switch (obj.get("window") orelse return null) {
        .integer => |i| if (i < 0) error.InvalidParams else @intCast(i),
        else => error.InvalidParams,
    };
}

// ══ 테스트(헤드리스, Linux CI 포함 — 순수 로직·소켓 0) ═══════════════════════════════════════════════════
const testing = std.testing;

// fake collector snapshot: 창 A(normal,win1)={10 terminal, 11 web}, 창 B(normal,win2)={20 terminal}, quick(win3)={30}.
const fx_surfaces = [_]cs.SurfaceDto{
    .{ .surface_id = 10, .generation = 0, .title = "shell-a", .window = 1, .tab = 0, .pane = 0, .focused = true, .detail = .{ .terminal = .{ .cwd = "/home/a", .git_branch = "main", .agent = .{ .kind = .claude, .state = .running }, .at_prompt = .not_at_prompt } } },
    .{ .surface_id = 11, .generation = 0, .title = "docs", .window = 1, .tab = 1, .pane = 0, .focused = false, .detail = .{ .web = .{ .url = "https://x/y", .panel_kind = .markdown, .loading = false, .trust = .trusted } } },
    .{ .surface_id = 20, .generation = 2, .title = "shell-b", .window = 2, .tab = 0, .pane = 0, .focused = false, .detail = .{ .terminal = .{ .cwd = "/srv/b", .at_prompt = .at_prompt } } },
    .{ .surface_id = 30, .generation = 0, .title = "quick", .window = 3, .tab = 0, .pane = 0, .focused = false, .detail = .{ .terminal = .{ .at_prompt = .unknown } } },
};
const fx_a_ids = [_]u64{ 10, 11 };
const fx_b_ids = [_]u64{20};
const fx_q_ids = [_]u64{30};
const fx_windows = [_]wm.WindowMembershipSnapshot{
    .{ .window_id = 1, .window_kind = .normal, .surface_ids = &fx_a_ids },
    .{ .window_id = 2, .window_kind = .normal, .surface_ids = &fx_b_ids },
    .{ .window_id = 3, .window_kind = .quick, .surface_ids = &fx_q_ids },
};
const fx: cs.CollectorSnapshot = .{ .surfaces = &fx_surfaces, .windows = &fx_windows };

fn dispatch(bytes: []const u8, caller: u64, scope: wm.MetadataScope) ![]u8 {
    return dispatchReadOnly(testing.allocator, bytes, fx, caller, scope);
}

// 응답 바이트에서 result 배열의 surface_id 집합을 뽑는다(순서 보존).
fn listIds(wire: []const u8, out: *std.ArrayList(u64)) !void {
    var pm = try cp.parseMessage(testing.allocator, wire);
    defer pm.deinit();
    try testing.expect(pm.message == .response);
    const arr = pm.message.response.result.?.array;
    for (arr.items) |item| {
        try out.append(testing.allocator, @intCast(item.object.get("id").?.object.get("surface_id").?.integer));
    }
}

// 응답 바이트의 에러 코드를 뽑는다(성공이면 실패 단언).
fn errCode(wire: []const u8) !i64 {
    var pm = try cp.parseMessage(testing.allocator, wire);
    defer pm.deinit();
    try testing.expect(pm.message == .response);
    return pm.message.response.err.?.code;
}

test "dispatch: sessions.list self scope → 자기 surface(10)만" {
    const wire = try dispatch("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sessions.list\"}", 10, .self);
    defer testing.allocator.free(wire);
    var ids: std.ArrayList(u64) = .empty;
    defer ids.deinit(testing.allocator);
    try listIds(wire, &ids);
    try testing.expectEqualSlices(u64, &.{10}, ids.items);
}

test "dispatch: sessions.list window scope → 창 A(10,11), all scope → 전체(10,11,20,30)" {
    {
        const wire = try dispatch("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sessions.list\"}", 10, .window);
        defer testing.allocator.free(wire);
        var ids: std.ArrayList(u64) = .empty;
        defer ids.deinit(testing.allocator);
        try listIds(wire, &ids);
        try testing.expectEqualSlices(u64, &.{ 10, 11 }, ids.items);
    }
    {
        const wire = try dispatch("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sessions.list\"}", 10, .all);
        defer testing.allocator.free(wire);
        var ids: std.ArrayList(u64) = .empty;
        defer ids.deinit(testing.allocator);
        try listIds(wire, &ids);
        try testing.expectEqualSlices(u64, &.{ 10, 11, 20, 30 }, ids.items);
    }
}

test "dispatch: sessions.list {window} 필터는 scope와 교집합 — all+window=2 → [20], self+window=2 → []" {
    // all scope + window=2 → 창 B의 20만.
    {
        const wire = try dispatch("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sessions.list\",\"params\":{\"window\":2}}", 10, .all);
        defer testing.allocator.free(wire);
        var ids: std.ArrayList(u64) = .empty;
        defer ids.deinit(testing.allocator);
        try listIds(wire, &ids);
        try testing.expectEqualSlices(u64, &.{20}, ids.items);
    }
    // self scope caller 10 + window=1 → 10만(11은 self 안 보임). window=2 → [](scope가 window 필터를 이긴다).
    {
        const w1 = try dispatch("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sessions.list\",\"params\":{\"window\":1}}", 10, .self);
        defer testing.allocator.free(w1);
        var ids1: std.ArrayList(u64) = .empty;
        defer ids1.deinit(testing.allocator);
        try listIds(w1, &ids1);
        try testing.expectEqualSlices(u64, &.{10}, ids1.items);

        const w2 = try dispatch("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sessions.list\",\"params\":{\"window\":2}}", 10, .self);
        defer testing.allocator.free(w2);
        var ids2: std.ArrayList(u64) = .empty;
        defer ids2.deinit(testing.allocator);
        try listIds(w2, &ids2);
        try testing.expectEqual(@as(usize, 0), ids2.items.len);
    }
}

test "dispatch: session.get self 자기(10) → Surface result" {
    const wire = try dispatch("{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"session.get\",\"params\":{\"id\":10}}", 10, .self);
    defer testing.allocator.free(wire);
    var pm = try cp.parseMessage(testing.allocator, wire);
    defer pm.deinit();
    try testing.expect(pm.message.response.err == null);
    const o = pm.message.response.result.?.object;
    try testing.expectEqual(@as(i64, 10), o.get("id").?.object.get("surface_id").?.integer);
    try testing.expectEqualStrings("terminal", o.get("kind").?.string);
    // request id(7)가 응답에 echo된다.
    try testing.expect(cp.idEql(pm.message.response.id, .{ .number = 7 }));
}

test "dispatch §8.3: self caller가 남의 id를 물으면 존재/부재 무관 균일 unauthorized(바이트 동일 = oracle 없음)" {
    // 존재하는 남(20) vs 아예 없는(999) — 같은 request id로 물어 응답 바이트가 동일해야 한다.
    const w_exists = try dispatch("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session.get\",\"params\":{\"id\":20}}", 10, .self);
    defer testing.allocator.free(w_exists);
    const w_absent = try dispatch("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session.get\",\"params\":{\"id\":999}}", 10, .self);
    defer testing.allocator.free(w_absent);
    try testing.expectEqualStrings(w_exists, w_absent); // oracle 없음
    try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.unauthorized)), try errCode(w_exists));
}

test "dispatch: 인가된 surface가 snapshot에 없으면 process_exited(unauthorized와 다름)" {
    // window scope caller 10이 같은 창 11을 묻되 snapshot엔 11이 없다 → 인가되나 부재 → process_exited.
    const partial = [_]cs.SurfaceDto{fx_surfaces[0]}; // 10만.
    const snap: cs.CollectorSnapshot = .{ .surfaces = &partial, .windows = &fx_windows };
    const wire = try dispatchReadOnly(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session.get\",\"params\":{\"id\":11}}", snap, 10, .window);
    defer testing.allocator.free(wire);
    try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.process_exited)), try errCode(wire));
}

test "dispatch: 미지 method → method_not_found(-32601)" {
    for ([_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session.sendText\",\"params\":{\"id\":10,\"text\":\"x\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sessions.foo\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"foo.bar\"}",
    }) |req| {
        const wire = try dispatch(req, 10, .all);
        defer testing.allocator.free(wire);
        try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.method_not_found)), try errCode(wire));
    }
}

// session.capture(1f)는 read-output capability를 요구하는데(§8.3) 이 read-only 라우터는 metadata scope만 나른다 —
// metadata는 read-output을 절대 만족하지 못하므로 method_not_found가 아니라 **§8.3 균일 unauthorized**로 접는다
// (실 read-output 경로는 control_capture.dispatchCaptureAck·1f). all scope로도, target 존재/부재와도 무관하게 균일.
test "dispatch: session.capture는 metadata 라우터에서 read-output 미충족 → 균일 unauthorized(method_not_found 아님)" {
    for ([_]wm.MetadataScope{ .self, .window, .all }) |scope| {
        const wire = try dispatch("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session.capture\",\"params\":{\"id\":10}}", 10, scope);
        defer testing.allocator.free(wire);
        try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.unauthorized)), try errCode(wire));
    }
    // §8.3 oracle 방지: target surface_id가 존재하는 10이든 없는 999든 바이트 동일(존재 여부 무누설).
    const w_exists = try dispatch("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session.capture\",\"params\":{\"id\":10}}", 10, .all);
    defer testing.allocator.free(w_exists);
    const w_absent = try dispatch("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session.capture\",\"params\":{\"id\":999}}", 10, .all);
    defer testing.allocator.free(w_absent);
    try testing.expectEqualStrings(w_exists, w_absent);
}

test "dispatch: malformed JSON → parse_error(-32700), id=null" {
    for ([_][]const u8{ "{not json", "", "{\"jsonrpc\":\"2.0\"," }) |req| {
        const wire = try dispatch(req, 10, .all);
        defer testing.allocator.free(wire);
        var pm = try cp.parseMessage(testing.allocator, wire);
        defer pm.deinit();
        try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.parse_error)), pm.message.response.err.?.code);
        try testing.expect(pm.message.response.id == .null);
    }
}

test "dispatch: 유효 JSON이나 유효 request 아님 → invalid_request(-32600)" {
    for ([_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1}", // method/result 없음
        "[]", // 배열
        "{\"jsonrpc\":\"2.0\",\"method\":\"sessions.list\"}", // notification(id 없음) — read-only는 request만
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}", // response
    }) |req| {
        const wire = try dispatch(req, 10, .all);
        defer testing.allocator.free(wire);
        try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.invalid_request)), try errCode(wire));
    }
}

test "dispatch: session.get params 오류 → invalid_params(-32602)" {
    for ([_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session.get\"}", // params 없음
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session.get\",\"params\":{}}", // id 없음
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session.get\",\"params\":{\"id\":\"x\"}}", // 비정수
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session.get\",\"params\":{\"id\":-3}}", // 음수
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session.get\",\"params\":[1,2]}", // params가 객체 아님
    }) |req| {
        const wire = try dispatch(req, 10, .all);
        defer testing.allocator.free(wire);
        try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.invalid_params)), try errCode(wire));
    }
}

test "dispatch: sessions.list window params 오류 → invalid_params" {
    for ([_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sessions.list\",\"params\":{\"window\":\"x\"}}", // 비정수
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sessions.list\",\"params\":{\"window\":-2}}", // 음수
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sessions.list\",\"params\":[]}", // params가 객체 아님
    }) |req| {
        const wire = try dispatch(req, 10, .all);
        defer testing.allocator.free(wire);
        try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.invalid_params)), try errCode(wire));
    }
}

test "dispatch: 빈 snapshot → sessions.list []" {
    const empty_s = [_]cs.SurfaceDto{};
    const empty_w = [_]wm.WindowMembershipSnapshot{};
    const snap: cs.CollectorSnapshot = .{ .surfaces = &empty_s, .windows = &empty_w };
    const wire = try dispatchReadOnly(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sessions.list\"}", snap, 10, .all);
    defer testing.allocator.free(wire);
    var pm = try cp.parseMessage(testing.allocator, wire);
    defer pm.deinit();
    try testing.expectEqual(@as(usize, 0), pm.message.response.result.?.array.items.len);
}

test "dispatch: 응답이 request id(number·string)를 echo한다" {
    // string id.
    const wire = try dispatch("{\"jsonrpc\":\"2.0\",\"id\":\"req-9\",\"method\":\"sessions.list\"}", 10, .self);
    defer testing.allocator.free(wire);
    var pm = try cp.parseMessage(testing.allocator, wire);
    defer pm.deinit();
    try testing.expect(cp.idEql(pm.message.response.id, .{ .string = "req-9" }));
}

// ══ 1e-core: dispatchAuthenticated(capability 인가 배선) 테스트(헤드리스, 주입 store) ══════════════════════
const n_all: cap.Nonce = [_]u8{0x01} ** cap.nonce_len;
const n_win: cap.Nonce = [_]u8{0x02} ** cap.nonce_len;
const n_browser: cap.Nonce = [_]u8{0x03} ** cap.nonce_len;
const n_unknown: cap.Nonce = [_]u8{0xEE} ** cap.nonce_len;

// 5f-4a: 단일 nonce(또는 null)를 dispatchAuthenticated의 cap **집합** 슬라이스로(누적 시그니처 어댑터). buf 수명 안 유효.
fn noncesSlice(buf: *[1]cap.Nonce, nonce: ?cap.Nonce) []const cap.Nonce {
    if (nonce) |n| {
        buf[0] = n;
        return buf[0..1];
    }
    return &.{};
}

// 1e-confirm-1b: grant 없는 테스트용 빈 store(불변 공유). 이 파일 테스트는 cap 경로만 검증하므로 항상 빈 grant.
const no_grants: cpg.PaneGrantStore = .{};

// .immediate(응답 바이트) 기대 — 호출자 free. .browser면 op.arg free 후 실패(5e 라우팅 분리 검증).
fn authDispatch(bytes: []const u8, selector: ?u64, nonce: ?cap.Nonce, store: *const cap.CapabilityStore) ![]u8 {
    var buf: [1]cap.Nonce = undefined;
    switch (try dispatchAuthenticated(testing.allocator, bytes, fx, selector, noncesSlice(&buf, nonce), store, &no_grants, 0)) {
        .immediate => |b| return b,
        .browser => |op| {
            testing.allocator.free(op.arg);
            return error.ExpectedImmediateGotBrowser;
        },
        .subscribe => return error.ExpectedImmediateGotSubscribe, // 이 헬퍼는 subscribe 요청 안 씀
        .needs_grant => return error.ExpectedImmediateGotNeedsGrant, // 이 헬퍼 테스트는 grant 조회 안 태움(selector+미grant browser는 별도 헬퍼)
    }
}
// .browser(op) 기대 — 호출자 op.arg free. .immediate면 free 후 실패.
fn authDispatchOp(bytes: []const u8, selector: ?u64, nonce: ?cap.Nonce, store: *const cap.CapabilityStore) !cb.BrowserOp {
    var buf: [1]cap.Nonce = undefined;
    switch (try dispatchAuthenticated(testing.allocator, bytes, fx, selector, noncesSlice(&buf, nonce), store, &no_grants, 0)) {
        .browser => |op| return op,
        .immediate => |b| {
            testing.allocator.free(b);
            return error.ExpectedBrowserGotImmediate;
        },
        .subscribe => return error.ExpectedBrowserGotSubscribe,
        .needs_grant => return error.ExpectedBrowserGotNeedsGrant,
    }
}
// 1e-confirm-1c: .needs_grant(미grant valid browser 요청) 기대 — GrantRequest 반환.
fn authDispatchNeedsGrant(bytes: []const u8, selector: ?u64, nonce: ?cap.Nonce, store: *const cap.CapabilityStore) !cb.GrantRequest {
    var buf: [1]cap.Nonce = undefined;
    switch (try dispatchAuthenticated(testing.allocator, bytes, fx, selector, noncesSlice(&buf, nonce), store, &no_grants, 0)) {
        .needs_grant => |g| return g,
        .immediate => |b| {
            testing.allocator.free(b);
            return error.ExpectedNeedsGrantGotImmediate;
        },
        .browser => |op| {
            testing.allocator.free(op.arg);
            return error.ExpectedNeedsGrantGotBrowser;
        },
        .subscribe => return error.ExpectedNeedsGrantGotSubscribe,
    }
}

test "dispatchAuthenticated: nonce 없음 → 기존 self 경로(회귀 없음) — selector=10 sessions.list → 10만" {
    var store: cap.CapabilityStore = .{};
    defer store.deinit(testing.allocator);
    const wire = try authDispatch("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sessions.list\"}", 10, null, &store);
    defer testing.allocator.free(wire);
    var ids: std.ArrayList(u64) = .empty;
    defer ids.deinit(testing.allocator);
    try listIds(wire, &ids);
    try testing.expectEqualSlices(u64, &.{10}, ids.items); // cap 없음 = self only(기존 동작)
}

test "dispatchAuthenticated(§4a): 셀렉터 없는 연결은 sessions.list 로 전체를 본다 — 폰이 목록을 받는 자리" {
    var store: cap.CapabilityStore = .{};
    defer store.deinit(testing.allocator);
    // 중계(`maru control --stdio`)는 `auth.self` 를 **셀렉터 없이** 보낸다 — 폰의 `exec` 채널엔 `MARU_PANE_ID` 가
    // 없다. 그때 `.self`(anchor=0)로 두면 아무것도 안 맞아 폰 화면에 "세션이 없다" 만 떴다(실측).
    const wire = try authDispatch("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sessions.list\"}", null, null, &store);
    defer testing.allocator.free(wire);
    var ids: std.ArrayList(u64) = .empty;
    defer ids.deinit(testing.allocator);
    try listIds(wire, &ids);
    try testing.expectEqualSlices(u64, &.{ 10, 11, 20, 30 }, ids.items);
}

test "dispatchAuthenticated(§4a): 셀렉터를 대면 종전대로 그 surface 하나다 — 넓어진 것은 앵커 없는 쪽뿐" {
    var store: cap.CapabilityStore = .{};
    defer store.deinit(testing.allocator);
    const wire = try authDispatch("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sessions.list\"}", 20, null, &store);
    defer testing.allocator.free(wire);
    var ids: std.ArrayList(u64) = .empty;
    defer ids.deinit(testing.allocator);
    try listIds(wire, &ids);
    try testing.expectEqualSlices(u64, &.{20}, ids.items);
}

test "dispatchAuthenticated(§8.3): 셀렉터가 없어도 read-output 은 안 넘는다 — session.capture 는 그대로 unauthorized" {
    var store: cap.CapabilityStore = .{};
    defer store.deinit(testing.allocator);
    // metadata 를 넓힌 것이 capture 까지 넓히면 화면 내용이 새어 나간다. **경계는 metadata 안쪽에서만 움직였다.**
    const wire = try authDispatch("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session.capture\",\"params\":{\"id\":10}}", null, null, &store);
    defer testing.allocator.free(wire);
    try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.unauthorized)), try errCode(wire));
}

test "dispatchAuthenticated(§9.6): browser.list → cap·selector 없이 web surface만(ungated 발견, 터미널 제외)" {
    var store: cap.CapabilityStore = .{};
    defer store.deinit(testing.allocator);
    // 발견은 ungated — nonce null·selector null이어도 통과(제어와 달리 cap/grant/모달 불요). fx의 web은 surface 11(markdown)뿐.
    const wire = try authDispatch("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.list\"}", null, null, &store);
    defer testing.allocator.free(wire);
    var pm = try cp.parseMessage(testing.allocator, wire);
    defer pm.deinit();
    const arr = pm.message.response.result.?.object.get("surfaces").?.array;
    try testing.expectEqual(@as(usize, 1), arr.items.len); // web 11만(터미널 10/20/30 제외)
    const o = arr.items[0].object;
    try testing.expectEqual(@as(i64, 11), o.get("id").?.integer);
    try testing.expectEqualStrings("https://x/y", o.get("url").?.string);
    try testing.expectEqualStrings("docs", o.get("title").?.string);
    try testing.expectEqualStrings("markdown", o.get("panel_kind").?.string);
}

test "dispatchAuthenticated: metadata:all cap(surface 10) → sessions.list 전체(10,11,20,30)" {
    var store: cap.CapabilityStore = .{};
    defer store.deinit(testing.allocator);
    try store.issueForFd(testing.allocator, n_all, .{ .surface_id = 10, .generation = 0, .scope = .{ .metadata = .all } });
    const wire = try authDispatch("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sessions.list\"}", 10, n_all, &store);
    defer testing.allocator.free(wire);
    var ids: std.ArrayList(u64) = .empty;
    defer ids.deinit(testing.allocator);
    try listIds(wire, &ids);
    try testing.expectEqualSlices(u64, &.{ 10, 11, 20, 30 }, ids.items); // cap이 self보다 넓은 scope 발급
}

test "dispatchAuthenticated: metadata:window cap(surface 10) → 창 A(10,11)만" {
    var store: cap.CapabilityStore = .{};
    defer store.deinit(testing.allocator);
    try store.issueForFd(testing.allocator, n_win, .{ .surface_id = 10, .generation = 0, .scope = .{ .metadata = .window } });
    const wire = try authDispatch("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sessions.list\"}", 10, n_win, &store);
    defer testing.allocator.free(wire);
    var ids: std.ArrayList(u64) = .empty;
    defer ids.deinit(testing.allocator);
    try listIds(wire, &ids);
    try testing.expectEqualSlices(u64, &.{ 10, 11 }, ids.items);
}

test "dispatchAuthenticated(22차 [1]): 미지 nonce는 아무 권한도 안 더함 → ambient self-origin으로 폴백(자기 surface만)" {
    var store: cap.CapabilityStore = .{};
    defer store.deinit(testing.allocator);
    // 빈 store(라이브 앱의 fd 발급 전 상태)에 미지 nonce 제시 → cap이 아무것도 인가 못 함. 그러나 self-origin ambient
    // access는 유지(22차 [1] — 유효 cap이 아니면 revoke도 elevate도 안 함) → 자기 surface(selector=10)만. **넓은 scope
    // 상승 없음**(전체 리스트 아님 — 미지 cap이 default-deny인 건 그대로, 단 ambient self는 안 잃음).
    const wire = try authDispatch("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sessions.list\"}", 10, n_unknown, &store);
    defer testing.allocator.free(wire);
    var ids: std.ArrayList(u64) = .empty;
    defer ids.deinit(testing.allocator);
    try listIds(wire, &ids);
    try testing.expectEqualSlices(u64, &.{10}, ids.items); // self scope만 — 미지 cap이 metadata:all로 elevate 안 함
}

test "dispatchAuthenticated(22차 [1]): cap surface≠anchor는 그 cap scope로 상승 안 함 → self-origin 폴백(자기 surface만)" {
    var store: cap.CapabilityStore = .{};
    defer store.deinit(testing.allocator);
    // cap은 surface 20에 묶인 metadata:all인데 caller가 anchor 10을 주장 → surface_mismatch로 이 cap은 인가 못 함.
    // self-origin 폴백 → 자기 surface(10)만. **핵심 보안**: surface 20용 cap이 anchor 10에서 metadata:all(전체 열거)로
    // 새지 않는다(폴백은 self scope=[10]이지 all=[10,11,20,30]이 아님).
    try store.issueForFd(testing.allocator, n_all, .{ .surface_id = 20, .generation = 0, .scope = .{ .metadata = .all } });
    const wire = try authDispatch("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sessions.list\"}", 10, n_all, &store);
    defer testing.allocator.free(wire);
    var ids: std.ArrayList(u64) = .empty;
    defer ids.deinit(testing.allocator);
    try listIds(wire, &ids);
    try testing.expectEqualSlices(u64, &.{10}, ids.items); // self만 — surface_mismatch cap이 all로 elevate 안 함
}

// 5e: browser.*는 control_browser에 위임(anchor=target web surface, selector 무관) → 모든 게이트 통과면 **.browser op**.
// metadata cap + browser.* = scope 불충족 unauthorized(.immediate). browser cap + 비-browser = scope 불충족 unauthorized.
// browser 경로(target 앵커)와 metadata resolve 경로(selector 앵커)의 분리를 증명한다.
test "dispatchAuthenticated 5e/1c: browser cap → .browser op; 미인가 cap+pane → needs_grant; browser cap+sessions.list → self-origin" {
    var store: cap.CapabilityStore = .{};
    defer store.deinit(testing.allocator);
    // cap은 **web surface 11**(fx: web/markdown)에 묶임 — browser cap의 anchor는 target이다.
    try store.issueForFd(testing.allocator, n_browser, .{ .surface_id = 11, .generation = 0, .scope = .browser });
    try store.issueForFd(testing.allocator, n_all, .{ .surface_id = 11, .generation = 0, .scope = .{ .metadata = .all } });

    const req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.navigate\",\"params\":{\"id\":11,\"url\":\"https://x\"}}";
    // browser cap → control_browser 위임 → 모든 게이트 통과 → .browser op. **selector=99(자기 surface)와 무관**(target 11 앵커).
    const op = try authDispatchOp(req, 99, n_browser, &store);
    defer testing.allocator.free(op.arg);
    try testing.expectEqual(@as(u64, 11), op.surface_id);
    try testing.expectEqual(cb.BrowserMethod.navigate, op.method);
    try testing.expectEqualStrings("https://x", op.arg);
    try testing.expectEqual(n_browser, op.capability_nonce.?); // callback 재인가용 실제 선택 nonce 값 복사
    try testing.expectEqual(@as(u64, 0), op.capability_generation.?);
    // metadata cap으로 browser.navigate(selector=11=pane): scope 불충족이나 pane이 확인 모달로 grant받을 수 있음 →
    // **needs_grant**(1e-confirm-1c — 옛 즉시 unauthorized 아님; self-authenticated pane은 prompt 대상).
    const g_deny = try authDispatchNeedsGrant(req, 11, n_all, &store);
    try testing.expectEqual(@as(u64, 11), g_deny.pane);
    try testing.expectEqual(@as(u64, 11), g_deny.target);
    try testing.expectEqual(cap.ScopeClass.browser, g_deny.scope);
    // browser cap으로 sessions.list(metadata, 비-browser 경로): cap이 metadata를 인가 못 하나 **ambient self-origin
    // 폴백**(22차 [1] — cap 제시가 self-access를 revoke하지 않음) → 자기 surface(selector=11)만 반환(성공, unauthorized 아님).
    const w_self = try authDispatch("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sessions.list\"}", 11, n_browser, &store);
    defer testing.allocator.free(w_self);
    var pm_self = try cp.parseMessage(testing.allocator, w_self);
    defer pm_self.deinit();
    try testing.expect(pm_self.message == .response and pm_self.message.response.result != null); // self-origin 성공
}

// 22차 [1] 회귀: auth.self(no cap, self-origin) 세션이 auth.grant로 cap을 **누적**해도 자기 surface metadata를 계속
// 읽을 수 있어야 한다(옛 singular 모델은 cap 하나만 제시해도 self 폴백을 잃어 unauthorized였다 — cap은 권한을 *더함*).
test "dispatchAuthenticated(22차 [1]): browser cap 누적 후에도 self-origin metadata 폴백 유지(revoke 아님)" {
    var store: cap.CapabilityStore = .{};
    defer store.deinit(testing.allocator);
    try store.issueForFd(testing.allocator, n_browser, .{ .surface_id = 11, .generation = 0, .scope = .browser });
    const list = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sessions.list\"}";

    // (a) cap 없음(no-cap shell): self-origin → 자기 surface(10)만.
    const w_nocap = try authDispatch(list, 10, null, &store);
    defer testing.allocator.free(w_nocap);
    // (b) browser cap 누적: self-origin 폴백은 여전히 유효 → (a)와 **바이트 동일**(cap이 metadata를 안 건드림).
    const w_cap = try authDispatch(list, 10, n_browser, &store);
    defer testing.allocator.free(w_cap);
    try testing.expectEqualStrings(w_nocap, w_cap); // 누적이 self-metadata를 revoke하지 않음
    // 둘 다 성공 응답(자기 surface 10 포함).
    var pm = try cp.parseMessage(testing.allocator, w_cap);
    defer pm.deinit();
    try testing.expect(pm.message == .response and pm.message.response.result != null);
}

// 5f-4a cap 누적(§9.5.6 ③): 세션이 cap 여러 개를 보유하면 요청은 그중 **하나라도** 인가하면 통과한다. navigate(browser)와
// sessions.list(metadata)가 각기 다른 cap으로 인가되는 게 핵심(다중 scope를 single-scope cap 누적으로).
test "dispatchAuthenticated(5f-4a): cap 집합 — 하나라도 인가하면 통과(누적), 아무도 없으면 균일 unauthorized" {
    var store: cap.CapabilityStore = .{};
    defer store.deinit(testing.allocator);
    try store.issueForFd(testing.allocator, n_browser, .{ .surface_id = 11, .generation = 0, .scope = .browser }); // web surface 11
    try store.issueForFd(testing.allocator, n_all, .{ .surface_id = 10, .generation = 0, .scope = .{ .metadata = .all } });
    const nav = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.navigate\",\"params\":{\"id\":11,\"url\":\"data:,x\"}}";

    // 집합 [metadata, browser] → browser cap이 navigate를 인가(앞의 metadata cap이 deny여도 다음 cap 시도) → .browser op.
    switch (try dispatchAuthenticated(testing.allocator, nav, fx, null, &[_]cap.Nonce{ n_all, n_browser }, &store, &no_grants, 0)) {
        .browser => |op| testing.allocator.free(op.arg),
        .immediate => |b| {
            testing.allocator.free(b);
            return error.ExpectedBrowserGotImmediate;
        },
        .subscribe => return error.ExpectedBrowser,
        .needs_grant => return error.ExpectedBrowser,
    }
    // 집합 [metadata only] → browser 인가 cap 없음 → 균일 unauthorized(.immediate 에러).
    switch (try dispatchAuthenticated(testing.allocator, nav, fx, null, &[_]cap.Nonce{n_all}, &store, &no_grants, 0)) {
        .immediate => |b| {
            defer testing.allocator.free(b);
            try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.unauthorized)), try errCode(b));
        },
        .browser => |op| {
            testing.allocator.free(op.arg);
            return error.ExpectedUnauthorized;
        },
        .subscribe => return error.ExpectedUnauthorized,
        .needs_grant => return error.ExpectedUnauthorized,
    }
    // metadata 경로도 누적: sessions.list는 metadata cap 필요. [browser, metadata:all(anchor 10)] + selector=10 → metadata 인가.
    const list = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"sessions.list\"}";
    switch (try dispatchAuthenticated(testing.allocator, list, fx, 10, &[_]cap.Nonce{ n_browser, n_all }, &store, &no_grants, 0)) {
        .immediate => |b| {
            defer testing.allocator.free(b);
            var pm = try cp.parseMessage(testing.allocator, b);
            defer pm.deinit();
            try testing.expect(pm.message == .response and pm.message.response.result != null); // 인가 성공(에러 아님)
        },
        .browser => |op| {
            testing.allocator.free(op.arg);
            return error.ExpectedImmediate;
        },
        .subscribe => return error.ExpectedImmediate,
        .needs_grant => return error.ExpectedImmediate,
    }
}

// 리뷰 [2]/1e-confirm-1c: cap_nonce **없는** browser.*와 **미지 nonce**가 응답이 안 갈려야 한다(§8.3 nonce 유무
// oracle 방지). pane selector가 있으면 둘 다 **동일 needs_grant**(pane이 grant받을 수 있음 — 옛 즉시 unauthorized에서
// Model B로 바뀜). 확인 대기라는 결과가 nonce 유무로 안 갈리므로 oracle은 여전히 없다.
test "dispatchAuthenticated 5e[2]/1c: cap 없는/미지 nonce browser.navigate → 동일 needs_grant(nonce 유무 무oracle)" {
    var store: cap.CapabilityStore = .{};
    defer store.deinit(testing.allocator);
    const req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.navigate\",\"params\":{\"id\":11,\"url\":\"https://x\"}}";
    // nonce 없음(cap fd 못 받은 pane) + 미지 nonce(빈 store) → 둘 다 needs_grant, 같은 GrantRequest(pane 11·target 11·browser).
    const g_none = try authDispatchNeedsGrant(req, 11, null, &store);
    const g_unknown = try authDispatchNeedsGrant(req, 11, n_unknown, &store);
    try testing.expectEqual(g_none.pane, g_unknown.pane); // nonce 유무로 안 갈림
    try testing.expectEqual(g_none.target, g_unknown.target);
    try testing.expectEqual(g_none.scope, g_unknown.scope);
    try testing.expectEqual(@as(u64, 11), g_none.pane);
    try testing.expectEqual(@as(u64, 11), g_none.target);
    try testing.expectEqual(cap.ScopeClass.browser, g_none.scope);
}

// 리뷰 [4] 회귀: read_output은 non-metadata지만 session.capture를 **실제로 인가**하는 유일한 scope다(다른 non-metadata
// method는 read-only 라우터에 아예 없어 자연히 method_not_found). read_output cap+capture가 라우터로 새면 라우터의
// capture 특수 unauthorized에 오접힌다 → non-metadata granted는 라우터 우회로 직접 method_not_found여야 한다.
test "dispatchAuthenticated: read_output cap + session.capture → method_not_found(미배선), metadata cap → unauthorized(scope)" {
    const cap_req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session.capture\",\"params\":{\"id\":10}}";
    // read_output cap(TTL 필수)이 capture를 인가(resolve grant) → 라이브 미배선(1f) → method_not_found(unauthorized 아님).
    {
        var store: cap.CapabilityStore = .{};
        defer store.deinit(testing.allocator);
        try store.issueForFd(testing.allocator, n_browser, .{ .surface_id = 10, .generation = 0, .scope = .read_output, .expires_at = 1000 });
        const wire = try authDispatch(cap_req, 10, n_browser, &store); // now=0 < 1000 유효
        defer testing.allocator.free(wire);
        try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.method_not_found)), try errCode(wire));
    }
    // 대조: metadata cap으로 capture → 구조적 read_output 미충족 → unauthorized.
    {
        var store: cap.CapabilityStore = .{};
        defer store.deinit(testing.allocator);
        try store.issueForFd(testing.allocator, n_all, .{ .surface_id = 10, .generation = 0, .scope = .{ .metadata = .all } });
        const wire = try authDispatch(cap_req, 10, n_all, &store);
        defer testing.allocator.free(wire);
        try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.unauthorized)), try errCode(wire));
    }
}

test {
    testing.refAllDecls(@This());
}
