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
//!
//! 시험이 증명하는 것: 맞추기(두 도착 차례·창·같은 주소의 차례 — 창이 다른 동시 요청·기록이 아직인 뒤 요청·ExtraInfo 가 먼저 온 요청·문 넘김과
//! 보이는 규칙이 다른 후보의 모호함·CDP 가 보지 못한 같은 주소 후보의 모호함과 갈린 다른 요청·서비스 워커 갈래·조각 떼기·A → B → A 와 다시
//! 시작), 설정 끔의 응답 호스트 기다림, 홉마다의 ExtraInfo 와 그 자리의 시한, 상한과 판정(넘침·글 아님·빈 본문·끊김·실패), 동시·초당 상한과
//! 기다림의 만료, 세대(끈 뒤 늦게 온 결과는 버린다), 시작마다 끝은 꼭 하나, MIME 가르기, 결과 풀기(JSON 글·base64·잘못된 UTF-8·windows-1252
//! 되돌리기), 물 높이(제 기록이 늦은 빠른 요청·응답 뒤 워커의 기록·응답의 CDP 시각·시한), abort 한 요청과 다시 받은 요청(CEF 에 닿았든 아니든·
//! CEF 끝이 늦어도), 답이 오지 않는 본문 호출의 시한, 서비스 워커 응답의 출처(Cache Storage·만든 응답·HTTP 캐시·출처 없음은 워커 기록에 붙이지
//! 않고 그대로 넘긴 것만 — 섞이면 `ambiguous`), 넘김 상자가 넘쳐 놓친 시작의 표지, CEF 가 받은 바이트로 가르는 빈 본문, (5 회차) CDP 실패 시각과
//! CEF 의 결과로만 정하는 abort 한 요청(느린 다시 받기·늦은 취소 끝·세 요청의 차례·물 높이), 기다림의 차례·내주기·전체 상한·줄 전체의 시한,
//! 넘김 상자가 버린 끝의 표지.

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

/// windows-1252 로 되돌려 볼 MIME 인가(J11 — charset 없는 `text/plain` 이 깨져 왔다; HTML·JavaScript·JSON 은 맞게 풀렸다).
fn redecodeCandidate(mime_full: []const u8) bool {
    const semi = std.mem.indexOfScalar(u8, mime_full, ';') orelse mime_full.len;
    const mime = std.mem.trim(u8, mime_full[0..semi], " \t");
    if (!std.ascii.startsWithIgnoreCase(mime, "text/")) return false;
    for ([_][]const u8{ "text/html", "text/javascript", "text/ecmascript" }) |t| if (std.ascii.eqlIgnoreCase(mime, t)) return false;
    return true;
}

/// Content-Type 헤더 값에 charset 매개변수가 있는가.
pub fn hasCharset(content_type: []const u8) bool {
    return std.ascii.findIgnoreCase(content_type, "charset=") != null;
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

/// `getResponseBody` 의 결과(`{"body":"…","base64Encoded":bool}`)를 보낼 바이트로 푼다. `mime` 은 응답 MIME, `charset` 은 Content-Type 에
/// charset 이 있었는가, `raw_size` 는 받은 바이트(Σ `dataReceived` — 0 = 모른다). 실패한 호출(`ok` 거짓 — 「다음 문서로 옮겨 사라졌다」 등)과
/// 모양이 틀린 결과는 `unavailable`.
///
/// windows-1252 되돌리기(J11)는 Chromium 이 **UTF-8 바이트를 windows-1252 로 잘못 읽은** 글에만 한다(W9d② 적대 리뷰 1 회차): 글을 그 표로
/// 되돌린 바이트가 UTF-8 로 맞고, 받은 바이트 수가 알려졌으면 그것과 꼭 같을 때. windows-1252 로 읽었다면 글자 하나가 받은 바이트 하나라
/// 수가 같다. BOM 으로 UTF-8 을 알아본 본문(Chromium 이 맞게 풀었다 — BOM 세 바이트와 여러 바이트 글자만큼 수가 다르다)은 이것으로 걸러져
/// 그대로 둔다(전에는 「Ã©」 같은 글을 담은 그런 본문을 「é」 로 바꿨다). 남는 틈: 받은 바이트를 모를 때(0)는 수를 보지 않는다. 진짜
/// Latin-1 본문 안의 「Ã©」 꼴 바이트는 UTF-8 로 맞아 되돌린다 — fetch·XHR 은 charset 없는 글을 UTF-8 로 읽으므로 그것이 페이지가 읽은 글이다.
pub fn decodeResult(gpa: std.mem.Allocator, ok: bool, json: []const u8, mime: []const u8, charset: bool, raw_size: u64) std.mem.Allocator.Error!Decoded {
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
    } else if (!charset and redecodeCandidate(mime) and !isAscii(bytes)) {
        // charset 없는 text/* 를 Chromium 이 windows-1252 로 풀었다(J11) — 되돌려 UTF-8 이면 그것이 페이지가 받은 글이다.
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
    }
    if (bytes.len > msg.max_net_body_bytes) {
        const n = bytes.len;
        gpa.free(bytes);
        return .{ .state = .over_cap, .over_bytes = n };
    }
    return .{ .state = .captured, .flags = flags, .bytes = bytes };
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
    will_be_sent: struct { rid: []const u8, url_hash: u64, method_hash: u64, ts_us: i64, redirect: bool = false, prefetch: bool = false, low: bool = false },
    /// `Network.requestWillBeSentExtraInfo` — 실제로 실린 쿠키(막히지 않은 것)·인증 헤더가 있었나.
    extra_info: struct { rid: []const u8, credentialed: bool },
    /// `Network.responseReceived` — `has_extra_info` 는 이 요청의 ExtraInfo 가 오거나 왔다는 Chromium 의 알림(`hasExtraInfo`).
    /// `ts_us` 는 CDP `timestamp`(µs — 0 = 모른다; W9d② 적대 리뷰 3 회차 P1 의 `bound`). `sw_source` 는 서비스 워커가 준 응답의 출처
    /// (`response.serviceWorkerResponseSource` — `network`·`http-cache`·`cache-storage`·`fallback-code`, 없으면 빈 글; W9d② 적대 리뷰 4 회차 SW1).
    response: struct { rid: []const u8, mime: []const u8, from_sw: bool, charset: bool, prefetch: bool = false, has_extra_info: bool = false, ts_us: i64 = 0, sw_source: []const u8 = "", low: bool = false },
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
            .charset = hasCharset(ct),
            .prefetch = boolean(v, "response.fromPrefetchCache"),
            .has_extra_info = boolean(v, "hasExtraInfo"),
            .ts_us = cdpMicros(v),
            .low = lowPriority(str(v, "type")),
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
    charset: bool = false,
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

const Waiting = struct {
    request: u64,
    rid: Rid,
    since: i64,
    bytes: u64,
    mime: [msg.max_net_mime_bytes]u8 = undefined,
    mime_len: u8 = 0,
    charset: bool,
    credentialed: bool,
    /// 5 회차 A2: 차례가 뒤(`lowPriority`) — 기다림은 앞 차례 모두 뒤에 이것들(차례마다 들어온 차례).
    low: bool = false,
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
    charset: bool,
    credentialed: bool,
    /// 보낸 UI 시각 — 답이 `fetch_timeout_us` 안에 오지 않으면 `unavailable` 로 끝낸다(W9d② 적대 리뷰 3 회차 S1).
    sent_at: i64 = 0,

    pub fn mimeSlice(self: *const Inflight) []const u8 {
        return self.mime[0..self.mime_len];
    }
};

const DropMark = struct { url: u64, t_us: i64 };

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

    pub fn recording(self: *const Tab) bool {
        return self.session != 0 and !self.paused;
    }

    fn deinit(self: *Tab, gpa: std.mem.Allocator) void {
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
        extra: std.ArrayList(u64) = .empty,
        /// 5 회차 A1: 왼쪽 맞추기에서 응답 없이 실패한 요청이 집은 후보(후보 자리마다).
        taken: std.ArrayList(bool) = .empty,

        fn deinit(self: *Scratch, gpa: std.mem.Allocator) void {
            self.taken.deinit(gpa);
            self.reqs.deinit(gpa);
            self.cands.deinit(gpa);
            self.left.deinit(gpa);
            self.right.deinit(gpa);
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
            try self.emit(gpa, .{ .end = .{ .browser = browser, .session = t.session, .request = t.cands.items[victim].request, .state = .busy } });
            _ = t.cands.orderedRemove(victim);
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
                        r.sends = 1;
                        r.last_url = v.url_hash;
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
                if (t.cdp.items.len >= max_cdp) _ = t.cdp.orderedRemove(0);
                try t.cdp.append(gpa, .{ .rid = rid, .key_url = v.url_hash, .key_method = v.method_hash, .ts_us = v.ts_us, .prefetch = v.prefetch, .has_key = true, .last_url = v.url_hash, .low = v.low });
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
                    if (placeholders >= max_placeholders) _ = t.cdp.orderedRemove(oldest.?) else if (t.cdp.items.len >= max_cdp) _ = t.cdp.orderedRemove(0);
                    try t.cdp.append(gpa, .{ .rid = rid, .key_url = 0, .key_method = 0, .ts_us = std.math.maxInt(i64), .has_key = false, .sends = 0, .placed_at = @max(now_us, 1) });
                    break :blk t.cdp.items.len - 1;
                };
                t.cdp.items[i].extras +|= 1;
                if (v.credentialed) t.cdp.items[i].credentialed = true;
            },
            .response => |v| {
                const i = cdpIndex(t, v.rid) orelse return;
                const r = &t.cdp.items[i];
                r.sw = v.from_sw;
                r.responded = true;
                r.sw_off_network = v.from_sw and !std.mem.eql(u8, v.sw_source, "network");
                // 제 기록의 IO 시각은 응답보다 앞이다 — CDP 의 응답 시각(같은 시계 — J1)이 맞아 보이면(UI 가 받은 때 앞 2 초 안) 그것, 아니면 UI 가
                // 받은 때(늦은 쪽 — 기다림이 조금 길 뿐 틀리지 않는다).
                if (r.responded_at == 0) r.responded_at = @max(cdpTime(v.ts_us, now_us), 1);
                if (v.prefetch) r.prefetch = true;
                r.low = r.low or v.low;
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
                t.cdp.items[i].state = .cached;
            },
            .finished => |v| {
                const i = cdpIndex(t, v.rid) orelse return;
                const r = &t.cdp.items[i];
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
                if (r.state == .cached or r.prefetch or !r.has_key or r.sw_off_network) {
                    _ = t.cdp.orderedRemove(i);
                    return;
                }
                r.state = .failed;
                r.done_at = @max(now_us, 1);
                // 5 회차 A1: 실패의 시각은 CDP 의 것(UI 가 받은 때는 늦다 — 응답 시각과 같은 검사).
                r.failed_at = @max(cdpTime(v.ts_us, now_us), 1);
                try self.tryDecide(gpa, t, i, now_us);
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

    /// 응답 없이 실패한 요청(다시 시작 아님) — CEF 에 닿지 않았을 수 있다(abort). 5 회차 A1: 맞추기의 차례를 밀지 않는다(`tryDecide`).
    fn failedBare(o: *const Cdp) bool {
        return o.state == .failed and o.responded_at == 0 and o.restart_ts_us == 0;
    }

    /// 실패한 요청 `o` 가 후보 `c` 를 제 것으로 정해도 되는가 — CEF 가 그 기록을 실패·취소로 끝냈을 때만(5 회차 A1 — 전에는 실패를 본 때까지
    /// 시작한 기록이면 결과를 보지 않았다). 끝이 아직이면 그 기록은 다음 요청의 것일 수 있다 — 기다리고(`tryDecide`), CEF 가 성공으로 끝내면
    /// 짝이 아니다(`compatible`). 끝이 버려진 후보(`lost` — 끝난 것으로 쳤을 뿐 `cef_failed` 를 세우지 않는다)는 결과를 모르니 정하지 않는다.
    fn definite(o: *const Cdp, c: *const Candidate) bool {
        if (o.state != .failed or o.responded_at != 0 or o.restart_ts_us != 0) return true;
        return c.ended_at != 0 and c.cef_failed;
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
    fn tryDecide(self: *Table, gpa: std.mem.Allocator, t: *Tab, i: usize, now_us: i64) std.mem.Allocator.Error!void {
        const r = t.cdp.items[i];
        const key = r.key();
        const ts = r.anchor();
        const none = std.math.maxInt(usize);
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
        // 같은 갈래의 CDP 요청 — 같은 주소·메서드, 서비스 워커 갈래가 같거나 아직 응답이 없어 모르는 것(열렸거나 끝나 짝을 기다린다 — 정한 것은
        // 목록에서 빠졌다), 기준 시각 차례. 끝난 것도 넣어야 한다: 앞 요청이 CEF 기록을 기다리는 동안 뒤 요청이 끝나면 앞 요청의 짝을 가져갔다.
        const sc = &self.scratch;
        sc.reqs.clearRetainingCapacity();
        for (t.cdp.items, 0..) |o, j| {
            // 서비스 워커가 네트워크 밖에서 준 응답(4 회차 SW1)은 어느 기록도 가져가지 않는다 — 그 워커의 기록은 이 요청의 차례에 남아 갈림을 보인다.
            if (o.state == .cached or o.prefetch or !o.has_key or o.sw_off_network) continue;
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
        std.mem.sort(usize, sc.reqs.items, ReqCtx{ .cdp = t.cdp.items }, ReqCtx.lessThan);
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
        std.mem.sort(usize, sc.cands.items, CandCtx{ .cands = t.cands.items }, CandCtx.lessThan);
        const reqs = sc.reqs.items;
        const cands = sc.cands.items;
        // 왼쪽 맞추기(요청마다 후보의 자리 — `none` 은 아직 기록이 오지 않았다). 5 회차 A1: 응답 없이 실패한 요청(`failedBare` — CEF 에 닿지
        // 않았을 수 있다)은 차례를 밀지 않는다 — 집은 후보에 표만 하고(`taken` — 뒤 요청은 건너뛴다) 다음 요청은 같은 자리부터 본다. 차례를 밀면
        // 그 요청이 CEF 가 성공으로 끝낸 기록을 건너뛰고 뒤 기록을 집을 때 그 사이의 기록이 아무에게도 가지 않았다.
        try sc.left.resize(gpa, reqs.len);
        try sc.taken.resize(gpa, cands.len);
        @memset(sc.taken.items, false);
        var me: usize = none;
        var pos: usize = 0;
        for (reqs, 0..) |j, q| {
            sc.left.items[q] = none;
            if (j == i) me = q;
            const o = &t.cdp.items[j];
            var p = pos;
            while (p < cands.len and (sc.taken.items[p] or !compatible(o, &t.cands.items[cands[p]]))) p += 1;
            if (p == cands.len) continue;
            sc.left.items[q] = p;
            if (failedBare(o)) sc.taken.items[p] = true else pos = p + 1;
        }
        const left = sc.left.items[me];
        if (left == none) {
            // 짝이 아직 오지 않았다(CEF 기록은 10 ms 묶음) — 시한이 지나면 CEF 가 보지 못한 요청으로 놓는다(본문 없음, maru 에 기록도 없다).
            if (now_us - r.done_at >= cef_grace_us) _ = t.cdp.orderedRemove(i);
            return;
        }
        const ci = cands[left];
        // P5·5 회차 A1: 응답 없이 실패한 요청에게 준 후보의 CEF 끝이 아직이면(다음 요청의 것일 수 있다 — 성공으로 끝나면 놓인다) 그 끝을
        // 기다린다. 시한까지 모르면 정하지 않는다: CDP 의 실패 시각 뒤에 시작한 기록은 다음 요청의 것(다시 받기 — 실제 CEF 93/93 이 실패 시각
        // 뒤)이라 이 요청만 놓고, 앞에 시작한 기록은 이 요청의 것일 수 있어(abort 가 CEF 의 끝보다 먼저 보였는데 그 끝이 늦다) 다음 요청에게 주지
        // 않고 본문 없이 끝낸다(`ambiguous`).
        if (!definite(&r, &t.cands.items[ci])) {
            if (now_us - r.done_at < cef_grace_us) return;
            const c = t.cands.items[ci];
            _ = t.cdp.orderedRemove(i);
            if (c.t_io_us <= r.failed_at) {
                try self.emit(gpa, .{ .end = .{ .browser = t.browser, .session = t.session, .request = c.request, .state = .ambiguous, .flags = .{ .credentialed = c.cef_credentialed } } });
                _ = t.cands.orderedRemove(ci);
            }
            return;
        }
        // 5 회차 A1: 응답 없이 실패한 요청이 이 요청의 후보 앞의 기록을 CEF 끝이 아직인 채 쥐고 있다 — 그 기록이 성공으로 끝나면 놓여 이 요청의
        // 짝이 바뀐다(abort 가 CEF 에 닿지 않았으면 그 기록은 다시 받은 이 요청의 것이다). 끝이 올 때까지 기다리고 시한이면 본문 없이.
        var held = false;
        if (!failedBare(&r)) for (reqs, sc.left.items) |j, lp| if (lp != none and lp < left and failedBare(&t.cdp.items[j]) and !definite(&t.cdp.items[j], &t.cands.items[cands[lp]])) {
            held = true;
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
        // 오른쪽 맞추기 — 왼쪽에서 짝을 받은 요청만(기록이 아직 오지 않은 요청이 뒤의 후보를 가져가는 것으로 치지 않는다).
        try sc.right.resize(gpa, reqs.len);
        var bound: usize = cands.len;
        var q = reqs.len;
        while (q > 0) {
            q -= 1;
            sc.right.items[q] = none;
            if (sc.left.items[q] == none) continue;
            // 응답 없이 실패한 요청은 차례를 밀지 않는다(왼쪽과 같다 — 갈림을 보이지 않는다).
            if (failedBare(&t.cdp.items[reqs[q]])) {
                sc.right.items[q] = sc.left.items[q];
                continue;
            }
            var p = bound;
            while (p > 0 and (sc.taken.items[p - 1] or !compatible(&t.cdp.items[reqs[q]], &t.cands.items[cands[p - 1]]))) p -= 1;
            if (p == 0) continue;
            sc.right.items[q] = p - 1;
            bound = p - 1;
        }
        const right = sc.right.items[me];
        var ambiguous = false;
        // 보이는 규칙(프레임·첫 사이트·initiator)이 다른 후보가 이 요청의 창 안에 있다.
        for (cands) |o| if (o != ci and t.cands.items[o].attr != t.cands.items[ci].attr and compatible(&r, &t.cands.items[o])) {
            ambiguous = true;
        };
        // 두 맞추기가 다른 후보를 준다 — CDP 가 보지 못한 같은 열쇠의 CEF 요청이 섞였다(MED-2·F2): 사이의 후보(둘 포함 — 이 요청의 짝일 수
        // 있다)를 모두 `ambiguous` 로 끝내고, 두 맞추기가 다른 짝을 준 다른 요청도 `ambiguous` 로 정한다.
        var extra_lo: usize = 0;
        var extra_hi: usize = 0;
        if (right != left) {
            ambiguous = true;
            if (right != none and right > left) {
                extra_lo = left + 1;
                extra_hi = right + 1;
            }
            for (reqs, 0..) |j, x| if (j != i and sc.left.items[x] != none and sc.left.items[x] != sc.right.items[x]) {
                t.cdp.items[j].tainted = true;
            };
        }
        if (r.tainted or late or held or t.cands.items[ci].lost) ambiguous = true;
        if (t.drop_overflow_until != 0 and ts - window_before_us <= t.drop_overflow_until) ambiguous = true;
        for (t.drops[0..t.drop_len]) |d| if (d.url == key.url and d.t_us >= ts - window_before_us and d.t_us <= ts + window_after_us) {
            ambiguous = true;
        };
        // 끝낼 사이의 후보는 번호로 적어 둔다(판정이 목록을 바꾼다).
        try sc.extra.resize(gpa, extra_hi - extra_lo);
        for (cands[extra_lo..extra_hi], 0..) |x, n| sc.extra.items[n] = t.cands.items[x].request;
        const cand = t.cands.items[ci];
        _ = t.cdp.orderedRemove(i);
        try self.decide(gpa, t, ci, cand, r, ambiguous, now_us);
        for (sc.extra.items) |req| for (t.cands.items, 0..) |c, x| if (c.request == req) {
            try self.emit(gpa, .{ .end = .{ .browser = t.browser, .session = t.session, .request = req, .state = .ambiguous, .flags = .{ .credentialed = c.cef_credentialed } } });
            _ = t.cands.orderedRemove(x);
            break;
        };
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
        var w: Waiting = .{ .request = cand.request, .rid = r.rid, .since = now_us, .bytes = r.data_bytes, .charset = r.charset, .credentialed = cred, .low = r.low };
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
            var f: Inflight = .{ .id = id, .browser = t.browser, .session = t.session, .request = w.request, .decoded = w.bytes, .charset = w.charset, .credentialed = w.credentialed, .sent_at = @max(now_us, 1) };
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
        var i: usize = 0;
        while (i < t.cdp.items.len) {
            const before = t.cdp.items.len;
            if (t.cdp.items[i].state == .finished or t.cdp.items[i].state == .failed) try self.tryDecide(gpa, t, i, now_us);
            if (t.cdp.items.len == before) i += 1;
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
            var c: usize = 0;
            while (c < t.cands.items.len) {
                const cand = t.cands.items[c];
                if (!cand.claimed and cand.ended_at != 0 and now_us - cand.ended_at >= unclaimed_expiry_us) {
                    try self.emit(gpa, .{ .end = .{ .browser = t.browser, .session = t.session, .request = cand.request, .state = .unmatched, .flags = .{ .credentialed = cand.cef_credentialed } } });
                    _ = t.cands.orderedRemove(c);
                    continue;
                }
                c += 1;
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
        try self.ev(browser, .{ .response = .{ .rid = rid, .mime = mime, .from_sw = false, .charset = true } }, now);
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
    try testing.expect(hasCharset("text/plain; Charset=EUC-KR"));
    try testing.expect(!hasCharset("text/plain"));
}

test "W9d②: 결과 풀기 — JSON 글, base64(글이면 글·아니면 바이너리), 빈 본문, 실패·모양이 틀린 결과, charset 없는 text/plain 의 windows-1252 되돌리기" {
    {
        const d = try decodeResult(gpa_t, true, "{\"body\":\"{\\\"a\\\":\\\"\\uD55C\\\"}\",\"base64Encoded\":false}", "application/json", false, 0);
        defer gpa_t.free(d.bytes);
        try testing.expectEqual(State.captured, d.state);
        try testing.expectEqualStrings("{\"a\":\"한\"}", d.bytes);
        try testing.expect(!d.flags.redecoded and !d.flags.binary);
    }
    {
        // 잘못된 UTF-8 JSON 은 base64 로 온다(J11) — 바이트 그대로, 바이너리 표시.
        const d = try decodeResult(gpa_t, true, "{\"body\":\"/wB7\",\"base64Encoded\":true}", "application/json", true, 0);
        defer gpa_t.free(d.bytes);
        try testing.expect(d.state == .captured and d.flags.binary);
        try testing.expectEqualSlices(u8, &.{ 0xff, 0x00, 0x7b }, d.bytes);
    }
    {
        // 글인 base64 는 글.
        const d = try decodeResult(gpa_t, true, "{\"body\":\"7ZWc\",\"base64Encoded\":true}", "text/plain", true, 0);
        defer gpa_t.free(d.bytes);
        try testing.expect(d.state == .captured and !d.flags.binary);
        try testing.expectEqualStrings("한", d.bytes);
    }
    {
        // UTF-8 「한」(ED 95 9C) 을 windows-1252 로 푼 깨진 글 「í•œ」 — 되돌린다.
        const d = try decodeResult(gpa_t, true, "{\"body\":\"\\u00ed\\u2022\\u0153 ok\",\"base64Encoded\":false}", "text/plain", false, 0);
        defer gpa_t.free(d.bytes);
        try testing.expect(d.state == .captured and d.flags.redecoded);
        try testing.expectEqualStrings("한 ok", d.bytes);
        // W9d② 적대 리뷰 1 회차: 받은 바이트 수(Σ dataReceived)를 알면 windows-1252 로 읽은 글자 수와 같을 때만 되돌린다 — 「한 ok」 는 6 바이트.
        const same = try decodeResult(gpa_t, true, "{\"body\":\"\\u00ed\\u2022\\u0153 ok\",\"base64Encoded\":false}", "text/plain", false, 6);
        defer gpa_t.free(same.bytes);
        try testing.expect(same.flags.redecoded);
        // BOM 으로 UTF-8 을 알아본 본문 — Chromium 이 맞게 풀었다(글 「Ã©」 는 원래 C3 83 C2 A9 에 BOM 셋, 7 바이트): 되돌리지 않는다(「é」 로 바꾸지 않는다).
        const bom = try decodeResult(gpa_t, true, "{\"body\":\"\\u00c3\\u00a9\",\"base64Encoded\":false}", "text/plain", false, 7);
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
        const o = try decodeResult(gpa_t, true, big.items, "text/plain", false, 400 * 1024);
        try testing.expectEqual(State.over_cap, o.state);
        try testing.expectEqual(@as(u64, 3 * 400 * 1024), o.over_bytes);
    }
    {
        // charset 이 있으면 되돌리지 않는다. 되돌릴 수 없는 글(표에 없는 글자)은 표시만.
        const d = try decodeResult(gpa_t, true, "{\"body\":\"\\u00ed\\u2022\\u0153\",\"base64Encoded\":false}", "text/plain", true, 0);
        defer gpa_t.free(d.bytes);
        try testing.expect(!d.flags.redecoded and !d.flags.chromium_decoded);
        const e = try decodeResult(gpa_t, true, "{\"body\":\"\\uD55C\",\"base64Encoded\":false}", "text/plain", false, 0);
        defer gpa_t.free(e.bytes);
        try testing.expect(e.flags.chromium_decoded and !e.flags.redecoded);
        // 라틴 글이 우연히 UTF-8 이 되지 않으면(é 하나) 그대로 — 표시만.
        const f = try decodeResult(gpa_t, true, "{\"body\":\"caf\\u00e9\",\"base64Encoded\":false}", "text/csv", false, 0);
        defer gpa_t.free(f.bytes);
        try testing.expect(f.flags.chromium_decoded);
        try testing.expectEqualStrings("café", f.bytes);
        // HTML 은 되돌리지 않는다(J11 — 맞게 풀렸다).
        const g = try decodeResult(gpa_t, true, "{\"body\":\"\\u00ed\\u2022\\u0153\",\"base64Encoded\":false}", "text/html", false, 0);
        defer gpa_t.free(g.bytes);
        try testing.expect(!g.flags.redecoded and !g.flags.chromium_decoded);
    }
    try testing.expectEqual(State.no_body, (try decodeResult(gpa_t, true, "{\"body\":\"\",\"base64Encoded\":false}", "text/plain", true, 0)).state);
    try testing.expectEqual(State.unavailable, (try decodeResult(gpa_t, false, "{\"code\":-32000}", "text/plain", true, 0)).state);
    try testing.expectEqual(State.unavailable, (try decodeResult(gpa_t, true, "[1]", "text/plain", true, 0)).state);
    try testing.expectEqual(State.unavailable, (try decodeResult(gpa_t, true, "{\"body\":\"!!!\",\"base64Encoded\":true}", "image/png", true, 0)).state);
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
    try testing.expect((try P.ev("Network.requestWillBeSent", "{\"requestId\":\"1.2\",\"timestamp\":1,\"redirectResponse\":{},\"request\":{\"url\":\"u\",\"method\":\"GET\"}}")).will_be_sent.redirect);
    try testing.expect((try P.ev("Network.requestWillBeSent", "{\"requestId\":\"A\",\"timestamp\":1,\"type\":\"Prefetch\",\"request\":{\"url\":\"u\",\"method\":\"GET\"}}")).will_be_sent.prefetch);
    try testing.expect((try P.ev("Network.requestWillBeSentExtraInfo", "{\"requestId\":\"1\",\"associatedCookies\":[{\"blockedReasons\":[]}],\"headers\":{}}")).extra_info.credentialed);
    try testing.expect(!(try P.ev("Network.requestWillBeSentExtraInfo", "{\"requestId\":\"1\",\"associatedCookies\":[{\"blockedReasons\":[\"SameSiteLax\"]}],\"headers\":{\"Accept\":\"*\"}}")).extra_info.credentialed);
    try testing.expect((try P.ev("Network.requestWillBeSentExtraInfo", "{\"requestId\":\"1\",\"associatedCookies\":[],\"headers\":{\"Authorization\":\"Basic x\"}}")).extra_info.credentialed);
    const r = (try P.ev("Network.responseReceived", "{\"requestId\":\"1\",\"response\":{\"mimeType\":\"text/plain\",\"fromServiceWorker\":true,\"headers\":{\"Content-Type\":\"text/plain\"}}}")).response;
    try testing.expect(r.from_sw and !r.charset and !r.has_extra_info);
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
    try h.ev(5, .{ .response = .{ .rid = "w.1", .mime = "application/json", .from_sw = true, .charset = true, .sw_source = "network" } }, 3_000_100);
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
    try testing.expectEqual(State.ambiguous, h.ended.get(10).?);
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
    try testing.expectEqualSlices(u64, &.{ 4032, 4031 }, h.fetchedRequests(&buf));
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
    try h.ev(5, .{ .response = .{ .rid = "2.1", .mime = "application/json", .from_sw = false, .charset = true, .has_extra_info = true } }, 6_011_000);
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
    try h.ev(5, .{ .response = .{ .rid = "3.1", .mime = "application/json", .from_sw = false, .charset = true, .has_extra_info = true } }, 7_011_000);
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
    try testing.expect(stateIs(&h, 201, .ambiguous));
    try testing.expect(stateIs(&h, 202, .ambiguous));
    // 앞 요청의 짝(200)도 가를 수 없었다(200 이 워커의 것이고 앞 요청의 기록이 201 일 수 있다 — 창 2 초 안) — 본문을 붙이지 않는다.
    try h.respond(5, "p.0", "application/json", 10, 2_100_000);
    try h.finish(5, "p.0", 2_100_100);
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
            try h.ev(5, .{ .response = .{ .rid = rid, .mime = "application/json", .from_sw = true, .charset = true, .sw_source = "network" } }, now);
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
        try testing.expectEqual(@as(?u64, 522), fetchedFor(&h, "c.r"));
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
        try testing.expect(stateIs(&h, 541, .ambiguous) and stateIs(&h, 542, .ambiguous));
        try h.respond(5, "e.s", "application/json", 9, 5_039_000);
        try h.finish(5, "e.s", 5_040_000);
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
        try k.ev(5, .{ .response = .{ .rid = "p.2", .mime = "application/json", .from_sw = false, .charset = true, .ts_us = cdp_ts } }, 1_505_000);
        try k.ev(5, .{ .data = .{ .rid = "p.2", .bytes = 9 } }, 1_505_000);
        try k.finish(5, "p.2", 1_506_000);
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
    try h.ev(5, .{ .response = .{ .rid = rid, .mime = "application/json", .from_sw = true, .charset = true, .sw_source = source } }, now);
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
        try h.ev(5, .{ .response = .{ .rid = rid, .mime = "application/javascript", .from_sw = false, .charset = true, .low = true } }, at + 1_000);
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
    try h.table.tick(gpa_t, 5_020_000);
    try h.drain();
    // 771 이 성공으로 끝났다 — x.7 은 그것을 놓고 773 을 집지만 차례를 밀지 않는다: p.7 은 곧 771.
    try testing.expectEqual(@as(?u64, 771), fetchedFor(&h, "p.7"));
    try h.respond(5, "q.7", "application/json", 9, 5_030_000);
    try h.finish(5, "q.7", 5_031_000);
    h.table.cefEnd(5, 773, 5_033_000);
    try h.table.tick(gpa_t, 5_040_000);
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
    try h.ev(b, .{ .response = .{ .rid = rid, .mime = if (low) "application/javascript" else "application/json", .from_sw = false, .charset = true } }, t);
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
    try h.ev(5, .{ .response = .{ .rid = "z.1", .mime = "application/javascript", .from_sw = false, .charset = true, .low = true } }, t);
    try h.finish(5, "z.1", t);
    try bodyAt(&h, 5, 7, false, t + 10);
    const tab = h.table.tabOf(5).?;
    try testing.expectEqual(@as(usize, 2), tab.waiting.items.len);
    try testing.expect(!tab.waiting.items[0].low); // 뒤에 온 fetch 가 앞에 선다
    try testing.expect(tab.waiting.items[1].low and tab.waiting.items[1].request == 9100);
}
