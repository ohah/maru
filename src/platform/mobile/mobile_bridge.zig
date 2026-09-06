//! L4 모바일 어댑터의 **코어 쪽 절반**. iOS·Android host 가 공유한다.
//!
//! 플랫폼은 배치를 모른다 — 쓸 수 있는 크기를 논리 px 로 받고 quad 목록을 돌려준다.
//! 셀 판정(`maru_mobile_hit_cell`)도 여기가 한다. C 쪽 계약은 `mobile_host_abi.h` 가
//! 단일 출처이고, 이 파일의 export 와 **필드 순서·타입을 함께** 바꿔야 한다(한쪽만
//! 고치면 링크는 되고 동작만 어긋난다).
//!
//! **OS 호출이 없다.** 있으면 `platform/ios`·`platform/android` 로 내려야 한다 — 그
//! 규칙이 "공통분모" 를 파일 내용으로 판정 가능하게 만든다(docs/mobile-platform.md §2).
const std = @import("std");
// **모듈 루트는 `maru.zig` 하나다.** chrome·renderer 를 따로 주면 둘 다 `icons.zig` 를
// 상대 경로로 끌어와 "file exists in two modules" 로 깨진다(실측). 배럴 하나로 받으면
// 상대 import 가 전부 같은 모듈 안에서 풀린다.
const maru = @import("maru");

/// **iOS 에서 ReleaseSafe 를 쓰려면 이게 필요하다.** 기본 panic 핸들러는 스택 트레이스를
/// 찍으려고 `_dyld_get_image_header_containing_address` 를 부르는데 그 심볼이 시뮬레이터
/// SDK 에 없어 링크가 깨진다(실측). `simple_panic` 은 메시지만 내고 그 경로를 안 들여온다
/// — **안전 검사(overflow·bounds)는 그대로 산다**.
pub const panic = std.debug.simple_panic;

const chrome = maru.chrome;
const icon_glyph = maru.renderer.icon_glyph;

const tree = chrome.ui.tree;
const layout = chrome.ui.layout;
const paint_mod = chrome.ui.paint;
const scroll_area = chrome.ui.scroll_area;
const input_math = maru.session.input_math;
const gesture = chrome.ui.gesture;
const draw = chrome.draw;
const tokens = chrome.tokens;

/// 플랫폼이 그릴 수 있는 최소 형태로 평탄화한 quad. ChromeDraw 의 op 은 union 이라
/// C 에서 다루기 번거로우니, 여기서 rect + 색 + radius 로 낮춰 넘긴다.
pub const MaruQuad = extern struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    r: f32,
    g: f32,
    b: f32,
    a: f32,
    radius: f32,
    /// 0=단색 quad · 1=아틀라스 글리프 · 2=아이콘 coverage
    kind: u32,
    /// kind=1 일 때 아틀라스 셀 좌표(열, 행). kind=2 면 아이콘 슬롯 인덱스.
    cell_x: u32,
    cell_y: u32,
};

/// 격자 상한. 본문 cols/rows 를 여기로 자르고, quad 버퍼도 **여기서 계산한다** — 둘을 따로
/// 두면 조용히 어긋난다(2048 로 박아 뒀을 때 태블릿 크기에서 격자만으로 넘쳤다. 폰 세로도
/// 1828/2048 로 아슬아슬했다 — 헤드리스 실측).
const max_cols: u16 = 200;
const max_rows: u16 = 60;
/// 본문 밖에서 나오는 quad: 배경 1 + chrome op(`ops` 배열 상한 512) + 라벨 글자 + 아이콘 6.
const chrome_quad_slack = 768;

/// **정적으로 최악을 잡지 않는다.** 셀 속성이 붙으면서 한 칸이 낼 수 있는 quad 가 늘었다 —
/// 배경 1 + 밑줄 1 + 이중밑줄 1 + 취소선 1 + 윗줄 1 + 글자 1 = 6. 최대 격자(200x60)에 그대로
/// 곱하면 72768 개(3.5MB)를 **쓰지도 않을 최악을 위해 늘 이고 가게** 된다(폰의 실제 최악은
/// 3577 개였다 — 실측).
///
/// 그래서 **필요할 때 배로 늘린다.** 늘어나는 시점은 격자가 커질 때뿐이고, 그건 리사이즈라
/// 어차피 플랫폼이 GPU 자원을 다시 세우는 순간이다. 플랫폼은 `maru_mobile_max_quads()` 로
/// 현재 용량을 물어보고 자기 버퍼를 맞춘다.
var quad_buf: []MaruQuad = &.{};
var quad_count: usize = 0;

// ── 본문용 터미널 코어 ────────────────────────────────────────────────────────
// 앞 단계 본문은 하드코딩 문자열이었다. 여기서는 **VT 파서를 실제로 태운다** — 색은
// SGR 에서, 한글 2셀 폭은 코어의 EAW 판정에서 나온다. 즉 화면에 보이는 본문이
// "maru 터미널이 실제로 계산한 격자"다.
const terminal = maru.terminal;
const color = maru.color;
/// **밖에서도 보인다** — 계약 테스트가 서버 목록을 직접 만들어 고르는 규칙을 잰다.
pub const mobile_config = @import("mobile_config.zig");
// **SSH 진입점을 링크에 남긴다.** `maru_mobile_ssh_*` 는 이 파일이 안 부르는 export 라, 참조가
// 없으면 정적 라이브러리에서 통째로 빠지고 host 는 링크 오류를 본다(계약 ABI 는 한 벌이다).
comptime {
    _ = @import("mobile_ssh.zig");
}

// **고정 버퍼로는 resize 를 못 버틴다.** `FixedBufferAllocator` 는 마지막 할당 말고는
// free 가 no-op 이라, 격자가 바뀔 때마다 옛 격자를 영영 못 돌려받는다 — 512KB 로 **resize
// 7번**이면 OutOfMemory 였다(헤드리스 실측). 키보드를 서너 번 올렸다 내리면 닿는 수다.
//
// `page_allocator` 를 쓴다: 전역 싱글턴이 없고(우리는 남의 앱 프로세스 안에 들어가는
// 라이브러리다) free 가 실제로 메모리를 돌려준다. 페이지 단위 반올림 손실은 코어 할당이
// 몇 개뿐이라 작다 — 원격 세션(M3)이 붙어 처리량이 생기면 그때 재보고 정한다.
const term_allocator = std.heap.page_allocator;
var term_core: ?terminal.core.TerminalCore = null;

/// 파싱된 모바일 config. **파일이 단일 출처**이고 host 가 바이트를 넘긴다(계약 §7 — 브리지엔 OS
/// 호출이 없다). 없으면 기본값으로 돈다 — 설정을 한 번도 안 건드린 기기가 정상 상태다.
var cfg_parsed: ?mobile_config.Parsed = null;

/// **파일 본문을 그대로 들고 있는다.** 저장은 통째로 다시 쓰는 것이 아니라 그 본문의 한 줄만
/// 고치는 것이라(주석·모르는 키 보존, 계약 §7) 원본이 있어야 한다. host 가 준 바이트를 복사해
/// 둔다 — host 의 버퍼는 그 호출이 끝나면 우리 것이 아니다.
var cfg_source: []u8 = &.{};
/// host 가 가져갈 저장 요청. 복사(`take_copy`)와 같은 모양 — 브리지엔 OS 호출이 없다.
var cfg_write: []u8 = &.{};

fn cfg() mobile_config.Config {
    return if (cfg_parsed) |p| p.config else .{};
}

/// host 가 마지막으로 알려 준 **시스템 외관**(다크면 true). `null` 이면 아직 못 들었다 —
/// 그때는 `theme.follow-system` 이 켜져 있어도 파일 색을 쓴다(모르는 값으로 화면을 바꾸지 않는다).
var system_is_dark: ?bool = null;

/// 시스템 외관이 다크인지 host 가 알려 준다. **생성 직후 한 번, 그리고 바뀔 때마다**다
/// (데스크톱 F2-9 의 `setSystemAppearance` 와 같은 계약).
pub export fn maru_mobile_set_system_appearance(is_dark: u32) void {
    system_is_dark = is_dark != 0;
}

/// 지금 화면에 쓸 테마 색. **여기가 follow-system 이 사는 유일한 자리다.**
///
/// **config 를 안 고친다** — 데스크톱은 색을 config 에 덮고 「파일에는 안 쓴다」를 규율로 지키며
/// 되돌리려고 원본을 스냅숏하는데, 모바일은 색을 **그릴 때** 읽으므로 그럴 필요가 없다:
/// 파일 값은 손대지 않은 채 남고, 저장 경로가 시스템 색을 실을 **길 자체가 없으며**(config 에
/// 없으니까), follow 를 끄면 다음 프레임에 파일 색으로 돌아온다. 규율 대신 구조로 지킨다.
///
/// 설정 화면의 `theme.preset` 줄도 **파일이 말하는 것**을 그대로 보인다 — 시스템이 고른 색을
/// 거기 비추면 사용자가 안 고른 것을 고른 것처럼 읽는다.
fn activeTheme() maru.config.theme.ThemeConfig {
    const c = cfg();
    if (!c.system_theme.follow_system) return c.theme;
    const dark = system_is_dark orelse return c.theme;
    return maru.config.theme.presetColors(if (dark) c.system_theme.preset_dark else c.system_theme.preset_light);
}

/// 지금 따라가는 중인가(판정자용). 켜져 있어도 host 가 아직 안 알려 줬으면 **안 따라간다**.
pub fn followingSystemTheme() bool {
    return cfg().system_theme.follow_system and system_is_dark != null;
}

/// 「아직 못 들었다」로 되돌린다(판정자용). 앱에는 그 전이가 없다 — host 가 만들 때 한 번 알린 뒤
/// 다시 모르는 상태가 되지 않는다.
pub fn resetSystemAppearanceForTest() void {
    system_is_dark = null;
}

/// **config 가 들고 있는** 배경색 글자(판정자용). 화면 색(`terminalBackgroundColor`)과 갈라
/// 보려고 둔다 — follow-system 이 파일을 안 건드리는지가 그 둘의 차이로 드러난다.
pub fn configThemeBackgroundForTest() []const u8 {
    return cfg().theme.background;
}

/// `#RRGGBB` 를 토큰 색으로. 값이 틀리면 fallback — 파싱이 이미 forgiving 이라 여기 오는 값은
/// 대개 맞지만, 색은 **화면이 통째로 검게 될 수 있는 자리**라 마지막까지 기본값을 지킨다.
fn hex(text: []const u8, fallback: color.Rgb) color.Rgb {
    return color.parseHex(text) orelse fallback;
}
/// 원격에서 받아 코어에 **닿은** 누적 바이트. host 가 "출력이 죽었나" 를 이 값으로 판정한다.
var term_written: usize = 0;
var term_cols: u16 = 0;
var term_rows: u16 = 0;

// **데모 바이트는 없앴다**(사용자 요청). 화면을 채워 보이려고 넣어 둔 글이었는데,
// 붙기 전에도 터미널이 뭔가 하고 있는 것처럼 보이고 원격 출력이 그 밑에 붙어 섞였다.
// 빈 화면이 정직하다 — 무엇이 원격에서 온 것인지가 화면만 봐도 분명해진다.

// ── 입력 ─────────────────────────────────────────────────────────────────────
// 플랫폼이 키를 받아 **바이트로** 넘긴다. 코어는 그것을 PTY 에서 온 것과 구분하지 않는다 —
// 그게 터미널의 계약이고, 모바일에서도 같은 계약이 서는지 보는 자리다.
/// **코어에 실제로 전달한** 누적 바이트. 반환값이 기록 길이였을 때는 버퍼가 찬 뒤에도
/// 같은 수가 계속 나와서, 입력이 죽은 것을 로그로 알아챌 수 없었다.
var delivered_len: usize = 0;

// **조합 중 문자열은 코어에 안 넣는다.** 확정 전에 PTY 로 흘리면 셸이 `ㅎ` 같은 자모를
// 명령어 일부로 받는다. 화면에만 흐리게 그릴 겉치레라 별도 상태로 둔다 — 데스크톱 maru 의
// IME 계약(삽입형 + dim 고스트)과 같은 모양이다.
var preedit_buf: [128]u8 = undefined;
var preedit_len: usize = 0;

/// 조합 중 문자열이 격자에서 차지하는 **칸 수**. 바이트 수도 글자 수도 아니다 — 한글은 한
/// 글자가 두 칸이라 셋이 전부 다르다. 폭 판정은 코어와 **같은 자리**(`maru.width.cellWidth`)를
/// 쓴다: 여기서 따로 세면 조합이 그려지는 자리와 커서가 서는 자리가 갈린다.
fn preeditCols() u16 {
    if (preedit_len == 0) return 0;
    var cols: u16 = 0;
    // 조용히 넘기지 않는다(§5) — 폭이 0 이면 커서가 안 움직여 "조합이 안 보인다" 로 나타나는데,
    // 신호가 없으면 그 원인을 화면만 보고는 못 가른다.
    var view = std.unicode.Utf8View.init(preedit_buf[0..preedit_len]) catch {
        setLastError("preedit_bad_utf8");
        return 0;
    };
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| cols +|= maru.width.cellWidth(cp);
    return cols;
}

/// 화면에서 커서가 **실제로 서는 열**. 조합 중이면 그 뒤다.
///
/// **한 곳이 정한다.** 커서를 그리는 자리와 후보창 앵커(`maru_mobile_caret_rect`)가 각자 세면
/// 갈리고, 갈리면 후보창이 글자를 덮는 자리에 뜬다 — 이 저장소가 반복해 겪은 "두 벌" 사고다.
fn cursorColOnScreen(cur_col: u16, cols: u16) u16 {
    const pre = preeditCols();
    if (pre == 0 or cols == 0) return cur_col;
    return @min(cur_col +| pre, cols - 1);
}

/// 조합 중 문자열이 차지하는 칸 수(테스트·진단용).
pub fn preeditColsNow() u16 {
    return preeditCols();
}

/// config 파일 바이트를 넘긴다. **파일을 여는 것은 host** 다(계약 §7 — 브리지엔 OS 호출이 없다).
/// 파일이 없으면 안 부르면 된다 — 그러면 기본값으로 돈다. 다시 부르면 통째로 갈아 끼운다.
/// 지금 접속의 상태. **화면이 이것으로 말한다** — 예전에는 실패가 로그에만 남아, 사용자는
/// 목록을 눌렀는데 빈 터미널만 봤다(무엇을 고쳐야 하는지 알 길이 없었다).
var conn_state: u32 = 0;
/// host 가 준 실패 이름(`connect_failed`·`AuthFailed`…). 사람 말로 바꾸는 것은 화면이 한다 —
/// 이름은 로그·계측의 것이고, 화면에 그대로 내면 사용자는 못 읽는다.
var conn_err: [64]u8 = undefined;
var conn_err_len: usize = 0;

/// host 가 세션 상태와 실패 이름을 알린다(`state` 는 `MARU_SSH_STATE_*`).
pub export fn maru_mobile_set_ssh_status(state: u32, err: [*]const u8, len: usize) void {
    conn_state = state;
    const n = @min(len, conn_err.len);
    @memcpy(conn_err[0..n], err[0..n]);
    conn_err_len = n;
}

/// 지금 상태를 **사람 말로**. 붙는 중·붙음·실패 이유가 한 문장이다.
///
/// **이름을 그대로 안 보인다.** `connect_failed` 는 우리 말이고, 사용자가 할 일은 "주소와
/// 포트를 확인" 이다 — 화면은 그것을 말해야 한다.
fn connectionMessage() ?[]const u8 {
    // **셸이 떴으면 아무 말도 안 한다 — 화면이 곧 답이다.** 이 판정이 이름 검사보다 **먼저**여야
    // 한다: 뒤에 두면 남아 있는 이름 하나가 **멀쩡히 돌아가는 셸 위에** "붙지 못했다" 를 띄운다.
    // 기기에서 실제로 그랬다 — 컨트롤 채널이 세션 준비 전에 지면서 남긴 `not_running` 이 세션
    // 내내 배너로 떠 있었다. 그 이름이 애초에 안 오게 축을 갈랐지만(ssh_pump.c 의 두 슬롯),
    // 순서를 그대로 두면 **다음에 어떤 이름이 새든 같은 사고가 다시 난다.**
    if (conn_state == 11) return null; // MARU_SSH_STATE_READY
    const err = conn_err[0..conn_err_len];
    if (err.len > 0) {
        const key: maru.i18n.Key = if (std.mem.eql(u8, err, "connect_failed") or std.mem.eql(u8, err, "resolve_failed"))
            .mob_conn_unreachable
        else if (std.mem.eql(u8, err, "AuthFailed") or std.mem.eql(u8, err, "auth"))
            .mob_conn_auth
        else if (std.mem.eql(u8, err, "host_key_mismatch"))
            .mob_conn_hostkey
        else if (std.mem.eql(u8, err, "host_key_rejected"))
            .mob_conn_rejected
        else if (std.mem.eql(u8, err, "host_key_timeout") or std.mem.eql(u8, err, "password_timeout"))
            .mob_conn_timeout
        else if (std.mem.eql(u8, err, "closed_by_peer"))
            .mob_conn_closed
        else
            .mob_conn_failed;
        return maru.i18n.tIn(.ko, key);
    }
    // **끝난 것을 진행 중이라고 말하지 않는다.** `CLOSED` 는 아래 "진행 상태" 갈래로 떨어져
    // **끊긴 화면에 "붙는 중..." 이 떴다**(기기 실측: 끊기를 누르면 `state=12` 인데 배너는
    // 붙는 중이라 했다 — 사용자는 앱이 알아서 다시 붙는 줄 안다). 이유 이름이 없어도 상태만으로
    // 갈리는 자리다.
    if (conn_state == 12) return maru.i18n.tIn(.ko, .mob_conn_ended); // MARU_SSH_STATE_CLOSED
    // 오류가 없으면 진행 상태다. 아직 시작 전이면 할 말이 없다(READY 는 위에서 이미 갈렸다).
    if (conn_state == 0) return null;
    return maru.i18n.tIn(.ko, .mob_conn_connecting);
}

/// 지금 화면이 보일 연결 문구(테스트·진단용).
pub fn connectionMessageNow() ?[]const u8 {
    return connectionMessage();
}

/// **처음 보는 서버의 지문을 묻는 중인가.** host 가 세션 상태를 보고 켠다.
var hostkey_prompt = false;
var hostkey_fp: [128]u8 = undefined;
var hostkey_fp_len: usize = 0;
/// 사용자의 답(0=아직, 1=승인, 2=거절). **가져가면 사라진다.**
var hostkey_answer: u32 = 0;
/// 지금 붙는 중인 서버의 번호. **승인한 지문을 어디에 적을지**가 이 값이다 — 요청은 가져가면
/// 사라지므로(§접속 요청) 여기 남겨 둔다.
var ssh_connecting: ?usize = null;

/// host 가 "이 지문을 물어라" 를 알린다. 0 길이면 화면을 거둔다.
pub export fn maru_mobile_set_host_key_prompt(fp: [*]const u8, len: usize) void {
    if (len == 0) {
        if (hostkey_prompt) {
            hostkey_prompt = false;
            hostkey_fp_len = 0;
            if (screenTop() == .host_key) navPop();
        }
        return;
    }
    if (hostkey_prompt) return; // 이미 묻는 중이다 — 같은 물음을 두 번 밀지 않는다
    if (len > hostkey_fp.len) {
        // **자르지 않는다** — 반쪽 지문을 보여 주면 사용자가 확인할 수 없는 것을 확인한 셈이 된다.
        setLastError("host_key_fp_too_long");
        return;
    }
    @memcpy(hostkey_fp[0..len], fp[0..len]);
    hostkey_fp_len = len;
    hostkey_answer = 0;
    hostkey_prompt = true;
    navPush(.host_key);
}

/// 사용자의 답을 가져간다(0=아직, 1=승인, 2=거절). **가져가면 사라진다.**
pub export fn maru_mobile_take_host_key_decision() u32 {
    const a = hostkey_answer;
    hostkey_answer = 0;
    return a;
}

/// 지금 보여 주고 있는 지문(테스트·진단용).
pub fn hostKeyFingerprintShown() []const u8 {
    return hostkey_fp[0..hostkey_fp_len];
}

/// **비밀번호를 묻는 중인가.** host 가 세션 상태를 보고 켠다(`maru_mobile_set_password_prompt`).
/// 화면이 그 값을 보고 서고, 사용자가 확정하면 host 가 가져간다.
var password_prompt = false;
/// 사용자가 친 비밀번호. **가져가면 사라진다**(계약 §3.4 — 저장하지 않는다).
var password_buf: [256]u8 = undefined;
var password_len: usize = 0;
var password_ready = false;

/// host 가 "비밀번호를 물어야 한다" 를 알린다(1=물어라, 0=끝났다).
///
/// **끄는 자리도 host 다** — 세션이 끝났는데 화면만 남으면 사용자는 안 가는 곳에 계속 친다.
pub export fn maru_mobile_set_password_prompt(wanted: u32) void {
    const on = wanted != 0;
    if (password_prompt == on) return;
    password_prompt = on;
    if (on) {
        set_edit_len = 0;
        edit_target = .password;
        kb_raise_req = true;
        navPush(.password);
    } else {
        // 화면을 거둔다. 친 것이 남아 있으면 지운다 — 다음 물음에 지난 값이 뜨면 안 된다.
        wipePassword();
        if (screenTop() == .password) navPop();
    }
}

/// 친 비밀번호를 가져간다(없으면 0). **가져가면 사라진다.**
pub export fn maru_mobile_take_password(out: [*]u8, cap: usize) usize {
    if (!password_ready) return 0;
    const n = password_len;
    if (n > cap) {
        // 자르면 **틀린 비밀번호를 보내는** 것이 된다 — 사용자는 맞게 쳤는데 실패한다.
        setLastError("password_truncated");
        return 0;
    }
    @memcpy(out[0..n], password_buf[0..n]);
    wipePassword();
    return n;
}

/// 친 비밀번호를 지운다. **브리지에도 안 남긴다**(계약 §3.4).
fn wipePassword() void {
    @memset(&password_buf, 0);
    password_len = 0;
    password_ready = false;
    if (edit_target == .password) {
        edit_target = .none;
        @memset(&set_edit_buf, 0); // 치는 중이던 것도 남기지 않는다
        set_edit_len = 0;
    }
}

/// 붙어 달라는 요청(0=없음, 아니면 번호+1). **가져가면 사라진다** — 두 번 붙으면 세션이 둘이다.
var ssh_connect_req: u32 = 0;

/// 붙을 수 있는 첫 서버. **반쯤 적은 줄은 건너뛴다** — 그걸로 붙으러 가면 실패 이유가
/// "네트워크" 처럼 보여 사용자가 무엇을 안 적었는지 모른다(계약 §4.3).
///
/// 자동 요청은 프로세스마다 한 번뿐이라 그 경로로는 이 규칙을 한 가지 경우밖에 못 잰다 —
/// 그래서 고르는 일만 순수 함수로 떼어 둔다(테스트가 목록을 직접 준다).
pub fn firstComplete(list: []const mobile_config.Server) ?usize {
    for (list, 0..) |srv, i| if (srv.isComplete()) return i;
    return null;
}

/// 그 서버에 붙어 달라고 요청하고 터미널로 간다. **여기가 사용자가 고르는 자리**다 —
/// 자동 요청(config 를 읽을 때)은 붙을 길이 이것뿐이던 때의 임시 경로이고, 이제 둘 다 같은
/// 요청 하나로 모인다(host 는 어디서 왔는지 안 봐도 된다).
///
/// **온전하지 않은 줄은 요청하지 않는다.** 화면이 그 줄을 "접속할 수 없다" 고 이미 말하고
/// 있으므로, 눌렀을 때 조용히 아무 일도 안 하는 대신 그 자리에 머문다.
fn connectToServer(i: usize) void {
    const list = servers();
    if (i >= list.len or !list[i].isComplete()) return;
    ssh_connect_req = @intCast(i + 1);
    ssh_connecting = i; // 승인한 지문을 이 줄에 적는다
    navPop(); // 목록 → 세션 목록
    navPush(.terminal);
}

/// 지금 들고 있는 서버 목록. config 를 안 읽었으면 빈 목록이다.
fn servers() []const mobile_config.Server {
    // **포인터로 잡는다.** 값으로 캡처하면 `Parsed` 를 통째로 스택에 복사하고, 돌려주는
    // 슬라이스가 **그 복사본**을 가리킨다 — 함수가 끝나면 사라지는 자리다. 값 하나만 읽을
    // 때는 우연히 동작해서(같은 프레임 안이라) 오래 안 드러난다: 화면이 그 목록으로 글자를
    // 만들자 그 자리에서 죽었다(테스트가 잡았다).
    if (cfg_parsed) |*parsed| return parsed.servers[0..parsed.server_count];
    return &.{};
}

pub export fn maru_mobile_load_config(ptr: [*]const u8, len: usize) void {
    const next = mobile_config.parse(term_allocator, ptr[0..len]) catch {
        setLastError("config_parse");
        return;
    };
    if (cfg_parsed) |*old| old.deinit();
    cfg_parsed = next;
    // **원격 세션이 없을 때만 온전한 첫 서버를 자동으로 요청한다**(임시 — S9b-2b 가 이 자리를
    // 화면 탭으로 바꾼다). 두 조건이 다 필요하다.
    //
    // - 붙어 있는 동안 또 요청하면 **세션이 둘** 생긴다. config 는 배경에서 돌아올 때마다 다시
    //   읽으므로(계약 §7) 그 자리가 곧 재접속 자리가 된다.
    // - 끊긴 뒤에는 **다시 붙어야 한다**. SSH 에는 재개가 없어서(SSH 계약 §4.1) 되살릴 수 없고
    //   새로 붙는 수밖에 없다 — 예전에는 host 가 `onResume` 마다 파일을 다시 읽어 그 일을 했다.
    //
    // "원격 세션이 있나" 는 **입력 목적지가 이미 아는 사실**이다(host 가 상태로 세운다) — 그
    // 사실을 두 번 세면 갈린다.
    if (input_sink == 0) {
        if (firstComplete(next.servers[0..next.server_count])) |i| {
            ssh_connect_req = @intCast(i + 1);
            ssh_connecting = i;
        }
    }
    if (cfg_source.len > 0) term_allocator.free(cfg_source);
    cfg_source = term_allocator.dupe(u8, ptr[0..len]) catch blk: {
        setLastError("config_source_alloc");
        break :blk &.{};
    };
    if (term_core) |*core| applyConfigToCore(core);
}

/// 설정 화면이 값을 바꾸면 부른다 — config 를 고치고 **저장 요청을 세운다**. 파일을 쓰는 것은
/// host 다(§7). 요청은 `maru_mobile_take_config_write` 로 한 번만 나간다.
fn settingChanged(row: mobile_config.Row, v: i64) void {
    if (cfg_parsed == null) {
        // 파일이 없던 기기 — 빈 본문에서 시작한다(그 키만 있는 파일이 생긴다).
        cfg_parsed = mobile_config.parse(term_allocator, "") catch {
            setLastError("config_parse");
            return;
        };
    }
    mobile_config.setValue(&cfg_parsed.?.config, row.key, v);
    if (term_core) |*core| applyConfigToCore(core);

    var num: [24]u8 = undefined;
    const text = mobile_config.textOf(row, v, &num);
    const next = mobile_config.withKey(term_allocator, cfg_source, row.key, text) catch {
        // **조용히 실패하지 않는다** — 화면은 이미 바뀌었는데 다음에 켜면 돌아가 있으면
        // 사용자는 이유를 모른다(계약 §7).
        setLastError("config_write_build");
        return;
    };
    if (cfg_source.len > 0) term_allocator.free(cfg_source);
    cfg_source = next;
    if (cfg_write.len > 0) term_allocator.free(cfg_write);
    cfg_write = term_allocator.dupe(u8, next) catch blk: {
        setLastError("config_write_alloc");
        break :blk &.{};
    };
}

/// 저장할 본문을 가져간다(한 번 가져가면 요청이 사라진다 — 복사와 같은 규율). 0 이면 없다.
/// 버퍼가 모자라면 **아무것도 안 준다** — 잘린 config 를 쓰면 설정이 반만 남는다.
pub export fn maru_mobile_take_config_write(out: [*]u8, cap: usize) usize {
    if (cfg_write.len == 0) return 0;
    if (cfg_write.len > cap) {
        setLastError("config_write_truncated");
        return 0;
    }
    @memcpy(out[0..cfg_write.len], cfg_write);
    const n = cfg_write.len;
    term_allocator.free(cfg_write);
    cfg_write = &.{};
    return n;
}

/// 코어가 드는 값을 config 에서 세운다. **두 곳에서 부른다** — config 를 읽을 때와 **코어가
/// 설 때**. host 는 화면이 서기 전에 config 를 읽으므로(첫 프레임부터 그 색으로 그리려고)
/// 그때는 코어가 아직 없다 — 여기 없으면 그 값들이 **조용히 버려진다**(스크롤백 줄 수가
/// 그렇게 사라졌다).
fn applyConfigToCore(core: *terminal.core.TerminalCore) void {
    const c = cfg();
    core.setMaxScrollback(c.scrollback.lines);
}

/// 코어가 실제로 들고 있는 스크롤백 줄 수(진단·테스트용). config 가 코어에 닿았는지는
/// **코어에 물어야** 안다 — 파싱된 값을 되읽으면 "닿았다" 를 재는 것이 아니다.
/// 설정 화면이 그릴 줄(테스트·진단용 — 스키마에서 comptime 에 나온다).
/// 그 점이 어느 설정 행인가(테스트·진단용) — **브리지가 그린 rect 로** 답한다. 테스트가 좌표를
/// 다시 계산하면 그리는 자리와 판정하는 자리가 갈린다.
pub fn settingsRowAt(x: f32, y: f32) ?usize {
    var field_i: usize = 0;
    for (set_items, 0..) |item, i| switch (item) {
        .header => {},
        .field => {
            if (setHit(set_row_rects[i], x, y)) return field_i;
            field_i += 1;
        },
    };
    return null;
}

/// 화면이 실제로 그린 필드 줄 수(헤더 제외).
pub fn settingsFieldCount() usize {
    var n: usize = 0;
    for (set_items) |item| if (item == .field) {
        n += 1;
    };
    return n;
}

/// **지금 무엇을 입력받고 있나.** host 는 이 값으로 키보드 종류를 고른다(터미널이면 글자,
/// 숫자 칸이면 숫자 패드). 브리지가 정하는 이유는 "무엇을 누르고 있나" 를 아는 쪽이 여기이기
/// 때문이다 — host 가 화면 상태를 다시 추측하면 갈린다(§3 "판단은 코어가 한다").
pub export fn maru_mobile_input_kind() u32 {
    // 비밀번호는 글자 키보드다 — 가림(●)은 우리가 그린다(OS 에 맡기면 그 칸이 우리 것이 아니다).
    if (edit_target == .password) return 2;
    // **줄의 종류를 봐야 한다 — "편집 중인가" 가 아니다.** 색 줄에 숫자 패드를 띄우면 `#` 도
    // `a~f` 도 못 쳐서 **아무것도 못 넣는다**(기기에서 그 상태로 막혔다).
    //
    // 그리고 **"안 하는 중" 과 "글자 칸" 은 다른 값이어야 한다** — 같은 0 으로 말하면 host 가
    // 하드웨어 키보드로 친 글자를 어디로 보낼지 못 고른다(터미널 vs 설정 칸).
    if (edit_target == .server_field) {
        const f: ServerField = @enumFromInt(srv_edit_field);
        return if (f == .port) 1 else 2;
    }
    const i = set_edit orelse return 0; // 0=글자(터미널) · 1=숫자 칸 · 2=글자 칸
    return if (set_items[i].field.kind == .number) 1 else 2;
}

/// **키보드가 사라졌다**고 host 가 알린다. 편집 중이었으면 **확정하고 거둔다.**
///
/// 키보드 없이 편집만 남으면 **칠 수 없는 편집 중**이 된다 — 줄은 캐럿을 달고 입력 대상인
/// 척하는데 글자가 들어갈 길이 없다. 사용자에게는 무엇을 해도 반응이 없는 화면이다.
///
/// **뒤로가기로는 못 잡는다.** Android 는 키보드가 떠 있으면 back 을 키보드가 먹어 앱까지
/// 안 온다(기기 실측: 사용자가 뒤로가기로 닫았는데 `edit` 이 그대로 남았다). 그래서 키보드가
/// 사라진 **사실 자체**를 신호로 쓴다.
///
/// **확정이지 취소가 아니다.** 바깥을 눌러 닫는 자리도 확정이고(§5.6 — iOS 숫자 패드에는
/// Return 이 없다), 아무것도 안 쳤으면 확정해도 값이 안 바뀐다.
pub export fn maru_mobile_keyboard_hidden() void {
    if (set_edit == null) return;
    commitTextEdit(); // 숫자 줄도 이 자리가 받는다(줄 종류는 안에서 가른다)
}

/// **키보드를 올려 달라는 요청.** 한 번 가져가면 사라진다(복사와 같은 규율).
///
/// 우리는 시작할 때부터 입력 대상을 잡고 있어(iOS first responder · Android showSoftInput) 그
/// 뒤로는 키보드 상태가 안 바뀐다 — 사용자가 한 번 내리면 **다시 올릴 길이 없었다**. 숫자 칸을
/// 눌렀는데 키보드가 없으면 칠 수가 없다.
var kb_raise_req: bool = false;
pub export fn maru_mobile_take_keyboard_raise() u32 {
    if (!kb_raise_req) return 0;
    kb_raise_req = false;
    return 1;
}

/// **키보드를 내려 달라는 요청.** 올리는 것과 대칭이고 규율도 같다(한 번 가져가면 사라진다).
var kb_hide_req: bool = false;
pub export fn maru_mobile_take_keyboard_hide() u32 {
    if (!kb_hide_req) return 0;
    kb_hide_req = false;
    return 1;
}

/// 화면이 바뀌었다 — **이 화면에 키보드가 필요한지** 다시 본다.
///
/// 앱은 시작부터 입력 대상을 잡고 키보드를 유지한다(터미널이 주 용도라 그렇게 정했다). 그런데
/// 그 상태로 다른 화면에 가면 **쓸 데가 없는 키보드가 화면 절반을 먹는다** — 목록에서 세션을
/// 고르려는데 절반이 자판이다(사용자 요청).
///
/// **터미널과 비밀번호는 올린다.** 둘 다 들어가자마자 치는 자리다. "그대로 둔다" 로는 부족한데,
/// 앞 화면에서 내려가 있었으면 **내려간 채로 들어오기** 때문이다(기기 실측: 비밀번호를 물으면서
/// 자판이 없었다). 이미 떠 있으면 올리라는 요청은 아무 일도 안 한다.
///
/// 나머지 화면은 **누르면 올라온다**(설정 줄·서버 칸이 `kb_raise_req` 를 세운다). 미리 띄워 둘
/// 이유가 없고, 띄워 두면 목록을 고르는데 화면 절반이 자판이다.
fn syncKeyboardForScreen() void {
    switch (screenTop()) {
        .terminal, .password => kb_raise_req = true,
        else => kb_hide_req = true,
    }
}

/// 친 글자를 편집 중인 숫자 칸에 넣는다. **숫자만 받는다** — host 가 숫자 패드를 띄우지만
/// 하드웨어 키보드나 다른 IME 는 무엇이든 보낼 수 있다. 자릿수 상한을 넘으면 무시한다(조용히
/// 자르지 않는다 — 넘친 것은 오류로 남긴다).
fn editNumberInput(bytes: []const u8) void {
    for (bytes) |c| {
        if (c == '\n' or c == '\r') { // 확정
            commitNumberEdit();
            return;
        }
        if (c < '0' or c > '9') {
            setLastError("settings_number_only");
            continue;
        }
        if (set_edit_len == set_edit_buf.len) {
            setLastError("settings_number_overflow");
            return;
        }
        set_edit_buf[set_edit_len] = c;
        set_edit_len += 1;
    }
}

/// 편집을 확정한다 — **범위 밖이면 안 넣는다**(스키마의 range 가 그 판정의 단일 출처다).
fn commitNumberEdit() void {
    if (edit_target == .server_field) return commitServerFieldEdit();
    const i = set_edit orelse return;
    defer {
        set_edit = null;
        set_edit_len = 0;
    }
    if (set_edit_len == 0) return; // 아무것도 안 치고 확정 — 값을 안 바꾼다
    const row = set_items[i].field;
    const v = std.fmt.parseInt(i64, set_edit_buf[0..set_edit_len], 10) catch {
        setLastError("settings_number_parse");
        return;
    };
    if (mobile_config.outOfRange(row.key, v)) {
        setLastError("settings_number_range");
        return;
    }
    settingChanged(row, v);
}

/// 문자열 줄에 친 글자를 담는다. **확정 전에는 config 를 안 건드린다**(숫자 줄과 같은 이유 —
/// 중간 값이 그대로 적용되면 화면이 치는 동안 요동친다).
fn editTextInput(bytes: []const u8) void {
    for (bytes) |c| {
        if (c == '\n' or c == '\r') { // 확정
            commitTextEdit();
            return;
        }
        if (set_edit_len == set_edit_buf.len) {
            setLastError("settings_text_overflow");
            return;
        }
        set_edit_buf[set_edit_len] = c;
        set_edit_len += 1;
    }
}

/// **한 글자를 지운다 — 한 바이트가 아니다.** UTF-8 은 글자마다 길이가 다르므로 바이트로
/// 지우면 한글이 반쪽 바이트로 남아 화면이 깨진다(그 조각은 파일에도 그대로 실린다).
fn editBackspace() void {
    if (set_edit_len == 0) return;
    var n = set_edit_len - 1;
    while (n > 0 and (set_edit_buf[n] & 0xC0) == 0x80) n -= 1; // 이어지는 바이트를 건너뛴다
    set_edit_len = n;
}

/// 문자열 편집을 확정한다. **못 쓰는 값이면 안 넣는다** — 색이 깨지면 화면이 통째로 안 보이게
/// 될 수 있고, 그 상태로 파일에 실리면 다음 실행에서도 그대로다.
fn commitTextEdit() void {
    if (edit_target == .password) return commitPassword();
    if (edit_target == .server_field) return commitServerFieldEdit();
    const i = set_edit orelse return;
    defer {
        set_edit = null;
        set_edit_len = 0;
    }
    if (set_edit_len == 0) return; // 아무것도 안 치고 확정 — 값을 안 바꾼다
    const row = set_items[i].field;
    const text = set_edit_buf[0..set_edit_len];
    if (std.mem.startsWith(u8, row.key, "theme.") or std.mem.startsWith(u8, row.key, "cursor.")) {
        if (color.parseHex(text) == null) {
            setLastError("settings_color_parse");
            return;
        }
    }
    settingChangedText(row, text);
}

/// 문자열 값을 config 에 넣고 파일에 실을 준비를 한다(숫자 쪽 `settingChanged` 와 같은 순서).
fn settingChangedText(row: mobile_config.Row, text: []const u8) void {
    const next = mobile_config.withKey(term_allocator, cfg_source, row.key, text) catch {
        setLastError("config_write_build");
        return;
    };
    if (cfg_source.len > 0) term_allocator.free(cfg_source);
    cfg_source = next;
    // **파일이 곧 값이다** — 새 본문을 다시 파싱해 화면·코어가 같은 것을 본다(§1: 화면이
    // 자기 상태를 들면 파일과 갈린다).
    const parsed = mobile_config.parse(term_allocator, cfg_source) catch {
        setLastError("config_parse");
        return;
    };
    if (cfg_parsed) |*old_parsed| old_parsed.deinit();
    cfg_parsed = parsed;
    if (term_core) |*core| applyConfigToCore(core);
    if (cfg_write.len > 0) term_allocator.free(cfg_write);
    cfg_write = term_allocator.dupe(u8, cfg_source) catch blk: {
        setLastError("config_write_alloc");
        break :blk &.{};
    };
}

/// **무엇을 편집 중인가.** 버퍼와 입력 경로는 하나지만 확정이 갈 곳은 둘이다(설정 줄 · 서버
/// 칸). 두 벌을 두면 백스페이스·넘침·취소 규칙이 갈리고, 한쪽만 고치는 일이 생긴다.
const EditTarget = enum { none, setting, server_field, password };
var edit_target: EditTarget = .none;
/// 서버 편집 화면에서 지금 치고 있는 칸(`ServerField`).
var srv_edit_field: usize = 0;

/// 지금 편집 중인 설정 줄(그 줄에 숫자를 친다). null 이면 편집 중이 아니다.
var set_edit: ?usize = null;
/// 편집 중인 값의 자릿수 버퍼. **확정 전에는 config 를 안 건드린다** — 중간 값(예: "5")이
/// 그대로 적용되면 스크롤백이 5줄로 줄었다가 돌아오는 것이 화면에 보인다.
var set_edit_buf: [64]u8 = undefined;

/// 편집 중인 칸에 보일 글자 = **확정 버퍼 + 조합 중 글자 + 캐럿**.
///
/// **조합을 빼먹으면 한글이 안 보인다.** IME 는 확정 전까지 `setComposingText` 로만 알리고
/// (`maru_mobile_set_preedit` 이 그것을 받는다), 그 버퍼를 안 그리는 칸은 치는 동안 화면이 멈춘
/// 것처럼 보인다 — 실제로 그것을 그리는 자리는 **터미널 하나뿐**이었고 편집 칸 셋(서버·설정 숫자·
/// 설정 글자)은 각자 같은 줄을 만들면서 조합을 빠뜨렸다(기기 실측 2026-08-20: 한글을 쳐도 칸에
/// 아무것도 안 나왔다). 같은 줄을 세 번 만들면 하나만 고쳐지므로 규칙을 여기 하나로 둔다.
const editing_text_cap = set_edit_buf.len + preedit_buf.len + 4; // +4 = 캐럿(U+258F, 3바이트)
fn editingText(buf: *[editing_text_cap]u8) []const u8 {
    // 버퍼가 두 원본을 다 담으므로 실패할 길이 없다 — `catch` 는 형식상 남긴다(모자라면 치던
    // 값까지 사라지는데, `editing_text_cap` 이 그 경우를 없앤다).
    return std.fmt.bufPrint(buf, "{s}{s}\u{258F}", .{
        set_edit_buf[0..set_edit_len],
        preedit_buf[0..preedit_len],
    }) catch "\u{258F}";
}
var set_edit_len: usize = 0;

/// 지금 편집 중인 값의 길이(테스트·진단용). **한 글자 지우기가 바이트 단위인지 글자 단위인지**를
/// 밖에서 재려면 이 값이 필요하다.
pub fn settingsEditLen() usize {
    return set_edit_len;
}

/// 팝업이 한 번에 그릴 수 있는 항목 수(테스트·진단용).
/// 지금 고른 프리셋의 색인(테스트·진단용). 어느 것과도 안 맞으면 `presetNone()`.
pub fn presetIndexNow() i64 {
    return mobile_config.valueOf(cfg(), "theme.preset");
}
pub fn presetNone() i64 {
    return mobile_config.preset_none;
}

/// 팝업의 그 항목이 **눌릴 수 있게** 그려졌나(테스트·진단용) — rect 가 비면 화면 밖이다.
pub fn settingsPopupItemVisible(i: usize) bool {
    return i < set_item_rects.len and set_item_rects[i].w > 0;
}

/// 팝업이 열려 있나(테스트용). **`settingsPopupItemVisible` 로 대신 묻지 않는다** — 그것은
/// "그 항목이 그려졌나" 이고, 열림 자체를 재려면 이 값이어야 한다.
pub fn settingsPopupOpen() bool {
    return set_open != null;
}

pub fn settingsPopupCap() usize {
    return set_item_rects.len;
}

/// 설정 목록이 지금 얼마나 밀려 있나(px). **관성은 줄 높이보다 작게 움직이는 프레임이 있어**
/// 줄 색인으로는 "흐르고 있다" 를 못 잰다.
pub fn settingsScrollPx() u32 {
    return set_sa.offset_y_px;
}

/// 지금 눌린 것으로 **표시되는** 키(테스트용). 눌림은 색만 바꿔서 quad 수로는 안 잡힌다 —
/// hover 가 없는 화면에서 이 표시가 "닿았다" 를 알리는 유일한 신호라(§2.4) 직접 물어야 한다.
pub fn keybarPressed() ?usize {
    return kb_pressed;
}

/// 본문 격자의 줄 수(테스트용). 앱 바·키바가 자리를 먹으면 이 값이 줄어야 한다 — 안 줄면
/// 화면 밖에 줄이 그려지거나 마지막 줄이 바 밑에 깔린다.
pub fn bodyRowCount() u16 {
    return body_rows;
}

/// 터미널 앱 바의 뒤로가기 한가운데(테스트용). **좌표를 테스트가 따로 적지 않는다** — 배치가
/// 바뀌면 테스트만 맞고 화면은 틀리게 된다. 폭이 0 이면 안 그려진 것이다.
pub fn terminalBackCenter() struct { x: f32, y: f32 } {
    return .{ .x = term_back_rect.x + term_back_rect.w / 2, .y = term_back_rect.y + term_back_rect.h / 2 };
}

/// 이 점이 뒤로가기 위인가(테스트용). **테스트가 사각형을 손으로 근사하지 않는다** — 경계에서
/// 어긋나 "안 눌러야 할 자리가 눌렸다" 로 잘못 읽힌다(실제로 그렇게 짰다가 걸렀다).
pub fn terminalBackHitAt(x: f32, y: f32) bool {
    return term_back_rect.w > 0 and setHit(term_back_rect, x, y);
}

/// 그 점이 **앱 바의 어느 버튼**에든 닿나(테스트용). 테스트가 자리를 다시 계산하면 버튼을
/// 하나 더할 때 조용히 어긋난다 — 자판 버튼을 넣다 실제로 그랬다.
pub fn terminalChromeHitAt(x: f32, y: f32) bool {
    if (terminalBackHitAt(x, y)) return true;
    if (term_kb_rect.w > 0 and setHit(term_kb_rect, x, y)) return true;
    if (term_disc_rect.w > 0 and setHit(term_disc_rect, x, y)) return true;
    if (term_copy_rect.w > 0 and setHit(term_copy_rect, x, y)) return true;
    return false;
}

/// 그 뒤로가기가 지금 눌린 것으로 그려지나(테스트용 — 눌림은 색만 바꿔 quad 수로 안 잡힌다).
pub fn terminalBackPressed() bool {
    return term_back_pressed;
}

pub fn settingsRows() []const mobile_config.Row {
    return mobile_config.rows;
}

pub export fn maru_mobile_scrollback_lines() u32 {
    const core = &(term_core orelse return 0);
    return @intCast(core.maxScrollback());
}

pub export fn maru_mobile_set_preedit(ptr: [*]const u8, len: usize) void {
    // **UTF-8 경계에서 자른다.** 바이트 수로만 자르면 조합 중 한글이 반토막 나고, 그리는
    // 쪽의 `Utf8View.init` 이 실패해 **조합 문자열 전체가 사라진다** — 화면이 멈춘 것처럼 보인다.
    var n = @min(len, preedit_buf.len);
    // 마지막 글자의 **시작 바이트**를 찾는다(이 자리를 따로 두어야 한다 — 예전에는 `n` 자체를
    // 거슬러 올려 놓고 온전한 글자를 **다시 안 늘렸다**. 그래서 조합 중 한글이 늘 첫 바이트만
    // 남아 깨진 UTF-8 이 됐고, 그리는 쪽 `Utf8View.init` 이 실패해 **조합 문자열이 통째로
    // 사라졌다** — "Q가" 를 넣으면 Q 까지 안 보였다, 실측).
    var start = n;
    while (start > 0 and (ptr[start - 1] & 0xC0) == 0x80) start -= 1; // continuation byte 위로
    if (start > 0) {
        const lead = ptr[start - 1];
        const need: usize = if (lead & 0x80 == 0) 1 else if (lead & 0xE0 == 0xC0) 2 else if (lead & 0xF0 == 0xE0) 3 else 4;
        // 그 글자가 버퍼에 다 안 들어가면 **통째로** 버린다. 다 들어가면 n 은 그대로다.
        if (start - 1 + need > n) n = start - 1;
    }
    @memcpy(preedit_buf[0..n], ptr[0..n]);
    preedit_len = n;
}

/// 코어가 만들었지만 **모바일에 아직 가져갈 사람이 없는 것**들을 치운다. 데스크톱은 매
/// 프레임 이걸 한다 — 답은 PTY 로 흘리고(`app/runtime.zig`·`app/pty_reader.zig`), 셸
/// 이벤트는 소비한 뒤 비운다(`clearShellEvents`).
///
/// 안 치우면 이렇게 된다(둘 다 실측):
///   * **답**(DA·DSR·커서 위치)은 쌓이기만 한다 — 질의 3000번에 15005바이트.
///   * **셸 이벤트**(OSC 133)는 상한 4096 에 닿고 그 뒤로 전부 드롭되며 overflow 가 영원히
///     선다 — 프롬프트 사이클 2000회면 닿는다. 코어 주석이 "프레임마다 drain 되면 닿을 일이
///     없다" 고 전제하는 바로 그 자리다.
///
/// 답을 버리는 것은 **의미의 손실**이라 신호를 남기고(§5), 셸 이벤트는 관측용이라 조용히
/// 비운다. 소비자가 생기면(에이전트 상태·프롬프트 표시) 비우기 **전에** 읽으면 된다.
fn drainUnconsumed(core: *terminal.core.TerminalCore) void {
    if (core.pendingResponse().len > 0) {
        setLastError("response_dropped");
        core.clearResponse();
    }
    if (core.shellEvents().len > 0) core.clearShellEvents();
}

/// 원격 출력(SSH)을 화면에 넣는다. host 가 `maru_mobile_ssh_screen_*` 에서 가져온 바이트를
/// 그대로 준다 — **바이트만 오간다**(§3).
///
/// 반환값은 **코어에 닿은 누적 바이트**다. 안 늘면 안 닿은 것이고, 왜인지는 `last_error` 에 있다
/// (§5 — 조용히 실패하지 않는다).
///
/// **답(DSR·DA 등)은 여기서 안 버린다.** 원격이 물어본 것이라 돌려보내야 하고, 그 자리가
/// `maru_mobile_take_response` 다. 로컬 셸이 없던 시절에는 버리고 이름만 남겼는데(그때는
/// 돌려보낼 상대가 없었다), 이제 상대가 생겼다.
///
/// **어느 세션의 바이트인지는 아직 안 가른다** — 화면이 하나이기 때문이다. 세션이 여럿이 되면
/// 그 라우팅은 서버 목록(S9b)·세션 호스트 부착(S10)이 정한다.
/// 코어가 서기 전에 온 원격 출력. **버리면 세션의 첫 출력이 사라진다** — 첫 프레임에 흘려 넣는다.
var pre_core: [8192]u8 = undefined;
var pre_core_len: usize = 0;

pub export fn maru_mobile_term_write(ptr: [*]const u8, len: usize) usize {
    const core = &(term_core orelse {
        // 아직 화면이 없다 — 첫 프레임까지 들고 있는다.
        if (pre_core_len + len > pre_core.len) {
            setLastError("term_write_before_core");
            return term_written;
        }
        @memcpy(pre_core[pre_core_len..][0..len], ptr[0..len]);
        pre_core_len += len;
        term_written += len;
        return term_written;
    });
    core.write(ptr[0..len]) catch {
        setLastError("term_write_failed");
        return term_written;
    };
    // 셸 이벤트(OSC 133 등)는 모바일이 아직 안 쓴다 — 쌓아 두면 자라기만 한다.
    if (core.shellEvents().len > 0) core.clearShellEvents();
    term_written += len;
    return term_written;
}

/// 등록된 서버 수. **자리가 아니라 개수다** — 빈 번호는 파싱에서 이미 당겨졌다.
pub export fn maru_mobile_server_count() u32 {
    return @intCast(servers().len);
}

/// 그 서버의 문자열 값을 채운다. 자리가 모자라면 **0 이고 아무것도 안 쓴다** — 잘라 주면
/// host 가 반쪽 주소로 붙으러 간다.
pub export fn maru_mobile_server_field(index: u32, field: u32, out: [*]u8, cap: usize) usize {
    const list = servers();
    if (index >= list.len) return 0;
    const srv = list[index];
    const text: []const u8 = switch (field) {
        0 => srv.name,
        1 => srv.host,
        2 => srv.user,
        3 => srv.fingerprint,
        else => return 0,
    };
    if (text.len == 0 or text.len > cap) return 0;
    @memcpy(out[0..text.len], text);
    return text.len;
}

/// 그 서버의 포트. 번호가 틀리면 0 이다 — 0 은 붙을 수 없는 포트라 그대로 오류 신호가 된다.
pub export fn maru_mobile_server_port(index: u32) u32 {
    const list = servers();
    if (index >= list.len) return 0;
    return list[index].port;
}

/// 붙어 달라는 요청을 가져간다. **가져가면 사라진다**(복사·키보드 올리기와 같은 규율).
pub export fn maru_mobile_take_server_connect() u32 {
    const req = ssh_connect_req;
    ssh_connect_req = 0;
    return req;
}

/// 지금 터미널 격자(열·행). **host 가 따로 세면 두 값이 갈린다** — 원격에 알릴 pty 크기는
/// 코어가 실제로 들고 있는 값이어야 하고(그리는 격자와 같아야 한다), 화면이 아직 없으면 0 이다.
pub export fn maru_mobile_term_cols() u32 {
    const core = &(term_core orelse return 0);
    return core.size.cols;
}

pub export fn maru_mobile_term_rows() u32 {
    const core = &(term_core orelse return 0);
    return core.size.rows;
}

/// 코어가 만든 답을 가져간다(**가져가면 사라진다**). host 는 이것을 `maru_mobile_ssh_write` 로
/// 원격에 돌려보낸다 — 안 돌려보내면 커서 위치를 묻는 프로그램이 답을 기다리며 멈춘다.
///
/// **자리가 모자라면 0 이고 아무것도 안 지운다.** 잘라 보내면 원격은 반쪽짜리 시퀀스를 읽고
/// 그때부터 화면이 어긋난다 — config 쓰기가 같은 이유로 같은 규칙을 쓴다.
// ── 컨트롤 축(S10d-2) ────────────────────────────────────────────────────────
//
// host 는 SSH 컨트롤 채널에서 읽은 바이트를 여기 밀어 넣고(`maru_mobile_control_feed`), 우리가
// 만든 요청을 가져가 그 채널로 보낸다(`maru_mobile_take_control_request`). **터미널과 다른
// 흐름이라 이름도 자리도 따로다** — 합치면 ndjson 파서가 사람 화면을 읽게 된다(계약 §4a).

const control = @import("mobile_control.zig");
const screen = @import("mobile_screen.zig");
const stream_flags = maru.session.screen_stream.StyleFlags;

/// 화면이 그릴 세션 목록의 상한. **폰 화면에 그 이상은 안 들어간다** — 넘으면 앞에서부터
/// 담고(파서가 그렇게 한다) 개수로 드러난다.
const max_sessions_shown = 32;

/// 목록 값은 **받은 프레임 안을 가리킨다**(계약 §4a) — 다음 걸음이면 사라지므로 여기 복사한다.
const SessionRow = struct {
    surface_id: i64 = -1,
    title: [64]u8 = @splat(0),
    title_len: usize = 0,
    cwd: [128]u8 = @splat(0),
    cwd_len: usize = 0,
    git: [48]u8 = @splat(0),
    git_len: usize = 0,
    agent: [48]u8 = @splat(0),
    agent_len: usize = 0,
    at_prompt: control.AtPrompt = .unknown,
    focused: bool = false,
    /// 그 줄을 눌러 화면을 열 수 있나 — **runtime id 가 있는 줄만** 눌린다(계약 §3).
    /// 32 소문자 hex 라 자리는 고정이고, 없으면 `has_runtime` 이 거짓이다.
    runtime_id: [32]u8 = @splat(0),
    has_runtime: bool = false,

    fn copyInto(dst: []u8, len: *usize, src: []const u8) void {
        const n = @min(src.len, dst.len - 1);
        @memcpy(dst[0..n], src[0..n]);
        dst[n] = 0;
        len.* = n;
    }

    fn set(self: *SessionRow, s: control.Session) void {
        self.surface_id = s.surface_id;
        self.at_prompt = s.at_prompt;
        self.focused = s.focused;
        // 파서가 이미 32 소문자 hex 만 통과시킨다(§4a) — 여기서는 자리에 옮겨 담기만 한다.
        self.has_runtime = s.runtime_id.len == 32;
        if (self.has_runtime) @memcpy(&self.runtime_id, s.runtime_id);
        copyInto(&self.title, &self.title_len, s.title);
        copyInto(&self.cwd, &self.cwd_len, s.cwd);
        copyInto(&self.git, &self.git_len, s.git_branch);
        // 에이전트는 **한 값으로 붙여** 든다 — 화면이 `kind:state` 로 한 번에 그린다.
        var buf: [48]u8 = undefined;
        const joined = if (s.agent_kind.len == 0)
            ""
        else if (s.agent_state.len == 0)
            std.fmt.bufPrint(&buf, "{s}", .{s.agent_kind}) catch s.agent_kind
        else
            std.fmt.bufPrint(&buf, "{s}:{s}", .{ s.agent_kind, s.agent_state }) catch s.agent_kind;
        copyInto(&self.agent, &self.agent_len, joined);
    }
};

var control_client: control.Client = .{};
var control_rows: [max_sessions_shown]SessionRow = @splat(.{});
var control_row_count: usize = 0;
/// 우리가 만들어 둔 요청(host 가 가져간다). **한 번에 하나**면 충분하다 — 목록 갱신은 답을
/// 받은 뒤에 다시 보낸다.
var control_req: [512]u8 = undefined;
var control_req_len: usize = 0;
/// 목록을 한 번이라도 받았나. **0 개인 것과 아직 안 받은 것은 다르다** — 화면이 "세션이 없다"
/// 와 "아직 모른다" 를 갈라 말해야 한다.
var control_listed: bool = false;

/// 컨트롤 채널이 돌릴 **원격 명령의 종류**. 채널은 하나뿐이고(SSH 코어가 `control` 을 한 자리만
/// 든다) 화면마다 원하는 명령이 다르므로, 축은 "열렸나" 가 아니라 **"무엇을 원하나"** 로
/// 판정한다(계약 §4a "한 채널, 여러 명령").
pub const ControlWant = union(enum) {
    /// 아무것도 안 원한다 — 터미널만 쓰는 접속이 여기다(§4a: 그때는 안 연다).
    none,
    /// 세션 목록. `maru control --stdio` 로 ndjson 을 주고받는다.
    sessions,
    /// 고른 세션의 화면. `maru attach --stream <32-hex>` 로 레코드를 받는다.
    screen: [32]u8,

    fn eql(a: ControlWant, b: ControlWant) bool {
        return switch (a) {
            .none => b == .none,
            .sessions => b == .sessions,
            .screen => |id| switch (b) {
                .screen => |other| std.mem.eql(u8, &id, &other),
                else => false,
            },
        };
    }
};

/// 32 소문자 hex 인가. 원격이 준 값을 명령 줄에 싣기 전에 여기서 거른다.
fn validRuntimeId(id: [32]u8) bool {
    for (id) |b| {
        const is_hex_digit = (b >= '0' and b <= '9') or (b >= 'a' and b <= 'f');
        if (!is_hex_digit) return false;
    }
    return true;
}

/// 지금 **원하는** 것. 그리는 자리가 세운다.
var control_want: ControlWant = .none;
/// 지금 채널이 **돌리고 있는** 것. host 가 열었다고 알릴 때 옮겨 담는다.
var control_open: ControlWant = .none;
/// 열어 달라는 뜻. **take-once 가 아니다** — host 가 가져갔는데 채널이 아직 안 닫혀 못 열면 그
/// 요청이 사라져 축이 영영 안 선다(§4a). 실제로 열렸을 때만 내린다.
var control_open_req: bool = false;
/// **닫아 달라**는 요청(take-once). 원하는 것이 바뀌었거나 아무것도 안 원할 때 세운다 — 열어 둔
/// 채로 두면 배터리·트래픽을 쓰고, 그 비용은 사용자가 안 보는 화면을 위해 치르는 것이다.
var control_close_req: bool = false;
/// 지금 화면이 목록을 보여 주는 자리인가. **프레임마다 판정한다** — 화면 전환은 여러 경로로
/// 일어나고(뒤로가기·팝·연결 실패), 그 전부에 갈고리를 다는 대신 결과만 본다.
var control_screen_active: bool = false;

/// 그리기가 이 값을 세운다(목록 자리에 왔나). **여는 판정을 화면 전환 코드에 흩지 않는다.**
fn noteControlScreen(active: bool) void {
    if (active == control_screen_active) return;
    control_screen_active = active;
    if (active) {
        // **이미 받아 둔 목록이 있으면 다시 안 연다**(§4a) — 다시 열면 그 서버에서 명령이 한 번
        // 더 돌고, 그것은 감사 로그에 남는다.
        if (control_client.state == .waiting_hello and !control_listed) wantControl(.sessions);
    } else if (control_want == .sessions) {
        // 목록 자리를 벗어났다. **세션 화면을 보는 중이면 건드리지 않는다** — 그건 목록 화면이
        // 세운 뜻이 아니다(세션 화면은 자기 자리에서 `wantControl` 을 부른다).
        wantControl(.none);
    }
}

/// **원하는 명령을 바꾼다.** 같은 것을 다시 원하면 아무 일도 안 일어난다 — 그 서버에서 명령이
/// 한 번 더 도는 것을 막는 규칙(§4a)은 그대로다.
///
/// 다른 것을 원하면 **먼저 닫는다.** 같은 채널 번호를 닫히기 전에 다시 열면 상대의 늦은 `close`
/// 가 새 채널로 배달돼 방금 연 것이 이유 없이 닫힌다(SSH §3.4.1 — 적대적 검증이 잡은 실패다).
pub fn wantControl(next: ControlWant) void {
    // **runtime id 는 32 소문자 hex 만이다.** 이 값은 원격이 준 목록에서 오고, 명령 줄에 그대로
    // 실린다 — 셸이 그 줄을 파싱하므로 `;` 나 공백이 들어가면 **원격 CLI 가 거절하기 전에**
    // 다른 명령이 그 서버에서 돈다. 인용으로 막을 수도 있지만, 형식이 정해진 값은 **아예 안
    // 받는 편**이 낫다(경로와 다르다 — 경로는 임의 문자열이라 인용한다).
    switch (next) {
        .screen => |id| if (!validRuntimeId(id)) {
            setLastError("control_runtime_id_invalid");
            return;
        },
        else => {},
    }
    if (control_want.eql(next)) return;
    // **모드가 바뀌면 실어 둔 요청을 버린다.** 그 바이트는 **그 채널** 을 위한 것이라 다른 채널에
    // 실리면 상대가 못 읽는다. 특히 뷰포트 선언(`MRSV` 8바이트)이 ndjson 컨트롤 축에 들어가면
    // 그 축이 통째로 깨진다 — 「세션 화면 → 뒤로」라는 평범한 조작이 그 창을 만든다(적대적
    // 검증 2회차). 반대 방향(ndjson 이 화면 채널로)은 프레임 디코더가 잡음으로 버려 안전하지만,
    // 그 비대칭에 기대지 않는다.
    control_req_len = 0;
    // **보던 화면을 버리지 않고 들고 있는다**(U2a). 예전에는 여기서 놓아서, 다른 세션을 봤다
    // 돌아오면 그 화면이 **빈 화면부터** 다시 쌓였다 — 「덮개로 고른다」는 전환 방식(계획 U0)에서
    // 그 왕복은 평범한 조작이다. 죽은 화면을 살아 있는 것처럼 보이지 않게 하는 것은 그대로다:
    // 되돌린 화면 위로 곧바로 새 프레임이 덮이고, 그 세션이 사라졌으면 attach 가 실패해 화면이
    // 그렇게 말한다. **새 연결**에서는 여전히 통째로 놓는다(`maru_mobile_control_reset`).
    switch (control_want) {
        .screen => |old_id| stashRemoteScreen(old_id),
        else => {},
    }
    control_want = next;
    // 들고 있던 세션이면 그 화면과 선언을 되살린다 — 돌아온 순간 마지막 화면이 보인다.
    switch (next) {
        .screen => |new_id| _ = restoreRemoteScreen(new_id),
        else => {},
    }
    if (control_open.eql(next)) {
        // 이미 그것을 돌리고 있다 — 열 것도 닫을 것도 없다.
        control_open_req = false;
        return;
    }
    if (control_open == .none) {
        // 열린 것이 없다. 원하는 것이 있으면 바로 연다.
        control_open_req = next != .none;
        return;
    }
    // 돌리고 있는 것이 다르다 — 닫고 나서 연다. 열기 요청은 닫힘이 확인된 뒤 host 가 집는다.
    control_close_req = true;
    control_open_req = next != .none;
}

/// 컨트롤 채널이 돌릴 **명령 한 줄**. host 가 그대로 `exec` 에 싣는다.
///
/// **경로는 그 서버 설정에서 온다**(`ssh.server.<n>.maru-path`). 비어 있으면 `maru` 를 그대로
/// 쓴다 — 우리가 설치 경로를 추측해 차례로 시도하지 않는다(계약 §4a).
///
/// **셸이 파싱한다.** `exec` 문자열은 원격 셸이 낱말로 쪼개므로 공백이 든 경로는 **여기서
/// 인용해서** 실어야 한다(안 하면 `/Applications/My Apps/maru` 가 두 낱말이 된다). 작은따옴표
/// 안에서는 작은따옴표만 특별하므로 그것만 `'\''` 로 바꾼다.
pub export fn maru_mobile_control_command(out: [*]u8, cap: usize) usize {
    const path = serverMaruPath();
    // **무엇을 원하는지가 명령을 정한다**(§4a "한 채널, 여러 명령"). 아무것도 안 원하면 만들 것도
    // 없다 — host 가 그 상태에서 열면 그 서버에서 뜻 없는 명령이 하나 돈다.
    var tail_buf: [64]u8 = undefined;
    const tail: []const u8 = switch (control_want) {
        .none => {
            setLastError("control_command_without_want");
            return 0;
        },
        .sessions => " control --stdio",
        // **id 는 이미 32 소문자 hex 다** — `wantControl` 이 유일한 설정자이고 거기서 걸렀다
        // (여기서 또 검사해도 도달할 수 없다: 변이 검사로 확인했다). 그래서 인용 없이 싣는다.
        .screen => |id| std.fmt.bufPrint(&tail_buf, " attach --stream {s}", .{&id}) catch {
            setLastError("control_command_too_long");
            return 0;
        },
    };
    if (path.len == 0) {
        // **자르지 않는다** — 잘린 명령은 다른 명령이다(계약 §4a). 이름을 남겨 host 가 안다.
        const plain_len = "maru".len + tail.len;
        if (plain_len > cap) {
            setLastError("control_command_too_long");
            return 0;
        }
        @memcpy(out[0.."maru".len], "maru");
        @memcpy(out["maru".len..][0..tail.len], tail);
        return plain_len;
    }

    // 작은따옴표 안에서는 작은따옴표만 특별하므로 그것만 `'\''` 로 바꾼다 — 그 한 글자가
    // 네 글자가 된다. 미리 세어 자리가 되는지 보고, 되면 그때 쓴다.
    var quotes: usize = 0;
    for (path) |c| {
        if (c == '\'') quotes += 1;
    }
    const need = 1 + path.len + quotes * 3 + 1 + tail.len;
    if (need > cap) {
        setLastError("control_command_too_long");
        return 0;
    }

    var n: usize = 0;
    out[n] = '\'';
    n += 1;
    for (path) |c| {
        if (c == '\'') {
            @memcpy(out[n..][0..4], "'\\''");
            n += 4;
        } else {
            out[n] = c;
            n += 1;
        }
    }
    out[n] = '\'';
    n += 1;
    @memcpy(out[n..][0..tail.len], tail);
    return n + tail.len;
}

/// 지금 붙어 있는 서버의 `maru-path`(없으면 빈 값). **연결한 그 서버의 것**이어야 한다 —
/// 목록의 첫 줄을 쓰면 다른 기계의 경로로 명령을 만든다.
fn serverMaruPath() []const u8 {
    const list = servers();
    if (list.len == 0) return "";
    // **연결한 그 줄**을 쓴다(`ssh_connecting` 은 그 값을 이미 든다 — 호스트키 승인이 같은 줄에
    // 적힌다). 목록의 첫 줄을 쓰면 다른 기계의 경로로 명령을 만든다.
    const idx = ssh_connecting orelse 0;
    if (idx >= list.len) return "";
    return list[idx].maru_path;
}

/// **그릴 수 있는 논리 크기.** 창 크기에서 시스템이 가리는 만큼과 소프트 키보드를 빼고 배율로
/// 나눈다. host 는 **잰 값을 그대로** 준다 — 보정은 여기서 한 번만 한다.
///
/// **`keyboard_from_bottom` 은 «화면 하단부터» 잰 높이다.** 그래서 하단 inset(제스처 바·3버튼
/// 바·홈 인디케이터)과 **겹친다** — 두 값을 그냥 빼면 그 띠를 두 번 빼서 화면이 그만큼 짧아진다.
/// 그 보정이 예전에는 **두 host 에 각자**(iOS 는 ObjC 에, Android 는 Java 의 `ImeInsets` 에)
/// 적혀 있었다. 같은 사실이 두 자리에 있으면 한쪽만 고쳐진다 — 그래서 여기로 모은다.
///
/// **배율은 host 가 준다**(`scale_milli`): iOS 는 UIKit 이 이미 pt 로 주므로 `1000`,
/// Android 는 px 라 `density/160 × 1000`(실측 2625). 그 차이가 이 함수의 유일한 플랫폼 갈래다.
///
/// 하한은 **1** 이다 — 0 을 내보내면 격자가 0 칸이 되어 그리는 쪽이 통째로 죽는다.
pub export fn maru_mobile_available_logical(
    extent_w: u32,
    extent_h: u32,
    inset_top: u32,
    inset_bottom: u32,
    inset_left: u32,
    inset_right: u32,
    keyboard_from_bottom: u32,
    scale_milli: u32,
    out_w: *u32,
    out_h: *u32,
) void {
    // **키보드가 하단 inset 을 덮는 만큼만 더 뺀다.** 키보드가 그 띠보다 작거나 없으면 0 이다.
    const keyboard_over_inset = keyboard_from_bottom -| inset_bottom;
    const w_px = extent_w -| inset_left -| inset_right;
    const h_px = extent_h -| inset_top -| inset_bottom -| keyboard_over_inset;
    const scale = if (scale_milli == 0) 1000 else scale_milli;
    out_w.* = @max(1, w_px * 1000 / scale);
    out_h.* = @max(1, h_px * 1000 / scale);
}

// ── 컨트롤 축의 «정책» 은 여기 산다 ────────────────────────────────────────────────
//
// **순서·가드·분류·마감이 전부 정책이다.** 예전에는 그 넷이 두 host 의 C/ObjC tick 안에
// 흩어져 있었고, 그래서 ⑴ 두 플랫폼이 갈릴 수 있었고 ⑵ **헤드리스로 잴 수가 없었다**.
// 실제로 iOS tick 이 **열기를 닫기보다 먼저** 해서, `wantControl` 이 둘을 함께 세운 tick 에
// 채널이 마침 닫혀 있으면 **열고 그 자리에서 닫았다** — 컨트롤 채널이 opening↔closed 로
// 무한히 진동하고 아무 세션도 안 떴다(실기 2026-09-04). 그 회차 내내 판정자는 초록이었다.
//
// 그래서 tick 마다 **행동을 하나만** 돌려준다 — 「열고 나서 닫기」는 **표현 자체가 없다**
// (가드로 막는 것과 다르다). host 에 남는 것은 **네이티브뿐**이다: 펌프 호출과 로그.
//
// 마감도 여기 있다. host 에 있을 때는 `CACurrentMediaTime()` 이 박혀 있어 **못 쟀다** —
// 시각을 인자로 받으면 판정자가 넣는다(이 저장소의 "답이 기계 속도에 달린 판정" 규율).

/// 이번 tick 에 host 가 할 일. **하나뿐이다.**
pub const ControlAction = enum(c_int) {
    /// 아무것도.
    none = 0,
    /// 컨트롤 채널을 닫는다(`maru_ssh_pump_close_control`).
    close = 1,
    /// 컨트롤 채널을 연다(`maru_mobile_control_command` 가 만든 명령으로).
    open = 2,
};

/// 열기 재시도 마감(ms). 「아직 때가 아니다」(`NOT_READY`)가 이만큼 이어지면 포기하고 화면이
/// 말한다. 근거는 [컨트롤 플레인 §4a](../../../docs/control-plane.md)가 소유한다.
const control_retry_deadline_ms: u64 = 5000;
/// 연 뒤 첫 답을 기다리는 마감(ms). 같은 눈금이다.
const control_reply_deadline_ms: u64 = 5000;

// **`0` 을 「없음」 으로 쓰지 않는다.** 시각 0 은 멀쩡한 값이고, 그것을 표식으로 쓰면 그 순간에
// 시작한 마감이 매 tick 다시 시작해 **영영 안 끝난다**. host 에 있을 때는 `CACurrentMediaTime()`
// 이 0 이 될 일이 없어 안 드러났는데, 시각을 넣는 판정자가 곧바로 잡았다 — 마감을 코어로 올린
// 값이 이것이다.
/// `NOT_READY` 가 처음 난 시각. `null` 이면 재시도 중이 아니다.
var control_retry_since_ms: ?u64 = null;
/// 열기가 성공한 시각. `null` 이면 기다리는 답이 없다.
var control_opened_at_ms: ?u64 = null;

/// **이번 tick 에 무엇을 할까.** host 는 `ssh_ready`(SSH 세션이 READY 인가)·`channel_state`
/// (`MARU_SSH_CONTROL_*`)·단조 시각을 주고, 돌려받은 행동 **하나**를 그대로 실행한다.
///
/// **닫기가 먼저다**(§4a — 한 번에 control 하나). 열기는 채널이 비었을 때만 나간다.
pub export fn maru_mobile_control_tick(ssh_ready: c_int, channel_state: u32, now_ms: u64) c_int {
    // 답을 기다리다 시한을 넘겼나 — 행동과 무관하게 매 tick 본다.
    if (control_opened_at_ms) |opened| {
        if (control_client.state == .waiting_hello and
            now_ms -| opened > control_reply_deadline_ms)
        {
            maru_mobile_control_timeout();
            control_opened_at_ms = null;
        }
    }
    if (takeControlClose() != 0) {
        control_opened_at_ms = null;
        return @intFromEnum(ControlAction.close);
    }
    // **열 수 있을 때만 집는다.** 이 요청은 take-once 가 아니다 — 채널이 아직 안 닫혔는데
    // 가져가면 그 뜻이 사라져 축이 영영 안 선다.
    if (ssh_ready == 0) return @intFromEnum(ControlAction.none);
    if (channel_state != ssh_control_none and channel_state != ssh_control_closed)
        return @intFromEnum(ControlAction.none);
    if (takeControlOpen() == 0) return @intFromEnum(ControlAction.none);
    return @intFromEnum(ControlAction.open);
}

/// 열기의 결과를 알린다. **「아직 때가 아니다」와 「졌다」를 여기서 가른다** — 그 분류가 host 에
/// 있으면 두 플랫폼이 갈리고 마감도 각자 세게 된다.
///
/// `rc` 는 `maru_ssh_pump_open_control` 이 돌려준 값이다. `MARU_SSH_ERR_NOT_READY`(-7)는
/// 이전 채널이 닫히는 중이라는 뜻이라 **조금 뒤에 다시 부르면 된다** — 그것을 딱딱한 실패로
/// 접으면 「열자」는 뜻이 사라져 그 화면이 영영 「받는 중」이 된다(실측 2026-09-03).
///
/// **왜 졌는지를 갈라 돌려준다** — `0` 아직 간다 / `1` 마감을 넘겨 포기 / `2` 딱딱한 실패.
/// 뭉뚱그리면 로그가 「졌다」만 말하고, 그러면 사용자가 고칠 자리(예: 그 기계에 `maru` 가 없다)를
/// 못 가른다 — 이 저장소가 그 모양으로 여러 번 시간을 버렸다.
pub export fn maru_mobile_control_note_open(rc: c_int, now_ms: u64) c_int {
    if (rc == ssh_err_not_ready) {
        const since = control_retry_since_ms orelse blk: {
            control_retry_since_ms = now_ms;
            break :blk now_ms;
        };
        if (now_ms -| since > control_retry_deadline_ms) {
            control_retry_since_ms = null;
            maru_mobile_control_open_failed();
            return 1; // 포기했다
        }
        maru_mobile_control_open_retry();
        return 0;
    }
    control_retry_since_ms = null;
    if (rc != 0) {
        maru_mobile_control_open_failed();
        return 2; // 딱딱한 실패 — 마감과 다른 이유다
    }
    control_opened_at_ms = now_ms;
    return 0;
}

/// 열어 둔 명령이 그냥 끝났다 — 시한을 더 기다리지 않는다(계약 §4a).
pub export fn maru_mobile_control_note_exit_at(code: u32) void {
    control_opened_at_ms = null;
    maru_mobile_control_note_exit(code);
}

/// 열린 명령의 답을 아직 기다리는가 — host 가 종료 코드를 볼 자격이 있나.
pub export fn maru_mobile_control_awaiting_reply() c_int {
    return if (control_opened_at_ms != null) 1 else 0;
}

/// 판정용 — 마감 상태를 처음으로 되돌린다.
pub fn resetControlDeadlinesForTest() void {
    control_retry_since_ms = null;
    control_opened_at_ms = null;
}

// **이 셋의 단일 출처는 `mobile_host_abi.h` 다.** 여기 베낀 값이 갈리면 정책이 조용히 틀린
// 상태를 본다 — `tests/mobile_control_policy_boundary.zig` 가 헤더 원문과 대조한다.
const ssh_control_none: u32 = 0;
const ssh_control_closed: u32 = 4;
const ssh_err_not_ready: c_int = -7;

/// 「열자」는 뜻을 집는다. **`maru_mobile_control_tick` 안에서만 쓴다** — `export` 를 뺀 것은
/// host 가 이것과 `takeControlClose` 를 **제 순서로** 부르다 「열고 그 자리에서 닫기」를 만든
/// 적이 있기 때문이다(실기 2026-09-04). 순서는 이제 코어가 정한다.
pub fn takeControlOpen() c_int {
    if (!control_open_req) return 0;
    // **가져간 순간 그것이 돌고 있는 것이 된다.** host 는 채널이 열릴 수 있을 때만 이걸 부르므로
    // (계약 §4a) 여기서 옮겨 담아야 "이미 그것을 돌리고 있다" 판정이 성립한다. 열기가 지면
    // `maru_mobile_control_open_failed` 가 되돌린다.
    control_open = control_want;
    control_open_req = false;
    return 1;
}

/// 「닫자」는 뜻을 집는다. **`maru_mobile_control_tick` 안에서만 쓴다**(위 주석).
pub fn takeControlClose() c_int {
    if (!control_close_req) return 0;
    // 닫으라고 했으면 그 채널은 곧 사라진다 — 돌고 있는 것을 비워야 다음 명령을 열 수 있다.
    control_open = .none;
    control_close_req = false;
    return 1;
}

/// host 가 컨트롤 채널에서 읽은 바이트를 넣는다. **먹은 만큼**을 돌려준다(0 이면 배압이 아니라
/// 축이 꺼진 것이다 — 코어와 달리 이 층은 버퍼가 없다).
pub export fn maru_mobile_control_feed(bytes: [*]const u8, len: usize) usize {
    // **소비자는 원하는 것이 정한다**(§4a). 화면을 원할 때 그 레코드를 ndjson 파서에 먹이면
    // 파서가 그것을 잡음으로 세다가 축을 꺼 버린다 — 그러면 목록으로 돌아와도 안 선다.
    if (control_want == .screen) return feedRemoteScreen(bytes[0..len]);
    var off: usize = 0;
    while (off < len) {
        var consumed: usize = 0;
        const step = control_client.feed(bytes[off..len], &consumed);
        if (consumed == 0) break;
        off += consumed;
        if (step.state == .ready and control_req_len == 0 and !control_listed) {
            // 축이 서면 **바로 목록을 묻는다** — 사용자가 화면에 있는 동안 기다리게 두지 않는다.
            requestSessions();
        }
        if (step.frame) |frame| absorbFrame(frame);
    }
    return off;
}

/// 원격 화면 조립기. **컨트롤 축과 다른 소비자**라 자리도 따로 든다(§4a).
var remote_screen: ?screen.Screen = null;

fn feedRemoteScreen(bytes: []const u8) usize {
    const s = &(remote_screen orelse blk: {
        remote_screen = screen.Screen.init(term_allocator);
        break :blk remote_screen.?;
    });
    return s.feed(term_allocator, bytes);
}

/// 원격 화면을 놓는다. **새 연결일 때다** — 남겨 두면 죽은(또는 다른 기계의) 세션 화면을
/// 살아 있는 것처럼 보여 준다. 세션을 «바꿀» 때는 이것이 아니라 `stashRemoteScreen` 이다(U2a).
fn dropRemoteScreen() void {
    if (remote_screen) |*s| s.deinit(term_allocator);
    remote_screen = null;
    // **다음에 열면 다시 선언한다.** 채널이 바뀌면 host 쪽 슬롯도 새것이라, 안 지우면 새 슬롯이
    // 선언 없이 남아 세션이 안 줄어든다.
    remote_declared_cols = 0;
    remote_declared_rows = 0;
}

/// 봤던 세션 하나의 상태(U2a). **화면과 그 세션에 대고 선언한 격자**를 함께 든다 — 돌아왔을 때
/// 격자를 다시 선언하지 않으려면 둘이 같이 살아 있어야 한다.
const HeldSession = struct {
    id: [32]u8,
    screen: screen.Screen,
    declared_cols: u16,
    declared_rows: u16,
    /// **마지막으로 본 순번**(U2b). 자리가 모자랄 때 누구를 버릴지 이 값이 정한다 — 시계가 아니라
    /// 순번이라 기계 속도에 안 흔들린다.
    seen: u64,
};

/// 마지막으로 본 순번을 매기는 자리. 넘칠 걱정은 없다(u64 이고 화면 전환마다 하나씩 는다).
var held_seen_counter: u64 = 0;

/// 폰이 동시에 들 수 있는 세션 수. **자리를 미리 잡지 않는다** — 조립기 하나가 이미 16 MiB
/// 상한을 들므로(그 구조체의 `max_image_bytes`) 수를 크게 잡으면 그만큼이 상주 가능 메모리다.
/// 넘칠 때의 버림 규칙은 U2b 가 정한다.
const max_held_sessions: usize = 4;
var held_sessions: [max_held_sessions]?HeldSession = @splat(null);

/// 지금 보던 화면을 **버리지 않고 들고 있는다**(U2a). 세션을 바꿀 때 부른다 — 그래야 돌아왔을 때
/// 빈 화면부터 다시 쌓지 않는다. 자리가 없으면 그냥 버린다(U2b 가 버림 규칙을 정한다).
fn stashRemoteScreen(id: [32]u8) void {
    const held = remote_screen orelse return;
    remote_screen = null;
    held_seen_counter += 1;
    const entry: HeldSession = .{
        .id = id,
        .screen = held,
        .declared_cols = remote_declared_cols,
        .declared_rows = remote_declared_rows,
        .seen = held_seen_counter,
    };
    remote_declared_cols = 0;
    remote_declared_rows = 0;

    // 같은 세션이 이미 있으면 그 자리를 덮는다 — 둘을 들면 어느 쪽이 최신인지 알 수 없다.
    for (&held_sessions) |*slot| {
        if (slot.*) |*existing| {
            if (!std.mem.eql(u8, &existing.id, &id)) continue;
            existing.screen.deinit(term_allocator);
            slot.* = entry;
            return;
        }
    }
    for (&held_sessions) |*slot| {
        if (slot.* != null) continue;
        slot.* = entry;
        return;
    }

    // **자리가 모자라면 «가장 오래 안 본 것» 을 버린다**(U2b). 예전에는 방금 보던 것을 버렸는데,
    // 그건 거꾸로다 — 방금 본 세션이야말로 돌아올 가능성이 가장 높다.
    var oldest: usize = 0;
    for (held_sessions, 0..) |slot, i| {
        const candidate = slot orelse continue;
        const current = held_sessions[oldest] orelse {
            oldest = i;
            continue;
        };
        if (candidate.seen < current.seen) oldest = i;
    }
    if (held_sessions[oldest]) |*victim| victim.screen.deinit(term_allocator);
    held_sessions[oldest] = entry;
}

/// 들고 있던 세션이면 그 화면을 되돌린다(U2a). 돌아왔다는 뜻이므로 **선언한 격자도 함께** 살린다
/// — 안 그러면 같은 값을 다시 선언하지 못해(중복 선언은 걸러진다) 세션이 안 좁아진다.
fn restoreRemoteScreen(id: [32]u8) bool {
    for (&held_sessions) |*slot| {
        const entry = if (slot.*) |value| value else continue;
        if (!std.mem.eql(u8, &entry.id, &id)) continue;
        slot.* = null;
        remote_screen = entry.screen;
        remote_declared_cols = entry.declared_cols;
        remote_declared_rows = entry.declared_rows;
        return true;
    }
    return false;
}

/// 들고 있던 것을 전부 놓는다. **새 연결**이 그 자리다 — 다른 기계일 수 있다.
fn dropHeldSessions() void {
    for (&held_sessions) |*slot| {
        if (slot.*) |*entry| entry.screen.deinit(term_allocator);
        slot.* = null;
    }
}

/// 판정용 — 화면 프레임의 wire 모양(`magic | kind | 예약 3 | len LE`). 판정자가 이 값을 손으로
/// 다시 적으면 코덱이 바뀔 때 갈린다.
pub const screen_frame_magic = screen.magic;
pub const ScreenFrameKind = screen.Kind;

/// 판정용 — 지금 보고 있는 화면이 프레임을 받은 적이 있는가(빈 화면인지 아닌지).
pub fn activeScreenHasFrames() bool {
    const s = remote_screen orelse return false;
    return s.snapshots != 0 or s.deltas != 0;
}

/// 판정용 — 지금 원하는 control 의 갈래. **화면 스택만 보면 「나갔는가」를 못 잰다** —
/// 목록으로 돌아왔는데 그 서버에서 `attach` 가 계속 도는 상태가 실기에서 실제로 났다
/// (2026-09-04 — 나온 뒤에도 host 가 `observers=1 50x27` 이었다).
pub fn controlWantKind() std.meta.Tag(ControlWant) {
    return std.meta.activeTag(control_want);
}

/// 판정용 — 원격 화면의 뒤로가기 한가운데(안 그려졌으면 `null`).
pub fn remoteBackCenter() ?struct { x: f32, y: f32 } {
    if (remote_back_rect.w <= 0) return null;
    return .{ .x = remote_back_rect.x + remote_back_rect.w / 2, .y = remote_back_rect.y + remote_back_rect.h / 2 };
}

/// 판정용 — 그 세션을 들고 있는가.
/// 판정용 — 지금 «그 세션» 의 화면을 원하는가. `controlWantKind()` 는 갈래만 말하므로,
/// 「누른 줄과 열린 세션이 같은가」는 이 값으로만 잰다.
pub fn wantsScreen(id: [32]u8) bool {
    return switch (control_want) {
        .screen => |cur| std.mem.eql(u8, &cur, &id),
        else => false,
    };
}

pub fn holdsSession(id: [32]u8) bool {
    for (held_sessions) |slot| {
        const entry = slot orelse continue;
        if (std.mem.eql(u8, &entry.id, &id)) return true;
    }
    return false;
}

/// 판정용 — 지금 들고 있는 세션 수.
pub fn heldSessionCount() usize {
    var n: usize = 0;
    for (held_sessions) |slot| {
        if (slot != null) n += 1;
    }
    return n;
}

/// **채널에 실어 host 가 가져간** 마지막 선언(S11-6). 0 은 「아직 안 실었다」다.
///
/// **「가져갔다」는 「닿았다」가 아니다.** 그 뒤 `maru_ssh_pump_write_control` 이 실패하면 선언은
/// 사라지는데 여기에는 남는다 — 같은 값이 다시 와도 걸러져 그 화면에서는 다시 안 간다. 채널이
/// 아주 끊기면 화면을 놓으면서 이 값도 0 이 되어 다음에 다시 선언하므로(`dropRemoteScreen`)
/// 남는 창은 「연결은 살아 있는데 그 write 만 실패」뿐이다. 좁히기가 늦어질 뿐 화면이 깨지지는
/// 않아 지금은 그대로 둔다 — 고치려면 host 가 write 결과를 되알려야 한다(적대적 검증 5회차).
var remote_declared_cols: u16 = 0;
var remote_declared_rows: u16 = 0;

/// 판정용 — 지금 채널에 실린 선언(없으면 `null`). 「무엇을 알렸나」를 바이트로 본다.
pub fn stagedViewportDeclaration() ?[8]u8 {
    if (control_req_len != 8) return null;
    if (!std.mem.eql(u8, control_req[0..4], "MRSV")) return null;
    var out: [8]u8 = undefined;
    @memcpy(&out, control_req[0..8]);
    return out;
}

/// 판정용 — 채널 모드를 바꾼다(실 SSH 없이 선언 규율만 잰다).
pub fn setControlWantForTest(next: ControlWant) void {
    control_want = next;
}

/// 판정용 — 선언 상태를 초기로 되돌린다.
pub fn resetViewportDeclarationForTest() void {
    remote_declared_cols = 0;
    remote_declared_rows = 0;
    control_req_len = 0;
}

/// 판정용 — 그리기 없이 선언만 시킨다.
pub fn declareViewportForTest(cols: u16, rows: u16) void {
    declareViewport(cols, rows);
}

/// 폰이 그릴 수 있는 격자를 알린다 — `"MRSV" | cols:u16 LE | rows:u16 LE`.
///
/// **창이 아니라 「그리는 격자」를 보낸다**(S11-6). 창 폭으로 선언하면 세션이 폰이 **못 그리는
/// 열까지** 갖게 되어 리사이즈를 하고도 오른쪽이 잘린다.
///
/// **실은 뒤에야 「마지막」이 된다.** 앞서 적어 두면 못 실은 값이 실은 것으로 남아, 같은 값이
/// 다시 와도 걸러져 **영영 안 간다**(CLI 쪽에서 같은 결함을 잡았다). 「실었다」까지가 이 층이
/// 아는 전부다 — 그 뒤 write 실패는 `remote_declared_cols` 머리말이 적은 한계다.
fn declareViewport(cols: u16, rows: u16) void {
    // 화면을 보고 있을 때만 뜻이 있다 — 목록 채널은 ndjson 을 나른다.
    if (control_want != .screen) return;
    if (cols == 0 or rows == 0) return;
    if (cols == remote_declared_cols and rows == remote_declared_rows) return;
    // 아직 host 가 안 가져간 요청이 있으면 덮지 않는다. 다음 프레임에 다시 본다.
    if (control_req_len != 0) return;
    @memcpy(control_req[0..4], "MRSV");
    std.mem.writeInt(u16, control_req[4..6], cols, .little);
    std.mem.writeInt(u16, control_req[6..8], rows, .little);
    control_req_len = 8;
    remote_declared_cols = cols;
    remote_declared_rows = rows;
}

/// 조립된 원격 화면의 상태(0=첫 프레임 대기, 1=선다, 2=껐다). 없으면 0.
pub export fn maru_mobile_remote_screen_state() u32 {
    const s = remote_screen orelse return 0;
    return switch (s.state) {
        .waiting_first => 0,
        .ready => 1,
        .off => 2,
    };
}

/// 받은 덩어리 수(진단용). 상위 16비트=snapshot, 하위 16비트=delta.
pub export fn maru_mobile_remote_screen_frames() u32 {
    const s = remote_screen orelse return 0;
    const snap: u32 = @intCast(@min(s.snapshots, 0xFFFF));
    const delta: u32 = @intCast(@min(s.deltas, 0xFFFF));
    return (snap << 16) | delta;
}

fn requestSessions() void {
    // **광고 안 한 메서드는 안 부른다**(계약 §4a).
    if (!control_client.supports("sessions.list")) return;
    // **조용히 넘기지 않는다.** 요청을 못 만들면 목록이 영영 안 오는데, 이름이 없으면 그 이유를
    // 기기에서 알 길이 없다(그 부류를 이 저장소가 여러 번 겪었다).
    const req = control_client.writeRequest(&control_req, "sessions.list", null) catch |e| {
        setLastError(@errorName(e));
        return;
    };
    control_req_len = req.len;
}

fn absorbFrame(frame: []const u8) void {
    var parsed: [max_sessions_shown]control.Session = undefined;
    const n = control.parseSessions(frame, &parsed);
    // **응답이 아닌 프레임(알림 등)은 목록을 안 지운다.** 지우면 알림 하나에 화면이 빈다.
    if (n == 0 and control.jsonValueField(frame, "result") == null) return;
    // **목록이 짧아지면 스크롤을 접는다**(적대적 검증 1회차). `sess_max_scroll` 은 그리면서
    // 재므로 이 프레임에는 아직 옛 값이고, 그 사이에 밀어 둔 자리가 내용보다 아래면 **빈 곳을
    // 보고 있게 된다** — 사용자에게는 「목록이 사라졌다」로 보인다. 늘어날 때는 문제가 없다.
    if (n < control_row_count) sess_sa.reset();
    for (parsed[0..n], 0..) |s, i| control_rows[i].set(s);
    control_row_count = n;
    control_listed = true;
}

/// 우리가 만든 요청을 가져간다. **가져가면 사라진다**(take-once — 모바일 ABI 의 규약).
pub export fn maru_mobile_take_control_request(out: [*]u8, cap: usize) usize {
    if (control_req_len == 0) return 0;
    if (control_req_len > cap) {
        setLastError("control_request_too_large");
        return 0;
    }
    @memcpy(out[0..control_req_len], control_req[0..control_req_len]);
    const n = control_req_len;
    control_req_len = 0;
    return n;
}

/// host 가 시한을 넘겼다고 알린다(계약 §4a — 5초). **시계는 이 층에 없다.**
pub export fn maru_mobile_control_timeout() void {
    control_client.timedOut();
}

/// host 가 채널을 못 열었다고 알린다. **소켓은 이 층에 없다.**
///
/// 안 알리면 화면은 `listed` 가 거짓인 채로 남아 **영영 "받는 중"** 을 보인다 — 실패를 아는 쪽이
/// host 뿐이라 그렇다. 계약 §4a 가 "실패하면 그 화면에서 말한다" 인 이유가 이것이다.
pub export fn maru_mobile_control_open_failed() void {
    // 못 열었으니 돌고 있는 것이 아니다 — 되돌리지 않으면 다시 시도할 자리가 막힌다.
    control_open = .none;
    control_client.openFailed();
}

/// host 가 **조금 뒤에 다시 부르면 되는** 이유로 못 열었다고 알린다(`err_not_ready`).
///
/// **화면에 실패를 말하지 않는다** — 실패가 아니라 아직 때가 아닌 것이다. 대신 「열자」는 뜻을
/// 되돌려 다음 tick 이 다시 집게 한다. 이것이 없으면 뜻은 `take_control_open` 이 이미 가져가서
/// 사라지고, 그 화면은 **영영 「받는 중」** 으로 남는다.
///
/// 실측으로 겪은 자리(2026-09-03, 시뮬레이터): 세션 화면을 열 때 이전 컨트롤 채널이 아직 닫히는
/// 중이라 `control_closing` 이 났고, host 가 그것을 딱딱한 실패로 접어 축이 다시는 안 섰다.
pub export fn maru_mobile_control_open_retry() void {
    control_open = .none;
    control_open_req = control_want != .none;
}

/// host 가 **원격 명령이 그냥 끝났다**고 알린다(계약 §4a). `code` 는 그 종료 코드다.
///
/// 시한을 기다리는 것과 다르다 — 답할 것이 이미 죽었으므로 화면이 **고칠 자리**를 말할 수 있다.
pub export fn maru_mobile_control_note_exit(code: u32) void {
    control_client.commandFailed(code);
}

/// 컨트롤 축 상태(0=hello 대기, 1=선다, 2=껐다).
pub export fn maru_mobile_control_state() u32 {
    return switch (control_client.state) {
        .waiting_hello => 0,
        .ready => 1,
        .off => 2,
    };
}

/// 왜 껐나(`MARU_MOBILE_CONTROL_OFF_*`). 화면이 사용자에게 할 말을 고르는 자리다.
pub export fn maru_mobile_control_off_reason() u32 {
    return switch (control_client.off_reason) {
        .none => 0,
        .hello_timeout => 1,
        .too_much_noise => 2,
        .protocol_mismatch => 3,
        .frame_too_large => 4,
        .open_failed => 5,
        .command_failed => 6,
    };
}

/// 지금 아는 세션 수. **아직 안 받았으면 0 이지만 `listed` 가 거짓이다**(아래).
pub export fn maru_mobile_control_session_count() u32 {
    return @intCast(control_row_count);
}

/// 목록을 한 번이라도 받았나. "세션이 없다" 와 "아직 모른다" 는 화면에서 다른 말이다.
pub export fn maru_mobile_control_listed() c_int {
    return if (control_listed) 1 else 0;
}

/// 세션이 새 연결에서 다시 시작한다. **끊겼다 붙으면 목록도 축도 처음부터**다 — 남겨 두면
/// 죽은 세션을 살아 있는 것처럼 보여 준다.
pub export fn maru_mobile_control_reset() void {
    // 새 연결이면 원하는 것도 돌고 있는 것도 처음부터다 — 남겨 두면 옛 세션의 화면을 열려 한다.
    control_want = .none;
    control_open = .none;
    // **요청도 함께 비운다.** 이걸 빼면 원하는 것이 없는데 열기 요청만 살아남아, host 가 그것을
    // 집고 `control_command` 가 0 을 답한다(뜻 없는 열기 한 번 + `control_command_without_want`).
    control_open_req = false;
    control_close_req = false;
    // **마감도 처음부터다.** 남기면 새 연결의 첫 열기가 옛 연결의 재시도 시각을 이어받아
    // 곧바로 「포기」로 접힌다.
    control_retry_since_ms = null;
    control_opened_at_ms = null;
    dropRemoteScreen();
    // **들고 있던 세션도 전부 놓는다**(U2a). 새 연결은 다른 기계일 수 있고, 그러면 그 화면들은
    // 남의 것이다 — runtime id 가 같아도 같은 세션이라는 보장이 없다.
    dropHeldSessions();
    control_client = .{};
    control_row_count = 0;
    // 목록이 통째로 사라졌다 — 밀어 둔 자리를 남기면 다음 목록이 엉뚱한 데서 시작한다.
    sess_sa.reset();
    sess_touch.cancel();
    control_req_len = 0;
    control_listed = false;
}

pub export fn maru_mobile_take_response(out: [*]u8, cap: usize) usize {
    const core = &(term_core orelse return 0);
    const pending = core.pendingResponse();
    if (pending.len == 0) return 0;
    if (pending.len > cap) {
        setLastError("response_too_large");
        return 0;
    }
    @memcpy(out[0..pending.len], pending);
    core.clearResponse();
    return pending.len;
}

pub export fn maru_mobile_input(ptr: [*]const u8, len: usize) u32 {

    // **밀린 화면이 있으면 글자는 셸로 안 간다.** 설정을 열어도 소프트 키보드는 떠 있으므로
    // (§5.2 — 앱이 내리지 않는다) 여기서 안 막으면 사용자가 **안 보이는 셸에 타이핑**하게 된다.
    // 화면에 아무 반응이 없어 잃은 것도 모른다. 설정에 입력 칸이 생기면(검색) 그때 그쪽으로
    // 라우팅한다 — 지금은 받을 곳이 없으니 안 보낸다.
    //
    // **밀린 화면에서도 받는 자리가 생겼다.** 설정의 숫자 줄을 누르면 그 줄이 입력 대상이 되고
    // 친 숫자가 거기로 간다 — 그전에는 키보드가 떠 있는데 글자를 버리고 있었다("키보드는 있는데
    // 아무것도 안 써지는" 상태). 받을 곳이 없을 때만 버리고, 그때는 **신호를 남긴다**(§5).
    if (screenTop() != .terminal) {
        // 서버 칸도 같은 입력 경로다(버퍼·백스페이스·넘침 규칙이 하나여야 갈리지 않는다).
        if (edit_target == .password) {
            // 비밀번호도 같은 버퍼·같은 규칙이다(넘침·글자 단위 지우기). 다른 것은 **안 보인다**
            // 는 것뿐이고, 그것은 그리는 쪽이 정한다.
            editTextInput(ptr[0..len]);
            return @intCast(delivered_len);
        }
        if (edit_target == .server_field) {
            const f: ServerField = @enumFromInt(srv_edit_field);
            if (f == .port) editNumberInput(ptr[0..len]) else editTextInput(ptr[0..len]);
            return @intCast(delivered_len);
        }
        if (set_edit) |i| {
            if (set_items[i].field.kind == .text) editTextInput(ptr[0..len]) else editNumberInput(ptr[0..len]);
            return @intCast(delivered_len);
        }
        setLastError("input_screen_pushed");
        return @intCast(delivered_len);
    }
    // **안 보낼 키는 겉치레도 안 건드린다.** 지우기를 게이트 앞에 두면, 터미널에서 한글을
    // 조합하다 설정을 열고 아무 키나 친 순간 **그 조합이 조용히 사라진다**(돌아오면 없다).
    preedit_len = 0; // 확정됐으니 겉치레를 지운다

    // **닿은 것만 센다.** 반환값이 "코어에 전달한 누적 바이트" 라고 헤더에 적어 놓고,
    // 코어가 없거나 write 가 실패해도 그냥 더하고 있었다 — 그 값으로 입력이 죽은 것을
    // 판정하라고 해 놓고 값이 거짓말을 했다.
    const core = &(term_core orelse {
        setLastError("input_before_core");
        return @intCast(delivered_len);
    });
    snapToBottomOnInput(core);
    // **눌러 둔 수정자가 있으면 첫 글자는 키 경로를 탄다.** 보조 키바에서 Ctrl 을 누르고
    // 소프트 키보드로 `c` 를 치는 것이 이 기능의 실제 쓰임인데, 여기서 안 받으면 Ctrl 이
    // 하드웨어 키보드에서만 듣는다 — 그러면 키바를 만든 이유가 없다.
    //
    // **타이핑한 글자에만 실린다.** 제어문자(ESC·CR…)는 타이핑이 아니라 시퀀스라, 여기에
    // 실으면 `\x1b[2J` 같은 것이 눌러 둔 Ctrl 을 먹고 **ESC 는 문자 키 표에 없어 바이트가
    // 조용히 사라진다**(테스트에서 그렇게 잡혔다).
    if (armed_mods != 0 and len > 0 and ptr[0] >= 0x20 and ptr[0] != 0x7F) {
        // **길이를 먼저 확인하고 자른다.** `ptr` 은 many-item 포인터라 길이가 없어 Zig 이
        // 경계를 못 잡는다 — lead 바이트가 말하는 길이를 그대로 믿고 자르면 host 가 준 버퍼
        // **밖**을 읽는다. 옛 코드는 이 확인을 `utf8Decode` **뒤**에 뒀다.
        const seq_len = std.unicode.utf8ByteSequenceLength(ptr[0]) catch {
            // 이어지는 바이트(0x80~0xBF)나 불가능한 lead. 조용히 흘리면 그 글자가 사라진 채
            // 아무 신호가 없다(§5).
            setLastError("input_bad_utf8_lead");
            armed_mods = 0;
            return @intCast(delivered_len);
        };
        if (seq_len > len) {
            // host 가 글자를 조각으로 넘겼다. 밖을 읽느니 **여기서 멈추고 남긴다**.
            setLastError("input_partial_utf8");
            armed_mods = 0;
            return @intCast(delivered_len);
        }
        const first = std.unicode.utf8Decode(ptr[0..seq_len]) catch {
            setLastError("input_bad_utf8_seq");
            armed_mods = 0;
            return @intCast(delivered_len);
        };
        _ = maru_mobile_key(0, first, 0); // armed 는 그 안에서 소비된다
        if (seq_len >= len) return @intCast(delivered_len);
        return maru_mobile_input(ptr + seq_len, len - seq_len);
    }
    // **개행은 문자가 아니라 Enter 키다.** IME 는 소프트 Return 을 `"\n"` 으로 커밋하는데,
    // 그대로 쓰면 LF 가 나간다 — 터미널은 CR 이고, 그 판단은 `encodeKey` 것이다. 하드웨어
    // Return 은 이미 키 경로로 CR 이 나가므로, 안 가르면 **같은 Enter 가 입력 수단에 따라
    // 다른 바이트**가 된다.
    var rest = ptr[0..len];
    while (std.mem.indexOfAny(u8, rest, "\r\n")) |i| {
        if (i > 0) sendInput(core, rest[0..i]);
        delivered_len += i;
        // CRLF 는 Enter 한 번이다.
        var skip: usize = 1;
        if (rest[i] == '\r' and i + 1 < rest.len and rest[i + 1] == '\n') skip = 2;
        writeKey(core, .enter, .{});
        rest = rest[i + skip ..];
    }
    if (rest.len > 0) {
        sendInput(core, rest);
        delivered_len += rest.len;
    }
    drainUnconsumed(core);
    return @intCast(delivered_len);
}

/// 키를 **코어의 인코더에 태운다**. 예전에는 host 가 `\r`·`0x7F` 를 손으로 적어 넣었는데,
/// 그러면 DECCKM(커서키 모드)·수정자(Ctrl·Alt)·kitty 프로토콜·application keypad 가 전부
/// 빠진다 — 그 지식은 전부 `core.encodeKey` 안에 있다.
///
/// 숫자 표의 단일 출처는 `mobile_host_abi.h` 다. 여기 매핑과 함께 바꾼다 —
/// 계약 테스트가 헤더를 읽어 미러를 검사한다.
fn keyFromId(key_id: u32, codepoint: u32) ?terminal.input.Key {
    return switch (key_id) {
        0 => terminal.input.charKeyFromCodepoint(codepoint) catch null,
        1 => .enter,
        2 => .escape,
        3 => .tab,
        4 => .backspace,
        5 => .arrow_up,
        6 => .arrow_down,
        7 => .arrow_left,
        8 => .arrow_right,
        9 => .home,
        10 => .end,
        11 => .insert,
        12 => .delete,
        13 => .page_up,
        14 => .page_down,
        100...111 => .{ .function = @intCast(key_id - 99) },
        else => null,
    };
}

/// 키 하나를 인코딩해 코어에 쓴다. **키 경로와 개행 경로가 같은 자리를 쓴다** — 안 그러면
/// 같은 Enter 가 입력 수단에 따라 다른 바이트가 된다.
/// 확정된 입력이 **어디로 가나**. 0=로컬 코어(기본), 1=host 가 가져간다(원격 세션).
///
/// **원격에 붙으면 입력은 코어로 가면 안 된다.** 코어에 쓰는 것은 *출력*을 그리는 일이라,
/// 원격 세션에서 그렇게 하면 사용자가 친 글자가 화면에 한 번 찍히고 **원격에는 영영 안 간다**
/// (실측: `whoami` 를 쳐도 아무 일도 안 났다). 인코딩은 여기 한 곳이어야 하므로(§3 — 의미는
/// 코어가 정한다) 목적지만 가른다.
var input_sink: u32 = 0;
/// 원격으로 나갈 바이트. **가져가면 사라진다.** 셸이 뜨기 전에 친 글자도 여기 모였다가 함께
/// 나간다(type-ahead) — 실제 터미널이 그렇게 군다.
var input_out: [4096]u8 = undefined;
var input_out_len: usize = 0;

/// 확정된 입력 한 조각. **모든 입력 경로가 여기를 지난다** — 조각마다 목적지를 따로 정하면
/// 언젠가 한 곳을 빠뜨리고, 그 경로만 원격에 안 간다.
fn sendInput(core: *terminal.core.TerminalCore, bytes: []const u8) void {
    if (input_sink == 0) {
        core.write(bytes) catch setLastError("core_write_input");
        return;
    }
    if (input_out_len + bytes.len > input_out.len) {
        // **넘치면 버리고 이름을 남긴다.** 조용히 자르면 명령 한 줄이 반만 나가 원격에서
        // 엉뚱한 것이 실행된다.
        setLastError("input_overflow");
        return;
    }
    @memcpy(input_out[input_out_len..][0..bytes.len], bytes);
    input_out_len += bytes.len;
}

/// 입력 목적지를 정한다. host 가 원격 세션을 열고 닫을 때 부른다.
pub export fn maru_mobile_set_input_sink(sink: u32) void {
    if (input_sink == sink) return;
    input_sink = sink;
    // **바꾸면 비운다.** 옛 목적지로 가려던 바이트가 새 목적지로 새어 나가면, 로컬에서 친
    // 글자가 원격에 뒤늦게 실행된다.
    input_out_len = 0;
}

pub export fn maru_mobile_input_sink() u32 {
    return input_sink;
}

/// 원격으로 보낼 바이트를 가져간다. **가져가면 사라진다.** 자리가 모자라면 0 이고 아무것도
/// 안 지운다 — 잘라 보내면 명령이 반만 나간다(config 쓰기와 같은 규칙).
pub export fn maru_mobile_take_input(out: [*]u8, cap: usize) usize {
    if (input_out_len == 0) return 0;
    if (input_out_len > cap) {
        setLastError("input_too_large");
        return 0;
    }
    @memcpy(out[0..input_out_len], input_out[0..input_out_len]);
    const n = input_out_len;
    input_out_len = 0;
    return n;
}

fn writeKey(core: *terminal.core.TerminalCore, key: terminal.input.Key, mods: terminal.input.ModifierSet) void {
    var buf: [terminal.input.encoded_key_buffer_len]u8 = undefined;
    const bytes = core.encodeKey(.{ .key = key, .modifiers = mods }, &buf) catch {
        setLastError("key_encode");
        return;
    };
    sendInput(core, bytes);
    delivered_len += bytes.len;
}

pub export fn maru_mobile_key(key_id: u32, codepoint: u32, mods: u32) u32 {
    // **밀린 화면이 있으면 글자는 셸로 안 간다.** 설정을 열어도 소프트 키보드는 떠 있으므로
    // (§5.2 — 앱이 내리지 않는다) 여기서 안 막으면 사용자가 **안 보이는 셸에 타이핑**하게 된다.
    // 화면에 아무 반응이 없어 잃은 것도 모른다. 설정에 입력 칸이 생기면(검색) 그때 그쪽으로
    // 라우팅한다 — 지금은 받을 곳이 없으니 안 보낸다. **버리되 신호는 남긴다**(문자 경로와
    // 같은 이유 — 16줄 아래 `key_unknown_id` 가 같은 규율이다).
    if (screenTop() != .terminal) {
        // **편집 중이면 지우기·확정은 그 칸의 것이다.** 그전에는 통째로 버려서 숫자 칸에서
        // 백스페이스가 아무 일도 안 했다 — 오타를 낸 사용자가 고칠 방법이 없었다.
        if (edit_target == .password) {
            switch (key_id) {
                4 => { // BACKSPACE
                    editBackspace();
                    return @intCast(delivered_len);
                },
                1 => { // ENTER = 접속
                    commitPassword();
                    return @intCast(delivered_len);
                },
                2 => { // ESCAPE = 취소(친 것을 지운다)
                    wipePassword();
                    return @intCast(delivered_len);
                },
                else => {},
            }
        }
        if (edit_target == .server_field) {
            switch (key_id) {
                4 => { // BACKSPACE — 글자 단위(S9b-1 과 같은 규칙)
                    editBackspace();
                    return @intCast(delivered_len);
                },
                1 => { // ENTER
                    commitServerFieldEdit();
                    return @intCast(delivered_len);
                },
                2 => { // ESCAPE = 취소
                    edit_target = .none;
                    set_edit_len = 0;
                    return @intCast(delivered_len);
                },
                else => {},
            }
        }
        if (set_edit) |edit_i| {
            const is_text = set_items[edit_i].field.kind == .text;
            switch (key_id) {
                4 => { // BACKSPACE
                    // **글자 단위로 지운다.** 숫자 줄은 한 바이트가 곧 한 글자라 결과가 같지만,
                    // 문자열 줄에서 바이트로 지우면 한글이 반쪽으로 남아 화면과 파일이 깨진다.
                    editBackspace();
                    return @intCast(delivered_len);
                },
                1 => { // ENTER
                    // **줄 종류에 맞는 확정을 부른다.** 문자열 줄에 숫자 확정을 부르면 값이
                    // 안 들어가고 `settings_number_parse` 만 남는다 — 사용자에게는 "엔터를
                    // 눌러도 아무 일이 안 나는" 상태다.
                    if (is_text) commitTextEdit() else commitNumberEdit();
                    return @intCast(delivered_len);
                },
                2 => { // ESCAPE = 취소
                    set_edit = null;
                    set_edit_len = 0;
                    return @intCast(delivered_len);
                },
                else => {},
            }
        }
        setLastError("key_screen_pushed");
        return @intCast(delivered_len);
    }
    // **안 보낼 키는 겉치레도 안 건드린다.** 지우기를 게이트 앞에 두면, 터미널에서 한글을
    // 조합하다 설정을 열고 아무 키나 친 순간 **그 조합이 조용히 사라진다**(돌아오면 없다).
    preedit_len = 0; // 확정됐으니 겉치레를 지운다

    const core = &(term_core orelse {
        setLastError("input_before_core");
        return @intCast(delivered_len);
    });
    const key = keyFromId(key_id, codepoint) orelse {
        // 모르는 id 를 조용히 흘리면 그 키가 사라진 채 아무 신호가 없다(§5).
        setLastError("key_unknown_id");
        return @intCast(delivered_len);
    };
    snapToBottomOnInput(core);
    // **눌러 둔 수정자를 여기서 소비한다.** 보조 키바의 Ctrl 은 다음 **한 키**에만 실린다 —
    // 계속 걸려 있으면 그 뒤 타이핑이 전부 제어문자가 된다. 소비 자리를 한 곳에 두어야
    // 키바 탭과 하드웨어 키가 같은 규칙을 탄다.
    const eff = mods | armed_mods;
    armed_mods = 0;
    const ev: terminal.input.KeyEvent = .{ .key = key, .modifiers = .{
        .shift = eff & 1 != 0,
        .control = eff & 2 != 0,
        .option = eff & 4 != 0,
        .command = eff & 8 != 0,
    } };
    writeKey(core, ev.key, ev.modifiers);
    drainUnconsumed(core);
    return @intCast(delivered_len);
}

// ── 스크롤 ────────────────────────────────────────────────────────────────────
// 한 줄이 안 되는 나머지. 폰의 미세한 델타를 버리면 **천천히 끌 때 아예 안 움직인다**.
var scroll_px_carry: f32 = 0;

/// 입력이 들어오면 바닥으로 스냅한다. 과거를 보는 중에 친 글자가 화면 밖에 찍히면 **친 것이
/// 사라진 것처럼 보인다**. 데스크톱도 같다("입력하면 live 복귀").
fn snapToBottomOnInput(core: *terminal.core.TerminalCore) void {
    if (core.viewOffset() != 0) core.scrollToBottom();
    scroll_px_carry = 0;
}

/// 플랫폼이 넘긴 논리 px 를 줄로 바꿔 코어에 태운다. **환산이 여기 있는 이유**는 셀 높이가
/// 코어 쪽 값이기 때문이다 — 플랫폼은 배치를 모른다(§3).
/// 휠 한 칸이 몇 줄인가. **macOS 는 이 3 을 이벤트에 이미 실어 보내고**(NSEvent 의 wheel
/// deltaY 가 노치당 3), Android `AXIS_VSCROLL` 은 노치당 1 만 준다 — 같은 휠이 플랫폼마다
/// 다르게 굴러가지 않도록 **여기서 한 번** 맞춘다.
const wheel_lines_per_notch: f64 = 3.0;

/// 한 줄이 안 되는 휠 델타를 모은다. **버리면 정밀 트랙패드가 아예 안 움직인다**(데스크톱이
/// 겪어 `wheelDeltaToLines` 에 누적기를 둔 자리 — 같은 함수를 쓴다).
var wheel_accum: f64 = 0;

/// 마우스 휠·트랙패드. **플랫폼은 원시 델타만 넘긴다**(데스크톱 ABI 와 같은 모양) — 줄 환산은
/// `maru.session.input_math.wheelDeltaToLines` 하나가 한다.
///
/// `precise != 0` 이면 델타가 **논리 px**(트랙패드), 0 이면 **노치**(휠)다. 부호는 손가락과 같다 —
/// 양수면 과거(위)로 간다.
///
/// **비유한 값(NaN·Inf)은 여기서 따로 안 막는다** — `wheelDeltaToLines` 가 이미 막고 있고,
/// 두 곳에서 막으면 한쪽이 죽는다(가드를 지우는 변이가 아무 테스트도 안 깼다). 그 보호가
/// 경로에 남아 있는지는 계약 테스트가 지킨다.
///
/// **가로(`delta_x`)는 아직 안 쓴다.** 데스크톱은 그것을 탭 바 가로 스크롤로 보내는데, 모바일의
/// 가로 스크롤 면은 키바뿐이고 마우스로 키바를 굴릴 이유가 아직 없다 — 쓰게 되면 그때 정한다
/// (지금 받아 두는 것은 서명을 두 번 바꾸지 않으려는 것이다).
pub export fn maru_mobile_wheel(delta_y: f32, delta_x: f32, precise: u32, x: f32, y: f32) void {
    _ = delta_x;
    _ = x;
    _ = y;

    // **밀린 화면 위에서 굴리면 그 목록이 움직인다.** 마우스는 가리키는 것이 곧 대상이다 —
    // 안 보이는 뒤 화면을 굴리면 돌아왔을 때 보던 자리가 아니다.
    if (screenTop() == .settings) {
        const lines = input_math.wheelDeltaToLines(
            &wheel_accum,
            @as(f64, delta_y) * (if (precise != 0) 1.0 else wheel_lines_per_notch),
            precise != 0,
            @intFromFloat(set_row_h),
            1000,
        );
        if (lines == 0) return;
        _ = set_sa.scrollByPx(@intFromFloat(-@as(f32, @floatFromInt(lines)) * set_row_h), @intFromFloat(@max(0, set_max_scroll)));
        return;
    }

    const line_h: u32 = if (body_line_h > 0) @intCast(body_line_h) else 1;
    const lines = input_math.wheelDeltaToLines(
        &wheel_accum,
        @as(f64, delta_y) * (if (precise != 0) 1.0 else wheel_lines_per_notch),
        precise != 0,
        line_h,
        1000,
    );
    if (lines == 0) return;
    // **적용은 손가락과 같은 경로다** — alt 화면 변환·선택 해제·clamp 가 거기 있고, 두 벌이 되면
    // 갈린다(휠만 alt 화면에서 뷰포트를 움직이는 일이 생긴다).
    maru_mobile_scroll(@as(f32, @floatFromInt(lines)) * @as(f32, @floatFromInt(line_h)));
}

pub fn maru_mobile_scroll(dy_px: f32) void {
    // **밀린 화면이 있으면 뒤는 안 움직인다.** host 의 관성은 손을 뗀 뒤에도 몇 프레임 더
    // 도는데, 그 사이 톱니를 눌러 설정을 열면 **안 보이는 터미널이 계속 흘러** 돌아왔을 때
    // 보던 자리가 아니다(§3 "전환에서 스크롤 위치를 잃지 않는다").
    //
    // **여기는 오류를 안 남긴다** — 위 두 경로(문자·키)와 다르다. 잃는 것이 사용자가 친
    // 글자가 아니라 host 가 스스로 돌리는 관성이고, 그 관성은 프레임마다 오므로 남기면
    // `last_error` 가 매 프레임 덮여 **진짜 오류를 가린다**.
    if (screenTop() != .terminal) return;
    const core = &(term_core orelse {
        setLastError("scroll_before_core");
        return;
    });
    if (body_line_h <= 0) return;
    // **선택 중에는 안 흘린다.** 플랫폼은 관성(느낌)만 갖고 그것을 적용할지는 의미라 코어가
    // 정한다 — host 는 MOVE 마다 관성 속도를 세워 두므로, 여기서 안 막으면 길게 눌러 선택하는
    // 동안에도 화면이 계속 흐른다(끌어서 범위를 넓히는 내내 글자가 도망간다).
    if (body_press.state == .long_pressed) {
        scroll_px_carry = 0;
        return;
    }
    scroll_px_carry += dy_px;
    const lines_f = @trunc(scroll_px_carry / @as(f32, @floatFromInt(body_line_h)));
    if (lines_f == 0) return; // 나머지는 다음 호출로 넘긴다
    scroll_px_carry -= lines_f * @as(f32, @floatFromInt(body_line_h));
    const lines: i32 = @intFromFloat(lines_f);

    // **휠을 직접 받겠다고 켠 앱에는 휠을 준다**(DECSET 1000/1002/1003 + 1006). Claude Code 처럼
    // 자기 화면을 스스로 굴리는 TUI 가 이 축이고, 그런 앱은 대개 `?1007l` 로 화살표 변환을 끈다
    // — 아래 alt-scroll 분기가 거짓이 되고, 그러면 스크롤백을 보러 가는데 **alt screen 에는
    // 스크롤백이 없어** 손가락이 아무것도 못 움직였다(기기 실측).
    //
    // **좌표를 함께 보낸다.** 어디를 굴릴지는 앱이 정한다 — 대화 영역이냐 입력 줄이냐를 그
    // 좌표로 가르므로, 가운데 열로 때려 맞히면 그 판단이 조용히 틀린다. 데스크톱 마우스가
    // 하는 것과 같은 일이라 규칙도 그쪽과 같다.
    //
    // **이 판정이 alt-scroll 보다 먼저다.** xterm 에서 alternate scroll 은 마우스 리포팅이
    // **없을 때** 쓰는 대체 장치다 — 순서가 반대면 휠을 받겠다고 켠 앱에 화살표가 가서,
    // 그 앱은 그것을 커서 이동이나 히스토리로 읽는다.
    if (core.mouse_tracking != .none) {
        // 변환하는 순간 그 화면은 프로그램이 다시 그린다 — 남은 선택은 좌표가 어긋난 유령이다.
        core.selectionClear();
        // 64=wheel-up · 65=wheel-down(`input_report.zig` 의 규약). 휠은 press 만 있고 release 가
        // 없으며 motion 도 아니다.
        const button: u8 = if (lines > 0) 64 else 65;
        const hit = maru_mobile_hit_cell(ptr_last_x, ptr_last_y);
        // 화면 밖이면 굴릴 자리가 없다 — 좌표를 지어내지 않는다.
        if (hit == 0xFFFFFFFF) return;
        const col: u16 = @intCast(hit >> 16);
        const row: u16 = @intCast(hit & 0xFFFF);
        var n: u32 = @abs(lines);
        while (n > 0) : (n -= 1) {
            core.reportMouse(button, col, row, 0, 0, true, false, 0);
        }
        // **코어가 만든 바이트를 입력 경로로 옮긴다 — 응답 큐에 두지 않는다.**
        //
        // 포맷을 정하는 것은 코어다(SGR·urxvt·x10 은 앱이 켠 모드에 달렸다). 그래서 만들기는
        // `reportMouse` 에 맡기되, **보내는 길은 화살표와 같아야 한다.** 응답 큐에 두면 두 가지가
        // 어긋난다: ① host 는 그것을 **원격이 뭔가 보냈을 때만** 가져간다(`ssh_pump.c` 의
        // `drain_screen`) — 조용한 화면에서 굴리면 휠이 큐에 앉아 있는다. ② 그 사이 사용자가
        // 한 글자라도 치면 `maru_mobile_input` 이 `drainUnconsumed` 로 **통째로 버린다**
        // (`response_dropped` 만 남는다 — 테스트를 쓰다 실제로 밟았다).
        const resp = core.pendingResponse();
        if (resp.len > 0) {
            var wheel: [512]u8 = undefined;
            const take = @min(resp.len, wheel.len);
            @memcpy(wheel[0..take], resp[0..take]);
            core.clearResponse();
            sendInput(core, wheel[0..take]);
            // 이 바이트도 코어에 닿은 것이다 — 화살표 경로가 같은 이유로 세는 자리다.
            delivered_len += take;
        }
        return;
    }

    // **alt screen 은 뷰포트가 아니라 프로그램의 것이다**(DECSET 1007). less·vim 이 자기
    // 스크롤을 갖고 있으므로 화살표를 보낸다. 데스크톱이 정한 것과 같은 규칙이다.
    if (core.alt_active and core.alternate_scroll) {
        // 변환하는 순간 그 화면은 프로그램이 다시 그린다 — 남은 선택은 좌표가 어긋난 유령이다.
        core.selectionClear();
        const key: terminal.input.Key = if (lines > 0) .arrow_up else .arrow_down;
        var n: u32 = @abs(lines);
        // **한 번에 한 줄씩 쓰지 않는다.** 빠른 플릭이면 수십 줄이 되고, 줄마다 write 하면
        // 뒷부분이 드랍된다(데스크톱이 겪어 배치로 바꾼 자리다).
        var buf: [terminal.input.encoded_key_buffer_len]u8 = undefined;
        const bytes = core.encodeKey(.{ .key = key }, &buf) catch {
            setLastError("key_encode");
            return;
        };
        var batch: [512]u8 = undefined;
        const per_batch = batch.len / bytes.len;
        while (n > 0) {
            const count = @min(n, @as(u32, @intCast(per_batch)));
            var used: usize = 0;
            var i: u32 = 0;
            while (i < count) : (i += 1) {
                @memcpy(batch[used..][0..bytes.len], bytes);
                used += bytes.len;
            }
            sendInput(core, batch[0..used]);
            // **이 바이트도 코어에 닿은 것이다.** 누적값이 "전달한 바이트" 라고 헤더에 적어
            // 놓고 이 경로만 빼면, 같은 값이 어떤 때는 참이고 어떤 때는 아니게 된다.
            delivered_len += used;
            n -= count;
        }
        drainUnconsumed(core);
        return;
    }
    // clamp 는 코어가 한다 — 여기서 또 하면 두 곳이 갈린다.
    core.scrollViewport(lines);
}

// ── 포인터: 끌면 스크롤, 길게 누르면 선택 ────────────────────────────────────
// **무엇으로 해석할지는 코어가 정한다**(§3.1). 플랫폼마다 판단하면 같은 손가락이 기기에 따라
// 다른 뜻이 된다. 플랫폼이 갖는 것은 관성뿐이다(손을 뗀 뒤 `maru_mobile_scroll`).
/// **길게 누름 지연은 OS 가 정한다.** 두 플랫폼 다 사용자 접근성 설정으로 바꿀 수 있고
/// (Android "길게 누르기 지연", iOS "터치 조절 → 유지 시간"), 하드코딩하면 그 설정을
/// 무시하게 된다 — 손이 느린 사용자가 길게 눌러도 선택이 안 잡힌다.
///
/// 여기 값은 **플랫폼이 안 알려줄 때의 폴백**이다. 실측: 이 에뮬레이터의 OS 값은 400ms 다.
var long_press_ms: u64 = 500;

/// 플랫폼이 자기 OS 값을 알려 준다(Android `ViewConfiguration.getLongPressTimeout()`,
/// iOS `UILongPressGestureRecognizer` 기본 0.5초). 0 은 무시한다.
pub export fn maru_mobile_set_long_press_ms(ms: u32) void {
    if (ms > 0) long_press_ms = ms;
}

/// 코어가 **실제로 들고 있는** 값. host 가 자기가 보낸 값을 로그해 봐야 "닿았다" 는 증명이
/// 안 된다 — 되물어야 안다(그렇게 안 해서 안 닿은 것을 못 본 적이 있다).
pub export fn maru_mobile_long_press_ms() u32 {
    return @intCast(long_press_ms);
}
/// 본문의 제스처. **뜻은 상태 하나가 든다**(계약 §3.1) — 전에는 `ptr_down`·`ptr_moved`·
/// `selecting` 이 따로 있었고, "길게 누름이 아직 살아 있나" 를 그 셋의 조합으로 봤다.
/// 선택으로 들어가는 것도 여기 전이다(`long_pressed`).
var body_press: gesture.Press = .{};
/// 스크롤 델타·속도의 기준. **제스처 상태가 아니다.**
var ptr_last_y: f32 = 0;
/// 손가락이 있던 **가로** 자리. 스크롤 자체는 세로만 쓰지만, 마우스 리포팅을 켠 앱에는 휠을
/// **좌표와 함께** 보내야 한다(`reportMouse` 의 col) — 그 앱이 "대화 영역이냐 입력 줄이냐" 를
/// 그 좌표로 가른다. 세로만 들고 가운데 열로 때려 맞히면 그 판단이 조용히 틀린다.
var ptr_last_x: f32 = 0;
var ptr_last_ms: u64 = 0;
/// 손을 뗀 뒤 남은 세로 관성(px/ms). **코어가 든다** — 전에는 host 가 들었는데, 목적지를
/// host 가 더는 모르게 되자(R2) 키바로 간 제스처의 세로 속도까지 본문에 흘렸다(회귀였다).
/// 키바·설정 관성이 이미 여기서 도는 것과 같은 자리다.
var body_fling: f32 = 0;
/// 길게 눌러 선택에 들어갔다 — 이 뒤의 이동은 스크롤이 아니라 선택 확장이다.
/// 본문 안의 점을 셀로. 본문 밖이면 null.
fn bodyCell(x: f32, y: f32) ?struct { row: u16, col: u16 } {
    const packed_cell = maru_mobile_hit_cell(x, y);
    if (packed_cell == 0xFFFF_FFFF) return null;
    return .{ .row = @intCast(packed_cell & 0xFFFF), .col = @intCast(packed_cell >> 16) };
}

/// 본문 제스처가 추적하는 손가락. **`Touch` 를 안 거친다** — 여기는 선택·롱프레스가 코어의
/// 포인터 상태를 직접 쓰는 자리라 스크롤 면과 모델이 다르다. 그래도 규칙은 같다(계약 §3.1):
/// 소유자만 뜻을 만들고, 소유자가 떼지면 남은 손가락이 **자기 기준으로** 이어받는다.
const BodySlot = struct { used: bool = false, id: u32 = 0, last_y: f32 = 0 };
var body_slots: [4]BodySlot = @splat(.{});
var body_owner: ?u32 = null;

fn bodySlot(id: u32) ?*BodySlot {
    for (&body_slots) |*s| if (s.used and s.id == id) return s;
    return null;
}

/// **터치의 유일한 진입점.** host 는 좌표와 손가락 id 만 나르고 **어디로 갈지는 여기서 정한다**
/// (계약 §3.1). 전에는 진입점이 셋이고 host 가 `chrome_active`·`keybar_active` 로 골랐는데,
/// 같은 사실을 두 층이 들다 보니 정리도 두 곳에서 해야 했고 한쪽을 빠뜨려 **복귀 후 첫 손짓이
/// 통째로 삼켜지는** 결함이 났다(같은 모양을 세 번 겪었다 — 키바 잡음·iOS `_hasBodyPtr`·
/// 배경 정리).
///
/// 순서는 **밀린 화면(chrome) → 보조 키바 → 본문**이다. 위가 떠 있으면 아래는 없는 것과 같다.
pub export fn maru_mobile_pointer(phase: u32, pointer_id: u32, x: f32, y: f32, time_ms: u64) void {
    // **취소는 전부에게 간다** — 어느 표면이 잡고 있었든 놓아야 한다(계약 §3.1: id 무관).
    if (phase == 3) {
        _ = chromePointer(3, pointer_id, x, y, time_ms);
        _ = keybarPointer(3, pointer_id, x, y, time_ms);
        bodyPointer(3, pointer_id, x, y, time_ms);
        return;
    }
    if (chromePointer(phase, pointer_id, x, y, time_ms) != 0) return;
    if (keybarPointer(phase, pointer_id, x, y, time_ms) != 0) return;
    bodyPointer(phase, pointer_id, x, y, time_ms);
}

/// 지금 제스처가 어디로 가고 있나(테스트용). **"이 터치가 어디로 갔나" 가 곧 재려는 성질**이라
/// 간접 효과(셀 판정·키 바이트)로 우회하지 않는다 — 우회하면 판정이 흐려진다.
pub fn currentRouteName() []const u8 {
    return if (route) |r| @tagName(r) else "none";
}

fn bodyPointer(phase: u32, pointer_id: u32, x: f32, y: f32, time_ms: u64) void {
    const core = &(term_core orelse return);
    // **취소는 손가락을 안 가린다**(계약 §3.1) — 전부 놓는다.
    if (phase == 3) {
        body_slots = @splat(.{});
        body_owner = null;
        body_press.cancel();
        // **취소는 관성도 거둔다.** 두 host 가 이 phase 를 배경 전환 정리로도 쓰므로, 남기면
        // 돌아왔을 때 손대지 않은 화면이 저 혼자 흐른다(전에 host 에서 겪은 그것이다).
        body_fling = 0;
        if (routeIs(.body)) routeClear();
    }
    switch (phase) {
        0 => { // down
            // 자리를 잡는다. **비소유자는 뜻을 안 만든다** — 둘째 손가락이 닿았다고 첫 손가락이
            // 만든 선택이 지워지거나 롱프레스 시계가 새로 도는 것은 사용자가 한 적 없는 일이다.
            // (T2 가 host 에서 모든 손가락을 보내기 시작하면서 실제로 그렇게 됐다.)
            // **같은 id 로 down 이 두 번 오면 자리를 새로 만들지 않는다.** 만들면 `up` 이 그
            // 중복을 "남은 손가락" 으로 이어받아 **제스처가 영영 안 끝난다**(테스트가 잡았다).
            // **본문은 마지막 순서다** — chrome·키바가 안 먹었을 때만 잡는다(계약 §3.1).
            // host 가 그 순서로 물어보므로 여기 오면 앞의 둘이 사양한 것이다.
            if (!routeIs(.body) and !routeClaim(.body)) return;
            if (bodySlot(pointer_id)) |sl| {
                sl.last_y = y;
            } else for (&body_slots) |*sl| {
                if (!sl.used) {
                    sl.* = .{ .used = true, .id = pointer_id, .last_y = y };
                    break;
                }
            }
            if (body_owner == null) body_owner = pointer_id;
            if (body_owner != pointer_id) return;
            // **본문에는 탭이 없다** — 짚어서 관성을 세우는 것이 전부라 `stop_tap` 은 안 쓴다
            // (그 처리는 바로 아래 `body_fling = 0` 이다).
            body_press.begin(x, y, time_ms, false);
            ptr_last_y = y;
            ptr_last_x = x;
            ptr_last_ms = time_ms;
            // **누르면 관성이 선다** — 흐르는 화면을 짚어 세우는 것은 모든 스크롤 면의 약속이다.
            body_fling = 0;
            // 새로 누르면 이전 선택은 사라진다 — 데스크톱에서 클릭이 선택을 푸는 것과 같다.
            // **새로 누르면 이전 선택은 사라진다** — 데스크톱에서 클릭이 선택을 푸는 것과 같다.
            // 선택 **상태**는 위 `begin` 이 이미 `pressed` 로 돌려놨다(그것이 전이다).
            if (core.selectionViewportSpan() != null) core.selectionClear();
        },
        1 => { // move
            if (!routeIs(.body)) return;
            // **비소유자의 기준만 갱신하고 뜻은 안 만든다** — 그 손가락이 이어받는 순간 옛
            // 자리에서 델타가 나오면 화면이 점프한다(T1 이 스크롤 면에서 없앤 그 병).
            if (bodySlot(pointer_id)) |sl| sl.last_y = y;
            if (body_owner != pointer_id) return;
            if (!body_press.active()) return;
            // **슬롭을 넘으면 밀기다 — 길게 누름은 더 이상 안 잡힌다.** 임계는 스크롤 면과 같은
            // 값을 쓴다(전에는 `long_press_slop` 이 같은 10 을 따로 들고 있었다 — 같은 손짓이
            // 표면마다 다르게 판정되면 사용자는 이유를 모른다).
            //
            // **본문은 슬롭 전에도 흘린다** — 키바·설정과 다른 자리다. 터미널 뷰포트에는 탭이
            // 없어 첫 10px 를 죽일 이유가 없고, 죽이면 끌기 시작이 굼떠 보인다.
            _ = body_press.move(x, y);

            if (body_press.state == .long_pressed) {
                // **누른 칸을 벗어나기 전에는 안 늘린다.** 길게 눌러 단어를 잡은 직후에도
                // move 는 계속 오는데, 그때마다 늘리면 head 가 **누른 칸으로 당겨져 단어
                // 끝이 잘린다**(3칸 단어가 2칸이 되는 것을 픽셀로 재서 잡았다).
                if (bodyCell(x, y)) |c| {
                    if (bodyCell(body_press.down_x, body_press.down_y)) |d| {
                        if (c.row != d.row or c.col != d.col) {
                            core.selectionExtend(c.row, c.col);
                            // **전에는 여기서 `ptr_moved` 를 세웠다.** 안 세우면 다음 프레임의
                            // `checkLongPress` 가 늘린 것을 되돌렸다 — 셀 폭(8)이 임계(10)보다
                            // 좁아 9px 끌면 여기까지 오는데도 "안 움직였다" 였기 때문이다.
                            // 상태기계에서는 **이미 `long_pressed` 라 다시 안 잡힌다**(전이는
                            // `pressed` 에서만 일어난다) — 그 뒷정리가 필요 없어졌다.
                        }
                    }
                }
                ptr_last_y = y;
                ptr_last_x = x;
                return;
            }
            // **길게 누름은 여기서 안 본다** — 프레임마다 도는 `checkLongPress` 가 판정한다.
            // 손가락이 가만히 있으면 move 가 아예 안 오기 때문이다.
            // 스크롤이다. 델타는 직전 move 대비다.
            maru_mobile_scroll(y - ptr_last_y);
            // **속도는 px/ms 다**(프레임당이 아니다 — 30Hz 기기에서 두 배 멀리 가는 것을 T1 이
            // 실측으로 잡았다). 간격은 아래위로 자른다: 0 이면 나눗셈이 폭발하고, 손가락이
            // 멈췄다 다시 움직인 긴 간격은 속도가 아니라 **정지**다.
            const dt_ms = @max(1.0, @min(100.0, @as(f32, @floatFromInt(time_ms -| ptr_last_ms))));
            const v = (y - ptr_last_y) / dt_ms;
            body_fling = @max(-scroll_area.Touch.max_velocity, @min(scroll_area.Touch.max_velocity, v));
            ptr_last_y = y;
            ptr_last_x = x;
            ptr_last_ms = time_ms;
        },
        else => { // up · cancel
            if (phase == 2) {
                if (!routeIs(.body)) return;
                if (bodySlot(pointer_id)) |sl| sl.* = .{};
                // **비소유자가 떼는 것은 이 제스처를 안 끝낸다**(계약 §3.1).
                //
                // **이 가드는 오늘 변이로 안 잡힌다** — 아래 인수인계 루프가 남은 손가락 중
                // 첫 번째를 고르는데, 비소유자가 떠도 소유자가 그대로 남아 있어 결과가 같기
                // 때문이다. 그래도 남긴다: 계약을 코드에 적어 두는 자리이고, 인수인계 규칙이
                // 바뀌면(예: 가장 최근 손가락을 고르게) 그 순간 필요해진다.
                if (body_owner != pointer_id) return;
                body_owner = null;
                for (body_slots) |sl| {
                    if (sl.used) {
                        body_owner = sl.id;
                        // **이어받는다.** 그 손가락은 자기 기준을 갖고 있으므로 그것으로 잇는다 —
                        // 여기서 옛 좌표를 남기면 다음 move 에서 점프한다.
                        ptr_last_y = sl.last_y;
                        ptr_last_ms = time_ms;
                        // **이어받는 자리의 불연속은 관성이 아니다**(AOSP `ScrollView` 가
                        // `VelocityTracker.clear()` 로 하는 그것이다).
                        body_fling = 0;
                        return; // 제스처는 계속된다 — 선택·롱프레스 상태를 안 거둔다
                    }
                }
                routeClear(); // 마지막 손가락이었다 — 목적지를 놓는다(계약 §3.1)
            }
            // **본문을 짧게 두드리는 것은 "치겠다" 는 뜻이다** — 키보드를 올린다. 예전에는 상단
            // `자판` 버튼만 그 일을 했는데, TUI 의 입력칸을 눈앞에 두고 화면 꼭대기까지 손을
            // 올려야 했다.
            //
            // **어디가 입력칸인지는 우리가 모른다.** 터미널은 셀 격자만 보고 그 안에 그려진 것의
            // 뜻은 앱만 안다. 대신 **커서를 본다** — Claude Code·Codex 같은 TUI 는 입력칸에 커서를
            // 둔다(기기 실측: 입력 박스를 탭한 셀과 커서가 같은 행이었다). 그래서 커서 행을
            // 두드리면 입력칸을 누른 것으로 본다.
            //
            // **커서가 안 보이면 그 판정을 못 한다.** TUI 는 화면을 다시 그리는 동안 DECTCEM
            // (`?25l`)으로 커서를 끄고, 스크롤백을 보는 중에는 커서가 화면 밖이다. 그때는 근거가
            // 없으므로 **아무 데나 두드려도 올린다** — 판정할 수 없을 때 아무것도 안 하면
            // 사용자는 키보드를 못 부른다.
            if (body_press.end() == .tap) {
                if (term_core) |*tc| {
                    const scrolled = tc.viewOffset() != 0;
                    const hit = maru_mobile_hit_cell(x, y);
                    if (!tc.cursor_visible or scrolled or hit == 0xFFFFFFFF) {
                        kb_raise_req = true; // 판정 못 한다 — 두드렸으면 올린다
                    } else if (@as(u16, @intCast(hit & 0xFFFF)) == tc.screen.cursor.row) {
                        kb_raise_req = true; // 커서 행 = 입력칸
                    }
                }
            }
            // 선택은 손을 떼도 **남는다** — 떼자마자 사라지면 복사할 수가 없다. 지우는 자리는
            // **다음 누름**이다(phase 0 이 이미 그렇게 한다).
            //
            // **취소(phase 3)에서도 안 지운다.** 두 host 가 이 phase 를 "제스처 취소" 가 아니라
            // **수명 정리**로도 쓴다(iOS `applicationDidEnterBackground`, Android
            // `APP_CMD_LOST_FOCUS` — 둘 다 주석이 "누르고 있던 손가락을 정리한다" 라고 적어
            // 뒀다). ABI 가 두 뜻에 같은 번호를 줘서 브리지는 구분할 수가 없다. 그런데 Android
            // 는 **알림 셰이드·권한 대화상자·분할 화면 포커스 변화**에도 LOST_FOCUS 를 내므로,
            // 여기서 지우면 셰이드 한 번 내렸다 온 사이에 **복사 안 한 선택이 사라진다**.
            //
            // 지울 이유도 없다 — 취소든 뗌이든 손가락이 없어진다는 뜻이고, 이미 만들어진 선택은
            // 진행 중인 제스처가 아니라 **결과**다. 다음 누름이 치운다.
            // (선택 **상태**는 위 `end`/`cancel` 이 이미 거뒀다 — 그것이 제스처의 단계다.)
        },
    }
}

/// 선택 범위(뷰포트 기준). start_row·start_col·end_row·end_col 을 각각 16비트로 담는다.
/// **끝 열은 포함이다**(데스크톱 렌더와 같은 약속). 선택이 없으면 0xFFFF_FFFF_FFFF_FFFF.
pub export fn maru_mobile_selection_span() u64 {
    const core = &(term_core orelse return std.math.maxInt(u64));
    const s = core.selectionViewportSpan() orelse return std.math.maxInt(u64);
    return (@as(u64, s.start.row) << 48) | (@as(u64, s.start.col) << 32) |
        (@as(u64, s.end.row) << 16) | @as(u64, s.end.col);
}

pub export fn maru_mobile_has_selection() u32 {
    const core = &(term_core orelse return 0);
    return if (core.selectionViewportSpan() != null) 1 else 0;
}

/// 키 하나의 크기와 간격. **44 는 손가락 기준**(iOS HIG 44pt·Android 48dp)이고, 이 값을 지키면
/// 키 11개가 폰 세로 폭을 넘는다 — 그래서 가로 스크롤이 함께 온다. 줄이거나 키를 버리는 대신
/// **크기를 지키고 스크롤한다**(사용자 결정).
const key_w: f32 = 44.0;
/// 본문(터미널 격자)의 안쪽 여백. **정의하는 곳과 빼는 곳이 같은 값을 봐야 한다** —
/// 레이아웃 결과가 border box 라, 소비하는 쪽이 이만큼 물려야 격자가 제 자리에 앉는다.
///
/// **모바일은 0 이다.** 화면이 좁아 좌우 여백은 곧 열이고 상하는 곧 행인데, 터미널에서 그
/// 한 칸이 데스크톱보다 훨씬 비싸다. 곡면·노치 대비는 host 가 이미 `inset_left/right` 로
/// 빼서 넘겨 주므로(android_app_host.c 의 "좌우도 뺀다") 여기서 또 물릴 이유가 없다.
///
/// **0 이어도 이 상수는 남긴다.** 값이 아니라 **경계를 누가 소유하는가**가 요점이다 — 다시
/// 여백을 주고 싶어지면 이 한 곳만 고치면 되고, 그때도 격자가 넘치지 않는다.
const body_pad_x: f32 = 0.0;
const body_pad_y: f32 = 0.0;

const key_gap: f32 = 4.0;
const key_h: f32 = 44.0;
const key_bar_pad_x: f32 = 6.0;
/// 키 라벨 크기. 44 카드에 15px 는 작아 눈에 안 들어왔다(화면으로 확인).
const key_font: f32 = 20.0;
/// 좌우 스크롤 여지 표시(`<`/`>`)가 차지하는 폭. **키가 지나가는 창은 이 안쪽**이라, 표시가
/// 가장자리 키 위에 얹혀 라벨을 지우지 않는다.
const edge_w: f32 = 26.0;

/// 키바 밴드의 **세로 범위**(스크롤 판정용). 가로는 안 본다 — 키바가 한 줄을 통째로 쓰고,
/// 스크롤로 밀려 키가 없는 자리도 밴드 안이다.
/// 앱 바의 **복사** 자리. 폭이 0 이면 지금 선택이 없어 안 그려졌다는 뜻이다.
var term_copy_rect: SetRect = .{};
/// 키보드를 다시 올리는 자리(앱 바). **늘 있다** — 없으면 한 번 내린 키보드를 못 올린다.
var term_kb_rect: SetRect = .{};
var term_kb_pressed = false;

/// 그 자리 한가운데(테스트용).
pub fn terminalKeyboardCenter() ?struct { x: f32, y: f32 } {
    if (term_kb_rect.w <= 0) return null;
    return .{ .x = term_kb_rect.x + term_kb_rect.w / 2, .y = term_kb_rect.y + term_kb_rect.h / 2 };
}

/// 원격 연결을 **사용자 뜻으로** 끊는 자리(앱 바). **늘 있다** — 뒤로가기는 화면만 빠져나오고
/// 연결은 그대로 두므로(계약: 목록으로 돌아가도 세션은 산다), 끊을 길이 따로 없었다.
///
/// **파괴적이지 않다.** 우리가 놓는 것은 SSH 연결이지 원격의 작업이 아니다 — tmux 를 쓰면
/// 세션은 서버에 그대로 남고 다시 붙으면 이어진다. 그래서 되묻지 않는다.
var term_disc_rect: SetRect = .{};
var term_disc_pressed = false;

/// 그 자리 한가운데(테스트용).
pub fn terminalDisconnectCenter() ?struct { x: f32, y: f32 } {
    if (term_disc_rect.w <= 0) return null;
    return .{ .x = term_disc_rect.x + term_disc_rect.w / 2, .y = term_disc_rect.y + term_disc_rect.h / 2 };
}

/// **끊어 달라는 요청.** host 가 가져가 펌프를 세운다 — 브리지는 소켓을 모른다(계약 §2:
/// 브리지는 그리고 판정만 하고, 바깥일은 host 가 한다). `take` 한 번에 한 번만 나간다.
var disconnect_req: bool = false;
pub export fn maru_mobile_take_disconnect() u32 {
    if (!disconnect_req) return 0;
    disconnect_req = false;
    return 1;
}
/// 배너가 먹은 높이(0 이면 없다). **본문을 밀지 않는다** — 코어 격자를 줄이면 원격이 믿는
/// 크기와 갈리고, 배너는 잠깐 뜨는 것이라 그 값이 오르내리면 원격에 resize 가 쏟아진다.
var term_banner_h: f32 = 0;
var term_copy_pressed = false;

/// 그 자리 한가운데(테스트용). 선택이 없으면 null — **없는 버튼을 누르는 테스트**를 막는다.
pub fn terminalCopyCenter() ?struct { x: f32, y: f32 } {
    if (term_copy_rect.w <= 0) return null;
    return .{ .x = term_copy_rect.x + term_copy_rect.w / 2, .y = term_copy_rect.y + term_copy_rect.h / 2 };
}

/// 터미널 앱 바의 자리(레이아웃이 잡아 준 값). **폭이 0 이면 안 그려졌다는 뜻**이고 그때는
/// 누름 판정도 서지 않는다 — 옛 자리를 답하면 없는 버튼이 눌린다(키바가 같은 규율을 갖는다).
/// 그 세션의 이름. **목록과 앱 바가 같은 말을 써야** 어디에 있는지 안다 — 두 곳에 따로 적으면
/// 갈린다(세션이 여럿이 되면 M3/U2 가 이 값을 세션에서 가져온다).
/// 세션 화면 제목. 모바일 화면은 **언어를 런타임에 못 바꾼다**(설정 행 목록이 comptime — I3b 참고)
/// 므로 `tIn(.ko, …)` 로 현행을 고정한다. 모바일이 OS 로케일을 받는 슬라이스가 이 고정을 푼다.
const session_title = maru.i18n.tIn(.ko, .set_section_terminal);

var term_bar_rect: SetRect = .{};
/// 터미널 앱 바의 뒤로가기 자리.
var term_back_rect: SetRect = .{};

/// 원격 화면에서 목록으로 돌아가는 자리(U2). 그려질 때 서고, 안 그려졌으면 `w == 0` 이라 누름
/// 판정도 안 선다(터미널 바와 같은 규칙).
var remote_back_rect: SetRect = .{};
/// 그 뒤로가기가 지금 눌려 있나.
var term_back_pressed: bool = false;
/// 터미널 앱 바의 제스처. 다른 표면과 같은 규칙을 쓴다(§3.1).
var term_press: gesture.Press = .{};
/// 레이아웃 트리에서 앱 바를 가리키는 id. 키바 id 대역과 안 겹치게 둔다.
const term_bar_id: u64 = 400;

var key_bar_band: struct { top: f32 = 0, bot: f32 = 0 } = .{};
// **키바는 안 흐른다.** 한 줄에 안 들어가면 두 줄로 접지 밀지 않는다(`keyBarRows`) — 그래서
// 스크롤 상태(`kb_sa`·`kb_touch`·`key_bar_max_scroll`)와 그 읽개(`kbScroll`)를 없앴다.
// 계약 §3.1·UX §5.4 는 이미 「밀 곳이 없다」고 적고 있었는데 **코드에만 잔해가 남아 있었다**
// (어느 것도 대입되거나 불리지 않았다 — 2026-09-05 적대적 검증).
/// 손가락이 지금 누르고 있는 키. **hover 가 없는 자리를 메우는 것이 눌림 표시**다(§2.4) —
/// 없으면 눌렀는지 화면이 답하지 않는다. 밀기로 판정되면 즉시 푼다(누른 것이 아니었으므로).
var kb_pressed: ?usize = null;

/// **이 터치가 어디로 가는가.** `down` 이 정하고 그 제스처는 끝까지 거기로 간다(계약 §3.1 —
/// chrome → 키바 → 본문 순). **판정을 코어가 든다** — 전에는 host 가 `chrome_active`·
/// `keybar_active` 로 같은 것을 들었고, 같은 상태가 두 층에 있으니 정리도 두 곳에서 해야 했다
/// (한쪽을 빠뜨려 "복귀 후 첫 손짓이 통째로 삼켜지는" 결함이 났다).
const Route = enum { chrome, keybar, body };
var route: ?Route = null;

/// 지금 목적지에 **닿아 있는 손가락이 하나도 없나.** `up` 이 안 온 채 끝난 제스처가 목적지를
/// 붙잡고 있으면 그 표면이 다음 터치를 계속 먹어 **다른 자리를 눌러도 아무 일이 안 난다** —
/// 이 저장소에서 그 "굳음" 을 두 번 겪었다(키바 잡음·iOS `_hasBodyPtr`). 상태가 사실과
/// 어긋났으면 **다음 `down` 이 고친다**.
fn routeStale() bool {
    return switch (route orelse return false) {
        // **손가락이 잡고 있는 동안은 안 놓는다**(계약 §3.1). 스크롤이 없어졌다고 이 조건까지
        // 없애면, 둘째 손가락이 본문에 닿는 순간 목적지를 뺏겨 **선택이 지워진다**(테스트가 잡았다).
        .keybar => kb_owner == null,
        .chrome => set_touch.owner == null and !set_press.active() and !sess_press.active() and !term_press.active(),
        .body => body_owner == null,
    };
}

/// 목적지를 잡는다. 주인이 있으면 실패하되, **그 주인이 손가락을 다 뗐으면 빼앗는다**(위).
///
/// **손가락 id 는 안 받는다.** 처음엔 `route_owner` 로 들었는데 **읽는 자리가 한 곳도 없었다**
/// — 소유 판정은 이미 표면마다 자기 손가락으로 한다(`kb_owner`·`body_owner`·
/// `set_touch.owner`) 그리고 `routeStale` 이 그것을 본다. 같은 사실을 두 곳에 두면 정리도 두
/// 곳이 되고, 그것이 R 이 host 에서 없앤 바로 그 병이다.
fn routeClaim(r: Route) bool {
    if (route != null) {
        if (!routeStale()) return false;
        routeClear();
    }
    route = r;
    return true;
}

/// 이 표면이 지금 제스처의 주인인가.
fn routeIs(r: Route) bool {
    return route == r;
}

/// 제스처가 끝났다 — 목적지를 놓는다.
fn routeClear() void {
    route = null;
}

/// 키바의 제스처. **뜻은 상태 하나가 든다**(계약 §3.1) — 전에는 `kb_stop_tap`·`kb_moved`·
/// `kb_down_x/y` 가 따로 있었다.
var kb_press: gesture.Press = .{};
/// 가로 스크롤 델타의 기준. **제스처 상태가 아니다** — 임계와 무관하게 매 move 갱신한다.
var kb_last_x: f32 = 0;

/// 터미널 앱 바 — 왼쪽 뒤로가기, 가운데 세션 이름. **오른쪽은 비운다**(설정 입구는 부모
/// 화면에 있고, 여기 또 두면 같은 것이 두 자리가 된다).
/// 연결 상태 배너. **본문보다 나중에 그린다** — 앱 바 바로 아래는 본문 사각형이 시작하는
/// 자리라, 먼저 그리면 셀 격자가 그 위를 덮는다(기기에서 아무것도 안 보였다).
fn drawConnBanner(tk: *const tokens.Tokens) void {
    if (term_bar_rect.w <= 0) return;
    // **연결 상태.** 실패했을 때 사용자가 있는 자리가 이 화면이다(빈 터미널) —
    // 로그로만 남기면 무엇을 고쳐야 하는지 알 길이 없다. 붙은 뒤에는 아무 말도 안 한다.
    term_banner_h = 0;
    if (connectionMessage()) |msg| {
        const by = term_bar_rect.y + term_bar_rect.h;
        // **접힌 줄 수를 먼저 센다** — 배경을 글보다 먼저 그려야 하는데, 높이는 글이 정한다.
        // 안 세고 30 으로 두면 두 줄짜리 안내가 배경 밖으로 나가 본문 위에 맨몸으로 얹힌다.
        const font: i32 = 14;
        const max_w = @as(i32, @intFromFloat(term_bar_rect.w - 2 * set_pad_x));
        const rows = wrappedLineCount(msg, max_w, font);
        const line_h: i32 = font + @divTrunc(font, 4);
        const bh: f32 = @max(30.0, @as(f32, @floatFromInt(@as(i32, @intCast(rows)) * line_h)) + 16.0);
        push(.{ .x = @intFromFloat(term_bar_rect.x), .y = @intFromFloat(by), .w = @intFromFloat(term_bar_rect.w), .h = @intFromFloat(bh) }, tk.get(.tab_hover_bg), 0xFF, 0, 0);
        // 실패는 강조색, 진행 중은 흐린 색 — 같은 자리에 두되 **읽는 무게가 다르다**.
        const role: tokens.ColorRole = if (conn_err_len > 0) .accent_bar else .muted_fg;
        const text_h = @as(f32, @floatFromInt(@as(i32, @intCast(rows)) * line_h));
        _ = pushTextWrapped(msg, @intFromFloat(term_bar_rect.x + set_pad_x), @intFromFloat(by + (bh - text_h) / 2), max_w, font, tk.get(role));
        term_banner_h = bh;
    }
}

fn drawTerminalBar(tk: *const tokens.Tokens) void {
    term_back_rect = .{};
    if (term_bar_rect.w <= 0) return; // 안 그려졌으면 누름 판정도 안 선다

    push(.{
        .x = @intFromFloat(term_bar_rect.x),
        .y = @intFromFloat(term_bar_rect.y),
        .w = @intFromFloat(term_bar_rect.w),
        .h = @intFromFloat(term_bar_rect.h),
    }, tk.get(.surface_bg), 0xFF, 0, 0);

    // **44 이상 정사각**(§5.1 — 작게 그리고 넓게 받는다). 설정 화면과 같은 자리·같은 크기다.
    term_back_rect = .{ .x = term_bar_rect.x, .y = term_bar_rect.y, .w = set_head_h, .h = set_head_h };
    noteA11y(term_back_rect, .{ .role = .button, .label = maru.i18n.tIn(.ko, .mob_a11y_back) });
    if (term_back_pressed) push(.{
        .x = @intFromFloat(term_back_rect.x),
        .y = @intFromFloat(term_back_rect.y),
        .w = @intFromFloat(term_back_rect.w),
        .h = @intFromFloat(term_back_rect.h),
    }, tk.get(.tab_hover_bg), 0xFF, 8, 0);
    if (reserveQuad()) {
        const rgb = tk.get(.surface_fg);
        quad_buf[quad_count] = .{
            .x = term_back_rect.x + (set_head_h - 22) / 2,
            .y = term_back_rect.y + (set_head_h - 22) / 2,
            .w = 22,
            .h = 22,
            .r = @as(f32, @floatFromInt(rgb.r)) / 255.0,
            .g = @as(f32, @floatFromInt(rgb.g)) / 255.0,
            .b = @as(f32, @floatFromInt(rgb.b)) / 255.0,
            .a = 1.0,
            .radius = 0,
            .kind = 2,
            .cell_x = 0,
            .cell_y = arrow_slot_base + 2, // arrow_left — 설정 화면과 같은 글리프
        };
        quad_count += 1;
    }

    // **복사는 선택이 있을 때만 있다.** 키바에 늘 두던 것을 여기로 옮겼다(사용자 요청으로 키바가
    // 두 줄 격자가 되며 자리가 없어졌다) — 그리고 이 편이 맞다: 쓸 수 없는 버튼이 늘 한 칸을
    // 먹는 대신, 쓸 수 있을 때만 나타난다.
    //
    // **나타나고 사라지는 것이 다른 버튼을 안 민다.** 오른쪽 끝 고정 자리이고, 뒤로가기·제목은
    // 왼쪽에 있다(키바에서 "조건부 키를 두면 손가락이 겨눈 자리가 바뀐다" 고 적어 둔 그 이유다).
    // **키보드를 다시 올리는 자리.** 앱이 키보드를 안 내리지만 사용자가 한 번 내리면
    // (스와이프·⌘K) 다시 올릴 길이 없었다 — 설정 칸을 누르는 것 말고는(사용자 요청).
    term_kb_rect = .{ .x = term_bar_rect.x + term_bar_rect.w - set_head_h * 2, .y = term_bar_rect.y, .w = set_head_h, .h = set_head_h };
    noteA11y(term_kb_rect, .{ .role = .button, .label = maru.i18n.tIn(.ko, .mob_keyboard) });
    if (term_kb_pressed) push(.{
        .x = @intFromFloat(term_kb_rect.x),
        .y = @intFromFloat(term_kb_rect.y),
        .w = @intFromFloat(term_kb_rect.w),
        .h = @intFromFloat(term_kb_rect.h),
    }, tk.get(.tab_hover_bg), 0xFF, 8, 0);
    {
        const kb_label = maru.i18n.tIn(.ko, .mob_keyboard);
        pushText(
            kb_label,
            @intFromFloat(term_kb_rect.x + (set_head_h - @as(f32, @floatFromInt(textWidth(kb_label, 15)))) / 2),
            @intFromFloat(term_kb_rect.y + (set_head_h - 15) / 2),
            15,
            tk.get(.surface_fg),
        );
    }

    // **끊는 자리.** 자판 왼쪽 고정이다 — 복사가 나타났다 사라져도 이 자리는 안 움직인다
    // (조건부 버튼이 다른 버튼을 밀면 손가락이 겨눈 자리가 바뀐다).
    term_disc_rect = .{ .x = term_bar_rect.x + term_bar_rect.w - set_head_h * 3, .y = term_bar_rect.y, .w = set_head_h, .h = set_head_h };
    noteA11y(term_disc_rect, .{ .role = .button, .label = maru.i18n.tIn(.ko, .mob_disconnect) });
    if (term_disc_pressed) push(.{
        .x = @intFromFloat(term_disc_rect.x),
        .y = @intFromFloat(term_disc_rect.y),
        .w = @intFromFloat(term_disc_rect.w),
        .h = @intFromFloat(term_disc_rect.h),
    }, tk.get(.tab_hover_bg), 0xFF, 8, 0);
    {
        const disc_label = maru.i18n.tIn(.ko, .mob_disconnect);
        pushText(
            disc_label,
            @intFromFloat(term_disc_rect.x + (set_head_h - @as(f32, @floatFromInt(textWidth(disc_label, 15)))) / 2),
            @intFromFloat(term_disc_rect.y + (set_head_h - 15) / 2),
            15,
            tk.get(.surface_fg),
        );
    }

    term_copy_rect = .{};
    if (copyEnabled()) {
        term_copy_rect = .{ .x = term_bar_rect.x + term_bar_rect.w - set_head_h, .y = term_bar_rect.y, .w = set_head_h, .h = set_head_h };
        noteA11y(term_copy_rect, .{ .role = .button, .label = maru.i18n.tIn(.ko, .mob_copy) });
        if (term_copy_pressed) push(.{
            .x = @intFromFloat(term_copy_rect.x),
            .y = @intFromFloat(term_copy_rect.y),
            .w = @intFromFloat(term_copy_rect.w),
            .h = @intFromFloat(term_copy_rect.h),
        }, tk.get(.tab_hover_bg), 0xFF, 8, 0);
        const label = maru.i18n.tIn(.ko, .mob_copy);
        pushText(
            label,
            @intFromFloat(term_copy_rect.x + (set_head_h - @as(f32, @floatFromInt(textWidth(label, 15)))) / 2),
            @intFromFloat(term_copy_rect.y + (set_head_h - 15) / 2),
            15,
            tk.get(.accent_bar),
        );
    }

    // 제목은 그 세션의 이름이다 — 목록에서 누른 그 줄과 같은 말이라야 어디에 있는지 안다.
    pushText(
        session_title,
        @intFromFloat(term_bar_rect.x + set_head_h),
        @intFromFloat(term_bar_rect.y + (set_head_h - 17) / 2),
        17,
        tk.get(.surface_fg),
    );
    push(.{
        .x = @intFromFloat(term_bar_rect.x),
        .y = @intFromFloat(term_bar_rect.y + term_bar_rect.h - 1),
        .w = @intFromFloat(term_bar_rect.w),
        .h = 1,
    }, tk.get(.divider), 0xFF, 0, 0);
}

/// 키 하나를 그린다 — 테두리 + 키캡 면 + 가운데 라벨.
fn drawKey(i: usize, kx: f32, ky: f32, kw: f32, tk: *const tokens.Tokens) void {
    // **눌린 키는 눌린 것처럼 보인다.** armed(sticky 수정자가 켜진 상태)와 다른 축이다 —
    // armed 는 `ctrl` 처럼 **다음 글자까지 유지되는 상태**이고, pressed 는 **지금 손가락이
    // 닿아 있다**는 순간 표시다. 이게 없으면 `ctrl` 말고는 눌러도 화면이 답하지 않는다.
    const pressed = kb_pressed != null and kb_pressed.? == i;
    // **켜진 비트와 대조한다.** 예전에는 `armed_mods != 0` 만 봐서, ctrl 을 켜면 sticky 를 가진
    // 키가 **전부** 함께 밝아졌다 — 화면에는 alt 도 눌린 것으로 보였다(기기 실측). 실제로 나가는
    // 것은 ctrl 하나뿐이라(`armed_mods` 에는 하나만 실린다) **손가락이 거짓말을 보던** 자리다.
    const armed = armed_mods & key_bar[i].sticky_mod != 0;
    // **판정을 그리기 경로 안에서 세운다.** 값(`armed_mods`)만 맞고 그려지는 것이 틀린 결함을 이
    // 저장소가 여러 번 겪었다 — 이 자리가 정확히 그 부류였다. 밖에서 볼 수 있어야 테스트가 잡는다.
    if (armed) keybar_armed_drawn |= key_bar[i].sticky_mod;
    // **못 쓰는 키는 흐리다.** `copy` 는 늘 줄에 있지만 선택이 없으면 눌러도 아무 일이 없다 —
    // 그것이 화면에 보여야 한다(눌렀는데 무반응이면 고장으로 읽힌다).
    const dimmed = key_bar[i].is_copy and !copyEnabled();
    const r: draw.Rect = .{
        .x = @intFromFloat(kx),
        .y = @intFromFloat(ky),
        .w = @intFromFloat(kw),
        .h = @intFromFloat(key_h),
    };
    // **경계선을 또렷하게 긋는다.** 손가락은 마우스와 달리 hover 로 더듬을 수 없어 **눌리는
    // 자리가 보이는 것이 크기보다 먼저**다(테두리 없이 44 로 키웠더니 어디까지가 한 키인지
    // 화면에서 안 보였다).
    push(r, tk.get(if (armed or pressed) .accent_bar else if (dimmed) .divider else .muted_fg), 0xFF, 10, 0);
    const in: i32 = 2;
    // **키캡처럼 면을 띄운다.** 채움이 본문 배경과 같으면 속이 빈 윤곽선으로 보인다 — 실제
    // 키보드처럼 눌리는 면이 배경보다 밝아야 "누를 것" 으로 읽힌다.
    push(.{ .x = r.x + in, .y = r.y + in, .w = r.w - 2 * @as(u32, @intCast(in)), .h = r.h - 2 * @as(u32, @intCast(in)) }, tk.get(if (armed or pressed) .tab_active_bg else .tab_hover_bg), 0xFF, 8, 0);
    // **아이콘이 있으면 아이콘을 그린다**(kind=2 — 아이콘 아틀라스 슬롯). 방향키가 그렇다:
    // 폰트 글리프는 폰트마다 작게 디자인돼 글자 라벨보다 훨씬 작아 보였다(화면으로 확인).
    // 합성 아이콘은 슬롯을 가장자리까지 채워 크기를 우리가 정한다.
    if (key_bar[i].icon_slot) |slot| {
        const ic: f32 = 22.0; // 44 키캡 안에서 여백을 남기는 크기
        if (!reserveQuad()) return;
        const rgb = tk.get(if (armed or pressed) .accent_bar else if (dimmed) .muted_fg else .surface_fg);
        quad_buf[quad_count] = .{
            .x = kx + (kw - ic) / 2,
            .y = ky + (key_h - ic) / 2,
            .w = ic,
            .h = ic,
            .r = @as(f32, @floatFromInt(rgb.r)) / 255.0,
            .g = @as(f32, @floatFromInt(rgb.g)) / 255.0,
            .b = @as(f32, @floatFromInt(rgb.b)) / 255.0,
            .a = 1.0,
            .radius = 0,
            .kind = 2,
            // **슬롯은 세로 인덱스다** — 아이콘 아틀라스가 슬롯을 세로로 쌓는다(host 가
            // `slot_px × slot_px*count` 텍스처를 만든다). `cell_x` 에 넣으면 빈 칸이 나온다.
            .cell_x = 0,
            .cell_y = slot,
        };
        quad_count += 1;
        return;
    }
    // 라벨은 키 한가운데. **실제 폭으로 잰다** — 글자 수 × 근사치로 재면 advance 가 다른 글자가
    // 왼쪽으로 쏠린다(화면으로 확인).
    const label_w: f32 = @floatFromInt(textWidth(key_bar[i].label, @intFromFloat(key_font)));
    pushText(key_bar[i].label, @intFromFloat(kx + (kw - label_w) / 2), @intFromFloat(ky + (key_h - key_font) / 2), @intFromFloat(key_font), tk.get(if (armed or pressed) .accent_bar else if (dimmed) .muted_fg else .surface_fg));
}

/// 본문 세로 관성을 한 프레임 몫만큼 흘린다. **키바·설정과 같은 자리에서 돈다.**
///
/// **전에는 host 가 이것을 들었다.** 그때는 host 가 목적지도 알아서(`keybar_active`) "본문
/// 제스처일 때만" 속도를 쟀는데, R2 로 그 지식을 걷어내면서 **가드까지 같이 사라져** 키바를
/// 비스듬히 튕기면 본문이 흘렀다. 관성은 목적지를 아는 쪽이 들어야 한다 — 여기가 그 자리다.
///
/// **손가락이 닿아 있는 동안에는 안 흘린다**(키바와 같은 이유 — `move` 가 이미 그만큼 흘렸다).
fn stepBodyFling() void {
    if (body_fling == 0) return;
    if (body_owner != null) return; // 아직 끌고 있다
    // 밀린 화면 뒤에서 계속 흐르면 돌아왔을 때 보던 자리가 아니다(`maru_mobile_scroll` 도
    // 같은 판정을 하지만, 여기서 멈춰야 **관성 자체가** 그 화면에 갇혀 있지 않는다).
    if (screenTop() != .terminal) {
        body_fling = 0;
        return;
    }
    // **간격은 위아래로 자른다** — `Touch.step` 과 같은 규칙이다(멈췄다 재개한 프레임의 dt 를
    // 그대로 곱하면 한 프레임에 화면을 날린다). 두 host 가 들고 있던 상한을 여기로 옮겼다.
    const dt = std.math.clamp(frame_dt_ms, 1, 100);
    maru_mobile_scroll(body_fling * dt);
    // **끝에 닿았을 때 속도를 따로 죽이지 않는다.** `Touch.step` 은 그렇게 하지만 여기서는
    // 관측되는 차이가 없다 — 다음 `down` 이 이미 속도를 0 으로 만들어 "죽은 속도가 남아
    // 튄다" 가 성립하지 않고, 감쇠가 1초 안에 스스로 멈춘다. 조건을 뒤집는 변이로 확인했다
    // (아무 테스트도 안 깨졌다). 헛방어를 남기면 다음 사람이 그것을 계약으로 읽는다.
    body_fling *= std.math.pow(f32, scroll_area.Touch.decay_per_ms, dt);
    if (@abs(body_fling) < scroll_area.Touch.stop_below) body_fling = 0;
}

/// 보조 키바 포인터. **탭과 가로 스크롤을 여기서 가른다** — 키가 화면을 넘치므로 손가락으로
/// 밀어 나머지에 닿아야 하고, 그러면 down 에서 바로 키를 누를 수 없다(밀려던 것이 입력이 된다).
/// up 까지 기다려 **움직인 거리가 임계 아래일 때만** 키로 친다.
///
/// phase: 0=down · 1=move · 2=up · 3=cancel. 반환 1=키바가 먹었다(플랫폼은 본문 처리 안 함).
/// 라벨로 키 번호를 찾는다(테스트·진단용). **번호를 손으로 적으면 배열이 바뀔 때 조용히 다른
/// 키를 누른다** — 두 줄 격자로 재배치하며 실제로 그랬다(ctrl 이 셋째에서 일곱째가 됐다).
pub fn keybarIndexOf(label: []const u8) ?u32 {
    for (key_bar, 0..) |k, i| {
        if (std.mem.eql(u8, k.label, label)) return @intCast(i);
    }
    return null;
}

/// 이 격자를 잡고 있는 손가락. **소유자가 떼야 놓인다**(계약 §3.1) — 둘째 손가락이 떼는 것으로
/// 목적지가 풀리면, 첫 손가락이 아직 키 위에 있는데 다음 터치가 본문으로 샌다.
var kb_owner: ?u32 = null;

fn keybarPointer(phase: u32, pointer_id: u32, x: f32, y: f32, time_ms: u64) u32 {
    // **취소는 잡고 있지 않아도 받는다.** host 는 배경으로 나갈 때 좌표 없이 취소만 보내는데
    // (`maru_mobile_pointer(3,0,0,0)` 과 짝), 그때 여기서 안 풀면 목적지가 남아 **복귀 후
    // 첫 터치가 통째로 키바로 간다** — 본문을 눌러도 아무 일이 안 일어난다.
    if (phase == 3) {
        if (routeIs(.keybar)) routeClear();
        kb_owner = null;
        kb_pressed = null;
        kb_press.cancel();
        return 0;
    }
    if (phase == 0) {
        if (!key_bar_ready) return 0;
        if (y < key_bar_band.top or y >= key_bar_band.bot) return 0;
        // **둘째 손가락은 누름 판정을 안 건드린다**(계약 §3.1 — 표면마다 한 제스처).
        if (routeIs(.keybar)) return 1;
        if (!routeClaim(.keybar)) return 0; // 이미 다른 표면의 제스처다
        kb_owner = pointer_id;
        kb_press.begin(x, y, time_ms, false); // **흐르는 것이 없다** — 두 줄 격자라 스크롤이 없다
        // **누르는 즉시 보여 준다.** 입력은 up 에서 나가지만 표시는 down 에서 서야 손가락이
        // "닿았다" 를 안다 — hover 가 없는 자리를 이것이 메운다(§2.4).
        kb_pressed = keybarIndexAt(x, y);
        return 1;
    }
    if (!routeIs(.keybar)) return 0;
    if (phase == 1) {
        // **소유자의 움직임만 판정을 건드린다.** 둘째 손가락이 움직였다고 첫 손가락의
        // "탭이냐 아니냐" 가 바뀌면 안 된다.
        if (kb_owner != pointer_id) return 1;
        // 임계를 넘으면 밀려던 것이다 — 누른 것이 아니므로 표시를 거둔다. 밀 곳은 없지만
        // (격자다) **손가락이 미끄러진 채로 키가 나가면 안 되는 것**은 그대로다.
        if (kb_press.move(x, y)) kb_pressed = null;
        return 1;
    }
    // **비소유자가 떼는 것은 이 제스처를 안 끝낸다**(계약 §3.1).
    if (kb_owner != pointer_id) return 1;
    kb_owner = null;
    kb_pressed = null;
    routeClear();
    const down_x = kb_press.down_x;
    const down_y = kb_press.down_y;
    if (kb_press.end() == .tap) _ = keybarTapAt(down_x, down_y);
    return 1;
}

/// 보조 키바 탭. **좌표는 여기서만 해석한다** — 그리는 자리와 판정하는 자리가 갈리면
/// 눌러도 다른 키가 나간다. 1=이 탭은 키바가 먹었다, 0=키바 밖(플랫폼이 본문 처리로).
fn keybarTapAt(x: f32, y: f32) u32 {
    const i = keybarIndexAt(x, y) orelse return 0;
    const item = key_bar[i];
    if (item.is_copy) {
        // 선택이 없으면 **아무 일도 안 한다** — 흐리게 그려져 있어 눌러도 안 된다는 것이 보인다.
        if (copyEnabled()) copy_pending = true;
        return 1;
    }
    if (item.sticky_mod != 0) {
        // 토글이다 — 잘못 눌렀을 때 되돌릴 방법이 있어야 한다.
        armed_mods = if (armed_mods & item.sticky_mod != 0) 0 else item.sticky_mod;
        return 1;
    }
    // 수정자를 여기서 안 실는다 — `maru_mobile_key` 가 눌러 둔 것을 소비한다(한 곳).
    _ = maru_mobile_key(item.key_id, item.codepoint, 0);
    return 1;
}

/// 그 자리에 있는 키의 인덱스. **누르는 것과 그리는 것이 같은 판정을 쓴다** — 눌림 표시가
/// 실제로 나갈 키와 어긋나면 손가락이 거짓말을 본다.
fn keybarIndexAt(x: f32, y: f32) ?usize {
    if (!key_bar_ready) return null;
    for (key_bar_rects, 0..) |r, i| {
        // 창 밖 키는 그리기 쪽에서 rect 를 0 으로 지운다 — 빈 사각형은 어떤 점도 안 품으므로
        // **여기 따로 가시성 조건이 없다**. 조건이 둘이면 그리는 자리와 누르는 자리가 갈린다.
        if (x < r.x or x >= r.x + r.w or y < r.y or y >= r.y + r.h) continue;
        return i;
    }
    return null;
}

/// 눌러 둔 수정자(0 이면 없음). 화면 표시는 브리지가 이미 한다 — 계측·접근성 라벨용이다.
/// 복사할 것이 있으면 `out` 에 채우고 바이트 수를 답한다(없으면 0). **추출은 코어가 하고**
/// (soft-wrap 잇기·줄끝 개행·2셀 뒷칸 제외가 전부 거기 있다) 플랫폼은 클립보드에 쓰기만 한다.
///
/// 한 번 가져가면 요청은 사라진다 — 매 프레임 같은 것을 다시 쓰지 않게.
pub export fn maru_mobile_take_copy(out: [*]u8, cap: u32) u32 {
    if (!copy_pending) return 0;
    copy_pending = false;
    // **정해진 글자를 복사하는 자리도 여기다.** 요청을 둘로 두면 host 가 두 번 가져가야 하고,
    // 한쪽만 배선한 host 에서는 복사가 조용히 안 된다(그 화면만 안 되는 것을 사람이 못 찾는다).
    if (copy_text_len > 0) {
        const text = copy_text_buf[0..copy_text_len];
        copy_text_len = 0;
        if (text.len > cap) {
            setLastError("copy_truncated");
            return 0; // 반쪽 공개키는 서버에서 조용히 안 먹는다 — 자르느니 안 준다
        }
        @memcpy(out[0..text.len], text);
        return @intCast(text.len);
    }
    const core = &(term_core orelse return 0);
    const text = (core.extractSelection(term_allocator) catch {
        setLastError("copy_extract");
        return 0;
    }) orelse return 0;
    defer term_allocator.free(text);
    // **문자 경계에서 자른다.** 바이트로만 자르면 한글·이모지가 반 토막 나고, iOS 는 그
    // 조각으로 NSString 을 못 만들어 **클립보드를 아예 안 쓴다**(그 자리에 else 가 없어
    // 로그도 안 남는다) — 사용자는 복사된 줄 알고 옛 내용을 붙여넣는다. Android 는
    // `NewStringUTF` 가 잘못된 바이트를 받아 CheckJNI 에서 abort 한다.
    // 규칙은 `width.truncateToBoundary` 가 단일 출처다(여기서 다시 세면 또 갈린다).
    const n = maru.width.truncateToBoundary(text, cap);
    if (n < text.len) setLastError("copy_truncated"); // 조용히 자르지 않는다
    @memcpy(out[0..n], text[0..n]);
    return @intCast(n);
}

pub export fn maru_mobile_armed_mods() u32 {
    return armed_mods;
}

/// 줄에 있는 키 수. **모든 키가 늘 줄에 있으므로 고정값이다** — 스크롤로 화면 밖에 나간 키도
/// 여기 센다(그건 `maru_mobile_keybar_rect` 가 0 으로 답해 가른다). 부르는 쪽이 rect 를 훑을
/// 상한으로 쓴다.
pub export fn maru_mobile_keybar_count() u32 {
    return key_bar.len;
}

/// 키 `index` 의 사각형(논리 px). x·y·w·h 를 각각 16비트로 담는다. 아직 안 섰으면 0.
/// **자리를 밖에서 다시 계산하지 말라고 내주는 값이다** — 손으로 적으면 레이아웃이 바뀔 때
/// 부르는 쪽만 맞고 화면은 틀리게 된다.
pub export fn maru_mobile_keybar_rect(index: u32) u64 {
    if (!key_bar_ready or index >= key_bar.len) return 0;
    const r = key_bar_rects[index];
    const x: u64 = @intFromFloat(@max(0, r.x));
    const y: u64 = @intFromFloat(@max(0, r.y));
    const w: u64 = @intFromFloat(@max(0, r.w));
    const h: u64 = @intFromFloat(@max(0, r.h));
    return (x << 48) | (y << 32) | (w << 16) | h;
}

pub export fn maru_mobile_scroll_to_bottom() void {
    const core = &(term_core orelse return);
    core.scrollToBottom();
    scroll_px_carry = 0;
}

pub export fn maru_mobile_view_offset() u32 {
    const core = &(term_core orelse return 0);
    return @intCast(core.viewOffset());
}

/// 포커스 변화를 코어에 알린다(DEC 1004). 켜져 있으면 `CSI I`/`CSI O` 가 흐르고 vim 의
/// FocusGained/Lost 가 그걸 본다 — 모바일은 배경↔복귀가 데스크톱보다 훨씬 잦다.
pub export fn maru_mobile_report_focus(focused: c_int) void {
    const core = &(term_core orelse return);
    core.reportFocus(focused != 0);
    drainUnconsumed(core);
}

// ── 포인터 조회 ───────────────────────────────────────────────────────────────
// 논리 좌표를 본문의 셀 좌표로 바꾼다. **배치를 아는 쪽이 답한다** — 플랫폼은 점만 넘긴다.
// 본문 rect·셀 크기는 마지막 build 가 정한 값을 그대로 쓴다(별도 상수를 두면 어긋난다).
var body_rect: struct { x: f32 = 0, y: f32 = 0, w: f32 = 0, h: f32 = 0 } = .{};
var body_cell_w: i32 = 1;
var body_line_h: i32 = 1;
/// 본문 사각형 안에 **실제로 있는** 격자 크기. 사각형은 격자보다 클 수 있다(나머지 여백,
/// cols/rows 상한). 그 여백을 셀로 답하면 없는 셀을 가리키게 된다.
var body_cols: u16 = 0;
var body_rows: u16 = 0;

/// 상위 16비트=열, 하위 16비트=행. 본문 밖이거나 **격자 밖이면** 0xFFFFFFFF.
pub export fn maru_mobile_hit_cell(x: f32, y: f32) u32 {
    if (body_rect.w <= 0 or body_rect.h <= 0) return 0xFFFFFFFF;
    if (x < body_rect.x or y < body_rect.y or
        x >= body_rect.x + body_rect.w or y >= body_rect.y + body_rect.h) return 0xFFFFFFFF;
    const col = @divTrunc(@as(i32, @intFromFloat(x - body_rect.x)), @max(1, body_cell_w));
    const row = @divTrunc(@as(i32, @intFromFloat(y - body_rect.y)), @max(1, body_line_h));
    if (col < 0 or row < 0 or col >= body_cols or row >= body_rows) return 0xFFFFFFFF;
    return (@as(u32, @intCast(col)) << 16) | @as(u32, @intCast(row));
}

/// 커서(캐럿)가 있는 자리를 논리 px 로 답한다. **IME 후보창이 이걸 보고 따라온다** —
/// 조합 중 후보 목록이 엉뚱한 자리에 뜨면 글자를 가린다.
///
/// 배치를 아는 쪽이 답한다(§3) — 플랫폼이 셀 크기·본문 위치를 다시 계산하면 어긋난다.
/// 반환값은 x·y·w·h 를 각각 16비트로 담는다(전부 논리 px, 화면 밖이면 0).
pub export fn maru_mobile_caret_rect() u64 {
    const core = &(term_core orelse return 0);
    const cur = core.screen.cursor;
    if (body_cols == 0 or body_rows == 0) return 0;
    // **밀린 화면이 있으면 터미널은 안 보인다** — 그런데 소프트 키보드는 일부러 떠 있다(§5.2).
    // 자리를 답하면 iOS 가 **설정 UI 위에 한글 후보창**을 띄운다, 보이지도 않는 캐럿에 앵커해서.
    if (screenTop() != .terminal) return 0;
    // 헤더가 약속한 "화면 밖이면 0". 그리는 쪽은 격자 범위를 검사하는데(§커서) 여기만 안 해서,
    // 격자가 줄어든 직후 화면 밖 자리를 답할 수 있었다.
    if (cur.col >= body_cols or cur.row >= body_rows) return 0;
    // **스크롤백은 여기서 0 이 아니다.** 커서를 그리지는 않지만 코어가 live 위치를 일부러
    // 보존한다 — "IME 후보창은 scroll-to-bottom 이 적용되기 전에도 이 anchor 를 즉시 써야
    // 한다"(`screen.renderSnapshot`). 타이핑하면 어차피 바닥으로 튄다.
    // **조합 중이면 앵커도 그 뒤다.** 후보창은 지금 치고 있는 글자 **다음**에 떠야 한다 —
    // 조합 시작 자리에 띄우면 자기가 방금 만든 글자를 가린다. 커서를 그리는 자리와 **같은
    // 판정**을 쓴다(`cursorColOnScreen`): 두 벌로 세면 화면과 후보창이 어긋난다.
    const anchor_col = cursorColOnScreen(cur.col, body_cols);
    const x = body_rect.x + @as(f32, @floatFromInt(@as(i32, anchor_col) * body_cell_w));
    const y = body_rect.y + @as(f32, @floatFromInt(@as(i32, cur.row) * body_line_h));
    return (@as(u64, @intFromFloat(@max(0, x))) << 48) |
        (@as(u64, @intFromFloat(@max(0, y))) << 32) |
        (@as(u64, @intCast(body_cell_w)) << 16) |
        @as(u64, @intCast(body_line_h));
}

/// 셀 색을 RGB 로 푼다. indexed 는 maru 자체 팔레트(`color.xterm256`)를 쓴다 —
/// 모바일용으로 색표를 새로 만들지 않는다.
fn resolveColor(c: terminal.types.Color, fallback: color.Rgb) color.Rgb {
    return switch (c) {
        .default => fallback,
        .indexed => |i| color.xterm256(i),
        .rgb => |v| v,
    };
}

/// 그 칸이 실제로 낼 **글자색**(테스트·진단용). 화면 quad 는 아틀라스에 셀이 있어야 나므로
/// (굽기가 밀리면 안 난다) 속성이 제대로 풀리는지는 이 값으로 잰다 — 예전에는 데모 줄을
/// 눈으로 보는 것이 유일한 판정이었다.
pub fn cellFgAt(row: u16, col: u16) ?color.Rgb {
    const core = &(term_core orelse return null);
    const snap = core.snapshot();
    if (row >= term_rows or col >= term_cols) return null;
    const tk = tokens.Tokens.rich(themeColors());
    return paintCell(snap.cells[core.index(row, col)].style, &tk).fg;
}

/// 그 칸의 글자가 차지하는 칸 수(1 또는 2). 폭이 틀리면 화면이 통째로 밀린다.
pub fn cellWidthAt(row: u16, col: u16) ?u8 {
    const core = &(term_core orelse return null);
    const snap = core.snapshot();
    if (row >= term_rows or col >= term_cols) return null;
    const cell = snap.cells[core.index(row, col)];
    if (cell.continuation) return 0; // 2셀 글자의 **뒷칸**이다(앞칸이 폭을 든다)
    if (cell.codepoint == 0) return 1;
    return @intCast(maru.width.cellWidth(cell.codepoint));
}

/// 팔레트 색(테스트·진단용). **테스트가 색 숫자를 손으로 적으면** 팔레트가 바뀔 때 조용히
/// 어긋난다 — 제품이 쓰는 함수를 그대로 묻는다.
pub fn paletteColor(i: u8) color.Rgb {
    return color.xterm256(i);
}

/// 지금 테마의 본문 배경색(테스트·진단용 — 숨김 셀의 글자가 이 색이다).
pub fn terminalBackgroundColor() color.Rgb {
    return hex(activeTheme().background, .{ .r = 0x1E, .g = 0x1E, .b = 0x2E });
}

/// 지금 테마의 전경색(테스트·진단용 — 반전 셀의 배경이 이 색이다).
pub fn foregroundColor() color.Rgb {
    return hex(activeTheme().foreground, .{ .r = 0xE6, .g = 0xE6, .b = 0xEA });
}

/// 셀 하나가 실제로 낼 색과 장식. **코어가 셀에 담은 속성을 여기서 푼다** — 예전에는
/// `foreground` 하나만 읽어서 배경색·reverse·밑줄·dim 이 전부 화면에서 사라졌다.
const CellPaint = struct {
    fg: color.Rgb,
    /// null = 표면 배경 그대로(quad 를 안 낸다). 값이 있으면 칸을 그 색으로 칠한다.
    bg: ?color.Rgb,
    line: color.Rgb,
    underline: bool,
    underline_double: bool,
    strikethrough: bool,
    overline: bool,
};

/// SGR 속성을 색으로 푼다. 규칙은 데스크톱과 같은 것을 쓴다:
///   * reverse(7) — 전경/배경을 맞바꾼다. **default 는 테마 값으로 풀고 나서** 바꾼다,
///     안 그러면 "기본색끼리 맞바꿈" 이 아무 일도 안 하게 된다.
///   * dim(2) — 전경을 배경 쪽으로 절반 보간한다(maru 전경엔 alpha 가 없어 RGB 보간으로 낸다).
///   * conceal(8) — 전경을 그 칸의 배경색으로 만든다(비밀번호 프롬프트).
///   * underline_color(58) — default 면 전경색을 쓴다.
/// blink(5)는 아직 정적이다(코어도 "렌더는 정적" 이라고 적어 둔 자리다).
fn paintCell(style: terminal.types.Style, tk: anytype) CellPaint {
    const surface_fg = tk.get(.surface_fg);
    // **본문 배경은 chrome 표면이 아니라 터미널 배경이다**(tokens.zig §4.1b). 예전에는 둘이
    // 같은 값이라 `surface_bg` 로 칠해도 티가 안 났는데, config 가 `theme.background` 를
    // 정하기 시작하면 그 순간 갈린다 — 사용자가 배경을 바꿔도 본문만 안 바뀐다.
    const surface_bg = tk.get(.terminal_bg);

    var fg = resolveColor(style.foreground, surface_fg);
    // 배경이 default 면 "칠하지 않는다" 는 뜻이라 null 로 둔다 — 표면 배경 위에 그대로 얹는다.
    var bg: ?color.Rgb = switch (style.background) {
        .default => null,
        else => resolveColor(style.background, surface_bg),
    };

    if (style.reverse) {
        const b = bg orelse surface_bg;
        bg = fg;
        fg = b;
    }
    const bg_for_blend = bg orelse surface_bg;
    if (style.dim) fg = .{
        .r = @intCast((@as(u16, fg.r) + bg_for_blend.r) / 2),
        .g = @intCast((@as(u16, fg.g) + bg_for_blend.g) / 2),
        .b = @intCast((@as(u16, fg.b) + bg_for_blend.b) / 2),
    };
    if (style.conceal) fg = bg_for_blend;

    return .{
        .fg = fg,
        .bg = bg,
        .line = resolveColor(style.underline_color, fg),
        .underline = style.underline,
        .underline_double = style.underline_double,
        .strikethrough = style.strikethrough,
        .overline = style.overline,
    };
}

fn sameRgb(a: color.Rgb, b: color.Rgb) bool {
    return a.r == b.r and a.g == b.g and a.b == b.b;
}

/// 같은 색이 이어지는 칸을 **하나의 quad 로 묶는다**. 칸마다 내면 80x24 만 해도 배경에서만
/// 1920 개가 나오고, 그것이 곧 quad 예산이다.
const Run = struct {
    active: bool = false,
    start: u16 = 0,
    rgb: color.Rgb = .{ .r = 0, .g = 0, .b = 0 },

    fn flush(self: *Run, end_col: u16, x0: i32, y: i32, cell_w: i32, h: i32) void {
        if (!self.active) return;
        const x = x0 + @as(i32, self.start) * cell_w;
        const w = @as(i32, end_col - self.start) * cell_w;
        if (w > 0 and h > 0) push(.{
            .x = x,
            .y = y,
            .w = @intCast(w),
            .h = @intCast(h),
        }, self.rgb, 0xFF, 0, 0);
        self.active = false;
    }

    fn note(self: *Run, col: u16, rgb: ?color.Rgb, x0: i32, y: i32, cell_w: i32, h: i32) void {
        const want = rgb orelse {
            self.flush(col, x0, y, cell_w, h);
            return;
        };
        if (self.active and sameRgb(self.rgb, want)) return;
        self.flush(col, x0, y, cell_w, h);
        self.active = true;
        self.start = col;
        self.rgb = want;
    }
};

/// 본문 사각형을 터미널 격자로 채운다.
/// 본문 한 줄의 높이. **레이아웃도 이 값을 봐야 한다** — 키바를 넣을지 말지가 「몇 줄이
/// 남는가」로 갈리는데, 그 식이 여기와 레이아웃에 따로 있으면 둘이 갈린다. 원격 화면(U2)도
/// 같은 값을 쓴다("여기서 따로 세면 본문과 갈린다" — 그 주석이 가리키던 자리가 여기다).
fn lineHeight() i32 {
    return @max(1, @as(i32, @intCast(cfg().font.size * cfg().font.line_height / 100)));
}

fn pushTerminal(rect: anytype, tk: anytype) void {
    // **본문 영역을 터미널 배경으로 깐다.** 창 전체는 chrome 표면색으로 칠해져 있는데(위
    // `push` 한 장), 본문은 그 위에 자기 배경을 가져야 한다 — 안 그러면 `theme.background`
    // 를 바꿔도 **글자 뒤가 안 바뀐다**(칠하는 셀만 바뀌고 빈 칸은 chrome 색으로 남는다).
    push(.{
        .x = @intFromFloat(rect.x),
        .y = @intFromFloat(rect.y),
        .w = @intFromFloat(rect.width),
        .h = @intFromFloat(rect.height),
    }, tk.get(.terminal_bg), 0xFF, 0, 0);
    // **글자 상자가 곧 칸이다**(계약 §4 — 글리프 기하). 아틀라스 슬롯 하나는 **양폭 상자**라
    // 단폭 글자는 왼쪽 절반만 쓴다. 줄 높이를 정하면 배율이 나오고, 칸 너비는 슬롯 절반이다.
    // 예전에는 상자(11x15)와 칸(5x22)이 달라서, 셀을 가장자리까지 채우는 합성 글리프가
    // 원리상 붙을 수 없었다.
    // **줄 높이는 config 가 정한다**(M10d). 예전에는 22 로 박혀 있어 글자 크기를 못 바꿨다 —
    // 모바일에서는 이 값이 곧 `font.size` 다(아틀라스 셀 기하가 고정이라 브리지가 직접 정한다).
    // **줄 높이는 글자 크기와 다른 손잡이다.** 백분율 100 이면 예전과 같다(= `font.size`).
    // 낮추면 글자는 그대로 두고 줄만 늘어난다 — 폰에서 그 한 줄이 비싸다.
    const line_h: i32 = lineHeight();
    const scale = @as(f32, @floatFromInt(line_h)) / @as(f32, @floatFromInt(atlas_cell_h));
    const cell_w: i32 = @max(1, @as(i32, @intFromFloat(@as(f32, @floatFromInt(atlas_cell_w)) * scale * 0.5)));
    // **여기에 chrome 라벨 크기가 있었다.** 본문 격자를 그리는 함수가 그것을 든 이유는 조합 중
    // 문자열을 `pushText` 로 그렸기 때문 하나뿐이었고, 그 경로가 격자와 어긋나는 것이 결함이었다.
    // 조합을 셀 상자로 옮기면서 이 상수의 소비자가 사라졌다 — 남겨 두면 "본문에도 chrome 크기가
    // 쓰인다" 는 잘못된 신호가 된다.
    const cols_f = @divTrunc(@as(i32, @intFromFloat(rect.width)), cell_w);
    const rows_f = @divTrunc(@as(i32, @intFromFloat(rect.height)), line_h);
    const cols: u16 = @intCast(@max(8, @min(max_cols, cols_f)));
    const rows: u16 = @intCast(@max(@as(i32, min_body_rows), @min(max_rows, rows_f)));

    // **크기가 바뀌면 코어를 다시 세우지 않고 `resize` 한다.** 새로 만들면 스크롤백과 화면
    // 상태가 통째로 날아간다 — 키보드를 올렸다 내리기만 해도 그렇게 된다(창이 리사이즈된다).
    // 지금은 고정 대본을 먹이고 있어 눈에 안 띄지만, 원격 세션이 붙으면 곧바로 드러난다.
    if (term_core != null and (term_cols != cols or term_rows != rows)) {
        // **실패했으면 기록도 안 바꾼다.** 예전에는 catch 로 오류만 적고 term_cols/rows 를
        // 새 값으로 덮어, 코어는 옛 크기인데 아래 격자 순회는 새 크기로 돌았다 — 없는 셀을
        // 읽는다(ReleaseSafe 범위 검사에 걸려 앱이 죽는다).
        if (term_core.?.resize(cols, rows)) {
            term_cols = cols;
            term_rows = rows;
        } else |_| setLastError("core_resize");
    }
    if (term_core == null) {
        term_core = terminal.core.TerminalCore.init(term_allocator, .{ .cols = cols, .rows = rows }) catch {
            // 조용히 비우면 본문만 사라진 채 아무 신호가 없다.
            setLastError("terminal_core_init");
            term_core = null;
            return;
        };
        term_cols = cols;
        term_rows = rows;
        // **이모지는 2칸이다**(데스크톱 기본 `text.emoji-width=wide` 와 같은 값). 이게 꺼져 있으면
        // 코어가 base+VS16 을 width 1 로 두는데, host 는 컬러 글리프를 **슬롯 전체(2셀)** 로 굽는다 —
        // 그리는 쪽이 단폭 규칙대로 **왼쪽 절반만** 샘플링해 `❤️` 가 세로로 반 잘려 나왔다(화면으로
        // 잡았다). 코어 주석이 데스크톱에서 겪은 같은 증상을 적어 두고 있다("1칸에 욱여넣어져").
        // 모바일은 아직 config 를 안 읽으므로(§1) 여기서 데스크톱 기본값과 맞춘다.
        //
        // **여기가 최종 자리는 아니다.** 이건 사용자 설정(`text.emoji-width`)이고 트레이드오프가
        // 있다 — 2칸은 모던 TUI 의 string-width 와 정합하지만, zsh ZLE 가 base+VS16 을 1칸으로
        // 가정하는 환경에서는 줄 편집이 밀린다. 지금은 데모 피드뿐이라 합의할 상대가 없어 무해하고,
        // **원격(M3)으로 실제 셸에 붙으면 사용자가 고를 수 있어야 한다** — M10(모바일 config
        // 스키마)에서 이 대입을 config 로 옮긴다.
        //
        // mode 2027 을 켜서 우회하지 않는다. 그건 **앱이 켜는 opt-in** 이고(DECRQM 으로 먼저 묻는다),
        // 터미널이 일방적으로 켜면 폭 합의가 한쪽만 바뀌어 커서·지우기가 통째로 어긋난다.
        term_core.?.emoji_wide = true;
        // **config 를 여기서 흘려 넣는다.** host 가 화면보다 먼저 config 를 읽으므로 그때는
        // 코어가 없었다 — 여기서 안 세우면 그 값들이 조용히 버려진다.
        applyConfigToCore(&term_core.?);
        drainUnconsumed(&term_core.?);
        // **코어가 서기 전에 온 원격 출력을 여기서 흘려 넣는다.** 세션은 첫 프레임보다 빨리
        // 붙을 수 있고(실측: iOS 에서 접속이 150ms, 그때 코어가 없었다), 그때 온 바이트를
        // 버리면 **세션의 첫 출력이 통째로 사라진다** — 배너·프롬프트가 그 자리다.
        if (pre_core_len > 0) {
            term_core.?.write(pre_core[0..pre_core_len]) catch setLastError("core_write_pre");
            pre_core_len = 0;
        }
    }
    const core = &(term_core orelse return);
    // **격자를 도는 기준은 코어가 실제로 들고 있는 크기다.** 우리가 요청한 크기를 쓰면
    // resize 가 실패했을 때 없는 셀을 읽는다. 요청값과 갈릴 수 있는 자리를 아예 없앤다.
    const grid_cols = core.size.cols;
    const grid_rows = core.size.rows;
    // **그리는 근거는 snapshot 이다 — 활성 화면이 아니다.** 스크롤백을 보는 동안 코어는 보이는
    // 윈도를 따로 합성하는데(`viewport_cells`), `screen.cells` 를 직접 읽으면 그 합성을 지나쳐
    // **스크롤해도 화면이 안 바뀐다**(view_offset 은 올라가는데 픽셀이 그대로였다 — 실측).
    // 커서 가시성도 여기 있다: snapshot 이 DECTCEM **그리고** 스크롤 여부를 이미 합성한다.
    const snap = core.renderSnapshot();

    // 포인터 조회가 **같은 값**을 쓰도록 기록한다 — 렌더와 판정이 갈리면 셀이 어긋난다.
    body_rect = .{ .x = rect.x, .y = rect.y, .w = rect.width, .h = rect.height };
    body_cell_w = cell_w;
    body_line_h = line_h;
    body_cols = grid_cols;
    body_rows = grid_rows;

    const ox = @as(i32, @intFromFloat(rect.x));
    const oy = @as(i32, @intFromFloat(rect.y));
    // 장식선 두께·자리. **칸 기준이다** — M4a3 에서 글자 상자를 칸과 같게 만들었으므로 둘이
    // 같은 말이 됐다. 그 전에는 칸(22)이 글자 상자(15)보다 높아 칸 기준으로 잡으면 밑줄이
    // 글자에서 5 논리 px 떨어져 줄 사이에 떴고(픽셀 실측), 그때는 글자 쪽에 맞춰 두었다.
    const rule: i32 = @max(1, @divTrunc(line_h, 16));
    // 윗줄은 **어센더 바로 위**다. 칸 맨 위(0)가 터미널 관례지만, 우리 셀은 굽는 baseline 이
    // 칸의 3/4 지점이라 위쪽에 5 논리 px 여백이 남는다 — 그 여백은 폰트 메트릭이 아니라 굽는
    // 방식의 부산물이라, 윗줄만 글자에서 멀어 보인다(실측: 어센더 위끝 5.3px, 윗줄 0px).
    // 밑줄이 베이스라인에서 1.5px 인 것과 같은 기준으로 맞춘다.
    const y_over = 4 * rule;
    const y_strike = @divTrunc(line_h, 2); // 취소선: 칸 한가운데
    // 밑줄은 **베이스라인 바로 아래**다. 칸 맨 아래에 두면 글자에서 3.7 논리 px 떨어져
    // 떠 보인다(픽셀 실측). 굽는 baseline 이 칸의 3/4 께라 그 조금 아래가 관례에 맞는다.
    const y_under = line_h - 4 * rule;
    const y_under2 = line_h - 2 * rule; // 이중밑줄의 **둘째** 줄은 그 아래

    // 선택 범위는 프레임마다 한 번만 묻는다(행마다 물으면 같은 답을 rows 번 계산한다).
    const sel = core.selectionViewportSpan();

    var row: u16 = 0;
    while (row < grid_rows) : (row += 1) {
        const y0 = oy + @as(i32, row) * line_h;

        // ── 1) 배경과 장식선을 먼저. **글자보다 앞에 쌓아야** 글자가 그 위에 온다.
        // 칸마다 quad 를 내지 않고 같은 색이 이어지는 구간을 묶는다(Run).
        var bg_run: Run = .{};
        var under_run: Run = .{};
        var under2_run: Run = .{};
        var strike_run: Run = .{};
        var over_run: Run = .{};
        var col: u16 = 0;
        while (col < grid_cols) : (col += 1) {
            const p = paintCell(snap.cells[core.index(row, col)].style, tk);
            bg_run.note(col, p.bg, ox, y0, cell_w, line_h);
            under_run.note(col, if (p.underline) p.line else null, ox, y0 + y_under, cell_w, rule);
            under2_run.note(col, if (p.underline_double) p.line else null, ox, y0 + y_under2, cell_w, rule);
            strike_run.note(col, if (p.strikethrough) p.line else null, ox, y0 + y_strike, cell_w, rule);
            over_run.note(col, if (p.overline) p.line else null, ox, y0 + y_over, cell_w, rule);
        }
        bg_run.flush(grid_cols, ox, y0, cell_w, line_h);

        // ── 선택 표시. **배경 위·글자 아래**에 깔아야 글자가 읽힌다(위에 얹으면 가린다).
        // 범위는 코어가 준다 — 어느 칸이 선택됐는지 다시 계산하면 갈린다.
        if (sel) |s| {
            if (row >= s.start.row and row <= s.end.row) {
                const from: u16 = if (row == s.start.row) s.start.col else 0;
                // **끝 열은 포함이다**(데스크톱 렌더가 `col <= end.col` 로 쓴다). 배타로 그리면
                // 선택이 한 칸씩 모자라 보인다 — 화면으로 잡았다.
                const to: u16 = if (row == s.end.row) s.end.col +| 1 else grid_cols;
                if (to > from and from < grid_cols) {
                    const end_col = @min(to, grid_cols);
                    if (reserveQuad()) {
                        const rgb = tk.get(.selection);
                        push(.{
                            .x = ox + @as(i32, from) * cell_w,
                            .y = y0,
                            .w = @intCast(@as(i32, end_col - from) * cell_w),
                            .h = @intCast(line_h),
                        }, rgb, 0x80, 0, 0);
                    }
                }
            }
        }
        under_run.flush(grid_cols, ox, y0 + y_under, cell_w, rule);
        under2_run.flush(grid_cols, ox, y0 + y_under2, cell_w, rule);
        strike_run.flush(grid_cols, ox, y0 + y_strike, cell_w, rule);
        over_run.flush(grid_cols, ox, y0 + y_over, cell_w, rule);

        // ── 2) 글자
        col = 0;
        while (col < grid_cols) : (col += 1) {
            const cell = snap.cells[core.index(row, col)];
            if (cell.continuation) continue; // 2셀 글자의 뒷칸은 앞칸이 이미 그렸다
            if (cell.codepoint == ' ' or cell.codepoint == 0) continue;
            // **클러스터를 열째로 넘긴다.** 코어는 base 를 셀에 두고 나머지를 `grapheme_id` 로
            // 따로 보관한다 — base 만 보면 `❤` 와 `❤️` 가 같아 보여 VS16 결합이 단색이 됐다.
            var seq: [max_cluster]u21 = undefined;
            seq[0] = cell.codepoint;
            var seq_len: usize = 1;
            if (cell.grapheme_id != 0 and cell.grapheme_id <= snap.graphemes.len) {
                for (snap.graphemes[cell.grapheme_id - 1]) |extra| {
                    if (seq_len == max_cluster) break;
                    seq[seq_len] = extra;
                    seq_len += 1;
                }
            }
            const glyph = atlasCell(seq[0..seq_len], styleBits(cell.style)) orelse continue;
            if (!reserveQuad()) return;
            const rgb = paintCell(cell.style, tk).fg;
            // 진행 폭은 코어가 정한 셀 폭을 따른다 — 한글이 2셀이라는 판정이 코어 것이다.
            const x = ox + @as(i32, col) * cell_w;
            // **양폭 글자는 슬롯 전체, 단폭은 왼쪽 절반.** 슬롯 하나가 양폭 상자라서다.
            // 그래야 글자 상자가 칸과 정확히 겹치고, 합성 글리프가 이음매 없이 붙는다.
            const wide = cell.width == 2;
            quad_buf[quad_count] = .{
                .x = @floatFromInt(x),
                .y = @floatFromInt(y0),
                .w = @floatFromInt(if (wide) cell_w * 2 else cell_w),
                .h = @floatFromInt(line_h),
                .r = @as(f32, @floatFromInt(rgb.r)) / 255.0,
                .g = @as(f32, @floatFromInt(rgb.g)) / 255.0,
                .b = @as(f32, @floatFromInt(rgb.b)) / 255.0,
                .a = 1.0,
                .radius = 0,
                // 3 = 슬롯의 왼쪽 절반. 컬러(4·5)는 **다른 텍스처**를 가리킨다 — 아틀라스가
                // 둘이라 kind 로 가르지 않으면 host 가 어느 텍스처를 샘플링할지 알 수 없다.
                .kind = if (glyph.color)
                    (if (wide) @as(u32, 4) else 5)
                else
                    (if (wide) @as(u32, 1) else 3),
                .cell_x = glyph.col,
                .cell_y = glyph.row,
            };
            quad_count += 1;
        }
    }

    // ── 커서 ──────────────────────────────────────────────────────────────────
    // **모양도 표시 여부도 코어가 정한다.** DECTCEM(`CSI ?25 l`)으로 TUI 가 커서를 숨기고,
    // DECSCUSR 로 모양을 바꾼다 — 그 판단을 플랫폼이 다시 하면 어긋난다.
    //
    // 커서가 없으면 화살표·선택이 **눈으로 검증되지 않는다**(로그가 유일한 판정자가 된다).
    // 그래서 이 자리가 이후 슬라이스 전부의 선행 조건이다.
    // **가시성 판단을 다시 하지 않는다.** `screen.cursor.visible` 은 코어가 "내부 불변" 이라
    // 적어 둔 값이라 늘 참이고, 실제 규칙(DECTCEM **그리고** 스크롤백을 보고 있지 않을 것)은
    // snapshot 이 이미 합성해 준다. 손으로 같은 규칙을 또 쓰면 한쪽만 낡는다.
    if (snap.cursor.visible) {
        const cur = snap.cursor;
        if (cur.col < grid_cols and cur.row < grid_rows) {
            // **조합 중이면 커서는 그 뒤에 선다.** preedit 은 아직 확정 안 된 글자지만 화면에서는
            // 이미 커서 앞자리를 차지한다 — 안 옮기면 커서가 **조합 첫 글자를 덮고 앉는다**
            // (기기 실측: `mux` 를 치는 동안 블록이 `m` 위에 그대로 있었다).
            const pre_cols = preeditCols();
            const cur_col = cursorColOnScreen(cur.col, grid_cols);
            const cx = ox + @as(i32, cur_col) * cell_w;
            // 격자와 **같은 식**으로 y 를 낸다 — 따로 계산하면 한 줄씩 어긋난다.
            const cy = oy + @as(i32, cur.row) * line_h;
            const rgb = tk.get(.cursor);
            const shape = snap.cursor_shape;
            // **2셀 글자 위에서는 두 칸을 덮는다.** 한 칸만 덮으면 한글 절반에만 걸려
            // "커서가 글자 가운데 있는" 모양이 된다(글자 폭은 코어가 정한 값을 쓴다).
            // continuation 칸(width 0)에 놓이면 한 칸이다 — 코어가 거기 커서를 두지 않는다.
            //
            // **조합 중에는 그 칸의 셀을 안 본다.** 커서는 조합 **뒤**의 빈 자리에 서 있고,
            // 거기 남아 있는 옛 셀의 폭은 지금 커서와 아무 상관이 없다.
            const cur_w = if (pre_cols != 0)
                cell_w
            else if (snap.cells[core.index(cur.row, cur.col)].width == 2)
                cell_w * 2
            else
                cell_w;
            // 블록은 칸을 채우고, 밑줄은 아래 굵은 선, 막대는 왼쪽 세로선이다.
            const r: draw.Rect = switch (shape) {
                .block => .{ .x = cx, .y = cy, .w = @intCast(cur_w), .h = @intCast(line_h) },
                .underline => .{
                    .x = cx,
                    .y = cy + line_h - 2 * rule,
                    .w = @intCast(cur_w),
                    .h = @intCast(2 * rule),
                },
                .bar => .{ .x = cx, .y = cy, .w = @intCast(2 * rule), .h = @intCast(line_h) },
            };
            // **글자 위에 얹되 가리지 않는다.** 블록을 불투명하게 칠하면 그 칸 글자가 사라진다 —
            // 반전은 셀 속성(reverse)이 하는 일이고, 여기서는 반투명으로 겹친다.
            push(r, rgb, if (shape == .block) 0x80 else 0xFF, 0, 0);
        }
    }

    // 조합 중 문자열을 커서 자리에 **흐리게** 얹는다. **격자를 다 그린 뒤**라야 그 위에
    // 올라간다 — 앞에 두면 커서 자리에 글자가 있을 때 그 글자가 조합을 덮는다(주석은 "위에
    // 그려진다" 라고 적혀 있었는데 순서는 반대였다).
    if (preedit_len > 0 and snap.cursor.row < grid_rows) {
        // **격자 칸에 그린다 — chrome 텍스트로 그리지 않는다.** 예전에는 `pushText` 를 썼는데
        // 그것은 사이드바·설정 라벨용이라 **자기 스케일로 펜을 진행**한다(`atlas_cell_w * scale`).
        // 셀 글자는 `cell_w`·`line_h` 상자에 맞춰 그리므로, 같은 줄인데 조합만 **위로 뜨고 글자
        // 간격도 어긋났다**(기기 실측: 확정된 `qd` 옆에 조합 `qd가나어더우` 가 딴 줄처럼 보였다).
        // M4a3 이 격자를 글리프 quad 로 옮길 때 이 자리는 안 따라온 것이다.
        const cur = snap.cursor;
        const rgb = tk.get(.muted_fg);
        const py = oy + @as(i32, cur.row) * line_h;
        var col: u16 = cur.col;
        var view = std.unicode.Utf8View.init(preedit_buf[0..preedit_len]) catch {
            setLastError("preedit_bad_utf8");
            return;
        };
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| {
            const w: u16 = maru.width.cellWidth(cp);
            // 줄 끝을 넘으면 거기서 멈춘다. **접어 넘기지 않는다** — 조합은 아직 코어에 안 들어간
            // 겉치레라, 다음 줄에 그리면 그 줄의 진짜 내용을 덮는다.
            if (col +| w > grid_cols) break;
            // 미스면 `noteMiss` 가 굽기 목록에 올려 다음 프레임에 나온다(셀 경로와 같다).
            if (atlasCell(&[_]u21{cp}, 0)) |glyph| {
                if (!reserveQuad()) return;
                const wide = w == 2;
                quad_buf[quad_count] = .{
                    .x = @floatFromInt(ox + @as(i32, col) * cell_w),
                    .y = @floatFromInt(py),
                    .w = @floatFromInt(if (wide) cell_w * 2 else cell_w),
                    .h = @floatFromInt(line_h),
                    .r = @as(f32, @floatFromInt(rgb.r)) / 255.0,
                    .g = @as(f32, @floatFromInt(rgb.g)) / 255.0,
                    .b = @as(f32, @floatFromInt(rgb.b)) / 255.0,
                    .a = 1.0,
                    .radius = 0,
                    .kind = if (glyph.color)
                        (if (wide) @as(u32, 4) else 5)
                    else
                        (if (wide) @as(u32, 1) else 3),
                    .cell_x = glyph.col,
                    .cell_y = glyph.row,
                };
                quad_count += 1;
            }
            col +|= w;
        }
    }
}

/// 데스크톱 기본 테마에 가까운 값. **아직 config 를 안 읽는다** — 모바일이 config 를
/// 어디서 받을지가 원격 연결(M3)과 함께 정해진다.
/// 두 색을 섞는다(`t` 는 0~255 — b 쪽 비중).
fn mix(a: anytype, b: @TypeOf(a), t: u16) @TypeOf(a) {
    return .{
        .r = @intCast((@as(u16, a.r) * (255 - t) + @as(u16, b.r) * t) / 255),
        .g = @intCast((@as(u16, a.g) * (255 - t) + @as(u16, b.g) * t) / 255),
        .b = @intCast((@as(u16, a.b) * (255 - t) + @as(u16, b.b) * t) / 255),
    };
}

fn themeColors() tokens.ThemeColors {
    const t = activeTheme();
    const bg = hex(t.background, .{ .r = 0x1E, .g = 0x1E, .b = 0x2E });
    const fg = hex(t.foreground, .{ .r = 0xE6, .g = 0xE6, .b = 0xEA });
    return .{
        .foreground = fg,
        // **chrome 색도 사용자 테마에서 나온다**(사용자 요청). 예전에는 여기 값이 박혀 있어
        // 배경을 흰색으로 바꿔도 설정·목록 화면만 어두운 채로 남았다 — 같은 앱이 화면마다
        // 다른 테마를 쓰는 셈이었다. 본문 배경에서 **글자색 쪽으로 조금 섞어** 만든다:
        // 그래야 어떤 테마에서도 chrome 이 본문과 구별되면서 같은 계열로 보인다.
        .sidebar_background = mix(bg, fg, 18),
        .sidebar_foreground = mix(fg, bg, 24),
        .sidebar_active = mix(bg, fg, 46),
        .search_match = .{ .r = 0x4A, .g = 0x4A, .b = 0x20 },
        .search_match_current = .{ .r = 0x8A, .g = 0x7A, .b = 0x20 },
        .selection = hex(t.selection, .{ .r = 0x30, .g = 0x40, .b = 0x60 }),
        // **터미널 본문 배경은 사이드바와 별개 입력이다**(tokens.zig §4.1b). `theme.background`
        // 가 그 자리다 — 사이드바는 chrome 색이라 따로 둔다.
        .terminal_background = bg,
        // 비교 본문 색. 모바일은 아직 diff 를 안 그리지만(§2.4 — 도크·편집기 미이식) 토큰이
        // 필수 입력이라 데스크톱 파생 규칙에 가까운 값을 준다.
        .diff_added = .{ .r = 0x20, .g = 0x40, .b = 0x28 },
        .diff_removed = .{ .r = 0x48, .g = 0x24, .b = 0x28 },
        .cursor = hex(t.cursor, .{ .r = 0xE6, .g = 0xE6, .b = 0xEA }),
        .accent = .{ .r = 0xDD, .g = 0xA1, .b = 0x5E }, // maru 앰버
    };
}

/// quad 자리를 하나 잡는다. **넘치면 알린다** — 조용히 자르면 화면 일부가 사라진 채
/// 아무 신호도 없다(본문만 알리고 chrome·아이콘은 조용하던 것을 한곳으로 모았다).
fn reserveQuad() bool {
    if (quad_count < quad_buf.len) return true;
    const next = if (quad_buf.len == 0) chrome_quad_slack * 2 else quad_buf.len * 2;
    const grown = term_allocator.alloc(MaruQuad, next) catch {
        setLastError("quad_alloc");
        return false;
    };
    @memcpy(grown[0..quad_count], quad_buf[0..quad_count]);
    if (quad_buf.len > 0) term_allocator.free(quad_buf);
    quad_buf = grown;
    return true;
}

fn push(rect: draw.Rect, rgb: anytype, alpha: u8, radius: u16, kind: u32) void {
    if (!reserveQuad()) return;
    quad_buf[quad_count] = .{
        .x = @floatFromInt(rect.x),
        .y = @floatFromInt(rect.y),
        .w = @floatFromInt(rect.w),
        .h = @floatFromInt(rect.h),
        .r = @as(f32, @floatFromInt(rgb.r)) / 255.0,
        .g = @as(f32, @floatFromInt(rgb.g)) / 255.0,
        .b = @as(f32, @floatFromInt(rgb.b)) / 255.0,
        .a = @as(f32, @floatFromInt(alpha)) / 255.0,
        .radius = @floatFromInt(radius),
        .kind = kind,
        .cell_x = 0,
        .cell_y = 0,
    };
    quad_count += 1;
}

/// 아틀라스 인덱스(호스트가 만든 atlas.idx)를 코드포인트→셀로 들고 있는다.
/// 아틀라스 격자. **여기가 용량의 단일 출처다** — 헤더 매크로로 두면 등록부보다 큰 슬롯을
/// 약속하게 되고, 남는 슬롯은 등록이 안 된 채 매 프레임 다시 구워진다(실측 위험).
const atlas_cols_n: u32 = 16;
const atlas_rows_n: u32 = 32;
const atlas_cap: usize = atlas_cols_n * atlas_rows_n;

pub export fn maru_mobile_atlas_cols() u32 {
    return atlas_cols_n;
}

pub export fn maru_mobile_atlas_rows() u32 {
    return atlas_rows_n;
}

var atlas_cp: [atlas_cap]u32 = undefined; // base+style — 1차 비교
/// 등록된 글자의 **코드포인트 열**. `❤` 와 `❤️` 는 base 가 같아 여기까지 봐야 갈린다.
var atlas_seq: [atlas_cap][max_cluster]u32 = undefined;
var atlas_len: [atlas_cap]u8 = undefined;
var atlas_col: [atlas_cap]u32 = undefined;
var atlas_row: [atlas_cap]u32 = undefined;
var atlas_adv: [atlas_cap]u32 = undefined;
/// 마지막으로 **그려진** 프레임 순번. 축출이 이것만 본다.
var atlas_used: [atlas_cap]u64 = undefined;
var atlas_n: usize = 0;
/// 프레임 순번. `maru_mobile_build` 가 올린다.
var frame_seq: u64 = 0;

/// 꽉 찬 등록부에서 **버릴 것**을 고른다 — 이번 프레임에 안 쓰인 것 중 가장 오래된 것.
///
/// **이번 프레임에 쓰인 것은 후보에서 뺀다.** 안 그러면 한 화면이 512종을 넘겼을 때 글자들이
/// 서로를 밀어내며 매 프레임 다시 구워진다(깜빡임 + CPU 낭비). 전부 이번 프레임 것이면 `null`
/// 이고, 그건 **버릴 수 있는 것이 없다**는 뜻이라 호출자가 소진을 알린다.
/// `next_slot` 이 고른 자리. `atlas_add` 가 **그 인덱스를 그대로** 쓴다.
///
/// 좌표로 되찾으면 안 된다 — 같은 (열,행)을 가진 항목이 둘이면 첫 번째가 걸려 **엉뚱한 항목을
/// 덮어쓰고**, 고른 자리는 옛 상태로 남아 다음 호출이 또 같은 자리를 고른다. 실측에서 다섯
/// 글자를 구웠는데 하나만 등록됐다.
var pending_victim: ?usize = null;
var pending_color_victim: ?usize = null;

fn oldestVictim(used: []const u64, n: usize) ?usize {
    var victim: ?usize = null;
    for (0..n) |i| {
        if (used[i] == frame_seq) continue;
        if (victim) |v| {
            if (used[i] < used[v]) victim = i;
        } else victim = i;
    }
    return victim;
}
/// 아틀라스 셀 크기(px). 종횡비를 지켜 그려야 글자가 안 늘어난다.
var atlas_cell_w: u32 = 24;
var atlas_cell_h: u32 = 32;

/// 지금 글자를 **구울** 크기(px). host 가 굽기 직전에 묻는다 — 전에는 헤더 매크로가 그 값을
/// 박아 두어 `font.size` 를 바꿔도 22px 로 구운 그림을 확대해 쓰느라 **흐려졌다**.
///
/// **셀에 안 넘치게 자른다.** 아틀라스 슬롯은 고정 기하(`MARU_ATLAS_CELL_W/H`)라 그보다 큰
/// 글자를 구우면 이웃 슬롯을 침범한다 — 어센더·디센더 여유로 셀 높이의 0.7 을 상한으로 둔다
/// (지금 값 22/32 가 그 비율이다).
pub export fn maru_mobile_atlas_text_px() u32 {
    // **셀에 맞춰 굽는다 — 설정 글자 크기를 따라가지 않는다.**
    //
    // 예전에는 `min(font.size, cell_h*0.7)` 이라 **설정값이 굽는 크기이자 축소 계수**였다.
    // 화면 글자는 `굽는 크기 x (line_h / cell_h)` 이므로 그 둘이 곱해져, `font.size = 19` 면
    // 화면에는 `19 x 19/32 = 11.3px` 로 나왔다 — **설정값의 60%**다. 게다가 곱이라 크기를
    // 올리면 글자가 제곱에 가깝게 커졌다(16→19 는 19% 인데 글자는 41% 커진다).
    //
    // 굽는 크기를 셀에 못박으면 화면 글자가 `line_h` 에 **정비례**한다. 셀 세로의 41% 였던
    // 여백도 줄어 같은 줄 높이에서 글자가 커진다 — **줄 수는 그대로다.**
    //
    // **7/10 인 이유**: baseline 은 host 가 셀 하단에서 8px 위에 둔다(`CH - 8`). 한글은 ascent
    // 가 em 에 가까워 그보다 크게 구우면 **위가 깎인다** — 26(13/16)으로 올렸다가 기기에서
    // 잘리는 것을 봤다. 예전 캡(`cell_h * 0.7`)이 바로 그 한계선이었고, 바뀐 것은 **그 값을
    // 설정에서 떼어 고정한 것**이다: 예전에는 `min(font.size, 22)` 라 설정이 작으면 굽는 크기도
    // 같이 작아져 화면 글자가 두 번 줄었다.
    //
    // 굽는 쪽과 이 값이 갈리면 글자가 상자를 넘는다 — 바꿀 때는 host 의 baseline 과 같이 본다.
    return @max(1, atlas_cell_h * 7 / 10);
}

/// 굽는 크기가 바뀌면 **등록부를 비운다** — 그래야 다음 프레임부터 놓친 글자로 올라와 새 크기로
/// 다시 구워진다. 슬롯 자체는 host 가 덮어쓰므로 여기서 지우는 것은 "어느 글자가 어디 있나" 뿐이다.
///
/// **이제 폰트 설정으로는 안 돈다.** 굽는 크기가 셀에서만 파생되므로(`atlas_text_px`), 여기가
/// 걸리는 것은 host 가 셀 기하를 다르게 넘길 때뿐이다 — 두 플랫폼의 아틀라스가 다를 수 있어
/// 경로 자체는 남긴다. 이름이 "text size" 였을 때는 설정을 따라간다는 잘못된 신호였다.
var atlas_baked_px: u32 = 0;
fn resetAtlasIfBakeSizeChanged() void {
    const px = maru_mobile_atlas_text_px();
    if (px == atlas_baked_px) return;
    atlas_baked_px = px;
    atlas_n = 0;
}

pub export fn maru_mobile_atlas_geometry(cell_w: u32, cell_h: u32) void {
    atlas_cell_w = cell_w;
    atlas_cell_h = cell_h;
}

/// 굵게(1)·기울임(2) 비트. **Android `Typeface` 상수와 같은 값**이라 host 가 그대로 넘긴다
/// (0=NORMAL·1=BOLD·2=ITALIC·3=BOLD_ITALIC). iOS 는 이 비트로 번들 폰트 파일을 고른다.
pub const style_bold: u32 = 1;
pub const style_italic: u32 = 2;

/// 등록부 키. 코드포인트는 21비트라 위쪽이 비어 있어 스타일을 같이 싣는다 — 같은 글자의
/// 굵은 판과 보통 판은 **다른 글리프**라 슬롯도 달라야 한다.
fn atlasKey(cp: u32, style: u32) u32 {
    return (cp & 0xFFFFFF) | (style << 24);
}

/// 구운 글자를 등록한다. **열을 통째로 받는다** — 단일 코드포인트면 `n=1` 이다.
/// `cps` 는 `maru_mobile_missing_cp_at` 로 읽은 그 열이어야 한다(다른 열을 넘기면 host 가 구운
/// 그림과 등록부가 어긋나 엉뚱한 글리프가 그려진다).
pub export fn maru_mobile_atlas_add(cps: [*]const u32, n: u32, style: u32, col: u32, row: u32, advance: u32) void {
    if (n == 0) return;
    const seq = cps[0..@min(n, max_cluster)];
    const key = atlasKey(seq[0], style);
    // 등록되면 "없음" 목록에서 뺀다. 안 그러면 아틀라스가 서기 **전에** 한 번 돈 build 가
    // 남긴 목록 때문에 이미 있는 글자를 슬롯만 축내며 다시 굽는다(실측: grew=15 가 전부
    // 'z' 같은 ASCII 중복이었다).
    var i: usize = 0;
    while (i < miss_n) : (i += 1) {
        if (miss_cp[i] == key and seqEqlU32(miss_seq[i][0..miss_len[i]], seq)) {
            miss_cp[i] = miss_cp[miss_n - 1];
            miss_seq[i] = miss_seq[miss_n - 1];
            miss_len[i] = miss_len[miss_n - 1];
            miss_n -= 1;
            break;
        }
    }
    // 이미 있으면 슬롯을 안 쓴다. **열까지 봐야 한다** — base 만 보면 `❤️` 가 `❤` 자리를 쓴다.
    for (0..atlas_n) |j| if (atlas_cp[j] == key and seqEqlU32(atlas_seq[j][0..atlas_len[j]], seq)) return;
    if (atlas_n == atlas_cp.len) {
        // **꽉 찼으면 덮어쓴다.** `maru_mobile_next_slot` 이 고른 자리가 곧 버릴 자리다.
        const v = pending_victim orelse return;
        // host 가 다른 자리에 구웠으면 안 받는다 — 없는 슬롯을 가리키는 등록은 화면에 쓰레기를
        // 그린다. 좌표는 **검증용**이고, 자리는 위 인덱스가 정한다.
        if (atlas_col[v] != col or atlas_row[v] != row) return;
        atlas_cp[v] = key;
        storeSeq(&atlas_seq[v], &atlas_len[v], seq);
        atlas_adv[v] = advance;
        atlas_used[v] = frame_seq;
        pending_victim = null;
        return;
    }
    atlas_cp[atlas_n] = key;
    storeSeq(&atlas_seq[atlas_n], &atlas_len[atlas_n], seq);
    atlas_col[atlas_n] = col;
    atlas_row[atlas_n] = row;
    atlas_adv[atlas_n] = advance;
    atlas_used[atlas_n] = frame_seq;
    atlas_n += 1;
}

fn storeSeq(dst: *[max_cluster]u32, len: *u8, seq: []const u32) void {
    for (seq, 0..) |cp, j| dst[j] = cp;
    len.* = @intCast(seq.len);
}

fn seqEqlU32(a: []const u32, b: []const u32) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

// **아틀라스는 자란다.** 처음 보는 글자는 그릴 글리프가 없어 조용히 안 그려진다 — 고정
// 집합으로 두면 입력·원격 출력의 새 글자가 전부 사라진다(실측으로 드러났다: 키를 넣었더니
// 코어엔 들어왔는데 화면이 그대로였다).
// 여기서는 **놓친 코드포인트를 모아** 플랫폼이 그것만 구워 넣게 한다. 슬롯 추가는
// 아틀라스 부분 업데이트(여섯 기능 4번)를 그대로 쓴다.
/// 한 글자가 실을 수 있는 코드포인트 수. 가족 이모지(👨‍👩‍👧‍👦)가 7, 스킨톤이 붙으면 더 길어진다.
/// 넘치는 꼬리는 버린다 — 자르면 host 가 다른 글자를 굽지만, 무한정 이고 갈 수는 없다.
pub const max_cluster: usize = 12;

var miss_cp: [64]u32 = undefined; // base+style — 1차 비교용(대부분 여기서 갈린다)
var miss_seq: [64][max_cluster]u32 = undefined;
var miss_len: [64]u8 = undefined;
var miss_n: usize = 0;

/// 못 그린 것은 **(코드포인트 열, 스타일)** 로 모은다. 열인 이유: 코어는 base 를 셀에 두고
/// 나머지를 `grapheme_id` 로 따로 보관하는데, base 만 넘기면 host 에게 `❤`(U+2764)와
/// `❤️`(U+2764 U+FE0F)가 **같아 보인다** — 그래서 VS16 결합이 단색으로 나왔다.
/// 스타일도 함께 싣는다 — 같은 글자라도 굵은 판은 따로 구워야 한다.
fn noteMiss(seq: []const u21, style: u32) void {
    const key = atlasKey(seq[0], style);
    for (0..miss_n) |i| if (miss_cp[i] == key and seqEql(miss_seq[i][0..miss_len[i]], seq)) return;
    // **넘쳐도 잃지 않는다 — 그래서 여기는 오류가 아니다.** 목록은 프레임마다 다시 채워지고
    // (host 가 구운 뒤 `missing_clear`), 안 구워진 글자는 등록부에 없으니 **다음 프레임에 다시
    // 올라온다**. 한 프레임(~33ms) 늦을 뿐이라 사용자에게는 안 보인다. 여기서 `last_error` 를
    // 세우면 글자 많은 화면에서 매 프레임 덮여 **진짜 오류를 가린다**(실제로 그렇게 됐다).
    if (miss_n == miss_cp.len) return;
    miss_cp[miss_n] = key;
    const n = @min(seq.len, max_cluster);
    for (0..n) |j| miss_seq[miss_n][j] = seq[j];
    miss_len[miss_n] = @intCast(n);
    miss_n += 1;
}

/// 열이 같은가. base 는 이미 `atlasKey` 로 걸러졌지만 꼬리까지 봐야 `❤` 와 `❤️` 가 갈린다.
fn seqEql(a: []const u32, b: []const u21) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

/// 플랫폼이 부른다: 아직 아틀라스에 없는 **글자** 개수(코드포인트 개수가 아니다).
pub export fn maru_mobile_missing_count() u32 {
    return @intCast(miss_n);
}

/// i번째 놓친 글자의 코드포인트 **개수**. 1이면 단일 코드포인트, 2 이상이면 클러스터다.
pub export fn maru_mobile_missing_len(i: u32) u32 {
    if (i >= miss_n) return 0;
    return miss_len[i];
}

/// i번째 놓친 글자의 j번째 코드포인트. host 는 `0..missing_len(i)` 를 이어 붙여 **문자열 하나로**
/// 구워야 한다 — 코드포인트를 따로 구우면 결합이 안 일어난다.
pub export fn maru_mobile_missing_cp_at(i: u32, j: u32) u32 {
    if (i >= miss_n or j >= miss_len[i]) return 0;
    return miss_seq[i][j];
}

/// i번째 놓친 것의 **스타일**(1=굵게·2=기울임, Android `Typeface` 상수와 같은 값).
/// 코드포인트와 함께 읽어야 host 가 어느 폰트로 구울지 안다.
pub export fn maru_mobile_missing_style(i: u32) u32 {
    if (i >= miss_n) return 0;
    return miss_cp[i] >> 24;
}

/// 다음 빈 슬롯의 (열, 행) — 상위 16비트=열, 하위 16비트=행.
/// 다음 빈 슬롯. **꽉 차면 0xFFFFFFFF 를 돌려준다** — 예전에는 같은 자리를 계속 돌려줘,
/// 등록되지 못한 글자가 매 프레임 다시 구워지며 CPU·GPU 만 먹었다.
pub export fn maru_mobile_next_slot(cols: u32) u32 {
    if (atlas_n < atlas_cap) {
        const idx: u32 = @intCast(atlas_n);
        return ((idx % cols) << 16) | (idx / cols);
    }
    // **차면 가장 안 쓰인 자리를 내준다.** 예전에는 여기서 끝이라, 아틀라스가 찬 뒤 나온 글자가
    // 미스로는 올라오는데 구울 자리가 없어 **영영 안 그려졌다**(오류도 로그도 없이). 실제 셸은
    // 512칸을 금방 채운다 — 굵게/기울임이 각각 별도 슬롯이라 더 빠르다.
    // 버릴 자리도 없으면(등록부가 전부 이번 프레임 것) 이번 프레임은 포기다 — **그 포기를
    // 남긴다.** 안 남기면 그 글자는 오류도 로그도 없이 빈칸으로 남는다.
    const v = oldestVictim(&atlas_used, atlas_n) orelse {
        setLastError("atlas_full");
        return 0xFFFFFFFF;
    };
    pending_victim = v;
    return (atlas_col[v] << 16) | atlas_row[v];
}

// ── 컬러 글리프(이모지) ────────────────────────────────────────────────────────
// **글자 아틀라스는 커버리지(R8)라 컬러를 못 담는다.** 컬러 비트맵을 거기 넣으면 실루엣이
// 된다. 그래서 컬러 전용 아틀라스를 따로 세운다 — 아이콘 아틀라스가 이미 RGBA8 로 서 있어
// 같은 모양이 하나 더 서는 것뿐이고, 텍스트 아틀라스의 **커버리지 계약(§4)은 안 흔든다**.
//
// **컬러인지는 코어가 정한다.** `width.isEmojiPresentation` 이 단일 출처라, 여기서 규칙을
// 다시 쓰면 컬러 판정이 갈린다(데스크톱 렌더러도 같은 함수를 본다).
/// 컬러로 구울 글자인가. **열을 본다** — `❤`(U+2764)는 텍스트 표현이지만 `❤️`(+VS16)는 컬러다.
/// base 만 보면 둘이 같아 보여 VS16 결합이 단색으로 나왔다(화면으로 확인한 결함).
///
/// base 판정의 단일 출처는 코어(`width.isEmojiPresentation`)다. VS16 은 그 위에 얹는 **표현
/// 선택자**라 열에서만 보이고, 코어의 셀 모델에는 `grapheme_id` 뒤에 숨어 있다.
fn isColorGlyph(seq: []const u21) bool {
    if (seq.len == 0 or seq[0] > 0x10FFFF) return false;
    // VS16(U+FE0F)이 붙으면 그 글자는 이모지 표현으로 그린다 — VS15(U+FE0E)는 반대(텍스트).
    for (seq[1..]) |cp| {
        if (cp == 0xFE0F) return true;
        if (cp == 0xFE0E) return false;
    }
    return maru.width.isEmojiPresentation(seq[0]);
}

var color_cp: [atlas_cap]u32 = undefined;
/// 글자 아틀라스의 `atlas_seq` 와 짝 — `❤` 와 `❤️` 를 가르는 열.
var color_seq: [atlas_cap][max_cluster]u32 = undefined;
var color_len: [atlas_cap]u8 = undefined;
var color_col: [atlas_cap]u32 = undefined;
var color_row: [atlas_cap]u32 = undefined;
var color_adv: [atlas_cap]u32 = undefined;
/// 글자 아틀라스의 `atlas_used` 와 짝 — 축출 판정용 마지막 사용 프레임.
var color_used: [atlas_cap]u64 = undefined;
var color_n: usize = 0;

/// i번째 놓친 것이 **컬러 글리프인가**. host 는 이 값으로 어느 아틀라스에 구울지 고른다 —
/// 커버리지 아틀라스에 컬러를 구우면 실루엣이 되고, 그 반대는 색이 사라진다.
pub export fn maru_mobile_missing_is_color(i: u32) u32 {
    if (i >= miss_n) return 0;
    var seq: [max_cluster]u21 = undefined;
    const n = miss_len[i];
    for (0..n) |j| seq[j] = @intCast(miss_seq[i][j] & 0x1FFFFF);
    return if (isColorGlyph(seq[0..n])) 1 else 0;
}

/// 컬러 아틀라스에 구운 글리프를 등록한다(글자 아틀라스의 `maru_mobile_atlas_add` 와 짝, 같은
/// 열 규약).
pub export fn maru_mobile_color_atlas_add(cps: [*]const u32, n: u32, style: u32, col: u32, row: u32, advance: u32) void {
    if (n == 0) return;
    const seq = cps[0..@min(n, max_cluster)];
    const key = atlasKey(seq[0], style);
    var i: usize = 0;
    while (i < miss_n) : (i += 1) {
        if (miss_cp[i] == key and seqEqlU32(miss_seq[i][0..miss_len[i]], seq)) {
            miss_cp[i] = miss_cp[miss_n - 1];
            miss_seq[i] = miss_seq[miss_n - 1];
            miss_len[i] = miss_len[miss_n - 1];
            miss_n -= 1;
            break;
        }
    }
    for (0..color_n) |j| if (color_cp[j] == key and seqEqlU32(color_seq[j][0..color_len[j]], seq)) return;
    if (color_n == color_cp.len) {
        // 글자 아틀라스와 같은 규칙 — 꽉 차면 `next_color_slot` 이 고른 자리를 덮어쓴다.
        const v = pending_color_victim orelse return;
        if (color_col[v] != col or color_row[v] != row) return;
        color_cp[v] = key;
        storeSeq(&color_seq[v], &color_len[v], seq);
        color_adv[v] = advance;
        color_used[v] = frame_seq;
        pending_color_victim = null;
        return;
    }
    color_cp[color_n] = key;
    storeSeq(&color_seq[color_n], &color_len[color_n], seq);
    color_col[color_n] = col;
    color_row[color_n] = row;
    color_adv[color_n] = advance;
    color_used[color_n] = frame_seq;
    color_n += 1;
}

/// 컬러 아틀라스의 다음 빈 슬롯(글자 쪽과 같은 인코딩·같은 소진 규약).
pub export fn maru_mobile_next_color_slot(cols: u32) u32 {
    if (color_n < atlas_cap) {
        const idx: u32 = @intCast(color_n);
        return ((idx % cols) << 16) | (idx / cols);
    }
    const v = oldestVictim(&color_used, color_n) orelse {
        setLastError("color_atlas_full");
        return 0xFFFFFFFF;
    };
    pending_color_victim = v;
    return (color_col[v] << 16) | color_row[v];
}

/// 등록된 컬러 글리프 수(테스트·진단용 — 등록이 실제로 됐는지 값으로 본다).
pub export fn maru_mobile_color_atlas_count() u32 {
    return @intCast(color_n);
}

/// 등록된 글자 글리프 수. **축출이 들어온 뒤로는 `next_slot` 만으로 "찼다"를 못 본다** —
/// 꽉 차도 재사용 슬롯을 돌려주기 때문이다. 용량(`cols*rows`)과 비교해 판정한다.
pub export fn maru_mobile_atlas_count() u32 {
    return @intCast(atlas_n);
}

/// 합성 글리프를 슬롯에 채운다. 플랫폼은 **폰트 경로보다 먼저** 이걸 부른다 —
/// `renderer.synthesizeGlyph` 의 계약이 그렇다("rasterizer 는 폰트 경로 전에 한 번 호출한다").
/// 반환값은 잉크 픽셀 수이고, **0 이면 합성 대상이 아니라서** 플랫폼이 폰트로 굽는다.
///
/// 박스 드로잉(U+2500~257F)·블록(U+2580~259F)·브라유(U+2800~28FF)·파워라인·legacy mosaic 은
/// 폰트 글리프로 그리면 셀에 안 맞아 **끊기고 이음매가 보인다**(그 상태를 화면으로 확인했다).
/// 합성은 셀을 가장자리까지 채워 이어진다.
///
/// **슬롯의 왼쪽 절반에 채운다.** 합성 대상은 전부 단폭이고, 그리는 쪽도 단폭 글자는 슬롯
/// 절반만 샘플링한다(§4 글리프 기하). 슬롯 전체에 채우면 두 배로 넓게 나온다.
/// 합성 결과를 받는 RGBA 스크래치. **coverage 계약이 RGBA 다** — `glyph_pixels.slotFits` 가
/// `bytes_per_row >= w*4` 를 요구하고 커버리지는 **alpha 채널**로 온다. 단일 채널 버퍼를
/// 그대로 주면 조용히 null 이다. 아이콘에서 `filled=0/6` 으로 한 번 헤맨 그 함정이고, 여기서
/// 또 걸렸다(`isSynthesizedCodepoint` 는 true 인데 잉크가 0 이었다).
var synth_rgba: [24 * 32 * 4]u8 = undefined;

pub export fn maru_mobile_synthesize(cp: u32, out: [*]u8, stride: u32) u32 {
    const w = atlas_cell_w / 2;
    const h = atlas_cell_h;
    const rgba_stride = w * 4;
    if (@as(usize, rgba_stride) * h > synth_rgba.len) {
        setLastError("synth_slot_too_small");
        return 0;
    }
    const buf = synth_rgba[0 .. @as(usize, rgba_stride) * h];
    @memset(buf, 0);
    const n = maru.renderer.synthesizeGlyph(cp, w, h, rgba_stride, buf) orelse return 0;

    // 아틀라스 텍스처는 단일 채널(coverage)이라 alpha 만 옮긴다.
    @memset(out[0 .. stride * h], 0);
    for (0..h) |y| {
        for (0..w) |x| out[y * stride + x] = buf[y * rgba_stride + x * 4 + 3];
    }
    return n;
}

/// 플랫폼이 다 구운 뒤 부른다. 목록을 비워 다음 프레임에 다시 쌓이게 한다.
pub export fn maru_mobile_missing_clear() void {
    miss_n = 0;
}

/// **눈에 보이는 것이 없는 format 문자**(Cf). 코어는 grapheme cluster mode(DECSET 2027) 합의가
/// 없으면 이것들을 제 셀에 담는다 — 그건 코어의 계약이고 여기서 바꾸지 않는다. 다만 **굽는 것은
/// 다른 문제**다: host 에게 미스로 올리면 CoreText·Canvas 가 빈 글리프를 굽고 그것이 아틀라스
/// 슬롯(512칸)을 영구히 차지한다. 실측에서 `👨‍👩‍👧` 한 줄이 U+200D 를 미스로 두 번 올렸다.
///
/// 안 굽고 **미스에도 안 올린다**. 미스에 올린 채 안 구우면 매 프레임 다시 올라와 목록이 찬다.
fn isZeroWidthFormat(cp: u21) bool {
    return switch (cp) {
        0x200B...0x200F, // ZWSP·ZWNJ·ZWJ·LRM·RLM
        0x2028...0x202E, // 줄/문단 분리자·양방향 제어
        0x2060...0x2064, // word joiner·invisible operators
        0xFEFF, // ZWNBSP(BOM)
        => true,
        else => false,
    };
}

fn atlasCell(seq: []const u21, style: u32) ?struct { col: u32, row: u32, adv: u32, color: bool = false } {
    if (seq.len == 0 or isZeroWidthFormat(seq[0])) return null;
    const key = atlasKey(seq[0], style);
    // **컬러 글자는 컬러 등록부에서 찾는다.** 두 아틀라스가 슬롯 번호를 각자 세므로, 글자
    // 아틀라스에서 찾으면 엉뚱한 슬롯을 가리킨다.
    if (isColorGlyph(seq)) {
        for (0..color_n) |i| if (color_cp[i] == key and seqEql(color_seq[i][0..color_len[i]], seq)) {
            color_used[i] = frame_seq; // 축출의 유일한 근거 — 여기가 빠지면 쓰는 글자를 버린다
            return .{ .col = color_col[i], .row = color_row[i], .adv = color_adv[i], .color = true };
        };
        // **컬러 아틀라스가 없으면 커버리지에 구워 둔 것이라도 쓴다.** 컬러를 모르는 host 는
        // 이모지를 커버리지에 굽고 `atlas_add` 로 등록하는데, 여기서 컬러 등록부만 보면 영영
        // 못 찾아 **매 프레임 다시 굽는다**(실측: 3프레임 내내 미스 목록에 남았다). 이 저장소가
        // 아틀라스가 꽉 찼을 때 이미 한 번 겪은 실패 모드다.
        for (0..atlas_n) |i| if (atlas_cp[i] == key and seqEql(atlas_seq[i][0..atlas_len[i]], seq)) {
            atlas_used[i] = frame_seq;
            return .{ .col = atlas_col[i], .row = atlas_row[i], .adv = atlas_adv[i] };
        };
        noteMiss(seq, style);
        return null;
    }
    for (0..atlas_n) |i| if (atlas_cp[i] == key and seqEql(atlas_seq[i][0..atlas_len[i]], seq)) {
        atlas_used[i] = frame_seq; // 축출의 유일한 근거 — 여기가 빠지면 쓰는 글자를 버린다
        return .{ .col = atlas_col[i], .row = atlas_row[i], .adv = atlas_adv[i] };
    };
    noteMiss(seq, style);
    return null;
}

/// 셀의 SGR 굵기·기울임을 아틀라스 스타일 비트로. **여기가 단일 출처다** — 글자를 그리는
/// 자리와 굽는 자리가 같은 값을 봐야 굵은 글자가 보통 슬롯을 덮어쓰지 않는다.
fn styleBits(s: terminal.types.Style) u32 {
    return (if (s.bold) style_bold else 0) | (if (s.italic) style_italic else 0);
}

/// 문자열을 글자 quad 로 분해한다. **폭은 maru 의 EAW 규칙을 따른다** — 한글은 2셀이다.
/// `pushText` 가 그릴 폭. **가운데 정렬은 이 값으로 해야 한다** — 글자 수 × 근사치로 재면
/// 화살표(`↑`)처럼 advance 가 다른 글자에서 눈에 띄게 왼쪽으로 쏠린다(화면으로 확인).
/// 진행 규칙(0폭 건너뛰기·폰트 advance·폴백)을 `pushText` 와 **그대로 공유**한다.
/// 최대 폭 안에서 **줄을 접어 가며** 그린다. 돌려주는 것은 **그린 줄 수**다 — 부르는 쪽이 그
/// 값으로 배경과 다음 요소의 자리를 잡아야 한다.
///
/// **왜 필요한가.** `pushText` 는 폭을 안 보고 펜을 끝까지 민다 — 긴 문구는 화면 밖으로 나가
/// **그냥 잘린다**(줄임표도 없다). 영어 안내문이 그 선을 넘었고(최장 74칸, 목록 창은 62칸),
/// 기존 문구도 이미 넘고 있었다. 잘려서 못 읽는 것보다 두 줄이 낫다.
///
/// **끊는 자리는 공백이 먼저다.** 단어 가운데를 자르면 읽기가 크게 나빠진다. 다만 한글에는
/// 단어 사이 공백이 드물어 그것만 고집하면 한 줄도 못 접는다 — 그때는 **넘치는 자리에서**
/// 자른다(CJK 조판 관례가 그렇다).
///
/// **한 글자도 못 넣는 폭이면 한 글자는 넣고 넘긴다.** 안 그러면 무한히 줄만 늘어난다.
/// 같은 규칙으로 **줄 수만** 센다(안 그린다). 배경은 글보다 먼저 그려야 하는데 높이는 글이
/// 정하므로, 부르는 쪽이 이것으로 자리를 잡는다. **`pushTextWrapped` 와 같은 자리에서 갈라야**
/// 배경과 글이 어긋나지 않는다 — 두 벌로 두면 한쪽만 고쳐진다.
/// 접힌 줄 수(테스트용). **그리는 자리와 같은 함수를 묻는다** — 따로 세면 그 둘이 갈린다.
pub fn wrappedLineCountForTest(text: []const u8, max_w: i32, font_px: i32) u32 {
    return wrappedLineCount(text, max_w, font_px);
}

fn wrappedLineCount(text: []const u8, max_w: i32, font_px: i32) u32 {
    return wrapLines(text, max_w, font_px, null, 0, 0);
}

fn pushTextWrapped(text: []const u8, x: i32, y: i32, max_w: i32, font_px: i32, col: color.Rgb) u32 {
    return wrapLines(text, max_w, font_px, col, x, y);
}

/// 접기의 **단일 출처**. `col` 이 없으면 세기만 한다 — 그리라는 신호를 따로 받지 않는다.
/// 두 인자로 나누면 "색은 줬는데 안 그린다" 같은 조합이 생기고, 그 조합이 뜻하는 바를 아무도
/// 안 정해 둔다.
///
/// **폭은 누적한다** — 글자마다 `glyphAdvance` 를 한 번씩만 더한다. 처음에는 매 글자마다
/// `textWidth` 로 줄 전체를 다시 재서 글자 수의 제곱이었고, 그 자리에 *"누적하면 폴백 advance 와
/// 양폭 판정을 한 번 더 구현하게 된다"* 고 적어 뒀다 — **틀린 말이었다.** 한 글자 폭을 함수로
/// 빼면 두 곳이 같은 것을 부르므로 갈릴 일이 없다.
///
/// 접은 뒤에는 **되감은 구간만** 다시 잰다(`cut..end`, 마지막 단어 정도라 짧다).
fn wrapLines(text: []const u8, max_w: i32, font_px: i32, col: ?color.Rgb, x: i32, y: i32) u32 {
    if (max_w <= 0) return 0;
    const line_h: i32 = font_px + @divTrunc(font_px, 4); // 줄 사이를 조금 벌린다(글자가 붙어 보인다)
    var view = std.unicode.Utf8View.init(text) catch {
        setLastError("text_bad_utf8");
        return 0;
    };
    var lines: u32 = 0;
    var line_start: usize = 0; // 지금 줄이 시작한 바이트
    var last_space: ?usize = null; // 이 줄에서 마지막으로 본 공백의 **다음** 바이트
    var w: i32 = 0; // 지금 줄에 쌓인 폭
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        const end = it.i; // 이 글자를 **포함한** 끝
        if (cp == ' ') last_space = end;
        w += glyphAdvance(cp, font_px);
        if (w <= max_w) continue;
        // 넘쳤다 — 어디서 끊을지 고른다.
        const cut = blk: {
            if (last_space) |sp| if (sp > line_start) break :blk sp;
            // 공백이 없거나 줄 첫 글자다 — 이 글자 앞에서 끊되, 그러면 빈 줄이 되는 경우
            // (한 글자도 안 들어가는 폭)에는 한 글자를 넣고 넘긴다.
            // **`catch 1` 은 삼키는 것이 아니다.** 여기 오는 `cp` 는 `Utf8View` 가 이미 검증해
            // 내놓은 코드포인트라 실패할 수 없다 — 그래도 1 을 쓰는 것은 **한 바이트 뒤로**
            // 물러나 진행을 보장하려는 것이고, 잘못돼도 줄이 한 칸 일찍 접힐 뿐 멈추지 않는다.
            const cp_len: usize = std.unicode.utf8CodepointSequenceLength(cp) catch 1;
            const before = end - cp_len;
            break :blk if (before > line_start) before else end;
        };
        if (col) |c| pushText(text[line_start..cut], x, y + @as(i32, @intCast(lines)) * line_h, font_px, c);
        lines += 1;
        line_start = cut;
        // 접은 자리의 공백은 다음 줄 앞에 안 남긴다.
        while (line_start < text.len and text[line_start] == ' ') line_start += 1;
        last_space = null;
        // **넘긴 만큼만 다시 잰다.** 접은 자리(`line_start`)부터 지금 글자까지가 다음 줄의
        // 시작이다 — `line_start` 가 `end` 를 넘어서는 경우(이 글자에서 끊었다)는 빈 줄이라 0.
        w = if (line_start < end) textWidth(text[line_start..end], font_px) else 0;
    }
    if (line_start < text.len) {
        if (col) |c| pushText(text[line_start..], x, y + @as(i32, @intCast(lines)) * line_h, font_px, c);
        lines += 1;
    }
    return lines;
}

/// 글자 **하나**가 펜을 미는 거리. `textWidth` 와 `wrapLines` 가 **같은 이것을 부른다** —
/// 한쪽이 자기 셈을 들면 그 둘이 갈리고, 갈리면 배경과 글이 어긋난다(접기가 막으려는 사고다).
///
/// **폴백 폭도 `pushText` 와 같이 폭을 본다.** 여기만 반칸으로 두면 아직 안 구운 한글이 든 값이
/// 절반 폭으로 재져 **우측 정렬이 여백 밖으로 밀린다**(다음 프레임에 글리프가 구워지며 제자리로
/// 돌아와 더 눈에 띈다).
fn glyphAdvance(cp: u21, font_px: i32) i32 {
    // 0폭 format 문자는 펜을 안 민다 — 폴백 advance 를 태우면 보이지 않는 글자가 자간을 벌린다.
    if (isZeroWidthFormat(cp)) return 0;
    const scale = @as(f32, @floatFromInt(font_px)) / @as(f32, @floatFromInt(atlas_cell_h));
    const half_w = @as(f32, @floatFromInt(atlas_cell_w)) * scale * 0.5;
    const draw_w: i32 = @intFromFloat(if (maru.width.cellWidth(cp) == 2) half_w * 2 else half_w);
    return if (atlasCell(&.{cp}, 0)) |c|
        @as(i32, @intFromFloat(@as(f32, @floatFromInt(c.adv)) * scale))
    else
        @divTrunc(draw_w, 2);
}

fn textWidth(text: []const u8, font_px: i32) i32 {
    var w: i32 = 0;
    // **조용히 0 을 답하지 않는다**(§5). 여기서 실패하면 그 글은 폭이 0 이라 자리를 안 차지하고,
    // 바로 아래 `pushText` 도 같은 이유로 아무것도 안 그려 **글이 통째로 사라진 것처럼** 보인다.
    // 평상시에는 안 난다 — 나면 절삭이나 host 인코딩이 깨진 것이라 알아야 한다.
    var view = std.unicode.Utf8View.init(text) catch {
        setLastError("text_bad_utf8");
        return 0;
    };
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| w += glyphAdvance(cp, font_px);
    return w;
}

fn pushText(text: []const u8, x0: i32, y0: i32, font_px: i32, rgb: anytype) void {
    // 셀 종횡비를 지킨다 — 임의 크기 상자에 셀을 넣으면 글자가 늘어난다.
    const scale = @as(f32, @floatFromInt(font_px)) / @as(f32, @floatFromInt(atlas_cell_h));
    // **슬롯 하나는 양폭(한글) 상자고 단폭 글자는 왼쪽 절반만 쓴다**(M4a3, §글리프 기하).
    // 여기가 그 절반 규칙을 안 따라와 슬롯 **전체**를 샘플링하고 있었다.
    //
    // **그런데 양폭 글자는 슬롯 전체가 맞다.** 절반 규칙을 모든 글자에 똑같이 적용하면 한글이
    // **왼쪽 반쪽만** 그려져 자모 조각처럼 보인다(설정 화면에 한글 라벨을 처음 넣고서 화면으로
    // 잡았다 — 그전 chrome 라벨은 `zsh`·`esc` 뿐이라 안 드러났다). 폭 판정은 코어와 같은
    // 자리(`maru.width.cellWidth`)를 쓴다 — 여기서 따로 세면 본문과 chrome 이 갈린다.
    const half_w = @as(f32, @floatFromInt(atlas_cell_w)) * scale * 0.5;
    var pen = x0;
    // 폭 계산과 **같은 이유**로 조용하지 않다(위 `textWidth`).
    var view = std.unicode.Utf8View.init(text) catch {
        setLastError("text_bad_utf8");
        return;
    };
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        // 0폭 format 문자는 **진행도 안 시킨다** — 폴백 advance(`draw_w/2`)를 태우면 보이지 않는
        // 글자가 자간을 벌린다.
        if (isZeroWidthFormat(cp)) continue;
        // chrome 텍스트는 클러스터를 안 만든다 — 코어 격자가 아니라 UTF-8 문자열이라 결합 정보가
        // 없다. 단일 코드포인트 열로 넘긴다.
        const cell = atlasCell(&.{cp}, 0);
        // **양폭이면 슬롯 전체, 단폭이면 왼쪽 절반.** 폭이 그리는 크기와 kind 를 함께 정한다.
        // 본문(`pushTerminal`)이 코어 셀의 wide 로 같은 갈래를 이미 쓴다 — chrome 만 안 따라와
        // 한글·이모지가 반쪽으로 나왔다. **다만 출처가 다르다**: 본문은 코어(=`emoji-width`
        // config 를 반영)가 정하고 여기는 정적 표를 본다. 지금은 브리지가 `emoji_wide` 를 늘
        // 켜 두어 둘이 같지만, config 로 열 때(M10) 이 자리도 코어 판정을 따라야 한다.
        const wide = maru.width.cellWidth(cp) == 2;
        const draw_w: i32 = @intFromFloat(if (wide) half_w * 2 else half_w);
        // 진행 폭은 **폰트 advance** 다. 셀 폭을 쓰면 자간이 벌어진다(실측).
        const adv_px: i32 = if (cell) |c|
            @intFromFloat(@as(f32, @floatFromInt(c.adv)) * scale)
        else
            @divTrunc(draw_w, 2);
        if (cp != ' ') {
            if (cell) |c| {
                if (reserveQuad()) {
                    quad_buf[quad_count] = .{
                        .x = @floatFromInt(pen),
                        .y = @floatFromInt(y0),
                        .w = @floatFromInt(draw_w),
                        .h = @floatFromInt(font_px),
                        .r = @as(f32, @floatFromInt(rgb.r)) / 255.0,
                        .g = @as(f32, @floatFromInt(rgb.g)) / 255.0,
                        .b = @as(f32, @floatFromInt(rgb.b)) / 255.0,
                        .a = 1.0,
                        .radius = 0,
                        // 슬롯의 왼쪽 절반. **컬러면 컬러 텍스처(5)** — 같은 조회를 쓰면서
                        // kind 를 안 따라오면 이모지가 든 탭 제목이 커버리지 텍스처의 같은
                        // 슬롯을 샘플링해 엉뚱한 글자가 나온다(적대적 검증 2라운드).
                        .kind = if (c.color) (if (wide) @as(u32, 4) else 5) else (if (wide) @as(u32, 1) else 3),
                        .cell_x = c.col,
                        .cell_y = c.row,
                    };
                    quad_count += 1;
                }
            }
        }
        pen += @max(1, adv_px);
    }
}

/// 등록된 SVG 아이콘의 coverage 를 Zig 에서 만든다 — 두 플랫폼이 같은 코드를 쓴다.
/// 상태바 아이콘 줄. **예약(레이아웃 padding)과 그리기가 같은 수를 봐야 한다** — 따로 적으면
/// 개수를 늘렸을 때 아이콘만 왼쪽으로 번져 카드 위에 겹친다(그 모양을 화면으로 한 번 잡았다).
/// 그리는 크기. **히트(44)와 다른 값이다** — 44 를 꽉 채우면 아이콘끼리 붙어 보인다.
/// 18 은 26px 줄에 맞춰 고른 값이라 44 줄에서는 작아 보였다(실제 하단 바는 24~28 을 쓴다).
const status_icon_px: i32 = 24;
const icon_slot_px = 32;
/// 1 = 하단 바(톱니), +4 = 보조 키바 방향키.
/// 아이콘 아틀라스에 굽는 것들. **이 배열이 개수의 출처다.**
///
/// **톱니 하나뿐이다.** 나머지 다섯(git·plus·search·bell·collapse)은 데스크톱 chrome 헤더에서
/// 따라온 것이고 **배선이 없었다** — 히트 rect 를 세우는 코드가 톱니에만 있어서, 다섯 개는
/// 그려지기만 하고 눌러도 아무 일이 안 났다. [UX 계약 §2](../../../docs/mobile-ux.md) 에도 자리가
/// 없다: `plus` 는 **서버 목록** 것이고, `git_branch` 는 버튼이 아니라 **세션 목록의 필드**이며,
/// `search`·`sidebar_collapse` 는 계약에 아예 없다(계약 §2.4 가 "데스크톱 도크의 전면 이식" 을
/// 버리기로 이미 적어 뒀다). `bell` 은 화면은 있으나 진입점을 여기로 두기로 한 적이 없다.
/// **각자의 화면이 생기면 그 화면에서 꺼낸다**(계획 U3).
const status_cps = [_]u32{maru.icons.codepoint(.gear)};

/// 톱니가 몇 번째 슬롯인가. **배열에서 찾는다** — 손으로 적으면 아이콘을 늘릴 때 조용히
/// 어긋나고, 그러면 설정 입구가 엉뚱한 자리에 선다.
const gear_slot: usize = blk: {
    for (status_cps, 0..) |cp, i| {
        if (cp == maru.icons.codepoint(.gear)) break :blk i;
    }
    break :blk 0;
};

/// 보조 키바 방향키. **폰트 글리프(`↑↓←→`)로는 안 됐다** — 폰트마다 작게 디자인돼 44px
/// 키캡 안에서 `esc`·`tab` 보다 훨씬 작아 보였다(화면으로 확인). 합성 아이콘은 슬롯을
/// 가장자리까지 채우므로 라벨 크기와 무관하게 또렷하다.
const arrow_cps = [_]u32{
    maru.icons.codepoint(.arrow_up),
    maru.icons.codepoint(.arrow_down),
    maru.icons.codepoint(.arrow_left),
    maru.icons.codepoint(.arrow_right),
};

/// 방향키가 시작하는 슬롯. **번호를 손으로 적지 않는다** — 상태바에 아이콘을 하나 넣는 순간
/// 키바 화살표와 설정 뒤로가기가 엉뚱한 그림이 되는데, 빌드는 통과하고 화면만 틀린다.
/// 두 배열을 이어 붙이므로 **순서가 구조로 정해진다**(검사할 것이 남지 않는다).
const arrow_slot_base: u32 = @intCast(status_cps.len);
const icon_slots = status_cps.len + arrow_cps.len;
/// **RGBA8** 이어야 한다 — `glyph_pixels.slotFits` 가 `bytes_per_row >= width*4` 를 요구한다
/// (단일 채널을 주면 조용히 0을 돌려준다. 실측: filled=0/6 으로 헤맸다). 셰이더는 alpha 를
/// coverage 로 읽는다.
var icon_pixels: [icon_slots * icon_slot_px * icon_slot_px * 4]u8 = undefined;

pub export fn maru_mobile_icon_atlas() [*]const u8 {
    return &icon_pixels;
}
pub export fn maru_mobile_icon_slot_px() u32 {
    return icon_slot_px;
}
pub export fn maru_mobile_icon_count() u32 {
    return icon_slots;
}

/// 아이콘 coverage 를 채우고, 실제로 잉크가 있는 슬롯 수를 돌려준다(0이면 자산 이식 실패).
pub export fn maru_mobile_icon_build() u32 {
    @memset(&icon_pixels, 0);
    // **이름으로 부른다.** PUA codepoint 리터럴은 경계 테스트가 막는다
    // (docs/chrome-strategy.md §9.7) — 자산이 옮겨 가면 리터럴만 조용히 어긋난다.
    const cps = status_cps ++ arrow_cps;
    var filled: u32 = 0;
    for (cps, 0..) |cp, i| {
        const stride = icon_slot_px * 4;
        const base = i * icon_slot_px * stride;
        const slot = icon_pixels[base .. base + icon_slot_px * stride];
        const n = icon_glyph.fillCoverage(cp, icon_slot_px, icon_slot_px, stride, slot) orelse continue;
        if (n > 0) filled += 1;
    }
    return filled;
}

/// 터미널 화면을 조립한다 — **본문과 보조 키바뿐이다**(U3: 탭·사이드바·하단 바를 걷어냈다).
fn buildUi(width: u32, height: u32, tk: *const tokens.Tokens) !void {
    var entries: [256]tree.RectEntry = undefined;
    var items: [256]layout.Item = undefined;
    var flex_scratch: [256]layout.FlexScratch = undefined;
    var child_rects: [256]layout.UiRect = undefined;

    // ── 상단 탭·좌측 사이드바는 **없다.** 데스크톱 chrome 을 옮겨 놓고 배선을 안 해서,
    // 탭 셋과 카드 다섯이 **눌러도 아무 일이 안 났다**(핸들러가 아예 없었다). 계획 U0 이 같은
    // 진단을 적어 뒀다 — "지금 구현은 탭 줄인데 그건 결정이 아니라 데스크톱을 옮긴 결과다".
    // 세션이 하나뿐이라(브리지가 `term_core` 단일 변수) 탭에 실을 것도 없고, 사이드바는 폰
    // 세로에서 **폭의 1/3 을 상시 점유**했다. 세션 전환 손짓과 화면들은 U2 가 M3 결정 뒤에
    // 세운다 — 그때까지 가짜를 그리지 않는다([UX §2.4](../../../docs/mobile-ux.md)).

    // ── 본문: **진짜 터미널 화면**이다. 자식 없이 자리만 잡고, 그 사각형을
    // `TerminalCore` 의 셀 격자로 채운다(아래 `pushTerminal`). 앞 단계의 하드코딩
    // 문자열과 달리 VT 파서를 실제로 태우므로 SGR 색·한글 2셀 폭이 코어에서 나온다.
    const body = tree.container(.{ .id = 300, .direction = .column, .style = .{ .flex = .{ .grow = 1 }, .padding = .{ .left = body_pad_x, .right = body_pad_x, .top = body_pad_y, .bottom = body_pad_y } } }, &.{});

    // ── 하단 바는 **없다.** 아이콘 다섯은 배선이 없었고(U3a), 남은 톱니 하나를 위해 44px 를
    // 영구히 쓰는 것은 두 플랫폼 관례도 아니다 — 하단은 이동 대상(destination) 자리이고
    // 동작은 앱 바 오른쪽·오버플로가 관례다. 설정 입구는 부모 화면(세션 목록)으로 갔고,
    // 그만큼이 본문으로 돌아왔다.

    // ── 보조 키바: 소프트 키보드에 없는 키들(Ctrl·Esc·Tab·화살표) + 셸 문장부호
    //
    // **레이아웃은 자리만 잡고 키는 브리지가 직접 그린다.** 키가 손가락 크기(44)라 화면을 넘쳐
    // **가로 스크롤은 안 쓴다.** 예전 머리말은 「키가 화면을 넘쳐 가로 스크롤이 필요한데
    // `scroll_area` 가 세로 전용이라 못 쓴다」였는데 **전제가 둘 다 무너졌다**: 넘치면 밀지 않고
    // **줄을 늘리고**(`keyBarRows`), 그 컴포넌트도 이제 축에 안 묶여 있다(`Touch.pos` 가 스칼라다).
    // 남은 이유는 하나다 — `tree` 는 스크롤 개념이 없고 음수 margin 은 `error.NegativeValue` 로
    // 거부되며(실측 — 화면이 통째로 검게 나갔다), 키바는 "고정 크기 버튼의 격자" 라 엔진 없이
    // 그리는 편이 싸다.
    // **줄에서 빠지는 키는 없다.** 조건부로 나타나는 키를 두면 나머지가 밀려 손가락이 겨눈
    // 자리가 바뀐다 — `copy` 도 늘 있고 못 쓸 때만 흐리다. 폭이 좁아 한 줄에 못 넣을 때도
    // **접는 것은 줄이지 키가 아니다**.
    const bar_n: usize = key_bar.len;
    // 줄 수·칸 수·높이를 **한 번 정해** 자리 잡기와 그리기가 같은 값을 본다(갈리면 아래 줄이
    // 잘리거나 격자가 넘친다).
    const bar_rows = keyBarRows(@floatFromInt(width));
    const bar_cols = keyBarCols(bar_rows);
    const bar_h = keyBarHeight(@floatFromInt(width));
    // 자식 없는 카드 하나가 **밴드 자리**만 잡는다. 키는 아래에서 직접 그린다.
    const bar = tree.card(.{
        .id = key_bar_id_base - 1,
        // **줄 수만큼 높다.** 숫자를 손으로 적으면 키를 더했을 때 아래 줄이 잘린다.
        .style = .{ .width = .{ .percent = 1.0 }, .height = .{ .px = bar_h } },
    }, &.{});

    // ── 상단 앱 바: **돌아갈 길이 보여야 한다.** U3b 가 하단 바를 걷어내며 터미널 화면의
    // chrome 을 통째로 없앴고, 남은 길은 가장자리 스와이프뿐이 됐다 — iOS 관례지만 **보이지
    // 않고**, Android 는 시스템 뒤로가기가 따로 있어 같은 화면이 두 플랫폼에서 다르게 읽힌다
    // (사용자 요청). 높이는 **다른 화면과 같은 값**이다 — 화면마다 다르면 옮길 때 본문이 튄다.
    const app_bar = tree.card(.{
        .id = term_bar_id,
        .style = .{ .width = .{ .percent = 1.0 }, .height = .{ .px = set_head_h } },
    }, &.{});

    // **자리가 없으면 키바를 안 그린다.** 본문 격자는 최소 `min_body_rows` 줄을 그리는데
    // (`pushTerminal` 의 바닥), 레이아웃이 그만큼도 안 남기면 **격자가 제 사각형 밖으로 넘쳐
    // 키바 밑에 깔린다** — 가로에서 소프트 키보드를 올리면 그 모양이 됐다(실측 2026-09-05:
    // 「Last login…」이 `esc`·`tab` 키 밑에 깔렸고 키바 아랫줄은 키보드에 잘렸다).
    //
    // **키바를 접는 쪽을 택한다.** 키바의 존재 이유는 「소프트 키보드에 없는 키」인데 그것을
    // 남기려다 터미널이 사라지면 앞뒤가 바뀐다. 그리고 남겨 봐야 잘려서 못 누른다 — 안 그리면
    // `key_bar_ready` 도 안 서서 **없는 키가 눌리는 일도 없다**(그 규율은 이미 있었다).
    //
    // 이건 **가로 레이아웃을 정한 것이 아니다** — 넘침을 막는 바닥이다. 가로에서 몇 줄로 그릴지는
    // 위 `keyBarRows` 가 폭을 보고 정한다.
    const min_body_h = @as(f32, @floatFromInt(@as(i32, min_body_rows) * lineHeight()));
    const bar_fits = @as(f32, @floatFromInt(height)) - set_head_h - bar_h >= min_body_h;
    const root = if (bar_fits)
        tree.container(.{ .id = 1, .direction = .column }, &.{ app_bar, body, bar })
    else
        tree.container(.{ .id = 1, .direction = .column }, &.{ app_bar, body });

    const built = try tree.build(root, .{
        .root_size = .{ .width = @floatFromInt(width), .height = @floatFromInt(height) },
        .max_entries = entries.len,
        .max_depth = 16,
    }, .{ .entries = &entries, .items = &items, .flex_scratch = &flex_scratch, .child_rects = &child_rects });

    // ── paint: 실제 컴포넌트 경로가 내는 ChromeDraw
    var ops: [512]draw.Op = undefined;
    const cd = try paint_mod.paint(built, .{}, tk, .sidebar, .{ .ops = &ops });

    // 배경 먼저
    push(.{ .x = 0, .y = 0, .w = width, .h = height }, tk.get(.surface_bg), 0xFF, 0, 0);
    for (cd.ops) |op| switch (op) {
        // **테두리를 그린다.** 예전에는 `border_widths`/`border_role` 을 통째로 버려서, 컴포넌트가
        // 테두리를 요청해도 화면에는 채움만 나왔다 — 손가락은 hover 로 더듬을 수 없어 **눌리는
        // 자리의 경계가 보이는 것이 크기보다 먼저**인데, 그게 아예 안 그려지고 있었다.
        // 바깥을 테두리 색으로 칠하고 그 안에 채움을 얹는다(quad 둘 — 셰이더에 테두리 개념이 없다).
        .quad => |q| {
            const bw: u32 = q.border_widths[0];
            if (q.border_role) |role| if (bw > 0 and q.rect.w > 2 * bw and q.rect.h > 2 * bw) {
                push(q.rect, tk.get(role), q.alpha, q.corner_radii[0], 0);
                push(.{
                    .x = q.rect.x + @as(i32, @intCast(bw)),
                    .y = q.rect.y + @as(i32, @intCast(bw)),
                    .w = q.rect.w - 2 * bw,
                    .h = q.rect.h - 2 * bw,
                }, tk.get(q.fill_role), q.alpha, if (q.corner_radii[0] > bw) q.corner_radii[0] - @as(u16, @intCast(bw)) else 0, 0);
                continue;
            };
            push(q.rect, tk.get(q.fill_role), q.alpha, q.corner_radii[0], 0);
        },
        .fill => |f| push(f.rect, tk.get(f.role), f.alpha, 0, 0),
        .border => |b| push(b.rect, tk.get(b.role), 0x60, 0, 0),
        .rule => |r| push(.{ .x = r.from.x, .y = r.from.y, .w = @intCast(@max(1, r.to.x - r.from.x)), .h = @intCast(@max(1, r.to.y - r.from.y)) }, tk.get(r.role), 0xFF, 0, 0),
        // **텍스트는 여기서 그리지 않는다.** `ui.paint` 는 `resolveText` 결과를 버려서
        // 이 분기가 실제로는 안 온다(`_ = paint_style.resolveText(visual)`). 글자는 아래
        // 레이아웃 entry 를 훑어 아틀라스로 그린다 — 혹시 이 op 이 오더라도 여기서 또
        // 그리면 같은 자리에 두 번 그려진다.
        .text => {},
        else => {},
    };

    // **터미널 화면의 트리에는 글자 노드가 없다.** 여기 있던 루프는 탭 라벨·사이드바 이름을
    // 그리던 것이고, 그 chrome 을 걷어내면서(U3a) 한 번도 안 도는 코드가 됐다 — `labelFor` 도
    // 함께 지웠다. 본문 글자는 `pushTerminal` 이 코어 격자에서 직접 내고, 키바 라벨은 키바가,
    // 설정·세션 목록 글자는 각 화면이 `pushText` 로 직접 낸다.

    // 키바의 각 사각형을 기록한다 — **그리는 자리와 판정하는 자리가 같아야** 눌러도
    // 다른 키가 나가지 않는다(따로 계산하면 갈린다).
    // **자리를 다 못 채웠으면 안 섰다고 답한다.** 세우기만 하고 안 내리면, 레이아웃에서
    // 키바가 빠진 프레임에도 **옛 자리를 그대로 답해** 없는 키가 눌린다.
    // 앱 바 자리를 기록한다 — **그리는 자리와 누르는 자리가 같아야** 한다(키바와 같은 규율).
    term_bar_rect = .{};
    for (built.entries) |entry| {
        if (entry.id != term_bar_id) continue;
        term_bar_rect = .{ .x = entry.rect.x, .y = entry.rect.y, .w = entry.rect.width, .h = entry.rect.height };
        break;
    }

    drawTerminalBar(tk);

    key_bar_ready = false;
    key_bar_rows_drawn = 0;
    for (built.entries) |entry| {
        if (entry.id != key_bar_id_base - 1) continue;
        const band = entry.rect;
        key_bar_band = .{ .top = band.y, .bot = band.y + band.height };
        // **키가 지나가는 창은 화살표 안쪽**이다. 창을 밴드 전체로 두면 `<`/`>` 배경이 가장자리
        // 키 위에 얹혀 그 라벨을 지운다(화면으로 확인 — 첫 키가 빈 칸이 됐다).
        // **가장자리에서 띄운다.** `>` 가 화면 끝에 딱 붙으면 잘려 보인다(사용자가 화면에서
        // 짚었다). 밴드 자체는 화면 폭이므로 여기서 좌우를 물린다.
        const band_x = band.x + key_bar_pad_x;
        const band_w = band.width - 2 * key_bar_pad_x;
        // **칸을 화면 폭으로 나눈다.** 예전에는 44px 고정에 가로 스크롤이었는데, 밀어야 닿는
        // 키는 급할 때 못 찾는다(Ctrl·화살표가 그렇다 — 사용자 요청으로 두 줄 격자가 됐다).
        // 나눈 칸은 44 보다 넓어 손가락에도 낫다.
        const cell_w = band_w / @as(f32, @floatFromInt(bar_cols));
        const kw = @floor(cell_w) - key_gap;
        keybar_armed_drawn = 0;
        for (0..key_bar.len) |i| {
            const col = i % bar_cols;
            const row = i / bar_cols;
            const kx = @floor(band_x + @as(f32, @floatFromInt(col)) * cell_w + key_gap / 2);
            const ky = @floor(band.y + 5.0 + @as(f32, @floatFromInt(row)) * (key_h + key_gap));
            key_bar_rects[i] = .{ .x = kx, .y = ky, .w = kw, .h = key_h };
            // **키바 키도 버튼이다.** 눌러 둔 수정자는 `selected` 로 읽히고, 못 쓰는 키는
            // 서술자를 **빼지 않고** `enabled = false` 로 낸다 — 계약이 「누를 수 없는 컨트롤도
            // 자리와 이름은 있다」로 정한 자리다(P1).
            const kr = key_bar_rects[i];
            noteA11y(.{ .x = kr.x, .y = kr.y, .w = kr.w, .h = kr.h }, .{
                .role = .button,
                .label = key_bar[i].label,
                .enabled = !(key_bar[i].is_copy and !copyEnabled()),
                .selected = armed_mods & key_bar[i].sticky_mod != 0,
            });
            drawKey(i, kx, ky, kw, tk);
        }
        // **스크롤 표시(`<`/`>`)는 없앴다** — 두 줄 격자라 전부 한눈에 들어와서 "더 있다" 를
        // 알릴 것이 없다. 남겨 두면 아무 데도 안 미는 화살표가 가장자리 칸을 먹는다.
        key_bar_ready = bar_n > 0;
        if (key_bar_ready) key_bar_rows_drawn = bar_rows;
    }

    // **본문은 진짜 터미널 코어다.** 레이아웃이 잡아 준 본문 사각형에 셀 격자를 채운다.
    for (built.entries) |entry| {
        if (entry.id != 300) continue;
        // **레이아웃 결과는 border box 다**(`chrome/ui/layout.zig` 머리말). 그대로 넘기면 격자가
        // padding 까지 제 몫으로 세어 **아래로 넘치고, 그 넘침이 보조 키바를 덮는다** — 기기에서
        // `ctrl` 줄이 소프트 키보드에 잘려 `Ctrl+B` 를 못 누르는 것으로 나타났다.
        //
        // **이것이 폰트 크기와 키바를 얽히게 한 자리이기도 하다.** 설계상 둘은 독립이다(키바는
        // 고정 높이를 요구하고 본문은 남은 것만 가져간다). 넘치는 양이 `line_h` 로 환산되니
        // 글자를 줄일수록 더 많은 행이 되어 티가 커졌을 뿐이다 — 경계를 지키면 서로 무관해진다.
        pushTerminal(.{
            .x = entry.rect.x + body_pad_x,
            .y = entry.rect.y + body_pad_y,
            .width = @max(0.0, entry.rect.width - 2 * body_pad_x),
            .height = @max(0.0, entry.rect.height - 2 * body_pad_y),
        }, tk);
        break;
    }
    // **본문 뒤에** 그린다 — 앱 바 아래는 본문이 시작하는 자리라 먼저 그리면 덮인다.
    if (screenTop() == .terminal) drawConnBanner(tk);

    // 하단 아이콘 줄은 **없다**(위 "하단 바는 없다"). `status_cps` 는 남는다 — 그 배열이
    // 아이콘 아틀라스의 출처이고, 톱니 글리프는 세션 목록 화면이 쓴다.
}

/// UiId → 문자열. `RectEntry` 는 문자열을 들고 있지 않으므로(레이아웃만 담는다) 조립할 때
/// 쓴 값을 여기서 되찾는다.
// ── 설정 화면 (PoC) ───────────────────────────────────────────────────────────
//
// **라우터 하나로 민다 — 모달이 아니다**([UX 계약 §3](../../../docs/mobile-ux.md)). 폰에서
// 전체화면 모달과 push 는 **보이는 것이 똑같고**, 다른 것은 되돌아가는 손짓의 의미뿐이다:
// Android 하드웨어 뒤로가기와 iOS 좌측 스와이프가 pop 이어야 하는데, 모달을 스택 밖에 두면
// 그 둘이 갈 곳이 없어 **스택을 두 벌** 두게 된다.
//
// **PoC 다.** 값은 아직 config 로 안 간다 — 스키마는 M10 이 짠다. 여기서 확인하려는 것은
// **"44 로 세운 설정 목록이 손가락에 어떻게 잡히는가"** 하나이고, 그래서 행·팝업·되돌아가기가
// 전부 실제로 눌린다.

const Screen = enum { sessions, terminal, settings, servers, server_edit, password, host_key, remote_screen };

/// **화면 스택이다**(UX §3 — "모달을 안 쓴다, 라우터 하나다"). 단일 변수로 두면 화면이 늘 때
/// "어디로 돌아가나" 를 분기마다 다시 적게 되고, 그 분기 하나를 빠뜨리면 뒤로가기가 갈 곳을
/// 잃는다. 깊이는 셋이면 충분하다(목록 → 터미널, 목록 → 설정).
var nav: [4]Screen = .{ .sessions, .terminal, .terminal, .terminal };
/// 스택에 실제로 쌓인 수. **앱은 터미널에서 시작한다** — 세션 목록은 그 아래에 있고 뒤로
/// 가면 나온다. 매번 목록을 거치게 하면 이 앱의 주 용도에 탭이 하나 더 붙는다.
var nav_len: usize = 2;

/// 누른 원격 줄을 연다. **누를 때 잡아 두는 것은 «그 세션의 id» 다** — 자리(좌표)도 순번(index)도
/// 아니다.
///
/// 좌표가 안 되는 것은 분명하다(그 사이 목록이 흐르거나 갱신되면 다른 줄이 그 자리에 온다).
/// **순번도 안 된다** — `absorbFrame` 이 줄을 갈아 끼우면 5번이 다른 세션이 된다(적대적 검증
/// 3회차). 누름과 뗌 사이는 짧지만, 목록은 그 서버가 바뀔 때마다 갱신되므로 **그 창이 실제로
/// 열린다.** id 로 잡으면 갱신돼도 사용자가 누른 그것을 열고, 사라졌으면 아무것도 안 연다.
fn openRemoteRow() void {
    const id = remote_pressed_id orelse return;
    remote_pressed_id = null;
    // 그 id 가 아직 목록에 있나 — 없으면 그 세션은 사라졌다.
    for (control_rows[0..control_row_count]) |*row| {
        if (!row.has_runtime) continue;
        if (!std.mem.eql(u8, &row.runtime_id, &id)) continue;
        wantControl(.{ .screen = id });
        navPush(.remote_screen);
        return;
    }
}

/// 그 좌표에 있는 **누를 수 있는** 원격 줄. 붙을 수 없는 줄은 null 이다 — 눌리는 것처럼 보이고
/// 아무 일도 안 일어나면 사용자는 고장으로 읽는다.
fn remoteRowAt(x: f32, y: f32) ?usize {
    if (remote_rows_drawn == 0 or remote_row0.h <= 0) return null;
    // **목록 창 밖은 어느 줄도 아니다**(적대적 검증 2회차). 목록이 흐르면서 `remote_row0.y` 가
    // 음수가 될 수 있는데, 그러면 아래 「첫 줄보다 위인가」 가드가 무력해져 **고정 헤더의 빈
    // 자리를 눌러도 그 밑으로 지나간 줄이 열린다** — UX 계약이 「붙임 헤더 밑을 눌러 안 보이는
    // 값이 바뀌는 것」을 막으라고 적어 둔 바로 그 모양이다.
    if (y < sess_list.y or y > sess_list.y + sess_list.h) return null;
    if (x < remote_row0.x or x > remote_row0.x + remote_row0.w) return null;
    if (y < remote_row0.y) return null;
    const rel = y - remote_row0.y;
    const pitch = remote_row0.h + 1;
    const idx_f = @floor(rel / pitch);
    if (idx_f < 0) return null;
    const idx: usize = @intFromFloat(idx_f);
    if (idx >= remote_rows_drawn or idx >= control_row_count) return null;
    // 줄 사이 divider 를 누른 것은 어느 줄도 아니다.
    if (rel - idx_f * pitch > remote_row0.h) return null;
    return if (control_rows[idx].has_runtime) idx else null;
}

/// 지금 보이는 화면 — 스택의 꼭대기다.
fn screenTop() Screen {
    return nav[nav_len - 1];
}

/// 화면을 민다. 스택이 꽉 차면 안 민다(그럴 일은 없지만 조용히 덮어쓰는 것보다 낫다).
fn navPush(s: Screen) void {
    if (nav_len >= nav.len) return;
    nav[nav_len] = s;
    nav_len += 1;
    syncKeyboardForScreen();
}

/// 한 장 뺀다. **뿌리는 안 뺀다** — 스택이 비면 그릴 화면이 없다.
fn navPop() void {
    if (nav_len > 1) nav_len -= 1;
    syncKeyboardForScreen();
}

/// 행 높이. **한 셀(22)이 아니라 손가락(44)이다** — 목록에서는 "작게 그리고 넓게 받는다"
/// 가 안 통한다(22 간격에 44 히트를 주면 위아래 행이 11px 씩 겹쳐 어느 행인지 모호해진다).
/// 그래서 **행 자체를 키우고 행 전체를 히트로** 쓴다(iOS·Android 설정 앱 관례).
const set_row_h: f32 = 44.0;
const set_head_h: f32 = 52.0;
const set_pad_x: f32 = 16.0;

/// 줄의 **생김새**는 스키마가 준다(`mobile_config.Row`). 값은 여기 안 든다 — 그릴 때마다
/// config 에서 읽는다("파일이 단일 출처", 계약 §1). 화면이 자기 값을 들면 파일과 갈린다.
/// 목록은 **필드와 헤더가 섞인 한 줄기**다. 헤더로 화면을 나누지 않는다 — 하위 화면으로
/// 밀면 설정 하나 바꾸는 데 탭이 하나 더 붙는데, [UX §3](../../../docs/mobile-ux.md)이
/// "터미널에서 시간을 가장 많이 쓴다" 고 못박아 뒀다. 헤더는 **순서만** 주고 누를 수 없다.
const SetItem = union(enum) { header: []const u8, field: mobile_config.Row };

const set_header_h: f32 = 34.0;

/// 목록은 **스키마에서 나온다**(계약 §6). PoC 는 라벨 58개를 손으로 적어 뒀는데 그 대부분은
/// 뒤에 키가 없어 눌러도 아무 일이 안 났다 — 이제 **키가 있는 줄만** 생기고, 스키마에 키를
/// 더하면 줄이 늘고 빼면 사라진다. 섹션 헤더도 그 줄들에서 만든다(모바일이 소유하는 분류).
const set_items: []const SetItem = blk: {
    var list: []const SetItem = &.{};
    var last: []const u8 = "";
    for (mobile_config.rows) |r| {
        if (!std.mem.eql(u8, r.section, last)) {
            list = list ++ [_]SetItem{.{ .header = r.section }};
            last = r.section;
        }
        list = list ++ [_]SetItem{.{ .field = r }};
    }
    break :blk list;
};

fn setItemH(i: usize) f32 {
    return switch (set_items[i]) {
        .header => set_header_h,
        .field => set_row_h,
    };
}

const SetRect = struct { x: f32 = 0, y: f32 = 0, w: f32 = 0, h: f32 = 0 };
fn setHit(r: SetRect, x: f32, y: f32) bool {
    return r.w > 0 and r.h > 0 and x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h;
}

var set_row_rects: [set_items.len]SetRect = @splat(.{});
var set_back_rect: SetRect = .{};
var set_gear_rect: SetRect = .{};
var set_list: SetRect = .{}; // 목록이 보이는 창(헤더 아래) — 클리핑·스크롤 한계의 기준
/// **스크롤은 컴포넌트가 든다**(`chrome.ui.scroll_area`). 예전에는 브리지가 offset·관성·감쇠를
/// 손으로 갖고 있었는데(`set_fling` + 프레임당 0.92) 같은 규칙이 키바에도 따로 있었다 — 두 번째
/// 소비처가 생긴 이상 규칙을 한곳에 둔다(계획 U1).
var set_sa: scroll_area.State = .{};
/// 편집 줄을 **어느 창 높이에 맞춰 뒀는지**. 같은 조합이면 다시 안 건드린다 — 매 프레임
/// 끌어당기면 편집 중 스크롤이 죽는다.
var set_reveal: ?struct { idx: usize, win_h: f32 } = null;

/// 이번 짚음이 **관성을 세운 것**인가. 그렇다면 행을 안 누른다.
var set_touch: scroll_area.Touch = .{};
var set_max_scroll: f32 = 0;
var set_pressed: ?usize = null;
var set_back_pressed: bool = false;
var set_open: ?usize = null; // 팝업이 열린 행
/// **가장 긴 목록에 맞춘다 — 숫자를 손으로 적지 않는다.** 예전에는 8이었고 프리셋 목록도 손으로
/// 적은 8개라 **우연히** 맞았다(그 자리 주석이 예고해 뒀다). 목록을 스키마·enum 에서 만들자
/// 프리셋이 16개가 되어 **절반을 고를 수 없게** 됐다 — `nord` 가 14번째다.
const set_item_cap: usize = blk: {
    var m: usize = 1;
    for (mobile_config.rows) |r| m = @max(m, r.items.len);
    break :blk m;
};
var set_item_rects: [set_item_cap]SetRect = @splat(.{});
var set_item_n: usize = 0;
/// 팝업이 목록 영역보다 길 때의 스크롤(본문 목록과 같은 모양).
/// 팝업 스크롤도 컴포넌트가 든다(목록·키바와 같은 규칙). 관성은 안 쓴다 — 항목이 열여섯이라
/// 끝까지 밀 일이 없고, 고르는 화면에서 미끄러지면 엉뚱한 것이 손가락 밑에 온다.
var set_pop_sa: scroll_area.State = .{};
var set_pop_max_scroll: f32 = 0;
/// 설정 화면의 제스처. **뜻은 상태 하나가 든다**(계약 §3.1) — 전에는 `set_active`·`set_moved`·
/// `set_stop_tap` 이 따로 있었고 "탭이다" 를 자리마다 조합으로 다시 만들었다.
var set_press: gesture.Press = .{};
/// 스크롤 델타의 기준. **제스처 상태가 아니다** — 임계와 무관하게 매 move 갱신한다.
var set_last_y: f32 = 0;

/// 지금 스크롤 위치(px). 컴포넌트가 정수로 들고 있으므로 그리는 쪽만 f32 로 받는다.
fn setScroll() f32 {
    return @floatFromInt(set_sa.offset_y_px);
}

fn stepSetFling() void {
    _ = set_touch.step(&set_sa, @intFromFloat(@max(0, set_max_scroll)), frame_dt_ms);
    // **서버 목록도 같은 걸음으로 흐른다.** 한쪽만 밟으면 손을 뗀 뒤 그 화면만 즉시 멈춘다 —
    // 같은 손짓이 화면마다 다르게 굴면 사용자는 매번 시험해 봐야 한다.
    _ = srv_touch.step(&srv_sa, @intFromFloat(@max(0, srv_max_scroll)), frame_dt_ms);
    // 세션 목록도 같은 걸음이다 — 한쪽만 밟으면 손을 뗀 뒤 그 화면만 즉시 멈춘다.
    _ = sess_touch.step(&sess_sa, @intFromFloat(@max(0, sess_max_scroll)), frame_dt_ms);
}

/// 설정 줄 하나를 서술자로 낸다. **자리는 이미 잡혀 있다**(`set_row_rects[i]` — 그리기와 히트가
/// 함께 쓰는 그 사각형이라, 읽는 자리도 같은 값이다).
///
/// 값을 이름에 붙이지 않는 이유는 계약이 소유한다 — 스크린 리더는 값만 바뀌었을 때 이름을 다시
/// 안 읽는다. 토글은 켜짐/꺼짐이 **손잡이 자리와 색으로만** 말해지던 것이라, 그 사실을 값과
/// `selected` 두 가지로 준다(읽는 쪽이 무엇을 쓰든 사실이 닿게).
/// 그린 값에서 **캐럿을 뗀다.** 화면은 「지금 이 줄이 입력을 받는다」를 캐럿(▏)과 색으로 말하는데,
/// 색은 안 읽히고 캐럿은 **글자로 읽힌다**(「왼쪽 팔분의 일 블록」 같은 이름이 값 끝에 붙는다).
/// 사실은 `selected` 로 주고, 값에서는 뗀다.
fn stripCaret(text: []const u8) []const u8 {
    const caret = "\u{258F}";
    return if (std.mem.endsWith(u8, text, caret)) text[0 .. text.len - caret.len] else text;
}

fn noteA11ySettingRow(i: usize, label: []const u8, value: []const u8, on: bool, list_top: f32, list_h: f32) void {
    // **팝업이 열려 있으면 아래 줄은 안 눌린다** — 포인터가 「항목 아니면 닫기」만 하기 때문이다.
    // 그때 이 줄들을 계속 내면 스크린 리더가 안 눌리는 것을 읽어 준다(이 이니셔티브가 계속
    // 막아 온 그 모양이다). **누르는 쪽과 같은 조건을 본다.**
    if (set_open != null) return;
    noteA11yClipped(
        set_row_rects[i],
        .{ .x = set_list.x, .y = list_top, .w = set_list.w, .h = list_h },
        .{
            .role = .button,
            .label = label,
            .value = stripCaret(value),
            // **편집 중이라는 사실도 여기 실린다.** 토글의 켜짐/꺼짐과 같은 이유다 — 화면이
            // 색으로만 말하는 것은 안 읽힌다. 지금 키보드가 어디로 가는지 모르면 칠 수가 없다.
            .selected = on or (set_edit != null and set_edit.? == i),
        },
    );
}

fn drawSetToggle(on: bool, cx: f32, cy: f32, tk: *const tokens.Tokens) void {
    const w: f32 = 44;
    const h: f32 = 26;
    const x = cx - w;
    const y = cy - h / 2;
    push(.{ .x = @intFromFloat(x), .y = @intFromFloat(y), .w = @intFromFloat(w), .h = @intFromFloat(h) }, tk.get(if (on) .accent_bar else .divider), 0xFF, 13, 0);
    const k: f32 = 20;
    const kx = if (on) x + w - k - 3 else x + 3;
    push(.{ .x = @intFromFloat(kx), .y = @intFromFloat(y + 3), .w = @intFromFloat(k), .h = @intFromFloat(k) }, tk.get(.surface_fg), 0xFF, 10, 0);
}

/// 설정 화면을 창 전체에 그린다. **그리는 자리를 그대로 히트 사각형에 기록한다** — 따로
/// 계산하면 갈린다(키바에서 1px 어긋나 옆 키가 나갔던 그 결함).
/// 지금 화면 이름(테스트용). **좌표를 테스트가 다시 계산하지 않게** 하는 것과 같은 이유다 —
/// 화면 전환 규칙이 바뀌면 테스트가 제품에게 물어야 한다.
pub fn currentScreenName() []const u8 {
    return @tagName(screenTop());
}

/// 세션 목록의 **서버 줄** 한가운데(테스트용 — 좌표를 테스트가 다시 계산하지 않는다).
pub fn serversEntryCenter() struct { x: f32, y: f32 } {
    return .{ .x = sess_servers_rect.x + sess_servers_rect.w / 2, .y = sess_servers_rect.y + sess_servers_rect.h / 2 };
}

/// 편집 화면의 **뒤로** 한가운데(테스트용).
pub fn serverEditBackCenter() struct { x: f32, y: f32 } {
    return .{ .x = srv_edit_back_rect.x + srv_edit_back_rect.w / 2, .y = srv_edit_back_rect.y + srv_edit_back_rect.h / 2 };
}

/// 서버 목록의 **추가 줄** 한가운데(테스트용).
pub fn serverAddCenter() ?struct { x: f32, y: f32 } {
    if (srv_add_rect.h <= 0) return null;
    return .{ .x = srv_add_rect.x + srv_add_rect.w / 2, .y = srv_add_rect.y + srv_add_rect.h / 2 };
}

/// 목록에서 그 줄의 **편집** 자리 한가운데(테스트용).
pub fn serverEditHitCenter(i: usize) ?struct { x: f32, y: f32 } {
    if (i >= srv_edit_rects_in_list.len or srv_edit_rects_in_list[i].h <= 0) return null;
    const r = srv_edit_rects_in_list[i];
    return .{ .x = r.x + r.w / 2, .y = r.y + r.h / 2 };
}

/// 편집 화면의 줄(칸 다섯 · 저장 · 삭제) 한가운데(테스트용).
pub fn serverEditRowCenterY(i: usize) ?f32 {
    if (i >= srv_edit_rects.len or srv_edit_rects[i].h <= 0) return null;
    return srv_edit_rects[i].y + srv_edit_rects[i].h / 2;
}

/// 편집 화면에서 **그 일을 하는 줄이 몇 번인가**(테스트용). 번호를 테스트가 손으로 적으면
/// 줄을 하나 끼울 때 조용히 다른 줄을 누르게 된다(공개키 줄을 넣다 실제로 그랬다).
pub fn serverEditPubkeyRow() usize {
    return server_field_n;
}
pub fn serverEditSaveRow() usize {
    return server_field_n + 1;
}
pub fn serverEditDeleteRow() usize {
    return server_field_n + 2;
}

/// 편집 화면의 줄 수(칸 + 저장 + 삭제).
pub fn serverEditRowN() usize {
    return srv_edit_rects.len;
}

/// 서버 목록의 지금 스크롤 위치(테스트용).
pub fn serverScrollY() f32 {
    return srvScroll();
}

/// 서버 화면에 실제로 **그려진** 줄 수. 목록 길이가 아니라 rect 를 센다 — 화면 밖 줄이 rect 를
/// 들고 있으면 "안 보이는데 눌린다" 가 되므로, 그 둘이 같은지도 이 값으로 본다.
pub fn serverRowCount() usize {
    var n: usize = 0;
    for (srv_row_rects) |r| {
        if (r.w > 0 and r.h > 0) n += 1;
    }
    return n;
}

/// 그 서버 줄의 세로 한가운데(안 그려졌으면 null).
pub fn serverRowCenterY(i: usize) ?f32 {
    if (i >= srv_row_rects.len) return null;
    const r = srv_row_rects[i];
    if (r.h <= 0) return null;
    return r.y + r.h / 2;
}

/// 세션 목록의 톱니 한가운데. 테스트가 좌표를 손으로 적으면 헤더 높이를 바꿀 때 조용히 빗나간다.
pub fn sessionsGearCenter() struct { x: f32, y: f32 } {
    return .{ .x = sess_gear_rect.x + sess_gear_rect.w / 2, .y = sess_gear_rect.y + sess_gear_rect.h / 2 };
}

/// 설정 화면 뒤로가기 한가운데(테스트용). **좌표를 테스트가 따로 적지 않는다** — 앱 바
/// 배치가 바뀌면 테스트만 맞고 화면은 틀리게 된다(이 저장소가 여러 번 겪은 결함이다).
pub fn settingsBackCenter() struct { x: f32, y: f32 } {
    return .{ .x = set_back_rect.x + set_back_rect.w / 2, .y = set_back_rect.y + set_back_rect.h / 2 };
}

/// 세션 줄 한가운데.
pub fn sessionsRowCenter() struct { x: f32, y: f32 } {
    return .{ .x = sess_row_rect.x + sess_row_rect.w / 2, .y = sess_row_rect.y + sess_row_rect.h / 2 };
}

/// 톱니 히트 자리(폭·높이). 손가락 기준 44 를 재는 테스트가 쓴다.
pub fn sessionsGearSize() struct { w: f32, h: f32 } {
    return .{ .w = sess_gear_rect.w, .h = sess_gear_rect.h };
}

/// 세션 목록의 톱니·줄 자리. **그리는 자리를 그대로 판정에 쓴다** — 따로 계산하면 갈린다.
var sess_gear_rect: SetRect = .{};
var sess_row_rect: SetRect = .{};
var sess_pressed: enum { none, gear, row, servers, remote_row } = .none;
/// 누른 원격 줄의 index(누름 판정과 뗌 판정이 **같은 줄**을 봐야 한다 — 그 사이 목록이 갱신되면
/// 좌표로 다시 찾은 줄은 다른 세션일 수 있다).
/// 누른 원격 줄의 **id**(순번이 아니다 — 위 `openRemoteRow` 주석).
var remote_pressed_id: ?[32]u8 = null;
/// 서버 목록으로 들어가는 줄. **여기서 들어간다** — UX 계약(§2.1)은 서버 목록을 세션 목록
/// *위*에 두지만, 뿌리를 바꾸면 앱이 뜨는 자리와 뒤로가기 스택이 함께 움직인다(그 재배치는
/// 다중 세션 U2 가 든다). 그때까지는 이 줄이 그 화면의 입구다.
var sess_servers_rect: SetRect = .{};
/// 세션 목록의 제스처. **설정 화면과 나눠 쓰지 않는다** — 전에는 `set_active`·`set_moved` 를
/// 그대로 썼고(한 번에 한 화면만 떠서 동작하기는 했다), 이름이 거짓말을 하는 데다 둘 중
/// 하나를 고치면 다른 하나가 조용히 바뀐다.
var sess_press: gesture.Press = .{};

// ── 세션 목록은 «흐른다» ──────────────────────────────────────────────────────────
//
// **예전에는 안 흘렀다.** 줄을 평범한 루프로 그리고 창을 넘으면 `return` 했다 — 오프셋이라는
// 개념 자체가 없었다. 그래서 맥에 탭이 열둘쯤 넘으면 **그 뒤 세션은 폰에서 닿을 수가 없었다**.
// 전환을 「덮개」로 정한 이상(계획 U0) 이 목록이 **세션을 바꾸는 유일한 통로**라, 통로에 못 가는
// 세션이 생긴다는 뜻이다. 들어가는 줄 수는 창에 달렸고(대략 열하나) 그 위는 조용히 사라졌다.
//
// 규칙은 서버 목록·설정과 같은 것을 쓴다(`chrome.ui.scroll_area`) — 같은 손짓이 화면마다 다르게
// 굴면 사용자는 매번 시험해 봐야 한다.
var sess_list: SetRect = .{};
var sess_sa: scroll_area.State = .{};
var sess_touch: scroll_area.Touch = .{};
var sess_max_scroll: f32 = 0;

/// 지금 스크롤 위치(px).
fn sessScroll() f32 {
    return @floatFromInt(sess_sa.offset_y_px);
}

/// 판정용 — 지금 그려진 「서버」 줄의 한가운데 y. 안 보이면 `null`.
/// 이번 프레임에 스크롤바를 그렸나. **판정용** — 「밀 수 있을 때만」이 규칙이라 그 조건을 잰다.
var sess_scrollbar_drawn: bool = false;

pub fn sessScrollbarDrawn() bool {
    return sess_scrollbar_drawn;
}

/// 판정용 — 지금 그려진 「터미널」 줄의 한가운데 y. 안 보이면 `null`.
pub fn sessTerminalRowCenterY() ?f32 {
    if (sess_row_rect.h <= 0) return null;
    return sess_row_rect.y + sess_row_rect.h / 2;
}

pub fn sessServersRowCenterY() ?f32 {
    if (sess_servers_rect.h <= 0) return null;
    return sess_servers_rect.y + sess_servers_rect.h / 2;
}

/// 그 사각이 목록 창 **안에 보이나**. 안 보이면 rect 를 안 남긴다 — 남기면 화면 밖인데 눌린다
/// (설정 목록에서 겪은 결함이다).
/// 판정자용 — 목록 창의 윗변(헤더 아래).
pub fn sessListTopForTest() f32 {
    return sess_list.y;
}

/// 판정자용 — 목록이 얼마나 밀렸나. **전제를 단언하는 데 쓴다**(안 밀렸는데 초록이면 그 판정은
/// 아무것도 안 잰 것이다).
pub fn sessScrollForTest() f32 {
    return sessScroll();
}

fn sessVisible(y: f32, h: f32) bool {
    return y + h >= sess_list.y and y <= sess_list.y + sess_list.h;
}

/// 세션 목록. **이 앱의 뿌리 화면이다**(UX §2.2). 지금 실을 수 있는 것은 **진짜 세션 하나**뿐이라
/// 한 줄이다 — 목록을 채워 보이려고 없는 세션을 그리지 않는다(계약 §2.4 가 경고한 자리이고,
/// 실제로 그렇게 그린 탭 셋을 U3a 에서 걷어냈다). 서버 목록·연결 진단은 **서버가 0개**이므로
/// 만들지 않는다 — M3 가 "서버를 등록한다" 를 정하면 그때 선다.
///
/// **설정 입구가 여기다.** 하단 상시 바는 두 플랫폼 관례가 아니고(하단은 이동 대상 자리다),
/// 키보드가 거의 늘 떠 있는 터미널에서 44px 를 영구히 쓴다. 관례대로 **부모 화면의 앱 바
/// 오른쪽**에 둔다.
/// 목록의 **전체 줄 수**. 스크린 리더가 「몇 분의 몇」을 말하려면 화면에 뜬 것이 아니라 **있는
/// 것 전부**를 세야 한다(계약 `Semantics.set_size` 가 가상화를 이유로 그렇게 적는다) — 목록은
/// 흐르므로 지금 보이는 줄만 세면 늘 창 크기가 나온다.
fn sessSetSize() u32 {
    return 2 + @as(u32, @intCast(control_row_count)); // 터미널 + 서버 + 원격 세션들
}

fn drawSessions(win: SetRect, tk: *const tokens.Tokens) void {
    push(.{ .x = @intFromFloat(win.x), .y = @intFromFloat(win.y), .w = @intFromFloat(win.w), .h = @intFromFloat(win.h) }, tk.get(.surface_bg), 0xFF, 0, 0);

    // ── 줄 하나: 지금 있는 세션. **48 이 아니라 56 이다** — 나중에 `cwd`·상태가 두 번째 줄로
    // 붙을 자리이고(M3), 그때 높이가 바뀌면 손가락이 겨눈 자리가 움직인다.
    const row_h: f32 = 56;
    // **헤더는 고정, 그 아래가 흐른다**(서버 목록·설정과 같은 자리). 헤더까지 흘리면 톱니가
    // 화면 밖으로 나가 설정에 못 들어간다.
    sess_list = .{ .x = win.x, .y = win.y + set_head_h + 1, .w = win.w, .h = win.h - set_head_h - 1 };
    sess_sa.clamp(@intFromFloat(@max(0, sess_max_scroll)));
    const top = sess_list.y - sessScroll();

    sess_row_rect = if (sessVisible(top, row_h)) .{ .x = win.x, .y = top, .w = win.w, .h = row_h } else .{};
    // **줄은 목록의 일원으로 읽힌다** — 「3 / 8」을 말할 수 있어야 어디쯤인지 안다. 집합은
    // `sessSetSize()` 가 세고, 번호는 화면에 놓인 차례 그대로다(터미널·서버·원격 세션들).
    noteA11yClipped(sess_row_rect, sess_list, .{
        .role = .list_item,
        .label = session_title,
        .position_in_set = 1,
        .set_size = sessSetSize(),
    });
    if (sess_row_rect.w > 0) {
        if (sess_pressed == .row) push(.{ .x = @intFromFloat(sess_row_rect.x), .y = @intFromFloat(sess_row_rect.y), .w = @intFromFloat(sess_row_rect.w), .h = @intFromFloat(sess_row_rect.h) }, tk.get(.tab_hover_bg), 0xFF, 0, 0);
        pushText(session_title, @intFromFloat(win.x + 16), @intFromFloat(top + (row_h - 17) / 2), 17, tk.get(.surface_fg));
        push(.{ .x = @intFromFloat(win.x), .y = @intFromFloat(top + row_h), .w = @intFromFloat(win.w), .h = 1 }, tk.get(.divider), 0xFF, 0, 0);
    }
    const servers_top = top + row_h + 1;
    drawServersEntry(win, tk, row_h, servers_top);
    const remote_h = drawRemoteSessions(win, tk, servers_top + row_h + 1);

    // **내용 높이는 그리면서 잰다.** 원격 줄 수는 매 프레임 달라지고(목록이 갱신된다) 메시지
    // 갈래는 줄 높이가 아니라 글줄이 정한다 — 미리 계산하면 그 지식이 두 자리에 산다.
    // 이번 프레임의 clamp 는 위에서 **직전 값**으로 했으므로, 목록이 줄어든 그 프레임 한 장만
    // 넘겨 그려질 수 있다(다음 프레임에 제자리). 늘어날 때는 어긋나지 않는다.
    const content = row_h + 1 + row_h + 1 + remote_h;
    sess_max_scroll = @max(0, content - sess_list.h);

    // **스크롤바.** 목록이 흐르게 된 순간 「얼마나 남았는지」가 화면에서 사라졌다 — 세션이 서른
    // 넘게 있으면 지금 어디쯤인지 알 길이 없다. 설정 화면과 **같은 규칙·같은 모양**을 쓴다
    // (3px, 최소 28px thumb) — 같은 손짓이 화면마다 다르게 굴면 사용자는 매번 시험해 봐야 한다.
    // 밀 수 있을 때만 그린다.
    sess_scrollbar_drawn = sess_max_scroll > 0;
    if (sess_scrollbar_drawn) {
        const thumb_h = @max(28.0, sess_list.h * (sess_list.h / content));
        const t = sessScroll() / sess_max_scroll;
        const bar_w: f32 = 3;
        push(.{
            .x = @intFromFloat(sess_list.x + sess_list.w - bar_w - 2),
            .y = @intFromFloat(sess_list.y + t * (sess_list.h - thumb_h)),
            .w = @intFromFloat(bar_w),
            .h = @intFromFloat(thumb_h),
        }, tk.get(.muted_fg), 0xB0, 1, 0);
    }

    // ── 헤더: 제목 + 오른쪽 톱니. **본문 «뒤» 에 그린다** — 목록이 흐르면 걸친 줄이 자기 y 에
    // 그려져 헤더 자리로 올라온다(사용자가 화면으로 잡았다: 첫 줄 글자가 「세션」 아래 물렸다).
    // 완전히 들어온 줄만 그리면 창 위에 **한 행짜리 빈 구멍**이 생기므로(UX §키바가 겪은 그것),
    // **걸친 것도 그리고 헤더가 그 위를 덮는다.** 그래서 헤더는 자기 배경을 갖는다.
    push(.{ .x = @intFromFloat(win.x), .y = @intFromFloat(win.y), .w = @intFromFloat(win.w), .h = @intFromFloat(set_head_h) }, tk.get(.surface_bg), 0xFF, 0, 0);
    pushText(maru.i18n.tIn(.ko, .mob_sessions), @intFromFloat(win.x + 16), @intFromFloat(win.y + (set_head_h - 20) / 2), 20, tk.get(.surface_fg));
    sess_gear_rect = .{ .x = win.x + win.w - set_head_h, .y = win.y, .w = set_head_h, .h = set_head_h };
    noteA11y(sess_gear_rect, .{ .role = .button, .label = maru.i18n.tIn(.ko, .mob_settings) });
    if (sess_pressed == .gear) push(.{ .x = @intFromFloat(sess_gear_rect.x), .y = @intFromFloat(sess_gear_rect.y), .w = @intFromFloat(sess_gear_rect.w), .h = @intFromFloat(sess_gear_rect.h) }, tk.get(.tab_hover_bg), 0xFF, 8, 0);
    if (reserveQuad()) {
        const rgb = tk.get(.surface_fg);
        quad_buf[quad_count] = .{
            .x = sess_gear_rect.x + (set_head_h - @as(f32, @floatFromInt(status_icon_px))) / 2,
            .y = sess_gear_rect.y + (set_head_h - @as(f32, @floatFromInt(status_icon_px))) / 2,
            .w = @floatFromInt(status_icon_px),
            .h = @floatFromInt(status_icon_px),
            .r = @as(f32, @floatFromInt(rgb.r)) / 255.0,
            .g = @as(f32, @floatFromInt(rgb.g)) / 255.0,
            .b = @as(f32, @floatFromInt(rgb.b)) / 255.0,
            .a = 1.0,
            .radius = 0,
            .kind = 2,
            .cell_x = 0,
            .cell_y = @intCast(gear_slot), // 아이콘 아틀라스의 줄 = `status_cps` 안의 자리
        };
        quad_count += 1;
    }
    push(.{ .x = @intFromFloat(win.x), .y = @intFromFloat(win.y + set_head_h), .w = @intFromFloat(win.w), .h = 1 }, tk.get(.divider), 0xFF, 0, 0);
}

/// **그 PC 의 세션들**(S10d-2). 서버 목록 아래에 붙는다 — 뜻이 다르다(하나는 붙을 수 있는 것,
/// 이것은 지금 그 기계에서 돌고 있는 것).
///
/// **"아직 모른다" 와 "없다" 를 가른다.** 같은 문구로 뭉치면 화면이 없는 사실을 말한다.
/// 원격 목록 자리에 **무엇을 그렸나**. 테스트가 이 값을 본다 — "값은 맞는데 닿는 자리가 틀린"
/// 부류를 잡으려면 판정이 **그리기 경로 안에서** 세워져야 한다(이 저장소가 그 모양의 결함을
/// 여러 번 겪었다).
pub const RemoteShown = enum { off, loading, none, rows };
var remote_shown: RemoteShown = .loading;
var remote_rows_drawn: usize = 0;

pub fn remoteSessionsShown() RemoteShown {
    return remote_shown;
}

/// 판정용 — 이번 프레임에 **「이미 본 세션」 표시**를 몇 줄에 그렸나(U2c).
var held_markers_drawn: usize = 0;

pub fn heldMarkersDrawn() usize {
    return held_markers_drawn;
}

pub fn remoteRowsDrawn() usize {
    return remote_rows_drawn;
}

/// 첫 세션 줄의 가운데(누르는 자리). 아직 안 그렸으면 `null`.
pub fn remoteRowCenter(index: usize) ?struct { x: f32, y: f32 } {
    if (index >= remote_rows_drawn) return null;
    return .{ .x = remote_row0.x + remote_row0.w / 2, .y = remote_row0.y + (remote_row0.h + 1) * @as(f32, @floatFromInt(index)) + remote_row0.h / 2 };
}

var remote_row0: SetRect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };

var remote_off_msg: [160]u8 = undefined;
var remote_off_msg_len: usize = 0;

/// 축이 꺼졌을 때 **화면에 실제로 그린 문구**. 판정용.
pub fn remoteOffMessage() []const u8 {
    return remote_off_msg[0..remote_off_msg_len];
}

/// 그린 **내용 높이**를 돌려준다 — 부르는 쪽이 그것으로 스크롤 상한을 잡는다.
fn drawRemoteSessions(win: SetRect, tk: *const tokens.Tokens, top: f32) f32 {
    // **여는 판정은 그리는 자리에서 한다.** 화면 전환은 여러 경로로 일어나므로 그 전부에
    // 갈고리를 달면 하나를 빠뜨린다 — 여기는 목록을 실제로 그리는 유일한 자리다.
    noteControlScreen(true);
    const row_h: f32 = 56;
    var y = top;
    remote_rows_drawn = 0;
    held_markers_drawn = 0;

    // **연결이 없으면 컨트롤 축의 이유를 말하지 않는다.** 축은 그 연결 위에 서는 것이라,
    // 연결이 사라지면 남아 있는 사유는 **그 연결이 죽으며 난 잔해**이지 지금의 사실이 아니다.
    //
    // 기기에서 이것이 물었다: 끊기를 누르자 채널도 함께 죽었는데, 그 종료 코드가 127 로 잡혀
    // 목록이 **그 기계에 maru 가 없다 — 서버 설정에 maru 경로를 적는다** 고 했다. 서버에는
    // maru 가 멀쩡히 있었고 사용자가 고칠 것은 아무것도 없었다. **틀린 안내는 침묵보다 나쁘다.**
    //
    // 연결 상태는 터미널 축의 사실이고 이미 사람 말로 바꾸는 자리가 있다 — 그것을 그대로 쓴다
    // (같은 사실을 두 곳에서 말하면 갈린다).
    if (conn_state != 11) { // MARU_SSH_STATE_READY 가 아니면 축이 설 자리가 없다
        const msg = connectionMessage() orelse maru.i18n.tIn(.ko, .mob_sessions_loading);
        _ = pushTextWrapped(msg, @intFromFloat(win.x + 16), @intFromFloat(y + 10), @as(i32, @intFromFloat(win.w - 32)), 15, tk.get(.muted_fg));
        remote_off_msg_len = @min(msg.len, remote_off_msg.len);
        @memcpy(remote_off_msg[0..remote_off_msg_len], msg[0..remote_off_msg_len]);
        remote_shown = .off;
        return row_h;
    }

    if (control_client.state == .off) {
        // 껐다 — **왜 껐는지**를 말한다. 사용자가 고칠 자리가 이유마다 다르다.
        var failed_buf: [128]u8 = undefined;
        const msg: []const u8 = switch (control_client.off_reason) {
            .hello_timeout => maru.i18n.tIn(.ko, .mob_control_off_timeout),
            .too_much_noise => maru.i18n.tIn(.ko, .mob_control_off_noise),
            .protocol_mismatch => maru.i18n.tIn(.ko, .mob_control_off_protocol),
            .frame_too_large => maru.i18n.tIn(.ko, .mob_control_off_frame),
            .open_failed => maru.i18n.tIn(.ko, .mob_control_off_open),
            // 127 은 셸이 "그런 명령이 없다" 로 쓰는 값이다(계약 §4a) — 그 자리는 경로다.
            .command_failed => if (control_client.exit_status == 127)
                maru.i18n.tIn(.ko, .mob_control_off_missing)
            else
                std.fmt.bufPrint(&failed_buf, "{s} ({d})", .{
                    maru.i18n.tIn(.ko, .mob_control_off_failed),
                    control_client.exit_status,
                }) catch maru.i18n.tIn(.ko, .mob_control_off_failed),
            .none => maru.i18n.tIn(.ko, .mob_sessions_none),
        };
        // **접어 그린다** — 축이 꺼진 이유는 무엇을 고치라는 말이라 잘리면 쓸모가 없다.
        // 이 자리는 메시지를 그리고 바로 돌아가므로(아래 세션 행이 안 그려진다) 줄이 늘어도
        // 겹칠 것이 없다.
        _ = pushTextWrapped(msg, @intFromFloat(win.x + 16), @intFromFloat(y + 10), @as(i32, @intFromFloat(win.w - 32)), 15, tk.get(.muted_fg));
        // **그린 문구 그대로**를 남긴다 — 이유가 갈렸다는 것만 재면 사용자가 읽는 말이 뒤바뀌어도
        // 초록이다(같은 함정을 렌더 쪽에서 이미 겪었다).
        remote_off_msg_len = @min(msg.len, remote_off_msg.len);
        @memcpy(remote_off_msg[0..remote_off_msg_len], msg[0..remote_off_msg_len]);
        remote_shown = .off;
        return row_h;
    }

    if (!control_listed) {
        // 아직 안 받았다. **비어 있다고 말하지 않는다.**
        pushText(maru.i18n.tIn(.ko, .mob_sessions_loading), @intFromFloat(win.x + 16), @intFromFloat(y + (row_h - 15) / 2), 15, tk.get(.muted_fg));
        remote_shown = .loading;
        return row_h;
    }

    if (control_row_count == 0) {
        pushText(maru.i18n.tIn(.ko, .mob_sessions_none), @intFromFloat(win.x + 16), @intFromFloat(y + (row_h - 15) / 2), 15, tk.get(.muted_fg));
        remote_shown = .none;
        return row_h;
    }

    remote_shown = .rows;
    remote_row0 = .{ .x = win.x, .y = top, .w = win.w, .h = row_h };
    for (control_rows[0..control_row_count]) |*row| {
        // **안 보이는 줄은 안 그린다 — 그래도 «센다».** 예전에는 창을 넘는 순간 `return` 해서
        // 그 아래 세션이 통째로 사라졌다(맥에 탭이 열둘쯤 넘으면 닿을 수가 없었다). 지금은
        // 목록이 흐르므로 위로 지나간 줄도 아래로 남은 줄도 높이에 들어가야 상한이 맞는다.
        if (sessVisible(y, row_h)) drawSessionRow(win, tk, row, y, row_h, remote_rows_drawn);
        // **센 것은 «있는 줄» 이지 그린 줄이 아니다.** 이 수는 히트 판정(`remoteRowAt`)과
        // 판정자가 쓰는데, 화면 밖 줄을 빼면 스크롤한 뒤 인덱스가 어긋난다.
        remote_rows_drawn += 1;
        y += row_h + 1;
    }
    return y - top;
}

/// 둘째 줄에 조각을 잇는다. **자리가 모자라면 그 조각을 통째로 생략한다** — 반쯤 그린 값은
/// 사용자가 값으로 읽는다.
fn appendPart(buf: []u8, len: *usize, part: []const u8) void {
    if (part.len == 0) return;
    const sep: []const u8 = if (len.* > 0) "  " else "";
    if (len.* + sep.len + part.len > buf.len) return;
    @memcpy(buf[len.*..][0..sep.len], sep);
    len.* += sep.len;
    @memcpy(buf[len.*..][0..part.len], part);
    len.* += part.len;
}

fn drawSessionRow(win: SetRect, tk: *const tokens.Tokens, row: *const SessionRow, y: f32, row_h: f32, index: usize) void {
    // 초점 있는 세션은 왼쪽에 띠 하나. **글자만으로 표시하면 목록에서 안 보인다.**
    if (row.focused) push(.{ .x = @intFromFloat(win.x), .y = @intFromFloat(y), .w = 3, .h = @intFromFloat(row_h) }, tk.get(.accent_bar), 0xFF, 0, 0);

    const title = if (row.title_len > 0) row.title[0..row.title_len] else row.cwd[0..row.cwd_len];
    pushText(title, @intFromFloat(win.x + 16), @intFromFloat(y + 8), 17, tk.get(.surface_fg));

    // 둘째 줄: `cwd` · git · agent. **한 줄에 이어 붙이되 있는 것만** 적는다.
    //
    // **조용한 `catch` 를 안 쓴다**(계약 §5). 자리가 모자라면 그 조각을 **통째로 생략**한다 —
    // 잘린 글자를 그리면 사용자는 그것을 값으로 읽는다.
    var line: [256]u8 = undefined;
    var len: usize = 0;
    if (row.title_len > 0) appendPart(&line, &len, row.cwd[0..row.cwd_len]);
    appendPart(&line, &len, row.git[0..row.git_len]);
    appendPart(&line, &len, row.agent[0..row.agent_len]);
    const sub = line[0..len];
    if (sub.len > 0) pushText(sub, @intFromFloat(win.x + 16), @intFromFloat(y + 30), 13, tk.get(.muted_fg));

    // **읽는 것도 여기서 낸다.** 이름은 줄의 제목(사용자 데이터라 번역하지 않는다), 값은 둘째
    // 줄(cwd·git·agent) 그대로다 — 이름에 이어 붙이면 값만 바뀔 때 이름이 바뀐 것으로 읽힌다.
    //
    // **「이미 본 세션」은 눈에 점 하나로 말한다**(U2c). 눈으로 보는 것과 같은 사실을 스크린
    // 리더도 들어야 하므로 값 끝에 문구로 잇는다 — 점은 색이라 읽히지 않는다.
    var read: [320]u8 = undefined;
    var read_len: usize = 0;
    appendPart(&read, &read_len, sub);
    if (row.has_runtime and holdsSession(row.runtime_id)) {
        appendPart(&read, &read_len, maru.i18n.tIn(.ko, .mob_a11y_held));
    }
    // **이름이 비면 그 줄은 사라진다.** 제목도 `cwd` 도 없는 세션이 있을 수 있는데(둘 다 원격이
    // 주는 값이다), 빈 이름을 내면 host 가 요소를 아예 안 만들어 **눌리는 줄이 안 읽힌다**.
    // 화면에는 빈 줄로 보이지만 누르면 열리므로, 읽는 쪽에도 그만큼은 있어야 한다
    // (적대적 검증 11회차 — 「이름 없는 줄」은 목록의 정상 상태다).
    const read_label = if (title.len > 0) title else maru.i18n.tIn(.ko, .mob_a11y_unnamed);
    noteA11yClipped(.{ .x = win.x, .y = y, .w = win.w, .h = row_h }, sess_list, .{
        .role = .list_item,
        .label = read_label,
        .value = read[0..read_len],
        // 초점 있는 세션이 **고른 상태**다 — 왼쪽 띠가 눈에 말하는 그것이다.
        .selected = row.focused,
        .position_in_set = @intCast(index + 3), // 터미널·서버 다음이 원격 세션들이다
        .set_size = sessSetSize(),
    });

    // **이미 본 세션은 그렇다고 말한다**(U2c). 전환을 「덮개」로 정했으니(계획 U0) 고르는 자리는
    // 이 목록 하나뿐이다 — 어느 줄이 이미 화면을 갖고 있는지 목록이 말하지 않으면, 사용자는 그
    // 왕복이 싼지 비싼지 모른 채 누른다. **오른쪽 끝의 작은 점** 하나다: 둘째 줄의 값(cwd·git·
    // agent)과 경쟁하지 않고, 글자가 아니라서 폭이 좁아도 안 잘린다.
    if (row.has_runtime and holdsSession(row.runtime_id)) {
        const dot: f32 = 6;
        push(.{
            .x = @intFromFloat(win.x + win.w - 16 - dot),
            .y = @intFromFloat(y + (row_h - dot) / 2),
            .w = @intFromFloat(dot),
            .h = @intFromFloat(dot),
        }, tk.get(.accent_bar), 0xFF, @intFromFloat(dot / 2), 0);
        held_markers_drawn += 1;
    }

    push(.{ .x = @intFromFloat(win.x), .y = @intFromFloat(y + row_h), .w = @intFromFloat(win.w), .h = 1 }, tk.get(.divider), 0xFF, 0, 0);
}

/// 원격 세션의 화면. **조립기가 든 run 을 셀로 편다** — 코어 격자를 거치지 않는다(그 바이트는
/// ANSI 가 아니라 이미 셀이다, §4a).
///
/// **읽기 전용이다**(§8 — `--stream` 은 observer). 키보드를 안 올리고 입력도 안 받는다: 뜨는데
/// 안 들어가면 사용자가 쳐 놓고 잃는다.
fn drawRemoteScreen(win: SetRect, tk: *const tokens.Tokens) void {
    // **먼저 창을 덮는다.** 밀린 화면은 터미널 **위에** 서고(위 `switch (screenTop())` 주석),
    // 터미널 chrome 은 그 아래에 이미 그려져 있다 — 목록·설정처럼 창 전체를 칠하지 않으면
    // 그 아래가 그대로 비친다. 실기에서 그것이 두 가지로 보였다(실측, 시뮬레이터 캡처):
    // 원격 화면의 글자가 **폰 자기 터미널 글자와 겹쳐** 찍혔고(빈칸은 안 그리므로 그 자리에
    // 아래 글자가 남는다), 읽기 전용인데 **보조 키바가 그대로 떠** 있었다. 둘 다 원인이 하나다.
    push(.{ .x = @intFromFloat(win.x), .y = @intFromFloat(win.y), .w = @intFromFloat(win.w), .h = @intFromFloat(win.h) }, tk.get(.surface_bg), 0xFF, 0, 0);

    // **나갈 자리를 만든다**(U2). 전환을 「덮개」로 정했으니(계획 U0) 여기서 목록으로 돌아가는
    // 것이 곧 세션을 바꾸는 길이다. 예전에는 제목만 그리고 **누를 자리를 안 만들어**, 이 화면에
    // 들어오면 앱을 죽이는 것 말고는 나갈 수 없었다(실기 2026-09-04 — 시뮬레이터에서 헤더 여러
    // 지점을 눌러도 아무 일이 없었다). 자리와 크기는 터미널 바의 뒤로가기와 같다(§5.1 — 44 이상).
    remote_back_rect = .{ .x = win.x, .y = win.y, .w = set_head_h, .h = set_head_h };
    // **나갈 길이 없으면 갇힌다.** 이 화면은 읽기 전용이라 누를 것이 뒤로가기 하나뿐인데, 그것을
    // 안 내면 스크린 리더 사용자는 들어온 뒤 **아무것도 못 한다**(적대적 검증 7회차).
    noteA11y(remote_back_rect, .{ .role = .button, .label = maru.i18n.tIn(.ko, .mob_a11y_back) });

    // 상단 바 — 어디서 왔는지와 무엇을 보는지.
    push(.{ .x = @intFromFloat(win.x), .y = @intFromFloat(win.y), .w = @intFromFloat(win.w), .h = @intFromFloat(set_head_h) }, tk.get(.surface_bg), 0xFF, 0, 0);
    // **화살표를 그린다** — 누를 자리만 만들고 안 그리면 「없는 것」과 구별되지 않는다
    // (실기 2026-09-04 — 히트는 되는데 화면에 아무 표시가 없어 여기가 눌린다는 것을 알 길이
    // 없었다). 자리·크기·글리프 모두 설정 화면과 같다(§5.1).
    if (reserveQuad()) {
        const arrow_rgb = tk.get(.surface_fg);
        quad_buf[quad_count] = .{
            .x = remote_back_rect.x + (set_head_h - 22) / 2,
            .y = remote_back_rect.y + (set_head_h - 22) / 2,
            .w = 22,
            .h = 22,
            .r = @as(f32, @floatFromInt(arrow_rgb.r)) / 255.0,
            .g = @as(f32, @floatFromInt(arrow_rgb.g)) / 255.0,
            .b = @as(f32, @floatFromInt(arrow_rgb.b)) / 255.0,
            .a = 1.0,
            .radius = 0,
            .kind = 2,
            .cell_x = 0,
            .cell_y = arrow_slot_base + 2, // arrow_left
        };
        quad_count += 1;
    }
    pushText(maru.i18n.tIn(.ko, .mob_remote_screen_title), @intFromFloat(win.x + set_head_h), @intFromFloat(win.y + (set_head_h - 20) / 2), 20, tk.get(.surface_fg));
    // **보는 중이라고 말한다** — 조종하는 화면과 헷갈리면 안 친 글자를 찾게 된다.
    const badge = maru.i18n.tIn(.ko, .mob_remote_screen_readonly);
    pushText(badge, @intFromFloat(win.x + win.w - 16 - @as(f32, @floatFromInt(textWidth(badge, 13)))), @intFromFloat(win.y + (set_head_h - 13) / 2), 13, tk.get(.muted_fg));
    push(.{ .x = @intFromFloat(win.x), .y = @intFromFloat(win.y + set_head_h), .w = @intFromFloat(win.w), .h = 1 }, tk.get(.divider), 0xFF, 0, 0);
    const scr = remote_screen orelse {
        // 조립기가 없는 이유가 둘이다. **아직 안 왔다**(바이트가 오면 생긴다)와 **연결이 끊겼다**
        // (`control_reset` 이 놓았다)를 가르지 않으면, 끊긴 화면에 "받는 중" 이 영원히 떠서
        // 사용자가 계속 기다린다. 그 판정은 **아직도 그 화면을 원하는가**로 한다.
        const still_wanted = control_want == .screen;
        const msg = if (still_wanted)
            maru.i18n.tIn(.ko, .mob_remote_screen_waiting)
        else
            maru.i18n.tIn(.ko, .mob_remote_screen_off);
        pushText(msg, @intFromFloat(win.x + 16), @intFromFloat(win.y + set_head_h + 20), 15, tk.get(.muted_fg));
        remote_screen_shown = if (still_wanted) .waiting else .off;
        return;
    };
    switch (scr.state) {
        .waiting_first => {
            // **아직 안 왔다고 말한다** — 빈 화면은 "세션이 비었다" 로 읽힌다.
            pushText(maru.i18n.tIn(.ko, .mob_remote_screen_waiting), @intFromFloat(win.x + 16), @intFromFloat(win.y + set_head_h + 20), 15, tk.get(.muted_fg));
            // **기다리는 중이라는 사실도 읽힌다** — 안 그러면 빈 화면과 구별이 안 된다.
            noteA11y(
                .{ .x = win.x + 16, .y = win.y + set_head_h + 20, .w = win.w - 32, .h = 24 },
                .{ .role = .text, .label = maru.i18n.tIn(.ko, .mob_remote_screen_waiting) },
            );
            remote_screen_shown = .waiting;
            return;
        },
        .off => {
            pushText(maru.i18n.tIn(.ko, .mob_remote_screen_off), @intFromFloat(win.x + 16), @intFromFloat(win.y + set_head_h + 20), 15, tk.get(.muted_fg));
            noteA11y(
                .{ .x = win.x + 16, .y = win.y + set_head_h + 20, .w = win.w - 32, .h = 24 },
                .{ .role = .text, .label = maru.i18n.tIn(.ko, .mob_remote_screen_off) },
            );
            remote_screen_shown = .off;
            return;
        },
        .ready => {},
    }

    // 셀 기하는 본문과 같은 규칙이다(§글리프 기하) — 여기서 따로 세면 본문과 갈린다.
    const line_h: i32 = lineHeight();
    const scale = @as(f32, @floatFromInt(line_h)) / @as(f32, @floatFromInt(atlas_cell_h));
    const cell_w: i32 = @max(1, @as(i32, @intFromFloat(@as(f32, @floatFromInt(atlas_cell_w)) * scale * 0.5)));
    const ox = @as(i32, @intFromFloat(win.x));
    const oy = @as(i32, @intFromFloat(win.y + set_head_h + 1));
    const rows_fit: u16 = @intCast(@max(0, @divTrunc(@as(i32, @intFromFloat(win.h - set_head_h - 1)), line_h)));
    const cols_fit: u16 = @intCast(@max(0, @divTrunc(@as(i32, @intFromFloat(win.w)), cell_w)));
    // **여기서 알린다.** 이 값이 곧 우리가 그릴 수 있는 격자이고, 회전·폰트 변경이 이 자리를
    // 다시 지나간다 — 별도 갈고리를 달면 그중 하나를 빠뜨린다.
    declareViewport(cols_fit, rows_fit);

    // **아래를 기준으로 그린다**(S11-6). 원격 화면이 창보다 높으면 위부터 그리는 것은 **프롬프트가
    // 있는 아래쪽을 버리는** 것이다 — 사용자가 방금 친 명령의 결과를 못 본다. 터미널은 최신 출력이
    // 아래에 있으므로, 넘치면 **오래된 위쪽**을 버린다.
    //
    // 세로를 이렇게 풀기 때문에 세션 크기 조정은 **열만** 한다(맥 창이 높을 때 행까지 맞추면
    // 그쪽이 스무 행 넘게 잃는다 — 계약 참조).
    // **판정용 값은 프레임마다 비운다.** 안 비우면 아무것도 안 그린 프레임에서 **지난 프레임의
    // 값**이 읽혀 판정자가 거짓으로 통과한다(적대적 검증 8회차 — 「그린 결과를 남긴다」는 말은
    // 「이번에 그린 것」이어야 뜻이 있다).
    remote_last_src_row = 0;
    remote_last_fg = null;
    remote_last_bg = null;
    remote_cursor_drawn = false;

    const total_rows = scr.rowCount();
    const first_row: u16 = if (total_rows > rows_fit) total_rows - rows_fit else 0;
    remote_first_row = first_row;

    var drawn: usize = 0;
    var row: u16 = 0;
    while (row < rows_fit) : (row += 1) {
        const src_row = first_row + row;
        if (src_row >= total_rows) break;
        const runs = scr.rowRuns(src_row);
        if (runs.len == 0) continue;
        var col: i32 = 0;
        for (runs) |r| {
            // **run 이 든 색을 쓴다.** 옛 판은 전부 `surface_fg` 한 색이라 색이 있는 화면이
            // 통째로 흑백으로 보였다 — host 는 색을 이미 실어 보내고 있었다(`Run.fg`, 태그드
            // intent). 푸는 규칙은 폰의 로컬 터미널이 쓰는 `resolveColor` 와 **같은 것**을 쓴다.
            // **반전(inverse)은 두 색을 맞바꾼다.** 그걸 안 보면 선택·강조가 통째로 안 보인다 —
            // 색을 실어 보내면서 그 플래그만 버리면 화면이 거짓말을 한다.
            const inverse = (r.style_flags & stream_flags.inverse) != 0;
            const fg_intent = remoteColorIntent(if (inverse) r.bg else r.fg);
            const bg_intent = remoteColorIntent(if (inverse) r.fg else r.bg);
            const fg = resolveColor(fg_intent, if (inverse) tk.get(.surface_bg) else tk.get(.surface_fg));
            // **푼 색을 남긴다**(판정용). 헤드리스에서는 글리프가 안 구워져 quad 가 안 나오므로
            // 그린 픽셀로는 못 잰다 — 대신 **제품 경로가 실제로 계산한 값**을 본다(불리언 깃발이
            // 아니라 값이라, 옛 한 색으로 되돌리는 변이가 이 값을 바꾼다).

            // **배경은 run 단위로 한 번 칠한다** — 셀마다 칠하면 같은 색 quad 가 run 길이만큼
            // 늘어난다. 기본 배경이면 안 칠한다: 창은 이미 `surface_bg` 로 덮여 있고, 안 칠하면
            // 그만큼 quad 가 준다(빈칸 글자를 안 그리는 것과 같은 규율).
            const bg_is_default = !inverse and bg_intent == .default;
            if (!bg_is_default) {
                const run_cells: i32 = @intCast(r.count * @max(1, r.width));
                const bx = ox + col * cell_w;
                const bw = @min(run_cells * cell_w, @as(i32, @intFromFloat(win.x + win.w)) - bx);
                if (bw > 0) {
                    const bg = resolveColor(bg_intent, if (inverse) tk.get(.surface_fg) else tk.get(.surface_bg));
                    push(.{ .x = bx, .y = oy + @as(i32, row) * line_h, .w = @intCast(bw), .h = @intCast(line_h) }, bg, 0xFF, 0, 0);
                    remote_last_bg = bg;
                }
            }
            var k: u32 = 0;
            while (k < r.count) : (k += 1) {
                // 화면 밖으로 나가면 그만 그린다. **팬은 후속이 아니라 «없어진 일» 이다** —
                // 뷰포트 선언(S11-6)이 세션을 이 격자에 맞추므로 넘칠 것이 없다. 이 줄은 그
                // 선언이 아직 안 닿았거나 host 가 못 줄인 동안의 **방어**로 남는다.
                if (ox + col * cell_w > @as(i32, @intFromFloat(win.x + win.w))) break;
                if (r.grapheme.len > 0 and r.grapheme[0] != ' ') {
                    pushText(r.grapheme, ox + col * cell_w, oy + @as(i32, row) * line_h, line_h, fg);
                    remote_last_fg = fg;
                    // **어느 «원본» 행을 그렸는지 남긴다**(판정용). `first_row` 가 맞다는 것만으로는
                    // 부족하다 — 그 값을 쓰지 않고 위에서 가져오는 판이 통과한다(적대적 검증 4회차에서
                    // 그 변이가 실제로 살아남았다).
                    remote_last_src_row = src_row;
                    drawn += 1;
                }
                col += @intCast(@max(1, r.width));
            }
        }
    }

    // **커서를 그린다.** 조립기가 이미 들고 있는데 폰이 안 꺼내 써서 원격 화면에는 커서가 아예
    // 없었고, 보는 사람은 그 세션이 어디에 서 있는지 알 수 없었다. 읽기 전용이라 깜빡이지
    // 않는다 — 깜빡임은 조종하는 화면의 신호고, 여기서 흉내 내면 칠 수 있다고 읽힌다.
    const cur = scr.cursor();
    // 커서도 **같은 기준**으로 옮긴다 — 안 옮기면 글자는 아래를 보여 주면서 커서만 위쪽 좌표에
    // 서서 엉뚱한 자리를 가리킨다.
    // **행이 없으면 커서도 없다.** `Cursor.visible` 의 기본값이 `true` 라, `rows = 0` 인 화면에서는
    // 글자를 하나도 안 그리면서 **커서만 떠 있게** 된다(적대적 검증 2회차).
    if (total_rows > 0 and cur.visible and cur.row >= first_row and cur.row - first_row < rows_fit) {
        const cur_row: u16 = cur.row - first_row;
        const cx = ox + @as(i32, cur.col) * cell_w;
        if (cx <= @as(i32, @intFromFloat(win.x + win.w))) {
            push(.{ .x = cx, .y = oy + @as(i32, cur_row) * line_h, .w = @intCast(cell_w), .h = @intCast(line_h) }, tk.get(.surface_fg), 0x66, 0, 0);
            remote_cursor_drawn = true;
        } else remote_cursor_drawn = false;
    } else remote_cursor_drawn = false;

    remote_screen_shown = if (drawn > 0) .cells else .blank;
}

/// 마지막으로 그린 원격 글자의 **푼 색**(판정용). `null` 이면 글자를 안 그렸다.
var remote_last_fg: ?color.Rgb = null;

pub fn remoteLastFg() ?color.Rgb {
    return remote_last_fg;
}

/// 마지막으로 그린 글자의 **원본 행**(판정용). 「아래를 그렸나」는 이 값으로만 판정된다.
var remote_last_src_row: u16 = 0;

pub fn remoteLastSrcRow() u16 {
    return remote_last_src_row;
}

/// 마지막으로 그린 원격 화면의 **첫 행 인덱스**(판정용). 창보다 높은 화면에서 아래를 기준으로
/// 그렸는지는 이 값으로만 보인다 — 그린 픽셀로는 「무엇이 안 그려졌나」를 못 잰다.
var remote_first_row: u16 = 0;

pub fn remoteFirstRow() u16 {
    return remote_first_row;
}

/// 마지막으로 칠한 원격 **배경색**(판정용). `null` 이면 기본 배경뿐이라 안 칠했다.
var remote_last_bg: ?color.Rgb = null;

pub fn remoteLastBg() ?color.Rgb {
    return remote_last_bg;
}

/// 원격 커서를 실제로 그렸나(판정용). 상태만 재면 «보인다» 고 해 놓고 안 그려도 초록이다.
var remote_cursor_drawn: bool = false;

pub fn remoteCursorDrawn() bool {
    return remote_cursor_drawn;
}

/// 화면 stream 의 태그드 색 의도를 코어 `Color` 로 푼다.
///
/// **매핑은 경계마다 각자 한다** — `screen_stream` 이 스스로 「terminal.Color 를 모른다: 태그 값만
/// SSOT 로 정의하고 매핑은 host/client 경계가 각자 한다」고 적어 두었다. macOS 재접속 렌더에도
/// 같은 모양의 짝(`session_host/remote_screen.unpackColorIntent`)이 있다.
fn remoteColorIntent(v: u32) terminal.types.Color {
    return switch (maru.session.screen_stream.decodeColor(v)) {
        .default => .default,
        .indexed => |index| .{ .indexed = index },
        .rgb => |c| .{ .rgb = .{ .r = c.r, .g = c.g, .b = c.b } },
    };
}

/// 원격 화면이 무엇을 보였나(판정용). 그린 결과를 남긴다 — 상태만 재면 화면이 비어도 초록이다.
pub const RemoteScreenShown = enum { waiting, off, blank, cells };
var remote_screen_shown: RemoteScreenShown = .waiting;
pub fn remoteScreenShown() RemoteScreenShown {
    return remote_screen_shown;
}

/// 세션 화면 아래에 붙는 **서버 목록 입구**. 화면을 나눠 그리는 이유는 하나다 — 세션 줄과
/// 이 줄은 뜻이 다르다(하나는 지금 보고 있는 것, 하나는 붙을 수 있는 것).
/// `y` 는 **흐르는 자리**다 — 세션 목록이 스크롤되므로 그리는 쪽이 정해서 준다(예전에는 위
/// 줄의 rect 에서 유도했는데, 그 줄이 화면 밖으로 나가면 rect 가 비어 여기가 0 을 기준으로 잡았다).
fn drawServersEntry(win: SetRect, tk: *const tokens.Tokens, row_h: f32, y: f32) void {
    // ── 서버 목록 입구. **개수를 함께 적는다** — 0 이면 들어가서야 비었음을 알게 되고, 그
    // 화면이 무엇을 담는지도 안 보인다.
    if (!sessVisible(y, row_h)) {
        sess_servers_rect = .{}; // 안 보이면 rect 를 안 남긴다 — 남기면 화면 밖인데 눌린다
        return;
    }
    sess_servers_rect = .{ .x = win.x, .y = y, .w = win.w, .h = row_h };
    if (sess_pressed == .servers) push(.{ .x = @intFromFloat(sess_servers_rect.x), .y = @intFromFloat(sess_servers_rect.y), .w = @intFromFloat(sess_servers_rect.w), .h = @intFromFloat(sess_servers_rect.h) }, tk.get(.tab_hover_bg), 0xFF, 0, 0);
    pushText(maru.i18n.tIn(.ko, .mob_servers), @intFromFloat(sess_servers_rect.x + 16), @intFromFloat(sess_servers_rect.y + (row_h - 17) / 2), 17, tk.get(.surface_fg));
    var cnt: [8]u8 = undefined;
    const cnt_text = std.fmt.bufPrint(&cnt, "{d}", .{servers().len}) catch "?";
    // **개수는 이름이 아니라 값이다.** 스크린 리더는 이름과 값을 다른 시점에 읽고, 값만 바뀌었을
    // 때 이름을 다시 안 읽는다 — 「서버 3」으로 이어 붙이면 3 이 바뀔 때마다 이름이 바뀐 것이 된다.
    noteA11yClipped(sess_servers_rect, sess_list, .{
        .role = .list_item,
        .label = maru.i18n.tIn(.ko, .mob_servers),
        .value = cnt_text,
        .position_in_set = 2,
        .set_size = sessSetSize(),
    });
    pushText(cnt_text, @intFromFloat(sess_servers_rect.x + sess_servers_rect.w - 16 - @as(f32, @floatFromInt(textWidth(cnt_text, 15)))), @intFromFloat(sess_servers_rect.y + (row_h - 15) / 2), 15, tk.get(.muted_fg));
    push(.{ .x = @intFromFloat(sess_servers_rect.x), .y = @intFromFloat(sess_servers_rect.y + row_h), .w = @intFromFloat(sess_servers_rect.w), .h = 1 }, tk.get(.divider), 0xFF, 0, 0);
}

// ── 서버 편집 화면 (S9b-2b-2) ───────────────────────────────────────────────

/// 편집 화면의 칸. **순서가 곧 화면 순서**다(주소를 먼저 묻는 것이 아니라, 사람이 부르는
/// 이름부터 묻는다 — 목록에 보이는 것이 그것이다).
const ServerField = enum { name, host, port, user, fingerprint };
const server_field_n = @typeInfo(ServerField).@"enum".fields.len;

/// 편집 중인 서버의 **사본**. config 의 문자열은 파싱 arena 것이라 다음 읽기에서 사라지므로,
/// 화면이 들고 있으려면 자기 자리에 복사해야 한다. 저장할 때 이 값으로 목록을 다시 적는다.
const ServerDraft = struct {
    name: [48]u8 = undefined,
    name_len: usize = 0,
    host: [64]u8 = undefined,
    host_len: usize = 0,
    user: [32]u8 = undefined,
    user_len: usize = 0,
    fingerprint: [80]u8 = undefined,
    fingerprint_len: usize = 0,
    port: u16 = 22,

    fn text(self: *const ServerDraft, f: ServerField) []const u8 {
        return switch (f) {
            .name => self.name[0..self.name_len],
            .host => self.host[0..self.host_len],
            .user => self.user[0..self.user_len],
            .fingerprint => self.fingerprint[0..self.fingerprint_len],
            .port => "", // 숫자다 — `port` 를 직접 본다
        };
    }

    /// 그 칸에 값을 넣는다. **자리보다 길면 안 넣고 알린다** — 잘라 넣으면 지문이 반쪽이 되어
    /// 접속이 "호스트키가 다르다" 로 실패한다(원인과 증상이 멀어지는 자리다).
    ///
    /// 지금 편집 버퍼가 64바이트라 **이름·사용자만 이 한계에 실제로 닿는다**(주소는 딱 64,
    /// 지문은 80). 그래도 칸마다 재는 이유는 이 함수가 그 버퍼에 묶여 있지 않아서다 — 값이
    /// 다른 데서(가져오기·원격 등록) 올 때 길이를 아는 쪽은 여기뿐이다.
    fn set(self: *ServerDraft, f: ServerField, value: []const u8) bool {
        switch (f) {
            .name => {
                if (value.len > self.name.len) return false;
                @memcpy(self.name[0..value.len], value);
                self.name_len = value.len;
            },
            .host => {
                if (value.len > self.host.len) return false;
                @memcpy(self.host[0..value.len], value);
                self.host_len = value.len;
            },
            .user => {
                if (value.len > self.user.len) return false;
                @memcpy(self.user[0..value.len], value);
                self.user_len = value.len;
            },
            .fingerprint => {
                if (value.len > self.fingerprint.len) return false;
                @memcpy(self.fingerprint[0..value.len], value);
                self.fingerprint_len = value.len;
            },
            .port => unreachable, // 숫자는 `setPort` 가 받는다 — 파싱은 뜻을 아는 자리에서 한다
        }
        return true;
    }

    /// 포트를 넣는다. **0 은 못 쓴다** — 붙을 수 없는 포트라 그대로 오류다.
    fn setPort(self: *ServerDraft, v: u16) bool {
        if (v == 0) return false;
        self.port = v;
        return true;
    }

    fn toServer(self: *const ServerDraft) mobile_config.Server {
        return .{
            .name = self.name[0..self.name_len],
            .host = self.host[0..self.host_len],
            .user = self.user[0..self.user_len],
            .fingerprint = self.fingerprint[0..self.fingerprint_len],
            .port = self.port,
        };
    }
};

/// 오른쪽 값이 `max_w` 를 넘으면 **앞을 자르고 `…` 를 붙인다**. 안 자르면 라벨 위에 겹쳐
/// 그려져 둘 다 못 읽는다(지문이 그렇다 — 화면으로 잡았다).
///
/// **앞을 자르는 이유**: 지문·주소는 뒤쪽이 서로 다르다. 뒤를 자르면 `SHA256:` 만 남아 어느
/// 서버인지 구별이 안 된다.
fn fitRight(text: []const u8, max_w: i32, px: i32, buf: []u8) []const u8 {
    if (textWidth(text, px) <= max_w) return text;
    const ell = "\u{2026}";
    const ell_w = textWidth(ell, px);
    var start = text.len;
    var w: i32 = ell_w;
    while (start > 0) {
        var next = start - 1;
        while (next > 0 and (text[next] & 0xC0) == 0x80) next -= 1; // UTF-8 경계
        const piece_w = textWidth(text[next..start], px);
        if (w + piece_w > max_w) break;
        w += piece_w;
        start = next;
    }
    const tail = text[start..];
    if (ell.len + tail.len > buf.len) return tail;
    @memcpy(buf[0..ell.len], ell);
    @memcpy(buf[ell.len..][0..tail.len], tail);
    return buf[0 .. ell.len + tail.len];
}

/// 위 두 함수는 화면 안에서만 쓰지만 **판정은 밖에서 한다** — 화면 픽셀을 헤드리스에서 못
/// 보므로(아틀라스가 안 구워진다) 자르기 규칙만이라도 테스트가 직접 잰다.
pub fn fitRightForTest(text: []const u8, max_w: i32, px: i32, buf: []u8) []const u8 {
    return fitRight(text, max_w, px, buf);
}
pub fn textWidthForTest(text: []const u8, px: i32) i32 {
    return textWidth(text, px);
}

/// **이 기기의 공개키 한 줄**(`ssh-ed25519 ... maru`). 키는 host 가 들고(Keystore·파일) 브리지는
/// 보여 주기만 한다 — 이 층엔 OS 호출이 없다(§3). 없으면 빈 값이고 화면이 그렇게 말한다.
var pubkey_buf: [256]u8 = undefined;
var pubkey_len: usize = 0;
/// 방금 복사했다는 표시. **시간을 안 센다** — 화면을 떠나면 사라지는 한 프레임짜리 사실이라
/// 타이머를 두면 그 상태를 지우는 자리가 또 생긴다.
var pubkey_copied = false;

/// host 가 자기 키의 한 줄을 알린다(`maru_mobile_ssh_public_key_line` 이 만든 것).
pub export fn maru_mobile_set_public_key(ptr: [*]const u8, len: usize) void {
    if (len > pubkey_buf.len) {
        // **자르지 않는다** — 반쪽 공개키를 서버에 붙이면 조용히 안 먹는다.
        setLastError("public_key_too_long");
        pubkey_len = 0;
        return;
    }
    @memcpy(pubkey_buf[0..len], ptr[0..len]);
    pubkey_len = len;
}

/// 화면이 "복사했다" 를 보이고 있나(테스트·진단용). **라벨이 거짓말하면 사용자는 안 붙은 키를
/// 붙였다고 믿는다.**
pub fn publicKeyCopiedShown() bool {
    return pubkey_copied;
}

/// 지금 아는 공개키 한 줄(없으면 빈 슬라이스).
pub fn publicKeyLine() []const u8 {
    return pubkey_buf[0..pubkey_len];
}

var srv_draft: ServerDraft = .{};
/// 편집 중인 서버의 목록 번호. null 이면 **새로 만드는 중**이다(저장할 때 끝에 붙는다).
var srv_edit_index: ?usize = null;
var srv_edit_rects: [server_field_n + 3]SetRect = @splat(.{}); // 칸 다섯 + 공개키 + 저장 + 삭제
var srv_edit_pressed: ?usize = null;
var srv_edit_back_rect: SetRect = .{};
var srv_edit_back_pressed = false;
var srv_edit_press: gesture.Press = .{};

/// 그 서버를 편집 화면으로 연다(`null` 이면 새로 만든다).
fn openServerEdit(i: ?usize) void {
    srv_draft = .{};
    srv_edit_index = i;
    if (i) |idx| {
        const list = servers();
        if (idx < list.len) {
            const srv = list[idx];
            _ = srv_draft.set(.name, srv.name);
            _ = srv_draft.set(.host, srv.host);
            _ = srv_draft.set(.user, srv.user);
            _ = srv_draft.set(.fingerprint, srv.fingerprint);
            _ = srv_draft.setPort(srv.port);
        }
    }
    edit_target = .none;
    set_edit_len = 0;
    pubkey_copied = false; // 들어올 때마다 새로 — 지난번 표시가 남으면 거짓말이 된다
    navPush(.server_edit);
}

/// 지금 초안을 목록에 넣고 파일로 낸다. **저장은 목록 통째로 다시 적는 일**이다 — 값 하나만
/// 고치면 지우기와 번호 다시 매기기를 못 한다(config 계약 §4.3).
fn saveServerDraft() void {
    var list: [mobile_config.max_servers]mobile_config.Server = @splat(.{});
    const cur = servers();
    var n: usize = 0;
    for (cur) |srv| {
        if (n == list.len) break;
        list[n] = srv;
        n += 1;
    }
    const draft = srv_draft.toServer();
    if (srv_edit_index) |idx| {
        if (idx >= n) return;
        list[idx] = draft;
    } else {
        if (n == list.len) {
            // **자리가 없으면 조용히 버리지 않는다**(계약 §5) — 저장을 누른 사용자는 들어간 줄
            // 알고 화면을 떠난다.
            setLastError("servers_full");
            return;
        }
        list[n] = draft;
        n += 1;
    }
    writeServers(list[0..n]);
}

/// 지금 편집 중인 서버를 목록에서 뺀다.
fn deleteServerDraft() void {
    const idx = srv_edit_index orelse {
        navPop(); // 새로 만들던 중이면 지울 것이 없다 — 그냥 나간다
        return;
    };
    var list: [mobile_config.max_servers]mobile_config.Server = @splat(.{});
    const cur = servers();
    var n: usize = 0;
    for (cur, 0..) |srv, i| {
        if (i == idx) continue;
        list[n] = srv;
        n += 1;
    }
    writeServers(list[0..n]);
}

/// 목록을 파일 본문에 반영하고 저장 요청을 세운다(설정 값 저장과 같은 순서).
fn writeServers(list: []const mobile_config.Server) void {
    const next = mobile_config.withServers(term_allocator, cfg_source, list) catch {
        setLastError("config_write_build");
        return;
    };
    if (cfg_source.len > 0) term_allocator.free(cfg_source);
    cfg_source = next;
    // **파일이 곧 값이다** — 다시 파싱해 화면이 같은 것을 본다(§1).
    const parsed = mobile_config.parse(term_allocator, cfg_source) catch {
        setLastError("config_parse");
        return;
    };
    if (cfg_parsed) |*old_parsed| old_parsed.deinit();
    cfg_parsed = parsed;
    if (cfg_write.len > 0) term_allocator.free(cfg_write);
    cfg_write = term_allocator.dupe(u8, cfg_source) catch blk: {
        setLastError("config_write_alloc");
        break :blk &.{};
    };
    navPop(); // 목록으로 돌아간다 — 바뀐 결과가 그 화면에 있다
}

/// 서버 칸 편집을 확정한다. **자리보다 길면 안 넣고 알린다**(위 `ServerDraft.set`).
fn commitServerFieldEdit() void {
    defer {
        edit_target = .none;
        set_edit_len = 0;
    }
    if (set_edit_len == 0) return; // 아무것도 안 치고 확정 — 값을 안 바꾼다
    const f: ServerField = @enumFromInt(srv_edit_field);
    const text = set_edit_buf[0..set_edit_len];
    if (f == .port) {
        // **파싱은 여기서 한다** — 어떤 칸인지 아는 자리가 여기고, 실패를 이름 있는 오류로
        // 남길 수 있는 자리도 여기다(`ServerDraft` 는 오류 이름을 모른다).
        const v = std.fmt.parseInt(u16, text, 10) catch {
            setLastError("server_field_invalid"); // 65535 를 넘거나 숫자가 아니다
            return;
        };
        if (!srv_draft.setPort(v)) setLastError("server_field_invalid");
        return;
    }
    if (!srv_draft.set(f, text)) setLastError("server_field_invalid");
}

// ── 서버 목록 화면 (S9b-2b) ─────────────────────────────────────────────────

/// 서버 줄 높이. **두 줄이 들어간다**(이름 + `user@host:port`) — 주소를 안 보이면 이름이
/// 비슷한 서버를 못 가른다.
const srv_row_h: f32 = 64;
var srv_list: SetRect = .{};
var srv_sa: scroll_area.State = .{};
var srv_touch: scroll_area.Touch = .{};
var srv_max_scroll: f32 = 0;
var srv_back_rect: SetRect = .{};
var srv_back_pressed = false;
var srv_row_rects: [mobile_config.max_servers]SetRect = @splat(.{});
/// 줄 오른쪽의 **편집** 자리(목록 화면). 접속과 편집을 같은 탭에 얹으면 하나는 못 쓴다.
var srv_edit_rects_in_list: [mobile_config.max_servers]SetRect = @splat(.{});
var srv_add_rect: SetRect = .{};
var srv_add_pressed = false;
/// 이번 짚음이 닿은 **편집** 자리(목록 화면).
var srv_edit_hit: ?usize = null;
var srv_pressed: ?usize = null;
var srv_press: gesture.Press = .{};
var srv_last_y: f32 = 0;

fn srvScroll() f32 {
    return @floatFromInt(srv_sa.offset_y_px);
}

/// 목록에 보일 이름. **비면 `user@host` 다** — 이름을 안 적었다고 빈 줄을 보이면 누를 것이
/// 무엇인지 알 수 없다(계약 [모바일 config](../../../docs/mobile-config.md) §4.3).
fn serverLabel(srv: mobile_config.Server, buf: []u8) []const u8 {
    if (srv.name.len > 0) return srv.name;
    return std.fmt.bufPrint(buf, "{s}@{s}", .{ srv.user, srv.host }) catch srv.host;
}

fn drawServers(win: SetRect, tk: *const tokens.Tokens) void {
    push(.{ .x = @intFromFloat(win.x), .y = @intFromFloat(win.y), .w = @intFromFloat(win.w), .h = @intFromFloat(win.h) }, tk.get(.surface_bg), 0xFF, 0, 0);

    // ── 헤더: 뒤로 + 제목(설정 화면과 같은 모양 — 두 화면이 다르게 굴면 매번 시험해 봐야 한다)
    srv_back_rect = .{ .x = win.x, .y = win.y, .w = set_head_h, .h = set_head_h };
    noteA11y(srv_back_rect, .{ .role = .button, .label = maru.i18n.tIn(.ko, .mob_a11y_back) });
    if (srv_back_pressed) push(.{ .x = @intFromFloat(srv_back_rect.x), .y = @intFromFloat(srv_back_rect.y), .w = @intFromFloat(srv_back_rect.w), .h = @intFromFloat(srv_back_rect.h) }, tk.get(.tab_hover_bg), 0xFF, 8, 0);
    if (reserveQuad()) {
        const rgb = tk.get(.surface_fg);
        quad_buf[quad_count] = .{
            .x = srv_back_rect.x + (set_head_h - 22) / 2,
            .y = srv_back_rect.y + (set_head_h - 22) / 2,
            .w = 22,
            .h = 22,
            .r = @as(f32, @floatFromInt(rgb.r)) / 255.0,
            .g = @as(f32, @floatFromInt(rgb.g)) / 255.0,
            .b = @as(f32, @floatFromInt(rgb.b)) / 255.0,
            .a = 1.0,
            .radius = 0,
            .kind = 2,
            .cell_x = 0,
            .cell_y = arrow_slot_base + 2, // arrow_left
        };
        quad_count += 1;
    }
    pushText(maru.i18n.tIn(.ko, .mob_servers), @intFromFloat(win.x + set_head_h), @intFromFloat(win.y + (set_head_h - 20) / 2), 20, tk.get(.surface_fg));
    push(.{ .x = @intFromFloat(win.x), .y = @intFromFloat(win.y + set_head_h), .w = @intFromFloat(win.w), .h = 1 }, tk.get(.divider), 0xFF, 0, 0);

    srv_list = .{ .x = win.x, .y = win.y + set_head_h + 1, .w = win.w, .h = win.h - set_head_h - 1 };
    const list = servers();
    srv_max_scroll = @max(0, @as(f32, @floatFromInt(list.len)) * srv_row_h - srv_list.h);
    srv_sa.clamp(@intFromFloat(@max(0, srv_max_scroll)));
    srv_row_rects = @splat(.{});
    srv_edit_rects_in_list = @splat(.{});

    // **빈 목록도 말을 한다.** 아무것도 안 그리면 화면이 고장 난 것처럼 보이고, 사용자는
    // 무엇을 해야 하는지 모른다(등록 수단은 다음 슬라이스라 지금은 어디에 적는지를 알린다).
    if (list.len == 0) {
        // 안내는 **추가 줄 아래**에 둔다 — 줄이 먼저 보여야 무엇을 누를지 안다.
        pushText(maru.i18n.tIn(.ko, .mob_servers_empty), @intFromFloat(srv_list.x + set_pad_x), @intFromFloat(srv_list.y + srv_row_h + 20), 17, tk.get(.surface_fg));
    }

    // **추가 줄은 목록 끝에 있다**(iOS·Android 설정 앱 관례). 목록이 비어도 이 줄은 있다 —
    // 그것이 없으면 화면이 유일한 입력 경로라는 계약(§2)이 거짓이 된다.
    for (0..list.len + 1) |i| {
        if (i == list.len) {
            const ry_add = srv_list.y + @as(f32, @floatFromInt(i)) * srv_row_h - srvScroll();
            if (ry_add + srv_row_h >= srv_list.y and ry_add <= srv_list.y + srv_list.h) {
                srv_add_rect = .{ .x = srv_list.x, .y = ry_add, .w = srv_list.w, .h = srv_row_h };
                noteA11yClipped(srv_add_rect, srv_list, .{
                    .role = .button,
                    .label = maru.i18n.tIn(.ko, .mob_server_add),
                });
                if (srv_add_pressed) push(.{ .x = @intFromFloat(srv_list.x), .y = @intFromFloat(ry_add), .w = @intFromFloat(srv_list.w), .h = @intFromFloat(srv_row_h) }, tk.get(.tab_hover_bg), 0xFF, 0, 0);
                pushText(maru.i18n.tIn(.ko, .mob_server_add), @intFromFloat(srv_list.x + set_pad_x), @intFromFloat(ry_add + (srv_row_h - 17) / 2), 17, tk.get(.accent_bar));
            } else srv_add_rect = .{};
            break;
        }
        const srv = list[i];
        const ry = srv_list.y + @as(f32, @floatFromInt(i)) * srv_row_h - srvScroll();
        // **안 보이는 행은 rect 를 안 남긴다** — 남기면 화면 밖인데 눌린다(설정 목록에서 겪었다).
        if (ry + srv_row_h < srv_list.y or ry > srv_list.y + srv_list.h) continue;
        srv_row_rects[i] = .{ .x = srv_list.x, .y = ry, .w = srv_list.w, .h = srv_row_h };
        if (srv_pressed == i) push(.{ .x = @intFromFloat(srv_list.x), .y = @intFromFloat(ry), .w = @intFromFloat(srv_list.w), .h = @intFromFloat(srv_row_h) }, tk.get(.tab_hover_bg), 0xFF, 0, 0);

        var name_buf: [96]u8 = undefined;
        const label = serverLabel(srv, &name_buf);
        pushText(label, @intFromFloat(srv_list.x + set_pad_x), @intFromFloat(ry + 12), 17, tk.get(.surface_fg));

        var addr_buf: [128]u8 = undefined;
        const addr = std.fmt.bufPrint(&addr_buf, "{s}@{s}:{d}", .{ srv.user, srv.host, srv.port }) catch srv.host;
        // **온전하지 않으면 그렇게 말한다.** 눌러도 안 붙는 줄을 멀쩡한 줄처럼 그리면 실패가
        // 네트워크 문제처럼 보인다(계약 §4.3).
        // **줄 오른쪽은 편집이다.** 탭이 접속인 자리에서 편집까지 같은 탭에 얹으면 둘 중
        // 하나는 못 쓴다 — 길게 누르기는 발견하기 어려워(숨은 기능) 눈에 보이는 자리를 준다.
        srv_edit_rects_in_list[i] = .{ .x = srv_list.x + srv_list.w - 88, .y = ry, .w = 88, .h = srv_row_h };
        pushText(maru.i18n.tIn(.ko, .mob_server_edit_short), @intFromFloat(srv_list.x + srv_list.w - 88 + 16), @intFromFloat(ry + (srv_row_h - 15) / 2), 15, tk.get(.accent_bar));

        // **지문이 없는 것은 오류가 아니다** — 처음 붙는 서버다(누르면 지문을 보여 주고 묻는다).
        // **지금 이 줄에 붙어 있나.** 붙는 중·붙음을 목록에서도 보인다 — 어느 서버가 살아 있는지
        // 를 목록이 말 못 하면 사용자는 눌러 보고서야 안다.
        const connected = ssh_connecting != null and ssh_connecting.? == i and conn_state != 0;
        const first = srv.isFirstConnect();
        const sub_role: tokens.ColorRole = if (!srv.isComplete()) .accent_bar else if (first) .accent_bar else .muted_fg;
        const sub_text = if (connected and conn_err_len == 0)
            maru.i18n.tIn(.ko, if (conn_state == 11) .mob_conn_ready else .mob_conn_connecting)
        else if (!srv.isComplete())
            maru.i18n.tIn(.ko, .mob_server_incomplete)
        else if (first)
            maru.i18n.tIn(.ko, .mob_server_first_connect)
        else
            addr;
        pushText(sub_text, @intFromFloat(srv_list.x + set_pad_x), @intFromFloat(ry + 12 + 22), 14, tk.get(sub_role));
        push(.{ .x = @intFromFloat(srv_list.x), .y = @intFromFloat(ry + srv_row_h - 1), .w = @intFromFloat(srv_list.w), .h = 1 }, tk.get(.divider), 0xFF, 0, 0);

        // **읽는 것도 여기서 낸다** — 값은 둘째 줄 그대로다. 그 줄은 주소일 수도 있고 「덜 적혔다」
        // 「처음 붙는다」 「붙는 중」일 수도 있는데, **그 사실이 색으로만 말해지면 안 읽힌다**.
        //
        // **누르는 자리가 둘이라 서술자도 둘이다**: 줄 전체는 접속이고 오른쪽 88px 는 편집이다.
        // 하나만 내면 스크린 리더 사용자는 둘 중 하나를 못 쓴다(길게 누르기는 숨은 기능이라
        // 그 자리를 눈에 보이게 둔 것이 이 화면의 결정이다).
        // **줄의 읽는 자리는 편집 띠 앞에서 끝난다.** 포인터가 편집을 먼저 보므로(그 자리는 줄이
        // 못 먹는다) 폭 전체를 내면 그 띠에서 두 서술자가 겹쳐, 스크린 리더가 짚은 것과 손가락이
        // 닿는 것이 갈린다(적대적 검증 4회차). **누르는 규칙과 같은 폭**을 쓴다.
        const row_read: SetRect = .{
            .x = srv_row_rects[i].x,
            .y = srv_row_rects[i].y,
            .w = @max(0, srv_row_rects[i].w - srv_edit_rects_in_list[i].w),
            .h = srv_row_rects[i].h,
        };
        noteA11yClipped(row_read, srv_list, .{
            .role = .list_item,
            .label = label,
            .value = sub_text,
            .position_in_set = @intCast(i + 1),
            // **집합은 서버 줄들이다.** 「추가」는 목록 끝에 붙은 **버튼**이라 이 집합의 일원으로
            // 읽히지 않는다 — 그것까지 세면 「셋 중 둘」이라 들은 사용자가 셋째를 찾다 못 찾는다
            // (적대적 검증 8회차: 수는 읽히는 것과 맞아야 한다).
            .set_size = @intCast(list.len),
        });
        noteA11yClipped(srv_edit_rects_in_list[i], srv_list, .{
            .role = .button,
            .label = maru.i18n.tIn(.ko, .mob_server_edit_short),
            // **어느 줄의 편집인가**를 값으로 말한다 — 「편집」만 여럿 읽히면 무엇을 고치는지 모른다.
            .value = label,
        });
    }
}

/// 편집 화면. **설정 화면과 같은 줄 모양**이다(라벨 왼쪽, 값 오른쪽, 눌러서 편집) — 두 화면이
/// 다르게 굴면 사용자가 어느 쪽이 먹는지 매번 시험해 봐야 한다.
/// 호스트키 승인 화면. **지문을 크게 보인다** — 사용자가 다른 경로로 받은 값과 눈으로 맞대야
/// 하는 유일한 자리다(그래서 줄여 쓰지 않는다).
fn drawHostKeyPrompt(win: SetRect, tk: *const tokens.Tokens) void {
    push(.{ .x = @intFromFloat(win.x), .y = @intFromFloat(win.y), .w = @intFromFloat(win.w), .h = @intFromFloat(win.h) }, tk.get(.surface_bg), 0xFF, 0, 0);
    pushText(maru.i18n.tIn(.ko, .mob_hostkey_title), @intFromFloat(win.x + set_pad_x), @intFromFloat(win.y + (set_head_h - 20) / 2), 20, tk.get(.surface_fg));
    push(.{ .x = @intFromFloat(win.x), .y = @intFromFloat(win.y + set_head_h), .w = @intFromFloat(win.w), .h = 1 }, tk.get(.divider), 0xFF, 0, 0);

    var y = win.y + set_head_h + 1;
    pushText(maru.i18n.tIn(.ko, .mob_hostkey_hint), @intFromFloat(win.x + set_pad_x), @intFromFloat(y + 14), 14, tk.get(.muted_fg));
    y += 46;

    // **지문은 두 줄로 나눠 통째로 보인다.** 줄이면(`…`) 눈으로 맞댈 수가 없다 — 이 화면의
    // 존재 이유가 그 대조다.
    const fp = hostKeyFingerprintShown();
    const half = fp.len / 2;
    // 두 줄을 덮는 자리를 **첫 줄에서** 붙든다(아래에서 `y` 가 내려간다 — 비밀번호 화면에서 같은
    // 방식으로 읽는 자리가 그린 글자를 비껴갔다).
    hk_fp_rect = .{ .x = win.x + set_pad_x, .y = y, .w = win.w - set_pad_x * 2, .h = 44 };
    pushText(fp[0..half], @intFromFloat(win.x + set_pad_x), @intFromFloat(y), 15, tk.get(.surface_fg));
    y += 22;
    pushText(fp[half..], @intFromFloat(win.x + set_pad_x), @intFromFloat(y), 15, tk.get(.surface_fg));
    // **지문은 «통째로» 읽힌다.** 화면은 눈으로 맞대기 좋게 두 줄로 쪼개 그리지만, 반쪽 둘로
    // 읽어 주면 대조가 안 된다 — 이 화면의 존재 이유가 그 대조다. 두 줄을 덮는 한 자리에
    // 온전한 값을 싣는다(무엇을 묻는 화면인지는 이름이 말한다).
    noteA11y(hk_fp_rect, .{ .role = .text, .label = maru.i18n.tIn(.ko, .mob_hostkey_hint), .value = fp });
    y += 34;

    hk_ok_rect = .{ .x = win.x, .y = y, .w = win.w, .h = set_row_h };
    noteA11y(hk_ok_rect, .{ .role = .button, .label = maru.i18n.tIn(.ko, .mob_hostkey_ok) });
    if (hk_pressed == .ok) push(.{ .x = @intFromFloat(hk_ok_rect.x), .y = @intFromFloat(hk_ok_rect.y), .w = @intFromFloat(hk_ok_rect.w), .h = @intFromFloat(hk_ok_rect.h) }, tk.get(.tab_hover_bg), 0xFF, 0, 0);
    pushText(maru.i18n.tIn(.ko, .mob_hostkey_ok), @intFromFloat(win.x + set_pad_x), @intFromFloat(y + (set_row_h - 16) / 2), 16, tk.get(.accent_bar));
    y += set_row_h;
    hk_cancel_rect = .{ .x = win.x, .y = y, .w = win.w, .h = set_row_h };
    noteA11y(hk_cancel_rect, .{ .role = .button, .label = maru.i18n.tIn(.ko, .mob_hostkey_cancel) });
    if (hk_pressed == .cancel) push(.{ .x = @intFromFloat(hk_cancel_rect.x), .y = @intFromFloat(hk_cancel_rect.y), .w = @intFromFloat(hk_cancel_rect.w), .h = @intFromFloat(hk_cancel_rect.h) }, tk.get(.tab_hover_bg), 0xFF, 0, 0);
    pushText(maru.i18n.tIn(.ko, .mob_hostkey_cancel), @intFromFloat(win.x + set_pad_x), @intFromFloat(y + (set_row_h - 16) / 2), 16, tk.get(.surface_fg));
}

/// 지문 두 줄을 덮는 자리(판정자용 — 읽는 자리가 그린 자리와 같아야 한다).
var hk_fp_rect: SetRect = .{};
pub fn hostKeyFingerprintRectForTest() SetRect {
    return hk_fp_rect;
}
var hk_ok_rect: SetRect = .{};
var hk_cancel_rect: SetRect = .{};
var hk_pressed: enum { none, ok, cancel } = .none;
var hk_press: gesture.Press = .{};

/// 두 버튼 한가운데(테스트용).
pub fn hostKeyOkCenter() struct { x: f32, y: f32 } {
    return .{ .x = hk_ok_rect.x + hk_ok_rect.w / 2, .y = hk_ok_rect.y + hk_ok_rect.h / 2 };
}
pub fn hostKeyCancelCenter() struct { x: f32, y: f32 } {
    return .{ .x = hk_cancel_rect.x + hk_cancel_rect.w / 2, .y = hk_cancel_rect.y + hk_cancel_rect.h / 2 };
}

/// 승인한다 — **그 지문을 그 서버 줄에 적는다**. 안 적으면 다음에 붙을 때 또 묻고, 그러면
/// "처음 보는 서버" 라는 말이 거짓이 된다(그리고 매번 묻는 물음은 사람이 안 읽는다).
fn acceptHostKey() void {
    hostkey_answer = 1;
    hostkey_prompt = false;
    if (screenTop() == .host_key) navPop();

    const idx = ssh_connecting orelse return;
    const list = servers();
    if (idx >= list.len) return;
    var next: [mobile_config.max_servers]mobile_config.Server = @splat(.{});
    var n: usize = 0;
    for (list) |srv| {
        next[n] = srv;
        n += 1;
    }
    next[idx].fingerprint = hostKeyFingerprintShown();
    writeServers(next[0..n]);
    // `writeServers` 가 목록 화면으로 되돌린다 — 여기서는 그 자리가 아니므로 되돌린 것을 취소한다.
    navPush(.terminal);
}

fn rejectHostKey() void {
    hostkey_answer = 2;
    hostkey_prompt = false;
    if (screenTop() == .host_key) navPop();
}

/// 비밀번호 화면. **친 글자를 안 보인다** — 어깨 너머로 읽히는 자리이고, 폰은 그 위험이 크다.
/// 대신 **몇 자 쳤는지**는 보인다(아무 표시도 없으면 키보드가 먹는지 알 수 없다).
fn drawPasswordPrompt(win: SetRect, tk: *const tokens.Tokens) void {
    push(.{ .x = @intFromFloat(win.x), .y = @intFromFloat(win.y), .w = @intFromFloat(win.w), .h = @intFromFloat(win.h) }, tk.get(.surface_bg), 0xFF, 0, 0);
    pushText(maru.i18n.tIn(.ko, .mob_password_title), @intFromFloat(win.x + set_pad_x), @intFromFloat(win.y + (set_head_h - 20) / 2), 20, tk.get(.surface_fg));
    push(.{ .x = @intFromFloat(win.x), .y = @intFromFloat(win.y + set_head_h), .w = @intFromFloat(win.w), .h = 1 }, tk.get(.divider), 0xFF, 0, 0);

    var y = win.y + set_head_h + 1;
    pushText(maru.i18n.tIn(.ko, .mob_password_hint), @intFromFloat(win.x + set_pad_x), @intFromFloat(y + 16), 14, tk.get(.muted_fg));
    y += 52;

    // 친 글자 수만큼 가림표. **글자 자체는 안 그린다.**
    var dots: [96]u8 = undefined;
    var n: usize = 0;
    var chars: usize = 0;
    var i: usize = 0;
    while (i < set_edit_len) : (i += 1) {
        if ((set_edit_buf[i] & 0xC0) == 0x80) continue; // 이어지는 바이트는 한 글자가 아니다
        chars += 1;
        if (n + 3 <= dots.len) {
            @memcpy(dots[n..][0..3], "\u{2022}");
            n += 3;
        }
    }
    const shown = if (chars == 0) maru.i18n.tIn(.ko, .mob_password_empty) else dots[0..n];
    const role: tokens.ColorRole = if (chars == 0) .muted_fg else .surface_fg;
    // **자리를 여기서 붙든다.** 아래에서 `y` 가 구분선과 여백만큼 더 내려가므로, 그 뒤에 계산하면
    // 읽는 자리가 그린 글자를 통째로 비껴간다(적대적 검증 1회차에서 그렇게 잡혔다).
    const dots_y = y;
    pw_dots_rect = .{ .x = win.x + set_pad_x, .y = dots_y, .w = win.w - set_pad_x * 2, .h = 24 };
    pushText(shown, @intFromFloat(win.x + set_pad_x), @intFromFloat(y), 20, tk.get(role));
    y += 40;
    push(.{ .x = @intFromFloat(win.x + set_pad_x), .y = @intFromFloat(y), .w = @intFromFloat(win.w - set_pad_x * 2), .h = 1 }, tk.get(.accent_bar), 0xFF, 0, 0);
    y += 24;

    // **가림표 줄도 읽힌다.** 글자는 절대 안 읽어 준다 — 스크린 리더는 소리로 나가고 곁에 사람이
    // 있을 수 있다(그래서 화면도 점으로만 그린다). 대신 **몇 글자를 쳤는지**를 값으로 준다:
    // 아무 표시가 없으면 키보드가 먹고 있는지조차 모른다.
    var cnt_buf: [24]u8 = undefined;
    const cnt_text = std.fmt.bufPrint(&cnt_buf, "{d}", .{chars}) catch "";
    noteA11y(
        .{ .x = win.x + set_pad_x, .y = dots_y, .w = win.w - set_pad_x * 2, .h = 24 },
        .{ .role = .text, .label = maru.i18n.tIn(.ko, .mob_password_hint), .value = cnt_text },
    );

    pw_ok_rect = .{ .x = win.x, .y = y, .w = win.w, .h = set_row_h };
    noteA11y(pw_ok_rect, .{ .role = .button, .label = maru.i18n.tIn(.ko, .mob_password_ok) });
    if (pw_pressed == .ok) push(.{ .x = @intFromFloat(pw_ok_rect.x), .y = @intFromFloat(pw_ok_rect.y), .w = @intFromFloat(pw_ok_rect.w), .h = @intFromFloat(pw_ok_rect.h) }, tk.get(.tab_hover_bg), 0xFF, 0, 0);
    pushText(maru.i18n.tIn(.ko, .mob_password_ok), @intFromFloat(win.x + set_pad_x), @intFromFloat(y + (set_row_h - 16) / 2), 16, tk.get(.accent_bar));
    y += set_row_h;
    pw_cancel_rect = .{ .x = win.x, .y = y, .w = win.w, .h = set_row_h };
    noteA11y(pw_cancel_rect, .{ .role = .button, .label = maru.i18n.tIn(.ko, .mob_password_cancel) });
    if (pw_pressed == .cancel) push(.{ .x = @intFromFloat(pw_cancel_rect.x), .y = @intFromFloat(pw_cancel_rect.y), .w = @intFromFloat(pw_cancel_rect.w), .h = @intFromFloat(pw_cancel_rect.h) }, tk.get(.tab_hover_bg), 0xFF, 0, 0);
    pushText(maru.i18n.tIn(.ko, .mob_password_cancel), @intFromFloat(win.x + set_pad_x), @intFromFloat(y + (set_row_h - 16) / 2), 16, tk.get(.surface_fg));
}

/// 판정자용 — 가림표를 **그린** 자리. 읽는 자리가 이것과 같아야 한다.
pub fn passwordDotsRectForTest() SetRect {
    return pw_dots_rect;
}
var pw_dots_rect: SetRect = .{};

/// 비밀번호 화면의 두 버튼 한가운데(테스트용 — 좌표를 테스트가 다시 계산하지 않는다).
pub fn passwordOkCenter() struct { x: f32, y: f32 } {
    return .{ .x = pw_ok_rect.x + pw_ok_rect.w / 2, .y = pw_ok_rect.y + pw_ok_rect.h / 2 };
}
pub fn passwordCancelCenter() struct { x: f32, y: f32 } {
    return .{ .x = pw_cancel_rect.x + pw_cancel_rect.w / 2, .y = pw_cancel_rect.y + pw_cancel_rect.h / 2 };
}

var pw_ok_rect: SetRect = .{};
var pw_cancel_rect: SetRect = .{};
var pw_pressed: enum { none, ok, cancel } = .none;
var pw_press: gesture.Press = .{};

/// 친 것을 확정한다 — host 가 `maru_mobile_take_password` 로 가져간다.
fn commitPassword() void {
    if (set_edit_len == 0) return; // 빈 값은 안 보낸다(서버가 실패로 셈한다)
    @memcpy(password_buf[0..set_edit_len], set_edit_buf[0..set_edit_len]);
    password_len = set_edit_len;
    password_ready = true;
    edit_target = .none;
    @memset(&set_edit_buf, 0);
    set_edit_len = 0;
}

fn drawServerEdit(win: SetRect, tk: *const tokens.Tokens) void {
    push(.{ .x = @intFromFloat(win.x), .y = @intFromFloat(win.y), .w = @intFromFloat(win.w), .h = @intFromFloat(win.h) }, tk.get(.surface_bg), 0xFF, 0, 0);

    srv_edit_back_rect = .{ .x = win.x, .y = win.y, .w = set_head_h, .h = set_head_h };
    noteA11y(srv_edit_back_rect, .{ .role = .button, .label = maru.i18n.tIn(.ko, .mob_a11y_back) });
    if (srv_edit_back_pressed) push(.{ .x = @intFromFloat(srv_edit_back_rect.x), .y = @intFromFloat(srv_edit_back_rect.y), .w = @intFromFloat(srv_edit_back_rect.w), .h = @intFromFloat(srv_edit_back_rect.h) }, tk.get(.tab_hover_bg), 0xFF, 8, 0);
    if (reserveQuad()) {
        const rgb = tk.get(.surface_fg);
        quad_buf[quad_count] = .{
            .x = srv_edit_back_rect.x + (set_head_h - 22) / 2,
            .y = srv_edit_back_rect.y + (set_head_h - 22) / 2,
            .w = 22,
            .h = 22,
            .r = @as(f32, @floatFromInt(rgb.r)) / 255.0,
            .g = @as(f32, @floatFromInt(rgb.g)) / 255.0,
            .b = @as(f32, @floatFromInt(rgb.b)) / 255.0,
            .a = 1.0,
            .radius = 0,
            .kind = 2,
            .cell_x = 0,
            .cell_y = arrow_slot_base + 2,
        };
        quad_count += 1;
    }
    pushText(maru.i18n.tIn(.ko, if (srv_edit_index == null) .mob_server_add else .mob_server_edit), @intFromFloat(win.x + set_head_h), @intFromFloat(win.y + (set_head_h - 20) / 2), 20, tk.get(.surface_fg));
    push(.{ .x = @intFromFloat(win.x), .y = @intFromFloat(win.y + set_head_h), .w = @intFromFloat(win.w), .h = 1 }, tk.get(.divider), 0xFF, 0, 0);

    srv_edit_rects = @splat(.{});
    var y = win.y + set_head_h + 1;
    inline for (@typeInfo(ServerField).@"enum".fields, 0..) |f, i| {
        const field: ServerField = @enumFromInt(f.value);
        const rect: SetRect = .{ .x = win.x, .y = y, .w = win.w, .h = set_row_h };
        srv_edit_rects[i] = rect;
        if (srv_edit_pressed == i) push(.{ .x = @intFromFloat(rect.x), .y = @intFromFloat(rect.y), .w = @intFromFloat(rect.w), .h = @intFromFloat(rect.h) }, tk.get(.tab_hover_bg), 0xFF, 0, 0);
        const label = maru.i18n.tIn(.ko, switch (field) {
            .name => .mob_server_name,
            .host => .mob_server_host,
            .port => .mob_server_port,
            .user => .mob_server_user,
            .fingerprint => .mob_server_fingerprint,
        });
        pushText(label, @intFromFloat(rect.x + set_pad_x), @intFromFloat(rect.y + (set_row_h - 16) / 2), 16, tk.get(.surface_fg));

        // 값(편집 중이면 치는 값 + 캐럿). 설정의 글자 칸과 **같은 규칙**이다(S9b-1).
        const editing = edit_target == .server_field and srv_edit_field == i;
        var buf: [editing_text_cap]u8 = undefined;
        const value = if (editing)
            editingText(&buf)
        else if (field == .port)
            (std.fmt.bufPrint(&buf, "{d}", .{srv_draft.port}) catch "?")
        else
            srv_draft.text(field);
        const role: tokens.ColorRole = if (editing) .accent_bar else .muted_fg;
        // **라벨 자리를 침범하지 않는다** — 값이 길면 앞을 자른다(지문이 그렇다).
        var fit_buf: [96]u8 = undefined;
        const label_w = textWidth(label, 16);
        const room = @as(i32, @intFromFloat(rect.w - set_pad_x * 2 - 12)) - label_w;
        const shown = fitRight(value, @max(40, room), 15, &fit_buf);
        pushText(shown, @intFromFloat(rect.x + rect.w - set_pad_x - @as(f32, @floatFromInt(textWidth(shown, 15)))), @intFromFloat(rect.y + (set_row_h - 15) / 2), 15, tk.get(role));
        // **값은 «줄인 것» 이 아니라 온전한 것을 읽힌다.** 화면은 자리에 맞춰 앞을 자르지만
        // (`fitRight`), 스크린 리더에는 잘릴 이유가 없다 — 주소가 반쪽이면 어느 서버인지 모른다.
        noteA11y(rect, .{
            .role = .button,
            .label = label,
            .value = stripCaret(value),
            .selected = editing,
        });
        push(.{ .x = @intFromFloat(rect.x), .y = @intFromFloat(rect.y + set_row_h - 1), .w = @intFromFloat(rect.w), .h = 1 }, tk.get(.divider), 0xFF, 0, 0);
        y += set_row_h;
    }

    // ── 이 기기의 공개키. **여기 있는 이유**: 이 서버에 붙으려면 그 서버 `authorized_keys` 에
    // 이 줄을 넣어야 한다 — 주소·지문을 치는 바로 그 자리에서 복사할 수 있어야 한 화면에서 끝난다.
    y += 12;
    const key_rect: SetRect = .{ .x = win.x, .y = y, .w = win.w, .h = set_row_h };
    srv_edit_rects[server_field_n] = key_rect;
    noteA11y(key_rect, .{ .role = .button, .label = maru.i18n.tIn(.ko, if (pubkey_copied) .mob_pubkey_copied else .mob_pubkey) });
    if (srv_edit_pressed == server_field_n) push(.{ .x = @intFromFloat(key_rect.x), .y = @intFromFloat(key_rect.y), .w = @intFromFloat(key_rect.w), .h = @intFromFloat(key_rect.h) }, tk.get(.tab_hover_bg), 0xFF, 0, 0);
    const key_label = maru.i18n.tIn(.ko, if (pubkey_copied) .mob_pubkey_copied else .mob_pubkey);
    pushText(key_label, @intFromFloat(key_rect.x + set_pad_x), @intFromFloat(key_rect.y + (set_row_h - 16) / 2), 16, tk.get(if (pubkey_copied) .accent_bar else .surface_fg));
    {
        // 키가 없으면 **그렇게 말한다** — 빈 줄을 보이면 눌러도 아무 일이 안 나는 줄이 된다.
        const line = publicKeyLine();
        var key_fit: [96]u8 = undefined;
        const key_room = @as(i32, @intFromFloat(key_rect.w - set_pad_x * 2 - 12)) - textWidth(key_label, 16);
        const shown = if (line.len == 0)
            maru.i18n.tIn(.ko, .mob_pubkey_absent)
        else
            fitRight(line, @max(40, key_room), 15, &key_fit);
        pushText(shown, @intFromFloat(key_rect.x + key_rect.w - set_pad_x - @as(f32, @floatFromInt(textWidth(shown, 15)))), @intFromFloat(key_rect.y + (set_row_h - 15) / 2), 15, tk.get(.muted_fg));
    }
    push(.{ .x = @intFromFloat(key_rect.x), .y = @intFromFloat(key_rect.y + set_row_h - 1), .w = @intFromFloat(key_rect.w), .h = 1 }, tk.get(.divider), 0xFF, 0, 0);
    y += set_row_h;

    // ── 저장 · 삭제. **저장이 위다** — 흔한 쪽이 손가락에 가깝고, 지우기가 실수로 눌리면 안 된다.
    y += 12;
    const save_rect: SetRect = .{ .x = win.x, .y = y, .w = win.w, .h = set_row_h };
    srv_edit_rects[server_field_n + 1] = save_rect;
    noteA11y(save_rect, .{ .role = .button, .label = maru.i18n.tIn(.ko, .mob_server_save) });
    if (srv_edit_pressed == server_field_n + 1) push(.{ .x = @intFromFloat(save_rect.x), .y = @intFromFloat(save_rect.y), .w = @intFromFloat(save_rect.w), .h = @intFromFloat(save_rect.h) }, tk.get(.tab_hover_bg), 0xFF, 0, 0);
    pushText(maru.i18n.tIn(.ko, .mob_server_save), @intFromFloat(save_rect.x + set_pad_x), @intFromFloat(save_rect.y + (set_row_h - 16) / 2), 16, tk.get(.accent_bar));
    push(.{ .x = @intFromFloat(save_rect.x), .y = @intFromFloat(save_rect.y + set_row_h - 1), .w = @intFromFloat(save_rect.w), .h = 1 }, tk.get(.divider), 0xFF, 0, 0);
    y += set_row_h;

    const del_rect: SetRect = .{ .x = win.x, .y = y, .w = win.w, .h = set_row_h };
    srv_edit_rects[server_field_n + 2] = del_rect;
    noteA11y(del_rect, .{ .role = .button, .label = maru.i18n.tIn(.ko, .mob_server_delete) });
    if (srv_edit_pressed == server_field_n + 2) push(.{ .x = @intFromFloat(del_rect.x), .y = @intFromFloat(del_rect.y), .w = @intFromFloat(del_rect.w), .h = @intFromFloat(del_rect.h) }, tk.get(.tab_hover_bg), 0xFF, 0, 0);
    pushText(maru.i18n.tIn(.ko, .mob_server_delete), @intFromFloat(del_rect.x + set_pad_x), @intFromFloat(del_rect.y + (set_row_h - 16) / 2), 16, tk.get(.surface_fg));
}

fn drawSettings(win: SetRect, tk: *const tokens.Tokens) void {
    push(.{ .x = @intFromFloat(win.x), .y = @intFromFloat(win.y), .w = @intFromFloat(win.w), .h = @intFromFloat(win.h) }, tk.get(.surface_bg), 0xFF, 0, 0);

    // ── 헤더: 뒤로 + 제목
    set_back_rect = .{ .x = win.x, .y = win.y, .w = set_head_h, .h = set_head_h }; // 44 이상 정사각
    // 팝업이 열려 있으면 **뒤로가기도 안 눌린다**(포인터가 「항목 아니면 닫기」로 먼저 먹는다).
    if (set_open == null) noteA11y(set_back_rect, .{ .role = .button, .label = maru.i18n.tIn(.ko, .mob_a11y_back) });
    if (set_back_pressed) push(.{ .x = @intFromFloat(set_back_rect.x), .y = @intFromFloat(set_back_rect.y), .w = @intFromFloat(set_back_rect.w), .h = @intFromFloat(set_back_rect.h) }, tk.get(.tab_hover_bg), 0xFF, 8, 0);
    if (reserveQuad()) {
        const rgb = tk.get(.surface_fg);
        quad_buf[quad_count] = .{
            .x = set_back_rect.x + (set_head_h - 22) / 2,
            .y = set_back_rect.y + (set_head_h - 22) / 2,
            .w = 22,
            .h = 22,
            .r = @as(f32, @floatFromInt(rgb.r)) / 255.0,
            .g = @as(f32, @floatFromInt(rgb.g)) / 255.0,
            .b = @as(f32, @floatFromInt(rgb.b)) / 255.0,
            .a = 1.0,
            .radius = 0,
            .kind = 2,
            .cell_x = 0,
            .cell_y = arrow_slot_base + 2, // arrow_left
        };
        quad_count += 1;
    }
    pushText(maru.i18n.tIn(.ko, .mob_settings), @intFromFloat(win.x + set_head_h), @intFromFloat(win.y + (set_head_h - 20) / 2), 20, tk.get(.surface_fg));
    push(.{ .x = @intFromFloat(win.x), .y = @intFromFloat(win.y + set_head_h), .w = @intFromFloat(win.w), .h = 1 }, tk.get(.divider), 0xFF, 0, 0);

    // ── 목록
    set_list = .{ .x = win.x, .y = win.y + set_head_h + 1, .w = win.w, .h = win.h - set_head_h - 1 };
    var content: f32 = 0;
    for (0..set_items.len) |k| content += setItemH(k);
    set_max_scroll = @max(0, content - set_list.h);
    set_sa.clamp(@intFromFloat(@max(0, set_max_scroll)));

    // **치고 있는 줄은 늘 보이게 끌어당긴다.** 소프트 키보드가 올라오면 host 가 그만큼 가용
    // 높이를 줄여 목록 창이 짧아지고(그래서 `set_max_scroll` 은 저절로 커진다 — 손으로 밀면
    // 닿는다), **스크롤 위치는 그대로**라 방금 누른 줄이 키보드 뒤로 들어갔다. 키보드는 떴는데
    // 어디에 쓰이는지 안 보이는, 이 화면이 이미 한 번 겪은 상태다(기기 실측: 글자 크기 줄을
    // 눌렀더니 숫자 패드는 떴고 그 줄은 사라졌다).
    //
    // **탭한 그 순간에 한 번 계산하면 빗나간다** — 그때는 키보드가 아직 안 올라와 창이 크다.
    // 매 프레임 재되, 이미 보이면 아무것도 안 한다. 그러면 키보드가 오르내려 창 높이가 바뀔
    // 때도 저절로 따라온다.
    if (set_edit) |ei| reveal: {
        // **한 번 맞춰 놓고는 손을 뗀다.** 매 프레임 끌어당기면 편집 중에 사용자가 목록을
        // 밀어도 즉시 되돌아가 **스크롤이 죽은 것처럼 보인다**(기기 실측: "한 번 수정을 거치고
        // 나면 스크롤이 안 된다"). 편집 중에도 다른 줄을 보고 싶을 수 있다.
        //
        // 다시 맞추는 때는 **창 높이가 바뀔 때**다 — 키보드가 오르내리면 보이는 범위가 달라져
        // 방금 맞춘 자리가 다시 어긋난다. 탭한 순간에 한 번만 계산하면 그때는 키보드가 아직
        // 안 올라와 창이 커서 빗나간다.
        const same = if (set_reveal) |r| r.idx == ei and r.win_h == set_list.h else false;
        if (same) break :reveal;
        set_reveal = .{ .idx = ei, .win_h = set_list.h };

        var top: f32 = 0;
        for (0..ei) |k| top += setItemH(k);
        const h = setItemH(ei);
        const cur: f32 = @floatFromInt(set_sa.offset_y_px);
        // 줄이 창 아래로 잘리지 않으려면 이만큼은 내려야 하고, 붙임 헤더에 가리지 않으려면
        // 이보다 더 내리면 안 된다. **창이 줄보다 작으면 위쪽을 살린다** — 값의 시작이 보이는
        // 편이 끝만 보이는 것보다 낫다(순서상 아래 조건이 덮는다).
        var want = cur;
        if (want < top + h - set_list.h) want = top + h - set_list.h;
        if (want > top - set_header_h) want = top - set_header_h;
        if (want != cur) _ = set_sa.scrollByPx(
            @intFromFloat(want - cur),
            @intFromFloat(@max(0, set_max_scroll)),
        );
    } else set_reveal = null;

    // 스크롤 위치에 걸린 섹션을 **먼저** 정한다. 붙임 헤더가 있으면 그만큼 목록 창이 좁아지고,
    // 그 좁아진 창이 **그리기와 히트의 공통 기준**이 되어야 한다 — 안 그러면 헤더 밑에 숨은
    // 행이 rect 를 그대로 갖고 있어 **안 보이는데 눌린다**(키바에서 고친 그 결함과 같은 모양).
    // **밴드는 늘 예약한다.** 붙임이 있을 때만 좁히면 헤더가 밴드에 들어간 순간 인라인으로도
    // 안 그려지고 붙임으로도 안 잡히는 **틈**이 생겨, 이름은 이전 섹션인데 내용은 다음 섹션인
    // 화면이 나온다(화면으로 잡았다). 목록 첫 항목이 헤더라 붙임은 늘 있다.
    const list_top = set_list.y + set_header_h;
    const list_h = set_list.h - set_header_h;
    var sticky: ?[]const u8 = null;
    {
        var probe: f32 = 0;
        for (set_items, 0..) |item, i| {
            if (set_list.y + probe - setScroll() <= list_top + 0.5) switch (item) {
                .header => |t| sticky = t,
                else => {},
            };
            probe += setItemH(i);
        }
    }

    var oy: f32 = 0;
    for (set_items, 0..) |item, i| {
        const h = setItemH(i);
        const ry = set_list.y + oy - setScroll();
        oy += h;
        switch (item) {
            .header => |title| {
                set_row_rects[i] = .{}; // 헤더는 **누를 수 없다** — 글자일 뿐이다
                if (ry + h < list_top or ry + h > list_top + list_h + 0.5) continue;
                pushText(title, @intFromFloat(set_list.x + set_pad_x), @intFromFloat(ry + (set_header_h - 13) / 2), 13, tk.get(.accent_bar));
                // **머리글도 읽힌다.** 누를 수는 없지만(글자다) 이것이 없으면 스무 줄 남짓이
                // 아무 구획 없이 이어져, 지금 어느 갈래를 듣고 있는지 알 수 없다.
                if (set_open == null) noteA11yClipped(
                    .{ .x = set_list.x, .y = ry, .w = set_list.w, .h = set_header_h },
                    .{ .x = set_list.x, .y = list_top, .w = set_list.w, .h = list_h },
                    .{ .role = .text, .label = title },
                );
            },
            .field => |*row| {
                // **위아래 규칙이 다르다 — 덮는 것이 있느냐로 갈린다.**
                // 위: 붙임 헤더가 **불투명하게 덮으므로** 걸쳐도 그린다(안 그러면 밴드 밑에
                //     한 행짜리 빈 구멍이 생긴다 — 화면으로 잡았다). 히트만 보이는 구간과
                //     교차시켜 **가려진 부분은 안 눌리게** 한다.
                // 아래: **덮을 것이 없다.** 걸쳐 그리면 하단 바 위로 반쯤 잘린 행이 삐져나온다
                //     (사용자가 화면에서 짚었다 — "벨 표시 레이아웃이 이상하다"). 그래서
                //     아래는 **완전히 들어온 것만** 그린다. 남는 자리는 목록 여백으로 읽힌다.
                if (ry + h < list_top or ry + h > list_top + list_h + 0.5) {
                    set_row_rects[i] = .{};
                    continue;
                }
                const vis_y = @max(ry, list_top);
                const vis_b = @min(ry + h, list_top + list_h);
                set_row_rects[i] = .{ .x = set_list.x, .y = vis_y, .w = set_list.w, .h = @max(0, vis_b - vis_y) };
                if (set_pressed != null and set_pressed.? == i)
                    push(.{ .x = @intFromFloat(set_list.x), .y = @intFromFloat(ry), .w = @intFromFloat(set_list.w), .h = @intFromFloat(h) }, tk.get(.row_hover_bg), 0xFF, 0, 0);
                pushText(row.label, @intFromFloat(set_list.x + set_pad_x), @intFromFloat(ry + (h - 15) / 2), 15, tk.get(.surface_fg));
                const right = set_list.x + set_list.w - set_pad_x;
                // **값은 config 에서 읽는다** — 화면이 자기 상태를 들면 파일과 갈린다(§1).
                const val = mobile_config.valueOf(cfg(), row.key);
                switch (row.kind) {
                    .toggle => {
                        drawSetToggle(val != 0, right, ry + h / 2, tk);
                        // **손잡이 자리와 색으로만 말하던 것**을 값으로 준다 — 둘 다 안 읽힌다.
                        noteA11ySettingRow(i, row.label, maru.i18n.tIn(.ko, if (val != 0) .mob_a11y_on else .mob_a11y_off), val != 0, list_top, list_h);
                    },
                    .number => {
                        // **편집 중이면 치는 값을 보인다.** 어디로 가는지 안 보이면 "키보드가
                        // 어디에 쓰이는지 모르는" 그 혼란이 그대로 남는다. 캐럿(▏)으로 그 줄이
                        // 입력 대상임을 알린다.
                        const editing = set_edit != null and set_edit.? == i;
                        var buf: [editing_text_cap]u8 = undefined;
                        const t = if (editing)
                            editingText(&buf)
                        else
                            (std.fmt.bufPrint(&buf, "{d}", .{val}) catch "?");
                        const role: tokens.ColorRole = if (editing) .accent_bar else .muted_fg;
                        pushText(t, @intFromFloat(right - @as(f32, @floatFromInt(textWidth(t, 15)))), @intFromFloat(ry + (h - 15) / 2), 15, tk.get(role));
                        noteA11ySettingRow(i, row.label, t, false, list_top, list_h);
                    },
                    .text => {
                        // 편집 중이면 치는 값을, 아니면 지금 값을 보인다. 캐럿(▏)으로 그 줄이
                        // 입력 대상임을 알린다(숫자 줄과 같은 규칙 — 두 줄이 다르게 굴면
                        // 사용자가 어느 쪽이 먹는지 매번 시험해 봐야 한다).
                        const editing = set_edit != null and set_edit.? == i;
                        var buf: [editing_text_cap]u8 = undefined;
                        const t = if (editing)
                            editingText(&buf)
                        else
                            mobile_config.textValueOf(cfg(), row.key);
                        const role: tokens.ColorRole = if (editing) .accent_bar else .muted_fg;
                        pushText(t, @intFromFloat(right - @as(f32, @floatFromInt(textWidth(t, 15)))), @intFromFloat(ry + (h - 15) / 2), 15, tk.get(role));
                        noteA11ySettingRow(i, row.label, t, false, list_top, list_h);
                    },
                    .choice => {
                        // **고른 것이 없으면 이름을 안 적는다**(§프리셋 되짚기). 아무거나 적으면
                        // 고르지도 않은 값을 고른 것처럼 보인다.
                        const v = if (val >= 0 and val < row.items.len) row.items[@intCast(val)] else "—";
                        const chev_w: f32 = 14;
                        pushText("\u{25BE}", @intFromFloat(right - chev_w), @intFromFloat(ry + (h - 15) / 2), 15, tk.get(.muted_fg));
                        pushText(v, @intFromFloat(right - chev_w - 6 - @as(f32, @floatFromInt(textWidth(v, 15)))), @intFromFloat(ry + (h - 15) / 2), 15, tk.get(.muted_fg));
                        noteA11ySettingRow(i, row.label, v, false, list_top, list_h);
                    },
                }
                push(.{ .x = @intFromFloat(set_list.x + set_pad_x), .y = @intFromFloat(ry + h - 1), .w = @intFromFloat(set_list.w - 2 * set_pad_x), .h = 1 }, tk.get(.divider), 0x80, 0, 0);
            },
        }
    }

    // **스크롤바.** 55줄을 한 줄기로 두면 **얼마나 남았는지**가 화면에 없다 — 목록을 나누지
    // 않기로 한 대가라 위치 표시가 그 자리를 메운다. 밀 수 있을 때만 그린다.
    if (set_max_scroll > 0) {
        const track_h = list_h;
        const thumb_h = @max(28.0, track_h * (track_h / content));
        const t = setScroll() / set_max_scroll;
        const thumb_y = list_top + t * (track_h - thumb_h);
        const bar_w: f32 = 3;
        push(.{
            .x = @intFromFloat(set_list.x + set_list.w - bar_w - 2),
            .y = @intFromFloat(thumb_y),
            .w = @intFromFloat(bar_w),
            .h = @intFromFloat(thumb_h),
        }, tk.get(.muted_fg), 0xB0, 1, 0);
    }

    // **지나간 섹션 이름을 맨 위에 붙인다.** 목록을 하나로 두면 "지금 어디" 가 사라지는데,
    // 하위 화면으로 나누는 대신 이 한 줄로 메운다(iOS 설정 앱과 같은 모양). 불투명하게
    // 덮어야 아래 행이 비쳐 글자가 겹치지 않는다.
    if (sticky) |title| {
        push(.{ .x = @intFromFloat(set_list.x), .y = @intFromFloat(set_list.y), .w = @intFromFloat(set_list.w), .h = @intFromFloat(set_header_h) }, tk.get(.surface_bg), 0xFF, 0, 0);
        pushText(title, @intFromFloat(set_list.x + set_pad_x), @intFromFloat(set_list.y + (set_header_h - 13) / 2), 13, tk.get(.accent_bar));
        push(.{ .x = @intFromFloat(set_list.x), .y = @intFromFloat(set_list.y + set_header_h - 1), .w = @intFromFloat(set_list.w), .h = 1 }, tk.get(.divider), 0xFF, 0, 0);
        // **붙임 머리글도 읽힌다.** 이 줄이 덮은 인라인 머리글은 안 그려지므로(그래서 안 낸다),
        // 여기서 안 내면 **맨 위 갈래의 이름이 어디에서도 안 읽힌다** — 실기 트리에서 첫 섹션만
        // 이름 없이 시작하는 것으로 드러났다.
        if (set_open == null) noteA11y(
            .{ .x = set_list.x, .y = set_list.y, .w = set_list.w, .h = set_header_h },
            .{ .role = .text, .label = title },
        );
    }

    // ── 팝업: **행 옆에 얹는다**(하위 화면으로 밀지 않는다). 배경이 보여야 즉시-적용이
    // 그대로 미리보기가 되기 때문이다 — 하위 화면으로 밀면 바꾼 결과가 가려진다.
    // **rect 도 같이 비운다.** 개수만 0 으로 두면 배열에는 **닫히기 전 값이 그대로 남아**
    // `settingsPopupItemVisible` 이 닫힌 팝업을 "보인다" 고 답한다 — 그 훅으로 판정하는
    // 테스트가 통과 보장 테스트가 된다(실제로 그렇게 짠 테스트가 결함을 못 잡았다).
    set_item_rects = @splat(.{});
    set_item_n = 0;
    if (set_open) |oi| switch (set_items[oi].field.kind) {
        .choice => {
            const c = set_items[oi].field; // items 는 스키마가, 고른 값은 config 가 든다
            // **고른 것이 없으면 아무것도 강조 안 한다.** 범위 밖을 0 으로 떨어뜨리면 첫 항목이
            // 선택된 것처럼 보인다 — 행에는 "—" 인데 팝업에는 `maru` 가 켜져 있었다(화면으로 잡았다).
            const sel: ?usize = s: {
                const v = mobile_config.valueOf(cfg(), c.key);
                break :s if (v >= 0 and v < c.items.len) @as(usize, @intCast(v)) else null;
            };
            const r = set_row_rects[oi];
            if (r.w == 0) {
                set_open = null;
            } else {
                const pw: f32 = 200;
                const px = set_list.x + set_list.w - set_pad_x - pw;
                var py = r.y + set_row_h;
                // **조용히 자르지 않는다.** 상자 높이를 `items.len` 으로 그리면서 항목은 rect
                // 배열만큼만 그리면, 넘치는 만큼 **빈 띠**가 생기고 그 자리는 눌리지도 않는다.
                // 지금 가장 긴 목록(테마 프리셋)이 정확히 상한이라 **우연히** 맞고 있다 —
                // 프리셋을 하나만 늘려도 드러난다(레포에 16개가 있다). 그릴 수 있는 만큼으로
                // 높이를 맞추고, 잘렸다는 사실은 오류로 남긴다(`take_copy` 와 같은 규율).
                const shown = @min(c.items.len, set_item_rects.len);
                if (shown < c.items.len) setLastError("settings_popup_truncated");
                const full_h = @as(f32, @floatFromInt(shown)) * set_row_h;
                // **목록 영역을 넘지 않는다.** 넘치면 그 항목들은 화면 밖이라 **고를 수가 없고**,
                // 모바일은 파일을 손으로 못 고치므로(계약 §2 — 화면이 유일한 입력 경로) 그 값이
                // 영영 사라진다. 프리셋 16개 × 44 = 704 라 작은 폰에서 실제로 넘친다.
                const ph = @min(full_h, set_list.h);
                set_pop_max_scroll = @max(0, full_h - ph);
                set_pop_sa.clamp(@intFromFloat(@max(0, set_pop_max_scroll)));
                if (py + ph > set_list.y + set_list.h) py = @max(set_list.y, r.y - ph);
                if (py < set_list.y) py = set_list.y;
                // **고르지 않고 닫는 길도 낸다.** 화면에서는 바깥을 눌러 취소하는데, 그 자리에
                // 서술자가 없으면 스크린 리더로는 **취소가 아예 불가능**하다(고르는 것 말고는
                // 나갈 길이 없다). 없는 것을 지어내는 것이 아니라 **이미 눌리는 자리**를 읽히게
                // 하는 것이다 — 포인터가 그 바깥 탭을 취소로 받는다(적대적 검증 5회차).
                //
                // 자리는 팝업 **위쪽 띠**다: 목록 창 안이고 팝업과 안 겹친다(겹치면 짚는 자리가
                // 갈린다). 팝업이 창 맨 위에 붙었으면 띠가 없으니 그때는 안 낸다.
                if (py - set_list.y >= set_row_h) noteA11y(
                    .{ .x = set_list.x, .y = set_list.y, .w = set_list.w, .h = py - set_list.y },
                    // **제 문구를 쓴다.** 다른 화면의 「취소」를 빌리면 그 화면이 바뀔 때 여기가
                    // 조용히 따라 바뀐다(적대적 검증 9회차).
                    .{ .role = .button, .label = maru.i18n.tIn(.ko, .mob_a11y_dismiss) },
                );
                push(.{ .x = @intFromFloat(px - 1), .y = @intFromFloat(py - 1), .w = @intFromFloat(pw + 2), .h = @intFromFloat(ph + 2) }, tk.get(.muted_fg), 0xFF, 9, 0);
                push(.{ .x = @intFromFloat(px), .y = @intFromFloat(py), .w = @intFromFloat(pw), .h = @intFromFloat(ph) }, tk.get(.surface_bg), 0xFF, 8, 0);
                for (c.items[0..shown], 0..) |it, k| {
                    const iy = py + @as(f32, @floatFromInt(k)) * set_row_h - @as(f32, @floatFromInt(set_pop_sa.offset_y_px));
                    // **보이는 것만 누를 수 있다.** 밖으로 나간 항목의 rect 를 남기면 화면에는
                    // 없는데 눌리는 자리가 생긴다(본문 목록과 같은 규율).
                    set_item_rects[k] = if (iy + set_row_h <= py or iy >= py + ph)
                        .{}
                    else
                        .{ .x = px, .y = iy, .w = pw, .h = set_row_h };
                    set_item_n = k + 1;
                    if (set_item_rects[k].w == 0) continue;
                    if (sel != null and k == sel.?)
                        push(.{ .x = @intFromFloat(px + 2), .y = @intFromFloat(iy + 2), .w = @intFromFloat(pw - 4), .h = @intFromFloat(set_row_h - 4) }, tk.get(.tab_active_bg), 0xFF, 6, 0);
                    pushText(it, @intFromFloat(px + 14), @intFromFloat(iy + (set_row_h - 15) / 2), 15, tk.get(if (sel != null and k == sel.?) .accent_bar else .surface_fg));
                    // **팝업 항목도 읽힌다.** 지금 이것이 눌리는 유일한 것인데 서술자가 없으면
                    // 스크린 리더 사용자는 **고를 수가 없다**(적대적 검증에서 잡았다).
                    noteA11y(set_item_rects[k], .{
                        .role = .list_item,
                        .label = it,
                        .selected = sel != null and k == sel.?,
                        .position_in_set = @intCast(k + 1),
                        .set_size = @intCast(shown),
                    });
                }
            }
        },
        else => set_open = null,
    };
}

/// chrome(설정 화면·톱니)이 이 터치를 먹었나. **키바보다 먼저** 물어야 한다 — 설정이 떠
/// 있으면 그 아래 키바·본문은 없는 것과 같다.
fn chromePointer(phase: u32, pointer_id: u32, x: f32, y: f32, time_ms: u64) u32 {
    // **터미널 화면의 chrome 은 상단 앱 바 하나뿐이다.** 하단 44px 바는 걷어냈고(U3b — 하단은
    // 이동 대상 자리이고 키보드가 늘 떠 있는 터미널에서 44px 를 영구히 썼다), 위쪽 뒤로가기만
    // 남겼다. 그 띠 **밖은 안 먹는다** — 키바·본문이 받는다.
    // **원격 화면의 뒤로가기.** 이 화면은 읽기 전용이라 본문에 받을 것이 없고, 상단바 왼쪽
    // 하나만 누른다 — 그것이 「덮개」로 세션을 바꾸는 길이다.
    if (screenTop() == .remote_screen) {
        if (phase != 0) return 0;
        if (remote_back_rect.w <= 0) return 0; // 안 그려졌으면 누를 것도 없다
        if (!setHit(remote_back_rect, x, y)) return 0;
        // **하드웨어 뒤로가기와 «같은 길»로 나간다.** 여기서 `navPop()` 만 부르면 화면은
        // 목록으로 돌아오는데 뜻은 `.screen` 그대로라, 그 서버에서 `attach` 가 계속 돌고
        // 맥은 폰이 선언한 폭에 계속 눌려 있다(실기 2026-09-04 — 나온 뒤에도 host 가
        // `observers=1 50x27` 이었다). 나가는 자리가 둘인데 하는 일이 달랐다.
        return maru_mobile_pop_screen();
    }
    if (screenTop() == .terminal) {
        switch (phase) {
            0 => {
                if (routeIs(.chrome)) return 1; // 둘째 손가락은 이 표면의 제스처를 안 건드린다
                // **복사가 먼저다** — 뒤로가기와 자리가 다르지만, 판정 순서를 고정해 둬야
                // 나중에 자리가 겹칠 때 조용히 한쪽이 죽지 않는다.
                if (term_kb_rect.w > 0 and setHit(term_kb_rect, x, y)) {
                    if (!routeClaim(.chrome)) return 0;
                    term_press.begin(x, y, time_ms, false);
                    term_kb_pressed = true;
                    return 1;
                }
                if (term_disc_rect.w > 0 and setHit(term_disc_rect, x, y)) {
                    if (!routeClaim(.chrome)) return 0;
                    term_press.begin(x, y, time_ms, false);
                    term_disc_pressed = true;
                    return 1;
                }
                if (term_copy_rect.w > 0 and setHit(term_copy_rect, x, y)) {
                    if (!routeClaim(.chrome)) return 0;
                    term_press.begin(x, y, time_ms, false);
                    term_copy_pressed = true;
                    return 1;
                }
                if (term_back_rect.w <= 0) return 0; // 안 그려졌으면 누를 것도 없다
                if (!setHit(term_back_rect, x, y)) return 0;
                if (!routeClaim(.chrome)) return 0;
                term_press.begin(x, y, time_ms, false); // 이 띠에는 흐르는 것이 없다
                term_back_pressed = true;
                return 1;
            },
            1 => {
                if (!routeIs(.chrome)) return 0;
                // 임계를 넘으면 밀려던 것이다 — 눌림 표시를 거둔다(다른 화면과 같은 규칙).
                if (term_press.move(x, y)) {
                    term_back_pressed = false;
                    term_copy_pressed = false;
                    term_kb_pressed = false;
                    term_disc_pressed = false;
                }
                return 1;
            },
            else => {
                if (!routeIs(.chrome)) return 0;
                const was_copy = term_copy_pressed;
                const was_kb = term_kb_pressed;
                const was_disc = term_disc_pressed;
                term_back_pressed = false;
                term_copy_pressed = false;
                term_kb_pressed = false;
                term_disc_pressed = false;
                routeClear(); // 이 띠는 한 손가락 자리다 — 뗀 순간 끝이다
                if (phase == 3) {
                    term_press.cancel();
                    return 1;
                }
                if (was_kb) {
                    // **화면 전환이 아니다** — 그 자리에 머문 채 올려 달라고만 한다.
                    if (term_press.end() == .tap) kb_raise_req = true;
                    return 1;
                }
                if (was_disc) {
                    // **끊고 목록으로 나간다**(사용자 확정 2026-08-24). 소켓을 놓는 것은 host 의
                    // 일이라 요청만 세우지만, **화면은 여기서 민다** — 끊긴 터미널에 남아 있을
                    // 이유가 없다(할 수 있는 것이 뒤로가기뿐인 화면이다).
                    //
                    // **상태를 보고 따라가게 두지 않는 이유**: 그러면 서버가 끊었을 때도 같이
                    // 나가 버려 **왜 끊겼는지를 못 본다**(`서버가 세션을 끊었다`·`붙지 못했다`는
                    // 그 화면에서 읽어야 하는 말이다). 나가는 것은 **사용자가 끊은 그 자리**의
                    // 일이라, 뜻이 분명한 여기서만 한다.
                    if (term_press.end() == .tap) {
                        disconnect_req = true;
                        navPop();
                    }
                    return 1;
                }
                if (was_copy) {
                    // **복사는 화면 전환이 아니다** — 그 자리에 머문 채 요청만 세운다.
                    if (term_press.end() == .tap and copyEnabled()) copy_pending = true;
                    return 1;
                }
                // **눌림 표시를 또 보지 않는다.** `down` 이 버튼 안에서만 잡으므로 "눌려 있었나"
                // 와 "탭인가" 가 늘 같은 값이다 — 둘을 다 보면 한쪽이 죽고, 죽은 조건은 변이로도
                // 안 드러난다(실제로 `end` 를 무시하는 변이가 통과했다).
                if (term_press.end() == .tap) _ = maru_mobile_pop_screen();
                return 1;
            },
        }
    }

    // **세션 목록**: 톱니는 설정을, 줄은 그 세션을 민다. down 에서 바로 밀지 않고 up 까지
    // 기다린다 — 밀려던 손짓이 화면 전환이 되면 안 된다(키바와 같은 규율).
    if (screenTop() == .sessions) {
        switch (phase) {
            0 => {
                // **둘째 손가락은 누름 판정을 안 건드린다**(계약 §3.1 — 표면마다 한 제스처).
                if (routeIs(.chrome)) return 1;
                if (!routeClaim(.chrome)) return 0;
                // **흐르는 목록을 세우려 짚었으면 줄을 안 누른다**(서버 목록·설정과 같은 규율).
                const stopped = sess_touch.begin(pointer_id, y);
                sess_press.begin(x, y, time_ms, stopped);
                if (stopped) {
                    sess_pressed = .none;
                    remote_pressed_id = null;
                    return 1;
                }
                sess_pressed = if (setHit(sess_gear_rect, x, y)) .gear else if (setHit(sess_row_rect, x, y)) .row else if (setHit(sess_servers_rect, x, y)) .servers else blk: {
                    // **원격 줄은 눌러서 그 화면을 연다**(§4a). 붙을 수 없는 줄(runtime id 가
                    // 없는 것 — in-process Term)은 누름 표시도 안 준다: 눌리는 것처럼 보이고
                    // 아무 일도 안 일어나면 사용자는 고장으로 읽는다.
                    remote_pressed_id = if (remoteRowAt(x, y)) |i| control_rows[i].runtime_id else null;
                    break :blk if (remote_pressed_id != null) .remote_row else .none;
                };
                return 1;
            },
            1 => {
                if (!routeIs(.chrome)) return 0;
                // 임계를 넘으면 밀려던 것이다 — 눌림 표시를 거둔다(목록·키바와 같은 규칙).
                if (sess_press.move(x, y)) {
                    sess_pressed = .none;
                    remote_pressed_id = null;
                }
                sess_touch.move(&sess_sa, pointer_id, y, @intFromFloat(@max(0, sess_max_scroll)));
                return 1;
            },
            else => {
                if (!routeIs(.chrome)) return 0;
                const was = sess_pressed;
                sess_pressed = .none;
                sess_touch.end(pointer_id, frame_dt_ms);
                routeClear(); // 세션 목록은 한 손가락 화면이다 — 뗀 순간 끝이다
                if (phase == 3) {
                    sess_press.cancel();
                    return 1;
                }
                if (sess_press.end() != .tap) return 1;
                switch (was) {
                    .gear => {
                        navPush(.settings);
                        set_sa.reset();
                        set_touch.cancel();
                    },
                    .row => navPush(.terminal),
                    .remote_row => openRemoteRow(),
                    .servers => {
                        navPush(.servers);
                        srv_sa.reset();
                        srv_touch.cancel();
                    },
                    .none => {},
                }
                return 1;
            },
        }
    }

    // ── 호스트키 승인 화면. 두 줄뿐이다(승인·취소).
    if (screenTop() == .host_key) {
        switch (phase) {
            0 => {
                if (routeIs(.chrome)) return 1;
                if (!routeClaim(.chrome)) return 0;
                hk_press.begin(x, y, time_ms, false);
                hk_pressed = if (setHit(hk_ok_rect, x, y)) .ok else if (setHit(hk_cancel_rect, x, y)) .cancel else .none;
                return 1;
            },
            1 => {
                if (!routeIs(.chrome)) return 0;
                if (hk_press.move(x, y)) hk_pressed = .none;
                return 1;
            },
            else => {
                if (!routeIs(.chrome)) return 0;
                const was = hk_pressed;
                hk_pressed = .none;
                routeClear();
                if (phase == 3) {
                    hk_press.cancel();
                    return 1;
                }
                if (hk_press.end() != .tap) return 1;
                switch (was) {
                    .ok => acceptHostKey(),
                    .cancel => rejectHostKey(),
                    .none => {},
                }
                return 1;
            },
        }
    }

    // ── 비밀번호 화면. 두 줄뿐이다(접속·취소) — 글자는 키보드가 넣는다.
    if (screenTop() == .password) {
        switch (phase) {
            0 => {
                if (routeIs(.chrome)) return 1;
                if (!routeClaim(.chrome)) return 0;
                pw_press.begin(x, y, time_ms, false);
                pw_pressed = if (setHit(pw_ok_rect, x, y)) .ok else if (setHit(pw_cancel_rect, x, y)) .cancel else .none;
                return 1;
            },
            1 => {
                if (!routeIs(.chrome)) return 0;
                if (pw_press.move(x, y)) pw_pressed = .none;
                return 1;
            },
            else => {
                if (!routeIs(.chrome)) return 0;
                const was = pw_pressed;
                pw_pressed = .none;
                routeClear();
                if (phase == 3) {
                    pw_press.cancel();
                    return 1;
                }
                if (pw_press.end() != .tap) return 1;
                switch (was) {
                    .ok => commitPassword(),
                    // **취소는 친 것을 지운다** — 화면만 닫고 값을 남기면 다음 물음에 그것이 간다.
                    .cancel => {
                        wipePassword();
                        password_prompt = false;
                        navPop();
                    },
                    .none => {},
                }
                return 1;
            },
        }
    }

    // ── 서버 편집 화면. 줄을 누르면 그 칸을 치고, 저장·삭제는 그 아래 두 줄이다.
    if (screenTop() == .server_edit) {
        switch (phase) {
            0 => {
                if (routeIs(.chrome)) return 1;
                if (!routeClaim(.chrome)) return 0;
                srv_edit_press.begin(x, y, time_ms, false);
                srv_edit_back_pressed = setHit(srv_edit_back_rect, x, y);
                srv_edit_pressed = null;
                if (!srv_edit_back_pressed) {
                    for (srv_edit_rects, 0..) |r, i| {
                        if (setHit(r, x, y)) {
                            srv_edit_pressed = i;
                            break;
                        }
                    }
                }
                return 1;
            },
            1 => {
                if (!routeIs(.chrome)) return 0;
                if (srv_edit_press.move(x, y)) {
                    srv_edit_pressed = null;
                    srv_edit_back_pressed = false;
                }
                return 1;
            },
            else => {
                if (!routeIs(.chrome)) return 0;
                const was_back = srv_edit_back_pressed;
                const was = srv_edit_pressed;
                srv_edit_back_pressed = false;
                srv_edit_pressed = null;
                routeClear();
                if (phase == 3) {
                    srv_edit_press.cancel();
                    return 1;
                }
                if (srv_edit_press.end() != .tap) return 1;
                if (was_back) {
                    // **나가면 안 저장한다** — 저장은 누르는 일이다(설정의 즉시 적용과 다른 이유:
                    // 서버 한 줄은 값 다섯이 함께 맞아야 뜻이 있다).
                    edit_target = .none;
                    set_edit_len = 0;
                    navPop();
                    return 1;
                }
                if (was) |i| {
                    if (i == server_field_n) {
                        // 공개키를 클립보드로. **없으면 아무 일도 안 한다** — 화면이 이미
                        // "아직 키가 없다" 고 말하고 있다.
                        const line = publicKeyLine();
                        if (line.len > 0) {
                            requestCopyText(line);
                            pubkey_copied = true;
                        }
                    } else if (i == server_field_n + 1) {
                        saveServerDraft();
                    } else if (i == server_field_n + 2) {
                        deleteServerDraft();
                    } else {
                        // 그 칸을 입력 대상으로 삼는다(설정의 글자 칸과 같은 규칙 — S9b-1).
                        edit_target = .server_field;
                        srv_edit_field = i;
                        set_edit_len = 0;
                        kb_raise_req = true;
                    }
                }
                return 1;
            },
        }
    }

    // ── 서버 목록 화면. 설정과 같은 규칙이다(밀면 스크롤, 짧게 누르면 그 줄).
    if (screenTop() == .servers) {
        switch (phase) {
            0 => {
                if (routeIs(.chrome)) return 1;
                if (!routeClaim(.chrome)) return 0;
                srv_last_y = y;
                // 흐르는 목록을 세우려 짚었는데 그 자리 서버에 붙으면 안 된다(키바·설정과 같은 규율).
                const stopped = srv_touch.begin(pointer_id, y);
                srv_press.begin(x, y, time_ms, stopped);
                srv_back_pressed = setHit(srv_back_rect, x, y);
                srv_pressed = null;
                srv_edit_hit = null;
                srv_add_pressed = false;
                if (!srv_back_pressed and !stopped) {
                    // **편집 자리를 먼저 본다** — 줄 전체가 접속이라 나중에 보면 영영 안 걸린다.
                    for (srv_edit_rects_in_list, 0..) |r, i| {
                        if (setHit(r, x, y)) {
                            srv_edit_hit = i;
                            break;
                        }
                    }
                    if (srv_edit_hit == null) {
                        for (srv_row_rects, 0..) |r, i| {
                            if (setHit(r, x, y)) {
                                srv_pressed = i;
                                break;
                            }
                        }
                    }
                    if (srv_edit_hit == null and srv_pressed == null) srv_add_pressed = setHit(srv_add_rect, x, y);
                }
                return 1;
            },
            1 => {
                if (!routeIs(.chrome)) return 0;
                if (srv_press.move(x, y)) { // 임계를 넘으면 밀려던 것이다
                    srv_pressed = null;
                    srv_back_pressed = false;
                    srv_edit_hit = null;
                    srv_add_pressed = false;
                }
                srv_touch.move(&srv_sa, pointer_id, y, @intFromFloat(@max(0, srv_max_scroll)));
                srv_last_y = y;
                return 1;
            },
            else => {
                if (!routeIs(.chrome)) return 0;
                const was_back = srv_back_pressed;
                const was_row = srv_pressed;
                const was_edit = srv_edit_hit;
                const was_add = srv_add_pressed;
                srv_back_pressed = false;
                srv_pressed = null;
                srv_edit_hit = null;
                srv_add_pressed = false;
                srv_touch.end(pointer_id, frame_dt_ms);
                routeClear();
                if (phase == 3) {
                    srv_press.cancel();
                    return 1;
                }
                if (srv_press.end() != .tap) return 1;
                if (was_back) {
                    navPop();
                    return 1;
                }
                if (was_edit) |i| {
                    openServerEdit(i);
                    return 1;
                }
                if (was_add) {
                    openServerEdit(null);
                    return 1;
                }
                if (was_row) |i| connectToServer(i);
                return 1;
            },
        }
    }

    // 설정 화면이 떠 있으면 **전부 먹는다**.
    switch (phase) {
        0 => {
            if (!routeIs(.chrome) and !routeClaim(.chrome)) return 0;
            set_last_y = y;
            // 키바와 같은 규칙 — 흐르는 목록을 세우려 짚었는데 그 자리 토글이 뒤집히면 안 된다.
            const was_owned = set_touch.owner != null;
            const stopped = set_touch.begin(pointer_id, y);
            // **둘째 손가락은 이 표면의 제스처를 안 건드린다**(계약 §3.1: 표면마다 한 제스처).
            // 전에는 이 가드가 `set_pressed` 만 막고 있었고 `set_down_y`·`set_moved` 는 **가드
            // 앞에서** 덮어써, 밀던 중에 다른 손가락이 닿으면 누적 이동량이 0 이 되어 **첫
            // 손가락을 떼는 순간 그 손짓이 탭으로 판정됐다**(팝업이 닫히고 값이 골라졌다).
            if (was_owned) return 1;
            set_press.begin(x, y, time_ms, stopped);
            // **팝업이 열려 있으면 뒤로가기도 안 눌린 것이다.** 그 상태의 첫 탭은 어디를 짚든
            // 팝업을 닫는 것뿐인데(아래 up), 표시만 눌린 것으로 두면 **뒤로 갈 줄 알고 누른
            // 손가락에게 거짓말**이 된다. 행 눌림을 같은 이유로 막고 있었는데 여기만 빠졌다.
            set_back_pressed = set_press.canTap() and set_open == null and setHit(set_back_rect, x, y);
            set_pressed = null;
            if (set_press.canTap() and set_open == null and !set_back_pressed) {
                for (set_row_rects, 0..) |r, i| if (setHit(r, x, y)) {
                    set_pressed = i;
                    break;
                };
            }
        },
        1 => {
            if (!set_press.active()) return 1;
            const dy = y - set_last_y;
            // **기준점은 임계와 무관하게 매 move 갱신한다**(키바 `kb_last_x` 와 같은 규칙).
            // 갱신을 임계 뒤로 미뤘더니 문턱을 넘는 첫 프레임이 **down 지점과의 차이**를
            // 통째로 적용해 목록이 10px 이상 **툭 뛰고**, 그 값이 그대로 관성 씨앗이 됐다.
            set_last_y = y;
            // **임계를 넘기 전에는 스크롤도 안 한다** — 살짝 민 손짓이 화면도 움직이고
            // 값도 바꾸면 같은 손짓이 어떨 때는 스크롤, 어떨 때는 입력으로 보인다.
            if (set_press.move(x, y)) {
                set_pressed = null;
                set_back_pressed = false;
            }
            if (set_press.state == .pressed) return 1;
            if (set_open != null) {
                // **팝업이 열려 있으면 팝업을 민다.** 안 그러면 목록 16개짜리 팝업에서 아래
                // 항목에 닿을 방법이 없다 — 화면이 유일한 입력 경로라 그 값이 영영 사라진다.
                _ = set_pop_sa.scrollByPx(@intFromFloat(-dy), @intFromFloat(@max(0, set_pop_max_scroll)));
                return 1;
            }
            if (set_open == null) {
                set_touch.move(&set_sa, pointer_id, y, @intFromFloat(@max(0, set_max_scroll)));
            }
        },
        else => {
            // **뗄 때 관성이 시작된다.** 취소(3)는 관성도 안 남긴다 — 화면이 바뀌는데 목록이
            // 계속 흐르면 돌아왔을 때 보던 자리가 아니다.
            if (phase == 3) set_touch.cancel() else set_touch.end(pointer_id, frame_dt_ms);
            // 마지막 손가락이면 목적지를 놓는다(계약 §3.1).
            if (phase == 3 or set_touch.owner == null) routeClear();
            // **비소유자가 떼는 것은 이 제스처를 안 끝낸다**(계약 §3.1) — 눌림 표시도 그대로
            // 둔다. 표시를 먼저 지우고 빠져나갔더니 **첫 손가락을 떼도 아무 일이 안 났다**
            // (둘째 손가락이 잠깐 닿았다 떨어진 것만으로 누르던 줄이 죽었다).
            if (phase == 2 and set_touch.owner != null) return 1;
            const pressed = set_pressed;
            const back = set_back_pressed;
            set_pressed = null;
            set_back_pressed = false;
            if (phase == 3) {
                set_press.cancel();
                return 1;
            }
            if (set_press.end() != .tap) return 1;
            if (set_open) |oi| {
                // 팝업이 열려 있으면 **항목 아니면 닫기**(바깥 탭 = 취소).
                var picked: ?usize = null;
                for (set_item_rects[0..set_item_n], 0..) |r, k| if (setHit(r, x, y)) {
                    picked = k;
                    break;
                };
                // **탭 = 즉시 적용 + 즉시 저장.** 값은 화면이 아니라 config 가 든다.
                if (picked) |k| if (set_items[oi].field.kind == .choice) {
                    settingChanged(set_items[oi].field, @intCast(k));
                };
                set_open = null;
                return 1;
            }
            // **편집 중에 바깥을 누르면 확정한다.** iOS 숫자 패드에는 Return 이 없어(Android 만
            // 있다) 그것 말고는 확정할 길이 없다 — iOS 앱들이 쓰는 그 관례다. 네이티브 툴바
            // (`inputAccessoryView`)를 얹지 않는 이유는 화면이 전부 우리 draw-list 라 거기만
            // 네이티브 스타일이 되기 때문이다.
            //
            // **그 탭은 삼킨다** — 확정하면서 뒤 행까지 누르면 "닫으려다 값이 바뀐다"(팝업이
            // 열렸을 때 행을 안 누르는 것과 같은 규율, [UX §5.6](../../../docs/mobile-ux.md)).
            if (set_edit) |ei| {
                const on_self = pressed != null and pressed.? == ei;
                if (!on_self) {
                    commitNumberEdit();
                    return 1;
                }
            }
            if (back) {
                navPop(); // pop
                return 1;
            }
            if (pressed) |i| switch (set_items[i].field.kind) {
                .toggle => {
                    const row = set_items[i].field;
                    settingChanged(row, if (mobile_config.valueOf(cfg(), row.key) != 0) 0 else 1);
                },
                .choice => {
                    set_open = i;
                    set_pop_sa.reset(); // 열 때마다 처음부터 — 지난번 자리가 남으면 엉뚱한 데서 뜬다
                },
                .number, .text => {
                    // **그 줄을 입력 대상으로 삼는다.** 소프트 키보드는 이미 떠 있고(설정을
                    // 열어도 안 내린다, §5.2) 지금까지 그 글자를 버리고 있었다 — 사용자에게는
                    // "키보드는 있는데 아무것도 안 써지는" 상태였다.
                    set_edit = i;
                    set_edit_len = 0;
                    kb_raise_req = true; // 내려가 있으면 올린다
                },
            };
        },
    }
    return 1;
}

/// Android 하드웨어 뒤로가기 · iOS 좌측 스와이프가 부른다. 뺄 화면이 있었으면 1.
pub export fn maru_mobile_pop_screen() u32 {
    if (screenTop() == .remote_screen) {
        // **화면을 그만 본다는 뜻을 코어에 알린다.** 안 알리면 그 서버에서 `attach` 가 계속 돌고,
        // 목록으로 돌아와도 축이 화면 레코드를 기다린다(§4a — 원하는 것이 소비자를 정한다).
        wantControl(.sessions);
        navPop();
        return 1;
    }
    if (screenTop() == .host_key) {
        // **뒤로가기는 거절이다.** 화면만 닫고 답을 안 주면 펌프가 2분을 기다린다.
        rejectHostKey();
        return 1;
    }
    if (screenTop() == .password) {
        // **뒤로가기는 취소다** — 친 것을 지우고 화면을 거둔다(안 지우면 다음 물음에 그것이 간다).
        wipePassword();
        password_prompt = false;
        navPop();
        return 1;
    }
    if (set_edit != null and screenTop() == .settings) {
        // **설정 줄도 같다** — 뒤로가기가 먼저 편집을 거둔다. 안 거두면 화면을 나가도 그 줄이
        // 편집 중으로 남아, 다시 들어왔을 때 **목록이 그 줄에 붙들린다**(치는 줄은 보이게
        // 끌어당기므로 스크롤이 죽은 것처럼 보인다 — 기기 실측).
        //
        // **확정이 아니라 취소다.** 뒤로가기는 "그만두겠다" 는 뜻이고, 바깥을 눌러 확정하는
        // 자리는 따로 있다(§5.6).
        set_edit = null;
        set_edit_len = 0;
        return 1;
    }
    if (edit_target == .server_field) {
        // 서버 칸도 같다 — 하드웨어 뒤로가기(Android)·스와이프(iOS)가 **먼저 편집을 거둔다**.
        // 안 거두면 화면을 나가도 목적지가 남아, 다음 화면에서 친 글자가 **안 보이는 초안**으로
        // 들어간다(그 화면은 이미 없다).
        edit_target = .none;
        set_edit_len = 0;
        return 1;
    }
    if (set_edit != null) {
        // 편집 중이면 **먼저 그것을 거둔다**(확정 없이 취소 — 값은 그대로).
        set_edit = null;
        set_edit_len = 0;
        return 1;
    }
    if (set_open != null) {
        set_open = null;
        return 1;
    }
    if (nav_len <= 1) return 0; // 목록이 뿌리다 — 더 뺄 것이 없으면 앱을 내린다(UX §3)
    navPop();
    // **진행 중이던 손짓도 함께 거둔다.** 손가락을 댄 채 뒤로가기를 누르면 up 이 안 와서
    // 제스처·눌림 표시·관성이 터미널 화면까지 살아남는다 — 남은 관성이 목록을 계속 밀고,
    // 다시 들어오면 누른 적 없는 행이 눌린 것처럼 보인다.
    // **네 표면을 다 거둔다.** 전에는 설정·목록만 거뒀는데, 본문을 짚은 채 뒤로 나가면 길게
    // 누름이 프레임에서 계속 판정돼 **안 보이는 화면에서 단어가 잡혔다**(돌아오면 누른 적 없는
    // 선택이 있다). 전이를 한 곳에 모아 놓고 그중 둘만 부르면 같은 병이 남는다.
    set_press.cancel();
    sess_press.cancel();
    kb_press.cancel();
    body_press.cancel();
    srv_press.cancel();
    srv_edit_press.cancel();
    term_press.cancel();
    term_back_pressed = false;
    set_pressed = null;
    set_back_pressed = false;
    kb_pressed = null;
    set_touch.cancel();
    return 1;
}

// ── 보조 키바 ─────────────────────────────────────────────────────────────────
// **소프트 키보드에는 Ctrl·Esc·Tab·화살표가 없다.** 그것 없이는 프로세스를 못 멈추고
// (Ctrl+C) vim 에서 못 빠져나온다 — 문장부호는 123 레이어로 칠 수 있지만 이 키들은 아예
// 칠 방법이 없다. 모바일 터미널이 전부 이 한 줄을 두는 이유다.
//
// **정의를 한곳에 둔다.** 레이아웃·라벨·탭 판정이 같은 표를 보게 해야 셋이 갈리지 않는다
// (라벨만 고치고 판정을 안 고치면 **엉뚱한 키가 나가고 화면에는 맞게 보인다**).
const KeyBarItem = struct {
    label: []const u8,
    key_id: u32, // mobile_host_abi.h 의 MARU_KEY_*
    codepoint: u32 = 0, // key_id == 0(문자)일 때만
    /// 누르면 **다음 글자에 실릴** 수정자. 0 이면 바로 나가는 키다.
    sticky_mod: u32 = 0,
    /// 키가 아니라 **복사**다. 다른 키와 똑같이 늘 줄에 있고, 선택이 없으면 흐리게 그려진다
    /// (`copyEnabled`). 한때 선택이 있을 때만 나타났는데 줄이 흔들렸다 — [UX §5.4](../../../docs/mobile-ux.md).
    is_copy: bool = false,
    /// 라벨 대신 그릴 **아이콘 슬롯**(없으면 null). 방향키가 여기 해당한다 — 폰트 글리프
    /// (`↑↓←→`)는 폰트마다 작게 디자인돼 44px 키캡에서 글자 라벨보다 훨씬 작아 보였다.
    icon_slot: ?u32 = null,
};

/// **개수 상한이 없다** — 44px 를 지키고 가로로 스크롤하므로 폰 폭에 안 들어가도 된다
/// (한때 11개가 상한이었다). 늘어나면 미는 거리가 길어지는 것이 유일한 대가다.
/// 키바는 **두 줄 · 여섯 칸**이다(사용자 확정 — 레퍼런스 배열). 한 줄로 늘어놓고 가로로 밀던
/// 것을 바꿨다: 밀어야 닿는 키는 **급할 때 못 찾는다**(Ctrl·화살표가 그렇다). 두 줄이면 전부
/// 한눈에 있고, 칸을 화면 폭으로 나눠 손가락에도 더 크다.
///
/// **여기 있는 것은 소프트 키보드에 없는 키뿐이다.** `|`·`~`·`/`·`-` 는 어느 키보드에나 기호
/// 층에 있어 뺐다(그 자리를 Home/End·PgUp/PgDn 이 쓴다 — 그것들은 어디에도 없다).
/// `copy` 는 **터미널 앱 바**로 옮겼다: 선택이 있을 때만 뜨는 것이 맞고, 늘 한 칸을 먹을 이유가
/// 없다(그리고 두 줄 열두 칸에는 자리가 없다).
const key_bar = [_]KeyBarItem{
    // ── 1행
    .{ .label = "esc", .key_id = 2 },
    .{ .label = "tab", .key_id = 3 },
    .{ .label = "home", .key_id = 9 },
    .{ .label = "\u{2191}", .key_id = 5, .icon_slot = arrow_slot_base + 0 },
    .{ .label = "end", .key_id = 10 },
    .{ .label = "pgup", .key_id = 13 },
    // ── 2행
    .{ .label = "ctrl", .key_id = 0, .sticky_mod = 2 }, // MARU_MOD_CTRL
    .{ .label = "alt", .key_id = 0, .sticky_mod = 4 }, // MARU_MOD_ALT
    .{ .label = "\u{2190}", .key_id = 7, .icon_slot = arrow_slot_base + 2 },
    .{ .label = "\u{2193}", .key_id = 6, .icon_slot = arrow_slot_base + 1 },
    .{ .label = "\u{2192}", .key_id = 8, .icon_slot = arrow_slot_base + 3 },
    .{ .label = "pgdn", .key_id = 14 },
};

/// 한 줄에 못 넣을 때의 줄 수. **사용자가 정한 값이다**([UX §5.4](../../../docs/mobile-ux.md) —
/// 「두 줄 격자」). 파생이 아니라 결정이라 여기 상수로 둔다.
const key_bar_rows_narrow: usize = 2;

/// 키 하나의 **최소 손가락 폭**. 높이(`key_h`)와 같은 수인 것은 우연이 아니다 — 손가락 표적은
/// 정사각(44×44)이다.
const key_min_w: f32 = key_h;

/// 이 폭에서 키바를 **몇 줄로 그리나.** 한 줄에 전부 넣어도 키가 손가락 크기를 지키면 한 줄이다.
///
/// **두 줄이 된 이유가 폭이었으니 푸는 기준도 폭이다** — 세로(논리 411)에서 열둘을 한 줄에 넣으면
/// 키가 29px 이 되어 못 누른다(UX §5.4 가 적은 그 계산이다). 가로(논리 865)에서는 같은 열둘이
/// 67px 씩 되어 **한 줄이 낫다**: 세로 한 줄(53px)을 본문에 돌려주고도 키가 오히려 넓어지고,
/// **숨는 키도 없다**(실측 2026-09-05).
///
/// **화면 방향을 안 묻는다** — 폭만 본다. 방향으로 가르면 태블릿 세로처럼 「세로인데 넓은」 자리를
/// 틀리게 답한다.
fn keyBarRows(width: f32) usize {
    const band_w = width - 2 * key_bar_pad_x;
    const one_row_w = @floor(band_w / @as(f32, @floatFromInt(key_bar.len))) - key_gap;
    return if (one_row_w >= key_min_w) 1 else key_bar_rows_narrow;
}

/// 그 줄 수일 때 **한 줄에 몇 칸인가.** 키를 더하면 따라온다 — 두 값을 따로 적으면 갈린다.
fn keyBarCols(rows: usize) usize {
    return (key_bar.len + rows - 1) / rows;
}

/// 키바가 먹는 높이. 레이아웃(자리 잡기)과 「들어가나」 판정이 **같은 식**을 봐야 한다.
fn keyBarHeight(width: f32) f32 {
    return @as(f32, @floatFromInt(keyBarRows(width))) * (key_h + key_gap) + 10.0;
}
/// 본문 격자가 **반드시 그리는** 줄 수. `pushTerminal` 의 바닥이자 레이아웃이 키바를 넣을지
/// 가르는 문턱이다 — 두 곳이 같은 수를 봐야 격자가 제 사각형 안에 남는다.
const min_body_rows: u16 = 2;

/// `copy` 가 지금 쓸 수 있나(선택이 있나). 표시와 판정이 같은 값을 본다.
fn copyEnabled() bool {
    const core = &(term_core orelse return false);
    return core.selectionViewportSpan() != null;
}

/// 복사 요청. host 가 다음에 `maru_mobile_take_copy` 로 가져간다 — **클립보드는 OS 것이라
/// 브리지가 못 쓴다**(§3: 여기엔 OS 호출이 없다).
var copy_pending = false;
/// 코어 선택이 아니라 **정해진 글자**를 복사할 때 그 글자(공개키 한 줄 등). 0 이면 선택에서 뽑는다.
var copy_text_buf: [256]u8 = undefined;
var copy_text_len: usize = 0;

/// 그 글자를 클립보드로 보내 달라고 요청한다(host 가 `take_copy` 로 가져간다).
fn requestCopyText(text: []const u8) void {
    if (text.len == 0 or text.len > copy_text_buf.len) {
        setLastError("copy_text_size");
        return;
    }
    @memcpy(copy_text_buf[0..text.len], text);
    copy_text_len = text.len;
    copy_pending = true;
}

/// 레이아웃 id 는 이 값에 인덱스를 더한다. 라벨 id 는 카드 id + 100.
const key_bar_id_base: u64 = 500;

/// 마지막 build 가 잡아 준 각 키의 사각형. **판정도 배치를 아는 쪽이 한다**(§3) —
/// 플랫폼은 점만 넘긴다.
var key_bar_rects: [key_bar.len]struct { x: f32 = 0, y: f32 = 0, w: f32 = 0, h: f32 = 0 } = undefined;
var key_bar_ready = false;
/// 마지막 프레임이 실제로 그린 키바 줄 수. `key_bar_ready` 와 같은 자리에서만 움직인다.
var key_bar_rows_drawn: usize = 0;

/// 눌러 둔 수정자(sticky). **다음 한 글자**에만 실린다 — 계속 걸려 있으면 그 다음 타이핑이
/// 전부 제어문자가 된다.
var armed_mods: u32 = 0;

/// 마지막 build 에서 **armed 로 그려진** 키의 비트마스크. `armed_mods` 와 **다른 축이다** —
/// 그쪽은 "무엇이 실릴 것인가" 이고 이것은 "무엇이 눌린 것처럼 보이는가" 다. 둘이 어긋났던 것이
/// 이 파일이 고친 결함이라, 어긋남을 밖에서 잴 수 있게 남긴다.
var keybar_armed_drawn: u32 = 0;

/// 스크롤이 무엇을 보고 갈래를 고르는지(테스트·진단용): bit0=alt_active · bit1=alternate_scroll ·
/// bit2=mouse_tracking != none.
pub fn scrollModeBits() u32 {
    const core = &(term_core orelse return 0xFFFF);
    var b: u32 = 0;
    if (core.alt_active) b |= 1;
    if (core.alternate_scroll) b |= 2;
    if (core.mouse_tracking != .none) b |= 4;
    return b;
}

/// 지금 화면에서 눌린 것처럼 보이는 수정자(테스트·진단용).
/// 본문 격자가 **제 사각형 밖으로 넘친 px**(0 이면 안 넘쳤다). 격자는 `min_body_rows` 를
/// 바닥으로 쓰므로 사각형이 그보다 얇으면 그 아래가 다른 것 위에 깔린다 — 가로에서 소프트
/// 키보드를 올렸을 때 실제로 그렇게 됐다. **눈이 아니면 안 보이던 것**이라 여기서 잰다.
pub fn bodyGridOverflowPx() f32 {
    if (body_rect.h <= 0) return 0;
    const drawn = @as(f32, @floatFromInt(@as(i32, term_rows) * body_line_h));
    return @max(0, drawn - body_rect.h);
}

/// 지금 **그려진** 키바의 줄 수(0 이면 안 그려졌다). 폭에서 다시 계산하지 않고 그리는 자리가
/// 적어 둔 값을 답한다 — 다시 계산하면 「그렇게 그렸나」가 아니라 「그렇게 계산되나」를 재게 된다.
pub fn keybarRowsDrawn() usize {
    return key_bar_rows_drawn;
}

pub fn keybarArmedDrawn() u32 {
    return keybar_armed_drawn;
}

/// 플랫폼이 부른다: UI 를 조립하고 quad 개수를 돌려준다.
/// 마지막 오류 이름. 0 quads 가 나왔을 때 **무엇이 실패했는지** 플랫폼이 볼 수 있어야 한다 —
/// catch 로 삼키면 화면이 비어 있는 이유를 알 수 없다(실측: 처음에 그렇게 짰다가 헤맸다).
var last_error: [64]u8 = [_]u8{0} ** 64;

/// 플랫폼이 `maru_mobile_last_error` 로 읽는 자리. 조용한 실패를 남기지 않기 위한 것이라
/// **덮어쓰지 않는다** — 먼저 난 원인이 더 쓸모 있다.
fn setLastError(name: []const u8) void {
    if (last_error[0] != 0) return;
    const n = @min(name.len, last_error.len - 1);
    @memcpy(last_error[0..n], name[0..n]);
}

/// 프레임 시각(ms). **길게 누름은 시계가 있어야 판정된다** — move 핸들러에서만 보면 손가락이
/// 가만히 있을 때 이벤트가 안 와서 영영 안 잡힌다(2초를 눌러도 아무 일도 안 났다, 실측).
var frame_ms: u64 = 0;
/// 직전 프레임과의 간격(ms). **관성이 이걸로 돈다** — 프레임당으로 감쇠하면 같은 손짓이
/// 30Hz 기기에서 두 배 멀리 간다.
var frame_dt_ms: f32 = 0;

/// 누르고 있는 채로 시간이 지났는지 매 프레임 본다. **여기가 유일한 판정 자리다** —
/// 두 곳에 두면 한쪽만 고쳐져 갈린다.
fn checkLongPress(core: *terminal.core.TerminalCore) void {
    // **판정은 상태기계가 한다** — `pressed` 일 때만 넘어가고, 한 제스처에 한 번만 true 다.
    // 전에는 `!ptr_down or ptr_moved` 로 같은 것을 조합으로 봤다.
    if (!body_press.holdPast(frame_ms, long_press_ms)) return;
    if (bodyCell(body_press.down_x, body_press.down_y)) |c| {
        core.selectWordAt(c.row, c.col, &.{});
        // **이 제스처는 스크롤이 아니다 — 여기서 속도를 거둔다.** 길게 누르기 전에도 손이
        // 떨려 `move` 가 오고(임계 10px 안이라 선택은 성립한다) 그 2px 가 0.125px/ms 로
        // 남는다 — 정지 임계(0.03)의 네 배다. 선택 중 `move` 는 속도 코드를 건너뛰므로 그
        // 값이 그대로 살아남아, 손을 떼는 순간 **방금 고른 글자가 흘러간다**(재현: 27 → 28).
        body_fling = 0;
    }
}

pub export fn maru_mobile_build(width: u32, height: u32, time_ms: u64) u32 {
    // **관성의 시간축.** 프레임 간격이 없으면 감쇠가 프레임률을 타서, 같은 손짓이 30Hz
    // 기기에서 두 배 멀리 간다(실측 610px 대 402px). 첫 프레임은 간격이 없으므로 0 이다 —
    // `Touch.step` 이 하한으로 자른다.
    frame_dt_ms = if (frame_ms == 0 or time_ms < frame_ms) 0 else @floatFromInt(time_ms - frame_ms);
    frame_ms = time_ms;
    // 아틀라스 축출의 시간축. **벽시계(`time_ms`)가 아니라 프레임 순번**이다 — 축출이 판정해야
    // 하는 것은 "몇 초 전"이 아니라 "이번 프레임에 쓰였나"이고, 시계는 테스트에서 멈출 수 있다.
    frame_seq +%= 1;
    resetAtlasIfBakeSizeChanged();
    stepSetFling();
    stepBodyFling();
    if (term_core) |*core| checkLongPress(core);
    quad_count = 0;
    // **서술자도 프레임마다 비운다**(M9). 안 비우면 지난 프레임에 있던 버튼을 계속 읽는다 —
    // rect 가 0 이면 안 답하는 규율과 같은 이유다.
    a11y_count = 0;
    a11y_text_len = 0;
    // **여기서 비우지 않는다.** 프레임 시작마다 비우면 프레임 **사이**에 난 실패
    // (`maru_mobile_input` 의 core write)가 아무도 읽기 전에 지워진다 — 키가 조용히
    // 사라지던 것이 이번 리뷰 최상위 결함이었는데, 그 신호가 딱 그 경로에서만 안 남았다.
    // 비우는 것은 **읽은 쪽**이 한다(`maru_mobile_clear_error`).
    const tk = tokens.Tokens.rich(themeColors());
    // **터미널 층은 맨 위일 때만 읽힌다.** 아래 `switch` 가 밀린 화면을 그리기 직전에 깃발을
    // 다시 세운다 — 그러면 「그리는 자리」와 「읽는 자리」의 조건이 한 곳에서만 정해진다.
    a11y_top_layer = screenTop() == .terminal;
    buildUi(width, height, &tk) catch |err| {
        setLastError(@errorName(err));
        return 0;
    };
    // **밀린 화면은 아래를 덮는다**(스택 — UX §3). 터미널을 먼저 세우는 이유는 두 가지다:
    // 코어 격자·아틀라스가 계속 살아 있어야 돌아왔을 때 화면이 그대로이고, 키바 사각형이
    // 서 있어야 `key_bar_ready` 가 거짓말을 안 한다.
    // **목록 자리를 벗어났으면 닫는다.** 여는 판정은 `drawRemoteSessions` 가 하고, 나가는
    // 판정은 여기서 한 번에 한다 — 화면 전환 경로마다 갈고리를 달면 하나를 빠뜨린다.
    if (screenTop() != .sessions) noteControlScreen(false);
    a11y_top_layer = true; // 여기부터는 «맨 위» 화면이다
    switch (screenTop()) {
        .terminal => {},
        .sessions => drawSessions(.{ .x = 0, .y = 0, .w = @floatFromInt(width), .h = @floatFromInt(height) }, &tk),
        .settings => drawSettings(.{ .x = 0, .y = 0, .w = @floatFromInt(width), .h = @floatFromInt(height) }, &tk),
        .servers => drawServers(.{ .x = 0, .y = 0, .w = @floatFromInt(width), .h = @floatFromInt(height) }, &tk),
        .server_edit => drawServerEdit(.{ .x = 0, .y = 0, .w = @floatFromInt(width), .h = @floatFromInt(height) }, &tk),
        .password => drawPasswordPrompt(.{ .x = 0, .y = 0, .w = @floatFromInt(width), .h = @floatFromInt(height) }, &tk),
        .host_key => drawHostKeyPrompt(.{ .x = 0, .y = 0, .w = @floatFromInt(width), .h = @floatFromInt(height) }, &tk),
        .remote_screen => drawRemoteScreen(.{ .x = 0, .y = 0, .w = @floatFromInt(width), .h = @floatFromInt(height) }, &tk),
    }
    sortA11yForReading();
    noteFrameChanged();
    return @intCast(quad_count);
}

// ── 접근성 서술자 (M9) ──────────────────────────────────────────────────────
//
// **계약은 데스크톱 것이다** — `chrome/ui/semantics.zig` 의 `Role`·`Semantics` 를 그대로 빌린다
// (CIM §3). 데스크톱은 `tree` 노드가 서술자를 싣고 Swift 어댑터가 그것을 네이티브 요소로
// 투영하는데, **모바일은 UI 를 거의 직접 그린다**(tree 노드 다섯 vs 누를 수 있는 사각형 서른일곱)
// — 그래서 tree 의 배관이 여기서는 거의 안 쓰이고, 그리는 자리가 스스로 내야 한다.
//
// **내는 자리는 rect 를 기록하는 그 자리다.** 「그리는 자리와 누르는 자리가 같아야 한다」는
// 규율이 이 파일에 이미 있는데(`key_bar_rects`·`term_back_rect`…), 서술자를 **다른 곳에서**
// 만들면 세 번째 진실이 생겨 조용히 갈린다. 그래서 `noteA11y` 는 rect 를 적는 줄 옆에 선다.
//
// **아직 host 어댑터가 없다**(iOS `UIAccessibilityElement`·Android `AccessibilityNodeInfo`).
// 이 슬라이스는 그 어댑터가 읽을 것을 내는 데까지다 — 그 전까지 VoiceOver·TalkBack 에게는
// 여전히 빈 화면이고, 그 사실을 계획에 적어 둔다.
const A11yNode = struct {
    rect: SetRect,
    sem: tree.Semantics,
};
/// 지금 **맨 위 화면**을 그리는 중인가. 서술자는 그때만 낸다.
///
/// 처음에는 `screenTop() == .terminal` 로 적었다 — 그때는 터미널 층만 서술자를 냈기 때문이다.
/// 화면이 늘면서 그 조건은 **「터미널이냐」가 아니라 「지금 그리는 것이 맨 위냐」**로 읽혀야 한다.
/// 빌드가 층마다 이 깃발을 세우므로, 새 화면이 서술자를 내기 시작해도 그 자리를 안 고쳐도 된다.
var a11y_top_layer = false;

/// 이번 프레임의 서술자. **프레임마다 다시 만든다** — 안 그리면 안 낸다는 것이 곧 계약이라
/// (`key_bar_rect` 가 0 을 답하는 규율과 같다), 남겨 두면 없는 것을 읽게 된다.
var a11y_nodes: [max_a11y_nodes]A11yNode = undefined;
var a11y_count: usize = 0;
const max_a11y_nodes = 128;

/// 지금 그린 면 하나를 접근성에 알린다. **폭이 0 이면 안 그려진 것**이라 안 낸다 — 이 파일의
/// rect 규율과 같은 판정이다(옛 자리를 답하면 없는 버튼이 읽힌다).
/// **읽는 순서로 세운다** — 위에서 아래로, 그다음 왼쪽에서 오른쪽으로.
///
/// 서술자가 나오는 순서는 **그리는 순서**다. 그대로 두면 스크린 리더로 훑을 때 앱 바에서
/// `뒤로 가기(x=0) → 자판(x=298) → 끊기(x=246)` 로 오른쪽에 갔다가 왼쪽으로 되돌아온다(실측).
/// 화면에는 아무 표시가 없고 **훑는 사람만** 겪는다.
///
/// **여기서 정하는 이유**: 순서를 host 가 각자 정하면 두 host 가 조용히 갈리고, 그 갈림은 스크린
/// 리더에게만 보인다(처음에는 iOS 어댑터에서 정렬했다가 Android 를 붙이며 이리로 옮겼다).
/// 그리고 좌우가 뒤집히는 언어를 알아야 할 자리도 결국 여기다 — 문구가 이 층에 있다.
///
/// 같은 줄인지는 **y 값이 같은가**로 잰다. 한 줄에 놓이는 사각형은 레이아웃이 같은 값을 주므로
/// (`term_bar_rect.y`·키바의 행 y) 이것이 참이고, 어림으로 재면 오히려 「a~b, b~c 인데 a≁c」가
/// 생겨 정렬 자체가 흐트러진다.
fn sortA11yForReading() void {
    const Less = struct {
        fn f(_: void, a: A11yNode, b: A11yNode) bool {
            if (a.rect.y != b.rect.y) return a.rect.y < b.rect.y;
            return a.rect.x < b.rect.x;
        }
    };
    std.mem.sort(A11yNode, a11y_nodes[0..a11y_count], {}, Less.f);
}

/// 서술자의 **이름·값 글자를 여기 복사해 둔다.**
///
/// 넘겨받은 슬라이스가 어디를 가리키는지 부르는 쪽마다 다르다 — 어떤 것은 i18n 표(영원하다),
/// 어떤 것은 목록 줄(다음 갱신에 바뀐다), 어떤 것은 **그리면서 만든 스택 버퍼**(이 함수가 돌아가는
/// 순간 사라진다)다. host 는 프레임이 **끝난 뒤에** 읽으므로, 복사하지 않으면 남의 메모리를 읽는다.
/// 프레임마다 비운다 — 서술자와 같은 수명이다.
/// **크기의 근거**(적대적 검증 2회차에서 실측했다): 한 화면에 목록 줄이 15개 서고, 그중 가장 긴
/// 줄이 이름+값 181바이트였다(제목·경로·git·agent 를 코어가 담는 자리 끝까지 채운 목록) — 약
/// 2.7 KiB 다. 세로가 더 긴 기기면 21줄까지 서므로 3.8 KiB 가 되어 4 KiB 로는 **여유가 5%** 였다.
/// 배로 둔다 — 넘치면 이름이 빈 것이 되고, 빈 이름은 host 가 요소를 아예 안 만들어 그 줄이
/// 스크린 리더에서 통째로 사라진다.
var a11y_text: [8192]u8 = undefined;
var a11y_text_len: usize = 0;

/// 글자를 담고 담은 자리를 답한다. 자리가 모자라면 **빈 것을 답하고 이름을 남긴다** — 조용히
/// 자르면 사용자가 그 반쪽을 값으로 읽는다(계약 §5).
fn a11yIntern(text: []const u8) []const u8 {
    if (text.len == 0) return "";
    if (a11y_text_len + text.len > a11y_text.len) {
        setLastError("a11y_text_overflow");
        return "";
    }
    const at = a11y_text[a11y_text_len..][0..text.len];
    @memcpy(at, text);
    a11y_text_len += text.len;
    return at;
}

/// 흐르는 목록의 줄처럼 **창에 갇힌 것**은 그 창으로 잘라서 낸다.
///
/// 화면에서는 헤더를 나중에 그려 지나간 줄을 덮지만 **서술자에는 덮개가 없다** — 자리를 그대로
/// 내면 스크린 리더가 헤더 자리에서 그 줄을 짚고, 톱니와 겹친다. 눈에는 안 보이고 훑는 사람만
/// 겪는 어긋남이라 판정자로만 잡힌다(적대적 검증 1회차).
fn noteA11yClipped(rect: SetRect, clip: SetRect, sem: tree.Semantics) void {
    const top = @max(rect.y, clip.y);
    const bottom = @min(rect.y + rect.h, clip.y + clip.h);
    if (bottom <= top) return; // 통째로 지나갔다 — 없는 것이다
    noteA11y(.{ .x = rect.x, .y = top, .w = rect.w, .h = bottom - top }, sem);
}

fn noteA11y(rect: SetRect, sem: tree.Semantics) void {
    if (rect.w <= 0 or rect.h <= 0) return;
    // **덮인 것은 안 낸다.** `buildUi` 는 어느 화면이든 터미널 층을 먼저 세우므로(코어 격자가
    // 살아 있어야 한다) 밀린 화면이 떠 있어도 앱 바·키바의 rect 는 서 있다. 그런데 그때
    // `chromePointer` 가 **모든 터치를 먹어서**(그 함수 끝의 `return 1`) 그 버튼들은 안 눌린다 —
    // 서술자만 내면 스크린 리더가 「자판」을 읽어 주고 짚어도 아무 일이 안 난다. 그것이 바로 이
    // 슬라이스가 막겠다고 한 「짚은 곳과 닿는 곳이 어긋나는 것」이다(적대적 검증 1회차에서 잡았다).
    //
    // 이것은 P1 의 「누를 수 없는 컨트롤도 자리와 이름은 있다」와 **다른 이야기**다. 그 말은 지금
    // 보이는 면 안의 꺼진 버튼(`enabled = false`)을 가리키고, 여기는 **다른 화면에 덮여 이 면에
    // 속하지도 않는** 것을 가리킨다.
    //
    // **누르는 쪽과 같은 조건을 본다** — 다른 식으로 적으면 또 갈린다.
    if (!a11y_top_layer) return;
    if (a11y_count >= a11y_nodes.len) {
        setLastError("a11y_overflow");
        return;
    }
    var owned = sem;
    owned.label = a11yIntern(sem.label);
    owned.value = a11yIntern(sem.value);
    a11y_nodes[a11y_count] = .{ .rect = rect, .sem = owned };
    a11y_count += 1;
}

/// 이번 프레임의 서술자 개수. **build 뒤에 읽는다.**
pub export fn maru_mobile_a11y_count() u32 {
    return @intCast(a11y_count);
}

/// 서술자 하나의 자리. `maru_mobile_keybar_rect` 와 **같은 꾸림**(x<<48|y<<32|w<<16|h)이라
/// host 가 두 가지 푸는 법을 안 익혀도 된다. 없는 index 는 0.
pub export fn maru_mobile_a11y_rect(index: u32) u64 {
    if (index >= a11y_count) return 0;
    const r = a11y_nodes[index].rect;
    const x: u64 = @intFromFloat(@max(0, r.x));
    const y: u64 = @intFromFloat(@max(0, r.y));
    const w: u64 = @intFromFloat(@max(0, r.w));
    const h: u64 = @intFromFloat(@max(0, r.h));
    return (x << 48) | (y << 32) | (w << 16) | h;
}

/// **wire 로 나가는 역할 번호.** 계약 enum(`chrome/ui/semantics.zig` 의 `Role`)의 순번을 그대로
/// 내보내지 않는 이유: 그 enum 에 줄을 하나 끼워 넣는 순간 host 가 **조용히 다른 역할**을 읽는다
/// (데스크톱 ABI 도 같은 이유로 제 번호를 따로 든다). 번호의 단일 출처는 `mobile_host_abi.h` 이고,
/// 아래 switch 가 **빠짐없이** 적혀 있어서 계약에 역할이 늘면 여기서 컴파일이 멈춘다.
const WireRole = enum(u32) {
    button = 0,
    tree_item = 1,
    list_item = 2,
    tab = 3,
    scroll_view = 4,
    text = 5,
    group = 6,

    fn from(role: tree.SemanticRole) WireRole {
        return switch (role) {
            .button => .button,
            .tree_item => .tree_item,
            .list_item => .list_item,
            .tab => .tab,
            .scroll_view => .scroll_view,
            .text => .text,
            .group => .group,
        };
    }
};

/// 역할(`mobile_host_abi.h` 의 `MARU_MOBILE_A11Y_ROLE_*`). 없는 index 는 0xFFFF_FFFF.
pub export fn maru_mobile_a11y_role(index: u32) u32 {
    if (index >= a11y_count) return 0xFFFF_FFFF;
    return @intFromEnum(WireRole.from(a11y_nodes[index].sem.role));
}

/// 상태 비트. **한 번에 읽어 간다** — 항목마다 호출을 넷 하면 host 코드가 그만큼 길어지고,
/// 그 사이에 프레임이 바뀌면 서로 다른 프레임의 값을 섞는다.
/// bit0 enabled · bit1 selected · bit2 focusable · bit3 expanded 를 아는가 · bit4 expanded 값.
pub export fn maru_mobile_a11y_state(index: u32) u32 {
    if (index >= a11y_count) return 0;
    const s = a11y_nodes[index].sem;
    var bits: u32 = 0;
    if (s.enabled) bits |= 1;
    if (s.selected) bits |= 2;
    if (s.focusable) bits |= 4;
    if (s.expanded) |e| {
        bits |= 8;
        if (e) bits |= 16;
    }
    return bits;
}

/// 이름·값을 `out` 에 복사하고 **쓴 바이트 수**를 답한다. **복사한다** — 가리키는 것은 다음
/// 프레임에 사라질 수 있고, host 가 그 뒤에 읽으면 남의 메모리를 읽는다.
///
/// `cap == 0` 이면 아무것도 안 쓰고 **필요한 길이**를 답한다(먼저 물어보고 담을 자리를 잡는 법).
///
/// **UTF-8 한가운데서는 안 끊는다.** 「뒤로 가기」는 13바이트라 cap 이 12 면 마지막 글자가 반쪽이
/// 되는데, 그 조각을 받은 iOS `initWithBytes:encoding:NSUTF8StringEncoding` 은 **nil 을 답한다** —
/// 이름이 통째로 사라져 VoiceOver 가 「버튼」이라고만 읽는다(Android 는 U+FFFD 를 읽어 준다).
/// 짧게 읽히는 것과 **안 읽히는 것**은 다르므로 마지막 온전한 글자까지만 준다.
fn copyA11yText(text: []const u8, out: [*]u8, cap: usize) usize {
    if (cap == 0) return text.len;
    var n = @min(text.len, cap);
    // 이어지는 바이트(0b10xxxxxx)에 멈춰 있으면 그 글자가 시작한 자리까지 물러선다.
    while (n > 0 and n < text.len and (text[n] & 0xC0) == 0x80) n -= 1;
    @memcpy(out[0..n], text[0..n]);
    return n;
}

pub export fn maru_mobile_a11y_label(index: u32, out: [*]u8, cap: usize) usize {
    if (index >= a11y_count) return 0;
    return copyA11yText(a11y_nodes[index].sem.label, out, cap);
}

/// **값은 이름과 따로 읽힌다.** 스크린 리더는 둘을 다른 시점에 읽고, 값만 바뀌었을 때 이름을 다시
/// 읽지 않는다 — 「서버 3」처럼 이어 붙이면 3 이 바뀔 때마다 **이름이 바뀐 것**이 된다(계약
/// `Semantics.value` 가 그 이유를 소유한다). 없으면 0 이다.
pub export fn maru_mobile_a11y_value(index: u32, out: [*]u8, cap: usize) usize {
    if (index >= a11y_count) return 0;
    return copyA11yText(a11y_nodes[index].sem.value, out, cap);
}

/// 판정자가 보는 서술자 한 줄. `A11yNode` 를 그대로 내면 그 타입이 밖으로 새므로 뷰만 낸다.
pub const A11yNodeView = A11yNode;

/// 판정자용 — 이번 프레임의 서술자를 그대로 본다.
pub fn a11yNodesForTest() []const A11yNodeView {
    return a11y_nodes[0..a11y_count];
}

// ── 안 바뀐 프레임은 GPU 를 안 쓴다 (M14) ────────────────────────────────────
//
// **깃발을 세우지 않고 결과를 비교한다.** 「바꾸는 자리마다 dirty 를 세운다」는 export 가
// 아흔 개라 하나만 빠뜨려도 화면이 언다 — 이 저장소가 그 모양으로 두 번 물렸다(전역 output
// 게이트가 커서 위상을 굶겼고, sync 게이트가 스크롤 리페인트를 막았다). 낸 quad 를 지난
// 프레임과 견주면 **빠뜨릴 목록이 없다**: 화면에 보이는 변화는 반드시 quad 를 바꾼다.
//
// **빌드는 그대로 매 tick 돈다.** 건너뛰는 것은 GPU(획득·제출·프레젠트)뿐이라, 빌드 안에서
// 도는 시간 축(관성 감쇠·길게 누름 승격·아틀라스 축출 순번)은 하나도 안 멈춘다. 그것들이
// 화면을 바꾸면 그 프레임은 자동으로 "바뀜" 이 된다.
var prev_quads: []MaruQuad = &.{};
var prev_quad_count: usize = 0;
/// 이번 프레임이 지난 프레임과 다른가. 첫 프레임은 **그린 적이 없으므로** 다르다.
var frame_changed: bool = true;
/// 이번 build 가 낸 그림이 지난 프레임과 다른가(1=그려야 한다). **build 뒤에 읽는다.**
pub export fn maru_mobile_frame_changed() u32 {
    return if (frame_changed) 1 else 0;
}

fn noteFrameChanged() void {
    const now = quad_buf[0..quad_count];
    const before = prev_quads[0..@min(prev_quad_count, prev_quads.len)];
    // **바이트로 견준다.** `MaruQuad` 는 `extern struct` 라 패딩 없는 평평한 값이고, 그래서
    // 「같은 그림인가」가 「같은 바이트인가」와 정확히 같은 물음이 된다(`std.mem.eql` 은 구조체에
    // `!=` 를 못 쓴다).
    frame_changed = now.len != before.len or
        !std.mem.eql(u8, std.mem.sliceAsBytes(now), std.mem.sliceAsBytes(before));
    if (!frame_changed) return;
    // 바뀐 프레임만 기억한다 — 안 바뀌었으면 지난 것이 이미 그 값이다.
    if (prev_quads.len < now.len) {
        const grown = term_allocator.realloc(prev_quads, now.len) catch {
            // **못 기억하면 다음 프레임도 "바뀜" 이다.** 안전한 쪽으로 넘어진다 — 화면이 어는
            // 것보다 한 프레임 더 그리는 것이 낫다.
            prev_quad_count = 0;
            return;
        };
        prev_quads = grown;
    }
    @memcpy(prev_quads[0..now.len], now);
    prev_quad_count = now.len;
}

/// 판정자용 — 다음 프레임을 "처음 그리는 것" 으로 되돌린다.
pub fn resetFrameCompareForTest() void {
    prev_quad_count = 0;
    frame_changed = true;
}

/// 판정자용 — **화면 스택을 그 화면 하나로 맞춘다.** 제품 경로는 손짓으로만 옮기는데(탭·뒤로가기),
/// 「화면을 옮기면 달라지는가」를 재려면 **옮긴 것이 확실해야** 한다.
///
/// 미는 것이 아니라 **맞추는** 이유: `nav` 는 넉 장뿐이라 앞선 판정자가 채워 두면 미는 것이
/// 조용히 무동작이 되고(`navPush` 의 이른 return), 그러면 판정자는 「옮겼다」고 믿은 채 **안 옮긴
/// 것**을 잰다. 뿌리가 `.sessions` 이고 그 위가 다 `.terminal` 이라 터미널을 재는 판정자는 그래도
/// 초록이어서 **아무도 안 알려 준다** — 실제로 그 함정에 두 번 걸렸다(M14 는 붉게, M9 는 초록으로).
pub fn setScreenForTest(name: []const u8) void {
    inline for (@typeInfo(Screen).@"enum".fields) |f| {
        if (std.mem.eql(u8, f.name, name)) {
            const s: Screen = @enumFromInt(f.value);
            if (s == .sessions) {
                nav_len = 1; // 뿌리는 목록이다
            } else {
                nav[1] = s;
                nav_len = 2;
            }
            syncKeyboardForScreen();
        }
    }
}

pub export fn maru_mobile_last_error() [*:0]const u8 {
    return @ptrCast(&last_error);
}

/// 플랫폼이 읽고 나서 부른다. 비우는 자리를 읽는 쪽에 두어야 **프레임 사이에 난 실패**도
/// 반드시 한 번은 눈에 띈다. 같은 오류가 계속 나면 호스트의 "바뀔 때만 로그"가 걸러 준다.
pub export fn maru_mobile_clear_error() void {
    @memset(&last_error, 0);
}

/// **매 프레임 다시 물어야 한다.** 버퍼가 자라면 주소가 바뀐다(격자가 커질 때만 자란다).
pub export fn maru_mobile_quads() [*]const MaruQuad {
    return quad_buf.ptr;
}

/// 지금 용량. 플랫폼이 GPU 버퍼를 이만큼 잡으면 잘릴 일이 없다. 상한을 host 마다 손으로 적어
/// 두면 어긋난다 — 실제로 iOS 는 늘리고 Android 는 4096 에서 **조용히 자르고** 있었다.
///
/// build **뒤에** 읽는다. 그 프레임에 늘어났다면 플랫폼 버퍼가 아직 작으므로, 플랫폼은 자기
/// 버퍼를 키우고(iOS) 또는 자원을 다시 세우고(Android) 그 프레임은 건너뛴다.
pub export fn maru_mobile_max_quads() u32 {
    // **0 은 답이 될 수 없다.** 플랫폼은 이 값으로 GPU 버퍼를 잡는데, Android 는 창이 서는
    // 순간(=첫 build 보다 먼저) 한 번 잡는다. 빈 슬라이스인 채로 0 을 돌려줬더니 크기 0 짜리
    // VkBuffer 를 만들었고 드라이버가 `pCreateInfo->size > 0` 단언에서 **에뮬레이터를 통째로
    // abort** 시켰다. 처음 물어보면 그때 잡는다.
    if (quad_buf.len == 0) _ = reserveQuad();
    return @intCast(quad_buf.len);
}
