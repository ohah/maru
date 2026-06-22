//! OSC(Operating System Command) host-reply 핸들러 — 색·팔레트 질의/설정(OSC 10/11/4/104).
//!
//! `TerminalCore`의 "host-reply/encoding" 책임(rule: parser·storage·encoding이 한 파일에서 서로 다른 이유로
//! 바뀌면 facade는 유지하되 구현을 목적별로 분리 — docs/project-rules.md "구조와 파일 분리")을 목적별 파일로 떼어낸다.
//! struct·facade(terminal.zig)는 불변이고, 각 핸들러는 `*TerminalCore`를 받는 free 함수다(필드 + pub helper만 접근).
//! 진입점 `dispatchOsc`는 core.zig에 남아 여기 함수로 위임한다(점진 분리 — PR 단위로 나머지 OSC도 이리로 이주).
//!
//! 베이스: xterm ctlseqs OSC 4/10/11/104(사실상 표준). 단일 표준 없는 동작의 결정은 해당 핸들러 주석·
//! docs/terminal-compatibility-policy.md를 단일 출처로 둔다.

const std = @import("std");
const core = @import("core.zig");
const types = @import("types.zig");

const TerminalCore = core.TerminalCore;

/// OSC 10/11(전경/배경 색) 설정·질의. spec이 `?`면 현재 색(override 또는 주입된 theme)을 xterm 형식
/// `OSC <code> ; rgb:rrrr/gggg/bbbb ST`로 회신한다(nvim 등이 배경 밝기로 light/dark 테마를 감지). color
/// spec이면 그 색을 `default_fg/bg_override`에 둔다 — 렌더러 default 색과 화면 clear color를 app이 그
/// override로 바꾼다(OSC 4 팔레트와 같은 결: 코어가 override 보관, app이 CellColors/clear로 wiring).
/// theme 기본 RGB는 platform이 setDefaultColors로 주입(코어는 Color.default 추상만 알아 실제 RGB는 받는다).
/// OSC 110/111이 리셋. 베이스: xterm ctlseqs OSC 10/11.
pub fn dispatchDefaultColor(self: *TerminalCore, body: []const u8, code: u16) void {
    // 여러 `;` 필드 중 첫 필드만 본다(xterm 연속 설정 `OSC 10 ; fg ; bg`는 후속).
    var it = std.mem.splitScalar(u8, body, ';');
    const spec = it.next() orelse return;
    if (std.mem.eql(u8, spec, "?")) {
        // 질의: override가 있으면 그 색, 없으면 주입된 theme 색을 회신(설정 직후 질의가 set 값을 본다).
        const base = if (code == 10) self.default_fg_rgb else self.default_bg_rgb;
        const ovr = if (code == 10) self.default_fg_override else self.default_bg_override;
        const rgb = ovr orelse base;
        var buf: [40]u8 = undefined;
        // 8-bit 채널을 16-bit로 복제(0xAB → 0xABAB) — xterm 4-hex-per-channel 표준 형식.
        const resp = std.fmt.bufPrint(&buf, "\x1b]{d};rgb:{x:0>2}{x:0>2}/{x:0>2}{x:0>2}/{x:0>2}{x:0>2}\x1b\\", .{
            code, rgb.r, rgb.r, rgb.g, rgb.g, rgb.b, rgb.b,
        }) catch return;
        self.appendResponse(resp);
    } else if (types.parseSpec(spec)) |rgb| {
        // 설정: default 전경/배경 override를 둔다 — 렌더러 default 색을 app이 override로 바꾼다.
        if (code == 10) {
            self.default_fg_override = rgb;
        } else {
            self.default_bg_override = rgb;
        }
    }
}

/// OSC 4 — 256색 팔레트 설정/질의. `<index>;<spec>` 쌍을 반복 파싱한다. spec이 `?`면 현재 색(우선순위
/// override > config base(idx<16) > 기본 xterm256)을 `OSC 4 ; <index> ; rgb:rrrr/gggg/bbbb ST`로 회신, color
/// spec이면 그 인덱스를 덮어쓴다. 인덱스는 0..255(parseInt u8 — 256+ 자동 실패→skip). 짝이 안 맞는 끝 토큰은
/// 버린다. 베이스: xterm ctlseqs OSC 4(`rgb:`/`#` 색 명세). 색 적용은 렌더러가 palette_override+config_palette를
/// 소비(코어는 표만 보관 — K1 경계). query 응답은 렌더(metal_frame)와 같은 우선순위라 화면·보고가 일치한다.
pub fn dispatchPalette(self: *TerminalCore, body: []const u8) void {
    var it = std.mem.splitScalar(u8, body, ';');
    while (it.next()) |idx_str| {
        const spec = it.next() orelse break; // 쌍이 안 맞는 마지막 index는 무시
        const idx = std.fmt.parseInt(u8, idx_str, 10) catch continue; // 0..255 밖 → skip
        if (std.mem.eql(u8, spec, "?")) {
            // 렌더(metal_frame.paletteColor)와 동일 우선순위: OSC4 override → config base(idx<16) → xterm256.
            const rgb = self.palette_override[idx] orelse
                (if (idx < 16) self.config_palette[idx] else null) orelse
                types.xterm256(idx);
            var buf: [48]u8 = undefined;
            // 8-bit 채널을 16-bit로 복제(0xAB → 0xABAB) — xterm 4-hex-per-channel 표준 응답 형식.
            const resp = std.fmt.bufPrint(&buf, "\x1b]4;{d};rgb:{x:0>2}{x:0>2}/{x:0>2}{x:0>2}/{x:0>2}{x:0>2}\x1b\\", .{
                idx, rgb.r, rgb.r, rgb.g, rgb.g, rgb.b, rgb.b,
            }) catch continue;
            self.appendResponse(resp);
        } else if (types.parseSpec(spec)) |rgb| {
            self.palette_override[idx] = rgb;
        }
    }
}

/// OSC 104 — 팔레트 리셋. body가 비면 전부 기본 xterm256으로(override 제거), 아니면 `;`로 나눈 인덱스만.
/// 베이스: xterm ctlseqs OSC 104.
pub fn dispatchPaletteReset(self: *TerminalCore, body: []const u8) void {
    if (body.len == 0) {
        @memset(&self.palette_override, null);
        return;
    }
    var it = std.mem.splitScalar(u8, body, ';');
    while (it.next()) |s| {
        const idx = std.fmt.parseInt(u8, s, 10) catch continue;
        self.palette_override[idx] = null;
    }
}
