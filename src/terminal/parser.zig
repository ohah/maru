//! VT 파서 dispatch — OSC 라우터 + DCS(DECRQSS·XTGETTCAP) + APC(kitty graphics) control 파싱·라우팅.
//!
//! `TerminalCore`(core.zig)는 VT 파서 상태기계 + 화면/스크롤백 storage + host-reply를 한 struct에 섞은
//! 구조 위반(docs/project-rules.md "구조와 파일 분리": parser·storage·encoding이 한 파일에서 서로 다른
//! 이유로 바뀌면 facade는 유지하되 구현을 목적별로 분리)을 목적별 파일로 떼어내는 **parser 분리 1단계**다.
//! 여기는 "바이트를 해독하고 시퀀스를 dispatch하는" 파서 책임을 모은다(화면 연산은 screen.zig, OSC host-reply는
//! osc.zig). struct·facade(terminal.zig)는 불변이고, 각 핸들러는 `*TerminalCore`를 받는 free 함수다
//! (필드 + pub helper만 접근 — Zig는 필드 privacy가 없어 cross-file 필드 접근이 자유롭다). 현재 진입점은
//! core.zig의 write 상태기계 루프가 위임한다: `.dcs_escape`→`dispatchDcs`(5/N), `.osc`/`.osc_escape`→
//! `dispatchOsc`(6/N), `.apc_escape`→`dispatchApc`(7/N). 남은 파서 dispatch(CSI·SGR·escape·write 루프
//! 본체)는 후속 PR로 이리로 이주한다(점진 분리, docs/terminal-core-decomposition.md §4 Phase D).
//!
//! 베이스: xterm ctlseqs DCS(DECRQSS는 VT420, XTGETTCAP는 xterm). 단일 표준 없는 동작의 결정은 해당
//! 핸들러 주석·docs/terminal-compatibility-policy.md를 단일 출처로 둔다.

const std = @import("std");
const core = @import("core.zig");
const types = @import("types.zig");
const osc = @import("osc.zig"); // OSC host-reply 핸들러 — 라우터(dispatchOsc)가 코드별로 위임

const TerminalCore = core.TerminalCore;

/// 종료된 OSC 내용을 코드별로 분기한다. 각 핸들러는 osc.zig(host-reply)에 있고 여기는 라우터다 —
/// OSC 8(하이퍼링크)·133(semantic)·7(cwd)·0/2(title)·10/11/110/111(색)·52(클립보드)·4/104(팔레트)·
/// 777/9(알림)·5379(maru)로 가른다. core.zig의 write 상태기계 루프(`.osc`/`.osc_escape`)가 위임한다.
pub fn dispatchOsc(self: *TerminalCore) void {
    if (self.osc_overflow) return; // 2048 버퍼를 넘긴 OSC는 통째로 무시(거대/악의적 시퀀스 방어)
    const body = self.osc_buffer[0..self.osc_len];
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
    const s = self.pen;
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
        self.execKittyGraphics(cmd, payload);
        return;
    }
    // chunked 진행 중 도착한 명령이 transmit continuation(a=t/T)이 아니라 독립 명령(delete 등)이면,
    // kitty 명세상 정의되지 않은 interleave다 — 진행 중 chunk를 버리고 새 명령을 즉시 실행한다(code
    // review #3, 사용자 결정). continuation은 a= 생략(기본 t) 또는 t/T라 누적 경로로 떨어진다.
    if (self.kitty_chunk_cmd != null and cmd.action != 't' and cmd.action != 'T') {
        abortKittyChunk(self);
        self.execKittyGraphics(cmd, payload);
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
        self.execKittyGraphics(first, self.kitty_chunk.items);
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
/// (KittyGraphicsCommand)는 core가 소유(exec·storage가 공유 — parse→exec DTO라 pub).
pub fn parseKittyGraphicsCommand(body: []const u8) core.TerminalCore.KittyGraphicsCommand {
    var cmd: core.TerminalCore.KittyGraphicsCommand = .{};
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
