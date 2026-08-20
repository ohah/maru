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

/// `#RRGGBB` 를 토큰 색으로. 값이 틀리면 fallback — 파싱이 이미 forgiving 이라 여기 오는 값은
/// 대개 맞지만, 색은 **화면이 통째로 검게 될 수 있는 자리**라 마지막까지 기본값을 지킨다.
fn hex(text: []const u8, fallback: color.Rgb) color.Rgb {
    return color.parseHex(text) orelse fallback;
}
/// 원격에서 받아 코어에 **닿은** 누적 바이트. host 가 "출력이 죽었나" 를 이 값으로 판정한다.
var term_written: usize = 0;
var term_cols: u16 = 0;
var term_rows: u16 = 0;

/// 실제 셸 세션이 낼 법한 바이트열. 색·굵기·한글이 섞여 있어야 코어를 통과했다는 게
/// 화면에서 드러난다.
const term_feed =
    "$ zig build test\r\n" ++
    "\x1b[32mAll 11 passed.\x1b[0m\r\n" ++
    "$ git status --short\r\n" ++
    "\x1b[33m M \x1b[0msrc/chrome/ui/tree.zig\r\n" ++
    "$ maru \x1b[36m0.1.0\x1b[0m (arm64)\r\n" ++
    "\x1b[35m한글 터미널\x1b[0m 세션 목록\r\n" ++
    "$ \x1b[1m설정 검색 알림\x1b[0m\r\n" ++
    // TUI 한 줄. 박스 드로잉·블록·브라유는 maru 가 **폰트 대신 절차 합성**하는 것들이라
    // (renderer.synthesizeGlyph) 화면에 이게 제대로 나오는지가 곧 합성 경로가 서 있는지다.
    "┌──┬──┐ █▄▀░ ⠿⠇\r\n" ++
    "│ab│cd│\r\n" ++
    // SGR 한 줄. 코어가 셀에 담는 속성이 화면까지 오는지 보는 자리다 — 배경(44)·반전(7)·
    // 밑줄(4)·굵게(1). 예전에는 전경색만 읽어서 넷 다 평범한 글자로 나왔다.
    "\x1b[44m bg \x1b[0m\x1b[7m rev \x1b[0m\x1b[4m under \x1b[0m\x1b[1m bold \x1b[0m\r\n" ++
    // 나머지 속성도 한 줄에 모은다 — **만들고 화면으로 안 본 것을 남기지 않으려고** 넣었다.
    // `hid`(8)는 안 보이는 것이 정답이고, `ucol`(58)은 밑줄만 빨갛다.
    "\x1b[2mdim\x1b[0m \x1b[3mital\x1b[0m \x1b[21mdbl\x1b[0m \x1b[9mst\x1b[0m " ++
    "\x1b[53move\x1b[0m \x1b[4;58;5;196mucol\x1b[0m \x1b[8mhid\x1b[0m|\r\n" ++
    // 이모지 한 줄. BMP 밖 글자(서러게이트 쌍)와 **컬러 아틀라스**가 서 있는지가 화면에서
    // 드러난다 — 이 줄이 없으면 이모지가 빈칸이던 것도 화면으로는 못 봤다(M4a6).
    //
    // 뒤의 셋은 **host 굽기 경로의 시각 판정자**다(계약 테스트가 못 닿는 자리라 이 줄이 유일한
    // 판정자다):
    //   - `\u{2764}`(❤) — 번들 폰트에 **없는** 기호. 시스템 폰트 폴백이 빠지면 빈칸이 된다.
    //   - `\u{2764}\u{FE0F}`(❤️) — 같은 base 에 VS16 이 붙은 **클러스터**. 브리지가 열을 안
    //     넘기거나 host 가 열을 문자열로 안 이으면 **앞의 ❤ 와 똑같이** 그려진다. 즉 이 둘이
    //     **나란히 달라 보여야** 클러스터 경로가 산 것이다.
    //   - `\u{1D400}`(𝐀) — **BMP 밖 비컬러** 글자. 서러게이트 쌍 조립이 빠지면 엉뚱한 글자가 된다.
    // 셋 다 컬러 이모지와 **다른 경로**를 타므로 이모지만 보고는 회귀를 못 잡는다.
    "emoji \u{1F600}\u{1F389}\u{1F680} + 한글 가나 \u{2764} \u{2764}\u{FE0F} \u{1D400}\r\n";

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
    // 오류가 없으면 진행 상태다. **붙은 뒤에는 아무 말도 안 한다** — 화면이 곧 답이다.
    if (conn_state == 0 or conn_state == 11) return null;
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
            _ = body_press.end(); // 본문에는 탭이 없다 — 결과를 안 쓴다
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
/// 그 뒤로가기가 지금 눌려 있나.
var term_back_pressed: bool = false;
/// 터미널 앱 바의 제스처. 다른 표면과 같은 규칙을 쓴다(§3.1).
var term_press: gesture.Press = .{};
/// 레이아웃 트리에서 앱 바를 가리키는 id. 키바 id 대역과 안 겹치게 둔다.
const term_bar_id: u64 = 400;

var key_bar_band: struct { top: f32 = 0, bot: f32 = 0 } = .{};
var key_bar_max_scroll: f32 = 0;
/// 가로 스크롤 오프셋(양수 = 왼쪽으로 밀림).
/// 키바 가로 스크롤도 **컴포넌트가 든다**(설정 목록과 같은 규칙 — 축만 다르다). 예전에는 여기
/// 감쇠·임계가 손으로 있었고 설정 목록에도 같은 숫자가 또 있었다.
var kb_sa: scroll_area.State = .{};
/// 이번 짚음이 **관성을 세운 것**인가. 그렇다면 키를 안 보낸다.
var kb_touch: scroll_area.Touch = .{};
/// 손을 뗀 뒤 남은 가로 관성(프레임당 논리 px).
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
/// — 소유 판정은 이미 표면마다 자기 손가락으로 한다(`kb_touch.owner`·`body_owner`·
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
        const bh: f32 = 30;
        const by = term_bar_rect.y + term_bar_rect.h;
        push(.{ .x = @intFromFloat(term_bar_rect.x), .y = @intFromFloat(by), .w = @intFromFloat(term_bar_rect.w), .h = @intFromFloat(bh) }, tk.get(.tab_hover_bg), 0xFF, 0, 0);
        // 실패는 강조색, 진행 중은 흐린 색 — 같은 자리에 두되 **읽는 무게가 다르다**.
        const role: tokens.ColorRole = if (conn_err_len > 0) .accent_bar else .muted_fg;
        pushText(msg, @intFromFloat(term_bar_rect.x + set_pad_x), @intFromFloat(by + (bh - 14) / 2), 14, tk.get(role));
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
    term_copy_rect = .{};
    if (copyEnabled()) {
        term_copy_rect = .{ .x = term_bar_rect.x + term_bar_rect.w - set_head_h, .y = term_bar_rect.y, .w = set_head_h, .h = set_head_h };
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
    const armed = key_bar[i].sticky_mod != 0 and armed_mods != 0;
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

/// 지금 키바 가로 위치(px).
fn kbScroll() f32 {
    return @floatFromInt(kb_sa.offset_y_px);
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
    const x = body_rect.x + @as(f32, @floatFromInt(@as(i32, cur.col) * body_cell_w));
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
    const line_h: i32 = @intCast(cfg().font.size);
    const scale = @as(f32, @floatFromInt(line_h)) / @as(f32, @floatFromInt(atlas_cell_h));
    const cell_w: i32 = @max(1, @as(i32, @intFromFloat(@as(f32, @floatFromInt(atlas_cell_w)) * scale * 0.5)));
    // chrome 라벨은 아직 예전 크기를 쓴다(본문 격자와 별개 — `pushText`).
    const font_px: i32 = 15;
    const cols_f = @divTrunc(@as(i32, @intFromFloat(rect.width)), cell_w);
    const rows_f = @divTrunc(@as(i32, @intFromFloat(rect.height)), line_h);
    const cols: u16 = @intCast(@max(8, @min(max_cols, cols_f)));
    const rows: u16 = @intCast(@max(2, @min(max_rows, rows_f)));

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
        term_core.?.write(term_feed) catch setLastError("core_write_feed");
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
            const cx = ox + @as(i32, cur.col) * cell_w;
            // 격자와 **같은 식**으로 y 를 낸다 — 따로 계산하면 한 줄씩 어긋난다.
            const cy = oy + @as(i32, cur.row) * line_h;
            const rgb = tk.get(.cursor);
            const shape = snap.cursor_shape;
            // **2셀 글자 위에서는 두 칸을 덮는다.** 한 칸만 덮으면 한글 절반에만 걸려
            // "커서가 글자 가운데 있는" 모양이 된다(글자 폭은 코어가 정한 값을 쓴다).
            // continuation 칸(width 0)에 놓이면 한 칸이다 — 코어가 거기 커서를 두지 않는다.
            const cur_cell = snap.cells[core.index(cur.row, cur.col)];
            const cur_w = if (cur_cell.width == 2) cell_w * 2 else cell_w;
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
    if (preedit_len > 0) {
        const cur = core.screen.cursor;
        const px = @as(i32, @intFromFloat(rect.x)) + @as(i32, cur.col) * cell_w;
        const py = @as(i32, @intFromFloat(rect.y)) + @as(i32, cur.row) * line_h;
        const dim = tk.get(.muted_fg);
        pushText(preedit_buf[0..preedit_len], px, py, font_px, dim);
    }
}

/// 데스크톱 기본 테마에 가까운 값. **아직 config 를 안 읽는다** — 모바일이 config 를
/// 어디서 받을지가 원격 연결(M3)과 함께 정해진다.
fn themeColors() tokens.ThemeColors {
    const t = cfg().theme;
    return .{
        .foreground = hex(t.foreground, .{ .r = 0xE6, .g = 0xE6, .b = 0xEA }),
        .sidebar_background = .{ .r = 0x24, .g = 0x24, .b = 0x2E },
        .sidebar_foreground = .{ .r = 0xD0, .g = 0xD0, .b = 0xD8 },
        .sidebar_active = .{ .r = 0x3A, .g = 0x3A, .b = 0x4A },
        .search_match = .{ .r = 0x4A, .g = 0x4A, .b = 0x20 },
        .search_match_current = .{ .r = 0x8A, .g = 0x7A, .b = 0x20 },
        .selection = hex(t.selection, .{ .r = 0x30, .g = 0x40, .b = 0x60 }),
        // **터미널 본문 배경은 사이드바와 별개 입력이다**(tokens.zig §4.1b). `theme.background`
        // 가 그 자리다 — 사이드바는 chrome 색이라 따로 둔다.
        .terminal_background = hex(t.background, .{ .r = 0x1E, .g = 0x1E, .b = 0x2E }),
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
    const cap: u32 = @intFromFloat(@as(f32, @floatFromInt(atlas_cell_h)) * 0.7);
    return @min(cfg().font.size, @max(1, cap));
}

/// 굽는 크기가 바뀌면 **등록부를 비운다** — 그래야 다음 프레임부터 놓친 글자로 올라와 새 크기로
/// 다시 구워진다. 슬롯 자체는 host 가 덮어쓰므로 여기서 지우는 것은 "어느 글자가 어디 있나" 뿐이다.
var atlas_baked_px: u32 = 0;
fn resetAtlasIfTextSizeChanged() void {
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
fn textWidth(text: []const u8, font_px: i32) i32 {
    const scale = @as(f32, @floatFromInt(font_px)) / @as(f32, @floatFromInt(atlas_cell_h));
    const half_w = @as(f32, @floatFromInt(atlas_cell_w)) * scale * 0.5;
    var w: i32 = 0;
    // **조용히 0 을 답하지 않는다**(§5). 여기서 실패하면 그 글은 폭이 0 이라 자리를 안 차지하고,
    // 바로 아래 `pushText` 도 같은 이유로 아무것도 안 그려 **글이 통째로 사라진 것처럼** 보인다.
    // 평상시에는 안 난다 — 나면 절삭이나 host 인코딩이 깨진 것이라 알아야 한다.
    var view = std.unicode.Utf8View.init(text) catch {
        setLastError("text_bad_utf8");
        return 0;
    };
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (isZeroWidthFormat(cp)) continue;
        const cell = atlasCell(&.{cp}, 0);
        // **폴백 폭도 `pushText` 와 같이 폭을 본다.** 여기만 반칸으로 두면 아직 안 구운
        // 한글이 든 값이 절반 폭으로 재져 **우측 정렬이 여백 밖으로 밀린다**(다음 프레임에
        // 글리프가 구워지며 제자리로 돌아와 더 눈에 띈다).
        const draw_w: i32 = @intFromFloat(if (maru.width.cellWidth(cp) == 2) half_w * 2 else half_w);
        w += if (cell) |c|
            @as(i32, @intFromFloat(@as(f32, @floatFromInt(c.adv)) * scale))
        else
            @divTrunc(draw_w, 2);
    }
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
    const body = tree.container(.{ .id = 300, .direction = .column, .style = .{ .flex = .{ .grow = 1 }, .padding = .{ .left = 16.0, .right = 16.0, .top = 14.0, .bottom = 14.0 } } }, &.{});

    // ── 하단 바는 **없다.** 아이콘 다섯은 배선이 없었고(U3a), 남은 톱니 하나를 위해 44px 를
    // 영구히 쓰는 것은 두 플랫폼 관례도 아니다 — 하단은 이동 대상(destination) 자리이고
    // 동작은 앱 바 오른쪽·오버플로가 관례다. 설정 입구는 부모 화면(세션 목록)으로 갔고,
    // 그만큼이 본문으로 돌아왔다.

    // ── 보조 키바: 소프트 키보드에 없는 키들(Ctrl·Esc·Tab·화살표) + 셸 문장부호
    //
    // **레이아웃은 자리만 잡고 키는 브리지가 직접 그린다.** 키가 손가락 크기(44)라 화면을 넘쳐
    // 가로 스크롤이 필요한데, `tree` 는 스크롤 개념이 없고 음수 margin 으로 밀면 레이아웃이
    // `error.NegativeValue` 로 거부한다(실측 — 화면이 통째로 검게 나갔다). `chrome/ui/scroll_area`
    // 는 세로 전용이라 여기 못 쓴다. 키바는 "고정 크기 버튼의 가로 나열" 이라 엔진 없이도
    // 그릴 수 있고, 스크롤·클리핑을 직접 쥐는 편이 낫다 — **U1 이 닫을 공백이 여기 남는다**
    // (컴포넌트 계층에 가로 스크롤이 생기면 이 직접 그리기를 그쪽으로 옮긴다).
    // **줄에서 빠지는 키는 없다.** 조건부로 나타나는 키를 두면 나머지가 밀려 손가락이 겨눈
    // 자리가 바뀐다 — `copy` 도 늘 있고 못 쓸 때만 흐리다.
    const bar_n: usize = key_bar.len;
    // 자식 없는 카드 하나가 **밴드 자리**만 잡는다. 키는 아래에서 직접 그린다.
    const bar = tree.card(.{
        .id = key_bar_id_base - 1,
        // **줄 수만큼 높다.** 숫자를 손으로 적으면 키를 더했을 때 아래 줄이 잘린다.
        .style = .{ .width = .{ .percent = 1.0 }, .height = .{ .px = @as(f32, @floatFromInt(key_bar_rows)) * (key_h + key_gap) + 10.0 } },
    }, &.{});

    // ── 상단 앱 바: **돌아갈 길이 보여야 한다.** U3b 가 하단 바를 걷어내며 터미널 화면의
    // chrome 을 통째로 없앴고, 남은 길은 가장자리 스와이프뿐이 됐다 — iOS 관례지만 **보이지
    // 않고**, Android 는 시스템 뒤로가기가 따로 있어 같은 화면이 두 플랫폼에서 다르게 읽힌다
    // (사용자 요청). 높이는 **다른 화면과 같은 값**이다 — 화면마다 다르면 옮길 때 본문이 튄다.
    const app_bar = tree.card(.{
        .id = term_bar_id,
        .style = .{ .width = .{ .percent = 1.0 }, .height = .{ .px = set_head_h } },
    }, &.{});

    const root = tree.container(.{ .id = 1, .direction = .column }, &.{ app_bar, body, bar });

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
        const cell_w = band_w / @as(f32, @floatFromInt(key_bar_cols));
        const kw = @floor(cell_w) - key_gap;
        for (0..key_bar.len) |i| {
            const col = i % key_bar_cols;
            const row = i / key_bar_cols;
            const kx = @floor(band_x + @as(f32, @floatFromInt(col)) * cell_w + key_gap / 2);
            const ky = @floor(band.y + 5.0 + @as(f32, @floatFromInt(row)) * (key_h + key_gap));
            key_bar_rects[i] = .{ .x = kx, .y = ky, .w = kw, .h = key_h };
            drawKey(i, kx, ky, kw, tk);
        }
        // **스크롤 표시(`<`/`>`)는 없앴다** — 두 줄 격자라 전부 한눈에 들어와서 "더 있다" 를
        // 알릴 것이 없다. 남겨 두면 아무 데도 안 미는 화살표가 가장자리 칸을 먹는다.
        key_bar_ready = bar_n > 0;
    }

    // **본문은 진짜 터미널 코어다.** 레이아웃이 잡아 준 본문 사각형에 셀 격자를 채운다.
    for (built.entries) |entry| {
        if (entry.id != 300) continue;
        pushTerminal(entry.rect, tk);
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

const Screen = enum { sessions, terminal, settings, servers, server_edit, password, host_key };

/// **화면 스택이다**(UX §3 — "모달을 안 쓴다, 라우터 하나다"). 단일 변수로 두면 화면이 늘 때
/// "어디로 돌아가나" 를 분기마다 다시 적게 되고, 그 분기 하나를 빠뜨리면 뒤로가기가 갈 곳을
/// 잃는다. 깊이는 셋이면 충분하다(목록 → 터미널, 목록 → 설정).
var nav: [4]Screen = .{ .sessions, .terminal, .terminal, .terminal };
/// 스택에 실제로 쌓인 수. **앱은 터미널에서 시작한다** — 세션 목록은 그 아래에 있고 뒤로
/// 가면 나온다. 매번 목록을 거치게 하면 이 앱의 주 용도에 탭이 하나 더 붙는다.
var nav_len: usize = 2;

/// 지금 보이는 화면 — 스택의 꼭대기다.
fn screenTop() Screen {
    return nav[nav_len - 1];
}

/// 화면을 민다. 스택이 꽉 차면 안 민다(그럴 일은 없지만 조용히 덮어쓰는 것보다 낫다).
fn navPush(s: Screen) void {
    if (nav_len >= nav.len) return;
    nav[nav_len] = s;
    nav_len += 1;
}

/// 한 장 뺀다. **뿌리는 안 뺀다** — 스택이 비면 그릴 화면이 없다.
fn navPop() void {
    if (nav_len > 1) nav_len -= 1;
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
var sess_pressed: enum { none, gear, row, servers } = .none;
/// 서버 목록으로 들어가는 줄. **여기서 들어간다** — UX 계약(§2.1)은 서버 목록을 세션 목록
/// *위*에 두지만, 뿌리를 바꾸면 앱이 뜨는 자리와 뒤로가기 스택이 함께 움직인다(그 재배치는
/// 다중 세션 U2 가 든다). 그때까지는 이 줄이 그 화면의 입구다.
var sess_servers_rect: SetRect = .{};
/// 세션 목록의 제스처. **설정 화면과 나눠 쓰지 않는다** — 전에는 `set_active`·`set_moved` 를
/// 그대로 썼고(한 번에 한 화면만 떠서 동작하기는 했다), 이름이 거짓말을 하는 데다 둘 중
/// 하나를 고치면 다른 하나가 조용히 바뀐다.
var sess_press: gesture.Press = .{};

/// 세션 목록. **이 앱의 뿌리 화면이다**(UX §2.2). 지금 실을 수 있는 것은 **진짜 세션 하나**뿐이라
/// 한 줄이다 — 목록을 채워 보이려고 없는 세션을 그리지 않는다(계약 §2.4 가 경고한 자리이고,
/// 실제로 그렇게 그린 탭 셋을 U3a 에서 걷어냈다). 서버 목록·연결 진단은 **서버가 0개**이므로
/// 만들지 않는다 — M3 가 "서버를 등록한다" 를 정하면 그때 선다.
///
/// **설정 입구가 여기다.** 하단 상시 바는 두 플랫폼 관례가 아니고(하단은 이동 대상 자리다),
/// 키보드가 거의 늘 떠 있는 터미널에서 44px 를 영구히 쓴다. 관례대로 **부모 화면의 앱 바
/// 오른쪽**에 둔다.
fn drawSessions(win: SetRect, tk: *const tokens.Tokens) void {
    push(.{ .x = @intFromFloat(win.x), .y = @intFromFloat(win.y), .w = @intFromFloat(win.w), .h = @intFromFloat(win.h) }, tk.get(.surface_bg), 0xFF, 0, 0);

    // ── 헤더: 제목 + 오른쪽 톱니
    pushText(maru.i18n.tIn(.ko, .mob_sessions), @intFromFloat(win.x + 16), @intFromFloat(win.y + (set_head_h - 20) / 2), 20, tk.get(.surface_fg));
    sess_gear_rect = .{ .x = win.x + win.w - set_head_h, .y = win.y, .w = set_head_h, .h = set_head_h };
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

    // ── 줄 하나: 지금 있는 세션. **48 이 아니라 56 이다** — 나중에 `cwd`·상태가 두 번째 줄로
    // 붙을 자리이고(M3), 그때 높이가 바뀌면 손가락이 겨눈 자리가 움직인다.
    const row_h: f32 = 56;
    sess_row_rect = .{ .x = win.x, .y = win.y + set_head_h + 1, .w = win.w, .h = row_h };
    if (sess_pressed == .row) push(.{ .x = @intFromFloat(sess_row_rect.x), .y = @intFromFloat(sess_row_rect.y), .w = @intFromFloat(sess_row_rect.w), .h = @intFromFloat(sess_row_rect.h) }, tk.get(.tab_hover_bg), 0xFF, 0, 0);
    pushText(session_title, @intFromFloat(sess_row_rect.x + 16), @intFromFloat(sess_row_rect.y + (row_h - 17) / 2), 17, tk.get(.surface_fg));
    push(.{ .x = @intFromFloat(sess_row_rect.x), .y = @intFromFloat(sess_row_rect.y + row_h), .w = @intFromFloat(sess_row_rect.w), .h = 1 }, tk.get(.divider), 0xFF, 0, 0);
    drawServersEntry(win, tk, row_h);
}

/// 세션 화면 아래에 붙는 **서버 목록 입구**. 화면을 나눠 그리는 이유는 하나다 — 세션 줄과
/// 이 줄은 뜻이 다르다(하나는 지금 보고 있는 것, 하나는 붙을 수 있는 것).
fn drawServersEntry(win: SetRect, tk: *const tokens.Tokens, row_h: f32) void {
    // ── 서버 목록 입구. **개수를 함께 적는다** — 0 이면 들어가서야 비었음을 알게 되고, 그
    // 화면이 무엇을 담는지도 안 보인다.
    sess_servers_rect = .{ .x = win.x, .y = sess_row_rect.y + row_h + 1, .w = win.w, .h = row_h };
    if (sess_pressed == .servers) push(.{ .x = @intFromFloat(sess_servers_rect.x), .y = @intFromFloat(sess_servers_rect.y), .w = @intFromFloat(sess_servers_rect.w), .h = @intFromFloat(sess_servers_rect.h) }, tk.get(.tab_hover_bg), 0xFF, 0, 0);
    pushText(maru.i18n.tIn(.ko, .mob_servers), @intFromFloat(sess_servers_rect.x + 16), @intFromFloat(sess_servers_rect.y + (row_h - 17) / 2), 17, tk.get(.surface_fg));
    var cnt: [8]u8 = undefined;
    const cnt_text = std.fmt.bufPrint(&cnt, "{d}", .{servers().len}) catch "?";
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
    pushText(fp[0..half], @intFromFloat(win.x + set_pad_x), @intFromFloat(y), 15, tk.get(.surface_fg));
    y += 22;
    pushText(fp[half..], @intFromFloat(win.x + set_pad_x), @intFromFloat(y), 15, tk.get(.surface_fg));
    y += 34;

    hk_ok_rect = .{ .x = win.x, .y = y, .w = win.w, .h = set_row_h };
    if (hk_pressed == .ok) push(.{ .x = @intFromFloat(hk_ok_rect.x), .y = @intFromFloat(hk_ok_rect.y), .w = @intFromFloat(hk_ok_rect.w), .h = @intFromFloat(hk_ok_rect.h) }, tk.get(.tab_hover_bg), 0xFF, 0, 0);
    pushText(maru.i18n.tIn(.ko, .mob_hostkey_ok), @intFromFloat(win.x + set_pad_x), @intFromFloat(y + (set_row_h - 16) / 2), 16, tk.get(.accent_bar));
    y += set_row_h;
    hk_cancel_rect = .{ .x = win.x, .y = y, .w = win.w, .h = set_row_h };
    if (hk_pressed == .cancel) push(.{ .x = @intFromFloat(hk_cancel_rect.x), .y = @intFromFloat(hk_cancel_rect.y), .w = @intFromFloat(hk_cancel_rect.w), .h = @intFromFloat(hk_cancel_rect.h) }, tk.get(.tab_hover_bg), 0xFF, 0, 0);
    pushText(maru.i18n.tIn(.ko, .mob_hostkey_cancel), @intFromFloat(win.x + set_pad_x), @intFromFloat(y + (set_row_h - 16) / 2), 16, tk.get(.surface_fg));
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
    pushText(shown, @intFromFloat(win.x + set_pad_x), @intFromFloat(y), 20, tk.get(role));
    y += 40;
    push(.{ .x = @intFromFloat(win.x + set_pad_x), .y = @intFromFloat(y), .w = @intFromFloat(win.w - set_pad_x * 2), .h = 1 }, tk.get(.accent_bar), 0xFF, 0, 0);
    y += 24;

    pw_ok_rect = .{ .x = win.x, .y = y, .w = win.w, .h = set_row_h };
    if (pw_pressed == .ok) push(.{ .x = @intFromFloat(pw_ok_rect.x), .y = @intFromFloat(pw_ok_rect.y), .w = @intFromFloat(pw_ok_rect.w), .h = @intFromFloat(pw_ok_rect.h) }, tk.get(.tab_hover_bg), 0xFF, 0, 0);
    pushText(maru.i18n.tIn(.ko, .mob_password_ok), @intFromFloat(win.x + set_pad_x), @intFromFloat(y + (set_row_h - 16) / 2), 16, tk.get(.accent_bar));
    y += set_row_h;
    pw_cancel_rect = .{ .x = win.x, .y = y, .w = win.w, .h = set_row_h };
    if (pw_pressed == .cancel) push(.{ .x = @intFromFloat(pw_cancel_rect.x), .y = @intFromFloat(pw_cancel_rect.y), .w = @intFromFloat(pw_cancel_rect.w), .h = @intFromFloat(pw_cancel_rect.h) }, tk.get(.tab_hover_bg), 0xFF, 0, 0);
    pushText(maru.i18n.tIn(.ko, .mob_password_cancel), @intFromFloat(win.x + set_pad_x), @intFromFloat(y + (set_row_h - 16) / 2), 16, tk.get(.surface_fg));
}

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
        var buf: [96]u8 = undefined;
        const value = if (editing)
            (std.fmt.bufPrint(&buf, "{s}\u{258F}", .{set_edit_buf[0..set_edit_len]}) catch "\u{258F}")
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
        push(.{ .x = @intFromFloat(rect.x), .y = @intFromFloat(rect.y + set_row_h - 1), .w = @intFromFloat(rect.w), .h = 1 }, tk.get(.divider), 0xFF, 0, 0);
        y += set_row_h;
    }

    // ── 이 기기의 공개키. **여기 있는 이유**: 이 서버에 붙으려면 그 서버 `authorized_keys` 에
    // 이 줄을 넣어야 한다 — 주소·지문을 치는 바로 그 자리에서 복사할 수 있어야 한 화면에서 끝난다.
    y += 12;
    const key_rect: SetRect = .{ .x = win.x, .y = y, .w = win.w, .h = set_row_h };
    srv_edit_rects[server_field_n] = key_rect;
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
    if (srv_edit_pressed == server_field_n + 1) push(.{ .x = @intFromFloat(save_rect.x), .y = @intFromFloat(save_rect.y), .w = @intFromFloat(save_rect.w), .h = @intFromFloat(save_rect.h) }, tk.get(.tab_hover_bg), 0xFF, 0, 0);
    pushText(maru.i18n.tIn(.ko, .mob_server_save), @intFromFloat(save_rect.x + set_pad_x), @intFromFloat(save_rect.y + (set_row_h - 16) / 2), 16, tk.get(.accent_bar));
    push(.{ .x = @intFromFloat(save_rect.x), .y = @intFromFloat(save_rect.y + set_row_h - 1), .w = @intFromFloat(save_rect.w), .h = 1 }, tk.get(.divider), 0xFF, 0, 0);
    y += set_row_h;

    const del_rect: SetRect = .{ .x = win.x, .y = y, .w = win.w, .h = set_row_h };
    srv_edit_rects[server_field_n + 2] = del_rect;
    if (srv_edit_pressed == server_field_n + 2) push(.{ .x = @intFromFloat(del_rect.x), .y = @intFromFloat(del_rect.y), .w = @intFromFloat(del_rect.w), .h = @intFromFloat(del_rect.h) }, tk.get(.tab_hover_bg), 0xFF, 0, 0);
    pushText(maru.i18n.tIn(.ko, .mob_server_delete), @intFromFloat(del_rect.x + set_pad_x), @intFromFloat(del_rect.y + (set_row_h - 16) / 2), 16, tk.get(.surface_fg));
}

fn drawSettings(win: SetRect, tk: *const tokens.Tokens) void {
    push(.{ .x = @intFromFloat(win.x), .y = @intFromFloat(win.y), .w = @intFromFloat(win.w), .h = @intFromFloat(win.h) }, tk.get(.surface_bg), 0xFF, 0, 0);

    // ── 헤더: 뒤로 + 제목
    set_back_rect = .{ .x = win.x, .y = win.y, .w = set_head_h, .h = set_head_h }; // 44 이상 정사각
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
                    .toggle => drawSetToggle(val != 0, right, ry + h / 2, tk),
                    .number => {
                        // **편집 중이면 치는 값을 보인다.** 어디로 가는지 안 보이면 "키보드가
                        // 어디에 쓰이는지 모르는" 그 혼란이 그대로 남는다. 캐럿(▏)으로 그 줄이
                        // 입력 대상임을 알린다.
                        const editing = set_edit != null and set_edit.? == i;
                        var buf: [20]u8 = undefined;
                        const t = if (editing)
                            (std.fmt.bufPrint(&buf, "{s}\u{258F}", .{set_edit_buf[0..set_edit_len]}) catch "\u{258F}")
                        else
                            (std.fmt.bufPrint(&buf, "{d}", .{val}) catch "?");
                        const role: tokens.ColorRole = if (editing) .accent_bar else .muted_fg;
                        pushText(t, @intFromFloat(right - @as(f32, @floatFromInt(textWidth(t, 15)))), @intFromFloat(ry + (h - 15) / 2), 15, tk.get(role));
                    },
                    .text => {
                        // 편집 중이면 치는 값을, 아니면 지금 값을 보인다. 캐럿(▏)으로 그 줄이
                        // 입력 대상임을 알린다(숫자 줄과 같은 규칙 — 두 줄이 다르게 굴면
                        // 사용자가 어느 쪽이 먹는지 매번 시험해 봐야 한다).
                        const editing = set_edit != null and set_edit.? == i;
                        var buf: [80]u8 = undefined;
                        const t = if (editing)
                            (std.fmt.bufPrint(&buf, "{s}\u{258F}", .{set_edit_buf[0..set_edit_len]}) catch "\u{258F}")
                        else
                            mobile_config.textValueOf(cfg(), row.key);
                        const role: tokens.ColorRole = if (editing) .accent_bar else .muted_fg;
                        pushText(t, @intFromFloat(right - @as(f32, @floatFromInt(textWidth(t, 15)))), @intFromFloat(ry + (h - 15) / 2), 15, tk.get(role));
                    },
                    .choice => {
                        // **고른 것이 없으면 이름을 안 적는다**(§프리셋 되짚기). 아무거나 적으면
                        // 고르지도 않은 값을 고른 것처럼 보인다.
                        const v = if (val >= 0 and val < row.items.len) row.items[@intCast(val)] else "—";
                        const chev_w: f32 = 14;
                        pushText("\u{25BE}", @intFromFloat(right - chev_w), @intFromFloat(ry + (h - 15) / 2), 15, tk.get(.muted_fg));
                        pushText(v, @intFromFloat(right - chev_w - 6 - @as(f32, @floatFromInt(textWidth(v, 15)))), @intFromFloat(ry + (h - 15) / 2), 15, tk.get(.muted_fg));
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
    if (screenTop() == .terminal) {
        switch (phase) {
            0 => {
                if (routeIs(.chrome)) return 1; // 둘째 손가락은 이 표면의 제스처를 안 건드린다
                // **복사가 먼저다** — 뒤로가기와 자리가 다르지만, 판정 순서를 고정해 둬야
                // 나중에 자리가 겹칠 때 조용히 한쪽이 죽지 않는다.
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
                }
                return 1;
            },
            else => {
                if (!routeIs(.chrome)) return 0;
                const was_copy = term_copy_pressed;
                term_back_pressed = false;
                term_copy_pressed = false;
                routeClear(); // 이 띠는 한 손가락 자리다 — 뗀 순간 끝이다
                if (phase == 3) {
                    term_press.cancel();
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
                sess_press.begin(x, y, time_ms, false); // 이 화면에는 흐르는 것이 없다
                sess_pressed = if (setHit(sess_gear_rect, x, y)) .gear else if (setHit(sess_row_rect, x, y)) .row else if (setHit(sess_servers_rect, x, y)) .servers else .none;
                return 1;
            },
            1 => {
                if (!routeIs(.chrome)) return 0;
                // 임계를 넘으면 밀려던 것이다 — 눌림 표시를 거둔다(목록·키바와 같은 규칙).
                if (sess_press.move(x, y)) sess_pressed = .none;
                return 1;
            },
            else => {
                if (!routeIs(.chrome)) return 0;
                const was = sess_pressed;
                sess_pressed = .none;
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

/// 한 줄에 몇 칸인가. **줄 수는 여기서 파생된다** — 키를 더하면 줄이 늘고, 두 값을 따로 적으면
/// 갈린다.
const key_bar_cols: usize = 6;
const key_bar_rows: usize = (key_bar.len + key_bar_cols - 1) / key_bar_cols;

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

/// 눌러 둔 수정자(sticky). **다음 한 글자**에만 실린다 — 계속 걸려 있으면 그 다음 타이핑이
/// 전부 제어문자가 된다.
var armed_mods: u32 = 0;

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
    resetAtlasIfTextSizeChanged();
    stepSetFling();
    stepBodyFling();
    if (term_core) |*core| checkLongPress(core);
    quad_count = 0;
    // **여기서 비우지 않는다.** 프레임 시작마다 비우면 프레임 **사이**에 난 실패
    // (`maru_mobile_input` 의 core write)가 아무도 읽기 전에 지워진다 — 키가 조용히
    // 사라지던 것이 이번 리뷰 최상위 결함이었는데, 그 신호가 딱 그 경로에서만 안 남았다.
    // 비우는 것은 **읽은 쪽**이 한다(`maru_mobile_clear_error`).
    const tk = tokens.Tokens.rich(themeColors());
    buildUi(width, height, &tk) catch |err| {
        setLastError(@errorName(err));
        return 0;
    };
    // **밀린 화면은 아래를 덮는다**(스택 — UX §3). 터미널을 먼저 세우는 이유는 두 가지다:
    // 코어 격자·아틀라스가 계속 살아 있어야 돌아왔을 때 화면이 그대로이고, 키바 사각형이
    // 서 있어야 `key_bar_ready` 가 거짓말을 안 한다.
    switch (screenTop()) {
        .terminal => {},
        .sessions => drawSessions(.{ .x = 0, .y = 0, .w = @floatFromInt(width), .h = @floatFromInt(height) }, &tk),
        .settings => drawSettings(.{ .x = 0, .y = 0, .w = @floatFromInt(width), .h = @floatFromInt(height) }, &tk),
        .servers => drawServers(.{ .x = 0, .y = 0, .w = @floatFromInt(width), .h = @floatFromInt(height) }, &tk),
        .server_edit => drawServerEdit(.{ .x = 0, .y = 0, .w = @floatFromInt(width), .h = @floatFromInt(height) }, &tk),
        .password => drawPasswordPrompt(.{ .x = 0, .y = 0, .w = @floatFromInt(width), .h = @floatFromInt(height) }, &tk),
        .host_key => drawHostKeyPrompt(.{ .x = 0, .y = 0, .w = @floatFromInt(width), .h = @floatFromInt(height) }, &tk),
    }
    return @intCast(quad_count);
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
