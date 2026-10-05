//! 웹 OSR sidecar 제어 채널의 메시지 모양(W1a) — tag·방향·닫힌 enum·본문 구조체. 바이트 배치는 `codec.zig`.

const std = @import("std");

/// 0~31 은 maru → sidecar, 32~ 는 sidecar → maru. 받는 쪽은 `StreamingDecoder` 의 방향으로 거꾸로 온
/// frame 을 거절한다.
pub const Tag = enum(u8) {
    hello = 0,
    create_browser = 1,
    destroy_browser = 2,
    resize = 3,
    set_hidden = 4,
    set_focus = 5,
    navigate = 6,
    shutdown = 7,
    /// 픽셀 채널(W2): maru 가 연 mach 받는 port 의 bootstrap 이름과 비밀 토큰(C3). 이것으로만 건넨다.
    frame_channel = 8,
    /// 뒤로·앞으로·새로고침·멈춤(W3b — 주소창 버튼).
    nav_action = 9,
    /// 입력(W4 — C5). 좌표는 view 좌상단 기준 DIP 다(CEF 의 view 좌표). 라우팅(누구에게 보낼지)은 maru 가 정했다.
    mouse = 10,
    wheel = 11,
    key = 12,
    ime_set_composition = 13,
    ime_commit_text = 14,
    /// 조합 중인 글을 그대로 확정한다(키 대상이 바뀌는 모달 에지 — C5).
    ime_finish_composing = 15,
    ime_cancel_composition = 16,
    /// 주 프레임 편집 명령(⌘A/C/V/X/Z — 메뉴와 단축키).
    edit_command = 17,
    /// 제스처 주인이 바뀌었다 — 페이지가 잡은 마우스 capture 를 놓게 한다(모달 에지 — C5).
    capture_lost = 18,
    /// JS 대화상자의 답(W5a — C6). 요청 번호는 `js_dialog` 가 준 것이다.
    dialog_reply = 19,
    /// 파일 선택의 경로 하나(W5a). 여러 개면 여러 번 보내고 `file_dialog_reply` 로 끝낸다.
    file_dialog_path = 20,
    file_dialog_reply = 21,
    /// 권한 요청의 답(W5b — C6). 요청 번호는 `permission_request` 가 준 것이다.
    permission_reply = 22,
    /// 위치 요청에 줄 좌표(W5b2) — 허용으로 답하기 **전에** 보낸다. sidecar 는 그 브라우저에 DevTools 위치 덮어쓰기를 건다
    /// (Chromium 의 위치 공급자는 CEF 에서 돌지 않는다 — 실측).
    geolocation = 23,
    /// 사용자가 maru 알림(배너·목록)을 눌렀다(W5c) — sidecar 는 그 페이지 알림의 `click` 을 부른다(Chrome 과 같다).
    web_notification_click = 24,
    /// 우클릭 메뉴에서 고른 것(W6c — D5). 메뉴 번호는 `context_menu` 가 준 것이다. 고르지 않고 닫았으면 `cancel`.
    context_menu_command = 25,
    /// 밖에서 끌어 온 것의 한 조각(W6d① — 파일 경로·글·HTML·주소·주소 제목). `drag_target` 의 enter 앞에 보낸다 — sidecar 는
    /// 브라우저마다 쌓았다가 enter 에서 drag data 를 만든다. 글·HTML 은 글자 경계에서 나눠 여러 번 보내면 이어 붙인다.
    drag_data = 26,
    /// 끌기가 그 탭 본문에 들어왔다·움직였다·나갔다·놓였다(W6d① — CEF `drag_target_*`). 좌표는 view DIP, 허용 동작은 macOS 와
    /// CEF 가 같은 비트다(복사 1·링크 2·일반 4·개인 8·이동 16·삭제 32).
    drag_target = 27,
    /// 페이지에서 시작한 끌기(W6d② — `drag_out`)가 끝났다 — 놓인 자리(그 탭 view DIP)와 받은 동작(0 = 취소). sidecar 는
    /// CEF `drag_source_ended_at`·`drag_source_system_drag_ended` 를 부르고 쥔 끌기 데이터를 놓는다. 끌기 번호가 지금 끌기가 아니면 버린다.
    drag_source_end = 28,
    /// 끌어낸 이미지의 파일 내용을 청한다(W6d③ — Finder 가 놓은 뒤 파일을 청할 때만). sidecar 는 끌기 시작 때 받아 둔 그 번호의 내용을
    /// `drag_out_data`(파일 내용) 조각으로 보내고 `drag_file_ready` 로 끝낸다.
    drag_file_request = 29,
    /// 팝업 브라우저에 쓸 번호 하나를 맡긴다(W6f — maru 의 surface id, 아직 쓰지 않은 것). 페이지가 연 팝업을 sidecar 가 CEF 로 만들게
    /// 두고 이 번호로 등록한다 — 원래 페이지와 이어진다(`window.opener`·`postMessage`·이름 창·`close`). 맡긴 번호가 없으면 주소만
    /// 보낸다(`open_tab` — W6e). sidecar 는 `max_popup_reserve` 개까지 쥔다(넘치면 버린다).
    popup_reserve = 30,
    /// 사용자가 그 탭을 닫는다 — 페이지에 묻고 닫는다(W6j — 강제하지 않는 닫기). 떠나기 확인을 건 페이지면 `js_dialog`
    /// (`before_unload`)가 오고, 머무르기면 브라우저는 그대로다. 묻지 않는 페이지는 곧바로 닫힌다(`browser_closed`). maru 는 답이
    /// 없으면 `destroy_browser` 로 강제한다. maru → sidecar 의 마지막 번호다.
    close_asking = 31,

    hello_ack = 32,
    browser_created = 33,
    browser_closed = 34,
    title_changed = 35,
    load_finished = 36,
    renderer_gone = 37,
    failure = 38,
    /// 주 프레임의 주소가 바뀌었다(W3b — 주소창).
    url_changed = 39,
    /// 뒤로·앞으로 가능 여부와 로딩 중(W3b — 주소창 버튼).
    nav_state = 40,
    /// 페이지가 원하는 마우스 커서(W4).
    cursor_changed = 41,
    /// IME 조합 글자들이 차지한 사각형(view DIP) — 후보창 위치(`firstRect`, W4).
    ime_range = 42,
    /// 페이지가 JS 대화상자(`alert`·`confirm`·`prompt`·떠나기 확인)를 띄우려 한다(W5a — C6). 페이지는 답이 올 때까지 멈춘다.
    js_dialog = 43,
    /// 페이지가 파일 선택을 띄우려 한다(W5a — C6).
    file_dialog = 44,
    /// 그 요청은 더는 답을 받지 않는다 — 페이지가 이동했거나 닫혔다(CEF `on_reset_dialog_state`). maru 는 떠 있는 창을 닫는다.
    /// 권한 요청(W5b)도 같다(CEF `on_dismiss_permission_prompt`).
    dialog_closed = 45,
    /// 페이지가 권한(카메라·마이크·위치·알림 등)을 청한다(W5b — C6). 답이 올 때까지 페이지의 그 요청만 기다린다.
    permission_request = 46,
    /// 페이지가 웹 알림을 띄웠다(W5c — C6). Chromium 은 웹 알림을 OS 로 보내지 않으므로(실측) sidecar 의 대리 스크립트가 받아
    /// 넘긴다 — 그 출처가 알림을 허용했을 때만.
    web_notification = 47,
    /// 페이지의 팝업 위젯(`<select>` 목록·색 선택기 등)이 열렸다·닫혔다(W6a — D4). CEF 154 구현에서는 사각형을 열릴 때 한 번만
    /// 알린다(`InitAsPopup` — 헤더는 옮기거나 크기를 바꿀 때도 부른다고 적는다, 다시 와도 같은 첫 세대를 보낸다). 열리면 view DIP 사각형과 그 팝업 링의 첫 세대, 닫히면 0 사각형·0 세대.
    /// 팝업의 픽셀은 본 화면과 다른 링으로 온다(`ring_message.popup_message_id`).
    popup_changed = 48,
    /// 페이지의 툴팁 글이 바뀌었다(W6b — HTML `title`). 빈 글이면 툴팁이 없다. sidecar 는 연달아 같은 글을 보내지 않고(CEF 는
    /// 요소 안에서 움직일 때마다 같은 글을 다시 부른다 — 실측), 페이지를 새로 불러오기 시작할 때·주 프레임 이동이 실패해 오류 페이지가 될 때·포인터가 떠날 때 기억한 글을
    /// 비우며 비어 있지 않았으면 빈 글을 한 번 보낸다(같은 문서 안 주소 변경에는 비우지 않는다). 여러 줄은 `\n` 으로 온다(대화상자 글 규칙).
    tooltip_changed = 49,
    /// 페이지에서 우클릭했다(W6c — D5). 메뉴는 maru 가 macOS 메뉴로 띄운다 — CEF 의 기본 메뉴는 창 없는 모드에서 뜨지 않고 항목도
    /// 적다(착수 전 실측). maru 는 고른 것을 `context_menu_command` 로 답한다. 페이지가 `contextmenu` 를 막으면 오지 않는다.
    context_menu = 50,
    /// 그 메뉴가 끝났다 — 고른 명령을 마쳤거나, 페이지가 이동·닫혀 CEF 가 메뉴를 거뒀다(`on_context_menu_dismissed`). maru 는 떠
    /// 있는 메뉴를 닫는다. 메뉴마다 한 번.
    context_menu_closed = 51,
    /// 페이지가 받아들이는 끌기 동작이 바뀌었다(W6d① — CEF `update_drag_cursor`). 0 이면 놓아도 받지 않는다. maru 는 탭마다
    /// 마지막 값을 끌기 커서(`draggingUpdated`)로 돌려준다.
    drag_operation = 52,
    /// 페이지가 시작한 끌기의 한 조각(W6d② — 글·HTML·주소·주소 제목·끌기 그림 PNG). `drag_out` 앞에 보낸다 — 글·HTML·그림은
    /// 나눠 여러 번 오면 이어 붙인다.
    drag_out_data = 53,
    /// 페이지가 끌기를 시작했다(W6d② — CEF `start_dragging`). maru 는 아직 누르고 있으면 macOS 끌기 세션을 시작하고, 끝나면
    /// `drag_source_end` 로 답한다(떼기를 이미 했으면 곧바로 취소로). 끌기는 sidecar 에 하나 — 새 끌기가 오면 앞 끌기는 sidecar 가
    /// 취소로 끝냈다.
    drag_out = 54,
    /// 청한 파일 내용의 끝(W6d③) — 보낸 크기와 성공 여부. 그 번호의 내용이 없으면(다음 끌기가 시작됐다·브라우저가 닫혔다) 실패.
    drag_file_ready = 55,
    /// 페이지가 새 탭을 열려 한다(W6e — `target=_blank`·`window.open`·⌘/가운데 클릭·메뉴 「새 탭에서 링크 열기」). sidecar 는 CEF 의
    /// 팝업을 취소하고(창을 만들지 않는다) 주소만 보낸다 — maru 는 그 탭 오른쪽에 새 탭을 만든다. 원래 페이지와는 이어지지 않는다
    /// (`window.opener` 없음 — 이어 받기는 다음 단계). sidecar 는 사용자 입력 하나에 하나만 보낸다.
    open_tab = 56,
    /// 페이지가 연 팝업을 맡긴 번호(`browser`)로 만들었다(W6f). 그 브라우저는 이미 돌고 있다(`browser_created` 는 오지 않는다) —
    /// maru 는 연 탭(`opener`) 오른쪽에 그 번호의 탭을 붙이거나, 붙일 수 없으면 `destroy_browser` 로 닫는다(페이지에는 팝업이 닫힌
    /// 것으로 보인다). 주소는 처음 이동할 곳(빈 팝업은 `about:blank`).
    popup_created = 57,

    pub fn direction(self: Tag) Direction {
        return if (@intFromEnum(self) < 32) .to_sidecar else .to_maru;
    }
};

pub const Direction = enum { to_sidecar, to_maru };

pub const RendererGoneReason = enum(u8) {
    abnormal = 0,
    killed = 1,
    crashed = 2,
    out_of_memory = 3,
    launch_failed = 4,
    /// 코드 무결성 검사 실패(CEF TS_INTEGRITY_FAILURE).
    integrity_failure = 5,
};

pub const FailureCode = enum(u8) {
    /// 같은 프로필을 다른 프로세스가 쥐고 있다(CEF process singleton — §13.1 exit 24).
    profile_in_use = 0,
    cef_initialize_failed = 1,
    browser_create_failed = 2,
    unknown_browser = 3,
    duplicate_browser = 4,
    /// sidecar 가 maru 의 frame 을 풀지 못했다. 이 뒤 sidecar 는 채널을 닫는다.
    protocol_violation = 5,
    /// `frame_channel` 의 이름으로 port 를 못 찾았다(W2).
    frame_channel_failed = 6,
    /// GPU 경로(`on_accelerated_paint`)가 아니라 CPU 버퍼(`on_paint`)로 그렸다 — 이 브라우저는 그리지 않는다(D9 — 거부하고
    /// 안내). 실측으로는 `--disable-gpu` 에서도 GPU 경로였다(W3b 착수 전) — 드문 경우다.
    gpu_unavailable = 7,
};

pub const NavActionKind = enum(u8) {
    back = 0,
    forward = 1,
    reload = 2,
    stop = 3,
};

pub const BrowserId = u64;

/// 대화상자·파일 선택 요청 번호(W5a). sidecar 가 0 이 아닌 값으로 매긴다 — 답은 이 번호로 짝을 찾는다.
pub const RequestId = u32;

pub const JsDialogKind = enum(u8) {
    alert = 0,
    confirm = 1,
    prompt = 2,
    /// 떠나기 확인(`beforeunload`) — 답이 참이면 떠난다.
    before_unload = 3,
};

/// CEF `cef_file_dialog_mode_t` 와 같은 값.
pub const FileDialogMode = enum(u8) {
    open = 0,
    open_multiple = 1,
    open_folder = 2,
    save = 3,
};

/// 대화상자 글: 줄바꿈·탭은 받는다(`alert("a\nb")` 가 흔하다). 나머지 제어 문자는 sidecar 가 바꿔 보내고 받는 쪽은 거절한다.
pub const JsDialog = struct {
    browser: BrowserId,
    request: RequestId,
    kind: JsDialogKind,
    /// 요청한 쪽의 출처(`https://example.com:8080`) — 사용자가 누가 띄웠는지 알게(위장 방지). `scheme://host[:port]` 만 받는다
    /// (`fields.checkOrigin`) — 경로·사용자 정보(`https://apple.com@evil.test`)·불투명 출처(`data:`)는 빈 글로 온다.
    origin: []const u8,
    message: []const u8,
    /// `prompt` 의 기본 글. 다른 종류는 빈 글.
    default_text: []const u8 = "",
    /// 이 페이지가 이동 없이 두 번째 이상 띄우는 대화상자다 — maru 는 「이 페이지가 대화상자를 더 띄우지 못하게」를 보인다(Chrome
    /// 과 같다 — `while(1) alert()` 에서 빠져나갈 길).
    offer_suppress: bool = false,
};

pub const FileDialog = struct {
    browser: BrowserId,
    request: RequestId,
    mode: FileDialogMode,
    /// 페이지가 준 제목(대개 빈 글 — 기본 제목을 쓴다).
    title: []const u8 = "",
    /// 처음 고를 경로·이름(저장이면 파일 이름). 빈 글이면 없다.
    default_path: []const u8 = "",
    /// 받을 형식을 쉼표로 이은 것(`image/*,.png`). 빈 글이면 제한 없음.
    accept: []const u8 = "",
};

pub const Request = struct {
    browser: BrowserId,
    request: RequestId,
};

/// 권한 종류(W5b) — CEF `cef_permission_request_types_t` 와 **같은 비트**(0~28 — sidecar 의 comptime 이 CEF 를 올려 값이
/// 바뀌면 빌드를 멈춘다). 이 밖의 비트는 거절한다(닫힌 필드).
pub const permission_kind_mask: u32 = (1 << 29) - 1;
/// 미디어 권한(W5b) — CEF `cef_media_access_permission_types_t` 와 같은 비트: 소리 입력(마이크)·영상 입력(카메라)·화면 소리·
/// 화면.
pub const permission_media_mask: u8 = 0b1111;

pub const PermissionKind = enum(u5) {
    ar_session = 0,
    camera_pan_tilt_zoom = 1,
    camera = 2,
    captured_surface_control = 3,
    clipboard = 4,
    top_level_storage_access = 5,
    disk_quota = 6,
    local_fonts = 7,
    geolocation = 8,
    hand_tracking = 9,
    identity_provider = 10,
    idle_detection = 11,
    microphone = 12,
    midi_sysex = 13,
    multiple_downloads = 14,
    notifications = 15,
    keyboard_lock = 16,
    pointer_lock = 17,
    protected_media_identifier = 18,
    register_protocol_handler = 19,
    storage_access = 20,
    vr_session = 21,
    web_app_installation = 22,
    window_management = 23,
    file_system_access = 24,
    local_network_access = 25,
    local_network = 26,
    loopback_network = 27,
    sensors = 28,

    pub fn bit(self: PermissionKind) u32 {
        return @as(u32, 1) << @intFromEnum(self);
    }
};

pub const MediaPermission = enum(u2) {
    microphone = 0,
    camera = 1,
    screen_audio = 2,
    screen = 3,

    pub fn bit(self: MediaPermission) u8 {
        return @as(u8, 1) << @intFromEnum(self);
    }
};

/// CEF `cef_permission_request_result_t` 와 같은 값. 허용·차단은 Chromium 이 출처별로 기억한다(사용자 결정 2026-09-25).
/// 닫기(사용자가 고른 것)는 허용·차단으로 기억하지 않지만 셋이 쌓이면 Chromium 이 한동안 묻지 않고 막는다(embargo — W5b 실측).
/// `ignore` 는 maru 가 **묻지 못했다**(대기열이 참·탭이 사라짐·창이 닫힘·macOS 가 장치를 막음) — 사용자의 닫기 수에 섞이지 않게
/// 따로 둔다. Chromium 은 이것도 따로 센다 — 넷이면 그 종류를 한동안 묻지 않는다(판정자 `perm-ignore` 실측, Chrome 에서 묻는 중
/// 탭을 닫은 것과 같다). 미디어 요청은 어느 쪽도 세지 않는다.
pub const PermissionResult = enum(u8) {
    accept = 0,
    deny = 1,
    dismiss = 2,
    ignore = 3,
};

/// 한 요청은 `kinds`(프롬프트 — `on_show_permission_prompt`)와 `media`(카메라·마이크·화면 — `on_request_media_access_permission`)
/// 중 **하나만** 싣는다(둘 다 0 이거나 둘 다 있으면 거절). 한 요청에 종류가 여럿일 수 있다(카메라+마이크).
pub const PermissionRequest = struct {
    browser: BrowserId,
    request: RequestId,
    /// `js_dialog` 와 같은 규칙의 출처(빈 글이면 maru 는 「이 페이지」).
    origin: []const u8,
    kinds: u32 = 0,
    media: u8 = 0,
    /// W5b2: Chromium 이 이 출처의 위치를 허용으로 기억한다 — Chromium 은 위치를 부를 때마다 다시 묻는다. maru 는 이 표시를 믿지
    /// 않고, 자기 sheet 에서 그 탭이 허용받은 출처일 때만 sheet 없이 좌표를 구한다. 위치만 청한 요청에만 선다(그 밖이면 거절).
    remembered: bool = false,
};

/// 위치 요청의 좌표(W5b2). `available` 이 거짓이면 좌표는 모두 0 이고 페이지는 「위치를 알 수 없음」을 받는다.
/// 위도 -90~90, 경도 -180~180, 정확도(m)는 0 보다 크고 `max_geolocation_accuracy` 이하 — 그 밖(NaN·무한대 포함)은 거절한다.
pub const Geolocation = struct {
    browser: BrowserId,
    request: RequestId,
    available: bool,
    latitude: f64 = 0,
    longitude: f64 = 0,
    accuracy: f64 = 0,
};

pub const max_geolocation_accuracy: f64 = 10_000_000;

/// 웹 알림(W5c). `notification` 은 sidecar 가 매긴 번호(0 은 누를 수 없는 알림 — 서비스 워커 등록의 알림), 글은 대화상자 글
/// 규칙(줄바꿈·탭은 받고 4 KiB), 출처는 `scheme://host[:port]`(빈 글 금지 — 출처를 모르는 알림은 넘기지 않는다).
pub const WebNotification = struct {
    browser: BrowserId,
    notification: u32,
    origin: []const u8,
    title: []const u8,
    body: []const u8 = "",
};

pub const WebNotificationClick = struct {
    browser: BrowserId,
    notification: u32,
};

pub const PermissionReply = struct {
    browser: BrowserId,
    request: RequestId,
    result: PermissionResult,
};

pub const DialogReply = struct {
    browser: BrowserId,
    request: RequestId,
    /// 확인·떠나기면 참, 취소·머무르기면 거짓.
    accept: bool,
    /// `prompt` 에 친 글. 다른 종류는 빈 글.
    text: []const u8 = "",
    /// 이 페이지가 이동할 때까지 대화상자를 더 띄우지 못하게 한다(sidecar 가 억제한다).
    suppress: bool = false,
};

pub const FileDialogPath = struct {
    browser: BrowserId,
    request: RequestId,
    path: []const u8,
};

pub const FileDialogReply = struct {
    browser: BrowserId,
    request: RequestId,
    /// 거짓이면 취소 — 앞서 보낸 경로는 버린다.
    accept: bool,
};

/// 입력 좌표·스크롤 양의 상한(절댓값, DIP). 제스처 주인은 view 밖까지 끌 수 있어(C5 — rect 밖 클램프 없음) 음수와 view
/// 크기 너머를 받되, 이보다 크면 쓰레기로 보고 거절한다.
pub const max_pointer_extent: i32 = 64 * 1024;

pub const MouseKind = enum(u8) {
    move = 0,
    /// 포인터가 view 를 떠났다(hover 해제).
    leave = 1,
    down = 2,
    up = 3,
};

pub const MouseButton = enum(u8) {
    left = 0,
    middle = 1,
    right = 2,
};

/// 입력의 수식자·눌린 버튼. 정의되지 않은 비트는 거절한다(닫힌 필드). 끄는 동안의 move 는 눌린 버튼 비트를 실어야
/// 페이지가 드래그(선택)로 본다.
pub const Modifiers = packed struct(u16) {
    shift: bool = false,
    control: bool = false,
    alt: bool = false,
    command: bool = false,
    caps_lock: bool = false,
    left_button: bool = false,
    middle_button: bool = false,
    right_button: bool = false,
    is_repeat: bool = false,
    /// 트랙패드처럼 픽셀 단위로 정밀한 스크롤 양이다.
    precise_scroll: bool = false,
    /// 숫자패드 키(DOM `location` 3).
    key_pad: bool = false,
    /// 왼쪽·오른쪽 수식키(DOM `location` 1·2 — Shift·Control·Option·Command).
    is_left: bool = false,
    is_right: bool = false,
    _reserved: u3 = 0,
};

pub const Point = struct {
    x: i32,
    y: i32,
};

pub const Mouse = struct {
    browser: BrowserId,
    kind: MouseKind,
    /// down·up 만 쓴다(move·leave 는 `left`).
    button: MouseButton = .left,
    point: Point,
    modifiers: Modifiers = .{},
    /// down·up 은 1 이상(macOS `clickCount` 그대로 — 네 번 이상도 Blink 가 받는다), move·leave 는 0.
    click_count: u8 = 0,
};

pub const Wheel = struct {
    browser: BrowserId,
    point: Point,
    delta_x: i32,
    delta_y: i32,
    modifiers: Modifiers = .{},
};

pub const KeyKind = enum(u8) {
    /// 글자로 바뀌기 전의 누름 — 글자는 따로 `char` 로 보낸다.
    raw_down = 0,
    down = 1,
    up = 2,
    char = 3,
};

/// 키 하나. macOS 의 keyCode·글자를 그대로 싣는다 — CEF 는 이것으로 NSEvent 를 다시 지어 DOM `key`·`code` 를 정한다
/// (W4a 변이 실측): `code` 는 `native_key_code` 에서, `key` 는 `character`·`unmodified_character` 에서 온다. Ctrl chord 는
/// `character` 에 제어 문자, `unmodified_character` 에 원 글자를 함께 싣는다 — 둘 다 0 이면 `key` 를 못 정한다(§13.1 시험기의
/// `Unidentified`). `windows_key_code` 는 macOS 에서 CEF 가 NSEvent 로 다시 정해 쓰지 않는다(실측) — 다른 플랫폼 자리다.
pub const Key = struct {
    browser: BrowserId,
    kind: KeyKind,
    modifiers: Modifiers = .{},
    windows_key_code: u8 = 0,
    native_key_code: u8 = 0,
    character: u16 = 0,
    unmodified_character: u16 = 0,
};

/// UTF-16 단위 범위. `none` 은 「범위 없음」(CEF 의 무효 범위 — `CefRange::InvalidRange`).
pub const TextRange = struct {
    start: u32,
    end: u32,

    pub const none: TextRange = .{ .start = std.math.maxInt(u32), .end = std.math.maxInt(u32) };

    pub fn isNone(self: TextRange) bool {
        return self.start == none.start and self.end == none.end;
    }
};

pub const ImeComposition = struct {
    browser: BrowserId,
    /// 조합 중인 글(빈 글이면 조합을 비운다). 탭·줄바꿈은 받는다(받아쓰기).
    text: []const u8,
    /// 조합 글 안에서 선택할 범위. `none`(무효 범위)이면 CEF 가 조합 글 끝의 캐럿으로 둔다(W4a 실측 — 판정자 `input-ime-cancel`).
    selection: TextRange = .none,
    /// 바꿀 기존 글 범위 — 입력칸 **전체 글** 안의 위치라 글 상한과 무관하다(macOS 만 쓴다).
    replacement: TextRange = .none,
};

pub const ImeCommit = struct {
    browser: BrowserId,
    text: []const u8,
    replacement: TextRange = .none,
};

pub const EditCommandKind = enum(u8) {
    undo = 0,
    redo = 1,
    cut = 2,
    copy = 3,
    paste = 4,
    paste_and_match_style = 5,
    delete = 6,
    select_all = 7,
};

pub const EditCommand = struct {
    browser: BrowserId,
    command: EditCommandKind,
};

/// 페이지가 원하는 커서. CEF 의 50 여 종을 maru 가 보일 수 있는 것으로 줄였다 — 나머지는 `arrow`.
pub const WebCursor = enum(u8) {
    arrow = 0,
    hand = 1,
    ibeam = 2,
    vertical_ibeam = 3,
    crosshair = 4,
    resize_ew = 5,
    resize_ns = 6,
    grab = 7,
    grabbing = 8,
    not_allowed = 9,
    copy = 10,
    alias = 11,
    context_menu = 12,
    wait = 13,
    progress = 14,
    help = 15,
    /// CSS `cursor: none` — 숨긴다.
    none = 16,
};

pub const CursorChanged = struct {
    browser: BrowserId,
    cursor: WebCursor,
};

/// view 좌표(DIP) 사각형.
pub const Rect = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
};

pub const PopupChanged = struct {
    browser: BrowserId,
    visible: bool,
    /// view 좌상단 기준 DIP. 닫혔으면(`visible = false`) 모두 0 이다(닫힌 필드 — 다른 값은 거절).
    bounds: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    /// 이 팝업의 링 세대는 이 값 이상이다(열렸을 때 1 이상, 닫혔으면 0). maru 는 알림(파이프)과 링(mach)이 따로 와 순서가
    /// 섞일 수 있다 — 이보다 작은 세대의 팝업 링은 닫히기 직전 팝업의 것이니 그리지 않는다(W6a① 적대 검증 2 차).
    first_generation: u32 = 0,
};

/// 툴팁 글(W6b). 대화상자 글 규칙(`fields.checkDialogText` — 4 KiB, UTF-8, `\t`·`\n`·`\r` 말고 제어 문자 없음).
pub const TooltipChanged = struct {
    browser: BrowserId,
    text: []const u8,
};

/// 우클릭한 자리와 그 자리에서 할 수 있는 일(W6c). 닫힌 필드 — 쓰지 않는 비트는 0, `image_loaded` 는 `image` 와,
/// `selection_truncated` 는 `selection` 과 함께만, `selection` 은 선택한 글이 있을 때만, `image_openable` 은 `image` 와 함께만,
/// `media_*` 는 `media` 와 함께만이고 `media_video`·`media_audio` 는 둘 중 하나(그 밖의 `media_*` 는 둘 중 하나가 있을 때만).
pub const ContextMenuFlags = packed struct(u32) {
    link: bool = false,
    image: bool = false,
    /// 이미지 픽셀이 있다(「이미지 복사」 — 아직 안 받아진 이미지는 주소만 있다).
    image_loaded: bool = false,
    /// 이미지가 아닌 미디어(동영상·오디오·canvas·플러그인) — 그 자리의 Chrome 메뉴는 미디어 항목이라 페이지 항목(뒤로 등)을 내지 않는다.
    media: bool = false,
    selection: bool = false,
    /// 선택한 글이 글 상한(4 KiB)에서 잘렸다.
    selection_truncated: bool = false,
    editable: bool = false,
    can_undo: bool = false,
    can_redo: bool = false,
    can_cut: bool = false,
    can_copy: bool = false,
    can_paste: bool = false,
    can_select_all: bool = false,
    can_go_back: bool = false,
    can_go_forward: bool = false,
    /// 링크를 새 탭에서 열 수 있다(W6e — 걸러진 링크 주소가 http·https 이고 주소 상한 안이다). `link` 일 때만.
    link_openable: bool = false,
    /// 이미지를 새 탭에서 열 수 있다(W6h① — 이미지 주소가 http·https 이고 주소 상한 안이다). `image` 일 때만.
    image_openable: bool = false,
    /// W6h②: 동영상(`<video>`)이다 — 메뉴 문구가 「동영상」.
    media_video: bool = false,
    /// W6h②: 오디오(`<audio>`, 소리만 있는 `<video>` 도 — Chromium 이 그렇게 준다)다 — 메뉴 문구가 「오디오」.
    media_audio: bool = false,
    /// 연속 재생이 켜져 있다(체크 표시)·켜고 끌 수 있다(Chrome 「연속 재생」 — CEF `CM_MEDIAFLAG_LOOP`·`CAN_LOOP`).
    media_loop: bool = false,
    media_can_loop: bool = false,
    /// 제어 기능이 보인다(체크 표시)·켜고 끌 수 있다(Chrome 「모든 제어 기능 표시」 — `CONTROLS`·`CAN_TOGGLE_CONTROLS`, 오디오는 끌 수 없다).
    media_controls: bool = false,
    media_can_toggle_controls: bool = false,
    /// 미디어 주소를 새 탭에서 열 수 있다(http·https, 주소 상한 안).
    media_openable: bool = false,
    /// 미디어 주소를 복사할 수 있다(비지 않았고 `blob:` 이 아니다 — Chrome 154 실측: `blob:` 동영상은 꺼져 있었다).
    media_copyable: bool = false,
    _reserved: u7 = 0,
};

pub const ContextMenu = struct {
    browser: BrowserId,
    /// 브라우저마다 1 부터 오르는 번호(0 은 없다). 명령·닫힘을 이 번호로 짝짓는다 — 늦게 온 명령이 다음 메뉴에 붙지 않게.
    menu: u32,
    /// 우클릭한 자리 — view 좌상단 기준 DIP(iframe 안이어도 view 좌표, 실측).
    point: Point,
    flags: ContextMenuFlags,
    /// 선택한 글(대화상자 글 규칙 — 4 KiB, UTF-8, `\t`·`\n`·`\r` 말고 제어 문자 없음). 「'…' 찾기」·음성·서비스가 쓴다.
    selection: []const u8 = "",
};

pub const ContextMenuClosed = struct {
    browser: BrowserId,
    menu: u32,
};

/// 우클릭 메뉴에서 고른 것. CEF 명령(뒤로~모두 선택)은 sidecar 가 CEF 메뉴 콜백으로 실행한다 — 초점이 있는 frame 에 간다(우클릭은
/// 그 자리에 초점을 준다 — iframe 안 입력 칸도 그 iframe 에 갔다, 실측). 기본 메뉴 모델에 없는 번호도 실행된다(새로고침 — 변이 실측). 복사 셋은 sidecar 가 클립보드에 쓴다(주소·이미지는 maru 에 오지 않는다 — 이미지는 frame 상한보다 크다).
pub const ContextMenuCommandKind = enum(u8) {
    cancel = 0,
    back = 1,
    forward = 2,
    reload = 3,
    undo = 4,
    redo = 5,
    cut = 6,
    copy = 7,
    paste = 8,
    paste_and_match_style = 9,
    select_all = 10,
    copy_link_address = 11,
    copy_image_address = 12,
    copy_image = 13,
    /// 링크를 새 탭(뒤)에서 연다(W6e — Chrome 「새 탭에서 링크 열기」). `link_openable` 일 때만.
    open_link_new_tab = 14,
    /// 링크를 새 창에서 연다(W6h① — Chrome 「새 창에서 링크 열기」, maru 는 새 창의 웹 탭). `link_openable` 일 때만.
    open_link_new_window = 15,
    /// 이미지를 새 탭(뒤)에서 연다(W6h① — Chrome 「새 탭에서 이미지 열기」). `image_openable` 일 때만.
    open_image_new_tab = 16,
    /// W6h②: 우클릭한 미디어의 연속 재생을 켜고 끈다. `media_can_loop` 일 때만.
    media_loop = 17,
    /// W6h②: 우클릭한 미디어의 제어 기능 표시를 켜고 끈다. `media_can_toggle_controls` 일 때만.
    media_controls = 18,
    /// W6h②: 미디어 주소를 새 탭(뒤)에서 연다. `media_openable` 일 때만.
    open_media_new_tab = 19,
    /// W6h②: 미디어 주소를 복사한다(sidecar 가 클립보드에 쓴다). `media_copyable` 일 때만.
    copy_media_address = 20,
};

/// 새 탭을 앞에 둘지(그 탭으로 옮긴다) 뒤에 둘지(W6e — Chrome 과 같다: ⌘·가운데 클릭과 메뉴는 뒤, 그 밖은 앞), 새 창에 둘지
/// (W6h① — 우클릭 메뉴 「새 창에서 링크 열기」에서만. 페이지가 연 창은 탭이다 — `new_tab.placement`). 팝업 이어 받기는 새 창이 아니다.
pub const NewTabPlacement = enum(u8) {
    foreground = 0,
    background = 1,
    new_window = 2,
};

pub const PopupReserve = struct {
    browser: BrowserId,
};

/// sidecar 가 쥐는 맡긴 번호 상한(W6f) — 입력 하나에 팝업 하나라 둘이면 넉넉하다. 넘는 것은 버린다(번호는 다시 쓰이지 않는다).
pub const max_popup_reserve = 4;

pub const PopupCreated = struct {
    opener: BrowserId,
    browser: BrowserId,
    placement: NewTabPlacement,
    url: []const u8,
};

pub const OpenTab = struct {
    browser: BrowserId,
    placement: NewTabPlacement,
    /// http·https 주소(maru 가 다시 거른다).
    url: []const u8,
};

/// 끌어 온 것의 종류(W6d①). 경로는 파일·폴더 하나(절대 경로), 글·HTML 은 이어 붙이는 조각, 주소와 그 제목은 하나씩.
pub const DragDataKind = enum(u8) {
    path = 0,
    text = 1,
    html = 2,
    url = 3,
    url_title = 4,
};

pub const DragData = struct {
    browser: BrowserId,
    kind: DragDataKind,
    bytes: []const u8,
};

pub const DragTargetKind = enum(u8) {
    enter = 0,
    over = 1,
    leave = 2,
    drop = 3,
};

/// 끌기 동작 비트(macOS `NSDragOperation` 과 CEF `cef_drag_operations_mask_t` 가 같은 값 — sidecar 가 comptime 으로 맞춘다).
pub const drag_operation_mask: u32 = 1 | 2 | 4 | 8 | 16 | 32;

pub const DragTarget = struct {
    browser: BrowserId,
    kind: DragTargetKind,
    /// enter 에서만: 0 이 아니면 쌓인 조각 대신 그 번호의 페이지 끌기(`drag_out`) 데이터를 쓴다 — maru 안의 Chromium 탭으로 놓을
    /// 때 페이지가 정한 형식(사용자 정의 MIME 등)이 pasteboard 를 거치며 사라지지 않게(W6d②).
    source: u32 = 0,
    /// leave 는 쓰지 않는다(0).
    point: Point = .{ .x = 0, .y = 0 },
    modifiers: Modifiers = .{},
    /// 끌어 온 쪽이 허용한 동작(`drag_operation_mask` 안). leave·drop 은 0.
    allowed: u32 = 0,
};

/// 페이지가 시작한 끌기의 조각 종류(W6d②). 그림은 PNG 바이트(조각을 이어 붙인다). 이미지 끌기면 파일 이름(W6d③ — Chromium 이
/// 정한 것, `drag_out` 앞에), 파일 내용은 maru 가 청할 때만(`drag_file_request` — 바이트 그대로 이어 붙인다).
pub const DragOutDataKind = enum(u8) {
    text = 0,
    html = 1,
    url = 2,
    url_title = 3,
    image_png = 4,
    file_name = 5,
    file_contents = 6,
};

pub const DragOutData = struct {
    browser: BrowserId,
    drag: u32,
    kind: DragOutDataKind,
    bytes: []const u8,
};

pub const DragOut = struct {
    browser: BrowserId,
    /// 0 이 아니다 — sidecar 전체에서 오른다.
    drag: u32,
    /// 페이지가 허용한 동작(`drag_operation_mask` 안).
    allowed: u32,
    /// 끌기가 시작된 자리(view DIP).
    point: Point,
    /// 그림 안에서 포인터가 잡은 자리와 그림 크기(DIP — 그림이 없으면 0).
    hotspot: Point = .{ .x = 0, .y = 0 },
    image_width: u32 = 0,
    image_height: u32 = 0,
    /// 이미지 끌기면 sidecar 가 받아 둔 파일 내용의 크기(W6d③ — `max_drag_file_bytes` 안, 0 = 파일 없음).
    file_size: u32 = 0,
};

/// 끌어낸 이미지 파일 내용 상한(W6d③) — 넘으면 파일 없이(주소만) 간다.
pub const max_drag_file_bytes: u32 = 32 * 1024 * 1024;

pub const DragFileRequest = struct {
    browser: BrowserId,
    drag: u32,
};

pub const DragFileReady = struct {
    browser: BrowserId,
    drag: u32,
    /// 보낸 크기(실패면 0).
    size: u32,
    ok: bool,
};

pub const DragSourceEnd = struct {
    browser: BrowserId,
    drag: u32,
    point: Point,
    /// 받은 동작 하나(또는 0 — 취소).
    operation: u32,
};

pub const DragOperation = struct {
    browser: BrowserId,
    /// 페이지가 받아들이는 동작 하나(또는 0).
    operation: u32,
};

pub const ContextMenuCommand = struct {
    browser: BrowserId,
    menu: u32,
    command: ContextMenuCommandKind,
};

/// 그 메뉴에서 할 수 있는 명령인가 — maru 는 이 규칙대로 항목을 보이고(W6c②), sidecar 는 이 규칙을 지나지 못한 명령을 취소로
/// 바꾼다. Chrome 메뉴를 따른다(착수 전 실측): 뒤로·앞으로·새로고침은 빈 페이지에서만, 편집 명령은 입력 칸에서만(복사는 선택한
/// 글에서도), 복사 셋은 그 대상이 있을 때만.
pub fn contextMenuAllows(flags: ContextMenuFlags, command: ContextMenuCommandKind) bool {
    const page = !flags.link and !flags.image and !flags.media and !flags.selection and !flags.editable;
    return switch (command) {
        .cancel => true,
        .back => page and flags.can_go_back,
        .forward => page and flags.can_go_forward,
        .reload => page,
        .undo => flags.editable and flags.can_undo,
        .redo => flags.editable and flags.can_redo,
        .cut => flags.editable and flags.can_cut,
        .copy => flags.can_copy and (flags.selection or flags.editable),
        .paste, .paste_and_match_style => flags.editable and flags.can_paste,
        .select_all => flags.editable and flags.can_select_all,
        .copy_link_address => flags.link,
        .copy_image_address => flags.image,
        .copy_image => flags.image_loaded,
        .open_link_new_tab, .open_link_new_window => flags.link_openable,
        .open_image_new_tab => flags.image_openable,
        .media_loop => flags.media_can_loop,
        .media_controls => flags.media_can_toggle_controls,
        .open_media_new_tab => flags.media_openable,
        .copy_media_address => flags.media_copyable,
    };
}

test "context menu commands follow what the menu showed — page items only on the page, edit items where they apply, copies need their target" {
    const page: ContextMenuFlags = .{ .can_go_back = true, .can_select_all = true };
    try std.testing.expect(contextMenuAllows(page, .back) and contextMenuAllows(page, .reload) and !contextMenuAllows(page, .forward));
    try std.testing.expect(!contextMenuAllows(page, .select_all)); // 페이지의 모두 선택은 Chrome 메뉴에 없다
    const link: ContextMenuFlags = .{ .link = true, .selection = true, .can_copy = true, .can_go_back = true };
    try std.testing.expect(contextMenuAllows(link, .copy_link_address) and contextMenuAllows(link, .copy));
    try std.testing.expect(!contextMenuAllows(link, .back) and !contextMenuAllows(link, .reload) and !contextMenuAllows(link, .copy_image_address));
    try std.testing.expect(!contextMenuAllows(link, .open_link_new_tab)); // 걸러진 주소가 http·https 가 아니면 새 탭 없음
    try std.testing.expect(contextMenuAllows(.{ .link = true, .link_openable = true }, .open_link_new_tab));
    // W6h②: 미디어의 복사·열기는 각자의 표지로(`data:` 오디오는 복사만, 열기는 http·https 이고 저장할 수 있을 때만).
    const data_audio: ContextMenuFlags = .{ .media = true, .media_audio = true, .media_copyable = true };
    try std.testing.expect(contextMenuAllows(data_audio, .copy_media_address) and !contextMenuAllows(data_audio, .open_media_new_tab));
    const open_only: ContextMenuFlags = .{ .media = true, .media_video = true, .media_openable = true };
    try std.testing.expect(!contextMenuAllows(open_only, .copy_media_address) and contextMenuAllows(open_only, .open_media_new_tab));
    try std.testing.expect(!contextMenuAllows(data_audio, .media_loop) and contextMenuAllows(.{ .media = true, .media_audio = true, .media_can_loop = true }, .media_loop));
    try std.testing.expect(contextMenuAllows(.{ .image = true }, .copy_image_address) and !contextMenuAllows(.{ .image = true }, .copy_image));
    try std.testing.expect(contextMenuAllows(.{ .image = true, .image_loaded = true }, .copy_image));
    const input: ContextMenuFlags = .{ .editable = true, .can_paste = true, .can_select_all = true };
    try std.testing.expect(contextMenuAllows(input, .paste) and contextMenuAllows(input, .paste_and_match_style) and contextMenuAllows(input, .select_all));
    try std.testing.expect(!contextMenuAllows(input, .undo) and !contextMenuAllows(input, .cut) and !contextMenuAllows(input, .copy) and !contextMenuAllows(input, .reload));
    try std.testing.expect(contextMenuAllows(.{ .selection = true }, .cancel) and !contextMenuAllows(.{ .selection = true }, .copy)); // 복사는 can_copy 를 본다
    try std.testing.expect(!contextMenuAllows(.{ .media = true, .can_go_back = true }, .back) and !contextMenuAllows(.{ .media = true }, .reload)); // 동영상 자리
}

pub const ImeRange = struct {
    browser: BrowserId,
    /// 조합 글자들의 사각형을 모두 합친 것.
    bounds: Rect,
};

pub const Hello = struct {
    instance: u64,
    nonce: u64,
};

pub const ViewSize = struct {
    width: u32,
    height: u32,
    scale: f32,
};

pub const CreateBrowser = struct {
    browser: BrowserId,
    size: ViewSize,
    hidden: bool,
    url: []const u8,
};

pub const Resize = struct {
    browser: BrowserId,
    size: ViewSize,
};

pub const BrowserFlag = struct {
    browser: BrowserId,
    value: bool,
};

/// 링 알림을 받을 mach port 의 bootstrap 이름과, 알림마다 실어 보낼 128 비트 비밀 토큰(C3).
pub const FrameChannel = struct {
    service: []const u8,
    token: [16]u8,
};

pub const Navigate = struct {
    browser: BrowserId,
    url: []const u8,
};

pub const BrowserText = struct {
    browser: BrowserId,
    text: []const u8,
};

pub const NavAction = struct {
    browser: BrowserId,
    action: NavActionKind,
};

pub const NavState = struct {
    browser: BrowserId,
    can_go_back: bool,
    can_go_forward: bool,
    loading: bool,
};

pub const LoadFinished = struct {
    browser: BrowserId,
    http_status: i32,
};

pub const RendererGone = struct {
    browser: BrowserId,
    reason: RendererGoneReason,
};

/// `browser` 가 0 이면 브라우저에 묶이지 않은 실패(초기화·프로필)다.
pub const Failure = struct {
    browser: BrowserId,
    code: FailureCode,
    detail: []const u8,
};

pub const Message = union(Tag) {
    hello: Hello,
    create_browser: CreateBrowser,
    destroy_browser: BrowserId,
    resize: Resize,
    set_hidden: BrowserFlag,
    set_focus: BrowserFlag,
    navigate: Navigate,
    shutdown: void,
    frame_channel: FrameChannel,
    nav_action: NavAction,
    mouse: Mouse,
    wheel: Wheel,
    key: Key,
    ime_set_composition: ImeComposition,
    ime_commit_text: ImeCommit,
    ime_finish_composing: BrowserFlag,
    ime_cancel_composition: BrowserId,
    edit_command: EditCommand,
    capture_lost: BrowserId,
    dialog_reply: DialogReply,
    file_dialog_path: FileDialogPath,
    file_dialog_reply: FileDialogReply,
    permission_reply: PermissionReply,
    geolocation: Geolocation,
    web_notification_click: WebNotificationClick,
    context_menu_command: ContextMenuCommand,
    drag_data: DragData,
    drag_target: DragTarget,
    drag_source_end: DragSourceEnd,
    drag_file_request: DragFileRequest,
    popup_reserve: PopupReserve,
    close_asking: BrowserId,

    hello_ack: Hello,
    browser_created: BrowserId,
    browser_closed: BrowserId,
    title_changed: BrowserText,
    load_finished: LoadFinished,
    renderer_gone: RendererGone,
    failure: Failure,
    url_changed: Navigate,
    nav_state: NavState,
    cursor_changed: CursorChanged,
    ime_range: ImeRange,
    js_dialog: JsDialog,
    file_dialog: FileDialog,
    dialog_closed: Request,
    permission_request: PermissionRequest,
    web_notification: WebNotification,
    popup_changed: PopupChanged,
    tooltip_changed: TooltipChanged,
    context_menu: ContextMenu,
    context_menu_closed: ContextMenuClosed,
    drag_operation: DragOperation,
    drag_out_data: DragOutData,
    drag_out: DragOut,
    drag_file_ready: DragFileReady,
    open_tab: OpenTab,
    popup_created: PopupCreated,
};

test "tags split by direction at 32" {
    inline for (std.meta.fields(Tag)) |field| {
        const tag: Tag = @enumFromInt(field.value);
        const expected: Direction = if (field.value < 32) .to_sidecar else .to_maru;
        try std.testing.expectEqual(expected, tag.direction());
    }
}
