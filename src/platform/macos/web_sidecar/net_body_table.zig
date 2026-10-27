//! 응답 본문 기록의 표(W9d② — docs/plans/web-osr-backend.md 「W9d② 결정」). CEF 를 모른다 — 시각·번호·CDP 이벤트의 값은 호출자
//! (`net_body.zig`)가 준다. 잠금도 없다 — UI 스레드 하나만 쓴다(CEF 의 DevTools 관찰자 콜백과 `network.zig` 의 보내는 task 가 둘 다 UI 스레드).
//!
//! 왜 맞추기가 필요한가: 본문은 CDP(`Network.getResponseBody`)로만 받는데, maru 의 네트워크 기록은 CEF 자원 요청 처리기의 요청 번호로 적는다.
//! 둘 사이에 번호의 관계가 없다(W9d②-0 J1 실측 — CDP 는 `<렌더러 pid>.<번호>`, CEF 는 프로세스 전체의 번호). 그래서 같은 요청을
//! (조각을 뗀 온 주소, 메서드, 서비스 워커 갈래)의 열쇠와 시각·차례로 맞춘다(J1·J2 — 실제 사이트 14 곳 두 번에서 짝지은 요청의 상태가 100 %
//! 같았다):
//!   - 후보: 같은 열쇠의 아직 짝이 없는 CEF 시작 중 IO 시각이 CDP 시작 `[ts − 5 ms, ts + 2 s]` 안.
//!   - 차례: 같은 열쇠의 CDP 요청(시작 차례)과 후보(IO 시각 차례)를 차례를 지켜 맞춘다 — 요청마다 앞 요청의 짝 뒤의 첫 후보(같은 주소의 동시
//!     요청 2250/2250 이 시작 차례 그대로였다). 기록이 아직 오지 않은 요청은 건너뛴다(W9d② 적대 리뷰 2 회차 — 전에는 먼저 시작해 열린 요청
//!     수만큼 창 안의 후보를 건너뛰어, 그 요청의 기록이 창 밖이어도 셌다).
//!   - CDP 의 `loadingFinished` 가 CEF 의 시작보다 먼저 올 수 있다(10 ms 묶음 — 빠른 로컬 요청은 450/450) — 그때는 잠시(`cef_grace_us`) 기다린다.
//!   - 모호함: 창 안의 다른 후보가 보이는 규칙(프레임·첫 사이트·initiator)이 다르거나, 그 탭이 같은 주소의 요청을 문에서 넘긴 창 안이면
//!     짝을 지어도 본문을 붙이지 않는다(`ambiguous` — 넘긴 요청의 쌍둥이 자리에 다른 요청이 들어온다, J2: 넘김 창 안에서 4–6 개가 틀렸다).
//! 본문 상태(`NetBodyState`)는 CEF 시작마다 **꼭 하나**다(`body_expected` 로 알린 요청 — 짝이 없으면 `unmatched`, 기록을 끄면
//! `recording_stopped`, 렌더러가 죽으면 `detached`, 같은 번호로 다시 시작하면 앞 시도는 `restarted` — 그 끝은 새 시작보다 먼저).
//! 상한: 풀어 낸 크기(`dataReceived` 의 합 — J4: 이것이 실제 크기와 꼭 같았다)가 1 MiB 를 넘으면 받지 않는다(CDP 의 자원 상한은 스크립트·스타일에 듣지 않았다 — 11 MB 가 왔다), 동시 2/탭·8 전체, 초당 20 개(버스트 60 — 4 회차)·4 MiB/탭·8 MiB 전체.
//! 다음 문서로 옮기면 본문이 사라지므로(J4) 기다리는 것은 잠시뿐이고(`waiting_expiry_us`) 넘으면 `busy` 다.
//! W9d② 적대 리뷰 1 회차: (MED-1) 설정이 꺼졌으면 응답을 보낸 호스트(리다이렉트 뒤)를 CEF 응답이 정하기 전에는 받으러 가지 않는다 — CDP 끝은 그
//! CEF 응답보다 대개 먼저 온다(`cover_pending`·`cover_grace_us`, 시한·응답 없는 끝은 `not_covered`). (MED-2) 창 안의 같은 열쇠 후보가 그것을 가져갈
//! 같은 열쇠의 CDP 요청보다 많으면(CDP 가 보지 못한 워커의 fetch) 짝일 수 있는 후보를 모두 `ambiguous` 로 끝낸다. (LOW-3) ExtraInfo 는 보낸 홉마다
//! 세고 덜 왔으면 실린 것으로 친다(잠시 기다린다 — `extra_grace_us`), ExtraInfo 만 온 자리는 시한·수로 놓는다.
//! W9d② 적대 리뷰 2 회차: 차례는 앞에서부터·뒤에서부터 두 번 맞춰 본다 — 둘이 이 요청에 다른 후보를 주면 CDP 가 보지 못한 같은 열쇠의 기록이
//! 섞였다(MED-2 를 바꿨다 — 후보 수와 가져갈 요청 수를 견주던 것은 창 밖의 열린 요청을 셌다): 두 후보 사이를 모두 `ambiguous` 로 끝내고 두 맞추기가
//! 갈린 다른 요청도 `ambiguous`(`Cdp.tainted`). 다시 시작은 바로 앞 홉과 같은 주소를 다시 보낸 것뿐이고(A → B → A 는 리다이렉트), 다시 시작한 CDP
//! 요청은 다시 시작한 CEF 시도와만 짓는다.
//! W9d② 적대 리뷰 3 회차: (P1) CDP 끝이 제 CEF 기록보다 먼저 오면 먼저 온 워커의 같은 주소 기록만 보고 정해 페이지의 본문이 워커의 기록에 붙었다 —
//! 이제 물 높이(`cef_seen_us` — CEF 기록이 이 IO 시각까지 다 왔다)가 그 요청의 응답 때(`Cdp.bound` — 제 기록은 그보다 앞에 시작했다)에 닿은 뒤에만
//! 정하고, 응답 뒤에 시작한 기록은 그 요청의 짝으로 치지 않는다(`compatible`). (P5) 응답 없이 실패한 요청(abort — CEF 에 닿지 않았을 수 있다)은
//! 끝난 뒤에 시작한 기록을 CEF 가 성공으로 끝내면 갖지 않고, 「그럴 수 있다」 뿐이면 제 짝으로 정하지 않는다(`definite`); 성공한 요청은 CEF 가
//! 실패·취소로 끝낸 기록을 갖지 않는다. (S1) 답이 오지 않는 본문 호출은 `fetch_timeout_us` 뒤 `unavailable`.
//! W9d② 적대 리뷰 4 회차: (SW1) 서비스 워커가 준 응답은 그 출처(`serviceWorkerResponseSource`)가 `network` 일 때만 서비스 워커 갈래의 기록과
//! 맞춘다 — Cache Storage·HTTP 캐시·워커가 만든 응답·출처 없음은 CEF 가 보지 못한 응답으로 친다(`Cdp.sw_off_network` — 캐시로 답하며 같은 주소를
//! 다시 받는 워커의 기록에 캐시의 옛 본문이 붙었다). (N1) CDP 의 빈 본문인데 CEF 끝이 바이트를 알렸으면 `unavailable`(`emptyBodyState`).
//! 본문 수의 버스트는 60(`tab_bodies_burst` — 초당 20 은 그대로).
//! W9d② 적대 리뷰 5 회차: (A1) 응답 없이 실패한 요청은 CEF 가 실패·취소로 끝낸 기록만 제 것으로 정한다 — 끝이 아직이면 기다리고(시한까지),
//! CEF 가 성공으로 끝낸 기록은 IO 시각과 무관하게 갖지 않는다. 실패 시각은 CDP `loadingFailed.timestamp`(`Cdp.failed_at` — 응답 시각과 같은
//! 검사), 그런 요청이 결과를 모르는 기록을 쥔 동안 뒤 요청은 정하지 않는다. (A2) 기다림은 탭 128·전체 512 이고 차례가 있다 — 스크립트·스타일·
//! 문서·이미지·글꼴·미디어(`lowPriority`)는 fetch·XHR 등 뒤로, 넘치면 뒤 차례의 가장 새것이 `busy`. (C1) 넘김 상자가 넘쳐 버린 시작 아닌 기록
//! (리다이렉트·응답·끝)은 그 요청의 후보에 표지(`Candidate.lost` — `cefLost`·`cefLostAll`)를 남겨 끝이 꼭 온다(짝이면 `ambiguous`, 아니면 시한 뒤
//! `unmatched`).
//! W9d② 20 회 검증(2026-10-21): (N1) 주 프레임이 새 문서로 옮기면(`documentStarted`) 그 앞에 시작한 요청은 CDP 끝이 오지 않는다(실측 0/34) — CEF 가
//! 취소·실패로 끝냈으면 `cef_grace_us` 뒤, 성공으로 끝냈으면 짝 없는 시한 뒤 `unavailable`(전에는 `unmatched` — 「다른 프로세스·worker」 로 보였다). (D3) 끝이 영영 오지 않을
//! 열린 CDP 요청(창이 지났고 짝일 수 있는 후보가 없다 — `cdpWindowPassed`·`cdpMayPair`)은 놓는다: 전에는 남아 `busy` 가 늘 참이라 50 ms 주기 task 가 멈추지 않았고
//! 4096 개까지 쌓였다. 자리가 차면 오래된 것을 묶음(`cdp_evict_batch`)으로 놓는다(하나씩이면 요청마다 목록을 밀었다).
//! W9d② 최종 재검증: (D-A) N1 이 앞 문서의 기록을 끝낼 때 왼쪽 맞추기가 그 기록에 맞춘 열린 CDP 요청도 함께 놓는다(`retireOwner` — 기록만 지우면 그
//! 요청이 다시 불러온 문서의 같은 주소 기록을 가져갔다). (D-B) 자리 상한의 묶음 놓기가 놓은 요청의 창 끝까지는 본문을 붙이지 않는다(`Tab.cdp_drop_until`).
//! (N-a) 끊긴 CDP 자리 훑기는 짝 없는 후보의 색인으로(`buildCandIndex`·`cdpMayPair` — 요청 × 후보였다).
//! W9d② 재검증 2–9 회차(WB): 판정 밖에서 짝 없는 기록을 끝내거나 지우는 모든 길(N1 끊김·짝 없는 시한·모호한 판정의 짝과 MED-2 사이 후보·A1
//! 시한 끝·후보 상한)은 그 기록의 **주인일 수 있는** CDP 요청(`mayOwn`)을 모두 함께 맞추기에서 뺀다(`expireRecords`) — 기록만 지우면 주인이
//! 차례에 남아 남의 기록을 가져갔다(두 맞추기가 함께 밀려 갈림으로 보이지 않는다). 끊긴 기록에 열린 주인 후보가 둘 이상이면 시한까지 지우지
//! 않는다. 응답 없이 실패한 요청이 쥔 기록에 기대는 판정은 그 요청이 정해질 때까지 기다리고(`held`), 그 기록의 실패 끝이 새
//! 문서 시작 뒤에 왔으면 그 abort 의 것으로 정하지 않는다(`definite`). 앞 문서의 열린 요청이 새 문서의 기록을 쥐면 그 뒤 요청은 본문을 붙이지
//! 않는다(`crossesDoc` — WB-3). CDP 자리 상한의 표지는 주소마다(`Tab.cdp_drop_marks`).
//!
//! 시험이 증명하는 것: 맞추기(두 도착 차례·창·같은 주소의 차례 — 창이 다른 동시 요청·기록이 아직인 뒤 요청·ExtraInfo 가 먼저 온 요청·문 넘김과
//! 보이는 규칙이 다른 후보의 모호함·CDP 가 보지 못한 같은 주소 후보의 모호함과 갈린 다른 요청·서비스 워커 갈래·조각 떼기·A → B → A 와 다시
//! 시작), 설정 끔의 응답 호스트 기다림, 홉마다의 ExtraInfo 와 그 자리의 시한, 상한과 판정(넘침·글 아님·빈 본문·끊김·실패), 동시·초당 상한과
//! 기다림의 만료, 세대(끈 뒤 늦게 온 결과는 버린다), 시작마다 끝은 꼭 하나, MIME 가르기, 결과 풀기(JSON 글·base64·잘못된 UTF-8·windows-1252
//! 되돌리기), 물 높이(제 기록이 늦은 빠른 요청·응답 뒤 워커의 기록·응답의 CDP 시각·시한), abort 한 요청과 다시 받은 요청(CEF 에 닿았든 아니든·
//! CEF 끝이 늦어도), 답이 오지 않는 본문 호출의 시한, 서비스 워커 응답의 출처(Cache Storage·만든 응답·HTTP 캐시·출처 없음은 워커 기록에 붙이지
//! 않고 그대로 넘긴 것만 — 섞이면 `ambiguous`), 넘김 상자가 넘쳐 놓친 시작의 표지, CEF 가 받은 바이트로 가르는 빈 본문, (5 회차) CDP 실패 시각과
//! CEF 의 결과로만 정하는 abort 한 요청(느린 다시 받기·늦은 취소 끝·세 요청의 차례·물 높이), 기다림의 차례·내주기·전체 상한·줄 전체의 시한,
//! 넘김 상자가 버린 끝의 표지, (20 회 검증) 새 문서와 함께 끊긴 요청의 `unavailable`·끝이 오지 않을 열린 CDP 요청을 놓아 한가해지는 표·자리가 찼을 때의
//! 묶음 놓기.

const std = @import("std");
const protocol = @import("web_sidecar_protocol");

const msg = protocol.message;
const BrowserId = msg.BrowserId;
const State = msg.NetBodyState;
const Flags = msg.NetBodyFlags;

pub const max_tabs = @import("registry.zig").capacity;
/// CDP 시작보다 CEF 시작이 이만큼 앞이어도 후보다(J1: CDP 가 늘 0.09–6.3 ms 먼저였다 — 거꾸로 온 것도 받는다).
pub const window_before_us: i64 = 5_000;
/// CDP 시작 뒤 이만큼까지의 CEF 시작이 후보다(J1·실제 사이트: 짝의 최대 간격 1.66 s).
pub const window_after_us: i64 = 2_000_000;
/// CDP 끝 뒤 CEF 시작을 기다리는 시간(CEF 기록은 10 ms 묶음으로 오고 p50 7 ms 늦다 — 넉넉히).
pub const cef_grace_us: i64 = 250_000;
/// 짝이 없는 CEF 요청이 끝난 뒤 `unmatched` 로 정하기까지(그 뒤의 CDP 끝이 아직 짝을 찾을 수 있게).
pub const unclaimed_expiry_us: i64 = 3_000_000;
/// 재검증 2–9 회차 WB: 성공으로 끝난 요청의 CEF 끝이 늦어도 이만큼 안에는 왔다(`Table.mayOwn` — CEF 의 끝은 렌더러의 `loadingFinished` 보다 먼저다).
pub const end_slack_us: i64 = 20_000;
/// 재검증 3 차 WB-4: 「막」 의 폭 — CEF 가 막 실패로 끝낸 기록(`markPending` — 그 주인이 곧 실패를 알린다), 막 시작한 기록(`ensureYoung` — 그
/// CDP 요청이 아직 알려지지 않았을 수 있다), 그 둘이 만든 갈림의 기다림(`cef_grace_us` 더하기). 재검증 3 차 뒤 WB-5: 전에는 응답 전의 열린
/// 요청의 기록도 기준 시각 뒤 이만큼 안에 시작했다고 봤다(J1 의 0.09–6.3 ms) — 서비스 워커는 페이지 요청을 얼마든지 늦게 넘기거나 캐시로 늦게
/// 답한다(검증 v20i-swlag·swsyn 100·300 ms 에서 틀린 본문 8·7·5·6/20). 이제 그 요청은 응답(또는 창 끝)까지 기록이 올 수 있는 것으로 친다
/// (`Table.recordDue`).
pub const record_lag_us: i64 = 60_000;
/// 재검증 3 차 뒤 WB-5: 같은 열쇠의 다른 요청(응답 전)의 기록이 정해지기를 판정이 기다리는 시한(끝을 본 때부터) — 넘기면 본문 없이. 응답 전의
/// 요청은 창 끝(`window_after_us`)까지 기록이 올 수 있어 그만큼이다.
pub const split_wait_us: i64 = 2_000_000;
/// 재검증 3 차 뒤: 끝난 짝 없는 기록을 판정을 기다리며 남겨 두는 가장 긴 때(CEF 끝부터) — 판정의 시한(`split_wait_us`)·짝 없는 시한·본문 호출의
/// 시한을 모두 넘는다. 이것이 지나면 미루지 않고 끝낸다.
pub const record_hard_expiry_us: i64 = 10_000_000;
/// 자리가 날 때까지 기다리는 본문의 시한 — 다음 문서로 옮기면 본문이 사라진다(J4).
pub const waiting_expiry_us: i64 = 3_000_000;
/// W9d② 적대 리뷰 3 회차 S1: 보낸 `getResponseBody` 의 답을 기다리는 시한 — 넘기면 그 본문은 `unavailable` 로 끝내고 자리를 놓는다(늦은 답은
/// 버린다). 렌더러 죽음은 `detached` 가 곧 끝내지만(J5) 그 밖에 답이 오지 않는 꼴이 생기면 자리(탭 2·전체 8)를 영영 쥐고 주기 task 가
/// 멈추지 않았다. 1 MiB 본문의 답도 실측에서 ms 단위였다 — 넉넉히(그동안 그 탭의 다른 본문은 자리를 기다리다 `busy` 가 된다).
pub const fetch_timeout_us: i64 = 5_000_000;
/// W9d② 적대 리뷰 1 회차 MED-1: 설정이 꺼졌을 때 CDP 끝 뒤 CEF 응답(응답을 보낸 호스트 — 리다이렉트 뒤)을 기다리는 시간. CEF 기록은 10 ms
/// 묶음으로 오고 CDP 가 p50 7 ms 앞선다(J1) — 넘기면 덮이지 않는 것으로 친다(`not_covered` — 본문이 브라우저 프로세스를 나가지 않는다).
pub const cover_grace_us: i64 = 500_000;
/// W9d② 적대 리뷰 1 회차 LOW-3: 응답이 ExtraInfo 가 온다고 알렸는데(`hasExtraInfo`) 홉마다의 ExtraInfo 가 아직 다 오지 않았으면 CDP 끝 뒤
/// 이만큼 기다린다 — 넘기면 실린 것으로 친다(UB1 은 닫힌 쪽으로).
pub const extra_grace_us: i64 = 200_000;
/// requestWillBeSent 없이 ExtraInfo 만 온 자리(열쇠 없음)의 시한과 수 — 이미 정한 요청의 늦은 ExtraInfo 는 다시 짝이 될 일이 없다. 둘 다 넘치면
/// 오래된 자리부터 놓는다(전에는 기록 내내 남아 주기 task 가 멈추지 않았고, 4096 개가 쌓이면 사건마다 목록을 통째로 밀었다).
pub const placeholder_expiry_us: i64 = 1_000_000;
pub const max_placeholders: usize = 64;
pub const max_inflight_per_tab: usize = 2;
pub const max_inflight: usize = 8;
/// W9d② 적대 리뷰 5 회차 A2: 자리를 기다리는 본문 수 — 탭마다 128(그 탭이 기다림의 시한 3 초 안에 보낼 수 있는 가장 많은 수 = 버스트 60 +
/// 초당 20 × 3 초 = 120 — 더 쥐어도 시한 안에 보내지 못한다), 모든 탭을 합쳐 512(기다림 하나는 `Waiting` 약 220 바이트 — 512 개 ≈ 110 KiB, 시험이
/// 128 KiB 아래임을 본다; 본문은 받기 전까지 Chromium 의 버퍼(탭 8 MiB)에 있다 — 기다림은 표의 줄만 쥔다). 탭 상한이 있어 적대 페이지 하나는 전체의
/// 1/4 만 쥔다. 전에는 탭 32 라 무거운 페이지의 첫 적재(글 응답 백여 개가 한꺼번에 끝난다)에서 넘쳐 페이지 JSON 의 1/3 이 `busy` 였다(판정
/// `rv5-mix` 57–62/90). 넘치면 차례가 뒤인(`lowPriority`) 가장 새 기다림을 내주고, 그것도 없으면 새것이 `busy` 다. 기다림의 시한(다음 문서로
/// 옮기면 본문이 사라진다 — J4)은 그대로 3 초.
pub const max_waiting_per_tab: usize = 128;
pub const max_waiting: usize = 512;
/// 탭마다 쥐는 CEF 후보·CDP 요청 수 상한(넘으면 가장 오래된 것부터 놓는다 — 후보는 `busy` 로 끝낸다).
pub const max_candidates: usize = 4096;
pub const max_cdp: usize = 4096;
/// W9d② 20 회 검증 D3: CDP 자리가 차면 가장 오래된 것을 이만큼 한꺼번에 놓는다 — 하나씩 놓으면 찬 동안 요청마다 4096 자리를 밀었다(O(n)).
/// 열린 채 끝이 오지 않는 요청은 시한으로 따로 놓으므로(`cdpWindowPassed`·`cdpMayPair`) 이 길은 짧은 사이에 4096 개가 열려 있을 때뿐이다.
pub const cdp_evict_batch: usize = max_cdp / 16;
/// 초당 본문 수·바이트(탭), 바이트(전체).
pub const tab_bodies_per_s: f64 = 20;
/// W9d② 적대 리뷰 4 회차(작성자 선택 — 사용자 결정): 본문 수의 버스트는 초당 수의 세 배(3 초 몫). 전에는 버스트가 초당 수와 같아(20) 초당 34 개의
/// JSON 을 5 초 동안 내는 SPA 꼴에서 기다림(32 개·3 초)이 넘쳐 페이지 JSON 의 12 % 가 `busy` 였다(판정 `rv4-spa` 134/152). 꾸준한 초당 수와 바이트
/// 양동이(하나 1 MiB 의 본문이 몰려도 탭 4 MiB/s·전체 8 MiB/s)·동시 2/탭·8 전체·maru 의 저장 상한은 그대로다.
pub const tab_bodies_burst: f64 = 3 * tab_bodies_per_s;
pub const tab_bytes_per_s: f64 = 4 * 1024 * 1024;
pub const global_bytes_per_s: f64 = 8 * 1024 * 1024;
/// 쏟아짐 밸브 — 이벤트가 초당 이만큼을 연달아 이 초만큼 넘으면 기록을 멈춘다(J7: 쏟아질 때 Chromium 의 직렬화가 CPU 를 먹는다).
pub const flood_events_per_s: u32 = 5000;
pub const flood_seconds: u8 = 2;
/// 탭마다 기억하는 문 넘김 표지 수(넘치면 그 창 전체를 모호함으로).
pub const max_drop_marks: usize = 128;
/// 재검증 2–9 회차 N3: CDP 자리 상한의 묶음 놓기가 남기는 주소마다의 표지 수(`Tab.cdp_drop_marks` — 넘치면 탭 전체로 접는다). 재검증 3 차: 묶음
/// 하나(256)였고 지난 표지를 지우지 않아 첫 묶음 뒤 모든 묶음이 탭 전체로 접혔다 — 이제 CDP 자리 수만큼이고 어느 창에도 들 수 없는 표지는 묶음마다
/// 지운다(`Table.dropOldestCdp`).
pub const max_cdp_drop_marks: usize = max_cdp;
/// 재검증 3 차 LB-1: 탭마다 기억하는 문서 loader(CDP `loaderId` 의 해시)와 그 loader 로 보낸 가장 늦은 요청의 기준 시각 수(`Tab.loaders`).
pub const max_loaders: usize = 32;
/// 재검증 3 차 WB-4: 막 시작한 기록이 만든 갈림을 풀어 보려 끝에서부터 빼 보는 기록 수의 상한(`Table.ensureArrays`).
pub const max_young: usize = 8;
/// 재검증 2–9 회차 WB-3: 기억하는 새 문서 시작 수(`Tab.doc_starts`).
pub const max_doc_starts: usize = 16;
/// `getResponseBody` 번호 대역 — 다른 DevTools 사용처와 겹치지 않는다(J13: 권한 0 부터·알림 20000 부터·`devtools_table` [1<<29, 1<<30)·미디어 메뉴
/// [1<<30, 2^31)).
pub const id_base: i32 = 1 << 28;
pub const id_end: i32 = 1 << 29;
pub const max_rid_bytes: usize = 64;

// ── 열쇠 ──────────────────────────────────────────────────────────────────────────────────────────────────

/// 맞추기 열쇠 — 조각(`#…`)을 뗀 온 주소의 해시, 메서드의 해시, 서비스 워커 갈래.
pub const Key = struct {
    url: u64,
    method: u64,
    sw: bool,

    pub fn eql(a: Key, b: Key) bool {
        return a.url == b.url and a.method == b.method and a.sw == b.sw;
    }
};

/// UTF-8 주소의 해시 — `#` 앞까지(CEF 주소는 조각을 싣고 CDP 는 떼었다 — J1).
pub fn hashUrl8(url: []const u8) u64 {
    const end = std.mem.indexOfScalar(u8, url, '#') orelse url.len;
    return std.hash.Wyhash.hash(0x9d2, url[0..end]);
}

/// CEF 의 UTF-16 주소를 UTF-8 로 풀며 같은 해시를 낸다(할당 없음 — IO 스레드에서 부른다). 짝 없는 대리 쌍은 U+FFFD.
pub fn hashUrl16(units: []const u16) u64 {
    var h = std.hash.Wyhash.init(0x9d2);
    var buf: [256]u8 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < units.len) : (i += 1) {
        var cp: u21 = units[i];
        if (cp == '#') break;
        if (cp >= 0xD800 and cp <= 0xDBFF and i + 1 < units.len and units[i + 1] >= 0xDC00 and units[i + 1] <= 0xDFFF) {
            cp = 0x10000 + ((cp - 0xD800) << 10) + (units[i + 1] - 0xDC00);
            i += 1;
        } else if (cp >= 0xD800 and cp <= 0xDFFF) cp = 0xFFFD;
        if (n + 4 > buf.len) {
            h.update(buf[0..n]);
            n = 0;
        }
        n += std.unicode.utf8Encode(cp, buf[n..][0..4]) catch unreachable;
    }
    h.update(buf[0..n]);
    return h.final();
}

pub fn hashMethod(method: []const u8) u64 {
    return std.hash.Wyhash.hash(0x3e7, method);
}

// ── MIME 가르기 ───────────────────────────────────────────────────────────────────────────────────────────

pub const MimeClass = enum {
    /// 글로 받는다.
    text,
    /// 글이 아닌 종류 — 받지 않는다(`not_text`).
    binary,
    /// 모른다(빈 MIME) — 받아 보고 UTF-8 이면 글.
    unknown,
};

/// 응답 MIME(매개변수 없이, 소문자로 비교)의 갈래. 글: `text/*`(이벤트 흐름 제외), JSON·XML 꼴(`+json`·`+xml` 포함), JavaScript, 양식,
/// GraphQL. 빈 MIME 는 모른다.
pub fn mimeClass(mime_full: []const u8) MimeClass {
    const semi = std.mem.indexOfScalar(u8, mime_full, ';') orelse mime_full.len;
    const mime = std.mem.trim(u8, mime_full[0..semi], " \t");
    if (mime.len == 0) return .unknown;
    var lb: [128]u8 = undefined;
    if (mime.len > lb.len) return .binary;
    const m = std.ascii.lowerString(&lb, mime);
    if (std.mem.eql(u8, m, "text/event-stream")) return .binary; // 끝나지 않는 흐름 — 본문이 남지 않는다
    if (std.mem.startsWith(u8, m, "text/")) return .text;
    if (std.mem.endsWith(u8, m, "+json") or std.mem.endsWith(u8, m, "+xml") or std.mem.endsWith(u8, m, "/json") or std.mem.endsWith(u8, m, "/xml")) return .text;
    for ([_][]const u8{ "application/javascript", "application/ecmascript", "application/x-javascript", "application/x-www-form-urlencoded", "application/graphql", "application/x-ndjson", "application/jsonl", "application/csv" }) |t| {
        if (std.mem.eql(u8, m, t)) return .text;
    }
    return .binary;
}

/// W9d② 적대 리뷰 5 회차 A2(작성자 결정): 기다림의 차례가 뒤인 CDP 자원 종류(`type`) — 페이지가 그리는 데 쓰고 주소로 다시 받을 수 있는 것:
/// `Document`·`Script`·`Stylesheet`·`Image`·`Font`·`Media`. 그 밖(`XHR`·`Fetch`·`EventSource`·`Manifest`·`TextTrack`·`Ping`·`Other`… 그리고
/// 종류를 모름)은 앞이다 — 에이전트가 본문으로 읽는 것은 대개 페이지가 받은 데이터다(첫 적재의 스크립트·스타일이 그것을 `busy` 로 밀어냈다).
/// 문서는 뒤다 — 페이지의 글은 snapshot·content 로도 읽고, iframe 이 많은 페이지(광고)에서 데이터를 밀어내지 않게.
pub fn lowPriority(kind: []const u8) bool {
    for ([_][]const u8{ "Document", "Script", "Stylesheet", "Image", "Font", "Media" }) |k| if (std.mem.eql(u8, kind, k)) return true;
    return false;
}

/// 재검증 4 차 뒤 B15-1·B15-2: 글을 푸는 규칙이 MIME 가 아니라 자원 종류로 갈리는 CDP `type` — 페이지가 `<script src>`(`Script`)·
/// `<link rel=stylesheet>`(`Stylesheet`)로 불러온 글은 Chromium 이 헤더에 charset 이 없으면 **문서의 인코딩**·`<script charset>`·`@charset` 으로
/// 푼다(MIME 의 기본이 아니다 — 실측 `v20f-15-vj-js-docgk`·`vj-js-attrgk`·`vj-css-u8`). 같은 주소를 fetch·XHR 로 받으면 MIME 의 기본이다(`dg1-csscs`)
/// — 그래서 주소가 아니라 종류로 가른다.
pub const ResKind = enum(u2) {
    other,
    script,
    stylesheet,
};

pub fn resKind(kind: []const u8) ResKind {
    if (std.mem.eql(u8, kind, "Script")) return .script;
    if (std.mem.eql(u8, kind, "Stylesheet")) return .stylesheet;
    return .other;
}

/// windows-1252 로 되돌려 볼 MIME 인가(J11 — charset 없는 `text/plain` 이 깨져 왔다; HTML·JavaScript·JSON 은 맞게 풀렸다).
///
/// 재검증 4 차 뒤 B15-2: Chromium 의 DevTools 는 charset 없는 JavaScript·JSON MIME 를 UTF-8 로 푼다(Blink `IsSupportedJavaScriptMIMEType` —
/// WHATWG 「JavaScript MIME type essence」 목록 — 과 `IsJSONMimeType`; 실측 `text/x-javascript`·`text/jscript`·`text/javascript1.5`·`text/json`) —
/// 전에는 `text/javascript`·`text/ecmascript` 만 빼 나머지의 맞는 UTF-8 글에 거짓 `chromium_decoded` 가 붙었다. 이 목록을 잘못 넓혀도 틀린 글이
/// 표시 없이 나가지 않는다 — windows-1252 로 푼 ASCII 아닌 글은 늘 받은 바이트보다 길어 아래 길이 견주기가 표시한다.
const js_json_text_mimes = [_][]const u8{
    "text/javascript",    "text/ecmascript",    "text/javascript1.0", "text/javascript1.1", "text/javascript1.2", "text/javascript1.3",
    "text/javascript1.4", "text/javascript1.5", "text/jscript",       "text/livescript",    "text/x-ecmascript",  "text/x-javascript",
    "text/json",
};

fn redecodeCandidate(mime_full: []const u8) bool {
    const semi = std.mem.indexOfScalar(u8, mime_full, ';') orelse mime_full.len;
    const mime = std.mem.trim(u8, mime_full[0..semi], " \t");
    if (!std.ascii.startsWithIgnoreCase(mime, "text/")) return false;
    if (std.ascii.eqlIgnoreCase(mime, "text/html")) return false;
    for (js_json_text_mimes) |t| if (std.ascii.eqlIgnoreCase(mime, t)) return false;
    if (std.ascii.endsWithIgnoreCase(mime, "+json")) return false; // `IsJSONMimeType` 의 `+json`
    // 재검증 3 차 뒤 D-I2·N-i2: `text/xml` 은 Chromium 이 XML 로 풀었다(선언·BOM, 없으면 UTF-8) — windows-1252 로 되돌리지 않는다(`sniffedMime`).
    return !sniffedMime(mime_full);
}

/// 재검증 3 차 뒤 D-I1·D-I2: Chromium 이 헤더에 charset 이 없을 때 본문을 보고 인코딩을 고르는 MIME — HTML(`<meta>` 앞 훑기는 `<head>` 끝까지·
/// XML 선언)과 XML 무리(`text/xml`·`application/xml`·`application/xhtml+xml`·`image/svg+xml`·`*+xml` — XML 선언). maru 는 받은 바이트를
/// 보지 못해 그 고름이 맞았는지 가르지 못한다(같은 길이면 크기로도 못 가른다).
fn sniffedMime(mime_full: []const u8) bool {
    const semi = std.mem.indexOfScalar(u8, mime_full, ';') orelse mime_full.len;
    const mime = std.mem.trim(u8, mime_full[0..semi], " \t");
    for ([_][]const u8{ "text/html", "text/xml", "application/xml", "application/xhtml+xml", "image/svg+xml" }) |t| if (std.ascii.eqlIgnoreCase(mime, t)) return true;
    return mime.len > 4 and std.ascii.endsWithIgnoreCase(mime, "+xml");
}

/// 응답 Content-Type 의 charset 갈래 — Chromium 이 그 글을 푼 방법에 맞춘다(W9d② 재검증 15 회차 D-G1: 전에는 `charset=` 부분 글을 찾아 UTF-8 이
/// 아닌 값을 모두 `other` 로 쳐, Chromium 이 무시한 빈 값·모르는 이름표·`x-charset=`·겹친 헤더의 본문이 windows-1252 로 풀린 채 표시 없이 남았다).
pub const Charset = enum {
    /// charset 매개변수가 없거나 그 값이 비었다 — Chromium 은 MIME 의 기본(`text/*` 는 windows-1252, JSON·JavaScript·HTML 은 UTF-8)이나 BOM 으로 푼다.
    none,
    /// Encoding Standard 의 UTF-8 이름표(`utf-8`·`utf8`·`unicode-1-1-utf-8`…).
    utf8,
    /// 이름표 표에 없는 값(`none`·`binary`·`utf-8x`·`'utf-8'`…) — Chromium 은 그 이름으로 디코더를 만들지 못해 **MIME 와 상관없이** windows-1252 로
    /// 푼다(BOM 이 있으면 그것 — 실측: `application/json; charset=x-bogus` 도 windows-1252). fetch·XHR 은 UTF-8 로 읽는다.
    unknown,
    /// 그 밖의 알려진 이름표(Latin-1·EUC-KR·UTF-16…) — Chromium 도 XHR 도 그 charset 으로 푼다.
    other,
};

/// Encoding Standard(WHATWG)의 이름표 표 — 대소문자 무시. UTF-8 의 이름표는 `utf8`, 나머지 인코딩(replacement·UTF-16·x-user-defined 포함)의
/// 이름표는 `other`. 표에 없으면 `unknown`.
const charset_labels = blk: {
    @setEvalBranchQuota(50_000);
    const utf8_labels = [_][]const u8{ "unicode-1-1-utf-8", "unicode11utf8", "unicode20utf8", "utf-8", "utf8", "x-unicode20utf8" };
    // 인코딩마다 한 줄(Encoding Standard 의 「Encodings」 표 차례).
    const other_groups = [_][]const []const u8{
        &.{ "866", "cp866", "csibm866", "ibm866" }, // IBM866
        &.{ "csisolatin2", "iso-8859-2", "iso-ir-101", "iso8859-2", "iso88592", "iso_8859-2", "iso_8859-2:1987", "l2", "latin2" }, // ISO-8859-2
        &.{ "csisolatin3", "iso-8859-3", "iso-ir-109", "iso8859-3", "iso88593", "iso_8859-3", "iso_8859-3:1988", "l3", "latin3" }, // ISO-8859-3
        &.{ "csisolatin4", "iso-8859-4", "iso-ir-110", "iso8859-4", "iso88594", "iso_8859-4", "iso_8859-4:1988", "l4", "latin4" }, // ISO-8859-4
        &.{ "csisolatincyrillic", "cyrillic", "iso-8859-5", "iso-ir-144", "iso8859-5", "iso88595", "iso_8859-5", "iso_8859-5:1988" }, // ISO-8859-5
        &.{ "arabic", "asmo-708", "csiso88596e", "csiso88596i", "csisolatinarabic", "ecma-114", "iso-8859-6", "iso-8859-6-e", "iso-8859-6-i", "iso-ir-127", "iso8859-6", "iso88596", "iso_8859-6", "iso_8859-6:1987" }, // ISO-8859-6
        &.{ "csisolatingreek", "ecma-118", "elot_928", "greek", "greek8", "iso-8859-7", "iso-ir-126", "iso8859-7", "iso88597", "iso_8859-7", "iso_8859-7:1987", "sun_eu_greek" }, // ISO-8859-7
        &.{ "csiso88598e", "csisolatinhebrew", "hebrew", "iso-8859-8", "iso-8859-8-e", "iso-ir-138", "iso8859-8", "iso88598", "iso_8859-8", "iso_8859-8:1988", "visual" }, // ISO-8859-8
        &.{ "csiso88598i", "iso-8859-8-i", "logical" }, // ISO-8859-8-I
        &.{ "csisolatin6", "iso-8859-10", "iso-ir-157", "iso8859-10", "iso885910", "l6", "latin6" }, // ISO-8859-10
        &.{ "iso-8859-13", "iso8859-13", "iso885913" }, // ISO-8859-13
        &.{ "iso-8859-14", "iso8859-14", "iso885914" }, // ISO-8859-14
        &.{ "csisolatin9", "iso-8859-15", "iso8859-15", "iso885915", "iso_8859-15", "l9" }, // ISO-8859-15
        &.{"iso-8859-16"}, // ISO-8859-16
        &.{ "cskoi8r", "koi", "koi8", "koi8-r", "koi8_r" }, // KOI8-R
        &.{ "koi8-ru", "koi8-u" }, // KOI8-U
        &.{ "csmacintosh", "mac", "macintosh", "x-mac-roman" }, // macintosh
        &.{ "dos-874", "iso-8859-11", "iso8859-11", "iso885911", "tis-620", "windows-874" }, // windows-874
        &.{ "cp1250", "windows-1250", "x-cp1250" }, // windows-1250
        &.{ "cp1251", "windows-1251", "x-cp1251" }, // windows-1251
        &.{ "ansi_x3.4-1968", "ascii", "cp1252", "cp819", "csisolatin1", "ibm819", "iso-8859-1", "iso-ir-100", "iso8859-1", "iso88591", "iso_8859-1", "iso_8859-1:1987", "l1", "latin1", "us-ascii", "windows-1252", "x-cp1252" }, // windows-1252
        &.{ "cp1253", "windows-1253", "x-cp1253" }, // windows-1253
        &.{ "cp1254", "csisolatin5", "iso-8859-9", "iso-ir-148", "iso8859-9", "iso88599", "iso_8859-9", "iso_8859-9:1989", "l5", "latin5", "windows-1254", "x-cp1254" }, // windows-1254
        &.{ "cp1255", "windows-1255", "x-cp1255" }, // windows-1255
        &.{ "cp1256", "windows-1256", "x-cp1256" }, // windows-1256
        &.{ "cp1257", "windows-1257", "x-cp1257" }, // windows-1257
        &.{ "cp1258", "windows-1258", "x-cp1258" }, // windows-1258
        &.{ "x-mac-cyrillic", "x-mac-ukrainian" }, // x-mac-cyrillic
        &.{ "chinese", "csgb2312", "csiso58gb231280", "gb2312", "gb_2312", "gb_2312-80", "gbk", "iso-ir-58", "x-gbk" }, // GBK
        &.{"gb18030"}, // gb18030
        &.{ "big5", "big5-hkscs", "cn-big5", "csbig5", "x-x-big5" }, // Big5
        &.{ "cseucpkdfmtjapanese", "euc-jp", "x-euc-jp" }, // EUC-JP
        &.{ "csiso2022jp", "iso-2022-jp" }, // ISO-2022-JP
        &.{ "csshiftjis", "ms932", "ms_kanji", "shift-jis", "shift_jis", "sjis", "windows-31j", "x-sjis" }, // Shift_JIS
        &.{ "cseuckr", "csksc56011987", "euc-kr", "iso-ir-149", "korean", "ks_c_5601-1987", "ks_c_5601-1989", "ksc5601", "ksc_5601", "windows-949" }, // EUC-KR
        &.{ "csiso2022kr", "hz-gb-2312", "iso-2022-cn", "iso-2022-cn-ext", "iso-2022-kr", "replacement" }, // replacement
        &.{ "unicodefffe", "utf-16be" }, // UTF-16BE
        &.{ "csunicode", "iso-10646-ucs-2", "ucs-2", "unicode", "unicodefeff", "utf-16", "utf-16le" }, // UTF-16LE
        &.{"x-user-defined"}, // x-user-defined
    };
    var count = utf8_labels.len;
    for (other_groups) |g| count += g.len;
    const KV = struct { []const u8, Charset };
    var kvs: [count]KV = undefined;
    for (utf8_labels, 0..) |l, i| kvs[i] = .{ l, .utf8 };
    var n = utf8_labels.len;
    for (other_groups) |g| for (g) |l| {
        kvs[n] = .{ l, .other };
        n += 1;
    };
    break :blk std.StaticStringMapWithEql(Charset, std.static_string_map.eqlAsciiIgnoreCase).initComptime(kvs);
};

/// 이름표(따옴표를 푼 값)의 갈래 — Encoding Standard 의 「get an encoding」 처럼 앞뒤 ASCII 공백을 떼고 대소문자 없이 표에서 찾는다. 빈 값은 `none`
/// (Chromium 은 빈 charset 을 없는 것으로 친다 — 실측: `application/json; charset=` 는 UTF-8 로 풀렸다).
pub fn charsetOfLabel(label_in: []const u8) Charset {
    const label = std.mem.trim(u8, label_in, " \t\n\x0c\r");
    if (label.len == 0) return .none;
    return charset_labels.get(label) orelse .unknown;
}

const http_ws = " \t\r\n";

fn httpTokenByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", c) != null;
}

fn allHttpToken(s: []const u8) bool {
    for (s) |c| if (!httpTokenByte(c)) return false;
    return true;
}

/// 따옴표 글(`"` 에서 시작)의 끝: 내용의 끝(닫는 `"` 의 자리, 닫히지 않으면 글의 끝)과 그 뒤의 자리. `\` 뒤의 글자는 건너뛴다.
fn quotedEnd(s: []const u8, open: usize) struct { content_end: usize, next: usize } {
    var i = open + 1;
    while (i < s.len) {
        switch (s[i]) {
            '\\' => i = @min(i + 2, s.len),
            '"' => return .{ .content_end = i, .next = i + 1 },
            else => i += 1,
        }
    }
    return .{ .content_end = s.len, .next = s.len };
}

/// 매개변수 값 하나(입력 안의 조각 — 따옴표 글이면 따옴표 안, `\` 를 아직 풀지 않았다).
const ParamValue = struct { raw: []const u8, quoted: bool };

/// MIME Sniffing 의 「parse a MIME type」 — 이 표가 쓰는 것만: 본질(`type/subtype`, 입력 안의 조각)과 첫 `charset` 매개변수.
/// `divergent` — W9d② 재검증 3 차 D-H2: Chromium 의 헤더 풀기(`net::HttpUtil::ParseContentType`)가 이 값을 이 풀기와 다르게 읽는다(첫 `charset` 값에
/// 제어 글자가 있다 — Chromium 은 그 값을 검사 없이 쓰고 모르는 이름이라 windows-1252 로 푼다). 이름 뒤의 공백(`charset = utf-8`)은 둘 다 charset 으로
/// 보지 않는다(실측 `v20f-15-dg1-spaced` — windows-1252 로 풀렸다) — 갈리지 않는다.
const ParsedMime = struct { essence: []const u8, charset: ?ParamValue, divergent: bool = false };

fn parseMime(value_in: []const u8) ?ParsedMime {
    const value = std.mem.trim(u8, value_in, http_ws);
    const slash = std.mem.indexOfScalar(u8, value, '/') orelse return null;
    if (slash == 0 or !allHttpToken(value[0..slash])) return null;
    var p = slash + 1;
    const semi = std.mem.indexOfScalarPos(u8, value, p, ';') orelse value.len;
    const subtype = std.mem.trimEnd(u8, value[p..semi], http_ws);
    if (subtype.len == 0 or !allHttpToken(subtype)) return null;
    var m: ParsedMime = .{ .essence = value[0 .. p + subtype.len], .charset = null };
    p = semi;
    while (p < value.len) {
        p += 1; // `;`
        while (p < value.len and std.mem.indexOfScalar(u8, http_ws, value[p]) != null) p += 1;
        const name_start = p;
        while (p < value.len and value[p] != ';' and value[p] != '=') p += 1;
        const name = value[name_start..p];
        if (p < value.len) {
            if (value[p] == ';') continue;
            p += 1; // `=`
        }
        // 재검증 3 차 D-H2: `=` 뒤의 공백 다음 따옴표 글(`charset= "utf-8"`)은 Chromium 처럼 따옴표를 푼다 — 실측: `charset= "utf-8"` 은 UTF-8 로,
        // `charset= "euc-kr"` 은 EUC-KR 로 풀렸다(Fetch 는 따옴표째 이름표로 봐 표에 없다). 따옴표 아닌 값의 앞 공백은 이름표 표가 뗀다.
        while (p < value.len and (value[p] == ' ' or value[p] == '\t')) p += 1;
        if (p >= value.len) break;
        var v: ParamValue = undefined;
        if (value[p] == '"') {
            const q = quotedEnd(value, p);
            v = .{ .raw = value[p + 1 .. q.content_end], .quoted = true };
            p = std.mem.indexOfScalarPos(u8, value, q.next, ';') orelse value.len;
        } else {
            const start = p;
            p = std.mem.indexOfScalarPos(u8, value, p, ';') orelse value.len;
            const raw = std.mem.trimEnd(u8, value[start..p], http_ws);
            if (raw.len == 0) continue;
            v = .{ .raw = raw, .quoted = false };
        }
        // 이름은 꼭 `charset`(대소문자 무시 — `x-charset`·`charset ` 은 아니다), 값은 따옴표 글의 글자만(제어 글자가 없다), 같은 이름은 첫 것.
        if (m.charset != null or !std.ascii.eqlIgnoreCase(name, "charset")) continue;
        const bad = for (v.raw) |c| {
            if ((c < 0x20 and c != '\t') or c == 0x7f) break true;
        } else false;
        // D-H2: Fetch 는 제어 글자가 든 값을 건너뛰고 다음 `charset` 을 보지만 Chromium 은 첫 값을 그대로 써 windows-1252 로 푼다 — 갈린다.
        if (bad) m.divergent = true else m.charset = v;
    }
    return m;
}

/// 헤더 값을 `,` 로 가른 다음 조각(따옴표 안의 `,` 는 가르지 않는다 — Fetch 의 「get, decode, and split」).
fn nextHeaderValue(s: []const u8, pos: *usize) ?[]const u8 {
    if (pos.* > s.len) return null;
    const start = pos.*;
    var i = start;
    while (i < s.len and s[i] != ',') {
        i = if (s[i] == '"') quotedEnd(s, i).next else i + 1;
    }
    pos.* = i + 1;
    return std.mem.trim(u8, s[start..i], " \t");
}

/// Content-Type 헤더(CDP 는 겹친 헤더를 `\n` 으로 잇는다)가 정한 MIME 의 charset 값 — Fetch 의 「extract a MIME type」: 값마다 MIME 를 읽고(못 읽거나
/// `*/*` 면 건너뛴다) 마지막 것을 쓰되, 본질이 앞 것과 같고 charset 이 없으면 앞의 charset 을 물려받는다(본질이 바뀌면 버린다).
///
/// W9d② 재검증 3 차 D-H2(정직하게 실패한다): 본문을 푼 것은 Fetch 가 아니라 Chromium 의 헤더 풀기다 — 둘이 갈리는 값이 하나라도 있으면
/// `divergent`(`charsetOf` 가 `unknown` — 되돌려 보고 못 하면 `chromium_decoded`). 갈리는 값: `/` 가 있는데(Chromium 은 `/` 가 든 값을 MIME 로
/// 받는다 — 타입은 공백·`;`·`(` 까지) Fetch 가 읽지 못한 것(`text/plain(x)`·`text/plai{n}`·`text/plain x`·`text/plain@`·`application/json (v2)`),
/// 첫 `charset` 값의 제어 글자(`ParsedMime.divergent`). 전에는 그 값을 건너뛰어 앞 헤더의 EUC-KR 을 따라 `other` 였는데
/// Chromium 은 뒤 값의 모르는 이름표로 windows-1252 로 풀어, 깨진 글이 표시 없이 남았다(fetch·XHR 둘 다 받은 바이트를 읽었다). `/` 가 없는
/// 값(`bogus`·`charset=utf-8`)은 둘 다 버린다 — 갈리지 않는다.
const CtCharset = struct { value: ?ParamValue = null, divergent: bool = false };

fn contentTypeCharset(content_type: []const u8) CtCharset {
    var essence: ?[]const u8 = null;
    var inherited: ?ParamValue = null;
    var result: CtCharset = .{};
    var lines = std.mem.splitScalar(u8, content_type, '\n');
    while (lines.next()) |line| {
        var pos: usize = 0;
        while (nextHeaderValue(line, &pos)) |value| {
            const m = parseMime(value) orelse {
                if (std.mem.indexOfScalar(u8, value, '/') != null) result.divergent = true;
                continue;
            };
            if (m.divergent) result.divergent = true;
            if (std.mem.eql(u8, m.essence, "*/*")) continue;
            result.value = m.charset;
            if (essence == null or !std.ascii.eqlIgnoreCase(m.essence, essence.?)) {
                inherited = m.charset;
                essence = m.essence;
            } else if (m.charset == null and inherited != null) result.value = inherited;
        }
    }
    return result;
}

/// Content-Type 헤더의 charset 갈래(위 `Charset`). 따옴표 글은 `\` 를 풀어 이름표로 본다 — 이름표 표의 가장 긴 것보다 길면 표에 없다.
pub fn charsetOf(content_type: []const u8) Charset {
    const ct = contentTypeCharset(content_type);
    if (ct.divergent) return .unknown;
    const v = ct.value orelse return .none;
    if (!v.quoted) return charsetOfLabel(v.raw);
    var buf: [64]u8 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < v.raw.len) : (n += 1) {
        var c = v.raw[i];
        if (c == '\\' and i + 1 < v.raw.len) {
            c = v.raw[i + 1];
            i += 2;
        } else i += 1;
        if (n == buf.len) return .unknown;
        buf[n] = c;
    }
    return charsetOfLabel(buf[0..n]);
}

// ── 결과 풀기 ─────────────────────────────────────────────────────────────────────────────────────────────

/// windows-1252 의 0x80..0x9F 자리(정의되지 않은 다섯은 그 C1 코드점 그대로 — Chromium 의 디코더와 같다).
const cp1252_high = [32]u21{
    0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
    0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
};

fn cp1252Byte(cp: u21) ?u8 {
    if (cp < 0x80 or (cp >= 0xA0 and cp <= 0xFF)) return @intCast(cp);
    for (cp1252_high, 0..) |v, i| if (v == cp) return @intCast(0x80 + i);
    return null;
}

/// 글을 windows-1252 바이트로 되돌린다(`out` 에) — 한 글자라도 그 표에 없으면 null.
pub fn toCp1252(text: []const u8, out: []u8) ?[]u8 {
    var it = (std.unicode.Utf8View.init(text) catch return null).iterator();
    var n: usize = 0;
    while (it.nextCodepoint()) |cp| {
        if (n == out.len) return null;
        out[n] = cp1252Byte(cp) orelse return null;
        n += 1;
    }
    return out[0..n];
}

pub const Decoded = struct {
    state: State,
    flags: Flags = .{},
    /// `captured` 일 때만 — 부른 쪽 소유.
    bytes: []u8 = &.{},
    /// `over_cap` 일 때 넘친 글의 바이트(0 = 모른다) — Chromium 이 windows-1252 로 푼 글은 UTF-8 로 원래의 세 배까지 커져, 받은 바이트(Σ
    /// `dataReceived`)는 상한 안인데 글이 넘칠 수 있다. 부른 쪽은 둘 중 큰 것을 알린다(크기와 상태가 엇갈리지 않게).
    over_bytes: u64 = 0,
};

/// `getResponseBody` 의 결과(`{"body":"…","base64Encoded":bool}`)를 보낼 바이트로 푼다. `mime` 은 응답 MIME, `charset` 은 Content-Type 의
/// charset 갈래(`Charset`), `raw_size` 는 받은 바이트(Σ `dataReceived` — 0 = 모른다). 실패한 호출(`ok` 거짓 — 「다음 문서로 옮겨 사라졌다」 등)과
/// 모양이 틀린 결과는 `unavailable`.
///
/// windows-1252 되돌리기(J11)는 Chromium 이 **UTF-8 바이트를 windows-1252 로 잘못 읽은** 글에만 한다(W9d② 적대 리뷰 1 회차): 글을 그 표로
/// 되돌린 바이트가 UTF-8 로 맞고, 받은 바이트 수가 알려졌으면 그것과 꼭 같을 때. windows-1252 로 읽었다면 글자 하나가 받은 바이트 하나라
/// 수가 같다. BOM 으로 UTF-8 을 알아본 본문(Chromium 이 맞게 풀었다 — BOM 세 바이트와 여러 바이트 글자만큼 수가 다르다)은 이것으로 걸러져
/// 그대로 둔다(전에는 「Ã©」 같은 글을 담은 그런 본문을 「é」 로 바꿨다). 남는 틈: 받은 바이트를 모를 때(0)는 수를 보지 않는다. 진짜
/// Latin-1 본문 안의 「Ã©」 꼴 바이트는 UTF-8 로 맞아 되돌린다 — fetch·XHR 은 charset 없는 글을 UTF-8 로 읽으므로 그것이 페이지가 읽은 글이다.
///
/// `kind` 는 CDP 자원 종류(`ResKind` — 재검증 4 차 뒤 B15): 헤더 charset 이 없는 스크립트·스타일시트는 `subresourceUtf8` 로 가른다.
///
/// 상한(재검증 4 차 뒤 B16-1 — 작성자 선택): 1 MiB 는 **싣는 글**(UTF-8 글, 바이너리면 바이트)의 상한이다 — 받은 바이트(Σ `dataReceived`)도 따로
/// 1 MiB 로 먼저 막는다(`decide`). wire 의 본문 조각·크기 검사(`net_fields.checkBodyData`·`checkBodyEnd`), 앱의 본문 하나 상한(`web_osr_network.
/// max_body_bytes`), 보내는 줄의 본문 몫(`out_queue.body_capacity` 2 MiB)이 모두 이 수로 셈하므로 글을 더 담으려면 그 셋을 함께 바꿔야 한다
/// — 그래서 Chromium 이 푼 글이 커져(windows-1252 는 0x80 넘는 바이트마다, EUC-KR 한글은 2 → 3 바이트) 넘친 본문은 받은 바이트가 1 MiB 아래여도
/// `over_cap` 이고, 알리는 크기는 둘 중 큰 것(`over_bytes`)이다.
pub fn decodeResult(gpa: std.mem.Allocator, ok: bool, json: []const u8, mime: []const u8, charset: Charset, raw_size: u64, kind: ResKind) std.mem.Allocator.Error!Decoded {
    if (!ok) return .{ .state = .unavailable };
    const parsed = std.json.parseFromSlice(struct { body: []const u8 = "", base64Encoded: bool = false }, gpa, json, .{ .ignore_unknown_fields = true }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .state = .unavailable },
    };
    defer parsed.deinit();
    const v = parsed.value;
    var bytes: []u8 = undefined;
    if (v.base64Encoded) {
        const dec = std.base64.standard.Decoder;
        const n = dec.calcSizeForSlice(v.body) catch return .{ .state = .unavailable };
        if (n > msg.max_net_body_bytes) return .{ .state = .over_cap, .over_bytes = n };
        bytes = try gpa.alloc(u8, n);
        dec.decode(bytes, v.body) catch {
            gpa.free(bytes);
            return .{ .state = .unavailable };
        };
    } else {
        if (v.body.len > 4 * msg.max_net_body_bytes) return .{ .state = .over_cap, .over_bytes = v.body.len };
        bytes = try gpa.dupe(u8, v.body);
    }
    if (bytes.len == 0) {
        gpa.free(bytes);
        return .{ .state = .no_body };
    }
    var flags: Flags = .{};
    if (v.base64Encoded) {
        // 글 MIME 인데 base64 로 왔다(잘못된 UTF-8 JSON·charset 없는 EUC-KR — J11): UTF-8 이면 글, 아니면 바이트 그대로.
        if (!std.unicode.utf8ValidateSlice(bytes)) flags.binary = true;
    } else if (!isAscii(bytes) and charset == .none and kind != .other) {
        // 재검증 4 차 뒤 B15-1·B15-2: 페이지가 불러온 스크립트·스타일시트(헤더 charset 없음)는 Chromium 이 문서 인코딩·`<script charset>`·
        // `@charset` 으로 풀었다 — MIME 의 기본(windows-1252 되돌리기)도 길이만도 맞지 않는다. UTF-8 로 풀린 근거가 없으면 표시한다.
        if (!subresourceUtf8(bytes, raw_size, kind)) flags.chromium_decoded = true;
    } else if (!isAscii(bytes) and redecodeWanted(charset, mime)) {
        // charset 없는 text/*·모르는 charset 이름표의 글을 Chromium 이 windows-1252 로 풀었다(J11·D-G1) — 되돌려 UTF-8 이면 그것이 페이지가 받은 글이다.
        const back = try gpa.alloc(u8, bytes.len);
        defer gpa.free(back);
        if (toCp1252(bytes, back)) |raw| {
            if (std.unicode.utf8ValidateSlice(raw) and !isAscii(raw) and (raw_size == 0 or raw_size == raw.len)) {
                const fixed = try gpa.dupe(u8, raw);
                gpa.free(bytes);
                bytes = fixed;
                flags.redecoded = true;
            } else flags.chromium_decoded = true;
        } else flags.chromium_decoded = true;
    } else if (charset != .other and raw_size != 0 and raw_size != bytes.len) {
        // charset 이 없거나 UTF-8 이거나 Chromium 이 모르는 이름표인 글인데 받은 바이트 수와 글의 UTF-8 길이가 다르다 — Chromium 이 BOM(UTF-16 등 — 선언한 charset 보다 앞선다)
        // 이나 MIME 의 기본으로 다르게 풀었다(W9d② 20 회 검증 15 회차 D1: `FF FE` 로 시작한 JSON 12 바이트가 UTF-16 글 15 바이트로 왔다;
        // 최종 재검증 D-B1: `charset=utf-8` 이어도 같다; 재검증 15 회차 D-G1: 모르는 이름표의 ASCII 글도). 받은 바이트도, fetch 가 읽은 글도 아니다. 다른 charset 을 선언한 글(Latin-1·EUC-KR)은
        // 그 charset 으로 푼 것이 XHR 이 읽은 글이라 표시하지 않는다.
        flags.chromium_decoded = true;
    } else if (charset == .none and !isAscii(bytes) and sniffedMime(mime)) {
        // 재검증 3 차 뒤 D-I1·D-I2(정직하게 실패 — 그 전의 D-H1 은 `text/html` 의 앞 1024 바이트에서 `<meta>` 를 훑었다): 헤더에 charset 이 없는
        // HTML·XML 무리는 Chromium 이 본문의 선언(`<head>` 끝까지의 `<meta>`·XML 선언)으로 인코딩을 고른다. 그 선언은 1024 바이트 밖에도 있고
        // (실측: 1100 바이트의 `<title>` 뒤·`<link>` 40 개 뒤·1.1 KiB 주석 뒤·DOCTYPE 앞의 `<?xml … encoding="euc-kr"?>`), 받은 바이트를 보지 못하는
        // maru 는 그 고름을 확인하지 못한다 — 훑기를 넓히는 대신 ASCII 아닌 글에 늘 표시한다(주석·스크립트 안의 `charset=` 를 읽던 거짓 표시 N-i1 도
        // 없어진다). 대가: 맞게 풀린 UTF-8 HTML·XML 도 「다를 수 있다」 표시를 단다(검증자의 흔한 꼴 36 개 중 15 개).
        flags.chromium_decoded = true;
    }
    if (bytes.len > msg.max_net_body_bytes) {
        const n = bytes.len;
        gpa.free(bytes);
        return .{ .state = .over_cap, .over_bytes = n };
    }
    return .{ .state = .captured, .flags = flags, .bytes = bytes };
}

/// windows-1252 로 되돌려 볼 글인가(ASCII 아닌 글만 묻는다): charset 없는 `text/*`(J11 — `redecodeCandidate`), 또는 Chromium 이 모르는 charset
/// 이름표(W9d② 재검증 15 회차 D-G1 — MIME 와 상관없이 windows-1252 로 푼다). W9d② 재검증 3 차 D-H1: 모르는 이름표의 글은 길이가 받은 바이트 수와
/// 같아도 되돌려 본다 — 전에는 「같으면 맞게 풀린 글」 로 두었는데, 모르는 이름표에서 Chromium 은 windows-1252(0x80 넘는 바이트마다 UTF-8 이
/// 길어진다)나 BOM 으로만 풀므로 ASCII 아닌 글의 길이가 꼭 같으면 UTF-16 BOM 으로 읽은 글뿐이다(실측: `FF FE 00 AC 98 B0` 6 바이트가 「가나」 6
/// 바이트로 표시 없이 왔고 fetch 는 U+FFFD… 를 읽었다). 되돌린 바이트 수가 받은 수와 달라 `chromium_decoded` 가 된다.
fn redecodeWanted(charset: Charset, mime: []const u8) bool {
    return switch (charset) {
        .none => redecodeCandidate(mime),
        .unknown => true,
        .utf8, .other => false,
    };
}

/// 재검증 4 차 뒤 B15-1·B15-2(작성자 결정 — 「틀린 글을 표시 없이 내보내지 않는다」 가 먼저): 헤더 charset 이 없는 스크립트·스타일시트의 ASCII
/// 아닌 글(`text`)이 받은 바이트를 UTF-8 로 푼 그대로라고 볼 근거가 있나. 근거는 둘 다여야 한다:
/// - 글의 UTF-8 길이가 받은 바이트 수(`raw_size` — 0 = 모른다면 근거 없음)와 꼭 같다. 한 바이트 인코딩(windows-125x·ISO-8859-x·KOI8…)으로 푼
///   0x80 넘는 바이트는 늘 UTF-8 두 바이트 넘게 되어 길이가 달라진다.
/// - U+0800–U+FFFF(UTF-8 세 바이트, U+FFFD 는 빼고) 글자가 하나라도 있다. EUC-KR·GBK·Big5·Shift_JIS 의 두 바이트 글자가 그 범위로 풀리면
///   한 바이트 길어지고(Shift_JIS 의 한 바이트 반각 가나는 두 바이트 길어진다), 줄어드는 꼴(GB18030 의 네 바이트·ISO-2022-JP 의 전환열·UTF-16)이 우연히 메우지
///   않는 한 길이가 같을 수 없다. 그리스·키릴 문자처럼 두 바이트로 풀리는 글자뿐이면(EUC-KR 「αβγδ」 8 바이트 = UTF-8 8 바이트 — B15-1) 가르지 못해
///   표시한다.
/// - 스타일시트가 `@charset "<UTF-8 아닌 이름표>";` 로 시작하면 Chromium 은 그것으로 풀었다 — 근거 없음.
/// 대가: 맞게 풀린 UTF-8 글인데 ASCII 밖 글자가 모두 U+0080–U+07FF(라틴 악센트·그리스·키릴·히브리·아랍)인 스크립트·스타일시트는 표시한다.
/// 남는 틈(표시 없이 틀릴 수 있다): 위 줄어드는 꼴이 우연히 길이를 맞춘 글, EUC-JP 의 세 바이트 JIS X 0212 글자뿐인 글.
fn subresourceUtf8(text: []const u8, raw_size: u64, kind: ResKind) bool {
    if (raw_size == 0 or raw_size != text.len) return false;
    if (kind == .stylesheet and std.mem.startsWith(u8, text, "@charset \"")) {
        const rest = text["@charset \"".len..];
        const end = std.mem.indexOfScalar(u8, rest, '"') orelse return false;
        if (charsetOfLabel(rest[0..end]) != .utf8) return false;
    }
    var it = (std.unicode.Utf8View.init(text) catch return false).iterator();
    while (it.nextCodepoint()) |cp| if (cp >= 0x800 and cp <= 0xFFFF and cp != 0xFFFD) return true;
    return false;
}

fn isAscii(b: []const u8) bool {
    for (b) |c| if (c >= 0x80) return false;
    return true;
}

// ── CDP 이벤트에서 고른 값 ────────────────────────────────────────────────────────────────────────────────

pub const Rid = struct {
    buf: [max_rid_bytes]u8 = undefined,
    len: u8 = 0,

    pub fn init(s: []const u8) ?Rid {
        if (s.len == 0 or s.len > max_rid_bytes) return null;
        var r: Rid = .{ .len = @intCast(s.len) };
        @memcpy(r.buf[0..s.len], s);
        return r;
    }

    pub fn slice(self: *const Rid) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn eql(self: *const Rid, s: []const u8) bool {
        return std.mem.eql(u8, self.slice(), s);
    }
};

/// 표가 받는 CDP 사건(호출자가 JSON 에서 고른 값 — `parseEvent`).
pub const Event = union(enum) {
    /// `Network.requestWillBeSent` — 리다이렉트 홉이면 `redirect`(열쇠는 첫 주소의 것). `low` 는 자원 종류가 기다림의 뒤 차례(`lowPriority` —
    /// W9d② 적대 리뷰 5 회차 A2).
    /// `loader` 는 CDP `loaderId` 의 해시(0 = 없다 — worker 의 요청은 빈 글): 그 요청을 낸 문서(재검증 3 차 LB-1 — `Table.crossesDoc`).
    /// `res_kind` 는 글 풀기가 갈리는 자원 종류(`ResKind` — 재검증 4 차 뒤 B15).
    will_be_sent: struct { rid: []const u8, url_hash: u64, method_hash: u64, ts_us: i64, redirect: bool = false, prefetch: bool = false, low: bool = false, loader: u64 = 0, res_kind: ResKind = .other },
    /// `Network.requestWillBeSentExtraInfo` — 실제로 실린 쿠키(막히지 않은 것)·인증 헤더가 있었나.
    extra_info: struct { rid: []const u8, credentialed: bool },
    /// `Network.responseReceived` — `has_extra_info` 는 이 요청의 ExtraInfo 가 오거나 왔다는 Chromium 의 알림(`hasExtraInfo`).
    /// `ts_us` 는 CDP `timestamp`(µs — 0 = 모른다; W9d② 적대 리뷰 3 회차 P1 의 `bound`). `sw_source` 는 서비스 워커가 준 응답의 출처
    /// (`response.serviceWorkerResponseSource` — `network`·`http-cache`·`cache-storage`·`fallback-code`, 없으면 빈 글; W9d② 적대 리뷰 4 회차 SW1).
    response: struct { rid: []const u8, mime: []const u8, from_sw: bool, charset: Charset, prefetch: bool = false, has_extra_info: bool = false, ts_us: i64 = 0, sw_source: []const u8 = "", low: bool = false, res_kind: ResKind = .other },
    /// `Network.dataReceived` — 풀어 낸 바이트.
    data: struct { rid: []const u8, bytes: u64 },
    /// `Network.requestServedFromCache` — 메모리 캐시: CEF 는 이 요청을 보지 못한다(J1).
    from_cache: struct { rid: []const u8 },
    finished: struct { rid: []const u8 },
    /// `ts_us` 는 CDP `timestamp`(µs — 0 = 모른다; W9d② 적대 리뷰 5 회차 A1 의 `Cdp.failed_at`).
    failed: struct { rid: []const u8, ts_us: i64 = 0 },
};

fn getPath(v: std.json.Value, path: []const u8) ?std.json.Value {
    var cur = v;
    var it = std.mem.splitScalar(u8, path, '.');
    while (it.next()) |k| {
        if (cur != .object) return null;
        cur = cur.object.get(k) orelse return null;
    }
    return cur;
}

fn str(v: std.json.Value, path: []const u8) []const u8 {
    const x = getPath(v, path) orelse return "";
    return if (x == .string) x.string else "";
}

fn boolean(v: std.json.Value, path: []const u8) bool {
    const x = getPath(v, path) orelse return false;
    return x == .bool and x.bool;
}

fn number(v: std.json.Value, path: []const u8) ?f64 {
    const x = getPath(v, path) orelse return null;
    return switch (x) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

/// 헤더 객체에서 이름(대소문자 무시)의 값.
fn header(headers: ?std.json.Value, name: []const u8) ?[]const u8 {
    const h = headers orelse return null;
    if (h != .object) return null;
    var it = h.object.iterator();
    while (it.next()) |kv| if (std.ascii.eqlIgnoreCase(kv.key_ptr.*, name)) {
        return if (kv.value_ptr.* == .string) kv.value_ptr.string else "";
    };
    return null;
}

/// 표가 쓰는 CDP 메서드인가(메서드 이름으로 먼저 거른다 — J7: 그 밖은 풀지 않는다).
pub fn wanted(method: []const u8) bool {
    for ([_][]const u8{ "Network.requestWillBeSent", "Network.requestWillBeSentExtraInfo", "Network.responseReceived", "Network.loadingFinished", "Network.loadingFailed", "Network.requestServedFromCache" }) |m| {
        if (std.mem.eql(u8, method, m)) return true;
    }
    return false;
}

/// `Network.dataReceived` 를 풀지 않고 훑는다(J7 — 이벤트의 29 %): `"requestId":"…"` 와 `"dataLength":N`.
pub fn scanData(params: []const u8) ?Event {
    const rid = scanString(params, "\"requestId\":\"") orelse return null;
    const at = std.mem.indexOf(u8, params, "\"dataLength\":") orelse return null;
    var i = at + "\"dataLength\":".len;
    while (i < params.len and params[i] == ' ') i += 1;
    var n: u64 = 0;
    var digits: usize = 0;
    while (i < params.len and params[i] >= '0' and params[i] <= '9') : (i += 1) {
        n = n *| 10 +| (params[i] - '0');
        digits += 1;
    }
    if (digits == 0) return null;
    return .{ .data = .{ .rid = rid, .bytes = n } };
}

fn scanString(p: []const u8, needle: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, p, needle) orelse return null;
    const rest = p[at + needle.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return rest[0..end];
}

/// CDP `loaderId` 의 해시(빈 글이면 0 — 모른다).
pub fn loaderHash(id: []const u8) u64 {
    if (id.len == 0) return 0;
    return @max(1, std.hash.Wyhash.hash(0x6c6f6164, id));
}

/// CDP `timestamp`(초 — 단조 시계) 를 µs 로(없거나 이상하면 0 = 모른다).
fn cdpMicros(v: std.json.Value) i64 {
    const t = number(v, "timestamp") orelse return 0;
    if (!(t > 0 and t < 1e12)) return 0;
    return @intFromFloat(t * 1e6);
}

/// 푼 params 에서 사건 하나(모르는 메서드·모양이면 null). 글 칸은 `v` 를 빌린다.
pub fn parseEvent(method: []const u8, v: std.json.Value) ?Event {
    const rid = str(v, "requestId");
    if (rid.len == 0) return null;
    if (std.mem.eql(u8, method, "Network.requestWillBeSent")) {
        const ts = number(v, "timestamp") orelse return null;
        const url = str(v, "request.url");
        const method_name = str(v, "request.method");
        const kind = str(v, "type");
        return .{ .will_be_sent = .{
            .rid = rid,
            .url_hash = hashUrl8(url),
            .method_hash = hashMethod(method_name),
            .ts_us = @intFromFloat(ts * 1e6),
            .redirect = getPath(v, "redirectResponse") != null,
            .prefetch = std.mem.eql(u8, kind, "Prefetch"),
            .low = lowPriority(kind),
            .loader = loaderHash(str(v, "loaderId")),
            .res_kind = resKind(kind),
        } };
    }
    if (std.mem.eql(u8, method, "Network.requestWillBeSentExtraInfo")) {
        var cred = false;
        if (getPath(v, "associatedCookies")) |cookies| if (cookies == .array) for (cookies.array.items) |ck| {
            const br = getPath(ck, "blockedReasons") orelse {
                cred = true; // 막은 까닭이 없다 — 실렸다
                break;
            };
            if (br == .array and br.array.items.len == 0) {
                cred = true;
                break;
            }
        };
        const hs = getPath(v, "headers");
        if (header(hs, "authorization") != null or header(hs, "cookie") != null or header(hs, "proxy-authorization") != null) cred = true;
        return .{ .extra_info = .{ .rid = rid, .credentialed = cred } };
    }
    if (std.mem.eql(u8, method, "Network.responseReceived")) {
        const ct = header(getPath(v, "response.headers"), "content-type") orelse "";
        return .{ .response = .{
            .rid = rid,
            .mime = str(v, "response.mimeType"),
            .from_sw = boolean(v, "response.fromServiceWorker"),
            .sw_source = str(v, "response.serviceWorkerResponseSource"),
            .charset = charsetOf(ct),
            .prefetch = boolean(v, "response.fromPrefetchCache"),
            .has_extra_info = boolean(v, "hasExtraInfo"),
            .ts_us = cdpMicros(v),
            .low = lowPriority(str(v, "type")),
            .res_kind = resKind(str(v, "type")),
        } };
    }
    if (std.mem.eql(u8, method, "Network.loadingFinished")) return .{ .finished = .{ .rid = rid } };
    if (std.mem.eql(u8, method, "Network.loadingFailed")) return .{ .failed = .{ .rid = rid, .ts_us = cdpMicros(v) } };
    if (std.mem.eql(u8, method, "Network.requestServedFromCache")) return .{ .from_cache = .{ .rid = rid } };
    return null;
}

// ── 표 ────────────────────────────────────────────────────────────────────────────────────────────────────

/// CEF 시작 하나(`body_expected` 로 알린 요청 — 끝은 꼭 하나).
pub const Candidate = struct {
    request: u64,
    key: Key,
    /// IO 스레드의 `on_before_resource_load` 시각(mach µs — CDP `timestamp` 와 같은 시계, J1).
    t_io_us: i64,
    /// 보이는 규칙에 드는 칸(프레임·앞 문서·첫 사이트·initiator)의 해시 — 다른 후보와 다르면 모호하다.
    attr: u64,
    /// 덮이는 호스트인가(설정이 꺼졌을 때 — 리다이렉트마다 다시 정한다). 켜져 있으면 늘 참.
    covered: bool = true,
    /// W9d② 적대 리뷰 1 회차 MED-1(설정이 꺼졌을 때): 응답을 보낸 호스트가 아직 정해지지 않았다 — 시작 호스트로 정한 `covered` 는 덮이는 주소가
    /// 덮이지 않는 호스트로 리다이렉트하면 틀린다. CDP `loadingFinished` 는 그 CEF 응답보다 대개 먼저 오므로(J1 — 10 ms 묶음), CEF 응답
    /// (`cefCovered`)이나 끝(`cefEnd` — 응답 없이 끝났으면 덮이지 않는 쪽)이 오기 전에는 본문을 받으러 가지 않는다. 리다이렉트마다 다시 선다.
    cover_pending: bool = false,
    /// CEF 헤더에 쿠키·인증 헤더가 있었다(ExtraInfo 가 없을 때와 함께 쓴다).
    cef_credentialed: bool = false,
    claimed: bool = false,
    /// CEF 끝을 본 UI 시각(µs, 0 = 아직).
    ended_at: i64 = 0,
    /// W9d② 적대 리뷰 3 회차 P5: CEF 가 그 요청을 실패·취소로 끝냈다(`ended_at` 과 함께 본다) — 성공한 CDP 요청의 짝이 아니고, 렌더러가 먼저
    /// abort 해 CDP 실패보다 늦게 시작한 기록이 abort 한 요청의 것임을 알게 해 준다.
    cef_failed: bool = false,
    /// W9d② 적대 리뷰 4 회차 N1: CEF 끝이 알린 받은 바이트(`net_end.received` — 0 = 없었거나 아직 끝을 보지 못했다). CDP 가 빈 본문을 줘도 이것이
    /// 0 보다 크면 서버는 바이트를 보냈다(`<link rel=prefetch>` — CDP 는 `dataReceived` 없이 빈 글을 줬다): `no_body`(「0 바이트」)가 아니라 `unavailable`.
    cef_received: u64 = 0,
    /// W9d② 적대 리뷰 5 회차 C1: 넘김 상자가 넘쳐 이 요청의 리다이렉트·응답·끝 중 무엇이 버려졌다(`cefLost`) — 끝(`ended_at`)도, 덮이는지도,
    /// 성공했는지도 모른다. 짝이면 `ambiguous`, 짝이 없으면 시한 뒤 `unmatched`(전에는 버려진 끝을 기다리며 끝이 오지 않았다 — maru 는 그 본문을
    /// 늘 `pending` 으로 보였고 주기 task 가 멈추지 않았다).
    lost: bool = false,
    /// 같은 번호로 다시 시작한 시도면 앞 시도의 IO 시각(0 = 첫 시도) — 앞 시도 때 시작한 CDP 요청과 짓지 않는다(`tryDecide`).
    prev_t_io_us: i64 = 0,
    /// 재검증 3 차 N-3: 이 기록을 집었던 판정이 본문 없이 끝났거나 이 기록을 쥘 수 있던 요청이 맞추기에서 빠졌다 — 짝 없이 시한으로 끝나면
    /// `unmatched`(「다른 프로세스 iframe·worker」)가 아니라 `ambiguous` 다(`expireRecords`).
    hint: bool = false,
};

const CdpState = enum { open, finished, failed, cached };

const Cdp = struct {
    rid: Rid,
    key_url: u64,
    key_method: u64,
    ts_us: i64,
    /// 응답의 서비스 워커 갈래(응답 전이면 거짓).
    sw: bool = false,
    /// 응답을 봤다(`sw` 를 안다) — 아직이면 어느 갈래의 맞추기에도 넣는다(W9d② 적대 리뷰 2 회차).
    responded: bool = false,
    /// W9d② 적대 리뷰 4 회차 SW1: 서비스 워커가 준 응답인데 네트워크에서 받은 것이 아니다(`serviceWorkerResponseSource` 가 `network` 가 아니거나
    /// 없다 — Cache Storage·HTTP 캐시·워커가 만든 `new Response`). 서비스 워커 갈래의 CEF 기록은 그 워커 제 fetch 다 — 캐시로 답하며 같은 주소를
    /// 네트워크로 다시 받는 stale-while-revalidate 에서는 그 기록과 페이지가 받은 본문(캐시의 옛것)이 다르다(실제 CEF 38/40 틀림). 그래서 이
    /// 요청은 CEF 가 보지 못한 것으로 친다(메모리 캐시처럼 — 맞추기에 넣지 않고 끝나면 놓는다). 그 워커 기록은 `unmatched` 로 끝난다.
    sw_off_network: bool = false,
    state: CdpState = .open,
    prefetch: bool = false,
    mime: [msg.max_net_mime_bytes]u8 = undefined,
    mime_len: u8 = 0,
    charset: Charset = .none,
    data_bytes: u64 = 0,
    /// ExtraInfo 가 실린 것을 알렸다.
    credentialed: bool = false,
    /// W9d② 적대 리뷰 1 회차 LOW-3: 이 requestId 로 보낸 수(첫 requestWillBeSent·리다이렉트 홉·다시 보내기 — ExtraInfo 는 보낼 때마다 하나다,
    /// CDP `redirectHasExtraInfo`)와 받은 ExtraInfo 수. 받은 수가 보낸 수보다 적으면 어느 홉의 쿠키를 모른다 — 실린 것으로 친다(전에는 ExtraInfo
    /// 하나만 봐도 「모른다」 가 풀려, 뒤 홉의 쿠키가 `loadingFinished` 뒤에 오면 실리지 않은 것이 됐다).
    sends: u8 = 1,
    extras: u8 = 0,
    /// 응답이 ExtraInfo 가 온다고 알렸다(`responseReceived.hasExtraInfo`) — 덜 왔으면 잠시(`extra_grace_us`) 기다릴 값어치가 있다.
    has_extra_info: bool = false,
    /// ExtraInfo 만 온 자리(열쇠 없음)를 잡은 UI 시각 — 시한(`placeholder_expiry_us`)이 지나면 놓는다.
    placed_at: i64 = 0,
    /// 끝(성공·실패)을 본 UI 시각 — 후보를 기다리는 시한의 기준.
    done_at: i64 = 0,
    /// W9d② 적대 리뷰 5 회차 A1: 실패의 시각(CDP `loadingFailed.timestamp` — 응답 시각과 같은 검사로 맞아 보이지 않으면 UI 가 받은 때; 0 = 실패하지
    /// 않았다). UI 가 실패 사건을 받는 때는 abort 보다 늦다 — 렌더러가 abort 와 다시 받기를 한 task 에서 하면 다시 받은 요청의 CEF 시작(IO 시각)이
    /// UI 가 받은 때보다 앞일 수 있다(실제 CEF: UI 시각과의 차 −0.13..+0.04 ms, CDP 시각과의 차 −0.47..−0.18 ms — 93/93). 물 높이의 기준
    /// (`bound`)과 시한에 결과를 모르는 기록을 가르는 데(`tryDecide`) 쓴다.
    failed_at: i64 = 0,
    /// W9d② 적대 리뷰 5 회차 A2: 자원 종류가 기다림의 뒤 차례(`lowPriority` — requestWillBeSent 나 responseReceived 의 `type`).
    low: bool = false,
    /// 재검증 4 차 뒤 B15: 글 풀기가 갈리는 자원 종류(`ResKind` — 응답의 `type` 이 있으면 그것, 없으면 요청의 것).
    res_kind: ResKind = .other,
    /// W9d② 적대 리뷰 3 회차 P1: 응답(`responseReceived`)의 시각(CDP `timestamp` — 맞아 보이지 않으면 UI 가 받은 때; 마지막 다시 시작 뒤 — 0 = 아직). 응답은 요청이 나간 뒤에 오고 요청은 CEF 의
    /// `on_before_resource_load`(제 기록의 IO 시각) 뒤에 나간다 — 그래서 제 CEF 기록의 IO 시각은 이 값보다 앞이다(`bound`).
    responded_at: i64 = 0,
    /// requestWillBeSent 를 봤다(ExtraInfo 가 먼저 와 자리만 잡은 동안 거짓 — 짝을 찾지 않는다).
    has_key: bool = true,
    /// 같은 requestId 로 같은 주소·메서드를 다시 보낸 때(0 = 없었다) — Chromium 이 이 요청을 다시 시작했다(CEF 는 같은 번호로 새 시작을 낸다,
    /// CDP 는 리다이렉트로 알린다 — 판정 `body-restart-same-id` 실측). 본문은 마지막 시도의 것이라 짝은 그때 시작한 CEF 시도와 짓는다.
    restart_ts_us: i64 = 0,
    /// W9d② 적대 리뷰 2 회차 F3: 마지막으로 보낸 홉의 주소 해시 — 다시 시작은 바로 앞 홉과 같은 주소를 다시 보낸 것뿐이다(A → B → A 는 리다이렉트).
    last_url: u64 = 0,
    /// W9d② 적대 리뷰 2 회차: 같은 열쇠의 다른 요청이 CDP 가 보지 못한 후보 때문에 모호하다고 정했고, 그 후보가 이 요청의 창에도 든다 — 이 요청의
    /// 짝도 가를 수 없으니 본문을 붙이지 않는다(`ambiguous`).
    tainted: bool = false,
    /// 재검증 3 차 LB-1: CDP `loaderId` 의 해시(0 = 모른다) — 이 요청을 낸 문서(`Tab.loaders`·`crossesDoc`).
    loader: u64 = 0,
    /// 재검증 3 차 뒤 PF-2: `decidePending` 한 바퀴 안에서 짝 없이 놓았다 — 맞추기·주인 찾기는 건너뛰고 바퀴 끝에 한 번에 지운다(하나씩 지우면
    /// 요청 수천 개의 목록을 그때마다 당겼다).
    gone: bool = false,

    fn key(self: *const Cdp) Key {
        return .{ .url = self.key_url, .method = self.key_method, .sw = self.sw };
    }

    /// 짝을 찾는 기준 시각 — 다시 보냈으면 그때, 아니면 처음 보낸 때.
    fn anchor(self: *const Cdp) i64 {
        return if (self.restart_ts_us != 0) self.restart_ts_us else self.ts_us;
    }

    /// W9d② 적대 리뷰 3 회차 P1: 이 시각까지의 CEF 기록이 모두 오면 제 기록(있다면)도 왔다 — 응답을 봤으면 그때(제 기록은 그보다 앞이다),
    /// 아니면 끝을 본 때(응답 없이 실패한 요청 — 그때까지 시작한 기록이 다 와야 「CEF 에 닿지 않았다」 를 안다). 0 = 아직 모른다(열린 요청).
    /// 다시 시작한 요청은 끝을 본 때다 — 실측(판정 `body-restart-same-id`)에서 새 시도의 CEF 시작이 CDP 의 200 응답 뒤에 왔다(그 짝은 다시
    /// 시작한 CEF 시도뿐이라 — `feasible` — 워커의 기록과 섞이지 않는다).
    /// 응답 없이 실패한 요청은 CDP 의 실패 시각(5 회차 A1 — `failed_at`).
    fn bound(self: *const Cdp) i64 {
        if (self.restart_ts_us != 0) return self.done_at;
        if (self.responded_at != 0) return self.responded_at;
        if (self.failed_at != 0) return self.failed_at;
        return self.done_at;
    }

    fn mimeSlice(self: *const Cdp) []const u8 {
        return self.mime[0..self.mime_len];
    }
};

/// W9d② 최종 재검증 N-a: 짝 없는 후보 하나의 색인 칸(`Table.buildCandIndex` — 끊긴 CDP 자리 훑기).
const CandKey = struct {
    url: u64,
    method: u64,
    sw: bool,
    t_io: i64,
    /// 같은 열쇠 무리에 다시 시작한 시도가 있다(색인을 만든 뒤 무리 전체에 적는다).
    restart: bool = false,

    fn order(a: CandKey, b: CandKey) std.math.Order {
        if (a.url != b.url) return std.math.order(a.url, b.url);
        if (a.method != b.method) return std.math.order(a.method, b.method);
        if (a.sw != b.sw) return if (b.sw) .lt else .gt;
        return std.math.order(a.t_io, b.t_io);
    }

    fn lessThan(_: void, a: CandKey, b: CandKey) bool {
        return order(a, b) == .lt;
    }

    fn sameGroup(a: CandKey, b: CandKey) bool {
        return a.url == b.url and a.method == b.method and a.sw == b.sw;
    }

    /// `key` 보다 작지 않은 첫 자리(정렬된 `items`).
    fn lowerBound(items: []const CandKey, key: CandKey) usize {
        var lo: usize = 0;
        var hi: usize = items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (order(items[mid], key) == .lt) lo = mid + 1 else hi = mid;
        }
        return lo;
    }
};

/// 재검증 2–9 회차 WB: 모든 열쇠를 한 번에 보는 칸(`Table.sortForOwners`) — (주소, 메서드, 서비스 워커 갈래, 시각, 자리) 차례.
const GroupItem = struct {
    url: u64,
    method: u64,
    sw: bool,
    t: i64,
    idx: usize,

    fn group(a: GroupItem, b: GroupItem) std.math.Order {
        if (a.url != b.url) return std.math.order(a.url, b.url);
        if (a.method != b.method) return std.math.order(a.method, b.method);
        if (a.sw != b.sw) return if (b.sw) .lt else .gt;
        return .eq;
    }

    fn lessThan(_: void, a: GroupItem, b: GroupItem) bool {
        return switch (group(a, b)) {
            .lt => true,
            .gt => false,
            .eq => a.t < b.t or (a.t == b.t and a.idx < b.idx),
        };
    }

    /// `key` 보다 작지 않은 첫 자리(정렬된 `items`).
    fn lowerBound(items: []const GroupItem, key: GroupItem) usize {
        var lo: usize = 0;
        var hi: usize = items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (lessThan({}, items[mid], key)) lo = mid + 1 else hi = mid;
        }
        return lo;
    }
};

const Waiting = struct {
    request: u64,
    rid: Rid,
    since: i64,
    bytes: u64,
    mime: [msg.max_net_mime_bytes]u8 = undefined,
    mime_len: u8 = 0,
    charset: Charset,
    credentialed: bool,
    /// 5 회차 A2: 차례가 뒤(`lowPriority`) — 기다림은 앞 차례 모두 뒤에 이것들(차례마다 들어온 차례).
    low: bool = false,
    res_kind: ResKind = .other,
};

/// 보낸 `getResponseBody` 하나.
pub const Inflight = struct {
    id: i32,
    browser: BrowserId,
    session: u32,
    request: u64,
    decoded: u64,
    mime: [msg.max_net_mime_bytes]u8 = undefined,
    mime_len: u8 = 0,
    charset: Charset,
    /// 재검증 4 차 뒤 B15: 글 풀기가 갈리는 자원 종류(`decodeResult`).
    res_kind: ResKind = .other,
    credentialed: bool,
    /// 보낸 UI 시각 — 답이 `fetch_timeout_us` 안에 오지 않으면 `unavailable` 로 끝낸다(W9d② 적대 리뷰 3 회차 S1).
    sent_at: i64 = 0,

    pub fn mimeSlice(self: *const Inflight) []const u8 {
        return self.mime[0..self.mime_len];
    }
};

const DropMark = struct { url: u64, t_us: i64 };

/// 재검증 4 차 뒤 R6: 서비스 워커가 답한 CDP 요청 하나(`Tab.sw_seen` — 주소·메서드 해시와 기준 시각; 주소 0 = 빈 자리).
const SwSeen = struct { url: u64 = 0, method: u64 = 0, at: i64 = 0 };
pub const max_sw_seen: usize = 128;

/// 재검증 3 차 LB-1: 문서 loader 하나와 그 loader 로 보낸 가장 늦은 요청의 기준 시각(`Tab.loaders`).
const LoaderSeen = struct { loader: u64 = 0, last_ts: i64 = 0 };

const Bucket = struct {
    tokens: f64,
    at_us: i64 = 0,

    fn refill(self: *Bucket, rate: f64, burst: f64, now_us: i64) void {
        if (self.at_us == 0) self.at_us = now_us;
        if (now_us > self.at_us) {
            self.tokens = @min(burst, self.tokens + @as(f64, @floatFromInt(now_us - self.at_us)) / 1e6 * rate);
            self.at_us = now_us;
        }
    }
};

pub const Tab = struct {
    browser: BrowserId = 0,
    /// 0 = 기록하지 않는다. maru 가 켤 때 매긴 번호(`net_record.session`).
    session: u32 = 0,
    /// 쏟아짐 밸브가 멈췄다(세션은 그대로 — maru 가 다시 켜야 풀린다).
    paused: bool = false,
    cands: std.ArrayList(Candidate) = .empty,
    cdp: std.ArrayList(Cdp) = .empty,
    waiting: std.ArrayList(Waiting) = .empty,
    inflight: usize = 0,
    drops: [max_drop_marks]DropMark = undefined,
    drop_len: usize = 0,
    drop_next: usize = 0,
    /// 표지가 넘쳤다 — 이 시각까지의 창은 모두 모호하다.
    drop_overflow_until: i64 = 0,
    bodies: Bucket = .{ .tokens = tab_bodies_burst },
    bytes: Bucket = .{ .tokens = tab_bytes_per_s },
    /// 쏟아짐 밸브 — 지금 초의 이벤트 수와 넘은 초가 이어진 수.
    flood_second: i64 = 0,
    flood_count: u32 = 0,
    flood_over: u8 = 0,
    /// W9d② 20 회 검증 N1: 주 프레임에 마지막으로 새 문서가 시작된 UI 시각(µs — `documentStarted`, 0 = 아직). 그보다 앞에 시작했는데 CEF 가
    /// 취소·실패로 끝낸 요청은 앞 문서와 함께 끊긴 것이다 — CDP 는 그 끝을 보내지 않는다(실측 0/34).
    doc_at: i64 = 0,
    /// 재검증 2–9 회차 WB-3: 최근 새 문서 시작 시각들(고리 — `doc_starts_len` 개, 넘치면 가장 오래된 것을 덮는다). 열린 요청과 그것이 쥔 기록
    /// 사이에 문서 경계가 있는가를 본다(`crossesDoc`).
    doc_starts: [max_doc_starts]i64 = @splat(0),
    doc_starts_next: usize = 0,
    /// W9d② 최종 재검증 D-B: CDP 자리 상한의 묶음 놓기(`dropOldestCdp`)가 놓은 요청의 창 끝(기준 시각 + `window_after_us`)을 주소마다(µs —
    /// `cdp_drop_marks`). 놓인 요청의 CEF 기록은 남는다 — 같은 주소의 다른 요청이 그것을 제 짝으로 볼 수 있으니, 창이 여기까지 닿는 같은 주소
    /// 요청은 짝을 지어도 본문을 붙이지 않는다(`ambiguous`). 재검증 2–9 회차 N3: 전에는 탭 전체의 값 하나라 다른 주소의 요청도 2 초 동안
    /// `ambiguous` 였다(4096 묶음 뒤 다른 주소 90 개 중 31). 표지 자리가 차면 그 묶음의 남은 것은 탭 전체의 값(`cdp_drop_until` — 0 = 없다)으로
    /// 접는다(보수적). 줄지 않는다 — 창이 이 값보다 뒤에서 시작하는 요청에는 듣지 않으니 잊을 까닭이 없다. 기록을 다시 켜면(`start`) 비운다(놓인
    /// 요청의 기록도 그때 함께 끝났다).
    cdp_drop_marks: std.ArrayList(DropMark) = .empty,
    cdp_drop_until: i64 = 0,
    /// 재검증 3 차 LB-1: 최근 문서 loader 들(`max_loaders` 개 — 넘치면 가장 오래 보지 못한 것을 덮는다). 새 문서 알림 앞에 보낸 요청이라도 같은
    /// loader 로 알림 뒤에 보낸 요청이 있으면 새 문서의 것이다(`crossesDoc` — 실제 CEF: 새 문서의 첫 요청은 20 번 중 15–19 번 알림보다 0.2–0.6 ms 먼저
    /// 나갔다).
    loaders: [max_loaders]LoaderSeen = @splat(.{}),
    /// 재검증 4 차 뒤 R6: 서비스 워커가 답한 최근 CDP 요청(출처를 가리지 않는다 — 캐시·만든 응답도; 고리 — 넘치면 가장 오래된 것을 덮는다).
    /// 네트워크 밖에서 답한 요청은 끝나면 맞추기 목록에서 빠지지만 그 워커가 같은 주소를 네트워크로 받았을 수 있다(stale-while-revalidate·다시 싸기)
    /// — 그 워커 기록은 「설명되는」 기록이다(`swUnique` 의 셋째 조건). 덮여 잊으면 설명되지 않는 쪽으로 치우친다(본문을 잃을 뿐).
    sw_seen: [max_sw_seen]SwSeen = @splat(.{}),
    sw_seen_next: usize = 0,

    pub fn recording(self: *const Tab) bool {
        return self.session != 0 and !self.paused;
    }

    fn deinit(self: *Tab, gpa: std.mem.Allocator) void {
        self.cdp_drop_marks.deinit(gpa);
        self.cands.deinit(gpa);
        self.cdp.deinit(gpa);
        self.waiting.deinit(gpa);
    }
};

/// 표가 내는 일 — 부른 쪽(`net_body.zig`)이 차례로 한다.
pub const Action = union(enum) {
    /// `getResponseBody` 를 보낸다(`inflight` 에 이미 적었다).
    fetch: struct { browser: BrowserId, id: i32, rid: Rid },
    /// 본문 없이 끝을 보낸다.
    end: struct { browser: BrowserId, session: u32, request: u64, state: State, flags: Flags = .{}, decoded: u64 = 0 },
    /// 쏟아짐 밸브가 그 탭의 기록을 멈췄다 — `Network.disable` 을 보내고 maru 에 알린다.
    pause: struct { browser: BrowserId, session: u32 },
};

pub const Table = struct {
    tabs: [max_tabs]Tab = @splat(.{}),
    inflight: std.ArrayList(Inflight) = .empty,
    next_id: i32 = id_base,
    global_bytes: Bucket = .{ .tokens = global_bytes_per_s },
    actions: std.ArrayList(Action) = .empty,
    /// `tryDecide` 의 맞추기가 다시 쓰는 자리(부를 때마다 할당하지 않는다).
    scratch: Scratch = .{},
    /// W9d② 적대 리뷰 3 회차 P1: CEF 기록이 이 IO 시각까지 모두 왔다(물 높이 — µs). `network.zig` 는 IO 시각을 넘김 상자의 잠금 아래에서 찍어
    /// 상자의 차례가 곧 시각의 차례다 — 그래서 시작 하나가 오면 그보다 앞서 찍힌 것은 모두 왔고(`cefBegin`), 상자가 비었으면 지금까지 모두
    /// 왔다(`cefSeen`·`tickAt`). 상자는 모든 브라우저가 함께 쓰므로 하나다.
    cef_seen_us: i64 = 0,

    const Scratch = struct {
        reqs: std.ArrayList(usize) = .empty,
        cands: std.ArrayList(usize) = .empty,
        left: std.ArrayList(usize) = .empty,
        right: std.ArrayList(usize) = .empty,
        /// 재검증 3 차 WB-4: 기록이 아직 올 수 있는 요청을 뺀 오른쪽 맞추기(`matchRight` 의 `fut`).
        right_fut: std.ArrayList(usize) = .empty,
        /// 재검증 3 차 WB-4: 맞추기 자리마다 제 기록이 아직 올 수 있거나 곧 실패를 알릴 요청인가(`markPending`).
        pend: std.ArrayList(bool) = .empty,
        /// 재검증 3 차 LB-1: 결과를 모르는 기록을 쥔 응답 없이 실패한 요청을 뺀 왼쪽 맞추기(`matchLeftLo` — 가장 이를 수 있는 쪽)와 그 `taken`.
        left_lo: std.ArrayList(usize) = .empty,
        taken_lo: std.ArrayList(bool) = .empty,
        /// 재검증 3 차 LB-1: 그 왼쪽 맞추기에서 요청마다 가져갔을 자리(아무것도 갖지 않은 요청도 — `markRangeOwners` 의 범위 앞 끝).
        lo_pos: std.ArrayList(usize) = .empty,
        /// 재검증 3 차 WB-4: IO 시각 차례 끝의 막 시작한 기록을 1..`young_n` 개 뺀 오른쪽 맞추기(`ensureArrays`).
        right_young: [max_young]std.ArrayList(usize) = @splat(.empty),
        young_n: usize = 0,
        /// 재검증 3 차 PF: `decidePending` 한 바퀴 안에서는 표가 바뀌지 않는 동안 같은 열쇠의 맞추기를 다시 하지 않는다(`ensureArrays` — 같은 주소
        /// 요청 2048 개가 한꺼번에 기다리면 한 바퀴가 기다리는 요청 × 맞추기였다; 판정이 표를 바꾸면 다시 한다).
        cache_on: bool = false,
        cache_valid: bool = false,
        cache_tab: usize = 0,
        cache_key: Key = .{ .url = 0, .method = 0, .sw = false },
        /// 재검증 3 차 뒤 PF-2: `tryDecide` 가 맞추기에서 아무것도 갖지 않은 요청 하나만 뺐다(`t.cdp` 자리 — 짝 없이 시한) — `decidePending` 이
        /// 맞추기를 다시 하지 않고 그 자리만 지운다(`dropBareFromCache`). 아니면 `none`.
        removed_bare: usize = std.math.maxInt(usize),
        /// 재검증 3 차 뒤 PF-2: 왼쪽 짝이 없는(기록이 아직 오지 않은 것으로 보인) 응답 없이 실패하지 않은 요청의 맞추기 자리(차례대로 —
        /// `ensureArrays`) — `tryDecide` 의 `held` 가 「뒤 요청의 기록으로 설명되는가」 를 이것만 훑는다(전에는 뒤 요청을 모두 — 쥔 기록마다).
        unpaired: std.ArrayList(usize) = .empty,
        /// 재검증 3 차 뒤 PF-2: 맞추기를 처음부터 한 수(시험이 값의 꼴을 본다).
        match_runs: u64 = 0,
        extra: std.ArrayList(u64) = .empty,
        /// 5 회차 A1: 왼쪽 맞추기에서 응답 없이 실패한 요청이 집은 후보(후보 자리마다).
        taken: std.ArrayList(bool) = .empty,
        /// 최종 재검증 N-a: 끊긴 CDP 자리 훑기의 짝 없는 후보 색인(열쇠·IO 시각 차례 — `cdpMayPair`).
        index: std.ArrayList(CandKey) = .empty,
        /// 재검증 2–9 회차 WB: 끝내는 기록의 주인일 수 있는 요청 찾기(`sortForOwners`) — 요청·끝낼 후보의 (열쇠, 시각) 칸, 끝낼 후보·놓을 요청의
        /// 표.
        all_reqs: std.ArrayList(GroupItem) = .empty,
        all_cands: std.ArrayList(GroupItem) = .empty,
        drop_cand: std.ArrayList(bool) = .empty,
        drop_cdp: std.ArrayList(bool) = .empty,
        /// 본문 없이 끝낼 기록 자리(`tryDecide` — 모호한 판정의 짝과 사이 후보).
        recs: std.ArrayList(usize) = .empty,
        /// 재검증 4 차 뒤 R19-1: `t.cdp` 자리 → 맞추기 자리(`reqs` — 없으면 `none`). `ensureArrays` 가 만든다 — `tryDecide` 의 `me` 찾기와 맞추기
        /// 나눠 쓰기의 확인이 요청마다 `reqs` 를 훑었다(같은 주소 N 개가 `split_wait_us` 2 s 를 기다리면 주기마다 O(N²)).
        pos_of: std.ArrayList(usize) = .empty,
        /// 재검증 4 차 뒤 R19-1: CEF 끝이 아직인(`definite` 아님) 기록을 왼쪽 짝으로 쥔 응답 없이 실패한 요청의 맞추기 자리(차례대로) — `held` 가
        /// 이것만 훑는다(대개 비었다; 전에는 요청마다 `reqs` 전체).
        bare_held: std.ArrayList(usize) = .empty,
        /// 재검증 4 차 뒤 R19-1: 새 문서를 건너 남의 기록을 쥔 열린 앞 문서 요청(`tryDecide` 의 WB-3 빼기)의 가장 앞 맞추기 자리(`none` = 없다).
        first_cross: usize = std.math.maxInt(usize),
        /// 재검증 4 차 뒤 R6: 서비스 워커 갈래의 짝이 유일하지 않을 때 함께 끝낼 기록 자리(`t.cands`).
        sw_recs: std.ArrayList(usize) = .empty,

        fn deinit(self: *Scratch, gpa: std.mem.Allocator) void {
            self.all_reqs.deinit(gpa);
            self.all_cands.deinit(gpa);
            self.drop_cand.deinit(gpa);
            self.drop_cdp.deinit(gpa);
            self.recs.deinit(gpa);
            self.pos_of.deinit(gpa);
            self.bare_held.deinit(gpa);
            self.sw_recs.deinit(gpa);
            self.index.deinit(gpa);
            self.taken.deinit(gpa);
            self.reqs.deinit(gpa);
            self.cands.deinit(gpa);
            self.left.deinit(gpa);
            self.right.deinit(gpa);
            self.right_fut.deinit(gpa);
            self.left_lo.deinit(gpa);
            self.lo_pos.deinit(gpa);
            for (&self.right_young) |*a| a.deinit(gpa);
            self.pend.deinit(gpa);
            self.unpaired.deinit(gpa);
            self.taken_lo.deinit(gpa);
            self.extra.deinit(gpa);
        }
    };

    pub fn deinit(self: *Table, gpa: std.mem.Allocator) void {
        for (&self.tabs) |*t| t.deinit(gpa);
        self.inflight.deinit(gpa);
        self.actions.deinit(gpa);
        self.scratch.deinit(gpa);
    }

    pub fn tabOf(self: *Table, browser: BrowserId) ?*Tab {
        if (browser == 0) return null;
        for (&self.tabs) |*t| if (t.browser == browser) return t;
        return null;
    }

    pub fn recording(self: *Table, browser: BrowserId) bool {
        const t = self.tabOf(browser) orelse return false;
        return t.recording();
    }

    /// 어느 탭이든 기록하는가(IO 스레드의 값싼 판단에 쓰는 값을 부른 쪽이 원자 변수로 옮긴다).
    pub fn anyRecording(self: *const Table) bool {
        for (&self.tabs) |*t| if (t.browser != 0 and t.recording()) return true;
        return false;
    }

    fn emit(self: *Table, gpa: std.mem.Allocator, a: Action) std.mem.Allocator.Error!void {
        try self.actions.append(gpa, a);
    }

    /// 쌓인 일을 `out`(빈 목록)과 바꿔 가져간다 — 일을 하는 동안 표가 새 일을 쌓아도 가져간 목록은 그대로다(부른 쪽이 비우고 다시 부른다).
    pub fn swapActions(self: *Table, out: *std.ArrayList(Action)) void {
        std.debug.assert(out.items.len == 0);
        std.mem.swap(std.ArrayList(Action), &self.actions, out);
    }

    // ── 켜고 끄기 ──────────────────────────────────────────────────────────────────────────────────────────

    /// `net_record` 켬 — 자리를 잡고 세션을 적는다. 이미 켜져 있으면 앞 세션의 것을 `recording_stopped` 로 끝내고 새 세션으로. 자리가 없으면 거짓.
    pub fn start(self: *Table, gpa: std.mem.Allocator, browser: BrowserId, session: u32) std.mem.Allocator.Error!bool {
        if (session == 0) return false;
        if (self.tabOf(browser)) |t| {
            try self.finishAll(gpa, t, .recording_stopped);
            t.session = session;
            t.paused = false;
            t.flood_over = 0;
            // 재검증 2–9 회차 N3: 놓인 요청의 기록은 방금 함께 끝났다 — 그 표지도 비운다.
            t.cdp_drop_marks.clearRetainingCapacity();
            t.cdp_drop_until = 0;
            return true;
        }
        for (&self.tabs) |*t| if (t.browser == 0) {
            t.* = .{ .browser = browser, .session = session };
            return true;
        };
        return false;
    }

    /// `net_record` 끔 — 기다리던 것·짝이 없는 것 모두 `recording_stopped`, 보낸 호출의 늦은 결과는 버린다(세대 — J6: disable 의 답이 2.8 초
    /// 늦을 수 있다).
    pub fn stop(self: *Table, gpa: std.mem.Allocator, browser: BrowserId) std.mem.Allocator.Error!void {
        const t = self.tabOf(browser) orelse return;
        try self.finishAll(gpa, t, .recording_stopped);
        t.deinit(gpa);
        t.* = .{};
    }

    /// 렌더러가 죽었다(J5 — 보낸 호출은 다음 이동까지 답이 없다): 그 탭의 것을 모두 `detached` 로 끝낸다. 기록은 그대로다(다시 켜지 않아도
    /// 이벤트가 이어진다 — J5).
    pub fn rendererGone(self: *Table, gpa: std.mem.Allocator, browser: BrowserId) std.mem.Allocator.Error!void {
        const t = self.tabOf(browser) orelse return;
        try self.finishAll(gpa, t, .detached);
    }

    /// 브라우저가 닫힌다 — `detached` 로 끝내고 자리를 비운다.
    pub fn closed(self: *Table, gpa: std.mem.Allocator, browser: BrowserId) std.mem.Allocator.Error!void {
        const t = self.tabOf(browser) orelse return;
        try self.finishAll(gpa, t, .detached);
        t.deinit(gpa);
        t.* = .{};
    }

    /// 그 탭의 기다림·보낸 호출·후보를 모두 `state` 로 끝낸다(끝은 후보마다 하나 — 보낸 호출의 후보는 그 호출이 끝낸다).
    fn finishAll(self: *Table, gpa: std.mem.Allocator, t: *Tab, state: State) std.mem.Allocator.Error!void {
        var i: usize = 0;
        while (i < self.inflight.items.len) {
            const f = self.inflight.items[i];
            if (f.browser != t.browser) {
                i += 1;
                continue;
            }
            try self.emit(gpa, .{ .end = .{ .browser = t.browser, .session = f.session, .request = f.request, .state = state } });
            _ = self.inflight.swapRemove(i);
            t.inflight -|= 1;
        }
        for (t.waiting.items) |w| try self.emit(gpa, .{ .end = .{ .browser = t.browser, .session = t.session, .request = w.request, .state = state } });
        t.waiting.clearRetainingCapacity();
        for (t.cands.items) |c| if (!c.claimed) try self.emit(gpa, .{ .end = .{ .browser = t.browser, .session = t.session, .request = c.request, .state = state } });
        t.cands.clearRetainingCapacity();
        t.cdp.clearRetainingCapacity();
        t.inflight = 0;
    }

    // ── CEF 쪽(UI 스레드의 보내는 task) ──────────────────────────────────────────────────────────────────────

    /// 기록하는 탭의 CEF 시작 하나를 후보로 적는다 — 적었으면 참(그 요청의 `net_begin` 에 `body_expected` 를 세운다 — 끝은 꼭 하나).
    /// 같은 번호의 후보가 있으면 다시 시작이다(`restartCand` — 앞 시도의 끝을 여기서 낸다: 부른 쪽은 이 시작의 `net_begin` 보다 먼저 보낸다).
    pub fn cefBegin(self: *Table, gpa: std.mem.Allocator, browser: BrowserId, c: Candidate) std.mem.Allocator.Error!bool {
        // 물 높이 — 이 시작보다 앞서 찍힌 시작은 모두 왔다(상자의 차례 — `cef_seen_us`). 기록하지 않는 탭의 시작도 같은 상자로 온다.
        self.cef_seen_us = @max(self.cef_seen_us, c.t_io_us);
        const t = self.tabOf(browser) orelse return false;
        if (!t.recording()) return false;
        var prev: i64 = 0;
        for (t.cands.items, 0..) |e, i| if (e.request == c.request) {
            prev = e.t_io_us;
            try self.restartCand(gpa, t, i);
            break;
        };
        if (t.cands.items.len >= max_candidates) {
            // 가장 오래된 것을 놓는다 — 짝이 있으면(가져갈 본문이 있다) 남기고 짝 없는 것부터.
            const victim = for (t.cands.items, 0..) |e, i| {
                if (!e.claimed) break i;
            } else return false;
            // 재검증 2–9 회차 WB: 그 기록의 주인일 수 있는 CDP 요청도 맞추기에서 뺀다(`expireRecords` 의 규칙 — 기록만 지우면 주인이 다음 기록을
            // 가져간다). 그 요청의 끝은 이 `busy` 다(제 기록이 따로 있었으면 그 기록은 짝 없는 시한으로 끝난다).
            try self.retireOwnersOf(gpa, t, &.{victim});
            try self.emit(gpa, .{ .end = .{ .browser = browser, .session = t.session, .request = t.cands.items[victim].request, .state = .busy } });
            _ = t.cands.orderedRemove(victim);
            self.dropRetired(t);
        }
        var cand = c;
        cand.claimed = false;
        cand.ended_at = 0;
        cand.prev_t_io_us = prev;
        try t.cands.append(gpa, cand);
        return true;
    }

    /// W9d① 적대 리뷰 후 × W9d②: CEF 가 같은 번호로 다시 시작했다(Critical-CH — W9d① 이 앞 기록을 `restarted` 로 끝낸다). 앞 시도의 후보를
    /// 어디에 있든(짝 없음·자리 기다림·보낸 호출) 지금 `restarted` 로 끝낸다 — maru 는 본문 frame 을 그 번호의 가장 새 기록에 붙이므로 앞 시도의
    /// 끝이 새 시작 뒤로 가면 새 기록에 붙는다. 보낸 호출은 목록에서 빼 늦은 답을 버린다(`takeInflight` 가 못 찾는다). 한 번호의 후보는 늘 하나다.
    fn restartCand(self: *Table, gpa: std.mem.Allocator, t: *Tab, i: usize) std.mem.Allocator.Error!void {
        const old = t.cands.items[i];
        for (t.waiting.items, 0..) |w, wi| if (w.request == old.request) {
            _ = t.waiting.orderedRemove(wi);
            break;
        };
        for (self.inflight.items, 0..) |f, fi| if (f.browser == t.browser and f.request == old.request) {
            _ = self.inflight.swapRemove(fi);
            t.inflight -|= 1;
            break;
        };
        try self.emit(gpa, .{ .end = .{ .browser = t.browser, .session = t.session, .request = old.request, .state = .restarted } });
        _ = t.cands.orderedRemove(i);
    }

    /// CEF 리다이렉트 — 설정이 꺼졌을 때(`pending`) 응답을 보낼 호스트가 바뀐다: 다음 CEF 응답(또는 끝)이 올 때까지 본문을 받으러 가지 않는다
    /// (W9d② 적대 리뷰 1 회차 MED-1).
    pub fn cefRedirect(self: *Table, browser: BrowserId, request: u64, pending: bool) void {
        if (!pending) return;
        const t = self.tabOf(browser) orelse return;
        for (t.cands.items) |*c| if (c.request == request) {
            c.cover_pending = true;
        };
    }

    /// CEF 응답 — 설정이 꺼졌을 때 응답을 보낸 호스트가 덮이는가(`net_response` 의 헤더를 덜어 낼지와 같은 결정 — 리다이렉트 뒤의 호스트다).
    /// 이것으로 응답 호스트가 정해진다(`cover_pending` 이 풀린다).
    pub fn cefCovered(self: *Table, browser: BrowserId, request: u64, covered: bool) void {
        const t = self.tabOf(browser) orelse return;
        for (t.cands.items) |*c| if (c.request == request) {
            c.covered = covered;
            c.cover_pending = false;
        };
    }

    /// CEF 끝(성공) — 짝이 없으면 시한 뒤 `unmatched`. 응답 호스트가 정해지지 않은 채 끝났으면(응답 없이 끝났다) 덮이지 않는 쪽으로 정한다(MED-1).
    pub fn cefEnd(self: *Table, browser: BrowserId, request: u64, now_us: i64) void {
        self.cefEndAs(browser, request, now_us, true);
    }

    /// CEF 끝 — `ok` 는 CEF 가 성공으로 끝냈는가(취소·실패면 거짓 — W9d② 적대 리뷰 3 회차 P5: 성공한 CDP 요청의 짝이 아니다).
    pub fn cefEndAs(self: *Table, browser: BrowserId, request: u64, now_us: i64, ok: bool) void {
        self.cefEndReceived(browser, request, now_us, ok, 0);
    }

    /// CEF 끝과 받은 바이트(`received` — W9d② 적대 리뷰 4 회차 N1: CDP 의 빈 본문이 정말 0 바이트였는가를 가른다, `emptyBodyState`).
    pub fn cefEndReceived(self: *Table, browser: BrowserId, request: u64, now_us: i64, ok: bool, received: u64) void {
        const t = self.tabOf(browser) orelse return;
        for (t.cands.items) |*c| if (c.request == request and c.ended_at == 0) {
            c.ended_at = @max(now_us, 1);
            c.cef_failed = !ok;
            c.cef_received = received;
            if (c.cover_pending) {
                c.cover_pending = false;
                c.covered = false;
            }
        };
    }

    /// 문이 그 탭의 요청을 넘겼다(IO 시각·주소 해시) — 그 창 안의 같은 주소 짝은 모호하다.
    pub fn noteDrop(self: *Table, browser: BrowserId, url_hash: u64, t_us: i64) void {
        const t = self.tabOf(browser) orelse return;
        if (!t.recording()) return;
        if (t.drop_len == max_drop_marks) {
            // 덮어쓰기 전에 가장 오래된 표지의 시각까지 모두 모호하게 둔다 — 잊은 표지가 짝을 맞게 보이게 하지 않는다.
            t.drop_overflow_until = @max(t.drop_overflow_until, t.drops[t.drop_next].t_us);
        } else t.drop_len += 1;
        t.drops[t.drop_next] = .{ .url = url_hash, .t_us = t_us };
        t.drop_next = (t.drop_next + 1) % max_drop_marks;
    }

    /// 표지를 남길 자리가 없었다(IO 스레드의 상자가 찼다) — 이 시각까지의 창은 모두 모호하다.
    pub fn noteDropOverflow(self: *Table, browser: BrowserId, t_us: i64) void {
        const t = self.tabOf(browser) orelse return;
        t.drop_overflow_until = @max(t.drop_overflow_until, t_us);
    }

    /// W9d② 적대 리뷰 5 회차 C1: 넘김 상자가 넘쳐 이 요청의 시작 아닌 기록(리다이렉트·응답·끝)이 버려졌다 — 짝이 없는 후보면 끝난 것으로 치고
    /// (`ended_at` — 시한 뒤 `unmatched`) 표지를 단다(짝이 되면 `ambiguous`). 짝을 지어 받으러 간 후보는 표지를 보지 않는다(본문 호출이 끝을
    /// 낸다 — 시한·짝·덮임은 짝 없는 후보에만 쓰인다).
    pub fn cefLost(self: *Table, browser: BrowserId, request: u64, now_us: i64) void {
        const t = self.tabOf(browser) orelse return;
        for (t.cands.items) |*c| if (c.request == request) markLost(c, now_us);
    }

    /// 표지를 남길 자리도 없었다 — 그 탭의 후보 모두(어느 요청의 것이 버려졌는지 모른다).
    pub fn cefLostAll(self: *Table, browser: BrowserId, now_us: i64) void {
        const t = self.tabOf(browser) orelse return;
        for (t.cands.items) |*c| markLost(c, now_us);
    }

    /// W9d② 20 회 검증 N1: 주 프레임에 새 문서가 시작됐다(`on_load_start`·오류 페이지 — `network.documentStarted`). 앞 문서의 진행 중 요청은
    /// CDP 끝(`loadingFinished`·`loadingFailed`)이 오지 않는다(판정 `v20a-r9-navigation-pending`: 끊긴 34 개 중 0) — 그런 후보는 `tickAt` 이
    /// `unavailable` 로 끝낸다(본문이 사라졌다 — J4; 전에는 짝 없는 시한 뒤 `unmatched` 라 「다른 프로세스·worker 의 요청」 처럼 보였다).
    pub fn documentStarted(self: *Table, browser: BrowserId, now_us: i64) void {
        const t = self.tabOf(browser) orelse return;
        t.doc_at = @max(now_us, 1);
        t.doc_starts[t.doc_starts_next] = t.doc_at;
        t.doc_starts_next = (t.doc_starts_next + 1) % max_doc_starts;
    }

    /// 재검증 2–9 회차 WB-3: 요청 `o`(기준 시각)와 그것이 쥔 기록의 IO 시각 `to` 사이에 새 문서가 시작했는가 — 그 요청은 앞 문서의 것인데 쥔
    /// 기록은 새 문서의 것이다. 새 문서 알림(`on_load_start`)은 문서가 실제로 바뀐 때보다 늦어 새 문서의 첫 기록이 알림보다 먼저 시작할 수
    /// 있다 — 기록의 경계를 알림 앞 `window_before_us` 까지 넓게 본다(요청은 알림 앞, 기록은 그 넓힌 경계 뒤).
    ///
    /// 재검증 3 차 LB-1: 요청이 알림 앞에 나갔어도 새 문서의 것일 수 있다(실제 CEF: 새 문서의 첫 요청이 20 번 중 15–19 번 알림보다 0.2–0.6 ms 먼저
    /// 나갔고 그 IO 는 알림 뒤였다 — 이 요청을 앞 문서의 것으로 보아 같은 주소의 뒤 요청이 본문을 잃었다, 판정 `v20h-h9nsearly` 30/60). 시각으로는
    /// 가르지 못하니 CDP `loaderId` 로 가른다: 같은 loader 로 알림 뒤에 보낸 요청이 있으면 그 요청은 새 문서의 것이다(`Tab.loaders` — 앞 문서는 새
    /// 문서가 들어선 뒤 요청을 내지 못한다; 앞 문서의 같은 프로세스 iframe 은 제 loader 라 주 프레임의 앞 문서 요청을 가리지 않는다). loader 를
    /// 모르거나(worker 의 요청·자리만 잡은 것) 알림 뒤에 같은 loader 의 요청이 아직 없으면 전처럼 시각으로 본다(본문을 잃는 쪽).
    fn crossesDoc(t: *const Tab, o: *const Cdp, to: i64) bool {
        const from = o.anchor();
        for (t.doc_starts) |d| if (d != 0 and from < d and d - window_before_us <= to and !loaderAfter(t, o.loader, d)) return true;
        return false;
    }

    /// 재검증 3 차 LB-1: `loader`(0 이 아닌 것)로 시각 `d` 뒤(같음 포함)에 보낸 요청을 봤는가.
    fn loaderAfter(t: *const Tab, loader: u64, d: i64) bool {
        if (loader == 0) return false;
        for (t.loaders) |l| if (l.loader == loader) return l.last_ts >= d;
        return false;
    }

    /// 재검증 3 차 LB-1: 요청 하나의 loader 를 적는다(그 loader 의 가장 늦은 기준 시각) — 자리가 없으면 가장 오래 보지 못한 것을 덮는다.
    fn noteLoader(t: *Tab, loader: u64, ts_us: i64) void {
        if (loader == 0) return;
        var oldest: usize = 0;
        for (&t.loaders, 0..) |*l, k| {
            if (l.loader == loader) {
                l.last_ts = @max(l.last_ts, ts_us);
                return;
            }
            if (l.last_ts < t.loaders[oldest].last_ts) oldest = k;
        }
        t.loaders[oldest] = .{ .loader = loader, .last_ts = ts_us };
    }

    fn markLost(c: *Candidate, now_us: i64) void {
        c.lost = true;
        if (c.ended_at == 0) c.ended_at = @max(now_us, 1);
        // 덮이는지 모른다 — 설정이 꺼졌을 때 응답 호스트를 기다리던 것은 덮이지 않는 쪽(MED-1 과 같은 쪽).
        if (c.cover_pending) {
            c.cover_pending = false;
            c.covered = false;
        }
    }

    // ── CDP 쪽 ──────────────────────────────────────────────────────────────────────────────────────────────

    /// 같은 requestId 로 다시 보낸 것이 Chromium 의 다시 시작인가(CEF 는 같은 번호로 새 시작을 낸다) — 첫 주소·메서드를 **바로 앞 홉과 같은 주소로**
    /// 다시 보냈다. W9d② 적대 리뷰 2 회차 F3: A → B → A 로 돌아온 리다이렉트는 한 CEF 요청 안의 홉이다(새 시작이 없다) — 그것을 다시 시작으로
    /// 치면 기준 시각이 옮겨져 이 요청의 CEF 기록은 창 밖이 되고 그 뒤에 시작한 같은 주소의 다른 요청 기록이 이 요청의 본문을 받았다. 리다이렉트
    /// 응답의 상태로는 가르지 못한다 — 실측(판정 `body-restart-same-id`, 실제 CEF 154)에서 Critical-CH 다시 시작도 307 이었다. 그래서 제 주소로의
    /// 3xx 는 여전히 다시 시작으로 보이고, 다시 시작한 CDP 요청은 다시 시작한 CEF 시도와만 짓는다(`feasible`) — 그 요청의 본문은 `unmatched` 이지
    /// 다른 기록에 붙지 않는다.
    fn isRestart(r: *const Cdp, url_hash: u64, method_hash: u64) bool {
        return url_hash == r.key_url and method_hash == r.key_method and r.last_url == r.key_url;
    }

    /// 자리가 찼다 — 가장 오래된 `cdp_evict_batch` 개를 한꺼번에 놓는다(D3 — 한 번 미는 값을 그 수만큼의 요청이 나눠 낸다).
    /// W9d② 최종 재검증 D-B: 놓인 것 가운데 아직 짝을 기다리던 요청(맨 앞이 아니어도 — 묶음은 살아 있는 요청도 놓는다)의 CEF 기록은 남는다. 같은
    /// 열쇠의 다른 요청이 제 기록을 잃었으면(후보 상한의 `busy`) 두 맞추기가 모두 그 남은 기록을 줘 다른 요청의 본문이 그 기록에 붙었다(검증 R8-1).
    /// 그래서 놓인 요청의 창 끝까지를 적어 두고(`Tab.cdp_drop_until`) 창이 거기에 닿는 요청은 본문을 붙이지 않는다 — 놓인 요청의 기록은 그
    /// 요청의 창 안에 있으니, 그 기록을 짝으로 볼 수 있는 요청은 모두 창이 그 끝 앞에서 시작한다. 값은 묶음마다 한 번 훑어(O(묶음)) 정한다.
    /// CEF 가 보지 못한 요청(메모리 캐시·미리 받기·네트워크 밖의 서비스 워커 응답)과 자리만 잡은 것은 기록이 없어 적지 않는다.
    ///
    /// 재검증 3 차 N-1: 표지는 그 주소의 요청 창이 그 값에 닿을 때만 듣는다 — 남는 요청(놓지 않은 것)의 가장 이른 기준 시각과 지금 보낸 요청의
    /// 시각(`ts_us` — CDP 의 시각은 앞으로만 간다) 중 이른 것보다 창 앞(5 ms)만큼도 앞인 표지는 어느 창에도 들 수 없어 지운다. 전에는 지우지 않아
    /// 첫 묶음(256 개 주소)이 자리를 다 채운 뒤의 묶음은 모두 탭 전체로 접혔다.
    fn dropOldestCdp(gpa: std.mem.Allocator, t: *Tab, ts_us: i64) void {
        const n = @min(cdp_evict_batch, t.cdp.items.len);
        var floor = ts_us;
        for (t.cdp.items[n..]) |*o| if (o.has_key) {
            floor = @min(floor, o.anchor());
        };
        var kept: usize = 0;
        for (t.cdp_drop_marks.items) |m| if (m.t_us + window_before_us >= floor) {
            t.cdp_drop_marks.items[kept] = m;
            kept += 1;
        };
        t.cdp_drop_marks.shrinkRetainingCapacity(kept);
        if (t.cdp_drop_until != 0 and t.cdp_drop_until + window_before_us < floor) t.cdp_drop_until = 0;
        for (t.cdp.items[0..n]) |*o| if (o.has_key and o.state != .cached and !o.prefetch and !o.sw_off_network) {
            const until = o.anchor() + window_after_us;
            const mark = for (t.cdp_drop_marks.items) |*m| {
                if (m.url == o.key_url) break m;
            } else null;
            if (mark) |m| {
                m.t_us = @max(m.t_us, until);
            } else if (t.cdp_drop_marks.items.len < max_cdp_drop_marks) {
                t.cdp_drop_marks.append(gpa, .{ .url = o.key_url, .t_us = until }) catch {
                    t.cdp_drop_until = @max(t.cdp_drop_until, until); // 자리를 못 잡으면 탭 전체로(보수적)
                };
            } else t.cdp_drop_until = @max(t.cdp_drop_until, until);
        };
        t.cdp.replaceRangeAssumeCapacity(0, n, &.{});
    }

    /// W9d② 20 회 검증 D3: 끝이 영영 오지 않을 열린 CDP 요청인가 — 주 프레임이 옮기면 앞 문서의 요청은 CDP 끝 없이 사라진다(실측 0/34). 그런 자리가
    /// 남으면 `busy` 가 늘 참이라 50 ms 주기 task 가 멈추지 않았고, 4096 개까지 쌓였다. 놓아도 되는 것은 **짝이 될 수 없는** 것뿐이다:
    ///   - 창이 지났다 — 기준 시각 + `window_after_us` 까지의 CEF 시작이 모두 왔다(물 높이). 그 뒤의 시작은 이 요청의 창 밖이다(`cdpWindowPassed`).
    ///   - 짝일 수 있는 후보가 없다 — 같은 열쇠의 짝 없는 후보가 창 안에 없고, 다시 시작한 시도(앞 IO 시각이 있다 — CDP 의 다시 보내기가
    ///     기준 시각을 옮길 수 있다)도 없다(`cdpMayPair`).
    /// 그런 요청은 맞추기에서 아무 후보도 받지 못해 다른 요청의 차례를 밀지 않는다(`tryDecide` 의 왼쪽·오른쪽 맞추기가 건너뛴다) — 놓아도 다른
    /// 요청의 짝이 바뀌지 않는다. 그 요청이 늦게라도 끝나면 자리가 없어 그 끝을 버린다(짝이 없었으니 본문도 없었다).
    fn cdpWindowPassed(self: *const Table, o: *const Cdp, now_us: i64) bool {
        if (!o.has_key or (o.state != .open and o.state != .cached)) return false; // 자리만·끝난 것은 제 시한이 있다
        const ts = o.anchor();
        return now_us - ts > window_after_us and self.cef_seen_us > ts + window_after_us;
    }

    /// 최종 재검증 N-a: 짝 없는 후보의 색인을 만든다 — (열쇠, IO 시각) 차례, 같은 열쇠 무리에 다시 시작한 시도가 있는가를 무리마다 적는다.
    /// 전에는 열린 CDP 요청마다 후보를 모두 훑었다(O(요청 × 후보) — 4095 개씩이면 50 ms 주기마다 ReleaseFast 4.9 ms·Debug 48 ms). 이제 색인
    /// 하나(O(후보 log 후보))와 요청마다 두 번의 이분 찾기다.
    fn buildCandIndex(self: *Table, gpa: std.mem.Allocator, t: *const Tab) std.mem.Allocator.Error!void {
        const ix = &self.scratch.index;
        ix.clearRetainingCapacity();
        for (t.cands.items) |c| if (!c.claimed) try ix.append(gpa, .{ .url = c.key.url, .method = c.key.method, .sw = c.key.sw, .t_io = c.t_io_us, .restart = c.prev_t_io_us != 0 });
        std.mem.sort(CandKey, ix.items, {}, CandKey.lessThan);
        var g: usize = 0;
        while (g < ix.items.len) {
            var e = g;
            var restart = false;
            while (e < ix.items.len and ix.items[e].sameGroup(ix.items[g])) : (e += 1) restart = restart or ix.items[e].restart;
            for (ix.items[g..e]) |*k| k.restart = restart;
            g = e;
        }
    }

    /// `buildCandIndex` 의 색인에서 `o` 의 짝일 수 있는 후보가 있는가 — 같은 열쇠(응답을 봤으면 그 서비스 워커 갈래만)의 다시 시작한 시도,
    /// 또는 창 `[기준 − window_before_us, 기준 + window_after_us]` 안의 IO 시각.
    fn cdpMayPair(self: *const Table, o: *const Cdp) bool {
        const ix = self.scratch.index.items;
        const ts = o.anchor();
        for ([_]bool{ false, true }) |sw| {
            if (o.responded and sw != o.sw) continue;
            const head = CandKey.lowerBound(ix, .{ .url = o.key_url, .method = o.key_method, .sw = sw, .t_io = std.math.minInt(i64) });
            if (head == ix.len or ix[head].url != o.key_url or ix[head].method != o.key_method or ix[head].sw != sw) continue;
            if (ix[head].restart) return true;
            const at = CandKey.lowerBound(ix, .{ .url = o.key_url, .method = o.key_method, .sw = sw, .t_io = ts - window_before_us });
            if (at < ix.len and ix[at].sameGroup(ix[head]) and ix[at].t_io <= ts + window_after_us) return true;
        }
        return false;
    }

    fn cdpIndex(t: *Tab, rid: []const u8) ?usize {
        var i = t.cdp.items.len;
        while (i > 0) {
            i -= 1;
            if (t.cdp.items[i].rid.eql(rid)) return i;
        }
        return null;
    }

    /// 쏟아짐 밸브 — 이 이벤트로 그 탭을 멈추면 참.
    fn floodCheck(self: *Table, gpa: std.mem.Allocator, t: *Tab, now_us: i64) std.mem.Allocator.Error!bool {
        const second = @divFloor(now_us, 1_000_000);
        if (second != t.flood_second) {
            // 바로 앞 초가 넘었으면 이어진 수를 늘리고, 아니면(넘지 않았거나 초를 건너뛰었다) 다시 센다.
            t.flood_over = if (second == t.flood_second + 1 and t.flood_count > flood_events_per_s) t.flood_over +| 1 else 0;
            t.flood_second = second;
            t.flood_count = 0;
        }
        t.flood_count += 1;
        if (t.flood_count == flood_events_per_s + 1 and t.flood_over + 1 >= flood_seconds) {
            try self.finishAll(gpa, t, .recording_stopped);
            t.paused = true;
            try self.emit(gpa, .{ .pause = .{ .browser = t.browser, .session = t.session } });
            return true;
        }
        return false;
    }

    /// CDP `Network.*` 사건 하나(`now_us` 는 UI 시각). 메서드를 표가 쓰지 않아도 쏟아짐을 세려고 부른다(`ev` 가 null).
    pub fn cdpEvent(self: *Table, gpa: std.mem.Allocator, browser: BrowserId, ev: ?Event, now_us: i64) std.mem.Allocator.Error!void {
        const t = self.tabOf(browser) orelse return;
        if (!t.recording()) return;
        if (try self.floodCheck(gpa, t, now_us)) return;
        const e = ev orelse return;
        switch (e) {
            .will_be_sent => |v| {
                if (cdpIndex(t, v.rid)) |i| {
                    // ExtraInfo 가 먼저 와 자리만 있던 요청이면 열쇠를 채운다. 아니면 리다이렉트 홉 — 열쇠는 첫 주소의 것.
                    const r = &t.cdp.items[i];
                    if (!r.has_key and !v.redirect) {
                        r.key_url = v.url_hash;
                        r.key_method = v.method_hash;
                        r.ts_us = v.ts_us;
                        r.has_key = true;
                        r.prefetch = r.prefetch or v.prefetch;
                        r.low = r.low or v.low;
                        r.res_kind = v.res_kind;
                        r.sends = 1;
                        r.last_url = v.url_hash;
                        r.loader = v.loader;
                        noteLoader(t, v.loader, v.ts_us);
                    } else if (r.has_key) {
                        // 다시 보냈다(리다이렉트 홉·다시 시작) — 그 홉의 ExtraInfo 가 하나 더 온다(LOW-3).
                        r.sends +|= 1;
                        if (isRestart(r, v.url_hash, v.method_hash)) {
                            // 같은 주소를 다시 보냈다 — 다시 시작(실측: Critical-CH 의 403 뒤 307 리다이렉트로 알린다). 받은 바이트는 앞 시도의 것.
                            r.restart_ts_us = v.ts_us;
                            r.data_bytes = 0;
                        }
                        r.last_url = v.url_hash;
                    }
                    return;
                }
                if (v.redirect) return; // 첫 홉을 못 봤다 — 옮겨 간 주소는 CEF 의 열쇠(첫 주소)가 아니다
                const rid = Rid.init(v.rid) orelse return;
                if (t.cdp.items.len >= max_cdp) dropOldestCdp(gpa, t, v.ts_us);
                noteLoader(t, v.loader, v.ts_us);
                try t.cdp.append(gpa, .{ .rid = rid, .key_url = v.url_hash, .key_method = v.method_hash, .ts_us = v.ts_us, .prefetch = v.prefetch, .has_key = true, .last_url = v.url_hash, .low = v.low, .loader = v.loader, .res_kind = v.res_kind });
            },
            .extra_info => |v| {
                const i = cdpIndex(t, v.rid) orelse blk: {
                    // ExtraInfo 가 requestWillBeSent 보다 먼저 올 수 있다 — 자리를 먼저 잡는다(열쇠는 requestWillBeSent 가 채운다, 그 전에는
                    // 어느 후보와도 맞지 않는다). 이미 정한 요청의 늦은 ExtraInfo 도 여기로 온다 — 그 자리는 시한(`tick`)과 수(`max_placeholders`)로
                    // 놓는다(W9d② 적대 리뷰 1 회차 LOW-3).
                    const rid = Rid.init(v.rid) orelse return;
                    var placeholders: usize = 0;
                    var oldest: ?usize = null;
                    for (t.cdp.items, 0..) |o, j| if (!o.has_key) {
                        placeholders += 1;
                        if (oldest == null) oldest = j;
                    };
                    if (placeholders >= max_placeholders) _ = t.cdp.orderedRemove(oldest.?) else if (t.cdp.items.len >= max_cdp) dropOldestCdp(gpa, t, now_us);
                    try t.cdp.append(gpa, .{ .rid = rid, .key_url = 0, .key_method = 0, .ts_us = std.math.maxInt(i64), .has_key = false, .sends = 0, .placed_at = @max(now_us, 1) });
                    break :blk t.cdp.items.len - 1;
                };
                t.cdp.items[i].extras +|= 1;
                if (v.credentialed) t.cdp.items[i].credentialed = true;
            },
            .response => |v| {
                const i = cdpIndex(t, v.rid) orelse return;
                const r = &t.cdp.items[i];
                // 재검증 3 차 뒤: 끝을 본 뒤의 늦은 응답은 버린다 — 정하는 중인 요청의 갈래·시각을 바꾸면 그 요청이 맞추기에서 빠졌다(혼돈 퍼즈: 판정이
                // 제 자리를 못 찾았다).
                if (r.state == .finished or r.state == .failed) return;
                r.sw = v.from_sw;
                r.responded = true;
                if (v.from_sw and r.has_key) {
                    t.sw_seen[t.sw_seen_next] = .{ .url = r.key_url, .method = r.key_method, .at = r.anchor() };
                    t.sw_seen_next = (t.sw_seen_next + 1) % max_sw_seen;
                }
                r.sw_off_network = v.from_sw and !std.mem.eql(u8, v.sw_source, "network");
                // 제 기록의 IO 시각은 응답보다 앞이다 — CDP 의 응답 시각(같은 시계 — J1)이 맞아 보이면(UI 가 받은 때 앞 2 초 안) 그것, 아니면 UI 가
                // 받은 때(늦은 쪽 — 기다림이 조금 길 뿐 틀리지 않는다).
                if (r.responded_at == 0) r.responded_at = @max(cdpTime(v.ts_us, now_us), 1);
                if (v.prefetch) r.prefetch = true;
                r.low = r.low or v.low;
                if (v.res_kind != .other) r.res_kind = v.res_kind;
                r.has_extra_info = v.has_extra_info;
                const m = v.mime[0..@min(v.mime.len, r.mime.len)];
                @memcpy(r.mime[0..m.len], m);
                r.mime_len = @intCast(m.len);
                r.charset = v.charset;
            },
            .data => |v| {
                const i = cdpIndex(t, v.rid) orelse return;
                t.cdp.items[i].data_bytes +|= v.bytes;
            },
            .from_cache => |v| {
                const i = cdpIndex(t, v.rid) orelse return;
                if (t.cdp.items[i].state != .open) return; // 끝을 본 뒤의 늦은 알림(위와 같다)
                t.cdp.items[i].state = .cached;
            },
            .finished => |v| {
                const i = cdpIndex(t, v.rid) orelse return;
                const r = &t.cdp.items[i];
                if (r.state == .finished or r.state == .failed) return; // 두 번째 끝은 버린다
                if (r.state == .cached or r.prefetch or !r.has_key or r.sw_off_network) {
                    // CEF 가 보지 못한 요청(메모리 캐시·추측 미리 받기 — J1·J3; 서비스 워커가 네트워크 밖에서 준 응답 — 4 회차 SW1)
                    _ = t.cdp.orderedRemove(i);
                    return;
                }
                r.state = .finished;
                r.done_at = @max(now_us, 1);
                try self.tryDecide(gpa, t, i, now_us);
            },
            .failed => |v| {
                const i = cdpIndex(t, v.rid) orelse return;
                const r = &t.cdp.items[i];
                if (r.state == .finished or r.state == .failed) return; // 두 번째 끝은 버린다
                if (r.state == .cached or r.prefetch or !r.has_key or r.sw_off_network) {
                    _ = t.cdp.orderedRemove(i);
                    return;
                }
                r.state = .failed;
                r.done_at = @max(now_us, 1);
                // 5 회차 A1: 실패의 시각은 CDP 의 것(UI 가 받은 때는 늦다 — 응답 시각과 같은 검사).
                r.failed_at = @max(cdpTime(v.ts_us, now_us), 1);
                // 재검증 3 차 뒤 PF-2: 응답 없이 실패한 요청(abort — 본문이 없다)은 다음 주기·물 높이(`decidePending`)가 한꺼번에 정한다 — 사건마다
                // 같은 주소 무리를 다시 맞추면 abort 수천 개가 UI 스레드를 세웠다(검증: 실패 사건 3960 개에 ReleaseFast 1.3 s). 늦어야 한 주기다.
                if (!failedBare(r)) try self.tryDecide(gpa, t, i, now_us);
            },
        }
    }

    /// CDP 사건의 시각(`timestamp` — CEF 의 IO 시각과 같은 시계, J1)이 맞아 보이면(UI 가 받은 때 앞 2 초 안) 그것, 아니면 UI 가 받은 때(늦은 쪽).
    fn cdpTime(ts_us: i64, now_us: i64) i64 {
        return if (ts_us > 0 and ts_us <= now_us and now_us - ts_us <= window_after_us) ts_us else now_us;
    }

    /// 후보 `c` 가 CDP 요청 `o` 의 짝일 수 있는가(열쇠는 부른 쪽이 이미 골랐다) — `o` 의 기준 시각의 창 안이고 다시 시작의 갈래가 맞는다.
    fn feasible(o: *const Cdp, c: *const Candidate) bool {
        const ts = o.anchor();
        if (c.t_io_us < ts - window_before_us or c.t_io_us > ts + window_after_us) return false;
        // 다시 시작한 시도의 후보는 앞 시도 때 시작한(다시 보내지 않은) CDP 요청과 짓지 않는다 — 그 본문은 버려진 앞 시도의 것이다(다른
        // requestId 로 보이는 다시 시작).
        if (c.prev_t_io_us != 0 and o.restart_ts_us == 0 and o.ts_us <= c.prev_t_io_us + window_before_us) return false;
        // W9d② 적대 리뷰 2 회차 F3: 다시 시작한 CDP 요청은 다시 시작한 CEF 시도(같은 번호의 둘째 시작)와만 — 옮긴 기준 시각의 창에 든 같은 주소의
        // 다른 요청 기록을 갖지 않는다.
        if (o.restart_ts_us != 0 and c.prev_t_io_us == 0) return false;
        return true;
    }

    /// 후보 `c` 가 CDP 요청 `o` 의 짝일 수 있는가 — 창(`feasible`)과 함께 시각의 차례(W9d② 적대 리뷰 3 회차):
    ///   - 응답을 봤으면 제 기록은 그 전에 시작했다(`bound` — 요청은 CEF 기록 뒤에 나가고 응답은 그 뒤에 온다): 그 뒤에 시작한 기록은 아니다.
    ///     뒤에 같은 주소를 받은 워커의 기록이 2 초 창에 들어도 이 요청을 모호하게 하지 않는다(P1 의 대가를 줄인다).
    ///   - 성공한 CDP 요청은 CEF 가 실패·취소로 끝낸 기록의 짝이 아니다(P5 — abort 한 요청의 기록).
    ///   - 응답 없이 실패한 요청(abort — CEF 에 닿지 않았을 수 있다, P5)은 CEF 가 성공으로 끝낸 기록을 갖지 않는다 — 그 기록이 실패 앞에
    ///     시작했어도(W9d② 적대 리뷰 5 회차 A1: 전에는 UI 가 실패를 본 때까지 시작한 기록은 결과를 보지 않고 제 것으로 쳤다 — 다시 받은 요청의
    ///     기록이 그보다 앞에 시작한 꼴에서 그 기록을 `request_failed` 로 가져갔다). 응답 없이 실패한 요청의 CEF 기록은 성공으로 끝나지 않는다
    ///     (CEF 가 응답을 다 받았으면 CDP 의 `responseReceived` 가 왔다). 끝이 아직이면 「그럴 수 있다」(`definite` 가 기다린다).
    fn compatible(o: *const Cdp, c: *const Candidate) bool {
        if (!feasible(o, c)) return false;
        const known_ok = c.ended_at != 0 and !c.cef_failed and !c.lost;
        if (o.state == .finished and c.ended_at != 0 and c.cef_failed) return false;
        if (o.restart_ts_us != 0) return true; // 다시 시작한 시도와만 짓는다(`feasible`) — 시각의 차례는 실측과 다르다(`bound`)
        if (o.responded_at != 0) return c.t_io_us <= o.responded_at;
        if (o.state == .failed) return !known_ok;
        if (o.state == .finished and c.t_io_us > o.done_at) return false;
        return true;
    }

    /// 맞추기에 드는 CDP 요청인가(메모리 캐시·추측 미리 받기·자리만 잡은 것·서비스 워커가 네트워크 밖에서 준 응답·놓인 것은 아니다).
    fn matchable(o: *const Cdp) bool {
        return !(o.gone or o.state == .cached or o.prefetch or !o.has_key or o.sw_off_network);
    }

    /// 재검증 4 차 뒤 R6-1·R6-2·R6-3(조정자 결정 — 이 PR 의 불변식 「틀린 본문 0 이 잃는 본문보다 먼저」): 서비스 워커가 넘긴 응답(`from_sw` —
    /// 출처 `network`)의 요청 `r`(`t.cdp` 자리 `i`)의 짝이 차례와 상관없이 **하나로** 정해지는가. 워커 갈래(`Key.sw`)의 CEF 기록 차례는 워커
    /// 스레드의 것이지 페이지의 CDP 시작 차례가 아니다(J2 는 서지 않는다 — 워커가 두 요청을 거꾸로 넘기면 네 맞추기가 함께 뒤바뀐 짝을 줬다,
    /// 실제 CEF swrev 40/40), 그리고 출처 `network` 는 「워커가 네트워크에서 받았다」 일 뿐 「이 주소를」 이 아니다(다른 주소로 답했을 수 있다 —
    /// swalt·swalt1 20/20). 그래서 셋 모두일 때만 정한다:
    ///   1. 같은 열쇠의 짝 없는 기록 가운데 `r` 와 짝일 수 있는 것(`compatible`)이 꼭 하나다.
    ///   2. 그 기록과 짝일 수 있는 같은 주소·메서드의 다른 요청(워커 갈래이거나 아직 응답이 없는)이 없다.
    ///   3. `r` 의 창(기준 시각 − 5 ms .. 응답 때)에 시작한, **다른 주소**의 워커 기록 가운데 그 주소의 CDP 요청(열린 것·워커가 답한 것 — 네트워크
    ///      밖에서 답해 목록에서 빠진 것은 `Tab.sw_seen`)으로 설명되지 않는 것(워커가 스스로 받은 것 — `r` 에 다른 주소로 답한 기록일 수 있다)이
    ///      없다. 이것이 없으면 R6-3(워커가 다른 주소로 답하고 같은 주소를 제 갱신 fetch 로 받았다 — 요청 하나·기록 하나)을 가르지 못한다.
    /// 응답 지문(상태·길이)은 쓰지 않는다 — 같아도 내용이 다를 수 있다. 아니면 부른 쪽이 그 기록들을 `ambiguous` 로 끝내고 주인일 수 있는
    /// 요청을 모두 맞추기에서 뺀다(남은 요청이 남은 기록과 「유일」 해 보이지 않게). 대가: 같은 주소를 겹쳐 받는 워커 요청, 워커가 스스로 다른
    /// 주소를 받는 동안(갱신·미리 받기·통계)의 워커 요청은 본문을 잃는다. 남는 틈: 워커가 `r` 에 다른 주소 v 로 답했는데 그 v 를 페이지도 같은
    /// 때 받아(그 기록이 v 의 CDP 요청으로 설명된다) 워커가 같은 주소를 따로 한 번 받은 꼴.
    fn swUnique(t: *const Tab, i: usize, r: *const Cdp) bool {
        const key = r.key();
        var only: ?*const Candidate = null;
        for (t.cands.items) |*c| {
            if (c.claimed or !c.key.eql(key) or !compatible(r, c)) continue;
            if (only != null) return false;
            only = c;
        }
        const c0 = only orelse return false;
        for (t.cdp.items, 0..) |*o, j| {
            if (j == i or !matchable(o) or o.key_url != key.url or o.key_method != key.method or (!o.sw and o.responded)) continue;
            if (compatible(o, c0)) return false;
        }
        const lo = r.anchor() - window_before_us;
        const hi = ioUpper(r);
        for (t.cands.items) |*c| {
            if (c.claimed or !c.key.sw or c.key.eql(key) or c.t_io_us < lo or c.t_io_us > hi) continue;
            const explained = for (t.cdp.items) |*o| {
                if (!matchable(o) or o.key_url != c.key.url or o.key_method != c.key.method or (!o.sw and o.responded)) continue;
                if (feasible(o, c)) break true;
            } else for (t.sw_seen) |w| {
                // 네트워크 밖에서 답해 목록에서 빠진 워커 요청도 그 주소의 워커 기록을 설명한다(`Tab.sw_seen`).
                if (w.url == c.key.url and w.method == c.key.method and c.t_io_us >= w.at - window_before_us and c.t_io_us <= w.at + window_after_us) break true;
            } else false;
            if (!explained) return false;
        }
        return true;
    }

    /// 응답 없이 실패한 요청(다시 시작 아님) — CEF 에 닿지 않았을 수 있다(abort). 5 회차 A1: 맞추기의 차례를 밀지 않는다(`tryDecide`).
    fn failedBare(o: *const Cdp) bool {
        return o.state == .failed and o.responded_at == 0 and o.restart_ts_us == 0;
    }

    /// 실패한 요청 `o` 가 후보 `c` 를 제 것으로 정해도 되는가 — CEF 가 그 기록을 실패·취소로 끝냈을 때만(5 회차 A1 — 전에는 실패를 본 때까지
    /// 시작한 기록이면 결과를 보지 않았다). 끝이 아직이면 그 기록은 다음 요청의 것일 수 있다 — 기다리고(`tryDecide`), CEF 가 성공으로 끝내면
    /// 짝이 아니다(`compatible`). 끝이 버려진 후보(`lost` — 끝난 것으로 쳤을 뿐 `cef_failed` 를 세우지 않는다)는 결과를 모르니 정하지 않는다.
    ///
    /// 재검증 2–9 회차 WB: 그 실패가 새 문서 시작(`doc_at`) 앞인데 기록의 실패 끝이 그 뒤에 왔으면 정하지 않는다 — 문서를 옮기며 CEF 가 진행 중
    /// 요청을 모두 취소하므로 그 끝은 이 abort 의 것이 아니라 다음 요청의 기록이 끊긴 것일 수 있다(퍼즈: CEF 에 닿지 않은 abort 가 뒤 요청의
    /// 끊긴 기록을 `request_failed` 로 가져가, 그 기록의 주인이 기록 없이 차례에 남았다). 시한 뒤의 길(`tryDecide`)이 정한다.
    fn definite(o: *const Cdp, c: *const Candidate, doc_at: i64) bool {
        if (o.state != .failed or o.responded_at != 0 or o.restart_ts_us != 0) return true;
        if (doc_at != 0 and o.failed_at < doc_at and c.ended_at >= doc_at) return false;
        return c.ended_at != 0 and c.cef_failed;
    }

    /// 맞추기의 왼쪽 차례(`tryDecide` 가 쓴다) — 열쇠 `key` 의 CDP 요청(기준 시각 차례 — `scratch.reqs`)과
    /// 짝 없는 후보(IO 시각 차례 — `scratch.cands`)를 채우고 요청마다 왼쪽 맞추기의 후보 자리를 `scratch.left` 에 둔다(`none` = 아직 기록이 오지
    /// 않았다).
    ///
    /// 같은 갈래의 CDP 요청 — 같은 주소·메서드, 서비스 워커 갈래가 같거나 아직 응답이 없어 모르는 것(열렸거나 끝나 짝을 기다린다 — 정한 것은
    /// 목록에서 빠졌다), 기준 시각 차례. 끝난 것도 넣어야 한다: 앞 요청이 CEF 기록을 기다리는 동안 뒤 요청이 끝나면 앞 요청의 짝을 가져갔다.
    /// 5 회차 A1: 응답 없이 실패한 요청(`failedBare` — CEF 에 닿지 않았을 수 있다)은 차례를 밀지 않는다 — 집은 후보에 표만 하고(`taken` — 뒤
    /// 요청은 건너뛴다) 다음 요청은 같은 자리부터 본다. 차례를 밀면 그 요청이 CEF 가 성공으로 끝낸 기록을 건너뛰고 뒤 기록을 집을 때 그 사이의
    /// 기록이 아무에게도 가지 않았다.
    fn matchLeft(self: *Table, gpa: std.mem.Allocator, t: *Tab, key: Key) std.mem.Allocator.Error!void {
        const none = std.math.maxInt(usize);
        const sc = &self.scratch;
        sc.reqs.clearRetainingCapacity();
        for (t.cdp.items, 0..) |o, j| {
            // 서비스 워커가 네트워크 밖에서 준 응답(4 회차 SW1)은 어느 기록도 가져가지 않는다 — 그 워커의 기록은 이 요청의 차례에 남아 갈림을 보인다.
            if (o.gone or o.state == .cached or o.prefetch or !o.has_key or o.sw_off_network) continue;
            if (o.key_url != key.url or o.key_method != key.method) continue;
            if (o.sw != key.sw and o.responded) continue;
            try sc.reqs.append(gpa, j);
        }
        const ReqCtx = struct {
            cdp: []const Cdp,
            fn lessThan(ctx: @This(), a: usize, b: usize) bool {
                const x = ctx.cdp[a].anchor();
                const y = ctx.cdp[b].anchor();
                return x < y or (x == y and a < b);
            }
        };
        // 재검증 3 차 뒤 PF-2: `t.cdp` 는 대개 이미 기준 시각 차례다 — 차례면 정렬하지 않는다.
        if (!std.sort.isSorted(usize, sc.reqs.items, ReqCtx{ .cdp = t.cdp.items }, ReqCtx.lessThan)) std.mem.sort(usize, sc.reqs.items, ReqCtx{ .cdp = t.cdp.items }, ReqCtx.lessThan);
        // 같은 열쇠의 짝 없는 CEF 시작 — IO 시각 차례.
        sc.cands.clearRetainingCapacity();
        for (t.cands.items, 0..) |c, ci| if (!c.claimed and c.key.eql(key)) try sc.cands.append(gpa, ci);
        const CandCtx = struct {
            cands: []const Candidate,
            fn lessThan(ctx: @This(), a: usize, b: usize) bool {
                const x = ctx.cands[a].t_io_us;
                const y = ctx.cands[b].t_io_us;
                return x < y or (x == y and a < b);
            }
        };
        if (!std.sort.isSorted(usize, sc.cands.items, CandCtx{ .cands = t.cands.items }, CandCtx.lessThan)) std.mem.sort(usize, sc.cands.items, CandCtx{ .cands = t.cands.items }, CandCtx.lessThan);
        const reqs = sc.reqs.items;
        const cands = sc.cands.items;
        try sc.left.resize(gpa, reqs.len);
        try sc.taken.resize(gpa, cands.len);
        @memset(sc.taken.items, false);
        var pos: usize = 0;
        // 재검증 3 차 뒤 PF-2: 응답 없이 실패한 요청(차례를 밀지 않는다)은 저마다 `pos` 부터 다시 훑었다 — abort 수천 개면 요청 × 기록. 그런
        // 요청에게 앞으로도 짝일 수 없는 기록(집혔다·CEF 가 성공으로 끝냈다·창 앞 — 요청은 기준 시각 차례라 창의 앞 끝은 늘기만 한다)이 앞에서부터
        // 이어진 자리(`bare_from`)는 건너뛰고, 창 끝을 넘으면 멈춘다(기록은 IO 시각 차례). 고른 짝은 같다.
        var bare_from: usize = 0;
        for (reqs, 0..) |j, q| {
            sc.left.items[q] = none;
            const o = &t.cdp.items[j];
            if (failedBare(o)) {
                const lo_t = o.anchor() - window_before_us;
                const hi_t = o.anchor() + window_after_us;
                bare_from = @max(bare_from, pos);
                var p = bare_from;
                while (p < cands.len) : (p += 1) {
                    const c = &t.cands.items[cands[p]];
                    if (sc.taken.items[p] or c.t_io_us < lo_t or (c.ended_at != 0 and !c.cef_failed and !c.lost)) {
                        if (p == bare_from) bare_from += 1;
                        continue;
                    }
                    if (c.t_io_us > hi_t) {
                        p = cands.len;
                        break;
                    }
                    if (compatible(o, c)) break;
                }
                if (p == cands.len) continue;
                sc.left.items[q] = p;
                sc.taken.items[p] = true;
                continue;
            }
            var p = pos;
            while (p < cands.len and (sc.taken.items[p] or !compatible(o, &t.cands.items[cands[p]]))) p += 1;
            if (p == cands.len) continue;
            sc.left.items[q] = p;
            pos = p + 1;
        }
    }

    /// 오른쪽 차례(`matchLeft` 뒤에) — 왼쪽에서 짝을 받은 요청만(기록이 아직 오지 않은 요청이 뒤의 후보를 가져가는 것으로 치지 않는다): 요청마다
    /// 뒤 요청의 짝 앞의 마지막 짝일 수 있는 후보(`out` — `scratch.right` 나 `scratch.right_fut`).
    ///
    /// 재검증 3 차 WB-4: `fut` 이면 오른쪽 맞추기를 「가장 늦을 수 있는」 쪽으로 한다 — 가장 이를 수 있는 왼쪽 맞추기(`matchLeftLo` 를 먼저
    /// 부른다)가 아무것도 주지 않은 요청, 곧 제 기록을 가졌는지 모르는 요청은 아무 기록도 가져가지 않는다: 제 기록이 아직 올 수 있는
    /// 요청(`scratch.pend`)과 결과를 모르는 기록을 쥔 응답 없이 실패한 요청(그 `taken` 도 보지 않는다). 그런 요청이 왼쪽에서 받은 기록은 제 것이 아닐 수 있다(앞 요청의 기록을 빌렸다 — 제 기록은 아직 오지 않았거나
    /// abort 한 요청이 집었다). 그 요청이 그 기록을 가져가는 것으로 치면 앞에 남는 기록(CDP 가 보지 못한 워커·미리 받기·다른 프로세스 iframe 의 같은
    /// 주소 기록, 놓인 요청의 기록)이 있을 때 두 맞추기가 함께 한 칸 밀려 같은 남의 기록을 줬다(검증 P-h·P-g·퍼즈 `localhost-bursts` 12/123,992).
    ///
    /// `young_after` 보다 늦게 시작한 기록은 보지 않는다(`maxInt` = 모두 본다) — 그 기록의 CDP 요청이 아직 알려지지 않았을 수 있다(`tryDecide`).
    fn matchRight(self: *Table, gpa: std.mem.Allocator, t: *Tab, out: *std.ArrayList(usize), fut: bool, young_after: i64) std.mem.Allocator.Error!void {
        const none = std.math.maxInt(usize);
        const sc = &self.scratch;
        const reqs = sc.reqs.items;
        const cands = sc.cands.items;
        try out.resize(gpa, reqs.len);
        var bound: usize = cands.len;
        var q = reqs.len;
        while (q > 0) {
            q -= 1;
            out.items[q] = none;
            // `fut` 은 가장 이를 수 있는 왼쪽 맞추기(`left_lo`·`taken_lo` — 결과를 모르는 기록을 쥔 응답 없이 실패한 요청과 기록이 아직 올 수 있는
            // 요청은 아무것도 갖지 않는다)를 바탕으로 한다 — 그 요청들은 여기서도 건너뛰고, 놓인 기록은 왼쪽 맞추기가 그것을 줬을 요청이 가져간다.
            const lq = if (fut) sc.left_lo.items[q] else sc.left.items[q];
            if (lq == none) continue;
            const o = &t.cdp.items[reqs[q]];
            // 응답 없이 실패한 요청은 차례를 밀지 않는다(왼쪽과 같다 — 갈림을 보이지 않는다).
            if (failedBare(o)) {
                out.items[q] = lq;
                continue;
            }
            const taken = if (fut) sc.taken_lo.items else sc.taken.items;
            var p = bound;
            while (p > 0 and (taken[p - 1] or t.cands.items[cands[p - 1]].t_io_us > young_after or !compatible(o, &t.cands.items[cands[p - 1]]))) p -= 1;
            if (p == 0) continue;
            out.items[q] = p - 1;
            bound = p - 1;
        }
    }

    /// 재검증 3 차 LB-1: 왼쪽 맞추기를 「가장 이를 수 있는」 쪽으로 다시 한다(`scratch.left_lo` — `matchLeft` 뒤에): 응답 없이 실패한 요청은 그
    /// 기록이 제 것으로 정해졌을 때(`definite`)만 가져가고, 아니면 아무것도 가져가지 않는다. 왼쪽 맞추기에서는 그런 요청이 뒤 요청의 기록을
    /// 집어(`taken`) 뒤 요청들이 한 칸씩 밀릴 수 있다 — 밀린 요청의 제 기록은 왼쪽 짝보다 앞이다(퍼즈: abort 가 다음 요청의 기록을 집고, 그 요청은
    /// 다시 받은 요청의 기록을, 다시 받은 요청은 짝이 없었다 — 갈린 판정이 그 기록을 끝내 다시 받은 요청이 남의 기록을 가져갔다).
    ///
    /// 제 기록이 아직 올 수 있는 요청(`scratch.pend` — 판정하는 요청은 끝났고 물 높이가 그 응답 때에 닿아 늘 아니다)도 아무것도 가져가지 않는다 — 그 요청은 CEF 에 닿지 않을 수도
    /// 있어(곧 abort 한다) 왼쪽 맞추기에서 뒤 요청의 기록을 빌렸을 수 있다(퍼즈: IO 가 CDP 시작보다 늦은 꼴에서 CEF 에 닿지 않을 앞 요청이 뒤
    /// 요청의 기록을 쥐어 뒤 요청이 그다음 기록을 받았다).
    fn matchLeftLo(self: *Table, gpa: std.mem.Allocator, t: *Tab) std.mem.Allocator.Error!void {
        const none = std.math.maxInt(usize);
        const sc = &self.scratch;
        const reqs = sc.reqs.items;
        const cands = sc.cands.items;
        try sc.left_lo.resize(gpa, reqs.len);
        try sc.lo_pos.resize(gpa, reqs.len);
        try sc.taken_lo.resize(gpa, cands.len);
        @memset(sc.taken_lo.items, false);
        var pos: usize = 0;
        var bare_from: usize = 0; // 재검증 3 차 뒤 PF-2: `matchLeft` 와 같다
        for (reqs, 0..) |j, q| {
            sc.left_lo.items[q] = none;
            sc.lo_pos.items[q] = none;
            const o = &t.cdp.items[j];
            var p = pos;
            if (failedBare(o)) {
                const lo_t = o.anchor() - window_before_us;
                const hi_t = o.anchor() + window_after_us;
                bare_from = @max(bare_from, pos);
                p = bare_from;
                while (p < cands.len) : (p += 1) {
                    const c = &t.cands.items[cands[p]];
                    if (sc.taken_lo.items[p] or c.t_io_us < lo_t or (c.ended_at != 0 and !c.cef_failed and !c.lost)) {
                        if (p == bare_from) bare_from += 1;
                        continue;
                    }
                    if (c.t_io_us > hi_t) {
                        p = cands.len;
                        break;
                    }
                    if (compatible(o, c)) break;
                }
            } else while (p < cands.len and (sc.taken_lo.items[p] or !compatible(o, &t.cands.items[cands[p]]))) p += 1;
            if (p == cands.len) continue;
            sc.lo_pos.items[q] = p;
            if (failedBare(o)) {
                if (!definite(o, &t.cands.items[cands[p]], t.doc_at)) continue;
                sc.taken_lo.items[p] = true;
            } else if (sc.pend.items[q]) continue else pos = p + 1;
            sc.left_lo.items[q] = p;
        }
    }

    /// 재검증 3 차 LB-1: 끝낼 후보 자리 [`lo`, `hi`](맞추기의 `cands` 자리)를 제 범위 — 가장 이를 수 있는 왼쪽 짝(`lo_pos`)·왼쪽 짝..늦어도 있을 자리
    /// (`rangeEnd`) — 에 둔 요청(`skip` 빼고)을 `scratch.drop_cdp` 에 적는다(부른 쪽이 `matchLeft`·`matchLeftLo`·두 `matchRight` 를 마쳤고
    /// `drop_cdp` 를 비웠다). 범위 밖의 요청은 제 기록이 제 범위 안이니 끝내는 기록의 주인이 아니다. 뺀 요청의 범위의 남은 기록은 끝내지 않는다 —
    /// 그 범위 끝은 아직 알려지지 않은 요청의 기록일 수 있다(끝내면 그 요청이 남의 기록을 가져갔다 — 퍼즈); 짝 없이 시한에 `ambiguous` 로
    /// 끝난다(`hint`). 범위가 겹쳐도 그 기록들의 주인일 수 없는 요청(`mayOwn`)은 두지 않는다. 전에는(재검증 2–9 회차) 끝내는 기록을 창에 둔 요청을 모두 뺐다 — 같은 주소의 촘촘한 무리에서 판정 하나가 무리 전체의 본문을
    /// 잃게 했다(검증 LB-1).
    fn markRangeOwners(self: *Table, t: *Tab, skip: usize, lo: usize, hi: usize) void {
        const none = std.math.maxInt(usize);
        const sc = &self.scratch;
        for (sc.reqs.items, 0..) |j, x| {
            const lj = sc.left.items[x];
            const ll = sc.lo_pos.items[x];
            if (j == skip or (lj == none and ll == none)) continue;
            const re = rangeEnd(sc, x);
            var ra: usize = none;
            var rb: usize = 0;
            for ([_]usize{ lj, ll, re }) |v| if (v != none) {
                ra = @min(ra, v);
                rb = @max(rb, v);
            };
            if (ra > hi or rb < lo) continue;
            // 범위가 겹쳐도 그 기록들의 주인일 수 없으면(`mayOwn` — 성공으로 끝난 요청의 기록은 그 끝 무렵에 끝났다) 두지 않는다.
            const owns = for (sc.cands.items[@max(ra, lo) .. @min(rb, hi) + 1]) |y| {
                if (self.mayOwn(&t.cdp.items[j], &t.cands.items[y])) break true;
            } else false;
            if (!owns) continue;
            sc.drop_cdp.items[j] = true;
            for (sc.cands.items[ra .. rb + 1]) |y| t.cands.items[y].hint = true;
        }
    }

    /// 재검증 3 차 LB-1: 맞추기 자리 `x` 의 요청의 기록이 늦어도 있을 후보 자리 — 기록이 올 수 있는 다른 요청을 뺀 오른쪽 짝(`right_fut`), 그것이
    /// 없으면(이 요청이 가장 늦을 수 있는 맞추기에서 아무것도 갖지 않았다 — 기록이 아직 올 수 있거나 결과를 모르는 기록을 쥔 abort) 차례의 끝:
    /// 그 요청의 기록은 어느 뒤 기록이든 될 수 있다. 재검증 3 차 뒤 WB-5: 전에는 오른쪽 짝·왼쪽 짝으로 좁혀, 응답을 기다리는 열린 요청의 제 기록을
    /// abort 의 시한 끝이 끝낼 때 그 요청을 놓지 않았다 — 그 요청이 뒤 기록을 가져가 같은 주소 요청들이 한 칸씩 밀렸다(퍼즈 spa-json).
    fn rangeEnd(sc: *const Scratch, x: usize) usize {
        const none = std.math.maxInt(usize);
        if (sc.right_fut.items[x] != none) return sc.right_fut.items[x];
        return if (sc.cands.items.len > 0) sc.cands.items.len - 1 else none;
    }

    /// 재검증 3 차 WB-4: 요청 `o` 의 CEF 기록(있다면)이 늦어도 시작한 IO 시각 — 응답을 봤으면 그때(제 기록은 응답 앞이다), 응답 없이 끝났으면 그
    /// 끝(실패 시각), 다시 시작한 요청은 끝을 본 때, 창 끝을 넘지 않는다. 재검증 3 차 뒤 WB-5: 아직 열려 있고 응답도 없으면 창 끝(전에는 기준
    /// 시각 + `record_lag_us` — 가정이었다: 서비스 워커가 늦게 넘긴 요청의 기록은 100 ms·300 ms 늦었다). 창 끝 뒤에는 새 기록이 그 요청의 것일
    /// 수 없다 — 기록 없는 응답 전 요청(서비스 워커가 2 초 넘게 늦게 캐시로 답한다)만 남는 틈이다.
    fn recordDue(o: *const Cdp) i64 {
        const end = o.anchor() + window_after_us;
        const due = if (o.restart_ts_us != 0)
            (if (o.done_at != 0) o.done_at else end)
        else if (o.responded_at != 0)
            o.responded_at
        else if (o.failed_at != 0)
            o.failed_at
        else if (o.done_at != 0)
            o.done_at
        else
            end;
        return @min(due, end);
    }

    /// 재검증 3 차 WB-4: 요청 `o` 의 CEF 기록이 아직 올 수 있다(물 높이가 `recordDue` 에 닿지 않았다).
    fn recordPending(self: *const Table, o: *const Cdp) bool {
        return self.cef_seen_us < recordDue(o);
    }

    /// 재검증 3 차 WB-4: 맞추기 자리마다 「제 기록을 가졌는지 아직 모르는」 요청을 `scratch.pend` 에 적는다(`matchLeft` 뒤에): 제 기록이 아직 올
    /// 수 있는 요청(`recordPending`), 그리고 CEF 가 막 실패·취소로 끝낸(`record_lag_us` 안) 같은 열쇠의 기록과 짝일 수 있는 열린 요청 — 그
    /// 기록의 주인이면 곧 `loadingFailed` 를 알린다(CEF 의 취소 끝이 먼저 온다). 그동안 응답 없이 실패한 다른 요청(CEF 에 닿지 않은 abort)이 그
    /// 기록을 제 것으로 가져가면 열린 주인은 뒤 기록을 빌려 뒤 요청들이 한 칸씩 밀렸다(퍼즈: IO 가 CDP 시작보다 수십 ms 늦은 꼴).
    fn markPending(self: *Table, gpa: std.mem.Allocator, t: *const Tab, now_us: i64) std.mem.Allocator.Error!void {
        const sc = &self.scratch;
        try sc.pend.resize(gpa, sc.reqs.items.len);
        for (sc.reqs.items, 0..) |j, x| sc.pend.items[x] = self.recordPending(&t.cdp.items[j]);
        for (sc.cands.items) |ci| {
            const c = &t.cands.items[ci];
            if (!(c.cef_failed and c.ended_at != 0 and now_us - c.ended_at < record_lag_us)) continue;
            for (sc.reqs.items, 0..) |j, x| if (t.cdp.items[j].state == .open and compatible(&t.cdp.items[j], c)) {
                sc.pend.items[x] = true;
            };
        }
    }

    /// 열쇠 `key` 의 맞추기를 모두 한다 — 왼쪽(`matchLeft`)·기록을 가졌는지 모르는 요청(`markPending`)·가장 이를 수 있는 왼쪽(`matchLeftLo`)·
    /// 가장 늦을 수 있는 오른쪽(`right_fut`)·오른쪽, 막 시작한 기록을 끝에서부터 1..`young_n` 개 뺀 오른쪽(`right_young`). 판정하는 요청과 상관없는
    /// 값이라 `decidePending` 한 바퀴 안에서 표가 바뀌지 않았으면 같은 열쇠는 다시 하지 않는다(`cache_*` — 바뀌면 지운다).
    ///
    /// 판정하는 요청 `i` 자신은 「기록이 아직 올 수 있는」 요청으로 치지 않는다(물 높이가 늦은 판정 — `late` — 에서만 그렇다; 그때는 맞추기를
    /// 다른 요청과 나누지 않는다).
    fn ensureArrays(self: *Table, gpa: std.mem.Allocator, t: *Tab, key: Key, i: usize, now_us: i64) std.mem.Allocator.Error!void {
        const sc = &self.scratch;
        if (sc.cache_on and sc.cache_valid and sc.cache_tab == @intFromPtr(t) and sc.cache_key.eql(key)) {
            // 재검증 4 차 뒤 R19-1: 자리 색인으로(전에는 `reqs` 를 훑었다).
            const q = if (i < sc.pos_of.items.len) sc.pos_of.items[i] else std.math.maxInt(usize);
            if (q != std.math.maxInt(usize) and !sc.pend.items[q]) return;
        }
        try self.matchLeft(gpa, t, key);
        sc.match_runs += 1;
        try sc.pos_of.resize(gpa, t.cdp.items.len);
        @memset(sc.pos_of.items, std.math.maxInt(usize));
        for (sc.reqs.items, 0..) |j, q| sc.pos_of.items[j] = q;
        try self.markPending(gpa, t, now_us);
        var shared = true;
        for (sc.reqs.items, 0..) |j, q| if (j == i and sc.pend.items[q]) {
            sc.pend.items[q] = false;
            shared = false;
        };
        try self.matchRight(gpa, t, &sc.right, false, std.math.maxInt(i64));
        sc.unpaired.clearRetainingCapacity();
        for (sc.reqs.items, sc.left.items, 0..) |j, l, q| if (l == std.math.maxInt(usize) and !failedBare(&t.cdp.items[j])) try sc.unpaired.append(gpa, q);
        // 기록을 가졌는지 모르는 요청이 없으면(대개) 가장 이를·늦을 수 있는 맞추기는 왼쪽·오른쪽 그대로다.
        const unsure = for (sc.reqs.items, sc.pend.items) |j, pd| {
            if (pd or failedBare(&t.cdp.items[j])) break true;
        } else false;
        if (unsure) {
            try self.matchLeftLo(gpa, t);
            try self.matchRight(gpa, t, &sc.right_fut, true, std.math.maxInt(i64));
        } else {
            try sc.left_lo.resize(gpa, sc.reqs.items.len);
            try sc.lo_pos.resize(gpa, sc.reqs.items.len);
            try sc.right_fut.resize(gpa, sc.reqs.items.len);
            @memcpy(sc.left_lo.items, sc.left.items);
            @memcpy(sc.lo_pos.items, sc.left.items);
            @memcpy(sc.right_fut.items, sc.right.items);
            try sc.taken_lo.resize(gpa, sc.cands.items.len);
            @memset(sc.taken_lo.items, false);
        }
        sc.young_n = std.math.maxInt(usize); // `ensureYoung` 가 처음 쓸 때 만든다
        // 재검증 4 차 뒤 R19-1: 판정하는 요청과 상관없는 두 훑기를 한 번에 — `held` 의 후보(결과를 모르는 기록을 쥔 응답 없이 실패한 요청)와 WB-3 의
        // 새 문서를 건너 쥔 앞 문서 요청(가장 앞 자리).
        sc.bare_held.clearRetainingCapacity();
        sc.first_cross = std.math.maxInt(usize);
        for (sc.reqs.items, sc.left.items, 0..) |j, lp, q| {
            if (lp == std.math.maxInt(usize)) continue;
            const o = &t.cdp.items[j];
            const c = &t.cands.items[sc.cands.items[lp]];
            if (failedBare(o) and !definite(o, c, t.doc_at)) try sc.bare_held.append(gpa, q);
            if (t.doc_at != 0 and sc.first_cross == std.math.maxInt(usize) and o.state == .open and !(c.cef_failed and c.ended_at != 0) and crossesDoc(t, o, c.t_io_us)) sc.first_cross = q;
        }
        sc.cache_valid = sc.cache_on and shared;
        sc.cache_tab = @intFromPtr(t);
        sc.cache_key = key;
    }

    /// `ensureArrays` 뒤에 — 막 시작한 기록을 끝에서부터 1..`young_n` 개 뺀 오른쪽 맞추기(`right_young`)를 만든다(처음 쓸 때 한 번).
    fn ensureYoung(self: *Table, gpa: std.mem.Allocator, t: *Tab, now_us: i64) std.mem.Allocator.Error!void {
        const sc = &self.scratch;
        if (sc.young_n != std.math.maxInt(usize)) return;
        const cands = sc.cands.items;
        sc.young_n = 0;
        while (sc.young_n < cands.len and sc.young_n < max_young and t.cands.items[cands[cands.len - 1 - sc.young_n]].t_io_us > now_us - record_lag_us) {
            sc.young_n += 1;
            try self.matchRight(gpa, t, &sc.right_young[sc.young_n - 1], false, t.cands.items[cands[cands.len - sc.young_n]].t_io_us - 1);
        }
    }

    /// 끝난 CDP 요청 `i` 의 짝을 찾아 판정한다. 아직 후보가 없으면 그대로 둔다(`tick` 이 다시 본다).
    ///
    /// 짝은 차례를 지키는 맞추기로 고른다(W9d② 적대 리뷰 2 회차 — 같은 주소의 동시 요청은 시작 차례 그대로다, J2): 같은 열쇠의 CDP 요청(기준 시각
    /// 차례)과 짝 없는 후보(IO 시각 차례)를 앞에서부터 — 요청마다 앞 요청의 짝 뒤의 첫 「짝일 수 있는」 후보(창 안)를 준다(왼쪽 맞추기). 후보가
    /// 없는 요청은 CEF 기록이 아직 오지 않았다(10 ms 묶음 — 오면 이미 준 후보들보다 IO 시각이 앞이 아니다)고 보고 건너뛴다. 전에는 먼저 시작해
    /// 아직 열린 요청 수 k 만큼 창 안의 후보를 건너뛰었다 — 그 요청의 기록이 이 요청의 창 밖(앞)에 있어도 세어, 5 ms 넘게 떨어져 시작한 같은
    /// 주소의 두 요청 중 뒤 요청이 먼저 끝나면 둘 다 본문을 잃었고(F1 — 느린 앞 요청이 있는 동시 POST /graphql), 워커의 같은 주소 기록이 페이지의
    /// 본문을 가져갔다(F2). 같은 맞추기를 뒤에서부터도 한다(오른쪽 맞추기 — 요청마다 뒤 요청의 짝 앞의 마지막 짝일 수 있는 후보, 왼쪽에서 짝을
    /// 받은 요청만). 둘이 이 요청에 다른 후보를 주면 CDP 가 보지 못한 같은 열쇠의 CEF 요청(전용·공유 워커의 fetch — J3)이 섞여 차례로는 가를 수
    /// 없다 — 두 후보 사이(둘 포함)를 모두 `ambiguous` 로 끝내고(적대 리뷰 1 회차 MED-2), 두 맞추기가 다른 짝을 준 다른 요청도 뒤에 `ambiguous`
    /// 로 정한다(`Cdp.tainted` — 끝낸 후보가 그 요청의 갈림을 보이던 증거였다).
    ///
    /// 재검증 3 차: 두 맞추기가 같은 기록을 줘도 뒤 요청의 기록이 아직 올 수 있으면(WB-4 — 그 요청이 왼쪽에서 받은 기록은 빌린 것일 수 있다) 그
    /// 요청을 뺀 오른쪽 맞추기(`right_fut`)도 같은 기록을 줄 때만 정하고, 아니면 그 기록이 올 때까지 기다린다(시한 `cef_grace_us` — 넘기면 본문
    /// 없이 — `cef_grace_us + record_lag_us`). 본문 없이 끝내는 판정은 까닭으로 가른다(LB-1): 두 맞추기가 같은 기록을 주고 맞추기를 의심할 까닭이 없으면(보이는 규칙·버린 끝의
    /// 표지·갈린 적 있는 요청 — 짝은 정해졌고 본문만 붙이지 않는다) 그 짝만 함께 빠진다 — 다른 요청을 놓지 않는다. 두 맞추기가 갈렸으면 사이
    /// 기록을 끝내고 그 기록이 제 범위(왼쪽 짝..`right_fut` 짝)에 드는 요청만 놓는다. 맞추기 자체를 의심할 때(물 높이가 늦다·`held`·문 넘김
    /// 표지·자리 상한 표지·뒤 기록 기다림의 시한)만 전처럼 그 기록의 주인일 수 있는 요청을 모두 놓는다(`retireOwnersOf`).
    fn tryDecide(self: *Table, gpa: std.mem.Allocator, t: *Tab, i_in: usize, now_us: i64) std.mem.Allocator.Error!void {
        const none = std.math.maxInt(usize);
        const sc = &self.scratch;
        var i = i_in;
        while (true) {
            const r = t.cdp.items[i];
            const key = r.key();
            const ts = r.anchor();
            // W9d② 적대 리뷰 3 회차 P1: 제 CEF 기록이 아직 오지 않았을 수 있다 — CDP 의 끝은 CEF 의 10 ms 묶음보다 대개 먼저 온다(빠른 로컬 요청은
            // 450/450). 그때 CDP 가 보지 못한 같은 주소의 기록(워커의 fetch — 앞 묶음으로 왔다)이 창 안에 있으면 두 맞추기 모두 그것을 줘 페이지의
            // 본문이 워커의 기록에 붙었다(실제 CEF 24/80). 그래서 제 기록이 시작했을 때(`bound` 앞)까지의 CEF 기록이 모두 온 뒤에만 정한다 — 물
            // 높이는 IO 상자가 비면 곧 지금이라 대개 기다리지 않거나 다음 묶음(10 ms)까지다. 시한(`cef_grace_us`)이 지나도 오르지 않으면(UI 스레드가
            // 상자를 비우지 못했다) 틀린 기록에 붙이느니 `ambiguous` 로 정한다.
            var late = false;
            if (self.cef_seen_us < r.bound()) {
                if (now_us - r.done_at < cef_grace_us) return;
                late = true;
            }
            try self.ensureArrays(gpa, t, key, i, now_us);
            const reqs = sc.reqs.items;
            const cands = sc.cands.items;
            // 재검증 4 차 뒤 R19-1: 자리 색인(`ensureArrays`).
            const me: usize = if (i < sc.pos_of.items.len) sc.pos_of.items[i] else none;
            if (me == none) {
                // 맞추기에 들지 않는 요청(위의 늦은 사건 버리기로 끝난 요청에는 생기지 않는다 — 지키는 길): 짝을 정할 수 없다 — 놓는다.
                _ = t.cdp.orderedRemove(i);
                return;
            }
            // 재검증 2–9 회차 WB-3 · 재검증 3 차 LB-1: 차례가 이 요청 앞인 열린 앞 문서의 요청(새 문서 알림 앞에 보냈다 — CDP 끝이 오지 않는다)이 새
            // 문서 뒤에 시작한 기록을 왼쪽 짝으로 쥔다 — 그 요청은 CEF 에 닿지 않아 제 기록이 없을 수 있다(문서가 떠나며 끊겼다). 그러면 두 맞추기가
            // 함께 한 칸씩 밀려 이 요청의 짝이 남의 기록이다(검증 WB-3: 다시 불러온 문서의 두 같은 주소 요청). 전에는 이 요청을 `ambiguous` 로 정했고
            // (그 판정이 같은 무리의 주인을 모두 놓아 다시 불러온 문서의 같은 주소 요청이 본문을 잃었다 — LB-1), 이제 그 앞 문서 요청을 맞추기에서
            // 빼고 다시 맞춘다 — 그 요청의 본문은 어차피 없다(앞 문서 — CDP 끝이 오지 않는다). CEF 가 실패·취소로 끝낸 기록은 빼고 본다 — 대개 끊긴
            // 앞 문서 요청 제 기록이고(경계 앞 5 ms 안이면 넓힌 경계에 걸린다 — 실제 CEF `v20g-r9-gap-*`), 성공한 요청의 짝이 아니라 본문이 붙을 일이
            // 없다. 새 문서의 요청인 것을 loader 로 아는 요청은 빼지 않는다(`crossesDoc`).
            if (t.doc_at != 0 and sc.first_cross < me) {
                try sc.drop_cdp.resize(gpa, t.cdp.items.len);
                @memset(sc.drop_cdp.items, false);
                var any = false;
                for (reqs[0..me], sc.left.items[0..me]) |j, lp| {
                    if (lp == none) continue;
                    const o = &t.cdp.items[j];
                    const c = &t.cands.items[cands[lp]];
                    if (o.state == .open and !(c.cef_failed and c.ended_at != 0) and crossesDoc(t, o, c.t_io_us)) {
                        sc.drop_cdp.items[j] = true;
                        c.hint = true;
                        any = true;
                    }
                }
                if (any) {
                    sc.cache_valid = false;
                    self.dropRetired(t);
                    i = cdpIndex(t, r.rid.slice()) orelse return;
                    continue;
                }
            }
            const left = sc.left.items[me];
            if (left == none) {
                // 짝이 아직 오지 않았다(CEF 기록은 10 ms 묶음) — 시한이 지나면 CEF 가 보지 못한 요청으로 놓는다(본문 없음, maru 에 기록도 없다).
                if (now_us - r.done_at >= cef_grace_us) {
                    if (sc.cache_on) {
                        // `decidePending` 안 — 표시만 하고 바퀴 끝에 지운다. 어느 맞추기에서도 기록을 갖지 않았으면 다른 요청의 짝은 그대로다(PF-2 —
                        // 나눠 쓰는 맞추기에서 그 자리만 지운다).
                        t.cdp.items[i].gone = true;
                        sc.removed_bare = if (sc.left_lo.items[me] == none and sc.right.items[me] == none and sc.right_fut.items[me] == none) i else std.math.maxInt(usize) - 1;
                    } else _ = t.cdp.orderedRemove(i);
                }
                return;
            }
            const ci = cands[left];
            // P5·5 회차 A1: 응답 없이 실패한 요청에게 준 후보의 CEF 끝이 아직이면(다음 요청의 것일 수 있다 — 성공으로 끝나면 놓인다) 그 끝을
            // 기다린다. 시한까지 모르면 정하지 않는다: CDP 의 실패 시각 뒤에 시작한 기록은 다음 요청의 것(다시 받기 — 실제 CEF 93/93 이 실패 시각
            // 뒤)이라 이 요청만 놓고, 앞에 시작한 기록은 이 요청의 것일 수 있어(abort 가 CEF 의 끝보다 먼저 보였는데 그 끝이 늦다) 다음 요청에게 주지
            // 않고 본문 없이 끝낸다(`ambiguous`).
            // 재검증 3 차 WB-4: CEF 가 막(`record_lag_us` 안) 실패로 끝낸 기록은 그것과 짝일 수 있는 열린 요청이 있으면 아직 이 요청의 것으로 정하지
            // 않는다 — 그 열린 요청이 주인이면 곧 실패를 알린다(`markPending`). 먼저 가져가면 그 요청이 뒤 기록을 빌렸다(퍼즈).
            if (failedBare(&r) and definite(&r, &t.cands.items[ci], t.doc_at) and now_us - t.cands.items[ci].ended_at < record_lag_us and now_us - r.done_at < cef_grace_us) {
                const c = &t.cands.items[ci];
                for (reqs) |j| if (j != i and t.cdp.items[j].state == .open and compatible(&t.cdp.items[j], c)) return;
            }
            if (!definite(&r, &t.cands.items[ci], t.doc_at)) {
                if (now_us - r.done_at < cef_grace_us) return;
                const c = t.cands.items[ci];
                if (c.t_io_us <= r.failed_at) {
                    // 재검증 2–9 회차 WB: 그 기록의 주인일 수 있는 다른 요청도 맞추기에서 뺀다 — 그 기록이 그 요청의 것이었으면(abort 가 CEF 에 닿지
                    // 않았다; 이 요청은 차례를 밀지 않고 집어 그 요청의 왼쪽 짝은 뒤로 밀려 있었다) 남겨 두면 다음 기록(남의 것)을 가져간다(검증 5 회차
                    // B). 본문은 잃지만 틀리지 않는다. 재검증 3 차 LB-1: 그 기록을 제 범위에 둔 요청만(`markRangeOwners` — 이 요청이 아무것도 갖지 않는
                    // 맞추기로 본 범위; 전에는 창에 둔 같은 주소 요청을 모두 — 퍼즈 spa-json: 그 기록의 주인 하나와 함께 열린 같은 무리 셋이 빠졌다).
                    try sc.drop_cdp.resize(gpa, t.cdp.items.len);
                    @memset(sc.drop_cdp.items, false);
                    self.markRangeOwners(t, i, left, left);
                    _ = t.cdp.orderedRemove(i);
                    if (i < sc.drop_cdp.items.len) {
                        std.mem.copyForwards(bool, sc.drop_cdp.items[i .. sc.drop_cdp.items.len - 1], sc.drop_cdp.items[i + 1 ..]);
                        sc.drop_cdp.items.len -= 1;
                    }
                    try self.emit(gpa, .{ .end = .{ .browser = t.browser, .session = t.session, .request = c.request, .state = .ambiguous, .flags = .{ .credentialed = c.cef_credentialed } } });
                    _ = t.cands.orderedRemove(ci);
                    self.dropRetired(t);
                } else _ = t.cdp.orderedRemove(i);
                return;
            }
            // 5 회차 A1: 응답 없이 실패한 요청이 이 요청의 후보 앞의 기록을 CEF 끝이 아직인 채 쥐고 있다 — 그 기록이 성공으로 끝나면 놓여 이 요청의
            // 짝이 바뀐다(abort 가 CEF 에 닿지 않았으면 그 기록은 다시 받은 이 요청의 것이다). 끝이 올 때까지 기다리고 시한이면 본문 없이.
            // 재검증 2–9 회차 WB: 쥔 기록이 이 요청의 후보 뒤여도 이 요청의 창 안이면 같다 — 두 맞추기가 모두 그 기록을 건너뛰어(`taken`) 갈림을
            // 보이지 못한다(퍼즈: 워커의 기록이 이 요청의 짝 자리에 들고, 이 요청의 기록은 그 실패한 요청이 쥐었다 — 둘이 함께 워커의 기록을 줬다).
            // 쥔 기록이 뒤에 있고 차례가 이 요청 뒤인 요청 가운데 아직 짝이 없는(기록이 오지 않은 것으로 보인) 요청이 그 기록과 짝일 수 있으면 그
            // 요청의 기록으로 본다(abort 의 다시 받기와 같은 주소의 다른 요청 — 5 회차 A1 의 꼴, 그 요청은 실패한 요청이 놓으면 그 기록을 받는다).
            var held = false;
            // 재검증 4 차 뒤 R19-1: 그런 요청만(`bare_held` — `ensureArrays` 가 모았다; 전에는 요청마다 `reqs` 전체).
            if (!failedBare(&r)) for (sc.bare_held.items) |bq| {
                const j = reqs[bq];
                const lp = sc.left.items[bq];
                if (j == i or lp == left) continue;
                const y = &t.cands.items[cands[lp]];
                if (lp < left) {
                    held = true;
                    break;
                }
                if (!compatible(&r, y)) continue;
                // 재검증 3 차 뒤 PF-2: 뒤 요청 가운데 짝 없는 것만 본다(`unpaired` — 전에는 뒤 요청을 모두 훑어 쥔 기록마다 O(요청)).
                const explained = for (sc.unpaired.items) |kq| {
                    if (kq > me and compatible(&t.cdp.items[reqs[kq]], y)) break true;
                } else false;
                if (!explained) {
                    held = true;
                    break;
                }
            };
            if (held and now_us - r.done_at < cef_grace_us) return;
            if (r.state == .finished) {
                // MED-1(설정이 꺼졌을 때): 응답을 보낸 호스트(리다이렉트 뒤)를 CEF 응답이 정하기 전에는 받으러 가지 않는다 — 시작 호스트로 정한
                // 「덮인다」 는 덮이지 않는 호스트로 리다이렉트한 요청에서 틀린다(판정 body-r1-switch-off-redirect: 12/12 가 빠져나갔다). 시한이
                // 지나도 오지 않으면 덮이지 않는 쪽으로.
                const c = &t.cands.items[ci];
                if (c.cover_pending) {
                    if (now_us - r.done_at < cover_grace_us) return;
                    c.cover_pending = false;
                    c.covered = false;
                }
                // LOW-3: Chromium 이 ExtraInfo 가 온다고 했는데 홉마다의 것이 아직 다 오지 않았다 — 잠시 기다린다(넘기면 `decide` 가 실린 것으로).
                if (r.has_extra_info and r.extras < r.sends and now_us - r.done_at < extra_grace_us) return;
            }
            // 재검증 3 차 LB-1: 두 맞추기가 갈렸는데 막 시작한 기록(`record_lag_us` 안 — 그 CDP 요청의 `requestWillBeSent` 가 아직 오지 않았을 수
            // 있다: IO 가 CDP 시작보다 앞일 수 있고 CDP 사건은 늦게 닿는다)을 빼면 같은 기록을 준다 — 그 요청이 알려지면 갈림이 풀릴 수 있으니 잠시
            // 기다린다(퍼즈: 알려지지 않은 요청의 기록을 앞 요청들이 한 칸씩 가져가 같은 주소 무리가 모두 본문을 잃었다). 막 시작한 기록은 IO 시각
            // 차례의 끝에 모인다 — 끝에서부터 하나씩(그 기록들이 알려지지 않은 요청들의 것이라 치고) 빼 본다(몇 개가 그런지는 모른다 — 모두 빼면 앞
            // 요청의 기록까지 빠진다).
            if (sc.right.items[me] != left and now_us - r.done_at < cef_grace_us + record_lag_us) {
                try self.ensureYoung(gpa, t, now_us);
                for (sc.right_young[0..sc.young_n]) |ry| if (ry.items[me] == left) return;
            }
            const right = sc.right.items[me];
            const right_fut = sc.right_fut.items[me];
            // 두 맞추기가 같은 기록을 주지만 뒤 요청의 기록이 오면 갈릴 수 있다 — 그 기록을 기다린다(시한 뒤에는 맞추기를 의심하는 쪽으로).
            var pending_split = false;
            if (right == left and (right_fut != left or sc.left_lo.items[me] != left)) {
                if (now_us - r.done_at < split_wait_us) return;
                pending_split = true;
            }
            // 재검증 4 차 뒤 R6: 서비스 워커가 넘긴 응답은 짝이 하나로 정해질 때만(`swUnique`) — 아니면 맞추기를 의심하는 쪽으로(그 기록들을 끝내고
            // 주인일 수 있는 요청을 모두 뺀다).
            const sw_unsure = r.sw and r.responded and !swUnique(t, i, &r);
            var ambiguous = false;
            // 보이는 규칙(프레임·첫 사이트·initiator)이 다른 후보가 이 요청의 창 안에 있다.
            for (cands) |o| if (o != ci and t.cands.items[o].attr != t.cands.items[ci].attr and compatible(&r, &t.cands.items[o])) {
                ambiguous = true;
            };
            // 두 맞추기가 다른 후보를 준다 — CDP 가 보지 못한 같은 열쇠의 CEF 요청이 섞였다(MED-2·F2): 사이의 후보(둘 포함 — 이 요청의 짝일 수
            // 있다)를 모두 `ambiguous` 로 끝내고, 두 맞추기가 다른 짝을 준 다른 요청도 `ambiguous` 로 정한다.
            const split = right != left;
            const lo: usize = left;
            var hi: usize = left;
            if (split) {
                ambiguous = true;
                if (right != none and right > left) hi = right;
                for (reqs, 0..) |j, x| if (j != i and sc.left.items[x] != none and sc.left.items[x] != sc.right.items[x]) {
                    t.cdp.items[j].tainted = true;
                };
            }
            // 맞추기를 의심할 까닭 — 이 요청의 왼쪽 짝이 제 것이라는 보장이 없다.
            var doubt = late or held or pending_split or sw_unsure;
            if (t.drop_overflow_until != 0 and ts - window_before_us <= t.drop_overflow_until) doubt = true;
            // 최종 재검증 D-B: 자리 상한의 묶음 놓기가 놓은 요청의 기록이 이 요청의 창에 들 수 있다(`Tab.cdp_drop_until`).
            if (t.cdp_drop_until != 0 and ts - window_before_us <= t.cdp_drop_until) doubt = true;
            for (t.cdp_drop_marks.items) |m| if (m.url == key.url and ts - window_before_us <= m.t_us) {
                doubt = true;
            };
            for (t.drops[0..t.drop_len]) |d| if (d.url == key.url and d.t_us >= ts - window_before_us and d.t_us <= ts + window_after_us) {
                doubt = true;
            };
            if (doubt or r.tainted or t.cands.items[ci].lost) ambiguous = true;
            if (ambiguous) {
                try sc.drop_cdp.resize(gpa, t.cdp.items.len);
                @memset(sc.drop_cdp.items, false);
            }
            // 재검증 3 차 LB-1: 두 맞추기가 갈렸고 맞추기를 의심할 까닭은 없다 — 끝낼 기록 [lo, hi] 를 제 범위(왼쪽 짝..`rangeEnd`)에 둔 요청만 뺀다.
            // 범위가 겹치지 않는 요청은 제 기록이 제 범위 안이니(왼쪽 짝 ≤ 제 기록 ≤ 오른쪽 짝 — 두 맞추기의 뜻) 끝내는 기록의 주인이 아니다. 뺀
            // 요청의 범위의 남은 기록은 끝내지 않는다(그 범위 끝은 아직 알려지지 않은 요청의 기록일 수 있다 — 끝내면 그 요청이 남의 기록을 가져갔다,
            // 퍼즈) — 짝 없이 시한에 `ambiguous` 로 끝난다(`hint`). 전에는(재검증 2–9 회차) 끝내는 기록을 창에 둔 요청을 모두 뺐다 — 같은 주소의 촘촘한
            // 무리에서 판정 하나가 무리 전체의 본문을 잃게 했다(검증 LB-1).
            if (split and !doubt) self.markRangeOwners(t, i, lo, hi);
            // 끝낼 사이의 후보는 번호로 적어 둔다(판정이 목록을 바꾼다).
            const extra_lo = if (split) lo else 0;
            const extra_hi = if (split) hi + 1 else 0;
            sc.extra.clearRetainingCapacity();
            for (cands[extra_lo..extra_hi]) |x| if (x != ci) try sc.extra.append(gpa, t.cands.items[x].request);
            // 재검증 4 차 뒤 R6: 워커 갈래의 짝이 하나로 정해지지 않으면 이 요청과 짝일 수 있는 같은 열쇠의 기록을 모두 함께 끝낸다.
            sc.sw_recs.clearRetainingCapacity();
            if (sw_unsure) for (cands, 0..) |x, p| if (x != ci and (p < extra_lo or p >= extra_hi) and compatible(&r, &t.cands.items[x])) {
                try sc.extra.append(gpa, t.cands.items[x].request);
                try sc.sw_recs.append(gpa, x);
            };
            const cand = t.cands.items[ci];
            if (ambiguous and doubt) {
                // 맞추기를 의심한다 — 끝내는 기록(이 요청의 짝과 사이 후보)의 주인일 수 있는 요청을 모두 뺀다(재검증 2–9 회차 WB 의 규칙).
                try sc.recs.resize(gpa, extra_hi - extra_lo + 1);
                for (cands[extra_lo..extra_hi], 0..) |x, n| sc.recs.items[n] = x;
                sc.recs.items[extra_hi - extra_lo] = ci;
                try sc.recs.appendSlice(gpa, sc.sw_recs.items);
                try self.retireOwnersOf(gpa, t, sc.recs.items);
            }
            _ = t.cdp.orderedRemove(i);
            // `drop_cdp` 는 자리로 적었다 — 빼낸 요청 뒤의 자리를 한 칸 당긴다.
            if (ambiguous and i < sc.drop_cdp.items.len) {
                std.mem.copyForwards(bool, sc.drop_cdp.items[i .. sc.drop_cdp.items.len - 1], sc.drop_cdp.items[i + 1 ..]);
                sc.drop_cdp.items.len -= 1;
            }
            try self.decide(gpa, t, ci, cand, r, ambiguous, now_us);
            for (sc.extra.items) |req| for (t.cands.items, 0..) |c, x| if (c.request == req) {
                try self.emit(gpa, .{ .end = .{ .browser = t.browser, .session = t.session, .request = req, .state = .ambiguous, .flags = .{ .credentialed = c.cef_credentialed } } });
                _ = t.cands.orderedRemove(x);
                break;
            };
            if (ambiguous) self.dropRetired(t);
            return;
        }
    }

    /// 재검증 2–9 회차 WB: CDP 요청 `o` 가 짝 없는 기록 `c` 의 주인일 수 있는가 — `compatible`(자기 기록은 늘 그렇다: 창 안, 응답 앞에 시작,
    /// 성공한 요청이면 실패로 끝나지 않은 기록, abort 면 성공으로 끝나지 않은 기록). 다만 성공으로 끝난 요청의 기록은 그 끝 무렵에 CEF 끝도
    /// 왔다(CEF 의 끝은 브라우저 프로세스에서 렌더러의 `loadingFinished` 보다 먼저다) — 물 높이가 그 끝 + `end_slack_us` 를 넘었는데 아직 끝나지
    /// 않은 기록은 그 요청의 것이 아니다(다시 시작은 실측이 달라 보지 않는다).
    fn mayOwn(self: *const Table, o: *const Cdp, c: *const Candidate) bool {
        if (!compatible(o, c)) return false;
        if (o.state == .finished and o.restart_ts_us == 0 and c.ended_at == 0 and self.cef_seen_us > o.done_at + end_slack_us) return false;
        return true;
    }

    /// 끝낼 기록(`scratch.drop_cand` 참)과 요청을 (열쇠, 시각) 차례로 정렬한다(`scratch.all_cands`·`all_reqs` — 응답 전이면 두 서비스 워커 갈래
    /// 모두). 끝낼 기록이 없으면 거짓.
    ///
    /// 재검증 3 차 PF-1: 요청은 끝낼 기록이 있는 열쇠의 것만 모은다(기록의 정렬된 목록에서 이분 찾기) — 전에는 부를 때마다 탭의 열린 요청을 모두
    /// 정렬해(응답 전이면 두 번) 모호한 판정·후보 상한마다 Debug 9–27 ms 였다(검증 C2·C5 — 4096 개). 이제 요청 수만큼 훑고 그 열쇠의 것만 정렬한다.
    fn sortForOwners(self: *Table, gpa: std.mem.Allocator, t: *Tab) std.mem.Allocator.Error!bool {
        const sc = &self.scratch;
        sc.all_cands.clearRetainingCapacity();
        for (t.cands.items, 0..) |c, ci| if (sc.drop_cand.items[ci]) try sc.all_cands.append(gpa, .{ .url = c.key.url, .method = c.key.method, .sw = c.key.sw, .t = c.t_io_us, .idx = ci });
        if (sc.all_cands.items.len == 0) return false;
        std.mem.sort(GroupItem, sc.all_cands.items, {}, GroupItem.lessThan);
        sc.all_reqs.clearRetainingCapacity();
        const cd = sc.all_cands.items;
        // 끝낼 기록이 한 열쇠뿐이면(후보 상한·A1 시한 끝 — 대개 그렇다) 주소부터 견준다.
        const one = cd[0].group(cd[cd.len - 1]) == .eq;
        for (t.cdp.items, 0..) |o, j| {
            if (one and (o.key_url != cd[0].url or o.key_method != cd[0].method)) continue;
            if (o.gone or o.state == .cached or o.prefetch or !o.has_key or o.sw_off_network) continue;
            for ([_]bool{ false, true }) |sw| {
                if (o.sw != sw and o.responded) continue;
                const x: GroupItem = .{ .url = o.key_url, .method = o.key_method, .sw = sw, .t = o.anchor(), .idx = j };
                const p = GroupItem.lowerBound(cd, .{ .url = x.url, .method = x.method, .sw = x.sw, .t = std.math.minInt(i64), .idx = 0 });
                if (p == cd.len or cd[p].group(x) != .eq) continue;
                try sc.all_reqs.append(gpa, x);
            }
        }
        std.mem.sort(GroupItem, sc.all_reqs.items, {}, GroupItem.lessThan);
        return true;
    }

    /// 재검증 3 차 PF-1: 요청 `o` 와 짝일 수 있는 기록의 IO 시각 상한 — 창 끝, 응답을 봤으면 그 응답 때, 응답 없이 성공으로 끝났으면 그 끝
    /// (`compatible` 의 시각 검사와 같다 — 다시 시작은 창 끝). 주인 찾기의 훑기를 여기서 멈춘다 — 전에는 창(2 초) 끝까지 훑어, 응답 뒤에 시작한
    /// 같은 주소 기록 2048 개가 한꺼번에 끝나면 한 주기에 요청 × 기록(검증 C1 — Debug 97 ms)이었다.
    fn ioUpper(o: *const Cdp) i64 {
        const end = o.anchor() + window_after_us;
        if (o.restart_ts_us != 0) return end;
        if (o.responded_at != 0) return @min(end, o.responded_at);
        if (o.state == .finished) return @min(end, o.done_at);
        return end;
    }

    /// 요청 `x` 의 창에 든, 끝낼 기록(`drop_cand` 참) 가운데 `x` 가 주인일 수 있는 첫 것(`all_cands` 자리) — 없으면 null.
    fn firstOwned(self: *const Table, t: *const Tab, x: GroupItem) ?usize {
        const sc = &self.scratch;
        const cd = sc.all_cands.items;
        const top = ioUpper(&t.cdp.items[x.idx]);
        var p = GroupItem.lowerBound(cd, .{ .url = x.url, .method = x.method, .sw = x.sw, .t = x.t - window_before_us, .idx = 0 });
        while (p < cd.len and cd[p].group(x) == .eq and cd[p].t <= top) : (p += 1) {
            if (sc.drop_cand.items[cd[p].idx] and self.mayOwn(&t.cdp.items[x.idx], &t.cands.items[cd[p].idx])) return p;
        }
        return null;
    }

    /// 재검증 2–9 회차 WB: 지금 끝내는 짝 없는 기록(`t.cands` 자리 `recs`)의 **주인일 수 있는** CDP 요청(`mayOwn`)을 모두 `scratch.drop_cdp` 에
    /// 적는다(`dropRetired` 가 뺀다). 자기 기록은 늘 그 요청의 `mayOwn` 이라 진짜 주인은 꼭 든다. 요청마다 창의 첫 기록을 이분 찾기로 본다 —
    /// 최종 재검증의 `retireOwner`(끊긴 기록마다 `matchLeft`)는 새 문서로 옮길 때 같은 주소 4095 개에 한 주기 ReleaseFast 153 ms·Debug 1.5 s
    /// 였다(검증 R8-b).
    fn retireOwnersOf(self: *Table, gpa: std.mem.Allocator, t: *Tab, recs: []const usize) std.mem.Allocator.Error!void {
        const sc = &self.scratch;
        try sc.drop_cand.resize(gpa, t.cands.items.len);
        @memset(sc.drop_cand.items, false);
        for (recs) |ci| if (!t.cands.items[ci].claimed) {
            sc.drop_cand.items[ci] = true;
        };
        try sc.drop_cdp.resize(gpa, t.cdp.items.len);
        @memset(sc.drop_cdp.items, false);
        if (!try self.sortForOwners(gpa, t)) return;
        for (sc.all_reqs.items) |x| if (self.firstOwned(t, x) != null) {
            sc.drop_cdp.items[x.idx] = true;
        };
    }

    /// `scratch.drop_cdp` 의 요청을 맞추기에서 뺀다 — 한 번 훑어 남길 것만 모은다(차례는 그대로). 그 요청은 본문을 부르지 않는다(늦게 온 CDP
    /// 사건은 자리가 없어 버린다). 표는 그 뒤로 `t.cdp` 를 바꾸지 않은 채 불러야 한다(자리로 적었다).
    fn dropRetired(self: *Table, t: *Tab) void {
        const marks = self.scratch.drop_cdp.items;
        var kept: usize = 0;
        for (0..t.cdp.items.len) |j| {
            if (j < marks.len and marks[j]) continue;
            if (kept != j) t.cdp.items[kept] = t.cdp.items[j];
            kept += 1;
        }
        t.cdp.shrinkRetainingCapacity(kept);
        @memset(marks, false);
    }

    /// 짝 없는 기록의 끝(`tickAt`): N1 끊김(새 문서 앞에 시작해 CEF 가 취소·실패로 끝낸 기록 — `cef_grace_us` 뒤 `unavailable`)과 짝 없는 시한
    /// (`unclaimed_expiry_us` — 새 문서 앞의 것은 `unavailable`, 그 밖은 `unmatched`).
    ///
    /// **재검증 2–9 회차 WB(규칙)**: 짝을 정하지 않고(`decide` 의 본문·실패 끝이 아니게) 기록을 끝내거나 지우는 모든 길은 그 기록의 **주인일 수
    /// 있는** CDP 요청(`mayOwn`)을 모두 함께 맞추기에서 뺀다. 기록만 지우면 주인은 차례에 남아 다음 같은 열쇠의 기록(다른 요청의 것)을
    /// 가져가고, 왼쪽·오른쪽 맞추기가 함께 한 칸씩 밀려 뒤 요청의 본문이 남의 기록에 붙는다(WB-1·WB-2 — 둘이 함께 밀리니 갈림으로 보이지
    /// 않는다). 왼쪽 맞추기의 짝만 빼면 모자랐다 — 응답 없이 실패한 요청은 기록을 집되 차례를 밀지 않고(`taken`), CDP 가 보지 못한 워커의
    /// 기록이 앞에 끼면 진짜 주인의 왼쪽 짝은 다른 기록이다(퍼즈). 주인일 수 있는 요청을 모두 빼면 남는 것은 「제 기록이 없는 요청」 이 아니라
    /// 「주인이 없는 기록」 뿐이고, 남는 기록은 두 맞추기를 가르거나(MED-2 — `ambiguous`) 짝 없는 시한으로 끝난다 — 틀린 본문이 아니라 잃은
    /// 본문이다. 길: 이 함수(N1 끊김·짝 없는 시한 — 전에는 끊김만 왼쪽 짝 하나를 놓았다), `tryDecide` 의 모호한 판정(그 짝과 MED-2 사이 후보)·A1
    /// 시한 끝(`!definite`), `cefBegin` 의 후보 상한 `busy`. 끝나 판정을 기다리는 요청이 주인일 수 있으면 이번에 끝내지 않는다 — 그 판정이 끝을
    /// 낸다. `restartCand` 는 기록을 같은 요청의 새 시도로 바꾼다(주인은 다시 시작의 규칙으로 그 시도와 짓는다 — `feasible`). 받으러 간
    /// 기록(`claimed`)은 맞추기에 없다.
    fn expireRecords(self: *Table, gpa: std.mem.Allocator, t: *Tab, now_us: i64) std.mem.Allocator.Error!void {
        const sc = &self.scratch;
        try sc.drop_cand.resize(gpa, t.cands.items.len);
        @memset(sc.drop_cand.items, false);
        var any = false;
        for (t.cands.items, 0..) |cand, ci| {
            // N1: 새 문서 앞에 시작한 요청(`old_doc`)은 앞 문서와 함께 떠났다 — CDP 는 그 끝을 보내지 않는다(문서가 없다). CEF 가 취소·실패로
            // 끝냈으면 그 실패가 CDP 로 오는 것(`request_failed`·`partial` — 앞의 `decidePending` 이 정한다)을 기다린 뒤(CEF 끝에서
            // `cef_grace_us`) 곧 `unavailable`. CEF 가 성공으로 끝냈으면(문서가 떠난 뒤 서버가 본문을 다 보냈다 — 실측 20 개 중 2) CDP 끝이 늦을 수
            // 있어 짝 없는 시한까지 기다리고 그때 `unmatched` 가 아니라 `unavailable`. 결과를 모르는 후보(`lost` — 기록이 버려졌다)는 그대로
            // `unmatched`.
            const old_doc = !cand.lost and t.doc_at != 0 and cand.t_io_us < t.doc_at;
            const cut = old_doc and cand.cef_failed and now_us - cand.ended_at >= cef_grace_us;
            if (!cand.claimed and cand.ended_at != 0 and (cut or now_us - cand.ended_at >= unclaimed_expiry_us)) {
                sc.drop_cand.items[ci] = true;
                any = true;
            }
        }
        if (!any) return;
        try sc.drop_cdp.resize(gpa, t.cdp.items.len);
        @memset(sc.drop_cdp.items, false);
        if (try self.sortForOwners(gpa, t)) {
            const cd = sc.all_cands.items;
            // 미룬다: 끝나 판정을 기다리는 요청이 주인일 수 있는 기록(그 판정이 끝을 낸다 — 시한 안에 꼭 온다), 그리고 짝 없는 시한 전의 N1 끊김
            // (취소된 앞 문서 기록)에 주인일 수 있는 열린 요청이 둘 이상인 기록 — 누구의 것인지 모르니 지우지 않고 둔다: 맞추기의 차례는 그대로이고,
            // 성공으로 끝나는 요청은 취소된 기록의 주인이 아니어서 수가 준다(검증 R5-1 꼴: 앞 문서의 abort 와 그 다시 받기 — 다시 받기가 끝나면
            // abort 하나가 남는다). 시한(`unclaimed_expiry_us`)에는 남은 주인을 모두 뺀다.
            // (가) 끝나 판정을 기다리는 요청 — 대개 몇 없다 — 의 창에 든 기록.
            for (sc.all_reqs.items) |x| {
                const o = &t.cdp.items[x.idx];
                if (o.state == .open) continue;
                const top = ioUpper(o);
                var p = GroupItem.lowerBound(cd, .{ .url = x.url, .method = x.method, .sw = x.sw, .t = x.t - window_before_us, .idx = 0 });
                while (p < cd.len and cd[p].group(x) == .eq and cd[p].t <= top) : (p += 1) {
                    const c = &t.cands.items[cd[p].idx];
                    // 재검증 3 차 뒤: 미루기에도 끝이 있다(`record_hard_expiry_us`) — 판정이 어떤 까닭으로 오지 않아도 기록은 끝난다(끝 없는 `pending` 을
                    // 남기지 않는다 — 스모크 w9d-body 의 끝나지 않은 본문을 막는 그물).
                    if (now_us - c.ended_at >= record_hard_expiry_us) continue;
                    if (self.mayOwn(o, c)) sc.drop_cand.items[cd[p].idx] = false;
                }
            }
            // (나) 시한 전의 끊김마다 열린 주인일 수 있는 요청을 둘까지 센다(기록의 창 — 기준 시각이 `[IO − window_after_us, IO + window_before_us]`).
            const rq = sc.all_reqs.items;
            for (cd) |c| {
                const ci = c.idx;
                if (!sc.drop_cand.items[ci] or now_us - t.cands.items[ci].ended_at >= unclaimed_expiry_us) continue;
                var n: u8 = 0;
                var q = GroupItem.lowerBound(rq, .{ .url = c.url, .method = c.method, .sw = c.sw, .t = c.t - window_after_us, .idx = 0 });
                while (q < rq.len and rq[q].group(c) == .eq and rq[q].t <= c.t + window_before_us and n < 2) : (q += 1) {
                    const o = &t.cdp.items[rq[q].idx];
                    if (o.state == .open and self.mayOwn(o, &t.cands.items[ci])) n += 1;
                }
                if (n >= 2) sc.drop_cand.items[ci] = false;
            }
            // (다) 지금 끝내는 기록만 남겨(차례 그대로) 열린 요청마다 창의 첫 주인일 수 있는 기록을 찾는다 — 그런 요청을 모두 놓는다.
            var m: usize = 0;
            for (0..cd.len) |p| if (sc.drop_cand.items[cd[p].idx]) {
                cd[m] = cd[p];
                m += 1;
            };
            sc.all_cands.shrinkRetainingCapacity(m);
            for (rq) |x| if (t.cdp.items[x.idx].state == .open and self.firstOwned(t, x) != null) {
                sc.drop_cdp.items[x.idx] = true;
            };
        }
        var kept: usize = 0;
        for (0..t.cands.items.len) |ci| {
            const cand = t.cands.items[ci];
            if (sc.drop_cand.items[ci]) {
                const old_doc = !cand.lost and t.doc_at != 0 and cand.t_io_us < t.doc_at;
                // 재검증 3 차 N-3: 본문 없이 끝난 판정이 집었거나 쥘 수 있던 요청이 빠진 기록은 `ambiguous`(`hint`) — `unmatched` 는 「다른 프로세스
                // iframe·worker」 로 읽힌다.
                const state: State = if (old_doc) .unavailable else if (cand.hint) .ambiguous else .unmatched;
                try self.emit(gpa, .{ .end = .{ .browser = t.browser, .session = t.session, .request = cand.request, .state = state, .flags = .{ .credentialed = cand.cef_credentialed } } });
                continue;
            }
            t.cands.items[kept] = cand;
            kept += 1;
        }
        t.cands.shrinkRetainingCapacity(kept);
        self.dropRetired(t);
    }

    /// 짝지은 요청의 판정 — 끝내거나(본문 없음) 받으러 간다.
    fn decide(self: *Table, gpa: std.mem.Allocator, t: *Tab, ci: usize, cand: Candidate, r: Cdp, ambiguous: bool, now_us: i64) std.mem.Allocator.Error!void {
        // 실린 자격 증명(UB1): ExtraInfo 가 알렸거나, 보낸 홉마다의 것이 다 오지 않았으면 실린 것으로 친다(J12 — 서비스 워커·메모리 캐시엔 없다;
        // W9d② 적대 리뷰 1 회차 LOW-3 — 뒤 홉의 것이 늦을 수 있다), CEF 헤더에 있으면 실렸다.
        const cred = r.credentialed or r.extras < r.sends or cand.cef_credentialed;
        var flags: Flags = .{ .credentialed = cred };
        const end = struct {
            fn f(s: *Table, g: std.mem.Allocator, tab: *Tab, idx: usize, request: u64, state: State, fl: Flags, decoded: u64) std.mem.Allocator.Error!void {
                try s.emit(g, .{ .end = .{ .browser = tab.browser, .session = tab.session, .request = request, .state = state, .flags = fl, .decoded = decoded } });
                _ = tab.cands.orderedRemove(idx);
            }
        }.f;
        if (ambiguous) return end(self, gpa, t, ci, cand.request, .ambiguous, flags, r.data_bytes);
        if (r.state == .failed) return end(self, gpa, t, ci, cand.request, if (r.data_bytes > 0) .partial else .request_failed, flags, r.data_bytes);
        if (!cand.covered) return end(self, gpa, t, ci, cand.request, .not_covered, flags, r.data_bytes);
        const class = mimeClass(r.mimeSlice());
        if (class == .binary) return end(self, gpa, t, ci, cand.request, if (r.data_bytes != 0) .not_text else if (cand.cef_received != 0) .unavailable else .no_body, flags, r.data_bytes);
        if (r.data_bytes > msg.max_net_body_bytes) return end(self, gpa, t, ci, cand.request, .over_cap, flags, r.data_bytes);
        flags = .{ .credentialed = cred };
        // 받으러 간다 — 자리가 없으면 잠시 기다린다(넘치면 busy).
        t.cands.items[ci].claimed = true;
        var w: Waiting = .{ .request = cand.request, .rid = r.rid, .since = now_us, .bytes = r.data_bytes, .charset = r.charset, .credentialed = cred, .low = r.low, .res_kind = r.res_kind };
        @memcpy(w.mime[0..r.mime_len], r.mime[0..r.mime_len]);
        w.mime_len = r.mime_len;
        // 5 회차 A2: 기다림이 찼으면(탭 128·전체 512) 차례가 뒤인 가장 새 기다림을 내주고(앞 차례가 들어올 때만), 그것도 없으면 이것이 `busy`.
        if (t.waiting.items.len >= max_waiting_per_tab or self.waitingTotal() >= max_waiting) {
            const victim: ?usize = if (w.low) null else lastLow(t);
            if (victim) |vi| {
                const v = t.waiting.orderedRemove(vi);
                try self.emit(gpa, .{ .end = .{ .browser = t.browser, .session = t.session, .request = v.request, .state = .busy, .flags = .{ .credentialed = v.credentialed }, .decoded = v.bytes } });
                self.removeCand(t, v.request);
            } else {
                try self.emit(gpa, .{ .end = .{ .browser = t.browser, .session = t.session, .request = cand.request, .state = .busy, .flags = flags, .decoded = r.data_bytes } });
                self.removeCand(t, cand.request);
                return;
            }
        }
        // 차례: 앞 차례는 앞 차례끼리 들어온 차례로, 뒤 차례는 그 뒤에.
        const at = if (w.low) t.waiting.items.len else for (t.waiting.items, 0..) |x, k| {
            if (x.low) break k;
        } else t.waiting.items.len;
        try t.waiting.insert(gpa, at, w);
        try self.pump(gpa, t, now_us);
    }

    /// 모든 탭의 기다림 수(5 회차 A2 — 전체 상한).
    fn waitingTotal(self: *const Table) usize {
        var n: usize = 0;
        for (&self.tabs) |*t| n += t.waiting.items.len;
        return n;
    }

    /// 그 탭의 기다림 중 차례가 뒤인 가장 새것(맨 뒤 — 뒤 차례는 늘 끝에 모여 있다). 없으면 null.
    fn lastLow(t: *const Tab) ?usize {
        const n = t.waiting.items.len;
        if (n == 0 or !t.waiting.items[n - 1].low) return null;
        return n - 1;
    }

    fn removeCand(self: *Table, t: *Tab, request: u64) void {
        _ = self;
        for (t.cands.items, 0..) |c, i| if (c.request == request) {
            _ = t.cands.orderedRemove(i);
            return;
        };
    }

    /// 기다리는 본문을 자리·양동이가 허락하는 만큼 보낸다(만료된 것은 `busy`). 기다림은 차례(앞·뒤)로 놓여 들어온 때의 차례가 아니다 —
    /// 만료는 모두 훑는다(5 회차 A2).
    fn pump(self: *Table, gpa: std.mem.Allocator, t: *Tab, now_us: i64) std.mem.Allocator.Error!void {
        var k: usize = 0;
        while (k < t.waiting.items.len) {
            const w = t.waiting.items[k];
            if (now_us - w.since <= waiting_expiry_us) {
                k += 1;
                continue;
            }
            try self.emit(gpa, .{ .end = .{ .browser = t.browser, .session = t.session, .request = w.request, .state = .busy, .flags = .{ .credentialed = w.credentialed }, .decoded = w.bytes } });
            self.removeCand(t, w.request);
            _ = t.waiting.orderedRemove(k);
        }
        while (t.waiting.items.len > 0) {
            const w = t.waiting.items[0];
            if (t.inflight >= max_inflight_per_tab or self.inflight.items.len >= max_inflight) return;
            t.bodies.refill(tab_bodies_per_s, tab_bodies_burst, now_us);
            t.bytes.refill(tab_bytes_per_s, tab_bytes_per_s, now_us);
            self.global_bytes.refill(global_bytes_per_s, global_bytes_per_s, now_us);
            const need: f64 = @floatFromInt(@max(w.bytes, 1));
            if (t.bodies.tokens < 1 or t.bytes.tokens < need or self.global_bytes.tokens < need) return;
            t.bodies.tokens -= 1;
            t.bytes.tokens -= need;
            self.global_bytes.tokens -= need;
            const id = self.next_id;
            self.next_id = if (self.next_id + 1 >= id_end) id_base else self.next_id + 1;
            var f: Inflight = .{ .id = id, .browser = t.browser, .session = t.session, .request = w.request, .decoded = w.bytes, .charset = w.charset, .res_kind = w.res_kind, .credentialed = w.credentialed, .sent_at = @max(now_us, 1) };
            @memcpy(f.mime[0..w.mime_len], w.mime[0..w.mime_len]);
            f.mime_len = w.mime_len;
            try self.inflight.append(gpa, f);
            t.inflight += 1;
            _ = t.waiting.orderedRemove(0);
            try self.emit(gpa, .{ .fetch = .{ .browser = t.browser, .id = id, .rid = w.rid } });
        }
    }

    /// 우리 대역의 결과가 왔다 — 보낸 호출이면 꺼내 준다(세대가 바뀌어 버린 호출이면 null — 늦은 답은 버린다). 부른 쪽이 풀어 보낸 뒤
    /// `bodyDone` 을 부른다.
    pub fn takeInflight(self: *Table, id: i32) ?Inflight {
        for (self.inflight.items, 0..) |f, i| if (f.id == id) {
            _ = self.inflight.swapRemove(i);
            if (self.tabOf(f.browser)) |t| {
                t.inflight -|= 1;
                if (t.session != f.session) return null;
            } else return null;
            return f;
        };
        return null;
    }

    /// W9d② 적대 리뷰 4 회차 N1: 받은 결과를 푼 상태 — CDP 가 빈 본문(`no_body`)을 줬는데 CEF 끝이 받은 바이트를 알렸으면 `unavailable`(서버는
    /// 바이트를 보냈다 — `<link rel=prefetch>` 는 CDP 에 `dataReceived` 도 본문도 없었다). CEF 끝이 결과보다 늦으면(10 ms 묶음) 아직 모른다 —
    /// 그때는 `no_body` 그대로다(알고 둔 틈). 부른 쪽은 `bodyDone`(후보를 지운다) 전에 부른다.
    pub fn emptyBodyState(self: *Table, f: Inflight, state: State) State {
        if (state != .no_body) return state;
        const t = self.tabOf(f.browser) orelse return state;
        for (t.cands.items) |c| if (c.request == f.request) return if (c.cef_received != 0) .unavailable else state;
        return state;
    }

    /// 받은 본문을 보냈거나 끝냈다 — 후보를 지우고 다음 기다림을 보낸다.
    pub fn bodyDone(self: *Table, gpa: std.mem.Allocator, f: Inflight, now_us: i64) std.mem.Allocator.Error!void {
        const t = self.tabOf(f.browser) orelse return;
        self.removeCand(t, f.request);
        try self.pump(gpa, t, now_us);
    }

    /// W9d② 적대 리뷰 3 회차 P1: CEF 기록이 IO 시각 `seen_us` 까지 모두 왔다(`network.zig` 가 IO 상자를 비운 뒤) — 물 높이를 올리고 그것을
    /// 기다리던 CDP 끝을 다시 본다(주기 task 를 기다리지 않는다 — 다음 묶음이 오면 곧 정한다).
    pub fn cefSeen(self: *Table, gpa: std.mem.Allocator, seen_us: i64, now_us: i64) std.mem.Allocator.Error!void {
        if (seen_us <= self.cef_seen_us) return;
        self.cef_seen_us = seen_us;
        for (&self.tabs) |*t| {
            if (t.browser == 0 or t.session == 0) continue;
            try self.decidePending(gpa, t, now_us);
        }
    }

    /// 끝난 CDP 요청(짝을 기다린다)을 앞에서부터 다시 본다.
    fn decidePending(self: *Table, gpa: std.mem.Allocator, t: *Tab, now_us: i64) std.mem.Allocator.Error!void {
        const sc = &self.scratch;
        sc.cache_on = true;
        sc.cache_valid = false;
        defer {
            sc.cache_on = false;
            sc.cache_valid = false;
        }
        // 바퀴 끝에 짝 없이 놓은 요청(`gone`)을 한 번에 지운다(차례는 그대로).
        defer {
            var kept: usize = 0;
            for (0..t.cdp.items.len) |j| {
                if (t.cdp.items[j].gone) continue;
                if (kept != j) t.cdp.items[kept] = t.cdp.items[j];
                kept += 1;
            }
            t.cdp.shrinkRetainingCapacity(kept);
        }
        var i: usize = 0;
        while (i < t.cdp.items.len) {
            const before = t.cdp.items.len;
            const cands_before = t.cands.items.len;
            const acts_before = self.actions.items.len;
            sc.removed_bare = std.math.maxInt(usize);
            const o = &t.cdp.items[i];
            if (!o.gone and (o.state == .finished or o.state == .failed)) try self.tryDecide(gpa, t, i, now_us);
            // 표가 바뀌었으면 맞추기를 다시 한다(판정·놓기·뺀 요청 — 끝을 냈거나 목록이 줄었다; 짝 하나를 빼도 다른 요청의 오른쪽 짝이 옮길 수 있다).
            // 재검증 3 차 뒤 PF-2: 맞추기에서 아무것도 갖지 않은 요청 하나만 놓았으면 다른 요청의 짝은 그대로다 — 그 자리만 지운다(검증 PF-2: CEF 에
            // 닿지 않은 abort 수천 개가 한 주기에 하나씩 놓이며 그때마다 같은 주소 무리를 다시 맞췄다 — ReleaseFast 한 주기 0.6–1.1 s).
            const same = t.cdp.items.len == before and t.cands.items.len == cands_before and self.actions.items.len == acts_before;
            if (sc.removed_bare != std.math.maxInt(usize)) {
                if (same and sc.cache_valid and sc.removed_bare < t.cdp.items.len) self.dropBareFromCache(sc.removed_bare) else sc.cache_valid = false;
            } else if (!same) sc.cache_valid = false;
            if (t.cdp.items.len == before) i += 1;
        }
    }

    /// 재검증 3 차 뒤 PF-2: 나눠 쓰는 맞추기에서 `t.cdp` 자리 `gone` 의 요청을 지운다(그 요청은 어느 맞추기에서도 기록을 갖지 않았다 — 왼쪽·
    /// 오른쪽·가장 이를·늦을 수 있는 짝이 모두 없다(`tryDecide` 가 확인했다) — 다른 요청의 짝과 기록 쪽 배열은 그대로). 그 요청은 `gone` 으로
    /// 남아 있다(`t.cdp` 자리는 그대로) — 맞추기 자리만 한 칸 당긴다.
    fn dropBareFromCache(self: *Table, gone: usize) void {
        const sc = &self.scratch;
        var q: usize = std.math.maxInt(usize);
        for (sc.reqs.items, 0..) |j, x| if (j == gone) {
            q = x;
        };
        if (q == std.math.maxInt(usize)) {
            sc.cache_valid = false;
            return;
        }
        _ = sc.reqs.orderedRemove(q);
        // 재검증 4 차 뒤 R19-1: 자리 색인·`held` 후보·WB-3 자리도 한 칸 당긴다(지운 요청은 왼쪽 짝이 없어 그 둘에 들지 않았다).
        sc.pos_of.items[gone] = std.math.maxInt(usize);
        for (sc.reqs.items[q..], q..) |j, x| sc.pos_of.items[j] = x;
        for (sc.bare_held.items) |*bq| if (bq.* > q) {
            bq.* -= 1;
        };
        if (sc.first_cross != std.math.maxInt(usize) and sc.first_cross > q) sc.first_cross -= 1;
        _ = sc.left.orderedRemove(q);
        _ = sc.right.orderedRemove(q);
        _ = sc.right_fut.orderedRemove(q);
        _ = sc.left_lo.orderedRemove(q);
        _ = sc.lo_pos.orderedRemove(q);
        _ = sc.pend.orderedRemove(q);
        if (sc.young_n != std.math.maxInt(usize)) for (sc.right_young[0..sc.young_n]) |*a| {
            _ = a.orderedRemove(q);
        };
        var k: usize = 0;
        while (k < sc.unpaired.items.len) {
            const kq = &sc.unpaired.items[k];
            if (kq.* == q) {
                _ = sc.unpaired.orderedRemove(k);
                continue;
            }
            if (kq.* > q) kq.* -= 1;
            k += 1;
        }
    }

    /// 주기적으로 — IO 상자가 비었을 때(시험·상자가 빈 때 — 지금까지의 CEF 기록이 모두 왔다). 제품은 물 높이를 주는 `tickAt` 을 부른다.
    pub fn tick(self: *Table, gpa: std.mem.Allocator, now_us: i64) std.mem.Allocator.Error!void {
        return self.tickAt(gpa, now_us, now_us);
    }

    /// 주기적으로(UI task) — 물 높이(`seen_us` — CEF 기록이 이 IO 시각까지 왔다)를 올리고, 답이 오지 않는 본문 호출을 끝내고(S1), 기다리던
    /// CDP 끝의 짝을 다시 보고, 짝 없는 CEF 요청을 `unmatched` 로 정하고, 기다리는 본문을 보낸다.
    pub fn tickAt(self: *Table, gpa: std.mem.Allocator, now_us: i64, seen_us: i64) std.mem.Allocator.Error!void {
        self.cef_seen_us = @max(self.cef_seen_us, seen_us);
        // S1: 답이 시한 안에 오지 않은 본문 호출 — `unavailable` 로 끝내고 자리를 놓는다(늦은 답은 `takeInflight` 가 못 찾아 버린다).
        var f: usize = 0;
        while (f < self.inflight.items.len) {
            const x = self.inflight.items[f];
            if (now_us - x.sent_at < fetch_timeout_us) {
                f += 1;
                continue;
            }
            _ = self.inflight.swapRemove(f);
            const t = self.tabOf(x.browser) orelse continue;
            t.inflight -|= 1;
            if (t.session != x.session) continue; // 끄거나 다시 켠 뒤의 옛 호출 — 그 끝은 그때 냈다
            try self.emit(gpa, .{ .end = .{ .browser = x.browser, .session = x.session, .request = x.request, .state = .unavailable, .flags = .{ .credentialed = x.credentialed }, .decoded = x.decoded } });
            self.removeCand(t, x.request);
        }
        for (&self.tabs) |*t| {
            if (t.browser == 0 or t.session == 0) continue;
            // ExtraInfo 만 온 자리(열쇠 없음)는 시한 뒤 놓는다(LOW-3 — 이미 정한 요청의 늦은 ExtraInfo 는 다시 짝이 될 일이 없다).
            var p: usize = 0;
            while (p < t.cdp.items.len) {
                const o = t.cdp.items[p];
                if (!o.has_key and now_us - o.placed_at >= placeholder_expiry_us) {
                    _ = t.cdp.orderedRemove(p);
                    continue;
                }
                p += 1;
            }
            // 끝난 CDP 요청(짝을 기다린다) — 앞에서부터.
            try self.decidePending(gpa, t, now_us);
            // 짝 없는 기록의 끝 — 그 기록의 주인(왼쪽 짝인 열린 CDP 요청)도 함께 뺀다(재검증 2–9 회차 WB — `expireRecords`).
            try self.expireRecords(gpa, t, now_us);
            // D3: 끝이 오지 않을 열린 CDP 요청(창이 지났고 짝이 될 수 없다 — `cdpWindowPassed`·`cdpMayPair`)을 놓는다. 후보를 끝낸 뒤에 본다(방금
            // 끝난 후보가 그 짝이었을 수 있다). 한 번 훑으며 남길 것만 앞으로 모은다(많이 쌓였을 때 하나씩 빼면 그때마다 목록을 민다). 차례는 그대로다.
            // 최종 재검증 N-a: 창이 지난 요청이 있을 때만 후보 색인을 만든다(요청마다 후보를 모두 훑지 않는다).
            const any_passed = for (t.cdp.items) |*o| {
                if (self.cdpWindowPassed(o, now_us)) break true;
            } else false;
            if (any_passed) {
                try self.buildCandIndex(gpa, t);
                var kept: usize = 0;
                for (0..t.cdp.items.len) |o| {
                    if (self.cdpWindowPassed(&t.cdp.items[o], now_us) and !self.cdpMayPair(&t.cdp.items[o])) continue;
                    if (kept != o) t.cdp.items[kept] = t.cdp.items[o];
                    kept += 1;
                }
                t.cdp.shrinkRetainingCapacity(kept);
            }
            // 오래된 문 넘김 표지는 잊는다(어떤 창에도 들지 않는다).
            if (t.drop_overflow_until != 0 and now_us - t.drop_overflow_until > window_after_us + unclaimed_expiry_us) t.drop_overflow_until = 0;
            try self.pump(gpa, t, now_us);
        }
    }

    /// 아직 할 일이 있는가(주기 task 를 이어 걸지).
    pub fn busy(self: *const Table) bool {
        for (&self.tabs) |*t| if (t.browser != 0 and (t.cands.items.len > 0 or t.cdp.items.len > 0 or t.waiting.items.len > 0)) return true;
        return self.inflight.items.len > 0;
    }
};

// ── 시험 ────────────────────────────────────────────────────────────────────────────────────────────────

const testing = std.testing;
const gpa_t = testing.allocator;

const H = struct {
    table: Table = .{},
    /// 번호마다 마지막 끝의 상태.
    ended: std.AutoHashMapUnmanaged(u64, State) = .empty,
    /// 번호마다 끝 수와 적은 시작(시도) 수 — 같은 번호로 다시 시작하면 시도가 여럿이다(끝은 시도마다 꼭 하나).
    end_counts: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    attempts: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    ends: usize = 0,
    fetches: std.ArrayList(Action) = .empty,
    paused: usize = 0,
    /// CDP 사건마다 그때까지의 CEF 기록이 모두 왔다고 친다(IO 상자가 빈 때 — 시험이 후보를 사건 차례대로 곧 넘긴다). 제 기록이 CDP 끝보다
    /// 늦게 오는 꼴(W9d② 적대 리뷰 3 회차 P1)을 보는 시험은 끄고 물 높이를 손으로 올린다(`flushed`·`tick`).
    sync: bool = true,

    fn deinit(self: *H) void {
        self.table.deinit(gpa_t);
        self.ended.deinit(gpa_t);
        self.end_counts.deinit(gpa_t);
        self.attempts.deinit(gpa_t);
        self.fetches.deinit(gpa_t);
    }

    /// 끝 하나를 센다 — 그 번호의 적은 시도 수(`cand` 를 거치지 않은 시작은 하나로 친다)보다 많으면 실패(끝은 시도마다 꼭 하나).
    fn noteEnd(self: *H, request: u64, state: State) !void {
        if (g_debug_seed != 0) std.debug.print("    end rec {d} {s}\n", .{ request, @tagName(state) });
        const gop = try self.end_counts.getOrPut(gpa_t, request);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
        if (gop.value_ptr.* > @max(1, self.attempts.get(request) orelse 1)) return error.SecondEnd;
        try self.ended.put(gpa_t, request, state);
        self.ends += 1;
    }

    /// 쌓인 일을 모은다 — 같은 시도에 끝이 둘이면 실패(끝은 꼭 하나).
    fn drain(self: *H) !void {
        var list: std.ArrayList(Action) = .empty;
        defer list.deinit(gpa_t);
        self.table.swapActions(&list);
        for (list.items) |a| switch (a) {
            .end => |e| try self.noteEnd(e.request, e.state),
            .fetch => try self.fetches.append(gpa_t, a),
            .pause => self.paused += 1,
        };
    }

    fn cand(self: *H, browser: BrowserId, request: u64, url: []const u8, t_io: i64, opts: struct { method: []const u8 = "GET", sw: bool = false, attr: u64 = 1, covered: bool = true, cover_pending: bool = false }) !bool {
        const ok = try self.table.cefBegin(gpa_t, browser, .{ .request = request, .key = .{ .url = hashUrl8(url), .method = hashMethod(opts.method), .sw = opts.sw }, .t_io_us = t_io, .attr = opts.attr, .covered = opts.covered, .cover_pending = opts.cover_pending });
        // 앞 시도의 끝(다시 시작)은 이 시작보다 먼저 센다 — sidecar 는 앞 시도의 끝을 이 시작의 `net_begin` 보다 먼저 보낸다.
        try self.drain();
        if (ok) {
            const gop = try self.attempts.getOrPut(gpa_t, request);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
        }
        return ok;
    }

    /// IO 상자를 비웠다 — CEF 기록이 IO 시각 `seen` 까지 모두 왔다(`network.zig` 의 flush 끝).
    fn flushed(self: *H, seen: i64, now: i64) !void {
        try self.table.cefSeen(gpa_t, seen, now);
        try self.drain();
    }

    fn ev(self: *H, browser: BrowserId, e: Event, now: i64) !void {
        if (self.sync) self.table.cef_seen_us = @max(self.table.cef_seen_us, now);
        try self.table.cdpEvent(gpa_t, browser, e, now);
        try self.drain();
    }

    fn sent(self: *H, browser: BrowserId, rid: []const u8, url: []const u8, ts: i64, now: i64) !void {
        try self.ev(browser, .{ .will_be_sent = .{ .rid = rid, .url_hash = hashUrl8(url), .method_hash = hashMethod("GET"), .ts_us = ts } }, now);
        try self.ev(browser, .{ .extra_info = .{ .rid = rid, .credentialed = false } }, now);
    }

    fn respond(self: *H, browser: BrowserId, rid: []const u8, mime: []const u8, bytes: u64, now: i64) !void {
        try self.ev(browser, .{ .response = .{ .rid = rid, .mime = mime, .from_sw = false, .charset = .other } }, now);
        if (bytes > 0) try self.ev(browser, .{ .data = .{ .rid = rid, .bytes = bytes } }, now);
    }

    fn finish(self: *H, browser: BrowserId, rid: []const u8, now: i64) !void {
        try self.ev(browser, .{ .finished = .{ .rid = rid } }, now);
    }

    /// 보낸 호출의 CEF 요청 번호들(차례대로).
    fn fetchedRequests(self: *H, out: []u64) []u64 {
        var n: usize = 0;
        for (self.fetches.items) |a| {
            const id = a.fetch.id;
            for (self.table.inflight.items) |f| if (f.id == id and n < out.len) {
                out[n] = f.request;
                n += 1;
            };
        }
        return out[0..n];
    }
};

test "W9d②: 주소 해시 — UTF-16 과 UTF-8 이 같은 값, 조각(#)은 떼고, 대리 쌍도 같게" {
    const cases = [_][]const u8{ "https://a.test/x?q=1", "https://a.test/한글/😀?x=%ED%95%9C", "http://u:p@a.test/<>\"" };
    for (cases) |s| {
        var u16buf: [256]u16 = undefined;
        const n = try std.unicode.utf8ToUtf16Le(&u16buf, s);
        try testing.expectEqual(hashUrl8(s), hashUrl16(u16buf[0..n]));
    }
    // CEF 는 조각을 싣고 CDP 는 뗀다(J1).
    var b16: [64]u16 = undefined;
    const n = try std.unicode.utf8ToUtf16Le(&b16, "https://a.test/p#frag");
    try testing.expectEqual(hashUrl8("https://a.test/p"), hashUrl16(b16[0..n]));
    try testing.expectEqual(hashUrl8("https://a.test/p#x"), hashUrl8("https://a.test/p"));
    try testing.expect(hashUrl8("https://a.test/p") != hashUrl8("https://a.test/q"));
    // 긴 주소(버퍼 256 을 넘어 여러 번 나눠 넣는다)도 같다.
    var long: [3000]u8 = undefined;
    @memset(&long, 'a');
    @memcpy(long[0..15], "https://a.test/");
    var l16: [3000]u16 = undefined;
    const ln = try std.unicode.utf8ToUtf16Le(&l16, &long);
    try testing.expectEqual(hashUrl8(&long), hashUrl16(l16[0..ln]));
}

test "W9d②: MIME 가르기 — 글(text/*·JSON·XML·JS·+json·+xml), 글 아님(이미지·글꼴·octet-stream·이벤트 흐름), 빈 것은 모른다" {
    for ([_][]const u8{ "text/plain", "TEXT/HTML; charset=utf-8", "application/json", "application/problem+json", "application/xml", "image/svg+xml", "application/javascript", "text/css", "application/x-www-form-urlencoded", "application/ld+json" }) |m| try testing.expectEqual(MimeClass.text, mimeClass(m));
    for ([_][]const u8{ "image/png", "font/woff2", "application/octet-stream", "video/mp4", "application/wasm", "text/event-stream", "application/pdf" }) |m| try testing.expectEqual(MimeClass.binary, mimeClass(m));
    try testing.expectEqual(MimeClass.unknown, mimeClass(""));
    try testing.expectEqual(Charset.other, charsetOf("text/plain; Charset=EUC-KR"));
    try testing.expectEqual(Charset.none, charsetOf("text/plain"));
}

test "W9d②: 결과 풀기 — JSON 글, base64(글이면 글·아니면 바이너리), 빈 본문, 실패·모양이 틀린 결과, charset 없는 text/plain 의 windows-1252 되돌리기" {
    {
        const d = try decodeResult(gpa_t, true, "{\"body\":\"{\\\"a\\\":\\\"\\uD55C\\\"}\",\"base64Encoded\":false}", "application/json", .none, 0, .other);
        defer gpa_t.free(d.bytes);
        try testing.expectEqual(State.captured, d.state);
        try testing.expectEqualStrings("{\"a\":\"한\"}", d.bytes);
        try testing.expect(!d.flags.redecoded and !d.flags.binary);
    }
    {
        // 잘못된 UTF-8 JSON 은 base64 로 온다(J11) — 바이트 그대로, 바이너리 표시.
        const d = try decodeResult(gpa_t, true, "{\"body\":\"/wB7\",\"base64Encoded\":true}", "application/json", .other, 0, .other);
        defer gpa_t.free(d.bytes);
        try testing.expect(d.state == .captured and d.flags.binary);
        try testing.expectEqualSlices(u8, &.{ 0xff, 0x00, 0x7b }, d.bytes);
    }
    {
        // 글인 base64 는 글.
        const d = try decodeResult(gpa_t, true, "{\"body\":\"7ZWc\",\"base64Encoded\":true}", "text/plain", .other, 0, .other);
        defer gpa_t.free(d.bytes);
        try testing.expect(d.state == .captured and !d.flags.binary);
        try testing.expectEqualStrings("한", d.bytes);
    }
    {
        // UTF-8 「한」(ED 95 9C) 을 windows-1252 로 푼 깨진 글 「í•œ」 — 되돌린다.
        const d = try decodeResult(gpa_t, true, "{\"body\":\"\\u00ed\\u2022\\u0153 ok\",\"base64Encoded\":false}", "text/plain", .none, 0, .other);
        defer gpa_t.free(d.bytes);
        try testing.expect(d.state == .captured and d.flags.redecoded);
        try testing.expectEqualStrings("한 ok", d.bytes);
        // W9d② 적대 리뷰 1 회차: 받은 바이트 수(Σ dataReceived)를 알면 windows-1252 로 읽은 글자 수와 같을 때만 되돌린다 — 「한 ok」 는 6 바이트.
        const same = try decodeResult(gpa_t, true, "{\"body\":\"\\u00ed\\u2022\\u0153 ok\",\"base64Encoded\":false}", "text/plain", .none, 6, .other);
        defer gpa_t.free(same.bytes);
        try testing.expect(same.flags.redecoded);
        // BOM 으로 UTF-8 을 알아본 본문 — Chromium 이 맞게 풀었다(글 「Ã©」 는 원래 C3 83 C2 A9 에 BOM 셋, 7 바이트): 되돌리지 않는다(「é」 로 바꾸지 않는다).
        const bom = try decodeResult(gpa_t, true, "{\"body\":\"\\u00c3\\u00a9\",\"base64Encoded\":false}", "text/plain", .none, 7, .other);
        defer gpa_t.free(bom.bytes);
        try testing.expect(!bom.flags.redecoded and bom.flags.chromium_decoded);
        try testing.expectEqualStrings("Ã©", bom.bytes);
    }
    {
        // windows-1252 로 푼 글이 UTF-8 로 커져 상한을 넘으면 넘친 글의 크기를 함께 알린다(받은 바이트는 상한 안이어도).
        var big: std.ArrayList(u8) = .empty;
        defer big.deinit(gpa_t);
        try big.appendSlice(gpa_t, "{\"body\":\"");
        for (0..400 * 1024) |_| try big.appendSlice(gpa_t, "\\u20ac");
        try big.appendSlice(gpa_t, "\",\"base64Encoded\":false}");
        const o = try decodeResult(gpa_t, true, big.items, "text/plain", .none, 400 * 1024, .other);
        try testing.expectEqual(State.over_cap, o.state);
        try testing.expectEqual(@as(u64, 3 * 400 * 1024), o.over_bytes);
    }
    {
        // charset 이 있으면 되돌리지 않는다. 되돌릴 수 없는 글(표에 없는 글자)은 표시만.
        const d = try decodeResult(gpa_t, true, "{\"body\":\"\\u00ed\\u2022\\u0153\",\"base64Encoded\":false}", "text/plain", .other, 0, .other);
        defer gpa_t.free(d.bytes);
        try testing.expect(!d.flags.redecoded and !d.flags.chromium_decoded);
        const e = try decodeResult(gpa_t, true, "{\"body\":\"\\uD55C\",\"base64Encoded\":false}", "text/plain", .none, 0, .other);
        defer gpa_t.free(e.bytes);
        try testing.expect(e.flags.chromium_decoded and !e.flags.redecoded);
        // 라틴 글이 우연히 UTF-8 이 되지 않으면(é 하나) 그대로 — 표시만.
        const f = try decodeResult(gpa_t, true, "{\"body\":\"caf\\u00e9\",\"base64Encoded\":false}", "text/csv", .none, 0, .other);
        defer gpa_t.free(f.bytes);
        try testing.expect(f.flags.chromium_decoded);
        try testing.expectEqualStrings("café", f.bytes);
        // HTML 은 되돌리지 않는다(J11 — 맞게 풀렸다). 재검증 3 차 뒤 D-I1: 헤더 charset 이 없으면 본문의 선언을 따랐을 수 있어 표시한다.
        const g = try decodeResult(gpa_t, true, "{\"body\":\"\\u00ed\\u2022\\u0153\",\"base64Encoded\":false}", "text/html", .none, 0, .other);
        defer gpa_t.free(g.bytes);
        try testing.expect(!g.flags.redecoded and g.flags.chromium_decoded);
    }
    {
        // W9d② 20 회 검증 15 회차 D1: `FF FE 7B 22 6B 22 3A 22 C0 80 22 7D`(12 바이트) JSON 을 Chromium 이 UTF-16 으로 풀어 15 바이트 글이 왔다 — 표시.
        const utf16 = try decodeResult(gpa_t, true, "{\"body\":\"\\u227b\\u226b\\u223a\\u80c0\\u7d22\",\"base64Encoded\":false}", "application/json", .none, 12, .other);
        defer gpa_t.free(utf16.bytes);
        try testing.expect(utf16.state == .captured and utf16.flags.chromium_decoded and !utf16.flags.redecoded and !utf16.flags.binary);
        // 대조: 같은 수(UTF-8 JSON — 여러 바이트 글자 포함), 수를 모름, charset 있음은 표시하지 않는다.
        const same = try decodeResult(gpa_t, true, "{\"body\":\"{\\\"k\\\":\\\"\\uD55C\\\"}\",\"base64Encoded\":false}", "application/json", .none, 11, .other);
        defer gpa_t.free(same.bytes);
        try testing.expect(!same.flags.chromium_decoded);
        const unknown = try decodeResult(gpa_t, true, "{\"body\":\"\\u227b\",\"base64Encoded\":false}", "application/json", .none, 0, .other);
        defer gpa_t.free(unknown.bytes);
        try testing.expect(!unknown.flags.chromium_decoded);
        const cs = try decodeResult(gpa_t, true, "{\"body\":\"\\uD55C\",\"base64Encoded\":false}", "application/json", .other, 2, .other);
        defer gpa_t.free(cs.bytes);
        try testing.expect(!cs.flags.chromium_decoded);
        // 최종 재검증 D-B1: `charset=utf-8` 을 선언해도 BOM 이 앞서 UTF-16 으로 풀린다 — 표시. 대조: UTF-8 선언에 같은 수는 표시하지 않는다.
        const u8cs = try decodeResult(gpa_t, true, "{\"body\":\"\\u227b\\u226b\\u223a\\u80c0\\u7d22\",\"base64Encoded\":false}", "application/json", .utf8, 12, .other);
        defer gpa_t.free(u8cs.bytes);
        try testing.expect(u8cs.flags.chromium_decoded and !u8cs.flags.redecoded);
        const u8same = try decodeResult(gpa_t, true, "{\"body\":\"\\uD55C ok\",\"base64Encoded\":false}", "text/plain", .utf8, 6, .other);
        defer gpa_t.free(u8same.bytes);
        try testing.expect(!u8same.flags.chromium_decoded and !u8same.flags.redecoded);
        try testing.expectEqualStrings("한 ok", u8same.bytes);
    }
    try testing.expectEqual(Charset.none, charsetOf("application/json"));
    try testing.expectEqual(Charset.utf8, charsetOf("application/json; charset=UTF-8"));
    try testing.expectEqual(Charset.utf8, charsetOf("text/plain;charset=\"utf8\"; foo=bar"));
    try testing.expectEqual(Charset.other, charsetOf("text/plain; charset=iso-8859-1"));
    try testing.expectEqual(Charset.other, charsetOf("text/plain; charset=utf-16"));
    try testing.expectEqual(State.no_body, (try decodeResult(gpa_t, true, "{\"body\":\"\",\"base64Encoded\":false}", "text/plain", .other, 0, .other)).state);
    try testing.expectEqual(State.unavailable, (try decodeResult(gpa_t, false, "{\"code\":-32000}", "text/plain", .other, 0, .other)).state);
    try testing.expectEqual(State.unavailable, (try decodeResult(gpa_t, true, "[1]", "text/plain", .other, 0, .other)).state);
    try testing.expectEqual(State.unavailable, (try decodeResult(gpa_t, true, "{\"body\":\"!!!\",\"base64Encoded\":true}", "image/png", .other, 0, .other)).state);
    var cp: [8]u8 = undefined;
    try testing.expectEqualSlices(u8, &.{ 0x80, 0xe9, 0x9f }, toCp1252("€éŸ", &cp).?);
    try testing.expect(toCp1252("한", &cp) == null);
}

test "W9d②: CDP 이벤트 고르기 — requestWillBeSent(리다이렉트·미리 받기), ExtraInfo 의 실린 쿠키·인증, responseReceived, dataReceived 훑기" {
    const P = struct {
        fn ev(method: []const u8, json: []const u8) !Event {
            const p = try std.json.parseFromSlice(std.json.Value, gpa_t, json, .{});
            defer p.deinit();
            var e = parseEvent(method, p.value) orelse return error.NoEvent;
            // 글 칸은 p 를 빌린다 — 시험은 값만 본다.
            switch (e) {
                .will_be_sent => |*v| v.rid = "",
                .extra_info => |*v| v.rid = "",
                .response => |*v| {
                    v.rid = "";
                    v.mime = "";
                },
                else => {},
            }
            return e;
        }
    };
    const w = (try P.ev("Network.requestWillBeSent", "{\"requestId\":\"1.2\",\"timestamp\":12.5,\"type\":\"XHR\",\"request\":{\"url\":\"https://a.test/x#f\",\"method\":\"POST\"}}")).will_be_sent;
    try testing.expectEqual(hashUrl8("https://a.test/x"), w.url_hash);
    try testing.expectEqual(hashMethod("POST"), w.method_hash);
    try testing.expectEqual(@as(i64, 12_500_000), w.ts_us);
    try testing.expect(!w.redirect and !w.prefetch);
    // 재검증 3 차 LB-1: 그 요청을 낸 문서(`loaderId`) — 없거나 빈 글(worker)이면 0.
    try testing.expectEqual(@as(u64, 0), w.loader);
    const wl = (try P.ev("Network.requestWillBeSent", "{\"requestId\":\"1.3\",\"loaderId\":\"6A2F\",\"timestamp\":1,\"request\":{\"url\":\"u\",\"method\":\"GET\"}}")).will_be_sent;
    try testing.expectEqual(loaderHash("6A2F"), wl.loader);
    try testing.expect(wl.loader != 0 and wl.loader != loaderHash("6A30"));
    try testing.expectEqual(@as(u64, 0), (try P.ev("Network.requestWillBeSent", "{\"requestId\":\"1.4\",\"loaderId\":\"\",\"timestamp\":1,\"request\":{\"url\":\"u\",\"method\":\"GET\"}}")).will_be_sent.loader);
    try testing.expect((try P.ev("Network.requestWillBeSent", "{\"requestId\":\"1.2\",\"timestamp\":1,\"redirectResponse\":{},\"request\":{\"url\":\"u\",\"method\":\"GET\"}}")).will_be_sent.redirect);
    try testing.expect((try P.ev("Network.requestWillBeSent", "{\"requestId\":\"A\",\"timestamp\":1,\"type\":\"Prefetch\",\"request\":{\"url\":\"u\",\"method\":\"GET\"}}")).will_be_sent.prefetch);
    try testing.expect((try P.ev("Network.requestWillBeSentExtraInfo", "{\"requestId\":\"1\",\"associatedCookies\":[{\"blockedReasons\":[]}],\"headers\":{}}")).extra_info.credentialed);
    try testing.expect(!(try P.ev("Network.requestWillBeSentExtraInfo", "{\"requestId\":\"1\",\"associatedCookies\":[{\"blockedReasons\":[\"SameSiteLax\"]}],\"headers\":{\"Accept\":\"*\"}}")).extra_info.credentialed);
    try testing.expect((try P.ev("Network.requestWillBeSentExtraInfo", "{\"requestId\":\"1\",\"associatedCookies\":[],\"headers\":{\"Authorization\":\"Basic x\"}}")).extra_info.credentialed);
    const r = (try P.ev("Network.responseReceived", "{\"requestId\":\"1\",\"response\":{\"mimeType\":\"text/plain\",\"fromServiceWorker\":true,\"headers\":{\"Content-Type\":\"text/plain\"}}}")).response;
    try testing.expect(r.from_sw and r.charset == .none and !r.has_extra_info);
    // W9d② 적대 리뷰 1 회차: `hasExtraInfo`(ExtraInfo 가 오거나 왔다 — 홉마다의 ExtraInfo 를 잠시 기다릴지).
    const rx = (try P.ev("Network.responseReceived", "{\"requestId\":\"2\",\"hasExtraInfo\":true,\"response\":{\"mimeType\":\"text/plain\",\"headers\":{}}}")).response;
    try testing.expect(rx.has_extra_info);
    try testing.expectEqual(@as(i64, 0), rx.ts_us);
    // W9d② 적대 리뷰 3 회차 P1: 응답의 `timestamp`(제 CEF 기록은 그보다 앞에 시작했다).
    try testing.expectEqual(@as(i64, 12_500_000), (try P.ev("Network.responseReceived", "{\"requestId\":\"3\",\"timestamp\":12.5,\"response\":{\"mimeType\":\"text/plain\",\"headers\":{}}}")).response.ts_us);
    try testing.expect(parseEvent("Network.loadingFinished", .{ .object = .empty }) == null); // requestId 없음
    const d = scanData("{\"requestId\":\"77.3\",\"timestamp\":1.0,\"dataLength\":4096,\"encodedDataLength\":10}").?.data;
    try testing.expectEqualStrings("77.3", d.rid);
    try testing.expectEqual(@as(u64, 4096), d.bytes);
    try testing.expect(scanData("{\"requestId\":\"1\"}") == null);
    try testing.expect(wanted("Network.loadingFinished") and !wanted("Network.dataReceived") and !wanted("Page.frameNavigated"));
}

test "W9d②: 맞추기 — CDP 가 먼저 와도 CEF 가 먼저 와도 짝을 짓고 받으러 간다, 짝이 없는 CDP 요청은 시한 뒤 놓고 짝이 없는 CEF 요청은 unmatched 하나" {
    var h: H = .{};
    defer h.deinit();
    try testing.expect(try h.table.start(gpa_t, 5, 1));
    // ① CEF 먼저.
    try testing.expect(try h.cand(5, 100, "https://a.test/a.json", 1_000_000, .{}));
    try h.sent(5, "1.1", "https://a.test/a.json", 999_500, 1_000_100);
    try h.respond(5, "1.1", "application/json", 30, 1_000_200);
    try h.finish(5, "1.1", 1_000_300);
    var buf: [8]u64 = undefined;
    try testing.expectEqualSlices(u64, &.{100}, h.fetchedRequests(&buf));
    // ② CDP 끝이 CEF 기록보다 먼저(J1 — 빠른 로컬 요청: 기록은 응답보다 앞에 시작했지만 10 ms 묶음이 아직이다) — 기다렸다가 짓는다.
    h.sync = false;
    try h.sent(5, "1.2", "https://a.test/b.json", 2_000_000, 2_000_000);
    try h.respond(5, "1.2", "application/json", 10, 2_000_100);
    try h.finish(5, "1.2", 2_000_200);
    try testing.expectEqual(@as(usize, 1), h.fetches.items.len);
    try testing.expect(try h.cand(5, 101, "https://a.test/b.json", 2_000_050, .{}));
    try h.table.tick(gpa_t, 2_010_000);
    try h.drain();
    h.sync = true;
    // 자리는 탭마다 2 — 첫 것이 쥐고 있어도 둘째는 받으러 간다.
    try testing.expectEqualSlices(u64, &.{ 100, 101 }, h.fetchedRequests(&buf));
    // ③ 짝이 없는 CDP 요청(메모리 캐시가 아닌데 CEF 가 보지 못했다 — 다른 프로세스 iframe 등) — 시한 뒤 놓는다(끝 없음 — maru 에 기록이 없다).
    try h.sent(5, "1.3", "https://a.test/c.json", 3_000_000, 3_000_000);
    try h.finish(5, "1.3", 3_000_100);
    try h.table.tick(gpa_t, 3_000_100 + cef_grace_us);
    try h.drain();
    try testing.expectEqual(@as(usize, 0), h.table.tabOf(5).?.cdp.items.len);
    // ④ 짝이 없는 CEF 요청 — CEF 끝 뒤 시한이 지나면 unmatched 하나.
    try testing.expect(try h.cand(5, 102, "https://iframe.test/x", 4_000_000, .{}));
    h.table.cefEnd(5, 102, 4_100_000);
    try h.table.tick(gpa_t, 4_100_000 + unclaimed_expiry_us - 1);
    try h.drain();
    try testing.expect(h.ended.get(102) == null);
    try h.table.tick(gpa_t, 4_100_000 + unclaimed_expiry_us);
    try h.drain();
    try testing.expectEqual(State.unmatched, h.ended.get(102).?);
    // ⑤ 창 밖(CDP 시작 2 초 넘어 뒤의 CEF 시작)은 짝이 아니다.
    try testing.expect(try h.cand(5, 103, "https://a.test/d", 9_000_000, .{}));
    try h.sent(5, "1.5", "https://a.test/d", 6_000_000, 9_000_100);
    try h.finish(5, "1.5", 9_000_200);
    for (h.table.tabOf(5).?.cands.items) |c| if (c.request == 103) try testing.expect(!c.claimed);
}

test "W9d②: 같은 주소의 동시 요청은 시작 차례대로 — 먼저 시작해 아직 열린 CDP 요청 수만큼 건너뛴다(J2), 메서드·서비스 워커 갈래가 다르면 다른 열쇠" {
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    for (0..3) |i| _ = try h.cand(5, 200 + i, "https://a.test/same", 1_000_000 + @as(i64, @intCast(i)) * 100, .{});
    for (0..3) |i| {
        var rb: [8]u8 = undefined;
        const rid = try std.fmt.bufPrint(&rb, "s.{d}", .{i});
        try h.sent(5, rid, "https://a.test/same", 999_000 + @as(i64, @intCast(i)) * 100, 1_000_000);
        try h.respond(5, rid, "text/plain", 5, 1_000_500);
    }
    // 셋째가 먼저 끝난다 — 앞의 둘이 아직 열렸으니 셋째 후보(202)를 갖는다.
    try h.finish(5, "s.2", 1_001_000);
    try h.finish(5, "s.0", 1_001_100);
    var buf: [8]u64 = undefined;
    try testing.expectEqualSlices(u64, &.{ 202, 200 }, h.fetchedRequests(&buf));
    // 메서드가 다르면 짝이 아니다.
    _ = try h.cand(5, 300, "https://a.test/m", 2_000_000, .{});
    try h.ev(5, .{ .will_be_sent = .{ .rid = "m.1", .url_hash = hashUrl8("https://a.test/m"), .method_hash = hashMethod("POST"), .ts_us = 1_999_900 } }, 2_000_000);
    try h.finish(5, "m.1", 2_000_100);
    try h.table.tick(gpa_t, 2_000_100 + cef_grace_us);
    try h.drain();
    try testing.expect(!h.table.tabOf(5).?.cands.items[h.table.tabOf(5).?.cands.items.len - 1].claimed);
    // 서비스 워커가 준 응답(fromServiceWorker)은 서비스 워커 갈래의 CEF 요청과만(J3). 보낸 둘을 먼저 돌려준다(탭마다 자리 2).
    for (h.fetches.items) |a| if (h.table.takeInflight(a.fetch.id)) |f| try h.table.bodyDone(gpa_t, f, 2_500_000);
    try h.drain();
    _ = try h.cand(5, 400, "https://a.test/swdata", 3_000_000, .{ .sw = false });
    _ = try h.cand(5, 401, "https://a.test/swdata", 3_000_050, .{ .sw = true });
    try h.sent(5, "w.1", "https://a.test/swdata", 2_999_900, 3_000_000);
    try h.ev(5, .{ .response = .{ .rid = "w.1", .mime = "application/json", .from_sw = true, .charset = .other, .sw_source = "network" } }, 3_000_100);
    try h.ev(5, .{ .data = .{ .rid = "w.1", .bytes = 9 } }, 3_000_100);
    try h.finish(5, "w.1", 3_000_200);
    const last = h.fetches.items[h.fetches.items.len - 1].fetch.id;
    for (h.table.inflight.items) |f| if (f.id == last) try testing.expectEqual(@as(u64, 401), f.request);
}

test "W9d②: ExtraInfo 가 먼저 와도 실린 자격 증명을 잃지 않는다, 앞 요청이 CEF 기록을 기다리는 동안 끝난 뒤 요청은 앞 요청의 짝을 가져가지 않는다" {
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    try h.ev(5, .{ .extra_info = .{ .rid = "e.1", .credentialed = false } }, 1_000_000);
    try h.ev(5, .{ .will_be_sent = .{ .rid = "e.1", .url_hash = hashUrl8("https://a.test/e"), .method_hash = hashMethod("GET"), .ts_us = 1_000_000 } }, 1_000_000);
    _ = try h.cand(5, 1, "https://a.test/e", 1_000_100, .{});
    try h.respond(5, "e.1", "image/png", 5, 1_000_200);
    try h.finish(5, "e.1", 1_000_300);
    try testing.expectEqual(State.not_text, h.ended.get(1).?);
    // 자격 증명 표시는 ExtraInfo 의 것(실리지 않았다).
    try h.drain();
    // 앞(A)·뒤(B) 둘 다 끝났는데 CEF 기록이 아직(IO 상자에 있다) — 오면 A 가 먼저 것을, B 가 뒤 것을 갖는다.
    h.sync = false;
    try h.sent(5, "A", "https://a.test/s", 2_000_000, 2_000_000);
    try h.sent(5, "B", "https://a.test/s", 2_000_010, 2_000_010);
    try h.respond(5, "A", "text/plain", 1, 2_000_020);
    try h.respond(5, "B", "text/plain", 1, 2_000_020);
    try h.finish(5, "A", 2_000_030);
    _ = try h.cand(5, 10, "https://a.test/s", 2_000_012, .{});
    _ = try h.cand(5, 11, "https://a.test/s", 2_000_015, .{});
    try h.finish(5, "B", 2_000_200);
    try h.table.tick(gpa_t, 2_000_300);
    try h.drain();
    var buf: [4]u64 = undefined;
    const got = h.fetchedRequests(&buf);
    try testing.expectEqual(@as(usize, 2), got.len);
    // 짝은 시작 차례 그대로다(B 가 먼저 끝나도 A 의 기록을 갖지 않는다).
    try testing.expectEqual(@as(?u64, 10), fetchedFor(&h, "A"));
    try testing.expectEqual(@as(?u64, 11), fetchedFor(&h, "B"));
}

test "W9d②: 모호함 — 보이는 규칙이 다른 후보가 창 안에 있거나, 그 탭이 같은 주소의 요청을 문에서 넘긴 창 안이면 ambiguous(본문 없음)" {
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    _ = try h.cand(5, 10, "https://a.test/x", 1_000_000, .{ .attr = 1 }); // 주 프레임
    _ = try h.cand(5, 11, "https://a.test/x", 1_000_100, .{ .attr = 2 }); // 같은 사이트 iframe — 보이는 규칙이 다르다
    try h.sent(5, "a.1", "https://a.test/x", 999_000, 1_000_000);
    try h.respond(5, "a.1", "text/plain", 3, 1_000_200);
    try h.finish(5, "a.1", 1_000_300);
    // 재검증 3 차: 막 시작한 기록(`record_lag_us` 60 ms 안)은 아직 알려지지 않은 요청의 것일 수 있어 두 맞추기의 갈림을 잠시 기다린다.
    try testing.expect(h.ended.get(10) == null);
    try h.table.tick(gpa_t, 1_070_000);
    try h.drain();
    try testing.expectEqual(@as(?State, .ambiguous), h.ended.get(10));
    // 문 넘김(같은 주소) 창 안.
    _ = try h.cand(5, 20, "https://a.test/y", 2_000_000, .{});
    h.table.noteDrop(5, hashUrl8("https://a.test/y"), 2_000_050);
    try h.sent(5, "b.1", "https://a.test/y", 1_999_000, 2_000_000);
    try h.respond(5, "b.1", "text/plain", 3, 2_000_200);
    try h.finish(5, "b.1", 2_000_300);
    try testing.expectEqual(State.ambiguous, h.ended.get(20).?);
    // 다른 주소의 넘김은 상관없다 — 짝을 지어 받으러 간다.
    _ = try h.cand(5, 30, "https://a.test/z", 3_000_000, .{});
    h.table.noteDrop(5, hashUrl8("https://a.test/other"), 3_000_050);
    try h.sent(5, "c.1", "https://a.test/z", 2_999_000, 3_000_000);
    try h.respond(5, "c.1", "text/plain", 3, 3_000_200);
    try h.finish(5, "c.1", 3_000_300);
    try testing.expect(h.ended.get(30) == null);
    try testing.expectEqual(@as(usize, 1), h.fetches.items.len);
    // 표지가 넘치면 가장 오래된 표지까지의 창은 모두 모호하다.
    for (0..max_drop_marks + 1) |i| h.table.noteDrop(5, @intCast(i), 4_000_000 + @as(i64, @intCast(i)));
    _ = try h.cand(5, 40, "https://a.test/w", 4_000_000, .{});
    try h.sent(5, "d.1", "https://a.test/w", 3_999_000, 4_000_000);
    try h.respond(5, "d.1", "text/plain", 3, 4_000_000);
    try h.finish(5, "d.1", 4_000_000);
    try testing.expectEqual(State.ambiguous, h.ended.get(40).?);
}

test "W9d②: 판정 — 넘침(dataReceived 합 > 1 MiB, 스크립트도), 글 아님, 빈 본문, 끊김·실패, 설정 끔에 덮이지 않음, 메모리 캐시는 짝을 찾지 않는다" {
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    const Case = struct { req: u64, mime: []const u8, bytes: u64, fail: bool = false, covered: bool = true, want: ?State };
    const cases = [_]Case{
        .{ .req = 1, .mime = "application/javascript", .bytes = msg.max_net_body_bytes + 1, .want = .over_cap },
        .{ .req = 2, .mime = "image/png", .bytes = 900, .want = .not_text },
        .{ .req = 3, .mime = "image/png", .bytes = 0, .want = .no_body },
        .{ .req = 4, .mime = "text/plain", .bytes = 40, .fail = true, .want = .partial },
        .{ .req = 5, .mime = "", .bytes = 0, .fail = true, .want = .request_failed },
        .{ .req = 6, .mime = "text/plain", .bytes = 4, .covered = false, .want = .not_covered },
        .{ .req = 7, .mime = "text/plain", .bytes = msg.max_net_body_bytes, .want = null }, // 꼭 상한 — 받으러 간다
    };
    for (cases, 0..) |c, i| {
        const t: i64 = @intCast(10_000_000 * (i + 1));
        var ub: [32]u8 = undefined;
        const url = try std.fmt.bufPrint(&ub, "https://a.test/{d}", .{c.req});
        var rb: [8]u8 = undefined;
        const rid = try std.fmt.bufPrint(&rb, "r.{d}", .{c.req});
        _ = try h.cand(5, c.req, url, t, .{ .covered = c.covered });
        try h.sent(5, rid, url, t - 100, t);
        try h.respond(5, rid, c.mime, c.bytes, t + 10);
        if (c.fail) try h.ev(5, .{ .failed = .{ .rid = rid } }, t + 20) else try h.finish(5, rid, t + 20);
        if (c.want) |w| try testing.expectEqual(w, h.ended.get(c.req).?) else try testing.expect(h.ended.get(c.req) == null);
    }
    // 메모리 캐시에서 온 요청은 같은 주소의 CEF 요청과 짝을 짓지 않는다(J1 — CEF 가 보지 못한다).
    _ = try h.cand(5, 50, "https://a.test/cached", 100_000_000, .{});
    try h.sent(5, "mc", "https://a.test/cached", 99_999_000, 100_000_000);
    try h.ev(5, .{ .from_cache = .{ .rid = "mc" } }, 100_000_000);
    try h.finish(5, "mc", 100_000_100);
    for (h.table.tabOf(5).?.cands.items) |c| if (c.request == 50) try testing.expect(!c.claimed);
    try testing.expect(h.ended.get(50) == null);
}

test "W9d②: 동시·초당 상한 — 탭마다 2·전체 8, 자리가 나면 다음 것, 기다림이 넘치면 busy, 오래 기다리면 busy, 늦게 온 옛 세대의 결과는 버린다" {
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    var t: i64 = 1_000_000;
    const n = max_waiting_per_tab + 10;
    for (0..n) |i| {
        var ub: [32]u8 = undefined;
        const url = try std.fmt.bufPrint(&ub, "https://a.test/q{d}", .{i});
        var rb: [8]u8 = undefined;
        const rid = try std.fmt.bufPrint(&rb, "q.{d}", .{i});
        _ = try h.cand(5, 1000 + i, url, t, .{});
        try h.sent(5, rid, url, t - 10, t);
        try h.respond(5, rid, "text/plain", 10, t);
        try h.finish(5, rid, t);
        t += 10;
    }
    try testing.expectEqual(@as(usize, 2), h.fetches.items.len); // 탭마다 2
    try testing.expectEqual(@as(usize, max_waiting_per_tab), h.table.tabOf(5).?.waiting.items.len);
    try testing.expectEqual(@as(usize, n - 2 - max_waiting_per_tab), h.ends); // 넘친 것은 busy
    var it = h.ended.valueIterator();
    while (it.next()) |s| try testing.expectEqual(State.busy, s.*);
    // 하나가 돌아오면 다음 것을 보낸다.
    const f = h.table.takeInflight(h.fetches.items[0].fetch.id).?;
    try h.table.bodyDone(gpa_t, f, t);
    try h.drain();
    try testing.expectEqual(@as(usize, 3), h.fetches.items.len);
    // 오래 기다린 것은 busy.
    try h.table.tick(gpa_t, t + waiting_expiry_us + 1);
    try h.drain();
    try testing.expectEqual(@as(usize, 0), h.table.tabOf(5).?.waiting.items.len);
    // 끄고 다시 켜면 보낸 호출의 결과는 버린다(세대).
    const old = h.fetches.items[2].fetch.id;
    try h.table.stop(gpa_t, 5);
    try h.drain();
    _ = try h.table.start(gpa_t, 5, 2);
    try testing.expect(h.table.takeInflight(old) == null);
}

test "W9d②: 초당 본문 수 — 버스트 60 개(W9d② 적대 리뷰 4 회차 — 전에는 20)를 넘으면 기다린다(시간이 지나면 초당 20 개씩 보낸다)" {
    var h: H = .{};
    defer h.deinit();
    for (1..6) |b| _ = try h.table.start(gpa_t, b, 1);
    // 다섯 탭이 하나씩 — 전체 8 자리 안. 한 탭에서 결과를 곧 돌려주며 80 개를 같은 순간에(넘친 20 은 기다림 32 안).
    var t: i64 = 5_000_000;
    var got: usize = 0;
    for (0..80) |i| {
        var ub: [32]u8 = undefined;
        const url = try std.fmt.bufPrint(&ub, "https://a.test/r{d}", .{i});
        var rb: [8]u8 = undefined;
        const rid = try std.fmt.bufPrint(&rb, "r.{d}", .{i});
        _ = try h.cand(1, 5000 + i, url, t, .{});
        try h.sent(1, rid, url, t - 10, t);
        try h.respond(1, rid, "text/plain", 10, t);
        try h.finish(1, rid, t);
        while (got < h.fetches.items.len) : (got += 1) {
            const f = h.table.takeInflight(h.fetches.items[got].fetch.id).?;
            try h.table.bodyDone(gpa_t, f, t);
            try h.drain();
        }
    }
    try testing.expectEqual(@as(usize, 60), h.fetches.items.len); // 버스트 60
    t += 500_000; // 0.5 초 — 10 개 더(꾸준한 수는 초당 20 그대로)
    try h.table.tick(gpa_t, t);
    try h.drain();
    while (got < h.fetches.items.len) : (got += 1) {
        const f = h.table.takeInflight(h.fetches.items[got].fetch.id).?;
        try h.table.bodyDone(gpa_t, f, t);
        try h.drain();
    }
    try testing.expectEqual(@as(usize, 70), h.fetches.items.len);
    // 쉬고 나면 버스트가 60 까지 다시 찬다(초당 수로 깎이지 않는다). 남은 기다림 10 은 시한(3 초)이 지나 busy 로 끝나고, 새로 70 개를 같은 순간에.
    t += 10_000_000;
    for (0..70) |i| {
        var ub: [32]u8 = undefined;
        const url = try std.fmt.bufPrint(&ub, "https://a.test/s{d}", .{i});
        var rb: [8]u8 = undefined;
        const rid = try std.fmt.bufPrint(&rb, "s.{d}", .{i});
        _ = try h.cand(1, 6000 + i, url, t, .{});
        try h.sent(1, rid, url, t - 10, t);
        try h.respond(1, rid, "text/plain", 10, t);
        try h.finish(1, rid, t);
        while (got < h.fetches.items.len) : (got += 1) {
            const f = h.table.takeInflight(h.fetches.items[got].fetch.id).?;
            try h.table.bodyDone(gpa_t, f, t);
            try h.drain();
        }
    }
    try testing.expectEqual(@as(usize, 70 + 60), h.fetches.items.len);
}

test "W9d②: 끄기·렌더러 죽음·닫힘 — 기다림·보낸 호출·짝 없는 후보 모두 끝을 하나씩(recording_stopped·detached), 꺼진 탭은 후보를 적지 않는다" {
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    _ = try h.cand(5, 1, "https://a.test/1", 1_000_000, .{}); // 짝 없음
    _ = try h.cand(5, 2, "https://a.test/2", 1_000_000, .{});
    try h.sent(5, "2", "https://a.test/2", 999_000, 1_000_000);
    try h.respond(5, "2", "text/plain", 3, 1_000_000);
    try h.finish(5, "2", 1_000_000); // 보낸 호출
    try h.table.rendererGone(gpa_t, 5);
    try h.drain();
    try testing.expectEqual(State.detached, h.ended.get(1).?);
    try testing.expectEqual(State.detached, h.ended.get(2).?);
    try testing.expect(h.table.recording(5)); // 기록은 그대로(J5)
    _ = try h.cand(5, 3, "https://a.test/3", 2_000_000, .{});
    try h.table.stop(gpa_t, 5);
    try h.drain();
    try testing.expectEqual(State.recording_stopped, h.ended.get(3).?);
    try testing.expect(!(try h.cand(5, 4, "https://a.test/4", 3_000_000, .{})));
    _ = try h.table.start(gpa_t, 6, 9);
    _ = try h.cand(6, 7, "https://a.test/7", 1, .{});
    try h.table.closed(gpa_t, 6);
    try h.drain();
    try testing.expectEqual(State.detached, h.ended.get(7).?);
    try testing.expect(h.table.tabOf(6) == null);
}

test "W9d②: 쏟아짐 밸브 — 초당 5000 을 2 초 넘기면 멈추고(pause 하나), 멈춘 동안은 후보를 적지 않는다" {
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    _ = try h.cand(5, 1, "https://a.test/1", 1, .{});
    var now: i64 = 10_000_000;
    for (0..flood_events_per_s + 10) |_| try h.table.cdpEvent(gpa_t, 5, null, now);
    now += 1_000_000;
    for (0..flood_events_per_s + 10) |_| try h.table.cdpEvent(gpa_t, 5, null, now);
    try h.drain();
    try testing.expectEqual(@as(usize, 1), h.paused);
    try testing.expectEqual(State.recording_stopped, h.ended.get(1).?);
    try testing.expect(!h.table.recording(5));
    try testing.expect(!(try h.cand(5, 2, "https://a.test/2", 2, .{})));
    // 다시 켜면 풀린다.
    _ = try h.table.start(gpa_t, 5, 2);
    try testing.expect(h.table.recording(5));
}

test "W9d②: 끝은 꼭 하나 — 무작위 사건 차례(CEF·CDP 의 엇갈림, 실패·캐시, 넘김, 끄기·렌더러 죽음, 같은 번호 다시 시작·CDP 의 같은 주소 다시 보냄)에도 적은 시도마다 끝이 하나다" {
    var prng = std.Random.DefaultPrng.init(0x9d2e);
    const r = prng.random();
    for (0..60) |round| {
        // 물 높이를 CDP 사건마다 올리는 판과 손으로만 올리는 판(W9d② 적대 리뷰 3 회차) 모두.
        var h: H = .{ .sync = round % 2 == 0 };
        defer h.deinit();
        _ = try h.table.start(gpa_t, 5, 1);
        var registered: std.ArrayList(u64) = .empty;
        defer registered.deinit(gpa_t);
        var now: i64 = 1_000_000;
        var next_req: u64 = 1;
        for (0..400) |_| {
            now += r.intRangeAtMost(i64, 0, 40_000);
            const url_i = r.intRangeLessThan(u8, 0, 6);
            var ub: [32]u8 = undefined;
            const url = try std.fmt.bufPrint(&ub, "https://a.test/{d}", .{url_i});
            var rb: [16]u8 = undefined;
            const rid = try std.fmt.bufPrint(&rb, "{d}.{d}", .{ round, r.intRangeLessThan(u16, 0, 40) });
            switch (r.intRangeLessThan(u8, 0, 15)) {
                0, 1 => {
                    if (try h.cand(5, next_req, url, now + r.intRangeAtMost(i64, -3000, 50_000), .{ .attr = r.intRangeAtMost(u64, 1, 2) })) try registered.append(gpa_t, next_req);
                    next_req += 1;
                },
                2 => try h.sent(5, rid, url, now, now),
                3 => try h.respond(5, rid, if (r.boolean()) "text/plain" else "image/png", r.intRangeAtMost(u64, 0, 2 << 20), now),
                4 => try h.finish(5, rid, now),
                5 => try h.ev(5, .{ .failed = .{ .rid = rid } }, now),
                6 => try h.ev(5, .{ .from_cache = .{ .rid = rid } }, now),
                7 => h.table.cefEndAs(5, r.intRangeLessThan(u64, 1, next_req + 1), now, r.intRangeLessThan(u8, 0, 4) != 0),
                8 => h.table.noteDrop(5, hashUrl8(url), now),
                9 => {
                    try h.table.tick(gpa_t, now);
                    try h.drain();
                },
                10 => if (h.table.inflight.items.len > 0) {
                    const f = h.table.inflight.items[r.intRangeLessThan(usize, 0, h.table.inflight.items.len)];
                    if (h.table.takeInflight(f.id)) |got| {
                        // 결과를 받아 보냈다고 치고 끝을 낸다(부른 쪽이 하는 일).
                        try h.noteEnd(got.request, .captured);
                        try h.table.bodyDone(gpa_t, got, now);
                        try h.drain();
                    }
                },
                // IO 상자를 비웠다(물 높이 — W9d② 적대 리뷰 3 회차).
                11 => try h.flushed(now - r.intRangeAtMost(i64, 0, 20_000), now),
                // 같은 번호 다시 시작(W9d① 적대 리뷰 후 × W9d②) — 앞 시도가 어디에 있든(짝 없음·기다림·보낸 호출·이미 끝남).
                12 => if (registered.items.len > 0) {
                    const req = registered.items[r.intRangeLessThan(usize, 0, registered.items.len)];
                    _ = try h.cand(5, req, url, now + r.intRangeAtMost(i64, -3000, 50_000), .{ .attr = r.intRangeAtMost(u64, 1, 2) });
                },
                // CDP 가 같은 requestId 로 같은 주소를 다시 보낸다(다시 시작 — 리다이렉트로 알린다).
                13 => try h.ev(5, .{ .will_be_sent = .{ .rid = rid, .url_hash = hashUrl8(url), .method_hash = hashMethod("GET"), .ts_us = now, .redirect = true } }, now),
                else => if (r.intRangeLessThan(u8, 0, 10) == 0) {
                    try h.table.rendererGone(gpa_t, 5);
                    try h.drain();
                },
            }
        }
        try h.table.stop(gpa_t, 5);
        try h.drain();
        for (registered.items) |req| if (h.ended.get(req) == null) return error.MissingEnd;
        var it = h.attempts.iterator();
        while (it.next()) |kv| if ((h.end_counts.get(kv.key_ptr.*) orelse 0) != kv.value_ptr.*) return error.MissingEnd;
    }
}

// ── 같은 번호 다시 시작(W9d① 적대 리뷰 후 × W9d②) ──
// 시험이 증명하는 것: CEF 가 같은 번호로 다시 시작하면(Critical-CH — 판정 `body-restart-same-id`) 앞 시도의 후보는 그 시작 안에서 끝을 꼭 하나 낸다
// (`restarted` — 짝 없음·기다림·보낸 호출 어디에 있든, 보낸 호출의 늦은 답은 버린다) — 그 끝은 새 시작의 `net_begin` 보다 먼저 나가므로 maru 는
// 번호가 같은 두 기록을 가른다. 새 시도는 새 후보다(`body_expected`). 짝은 그 시도의 CDP 요청과만: CDP 가 같은 requestId 로 같은 주소를 다시
// 보내면(실측 — 리다이렉트로 알린다) 그 요청의 시작은 다시 보낸 때이고, 그 전에 끝나도 앞 시도의 후보와 짓지 않는다(새 후보를 기다린다). 다른
// requestId 로 보이는 앞 시도의 CDP 요청은 새 후보와 짓지 않는다. 브라우저 탭에서 중요한 이유 — 확인 페이지(403)의 본문과 다시 시작한 이동의
// 진짜 페이지 본문이 서로의 기록에 붙으면 에이전트는 다른 응답을 그 요청의 것으로 읽는다.

fn stateIs(h: *const H, request: u64, want: State) bool {
    const s = h.ended.get(request) orelse return false;
    return s == want;
}

fn endCount(h: *const H, request: u64) u32 {
    return h.end_counts.get(request) orelse 0;
}

const cch = "https://so.test/q";

test "W9d② × 다시 시작 S1: 실측 꼴 — CEF 시작·CDP 가 같은 requestId 로 같은 주소를 다시 보냄·CEF 끝·같은 번호 시작 — 앞 시도는 그 시작 안에서 restarted 하나, 새 시도의 본문을 받는다" {
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    const t0: i64 = 249_909_872_356;
    try h.sent(5, "R", cch, t0, t0);
    try testing.expect(try h.cand(5, 9, cch, t0 + 2_144, .{}));
    try h.ev(5, .{ .will_be_sent = .{ .rid = "R", .url_hash = hashUrl8(cch), .method_hash = hashMethod("GET"), .ts_us = t0 + 196_641, .redirect = true } }, t0 + 196_674);
    try h.respond(5, "R", "text/html", 50, t0 + 197_000);
    h.table.cefEnd(5, 9, t0 + 207_548);
    // 같은 번호의 시작 — 앞 시도의 끝은 이 시작 안에서 나간다(새 `net_begin` 보다 먼저).
    try testing.expect(try h.cand(5, 9, cch, t0 + 197_191, .{}));
    try testing.expectEqual(@as(u32, 1), endCount(&h, 9));
    try testing.expect(stateIs(&h, 9, .restarted));
    try testing.expectEqual(@as(usize, 1), h.table.tabOf(5).?.cands.items.len);
    try h.finish(5, "R", t0 + 221_229);
    var buf: [4]u64 = undefined;
    try testing.expectEqualSlices(u64, &.{9}, h.fetchedRequests(&buf));
    try testing.expectEqualStrings("R", h.fetches.items[0].fetch.rid.slice());
    const f = h.table.takeInflight(h.fetches.items[0].fetch.id).?;
    try h.noteEnd(f.request, .captured);
    try h.table.bodyDone(gpa_t, f, t0 + 230_000);
    try h.drain();
    try testing.expectEqual(@as(u32, 2), endCount(&h, 9));
    try testing.expect(!h.table.busy());
}

test "W9d② × 다시 시작 S2: CDP 끝이 같은 번호의 새 시작보다 먼저 와도 앞 시도의 후보와 짓지 않는다 — 새 후보가 오면 짓는다, 오지 않으면 놓는다" {
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    const t0: i64 = 10_000_000;
    try h.sent(5, "R", cch, t0, t0);
    try testing.expect(try h.cand(5, 9, cch, t0 + 2_000, .{}));
    try h.ev(5, .{ .will_be_sent = .{ .rid = "R", .url_hash = hashUrl8(cch), .method_hash = hashMethod("GET"), .ts_us = t0 + 196_000, .redirect = true } }, t0 + 196_100);
    try h.respond(5, "R", "text/html", 50, t0 + 197_000);
    h.table.cefEnd(5, 9, t0 + 200_000);
    try h.finish(5, "R", t0 + 205_000);
    try testing.expectEqual(@as(usize, 0), h.fetches.items.len); // 앞 시도의 후보(t0+2ms)는 다시 보낸 때(t0+196ms)의 창 밖
    try testing.expect(try h.cand(5, 9, cch, t0 + 196_500, .{}));
    try testing.expect(stateIs(&h, 9, .restarted));
    try h.table.tick(gpa_t, t0 + 215_000);
    try h.drain();
    var buf: [4]u64 = undefined;
    try testing.expectEqualSlices(u64, &.{9}, h.fetchedRequests(&buf));
    // 새 시작이 오지 않으면(처리기가 다시 시작을 다음 홉으로 봤다 — 시작을 보내지 않는다) CDP 요청은 시한 뒤 놓고 앞 후보는 unmatched.
    var g: H = .{};
    defer g.deinit();
    _ = try g.table.start(gpa_t, 5, 1);
    try g.sent(5, "R", cch, t0, t0);
    try testing.expect(try g.cand(5, 9, cch, t0 + 2_000, .{}));
    try g.ev(5, .{ .will_be_sent = .{ .rid = "R", .url_hash = hashUrl8(cch), .method_hash = hashMethod("GET"), .ts_us = t0 + 196_000, .redirect = true } }, t0 + 196_100);
    try g.finish(5, "R", t0 + 205_000);
    g.table.cefEnd(5, 9, t0 + 206_000);
    try g.table.tick(gpa_t, t0 + 206_000 + unclaimed_expiry_us);
    try g.drain();
    try testing.expectEqual(@as(usize, 0), g.fetches.items.len);
    try testing.expect(stateIs(&g, 9, .unmatched));
    try testing.expect(!g.table.busy());
}

test "W9d② × 다시 시작 S3: 앞 시도의 본문을 받는 중(보낸 호출)이면 restarted 로 곧 끝내고 늦은 답은 버린다 — 다른 requestId 로 보인 앞 시도의 CDP 요청은 새 후보와 짓지 않는다" {
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    const t0: i64 = 20_000_000;
    // ① 보낸 호출.
    try h.sent(5, "A1", cch, t0, t0);
    try testing.expect(try h.cand(5, 9, cch, t0 + 1_500, .{}));
    try h.respond(5, "A1", "text/html", 20, t0 + 50_000);
    try h.finish(5, "A1", t0 + 60_000);
    try testing.expectEqual(@as(usize, 1), h.fetches.items.len);
    const old_id = h.fetches.items[0].fetch.id;
    try testing.expect(try h.cand(5, 9, cch, t0 + 300_000, .{}));
    try testing.expect(stateIs(&h, 9, .restarted));
    try testing.expectEqual(@as(u32, 1), endCount(&h, 9));
    try testing.expect(h.table.takeInflight(old_id) == null); // 늦은 답은 버린다
    try testing.expectEqual(@as(usize, 0), h.table.tabOf(5).?.inflight);
    try h.sent(5, "A2", cch, t0 + 299_400, t0 + 299_500);
    try h.respond(5, "A2", "text/html", 30, t0 + 310_000);
    try h.finish(5, "A2", t0 + 320_000);
    try testing.expectEqual(@as(usize, 2), h.fetches.items.len);
    try testing.expectEqualStrings("A2", h.fetches.items[1].fetch.rid.slice());
    // ② 앞 시도의 CDP 요청(다른 requestId)이 새 시작 뒤에 끝난다 — 새 후보와 짓지 않는다.
    var g: H = .{};
    defer g.deinit();
    _ = try g.table.start(gpa_t, 5, 1);
    try g.sent(5, "B1", cch, t0, t0);
    try testing.expect(try g.cand(5, 9, cch, t0 + 1_500, .{}));
    try testing.expect(try g.cand(5, 9, cch, t0 + 300_000, .{}));
    try testing.expect(stateIs(&g, 9, .restarted));
    try g.respond(5, "B1", "text/html", 20, t0 + 301_000);
    try g.finish(5, "B1", t0 + 302_000);
    try testing.expectEqual(@as(usize, 0), g.fetches.items.len);
    try g.table.tick(gpa_t, t0 + 302_000 + cef_grace_us);
    try g.drain();
    try g.sent(5, "B2", cch, t0 + 299_500, t0 + 600_000);
    try g.respond(5, "B2", "text/html", 30, t0 + 610_000);
    try g.finish(5, "B2", t0 + 620_000);
    try testing.expectEqual(@as(usize, 1), g.fetches.items.len);
    try testing.expectEqualStrings("B2", g.fetches.items[0].fetch.rid.slice());
}

test "W9d② × 다시 시작 S4: 앞 시도가 자리를 기다리면(동시 상한) restarted 로 끝내고 기다림에서 뺀다 — 자리가 나도 앞 시도의 본문을 받으러 가지 않는다" {
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    const t0: i64 = 30_000_000;
    // 다른 둘이 탭의 자리(2)를 쥔다.
    for (0..2) |i| {
        var ub: [32]u8 = undefined;
        const url = try std.fmt.bufPrint(&ub, "https://a.test/o{d}", .{i});
        var rb: [8]u8 = undefined;
        const rid = try std.fmt.bufPrint(&rb, "o.{d}", .{i});
        _ = try h.cand(5, 100 + i, url, t0, .{});
        try h.sent(5, rid, url, t0 - 10, t0);
        try h.respond(5, rid, "text/plain", 10, t0);
        try h.finish(5, rid, t0);
    }
    try h.sent(5, "W", cch, t0, t0);
    _ = try h.cand(5, 9, cch, t0 + 1_000, .{});
    try h.respond(5, "W", "text/html", 10, t0 + 2_000);
    try h.finish(5, "W", t0 + 3_000);
    try testing.expectEqual(@as(usize, 1), h.table.tabOf(5).?.waiting.items.len);
    try testing.expect(try h.cand(5, 9, cch, t0 + 200_000, .{}));
    try testing.expect(stateIs(&h, 9, .restarted));
    try testing.expectEqual(@as(usize, 0), h.table.tabOf(5).?.waiting.items.len);
    const f = h.table.takeInflight(h.fetches.items[0].fetch.id).?;
    try h.noteEnd(f.request, .captured);
    try h.table.bodyDone(gpa_t, f, t0 + 210_000);
    try h.drain();
    try testing.expectEqual(@as(usize, 2), h.fetches.items.len); // 앞 시도(W)는 받으러 가지 않는다
    try testing.expectEqual(@as(u32, 1), endCount(&h, 9));
}

// ── W9d② 적대 리뷰 1 회차 재현(그 리뷰의 repro — 고치기 전에는 모두 실패했다) ─────────────────────────────────────────────────

// 이 시험이 증명하는 것(MED-1): 설정이 꺼졌을 때 덮이는 주소가 덮이지 않는 호스트로 리다이렉트하면, CDP 의 `loadingFinished` 가 그 CEF 응답보다
// 먼저 와도(J1 — 10 ms 묶음) 본문을 받으러 가지 않고 CEF 응답이 정한 대로 `not_covered` 로 끝낸다. 덮이는 호스트의 응답이면 그때 받으러 간다.
// 응답 없이 끝났거나 시한까지 오지 않으면 덮이지 않는 쪽. 왜 중요한가 — 설정을 끈 사용자의 결정은 「덮이지 않는 호스트의 본문은 브라우저 프로세스를
// 나가지 않는다」 다(실제 CEF 154 판정에서 12/12 가 빠져나갔다).
test "W9d② 적대 리뷰 1 회차 재현 RV1: 설정 끔 — 덮이는 주소가 덮이지 않는 호스트로 리다이렉트하면 CEF 응답이 덮임을 정하기 전에는 받지 않는다(not_covered), 덮이면 그때 받는다, 응답 없이 끝나거나 시한이 지나면 덮이지 않는 쪽" {
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    // CEF 시작(덮이는 첫 홉 127.0.0.1 — covered 참, 설정 끔이라 응답 호스트는 아직 모른다).
    _ = try h.cand(5, 900, "http://127.0.0.1/rv/redir?0", 1_000_000, .{ .covered = true, .cover_pending = true });
    try h.sent(5, "9.1", "http://127.0.0.1/rv/redir?0", 999_500, 1_000_100);
    h.table.cefRedirect(5, 900, true);
    try h.ev(5, .{ .will_be_sent = .{ .rid = "9.1", .url_hash = hashUrl8("http://localhost/rv/secret.json?0"), .method_hash = hashMethod("GET"), .ts_us = 1_080_000, .redirect = true } }, 1_080_100);
    try h.ev(5, .{ .extra_info = .{ .rid = "9.1", .credentialed = false } }, 1_080_100);
    try h.respond(5, "9.1", "application/json", 38, 1_081_000);
    try h.finish(5, "9.1", 1_081_100);
    try testing.expectEqual(@as(usize, 0), h.fetches.items.len);
    // 시한 안의 tick 도 받으러 가지 않는다.
    try h.table.tick(gpa_t, 1_081_100 + cover_grace_us / 2);
    try h.drain();
    try testing.expectEqual(@as(usize, 0), h.fetches.items.len);
    // CEF 응답(호스트 localhost — 덮이지 않는다)이 오면 not_covered.
    h.table.cefCovered(5, 900, false);
    try h.table.tick(gpa_t, 1_100_000);
    try h.drain();
    try testing.expectEqual(@as(usize, 0), h.fetches.items.len);
    try testing.expectEqual(State.not_covered, h.ended.get(900).?);

    // 덮이는 호스트로의 응답이면 그때 받으러 간다.
    _ = try h.cand(5, 901, "http://127.0.0.1/own?1", 2_000_000, .{ .cover_pending = true });
    try h.sent(5, "9.2", "http://127.0.0.1/own?1", 1_999_500, 2_000_100);
    try h.respond(5, "9.2", "application/json", 3, 2_001_000);
    try h.finish(5, "9.2", 2_001_100);
    try testing.expectEqual(@as(usize, 0), h.fetches.items.len);
    h.table.cefCovered(5, 901, true);
    try h.table.tick(gpa_t, 2_010_000);
    try h.drain();
    var buf: [4]u64 = undefined;
    try testing.expectEqualSlices(u64, &.{901}, h.fetchedRequests(&buf));

    // 응답 없이 끝났다(CEF 끝만) — 덮이지 않는 쪽.
    _ = try h.cand(5, 902, "http://127.0.0.1/noresp", 3_000_000, .{ .cover_pending = true });
    try h.sent(5, "9.3", "http://127.0.0.1/noresp", 2_999_500, 3_000_100);
    try h.respond(5, "9.3", "text/plain", 3, 3_001_000);
    try h.finish(5, "9.3", 3_001_100);
    h.table.cefEnd(5, 902, 3_002_000);
    try h.table.tick(gpa_t, 3_010_000);
    try h.drain();
    try testing.expectEqual(State.not_covered, h.ended.get(902).?);

    // 시한까지 CEF 응답이 오지 않는다 — 덮이지 않는 쪽.
    _ = try h.cand(5, 903, "http://127.0.0.1/slow", 4_000_000, .{ .cover_pending = true });
    try h.sent(5, "9.4", "http://127.0.0.1/slow", 3_999_500, 4_000_100);
    try h.respond(5, "9.4", "text/plain", 3, 4_001_000);
    try h.finish(5, "9.4", 4_001_100);
    try h.table.tick(gpa_t, 4_001_100 + cover_grace_us);
    try h.drain();
    try testing.expectEqual(State.not_covered, h.ended.get(903).?);
    try testing.expectEqualSlices(u64, &.{901}, h.fetchedRequests(&buf));

    // 앞 홉의 응답이 덮임을 정했어도 리다이렉트가 오면 다시 기다린다(마지막 응답 호스트로 정한다).
    _ = try h.cand(5, 904, "http://127.0.0.1/hop", 5_000_000, .{ .cover_pending = true });
    try h.sent(5, "9.5", "http://127.0.0.1/hop", 4_999_500, 5_000_100);
    h.table.cefCovered(5, 904, true);
    h.table.cefRedirect(5, 904, true);
    try h.respond(5, "9.5", "application/json", 3, 5_001_000);
    try h.finish(5, "9.5", 5_001_100);
    h.table.cefCovered(5, 904, false);
    try h.table.tick(gpa_t, 5_010_000);
    try h.drain();
    try testing.expectEqual(State.not_covered, h.ended.get(904).?);
    // 설정이 켜져 있으면(리다이렉트가 `pending` 거짓) 기다리지 않는다.
    _ = try h.cand(5, 905, "http://127.0.0.1/on", 6_000_000, .{});
    try h.sent(5, "9.6", "http://127.0.0.1/on", 5_999_500, 6_000_100);
    h.table.cefRedirect(5, 905, false);
    try h.respond(5, "9.6", "application/json", 3, 6_001_000);
    try h.finish(5, "9.6", 6_001_100);
    try testing.expect(std.mem.indexOfScalar(u64, h.fetchedRequests(&buf), 905) != null);
}

// 이 시험이 증명하는 것(MED-2): 페이지의 CDP 에 없는 같은 주소의 CEF 요청(전용 워커의 fetch — CEF 는 주 프레임의 것으로 적는다, J3)이 창 안에
// 있으면 페이지의 본문을 어느 CEF 요청에도 붙이지 않는다 — 이 요청의 짝일 수 있는 후보(워커의 것·페이지의 것)를 모두 `ambiguous` 로 끝내고,
// 창 안이어도 뒤 CDP 요청의 몫인 후보는 남긴다. 후보 수가 그것을 가져갈 CDP 요청 수와 같으면(같은 주소 동시 요청) 전처럼 차례로 짓는다. 왜 중요한가 — 에이전트가 A 의 요청 헤더와 B 의 본문을 한 요청으로 보게 된다(실제 CEF 154
// 판정에서 40 번 중 39–40 번).
test "W9d② 적대 리뷰 1 회차 재현 RV2: 페이지의 CDP 가 보지 못한 같은 주소의 워커 요청이 창 안에 있으면 짝일 수 있는 후보를 모두 ambiguous 로(본문 없음), 그 뒤 요청의 후보는 남긴다 — 후보와 CDP 요청 수가 같으면 차례대로" {
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    // 워커의 fetch: CEF 시작만(같은 열쇠·같은 보이는 규칙).
    _ = try h.cand(5, 4011, "http://127.0.0.1/rv/echo3?1", 1_000_300, .{});
    // 페이지의 fetch: CDP 시각이 조금 뒤, 그 CEF 시작은 0.7 ms 뒤.
    _ = try h.cand(5, 4012, "http://127.0.0.1/rv/echo3?1", 1_001_200, .{});
    try h.sent(5, "1.40", "http://127.0.0.1/rv/echo3?1", 1_000_500, 1_001_300);
    try h.respond(5, "1.40", "application/json", 10, 1_020_000);
    try h.finish(5, "1.40", 1_020_100);
    // 재검증 3 차: 막 시작한 기록(60 ms 안 — 아직 알려지지 않은 요청의 것일 수 있다)이 갈림을 만들면 잠시 기다린다.
    try h.table.tick(gpa_t, 1_070_000);
    try h.drain();
    var buf: [4]u64 = undefined;
    try testing.expect(std.mem.indexOfScalar(u64, h.fetchedRequests(&buf), 4011) == null);
    try testing.expectEqual(@as(usize, 0), h.fetchedRequests(&buf).len);
    // 이 요청의 짝일 수 있는 후보 둘(워커의 것·페이지의 것)이 모두 `ambiguous` — 어느 쪽에도 본문이 없다.
    try testing.expectEqual(State.ambiguous, h.ended.get(4011).?);
    try testing.expectEqual(State.ambiguous, h.ended.get(4012).?);
    h.table.cefEnd(5, 4012, 1_030_000);
    h.table.cefEnd(5, 4011, 1_030_000);
    try h.table.tick(gpa_t, 1_030_000 + unclaimed_expiry_us);
    try h.drain(); // 끝은 하나씩(두 번째 끝이면 drain 이 실패한다)

    // 워커가 늦게 시작해도(페이지의 CEF 시작 4021 뒤 — 4022) 창 안이면 모호하다 — 어느 쪽이 페이지의 것인지 차례로는 가를 수 없다.
    _ = try h.cand(5, 4021, "http://127.0.0.1/rv/echo3?2", 2_000_700, .{});
    _ = try h.cand(5, 4022, "http://127.0.0.1/rv/echo3?2", 2_001_000, .{});
    try h.sent(5, "1.41", "http://127.0.0.1/rv/echo3?2", 2_000_000, 2_001_100);
    try h.respond(5, "1.41", "application/json", 10, 2_020_000);
    try h.finish(5, "1.41", 2_020_100);
    try h.table.tick(gpa_t, 2_070_000);
    try h.drain();
    try testing.expectEqual(State.ambiguous, h.ended.get(4021).?);
    try testing.expectEqual(State.ambiguous, h.ended.get(4022).?);

    // 같은 주소의 페이지 요청 둘과 CEF 후보 둘 — 수가 같으니 차례대로 짓는다(모호하지 않다).
    _ = try h.cand(5, 4031, "http://127.0.0.1/rv/echo3?3", 3_000_700, .{});
    _ = try h.cand(5, 4032, "http://127.0.0.1/rv/echo3?3", 3_001_700, .{});
    try h.sent(5, "1.50", "http://127.0.0.1/rv/echo3?3", 3_000_000, 3_000_100);
    try h.sent(5, "1.51", "http://127.0.0.1/rv/echo3?3", 3_001_000, 3_001_100);
    try h.respond(5, "1.51", "application/json", 10, 3_020_000);
    try h.finish(5, "1.51", 3_020_100);
    try h.respond(5, "1.50", "application/json", 10, 3_021_000);
    try h.finish(5, "1.50", 3_021_100);
    // 재검증 3 차 뒤 WB-5: 1.51 은 1.50(응답 전)의 기록이 정해질 때까지 기다렸다가 다음 주기에 정한다.
    try h.table.tick(gpa_t, 3_030_000);
    try h.drain();
    try testing.expectEqualSlices(u64, &.{ 4031, 4032 }, h.fetchedRequests(&buf));
    // 같은 주소의 CDP 요청이라도 창 밖(3 초 뒤 — 이 요청의 후보를 가져갈 수 없다)이면 가져갈 쪽으로 세지 않는다: 워커 후보 하나가 남는다 → 모호.
    _ = try h.cand(5, 4051, "http://127.0.0.1/rv/echo3?5", 7_000_300, .{}); // w
    _ = try h.cand(5, 4052, "http://127.0.0.1/rv/echo3?5", 7_001_000, .{}); // 페이지
    try h.sent(5, "1.70", "http://127.0.0.1/rv/echo3?5", 7_000_500, 7_000_600);
    try h.sent(5, "1.71", "http://127.0.0.1/rv/echo3?5", 10_100_000, 10_100_100); // 창 밖의 열린 같은 주소 요청
    try h.respond(5, "1.70", "application/json", 10, 10_200_000);
    try h.finish(5, "1.70", 10_200_100);
    try testing.expectEqual(State.ambiguous, h.ended.get(4052).?);

    // 받은 것으로 치고 자리를 비운다(탭마다 동시 2).
    for (h.fetches.items) |act| if (h.table.takeInflight(act.fetch.id)) |f| try h.table.bodyDone(gpa_t, f, 3_100_000);
    try h.drain();

    // 워커의 것이 끼어도 그 뒤(창 밖으로 먼 뒤 요청의 몫)의 후보는 남긴다: 워커 w, 페이지 요청 A(곧 시작)와 B(1.5 초 뒤) — A 가 늦게 끝나 B 의
    // 후보까지 창에 들어도 A 는 w·a 만 모호로 끝내고 B 는 제 후보와 짓는다.
    _ = try h.cand(5, 4041, "http://127.0.0.1/rv/echo3?4", 4_000_000, .{}); // w
    _ = try h.cand(5, 4042, "http://127.0.0.1/rv/echo3?4", 4_001_000, .{}); // a
    try h.sent(5, "1.60", "http://127.0.0.1/rv/echo3?4", 4_000_300, 4_000_400);
    try h.sent(5, "1.61", "http://127.0.0.1/rv/echo3?4", 5_500_000, 5_500_100);
    _ = try h.cand(5, 4043, "http://127.0.0.1/rv/echo3?4", 5_500_700, .{}); // b
    try h.respond(5, "1.60", "application/json", 10, 5_600_000);
    try h.finish(5, "1.60", 5_600_100);
    try testing.expectEqual(State.ambiguous, h.ended.get(4041).?);
    try testing.expectEqual(State.ambiguous, h.ended.get(4042).?);
    try testing.expect(h.ended.get(4043) == null);
    try h.respond(5, "1.61", "application/json", 10, 5_700_000);
    try h.finish(5, "1.61", 5_700_100);
    try testing.expect(std.mem.indexOfScalar(u64, h.fetchedRequests(&buf), 4043) != null);
}

// 이 시험이 증명하는 것(LOW-3): 정한 뒤에 온 ExtraInfo 가 남긴 열쇠 없는 자리는 시한 뒤 놓여 할 일이 없어진다(`busy` 거짓 — 50 ms 주기 task 가
// 멈춘다), 그런 자리는 수도 묶인다(오래된 것부터 — 진행 중인 요청을 밀어내지 않는다). 홉마다 ExtraInfo 를 세어 뒤 홉의 것이 `loadingFinished` 뒤에
// 오면 잠시 기다려 그 쿠키를 반영하고, 끝내 오지 않으면 실린 것으로 친다(UB1 은 닫힌 쪽).
test "W9d② 적대 리뷰 1 회차 재현 C8: 정한 뒤 온 ExtraInfo 의 자리는 시한 뒤 놓는다(busy 거짓), 그런 자리의 수는 묶인다, 뒤 홉의 쿠키가 loadingFinished 뒤에 와도 실린 것" {
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    _ = try h.cand(5, 1, "https://a.test/x", 1_000_000, .{});
    try h.sent(5, "1.1", "https://a.test/x", 999_500, 1_000_100);
    try h.respond(5, "1.1", "application/json", 3, 1_000_200);
    try h.finish(5, "1.1", 1_000_300);
    // 정한 뒤의 늦은 ExtraInfo(리다이렉트 홉의 것이 loadingFinished 뒤에 오는 꼴).
    try h.ev(5, .{ .extra_info = .{ .rid = "1.1", .credentialed = true } }, 1_000_400);
    var list: [4]u64 = undefined;
    _ = h.fetchedRequests(&list);
    const f = h.table.takeInflight(h.fetches.items[0].fetch.id).?;
    try h.table.bodyDone(gpa_t, f, 1_001_000);
    try h.table.tick(gpa_t, 100_000_000);
    try h.drain();
    try testing.expect(!h.table.busy());

    // 열쇠 없는 자리는 많아야 `max_placeholders` — 진행 중인 요청(열쇠 있음)은 밀려나지 않는다.
    _ = try h.table.start(gpa_t, 6, 2);
    try h.ev(6, .{ .will_be_sent = .{ .rid = "live", .url_hash = hashUrl8("https://a.test/live"), .method_hash = hashMethod("GET"), .ts_us = 5_000_000 } }, 5_000_000);
    var rb: [16]u8 = undefined;
    for (0..max_placeholders * 3) |n| try h.ev(6, .{ .extra_info = .{ .rid = try std.fmt.bufPrint(&rb, "late.{d}", .{n}), .credentialed = false } }, 5_000_100);
    const t6 = h.table.tabOf(6).?;
    try testing.expectEqual(@as(usize, max_placeholders + 1), t6.cdp.items.len);
    try testing.expect(Table.cdpIndex(t6, "live") != null);

    // 홉마다 센다: 첫 홉의 ExtraInfo(쿠키 없음) → 리다이렉트 → loadingFinished → 둘째 홉의 ExtraInfo(쿠키) — Chromium 이 ExtraInfo 가 온다고
    // 했으면 잠시 기다려 반영한다.
    const before = h.fetches.items.len;
    _ = try h.cand(5, 2, "https://a.test/r", 6_000_000, .{});
    try h.sent(5, "2.1", "https://a.test/r", 5_999_500, 6_000_100);
    try h.ev(5, .{ .will_be_sent = .{ .rid = "2.1", .url_hash = hashUrl8("https://b.test/y"), .method_hash = hashMethod("GET"), .ts_us = 6_010_000, .redirect = true } }, 6_010_100);
    try h.ev(5, .{ .response = .{ .rid = "2.1", .mime = "application/json", .from_sw = false, .charset = .other, .has_extra_info = true } }, 6_011_000);
    try h.ev(5, .{ .data = .{ .rid = "2.1", .bytes = 3 } }, 6_011_000);
    try h.finish(5, "2.1", 6_011_100);
    try testing.expectEqual(before, h.fetches.items.len); // 둘째 홉의 ExtraInfo 를 기다린다
    try h.ev(5, .{ .extra_info = .{ .rid = "2.1", .credentialed = true } }, 6_020_000);
    try h.table.tick(gpa_t, 6_030_000);
    try h.drain();
    try testing.expectEqual(before + 1, h.fetches.items.len);
    const f2 = h.table.takeInflight(h.fetches.items[before].fetch.id).?;
    try testing.expect(f2.credentialed);
    try h.table.bodyDone(gpa_t, f2, 6_040_000);
    // 둘째 홉의 ExtraInfo 가 끝내 오지 않으면(시한) 실린 것으로 친다. Chromium 이 ExtraInfo 가 없다고 했으면 기다리지 않고 실린 것으로.
    _ = try h.cand(5, 3, "https://a.test/s", 7_000_000, .{});
    try h.sent(5, "3.1", "https://a.test/s", 6_999_500, 7_000_100);
    try h.ev(5, .{ .will_be_sent = .{ .rid = "3.1", .url_hash = hashUrl8("https://b.test/z"), .method_hash = hashMethod("GET"), .ts_us = 7_010_000, .redirect = true } }, 7_010_100);
    try h.ev(5, .{ .response = .{ .rid = "3.1", .mime = "application/json", .from_sw = false, .charset = .other, .has_extra_info = true } }, 7_011_000);
    try h.finish(5, "3.1", 7_011_100);
    try h.table.tick(gpa_t, 7_011_100 + extra_grace_us);
    try h.drain();
    try testing.expectEqual(before + 2, h.fetches.items.len);
    try testing.expect(h.table.takeInflight(h.fetches.items[before + 1].fetch.id).?.credentialed);
    _ = try h.cand(5, 4, "https://a.test/u", 8_000_000, .{});
    try h.sent(5, "4.1", "https://a.test/u", 7_999_500, 8_000_100);
    try h.ev(5, .{ .will_be_sent = .{ .rid = "4.1", .url_hash = hashUrl8("https://b.test/w"), .method_hash = hashMethod("GET"), .ts_us = 8_010_000, .redirect = true } }, 8_010_100);
    try h.respond(5, "4.1", "application/json", 3, 8_011_000);
    try h.finish(5, "4.1", 8_011_100);
    try testing.expectEqual(before + 3, h.fetches.items.len);
    try testing.expect(h.table.takeInflight(h.fetches.items[before + 2].fetch.id).?.credentialed);
}

// W9d② 적대 리뷰 2 회차 재현 F1: 같은 주소의 두 요청(5 ms 넘게 떨어져 시작) 중 뒤 요청이 먼저 끝나면 차례 k 가 창 밖 후보를 가진 앞 요청을
// 세어 뒤 요청은 짝을 못 찾고, 앞 요청은 남은 뒤 후보 때문에 ambiguous — 둘 다 본문이 없다(동시 POST /graphql 꼴).
test "W9d② 적대 리뷰 2 회차 재현 F1: 같은 주소의 느린 앞 요청과 빠른 뒤 요청 — 둘 다 제 본문을 받는다" {
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    const url = "https://app.test/graphql";
    try h.sent(5, "q.1", url, 1_000_000, 1_000_100);
    _ = try h.cand(5, 101, url, 1_000_300, .{});
    try h.sent(5, "q.2", url, 1_020_000, 1_020_100);
    _ = try h.cand(5, 102, url, 1_020_300, .{});
    try h.respond(5, "q.2", "application/json", 10, 1_059_000);
    try h.finish(5, "q.2", 1_060_000);
    h.table.cefEnd(5, 102, 1_065_000);
    try h.table.tick(gpa_t, 1_400_000);
    try h.drain();
    try h.respond(5, "q.1", "application/json", 10, 1_499_000);
    try h.finish(5, "q.1", 1_500_000);
    h.table.cefEnd(5, 101, 1_505_000);
    try h.table.tick(gpa_t, 1_510_000);
    try h.drain();
    var buf: [4]u64 = undefined;
    const got = h.fetchedRequests(&buf);
    try testing.expect(std.mem.indexOfScalar(u64, got, 101) != null);
    try testing.expect(std.mem.indexOfScalar(u64, got, 102) != null);
}

// W9d② 적대 리뷰 2 회차 재현 F2: 같은 주소의 앞 요청이 아직 열려 있으면(창 밖 후보) k=1 이 되어 페이지 요청의 본문이 워커의 CEF 기록(차례 1)에
// 붙는다 — 후보 둘·가져갈 쪽 둘이라 MED-2 의 모호함도 서지 않는다.
test "W9d② 적대 리뷰 2 회차 재현 F2: 앞의 열린 같은 주소 요청이 있어도 워커의 CEF 기록은 페이지의 본문을 받지 않는다" {
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    const url = "http://127.0.0.1/rv/echo";
    try h.sent(5, "p.0", url, 500_000, 500_100); // 오래 걸리는 앞 요청
    _ = try h.cand(5, 200, url, 500_300, .{});
    try h.sent(5, "p.1", url, 2_000_000, 2_000_100); // 페이지 요청
    _ = try h.cand(5, 201, url, 2_000_200, .{}); // 페이지의 CEF 기록
    _ = try h.cand(5, 202, url, 2_000_400, .{}); // 워커의 fetch(CDP 에 없다)
    try h.respond(5, "p.1", "application/json", 10, 2_029_000);
    try h.finish(5, "p.1", 2_030_000);
    var buf: [4]u64 = undefined;
    try testing.expect(std.mem.indexOfScalar(u64, h.fetchedRequests(&buf), 202) == null);
}

// W9d② 적대 리뷰 2 회차 재현 F3: A → B → A 리다이렉트는 CDP 에서 같은 주소 다시 보냄이라 기준 시각이 옮겨진다 — 그 뒤에 시작한 같은 주소의
// 다른 요청의 CEF 기록이 이 요청의 본문을 받는다(문서는 「틀린 기록에 붙지는 않는다」).
test "W9d② 적대 리뷰 2 회차 재현 F3: A→B→A 로 돌아온 요청의 본문은 그 뒤에 시작한 같은 주소의 다른 요청 기록에 붙지 않는다" {
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    const a = "https://app.test/me";
    try h.sent(5, "r.1", a, 1_000_000, 1_000_100);
    _ = try h.cand(5, 301, a, 1_000_300, .{});
    try h.ev(5, .{ .will_be_sent = .{ .rid = "r.1", .url_hash = hashUrl8("https://sso.test/auth"), .method_hash = hashMethod("GET"), .ts_us = 1_010_000, .redirect = true } }, 1_010_100);
    try h.ev(5, .{ .extra_info = .{ .rid = "r.1", .credentialed = true } }, 1_010_200);
    try h.ev(5, .{ .will_be_sent = .{ .rid = "r.1", .url_hash = hashUrl8(a), .method_hash = hashMethod("GET"), .ts_us = 1_020_000, .redirect = true } }, 1_020_100);
    try h.ev(5, .{ .extra_info = .{ .rid = "r.1", .credentialed = false } }, 1_020_200);
    try h.sent(5, "r.2", a, 1_021_000, 1_021_100);
    _ = try h.cand(5, 302, a, 1_021_300, .{});
    try h.respond(5, "r.1", "application/json", 10, 1_039_000);
    try h.finish(5, "r.1", 1_040_000);
    var buf: [4]u64 = undefined;
    try testing.expect(std.mem.indexOfScalar(u64, h.fetchedRequests(&buf), 302) == null);
}

// ── W9d② 적대 리뷰 2 회차(고친 뒤 넓힌 시험) ──────────────────────────────────────────────────────────────────────────────────
//
// 이 시험들이 증명하는 것: 짝은 차례를 지키는 맞추기(앞에서부터·뒤에서부터)로 고른다 — 같은 주소의 동시 요청은 창이 서로 달라도 끝난 차례와 무관하게
// 저마다 제 본문을 받고(먼저 시작한 요청의 기록이 이 요청의 창 밖이면 그 요청 몫으로 건너뛰지 않는다), CDP 가 보지 못한 같은 주소의 기록이 섞이면
// 두 맞추기가 갈려 그 사이의 후보와 갈린 다른 요청 모두 `ambiguous` 다. 같은 주소로 돌아오는 리다이렉트(A → B → A)는 다시 시작이 아니다(기준 시각을
// 옮기지 않는다), 다시 시작한 CDP 요청은 다시 시작한 CEF 시도와만 짓는다(제 주소로의 3xx 는 다시 시작과 가르지 못해 본문이 없다 — 틀린 기록보다). 왜 중요한가 — 에이전트는 본문을 그 요청의 응답으로
// 읽는다: 다른 요청의 본문이 붙으면(동시 POST /graphql 의 다른 질의, 워커의 응답) 틀린 결론을 내고, 둘 다 잃으면 흔한 페이지에서 본문이 없다.

/// 보낸 호출 중 그 requestId 의 것이 받으러 간 CEF 번호(없으면 null).
fn fetchedFor(h: *H, rid: []const u8) ?u64 {
    for (h.fetches.items) |a| if (a.fetch.rid.eql(rid)) {
        for (h.table.inflight.items) |f| if (f.id == a.fetch.id) return f.request;
    };
    return null;
}

test "W9d② 적대 리뷰 2 회차: 같은 주소의 동시 요청 셋(창이 서로 다르다) — 거꾸로 끝나도, 느린 첫 요청이 있어도 저마다 제 CEF 기록의 본문을 받는다" {
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    const url = "https://app.test/graphql";
    const post = hashMethod("POST");
    const starts = [_]i64{ 1_000_000, 1_100_000, 1_300_000 };
    const rids = [_][]const u8{ "g.1", "g.2", "g.3" };
    for (starts, rids, 0..) |st, rid, k| {
        try h.ev(5, .{ .will_be_sent = .{ .rid = rid, .url_hash = hashUrl8(url), .method_hash = post, .ts_us = st } }, st + 100);
        try h.ev(5, .{ .extra_info = .{ .rid = rid, .credentialed = false } }, st + 100);
        _ = try h.cand(5, 700 + k, url, st + 300 + @as(i64, @intCast(k)) * 1_000, .{ .method = "POST" });
    }
    // 셋째가 먼저, 둘째가 시한(cef_grace) 넘게 뒤에, 첫째(느리다)는 1 초 뒤에 끝난다.
    try h.respond(5, "g.3", "application/json", 10, 1_350_000);
    try h.finish(5, "g.3", 1_351_000);
    try h.table.tick(gpa_t, 1_700_000);
    try h.drain();
    try h.respond(5, "g.2", "application/json", 10, 1_800_000);
    try h.finish(5, "g.2", 1_801_000);
    try h.table.tick(gpa_t, 2_200_000);
    try h.drain();
    // 자리를 비운다(탭마다 동시 2).
    for (h.fetches.items) |a| if (h.table.takeInflight(a.fetch.id)) |f| {
        try testing.expectEqual(@as(u64, if (a.fetch.rid.eql("g.3")) 702 else 701), f.request);
        try h.noteEnd(f.request, .captured);
        try h.table.bodyDone(gpa_t, f, 2_300_000);
    };
    try h.drain();
    try h.respond(5, "g.1", "application/json", 10, 2_400_000);
    try h.finish(5, "g.1", 2_401_000);
    try testing.expectEqual(@as(?u64, 700), fetchedFor(&h, "g.1"));
    try testing.expectEqual(@as(usize, 3), h.fetches.items.len);
    for (0..3) |k| try testing.expect(h.ended.get(700 + k) == null or stateIs(&h, 700 + k, .captured));
    try testing.expect(h.ended.get(700) == null);
}

test "W9d② 적대 리뷰 2 회차: 워커의 같은 주소 기록이 섞여 두 맞추기가 갈리면 이 요청의 사이 후보와 갈린 앞 요청도 ambiguous — 어느 기록에도 본문이 없다" {
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    const url = "http://127.0.0.1/rv/echo";
    try h.sent(5, "p.0", url, 500_000, 500_100); // 오래 걸리는 앞 요청
    _ = try h.cand(5, 200, url, 500_300, .{});
    try h.sent(5, "p.1", url, 2_000_000, 2_000_100);
    _ = try h.cand(5, 201, url, 2_000_200, .{}); // 페이지
    _ = try h.cand(5, 202, url, 2_000_400, .{}); // 워커(CDP 에 없다)
    try h.respond(5, "p.1", "application/json", 10, 2_029_000);
    try h.finish(5, "p.1", 2_030_000);
    // 재검증 3 차: 201·202 는 막 시작했다(60 ms 안) — 갈림이 아직 알려지지 않은 요청 때문일 수 있어 그동안 기다린다.
    try h.table.tick(gpa_t, 2_070_000);
    try h.drain();
    try testing.expect(stateIs(&h, 201, .ambiguous));
    try testing.expect(stateIs(&h, 202, .ambiguous));
    // 앞 요청의 짝(200)도 가를 수 없었다(200 이 워커의 것이고 앞 요청의 기록이 201 일 수 있다 — 창 2 초 안) — 본문을 붙이지 않는다.
    // 재검증 2–9 회차 WB: 앞 요청은 끝낸 사이 후보의 주인일 수 있어 그 판정 때 함께 맞추기에서 빠졌다(남으면 다음 기록을 가져간다) — 그
    // 끝은 버려지고, 그 기록(200)은 짝 없는 시한으로 끝난다(전에는 앞 요청의 판정이 ambiguous 로 끝냈다 — 본문은 둘 다 없다).
    try h.respond(5, "p.0", "application/json", 10, 2_100_000);
    try h.finish(5, "p.0", 2_100_100);
    try testing.expect(h.ended.get(200) == null);
    h.table.cefEnd(5, 200, 2_100_200);
    try h.table.tick(gpa_t, 2_100_200 + unclaimed_expiry_us);
    try h.drain();
    // 재검증 3 차 N-3: 빠진 요청이 쥘 수 있던 기록이라 `unmatched`(다른 프로세스 iframe·worker)가 아니라 `ambiguous`.
    try testing.expect(stateIs(&h, 200, .ambiguous));
    try testing.expectEqual(@as(usize, 0), h.fetches.items.len);
    // 워커 없이 같은 꼴이면(앞 요청의 기록은 이 요청의 창 밖) 둘 다 제 본문을 받는다.
    _ = try h.cand(5, 300, url, 5_000_300, .{});
    try h.sent(5, "q.0", url, 5_000_000, 5_000_400);
    try h.sent(5, "q.1", url, 6_500_000, 6_500_100);
    _ = try h.cand(5, 301, url, 6_500_200, .{});
    try h.respond(5, "q.1", "application/json", 10, 6_529_000);
    try h.finish(5, "q.1", 6_530_000);
    try h.respond(5, "q.0", "application/json", 10, 6_600_000);
    try h.finish(5, "q.0", 6_600_100);
    try testing.expectEqual(@as(?u64, 301), fetchedFor(&h, "q.1"));
    try testing.expectEqual(@as(?u64, 300), fetchedFor(&h, "q.0"));
}

test "W9d② 적대 리뷰 2 회차: 같은 주소 다시 보냄(다시 시작 — 실측 307, 제 주소로의 3xx 와 가르지 못한다)의 CDP 요청은 다시 시작한 CEF 시도와만 — 앞 시도의 기록도, 옮긴 창에 든 다른 요청의 기록도 갖지 않는다" {
    const a = "https://app.test/me";
    // ① 제 주소로의 302(쿠키를 세우고 같은 주소로 — CEF 는 새 시작을 내지 않는다): 그 뒤에 시작한 같은 주소의 다른 요청 기록(402)을 갖지 않는다 —
    // 제 기록(401)과도 짓지 못해 `unmatched`(틀린 기록보다 없음).
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    try h.sent(5, "s.1", a, 1_000_000, 1_000_100);
    _ = try h.cand(5, 401, a, 1_000_300, .{});
    try h.ev(5, .{ .will_be_sent = .{ .rid = "s.1", .url_hash = hashUrl8(a), .method_hash = hashMethod("GET"), .ts_us = 1_020_000, .redirect = true } }, 1_020_100);
    try h.ev(5, .{ .extra_info = .{ .rid = "s.1", .credentialed = false } }, 1_020_200);
    try h.sent(5, "s.2", a, 1_021_000, 1_021_100);
    _ = try h.cand(5, 402, a, 1_021_300, .{});
    try h.respond(5, "s.1", "application/json", 10, 1_039_000);
    try h.finish(5, "s.1", 1_040_000);
    try h.table.tick(gpa_t, 1_040_000 + cef_grace_us);
    try h.drain();
    try testing.expectEqual(@as(?u64, null), fetchedFor(&h, "s.1"));
    try h.respond(5, "s.2", "application/json", 10, 1_300_000);
    try h.finish(5, "s.2", 1_300_100);
    try testing.expectEqual(@as(?u64, 402), fetchedFor(&h, "s.2"));
    h.table.cefEnd(5, 401, 1_041_000);
    try h.table.tick(gpa_t, 1_041_000 + unclaimed_expiry_us);
    try h.drain();
    try testing.expect(stateIs(&h, 401, .unmatched));
    // ② 같은 주소 다시 보냄(Critical-CH — 다시 시작): 옮긴 창에 든 다른 요청의 기록(412)도, 앞 시도의 기록(411)도 갖지 않고
    // 같은 번호의 둘째 시작(411 의 새 시도)을 기다린다.
    var g: H = .{};
    defer g.deinit();
    _ = try g.table.start(gpa_t, 5, 1);
    try g.sent(5, "c.1", a, 2_000_000, 2_000_100);
    _ = try g.cand(5, 411, a, 2_000_300, .{});
    try g.ev(5, .{ .will_be_sent = .{ .rid = "c.1", .url_hash = hashUrl8(a), .method_hash = hashMethod("GET"), .ts_us = 2_200_000, .redirect = true } }, 2_200_100);
    try g.ev(5, .{ .extra_info = .{ .rid = "c.1", .credentialed = false } }, 2_200_200);
    try g.sent(5, "c.2", a, 2_201_000, 2_201_100);
    _ = try g.cand(5, 412, a, 2_201_300, .{});
    try g.respond(5, "c.1", "text/html", 10, 2_210_000);
    try g.finish(5, "c.1", 2_211_000);
    try testing.expectEqual(@as(usize, 0), g.fetches.items.len);
    try testing.expect(try g.cand(5, 411, a, 2_200_400, .{})); // 같은 번호의 둘째 시작
    try testing.expect(stateIs(&g, 411, .restarted));
    try g.table.tick(gpa_t, 2_220_000);
    try g.drain();
    try testing.expectEqual(@as(?u64, 411), fetchedFor(&g, "c.1"));
    try g.respond(5, "c.2", "text/html", 10, 2_230_000);
    try g.finish(5, "c.2", 2_231_000);
    try testing.expectEqual(@as(?u64, 412), fetchedFor(&g, "c.2"));
}

test "W9d② 적대 리뷰 2 회차: 맞추기의 차례와 갈래 — 뒤 요청의 기록이 아직이어도 앞 요청은 제 것, ExtraInfo 가 먼저 온 요청도 시작 시각 차례, 서비스 워커 갈래는 응답 전의 요청도 세고 다른 갈래로 응답한 요청은 세지 않는다" {
    const sw_resp = struct {
        fn f(h: *H, rid: []const u8, now: i64) !void {
            try h.ev(5, .{ .response = .{ .rid = rid, .mime = "application/json", .from_sw = true, .charset = .other, .sw_source = "network" } }, now);
            try h.ev(5, .{ .data = .{ .rid = rid, .bytes = 9 } }, now);
        }
    }.f;
    {
        // 뒤 요청(1 ms 뒤)의 CEF 기록이 아직 오지 않았다 — 앞 요청은 제 기록을 받는다(뒤 요청이 그것을 가져갈 쪽으로 치지 않는다).
        var h: H = .{};
        defer h.deinit();
        _ = try h.table.start(gpa_t, 5, 1);
        const u = "https://a.test/pair";
        try h.sent(5, "a.r", u, 1_000_000, 1_000_100);
        _ = try h.cand(5, 501, u, 1_000_300, .{});
        try h.sent(5, "a.s", u, 1_001_000, 1_001_100);
        try h.respond(5, "a.r", "application/json", 9, 1_019_000);
        try h.finish(5, "a.r", 1_020_000);
        try testing.expectEqual(@as(?u64, 501), fetchedFor(&h, "a.r"));
        _ = try h.cand(5, 502, u, 1_001_300, .{});
        try h.respond(5, "a.s", "application/json", 9, 1_029_000);
        try h.finish(5, "a.s", 1_030_000);
        try testing.expectEqual(@as(?u64, 502), fetchedFor(&h, "a.s"));
    }
    {
        // ExtraInfo 가 requestWillBeSent 보다 먼저 와 목록 앞에 자리를 잡은 뒤 요청 — 차례는 목록 자리가 아니라 시작 시각이다.
        var h: H = .{};
        defer h.deinit();
        _ = try h.table.start(gpa_t, 5, 1);
        const u = "https://a.test/ph";
        try h.ev(5, .{ .extra_info = .{ .rid = "b.s", .credentialed = false } }, 2_000_000);
        try h.sent(5, "b.r", u, 2_000_000, 2_000_050);
        try h.ev(5, .{ .will_be_sent = .{ .rid = "b.s", .url_hash = hashUrl8(u), .method_hash = hashMethod("GET"), .ts_us = 2_001_000 } }, 2_001_100);
        _ = try h.cand(5, 511, u, 2_000_300, .{});
        _ = try h.cand(5, 512, u, 2_001_300, .{});
        try h.respond(5, "b.r", "application/json", 9, 2_029_000);
        try h.finish(5, "b.r", 2_030_000);
        // 재검증 3 차: b.s(응답 전)의 기록이 아직 올 수 있는 동안은 b.r 이 512 를 가질 수도 있어 기다린다. 재검증 3 차 뒤 WB-5: 그 동안은 기준 +
        // 60 ms 가 아니라 b.s 의 응답까지다(기록이 얼마나 늦을지는 페이지·서비스 워커가 정한다).
        try h.table.tick(gpa_t, 2_070_000);
        try h.drain();
        try testing.expectEqual(@as(?u64, null), fetchedFor(&h, "b.r"));
        try h.respond(5, "b.s", "application/json", 9, 2_200_000);
        try h.table.tick(gpa_t, 2_200_000);
        try h.drain();
        try testing.expectEqual(@as(?u64, 511), fetchedFor(&h, "b.r"));
    }
    {
        // 서비스 워커 갈래: 앞 요청이 아직 응답 전이면(어느 갈래인지 모른다) 그 몫을 센다 — 뒤 요청이 앞 요청의 서비스 워커 기록을 갖지 않는다.
        var h: H = .{};
        defer h.deinit();
        _ = try h.table.start(gpa_t, 5, 1);
        const u = "https://a.test/swv";
        try h.sent(5, "c.o", u, 3_000_000, 3_000_100);
        try h.sent(5, "c.r", u, 3_001_000, 3_001_100);
        _ = try h.cand(5, 521, u, 3_000_300, .{ .sw = true });
        _ = try h.cand(5, 522, u, 3_001_300, .{ .sw = true });
        try sw_resp(&h, "c.r", 3_019_000);
        try h.finish(5, "c.r", 3_020_000);
        // 재검증 3 차: 앞 요청(응답 전)의 기록이 아직 올 수 있는 동안은 기다린다 — 재검증 3 차 뒤 WB-5: 그 요청의 응답까지.
        try h.table.tick(gpa_t, 3_070_000);
        try h.drain();
        try testing.expectEqual(@as(?u64, null), fetchedFor(&h, "c.r"));
        try sw_resp(&h, "c.o", 3_300_000);
        try h.table.tick(gpa_t, 3_300_000);
        try h.drain();
        // 재검증 4 차 뒤 R6-1(기대를 바꿈 — 대가): 워커 갈래의 기록 차례는 페이지의 시작 차례가 아니다(워커가 두 요청을 거꾸로 넘기면 맞바뀐다) —
        // 같은 주소 워커 요청 둘·기록 둘이면 짝이 하나로 정해지지 않아 둘 다 본문 없이(전에는 522 를 받았다).
        try testing.expectEqual(@as(?u64, null), fetchedFor(&h, "c.r"));
        try testing.expectEqual(@as(?State, .ambiguous), h.ended.get(521));
        try testing.expectEqual(@as(?State, .ambiguous), h.ended.get(522));
    }
    {
        // 앞 요청이 서비스 워커가 아닌 응답을 받았으면(다른 갈래) 서비스 워커 갈래의 맞추기에 넣지 않는다 — 뒤 요청은 제 기록을 받는다.
        var h: H = .{};
        defer h.deinit();
        _ = try h.table.start(gpa_t, 5, 1);
        const u = "https://a.test/swx";
        try h.sent(5, "d.o", u, 4_000_000, 4_000_100);
        _ = try h.cand(5, 531, u, 4_000_300, .{});
        try h.respond(5, "d.o", "application/json", 9, 4_005_000);
        try h.sent(5, "d.r", u, 4_001_000, 4_001_100);
        _ = try h.cand(5, 532, u, 4_001_300, .{ .sw = true });
        try sw_resp(&h, "d.r", 4_019_000);
        try h.finish(5, "d.r", 4_020_000);
        try testing.expectEqual(@as(?u64, 532), fetchedFor(&h, "d.r"));
    }
}

test "W9d② 적대 리뷰 2 회차: 갈린 맞추기 — 갈린 뒤 요청도 ambiguous, 사이의 후보는 모두 ambiguous, 보이는 규칙이 다른 두 후보는 수가 맞아도 ambiguous, A→B→A 로 돌아온 요청은 제 본문" {
    {
        // 워커의 기록(542)이 두 요청의 기록 사이 — 앞 요청이 정할 때 뒤 요청도 갈린다(542 일 수도 543 일 수도): 뒤 요청의 543 도 본문이 없다.
        var h: H = .{};
        defer h.deinit();
        _ = try h.table.start(gpa_t, 5, 1);
        const u = "https://a.test/mix";
        try h.sent(5, "e.r", u, 5_000_000, 5_000_100);
        try h.sent(5, "e.s", u, 5_010_000, 5_010_100);
        _ = try h.cand(5, 541, u, 5_000_300, .{});
        _ = try h.cand(5, 542, u, 5_010_200, .{});
        _ = try h.cand(5, 543, u, 5_010_300, .{});
        try h.respond(5, "e.r", "application/json", 9, 5_029_000);
        try h.finish(5, "e.r", 5_030_000);
        // 재검증 3 차: 542·543 은 막 시작했다(60 ms 안) — 갈림이 아직 알려지지 않은 요청 때문일 수 있어 그동안 기다린다.
        try testing.expect(h.ended.get(541) == null);
        try h.table.tick(gpa_t, 5_075_000);
        try h.drain();
        try testing.expect(stateIs(&h, 541, .ambiguous) and stateIs(&h, 542, .ambiguous));
        // 재검증 2–9 회차 WB: 뒤 요청은 끝낸 사이 후보(542)의 주인일 수 있어 앞 요청의 판정 때 함께 빠졌다 — 그 끝은 버려지고 543 은 짝 없는
        // 시한으로 끝난다(본문 없음 — 전에는 뒤 요청의 판정이 ambiguous 로). 재검증 3 차 N-3: 빠진 요청이 쥘 수 있던 기록이라 그 끝은
        // `unmatched` 가 아니라 `ambiguous`.
        try h.respond(5, "e.s", "application/json", 9, 5_039_000);
        try h.finish(5, "e.s", 5_040_000);
        try testing.expect(h.ended.get(543) == null);
        h.table.cefEnd(5, 543, 5_040_100);
        try h.table.tick(gpa_t, 5_040_100 + unclaimed_expiry_us);
        try h.drain();
        try testing.expect(stateIs(&h, 543, .ambiguous));
        try testing.expectEqual(@as(usize, 0), h.fetches.items.len);
    }
    {
        // 워커 기록 둘이 앞에 — 두 맞추기 사이의 후보 셋(551·552·553)이 모두 ambiguous(하나라도 남으면 뒤에 unmatched 로 보인다).
        var h: H = .{};
        defer h.deinit();
        _ = try h.table.start(gpa_t, 5, 1);
        const u = "https://a.test/two";
        try h.sent(5, "f.r", u, 6_000_000, 6_000_100);
        for (0..3) |k| _ = try h.cand(5, 551 + k, u, 6_000_100 + @as(i64, @intCast(k)) * 100, .{});
        try h.respond(5, "f.r", "application/json", 9, 6_029_000);
        try h.finish(5, "f.r", 6_030_000);
        try h.table.tick(gpa_t, 6_070_000); // 재검증 3 차: 막 시작한 기록의 갈림은 60 ms 기다린다
        try h.drain();
        for (0..3) |k| try testing.expect(stateIs(&h, 551 + k, .ambiguous));
    }
    {
        // 같은 주소의 요청 둘·기록 둘(수가 맞는다)이어도 보이는 규칙(프레임·첫 사이트)이 다르면 모호하다.
        var h: H = .{};
        defer h.deinit();
        _ = try h.table.start(gpa_t, 5, 1);
        const u = "https://a.test/attr";
        try h.sent(5, "g.1", u, 7_000_000, 7_000_100);
        try h.sent(5, "g.2", u, 7_001_000, 7_001_100);
        _ = try h.cand(5, 561, u, 7_000_300, .{ .attr = 1 });
        _ = try h.cand(5, 562, u, 7_001_300, .{ .attr = 2 });
        try h.respond(5, "g.1", "application/json", 9, 7_029_000);
        try h.finish(5, "g.1", 7_030_000);
        try h.table.tick(gpa_t, 7_070_000); // 재검증 3 차: g.2(응답 전)의 기록이 아직 올 수 있는 동안은 기다린다(재검증 3 차 뒤 WB-5: 그 응답까지)
        try h.drain();
        try testing.expect(h.ended.get(561) == null);
        try h.respond(5, "g.2", "application/json", 9, 7_100_000);
        try h.table.tick(gpa_t, 7_100_000);
        try h.drain();
        try testing.expect(stateIs(&h, 561, .ambiguous));
    }
    {
        // A → B → A — 다시 시작이 아니다: 기준 시각은 처음 보낸 때, 제 CEF 기록의 본문을 받는다.
        var h: H = .{};
        defer h.deinit();
        _ = try h.table.start(gpa_t, 5, 1);
        const a = "https://app.test/aba";
        try h.sent(5, "h.1", a, 8_000_000, 8_000_100);
        _ = try h.cand(5, 571, a, 8_000_300, .{});
        try h.ev(5, .{ .will_be_sent = .{ .rid = "h.1", .url_hash = hashUrl8("https://sso.test/x"), .method_hash = hashMethod("GET"), .ts_us = 8_010_000, .redirect = true } }, 8_010_100);
        try h.ev(5, .{ .will_be_sent = .{ .rid = "h.1", .url_hash = hashUrl8(a), .method_hash = hashMethod("GET"), .ts_us = 8_020_000, .redirect = true } }, 8_020_100);
        try h.respond(5, "h.1", "application/json", 9, 8_039_000);
        try h.finish(5, "h.1", 8_040_000);
        try testing.expectEqual(@as(?u64, 571), fetchedFor(&h, "h.1"));
    }
}

// W9d② 적대 리뷰 3 회차 재현 P1: 빠른 요청은 CDP 끝이 제 CEF 기록(10 ms 묶음)보다 먼저 온다(450/450). 그때 CDP 가 보지 못한 같은 주소의 기록
// (전용 워커의 fetch — 앞 묶음으로 이미 왔다)이 창 안에 있으면 두 맞추기 모두 그것을 준다(후보 하나·요청 하나) — 페이지의 본문이 워커의 기록에 붙는다.
test "W9d② 적대 리뷰 3 회차 재현 P1: 제 기록이 아직인 빠른 요청의 본문은 먼저 온 워커의 같은 주소 기록에 붙지 않는다" {
    var h: H = .{ .sync = false }; // 고침 뒤: 페이지의 제 기록은 CDP 끝 때 아직 IO 상자에 있다(물 높이를 CDP 사건마다 올리지 않는다)
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    const u = "http://127.0.0.1/rv3/e?1";
    _ = try h.cand(5, 701, u, 997_000, .{}); // 워커의 fetch(CDP 에 없다) — 앞 묶음으로 왔다
    try h.sent(5, "p.1", u, 1_000_000, 1_000_100);
    try h.respond(5, "p.1", "application/json", 9, 1_002_000);
    try h.finish(5, "p.1", 1_003_000);
    _ = try h.cand(5, 702, u, 1_000_400, .{}); // 페이지의 제 CEF 기록 — 다음 묶음
    h.table.cefEnd(5, 701, 1_004_000);
    h.table.cefEnd(5, 702, 1_008_000);
    try h.table.tick(gpa_t, 1_060_000);
    try h.drain();
    try testing.expect(fetchedFor(&h, "p.1") != @as(?u64, 701));
}

// W9d② 적대 리뷰 3 회차 재현 P5: CEF 까지 가지 않고 실패한 CDP 요청(곧 abort 한 fetch — React StrictMode 의 effect 두 번 꼴)이 짝 없이 남아 있는
// 동안(cef_grace 250 ms) 같은 주소의 다음 요청을 시작하면, 왼쪽 맞추기가 실패한 요청에 다음 요청의 기록을 준다 — 성공한 요청이 `request_failed`.
test "W9d② 적대 리뷰 3 회차 재현 P5: CEF 에 닿지 않은 실패 요청이 같은 주소 다음 요청의 기록을 request_failed 로 끝내지 않는다" {
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    const u = "https://app.test/api/me";
    try h.sent(5, "a.0", u, 2_000_000, 2_000_100);
    try h.ev(5, .{ .failed = .{ .rid = "a.0" } }, 2_000_300); // abort — CEF 시작 없음
    try h.sent(5, "a.1", u, 2_001_000, 2_001_100);
    _ = try h.cand(5, 711, u, 2_001_200, .{});
    try h.respond(5, "a.1", "application/json", 9, 2_009_000);
    try h.finish(5, "a.1", 2_010_000);
    h.table.cefEnd(5, 711, 2_012_000);
    try h.table.tick(gpa_t, 2_060_000);
    try h.drain();
    try h.table.tick(gpa_t, 2_400_000);
    try h.drain();
    try testing.expect(!stateIs(&h, 711, .request_failed));
    try testing.expectEqual(@as(?u64, 711), fetchedFor(&h, "a.1"));
}

// W9d② 적대 리뷰 3 회차 재현 S1(방어): 보낸 getResponseBody 에는 시한이 없다 — 답이 오지 않으면(렌더러 죽음 밖의 꼴) 그 후보는 끝이 영영 없고
// (maru 의 기록은 `pending`), 동시 자리(탭 2·전체 8)를 쥐며 주기 task 가 멈추지 않는다.
test "W9d② 적대 리뷰 3 회차 재현 S1: 답이 오지 않는 getResponseBody 도 시한 뒤 끝이 꼭 하나다" {
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    const u = "https://app.test/a.json";
    try h.sent(5, "s.1", u, 1_000_000, 1_000_100);
    _ = try h.cand(5, 721, u, 1_000_300, .{});
    try h.respond(5, "s.1", "application/json", 9, 1_009_000);
    try h.finish(5, "s.1", 1_010_000);
    try testing.expectEqual(@as(?u64, 721), fetchedFor(&h, "s.1"));
    try h.table.tick(gpa_t, 61_010_000);
    try h.drain();
    try testing.expectEqual(@as(u32, 1), endCount(&h, 721));
    try testing.expect(!h.table.busy());
}

// ── W9d② 적대 리뷰 3 회차 ──
// 시험이 증명하는 것: (P1) CDP 끝이 제 CEF 기록보다 먼저 와도 물 높이(그 요청의 응답 때까지의 CEF 기록이 다 왔다)가 오르기 전에는 정하지 않는다 —
// 오르면 먼저 온 워커의 같은 주소 기록과 제 기록이 함께 보여 `ambiguous`(틀린 본문이 아니다), 물 높이가 시한까지 오르지 않으면 `ambiguous`. 응답 뒤에
// 시작한 워커의 같은 주소 기록은 그 요청의 짝일 수 없어 이제 모호하게 하지 않는다(대가가 줄었다). (P5) CEF 에 닿지 않고 실패한(abort) 요청은 다음
// 같은 주소 요청의 기록을 갖지 않는다 — 그 기록의 CEF 끝이 늦어도, abort 가 CEF 까지 간 꼴(실패 뒤에 시작해 취소로 끝난 기록)도 저마다 제 것.
// (S1) 보낸 본문 호출의 답이 시한 안에 오지 않으면 `unavailable` 하나로 끝내고 자리를 놓는다 — 늦은 답은 버리고 기다리던 본문을 보낸다.
// 브라우저 탭에서 중요한 이유: 에이전트는 본문을 그 요청의 응답으로 읽는다 — 워커의 응답이나 abort 한 요청의 실패가 다른 요청에 붙으면 틀린 것을 믿는다.

test "W9d② 적대 리뷰 3 회차 P1: 물 높이가 그 요청의 응답 때에 닿기 전에는 정하지 않는다 — 닿으면 워커와 제 기록이 함께 보여 ambiguous, 닿지 않으면 시한 뒤 ambiguous" {
    const u = "http://127.0.0.1/rv3/e?1";
    // ① 상자를 비운 물 높이가 응답 때 앞이면 기다리고, 닿으면(제 기록이 함께 왔다) 둘 다 ambiguous — 어느 기록에도 본문이 없다.
    {
        var h: H = .{ .sync = false };
        defer h.deinit();
        _ = try h.table.start(gpa_t, 5, 1);
        _ = try h.cand(5, 701, u, 997_000, .{});
        try h.sent(5, "p.1", u, 1_000_000, 1_000_100);
        try h.respond(5, "p.1", "application/json", 9, 1_002_000);
        try h.finish(5, "p.1", 1_003_000);
        try h.flushed(1_001_999, 1_003_500); // 응답(1_002_000) 앞까지만 — 제 기록이 아직 상자에 있을 수 있다
        try testing.expectEqual(@as(usize, 0), h.fetches.items.len);
        try testing.expect(h.ended.get(701) == null);
        _ = try h.cand(5, 702, u, 1_000_400, .{});
        try h.flushed(1_013_000, 1_013_000);
        try testing.expectEqual(@as(usize, 0), h.fetches.items.len);
        // 재검증 3 차: 702 는 막 시작했다(60 ms 안) — 그 갈림은 기록이 늙을 때까지 기다린다.
        try h.flushed(1_065_000, 1_065_000);
        try testing.expect(stateIs(&h, 701, .ambiguous));
        try testing.expect(stateIs(&h, 702, .ambiguous));
    }
    // ② 물 높이가 시한(cef_grace_us)까지 오르지 않으면 정하되 ambiguous — 먼저 온 워커의 기록에 본문을 붙이지 않는다.
    {
        var h: H = .{ .sync = false };
        defer h.deinit();
        _ = try h.table.start(gpa_t, 5, 1);
        _ = try h.cand(5, 701, u, 997_000, .{});
        try h.sent(5, "p.1", u, 1_000_000, 1_000_100);
        try h.respond(5, "p.1", "application/json", 9, 1_002_000);
        try h.finish(5, "p.1", 1_003_000);
        try h.table.tickAt(gpa_t, 1_003_000 + cef_grace_us - 1, 999_000);
        try h.drain();
        try testing.expect(h.ended.get(701) == null);
        try h.table.tickAt(gpa_t, 1_003_000 + cef_grace_us, 999_000);
        try h.drain();
        try testing.expectEqual(@as(usize, 0), h.fetches.items.len);
        try testing.expect(stateIs(&h, 701, .ambiguous));
    }
    // ③ 물 높이가 이미 응답 때를 넘었으면(상자가 비었다) 곧 정한다 — 기다림은 묶음이 늦을 때만이다.
    {
        var h: H = .{ .sync = false };
        defer h.deinit();
        _ = try h.table.start(gpa_t, 5, 1);
        try h.sent(5, "q.1", u, 1_000_000, 1_000_100);
        _ = try h.cand(5, 703, u, 1_000_300, .{});
        try h.respond(5, "q.1", "application/json", 9, 1_002_000);
        try h.flushed(1_002_500, 1_002_500);
        try h.finish(5, "q.1", 1_003_000);
        try testing.expectEqual(@as(?u64, 703), fetchedFor(&h, "q.1"));
    }
}

test "W9d② 적대 리뷰 3 회차 P1: 응답 뒤에 시작한 워커의 같은 주소 기록은 그 요청의 짝일 수 없다 — 페이지는 제 본문, 워커의 기록은 본문 없이" {
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    const u = "https://app.test/api/me";
    try h.sent(5, "p.1", u, 1_000_000, 1_000_100);
    _ = try h.cand(5, 801, u, 1_000_300, .{}); // 페이지의 제 기록
    try h.respond(5, "p.1", "application/json", 9, 1_004_000);
    _ = try h.cand(5, 802, u, 1_006_000, .{}); // 워커가 응답 뒤(2 초 창 안)에 같은 주소를 받는다
    try h.finish(5, "p.1", 1_008_000);
    try testing.expectEqual(@as(?u64, 801), fetchedFor(&h, "p.1"));
    try testing.expect(h.ended.get(802) == null); // 짝 없이 남는다 — 시한 뒤 unmatched
    h.table.cefEnd(5, 802, 1_010_000);
    try h.table.tick(gpa_t, 1_010_000 + unclaimed_expiry_us);
    try h.drain();
    try testing.expect(stateIs(&h, 802, .unmatched));
    // 응답의 CDP 시각이 UI 가 받은 때보다 앞이면 그것으로 — 그 사이에 시작한 워커의 기록도 짝이 아니다. 시각이 맞아 보이지 않으면(받은 때보다
    // 뒤) UI 가 받은 때로.
    for ([_]i64{ 1_503_000, 1_509_000 }, [_]bool{ true, false }) |cdp_ts, own| {
        var k: H = .{};
        defer k.deinit();
        _ = try k.table.start(gpa_t, 5, 1);
        try k.sent(5, "p.2", u, 1_500_000, 1_500_100);
        _ = try k.cand(5, 821, u, 1_500_300, .{});
        _ = try k.cand(5, 822, u, 1_504_000, .{}); // CDP 응답(1_503_000) 뒤·UI 가 받은 때(1_505_000) 앞에 시작한 워커의 기록
        try k.ev(5, .{ .response = .{ .rid = "p.2", .mime = "application/json", .from_sw = false, .charset = .other, .ts_us = cdp_ts } }, 1_505_000);
        try k.ev(5, .{ .data = .{ .rid = "p.2", .bytes = 9 } }, 1_505_000);
        try k.finish(5, "p.2", 1_506_000);
        try k.table.tick(gpa_t, 1_570_000);
        try k.drain();
        errdefer std.debug.print("cdp_ts={d}\n", .{cdp_ts});
        if (own) try testing.expectEqual(@as(?u64, 821), fetchedFor(&k, "p.2")) else try testing.expect(stateIs(&k, 821, .ambiguous));
    }
    // 성공한 CDP 요청은 CEF 가 취소·실패로 끝낸 기록과 짓지 않는다 — 그 기록뿐이면 짝 없이 놓는다.
    var g: H = .{};
    defer g.deinit();
    _ = try g.table.start(gpa_t, 5, 1);
    try g.sent(5, "c.1", u, 2_000_000, 2_000_100);
    _ = try g.cand(5, 811, u, 2_000_300, .{});
    g.table.cefEndAs(5, 811, 2_000_900, false);
    try g.respond(5, "c.1", "application/json", 9, 2_004_000);
    try g.finish(5, "c.1", 2_005_000);
    try testing.expectEqual(@as(usize, 0), g.fetches.items.len);
}

test "W9d② 적대 리뷰 3 회차 P5: abort 가 CEF 까지 갔든 아니든 다시 받은 같은 주소 요청은 제 본문 — 실패 뒤에 시작해 취소로 끝난 기록은 abort 한 요청의 것" {
    const u = "https://app.test/api/me";
    // ① abort 가 CEF 까지 갔다 — 그 기록(711)은 CDP 실패보다 늦게 시작해 취소로 끝난다. 그 끝이 다시 받은 요청의 판정 전에 오든 뒤에 오든.
    for ([_]bool{ true, false }) |end_first| {
        var h: H = .{};
        defer h.deinit();
        _ = try h.table.start(gpa_t, 5, 1);
        try h.sent(5, "a.0", u, 2_000_000, 2_000_100);
        try h.ev(5, .{ .failed = .{ .rid = "a.0" } }, 2_000_300);
        try h.sent(5, "a.1", u, 2_000_400, 2_000_500);
        _ = try h.cand(5, 711, u, 2_000_600, .{}); // abort 한 요청의 기록(렌더러의 abort 가 먼저 보였다)
        _ = try h.cand(5, 712, u, 2_000_700, .{});
        if (end_first) h.table.cefEndAs(5, 711, 2_001_000, false);
        try h.respond(5, "a.1", "application/json", 9, 2_009_000);
        try h.finish(5, "a.1", 2_010_000);
        // 5 회차 A1: 711 의 끝이 아직이면 a.0 이 결과를 모르는 기록을 쥐고 있다 — 그것이 성공으로 끝나면 a.1 의 짝이 바뀌므로 a.1 은 끝을 기다린다.
        try testing.expectEqual(if (end_first) @as(?u64, 712) else null, fetchedFor(&h, "a.1"));
        if (!end_first) h.table.cefEndAs(5, 711, 2_011_000, false);
        try h.table.tick(gpa_t, 2_020_000);
        try h.drain();
        errdefer std.debug.print("P5 ① end_first={}\n", .{end_first});
        try testing.expectEqual(@as(?u64, 712), fetchedFor(&h, "a.1"));
        try testing.expect(stateIs(&h, 711, .request_failed));
        try testing.expect(h.ended.get(712) == null); // 받으러 갔다
    }
    // ② abort 가 CEF 에 닿지 않았다 — 다시 받은 요청의 기록이 끝나기(성공) 전에는 실패한 요청이 그것을 「그럴 수 있다」 로만 본다: 실패한
    // 요청은 기다리고, 다시 받은 요청도 기다린다. 끝이 오면 다시 받은 요청이 갖는다 — 실패한 요청은 시한 뒤 짝 없이 놓인다.
    {
        var h: H = .{};
        defer h.deinit();
        _ = try h.table.start(gpa_t, 5, 1);
        try h.sent(5, "b.0", u, 3_000_000, 3_000_100);
        try h.ev(5, .{ .failed = .{ .rid = "b.0" } }, 3_000_300);
        try h.sent(5, "b.1", u, 3_000_400, 3_000_500);
        _ = try h.cand(5, 721, u, 3_000_600, .{});
        try h.table.tick(gpa_t, 3_001_000);
        try h.drain();
        try testing.expect(h.ended.get(721) == null); // 실패한 요청이 「그럴 수 있다」 뿐인 후보로 정하지 않는다
        try h.respond(5, "b.1", "application/json", 9, 3_009_000);
        try h.finish(5, "b.1", 3_010_000);
        try testing.expectEqual(@as(usize, 0), h.fetches.items.len); // 실패한 요청이 그 후보를 가질 수도 있다 — 끝을 기다린다
        h.table.cefEnd(5, 721, 3_012_000);
        try h.table.tick(gpa_t, 3_060_000);
        try h.drain();
        try testing.expectEqual(@as(?u64, 721), fetchedFor(&h, "b.1"));
        try h.table.tick(gpa_t, 3_000_300 + cef_grace_us);
        try h.drain();
        try testing.expectEqual(@as(usize, 0), h.table.tabOf(5).?.cdp.items.len);
        try testing.expect(h.ended.get(721) == null);
    }
    // ③ 바이트 전에 실패한 요청의 기록(실패 전에 시작했다)은 CEF 도 실패로 끝내면 request_failed — 서버가 빈 응답으로 닫은 꼴. 5 회차 A1:
    // CEF 의 끝을 보기 전에는 정하지 않는다(실패 전에 시작한 기록도 — 다시 받은 요청의 것일 수 있다).
    {
        var h: H = .{};
        defer h.deinit();
        _ = try h.table.start(gpa_t, 5, 1);
        try h.sent(5, "f.0", u, 4_000_000, 4_000_100);
        _ = try h.cand(5, 731, u, 4_000_300, .{});
        try h.ev(5, .{ .failed = .{ .rid = "f.0" } }, 4_005_000);
        try testing.expect(h.ended.get(731) == null);
        h.table.cefEndAs(5, 731, 4_006_000, false);
        try h.table.tick(gpa_t, 4_010_000);
        try h.drain();
        try testing.expect(stateIs(&h, 731, .request_failed));
    }
}

test "W9d② 적대 리뷰 3 회차 S1: 시한 뒤 끝낸 본문 호출의 늦은 답은 버리고, 놓인 자리로 기다리던 본문을 보낸다" {
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    for (0..3) |i| {
        var ub: [32]u8 = undefined;
        const url = try std.fmt.bufPrint(&ub, "https://app.test/{d}.json", .{i});
        var rb: [8]u8 = undefined;
        const rid = try std.fmt.bufPrint(&rb, "s.{d}", .{i});
        // 셋째는 늦게 끝난다 — 시한 때 아직 기다림의 시한(waiting_expiry_us) 안이다.
        const at: i64 = if (i == 2) 1_010_000 + fetch_timeout_us - 1_000_000 else 1_000_000;
        try h.sent(5, rid, url, at, at + 100);
        _ = try h.cand(5, 900 + i, url, at + 300, .{});
        try h.respond(5, rid, "application/json", 9, at + 9_000);
        try h.finish(5, rid, at + 10_000);
    }
    try testing.expectEqual(@as(usize, 2), h.fetches.items.len); // 탭마다 2 — 셋째는 기다린다
    const first = h.fetches.items[0].fetch.id;
    try h.table.tick(gpa_t, 1_010_000 + fetch_timeout_us - 1);
    try h.drain();
    try testing.expectEqual(@as(usize, 2), h.fetches.items.len);
    try h.table.tick(gpa_t, 1_010_000 + fetch_timeout_us);
    try h.drain();
    try testing.expect(stateIs(&h, 900, .unavailable) and stateIs(&h, 901, .unavailable));
    try testing.expectEqual(@as(usize, 3), h.fetches.items.len); // 놓인 자리로 셋째를 보냈다
    try testing.expect(h.table.takeInflight(first) == null); // 늦은 답은 버린다(끝이 둘이 되지 않는다)
    try testing.expectEqual(@as(u32, 1), endCount(&h, 900));
}

test "W9d② 적대 리뷰 3 회차 P1: 물 높이는 닿은 CEF 시작으로도 오른다(상자의 차례) — 응답 뒤에 찍힌 시작이 닿았으면 CDP 끝에서 곧 정한다; 응답 없이 끝난 요청은 끝 뒤에 시작한 기록과 짓지 않는다" {
    const u = "https://app.test/api/x";
    {
        var h: H = .{ .sync = false };
        defer h.deinit();
        _ = try h.table.start(gpa_t, 5, 1);
        try h.sent(5, "r.1", u, 1_000_000, 1_000_100);
        _ = try h.cand(5, 851, u, 1_000_300, .{});
        try h.respond(5, "r.1", "application/json", 9, 1_004_000);
        _ = try h.cand(5, 852, "https://other.test/y", 1_004_500, .{}); // 다른 주소 — 응답 뒤에 찍혀 닿았다: 그 앞은 다 왔다
        try h.finish(5, "r.1", 1_005_000);
        try testing.expectEqual(@as(?u64, 851), fetchedFor(&h, "r.1"));
    }
    // 응답 사건 없이 끝난 요청(드물다) — 끝 뒤에 시작한 같은 주소의 기록(워커)은 그 짝이 아니다.
    {
        var h: H = .{ .sync = false };
        defer h.deinit();
        _ = try h.table.start(gpa_t, 5, 1);
        try h.sent(5, "n.1", u, 2_000_000, 2_000_100);
        _ = try h.cand(5, 861, u, 2_000_300, .{});
        try h.ev(5, .{ .data = .{ .rid = "n.1", .bytes = 9 } }, 2_003_000);
        try h.finish(5, "n.1", 2_004_000);
        _ = try h.cand(5, 862, u, 2_006_000, .{});
        try h.table.tick(gpa_t, 2_010_000);
        try h.drain();
        try testing.expect(h.ended.get(861) != null or fetchedFor(&h, "n.1") == @as(?u64, 861));
        try testing.expect(!stateIs(&h, 861, .ambiguous));
        try testing.expect(h.ended.get(862) == null);
    }
}

// ── W9d② 적대 리뷰 4 회차 ──────────────────────────────────────────────────────────────────────────────────

/// 서비스 워커가 준 응답(fromServiceWorker)과 그 출처(`serviceWorkerResponseSource`).
fn swResponse(h: *H, rid: []const u8, source: []const u8, now: i64) !void {
    try h.ev(5, .{ .response = .{ .rid = rid, .mime = "application/json", .from_sw = true, .charset = .other, .sw_source = source } }, now);
    try h.ev(5, .{ .data = .{ .rid = rid, .bytes = 11 } }, now);
}

// SW1: 실제 CEF 154 의 차례(판정 rv4-sw-swr 진단 줄 — µs): CDP 시작 518 911 · 서비스 워커의 네트워크 fetch 의 CEF 시작 519 318 · 페이지의 응답
// (fromServiceWorker — Cache Storage 의 옛 본문) 519 790 · CDP 끝 519 914 · 그 CEF 기록의 끝 531 249. 전에는 페이지 요청이 서비스 워커 갈래의 그
// 기록과 짝지어져 캐시의 옛 본문이 네트워크 응답의 기록에 붙었다(38/40). 지금 Event 칸으로는 이 차례가 서비스 워커의 그대로 넘김(pass-through —
// 판정 body-service-worker 는 잡아야 한다)과 같다 — 가르는 것은 응답의 출처다.
test "W9d② 적대 리뷰 4 회차 SW1: 서비스 워커가 Cache Storage 로 답하고 같은 주소를 네트워크로 다시 받으면(stale-while-revalidate) 그 네트워크 기록에 캐시의 본문을 붙이지 않는다 — 기록은 unmatched" {
    const u = "https://app.test/sw/d";
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    try h.sent(5, "p.1", u, 518_911, 518_950);
    _ = try h.cand(5, 9001, u, 519_318, .{ .sw = true });
    try swResponse(&h, "p.1", "cache-storage", 519_790);
    try h.finish(5, "p.1", 519_914);
    try testing.expectEqual(@as(usize, 0), h.fetches.items.len);
    try testing.expectEqual(@as(usize, 0), h.table.tabOf(5).?.cdp.items.len); // CEF 가 보지 못한 응답으로 놓았다
    h.table.cefEnd(5, 9001, 531_249);
    try h.table.tick(gpa_t, 531_249 + unclaimed_expiry_us);
    try h.drain();
    try testing.expect(stateIs(&h, 9001, .unmatched));
    try testing.expectEqual(@as(u32, 1), endCount(&h, 9001));
}

// SW1b·출처 없음: 워커가 네트워크로 받은 뒤 `new Response(...)` 로 바꿔 답했다(출처 `fallback-code`), HTTP 캐시의 것, 출처를 알리지 않은 응답 —
// 모두 네트워크 응답이 아니다(닫힌 쪽). 대조: 출처가 `network` 면(그대로 넘김) 그 워커 기록의 본문을 받는다.
test "W9d② 적대 리뷰 4 회차 SW1b: 서비스 워커가 만든 응답·HTTP 캐시의 것·출처를 모르는 것도 워커 기록에 붙이지 않는다, 네트워크에서 받은 응답(그대로 넘김)만 붙인다" {
    const u = "https://app.test/sw/syn";
    for ([_][]const u8{ "fallback-code", "http-cache", "", "network" }, 0..) |source, n| {
        var h: H = .{};
        defer h.deinit();
        _ = try h.table.start(gpa_t, 5, 1);
        const base: i64 = 1_000_000;
        try h.sent(5, "s.1", u, base, base + 50);
        _ = try h.cand(5, 9100 + n, u, base + 400, .{ .sw = true });
        try swResponse(&h, "s.1", source, base + 9_000);
        try h.finish(5, "s.1", base + 9_100);
        var buf: [4]u64 = undefined;
        if (std.mem.eql(u8, source, "network")) {
            try testing.expectEqualSlices(u64, &.{9100 + n}, h.fetchedRequests(&buf));
        } else {
            try testing.expectEqual(@as(usize, 0), h.fetches.items.len);
            h.table.cefEnd(5, 9100 + n, base + 20_000);
            try h.table.tick(gpa_t, base + 20_000 + unclaimed_expiry_us);
            try h.drain();
            try testing.expect(stateIs(&h, 9100 + n, .unmatched));
        }
    }
}

// 같은 주소를 서비스 워커가 그대로 넘긴 요청(P — 출처 network)과 캐시로 답하며 다시 받은 요청(A — 출처 cache-storage)이 한꺼번에: A 의 다시 받기
// 기록(a)이 P 의 기록(p)보다 앞이다. A 는 기록을 가져가지 않으므로 P 의 왼쪽 맞추기는 a 를, 오른쪽은 p 를 준다 — 갈렸으니 둘 다 `ambiguous`(틀린
// 본문보다 없음). P 가 a 의 본문을 받는 일은 없다.
test "W9d② 적대 리뷰 4 회차 SW1: 그대로 넘긴 요청과 캐시로 답한 요청이 같은 주소로 섞이면 그대로 넘긴 요청도 캐시 쪽 워커 기록을 갖지 않는다(ambiguous)" {
    const u = "https://app.test/sw/mix";
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    try h.sent(5, "a.1", u, 1_000_000, 1_000_050);
    _ = try h.cand(5, 9201, u, 1_000_200, .{ .sw = true }); // A 의 다시 받기
    try h.sent(5, "p.1", u, 1_000_500, 1_000_550);
    _ = try h.cand(5, 9202, u, 1_000_700, .{ .sw = true }); // P 의 그대로 넘김
    try swResponse(&h, "a.1", "cache-storage", 1_001_000);
    try h.finish(5, "a.1", 1_001_100);
    try swResponse(&h, "p.1", "network", 1_010_000);
    try h.finish(5, "p.1", 1_011_000);
    try h.table.tick(gpa_t, 1_065_000);
    try h.drain();
    try testing.expectEqual(@as(usize, 0), h.fetches.items.len);
    try testing.expect(stateIs(&h, 9201, .ambiguous) and stateIs(&h, 9202, .ambiguous));
}

// 캐시로 답한 요청(A — 기록이 없는 캐시 적중)이 아직 열린 동안 같은 주소를 그대로 넘긴 요청(P)이 끝난다: A 는 어느 기록도 가져가지 않으므로 P 는
// 곧 제 기록(p)을 받는다(A 를 맞추기에 넣으면 — A 의 응답이 p 의 시작 뒤라 p 는 A 의 짝일 수 있다 — A 가 p 를 가져가 P 는 기다리다 본문을 잃었다).
// 캐시로 답한 요청이 실패로 끝나도(읽는 중 끊김) 아무 기록에도 닿지 않고 놓인다.
test "W9d② 적대 리뷰 4 회차 SW1: 캐시로 답해 아직 열린 요청은 같은 주소의 그대로 넘긴 요청의 기록을 가져가지 않는다, 실패로 끝나도 놓인다" {
    const u = "https://app.test/sw/open";
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    try h.sent(5, "a.1", u, 1_000_000, 1_000_050);
    try h.sent(5, "p.1", u, 1_000_500, 1_000_550);
    _ = try h.cand(5, 9251, u, 1_000_700, .{ .sw = true });
    try swResponse(&h, "a.1", "cache-storage", 1_005_000); // 응답은 왔고 끝은 아직
    try swResponse(&h, "p.1", "network", 1_010_000);
    try h.finish(5, "p.1", 1_011_000);
    try testing.expectEqual(@as(?u64, 9251), fetchedFor(&h, "p.1"));
    try h.ev(5, .{ .failed = .{ .rid = "a.1" } }, 1_012_000);
    try testing.expectEqual(@as(usize, 0), h.table.tabOf(5).?.cdp.items.len);
    try h.table.tick(gpa_t, 1_012_000 + cef_grace_us);
    try h.drain();
    try testing.expectEqual(@as(u32, 0), endCount(&h, 9251)); // 보낸 호출은 그대로 — 실패한 A 가 끝내지 않았다
}

test "W9d② 적대 리뷰 4 회차 SW1: responseReceived 의 serviceWorkerResponseSource 를 읽는다(없으면 빈 글)" {
    const P = struct {
        var arena_state: std.heap.ArenaAllocator = undefined;
        fn ev(json: []const u8) !Event {
            const v = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), json, .{});
            return parseEvent("Network.responseReceived", v).?;
        }
    };
    P.arena_state = .init(gpa_t);
    defer P.arena_state.deinit();
    try testing.expectEqualStrings("cache-storage", (try P.ev("{\"requestId\":\"1\",\"response\":{\"mimeType\":\"a/b\",\"fromServiceWorker\":true,\"serviceWorkerResponseSource\":\"cache-storage\",\"headers\":{}}}")).response.sw_source);
    try testing.expectEqualStrings("", (try P.ev("{\"requestId\":\"1\",\"response\":{\"mimeType\":\"a/b\",\"fromServiceWorker\":true,\"headers\":{}}}")).response.sw_source);
}

// 넘김 상자가 넘쳐 시작이 표에 닿지 않은 요청(A — 그 표지는 `net_gate.State.queueRefused` 가 남긴다)과 같은 주소의 동시 요청(B): 표지가 없으면 A 의
// 맞추기가 B 의 기록(b)을 준다 — B 의 응답 본문이 아니라 A 의 본문이 b 에 붙는다. 표지가 있으면 그 창은 모호하다.
test "W9d② 적대 리뷰 4 회차: 상자가 넘쳐 놓친 시작 — 표지가 있으면 같은 주소의 다른 요청 기록을 갖지 않는다(ambiguous), 표지가 없을 때는 가져갔다(대조)" {
    const u = "https://app.test/api/q";
    for ([_]bool{ false, true }) |marked| {
        var h: H = .{};
        defer h.deinit();
        _ = try h.table.start(gpa_t, 5, 1);
        try h.sent(5, "A", u, 1_000_000, 1_000_050);
        if (marked) h.table.noteDrop(5, hashUrl8(u), 1_000_100); // A 의 시작(상자에 넣지 못했다)
        try h.sent(5, "B", u, 1_001_000, 1_001_050);
        _ = try h.cand(5, 9301, u, 1_001_200, .{}); // B 의 기록
        try h.respond(5, "A", "application/json", 9, 1_005_000);
        try h.finish(5, "A", 1_006_000);
        if (marked) {
            try testing.expectEqual(@as(usize, 0), h.fetches.items.len);
            try testing.expect(stateIs(&h, 9301, .ambiguous));
        } else {
            try testing.expectEqual(@as(?u64, 9301), fetchedFor(&h, "A"));
        }
    }
}

// N1: `<link rel=prefetch>` — CDP 는 `dataReceived` 없이 빈 본문을 줬는데 서버는 13 바이트를 보냈다(CEF 끝의 받은 바이트). 「0 바이트」(`no_body`)가
// 아니라 `unavailable`. 204·HEAD(CEF 도 0)는 그대로 `no_body`. 글 아닌 종류도 같다. CEF 끝이 결과보다 늦으면 아직 모른다(no_body 그대로 — 알고 둔 틈).
test "W9d② 적대 리뷰 4 회차 N1: CDP 가 빈 본문을 줬는데 CEF 는 바이트를 받았으면 unavailable — 정말 0 바이트면 no_body" {
    const u = "https://app.test/pf";
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    // 글: 받으러 간 뒤 빈 결과.
    try h.sent(5, "f.1", u, 1_000_000, 1_000_050);
    _ = try h.cand(5, 9401, u, 1_000_200, .{});
    h.table.cefEndReceived(5, 9401, 1_004_000, true, 13);
    try h.respond(5, "f.1", "application/json", 0, 1_003_000);
    try h.finish(5, "f.1", 1_005_000);
    const f1 = h.table.takeInflight(h.fetches.items[0].fetch.id).?;
    try testing.expectEqual(State.unavailable, h.table.emptyBodyState(f1, .no_body));
    try testing.expectEqual(State.captured, h.table.emptyBodyState(f1, .captured));
    try testing.expectEqual(State.over_cap, h.table.emptyBodyState(f1, .over_cap)); // 빈 본문만 바꾼다
    try testing.expectEqual(State.busy, h.table.emptyBodyState(f1, .busy));
    try h.table.bodyDone(gpa_t, f1, 1_006_000);
    // 정말 0 바이트(204) — 그대로.
    try h.sent(5, "f.2", u, 2_000_000, 2_000_050);
    _ = try h.cand(5, 9402, u, 2_000_200, .{});
    h.table.cefEndReceived(5, 9402, 2_004_000, true, 0);
    try h.respond(5, "f.2", "application/json", 0, 2_003_000);
    try h.finish(5, "f.2", 2_005_000);
    const f2 = h.table.takeInflight(h.fetches.items[1].fetch.id).?;
    try testing.expectEqual(State.no_body, h.table.emptyBodyState(f2, .no_body));
    try h.table.bodyDone(gpa_t, f2, 2_006_000);
    // 글 아닌 종류 — 받으러 가지 않고 곧 정한다.
    try h.sent(5, "f.3", "https://app.test/i.png", 3_000_000, 3_000_050);
    _ = try h.cand(5, 9403, "https://app.test/i.png", 3_000_200, .{});
    h.table.cefEndReceived(5, 9403, 3_004_000, true, 70);
    try h.respond(5, "f.3", "image/png", 0, 3_003_000);
    try h.finish(5, "f.3", 3_005_000);
    try testing.expect(stateIs(&h, 9403, .unavailable));
    try h.sent(5, "f.4", "https://app.test/j.png", 4_000_000, 4_000_050);
    _ = try h.cand(5, 9404, "https://app.test/j.png", 4_000_200, .{});
    try h.respond(5, "f.4", "image/png", 0, 4_003_000);
    try h.finish(5, "f.4", 4_005_000);
    try testing.expect(stateIs(&h, 9404, .no_body));
}

// W9d② 적대 리뷰 5 회차 재현 A1: abort 한 fetch 가 CEF 에 닿지 않았고, 다시 받은 같은 주소 요청의 CEF 시작(IO 시각)이 UI 가 그 abort 의
// `loadingFailed` 를 받은 때(`done_at` — UI 시각)보다 앞이다(렌더러가 abort 와 다시 받기를 한 task 에서 했고, UI 스레드는 그 실패 사건을 IO 의
// 시작보다 늦게 받았다). 실패한 요청은 「끝을 본 때까지 시작한 기록」 을 확실한 제 짝으로 친다(`definite`) — 그래서 다시 받은 요청의 기록을
// 가져가 `request_failed` 로 끝내고, 성공한 다시 받은 요청은 짝 없이 놓인다(4 회차 판정 `body-r3-abort-refetch` 29/30 의 한 번).
test "W9d② 적대 리뷰 5 회차 재현 A1: CEF 에 닿지 않은 abort 의 실패를 UI 가 다시 받은 요청의 CEF 시작보다 늦게 보면 그 기록을 request_failed 로 가져간다" {
    var h: H = .{ .sync = false };
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    const u = "http://127.0.0.1/rv3/slow?a7";
    try h.sent(5, "x.7", u, 2_000_000, 2_000_100); // abort 할 fetch — CEF 에 닿지 않는다
    try h.ev(5, .{ .failed = .{ .rid = "x.7" } }, 2_000_900); // UI 가 실패를 받은 때(done_at)
    try h.sent(5, "p.7", u, 2_000_200, 2_000_950); // 다시 받기 — 렌더러에서는 abort 바로 뒤
    _ = try h.cand(5, 771, u, 2_000_500, .{}); // 다시 받은 요청의 CEF 시작 — IO 시각은 UI 가 실패를 본 때보다 앞
    try h.flushed(2_001_000, 2_001_000); // 그 시작이 온 묶음
    try h.respond(5, "p.7", "application/json", 9, 2_008_000);
    try h.finish(5, "p.7", 2_009_000);
    h.table.cefEnd(5, 771, 2_012_000);
    try h.table.tick(gpa_t, 2_060_000);
    try h.drain();
    try h.table.tick(gpa_t, 2_400_000);
    try h.drain();
    errdefer std.debug.print("A1: 771 state={?} fetched for p.7={?}\n", .{ h.ended.get(771), fetchedFor(&h, "p.7") });
    try testing.expect(!stateIs(&h, 771, .request_failed));
    try testing.expectEqual(@as(?u64, 771), fetchedFor(&h, "p.7"));
}

// W9d② 적대 리뷰 5 회차 재현 A2(받는 비율 — 판정 `rv5-mix`): 무거운 페이지의 첫 적재는 글 응답 백여 개(스크립트·스타일·JSON)가 한꺼번에 끝난다.
// 기다림 상한(탭 32)이 그 순간에 넘쳐 나머지는 곧 `busy` 다 — 본문 호출 하나는 ms 단위로 끝나고 기다림의 시한(3 초) 안에 모두 받을 수 있는데도.
// 실제 CEF(ReleaseFast) 판정: 글 본문 142 중 56 `busy`, 페이지의 JSON 은 차례에 따라 0/30–27/30.
test "W9d② 적대 리뷰 5 회차 재현 A2: 한꺼번에 끝난 글 응답 100 개 — 본문 호출이 곧 끝나면 기다림 시한 안에 모두 받는다(busy 없음)" {
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    const n = 100;
    for (0..n) |i| {
        var ub: [48]u8 = undefined;
        const url = try std.fmt.bufPrint(&ub, "https://app.test/chunk{d}.js", .{i});
        var rb: [16]u8 = undefined;
        const rid = try std.fmt.bufPrint(&rb, "m.{d}", .{i});
        const at: i64 = 1_000_000 + @as(i64, @intCast(i)) * 200;
        try h.sent(5, rid, url, at, at + 50);
        _ = try h.cand(5, 5000 + i, url, at + 100, .{});
        // 5 회차 고침: 스크립트(차례가 뒤 — `lowPriority`)로 알린다. 앞 차례가 없으면 뒤 차례도 시한 안에 모두 받는다.
        try h.ev(5, .{ .response = .{ .rid = rid, .mime = "application/javascript", .from_sw = false, .charset = .other, .low = true } }, at + 1_000);
        try h.ev(5, .{ .data = .{ .rid = rid, .bytes = 2000 } }, at + 1_000);
        try h.finish(5, rid, at + 1_500);
    }
    // 본문 호출은 2 ms 마다 답한다(실측 — 작은 본문은 ms 단위). 5 회차 고침: 보낼 것이 없으면(초당 본문 수 양동이 — 버스트 60 뒤로는 초당 20)
    // 시간을 10 ms 씩 보낸다 — 고치기 전 시험은 여기서 멈춰 「다 받지 못함」 과 「아직 보내지 않음」 을 가르지 못했다. 기다림의 시한까지만.
    var now: i64 = 1_030_000;
    var done: usize = 0;
    while (now < 1_030_000 + waiting_expiry_us) {
        if (h.fetches.items.len > done) {
            const a = h.fetches.items[done];
            done += 1;
            now += 2_000;
            if (h.table.takeInflight(a.fetch.id)) |f| try h.table.bodyDone(gpa_t, f, now);
        } else {
            if (h.fetches.items.len == n or h.ended.count() == n) break;
            now += 10_000;
        }
        try h.table.tick(gpa_t, now);
        try h.drain();
    }
    var busy: usize = 0;
    var it = h.ended.iterator();
    while (it.next()) |e| if (e.value_ptr.* == .busy) {
        busy += 1;
    };
    errdefer std.debug.print("A2: fetched {d}/{d}, busy {d}, last at +{d} ms\n", .{ h.fetches.items.len, n, busy, @divTrunc(now - 1_000_000, 1000) });
    try testing.expectEqual(@as(usize, 0), busy);
    try testing.expectEqual(@as(usize, n), h.fetches.items.len);
}

// ── W9d② 적대 리뷰 5 회차 고침의 시험 ──

test "W9d② 적대 리뷰 5 회차: loadingFailed 의 timestamp 와 자원 종류(type)를 읽는다 — 차례가 뒤인 종류는 문서·스크립트·스타일·이미지·글꼴·미디어" {
    const P = struct {
        fn ev(method: []const u8, json: []const u8) !Event {
            const p = try std.json.parseFromSlice(std.json.Value, gpa_t, json, .{});
            defer p.deinit();
            var e = parseEvent(method, p.value) orelse return error.NoEvent;
            switch (e) {
                .will_be_sent => |*v| v.rid = "",
                .response => |*v| {
                    v.rid = "";
                    v.mime = "";
                    v.sw_source = "";
                },
                .failed => |*v| v.rid = "",
                else => {},
            }
            return e;
        }
    };
    try testing.expectEqual(@as(i64, 7_250_000), (try P.ev("Network.loadingFailed", "{\"requestId\":\"1.2\",\"timestamp\":7.25,\"errorText\":\"net::ERR_ABORTED\",\"canceled\":true}")).failed.ts_us);
    try testing.expectEqual(@as(i64, 0), (try P.ev("Network.loadingFailed", "{\"requestId\":\"1.2\"}")).failed.ts_us);
    try testing.expectEqual(@as(i64, 0), (try P.ev("Network.loadingFailed", "{\"requestId\":\"1.2\",\"timestamp\":-3}")).failed.ts_us);
    try testing.expect((try P.ev("Network.requestWillBeSent", "{\"requestId\":\"1\",\"timestamp\":1,\"type\":\"Script\",\"request\":{\"url\":\"u\",\"method\":\"GET\"}}")).will_be_sent.low);
    try testing.expect(!(try P.ev("Network.requestWillBeSent", "{\"requestId\":\"1\",\"timestamp\":1,\"type\":\"XHR\",\"request\":{\"url\":\"u\",\"method\":\"GET\"}}")).will_be_sent.low);
    try testing.expect((try P.ev("Network.responseReceived", "{\"requestId\":\"1\",\"type\":\"Stylesheet\",\"response\":{\"mimeType\":\"text/css\"}}")).response.low);
    try testing.expect(!(try P.ev("Network.responseReceived", "{\"requestId\":\"1\",\"type\":\"Fetch\",\"response\":{\"mimeType\":\"application/json\"}}")).response.low);
    for ([_][]const u8{ "Document", "Script", "Stylesheet", "Image", "Font", "Media" }) |k| try testing.expect(lowPriority(k));
    for ([_][]const u8{ "XHR", "Fetch", "EventSource", "Manifest", "TextTrack", "Ping", "Other", "Preflight", "", "script" }) |k| try testing.expect(!lowPriority(k));
}

test "W9d② 적대 리뷰 5 회차 A1: CDP 의 실패 시각 뒤에 시작해 아직 끝나지 않은 기록(느린 다시 받기)은 실패한 요청의 시한 뒤 다시 받은 요청의 것 — 실패 시각을 모르거나 맞아 보이지 않으면(UI 가 받은 때) 본문 없이 ambiguous" {
    // 실패 시각: 맞다 / 없다 / UI 가 받은 때보다 2 초 넘게 앞(맞아 보이지 않는다 — 응답 시각과 같은 검사).
    for ([_]i64{ 2_000_300, 0, 100 }) |fail_ts| {
        const cdp_ts = fail_ts == 2_000_300;
        var h: H = .{ .sync = false };
        defer h.deinit();
        _ = try h.table.start(gpa_t, 5, 1);
        const u = "http://127.0.0.1/rv5/slow?a9";
        try h.sent(5, "x.9", u, 2_000_000, 2_000_050);
        try h.ev(5, .{ .failed = .{ .rid = "x.9", .ts_us = fail_ts } }, 2_000_900); // UI 가 받은 때 2_000_900
        try h.sent(5, "p.9", u, 2_000_350, 2_000_950);
        _ = try h.cand(5, 791, u, 2_000_500, .{}); // 다시 받은 요청의 기록 — CDP 실패 시각 뒤, UI 가 받은 때 앞
        try h.flushed(2_001_000, 2_001_000);
        try testing.expect(h.ended.get(791) == null); // 끝을 모른다 — 실패한 요청은 정하지 않는다
        try h.table.tick(gpa_t, 2_000_900 + cef_grace_us + 1_000); // 실패한 요청의 시한
        try h.drain();
        errdefer std.debug.print("A1 slow fail_ts={d} 791={?} p.9={?}\n", .{ fail_ts, h.ended.get(791), fetchedFor(&h, "p.9") });
        if (cdp_ts) {
            try testing.expect(h.ended.get(791) == null); // 실패 시각 뒤에 시작한 기록 — 다음 요청의 것으로 남긴다
            try testing.expectEqual(@as(usize, 1), h.table.tabOf(5).?.cdp.items.len); // x.9 는 짝 없이 놓였다
        } else try testing.expect(stateIs(&h, 791, .ambiguous)); // 실패 앞에 시작한 것으로 보인다 — 다음 요청에 주지 않는다
        try h.respond(5, "p.9", "application/json", 9, 2_400_000);
        try h.finish(5, "p.9", 2_401_000);
        h.table.cefEnd(5, 791, 2_402_000);
        try h.table.tick(gpa_t, 2_450_000);
        try h.drain();
        try h.table.tick(gpa_t, 2_402_000 + unclaimed_expiry_us);
        try h.drain();
        try testing.expectEqual(if (cdp_ts) @as(?u64, 791) else null, fetchedFor(&h, "p.9"));
    }
}

test "W9d② 적대 리뷰 5 회차 A1: abort 가 CEF 에 닿았는데 그 취소의 끝이 시한보다 늦으면 그 기록은 다시 받은 요청에 주지 않는다(ambiguous) — 다시 받은 요청은 그동안 기다렸다가 제 기록" {
    var h: H = .{ .sync = false };
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    const u = "https://app.test/api/me";
    try h.sent(5, "a.0", u, 3_000_000, 3_000_050);
    _ = try h.cand(5, 781, u, 3_000_100, .{}); // abort 한 요청의 기록
    try h.ev(5, .{ .failed = .{ .rid = "a.0", .ts_us = 3_000_300 } }, 3_000_500);
    try h.sent(5, "a.1", u, 3_000_350, 3_000_550);
    _ = try h.cand(5, 782, u, 3_000_400, .{});
    try h.flushed(3_001_000, 3_001_000);
    try h.respond(5, "a.1", "application/json", 9, 3_090_000);
    try h.finish(5, "a.1", 3_100_000);
    try h.flushed(3_100_500, 3_100_500);
    // a.0 이 끝을 모르는 781(a.1 의 짝 782 앞)을 쥐고 있다 — 781 이 성공으로 끝나면 a.1 의 짝이 바뀐다: a.1 은 기다린다.
    try testing.expectEqual(@as(usize, 0), h.fetches.items.len);
    try h.table.tick(gpa_t, 3_000_500 + cef_grace_us + 100);
    try h.drain();
    try testing.expect(stateIs(&h, 781, .ambiguous)); // 실패 시각 앞에 시작했고 끝을 모른다 — a.1 에 주지 않는다
    try testing.expectEqual(@as(?u64, 782), fetchedFor(&h, "a.1"));
    h.table.cefEndAs(5, 781, 3_300_000, false); // 늦은 취소의 끝 — 끝은 하나뿐
    try h.table.tick(gpa_t, 3_400_000);
    try h.drain();
    try testing.expectEqual(@as(u32, 1), endCount(&h, 781));
}

test "W9d② 적대 리뷰 5 회차 A1: CEF 에 닿지 않은 abort 가 끝을 모르는 기록을 쥔 동안 다시 받은 요청은 뒤 요청의 기록을 집지 않는다 — 실패한 요청은 맞추기의 차례를 밀지 않는다" {
    var h: H = .{ .sync = false };
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    const u = "https://app.test/api/feed";
    try h.sent(5, "x.7", u, 5_000_000, 5_000_050); // abort — CEF 에 닿지 않는다
    try h.ev(5, .{ .failed = .{ .rid = "x.7", .ts_us = 5_000_100 } }, 5_000_300);
    try h.sent(5, "p.7", u, 5_000_150, 5_000_350); // 다시 받기
    _ = try h.cand(5, 771, u, 5_000_200, .{});
    try h.sent(5, "q.7", u, 5_000_250, 5_000_400); // 같은 주소의 다른 요청
    _ = try h.cand(5, 773, u, 5_000_300, .{});
    try h.flushed(5_001_000, 5_001_000);
    try h.respond(5, "p.7", "application/json", 9, 5_008_000);
    try h.finish(5, "p.7", 5_009_000);
    try h.flushed(5_009_500, 5_009_500);
    // 고치기 전: x.7 이 771 을, p.7 이 q.7 의 773 을 집어 p.7 의 본문이 q.7 의 기록에 붙었다.
    try testing.expectEqual(@as(usize, 0), h.fetches.items.len);
    h.table.cefEnd(5, 771, 5_012_000);
    // 재검증 3 차: q.7(응답 전)의 기록이 아직 올 수 있는 동안은 p.7 이 그 기록을 가질 수도 있어 기다린다(재검증 3 차 뒤 WB-5: q.7 의 응답까지).
    try h.table.tick(gpa_t, 5_065_000);
    try h.drain();
    try testing.expectEqual(@as(?u64, null), fetchedFor(&h, "p.7"));
    try h.respond(5, "q.7", "application/json", 9, 5_070_000);
    try h.flushed(5_070_500, 5_070_500);
    try h.table.tick(gpa_t, 5_071_000);
    try h.drain();
    // 771 이 성공으로 끝났다 — x.7 은 그것을 놓고 773 을 집지만 차례를 밀지 않는다: p.7 은 곧 771.
    try testing.expectEqual(@as(?u64, 771), fetchedFor(&h, "p.7"));
    try h.finish(5, "q.7", 5_072_000);
    h.table.cefEnd(5, 773, 5_073_000);
    try h.table.tick(gpa_t, 5_080_000);
    try h.drain();
    try testing.expectEqual(@as(?u64, 773), fetchedFor(&h, "q.7"));
    try h.table.tick(gpa_t, 5_000_300 + cef_grace_us + 1);
    try h.drain();
    try testing.expectEqual(@as(usize, 0), h.table.tabOf(5).?.cdp.items.len);
    try testing.expectEqual(@as(usize, 0), h.ends);
}

/// 5 회차 A2 시험: 탭 `b` 에 글 응답 하나(`low` — 스크립트 꼴)를 끝까지 보낸다(같은 시각).
fn bodyAt(h: *H, b: BrowserId, i: usize, low: bool, t: i64) !void {
    var ub: [48]u8 = undefined;
    const url = try std.fmt.bufPrint(&ub, "https://app.test/{s}{d}-{d}", .{ if (low) "s" else "j", b, i });
    var rb: [24]u8 = undefined;
    const rid = try std.fmt.bufPrint(&rb, "{s}{d}.{d}", .{ if (low) "s" else "j", b, i });
    _ = try h.cand(b, b * 100_000 + (if (low) @as(u64, 0) else 50_000) + i, url, t, .{});
    try h.ev(b, .{ .will_be_sent = .{ .rid = rid, .url_hash = hashUrl8(url), .method_hash = hashMethod("GET"), .ts_us = t - 10, .low = low } }, t);
    try h.ev(b, .{ .extra_info = .{ .rid = rid, .credentialed = false } }, t);
    try h.ev(b, .{ .response = .{ .rid = rid, .mime = if (low) "application/javascript" else "application/json", .from_sw = false, .charset = .other } }, t);
    try h.ev(b, .{ .data = .{ .rid = rid, .bytes = 100 } }, t);
    try h.ev(b, .{ .finished = .{ .rid = rid } }, t);
}

test "W9d② 적대 리뷰 5 회차 A2: 기다림의 차례 — 스크립트가 기다림을 채운 뒤 온 fetch 는 가장 새 스크립트를 내주고 들어와 먼저 받는다, 뒤 차례끼리는 새것이 busy, 시한은 줄 가운데의 것도" {
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    const t: i64 = 10_000_000;
    // 스크립트 2(보낸 호출) + 128(기다림).
    for (0..max_waiting_per_tab + 2) |i| try bodyAt(&h, 5, i, true, t);
    const tab = h.table.tabOf(5).?;
    try testing.expectEqual(@as(usize, 2), h.fetches.items.len);
    try testing.expectEqual(max_waiting_per_tab, tab.waiting.items.len);
    try testing.expectEqual(@as(usize, 0), h.ends);
    // fetch 스물 — 저마다 가장 새 스크립트 하나를 busy 로 내주고 앞에 선다.
    for (0..20) |i| try bodyAt(&h, 5, i, false, t + 1_000);
    try testing.expectEqual(max_waiting_per_tab, tab.waiting.items.len);
    try testing.expectEqual(@as(usize, 20), h.ends);
    for (0..20) |k| {
        const victim: u64 = 5 * 100_000 + max_waiting_per_tab + 1 - k; // 가장 새 스크립트부터
        try testing.expect(stateIs(&h, victim, .busy));
    }
    for (tab.waiting.items[0..20]) |w| try testing.expect(!w.low);
    for (tab.waiting.items[20..]) |w| try testing.expect(w.low);
    // 뒤 차례가 또 오면 그것이 busy(앞 차례를 내주지 않는다).
    try bodyAt(&h, 5, 999, true, t + 2_000);
    try testing.expect(stateIs(&h, 5 * 100_000 + 999, .busy));
    // 보낸 호출이 돌아오면 다음은 fetch.
    for (h.fetches.items[0..2]) |a| {
        const f = h.table.takeInflight(a.fetch.id).?;
        try h.table.bodyDone(gpa_t, f, t + 3_000);
    }
    try h.drain();
    try testing.expectEqual(@as(usize, 4), h.fetches.items.len);
    for (h.fetches.items[2..4]) |a| try testing.expectEqual(@as(u8, 'j'), a.fetch.rid.slice()[0]);
    // 시한: 줄 가운데(차례가 뒤라 들어온 때와 자리가 다르다)의 오래된 것도 busy.
    try bodyAt(&h, 5, 500, false, t + 2_000_000);
    try h.table.tick(gpa_t, t + 1_000 + waiting_expiry_us + 1);
    try h.drain();
    try testing.expectEqual(@as(usize, 1), tab.waiting.items.len); // 늦게 온 fetch 하나만 남는다
    try testing.expect(!tab.waiting.items[0].low);
}

test "W9d② 적대 리뷰 5 회차 A2: 기다림의 전체 상한 512 — 네 탭이 채우면 다섯째 탭의 새것은 busy, 찬 탭의 fetch 는 제 스크립트를 내준다" {
    var h: H = .{};
    defer h.deinit();
    for (1..6) |b| _ = try h.table.start(gpa_t, b, 1);
    const t: i64 = 20_000_000;
    for (1..5) |b| for (0..max_waiting_per_tab + 2) |i| try bodyAt(&h, b, i, true, t);
    try testing.expectEqual(max_inflight, h.table.inflight.items.len);
    try testing.expectEqual(max_waiting, h.table.waitingTotal());
    try testing.expectEqual(@as(usize, 0), h.ends);
    try bodyAt(&h, 5, 0, false, t + 1_000);
    try testing.expect(stateIs(&h, 5 * 100_000 + 50_000, .busy)); // 다섯째 탭 — 내줄 제 뒤 차례가 없다
    try bodyAt(&h, 1, 0, false, t + 1_000);
    try testing.expect(h.ended.get(1 * 100_000 + 50_000) == null); // 들어갔다
    try testing.expect(stateIs(&h, 1 * 100_000 + max_waiting_per_tab + 1, .busy)); // 제 가장 새 스크립트를 내줬다
    try testing.expectEqual(max_waiting, h.table.waitingTotal());
    try testing.expect(@sizeOf(Waiting) * max_waiting <= 128 * 1024);
}

test "W9d② 적대 리뷰 5 회차 C1: 넘김 상자가 넘쳐 끝이 버려진 후보도 끝이 꼭 온다 — 짝이 없으면 시한 뒤 unmatched(주기 task 가 멈춘다), 짝이면 ambiguous, 받으러 간 후보는 그대로" {
    // 대조: 표지가 없으면 끝이 오지 않은 후보는 영영 남는다(고치기 전).
    {
        var h: H = .{};
        defer h.deinit();
        _ = try h.table.start(gpa_t, 5, 1);
        _ = try h.cand(5, 800, "https://a.test/lost0", 1_000_000, .{});
        try h.table.tick(gpa_t, 60_000_000);
        try h.drain();
        try testing.expect(h.ended.get(800) == null);
        try testing.expect(h.table.busy());
    }
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    // 짝 없는 후보 — 끝이 버려졌다.
    _ = try h.cand(5, 801, "https://a.test/lost1", 1_000_000, .{});
    h.table.cefLost(5, 801, 1_100_000);
    // 짝이 될 후보 — 응답이 버려졌다(덮이는지 기다리던 것은 덮이지 않는 쪽).
    _ = try h.cand(5, 802, "https://a.test/lost2", 1_000_000, .{ .cover_pending = true });
    h.table.cefLost(5, 802, 1_100_000);
    try h.sent(5, "l.2", "https://a.test/lost2", 999_000, 1_200_000);
    try h.respond(5, "l.2", "application/json", 5, 1_210_000);
    try h.finish(5, "l.2", 1_220_000);
    try testing.expect(stateIs(&h, 802, .ambiguous));
    // 받으러 간(짝지은) 후보는 표지에 흔들리지 않는다.
    _ = try h.cand(5, 803, "https://a.test/ok", 1_300_000, .{});
    try h.sent(5, "o.3", "https://a.test/ok", 1_299_000, 1_300_000);
    try h.respond(5, "o.3", "application/json", 5, 1_310_000);
    try h.finish(5, "o.3", 1_320_000);
    try testing.expectEqual(@as(?u64, 803), fetchedFor(&h, "o.3"));
    h.table.cefLost(5, 803, 1_330_000);
    // 넘침 — 그 탭의 짝 없는 후보 모두(응답 없이 실패한 요청은 그것을 제 것으로 정하지 않는다).
    _ = try h.cand(5, 804, "https://a.test/lost4", 1_400_000, .{});
    _ = try h.cand(5, 805, "https://a.test/lost5", 1_400_000, .{});
    try h.sent(5, "f.5", "https://a.test/lost5", 1_399_000, 1_400_000);
    h.table.cefLostAll(5, 1_450_000);
    try h.ev(5, .{ .failed = .{ .rid = "f.5", .ts_us = 1_460_000 } }, 1_460_000);
    try testing.expect(h.ended.get(805) == null);
    try h.table.tick(gpa_t, 1_460_000 + cef_grace_us + 1);
    try h.drain();
    try testing.expect(stateIs(&h, 805, .ambiguous)); // 실패 앞에 시작했고 결과를 모른다
    try h.table.tick(gpa_t, 1_450_000 + unclaimed_expiry_us);
    try h.drain();
    try testing.expect(stateIs(&h, 801, .unmatched));
    try testing.expect(stateIs(&h, 804, .unmatched));
    try testing.expect(h.ended.get(803) == null); // 받는 중
    const f = h.table.takeInflight(h.fetches.items[0].fetch.id).?;
    try h.table.bodyDone(gpa_t, f, 4_500_000);
    try h.drain();
    try testing.expect(!h.table.busy()); // 주기 task 가 멈춘다
}

test "W9d② 적대 리뷰 5 회차 A1: 물 높이는 CDP 의 실패 시각까지만 기다린다 — CEF 가 실패로 끝낸 기록이 와 있으면 UI 가 실패를 받은 때까지의 기록을 기다리지 않고 곧 request_failed" {
    var h: H = .{ .sync = false };
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    const u = "https://app.test/api/x";
    try h.sent(5, "a.0", u, 3_000_000, 3_000_050);
    _ = try h.cand(5, 781, u, 3_000_100, .{});
    h.table.cefEndAs(5, 781, 3_000_350, false);
    try h.flushed(3_000_400, 3_000_400); // 물 높이 — CDP 실패 시각(3_000_300) 뒤, UI 가 받은 때(3_000_500) 앞
    try h.ev(5, .{ .failed = .{ .rid = "a.0", .ts_us = 3_000_300 } }, 3_000_500);
    // 재검증 3 차 뒤 PF-2: 응답 없이 실패한 요청은 다음 주기가 정한다 — 물 높이는 그대로(3_000_400)여도 곧.
    try h.table.tickAt(gpa_t, 3_000_550, 3_000_400);
    try h.drain();
    try testing.expect(stateIs(&h, 781, .request_failed));
}

test "W9d② 적대 리뷰 5 회차 A2: 자원 종류를 응답에서만 알아도(requestWillBeSent 에 없다) 뒤 차례다" {
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    const t: i64 = 30_000_000;
    for (0..2) |i| try bodyAt(&h, 5, i, false, t); // 보낸 호출 둘 — 자리를 채운다
    const u = "https://app.test/late.js";
    _ = try h.cand(5, 9100, u, t, .{});
    try h.sent(5, "z.1", u, t - 10, t);
    try h.ev(5, .{ .response = .{ .rid = "z.1", .mime = "application/javascript", .from_sw = false, .charset = .other, .low = true } }, t);
    try h.finish(5, "z.1", t);
    try bodyAt(&h, 5, 7, false, t + 10);
    const tab = h.table.tabOf(5).?;
    try testing.expectEqual(@as(usize, 2), tab.waiting.items.len);
    try testing.expect(!tab.waiting.items[0].low); // 뒤에 온 fetch 가 앞에 선다
    try testing.expect(tab.waiting.items[1].low and tab.waiting.items[1].request == 9100);
}

// ── W9d② v20 A R8(적대 검증 — 자원 상한, 순수): 버스트 60 의 경계와 초당 20 의 다음 자리(50 ms 의 앞·뒤), 1 MiB 상한의 경계(꼭 1 MiB 는 받고
// +1 은 over_cap — dataReceived 가 여러 조각이어도), 탭 바이트 양동이(4 MiB/s — 1 MiB 본문 다섯째는 250 ms 뒤), 앞 차례만 찬 기다림에 온 새것은
// 앞 차례를 밀어내지 않고 제가 busy, 끝은 요청마다 꼭 하나.

/// 탭 `b` 에 `bytes` 바이트(조각 `pieces` 개로 나눈) 응답 하나를 끝까지(같은 시각) — 앞 차례(JSON).
fn v20Body(h: *H, b: BrowserId, request: u64, bytes: u64, pieces: u64, t: i64) !void {
    var ub: [48]u8 = undefined;
    const url = try std.fmt.bufPrint(&ub, "https://app.test/v20/{d}", .{request});
    var rb: [24]u8 = undefined;
    const rid = try std.fmt.bufPrint(&rb, "v.{d}", .{request});
    _ = try h.cand(b, request, url, t, .{});
    try h.sent(b, rid, url, t - 10, t);
    try h.ev(b, .{ .response = .{ .rid = rid, .mime = "application/json", .from_sw = false, .charset = .other } }, t);
    var left = bytes;
    for (0..pieces) |k| {
        const n = if (k + 1 == pieces) left else bytes / pieces;
        left -= n;
        try h.ev(b, .{ .data = .{ .rid = rid, .bytes = n } }, t);
    }
    try h.finish(b, rid, t);
}

/// 보낸 호출을 모두 곧 돌려준다(`got` 부터).
fn v20Return(h: *H, got: *usize, t: i64) !void {
    while (got.* < h.fetches.items.len) : (got.* += 1) {
        const f = h.table.takeInflight(h.fetches.items[got.*].fetch.id) orelse continue;
        try h.table.bodyDone(gpa_t, f, t);
        try h.drain();
    }
}

test "W9d② v20 A R8: 본문 수 버스트 60 의 경계 — 같은 순간 61 개면 60 개가 나가고, 다음 자리는 꼭 50 ms 뒤(49.999 ms 에는 아니다)" {
    for ([_]i64{ 49_999, 50_000 }) |later| {
        var h: H = .{};
        defer h.deinit();
        _ = try h.table.start(gpa_t, 1, 1);
        const t: i64 = 7_000_000;
        var got: usize = 0;
        for (0..61) |i| {
            try v20Body(&h, 1, 100 + i, 10, 1, t);
            try v20Return(&h, &got, t);
        }
        try testing.expectEqual(@as(usize, 60), h.fetches.items.len);
        try testing.expectEqual(@as(usize, 1), h.table.tabOf(1).?.waiting.items.len);
        try h.table.tick(gpa_t, t + later);
        try h.drain();
        errdefer std.debug.print("R8 burst: later={d} fetches={d}\n", .{ later, h.fetches.items.len });
        try testing.expectEqual(@as(usize, if (later >= 50_000) 61 else 60), h.fetches.items.len);
        try testing.expectEqual(@as(usize, 0), h.ends); // 아무것도 busy 가 아니다
    }
}

test "W9d② v20 A R8: 1 MiB 상한의 경계 — dataReceived 합이 꼭 1 MiB 면 받으러 가고(조각 셋이어도), 1 바이트 넘으면 over_cap(한 조각이어도), 0 바이트 글은 결과를 본 뒤" {
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 1, 1);
    const t: i64 = 8_000_000;
    const cap: u64 = msg.max_net_body_bytes;
    try v20Body(&h, 1, 1, cap, 3, t);
    try testing.expectEqual(@as(usize, 1), h.fetches.items.len);
    try testing.expect(h.ended.get(1) == null);
    try v20Body(&h, 1, 2, cap + 1, 3, t);
    try testing.expect(stateIs(&h, 2, .over_cap));
    try v20Body(&h, 1, 3, cap + 1, 1, t);
    try testing.expect(stateIs(&h, 3, .over_cap));
    try testing.expectEqual(@as(usize, 1), h.fetches.items.len); // 넘친 것은 받으러 가지 않았다
    // 0 바이트 글 — 받으러 가서(빈 결과의 상태는 결과를 본 뒤 — `emptyBodyState`) 끝은 아직이다.
    try v20Body(&h, 1, 4, 0, 0, t);
    try testing.expect(h.ended.get(4) == null);
    try testing.expectEqual(@as(usize, 2), h.fetches.items.len);
}

test "W9d② v20 A R8: 탭 바이트 양동이(4 MiB/s) — 1 MiB 본문 넷은 곧, 다섯째는 250 ms 뒤(249.999 ms 에는 아니다), 다른 탭은 제 양동이로 곧" {
    for ([_]i64{ 249_999, 250_000 }) |later| {
        var h: H = .{};
        defer h.deinit();
        _ = try h.table.start(gpa_t, 1, 1);
        _ = try h.table.start(gpa_t, 2, 1);
        const t: i64 = 9_000_000;
        var got: usize = 0;
        for (0..5) |i| {
            try v20Body(&h, 1, 10 + i, msg.max_net_body_bytes, 1, t);
            try v20Return(&h, &got, t);
        }
        try testing.expectEqual(@as(usize, 4), h.fetches.items.len);
        // 다른 탭의 1 MiB 는 곧(전체 8 MiB/s 안 — 4 + 1).
        try v20Body(&h, 2, 50, msg.max_net_body_bytes, 1, t);
        try v20Return(&h, &got, t);
        try testing.expectEqual(@as(usize, 5), h.fetches.items.len);
        try h.table.tick(gpa_t, t + later);
        try h.drain();
        errdefer std.debug.print("R8 bytes: later={d} fetches={d}\n", .{ later, h.fetches.items.len });
        try testing.expectEqual(@as(usize, if (later >= 250_000) 6 else 5), h.fetches.items.len);
        try testing.expectEqual(@as(usize, 0), h.ends);
    }
}

test "W9d② v20 A R8: 앞 차례만으로 찬 기다림(128) — 새 앞 차례도 뒤 차례도 제가 busy(앞 차례를 밀어내지 않는다), 끝은 꼭 하나, 자리가 나면 들어온 차례로" {
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    const t: i64 = 11_000_000;
    for (0..max_waiting_per_tab + 2) |i| try bodyAt(&h, 5, i, false, t); // fetch 2 + 기다림 128(모두 앞 차례)
    const tab = h.table.tabOf(5).?;
    try testing.expectEqual(max_waiting_per_tab, tab.waiting.items.len);
    try testing.expectEqual(@as(usize, 0), h.ends);
    try bodyAt(&h, 5, 900, false, t + 1);
    try testing.expect(stateIs(&h, 5 * 100_000 + 50_000 + 900, .busy));
    try bodyAt(&h, 5, 901, true, t + 1);
    try testing.expect(stateIs(&h, 5 * 100_000 + 901, .busy));
    try testing.expectEqual(@as(usize, 2), h.ends);
    try testing.expectEqual(max_waiting_per_tab, tab.waiting.items.len);
    // 들어온 차례 — 다음에 나가는 것은 세 번째로 들어온 것.
    const f = h.table.takeInflight(h.fetches.items[0].fetch.id).?;
    try h.table.bodyDone(gpa_t, f, t + 2);
    try h.drain();
    try testing.expectEqual(@as(usize, 3), h.fetches.items.len);
    try testing.expectEqualStrings("j5.2", h.fetches.items[2].fetch.rid.slice());
    var it = h.end_counts.valueIterator();
    while (it.next()) |c| try testing.expectEqual(@as(u32, 1), c.*);
}

// W9d② v20 A R9(실제 CEF 154 — 판정 `v20a-r9-navigation-pending`, 본문 로그): 주 프레임이 다른 문서로 옮기면 옛 문서의 진행 중 요청은 CEF 가 취소로
// 끝내지만 CDP 는 loadingFinished·loadingFailed 를 보내지 않았다(끊긴 34 개 중 cdp-fail 0). 그 요청의 본문 끝은 짝 없는 후보의 시한으로 꼭 하나
// 나오지만(unmatched), 끝나지 않은 CDP 요청은 표에 남았다(D3 — 고친 뒤: `cdpWindowPassed`·`cdpMayPair`). 새 문서의 시작(`documentStarted`)을 표가 알면 그 끝은 곧
// `unavailable` 이다(N1 — 아래 「20 회 검증 N1」); 이 시험은 그 알림이 없을 때의 길이다.
test "W9d② v20 A R9: 이동으로 CDP 끝이 오지 않는 요청 — 새 문서 시작을 못 봤어도 본문 끝은 꼭 하나(unmatched)이고, 표는 끝내 한가해진다(50 ms 주기 task 가 멈춘다)" {
    const u = "http://127.0.0.1/v20/d?pd0";
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    try h.sent(5, "r.1", u, 1_000_000, 1_000_100);
    _ = try h.cand(5, 900, u, 1_000_050, .{});
    try h.ev(5, .{ .response = .{ .rid = "r.1", .mime = "application/json", .from_sw = false, .charset = .other } }, 1_010_000);
    // 이동: CEF 가 취소로 끝낸다. CDP 끝은 오지 않는다.
    h.table.cefEndAs(5, 900, 1_400_000, false);
    var now: i64 = 1_400_000;
    while (now < 61_400_000) : (now += 50_000) {
        try h.table.tickAt(gpa_t, now, now);
        try h.drain();
    }
    try testing.expectEqual(@as(u32, 1), endCount(&h, 900));
    try testing.expect(stateIs(&h, 900, .unmatched));
    // 대조로 앞의 것은 통과한다. 이것이 거짓이면 끝나지 않은 CDP 요청이 기록 내내 남아 `busy()` 가 참이다(주기 task 가 멈추지 않는다).
    try testing.expect(!h.table.busy());
}

test "W9d② v20 A R9: 이동으로 끝나지 않은 같은 주소의 CDP 요청이 남아도, 곧 다시 불러온 문서의 같은 주소 요청은 제 기록을 받는다(틀린 본문 없음)" {
    const u = "http://127.0.0.1/v20/r9/hold1?k=0";
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    // 옛 문서: 보냈고 머리가 왔고, 이동으로 CEF 가 취소로 끝냈다 — CDP 끝은 없다.
    try h.sent(5, "o.1", u, 1_000_000, 1_000_100);
    _ = try h.cand(5, 900, u, 1_000_050, .{});
    try h.ev(5, .{ .response = .{ .rid = "o.1", .mime = "application/json", .from_sw = false, .charset = .other } }, 1_010_000);
    h.table.cefEndAs(5, 900, 1_300_000, false);
    // 새 문서(300 ms 뒤): 같은 주소를 다시 — 곧 끝난다.
    try h.sent(5, "n.1", u, 1_350_000, 1_350_100);
    _ = try h.cand(5, 901, u, 1_350_050, .{});
    try h.respond(5, "n.1", "application/json", 9, 1_352_000);
    h.table.cefEnd(5, 901, 1_353_000);
    try h.finish(5, "n.1", 1_353_500);
    var now: i64 = 1_353_500;
    while (now < 5_000_000) : (now += 50_000) {
        try h.table.tickAt(gpa_t, now, now);
        try h.drain();
    }
    var buf: [8]u64 = undefined;
    const got = h.fetchedRequests(&buf);
    // 새 요청의 본문 호출은 새 기록(901)으로만 — 옛 기록(900)에 가지 않는다.
    for (got) |rq| try testing.expect(rq != 900);
    try testing.expectEqual(@as(u32, 1), endCount(&h, 900));
}

// ── W9d② 20 회 검증 고침(D3·N1) ─────────────────────────────────────────────────────────────────────────────
// 증명하는 것: 주 프레임이 새 문서로 옮기면 앞 문서와 함께 끊긴 요청(CEF 는 취소로 끝내고 CDP 는 끝을 보내지 않는다)의 본문 끝은 곧(`cef_grace_us`
// 뒤) `unavailable` 하나다 — 새 문서 뒤에 시작한 요청의 실패와 CDP 실패가 곧 온 요청은 그 규칙을 타지 않는다(N1). 끝이 오지 않을 열린 CDP 요청은
// 창이 지나고 짝일 수 있는 후보가 없으면 놓여 표가 한가해진다 — 짝이 살아 있는 긴 요청은 놓지 않는다(D3). 자리가 차면 오래된 것을 묶음으로 놓는다.

test "W9d② 20 회 검증 N1: 새 문서 앞에 시작해 CEF 가 취소로 끝낸 요청은 곧 unavailable 하나, 성공으로 끝났는데 CDP 끝이 없으면 시한 뒤 unavailable — 새 문서 뒤의 실패·기록이 버려진 것은 unmatched, CDP 실패가 곧 오면 request_failed, CDP 끝이 늦은 성공은 제 본문" {
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    // 앞 문서의 요청 셋: 900 은 머리가 왔고 끊긴다, 902 는 CDP 실패가 곧 온다.
    try h.sent(5, "r.1", "http://127.0.0.1/v20/n1/a", 1_000_000, 1_000_100);
    _ = try h.cand(5, 900, "http://127.0.0.1/v20/n1/a", 1_000_050, .{});
    try h.ev(5, .{ .response = .{ .rid = "r.1", .mime = "application/json", .from_sw = false, .charset = .other } }, 1_010_000);
    try h.sent(5, "r.3", "http://127.0.0.1/v20/n1/c", 1_100_000, 1_100_100);
    _ = try h.cand(5, 902, "http://127.0.0.1/v20/n1/c", 1_100_050, .{});
    // 대조: 앞 문서 때 시작해 CEF 가 성공으로 끝낸 요청(새 문서의 문서 요청 자체·keepalive) — CDP 끝이 늦어도 제 본문을 받는다.
    try h.sent(5, "r.4", "http://127.0.0.1/v20/n1/d", 1_200_000, 1_200_100);
    _ = try h.cand(5, 903, "http://127.0.0.1/v20/n1/d", 1_200_050, .{});
    // 대조: 기록이 버려진 후보(`lost` — 결과를 모른다)는 끊긴 것으로 치지 않는다(시한 뒤 unmatched).
    _ = try h.cand(5, 904, "http://127.0.0.1/v20/n1/e", 1_250_000, .{});
    // 앞 문서 때 시작해 문서가 떠난 뒤 CEF 가 성공으로 끝냈는데 CDP 끝은 끝내 오지 않는다 — 짝 없는 시한 뒤 unmatched 가 아니라 unavailable.
    try h.sent(5, "r.6", "http://127.0.0.1/v20/n1/f", 1_260_000, 1_260_100);
    _ = try h.cand(5, 905, "http://127.0.0.1/v20/n1/f", 1_260_050, .{});
    // 새 문서가 시작된다.
    h.table.documentStarted(5, 1_300_000);
    h.table.cefEnd(5, 903, 1_350_000);
    h.table.cefEnd(5, 905, 1_350_000);
    h.table.cefEndAs(5, 904, 1_350_000, false);
    h.table.cefLost(5, 904, 1_360_000);
    h.table.cefEndAs(5, 900, 1_350_000, false);
    h.table.cefEndAs(5, 902, 1_330_000, false);
    try h.ev(5, .{ .failed = .{ .rid = "r.3", .ts_us = 1_335_000 } }, 1_340_000);
    // 새 문서 뒤에 시작해 실패한 요청(CDP 는 보지 못했다) — 끊긴 것이 아니다.
    _ = try h.cand(5, 901, "http://127.0.0.1/v20/n1/b", 1_400_000, .{});
    h.table.cefEndAs(5, 901, 1_450_000, false);
    // 시한 전(끝 + 250 ms 앞)에는 끝내지 않는다.
    try h.table.tickAt(gpa_t, 1_599_999, 1_599_999);
    try h.drain();
    try testing.expect(h.ended.get(900) == null);
    try h.table.tickAt(gpa_t, 1_600_000, 1_600_000);
    try h.drain();
    try testing.expect(stateIs(&h, 900, .unavailable));
    try testing.expect(stateIs(&h, 902, .request_failed));
    try testing.expect(h.ended.get(901) == null);
    try testing.expect(h.ended.get(903) == null and h.ended.get(904) == null and h.ended.get(905) == null);
    try h.respond(5, "r.4", "application/json", 5, 1_700_000);
    try h.finish(5, "r.4", 1_700_000);
    var fb: [4]u64 = undefined;
    try testing.expectEqualSlices(u64, &.{903}, h.fetchedRequests(&fb));
    // 903 의 본문 호출을 곧 돌려준다(끝은 본문 호출이 낸다 — 표의 몫이 아니다).
    const f = h.table.takeInflight(h.fetches.items[0].fetch.id).?;
    try h.table.bodyDone(gpa_t, f, 1_700_000);
    try h.drain();
    var now: i64 = 1_650_000;
    while (now < 10_000_000) : (now += 50_000) {
        try h.table.tickAt(gpa_t, now, now);
        try h.drain();
    }
    try testing.expect(stateIs(&h, 901, .unmatched));
    try testing.expect(stateIs(&h, 904, .unmatched));
    try testing.expect(stateIs(&h, 905, .unavailable));
    for ([_]u64{ 900, 901, 902, 904, 905 }) |r| try testing.expectEqual(@as(u32, 1), endCount(&h, r));
    try testing.expect(!h.table.busy());
}

test "W9d② 20 회 검증 D3: 열린 CDP 요청은 짝이 살아 있으면 창이 지나도 놓지 않는다 — 긴 요청이 끝나면 제 기록이 본문을 받는다, 끊긴 것은 놓여 표가 한가해진다" {
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    // 긴 요청(10 초) — 후보는 끝나지 않은 채 산다.
    try h.sent(5, "l.1", "http://127.0.0.1/v20/long", 1_000_000, 1_000_100);
    _ = try h.cand(5, 909, "http://127.0.0.1/v20/long", 1_000_050, .{});
    // 끊긴 요청 — 후보 없음(문이 넘겼다), 끝도 오지 않는다.
    try h.sent(5, "o.1", "http://127.0.0.1/v20/orphan", 1_000_000, 1_000_100);
    // 끊긴 요청 — 페이지의 응답(서비스 워커 아님)이 왔다. 같은 주소의 워커 기록(서비스 워커 갈래 — 짝이 될 수 없다)이 살아 있어도 놓는다.
    try h.sent(5, "w.1", "http://127.0.0.1/v20/worker-same", 1_000_000, 1_000_100);
    try h.ev(5, .{ .response = .{ .rid = "w.1", .mime = "application/json", .from_sw = false, .charset = .other } }, 1_010_000);
    _ = try h.cand(5, 908, "http://127.0.0.1/v20/worker-same", 1_000_060, .{ .sw = true });
    var now: i64 = 1_050_000;
    while (now < 11_000_000) : (now += 50_000) {
        try h.table.tickAt(gpa_t, now, now);
        try h.drain();
    }
    const tab = h.table.tabOf(5).?;
    try testing.expectEqual(@as(usize, 1), tab.cdp.items.len);
    try testing.expect(tab.cdp.items[0].rid.eql("l.1"));
    try h.respond(5, "l.1", "application/json", 7, 11_000_000);
    h.table.cefEnd(5, 909, 11_001_000);
    try h.finish(5, "l.1", 11_002_000);
    try h.table.tickAt(gpa_t, 11_003_000, 11_003_000);
    try h.drain();
    var buf: [4]u64 = undefined;
    try testing.expectEqualSlices(u64, &.{909}, h.fetchedRequests(&buf));
    // 끊긴 것이 늦게 끝나도 자리가 없다 — 아무 일도 없다.
    try h.finish(5, "o.1", 11_004_000);
    try testing.expectEqual(@as(usize, 0), tab.cdp.items.len);
    try testing.expectEqual(@as(usize, 0), h.ends);
}

test "W9d② 20 회 검증 D3: CDP 자리가 차면 가장 오래된 것을 묶음(256)으로 놓는다 — 새것과 그 앞의 차례는 그대로" {
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    var rb: [24]u8 = undefined;
    var ub: [48]u8 = undefined;
    for (0..max_cdp + 1) |i| {
        const rid = try std.fmt.bufPrint(&rb, "c.{d}", .{i});
        const url = try std.fmt.bufPrint(&ub, "http://127.0.0.1/v20/cap/{d}", .{i});
        // 쏟아짐 밸브(초당 5000)를 넘지 않게 사건마다 1 ms.
        const t: i64 = 1_000_000 + @as(i64, @intCast(i)) * 1_000;
        try h.table.cdpEvent(gpa_t, 5, .{ .will_be_sent = .{ .rid = rid, .url_hash = hashUrl8(url), .method_hash = hashMethod("GET"), .ts_us = t } }, t);
    }
    const tab = h.table.tabOf(5).?;
    try testing.expectEqual(max_cdp - cdp_evict_batch + 1, tab.cdp.items.len);
    try testing.expect(tab.cdp.items[0].rid.eql("c.256"));
    try testing.expect(tab.cdp.items[tab.cdp.items.len - 1].rid.eql("c.4096"));
}

test "W9d② 20 회 검증 D3: 창이 지난 뒤 같은 번호로 다시 시작한 요청 — CDP 의 다시 보내기가 늦어도 그 CDP 요청을 놓지 않아 다시 시작한 시도가 본문을 받는다" {
    const u = "http://127.0.0.1/v20/restart-late";
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    try h.sent(5, "s.1", u, 1_000_000, 1_000_100);
    _ = try h.cand(5, 950, u, 1_000_050, .{});
    // 2.5 초 뒤 Chromium 이 같은 번호로 다시 시작한다(느린 서버의 Critical-CH) — CEF 의 새 시작이 먼저 온다(앞 시도는 restarted).
    _ = try h.cand(5, 950, u, 3_500_000, .{});
    try testing.expect(stateIs(&h, 950, .restarted));
    // 앞 시도의 창은 지났지만 다시 시작한 시도가 있다 — 그 CDP 요청을 놓지 않는다.
    try h.table.tickAt(gpa_t, 3_600_000, 3_600_000);
    try h.drain();
    try testing.expectEqual(@as(usize, 1), h.table.tabOf(5).?.cdp.items.len);
    // CDP 의 다시 보내기(같은 주소의 리다이렉트로 알린다)와 끝.
    try h.ev(5, .{ .will_be_sent = .{ .rid = "s.1", .url_hash = hashUrl8(u), .method_hash = hashMethod("GET"), .ts_us = 3_500_100, .redirect = true } }, 3_610_000);
    try h.ev(5, .{ .extra_info = .{ .rid = "s.1", .credentialed = false } }, 3_610_000);
    try h.respond(5, "s.1", "application/json", 4, 3_620_000);
    h.table.cefEnd(5, 950, 3_630_000);
    try h.finish(5, "s.1", 3_640_000);
    try h.table.tickAt(gpa_t, 3_700_000, 3_700_000);
    try h.drain();
    var buf: [4]u64 = undefined;
    try testing.expectEqualSlices(u64, &.{950}, h.fetchedRequests(&buf));
}

test "W9d② 20 회 검증 D3: 물 높이가 창 끝에 닿기 전에는 열린 CDP 요청을 놓지 않는다 — IO 스레드가 늦어 제 CEF 기록이 2 초 넘게 늦게 와도 짝을 짓는다" {
    const u = "http://127.0.0.1/v20/late-cef";
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    try h.sent(5, "q.1", u, 1_000_000, 1_000_100);
    // 2.1 초 뒤 — 시간은 창을 지났지만 CEF 기록은 IO 시각 2.9 초까지만 왔다(창 끝 3.0 초 앞): 놓지 않는다.
    try h.table.tickAt(gpa_t, 3_100_000, 2_900_000);
    try h.drain();
    try testing.expectEqual(@as(usize, 1), h.table.tabOf(5).?.cdp.items.len);
    // 늦은 제 기록(IO 시각 1.5 초 — 창 안)이 오고 요청이 끝난다.
    _ = try h.cand(5, 960, u, 1_500_000, .{});
    try h.respond(5, "q.1", "application/json", 3, 3_200_000);
    h.table.cefEnd(5, 960, 3_210_000);
    try h.finish(5, "q.1", 3_220_000);
    try h.table.tickAt(gpa_t, 3_300_000, 3_300_000);
    try h.drain();
    var buf: [4]u64 = undefined;
    try testing.expectEqualSlices(u64, &.{960}, h.fetchedRequests(&buf));
}

// ── W9d② 최종 재검증(검증자 v20f A 의 재현을 회귀 시험으로 — D-A·D-B·N-a) ──────────────────────────────────────────
// 증명하는 것: 새 문서와 함께 끊긴 앞 문서의 기록을 N1 이 끝낼 때 그 기록을 짝으로 쥔 열린 CDP 요청도 함께 놓여, 같은 주소를 다시 불러온 문서의
// 요청이 제 기록을 받는다(끊김 + 250 ms 뒤에 끝나도, 3 초 넘게 늦어도) — 새 문서 맨 앞의 abort 의 CDP 실패가 늦어도 다시 받은 요청은 제 것(D-A·
// R5-1). CDP 자리 상한의 묶음 놓기는 놓인 요청의 기록을 다른 요청에 붙이지 않는다(D-B). 끊긴 CDP 자리 훑기의 색인은 모든 후보를 훑던 판정과
// 같다(N-a).

/// 옛 문서 요청 A(머리 전 — 응답 없음, `a_responded` 면 머리가 왔다)가 이동으로 끊기고, 새 문서가 같은 주소 B 를 곧 다시 받는다. `doc` 이면 새 문서
/// 시작을 표에 알린다(N1). `b_finish` 는 B 의 CDP 끝 시각(A 의 CEF 취소는 1.3 s).
fn v20fReload(h: *H, doc: bool, a_responded: bool, b_finish: i64) !void {
    const u = "http://127.0.0.1/v20f/r9/api";
    _ = try h.table.start(gpa_t, 5, 1);
    try h.sent(5, "o.1", u, 1_000_000, 1_000_100);
    _ = try h.cand(5, 900, u, 1_000_050, .{});
    if (a_responded) try h.ev(5, .{ .response = .{ .rid = "o.1", .mime = "application/json", .from_sw = false, .charset = .other } }, 1_010_000);
    if (doc) h.table.documentStarted(5, 1_300_000);
    h.table.cefEndAs(5, 900, 1_300_000, false);
    // 새 문서의 같은 주소(350 ms 뒤 시작 — A 의 창 2 s 안).
    try h.sent(5, "n.1", u, 1_350_000, 1_350_100);
    _ = try h.cand(5, 901, u, 1_350_050, .{});
    var now: i64 = 1_350_100;
    while (now + 50_000 <= b_finish) : (now += 50_000) {
        try h.table.tickAt(gpa_t, now, now);
        try h.drain();
    }
    try h.respond(5, "n.1", "application/json", 9, b_finish - 2_000);
    h.table.cefEnd(5, 901, b_finish - 1_000);
    try h.finish(5, "n.1", b_finish);
    now = b_finish;
    // 4 s — 짝 없는 시한(3 s)은 지나고 본문 호출의 시한(5 s)은 아직(호출이 `inflight` 에 남아 `fetchedRequests` 가 본다).
    while (now < b_finish + 4_000_000) : (now += 50_000) {
        try h.table.tickAt(gpa_t, now, now);
        try h.drain();
    }
}

test "W9d② 최종 재검증 D-A(v20f A R9-1): 머리 전에 끊긴 앞 문서 요청 — 끊긴 기록과 함께 그 CDP 요청도 놓여, 같은 주소를 다시 불러온 문서의 요청은 끊김 + 250 ms 뒤에 끝나도·짝 없는 시한(3 s) 넘게 늦어도 제 본문, 앞 기록은 unavailable 하나" {
    inline for (.{ 1_700_000, 2_400_000, 4_800_000 }) |b_finish| {
        var h: H = .{};
        defer h.deinit();
        try v20fReload(&h, true, false, b_finish);
        var buf: [4]u64 = undefined;
        const got = h.fetchedRequests(&buf);
        errdefer std.debug.print("D-A b_finish={d}: fetched {any} · 900 {?} · 901 {?} · ends 900={d} 901={d}\n", .{ b_finish, got, h.ended.get(900), h.ended.get(901), endCount(&h, 900), endCount(&h, 901) });
        try testing.expectEqualSlices(u64, &.{901}, got); // B 는 제 본문, A 의 기록에는 없다
        try testing.expectEqual(@as(u32, 1), endCount(&h, 900));
        try testing.expect(stateIs(&h, 900, .unavailable));
        try testing.expect(h.ended.get(901) == null); // B 의 끝은 본문 호출이 낸다
        try testing.expectEqual(@as(usize, 0), h.table.tabOf(5).?.cdp.items.len); // 끝이 오지 않는 A 는 남지 않는다
    }
}

test "W9d② 최종 재검증 D-A 대조(v20f A R9-1): 새 문서 시작 알림이 없으면(N1 이전의 길) B 는 제 본문 · A 가 머리를 받았으면 N1 이 있어도 제 본문 · B 가 끊김 + 250 ms 안에 끝나도 제 본문" {
    inline for (.{ .{ false, false, 1_700_000 }, .{ true, true, 1_700_000 }, .{ true, false, 1_450_000 } }) |c| {
        var h: H = .{};
        defer h.deinit();
        try v20fReload(&h, c[0], c[1], c[2]);
        var buf: [4]u64 = undefined;
        const got = h.fetchedRequests(&buf);
        errdefer std.debug.print("D-A control doc={} a_responded={} b_finish={d}: fetched {any} · 901 {?}\n", .{ c[0], c[1], c[2], got, h.ended.get(901) });
        try testing.expectEqualSlices(u64, &.{901}, got);
        try testing.expectEqual(@as(u32, 1), endCount(&h, 900));
    }
}

test "W9d② 최종 재검증 D-A: 앞 문서의 같은 주소 요청 넷(머리 전)과 다시 불러온 문서의 넷 — 끊긴 넷은 unavailable, 새 넷은 모두 제 본문(실제 CEF 9 회차의 꼴: 다른 호스트·400 ms)" {
    const u = "http://localhost/v20f/r9/rlp";
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    var rb: [16]u8 = undefined;
    for (0..4) |k| {
        const ki: i64 = @intCast(k);
        try h.sent(5, try std.fmt.bufPrint(&rb, "o.{d}", .{k}), u, 1_000_000 + ki * 1_000, 1_000_100 + ki * 1_000);
        _ = try h.cand(5, 900 + k, u, 1_000_050 + ki * 1_000, .{});
    }
    h.table.documentStarted(5, 1_300_000);
    for (0..4) |k| h.table.cefEndAs(5, 900 + k, 1_300_000, false);
    for (0..4) |k| {
        const ki: i64 = @intCast(k);
        try h.sent(5, try std.fmt.bufPrint(&rb, "n.{d}", .{k}), u, 1_400_000 + ki * 1_000, 1_400_100 + ki * 1_000);
        _ = try h.cand(5, 910 + k, u, 1_400_050 + ki * 1_000, .{});
    }
    var now: i64 = 1_400_000;
    while (now < 1_800_000) : (now += 50_000) {
        try h.table.tickAt(gpa_t, now, now);
        try h.drain();
    }
    // 새 요청은 거꾸로 끝난다(마지막 것이 먼저).
    var k: usize = 4;
    while (k > 0) {
        k -= 1;
        const ki: i64 = @intCast(k);
        const rid = try std.fmt.bufPrint(&rb, "n.{d}", .{k});
        try h.respond(5, rid, "application/json", 9, 1_800_000 + (3 - ki) * 1_000);
        h.table.cefEnd(5, 910 + k, 1_800_500 + (3 - ki) * 1_000);
        try h.finish(5, rid, 1_800_900 + (3 - ki) * 1_000);
    }
    // 본문 호출은 탭마다 둘 — 답을 곧 돌려줘 기다리던 것이 나가게 하며 받은 요청을 모은다.
    var got: [8]u64 = undefined;
    var n: usize = 0;
    var done: usize = 0;
    // 재검증 2–9 회차 WB: 끊긴 기록마다 주인일 수 있는 열린 앞 문서 요청이 넷이라 끊김(+250 ms)에 지우지 않고 짝 없는 시한(CEF 끝 + 3 s)에
    // 끝낸다 — 그동안 기록이 차례에 남아 새 넷은 제 기록을 받는다.
    while (now < 1_300_000 + unclaimed_expiry_us + 100_000) : (now += 50_000) {
        try h.table.tickAt(gpa_t, now, now);
        try h.drain();
        while (done < h.fetches.items.len) : (done += 1) {
            const f = h.table.takeInflight(h.fetches.items[done].fetch.id) orelse continue;
            if (n < got.len) got[n] = f.request;
            n += 1;
            try h.table.bodyDone(gpa_t, f, now);
            try h.drain();
        }
    }
    errdefer std.debug.print("D-A four: fetched {any}\n", .{got[0..@min(n, got.len)]});
    try testing.expectEqual(@as(usize, 4), n);
    std.mem.sort(u64, got[0..4], {}, std.sort.asc(u64));
    try testing.expectEqualSlices(u64, &.{ 910, 911, 912, 913 }, got[0..4]);
    for (900..904) |r| {
        try testing.expect(stateIs(&h, r, .unavailable));
        try testing.expectEqual(@as(u32, 1), endCount(&h, r));
    }
}

test "W9d② 최종 재검증 D-A: 끊긴 기록을 짝으로 쥔 요청의 CDP 실패가 왔는데 물 높이를 기다리면 끊김은 그 판정을 기다린다 — request_failed 하나(놓아 unavailable 로 덮지 않는다)" {
    const u = "http://127.0.0.1/v20f/da/wait";
    var h: H = .{};
    defer h.deinit();
    h.sync = false;
    _ = try h.table.start(gpa_t, 5, 1);
    try h.sent(5, "a", u, 1_000_000, 1_000_100);
    _ = try h.cand(5, 900, u, 1_000_050, .{});
    h.table.documentStarted(5, 1_300_000);
    h.table.cefEndAs(5, 900, 1_300_000, false);
    // CDP 실패(시각 1.49 s)가 1.5 s 에 온다 — CEF 기록은 IO 시각 1.1 s 까지만 왔다(물 높이가 실패 시각 앞): 판정은 기다린다.
    try h.ev(5, .{ .failed = .{ .rid = "a", .ts_us = 1_490_000 } }, 1_500_000);
    try h.table.tickAt(gpa_t, 1_560_000, 1_100_000); // 끊김의 때(취소 + 250 ms)는 지났다
    try h.drain();
    try testing.expect(h.ended.get(900) == null);
    try h.table.tickAt(gpa_t, 1_600_000, 1_600_000);
    try h.drain();
    try testing.expect(stateIs(&h, 900, .request_failed));
    try testing.expectEqual(@as(u32, 1), endCount(&h, 900));
}

test "W9d② 최종 재검증 D-A: 끊긴 앞 문서 기록에 그것을 짝으로 쥔 CDP 요청이 없으면(다른 프로세스 iframe — CDP 에 없다) 놓을 것 없이 곧 unavailable 하나, 표는 한가해진다" {
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    _ = try h.cand(5, 920, "http://localhost/v20f/da/oopif", 1_000_000, .{});
    h.table.documentStarted(5, 1_300_000);
    h.table.cefEndAs(5, 920, 1_300_000, false);
    var now: i64 = 1_300_000;
    while (now <= 1_600_000) : (now += 50_000) {
        try h.table.tickAt(gpa_t, now, now);
        try h.drain();
    }
    try testing.expect(stateIs(&h, 920, .unavailable));
    try testing.expectEqual(@as(u32, 1), endCount(&h, 920));
    try testing.expect(!h.table.busy());
}

test "W9d② 재검증 2–9 회차 WB(전에는 D-A 대조): 새 문서 알림 없이 짝 없는 시한으로 끝나는 기록(CDP 가 보지 못한 워커의 같은 주소)의 주인일 수 있는 열린 긴 요청도 함께 뺀다 — 긴 요청은 본문을 잃고(틀리지 않는다) 제 기록은 짝 없는 시한으로" {
    const u = "http://127.0.0.1/v20f/da/long";
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    _ = try h.cand(5, 700, u, 1_000_000, .{}); // 워커의 기록 — CDP 에는 없다
    h.table.cefEnd(5, 700, 1_100_000);
    try h.sent(5, "x", u, 1_001_000, 1_001_100);
    _ = try h.cand(5, 701, u, 1_002_000, .{});
    var now: i64 = 1_100_000;
    while (now < 5_900_000) : (now += 50_000) {
        try h.table.tickAt(gpa_t, now, now);
        try h.drain();
    }
    try testing.expect(stateIs(&h, 700, .unmatched));
    // 700 이 x 의 기록이었으면(x 의 CDP 끝이 3 초 넘게 밀렸다) x 를 남겨 두면 701(다른 요청의 것일 수 있다)을 가져간다 — 가를 수 없으니 뺀다.
    try testing.expectEqual(@as(usize, 0), h.table.tabOf(5).?.cdp.items.len);
    try h.respond(5, "x", "application/json", 9, 5_900_000);
    h.table.cefEnd(5, 701, 5_950_000);
    try h.finish(5, "x", 6_000_000);
    now = 6_050_000;
    while (now < 9_000_000) : (now += 50_000) {
        try h.table.tickAt(gpa_t, now, now);
        try h.drain();
    }
    try testing.expectEqual(@as(usize, 0), h.fetches.items.len);
    try testing.expect(stateIs(&h, 701, .unmatched));
    try testing.expect(!h.table.busy());
}

test "W9d② 최종 재검증 D-B(v20f A R8-1): CDP 자리 상한의 묶음 놓기(256) — 살아 있던 X(101 째)가 놓이고 그 기록이 남아도, 제 기록을 후보 상한으로 잃은 같은 주소의 Y 는 X 의 기록에 본문을 붙이지 않는다(ambiguous) · 놓인 요청의 창 뒤에 시작한 같은 주소 Z 는 제 본문(대조)" {
    const k = "http://127.0.0.1/v20f/r8/k";
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    var rb: [24]u8 = undefined;
    var ub: [64]u8 = undefined;
    const t0: i64 = 1_000_000;
    _ = try h.cand(5, 1, k, t0, .{}); // Y 의 CEF 시작(가장 먼저)
    var t: i64 = t0 + 300;
    for (0..max_cdp - 1) |i| {
        if (i == 100) {
            // X 의 CDP — 자리 101 째(하나씩 놓던 때는 놓이지 않았다).
            try h.table.cdpEvent(gpa_t, 5, .{ .will_be_sent = .{ .rid = "x", .url_hash = hashUrl8(k), .method_hash = hashMethod("GET"), .ts_us = t } }, t);
            t += 300;
        }
        const rid = try std.fmt.bufPrint(&rb, "f.{d}", .{i});
        const url = try std.fmt.bufPrint(&ub, "http://127.0.0.1/v20f/fill/{d}", .{i});
        try h.table.cdpEvent(gpa_t, 5, .{ .will_be_sent = .{ .rid = rid, .url_hash = hashUrl8(url), .method_hash = hashMethod("GET"), .ts_us = t } }, t);
        _ = try h.cand(5, 1000 + i, url, t + 10, .{});
        t += 300;
    }
    _ = try h.cand(5, 2, k, t, .{}); // X 의 CEF 시작 — 후보 상한(4096)을 넘겨 가장 오래된 짝 없는 후보(Y 의 것)가 busy
    try h.drain();
    errdefer std.debug.print("D-B: Y(1) {?} X(2) {?} fetches {d} x kept {}\n", .{ h.ended.get(1), h.ended.get(2), h.fetches.items.len, cdpIndexOf(&h, "x") != null });
    try testing.expect(stateIs(&h, 1, .busy));
    try testing.expect(cdpIndexOf(&h, "x") != null);
    // Y 의 CDP — 자리 4097 째: 묶음 놓기가 가장 오래된 256 개(채움 100·X·채움 155)를 놓는다.
    try h.ev(5, .{ .will_be_sent = .{ .rid = "y", .url_hash = hashUrl8(k), .method_hash = hashMethod("GET"), .ts_us = t + 100 } }, t + 100);
    try testing.expect(cdpIndexOf(&h, "x") == null);
    try h.respond(5, "y", "application/json", 9, t + 5_000);
    try h.finish(5, "y", t + 6_000);
    try h.table.tickAt(gpa_t, t + 7_000, t + 7_000);
    try h.drain();
    try testing.expectEqual(@as(usize, 0), h.fetches.items.len); // Y 의 본문을 X(2)의 기록에 붙이지 않는다
    try testing.expect(stateIs(&h, 2, .ambiguous));
    // 경계: 창이 꼭 놓인 같은 주소 요청(X)의 창 끝에서 시작하는 같은 주소 요청은 본문을 붙이지 않는다(그 끝의 기록을 볼 수 있다).
    // 재검증 2–9 회차 N3: 표지는 주소마다다 — 같은 때의 다른 주소 요청은 제 본문(전에는 탭 전체라 그것도 ambiguous 였다).
    const tab5 = h.table.tabOf(5).?;
    try testing.expectEqual(@as(i64, 0), tab5.cdp_drop_until); // 묶음 하나(256)는 주소마다의 표지에 다 든다
    const until = for (tab5.cdp_drop_marks.items) |m| {
        if (m.url == hashUrl8(k)) break m.t_us;
    } else return error.TestUnexpectedResult;
    const tw = until + window_before_us;
    try h.sent(5, "w", k, tw, tw);
    _ = try h.cand(5, 4, k, tw + 50, .{});
    try h.respond(5, "w", "application/json", 9, tw + 1_000);
    h.table.cefEnd(5, 4, tw + 1_500);
    try h.finish(5, "w", tw + 2_000);
    try h.drain();
    try testing.expect(stateIs(&h, 4, .ambiguous));
    try h.sent(5, "e", "http://127.0.0.1/v20f/r8/edge", tw, tw);
    _ = try h.cand(5, 5, "http://127.0.0.1/v20f/r8/edge", tw + 50, .{});
    try h.respond(5, "e", "application/json", 9, tw + 1_000);
    h.table.cefEnd(5, 5, tw + 1_500);
    try h.finish(5, "e", tw + 2_000);
    try h.table.tickAt(gpa_t, tw + 2_500, tw + 2_500);
    try h.drain();
    try testing.expectEqual(@as(?u64, 5), fetchedFor(&h, "e"));
    // 대조: 놓인 요청의 창 끝(가장 늦은 기준 + 2 s) 뒤에 시작한 같은 주소 Z — 제 기록에 제 본문.
    const tz = until + window_before_us + 1;
    try h.sent(5, "z", k, tz, tz);
    _ = try h.cand(5, 3, k, tz + 50, .{});
    try h.respond(5, "z", "application/json", 9, tz + 1_000);
    h.table.cefEnd(5, 3, tz + 1_500);
    try h.finish(5, "z", tz + 2_000);
    try h.table.tickAt(gpa_t, tz + 3_000, tz + 3_000);
    try h.drain();
    var buf: [4]u64 = undefined;
    try testing.expectEqualSlices(u64, &.{ 5, 3 }, h.fetchedRequests(&buf));
}

fn cdpIndexOf(h: *H, rid: []const u8) ?usize {
    const tab = h.table.tabOf(5).?;
    for (tab.cdp.items, 0..) |o, i| if (o.rid.eql(rid)) return i;
    return null;
}

test "W9d② 최종 재검증(v20f A R9-2): 끊긴 CDP 자리 놓기와 같은 주소의 늦은 시작 — 놓인 뒤 늦게 끝난 옛 CDP 요청이 새 요청의 후보를 가져가지 않고, 끝은 꼭 하나" {
    const u = "http://127.0.0.1/v20f/r9/orph";
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    // 옛 요청 A: 후보가 넘김(문)으로 없다 — 열린 채 끝이 오지 않는다.
    try h.sent(5, "a", u, 1_000_000, 1_000_100);
    var now: i64 = 1_000_100;
    while (now < 3_200_000) : (now += 50_000) {
        try h.table.tickAt(gpa_t, now, now);
        try h.drain();
    }
    try testing.expect(cdpIndexOf(&h, "a") == null); // 놓였다
    // 새 요청 B(같은 주소, A 의 창 밖): 제 후보와 끝.
    try h.sent(5, "b", u, 3_250_000, 3_250_100);
    _ = try h.cand(5, 77, u, 3_250_050, .{});
    // 늦게 온 A 의 응답·끝 — 자리가 없어 아무 일도 없어야 한다(B 의 후보를 가져가지 않는다).
    try h.respond(5, "a", "application/json", 5, 3_260_000);
    try h.finish(5, "a", 3_261_000);
    try testing.expectEqual(@as(usize, 0), h.fetches.items.len);
    try h.respond(5, "b", "application/json", 9, 3_300_000);
    h.table.cefEnd(5, 77, 3_301_000);
    try h.finish(5, "b", 3_302_000);
    now = 3_302_000;
    while (now < 8_000_000) : (now += 50_000) {
        try h.table.tickAt(gpa_t, now, now);
        try h.drain();
    }
    var buf: [4]u64 = undefined;
    try testing.expectEqualSlices(u64, &.{77}, h.fetchedRequests(&buf));
    try testing.expect(endCount(&h, 77) <= 1);
}

test "W9d② 최종 재검증(v20f A R4-1): 물 높이가 다른 탭의 IO 밀림으로 멈춘 동안 열린 CDP 요청은 놓이지 않는다 — 멈춘 높이가 창 끝 바로 앞(ts + 2 s − 1 µs)이면 놓지 않고, 꼭 끝이면(= ts + 2 s) 아직, 넘으면 놓는다" {
    const u = "http://127.0.0.1/v20f/r4/wm";
    inline for (.{ .{ 2_999_999, true }, .{ 3_000_000, true }, .{ 3_000_001, false } }) |c| {
        var h: H = .{};
        defer h.deinit();
        _ = try h.table.start(gpa_t, 5, 1);
        try h.sent(5, "q", u, 1_000_000, 1_000_100);
        h.table.cef_seen_us = 0;
        try h.table.tickAt(gpa_t, 9_000_000, c[0]);
        try h.drain();
        errdefer std.debug.print("R4-1 seen={d}: kept {}\n", .{ c[0], cdpIndexOf(&h, "q") != null });
        try testing.expectEqual(c[1], cdpIndexOf(&h, "q") != null);
    }
}

/// 최종 재검증 N-a 전의 판정(열린 요청마다 후보를 모두 훑었다) — 색인 판정(`cdpMayPair`)과 견준다.
fn naiveMayPair(t: *const Tab, o: *const Cdp) bool {
    const ts = o.anchor();
    for (t.cands.items) |c| {
        if (c.claimed or c.key.url != o.key_url or c.key.method != o.key_method) continue;
        if (o.responded and c.key.sw != o.sw) continue;
        if (c.prev_t_io_us != 0) return true;
        if (c.t_io_us >= ts - window_before_us and c.t_io_us <= ts + window_after_us) return true;
    }
    return false;
}

test "W9d② 최종 재검증 N-a: 끊긴 CDP 자리 훑기의 색인은 모든 후보를 훑던 판정과 같다 — 열쇠·서비스 워커 갈래(응답 전·뒤)·창의 두 끝(±1 µs)·다시 시작한 시도·짝 지은 후보, 무작위 3000 번" {
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    const t = h.table.tabOf(5).?;
    var prng = std.Random.DefaultPrng.init(0x20f);
    const rnd = prng.random();
    const base: i64 = 10_000_000;
    const edges = [_]i64{ -window_before_us - 1, -window_before_us, 0, window_after_us, window_after_us + 1, -3_000_000, 3_000_000 };
    var hits: usize = 0;
    for (0..3000) |_| {
        t.cands.clearRetainingCapacity();
        const n = rnd.uintLessThan(usize, 12);
        for (0..n) |k| {
            const off = if (rnd.boolean()) edges[rnd.uintLessThan(usize, edges.len)] else rnd.intRangeAtMost(i64, -3_000_000, 3_000_000);
            try t.cands.append(gpa_t, .{ .request = k, .key = .{ .url = rnd.uintLessThan(u64, 3), .method = rnd.uintLessThan(u64, 2), .sw = rnd.boolean() }, .t_io_us = base + off, .attr = 1, .claimed = rnd.uintLessThan(u8, 5) == 0, .prev_t_io_us = if (rnd.uintLessThan(u8, 12) == 0) base - 1 else 0 });
        }
        try h.table.buildCandIndex(gpa_t, t);
        for (0..8) |_| {
            var o: Cdp = .{ .rid = Rid.init("q").?, .key_url = rnd.uintLessThan(u64, 3), .key_method = rnd.uintLessThan(u64, 2), .ts_us = base, .responded = rnd.boolean(), .sw = rnd.boolean() };
            if (rnd.uintLessThan(u8, 6) == 0) o.restart_ts_us = base + 100;
            const want = naiveMayPair(t, &o);
            errdefer std.debug.print("N-a: cands {any} o url={d} m={d} sw={} responded={} want {}\n", .{ t.cands.items.len, o.key_url, o.key_method, o.sw, o.responded, want });
            try testing.expectEqual(want, h.table.cdpMayPair(&o));
            if (want) hits += 1;
        }
    }
    try testing.expect(hits > 3000 and hits < 21000); // 두 쪽 모두 충분히 나왔다
}

/// 새 문서 맨 앞의 abort·다시(둘 다 문서 시작 알림보다 앞의 IO 시각 — 경주)에서 abort 의 CDP 실패가 늦게 온다(렌더러가 바빠 알림을 늦게 낸다).
fn v20fEarlyAbort(h: *H, doc: bool) !void {
    const u = "http://127.0.0.1/v20f/r5/early";
    _ = try h.table.start(gpa_t, 5, 1);
    try h.sent(5, "a", u, 1_289_900, 1_289_950);
    _ = try h.cand(5, 800, u, 1_290_000, .{});
    try h.sent(5, "b", u, 1_290_100, 1_290_150);
    _ = try h.cand(5, 801, u, 1_290_200, .{});
    if (doc) h.table.documentStarted(5, 1_300_000);
    h.table.cefEndAs(5, 800, 1_291_000, false); // abort — CEF 는 곧 취소로
    var now: i64 = 1_300_000;
    while (now < 1_650_000) : (now += 50_000) {
        try h.table.tickAt(gpa_t, now, now);
        try h.drain();
    }
    // CDP 실패가 350 ms 늦게 온다(시각은 abort 때 — 다시 받은 요청의 CEF 시작보다 0.3 ms 뒤, 실측 꼴).
    try h.ev(5, .{ .failed = .{ .rid = "a", .ts_us = 1_290_500 } }, 1_650_000);
    // 다시 받은 요청은 느리다(서버 700 ms).
    while (now < 1_990_000) : (now += 50_000) {
        try h.table.tickAt(gpa_t, now, now);
        try h.drain();
    }
    try h.respond(5, "b", "application/json", 9, 1_990_000);
    h.table.cefEnd(5, 801, 1_991_000);
    try h.finish(5, "b", 1_992_000);
    now = 2_000_000;
    while (now < 5_500_000) : (now += 50_000) {
        try h.table.tickAt(gpa_t, now, now);
        try h.drain();
    }
}

test "W9d② 최종 재검증 R5-1(v20f A): 새 문서 맨 앞의 abort·다시가 새 문서 알림과 경주하고 abort 의 CDP 실패가 끊김 시한(250 ms) 뒤에 오면 — 다시 받은 요청은 제 본문, abort 의 기록은 request_failed 하나(재검증 2–9 회차 WB 뒤 — 전에는 unavailable)" {
    var h: H = .{};
    defer h.deinit();
    try v20fEarlyAbort(&h, true);
    var buf: [4]u64 = undefined;
    const got = h.fetchedRequests(&buf);
    errdefer std.debug.print("R5-1 (N1 on): fetched {any} · 800 {?} · 801 {?}\n", .{ got, h.ended.get(800), h.ended.get(801) });
    try testing.expectEqual(@as(u32, 1), endCount(&h, 800));
    // 재검증 2–9 회차 WB: 끊긴 800 의 주인일 수 있는 열린 요청이 둘(a·b)이라 짝 없는 시한까지 지우지 않고 둔다 — b 가 성공으로 끝나 주인에서
    // 빠지고, 늦은 a 의 CDP 실패가 그 기록을 제 것으로 정한다(전에는 끊김이 a 를 놓아 unavailable — 이제 실제 끝 request_failed).
    try testing.expect(stateIs(&h, 800, .request_failed));
    try testing.expectEqualSlices(u64, &.{801}, got);
}

test "W9d② 최종 재검증 R5-1 대조(v20f A): 새 문서 시작 알림이 없으면 같은 꼴에서 abort 는 request_failed, 다시 받은 요청은 제 본문" {
    var h: H = .{};
    defer h.deinit();
    try v20fEarlyAbort(&h, false);
    var buf: [4]u64 = undefined;
    const got = h.fetchedRequests(&buf);
    errdefer std.debug.print("R5-1 control: fetched {any} · 800 {?} · 801 {?}\n", .{ got, h.ended.get(800), h.ended.get(801) });
    try testing.expect(stateIs(&h, 800, .request_failed));
    try testing.expectEqualSlices(u64, &.{801}, got);
}

// ── W9d② 최종 재검증 — 검증자 v20f B(11–20 회차)의 시험을 회귀 시험으로 ─────────────────────────────────────────────────

test "W9d② v20f 15: V4 boundaries — received size ±1 marks, equal or unknown does not, ASCII text/plain from a UTF-16 BOM is marked by the size, a re-decoded body is not marked twice, base64 is never marked chromium_decoded, a marked body over 1 MiB is over_cap" {
    const Case = struct { json: []const u8, mime: []const u8, charset: Charset, raw: u64, mark: bool, redecoded: bool = false, state: State = .captured };
    const cases = [_]Case{
        .{ .json = "{\"body\":\"{\\\"k\\\":1}\",\"base64Encoded\":false}", .mime = "application/json", .charset = .none, .raw = 7, .mark = false },
        .{ .json = "{\"body\":\"{\\\"k\\\":1}\",\"base64Encoded\":false}", .mime = "application/json", .charset = .none, .raw = 8, .mark = true },
        .{ .json = "{\"body\":\"{\\\"k\\\":1}\",\"base64Encoded\":false}", .mime = "application/json", .charset = .none, .raw = 6, .mark = true },
        .{ .json = "{\"body\":\"{\\\"k\\\":1}\",\"base64Encoded\":false}", .mime = "application/json", .charset = .none, .raw = 0, .mark = false },
        .{ .json = "{\"body\":\"AB\",\"base64Encoded\":false}", .mime = "text/plain", .charset = .none, .raw = 6, .mark = true },
        .{ .json = "{\"body\":\"AB\",\"base64Encoded\":false}", .mime = "text/plain", .charset = .none, .raw = 2, .mark = false },
        // "한" read as windows-1252 (í•œ), 3 received bytes — re-decoded, not also marked
        .{ .json = "{\"body\":\"\\u00ed\\u2022\\u0153\",\"base64Encoded\":false}", .mime = "text/plain", .charset = .none, .raw = 3, .mark = false, .redecoded = true },
        .{ .json = "{\"body\":\"7ZWc\",\"base64Encoded\":true}", .mime = "application/json", .charset = .none, .raw = 99, .mark = false },
    };
    for (cases, 0..) |c, i| {
        const d = try decodeResult(gpa_t, true, c.json, c.mime, c.charset, c.raw, .other);
        defer gpa_t.free(d.bytes);
        errdefer std.debug.print("v20f 15 case {d}: state={s} chromium_decoded={} redecoded={}\n", .{ i, @tagName(d.state), d.flags.chromium_decoded, d.flags.redecoded });
        try testing.expectEqual(c.state, d.state);
        try testing.expectEqual(c.mark, d.flags.chromium_decoded);
        try testing.expectEqual(c.redecoded, d.flags.redecoded);
    }
    // a marked (size-mismatched) body whose UTF-8 is over 1 MiB is over_cap, with the text size
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(gpa_t);
    try big.appendSlice(gpa_t, "{\"body\":\"");
    for (0..(msg.max_net_body_bytes / 3 + 1)) |_| try big.appendSlice(gpa_t, "\\u227b");
    try big.appendSlice(gpa_t, "\",\"base64Encoded\":false}");
    const o = try decodeResult(gpa_t, true, big.items, "application/json", .none, 1000, .other);
    defer gpa_t.free(o.bytes);
    try testing.expectEqual(State.over_cap, o.state);
    try testing.expect(o.over_bytes > msg.max_net_body_bytes);
}

// ── W9d② 재검증 15 회차 D-G1 — charset 매개변수 풀기 ─────────────────────────────────────────────────────────────────────────

test "W9d② 재검증 15 회차 D-G1: charsetOf — 매개변수 이름은 꼭 charset, 값은 WHATWG 이름표(빈 값은 none·모르는 이름표는 unknown), 따옴표·\\ 풀기, 같은 이름은 첫 것, 겹친 Content-Type 은 Fetch 의 extract a MIME type" {
    const C = struct { ct: []const u8, want: Charset };
    const cases = [_]C{
        .{ .ct = "", .want = .none },
        .{ .ct = "text/plain", .want = .none },
        // 빈 값 — Chromium 은 없는 것으로 친다(실측 `application/json; charset=` 는 UTF-8)
        .{ .ct = "text/plain; charset=", .want = .none },
        .{ .ct = "text/plain; charset=\"\"", .want = .none },
        .{ .ct = "text/plain; charset=\"  \"", .want = .none },
        .{ .ct = "text/css; charset=", .want = .none },
        .{ .ct = "application/json; charset=", .want = .none },
        .{ .ct = "text/plain; charset", .want = .none },
        // 모르는 이름표
        .{ .ct = "text/plain; charset=x-bogus-maru", .want = .unknown },
        .{ .ct = "application/json; charset=x-bogus-maru", .want = .unknown },
        .{ .ct = "text/plain; charset=none", .want = .unknown },
        .{ .ct = "text/plain; charset=binary", .want = .unknown },
        .{ .ct = "text/plain; charset=utf-8x", .want = .unknown },
        .{ .ct = "text/plain; charset='utf-8'", .want = .unknown },
        .{ .ct = "text/plain; charset=\"utf-8\\\"\"", .want = .unknown },
        .{ .ct = "text/plain; charset=\"a,b\"", .want = .unknown },
        .{ .ct = "text/plain; charset=\"utf-8-utf-8-utf-8-utf-8-utf-8-utf-8-utf-8-utf-8-utf-8-utf-8-utf-8-utf-8-utf-8-\"", .want = .unknown },
        // 이름이 charset 이 아니다(부분 글이 아니라 이름 전체 — `x-charset`·`charset `)
        .{ .ct = "text/plain; x-charset=latin1", .want = .none },
        .{ .ct = "text/plain; x-charset=utf-8", .want = .none },
        .{ .ct = "text/plain; charset = utf-8", .want = .none },
        .{ .ct = "text/plain; foo=\"a;charset=latin1\"; charset=utf-8", .want = .utf8 },
        .{ .ct = "text/plain; foo=\"a;charset=latin1\"", .want = .none },
        .{ .ct = "text/plain; charset;charset=utf-8", .want = .utf8 },
        // 대소문자·공백·여러 매개변수·따옴표
        .{ .ct = "TEXT/PLAIN; CHARSET=UTF-8", .want = .utf8 },
        .{ .ct = "text/plain; Charset=EUC-KR", .want = .other },
        .{ .ct = "  text/plain ;  charset=utf-8  ", .want = .utf8 },
        .{ .ct = "text/plain; charset= utf-8", .want = .utf8 },
        .{ .ct = "text/plain; charset=\tutf-8\t", .want = .utf8 },
        .{ .ct = "text/plain;charset=utf-8", .want = .utf8 },
        .{ .ct = "text/plain; format=flowed; charset=utf-8; delsp=yes", .want = .utf8 },
        .{ .ct = "text/plain; charset=\"utf-8\"; foo=bar", .want = .utf8 },
        .{ .ct = "text/plain; charset=\"UTF-8\"", .want = .utf8 },
        .{ .ct = "text/plain; charset=\"ut\\f-8\"", .want = .utf8 },
        .{ .ct = "text/plain; charset=\"utf-8", .want = .utf8 },
        .{ .ct = "text/plain; charset=\"utf-8\"junk; x=1", .want = .utf8 },
        .{ .ct = "text/plain; charset=lat\x01in1; charset=utf-8", .want = .unknown }, // 재검증 3 차 D-H2: Chromium 은 첫 값(제어 글자)을 쓴다
        // 같은 이름은 첫 것(실측: `iso-8859-1; charset=utf-8` 은 Latin-1 로 풀렸다)
        .{ .ct = "text/plain; charset=iso-8859-1; charset=utf-8", .want = .other },
        .{ .ct = "text/plain; charset=utf-8; charset=iso-8859-1", .want = .utf8 },
        // UTF-8 의 다른 이름표, 그 밖의 알려진 이름표
        .{ .ct = "text/plain; charset=unicode-1-1-utf-8", .want = .utf8 },
        .{ .ct = "text/plain; charset=X-Unicode20UTF8", .want = .utf8 },
        .{ .ct = "text/plain; charset=iso-8859-1", .want = .other },
        .{ .ct = "text/plain; charset=latin1", .want = .other },
        .{ .ct = "text/plain; charset=us-ascii", .want = .other },
        .{ .ct = "text/plain; charset=ks_c_5601-1987", .want = .other },
        .{ .ct = "text/plain; charset=shift_jis", .want = .other },
        .{ .ct = "text/plain; charset=gb18030", .want = .other },
        .{ .ct = "application/json; charset=utf-16", .want = .other },
        .{ .ct = "application/json; charset=UTF-16LE", .want = .other },
        .{ .ct = "application/json; charset=utf-16be", .want = .other },
        .{ .ct = "text/plain; charset=iso-2022-kr", .want = .other },
        .{ .ct = "text/plain; charset=replacement", .want = .other },
        .{ .ct = "text/plain; charset=x-user-defined", .want = .other },
        // MIME 가 아닌 값은 버린다 — `/` 가 없으면(둘 다 버린다), `/` 가 있는데 Fetch 가 읽지 못하면 Chromium 과 갈려 unknown(재검증 3 차 D-H2)
        .{ .ct = "charset=utf-8", .want = .none },
        .{ .ct = "/plain; charset=utf-8", .want = .unknown },
        .{ .ct = "text/; charset=utf-8", .want = .unknown },
        .{ .ct = "te xt/plain; charset=utf-8", .want = .unknown },
        // 겹친 Content-Type(CDP 는 `\n` 으로 잇는다·한 헤더 안의 `,`): 마지막 MIME, 같은 본질이면 앞 charset 을 물려받고 다르면 버린다, `*/*`·틀린 값은 건너뛴다
        .{ .ct = "application/json; charset=utf-8\napplication/json", .want = .utf8 },
        .{ .ct = "text/plain; charset=x-bogus-maru\ntext/plain; charset=utf-8", .want = .utf8 },
        .{ .ct = "text/plain; charset=utf-8\ntext/plain; charset=x-bogus-maru", .want = .unknown },
        .{ .ct = "text/plain; charset=utf-8\ntext/html", .want = .none },
        .{ .ct = "text/plain; charset=utf-8, text/html", .want = .none },
        .{ .ct = "text/plain; charset=latin1, TEXT/Plain", .want = .other },
        .{ .ct = "text/plain; charset=utf-8\n*/*", .want = .utf8 },
        .{ .ct = "text/plain; charset=utf-8\nbogus", .want = .utf8 },
        .{ .ct = "text/plain; charset=latin1\ntext/plain\ntext/plain", .want = .other },
        .{ .ct = "text/plain; charset=utf-8\napplication/json\ntext/plain", .want = .none },
    };
    var bad: usize = 0;
    for (cases) |c| {
        const got = charsetOf(c.ct);
        if (got != c.want) {
            std.debug.print("charsetOf [{s}] = {s}, want {s}\n", .{ c.ct, @tagName(got), @tagName(c.want) });
            bad += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);
    // 이름표 표: 인코딩마다 하나씩 — 대소문자 없이, 앞뒤 ASCII 공백을 떼고. 표에 없는 비슷한 이름은 unknown.
    for ([_][]const u8{ "ibm866", "ISO-8859-2", "iso8859-3", "latin4", "cyrillic", "arabic", "greek", "hebrew", "logical", "l6", "iso885913", "iso-8859-14", "l9", "iso-8859-16", "koi8_r", "koi8-ru", "x-mac-roman", "tis-620", "cp1250", "x-cp1251", "ascii", "cp1253", "latin5", "cp1255", "windows-1256", "x-cp1257", "cp1258", "x-mac-ukrainian", "gbk", "big5-hkscs", "euc-jp", "csiso2022jp", "windows-31j", "windows-949", "hz-gb-2312", "unicodefffe", "ucs-2", " \tutf-16\x0c\n" }) |l| try testing.expectEqual(Charset.other, charsetOfLabel(l));
    for ([_][]const u8{ "utf-8", "UTF8", "unicode11utf8", "unicode20utf8", " utf-8\r\n" }) |l| try testing.expectEqual(Charset.utf8, charsetOfLabel(l));
    for ([_][]const u8{ "utf-7", "utf-32", "iso-8859-12", "latin", "windows-1259", "euckr", "utf_8", "utf-8;", "\"utf-8\"" }) |l| try testing.expectEqual(Charset.unknown, charsetOfLabel(l));
    try testing.expectEqual(Charset.none, charsetOfLabel(" \t"));
}

test "W9d② 재검증 15 회차 D-G1: decodeResult 의 갈래 — 빈·모르는 charset·charset 아닌 매개변수의 windows-1252 글은 되돌리고(JSON 도), UTF-16 BOM 글은 크기로 표시, 선언한 Latin-1·EUC-KR 과 맞는 UTF-8 은 표시하지 않는다" {
    // 실측 바이트(v20g B R15): 「café 가나 ✓ 😀」 21 바이트, windows-1252 로 푼 글 40 바이트; 「café naïve」 12 → 16; UTF-16LE BOM JSON 20 → 「{"k":"é"}」 10.
    const good = "caf\u{e9} \u{ac00}\u{b098} \u{2713} \u{1F600}";
    const moji = "{\"body\":\"caf\\u00c3\\u00a9 \\u00ea\\u00b0\\u20ac\\u00eb\\u201a\\u02dc \\u00e2\\u0153\\u201c \\u00f0\\u0178\\u02dc\\u20ac\",\"base64Encoded\":false}";
    const moji_latin = "{\"body\":\"caf\\u00c3\\u00a9 na\\u00c3\\u00afve\",\"base64Encoded\":false}";
    const ok_json = "{\"body\":\"" ++ good ++ "\",\"base64Encoded\":false}";
    const utf16_bom = "{\"body\":\"{\\\"k\\\":\\\"\\u00e9\\\"}\",\"base64Encoded\":false}";
    const u16_ascii = "{\"body\":\"{\\\"k\\\":1}\",\"base64Encoded\":false}";
    const euckr = "{\"body\":\"\\uac00\\ub098\",\"base64Encoded\":false}";
    const Out = enum { exact, redecoded, marked, as_is };
    const R = struct { ct: []const u8, json: []const u8, raw: u64, out: Out };
    const rows = [_]R{
        // D-G1: 페이지(fetch·XHR)는 받은 바이트를 UTF-8 로 읽었다 — 되돌려 받은 바이트로
        .{ .ct = "text/plain; charset=", .json = moji, .raw = 21, .out = .redecoded },
        .{ .ct = "text/plain; charset=\"\"", .json = moji, .raw = 21, .out = .redecoded },
        .{ .ct = "text/plain; charset=x-bogus-maru", .json = moji, .raw = 21, .out = .redecoded },
        .{ .ct = "text/plain; charset=x-bogus-maru", .json = moji_latin, .raw = 12, .out = .redecoded },
        .{ .ct = "text/plain; charset=none", .json = moji, .raw = 21, .out = .redecoded },
        .{ .ct = "text/plain; charset=binary", .json = moji, .raw = 21, .out = .redecoded },
        .{ .ct = "text/plain; charset=utf-8x", .json = moji, .raw = 21, .out = .redecoded },
        .{ .ct = "text/plain; x-charset=latin1", .json = moji, .raw = 21, .out = .redecoded },
        .{ .ct = "text/plain; x-charset=utf-8", .json = moji, .raw = 21, .out = .redecoded },
        .{ .ct = "text/plain; charset = utf-8", .json = moji, .raw = 21, .out = .redecoded },
        .{ .ct = "text/plain; charset='utf-8'", .json = moji, .raw = 21, .out = .redecoded },
        .{ .ct = "text/css; charset=", .json = moji, .raw = 21, .out = .redecoded },
        .{ .ct = "application/json; charset=x-bogus-maru", .json = moji, .raw = 21, .out = .redecoded },
        .{ .ct = "application/json; charset=x-bogus-maru", .json = moji_latin, .raw = 12, .out = .redecoded },
        .{ .ct = "text/html; charset=x-bogus-maru", .json = moji, .raw = 21, .out = .redecoded },
        // 받은 수를 모르면 되돌린 글이 UTF-8 인 것만 본다
        .{ .ct = "application/json; charset=x-bogus-maru", .json = moji, .raw = 0, .out = .redecoded },
        // 모르는 이름표인데 수가 꼭 같다 — windows-1252 로 읽은 글이 아니다: 재검증 3 차 D-H1 — 그러면 BOM 으로 읽은 글뿐이라 표시(전에는 그대로);
        // 수를 모르면 되돌릴 수 없어 표시
        .{ .ct = "application/javascript; charset=x-bogus-maru", .json = ok_json, .raw = 21, .out = .marked },
        .{ .ct = "application/javascript; charset=x-bogus-maru", .json = ok_json, .raw = 0, .out = .marked },
        // 수가 다른데 되돌린 바이트 수와도 다르다 — 표시
        .{ .ct = "text/plain; charset=x-bogus-maru", .json = moji, .raw = 22, .out = .marked },
        // UTF-16 BOM(fetch 는 UTF-8 로 읽어 다르다): 빈·모르는 이름표·겹친 헤더(같은 본질 — 앞의 utf-8 을 물려받는다) — 표시
        .{ .ct = "application/json; charset=", .json = utf16_bom, .raw = 20, .out = .marked },
        .{ .ct = "application/json; charset=x-bogus-maru", .json = utf16_bom, .raw = 20, .out = .marked },
        .{ .ct = "application/json; charset=x-bogus-maru", .json = u16_ascii, .raw = 16, .out = .marked },
        .{ .ct = "application/json; charset=utf-8\napplication/json", .json = utf16_bom, .raw = 20, .out = .marked },
        // 대조: 맞는 UTF-8(선언한 utf-8·빈 값의 JSON·겹친 헤더의 마지막 utf-8·UTF-8 의 다른 이름표) — 그대로, 표시 없음
        .{ .ct = "application/json; charset=utf-8", .json = ok_json, .raw = 21, .out = .exact },
        .{ .ct = "text/plain; charset=\"UTF-8\"; foo=bar", .json = ok_json, .raw = 21, .out = .exact },
        .{ .ct = "application/json; charset=", .json = ok_json, .raw = 21, .out = .exact },
        .{ .ct = "text/plain; charset=x-bogus-maru\ntext/plain; charset=utf-8", .json = ok_json, .raw = 21, .out = .exact },
        .{ .ct = "text/plain; charset=unicode-1-1-utf-8", .json = ok_json, .raw = 21, .out = .exact },
        .{ .ct = "text/plain; charset=utf-8; charset=iso-8859-1", .json = ok_json, .raw = 21, .out = .exact },
        .{ .ct = "application/json", .json = ok_json, .raw = 21, .out = .exact },
        // 대조: 선언한 다른 charset(XHR 이 그렇게 읽는다) — Chromium 이 푼 그대로, 표시 없음
        .{ .ct = "text/plain; charset=iso-8859-1", .json = moji, .raw = 21, .out = .as_is },
        .{ .ct = "text/plain; charset=iso-8859-1; charset=utf-8", .json = moji, .raw = 21, .out = .as_is },
        .{ .ct = "text/plain; charset=euc-kr", .json = euckr, .raw = 4, .out = .as_is },
        .{ .ct = "application/json; charset=utf-16", .json = u16_ascii, .raw = 14, .out = .as_is },
    };
    var bad: usize = 0;
    for (rows) |r| {
        const semi = std.mem.indexOfAny(u8, r.ct, ";\n") orelse r.ct.len;
        const d = try decodeResult(gpa_t, true, r.json, r.ct[0..semi], charsetOf(r.ct), r.raw, .other);
        defer gpa_t.free(d.bytes);
        const fine = d.state == .captured and switch (r.out) {
            .exact => !d.flags.redecoded and !d.flags.chromium_decoded and std.mem.eql(u8, d.bytes, good),
            .redecoded => d.flags.redecoded and !d.flags.chromium_decoded and (std.mem.eql(u8, d.bytes, good) or std.mem.eql(u8, d.bytes, "caf\u{e9} na\u{ef}ve")),
            .marked => d.flags.chromium_decoded and !d.flags.redecoded,
            .as_is => !d.flags.redecoded and !d.flags.chromium_decoded,
        };
        if (!fine) {
            std.debug.print("decode [{s}] raw {d}: {s} redecoded={} chromium_decoded={} len {d}, want {s}\n", .{ r.ct, r.raw, @tagName(d.state), d.flags.redecoded, d.flags.chromium_decoded, d.bytes.len, @tagName(r.out) });
            bad += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);
}

// ── W9d② 재검증 3 차 D-H1·D-H2 — 같은 길이의 다른 풀기·Chromium 과 갈리는 Content-Type(검증자 v20h B R15 의 실측 꼴) ──────────────────────

/// 받은 바이트를 Chromium 의 windows-1252 디코더처럼 푼 글(0x80..0x9F 는 `cp1252_high`, 그 밖은 Latin-1 코드점).
fn win1252Text(gpa: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (raw) |b| {
        const cp: u21 = if (b >= 0x80 and b < 0xA0) cp1252_high[b - 0x80] else b;
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch unreachable;
        try out.appendSlice(gpa, buf[0..n]);
    }
    return out.toOwnedSlice(gpa);
}

test "W9d② 재검증 3 차 D-H1·D-H2·D-I1·D-I2: 실측 꼴마다 — 모르는 이름표의 같은 길이 글·헤더 charset 없는 HTML·XML 무리의 ASCII 아닌 글은 표시, Chromium 과 갈리는 Content-Type 은 unknown 으로 되돌려 받은 바이트, 맞는 글은 그대로" {
    const u8_raw = "caf\u{e9} \u{ac00}\u{b098} \u{2713} \u{1F600}"; // 21 바이트
    const u8l_raw = "caf\u{e9} na\u{ef}ve"; // 12 바이트
    const u16eq_le = "\xff\xfe\x00\xac\x98\xb0"; // UTF-16LE BOM + 「가나」 — Chromium 은 「가나」 6 바이트로 푼다
    const gana = "\u{ac00}\u{b098}";
    const u16eq_json_text = "{\"k\":\"\u{ac00}\u{b098}\u{b2e4}\u{b77c}\u{b9c8}\u{bc14}\u{c0ac}\u{c544}\u{c790}\u{cc28}\"}"; // 38 바이트 = 받은 38 바이트
    const gb_html_text = "<!doctype html><meta charset=gb18030><title>g</title>\u{f1}\u{4e2d}\u{6587}"; // 61 = 받은 61
    const html8 = "<!doctype html><meta charset=utf-8><title>u</title>" ++ u8_raw;
    const html_metakr8 = "<!doctype html><meta charset=euc-kr><title>k</title>" ++ u8_raw;
    const dots: [1030]u8 = @splat('.');
    // Chromium 이 푼 방법: 받은 바이트 그대로의 UTF-8(`right`), windows-1252(`w1252`), 따로 준 글(`text`).
    const How = enum { right, w1252, text };
    const Out = enum { exact, redecoded, marked, as_is };
    const R = struct { name: []const u8, ct: []const u8, mime: []const u8, raw: []const u8, how: How = .right, text: []const u8 = "", out: Out };
    const rows = [_]R{
        // D-H1: 모르는 이름표의 같은 길이 — BOM 으로 읽은 글뿐(표시)
        .{ .name = "u16eq_bogus", .ct = "application/json; charset=x-bogus-maru", .mime = "application/json", .raw = u16eq_le, .how = .text, .text = gana, .out = .marked },
        .{ .name = "u16eq_txtbogus", .ct = "text/plain; charset=x-bogus-maru", .mime = "text/plain", .raw = u16eq_le, .how = .text, .text = gana, .out = .marked },
        .{ .name = "u16eq_json_bogus", .ct = "application/json; charset=x-bogus-maru", .mime = "application/json", .raw = "\xff\xfe" ++ "0123456789abcdefghijklmnopqrstuvwxyz", .how = .text, .text = u16eq_json_text, .out = .marked },
        // D-H1: charset 없는 HTML 의 UTF-8 아닌 <meta>(같은 길이) — 표시; 길이가 다르면 전처럼 크기로
        .{ .name = "gb_html", .ct = "text/html", .mime = "text/html", .raw = "<!doctype html><meta charset=gb18030><title>g</title>\x81\x30\x8a\x39\xd6\xd0\xce\xc4", .how = .text, .text = gb_html_text, .out = .marked },
        .{ .name = "gb_html_ne", .ct = "text/html", .mime = "text/html", .raw = "<!doctype html><meta charset=gb18030><title>g</title>\xd6\xd0\xce\xc4", .how = .text, .text = "<!doctype html><meta charset=gb18030><title>g</title>\u{4e2d}\u{6587}", .out = .marked },
        .{ .name = "http-equiv gb2312", .ct = "text/html", .mime = "text/html", .raw = "x", .how = .text, .text = "<html><head><META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=gb2312\">\u{4e2d}", .out = .marked },
        .{ .name = "meta single-quoted euc-kr", .ct = "text/html", .mime = "text/html", .raw = "x", .how = .text, .text = "<meta charset='euc-kr'>" ++ gana, .out = .marked },
        // 재검증 3 차 뒤 D-I1·D-I2: 헤더에 charset 이 없는 HTML·XML 무리의 ASCII 아닌 글은 선언과 상관없이 늘 표시 — Chromium 은 본문의 선언(1024
        // 바이트 밖의 <meta>·XML 선언)을 따르고 maru 는 받은 바이트를 보지 못한다(전의 앞 1024 바이트 <meta> 훑기는 밖의 선언을 놓치고 주석 안의
        // `charset=` 에 속았다 — N-i1). 맞게 풀린 UTF-8 도 표시한다(대가).
        .{ .name = "html_none_meta8", .ct = "text/html", .mime = "text/html", .raw = html8, .out = .marked },
        .{ .name = "meta utf-16", .ct = "text/html", .mime = "text/html", .raw = "<meta charset=utf-16>" ++ u8_raw, .out = .marked },
        .{ .name = "meta unknown label", .ct = "text/html", .mime = "text/html", .raw = "<meta charset=x-bogus>" ++ u8_raw, .out = .marked },
        .{ .name = "meta past 1024", .ct = "text/html", .mime = "text/html", .raw = "<p>" ++ dots ++ "<meta charset=euc-kr>" ++ u8_raw, .out = .marked },
        .{ .name = "meta word charset", .ct = "text/html", .mime = "text/html", .raw = "<meta name=description content=\"charset handling\">" ++ u8_raw, .out = .marked },
        .{ .name = "D-I1 meta after 1100 B title", .ct = "text/html", .mime = "text/html", .raw = "x", .how = .text, .text = "<!doctype html><html><head><title>" ++ dots ++ dots[0..70] ++ "</title><meta charset=\"euc-kr\"></head><body>\u{3b1}\u{3b2}</body></html>", .out = .marked },
        .{ .name = "D-I1 xml decl in html", .ct = "text/html", .mime = "text/html", .raw = "x", .how = .text, .text = "<?xml version=\"1.0\" encoding=\"euc-kr\"?><!DOCTYPE html><p>\u{3b1}\u{3b2}</p>", .out = .marked },
        .{ .name = "N-i1 comment meta", .ct = "text/html", .mime = "text/html", .raw = "<!-- <meta charset=\"iso-8859-1\"> --><meta charset=utf-8>" ++ u8_raw, .out = .marked },
        .{ .name = "D-I2 application/xml prolog", .ct = "application/xml", .mime = "application/xml", .raw = "x", .how = .text, .text = "<?xml version=\"1.0\" encoding=\"euc-kr\"?><r>\u{3b1}\u{3b2}\u{3b3}\u{3b4}</r>", .out = .marked },
        .{ .name = "D-I2 svg", .ct = "image/svg+xml", .mime = "image/svg+xml", .raw = "<svg><text>" ++ u8_raw ++ "</text></svg>", .out = .marked },
        .{ .name = "D-I2 xhtml", .ct = "application/xhtml+xml", .mime = "application/xhtml+xml", .raw = "<html>" ++ u8_raw ++ "</html>", .out = .marked },
        .{ .name = "D-I2 atom +xml", .ct = "application/atom+xml", .mime = "application/atom+xml", .raw = "<feed>" ++ u8_raw ++ "</feed>", .out = .marked },
        .{ .name = "N-i2 text/xml (no re-decoding)", .ct = "text/xml", .mime = "text/xml", .raw = "<r>" ++ u8_raw ++ "</r>", .out = .marked },
        .{ .name = "N-i2 text/xml Latin-1 range (no re-decoding)", .ct = "text/xml", .mime = "text/xml", .raw = "<r>caf\xc3\xa9</r>", .out = .marked },
        // 대조(HTML·XML): 헤더 charset 이 앞선다(선언은 보지 않는다)·ASCII 글은 어느 인코딩이든 같다
        .{ .name = "html_hdr8_metakr", .ct = "text/html; charset=utf-8", .mime = "text/html", .raw = html_metakr8, .out = .exact },
        .{ .name = "xml_hdr8", .ct = "application/xml; charset=utf-8", .mime = "application/xml", .raw = "<?xml version=\"1.0\" encoding=\"euc-kr\"?><r>" ++ u8_raw ++ "</r>", .out = .exact },
        .{ .name = "meta ascii body", .ct = "text/html", .mime = "text/html", .raw = "<meta charset=gb18030>plain", .out = .exact },
        .{ .name = "xml ascii body", .ct = "application/xml", .mime = "application/xml", .raw = "<r>plain</r>", .out = .exact },
        // D-H2: Chromium 이 갈리게 읽어 windows-1252 로 푼 꼴 9 개 — unknown 이라 되돌려 받은 바이트(전에는 앞 헤더의 EUC-KR 을 따라 깨진 글이 표시 없이)
        .{ .name = "ctl_first_kr", .ct = "text/plain; charset=lat\x01in1; charset=euc-kr", .mime = "text/plain", .raw = u8_raw, .how = .w1252, .out = .redecoded },
        .{ .name = "del_first_kr", .ct = "text/plain; charset=euc\x7fkr; charset=euc-kr", .mime = "text/plain", .raw = u8_raw, .how = .w1252, .out = .redecoded },
        .{ .name = "ctl_first_json", .ct = "application/json; charset=x\x01; charset=euc-kr", .mime = "application/json", .raw = u8_raw, .how = .w1252, .out = .redecoded },
        .{ .name = "ctl_first_l2", .ct = "text/plain; charset=lat\x01in1; charset=latin2", .mime = "text/plain", .raw = u8l_raw, .how = .w1252, .out = .redecoded },
        .{ .name = "at_kr", .ct = "text/plain; charset=euc-kr\ntext/plain@; charset=x-bogus-maru", .mime = "text/plain", .raw = u8_raw, .how = .w1252, .out = .redecoded },
        .{ .name = "paren_kr", .ct = "text/plain; charset=euc-kr\ntext/plain(x); charset=x-bogus-maru", .mime = "text/plain", .raw = u8_raw, .how = .w1252, .out = .redecoded },
        .{ .name = "brace_kr", .ct = "text/plain; charset=euc-kr\ntext/plai{n}; charset=x-bogus-maru", .mime = "text/plain", .raw = u8_raw, .how = .w1252, .out = .redecoded },
        .{ .name = "sp_type_kr", .ct = "text/plain; charset=euc-kr\ntext/plain x; charset=x-bogus-maru", .mime = "text/plain", .raw = u8_raw, .how = .w1252, .out = .redecoded },
        .{ .name = "paren_json_kr", .ct = "application/json; charset=euc-kr\napplication/json (v2); charset=x-bogus-maru", .mime = "application/json", .raw = u8_raw, .how = .w1252, .out = .redecoded },
        // 같은 꼴의 utf-8 판(전에는 크기로 표시) — 이제 되돌려 받은 바이트
        .{ .name = "ctl_first_u8", .ct = "text/plain; charset=lat\x01in1; charset=utf-8", .mime = "text/plain", .raw = u8_raw, .how = .w1252, .out = .redecoded },
        .{ .name = "paren_u8_bogus", .ct = "text/plain; charset=utf-8\ntext/plain(x); charset=x-bogus-maru", .mime = "text/plain", .raw = u8_raw, .how = .w1252, .out = .redecoded },
        // N-h4(결정): 갈리는 꼴인데 Chromium 이 맞게 푼 글 — 가를 수 없어 표시(닫힌 쪽 — 「다를 수 있다」)
        .{ .name = "paren_single_u8", .ct = "text/plain(x); charset=utf-8", .mime = "text/plain", .raw = u8_raw, .out = .marked },
        // 대조(맞는 글 — 그대로, 표시 없음): 실측 ctl 꼴과 따옴표 앞 공백(Chromium 처럼 푼다)·`*/*`·`/` 없는 값
        .{ .name = "ctl_u8", .ct = "application/json; charset=utf-8", .mime = "application/json", .raw = u8_raw, .out = .exact },
        .{ .name = "ctl_txt8", .ct = "text/plain; charset=utf-8", .mime = "text/plain", .raw = u8_raw, .out = .exact },
        .{ .name = "lab_u20", .ct = "text/plain; charset=X-UNICODE20UTF8", .mime = "text/plain", .raw = u8_raw, .out = .exact },
        .{ .name = "lab_u11b", .ct = "text/plain; charset=unicode11utf8", .mime = "text/plain", .raw = u8_raw, .out = .exact },
        .{ .name = "lab_trailsemi", .ct = "text/plain;charset=utf-8;", .mime = "text/plain", .raw = u8_raw, .out = .exact },
        .{ .name = "comma_bogus_then8", .ct = "text/plain; charset=x-bogus-maru, text/plain; charset=utf-8", .mime = "text/plain", .raw = u8_raw, .out = .exact },
        .{ .name = "dup_diff", .ct = "text/plain; charset=euc-kr\napplication/json", .mime = "application/json", .raw = u8_raw, .out = .exact },
        .{ .name = "comma_u8_html", .ct = "text/plain; charset=utf-8, text/html", .mime = "text/html", .raw = u8_raw, .out = .marked }, // 본질이 바뀌어 charset 을 버린다 — charset 없는 HTML
        .{ .name = "q_lead_u8", .ct = "text/plain; charset=\" utf-8\"", .mime = "text/plain", .raw = u8_raw, .out = .exact },
        .{ .name = "sp_q_u8", .ct = "text/plain; charset= \"utf-8\"", .mime = "text/plain", .raw = u8_raw, .out = .exact },
        .{ .name = "sp_q_u8json", .ct = "application/json; charset= \"utf-8\"", .mime = "application/json", .raw = u8_raw, .out = .exact },
        .{ .name = "star second", .ct = "text/plain; charset=utf-8\n*/*; charset=x-bogus-maru", .mime = "text/plain", .raw = u8_raw, .out = .exact },
        .{ .name = "no-slash second", .ct = "text/plain; charset=utf-8\nbogus", .mime = "text/plain", .raw = u8_raw, .out = .exact },
        .{ .name = "noct_ascii", .ct = "", .mime = "text/plain", .raw = "plain ascii body", .out = .exact },
        .{ .name = "ctl_bogus_ascii", .ct = "text/plain; charset=x-bogus-maru", .mime = "text/plain", .raw = "plain ascii body", .out = .exact },
        .{ .name = "paren ascii", .ct = "text/plain(x); charset=utf-8", .mime = "text/plain", .raw = "plain ascii body", .out = .exact },
        // 알고 둔 틈(charset 없음·UTF-8): 같은 길이의 BOM 글은 맞는 UTF-8 과 가를 수 없다 — 표시 없이 Chromium 의 글(문서에 적었다)
        .{ .name = "u16eq_cs (gap)", .ct = "application/json; charset=utf-8", .mime = "application/json", .raw = u16eq_le, .how = .text, .text = gana, .out = .as_is },
        .{ .name = "u16eq_none (gap)", .ct = "application/json", .mime = "application/json", .raw = u16eq_le, .how = .text, .text = gana, .out = .as_is },
        .{ .name = "dup_8_then_none_json (gap)", .ct = "application/json; charset=utf-8\napplication/json", .mime = "application/json", .raw = u16eq_le, .how = .text, .text = gana, .out = .as_is },
    };
    var bad: usize = 0;
    for (rows) |r| {
        const text = switch (r.how) {
            .right => try gpa_t.dupe(u8, r.raw),
            .w1252 => try win1252Text(gpa_t, r.raw),
            .text => try gpa_t.dupe(u8, r.text),
        };
        defer gpa_t.free(text);
        const json = try std.json.Stringify.valueAlloc(gpa_t, .{ .body = text, .base64Encoded = false }, .{});
        defer gpa_t.free(json);
        const raw_size: u64 = if (std.mem.eql(u8, r.raw, "x")) text.len else r.raw.len;
        const d = try decodeResult(gpa_t, true, json, r.mime, charsetOf(r.ct), raw_size, .other);
        defer gpa_t.free(d.bytes);
        const fine = d.state == .captured and switch (r.out) {
            .exact => !d.flags.redecoded and !d.flags.chromium_decoded and std.mem.eql(u8, d.bytes, r.raw),
            .redecoded => d.flags.redecoded and !d.flags.chromium_decoded and std.mem.eql(u8, d.bytes, r.raw),
            .marked => d.flags.chromium_decoded and !d.flags.redecoded,
            .as_is => !d.flags.redecoded and !d.flags.chromium_decoded,
        };
        if (!fine) {
            std.debug.print("D-H [{s}] charset {s}: {s} redecoded={} chromium_decoded={} len {d} (raw {d}), want {s}\n", .{ r.name, @tagName(charsetOf(r.ct)), @tagName(d.state), d.flags.redecoded, d.flags.chromium_decoded, d.bytes.len, raw_size, @tagName(r.out) });
            bad += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);
    // N-i2: 받은 수를 모를 때(0)도 `text/xml` 을 windows-1252 로 되돌리지 않는다 — Chromium 은 UTF-8 로 풀었다(「Ã©」 는 페이지가 받은 글이다;
    // 되돌리면 「é」 로 바꿨다). 받은 수를 알면 길이가 달라 어느 쪽이든 표시만 된다 — 이 꼴만 둘을 가른다.
    const xml_moji = "<r>\u{c3}\u{a9}</r>";
    const json_moji = try std.json.Stringify.valueAlloc(gpa_t, .{ .body = xml_moji, .base64Encoded = false }, .{});
    defer gpa_t.free(json_moji);
    const dm = try decodeResult(gpa_t, true, json_moji, "text/xml", charsetOf("text/xml"), 0, .other);
    defer gpa_t.free(dm.bytes);
    try testing.expect(dm.state == .captured and !dm.flags.redecoded and dm.flags.chromium_decoded);
    try testing.expectEqualStrings(xml_moji, dm.bytes);
}

test "W9d② 재검증 3 차 D-H2: charsetOf — `/` 가 든 값을 Fetch 가 읽지 못하거나 첫 charset 에 제어 글자면 unknown, `/` 없는 값·`*/*` 는 둘 다 버린다, `=` 뒤 공백의 따옴표 값은 Chromium 처럼 푼다" {
    const C = struct { ct: []const u8, want: Charset };
    for ([_]C{
        .{ .ct = "text/plain(x); charset=utf-8", .want = .unknown },
        .{ .ct = "text/plain; charset=euc-kr\ntext/plai{n}; charset=x-bogus-maru", .want = .unknown },
        .{ .ct = "text/plain; charset=euc-kr, text/plain x; charset=euc-kr", .want = .unknown },
        .{ .ct = "application/json (v2)", .want = .unknown },
        .{ .ct = "text/plain(x)\ntext/plain; charset=utf-8", .want = .unknown },
        .{ .ct = "text/plain; charset=\"lat\x01in1\"; charset=utf-8", .want = .unknown },
        .{ .ct = "text/plain; charset =utf-8", .want = .none }, // 이름 뒤 공백 — 둘 다 charset 이 아니다(실측 dg1-spaced)
        .{ .ct = "text/plain; charset=utf-8; x=\x01", .want = .utf8 },
        .{ .ct = "text/plain; charset=utf-8\n*/*; charset=x-bogus-maru", .want = .utf8 },
        .{ .ct = "text/plain; charset=utf-8\nbogus; charset=latin1", .want = .utf8 },
        .{ .ct = "text/plain; charset=utf-8, ", .want = .utf8 },
        .{ .ct = "text/plain; charset= \"euc-kr\"", .want = .other },
        .{ .ct = "text/plain; charset=\t\"utf-8\"", .want = .utf8 },
        .{ .ct = "text/plain; charset=  ", .want = .none },
    }) |c| {
        errdefer std.debug.print("charsetOf [{s}] = {s}, want {s}\n", .{ c.ct, @tagName(charsetOf(c.ct)), @tagName(c.want) });
        try testing.expectEqual(c.want, charsetOf(c.ct));
    }
}

// ── W9d② v20g A — adversarial re-verification of e9ba4f018 (rounds 2–9), kept as regression tests (the WB rule — `expireRecords`) ──
// Names start with `W9d② v20g A`. The fuzz is seeded (deterministic); rows inside the model's assumptions assert "no wrong body".

const GKind = enum { page, worker, cdp_only };
const GOut = enum { ok, abort, cut };
const GReq = struct {
    kind: GKind,
    url: u8,
    /// CDP ts (page / cdp_only).
    ts: i64 = 0,
    /// CEF IO time (0 = no CEF record).
    io: i64 = 0,
    cef_id: u64 = 0,
    out: GOut = .ok,
    /// CDP ts of the response (0 = none).
    resp: i64 = 0,
    /// CDP ts of loadingFinished / loadingFailed (0 = none — cut by navigation).
    fin: i64 = 0,
    /// IO time of the CEF end (0 = none).
    cef_end: i64 = 0,
    cef_ok: bool = true,
    /// Started after the last navigation before it (new-doc) — for stats.
    early_new_doc: bool = false,
};

const GCdpKind = enum { sent, resp, fin, fail };
const GCdp = struct { gen: i64, at: i64 = 0, kind: GCdpKind, idx: usize };
const GCef = struct { io: i64, begin: bool, idx: usize };

var g_debug_seed: u64 = 0;
/// Fuzz knobs: renderer stall per mille of CDP events, its max (µs), and the IO jitter mix (0 = 85/10/5 %, 1 = no > 300 ms, 2 = only ≤ 6 ms).
var g_stall_pm: u16 = 15;
var g_stall_max: i64 = 3_500_000;
var g_io_mix: u8 = 0;
var g_worker_pct: u8 = 14;
var g_abort_pct: u8 = 14;
var g_navs: bool = true;
/// abort may come before CEF saw the request (no record); a request whose record would start after the navigation has no record.
var g_abort_precef: bool = true;
var g_nav_drop_record: bool = true;

const GStats = struct {
    skipped: usize = 0,
    scenarios: usize = 0,
    page_records: usize = 0,
    own: usize = 0,
    wrong: usize = 0,
    states: [16]usize = @splat(0),
    cut_states: [16]usize = @splat(0),
    ok_lost: usize = 0,
    not_idle: usize = 0,
    missing_end: usize = 0,
    first_wrong: [256]u8 = undefined,
    first_wrong_len: usize = 0,
};

fn gUrl(buf: []u8, u: u8) []const u8 {
    return std.fmt.bufPrint(buf, "https://g.test/{d}", .{u}) catch unreachable;
}

fn gRid(buf: []u8, i: usize) []const u8 {
    return std.fmt.bufPrint(buf, "g{d}", .{i}) catch unreachable;
}

/// One random scenario under the model's assumptions (every CDP-visible request has its own CEF record unless `gap`; CEF-only records —
/// workers — exist; CEF records are delivered by a 10 ms box in IO order and the watermark follows the box; CDP events are FIFO from one
/// renderer with stalls). Checks: no wrong body, every begin ends exactly once, the table goes idle.
fn gScenario(seed: u64, gap: bool, doc_notices: bool, st: *GStats) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    var h: H = .{ .sync = false };
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    var reqs: std.ArrayList(GReq) = .empty;
    defer reqs.deinit(gpa_t);
    const t0: i64 = 10_000_000;
    // navigations
    var navs: [3]i64 = undefined;
    var nav_n: usize = r.uintLessThan(usize, 3);
    {
        var t = t0 + 300_000;
        for (0..nav_n) |k| {
            t += r.intRangeAtMost(i64, 200_000, 1_500_000);
            navs[k] = t;
        }
        if (nav_n == 0 and r.boolean()) {
            navs[0] = t0 + r.intRangeAtMost(i64, 400_000, 2_000_000);
            nav_n = 1;
        }
    }
    if (!g_navs) nav_n = 0;
    const n_req = r.intRangeAtMost(usize, 12, 50);
    var t = t0;
    var next_id: u64 = 1;
    var i: usize = 0;
    while (i < n_req) : (i += 1) {
        t += switch (r.uintLessThan(u8, 4)) {
            0 => 0,
            1 => r.intRangeAtMost(i64, 0, 3_000),
            else => r.intRangeAtMost(i64, 0, 150_000),
        };
        const url = r.uintLessThan(u8, 3);
        const kr = r.uintLessThan(u8, 100);
        const kind: GKind = if (kr < g_worker_pct) .worker else if (gap and kr < g_worker_pct + 6) .cdp_only else .page;
        var q: GReq = .{ .kind = kind, .url = url };
        if (kind == .worker) {
            q.io = t + r.intRangeAtMost(i64, 0, 5_000);
            q.cef_id = next_id;
            next_id += 1;
            q.cef_end = q.io + r.intRangeAtMost(i64, 5_000, 1_000_000);
            try reqs.append(gpa_t, q);
            continue;
        }
        q.ts = t;
        if (kind == .page) {
            const jr = r.uintLessThan(u8, 100);
            q.io = q.ts + (if (g_io_mix == 3) r.intRangeAtMost(i64, 50, 6_000) else if (jr < 85 or g_io_mix == 2) r.intRangeAtMost(i64, -2_000, 6_000) else if (jr < 95 or g_io_mix == 1) r.intRangeAtMost(i64, 6_000, 300_000) else r.intRangeAtMost(i64, 300_000, 1_900_000));
            q.cef_id = next_id;
            next_id += 1;
        }
        const base = if (q.io != 0) q.io else q.ts;
        const lr = r.uintLessThan(u8, 100);
        const lat = if (lr < 60) r.intRangeAtMost(i64, 3_000, 200_000) else if (lr < 90) r.intRangeAtMost(i64, 200_000, 2_500_000) else r.intRangeAtMost(i64, 2_500_000, 5_000_000);
        q.resp = base + lat;
        q.fin = q.resp + r.intRangeAtMost(i64, 0, 300_000);
        if (q.io != 0) q.cef_end = q.fin + r.intRangeAtMost(i64, -1_000, 2_000);
        if (q.cef_end != 0 and q.cef_end < q.resp) q.cef_end = q.resp;
        if (kind == .page and r.uintLessThan(u8, 100) < g_abort_pct) {
            // abort before the response
            const a = q.io + r.intRangeAtMost(i64, if (g_abort_precef) -3_000 else 0, 40_000);
            if (a < q.resp) {
                q.out = .abort;
                q.resp = 0;
                q.fin = @max(a, q.ts + 1);
                if (a < q.io) {
                    // never reached CEF
                    q.io = 0;
                    q.cef_id = 0;
                    q.cef_end = 0;
                } else {
                    q.cef_end = a + r.intRangeAtMost(i64, 0, 1_000);
                    q.cef_ok = false;
                }
                try reqs.append(gpa_t, q);
                if (r.uintLessThan(u8, 100) < 70) {
                    // refetch of the same URL right after the abort
                    var b: GReq = .{ .kind = .page, .url = url, .ts = q.fin + r.intRangeAtMost(i64, 0, 500) };
                    b.io = b.ts + r.intRangeAtMost(i64, if (g_io_mix == 3) 50 else -500, 2_000);
                    b.cef_id = next_id;
                    next_id += 1;
                    b.resp = b.io + r.intRangeAtMost(i64, 3_000, 900_000);
                    b.fin = b.resp + r.intRangeAtMost(i64, 0, 50_000);
                    b.cef_end = b.fin + r.intRangeAtMost(i64, 0, 2_000);
                    try reqs.append(gpa_t, b);
                }
                continue;
            }
        }
        try reqs.append(gpa_t, q);
    }
    // reload bursts: right after each navigation the new document fetches URLs again (D-A shape), some before the doc notice
    for (navs[0..nav_n]) |nv| {
        const burst = r.intRangeAtMost(usize, 1, 5);
        for (0..burst) |_| {
            var b: GReq = .{ .kind = .page, .url = r.uintLessThan(u8, 3), .ts = nv + r.intRangeAtMost(i64, 100, 4_000), .early_new_doc = true };
            b.io = b.ts + r.intRangeAtMost(i64, if (g_io_mix == 3) 50 else -500, 3_000);
            b.cef_id = next_id;
            next_id += 1;
            b.resp = b.io + r.intRangeAtMost(i64, 3_000, 5_000_000);
            b.fin = b.resp + r.intRangeAtMost(i64, 0, 100_000);
            b.cef_end = b.fin + r.intRangeAtMost(i64, 0, 2_000);
            try reqs.append(gpa_t, b);
        }
    }
    // one renderer: CEF IO order of its requests follows their CDP start order (FIFO — J2: 2250/2250 in start order)
    {
        var order: std.ArrayList(usize) = .empty;
        defer order.deinit(gpa_t);
        for (reqs.items, 0..) |q, k| if (q.kind == .page and q.io != 0) try order.append(gpa_t, k);
        const Ctx = struct {
            rq: []const GReq,
            fn lt(c: @This(), a: usize, b: usize) bool {
                return c.rq[a].ts < c.rq[b].ts or (c.rq[a].ts == c.rq[b].ts and a < b);
            }
        };
        std.mem.sort(usize, order.items, Ctx{ .rq = reqs.items }, Ctx.lt);
        var prev: i64 = 0;
        for (order.items) |k| {
            const q = &reqs.items[k];
            const io = @max(q.io, prev + 1);
            const d = io - q.io;
            q.io = io;
            if (d > 0) {
                if (q.resp != 0) q.resp += d;
                if (q.fin != 0) q.fin += d;
                if (q.cef_end != 0) q.cef_end += d;
            }
            prev = io;
        }
    }
    // model assumption: a page request's record lies in its window (IO ≤ CDP ts + 2 s) — skip scenarios the FIFO push broke
    for (reqs.items) |q| if (q.kind == .page and q.io != 0 and q.io - q.ts > window_after_us - 50_000) {
        st.skipped += 1;
        return;
    };
    if (g_debug_seed == seed) for (reqs.items, 0..) |q, k| std.debug.print("  g{d}: {s} url {d} out {s} ts {d} io {d} cef {d} resp {d} fin {d} cef_end {d} ok {}\n", .{ k, @tagName(q.kind), q.url, @tagName(q.out), q.ts, q.io, q.cef_id, q.resp, q.fin, q.cef_end, q.cef_ok });
    if (g_debug_seed == seed) for (navs[0..nav_n]) |nv| std.debug.print("  nav {d}\n", .{nv});
    // navigation cuts: a request alive across a navigation is cut there (CEF cancels, CDP sends no end)
    for (reqs.items) |*q| {
        const start = if (q.kind == .worker) q.io else q.ts;
        const end = if (q.kind == .worker) q.cef_end else q.fin;
        for (navs[0..nav_n]) |nv| if (start < nv and end > nv) {
            q.out = .cut;
            if (q.resp > nv) q.resp = 0;
            q.fin = 0;
            if (g_nav_drop_record and q.io != 0 and q.io >= nv) {
                q.io = 0;
                q.cef_id = 0;
            }
            if (q.io != 0) {
                q.cef_end = nv + r.intRangeAtMost(i64, 0, 3_000);
                q.cef_ok = false;
            } else q.cef_end = 0;
            break;
        };
    }
    // CEF box events in IO order
    var cef: std.ArrayList(GCef) = .empty;
    defer cef.deinit(gpa_t);
    for (reqs.items, 0..) |q, k| if (q.io != 0) {
        try cef.append(gpa_t, .{ .io = q.io, .begin = true, .idx = k });
        if (q.cef_end != 0) try cef.append(gpa_t, .{ .io = @max(q.cef_end, q.io + 1), .begin = false, .idx = k });
    };
    std.mem.sort(GCef, cef.items, {}, struct {
        fn lt(_: void, a: GCef, b: GCef) bool {
            return a.io < b.io or (a.io == b.io and a.begin and !b.begin);
        }
    }.lt);
    // CDP events FIFO with stalls
    var cdp: std.ArrayList(GCdp) = .empty;
    defer cdp.deinit(gpa_t);
    for (reqs.items, 0..) |q, k| if (q.kind != .worker) {
        try cdp.append(gpa_t, .{ .gen = q.ts, .kind = .sent, .idx = k });
        if (q.resp != 0) try cdp.append(gpa_t, .{ .gen = q.resp, .kind = .resp, .idx = k });
        if (q.fin != 0) try cdp.append(gpa_t, .{ .gen = q.fin, .kind = if (q.out == .abort) .fail else .fin, .idx = k });
    };
    std.mem.sort(GCdp, cdp.items, {}, struct {
        fn lt(_: void, a: GCdp, b: GCdp) bool {
            if (a.gen != b.gen) return a.gen < b.gen;
            if (a.kind != b.kind) return @backingInt(a.kind) < @backingInt(b.kind);
            return a.idx < b.idx;
        }
    }.lt);
    {
        var last: i64 = 0;
        for (cdp.items) |*e| {
            var at = e.gen + r.intRangeAtMost(i64, 100, 3_000);
            if (r.uintLessThan(u16, 1000) < g_stall_pm) at += r.intRangeAtMost(i64, @min(250_000, g_stall_max), g_stall_max); // renderer stall
            at = @max(at, last + 1);
            e.at = at;
            last = at;
        }
    }
    var docs: [3]i64 = undefined;
    for (navs[0..nav_n], 0..) |nv, k| docs[k] = nv + r.intRangeAtMost(i64, 200, 4_000);
    // rid → request
    var rid_buf: [16]u8 = undefined;
    var url_buf: [32]u8 = undefined;
    // run
    var now: i64 = t0 - 1;
    var next_flush: i64 = t0 + r.intRangeAtMost(i64, 0, 10_000);
    var next_tick: i64 = t0 + r.intRangeAtMost(i64, 0, 50_000);
    var cef_cur: usize = 0;
    var cdp_cur: usize = 0;
    var doc_cur: usize = 0;
    const Pending = struct { id: i32, due: i64 };
    var pend: std.ArrayList(Pending) = .empty;
    defer pend.deinit(gpa_t);
    var seen_fetch: usize = 0;
    var horizon: i64 = 0;
    for (cdp.items) |e| horizon = @max(horizon, e.at);
    for (cef.items) |e| horizon = @max(horizon, e.io);
    horizon += 15_000_000;
    while (now < horizon) {
        // next event time
        var nt = @min(next_flush, next_tick);
        if (cdp_cur < cdp.items.len) nt = @min(nt, cdp.items[cdp_cur].at);
        if (doc_cur < nav_n) nt = @min(nt, docs[doc_cur]);
        for (pend.items) |p| nt = @min(nt, p.due);
        now = nt;
        const wm = blk: {
            var w = now - 1;
            if (cef_cur < cef.items.len and cef.items[cef_cur].io <= now) w = @min(w, cef.items[cef_cur].io - 1);
            break :blk w;
        };
        if (g_debug_seed == seed) {
            if (doc_cur < nav_n and docs[doc_cur] == now) std.debug.print("  @{d} DOC\n", .{now}) else if (cdp_cur < cdp.items.len and cdp.items[cdp_cur].at == now) std.debug.print("  @{d} cdp {s} g{d} (url {d})\n", .{ now, @tagName(cdp.items[cdp_cur].kind), cdp.items[cdp_cur].idx, reqs.items[cdp.items[cdp_cur].idx].url }) else if (next_flush == now) {
                var k = cef_cur;
                while (k < cef.items.len and cef.items[k].io <= now) : (k += 1) std.debug.print("  @{d} cef {s} rec {d} (g{d} url {d}) io {d}\n", .{ now, if (cef.items[k].begin) "begin" else "end", reqs.items[cef.items[k].idx].cef_id, cef.items[k].idx, reqs.items[cef.items[k].idx].url, cef.items[k].io });
            }
        }
        if (doc_cur < nav_n and docs[doc_cur] == now) {
            if (doc_notices) h.table.documentStarted(5, now);
            doc_cur += 1;
        } else if (cdp_cur < cdp.items.len and cdp.items[cdp_cur].at == now) {
            const e = cdp.items[cdp_cur];
            cdp_cur += 1;
            const q = reqs.items[e.idx];
            const rid = gRid(&rid_buf, e.idx);
            switch (e.kind) {
                .sent => {
                    try h.ev(5, .{ .will_be_sent = .{ .rid = rid, .url_hash = hashUrl8(gUrl(&url_buf, q.url)), .method_hash = hashMethod("GET"), .ts_us = q.ts } }, now);
                    try h.ev(5, .{ .extra_info = .{ .rid = rid, .credentialed = false } }, now);
                },
                .resp => {
                    try h.ev(5, .{ .response = .{ .rid = rid, .mime = "application/json", .from_sw = false, .charset = .other, .ts_us = q.resp } }, now);
                    try h.ev(5, .{ .data = .{ .rid = rid, .bytes = 10 } }, now);
                },
                .fin => {
                    h.table.cef_seen_us = @max(h.table.cef_seen_us, wm);
                    try h.ev(5, .{ .finished = .{ .rid = rid } }, now);
                },
                .fail => {
                    h.table.cef_seen_us = @max(h.table.cef_seen_us, wm);
                    try h.ev(5, .{ .failed = .{ .rid = rid, .ts_us = q.fin } }, now);
                },
            }
        } else if (next_flush == now) {
            next_flush += 10_000;
            while (cef_cur < cef.items.len and cef.items[cef_cur].io <= now) : (cef_cur += 1) {
                const e = cef.items[cef_cur];
                const q = reqs.items[e.idx];
                if (e.begin) {
                    _ = try h.cand(5, q.cef_id, gUrl(&url_buf, q.url), q.io, .{});
                } else {
                    h.table.cefEndReceived(5, q.cef_id, now, q.cef_ok, if (q.cef_ok) 10 else 0);
                }
            }
            try h.flushed(now - 1, now);
        } else if (next_tick == now) {
            next_tick += 50_000;
            try h.table.tickAt(gpa_t, now, wm);
            try h.drain();
        } else {
            var k: usize = 0;
            while (k < pend.items.len) {
                if (pend.items[k].due != now) {
                    k += 1;
                    continue;
                }
                const p = pend.swapRemove(k);
                if (h.table.takeInflight(p.id)) |f| {
                    try h.noteEnd(f.request, .captured);
                    try h.table.bodyDone(gpa_t, f, now);
                    try h.drain();
                }
            }
        }
        // new fetches: check the rid's own record
        while (seen_fetch < h.fetches.items.len) : (seen_fetch += 1) {
            const a = h.fetches.items[seen_fetch].fetch;
            var req: u64 = 0;
            for (h.table.inflight.items) |f| if (f.id == a.id) {
                req = f.request;
            };
            const idx = std.fmt.parseInt(usize, a.rid.slice()[1..], 10) catch unreachable;
            const q = reqs.items[idx];
            if (q.cef_id == req) st.own += 1 else {
                st.wrong += 1;
                if (st.first_wrong_len == 0) {
                    const s = std.fmt.bufPrint(&st.first_wrong, "seed {d} gap {} doc {}: rid g{d} (kind {s} out {s} url {d} ts {d} io {d} cef {d}) fetched for record {d}", .{ seed, gap, doc_notices, idx, @tagName(q.kind), @tagName(q.out), q.url, q.ts, q.io, q.cef_id, req }) catch "";
                    st.first_wrong_len = s.len;
                }
            }
            if (g_debug_seed == seed) std.debug.print("  @{d} fetch rid g{d} for record {d}\n", .{ now, idx, req });
            try pend.append(gpa_t, .{ .id = a.id, .due = now + r.intRangeAtMost(i64, 1_000, 40_000) });
        }
    }
    st.scenarios += 1;
    if (h.table.busy()) st.not_idle += 1;
    for (reqs.items) |q| if (q.cef_id != 0) {
        const n = endCount(&h, q.cef_id);
        if (n != 1) st.missing_end += 1;
        if (q.kind == .page) {
            st.page_records += 1;
            if (h.ended.get(q.cef_id)) |s| {
                if (q.out == .cut) st.cut_states[@backingInt(s)] += 1 else st.states[@backingInt(s)] += 1;
                if (q.out == .ok and s != .captured) st.ok_lost += 1;
            }
        }
    };
}

fn gPrint(name: []const u8, st: *const GStats) void {
    std.debug.print("\n[v20g fuzz {s}] skipped (model) {d} · scenarios {d} · page records {d} · own fetches {d} · WRONG {d} · end!=1 {d} · not idle {d} · ok-request records without capture {d}\n", .{ name, st.skipped, st.scenarios, st.page_records, st.own, st.wrong, st.missing_end, st.not_idle, st.ok_lost });
    std.debug.print("  states (not cut):", .{});
    for (st.states, 0..) |c, k| if (c > 0) std.debug.print(" {s}={d}", .{ @tagName(@as(State, @fromBackingInt(@intCast(k)))), c });
    std.debug.print("\n  states (cut by navigation):", .{});
    for (st.cut_states, 0..) |c, k| if (c > 0) std.debug.print(" {s}={d}", .{ @tagName(@as(State, @fromBackingInt(@intCast(k)))), c });
    std.debug.print("\n", .{});
    if (st.first_wrong_len > 0) std.debug.print("  first wrong: {s}\n", .{st.first_wrong[0..st.first_wrong_len]});
}

test "W9d② v20g A fuzz: model-based ground truth inside the table's assumptions (CEF IO −2..+6 ms of the CDP start, no renderer stall) — navigations (cut requests, reload bursts before/after the doc notice), aborts (before/after CEF, late CDP failure), refetch, worker records, 10 ms box watermark — no wrong body, one end per begin, idle at the end" {
    defer {
        g_stall_pm = 15;
        g_io_mix = 0;
    }
    g_stall_pm = 0;
    g_io_mix = 2;
    var on: GStats = .{};
    var off: GStats = .{};
    for (0..400) |s| {
        try gScenario(0x20a0000 + s, false, true, &on);
        try gScenario(0x20a0000 + s, false, false, &off);
    }
    gPrint("doc notices ON (product)", &on);
    gPrint("doc notices OFF (control)", &off);
    try testing.expectEqual(@as(usize, 0), on.wrong);
    try testing.expectEqual(@as(usize, 0), on.missing_end);
    try testing.expectEqual(@as(usize, 0), on.not_idle);
}

test "W9d② v20g A fuzz gap: same model plus CDP requests that have no CEF record of their own (documented gap) — count wrong bodies (observation)" {
    var on: GStats = .{};
    for (0..400) |s| try gScenario(0x20b0000 + s, true, true, &on);
    gPrint("gap: CDP-only requests, doc notices ON", &on);
    try testing.expectEqual(@as(usize, 0), on.missing_end);
    try testing.expectEqual(@as(usize, 0), on.not_idle);
}

fn gTicks(h: *H, from: i64, to: i64) !i64 {
    var now = from;
    while (now <= to) : (now += 50_000) {
        try h.table.tickAt(gpa_t, now, now);
        try h.drain();
    }
    return now;
}

/// Complete every pending fetch at once (returns the fetched CEF requests in order).
fn gServe(h: *H, done: *usize, out: *std.ArrayList(u64), now: i64) !void {
    while (done.* < h.fetches.items.len) : (done.* += 1) {
        const f = h.table.takeInflight(h.fetches.items[done.*].fetch.id) orelse continue;
        try out.append(gpa_t, f.request);
        try h.noteEnd(f.request, .captured);
        try h.table.bodyDone(gpa_t, f, now);
        try h.drain();
    }
}

test "W9d② v20g A R9-a: reload chain A → B → C while every same-URL request waits for headers (4 per document, other-host shape) — C's four get their own bodies, A's and B's eight end unavailable once, table idle" {
    const u = "http://localhost/v20g/chain";
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    var rb: [16]u8 = undefined;
    var t: i64 = 1_000_000;
    // A then B (300 ms later) then C (300 ms later)
    for (0..3) |d| {
        if (d > 0) {
            h.table.documentStarted(5, t);
            for (0..4) |k| h.table.cefEndAs(5, 100 * (d - 1) + k, t, false);
            t += 100_000;
        }
        for (0..4) |k| {
            const ki: i64 = @intCast(k);
            try h.sent(5, try std.fmt.bufPrint(&rb, "d{d}.{d}", .{ d, k }), u, t + ki * 1_000, t + ki * 1_000 + 100);
            _ = try h.cand(5, 100 * d + k, u, t + ki * 1_000 + 50, .{});
        }
        _ = try gTicks(&h, t + 50_000, t + 250_000);
        t += 300_000;
    }
    // C answers 1.7 s after it started, in reverse order
    var k: usize = 4;
    const tc = t - 300_000;
    while (k > 0) {
        k -= 1;
        const ki: i64 = @intCast(k);
        const rid = try std.fmt.bufPrint(&rb, "d2.{d}", .{k});
        try h.respond(5, rid, "application/json", 9, tc + 1_700_000 + (3 - ki) * 1_000);
        h.table.cefEnd(5, 200 + k, tc + 1_700_500 + (3 - ki) * 1_000);
        try h.finish(5, rid, tc + 1_700_900 + (3 - ki) * 1_000);
    }
    var got: std.ArrayList(u64) = .empty;
    defer got.deinit(gpa_t);
    var done: usize = 0;
    var now = tc + 1_750_000;
    while (now < tc + 9_000_000) : (now += 50_000) {
        try h.table.tickAt(gpa_t, now, now);
        try h.drain();
        try gServe(&h, &done, &got, now);
    }
    std.mem.sort(u64, got.items, {}, std.sort.asc(u64));
    errdefer std.debug.print("R9-a: fetched {any}; A {?} {?} B {?} {?}\n", .{ got.items, h.ended.get(0), h.ended.get(3), h.ended.get(100), h.ended.get(103) });
    try testing.expectEqualSlices(u64, &.{ 200, 201, 202, 203 }, got.items);
    for ([_]u64{ 0, 1, 2, 3, 100, 101, 102, 103 }) |q| {
        try testing.expect(stateIs(&h, q, .unavailable));
        try testing.expectEqual(@as(u32, 1), endCount(&h, q));
    }
    try testing.expect(!h.table.busy());
}

test "W9d② v20g A R9-b: retireOwner when the owner already ended — CDP failure arrives exactly at the cut tick / partial bytes / failure after the owner was retired: one end each, never lost" {
    const u = "http://127.0.0.1/v20g/owner";
    // (1) failure with data arrives at cancel + 250 ms, watermark behind → owner waits → partial
    {
        var h: H = .{ .sync = false };
        defer h.deinit();
        _ = try h.table.start(gpa_t, 5, 1);
        try h.sent(5, "a", u, 1_000_000, 1_000_100);
        _ = try h.cand(5, 900, u, 1_000_050, .{});
        h.table.cef_seen_us = 1_000_100;
        try h.ev(5, .{ .response = .{ .rid = "a", .mime = "application/json", .from_sw = false, .charset = .other, .ts_us = 1_010_000 } }, 1_010_000);
        try h.ev(5, .{ .data = .{ .rid = "a", .bytes = 5 } }, 1_010_000);
        h.table.documentStarted(5, 1_300_000);
        h.table.cefEndAs(5, 900, 1_300_000, false);
        try h.ev(5, .{ .failed = .{ .rid = "a", .ts_us = 1_549_000 } }, 1_550_000); // watermark 1_000_100 < bound 1_010_000 → waits
        try h.table.tickAt(gpa_t, 1_550_000, 1_005_000);
        try h.drain();
        try testing.expect(h.ended.get(900) == null);
        _ = try gTicks(&h, 1_600_000, 2_500_000);
        errdefer std.debug.print("R9-b(1): 900 {?} ends {d}\n", .{ h.ended.get(900), endCount(&h, 900) });
        try testing.expect(stateIs(&h, 900, .partial));
        try testing.expectEqual(@as(u32, 1), endCount(&h, 900));
        try testing.expect(!h.table.busy());
    }
    // (2) the CDP failure arrives 50 ms after the owner was retired — ignored; the record ended unavailable once
    {
        var h: H = .{};
        defer h.deinit();
        _ = try h.table.start(gpa_t, 5, 1);
        try h.sent(5, "a", u, 1_000_000, 1_000_100);
        _ = try h.cand(5, 900, u, 1_000_050, .{});
        h.table.documentStarted(5, 1_300_000);
        h.table.cefEndAs(5, 900, 1_300_000, false);
        _ = try gTicks(&h, 1_300_000, 1_600_000);
        try testing.expect(stateIs(&h, 900, .unavailable));
        try h.ev(5, .{ .failed = .{ .rid = "a", .ts_us = 1_299_000 } }, 1_650_000);
        // a new same-URL request right after: own body
        try h.sent(5, "b", u, 1_700_000, 1_700_100);
        _ = try h.cand(5, 901, u, 1_700_050, .{});
        try h.respond(5, "b", "application/json", 9, 1_800_000);
        h.table.cefEnd(5, 901, 1_800_500);
        try h.finish(5, "b", 1_801_000);
        _ = try gTicks(&h, 1_850_000, 2_000_000);
        var buf: [4]u64 = undefined;
        try testing.expectEqualSlices(u64, &.{901}, h.fetchedRequests(&buf));
        try testing.expectEqual(@as(u32, 1), endCount(&h, 900));
    }
}

test "W9d② v20g A R9-c (documented gap, observation): an old-document CDP request that has no CEF record of its own (its CEF begin never came) and a reload of the same URL — the reloaded request loses its body (unmatched), never a wrong body" {
    const u = "http://127.0.0.1/v20g/norec";
    inline for (.{ 1_700_000, 2_400_000, 4_800_000 }) |fin| {
        var h: H = .{};
        defer h.deinit();
        _ = try h.table.start(gpa_t, 5, 1);
        try h.sent(5, "o", u, 1_000_000, 1_000_100); // no CEF record
        h.table.documentStarted(5, 1_300_000);
        try h.sent(5, "n", u, 1_350_000, 1_350_100);
        _ = try h.cand(5, 901, u, 1_350_050, .{});
        _ = try gTicks(&h, 1_350_100, fin - 10_000);
        try h.respond(5, "n", "application/json", 9, fin - 2_000);
        h.table.cefEnd(5, 901, fin - 1_000);
        try h.finish(5, "n", fin);
        _ = try gTicks(&h, fin, fin + 6_000_000);
        var buf: [4]u64 = undefined;
        const got = h.fetchedRequests(&buf);
        std.debug.print("\n[v20g R9-c fin={d}] fetched {any} · 901 {?} · cdp left {d} · busy {}\n", .{ fin, got, h.ended.get(901), h.table.tabOf(5).?.cdp.items.len, h.table.busy() });
        for (got) |g| try testing.expect(g == 901);
        try testing.expectEqual(@as(u32, 1), endCount(&h, 901));
        try testing.expect(!h.table.busy());
    }
}

test "W9d② v20g A R9-d (observation): a CDP-invisible old-doc record that sits ≤ 5 ms before a live long request's own record (new-doc early request with IO before the doc notice) — the live request may own the cut record, so it is released: its body is lost, never wrong (with and without the notice)" {
    const u = "http://127.0.0.1/v20g/misowner";
    inline for (.{ true, false }) |doc| {
        var h: H = .{};
        defer h.deinit();
        _ = try h.table.start(gpa_t, 5, 1);
        // P (CDP ts 1.000 s) — the page's early long fetch; W (IO 1.0010 s) — a CDP-invisible record of the same URL (prefetch / worker)
        try h.sent(5, "p", u, 1_000_000, 1_000_100);
        _ = try h.cand(5, 700, u, 1_001_000, .{}); // W
        _ = try h.cand(5, 701, u, 1_001_500, .{}); // P's own record
        if (doc) h.table.documentStarted(5, 1_003_000); // both IO times before the notice (old_doc)
        h.table.cefEnd(5, 700, 1_050_000); // W ends OK fast
        _ = try gTicks(&h, 1_050_000, 4_200_000); // W's unmatched expiry (3 s) passes while P is open
        try h.respond(5, "p", "application/json", 9, 4_300_000);
        h.table.cefEnd(5, 701, 4_301_000);
        try h.finish(5, "p", 4_302_000);
        _ = try gTicks(&h, 4_350_000, 8_000_000);
        var buf: [4]u64 = undefined;
        const got = h.fetchedRequests(&buf);
        std.debug.print("\n[v20g R9-d doc={}] fetched {any} · W(700) {?} · P(701) {?}\n", .{ doc, got, h.ended.get(700), h.ended.get(701) });
        for (got) |g| try testing.expect(g == 701); // never a wrong body
        try testing.expectEqual(@as(u32, 1), endCount(&h, 700));
        try testing.expectEqual(@as(u32, 1), endCount(&h, 701) + @as(u32, @intCast(got.len)));
    }
}

test "W9d② v20g A R5: abort racing the new-document notice — the abort's CDP failure arrives 100/249/250/251/400/3000 ms late, refetch finishes before or after it — the refetch never gets a wrong body, both end once" {
    const u = "http://127.0.0.1/v20g/r5";
    inline for (.{ 100_000, 249_000, 250_000, 251_000, 400_000, 3_000_000 }) |late| {
        inline for (.{ 200_000, 900_000, 3_500_000 }) |bfin| {
            var h: H = .{};
            defer h.deinit();
            _ = try h.table.start(gpa_t, 5, 1);
            try h.sent(5, "a", u, 1_289_900, 1_289_950);
            _ = try h.cand(5, 800, u, 1_290_000, .{});
            try h.sent(5, "b", u, 1_290_100, 1_290_150);
            _ = try h.cand(5, 801, u, 1_290_200, .{});
            h.table.documentStarted(5, 1_300_000);
            h.table.cefEndAs(5, 800, 1_291_000, false);
            var now: i64 = 1_300_000;
            var failed = false;
            var finished = false;
            var served: std.ArrayList(u64) = .empty;
            defer served.deinit(gpa_t);
            var done: usize = 0;
            while (now < 8_000_000) : (now += 10_000) {
                try gServe(&h, &done, &served, now);
                if (!failed and now >= 1_291_000 + late) {
                    try h.ev(5, .{ .failed = .{ .rid = "a", .ts_us = 1_290_500 } }, now);
                    failed = true;
                }
                if (!finished and now >= 1_290_200 + bfin) {
                    try h.respond(5, "b", "application/json", 9, now - 2_000);
                    h.table.cefEnd(5, 801, now - 1_000);
                    try h.finish(5, "b", now);
                    finished = true;
                }
                if (@mod(now, 50_000) == 0) {
                    try h.table.tickAt(gpa_t, now, now);
                    try h.drain();
                }
            }
            const got = served.items;
            std.debug.print("[v20g R5 late={d} bfin={d}] fetched {any} · A(800) {?} · B(801) {?}\n", .{ late, bfin, got, h.ended.get(800), h.ended.get(801) });
            for (got) |g| try testing.expect(g == 801);
            try testing.expectEqual(@as(u32, 1), endCount(&h, 800));
            try testing.expectEqual(@as(u32, 1), endCount(&h, 801));
            try testing.expect(!h.table.busy());
        }
    }
}

test "W9d② v20g A R8-a: cdp_drop_until — after a burst of 4096 hung requests, how many later legitimate requests (distinct URLs, 50 ms apart) are made ambiguous, and the window ends (count)" {
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    var rb: [24]u8 = undefined;
    var ub: [64]u8 = undefined;
    // 4096 hung requests in 0.4 s, each with its own record (never ends)
    for (0..max_cdp) |i| {
        const ii: i64 = @intCast(i);
        const ts: i64 = 1_000_000 + @divTrunc(ii * 400_000, max_cdp);
        const rid = try std.fmt.bufPrint(&rb, "h.{d}", .{i});
        const url = try std.fmt.bufPrint(&ub, "http://127.0.0.1/v20g/hung/{d}", .{i});
        try h.table.cdpEvent(gpa_t, 5, .{ .will_be_sent = .{ .rid = rid, .url_hash = hashUrl8(url), .method_hash = hashMethod("GET"), .ts_us = ts } }, ts);
        _ = try h.cand(5, 10_000 + i, url, ts + 50, .{});
    }
    try h.drain();
    var amb: usize = 0;
    var own: usize = 0;
    var first_ok: i64 = 0;
    var last_amb: i64 = 0;
    var now: i64 = 1_500_000;
    var n: usize = 0;
    while (now < 6_000_000) : (now += 50_000) {
        const rid = try std.fmt.bufPrint(&rb, "l.{d}", .{n});
        const url = try std.fmt.bufPrint(&ub, "http://127.0.0.1/v20g/legit/{d}", .{n});
        try h.sent(5, rid, url, now, now);
        _ = try h.cand(5, 50_000 + n, url, now + 100, .{});
        try h.respond(5, rid, "application/json", 9, now + 5_000);
        h.table.cefEnd(5, 50_000 + n, now + 6_000);
        try h.finish(5, rid, now + 7_000);
        try h.table.tickAt(gpa_t, now + 8_000, now + 8_000);
        try h.drain();
        if (stateIs(&h, 50_000 + n, .ambiguous)) {
            amb += 1;
            last_amb = now;
        } else {
            own += 1;
            if (first_ok == 0) first_ok = now;
        }
        n += 1;
    }
    std.debug.print("\n[v20g R8-a] legit {d}: ambiguous {d} (last at +{d} ms), not ambiguous {d} (first at +{d} ms) · drop_until +{d} ms · open cdp {d}\n", .{ n, amb, @divTrunc(last_amb - 1_000_000, 1000), own, @divTrunc(first_ok - 1_000_000, 1000), @divTrunc(h.table.tabOf(5).?.cdp_drop_until - 1_000_000, 1000), h.table.tabOf(5).?.cdp.items.len });
    // 재검증 2–9 회차 N3: 표지는 주소마다다 — 다른 주소의 요청은 ambiguous 가 아니다(전에는 31/90).
    try testing.expectEqual(@as(usize, 0), amb);
}

extern "c" fn clock_gettime_nsec_np(clock_id: c_int) u64;

test "W9d② v20g A R8-b: cost of the N1 cut — N old-document requests of ONE URL (all open, all cancelled by a navigation: ended at the unclaimed deadline because each cut record has many possible owners) and N of distinct URLs (cut at once) — every record ends once, no CDP request is left (times printed)" {
    inline for (.{ true, false }) |same| {
        for ([_]usize{ 512, 1024, 2048, 4095 }) |n| {
            var h: H = .{};
            defer h.deinit();
            _ = try h.table.start(gpa_t, 5, 1);
            var rb: [24]u8 = undefined;
            var ub: [64]u8 = undefined;
            for (0..n) |i| {
                const ii: i64 = @intCast(i);
                const ts: i64 = 1_000_000 + ii * 100;
                const rid = try std.fmt.bufPrint(&rb, "c.{d}", .{i});
                const url = if (same) "http://127.0.0.1/v20g/same" else try std.fmt.bufPrint(&ub, "http://127.0.0.1/v20g/d/{d}", .{i});
                try h.table.cdpEvent(gpa_t, 5, .{ .will_be_sent = .{ .rid = rid, .url_hash = hashUrl8(url), .method_hash = hashMethod("GET"), .ts_us = ts } }, ts);
                _ = try h.table.cefBegin(gpa_t, 5, .{ .request = 10_000 + i, .key = .{ .url = hashUrl8(url), .method = hashMethod("GET"), .sw = false }, .t_io_us = ts + 50, .attr = 1 });
            }
            const nav: i64 = 1_000_000 + @as(i64, @intCast(n)) * 100 + 1_000;
            h.table.documentStarted(5, nav);
            for (0..n) |i| h.table.cefEndAs(5, 10_000 + i, nav, false);
            // 재검증 2–9 회차 WB: 같은 주소면 끊긴 기록마다 주인일 수 있는 열린 요청이 여럿이라 짝 없는 시한(3 s)에 끝낸다 — 두 주기를 잰다.
            const a = clock_gettime_nsec_np(4);
            try h.table.tickAt(gpa_t, nav + cef_grace_us, nav + cef_grace_us);
            const b = clock_gettime_nsec_np(4);
            try h.drain();
            const at_cut = h.ends;
            const c = clock_gettime_nsec_np(4);
            try h.table.tickAt(gpa_t, nav + unclaimed_expiry_us, nav + unclaimed_expiry_us);
            const d = clock_gettime_nsec_np(4);
            try h.drain();
            std.debug.print("\n[v20g R8-b] {s} n={d}: cut tick {d} us (ends {d}) · deadline tick {d} us · ends {d} · cdp left {d}", .{ if (same) "same URL" else "distinct URLs", n, (b - a) / 1000, at_cut, (d - c) / 1000, h.ends, h.table.tabOf(5).?.cdp.items.len });
            try testing.expectEqual(n, h.ends);
            try testing.expectEqual(@as(usize, 0), h.table.tabOf(5).?.cdp.items.len);
        }
    }
    std.debug.print("\n", .{});
}

/// Old (pre-N-a) release rule for one open request — every candidate scanned.
fn gNaiveOrphan(tbl: *const Table, t: *const Tab, o: *const Cdp, now_us: i64) bool {
    if (!o.has_key or (o.state != .open and o.state != .cached)) return false;
    const ts = o.anchor();
    if (now_us - ts <= window_after_us or tbl.cef_seen_us <= ts + window_after_us) return false;
    for (t.cands.items) |c| {
        if (c.claimed or c.key.url != o.key_url or c.key.method != o.key_method) continue;
        if (o.responded and c.key.sw != o.sw) continue;
        if (c.prev_t_io_us != 0) return false;
        if (c.t_io_us >= ts - window_before_us and c.t_io_us <= ts + window_after_us) return false;
    }
    return true;
}

test "W9d② v20g A R4: the indexed orphan scan inside tickAt equals the brute-force rule over many ticks — one key with many (and equal) IO times, colliding keys, sw split, restarts, claimed, records and requests added/removed between ticks, watermark stalls" {
    var prng = std.Random.DefaultPrng.init(0x20a4);
    const r = prng.random();
    var checked: usize = 0;
    var released: usize = 0;
    for (0..300) |_| {
        var h: H = .{};
        defer h.deinit();
        _ = try h.table.start(gpa_t, 5, 1);
        const t = h.table.tabOf(5).?;
        var now: i64 = 10_000_000;
        var seen: i64 = now;
        var next_rid: usize = 0;
        var next_req: u64 = 1;
        var rb: [16]u8 = undefined;
        for (0..40) |_| {
            // mutate between ticks
            const adds = r.uintLessThan(usize, 12);
            for (0..adds) |_| {
                const url = r.uintLessThan(u64, 3);
                const method = r.uintLessThan(u64, 2);
                const ts = now - r.intRangeAtMost(i64, 0, 4_000_000);
                if (r.boolean()) {
                    const rid = try std.fmt.bufPrint(&rb, "o{d}", .{next_rid});
                    next_rid += 1;
                    var o: Cdp = .{ .rid = Rid.init(rid).?, .key_url = url, .key_method = method, .ts_us = ts, .last_url = url };
                    if (r.uintLessThan(u8, 3) == 0) {
                        o.responded = true;
                        o.sw = r.boolean();
                    }
                    if (r.uintLessThan(u8, 10) == 0) o.restart_ts_us = ts + r.intRangeAtMost(i64, 0, 500_000);
                    if (r.uintLessThan(u8, 10) == 0) o.state = .cached;
                    if (t.cdp.items.len < 600) try t.cdp.append(gpa_t, o);
                } else {
                    // several records may share one IO time; equal timestamps on purpose
                    const io = if (r.uintLessThan(u8, 3) == 0) now - 2_500_000 else ts + r.intRangeAtMost(i64, -6_000, 2_100_000);
                    if (t.cands.items.len < 600) try t.cands.append(gpa_t, .{ .request = next_req, .key = .{ .url = url, .method = method, .sw = r.boolean() }, .t_io_us = io, .attr = 1, .claimed = r.uintLessThan(u8, 6) == 0, .prev_t_io_us = if (r.uintLessThan(u8, 15) == 0) io - 1 else 0 });
                    next_req += 1;
                }
            }
            // remove some records / claim some
            if (t.cands.items.len > 0 and r.boolean()) _ = t.cands.orderedRemove(r.uintLessThan(usize, t.cands.items.len));
            if (t.cands.items.len > 0 and r.uintLessThan(u8, 4) == 0) t.cands.items[r.uintLessThan(usize, t.cands.items.len)].claimed = true;
            now += r.intRangeAtMost(i64, 0, 400_000);
            // watermark sometimes stalls
            if (r.uintLessThan(u8, 3) != 0) seen = now - r.intRangeAtMost(i64, 0, 1_000_000);
            // expected keep set
            var want: std.ArrayList(bool) = .empty;
            defer want.deinit(gpa_t);
            const tbl_seen = @max(h.table.cef_seen_us, seen);
            const saved = h.table.cef_seen_us;
            h.table.cef_seen_us = tbl_seen;
            for (t.cdp.items) |*o| try want.append(gpa_t, !gNaiveOrphan(&h.table, t, o, now));
            h.table.cef_seen_us = saved;
            var want_rids: std.ArrayList(Rid) = .empty;
            defer want_rids.deinit(gpa_t);
            for (t.cdp.items, want.items) |o, k| if (k) try want_rids.append(gpa_t, o.rid);
            const before = t.cdp.items.len;
            // no ended candidates → tickAt touches cdp only through the release (cdp are .open/.cached, has_key)
            try h.table.tickAt(gpa_t, now, seen);
            try h.drain();
            errdefer std.debug.print("R4: want {d} kept {d} (before {d})\n", .{ want_rids.items.len, t.cdp.items.len, before });
            try testing.expectEqual(want_rids.items.len, t.cdp.items.len);
            for (t.cdp.items, want_rids.items) |o, w| try testing.expect(o.rid.eql(w.slice()));
            checked += before;
            released += before - t.cdp.items.len;
        }
    }
    std.debug.print("\n[v20g R4] open requests checked {d}, released {d}\n", .{ checked, released });
    try testing.expect(released > 1000 and released < checked);
}

test "W9d② v20g A fuzz debug: V20G_SEED=<seed> [V20G_GAP=1] prints one scenario (no-op otherwise)" {
    const env = std.c.getenv("V20G_SEED") orelse return;
    const seed = std.fmt.parseInt(u64, std.mem.span(env), 10) catch return;
    g_debug_seed = seed;
    defer g_debug_seed = 0;
    if (std.c.getenv("V20G_STALL_PM")) |v| g_stall_pm = std.fmt.parseInt(u16, std.mem.span(v), 10) catch 15;
    if (std.c.getenv("V20G_IOMIX")) |v| g_io_mix = std.fmt.parseInt(u8, std.mem.span(v), 10) catch 0;
    if (std.c.getenv("V20G_WORKER")) |v| g_worker_pct = std.fmt.parseInt(u8, std.mem.span(v), 10) catch 14;
    if (std.c.getenv("V20G_ABORT")) |v| g_abort_pct = std.fmt.parseInt(u8, std.mem.span(v), 10) catch 14;
    if (std.c.getenv("V20G_NONAV") != null) g_navs = false;
    if (std.c.getenv("V20G_NOPRECEF") != null) g_abort_precef = false;
    if (std.c.getenv("V20G_NAVKEEP") != null) g_nav_drop_record = false;
    defer {
        g_stall_pm = 15;
        g_io_mix = 0;
        g_worker_pct = 14;
        g_abort_pct = 14;
        g_navs = true;
        g_abort_precef = true;
        g_nav_drop_record = true;
    }
    var st: GStats = .{};
    try gScenario(seed, std.c.getenv("V20G_GAP") != null, true, &st);
    gPrint("debug", &st);
}

test "W9d② v20g A fuzz knobs (observation, outside the assumptions): renderer stalls (none / ≤ 1.9 s / ≤ 3.5 s) × IO jitter mix (IO up to 1.9 s after the CDP start), doc notices on and off — wrong bodies are printed, not asserted" {
    defer {
        g_stall_pm = 15;
        g_stall_max = 3_500_000;
        g_io_mix = 0;
    }
    inline for (.{ .{ 0, 3_500_000 }, .{ 15, 1_900_000 }, .{ 15, 3_500_000 }, .{ 60, 3_500_000 } }) |sk| {
        inline for (.{ 0, 1, 2 }) |mix| {
            g_stall_pm = sk[0];
            g_stall_max = sk[1];
            g_io_mix = mix;
            var on: GStats = .{};
            var off: GStats = .{};
            for (0..60) |s| {
                try gScenario(0x20c0000 + s, false, true, &on);
                try gScenario(0x20c0000 + s, false, false, &off);
            }
            std.debug.print("\n[v20g knobs stall_pm={d} stall_max={d} io_mix={d}] doc ON: own {d} WRONG {d} end!=1 {d} not idle {d} · doc OFF: own {d} WRONG {d}", .{ sk[0], sk[1], mix, on.own, on.wrong, on.missing_end, on.not_idle, off.own, off.wrong });
            if (on.first_wrong_len > 0) std.debug.print("\n   first: {s}", .{on.first_wrong[0..on.first_wrong_len]});
        }
    }
    std.debug.print("\n", .{});
}

test "W9d② v20g A fuzz factors: no stalls, IO −2..+6 ms — workers {0,14 %} × aborts {0,14 %} × navigations {off,on}: no wrong body in any combination" {
    defer {
        g_stall_pm = 15;
        g_io_mix = 0;
        g_worker_pct = 14;
        g_abort_pct = 14;
        g_navs = true;
    }
    g_stall_pm = 0;
    g_io_mix = 2;
    inline for (.{ 0, 14 }) |wp| inline for (.{ 0, 14 }) |ap| inline for (.{ false, true }) |nv| {
        g_worker_pct = wp;
        g_abort_pct = ap;
        g_navs = nv;
        var on: GStats = .{};
        for (0..300) |s| try gScenario(0x20d0000 + s, false, true, &on);
        std.debug.print("\n[v20g factors workers={d}% aborts={d}% navs={}] own {d} WRONG {d} end!=1 {d} not idle {d}", .{ wp, ap, nv, on.own, on.wrong, on.missing_end, on.not_idle });
        if (on.first_wrong_len > 0) std.debug.print("\n   first: {s}", .{on.first_wrong[0..on.first_wrong_len]});
        try testing.expectEqual(@as(usize, 0), on.wrong);
        try testing.expectEqual(@as(usize, 0), on.missing_end);
        try testing.expectEqual(@as(usize, 0), on.not_idle);
    };
    std.debug.print("\n", .{});
}

test "W9d② v20g A fuzz attribution: IO strictly after the CDP start, no stalls — workers only / aborts only (with and without aborts before CEF) / navigations only (with and without old-doc requests that never reached CEF): no wrong body with doc notices" {
    defer {
        g_stall_pm = 15;
        g_io_mix = 0;
        g_worker_pct = 14;
        g_abort_pct = 14;
        g_navs = true;
        g_abort_precef = true;
        g_nav_drop_record = true;
    }
    g_stall_pm = 0;
    g_io_mix = 3;
    const cases = .{
        .{ "workers only", 14, 0, false, true, true },
        .{ "aborts only (abort may precede CEF)", 0, 14, false, true, true },
        .{ "aborts only (abort always after CEF saw it)", 0, 14, false, false, true },
        .{ "navigations only (old-doc request may never reach CEF)", 0, 0, true, true, true },
        .{ "navigations only (every old-doc request reached CEF)", 0, 0, true, true, false },
        .{ "workers + aborts after CEF + navs with records", 14, 14, true, false, false },
    };
    inline for (cases) |c| {
        g_worker_pct = c[1];
        g_abort_pct = c[2];
        g_navs = c[3];
        g_abort_precef = c[4];
        g_nav_drop_record = c[5];
        var on: GStats = .{};
        var off: GStats = .{};
        for (0..400) |s| {
            try gScenario(0x20e0000 + s, false, true, &on);
            try gScenario(0x20e0000 + s, false, false, &off);
        }
        std.debug.print("\n[v20g attribution {s}] doc ON: own {d} WRONG {d} end!=1 {d} not idle {d} · doc OFF: own {d} WRONG {d}", .{ c[0], on.own, on.wrong, on.missing_end, on.not_idle, off.own, off.wrong });
        if (on.first_wrong_len > 0) std.debug.print("\n   first: {s}", .{on.first_wrong[0..on.first_wrong_len]});
        // doc notices ON is the product; OFF is printed only (without the notice an old-doc request that never reached CEF stays a gap).
        try testing.expectEqual(@as(usize, 0), on.wrong);
        try testing.expectEqual(@as(usize, 0), on.missing_end);
        try testing.expectEqual(@as(usize, 0), on.not_idle);
    }
    std.debug.print("\n", .{});
}

// ── v20g A minimal repros of the fuzz findings (each prints what it fetched; the assertion is the invariant "no wrong body") ──

fn gFetchedFor(h: *H, rid: []const u8) ?u64 {
    for (h.fetches.items) |a| if (a.fetch.rid.eql(rid)) {
        for (h.table.inflight.items) |f| if (f.id == a.fetch.id) return f.request;
    };
    return null;
}

test "W9d② v20g A WB-1 (fixed): MED-2 ends the in-between record of a live request (worker record of the same URL) — that request stays open without its record, steals the next same-URL record, and a later request's body goes to another request's record" {
    const u = "http://127.0.0.1/v20g/wb1";
    const T: i64 = 1_000_000;
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    try h.sent(5, "a", u, T, T + 50); // A (finishes early)
    try h.sent(5, "b", u, T + 1, T + 60); // B (open long — its record will be ended by A's decision)
    _ = try h.cand(5, 1, u, T + 4_000, .{}); // A's record
    _ = try h.cand(5, 2, u, T + 4_100, .{}); // B's record
    _ = try h.cand(5, 9, u, T + 256_000, .{}); // worker record (CDP-invisible), inside B's window
    h.table.cefEnd(5, 9, T + 500_000);
    try h.ev(5, .{ .response = .{ .rid = "a", .mime = "application/json", .from_sw = false, .charset = .other, .ts_us = T + 74_000 } }, T + 74_000);
    try h.ev(5, .{ .data = .{ .rid = "a", .bytes = 9 } }, T + 74_000);
    h.table.cefEnd(5, 1, T + 353_000);
    try h.finish(5, "a", T + 353_500);
    try h.table.tickAt(gpa_t, T + 360_000, T + 360_000);
    try h.drain();
    const b_rec_end = h.ended.get(2);
    // C (open long) and D, E later — same URL
    try h.sent(5, "c", u, T + 500_000, T + 500_100);
    _ = try h.cand(5, 3, u, T + 504_000, .{});
    try h.sent(5, "d", u, T + 1_590_000, T + 1_590_100);
    _ = try h.cand(5, 4, u, T + 1_594_000, .{});
    try h.sent(5, "e", u, T + 1_640_000, T + 1_640_100);
    _ = try h.cand(5, 5, u, T + 1_644_000, .{});
    _ = try gTicks(&h, T + 1_650_000, T + 3_550_000); // the worker record's unmatched expiry passes
    try h.ev(5, .{ .response = .{ .rid = "d", .mime = "application/json", .from_sw = false, .charset = .other, .ts_us = T + 3_560_000 } }, T + 3_560_000);
    try h.ev(5, .{ .data = .{ .rid = "d", .bytes = 9 } }, T + 3_560_000);
    h.table.cefEnd(5, 4, T + 3_599_000);
    try h.finish(5, "d", T + 3_600_000);
    try h.table.tickAt(gpa_t, T + 3_610_000, T + 3_610_000);
    try h.drain();
    // 재검증 3 차 뒤 WB-5: E(응답 전)의 기록은 그 창 끝(T + 3.64 s)까지 올 수 있다 — D 는 그때까지 기다린다.
    try testing.expectEqual(@as(?u64, null), gFetchedFor(&h, "d"));
    _ = try gTicks(&h, T + 3_620_000, T + 3_700_000);
    const d_got = gFetchedFor(&h, "d");
    std.debug.print("\n[v20g WB-1] B's record(2) ended {?} at A's decision · D (own record 4) fetched for record {?} · ends 3 {?} 5 {?}\n", .{ b_rec_end, d_got, h.ended.get(3), h.ended.get(5) });
    try testing.expectEqual(@as(?u64, 4), d_got); // the WB rule: B left with its record, D gets its own
}

test "W9d② v20g A WB-2 (fixed): an old-document request whose CEF record started just after the doc notice (not old_doc) — the record ends unmatched without retiring its open CDP request, which then steals the reloaded request's record; the reloaded request's body goes to a later request's record" {
    const u = "http://127.0.0.1/v20g/wb2";
    const T: i64 = 1_000_000;
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    try h.sent(5, "o", u, T, T + 100); // old document's request (headers never come)
    h.table.documentStarted(5, T + 300_000);
    _ = try h.cand(5, 1, u, T + 301_000, .{}); // its CEF begin lands 1 ms after the doc notice …
    h.table.cefEndAs(5, 1, T + 301_100, false); // … and is cancelled at once
    try h.sent(5, "n", u, T + 302_000, T + 302_100); // reload's request (slow: 3.5 s)
    _ = try h.cand(5, 2, u, T + 303_000, .{});
    try h.sent(5, "m", u, T + 1_000_000, T + 1_000_100); // a later same-URL request (open longer)
    _ = try h.cand(5, 3, u, T + 1_003_000, .{});
    _ = try gTicks(&h, T + 350_000, T + 3_750_000); // record 1's unmatched expiry (3 s) passes
    try h.ev(5, .{ .response = .{ .rid = "n", .mime = "application/json", .from_sw = false, .charset = .other, .ts_us = T + 3_790_000 } }, T + 3_790_000);
    try h.ev(5, .{ .data = .{ .rid = "n", .bytes = 9 } }, T + 3_790_000);
    h.table.cefEnd(5, 2, T + 3_799_000);
    try h.finish(5, "n", T + 3_800_000);
    try h.table.tickAt(gpa_t, T + 3_810_000, T + 3_810_000);
    try h.drain();
    const n_got = gFetchedFor(&h, "n");
    std.debug.print("\n[v20g WB-2] record 1 ended {?} · N (own record 2) fetched for record {?} · 2 {?} 3 {?}\n", .{ h.ended.get(1), n_got, h.ended.get(2), h.ended.get(3) });
    if (n_got) |g| try testing.expectEqual(@as(u64, 2), g);
}

test "W9d② v20g A WB-3 (fixed): documented gap — an old-document CDP request that never reached CEF — with TWO reloaded same-URL requests: the first reloaded request's body goes to the second's record (the gap is not only a lost body)" {
    const u = "http://127.0.0.1/v20g/wb3";
    const T: i64 = 1_000_000;
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    try h.sent(5, "o", u, T, T + 100); // never reaches CEF, cut by the navigation
    h.table.documentStarted(5, T + 300_000);
    try h.sent(5, "n1", u, T + 350_000, T + 350_100);
    _ = try h.cand(5, 1, u, T + 351_000, .{});
    try h.sent(5, "n2", u, T + 360_000, T + 360_100); // open longer than n1
    _ = try h.cand(5, 2, u, T + 361_000, .{});
    try h.ev(5, .{ .response = .{ .rid = "n1", .mime = "application/json", .from_sw = false, .charset = .other, .ts_us = T + 700_000 } }, T + 700_000);
    try h.ev(5, .{ .data = .{ .rid = "n1", .bytes = 9 } }, T + 700_000);
    h.table.cefEnd(5, 1, T + 709_000);
    try h.finish(5, "n1", T + 710_000);
    try h.table.tickAt(gpa_t, T + 720_000, T + 720_000);
    try h.drain();
    const got = gFetchedFor(&h, "n1");
    std.debug.print("\n[v20g WB-3] N1 (own record 1) fetched for record {?} · 1 {?} 2 {?}\n", .{ got, h.ended.get(1), h.ended.get(2) });
    if (got) |g| try testing.expectEqual(@as(u64, 1), g);
}

test "W9d② 재검증 2–9 회차 WB: 후보 상한(4096)으로 가장 오래된 짝 없는 기록을 busy 로 놓으면 그 주인일 수 있는 열린 요청도 뺀다 — 그 요청이 늦게 끝나도 같은 주소의 다음 요청 기록을 가져가지 않는다" {
    const u = "http://127.0.0.1/v20g/wb/victim";
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    try h.sent(5, "a", u, 1_000_000, 1_000_100); // 오래 걸리는 요청 — 그 기록(1)이 상한으로 놓인다
    _ = try h.cand(5, 1, u, 1_000_050, .{});
    var ub: [64]u8 = undefined;
    for (0..max_candidates - 1) |i| _ = try h.cand(5, 100 + i, try std.fmt.bufPrint(&ub, "http://127.0.0.1/v20g/wb/fill/{d}", .{i}), 1_000_100 + @as(i64, @intCast(i)), .{});
    try h.sent(5, "b", u, 1_100_000, 1_100_100);
    _ = try h.cand(5, 2, u, 1_100_050, .{}); // 상한을 넘겨 1 이 busy
    try testing.expect(stateIs(&h, 1, .busy));
    // a 가 남아 있으면 a 는 차례에서 b 의 기록(2)을 가져가고 b 는 짝이 없다 — 이제 a 는 빠졌다: a 의 늦은 끝은 버려지고 b 는 제 본문.
    try testing.expect(cdpIndexOf(&h, "a") == null);
    try h.respond(5, "a", "application/json", 9, 1_200_000);
    try h.finish(5, "a", 1_200_100);
    try h.respond(5, "b", "application/json", 9, 1_200_200);
    h.table.cefEnd(5, 2, 1_200_250);
    try h.finish(5, "b", 1_200_300);
    try h.table.tickAt(gpa_t, 1_210_000, 1_210_000);
    try h.drain();
    try testing.expectEqual(@as(?u64, 2), fetchedFor(&h, "b"));
    try testing.expectEqual(@as(usize, 1), h.fetches.items.len);
}

test "W9d② 재검증 2–9 회차 N3: CDP 자리 상한의 표지는 주소마다고 기록을 다시 켜면(start) 비운다 — 다시 켠 뒤 같은 주소 요청은 제 본문" {
    const k = "http://127.0.0.1/v20g/n3/k";
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    var rb: [24]u8 = undefined;
    var t: i64 = 1_000_000;
    try h.table.cdpEvent(gpa_t, 5, .{ .will_be_sent = .{ .rid = "x", .url_hash = hashUrl8(k), .method_hash = hashMethod("GET"), .ts_us = t } }, t);
    for (0..max_cdp) |i| {
        t += 10;
        const rid = try std.fmt.bufPrint(&rb, "f.{d}", .{i});
        try h.table.cdpEvent(gpa_t, 5, .{ .will_be_sent = .{ .rid = rid, .url_hash = hashUrl8("http://127.0.0.1/v20g/n3/fill"), .method_hash = hashMethod("GET"), .ts_us = t } }, t);
    }
    const tab5 = h.table.tabOf(5).?;
    try testing.expectEqual(@as(usize, 2), tab5.cdp_drop_marks.items.len); // k 와 fill — 주소마다 하나
    _ = try h.table.start(gpa_t, 5, 2);
    try testing.expectEqual(@as(usize, 0), tab5.cdp_drop_marks.items.len);
    try testing.expectEqual(@as(i64, 0), tab5.cdp_drop_until);
    try h.sent(5, "y", k, t + 100, t + 100);
    _ = try h.cand(5, 7, k, t + 150, .{});
    try h.respond(5, "y", "application/json", 9, t + 1_000);
    h.table.cefEnd(5, 7, t + 1_500);
    try h.finish(5, "y", t + 2_000);
    try h.table.tickAt(gpa_t, t + 3_000, t + 3_000);
    try h.drain();
    try testing.expectEqual(@as(?u64, 7), fetchedFor(&h, "y"));
}

test "W9d② 재검증 2–9 회차 WB: CEF 에 닿지 않은 abort 의 실패 뒤 새 문서로 옮겨 다음 요청의 기록이 취소로 끝나도 그 abort 의 것으로 정하지 않는다(request_failed 아님) — 그 기록은 주인과 함께 unavailable 하나" {
    const u = "http://127.0.0.1/v20g/wb/navdef";
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    try h.sent(5, "x", u, 1_000_000, 1_000_050); // abort — CEF 에 닿지 않는다
    try h.ev(5, .{ .failed = .{ .rid = "x", .ts_us = 1_000_100 } }, 1_000_200);
    try h.sent(5, "y", u, 1_000_300, 1_000_350); // 같은 주소의 다음 요청 — 머리 전에 문서가 옮긴다
    _ = try h.cand(5, 1, u, 1_000_400, .{});
    try h.flushed(1_001_000, 1_001_000);
    h.table.documentStarted(5, 1_100_000);
    h.table.cefEndAs(5, 1, 1_100_100, false); // 문서를 옮기며 CEF 가 취소한다
    var now: i64 = 1_100_100;
    while (now < 1_100_100 + unclaimed_expiry_us + 100_000) : (now += 50_000) {
        try h.table.tickAt(gpa_t, now, now);
        try h.drain();
    }
    try testing.expect(stateIs(&h, 1, .unavailable)); // x 가 request_failed 로 가져가지 않았다
    try testing.expectEqual(@as(u32, 1), endCount(&h, 1));
    try testing.expect(!h.table.busy());
}

test "W9d② 재검증 2–9 회차 WB-3: 큰 퍼즈가 찾은 씨앗 — 새 문서 알림이 실제 문서 바뀜보다 늦어 알림 앞에 시작한 새 문서 기록을 앞 문서의 열린 요청이 쥔다(경계를 알림 앞 5 ms 까지 넓게) — 틀린 본문 없음" {
    defer {
        g_stall_pm = 15;
        g_io_mix = 0;
        g_worker_pct = 14;
        g_abort_pct = 14;
    }
    g_stall_pm = 0;
    g_io_mix = 2;
    g_worker_pct = 0;
    var st: GStats = .{};
    for ([_]u8{ 0, 14 }) |ap| {
        g_abort_pct = ap;
        for ([_]u64{ 51183964, 51184756, 51185889, 51185263, 51186227 }) |seed| try gScenario(seed, false, true, &st);
    }
    gPrint("pinned seeds (doc notice boundary)", &st);
    try testing.expectEqual(@as(usize, 0), st.wrong);
    try testing.expectEqual(@as(usize, 0), st.missing_end);
    try testing.expectEqual(@as(usize, 0), st.not_idle);
}

test "W9d② 재검증 2–9 회차 WB-3 대조: 새 문서로 옮기기 바로 앞(알림 앞 5 ms 안)에 앞 문서가 보낸 같은 주소 요청 셋 — 그 기록은 옮기며 취소된다 — 과 다시 불러온 요청 둘은 모두 제 본문(실제 CEF v20g-r9-gap-plain 의 꼴)" {
    const u = "http://127.0.0.1/v20g/wb3/gap";
    var h: H = .{ .sync = false };
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    const doc: i64 = 2_000_000;
    for (0..3) |k| {
        const ki: i64 = @intCast(k);
        var rb: [8]u8 = undefined;
        try h.sent(5, try std.fmt.bufPrint(&rb, "o{d}", .{k}), u, doc - 3_000 + ki * 100, doc - 2_900 + ki * 100);
        _ = try h.cand(5, 10 + k, u, doc - 2_500 + ki * 100, .{});
    }
    h.table.documentStarted(5, doc);
    for (0..3) |k| h.table.cefEndAs(5, 10 + k, doc + 500, false);
    try h.sent(5, "n1", u, doc + 100_000, doc + 100_100);
    _ = try h.cand(5, 20, u, doc + 100_200, .{});
    try h.sent(5, "n2", u, doc + 1_500_000, doc + 1_500_100);
    _ = try h.cand(5, 21, u, doc + 1_500_200, .{});
    try h.flushed(doc + 1_500_300, doc + 1_500_300);
    try h.respond(5, "n1", "application/json", 9, doc + 1_600_000);
    h.table.cefEnd(5, 20, doc + 1_600_500);
    try h.finish(5, "n1", doc + 1_601_000);
    try h.respond(5, "n2", "application/json", 9, doc + 1_700_000);
    h.table.cefEnd(5, 21, doc + 1_700_500);
    try h.finish(5, "n2", doc + 1_701_000);
    try h.flushed(doc + 1_702_000, doc + 1_702_000);
    var buf: [4]u64 = undefined;
    try testing.expectEqualSlices(u64, &.{ 20, 21 }, h.fetchedRequests(&buf));
}

// ── 재검증 3 차: 실측 꼴 모델 퍼즈(검증자 v20h A 의 신탁 — 틀린 본문과 잃은 본문을 함께 센다) ─────────────────────────────────────────
// 시험이 증명하는 것: 실제 페이지 꼴 다섯(SPA 의 GraphQL 무리·무거운 페이지·abort 와 다시 받기·새로고침 고리·localhost 의 같은 주소 무리 — 워커·
// 다른 사이트 iframe 의 CDP 가 보지 못한 같은 주소 기록이 섞인다)에서 씨앗을 고정해 (1) 틀린 본문이 하나도 없고(가정 안: CEF IO 가 CDP 시작
// −2..+6 ms, 그리고 IO 가 50 ms 까지 늦은 줄 — `record_lag_us` 60 ms 안), (2) 잃은 본문(제 기록이 있고 성공한 글 요청인데 제 본문을 받지 못한
// 것)의 율이 e9ba4f018(재검증 2–9 회차 앞 — 틀린 본문이 있던 코드)의 같은 씨앗의 율을 넘지 않고(IO 50 ms 줄은 0.1 %p 까지), (3) 시작마다 끝이
// 꼭 하나이고 한가해진다. 율의 한계는 같은 씨앗에서 e9ba4f018 을 돌려 잰 값이다(`scratchpad/w9d2fix4/hx` — 같은 생성기·같은 씨앗을 옛 코드에
// 붙여 돌렸다): IO −2..+6 ms 씨앗 200 개 — spa-json 271/11614·heavy-page 609/17684·abort-refetch 107/5529·reload-loop 19/6478·
// localhost-bursts 1014/16479(틀린 본문 15·7·9·5·42 도 잃은 것으로 셌다), IO −2..+50 ms 씨앗 100 개 — 119/5821·314/8816·6/2531·2/3201·
// 850/8175(틀린 본문 7·0·1·1·82). 1c8e95230(재검증 2–9 회차)은 같은 씨앗에서 heavy-page 4.03 %·reload-loop 1.87 % 를 잃었다(LB-1).
// 브라우저 탭에서 중요한 이유: 에이전트는 받은 본문을 그 요청의 응답으로 믿는다 — 남의 기록에 붙은 본문은 조용히 틀린 답이 되고, 잃은 본문은
// 같은 요청을 다시 부르게 한다.

const PfKind = enum { page, worker };
const PfOut = enum { ok, abort, cut };
const PfReq = struct {
    kind: PfKind,
    url: u16,
    post: bool = false,
    attr: u64 = 1,
    text: bool = true,
    ts: i64 = 0,
    io: i64 = 0,
    cef_id: u64 = 0,
    out: PfOut = .ok,
    resp: i64 = 0,
    fin: i64 = 0,
    cef_end: i64 = 0,
    cef_ok: bool = true,
    /// 그 요청을 낸 문서의 loader(0 = worker).
    loader: u64 = 1,
};

const PfCdpKind = enum { sent, resp, fin, fail };
const PfCdp = struct { gen: i64, at: i64 = 0, kind: PfCdpKind, idx: usize };
const PfCef = struct { io: i64, begin: bool, idx: usize };

const PfStats = struct {
    scenarios: usize = 0,
    eligible: usize = 0,
    own: usize = 0,
    wrong: usize = 0,
    lost: usize = 0,
    missing_end: usize = 0,
    not_idle: usize = 0,
    first_wrong_seed: u64 = 0,
};

fn pfUrl(buf: []u8, u: u16) []const u8 {
    return std.fmt.bufPrint(buf, "https://p.test/{d}", .{u}) catch unreachable;
}

fn pfRid(buf: []u8, i: usize) []const u8 {
    return std.fmt.bufPrint(buf, "p{d}", .{i}) catch unreachable;
}

const PfGen = struct {
    r: std.Random,
    reqs: *std.ArrayList(PfReq),
    next_id: u64 = 1,
    loader: u64 = 1,
    /// CEF IO 가 CDP 시작보다 늦을 수 있는 가장 큰 값(µs).
    io_max: i64,

    fn lat(self: *PfGen, slow_pct: u8) i64 {
        const x = self.r.uintLessThan(u8, 100);
        if (x < slow_pct) return self.r.intRangeAtMost(i64, 400_000, 2_500_000);
        return self.r.intRangeAtMost(i64, 15_000, 400_000);
    }

    /// CDP 가 보는 페이지 요청 하나(IO 는 CDP 시작 −2 ms .. `io_max`).
    fn page(self: *PfGen, ts: i64, url: u16, post: bool, attr: u64, latency: i64, abort_pct: u8, precef_pct: u8, refetch_pct: u8) !void {
        var q: PfReq = .{ .kind = .page, .url = url, .post = post, .attr = attr, .ts = ts, .loader = self.loader };
        q.io = ts + self.r.intRangeAtMost(i64, -2_000, self.io_max);
        q.cef_id = self.next_id;
        self.next_id += 1;
        q.resp = q.io + latency;
        q.fin = q.resp + self.r.intRangeAtMost(i64, 0, 60_000);
        q.cef_end = @max(q.resp, q.fin + self.r.intRangeAtMost(i64, -1_000, 2_000));
        if (abort_pct > 0 and self.r.uintLessThan(u8, 100) < abort_pct) {
            const pre = self.r.uintLessThan(u8, 100) < precef_pct;
            const a = if (pre) q.io - self.r.intRangeAtMost(i64, 1, 3_000) else q.io + self.r.intRangeAtMost(i64, 0, @max(1, @min(latency - 1, 200_000)));
            q.out = .abort;
            q.resp = 0;
            q.fin = @max(a, q.ts + 1);
            if (a < q.io) {
                q.io = 0;
                q.cef_id = 0;
                q.cef_end = 0;
            } else {
                q.cef_end = a + self.r.intRangeAtMost(i64, 0, 1_000);
                q.cef_ok = false;
            }
            try self.reqs.append(gpa_t, q);
            if (self.r.uintLessThan(u8, 100) < refetch_pct) try self.page(q.fin + self.r.intRangeAtMost(i64, 0, 500), url, post, attr, self.lat(5), 0, 0, 0);
            return;
        }
        try self.reqs.append(gpa_t, q);
    }

    /// CEF 만 보는 기록(워커·다른 사이트 iframe — CDP 가 보지 못한다).
    fn hidden(self: *PfGen, t: i64, url: u16, post: bool, attr: u64) !void {
        var q: PfReq = .{ .kind = .worker, .url = url, .post = post, .attr = attr, .loader = 0 };
        q.io = t;
        q.cef_id = self.next_id;
        self.next_id += 1;
        q.cef_end = q.io + self.r.intRangeAtMost(i64, 10_000, 600_000);
        try self.reqs.append(gpa_t, q);
    }
};

/// 꼴: 0 spa-json(한 POST 열쇠의 GraphQL 무리·1 초 폴링·같은 열쇠의 워커), 1 heavy-page(요청 220 개·같은 JSON 주소 10·보이는 규칙이 다른 같은
/// 사이트 iframe·다른 사이트 iframe/워커의 같은 주소 기록), 2 abort-refetch(타자마다 앞 요청 abort·StrictMode 의 두 번 받기), 3 reload-loop(0.4–2 초마다
/// 새 문서 — 문서마다 같은 주소 셋을 다시 받는다, 긴 요청은 끊긴다), 4 localhost-bursts(0–12 ms 간격의 같은 열쇠 무리, 응답 1–8 ms, 워커·iframe 기록).
fn pfGenerate(profile: u8, seed: u64, io_max: i64, reqs: *std.ArrayList(PfReq), navs: *std.ArrayList(i64)) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    var g: PfGen = .{ .r = r, .reqs = reqs, .io_max = io_max };
    const t0: i64 = 10_000_000;
    var uniq: u16 = 1000;
    switch (profile) {
        0 => {
            const worker_on = r.uintLessThan(u8, 100) < 40;
            var t = t0;
            for (0..8) |_| {
                try g.page(t, uniq, false, 1, g.lat(5), 0, 0, 0);
                uniq += 1;
                t += r.intRangeAtMost(i64, 0, 2_000);
            }
            const end = t0 + 8_000_000;
            var next_poll = t0 + 1_000_000;
            while (t < end) {
                const n = r.intRangeAtMost(usize, 1, 6);
                var bt = t;
                for (0..n) |_| {
                    try g.page(bt, 0, true, 1, g.lat(8), 6, 30, 50);
                    bt += r.intRangeAtMost(i64, 0, 400);
                }
                for (0..r.uintLessThan(usize, 3)) |_| {
                    try g.page(bt + r.intRangeAtMost(i64, 0, 20_000), uniq, false, 1, g.lat(5), 0, 0, 0);
                    uniq += 1;
                }
                if (worker_on and r.uintLessThan(u8, 100) < 25) try g.hidden(t + r.intRangeAtMost(i64, -300_000, 1_500_000), 0, true, 9);
                t += r.intRangeAtMost(i64, 300_000, 1_500_000);
                while (next_poll < t) : (next_poll += 1_000_000 + r.intRangeAtMost(i64, -50_000, 50_000)) {
                    try g.page(next_poll, 1, false, 1, g.lat(3), 0, 0, 0);
                    if (worker_on and r.uintLessThan(u8, 100) < 10) try g.hidden(next_poll + r.intRangeAtMost(i64, -500_000, 1_500_000), 1, false, 9);
                }
            }
        },
        1 => {
            var t = t0;
            for (0..220) |_| {
                const x = r.uintLessThan(u8, 100);
                if (x < 82) {
                    try g.page(t, uniq, false, 1, g.lat(10), 2, 30, 0);
                    reqs.items[reqs.items.len - 1].text = r.uintLessThan(u8, 100) < 25;
                    uniq += 1;
                } else try g.page(t, r.uintLessThan(u16, 10), false, 1, g.lat(10), 2, 30, 30);
                t += r.intRangeAtMost(i64, 0, 12_000);
            }
            for (0..r.uintLessThan(usize, 3)) |_| {
                var ft = t0 + r.intRangeAtMost(i64, 200_000, 2_000_000);
                for (0..5) |_| {
                    try g.page(ft, r.uintLessThan(u16, 10), false, 2, g.lat(10), 0, 0, 0);
                    ft += r.intRangeAtMost(i64, 0, 30_000);
                }
            }
            for (0..r.uintLessThan(usize, 4)) |_| try g.hidden(t0 + r.intRangeAtMost(i64, 0, 2_500_000), r.uintLessThan(u16, 10), false, 3);
        },
        2 => {
            var t = t0;
            for (0..40) |_| {
                const u = r.uintLessThan(u16, 4);
                try g.page(t, u, false, 1, g.lat(10), 0, 0, 0);
                const gap = r.intRangeAtMost(i64, 40_000, 350_000);
                const q = &reqs.items[reqs.items.len - 1];
                if (q.resp > t + gap and r.uintLessThan(u8, 100) < 80) {
                    const a = t + gap;
                    q.out = .abort;
                    q.resp = 0;
                    q.fin = a;
                    if (a < q.io) {
                        q.io = 0;
                        q.cef_id = 0;
                        q.cef_end = 0;
                    } else {
                        q.cef_end = a + r.intRangeAtMost(i64, 0, 1_000);
                        q.cef_ok = false;
                    }
                }
                t += gap;
            }
            for (0..r.intRangeAtMost(usize, 3, 10)) |_| {
                const st = t0 + r.intRangeAtMost(i64, 0, 12_000_000);
                try g.page(st, 10 + r.uintLessThan(u16, 3), false, 1, g.lat(5), 100, 60, 100);
            }
        },
        3 => {
            const n_nav = r.intRangeAtMost(usize, 3, 6);
            var doc_start = t0;
            for (0..n_nav + 1) |k| {
                g.loader = 100 + k;
                var dt = doc_start + r.intRangeAtMost(i64, 100, 4_000);
                for (0..r.intRangeAtMost(usize, 4, 12)) |_| {
                    const shared = r.uintLessThan(u8, 100) < 50;
                    const u: u16 = if (shared) r.uintLessThan(u16, 3) else blk: {
                        uniq += 1;
                        break :blk uniq;
                    };
                    const latency = if (r.uintLessThan(u8, 100) < 25) r.intRangeAtMost(i64, 1_000_000, 6_000_000) else g.lat(5);
                    try g.page(dt, u, false, 1, latency, 5, 40, 60);
                    dt += r.intRangeAtMost(i64, 0, 60_000);
                }
                if (k == n_nav) break;
                const t = doc_start + r.intRangeAtMost(i64, 400_000, 2_000_000);
                try navs.append(gpa_t, t);
                doc_start = t;
            }
        },
        4 => {
            var t = t0;
            const end = t0 + 6_000_000;
            while (t < end) {
                const u = r.uintLessThan(u16, 3);
                const post = r.boolean();
                var bt = t;
                for (0..r.intRangeAtMost(usize, 2, 7)) |_| {
                    const latency = if (r.uintLessThan(u8, 100) < 70) r.intRangeAtMost(i64, 1_000, 8_000) else r.intRangeAtMost(i64, 8_000, 300_000);
                    try g.page(bt, u, post, 1, latency, 8, 40, 60);
                    bt += r.intRangeAtMost(i64, 0, 12_000);
                }
                if (r.uintLessThan(u8, 100) < 15) try g.hidden(t + r.intRangeAtMost(i64, -20_000, 40_000), u, post, if (r.boolean()) 3 else 9);
                t += r.intRangeAtMost(i64, 50_000, 600_000);
            }
        },
        else => unreachable,
    }
}

/// 씨앗 하나를 바른 시각 차례로 표에 흘리고 센다: CEF 기록은 10 ms 묶음(물 높이 — 그 묶음의 IO 시각까지), CDP 사건은 0.1–3 ms 늦게 차례대로,
/// 새 문서 알림은 이동 0.2–4 ms 뒤, 50 ms 주기 task, 본문 호출의 답은 1–40 ms 뒤. 한 렌더러라 CDP 가 보는 요청의 CEF IO 는 CDP 시작 차례다.
fn pfScenario(profile: u8, seed: u64, io_max: i64, st: *PfStats) !void {
    var reqs: std.ArrayList(PfReq) = .empty;
    defer reqs.deinit(gpa_t);
    var navs: std.ArrayList(i64) = .empty;
    defer navs.deinit(gpa_t);
    try pfGenerate(profile, seed, io_max, &reqs, &navs);
    var prng = std.Random.DefaultPrng.init(seed ^ 0x5a5a_1234);
    const r = prng.random();
    const t0: i64 = 10_000_000;
    {
        var order: std.ArrayList(usize) = .empty;
        defer order.deinit(gpa_t);
        for (reqs.items, 0..) |q, k| if (q.kind == .page and q.io != 0) try order.append(gpa_t, k);
        const Ctx = struct {
            rq: []const PfReq,
            fn lt(c: @This(), a: usize, b: usize) bool {
                return c.rq[a].ts < c.rq[b].ts or (c.rq[a].ts == c.rq[b].ts and a < b);
            }
        };
        std.mem.sort(usize, order.items, Ctx{ .rq = reqs.items }, Ctx.lt);
        var prev: i64 = 0;
        for (order.items) |k| {
            const q = &reqs.items[k];
            const io = @max(q.io, prev + 1);
            const d = io - q.io;
            q.io = io;
            if (d > 0) {
                if (q.resp != 0) q.resp += d;
                if (q.fin != 0) q.fin += d;
                if (q.cef_end != 0) q.cef_end += d;
            }
            prev = io;
        }
    }
    for (reqs.items) |q| if (q.kind == .page and q.io != 0 and q.io - q.ts > window_after_us - 50_000) return;
    for (reqs.items) |*q| {
        const start = if (q.kind == .worker) q.io else q.ts;
        const end = if (q.kind == .worker) q.cef_end else q.fin;
        for (navs.items) |nv| if (start < nv and end > nv) {
            q.out = .cut;
            if (q.resp > nv) q.resp = 0;
            q.fin = 0;
            if (q.io != 0) {
                q.cef_end = nv + r.intRangeAtMost(i64, 0, 3_000);
                q.cef_ok = false;
            } else q.cef_end = 0;
            break;
        };
    }
    var cef: std.ArrayList(PfCef) = .empty;
    defer cef.deinit(gpa_t);
    for (reqs.items, 0..) |q, k| if (q.io != 0) {
        try cef.append(gpa_t, .{ .io = q.io, .begin = true, .idx = k });
        if (q.cef_end != 0) try cef.append(gpa_t, .{ .io = @max(q.cef_end, q.io + 1), .begin = false, .idx = k });
    };
    std.mem.sort(PfCef, cef.items, {}, struct {
        fn lt(_: void, a: PfCef, b: PfCef) bool {
            return a.io < b.io or (a.io == b.io and a.begin and !b.begin);
        }
    }.lt);
    var cdp: std.ArrayList(PfCdp) = .empty;
    defer cdp.deinit(gpa_t);
    for (reqs.items, 0..) |q, k| if (q.kind == .page) {
        try cdp.append(gpa_t, .{ .gen = q.ts, .kind = .sent, .idx = k });
        if (q.resp != 0) try cdp.append(gpa_t, .{ .gen = q.resp, .kind = .resp, .idx = k });
        if (q.fin != 0) try cdp.append(gpa_t, .{ .gen = q.fin, .kind = if (q.out == .abort) .fail else .fin, .idx = k });
    };
    std.mem.sort(PfCdp, cdp.items, {}, struct {
        fn lt(_: void, a: PfCdp, b: PfCdp) bool {
            if (a.gen != b.gen) return a.gen < b.gen;
            if (a.kind != b.kind) return @backingInt(a.kind) < @backingInt(b.kind);
            return a.idx < b.idx;
        }
    }.lt);
    {
        var last: i64 = 0;
        for (cdp.items) |*e| {
            e.at = @max(e.gen + r.intRangeAtMost(i64, 100, 3_000), last + 1);
            last = e.at;
        }
    }
    var docs: std.ArrayList(i64) = .empty;
    defer docs.deinit(gpa_t);
    for (navs.items) |nv| try docs.append(gpa_t, nv + r.intRangeAtMost(i64, 200, 4_000));
    var h: H = .{ .sync = false };
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    var rid_buf: [16]u8 = undefined;
    var url_buf: [32]u8 = undefined;
    var now: i64 = t0 - 1;
    var next_flush: i64 = t0 + r.intRangeAtMost(i64, 0, 10_000);
    var next_tick: i64 = t0 + r.intRangeAtMost(i64, 0, 50_000);
    var cef_cur: usize = 0;
    var cdp_cur: usize = 0;
    var doc_cur: usize = 0;
    const Pending = struct { id: i32, due: i64 };
    var pend: std.ArrayList(Pending) = .empty;
    defer pend.deinit(gpa_t);
    var seen_fetch: usize = 0;
    var horizon: i64 = 0;
    for (cdp.items) |e| horizon = @max(horizon, e.at);
    for (cef.items) |e| horizon = @max(horizon, e.io);
    horizon += 15_000_000;
    const fetched_own = try gpa_t.alloc(bool, reqs.items.len);
    defer gpa_t.free(fetched_own);
    @memset(fetched_own, false);
    var dprng = std.Random.DefaultPrng.init(seed ^ 0x77);
    const dr = dprng.random();
    while (now < horizon) {
        var nt = @min(next_flush, next_tick);
        if (cdp_cur < cdp.items.len) nt = @min(nt, cdp.items[cdp_cur].at);
        if (doc_cur < docs.items.len) nt = @min(nt, docs.items[doc_cur]);
        for (pend.items) |p| nt = @min(nt, p.due);
        now = nt;
        // 물 높이 — 아직 넘기지 않은 CEF 기록의 IO 시각 앞까지.
        const wm = blk: {
            var w = now - 1;
            if (cef_cur < cef.items.len and cef.items[cef_cur].io <= now) w = @min(w, cef.items[cef_cur].io - 1);
            break :blk w;
        };
        if (doc_cur < docs.items.len and docs.items[doc_cur] == now) {
            h.table.documentStarted(5, now);
            doc_cur += 1;
        } else if (cdp_cur < cdp.items.len and cdp.items[cdp_cur].at == now) {
            const e = cdp.items[cdp_cur];
            cdp_cur += 1;
            const q = reqs.items[e.idx];
            const rid = pfRid(&rid_buf, e.idx);
            switch (e.kind) {
                .sent => {
                    try h.ev(5, .{ .will_be_sent = .{ .rid = rid, .url_hash = hashUrl8(pfUrl(&url_buf, q.url)), .method_hash = hashMethod(if (q.post) "POST" else "GET"), .ts_us = q.ts, .loader = q.loader } }, now);
                    try h.ev(5, .{ .extra_info = .{ .rid = rid, .credentialed = false } }, now);
                },
                .resp => {
                    try h.ev(5, .{ .response = .{ .rid = rid, .mime = if (q.text) "application/json" else "image/png", .from_sw = false, .charset = .other, .ts_us = q.resp } }, now);
                    try h.ev(5, .{ .data = .{ .rid = rid, .bytes = 10 } }, now);
                },
                .fin => {
                    h.table.cef_seen_us = @max(h.table.cef_seen_us, wm);
                    try h.ev(5, .{ .finished = .{ .rid = rid } }, now);
                },
                .fail => {
                    h.table.cef_seen_us = @max(h.table.cef_seen_us, wm);
                    try h.ev(5, .{ .failed = .{ .rid = rid, .ts_us = q.fin } }, now);
                },
            }
        } else if (next_flush == now) {
            next_flush += 10_000;
            while (cef_cur < cef.items.len and cef.items[cef_cur].io <= now) : (cef_cur += 1) {
                const e = cef.items[cef_cur];
                const q = reqs.items[e.idx];
                if (e.begin) {
                    _ = try h.cand(5, q.cef_id, pfUrl(&url_buf, q.url), q.io, .{ .method = if (q.post) "POST" else "GET", .attr = q.attr });
                } else h.table.cefEndReceived(5, q.cef_id, now, q.cef_ok, if (q.cef_ok) 10 else 0);
            }
            try h.flushed(now - 1, now);
        } else if (next_tick == now) {
            next_tick += 50_000;
            try h.table.tickAt(gpa_t, now, wm);
            try h.drain();
        } else {
            var k: usize = 0;
            while (k < pend.items.len) {
                if (pend.items[k].due != now) {
                    k += 1;
                    continue;
                }
                const p = pend.swapRemove(k);
                if (h.table.takeInflight(p.id)) |f| {
                    try h.noteEnd(f.request, .captured);
                    try h.table.bodyDone(gpa_t, f, now);
                    try h.drain();
                }
            }
        }
        while (seen_fetch < h.fetches.items.len) : (seen_fetch += 1) {
            const a = h.fetches.items[seen_fetch].fetch;
            var req: u64 = 0;
            for (h.table.inflight.items) |f| if (f.id == a.id) {
                req = f.request;
            };
            const idx = std.fmt.parseInt(usize, a.rid.slice()[1..], 10) catch unreachable;
            if (reqs.items[idx].cef_id == req) fetched_own[idx] = true else {
                st.wrong += 1;
                if (st.first_wrong_seed == 0) st.first_wrong_seed = seed;
            }
            try pend.append(gpa_t, .{ .id = a.id, .due = now + dr.intRangeAtMost(i64, 1_000, 40_000) });
        }
    }
    st.scenarios += 1;
    if (h.table.busy()) st.not_idle += 1;
    for (reqs.items, 0..) |q, k| {
        if (q.cef_id != 0 and endCount(&h, q.cef_id) != 1) st.missing_end += 1;
        if (q.kind != .page or q.out != .ok or q.cef_id == 0 or !q.text) continue;
        st.eligible += 1;
        if (fetched_own[k]) st.own += 1 else st.lost += 1;
    }
}

const pf_names = [_][]const u8{ "spa-json", "heavy-page", "abort-refetch", "reload-loop", "localhost-bursts" };

/// 꼴마다 씨앗 `n` 개(검증자의 씨앗 — `0x7a00000 + s × 7919 + 꼴`)를 돌려, 틀린 본문 0·끝 하나·한가해짐과 잃은 본문의 율 상한(`bound_bp` — 만분율,
/// 같은 씨앗의 e9ba4f018 의 율을 올림한 값)을 단언한다. 생성기가 바뀌면 상한이 뜻을 잃으니 자격 있는 본문 수(`eligible`)도 박는다.
fn pfCheck(io_max: i64, n: usize, eligible: [5]usize, bound_bp: [5]usize) !void {
    for (0..5) |p| {
        var st: PfStats = .{};
        for (0..n) |s| try pfScenario(@intCast(p), 0x7a00000 + s * 7919 + p, io_max, &st);
        errdefer std.debug.print("[fuzz] {s} IO ..+{d} us: seeds {d} · eligible {d} · own {d} · lost {d} · wrong {d} (first seed {d}) · end!=1 {d} · not idle {d}\n", .{ pf_names[p], io_max, st.scenarios, st.eligible, st.own, st.lost, st.wrong, st.first_wrong_seed, st.missing_end, st.not_idle });
        try testing.expectEqual(n, st.scenarios);
        try testing.expectEqual(eligible[p], st.eligible);
        try testing.expectEqual(@as(usize, 0), st.wrong);
        try testing.expectEqual(@as(usize, 0), st.missing_end);
        try testing.expectEqual(@as(usize, 0), st.not_idle);
        try testing.expect(st.lost * 10_000 <= bound_bp[p] * st.eligible);
    }
}

test "W9d② 재검증 3 차 퍼즈: 실측 꼴 다섯(IO 가 CDP 시작 −2..+6 ms) — 틀린 본문 0, 잃은 본문의 율 상한, 끝 하나, 한가해짐" {
    // 재검증 3 차 뒤 WB-5: 응답 전의 열린 요청은 응답(또는 창 끝)까지 「기록이 아직 올 수 있다」 — 같은 주소의 앞 요청은 그동안 기다리고(시한
    // `split_wait_us`) 넘기면 본문 없이. 잃은 본문(만분율): 0e5012175 213·340·181·21·601 → 371·408·187·36·634(e9ba4f018 234·345·194·30·616).
    try pfCheck(6_000, 200, .{ 11614, 17684, 5529, 6478, 16479 }, .{ 371, 408, 187, 36, 634 });
}

test "W9d② 재검증 3 차 퍼즈: IO 가 CDP 시작보다 50 ms 까지 늦은 실측 꼴 다섯(WB-4 — 뒤 요청의 기록이 늦다) — 틀린 본문 0, 잃은 본문의 율 상한" {
    // e9ba4f018: 119/5821(2.04 %, 틀림 7)·314/8816(3.56 %)·6/2531(0.24 %, 틀림 1)·2/3201(0.06 %, 틀림 1)·850/8175(10.40 %, 틀림 82).
    // 0e5012175(만분율): 195·357·20·4·1041 → 360·385·20·7·1051.
    try pfCheck(50_000, 100, .{ 5821, 8816, 2531, 3201, 8175 }, .{ 360, 385, 20, 7, 1051 });
}

test "W9d② 재검증 3 차 뒤 WB-5 퍼즈: IO 가 CDP 시작보다 300 ms·1.6 s 까지 늦은 꼴 다섯(60 ms 가정 밖 — 서비스 워커가 늦게 넘긴 요청) — 틀린 본문 0" {
    // 0e5012175 의 틀린 본문: 300 ms 1·2·0·0·166, 1.6 s 371·85·0·0·1110 — 60 ms 뒤에는 응답 전의 요청도 제 기록을 가졌다고 봤다.
    // 잃은 본문(만분율) 300 ms 313·506·11·0·1274 → 511·536·11·0·1276, 1.6 s 1526·925·40·210·2764 → 1579·914·40·210·2781.
    try pfCheck(300_000, 100, .{ 5821, 8816, 1895, 3002, 8175 }, .{ 511, 536, 11, 0, 1276 });
    try pfCheck(1_600_000, 100, .{ 5821, 8816, 1502, 1434, 8175 }, .{ 1579, 914, 40, 210, 2781 });
}

/// 재검증 3 차 뒤 WB-5(검증자 v20i A 의 P-i): 서비스 워커가 같은 주소를 제 fetch 로 먼저 받고(CDP 가 보지 못한 기록 X — 차례 맨 앞), 페이지의
/// R1 은 곧 넘기고, 1 ms 뒤의 R2 는 `lag` 뒤에 넘긴다(`syn` 이면 넘기지 않고 Cache Storage 로 답한다 — 기록 없음). R1·R2 가 본문을 받은 기록
/// (`out` — 0 = 받지 않았다)을 준다. R1 의 제 기록은 2, R2 는 3.
fn wb5Run(lag: i64, syn: bool, out: *[2]u64) !void {
    var h: H = .{ .sync = false };
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    const u = "https://p.test/i";
    const t0: i64 = 10_000_000;
    const sw_resp = struct {
        fn f(hh: *H, rid: []const u8, src: []const u8, ts: i64, now: i64) !void {
            try hh.ev(5, .{ .response = .{ .rid = rid, .mime = "application/json", .from_sw = true, .sw_source = src, .charset = .other, .ts_us = ts } }, now);
            try hh.ev(5, .{ .data = .{ .rid = rid, .bytes = 9 } }, now);
        }
    }.f;
    try h.ev(5, .{ .will_be_sent = .{ .rid = "r1", .url_hash = hashUrl8(u), .method_hash = hashMethod("GET"), .ts_us = t0 } }, t0 + 200);
    try h.ev(5, .{ .will_be_sent = .{ .rid = "r2", .url_hash = hashUrl8(u), .method_hash = hashMethod("GET"), .ts_us = t0 + 1_000 } }, t0 + 1_200);
    _ = try h.cand(5, 1, u, t0 + 500, .{ .sw = true }); // X — 워커 제 fetch
    _ = try h.cand(5, 2, u, t0 + 1_100, .{ .sw = true }); // R1 을 넘겼다
    try h.flushed(t0 + 2_000, t0 + 2_000);
    try sw_resp(&h, "r1", "network", t0 + 4_000, t0 + 4_200);
    h.table.cefEndReceived(5, 1, t0 + 4_500, true, 10);
    h.table.cefEndReceived(5, 2, t0 + 4_600, true, 10);
    try h.flushed(t0 + 5_000, t0 + 5_000);
    try h.finish(5, "r1", t0 + 5_000);
    var now: i64 = t0 + 10_000;
    var r2_done = false;
    while (now < t0 + 4_000_000) : (now += 10_000) {
        if (!r2_done and now >= t0 + 1_000 + lag) {
            r2_done = true;
            if (syn) {
                try sw_resp(&h, "r2", "cache-storage", now - 1_000, now);
                try h.finish(5, "r2", now);
            } else {
                _ = try h.cand(5, 3, u, t0 + 1_000 + lag, .{ .sw = true });
                try h.flushed(now, now);
                try sw_resp(&h, "r2", "network", now + 2_000, now + 2_500);
                h.table.cefEndReceived(5, 3, now + 2_600, true, 10);
                try h.flushed(now + 3_000, now + 3_000);
                try h.finish(5, "r2", now + 3_000);
            }
        }
        try h.table.tickAt(gpa_t, now, now);
        try h.drain();
    }
    out.* = .{ fetchedFor(&h, "r1") orelse 0, fetchedFor(&h, "r2") orelse 0 };
}

test "W9d② 재검증 3 차 뒤 WB-5(P-i): 서비스 워커가 같은 주소를 먼저 받고 뒤 요청을 20 ms–1 s 늦게 넘기거나 캐시로 늦게 답해도 앞 요청의 본문은 워커의 기록에 붙지 않는다" {
    for ([_]i64{ 20_000, 59_000, 61_000, 100_000, 300_000, 1_000_000 }) |lag| {
        for ([_]bool{ false, true }) |syn| {
            var o: [2]u64 = undefined;
            try wb5Run(lag, syn, &o);
            errdefer std.debug.print("[WB-5] lag {d} ms syn {}: r1 fetched for {d} (own 2), r2 for {d} (own 3)\n", .{ @divTrunc(lag, 1000), syn, o[0], o[1] });
            // 0e5012175: 60 ms 넘게 늦으면 r1 의 본문을 X(1)에 붙였다. 이제 r1 은 r2 의 기록이 정해질 때까지 기다리고 X 가 갈림을 보여 본문 없이.
            try testing.expect(o[0] == 0 or o[0] == 2);
            try testing.expect(o[1] == 0 or o[1] == 3);
        }
    }
}

test "W9d② 재검증 3 차 뒤 PF-2: 같은 주소 GET 60·곧 abort 한 fetch 3000(CEF 에 닿지 않는다)·뒤의 느린 GET 60 — 실패 사건은 맞추기를 하지 않고, 한 주기가 abort 를 놓으며 맞추기를 다시 하지 않는다" {
    var h: H = .{ .sync = false };
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    const u = "https://p.test/hostile";
    const t0: i64 = 10_000_000;
    var rb: [16]u8 = undefined;
    var req: u64 = 1;
    for (0..60) |k| {
        const ts = t0 + @as(i64, @intCast(k)) * 10;
        try h.sent(5, try std.fmt.bufPrint(&rb, "g{d}", .{k}), u, ts, ts + 5);
        _ = try h.cand(5, req, u, ts + 100, .{});
        req += 1;
    }
    for (0..3000) |k| {
        const ts = t0 + 1_000 + @as(i64, @intCast(k)) * 10;
        try h.sent(5, try std.fmt.bufPrint(&rb, "f{d}", .{k}), u, ts, ts + 5);
    }
    // 앞 GET 은 모두 성공으로 끝났다 — abort 의 짝일 수 없다(응답 없이 실패한 요청은 성공으로 끝난 기록을 갖지 않는다).
    for (0..60) |k| {
        h.table.cefEndReceived(5, 1 + k, t0 + 40_000, true, 10);
        try h.respond(5, try std.fmt.bufPrint(&rb, "g{d}", .{k}), "application/json", 9, t0 + 39_000);
        try h.finish(5, try std.fmt.bufPrint(&rb, "g{d}", .{k}), t0 + 40_000);
    }
    try h.flushed(t0 + 50_000, t0 + 50_000);
    try h.drain();
    const runs0 = h.table.scratch.match_runs;
    // abort 의 CDP 실패(시각은 물 높이 앞 — 곧 정할 수 있다).
    for (0..3000) |k| try h.ev(5, .{ .failed = .{ .rid = try std.fmt.bufPrint(&rb, "f{d}", .{k}), .ts_us = t0 + 45_000 } }, t0 + 60_000 + @as(i64, @intCast(k)));
    // 실패 사건마다 맞추지 않는다(전에는 3000 번 — 같은 주소 무리 3060 개를 그때마다).
    try testing.expectEqual(runs0, h.table.scratch.match_runs);
    // 느린 GET 60(창 밖 — abort 의 짝일 수 없다).
    for (0..60) |k| {
        const ts = t0 + 2_500_000 + @as(i64, @intCast(k)) * 10;
        try h.sent(5, try std.fmt.bufPrint(&rb, "s{d}", .{k}), u, ts, ts + 5);
        _ = try h.cand(5, req, u, ts + 100, .{});
        req += 1;
    }
    // 시한 뒤 한 주기: abort 3000 은 짝 없이 놓인다 — 그때마다 맞추기를 다시 하지 않는다(전에는 abort 마다 — ReleaseFast 한 주기 0.6–1.1 s).
    const runs1 = h.table.scratch.match_runs;
    try h.table.tickAt(gpa_t, t0 + 2_600_000, t0 + 2_600_000);
    try h.drain();
    errdefer std.debug.print("[PF-2] match runs in the release tick: {d}, cdp left {d}\n", .{ h.table.scratch.match_runs - runs1, h.table.tabOf(5).?.cdp.items.len });
    try testing.expect(h.table.scratch.match_runs - runs1 <= 10);
    var bare: usize = 0;
    for (h.table.tabOf(5).?.cdp.items) |o| if (Table.failedBare(&o)) {
        bare += 1;
    };
    try testing.expectEqual(@as(usize, 0), bare);
    try testing.expectEqual(@as(usize, 60), h.table.tabOf(5).?.cdp.items.len);
}

// ── 재검증 3 차 뒤: 사건이 멎은 뒤 주기만으로 모든 기록이 끝나는가(혼돈 퍼즈) ──
// 시험이 증명하는 것: 사건의 차례가 어떻든(늦은 응답·두 번째 끝·끝 뒤의 캐시 알림·ExtraInfo 먼저·물 높이 늦음·새 문서·버려진 끝·답 없는 본문
// 호출) 사건이 멎으면 주기(`tickAt`)만으로 CEF 시작마다 끝이 꼭 하나 오고 표가 한가해진다. 왜 중요한가 — 끝이 오지 않으면 maru 는 그 본문을
// 영영 `pending` 으로 보인다(스모크 w9d-body 의 실패 꼴). 이 퍼즈가 찾은 것: 끝을 본 뒤에 온 응답이 그 요청을 맞추기에서 빼 판정이 제 자리를
// 못 찾았다(Debug 는 멈춤 — 범위 밖 읽기, ReleaseFast 는 정의되지 않은 동작).
fn chaosRun(seed: u64, stats: *[4]usize) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const rnd = prng.random();
    var h: H = .{ .sync = rnd.boolean() };
    defer h.deinit();
    const b: BrowserId = 5;
    _ = try h.table.start(gpa_t, b, 1);
    const urls = [_][]const u8{ "https://c.test/a", "https://c.test/b", "https://c.test/c.png" };
    const mimes = [_][]const u8{ "application/json", "text/javascript", "image/png", "text/html" };
    var now: i64 = 1_000_000;
    var next_req: u64 = 1;
    var rb: [16][12]u8 = undefined;
    var rids: [16][]const u8 = undefined;
    var nrid: usize = 0;
    const steps = rnd.intRangeAtMost(usize, 5, 60);
    var pend_fetch: std.ArrayList(i32) = .empty;
    defer pend_fetch.deinit(gpa_t);
    var seen_fetch: usize = 0;
    for (0..steps) |_| {
        now += rnd.intRangeAtMost(i64, 0, 40_000);
        const k = rnd.uintLessThan(u8, 16);
        const u = urls[rnd.uintLessThan(usize, urls.len)];
        switch (k) {
            0, 1 => { // CDP will_be_sent (new rid)
                if (nrid < rids.len) {
                    rids[nrid] = std.fmt.bufPrint(&rb[nrid], "r{d}", .{nrid}) catch unreachable;
                    try h.ev(b, .{ .will_be_sent = .{ .rid = rids[nrid], .url_hash = hashUrl8(u), .method_hash = hashMethod("GET"), .ts_us = now - rnd.intRangeAtMost(i64, 0, 3_000), .loader = rnd.uintLessThan(u64, 3) } }, now);
                    nrid += 1;
                }
            },
            2, 3 => { // CEF begin
                _ = try h.cand(b, next_req, u, now - rnd.intRangeAtMost(i64, -6_000, 3_000), .{ .sw = rnd.uintLessThan(u8, 8) == 0, .attr = if (rnd.uintLessThan(u8, 8) == 0) 2 else 1, .cover_pending = rnd.uintLessThan(u8, 10) == 0 });
                next_req += 1;
            },
            4 => if (next_req > 1) { // CEF end (random record)
                h.table.cefEndReceived(b, rnd.intRangeLessThan(u64, 1, next_req), now, rnd.uintLessThan(u8, 4) != 0, rnd.uintLessThan(u64, 3));
            },
            5, 6 => if (nrid > 0) { // response
                const r = rids[rnd.uintLessThan(usize, nrid)];
                const sw = rnd.uintLessThan(u8, 8) == 0;
                try h.ev(b, .{ .response = .{ .rid = r, .mime = mimes[rnd.uintLessThan(usize, mimes.len)], .from_sw = sw, .sw_source = if (sw and rnd.boolean()) "cache-storage" else "network", .charset = .other, .ts_us = now - rnd.intRangeAtMost(i64, 0, 2_000), .has_extra_info = rnd.boolean() } }, now);
                try h.ev(b, .{ .data = .{ .rid = r, .bytes = rnd.uintLessThan(u64, 3) * 7 } }, now);
            },
            7, 8 => if (nrid > 0) try h.ev(b, .{ .finished = .{ .rid = rids[rnd.uintLessThan(usize, nrid)] } }, now),
            9 => if (nrid > 0) try h.ev(b, .{ .failed = .{ .rid = rids[rnd.uintLessThan(usize, nrid)], .ts_us = now - rnd.intRangeAtMost(i64, 0, 1_000) } }, now),
            10 => if (nrid > 0) try h.ev(b, .{ .extra_info = .{ .rid = rids[rnd.uintLessThan(usize, nrid)], .credentialed = rnd.boolean() } }, now),
            11 => if (nrid > 0 and rnd.uintLessThan(u8, 3) == 0) try h.ev(b, .{ .from_cache = .{ .rid = rids[rnd.uintLessThan(usize, nrid)] } }, now),
            12 => h.table.documentStarted(b, now),
            13 => try h.flushed(now - rnd.intRangeAtMost(i64, 0, 20_000), now),
            14 => {
                try h.table.tickAt(gpa_t, now, now - rnd.intRangeAtMost(i64, 0, 20_000));
                try h.drain();
            },
            else => if (next_req > 1 and rnd.uintLessThan(u8, 4) == 0) h.table.cefLost(b, rnd.intRangeLessThan(u64, 1, next_req), now),
        }
        while (seen_fetch < h.fetches.items.len) : (seen_fetch += 1) try pend_fetch.append(gpa_t, h.fetches.items[seen_fetch].fetch.id);
        // 본문 호출의 답 — 몇은 끝내 오지 않는다(시한).
        while (pend_fetch.items.len > 0 and rnd.uintLessThan(u8, 3) == 0) {
            const id = pend_fetch.swapRemove(rnd.uintLessThan(usize, pend_fetch.items.len));
            if (rnd.uintLessThan(u8, 5) == 0) continue;
            if (h.table.takeInflight(id)) |f| {
                try h.noteEnd(f.request, .captured);
                try h.table.bodyDone(gpa_t, f, now);
                try h.drain();
            }
        }
    }
    // CEF 끝은 모두 온다(앱이 본 「done」 — 실패의 꼴 그대로).
    for (1..next_req) |r| h.table.cefEndReceived(b, r, now + 1_000, true, 10);
    // 사건이 멎었다 — 주기만 30 초.
    var t = now + 50_000;
    while (t < now + 30_000_000) : (t += 50_000) {
        try h.table.tickAt(gpa_t, t, t);
        try h.drain();
        while (seen_fetch < h.fetches.items.len) : (seen_fetch += 1) {}
    }
    stats[0] += 1;
    var stuck: usize = 0;
    for (1..next_req) |r| {
        const want = h.attempts.get(r) orelse continue;
        if (endCount(&h, r) != want) stuck += 1;
    }
    if (h.table.busy()) stats[2] += 1;
    if (stuck > 0) {
        stats[1] += 1;
        if (stats[3] == 0) stats[3] = seed;
    }
}

test "W9d② 재검증 3 차 뒤: 혼돈 퍼즈 — 사건이 멎으면 주기만으로 시작마다 끝 하나, 한가해짐(늦은 응답·두 번째 끝·끝 뒤 캐시 알림 포함)" {
    var stats: [4]usize = @splat(0);
    const n = 3000;
    for (0..n) |s| try chaosRun(0xc4a05000 + s, &stats);
    errdefer std.debug.print("[chaos] runs {d} stuck {d} busy {d} first seed {d}\n", .{ stats[0], stats[1], stats[2], stats[3] });
    try testing.expectEqual(@as(usize, n), stats[0]);
    try testing.expectEqual(@as(usize, 0), stats[1]);
    try testing.expectEqual(@as(usize, 0), stats[2]);
}

test "W9d② 재검증 3 차 뒤: 끝을 본 뒤의 늦은 응답·두 번째 끝·캐시 알림은 버린다 — 판정은 제 자리를 찾고 끝은 하나" {
    var h: H = .{ .sync = false }; // 끝을 본 때 물 높이는 아직 그 앞이다 — 판정이 늦은 사건들 뒤에 온다
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    const u = "https://l.test/late";
    try h.sent(5, "l.1", u, 1_000_000, 1_000_100);
    _ = try h.cand(5, 1, u, 1_000_300, .{});
    try h.finish(5, "l.1", 1_010_000); // 응답 없이 끝(제 기록은 아직 끝나지 않았다)
    // 늦은 응답 — 서비스 워커의 캐시 갈래로 알리면 전에는 그 요청이 맞추기에서 빠져 판정이 제 자리를 찾지 못했다(범위 밖 읽기).
    try h.ev(5, .{ .response = .{ .rid = "l.1", .mime = "application/json", .from_sw = true, .sw_source = "cache-storage", .charset = .other } }, 1_011_000);
    try h.ev(5, .{ .failed = .{ .rid = "l.1", .ts_us = 1_011_500 } }, 1_012_000);
    try h.ev(5, .{ .from_cache = .{ .rid = "l.1" } }, 1_012_500);
    h.table.cefEnd(5, 1, 1_013_000);
    var t: i64 = 1_020_000;
    // 본문 호출의 답은 오지 않는다 — 시한(`fetch_timeout_us`) 뒤 `unavailable`.
    while (t < 1_020_000 + fetch_timeout_us + 500_000) : (t += 50_000) {
        try h.table.tick(gpa_t, t);
        try h.drain();
    }
    // 짝은 제 기록이었다(본문을 받으러 갔다 — 늦은 사건에 흔들려 놓이지 않았다), 답이 없어 시한에 `unavailable` 하나.
    try testing.expectEqual(@as(usize, 1), h.fetches.items.len);
    try testing.expect(stateIs(&h, 1, .unavailable));
    try testing.expectEqual(@as(u32, 1), endCount(&h, 1));
    try testing.expect(!h.table.busy());
}

// ── 재검증 3 차: 검증자 v20h A 의 결정적 재현(P-a·P-b·P-c·P-d·P-f·P-g·P-h) ─────────────────────────────────────────────────────────────
// 시험이 증명하는 것: (WB-4) 앞에 남는 기록(놓인 요청의 기록·다른 사이트 iframe·미리 받기의 같은 주소 기록)과 기록이 늦은 뒤 요청이 겹쳐도 두
// 맞추기가 함께 밀려 남의 기록에 본문을 붙이지 않는다(P-h 둘·P-g 둘 — 전에는 셋에서 틀린 본문 하나씩), 같은 번호로 다시 시작한 CEF 시도가
// CDP 의 다시 보내기보다 먼저 와도 틀린 본문이 없다(P-f — 전에는 둘), (LB-1) 기록 하나의 끝이 버려진 같은 주소 무리(P-a)·보이는 규칙이 다른
// 같은 사이트 iframe(P-b)·새 문서 알림보다 먼저 나간 새 문서의 첫 요청(P-c — loader 로 가른다; loader 가 없으면 그 요청만 잃는다)에서 다른 요청이
// 본문을 잃지 않는다, (N-1) CDP 자리 상한의 묶음이 두 번 와도 다른 주소 요청은 모호하지 않다(P-d — 전에는 60 개 중 36).

var rv3_own: usize = 0;
var rv3_wrong: usize = 0;
var rv3_seen: usize = 0;
var rv3_rec: []const u64 = &.{};

fn rv3Rid(buf: []u8, i: usize) []const u8 {
    return std.fmt.bufPrint(buf, "q{d}", .{i}) catch unreachable;
}

fn rv3Sent(h: *H, rid: []const u8, url: []const u8, method: []const u8, ts: i64, loader: u64) !void {
    try h.ev(5, .{ .will_be_sent = .{ .rid = rid, .url_hash = hashUrl8(url), .method_hash = hashMethod(method), .ts_us = ts, .loader = loader } }, ts);
    try h.ev(5, .{ .extra_info = .{ .rid = rid, .credentialed = false } }, ts);
}

fn rv3Resp(h: *H, rid: []const u8, at: i64) !void {
    try h.ev(5, .{ .response = .{ .rid = rid, .mime = "application/json", .from_sw = false, .charset = .other, .ts_us = at } }, at);
    try h.ev(5, .{ .data = .{ .rid = rid, .bytes = 10 } }, at);
}

fn rv3Fin(h: *H, rid: []const u8, at: i64) !void {
    try h.ev(5, .{ .finished = .{ .rid = rid } }, at);
    try rv3Serve(h, at);
}

/// 보낸 본문 호출을 곧 답한다(요청 번호 `q<i>` 의 제 기록 `rv3_rec[i]` 인지 센다).
fn rv3Serve(h: *H, now: i64) !void {
    while (rv3_seen < h.fetches.items.len) : (rv3_seen += 1) {
        const a = h.fetches.items[rv3_seen].fetch;
        const idx = std.fmt.parseInt(usize, a.rid.slice()[1..], 10) catch unreachable;
        var req: u64 = 0;
        for (h.table.inflight.items) |f| if (f.id == a.id) {
            req = f.request;
        };
        if (idx < rv3_rec.len and rv3_rec[idx] == req) rv3_own += 1 else rv3_wrong += 1;
        const f = h.table.takeInflight(a.id) orelse continue;
        try h.noteEnd(f.request, .captured);
        try h.table.bodyDone(gpa_t, f, now);
        try h.drain();
    }
}

fn rv3Reset(recs: []const u64) void {
    rv3_own = 0;
    rv3_wrong = 0;
    rv3_seen = 0;
    rv3_rec = recs;
}

/// 제품의 주기 task(50 ms) — `from` 부터 `to` 까지.
fn rv3Ticks(h: *H, from: i64, to: i64) !void {
    var now = from;
    while (now <= to) : (now += 50_000) {
        try h.table.tickAt(gpa_t, now, now);
        try h.drain();
        try rv3Serve(h, now);
    }
}

test "W9d② 재검증 3 차 WB-4(P-h): 놓인 요청의 기록이나 다른 사이트 iframe 의 같은 주소 기록이 앞에 남고 뒤 요청의 기록이 늦어도(IO +6 ms) 남의 기록에 본문을 붙이지 않는다" {
    for ([_]u8{ 0, 1 }) |trigger| {
        var h: H = .{ .sync = false };
        defer h.deinit();
        _ = try h.table.start(gpa_t, 5, 1);
        const u = "https://p.test/items";
        var rb: [8]u8 = undefined;
        const t0: i64 = 10_000_000;
        const recs = [_]u64{ 1, 2, 3, 4 };
        rv3Reset(&recs);
        if (trigger == 1) {
            _ = try h.cand(5, 9, u, t0 + 1_000, .{ .attr = 3 }); // 다른 사이트 iframe(CDP 가 보지 못한다)
            h.table.cefEndReceived(5, 9, t0 + 4_000, true, 10);
        }
        const ts = [_]i64{ t0, t0 + 3_000, t0 + 7_000, t0 + 8_000 };
        const io = [_]i64{ t0 + 200, t0 + 3_200, t0 + 7_200, t0 + 14_000 };
        for (0..3) |k| {
            try rv3Sent(&h, rv3Rid(&rb, k), u, "GET", ts[k], 1);
            _ = try h.cand(5, recs[k], u, io[k], .{});
        }
        try rv3Sent(&h, rv3Rid(&rb, 3), u, "GET", ts[3], 1);
        if (trigger == 0) h.table.cefLost(5, 1, t0 + 5_000); // A 의 기록 끝이 버려졌다 — A 는 본문 없이
        h.table.cef_seen_us = t0 + 8_000;
        if (trigger == 1) h.table.cefEndReceived(5, 1, t0 + 5_500, true, 10);
        try rv3Resp(&h, rv3Rid(&rb, 0), t0 + 5_000);
        try rv3Fin(&h, rv3Rid(&rb, 0), t0 + 6_000);
        // C 는 +13 ms 에 끝난다 — D 의 기록(IO +14 ms)은 아직 오지 않았다.
        h.table.cefEndReceived(5, 3, t0 + 12_500, true, 10);
        h.table.cef_seen_us = t0 + 13_000;
        try rv3Resp(&h, rv3Rid(&rb, 2), t0 + 12_000);
        try rv3Fin(&h, rv3Rid(&rb, 2), t0 + 13_000);
        _ = try h.cand(5, 4, u, io[3], .{});
        h.table.cef_seen_us = t0 + 20_000;
        for ([_]usize{ 1, 3 }) |k| {
            const ki: i64 = @intCast(k);
            h.table.cefEndReceived(5, recs[k], t0 + 300_000 + ki * 10_000, true, 10);
            try rv3Resp(&h, rv3Rid(&rb, k), t0 + 299_000 + ki * 10_000);
            h.table.cef_seen_us = t0 + 301_000 + ki * 10_000;
            try rv3Fin(&h, rv3Rid(&rb, k), t0 + 301_000 + ki * 10_000);
        }
        try rv3Ticks(&h, t0 + 400_000, t0 + 5_000_000);
        errdefer std.debug.print("P-h trigger {d}: own {d} wrong {d}\n", .{ trigger, rv3_own, rv3_wrong });
        try testing.expectEqual(@as(usize, 0), rv3_wrong);
        // 기록 끝이 버려진 꼴: A 만 본문 없이 — B·C·D 는 제 본문(1c8e95230 은 C 에 B 의 기록을 붙였다).
        if (trigger == 0) try testing.expectEqual(@as(usize, 3), rv3_own);
        for (recs) |rq| try testing.expectEqual(@as(u32, 1), endCount(&h, rq));
    }
}

test "W9d② 재검증 3 차 WB-4(P-g): 미리 받기의 같은 주소 기록이 다시 받은 요청의 기록 바로 앞에 있고 뒤 요청의 기록이 50 ms 늦어도 그 기록에 본문을 붙이지 않는다(CEF 에 닿지 않은 abort 가 그 기록을 쥔 채)" {
    for ([_]bool{ false, true }) |end_in_box| {
        var h: H = .{ .sync = false };
        defer h.deinit();
        _ = try h.table.start(gpa_t, 5, 1);
        const u = "https://p.test/list";
        var rb: [8]u8 = undefined;
        const t0: i64 = 10_000_000;
        const recs0 = [_]u64{ 0, 2, 3 }; // j(abort) 는 기록이 없다, r → 2, k → 3
        rv3Reset(&recs0);
        try h.ev(5, .{ .will_be_sent = .{ .rid = "pf", .url_hash = hashUrl8(u), .method_hash = hashMethod("GET"), .ts_us = t0 + 700, .prefetch = true } }, t0 + 700);
        try rv3Sent(&h, rv3Rid(&rb, 0), u, "GET", t0, 1);
        _ = try h.cand(5, 1, u, t0 + 800, .{}); // 미리 받기의 기록 W
        try rv3Sent(&h, rv3Rid(&rb, 1), u, "GET", t0 + 900, 1);
        _ = try h.cand(5, 2, u, t0 + 1_000, .{});
        try rv3Sent(&h, rv3Rid(&rb, 2), u, "GET", t0 + 2_000, 1);
        h.table.cef_seen_us = t0 + 2_000;
        try h.ev(5, .{ .failed = .{ .rid = rv3Rid(&rb, 0), .ts_us = t0 + 500 } }, t0 + 3_000);
        h.table.cefEndReceived(5, 1, t0 + 20_000, true, 10);
        h.table.cef_seen_us = t0 + 30_000;
        try rv3Resp(&h, rv3Rid(&rb, 1), t0 + 40_000);
        if (!end_in_box) h.table.cefEndReceived(5, 2, t0 + 46_000, true, 10);
        h.table.cef_seen_us = t0 + 41_000;
        try rv3Fin(&h, rv3Rid(&rb, 1), t0 + 50_000);
        if (end_in_box) h.table.cefEndReceived(5, 2, t0 + 55_000, true, 10);
        _ = try h.cand(5, 3, u, t0 + 52_000, .{}); // k 의 기록 — CDP 시작보다 50 ms 늦다
        h.table.cef_seen_us = t0 + 60_000;
        try h.table.tickAt(gpa_t, t0 + 60_000, t0 + 60_000);
        try h.drain();
        try rv3Serve(&h, t0 + 60_000);
        h.table.cefEndReceived(5, 3, t0 + 99_000, true, 10);
        try rv3Resp(&h, rv3Rid(&rb, 2), t0 + 95_000);
        h.table.cef_seen_us = t0 + 100_000;
        try rv3Fin(&h, rv3Rid(&rb, 2), t0 + 100_000);
        try rv3Ticks(&h, t0 + 150_000, t0 + 5_000_000);
        errdefer std.debug.print("P-g end_in_box {}: own {d} wrong {d}\n", .{ end_in_box, rv3_own, rv3_wrong });
        try testing.expectEqual(@as(usize, 0), rv3_wrong);
        for ([_]u64{ 1, 2, 3 }) |rq| try testing.expectEqual(@as(u32, 1), endCount(&h, rq));
    }
}

test "W9d② 재검증 3 차(P-f — N-2): 같은 번호로 다시 시작한 CEF 시도가 CDP 의 같은 주소 다시 보내기보다 먼저 와도 남의 기록에 본문을 붙이지 않는다(실측 차례는 거꾸로 — 본문은 잃는다)" {
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    const u = "https://p.test/doc";
    var rb: [8]u8 = undefined;
    const t0: i64 = 10_000_000;
    const recs = [_]u64{ 1, 2, 3 };
    rv3Reset(&recs);
    try rv3Sent(&h, rv3Rid(&rb, 0), u, "GET", t0, 1);
    _ = try h.cand(5, 1, u, t0 + 100, .{});
    try rv3Sent(&h, rv3Rid(&rb, 1), u, "GET", t0 + 1_000, 1);
    _ = try h.cand(5, 2, u, t0 + 1_100, .{});
    try rv3Sent(&h, rv3Rid(&rb, 2), u, "GET", t0 + 20_000, 1);
    _ = try h.cand(5, 3, u, t0 + 20_100, .{});
    _ = try h.cand(5, 1, u, t0 + 30_000, .{}); // A 의 다시 시작(같은 번호)
    h.table.cefEndReceived(5, 2, t0 + 49_000, true, 10);
    try rv3Resp(&h, rv3Rid(&rb, 1), t0 + 45_000);
    try rv3Fin(&h, rv3Rid(&rb, 1), t0 + 50_000);
    try h.ev(5, .{ .will_be_sent = .{ .rid = rv3Rid(&rb, 0), .url_hash = hashUrl8(u), .method_hash = hashMethod("GET"), .ts_us = t0 + 55_000, .redirect = true } }, t0 + 55_000);
    h.table.cefEndReceived(5, 3, t0 + 79_000, true, 10);
    try rv3Resp(&h, rv3Rid(&rb, 2), t0 + 75_000);
    try rv3Fin(&h, rv3Rid(&rb, 2), t0 + 80_000);
    h.table.cefEndReceived(5, 1, t0 + 99_000, true, 10);
    try rv3Resp(&h, rv3Rid(&rb, 0), t0 + 95_000);
    try rv3Fin(&h, rv3Rid(&rb, 0), t0 + 100_000);
    try rv3Ticks(&h, t0 + 150_000, t0 + 5_000_000);
    try testing.expectEqual(@as(usize, 0), rv3_wrong);
}

test "W9d② 재검증 3 차 LB-1(P-a·P-b): 같은 주소 무리에서 기록 하나의 끝이 버려지거나 보이는 규칙이 다른 같은 사이트 iframe 이 끼어도 그 하나만 본문을 잃는다(1c8e95230 은 무리 전체·주 프레임 둘)" {
    {
        // P-a: GraphQL 무리 여섯(0.5 ms 안), 셋째 기록의 끝이 버려졌다 — 셋째만 ambiguous.
        var h: H = .{};
        defer h.deinit();
        _ = try h.table.start(gpa_t, 5, 1);
        const u = "https://p.test/graphql";
        var rb: [8]u8 = undefined;
        const t0: i64 = 10_000_000;
        const rec = [_]u64{ 1, 2, 3, 4, 5, 6 };
        rv3Reset(&rec);
        for (0..6) |k| {
            const ts = t0 + @as(i64, @intCast(k)) * 100;
            try rv3Sent(&h, rv3Rid(&rb, k), u, "POST", ts, 1);
            _ = try h.cand(5, rec[k], u, ts + 50, .{ .method = "POST" });
        }
        h.table.cefLost(5, rec[2], t0 + 100_000);
        var now: i64 = t0 + 200_000;
        for ([_]usize{ 2, 0, 5, 1, 4, 3 }) |k| {
            if (k != 2) h.table.cefEndReceived(5, rec[k], now - 1_000, true, 10);
            try rv3Resp(&h, rv3Rid(&rb, k), now - 2_000);
            try rv3Fin(&h, rv3Rid(&rb, k), now);
            now += 100_000;
        }
        try rv3Ticks(&h, now, now + 4_000_000);
        try testing.expectEqual(@as(usize, 0), rv3_wrong);
        try testing.expectEqual(@as(usize, 5), rv3_own);
        try testing.expect(stateIs(&h, 3, .ambiguous));
    }
    {
        // P-b: 주 프레임 A(느림)·B(느림), 같은 사이트 iframe C(보이는 규칙이 다르다, 빠름), 주 프레임 D — A·B·D 는 제 본문.
        var h: H = .{};
        defer h.deinit();
        _ = try h.table.start(gpa_t, 5, 1);
        const u = "https://p.test/config.json";
        var rb: [8]u8 = undefined;
        const t0: i64 = 10_000_000;
        const rec = [_]u64{ 1, 2, 3, 4 };
        rv3Reset(&rec);
        const ts = [_]i64{ t0, t0 + 10_000, t0 + 70_000, t0 + 100_000 };
        for (0..4) |k| {
            try rv3Sent(&h, rv3Rid(&rb, k), u, "GET", ts[k], 1);
            _ = try h.cand(5, rec[k], u, ts[k] + 1_000, .{ .attr = if (k == 2) 2 else 1 });
        }
        const fin = [_]i64{ t0 + 900_000, t0 + 1_000_000, t0 + 120_000, t0 + 400_000 };
        var tk: i64 = t0 + 50_000;
        for ([_]usize{ 2, 3, 0, 1 }) |k| {
            while (tk < fin[k] - 6_000) : (tk += 50_000) try rv3Ticks(&h, tk, tk);
            h.table.cefEndReceived(5, rec[k], fin[k] - 1_000, true, 10);
            try rv3Resp(&h, rv3Rid(&rb, k), fin[k] - 5_000);
            try rv3Fin(&h, rv3Rid(&rb, k), fin[k]);
        }
        try rv3Ticks(&h, t0 + 1_050_000, t0 + 5_000_000);
        try testing.expectEqual(@as(usize, 0), rv3_wrong);
        // 재검증 3 차 뒤 WB-5: C 는 A·B(응답 전)의 기록이 정해질 때까지 기다린다 — 그 사이 A·B 가 제 기록으로 정해져 보이는 규칙이 다른 기록이
        // 창에 남지 않으니 C 도 제 본문(전에는 C 만 `ambiguous`).
        try testing.expectEqual(@as(usize, 4), rv3_own);
    }
}

test "W9d② 재검증 3 차 LB-1(P-c): 새 문서의 첫 요청이 새 문서 알림보다 2 ms 먼저 나가도 같은 loader 로 알림 뒤에 나간 같은 주소 요청은 제 본문 — loader 를 모르면 그 첫 요청만 잃는다" {
    for ([_]u64{ 7, 0 }) |loader| {
        var h: H = .{};
        defer h.deinit();
        _ = try h.table.start(gpa_t, 5, 1);
        const u = "https://p.test/api/me";
        var rb: [8]u8 = undefined;
        const nav: i64 = 20_000_000;
        const rec = [_]u64{ 1, 2, 3 };
        rv3Reset(&rec);
        const ts = [_]i64{ nav - 2_000, nav + 40_000, nav + 80_000 };
        try rv3Sent(&h, rv3Rid(&rb, 0), u, "GET", ts[0], loader);
        _ = try h.cand(5, rec[0], u, ts[0] + 500, .{});
        h.table.documentStarted(5, nav);
        for (1..3) |k| {
            try rv3Sent(&h, rv3Rid(&rb, k), u, "GET", ts[k], loader);
            _ = try h.cand(5, rec[k], u, ts[k] + 500, .{});
        }
        const fin = [_]i64{ nav + 900_000, nav + 150_000, nav + 200_000 };
        for ([_]usize{ 1, 2, 0 }) |k| {
            h.table.cefEndReceived(5, rec[k], fin[k] - 1_000, true, 10);
            try rv3Resp(&h, rv3Rid(&rb, k), fin[k] - 5_000);
            try rv3Fin(&h, rv3Rid(&rb, k), fin[k]);
        }
        try rv3Ticks(&h, nav + 950_000, nav + 5_000_000);
        errdefer std.debug.print("P-c loader {d}: own {d} wrong {d}\n", .{ loader, rv3_own, rv3_wrong });
        try testing.expectEqual(@as(usize, 0), rv3_wrong);
        // loader 가 있으면 셋 모두(1c8e95230 은 1/3), 없으면 앞 문서의 것으로 보이는 첫 요청만 빠진다(2/3).
        try testing.expectEqual(@as(usize, if (loader != 0) 3 else 2), rv3_own);
    }
}

test "W9d② 재검증 3 차 N-1(P-d): CDP 자리 상한의 묶음 놓기가 두 번 와도(다른 주소 256 개씩) 그 뒤의 다른 주소 요청은 모호하지 않다 — 지난 표지는 지우고 자리는 CDP 자리 수만큼" {
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    var rb: [16]u8 = undefined;
    var ub: [48]u8 = undefined;
    var n: usize = 0;
    var rid_id: usize = 0;
    var rec_id: u64 = 1;
    var now: i64 = 10_000_000;
    for (0..2) |round| {
        for (0..max_cdp + cdp_evict_batch) |k| {
            const u = std.fmt.bufPrint(&ub, "https://p.test/hung/{d}/{d}", .{ round, k }) catch unreachable;
            const id = std.fmt.bufPrint(&rb, "h{d}", .{rid_id}) catch unreachable;
            rid_id += 1;
            try h.ev(5, .{ .will_be_sent = .{ .rid = id, .url_hash = hashUrl8(u), .method_hash = hashMethod("GET"), .ts_us = now } }, now);
            _ = try h.cand(5, rec_id, u, now + 1, .{});
            rec_id += 1;
            now += 50;
        }
        for (0..60) |k| {
            now += 50_000;
            const u = std.fmt.bufPrint(&ub, "https://p.test/ok/{d}/{d}", .{ round, k }) catch unreachable;
            const id = std.fmt.bufPrint(&rb, "o{d}", .{n}) catch unreachable;
            n += 1;
            try h.ev(5, .{ .will_be_sent = .{ .rid = id, .url_hash = hashUrl8(u), .method_hash = hashMethod("GET"), .ts_us = now } }, now);
            _ = try h.cand(5, rec_id, u, now + 1, .{});
            h.table.cefEndReceived(5, rec_id, now + 2_000, true, 10);
            try h.ev(5, .{ .response = .{ .rid = id, .mime = "application/json", .from_sw = false, .charset = .other, .ts_us = now + 1_000 } }, now + 1_000);
            try h.ev(5, .{ .finished = .{ .rid = id } }, now + 3_000);
            errdefer std.debug.print("P-d round {d} k {d}: {?}\n", .{ round, k, h.ended.get(rec_id) });
            try testing.expect(h.ended.get(rec_id) == null); // 받으러 갔다(모호하지 않다)
            rec_id += 1;
        }
        // 두 묶음 모두 주소마다의 표지에 든다(탭 전체로 접지 않는다).
        try testing.expectEqual(@as(i64, 0), h.table.tabOf(5).?.cdp_drop_until);
        now += 10_000_000;
        try h.table.tickAt(gpa_t, now, now);
        try h.drain();
    }
}

test "W9d② 재검증 3 차 WB-4: 미리 받기의 같은 주소 기록(보이는 규칙이 같다)이 앞 요청의 기록 앞에 있고 뒤 요청의 기록이 아직이면 — 두 맞추기는 그 기록을 주지만 뒤 요청의 기록이 올 때까지 기다리고, 오면 갈려 본문 없이" {
    var h: H = .{ .sync = false };
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    const u = "https://p.test/feed";
    const t0: i64 = 10_000_000;
    // 미리 받기(CDP 가 표시해 맞추기에서 뺀다)의 CEF 기록 1 — C 의 기록 2 앞, C 의 창 안.
    try h.ev(5, .{ .will_be_sent = .{ .rid = "pf", .url_hash = hashUrl8(u), .method_hash = hashMethod("GET"), .ts_us = t0 - 100, .prefetch = true } }, t0 - 100);
    _ = try h.cand(5, 1, u, t0, .{});
    try h.sent(5, "C", u, t0 + 200, t0 + 200);
    _ = try h.cand(5, 2, u, t0 + 500, .{});
    try h.sent(5, "D", u, t0 + 4_000, t0 + 4_000); // D 의 기록(3)은 IO +20 ms — 아직 오지 않았다
    h.table.cefEnd(5, 1, t0 + 6_000);
    h.table.cef_seen_us = t0 + 10_000;
    try h.respond(5, "C", "application/json", 9, t0 + 10_000);
    h.table.cefEnd(5, 2, t0 + 10_500);
    h.table.cef_seen_us = t0 + 11_000;
    try h.finish(5, "C", t0 + 11_000);
    // 두 맞추기는 C → 1(미리 받기의 기록)을 준다 — D 가 제 기록을 가졌는지 아직 모르니 정하지 않는다.
    try testing.expectEqual(@as(usize, 0), h.fetches.items.len);
    try testing.expect(h.ended.get(1) == null and h.ended.get(2) == null);
    _ = try h.cand(5, 3, u, t0 + 20_000, .{});
    try h.flushed(t0 + 20_100, t0 + 20_100);
    try h.table.tick(gpa_t, t0 + 100_000);
    try h.drain();
    errdefer std.debug.print("1 {?} 2 {?} fetches {d}\n", .{ h.ended.get(1), h.ended.get(2), h.fetches.items.len });
    // 뒤 기록이 와 두 맞추기가 갈렸다 — C 는 본문 없이(1·2 ambiguous), 1 에 붙지 않는다.
    try testing.expectEqual(@as(usize, 0), h.fetches.items.len);
    try testing.expect(stateIs(&h, 1, .ambiguous) and stateIs(&h, 2, .ambiguous));
}

test "W9d② 재검증 3 차 퍼즈: 큰 퍼즈가 찾은 씨앗(IO 50 ms) — CEF 에 닿지 않을 앞 요청이 뒤 기록을 쥔 꼴, 막 실패로 끝난 기록을 다른 abort 가 먼저 가져간 꼴 — 틀린 본문 0" {
    // 0x7a00000 + s × 7919 + 꼴: spa-json s = 313·1250, localhost-bursts s = 77·504.
    for ([_][2]u64{ .{ 0, 313 }, .{ 0, 1250 }, .{ 4, 77 }, .{ 4, 504 } }) |ps| {
        var st: PfStats = .{};
        try pfScenario(@intCast(ps[0]), 0x7a00000 + ps[1] * 7919 + ps[0], 50_000, &st);
        errdefer std.debug.print("profile {d} seed {d}: wrong {d}\n", .{ ps[0], ps[1], st.wrong });
        try testing.expectEqual(@as(usize, 1), st.scenarios);
        try testing.expectEqual(@as(usize, 0), st.wrong);
        try testing.expectEqual(@as(usize, 0), st.missing_end);
    }
}

// ── W9d② 재검증 4 차 뒤 — 검증자 B 15·16 회차(스크립트·스타일시트의 글 풀기, JS·JSON MIME, 글로 넘친 상한) ─────────────────────────────────

test "W9d② 재검증 4 차 뒤 B15-1·B15-2: 헤더 charset 없는 스크립트·스타일시트 — 문서 인코딩으로 푼 같은 길이 글은 표시, UTF-8 근거(같은 길이 + 세 바이트 글자)가 있으면 그대로, 같은 MIME 를 fetch 로 받으면 전처럼" {
    const gk_text = "var s=\"\u{3b1}\u{3b2}\u{3b3}\u{3b4}\";"; // EUC-KR A5 E1… 를 문서 인코딩으로 푼 글 — 받은 바이트와 같은 길이
    const gk_raw_len: u64 = ("var s=\"".len + 8 + 2);
    const kr_text = "var s=\"\u{ac00}\u{b098}\";"; // EUC-KR 「가나」 4 바이트 → 6 바이트
    const u8_js = "var s=\"\u{d55c}\u{2192} caf\u{e9}\";"; // 맞는 UTF-8 — 세 바이트 글자가 있다
    const u8_lat = "var s=\"caf\u{e9} na\u{ef}ve\";"; // 맞는 UTF-8 — 두 바이트 글자뿐(대가: 표시)
    const css_u8 = "/*caf\u{e9} \u{2713}*/"; // 실측 vj-css-u8
    const css_gk = "/*\u{3b1}\u{3b2}\u{3b3}\u{3b4}*/";
    const Out = enum { exact, redecoded, marked };
    const R = struct { name: []const u8, kind: ResKind, mime: []const u8, ct: []const u8 = "", text: []const u8, raw: ?u64 = null, out: Out, want: ?[]const u8 = null };
    const rows = [_]R{
        // B15-1: 문서 인코딩(EUC-KR)·<script charset=euc-kr> 로 푼 그리스 글 — 길이가 받은 바이트와 같아도 표시
        .{ .name = "js docgk", .kind = .script, .mime = "text/javascript", .text = gk_text, .raw = gk_raw_len, .out = .marked },
        .{ .name = "js docgk application/javascript", .kind = .script, .mime = "application/javascript", .text = gk_text, .raw = gk_raw_len, .out = .marked },
        .{ .name = "js docgk text/plain", .kind = .script, .mime = "text/plain", .text = gk_text, .raw = gk_raw_len, .out = .marked },
        .{ .name = "js kr (longer)", .kind = .script, .mime = "text/javascript", .text = kr_text, .raw = kr_text.len - 2, .out = .marked },
        .{ .name = "js u8 unknown size", .kind = .script, .mime = "text/javascript", .text = u8_js, .raw = 0, .out = .marked },
        .{ .name = "js u8 lat (cost)", .kind = .script, .mime = "text/javascript", .text = u8_lat, .out = .marked },
        .{ .name = "js only fffd", .kind = .script, .mime = "text/javascript", .text = "x=\"\u{fffd}\u{e9}\"", .out = .marked },
        .{ .name = "js supplementary only", .kind = .script, .mime = "text/javascript", .text = "x=\"\u{1f600}\"", .out = .marked },
        .{ .name = "js ascii size differs", .kind = .script, .mime = "text/javascript", .text = "var a=1;", .raw = 18, .out = .marked },
        // 맞는 UTF-8(근거 있음) — 그대로, 표시 없음(MIME 가 무엇이든 — 종류가 정한다)
        .{ .name = "js u8", .kind = .script, .mime = "text/javascript", .text = u8_js, .out = .exact },
        .{ .name = "js u8 text/plain", .kind = .script, .mime = "text/plain", .text = u8_js, .out = .exact },
        .{ .name = "js ascii", .kind = .script, .mime = "text/javascript", .text = "var a=1;", .out = .exact },
        // 헤더 charset 이 있으면 종류와 상관없이 전의 규칙(Chromium 도 헤더를 앞세운다)
        .{ .name = "js hdr euc-kr", .kind = .script, .mime = "text/javascript", .ct = "text/javascript; charset=euc-kr", .text = gk_text, .raw = gk_raw_len, .out = .exact, .want = gk_text },
        .{ .name = "js hdr utf-8", .kind = .script, .mime = "text/javascript", .ct = "text/javascript; charset=utf-8", .text = u8_lat, .out = .exact },
        // B15-2: 스타일시트 — windows-1252 로 되돌리지 않는다(맞는 UTF-8 CSS 의 거짓 표시), 근거가 없으면 표시(문서 인코딩의 그리스 글)
        .{ .name = "css u8", .kind = .stylesheet, .mime = "text/css", .text = css_u8, .out = .exact },
        .{ .name = "css hangul font", .kind = .stylesheet, .mime = "text/css", .text = "a{font-family:\"\u{b9d1}\u{c740} \u{ace0}\u{b515}\"}", .out = .exact },
        .{ .name = "css docgk", .kind = .stylesheet, .mime = "text/css", .text = css_gk, .out = .marked },
        .{ .name = "css @charset euc-kr", .kind = .stylesheet, .mime = "text/css", .text = "@charset \"euc-kr\";/*\u{2192}*/", .out = .marked },
        .{ .name = "css @charset unclosed", .kind = .stylesheet, .mime = "text/css", .text = "@charset \"utf-8;/*\u{2192}*/", .out = .marked },
        .{ .name = "css @charset utf-8", .kind = .stylesheet, .mime = "text/css", .text = "@charset \"UTF-8\";/*\u{2192}*/", .out = .exact },
        .{ .name = "css w1252 moji", .kind = .stylesheet, .mime = "text/css", .text = "/*caf\u{c3}\u{a9}*/", .raw = 9, .out = .marked },
        // 대조: 같은 CSS 를 fetch 로 받았다(종류 other) — 전처럼 windows-1252 로 되돌린다(dg1-csscs)
        .{ .name = "fetch css w1252", .kind = .other, .mime = "text/css", .text = "/*caf\u{c3}\u{a9}*/", .raw = 9, .out = .redecoded, .want = "/*caf\u{e9}*/" },
        .{ .name = "fetch css u8 (marked as before)", .kind = .other, .mime = "text/css", .text = css_u8, .out = .marked },
    };
    var bad: usize = 0;
    for (rows) |r| {
        const json = try std.json.Stringify.valueAlloc(gpa_t, .{ .body = r.text, .base64Encoded = false }, .{});
        defer gpa_t.free(json);
        const raw = r.raw orelse r.text.len;
        const d = try decodeResult(gpa_t, true, json, r.mime, charsetOf(r.ct), raw, r.kind);
        defer gpa_t.free(d.bytes);
        const want = r.want orelse r.text;
        const fine = d.state == .captured and switch (r.out) {
            .exact => !d.flags.redecoded and !d.flags.chromium_decoded and std.mem.eql(u8, d.bytes, want),
            .redecoded => d.flags.redecoded and !d.flags.chromium_decoded and std.mem.eql(u8, d.bytes, want),
            .marked => d.flags.chromium_decoded and !d.flags.redecoded,
        };
        if (!fine) {
            std.debug.print("B15 [{s}]: {s} redecoded={} chromium_decoded={} len {d} (raw {d}), want {s}\n", .{ r.name, @tagName(d.state), d.flags.redecoded, d.flags.chromium_decoded, d.bytes.len, raw, @tagName(r.out) });
            bad += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);
}

test "W9d② 재검증 4 차 뒤 B15-2: Blink 의 JavaScript·JSON MIME(charset 없음)는 windows-1252 로 되돌리지 않는다 — 맞는 UTF-8 은 그대로, windows-1252 로 푼 글이 오더라도 길이로 표시(틀린 글이 표시 없이 나가지 않는다)" {
    const u8_text = "x=\"caf\u{e9} \u{2713}\"";
    const moji = "x=\"caf\u{c3}\u{a9}\""; // 「café」 의 UTF-8 을 windows-1252 로 읽은 글
    for ([_][]const u8{ "text/javascript", "text/ecmascript", "text/javascript1.0", "text/javascript1.5", "text/jscript", "text/livescript", "text/x-ecmascript", "text/x-javascript", "TEXT/X-JavaScript", "text/json", "text/vnd.maru+json", "text/x-javascript; charset=" }) |mime| {
        errdefer std.debug.print("B15-2 mime {s}\n", .{mime});
        try testing.expect(!redecodeCandidate(mime));
        const j1 = try std.json.Stringify.valueAlloc(gpa_t, .{ .body = u8_text, .base64Encoded = false }, .{});
        defer gpa_t.free(j1);
        const d = try decodeResult(gpa_t, true, j1, mime, charsetOf(mime), u8_text.len, .other);
        defer gpa_t.free(d.bytes);
        try testing.expect(d.state == .captured and !d.flags.chromium_decoded and !d.flags.redecoded);
        try testing.expectEqualStrings(u8_text, d.bytes);
        // 지킴: Chromium 이 이 MIME 를 windows-1252 로 풀었다고 해도 길이가 달라 표시된다.
        const j2 = try std.json.Stringify.valueAlloc(gpa_t, .{ .body = moji, .base64Encoded = false }, .{});
        defer gpa_t.free(j2);
        const m = try decodeResult(gpa_t, true, j2, mime, charsetOf(mime), moji.len - 2, .other);
        defer gpa_t.free(m.bytes);
        try testing.expect(m.state == .captured and m.flags.chromium_decoded and !m.flags.redecoded);
    }
    // 대조: 다른 글 MIME 는 전처럼 되돌린다.
    for ([_][]const u8{ "text/plain", "text/css", "text/csv", "text/x-json-not", "text/javascript2" }) |mime| {
        errdefer std.debug.print("B15-2 control {s}\n", .{mime});
        try testing.expect(redecodeCandidate(mime));
        const j = try std.json.Stringify.valueAlloc(gpa_t, .{ .body = moji, .base64Encoded = false }, .{});
        defer gpa_t.free(j);
        const d = try decodeResult(gpa_t, true, j, mime, .none, moji.len - 2, .other);
        defer gpa_t.free(d.bytes);
        try testing.expect(d.state == .captured and d.flags.redecoded);
        try testing.expectEqualStrings("x=\"caf\u{e9}\"", d.bytes);
    }
}

test "W9d② 재검증 4 차 뒤 B15: 자원 종류는 requestWillBeSent·responseReceived 의 type 에서 골라 기다림·보낸 호출까지 간다(응답의 것이 앞선다)" {
    const P = struct {
        fn kindOf(method: []const u8, json: []const u8) !ResKind {
            const p = try std.json.parseFromSlice(std.json.Value, gpa_t, json, .{});
            defer p.deinit();
            const e = parseEvent(method, p.value) orelse return error.NoEvent;
            return switch (e) {
                .will_be_sent => |v| v.res_kind,
                .response => |v| v.res_kind,
                else => error.NoEvent,
            };
        }
    };
    try testing.expectEqual(ResKind.script, try P.kindOf("Network.requestWillBeSent", "{\"requestId\":\"1\",\"timestamp\":1,\"type\":\"Script\",\"request\":{\"url\":\"u\",\"method\":\"GET\"}}"));
    try testing.expectEqual(ResKind.stylesheet, try P.kindOf("Network.requestWillBeSent", "{\"requestId\":\"1\",\"timestamp\":1,\"type\":\"Stylesheet\",\"request\":{\"url\":\"u\",\"method\":\"GET\"}}"));
    try testing.expectEqual(ResKind.other, try P.kindOf("Network.requestWillBeSent", "{\"requestId\":\"1\",\"timestamp\":1,\"type\":\"Fetch\",\"request\":{\"url\":\"u\",\"method\":\"GET\"}}"));
    try testing.expectEqual(ResKind.other, try P.kindOf("Network.requestWillBeSent", "{\"requestId\":\"1\",\"timestamp\":1,\"type\":\"script\",\"request\":{\"url\":\"u\",\"method\":\"GET\"}}"));
    try testing.expectEqual(ResKind.stylesheet, try P.kindOf("Network.responseReceived", "{\"requestId\":\"1\",\"type\":\"Stylesheet\",\"response\":{\"mimeType\":\"text/css\",\"headers\":{}}}"));
    try testing.expectEqual(ResKind.other, try P.kindOf("Network.responseReceived", "{\"requestId\":\"1\",\"response\":{\"mimeType\":\"text/css\",\"headers\":{}}}"));

    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    const t: i64 = 10_000_000;
    const Row = struct { url: []const u8, rid: []const u8, req: u64, sent: ResKind, resp: ResKind, want: ResKind };
    const rows = [_]Row{
        .{ .url = "https://a.test/s.js", .rid = "k.1", .req = 1, .sent = .script, .resp = .other, .want = .script },
        .{ .url = "https://a.test/c.css", .rid = "k.2", .req = 2, .sent = .stylesheet, .resp = .stylesheet, .want = .stylesheet },
        .{ .url = "https://a.test/d.json", .rid = "k.3", .req = 3, .sent = .other, .resp = .other, .want = .other },
        .{ .url = "https://a.test/e.js", .rid = "k.4", .req = 4, .sent = .other, .resp = .script, .want = .script },
    };
    for (rows, 0..) |r, i| {
        const at = t + @as(i64, @intCast(i)) * 1000;
        _ = try h.cand(5, r.req, r.url, at, .{});
        try h.ev(5, .{ .will_be_sent = .{ .rid = r.rid, .url_hash = hashUrl8(r.url), .method_hash = hashMethod("GET"), .ts_us = at - 10, .res_kind = r.sent } }, at);
        try h.ev(5, .{ .extra_info = .{ .rid = r.rid, .credentialed = false } }, at);
        try h.ev(5, .{ .response = .{ .rid = r.rid, .mime = "text/plain", .from_sw = false, .charset = .none, .res_kind = r.resp } }, at);
        try h.ev(5, .{ .data = .{ .rid = r.rid, .bytes = 10 } }, at);
        try h.finish(5, r.rid, at);
        // 하나씩 보내고 돌려받는다(탭의 보낸 호출 자리는 둘).
        const act = h.fetches.items[h.fetches.items.len - 1];
        const f = h.table.takeInflight(act.fetch.id).?;
        errdefer std.debug.print("B15 kind row {d}: got {s}\n", .{ i, @tagName(f.res_kind) });
        try testing.expectEqual(r.req, f.request);
        try testing.expectEqual(r.want, f.res_kind);
        try h.table.bodyDone(gpa_t, f, at + 10);
        try h.drain();
    }
    try testing.expectEqual(rows.len, h.fetches.items.len);
}

test "W9d② 재검증 4 차 뒤 B16-1: 상한은 싣는 글 — 받은 바이트가 1 MiB 아래여도 Chromium 이 푼 글이 넘치면 over_cap 이고 그 크기는 글의 것, 꼭 1 MiB 인 글은 잡는다" {
    // windows-1252 글 1,000,000 바이트(é 10 %) — 검증자의 vs-w1252-1000k: 글은 1,100,000 바이트.
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa_t);
    try text.appendNTimes(gpa_t, 'a', 900_000);
    for (0..100_000) |_| try text.appendSlice(gpa_t, "\u{e9}");
    for ([_]struct { body: []const u8, raw: u64, want: State, size: u64 }{
        .{ .body = text.items, .raw = 1_000_000, .want = .over_cap, .size = 1_100_000 },
        // 글이 꼭 1 MiB 면 잡는다(표시 — 길이가 받은 수와 다르다)
        .{ .body = text.items[text.items.len - msg.max_net_body_bytes ..], .raw = msg.max_net_body_bytes - 100_000, .want = .captured, .size = msg.max_net_body_bytes },
    }) |c| {
        const json = try std.json.Stringify.valueAlloc(gpa_t, .{ .body = c.body, .base64Encoded = false }, .{});
        defer gpa_t.free(json);
        const d = try decodeResult(gpa_t, true, json, "text/plain", .none, c.raw, .other);
        defer gpa_t.free(d.bytes);
        errdefer std.debug.print("B16-1: {s} over_bytes {d} len {d}\n", .{ @tagName(d.state), d.over_bytes, d.bytes.len });
        try testing.expectEqual(c.want, d.state);
        if (c.want == .over_cap) {
            try testing.expectEqual(c.size, d.over_bytes);
            try testing.expect(d.over_bytes > c.raw);
        } else try testing.expectEqual(c.size, @as(u64, d.bytes.len));
    }
}

// ── 재검증 4 차 뒤: 검증자 v20j A 의 재현(시험만 — 제품 코드는 그대로) ─────────────────────────────────────────────────────────────

/// v20j A R6-1: 서비스 워커가 같은 주소의 두 페이지 요청(P1 → P2 차례)을 거꾸로 넘긴다 — P1 을 `sw_delay` 늦게 fetch(e.request) 하고 P2 는 곧.
/// 서버가 느려(`server_ms`) 두 워커 기록(R2 먼저, R1 뒤)이 모두 두 응답보다 앞에 시작한다. `p2_first` 면 P2 가 먼저 응답·끝난다.
/// 돌려주는 것: P1·P2 가 받으러 간 CEF 기록 번호(0 = 본문 없음). 제 기록은 P1 → 1, P2 → 2.
fn v20jSwReorder(sw_delay: i64, server: i64, p2_first: bool, out: *[2]u64) !void {
    var h: H = .{ .sync = false };
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    const u = "https://sw.test/x";
    const t0: i64 = 10_000_000;
    const sw_resp = struct {
        fn f(hh: *H, rid: []const u8, ts: i64, now: i64) !void {
            try hh.ev(5, .{ .response = .{ .rid = rid, .mime = "application/json", .from_sw = true, .sw_source = "network", .charset = .other, .ts_us = ts } }, now);
            try hh.ev(5, .{ .data = .{ .rid = rid, .bytes = 9 } }, now);
        }
    }.f;
    try h.ev(5, .{ .will_be_sent = .{ .rid = "P1", .url_hash = hashUrl8(u), .method_hash = hashMethod("GET"), .ts_us = t0 } }, t0 + 200);
    try h.ev(5, .{ .will_be_sent = .{ .rid = "P2", .url_hash = hashUrl8(u), .method_hash = hashMethod("GET"), .ts_us = t0 + 1_000 } }, t0 + 1_200);
    out.* = .{ 0, 0 };
    var now: i64 = t0 + 10_000;
    var r1 = false;
    var r2 = false;
    var p1 = false;
    var p2 = false;
    // 워커의 fetch: P2 의 것(R2)은 곧, P1 의 것(R1)은 `sw_delay` 뒤. 각 응답은 그 fetch + `server` 에 오고 곧 끝난다(P2 먼저면 P1 의 응답은 조금 더 늦게).
    const r2_at = t0 + 3_000;
    const r1_at = t0 + sw_delay;
    const p2_resp = if (p2_first) r2_at + server else r1_at + server + 40_000;
    const p1_resp = if (p2_first) @max(r1_at + server, p2_resp + 40_000) else r1_at + server;
    while (now < t0 + 8_000_000) : (now += 10_000) {
        if (!r2 and now >= r2_at) {
            r2 = true;
            _ = try h.cand(5, 2, u, r2_at, .{ .sw = true });
        }
        if (!r1 and now >= r1_at) {
            r1 = true;
            _ = try h.cand(5, 1, u, r1_at, .{ .sw = true });
        }
        try h.flushed(now, now);
        if (!p2 and now >= p2_resp) {
            p2 = true;
            h.table.cefEndReceived(5, 2, now - 2_000, true, 9);
            try sw_resp(&h, "P2", now - 1_000, now);
            try h.finish(5, "P2", now + 500);
        }
        if (!p1 and now >= p1_resp) {
            p1 = true;
            h.table.cefEndReceived(5, 1, now - 2_000, true, 9);
            try sw_resp(&h, "P1", now - 1_000, now);
            try h.finish(5, "P1", now + 500);
        }
        try h.table.tickAt(gpa_t, now + 600, now + 600);
        try h.drain();
        v20jNoteFetches(&h, out);
    }
    try testing.expectEqual(@as(u32, 1), endCount(&h, 1));
    try testing.expectEqual(@as(u32, 1), endCount(&h, 2));
}

/// 보낸 본문 호출마다(그 호출이 아직 inflight 일 때) CDP rid 가 P1·P2 면 그 CEF 기록 번호를 `out` 에 적는다.
fn v20jNoteFetches(h: *H, out: *[2]u64) void {
    for (h.fetches.items) |a| for (h.table.inflight.items) |f| if (f.id == a.fetch.id) {
        if (a.fetch.rid.eql("P1")) out[0] = f.request;
        if (a.fetch.rid.eql("P2")) out[1] = f.request;
    };
}

test "W9d② v20j A R6-1: 서비스 워커가 같은 주소 두 요청을 거꾸로 넘기고 서버가 느리면(두 워커 기록이 두 응답 앞) 본문이 남의 기록에 붙는다" {
    var wrong: usize = 0;
    for ([_]i64{ 20_000, 100_000, 300_000 }) |d| for ([_]i64{ 400_000, 900_000 }) |srv| for ([_]bool{ false, true }) |p2f| {
        var o: [2]u64 = undefined;
        try v20jSwReorder(d, srv, p2f, &o);
        const bad = (o[0] != 0 and o[0] != 1) or (o[1] != 0 and o[1] != 2);
        if (bad) wrong += 1;
        std.debug.print("[v20j R6-1] sw delay {d} ms server {d} ms p2 first {}: P1 → {d} (own 1), P2 → {d} (own 2){s}\n", .{ @divTrunc(d, 1000), @divTrunc(srv, 1000), p2f, o[0], o[1], if (bad) "  WRONG" else "" });
    };
    try testing.expectEqual(@as(usize, 0), wrong);
}

/// v20j A R6-2: 서비스 워커가 P1 에는 다른 주소를 fetch 해 답하고(출처 `network` — CDP 신호로 빠지지 않는다, 제 주소의 CEF 기록이 없다) 같은
/// 주소의 P2 는 그대로 넘긴다(R2). 서버가 느려 R2 가 P1 의 응답보다 앞에 시작한다. `p2_first` 면 P2 가 먼저 끝난다. 돌려주는 것: P1·P2 가 받으러
/// 간 CEF 기록 번호(0 = 본문 없음). P1 의 다른 주소 기록은 3(다른 열쇠).
fn v20jSwAlt(server: i64, p2_first: bool, out: *[2]u64) !void {
    var h: H = .{ .sync = false };
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    const u = "https://sw.test/data";
    const alt = "https://sw.test/data?fresh=1";
    const t0: i64 = 10_000_000;
    const sw_resp = struct {
        fn f(hh: *H, rid: []const u8, ts: i64, now: i64) !void {
            try hh.ev(5, .{ .response = .{ .rid = rid, .mime = "application/json", .from_sw = true, .sw_source = "network", .charset = .other, .ts_us = ts } }, now);
            try hh.ev(5, .{ .data = .{ .rid = rid, .bytes = 9 } }, now);
        }
    }.f;
    out.* = .{ 0, 0 };
    try h.ev(5, .{ .will_be_sent = .{ .rid = "P1", .url_hash = hashUrl8(u), .method_hash = hashMethod("GET"), .ts_us = t0 } }, t0 + 200);
    try h.ev(5, .{ .will_be_sent = .{ .rid = "P2", .url_hash = hashUrl8(u), .method_hash = hashMethod("GET"), .ts_us = t0 + 1_000 } }, t0 + 1_200);
    _ = try h.cand(5, 3, alt, t0 + 2_000, .{ .sw = true }); // 워커가 P1 을 위해 받은 다른 주소
    _ = try h.cand(5, 2, u, t0 + 3_000, .{ .sw = true }); // P2 를 그대로 넘겼다
    try h.flushed(t0 + 4_000, t0 + 4_000);
    const p1_at = t0 + server + if (p2_first) @as(i64, 40_000) else 0;
    const p2_at = t0 + server + if (p2_first) @as(i64, 0) else 40_000;
    var now: i64 = t0 + 10_000;
    var p1 = false;
    var p2 = false;
    while (now < t0 + 4_000_000) : (now += 10_000) {
        try h.flushed(now, now);
        if (!p1 and now >= p1_at) {
            p1 = true;
            h.table.cefEndReceived(5, 3, now - 2_000, true, 9);
            try sw_resp(&h, "P1", now - 1_000, now);
            try h.finish(5, "P1", now + 500);
        }
        if (!p2 and now >= p2_at) {
            p2 = true;
            h.table.cefEndReceived(5, 2, now - 2_000, true, 9);
            try sw_resp(&h, "P2", now - 1_000, now);
            try h.finish(5, "P2", now + 500);
        }
        try h.table.tickAt(gpa_t, now + 600, now + 600);
        try h.drain();
        v20jNoteFetches(&h, out);
    }
}

test "W9d② v20j A R6-2: 서비스 워커가 P1 에 다른 주소를 fetch 해 답하면(출처 network) P1 의 본문이 같은 주소 P2 의 워커 기록에 붙는다" {
    var wrong: usize = 0;
    for ([_]i64{ 50_000, 400_000 }) |srv| for ([_]bool{ false, true }) |p2f| {
        var o: [2]u64 = undefined;
        try v20jSwAlt(srv, p2f, &o);
        const bad = o[0] != 0 or (o[1] != 0 and o[1] != 2);
        if (bad) wrong += 1;
        std.debug.print("[v20j R6-2] server {d} ms p2 first {}: P1 → {d} (own: none — its record 3 is another URL), P2 → {d} (own 2){s}\n", .{ @divTrunc(srv, 1000), p2f, o[0], o[1], if (bad) "  WRONG" else "" });
    };
    try testing.expectEqual(@as(usize, 0), wrong);
}

/// v20j A R9-1: 혼돈 퍼즈를 넓힌 것 — 두 탭, 같은 rid 로 다시 보냄(리다이렉트 홉·같은 주소 다시 시작 — 끝을 본 뒤에도), 같은 번호의 CEF 다시 시작
/// (`restartCand`), 설정 끔의 덮기(`cefRedirect`·`cefCovered`), 문 넘김 표지·표지 넘침, 기록이 버려짐(하나·모두), 끄기·다시 켜기·렌더러 죽음·닫힘,
/// 쏟아짐 밸브. 사건이 멎으면 주기만 30 초 — 시작마다 끝 하나·한가해짐(Debug 의 범위 검사가 UB 를 잡는다).
fn v20jChaos(seed: u64, stats: *[4]usize) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const rnd = prng.random();
    var h: H = .{ .sync = rnd.boolean() };
    defer h.deinit();
    const tabs = [_]BrowserId{ 5, 6 };
    var session: u32 = 1;
    for (tabs) |b| _ = try h.table.start(gpa_t, b, session);
    const urls = [_][]const u8{ "https://c.test/a", "https://c.test/b", "https://c.test/c.png" };
    const mimes = [_][]const u8{ "application/json", "text/javascript", "image/png", "text/html" };
    var now: i64 = 1_000_000;
    var next_req: u64 = 1;
    var rb: [24][12]u8 = undefined;
    var rids: [24][]const u8 = undefined;
    var rtab: [24]BrowserId = undefined;
    var nrid: usize = 0;
    var req_tab: [256]BrowserId = undefined;
    const steps = rnd.intRangeAtMost(usize, 5, 90);
    var pend_fetch: std.ArrayList(i32) = .empty;
    defer pend_fetch.deinit(gpa_t);
    var seen_fetch: usize = 0;
    for (0..steps) |_| {
        now += rnd.intRangeAtMost(i64, 0, 40_000);
        const k = rnd.uintLessThan(u8, 26);
        const u = urls[rnd.uintLessThan(usize, urls.len)];
        const b = tabs[rnd.uintLessThan(usize, tabs.len)];
        switch (k) {
            0, 1 => if (nrid < rids.len) { // CDP will_be_sent (new rid)
                rids[nrid] = std.fmt.bufPrint(&rb[nrid], "r{d}", .{nrid}) catch unreachable;
                rtab[nrid] = b;
                try h.ev(b, .{ .will_be_sent = .{ .rid = rids[nrid], .url_hash = hashUrl8(u), .method_hash = hashMethod(if (rnd.uintLessThan(u8, 6) == 0) "POST" else "GET"), .ts_us = now - rnd.intRangeAtMost(i64, 0, 3_000), .loader = rnd.uintLessThan(u64, 3), .low = rnd.boolean() } }, now);
                nrid += 1;
            },
            2, 3 => if (next_req < req_tab.len) { // CEF begin
                req_tab[next_req] = b;
                _ = try h.cand(b, next_req, u, now - rnd.intRangeAtMost(i64, -6_000, 3_000), .{ .sw = rnd.uintLessThan(u8, 8) == 0, .attr = if (rnd.uintLessThan(u8, 8) == 0) 2 else 1, .cover_pending = rnd.uintLessThan(u8, 10) == 0, .method = if (rnd.uintLessThan(u8, 6) == 0) "POST" else "GET" });
                next_req += 1;
            },
            4 => if (next_req > 1) { // CEF end (random record)
                const r = rnd.intRangeLessThan(u64, 1, next_req);
                h.table.cefEndReceived(req_tab[r], r, now, rnd.uintLessThan(u8, 4) != 0, rnd.uintLessThan(u64, 3));
            },
            5, 6 => if (nrid > 0) { // response
                const x = rnd.uintLessThan(usize, nrid);
                const sw = rnd.uintLessThan(u8, 8) == 0;
                try h.ev(rtab[x], .{ .response = .{ .rid = rids[x], .mime = mimes[rnd.uintLessThan(usize, mimes.len)], .from_sw = sw, .sw_source = if (sw and rnd.boolean()) "cache-storage" else "network", .charset = .other, .ts_us = now - rnd.intRangeAtMost(i64, 0, 2_000), .has_extra_info = rnd.boolean() } }, now);
                try h.ev(rtab[x], .{ .data = .{ .rid = rids[x], .bytes = rnd.uintLessThan(u64, 3) * 7 } }, now);
            },
            7, 8 => if (nrid > 0) {
                const x = rnd.uintLessThan(usize, nrid);
                try h.ev(rtab[x], .{ .finished = .{ .rid = rids[x] } }, now);
            },
            9 => if (nrid > 0) {
                const x = rnd.uintLessThan(usize, nrid);
                try h.ev(rtab[x], .{ .failed = .{ .rid = rids[x], .ts_us = now - rnd.intRangeAtMost(i64, 0, 1_000) } }, now);
            },
            10 => if (nrid > 0) {
                const x = rnd.uintLessThan(usize, nrid);
                try h.ev(rtab[x], .{ .extra_info = .{ .rid = rids[x], .credentialed = rnd.boolean() } }, now);
            },
            11 => if (nrid > 0 and rnd.uintLessThan(u8, 3) == 0) {
                const x = rnd.uintLessThan(usize, nrid);
                try h.ev(rtab[x], .{ .from_cache = .{ .rid = rids[x] } }, now);
            },
            12 => h.table.documentStarted(b, now),
            13 => try h.flushed(now - rnd.intRangeAtMost(i64, 0, 20_000), now),
            14 => {
                try h.table.tickAt(gpa_t, now, now - rnd.intRangeAtMost(i64, 0, 20_000));
                try h.drain();
            },
            15 => if (next_req > 1 and rnd.uintLessThan(u8, 4) == 0) {
                const r = rnd.intRangeLessThan(u64, 1, next_req);
                h.table.cefLost(req_tab[r], r, now);
            },
            16 => if (nrid > 0) { // 같은 rid 로 다시 보냄 — 같은 주소(다시 시작)나 다른 주소(리다이렉트 홉), 끝을 본 뒤에도
                const x = rnd.uintLessThan(usize, nrid);
                const same = rnd.boolean();
                const uu = if (same) u else urls[rnd.uintLessThan(usize, urls.len)];
                try h.ev(rtab[x], .{ .will_be_sent = .{ .rid = rids[x], .url_hash = hashUrl8(uu), .method_hash = hashMethod("GET"), .ts_us = now - rnd.intRangeAtMost(i64, 0, 2_000), .redirect = !same or rnd.boolean() } }, now);
            },
            17 => if (next_req > 1) { // 같은 번호의 CEF 다시 시작
                const r = rnd.intRangeLessThan(u64, 1, next_req);
                _ = try h.cand(req_tab[r], r, u, now - rnd.intRangeAtMost(i64, -3_000, 3_000), .{ .sw = rnd.uintLessThan(u8, 8) == 0 });
            },
            18 => if (next_req > 1) {
                const r = rnd.intRangeLessThan(u64, 1, next_req);
                if (rnd.boolean()) h.table.cefRedirect(req_tab[r], r, rnd.boolean()) else h.table.cefCovered(req_tab[r], r, rnd.boolean());
            },
            19 => if (rnd.uintLessThan(u8, 4) == 0) h.table.noteDropOverflow(b, now) else h.table.noteDrop(b, hashUrl8(u), now - rnd.intRangeAtMost(i64, 0, 3_000)),
            20 => if (rnd.uintLessThan(u8, 6) == 0) h.table.cefLostAll(b, now),
            21 => if (rnd.uintLessThan(u8, 4) == 0) { // 다시 켬(새 세션 — 앞 세션의 것은 recording_stopped)
                session += 1;
                _ = try h.table.start(gpa_t, b, session);
                try h.drain();
            },
            22 => if (rnd.uintLessThan(u8, 6) == 0) {
                try h.table.stop(gpa_t, b);
                try h.drain();
                if (rnd.boolean()) {
                    session += 1;
                    _ = try h.table.start(gpa_t, b, session);
                }
            },
            23 => if (rnd.uintLessThan(u8, 5) == 0) {
                try h.table.rendererGone(gpa_t, b);
                try h.drain();
            },
            24 => if (rnd.uintLessThan(u8, 8) == 0) {
                try h.table.closed(gpa_t, b);
                try h.drain();
                session += 1;
                _ = try h.table.start(gpa_t, b, session);
            },
            else => if (rnd.uintLessThan(u8, 10) == 0) { // 쏟아짐 — 같은 초에 5001 개를 두 초
                for (0..2) |sec| {
                    const base = (@divFloor(now, 1_000_000) + @as(i64, @intCast(sec)) + 1) * 1_000_000;
                    for (0..flood_events_per_s + 1) |_| try h.table.cdpEvent(gpa_t, b, null, base + 10);
                }
                now = (@divFloor(now, 1_000_000) + 3) * 1_000_000;
                try h.drain();
            },
        }
        while (seen_fetch < h.fetches.items.len) : (seen_fetch += 1) try pend_fetch.append(gpa_t, h.fetches.items[seen_fetch].fetch.id);
        while (pend_fetch.items.len > 0 and rnd.uintLessThan(u8, 3) == 0) {
            const id = pend_fetch.swapRemove(rnd.uintLessThan(usize, pend_fetch.items.len));
            if (rnd.uintLessThan(u8, 5) == 0) continue;
            if (h.table.takeInflight(id)) |f| {
                try h.noteEnd(f.request, .captured);
                try h.table.bodyDone(gpa_t, f, now);
                try h.drain();
            }
        }
    }
    for (1..next_req) |r| h.table.cefEndReceived(req_tab[r], r, now + 1_000, true, 10);
    var t = now + 50_000;
    while (t < now + 30_000_000) : (t += 50_000) {
        try h.table.tickAt(gpa_t, t, t);
        try h.drain();
        while (seen_fetch < h.fetches.items.len) : (seen_fetch += 1) {}
    }
    stats[0] += 1;
    var stuck: usize = 0;
    for (1..next_req) |r| {
        const want = h.attempts.get(r) orelse continue;
        if (endCount(&h, r) != want) stuck += 1;
    }
    if (h.table.busy()) stats[2] += 1;
    if (stuck > 0) {
        stats[1] += 1;
        if (stats[3] == 0) stats[3] = seed;
    }
}

test "W9d② v20j A R9-1: 넓힌 혼돈 퍼즈 — 두 탭·rid 다시 보냄·CEF 다시 시작·덮기·표지·끄기/켜기/죽음/닫힘·쏟아짐: 시작마다 끝 하나, 한가해짐" {
    var stats: [4]usize = @splat(0);
    const n: usize = if (std.c.getenv("V20J_CHAOS_N")) |v| std.fmt.parseInt(usize, std.mem.span(v), 10) catch 3000 else 3000;
    const base: u64 = if (std.c.getenv("V20J_CHAOS_BASE")) |v| std.fmt.parseInt(u64, std.mem.span(v), 10) catch 0x7a1c0000 else 0x7a1c0000;
    for (0..n) |s| v20jChaos(base + s, &stats) catch |err| {
        std.debug.print("[v20j chaos] seed {d}: {s}\n", .{ base + s, @errorName(err) });
        return err;
    };
    std.debug.print("[v20j chaos] runs {d} stuck {d} busy {d} first seed {d}\n", .{ stats[0], stats[1], stats[2], stats[3] });
    try testing.expectEqual(@as(usize, 0), stats[1]);
    try testing.expectEqual(@as(usize, 0), stats[2]);
}

// 재검증 4 차 뒤 R19-1(검증자 A 의 값 탐침을 단언으로): 주기마다의 일은 기다리는 요청 수에 비례한다 — 전에는 요청마다 `reqs` 를 훑어(`me`·`held`)
// N=4095 에 Debug 112 ms/주기였다. 스레드 CPU 시간으로 재 부하에 덜 흔들린다.
test "W9d② v20j A R19-1: split_wait 의 값 — 응답을 기다리는 같은 주소 요청 하나 뒤의 끝난 같은 주소 GET N 개가 2 초 기다리는 동안 주기마다 드는 시간이 N 에 비례한다(N=4095 의 가장 무거운 주기 40 ms 아래)" {
    for ([_]usize{ 512, 2048, 4095 }) |n| {
        var h: H = .{};
        defer h.deinit();
        _ = try h.table.start(gpa_t, 5, 1);
        const url = "http://127.0.0.1/v20j/same";
        var rb: [24]u8 = undefined;
        const t0: i64 = 10_000_000;
        // S: 응답을 기다린다(기록은 왔다 — 응답이 없어 2 초 동안 「기록이 아직 올 수 있는」 요청).
        try h.table.cdpEvent(gpa_t, 5, .{ .will_be_sent = .{ .rid = "S", .url_hash = hashUrl8(url), .method_hash = hashMethod("GET"), .ts_us = t0 } }, t0);
        _ = try h.table.cefBegin(gpa_t, 5, .{ .request = 1, .key = .{ .url = hashUrl8(url), .method = hashMethod("GET"), .sw = false }, .t_io_us = t0 + 50, .attr = 1 });
        for (0..n) |i| {
            const ts: i64 = t0 + 1 + @as(i64, @intCast(i));
            const rid = try std.fmt.bufPrint(&rb, "f.{d}", .{i});
            try h.table.cdpEvent(gpa_t, 5, .{ .will_be_sent = .{ .rid = rid, .url_hash = hashUrl8(url), .method_hash = hashMethod("GET"), .ts_us = ts } }, ts);
            _ = try h.table.cefBegin(gpa_t, 5, .{ .request = 100 + i, .key = .{ .url = hashUrl8(url), .method = hashMethod("GET"), .sw = false }, .t_io_us = ts + 50, .attr = 1 });
        }
        const fin: i64 = t0 + 20_000;
        for (0..n) |i| {
            const rid = try std.fmt.bufPrint(&rb, "f.{d}", .{i});
            h.table.cefEnd(5, 100 + i, fin - 1_000);
            h.table.cef_seen_us = fin;
            try h.table.cdpEvent(gpa_t, 5, .{ .response = .{ .rid = rid, .mime = "application/json", .from_sw = false, .charset = .other, .ts_us = fin - 500 } }, fin);
            try h.table.cdpEvent(gpa_t, 5, .{ .finished = .{ .rid = rid } }, fin);
        }
        var worst: u64 = 0;
        var wait_worst: u64 = 0;
        var total: u64 = 0;
        var ticks: usize = 0;
        var decided_at: i64 = 0;
        var now = fin + 50_000;
        while (now < fin + 3_000_000) : (now += 50_000) {
            const pre = h.table.actions.items.len;
            const a = clock_gettime_nsec_np(16); // CLOCK_THREAD_CPUTIME_ID
            try h.table.tickAt(gpa_t, now, now);
            const b = clock_gettime_nsec_np(16);
            const produced = h.table.actions.items.len > pre;
            worst = @max(worst, b - a);
            if (decided_at == 0 and !produced) wait_worst = @max(wait_worst, b - a);
            total += b - a;
            if (b - a > 5_000_000) std.debug.print("\n    [v20j R19-1] n={d} tick at +{d} ms: {d} us (ends so far {d})", .{ n, @divTrunc(now - fin, 1000), (b - a) / 1000, h.table.actions.items.len });
            ticks += 1;
            if (decided_at == 0 and produced) decided_at = now;
            // 받으러 간 호출은 곧 답한다(자리를 비워 다음 기다림이 나간다).
            var list: std.ArrayList(Action) = .empty;
            defer list.deinit(gpa_t);
            h.table.swapActions(&list);
            for (list.items) |x| switch (x) {
                .fetch => |f| if (h.table.takeInflight(f.id)) |ff| try h.table.bodyDone(gpa_t, ff, now),
                else => {},
            };
        }
        std.debug.print("\n[v20j R19-1] n={d}: first decision {d} ms after the finishes · {d} ticks · worst tick {d} us · total {d} us", .{ n, @divTrunc(decided_at - fin, 1000), ticks, worst / 1000, total / 1000 });
        // 기다리는 동안의 주기(판정 주기는 끝을 N 개 내니 따로) — 판정 전 주기들의 가장 무거운 것.
        try testing.expect(decided_at > fin + 1_500_000); // 기다림이 실제로 있었다(주기 수십 개)
        if (n == 4095) try testing.expect(wait_worst < 40_000_000);
    }
    std.debug.print("\n", .{});
}

test "W9d② v20j A R6-3: 페이지 요청 하나 — 워커가 다른 주소로 답하고(출처 network) 같은 주소를 제 갱신 fetch 로 따로 받으면(CDP 가 보지 못한다) 그 갱신 기록에 페이지의 본문이 붙는다" {
    var wrong: usize = 0;
    for ([_]i64{ 50_000, 400_000 }) |srv| {
        var h: H = .{ .sync = false };
        defer h.deinit();
        _ = try h.table.start(gpa_t, 5, 1);
        const u = "https://sw.test/feed";
        const alt = "https://sw.test/feed?fresh=1";
        const t0: i64 = 10_000_000;
        try h.ev(5, .{ .will_be_sent = .{ .rid = "P1", .url_hash = hashUrl8(u), .method_hash = hashMethod("GET"), .ts_us = t0 } }, t0 + 200);
        _ = try h.cand(5, 3, alt, t0 + 2_000, .{ .sw = true }); // 워커가 P1 에 답하려고 받은 다른 주소
        _ = try h.cand(5, 4, u, t0 + 2_500, .{ .sw = true }); // 워커 제 갱신 fetch(같은 주소 — CDP 에 없다)
        var out: [2]u64 = .{ 0, 0 };
        var now: i64 = t0 + 10_000;
        var done = false;
        while (now < t0 + 3_000_000) : (now += 10_000) {
            try h.flushed(now, now);
            if (!done and now >= t0 + srv) {
                done = true;
                h.table.cefEndReceived(5, 3, now - 2_000, true, 9);
                h.table.cefEndReceived(5, 4, now - 1_500, true, 9);
                try h.ev(5, .{ .response = .{ .rid = "P1", .mime = "application/json", .from_sw = true, .sw_source = "network", .charset = .other, .ts_us = now - 1_000 } }, now);
                try h.ev(5, .{ .data = .{ .rid = "P1", .bytes = 9 } }, now);
                try h.finish(5, "P1", now + 500);
            }
            try h.table.tickAt(gpa_t, now + 600, now + 600);
            try h.drain();
            v20jNoteFetches(&h, &out);
        }
        const bad = out[0] != 0;
        if (bad) wrong += 1;
        std.debug.print("[v20j R6-3] server {d} ms: P1 → {d} (own: none — its record 3 is another URL; 4 is the worker's own refresh){s}\n", .{ @divTrunc(srv, 1000), out[0], if (bad) "  WRONG" else "" });
    }
    try testing.expectEqual(@as(usize, 0), wrong);
}

test "W9d② 재검증 4 차 뒤 R6: 워커가 그대로 넘긴 요청 하나는 제 본문 — 곁의 워커 요청이 캐시로 답하고 같은 주소를 네트워크로 다시 받아도(stale-while-revalidate — 그 기록은 설명된다), 설명되지 않는 다른 주소의 워커 기록이 창에 있으면 본문 없이" {
    for ([_]bool{ true, false }) |with_swr| {
        var h: H = .{ .sync = false };
        defer h.deinit();
        _ = try h.table.start(gpa_t, 5, 1);
        const u = "https://sw.test/api";
        const v = "https://sw.test/style.css";
        const t0: i64 = 10_000_000;
        // P(u): 워커가 그대로 넘긴다(기록 1). V(v): 워커가 캐시로 답하고 v 를 네트워크로 다시 받는다(기록 2 — CDP 에는 V 만 보인다).
        try h.ev(5, .{ .will_be_sent = .{ .rid = "P", .url_hash = hashUrl8(u), .method_hash = hashMethod("GET"), .ts_us = t0 } }, t0 + 100);
        if (with_swr) try h.ev(5, .{ .will_be_sent = .{ .rid = "V", .url_hash = hashUrl8(v), .method_hash = hashMethod("GET"), .ts_us = t0 + 500 } }, t0 + 600);
        _ = try h.cand(5, 1, u, t0 + 1_000, .{ .sw = true });
        _ = try h.cand(5, 2, v, t0 + 2_000, .{ .sw = true });
        try h.flushed(t0 + 3_000, t0 + 3_000);
        if (with_swr) {
            try h.ev(5, .{ .response = .{ .rid = "V", .mime = "text/css", .from_sw = true, .sw_source = "cache-storage", .charset = .other, .ts_us = t0 + 4_000 } }, t0 + 4_100);
            try h.finish(5, "V", t0 + 4_200);
        }
        h.table.cefEndReceived(5, 1, t0 + 40_000, true, 9);
        try h.flushed(t0 + 41_000, t0 + 41_000);
        try h.ev(5, .{ .response = .{ .rid = "P", .mime = "application/json", .from_sw = true, .sw_source = "network", .charset = .other, .ts_us = t0 + 41_000 } }, t0 + 41_100);
        try h.ev(5, .{ .data = .{ .rid = "P", .bytes = 9 } }, t0 + 41_100);
        try h.finish(5, "P", t0 + 41_200);
        var now: i64 = t0 + 50_000;
        while (now < t0 + 3_000_000) : (now += 50_000) {
            try h.flushed(now, now);
            try h.table.tickAt(gpa_t, now, now);
            try h.drain();
        }
        errdefer std.debug.print("R6 swr={}: P fetched {?d} · rec1 {?s}\n", .{ with_swr, fetchedFor(&h, "P"), if (h.ended.get(1)) |x| @tagName(x) else null });
        if (with_swr) {
            try testing.expectEqual(@as(?u64, 1), fetchedFor(&h, "P"));
        } else {
            try testing.expectEqual(@as(?u64, null), fetchedFor(&h, "P"));
            try testing.expectEqual(@as(?State, .ambiguous), h.ended.get(1));
        }
    }
}
