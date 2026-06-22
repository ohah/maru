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

/// OSC 52(클립보드)가 한 번에 받는 디코드 결과의 상한(바이트) — drain 안 돼도 무한정 안 자라게 하는 폭주 방어선.
const max_clipboard_bytes: usize = 16 * 1000 * 1000;

/// OSC 52(클립보드) — `52;<targets>;<base64>`로 system clipboard 쓰기를 요청한다(tmux/nvim이 SSH 너머
/// `"+y`로 씀). **코어는 파싱+base64 디코드만** 하고 결과를 clipboard_write pending에 둔다 — 실제 clipboard
/// 쓰기와 정책(osc52.write ask/allow/deny)은 app/platform 책임이다(클립보드는 OS 리소스라 native 소유 —
/// terminal-compatibility-policy.md "TerminalCore parses OSC52, app/platform layer만 실제 read/write"). 읽기
/// (data가 `?`)는 코어가 target만 기억하고 clipboard_read_pending을 세운다(무시하지 않는다) — 실제 base64 읽기와
/// osc52.read(allow|deny, 기본 deny) 정책은 app/platform이 한다(write 대칭, 코어는 OS 클립보드를 직접 안 읽음 —
/// 원격 세션의 clipboard 탈취는 기본 deny로 막고, ask UI는 후속). 베이스: xterm/iTerm2 OSC 52(사실상 표준),
/// 보안 정책은 호환성/보안 정책 문서.
pub fn dispatchClipboard(self: *TerminalCore, body: []const u8) void {
    const semi = std.mem.indexOfScalar(u8, body, ';') orelse return; // <targets>;<data>
    const targets = body[0..semi];
    const data = body[semi + 1 ..];
    if (data.len == 0) return; // 빈 데이터 무시
    if (std.mem.eql(u8, data, "?")) {
        // 읽기 쿼리(`OSC 52 ; <Pc> ; ? ST`): target만 기억하고 pending을 세운다 — 실제 클립보드 읽기·정책(osc52.read)·
        // base64 응답은 platform(app)이 한다(write 대칭, 코어는 OS 클립보드를 직접 안 읽음). target은 응답에 그대로 echo.
        self.clipboard_read_target.clearRetainingCapacity();
        self.clipboard_read_target.appendSlice(self.allocator, targets) catch return;
        self.clipboard_read_pending = true;
        return;
    }
    const dec = std.base64.standard.Decoder;
    const decoded_len = dec.calcSizeForSlice(data) catch return; // 잘못된 base64
    if (decoded_len == 0 or decoded_len > max_clipboard_bytes) return; // 빈/과대 거부(폭주 방어선)
    self.clipboard_write.resize(self.allocator, decoded_len) catch return;
    dec.decode(self.clipboard_write.items, data) catch {
        self.clipboard_write.clearRetainingCapacity();
        return;
    };
}

/// OSC 777(rxvt/urxvt) 데스크톱 알림 — `OSC 777 ; notify ; <title> ; <body>`. `notify;` 접두만 처리하고
/// 나머지를 첫 `;`로 title/body로 가른다(body는 `;` 포함 가능). body가 없으면 빈 문자열. 다른 777 서브타입
/// (notify 외)은 무시. 베이스: urxvt OSC 777 notify.
pub fn dispatchNotify777(self: *TerminalCore, body: []const u8) void {
    if (!std.mem.startsWith(u8, body, "notify;")) return; // notify 외 777 서브타입은 미지원(소비만)
    const rest = body["notify;".len..];
    const sep = std.mem.indexOfScalar(u8, rest, ';');
    if (sep) |i| {
        setNotification(self, rest[0..i], rest[i + 1 ..]);
    } else {
        setNotification(self, rest, ""); // body 없는 형태: title만
    }
}

/// OSC 9(iTerm2) 데스크톱 알림 — `OSC 9 ; <message>`(title 없음, body=message). **ConEmu 충돌**: OSC 9는
/// ConEmu가 `9;1`(sleep)·`9;2`(msgbox)·`9;4`(progress)·`9;9`(cwd) 등으로도 쓴다. 이들을 알림으로 오발사하면
/// (특히 `9;4` progress가 진행바마다 알림 폭탄) 곤란하므로, `<숫자>;...` 형태는 ConEmu 서브커맨드로 보고
/// 소비만 한다(알림 안 함). **베이스/결정**: iTerm2 OSC 9(body=전체) 기준. ConEmu 분기는 Ghostty osc9가
/// 유효 서브커맨드만 소비하고 미완성은 알림으로 폴백하는데(예: `9;4`→알림 "4"), maru는 `<숫자>;` 패턴 전체를
/// 보수적으로 소비해 progress 등 완성 서브커맨드의 오발사를 확실히 막는다(순수 텍스트·단일 숫자 알림만 발사).
pub fn dispatchNotify9(self: *TerminalCore, body: []const u8) void {
    if (body.len == 0) return;
    if (looksLikeConemu9(body)) return; // `<숫자>;...` → ConEmu 서브커맨드(소비, 알림 안 함)
    setNotification(self, "", body); // iTerm2: title 없음, body=메시지 전체
}

/// OSC 9 body가 ConEmu 서브커맨드(`<숫자>;...`)처럼 보이는가. 선두 숫자 뒤에 `;`가 오면 true.
fn looksLikeConemu9(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {}
    return i > 0 and i < s.len and s[i] == ';';
}

/// 알림 title/body를 pending에 둔다(소유 버퍼에 복사). 할당 실패면 조용히 폐기(알림은 best-effort).
fn setNotification(self: *TerminalCore, title: []const u8, notify_body: []const u8) void {
    self.notification_title.clearRetainingCapacity();
    self.notification_body.clearRetainingCapacity();
    self.notification_title.appendSlice(self.allocator, title) catch return;
    self.notification_body.appendSlice(self.allocator, notify_body) catch {
        self.notification_title.clearRetainingCapacity();
        return;
    };
    self.notification_pending = true;
}
