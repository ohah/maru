//! OSC(Operating System Command) host-reply 핸들러 — 색·팔레트 질의/설정(OSC 10/11/4/104/110/111),
//! 클립보드(OSC 52)·notify(OSC 9/777)·hyperlink(OSC 8)·cwd(OSC 7)·maru(OSC 5379)·semantic prompt(OSC 133).
//!
//! `TerminalCore`의 "host-reply/encoding" 책임(rule: parser·storage·encoding이 한 파일에서 서로 다른 이유로
//! 바뀌면 facade는 유지하되 구현을 목적별로 분리 — docs/project-rules.md "구조와 파일 분리")을 목적별 파일로 떼어낸다.
//! struct·facade(terminal.zig)는 불변이고, 각 핸들러는 `*TerminalCore`를 받는 free 함수다(필드 + pub helper만 접근).
//! OSC 라우터 진입점 `dispatchOsc`는 parser.zig에 있고(분할 6/N), 코드별로 여기 핸들러에 위임한다.
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
/// parser.max_osc_bytes(OSC 본문 수집 상한)가 이 값에서 파생된다(base64 4/3× + 헤더) — 둘이 어긋나면
/// 이 상한에 못 미치는 클립보드도 파서가 먼저 버린다(pub인 이유).
pub const max_clipboard_bytes: usize = 16 * 1000 * 1000;

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
    if (decoded_len == 0) return; // 빈 데이터 무시(no-op — 거부 아님)
    if (decoded_len > max_clipboard_bytes) {
        // 상한 초과 거부(폭주 방어선). 무음 폐기 대신 표면화 — platform이 takeClipboardWriteRejected로 drain해 notice.
        // (대개 base64가 max_osc_bytes를 먼저 넘어 parser overflow로 잡히지만, 경계 반올림 케이스의 belt다.)
        self.clipboard_write_rejected = true;
        return;
    }
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
    // ConEmu 공개 OSC 9;4 progress: `4;state[;value]`. 상태 관측용 최신값만 보관하고 데스크톱 알림은
    // 만들지 않는다. https://conemu.github.io/en/AnsiEscapeCodes.html#ConEmu_specific_OSC
    if (std.mem.startsWith(u8, body, "4;")) {
        self.agent_progress.clearRetainingCapacity();
        self.agent_progress.appendSlice(self.allocator, body) catch self.agent_progress.clearRetainingCapacity();
        return;
    }
    // ConEmu 공개 OSC 9;9 "set working directory": `9;<경로>`. **Windows 네이티브 셸의 cwd 보고가 이것이다**
    // (docs/windows-platform.md §3.2) — Microsoft가 cmd·PowerShell 셸 통합으로 안내하고 Windows Terminal이
    // 채택했다. OSC 7과 달리 `file://` URI가 아니라 **네이티브 경로**를 그대로 나른다.
    if (std.mem.startsWith(u8, body, "9;")) {
        dispatchConEmuCwd(self, body[2..]);
        return;
    }
    if (!isNotify9Body(body)) return; // `<숫자>;...` → ConEmu 서브커맨드(소비, 알림 안 함)
    setNotification(self, "", body); // iTerm2: title 없음, body=메시지 전체
}

/// OSC 9;9의 cwd. **host(authority)를 건드리지 않는다** — 이 시퀀스는 authority를 나르지 않기 때문이다
/// (docs/windows-platform.md §3.2a). 지우면 원격 세션이 로컬로 뒤집혀 원격 경로를 로컬 파일시스템에 대고
/// 해석하고(남의 저장소에 stage/discard), 만들어 내면 없는 근거로 원격을 주장하게 된다. 그래서 `dispatchCwd`가
/// (host, path)를 함께 세우는 것과 달리 여기서는 **path만** 세우고 host는 이전 값 그대로 둔다.
///
/// **percent-decode하지 않는다.** OSC 7의 path는 URI라 디코드가 맞지만 9;9은 네이티브 경로라, 디코드하면
/// `C:\temp\100%done` 같은 정상 경로가 깨진다.
///
/// **구분자를 정규화하지 않는다.** 그 선행조건 — 중립 레이어의 절대경로 판정을 `[0]=='/'`에서 떼어내는 것 —
/// 은 W1.5에서 끝났다(`path_shape.isAbsolute`; docs/windows-platform.md §5·§5.1). 그래도 여기서 바꾸지 않는
/// 것은 **정규화의 자리가 여기가 아니기 때문**이다: L2가 받는 경로가 POSIX여야 한다는 규칙
/// (docs/layering-and-portability.md §4.1)은 플랫폼이 코어로 넘기는 **입구**에 적용되고, 이 필드는 그 입구를
/// 아직 거치지 않은 셸의 원본 바이트다. 받은 그대로 보관한다.
fn dispatchConEmuCwd(self: *TerminalCore, raw: []const u8) void {
    // ConEmu 원본 스펙은 경로를 따옴표로 감싸고(`9;9;"C:\path"`), Microsoft가 안내하는 `PROMPT`는 감싸지
    // 않는다(`$e]9;9;$P$e\`). 둘 다 실제로 나오는 바이트라 양쪽을 받는다 — Windows 파일명에 `"`가 올 수
    // 없으므로 **양끝이 짝일 때만** 벗기는 것은 모호하지 않다(한쪽만 있으면 비정상 입력이라 그대로 둔다).
    const path = if (raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"')
        raw[1 .. raw.len - 1]
    else
        raw;
    if (path.len == 0) return; // 빈 경로는 무시 — 기존 cwd를 유지한다(부분 갱신으로 이전 값을 잃지 않는다)
    const copy = self.allocator.dupe(u8, path) catch return; // OOM이면 기존 cwd 유지(같은 이유)

    // `dispatchCwd`와 같은 규율: **실제로 바뀔 때만** bump한다. 이 generation은 창 제목 재sync만이 아니라
    // runtime observation refresh의 게이트라, 빠뜨리면 경로가 바뀌어도 관측이 안 돌아 폴더줄·cwd 상속·
    // 링크 스코프가 옛 판정에 머문다. 반대로 무조건 올리면 매 프롬프트 재보고가 헛 sync를 만든다.
    const changed = if (self.cwd) |old| !std.mem.eql(u8, old, copy) else true;
    if (self.cwd) |old| self.allocator.free(old);
    self.cwd = copy;
    if (changed) self.bumpTitleGeneration();
    self.recordShellEvent(.cwd_changed);
}

/// OSC 9 body가 ConEmu 서브커맨드(`<숫자>;...`)처럼 보이는가. 선두 숫자 뒤에 `;`가 오면 true.
fn looksLikeConemu9(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {}
    return i > 0 and i < s.len and s[i] == ';';
}

/// Parser overflow 경로도 정상 dispatch와 같은 OSC 9/ConEmu 판정을 쓰게 하는 SSOT다.
pub fn isNotify9Body(body: []const u8) bool {
    return body.len > 0 and !looksLikeConemu9(body);
}

/// 알림 title/body를 pending에 둔다(소유 버퍼에 복사). 할당 실패면 조용히 폐기(알림은 best-effort).
fn setNotification(self: *TerminalCore, title: []const u8, notify_body: []const u8) void {
    const next_generation = std.math.add(
        u64,
        self.notification_generation,
        1,
    ) catch return;
    var next_title: std.ArrayListUnmanaged(u8) = .empty;
    defer next_title.deinit(self.allocator);
    next_title.appendSlice(self.allocator, title) catch return;
    var next_body: std.ArrayListUnmanaged(u8) = .empty;
    defer next_body.deinit(self.allocator);
    next_body.appendSlice(self.allocator, notify_body) catch return;

    std.mem.swap(std.ArrayListUnmanaged(u8), &self.notification_title, &next_title);
    std.mem.swap(std.ArrayListUnmanaged(u8), &self.notification_body, &next_body);
    self.notification_generation = next_generation;
    self.notification_pending = true;
}

/// OSC 8: `8 ; params ; URI` — URI가 비면 링크 닫기, 있으면 열기(이후 출력 셀에 id가 찍힌다).
/// params(`id=...` 등)는 무시한다(xterm ctlseqs의 OSC 8 확장 — 시각 묶음 힌트일 뿐).
/// URI 안의 ';'는 보존된다(두 번째 구분자 이후 전부 URI). 링크 intern(storage)은 core가 소유(internLink, pub).
pub fn dispatchHyperlink(self: *TerminalCore, after_code: []const u8) void {
    const params_end = std.mem.indexOfScalar(u8, after_code, ';') orelse return;
    const uri = after_code[params_end + 1 ..];
    if (uri.len == 0) {
        self.pen_link = 0;
        return;
    }
    self.pen_link = self.internLink(uri) catch 0; // OOM이면 링크 없이 출력(텍스트는 보존)
}

/// OSC 7: `7 ; file://<host>/<percent-encoded path>` — 셸이 cwd를 보고한다. VTE(GNOME)가
/// 정의한 사실상 표준으로(공개 형식 문서 기반, VTE는 LGPL이라 소스 미열람), iTerm2/Terminal.app/
/// kitty/WezTerm이 채택했다. `file://` 스킴만 받고 첫 '/'부터의 path를 percent-decode해 저장하며,
/// 그 앞의 **authority(host)도 함께 보관**한다 — 버리면 원격 셸이 보고한 경로가 로컬 경로와 구분되지
/// 않아 폴더줄이 사라지거나 없는 디렉터리로 spawn한다(docs/ssh-integration.md §9). 형식이 안 맞거나
/// 빈 path, OOM이면 기존 cwd를 유지한다 — 부분/깨진 갱신으로 이전 값을 잃지 않게 한다.
pub fn dispatchCwd(self: *TerminalCore, body: []const u8) void {
    const scheme = "file://";
    if (!std.mem.startsWith(u8, body, scheme)) return; // file 스킴만(다른 스킴은 무시)
    const authority_and_path = body[scheme.len..];
    // file://<host>/<path> — host(authority)는 첫 '/'까지, path는 그 '/'부터(절대경로라 '/' 포함).
    const slash = std.mem.indexOfScalar(u8, authority_and_path, '/') orelse return;
    const raw_host = authority_and_path[0..slash];
    const raw_path = authority_and_path[slash..];
    if (raw_path.len == 0) return;
    const decoded = percentDecodeAlloc(self, raw_path) catch return; // OOM/실패면 기존 cwd 유지
    // host는 **같은 갱신 안에서** 확보한다. 여기서 실패했는데 path만 새 값으로 바꾸면 새 경로에 옛 host가
    // 붙어 짝이 어긋난다(로컬 경로에 원격 host가 붙는 최악의 오표시). 그래서 갱신 전체를 포기하고 이전
    // 쌍을 그대로 둔다. host는 percent-decode하지 않는다 — authority는 hostname이라 인코딩이 오지 않고,
    // 디코드하면 오히려 `%`가 든 이름이 다른 호스트로 바뀐다.
    const host_copy: ?[]u8 = if (raw_host.len == 0) null else self.allocator.dupe(u8, raw_host) catch {
        self.allocator.free(decoded);
        return;
    };
    // cwd가 **실제로 바뀔 때만** title_generation을 올린다 — 셸 통합(VTE/iTerm precmd)은 cd 안 해도 매 프롬프트 OSC 7을
    // 동일 경로로 재보고하므로, 무조건 bump하면 매 프롬프트 syncAutoTitles가 헛 lock+복사해 P4-1을 무력화한다(code-review [0]).
    //
    // **host 변경도 "바뀜"으로 친다.** 이 generation은 창 제목 재sync만이 아니라 **runtime observation refresh의
    // 게이트**이기도 하다(app_session term.refreshTermObservation). host만 달라진 전이(로컬 `/srv/app` ↔ 원격
    // `/srv/app` — ssh로 같은 경로에 들어가거나 빠져나오는, 같은 레이아웃을 쓰는 사람에겐 평범한 이동)에서 bump를
    // 빼면 observation이 통째로 갱신되지 않아 **폴더줄이 옛 host를 계속 그리고 cwd 상속·링크 스코프도 옛 판정에
    // 머문다**(적대적 검증에서 제품 렌더 경로 테스트로 발견). 경로나 host가 바뀔 때만이라 헛 sync는 여전히 없다.
    const cwd_changed = if (self.cwd) |old| !std.mem.eql(u8, old, decoded) else true;
    const host_changed = blk: {
        const old = self.cwd_host orelse "";
        const new = host_copy orelse "";
        break :blk !std.mem.eql(u8, old, new);
    };
    if (self.cwd) |old| self.allocator.free(old);
    self.cwd = decoded;
    if (self.cwd_host) |old| self.allocator.free(old);
    self.cwd_host = host_copy;
    if (cwd_changed or host_changed) self.bumpTitleGeneration(); // title이 null이면 windowTitle(cwd basename)이 바뀌므로 라벨 재sync 유도(P4-1, §12)
    self.recordShellEvent(.cwd_changed); // 값은 currentCwd()가 권위 — 이벤트는 경계만 표시(recordShellEvent: core, pub)
}

/// OSC 5379: maru 전용 통지(사설 OSC 번호 — 표준/벤더 충돌을 피하려 골랐다). payload는
/// `<서브커맨드>;<인자...>`. `ssh;<dest>`는 maru ssh 진입, `ssh-end`는 그 foreground ssh가 끝나 로컬 shell로
/// 돌아온 경계다. Maru는 dest로 cli.ssh.controlSocketPath를 계산해 드롭 파일을 그 control socket으로 업로드한다.
/// 알 수 없는 서브커맨드나 빈 dest는 무시하고(기존 상태 유지), OOM이면 갱신하지 않는다.
/// **dest가 실제로 바뀌면 title_generation을 올린다.** `ssh_remote_dest`는 runtime observation의 필드이고, 그
/// generation이 곧 observation refresh의 게이트다(위 OSC 7 주석의 같은 논지). bump가 없으면 periodic 관측이
/// "current"인 채 옛 값을 들고 있어, ssh에 들어가고 나오는 순간을 소비자가 **다음 cwd/title 변화 때까지 모른다**.
/// 원격 세션 동안에는 로컬 OSC 7이 오지 않으므로 그 공백이 길어질 수 있다 — 그 사이 저장소 판정이 원격 세션을
/// 로컬로 보고 남의 저장소를 보여 준다(적대적 검증에서 발견). barrier(`refreshObservation`)를 쓰는 소비자는
/// 원래 안전했고, 이 bump는 **periodic 경로도** 제때 보게 만든다. 값이 그대로면 올리지 않는다(헛 sync 방지).
pub fn dispatchMaru(self: *TerminalCore, body: []const u8) void {
    var it = std.mem.splitScalar(u8, body, ';');
    const sub = it.next() orelse return;
    if (std.mem.eql(u8, sub, "ssh-end")) {
        if (self.ssh_remote_dest) |old| {
            self.allocator.free(old);
            self.bumpTitleGeneration(); // 지울 게 있었을 때만(멱등 clear가 헛 sync를 만들지 않게)
        }
        self.ssh_remote_dest = null;
        return;
    }
    if (!std.mem.eql(u8, sub, "ssh")) return; // 알 수 없는 서브커맨드는 무시(소비만)
    const dest = it.rest(); // 첫 필드(sub) 뒤 나머지 전체 = dest(목적지 문자열)
    if (dest.len == 0) return; // 빈 dest는 무시(기존 dest 유지)
    const changed = if (self.ssh_remote_dest) |old| !std.mem.eql(u8, old, dest) else true;
    const dup = self.allocator.dupe(u8, dest) catch return; // OOM이면 기존 dest 유지
    if (self.ssh_remote_dest) |old| self.allocator.free(old);
    self.ssh_remote_dest = dup;
    if (changed) {
        // **ssh 에 들어가면 기록된 cwd 는 더 이상 이 pane 의 것이 아니다.**
        //
        // 그 값은 **ssh 를 치기 직전** 로컬 셸이 보고한 경로다. 원격 셸에 OSC 7 보고자가 없으면 그
        // 값이 세션 내내 남아, 소비처들이 그것을 **지금 이 터미널의 cwd** 로 읽는다 — 새 탭이 그리로
        // 열리고, 화면의 상대 경로가 그 기준으로 resolve 되고, 폴더줄이 남의 디렉터리를 가리킨다
        // (ssh-integration.md §9.4 가 원격 cwd 에 대해 닫아 둔 길이, 여기서는 「원격인 줄 모르는 채」로
        // 열려 있었다).
        //
        // 지우면 그 자리들이 **모른다** 로 떨어져 안전한 기본값(워크스페이스 root·감지 안 함·빈 줄)을
        // 쓴다. ssh 를 빠져나오면 로컬 셸의 `precmd` 보고자가 다음 프롬프트에서 곧바로 다시 채운다.
        //
        // ⚠️ 이것만으로 §9.4 보호가 켜지지는 **않는다** — `termCwdIsRemote` 는 authority 로만 판정하고
        // 빈 cwd 는 「로컬」로 떨어지므로, 화면의 **절대 경로**는 여전히 로컬 파일로 열린다. 그 구멍은
        // 원격 판정을 `ssh_remote_dest` 까지 넓히는 후속이 닫는다(적대적 검증이 이 순서를 확정했다).
        clearCwd(self);
        self.bumpTitleGeneration();
    }
}

/// 기록된 cwd 와 그 authority 를 버린다. **소유한 메모리를 푼다** — 두 값은 한 쌍이라 함께 지운다
/// (하나만 지우면 「host 는 아는데 경로는 모른다」 는 없는 상태가 된다).
fn clearCwd(self: *TerminalCore) void {
    if (self.cwd) |c| self.allocator.free(c);
    self.cwd = null;
    if (self.cwd_host) |h| self.allocator.free(h);
    self.cwd_host = null;
}

/// OSC 133(semantic prompt): 셸이 프롬프트/입력/출력 경계를 마킹한다. `133 ; <action> [; opts]`.
/// 명세: freedesktop semantic-prompts.md(FinalTerm 발) + kitty/Ghostty 확장. 동작 비교만 했고
/// 레퍼런스 코드 표현은 옮기지 않았다(clean-room). 옵션은 liberal하게 파싱 — 모르는 키는 무시한다.
///   A/P = 프롬프트 시작, B = 프롬프트 끝·입력 시작, C = 입력 끝·출력 시작, D[;code] = 명령 끝.
/// 각 마커는 현재 커서 행을 그 영역으로 태깅하고 semantic_state를 갱신한다(lineFeed가 다음 행에
/// 전파). D는 행을 태깅하지 않고 종료코드만 기록한 뒤 영역을 닫는다(.unknown). 이벤트 기록(recordShellEvent)·
/// exit 스탬프(stampPromptExit)는 core가 소유(prompt 분류 storage, pub).
pub fn dispatchSemanticPrompt(self: *TerminalCore, rest: []const u8) void {
    if (rest.len == 0) return;
    const action = rest[0];
    // action 뒤에 내용이 더 있으면 반드시 ';'로 시작해야 한다(아니면 `Pextra`류 — invalid).
    if (rest.len > 1 and rest[1] != ';') return;
    const opts: []const u8 = if (rest.len > 2) rest[2..] else "";
    const row: u16 = @intCast(@min(self.screen.cursor.row, std.math.maxInt(u16)));
    switch (action) {
        // A(fresh_line_new_prompt)·P(prompt_start) — PR1은 동일 취급(prompt_kind 옵션은 파싱·무시).
        'A', 'P' => {
            self.semantic_state = .prompt;
            self.screen.prompt_marks[self.screen.cursor.row] = .{ .kind = .prompt }; // 새 프롬프트 — exit 리셋
            self.recordShellEvent(.{ .prompt_start = row });
        },
        'B' => {
            self.semantic_state = .input;
            self.screen.prompt_marks[self.screen.cursor.row].kind = .input; // exit는 보존(D가 채움)
            self.recordShellEvent(.{ .input_start = row });
        },
        'C' => {
            self.semantic_state = .command;
            self.screen.prompt_marks[self.screen.cursor.row].kind = .command;
            self.recordShellEvent(.{ .command_start = row });
        },
        'D' => {
            // 첫 ';' 구분 토큰을 종료코드로(없거나 정수 아니면 이전 값 유지 — 명세상 D는 code 없이도 옴).
            const first = if (std.mem.indexOfScalar(u8, opts, ';')) |s| opts[0..s] else opts;
            var exit_clamped: ?i16 = null;
            if (std.fmt.parseInt(i32, first, 10) catch null) |code| {
                self.last_command_exit = code;
                exit_clamped = @intCast(std.math.clamp(code, std.math.minInt(i16), std.math.maxInt(i16)));
                // 이 명령의 프롬프트 시작 행(커서에서 위로 가장 가까운 isPromptStart)에 종료코드를
                // 스탬프한다 — 거터가 그 행 옆에 ✓(0)/✗(≠0)를 그린다. exit는 행과 함께 carry된다.
                self.stampPromptExit(exit_clamped.?);
            }
            self.recordShellEvent(.{ .command_end = .{ .row = row, .exit = exit_clamped } });
            self.semantic_state = .unknown; // 명령 끝 — 영역을 닫는다(커서 행은 태깅하지 않음)
        },
        // L(fresh_line)·I·N 등은 수용하되 무동작(분류 상태 변화 없음).
        else => {},
    }
}

/// `%XX`를 바이트로 디코드한 새 문자열을 돌려준다(호출자 소유). 잘못된 %escape(두 hex가
/// 아니거나 끝에서 잘림)는 관대하게 '%'를 리터럴로 두고 계속한다 — path 한 글자가 깨졌다고
/// 전체를 버리지 않는다. UTF-8 바이트는 그대로 통과(셸이 raw로 보내든 %인코드로 보내든 복원). OSC 7 전용.
fn percentDecodeAlloc(self: *TerminalCore, s: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(self.allocator);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '%' and i + 2 < s.len) {
            const hi = std.fmt.charToDigit(s[i + 1], 16) catch {
                try out.append(self.allocator, s[i]);
                i += 1;
                continue;
            };
            const lo = std.fmt.charToDigit(s[i + 2], 16) catch {
                try out.append(self.allocator, s[i]);
                i += 1;
                continue;
            };
            try out.append(self.allocator, hi * 16 + lo);
            i += 3;
        } else {
            try out.append(self.allocator, s[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(self.allocator);
}
