//! VT 파서 — write 상태기계 진입점(feed) + escape/CSI/OSC/DCS/APC dispatch + UTF-8 디코드.
//!
//! `TerminalCore`(core.zig)가 VT 파서 상태기계 + 화면/스크롤백 storage + host-reply를 한 struct에 섞은
//! 구조 위반(docs/project-rules.md "구조와 파일 분리": parser·storage·encoding이 한 파일에서 서로 다른
//! 이유로 바뀌면 facade는 유지하되 구현을 목적별로 분리)을 목적별 파일로 떼어낸 결과다. 여기는 "바이트를
//! 해독하고 시퀀스를 dispatch하는" 파서 책임을 모은다(화면 연산은 screen.zig, OSC host-reply는 osc.zig).
//! struct·facade(terminal.zig)는 불변이고, 각 함수는 `*TerminalCore`를 받는 free 함수다(필드 직접 접근 — Zig는
//! 필드 privacy가 없다). core.zig의 `write` facade가 owner_dbg 확인 후 `feed`로 위임하고, feed가 상태기계로
//! escape→handleEscapeByte, CSI→handleCsiByte/dispatchCsi, OSC/DCS/APC→dispatchOsc/Dcs/Apc, ground→
//! screen.writeCodepoint로 분기한다. CSI param 접근자(csiRawParam/csiParam)는 core 잔류 — param 저장소
//! (csi_params 필드)와 한 묶음이고 screen.cursorPosition/setScrollRegion도 호출해 self.로 부른다.
//!
//! 현재 보유(core.zig 분할 5~21/N 완료, docs/terminal-core-decomposition.md): DCS(DECRQSS·XTGETTCAP)·OSC
//! 라우터·APC(kitty graphics) 파싱(Phase A) + SGR/모드 dispatch·CSI 상태기계·escape/write 루프(Phase D).
//!
//! 베이스: vt100.net DEC ANSI state machine(ground/escape/CSI/OSC/DCS/APC) + xterm ctlseqs(DECRQSS는 VT420,
//! XTGETTCAP는 xterm). 단일 표준 없는 동작의 결정은 해당 함수 주석·docs/terminal-compatibility-policy.md를 단일 출처로 둔다.

const std = @import("std");
const core = @import("core.zig");
const types = @import("types.zig");
const osc = @import("osc.zig"); // OSC host-reply 핸들러 — 라우터(dispatchOsc)가 코드별로 위임
const screen = @import("screen.zig"); // CSI dispatch가 화면 연산(setOriginMode·enterAltScreen·putCell 등) 호출
const kitty = @import("kitty.zig"); // APC kitty graphics — parseKittyGraphicsCommand의 결과 DTO(KittyGraphicsCommand) 소유

const TerminalCore = core.TerminalCore;

/// OSC 52(클립보드) 본문 수집 상한. 디코드 상한(osc.max_clipboard_bytes)이 base64(3바이트→4자) 인코딩으로도
/// 통과할 수 있어야 한다: 4/3× + 헤더("52;c;" 등) 여유. 이 상한을 넘는 OSC는 통째로 무시한다(osc_overflow).
pub const max_osc_bytes: usize = osc.max_clipboard_bytes / 3 * 4 + 64;
/// 비-클립보드 OSC의 수집 상한 — 옛 고정 버퍼(2048)의 방어선을 유지한다. title/cwd/알림/OSC 8 URI 등은
/// 핸들러가 본문을 dupe해 보관하므로, 대용량을 허용하면 악의적 스트림이 핸들러 저장소(제목·링크 스토어 등)에
/// 수 MB를 꽂을 수 있다. 대용량이 정당한 건 OSC 52(한 문단 복사가 base64로 2KB를 쉽게 넘는다)뿐이다.
pub const max_osc_small_bytes: usize = 2048;
/// dispatch 후 유지할 osc_buffer 용량 상한 — 대용량 OSC(클립보드) 뒤 capacity를 반납해 일상 OSC
/// (title/cwd/133 등 소형)가 수십 MB를 계속 붙들지 않게 한다.
const osc_retain_bytes: usize = 4096;

/// 종료된 OSC 내용을 코드별로 분기한다. 각 핸들러는 osc.zig(host-reply)에 있고 여기는 라우터다 —
/// OSC 8(하이퍼링크)·133(semantic)·7(cwd)·0/2(title)·10/11/110/111(색)·52(클립보드)·4/104(팔레트)·
/// 777/9(알림)·5379(maru)로 가른다. core.zig의 write 상태기계 루프(`.osc`/`.osc_escape`)가 위임한다.
pub fn dispatchOsc(self: *TerminalCore) void {
    // 대용량 OSC 뒤 용량 반납 — 핸들러들은 body에서 필요한 것을 모두 복사(dupe/intern/decode)하므로
    // dispatch가 끝나면 버퍼를 비워도 안전하다(참조 유지 없음). 정상 종료(BEL/ST)의 즉시 반납 경로다.
    defer reclaimOscBuffer(self);
    if (self.osc_overflow) {
        // 수집 상한(oscMayGrow)을 넘긴 OSC는 통째로 무시(거대/악의적 시퀀스 방어). 그게 클립보드(52;)였으면
        // (osc_large_ok latch) 무음 폐기 대신 거부를 표면화해 사용자가 "왜 복사가 안 됐는지" 알게 한다.
        if (self.osc_large_ok) self.clipboard_write_rejected = true;
        return;
    }
    const body = self.osc_buffer.items;
    if (std.mem.startsWith(u8, body, "8;")) {
        osc.dispatchHyperlink(self, body[2..]);
    } else if (std.mem.startsWith(u8, body, "133;")) {
        osc.dispatchSemanticPrompt(self, body[4..]);
    } else if (std.mem.startsWith(u8, body, "7;")) {
        osc.dispatchCwd(self, body[2..]);
    } else if (std.mem.startsWith(u8, body, "0;")) {
        self.setWindowTitle(body[2..]); // OSC 0 = 아이콘 이름 + 창 제목(둘 다) — 창 제목으로 받는다
    } else if (std.mem.startsWith(u8, body, "2;")) {
        self.setWindowTitle(body[2..]); // OSC 2 = 창 제목만
    } else if (std.mem.startsWith(u8, body, "10;")) {
        osc.dispatchDefaultColor(self, body[3..], 10); // OSC 10 = 전경색 설정/질의
    } else if (std.mem.startsWith(u8, body, "11;")) {
        osc.dispatchDefaultColor(self, body[3..], 11); // OSC 11 = 배경색 설정/질의
    } else if (std.mem.eql(u8, body, "110")) {
        self.default_fg_override = null; // OSC 110 = 전경색 리셋(theme 기본 복귀)
    } else if (std.mem.eql(u8, body, "111")) {
        self.default_bg_override = null; // OSC 111 = 배경색 리셋
    } else if (std.mem.startsWith(u8, body, "52;")) {
        osc.dispatchClipboard(self, body[3..]); // OSC 52 = 클립보드(파싱+디코드만; 실제 쓰기·정책은 platform)
    } else if (std.mem.startsWith(u8, body, "4;")) {
        osc.dispatchPalette(self, body[2..]); // OSC 4 = 256색 팔레트 설정/질의(`<index>;<spec>` 쌍 반복)
    } else if (std.mem.eql(u8, body, "104") or std.mem.startsWith(u8, body, "104;")) {
        // OSC 104 = 팔레트 리셋. 인덱스 없으면(정확히 "104") 전부, "104;1;2"면 그 인덱스만.
        osc.dispatchPaletteReset(self, if (body.len > 4) body[4..] else "");
    } else if (std.mem.startsWith(u8, body, "777;")) {
        osc.dispatchNotify777(self, body[4..]); // OSC 777 = rxvt 데스크톱 알림(notify;title;body)
    } else if (std.mem.startsWith(u8, body, "9;")) {
        osc.dispatchNotify9(self, body[2..]); // OSC 9 = iTerm2 알림(ConEmu 서브커맨드와 충돌 — 가드)
    } else if (std.mem.startsWith(u8, body, "5379;")) {
        osc.dispatchMaru(self, body["5379;".len..]); // OSC 5379 = maru 전용 통지(사설 번호; 현재 ssh;<dest>)
    }
    // OSC 1(아이콘 이름만)은 창 제목과 무관 — 위 분기에 없으니 소비만 하고 저장 안 한다.
}

/// osc_buffer의 capacity를 반납-or-리셋한다 — 직전 수집이 대용량(클립보드)이었으면 free하고, 아니면 length만
/// 비운다. **.osc를 벗어나는 모든 경로**가 이걸 불러 옛 고정 2048 상한을 재확립한다: 정상 종료(BEL/ST → dispatch
/// defer)와 abort(ESC+비-`\`)가 1차 반납 지점이고, OSC 재시작(`]`)·RIS(fullReset)는 방어적 백스톱이다(이 둘이
/// 실행될 땐 보통 이미 반납돼 있지만, 미래에 종료 경로가 늘어도 megabyte가 새지 않게 한 곳에서 정책을 준다).
/// 핸들러가 body를 모두 복사하므로 비워도 안전하다(참조 유지 없음).
pub fn reclaimOscBuffer(self: *TerminalCore) void {
    if (self.osc_buffer.capacity > osc_retain_bytes)
        self.osc_buffer.clearAndFree(self.allocator)
    else
        self.osc_buffer.clearRetainingCapacity();
}

/// OSC 본문이 한 바이트 더 자랄 수 있는가 — 수집 게이트. 기본 상한은 max_osc_small_bytes(옛 2048 방어선)이고,
/// **OSC 52("52;" 접두)만** max_osc_bytes까지 허용한다(클립보드 base64는 한 문단만 돼도 2KB를 넘는다).
/// overflow(상한 초과·OOM)면 즉시 false — 남은 수백만 바이트마다 append를 재시도(alloc storm)하지 않고 값싸게
/// 버린다. 접두("52;") 판정은 소형 상한 진입 시 **1회만** 하고 osc_large_ok에 latch한다(hot path에서 매
/// 바이트 startsWith 재실행 제거). self를 mutate하므로 non-const.
fn oscMayGrow(self: *TerminalCore) bool {
    if (self.osc_overflow) return false; // 이미 폐기 확정 — 재시도 없이 값싸게 소비
    const len = self.osc_buffer.items.len;
    if (len < max_osc_small_bytes) return true;
    if (self.osc_large_ok) return len < max_osc_bytes; // latch된 클립보드 판정(startsWith 재실행 없음)
    // 소형 상한 첫 도달: 클립보드면 대용량 허용을 latch, 아니면 overflow로 확정(이후 위 가드로 값싸게 폐기).
    if (std.mem.startsWith(u8, self.osc_buffer.items, "52;")) {
        self.osc_large_ok = true;
        return len < max_osc_bytes;
    }
    self.osc_overflow = true;
    return false;
}

/// 종료된 DCS(ESC P ... ST) 내용을 처리한다. 현재 DECRQSS(`DCS $ q <req> ST`)만 — 그 외 DCS(Sixel 등)는
/// 미지원이라 소비만 한다(이 상태기계가 그 토대). overflow면 폐기.
pub fn dispatchDcs(self: *TerminalCore) void {
    if (self.dcs_overflow) return;
    const body = self.dcs_buffer[0..self.dcs_len];
    if (std.mem.startsWith(u8, body, "$q")) {
        dispatchDecrqss(self, body[2..]);
    } else if (std.mem.startsWith(u8, body, "+q")) {
        dispatchXtgettcap(self, body[2..]);
    }
}

/// XTGETTCAP(`DCS + q <hex names> ST`): terminfo/termcap 캡을 런타임 질의한다(xterm ctlseqs). terminfo
/// 파일이 원격에 없어도 도구(tmux 등)가 캡을 직접 물어 자기식별·기능 협상을 한다 — XTVERSION(CSI > q)과
/// 함께 "파일 없는 자기식별"의 두 번째 채널이다. 요청은 `;`로 구분된 hex 캡 이름들이고, 캡마다 따로
/// 응답한다(per-cap): 알면 `DCS 1 + r <hex이름>=<hex값> ST`, 모르면 `DCS 0 + r <hex이름> ST`.
/// maru가 정직하게 지원하는 캡만 안다고 답한다. 요청 hex 이름은 그대로 echo하고 값만 hex 인코딩한다.
fn dispatchXtgettcap(self: *TerminalCore, names_hex: []const u8) void {
    var it = std.mem.splitScalar(u8, names_hex, ';');
    while (it.next()) |hex_name| {
        if (hex_name.len == 0) continue;
        respondXtgettcap(self, hex_name);
    }
}

/// 캡 하나에 응답한다. hex 이름을 디코드해 식별하고, 아는 캡이면 값을 hex로 실어 `1+r`로, 모르면
/// `0+r`로 답한다. maru가 아는 캡: TN(terminfo 이름)·Co(색 수 256)·RGB(truecolor, 8bit/채널). 이게
/// maru가 실제 지원하는 정직한 집합이다 — 모르는 캡에 거짓 응답하면 도구가 없는 기능을 켜 깨진다.
fn respondXtgettcap(self: *TerminalCore, hex_name: []const u8) void {
    var name_buf: [16]u8 = undefined; // 캡 이름은 짧다(TN/Co/RGB 등). 길면 모르는 캡으로 처리.
    const name = decodeHex(hex_name, &name_buf) orelse return appendXtgettcapInvalid(self, hex_name);
    const value: ?[]const u8 =
        if (std.mem.eql(u8, name, "TN")) core.terminfo_name else if (std.mem.eql(u8, name, "Co")) "256" else if (std.mem.eql(u8, name, "RGB")) "8" else null;
    if (value) |v| {
        self.appendResponse("\x1bP1+r");
        self.appendResponse(hex_name); // 요청 이름을 그대로 echo(이미 hex)
        self.appendResponse("=");
        appendHexEncoded(self, v);
        self.appendResponse("\x1b\\");
    } else {
        appendXtgettcapInvalid(self, hex_name);
    }
}

fn appendXtgettcapInvalid(self: *TerminalCore, hex_name: []const u8) void {
    self.appendResponse("\x1bP0+r");
    self.appendResponse(hex_name);
    self.appendResponse("\x1b\\");
}

/// 바이트열을 대문자 hex(2자리/바이트)로 인코딩해 응답에 붙인다(xterm/Ghostty 관례).
fn appendHexEncoded(self: *TerminalCore, bytes: []const u8) void {
    const digits = "0123456789ABCDEF";
    for (bytes) |b| {
        const pair = [2]u8{ digits[b >> 4], digits[b & 0xf] };
        self.appendResponse(&pair);
    }
}

/// hex 문자열(2자리/바이트, 대소문자 무관)을 디코드해 out에 채우고 그 슬라이스를 돌려준다. 길이가
/// 홀수거나 비-hex거나 out보다 길면 null(호출 측은 모르는 캡으로 처리). XTGETTCAP 이름 디코드에 쓴다.
fn decodeHex(hex: []const u8, out: []u8) ?[]const u8 {
    if (hex.len % 2 != 0) return null;
    const n = hex.len / 2;
    if (n > out.len) return null;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const hi = hexNibble(hex[i * 2]) orelse return null;
        const lo = hexNibble(hex[i * 2 + 1]) orelse return null;
        out[i] = (@as(u8, hi) << 4) | lo;
    }
    return out[0..n];
}

fn hexNibble(c: u8) ?u4 {
    return switch (c) {
        '0'...'9' => @intCast(c - '0'),
        'a'...'f' => @intCast(c - 'a' + 10),
        'A'...'F' => @intCast(c - 'A' + 10),
        else => null,
    };
}

/// DECRQSS(`DCS $ q <req> ST`): 현재 설정을 회신한다. 유효하면 `DCS 1 $ r <설정> ST`, 미지원이면
/// `DCS 0 $ r ST`. req는 질의 설정의 final(`m`=SGR·`r`=DECSTBM·` q`=DECSCUSR). 베이스: xterm/VT420 DECRQSS.
fn dispatchDecrqss(self: *TerminalCore, req: []const u8) void {
    if (std.mem.eql(u8, req, "m")) {
        appendDecrqssSgr(self);
    } else if (std.mem.eql(u8, req, "r")) {
        // DECSTBM(scroll region) — top;bottom(1-based).
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "\x1bP1$r{d};{d}r\x1b\\", .{ self.scroll_top + 1, self.scroll_bottom + 1 }) catch return;
        self.appendResponse(s);
    } else if (std.mem.eql(u8, req, " q")) {
        // DECSCUSR(커서 스타일) — shape+blink를 DECSCUSR param 1..6으로 역매핑.
        const param: u8 = switch (self.cursor_shape) {
            .block => if (self.cursor_blink) 1 else 2,
            .underline => if (self.cursor_blink) 3 else 4,
            .bar => if (self.cursor_blink) 5 else 6,
        };
        var buf: [16]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "\x1bP1$r{d} q\x1b\\", .{param}) catch return;
        self.appendResponse(s);
    } else {
        self.appendResponse("\x1bP0$r\x1b\\"); // 미지원 설정 질의 → invalid
    }
}

/// DECRQSS SGR 응답: 현재 pen을 SGR 파라미터로 재구성해 `DCS 1 $ r 0;… m ST`로 회신(default 색은 0 reset에
/// 포함되므로 생략). appendResponse로 조각조각 누적한다.
fn appendDecrqssSgr(self: *TerminalCore) void {
    self.appendResponse("\x1bP1$r0");
    const s = self.screen.pen;
    if (s.bold) self.appendResponse(";1");
    if (s.dim) self.appendResponse(";2");
    if (s.italic) self.appendResponse(";3");
    if (s.underline) self.appendResponse(";4");
    if (s.blink) self.appendResponse(";5");
    if (s.reverse) self.appendResponse(";7");
    if (s.conceal) self.appendResponse(";8");
    if (s.strikethrough) self.appendResponse(";9");
    if (s.overline) self.appendResponse(";53");
    appendSgrColor(self, s.foreground, true);
    appendSgrColor(self, s.background, false);
    appendSgrUnderlineColor(self, s.underline_color);
    self.appendResponse("m\x1b\\");
}

fn appendSgrColor(self: *TerminalCore, c: types.Color, foreground: bool) void {
    var buf: [24]u8 = undefined;
    switch (c) {
        .default => {}, // default(39/49)는 0 reset에 포함 — 생략
        .indexed => |n| {
            const s = if (n < 8)
                std.fmt.bufPrint(&buf, ";{d}", .{@as(u16, if (foreground) 30 else 40) + @as(u16, n)})
            else if (n < 16)
                std.fmt.bufPrint(&buf, ";{d}", .{@as(u16, if (foreground) 90 else 100) + @as(u16, n - 8)})
            else
                std.fmt.bufPrint(&buf, ";{d};5;{d}", .{ @as(u16, if (foreground) 38 else 48), n });
            self.appendResponse(s catch return);
        },
        .rgb => |v| {
            const s = std.fmt.bufPrint(&buf, ";{d};2;{d};{d};{d}", .{ @as(u16, if (foreground) 38 else 48), v.r, v.g, v.b }) catch return;
            self.appendResponse(s);
        },
    }
}

fn appendSgrUnderlineColor(self: *TerminalCore, c: types.Color) void {
    var buf: [24]u8 = undefined;
    switch (c) {
        .default => {},
        .indexed => |n| self.appendResponse(std.fmt.bufPrint(&buf, ";58;5;{d}", .{n}) catch return),
        .rgb => |v| self.appendResponse(std.fmt.bufPrint(&buf, ";58;2;{d};{d};{d}", .{ v.r, v.g, v.b }) catch return),
    }
}

/// 종료된 APC(ESC _ ... ESC \) 내용을 처리한다. kitty graphics(`ESC _ G ...`)가 유일한 소비자다.
/// 토대 단계라 현재는 수집만 — command 파싱·이미지 저장·렌더는 후속(audit 5/5 단계적). APC를 안
/// 받으면 payload가 화면에 텍스트로 새므로(과거 ESC_ 미처리), 수집해서 무시하는 것만으로도 그 누수를
/// 막는다. 베이스: kitty graphics protocol(APC payload), OSC dispatch와 동형. control 파싱은 여기서,
/// 실제 이미지 exec/display/transmit/delete는 core(execKittyGraphics, pub)가 한다(범위 분리 — 후속 kitty.zig).
pub fn dispatchApc(self: *TerminalCore) void {
    if (self.apc_overflow or self.apc_buffer.items.len == 0) {
        // 한 청크가 4096을 넘쳤다(overflow) — chunked 진행 중이면 그 전송 전체가 손상이라 폐기한다.
        if (self.apc_overflow) abortKittyChunk(self);
        return;
    }
    // kitty graphics(ESC _ G ...)만 처리한다. control(k=v)을 파싱하고, transmit이면 payload(base64)를
    // 디코드해 이미지를 저장한다. payload는 control 다음(';' 이후)이다.
    if (self.apc_buffer.items[0] != 'G') return;
    const body = self.apc_buffer.items[1..];
    const cmd = parseKittyGraphicsCommand(body);
    const payload = if (std.mem.indexOfScalar(u8, body, ';')) |i| body[i + 1 ..] else body[0..0];

    // chunked(m=1): 첫 청크가 control을 갖고, 이후 청크는 payload만 이어 붙인다. m=0에서 누적분을
    // 한 번에 실행한다. 진행 중이 아니고(첫 등장) m=0이면 단일 전송이라 즉시 실행(기존 경로).
    if (self.kitty_chunk_cmd == null and !cmd.more) {
        kitty.execKittyGraphics(self, cmd, payload);
        return;
    }
    // chunked 진행 중 도착한 명령이 transmit continuation(a=t/T)이 아니라 독립 명령(delete 등)이면,
    // kitty 명세상 정의되지 않은 interleave다 — 진행 중 chunk를 버리고 새 명령을 즉시 실행한다(code
    // review #3, 사용자 결정). continuation은 a= 생략(기본 t) 또는 t/T라 누적 경로로 떨어진다.
    if (self.kitty_chunk_cmd != null and cmd.action != 't' and cmd.action != 'T') {
        abortKittyChunk(self);
        kitty.execKittyGraphics(self, cmd, payload);
        return;
    }
    if (self.kitty_chunk_cmd == null) self.kitty_chunk_cmd = cmd; // 첫 청크의 control 보존
    if (self.kitty_chunk.items.len + payload.len > core.TerminalCore.max_kitty_chunk_bytes) {
        abortKittyChunk(self); // 폭주 방어선 초과 — 전송 폐기
        return;
    }
    self.kitty_chunk.appendSlice(self.allocator, payload) catch {
        abortKittyChunk(self); // OOM도 폐기(graceful)
        return;
    };
    if (!cmd.more) { // 마지막 청크 — 첫 청크 control + 누적 payload로 실행
        const first = self.kitty_chunk_cmd.?;
        kitty.execKittyGraphics(self, first, self.kitty_chunk.items);
        abortKittyChunk(self);
    }
}

/// 진행 중인 chunked 전송을 폐기한다(누적 버퍼 비우고 control 해제). 완료·overflow·OOM·RIS 공용.
/// core.fullReset(RIS)이 cross-file로 부른다(pub).
pub fn abortKittyChunk(self: *TerminalCore) void {
    self.kitty_chunk.clearRetainingCapacity();
    self.kitty_chunk_cmd = null;
}

/// kitty graphics APC의 control 섹션(`G` 다음 ~ ';' 전)을 파싱한다. `k=v,k=v` 형식 — 주요 key만
/// 추출하고 나머지는 후속 확장으로 무시한다. value는 단일 비숫자 문자면 그 문자(a/o), 아니면 정수
/// (f/s/v/i/m) — 어느 key가 문자/정수인지는 kitty 명세 control data가 정한다. payload(base64)는
/// 토대에선 보지 않는다(디코드·저장은 후속). 베이스: kitty graphics protocol control data. 결과 struct
/// (KittyGraphicsCommand)는 kitty.zig가 소유(exec·storage가 공유 — parse→exec DTO라 pub).
pub fn parseKittyGraphicsCommand(body: []const u8) kitty.KittyGraphicsCommand {
    var cmd: kitty.KittyGraphicsCommand = .{};
    const control = if (std.mem.indexOfScalar(u8, body, ';')) |i| body[0..i] else body;
    var it = std.mem.splitScalar(u8, control, ',');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const key = pair[0..eq];
        const val = pair[eq + 1 ..];
        if (key.len != 1 or val.len == 0) continue; // kitty control key는 모두 1글자
        switch (key[0]) {
            'a' => if (val.len == 1) {
                cmd.action = val[0];
            },
            'f' => cmd.format = std.fmt.parseInt(u16, val, 10) catch cmd.format,
            's' => cmd.width = std.fmt.parseInt(u32, val, 10) catch 0,
            'v' => cmd.height = std.fmt.parseInt(u32, val, 10) catch 0,
            'i' => cmd.image_id = std.fmt.parseInt(u32, val, 10) catch 0,
            'm' => cmd.more = (val.len == 1 and val[0] == '1'),
            'o' => if (val.len == 1) {
                cmd.compression = val[0];
            },
            // display(placement) 키. 대/소문자가 다른 키(x/X, y/Y)는 별개 의미라 그대로 구분한다.
            'p' => cmd.placement_id = std.fmt.parseInt(u32, val, 10) catch 0,
            'x' => cmd.src_x = std.fmt.parseInt(u32, val, 10) catch 0,
            'y' => cmd.src_y = std.fmt.parseInt(u32, val, 10) catch 0,
            'w' => cmd.src_width = std.fmt.parseInt(u32, val, 10) catch 0,
            'h' => cmd.src_height = std.fmt.parseInt(u32, val, 10) catch 0,
            'X' => cmd.cell_x_offset = std.fmt.parseInt(u32, val, 10) catch 0,
            'Y' => cmd.cell_y_offset = std.fmt.parseInt(u32, val, 10) catch 0,
            'c' => cmd.columns = std.fmt.parseInt(u32, val, 10) catch 0,
            'r' => cmd.rows = std.fmt.parseInt(u32, val, 10) catch 0,
            'z' => cmd.z = std.fmt.parseInt(i32, val, 10) catch 0, // 부호 있음(텍스트 앞/뒤)
            'C' => cmd.no_cursor_move = (val.len == 1 and val[0] == '1'),
            'd' => if (val.len == 1) {
                cmd.delete_what = val[0]; // 삭제 타깃 문자(a/A/i/I/z/Z/…)
            },
            else => {}, // 나머지 control key는 토대에선 무시(후속 확장)
        }
    }
    return cmd;
}

// ── CSI dispatch sub-handler: 모드(DECSET/SM)·SGR·host-reply report ──────────────────────────────
// dispatchCsi(같은 파일)가 final byte별로 위임하는 핸들러. 모드 setter는 화면 연산
// (screen.setOriginMode/enterAltScreen/putCell 등)을 호출하고, report는 self.appendResponse(core 잔류)로
// PTY 응답을 쌓는다. CSI param 접근(csiRawParam/csiParam)은 core 잔류 — param 저장소(csi_params 필드)와 한 묶음.

/// DECSET(h)/DECRST(l)의 사적 모드를 적용한다(파라미터가 여러 개면 각각). 커서가 화면에 귀속되므로(per-screen,
/// §10.8) 47/1047/1049는 모두 alt 진입/이탈 한 동작으로 수렴한다 — 커서·pen·deferred-wrap이 grid·스크롤백과
/// 함께 swap돼 진입은 home, 이탈은 primary 복원이 자동이다(옛 save_cursor 플래그 분기 소멸). 1048(별도 SCO
/// 저장/복원)만 화면 전환 없이 커서 슬롯을 다룬다 — vim/less가 47/1047/1049를, CSI s/u·1048이 커서만 쓴다.
pub fn setPrivateModes(self: *TerminalCore, set: bool) void {
    var i: usize = 0;
    while (i < self.csi_param_count) : (i += 1) {
        switch (self.csiRawParam(i)) {
            1 => self.application_cursor_keys = set, // DECCKM: 화살표 SS3/CSI 인코딩 전환
            5 => if (self.reverse_screen != set) { // DECSCNM(G9): 화면 전역 반전 — 바뀌면 전체 재칠
                self.reverse_screen = set;
                self.dirty = core.fullDirty(self.size);
            },
            6 => screen.setOriginMode(self, set), // DECOM: CUP/HVP origin을 scroll region 상단으로 + 커서 home
            25 => { // DECTCEM: 커서 표시/숨김. 커서 행만 다시 그리면 된다.
                self.cursor_visible = set;
                screen.markDirty(self, self.screen.cursor.row);
            },
            1007 => self.alternate_scroll = set, // alt screen 휠 -> 화살표 변환 on/off
            2004 => self.bracketed_paste = set, // bracketed paste(붙여넣기 감싸기)
            1004 => self.focus_events = set, // focus reporting(창 포커스 in/out → CSI I/O)
            9 => self.mouse_tracking = if (set) .x10 else .none, // X10 mouse(press만)
            1000 => self.mouse_tracking = if (set) .normal else .none, // normal(press+release)
            1002 => self.mouse_tracking = if (set) .button else .none, // button(+버튼 눌린 채 drag)
            1003 => self.mouse_tracking = if (set) .any else .none, // any(+모든 motion)
            1006 => self.mouse_format = if (set) .sgr else .x10, // SGR 인코딩(좌표 무제한)
            1016 => self.mouse_format = if (set) .sgr_pixels else .x10, // SGR-pixels 인코딩
            1015 => self.mouse_format = if (set) .urxvt else .x10, // urxvt 인코딩(G13 — 거의 1006으로 대체)
            7 => self.autowrap = set, // DECAWM(G8): autowrap on/off — off면 마지막 칸에서 덮어쓴다
            2027 => self.grapheme_cluster_mode = set, // grapheme cluster 너비(이모지 풀사이즈 합의)
            2026 => {
                self.sync_output = set; // synchronized output(set=BSU hold 시작, reset=ESU flush)
                // ESU(reset=프레임 완성)마다 카운트 — shouldProjectFrame의 esu_advanced가 tick 폴링이 놓친 완성 프레임을 flush.
                // BSU(set=hold 시작)도 카운트 — .sync 로거가 BSU/ESU 짝을 노출해 메인 per-tick 샘플링 누락(ssh sync 어긋남)을 추적.
                if (set) self.sync_bsu_count +%= 1 else self.sync_esu_count +%= 1;
            },
            47, 1047, 1049 => if (set) screen.enterAltScreen(self) else screen.leaveAltScreen(self), // 커서가 화면 귀속이라 셋 다 동일(§10.8)
            1048 => if (set) screen.saveCursorState(self) else screen.restoreCursorState(self),
            else => {}, // 그 외 private 모드(25 커서 표시 등)는 아직 소비만 한다.
        }
    }
}

/// SM/RM(CSI Ps h/l, private marker 없음): 비-private ANSI 모드. 현재 IRM(4)=insert mode만 지원(그 외 소비).
pub fn setAnsiModes(self: *TerminalCore, set: bool) void {
    var i: usize = 0;
    while (i < self.csi_param_count) : (i += 1) {
        switch (self.csiRawParam(i)) {
            4 => self.insert_mode = set, // IRM(G6): insert/replace
            else => {},
        }
    }
}

/// REP(CSI Ps b): 직전에 출력한 graphic 글자(last_printed_cp)를 N회(기본 1) 더 반복한다. 아직 출력이
/// 없으면(0) 무동작. 각 반복은 putCell 경로(wrap·IRM·DECAWM·wide 적용)를 그대로 탄다.
pub fn repeatLastChar(self: *TerminalCore, count: u16) void {
    if (self.screen.last_printed_cp == 0) return;
    const cp = self.screen.last_printed_cp;
    var n = @max(count, 1);
    // putCell을 직접 호출한다(writeCodepoint가 아니라) — last_printed_cp는 이미 charset 변환을 거친 최종
    // 글리프라, writeCodepoint로 다시 보내면 translateCharset이 두 번 적용된다(현 charset이 dec_special이면
    // 오변환). putCell이 wrap·IRM·DECAWM·wide를 그대로 처리하고 charset만 건너뛴다.
    while (n > 0) : (n -= 1) screen.putCell(self, cp);
}

pub fn deviceStatusReport(self: *TerminalCore) void {
    switch (self.csiRawParam(0)) {
        5 => self.appendResponse("\x1b[0n"),
        6 => {
            var buf: [40]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "\x1b[{d};{d}R", .{
                self.screen.cursor.row + 1,
                self.screen.cursor.col + 1,
            }) catch return;
            self.appendResponse(s);
        },
        else => {},
    }
}

/// DECRQM(CSI ? Ps $ p) 응답 — DECRPM(CSI ? Ps ; Pm $ y). Pm: 0=미인식, 1=set, 2=reset,
/// 3=영구 set, 4=영구 reset. 우리가 추적하는 모드는 현재 상태(1/2)를 알려 앱이 지원을 감지하고
/// 켤 수 있게 한다(특히 mode 2027). 모르는 모드는 0(미인식)으로 답해 앱이 폴백하게 둔다.
pub fn reportPrivateMode(self: *TerminalCore, mode: u16) void {
    const state: u8 = switch (mode) {
        2027 => if (self.grapheme_cluster_mode) 1 else 2,
        2026 => if (self.sync_output) 1 else 2,
        2004 => if (self.bracketed_paste) 1 else 2,
        25 => if (self.cursor_visible) 1 else 2,
        1 => if (self.application_cursor_keys) 1 else 2,
        6 => if (self.origin_mode) 1 else 2, // DECOM(origin mode)
        else => 0, // 미인식 — 앱이 보수적으로 폴백
    };
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "\x1b[?{d};{d}$y", .{ mode, state }) catch return;
    self.appendResponse(s);
}

/// CSI 파라미터(u16)를 kitty flags로 — Maru가 실제 인코딩하는 disambiguate(bit 0)만 통과시킨다.
/// report_events/report_alternates/report_all/report_associated는 미구현이므로 스택에 저장하지
/// 않는다: 저장하면 query(CSI ? u)가 미구현 능력을 활성으로 거짓 보고하고(앱이 켜진 줄 알고 key
/// release·대체키·연관텍스트를 기대), 인코딩은 disambiguate 수준만 나가 광고와 동작이 어긋난다.
/// 지원 flag가 늘면 이 마스크를 넓힌다.
pub fn kittyFlagsFromParam(v: u16) core.KittyFlags {
    return .{ .disambiguate = (v & 1) != 0 };
}

/// kitty keyboard query(CSI ? u) 응답: 현재 스택 최상단 flags를 CSI ? flags u로 보고한다.
pub fn reportKittyFlags(self: *TerminalCore) void {
    var buf: [16]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "\x1b[?{d}u", .{self.kitty_flags.current().int()}) catch return;
    self.appendResponse(s);
}

pub fn applySgr(self: *TerminalCore) void {
    const count = @min(self.csi_param_count, core.TerminalCore.max_csi_params);
    var i: usize = 0;
    while (i < count) {
        const p = self.csi_params[i];
        switch (p) {
            0 => self.screen.pen = .{},
            7 => self.screen.pen.reverse = true,
            27 => self.screen.pen.reverse = false,
            1 => self.screen.pen.bold = true,
            2 => self.screen.pen.dim = true, // SGR 2: faint/decreased intensity (ECMA-48)
            3 => self.screen.pen.italic = true,
            4 => {
                // underline. colon 형식 4:x(ITU T.416 — x는 underline 스타일)는 x=0이면 off, x=2면 double,
                // 그 외 x>0은 single on(curly/dotted 등 스타일 종류는 single로 근사). 세미콜론 plain 4는 single on.
                // sub-param은 아래 루프 끝에서 소비한다.
                const styled = i + 1 < count and self.csi_subparam[i + 1];
                if (styled) {
                    const sub = self.csi_params[i + 1];
                    self.screen.pen.underline = sub != 0;
                    self.screen.pen.underline_double = sub == 2; // 4:2 = double underline
                } else {
                    self.screen.pen.underline = true;
                    self.screen.pen.underline_double = false;
                }
            },
            22 => { // SGR 22: normal intensity — bold·faint 둘 다 off (ECMA-48)
                self.screen.pen.bold = false;
                self.screen.pen.dim = false;
            },
            23 => self.screen.pen.italic = false,
            24 => { // SGR 24: underline off — single·double 둘 다 끈다
                self.screen.pen.underline = false;
                self.screen.pen.underline_double = false;
            },
            21 => { // SGR 21: doubly underlined — 하단 2중선
                self.screen.pen.underline = true;
                self.screen.pen.underline_double = true;
            },
            9 => self.screen.pen.strikethrough = true, // SGR 9: crossed-out (ECMA-48)
            29 => self.screen.pen.strikethrough = false, // SGR 29: not crossed-out
            53 => self.screen.pen.overline = true, // SGR 53: overlined (ECMA-48)
            55 => self.screen.pen.overline = false, // SGR 55: not overlined
            5, 6 => self.screen.pen.blink = true, // SGR 5(slow)/6(rapid) blink — 파싱·저장만(렌더 정적)
            25 => self.screen.pen.blink = false, // SGR 25: blink off
            8 => self.screen.pen.conceal = true, // SGR 8: concealed(invisible)
            28 => self.screen.pen.conceal = false, // SGR 28: reveal
            59 => self.screen.pen.underline_color = .default, // SGR 59: underline color를 default(전경색)로
            30...37 => self.screen.pen.foreground = .{ .indexed = @intCast(p - 30) },
            39 => self.screen.pen.foreground = .default,
            40...47 => self.screen.pen.background = .{ .indexed = @intCast(p - 40) },
            49 => self.screen.pen.background = .default,
            90...97 => self.screen.pen.foreground = .{ .indexed = @intCast(p - 90 + 8) },
            100...107 => self.screen.pen.background = .{ .indexed = @intCast(p - 100 + 8) },
            38 => {
                i = applyExtendedColor(self, i, &self.screen.pen.foreground);
                continue;
            },
            48 => {
                i = applyExtendedColor(self, i, &self.screen.pen.background);
                continue;
            },
            58 => { // SGR 58: underline color(58;2;r;g;b·58;5;n) — 전경과 별개 밑줄 색(nvim/helix LSP)
                i = applyExtendedColor(self, i, &self.screen.pen.underline_color);
                continue;
            },
            else => {},
        }
        i += 1;
        // 직전 주 파라미터에 딸린 colon sub-parameter는 그 파라미터에 종속이라 별도 SGR로 처리하지
        // 않는다(ITU T.416). 4:3은 underline 스타일이지 italic(SGR 3)이 아니고, 4:0은 underline off지
        // SGR 0(전체 리셋)이 아니다 — 4 case에서 이미 소비했으니 여기선 건너뛰기만 한다. 38/48은 위에서
        // continue로 i를 직접 점프하므로 여기 오지 않는다.
        while (i < count and self.csi_subparam[i]) i += 1;
    }
}

/// 38/48 (확장 색)을 처리하고 다음으로 읽을 파라미터 인덱스를 돌려준다. 세미콜론
/// (38;2;r;g;b, 38;5;n)과 colon sub-parameter(38:2:colorspace:r:g:b, 38:5:n)를 모두 지원한다.
fn applyExtendedColor(self: *TerminalCore, start: usize, target: *types.Color) usize {
    const count = @min(self.csi_param_count, core.TerminalCore.max_csi_params);
    const mode = if (start + 1 < count) self.csi_params[start + 1] else 0;
    // mode가 ':'로 들어왔으면 colon 형식이다. colon mode 2는 r,g,b 앞에 colorspace
    // 컴포넌트가 하나 더 있다(빈 경우 '::'). mode 5는 두 형식 모두 n 위치가 같다.
    const colon_form = start + 1 < count and self.csi_subparam[start + 1];
    if (mode == 5 and start + 2 < count) {
        target.* = .{ .indexed = @intCast(@min(self.csi_params[start + 2], 255)) };
        return start + 3;
    }
    if (mode == 2) {
        if (colon_form) {
            // colon 형식은 mode 뒤의 colon sub-parameter가 [r,g,b](3개) 또는
            // [colorspace,r,g,b](4개, colorspace는 빈 '::'일 수 있음)다. colorspace가
            // 있는지 개수로 정해진 게 아니므로(38:2:r:g:b처럼 생략 가능) mode 뒤 colon
            // 컴포넌트 수를 세어, r,g,b는 항상 마지막 3개로 읽는다. 이전에는 colorspace가
            // 항상 있다고 가정해 38:2:r:g:b(5컴포넌트)를 통째로 버렸다.
            var n: usize = 0;
            while (start + 2 + n < count and self.csi_subparam[start + 2 + n]) : (n += 1) {}
            if (n >= 3) {
                const rgb_start = start + 2 + (n - 3);
                target.* = .{ .rgb = .{
                    .r = @intCast(@min(self.csi_params[rgb_start], 255)),
                    .g = @intCast(@min(self.csi_params[rgb_start + 1], 255)),
                    .b = @intCast(@min(self.csi_params[rgb_start + 2], 255)),
                } };
                return start + 2 + n;
            }
        } else if (start + 4 < count) {
            // 세미콜론 형식 38;2;r;g;b — r,g,b가 mode 바로 뒤.
            target.* = .{ .rgb = .{
                .r = @intCast(@min(self.csi_params[start + 2], 255)),
                .g = @intCast(@min(self.csi_params[start + 3], 255)),
                .b = @intCast(@min(self.csi_params[start + 4], 255)),
            } };
            return start + 5;
        }
    }
    // 형식이 안 맞으면 나머지 파라미터를 버린다.
    return count;
}

// ── CSI 상태기계 (param 누적 + final dispatch) ──────────────────────────────────────────────────
// write 루프의 .csi 상태가 byte별로 handleCsiByte에 넘긴다: 숫자는 param에 누적, ;/: 는 다음 슬롯,
// </=/>/? 는 marker, 0x20..0x2f 는 intermediate, 0x40..0x7e final이면 dispatchCsi 후 ground 복귀.
// dispatchCsi는 (intermediate, marker, final)로 분기해 화면 연산(screen.X)·SGR/모드(같은 파일)·
// host-reply(self.appendResponse)로 위임한다. CSI param 접근자(csiRawParam/csiParam)는 core 잔류
// (screen.cursorPosition/setScrollRegion도 호출 — self.로 부른다).

pub fn beginCsi(self: *TerminalCore) void {
    self.csi_params = [_]u16{0} ** core.TerminalCore.max_csi_params;
    self.csi_subparam = [_]bool{false} ** core.TerminalCore.max_csi_params;
    // 항상 최소 1개의 (비어 있을 수도 있는) 파라미터가 있다고 본다.
    self.csi_param_count = 1;
    self.csi_has_digit = false;
    self.csi_marker = 0;
    self.csi_intermediate = 0;
    self.csi_overflow = false;
}

/// ';'(is_sub=false)나 ':'(is_sub=true)로 다음 파라미터 슬롯을 연다. ':'로 연 슬롯은
/// sub-parameter로 표시해, 38/48 확장 색의 colon 형식을 세미콜론 형식과 구분한다.
fn csiNextParam(self: *TerminalCore, is_sub: bool) void {
    if (self.csi_param_count >= core.TerminalCore.max_csi_params) {
        self.csi_overflow = true;
    } else {
        self.csi_param_count += 1;
        self.csi_subparam[self.csi_param_count - 1] = is_sub;
    }
    self.csi_has_digit = false;
}

pub fn handleCsiByte(self: *TerminalCore, byte: u8) void {
    switch (byte) {
        '0'...'9' => {
            self.csi_has_digit = true;
            // 파라미터가 max(16)를 넘으면(';'가 csi_overflow를 세움) 이후 자릿수는 버린다.
            // 안 그러면 17번째+ 파라미터의 숫자가 params[15]에 누적돼 마지막 파라미터를
            // 오염시킨다.
            if (self.csi_overflow) return;
            const slot = self.csi_param_count - 1;
            const digit: u16 = byte - '0';
            const value = self.csi_params[slot];
            // saturating: 손상/악성 입력이 u16을 넘기지 않게 한다.
            self.csi_params[slot] = if (value > (std.math.maxInt(u16) - digit) / 10)
                std.math.maxInt(u16)
            else
                value * 10 + digit;
        },
        // ';'는 파라미터 구분자, ':'는 sub-parameter 구분자다. 둘 다 다음 슬롯을 열되,
        // ':'로 연 슬롯은 sub-parameter로 표시해 colon 확장색 형식을 구분한다.
        ';' => csiNextParam(self, false),
        ':' => csiNextParam(self, true),
        // private/marker bytes: < = > ? (예: CSI ? 25 h). 어떤 marker였는지 기억한다.
        0x3c...0x3f => self.csi_marker = byte,
        // intermediate bytes(공백~/): 같은 final이라도 다른 명령이 된다 — 바이트를 기억해
        // (intermediate, final) 튜플로 dispatch한다(아래 dispatchCsi).
        0x20...0x2f => self.csi_intermediate = byte,
        // final byte: 시퀀스를 dispatch하고 ground로 돌아간다.
        0x40...0x7e => {
            dispatchCsi(self, byte);
            self.parser = .ground;
        },
        // ESC는 진행 중인 CSI를 취소하고 새 escape를 시작한다(VT abort-and-restart). 안 하면
        // ESC[ ESC[31m 같은 입력에서 두 번째 시퀀스가 글자로 샌다.
        0x1b => self.parser = .escape,
        // CSI 안의 C0 control(ESC 제외)은 실행하고 CSI 파싱을 계속한다(VT spec). writeCodepoint가
        // CR/LF/Tab/BS를 처리하고 나머지 C0는 버린다. parser는 .csi로 유지된다.
        0x00...0x1a, 0x1c...0x1f => screen.writeCodepoint(self, byte),
        // 그 밖(DEL/high byte)은 CSI를 중단하고 소비한다(관대 처리).
        else => self.parser = .ground,
    }
}

fn dispatchCsi(self: *TerminalCore, final: u8) void {
    // intermediate가 붙은 시퀀스는 bare final과 다른 명령이다 — 아는 (intermediate, final)
    // 조합만 dispatch하고 나머지는 소비한다(Williams VT500 파서의 튜플 dispatch 의미).
    if (self.csi_intermediate != 0) {
        switch (self.csi_intermediate) {
            ' ' => switch (final) {
                'q' => screen.setCursorStyle(self, self.csiRawParam(0)), // DECSCUSR
                else => {},
            },
            '$' => switch (final) {
                // DECRQM(CSI ? Ps $ p): private mode 상태 질의. 앱(terminal-unicode-core 등)이
                // mode 2027 지원 여부를 이걸로 먼저 묻고, "지원함"이면 DECSET 2027로 켠다. 응답이
                // 없으면 미지원으로 보고 안 켜므로, 우리가 아는 모드는 현재 상태를 보고한다.
                'p' => if (self.csi_marker == '?') reportPrivateMode(self, self.csiRawParam(0)),
                else => {},
            },
            else => {}, // `$r`(DECCARA) 등 미지원 조합은 무시
        }
        return;
    }
    // marker별 처리: '?'는 DEC private mode(DECSET/DECRST), '>'는 secondary DA. 그 외 marker
    // 시퀀스(>m modifyOtherKeys, <u kitty 등)는 소비만 한다 — bare final로 흘리면 SGR 등을
    // 오염시킨다.
    if (self.csi_marker != 0) {
        switch (self.csi_marker) {
            '?' => switch (final) {
                'h' => setPrivateModes(self, true),
                'l' => setPrivateModes(self, false),
                // kitty keyboard(CSI ? u): 현재 flag 스택 최상단을 CSI ? flags u로 보고. 앱이 지원
                // 여부·현재 모드를 감지한다(flags=0이면 비활성). 베이스: kitty keyboard protocol query.
                'u' => reportKittyFlags(self),
                else => {},
            },
            '>' => switch (final) {
                // DA2(CSI > c): 단말 버전 식별. DA1만 답하고 침묵하면 vim 등이 DA2 응답을
                // 타임아웃까지 기다린다. VT220급(1), 버전 10, ROM 0으로 답한다.
                'c' => if (self.csiRawParam(0) == 0) self.appendResponse("\x1b[>1;10;0c"),
                // XTVERSION(CSI > q, Ps=0): xterm ctlseqs "Report xterm name and version".
                // DA1/DA2가 범용 신원만 주는 것과 달리 "이 단말은 maru다"를 이름으로 알리는
                // 런타임 자기식별 채널이다. 응답은 DCS `DCS > | <name> <version> ST`
                // (= ESC P > | ... ESC \). Ps=0만 정의돼 있어 그 외엔 침묵한다. 이름/버전은
                // terminal_name/terminal_version 단일 출처에서 comptime으로 조립한다.
                'q' => if (self.csiRawParam(0) == 0)
                    self.appendResponse("\x1bP>|" ++ core.terminal_name ++ " " ++ core.terminal_version ++ "\x1b\\"),
                // kitty keyboard(CSI > flags u): flag 스택에 push(enable). flags는 u5로 truncate.
                'u' => self.kitty_flags.push(kittyFlagsFromParam(self.csiRawParam(0))),
                else => {},
            },
            '<' => switch (final) {
                // kitty keyboard(CSI < n u): 스택에서 n개(기본 1) pop — 이전 모드 복원/비활성.
                'u' => self.kitty_flags.pop(self.csiParam(0, 1)),
                else => {},
            },
            '=' => switch (final) {
                // kitty keyboard(CSI = flags ; mode u): 최상단 flags set — mode 1=치환·2=or·3=not(기본 1).
                'u' => self.kitty_flags.set(switch (self.csiParam(1, 1)) {
                    2 => .@"or",
                    3 => .not,
                    else => .set,
                }, kittyFlagsFromParam(self.csiRawParam(0))),
                else => {},
            },
            else => {},
        }
        return;
    }
    switch (final) {
        'm' => applySgr(self),
        'H', 'f' => screen.cursorPosition(self),
        'A' => screen.cursorVertical(self, self.csiParam(0, 1), true),
        'B', 'e' => screen.cursorVertical(self, self.csiParam(0, 1), false),
        'C', 'a' => screen.cursorHorizontal(self, self.csiParam(0, 1), true),
        'D' => screen.cursorHorizontal(self, self.csiParam(0, 1), false),
        'G', '`' => screen.cursorToColumn(self, self.csiParam(0, 1)),
        'd' => screen.cursorToRow(self, self.csiParam(0, 1)),
        'J' => screen.eraseInDisplay(self, self.csiRawParam(0)),
        'K' => screen.eraseInLine(self, self.csiRawParam(0)),
        'X' => screen.eraseCharacters(self, self.csiParam(0, 1)), // ECH: 커서부터 N개(기본 1) cell blank, 커서 유지 — nvim이 모드 라벨(-- INSERT --) clear에 이걸 쓴다
        'n' => deviceStatusReport(self),
        'r' => screen.setScrollRegion(self),
        'L' => screen.insertLines(self, self.csiParam(0, 1)),
        'M' => screen.deleteLines(self, self.csiParam(0, 1)),
        '@' => screen.insertChars(self, self.csiParam(0, 1)), // ICH: 커서에 N개(기본 1) blank 삽입, 오른쪽으로 민다
        'P' => screen.deleteChars(self, self.csiParam(0, 1)), // DCH: 커서에서 N개(기본 1) 삭제, 왼쪽으로 당긴다
        'Z' => screen.cursorBackTab(self, self.csiParam(0, 1)), // CBT: 역방향 N개(기본 1) 탭스톱 — Shift+Tab 폼 역이동
        'g' => screen.clearTabstop(self, self.csiRawParam(0)), // TBC: 0(기본)=커서 열 탭스톱 제거, 3=전체 제거
        'b' => repeatLastChar(self, self.csiParam(0, 1)), // REP(G5): 직전 graphic 글자를 N회 반복
        'S' => screen.scrollRangeUp(self, self.scroll_top, self.scroll_bottom, self.csiParam(0, 1), false), // SU(G7): scroll region N줄 위로 팬(history 미보관)
        'T' => screen.scrollRangeDown(self, self.scroll_top, self.scroll_bottom, self.csiParam(0, 1)), // SD(G7): scroll region N줄 아래로 팬
        'h' => setAnsiModes(self, true), // SM(G6): 비-private ANSI 모드 set(IRM=4 등)
        'l' => setAnsiModes(self, false), // RM(G6): 비-private ANSI 모드 reset
        // SCOSC/SCORC(CSI s / CSI u): ANSI(SCO) 커서 저장/복원. DECSC/DECRC(ESC 7/8)와 같은 슬롯을
        // 쓴다(위치+pen+pending_wrap). xterm은 좌우 margin 모드(DECLRMM ?69)일 때만 CSI s를 DECSLRM으로
        // 보지만, maru는 좌우 margin 미구현이라 항상 save로 처리한다. multi-line progress(brew 등)가
        // 커서 저장→여러 줄 그리기→복원으로 제자리 갱신하는 표준 수단이다 — 복원을 무시하면 진행바가
        // 줄줄이 쌓인다. 베이스: xterm ctlseqs SCOSC/SCORC(Ghostty 동등). bare 's'/'u'만 — kitty CSI u
        // (`> < = ?` prefix)는 위 private 분기에서 처리하므로 여기 안 온다.
        's' => screen.saveCursorState(self),
        'u' => screen.restoreCursorState(self),

        // DA1(CSI c / CSI 0 c): 터미널 식별 질의. 프로그램(claude CLI 등)이 시작 시 기능 협상
        // 으로 보내며, 응답이 없으면 타임아웃을 기다리거나 기능을 보수적으로 끈다. VT102로
        // 식별한다(CSI ?6c) — 현재 구현 수준(커서/erase/scroll region/IL/DL)과 부합.
        'c' => if (self.csiRawParam(0) == 0) self.appendResponse("\x1b[?6c"),
        else => {},
    }
}

// ── write 상태기계 (바이트 스트림 → escape/CSI/OSC/DCS/APC + UTF-8) ──────────────────────────────
// 이 파일의 최상위 진입점. core.write(facade)가 owner_dbg 확인 후 feed로 위임한다. ground 상태는 UTF-8을
// 셀로(screen.writeCodepoint), ESC는 escape/CSI/OSC/DCS/APC 상태로 분기한다. 상태(self.parser)는 write 호출을
// 가로질러 유지돼 PTY read 경계로 쪼개진 시퀀스를 잇는다. PTY read가 codepoint 중간에 끊기면 storePendingUtf8이
// 꼬리를 보관하고 다음 호출의 completePendingUtf8이 잇는다(레이어 경계: PTY는 바이트 전송만, 디코딩은 여기).

pub fn feed(self: *TerminalCore, bytes: []const u8) !void {
    var index_: usize = 0;
    while (index_ < bytes.len) {
        switch (self.parser) {
            .ground => {
                if (self.utf8_tail_len != 0) {
                    index_ = try completePendingUtf8(self, bytes, index_);
                    continue;
                }
                const byte = bytes[index_];
                if (byte == 0x1b) {
                    self.parser = .escape;
                    index_ += 1;
                    continue;
                }

                const sequence_len = utf8SequenceLength(byte) catch return error.InvalidUtf8;
                const end = index_ + sequence_len;
                if (end > bytes.len) {
                    storePendingUtf8(self, bytes[index_..]);
                    return;
                }

                const codepoint = decodeUtf8(bytes[index_..end]) catch return error.InvalidUtf8;
                screen.writeCodepoint(self, codepoint);
                index_ = end;
            },
            .escape => {
                handleEscapeByte(self, bytes[index_]);
                index_ += 1;
            },
            .escape_intermediate => {
                // ESC <intermediate> <final>: DECALN(ESC # 8)이면 화면을 'E'로 채우고, 아니면 charset 지정
                // (intermediate '('=G0·')'=G1, final '0'=dec_special·'B'=ascii). 미지원 조합은 ascii로 소비.
                const final = bytes[index_];
                if (self.escape_intermediate_byte == '#' and final == '8') {
                    screen.decAlign(self); // DECALN(G11)
                } else {
                    screen.designateCharset(self, self.escape_intermediate_byte, final);
                }
                self.parser = .ground;
                index_ += 1;
            },
            .csi => {
                handleCsiByte(self, bytes[index_]);
                index_ += 1;
            },
            .osc => {
                const byte = bytes[index_];
                // OSC string은 BEL(0x07) 또는 ST(ESC \)로 끝난다. 내용은 버퍼에 모아 종료
                // 시점에 해석한다(현재 OSC 8 하이퍼링크만 적용, title 등은 소비).
                if (byte == 0x07) {
                    dispatchOsc(self);
                    self.parser = .ground;
                } else if (byte == 0x1b) {
                    self.parser = .osc_escape;
                } else if (oscMayGrow(self)) {
                    self.osc_buffer.append(self.allocator, byte) catch {
                        self.osc_overflow = true; // OOM도 폐기(graceful — APC 수집과 동형)
                    };
                } else {
                    self.osc_overflow = true; // 상한 초과 — 너무 긴 OSC는 통째로 무시
                }
                index_ += 1;
            },
            .osc_escape => {
                // OSC 안에서 ESC 다음 바이트. ST(ESC \)면 정상 종료로 dispatch(defer가 capacity 반납),
                // 그 외(abort)도 OSC를 끝내되(관대 처리 — 내용은 버린다) dispatch를 안 거치므로 여기서 직접
                // 반납한다 — 안 그러면 대용량 OSC 52를 abort로 끊었을 때 megabyte가 상주한다(상한 재확립).
                if (bytes[index_] == '\\') {
                    dispatchOsc(self);
                    self.parser = .ground;
                    index_ += 1;
                } else {
                    reclaimOscBuffer(self);
                    // **ESC를 삼키지 않는다.** ECMA-48/DEC 상태 머신에서 ESC는 anywhere transition이라, 문자열
                    // 시퀀스 도중의 ESC는 그 시퀀스를 취소하고 **그 ESC부터 새 시퀀스를 시작**한다. 예전에는
                    // abort하며 ESC를 소비해, 뒤따르는 `]777;notify;…`가 본문 텍스트로 화면에 찍히고 알림은
                    // 유실됐다(실측: claude가 타이틀 OSC 재설정 중 알림 OSC를 보내면 재현). index_를 올리지 않고
                    // `.escape`로 되돌려 현재 바이트를 새 시퀀스의 첫 바이트로 다시 본다.
                    self.parser = .escape;
                }
            },
            .apc => {
                const byte = bytes[index_];
                // APC는 ST(ESC \)로 끝난다. ESC면 apc_escape로, 아니면 버퍼에 모은다(넘치면 overflow
                // 표시 후 무시 — 거대/악의적 시퀀스 방어). OSC 수집과 동형.
                if (byte == 0x1b) {
                    self.parser = .apc_escape;
                } else if (self.apc_buffer.items.len < core.TerminalCore.max_kitty_chunk_bytes) {
                    self.apc_buffer.append(self.allocator, byte) catch {
                        self.apc_overflow = true; // OOM도 폐기(graceful)
                    };
                } else {
                    self.apc_overflow = true; // 상한 초과 — 거대/악의적 시퀀스 방어
                }
                index_ += 1;
            },
            .apc_escape => {
                // APC 안에서 ESC 다음 바이트. ST(ESC \)면 dispatch, 그 외는 APC를 취소하고 그 ESC부터 새
                // 시퀀스를 시작한다(osc_escape와 같은 근거 — ESC는 anywhere transition).
                if (bytes[index_] == '\\') {
                    dispatchApc(self);
                    self.parser = .ground;
                    index_ += 1;
                } else {
                    self.parser = .escape;
                }
            },
            .dcs => {
                const byte = bytes[index_];
                // DCS는 ST(ESC \)로만 끝난다(OSC와 달리 BEL 종료 없음). 내용을 모아 종료 시 dispatch.
                if (byte == 0x1b) {
                    self.parser = .dcs_escape;
                } else if (self.dcs_len < self.dcs_buffer.len) {
                    self.dcs_buffer[self.dcs_len] = byte;
                    self.dcs_len += 1;
                } else {
                    self.dcs_overflow = true; // 너무 긴 DCS(Sixel 등 미지원) — 폐기
                }
                index_ += 1;
            },
            .dcs_escape => {
                // DCS 안에서 ESC 다음 바이트. ST(ESC \)면 dispatch, 그 외는 DCS를 취소하고 그 ESC부터 새
                // 시퀀스를 시작한다(osc_escape와 같은 근거 — ESC는 anywhere transition).
                if (bytes[index_] == '\\') {
                    dispatchDcs(self);
                    self.parser = .ground;
                    index_ += 1;
                } else {
                    self.parser = .escape;
                }
            },
        }
    }
}

fn handleEscapeByte(self: *TerminalCore, byte: u8) void {
    switch (byte) {
        '[' => {
            beginCsi(self);
            self.parser = .csi;
        },
        ']' => {
            reclaimOscBuffer(self); // 방어적 백스톱: 정상 경로면 이미 반납됐고, 여기서도 상한을 재확립(clearRetainingCapacity 대체)
            self.osc_overflow = false;
            self.osc_large_ok = false; // 새 수집 — 접두 판정 캐시 리셋
            self.parser = .osc;
        },
        // APC(ESC _): application program command. kitty graphics(`ESC _ G ...`)가 쓴다. OSC와
        // 동형으로 버퍼에 모아 ESC \(ST)에서 dispatch한다 — 안 받으면 payload가 화면에 텍스트로 샌다.
        '_' => {
            self.apc_buffer.clearRetainingCapacity();
            self.apc_overflow = false;
            self.parser = .apc;
        },
        // DCS(ESC P ... ST): device control string. 현재 DECRQSS(`DCS $ q`)만 처리하고 ST에서 dispatch한다.
        // 안 받으면 payload(예: tmux의 `$q`)가 화면에 텍스트로 샌다. G14 — Sixel/DECDLD의 토대 상태기계.
        'P' => {
            self.dcs_len = 0;
            self.dcs_overflow = false;
            self.parser = .dcs;
        },
        // IND(ESC D): index. CR 없이 한 줄 내림 + 하단 margin이면 scroll region을 위로 민다(LF와 동일).
        'D' => {
            screen.lineFeed(self);
            self.parser = .ground;
        },
        // RI(ESC M): reverse index. 한 줄 올림 + 상단 margin이면 scroll region을 아래로 민다.
        'M' => {
            screen.reverseIndex(self);
            self.parser = .ground;
        },
        // HTS(ESC H): 현재 커서 열에 탭스톱을 설정한다(G4 동적 탭스톱).
        'H' => {
            if (self.screen.cursor.col < self.tabstops.len) self.tabstops[self.screen.cursor.col] = true;
            self.parser = .ground;
        },
        // NEL(ESC E): next line = CR + LF. 커서를 다음 줄 0열로 옮긴다(하단 margin이면 스크롤). G12.
        'E' => {
            const old_cursor = self.screen.cursor;
            self.screen.cursor.col = 0;
            screen.markCursorMoveDirty(self, old_cursor, self.screen.cursor);
            screen.lineFeed(self);
            self.parser = .ground;
        },
        // DECSC(ESC 7)/DECRC(ESC 8): 커서(위치+pen+pending_wrap) 저장/복원. claude CLI 등이
        // 시작 시 `ESC 7, CSI r, ESC 8`로 scroll region을 리셋하는데, CSI r의 부수효과(커서
        // home)를 ESC 8이 되돌린다 — 복원이 없으면 커서가 (0,0)에 남아 UI가 기존 화면 맨 위를
        // 덮는다. DECSET 1048과 같은 저장 슬롯을 쓴다(xterm 동일).
        '7' => {
            screen.saveCursorState(self);
            self.parser = .ground;
        },
        '8' => {
            screen.restoreCursorState(self);
            self.parser = .ground;
        },
        // RIS(ESC c): 하드 리셋. 화면/스크롤백/선택/링크 저장소를 비우고 pen·pen_link·모드를
        // 초기화한다. 안 하면 열린 OSC 8 링크(pen_link)·intern된 URI가 리셋을 넘어 살아남는다.
        'c' => {
            self.fullReset();
            self.parser = .ground;
        },
        // DECKPAM(ESC =)/DECKPNM(ESC >): application/numeric keypad 모드(G10). 모드만 추적(numpad 인코딩은 후속).
        '=' => {
            self.application_keypad = true;
            self.parser = .ground;
        },
        '>' => {
            self.application_keypad = false;
            self.parser = .ground;
        },
        // ESC <intermediate>(0x20..0x2f) <final>: charset designation 등 2바이트 시퀀스. intermediate를
        // 기억해 escape_intermediate가 final과 함께 해석한다(G0 `(` vs G1 `)` 구분).
        0x20...0x2f => {
            self.escape_intermediate_byte = byte;
            self.parser = .escape_intermediate;
        },
        // ESC 다음에 또 ESC가 오면 앞의 것은 버려진 시작이고 뒤의 것이 진짜 시작이다(ESC는 anywhere
        // transition). ground로 떨어뜨리면 이어지는 `]777;…`이 본문 텍스트가 되어 화면을 더럽히고 알림이
        // 유실된다 — 문자열 시퀀스 abort와 같은 결함이라 여기서도 escape 상태를 유지한다.
        0x1b => self.parser = .escape,
        // 그 밖의 ESC <final>(NEL 등)은 A1에서 소비만 한다.
        else => self.parser = .ground,
    }
}

fn completePendingUtf8(self: *TerminalCore, bytes: []const u8, index_: usize) !usize {
    const sequence_len = utf8SequenceLength(self.utf8_tail[0]) catch {
        self.utf8_tail_len = 0;
        return error.InvalidUtf8;
    };
    const needed = sequence_len - self.utf8_tail_len;
    const available = bytes.len - index_;
    const take = @min(needed, available);

    @memcpy(
        self.utf8_tail[self.utf8_tail_len .. self.utf8_tail_len + take],
        bytes[index_ .. index_ + take],
    );
    self.utf8_tail_len += take;

    if (self.utf8_tail_len < sequence_len) return bytes.len;

    const codepoint = decodeUtf8(self.utf8_tail[0..sequence_len]) catch {
        self.utf8_tail_len = 0;
        return error.InvalidUtf8;
    };
    self.utf8_tail_len = 0;
    screen.writeCodepoint(self, codepoint);
    return index_ + take;
}

fn storePendingUtf8(self: *TerminalCore, bytes: []const u8) void {
    // PTY reads can stop in the middle of a codepoint. Keeping the partial
    // bytes inside TerminalCore preserves the layer boundary: PTY remains a
    // byte transport and does not need text-decoding logic.
    @memcpy(self.utf8_tail[0..bytes.len], bytes);
    self.utf8_tail_len = bytes.len;
}

fn utf8SequenceLength(first_byte: u8) !usize {
    return std.unicode.utf8ByteSequenceLength(first_byte) catch error.InvalidUtf8;
}

fn decodeUtf8(bytes: []const u8) !u21 {
    return std.unicode.utf8Decode(bytes) catch error.InvalidUtf8;
}
