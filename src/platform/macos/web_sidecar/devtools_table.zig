//! sidecar 가 쥔 DevTools 호출 표(W9-0b — CEF 를 모르는 부분, `pure_tests`). maru 가 `devtools_call` 로 시작하고 인자 조각
//! (`devtools_call_data`)을 다 보내면 CDP 메시지(`{"id","method","params"}`)를 만들어 CEF 에 보낸다(`devtools.zig`). 답은 그
//! 메시지 번호로 찾는다.
//!
//! - 메시지 번호는 다른 DevTools 사용처와 겹치지 않는 대역 `[1<<29, 1<<30)` 이다 — 권한(0 부터)·알림(20000 부터)·미디어 메뉴
//!   (1<<30 부터). 관찰자는 브라우저의 DevTools 세션을 함께 쓰므로 모두가 모든 결과를 받는다 — 대역으로 제 것만 고른다.
//! - 인자는 JSON **객체** 하나여야 한다 — 그대로 이어 붙이므로, 객체가 아니면(`1},"id":7`) 메시지 모양을 바꿀 수 있다. 메서드
//!   이름은 wire 가 이미 영숫자와 `.` 로 닫았다.
//! - 자리는 전체 `max_devtools_calls`·탭마다 `max_devtools_calls_per_browser` 개 — maru 도 그만큼만 기다리지만, 답을 영영 못 받는
//!   호출(렌더러가 멈추면 CDP 는 답도 detach 도 주지 않는다)이 자리를 막지 않게 `stale_ms` 가 지난 것은 `takeStale` 이 꺼낸다
//!   (`devtools.zig` 가 주기적으로). 탭마다 상한이 있어 멈춘 페이지 하나가 다른 탭의 호출을 막지 못한다.
//! - 인자 중첩 깊이도 본다 — CDP 파서의 깊이 한도를 넘으면 번호 없는 오류가 나 그 호출은 답을 받지 못한다.

const array_repeat = @import("array_repeat");

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const message = protocol.message;
const BrowserId = message.BrowserId;

pub const capacity = message.max_devtools_calls;
pub const id_base: i32 = 1 << 29;
pub const id_end: i32 = 1 << 30;

pub const Phase = enum { collecting, sent };

pub const Call = struct {
    browser: BrowserId,
    call: u32,
    method_buf: [message.max_devtools_method_bytes]u8 = undefined,
    method_len: usize,
    params: std.ArrayList(u8) = .empty,
    params_size: u32,
    phase: Phase = .collecting,
    /// 보낸 CDP 메시지 번호(보내기 전 0).
    cdp_id: i32 = 0,
    started_ms: i64,
    /// maru 의 kick(`message.devtools_kick_*` 와 꼭 같은 호출) — 짧은 시한(`kick_stale_ms`)에 놓는다(W9b②-3 적대 리뷰 3 회차).
    kick: bool = false,

    pub fn method(self: *const Call) []const u8 {
        return self.method_buf[0..self.method_len];
    }

    /// 인자를 다 받았는가(인자 없는 호출은 처음부터).
    pub fn complete(self: *const Call) bool {
        return self.params.items.len == self.params_size;
    }

    pub fn deinit(self: *Call, gpa: std.mem.Allocator) void {
        self.params.deinit(gpa);
    }
};

pub const BeginError = error{ Busy, Duplicate, Forbidden };

/// maru 를 거쳐 오는 호출이 부를 수 없는 메서드(W9d② — J4·J6·J13): `Network.enable`·`Network.disable` 은 본문 기록이 건 버퍼 상한을 바꾸거나
/// (disable 뒤 enable {} 이면 12 MB 본문이 돌아왔다 — J4-D) 기록을 말없이 끈다(J6). `Fetch.*` 는 요청을 가로채 바꾼다(막기·가짜 응답은 따로
/// 묻는 W9d③·④ 의 몫이다). 세션이 하나라 이 호출과 sidecar 의 기록이 같은 Network 도메인을 쓴다.
///
/// 재검증 5 차 S1(서비스 워커 갈래 새 설계 — 공격 2 A7·A16): `Target.*` 도 막는다 — 같은 세션에 sidecar 가 서비스 워커 auto-attach 를 건다.
/// 떼면(`setAutoAttach`·`detachFromTarget`) 워커 사건이 말없이 끊기고 멈춰 붙은 워커가 놓이기 앞에 떼어 영영 멈출 수 있으며(재검증 12 차 —
/// sidecar 는 새로 뜨는 워커를 멈춰 붙여 enable 뒤에 놓는다; 그 차례를 바꾸면 눈먼 때가 다시 생긴다), 다른 탭·브라우저 전체를 본다
/// (`setDiscoverTargets`). `Runtime.runIfWaitingForDebugger` 는 페이지 세션의 것이라 워커를 놓지 않는다(해가 없다 — 판정 `swwait-agent`). maru 가 쓰는 꼴 하나 — 인자 없는 `getTargetInfo`(그 탭 자신의
/// 주소: localStorage 의 출처 확인 — `web_cdp_storage.zig` 가 `{}` 로 보낸다)만 받는다(`targetParamsAllowed`). 재검증 6 차 F11: 전에는
/// `getTargets`·`activateTarget`·`targetId` 를 준 `getTargetInfo` 도 받아, 이 길을 쓰는 쪽이 다른 탭(사용자 탭 포함)의 주소와 다른 사이트 서비스
/// 워커의 스크립트 주소를 보고 다른 탭을 앞으로 올릴 수 있었다(v20l r11 실측 — 지금은 에이전트가 메서드를 고를 길이 없어 해가 없었다).
pub fn forbiddenMethod(method: []const u8) bool {
    if (std.mem.eql(u8, method, "Network.enable") or std.mem.eql(u8, method, "Network.disable")) return true;
    // W9d③: 막기·엄격 모드와 같은 것을 scope·⊘ 없이 바꾸는 길(§12 P1-11) — 서비스 워커 우회는 sidecar 의 `net_domain` 만 보낸다.
    // 20 회 검증 B DEF-4 와 표면 훑기(CDP Network·Fetch·Emulation — 기준: 막기를 피하거나 흉내 내는가):
    //   - `emulateNetworkConditionsByRule` — 주소 패턴마다 offline(실측 CEF 154: fetch TypeError, 서버 0 — 규칙 없는 막기).
    //   - `continueInterceptedRequest` — 가로챈 요청을 바꿔 보낸다(가로채기는 이미 막지만 짝을 함께 막는다).
    //   - `loadNetworkResource` — 프로필의 쿠키로 탭 길 밖에서 주소를 받아 온다(막힌 주소를 규칙 밖에서 받는 길 — 재지 않았다, 방어).
    //   남긴 것: `overrideNetworkState`(navigator.onLine 만 — 실측 fetch 는 그대로), `setCacheDisabled`(HTTP 캐시 응답도 막기가 본다),
    //   `setExtraHTTPHeaders`·`setUserAgentOverride`·쿠키(패턴은 주소만 본다), `replayXHR`(탭 길로 다시 가 막힌다), Emulation 의 요청 관련 없음.
    for ([_][]const u8{
        "Network.setBypassServiceWorker",
        "Network.setBlockedURLs",
        "Network.setRequestInterception",
        "Network.continueInterceptedRequest",
        "Network.emulateNetworkConditions",
        "Network.emulateNetworkConditionsByRule",
        "Network.loadNetworkResource",
    }) |m| {
        if (std.mem.eql(u8, method, m)) return true;
    }
    // 2 차 검증 NEW-1: 지킴은 바깥 메서드 이름만 본다 — `Target` 은 그 안에 다른 CDP 를 싣는 길이다(실측 CEF 154: `attachToTarget{flatten:false}`
    // 뒤 `sendMessageToTarget` 이 실은 `Network.enable`·`Network.setBlockedURLs` 가 지나 fetch 가 막혔다, 서버 0). 훑기(CDP 1.3 의 모든 도메인 —
    // 기준: 다른 세션·다른 브라우저를 열거나 메시지를 옮기는가): `Target.attachToTarget`·`attachToBrowserTarget`·`setAutoAttach`·`autoAttachRelated`
    // (둘째 세션), `sendMessageToTarget`(옮기기), `exposeDevToolsProtocol`(페이지 JS 에 CDP), `createTarget`·`createBrowserContext`(maru 가 모르는
    // 브라우저 — 규칙이 없다)·`closeTarget`·`activateTarget`·`detachFromTarget`·`setDiscoverTargets`·`setRemoteLocations`. 그래서 `Target.*` 를 모두
    // 막고 maru 가 쓰는 읽기 하나(`getTargetInfo` — 저장소 op 의 출처 확인)만 둔다. 다른 도메인에는 세션을 여는 메서드가 없다(`ServiceWorker.*` 는
    // 워커 상태만 — 그 요청은 서비스 워커 길로 와 막기가 본다, `Runtime.addBinding` 은 페이지 JS 에 함수만, `Browser.*`·`Tethering.*` 는 브라우저
    // 세션 것이라 탭 세션에서 듣지 않는다).
    // 재검증 6 차 F11(W9d②): 그 읽기도 인자 없는 꼴만 — `targetId` 를 준 `getTargetInfo` 는 다른 탭을 본다(`targetParamsAllowed`).
    if (std.mem.startsWith(u8, method, "Target.")) return !std.mem.eql(u8, method, target_info_method);
    // 3 차 검증 N-B3-f: `Browser.executeBrowserCommand`(예: openTabSearch)는 CEF 154 에서 답하지 않고 그 탭의 뒤 DevTools 호출·`Runtime.evaluate` 를
    // 모두 멈추게 했다(실측 — 첫 훑기에서 남은 29 호출이 함께 멈췄다). maru 는 쓰지 않는다 — 막기와 무관한 방어.
    if (std.mem.eql(u8, method, "Browser.executeBrowserCommand")) return true;
    return std.mem.startsWith(u8, method, "Fetch.");
}

const target_info_method = "Target.getTargetInfo";

/// 재검증 6 차 F11: `Target.getTargetInfo` 는 인자가 없을 때만(빈 값 또는 빈 객체 `{}` — 공백은 받는다) — `targetId` 를 주면 다른 탭을 본다.
/// 다른 메서드는 여기서 보지 않는다(참). 인자 글 전체가 오기 전(`begin`)에는 크기로만 거른다(`target_params_max`).
pub fn targetParamsAllowed(method: []const u8, params: []const u8) bool {
    if (!std.mem.eql(u8, method, target_info_method)) return true;
    const p = std.mem.trim(u8, params, " \t\r\n");
    if (p.len == 0) return true;
    if (p[0] != '{' or p[p.len - 1] != '}') return false;
    return std.mem.trim(u8, p[1 .. p.len - 1], " \t\r\n").len == 0;
}

/// 인자 없는 `getTargetInfo` 의 인자 글이 가질 수 있는 크기의 위 끝(공백을 넉넉히) — 넘으면 `begin` 에서 곧 막는다.
const target_params_max: u32 = 64;

/// 에이전트의 이 DevTools 호출이 주 프레임 이동을 시작할 수 있는가(W9d③ 2 차 검증 LOW-A2-3) — 그러면 sidecar 가 그 탭의 산 사용자 D2 토큰을
/// **다툼**으로 둔다(W9d④ v1 검증 SEVERE-2 부터 — 전에는 거뒀고, 그러면 겹친 `Runtime.evaluate` 하나로 사용자가 친 주소·새로 고침이 막힘·가짜가
/// 됐다: `net_block_table.agentDevtoolsCall`). 에이전트의 뒤로·앞으로·새로 고침은 wire `nav_action` 이 아니라 CDP `Page.navigateToHistoryEntry`·
/// `Page.reload` 다 — 실측: 사용자의 iframe 만 옮긴 뒤로·조각만 다른 친 주소가 남긴 토큰을 그것이 가져갔다(그 둘은 따로 거둔다 — 기록 토큰 정리·
/// 같은 문서 확정). 누르기·키·스크립트도 링크·폼·`location` 으로 이동을 시작할 수 있고, 페이지의
/// 처리기를 부르는 호출(3 차 검증 N-A3-3 — scroll·focus·input·DOM 바꾸기·`Emulation.*` 등)도 같다.
/// **허용 목록을 뒤집었다**(4 차 검증 A-LOW: 「거두는 목록」 에 `Page.handleJavaScriptDialog`(멈춘 스크립트를 잇는다)·`Page.setWebLifecycleState`
/// (freeze·resume 처리기)·`CSS.setStyleTexts`(transitionend·관찰자 처리기)·`Animation.seekAnimations`·`DOMStorage.setDOMStorageItem`(다른 문서의
/// storage 처리기)·`ServiceWorker.dispatchSyncEvent`·`skipWaiting`(controllerchange — 흔히 `location.reload()`)이 빠져 있었다 — 새 메서드가 생겨도
/// 빠진다): 아래 **읽기**(처리기를 부르지도 스크립트를 잇지도 않는다)만 다툼 없이 두고 나머지는 모두 다툼으로 둔다. 대가(v1 SEVERE-2 뒤): 다툼의
/// 창 안에서 에이전트가 같은 주소·같은 갈래로 몬 이동도 사용자 것으로 지나간다(막힘·가짜 없이 — 사용자 쪽 fail-safe).
pub fn startsNavigation(method: []const u8) bool {
    for (read_only_methods) |m| {
        if (std.mem.eql(u8, method, m)) return false;
    }
    return true;
}

/// 다 모인 호출 하나(메서드와 인자)가 토큰을 거둘 호출인가 — 이름(`startsNavigation`)에 더해, 읽기 목록의 메서드라도 인자 때문에 페이지 스크립트를
/// 돌리면 거둔다(5 차 검증 LOW: `Page.captureScreenshot{captureBeyondViewport:true}` 는 화면 밖까지 찍으려 보기 크기를 늘렸다 되돌려 페이지의
/// `resize` 처리기를 두 번 돌렸다 — 실측 resize +4, clip 이 있어도). 인자를 읽지 못하면(JSON 이 아니다·같은 열쇠 둘·값의 꼴이 다르다) 거둔다.
/// 목록에 남은 다른 메서드는 인자로도 스크립트를 돌리지 않는다(실측 — `read_only_methods` 의 주석). 인자와 무관하게 페이지 스크립트를 돌리는
/// 메서드는 인자를 볼 것 없이 목록 밖이다(6 차 검증 LOW: `Runtime.getProperties`). `gpa` 는 인자 풀기에만 잠깐 쓴다.
pub fn startsNavigationCall(gpa: std.mem.Allocator, method: []const u8, params: []const u8) bool {
    if (startsNavigation(method)) return true;
    if (!std.mem.eql(u8, method, "Page.captureScreenshot") or params.len == 0) return false;
    const Shot = struct { captureBeyondViewport: ?bool = null };
    const parsed = std.json.parseFromSlice(Shot, gpa, params, .{ .ignore_unknown_fields = true }) catch return true;
    defer parsed.deinit();
    return parsed.value.captureBeyondViewport orelse false;
}

/// 토큰을 남기는 에이전트의 DevTools 호출 — 페이지의 처리기를 부르지 않는 읽기(maru 의 snapshot·찾기·화면 찍기·저장소 읽기·DevTools kick
/// `Page.captureScreenshot` 이 쓰는 것과 같은 꼴). 넣을 때의 기준: 페이지 스크립트를 돌리거나 잇지 않고, DOM·스타일·저장소·기록·창을 바꾸지 않는다.
/// **페이지의 JS 값을 설명하는 메서드는 넣지 않는다** — V8 은 값의 설명을 만들며 늦은 접근자로 페이지 함수를 부를 수 있다(6 차 검증 LOW: 전에 든
/// `Runtime.getProperties` 는 아직 읽지 않은 Error 값마다 그 `stack` 의 꼴을 만들며 페이지의 `Error.prepareStackTrace` 를 한 번씩 돌렸다 —
/// `ownProperties`·`generatePreview` 와 무관하게, `window` 에도, 실측 2/2. 그래서 뺐다 — 거둔다. maru 의 흐름은 getProperties 를 쓰지 않는다).
/// **페이지가 건너뛰게 한 하위 트리의 스타일·배치를 강제하는 메서드도 넣지 않는다** — 강제하면 그 안의 글꼴·그림·`<object>` 를 요청해 페이지의
/// `document.fonts` 이벤트·`<object>` onload·PerformanceObserver 처리기가 돈다(7 차 검증 LOW-1: 전에 든 `DOM.getBoxModel` 이 `content-visibility:hidden`
/// 하위 트리 안의 노드에서 요청·marks +10, 실측 2/2. 같은 갈래를 목록의 다른 메서드에 쟀더니 `CSS.getComputedStyleForNode` 도 +10 — 둘 다 뺐다,
/// 거둔다. maru 의 흐름은 둘 다 쓰지 않는다). 같은 노드에서 `DOM.getContentQuads`·`describeNode`·`getOuterHTML`·`resolveNode`·`Accessibility.*`
/// (`getRootAXNode`·`getChildAXNodes` 는 켠 뒤)·`Page.getLayoutMetrics`, 화면 안 c-v:hidden 점의 `DOM.getNodeForLocation` 은 +0 이다(판정
/// `A7-R1b-read-list-skipped-subtree`). 화면 밖 `content-visibility:auto`·`hidden=until-found`·닫힌 `<details>` 의 하위 트리는 CEF 154 가 넣은 뒤 곧
/// 스타일·배치해(자원을 받는다 — 실측) 강제할 것이 남지 않고, `display:none` 하위 트리는 페이지 JS 의 강제로도 요청이 없다 — 그 넷에서도 모두 +0.
/// `Runtime.releaseObject(Group)`·`terminateExecution` 은 읽기는 아니지만 남긴다 — maru 가 대화상자가 닫힌 뒤로 미뤄 보내는 정리라 사용자의 떠나기
/// 확인 답과 같은 때에 온다(거두면 그 사용자의 이동이 막힌다); 멈춤은 페이지 스크립트를 끊을 뿐 이동을 시작하지 않는다. 놓기 자체는 처리기를 부르지
/// 않지만 **GC 뒤 페이지의 `FinalizationRegistry` 콜백이 돌 수 있다**(7 차 검증 LOW-3: 페이지가 놓고 DevTools 만 쥔 객체를 놓으면 다음 GC 뒤 그 콜백이
/// 돌았다, 실측 2/2 — 시점은 GC 가 정한다) — 남는 틈, 페이지 타이머와 같은 등급(3·4 차의 문서화된 틈).
/// 인자도 본다(5 차 검증 LOW — `startsNavigationCall`): 화면 찍기의 `captureBeyondViewport:true` 는 보기 크기를 바꿔 `resize` 처리기를 돌린다 — 거둔다.
/// 남은 메서드의 인자는 훑어 보았다(CDP 1.3): DOM 의 `depth`·`pierce`·`includeShadowDOM`·`includeUserAgentShadowDOM`·`ignorePointerEventsNone`·선택자,
/// Accessibility 의 `depth`·`frameId`·이름·역할, 화면 찍기의 `clip`(보기 크기가 아닌 보기 변환)·`fromSurface`·`format`·`quality`·`optimizeForSpeed`,
/// 쿠키·저장소의 `urls`·출처는 배치·스타일 계산·읽기뿐이다(배치는 `ResizeObserver`·`IntersectionObserver` 를 부르지 않는다 — 그것은 렌더 차례에 돈다).
/// **숨은 탭에서는 화면 찍기가 렌더 차례를 한 번 돈다**(7 차 검증 LOW-2: kick 꼴도 `{}` 도 숨은 탭의 rAF·ResizeObserver·IntersectionObserver 를
/// 한 번씩 돌렸다, +3 실측 2/2 — 숨은 탭은 스스로는 부르지 않는다) — 남는 틈, 페이지 타이머와 같은 등급. kick 은 그 목적 자체가 숨은 탭의 rAF 를
/// 돌리는 것이라(W9b②-3 — 숨은 탭에서 rAF 로 나타나는 요소) 목록에서 뺄 수 없다. 숨은 탭은 사용자가 몰지 않는다.
/// 실측(CEF 154): 판정 `A5-R10-read-only-runs-no-script`(getter·Proxy 트랩·custom element getter·resize·scroll·visualViewport·IntersectionObserver
/// 를 단 **보이는 탭** — kick 꼴·화면 밖 clip·clip scale 2 포함 marks 0, 화면 밖까지 찍기만 resize +2·visualViewport resize +3 씩)과 판정
/// `A6-R10-read-list-lazy-accessors`(getProperties 와 같은 갈래 — 읽지 않은 Error·`Error.captureStackTrace` 를 단 요소·`Symbol.toStringTag`
/// getter·`toJSON`·`Symbol.toPrimitive`, 그리고 ElementInternals·aria-labelledby·label·shadow·slot 을 거치는 접근성 이름 계산, custom element
/// 콜백, DOM 원형 getter 를 페이지가 덮어쓴 것, Mutation·Resize·Intersection 감시자, beforematch·화면 밖 content-visibility(auto·hidden 하위 트리의
/// 노드에 읽기)·details toggle·늦은 그림 — 을 단 페이지에서 남은 메서드 모두(`DOM.resolveNode`·`describeNode`·`Accessibility.*` 포함, 도메인을 켜야
/// 답하는 둘은 켠 뒤에도) marks 0, 같은 페이지의 getProperties 는 +3). `Network.getResponseBody` 는 실제 요청 번호로도 쟀다 — 에이전트에게
/// `Network.enable` 은 막혀 있으나 maru 의 응답 본문 기록(W9d② `net_record`)이 켠 탭에서는 같은 DevTools 세션이라 문서 요청의 번호(`Page.getFrameTree`
/// 의 `loaderId`)로 그 본문을 읽는다: marks 0(받아 둔 본문을 읽을 뿐 렌더러에 닿지 않는다).
pub const read_only_methods = [_][]const u8{
    "Accessibility.getFullAXTree", "Accessibility.getPartialAXTree", "Accessibility.queryAXTree", "Accessibility.getChildAXNodes",
    "Accessibility.getRootAXNode", "DOM.getDocument",                "DOM.querySelector",         "DOM.querySelectorAll",
    "DOM.describeNode",            "DOM.resolveNode",                "DOM.getContentQuads",       "DOM.getOuterHTML",
    "DOM.getAttributes",           "DOM.getNodeForLocation",         "Page.captureScreenshot",    "Page.getLayoutMetrics",
    "Page.getFrameTree",           "Page.getNavigationHistory",      "Page.getResourceTree",      "Runtime.releaseObject",
    "Runtime.releaseObjectGroup",  "Runtime.terminateExecution",     "Network.getCookies",        "Network.getResponseBody",
    "Storage.getCookies",          "Storage.getUsageAndQuota",       "Target.getTargetInfo",      "Browser.getVersion",
};

pub const AddResult = union(enum) {
    /// 모르는 호출 — 버린다(이미 실패로 답했다).
    unknown,
    more,
    ready: *Call,
    /// 알린 크기보다 많다 — 그 호출은 `invalid_request` 로 답하고 버린다.
    overflow: *Call,
    out_of_memory: *Call,
};

pub const Table = struct {
    slots: [capacity]?Call = @splat(null),
    next_id: i32 = id_base,
    /// 답을 기다리는 시한(판정자는 짧게 — `devtools.zig`).
    stale_ms: i64 = message.devtools_stale_ms,
    /// kick 의 시한(둘 가운데 짧은 것을 쓴다).
    kick_stale_ms: i64 = message.devtools_kick_stale_ms,

    pub fn deinit(self: *Table, gpa: std.mem.Allocator) void {
        for (&self.slots) |*s| if (s.*) |*v| v.deinit(gpa);
        self.* = .{};
    }

    pub fn isEmpty(self: *const Table) bool {
        for (self.slots) |s| if (s != null) return false;
        return true;
    }

    pub fn find(self: *Table, browser: BrowserId, call: u32) ?*Call {
        for (&self.slots) |*s| if (s.*) |*v| if (v.browser == browser and v.call == call) return v;
        return null;
    }

    /// 새 호출의 자리를 잡는다. 메서드 이름·크기는 wire 가 검사했다.
    pub fn begin(self: *Table, value: message.DevtoolsCall, now_ms: i64) BeginError!*Call {
        if (forbiddenMethod(value.method)) return error.Forbidden;
        if (std.mem.eql(u8, value.method, target_info_method) and value.params_size > target_params_max) return error.Forbidden;
        if (self.find(value.browser, value.call) != null) return error.Duplicate;
        var of_browser: usize = 0;
        for (self.slots) |s| if (s) |v| if (v.browser == value.browser) {
            of_browser += 1;
        };
        if (of_browser >= message.max_devtools_calls_per_browser) return error.Busy;
        for (&self.slots) |*s| if (s.* == null) {
            s.* = .{ .browser = value.browser, .call = value.call, .method_len = value.method.len, .params_size = value.params_size, .started_ms = now_ms };
            @memcpy(s.*.?.method_buf[0..value.method.len], value.method);
            return &s.*.?;
        };
        return error.Busy;
    }

    pub fn addData(self: *Table, gpa: std.mem.Allocator, value: message.DevtoolsData) AddResult {
        const c = self.find(value.browser, value.call) orelse return .unknown;
        if (c.phase != .collecting) return .{ .overflow = c };
        if (c.params.items.len + value.bytes.len > c.params_size) return .{ .overflow = c };
        c.params.appendSlice(gpa, value.bytes) catch return .{ .out_of_memory = c };
        return if (c.complete()) .{ .ready = c } else .more;
    }

    fn takeId(self: *Table) i32 {
        const id = self.next_id;
        self.next_id = if (self.next_id + 1 >= id_end) id_base else self.next_id + 1;
        return id;
    }

    pub const BuildError = error{ InvalidParams, OutOfMemory };

    /// 보낼 CDP 메시지를 만들고 번호를 매긴다(부른 쪽이 해제). 인자가 JSON 객체 하나가 아니면 `InvalidParams`.
    pub fn buildMessage(self: *Table, gpa: std.mem.Allocator, c: *Call) BuildError![]u8 {
        std.debug.assert(c.complete() and c.phase == .collecting);
        const params = c.params.items;
        if (params.len != 0) {
            const first = std.mem.trimStart(u8, params, " \t\r\n");
            if (first.len == 0 or first[0] != '{') return error.InvalidParams;
            if (!try std.json.validate(gpa, params)) return error.InvalidParams;
            if (!protocol.fields.jsonDepthWithin(params, message.max_devtools_params_depth)) return error.InvalidParams;
        }
        if (!targetParamsAllowed(c.method(), params)) return error.InvalidParams; // 재검증 6 차 F11
        c.kick = std.mem.eql(u8, c.method(), message.devtools_kick_method) and std.mem.eql(u8, params, message.devtools_kick_params);
        const id = self.takeId();
        const json = if (params.len == 0)
            try std.fmt.allocPrint(gpa, "{{\"id\":{d},\"method\":\"{s}\"}}", .{ id, c.method() })
        else
            try std.fmt.allocPrint(gpa, "{{\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}", .{ id, c.method(), params });
        c.cdp_id = id;
        c.phase = .sent;
        c.params.clearAndFree(gpa); // 보냈다 — 결과를 기다리는 동안 쥐지 않는다
        return json;
    }

    /// 그 메시지 번호로 보낸 호출을 꺼낸다(대역 밖이거나 모르면 null — 다른 사용처의 결과).
    pub fn takeByCdpId(self: *Table, cdp_id: i32) ?Call {
        if (cdp_id < id_base or cdp_id >= id_end) return null;
        for (&self.slots) |*s| if (s.*) |v| if (v.phase == .sent and v.cdp_id == cdp_id) {
            s.* = null;
            return v;
        };
        return null;
    }

    pub fn take(self: *Table, c: *Call) Call {
        for (&self.slots) |*s| if (s.*) |*v| if (v == c) {
            const out = v.*;
            s.* = null;
            return out;
        };
        unreachable;
    }

    /// 그 브라우저의 호출 하나를 꺼낸다(DevTools 가 떨어졌다·브라우저가 닫혔다 — 부른 쪽이 null 까지 되풀이해 `detached` 로 답한다).
    pub fn takeForBrowser(self: *Table, browser: BrowserId) ?Call {
        for (&self.slots) |*s| if (s.*) |v| if (v.browser == browser) {
            s.* = null;
            return v;
        };
        return null;
    }

    /// 시한이 지난 호출 하나를 꺼낸다(null 까지 되풀이해 `expired` 로 답한다). kick 은 짧은 시한으로.
    pub fn takeStale(self: *Table, now_ms: i64) ?Call {
        for (&self.slots) |*s| if (s.*) |v| if (now_ms - v.started_ms >= self.staleOf(&v)) {
            s.* = null;
            return v;
        };
        return null;
    }

    fn staleOf(self: *const Table, c: *const Call) i64 {
        return if (c.kick) @min(self.stale_ms, self.kick_stale_ms) else self.stale_ms;
    }
};

const testing = std.testing;

fn callOf(browser: BrowserId, call: u32, method: []const u8, params_size: u32) message.DevtoolsCall {
    return .{ .browser = browser, .call = call, .method = method, .params_size = params_size };
}

test "인자 조각을 모아 CDP 메시지를 만들고, 대역 안의 번호로만 답을 찾는다" {
    var t: Table = .{};
    defer t.deinit(testing.allocator);
    const params = "{\"expression\":\"1+1\",\"returnByValue\":true}";
    const c = try t.begin(callOf(3, 7, "Runtime.evaluate", params.len), 0);
    try testing.expect(!c.complete());
    try testing.expectEqual(AddResult.more, t.addData(testing.allocator, .{ .browser = 3, .call = 7, .bytes = params[0..10] }));
    const ready = t.addData(testing.allocator, .{ .browser = 3, .call = 7, .bytes = params[10..] });
    try testing.expect(ready == .ready and ready.ready == c);
    const json = try t.buildMessage(testing.allocator, c);
    defer testing.allocator.free(json);
    try testing.expectEqualStrings("{\"id\":536870912,\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"1+1\",\"returnByValue\":true}}", json);
    try testing.expectEqual(@as(usize, 0), c.params.capacity); // 보낸 뒤 인자를 쥐지 않는다
    // 다른 사용처의 번호(미디어 메뉴 1<<30 · 권한 0)는 모른다.
    try testing.expect(t.takeByCdpId(1 << 30) == null);
    try testing.expect(t.takeByCdpId(0) == null);
    var got = t.takeByCdpId(id_base).?;
    defer got.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 7), got.call);
    try testing.expect(t.find(3, 7) == null);
}

test "인자 없는 호출은 params 없이, 번호는 대역 안에서 돈다" {
    var t: Table = .{ .next_id = id_end - 1 };
    defer t.deinit(testing.allocator);
    const c = try t.begin(callOf(3, 1, "Page.enable", 0), 0);
    try testing.expect(c.complete());
    const json = try t.buildMessage(testing.allocator, c);
    defer testing.allocator.free(json);
    try testing.expectEqualStrings("{\"id\":1073741823,\"method\":\"Page.enable\"}", json);
    try testing.expectEqual(id_base, t.next_id);
}

test "인자는 JSON 객체 하나여야 한다 — 이어 붙여 메시지 모양을 바꾸지 못한다" {
    var t: Table = .{};
    defer t.deinit(testing.allocator);
    for ([_][]const u8{ "1},\"id\":7", "[1]", "\"s\"", "{\"a\":1}x", "{\"a\":1},{\"b\":2}", "{", " ", "{\"a\":1}}" }) |bad| {
        const c = try t.begin(callOf(3, 9, "A.b", @intCast(bad.len)), 0);
        _ = t.addData(testing.allocator, .{ .browser = 3, .call = 9, .bytes = bad });
        try testing.expectError(error.InvalidParams, t.buildMessage(testing.allocator, c));
        var gone = t.take(c);
        gone.deinit(testing.allocator);
    }
    const c = try t.begin(callOf(3, 9, "A.b", 9), 0);
    _ = t.addData(testing.allocator, .{ .browser = 3, .call = 9, .bytes = " {\"a\":1}" ++ "\n" });
    const json = try t.buildMessage(testing.allocator, c);
    testing.allocator.free(json);
}

test "알린 크기를 넘는 조각·보낸 뒤의 조각은 넘침, 모르는 호출은 버림" {
    var t: Table = .{};
    defer t.deinit(testing.allocator);
    const c = try t.begin(callOf(3, 2, "A.b", 4), 0);
    try testing.expect(t.addData(testing.allocator, .{ .browser = 3, .call = 2, .bytes = "{\"a\":1}" }) == .overflow);
    try testing.expect(t.addData(testing.allocator, .{ .browser = 4, .call = 2, .bytes = "{}" }) == .unknown);
    var gone = t.take(c);
    gone.deinit(testing.allocator);
    const d = try t.begin(callOf(3, 2, "A.b", 2), 0);
    _ = t.addData(testing.allocator, .{ .browser = 3, .call = 2, .bytes = "{}" });
    testing.allocator.free(try t.buildMessage(testing.allocator, d));
    try testing.expect(t.addData(testing.allocator, .{ .browser = 3, .call = 2, .bytes = "{}" }) == .overflow);
}

test "kick(메서드와 인자가 꼭 같은 것)만 짧은 시한으로 꺼낸다 — 인자가 한 바이트라도 다르면 보통 시한" {
    var t: Table = .{};
    defer t.deinit(testing.allocator);
    const kp = message.devtools_kick_params;
    const not_kick = "{\"format\":\"jpeg\",\"quality\":1,\"clip\":{\"x\":0,\"y\":0,\"width\":2,\"height\":1,\"scale\":1}}";
    const cases = [_]struct { browser: BrowserId, method: []const u8, params: []const u8 }{
        .{ .browser = 3, .method = message.devtools_kick_method, .params = kp },
        .{ .browser = 3, .method = "Runtime.evaluate", .params = kp },
        .{ .browser = 4, .method = message.devtools_kick_method, .params = not_kick },
    };
    for (cases, 0..) |k, i| {
        const c = try t.begin(callOf(k.browser, @intCast(i + 1), k.method, @intCast(k.params.len)), 0);
        _ = t.addData(testing.allocator, .{ .browser = k.browser, .call = @intCast(i + 1), .bytes = k.params });
        testing.allocator.free(try t.buildMessage(testing.allocator, c));
    }
    try testing.expect(t.takeStale(message.devtools_kick_stale_ms - 1) == null);
    try testing.expectEqual(@as(u32, 1), t.takeStale(message.devtools_kick_stale_ms).?.call);
    try testing.expect(t.takeStale(message.devtools_kick_stale_ms) == null); // 나머지는 kick 이 아니다
    try testing.expectEqual(@as(u32, 2), t.takeStale(t.stale_ms).?.call);
    try testing.expectEqual(@as(u32, 3), t.takeStale(t.stale_ms).?.call);
    // 판정자가 시한을 kick 보다 짧게 줄이면 그것을 쓴다.
    t.stale_ms = 1_000;
    const c = try t.begin(callOf(3, 9, message.devtools_kick_method, kp.len), 0);
    _ = t.addData(testing.allocator, .{ .browser = 3, .call = 9, .bytes = kp });
    testing.allocator.free(try t.buildMessage(testing.allocator, c));
    try testing.expectEqual(@as(u32, 9), t.takeStale(1_000).?.call);
}

test "자리는 상한까지, 같은 번호는 거절, 브라우저·시한으로 꺼낸다" {
    var t: Table = .{};
    defer t.deinit(testing.allocator);
    // 탭마다 상한까지 — 전체가 찬다.
    for (0..capacity) |i| _ = try t.begin(callOf(@intCast(3 + i / message.max_devtools_calls_per_browser), @intCast(i + 1), "A.b", 0), @intCast(i * 1000));
    try testing.expectError(error.Busy, t.begin(callOf(99, 99, "A.b", 0), 0));
    try testing.expectError(error.Duplicate, t.begin(callOf(3, 1, "A.b", 0), 0));
    // 시한 — 처음 것(0 ms)만 지났다.
    try testing.expectEqual(@as(u32, 1), t.takeStale(t.stale_ms).?.call);
    try testing.expect(t.takeStale(t.stale_ms) == null);
    // 브라우저 4 의 것만 꺼낸다.
    var n: usize = 0;
    while (t.takeForBrowser(4)) |v| : (n += 1) try testing.expectEqual(@as(BrowserId, 4), v.browser);
    try testing.expectEqual(message.max_devtools_calls_per_browser, n);
    _ = try t.begin(callOf(4, 99, "A.b", 0), 0);
}

test "탭마다 상한 — 멈춘 탭 하나가 다른 탭의 자리를 막지 못한다" {
    var t: Table = .{};
    defer t.deinit(testing.allocator);
    for (0..message.max_devtools_calls_per_browser) |i| _ = try t.begin(callOf(3, @intCast(i + 1), "A.b", 0), 0);
    try testing.expectError(error.Busy, t.begin(callOf(3, 50, "A.b", 0), 0));
    _ = try t.begin(callOf(4, 50, "A.b", 0), 0);
}

test "인자 중첩이 깊으면 보내지 않는다(CDP 가 번호 없이 오류를 내 답이 오지 않는다)" {
    var t: Table = .{};
    defer t.deinit(testing.allocator);
    const deep = "{\"a\":" ++ array_repeat.repeat("[", 65) ++ array_repeat.repeat("]", 65) ++ "}";
    const c = try t.begin(callOf(3, 1, "A.b", deep.len), 0);
    _ = t.addData(testing.allocator, .{ .browser = 3, .call = 1, .bytes = deep });
    try testing.expectError(error.InvalidParams, t.buildMessage(testing.allocator, c));
}

test "W9d②: Network.enable·Network.disable·Fetch.* 는 보내지 않는다(본문 기록의 상한을 바꾸거나 기록을 끈다) — 다른 Network 메서드는 받는다" {
    var t: Table = .{};
    defer t.deinit(std.testing.allocator);
    for ([_][]const u8{ "Network.enable", "Network.disable", "Fetch.enable", "Fetch.continueRequest" }) |m| {
        try std.testing.expectError(error.Forbidden, t.begin(.{ .browser = 1, .call = 1, .method = m, .params_size = 0 }, 0));
    }
    _ = try t.begin(.{ .browser = 1, .call = 2, .method = "Network.getCookies", .params_size = 0 }, 0);
    try std.testing.expect(!forbiddenMethod("Network.enableX"));
    // W9d③ 20 회 검증 B DEF-4: 주소 패턴의 offline 흉내(규칙 없는 막기)와 그 짝들. 남긴 것은 막기를 피하지도 흉내 내지도 않는다.
    for ([_][]const u8{ "Network.emulateNetworkConditionsByRule", "Network.continueInterceptedRequest", "Network.loadNetworkResource", "Network.setBlockedURLs", "Network.setBypassServiceWorker" }) |m| try std.testing.expect(forbiddenMethod(m));
    for ([_][]const u8{ "Network.overrideNetworkState", "Network.setCacheDisabled", "Network.setExtraHTTPHeaders", "Network.replayXHR", "Network.getCookies" }) |m| try std.testing.expect(!forbiddenMethod(m));
    try std.testing.expect(!forbiddenMethod("NetworkX.enable"));
    // W9d③ 2 차 검증 NEW-1: Target 은 maru 가 쓰는 읽기 하나만 — 둘째 세션·메시지 옮기기·페이지 JS 의 CDP 는 막는다.
    for ([_][]const u8{ "Target.attachToTarget", "Target.attachToBrowserTarget", "Target.sendMessageToTarget", "Target.setAutoAttach", "Target.autoAttachRelated", "Target.exposeDevToolsProtocol", "Target.createTarget", "Target.createBrowserContext", "Target.getTargets" }) |m| try std.testing.expect(forbiddenMethod(m));
    try std.testing.expect(!forbiddenMethod("Target.getTargetInfo"));
    try std.testing.expect(!forbiddenMethod("TargetX.attachToTarget"));
    // 2 차 검증 LOW-A2-3: 이동을 시작할 수 있는 호출은 사용자 토큰을 거둔다 — 읽기는 아니다.
    for ([_][]const u8{ "Page.reload", "Page.navigateToHistoryEntry", "Page.navigate", "Input.dispatchMouseEvent", "Input.dispatchKeyEvent", "Input.insertText", "Runtime.evaluate", "Runtime.callFunctionOn" }) |m| try std.testing.expect(startsNavigation(m));
    for ([_][]const u8{ "Page.getNavigationHistory", "Page.captureScreenshot", "DOM.getDocument", "Accessibility.getFullAXTree", "Target.getTargetInfo" }) |m| try std.testing.expect(!startsNavigation(m));
    // 3 차 검증 N-A3-3: 에이전트의 fill·type·press·upload 가 보내는 DOM 호출(처리기를 부른다)과 DOM 을 바꾸는 호출, 스크립트·창 흉내도 거둔다 — maru 가
    // 보내는 읽기(DOM·Accessibility·Page 의 get·찍기·세계 만들기, Runtime 의 놓기·멈춤)는 아니다.
    for ([_][]const u8{ "DOM.focus", "DOM.scrollIntoViewIfNeeded", "DOM.setFileInputFiles", "DOM.setOuterHTML", "DOM.setAttributeValue", "DOM.removeNode", "DOM.moveTo", "Page.setDocumentContent", "Runtime.runScript", "Debugger.resume", "Emulation.setDeviceMetricsOverride" }) |m| try std.testing.expect(startsNavigation(m));
    for ([_][]const u8{ "DOM.resolveNode", "DOM.describeNode", "DOM.querySelector", "DOM.getContentQuads", "Accessibility.queryAXTree", "Page.getFrameTree", "Page.getLayoutMetrics", "Runtime.releaseObjectGroup", "Runtime.terminateExecution" }) |m| try std.testing.expect(!startsNavigation(m));
    // 4 차 검증 A-LOW: 읽기 허용 목록 밖은 모두 거둔다 — 모르는 이름(`Page.reloadX`), 읽기가 아닌 세계 만들기·저장소 지우기(쿠키 change 처리기)도.
    for ([_][]const u8{ "Page.reloadX", "Page.createIsolatedWorld", "Storage.clearDataForOrigin" }) |m| try std.testing.expect(startsNavigation(m));
    // 5 차 검증 LOW: 인자도 본다 — 화면 밖까지 찍기(보기 크기를 바꿔 resize 처리기를 돌린다)와 읽지 못하는 인자는 거두고, kick 꼴·clip·빈 인자는 남긴다.
    const gpa = std.testing.allocator;
    for ([_][]const u8{
        "{\"captureBeyondViewport\":true}",
        "{\"captureBeyondViewport\":true,\"clip\":{\"x\":0,\"y\":2900,\"width\":800,\"height\":200,\"scale\":1}}",
        "{\"format\":\"png\",\"captureBeyondViewport\":true}",
        "{\"captureBeyond\\u0056iewport\":true}", // 이스케이프한 열쇠도 같은 열쇠다
        "{\"captureBeyondViewport\":false,\"captureBeyondViewport\":true}", // 같은 열쇠 둘 — 읽지 못한다
        "{\"captureBeyondViewport\":1}",
        "not json",
    }) |p| {
        if (!startsNavigationCall(gpa, "Page.captureScreenshot", p)) std.debug.print("남긴 인자: {s}\n", .{p});
        try std.testing.expect(startsNavigationCall(gpa, "Page.captureScreenshot", p));
    }
    for ([_][]const u8{
        "",
        "{}",
        message.devtools_kick_params,
        "{\"captureBeyondViewport\":false}",
        "{\"captureBeyondViewport\":null}",
        "{\"clip\":{\"x\":0,\"y\":2900,\"width\":800,\"height\":200,\"scale\":1}}",
        "{\"clip\":{\"x\":0,\"y\":0,\"width\":100,\"height\":100,\"scale\":2},\"fromSurface\":false}",
    }) |p| try std.testing.expect(!startsNavigationCall(gpa, "Page.captureScreenshot", p));
    // 이름이 거두는 호출은 인자와 무관하게, 읽기의 다른 메서드는 인자와 무관하게 남긴다(인자로 스크립트를 돌리지 않는다).
    try std.testing.expect(startsNavigationCall(gpa, "Page.reload", ""));
    try std.testing.expect(!startsNavigationCall(gpa, "DOM.describeNode", "{\"nodeId\":1,\"depth\":-1,\"pierce\":true}"));
    // 6 차 검증 LOW: getProperties 는 읽기 목록 밖이다(Error 값의 설명이 페이지의 `Error.prepareStackTrace` 를 부른다) — 인자와 무관하게 거둔다.
    try std.testing.expect(startsNavigationCall(gpa, "Runtime.getProperties", "{\"objectId\":\"1\",\"ownProperties\":false,\"accessorPropertiesOnly\":true,\"generatePreview\":true}"));
    try std.testing.expect(!startsNavigationCall(gpa, "DOM.getDocument", "{\"depth\":-1,\"pierce\":true,\"captureBeyondViewport\":true}"));
    // 7 차 검증 LOW-1: 건너뛴 하위 트리의 스타일·배치를 강제하는 둘은 읽기 목록 밖이다 — 인자와 무관하게 거둔다. 같은 노드의 getContentQuads 는 남긴다.
    for ([_][]const u8{ "DOM.getBoxModel", "CSS.getComputedStyleForNode" }) |m| {
        try std.testing.expect(startsNavigationCall(gpa, m, "{\"nodeId\":15}"));
        try std.testing.expect(startsNavigationCall(gpa, m, ""));
    }
    try std.testing.expect(!startsNavigationCall(gpa, "DOM.getContentQuads", "{\"nodeId\":15}"));
    // 3 차 검증 N-B3-f: 탭의 DevTools 를 멈추게 한 브라우저 명령.
    try std.testing.expect(forbiddenMethod("Browser.executeBrowserCommand"));
    try std.testing.expect(!forbiddenMethod("Browser.getVersion"));
}

test "W9d② 재검증 5 차 S1·6 차 F11: Target.* 는 보내지 않는다(서비스 워커 세션을 떼거나 멈추게 하고 다른 탭을 본다) — maru 가 쓰는 인자 없는 getTargetInfo 하나만 받는다" {
    for ([_][]const u8{ "Target.setAutoAttach", "Target.autoAttachRelated", "Target.attachToTarget", "Target.attachToBrowserTarget", "Target.detachFromTarget", "Target.sendMessageToTarget", "Target.setDiscoverTargets", "Target.exposeDevToolsProtocol", "Target.createTarget", "Target.closeTarget", "Target.createBrowserContext", "Target.disposeBrowserContext", "Target.setRemoteLocations", "Target.somethingNew", "Target.getTargets", "Target.activateTarget", "Target.getTargetInfoX", "Target.getBrowserContexts" }) |m| {
        try std.testing.expect(forbiddenMethod(m));
    }
    for ([_][]const u8{ "Target.getTargetInfo", "TargetX.setAutoAttach", "Page.crash" }) |m| try std.testing.expect(!forbiddenMethod(m));
    // 인자: 없음·빈 객체만(maru 의 `web_cdp_storage` 는 `{}`).
    for ([_][]const u8{ "", "{}", " { } ", "{\n}" }) |p| try std.testing.expect(targetParamsAllowed("Target.getTargetInfo", p));
    for ([_][]const u8{ "{\"targetId\":\"A\"}", "{\"targetId\":\"\"}", "{\"x\":1}", "[]", "null" }) |p| try std.testing.expect(!targetParamsAllowed("Target.getTargetInfo", p));
    try std.testing.expect(targetParamsAllowed("Page.navigate", "{\"url\":\"x\"}"));
    // 실제 길: targetId 를 준 호출은 보내지 않고(`InvalidParams` — invalid_request), 큰 인자는 자리도 잡지 않는다, 빈 객체는 보낸다.
    var t: Table = .{};
    defer t.deinit(std.testing.allocator);
    const leak = "{\"targetId\":\"ABCDEF\"}";
    const c = try t.begin(.{ .browser = 1, .call = 1, .method = "Target.getTargetInfo", .params_size = leak.len }, 0);
    _ = t.addData(std.testing.allocator, .{ .browser = 1, .call = 1, .bytes = leak });
    try std.testing.expectError(error.InvalidParams, t.buildMessage(std.testing.allocator, c));
    try std.testing.expectError(error.Forbidden, t.begin(.{ .browser = 1, .call = 2, .method = "Target.getTargetInfo", .params_size = 4096 }, 0));
    const ok = try t.begin(.{ .browser = 1, .call = 3, .method = "Target.getTargetInfo", .params_size = 2 }, 0);
    _ = t.addData(std.testing.allocator, .{ .browser = 1, .call = 3, .bytes = "{}" });
    const json = try t.buildMessage(std.testing.allocator, ok);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"method\":\"Target.getTargetInfo\",\"params\":{}") != null);
}
