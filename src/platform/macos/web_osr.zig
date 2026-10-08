//! 웹 OSR sidecar 관리(W3b, docs/plans/web-osr-backend.md) — 앱 하나에 `maru-web-host` 하나. 창들이 나눠 쓴다.
//!
//! **Zig 가 직접 띄운다**(사용자 결정 2026-09-24 — `lsp_process.zig` 선례): fork·execve 로 띄우고, 비차단 파이프를 창
//! tick 에서 비운다. Mermaid helper 는 Swift 가 띄우는데 그 이유(Security.framework 서명 검증)는 배포(W7) 때 필요하다.
//!
//! **켜는 법**: 설정 `browser.engine = chromium`(W4d — `maru-chromium` 설치가 있어야 한다, 앱을 다시 시작해야 적용)
//! 또는 개발용 `MARU_WEB_OSR_DIR=<설치 디렉터리>`(`zig build web-sidecar` 의 `zig-out/web-sidecar` — 환경변수가 먼저).
//!
//! 수명: 첫 OSR 탭이 보이면 띄우고, 마지막 브라우저가 파괴되면 내린다. 죽으면 다시 띄워 살아 있던 탭을 다시 만든다 —
//! 60 초 안에 세 번 죽으면 멈추고 안내한다(Mermaid 와 같은 예산). 같은 프로필을 다른 maru 가 쓰면(`profile_in_use`)
//! 다시 띄우지 않는다. **메인 스레드 전용**(창 tick 과 ABI 가 모두 메인).

const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const lsp_process = @import("lsp_process.zig");
const install = @import("web_osr_install.zig");
const ring_receiver = @import("web_sidecar/ring_receiver.zig");
const iosurface = @import("web_sidecar/iosurface.zig");

const ws = maru.session.web_sidecar;
const web_downloads = @import("web_downloads.zig");
/// W10b: 세션(app_session/web.zig)이 다운로드 「매번 묻기」를 다룬다.
pub const downloads = web_downloads;
const plan = maru.session.web_osr_plan;
const mailbox = ws.mailbox;
const osr_input = maru.session.web_osr_input;

/// 링 하나(W3c): 받은 IOSurface 셋·제어 페이지와, View 가 보는 세대·mailbox 워드.
pub const AppRing = struct {
    generation: u32,
    control: *mailbox.Control,
    width: u32,
    height: u32,
    ring: ring_receiver.Ring,

    fn release(self: AppRing) void {
        self.ring.release();
    }
};

const RingView = maru.session.web_osr_view.View(AppRing);

/// 그릴 front 하나(창 좌표는 호출자가 안다).
pub const Front = struct {
    surface: iosurface.Ref,
    width: u32,
    height: u32,
};
const Message = ws.message.Message;
const FailureCode = ws.message.FailureCode;

pub const State = enum { off, starting, running, failed };

/// 창이 사용자에게 보일 안내. 표시 문구는 창이 i18n 으로 만든다(여기는 코드만).
pub const Notice = enum { gpu_unavailable, profile_in_use, start_failed, crashed_repeatedly, version_mismatch };

pub const NavUpdate = struct {
    surface_id: u64,
    url: []const u8,
    can_go_back: bool,
    can_go_forward: bool,
};

const restart_window_ms: i64 = 60_000;
const restart_budget = 3;
const handshake_timeout_ms: i64 = 15_000;
const shutdown_wait_ms: i64 = 3_000;

const Surface = struct {
    record: plan.Record,
    /// sidecar 가 이 브라우저를 만들었다고 답했다(그 전 명령은 CEF 가 모르는 id 라 보내지 않고 쥔다).
    created: bool = false,
    /// 마지막으로 이동시킨 주소 — sidecar 가 다시 뜨면 이 주소로 되살린다. 이동을 CEF 가 끝내면 `url` 이 된다.
    last_url: ?[]u8 = null,
    url: ?[]u8 = null,
    can_go_back: bool = false,
    can_go_forward: bool = false,
    nav_dirty: bool = false,
    gpu_notice_pending: bool = false,
    /// 엔진이 멈췄다는 안내(`latched`)를 이 탭의 창이 아직 안 보였다 — 멈출 때 열려 있던 탭과 멈춘 뒤 새로 연 탭에 한 번씩
    /// 건다(W7a1 7 차 적대 검증 — 앱 전체 안내 하나는 Chromium 탭과 무관한 창에 한 번만 떴고, 새 탭은 빈 채 단서가 없었다).
    stopped_notice_pending: bool = false,
    /// 보일 링 고르기(W3c) — 새 링의 첫 프레임까지 옛 장, GPU 소비자 규칙.
    view: RingView = .{},
    /// 마지막으로 이 front 를 그린 창(AppSession 주소). 프레임 세대는 창마다 따로 세므로 다른 창의 세대와 비교하지 않는다.
    drawn_by: usize = 0,
    /// 페이지가 원하는 커서(W4b). sidecar 는 같은 커서를 다시 보내지 않으므로 maru 가 기억한다 — 포인터가 나갔다 다시
    /// 들어와도 이 값을 쓴다. 세대는 바뀔 때마다 올라, 창이 hover 중인 탭의 커서가 바뀐 것을 안다.
    cursor: ws.message.WebCursor = .arrow,
    cursor_generation: u32 = 0,
    /// 키 포커스를 줘야 하는가(W4c — 창이 정한 키 대상). sidecar 가 다시 떠 브라우저를 새로 만들면 이 값으로 되살린다.
    focused: bool = false,
    /// 포커스를 준 창(AppSession 주소) — 탭이 다른 창으로 옮긴 뒤 옛 창의 늦은 「포커스 놓기」가 새 창의 포커스를 덮지 않게.
    focus_owner: usize = 0,
    /// 페이지에 조합이 열려 있다고 보는가(W4c). maru 가 보낸 조합 메시지로 세고, 페이지가 조합을 끝내는 자리(이동·포커스
    /// 잃음·브라우저 재생성)에서 푼다. **조합이 없을 때의 조합 취소는 선택한 글을 지운다**(Chromium — 판정자
    /// `input-ime-cancel-idle`) — 그래서 취소는 이 값이 참일 때만 보낸다. CEF 는 조합이 끝날 때 알려 주지 않는다(실측).
    composing: bool = false,
    /// 마지막 IME 조합 사각형(view DIP — `ime_range`). 후보창 위치(`firstRect`)에 쓴다.
    ime_bounds: ?ws.message.Rect = null,
    /// 열린 팝업 위젯(`<select>` 목록 등)의 view DIP 사각형(W6a — D4). 닫혔으면 null. 그리기는 W6a②.
    popup_bounds: ?ws.message.Rect = null,
    /// 열린 팝업의 링 첫 세대 — 이보다 작은 세대의 팝업 링은 닫히기 직전 팝업의 것이다(W6a②). **그릴 때** 거른다 — 링(mach)이
    /// 보임 알림(파이프)보다 한 tick 먼저 올 수 있어, 받을 때 거르면 다시 알리지 않는 첫 링을 잃는다(W6a① 적대 검증 3 차).
    /// 링 크기가 사각형 × scale(±1)인지도 본다 — 열린 A 위로 B 가 열릴 때 A 의 늦은 그림이 B 의 첫 세대로 실려도 A 와 B 의
    /// 크기가 다르면 걸러진다(같은 크기는 못 거른다 — CEF 154 에서 관측되지 않았다. sidecar 의 `popup_open` 은 A 의 닫힘과 B 의
    /// 열림 사이에 온 그림만 막는다. W6a① 적대 검증 5~7 차 — 판정 `popup-frame` 이 쓰는 조건). 브라우저가 닫혀도(`browser_closed`)
    /// 닫힘 알림은 오지 않는다 — 그때도 지운다(`dropPopup`).
    popup_first_generation: u32 = 0,
    /// 페이지의 지금 툴팁 글(W6b — 비었으면 null)과 바뀔 때마다 오르는 세대. 창이 세대로 바뀐 것을 안다(꺼내 가지 않는다 — 창이
    /// 여럿이어도 한 창이 먹어 버리지 않게).
    tooltip_text: ?[]u8 = null,
    tooltip_generation: u32 = 0,
    /// sidecar 가 알린 우클릭 메뉴(W6c② — 하나). 그 탭이 보이는 창의 tick 이 가져가 macOS 메뉴로 띄운다.
    context_menu: ?ContextMenu = null,
    /// 페이지의 제안 목록(W6m② — `datalist_show`, 하나). 닫히면(`datalist_hide`·고름·Esc·브라우저·sidecar 가 사라짐) null.
    /// 바뀔 때마다 새 세대를 받는다(`nextDatalistGeneration` — 앱 전체에서 겹치지 않는다) — 창이 강조를 처음으로 되돌리고 띄운 목록을
    /// 다시 싣는다.
    datalist: ?Datalist = null,
    datalist_generation: u32 = 0,
    /// 마지막으로 이 탭에 보낸 사용자 입력(누름·키·조합·편집 명령 — 단조 ms). 제안 목록은 그 뒤 `datalist_user_window_ms` 안에서만
    /// 받는다 — 대리 스크립트도 사용자 사건에만 보이기를 보내지만, 페이지가 그 경로를 흉내 내도(알림용 `send` 가 남은 첫 문서·
    /// `execCommand` 의 `input`) 사용자가 손대지 않은 네이티브 창이 뜨지 않게(W6m② 적대 검증 4 차).
    last_user_input_ms: i64 = std.math.minInt(i64) / 2,
    /// 주 프레임에 새 문서가 마지막으로 커밋된 때(W10a — `page_started`) — 그 전의 누름은 새 문서가 시작한 다운로드의 「사용자
    /// 동작」이 아니다(누른 링크가 연 페이지가 3 초 안에 실행 파일을 받게 하면 보류를 비켜 갔다 — 적대 리뷰 1 회차). 주소 알림
    /// (`url_changed`)으로 세우면 32 KiB 를 넘는 주소는 알림이 없어 비켜 갔고(2 회차), pushState 도 이동으로 쳤다.
    last_nav_ms: i64 = std.math.minInt(i64) / 2,
    /// 다운로드만의 사용자 동작(W10a) — 주소창 이동·연 탭에서 물려받은 누름. 페이지 입력(`last_user_input_ms`)과 따로 둔다: 그쪽은
    /// 제안 목록 막음(W6m②)도 쓰는데, 주소창으로 연 페이지·팝업이 손대지 않은 채 목록을 띄울 수 있게 됐다(적대 리뷰 4 회차).
    download_gesture_ms: i64 = std.math.minInt(i64) / 2,
    /// 밖에서 끌어 온 것이 이 탭 본문에 들어와 sidecar 에 enter 를 보냈고 아직 leave·drop 하지 않았다(W6d①). sidecar 가 다시 뜨거나
    /// 브라우저가 닫히면 푼다 — 새 sidecar 는 그 끌기를 모른다.
    drag_entered: bool = false,
    /// 이 끌기에서 페이지가 받아들이는 동작(`drag_operation` — 0 이면 놓아도 받지 않는다). enter 에서 0 으로 시작한다.
    drag_operation: u32 = 0,
    /// 페이지가 시작한 끌기(W6d② — `drag_out`). 조각을 모으다가 `drag_out` 이 오면 창이 가져가 macOS 끌기 세션으로 돌린다.
    drag_out: ?DragOut = null,
    /// 팝업 링의 보일 장 고르기(W6a②) — 본문과 같은 규칙(GPU 소비자 규칙·기대 크기 = 사각형 × scale). 닫혀도 곧바로
    /// 비우지 않는다: A 닫힘 알림을 처리하기 전에 B 의 링이 먼저 와 있을 수 있어, 닫힐 때 다 놓으면 다시 알리지 않는 B 의
    /// 링을 잃는다(1 차). 닫힐 때 보이던 링만 GPU 가 끝난 뒤 놓는다(`popup_release_generation` — 4 차).
    popup_view: RingView = .{},
    /// 닫힐 때 보이던 팝업 링의 세대(0 = 없음) — 그 링이 아직 보이는 링이고 기다리는 링이 없으면 GPU 가 끝난 뒤 놓는다.
    popup_release_generation: u32 = 0,
    /// 팝업 front 를 마지막으로 그린 창(본문의 `drawn_by` 와 따로 — 본문만 그린 다른 창의 세대와 비교하지 않게).
    popup_drawn_by: usize = 0,
    /// 팝업이 열리거나 닫혔다 — 새 프레임이 없어도 창을 다시 그린다(정적 페이지에서 닫힌 목록이 남거나, 링이 알림보다 먼저
    /// 와 첫 장을 이미 꺼낸 뒤 열린 목록이 안 보이지 않게 — W6a② 적대 검증 1 차). `pollFrame` 이 소비한다.
    popup_redraw: bool = false,
    /// 답을 기다리는 대화상자·파일 선택(W5a)·권한 요청(W5b) — 온 차례대로.
    dialogs: std.ArrayList(Dialog) = .empty,
    /// 아직 maru 알림으로 내보내지 않은 웹 알림(W5c) — 온 차례대로, 탭마다 `max_notes_per_surface` 까지(넘치면 오래된 것부터 버린다).
    notes: std.ArrayList(WebNote) = .empty,
    /// 페이지가 연 새 탭(W6e — `open_tab`) — 온 차례대로, `max_new_tabs` 까지. 그 탭이 있는 창의 tick 이 하나씩 꺼내 간다.
    new_tabs: std.ArrayList(NewTab) = .empty,
    /// 그 팝업을 연 탭(W6f② — 페이지가 닫으면 그 탭으로 돌아간다. Chrome 처럼).
    popup_opener: u64 = 0,
    /// 페이지가 그 브라우저를 닫았다(maru 가 닫지 않았다 — `window.close`) — 그 탭이 있는 창이 꺼내 가 탭을 닫는다(`takePageClosed`).
    page_closed: bool = false,
    /// 새 탭 한 장(W6e) — maru 가 이 탭에 보낸 누름·Esc 아닌 키 누름, 또는 메뉴의 「새 탭에서 링크 열기」·「새 탭에서 이미지 열기」(W6h①) 답이 준다. sidecar 의 `open_tab`
    /// 하나가 쓴다 — sidecar 도 같은 규칙을 지키지만 maru 는 sidecar 가 보낸 것을 그대로 믿지 않는다(W6e 적대 검증 2 차).
    new_tab_credits: ws.new_tab.Credits = .{},
    /// 새 창 한 장(W6h①) — 메뉴 「새 창에서 링크 열기」 답만 준다(그때의 단조 시각 ms, 0 은 없음). 자리가 `new_window` 인 `open_tab`
    /// 하나가 쓴다 — 페이지 입력의 새 탭 장으로는 새 창을 받지 않는다(sidecar 가 새 창 자리를 보내도). 한 칸이다 — sidecar 의 답이 오기
    /// 전에 같은 탭에서 또 고르면 앞 것은 쓰지 못한다(드물다 — W6h① 적대 검증에서 받아들임).
    new_window_credit_ms: i64 = 0,
    /// 사용자의 닫기를 페이지에 물었다(W6j — `askClose`). 창이 `takeCloseAsk` 로 결과를 꺼내 그 탭을 닫거나 둔다.
    close_ask: CloseAsk = .none,
    /// 물은(떠나기를 고른 뒤에는 그) 단조 시각 ms — 질문도 닫힘도 없이 `close_ask_wait_ms` 가 지나면 강제로 닫는다.
    close_ask_since_ms: i64 = 0,
    /// 물은 닫기를 닫기 대신 about:blank 이동으로 보냈다(W10c — 받던 다운로드가 있다. 닫으면 Chromium 이 받기를 끊는다). 떠나기
    /// 확인은 이동에도 같게 온다 — 새 문서(`page_started`)가 오면 닫힌 것으로 본다. 탭이 사라지면 브라우저는 숨겨 남긴다(`parked`).
    close_park: bool = false,
    /// 페이지가 연 탭(W10c — 이어 받은 팝업·`open_tab` 의 새 탭). 문서 없이(주소가 없거나 about:blank) 다운로드만 하면 창이 그 탭을
    /// 닫는다(Chrome 처럼).
    page_opened: bool = false,
    /// 문서도 사용자 입력도 없이 다운로드만 한 페이지가 연 탭(W10c) — 그 탭이 있는 창이 꺼내 가 닫는다(`takeDownloadBlank`).
    download_blank: bool = false,
};

/// 페이지에 물은 닫기의 진행(W6j).
const CloseAsk = enum {
    none,
    /// 물었다 — 질문(`before_unload`)이나 닫힘을 기다린다(시한이 있다).
    asking,
    /// 페이지가 물었다 — 사용자가 답할 때까지 기다린다(시한이 없다).
    asked,
    /// 닫혔다(묻지 않는 페이지·떠나기) — 창이 그 탭을 닫는다.
    closed,
    /// 머물렀다 — 창이 한 번 본다(보고).
    stayed,
};

/// 창이 꺼내는 결과(W6j — `takeCloseAsk`).
pub const CloseAskOutcome = enum { none, waiting, closed, timed_out, stayed };

/// 물은 뒤 질문도 닫힘도 없을 때 기다리는 시간(W6j). 묻지 않는 페이지는 수 ms 안에 닫히고(실측 1~14 ms) 떠나기 확인은 곧바로 온다 —
/// 떠나기 확인 처리기가 멈춘 페이지는 CEF 가 끝없이 기다려(실측 20 초 처리기에 20 초) maru 가 강제로 닫는다.
pub const close_ask_wait_ms: i64 = 2000;

/// 페이지가 연 새 탭 하나(W6e). 주소는 걸렀다(`new_tab.urlAllowed`) — 꺼내 간 쪽이 놓는다.
pub const NewTab = struct {
    url: []u8,
    placement: ws.message.NewTabPlacement,
    arrived_ms: i64,
    /// 0 이 아니면 이미 도는 팝업 브라우저(W6f② — 그 번호로 탭을 붙인다, 주소는 싣지 않는다). 붙이지 못하면 `abandonPopup`.
    adopt: u64 = 0,
};

// ── W6f②: 팝업 이어 받기 ─────────────────────────────────────────────────────────────────────────────────
// sidecar 가 돌면 쓰지 않은 번호를 `popup_reserve_target` 개 맡겨 둔다(창 tick 이 앱 전역 발급기에서 떼어 준다). 그 번호의 링이
// `popup_created` 보다 먼저 오면 쥐어 둔다 — 링은 다시 알려지지 않는다(W6f① 적대 검증). 팝업이 오면 그 번호의 기록을 「만들어짐」으로
// 두고 연 탭의 새 탭 줄에 붙일 번호로 넣는다. 붙이지 못한 팝업(만료·연 탭 사라짐·창이 못 만듦)은 `orphan_popups` 로 미뤄 pump 가
// 닫는다(표를 도는 중에 지우지 않게).
const popup_reserve_target = 2;
const ReservedPopup = struct { id: u64, ring: ?AppRing = null };
var popup_reserved: [ws.message.max_popup_reserve]ReservedPopup = undefined;
var popup_reserved_len: usize = 0;
var orphan_popups: std.ArrayList(u64) = .empty;

/// 탭마다 쥐는 새 탭 상한 — sidecar 는 사용자 입력 하나에 하나만 보내므로 넘칠 일이 없다. 넘치면 새 것을 버린다.
const max_new_tabs = 4;
/// 이 안에 아무 창도 꺼내 가지 않으면 버린다 — 연 탭이 사라졌거나 창이 멈췄다. 한참 뒤 탭이 갑자기 생기지 않게.
const new_tab_pickup_ms = 5_000;

pub const Cursor = struct { cursor: ws.message.WebCursor, generation: u32 };

/// 답을 기다리는 JS 대화상자·파일 선택(W5a)·권한 요청(W5b) — C6. 글은 복사해 쥔다(sidecar 가 보낸 frame 은 곧 사라진다).
pub const DialogKind = enum(u32) {
    alert = 0,
    confirm = 1,
    prompt = 2,
    before_unload = 3,
    file_open = 10,
    file_open_multiple = 11,
    file_open_folder = 12,
    file_save = 13,
    permission = 20,

    pub fn isFile(self: DialogKind) bool {
        return @intFromEnum(self) >= 10 and @intFromEnum(self) <= 13;
    }
};

pub const Dialog = struct {
    /// maru 가 매기는 번호(프로세스 전체에서 한 번씩) — 창·Swift 는 이것으로 짝을 찾는다. sidecar 의 요청 번호는 sidecar 가
    /// 다시 뜨면 1 부터 다시 매겨 옛 창의 늦은 답이 새 요청에 붙을 수 있다(적대 검증).
    token: u64,
    request: ws.message.RequestId,
    kind: DialogKind,
    origin: []u8,
    message: []u8,
    /// `prompt` 의 기본 글, 파일 선택이면 처음 고를 경로.
    default_text: []u8,
    /// 파일 선택이 받을 형식(`image/*,.png`).
    accept: []u8,
    /// 이 페이지가 이동 없이 두 번째 이상 띄운 대화상자 — 「더 띄우지 못하게」를 보인다.
    offer_suppress: bool = false,
    /// 권한 요청(W5b)이 청한 종류 — 둘 중 하나만 찬다(`ws.message.PermissionRequest`).
    permission_kinds: u32 = 0,
    permission_media: u8 = 0,
    /// W5b2: 사용자가 이미 허용한 출처의 위치 요청 — sheet 없이 좌표만 구해 답한다(`nextLocation`). 초점·창 sheet 와 무관하다.
    remembered: bool = false,
    /// W5b2: 답을 기다리는 사이 사용자가 그 출처의 위치를 차단했다 — 허용으로 답하지 않는다(`revokeLocationOrigin`).
    revoked: bool = false,
    /// 띄운 창(AppSession 주소) — 0 이면 아직 안 띄웠다.
    shown_by: usize = 0,

    fn free(self: Dialog, gpa: std.mem.Allocator) void {
        gpa.free(self.origin);
        gpa.free(self.message);
        gpa.free(self.default_text);
        gpa.free(self.accept);
    }
};

/// 한 브라우저가 동시에 기다리게 하는 상한. JS 대화상자는 페이지가 멈춰 하나씩이고 파일 선택도 하나씩이라 넉넉하다 —
/// 넘으면 곧바로 취소로 답한다(sidecar 가 쥔 콜백이 쌓이지 않게).
const max_dialogs_per_surface = 4;

/// 웹 알림 한 건(W5c). 글은 sidecar 가 대화상자 글 규칙으로 다듬었다 — maru 알림 경로가 한 번 더 다듬는다.
pub const WebNote = struct {
    /// maru 가 매긴 번호 — 알림(배너 userInfo·목록)이 들고 있다가 누르면 이것으로 짝을 찾는다. 시작값이 무작위라 옛 프로세스의
    /// 배너가 새 프로세스의 다른 알림을 누르지 못한다.
    token: u64,
    surface_id: u64,
    /// sidecar 가 매긴 번호(누를 때 돌려준다). 0 이면 누를 수 없는 알림.
    notification: u32,
    origin: []u8,
    title: []u8,
    body: []u8,

    pub fn free(self: WebNote, gpa: std.mem.Allocator) void {
        gpa.free(self.origin);
        gpa.free(self.title);
        gpa.free(self.body);
    }
};
const max_notes_per_surface = 8;
var next_note_token: u64 = 0;
/// 내보낸 알림 → (탭, sidecar 번호) — 누를 때 찾는다. 최근 64 개.
const ShownNote = struct { token: u64, surface_id: u64, notification: u32 };
var shown_notes: [64]?ShownNote = [_]?ShownNote{null} ** 64;
var shown_notes_next: usize = 0;

fn queueNote(gpa: std.mem.Allocator, v: ws.message.WebNotification) void {
    const s = surfaces.getPtr(v.browser) orelse return;
    if (s.notes.items.len >= max_notes_per_surface) s.notes.orderedRemove(0).free(gpa);
    if (next_note_token == 0) {
        arc4random_buf(@ptrCast(&next_note_token), @sizeOf(u64));
        next_note_token |= 1;
    }
    const origin = gpa.dupe(u8, v.origin) catch return;
    const title = gpa.dupe(u8, v.title) catch {
        gpa.free(origin);
        return;
    };
    const body = gpa.dupe(u8, v.body) catch {
        gpa.free(origin);
        gpa.free(title);
        return;
    };
    const note: WebNote = .{ .token = next_note_token, .surface_id = v.browser, .notification = v.notification, .origin = origin, .title = title, .body = body };
    next_note_token +%= 1;
    if (next_note_token == 0) next_note_token = 1;
    s.notes.append(gpa, note) catch note.free(gpa);
}

/// 그 탭의 다음 웹 알림(소유권은 호출자 — `WebNote.free`). 내보낸 것으로 적는다(누를 수 있게).
pub fn takeWebNotification(surface_id: u64) ?WebNote {
    const s = surfaces.getPtr(surface_id) orelse return null;
    if (s.notes.items.len == 0) return null;
    const note = s.notes.orderedRemove(0);
    if (note.notification != 0) {
        shown_notes[shown_notes_next] = .{ .token = note.token, .surface_id = surface_id, .notification = note.notification };
        shown_notes_next = (shown_notes_next + 1) % shown_notes.len;
    }
    return note;
}

/// 사용자가 maru 알림을 눌렀다 — 그 탭의 그 알림이면 sidecar 에 알린다(페이지의 `onclick`). 모르는 번호·다른 탭이면 무동작.
pub fn clickWebNotification(gpa: std.mem.Allocator, surface_id: u64, token: u64) void {
    if (token == 0) return;
    for (shown_notes) |slot| {
        const note = slot orelse continue;
        if (note.token != token or note.surface_id != surface_id) continue;
        const s = surfaces.getPtr(surface_id) orelse return;
        if (s.created) send(gpa, .{ .web_notification_click = .{ .browser = surface_id, .notification = note.notification } });
        return;
    }
}

fn dropNotes(gpa: std.mem.Allocator, s: *Surface) void {
    for (s.notes.items) |n| n.free(gpa);
    s.notes.clearRetainingCapacity();
}
var next_dialog_token: u64 = 1;

/// W5b2: 이 실행 동안 사용자가 **maru 의 sheet 에서** 위치를 허용한 (탭, 출처). sidecar 의 `remembered` 는 믿지 않는다 —
/// sidecar 는 신뢰할 수 없는 웹의 뿌리라, 그 표시 하나로 sheet 를 건너뛰면 장악된 sidecar 가 Maru 의 macOS 위치 권한으로 좌표를
/// 조용히 빼 갈 수 있다(적대 검증). 출처만이 아니라 허용한 **탭**에 묶는다 — 장악된 sidecar 가 다른 탭 번호로 그 출처를 흉내 내도
/// sheet 로 묻는다(2 차 적대 검증). 탭이 닫히면 그 탭의 기록이 지워지고, 차단하면 그 출처의 기록을 모든 탭에서 뺀다. 앱을 다시
/// 띄우면 비어 첫 요청은 다시 묻는다. 키는 `<탭 번호>\x00<출처>`.
var location_allowed: std.StringArrayHashMapUnmanaged(void) = .empty;
const max_location_allowed = 256;

fn locationKey(buf: []u8, surface_id: u64, origin: []const u8) ?[]const u8 {
    if (origin.len == 0) return null;
    return std.fmt.bufPrint(buf, "{d}\x00{s}", .{ surface_id, origin }) catch null;
}

fn locationAllowed(surface_id: u64, origin: []const u8) bool {
    var buf: [ws.fields.max_origin_bytes + 32]u8 = undefined;
    const key = locationKey(&buf, surface_id, origin) orelse return false;
    return location_allowed.contains(key);
}

fn allowLocation(gpa: std.mem.Allocator, surface_id: u64, origin: []const u8) void {
    var buf: [ws.fields.max_origin_bytes + 32]u8 = undefined;
    const key = locationKey(&buf, surface_id, origin) orelse return;
    if (location_allowed.contains(key) or location_allowed.count() >= max_location_allowed) return;
    const owned = gpa.dupe(u8, key) catch return;
    location_allowed.put(gpa, owned, {}) catch gpa.free(owned);
}

/// 차단 — 그 출처의 기록을 모든 탭에서 뺀다(Chromium 도 출처 단위로 차단을 기억한다).
fn forgetLocationOrigin(gpa: std.mem.Allocator, origin: []const u8) void {
    var i: usize = 0;
    while (i < location_allowed.count()) {
        const key = location_allowed.keys()[i];
        const sep = std.mem.indexOfScalar(u8, key, 0) orelse unreachable;
        if (std.mem.eql(u8, key[sep + 1 ..], origin)) {
            location_allowed.swapRemoveAt(i);
            gpa.free(key);
        } else i += 1;
    }
}

/// 탭이 사라졌다 — 그 탭의 기록을 뺀다(탭 번호가 다시 쓰여도 옛 허용이 붙지 않게).
fn forgetLocationSurface(gpa: std.mem.Allocator, surface_id: u64) void {
    var prefix_buf: [32]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "{d}\x00", .{surface_id}) catch return;
    var i: usize = 0;
    while (i < location_allowed.count()) {
        const key = location_allowed.keys()[i];
        if (std.mem.startsWith(u8, key, prefix)) {
            location_allowed.swapRemoveAt(i);
            gpa.free(key);
        } else i += 1;
    }
}

/// 사용자가 그 출처의 위치를 차단했다 — 답을 기다리던 같은 출처의 위치 요청(좌표를 구하는 중인 허용 포함)은 허용으로 답하지
/// 않는다. 늦게 온 허용이 나중의 차단을 덮어쓰지 않게(Chromium 의 저장값은 마지막 답이다 — 2 차 적대 검증).
fn revokeLocationOrigin(origin: []const u8, except_token: u64) void {
    for (surfaces.values()) |*s| {
        for (s.dialogs.items) |*d| if (d.token != except_token and d.kind == .permission and
            d.permission_kinds & ws.message.PermissionKind.geolocation.bit() != 0 and std.mem.eql(u8, d.origin, origin))
        {
            d.revoked = true;
        };
    }
}

/// 시험용 — 기록한 출처를 모두 비운다.
fn forgetAllLocations(gpa: std.mem.Allocator) void {
    for (location_allowed.keys()) |key| gpa.free(key);
    location_allowed.deinit(gpa);
    location_allowed = .empty;
}

var gpa_ref: ?std.mem.Allocator = null;
var state: State = .off;
var process: ?lsp_process.Process = null;
/// shutdown 을 보내고 끝나기를 기다리는 옛 sidecar(마지막 탭을 닫았다). tick 이 거두고, 기한을 넘으면 죽인다 — 탭을 닫는
/// 메인 스레드를 막지 않는다(처음엔 최대 3 초 막았다 — 적대 검증).
var retiring: ?lsp_process.Process = null;
var retiring_since_ms: i64 = 0;
/// 그 sidecar 들이 도는 실행 사본(W7a2) — 프로세스를 거둔 뒤에 놓는다(물러나는 sidecar 의 사본을 새 sidecar 가 지우지 않게).
var run_copy: ?install.RunCopy = null;
var retiring_copy: ?install.RunCopy = null;
var decoder: ws.stream.StreamingDecoder = .init(.to_maru);
var inbox: std.ArrayList(u8) = .empty;
var outbox_pending: std.ArrayList(u8) = .empty; // handshake 전 명령(인코딩된 frame)
var surfaces: std.AutoArrayHashMapUnmanaged(u64, Surface) = .empty;
/// 탭은 닫혔지만 받던 다운로드가 끝나지 않아 숨겨 남긴 브라우저(W10c — 주차). 그 페이지는 about:blank 로 보냈다(소리·스크립트가
/// 멈춘다). maru 에는 그 탭이 없으니 그 브라우저의 대화상자·권한·새 탭·다운로드는 「모르는 브라우저」로 곧바로 거절된다(떠나기
/// 확인은 떠나기). 다운로드가 모두 끝나면 `releaseParked` 가 닫는다. sidecar 를 잃으면 비운다(다운로드도 함께 끝났다).
var parked: std.AutoArrayHashMapUnmanaged(u64, void) = .empty;
/// 페이지가 연 새 탭으로 만들 번호(W10c — `open_tab` 의 새 탭은 배치가 와야 기록이 생긴다. 생기면 `page_opened` 로 옮긴다).
var page_opened_pending: [16]u64 = @splat(0);
var page_opened_next: usize = 0;
var hello_nonce: u64 = 0;
var started_ms: i64 = 0;
var failures: [restart_budget]?i64 = @splat(null);
/// 띄울 때마다 오른다 — 파이프를 비우는 도중 sidecar 가 죽어 다시 띄우면(받은 바이트를 지운다) 비우던 쪽이 멈춘다.
var process_generation: u64 = 0;
var failure_head: usize = 0;
/// 픽셀 링을 받는 mach port(W3c). sidecar 가 바뀌어도 하나를 계속 쓴다 — 기대 pid 와 pid 버전 고정만 새로 한다.
var receiver: ?ring_receiver.Receiver = null;
/// 받은 링 알림 중 거절한 수(관측점 — 이름은 비밀이 아니라 아무나 넣을 수 있다).
var rejected_rings: u64 = 0;
var latched: ?Notice = null;

/// 엔진 결정(W4d — 프로세스에 한 번, 재시작 후 적용). 첫 창이 설정을 읽은 뒤 `decide` 로 정한다. 개발용 환경변수
/// `MARU_WEB_OSR_DIR` 가 먼저고, 아니면 설정 `browser.engine = chromium` 이고 `maru-chromium` 이 설치돼 있을 때 켠다.
var decided: ?bool = null;
/// 결정할 때 설정이 청한 값(chromium 이면 true) — 설정이 바뀌면 「재시작하면 적용」을 한 번 알린다.
var requested_chromium: bool = false;
var last_change_notice: ?bool = null;
var install_notice_pending = false;
var install_buf: [512]u8 = undefined;
var install_len: usize = 0;
/// `findInstall` 이 찾은 설치의 brew prefix.
var install_prefix_buf: [512]u8 = undefined;
var install_prefix_len: usize = 0;

/// `maru-chromium` formula 설치 위치 후보(`$(brew --prefix)/opt/maru-chromium/libexec` — 계획 문서 「배포·배치」).
/// 개발 판은 `HOMEBREW_PREFIX` 가 있으면 그 prefix 를 먼저 본다(brew shellenv 가 세운다 — 스모크도 이것으로 가짜 설치를 가리킨다).
/// 릴리스 판(hardened runtime)은 이 두 후보만 본다(W7a2 — `findInstallFor`).
const install_candidates = [_][]const u8{
    "/opt/homebrew",
    "/usr/local",
};

/// 엔진 결정 규칙(순수 — 시험한다): 개발용 환경변수가 먼저, 설정이 chromium 을 청하고 설치가 있으면 그 설치, 청했는데
/// 설치가 없으면 WebKit + 안내.
pub const Decision = struct { chromium: bool, dir: ?[]const u8 = null, not_installed: bool = false };

pub fn decideFrom(config_wants_chromium: bool, env_dir: ?[]const u8, installed_dir: ?[]const u8) Decision {
    if (env_dir) |dir| return .{ .chromium = true, .dir = dir };
    if (!config_wants_chromium) return .{ .chromium = false };
    if (installed_dir) |dir| return .{ .chromium = true, .dir = dir };
    return .{ .chromium = false, .not_installed = true };
}

/// 첫 창이 설정을 읽은 뒤 부른다(두 번째부터는 무동작).
pub fn decide(config_wants_chromium: bool) void {
    if (decided != null) return;
    requested_chromium = config_wants_chromium;
    const env = envDir();
    const d = decideFrom(config_wants_chromium, env, if (config_wants_chromium) findInstall() else null);
    // 환경변수 경로는 복사하지 않는다(`installDir` 가 그대로 읽는다 — 길이 제한 없이). 설치 경로는 findInstall 이 상한 안에서 만든다.
    if (env == null) if (d.dir) |dir| setInstall(dir);
    decided = d.chromium;
    install_notice_pending = d.not_installed; // 청했는데 설치가 없다 — 한 번 안내하고 WebKit 으로
    const log = std.log.scoped(.web_osr);
    if (d.not_installed) log.warn("browser.engine = chromium but maru-chromium is not installed — using WebKit", .{});
    if (d.chromium) log.info("browser engine: chromium ({s})", .{installDir() orelse "?"});
    // 지난 실행이 남긴 사본을 지운다 — WebKit 으로 돌아갔어도(W7a2 적대 검증 1 차: 청소할 기회가 영영 없었다).
    if (!builtin.is_test) {
        var cache_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (install.runCacheRoot(&cache_buf, install.hardenedRuntime())) |root| install.sweepRunCopies(root);
    }
}

test "closing the last Chromium tab ends its downloads instead of leaving them active (W10a)" {
    web_downloads.testReset();
    defer web_downloads.testReset();
    try web_downloads.testAddActive(1, 7);
    try std.testing.expectEqual(@as(usize, 1), web_downloads.activeTotal());
    retire(std.testing.allocator, 0); // 마지막 탭을 닫아 sidecar 를 내린다(여기서는 프로세스가 없다 — 상태만)
    try std.testing.expectEqual(@as(usize, 0), web_downloads.activeTotal());
}

/// 시험 전용 — 돌고 있는(`running`) 채 프로세스 없이 보낸 것을 outbox 에 쌓는다(`sentFrames` 로 본다).
var test_record_sends = false;

fn testSurfaces(gpa: std.mem.Allocator, ids: []const u64) !void {
    for (ids) |id| try surfaces.put(gpa, id, .{ .record = .{ .surface_id = id, .size = .{ .width = 300, .height = 200, .scale = 2 }, .hidden = false }, .created = true });
}

fn testTeardown(gpa: std.mem.Allocator) void {
    for (surfaces.values()) |*s| freeSurface(gpa, s);
    surfaces.deinit(gpa);
    surfaces = .empty;
    parked.deinit(gpa);
    parked = .empty;
    outbox_pending.clearAndFree(gpa);
    state = .off;
    test_record_sends = false;
}

test "closing a tab that is still downloading hides it on about:blank and closes it once the downloads end (W10c)" {
    const gpa = std.testing.allocator;
    web_downloads.testReset();
    defer web_downloads.testReset();
    state = .starting; // 보낸 frame 을 outbox 에 쌓게(sidecar 없이)
    defer testTeardown(gpa);
    try testSurfaces(gpa, &.{ 7, 8 });
    try web_downloads.testAddActive(1, 7);
    destroy(gpa, 7);
    destroy(gpa, 8); // 받는 것이 없는 탭은 곧바로 닫는다
    var sent: [8]Message = undefined;
    var n = sentFrames(&sent);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqual(@as(u64, 7), sent[0].set_focus.browser);
    try std.testing.expect(!sent[0].set_focus.value);
    try std.testing.expect(sent[1].set_hidden.browser == 7 and sent[1].set_hidden.value);
    try std.testing.expect(sent[2].navigate.browser == 7 and std.mem.eql(u8, sent[2].navigate.url, "about:blank"));
    try std.testing.expectEqual(@as(u64, 8), sent[3].destroy_browser);
    // 탭이 하나도 없어도 sidecar 를 내리지 않는다 — 내리면 받던 것이 끊긴다.
    try std.testing.expectEqual(@as(usize, 1), parkedCount());
    try std.testing.expectEqual(State.starting, state);
    try std.testing.expectEqual(@as(usize, 1), web_downloads.activeTotal());
    releaseParked(gpa, 0); // 아직 받는다 — 그대로
    try std.testing.expectEqual(@as(usize, 1), parkedCount());
    outbox_pending.clearRetainingCapacity();
    web_downloads.testFinish(1);
    releaseParked(gpa, 0);
    n = sentFrames(&sent);
    try std.testing.expect(n >= 1);
    try std.testing.expectEqual(@as(u64, 7), sent[0].destroy_browser);
    try std.testing.expectEqual(@as(usize, 0), parkedCount());
    try std.testing.expectEqual(State.off, state); // 마지막이었다 — sidecar 를 내렸다
}

test "a page-asked close of a downloading tab goes to about:blank and closes on the new document unless the user stays (W10c)" {
    const gpa = std.testing.allocator;
    web_downloads.testReset();
    defer web_downloads.testReset();
    state = .running; // 물을 수 있는 상태(보낼 프로세스는 없다 — 보낸 것은 outbox 에 쌓는다)
    test_record_sends = true;
    defer testTeardown(gpa);
    try testSurfaces(gpa, &.{7});
    try web_downloads.testAddActive(1, 7);
    // 처리기 없는 페이지 — 이동이 곧바로 새 문서를 연다.
    try std.testing.expect(askClose(gpa, 7, 0));
    try std.testing.expect(surfaces.getPtr(7).?.close_park);
    var sent: [4]Message = undefined;
    try std.testing.expectEqual(@as(usize, 1), sentFrames(&sent)); // 닫기(`close_asking`) 대신 about:blank 로
    try std.testing.expect(sent[0].navigate.browser == 7 and std.mem.eql(u8, sent[0].navigate.url, "about:blank"));
    outbox_pending.clearRetainingCapacity();
    try std.testing.expectEqual(CloseAskOutcome.waiting, takeCloseAsk(7, 10));
    apply(gpa, .{ .page_started = 7 }, 0);
    try std.testing.expectEqual(CloseAskOutcome.closed, takeCloseAsk(7, 10));
    // 떠나기 확인 — 머무르면 탭을 두고, 그 뒤의 새 문서(사용자가 다른 곳으로 감)는 닫기가 아니다.
    try std.testing.expect(askClose(gpa, 7, 0));
    apply(gpa, .{ .js_dialog = .{ .browser = 7, .request = 3, .kind = .before_unload, .origin = "", .message = "" } }, 0);
    const d = nextDialog(7).?;
    replyDialog(gpa, 7, d.token, false, "", false);
    try std.testing.expectEqual(CloseAskOutcome.stayed, takeCloseAsk(7, 10));
    try std.testing.expect(!surfaces.getPtr(7).?.close_park);
    apply(gpa, .{ .page_started = 7 }, 0);
    try std.testing.expectEqual(CloseAskOutcome.none, takeCloseAsk(7, 10));
    // 떠나기를 고르면 새 문서가 닫는다.
    try std.testing.expect(askClose(gpa, 7, 0));
    apply(gpa, .{ .js_dialog = .{ .browser = 7, .request = 4, .kind = .before_unload, .origin = "", .message = "" } }, 0);
    replyDialog(gpa, 7, nextDialog(7).?.token, true, "", false);
    try std.testing.expectEqual(CloseAskOutcome.waiting, takeCloseAsk(7, 10));
    apply(gpa, .{ .page_started = 7 }, 0);
    try std.testing.expectEqual(CloseAskOutcome.closed, takeCloseAsk(7, 10));
    // 받는 것이 없으면 예전처럼 페이지에 닫기를 묻는다.
    web_downloads.testFinish(1);
    outbox_pending.clearRetainingCapacity();
    try std.testing.expect(askClose(gpa, 7, 0));
    try std.testing.expect(!surfaces.getPtr(7).?.close_park);
    try std.testing.expectEqual(@as(usize, 1), sentFrames(&sent));
    try std.testing.expectEqual(@as(u64, 7), sent[0].close_asking);
    apply(gpa, .{ .page_started = 7 }, 0);
    try std.testing.expectEqual(CloseAskOutcome.waiting, takeCloseAsk(7, 10)); // 새 문서로는 닫지 않는다(`browser_closed` 를 기다린다)
}

test "a page-opened tab that only downloaded is closed, one with a document or a click is kept (W10c)" {
    const gpa = std.testing.allocator;
    web_downloads.testReset();
    defer web_downloads.testReset();
    state = .starting;
    defer testTeardown(gpa);
    try testSurfaces(gpa, &.{ 7, 8, 9, 10 });
    surfaces.getPtr(7).?.page_opened = true; // 페이지가 열고 곧바로 받았다
    surfaces.getPtr(8).?.page_opened = true;
    surfaces.getPtr(8).?.url = try gpa.dupe(u8, "https://a.example/landing"); // 문서가 있었다(「곧 받기가 시작됩니다」 쪽)
    surfaces.getPtr(7).?.url = try gpa.dupe(u8, "about:blank"); // 처음 만들 때의 빈 문서(새 문서 표지도 왔다)
    surfaces.getPtr(7).?.last_nav_ms = 5;
    surfaces.getPtr(9).?.page_opened = true;
    surfaces.getPtr(9).?.last_user_input_ms = 5; // 그 탭에서 눌렀다(document.write 로 쓴 팝업 등)
    // 10 — 사용자가 연 탭(주소창에 친 파일 주소)
    web_downloads.setAsk(true); // 사용자 동작 없는 행은 보류 — 시험이 `~/Downloads` 에 경로를 만들지 않게
    for ([_]u64{ 7, 8, 9, 10 }, 1..) |id, dl| apply(gpa, .{ .download_begin = .{ .browser = id, .download = @intCast(dl), .url = "https://a.example/f", .name = "f.txt", .mime = "text/plain", .total = 10 } }, 0);
    try std.testing.expect(takeDownloadBlank(7));
    try std.testing.expect(!takeDownloadBlank(7)); // 한 번
    // 「매번 묻기」에서 누른 다운로드 — 저장 창이 뜰 때(맡을 때)까지 탭을 닫지 않는다(그 탭이 저장 창을 띄운다).
    try testSurfaces(gpa, &.{11});
    const s11 = surfaces.getPtr(11).?;
    s11.page_opened = true;
    s11.download_gesture_ms = monotonicNow(); // 연 탭의 누름을 물려받았다
    apply(gpa, .{ .download_begin = .{ .browser = 11, .download = 9, .url = "https://a.example/f", .name = "g.txt", .mime = "text/plain", .total = 10 } }, 0);
    try std.testing.expectEqual(web_downloads.State.asking, web_downloads.at(web_downloads.count() - 1).?.state);
    try std.testing.expect(!takeDownloadBlank(11));
    try std.testing.expect(web_downloads.claimAskFor(11) != null);
    try std.testing.expect(takeDownloadBlank(11));
    try std.testing.expect(!takeDownloadBlank(8));
    try std.testing.expect(!takeDownloadBlank(9));
    try std.testing.expect(!takeDownloadBlank(10));
    // `open_tab` 의 새 탭은 기록이 생길 때 표지를 받는다.
    notePageOpened(42);
    try std.testing.expect(takePageOpened(42));
    try std.testing.expect(!takePageOpened(42));
}

test "ask mode: a clicked download asks, one per tab, the rest are held, and the list's take asks again (W10b)" {
    const gpa = std.testing.allocator;
    web_downloads.testReset();
    defer web_downloads.testReset();
    state = .starting;
    defer {
        for (surfaces.values()) |*s| freeSurface(gpa, s);
        surfaces.deinit(gpa);
        surfaces = .empty;
        outbox_pending.clearAndFree(gpa);
        state = .off;
    }
    try surfaces.put(gpa, 7, .{ .record = .{ .surface_id = 7, .size = .{ .width = 300, .height = 200, .scale = 2 }, .hidden = false }, .created = true });
    try surfaces.put(gpa, 8, .{ .record = .{ .surface_id = 8, .size = .{ .width = 300, .height = 200, .scale = 2 }, .hidden = false }, .created = true });
    web_downloads.setAsk(true);
    const now = monotonicNow();
    surfaces.getPtr(7).?.last_user_input_ms = now; // 탭 7 에서 눌렀다, 탭 8 은 손대지 않았다
    var surface: u64 = 0;
    const show_before = web_downloads.showRequest(&surface);
    apply(gpa, .{ .download_begin = .{ .browser = 7, .download = 1, .url = "https://a.example/x", .name = "a.txt", .mime = "text/plain", .total = 10 } }, now);
    apply(gpa, .{ .download_begin = .{ .browser = 7, .download = 2, .url = "https://a.example/y", .name = "b.txt", .mime = "text/plain", .total = 10 } }, now);
    apply(gpa, .{ .download_begin = .{ .browser = 8, .download = 3, .url = "https://b.example/z", .name = "c.txt", .mime = "text/plain", .total = 10 } }, now);
    try std.testing.expectEqual(@as(usize, 3), web_downloads.count());
    try std.testing.expectEqual(web_downloads.State.asking, web_downloads.at(0).?.state); // 누른 것 — 묻는다
    try std.testing.expectEqual(web_downloads.State.held, web_downloads.at(1).?.state); // 그 탭에 이미 묻는 것이 있다 — 보류
    try std.testing.expectEqual(web_downloads.State.held, web_downloads.at(2).?.state); // 사용자 동작 없음 — 보통 파일도 보류
    // 묻는 행은 목록 창을 내지 않는다 — 보류 둘만큼만 올랐다.
    try std.testing.expectEqual(show_before +% 2, web_downloads.showRequest(&surface));
    // 목록의 받기는 묻기로(시각은 새로), 묻는 행의 취소는 받지 않음.
    try std.testing.expect(web_downloads.act(web_downloads.at(2).?.key, .accept));
    try std.testing.expectEqual(web_downloads.State.asking, web_downloads.at(2).?.state);
    try std.testing.expectEqual(@as(i64, 0), web_downloads.at(2).?.ask_since_ms);
    try std.testing.expect(web_downloads.act(web_downloads.at(0).?.key, .cancel));
    try std.testing.expectEqual(web_downloads.State.canceled, web_downloads.at(0).?.state);
}

test "a click counts as the user starting a download only until the page moves on (W10a)" {
    const gpa = std.testing.allocator;
    defer {
        for (surfaces.values()) |*s| freeSurface(gpa, s);
        surfaces.deinit(gpa);
        surfaces = .empty;
        outbox_pending.clearAndFree(gpa);
    }
    try surfaces.put(gpa, 7, .{ .record = .{ .surface_id = 7, .size = .{ .width = 300, .height = 200, .scale = 2 }, .hidden = false }, .created = true });
    const now = monotonicNow();
    try std.testing.expect(!recentUserInput(7, 3000, now)); // 손대지 않았다
    surfaces.getPtr(7).?.last_user_input_ms = now;
    try std.testing.expect(recentUserInput(7, 3000, now + 10));
    try std.testing.expect(!recentUserInput(7, 3000, now + 3001)); // 창 밖
    // 같은 문서 안의 주소 바꾸기(pushState)는 이동이 아니다 — 누른 뒤 라우터가 주소를 바꾸고 받는 흔한 길.
    apply(gpa, .{ .url_changed = .{ .browser = 7, .url = "https://example.test/next" } }, 0);
    try std.testing.expect(recentUserInput(7, 3000, now + 10));
    // 누른 링크가 다른 문서를 열었다 — 그 문서가 시작한 다운로드는 사용자 동작이 아니다.
    apply(gpa, .{ .page_started = 7 }, 0);
    try std.testing.expect(!recentUserInput(7, 3000, monotonicNow()));
    surfaces.getPtr(7).?.last_user_input_ms = monotonicNow() + 1; // 새 페이지에서 다시 눌렀다
    try std.testing.expect(recentUserInput(7, 3000, monotonicNow() + 1));
    // 주소창에 친 주소는 다운로드의 사용자 동작이다(문서를 열면 `page_started` 가 지운다) — 제안 목록 막음의 입력 시각은 그대로다.
    // 페이지가 연 탭이어도 이제 사용자의 탭이다(W10c — 빈 다운로드 탭으로 닫지 않는다).
    surfaces.getPtr(7).?.page_opened = true;
    // (시각은 정해 둔다 — 같은 밀리초 안의 순서에 기대지 않게.)
    const s7 = surfaces.getPtr(7).?;
    s7.last_user_input_ms = 100;
    s7.last_nav_ms = 200;
    noteUserNavigation(7);
    try std.testing.expect(recentUserInput(7, 3000, monotonicNow()));
    try std.testing.expect(!surfaces.getPtr(7).?.page_opened);
    try std.testing.expectEqual(@as(i64, 100), s7.last_user_input_ms);
    s7.last_nav_ms = monotonicNow() + 5; // 친 주소가 문서를 열었다(그 뒤)
    try std.testing.expect(!recentUserInput(7, 3000, monotonicNow() + 5));
    try std.testing.expect(!recentUserInput(8, 3000, now)); // 모르는 탭
}

test "datalist is owned per surface, replaced by a newer list, closed only by its own list, picked once (W6m②)" {
    const gpa = std.testing.allocator;
    // `.starting` — 보내는 것이 outbox 에 남아 frame 으로 본다.
    state = .starting;
    defer {
        for (surfaces.values()) |*s| freeSurface(gpa, s);
        surfaces.deinit(gpa);
        surfaces = .empty;
        outbox_pending.clearAndFree(gpa);
        state = .off;
    }
    try surfaces.put(gpa, 7, .{ .record = .{ .surface_id = 7, .size = .{ .width = 300, .height = 200, .scale = 2 }, .hidden = false }, .created = true });
    const items = "\x00\x05apple\x00\x00";
    // 사용자가 손대지 않은 탭의 목록은 받지 않는다(적대 검증 4 차).
    apply(gpa, .{ .datalist_show = .{ .browser = 7, .list = 2, .field = .{ .x = 0, .y = 0, .width = 300, .height = 40 }, .count = 1, .items = items } }, 0);
    try std.testing.expect(datalist(7) == null);
    surfaces.getPtr(7).?.last_user_input_ms = monotonicNow();
    apply(gpa, .{ .datalist_show = .{ .browser = 7, .list = 3, .field = .{ .x = 0, .y = 0, .width = 300, .height = 40 }, .count = 1, .items = items } }, 0);
    const first = datalist(7).?;
    try std.testing.expectEqual(@as(u32, 3), first.d.list);
    const gen = first.generation;
    apply(gpa, .{ .datalist_show = .{ .browser = 7, .list = 4, .field = .{ .x = 0, .y = 0, .width = 300, .height = 40 }, .count = 1, .items = items } }, 0);
    try std.testing.expectEqual(@as(u32, 4), datalist(7).?.d.list);
    try std.testing.expect(datalist(7).?.generation != gen);
    // 옛 목록의 닫기는 지금 목록을 닫지 않는다.
    apply(gpa, .{ .datalist_hide = .{ .browser = 7, .list = 3 } }, 0);
    try std.testing.expect(datalist(7) != null);
    // 옛 번호·범위 밖 고르기는 보내지 않는다, 맞는 고르기는 한 번만.
    try std.testing.expect(!datalistPick(gpa, 7, 3, 0));
    try std.testing.expect(!datalistPick(gpa, 7, 4, 1));
    try std.testing.expect(datalistPick(gpa, 7, 4, 0));
    try std.testing.expect(datalist(7) == null);
    var frames: [8]Message = undefined;
    const sent = frames[0..sentFrames(&frames)];
    try std.testing.expectEqual(@as(usize, 1), sent.len);
    try std.testing.expectEqual(@as(u32, 4), sent[0].datalist_pick.list);
    try std.testing.expectEqual(@as(u16, 0), sent[0].datalist_pick.index);
    try std.testing.expect(!datalistPick(gpa, 7, 4, 0));
    // 렌더러가 죽으면 닫힌다, 0 번 닫기는 어느 목록이든.
    apply(gpa, .{ .datalist_show = .{ .browser = 7, .list = 5, .field = .{ .x = 0, .y = 0, .width = 300, .height = 40 }, .count = 1, .items = items } }, 0);
    apply(gpa, .{ .renderer_gone = .{ .browser = 7, .reason = .crashed } }, 0);
    try std.testing.expect(datalist(7) == null);
    apply(gpa, .{ .datalist_show = .{ .browser = 7, .list = 6, .field = .{ .x = 0, .y = 0, .width = 300, .height = 40 }, .count = 1, .items = items } }, 0);
    apply(gpa, .{ .datalist_hide = .{ .browser = 7, .list = 0 } }, 0);
    try std.testing.expect(datalist(7) == null);
}

test "a page click inside the datalist field keeps the list, outside closes it (W6m②)" {
    const r: ws.message.Rect = .{ .x = 10, .y = 20, .width = 100, .height = 30 };
    try std.testing.expect(pointInRect(.{ .x = 10, .y = 20 }, r));
    try std.testing.expect(pointInRect(.{ .x = 109, .y = 49 }, r));
    try std.testing.expect(!pointInRect(.{ .x = 110, .y = 20 }, r));
    try std.testing.expect(!pointInRect(.{ .x = 10, .y = 50 }, r));
    try std.testing.expect(!pointInRect(.{ .x = 9, .y = 30 }, r));
}

test "tooltip text is owned per surface, cleared by an empty text, and each change bumps the generation (W6b)" {
    const gpa = std.testing.allocator;
    var s: Surface = .{ .record = .{ .surface_id = 1, .size = .{ .width = 10, .height = 10, .scale = 1 }, .hidden = false } };
    var source = "A tip\nline2".*;
    setTooltip(gpa, &s, &source);
    source[0] = 'X'; // 받은 글은 복사해 둔다(디코더 버퍼는 다음 frame 에 덮인다)
    try std.testing.expectEqualStrings("A tip\nline2", s.tooltip_text.?);
    try std.testing.expectEqual(@as(u32, 1), s.tooltip_generation);
    setTooltip(gpa, &s, "B");
    try std.testing.expectEqualStrings("B", s.tooltip_text.?);
    setTooltip(gpa, &s, ""); // 빈 글이면 없앤다(렌더러 죽음·sidecar 잃음·브라우저 닫힘도 이 길)
    try std.testing.expect(s.tooltip_text == null);
    try std.testing.expectEqual(@as(u32, 3), s.tooltip_generation);
    setTooltip(gpa, &s, "C");
    if (s.tooltip_text) |t| gpa.free(t); // 테스트 할당자가 새는 것을 잡는다(freeSurface 의 해제와 같은 몫)
}

test "engine decision: env first, then an installed maru-chromium, else WebKit with a notice" {
    try std.testing.expectEqual(Decision{ .chromium = true, .dir = "/dev/build" }, decideFrom(false, "/dev/build", null));
    try std.testing.expectEqual(Decision{ .chromium = false }, decideFrom(false, null, "/opt/homebrew/opt/maru-chromium/libexec"));
    const installed = decideFrom(true, null, "/opt/homebrew/opt/maru-chromium/libexec");
    try std.testing.expect(installed.chromium and !installed.not_installed);
    try std.testing.expectEqualStrings("/opt/homebrew/opt/maru-chromium/libexec", installed.dir.?);
    try std.testing.expectEqual(Decision{ .chromium = false, .not_installed = true }, decideFrom(true, null, null));
}

test "a hardened (release) build ignores the development env overrides" {
    const allocator = std.testing.allocator;
    const Saved = struct {
        name: [:0]const u8,
        value: ?[:0]u8,
    };
    var saved = [_]Saved{ .{ .name = "MARU_WEB_OSR_DIR", .value = null }, .{ .name = "HOMEBREW_PREFIX", .value = null } };
    for (&saved) |*e| e.value = if (std.c.getenv(e.name)) |v| try allocator.dupeZ(u8, std.mem.span(v)) else null;
    defer for (saved) |e| {
        if (e.value) |v| {
            _ = setenv(e.name, v, 1);
            allocator.free(v);
        } else _ = unsetenv(e.name);
    };
    // 가짜 prefix 에 실행 파일이 있는 설치(모양만 — 검사는 `start` 에서).
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_base = if (std.c.getenv("TMPDIR")) |t| std.mem.trimEnd(u8, std.mem.span(t), "/") else "/tmp";
    const template = try std.fmt.bufPrintZ(&tmp_buf, "{s}/maru-prefix-{d}-XXXXXX", .{ if (tmp_base.len > 0 and tmp_base[0] == '/') tmp_base else "/tmp", std.c.getpid() });
    const made = std.mem.span(mkdtemp(template.ptr) orelse return error.NoTemp);
    defer {
        var rm_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (std.fmt.bufPrintZ(&rm_buf, "{s}/opt/maru-chromium/libexec/maru-web-host", .{made})) |f| _ = std.c.unlink(f) else |_| {}
        for ([_][]const u8{ "/opt/maru-chromium/libexec", "/opt/maru-chromium", "/opt", "" }) |rel| {
            if (std.fmt.bufPrintZ(&rm_buf, "{s}{s}", .{ made, rel })) |d| _ = std.c.rmdir(d) else |_| {}
        }
    }
    var host_buf: [std.fs.max_path_bytes]u8 = undefined;
    const libexec = try std.fmt.bufPrint(&host_buf, "{s}/opt/maru-chromium/libexec", .{made});
    try std.testing.expect(mkdirs(libexec));
    var host_z_buf: [std.fs.max_path_bytes]u8 = undefined;
    const host = try std.fmt.bufPrintZ(&host_z_buf, "{s}/maru-web-host", .{libexec});
    const fd = std.c.open(host, .{ .ACCMODE = .WRONLY, .CREAT = true }, @as(std.c.mode_t, 0o755));
    try std.testing.expect(fd >= 0);
    _ = std.c.close(fd);
    const made_z = try allocator.dupeZ(u8, made);
    defer allocator.free(made_z);
    try std.testing.expectEqual(@as(c_int, 0), setenv("MARU_WEB_OSR_DIR", "/dev/build", 1));
    try std.testing.expectEqual(@as(c_int, 0), setenv("HOMEBREW_PREFIX", made_z, 1));
    try std.testing.expectEqualStrings("/dev/build", envDirFor(false).?);
    try std.testing.expect(envDirFor(true) == null);
    try std.testing.expectEqualStrings(libexec, findInstallFor(false).?);
    if (findInstallFor(true)) |dir| try std.testing.expect(!std.mem.startsWith(u8, dir, made)); // 실제 설치가 있으면 그것
}

test "a rejected install shows a version notice only for a control-channel mismatch" {
    try std.testing.expectEqual(Notice.version_mismatch, rejectedNotice(.version_mismatch));
    try std.testing.expectEqual(Notice.start_failed, rejectedNotice(.bad_manifest));
    try std.testing.expectEqual(Notice.start_failed, rejectedNotice(.not_owned));
    try std.testing.expectEqual(Notice.start_failed, rejectedNotice(.clone_failed));
    try std.testing.expectEqual(Notice.start_failed, rejectedNotice(.signature_unverified)); // 사용자에게는 같은 「시작 실패」(기록만)
}

/// 시험용 실행 사본 — 임시 디렉터리(빈 `src`)를 그 아래 `cache` 로 복제한다. 뿌리는 처음 한 번만 만든다(부를 때마다 만들면
/// `cleanup` 이 마지막 것만 지워 남았다 — W7a2 4 차 적대 검증).
const TestCopy = struct {
    root_buf: [std.fs.max_path_bytes]u8 = undefined,
    root: []const u8 = "",

    fn make(self: *TestCopy) !install.RunCopy {
        if (self.root.len == 0) {
            const tmp_base = if (std.c.getenv("TMPDIR")) |t| std.mem.trimEnd(u8, std.mem.span(t), "/") else "/tmp";
            var template_buf: [std.fs.max_path_bytes]u8 = undefined;
            const template = try std.fmt.bufPrintZ(&template_buf, "{s}/maru-runcopy-{d}-XXXXXX", .{ if (tmp_base.len > 0 and tmp_base[0] == '/') tmp_base else "/tmp", std.c.getpid() });
            const made = mkdtemp(template.ptr) orelse return error.NoTemp;
            self.root = std.mem.span(std.c.realpath(made, &self.root_buf) orelse return error.NoTemp);
        }
        var src_buf: [std.fs.max_path_bytes]u8 = undefined;
        const src = try std.fmt.bufPrint(&src_buf, "{s}/src", .{self.root});
        try std.testing.expect(mkdirs(src));
        const fd = install.openDevSource(src) orelse return error.NoSource;
        defer _ = std.c.close(fd);
        var cache_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cache = try std.fmt.bufPrint(&cache_buf, "{s}/cache", .{self.root});
        return switch (install.cloneForRun(fd, cache)) {
            .ok => |c| c,
            .bad => error.CloneFailed,
        };
    }

    fn exists(path: []const u8) bool {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const z = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return false;
        return std.c.access(z, std.c.F_OK) == 0;
    }

    fn cleanup(self: *const TestCopy) void {
        if (self.root.len == 0) return;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        for ([_][]const u8{ "/src", "/cache", "" }) |rel| {
            if (std.fmt.bufPrintZ(&buf, "{s}{s}", .{ self.root, rel })) |d| _ = std.c.rmdir(d) else |_| {}
        }
    }
};

test "a run copy lives as long as its sidecar: kept while it retires, removed once it is reaped or stopped for good" {
    const gpa = std.testing.allocator;
    gpa_ref = gpa;
    try std.testing.expectEqual(@as(usize, 0), surfaces.count());
    var tc: TestCopy = .{};
    defer tc.cleanup();
    defer {
        latched = null;
        state = .off;
    }
    // 마지막 탭을 닫았다 — 물러나는 동안 사본은 남고, 기한 뒤 거두면 지워진다.
    run_copy = try tc.make();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const first = try std.fmt.bufPrint(&dir_buf, "{s}", .{run_copy.?.dir()});
    process = try lsp_process.spawn(gpa, "/bin/sleep", &.{"30"}, "/");
    retire(gpa, 1_000);
    try std.testing.expect(run_copy == null and retiring_copy != null);
    try std.testing.expect(TestCopy.exists(first));
    reapRetiring(gpa, 1_000 + shutdown_wait_ms);
    try std.testing.expect(retiring == null and retiring_copy == null);
    try std.testing.expect(!TestCopy.exists(first));
    // 다시 띄워도 같은 불일치 — 멈출 때도 지운다.
    run_copy = try tc.make();
    var second_buf: [std.fs.max_path_bytes]u8 = undefined;
    const second = try std.fmt.bufPrint(&second_buf, "{s}", .{run_copy.?.dir()});
    process = try lsp_process.spawn(gpa, "/bin/sleep", &.{"30"}, "/");
    stopWith(gpa, .version_mismatch);
    try std.testing.expect(process == null and run_copy == null);
    try std.testing.expect(!TestCopy.exists(second));
    // 띄우지 못한 채 남은 사본도 멈출 때 지운다.
    run_copy = try tc.make();
    var third_buf: [std.fs.max_path_bytes]u8 = undefined;
    const third = try std.fmt.bufPrint(&third_buf, "{s}", .{run_copy.?.dir()});
    stop(gpa);
    try std.testing.expect(run_copy == null and !TestCopy.exists(third));
}

test "a sidecar whose channel ended but which is still alive is killed and reaped, not left a zombie" {
    const gpa = std.testing.allocator;
    gpa_ref = gpa;
    try std.testing.expectEqual(@as(usize, 0), surfaces.count()); // 크래시 경로가 실제 sidecar 를 띄우지 않게
    const saved_failures = .{ failures, failure_head };
    defer {
        failures = saved_failures[0];
        failure_head = saved_failures[1];
        latched = null;
        state = .off;
    }
    process = try lsp_process.spawn(gpa, "/bin/sleep", &.{"30"}, "/");
    const pid = process.?.pid;
    crashed(gpa, 1_000);
    try std.testing.expect(process == null);
    // 거뒀다 — 그 pid 는 이제 이 프로세스의 자식이 아니다(좀비면 waitpid 가 거둘 수 있다).
    var status: c_int = 0;
    try std.testing.expectEqual(@as(std.c.pid_t, -1), std.c.waitpid(pid, &status, std.c.W.NOHANG));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(std.c.E.CHILD)), std.c._errno().*);
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;
extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;

test "the engine is latched by the first decision (restart-only)" {
    const saved = .{ decided, requested_chromium, install_notice_pending };
    defer {
        decided = saved[0];
        requested_chromium = saved[1];
        install_notice_pending = saved[2];
    }
    if (envDir() != null) return error.SkipZigTest; // 개발용 환경변수가 걸린 셸이면 결정이 달라진다
    decided = null;
    decide(false);
    try std.testing.expect(!enabled());
    decide(true); // 두 번째 창 — 무동작
    try std.testing.expect(!enabled());
    try std.testing.expect(!requested_chromium);
}

test "a sidecar of another control-channel version stops with a version notice instead of a restart loop" {
    const gpa = std.testing.allocator;
    gpa_ref = gpa;
    try std.testing.expectEqual(@as(usize, 0), surfaces.count()); // 크래시 경로가 실제 sidecar 를 띄우지 않게
    const saved_failures = .{ failures, failure_head };
    defer {
        failures = saved_failures[0];
        failure_head = saved_failures[1];
        inbox.deinit(gpa);
        inbox = .empty;
        outbox_pending.deinit(gpa);
        outbox_pending = .empty;
        decoder = .init(.to_maru);
        latched = null;
        state = .off;
    }
    // 따로 설치된 sidecar 가 제 버전으로 보낸 hello_ack(머리만 다르다). handshake 전에 쥔 명령도 있다.
    try outbox_pending.appendSlice(gpa, "queued");
    var frame: [64]u8 = undefined;
    const len = try ws.codec.encode(.{ .hello_ack = .{ .instance = 0, .nonce = 0 } }, &frame);
    std.mem.writeInt(u16, frame[ws.wire.prefix_len + ws.wire.magic.len ..][0..2], ws.wire.version + 1, .big);
    state = .starting;
    try inbox.appendSlice(gpa, frame[0..len]);
    drainInbox(gpa, 0);
    try std.testing.expectEqual(State.failed, state);
    try std.testing.expectEqual(@as(?Notice, .version_mismatch), latched);
    try std.testing.expectEqual(@as(usize, 0), outbox_pending.items.len); // 보낼 곳이 없다 — 버린다
    // handshake 중이라도 버전이 아닌 위반(깨진 magic)은 규칙 위반(죽이고 다시 띄우는 쪽) — 버전 안내가 아니다.
    decoder = .init(.to_maru);
    inbox.clearRetainingCapacity();
    latched = null;
    state = .starting;
    var broken = frame;
    std.mem.writeInt(u16, broken[ws.wire.prefix_len + ws.wire.magic.len ..][0..2], ws.wire.version, .big);
    broken[ws.wire.prefix_len] = 'X';
    try inbox.appendSlice(gpa, broken[0..len]);
    drainInbox(gpa, 0);
    try std.testing.expect(latched != Notice.version_mismatch);
    // handshake 뒤의 버전 위반도 규칙 위반 — 버전 안내가 아니다.
    decoder = .init(.to_maru);
    inbox.clearRetainingCapacity();
    latched = null;
    state = .running;
    try inbox.appendSlice(gpa, frame[0..len]);
    drainInbox(gpa, 0);
    try std.testing.expect(latched != Notice.version_mismatch);
}

test "stopping for good also drops what the dead sidecar held — dialogs, queued notifications, clickable records" {
    const gpa = std.testing.allocator;
    gpa_ref = gpa;
    try std.testing.expectEqual(@as(usize, 0), surfaces.count());
    defer {
        for (surfaces.values()) |*s| freeSurface(gpa, s);
        surfaces.deinit(gpa);
        surfaces = .empty;
        outbox_pending.deinit(gpa);
        outbox_pending = .empty;
        latched = null;
        state = .off;
    }
    state = .running;
    try surfaces.put(gpa, 7, .{ .record = .{ .surface_id = 7, .size = .{ .width = 10, .height = 10, .scale = 1 }, .hidden = false }, .created = true });
    apply(gpa, .{ .js_dialog = .{ .browser = 7, .request = 1, .kind = .alert, .origin = "", .message = "" } }, 0);
    apply(gpa, .{ .web_notification = .{ .browser = 7, .notification = 2, .origin = "https://a.b", .title = "t" } }, 0);
    try std.testing.expect(nextDialog(7) != null);
    // 실행 중에 온 `profile_in_use` 처럼 — 다시 띄우지 않는 멈춤. 답할 콜백이 사라졌으니 요청·알림을 남기지 않는다.
    stopWith(gpa, .profile_in_use);
    try std.testing.expect(nextDialog(7) == null);
    try std.testing.expect(takeWebNotification(7) == null);
    try std.testing.expectEqual(@as(?Notice, .profile_in_use), takeStoppedNotice(7));
}

test "a stopped engine is announced once in every Chromium tab's window, including tabs opened after it stopped" {
    const gpa = std.testing.allocator;
    gpa_ref = gpa;
    try std.testing.expectEqual(@as(usize, 0), surfaces.count());
    defer {
        for (surfaces.values()) |*s| freeSurface(gpa, s);
        surfaces.deinit(gpa);
        surfaces = .empty;
        latched = null;
        state = .off;
    }
    const size: ws.message.ViewSize = .{ .width = 10, .height = 10, .scale = 1 };
    try surfaces.put(gpa, 7, .{ .record = .{ .surface_id = 7, .size = size, .hidden = false } });
    try surfaces.put(gpa, 8, .{ .record = .{ .surface_id = 8, .size = size, .hidden = true } });
    fail(.version_mismatch);
    // 열려 있던 두 탭 모두 — 각자 한 번.
    try std.testing.expectEqual(@as(?Notice, .version_mismatch), takeStoppedNotice(7));
    try std.testing.expectEqual(@as(?Notice, null), takeStoppedNotice(7));
    try std.testing.expectEqual(@as(?Notice, .version_mismatch), takeStoppedNotice(8));
    // 멈춘 뒤 새로 연 탭도 안내를 받는다(엔진은 띄우지 않는다).
    ensure(gpa, .{ .surface_id = 9, .width_px = 10, .height_px = 10, .visible = true }, 1000, 0);
    try std.testing.expectEqual(State.failed, state);
    try std.testing.expect(process == null);
    try std.testing.expectEqual(@as(?Notice, .version_mismatch), takeStoppedNotice(9));
    try std.testing.expectEqual(@as(?Notice, null), takeStoppedNotice(9));
}

test "an exit seen before the last frame is read still reads it, so a version mismatch is not counted as a crash" {
    const gpa = std.testing.allocator;
    gpa_ref = gpa;
    try std.testing.expectEqual(@as(usize, 0), surfaces.count()); // 크래시 경로가 실제 sidecar 를 띄우지 않게
    const saved_failures = .{ failures, failure_head };
    defer {
        failures = saved_failures[0];
        failure_head = saved_failures[1];
        if (process) |*p| {
            lsp_process.kill(p, .KILL);
            lsp_process.reapBlocking(p);
            p.deinit(gpa);
        }
        process = null;
        inbox.deinit(gpa);
        inbox = .empty;
        outbox_pending.deinit(gpa);
        outbox_pending = .empty;
        decoder = .init(.to_maru);
        latched = null;
        state = .off;
    }
    // 이미 끝났지만 아직 거두지 않은 자식(`waitid` 의 WNOWAIT — 거두지 않고 끝나기만 기다린다).
    var child = try lsp_process.spawn(gpa, "/usr/bin/true", &.{}, "/");
    var handed_over = false;
    defer if (!handed_over) {
        lsp_process.reapBlocking(&child);
        child.deinit(gpa);
    };
    try std.testing.expect(lsp_process.testWaitExitedNoReap(child.pid)); // 거두지 않고 끝나기만 기다린다
    // 그 자식이 끝나기 직전에 쓴 것처럼, 아직 안 읽은 버전이 다른 `hello_ack` 가 파이프에 있다.
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    var fds_owned = true; // `child` 에 넘기기 전에 실패하면 닫는다
    defer if (fds_owned) {
        _ = std.c.close(fds[0]);
        _ = std.c.close(fds[1]);
    };
    // 운영의 `out_fd` 처럼 비차단·exec 에 안 넘김 — 다른 시험이 띄운 자식이 쓰기 끝을 물려받으면 EOF 가 영영 안 와 샤드가
    // 멈춘다(W7a1 5 차 적대 검증).
    for (fds) |fd| _ = std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC));
    _ = std.c.fcntl(fds[0], std.c.F.SETFL, @as(c_int, @bitCast(std.c.O{ .NONBLOCK = true })));
    var frame: [64]u8 = undefined;
    const len = try ws.codec.encode(.{ .hello_ack = .{ .instance = 0, .nonce = 0 } }, &frame);
    std.mem.writeInt(u16, frame[ws.wire.prefix_len + ws.wire.magic.len ..][0..2], ws.wire.version + 1, .big);
    try std.testing.expectEqual(@as(isize, @intCast(len)), std.c.write(fds[1], &frame, len));
    _ = std.c.close(fds[1]);
    _ = std.c.close(child.out_fd);
    child.out_fd = fds[0];
    fds_owned = false;
    // 실제 순서처럼 먼저 거둔다(`pump` 의 `reapIfExited`) — 그 뒤 멈출 때 거둔 pid 를 다시 죽이거나 기다리지 않는다.
    try std.testing.expect(lsp_process.reapIfExited(&child));
    process = child;
    handed_over = true;
    state = .starting;
    onExited(gpa, 0, process_generation);
    try std.testing.expectEqual(@as(?Notice, .version_mismatch), latched);
    try std.testing.expect(process == null); // 멈췄다 — 다시 띄우지 않는다
    try std.testing.expectEqual(saved_failures[1], failure_head); // 크래시로 세지 않았다
}

test "engine change notice fires once per new value and resets when the setting returns" {
    const saved_decided = decided;
    const saved_requested = requested_chromium;
    const saved_last = last_change_notice;
    defer {
        decided = saved_decided;
        requested_chromium = saved_requested;
        last_change_notice = saved_last;
    }
    decided = false;
    requested_chromium = false;
    last_change_notice = null;
    try std.testing.expect(!engineChangeNeedsNotice(false));
    try std.testing.expect(engineChangeNeedsNotice(true));
    try std.testing.expect(!engineChangeNeedsNotice(true)); // 같은 값 — 다시 안 알린다
    try std.testing.expect(!engineChangeNeedsNotice(false)); // 되돌림 — 적용 중인 값과 같다
    try std.testing.expect(engineChangeNeedsNotice(true)); // 다시 바꾸면 다시 알린다
    // 청했지만 설치가 없어 WebKit 인 상태에서 webkit 으로 되돌림 — 바뀌는 것이 없다.
    decided = false;
    requested_chromium = true;
    last_change_notice = null;
    try std.testing.expect(!engineChangeNeedsNotice(false));
}

/// 설정의 엔진이 바뀌었다(파일 reload·설정 화면). 적용 중인 결정과 다르면 한 번 true — 「재시작하면 적용」 안내.
pub fn engineChangeNeedsNotice(config_wants_chromium: bool) bool {
    const effective = decided orelse return false;
    // 청했지만 설치가 없어 이미 WebKit 인데 webkit 으로 되돌렸다 — 바뀌는 것이 없다.
    if (config_wants_chromium == requested_chromium or (!effective and !config_wants_chromium)) {
        last_change_notice = null;
        return false;
    }
    if (last_change_notice == config_wants_chromium) return false;
    last_change_notice = config_wants_chromium;
    return true;
}

/// 설정은 chromium 을 청했는데 설치가 없어 WebKit 으로 열었다 — 한 번.
pub fn takeInstallNotice() bool {
    const v = install_notice_pending;
    install_notice_pending = false;
    return v;
}

/// OSR 백엔드가 켜져 있는가. 결정 전(첫 창 설정 전)에는 개발용 환경변수만 본다.
pub fn enabled() bool {
    return decided orelse (envDir() != null);
}

fn envDir() ?[]const u8 {
    return envDirFor(install.hardenedRuntime());
}

/// 릴리스 판(hardened runtime)은 환경변수로 실행 파일을 고르지 않는다(W7a2 — `web_osr_install.zig`).
fn envDirFor(hardened: bool) ?[]const u8 {
    if (hardened) return null;
    const dir = std.c.getenv("MARU_WEB_OSR_DIR") orelse return null;
    const s = std.mem.span(dir);
    return if (s.len == 0) null else s;
}

fn findInstall() ?[]const u8 {
    return findInstallFor(install.hardenedRuntime());
}

fn findInstallFor(hardened: bool) ?[]const u8 {
    const S = struct {
        var dir_buf: [512]u8 = undefined;
    };
    var path_buf: [600]u8 = undefined;
    const env_prefix: ?[]const u8 = if (hardened) null else if (std.c.getenv("HOMEBREW_PREFIX")) |p| std.mem.span(p) else null;
    const prefixes = [_]?[]const u8{ env_prefix, install_candidates[0], install_candidates[1] };
    for (prefixes) |maybe| {
        const prefix = maybe orelse continue;
        if (prefix.len == 0) continue;
        const dir = std.fmt.bufPrint(&S.dir_buf, "{s}/opt/maru-chromium/libexec", .{prefix}) catch continue;
        const host = std.fmt.bufPrintZ(&path_buf, "{s}/maru-web-host", .{dir}) catch continue;
        if (std.c.access(host, std.c.X_OK) == 0) {
            // 띄울 때 그 prefix 의 keg 인지 본다(`start` → `install.openBrewSource`).
            const n = @min(prefix.len, install_prefix_buf.len);
            @memcpy(install_prefix_buf[0..n], prefix[0..n]);
            install_prefix_len = n;
            return dir;
        }
    }
    return null;
}

fn setInstall(dir: []const u8) void {
    const n = @min(dir.len, install_buf.len);
    @memcpy(install_buf[0..n], dir[0..n]);
    install_len = n;
}

pub fn currentState() State {
    return state;
}

/// 이 surface 를 OSR 이 들고 있는가(control-plane 이 「이 엔진은 아직 지원하지 않는다」로 답할 때).
/// 시험 전용(W6i): sidecar 없이 탭 기록 하나를 두고 Chromium 엔진을 켠 것으로 친다 — 창 정리가 그 기록을 놓는지 본다.
/// 되돌리기는 `testForget`.
pub fn testHold(gpa: std.mem.Allocator, surface_id: u64) !void {
    if (!builtin.is_test) @compileError("test only");
    gpa_ref = gpa;
    decided = true;
    try surfaces.put(gpa, surface_id, .{ .record = .{ .surface_id = surface_id, .size = .{ .width = 10, .height = 10, .scale = 1 }, .hidden = false } });
}

/// 시험 전용(W6j): 엔진이 돌고 그 탭의 브라우저가 만들어진 것으로 친다 — 보낸 것은 버려진다(sidecar 없음). 되돌리기는 `testForget`.
pub fn testRunning(surface_id: u64) void {
    if (!builtin.is_test) @compileError("test only");
    state = .running;
    if (surfaces.getPtr(surface_id)) |s| s.created = true;
}

/// 시험 전용(W10c): sidecar 의 메시지 하나를 적용한다.
pub fn testApply(gpa: std.mem.Allocator, message: Message) void {
    if (!builtin.is_test) @compileError("test only");
    apply(gpa, message, 0);
}

pub fn testForget(gpa: std.mem.Allocator) void {
    if (!builtin.is_test) @compileError("test only");
    decided = null;
    state = .off;
    parked.deinit(gpa); // W10c: 받는 중인 탭을 닫으면 주차한다
    parked = .empty;
    if (surfaces.count() == 0) {
        surfaces.deinit(gpa);
        surfaces = .empty;
    }
}

pub fn owns(surface_id: u64) bool {
    return surfaces.contains(surface_id);
}

/// 창 배치 하나를 맞춘다(창 tick 의 web 전이 계산에서, OSR 대상 탭마다).
pub fn ensure(gpa: std.mem.Allocator, layout: plan.Layout, scale_milli: u32, now_ms: i64) void {
    gpa_ref = gpa;
    var commands: std.ArrayList(plan.Command) = .empty;
    defer commands.deinit(gpa);
    const existing = surfaces.getPtr(layout.surface_id);
    const fresh = (plan.reconcile(if (existing) |s| &s.record else null, layout, scale_milli, &commands, gpa) catch return) orelse null;
    if (fresh) |record| {
        surfaces.put(gpa, layout.surface_id, .{ .record = record, .stopped_notice_pending = latched != null, .page_opened = takePageOpened(layout.surface_id) }) catch return;
        // 판정자 전용(`MARU_WEB_OSR_TEST_URL`): 새 탭을 이 주소로 연다 — 스모크가 sidecar 까지의 경로(띄우기·handshake·
        // 생성·이동)를 시험 서버가 받은 요청으로 확인한다. 제품 사용자가 켤 이유는 없다.
        if (std.c.getenv("MARU_WEB_OSR_TEST_URL")) |test_url| navigate(gpa, layout.surface_id, std.mem.span(test_url));
    }
    if (commands.items.len == 0) return;
    if (latched != null) return; // 멈췄다 — 새로 띄우지 않는다
    if (state == .off) start(gpa, now_ms);
    for (commands.items) |command| {
        // 이 크기로 그리라고 보냈다 — 다른 크기 링(크기 변경 전환 프레임)에서는 꺼내지 않는다(W3c).
        switch (command) {
            .create => |c| if (surfaces.getPtr(c.browser)) |s| s.view.expect(pixels(c.size.width, c.size.scale), pixels(c.size.height, c.size.scale)),
            .resize => |c| if (surfaces.getPtr(c.browser)) |s| s.view.expect(pixels(c.size.width, c.size.scale), pixels(c.size.height, c.size.scale)),
            .set_hidden => {},
        }
        sendCommand(gpa, command);
    }
}

/// DIP × scale — CEF 가 그 크기로 그린 장의 픽셀 수(반올림).
fn pixels(dip: u32, scale: f32) u32 {
    return @intFromFloat(@round(@as(f32, @floatFromInt(dip)) * scale));
}

/// 이동(주소창·복원·링크). 아직 만들어지지 않았으면 만든 뒤 보낸다.
pub fn navigate(gpa: std.mem.Allocator, surface_id: u64, url: []const u8) void {
    const s = surfaces.getPtr(surface_id) orelse return;
    const owned = gpa.dupe(u8, url) catch return;
    if (s.last_url) |old| gpa.free(old);
    s.last_url = owned;
    if (s.created) send(gpa, .{ .navigate = .{ .browser = surface_id, .url = url } });
}

/// 사용자가 주소창에서 이 탭을 이동시켰다(W10a) — 친 주소가 곧바로 파일이면(문서를 커밋하지 않는다) 사용자가 시작한 다운로드다. 복원·
/// 페이지가 연 새 탭의 이동은 부르지 않는다. 주소가 문서를 열면 `page_started` 가 지운다.
pub fn noteUserNavigation(surface_id: u64) void {
    const s = surfaces.getPtr(surface_id) orelse return;
    s.download_gesture_ms = monotonicNow();
    // W10c: 사용자가 이 탭을 쓴다 — 페이지가 연 빈 탭이어도 이제 사용자의 탭이다(주소창에 친 파일 주소에 그 탭이 닫혔다 — 적대
    // 리뷰 2 회차).
    s.page_opened = false;
}

/// 이 탭의 다운로드용 사용자 동작 시각 — 페이지 입력과 다운로드만의 것 중 나중 것, 그 뒤로 새 문서가 오지 않았을 때만.
fn downloadGestureMs(s: *const Surface) i64 {
    const t = @max(s.last_user_input_ms, s.download_gesture_ms);
    return if (t > s.last_nav_ms) t else std.math.minInt(i64) / 2;
}

pub fn navAction(gpa: std.mem.Allocator, surface_id: u64, action: ws.message.NavActionKind) void {
    const s = surfaces.getPtr(surface_id) orelse return;
    if (s.created) send(gpa, .{ .nav_action = .{ .browser = surface_id, .action = action } });
}

/// 입력(W4b·W4c — 라우팅은 창이 정했다). 만들어졌고 sidecar 가 돌 때만 보낸다 — 입력은 쥐었다가 늦게 보낼 것이 아니다(첫
/// 프레임 전 입력은 렌더러도 버린다 — W4a 실측). 보냈으면 true.
pub fn sendInput(gpa: std.mem.Allocator, message: Message) bool {
    const browser: u64 = switch (message) {
        .mouse => |m| m.browser,
        .wheel => |m| m.browser,
        .key => |m| m.browser,
        .capture_lost, .ime_cancel_composition => |b| b,
        .ime_set_composition => |m| m.browser,
        .ime_commit_text => |m| m.browser,
        .ime_finish_composing => |m| m.browser,
        .edit_command => |m| m.browser,
        else => return false,
    };
    const s = surfaces.getPtr(browser) orelse return false;
    if (!s.created or state != .running) return false;
    switch (message) {
        .mouse => |m| if (m.kind == .down) {
            s.new_tab_credits.grant(monotonicNow());
            s.last_user_input_ms = monotonicNow();
            // W6m②: 칸 밖 본문 누름은 열린 제안 목록을 닫는다(Chrome 도 팝업 밖 누름에 닫는다) — 대리 스크립트의 닫기에만 기대면
            // 그 처리기를 지운 페이지(`document.open`)의 목록이 남았다(적대 검증 4 차). 칸 안은 두다 — 닫으면 페이지가 다시 보낼
            // 때까지 창이 숨었다 뜨며 깜빡였다(5 차).
            if (s.datalist) |d| if (!pointInRect(m.point, d.field)) dropDatalist(gpa, s);
        },
        .key => |k| {
            s.last_user_input_ms = monotonicNow();
            if (ws.new_tab.grantsActivation(k.kind, k.windows_key_code, k.native_key_code)) s.new_tab_credits.grant(monotonicNow());
        },
        .edit_command => s.last_user_input_ms = monotonicNow(),
        .ime_set_composition => |m| {
            s.last_user_input_ms = monotonicNow();
            if (!s.composing) s.ime_bounds = null; // 새 조합 — 옛 사각형을 쓰지 않는다
            s.composing = m.text.len > 0;
        },
        .ime_commit_text, .ime_finish_composing => {
            s.last_user_input_ms = monotonicNow();
            s.composing = false;
        },
        .ime_cancel_composition => {
            if (!s.composing) return false; // 조합이 없으면 취소는 선택을 지운다 — 보내지 않는다
            s.composing = false;
        },
        else => {},
    }
    send(gpa, message);
    return true;
}

/// 페이지에 조합이 열려 있다고 보는가.
pub fn composing(surface_id: u64) bool {
    const s = surfaces.getPtr(surface_id) orelse return false;
    return s.composing;
}

/// 키 포커스(W4c). 원하는 값을 기억하고 만들어졌으면 곧바로 보낸다 — 만들어지기 전이거나 sidecar 가 다시 떠도
/// `browser_created` 에서 되살린다(안 그러면 새 브라우저는 포커스 없이 키를 버린다).
pub fn setFocus(gpa: std.mem.Allocator, surface_id: u64, value: bool, window: usize) void {
    const s = surfaces.getPtr(surface_id) orelse return;
    if (value) {
        s.focus_owner = window;
    } else {
        if (s.focus_owner != window) return; // 다른 창이 이미 포커스를 가져갔다
        s.focus_owner = 0;
        s.composing = false; // 포커스를 잃으면 Chromium 이 조합을 확정한다
    }
    s.focused = value;
    if (s.created and state == .running) send(gpa, .{ .set_focus = .{ .browser = surface_id, .value = value } });
}

/// 마지막 IME 조합 사각형(view DIP). 없으면 null.
pub fn imeBounds(surface_id: u64) ?ws.message.Rect {
    const s = surfaces.getPtr(surface_id) orelse return null;
    return s.ime_bounds;
}

/// 이 탭이 원하는 커서와 그 세대(없는 탭이면 null).
pub fn cursor(surface_id: u64) ?Cursor {
    const s = surfaces.getPtr(surface_id) orelse return null;
    return .{ .cursor = s.cursor, .generation = s.cursor_generation };
}

/// 사용자가 닫는 탭 하나를 페이지에 묻는다(W6j — 떠나기 확인). 물을 수 없으면(sidecar 가 돌지 않는다·브라우저가 아직 없다·
/// 페이지가 이미 닫혔다) false — 호출자가 곧바로 닫는다. 이미 묻는 중이면 다시 보내지 않는다(CEF 도 한 번만 묻는다).
pub fn askClose(gpa: std.mem.Allocator, surface_id: u64, now_ms: i64) bool {
    const s = surfaces.getPtr(surface_id) orelse return false;
    if (state != .running or !s.created or s.page_closed) return false;
    switch (s.close_ask) {
        .asking, .asked => return true,
        .none, .closed, .stayed => {},
    }
    s.close_ask = .asking;
    s.close_ask_since_ms = now_ms;
    // W10c: 받던 다운로드가 있으면 닫지 않고 about:blank 로 보낸다(떠나기 확인은 이동에도 온다). 새 문서가 오면 닫힌 것으로 보고, 탭이
    // 사라지면 `destroy` 가 브라우저를 숨겨 남긴다.
    if (web_downloads.unfinishedFor(surface_id) > 0) {
        s.close_park = true;
        send(gpa, .{ .navigate = .{ .browser = surface_id, .url = "about:blank" } });
    } else {
        s.close_park = false;
        send(gpa, .{ .close_asking = surface_id });
    }
    return true;
}

/// 물은 닫기의 결과를 꺼낸다(W6j — 창의 tick). `closed`·`timed_out` 이면 창이 그 탭을 닫는다(강제 — `destroy`), `stayed` 는
/// 보고만 한다. 꺼내면 지운다. sidecar 가 내려갔으면(다시 뜨면 그 페이지를 되살린다) 시한을 기다리지 않는다 — 사용자는 닫기를 골랐다.
pub fn takeCloseAsk(surface_id: u64, now_ms: i64) CloseAskOutcome {
    const s = surfaces.getPtr(surface_id) orelse return .none;
    switch (s.close_ask) {
        .none => return .none,
        .asked => return .waiting,
        .closed => {
            s.close_ask = .none;
            return .closed;
        },
        .stayed => {
            s.close_ask = .none;
            s.close_park = false;
            return .stayed;
        },
        .asking => {
            if (state == .running and now_ms - s.close_ask_since_ms < close_ask_wait_ms) return .waiting;
            s.close_ask = .none;
            return .timed_out;
        },
    }
}

/// 꺼내 간 창이 지금 닫지 못했다(닫기 확인·탭 끌기 중) — 다음 tick 에 다시(W6j).
pub fn markCloseAskClosed(surface_id: u64) void {
    if (surfaces.getPtr(surface_id)) |s| s.close_ask = .closed;
}

/// Term 이 사라졌다 — 브라우저를 파괴한다. 마지막이면 sidecar 도 내린다.
pub fn destroy(gpa: std.mem.Allocator, surface_id: u64) void {
    var kv = surfaces.fetchSwapRemove(surface_id) orelse return;
    // Term 이 사라졌다 — 다음 프레임부터 그리지 않는다. 이미 GPU 에 올라간 장은 renderer 캐시의 텍스처가 IOSurface 를
    // 쥐고 있어 여기서 놓아도 안전하다.
    for (kv.value.view.clear()) |ring| if (ring) |r| r.release();
    for (kv.value.popup_view.clear()) |ring| if (ring) |r| r.release();
    const was_created = kv.value.created;
    freeSurface(gpa, &kv.value);
    const live = state == .running or state == .starting;
    // W10c: 받던 다운로드가 있으면 닫지 않고 숨겨 남긴다 — 닫으면 Chromium 이 서버 연결을 끊고 받던 파일을 지운다(실측 — 판정
    // `dl-closed`). about:blank 로 보내 페이지는 끝낸다(숨김·이동만으로 끝까지 받는다 — 판정 `dl-park`).
    if (live and was_created and web_downloads.unfinishedFor(surface_id) > 0) {
        park(gpa, surface_id);
    } else if (live) send(gpa, .{ .destroy_browser = surface_id });
    if (surfaces.count() == 0 and parked.count() == 0) retire(gpa, monotonicNow());
}

fn park(gpa: std.mem.Allocator, surface_id: u64) void {
    parked.put(gpa, surface_id, {}) catch {
        send(gpa, .{ .destroy_browser = surface_id }); // 기록할 수 없다 — 쥐지 못할 브라우저는 닫는다(다운로드는 끊긴다)
        return;
    };
    send(gpa, .{ .set_focus = .{ .browser = surface_id, .value = false } });
    send(gpa, .{ .set_hidden = .{ .browser = surface_id, .value = true } });
    send(gpa, .{ .navigate = .{ .browser = surface_id, .url = "about:blank" } });
    if (testReporting()) std.debug.print("osr-test download-park parked={d}\n", .{parked.count()});
}

/// 판정 모드(스모크 대본 — `MARU_WEB_OSR_TEST_INPUT`)에서만 보고 줄을 남긴다.
fn testReporting() bool {
    return !builtin.is_test and std.c.getenv("MARU_WEB_OSR_TEST_INPUT") != null;
}

/// 주차한 브라우저 중 다운로드가 모두 끝난 것을 닫는다(W10c — `pump`). 마지막이면 sidecar 도 내린다.
fn releaseParked(gpa: std.mem.Allocator, now_ms: i64) void {
    if (parked.count() == 0) return;
    var i: usize = 0;
    while (i < parked.count()) {
        const id = parked.keys()[i];
        if (web_downloads.unfinishedFor(id) > 0) {
            i += 1;
            continue;
        }
        parked.swapRemoveAt(i);
        send(gpa, .{ .destroy_browser = id });
        if (testReporting()) std.debug.print("osr-test download-park released parked={d} tabs={d}\n", .{ parked.count(), surfaces.count() });
    }
    if (parked.count() == 0 and surfaces.count() == 0) retire(gpa, now_ms);
}

/// 그 탭의 브라우저가 sidecar 에 살아 있는가(W10c — 물은 닫기가 about:blank 로 끝나면 브라우저는 그대로다).
pub fn browserLive(surface_id: u64) bool {
    const s = surfaces.getPtr(surface_id) orelse return false;
    return s.created;
}

/// 주차한 브라우저 수(W10c — 시험·판정).
pub fn parkedCount() usize {
    return parked.count();
}

/// 페이지가 연 새 탭의 번호(W10c — 기록이 아직 없다. 배치가 와 기록이 생기면 `page_opened` 가 선다).
pub fn notePageOpened(surface_id: u64) void {
    page_opened_pending[page_opened_next] = surface_id;
    page_opened_next = (page_opened_next + 1) % page_opened_pending.len;
}

fn takePageOpened(surface_id: u64) bool {
    for (&page_opened_pending) |*id| if (id.* == surface_id) {
        id.* = 0;
        return true;
    };
    return false;
}

/// 꺼내 간 창이 지금 닫지 못했다(확인 모달·탭 끌기 중) — 다음 tick 에 다시(W10c).
pub fn markDownloadBlank(surface_id: u64) void {
    if (surfaces.getPtr(surface_id)) |s| s.download_blank = true;
}

/// 문서 없이 다운로드만 한 페이지가 연 탭인가(W10c) — 그 탭이 있는 창이 꺼내 가 닫는다(한 번).
pub fn takeDownloadBlank(surface_id: u64) bool {
    const s = surfaces.getPtr(surface_id) orelse return false;
    if (!s.download_blank) return false;
    // 「매번 묻기」의 저장 창이 아직 어느 창에도 뜨지 않았다 — 이 탭(활성)이 띄울 차례다. 먼저 닫으면 저장 창이 뜰 탭이 없어 1 초 뒤
    // 목록 창으로 밀렸다(W10c 적대 리뷰 1 회차). 저장 창이 뜨면(맡으면) 닫는다 — 답은 행 번호로 간다.
    if (web_downloads.unclaimedAskFor(surface_id)) return false;
    s.download_blank = false;
    return true;
}

/// 창 tick 마다 부른다 — 파이프를 비우고 알림을 적용하고, 죽었으면 다시 띄운다. 여러 창이 불러도 값싸다.
pub fn pump(gpa: std.mem.Allocator, now_ms: i64) void {
    gpa_ref = gpa;
    reapRetiring(gpa, now_ms);
    const generation = process_generation;
    const p = if (process) |*p| p else {
        // sidecar 가 멈췄어도(실패·프로필 사용 중) 붙이지 못한 팝업의 만료·정리는 한다 — 기록이 앱이 끝날 때까지 남지 않게(W6f② 적대 검증
        // 2 차). 보낼 곳이 없으면 `destroy` 는 보내지 않고 지우기만 한다.
        expireNewTabs(gpa, now_ms);
        closeOrphanPopups(gpa);
        web_downloads.reapPrepared(); // W10a: 내린 뒤 작업 스레드가 만든 임시 파일도 지운다(적대 리뷰 2 회차)
        web_downloads.nudgeAsking(now_ms);
        return;
    };
    _ = lsp_process.flush(p, gpa) catch {};
    // 청한 파일 내용을 받는 동안은 한 번에 더 읽는다 — sidecar 는 다 보낼 때까지 CEF 스레드(모든 Chromium 탭)에서 쓰기를 기다린다.
    // tick 마다 256 KiB 면 32 MiB 에 2 초 넘게 탭이 멈췄다(W6d③ 적대 검증 2 차).
    const budget: usize = if (fileFetchPending()) 8 * 1024 * 1024 else 256 * 1024;
    const read = lsp_process.readInto(p, gpa, &inbox, budget) catch .eof;
    drainInbox(gpa, now_ms);
    web_downloads.drain(gpa); // W10a: 작업 스레드가 만든 경로·목록 창의 누름을 sidecar 로
    web_downloads.nudgeAsking(now_ms); // W10b: 저장 창이 뜰 곳이 없는 묻는 행은 목록 창으로
    expireContextMenus(gpa, now_ms);
    expireDragOuts(gpa, now_ms);
    expireNewTabs(gpa, now_ms);
    receiveRings();
    closeOrphanPopups(gpa);
    // 비우는 사이 sidecar 가 끝났거나(`profile_in_use` 로 멈춤) 다시 떴다 — 위의 `read`·`p` 는 옛 프로세스의 것이다.
    // 처음엔 그대로 이어가 옛 EOF 로 새 sidecar 를 또 죽은 것으로 세거나, 비운 optional 을 읽었다(적대 점검).
    if (process == null or process_generation != generation) return;
    if (read == .eof or lsp_process.reapIfExited(&process.?)) return onExited(gpa, now_ms, generation);
    if (state == .starting and now_ms - started_ms > handshake_timeout_ms) {
        lsp_process.kill(&process.?, .KILL);
        return crashed(gpa, now_ms);
    }
    // W10c: 다운로드가 끝난 주차 브라우저를 닫는다(마지막이면 sidecar 도 내린다 — 내림이 `process` 를 비우므로 맨 끝에서).
    releaseParked(gpa, now_ms);
}

/// sidecar 가 끝났다(EOF 또는 거둠). 읽기와 거두기 사이에 끝났을 수 있다 — 끝나기 직전에 쓴 frame(버전 불일치의 `hello_ack`
/// 등)을 마저 읽고 적용한 뒤 판정한다. 안 읽으면 버전 불일치가 크래시로 세어져 재시작 셋 뒤 「거듭 멈춤」으로 잘못 안내된다
/// (W7a1 적대 검증).
fn onExited(gpa: std.mem.Allocator, now_ms: i64, generation: u64) void {
    if (lsp_process.readInto(&process.?, gpa, &inbox, 256 * 1024)) |_| {} else |_| {}
    drainInbox(gpa, now_ms);
    if (process == null or process_generation != generation) return;
    crashed(gpa, now_ms);
}

/// 이 surface 에 새 프레임이 있으면 front 로 삼는다(W3c). `completed_generation` 은 그 창에서 GPU 가 끝낸 마지막
/// 프레임 세대다 — 지금 front 를 그린 프레임이 안 끝났으면 꺼내지 않는다. 새 프레임이면 true(창을 다시 그린다).
pub fn pollFrame(surface_id: u64, completed_generation: u64, window: usize) bool {
    const s = surfaces.getPtr(surface_id) orelse return false;
    // 다른 창이 마지막으로 그렸다(탭이 창을 옮겼다) — 그 창의 세대는 이 창의 완료 세대와 셈이 달라 영영 끝나지 않은 것으로
    // 보인다. 옛 창은 이제 이 탭을 그리지 않으니 막지 않는다.
    const completed = if (s.drawn_by == 0 or s.drawn_by == window) completed_generation else std.math.maxInt(u64);
    const polled = s.view.poll(completed);
    for (polled.retired) |ring| if (ring) |r| r.release();
    if (polled.corrupt) rejected_rings += 1;
    const popup_completed = if (s.popup_drawn_by == 0 or s.popup_drawn_by == window) completed_generation else std.math.maxInt(u64);
    const popup = s.popup_view.poll(popup_completed);
    for (popup.retired) |ring| if (ring) |r| r.release();
    if (popup.corrupt) rejected_rings += 1;
    const shown_generation: ?u32 = if (s.popup_view.shown) |r| r.generation else null;
    if (osr_input.popupReleasable(s.popup_bounds != null, s.popup_release_generation, shown_generation, s.popup_view.pending != null, s.popup_view.drawn_generation, popup_completed)) {
        for (s.popup_view.clear()) |ring| if (ring) |r| r.release();
        s.popup_release_generation = 0;
    }
    const redraw = s.popup_redraw;
    s.popup_redraw = false;
    return polled.new_frame or (popup.new_frame and s.popup_bounds != null) or redraw;
}

/// 지금 그릴 front(첫 프레임 전이면 null).
pub fn front(surface_id: u64) ?Front {
    const s = surfaces.getPtr(surface_id) orelse return null;
    if (!s.view.has_frame) return null;
    const shown = s.view.shown orelse return null;
    return .{ .surface = shown.ring.surfaces[s.view.front], .width = shown.ring.width, .height = shown.ring.height };
}

/// 그릴 팝업 위젯(W6a②) — 열려 있고, 그 팝업의 첫 세대 이상인 링의 실제 프레임이 있을 때만. 링은 보임 알림보다 먼저 올
/// 수 있고 닫히기 직전 팝업의 링이 늦게 올 수도 있어 **그릴 때** 첫 세대로 거른다(받을 때 거르면 다시 알리지 않는 첫 링을
/// 잃는다). 크기는 `popup_view.expect`(사각형 × scale ±1)가 거른다.
pub const PopupFront = struct { front: Front, bounds: ws.message.Rect };

pub fn popupFront(surface_id: u64) ?PopupFront {
    const s = surfaces.getPtr(surface_id) orelse return null;
    const shown_generation: ?u32 = if (s.popup_view.shown) |r| r.generation else null;
    if (!osr_input.popupShows(s.popup_bounds != null, s.popup_view.has_frame, shown_generation, s.popup_first_generation)) return null;
    const bounds = s.popup_bounds.?;
    const shown = s.popup_view.shown.?;
    return .{ .front = .{ .surface = shown.ring.surfaces[s.popup_view.front], .width = shown.ring.width, .height = shown.ring.height }, .bounds = bounds };
}

/// 이 프레임(세대)이 그 surface 의 팝업 front 를 그렸다(GPU 소비자 규칙).
pub fn drewPopup(surface_id: u64, frame_generation: u64, window: usize) void {
    const s = surfaces.getPtr(surface_id) orelse return;
    s.popup_view.drew(frame_generation);
    s.popup_drawn_by = window;
}

/// 키 대상 탭에 팝업이 열려 있는가(W6a② — 열린 목록의 키는 입력기를 거치지 않는다).
pub fn popupOpen(surface_id: u64) bool {
    const s = surfaces.getPtr(surface_id) orelse return false;
    return s.popup_bounds != null;
}

/// 팝업이 닫혔다 — 그리지 않는다(다시 그려 지운다). 그때 보이던 링은 GPU 가 끝난 뒤 놓는다(`popup_release_generation` —
/// 기다리는 다음 팝업의 링은 남긴다, `popup_view` 주석).
fn hidePopup(s: *Surface) void {
    s.popup_bounds = null;
    s.popup_first_generation = 0;
    s.popup_redraw = true;
    s.popup_release_generation = if (s.popup_view.shown) |r| r.generation else 0;
}

/// 브라우저·sidecar 가 사라졌다 — 링까지 곧바로 놓는다. 생산자는 이미 없고(더 덮어쓰지 않는다), GPU 가 읽던 장은 renderer
/// 캐시의 텍스처가 IOSurface 를 쥐고 있어 놓아도 안전하다(`destroy` 와 같은 근거). 새 sidecar·새 브라우저는 세대를 1 부터
/// 세므로 옛 링을 남기면 첫 세대 거르기를 지나 옛 목록이 비친다.
fn dropPopup(s: *Surface) void {
    hidePopup(s);
    for (s.popup_view.clear()) |ring| if (ring) |r| r.release();
    s.popup_release_generation = 0;
}

/// 이 프레임(세대)이 그 surface 의 front 를 그렸다.
pub fn drew(surface_id: u64, frame_generation: u64, window: usize) void {
    const s = surfaces.getPtr(surface_id) orelse return;
    s.view.drew(frame_generation);
    s.drawn_by = window;
}

/// 이 surface 의 새 주소·탐색 상태(있으면 한 번). 창이 자기 surface 에만 부른다.
pub fn takeNavUpdate(surface_id: u64) ?NavUpdate {
    const s = surfaces.getPtr(surface_id) orelse return null;
    if (!s.nav_dirty) return null;
    s.nav_dirty = false;
    return .{ .surface_id = surface_id, .url = s.url orelse "", .can_go_back = s.can_go_back, .can_go_forward = s.can_go_forward };
}

/// 이 surface 에 GPU 불가 안내가 걸려 있는가(한 번).
pub fn takeGpuNotice(surface_id: u64) bool {
    const s = surfaces.getPtr(surface_id) orelse return false;
    defer s.gpu_notice_pending = false;
    return s.gpu_notice_pending;
}

/// 이 탭에 걸린 「엔진이 멈췄다」 안내(탭마다 한 번 — 그 탭의 창이 보인다).
pub fn takeStoppedNotice(surface_id: u64) ?Notice {
    const s = surfaces.getPtr(surface_id) orelse return null;
    if (!s.stopped_notice_pending) return null;
    s.stopped_notice_pending = false;
    return latched;
}

/// 앱 종료 — shutdown 을 보내고 잠시 기다린 뒤 남았으면 죽인다. sidecar 는 부모(maru)가 사라지면 스스로도 끝난다.
pub fn shutdownForExit() void {
    const gpa = gpa_ref orelse return;
    stop(gpa);
    // 받던 다운로드는 sidecar 와 함께 멈췄다 — 덜 받은 임시 파일(격리 표지 없음)을 남기지 않는다(W10a 적대 리뷰 3 회차). 종료 확인이 받는 중인 수를 알렸다(W10c).
    web_downloads.sidecarLost();
    web_downloads.reapPrepared(); // 작업 스레드가 만들었지만 아직 반영하지 않은 임시 파일도(4 회차) — 아직 도는 스레드는 W10d
    if (retiring) |*old| {
        // 앱이 끝난다 — 물러나던 sidecar 도 기한 안에 거둔다(앱 종료는 기다려도 된다).
        var waited: i64 = 0;
        while (waited < shutdown_wait_ms and !lsp_process.reapIfExited(old)) : (waited += 20) sleepMs(20);
        if (waited >= shutdown_wait_ms) {
            lsp_process.kill(old, .KILL);
            lsp_process.reapBlocking(old);
        }
        old.deinit(gpa);
        retiring = null;
    }
    releaseRunCopy(&retiring_copy);
    clearDownloadStaging(profile_held or retiring_profile_held); // W10b: 결정 전에 받아 둔 것 — 물러나던 sidecar 까지 거둔 뒤(5 회차)
    profile_held = false;
    retiring_profile_held = false;
    var it = surfaces.iterator();
    while (it.next()) |entry| {
        for (entry.value_ptr.view.clear()) |ring| if (ring) |r| r.release();
        for (entry.value_ptr.popup_view.clear()) |ring| if (ring) |r| r.release();
        freeSurface(gpa, entry.value_ptr);
    }
    surfaces.deinit(gpa);
    if (receiver) |*r| r.close();
    receiver = null;
    surfaces = .empty;
    inbox.deinit(gpa);
    inbox = .empty;
    outbox_pending.deinit(gpa);
    outbox_pending = .empty;
}

// ── 대화상자·파일 선택(W5a) ────────────────────────────────────────────────────────────────────────────
//
// 창은 자기 창에서 **키보드 초점을 가진** Chromium 탭의 요청만 띄운다(뒤쪽 탭·초점 없는 pane 의 대화상자는 초점이 올 때까지
// 기다린다 — 페이지는 그동안 멈춰 있다). 한 창에 하나씩 — sheet 는 창 전체를 막는다.

/// 요청을 적는다. 모르는 브라우저(파괴 경합)·상한·메모리 부족이면 false — 호출자가 곧바로 기본값으로 답한다.
fn queueDialog(gpa: std.mem.Allocator, browser: u64, request: ws.message.RequestId, kind: DialogKind, origin: []const u8, message_text: []const u8, default_text: []const u8, accept: []const u8, offer_suppress: bool) bool {
    const s = surfaces.getPtr(browser) orelse return false;
    if (s.dialogs.items.len >= max_dialogs_per_surface) return false;
    const origin_owned = gpa.dupe(u8, origin) catch return false;
    const message_owned = gpa.dupe(u8, message_text) catch {
        gpa.free(origin_owned);
        return false;
    };
    const default_owned = gpa.dupe(u8, default_text) catch {
        gpa.free(origin_owned);
        gpa.free(message_owned);
        return false;
    };
    const accept_owned = gpa.dupe(u8, accept) catch {
        gpa.free(origin_owned);
        gpa.free(message_owned);
        gpa.free(default_owned);
        return false;
    };
    const dialog: Dialog = .{ .token = next_dialog_token, .request = request, .kind = kind, .origin = origin_owned, .message = message_owned, .default_text = default_owned, .accept = accept_owned, .offer_suppress = offer_suppress };
    next_dialog_token += 1;
    s.dialogs.append(gpa, dialog) catch {
        dialog.free(gpa);
        return false;
    };
    return true;
}

/// 권한 요청(W5b)을 적는다 — 대화상자와 같은 대기열·상한·토큰.
fn queuePermission(gpa: std.mem.Allocator, v: ws.message.PermissionRequest) bool {
    if (!queueDialog(gpa, v.browser, v.request, .permission, v.origin, "", "", "", false)) return false;
    const s = surfaces.getPtr(v.browser).?;
    const d = &s.dialogs.items[s.dialogs.items.len - 1];
    d.permission_kinds = v.kinds;
    d.permission_media = v.media;
    // sheet 없이 답하는 것은 maru 가 스스로 기록한 (탭, 출처)만 — sidecar 의 표시만으로는 아니다(적대 검증).
    d.remembered = v.remembered and locationAllowed(v.browser, v.origin);
    return true;
}

/// W5b2 좌표. null 이면 「없음」(페이지는 「위치를 알 수 없음」).
pub const Position = struct { latitude: f64, longitude: f64, accuracy: f64 };

fn removeDialog(gpa: std.mem.Allocator, s: *Surface, token: u64) void {
    for (s.dialogs.items, 0..) |d, i| if (d.token == token) {
        d.free(gpa);
        _ = s.dialogs.orderedRemove(i);
        return;
    };
}

/// 그 탭에서 다음에 띄울 요청(아직 아무 창도 안 띄운 첫 요청). 앞 요청이 떠 있으면 null — 한 탭은 하나씩. 기억된 위치
/// 요청(W5b2)은 sheet 가 없으니 건너뛴다(`nextLocation`).
pub fn nextDialog(surface_id: u64) ?*const Dialog {
    const s = surfaces.getPtr(surface_id) orelse return null;
    for (s.dialogs.items) |*d| {
        if (d.remembered) continue;
        return if (d.shown_by == 0) d else null;
    }
    return null;
}

/// W5b2: 아직 아무 창도 맡지 않은 기억된 위치 요청(모든 탭에서 — 보이지 않는 탭도 sheet 없이 답한다). 맡은 창을 적는다.
pub fn nextLocation(window: usize) ?struct { surface_id: u64, token: u64 } {
    for (surfaces.keys(), surfaces.values()) |surface_id, *s| {
        for (s.dialogs.items) |*d| if (d.remembered and d.shown_by == 0) {
            d.shown_by = window;
            return .{ .surface_id = surface_id, .token = d.token };
        };
    }
    return null;
}

/// W5b2: 위치 요청의 답 — `accept` 면 좌표(없으면 「없음」)를 먼저 걸고 허용한다(허용 뒤에 걸면 기다리던 요청이 실패한다 —
/// 실측), 아니면 그 답만. 답했으면 true — 위치 요청이 아니거나 이미 사라졌으면 false.
pub fn replyLocation(gpa: std.mem.Allocator, surface_id: u64, token: u64, position: ?Position, result: ws.message.PermissionResult) bool {
    const s = surfaces.getPtr(surface_id) orelse return false;
    const d = dialogPending(surface_id, token) orelse return false;
    if (d.kind != .permission or d.permission_kinds & ws.message.PermissionKind.geolocation.bit() == 0) return false;
    const request = d.request;
    // 기다리는 사이 그 출처를 차단했다 — 허용으로 답하지 않는다(늦은 허용이 차단을 덮어쓰지 않게).
    const effective: ws.message.PermissionResult = if (d.revoked and result == .accept) .ignore else result;
    // sheet 에서 허용했다 — 이 탭에서 이 출처의 다음 요청(Chromium 은 부를 때마다 묻는다)은 sheet 없이 답한다.
    if (!d.remembered and effective == .accept) allowLocation(gpa, surface_id, d.origin);
    removeDialog(gpa, s, token);
    if (!s.created) return true;
    if (effective == .accept) {
        const geo: ws.message.Geolocation = if (position) |p| .{ .browser = surface_id, .request = request, .available = true, .latitude = p.latitude, .longitude = p.longitude, .accuracy = p.accuracy } else .{ .browser = surface_id, .request = request, .available = false };
        // 규칙(범위·유한)을 못 지나는 좌표는 「없음」으로.
        ws.fields.checkGeolocation(geo) catch {
            send(gpa, .{ .geolocation = .{ .browser = surface_id, .request = request, .available = false } });
            send(gpa, .{ .permission_reply = .{ .browser = surface_id, .request = request, .result = .accept } });
            return true;
        };
        send(gpa, .{ .geolocation = geo });
    }
    send(gpa, .{ .permission_reply = .{ .browser = surface_id, .request = request, .result = effective } });
    return true;
}

pub fn markDialogShown(surface_id: u64, token: u64, window: usize) void {
    const s = surfaces.getPtr(surface_id) orelse return;
    for (s.dialogs.items) |*d| if (d.token == token) {
        d.shown_by = window;
        return;
    };
}

/// 그 요청이 아직 답을 기다리는가 — 창은 떠 있는 요청이 사라지면(이동·닫힘·sidecar 재시작) 창을 닫는다.
pub fn dialogPending(surface_id: u64, token: u64) ?*const Dialog {
    const s = surfaces.getPtr(surface_id) orelse return null;
    for (s.dialogs.items) |*d| if (d.token == token) return d;
    return null;
}

/// JS 대화상자의 답. 요청이 없으면(이미 사라졌다) 무동작. `suppress` 면 그 페이지가 이동할 때까지 대화상자를 더 띄우지 못한다.
pub fn replyDialog(gpa: std.mem.Allocator, surface_id: u64, token: u64, accept: bool, text: []const u8, suppress: bool) void {
    const s = surfaces.getPtr(surface_id) orelse return;
    const d = dialogPending(surface_id, token) orelse return;
    if (d.kind.isFile() or d.kind == .permission) return;
    const request = d.request;
    // 답 글은 대화상자 글 규칙(상한·제어 문자)에 맞게 다듬는다 — 글자 경계에서 자르고 줄바꿈·탭 밖의 제어 문자는 공백으로
    // (통째로 버리면 긴 답이 빈 답이 된다 — 적대 검증).
    var buf: [ws.wire.max_text_bytes]u8 = undefined;
    const clamped = ws.text.clampUtf8(text, buf.len);
    @memcpy(buf[0..clamped.len], clamped);
    ws.text.replaceControlKeepLines(buf[0..clamped.len]);
    // 물은 닫기의 떠나기 확인(W6j): 떠나기면 닫힘을 기다린다(시한 — 안 닫히면 강제), 머무르기면 탭을 둔다.
    if (d.kind == .before_unload and s.close_ask == .asked) {
        s.close_ask = if (accept) .asking else .stayed;
        s.close_ask_since_ms = monotonicNow();
    }
    removeDialog(gpa, s, token);
    if (s.created) send(gpa, .{ .dialog_reply = .{ .browser = surface_id, .request = request, .accept = accept, .text = buf[0..clamped.len], .suppress = suppress } });
}

/// 파일 선택의 경로 하나(여러 개면 여러 번). 경로 규칙을 못 지나면 버린다.
pub fn fileDialogPath(gpa: std.mem.Allocator, surface_id: u64, token: u64, path: []const u8) void {
    const s = surfaces.getPtr(surface_id) orelse return;
    const d = dialogPending(surface_id, token) orelse return;
    if (!d.kind.isFile()) return;
    ws.fields.checkPath(path) catch return;
    if (s.created) send(gpa, .{ .file_dialog_path = .{ .browser = surface_id, .request = d.request, .path = path } });
}

pub fn replyFileDialog(gpa: std.mem.Allocator, surface_id: u64, token: u64, accept: bool) void {
    const s = surfaces.getPtr(surface_id) orelse return;
    const d = dialogPending(surface_id, token) orelse return;
    if (!d.kind.isFile()) return;
    const request = d.request;
    removeDialog(gpa, s, token);
    if (s.created) send(gpa, .{ .file_dialog_reply = .{ .browser = surface_id, .request = request, .accept = accept } });
}

/// 권한 요청의 답(W5b). 허용·차단은 Chromium 이 출처별로 기억하고(프롬프트 — 미디어는 기억하지 않는다), 닫기·못 물음은
/// 기억하지 않는다. 답했으면 true — 권한 요청이 아니거나 이미 사라졌으면(이동·닫힘) false.
pub fn replyPermission(gpa: std.mem.Allocator, surface_id: u64, token: u64, result: ws.message.PermissionResult) bool {
    const s = surfaces.getPtr(surface_id) orelse return false;
    const d = dialogPending(surface_id, token) orelse return false;
    if (d.kind != .permission) return false;
    const request = d.request;
    // 위치를 차단했다 — maru 의 기록에서도 빼고, 같은 출처의 기다리던 허용을 거둔다(Chromium 도 차단을 기억해 다시 묻지 않는다).
    if (result == .deny and d.permission_kinds & ws.message.PermissionKind.geolocation.bit() != 0) {
        forgetLocationOrigin(gpa, d.origin);
        revokeLocationOrigin(d.origin, token);
    }
    removeDialog(gpa, s, token);
    if (s.created) send(gpa, .{ .permission_reply = .{ .browser = surface_id, .request = request, .result = result } });
    return true;
}

/// 창이 닫힌다 — 그 창이 띄운 요청은 취소로 답한다(다른 창이 다시 띄우지 않는다). 기억된 위치 요청은 창에 묶이지 않아 맡음만
/// 푼다(다른 창 탭의 요청일 수 있다).
pub fn cancelDialogsShownBy(gpa: std.mem.Allocator, window: usize) void {
    for (surfaces.keys(), surfaces.values()) |surface_id, *s| {
        var i: usize = 0;
        while (i < s.dialogs.items.len) {
            const d = s.dialogs.items[i];
            if (d.shown_by != window) {
                i += 1;
                continue;
            }
            // 권한은 「못 물음」 — 차단은 Chromium 이 그 사이트에 기억하고 닫기는 embargo 를 쌓는다(사용자가 고르지 않았다).
            // 기억된 위치 요청은 창에 묶이지 않는다 — 맡음만 풀어 다른 창이 맡게 한다(다른 창 탭의 요청을 끝내지 않게 — 적대 검증).
            if (d.kind == .permission and d.remembered) {
                s.dialogs.items[i].shown_by = 0;
                i += 1;
                continue;
            }
            if (d.kind.isFile()) replyFileDialog(gpa, surface_id, d.token, false) else if (d.kind == .permission) {
                _ = replyPermission(gpa, surface_id, d.token, .ignore);
            } else replyDialog(gpa, surface_id, d.token, d.kind == .before_unload, "", false);
        }
    }
}

// ── 안 ─────────────────────────────────────────────────────────────────────────────────────────────

/// 탭의 우클릭 메뉴(W6c②). sidecar 가 CEF 메뉴 콜백을 쥐고 답을 기다린다 — 띄웠든 아니든 답은 정확히 한 번 간다(`answerContextMenu`
/// 또는 이 파일의 취소). sidecar 가 먼저 닫으면(이동·탭 닫힘 — `context_menu_closed`) 답하지 않는다.
pub const ContextMenu = struct {
    menu: u32,
    /// 우클릭한 자리(view DIP).
    point: ws.message.Point,
    flags: ws.message.ContextMenuFlags,
    /// 선택한 글(소유 — 비었으면 빈 조각). 「찾기」·음성·서비스가 쓴다.
    selection: []u8,
    arrived_ms: i64,
    /// 창이 가져가 메뉴를 띄웠다.
    shown: bool = false,
    /// sidecar 가 닫았다 — 띄운 창이 다음 tick 에 메뉴를 거둔다(그 뒤 답은 보내지 않는다).
    closed: bool = false,
};

/// 이만큼 지나도 어느 창도 가져가지 않은 메뉴는 취소한다 — 메뉴가 오기 전에 탭을 바꿨다(그 탭이 어느 창에도 보이지 않는다).
/// 쥔 채 두면 sidecar 의 CEF 는 메뉴가 떠 있다고 보고 그 탭의 다음 우클릭을 버린다(W6c① 판정 중 실측).
const context_menu_pickup_ms = 2_000;

fn dropContextMenu(gpa: std.mem.Allocator, s: *Surface) void {
    const m = s.context_menu orelse return;
    gpa.free(m.selection);
    s.context_menu = null;
}

/// 답하지 않은 메뉴를 취소로 끝낸다(sidecar 가 닫지 않았으면 취소를 보낸다).
fn cancelContextMenu(gpa: std.mem.Allocator, s: *Surface) void {
    const m = s.context_menu orelse return;
    if (!m.closed) send(gpa, .{ .context_menu_command = .{ .browser = s.record.surface_id, .menu = m.menu, .command = .cancel } });
    dropContextMenu(gpa, s);
}

fn expireContextMenus(gpa: std.mem.Allocator, now_ms: i64) void {
    for (surfaces.values()) |*s| if (s.context_menu) |m| {
        if (!m.shown and now_ms - m.arrived_ms > context_menu_pickup_ms) cancelContextMenu(gpa, s);
    };
}

/// 그 탭에 아직 띄우지 않은 메뉴가 있으면 띄운 것으로 하고 돌려준다(창이 가져간다 — 한 창만).
pub fn takeContextMenu(surface_id: u64) ?struct { menu: u32, point: ws.message.Point, flags: ws.message.ContextMenuFlags } {
    const s = surfaces.getPtr(surface_id) orelse return null;
    if (s.context_menu == null) return null;
    const held = &s.context_menu.?;
    if (held.shown or held.closed) return null;
    held.shown = true;
    return .{ .menu = held.menu, .point = held.point, .flags = held.flags };
}

/// 띄운 그 메뉴가 아직 열려 있어야 하는가 — sidecar 가 닫았거나(이동·닫힘) 탭이 사라졌으면 false.
pub fn contextMenuOpen(surface_id: u64, menu: u32) bool {
    const s = surfaces.getPtr(surface_id) orelse return false;
    const m = s.context_menu orelse return false;
    // 띄운 것만 — sidecar 를 다시 띄운 뒤 같은 번호의 새(안 띄운) 메뉴가 옛 NSMenu 를 열어 두지 않게(W6c② 적대 검증 2 차).
    return m.shown and m.menu == menu and !m.closed;
}

// ── W6d①: 밖에서 끌어 놓기 ─────────────────────────────────────────────────────────────────────────
// 창(AppSession)이 끌기 동안 끌어 온 것을 쥐고, 포인터가 Chromium 탭 본문에 들어오면 `dragEnter` 로 조각과 enter 를 보낸다.
// 여기는 탭마다 「enter 를 보냈는가」와 페이지가 받아들이는 동작만 든다.

/// 끌어 온 것(W6d①). 창이 쥔 것을 빌린다.
pub const DragPayload = struct {
    paths: []const []const u8 = &.{},
    text: []const u8 = "",
    html: []const u8 = "",
    url: []const u8 = "",
    url_title: []const u8 = "",
    /// 0 이 아니면 maru 의 Chromium 탭에서 시작한 그 끌기(`drag_out` 번호) — 위 조각 대신 그 데이터를 쓴다(W6d②).
    source: u32 = 0,
};

/// 조각 상한 — sidecar(`drag.max_paths`·`max_text_total`)와 같다. 글·HTML 은 넘으면 글자 경계에서 자른다.
pub const max_drag_paths = 4096;
pub const max_drag_text = 1024 * 1024;

fn forgetDrag(s: *Surface) void {
    s.drag_entered = false;
    s.drag_operation = 0;
}

/// 끌기가 그 탭 본문에 들어왔다 — 조각을 보내고 enter. 탭이 아직 없으면(sidecar 가 만들기 전 — 다시 뜬 sidecar 도) false.
/// 경로 규칙(절대·제어 문자 없음·4 KiB)을 못 지나는 경로와 상한 넘은 경로는 빠진다.
pub fn dragEnter(gpa: std.mem.Allocator, surface_id: u64, payload: DragPayload, point: ws.message.Point, modifiers: ws.message.Modifiers, allowed: u32) bool {
    const s = surfaces.getPtr(surface_id) orelse return false;
    if (!s.created) return false;
    // maru 의 Chromium 탭에서 시작한 끌기 — 조각 대신 sidecar 가 쥔 그 끌기 데이터를 고른다(W6d②).
    if (payload.source != 0) {
        send(gpa, .{ .drag_target = .{ .browser = surface_id, .kind = .enter, .point = point, .modifiers = modifiers, .allowed = allowed & ws.message.drag_operation_mask, .source = payload.source } });
        s.drag_entered = true;
        s.drag_operation = 0;
        return true;
    }
    var sent_paths: usize = 0;
    for (payload.paths) |p| {
        if (sent_paths == max_drag_paths) break;
        ws.fields.checkPath(p) catch continue;
        send(gpa, .{ .drag_data = .{ .browser = surface_id, .kind = .path, .bytes = p } });
        sent_paths += 1;
    }
    sendDragText(gpa, surface_id, .text, payload.text);
    sendDragText(gpa, surface_id, .html, payload.html);
    if (payload.url.len != 0) if (ws.fields.checkUrl(payload.url)) |_| {
        send(gpa, .{ .drag_data = .{ .browser = surface_id, .kind = .url, .bytes = payload.url } });
        if (payload.url_title.len != 0) {
            var buf: [ws.wire.max_text_bytes]u8 = undefined;
            const title = cleanDragText(payload.url_title, &buf);
            if (title.len != 0) send(gpa, .{ .drag_data = .{ .browser = surface_id, .kind = .url_title, .bytes = title } });
        }
    } else |_| {};
    send(gpa, .{ .drag_target = .{ .browser = surface_id, .kind = .enter, .point = point, .modifiers = modifiers, .allowed = allowed & ws.message.drag_operation_mask } });
    s.drag_entered = true;
    s.drag_operation = 0;
    return true;
}

/// 글·HTML 을 글자 경계에서 `max_ime_text_bytes` 조각으로 나눠 보낸다 — 탭·줄바꿈 말고 제어 문자는 공백으로, 합계는
/// `max_drag_text` 에서 자른다. UTF-8 이 아니면 보내지 않는다.
fn sendDragText(gpa: std.mem.Allocator, surface_id: u64, kind: ws.message.DragDataKind, text: []const u8) void {
    if (text.len == 0 or !std.unicode.utf8ValidateSlice(text)) return;
    // 검증은 한 번 — 조각은 글자 경계(이어지는 바이트 앞)에서만 자른다. 조각마다 남은 글 전체를 다시 검증하면 1 MiB 글에서
    // enter 한 번에 수십 MB 를 읽었다(W6d① 적대 검증 1 차).
    var rest = text[0..utf8Boundary(text, max_drag_text)];
    var buf: [ws.wire.max_ime_text_bytes]u8 = undefined;
    while (rest.len != 0) {
        const len = utf8Boundary(rest, buf.len);
        if (len == 0) return;
        for (rest[0..len], 0..) |byte, i| buf[i] = cleanByte(byte);
        send(gpa, .{ .drag_data = .{ .browser = surface_id, .kind = kind, .bytes = buf[0..len] } });
        rest = rest[len..];
    }
}

/// 검증된 UTF-8 `text` 의 앞 `limit` 바이트 안에서 가장 긴 글자 경계.
fn utf8Boundary(text: []const u8, limit: usize) usize {
    if (text.len <= limit) return text.len;
    var end = limit;
    while (end > 0 and text[end] & 0xC0 == 0x80) end -= 1;
    return end;
}

fn cleanByte(byte: u8) u8 {
    return if ((byte < 0x20 and byte != '\t' and byte != '\n' and byte != '\r') or byte == 0x7f) ' ' else byte;
}

/// 탭·줄바꿈 말고 제어 문자를 공백으로 바꿔 `buf` 에 옮긴다(넘치면 글자 경계에서 자른다).
fn cleanDragText(text: []const u8, buf: []u8) []const u8 {
    const piece = ws.text.clampUtf8(text, buf.len);
    for (piece, 0..) |byte, i| buf[i] = cleanByte(byte);
    return buf[0..piece.len];
}

/// 끌기가 그 탭 본문 안에서 움직였다(enter 를 보낸 탭에만).
pub fn dragOver(gpa: std.mem.Allocator, surface_id: u64, point: ws.message.Point, modifiers: ws.message.Modifiers, allowed: u32) void {
    const s = surfaces.getPtr(surface_id) orelse return;
    if (!s.drag_entered) return;
    send(gpa, .{ .drag_target = .{ .browser = surface_id, .kind = .over, .point = point, .modifiers = modifiers, .allowed = allowed & ws.message.drag_operation_mask } });
}

/// 끌기가 그 탭을 떠났다.
pub fn dragLeave(gpa: std.mem.Allocator, surface_id: u64) void {
    const s = surfaces.getPtr(surface_id) orelse return;
    if (!s.drag_entered) return;
    forgetDrag(s);
    send(gpa, .{ .drag_target = .{ .browser = surface_id, .kind = .leave } });
}

/// 그 탭에 놓았다. enter 를 보낸 탭이면 drop 을 보내고 true. 받을지는 페이지가 정한다(마지막 동작이 0 이면 CEF 가 나가기로 바꾼다).
pub fn dragDrop(gpa: std.mem.Allocator, surface_id: u64, point: ws.message.Point, modifiers: ws.message.Modifiers) bool {
    const s = surfaces.getPtr(surface_id) orelse return false;
    if (!s.drag_entered) return false;
    forgetDrag(s);
    s.last_user_input_ms = monotonicNow(); // W6m②: 놓은 글의 `input` 에 따른 제안 목록도 받는다(적대 검증 5 차)
    send(gpa, .{ .drag_target = .{ .browser = surface_id, .kind = .drop, .point = point, .modifiers = modifiers } });
    return true;
}

// ── W6d②: 페이지에서 시작한 끌기 ──────────────────────────────────────────────────────────────────────
// sidecar 가 조각(`drag_out_data`)과 시작(`drag_out`)을 보내면 탭에 모은다. 그 탭이 보이는 창의 tick 이 가져가(`takeDragOut`) 아직
// 누르고 있으면 macOS 끌기 세션을 시작하고, 끝나면(`endDragOut`) sidecar 에 답한다. 아무 창도 가져가지 않으면(떼기를 이미 했거나
// 창이 없다) `drag_out_pickup_ms` 뒤 취소로 답한다 — CEF 는 답이 올 때까지 페이지의 끌기를 붙든다.

pub const drag_out_pickup_ms: i64 = 1_000;
/// 조각 상한 — sidecar(`drag.max_text_total`·`max_out_png`)와 같다.
pub const max_drag_out_text = 1024 * 1024;
pub const max_drag_out_png = 4 * 1024 * 1024;

pub const DragOut = struct {
    drag: u32,
    text: std.ArrayList(u8) = .empty,
    html: std.ArrayList(u8) = .empty,
    url: std.ArrayList(u8) = .empty,
    url_title: std.ArrayList(u8) = .empty,
    png: std.ArrayList(u8) = .empty,
    /// 이미지 끌기면 Chromium 이 정한 파일 이름과 sidecar 가 받아 둔 내용의 크기(W6d③ — 내용은 Finder 가 청할 때 `requestDragFile`).
    file_name: std.ArrayList(u8) = .empty,
    file_size: u32 = 0,
    allowed: u32 = 0,
    point: ws.message.Point = .{ .x = 0, .y = 0 },
    hotspot: ws.message.Point = .{ .x = 0, .y = 0 },
    image_width: u32 = 0,
    image_height: u32 = 0,
    /// `drag_out` 이 왔다(조각이 다 왔다).
    ready: bool = false,
    /// 창이 가져갔다(끌기 세션이 돈다) — 만료로 취소하지 않는다.
    taken: bool = false,
    arrived_ms: i64 = 0,

    fn add(self: *DragOut, gpa: std.mem.Allocator, kind: ws.message.DragOutDataKind, bytes: []const u8) void {
        const list, const cap: usize = switch (kind) {
            .text => .{ &self.text, max_drag_out_text },
            .html => .{ &self.html, max_drag_out_text },
            .url => .{ &self.url, ws.wire.max_url_bytes },
            .url_title => .{ &self.url_title, ws.wire.max_text_bytes },
            .image_png => .{ &self.png, max_drag_out_png },
            .file_name => .{ &self.file_name, ws.wire.max_text_bytes },
            .file_contents => return, // 끌기 조각이 아니다 — `drag_file_request` 의 답(`file_fetch`)
        };
        // 주소·제목·파일 이름은 한 조각이다(마지막 것).
        if (kind == .url or kind == .url_title or kind == .file_name) list.clearRetainingCapacity();
        if (list.items.len + bytes.len > cap) return; // 넘는 조각은 통째로 버린다(조각마다 글자 경계)
        list.appendSlice(gpa, bytes) catch {};
    }

    pub fn deinit(self: *DragOut, gpa: std.mem.Allocator) void {
        self.text.deinit(gpa);
        self.html.deinit(gpa);
        self.url.deinit(gpa);
        self.url_title.deinit(gpa);
        self.png.deinit(gpa);
        self.file_name.deinit(gpa);
    }
};

fn dragOutFor(gpa: std.mem.Allocator, s: *Surface, drag: u32) ?*DragOut {
    if (s.drag_out) |*d| {
        if (d.drag == drag) return d;
        dropDragOut(gpa, s);
    }
    s.drag_out = .{ .drag = drag };
    return &s.drag_out.?;
}

/// 답하지 않고 버린다(sidecar 가 끝냈거나 사라졌다).
fn dropDragOut(gpa: std.mem.Allocator, s: *Surface) void {
    if (s.drag_out) |*d| d.deinit(gpa);
    s.drag_out = null;
}

/// 그 탭에 아직 가져가지 않은 다 온 끌기가 있으면 가져간다(창 하나만).
pub fn takeDragOut(surface_id: u64) ?*const DragOut {
    const s = surfaces.getPtr(surface_id) orelse return null;
    const d = if (s.drag_out) |*d| d else return null;
    if (!d.ready or d.taken) return null;
    d.taken = true;
    return d;
}

// ── W6d③: 끌어낸 이미지의 파일 내용(Finder 가 청할 때만) ─────────────────────────────────────────────────────────────

/// 파일을 받아 둔 마지막 끌기(sidecar 도 그것 하나를 쥔다).
var file_source: ?struct { surface: u64, drag: u32, size: u32 } = null;

pub const FileFetchState = enum { pending, ready, failed };

/// 청한 파일 내용(하나 — Finder 는 놓은 하나를 청한다).
const FileFetch = struct {
    surface: u64,
    drag: u32,
    expected: u32,
    contents: std.ArrayList(u8) = .empty,
    state: FileFetchState = .pending,
};
var file_fetch: ?FileFetch = null;

fn fileFetchPending() bool {
    const f = file_fetch orelse return false;
    return f.state == .pending;
}

/// 그 번호의 파일 내용을 sidecar 에 청한다(이미 청했으면 그대로). 그 끌기가 파일을 받아 두지 않았거나 그 탭이 없으면 false.
/// (sidecar 가 다시 뜨면 `file_source` 를 비운다 — 새 sidecar 는 그 파일을 모른다.)
pub fn requestDragFile(gpa: std.mem.Allocator, drag: u32) bool {
    const src = file_source orelse return false;
    if (src.drag != drag or drag == 0) return false;
    if (file_fetch) |f| if (f.drag == drag and f.state != .failed) return true;
    dropFileFetch(gpa);
    const s = surfaces.getPtr(src.surface) orelse return false;
    if (!s.created or state == .off or state == .failed) return false;
    file_fetch = .{ .surface = src.surface, .drag = drag, .expected = src.size };
    file_fetch.?.contents.ensureTotalCapacityPrecise(gpa, src.size) catch {
        file_fetch = null;
        return false;
    };
    send(gpa, .{ .drag_file_request = .{ .browser = src.surface, .drag = drag } });
    return true;
}

fn fileFetchAdd(gpa: std.mem.Allocator, v: ws.message.DragOutData) void {
    const f = if (file_fetch) |*f| f else return;
    if (f.surface != v.browser or f.drag != v.drag or f.state != .pending) return;
    if (f.contents.items.len + v.bytes.len > f.expected) {
        f.state = .failed; // 알린 크기보다 많다
        return;
    }
    f.contents.appendSlice(gpa, v.bytes) catch {
        f.state = .failed;
    };
}

fn failFileFetch(surface: u64) void {
    if (file_fetch) |*f| if (f.surface == surface and f.state == .pending) {
        f.state = .failed;
    };
    if (file_source) |src| if (src.surface == surface) {
        file_source = null;
    };
}

fn dropFileFetch(gpa: std.mem.Allocator) void {
    if (file_fetch) |*f| f.contents.deinit(gpa);
    file_fetch = null;
}

/// 청한 그 번호의 파일 내용 상태. 다 왔으면 `ready` 와 내용(`releaseDragFile` 이 놓을 때까지 유효).
pub fn dragFile(drag: u32) struct { state: FileFetchState, bytes: []const u8 = "" } {
    const f = file_fetch orelse return .{ .state = .failed };
    if (f.drag != drag) return .{ .state = .failed };
    return .{ .state = f.state, .bytes = if (f.state == .ready) f.contents.items else "" };
}

/// 다 읽었다·실패했다·기다리다 그만뒀다 — 놓는다.
pub fn releaseDragFile(gpa: std.mem.Allocator, drag: u32) void {
    if (file_fetch) |f| if (f.drag == drag) dropFileFetch(gpa);
}

/// 그 번호의 페이지 끌기가 아직 살아 있는가(어느 탭이든 창이 가져간 채) — 원래 탭이 닫혔거나 sidecar 가 다시 떴거나 창이 닫혀
/// 끝났으면 false 다. 그러면 sidecar 도 데이터를 놓았으니 maru 안 놓기는 pasteboard 로 간다(W6d② 적대 검증 2 차).
pub fn dragOutAlive(drag: u32) bool {
    if (drag == 0) return false;
    for (surfaces.values()) |*s| if (s.drag_out) |d| if (d.drag == drag and d.taken) return true;
    return false;
}

/// 가져간 그 끌기(창이 조각을 읽는다). 번호가 다르면 null.
pub fn dragOut(surface_id: u64, drag: u32) ?*const DragOut {
    const s = surfaces.getPtr(surface_id) orelse return null;
    const d = if (s.drag_out) |*d| d else return null;
    return if (d.drag == drag) d else null;
}

/// 그 끌기가 끝났다 — sidecar 에 놓인 자리(view DIP)와 받은 동작을 답하고 버린다. 그 끌기가 아니면(이미 끝났다) false.
pub fn endDragOut(gpa: std.mem.Allocator, surface_id: u64, drag: u32, point: ws.message.Point, operation: u32) bool {
    const s = surfaces.getPtr(surface_id) orelse return false;
    const d = s.drag_out orelse return false;
    if (d.drag != drag or !d.ready) return false;
    const masked = operation & d.allowed & ws.message.drag_operation_mask;
    const one: u32 = if (masked == 0) 0 else masked & (~masked +% 1);
    dropDragOut(gpa, s);
    send(gpa, .{ .drag_source_end = .{ .browser = surface_id, .drag = drag, .point = point, .operation = one } });
    return true;
}

/// 아무 창도 가져가지 않은 끌기를 취소로 끝낸다.
fn expireDragOuts(gpa: std.mem.Allocator, now_ms: i64) void {
    for (surfaces.values()) |*s| {
        const d = s.drag_out orelse continue;
        if (d.ready and !d.taken and now_ms - d.arrived_ms > drag_out_pickup_ms) _ = endDragOut(gpa, s.record.surface_id, d.drag, d.point, 0);
    }
}

/// 그 탭에 보낸 enter 가 살아 있는가 — 창이 enter 한 탭이라도 sidecar 가 다시 떴거나 렌더러가 죽었으면(브라우저를 다시
/// 만들었으면) false 다. 창은 그때 다시 enter 한다(W6d① 적대 검증 1 차 — 안 하면 본문을 나갔다 들어올 때까지 끌기가 멈췄다).
pub fn dragEntered(surface_id: u64) bool {
    const s = surfaces.getPtr(surface_id) orelse return false;
    return s.drag_entered;
}

/// 이 끌기에서 페이지가 받아들이는 동작(enter 를 보내지 않은 탭이면 0).
pub fn dragOperation(surface_id: u64) u32 {
    const s = surfaces.getPtr(surface_id) orelse return 0;
    return if (s.drag_entered) s.drag_operation else 0;
}

/// 그 메뉴의 선택한 글(없으면 빈 글).
pub fn contextMenuSelection(surface_id: u64, menu: u32) []const u8 {
    const s = surfaces.getPtr(surface_id) orelse return "";
    const m = s.context_menu orelse return "";
    return if (m.menu == menu) m.selection else "";
}

/// 띄운 메뉴의 답(고른 명령, 고르지 않았으면 취소). sidecar 가 이미 닫았으면 보내지 않는다. 그 메뉴가 아니면 무동작.
pub fn answerContextMenu(gpa: std.mem.Allocator, surface_id: u64, menu: u32, command: ws.message.ContextMenuCommandKind) void {
    const s = surfaces.getPtr(surface_id) orelse return;
    const m = s.context_menu orelse return;
    // 띄운 그 메뉴에만 답한다 — sidecar 를 다시 띄운 뒤 같은 번호의 새(아직 안 띄운) 메뉴에 옛 창의 늦은 답이 가지 않게(W6c② 적대 검증).
    if (m.menu != menu or !m.shown) return;
    if (!m.closed) {
        s.last_user_input_ms = monotonicNow(); // W6m②: 메뉴의 붙여넣기·맞춤법 교정이 낸 `input` 의 제안 목록도 받는다(적대 검증 5 차)
        send(gpa, .{ .context_menu_command = .{ .browser = surface_id, .menu = menu, .command = command } });
    }
    // 사용자가 메뉴에서 골랐다(W6e·W6h①) — 그 답이 부를 `open_tab` 하나를 받는다.
    // 그 메뉴가 보인 대로 할 수 있는 명령에만(심층 방어 — 꺼진 항목은 Swift 에서 고를 수 없다, W6h② 적대 검증 3 회차).
    if (!m.closed and ws.message.contextMenuAllows(m.flags, command)) switch (command) {
        .open_link_new_tab, .open_image_new_tab, .open_media_new_tab => s.new_tab_credits.grant(monotonicNow()),
        .open_link_new_window => s.new_window_credit_ms = monotonicNow(),
        else => {},
    };
    dropContextMenu(gpa, s);
}

// ── W6e: 페이지가 연 새 탭 ─────────────────────────────────────────────────────────────────────────────

fn queueNewTab(gpa: std.mem.Allocator, s: *Surface, v: ws.message.OpenTab, now_ms: i64) void {
    if (!ws.new_tab.urlAllowed(v.url) or s.new_tabs.items.len >= max_new_tabs) return;
    if (v.placement == .new_window) {
        // 새 창은 메뉴 「새 창에서 링크 열기」를 고른 직후에만(W6h①) — 한 번 쓴다.
        if (!ws.new_tab.creditLive(s.new_window_credit_ms, now_ms)) return;
        s.new_window_credit_ms = 0;
    } else if (!s.new_tab_credits.take(now_ms)) return; // 이 탭에 보낸 사용자 입력이 없다(5 초 안) — sidecar 가 보냈어도 받지 않는다.
    const url = gpa.dupe(u8, v.url) catch return;
    s.new_tabs.append(gpa, .{ .url = url, .placement = v.placement, .arrived_ms = now_ms }) catch gpa.free(url);
}

/// 우클릭 메뉴 「…에서 '…' 검색」(W6h①) — maru 가 만든 검색 주소를 그 탭의 새 탭 줄에 앞 탭으로 넣는다(사용자가 maru 의 메뉴에서
/// 골랐다 — 장을 쓰지 않는다). 그 탭이 없거나 주소가 새 탭 규칙에 맞지 않거나 줄이 차면 false.
pub fn queueSearchTab(gpa: std.mem.Allocator, surface_id: u64, url: []const u8) bool {
    const s = surfaces.getPtr(surface_id) orelse return false;
    if (!ws.new_tab.urlAllowed(url) or s.new_tabs.items.len >= max_new_tabs) return false;
    const owned = gpa.dupe(u8, url) catch return false;
    s.new_tabs.append(gpa, .{ .url = owned, .placement = .foreground, .arrived_ms = monotonicNow() }) catch {
        gpa.free(owned);
        return false;
    };
    return true;
}

fn dropNewTabs(gpa: std.mem.Allocator, s: *Surface) void {
    for (s.new_tabs.items) |t| {
        if (t.adopt != 0) abandonPopup(gpa, t.adopt);
        gpa.free(t.url);
    }
    s.new_tabs.clearRetainingCapacity();
}

/// 붙이지 못한 팝업 — pump 가 닫는다(지금 표를 돌고 있을 수 있다).
pub fn abandonPopup(gpa: std.mem.Allocator, id: u64) void {
    orphan_popups.append(gpa, id) catch {
        // 쥘 곳이 없다(메모리 부족) — 브라우저만이라도 닫는다. 기록은 남는다: sidecar 가 다시 뜨면 Term 없는 브라우저로 되살아나고
        // sidecar 를 내리지 못한다 — 메모리 부족일 때만이다.
        send(gpa, .{ .destroy_browser = id });
    };
}

fn closeOrphanPopups(gpa: std.mem.Allocator) void {
    while (orphan_popups.pop()) |id| {
        if (surfaces.contains(id)) destroy(gpa, id) else if (state == .running or state == .starting) send(gpa, .{ .destroy_browser = id });
    }
}

/// 맡겨 둘 번호가 몇 개 더 필요한가(sidecar 가 돌 때만).
pub fn popupIdsWanted() usize {
    if (state != .running) return 0;
    return popup_reserve_target -| popup_reserved_len;
}

/// 번호 하나를 맡긴다(창 tick 이 앱 전역 발급기에서 떼어 준다 — 쓰이지 않으면 버려진다. 번호는 다시 쓰이지 않는다).
pub fn reservePopupId(gpa: std.mem.Allocator, id: u64) void {
    if (popup_reserved_len == popup_reserved.len or (state != .running and state != .starting)) return;
    popup_reserved[popup_reserved_len] = .{ .id = id };
    popup_reserved_len += 1;
    send(gpa, .{ .popup_reserve = .{ .browser = id } });
}

fn reservedIndex(id: u64) ?usize {
    for (popup_reserved[0..popup_reserved_len], 0..) |r, i| if (r.id == id) return i;
    return null;
}

fn takeReserved(id: u64) ?ReservedPopup {
    const i = reservedIndex(id) orelse return null;
    const r = popup_reserved[i];
    var j = i + 1;
    while (j < popup_reserved_len) : (j += 1) popup_reserved[j - 1] = popup_reserved[j];
    popup_reserved_len -= 1;
    return r;
}

/// sidecar 가 사라졌다 — 맡긴 번호도 사라졌다(새 sidecar 에 다시 맡긴다).
fn forgetReserved() void {
    for (popup_reserved[0..popup_reserved_len]) |r| if (r.ring) |ring| ring.release();
    popup_reserved_len = 0;
}

/// sidecar 가 팝업을 맡긴 번호로 만들었다. 연 탭이 알고 그 탭에 사용자 입력을 보냈으면(장) 그 번호의 기록을 「만들어짐」으로 두고
/// 연 탭의 새 탭 줄에 넣는다 — 아니면 닫는다(페이지에는 팝업이 닫힌 것으로 보인다).
fn adoptPopup(gpa: std.mem.Allocator, v: ws.message.PopupCreated, now_ms: i64) void {
    const reserved = takeReserved(v.browser) orelse {
        // 맡기지 않은 번호 — 이미 있는 탭이면 건드리지 않는다(고장 난 sidecar), 아니면 닫는다.
        if (!surfaces.contains(v.browser)) send(gpa, .{ .destroy_browser = v.browser });
        return;
    };
    const accepted = blk: {
        const opener = surfaces.getPtr(v.opener) orelse break :blk false;
        if (opener.new_tabs.items.len >= max_new_tabs or !ws.new_tab.popupUrlAllowed(v.url)) break :blk false;
        if (!opener.new_tab_credits.take(now_ms)) break :blk false;
        break :blk true;
    };
    if (!accepted) {
        if (reserved.ring) |ring| ring.release();
        send(gpa, .{ .destroy_browser = v.browser });
        return;
    }
    const size = surfaces.getPtr(v.opener).?.record.size;
    // 누른 `target=_blank` 링크가 첨부를 돌려주면 다운로드는 이 팝업 브라우저의 것이다 — 연 탭에서 누른 것을 물려받는다(W10a 적대
    // 리뷰 3 회차: 사용자가 누른 실행 파일이 보류됐다). 팝업이 문서를 열면 `page_started` 가 지운다.
    // 연 탭이 그 뒤 다른 문서로 갔다면 그 누름은 이미 무효다 — 무효가 아닌 것만 물려준다(4 회차). 제안 목록 막음은 물려받지 않는다.
    const opener_gesture_ms = downloadGestureMs(surfaces.getPtr(v.opener).?);
    const queued_url = gpa.dupe(u8, v.url) catch null;
    const last_url = gpa.dupe(u8, v.url) catch null;
    if (queued_url == null or last_url == null) {
        if (queued_url) |u| gpa.free(u);
        if (last_url) |u| gpa.free(u);
        if (reserved.ring) |ring| ring.release();
        send(gpa, .{ .destroy_browser = v.browser });
        return;
    }
    // 그 번호의 기록 — sidecar 는 이미 만들었다(`browser_created` 는 오지 않는다). 다시 띄우면 처음 주소로 보통 탭처럼 되살린다.
    // 주소창은 처음 주소를 미리 보이지 않는다 — 커밋되기 전 빈 문서에 연 페이지가 쓸 수 있다(`w.stop(); w.document.write(…)`):
    // 남의 주소 아래 공격자 글이 보였다(W6f② 적대 검증 4 차 — Chrome 도 그때 대기 주소를 숨긴다). 첫 `url_changed` 가 채운다.
    surfaces.put(gpa, v.browser, .{
        .record = .{ .surface_id = v.browser, .size = size, .hidden = false },
        .created = true,
        .last_url = last_url,
        .popup_opener = v.opener,
        .download_gesture_ms = opener_gesture_ms,
        .page_opened = true,
    }) catch {
        gpa.free(queued_url.?);
        gpa.free(last_url.?);
        if (reserved.ring) |ring| ring.release();
        send(gpa, .{ .destroy_browser = v.browser });
        return;
    };
    // 크기를 맞춘다 — sidecar 는 연 탭의 그때 크기로 만들었고, 그사이 연 탭이 바뀌었으면 배치가 같아 다시 보내지 않았다(W6f② 적대
    // 검증 5 차). 기대 크기도 함께 건다.
    const adopted = surfaces.getPtr(v.browser).?;
    adopted.view.expect(pixels(size.width, size.scale), pixels(size.height, size.scale));
    send(gpa, .{ .resize = .{ .browser = v.browser, .size = size } });
    if (reserved.ring) |ring| if (adopted.view.adopt(ring)) |never_drawn| never_drawn.release();
    // `put` 이 표를 옮겼을 수 있다 — 연 탭을 다시 찾는다.
    const opener = surfaces.getPtr(v.opener).?;
    opener.new_tabs.append(gpa, .{ .url = queued_url.?, .placement = v.placement, .arrived_ms = now_ms, .adopt = v.browser }) catch {
        gpa.free(queued_url.?);
        abandonPopup(gpa, v.browser);
    };
}

/// 그 팝업이 아직 탭으로 붙기 전이면 줄에서 뺀다(페이지가 곧바로 닫았다). 뺐으면 true.
fn dropPendingAdopt(gpa: std.mem.Allocator, id: u64) bool {
    for (surfaces.values()) |*s| for (s.new_tabs.items, 0..) |t, i| if (t.adopt == id) {
        gpa.free(s.new_tabs.orderedRemove(i).url);
        return true;
    };
    return false;
}

/// 페이지가 닫은 팝업인데 그 탭을 닫지 않는다(그 pane 의 유일한 탭 — W6f②). 브라우저는 이미 없다 — 그 번호로 빈 보통 탭을 새로
/// 만든다(`about:blank`). 그대로 두면 입력·크기·이동이 죽은 번호로 가고, sidecar 를 내리지 못하고, sidecar 가 다시 뜨면 닫힌 팝업이 처음
/// 주소로 되살아났다(로그인 흐름의 첫 주소 — W6f② 적대 검증 2 차).
pub fn revivePageClosed(gpa: std.mem.Allocator, surface_id: u64) void {
    const s = surfaces.getPtr(surface_id) orelse return;
    s.page_closed = false;
    s.popup_opener = 0; // 이제 보통 탭이다 — 나중에 닫혀도 옛 연 탭으로 가지 않는다
    s.page_opened = false; // W10c: 빈 다운로드 탭으로 닫지 않는다(사용자가 쓰는 보통 탭이다 — 적대 리뷰 2 회차)
    s.composing = false; // 닫힌 페이지의 조합은 끝났다(창이 입력기 쪽을 버린다 — `osr_discard_marked`)
    dropDialogs(gpa, s);
    dropNotes(gpa, s);
    for (s.view.clear()) |ring| if (ring) |r| r.release();
    const blank = gpa.dupe(u8, "about:blank") catch null;
    if (s.last_url) |u| gpa.free(u);
    s.last_url = blank;
    s.created = false;
    if (state == .running or state == .starting) sendCommand(gpa, .{ .create = .{ .browser = surface_id, .size = s.record.size, .hidden = s.record.hidden } });
}

/// 그 팝업을 연 탭(없으면 0).
pub fn popupOpener(surface_id: u64) u64 {
    const s = surfaces.getPtr(surface_id) orelse return 0;
    return s.popup_opener;
}

/// 꺼내 간 창이 지금 닫지 못했다(탭을 끄는 중·닫기 확인) — 다음 tick 에 다시.
pub fn markPageClosed(surface_id: u64) void {
    if (surfaces.getPtr(surface_id)) |s| s.page_closed = true;
}

/// 페이지가 이 탭의 팝업을 닫았는가 — 그 탭이 있는 창이 꺼내 가 탭을 닫는다(한 번).
pub fn takePageClosed(surface_id: u64) bool {
    const s = surfaces.getPtr(surface_id) orelse return false;
    if (!s.page_closed) return false;
    s.page_closed = false;
    return true;
}

fn expireNewTabs(gpa: std.mem.Allocator, now_ms: i64) void {
    for (surfaces.values()) |*s| {
        var i: usize = 0;
        while (i < s.new_tabs.items.len) {
            if (now_ms - s.new_tabs.items[i].arrived_ms > new_tab_pickup_ms) {
                const t = s.new_tabs.orderedRemove(i);
                if (t.adopt != 0) abandonPopup(gpa, t.adopt);
                gpa.free(t.url);
            } else i += 1;
        }
    }
}

/// 그 탭이 연 새 탭이 기다리는가.
pub fn newTabPending(surface_id: u64) bool {
    const s = surfaces.getPtr(surface_id) orelse return false;
    return s.new_tabs.items.len != 0;
}

/// 그 탭이 연 새 탭 하나를 꺼낸다(온 차례대로). 주소는 꺼낸 쪽이 같은 할당기로 놓는다.
pub fn takeNewTab(surface_id: u64) ?NewTab {
    const s = surfaces.getPtr(surface_id) orelse return null;
    if (s.new_tabs.items.len == 0) return null;
    return s.new_tabs.orderedRemove(0);
}

/// 툴팁 글을 바꾼다(W6b). 빈 글이면 없앤다. 세대는 늘 오른다.
fn setTooltip(gpa: std.mem.Allocator, s: *Surface, text: []const u8) void {
    if (s.tooltip_text) |old| gpa.free(old);
    s.tooltip_text = if (text.len == 0) null else gpa.dupe(u8, text) catch null;
    s.tooltip_generation +%= 1;
}

/// 이 surface 의 지금 툴팁 글과 세대(W6b).
pub fn tooltip(surface_id: u64) ?struct { text: []const u8, generation: u32 } {
    const s = surfaces.getPtr(surface_id) orelse return null;
    return .{ .text = s.tooltip_text orelse "", .generation = s.tooltip_generation };
}

/// 제안 목록 하나(W6m②) — 항목 덩어리는 복사해 쥔다(sidecar 가 보낸 모양은 decode 가 검증했다 — `ws.fields.DatalistItems` 로 읽는다).
pub const Datalist = struct {
    list: u32,
    /// 칸 사각형(그 탭 view DIP).
    field: ws.message.Rect,
    count: u16,
    items: []u8,
};

const datalist_user_window_ms = 1000;

fn pointInRect(p: ws.message.Point, r: ws.message.Rect) bool {
    const px: i64 = p.x;
    const py: i64 = p.y;
    return px >= r.x and py >= r.y and px < @as(i64, r.x) + r.width and py < @as(i64, r.y) + r.height;
}

fn setDatalist(gpa: std.mem.Allocator, s: *Surface, v: ws.message.DatalistShow) void {
    dropDatalist(gpa, s);
    // 사용자가 이 탭에 손댄 직후가 아니면 받지 않는다(옛 목록도 닫힌 채로) — `last_user_input_ms` 참고.
    if (monotonicNow() - s.last_user_input_ms > datalist_user_window_ms) return;
    const items = gpa.dupe(u8, v.items) catch return;
    s.datalist = .{ .list = v.list, .field = v.field, .count = v.count, .items = items };
    s.datalist_generation = nextDatalistGeneration();
}

fn dropDatalist(gpa: std.mem.Allocator, s: *Surface) void {
    const d = s.datalist orelse return;
    gpa.free(d.items);
    s.datalist = null;
    s.datalist_generation = nextDatalistGeneration();
}

/// 목록 세대는 탭마다가 아니라 앱 전체에서 센다 — 키 대상이 한 tick 사이에 다른 탭의 같은 세대 목록으로 바뀌면 Swift 가 띄운 옛
/// 탭의 항목을 새 탭의 목록으로 알고 그 번호를 고를 수 있다(네이티브 창은 세대로만 같은 목록인지 본다). 0 은 쓰지 않는다
/// (「띄우지 않음」).
var datalist_generation_seq: u32 = 0;

fn nextDatalistGeneration() u32 {
    datalist_generation_seq +%= 1;
    if (datalist_generation_seq == 0) datalist_generation_seq = 1;
    return datalist_generation_seq;
}

/// 이 탭의 지금 제안 목록과 세대(W6m②).
pub fn datalist(surface_id: u64) ?struct { d: *const Datalist, generation: u32 } {
    const s = surfaces.getPtr(surface_id) orelse return null;
    if (s.datalist == null) return null;
    return .{ .d = &s.datalist.?, .generation = s.datalist_generation };
}

/// 사용자가 골랐다(W6m②) — 지금 목록이고 번호가 안이면 sidecar 에 보내고 목록을 닫는다(대리 스크립트도 넣은 뒤 닫기를 보낸다 —
/// 먼저 닫아 같은 목록을 두 번 고르지 않게). 보냈으면 true.
pub fn datalistPick(gpa: std.mem.Allocator, surface_id: u64, list: u32, index: usize) bool {
    const s = surfaces.getPtr(surface_id) orelse return false;
    const d = s.datalist orelse return false;
    if (d.list != list or index >= d.count or !s.created) return false;
    send(gpa, .{ .datalist_pick = .{ .browser = surface_id, .list = list, .index = @intCast(index) } });
    dropDatalist(gpa, s);
    return true;
}

/// maru 쪽에서 닫는다(W6m② — Esc). 페이지에는 알리지 않는다 — Chrome 도 Esc 는 목록만 닫고 페이지에 키를 보내지 않는다(§7 실측).
/// 대리 스크립트는 그 칸을 쥔 채라 다음 ↓·글자에 다시 보낸다(Chrome 과 같다).
pub fn datalistDismiss(gpa: std.mem.Allocator, surface_id: u64) void {
    const s = surfaces.getPtr(surface_id) orelse return;
    dropDatalist(gpa, s);
}

fn freeSurface(gpa: std.mem.Allocator, s: *Surface) void {
    forgetLocationSurface(gpa, s.record.surface_id);
    dropNewTabs(gpa, s);
    s.new_tabs.deinit(gpa);
    if (s.tooltip_text) |t| gpa.free(t);
    s.tooltip_text = null;
    dropDatalist(gpa, s);
    dropContextMenu(gpa, s);
    dropDragOut(gpa, s);
    if (s.last_url) |u| gpa.free(u);
    if (s.url) |u| gpa.free(u);
    s.last_url = null;
    s.url = null;
    dropDialogs(gpa, s);
    s.dialogs.deinit(gpa);
    dropNotes(gpa, s);
    s.notes.deinit(gpa);
}

/// 답을 기다리던 요청을 모두 버린다 — 답을 보내지 않는다(sidecar 가 죽었거나 브라우저가 사라져 콜백이 없다). 떠 있던
/// 창은 그 창의 tick 이 요청이 사라진 것을 보고 닫는다.
fn dropDialogs(gpa: std.mem.Allocator, s: *Surface) void {
    for (s.dialogs.items) |d| d.free(gpa);
    s.dialogs.clearRetainingCapacity();
}

fn installDir() ?[]const u8 {
    if (install_len > 0) return install_buf[0..install_len];
    return envDir();
}

/// `~/Library/Application Support/maru/web/<번들 ID>/profile` — 개발 빌드와 설치본이 갈리게(C7).
fn profileDir(buf: []u8) ?[]const u8 {
    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = install.homeDir(&home_buf, install.hardenedRuntime()) orelse return null; // 실행 사본과 같은 홈(W7a2)
    var id_buf: [256]u8 = undefined;
    const bundle = bundleIdentifier(&id_buf) orelse "dev.maru.unbundled";
    return std.fmt.bufPrint(buf, "{s}/Library/Application Support/maru/web/{s}/profile", .{ home, bundle }) catch null;
}

extern "c" fn CFBundleGetMainBundle() ?*anyopaque;
extern "c" fn CFBundleGetIdentifier(bundle: *anyopaque) ?*anyopaque;
extern "c" fn CFStringGetCString(string: *anyopaque, buffer: [*]u8, size: isize, encoding: u32) u8;

fn bundleIdentifier(buf: []u8) ?[]const u8 {
    const bundle = CFBundleGetMainBundle() orelse return null;
    const id = CFBundleGetIdentifier(bundle) orelse return null;
    if (CFStringGetCString(id, buf.ptr, @intCast(buf.len), 0x0800_0100) == 0) return null; // kCFStringEncodingUTF8
    const s = std.mem.sliceTo(buf, 0);
    // 경로 조각으로 쓰므로 번들 ID 문자(영숫자·점·하이픈)만 받는다.
    for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '-')) return null;
    return if (s.len == 0) null else s;
}

fn mkdirs(path: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= buf.len) return false;
    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i != path.len and path[i] != '/') continue;
        @memcpy(buf[0..i], path[0..i]);
        buf[i] = 0;
        const z: [*:0]const u8 = @ptrCast(&buf);
        // 프로필과 그 위(maru/web/<번들 ID>)는 소유자 전용 — sidecar 가 프로필 권한을 검사한다(0700).
        if (std.c.mkdir(z, 0o700) != 0 and std.c._errno().* != @intFromEnum(std.c.E.EXIST)) return false;
    }
    return true;
}

fn start(gpa: std.mem.Allocator, now_ms: i64) void {
    const log = std.log.scoped(.web_osr);
    profile_held = false; // 새 sidecar — 첫 browser_created 가 세운다(W10b)
    const source = installDir() orelse return fail(.start_failed);
    // W7a2: brew 설치는 그 prefix 의 keg 이고 믿을 만할 때만 — 검사한 keg 를 fd 로 쥐고 그 fd 에서 복제한다. 개발용
    // `MARU_WEB_OSR_DIR` 은 빌드 디렉터리라 이 검사를 건너뛴다(릴리스 판에서는 그 환경변수 자체를 안 본다).
    const dev = install_len == 0;
    const hardened = install.hardenedRuntime();
    const source_fd: c_int = if (dev) install.openDevSource(source) orelse return fail(.start_failed) else switch (install.openBrewSource(source, install_prefix_buf[0..install_prefix_len])) {
        .ok => |fd| fd,
        .bad => |problem| {
            log.warn("maru-chromium install rejected before start: {s}", .{@tagName(problem)});
            return fail(rejectedNotice(problem));
        },
    };
    defer _ = std.c.close(source_fd);
    // 실행 사본 — 도는 동안 `brew upgrade` 가 설치를 지워도 새 렌더러가 뜨게. brew 설치는 복제가 안 되면 띄우지 않는다(설치에서
    // 바로 띄우면 CEF 가 helper 를 경로로 다시 띄워 검사가 무력해진다). 개발 디렉터리는 그 자리에서.
    std.debug.assert(run_copy == null);
    var cache_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (install.runCacheRoot(&cache_buf, hardened)) |root| switch (install.cloneForRun(source_fd, root)) {
        .ok => |copy| run_copy = copy,
        .bad => |problem| {
            log.warn("could not make the maru-chromium run copy: {s}", .{@tagName(problem)});
            if (!dev) return fail(.start_failed);
        },
    } else if (!dev) return fail(.start_failed);
    const dir = if (run_copy) |*copy| copy.dir() else source;
    if (install.verifyRunDir(dir, !dev)) |problem| {
        log.warn("maru-chromium install rejected before start: {s}", .{@tagName(problem)});
        releaseRunCopy(&run_copy);
        return fail(rejectedNotice(problem));
    }
    var host_buf: [std.fs.max_path_bytes]u8 = undefined;
    // 여기부터 실패하면 만든 사본도 놓는다(W7a2 적대 검증 2 차 — 그 세션 내내 사본과 잠금이 남았다).
    const host_path = std.fmt.bufPrint(&host_buf, "{s}/maru-web-host", .{dir}) catch return startFailedAfterCopy();
    var profile_buf: [std.fs.max_path_bytes]u8 = undefined;
    const profile = profileDir(&profile_buf) orelse return startFailedAfterCopy();
    if (!mkdirs(profile)) return startFailedAfterCopy();
    var arg_buf: [std.fs.max_path_bytes + 32]u8 = undefined;
    const arg = std.fmt.bufPrint(&arg_buf, "--profile-dir={s}", .{profile}) catch return startFailedAfterCopy();
    if (receiver == null) receiver = ring_receiver.Receiver.open() catch return startFailedAfterCopy();
    const spawned = lsp_process.spawn(gpa, host_path, &.{arg}, dir) catch return startFailedAfterCopy();
    process = spawned;
    // 새 sidecar 의 pid 만 받는다. pid 버전은 그 첫 알림에서 다시 고정한다(옛 sidecar 의 고정값은 버린다).
    receiver.?.expected_pid = spawned.pid;
    receiver.?.pinned_pid_version = null;
    decoder = .init(.to_maru);
    inbox.clearRetainingCapacity();
    state = .starting;
    started_ms = now_ms;
    process_generation += 1;
    arc4random_buf(@ptrCast(&hello_nonce), @sizeOf(u64));
    var frame: [ws.wire.max_frame_bytes]u8 = undefined;
    const len = ws.codec.encode(.{ .hello = .{ .instance = @intCast(std.c.getpid()), .nonce = hello_nonce } }, &frame) catch return fail(.start_failed);
    if (!(lsp_process.write(&process.?, gpa, frame[0..len]) catch false)) return crashed(gpa, now_ms);
}

/// 띄우기 전 검사가 거절한 이유를 안내로 — 제어 채널 버전이 다르면 버전 불일치, 그 밖은 시작 실패.
fn rejectedNotice(problem: install.Problem) Notice {
    return if (problem == .version_mismatch) .version_mismatch else .start_failed;
}

fn startFailedAfterCopy() void {
    releaseRunCopy(&run_copy);
    fail(.start_failed);
}

fn releaseRunCopy(copy: *?install.RunCopy) void {
    if (copy.*) |*c| c.release();
    copy.* = null;
}

fn monotonicNow() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}

/// 마지막 브라우저가 사라졌다 — shutdown 을 보내고 기다리지 않는다(`reapRetiring` 이 거둔다). 이미 물러나는 옛
/// sidecar 가 있으면 그것은 바로 죽인다(둘을 쌓지 않는다).
fn retire(gpa: std.mem.Allocator, now_ms: i64) void {
    parked.clearRetainingCapacity(); // W10c: 주차한 것이 남았으면(부른 쪽은 남지 않았을 때만 부른다 — 방어) sidecar 와 함께 끝난다
    web_downloads.sidecarRetired(); // 받던 다운로드는 멈춘다 — 내리는 sidecar 의 알림은 읽지 않는다(W10a 적대 리뷰 1 회차)
    // 내리는 sidecar 에 맡긴 번호(W6f②) — 다음 sidecar 에 다시 맡긴다(안 잊으면 남은 칸 때문에 다시 맡기지 않아, 첫 내림 뒤로 팝업
    // 이어 받기가 앱이 끝날 때까지 꺼졌다 — W6f② 적대 검증).
    forgetReserved();
    var p = process orelse {
        state = .off;
        return;
    };
    if (retiring) |*old| {
        lsp_process.kill(old, .KILL);
        lsp_process.reapBlocking(old);
        old.deinit(gpa);
    }
    releaseRunCopy(&retiring_copy);
    var frame: [64]u8 = undefined;
    if (ws.codec.encode(.shutdown, &frame)) |len| {
        _ = lsp_process.write(&p, gpa, frame[0..len]) catch false;
    } else |_| {}
    retiring = p;
    retiring_profile_held = profile_held;
    profile_held = false;
    retiring_since_ms = now_ms;
    retiring_copy = run_copy;
    run_copy = null;
    process = null;
    state = .off;
    outbox_pending.clearRetainingCapacity();
}

fn reapRetiring(gpa: std.mem.Allocator, now_ms: i64) void {
    const p = if (retiring) |*p| p else return;
    _ = lsp_process.flush(p, gpa) catch {};
    if (!lsp_process.reapIfExited(p)) {
        if (now_ms - retiring_since_ms < shutdown_wait_ms) return;
        lsp_process.kill(p, .KILL);
        lsp_process.reapBlocking(p);
    }
    p.deinit(gpa);
    retiring = null;
    // 거뒀다 — 지금 sidecar 가 없으면 그 sidecar 가 받아 둔 것을 비운다(8 회차: 마지막 탭을 닫아 내린 뒤 엔진을 WebKit 으로 돌리면 계속
    // 남았다). 지금 sidecar 가 있으면 그것이 시작하며 이미 비웠다. 플래그는 내린다(다음 sidecar 가 막혀 끝날 때 남의 것을 비우지 않게 — 7 회차).
    if (retiring_profile_held and process == null) clearDownloadStaging(true);
    retiring_profile_held = false;
    releaseRunCopy(&retiring_copy);
}

fn stop(gpa: std.mem.Allocator) void {
    parked.clearRetainingCapacity(); // W10c: 주차한 브라우저도 함께 끝난다(종료 확인이 받는 중인 다운로드 수를 알렸다)
    var p = process orelse {
        releaseRunCopy(&run_copy); // 띄우지 못한 사본이 남았더라도
        state = .off;
        return;
    };
    var frame: [64]u8 = undefined;
    if (ws.codec.encode(.shutdown, &frame)) |len| {
        _ = lsp_process.write(&p, gpa, frame[0..len]) catch false;
        _ = lsp_process.flush(&p, gpa) catch false;
    } else |_| {}
    // sidecar 는 열린 브라우저를 닫고 끝난다(감시견 10 초). 앱이 그만큼 멈추지 않게 짧게만 기다린 뒤 죽인다.
    var waited: i64 = 0;
    while (waited < shutdown_wait_ms and !lsp_process.reapIfExited(&p)) : (waited += 20) sleepMs(20);
    if (waited >= shutdown_wait_ms) {
        lsp_process.kill(&p, .KILL);
        lsp_process.reapBlocking(&p);
    }
    p.deinit(gpa);
    process = null;
    releaseRunCopy(&run_copy);
    state = .off;
    outbox_pending.clearRetainingCapacity();
    forgetReserved(); // 내린 sidecar 에 맡긴 번호(W6f②)
    var it = surfaces.iterator();
    while (it.next()) |entry| entry.value_ptr.created = false;
}

extern "c" fn arc4random_buf(buf: [*]u8, len: usize) void;
extern "c" fn nanosleep(rqtp: *const std.c.timespec, rmtp: ?*std.c.timespec) c_int;

fn sleepMs(ms: i64) void {
    const ts: std.c.timespec = .{ .sec = 0, .nsec = @intCast(ms * std.time.ns_per_ms) };
    _ = nanosleep(&ts, null);
}

fn fail(notice: Notice) void {
    state = .failed;
    latched = notice;
    for (surfaces.values()) |*s| s.stopped_notice_pending = true;
}

/// W10b: 지금 sidecar 가 프로필을 잡았다(첫 `browser_created` — 초기화·잠금 뒤에만 온다). sidecar 마다 — 한 번 잡았다고
/// 다음 sidecar(같은 프로필의 다른 maru 에 막힌)가 죽을 때 남의 받아 둔 것을 비우지 않게(6 회차). 물러나는 sidecar 는 따로.
var profile_held = false;
var retiring_profile_held = false;

/// W10b: 프로필의 `download-staging`(sidecar 가 결정 전 다운로드를 받아 두는 곳 — `web_sidecar/preferences.zig`)의 파일을 지운다.
/// sidecar 가 없을 때만 부른다(죽었거나 끝났다 — 다시 뜨면 sidecar 도 비운다).
fn clearDownloadStaging(held: bool) void {
    // 시험은 실제 홈의 프로필을 건드리지 않는다(5 회차). 끝난 sidecar 가 프로필을 잡지 않았으면(잠금에 막혔다 — 같은 프로필의 다른
    // maru 가 받아 두는 중일 수 있다) 비우지 않는다.
    if (builtin.is_test or !held) return;
    var profile_buf: [std.fs.max_path_bytes]u8 = undefined;
    const profile = profileDir(&profile_buf) orelse return;
    var dir_buf: [std.fs.max_path_bytes + 32]u8 = undefined;
    const dir = std.fmt.bufPrintZ(&dir_buf, "{s}/download-staging", .{profile}) catch return;
    // 순회하며 지우면 항목을 건너뛸 수 있다 — 지운 것이 있으면 몇 번 더 돈다(9 회차).
    var pass: u8 = 0;
    while (pass < 4) : (pass += 1) {
        if (clearDirOnce(dir) == 0) break;
    }
}

fn clearDirOnce(dir: [:0]const u8) usize {
    var removed: usize = 0;
    const handle = std.c.opendir(dir) orelse return 0;
    defer _ = std.c.closedir(handle);
    while (std.c.readdir(handle)) |entry| {
        const name = entry.name[0..@min(entry.namlen, entry.name.len)];
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..") or entry.type == 4) continue;
        var file_buf: [std.fs.max_path_bytes + 300]u8 = undefined;
        const file = std.fmt.bufPrintZ(&file_buf, "{s}/{s}", .{ dir, name }) catch continue;
        if (std.c.unlink(file) == 0) removed += 1;
    }
    return removed;
}

/// 죽은 sidecar 가 쥐던 것을 버린다. 대화상자 콜백은 사라졌다 — 기다리던 요청을 버린다(떠 있는 창은 그 창이 닫는다). 알림
/// 번호도 새 sidecar 에서 다시 매겨지므로 아직 내보내지 않은 알림과 누를 수 있던 기록을 지운다(옛 번호가 새 알림을 누르지
/// 않게 — 적대 검증).
fn forgetSidecar(gpa: std.mem.Allocator) void {
    for (surfaces.values()) |*s| {
        dropDialogs(gpa, s);
        dropNotes(gpa, s);
        setTooltip(gpa, s, ""); // 죽은 sidecar 의 툴팁은 끝났다(W6b)
        dropDatalist(gpa, s); // 제안 목록도 — 고르기를 받을 문서가 없다(W6m②)
        dropContextMenu(gpa, s); // 그 메뉴의 콜백도 사라졌다 — 답하지 않는다(W6c②)
        dropPopup(s); // 닫힘 알림은 오지 않는다 — 다시 뜬 sidecar 의 브라우저에 옛 팝업이 남지 않게. 새 sidecar 는 세대를 1 부터 세므로 옛 링도 놓는다
        forgetDrag(s); // 새 sidecar 는 그 끌기를 모른다 — enter 없이 drop 을 보내지 않게(W6d①)
        dropDragOut(gpa, s); // 페이지 끌기도 — 답할 곳이 없다(W6d②)
        failFileFetch(s.record.surface_id); // 청한 파일 내용도 오지 않는다(W6d③)
        // 물은 닫기(W6j) — 답할 곳이 없다. 사용자는 닫기를 골랐다(떠나기 확인도 함께 사라졌다) — 창이 닫는다.
        if (s.close_ask == .asking or s.close_ask == .asked) s.close_ask = .closed;
    }
    forgetReserved(); // 맡긴 번호도 새 sidecar 는 모른다(W6f②) — 붙은 팝업은 새 sidecar 에서 보통 탭으로 되살아난다
    parked.clearRetainingCapacity(); // W10c: 주차한 브라우저도 sidecar 와 함께 사라졌다(다시 만들지 않는다 — 탭이 없다)
    web_downloads.sidecarLost(); // 받던 다운로드는 끝났다(W10a) — 임시 파일을 지우고 새 sidecar 의 번호와 섞이지 않게
    clearDownloadStaging(profile_held); // W10b: 죽은 sidecar 가 결정 전에 받아 둔 것(다시 뜨지 않으면 다음 실행까지 남았다 — 4 회차)
    profile_held = false;
    shown_notes = [_]?ShownNote{null} ** shown_notes.len;
}

/// sidecar 가 죽었다 — 예산 안이면 다시 띄워 살아 있던 브라우저를 되살린다.
fn crashed(gpa: std.mem.Allocator, now_ms: i64) void {
    if (process) |*p| {
        // 채널이 끝났어도 프로세스는 아직 살아 있을 수 있다 — 끝내고 거둔다(안 거두면 좀비로 남는다 — W7a1 적대 검증 5 차).
        if (!lsp_process.reapIfExited(p)) {
            lsp_process.kill(p, .KILL);
            lsp_process.reapBlocking(p);
        }
        p.deinit(gpa);
    }
    process = null;
    releaseRunCopy(&run_copy);
    state = .off;
    outbox_pending.clearRetainingCapacity();
    failures[failure_head] = now_ms;
    failure_head = (failure_head + 1) % restart_budget;
    var recent: usize = 0;
    for (failures) |at| {
        const t = at orelse continue;
        if (now_ms - t < restart_window_ms) recent += 1;
    }
    forgetSidecar(gpa);
    if (recent >= restart_budget) return fail(.crashed_repeatedly);
    if (surfaces.count() == 0) return;
    // 모든 브라우저를 처음부터 다시 만든다(기록을 「안 만들어짐」으로 돌리고 create 를 다시 보낸다).
    start(gpa, now_ms);
    var it = surfaces.iterator();
    while (it.next()) |entry| {
        const s = entry.value_ptr;
        s.created = false;
        sendCommand(gpa, .{ .create = .{ .browser = entry.key_ptr.*, .size = s.record.size, .hidden = s.record.hidden } });
    }
}

/// 받는 port 에 쌓인 링 알림을 모두 받아 그 브라우저의 View 에 넘긴다. 모르는 브라우저의 링은 바로 놓는다.
fn receiveRings() void {
    const r = if (receiver) |*r| r else return;
    var budget: usize = 64; // 한 tick 에 받는 상한 — 누가 넘치게 넣어도 tick 이 붙잡히지 않게
    while (budget > 0) : (budget -= 1) {
        const received = (r.receive(0) catch return) orelse return;
        switch (received) {
            .rejected => rejected_rings += 1,
            .ring => |ring| {
                const app_ring: AppRing = .{ .generation = ring.generation, .control = @ptrFromInt(ring.control_address), .width = ring.width, .height = ring.height, .ring = ring };
                const s = surfaces.getPtr(ring.browser) orelse {
                    // 맡긴 번호의 팝업 링이 `popup_created` 보다 먼저 왔다(W6f②) — 쥐어 둔다(다시 알려지지 않는다).
                    if (!ring.popup) if (reservedIndex(ring.browser)) |i| {
                        if (popup_reserved[i].ring) |old| old.release();
                        popup_reserved[i].ring = app_ring;
                        continue;
                    };
                    app_ring.release();
                    continue;
                };
                // 팝업 위젯의 링(W6a②)은 따로 고른다. 닫혀 있어도 받아 둔다 — 링(mach)이 보임 알림(파이프)보다 먼저 올 수 있고,
                // 옛 팝업의 늦은 링은 그릴 때 첫 세대로 거른다(`popupFront`).
                const view = if (ring.popup) &s.popup_view else &s.view;
                if (view.adopt(app_ring)) |never_drawn| never_drawn.release();
            },
        }
    }
}

fn sendCommand(gpa: std.mem.Allocator, command: plan.Command) void {
    switch (command) {
        .create => |c| send(gpa, .{ .create_browser = .{ .browser = c.browser, .size = c.size, .hidden = c.hidden, .url = "about:blank" } }),
        .resize => |c| send(gpa, .{ .resize = .{ .browser = c.browser, .size = c.size } }),
        .set_hidden => |c| send(gpa, .{ .set_hidden = .{ .browser = c.browser, .value = c.value } }),
    }
}

/// 보낸다 — handshake 전이면 쥐었다가 hello_ack 에 보낸다.
/// 다운로드(W10a — `web_downloads`)가 sidecar 로 보낸다.
pub fn sendToSidecar(gpa: std.mem.Allocator, message: Message) void {
    send(gpa, message);
}

/// 이 탭에 `window_ms` 안에 사용자 입력(누름·키·조합·편집 명령·메뉴 답·끌어 놓기)을 보냈고 그 뒤로 주 프레임에 새 문서가 오지 않았는가
/// (W10a — 사용자 동작으로 시작한 다운로드). 첨부 응답은 문서를 커밋하지 않아 「눌러서 받기」는 그대로다. 교차 출처 iframe 이 위 문서의
/// 누름으로 시작한 다운로드는 가르지 못한다(문서마다의 사용자 활성화는 Chromium 안에 있다).
pub fn recentUserInput(surface_id: u64, window_ms: i64, now_ms: i64) bool {
    const s = surfaces.getPtr(surface_id) orelse return false;
    return now_ms - downloadGestureMs(s) <= window_ms;
}

fn send(gpa: std.mem.Allocator, message: Message) void {
    var frame: [ws.wire.max_frame_bytes]u8 = undefined;
    const len = ws.codec.encode(message, &frame) catch return; // maru 가 만든 값이 codec 규칙을 어기면 보내지 않는다
    switch (state) {
        .starting => outbox_pending.appendSlice(gpa, frame[0..len]) catch {},
        .running => if (process) |*p| {
            _ = lsp_process.write(p, gpa, frame[0..len]) catch false;
        } else if (builtin.is_test and test_record_sends) outbox_pending.appendSlice(gpa, frame[0..len]) catch {},
        .off, .failed => {},
    }
}

/// 받은 바이트를 decoder 에 넣고 frame 을 적용한다. decoder 는 가장 큰 frame 하나만큼만 받으므로(W1a) frame 을 비우며
/// 조금씩 넣는다. 적용 중 채널이 끝나거나 다시 띄워지면(`process_generation`) 곧바로 멈춘다 — 그때 inbox 는 비워졌다.
fn drainInbox(gpa: std.mem.Allocator, now_ms: i64) void {
    const generation = process_generation;
    var consumed: usize = 0;
    while (true) {
        while (decoder.next() catch |err| return decodeFailed(gpa, now_ms, err)) |message| {
            apply(gpa, message, now_ms);
            if (process == null or process_generation != generation) return;
        }
        if (consumed == inbox.items.len) break;
        const fed = decoder.feed(inbox.items[consumed..]) catch |err| return decodeFailed(gpa, now_ms, err);
        if (fed == 0) return protocolBroken(gpa, now_ms); // frame 을 비웠는데 한 바이트도 못 넣는다 — 불변식이 깨졌다
        consumed += fed;
    }
    inbox.clearRetainingCapacity();
}

/// 받은 바이트가 frame 으로 풀리지 않는다. handshake 중에 버전이 다르면(따로 설치된 `maru-chromium` 이 이 maru 와 다른
/// 제어 채널 버전 — `wire.version`) 다시 띄워도 같으므로 멈추고 안내한다. 그 밖은 규칙 위반이라 죽인다.
fn decodeFailed(gpa: std.mem.Allocator, now_ms: i64, err: ws.wire.Error) void {
    if (err == error.UnsupportedVersion and state == .starting) return stopWith(gpa, .version_mismatch);
    protocolBroken(gpa, now_ms);
}

/// 다시 띄워도 같은 실패 — sidecar 를 끝내고 멈춘 뒤 안내한다. handshake 전에 쥔 명령도, 죽은 sidecar 가 쥐던 대화상자·알림
/// 기록도 버린다(보낼 곳·답할 곳이 없다 — 크래시 경로와 같게, W7a1 7 차 적대 검증).
fn stopWith(gpa: std.mem.Allocator, notice: Notice) void {
    if (process) |*p| {
        lsp_process.kill(p, .KILL);
        lsp_process.reapBlocking(p);
        p.deinit(gpa);
    }
    process = null;
    releaseRunCopy(&run_copy);
    outbox_pending.clearRetainingCapacity();
    forgetSidecar(gpa);
    fail(notice);
}

fn protocolBroken(gpa: std.mem.Allocator, now_ms: i64) void {
    if (process) |*p| lsp_process.kill(p, .KILL);
    crashed(gpa, now_ms);
}

fn apply(gpa: std.mem.Allocator, message: Message, now_ms: i64) void {
    switch (message) {
        .hello_ack => |ack| {
            if (state != .starting or ack.nonce != hello_nonce) return protocolBroken(gpa, now_ms);
            state = .running;
            // 받는 port 이름과 토큰은 제어 채널로만 건넨다(C3). 브라우저 생성보다 먼저 — 첫 그리기부터 링을 알린다.
            if (receiver) |*r| send(gpa, .{ .frame_channel = .{ .service = r.serviceName(), .token = r.token } });
            if (process) |*p| _ = lsp_process.write(p, gpa, outbox_pending.items) catch false;
            outbox_pending.clearRetainingCapacity();
        },
        .browser_created => |id| if (blk: {
            // W10b: 브라우저가 만들어졌다 — CEF 초기화(프로필 잠금)가 끝났다는 뜻이라 이 sidecar 가 프로필을 잡았다. handshake 는
            // 초기화 전에도 답한다 — hello_ack 로 세우면 잠금에 막힌 sidecar 가 같은 프로필의 다른 maru 가 받아 둔 것을 비웠다(7 회차).
            profile_held = true;
            break :blk surfaces.getPtr(id);
        }) |s| {
            s.created = true;
            dropPopup(s);
            if (s.last_url) |u| send(gpa, .{ .navigate = .{ .browser = id, .url = u } });
            if (s.focused) send(gpa, .{ .set_focus = .{ .browser = id, .value = true } });
            s.composing = false;
        },
        .browser_closed => |id| if (surfaces.getPtr(id)) |s| {
            // maru 가 닫지 않았는데 닫혔다(maru 가 닫은 탭은 이미 표에 없다) — 페이지가 `window.close` 했다(이어 받은 팝업, 또는 기록이 하나뿐이라 스크립트가 닫을 수 있는
            // 탭 — Blink 규칙). 붙기 전이면 줄에서 빼고, 아니면 창이 그 탭을 닫는다(유일한 탭이면 빈 탭으로 새로). 그대로 두면 죽은 번호의
            // 탭이 남았다(W6f② 적대 검증 4 차).
            s.created = false; // 그 브라우저는 없다 — 입력·이동·포커스를 죽은 번호로 보내지 않는다(W6f② 적대 검증 5 차)
            // 사용자가 닫기를 물었던 탭이면(W6j) 그 닫기가 끝났다 — 창이 그 탭을 닫는다(페이지가 닫은 것으로 보지 않는다: 유일한 탭이어도
            // 빈 탭으로 되살리지 않는다).
            if (s.close_ask == .asking or s.close_ask == .asked) {
                s.close_ask = .closed;
            } else if (dropPendingAdopt(gpa, id)) abandonPopup(gpa, id) else s.page_closed = true;
            dropPopup(s); // 닫힘 알림 없이 사라진다(W6a②)
            setTooltip(gpa, s, ""); // 툴팁도(W6b — 방어)
            dropDatalist(gpa, s); // 제안 목록도(W6m② — sidecar 는 브라우저가 닫히면 알리지 않는다)
            dropContextMenu(gpa, s); // 브라우저가 닫히며 CEF 가 메뉴를 거뒀다(W6c② — 닫힘 알림은 sidecar 가 보내지 않는다)
            forgetDrag(s); // 끌기도(W6d①)
            dropDragOut(gpa, s); // sidecar 가 그 끌기를 놓았다(W6d②)
            failFileFetch(id); // 받아 둔 파일도(W6d③)
        },
        .drag_operation => |v| if (surfaces.getPtr(v.browser)) |s| {
            if (s.drag_entered) s.drag_operation = v.operation;
        },
        // 페이지 끌기의 조각 — 새 번호면 앞 것을 버린다(sidecar 가 앞 끌기를 끝냈다).
        // 청한 파일 내용의 조각(W6d③) — 끌기와 따로 모은다(끌기는 이미 끝났을 수 있다).
        .drag_out_data => |v| if (v.kind == .file_contents) fileFetchAdd(gpa, v) else if (surfaces.getPtr(v.browser)) |s| {
            const d = dragOutFor(gpa, s, v.drag) orelse return;
            if (d.ready) return; // `drag_out` 뒤 조각은 규칙 위반이 아니지만 쓰지 않는다
            d.add(gpa, v.kind, v.bytes);
        },
        .drag_out => |v| if (surfaces.getPtr(v.browser)) |s| {
            const d = dragOutFor(gpa, s, v.drag) orelse return;
            if (d.ready) return;
            d.ready = true;
            d.allowed = v.allowed;
            d.point = v.point;
            d.hotspot = v.hotspot;
            d.image_width = v.image_width;
            d.image_height = v.image_height;
            d.file_size = v.file_size;
            d.arrived_ms = now_ms;
            // 파일을 받아 둔 끌기 — sidecar 는 다음 끌기까지 쥐므로 maru 도 그 번호를 기억한다(끌기가 끝난 뒤 Finder 가 청한다).
            if (v.file_size != 0) file_source = .{ .surface = v.browser, .drag = v.drag, .size = v.file_size };
        },
        .drag_file_ready => |v| if (file_fetch) |*f| if (f.surface == v.browser and f.drag == v.drag and f.state == .pending) {
            f.state = if (v.ok and v.size == f.expected and f.contents.items.len == f.expected) .ready else .failed;
        },
        // W6e: 새 탭 — maru 가 주소를 다시 거른다(sidecar 도 걸렀다). 모르는 탭이면 버린다.
        .open_tab => |v| if (surfaces.getPtr(v.browser)) |s| queueNewTab(gpa, s, v, now_ms),
        // W6f②: 맡긴 번호로 만든 팝업 — 붙이거나 닫는다(`adoptPopup`).
        .popup_created => |v| adoptPopup(gpa, v, now_ms),
        .url_changed => |v| if (surfaces.getPtr(v.browser)) |s| {
            const owned = gpa.dupe(u8, v.url) catch return;
            if (s.url) |old| gpa.free(old);
            s.url = owned;
            s.nav_dirty = true;
            // 다른 사이트로 옮기면 Chromium 이 렌더러를 바꾸고 새 렌더러는 포커스를 모른다 — 키는 닿아도 페이지 `focus`
            // 가 안 오고 입력기 조합이 버려졌다(W4c 실측). 포커스를 줘야 하는 탭이면 다시 준다.
            if (s.focused and s.created) send(gpa, .{ .set_focus = .{ .browser = v.browser, .value = true } });
            s.composing = false; // 이동하면 페이지의 조합은 사라진다
        },
        .page_started => |id| if (surfaces.getPtr(id)) |s| {
            s.last_nav_ms = monotonicNow();
            // W10c: 닫기 대신 보낸 about:blank 가 열렸다(떠나기 확인이 없었거나 떠나기) — 창이 그 탭을 닫는다.
            if (s.close_park and (s.close_ask == .asking or s.close_ask == .asked)) {
                s.close_park = false;
                s.close_ask = .closed;
            }
        },
        .nav_state => |v| if (surfaces.getPtr(v.browser)) |s| {
            s.can_go_back = v.can_go_back;
            s.can_go_forward = v.can_go_forward;
            s.nav_dirty = true;
        },
        .failure => |f| switch (f.code) {
            .gpu_unavailable => if (surfaces.getPtr(f.browser)) |s| {
                s.gpu_notice_pending = true;
            },
            // 다른 maru 가 같은 프로필을 쓴다 — 다시 띄워도 같다. 멈추고 안내한다.
            .profile_in_use => stopWith(gpa, .profile_in_use),
            .cef_initialize_failed, .protocol_violation => protocolBroken(gpa, now_ms),
            // 맡긴 번호로 팝업을 등록하지 못했다(W6f① — sidecar 가 닫았다) — 그 번호는 쓰였다고 보고 거둔다(다시 맡긴다).
            .browser_create_failed => if (takeReserved(f.browser)) |r| if (r.ring) |ring| ring.release(),
            .unknown_browser, .duplicate_browser, .frame_channel_failed => {},
        },
        .title_changed, .load_finished => {},
        // 렌더러가 죽으면 그 페이지의 툴팁도 끝났다(CEF 가 빈 글을 부르지 않을 수 있다).
        .renderer_gone => |v| if (surfaces.getPtr(v.browser)) |s| {
            setTooltip(gpa, s, ""); // 메뉴는 sidecar 가 닫음을 보낸다(W6c①)
            dropDatalist(gpa, s); // sidecar 도 닫기를 보내지만(W6m①) 먼저 닫는다
            // sidecar 도 그 끌기를 잊었다 — 남겨 두면 죽은 페이지의 옛 동작을 돌려주고 놓기를 받았다고 답했다(W6d① 적대 검증 1 차).
            // 창은 다음 움직임에 다시 enter 한다(`dragEntered`).
            forgetDrag(s);
        },
        .tooltip_changed => |v| if (surfaces.getPtr(v.browser)) |s| setTooltip(gpa, s, v.text),
        .cursor_changed => |v| if (surfaces.getPtr(v.browser)) |s| {
            s.cursor = v.cursor;
            s.cursor_generation +%= 1;
        },
        .ime_range => |v| if (surfaces.getPtr(v.browser)) |s| {
            s.ime_bounds = v.bounds;
        },
        .popup_changed => |v| if (surfaces.getPtr(v.browser)) |s| {
            if (v.visible) {
                s.popup_bounds = v.bounds;
                s.popup_first_generation = v.first_generation;
                s.popup_view.expect(pixels(v.bounds.width, s.record.size.scale), pixels(v.bounds.height, s.record.size.scale));
                s.popup_redraw = true;
                s.popup_release_generation = 0; // 남은 옛 링은 이 팝업의 첫 장이 꺼낼 때(poll 의 retire), 장 없이 닫히면 그 닫힘이 놓는다
            } else hidePopup(s);
        },
        .js_dialog => |v| {
            const kind: DialogKind = switch (v.kind) {
                .alert => .alert,
                .confirm => .confirm,
                .prompt => .prompt,
                .before_unload => .before_unload,
            };
            if (!queueDialog(gpa, v.browser, v.request, kind, v.origin, v.message, v.default_text, "", v.offer_suppress))
                send(gpa, .{ .dialog_reply = .{ .browser = v.browser, .request = v.request, .accept = kind == .before_unload } })
            else if (kind == .before_unload) if (surfaces.getPtr(v.browser)) |s| {
                // 물은 닫기에 페이지가 떠나기 확인으로 답했다(W6j) — 사용자가 답할 때까지 시한 없이 기다린다.
                if (s.close_ask == .asking) s.close_ask = .asked;
            };
        },
        .file_dialog => |v| {
            const kind: DialogKind = switch (v.mode) {
                .open => .file_open,
                .open_multiple => .file_open_multiple,
                .open_folder => .file_open_folder,
                .save => .file_save,
            };
            if (!queueDialog(gpa, v.browser, v.request, kind, "", v.title, v.default_path, v.accept, false))
                send(gpa, .{ .file_dialog_reply = .{ .browser = v.browser, .request = v.request, .accept = false } });
        },
        // 받지 못하면(상한·모르는 탭) 「못 물음」으로 답한다 — 차단은 Chromium 이 기억하고 닫기는 embargo 를 쌓는다.
        // maru 가 허용을 기록한 기억된 위치 요청은 허용과 「없음」으로(되풀이된 못 물음이 embargo 를 만들지 않게) — sidecar 의
        // 표시만이면 못 물음.
        .permission_request => |v| if (!queuePermission(gpa, v)) {
            const allowed = v.remembered and locationAllowed(v.browser, v.origin);
            if (allowed) send(gpa, .{ .geolocation = .{ .browser = v.browser, .request = v.request, .available = false } });
            send(gpa, .{ .permission_reply = .{ .browser = v.browser, .request = v.request, .result = if (allowed) .accept else .ignore } });
        },
        .web_notification => |v| queueNote(gpa, v),
        // W6m②: 제안 목록 — 그 탭이 키 대상인 창이 그린다. 닫기는 그 목록 번호일 때만(0 이면 어느 것이든).
        .datalist_show => |v| if (surfaces.getPtr(v.browser)) |s| setDatalist(gpa, s, v),
        // W10a: 다운로드 — 경로는 maru 가 정한다(`web_downloads`). 받아들일 수 없으면 곧바로 받지 않는다고 답한다.
        .download_begin => |v| if (surfaces.getPtr(v.browser) == null or !web_downloads.onBegin(v, monotonicNow())) {
            send(gpa, .{ .download_decide = .{ .browser = v.browser, .download = v.download, .path = "" } });
        } else if (surfaces.getPtr(v.browser)) |s| {
            // W10c: 페이지가 연 탭이 문서도 사용자 입력도 없이 다운로드만 했다(`target=_blank` 첨부·`window.open` 파일) — 빈 탭으로
            // 남기지 않는다(창이 닫고, 받던 것은 `destroy` 가 숨겨 이어 받는다). 사용자가 그 탭에서 누른 것이면 문서가 있던 탭이다.
            // 문서는 주소로 가른다 — 다운로드가 된 이동은 주소를 바꾸지 않는다. 새 문서 표지(`page_started`)로 가르면 주소로 연 새 탭이
            // 처음 만들어질 때의 about:blank 가 「문서」로 세어져 닫히지 않았다(스모크가 잡았다).
            const untouched = std.math.minInt(i64) / 2;
            const no_document = if (s.url) |u| std.mem.eql(u8, u, "about:blank") else true;
            if (s.page_opened and no_document and s.last_user_input_ms == untouched) s.download_blank = true;
        },
        .download_update => |v| web_downloads.onUpdate(v),
        .datalist_hide => |v| if (surfaces.getPtr(v.browser)) |s| if (s.datalist) |d| if (v.list == 0 or v.list == d.list) dropDatalist(gpa, s),
        // W6c②: 우클릭 메뉴 — 그 탭이 보이는 창이 가져가 띄운다. 모르는 탭이거나 담을 항목이 없으면(동영상 자리) 곧바로 취소한다.
        // 앞 메뉴가 남았으면(생기지 않는다 — CEF 는 메뉴가 떠 있는 동안 새 메뉴를 만들지 않는다) 그것은 취소로 끝낸다.
        .context_menu => |v| {
            const s = surfaces.getPtr(v.browser) orelse {
                send(gpa, .{ .context_menu_command = .{ .browser = v.browser, .menu = v.menu, .command = .cancel } });
                return;
            };
            cancelContextMenu(gpa, s);
            const selection = gpa.dupe(u8, v.selection) catch null;
            if (selection == null or maru.session.web_osr_context_menu.build(v.flags, true).len == 0) {
                if (selection) |b| gpa.free(b);
                send(gpa, .{ .context_menu_command = .{ .browser = v.browser, .menu = v.menu, .command = .cancel } });
                return;
            }
            s.context_menu = .{ .menu = v.menu, .point = v.point, .flags = v.flags, .selection = selection.?, .arrived_ms = now_ms };
        },
        // 띄운 메뉴면 닫혔다고 적어 창이 거두게 하고, 아직 안 띄웠으면 지운다(답은 보내지 않는다 — sidecar 가 끝냈다).
        .context_menu_closed => |v| if (surfaces.getPtr(v.browser)) |s| if (s.context_menu) |m| if (m.menu == v.menu) {
            if (m.shown) s.context_menu.?.closed = true else dropContextMenu(gpa, s);
        },
        .dialog_closed => |v| if (surfaces.getPtr(v.browser)) |s| {
            for (s.dialogs.items) |d| if (d.request == v.request) {
                // 물은 닫기의 떠나기 확인이 답 없이 치워졌다(W6j) — 그사이 사용자가 그 탭을 옮겨 가게 했거나(sidecar 가 이동·새로고침 전에
                // 머무르기로 답한다 — `cancelFor`) 렌더러가 죽었다. 닫기는 그만둔다(탭을 둔다) — 시한으로 강제하면 사용자가 고르지 않은
                // 떠나기가 되고 이동을 잃었다(적대 검증). 브라우저가 그래도 닫히면 페이지가 닫은 탭으로 처리된다.
                if (d.kind == .before_unload and s.close_ask == .asked) s.close_ask = .stayed;
                removeDialog(gpa, s, d.token);
                break;
            };
        },
        // 방향이 다른 tag 는 decoder 가 이미 거절했다.
        .hello, .create_browser, .destroy_browser, .resize, .set_hidden, .set_focus, .navigate, .shutdown, .frame_channel, .nav_action, .mouse, .wheel, .key, .ime_set_composition, .ime_commit_text, .ime_finish_composing, .ime_cancel_composition, .edit_command, .capture_lost, .dialog_reply, .file_dialog_path, .file_dialog_reply, .permission_reply, .geolocation, .web_notification_click, .context_menu_command, .drag_data, .drag_target, .drag_source_end, .drag_file_request, .popup_reserve, .close_asking, .datalist_pick, .download_decide, .download_control => unreachable,
    }
}

/// 시험용 — 쌓인 frame(handshake 전 outbox)을 풀어 돌려준다.
fn sentFrames(out: []Message) usize {
    var n: usize = 0;
    var rest = outbox_pending.items;
    while (rest.len >= 4 and n < out.len) {
        const len = 4 + std.mem.readInt(u32, rest[0..4], .big);
        out[n] = ws.codec.decodeExact(rest[0..len]) catch unreachable;
        n += 1;
        rest = rest[len..];
    }
    return n;
}

test "dialogs queue per tab, show one at a time, and each answer goes out exactly once" {
    const gpa = std.testing.allocator;
    state = .starting; // 보낸 frame 을 outbox 에 쌓게(sidecar 없이)
    defer {
        for (surfaces.values()) |*s| freeSurface(gpa, s);
        surfaces.deinit(gpa);
        surfaces = .empty;
        outbox_pending.deinit(gpa);
        outbox_pending = .empty;
        state = .off;
    }
    try surfaces.put(gpa, 7, .{ .record = .{ .surface_id = 7, .size = .{ .width = 10, .height = 10, .scale = 1 }, .hidden = false }, .created = true });
    apply(gpa, .{ .js_dialog = .{ .browser = 7, .request = 1, .kind = .alert, .origin = "https://a.b", .message = "하나" } }, 0);
    apply(gpa, .{ .js_dialog = .{ .browser = 7, .request = 2, .kind = .prompt, .origin = "", .message = "둘", .default_text = "기본" } }, 0);
    const first = nextDialog(7).?;
    try std.testing.expectEqual(@as(u32, 1), first.request);
    const first_token = first.token;
    // 떠 있는 동안 다음 요청은 나오지 않는다(한 탭에 하나씩).
    markDialogShown(7, first_token, 11);
    try std.testing.expect(nextDialog(7) == null);
    replyDialog(gpa, 7, first_token, true, "", false);
    replyDialog(gpa, 7, first_token, true, "", false); // 두 번째 답은 무동작
    const second = nextDialog(7).?;
    const second_token = second.token;
    try std.testing.expect(second_token != first_token);
    try std.testing.expectEqual(DialogKind.prompt, second.kind);
    try std.testing.expectEqualStrings("기본", second.default_text);
    // 페이지가 옮겨 가 요청이 사라지면 답을 보내지 않는다.
    apply(gpa, .{ .dialog_closed = .{ .browser = 7, .request = 2 } }, 0);
    try std.testing.expect(dialogPending(7, second_token) == null);
    // 상한을 넘은 요청은 곧바로 기본값으로 답한다(떠나기 확인은 떠나기).
    for (3..7) |r| apply(gpa, .{ .js_dialog = .{ .browser = 7, .request = @intCast(r), .kind = .confirm, .origin = "", .message = "" } }, 0);
    apply(gpa, .{ .js_dialog = .{ .browser = 7, .request = 9, .kind = .before_unload, .origin = "", .message = "" } }, 0);
    for (surfaces.getPtr(7).?.dialogs.items) |d| try std.testing.expect(d.request != 9);
    // 모르는 탭의 요청도 곧바로 답한다(sidecar 가 콜백을 쥔 채 남지 않게).
    apply(gpa, .{ .file_dialog = .{ .browser = 99, .request = 10, .mode = .open } }, 0);
    // 창이 닫히면 그 창이 띄운 요청만 취소로 답한다.
    const third = nextDialog(7).?.token;
    const fourth = surfaces.getPtr(7).?.dialogs.items[1].token;
    markDialogShown(7, third, 11);
    cancelDialogsShownBy(gpa, 11);
    try std.testing.expect(dialogPending(7, third) == null);
    try std.testing.expect(dialogPending(7, fourth) != null);

    var frames: [16]Message = undefined;
    const n = sentFrames(&frames);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expect(frames[0].dialog_reply.request == 1 and frames[0].dialog_reply.accept);
    try std.testing.expect(frames[1].dialog_reply.request == 9 and frames[1].dialog_reply.accept);
    try std.testing.expect(frames[2].file_dialog_reply.request == 10 and !frames[2].file_dialog_reply.accept);
    try std.testing.expect(frames[3].dialog_reply.request == 3 and !frames[3].dialog_reply.accept);
}

test "W6j: a close asked of the page closes, stays or is forced after the wait — never mistaken for a page that closed itself" {
    const gpa = std.testing.allocator;
    gpa_ref = gpa;
    try std.testing.expectEqual(@as(usize, 0), surfaces.count());
    defer {
        for (surfaces.values()) |*s| freeSurface(gpa, s);
        surfaces.deinit(gpa);
        surfaces = .empty;
        outbox_pending.deinit(gpa);
        outbox_pending = .empty;
        state = .off;
    }
    state = .running; // 보낸 것은 버려진다(sidecar 없음) — 상태만 본다
    const size: ws.message.ViewSize = .{ .width = 10, .height = 10, .scale = 1 };
    try surfaces.put(gpa, 7, .{ .record = .{ .surface_id = 7, .size = size, .hidden = false }, .created = true });
    try surfaces.put(gpa, 8, .{ .record = .{ .surface_id = 8, .size = size, .hidden = false } });
    // 브라우저가 아직 없거나 모르는 탭이면 묻지 않는다(호출자가 곧바로 닫는다).
    try std.testing.expect(!askClose(gpa, 8, 0));
    try std.testing.expect(!askClose(gpa, 99, 0));

    // 묻지 않는 페이지 — 닫힘이 오면 창이 닫는다. 페이지가 닫은 것(`window.close` — 유일한 탭이면 빈 탭으로 되살림)으로 보지 않는다.
    try std.testing.expect(askClose(gpa, 7, 0));
    try std.testing.expectEqual(CloseAskOutcome.waiting, takeCloseAsk(7, 100));
    apply(gpa, .{ .browser_closed = 7 }, 0);
    try std.testing.expect(!takePageClosed(7));
    try std.testing.expectEqual(CloseAskOutcome.closed, takeCloseAsk(7, 100));
    try std.testing.expectEqual(CloseAskOutcome.none, takeCloseAsk(7, 100));
    // 닫힌 브라우저에는 다시 묻지 않는다.
    try std.testing.expect(!askClose(gpa, 7, 0));
    surfaces.getPtr(7).?.created = true;

    // 떠나기 확인 — 질문이 오면 시한 없이 기다리고, 머무르기면 둔다(한 번 보고).
    var t = monotonicNow();
    try std.testing.expect(askClose(gpa, 7, t));
    try std.testing.expect(askClose(gpa, 7, t)); // 묻는 중 — 다시 보내지 않는다
    apply(gpa, .{ .js_dialog = .{ .browser = 7, .request = 5, .kind = .before_unload, .origin = "", .message = "" } }, 0);
    try std.testing.expectEqual(CloseAskOutcome.waiting, takeCloseAsk(7, t + close_ask_wait_ms * 10));
    replyDialog(gpa, 7, nextDialog(7).?.token, false, "", false);
    try std.testing.expectEqual(CloseAskOutcome.stayed, takeCloseAsk(7, t));
    try std.testing.expectEqual(CloseAskOutcome.none, takeCloseAsk(7, t));

    // 떠나기 — 닫힘을 기다리고, 시한 안에 안 오면 강제로.
    t = monotonicNow();
    try std.testing.expect(askClose(gpa, 7, t));
    apply(gpa, .{ .js_dialog = .{ .browser = 7, .request = 6, .kind = .before_unload, .origin = "", .message = "" } }, 0);
    replyDialog(gpa, 7, nextDialog(7).?.token, true, "", false);
    t = monotonicNow();
    try std.testing.expectEqual(CloseAskOutcome.waiting, takeCloseAsk(7, t));
    try std.testing.expectEqual(CloseAskOutcome.timed_out, takeCloseAsk(7, t + close_ask_wait_ms + 1));

    // 질문이 답 없이 치워지면(사용자가 이동하게 함·렌더러가 죽음) 닫기를 그만둔다 — 강제하지 않는다.
    try std.testing.expect(askClose(gpa, 7, 0));
    apply(gpa, .{ .js_dialog = .{ .browser = 7, .request = 7, .kind = .before_unload, .origin = "", .message = "" } }, 0);
    apply(gpa, .{ .dialog_closed = .{ .browser = 7, .request = 7 } }, 0);
    try std.testing.expectEqual(CloseAskOutcome.stayed, takeCloseAsk(7, monotonicNow() + close_ask_wait_ms * 10));

    // 떠나기 뒤 닫힘이 오면 닫힌다.
    try std.testing.expect(askClose(gpa, 7, 0));
    apply(gpa, .{ .js_dialog = .{ .browser = 7, .request = 8, .kind = .before_unload, .origin = "", .message = "" } }, 0);
    replyDialog(gpa, 7, nextDialog(7).?.token, true, "", false);
    apply(gpa, .{ .browser_closed = 7 }, 0);
    try std.testing.expect(!takePageClosed(7));
    try std.testing.expectEqual(CloseAskOutcome.closed, takeCloseAsk(7, 0));
    surfaces.getPtr(7).?.created = true;

    // 창이 닫히며 띄운 질문을 떠나기로 답하면(`cancelDialogsShownBy`) 닫힘을 기다린다.
    try std.testing.expect(askClose(gpa, 7, 0));
    apply(gpa, .{ .js_dialog = .{ .browser = 7, .request = 9, .kind = .before_unload, .origin = "", .message = "" } }, 0);
    markDialogShown(7, nextDialog(7).?.token, 11);
    cancelDialogsShownBy(gpa, 11);
    t = monotonicNow();
    try std.testing.expectEqual(CloseAskOutcome.waiting, takeCloseAsk(7, t));
    try std.testing.expectEqual(CloseAskOutcome.timed_out, takeCloseAsk(7, t + close_ask_wait_ms + 1));

    // 질문도 닫힘도 없으면(처리기가 멈춤) 시한 뒤 강제로.
    try std.testing.expect(askClose(gpa, 7, 1000));
    try std.testing.expectEqual(CloseAskOutcome.waiting, takeCloseAsk(7, 1000 + close_ask_wait_ms - 1));
    try std.testing.expectEqual(CloseAskOutcome.timed_out, takeCloseAsk(7, 1000 + close_ask_wait_ms));

    // sidecar 가 죽으면 묻던 닫기는 닫힌다(답할 곳이 없다 — 사용자는 닫기를 골랐다).
    try std.testing.expect(askClose(gpa, 7, 0));
    forgetSidecar(gpa);
    try std.testing.expectEqual(CloseAskOutcome.closed, takeCloseAsk(7, 0));
    // 엔진이 돌지 않으면 시한을 기다리지 않는다.
    try std.testing.expect(askClose(gpa, 7, 0));
    state = .off;
    try std.testing.expectEqual(CloseAskOutcome.timed_out, takeCloseAsk(7, 0));
    try std.testing.expect(!askClose(gpa, 7, 0));
}

test "permission requests share the dialog queue: one answer each, other answers cannot close them, a closing window dismisses" {
    const gpa = std.testing.allocator;
    state = .starting;
    defer {
        for (surfaces.values()) |*s| freeSurface(gpa, s);
        surfaces.deinit(gpa);
        surfaces = .empty;
        outbox_pending.deinit(gpa);
        outbox_pending = .empty;
        state = .off;
    }
    try surfaces.put(gpa, 7, .{ .record = .{ .surface_id = 7, .size = .{ .width = 10, .height = 10, .scale = 1 }, .hidden = false }, .created = true });
    apply(gpa, .{ .permission_request = .{ .browser = 7, .request = 1, .origin = "https://meet.example", .media = 0b11 } }, 0);
    const asked = nextDialog(7).?;
    try std.testing.expectEqual(DialogKind.permission, asked.kind);
    try std.testing.expectEqual(@as(u8, 0b11), asked.permission_media);
    try std.testing.expectEqualStrings("https://meet.example", asked.origin);
    const token = asked.token;
    // JS 대화상자·파일 선택의 답은 권한 요청을 닫지 못한다.
    replyDialog(gpa, 7, token, true, "", false);
    replyFileDialog(gpa, 7, token, true);
    try std.testing.expect(dialogPending(7, token) != null);
    try std.testing.expect(replyPermission(gpa, 7, token, .accept));
    try std.testing.expect(!replyPermission(gpa, 7, token, .deny)); // 두 번째 답은 무동작
    try std.testing.expect(dialogPending(7, token) == null);
    // 권한 답은 대화상자를 닫지 못한다.
    apply(gpa, .{ .js_dialog = .{ .browser = 7, .request = 2, .kind = .confirm, .origin = "", .message = "" } }, 0);
    const confirm = nextDialog(7).?.token;
    try std.testing.expect(!replyPermission(gpa, 7, confirm, .accept));
    try std.testing.expect(dialogPending(7, confirm) != null);
    replyDialog(gpa, 7, confirm, false, "", false);
    // 창이 닫히면 그 창이 띄운 권한 요청은 「못 물음」으로(차단은 기억되고 닫기는 embargo 를 쌓는다), 상한을 넘은 요청·모르는
    // 탭도 「못 물음」으로.
    apply(gpa, .{ .permission_request = .{ .browser = 7, .request = 3, .origin = "", .kinds = ws.message.PermissionKind.notifications.bit() } }, 0);
    const notif = nextDialog(7).?;
    try std.testing.expectEqual(ws.message.PermissionKind.notifications.bit(), notif.permission_kinds);
    markDialogShown(7, notif.token, 11);
    cancelDialogsShownBy(gpa, 11);
    for (4..9) |r| apply(gpa, .{ .permission_request = .{ .browser = 7, .request = @intCast(r), .origin = "", .kinds = 1 } }, 0);
    apply(gpa, .{ .permission_request = .{ .browser = 99, .request = 10, .origin = "", .kinds = 1 } }, 0);
    // 페이지가 옮겨 가 요청이 사라지면 답을 보내지 않는다.
    apply(gpa, .{ .dialog_closed = .{ .browser = 7, .request = 4 } }, 0);

    var frames: [16]Message = undefined;
    const n = sentFrames(&frames);
    try std.testing.expectEqual(@as(usize, 5), n);
    try std.testing.expect(frames[0].permission_reply.request == 1 and frames[0].permission_reply.result == .accept);
    try std.testing.expect(frames[1].dialog_reply.request == 2 and !frames[1].dialog_reply.accept);
    try std.testing.expect(frames[2].permission_reply.request == 3 and frames[2].permission_reply.result == .ignore);
    try std.testing.expect(frames[3].permission_reply.request == 8 and frames[3].permission_reply.result == .ignore);
    try std.testing.expect(frames[4].permission_reply.request == 10 and frames[4].permission_reply.result == .ignore);
    try std.testing.expectEqual(@as(usize, 3), surfaces.getPtr(7).?.dialogs.items.len);
}

test "remembered location requests skip the sheet only for origins the user allowed in maru, take coordinates before the allow" {
    const gpa = std.testing.allocator;
    state = .starting;
    defer {
        for (surfaces.values()) |*s| freeSurface(gpa, s);
        surfaces.deinit(gpa);
        surfaces = .empty;
        outbox_pending.deinit(gpa);
        outbox_pending = .empty;
        forgetAllLocations(gpa);
        state = .off;
    }
    try surfaces.put(gpa, 7, .{ .record = .{ .surface_id = 7, .size = .{ .width = 10, .height = 10, .scale = 1 }, .hidden = false }, .created = true });
    const geo = ws.message.PermissionKind.geolocation.bit();
    const site = "https://maps.example";
    // sidecar 가 「기억된 허용」이라 해도 maru 가 기록하지 않은 출처면 sheet 로 묻는다(적대 검증 — 장악된 sidecar).
    apply(gpa, .{ .permission_request = .{ .browser = 7, .request = 1, .origin = site, .kinds = geo, .remembered = true } }, 0);
    try std.testing.expect(nextLocation(11) == null);
    const asked = nextDialog(7).?;
    try std.testing.expect(!asked.remembered);
    // sheet 에서 허용하면 좌표를 먼저 걸고 허용한다 — 그 출처가 기록된다.
    try std.testing.expect(replyLocation(gpa, 7, asked.token, .{ .latitude = 37.5, .longitude = 127, .accuracy = 30 }, .accept));
    try std.testing.expect(!replyLocation(gpa, 7, asked.token, null, .accept)); // 두 번째 답은 무동작
    // 이제 그 출처의 기억된 요청은 sheet 를 건너뛰고 창 하나가 맡는다. 빈 출처·다른 출처는 여전히 sheet.
    apply(gpa, .{ .permission_request = .{ .browser = 7, .request = 2, .origin = site, .kinds = geo, .remembered = true } }, 0);
    apply(gpa, .{ .permission_request = .{ .browser = 7, .request = 3, .origin = "", .kinds = geo, .remembered = true } }, 0);
    const loc = nextLocation(11).?;
    try std.testing.expect(nextLocation(12) == null);
    // (대기열 원소를 가리키는 포인터는 다음 요청이 오면 무효다 — 값으로 떠 둔다.)
    const blank = nextDialog(7).?;
    try std.testing.expect(blank.request == 3 and !blank.remembered);
    const blank_token = blank.token;
    // 범위를 벗어난 좌표는 「없음」으로.
    try std.testing.expect(replyLocation(gpa, 7, loc.token, .{ .latitude = 91, .longitude = 0, .accuracy = 5 }, .accept));
    // 맡은 창이 닫히면 기억된 요청은 끝내지 않고 맡음만 푼다 — 다른 창이 맡는다.
    apply(gpa, .{ .permission_request = .{ .browser = 7, .request = 4, .origin = site, .kinds = geo, .remembered = true } }, 0);
    const held = nextLocation(11).?;
    cancelDialogsShownBy(gpa, 11);
    try std.testing.expectEqual(held.token, nextLocation(12).?.token);
    // 다른 탭(8)이 같은 출처를 「기억된 허용」으로 청해도 sheet 로 — 허용은 허용한 탭에 묶인다(장악된 sidecar 가 탭 번호를 흉내 내도).
    try surfaces.put(gpa, 8, .{ .record = .{ .surface_id = 8, .size = .{ .width = 10, .height = 10, .scale = 1 }, .hidden = false }, .created = true });
    apply(gpa, .{ .permission_request = .{ .browser = 8, .request = 8, .origin = site, .kinds = geo, .remembered = true } }, 0);
    const other_tab = nextDialog(8).?;
    try std.testing.expect(!other_tab.remembered);
    const other_tab_token = other_tab.token;
    // 차단하면 기록에서 빠지고, 좌표를 기다리던 같은 출처의 허용(탭 8)은 늦게 와도 허용이 되지 않는다(못 물음).
    try std.testing.expect(replyPermission(gpa, 7, blank_token, .deny));
    apply(gpa, .{ .permission_request = .{ .browser = 7, .request = 5, .origin = site, .kinds = geo } }, 0);
    try std.testing.expect(replyPermission(gpa, 7, nextDialog(7).?.token, .deny));
    try std.testing.expect(replyLocation(gpa, 8, other_tab_token, .{ .latitude = 1, .longitude = 1, .accuracy = 1 }, .accept));
    try std.testing.expect(!locationAllowed(8, site));
    apply(gpa, .{ .permission_request = .{ .browser = 7, .request = 6, .origin = site, .kinds = geo, .remembered = true } }, 0);
    try std.testing.expect(!nextDialog(7).?.remembered);
    apply(gpa, .{ .permission_request = .{ .browser = 99, .request = 7, .origin = site, .kinds = geo, .remembered = true } }, 0);

    var frames: [16]Message = undefined;
    const n = sentFrames(&frames);
    try std.testing.expectEqual(@as(usize, 8), n);
    try std.testing.expect(frames[0].geolocation.request == 1 and frames[0].geolocation.available and frames[0].geolocation.latitude == 37.5);
    try std.testing.expect(frames[1].permission_reply.request == 1 and frames[1].permission_reply.result == .accept);
    try std.testing.expect(frames[2].geolocation.request == 2 and !frames[2].geolocation.available);
    try std.testing.expect(frames[3].permission_reply.request == 2 and frames[3].permission_reply.result == .accept);
    try std.testing.expect(frames[4].permission_reply.request == 3 and frames[4].permission_reply.result == .deny);
    try std.testing.expect(frames[5].permission_reply.request == 5 and frames[5].permission_reply.result == .deny);
    try std.testing.expect(frames[6].permission_reply.request == 8 and frames[6].permission_reply.result == .ignore);
    // 모르는 탭(99)은 maru 가 기록하지 않았으니 sidecar 의 표시만으로는 못 물음.
    try std.testing.expect(frames[7].permission_reply.request == 7 and frames[7].permission_reply.result == .ignore);
}

test "web notifications queue per tab, drop the oldest past the cap, and a click reaches only its own tab" {
    const gpa = std.testing.allocator;
    state = .starting;
    defer {
        for (surfaces.values()) |*s| freeSurface(gpa, s);
        surfaces.deinit(gpa);
        surfaces = .empty;
        outbox_pending.deinit(gpa);
        outbox_pending = .empty;
        shown_notes = [_]?ShownNote{null} ** shown_notes.len;
        state = .off;
    }
    try surfaces.put(gpa, 7, .{ .record = .{ .surface_id = 7, .size = .{ .width = 10, .height = 10, .scale = 1 }, .hidden = false }, .created = true });
    try surfaces.put(gpa, 8, .{ .record = .{ .surface_id = 8, .size = .{ .width = 10, .height = 10, .scale = 1 }, .hidden = false }, .created = true });
    for (1..11) |i| apply(gpa, .{ .web_notification = .{ .browser = 7, .notification = @intCast(i), .origin = "https://chat.example", .title = "t", .body = "b" } }, 0);
    apply(gpa, .{ .web_notification = .{ .browser = 99, .notification = 1, .origin = "https://a.b", .title = "t" } }, 0); // 모르는 탭
    // 상한 8 — 오래된 둘(1·2)은 버려졌다.
    const first = takeWebNotification(7).?;
    defer first.free(gpa);
    try std.testing.expectEqual(@as(u32, 3), first.notification);
    try std.testing.expectEqualStrings("https://chat.example", first.origin);
    // 다른 탭(8)의 이름으로 누르거나 모르는 번호로 누르면 무동작, 제 탭으로 누르면 sidecar 번호로 간다.
    clickWebNotification(gpa, 8, first.token);
    clickWebNotification(gpa, 7, first.token +% 12345);
    clickWebNotification(gpa, 7, first.token);
    var frames: [4]Message = undefined;
    try std.testing.expectEqual(@as(usize, 1), sentFrames(&frames));
    try std.testing.expectEqual(@as(u32, 3), frames[0].web_notification_click.notification);
    // sidecar 가 죽으면(`crashed` 가 부르는 그 정리) 옛 번호로는 누르지 못하고, 아직 내보내지 않은 알림도 사라진다(새
    // sidecar 의 같은 번호를 누르지 않게).
    const second = takeWebNotification(7).?;
    defer second.free(gpa);
    forgetSidecar(gpa);
    clickWebNotification(gpa, 7, first.token);
    clickWebNotification(gpa, 7, second.token);
    try std.testing.expectEqual(@as(usize, 1), sentFrames(&frames)); // 앞의 그 하나뿐 — 새로 나간 것이 없다
    try std.testing.expect(takeWebNotification(7) == null);
}

test "context menus wait for a window, are answered exactly once, and a menu nobody picks up or that has no items is cancelled (W6c②)" {
    const gpa = std.testing.allocator;
    state = .starting;
    defer {
        for (surfaces.values()) |*s| freeSurface(gpa, s);
        surfaces.deinit(gpa);
        surfaces = .empty;
        outbox_pending.deinit(gpa);
        outbox_pending = .empty;
        state = .off;
    }
    try surfaces.put(gpa, 7, .{ .record = .{ .surface_id = 7, .size = .{ .width = 10, .height = 10, .scale = 1 }, .hidden = false }, .created = true });
    var frames: [8]Message = undefined;
    // 오면 기다린다 — 답은 아직 없다. 창이 가져가 고르면 그 명령이 한 번 간다(두 번째 답은 무동작).
    apply(gpa, .{ .context_menu = .{ .browser = 7, .menu = 4, .point = .{ .x = 1, .y = 2 }, .flags = .{ .editable = true, .can_select_all = true } } }, 0);
    try std.testing.expectEqual(@as(usize, 0), sentFrames(&frames));
    const taken = takeContextMenu(7).?;
    try std.testing.expectEqual(@as(u32, 4), taken.menu);
    try std.testing.expect(takeContextMenu(7) == null); // 한 창만
    try std.testing.expect(contextMenuOpen(7, 4));
    answerContextMenu(gpa, 7, 4, .select_all);
    answerContextMenu(gpa, 7, 4, .cancel);
    try std.testing.expectEqual(@as(usize, 1), sentFrames(&frames));
    try std.testing.expectEqual(ws.message.ContextMenuCommandKind.select_all, frames[0].context_menu_command.command);
    // 띄운 뒤 sidecar 가 닫으면 열려 있지 않고, 그 뒤 답은 보내지 않는다.
    apply(gpa, .{ .context_menu = .{ .browser = 7, .menu = 5, .point = .{ .x = 1, .y = 2 }, .flags = .{} } }, 0);
    _ = takeContextMenu(7).?;
    apply(gpa, .{ .context_menu_closed = .{ .browser = 7, .menu = 5 } }, 0);
    try std.testing.expect(!contextMenuOpen(7, 5));
    answerContextMenu(gpa, 7, 5, .reload);
    try std.testing.expectEqual(@as(usize, 1), sentFrames(&frames));
    // 아무 창도 가져가지 않으면 2 초 뒤 취소, 항목이 없으면(동영상 자리) 곧바로 취소, 모르는 탭도 곧바로 취소.
    apply(gpa, .{ .context_menu = .{ .browser = 7, .menu = 6, .point = .{ .x = 1, .y = 2 }, .flags = .{ .selection = true, .can_copy = true }, .selection = "글" } }, 1_000);
    try std.testing.expectEqualStrings("글", contextMenuSelection(7, 6));
    expireContextMenus(gpa, 2_500);
    try std.testing.expectEqual(@as(usize, 1), sentFrames(&frames));
    expireContextMenus(gpa, 3_100);
    try std.testing.expectEqual(@as(usize, 2), sentFrames(&frames));
    try std.testing.expectEqual(ws.message.ContextMenuCommandKind.cancel, frames[1].context_menu_command.command);
    apply(gpa, .{ .context_menu = .{ .browser = 7, .menu = 7, .point = .{ .x = 1, .y = 2 }, .flags = .{ .media = true } } }, 0);
    apply(gpa, .{ .context_menu = .{ .browser = 99, .menu = 8, .point = .{ .x = 1, .y = 2 }, .flags = .{} } }, 0);
    try std.testing.expectEqual(@as(usize, 4), sentFrames(&frames));
    try std.testing.expectEqual(@as(u32, 7), frames[2].context_menu_command.menu);
    try std.testing.expectEqual(@as(u32, 8), frames[3].context_menu_command.menu);
    try std.testing.expect(takeContextMenu(7) == null);
    // 아직 안 띄운 메뉴를 sidecar 가 닫으면 지운다(답 없음).
    apply(gpa, .{ .context_menu = .{ .browser = 7, .menu = 9, .point = .{ .x = 1, .y = 2 }, .flags = .{} } }, 0);
    apply(gpa, .{ .context_menu_closed = .{ .browser = 7, .menu = 9 } }, 0);
    try std.testing.expect(takeContextMenu(7) == null);
    try std.testing.expectEqual(@as(usize, 4), sentFrames(&frames));
    // 아직 안 띄운 메뉴는 열려 있지 않고 답도 가지 않는다 — sidecar 를 다시 띄운 뒤 같은 번호가 오면 옛 NSMenu 를 거둬야 한다.
    apply(gpa, .{ .context_menu = .{ .browser = 7, .menu = 10, .point = .{ .x = 1, .y = 2 }, .flags = .{} } }, 0);
    try std.testing.expect(!contextMenuOpen(7, 10));
    answerContextMenu(gpa, 7, 10, .reload);
    try std.testing.expectEqual(@as(usize, 4), sentFrames(&frames));
    _ = takeContextMenu(7).?;
    try std.testing.expect(contextMenuOpen(7, 10));
}

test "drags send their pieces before enter, split long text at character boundaries, drop bad paths, and are forgotten when the sidecar or browser goes (W6d①)" {
    const gpa = std.testing.allocator;
    state = .starting;
    defer {
        for (surfaces.values()) |*s| freeSurface(gpa, s);
        surfaces.deinit(gpa);
        surfaces = .empty;
        outbox_pending.deinit(gpa);
        outbox_pending = .empty;
        state = .off;
    }
    try surfaces.put(gpa, 7, .{ .record = .{ .surface_id = 7, .size = .{ .width = 10, .height = 10, .scale = 1 }, .hidden = false } });
    var frames: [32]Message = undefined;
    const at: ws.message.Point = .{ .x = 3, .y = 4 };
    // 아직 만들어지지 않은 탭은 받지 않는다.
    try std.testing.expect(!dragEnter(gpa, 7, .{ .paths = &.{"/a"} }, at, .{}, 1));
    surfaces.getPtr(7).?.created = true;
    // 상대·제어 문자 경로는 빠지고, 글은 조각마다 상한 안·글자 경계(3 바이트 「가」)로 나뉘며 제어 문자는 공백이 된다.
    const long = "가" ** (ws.wire.max_ime_text_bytes / 3 + 1);
    try std.testing.expect(dragEnter(gpa, 7, .{ .paths = &.{ "/ok", "rel", "/bad\nname" }, .text = long ++ "\x07끝", .url = "https://a.b/", .url_title = "제목\x1b" }, at, .{}, 0xFF));
    const n = sentFrames(&frames);
    try std.testing.expectEqual(@as(usize, 6), n);
    try std.testing.expectEqualStrings("/ok", frames[0].drag_data.bytes);
    try std.testing.expectEqual(ws.message.DragDataKind.text, frames[1].drag_data.kind);
    try std.testing.expect(frames[1].drag_data.bytes.len <= ws.wire.max_ime_text_bytes and frames[1].drag_data.bytes.len % 3 == 0);
    try std.testing.expect(std.mem.endsWith(u8, frames[2].drag_data.bytes, "가 끝"));
    try std.testing.expectEqual(long.len + 4, frames[1].drag_data.bytes.len + frames[2].drag_data.bytes.len);
    try std.testing.expectEqualStrings("https://a.b/", frames[3].drag_data.bytes);
    try std.testing.expectEqualStrings("제목 ", frames[4].drag_data.bytes);
    try std.testing.expectEqual(ws.message.DragTargetKind.enter, frames[5].drag_target.kind);
    try std.testing.expectEqual(ws.message.drag_operation_mask, frames[5].drag_target.allowed); // 쓰지 않는 비트는 떼고 보낸다
    // 페이지가 알린 동작은 그 끌기에만 — 놓으면 drop 이 가고 더는 over·drop 을 보내지 않는다.
    apply(gpa, .{ .drag_operation = .{ .browser = 7, .operation = 1 } }, 0);
    try std.testing.expectEqual(@as(u32, 1), dragOperation(7));
    dragOver(gpa, 7, at, .{}, 1);
    try std.testing.expect(dragDrop(gpa, 7, at, .{}));
    try std.testing.expect(!dragDrop(gpa, 7, at, .{}));
    dragOver(gpa, 7, at, .{}, 1);
    try std.testing.expectEqual(@as(u32, 0), dragOperation(7));
    try std.testing.expectEqual(@as(usize, 8), sentFrames(&frames));
    try std.testing.expectEqual(ws.message.DragTargetKind.over, frames[6].drag_target.kind);
    try std.testing.expectEqual(ws.message.DragTargetKind.drop, frames[7].drag_target.kind);
    // enter 뒤 렌더러가 죽으면 잊는다(sidecar 도 잊었다 — 옛 동작을 돌려주거나 놓기를 받았다고 하지 않게), sidecar 가 다시
    // 떠도, 브라우저가 닫혀도.
    try std.testing.expect(dragEnter(gpa, 7, .{}, at, .{}, 1));
    apply(gpa, .{ .drag_operation = .{ .browser = 7, .operation = 1 } }, 0);
    apply(gpa, .{ .renderer_gone = .{ .browser = 7, .reason = .crashed } }, 0);
    try std.testing.expect(!dragEntered(7));
    try std.testing.expectEqual(@as(u32, 0), dragOperation(7));
    try std.testing.expect(!dragDrop(gpa, 7, at, .{}));
    try std.testing.expect(dragEnter(gpa, 7, .{}, at, .{}, 1));
    forgetSidecar(gpa);
    try std.testing.expect(!dragDrop(gpa, 7, at, .{}));
    dragLeave(gpa, 7);
    try std.testing.expect(dragEnter(gpa, 7, .{}, at, .{}, 1));
    apply(gpa, .{ .browser_closed = 7 }, 0);
    try std.testing.expect(!dragDrop(gpa, 7, at, .{}));
    try std.testing.expectEqual(@as(usize, 11), sentFrames(&frames)); // enter 세 번뿐
}

test "page drags gather their pieces, are taken by one window, answered once with an allowed operation, expire when nobody takes them, and are dropped when the sidecar goes (W6d②)" {
    const gpa = std.testing.allocator;
    state = .starting;
    defer {
        for (surfaces.values()) |*s| freeSurface(gpa, s);
        surfaces.deinit(gpa);
        surfaces = .empty;
        outbox_pending.deinit(gpa);
        outbox_pending = .empty;
        state = .off;
    }
    try surfaces.put(gpa, 7, .{ .record = .{ .surface_id = 7, .size = .{ .width = 10, .height = 10, .scale = 1 }, .hidden = false }, .created = true });
    var frames: [16]Message = undefined;
    // 조각만 온 끌기는 아직 가져갈 수 없다. 글은 이어 붙고, 주소는 마지막 것.
    apply(gpa, .{ .drag_out_data = .{ .browser = 7, .drag = 3, .kind = .text, .bytes = "ab" } }, 0);
    apply(gpa, .{ .drag_out_data = .{ .browser = 7, .drag = 3, .kind = .text, .bytes = "c" } }, 0);
    apply(gpa, .{ .drag_out_data = .{ .browser = 7, .drag = 3, .kind = .url, .bytes = "https://x/" } }, 0);
    apply(gpa, .{ .drag_out_data = .{ .browser = 7, .drag = 3, .kind = .url, .bytes = "https://y/" } }, 0);
    try std.testing.expect(takeDragOut(7) == null);
    apply(gpa, .{ .drag_out = .{ .browser = 7, .drag = 3, .allowed = 1 | 16, .point = .{ .x = 4, .y = 5 } } }, 100);
    try std.testing.expect(!dragOutAlive(3)); // 아직 아무 창도 안 가져갔다
    // `drag_out` 뒤 조각은 쓰지 않는다.
    apply(gpa, .{ .drag_out_data = .{ .browser = 7, .drag = 3, .kind = .text, .bytes = "late" } }, 0);
    const taken = takeDragOut(7).?;
    try std.testing.expectEqualStrings("abc", taken.text.items);
    try std.testing.expectEqualStrings("https://y/", taken.url.items);
    try std.testing.expect(takeDragOut(7) == null); // 한 창만
    try std.testing.expect(dragOutAlive(3) and !dragOutAlive(4) and !dragOutAlive(0));
    // 가져간 끌기는 만료되지 않는다. 답은 허용 동작 안의 하나로, 한 번만.
    expireDragOuts(gpa, 100 + drag_out_pickup_ms + 1);
    try std.testing.expectEqual(@as(usize, 0), sentFrames(&frames));
    try std.testing.expect(endDragOut(gpa, 7, 3, .{ .x = 1, .y = 2 }, 2 | 16));
    try std.testing.expect(!endDragOut(gpa, 7, 3, .{ .x = 1, .y = 2 }, 1));
    try std.testing.expect(!dragOutAlive(3)); // 끝난 끌기 — maru 안 놓기는 pasteboard 로
    try std.testing.expectEqual(@as(usize, 1), sentFrames(&frames));
    try std.testing.expectEqual(@as(u32, 16), frames[0].drag_source_end.operation); // 링크(2)는 허용 밖이라 빠진다
    // 아무 창도 가져가지 않으면 시작 자리·취소로 답한다.
    apply(gpa, .{ .drag_out = .{ .browser = 7, .drag = 4, .allowed = 1, .point = .{ .x = 9, .y = 8 } } }, 1_000);
    expireDragOuts(gpa, 1_000 + drag_out_pickup_ms);
    try std.testing.expectEqual(@as(usize, 1), sentFrames(&frames));
    expireDragOuts(gpa, 1_000 + drag_out_pickup_ms + 1);
    try std.testing.expectEqual(@as(usize, 2), sentFrames(&frames));
    try std.testing.expectEqual(@as(u32, 0), frames[1].drag_source_end.operation);
    try std.testing.expectEqual(@as(i32, 9), frames[1].drag_source_end.point.x);
    // 새 번호의 조각은 앞 끌기를 버린다(sidecar 가 끝냈다 — 답하지 않는다). sidecar 가 다시 뜨거나 브라우저가 닫히면 버린다.
    apply(gpa, .{ .drag_out = .{ .browser = 7, .drag = 5, .allowed = 1, .point = .{ .x = 0, .y = 0 } } }, 2_000);
    apply(gpa, .{ .drag_out_data = .{ .browser = 7, .drag = 6, .kind = .text, .bytes = "n" } }, 2_000);
    try std.testing.expect(!endDragOut(gpa, 7, 5, .{ .x = 0, .y = 0 }, 1));
    apply(gpa, .{ .drag_out = .{ .browser = 7, .drag = 6, .allowed = 1, .point = .{ .x = 0, .y = 0 } } }, 2_000);
    forgetSidecar(gpa);
    try std.testing.expect(takeDragOut(7) == null);
    apply(gpa, .{ .drag_out = .{ .browser = 7, .drag = 7, .allowed = 1, .point = .{ .x = 0, .y = 0 } } }, 3_000);
    apply(gpa, .{ .browser_closed = 7 }, 3_000);
    expireDragOuts(gpa, 9_000);
    try std.testing.expectEqual(@as(usize, 2), sentFrames(&frames)); // 버린 것에는 답하지 않는다
}

test "new tabs a page opens queue per tab in order, only for http(s), one per user input maru sent, at most four, and expire unpicked (W6e)" {
    const gpa = std.testing.allocator;
    state = .starting;
    defer {
        for (surfaces.values()) |*s| freeSurface(gpa, s);
        surfaces.deinit(gpa);
        surfaces = .empty;
        outbox_pending.deinit(gpa);
        outbox_pending = .empty;
        state = .off;
    }
    try surfaces.put(gpa, 7, .{ .record = .{ .surface_id = 7, .size = .{ .width = 10, .height = 10, .scale = 1 }, .hidden = false }, .created = true });
    try std.testing.expect(!newTabPending(7));
    const s7 = surfaces.getPtr(7).?;
    // maru 가 이 탭에 사용자 입력을 보내지 않았으면 sidecar 가 보낸 새 탭도 받지 않는다.
    apply(gpa, .{ .open_tab = .{ .browser = 7, .placement = .foreground, .url = "https://a.example/0" } }, 0);
    try std.testing.expect(!newTabPending(7));
    state = .running;
    try std.testing.expect(sendInput(gpa, .{ .mouse = .{ .browser = 7, .kind = .move, .point = .{ .x = 1, .y = 1 } } }));
    try std.testing.expect(sendInput(gpa, .{ .key = .{ .browser = 7, .kind = .raw_down, .windows_key_code = 0, .native_key_code = 0x35, .character = 0x1b, .unmodified_character = 0x1b } })); // maru 의 Esc(macOS 코드만)
    try std.testing.expect(!s7.new_tab_credits.any()); // 이동·Esc 는 사용자 활성화가 아니다
    try std.testing.expect(sendInput(gpa, .{ .mouse = .{ .browser = 7, .kind = .down, .point = .{ .x = 1, .y = 1 }, .click_count = 1 } }));
    try std.testing.expect(s7.new_tab_credits.any());
    apply(gpa, .{ .open_tab = .{ .browser = 7, .placement = .foreground, .url = "https://a.example/1" } }, 0);
    apply(gpa, .{ .open_tab = .{ .browser = 9, .placement = .foreground, .url = "https://a.example/x" } }, 0); // 모르는 탭
    // maru 가 다시 거른다 — sidecar 가 걸렀어도.
    apply(gpa, .{ .open_tab = .{ .browser = 7, .placement = .foreground, .url = "https://a.example/again" } }, 0); // 장을 썼다
    s7.new_tab_credits.grant(0);
    apply(gpa, .{ .open_tab = .{ .browser = 7, .placement = .foreground, .url = "about:blank" } }, 0);
    apply(gpa, .{ .open_tab = .{ .browser = 7, .placement = .foreground, .url = "file:///etc/hosts" } }, 0);
    try std.testing.expect(s7.new_tab_credits.any()); // 거른 주소는 장을 쓰지 않는다
    try std.testing.expect(sendInput(gpa, .{ .key = .{ .browser = 7, .kind = .raw_down, .windows_key_code = 'A', .native_key_code = 0, .character = 'a', .unmodified_character = 'a' } }));
    apply(gpa, .{ .open_tab = .{ .browser = 7, .placement = .background, .url = "http://b.example/2" } }, 10);
    try std.testing.expect(newTabPending(7));
    try std.testing.expect(!newTabPending(9));
    var first = takeNewTab(7).?;
    try std.testing.expectEqualStrings("https://a.example/1", first.url);
    try std.testing.expectEqual(ws.message.NewTabPlacement.foreground, first.placement);
    gpa.free(first.url);
    first = takeNewTab(7).?;
    try std.testing.expectEqualStrings("http://b.example/2", first.url);
    try std.testing.expectEqual(ws.message.NewTabPlacement.background, first.placement);
    gpa.free(first.url);
    try std.testing.expect(takeNewTab(7) == null);
    // 넷까지만 쥔다.
    for (0..6) |_| {
        s7.new_tab_credits.grant(100);
        apply(gpa, .{ .open_tab = .{ .browser = 7, .placement = .background, .url = "https://c.example/" } }, 100);
    }
    try std.testing.expectEqual(@as(usize, max_new_tabs), surfaces.getPtr(7).?.new_tabs.items.len);
    // 아무 창도 꺼내 가지 않으면 버린다(새로 온 것은 남는다).
    s7.new_tab_credits.grant(5_100);
    apply(gpa, .{ .open_tab = .{ .browser = 7, .placement = .background, .url = "https://d.example/" } }, 5_100);
    expireNewTabs(gpa, 100 + new_tab_pickup_ms);
    try std.testing.expectEqual(@as(usize, max_new_tabs), surfaces.getPtr(7).?.new_tabs.items.len);
    expireNewTabs(gpa, 101 + new_tab_pickup_ms);
    try std.testing.expectEqual(@as(usize, 0), surfaces.getPtr(7).?.new_tabs.items.len); // 넘친 d 는 처음부터 버렸다
    s7.new_tab_credits.grant(6_000);
    apply(gpa, .{ .open_tab = .{ .browser = 7, .placement = .background, .url = "https://e.example/" } }, 6_000);
    try std.testing.expect(newTabPending(7)); // 탭이 사라지면 freeSurface 가 놓는다(testing allocator 가 샌 것을 잡는다)
}

test "a new window opens only right after the menu's open-link-in-new-window answer, once; page input and the new-tab menu never admit one (W6h①)" {
    const gpa = std.testing.allocator;
    state = .starting;
    defer {
        for (surfaces.values()) |*s| freeSurface(gpa, s);
        surfaces.deinit(gpa);
        surfaces = .empty;
        outbox_pending.deinit(gpa);
        outbox_pending = .empty;
        state = .off;
    }
    try surfaces.put(gpa, 7, .{ .record = .{ .surface_id = 7, .size = .{ .width = 10, .height = 10, .scale = 1 }, .hidden = false }, .created = true });
    state = .running;
    const s7 = surfaces.getPtr(7).?;
    const now = monotonicNow();
    // 페이지 입력의 장으로는 새 창을 받지 않는다.
    try std.testing.expect(sendInput(gpa, .{ .mouse = .{ .browser = 7, .kind = .down, .point = .{ .x = 1, .y = 1 }, .click_count = 1 } }));
    apply(gpa, .{ .open_tab = .{ .browser = 7, .placement = .new_window, .url = "https://a.example/w0" } }, now);
    try std.testing.expect(!newTabPending(7));
    try std.testing.expect(s7.new_tab_credits.any()); // 새 창 자리는 새 탭 장을 쓰지 않는다
    // 메뉴를 받고 띄운 뒤 「새 창에서 링크 열기」로 답한다.
    const link: ws.message.ContextMenuFlags = .{ .link = true, .link_openable = true };
    apply(gpa, .{ .context_menu = .{ .browser = 7, .menu = 3, .point = .{ .x = 1, .y = 1 }, .flags = link } }, now);
    try std.testing.expect(takeContextMenu(7) != null);
    answerContextMenu(gpa, 7, 3, .open_link_new_window);
    try std.testing.expect(s7.new_window_credit_ms != 0);
    apply(gpa, .{ .open_tab = .{ .browser = 7, .placement = .new_window, .url = "file:///etc/hosts" } }, monotonicNow()); // 거른 주소는 장을 쓰지 않는다
    try std.testing.expect(s7.new_window_credit_ms != 0);
    apply(gpa, .{ .open_tab = .{ .browser = 7, .placement = .new_window, .url = "https://a.example/w1" } }, monotonicNow());
    apply(gpa, .{ .open_tab = .{ .browser = 7, .placement = .new_window, .url = "https://a.example/w2" } }, monotonicNow()); // 한 번만
    var got = takeNewTab(7).?;
    try std.testing.expectEqualStrings("https://a.example/w1", got.url);
    try std.testing.expectEqual(ws.message.NewTabPlacement.new_window, got.placement);
    gpa.free(got.url);
    // 새 탭 장 하나는 아직 남았다(새 창이 쓰지 않았다) — 그것을 쓰고 비운다.
    apply(gpa, .{ .open_tab = .{ .browser = 7, .placement = .foreground, .url = "https://a.example/t" } }, monotonicNow());
    got = takeNewTab(7).?;
    gpa.free(got.url);
    try std.testing.expect(!newTabPending(7));
    // 메뉴 「새 탭에서 링크 열기」 답은 새 탭 장이지 새 창 장이 아니다. 오래된 새 창 장은 쓰지 못한다.
    apply(gpa, .{ .context_menu = .{ .browser = 7, .menu = 4, .point = .{ .x = 1, .y = 1 }, .flags = link } }, now);
    _ = takeContextMenu(7);
    answerContextMenu(gpa, 7, 4, .open_link_new_tab);
    apply(gpa, .{ .open_tab = .{ .browser = 7, .placement = .new_window, .url = "https://a.example/w3" } }, monotonicNow());
    try std.testing.expect(!newTabPending(7));
    s7.new_window_credit_ms = 1;
    apply(gpa, .{ .open_tab = .{ .browser = 7, .placement = .new_window, .url = "https://a.example/w4" } }, 1 + ws.new_tab.activation_ms + 1);
    try std.testing.expect(!newTabPending(7));
    // 닫힌 메뉴(sidecar 가 이미 닫았다)의 답은 장을 주지 않는다.
    s7.new_window_credit_ms = 0;
    apply(gpa, .{ .context_menu = .{ .browser = 7, .menu = 6, .point = .{ .x = 1, .y = 1 }, .flags = link } }, now);
    _ = takeContextMenu(7);
    apply(gpa, .{ .context_menu_closed = .{ .browser = 7, .menu = 6 } }, now);
    answerContextMenu(gpa, 7, 6, .open_link_new_window);
    try std.testing.expectEqual(@as(i64, 0), s7.new_window_credit_ms);
    // W6h②: 「새 탭에서 동영상 열기」 답도 새 탭 장을 주고, 그 메뉴가 열 수 없다고 보인 것(표지 꺼짐)에는 주지 않는다(심층 방어).
    s7.new_tab_credits = .{};
    apply(gpa, .{ .context_menu = .{ .browser = 7, .menu = 7, .point = .{ .x = 1, .y = 1 }, .flags = .{ .media = true, .media_video = true, .media_openable = true } } }, now);
    _ = takeContextMenu(7);
    answerContextMenu(gpa, 7, 7, .open_media_new_tab);
    try std.testing.expect(s7.new_tab_credits.any());
    s7.new_tab_credits = .{};
    apply(gpa, .{ .context_menu = .{ .browser = 7, .menu = 8, .point = .{ .x = 1, .y = 1 }, .flags = .{ .media = true, .media_video = true } } }, now);
    _ = takeContextMenu(7);
    answerContextMenu(gpa, 7, 8, .open_media_new_tab);
    try std.testing.expect(!s7.new_tab_credits.any());
    // 메뉴 「새 탭에서 이미지 열기」 답도 새 탭 장을 준다.
    s7.new_tab_credits = .{};
    apply(gpa, .{ .context_menu = .{ .browser = 7, .menu = 5, .point = .{ .x = 1, .y = 1 }, .flags = .{ .image = true, .image_openable = true } } }, now);
    _ = takeContextMenu(7);
    answerContextMenu(gpa, 7, 5, .open_image_new_tab);
    try std.testing.expect(s7.new_tab_credits.any());
    // 검색 탭은 maru 가 넣는다 — 장 없이, 앞 탭, 새 탭 주소 규칙대로.
    s7.new_tab_credits = .{};
    try std.testing.expect(queueSearchTab(gpa, 7, "https://www.google.com/search?q=a"));
    try std.testing.expect(!queueSearchTab(gpa, 7, "javascript:alert(1)"));
    try std.testing.expect(!queueSearchTab(gpa, 9, "https://www.google.com/search?q=a"));
    got = takeNewTab(7).?;
    try std.testing.expectEqual(ws.message.NewTabPlacement.foreground, got.placement);
    try std.testing.expectEqualStrings("https://www.google.com/search?q=a", got.url);
    gpa.free(got.url);
}

test "popups the sidecar made with a reserved id are adopted as tabs of their opener, or closed when they cannot be (W6f②)" {
    const gpa = std.testing.allocator;
    // `.starting` — 보내는 것이 outbox 에 남아 frame 으로 본다.
    state = .starting;
    defer {
        for (surfaces.values()) |*s| freeSurface(gpa, s);
        surfaces.deinit(gpa);
        surfaces = .empty;
        orphan_popups.deinit(gpa);
        orphan_popups = .empty;
        popup_reserved_len = 0;
        outbox_pending.clearAndFree(gpa);
        state = .off;
    }
    const Frames = struct {
        buf: [64]Message = undefined,
        seen: usize = 0,
        /// 지난번 뒤로 새로 보낸 frame 들.
        fn fresh(self: *@This()) []const Message {
            const n = sentFrames(&self.buf);
            defer self.seen = n;
            return self.buf[self.seen..n];
        }
    };
    var f: Frames = .{};
    try surfaces.put(gpa, 7, .{ .record = .{ .surface_id = 7, .size = .{ .width = 300, .height = 200, .scale = 2 }, .hidden = false }, .created = true });
    reservePopupId(gpa, 100);
    reservePopupId(gpa, 101);
    var out = f.fresh();
    try std.testing.expectEqual(@as(usize, 2), out.len);
    try std.testing.expectEqual(@as(u64, 101), out[1].popup_reserve.browser);
    // 맡기지 않은 번호 — 붙이지 않고 그 번호만 닫는다. 이미 있는 탭의 번호면 닫지도 않는다(고장 난 sidecar 가 남의 탭을 닫지 못하게).
    apply(gpa, .{ .popup_created = .{ .opener = 7, .browser = 555, .placement = .foreground, .url = "https://a.example/" } }, 0);
    apply(gpa, .{ .popup_created = .{ .opener = 555, .browser = 7, .placement = .foreground, .url = "https://a.example/" } }, 0);
    out = f.fresh();
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqual(@as(u64, 555), out[0].destroy_browser);
    try std.testing.expect(surfaces.getPtr(7).?.created and !newTabPending(7));
    // 연 탭에 사용자 입력을 보내지 않았다 — 닫는다(그 번호는 쓰였다).
    apply(gpa, .{ .popup_created = .{ .opener = 7, .browser = 100, .placement = .foreground, .url = "https://a.example/" } }, 0);
    out = f.fresh();
    try std.testing.expect(out.len == 1 and out[0].destroy_browser == 100 and !surfaces.contains(100));
    // 누른 뒤 — 「만들어짐」 기록과 연 탭의 줄. 크기는 연 탭의 것으로 맞춘다(resize). 주소창은 미리 채우지 않는다(위조 — 4 차).
    surfaces.getPtr(7).?.new_tab_credits.grant(0);
    apply(gpa, .{ .popup_created = .{ .opener = 7, .browser = 101, .placement = .background, .url = "https://bank.example/login" } }, 0);
    out = f.fresh();
    try std.testing.expect(out.len == 1 and out[0].resize.browser == 101 and out[0].resize.size.scale == 2);
    const p = surfaces.getPtr(101).?;
    try std.testing.expect(p.created and p.popup_opener == 7 and p.url == null and !p.nav_dirty);
    try std.testing.expect(takeNavUpdate(101) == null);
    try std.testing.expectEqualStrings("https://bank.example/login", p.last_url.?);
    const taken = takeNewTab(7).?;
    try std.testing.expectEqual(@as(u64, 101), taken.adopt);
    try std.testing.expectEqual(ws.message.NewTabPlacement.background, taken.placement);
    gpa.free(taken.url);
    // 붙은 뒤 페이지가 닫았다 — 그 브라우저로 더 보내지 않고, 창이 한 번 꺼내 간다.
    apply(gpa, .{ .browser_closed = 101 }, 0);
    state = .running;
    try std.testing.expect(!sendInput(gpa, .{ .mouse = .{ .browser = 101, .kind = .down, .point = .{ .x = 1, .y = 1 }, .click_count = 1 } }));
    state = .starting;
    try std.testing.expect(takePageClosed(101) and !takePageClosed(101));
    // 유일한 탭이라 남기면 그 번호로 빈 보통 탭을 새로 만든다 — 처음 주소로 되살아나지 않고, 옛 연 탭을 잊는다.
    revivePageClosed(gpa, 101);
    const r = surfaces.getPtr(101).?;
    try std.testing.expect(!r.created and r.popup_opener == 0 and !r.page_closed);
    try std.testing.expectEqualStrings("about:blank", r.last_url.?);
    out = f.fresh();
    try std.testing.expect(out.len == 1 and out[0].create_browser.browser == 101);
    // 붙기 전에 닫혔다 — 줄에서 빼고 기록을 지운다.
    reservePopupId(gpa, 102);
    surfaces.getPtr(7).?.new_tab_credits.grant(0);
    apply(gpa, .{ .popup_created = .{ .opener = 7, .browser = 102, .placement = .foreground, .url = "https://a.example/b" } }, 0);
    try std.testing.expect(newTabPending(7));
    apply(gpa, .{ .browser_closed = 102 }, 0);
    try std.testing.expect(!newTabPending(7));
    closeOrphanPopups(gpa);
    try std.testing.expect(!surfaces.contains(102));
    // 아무 창도 붙이지 않으면 만료 — 닫는다.
    reservePopupId(gpa, 103);
    surfaces.getPtr(7).?.new_tab_credits.grant(0);
    apply(gpa, .{ .popup_created = .{ .opener = 7, .browser = 103, .placement = .foreground, .url = "https://a.example/c" } }, 0);
    expireNewTabs(gpa, new_tab_pickup_ms + 1);
    closeOrphanPopups(gpa);
    try std.testing.expect(!surfaces.contains(103) and !newTabPending(7));
    _ = f.fresh();
    // 장은 5 초(+ 전달 1 초) — 지난 장으로는 붙이지 않는다.
    reservePopupId(gpa, 109);
    surfaces.getPtr(7).?.new_tab_credits.grant(0);
    apply(gpa, .{ .popup_created = .{ .opener = 7, .browser = 109, .placement = .foreground, .url = "https://a.example/d" } }, ws.new_tab.activation_ms + ws.new_tab.Credits.transit_ms + 1);
    out = f.fresh();
    try std.testing.expect(out.len == 2 and out[1].destroy_browser == 109 and !surfaces.contains(109));
    // sidecar 를 잃거나 내려도 맡긴 번호를 잊는다(retire 가 잊지 않아 그 뒤로 이어 받기가 꺼졌다 — 2 차).
    reservePopupId(gpa, 104);
    forgetSidecar(gpa);
    state = .running;
    try std.testing.expectEqual(@as(usize, 2), popupIdsWanted());
    reservePopupId(gpa, 107);
    retire(gpa, 0); // 프로세스가 없다 — 상태만 내린다
    state = .running;
    try std.testing.expectEqual(@as(usize, 2), popupIdsWanted());
    // 맡긴 번호의 등록 실패는 그 번호를 거둔다(sidecar 가 닫았다 — 보내지 않는다).
    state = .starting;
    reservePopupId(gpa, 106);
    _ = f.fresh();
    apply(gpa, .{ .failure = .{ .browser = 106, .code = .browser_create_failed, .detail = "popup not adopted" } }, 0);
    try std.testing.expectEqual(@as(usize, 0), popup_reserved_len);
    try std.testing.expectEqual(@as(usize, 0), f.fresh().len);
    // 이어 받지 않은 탭도 maru 가 닫지 않았는데 닫히면(스크립트가 닫을 수 있는 탭) 창이 닫는다 — 죽은 번호로 남지 않게(4 차).
    apply(gpa, .{ .browser_closed = 7 }, 0);
    try std.testing.expect(takePageClosed(7) and !surfaces.getPtr(7).?.created);
    // 연 탭이 사라지면 아직 붙지 않은 팝업도 닫는다.
    surfaces.getPtr(7).?.created = true;
    reservePopupId(gpa, 108);
    surfaces.getPtr(7).?.new_tab_credits.grant(0);
    apply(gpa, .{ .popup_created = .{ .opener = 7, .browser = 108, .placement = .foreground, .url = "https://a.example/e" } }, 0);
    try std.testing.expect(surfaces.contains(108));
    destroy(gpa, 7);
    closeOrphanPopups(gpa);
    try std.testing.expect(!surfaces.contains(108));
}

test "dragged image files are fetched only when asked, gathered apart from the drag, checked against the announced size, and failed when the sidecar or browser goes (W6d③)" {
    const gpa = std.testing.allocator;
    state = .starting;
    defer {
        for (surfaces.values()) |*s| freeSurface(gpa, s);
        surfaces.deinit(gpa);
        surfaces = .empty;
        outbox_pending.deinit(gpa);
        outbox_pending = .empty;
        dropFileFetch(gpa);
        file_source = null;
        state = .off;
    }
    try surfaces.put(gpa, 7, .{ .record = .{ .surface_id = 7, .size = .{ .width = 10, .height = 10, .scale = 1 }, .hidden = false }, .created = true });
    var frames: [8]Message = undefined;
    // 파일을 받아 둔 끌기 — 내용은 아직 오지 않는다. 청하기 전에는 아무것도 보내지 않는다.
    apply(gpa, .{ .drag_out_data = .{ .browser = 7, .drag = 3, .kind = .file_name, .bytes = "cat.png" } }, 0);
    apply(gpa, .{ .drag_out = .{ .browser = 7, .drag = 3, .allowed = 1, .point = .{ .x = 0, .y = 0 }, .file_size = 5 } }, 0);
    try std.testing.expectEqual(@as(u32, 5), surfaces.getPtr(7).?.drag_out.?.file_size);
    try std.testing.expect(!requestDragFile(gpa, 4)); // 다른 번호
    // 끌기가 끝난 뒤에도 청할 수 있다(Finder 는 놓은 뒤 청한다). 청하기는 한 번만 나간다.
    _ = takeDragOut(7);
    try std.testing.expect(endDragOut(gpa, 7, 3, .{ .x = 0, .y = 0 }, 1));
    const before = sentFrames(&frames);
    try std.testing.expect(requestDragFile(gpa, 3));
    try std.testing.expect(requestDragFile(gpa, 3)); // 이미 청했다 — 다시 보내지 않는다
    try std.testing.expectEqual(before + 1, sentFrames(&frames));
    try std.testing.expectEqual(@as(u32, 3), frames[before].drag_file_request.drag);
    try std.testing.expectEqual(FileFetchState.pending, dragFile(3).state);
    // 조각은 끌기가 아니라 청한 것에 모인다. 알린 크기와 맞아야 ready.
    apply(gpa, .{ .drag_out_data = .{ .browser = 7, .drag = 3, .kind = .file_contents, .bytes = "ab" } }, 0);
    apply(gpa, .{ .drag_out_data = .{ .browser = 7, .drag = 3, .kind = .file_contents, .bytes = "cde" } }, 0);
    apply(gpa, .{ .drag_file_ready = .{ .browser = 7, .drag = 3, .size = 5, .ok = true } }, 0);
    try std.testing.expectEqual(FileFetchState.ready, dragFile(3).state);
    try std.testing.expectEqualStrings("abcde", dragFile(3).bytes);
    releaseDragFile(gpa, 3);
    try std.testing.expectEqual(FileFetchState.failed, dragFile(3).state);
    // 크기가 모자라면·넘치면·sidecar 가 실패를 알리면 실패.
    try std.testing.expect(requestDragFile(gpa, 3));
    apply(gpa, .{ .drag_out_data = .{ .browser = 7, .drag = 3, .kind = .file_contents, .bytes = "ab" } }, 0);
    apply(gpa, .{ .drag_file_ready = .{ .browser = 7, .drag = 3, .size = 5, .ok = true } }, 0);
    try std.testing.expectEqual(FileFetchState.failed, dragFile(3).state);
    try std.testing.expect(requestDragFile(gpa, 3)); // 실패한 것은 다시 청할 수 있다
    apply(gpa, .{ .drag_out_data = .{ .browser = 7, .drag = 3, .kind = .file_contents, .bytes = "abcdef" } }, 0);
    try std.testing.expectEqual(FileFetchState.failed, dragFile(3).state); // 알린 크기보다 많다
    try std.testing.expect(requestDragFile(gpa, 3));
    apply(gpa, .{ .drag_file_ready = .{ .browser = 7, .drag = 3, .size = 0, .ok = false } }, 0);
    try std.testing.expectEqual(FileFetchState.failed, dragFile(3).state);
    // 다른 번호의 늦은 조각은 섞이지 않는다.
    try std.testing.expect(requestDragFile(gpa, 3));
    apply(gpa, .{ .drag_out_data = .{ .browser = 7, .drag = 2, .kind = .file_contents, .bytes = "zzzzz" } }, 0);
    try std.testing.expectEqual(@as(usize, 0), file_fetch.?.contents.items.len);
    // 브라우저가 닫히면·sidecar 가 다시 뜨면 실패하고 다시 청할 수 없다.
    apply(gpa, .{ .browser_closed = 7 }, 0);
    try std.testing.expectEqual(FileFetchState.failed, dragFile(3).state);
    try std.testing.expect(!requestDragFile(gpa, 3));
    surfaces.getPtr(7).?.created = true; // 닫힌 브라우저로는 청하지 않는다(W6f②) — 다시 만들어졌다고 둔다
    apply(gpa, .{ .drag_out = .{ .browser = 7, .drag = 5, .allowed = 1, .point = .{ .x = 0, .y = 0 }, .file_size = 5 } }, 0);
    try std.testing.expect(requestDragFile(gpa, 5));
    forgetSidecar(gpa);
    try std.testing.expectEqual(FileFetchState.failed, dragFile(5).state);
    try std.testing.expect(!requestDragFile(gpa, 5)); // 새 sidecar 는 그 파일을 모른다
}

test "file chooser answers: bad paths are dropped, a JS answer cannot close a file request, crash drops everything" {
    const gpa = std.testing.allocator;
    state = .starting;
    defer {
        for (surfaces.values()) |*s| freeSurface(gpa, s);
        surfaces.deinit(gpa);
        surfaces = .empty;
        outbox_pending.deinit(gpa);
        outbox_pending = .empty;
        state = .off;
    }
    try surfaces.put(gpa, 7, .{ .record = .{ .surface_id = 7, .size = .{ .width = 10, .height = 10, .scale = 1 }, .hidden = false }, .created = true });
    apply(gpa, .{ .file_dialog = .{ .browser = 7, .request = 5, .mode = .open_multiple, .accept = ".png" } }, 0);
    const file = nextDialog(7).?;
    try std.testing.expectEqualStrings(".png", file.accept);
    const token = file.token;
    fileDialogPath(gpa, 7, token, "relative/a.png"); // 절대 경로가 아니다 — 버린다
    fileDialogPath(gpa, 7, token, "/a\nb"); // 제어 문자 — 버린다
    fileDialogPath(gpa, 7, token, "/tmp/a.png");
    replyDialog(gpa, 7, token, true, "", false); // JS 답은 파일 요청을 닫지 못한다
    try std.testing.expect(dialogPending(7, token) != null);
    replyFileDialog(gpa, 7, token, true);
    try std.testing.expect(dialogPending(7, token) == null);
    var frames: [8]Message = undefined;
    const n = sentFrames(&frames);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("/tmp/a.png", frames[0].file_dialog_path.path);
    try std.testing.expect(frames[1].file_dialog_reply.accept);
    // sidecar 가 죽으면 기다리던 요청은 답 없이 사라진다(콜백이 없다).
    apply(gpa, .{ .js_dialog = .{ .browser = 7, .request = 6, .kind = .alert, .origin = "", .message = "" } }, 0);
    const dropped = nextDialog(7).?.token;
    forgetSidecar(gpa);
    try std.testing.expect(dialogPending(7, dropped) == null);
    try std.testing.expectEqual(@as(usize, 2), sentFrames(&frames));
    // 다시 뜬 sidecar 가 같은 요청 번호(6)로 새 요청을 보내도 옛 토큰의 답은 붙지 않는다.
    apply(gpa, .{ .js_dialog = .{ .browser = 7, .request = 6, .kind = .confirm, .origin = "", .message = "" } }, 0);
    replyDialog(gpa, 7, dropped, true, "", false);
    try std.testing.expect(nextDialog(7) != null);
    try std.testing.expectEqual(@as(usize, 2), sentFrames(&frames));
}

test "a prompt answer is trimmed to the dialog text rules instead of being dropped, and suppress rides along" {
    const gpa = std.testing.allocator;
    state = .starting;
    defer {
        for (surfaces.values()) |*s| freeSurface(gpa, s);
        surfaces.deinit(gpa);
        surfaces = .empty;
        outbox_pending.deinit(gpa);
        outbox_pending = .empty;
        state = .off;
    }
    try surfaces.put(gpa, 7, .{ .record = .{ .surface_id = 7, .size = .{ .width = 10, .height = 10, .scale = 1 }, .hidden = false }, .created = true });
    apply(gpa, .{ .js_dialog = .{ .browser = 7, .request = 1, .kind = .prompt, .origin = "", .message = "", .offer_suppress = true } }, 0);
    const d = nextDialog(7).?;
    try std.testing.expect(d.offer_suppress);
    const long = "가" ** 2000; // 6000 바이트 — 상한(4 KiB)을 넘는다
    replyDialog(gpa, 7, d.token, true, long ++ "\x1b", true);
    var frames: [2]Message = undefined;
    try std.testing.expectEqual(@as(usize, 1), sentFrames(&frames));
    const r = frames[0].dialog_reply;
    try std.testing.expect(r.accept and r.suppress);
    try std.testing.expect(r.text.len > 4000 and r.text.len <= ws.wire.max_text_bytes);
    try std.testing.expect(std.mem.startsWith(u8, r.text, "가가가"));
}
