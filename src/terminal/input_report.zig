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
//! paste(DECSET 2004) — 단일 출처는 각 함수 주석·docs/terminal-core-decomposition.md §9.

const std = @import("std");
const core = @import("core.zig");
const input = @import("input.zig");

const TerminalCore = core.TerminalCore;

/// 붙여넣기 바이트를 PTY 입력으로 인코딩한다: 개행을 CR로 정규화(\r\n/\n -> \r — 셸 입력의
/// 줄바꿈 관례)하고, 프로그램이 bracketed paste(DECSET 2004)를 켰으면 ESC[200~ ... ESC[201~로
/// 감싼다(타이핑과 구분돼 자동 들여쓰기/즉시 실행 방지). 호출자가 free한다.
pub fn encodePaste(self: *const TerminalCore, allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    if (self.bracketed_paste) try out.appendSlice(allocator, "\x1b[200~");
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        const b = bytes[i];
        if (b == '\r' or b == '\n') {
            try out.append(allocator, '\r');
            if (b == '\r' and i + 1 < bytes.len and bytes[i + 1] == '\n') i += 1; // CRLF는 한 번만
        } else if (b == 0x1b) {
            // 보안: 붙여넣기 본문의 ESC를 공백으로 치환한다. 안 그러면 악성 클립보드가 ESC[201~
            // 를 심어 bracketed paste 괄호를 일찍 닫고, 뒤따르는 \r-종료 바이트가 "타이핑"으로
            // 실행된다(고전적 paste 인젝션). bracketed paste를 안 쓸 때도 ESC 시퀀스가 그대로
            // 터미널에 주입되는 걸 막는다. ECMA-48의 C1/CSI는 ESC로 시작하므로 ESC만 막으면
            // 시퀀스가 무력화된다. Ghostty(input/paste.zig)도 같은 보호를 한다.
            try out.append(allocator, ' ');
        } else {
            try out.append(allocator, b);
        }
    }
    if (self.bracketed_paste) try out.appendSlice(allocator, "\x1b[201~");
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
