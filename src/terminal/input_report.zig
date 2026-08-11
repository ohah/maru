//! 입력/이벤트 → host(PTY) 바이트 인코딩 — 키·붙여넣기 인코딩 + focus/mouse 리포트.
//!
//! `TerminalCore`(core.zig)가 VT 파서 + 화면 storage + host-reply + 선택/kitty + 입력 인코딩을 한 struct에
//! 섞은 구조 위반(docs/project-rules.md "구조와 파일 분리")을 목적별 파일로 떼어낸 결과다. 여기는 "입력
//! 이벤트(키/붙여넣기)와 포커스/마우스 변화를 host(PTY)로 보낼 바이트로 바꾸는" 책임을 모은다(저수준 키 인코딩
//! 표는 input.zig, 응답 버퍼 적재는 core의 appendResponse). 각 함수는 `*TerminalCore`를 받는 free 함수다
//! (필드 직접 접근 — Zig는 필드 privacy가 없다; osc/parser/screen/selection/kitty와 동형). 외부(app/session/
//! keybinding)가 점-호출하는 pub API는 core.zig에 얇은 facade 메서드로 남고 본문만 여기 있다.
//!
//! encodeKey/encodePaste는 바이트를 **반환**(호출자가 PTY로 씀), reportFocus/reportMouse는 `self.appendResponse`로
//! 응답 버퍼에 **적재**(app이 매 write 후 PTY로 드레인). 응답 버퍼(`self.response`) primitive는 parser/osc/kitty도
//! 공유하므로 core 잔류. 베이스: xterm(focus event 1004, mouse 1000/1002/1003/1006/1015/1016/x10)·bracketed
//! paste(DECSET 2004) — 단일 출처는 각 함수 주석·docs/plans/terminal-core-decomposition.md §9.

const std = @import("std");
const core = @import("core.zig");
const input = @import("input.zig");

const TerminalCore = core.TerminalCore;

/// 붙여넣기 본문에서 공백으로 치환하는 위험 제어 바이트 집합. 어떤 삽입 방식(paste·drop)에서도 제거된다.
/// 베이스: xterm이 paste에서 항상 strip하는 제어문자(Ghostty input/paste.zig가 "copied directly from xterm's
/// source"로 같은 목록 사용). 개행(\n/\r)·탭(\t)은 여기 없음 — 개행은 encodePaste가 실행 트리거 \r로
/// 정규화하고(bracketed면 괄호가 감쌈), 탭은 정당한 공백이라 보존한다. ESC[201~ 조기 종료 인젝션은 이
/// 목록의 ESC(0x1b) 제거로 무력화된다(ECMA-48 C1/CSI가 ESC로 시작). VINTR·VSUSP 등 라인 규율 제어키는
/// tcsetattr로 프로그램이 바꿀 수 있어 100% 안전하진 않지만, xterm/Ghostty처럼 관례값을 하드코딩한다.
const paste_strip_bytes = [_]u8{
    0x00, // NUL
    0x08, // BS  (backspace — 앞 글자 삭제)
    0x05, // ENQ
    0x04, // EOT (Ctrl+D — EOF)
    0x1b, // ESC (C1/CSI 시퀀스·bracketed 종료 마커 인젝션 무력화)
    0x7f, // DEL
    0x03, // VINTR   (Ctrl+C)
    0x1c, // VQUIT   (Ctrl+\)
    0x15, // VKILL   (Ctrl+U)
    0x1a, // VSUSP   (Ctrl+Z)
    0x11, // VSTART  (Ctrl+Q)
    0x13, // VSTOP   (Ctrl+S)
    0x17, // VWERASE (Ctrl+W)
    0x16, // VLNEXT  (Ctrl+V — 다음 글자 리터럴 인용)
    0x12, // VREPRINT(Ctrl+R)
    0x0f, // VDISCARD(Ctrl+O)
};

fn isPasteStripByte(b: u8) bool {
    return std.mem.indexOfScalar(u8, &paste_strip_bytes, b) != null;
}

/// 붙여넣기 데이터가 "붙여넣는 순간 바로 실행"될 위험이 있는지(paste protection 판정용 순수 검사). 개행
/// (\n/\r — encodePaste가 실행 트리거 \r로 정규화)이나 bracketed paste 종료 마커(ESC[201~ — 괄호를 일찍
/// 닫아 뒤 내용을 타이핑으로 실행시키는 인젝션)가 있으면 unsafe. 베이스: Ghostty input/paste.zig `isSafe`
/// 동형(개행 + 종료 마커 검사). Ghostty는 \n만 보지만, maru encodePaste는 \r도 실행 \r로 흘리므로 \r도 본다.
pub fn pasteHasUnsafeBytes(data: []const u8) bool {
    return std.mem.indexOfScalar(u8, data, '\n') != null or
        std.mem.indexOfScalar(u8, data, '\r') != null or
        std.mem.indexOf(u8, data, "\x1b[201~") != null;
}

/// 이 붙여넣기가 사용자 확인을 요구하는지(paste protection 게이트). Ghostty Surface.zig 게이트 동형:
///   - protection이 꺼져 있으면 확인 안 함(false).
///   - bracketed paste 모드(DECSET 2004)면: (1) 본문에 종료 마커 ESC[201~가 있으면 bracketed여도 **항상**
///     확인(괄호 조기 종료 인젝션은 절대 신뢰 안 함), (2) 아니고 bracketed_safe가 true면 확인 생략(괄호가
///     감싸 자동 실행 안 됨), false면 개행 검사로 넘어간다.
///   - 비-bracketed면 pasteHasUnsafeBytes로 판정.
/// 베이스: Ghostty `clipboard-paste-protection` / `clipboard-paste-bracketed-safe`.
pub fn pasteNeedsConfirmation(self: *const TerminalCore, data: []const u8, protection_enabled: bool, bracketed_safe: bool) bool {
    return pasteNeedsConfirmationWith(self.bracketed_paste, data, protection_enabled, bracketed_safe);
}

/// pasteNeedsConfirmation의 순수 변형 — bracketed 모드를 명시 인자로 받는다(encodePasteWith와 대칭). host-backed
/// 원격 터미널은 placeholder core에 bracketed 상태가 없으므로(진짜 코어는 host 프로세스), 관측(RuntimeObservation)에서
/// 온 bracketed로 판정한다. 로컬(in-process) 경로는 위 래퍼가 self.bracketed_paste로 그대로 부른다.
pub fn pasteNeedsConfirmationWith(bracketed: bool, data: []const u8, protection_enabled: bool, bracketed_safe: bool) bool {
    if (!protection_enabled) return false;
    if (bracketed) {
        if (std.mem.indexOf(u8, data, "\x1b[201~") != null) return true; // bracketed여도 조기 종료 마커는 불신
        if (bracketed_safe) return false; // 괄호가 감싸 안전 → 확인 생략
    }
    return pasteHasUnsafeBytes(data);
}

/// 붙여넣기 바이트를 PTY 입력으로 인코딩한다: 개행을 CR로 정규화(\r\n/\n -> \r — 셸 입력의
/// 줄바꿈 관례)하고, 위험 제어 바이트(paste_strip_bytes — ESC 포함)를 공백으로 치환하며, 프로그램이
/// bracketed paste(DECSET 2004)를 켰으면 ESC[200~ ... ESC[201~로 감싼다(타이핑과 구분돼 자동 들여쓰기/
/// 즉시 실행 방지). 호출자가 free한다.
pub fn encodePaste(self: *const TerminalCore, allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    return encodePasteWith(self.bracketed_paste, allocator, bytes);
}

/// encodePaste의 **순수** 변형 — 코어에서 필요한 유일한 상태(bracketed paste 여부)를 값으로 받는다.
/// app이 `core_mutex` **아래에서 그 bool만 읽고**, 실제 인코딩(할당 + payload 전체 복사)은 **락 밖에서** 하도록
/// 쓴다: 멀티MB 붙여넣기를 코어 뮤텍스 안에서 인코딩하면 그동안 그 pane의 PTY reader 스레드가 막힌다(code-review).
pub fn encodePasteWith(bracketed_paste: bool, allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    if (bracketed_paste) try out.appendSlice(allocator, "\x1b[200~");
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        const b = bytes[i];
        if (b == '\r' or b == '\n') {
            try out.append(allocator, '\r');
            if (b == '\r' and i + 1 < bytes.len and bytes[i + 1] == '\n') i += 1; // CRLF는 한 번만
        } else if (isPasteStripByte(b)) {
            // 보안: 위험 제어 바이트를 공백으로 치환한다(paste_strip_bytes 주석 참조). 특히 ESC는 악성
            // 클립보드가 ESC[201~를 심어 bracketed paste 괄호를 일찍 닫고 뒤따르는 \r-종료 바이트를
            // "타이핑"으로 실행시키는 고전적 인젝션을 막고, VINTR/VSUSP 등은 붙여넣기가 시그널을 쏘는 걸 막는다.
            try out.append(allocator, ' ');
        } else {
            try out.append(allocator, b);
        }
    }
    if (bracketed_paste) try out.appendSlice(allocator, "\x1b[201~");
    return try out.toOwnedSlice(allocator);
}

/// focus reporting(DECSET 1004)이 켜져 있으면 창 포커스 변화를 CSI I(gained)/CSI O(lost)로 PTY에 리포트한다.
/// 베이스: xterm focus event(mode 1004) — 인코딩은 Ghostty `focus.zig`와 동일(`\x1b[I`/`\x1b[O`). off면 무동작.
pub fn reportFocus(self: *TerminalCore, gained: bool) void {
    if (!self.focus_events) return;
    self.appendResponse(if (gained) "\x1b[I" else "\x1b[O");
}

/// mouse 이벤트를 활성 tracking 모드/format으로 PTY에 리포트한다(mouse_tracking이 .none이 아닐 때).
/// col/row는 0-based 셀(인코딩은 1-based로 +1). x_px/y_px는 0-based backing(device) 픽셀로 SGR-Pixels(1016)
/// format에서만 쓴다 — platform이 활성 pane 좌상단 기준으로 보정해 전달하고, SGR/x10은 픽셀을 무시하고 셀 좌표를 쓴다.
/// button: 0=left,1=middle,2=right, 3=no-button(any-event motion), 64=wheel-up,65=wheel-down. mods 비트: 4=shift,8=meta(alt),16=ctrl.
/// motion이면 drag/move(button·any 모드만, Cb에 +32). 베이스: xterm — SGR(1006/1016) `CSI < Cb;Px;Py M`(press)/
/// `m`(release); x10 `CSI M` + (32+Cb)(32+Px)(32+Py) 바이트(좌표 223 초과는 깨져 SGR 권장, release는 버튼 미상이라 Cb=3).
pub fn reportMouse(self: *TerminalCore, button: u8, col: u16, row: u16, x_px: u16, y_px: u16, pressed: bool, motion: bool, mods: u8) void {
    if (self.mouse_tracking == .none) return;
    // motion(drag/move)은 button·any 모드만 리포트한다(x10/normal은 press·release만).
    if (motion and self.mouse_tracking != .button and self.mouse_tracking != .any) return;
    // x10은 press만 리포트(release를 안 보낸다).
    if (!pressed and self.mouse_tracking == .x10) return;
    const cb: u32 = @as(u32, button) + @as(u32, mods) + (if (motion) @as(u32, 32) else 0);
    var buf: [32]u8 = undefined;
    const out = switch (self.mouse_format) {
        .sgr => std.fmt.bufPrint(&buf, "\x1b[<{d};{d};{d}{c}", .{
            cb, @as(u32, col) + 1, @as(u32, row) + 1, @as(u8, if (pressed) 'M' else 'm'),
        }) catch return,
        // SGR-Pixels(1016): 1006과 같은 형식이되 셀이 아니라 픽셀 좌표를 1-based로 리포트한다.
        // 베이스: xterm ctlseqs "report position in pixels rather than character cells". 단위는
        // maru가 마우스·렌더 전반에 쓰는 backing(device) 픽셀로, xterm X11 device-pixel 관례와 정합한다.
        .sgr_pixels => std.fmt.bufPrint(&buf, "\x1b[<{d};{d};{d}{c}", .{
            cb, @as(u32, x_px) + 1, @as(u32, y_px) + 1, @as(u8, if (pressed) 'M' else 'm'),
        }) catch return,
        // urxvt(1015): x10과 같은 Cb(32 offset)·1-based 셀 좌표를 바이트가 아니라 십진수 `CSI Cb;Px;Py M`로
        // 보낸다(release는 x10처럼 Cb=3). 좌표 무제한이라 x10의 >223 깨짐이 없다. 베이스: urxvt 1015.
        .urxvt => blk: {
            const eb: u32 = if (pressed) cb else 3;
            break :blk std.fmt.bufPrint(&buf, "\x1b[{d};{d};{d}M", .{
                32 + eb, @as(u32, col) + 1, @as(u32, row) + 1,
            }) catch return;
        },
        .x10 => blk: {
            // x10은 release 시 버튼 미상이라 Cb=3(sentinel). 각 바이트 32 offset, 255 saturate(>223 깨짐).
            const eb: u32 = if (pressed) cb else 3;
            break :blk std.fmt.bufPrint(&buf, "\x1b[M{c}{c}{c}", .{
                @as(u8, @intCast(@min(32 + eb, 255))),
                @as(u8, @intCast(@min(32 + @as(u32, col) + 1, 255))),
                @as(u8, @intCast(@min(32 + @as(u32, row) + 1, 255))),
            }) catch return;
        },
    };
    self.appendResponse(out);
}

/// KeyEvent를 PTY로 보낼 바이트로 인코딩한다(input.encodeKey 위임 — 저수준 표는 input.zig). 현재 입력 모드
/// (encodeOptions)를 넘겨 DECCKM/kitty/keypad를 반영한다. 호출자가 buffer를 소유(반환은 그 슬라이스).
pub fn encodeKey(self: *const TerminalCore, event: input.KeyEvent, buffer: *[input.encoded_key_buffer_len]u8) ![]const u8 {
    return input.encodeKey(event, buffer, encodeOptions(self));
}

/// 이 surface의 현재 입력 인코딩 모드. 키를 인코딩하는 쪽(keybinding resolver 경유 포함)이
/// 매 키마다 읽어 전달한다 — DECCKM은 프로그램이 수시로 켜고 끈다(vim 진입/이탈).
pub fn encodeOptions(self: *const TerminalCore) input.EncodeOptions {
    return .{ .application_cursor_keys = self.application_cursor_keys, .kitty_flags = self.kitty_flags.current().int(), .application_keypad = self.application_keypad };
}
