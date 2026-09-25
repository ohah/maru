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
};

test "tags split by direction at 32" {
    inline for (std.meta.fields(Tag)) |field| {
        const tag: Tag = @enumFromInt(field.value);
        const expected: Direction = if (field.value < 32) .to_sidecar else .to_maru;
        try std.testing.expectEqual(expected, tag.direction());
    }
}
