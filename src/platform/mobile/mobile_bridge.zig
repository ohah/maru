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
const mobile_config = @import("mobile_config.zig");

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
pub export fn maru_mobile_load_config(ptr: [*]const u8, len: usize) void {
    const next = mobile_config.parse(term_allocator, ptr[0..len]) catch {
        setLastError("config_parse");
        return;
    };
    if (cfg_parsed) |*old| old.deinit();
    cfg_parsed = next;
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
    return if (set_edit != null) 1 else 0; // 0=글자(터미널) · 1=숫자
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

/// 지금 편집 중인 설정 줄(그 줄에 숫자를 친다). null 이면 편집 중이 아니다.
var set_edit: ?usize = null;
/// 편집 중인 값의 자릿수 버퍼. **확정 전에는 config 를 안 건드린다** — 중간 값(예: "5")이
/// 그대로 적용되면 스크롤백이 5줄로 줄었다가 돌아오는 것이 화면에 보인다.
var set_edit_buf: [12]u8 = undefined;
var set_edit_len: usize = 0;

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

pub fn settingsPopupCap() usize {
    return set_item_rects.len;
}

/// 설정 목록이 지금 얼마나 밀려 있나(px). **관성은 줄 높이보다 작게 움직이는 프레임이 있어**
/// 줄 색인으로는 "흐르고 있다" 를 못 잰다.
pub fn settingsScrollPx() u32 {
    return set_sa.offset_y_px;
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

pub export fn maru_mobile_input(ptr: [*]const u8, len: usize) u32 {
    // **밀린 화면이 있으면 글자는 셸로 안 간다.** 설정을 열어도 소프트 키보드는 떠 있으므로
    // (§5.2 — 앱이 내리지 않는다) 여기서 안 막으면 사용자가 **안 보이는 셸에 타이핑**하게 된다.
    // 화면에 아무 반응이 없어 잃은 것도 모른다. 설정에 입력 칸이 생기면(검색) 그때 그쪽으로
    // 라우팅한다 — 지금은 받을 곳이 없으니 안 보낸다.
    //
    // **밀린 화면에서도 받는 자리가 생겼다.** 설정의 숫자 줄을 누르면 그 줄이 입력 대상이 되고
    // 친 숫자가 거기로 간다 — 그전에는 키보드가 떠 있는데 글자를 버리고 있었다("키보드는 있는데
    // 아무것도 안 써지는" 상태). 받을 곳이 없을 때만 버리고, 그때는 **신호를 남긴다**(§5).
    if (screen != .terminal) {
        if (set_edit != null) {
            editNumberInput(ptr[0..len]);
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
        if (i > 0) core.write(rest[0..i]) catch {
            setLastError("core_write_input");
            return @intCast(delivered_len);
        };
        delivered_len += i;
        // CRLF 는 Enter 한 번이다.
        var skip: usize = 1;
        if (rest[i] == '\r' and i + 1 < rest.len and rest[i + 1] == '\n') skip = 2;
        writeKey(core, .enter, .{});
        rest = rest[i + skip ..];
    }
    if (rest.len > 0) {
        core.write(rest) catch {
            setLastError("core_write_input");
            return @intCast(delivered_len);
        };
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
fn writeKey(core: *terminal.core.TerminalCore, key: terminal.input.Key, mods: terminal.input.ModifierSet) void {
    var buf: [terminal.input.encoded_key_buffer_len]u8 = undefined;
    const bytes = core.encodeKey(.{ .key = key, .modifiers = mods }, &buf) catch {
        setLastError("key_encode");
        return;
    };
    core.write(bytes) catch {
        setLastError("core_write_input");
        return;
    };
    delivered_len += bytes.len;
}

pub export fn maru_mobile_key(key_id: u32, codepoint: u32, mods: u32) u32 {
    // **밀린 화면이 있으면 글자는 셸로 안 간다.** 설정을 열어도 소프트 키보드는 떠 있으므로
    // (§5.2 — 앱이 내리지 않는다) 여기서 안 막으면 사용자가 **안 보이는 셸에 타이핑**하게 된다.
    // 화면에 아무 반응이 없어 잃은 것도 모른다. 설정에 입력 칸이 생기면(검색) 그때 그쪽으로
    // 라우팅한다 — 지금은 받을 곳이 없으니 안 보낸다. **버리되 신호는 남긴다**(문자 경로와
    // 같은 이유 — 16줄 아래 `key_unknown_id` 가 같은 규율이다).
    if (screen != .terminal) {
        // **편집 중이면 지우기·확정은 그 칸의 것이다.** 그전에는 통째로 버려서 숫자 칸에서
        // 백스페이스가 아무 일도 안 했다 — 오타를 낸 사용자가 고칠 방법이 없었다.
        if (set_edit != null) {
            switch (key_id) {
                4 => { // BACKSPACE
                    if (set_edit_len > 0) set_edit_len -= 1;
                    return @intCast(delivered_len);
                },
                1 => { // ENTER
                    commitNumberEdit();
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
pub export fn maru_mobile_scroll(dy_px: f32) void {
    // **밀린 화면이 있으면 뒤는 안 움직인다.** host 의 관성은 손을 뗀 뒤에도 몇 프레임 더
    // 도는데, 그 사이 톱니를 눌러 설정을 열면 **안 보이는 터미널이 계속 흘러** 돌아왔을 때
    // 보던 자리가 아니다(§3 "전환에서 스크롤 위치를 잃지 않는다").
    //
    // **여기는 오류를 안 남긴다** — 위 두 경로(문자·키)와 다르다. 잃는 것이 사용자가 친
    // 글자가 아니라 host 가 스스로 돌리는 관성이고, 그 관성은 프레임마다 오므로 남기면
    // `last_error` 가 매 프레임 덮여 **진짜 오류를 가린다**.
    if (screen != .terminal) return;
    const core = &(term_core orelse {
        setLastError("scroll_before_core");
        return;
    });
    if (body_line_h <= 0) return;
    // **선택 중에는 안 흘린다.** 플랫폼은 관성(느낌)만 갖고 그것을 적용할지는 의미라 코어가
    // 정한다 — host 는 MOVE 마다 관성 속도를 세워 두므로, 여기서 안 막으면 길게 눌러 선택하는
    // 동안에도 화면이 계속 흐른다(끌어서 범위를 넓히는 내내 글자가 도망간다).
    if (selecting) {
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
            core.write(batch[0..used]) catch {
                setLastError("core_write_input");
                break;
            };
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
/// 이만큼 움직이면 "누르고 있는" 것이 아니라 끄는 것이다(논리 px).
const long_press_slop: f32 = 10;

var ptr_down = false;
var ptr_down_x: f32 = 0;
var ptr_down_y: f32 = 0;
var ptr_down_ms: u64 = 0;
var ptr_last_y: f32 = 0;
var ptr_moved = false;
/// 길게 눌러 선택에 들어갔다 — 이 뒤의 이동은 스크롤이 아니라 선택 확장이다.
var selecting = false;

/// 본문 안의 점을 셀로. 본문 밖이면 null.
fn bodyCell(x: f32, y: f32) ?struct { row: u16, col: u16 } {
    const packed_cell = maru_mobile_hit_cell(x, y);
    if (packed_cell == 0xFFFF_FFFF) return null;
    return .{ .row = @intCast(packed_cell & 0xFFFF), .col = @intCast(packed_cell >> 16) };
}

pub export fn maru_mobile_pointer(phase: u32, x: f32, y: f32, time_ms: u64) void {
    const core = &(term_core orelse return);
    switch (phase) {
        0 => { // down
            ptr_down = true;
            ptr_down_x = x;
            ptr_down_y = y;
            ptr_down_ms = time_ms;
            ptr_last_y = y;
            ptr_moved = false;
            // 새로 누르면 이전 선택은 사라진다 — 데스크톱에서 클릭이 선택을 푸는 것과 같다.
            if (selecting or core.selectionViewportSpan() != null) {
                core.selectionClear();
                selecting = false;
            }
        },
        1 => { // move
            if (!ptr_down) return;
            const dx = x - ptr_down_x;
            const dy = y - ptr_down_y;
            if (@abs(dx) > long_press_slop or @abs(dy) > long_press_slop) ptr_moved = true;

            if (selecting) {
                // **누른 칸을 벗어나기 전에는 안 늘린다.** 길게 눌러 단어를 잡은 직후에도
                // move 는 계속 오는데, 그때마다 늘리면 head 가 **누른 칸으로 당겨져 단어
                // 끝이 잘린다**(3칸 단어가 2칸이 되는 것을 픽셀로 재서 잡았다).
                if (bodyCell(x, y)) |c| {
                    if (bodyCell(ptr_down_x, ptr_down_y)) |d| {
                        if (c.row != d.row or c.col != d.col) {
                            core.selectionExtend(c.row, c.col);
                            // **여기가 "누른 칸을 벗어났다" 는 판정 그 자체다.** `ptr_moved` 를
                            // px 임계로만 세우면 가로에서 거짓이 된다 — 셀 폭(8)이 임계(10)보다
                            // 좁아, 9px 끌면 다른 칸으로 넘어가 여기까지 오는데도 안 서고
                            // 다음 프레임 `checkLongPress` 가 늘린 것을 **되돌린다**(한 칸만큼
                            // 넓히는 것이 아예 불가능했다). 세로는 줄 높이(22)가 임계보다 커서
                            // 우연히 맞았다 — 우연에 기대지 않는다.
                            ptr_moved = true;
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
            ptr_last_y = y;
        },
        else => { // up · cancel
            ptr_down = false;
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
            selecting = false;
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
var key_bar_band: struct { top: f32 = 0, bot: f32 = 0 } = .{};
var key_bar_max_scroll: f32 = 0;
/// 가로 스크롤 오프셋(양수 = 왼쪽으로 밀림).
/// 키바 가로 스크롤도 **컴포넌트가 든다**(설정 목록과 같은 규칙 — 축만 다르다). 예전에는 여기
/// 감쇠·임계가 손으로 있었고 설정 목록에도 같은 숫자가 또 있었다.
var kb_sa: scroll_area.State = .{};
/// 이번 짚음이 **관성을 세운 것**인가. 그렇다면 키를 안 보낸다.
var kb_stop_tap: bool = false;
var kb_touch: scroll_area.Touch = .{};
/// 손을 뗀 뒤 남은 가로 관성(프레임당 논리 px).
/// 손가락이 지금 누르고 있는 키. **hover 가 없는 자리를 메우는 것이 눌림 표시**다(§2.4) —
/// 없으면 눌렀는지 화면이 답하지 않는다. 밀기로 판정되면 즉시 푼다(누른 것이 아니었으므로).
var kb_pressed: ?usize = null;

var kb_active = false;
var kb_down_x: f32 = 0;
var kb_down_y: f32 = 0;
var kb_last_x: f32 = 0;
var kb_moved: f32 = 0;

/// 키 하나를 그린다 — 테두리 + 키캡 면 + 가운데 라벨.
fn drawKey(i: usize, kx: f32, ky: f32, tk: *const tokens.Tokens) void {
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
        .w = @intFromFloat(key_w),
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
            .x = kx + (key_w - ic) / 2,
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
    pushText(key_bar[i].label, @intFromFloat(kx + (key_w - label_w) / 2), @intFromFloat(ky + (key_h - key_font) / 2), @intFromFloat(key_font), tk.get(if (armed or pressed) .accent_bar else if (dimmed) .muted_fg else .surface_fg));
}

fn clampKeyBarScroll() void {
    kb_sa.clamp(@intFromFloat(@max(0, key_bar_max_scroll)));
}

/// 남은 가로 관성을 한 프레임 몫만큼 흘린다. 터미널 세로 관성(host `fling_vy`)과 같은 모양이다.
///
/// **손가락이 닿아 있는 동안에는 안 흘린다.** `move` 가 이미 그만큼 스크롤했는데 여기서 또
/// 흘리면 **같은 이동량이 두 번** 적용돼 손가락보다 두 배로 미끄러진다. 관성은 손을 뗀 뒤의 것이다.
fn stepKeyBarFling() void {
    // **밀린 화면이 있으면 키바도 멈춘다.** 안 그러면 손을 뗀 뒤 남은 관성이 설정 화면 뒤에서
    // 계속 흘러, 돌아왔을 때 키 줄이 딴 자리에 가 있다(본문 관성과 같은 이유).
    if (screen != .terminal) return;
    _ = kb_touch.step(&kb_sa, @intFromFloat(@max(0, key_bar_max_scroll)));
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
pub export fn maru_mobile_keybar_pointer(phase: u32, x: f32, y: f32) u32 {
    // **취소는 잡고 있지 않아도 받는다.** host 는 배경으로 나갈 때 좌표 없이 취소만 보내는데
    // (`maru_mobile_pointer(3,0,0,0)` 과 짝), 그때 여기서 안 풀면 `kb_active` 가 남아 **복귀 후
    // 첫 터치가 통째로 키바로 간다** — 본문을 눌러도 아무 일이 안 일어난다.
    if (phase == 3) {
        kb_active = false;
        kb_pressed = null;
        kb_touch.cancel();
        return 0;
    }
    if (phase == 0) {
        // 가로는 안 본다 — 키바가 한 줄을 통째로 쓰고, 스크롤로 밀려 키가 없는 자리도 밴드 안이다.
        if (!key_bar_ready) return 0;
        if (y < key_bar_band.top or y >= key_bar_band.bot) return 0;
        kb_active = true;
        kb_down_x = x;
        kb_down_y = y;
        kb_last_x = x;
        kb_moved = 0;
        // **흐르는 중에 짚으면 멈추기만 한다.** 그 짚음은 세우려던 것이지 키를 누른 것이
        // 아니다 — 안 가리면 멈추려던 손가락이 그 자리 키를 터미널로 보낸다(재현했다).
        kb_stop_tap = kb_touch.begin(x);
        // **누르는 즉시 보여 준다.** 입력은 up 에서 나가지만 표시는 down 에서 서야 손가락이
        // "닿았다" 를 안다 — hover 가 없는 자리를 이것이 메운다(§2.4).
        kb_pressed = if (kb_stop_tap) null else keybarIndexAt(x, y);
        return 1;
    }
    if (!kb_active) return 0;
    if (phase == 1) {
        const dx = x - kb_last_x;
        kb_last_x = x;
        kb_moved += @abs(dx);
        // **임계를 넘기 전에는 스크롤도 안 한다.** 예전에는 이동량을 늘 반영해서, 살짝 민 손짓이
        // **화면도 조금 움직이고 키도 나가는** 두 일을 한꺼번에 했다 — 같은 손짓이 어떨 때는
        // 스크롤로, 어떨 때는 입력으로 보이는 원인이었다(사용자가 화면에서 짚었다).
        // 임계를 넘는 순간부터 밀기이고, 그때 눌림 표시도 거둔다(누른 것이 아니었으므로).
        if (kb_moved < scroll_area.Touch.slop_px) return 1;
        kb_pressed = null;
        kb_touch.move(&kb_sa, x, @intFromFloat(@max(0, key_bar_max_scroll)));
        return 1;
    }
    kb_active = false;
    kb_pressed = null;
    // 뗄 때 관성이 시작된다(취소는 위에서 이미 거뒀다).
    kb_touch.end();
    // **10px 은 손가락이 가만히 있다고 보는 폭**이다. 이보다 크면 밀려던 것이지 누르려던 것이 아니다.
    if (phase == 2 and !kb_stop_tap and kb_moved < scroll_area.Touch.slop_px) {
        kb_touch.cancel(); // 탭이면 관성이 없다
        // **`<`/`>` 는 누르는 것이 아니라 신호다.** 한때 데스크톱 탭바의 `‹›` 가 클릭 가능하다는
        // 이유로 한 화면씩 옮기게 했는데, 두 가지가 어긋났다 — ① 데스크톱이 그런 것은 **마우스**
        // 이기 때문이고 터치에서는 **밀면 된다**(§2.4 "입력 방식이 다르면 같은 요소도 다르게
        // 동작한다"), ② 표시 폭이 26px 이라 **44 기준에 미달하는 버튼**을 새로 만드는 꼴이었다
        // (44 를 지키려고 시작한 작업에서). 그래서 표시로만 두고, 그 자리를 눌러도 스크롤의
        // 시작점일 뿐 아무 키도 안 나간다.
        _ = keybarTapAt(kb_down_x, kb_down_y);
    }
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
    if (screen != .terminal) return 0;
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
    const line_h: i32 = 22;
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
const status_icon_count: usize = status_cps.len;
const status_icon_step: i32 = 44; // 히트 44 가 이웃과 안 겹치려면 간격도 44 여야 한다
/// 그리는 크기. **히트(44)와 다른 값이다** — 44 를 꽉 채우면 아이콘끼리 붙어 보인다.
/// 18 은 26px 줄에 맞춰 고른 값이라 44 줄에서는 작아 보였다(실제 하단 바는 24~28 을 쓴다).
const status_icon_px: i32 = 24;
const icon_slot_px = 32;
/// 6 = chrome 헤더(git·gear·plus·search·bell·collapse), +4 = 보조 키바 방향키.
/// 하단 바 아이콘. **이 배열이 개수의 출처다**(`status_icon_count`).
const status_cps = [_]u32{
    maru.icons.codepoint(.git_branch),
    maru.icons.codepoint(.gear),
    maru.icons.codepoint(.plus),
    maru.icons.codepoint(.search),
    maru.icons.codepoint(.bell),
    maru.icons.codepoint(.sidebar_collapse),
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

/// 터미널 창 chrome 을 실제 컴포넌트로 조립한다 — 탭 바, 사이드바 카드 목록, 본문, 상태바.
fn buildUi(width: u32, height: u32, tk: *const tokens.Tokens) !void {
    const height_f: f32 = @floatFromInt(height);
    var entries: [256]tree.RectEntry = undefined;
    var items: [256]layout.Item = undefined;
    var flex_scratch: [256]layout.FlexScratch = undefined;
    var child_rects: [256]layout.UiRect = undefined;

    // ── 탭 바: 탭 세 개를 가로로
    const tab_label_style: layout.UiStyle = .{ .width = .{ .px = 34.0 }, .height = .{ .px = 13.0 }, .margin = .{ .left = 12.0, .top = 11.0 } };
    // 자식 슬라이스는 **함수 스코프 변수**를 가리켜야 한다. `&.{...}` 는 임시 배열이라
    // statement 를 벗어나면 dangling 이고, build 가 그 쓰레기를 읽는다(실측).
    var tab_kids: [3][1]tree.UiNode = .{
        .{tree.text(.{ .id = 111, .style = tab_label_style, .value = "zsh", .tone = .primary })},
        .{tree.text(.{ .id = 112, .style = tab_label_style, .value = "vim", .tone = .muted })},
        .{tree.text(.{ .id = 113, .style = tab_label_style, .value = "logs", .tone = .muted })},
    };
    const tabs = [_]tree.UiNode{
        tree.card(.{ .id = 101, .style = .{ .flex = .{ .grow = 1 }, .height = .{ .px = 34.0 }, .margin = .{ .right = 6.0 } }, .variant = .selected }, &tab_kids[0]),
        tree.card(.{ .id = 102, .style = .{ .flex = .{ .grow = 1 }, .height = .{ .px = 34.0 }, .margin = .{ .right = 6.0 } }, .variant = .surface }, &tab_kids[1]),
        tree.card(.{ .id = 103, .style = .{ .flex = .{ .grow = 1 }, .height = .{ .px = 34.0 } }, .variant = .surface }, &tab_kids[2]),
    };
    const tab_bar = tree.container(.{ .id = 100, .direction = .row, .style = .{ .height = .{ .px = 46.0 }, .padding = .{ .left = 12.0, .right = 12.0, .top = 6.0, .bottom = 6.0 } } }, &tabs);

    // ── 사이드바: 워크스페이스 카드 다섯 개(세로)
    const names = [_][]const u8{ "maru", "web", "docs", "infra", "scratch" };
    var side_kids: [5][1]tree.UiNode = undefined;
    var side_children: [5]tree.UiNode = undefined;
    for (&side_children, 0..) |*c, i| {
        side_kids[i] = .{tree.text(.{
            .id = @intCast(230 + i),
            .style = .{ .width = .{ .px = 58.0 }, .height = .{ .px = 13.0 }, .margin = .{ .left = 12.0, .top = 19.0 } },
            .value = names[i],
            .tone = if (i == 1) .accent else .primary,
        })};
        c.* = tree.card(.{
            .id = @intCast(210 + i),
            .style = .{ .width = .{ .percent = 1.0 }, .height = .{ .px = 52.0 }, .margin = .{ .bottom = 8.0 } },
            .variant = if (i == 1) .selected else .surface,
        }, &side_kids[i]);
    }
    const sidebar = tree.container(.{ .id = 200, .direction = .column, .style = .{ .width = .{ .percent = 0.34 }, .padding = .{ .left = 10.0, .right = 10.0, .top = 10.0, .bottom = 10.0 } } }, &side_children);

    // ── 본문: **진짜 터미널 화면**이다. 자식 없이 자리만 잡고, 그 사각형을
    // `TerminalCore` 의 셀 격자로 채운다(아래 `pushTerminal`). 앞 단계의 하드코딩
    // 문자열과 달리 VT 파서를 실제로 태우므로 SGR 색·한글 2셀 폭이 코어에서 나온다.
    const body = tree.container(.{ .id = 300, .direction = .column, .style = .{ .flex = .{ .grow = 1 }, .padding = .{ .left = 16.0, .right = 16.0, .top = 14.0, .bottom = 14.0 } } }, &.{});

    const middle = tree.container(.{ .id = 20, .direction = .row, .style = .{ .flex = .{ .grow = 1 } } }, &.{ sidebar, body });

    // ── 상태바
    // ── 하단 바: **아이콘 줄 하나다.**
    //
    // **높이 44 다**(iOS 44 · Android 48 의 아래쪽). 전에는 26 이라 이 줄의 어떤 아이콘도
    // 손가락 기준을 못 맞췄다 — 설정 입구(톱니)를 44 로 넓히려다 그 사실이 드러났다.
    // 대가는 본문이 18px 줄어드는 것이고, 실제 하단 바가 iOS 49pt·Android 56dp 인 것을 보면
    // 44 도 넉넉한 편이 아니다([UX §5.6](../../../docs/mobile-ux.md)).
    //
    // **빈 카드 둘을 지웠다.** M0 에서 PoC 목업을 옮겨 오며 따라온 자리 채우개였고, 무엇이
    // 들어갈지 어느 문서에도 없었다. 26 일 때는 얇은 선이라 안 보였는데 44 로 키우니 **빈
    // 상자**가 되어 "여기 뭔가 들어간다" 로 읽혔다. 여기에 어울리는 것(연결 상태·세션 이름)은
    // 전부 M3 가 정해야 나오므로, 그때 넣는다 — 지금 채우면 또 가짜 라벨이다.
    //
    // 자식이 없으므로 아이콘 자리를 padding 으로 예약할 필요도 없어졌다(예약이 좁은 창에서
    // 음수 자리를 만들어 화면을 검게 만들던 위험도 함께 사라진다).
    const status = tree.container(.{ .id = 400, .direction = .row, .style = .{ .height = .{ .px = 44.0 }, .padding = .{ .left = 12.0, .right = 12.0, .top = 5.0, .bottom = 5.0 } } }, &.{});

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
        .style = .{ .width = .{ .percent = 1.0 }, .height = .{ .px = key_h + 10.0 } },
    }, &.{});

    const root = tree.container(.{ .id = 1, .direction = .column }, &.{ tab_bar, middle, bar, status });

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

    // `ui.paint` 는 텍스트 op 을 내지 않는다(resolveText 결과를 버린다 — 실측). 텍스트 렌더는
    // typography/lowering 이 따로 맡는 구조라, 레이아웃이 잡은 자리에 **실제 글자**를 그린다.
    for (built.entries) |entry| {
        if (entry.kind != .text) continue;
        const label = labelFor(entry.id) orelse continue;
        const tone_role: tokens.ColorRole = switch (entry.visual) {
            .text => |tv| switch (tv.tone) {
                .accent => .accent_bar,
                .muted => .muted_fg,
                else => .surface_fg,
            },
            else => .surface_fg,
        };
        pushText(label, @intFromFloat(entry.rect.x), @intFromFloat(entry.rect.y), 15, tk.get(tone_role));
    }

    // 키바의 각 사각형을 기록한다 — **그리는 자리와 판정하는 자리가 같아야** 눌러도
    // 다른 키가 나가지 않는다(따로 계산하면 갈린다).
    // **자리를 다 못 채웠으면 안 섰다고 답한다.** 세우기만 하고 안 내리면, 레이아웃에서
    // 키바가 빠진 프레임에도 **옛 자리를 그대로 답해** 없는 키가 눌린다.
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
        // 자투리(`slack`)는 아래에서 좌우 표시 영역이 나눠 먹는다 — `view_x` 는 그만큼 오른쪽에서
        // 시작한다(왼쪽 표시가 넓어진다).
        var view_x: f32 = band_x + edge_w;
        // **`copy` 자리는 예약한다.** 없애 보니 `copy` 가 창 밖으로 밀려 **누르려면 찾아 밀어야
        // 했다**(선택을 잡자마자 쓰는 버튼이라 그건 못 쓴다). 오른쪽 끝 고정 자리에 둔다.
        // **`copy` 도 스크롤을 탄다**(사용자 결정). 늘 줄에 있으므로 나타났다 사라지며 나머지
        // 키를 미는 일이 없고, 고정 자리를 예약할 이유도 없다 — 예약은 오른쪽에 죽은 공간을
        // 남길 뿐이었다. 목록 끝이 그 자리이고 밀어서 닿는다.
        const copy_slot_w: f32 = 0;
        // **창을 키 단위로 맞춘다.** 자투리를 남기면 스크롤 0 에서도 오른쪽에 **아무것도 없는
        // 자리**가 뜬다(사용자가 화면에서 짚었다) — 완전히 들어온 키만 그리므로 그 자투리는
        // 영영 안 채워진다. 남는 폭은 좌우 표시 영역이 나눠 먹어 눈에 안 띈다.
        const per_key = key_w + key_gap;
        const raw_view_w = band_w - 2 * edge_w - copy_slot_w;
        const fit_n = @max(1.0, @floor((raw_view_w + key_gap) / per_key));
        const view_w = fit_n * per_key - key_gap;
        const slack = raw_view_w - view_w;
        view_x += @floor(slack / 2);
        const scroll_n = bar_n;
        // **마지막 키 뒤에는 gap 이 없다.** `n * (w + gap)` 으로 재면 끝까지 밀었을 때 gap 만큼
        // 빈 자리가 남는다(화면으로 확인). 키 n개 사이의 gap 은 n-1 개다.
        const content = if (scroll_n == 0) 0 else @as(f32, @floatFromInt(scroll_n)) * key_w + @as(f32, @floatFromInt(scroll_n - 1)) * key_gap;
        key_bar_max_scroll = @max(0, content - view_w);
        clampKeyBarScroll();

        // 창 왼쪽에서 스크롤 오프셋만큼 물러난 자리에서 시작한다. 창 밖으로 나간 키는
        // 그리지도 않는다 — 화면 밖 quad 는 낭비이고, 잘린 조각이 옆 UI 위에 얹힌다.
        var kx = view_x - kbScroll();
        const ky = @floor(band.y + 5.0); // 세로도 같은 이유로 정수에 맞춘다(위 `kxi` 주석)
        for (0..key_bar.len) |i| {
            defer kx += key_w + key_gap;
            // **창 밖 키는 자리도 안 남긴다.** rect 를 그대로 두면 화살표 아래로 숨은 키가
            // 여전히 눌린다 — 보이지 않는 것이 눌리면 사용자는 왜 그 키가 나갔는지 알 수 없다.
            // **창에 완전히 들어온 키만 그리고, 그것만 누른다.** 조건이 하나다 — 걸친 것을 그리면
            // 반쯤 잘린 키가 `>` 옆에 붙어 **표시를 묻고**(사용자가 화면에서 짚었다), 그리는
            // 범위와 누르는 범위가 갈리면 **보이는데 안 눌리는 키**가 생긴다. 스크롤 중 키가
            // 44px 단위로 나타났다 사라지지만, "보이는 것이 눌린다" 가 그보다 중요하다.
            //
            // 좌표는 `@floor` 로 정수에 맞춘다 — 그리기는 절삭되는데 히트가 f32 면 1px 어긋나
            // 가장자리에서 옆 키가 나간다.
            const kxi = @floor(kx);
            if (kx < view_x - 0.5 or kx + key_w > view_x + view_w + 0.5) {
                key_bar_rects[i] = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
                continue;
            }
            key_bar_rects[i] = .{ .x = kxi, .y = ky, .w = key_w, .h = key_h };
            drawKey(i, kxi, ky, tk);
        }
        // **밴드를 찾았을 때만 "섰다" 고 답한다.** 이 값이 `false` 면 포인터가 키바를 안 먹는다 —
        // 레이아웃에서 키바가 빠진 프레임에 **옛 자리를 그대로 답해 없는 키가 눌리는 것**을 막는
        // 판정이다. 밴드 entry 를 못 찾으면 이 블록에 아예 안 들어와 `false` 로 남는다(위에서
        // 그렇게 초기화한다). 놓은 키 수를 여기 또 세지 않는다 — 늘 `bar_n` 이라 **항상 참인
        // 조건**이 되어 판정이 죽는다(전에 그랬다).
        key_bar_ready = bar_n > 0;

        // **더 있다는 것을 알린다.** 잘린 자리는 화면에서 "끝" 과 구별되지 않는다 — 밀 수 있다는
        // 신호가 없으면 사용자는 `~ / -` 가 존재하는 줄도 모른다. 키 **위에** 그리므로 지나가는
        // 키가 화살표를 덮지 않는다(그리기 순서가 곧 위아래다).
        // **불투명하게, 밝게, 크게.** 처음엔 14px 폭에 흐린 색으로 얹었더니 지나가는 키가 비쳐
        // 화살표인지도 알아보기 어려웠다(화면으로 확인). 이건 "더 있다" 를 알리는 신호라
        // 본문보다 또렷해야 한다 — 배경을 완전히 덮고, 안쪽 경계에 선을 그어 잘리는 자리를 못박는다.
        const edge_bg = tk.get(.surface_bg);
        const edge_fg = tk.get(.surface_fg);
        if (kbScroll() > 0.5) {
            const er: draw.Rect = .{ .x = @intFromFloat(band_x), .y = @intFromFloat(ky), .w = @intFromFloat(edge_w), .h = @intFromFloat(key_h) };
            push(er, edge_bg, 0xFF, 0, 0);
            push(.{ .x = er.x + @as(i32, @intFromFloat(edge_w)) - 1, .y = er.y, .w = 1, .h = er.h }, tk.get(.divider), 0xFF, 0, 0);
            pushText("<", er.x + @divTrunc(@as(i32, @intFromFloat(edge_w)) - textWidth("<", 22), 2), @intFromFloat(ky + (key_h - 22) / 2), 22, edge_fg);
        }
        if (kbScroll() < key_bar_max_scroll - 0.5) {
            const ex = band_x + band_w - edge_w;
            const er: draw.Rect = .{ .x = @intFromFloat(ex), .y = @intFromFloat(ky), .w = @intFromFloat(edge_w), .h = @intFromFloat(key_h) };
            push(er, edge_bg, 0xFF, 0, 0);
            push(.{ .x = er.x, .y = er.y, .w = 1, .h = er.h }, tk.get(.divider), 0xFF, 0, 0);
            pushText(">", er.x + @divTrunc(@as(i32, @intFromFloat(edge_w)) - textWidth(">", 22), 2), @intFromFloat(ky + (key_h - 22) / 2), 22, edge_fg);
        }
    }

    // **본문은 진짜 터미널 코어다.** 레이아웃이 잡아 준 본문 사각형에 셀 격자를 채운다.
    for (built.entries) |entry| {
        if (entry.id != 300) continue;
        pushTerminal(entry.rect, tk);
        break;
    }

    // **SVG 아이콘**: maru 의 등록 아이콘을 그대로 얹는다. coverage 는 Zig 가 만들고
    // (renderer/icon_glyph) 플랫폼은 텍스처로 올려 샘플링만 한다 — 자산이 이식된다는 증거다.
    // 아이콘 18px 를 44 줄 한가운데. **간격도 44 다** — 히트를 44 로 주면 26 간격에서는
    // 좌우로 9px 씩 겹쳐 어느 아이콘인지 모호해진다(설정 목록에서 배운 것과 같다).
    // 줄 한가운데. **그리는 크기에서 파생시킨다** — 따로 적으면 크기를 바꿀 때 세로가 안 따라와
    // 아이콘이 줄 위아래로 치우친다.
    const icon_y: i32 = @intFromFloat(@max(0, height_f - 44 + @as(f32, @floatFromInt(44 - status_icon_px)) / 2));
    const icon_step: i32 = status_icon_step;
    // **마지막 아이콘의 오른쪽 끝**을 가장자리에서 12 떨어뜨린다. 슬롯 수(6)만큼 통째로 빼면
    // 마지막 슬롯의 남는 폭(44-24)이 여백에 더해져 줄 전체가 20px 왼쪽으로 치우친다 — 간격과
    // 그리는 크기가 달라진 뒤로 그 차이가 눈에 보인다(전에는 26 대 18 이라 8px 이었다).
    const icon_span: i32 = icon_step * @as(i32, @intCast(status_icon_count - 1)) + status_icon_px;
    const icon_x0: i32 = @as(i32, @intCast(width)) - icon_span - 12;
    for (0..status_icon_count) |i| {
        if (!reserveQuad()) break;
        const rgb = tk.get(if (i == 0) .accent_bar else .surface_fg);
        // 톱니(슬롯 1)가 설정 화면 입구다. **그리는 자리를 그대로 히트로 쓰되 44 로 넓힌다** —
        // 아이콘은 18px 이라 그대로 받으면 손가락 기준의 절반도 안 된다(§5.1 "작게 그리고
        // 넓게 받는다" — 아이콘은 서로 떨어져 있어 목록과 달리 이 기법이 통한다).
        if (i == 1) {
            const half_icon = @as(f32, @floatFromInt(status_icon_px)) / 2;
            const cx = @as(f32, @floatFromInt(icon_x0 + icon_step * @as(i32, @intCast(i)))) + half_icon;
            const cy = @as(f32, @floatFromInt(icon_y)) + half_icon;
            // **위로는 키바 밴드를 넘지 않는다.** chrome 을 키바보다 먼저 묻기 때문에 rect 를
            // 위로 펴면 그 x 에 있는 키의 **밑동이 조용히 안 눌린다**. 줄이 44 라 넘길 필요도
            // 없다 — 클램프는 줄을 다시 줄일 때를 위한 가드로 남긴다([UX §5.6](../../../docs/mobile-ux.md)).
            const gear_top = @max(cy - 22, key_bar_band.bot);
            set_gear_rect = .{ .x = cx - 22, .y = gear_top, .w = 44, .h = @max(0, cy + 22 - gear_top) };
        }
        quad_buf[quad_count] = .{
            .x = @floatFromInt(icon_x0 + icon_step * @as(i32, @intCast(i))),
            .y = @floatFromInt(icon_y),
            .w = @floatFromInt(status_icon_px),
            .h = @floatFromInt(status_icon_px),
            .r = @as(f32, @floatFromInt(rgb.r)) / 255.0,
            .g = @as(f32, @floatFromInt(rgb.g)) / 255.0,
            .b = @as(f32, @floatFromInt(rgb.b)) / 255.0,
            .a = 1.0,
            .radius = 0,
            .kind = 2,
            .cell_x = 0,
            .cell_y = @intCast(i),
        };
        quad_count += 1;
    }
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

const Screen = enum { terminal, settings };
var screen: Screen = .terminal;

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
var set_stop_tap: bool = false;
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
var set_active: bool = false;
var set_down_x: f32 = 0;
var set_down_y: f32 = 0;
var set_last_y: f32 = 0;
var set_moved: f32 = 0;

/// 지금 스크롤 위치(px). 컴포넌트가 정수로 들고 있으므로 그리는 쪽만 f32 로 받는다.
fn setScroll() f32 {
    return @floatFromInt(set_sa.offset_y_px);
}

fn stepSetFling() void {
    _ = set_touch.step(&set_sa, @intFromFloat(@max(0, set_max_scroll)));
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
    pushText("설정", @intFromFloat(win.x + set_head_h), @intFromFloat(win.y + (set_head_h - 20) / 2), 20, tk.get(.surface_fg));
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
pub export fn maru_mobile_chrome_pointer(phase: u32, x: f32, y: f32) u32 {
    if (screen == .terminal) {
        // 톱니를 누르면 설정을 민다. down 에서 바로 밀지 않고 up 까지 기다린다 — 밀려던
        // 손짓이 화면 전환이 되면 안 된다(키바와 같은 규율).
        if (phase == 0) {
            // **down 은 톱니를 짚었을 때만 먹는다.** 예전에는 남아 있던 `set_active` 때문에
            // 톱니 근처도 아닌 down 을 chrome 이 가져가, 그 손짓이 통째로 사라졌다.
            set_active = setHit(set_gear_rect, x, y);
            if (!set_active) return 0;
            // **여기는 터미널 화면이라 설정 목록이 흐를 리가 없다.** 그런데 설정에서 나올 때
            // 남은 값이 그대로면 톱니가 영영 안 눌린다 — 실제로 그렇게 막혔다(테스트가 잡았다).
            set_stop_tap = false;
            set_down_x = x;
            set_down_y = y;
            set_moved = 0;
            return 1;
        }
        if (!set_active) return 0;
        if (phase == 1) {
            set_moved = @max(set_moved, @abs(x - set_down_x) + @abs(y - set_down_y));
            return 1;
        }
        set_active = false;
        if (phase == 2 and set_moved < scroll_area.Touch.slop_px and setHit(set_gear_rect, x, y)) {
            screen = .settings;
            set_sa.reset();
            set_touch.cancel();
        }
        return 1;
    }

    // 설정 화면이 떠 있으면 **전부 먹는다**.
    switch (phase) {
        0 => {
            set_active = true;
            set_down_x = x;
            set_down_y = y;
            set_last_y = y;
            set_moved = 0;
            // 키바와 같은 규칙 — 흐르는 목록을 세우려 짚었는데 그 자리 토글이 뒤집히면 안 된다.
            set_stop_tap = set_touch.begin(y);
            // **팝업이 열려 있으면 뒤로가기도 안 눌린 것이다.** 그 상태의 첫 탭은 어디를 짚든
            // 팝업을 닫는 것뿐인데(아래 up), 표시만 눌린 것으로 두면 **뒤로 갈 줄 알고 누른
            // 손가락에게 거짓말**이 된다. 행 눌림을 같은 이유로 막고 있었는데 여기만 빠졌다.
            set_back_pressed = !set_stop_tap and set_open == null and setHit(set_back_rect, x, y);
            set_pressed = null;
            if (!set_stop_tap and set_open == null and !set_back_pressed) {
                for (set_row_rects, 0..) |r, i| if (setHit(r, x, y)) {
                    set_pressed = i;
                    break;
                };
            }
        },
        1 => {
            if (!set_active) return 1;
            const dy = y - set_last_y;
            // **기준점은 임계와 무관하게 매 move 갱신한다**(키바 `kb_last_x` 와 같은 규칙).
            // 갱신을 임계 뒤로 미뤘더니 문턱을 넘는 첫 프레임이 **down 지점과의 차이**를
            // 통째로 적용해 목록이 10px 이상 **툭 뛰고**, 그 값이 그대로 관성 씨앗이 됐다.
            set_last_y = y;
            set_moved = @max(set_moved, @abs(x - set_down_x) + @abs(y - set_down_y));
            // **임계를 넘기 전에는 스크롤도 안 한다** — 살짝 민 손짓이 화면도 움직이고
            // 값도 바꾸면 같은 손짓이 어떨 때는 스크롤, 어떨 때는 입력으로 보인다.
            if (set_moved < scroll_area.Touch.slop_px) return 1;
            set_pressed = null;
            set_back_pressed = false;
            if (set_open != null) {
                // **팝업이 열려 있으면 팝업을 민다.** 안 그러면 목록 16개짜리 팝업에서 아래
                // 항목에 닿을 방법이 없다 — 화면이 유일한 입력 경로라 그 값이 영영 사라진다.
                _ = set_pop_sa.scrollByPx(@intFromFloat(-dy), @intFromFloat(@max(0, set_pop_max_scroll)));
                return 1;
            }
            if (set_open == null) {
                set_touch.move(&set_sa, y, @intFromFloat(@max(0, set_max_scroll)));
            }
        },
        else => {
            const was = set_active;
            set_active = false;
            // **뗄 때 관성이 시작된다.** 취소(3)는 관성도 안 남긴다 — 화면이 바뀌는데 목록이
            // 계속 흐르면 돌아왔을 때 보던 자리가 아니다.
            if (phase == 3) set_touch.cancel() else set_touch.end();
            const pressed = set_pressed;
            const back = set_back_pressed;
            set_pressed = null;
            set_back_pressed = false;
            if (!was or phase == 3 or set_moved >= 10) return 1;
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
                screen = .terminal; // pop
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
                .number => {
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
    if (screen == .terminal) return 0;
    screen = .terminal;
    // **진행 중이던 손짓도 함께 거둔다.** 손가락을 댄 채 뒤로가기를 누르면 up 이 안 와서
    // `set_active`·눌림 표시·관성이 터미널 화면까지 살아남는다 — 남은 관성이 목록을 계속
    // 밀고, 다시 들어오면 누른 적 없는 행이 눌린 것처럼 보인다.
    set_active = false;
    set_pressed = null;
    set_back_pressed = false;
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
const key_bar = [_]KeyBarItem{
    .{ .label = "esc", .key_id = 2 },
    .{ .label = "tab", .key_id = 3 },
    .{ .label = "ctrl", .key_id = 0, .sticky_mod = 2 }, // MARU_MOD_CTRL
    // 방향키는 **아이콘**이다(슬롯 6~9 — `maru_mobile_icon_build` 순서). 라벨은 접근성·계측용
    // 이름으로 남긴다.
    .{ .label = "\u{2191}", .key_id = 5, .icon_slot = arrow_slot_base + 0 },
    .{ .label = "\u{2193}", .key_id = 6, .icon_slot = arrow_slot_base + 1 },
    .{ .label = "\u{2190}", .key_id = 7, .icon_slot = arrow_slot_base + 2 },
    .{ .label = "\u{2192}", .key_id = 8, .icon_slot = arrow_slot_base + 3 },
    .{ .label = "|", .key_id = 0, .codepoint = '|' },
    .{ .label = "~", .key_id = 0, .codepoint = '~' },
    .{ .label = "/", .key_id = 0, .codepoint = '/' },
    .{ .label = "-", .key_id = 0, .codepoint = '-' },
    .{ .label = "copy", .key_id = 0, .is_copy = true },
};

/// `copy` 가 지금 쓸 수 있나(선택이 있나). 표시와 판정이 같은 값을 본다.
fn copyEnabled() bool {
    const core = &(term_core orelse return false);
    return core.selectionViewportSpan() != null;
}

/// 복사 요청. host 가 다음에 `maru_mobile_take_copy` 로 가져간다 — **클립보드는 OS 것이라
/// 브리지가 못 쓴다**(§3: 여기엔 OS 호출이 없다).
var copy_pending = false;

/// 레이아웃 id 는 이 값에 인덱스를 더한다. 라벨 id 는 카드 id + 100.
const key_bar_id_base: u64 = 500;

/// 마지막 build 가 잡아 준 각 키의 사각형. **판정도 배치를 아는 쪽이 한다**(§3) —
/// 플랫폼은 점만 넘긴다.
var key_bar_rects: [key_bar.len]struct { x: f32 = 0, y: f32 = 0, w: f32 = 0, h: f32 = 0 } = undefined;
var key_bar_ready = false;

/// 눌러 둔 수정자(sticky). **다음 한 글자**에만 실린다 — 계속 걸려 있으면 그 다음 타이핑이
/// 전부 제어문자가 된다.
var armed_mods: u32 = 0;

fn labelFor(id: u64) ?[]const u8 {
    if (id >= key_bar_id_base + 100 and id < key_bar_id_base + 100 + key_bar.len) {
        return key_bar[id - key_bar_id_base - 100].label;
    }
    return switch (id) {
        111 => "zsh",
        112 => "vim",
        113 => "logs",
        230 => "maru",
        231 => "web",
        232 => "docs",
        233 => "infra",
        234 => "scratch",
        // 본문 줄은 여기 없다 — TerminalCore 격자가 소유한다(pushTerminal).
        else => null,
    };
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

/// 누르고 있는 채로 시간이 지났는지 매 프레임 본다. **여기가 유일한 판정 자리다** —
/// 두 곳에 두면 한쪽만 고쳐져 갈린다.
fn checkLongPress(core: *terminal.core.TerminalCore) void {
    // `selecting` 을 또 보지 않는다 — 선택을 늘리려면 누른 칸을 벗어나야 하고 그 순간
    // `ptr_moved` 가 선다. 변이로 확인했다(그 조건을 지워도 아무 차이가 없었다).
    if (!ptr_down or ptr_moved) return;
    if (frame_ms < ptr_down_ms or frame_ms - ptr_down_ms < long_press_ms) return;
    if (bodyCell(ptr_down_x, ptr_down_y)) |c| {
        core.selectWordAt(c.row, c.col, &.{});
        selecting = true;
    }
}

pub export fn maru_mobile_build(width: u32, height: u32, time_ms: u64) u32 {
    frame_ms = time_ms;
    // 아틀라스 축출의 시간축. **벽시계(`time_ms`)가 아니라 프레임 순번**이다 — 축출이 판정해야
    // 하는 것은 "몇 초 전"이 아니라 "이번 프레임에 쓰였나"이고, 시계는 테스트에서 멈출 수 있다.
    frame_seq +%= 1;
    stepKeyBarFling();
    stepSetFling();
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
    if (screen == .settings) {
        drawSettings(.{ .x = 0, .y = 0, .w = @floatFromInt(width), .h = @floatFromInt(height) }, &tk);
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
