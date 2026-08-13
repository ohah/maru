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

// **고정 버퍼로는 resize 를 못 버틴다.** `FixedBufferAllocator` 는 마지막 할당 말고는
// free 가 no-op 이라, 격자가 바뀔 때마다 옛 격자를 영영 못 돌려받는다 — 512KB 로 **resize
// 7번**이면 OutOfMemory 였다(헤드리스 실측). 키보드를 서너 번 올렸다 내리면 닿는 수다.
//
// `page_allocator` 를 쓴다: 전역 싱글턴이 없고(우리는 남의 앱 프로세스 안에 들어가는
// 라이브러리다) free 가 실제로 메모리를 돌려준다. 페이지 단위 반올림 손실은 코어 할당이
// 몇 개뿐이라 작다 — 원격 세션(M3)이 붙어 처리량이 생기면 그때 재보고 정한다.
const term_allocator = std.heap.page_allocator;
var term_core: ?terminal.core.TerminalCore = null;
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
    "emoji \u{1F600}\u{1F389}\u{1F680} + 한글 가나\r\n";

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
        const seq_len = std.unicode.utf8ByteSequenceLength(ptr[0]) catch 1;
        const first = std.unicode.utf8Decode(ptr[0..seq_len]) catch {
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
                        if (c.row != d.row or c.col != d.col) core.selectionExtend(c.row, c.col);
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
            // 선택은 손을 떼도 **남는다** — 떼자마자 사라지면 복사할 수가 없다.
            if (phase == 3) {
                core.selectionClear();
                selecting = false;
            }
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

/// 보조 키바 탭. **좌표는 여기서만 해석한다** — 그리는 자리와 판정하는 자리가 갈리면
/// 눌러도 다른 키가 나간다. 1=이 탭은 키바가 먹었다, 0=키바 밖(플랫폼이 본문 처리로).
pub export fn maru_mobile_keybar_tap(x: f32, y: f32) u32 {
    if (!key_bar_ready) return 0;
    for (key_bar_rects, 0..) |r, i| {
        if (!keyBarVisible(i)) continue; // 안 보이는 키는 못 누른다
        if (x < r.x or x >= r.x + r.w or y < r.y or y >= r.y + r.h) continue;
        const item = key_bar[i];
        if (item.is_copy) {
            copy_pending = true;
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
    return 0;
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
    const n = @min(text.len, cap);
    if (n < text.len) setLastError("copy_truncated"); // 조용히 자르지 않는다
    @memcpy(out[0..n], text[0..n]);
    return @intCast(n);
}

pub export fn maru_mobile_armed_mods() u32 {
    return armed_mods;
}

/// **지금 줄에 있는** 키 수. 총 개수가 아니라 보이는 수다 — `copy` 는 선택이 있을 때만
/// 나타나므로, 총 개수를 답하면 host 도 테스트도 없는 키를 있다고 믿는다.
pub export fn maru_mobile_keybar_count() u32 {
    var n: u32 = 0;
    for (0..key_bar.len) |i| {
        if (keyBarVisible(i)) n += 1;
    }
    return n;
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
    const surface_bg = tk.get(.surface_bg);

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
            const glyph = atlasCell(cell.codepoint, styleBits(cell.style)) orelse continue;
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
    return .{
        .foreground = .{ .r = 0xE6, .g = 0xE6, .b = 0xEA },
        .sidebar_background = .{ .r = 0x24, .g = 0x24, .b = 0x2E },
        .sidebar_foreground = .{ .r = 0xD0, .g = 0xD0, .b = 0xD8 },
        .sidebar_active = .{ .r = 0x3A, .g = 0x3A, .b = 0x4A },
        .search_match = .{ .r = 0x4A, .g = 0x4A, .b = 0x20 },
        .search_match_current = .{ .r = 0x8A, .g = 0x7A, .b = 0x20 },
        .selection = .{ .r = 0x30, .g = 0x40, .b = 0x60 },
        .cursor = .{ .r = 0xE6, .g = 0xE6, .b = 0xEA },
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

var atlas_cp: [atlas_cap]u32 = undefined;
var atlas_col: [atlas_cap]u32 = undefined;
var atlas_row: [atlas_cap]u32 = undefined;
var atlas_adv: [atlas_cap]u32 = undefined;
var atlas_n: usize = 0;
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

pub export fn maru_mobile_atlas_add(cp: u32, style: u32, col: u32, row: u32, advance: u32) void {
    const key = atlasKey(cp, style);
    // 등록되면 "없음" 목록에서 뺀다. 안 그러면 아틀라스가 서기 **전에** 한 번 돈 build 가
    // 남긴 목록 때문에 이미 있는 글자를 슬롯만 축내며 다시 굽는다(실측: grew=15 가 전부
    // 'z' 같은 ASCII 중복이었다).
    var i: usize = 0;
    while (i < miss_n) : (i += 1) {
        if (miss_cp[i] == key) {
            miss_cp[i] = miss_cp[miss_n - 1];
            miss_n -= 1;
            break;
        }
    }
    for (0..atlas_n) |j| if (atlas_cp[j] == key) return; // 이미 있으면 슬롯을 안 쓴다
    if (atlas_n == atlas_cp.len) return;
    atlas_cp[atlas_n] = key;
    atlas_col[atlas_n] = col;
    atlas_row[atlas_n] = row;
    atlas_adv[atlas_n] = advance;
    atlas_n += 1;
}

// **아틀라스는 자란다.** 처음 보는 글자는 그릴 글리프가 없어 조용히 안 그려진다 — 고정
// 집합으로 두면 입력·원격 출력의 새 글자가 전부 사라진다(실측으로 드러났다: 키를 넣었더니
// 코어엔 들어왔는데 화면이 그대로였다).
// 여기서는 **놓친 코드포인트를 모아** 플랫폼이 그것만 구워 넣게 한다. 슬롯 추가는
// 아틀라스 부분 업데이트(여섯 기능 4번)를 그대로 쓴다.
var miss_cp: [64]u32 = undefined;
var miss_n: usize = 0;

/// 못 그린 것은 **(코드포인트, 스타일) 짝**으로 모은다 — 같은 글자라도 굵은 판은 따로 구워야 한다.
fn noteMiss(key: u32) void {
    for (0..miss_n) |i| if (miss_cp[i] == key) return;
    if (miss_n == miss_cp.len) return;
    miss_cp[miss_n] = key;
    miss_n += 1;
}

/// 플랫폼이 부른다: 아직 아틀라스에 없는 코드포인트 개수.
pub export fn maru_mobile_missing_count() u32 {
    return @intCast(miss_n);
}

/// i번째 놓친 코드포인트. 플랫폼이 이걸 구워 `maru_mobile_atlas_add` 로 넣는다.
pub export fn maru_mobile_missing_cp(i: u32) u32 {
    if (i >= miss_n) return 0;
    return miss_cp[i] & 0xFFFFFF;
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
    if (atlas_n >= atlas_cap) return 0xFFFFFFFF;
    const idx: u32 = @intCast(atlas_n);
    return ((idx % cols) << 16) | (idx / cols);
}

// ── 컬러 글리프(이모지) ────────────────────────────────────────────────────────
// **글자 아틀라스는 커버리지(R8)라 컬러를 못 담는다.** 컬러 비트맵을 거기 넣으면 실루엣이
// 된다. 그래서 컬러 전용 아틀라스를 따로 세운다 — 아이콘 아틀라스가 이미 RGBA8 로 서 있어
// 같은 모양이 하나 더 서는 것뿐이고, 텍스트 아틀라스의 **커버리지 계약(§4)은 안 흔든다**.
//
// **컬러인지는 코어가 정한다.** `width.isEmojiPresentation` 이 단일 출처라, 여기서 규칙을
// 다시 쓰면 컬러 판정이 갈린다(데스크톱 렌더러도 같은 함수를 본다).
fn isColorGlyph(cp: u32) bool {
    if (cp > 0x10FFFF) return false;
    return maru.width.isEmojiPresentation(@intCast(cp));
}

var color_cp: [atlas_cap]u32 = undefined;
var color_col: [atlas_cap]u32 = undefined;
var color_row: [atlas_cap]u32 = undefined;
var color_adv: [atlas_cap]u32 = undefined;
var color_n: usize = 0;

/// i번째 놓친 것이 **컬러 글리프인가**. host 는 이 값으로 어느 아틀라스에 구울지 고른다 —
/// 커버리지 아틀라스에 컬러를 구우면 실루엣이 되고, 그 반대는 색이 사라진다.
pub export fn maru_mobile_missing_is_color(i: u32) u32 {
    if (i >= miss_n) return 0;
    return if (isColorGlyph(miss_cp[i] & 0xFFFFFF)) 1 else 0;
}

/// 컬러 아틀라스에 구운 글리프를 등록한다(글자 아틀라스의 `maru_mobile_atlas_add` 와 짝).
pub export fn maru_mobile_color_atlas_add(cp: u32, style: u32, col: u32, row: u32, advance: u32) void {
    const key = atlasKey(cp, style);
    var i: usize = 0;
    while (i < miss_n) : (i += 1) {
        if (miss_cp[i] == key) {
            miss_cp[i] = miss_cp[miss_n - 1];
            miss_n -= 1;
            break;
        }
    }
    for (0..color_n) |j| if (color_cp[j] == key) return;
    if (color_n == color_cp.len) return;
    color_cp[color_n] = key;
    color_col[color_n] = col;
    color_row[color_n] = row;
    color_adv[color_n] = advance;
    color_n += 1;
}

/// 컬러 아틀라스의 다음 빈 슬롯(글자 쪽과 같은 인코딩·같은 소진 규약).
pub export fn maru_mobile_next_color_slot(cols: u32) u32 {
    if (color_n >= atlas_cap) return 0xFFFFFFFF;
    const idx: u32 = @intCast(color_n);
    return ((idx % cols) << 16) | (idx / cols);
}

/// 등록된 컬러 글리프 수(테스트·진단용 — 등록이 실제로 됐는지 값으로 본다).
pub export fn maru_mobile_color_atlas_count() u32 {
    return @intCast(color_n);
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

fn atlasCell(cp: u21, style: u32) ?struct { col: u32, row: u32, adv: u32, color: bool = false } {
    const key = atlasKey(cp, style);
    // **컬러 글자는 컬러 등록부에서 찾는다.** 두 아틀라스가 슬롯 번호를 각자 세므로, 글자
    // 아틀라스에서 찾으면 엉뚱한 슬롯을 가리킨다.
    if (isColorGlyph(cp)) {
        for (0..color_n) |i| if (color_cp[i] == key)
            return .{ .col = color_col[i], .row = color_row[i], .adv = color_adv[i], .color = true };
        // **컬러 아틀라스가 없으면 커버리지에 구워 둔 것이라도 쓴다.** 컬러를 모르는 host 는
        // 이모지를 커버리지에 굽고 `atlas_add` 로 등록하는데, 여기서 컬러 등록부만 보면 영영
        // 못 찾아 **매 프레임 다시 굽는다**(실측: 3프레임 내내 미스 목록에 남았다). 이 저장소가
        // 아틀라스가 꽉 찼을 때 이미 한 번 겪은 실패 모드다.
        for (0..atlas_n) |i| if (atlas_cp[i] == key)
            return .{ .col = atlas_col[i], .row = atlas_row[i], .adv = atlas_adv[i] };
        noteMiss(key);
        return null;
    }
    for (0..atlas_n) |i| if (atlas_cp[i] == key)
        return .{ .col = atlas_col[i], .row = atlas_row[i], .adv = atlas_adv[i] };
    noteMiss(key);
    return null;
}

/// 셀의 SGR 굵기·기울임을 아틀라스 스타일 비트로. **여기가 단일 출처다** — 글자를 그리는
/// 자리와 굽는 자리가 같은 값을 봐야 굵은 글자가 보통 슬롯을 덮어쓰지 않는다.
fn styleBits(s: terminal.types.Style) u32 {
    return (if (s.bold) style_bold else 0) | (if (s.italic) style_italic else 0);
}

/// 문자열을 글자 quad 로 분해한다. **폭은 maru 의 EAW 규칙을 따른다** — 한글은 2셀이다.
fn pushText(text: []const u8, x0: i32, y0: i32, font_px: i32, rgb: anytype) void {
    // 셀 종횡비를 지킨다 — 임의 크기 상자에 셀을 넣으면 글자가 늘어난다.
    const scale = @as(f32, @floatFromInt(font_px)) / @as(f32, @floatFromInt(atlas_cell_h));
    // **슬롯 하나는 양폭(한글) 상자고 단폭 글자는 왼쪽 절반만 쓴다**(M4a3, §글리프 기하).
    // 여기가 그 절반 규칙을 안 따라와 슬롯 **전체**를 샘플링하고 있었다.
    const draw_w: i32 = @intFromFloat(@as(f32, @floatFromInt(atlas_cell_w)) * scale * 0.5);
    var pen = x0;
    var view = std.unicode.Utf8View.init(text) catch return;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        const cell = atlasCell(cp, 0);
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
                        .kind = if (c.color) 5 else 3,
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
const icon_slot_px = 32;
const icon_slots = 6;
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
    const cps = [icon_slots]u32{
        maru.icons.codepoint(.git_branch),
        maru.icons.codepoint(.gear),
        maru.icons.codepoint(.plus),
        maru.icons.codepoint(.search),
        maru.icons.codepoint(.bell),
        maru.icons.codepoint(.sidebar_collapse),
    };
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
    const status = tree.container(.{ .id = 400, .direction = .row, .style = .{ .height = .{ .px = 26.0 }, .padding = .{ .left = 12.0, .right = 12.0, .top = 5.0, .bottom = 5.0 } } }, &.{
        tree.card(.{ .id = 401, .style = .{ .flex = .{ .grow = 1 }, .height = .{ .px = 16.0 }, .margin = .{ .right = 10.0 } }, .variant = .raised }, &.{}),
        tree.card(.{ .id = 402, .style = .{ .flex = .{ .grow = 1.4 }, .height = .{ .px = 16.0 } }, .variant = .raised }, &.{}),
    });

    // ── 보조 키바: 소프트 키보드에 없는 키들(Ctrl·Esc·Tab·화살표) + 셸 문장부호
    var bar_kids: [key_bar.len][1]tree.UiNode = undefined;
    var bar_children: [key_bar.len]tree.UiNode = undefined;
    // 안 보이는 키(선택 없을 때의 `copy`)는 자리도 안 차지한다 — 빈 칸으로 두면 줄이
    // 어색하게 벌어지고, 그 자리를 눌렀을 때 뭐가 되는지도 애매해진다.
    var bar_n: usize = 0;
    for (0..key_bar.len) |i| {
        if (!keyBarVisible(i)) continue;
        const c = &bar_children[bar_n];
        bar_n += 1;
        bar_kids[i] = .{tree.text(.{
            .id = key_bar_id_base + 100 + i,
            .style = .{ .width = .{ .px = 26.0 }, .height = .{ .px = 13.0 }, .margin = .{ .left = 5.0, .top = 9.0 } },
            .value = key_bar[i].label,
            // 눌러 둔 수정자는 **켜져 있다는 것이 보여야** 한다 — 안 보이면 왜 제어문자가
            // 나가는지 알 수 없다.
            .tone = if (key_bar[i].sticky_mod != 0 and armed_mods != 0) .accent else .primary,
        })};
        c.* = tree.card(.{
            .id = key_bar_id_base + i,
            // **키 폭을 고정한다.** 전부 flex 로 나눠 가지면 `copy` 가 나타날 때 나머지 키가
            // 전부 왼쪽으로 밀린다(실측: 마지막 키가 30px — 거의 한 칸). 선택을 잡은 직후
            // 그 자리를 누르면 옆 키가 눌린다. `copy` 만 남는 자리를 쓴다.
            .style = if (key_bar[i].is_copy)
                .{ .flex = .{ .grow = 1 }, .height = .{ .px = 32.0 }, .margin = .{ .right = 3.0 } }
            else
                .{ .width = .{ .px = 30.0 }, .height = .{ .px = 32.0 }, .margin = .{ .right = 3.0 } },
            .variant = if (key_bar[i].sticky_mod != 0 and armed_mods != 0) .selected else .surface,
        }, &bar_kids[i]);
    }
    const bar = tree.container(.{ .id = key_bar_id_base - 1, .direction = .row, .style = .{ .height = .{ .px = 40.0 }, .padding = .{ .left = 6.0, .right = 6.0, .top = 4.0, .bottom = 4.0 } } }, bar_children[0..bar_n]);

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
        .quad => |q| push(q.rect, tk.get(q.fill_role), q.alpha, q.corner_radii[0], 0),
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
    var bar_found: usize = 0;
    for (built.entries) |entry| {
        if (entry.id < key_bar_id_base or entry.id >= key_bar_id_base + key_bar.len) continue;
        key_bar_rects[entry.id - key_bar_id_base] = .{
            .x = entry.rect.x,
            .y = entry.rect.y,
            .w = entry.rect.width,
            .h = entry.rect.height,
        };
        bar_found += 1;
    }
    // 보이는 키만큼만 자리가 잡힌다(선택이 없으면 `copy` 가 빠진다).
    var want_bar: usize = 0;
    for (0..key_bar.len) |i| {
        if (keyBarVisible(i)) want_bar += 1;
    }
    key_bar_ready = bar_found == want_bar;

    // **본문은 진짜 터미널 코어다.** 레이아웃이 잡아 준 본문 사각형에 셀 격자를 채운다.
    for (built.entries) |entry| {
        if (entry.id != 300) continue;
        pushTerminal(entry.rect, tk);
        break;
    }

    // **SVG 아이콘**: maru 의 등록 아이콘을 그대로 얹는다. coverage 는 Zig 가 만들고
    // (renderer/icon_glyph) 플랫폼은 텍스처로 올려 샘플링만 한다 — 자산이 이식된다는 증거다.
    const icon_y: i32 = @intFromFloat(@max(0, height_f - 24));
    const icon_step: i32 = 26;
    const icon_x0: i32 = @as(i32, @intCast(width)) - icon_step * 6 - 12;
    for (0..6) |i| {
        if (!reserveQuad()) break;
        const rgb = tk.get(if (i == 0) .accent_bar else .surface_fg);
        quad_buf[quad_count] = .{
            .x = @floatFromInt(icon_x0 + icon_step * @as(i32, @intCast(i))),
            .y = @floatFromInt(icon_y),
            .w = 18,
            .h = 18,
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
    /// 키가 아니라 **복사**다. 선택이 있을 때만 줄에 나타난다 — 늘 두면 한 줄에 자리가
    /// 모자라고(11개가 상한), 누를 수 없는 버튼이 계속 보이는 것도 어색하다.
    is_copy: bool = false,
};

/// 한 줄에 들어가야 한다 — 폰 세로 폭(~400 논리 px)에 11개가 상한이다.
const key_bar = [_]KeyBarItem{
    .{ .label = "esc", .key_id = 2 },
    .{ .label = "tab", .key_id = 3 },
    .{ .label = "ctrl", .key_id = 0, .sticky_mod = 2 }, // MARU_MOD_CTRL
    .{ .label = "\u{2191}", .key_id = 5 },
    .{ .label = "\u{2193}", .key_id = 6 },
    .{ .label = "\u{2190}", .key_id = 7 },
    .{ .label = "\u{2192}", .key_id = 8 },
    .{ .label = "|", .key_id = 0, .codepoint = '|' },
    .{ .label = "~", .key_id = 0, .codepoint = '~' },
    .{ .label = "/", .key_id = 0, .codepoint = '/' },
    .{ .label = "-", .key_id = 0, .codepoint = '-' },
    .{ .label = "copy", .key_id = 0, .is_copy = true },
};

/// 선택이 없으면 `copy` 는 줄에서 빠진다.
fn keyBarVisible(i: usize) bool {
    if (!key_bar[i].is_copy) return true;
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
