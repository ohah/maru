//! browser — `maru browser` CLI 클라이언트(L2 순수, §9.6). `browser.*`(navigate/getUrl/executeScript/getCookies)를
//! 에이전트가 쓸 CLI로 노출한다. 1d `sessions` CLI(cli/sessions.zig)와 **동형**: 여기는 인자 파싱 + 요청 바이트
//! 조립(`buildRequestBytes`, 1a `serializeMessage` 재사용) + 응답 렌더(`renderResponse`, 1a `parseMessage` 재사용)만
//! 하고, 소켓 발견·connect·`auth.self`·프레임 왕복은 [`cli/control_client.zig`](control_client.zig)가,
//! 그 위의 응답 수신 상태 기계(chunk 재조립·`--out` 원자 공개)는 [`cli/browser/run.zig`](browser/run.zig)가 한다.
//!
//! **auth·grant(§9.2 Model B)**: CLI는 `auth.self`(selector=`MARU_PANE_ID`·cap_nonce=null)만 보낸다 — browser 요청은
//! 세션 cap이 없어 needs_grant→서버 held→**확인 모달**. 러너의 read는 사용자가 모달을 클릭할 때까지 블록(승인=응답
//! 렌더·거부=`Unauthorized`·무응답 timeout=EOF). 대상 `--surface N`은 필수(에이전트는 `maru sessions list`로 web
//! surface_id 발견). 확장(screenshot·act·set/delete)은 서브커맨드 dispatch에 한 줄씩.
//!
//! **L2 순수**: std + control_plane(1a)만. 소켓/OS 0(파싱·wire만 — I/O는 `cli/control_client.zig`·`cli/browser/run.zig`).

const std = @import("std");
const cp = @import("../session/control_plane.zig");

/// `maru browser --help`. 구현된 서브커맨드만 노출한다(§11 help gate — 정직성). 대상 surface는 `maru sessions list`로 발견.
pub const browser_help =
    \\usage: maru browser <command> [--surface <id>] [args]
    \\
    \\Specify --surface only once per invocation (repeated IDs are also rejected).
    \\Control a web surface (browser panel). First discover the target web surface_id with
    \\`maru browser list`, then pass it to the other commands as --surface <id>. Without a
    \\capability the request opens a confirmation dialog; allowing it runs the command (§9.2 Model B).
    \\
    \\commands:
    \\  list                                   list open web panels (id, url, title, engine — for discovery)
    \\  navigate    --surface <id> <url>       navigate to URL (Chromium tabs: http, https or about:blank; waits for the first load)
    \\  get-url     --surface <id>             print the current document URL
    \\  exec        --surface <id> [--args json-array] [--max-result-bytes n] [--out f] <expression>   run and await a JavaScript expression
    \\  get-cookies --surface <id>             print cookies for the current document host as JSON
    \\  set-cookie  --surface <id> --name n --value v [--domain d] [--path p] [--secure]   set a cookie
    \\  delete-cookie --surface <id> --name n [--domain d] [--path p]                      delete a cookie
    \\  get-local-storage    --surface <id> --key k             print a localStorage value
    \\  set-local-storage    --surface <id> --key k --value v   set a localStorage value
    \\  remove-local-storage --surface <id> --key k             remove a localStorage entry
    \\  clear-storage        --surface <id>                     clear the target origin's storage and its host's cookies
    \\  click   --surface <id> (--selector <css> | --ref <ref>)         click an element (by selector or snapshot ref; real mouse input on Chromium tabs)
    \\  type    --surface <id> (--selector <css> | --ref <ref>) --text <t>  type text into an element (replaces its text; real input on Chromium tabs)
    \\  scroll  --surface <id> (--selector <css> | --ref <ref>)         scroll an element into view
    \\  (click/type/scroll/hover/press also take --role <role> [--name <n>] [--level <n>], --by-text <t> or --by-label <t>, with [--exact] [--nth <n>], instead of --selector/--ref; Chromium tabs)
    \\  wait    --surface <id> (--selector <css> | --load) [--timeout <ms>]   wait for a condition (default and max 25000ms)
    \\  (wait also takes --role <role> [--name <n>] [--level <n>], --by-text <t> or --by-label <t>, with [--exact] [--nth <n>] [--visible]: wait until it is visible; Chromium tabs)
    \\  snapshot --surface <id> [--interactive] [--max-depth <n>] [--selector <css>]   print the page ARIA tree (role/name/ref)
    \\  console --surface <id> [--clear]                        print page console logs (level, text); --clear empties after reading
    \\  screenshot  --surface <id> [--out f] [--rect x,y,w,h] [--scale s]   capture PNG of the visible view (--rect region in view coordinates, --scale factor; omit for the whole view at device scale)
    \\  back    --surface <id>                     go back in the tab's history (Chromium tabs; "not ok" when there is nothing to go back to)
    \\  forward --surface <id>                     go forward in the tab's history (Chromium tabs)
    \\  reload  --surface <id>                     reload the page (Chromium tabs)
    \\  hover   --surface <id> (--selector <css> | --ref <ref>)         move the pointer onto an element (real input; Chromium tabs)
    \\  press   --surface <id> --key <keys> [--selector <css> | --ref <ref>]   press a key like Enter, Shift+Tab or Meta+a (real input; on the element, or where the focus is; Chromium tabs)
    \\  open    [--url <url>] [--timeout <ms>]     open a tab behind the current one in this pane and print its id (waits for the first load; Chromium; from a maru pane)
    \\  close   --surface <id>                     close a tab this pane opened (asks the page; "not closed" if it asks before leaving)
    \\  repl    [--surface <id>]                   read one command per line; `use <id>` (or `open`) picks the tab so --surface can be left out
    \\
;

// ── 명령 모델 ─────────────────────────────────────────────────────────────────────────────────────────────

/// `browser.*` 요청(핵심 4개). id는 대상 web surface_id.
pub const ExecCmd = struct {
    surface_id: u64,
    script: []const u8,
    args_json: ?[]const u8 = null,
    max_result_bytes: usize = 16 * 1024 * 1024,
    out: ?[]const u8 = null,
};

pub const Request = union(enum) {
    /// `browser list`(§9.6 발견) — **surface_id 불요**(인스턴스의 web surface 전부 나열). ungated 발견(제어는 별도 모달).
    /// 다른 서브커맨드가 `--surface`로 대상을 지정하는 것과 달리 대상이 없다(에이전트가 이걸로 대상 id를 발견).
    list,
    navigate: struct { surface_id: u64, url: []const u8 },
    get_url: struct { surface_id: u64 },
    exec: ExecCmd,
    get_cookies: struct { surface_id: u64 },
    /// `browser set-cookie`(§9.4 D4 write). name/value 필수, domain/path/secure 선택. 응답 {ok}.
    set_cookie: struct { surface_id: u64, name: []const u8, value: []const u8, domain: ?[]const u8, path: ?[]const u8, secure: bool },
    /// `browser delete-cookie`(§9.4 D4 write). name 필수, domain/path 선택. 응답 {ok}.
    delete_cookie: struct { surface_id: u64, name: []const u8, domain: ?[]const u8, path: ?[]const u8 },
    /// `browser get-local-storage`(§9.4 D4). key 필수. 응답 {value}.
    get_local_storage: struct { surface_id: u64, key: []const u8 },
    /// `browser set-local-storage`(§9.4 D4). key/value 필수. 응답 {ok}.
    set_local_storage: struct { surface_id: u64, key: []const u8, value: []const u8 },
    /// `browser remove-local-storage`(§9.4 D4). key 필수. 응답 {ok}.
    remove_local_storage: struct { surface_id: u64, key: []const u8 },
    /// `browser clear-storage`(§9.4 D4). surface만. 대상 origin 쿠키+스토리지 삭제. 응답 {ok}.
    clear_storage: struct { surface_id: u64 },
    /// `browser back`·`forward`·`reload`(W9b① — Chromium 탭). surface만. 응답 {ok}(back·forward 는 갈 곳이 없으면 false).
    back: struct { surface_id: u64 },
    forward: struct { surface_id: u64 },
    reload: struct { surface_id: u64 },
    /// `browser hover`·`press`(W9b①b-2 — Chromium 탭). hover 는 locator 필수, press 는 key 필수·locator 는 없어도 된다(지금 초점).
    hover: struct { surface_id: u64, locator: Locator },
    press: struct { surface_id: u64, key: []const u8, locator: ?Locator },
    /// `browser click`(act 5f-2·snapshot-2). locator=--selector 또는 --ref 하나. 응답 {ok}(요소 발견+클릭).
    click: struct { surface_id: u64, locator: Locator },
    /// `browser type`(act 5f-2·snapshot-2). locator + text 필수. 응답 {ok}.
    type_text: struct { surface_id: u64, locator: Locator, text: []const u8 },
    /// `browser scroll`(act 5f-2·snapshot-2). locator 필수(scrollIntoView). 응답 {ok}.
    scroll: struct { surface_id: u64, locator: Locator },
    /// `browser wait`: visible selector 또는 현재 load idle까지 polling. timeout은 1..25_000ms. 응답 {ok}.
    wait: struct { surface_id: u64, condition: WaitCondition, selector: ?[]const u8, timeout_ms: u32, locator: ?Locator = null },
    /// `browser snapshot`(§9.5.4): 페이지 ARIA 트리(role/name/ref). interactive_only/max_depth/selector 선택. 응답 {snapshot}.
    snapshot: struct { surface_id: u64, interactive_only: bool, max_depth: ?u32, selector: ?[]const u8 },
    /// `browser console`(§9.5.9): 서버 버퍼에 쌓인 콘솔을 회수. clear=반환 후 버퍼 비움. 응답 {console:[{level,text}]}.
    console: struct { surface_id: u64, clear: bool },
    /// `browser open`(W9b③ — Chromium). 대상 탭이 없다 — 부른 pane 의 탭 줄 끝에 뒤쪽 탭으로 연다. 응답 {id, url, loaded}.
    open: struct { url: ?[]const u8, timeout_ms: ?u32 },
    /// `browser close`(W9b③ — 그 pane 이 연 탭만). 응답 {closed, reason?}.
    close: struct { surface_id: u64 },

    /// 응답 렌더용 종류(어느 result 모양인지). renderResponse가 소비.
    pub fn kind(self: Request) ResponseKind {
        return switch (self) {
            .list => .list,
            .navigate => .navigate,
            .get_url => .get_url,
            .exec => .exec,
            .get_cookies => .get_cookies,
            .set_cookie, .delete_cookie, .set_local_storage, .remove_local_storage, .clear_storage, .click, .type_text, .scroll, .wait, .back, .forward, .reload, .hover, .press => .ok,
            .get_local_storage => .value,
            .snapshot => .snapshot,
            .console => .console,
            .open => .open,
            .close => .close,
        };
    }
};

pub const WaitCondition = enum {
    selector,
    load,
    /// 로케이터가 보일 때까지(W9b②-3 — Chromium 탭).
    visible,

    fn wire(self: WaitCondition) []const u8 {
        return switch (self) {
            .selector => "selector",
            .load => "load",
            .visible => "visible",
        };
    }
};

/// act(click/type/scroll) 대상 지시자 — `--selector <css>` 또는 `--ref <e#>`(§9.5.4 snapshot) 중 정확히 하나.
/// ref는 snapshot이 매긴 불투명 토큰이라 CLI는 값을 그대로 wire에 실을 뿐 해석하지 않는다. parse가 배타성을 강제한다.
pub const Locator = union(enum) {
    selector: []const u8,
    ref: []const u8,
    /// W9b② — `--role <role> [--name <n>] [--level <n>] [--exact] [--nth <n>]`(Chromium 탭).
    role: RoleLocator,
    /// W9b②-2 — `--by-text <t>`·`--by-label <t>` [`--exact`] [`--nth <n>`](Chromium 탭).
    text: TextLocator,
    label: TextLocator,
};

pub const TextLocator = struct { value: []const u8, exact: bool = false, nth: ?u32 = null };

pub const RoleLocator = struct { role: []const u8, name: ?[]const u8 = null, level: ?u32 = null, exact: bool = false, nth: ?u32 = null };

pub const wait_default_timeout_ms: u32 = 25_000;
pub const wait_max_timeout_ms: u32 = 25_000;

/// screenshot(5f-1)은 단일 응답이 아니라 **chunk 스트림**(§9.5.7)이라 단일-응답 `Request`와 분리한다 — main이
/// `ScreenshotStreamValidator`로 chunk를 검증·decode해 PNG를 `out`(nil=stdout)에 쓴다. surface_id=대상 web surface. named 타입이라
/// 러너(`cli/browser/run.zig`) 핸들러 인자로 그대로 전달된다(익명 struct는 별개 타입이 되어 안 맞음).
pub const ScreenshotCmd = struct {
    surface_id: u64,
    out: ?[]const u8,
    /// 선택 캡처 영역 `[x, y, width, height]`(CSS 포인트, §9.5.7). null=전체 가시 뷰포트.
    rect: ?[4]f64 = null,
    /// 선택 출력 배율(>0). null=기기 배율.
    scale: ?f64 = null,
};

pub const Command = union(enum) {
    request: Request,
    screenshot: ScreenshotCmd,
    help,
    /// `browser repl [--surface <id>]`(W9f) — 줄마다 하위 명령을 읽어 돌린다. 고른 탭(`use <id>`·`open`)은 `--surface` 를 생략한다.
    repl: struct { surface: ?u64 },
};

/// 파싱 실패. main이 usage/에러 메시지를 stderr에 낸다(sessions.ParseError와 동형 규율).
pub const ParseError = error{
    MissingSubcommand, // `maru browser`에 서브커맨드 없음
    UnknownSubcommand, // 알 수 없는 서브커맨드(`browser foo`)
    MissingSurface, // `--surface` 미제공(모든 서브커맨드 필수)
    InvalidSurface, // surface 값이 비숫자/음수/범위밖
    DuplicateSurface, // one invocation may select its target only once
    MissingSurfaceValue, // `--surface`에 값 없음
    MissingUrl, // `navigate`에 url 없음
    MissingScript, // `exec`에 script 없음
    MissingArgsValue,
    InvalidArgs,
    ArgsTooDeep, // `exec --args` 가 서버 계약(배열 안쪽 128 단)보다 깊다
    MissingMaxResultBytesValue,
    InvalidMaxResultBytes,
    MissingOutValue, // `screenshot --out`에 값 없음
    MissingRectValue, // `screenshot --rect`에 값 없음
    MissingScaleValue, // `screenshot --scale`에 값 없음
    InvalidRect, // `--rect`가 `x,y,w,h`(4개 수치, w/h>0) 형식 아님
    InvalidScale, // `--scale`이 양수 수치 아님
    MissingName, // `set-cookie`/`delete-cookie`에 `--name` 없음
    MissingKey, // `*-local-storage`에 `--key` 없음
    MissingSelector, // `wait --selector`에 값 없음(selector 조건)
    MissingLocator, // act 에 대상(`--selector`·`--ref`·`--role`·`--by-text`·`--by-label`)이 없음
    ConflictingLocator, // act 에 대상이 둘 이상
    MissingWaitCondition, // `wait`에 `--selector` 또는 `--load` 없음
    ConflictingWaitCondition, // `wait` 조건을 둘 이상 지정
    MissingTimeoutValue, // `wait --timeout`에 값 없음
    InvalidTimeout, // timeout이 1..25_000 정수가 아님
    MissingText, // `type`에 `--text` 없음
    LocatorOptionWithoutRole, // `--name`·`--level`·`--exact`·`--nth` 를 `--role` 없이
    ExactWithoutName, // `--exact` 를 `--name` 없이
    InvalidLocatorNumber, // `--level`(1..100)·`--nth`(0 이상)가 수가 아님
    MissingPressKey, // `press`에 `--key` 없음
    MissingValue, // `set-cookie`/`set-local-storage`에 `--value` 없음
    MissingOptionValue, // `--name`/`--value`/`--domain`/`--path`/`--selector`에 값 없음
    MissingMaxDepthValue, // `snapshot --max-depth`에 값 없음
    InvalidMaxDepth, // `--max-depth`가 비음수 정수(u32)가 아님
    UnknownOption, // 알 수 없는 옵션(`--bogus`)
    UnexpectedArgument, // 남는 위치 인자
};

/// 표시해도 안전한 글만 `out` 에 — C0·DEL·C1 제어 문자, 양방향 제어 글자, 줄·문단 구분, interlinear, tag 글자를 뺀다(서버가 보낸 페이지
/// 글을 터미널에 찍을 때). 쓴 바이트 수. `web_cdp_locate.displaySafe` 와 같다(둘을 함께 고친다).
/// 터미널에 그대로 내면 안 되는 코드 포인트(제어·양방향·줄 구분·태그 — 페이지 글이 화면을 속이지 못하게).
fn displayUnsafe(code: u21) bool {
    return code < 0x20 or (code >= 0x7f and code <= 0x9f) or code == 0x061C or code == 0x200E or code == 0x200F or
        (code >= 0x202A and code <= 0x202E) or (code >= 0x2066 and code <= 0x2069) or code == 0x2028 or code == 0x2029 or
        (code >= 0xFFF9 and code <= 0xFFFB) or (code >= 0xE0000 and code <= 0xE007F);
}

/// JSON 값을 한 줄로 — 문자열의 `displayUnsafe` 글자는 `\uXXXX` 로 쓴다(값은 그대로, 터미널엔 보이지 않는 글자가 가지 않는다 — W9a③ 적대
/// 리뷰 8 회차: get-cookies 가 페이지가 정한 C1 CSI·RLO 를 그대로 냈다). 깨진 UTF-8 바이트는 U+FFFD.
fn writeDisplaySafeJson(w: *std.Io.Writer, value: std.json.Value) std.Io.Writer.Error!void {
    switch (value) {
        .string => |str| {
            try w.writeByte('"');
            var i: usize = 0;
            while (i < str.len) {
                const len = std.unicode.utf8ByteSequenceLength(str[i]) catch 1;
                const code: u21 = if (i + len <= str.len) std.unicode.utf8Decode(str[i .. i + len]) catch 0xFFFD else 0xFFFD;
                const n = if (i + len <= str.len) len else str.len - i;
                if (code == '"' or code == '\\') {
                    try w.writeByte('\\');
                    try w.writeByte(@intCast(code));
                } else if (displayUnsafe(code)) {
                    if (code > 0xFFFF) {
                        const v = code - 0x10000;
                        try w.print("\\u{x:0>4}\\u{x:0>4}", .{ 0xD800 + (v >> 10), 0xDC00 + (v & 0x3FF) });
                    } else try w.print("\\u{x:0>4}", .{code});
                } else if (code == 0xFFFD and !(n == 3 and std.mem.eql(u8, str[i .. i + 3], "\xef\xbf\xbd"))) {
                    try w.writeAll("\xef\xbf\xbd");
                } else try w.writeAll(str[i .. i + n]);
                i += n;
            }
            try w.writeByte('"');
        },
        .array => |a| {
            try w.writeByte('[');
            for (a.items, 0..) |item, k| {
                if (k > 0) try w.writeByte(',');
                try writeDisplaySafeJson(w, item);
            }
            try w.writeByte(']');
        },
        .object => |o| {
            try w.writeByte('{');
            var it = o.iterator();
            var first = true;
            while (it.next()) |e| {
                if (!first) try w.writeByte(',');
                first = false;
                try writeDisplaySafeJson(w, .{ .string = e.key_ptr.* });
                try w.writeByte(':');
                try writeDisplaySafeJson(w, e.value_ptr.*);
            }
            try w.writeByte('}');
        },
        else => {
            var s: std.json.Stringify = .{ .writer = w, .options = .{} };
            s.write(value) catch return error.WriteFailed;
        },
    }
}

/// 이미 유효한 JSON 글(exec 결과)의 `displayUnsafe` 글자(U+007F 이상 — 그 아래 제어 글자는 JSON 문자열 안에 그대로 올 수 없다)를 `\uXXXX` 로 —
/// 값은 그대로, 터미널엔 보이지 않는 글자가 가지 않는다(W9a③ 적대 리뷰 9 회차: exec 가 페이지가 정한 C1 CSI·RLO 를 그대로 냈다). 그런 글자는
/// 유효한 JSON 에서 문자열 안에만 올 수 있어 바꿔도 JSON 이다.
pub fn writeDisplaySafeJsonText(w: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        if (len == 1 or i + len > text.len) {
            try w.writeByte(text[i]);
            i += 1;
            continue;
        }
        const code = std.unicode.utf8Decode(text[i .. i + len]) catch {
            try w.writeAll(text[i .. i + len]);
            i += len;
            continue;
        };
        if (code >= 0x7f and displayUnsafe(code)) {
            if (code > 0xFFFF) {
                const v = code - 0x10000;
                try w.print("\\u{x:0>4}\\u{x:0>4}", .{ 0xD800 + (v >> 10), 0xDC00 + (v & 0x3FF) });
            } else try w.print("\\u{x:0>4}", .{code});
        } else try w.writeAll(text[i .. i + len]);
        i += len;
    }
}

fn displaySafe(s: []const u8, out: []u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch {
            i += 1;
            continue;
        };
        if (i + len > s.len) break;
        const code = std.unicode.utf8Decode(s[i .. i + len]) catch {
            i += len;
            continue;
        };
        if (!displayUnsafe(code) and n + len <= out.len) {
            @memcpy(out[n .. n + len], s[i .. i + len]);
            n += len;
        }
        i += len;
    }
    return n;
}

// ══ 파서 ═══════════════════════════════════════════════════════════════════════════════════════════════════

/// `maru browser` 뒤 인자를 파싱한다. `--help`/`-h` 있으면 `.help`.
pub fn parse(args: []const []const u8) ParseError!Command {
    if (hasHelpFlag(args)) return .help;
    if (args.len == 0) return error.MissingSubcommand;
    const sub = args[0];
    const rest = args[1..];
    if (eq(sub, "repl")) {
        const p = try parseSurfaceArg(rest);
        if (p.arg != null) return error.UnexpectedArgument;
        return .{ .repl = .{ .surface = p.surface } };
    }
    if (eq(sub, "list")) {
        // 발견 — 대상 surface 불요(전부 나열). 남는 인자(옵션/위치)는 에러(오타 방지).
        if (rest.len != 0) {
            if (std.mem.startsWith(u8, rest[0], "-")) return error.UnknownOption;
            return error.UnexpectedArgument;
        }
        return .{ .request = .list };
    }
    if (eq(sub, "open")) {
        // W9b③: 대상 탭이 없다(부른 pane) — `--surface` 는 받지 않는다.
        var url: ?[]const u8 = null;
        var timeout_ms: ?u32 = null;
        var i: usize = 0;
        while (i < rest.len) {
            const a = rest[i];
            if (matchOpt(a, "--url")) {
                url = optValue(rest, &i, "--url") catch |err| switch (err) {
                    error.MissingOptionValue => return error.MissingUrl,
                    else => return err,
                };
            } else if (matchOpt(a, "--timeout")) {
                const value = optValue(rest, &i, "--timeout") catch |err| switch (err) {
                    error.MissingOptionValue => return error.MissingTimeoutValue,
                    else => return err,
                };
                const t = std.fmt.parseInt(u32, value, 10) catch return error.InvalidTimeout;
                if (t == 0 or t > wait_max_timeout_ms) return error.InvalidTimeout;
                timeout_ms = t;
            } else if (std.mem.startsWith(u8, a, "-")) {
                return error.UnknownOption;
            } else return error.UnexpectedArgument;
        }
        return .{ .request = .{ .open = .{ .url = url, .timeout_ms = timeout_ms } } };
    }
    if (eq(sub, "close")) {
        const p = try parseSurfaceArg(rest);
        const s = p.surface orelse return error.MissingSurface;
        if (p.arg != null) return error.UnexpectedArgument;
        return .{ .request = .{ .close = .{ .surface_id = s } } };
    }
    if (eq(sub, "navigate")) {
        const p = try parseSurfaceArg(rest);
        const s = p.surface orelse return error.MissingSurface;
        const url = p.arg orelse return error.MissingUrl;
        return .{ .request = .{ .navigate = .{ .surface_id = s, .url = url } } };
    }
    if (eq(sub, "get-url")) {
        const p = try parseSurfaceArg(rest);
        const s = p.surface orelse return error.MissingSurface;
        if (p.arg != null) return error.UnexpectedArgument;
        return .{ .request = .{ .get_url = .{ .surface_id = s } } };
    }
    if (eq(sub, "exec")) {
        return .{ .request = .{ .exec = try parseExecArgs(rest) } };
    }
    if (eq(sub, "get-cookies")) {
        const p = try parseSurfaceArg(rest);
        const s = p.surface orelse return error.MissingSurface;
        if (p.arg != null) return error.UnexpectedArgument;
        return .{ .request = .{ .get_cookies = .{ .surface_id = s } } };
    }
    if (eq(sub, "set-cookie")) {
        const ca = try parseCookieArgs(rest);
        const s = ca.surface orelse return error.MissingSurface;
        const name = ca.name orelse return error.MissingName;
        const value = ca.value orelse return error.MissingValue;
        return .{ .request = .{ .set_cookie = .{ .surface_id = s, .name = name, .value = value, .domain = ca.domain, .path = ca.path, .secure = ca.secure } } };
    }
    if (eq(sub, "delete-cookie")) {
        const ca = try parseCookieArgs(rest);
        const s = ca.surface orelse return error.MissingSurface;
        const name = ca.name orelse return error.MissingName;
        // --value/--secure는 delete엔 무의미 — 관대하게 무시(파서가 받아도 안 씀).
        return .{ .request = .{ .delete_cookie = .{ .surface_id = s, .name = name, .domain = ca.domain, .path = ca.path } } };
    }
    if (eq(sub, "get-local-storage")) {
        const ca = try parseCookieArgs(rest);
        const s = ca.surface orelse return error.MissingSurface;
        const key = ca.key orelse return error.MissingKey;
        return .{ .request = .{ .get_local_storage = .{ .surface_id = s, .key = key } } };
    }
    if (eq(sub, "set-local-storage")) {
        const ca = try parseCookieArgs(rest);
        const s = ca.surface orelse return error.MissingSurface;
        const key = ca.key orelse return error.MissingKey;
        const value = ca.value orelse return error.MissingValue;
        return .{ .request = .{ .set_local_storage = .{ .surface_id = s, .key = key, .value = value } } };
    }
    if (eq(sub, "remove-local-storage")) {
        const ca = try parseCookieArgs(rest);
        const s = ca.surface orelse return error.MissingSurface;
        const key = ca.key orelse return error.MissingKey;
        return .{ .request = .{ .remove_local_storage = .{ .surface_id = s, .key = key } } };
    }
    if (eq(sub, "clear-storage")) {
        const p = try parseSurfaceArg(rest);
        const s = p.surface orelse return error.MissingSurface;
        if (p.arg != null) return error.UnexpectedArgument;
        return .{ .request = .{ .clear_storage = .{ .surface_id = s } } };
    }
    if (eq(sub, "back") or eq(sub, "forward") or eq(sub, "reload")) {
        const p = try parseSurfaceArg(rest);
        const s = p.surface orelse return error.MissingSurface;
        if (p.arg != null) return error.UnexpectedArgument;
        return .{ .request = if (eq(sub, "back")) .{ .back = .{ .surface_id = s } } else if (eq(sub, "forward")) .{ .forward = .{ .surface_id = s } } else .{ .reload = .{ .surface_id = s } } };
    }
    if (eq(sub, "hover")) {
        const aa = try parseActArgs(rest, .{});
        const s = aa.surface orelse return error.MissingSurface;
        return .{ .request = .{ .hover = .{ .surface_id = s, .locator = try actLocator(aa) } } };
    }
    if (eq(sub, "press")) {
        const aa = try parseActArgs(rest, .{ .key = true });
        const s = aa.surface orelse return error.MissingSurface;
        const key = aa.key orelse return error.MissingPressKey;
        const loc: ?Locator = if (aa.selector == null and aa.ref == null and aa.role == null and aa.by_text == null and aa.by_label == null and !aa.hasRoleOptions() and !aa.hasMatchOptions()) null else try actLocator(aa);
        return .{ .request = .{ .press = .{ .surface_id = s, .key = key, .locator = loc } } };
    }
    if (eq(sub, "click")) {
        const aa = try parseActArgs(rest, .{});
        const s = aa.surface orelse return error.MissingSurface;
        return .{ .request = .{ .click = .{ .surface_id = s, .locator = try actLocator(aa) } } };
    }
    if (eq(sub, "type")) {
        const aa = try parseActArgs(rest, .{ .text = true });
        const s = aa.surface orelse return error.MissingSurface;
        const loc = try actLocator(aa);
        const text = aa.text orelse return error.MissingText;
        return .{ .request = .{ .type_text = .{ .surface_id = s, .locator = loc, .text = text } } };
    }
    if (eq(sub, "scroll")) {
        const aa = try parseActArgs(rest, .{});
        const s = aa.surface orelse return error.MissingSurface;
        return .{ .request = .{ .scroll = .{ .surface_id = s, .locator = try actLocator(aa) } } };
    }
    if (eq(sub, "wait")) {
        const wa = try parseWaitArgs(rest);
        const s = wa.surface orelse return error.MissingSurface;
        // 로케이터(role·text·label)면 visible(W9b②-3). `--selector` 는 `--visible` 이 있어도 selector 조건으로 보낸다(같은 뜻 — 옛 앱도 안다).
        const has_locator = wa.loc.role != null or wa.loc.by_text != null or wa.loc.by_label != null;
        if (wa.condition == .load and (has_locator or wa.visible)) return error.ConflictingWaitCondition;
        if (has_locator or wa.loc.hasRoleOptions() or wa.loc.hasMatchOptions()) {
            var la = wa.loc;
            la.selector = wa.selector;
            const loc = try actLocator(la);
            if (loc == .selector) return error.LocatorOptionWithoutRole; // 위의 has_locator 가 거짓 — 로케이터 옵션만 왔다
            return .{ .request = .{ .wait = .{ .surface_id = s, .condition = .visible, .selector = null, .timeout_ms = wa.timeout_ms, .locator = loc } } };
        }
        const condition = wa.condition orelse return error.MissingWaitCondition;
        if (condition == .selector and (wa.selector == null or wa.selector.?.len == 0)) return error.MissingSelector;
        return .{ .request = .{ .wait = .{
            .surface_id = s,
            .condition = condition,
            .selector = wa.selector,
            .timeout_ms = wa.timeout_ms,
        } } };
    }
    if (eq(sub, "screenshot")) {
        // screenshot은 위치 인자 없음 — `--surface <id>` + 선택 `--out <file>`/`--rect x,y,w,h`/`--scale f`(생략=stdout·전체 뷰·기기 배율).
        var surface: ?u64 = null;
        var out: ?[]const u8 = null;
        var rect: ?[4]f64 = null;
        var scale: ?f64 = null;
        var i: usize = 1;
        while (i < args.len) {
            const a = args[i];
            if (eq(a, "--surface")) {
                if (i + 1 >= args.len) return error.MissingSurfaceValue;
                try assignSurface(&surface, args[i + 1]);
                i += 2;
            } else if (std.mem.startsWith(u8, a, "--surface=")) {
                try assignSurface(&surface, a["--surface=".len..]);
                i += 1;
            } else if (eq(a, "--out")) {
                if (i + 1 >= args.len) return error.MissingOutValue;
                out = args[i + 1];
                i += 2;
            } else if (std.mem.startsWith(u8, a, "--out=")) {
                out = a["--out=".len..];
                i += 1;
            } else if (eq(a, "--rect")) {
                if (i + 1 >= args.len) return error.MissingRectValue;
                rect = parseRect(args[i + 1]) catch return error.InvalidRect;
                i += 2;
            } else if (std.mem.startsWith(u8, a, "--rect=")) {
                rect = parseRect(a["--rect=".len..]) catch return error.InvalidRect;
                i += 1;
            } else if (eq(a, "--scale")) {
                if (i + 1 >= args.len) return error.MissingScaleValue;
                scale = parseScale(args[i + 1]) catch return error.InvalidScale;
                i += 2;
            } else if (std.mem.startsWith(u8, a, "--scale=")) {
                scale = parseScale(a["--scale=".len..]) catch return error.InvalidScale;
                i += 1;
            } else if (std.mem.startsWith(u8, a, "-")) {
                return error.UnknownOption;
            } else {
                return error.UnexpectedArgument; // screenshot은 위치 인자 없음
            }
        }
        const s = surface orelse return error.MissingSurface;
        return .{ .screenshot = .{ .surface_id = s, .out = out, .rect = rect, .scale = scale } };
    }
    if (eq(sub, "snapshot")) {
        // `--surface <id>` + 선택 `--interactive`(상호작용 role만 flag)·`--max-depth <n>`·`--selector <css>`(하위트리 scope).
        var surface: ?u64 = null;
        var interactive = false;
        var max_depth: ?u32 = null;
        var selector: ?[]const u8 = null;
        var i: usize = 1;
        while (i < args.len) {
            const a = args[i];
            if (eq(a, "--surface")) {
                if (i + 1 >= args.len) return error.MissingSurfaceValue;
                try assignSurface(&surface, args[i + 1]);
                i += 2;
            } else if (std.mem.startsWith(u8, a, "--surface=")) {
                try assignSurface(&surface, a["--surface=".len..]);
                i += 1;
            } else if (eq(a, "--interactive")) {
                interactive = true;
                i += 1;
            } else if (eq(a, "--max-depth")) {
                if (i + 1 >= args.len) return error.MissingMaxDepthValue;
                max_depth = std.fmt.parseInt(u32, args[i + 1], 10) catch return error.InvalidMaxDepth;
                i += 2;
            } else if (std.mem.startsWith(u8, a, "--max-depth=")) {
                max_depth = std.fmt.parseInt(u32, a["--max-depth=".len..], 10) catch return error.InvalidMaxDepth;
                i += 1;
            } else if (eq(a, "--selector")) {
                if (i + 1 >= args.len) return error.MissingOptionValue;
                selector = args[i + 1];
                i += 2;
            } else if (std.mem.startsWith(u8, a, "--selector=")) {
                selector = a["--selector=".len..];
                i += 1;
            } else if (std.mem.startsWith(u8, a, "-")) {
                return error.UnknownOption;
            } else {
                return error.UnexpectedArgument;
            }
        }
        const s = surface orelse return error.MissingSurface;
        return .{ .request = .{ .snapshot = .{ .surface_id = s, .interactive_only = interactive, .max_depth = max_depth, .selector = selector } } };
    }
    if (eq(sub, "console")) {
        // `--surface <id>` + 선택 `--clear`(반환 후 서버 버퍼 비움 flag, §9.5.9).
        var surface: ?u64 = null;
        var clear = false;
        var i: usize = 1;
        while (i < args.len) {
            const a = args[i];
            if (eq(a, "--surface")) {
                if (i + 1 >= args.len) return error.MissingSurfaceValue;
                try assignSurface(&surface, args[i + 1]);
                i += 2;
            } else if (std.mem.startsWith(u8, a, "--surface=")) {
                try assignSurface(&surface, a["--surface=".len..]);
                i += 1;
            } else if (eq(a, "--clear")) {
                clear = true;
                i += 1;
            } else if (std.mem.startsWith(u8, a, "-")) {
                return error.UnknownOption;
            } else {
                return error.UnexpectedArgument;
            }
        }
        const s = surface orelse return error.MissingSurface;
        return .{ .request = .{ .console = .{ .surface_id = s, .clear = clear } } };
    }
    return error.UnknownSubcommand;
}

fn parseExecArgs(rest: []const []const u8) ParseError!ExecCmd {
    var surface: ?u64 = null;
    var script: ?[]const u8 = null;
    var args_json: ?[]const u8 = null;
    var max_result_bytes: usize = 16 * 1024 * 1024;
    var out: ?[]const u8 = null;
    var i: usize = 0;
    while (i < rest.len) {
        const arg = rest[i];
        if (eq(arg, "--surface")) {
            if (i + 1 >= rest.len) return error.MissingSurfaceValue;
            try assignSurface(&surface, rest[i + 1]);
            i += 2;
        } else if (std.mem.startsWith(u8, arg, "--surface=")) {
            try assignSurface(&surface, arg["--surface=".len..]);
            i += 1;
        } else if (eq(arg, "--args")) {
            if (i + 1 >= rest.len) return error.MissingArgsValue;
            args_json = rest[i + 1];
            i += 2;
        } else if (std.mem.startsWith(u8, arg, "--args=")) {
            args_json = arg["--args=".len..];
            if (args_json.?.len == 0) return error.MissingArgsValue;
            i += 1;
        } else if (eq(arg, "--max-result-bytes")) {
            if (i + 1 >= rest.len) return error.MissingMaxResultBytesValue;
            max_result_bytes = std.fmt.parseInt(usize, rest[i + 1], 10) catch return error.InvalidMaxResultBytes;
            if (max_result_bytes == 0 or max_result_bytes > 16 * 1024 * 1024) return error.InvalidMaxResultBytes;
            i += 2;
        } else if (std.mem.startsWith(u8, arg, "--max-result-bytes=")) {
            max_result_bytes = std.fmt.parseInt(usize, arg["--max-result-bytes=".len..], 10) catch return error.InvalidMaxResultBytes;
            if (max_result_bytes == 0 or max_result_bytes > 16 * 1024 * 1024) return error.InvalidMaxResultBytes;
            i += 1;
        } else if (eq(arg, "--out")) {
            if (i + 1 >= rest.len) return error.MissingOutValue;
            out = rest[i + 1];
            i += 2;
        } else if (std.mem.startsWith(u8, arg, "--out=")) {
            out = arg["--out=".len..];
            i += 1;
        } else if (eq(arg, "--")) {
            // 그 뒤 하나는 `-` 로 시작해도 식이다(W9f).
            if (script != null or rest.len != i + 2) return if (rest.len == i + 1) error.MissingScript else error.UnexpectedArgument;
            script = rest[i + 1];
            i += 2;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownOption;
        } else {
            if (script != null) return error.UnexpectedArgument;
            script = arg;
            i += 1;
        }
    }
    // 깊게 중첩된 인자는 요청을 만들 때 JSON 쓰개의 중첩 한도(256)를 넘겨 panic 했다(W9f 적대 리뷰 1 회차) — 여기서 거절한다.
    if (args_json) |j| if (argsValueDepth(j) > max_args_depth) return error.ArgsTooDeep;
    return .{
        .surface_id = surface orelse return error.MissingSurface,
        .script = script orelse return error.MissingScript,
        .args_json = args_json,
        .max_result_bytes = max_result_bytes,
        .out = out,
    };
}

const Parsed = struct { surface: ?u64, arg: ?[]const u8 };

/// `--surface <N>`(또는 `--surface=<N>`) + 위치 인자 **최대 1개**(url/script)를 뽑는다. 알 수 없는 `-`옵션·둘째 위치
/// 인자는 에러. sessions.parseListArgs 규율(양형태 옵션, `-`프리픽스=옵션).
fn parseSurfaceArg(rest: []const []const u8) ParseError!Parsed {
    var surface: ?u64 = null;
    var arg: ?[]const u8 = null;
    var i: usize = 0;
    while (i < rest.len) {
        const a = rest[i];
        if (eq(a, "--surface")) {
            if (i + 1 >= rest.len) return error.MissingSurfaceValue;
            try assignSurface(&surface, rest[i + 1]);
            i += 2;
        } else if (std.mem.startsWith(u8, a, "--surface=")) {
            try assignSurface(&surface, a["--surface=".len..]);
            i += 1;
        } else if (eq(a, "--")) {
            // 그 뒤 하나는 `-` 로 시작해도 위치 인자다(W9f).
            if (arg != null or rest.len > i + 2) return error.UnexpectedArgument;
            if (rest.len == i + 2) arg = rest[i + 1];
            i = rest.len;
        } else if (std.mem.startsWith(u8, a, "-")) {
            return error.UnknownOption;
        } else {
            if (arg != null) return error.UnexpectedArgument; // 둘째 위치 인자 금지
            arg = a;
            i += 1;
        }
    }
    return .{ .surface = surface, .arg = arg };
}

const CookieArgs = struct { surface: ?u64, name: ?[]const u8, key: ?[]const u8, value: ?[]const u8, domain: ?[]const u8, path: ?[]const u8, selector: ?[]const u8, ref: ?[]const u8, text: ?[]const u8, secure: bool };

/// act(click/type/scroll)의 locator를 옵션에서 만든다 — `--selector` xor `--ref`(§9.5.4). 둘 다=배타 위반,
/// 둘 다 없음=대상 미지정. ref는 값 검증 없이 그대로(불투명 토큰 — 미발견은 서버가 정직하게 ok:false).
fn locatorFromArgs(ca: CookieArgs) ParseError!Locator {
    if (ca.selector != null and ca.ref != null) return error.ConflictingLocator;
    if (ca.selector) |s| return .{ .selector = s };
    if (ca.ref) |r| return .{ .ref = r };
    return error.MissingLocator;
}

const WaitArgs = struct {
    surface: ?u64 = null,
    condition: ?WaitCondition = null,
    selector: ?[]const u8 = null,
    timeout_ms: u32 = wait_default_timeout_ms,
    /// `--visible`(선택 — 로케이터 옵션이 곧 visible 이다)과 로케이터 옵션(act 와 같은 규칙).
    visible: bool = false,
    loc: ActArgs = .{},
};

fn parseWaitArgs(rest: []const []const u8) ParseError!WaitArgs {
    var r: WaitArgs = .{};
    var i: usize = 0;
    while (i < rest.len) {
        const a = rest[i];
        if (matchOpt(a, "--surface")) {
            const value = optValue(rest, &i, "--surface") catch |err| switch (err) {
                error.MissingOptionValue => return error.MissingSurfaceValue,
                else => return err,
            };
            try assignSurface(&r.surface, value);
        } else if (matchOpt(a, "--selector")) {
            if (r.condition != null) return error.ConflictingWaitCondition;
            const value = try optValue(rest, &i, "--selector");
            if (value.len == 0) return error.MissingSelector;
            r.condition = .selector;
            r.selector = value;
        } else if (eq(a, "--load")) {
            if (r.condition != null) return error.ConflictingWaitCondition;
            r.condition = .load;
            i += 1;
        } else if (eq(a, "--visible")) {
            r.visible = true;
            i += 1;
        } else if (eq(a, "--exact")) {
            r.loc.exact = true;
            i += 1;
        } else if (matchOpt(a, "--role")) {
            r.loc.role = try optValue(rest, &i, "--role");
        } else if (matchOpt(a, "--name")) {
            r.loc.name = try optValue(rest, &i, "--name");
        } else if (matchOpt(a, "--by-text")) {
            r.loc.by_text = try optValue(rest, &i, "--by-text");
        } else if (matchOpt(a, "--by-label")) {
            r.loc.by_label = try optValue(rest, &i, "--by-label");
        } else if (matchOpt(a, "--level")) {
            const v = std.fmt.parseInt(u32, try optValue(rest, &i, "--level"), 10) catch return error.InvalidLocatorNumber;
            if (v < 1 or v > 100) return error.InvalidLocatorNumber;
            r.loc.level = v;
        } else if (matchOpt(a, "--nth")) {
            const v = std.fmt.parseInt(u32, try optValue(rest, &i, "--nth"), 10) catch return error.InvalidLocatorNumber;
            if (v > 1_000_000) return error.InvalidLocatorNumber;
            r.loc.nth = v;
        } else if (matchOpt(a, "--timeout")) {
            const value = optValue(rest, &i, "--timeout") catch |err| switch (err) {
                error.MissingOptionValue => return error.MissingTimeoutValue,
                else => return err,
            };
            const timeout = std.fmt.parseInt(u32, value, 10) catch return error.InvalidTimeout;
            if (timeout == 0 or timeout > wait_max_timeout_ms) return error.InvalidTimeout;
            r.timeout_ms = timeout;
        } else if (std.mem.startsWith(u8, a, "-")) {
            return error.UnknownOption;
        } else {
            return error.UnexpectedArgument;
        }
    }
    return r;
}

/// cookie/localStorage 명령 옵션(`--surface`·`--name`·`--key`·`--value`·`--domain`·`--path`·`--secure`)을 뽑는다. 위치
/// 인자 금지, 알 수 없는 `-`옵션 에러. 각 값 옵션은 `--opt val`·`--opt=val` 양형태. 서브커맨드가 필요 필드만 검사(파서는 공유).
fn parseCookieArgs(rest: []const []const u8) ParseError!CookieArgs {
    var r: CookieArgs = .{ .surface = null, .name = null, .key = null, .value = null, .domain = null, .path = null, .selector = null, .ref = null, .text = null, .secure = false };
    var i: usize = 0;
    while (i < rest.len) {
        const a = rest[i];
        if (eq(a, "--secure")) {
            r.secure = true;
            i += 1;
        } else if (matchOpt(a, "--surface")) {
            try assignSurface(&r.surface, try optValue(rest, &i, "--surface"));
        } else if (matchOpt(a, "--name")) {
            r.name = try optValue(rest, &i, "--name");
        } else if (matchOpt(a, "--key")) {
            r.key = try optValue(rest, &i, "--key");
        } else if (matchOpt(a, "--value")) {
            r.value = try optValue(rest, &i, "--value");
        } else if (matchOpt(a, "--domain")) {
            r.domain = try optValue(rest, &i, "--domain");
        } else if (matchOpt(a, "--path")) {
            r.path = try optValue(rest, &i, "--path");
        } else if (matchOpt(a, "--selector")) {
            r.selector = try optValue(rest, &i, "--selector");
        } else if (matchOpt(a, "--ref")) {
            r.ref = try optValue(rest, &i, "--ref");
        } else if (matchOpt(a, "--text")) {
            r.text = try optValue(rest, &i, "--text");
        } else if (std.mem.startsWith(u8, a, "-")) {
            return error.UnknownOption;
        } else {
            return error.UnexpectedArgument; // cookie/localStorage 명령은 위치 인자 없음
        }
    }
    return r;
}

/// act 명령(click·type·scroll·hover·press)의 옵션 — 다른 명령의 옵션(`--value` 등)은 받지 않는다(예전엔 쿠키 파서를 함께 써서
/// `click --name x` 를 조용히 무시했다 — W9b② 에서 `--name` 이 역할 이름이 됐다).
const ActArgs = struct {
    surface: ?u64 = null,
    selector: ?[]const u8 = null,
    ref: ?[]const u8 = null,
    role: ?[]const u8 = null,
    name: ?[]const u8 = null,
    level: ?u32 = null,
    exact: bool = false,
    nth: ?u32 = null,
    text: ?[]const u8 = null,
    key: ?[]const u8 = null,
    by_text: ?[]const u8 = null,
    by_label: ?[]const u8 = null,

    /// `--role` 하고만 쓰는 옵션.
    fn hasRoleOptions(self: ActArgs) bool {
        return self.name != null or self.level != null;
    }
    /// 로케이터(role·text·label) 셋 모두와 쓰는 옵션.
    fn hasMatchOptions(self: ActArgs) bool {
        return self.exact or self.nth != null;
    }
};
const ActExtras = struct { text: bool = false, key: bool = false };

fn parseActArgs(rest: []const []const u8, extras: ActExtras) ParseError!ActArgs {
    var r: ActArgs = .{};
    var i: usize = 0;
    while (i < rest.len) {
        const a = rest[i];
        if (eq(a, "--exact")) {
            r.exact = true;
            i += 1;
        } else if (matchOpt(a, "--surface")) {
            try assignSurface(&r.surface, try optValue(rest, &i, "--surface"));
        } else if (matchOpt(a, "--selector")) {
            r.selector = try optValue(rest, &i, "--selector");
        } else if (matchOpt(a, "--ref")) {
            r.ref = try optValue(rest, &i, "--ref");
        } else if (matchOpt(a, "--by-text")) {
            r.by_text = try optValue(rest, &i, "--by-text");
        } else if (matchOpt(a, "--by-label")) {
            r.by_label = try optValue(rest, &i, "--by-label");
        } else if (matchOpt(a, "--role")) {
            r.role = try optValue(rest, &i, "--role");
        } else if (matchOpt(a, "--name")) {
            r.name = try optValue(rest, &i, "--name");
        } else if (matchOpt(a, "--level")) {
            const v = std.fmt.parseInt(u32, try optValue(rest, &i, "--level"), 10) catch return error.InvalidLocatorNumber;
            if (v < 1 or v > 100) return error.InvalidLocatorNumber;
            r.level = v;
        } else if (matchOpt(a, "--nth")) {
            r.nth = std.fmt.parseInt(u32, try optValue(rest, &i, "--nth"), 10) catch return error.InvalidLocatorNumber;
            if (r.nth.? > 1_000_000) return error.InvalidLocatorNumber; // 서버(L2)와 같은 범위
        } else if (extras.text and matchOpt(a, "--text")) {
            r.text = try optValue(rest, &i, "--text");
        } else if (extras.key and matchOpt(a, "--key")) {
            r.key = try optValue(rest, &i, "--key");
        } else if (std.mem.startsWith(u8, a, "-")) {
            return error.UnknownOption;
        } else {
            return error.UnexpectedArgument;
        }
    }
    return r;
}

/// act 의 대상 — `--selector`·`--ref`·`--role`·`--by-text`·`--by-label` 가운데 정확히 하나. `--name`·`--level` 은 `--role` 과만,
/// `--exact`·`--nth` 는 로케이터(role 은 `--exact` 에 `--name` 이 있어야)와만.
fn actLocator(aa: ActArgs) ParseError!Locator {
    const given = @as(u8, @intFromBool(aa.selector != null)) + @intFromBool(aa.ref != null) + @intFromBool(aa.role != null) +
        @intFromBool(aa.by_text != null) + @intFromBool(aa.by_label != null);
    if (given > 1) return error.ConflictingLocator;
    if (aa.role == null and aa.hasRoleOptions()) return error.LocatorOptionWithoutRole;
    if (aa.role == null and aa.by_text == null and aa.by_label == null and aa.hasMatchOptions()) return error.LocatorOptionWithoutRole;
    if (aa.role != null and aa.exact and aa.name == null) return error.ExactWithoutName;
    if (aa.by_text) |t| return .{ .text = .{ .value = t, .exact = aa.exact, .nth = aa.nth } };
    if (aa.by_label) |t| return .{ .label = .{ .value = t, .exact = aa.exact, .nth = aa.nth } };
    if (aa.selector) |s| return .{ .selector = s };
    if (aa.ref) |r| return .{ .ref = r };
    if (aa.role) |role| return .{ .role = .{ .role = role, .name = aa.name, .level = aa.level, .exact = aa.exact, .nth = aa.nth } };
    return error.MissingLocator;
}

fn matchOpt(a: []const u8, opt: []const u8) bool {
    return eq(a, opt) or (std.mem.startsWith(u8, a, opt) and a.len > opt.len and a[opt.len] == '=');
}

/// `--opt val`(공백) 또는 `--opt=val`의 값. `i`를 소비만큼 전진. 값 없으면 MissingOptionValue.
fn optValue(rest: []const []const u8, i: *usize, opt: []const u8) ParseError![]const u8 {
    const a = rest[i.*];
    if (eq(a, opt)) {
        if (i.* + 1 >= rest.len) return error.MissingOptionValue;
        i.* += 2;
        return rest[i.* - 1];
    }
    i.* += 1; // `--opt=val` 형태
    return a[opt.len + 1 ..];
}

fn hasHelpFlag(args: []const []const u8) bool {
    for (args, 0..) |a, i| {
        if (eq(a, "--")) return false; // 그 뒤는 위치 인자(W9f — `exec -- -h` 는 식이다)
        // 값을 받는 옵션 바로 뒤는 값이다 — `type --text -h` 는 글 「-h」(W9f 적대 리뷰 1 회차: repl 에서 도움말을 「성공」 으로 냈다).
        if (i > 0 and takesValue(args[i - 1])) continue;
        if (eq(a, "--help") or eq(a, "-h")) return true;
    }
    return false;
}

/// 다음 토큰을 값으로 받는 옵션인가(`--opt=값` 꼴과 값 없는 플래그는 아니다).
fn takesValue(opt: []const u8) bool {
    if (!std.mem.startsWith(u8, opt, "--") or std.mem.indexOfScalar(u8, opt, '=') != null) return false;
    for ([_][]const u8{ "--", "--help", "--interactive", "--clear", "--load", "--visible", "--exact", "--secure" }) |flag| if (eq(opt, flag)) return false;
    return true;
}

/// exec 인자의 값 깊이 상한 — 서버 계약 `control_browser.execute_script_args_max_depth`(시험이 둘을 맞춘다). 서버는 바깥 배열의 원소를
/// 깊이 0 에 두고 어느 값이든 이 깊이 이하를 요구한다(W9f 적대 리뷰 2·3 회차: 64 로 좁혔다가, 괄호 수로 세어 가장 안쪽이 빈 컨테이너인 인자를
/// 한 단 엄격하게 막았다). 요청 JSON 쓰개 한도(256) 안쪽이다.
pub const max_args_depth = 128;

/// exec 인자 글(JSON 배열)에서 서버 셈법의 가장 깊은 값 — 바깥 배열 안의 값마다 「둘러싼 컨테이너 수 − 1」(문자열 안은 세지 않는다).
pub fn argsValueDepth(text: []const u8) usize {
    var open: usize = 0;
    var deepest: usize = 0;
    var in_string = false;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (in_string) {
            if (ch == '\\') i += 1 else if (ch == '"') in_string = false;
            continue;
        }
        switch (ch) {
            ']', '}' => open -|= 1,
            ',', ':', ' ', '\t', '\r', '\n' => {},
            else => {
                // 값이 여기서 시작한다(컨테이너·문자열·수·리터럴 — 이어지는 글자도 같은 깊이라 셈이 바뀌지 않는다).
                if (open >= 1) deepest = @max(deepest, open - 1);
                if (ch == '"') in_string = true;
                if (ch == '[' or ch == '{') open += 1;
            },
        }
    }
    return deepest;
}

/// 10진 파싱 후 wire i64 범위 제한(surface_id는 JSON integer=i64). sessions.parseU64와 동일 규율.
// Share target ownership across all verb parsers: no branch may silently overwrite it.
fn assignSurface(target: *?u64, value: []const u8) ParseError!void {
    if (target.* != null) return error.DuplicateSurface;
    target.* = parseU64(value) catch return error.InvalidSurface;
}

fn parseU64(s: []const u8) !u64 {
    const v = try std.fmt.parseInt(u64, s, 10);
    if (v > std.math.maxInt(i64)) return error.Overflow;
    return v;
}

inline fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// `--rect` 값 `x,y,width,height`(쉼표 구분 4개 수치) → `[4]f64`. width/height는 양수, 전부 유한. 형식 오류 → error(InvalidRect).
/// 서버(parseScreenshotOptParams)도 같은 검증을 하지만 CLI에서 명확한 에러(InvalidRect)를 주기 위해 먼저 검사한다.
fn parseRect(s: []const u8) !([4]f64) {
    var out: [4]f64 = undefined;
    var it = std.mem.splitScalar(u8, s, ',');
    var n: usize = 0;
    while (it.next()) |part| : (n += 1) {
        if (n >= 4) return error.InvalidRect; // 4개 초과
        out[n] = std.fmt.parseFloat(f64, part) catch return error.InvalidRect;
        if (!std.math.isFinite(out[n])) return error.InvalidRect;
    }
    if (n != 4) return error.InvalidRect; // 4개 미만
    if (!(out[2] > 0) or !(out[3] > 0)) return error.InvalidRect; // width/height 양수
    return out;
}

/// `--scale` 값 → f64. 양수·유한만. 형식 오류 → error(InvalidScale).
fn parseScale(s: []const u8) !f64 {
    const v = std.fmt.parseFloat(f64, s) catch return error.InvalidScale;
    if (!std.math.isFinite(v) or !(v > 0)) return error.InvalidScale;
    return v;
}

// ══ client wire ════════════════════════════════════════════════════════════════════════════════════════════

/// 파싱된 `Request` → JSON-RPC 요청 바이트 한 줄(1a `serializeMessage` 재사용). caller free. 메서드명은 camelCase
/// (control_browser `parseBrowserMethod` 계약: navigate/getUrl/executeScript/getCookies).
pub fn buildRequestBytes(gpa: std.mem.Allocator, req: Request, id: cp.Id) (std.mem.Allocator.Error || error{InvalidArgs})![]u8 {
    switch (req) {
        .list => return cp.serializeMessage(gpa, .{ .request = .{ .id = id, .method = "browser.list", .params = null } }), // 발견 — params 없음
        .navigate => |n| {
            var obj: std.json.ObjectMap = .empty;
            defer obj.deinit(gpa);
            try obj.put(gpa, "id", .{ .integer = @intCast(n.surface_id) });
            try obj.put(gpa, "url", .{ .string = n.url });
            return cp.serializeMessage(gpa, .{ .request = .{ .id = id, .method = "browser.navigate", .params = .{ .object = obj } } });
        },
        .get_url => |g| return idOnlyRequest(gpa, id, "browser.getUrl", g.surface_id),
        .exec => |e| {
            var obj: std.json.ObjectMap = .empty;
            defer obj.deinit(gpa);
            try obj.put(gpa, "id", .{ .integer = @intCast(e.surface_id) });
            try obj.put(gpa, "script", .{ .string = e.script });
            try obj.put(gpa, "max_result_bytes", .{ .integer = @intCast(e.max_result_bytes) });
            var parsed_args: ?std.json.Parsed(std.json.Value) = null;
            defer if (parsed_args) |*parsed| parsed.deinit();
            if (e.args_json) |raw| {
                if (argsValueDepth(raw) > max_args_depth) return error.InvalidArgs; // 쓰개의 중첩 한도(256)에서 panic 했다(W9f 적대 리뷰 1 회차)
                // Preserve number lexemes through the CLI request. The server validates -0 and the JS safe-number
                // boundary against the original spelling before WebKit receives NSNumber values.
                parsed_args = std.json.parseFromSlice(std.json.Value, gpa, raw, .{ .parse_numbers = false }) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.InvalidArgs,
                };
                if (parsed_args.?.value != .array) return error.InvalidArgs;
                try obj.put(gpa, "args", parsed_args.?.value);
            }
            return cp.serializeMessage(gpa, .{ .request = .{ .id = id, .method = "browser.executeScript", .params = .{ .object = obj } } });
        },
        .get_cookies => |g| return idOnlyRequest(gpa, id, "browser.getCookies", g.surface_id),
        .set_cookie => |c| {
            var obj: std.json.ObjectMap = .empty;
            defer obj.deinit(gpa);
            try obj.put(gpa, "id", .{ .integer = @intCast(c.surface_id) });
            try obj.put(gpa, "name", .{ .string = c.name });
            try obj.put(gpa, "value", .{ .string = c.value });
            if (c.domain) |d| try obj.put(gpa, "domain", .{ .string = d });
            if (c.path) |p| try obj.put(gpa, "path", .{ .string = p });
            if (c.secure) try obj.put(gpa, "secure", .{ .bool = true });
            return cp.serializeMessage(gpa, .{ .request = .{ .id = id, .method = "browser.setCookie", .params = .{ .object = obj } } });
        },
        .delete_cookie => |c| {
            var obj: std.json.ObjectMap = .empty;
            defer obj.deinit(gpa);
            try obj.put(gpa, "id", .{ .integer = @intCast(c.surface_id) });
            try obj.put(gpa, "name", .{ .string = c.name });
            if (c.domain) |d| try obj.put(gpa, "domain", .{ .string = d });
            if (c.path) |p| try obj.put(gpa, "path", .{ .string = p });
            return cp.serializeMessage(gpa, .{ .request = .{ .id = id, .method = "browser.deleteCookie", .params = .{ .object = obj } } });
        },
        .get_local_storage => |g| return keyRequest(gpa, id, "browser.getLocalStorage", g.surface_id, g.key, null),
        .set_local_storage => |g| return keyRequest(gpa, id, "browser.setLocalStorage", g.surface_id, g.key, g.value),
        .remove_local_storage => |g| return keyRequest(gpa, id, "browser.removeLocalStorage", g.surface_id, g.key, null),
        .clear_storage => |g| return idOnlyRequest(gpa, id, "browser.clearStorage", g.surface_id),
        .back => |g| return idOnlyRequest(gpa, id, "browser.back", g.surface_id),
        .close => |g| return idOnlyRequest(gpa, id, "browser.close", g.surface_id),
        .open => |o| {
            var obj: std.json.ObjectMap = .empty;
            defer obj.deinit(gpa);
            if (o.url) |u| try obj.put(gpa, "url", .{ .string = u });
            if (o.timeout_ms) |t| try obj.put(gpa, "timeout_ms", .{ .integer = t });
            return cp.serializeMessage(gpa, .{ .request = .{ .id = id, .method = "browser.open", .params = .{ .object = obj } } });
        },
        .forward => |g| return idOnlyRequest(gpa, id, "browser.forward", g.surface_id),
        .reload => |g| return idOnlyRequest(gpa, id, "browser.reload", g.surface_id),
        .hover => |c| return actRequest(gpa, id, "browser.hover", c.surface_id, c.locator, null),
        .press => |c| {
            var obj: std.json.ObjectMap = .empty;
            defer obj.deinit(gpa);
            try obj.put(gpa, "id", .{ .integer = @intCast(c.surface_id) });
            try obj.put(gpa, "key", .{ .string = c.key });
            var loc_obj: std.json.ObjectMap = .empty;
            defer loc_obj.deinit(gpa);
            if (c.locator) |l| try putLocator(gpa, &obj, &loc_obj, l);
            return cp.serializeMessage(gpa, .{ .request = .{ .id = id, .method = "browser.press", .params = .{ .object = obj } } });
        },
        .click => |c| return actRequest(gpa, id, "browser.click", c.surface_id, c.locator, null),
        .type_text => |c| return actRequest(gpa, id, "browser.type", c.surface_id, c.locator, c.text),
        .scroll => |c| return actRequest(gpa, id, "browser.scroll", c.surface_id, c.locator, null),
        .wait => |w| {
            var obj: std.json.ObjectMap = .empty;
            defer obj.deinit(gpa);
            try obj.put(gpa, "id", .{ .integer = @intCast(w.surface_id) });
            try obj.put(gpa, "condition", .{ .string = w.condition.wire() });
            if (w.selector) |selector| try obj.put(gpa, "selector", .{ .string = selector });
            var loc_obj: std.json.ObjectMap = .empty;
            defer loc_obj.deinit(gpa);
            if (w.locator) |l| try putLocator(gpa, &obj, &loc_obj, l);
            try obj.put(gpa, "timeout_ms", .{ .integer = w.timeout_ms });
            return cp.serializeMessage(gpa, .{ .request = .{ .id = id, .method = "browser.wait", .params = .{ .object = obj } } });
        },
        .snapshot => |sn| {
            var obj: std.json.ObjectMap = .empty;
            defer obj.deinit(gpa);
            try obj.put(gpa, "id", .{ .integer = @intCast(sn.surface_id) });
            if (sn.interactive_only) try obj.put(gpa, "interactive_only", .{ .bool = true });
            if (sn.max_depth) |d| try obj.put(gpa, "max_depth", .{ .integer = d });
            if (sn.selector) |selector| try obj.put(gpa, "selector", .{ .string = selector });
            return cp.serializeMessage(gpa, .{ .request = .{ .id = id, .method = "browser.snapshot", .params = .{ .object = obj } } });
        },
        .console => |c| {
            var obj: std.json.ObjectMap = .empty;
            defer obj.deinit(gpa);
            try obj.put(gpa, "id", .{ .integer = @intCast(c.surface_id) });
            if (c.clear) try obj.put(gpa, "clear", .{ .bool = true });
            return cp.serializeMessage(gpa, .{ .request = .{ .id = id, .method = "browser.console", .params = .{ .object = obj } } });
        },
    }
}

/// locator 를 요청 객체에 — selector·ref 는 최상위, role 은 `locator` 객체(`loc_obj` 는 부른 쪽이 함수 끝까지 쥔다 — 중첩 객체 수명).
fn putLocator(gpa: std.mem.Allocator, obj: *std.json.ObjectMap, loc_obj: *std.json.ObjectMap, l: Locator) std.mem.Allocator.Error!void {
    switch (l) {
        .selector => |sel| try obj.put(gpa, "selector", .{ .string = sel }),
        .ref => |r| try obj.put(gpa, "ref", .{ .string = r }),
        .role => |r| {
            try loc_obj.put(gpa, "role", .{ .string = r.role });
            if (r.name) |n| try loc_obj.put(gpa, "name", .{ .string = n });
            if (r.level) |v| try loc_obj.put(gpa, "level", .{ .integer = v });
            if (r.exact) try loc_obj.put(gpa, "exact", .{ .bool = true });
            if (r.nth) |v| try loc_obj.put(gpa, "nth", .{ .integer = v });
            try obj.put(gpa, "locator", .{ .object = loc_obj.* });
        },
        .text, .label => |t| {
            try loc_obj.put(gpa, if (l == .text) "text" else "label", .{ .string = t.value });
            if (t.exact) try loc_obj.put(gpa, "exact", .{ .bool = true });
            if (t.nth) |v| try loc_obj.put(gpa, "nth", .{ .integer = v });
            try obj.put(gpa, "locator", .{ .object = loc_obj.* });
        },
    }
}

/// act 요청 바이트: `{id, selector|ref, text?}`(§9.5.4). locator=selector 또는 ref 하나, text null이면 locator만(click/scroll).
/// ref는 wire 불투명 토큰(서버가 [data-maru-ref]로 해소). caller free.
fn actRequest(gpa: std.mem.Allocator, id: cp.Id, method: []const u8, surface_id: u64, locator: Locator, text: ?[]const u8) std.mem.Allocator.Error![]u8 {
    return switch (locator) {
        .selector => |s| twoFieldRequest(gpa, id, method, surface_id, "selector", s, "text", text),
        .ref => |r| twoFieldRequest(gpa, id, method, surface_id, "ref", r, "text", text),
        .role, .text, .label => {
            var obj: std.json.ObjectMap = .empty;
            defer obj.deinit(gpa);
            var loc_obj: std.json.ObjectMap = .empty;
            defer loc_obj.deinit(gpa);
            try obj.put(gpa, "id", .{ .integer = @intCast(surface_id) });
            try putLocator(gpa, &obj, &loc_obj, locator);
            if (text) |t| try obj.put(gpa, "text", .{ .string = t });
            return cp.serializeMessage(gpa, .{ .request = .{ .id = id, .method = method, .params = .{ .object = obj } } });
        },
    };
}

/// localStorage 요청 바이트: `{id, key, value?}`. value null이면 key만(get/remove). caller free.
fn keyRequest(gpa: std.mem.Allocator, id: cp.Id, method: []const u8, surface_id: u64, key: []const u8, value: ?[]const u8) std.mem.Allocator.Error![]u8 {
    return twoFieldRequest(gpa, id, method, surface_id, "key", key, "value", value);
}

/// `{id, <req_field>, <opt_field>?}` 모양 요청 빌더 공용(act=selector/text·localStorage=key/value가 필드명만
/// 달랐다). opt_val null이면 opt_field 생략. wire-envelope 변경이 한 곳에만 반영되게 통합. caller free.
fn twoFieldRequest(gpa: std.mem.Allocator, id: cp.Id, method: []const u8, surface_id: u64, req_field: []const u8, req_val: []const u8, opt_field: []const u8, opt_val: ?[]const u8) std.mem.Allocator.Error![]u8 {
    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(gpa);
    try obj.put(gpa, "id", .{ .integer = @intCast(surface_id) });
    try obj.put(gpa, req_field, .{ .string = req_val });
    if (opt_val) |v| try obj.put(gpa, opt_field, .{ .string = v });
    return cp.serializeMessage(gpa, .{ .request = .{ .id = id, .method = method, .params = .{ .object = obj } } });
}

fn idOnlyRequest(gpa: std.mem.Allocator, id: cp.Id, method: []const u8, surface_id: u64) std.mem.Allocator.Error![]u8 {
    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(gpa);
    try obj.put(gpa, "id", .{ .integer = @intCast(surface_id) });
    return cp.serializeMessage(gpa, .{ .request = .{ .id = id, .method = method, .params = .{ .object = obj } } });
}

/// screenshot 요청 바이트(§9.5.7): `browser.screenshot {id, rect?, scale?}`. rect=`{x,y,width,height}`·scale=수(둘 다
/// 부재면 `{id}`만=전체 뷰·기기 배율). 응답은 단일이 아니라 chunk 스트림이라 렌더는 `ScreenshotStreamValidator`가 맡는다
/// (renderResponse 아님). main이 이 요청을 보내고 프레임을 assembler로 재조립. caller free.
pub fn buildScreenshotRequestBytes(gpa: std.mem.Allocator, cmd: ScreenshotCmd, id: cp.Id) std.mem.Allocator.Error![]u8 {
    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(gpa);
    // 중첩 rect 객체는 **함수 스코프**로 둔다 — `if` 블록 안에서 defer deinit하면 serializeMessage 전에 free돼 obj가 든
    // `.object = ro`가 UAF가 된다(ObjectMap.deinit은 top-level만 free하므로 함수 끝 deinit이 정확한 단일 free).
    var ro: std.json.ObjectMap = .empty;
    defer ro.deinit(gpa);
    try obj.put(gpa, "id", .{ .integer = @intCast(cmd.surface_id) });
    if (cmd.rect) |r| {
        try ro.put(gpa, "x", .{ .float = r[0] });
        try ro.put(gpa, "y", .{ .float = r[1] });
        try ro.put(gpa, "width", .{ .float = r[2] });
        try ro.put(gpa, "height", .{ .float = r[3] });
        try obj.put(gpa, "rect", .{ .object = ro });
    }
    if (cmd.scale) |sc| try obj.put(gpa, "scale", .{ .float = sc });
    return cp.serializeMessage(gpa, .{ .request = .{ .id = id, .method = "browser.screenshot", .params = .{ .object = obj } } });
}

// ══ 응답 렌더 ══════════════════════════════════════════════════════════════════════════════════════════════

/// 어느 요청의 응답인지 — result 모양을 안다(navigate={ok}·get_url={url}·exec={result}·get_cookies={cookies}).
pub const ResponseKind = enum { list, navigate, get_url, exec, get_cookies, ok, value, snapshot, console, open, close };

const unauthorized_code: i64 = -32002;
const unsupported_by_engine_code: i64 = -32008;
/// executeScript 의 스크립트 오류 — data 에 `{kind, name, message, stack, diagnostics_truncated}`.
const script_error_code: i64 = -32006;
const timeout_code: i64 = -32004;
const unauthorized_hint =
    \\hint: browser requests are allowed from a command running in a maru pane's foreground job (an agent there,
    \\      or your shell). Not from another terminal, inside tmux/screen, or a background job while another
    \\      program holds the terminal. A refused confirmation dialog looks the same; the maru app log has the reason.
    \\      A tab that was closed, or an id that is not in `browser list`, is refused the same way.
    \\
;

/// 응답 바이트 한 줄을 기계·사람 읽기 편한 형태로 `w`에 쓴다. 에러 응답이면 균일하게 `error: <msg> (<code>)`
/// (sessions.renderResponse 규율 — 미grant 거부는 `error: Unauthorized (-32002)`). result는 kind별 한 줄.
/// Returns false after a server/protocol diagnostic; write failures remain errors.
pub fn renderResponse(gpa: std.mem.Allocator, response_bytes: []const u8, kind: ResponseKind, w: *std.Io.Writer) !bool {
    var pm = cp.parseMessage(gpa, response_bytes) catch {
        try w.writeAll("error: malformed response from server\n");
        return false;
    };
    defer pm.deinit();
    const resp = switch (pm.message) {
        .response => |r| r,
        else => {
            try w.writeAll("error: unexpected message (not a response)\n");
            return false;
        },
    };
    if (resp.err) |e| {
        // 메시지에는 페이지 글이 섞일 수 있다(로케이터의 후보 이름 등) — 표시 안전하게(W9b②-1).
        var safe_msg: [4096]u8 = undefined;
        const msg_n = displaySafe(e.message[0..@min(e.message.len, safe_msg.len)], &safe_msg);
        try w.print("error: {s}{s} ({d})", .{ safe_msg[0..msg_n], if (e.message.len > safe_msg.len) "…" else "", e.code });
        // W9-0: 어느 엔진이 지원하지 않는지(`-32008` data) — 브라우저 탭이 아니면 그것이 이유다.
        if (e.code == unsupported_by_engine_code) if (e.data) |d| if (d == .object) {
            if (d.object.get("controllable")) |c| if (c == .bool and !c.bool) try w.writeAll(" [not a browser tab]");
            if (d.object.get("engine")) |engine| if (engine == .string) try w.print(" [engine={s}]", .{engine.string});
            // 메서드는 되지만 그 인자를 그 엔진이 못 한다(W9b② — WebKit 의 locator).
            if (d.object.get("param")) |param| if (param == .string) {
                var safe_p: [64]u8 = undefined;
                try w.print(" [param={s}]", .{safe_p[0..displaySafe(param.string[0..@min(param.string.len, 64)], &safe_p)]});
            };
        };
        try w.writeAll("\n");
        // W9a②: 스크립트 오류의 진단 한 줄 — 종류와 이름·메시지(페이지의 스크립트가 정한 글이라 걸러 낸다; stack 은 싣지 않는다).
        if (e.code == script_error_code) if (e.data) |d| if (d == .object) {
            try w.writeAll("script error (");
            try writePageText(gpa, w, strField(d.object.get("kind")), false);
            try w.writeAll("): ");
            try writePageText(gpa, w, strField(d.object.get("name")), false);
            try w.writeAll(": ");
            try writePageText(gpa, w, strField(d.object.get("message")), false);
            try w.writeAll("\n");
        };
        // 1g(control-plane-security §8.4): 확인 모달 없이 거절되는 가장 흔한 이유는 「pane 밖에서 불렀다」다. 서버는 균일
        // unauthorized 만 주므로(존재 oracle 금지) 이유를 묻지 않고 늘 같은 안내를 붙인다 — 서버 정보가 새지 않는다.
        // W9b③: close 의 거절은 그 pane 이 연 탭이 아니어서다 — 일반 안내(pane 의 foreground job)는 이유를 가린다(적대 리뷰 1 회차).
        if (e.code == unauthorized_code) try w.writeAll(if (kind == .close) "hint: only tabs this pane opened with `browser open` can be closed\n" else unauthorized_hint);
        // 로케이터 wait 의 시한 — 마지막 확인에 숨은 일치가 있었다(W9b②-3 적대 리뷰 1 회차 — data 에만 있어 보이지 않았다).
        if (e.code == timeout_code) if (e.data) |d| if (d == .object) if (d.object.get("hidden")) |h| if (h == .integer and h.integer > 0)
            try w.print("hint: {d} matching element(s) are hidden (not rendered, aria-hidden or off-page)\n", .{h.integer});
        return false;
    }
    const result = switch (resp.result orelse {
        try w.writeAll("error: empty result\n");
        return false;
    }) {
        .object => |o| o,
        else => {
            try w.writeAll("error: malformed result\n");
            return false;
        },
    };
    switch (kind) {
        .list => {
            // {surfaces:[{id,url,title,panel_kind}]} → surface별 한 줄. 에이전트가 id를 골라 제어를 건다.
            const surfaces = switch (result.get("surfaces") orelse std.json.Value{ .null = {} }) {
                .array => |a| a,
                else => {
                    try w.writeAll("error: malformed surfaces\n");
                    return false;
                },
            };
            if (surfaces.items.len == 0) {
                try w.writeAll("(no web surfaces)\n");
                return true;
            }
            for (surfaces.items) |item| {
                const o = switch (item) {
                    .object => |oo| oo,
                    else => continue,
                };
                // 주소·제목은 페이지가 정한 글 — 걸러 내고 제목은 JSON 으로 인용한다(W9f 적대 리뷰 4 회차 — 제목의 `"` 로 뒤 칸을 흉내 냈다).
                try w.print("surface {d}  ", .{intField(o.get("id")) orelse 0});
                try writePageText(gpa, w, strField(o.get("panel_kind")), false);
                try w.writeAll("  ");
                try writePageText(gpa, w, strField(o.get("url")), false);
                try w.writeAll("  ");
                try writePageText(gpa, w, strField(o.get("title")), true);
                // W9-0: 엔진(뒤에 붙인다 — 앞 칸을 읽던 대본이 그대로 돈다). 실행할 수 있는 명령이 없으면 그 이유를 적는다
                // (브라우저 탭이 아닌 markdown·파일 뷰 / 엔진이 아직 지원하지 않음). 구 서버는 생략.
                if (o.get("engine")) |engine| {
                    try w.print("  engine={s}", .{strField(engine)});
                    const controllable = if (o.get("controllable")) |c| c != .bool or c.bool else true;
                    if (!controllable) {
                        try w.writeAll(" (not a browser tab — browser commands do not apply)");
                    } else if (o.get("methods")) |methods| if (methods == .array and methods.array.items.len == 0)
                        try w.writeAll(" (browser commands not supported yet)");
                }
                try w.writeAll("\n");
            }
        },
        .navigate => {
            if (boolField(result.get("ok"))) try w.writeAll("ok\n") else {
                try w.writeAll("error: navigate not ok\n");
                return false;
            }
            // Chromium 탭은 첫 불러오기를 기다린다(W9a) — 불러온 문서가 없으면 경고 한 줄(이동 자체는 보냈다).
            if (result.get("loaded")) |l| if (l == .bool and !l.bool) try w.writeAll("warning: no page finished loading (an empty response, a download, a same-page link, or the time ran out) — check with get-url\n");
        },
        .ok => { // set-cookie/delete-cookie/set·remove-local-storage/clear-storage 성공 = {ok:true}
            if (boolField(result.get("ok"))) try w.writeAll("ok\n") else {
                try w.writeAll("error: not ok\n");
                // 로케이터가 숨은 일치만 찾았다(W9b②-2) — 그 안내 한 줄(페이지 글은 섞이지 않지만 표시 안전하게).
                if (result.get("hint")) |h| if (h == .string) {
                    var safe_h: [512]u8 = undefined;
                    try w.print("hint: {s}\n", .{safe_h[0..displaySafe(h.string[0..@min(h.string.len, 512)], &safe_h)]});
                };
                return false;
            }
            // 로케이터로 찾았으면 무엇을 눌렀는지(W9b②) — 첫 줄은 그대로 「ok」.
            if (result.get("matched")) |m| if (m == .object) {
                // 이름은 페이지가 정한 글 — 제어·양방향 제어 글자를 빼고 JSON 으로 인용한다(터미널 표시 속이기, W9b②-1 1 회차).
                var safe_ref: [64]u8 = undefined;
                var safe_name: [512]u8 = undefined;
                const ref = strField(m.object.get("ref"));
                const name = strField(m.object.get("name"));
                try w.print("matched {s} ", .{safe_ref[0..displaySafe(ref[0..@min(ref.len, 64)], &safe_ref)]});
                var js: std.json.Stringify = .{ .writer = w, .options = .{} };
                js.write(safe_name[0..displaySafe(name[0..@min(name.len, 512)], &safe_name)]) catch return error.WriteFailed;
                if (name.len > 512) try w.writeAll("…");
                try w.writeAll("\n");
            };
            // wait 이 찾은 것이 여럿과 맞는다(W9b②-3) — 같은 로케이터로 누르면 「여럿」 으로 실패한다.
            if (boolField(result.get("ambiguous"))) try w.writeAll("warning: ambiguous — the locator matches several elements; act with the matched ref, --exact or --nth\n");
            // 입력 뒤 페이지가 대화상자를 띄웠다(W9b③ 적대 리뷰 3 회차) — 입력은 갔다: 다시 하면 두 번 간다.
            if (boolField(result.get("dialog"))) try w.writeAll("warning: the page opened a dialog right after the input — the input reached the page, do not repeat it; answer the dialog in that tab\n");
        },
        // get-local-storage → {value}. 값은 페이지가 쓴 글 — 걸러 낸다(W9f 적대 리뷰 5 회차: OSC 52·화면 지우기·줄바꿈이 그대로 나갔다).
        .value => {
            try writePageText(gpa, w, strField(result.get("value")), false);
            try w.writeAll("\n");
        },
        // W9b③: 연 탭의 id(다음 명령의 --surface)와 주소. 시한 안에 다 불러오지 못했으면 경고 한 줄(탭은 열렸다).
        .open => {
            const tab = if (result.get("id")) |v| (if (v == .integer) v.integer else 0) else 0;
            const url = strField(result.get("url"));
            var safe_url: [2048]u8 = undefined;
            if (url.len == 0) try w.print("opened {d}\n", .{tab}) else try w.print("opened {d} {s}\n", .{ tab, safe_url[0..displaySafe(url[0..@min(url.len, safe_url.len)], &safe_url)] });
            if (!boolField(result.get("loaded"))) try w.writeAll("warning: the page did not finish loading in time — wait --load before acting\n");
        },
        .close => {
            if (boolField(result.get("closed"))) try w.writeAll("closed\n") else {
                const reason = strField(result.get("reason"));
                var safe_r: [512]u8 = undefined;
                try w.print("not closed: {s}\n", .{safe_r[0..displaySafe(reason[0..@min(reason.len, safe_r.len)], &safe_r)]});
                return false;
            }
        },
        .get_url => {
            try writePageText(gpa, w, strField(result.get("url")), false);
            try w.writeAll("\n");
        },
        .exec => {
            try writeDisplaySafeJsonText(w, strField(result.get("result")));
            try w.writeAll("\n");
        },
        .get_cookies => {
            // cookies 배열을 JSON 한 줄로 재직렬화(에이전트가 파싱). 배열 아니면 에러.
            const cookies = switch (result.get("cookies") orelse std.json.Value{ .null = {} }) {
                .array => |a| a,
                else => {
                    try w.writeAll("error: malformed cookies\n");
                    return false;
                },
            };
            try writeDisplaySafeJson(w, .{ .array = cookies });
            try w.writeAll("\n");
        },
        .snapshot => {
            // {snapshot:{tree:[{role,name,ref?,children?}]}} → compact 들여쓰기 텍스트(§9.5.4). 에이전트가 role/name/ref를 읽고 ref로 조작.
            const snap = switch (result.get("snapshot") orelse std.json.Value{ .null = {} }) {
                .object => |o| o,
                else => {
                    try w.writeAll("error: malformed snapshot\n");
                    return false;
                },
            };
            const tree = switch (snap.get("tree") orelse std.json.Value{ .null = {} }) {
                .array => |a| a,
                else => {
                    try w.writeAll("error: malformed snapshot tree\n");
                    return false;
                },
            };
            if (tree.items.len == 0) {
                try w.writeAll("(empty snapshot)\n");
                return true;
            }
            for (tree.items) |node| try renderSnapshotNode(gpa, node, 0, w);
        },
        .console => {
            // {console:[{level,text},...]} → 각 항목 `[level] text` 한 줄(§9.5.9). 배열 아니면 에러, 비면 안내.
            const entries = switch (result.get("console") orelse std.json.Value{ .null = {} }) {
                .array => |a| a,
                else => {
                    try w.writeAll("error: malformed console\n");
                    return false;
                },
            };
            if (entries.items.len == 0) {
                try w.writeAll("(empty console)\n");
                return true;
            }
            for (entries.items) |entry| {
                const o = switch (entry) {
                    .object => |oo| oo,
                    else => continue,
                };
                // 콘솔 글은 페이지가 쓴 것 — 걸러 낸다(줄바꿈으로 다음 항목을 흉내 내지 못하게, W9f 적대 리뷰 4 회차).
                try w.writeAll("[");
                try writePageText(gpa, w, strField(o.get("level")), false);
                try w.writeAll("] ");
                try writePageText(gpa, w, strField(o.get("text")), false);
                try w.writeAll("\n");
            }
        },
    }
    return true;
}

/// snapshot 을 그리는 깊이 상한 — 넘는 자식은 한 줄 안내로 접는다(W9f 적대 리뷰 5 회차).
pub const max_snapshot_render_depth: usize = 128;

/// snapshot 트리 노드 한 줄 + 자식 재귀(들여쓰기 2칸). `<role> "<name>" [ref=<ref>]`(name/ref 없으면 생략).
fn renderSnapshotNode(gpa: std.mem.Allocator, node: std.json.Value, depth: usize, w: *std.Io.Writer) !void {
    const o = switch (node) {
        .object => |oo| oo,
        else => return,
    };
    var i: usize = 0;
    while (i < depth) : (i += 1) try w.writeAll("  ");
    try writePageText(gpa, w, strField(o.get("role")), false);
    // 이름은 페이지가 정한 글 — 걸러 JSON 으로 인용한다(W9f 적대 리뷰 4 회차: `Q" [ref=n7]` 로 남의 ref 를 흉내 내고 ESC·RLO 가 그대로 나갔다).
    const name = strField(o.get("name"));
    if (name.len > 0) {
        try w.writeAll(" ");
        try writePageText(gpa, w, name, true);
    }
    const ref = strField(o.get("ref"));
    if (ref.len > 0) {
        try w.writeAll(" [ref=");
        try writePageText(gpa, w, ref, false);
        try w.writeAll("]");
    }
    try w.writeAll("\n");
    switch (o.get("children") orelse std.json.Value{ .null = {} }) {
        .array => |kids| if (kids.items.len > 0) {
            // 상한에서 접는다 — 재귀가 스택을 넘고 들여쓰기가 깊이의 제곱으로 커졌다(W9f 적대 리뷰 5 회차: 2 만 단에 죽고 1 만 4 천 단에 196 MB).
            if (depth + 1 >= max_snapshot_render_depth) {
                i = 0;
                while (i <= depth) : (i += 1) try w.writeAll("  ");
                try w.writeAll("… (deeper levels omitted)\n");
            } else for (kids.items) |kid| try renderSnapshotNode(gpa, kid, depth + 1, w);
        },
        else => {},
    }
}

/// 페이지가 정한 글(이름·제목·주소·콘솔)을 낸다 — 제어·양방향·줄 구분 글자를 빼고(`displaySafe`), `quoted` 면 JSON 문자열로 인용한다(따옴표로
/// 칸을 흉내 내지 못하게). 메모리가 모자라면 「…」.
fn writePageText(gpa: std.mem.Allocator, w: *std.Io.Writer, text: []const u8, quoted: bool) !void {
    const tmp = gpa.alloc(u8, text.len) catch return w.writeAll("…");
    defer gpa.free(tmp);
    const safe = tmp[0..displaySafe(text, tmp)];
    if (!quoted) return w.writeAll(safe);
    var js: std.json.Stringify = .{ .writer = w, .options = .{} };
    js.write(safe) catch return error.WriteFailed;
}

fn boolField(v: ?std.json.Value) bool {
    return if (v) |val| (val == .bool and val.bool) else false;
}
fn strField(v: ?std.json.Value) []const u8 {
    return if (v) |val| (switch (val) {
        .string => |s| s,
        else => "",
    }) else "";
}
fn intField(v: ?std.json.Value) ?i64 {
    return if (v) |val| (switch (val) {
        .integer => |i| i,
        else => null,
    }) else null;
}

// ══ screenshot(5f-1) chunk 재조립(L2 순수, §9.5.7) ═══════════════════════════════════════════════════════════

/// screenshot chunk notification의 method(server→client push). control_browser의 wire 이름과 동일해야 한다(client측 상수).
const screenshot_chunk_method = cp.browser_screenshot_chunk_method; // 22차 [8]: 단일 출처(control_plane)
const execute_script_chunk_method = cp.browser_execute_script_chunk_method;
const snapshot_chunk_method = cp.browser_snapshot_chunk_method; // §9.5.10 통일-1: snapshot 대형 결과 chunk 스트림 method(client측 상수)
const console_chunk_method = cp.browser_console_chunk_method; // §9.5.10 통일-2: console 대형 결과 chunk 스트림 method(client측 상수)

/// executeScript chunk 재조립기(5f-5b L2). 전체 결과는 max_bytes를 넘지 않으며,
/// chunk는 request/result id·encoding·seq·최종 bytes를 모두 검증한다.
/// main CLI가 전체 결과를 메모리에 모으지 않고 secure spool로 쓰기 위한 프레임 검증기. decoded chunk는 caller의
/// 고정 512 KiB scratch를 빌리고, inline만 계약상 최대 512 KiB owned buffer에 직렬화한다.
pub const ExecuteScriptStreamValidator = struct {
    gpa: std.mem.Allocator,
    request_id: cp.Id,
    result_id: ?i64 = null,
    max_bytes: usize,
    total_bytes: usize = 0,
    next_seq: i64 = 0,
    saw_short_chunk: bool = false,
    terminal: bool = false,
    inline_buf: std.ArrayList(u8) = .empty,

    pub const Step = union(enum) {
        need_more,
        chunk: []const u8,
        inline_result: []const u8,
        error_response, // 서버가 정상 JSON-RPC error(script_error·result_too_large·timeout·unauthorized 등) 반환 — caller가 원 응답을 renderResponse해 실제 code/message를 보임
        done,
        failed,
    };

    pub fn init(gpa: std.mem.Allocator, request_id: cp.Id, max_bytes: usize) ExecuteScriptStreamValidator {
        return .{ .gpa = gpa, .request_id = request_id, .max_bytes = max_bytes };
    }

    pub fn deinit(self: *ExecuteScriptStreamValidator) void {
        self.inline_buf.deinit(self.gpa);
    }

    pub fn feed(self: *ExecuteScriptStreamValidator, frame: []const u8, scratch: []u8) std.mem.Allocator.Error!Step {
        if (self.terminal) return .failed;
        var pm = cp.parseMessage(self.gpa, frame) catch return .failed;
        defer pm.deinit();
        return switch (pm.message) {
            .notification => |note| if (std.mem.eql(u8, note.method, execute_script_chunk_method))
                self.feedChunk(note.params, scratch)
            else
                .need_more,
            .response => |response| self.feedResponse(response),
            else => .failed,
        };
    }

    fn feedChunk(self: *ExecuteScriptStreamValidator, params: ?std.json.Value, scratch: []u8) Step {
        const obj = switch (params orelse return .failed) {
            .object => |o| o,
            else => return .failed,
        };
        const result_id = intField(obj.get("result_id")) orelse return .failed;
        const seq = intField(obj.get("seq")) orelse return .failed;
        if (result_id < 0 or seq != self.next_seq) return .failed;
        if (self.result_id) |bound| {
            if (bound != result_id) return .failed;
        } else self.result_id = result_id;
        const request_id = valueAsId(obj.get("request_id") orelse return .failed) orelse return .failed;
        if (!cp.idEql(request_id, self.request_id)) return .failed;
        const encoding = switch (obj.get("encoding") orelse return .failed) {
            .string => |s| s,
            else => return .failed,
        };
        if (!eq(encoding, "base64-json")) return .failed;
        const encoded = switch (obj.get("data") orelse return .failed) {
            .string => |s| s,
            else => return .failed,
        };
        const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return .failed;
        const max_chunks = std.math.divCeil(usize, self.max_bytes, scratch.len) catch return .failed;
        if (decoded_len == 0 or self.saw_short_chunk or self.next_seq >= @as(i64, @intCast(max_chunks)) or decoded_len > scratch.len or decoded_len > self.max_bytes -| self.total_bytes) return .failed;
        std.base64.standard.Decoder.decode(scratch[0..decoded_len], encoded) catch return .failed;
        self.total_bytes += decoded_len;
        self.next_seq += 1;
        self.saw_short_chunk = decoded_len < scratch.len;
        return .{ .chunk = scratch[0..decoded_len] };
    }

    fn feedResponse(self: *ExecuteScriptStreamValidator, response: cp.Response) std.mem.Allocator.Error!Step {
        if (!cp.idEql(response.id, self.request_id)) return .failed;
        // 정상 JSON-RPC error 응답은 stream 손상이 아니라 **실제 결과**다(script_error·result_too_large·timeout·unauthorized).
        // .failed로 뭉개 일반 "잘못된 stream" 메시지로 감추면 에이전트가 실패 원인을 못 본다 — caller가 원 응답 라인을
        // renderResponse해 실제 code/message를 내게 terminal error 신호를 준다(WrappedResultStreamValidator와 동형 — 리뷰).
        if (response.err != null) {
            self.terminal = true;
            return .error_response;
        }
        const obj = switch (response.result orelse return .failed) {
            .object => |o| o,
            else => return .failed,
        };
        const transfer = switch (obj.get("transfer") orelse return .failed) {
            .string => |s| s,
            else => return .failed,
        };
        if (eq(transfer, "inline")) {
            if (self.next_seq != 0) return .failed;
            const value = obj.get("result") orelse return .failed;
            self.inline_buf.clearRetainingCapacity();
            var writer = std.Io.Writer.Allocating.fromArrayList(self.gpa, &self.inline_buf);
            defer self.inline_buf = writer.toArrayList();
            var stringify: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
            stringify.write(value) catch return error.OutOfMemory;
            const bytes = writer.writer.buffered();
            if (bytes.len > 512 * 1024 or bytes.len > self.max_bytes) return .failed;
            self.total_bytes = bytes.len;
            self.terminal = true;
            return .{ .inline_result = bytes };
        }
        if (!eq(transfer, "chunked")) return .failed;
        const final_result_id = intField(obj.get("result_id")) orelse return .failed;
        const final_seq = intField(obj.get("seq_total")) orelse return .failed;
        const final_bytes = intField(obj.get("bytes")) orelse return .failed;
        if (self.result_id == null or final_result_id != self.result_id.? or final_seq != self.next_seq or final_bytes != self.total_bytes) return .failed;
        self.terminal = true;
        return .done;
    }
};

/// §9.5.10 통일: **inline이 method-특화 serializer로 감싸지는**(transfer envelope 없이 `{result:{<field>:value}}`) browser
/// 메서드의 응답 스트림을 bounded 검증·재조립한다. snapshot(`{snapshot:tree}`)·console(`{console:[…]}`)이 공유한다 — 둘은
/// executeScript와 **같은 transfer 기계**를 쓰되 chunk method(`browser.snapshotChunk`/`browser.consoleChunk`)만 다르고 나머지는
/// 동형이라 하나의 validator로 통일했다(chunk method는 `init`으로 주입). chunk 검증부는 executeScript와 동형(base64-json·
/// result_id/seq/request_id 일관·short-chunk·max_bytes/max_chunks 상한)이되, 종단 판정만 다르다: `transfer:"chunked"` final이면
/// raw 값을 재조립(`.done`), 아니면(inline `{<field>}` 또는 에러 응답) 그대로 렌더하도록 `.inline_terminal`. executeScript는
/// inline이 `{transfer:"inline",result:value}`라 shape가 달라 별도 `ExecuteScriptStreamValidator`, screenshot은 capture_id 기반.
pub const WrappedResultStreamValidator = struct {
    gpa: std.mem.Allocator,
    request_id: cp.Id,
    chunk_method: []const u8, // browser.snapshotChunk / browser.consoleChunk (SSOT 상수, init 주입)
    result_id: ?i64 = null,
    max_bytes: usize,
    total_bytes: usize = 0,
    next_seq: i64 = 0,
    saw_short_chunk: bool = false,
    terminal: bool = false,

    pub const Step = union(enum) {
        need_more,
        chunk: []const u8,
        inline_terminal, // inline `{<field>}` 또는 에러 응답 — caller가 원 응답 라인을 renderResponse
        done, // chunked final — caller가 재조립한 raw 값을 `{result:{<field>:value}}`로 감싸 렌더
        failed,
    };

    pub fn init(gpa: std.mem.Allocator, request_id: cp.Id, chunk_method: []const u8, max_bytes: usize) WrappedResultStreamValidator {
        return .{ .gpa = gpa, .request_id = request_id, .chunk_method = chunk_method, .max_bytes = max_bytes };
    }

    pub fn feed(self: *WrappedResultStreamValidator, frame: []const u8, scratch: []u8) Step {
        if (self.terminal) return .failed;
        var pm = cp.parseMessage(self.gpa, frame) catch return .failed;
        defer pm.deinit();
        return switch (pm.message) {
            .notification => |note| if (eq(note.method, self.chunk_method))
                self.feedChunk(note.params, scratch)
            else
                .need_more,
            .response => |response| self.feedResponse(response),
            else => .failed,
        };
    }

    // executeScript와 동형 bounded chunk 검증(base64-json wire 공유). scratch에 decode해 slice를 돌려준다.
    fn feedChunk(self: *WrappedResultStreamValidator, params: ?std.json.Value, scratch: []u8) Step {
        const obj = switch (params orelse return .failed) {
            .object => |o| o,
            else => return .failed,
        };
        const result_id = intField(obj.get("result_id")) orelse return .failed;
        const seq = intField(obj.get("seq")) orelse return .failed;
        if (result_id < 0 or seq != self.next_seq) return .failed;
        if (self.result_id) |bound| {
            if (bound != result_id) return .failed;
        } else self.result_id = result_id;
        const request_id = valueAsId(obj.get("request_id") orelse return .failed) orelse return .failed;
        if (!cp.idEql(request_id, self.request_id)) return .failed;
        const encoding = switch (obj.get("encoding") orelse return .failed) {
            .string => |s| s,
            else => return .failed,
        };
        if (!eq(encoding, "base64-json")) return .failed;
        const encoded = switch (obj.get("data") orelse return .failed) {
            .string => |s| s,
            else => return .failed,
        };
        const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return .failed;
        const max_chunks = std.math.divCeil(usize, self.max_bytes, scratch.len) catch return .failed;
        if (decoded_len == 0 or self.saw_short_chunk or self.next_seq >= @as(i64, @intCast(max_chunks)) or decoded_len > scratch.len or decoded_len > self.max_bytes -| self.total_bytes) return .failed;
        std.base64.standard.Decoder.decode(scratch[0..decoded_len], encoded) catch return .failed;
        self.total_bytes += decoded_len;
        self.next_seq += 1;
        self.saw_short_chunk = decoded_len < scratch.len;
        return .{ .chunk = scratch[0..decoded_len] };
    }

    fn feedResponse(self: *WrappedResultStreamValidator, response: cp.Response) Step {
        if (!cp.idEql(response.id, self.request_id)) return .failed;
        // 에러 응답(surface 없음 등)은 그대로 렌더한다 — renderResponse가 error envelope를 접는다.
        if (response.err != null) {
            self.terminal = true;
            return .inline_terminal;
        }
        const obj = switch (response.result orelse std.json.Value{ .null = {} }) {
            .object => |o| o,
            else => {
                self.terminal = true;
                return .inline_terminal;
            },
        };
        // transfer 필드가 있으면 chunked final(method-중립)이어야 한다. 없으면 inline `{<field>:value}`.
        if (obj.get("transfer")) |tv| {
            const transfer = switch (tv) {
                .string => |s| s,
                else => return .failed,
            };
            if (!eq(transfer, "chunked")) return .failed;
            const final_result_id = intField(obj.get("result_id")) orelse return .failed;
            const final_seq = intField(obj.get("seq_total")) orelse return .failed;
            const final_bytes = intField(obj.get("bytes")) orelse return .failed;
            if (self.result_id == null or final_result_id != self.result_id.? or final_seq != self.next_seq or final_bytes != self.total_bytes) return .failed;
            self.terminal = true;
            return .done;
        }
        self.terminal = true;
        return .inline_terminal;
    }
};

fn valueAsId(v: std.json.Value) ?cp.Id {
    return switch (v) {
        .integer => |n| .{ .number = n },
        .string => |s| .{ .string = s },
        else => null,
    };
}

/// screenshot chunk 스트림(§9.5.7)을 프레임 단위로 재조립한다. CLI(main)가 소켓에서 읽은 프레임을 하나씩 `feed`하면
/// chunk notification은 seq 순서로 PNG 버퍼에 누적하고, 최종 응답에서 완성(done)/에러(failed)를 판정한다. capture_id
/// 일관성·seq 연속성·seq_total 일치를 검증(누락/재정렬 감지 — 서버 FIFO가 순서를 보장하나 방어적으로도 확인). L2 순수.
/// screenshot 결과를 전체 메모리 재조립 없이 검증한다. chunk는 caller의 512 KiB scratch로 decode하고,
/// PNG header·누적 byte 수·capture/seq/final metadata만 보존한다.
pub const ScreenshotStreamValidator = struct {
    request_id: cp.Id,
    capture_id: ?i64 = null,
    next_seq: i64 = 0,
    saw_short_chunk: bool = false,
    total_bytes: usize = 0,
    header: [24]u8 = undefined,
    header_len: usize = 0,
    width: u32 = 0,
    height: u32 = 0,
    terminal: bool = false,

    pub const max_bytes: usize = 12 * 1024 * 1024;
    pub const Step = union(enum) {
        need_more,
        chunk: []const u8,
        error_response, // 서버가 정상 JSON-RPC error(unauthorized·surface 없음 등) 반환 — caller가 원 응답을 renderResponse해 실제 code/message를 보임
        done,
        failed,
    };

    pub fn init(request_id: cp.Id) ScreenshotStreamValidator {
        return .{ .request_id = request_id };
    }

    pub fn feed(self: *ScreenshotStreamValidator, gpa: std.mem.Allocator, frame: []const u8, scratch: []u8) std.mem.Allocator.Error!Step {
        if (self.terminal) return .failed;
        var pm = cp.parseMessage(gpa, frame) catch return .failed;
        defer pm.deinit();
        return switch (pm.message) {
            .notification => |note| if (eq(note.method, screenshot_chunk_method))
                self.feedChunk(note.params, scratch)
            else
                .need_more,
            .response => |response| self.feedResponse(response),
            .request => .need_more,
        };
    }

    fn feedChunk(self: *ScreenshotStreamValidator, params: ?std.json.Value, scratch: []u8) Step {
        const obj = switch (params orelse return .failed) {
            .object => |o| o,
            else => return .failed,
        };
        const capture_id = intField(obj.get("capture_id")) orelse return .failed;
        const seq = intField(obj.get("seq")) orelse return .failed;
        if (capture_id < 0 or seq != self.next_seq) return .failed;
        if (self.capture_id) |bound| {
            if (bound != capture_id) return .failed;
        } else self.capture_id = capture_id;
        const encoding = switch (obj.get("encoding") orelse return .failed) {
            .string => |s| s,
            else => return .failed,
        };
        if (!eq(encoding, "base64")) return .failed;
        const encoded = switch (obj.get("data") orelse return .failed) {
            .string => |s| s,
            else => return .failed,
        };
        const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return .failed;
        const max_chunks = std.math.divCeil(usize, max_bytes, scratch.len) catch return .failed;
        if (decoded_len == 0 or self.saw_short_chunk or self.next_seq >= @as(i64, @intCast(max_chunks)) or decoded_len > scratch.len or decoded_len > max_bytes -| self.total_bytes) return .failed;
        std.base64.standard.Decoder.decode(scratch[0..decoded_len], encoded) catch return .failed;
        const header_copy_len = @min(decoded_len, self.header.len - self.header_len);
        if (header_copy_len > 0) {
            @memcpy(self.header[self.header_len .. self.header_len + header_copy_len], scratch[0..header_copy_len]);
            self.header_len += header_copy_len;
        }
        self.total_bytes += decoded_len;
        self.next_seq += 1;
        self.saw_short_chunk = decoded_len < scratch.len;
        return .{ .chunk = scratch[0..decoded_len] };
    }

    fn feedResponse(self: *ScreenshotStreamValidator, response: cp.Response) Step {
        if (!cp.idEql(response.id, self.request_id)) return .failed;
        // 정상 JSON-RPC error 응답(unauthorized·surface 없음 등)은 stream 손상이 아니라 실제 결과다 — .failed로 일반
        // 메시지에 감추지 말고 caller가 원 응답을 renderResponse해 실제 code/message를 내게 한다(exec/wrapped와 동형 — 리뷰).
        if (response.err != null) {
            self.terminal = true;
            return .error_response;
        }
        const obj = switch (response.result orelse return .failed) {
            .object => |o| o,
            else => return .failed,
        };
        const final_capture_id = intField(obj.get("capture_id")) orelse return .failed;
        const seq_total = intField(obj.get("seq_total")) orelse return .failed;
        const total_bytes = intField(obj.get("bytes")) orelse return .failed;
        const width = intField(obj.get("width")) orelse return .failed;
        const height = intField(obj.get("height")) orelse return .failed;
        const format = switch (obj.get("format") orelse return .failed) {
            .string => |s| s,
            else => return .failed,
        };
        if (self.capture_id == null or final_capture_id != self.capture_id.? or seq_total != self.next_seq or total_bytes != self.total_bytes) return .failed;
        if (!eq(format, "png") or width <= 0 or height <= 0 or width > std.math.maxInt(u32) or height > std.math.maxInt(u32)) return .failed;
        const dims = cp.pngDimensions(self.header[0..self.header_len]) orelse return .failed;
        if (dims.width != width or dims.height != height) return .failed;
        self.width = dims.width;
        self.height = dims.height;
        self.terminal = true;
        return .done;
    }
};

const testing = std.testing;

test "parse: navigate/get-url/exec/get-cookies + --surface" {
    switch (try parse(&.{ "navigate", "--surface", "11", "https://a/" })) {
        .request => |r| {
            try testing.expectEqual(@as(u64, 11), r.navigate.surface_id);
            try testing.expectEqualStrings("https://a/", r.navigate.url);
        },
        else => return error.Unexpected,
    }
    // --surface=N 형태 + 순서 무관(url 먼저).
    switch (try parse(&.{ "navigate", "https://b/", "--surface=7" })) {
        .request => |r| try testing.expectEqual(@as(u64, 7), r.navigate.surface_id),
        else => return error.Unexpected,
    }
    try testing.expectEqual(@as(u64, 3), (try parse(&.{ "get-url", "--surface", "3" })).request.get_url.surface_id);
    switch (try parse(&.{ "exec", "--surface", "5", "document.title" })) {
        .request => |r| try testing.expectEqualStrings("document.title", r.exec.script),
        else => return error.Unexpected,
    }
    try testing.expectEqual(@as(u64, 9), (try parse(&.{ "get-cookies", "--surface", "9" })).request.get_cookies.surface_id);
}

test "parse exec: args와 max result와 out을 순서 무관하게 적용" {
    switch (try parse(&.{ "exec", "--out", "result.json", "--args", "[40,2]", "--max-result-bytes", "524289", "--surface", "5", "Promise.resolve(args[0]+args[1])" })) {
        .request => |request| {
            try testing.expectEqual(@as(u64, 5), request.exec.surface_id);
            try testing.expectEqual(@as(usize, 524289), request.exec.max_result_bytes);
            try testing.expectEqualStrings("result.json", request.exec.out.?);
            try testing.expectEqualStrings("[40,2]", request.exec.args_json.?);
            try testing.expectEqualStrings("Promise.resolve(args[0]+args[1])", request.exec.script);
        },
        else => return error.Unexpected,
    }
    try testing.expectError(error.InvalidMaxResultBytes, parse(&.{ "exec", "--surface", "5", "--max-result-bytes", "0", "1" }));
    try testing.expectError(error.InvalidMaxResultBytes, parse(&.{ "exec", "--surface", "5", "--max-result-bytes", "16777217", "1" }));
    try testing.expectError(error.MissingArgsValue, parse(&.{ "exec", "--surface", "5", "--args" }));
}

test "parse: --help → .help(파싱보다 우선)" {
    try testing.expect((try parse(&.{ "navigate", "--surface", "1", "--help" })) == .help);
    try testing.expect((try parse(&.{"-h"})) == .help);
}

test "parse: 에러 케이스" {
    try testing.expectError(error.MissingSubcommand, parse(&.{}));
    try testing.expectError(error.UnknownSubcommand, parse(&.{"bogus"}));
    try testing.expectError(error.MissingSurface, parse(&.{ "navigate", "https://a/" })); // surface 없음
    try testing.expectError(error.MissingUrl, parse(&.{ "navigate", "--surface", "1" })); // url 없음
    try testing.expectError(error.MissingScript, parse(&.{ "exec", "--surface", "1" })); // script 없음
    try testing.expectError(error.InvalidSurface, parse(&.{ "get-url", "--surface", "-1" })); // 음수
    try testing.expectError(error.InvalidSurface, parse(&.{ "get-url", "--surface", "x" })); // 비숫자
    try testing.expectError(error.MissingSurfaceValue, parse(&.{ "get-url", "--surface" })); // 값 없음
    try testing.expectError(error.UnknownOption, parse(&.{ "get-url", "--surface", "1", "--bogus" }));
    try testing.expectError(error.UnexpectedArgument, parse(&.{ "get-url", "--surface", "1", "extra" })); // get-url은 위치 인자 없음
    try testing.expectError(error.UnexpectedArgument, parse(&.{ "navigate", "--surface", "1", "u1", "u2" })); // 둘째 위치 인자
}

test "buildRequestBytes: browser.* 메서드·params(camelCase 계약)" {
    // navigate {id, url}.
    {
        const b = try buildRequestBytes(testing.allocator, .{ .navigate = .{ .surface_id = 11, .url = "https://a/" } }, .{ .number = 1 });
        defer testing.allocator.free(b);
        var pm = try cp.parseMessage(testing.allocator, b);
        defer pm.deinit();
        try testing.expectEqualStrings("browser.navigate", pm.message.request.method);
        const p = pm.message.request.params.?.object;
        try testing.expectEqual(@as(i64, 11), p.get("id").?.integer);
        try testing.expectEqualStrings("https://a/", p.get("url").?.string);
    }
    // getUrl {id} — camelCase 메서드명.
    {
        const b = try buildRequestBytes(testing.allocator, .{ .get_url = .{ .surface_id = 3 } }, .{ .number = 1 });
        defer testing.allocator.free(b);
        var pm = try cp.parseMessage(testing.allocator, b);
        defer pm.deinit();
        try testing.expectEqualStrings("browser.getUrl", pm.message.request.method);
        try testing.expectEqual(@as(i64, 3), pm.message.request.params.?.object.get("id").?.integer);
    }
    // executeScript {id, script, args?, max_result_bytes}.
    {
        const b = try buildRequestBytes(testing.allocator, .{ .exec = .{ .surface_id = 5, .script = "Promise.resolve(args[0]+1)", .args_json = "[41]" } }, .{ .number = 1 });
        defer testing.allocator.free(b);
        var pm = try cp.parseMessage(testing.allocator, b);
        defer pm.deinit();
        try testing.expectEqualStrings("browser.executeScript", pm.message.request.method);
        const params = pm.message.request.params.?.object;
        try testing.expectEqualStrings("Promise.resolve(args[0]+1)", params.get("script").?.string);
        try testing.expectEqual(@as(i64, 41), params.get("args").?.array.items[0].integer);
        try testing.expectEqual(@as(i64, 16 * 1024 * 1024), params.get("max_result_bytes").?.integer);
    }
    try testing.expectError(error.InvalidArgs, buildRequestBytes(testing.allocator, .{ .exec = .{ .surface_id = 5, .script = "1", .args_json = "{}" } }, .{ .number = 1 }));
    try testing.expectError(error.InvalidArgs, buildRequestBytes(testing.allocator, .{ .exec = .{ .surface_id = 5, .script = "1", .args_json = "[" } }, .{ .number = 1 }));
    {
        const b = try buildRequestBytes(testing.allocator, .{ .exec = .{ .surface_id = 5, .script = "args[0]", .args_json = "[-0,9007199254740993.0,1e-400]" } }, .{ .number = 1 });
        defer testing.allocator.free(b);
        try testing.expect(std.mem.indexOf(u8, b, "[-0,9007199254740993.0,1e-400]") != null);
    }
    // getCookies {id}.
    {
        const b = try buildRequestBytes(testing.allocator, .{ .get_cookies = .{ .surface_id = 9 } }, .{ .number = 1 });
        defer testing.allocator.free(b);
        var pm = try cp.parseMessage(testing.allocator, b);
        defer pm.deinit();
        try testing.expectEqualStrings("browser.getCookies", pm.message.request.method);
    }
}

test "renderResponse: navigate ok·getUrl url·exec result·getCookies 배열·error" {
    var buf: [512]u8 = undefined;
    // navigate {ok:true} → "ok".
    {
        var w = std.Io.Writer.fixed(&buf);
        _ = try renderResponse(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ok\":true}}", .navigate, &w);
        try testing.expectEqualStrings("ok\n", w.buffered());
    }
    // getUrl {url} → url 한 줄.
    {
        var w = std.Io.Writer.fixed(&buf);
        _ = try renderResponse(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"url\":\"https://x/y\"}}", .get_url, &w);
        try testing.expectEqualStrings("https://x/y\n", w.buffered());
    }
    // exec {result} → 값 한 줄.
    {
        var w = std.Io.Writer.fixed(&buf);
        _ = try renderResponse(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"result\":\"My Page\"}}", .exec, &w);
        try testing.expectEqualStrings("My Page\n", w.buffered());
    }
    // getCookies {cookies:[...]} → JSON 배열 한 줄.
    {
        var w = std.Io.Writer.fixed(&buf);
        _ = try renderResponse(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"cookies\":[{\"name\":\"sid\",\"value\":\"v\"}]}}", .get_cookies, &w);
        try testing.expect(std.mem.indexOf(u8, w.buffered(), "\"name\":\"sid\"") != null);
    }
    // error 응답(미grant 거부) → 균일 "error: msg (code)".
    {
        var w = std.Io.Writer.fixed(&buf);
        _ = try renderResponse(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32002,\"message\":\"Unauthorized\"}}", .navigate, &w);
        try testing.expectEqualStrings("error: Unauthorized (-32002)\n" ++ unauthorized_hint, w.buffered());
    }
}

// ── screenshot(5f-1) 파서·wire·재조립 단위(§9.5.7) ──

test "parse: screenshot --surface + --out(선택), 위치 인자 금지" {
    switch (try parse(&.{ "screenshot", "--surface", "11" })) {
        .screenshot => |s| {
            try testing.expectEqual(@as(u64, 11), s.surface_id);
            try testing.expect(s.out == null); // 생략=stdout
        },
        else => return error.Unexpected,
    }
    switch (try parse(&.{ "screenshot", "--surface=3", "--out", "p.png" })) {
        .screenshot => |s| {
            try testing.expectEqual(@as(u64, 3), s.surface_id);
            try testing.expectEqualStrings("p.png", s.out.?);
        },
        else => return error.Unexpected,
    }
    switch (try parse(&.{ "screenshot", "--surface", "5", "--out=x.png" })) {
        .screenshot => |s| try testing.expectEqualStrings("x.png", s.out.?),
        else => return error.Unexpected,
    }
    // rect/scale(§9.5.7): 없으면 null, 있으면 [4]f64/f64. w/h>0·양수 검증.
    switch (try parse(&.{ "screenshot", "--surface", "3" })) {
        .screenshot => |s| {
            try testing.expect(s.rect == null);
            try testing.expect(s.scale == null);
        },
        else => return error.Unexpected,
    }
    switch (try parse(&.{ "screenshot", "--surface", "3", "--rect", "10,20,300,400", "--scale", "0.5" })) {
        .screenshot => |s| {
            try testing.expectEqual(@as(f64, 10), s.rect.?[0]);
            try testing.expectEqual(@as(f64, 20), s.rect.?[1]);
            try testing.expectEqual(@as(f64, 300), s.rect.?[2]);
            try testing.expectEqual(@as(f64, 400), s.rect.?[3]);
            try testing.expectEqual(@as(f64, 0.5), s.scale.?);
        },
        else => return error.Unexpected,
    }
    switch (try parse(&.{ "screenshot", "--surface=3", "--rect=0,0,100,50", "--scale=2" })) {
        .screenshot => |s| try testing.expectEqual(@as(f64, 2), s.scale.?),
        else => return error.Unexpected,
    }
    try testing.expectError(error.MissingSurface, parse(&.{ "screenshot", "--out", "p.png" }));
    try testing.expectError(error.MissingOutValue, parse(&.{ "screenshot", "--surface", "1", "--out" }));
    try testing.expectError(error.MissingRectValue, parse(&.{ "screenshot", "--surface", "1", "--rect" }));
    try testing.expectError(error.MissingScaleValue, parse(&.{ "screenshot", "--surface", "1", "--scale" }));
    try testing.expectError(error.InvalidRect, parse(&.{ "screenshot", "--surface", "1", "--rect", "1,2,3" })); // 3개
    try testing.expectError(error.InvalidRect, parse(&.{ "screenshot", "--surface", "1", "--rect", "0,0,0,100" })); // width 0
    try testing.expectError(error.InvalidRect, parse(&.{ "screenshot", "--surface", "1", "--rect", "0,0,x,1" })); // 비수치
    try testing.expectError(error.InvalidScale, parse(&.{ "screenshot", "--surface", "1", "--scale", "0" })); // 양수 아님
    try testing.expectError(error.InvalidScale, parse(&.{ "screenshot", "--surface", "1", "--scale", "-1" }));
    try testing.expectError(error.UnexpectedArgument, parse(&.{ "screenshot", "--surface", "1", "extra" })); // 위치 인자 금지
    try testing.expectError(error.UnknownOption, parse(&.{ "screenshot", "--surface", "1", "--bogus" }));
}

// JSON 수치(integer/float)를 f64로 — 정수값 float가 .integer로 직렬화되는 round-trip 관대 비교(테스트 전용).
fn jsonNum(v: std.json.Value) f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => std.math.nan(f64),
    };
}

test "buildScreenshotRequestBytes: browser.screenshot {id} + rect/scale" {
    // 기본(rect/scale 없음)=id만.
    {
        const b = try buildScreenshotRequestBytes(testing.allocator, .{ .surface_id = 11, .out = null }, .{ .number = 1 });
        defer testing.allocator.free(b);
        var pm = try cp.parseMessage(testing.allocator, b);
        defer pm.deinit();
        try testing.expectEqualStrings("browser.screenshot", pm.message.request.method);
        const obj = pm.message.request.params.?.object;
        try testing.expectEqual(@as(i64, 11), obj.get("id").?.integer);
        try testing.expect(obj.get("rect") == null);
        try testing.expect(obj.get("scale") == null);
    }
    // rect+scale → params에 {rect:{x,y,width,height}, scale}.
    {
        const b = try buildScreenshotRequestBytes(testing.allocator, .{ .surface_id = 3, .out = null, .rect = .{ 10, 20, 300, 400 }, .scale = 0.5 }, .{ .number = 1 });
        defer testing.allocator.free(b);
        var pm = try cp.parseMessage(testing.allocator, b);
        defer pm.deinit();
        const obj = pm.message.request.params.?.object;
        const ro = obj.get("rect").?.object;
        // 정수값 f64(10·400)는 "10"/"400"으로 직렬화돼 .integer로 파싱될 수 있어 관대 비교.
        try testing.expectEqual(@as(f64, 10), jsonNum(ro.get("x").?));
        try testing.expectEqual(@as(f64, 400), jsonNum(ro.get("height").?));
        try testing.expectEqual(@as(f64, 0.5), jsonNum(obj.get("scale").?));
    }
}

test "ExecuteScriptStreamValidator: chunked와 inline 결과를 bounded 검증" {
    const request_id: cp.Id = .{ .number = 1 };
    var scratch: [512 * 1024]u8 = undefined;
    {
        var validator = ExecuteScriptStreamValidator.init(testing.allocator, request_id, 16 * 1024 * 1024);
        defer validator.deinit();
        const chunk = "{\"jsonrpc\":\"2.0\",\"method\":\"browser.executeScriptChunk\",\"params\":{\"request_id\":1,\"result_id\":7,\"seq\":0,\"encoding\":\"base64-json\",\"data\":\"eyJhIjoxfQ==\"}}";
        switch (try validator.feed(chunk, &scratch)) {
            .chunk => |bytes| try testing.expectEqualStrings("{\"a\":1}", bytes),
            else => return error.Unexpected,
        }
        try testing.expect((try validator.feed("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"transfer\":\"chunked\",\"result_id\":7,\"seq_total\":1,\"bytes\":7}}", &scratch)) == .done);
    }
    {
        var validator = ExecuteScriptStreamValidator.init(testing.allocator, request_id, 512 * 1024);
        defer validator.deinit();
        switch (try validator.feed("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"transfer\":\"inline\",\"result\":[1,true,null]}}", &scratch)) {
            .inline_result => |bytes| try testing.expectEqualStrings("[1,true,null]", bytes),
            else => return error.Unexpected,
        }
    }
    {
        // 정상 JSON-RPC error 응답(script_error 등, id 일치)은 stream 손상(.failed) 아니라 **실제 결과** → .error_response
        // (caller가 원 응답을 renderResponse해 실제 code/message를 냄 — 일반 "잘못된 stream"으로 감추던 회귀 가드, 리뷰).
        var errv = ExecuteScriptStreamValidator.init(testing.allocator, request_id, 512 * 1024);
        defer errv.deinit();
        try testing.expect((try errv.feed("{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32006,\"message\":\"script error\"}}", &scratch)) == .error_response);
        // id 불일치 error는 여전히 stream 손상 → .failed(엉뚱한 응답을 정상 error로 오인 금지).
        var mism = ExecuteScriptStreamValidator.init(testing.allocator, request_id, 512 * 1024);
        defer mism.deinit();
        try testing.expect((try mism.feed("{\"jsonrpc\":\"2.0\",\"id\":2,\"error\":{\"code\":-32006,\"message\":\"x\"}}", &scratch)) == .failed);
    }
    {
        var empty = ExecuteScriptStreamValidator.init(testing.allocator, request_id, 16 * 1024 * 1024);
        defer empty.deinit();
        const empty_chunk = "{\"jsonrpc\":\"2.0\",\"method\":\"browser.executeScriptChunk\",\"params\":{\"request_id\":1,\"result_id\":7,\"seq\":0,\"encoding\":\"base64-json\",\"data\":\"\"}}";
        try testing.expect((try empty.feed(empty_chunk, &scratch)) == .failed);

        var short = ExecuteScriptStreamValidator.init(testing.allocator, request_id, 16 * 1024 * 1024);
        defer short.deinit();
        const short0 = "{\"jsonrpc\":\"2.0\",\"method\":\"browser.executeScriptChunk\",\"params\":{\"request_id\":1,\"result_id\":7,\"seq\":0,\"encoding\":\"base64-json\",\"data\":\"e30=\"}}";
        const short1 = "{\"jsonrpc\":\"2.0\",\"method\":\"browser.executeScriptChunk\",\"params\":{\"request_id\":1,\"result_id\":7,\"seq\":1,\"encoding\":\"base64-json\",\"data\":\"e30=\"}}";
        try testing.expect((try short.feed(short0, &scratch)) == .chunk);
        try testing.expect((try short.feed(short1, &scratch)) == .failed);
    }
}

test "WrappedResultStreamValidator(§9.5.10): snapshot/console chunked 재조립·inline·에러·실패 경로" {
    const request_id: cp.Id = .{ .number = 1 };
    var scratch: [512 * 1024]u8 = undefined;
    // chunked: snapshotChunk(base64-json) → .chunk(raw 트리 바이트), transfer:"chunked" final → .done.
    {
        var v = WrappedResultStreamValidator.init(testing.allocator, request_id, snapshot_chunk_method, 16 * 1024 * 1024);
        const chunk = "{\"jsonrpc\":\"2.0\",\"method\":\"browser.snapshotChunk\",\"params\":{\"request_id\":1,\"result_id\":7,\"seq\":0,\"encoding\":\"base64-json\",\"data\":\"eyJhIjoxfQ==\"}}";
        switch (v.feed(chunk, &scratch)) {
            .chunk => |bytes| try testing.expectEqualStrings("{\"a\":1}", bytes), // 7 bytes
            else => return error.Unexpected,
        }
        try testing.expect(v.feed("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"transfer\":\"chunked\",\"result_id\":7,\"seq_total\":1,\"bytes\":7}}", &scratch) == .done);
    }
    // inline `{result:{snapshot:...}}`(transfer envelope 없음) → .inline_terminal(caller가 그대로 렌더).
    {
        var v = WrappedResultStreamValidator.init(testing.allocator, request_id, snapshot_chunk_method, 16 * 1024 * 1024);
        try testing.expect(v.feed("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"snapshot\":{\"tree\":[]}}}", &scratch) == .inline_terminal);
    }
    // 에러 응답도 그대로 렌더 대상 → .inline_terminal(프로토콜 위반 아님).
    {
        var v = WrappedResultStreamValidator.init(testing.allocator, request_id, snapshot_chunk_method, 16 * 1024 * 1024);
        try testing.expect(v.feed("{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32000,\"message\":\"no surface\"}}", &scratch) == .inline_terminal);
    }
    // 실패: 빈 chunk data.
    {
        var v = WrappedResultStreamValidator.init(testing.allocator, request_id, snapshot_chunk_method, 16 * 1024 * 1024);
        const empty = "{\"jsonrpc\":\"2.0\",\"method\":\"browser.snapshotChunk\",\"params\":{\"request_id\":1,\"result_id\":7,\"seq\":0,\"encoding\":\"base64-json\",\"data\":\"\"}}";
        try testing.expect(v.feed(empty, &scratch) == .failed);
    }
    // 실패: final bytes가 누적과 불일치(누락/변조 감지).
    {
        var v = WrappedResultStreamValidator.init(testing.allocator, request_id, snapshot_chunk_method, 16 * 1024 * 1024);
        const chunk = "{\"jsonrpc\":\"2.0\",\"method\":\"browser.snapshotChunk\",\"params\":{\"request_id\":1,\"result_id\":7,\"seq\":0,\"encoding\":\"base64-json\",\"data\":\"eyJhIjoxfQ==\"}}";
        try testing.expect(v.feed(chunk, &scratch) == .chunk);
        try testing.expect(v.feed("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"transfer\":\"chunked\",\"result_id\":7,\"seq_total\":1,\"bytes\":8}}", &scratch) == .failed);
    }
    // 실패: seq 불연속(첫 조각이 seq=1).
    {
        var v = WrappedResultStreamValidator.init(testing.allocator, request_id, snapshot_chunk_method, 16 * 1024 * 1024);
        const bad_seq = "{\"jsonrpc\":\"2.0\",\"method\":\"browser.snapshotChunk\",\"params\":{\"request_id\":1,\"result_id\":7,\"seq\":1,\"encoding\":\"base64-json\",\"data\":\"eyJhIjoxfQ==\"}}";
        try testing.expect(v.feed(bad_seq, &scratch) == .failed);
    }
    // 통일-2: 같은 validator를 console_chunk_method로 — consoleChunk 재조립 + inline `{console:[…]}` → .inline_terminal.
    {
        var v = WrappedResultStreamValidator.init(testing.allocator, request_id, console_chunk_method, 16 * 1024 * 1024);
        const chunk = "{\"jsonrpc\":\"2.0\",\"method\":\"browser.consoleChunk\",\"params\":{\"request_id\":1,\"result_id\":9,\"seq\":0,\"encoding\":\"base64-json\",\"data\":\"eyJhIjoxfQ==\"}}";
        switch (v.feed(chunk, &scratch)) {
            .chunk => |bytes| try testing.expectEqualStrings("{\"a\":1}", bytes),
            else => return error.Unexpected,
        }
        try testing.expect(v.feed("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"transfer\":\"chunked\",\"result_id\":9,\"seq_total\":1,\"bytes\":7}}", &scratch) == .done);
    }
    {
        var v = WrappedResultStreamValidator.init(testing.allocator, request_id, console_chunk_method, 16 * 1024 * 1024);
        try testing.expect(v.feed("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"console\":[]}}", &scratch) == .inline_terminal);
    }
    // chunk_method 게이팅: snapshot 검증기는 consoleChunk를 자기 chunk로 안 봄 → .need_more(무시).
    {
        var v = WrappedResultStreamValidator.init(testing.allocator, request_id, snapshot_chunk_method, 16 * 1024 * 1024);
        const console_chunk = "{\"jsonrpc\":\"2.0\",\"method\":\"browser.consoleChunk\",\"params\":{\"request_id\":1,\"result_id\":9,\"seq\":0,\"encoding\":\"base64-json\",\"data\":\"eyJhIjoxfQ==\"}}";
        try testing.expect(v.feed(console_chunk, &scratch) == .need_more);
    }
}

test "ScreenshotStreamValidator: PNG header와 terminal byte metadata를 검증" {
    var validator = ScreenshotStreamValidator.init(.{ .number = 1 });
    var scratch: [512 * 1024]u8 = undefined;
    const chunk = "{\"jsonrpc\":\"2.0\",\"method\":\"browser.screenshotChunk\",\"params\":{\"capture_id\":9,\"seq\":0,\"encoding\":\"base64\",\"data\":\"iVBORw0KGgoAAAANSUhEUgAAAAMAAAAE\"}}";
    switch (try validator.feed(testing.allocator, chunk, &scratch)) {
        .chunk => |bytes| try testing.expectEqual(@as(usize, 24), bytes.len),
        else => return error.Unexpected,
    }
    try testing.expect((try validator.feed(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"capture_id\":9,\"seq_total\":1,\"bytes\":24,\"width\":3,\"height\":4,\"format\":\"png\"}}", &scratch)) == .done);
    try testing.expectEqual(@as(u32, 3), validator.width);
    try testing.expectEqual(@as(u32, 4), validator.height);

    var mismatch = ScreenshotStreamValidator.init(.{ .number = 1 });
    _ = try mismatch.feed(testing.allocator, chunk, &scratch);
    try testing.expect((try mismatch.feed(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"capture_id\":9,\"seq_total\":1,\"bytes\":23,\"width\":3,\"height\":4,\"format\":\"png\"}}", &scratch)) == .failed);

    var empty = ScreenshotStreamValidator.init(.{ .number = 1 });
    try testing.expect((try empty.feed(testing.allocator, "{\"jsonrpc\":\"2.0\",\"method\":\"browser.screenshotChunk\",\"params\":{\"capture_id\":9,\"seq\":0,\"encoding\":\"base64\",\"data\":\"\"}}", &scratch)) == .failed);

    // 정상 JSON-RPC error 응답(id 일치, unauthorized·surface 없음 등)은 stream 손상 아니라 실제 결과 → .error_response
    // (caller가 renderResponse해 실제 code/message를 냄 — 리뷰 회귀 가드). id 불일치 error는 여전히 .failed.
    var errv = ScreenshotStreamValidator.init(.{ .number = 1 });
    try testing.expect((try errv.feed(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32002,\"message\":\"Unauthorized\"}}", &scratch)) == .error_response);
    var errmis = ScreenshotStreamValidator.init(.{ .number = 1 });
    try testing.expect((try errmis.feed(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":2,\"error\":{\"code\":-32002,\"message\":\"Unauthorized\"}}", &scratch)) == .failed);
}

// ── browser list(§9.6 발견) 파서·wire·렌더 단위 ──

test "parse: list(surface 불요), 남는 인자는 에러" {
    try testing.expect((try parse(&.{"list"})).request == .list);
    try testing.expectError(error.UnexpectedArgument, parse(&.{ "list", "extra" }));
    try testing.expectError(error.UnknownOption, parse(&.{ "list", "--surface", "1" })); // list는 surface 안 받음
}

test "buildRequestBytes: browser.list(params 없음)" {
    const b = try buildRequestBytes(testing.allocator, .list, .{ .number = 1 });
    defer testing.allocator.free(b);
    var pm = try cp.parseMessage(testing.allocator, b);
    defer pm.deinit();
    try testing.expectEqualStrings("browser.list", pm.message.request.method);
    try testing.expect(pm.message.request.params == null);
}

test "renderResponse(list): surface별 한 줄(id·panel_kind·url·title), 빈 목록 안내" {
    // 정상: web surface 2개 → 각 한 줄.
    {
        var buf: [512]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        _ = try renderResponse(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"surfaces\":[{\"id\":3,\"url\":\"https://naver.com/\",\"title\":\"Browser\",\"panel_kind\":\"browser\"},{\"id\":7,\"url\":\"\",\"title\":\"docs\",\"panel_kind\":\"markdown\"}]}}", .list, &w);
        const out = w.buffered();
        try testing.expect(std.mem.indexOf(u8, out, "surface 3  browser  https://naver.com/  \"Browser\"") != null);
        try testing.expect(std.mem.indexOf(u8, out, "surface 7  markdown  ") != null);
    }
    // W9-0: 엔진과 「지원하는 명령 없음」을 줄 끝에 — 앞 칸은 그대로다.
    {
        var buf: [512]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        _ = try renderResponse(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"surfaces\":[{\"id\":3,\"url\":\"https://a/\",\"title\":\"A\",\"panel_kind\":\"browser\",\"engine\":\"webkit\",\"methods\":[\"navigate\"]},{\"id\":4,\"url\":\"https://b/\",\"title\":\"B\",\"panel_kind\":\"browser\",\"engine\":\"chromium\",\"methods\":[]}]}}", .list, &w);
        const out = w.buffered();
        try testing.expect(std.mem.indexOf(u8, out, "surface 3  browser  https://a/  \"A\"  engine=webkit\n") != null);
        try testing.expect(std.mem.indexOf(u8, out, "surface 4  browser  https://b/  \"B\"  engine=chromium (browser commands not supported yet)\n") != null);
    }
    // 브라우저 탭이 아닌 web 패널(파일 HTML 뷰 — panel_kind 는 browser).
    {
        var buf: [512]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        _ = try renderResponse(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"surfaces\":[{\"id\":5,\"url\":\"\",\"title\":\"p.html\",\"panel_kind\":\"browser\",\"engine\":\"webkit\",\"controllable\":false,\"methods\":[]}]}}", .list, &w);
        try testing.expectEqualStrings("surface 5  browser    \"p.html\"  engine=webkit (not a browser tab — browser commands do not apply)\n", w.buffered());
    }
    // `-32008` 은 data 의 엔진(과 브라우저 탭 아님)을 붙인다.
    {
        var buf: [256]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        _ = try renderResponse(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32008,\"message\":\"Not supported by this browser engine\",\"data\":{\"engine\":\"chromium\"}}}", .navigate, &w);
        try testing.expectEqualStrings("error: Not supported by this browser engine (-32008) [engine=chromium]\n", w.buffered());
        w = std.Io.Writer.fixed(&buf);
        _ = try renderResponse(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32008,\"message\":\"Not supported by this browser engine\",\"data\":{\"engine\":\"webkit\",\"controllable\":false}}}", .navigate, &w);
        try testing.expectEqualStrings("error: Not supported by this browser engine (-32008) [not a browser tab] [engine=webkit]\n", w.buffered());
    }
    // 빈 목록.
    {
        var buf: [128]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        _ = try renderResponse(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"surfaces\":[]}}", .list, &w);
        try testing.expectEqualStrings("(no web surfaces)\n", w.buffered());
    }
}

// ── cookie write(§9.4 D4) 파서·wire·렌더 단위 ──

test "parse: set-cookie/delete-cookie 옵션·양형태·에러" {
    switch (try parse(&.{ "set-cookie", "--surface", "3", "--name", "sid", "--value", "abc", "--domain", "x.com", "--path", "/a", "--secure" })) {
        .request => |r| {
            try testing.expectEqual(@as(u64, 3), r.set_cookie.surface_id);
            try testing.expectEqualStrings("sid", r.set_cookie.name);
            try testing.expectEqualStrings("abc", r.set_cookie.value);
            try testing.expectEqualStrings("x.com", r.set_cookie.domain.?);
            try testing.expectEqualStrings("/a", r.set_cookie.path.?);
            try testing.expect(r.set_cookie.secure);
        },
        else => return error.Unexpected,
    }
    // --opt=val 형태 + 최소(name/value).
    switch (try parse(&.{ "set-cookie", "--surface=5", "--name=n", "--value=v" })) {
        .request => |r| {
            try testing.expectEqual(@as(u64, 5), r.set_cookie.surface_id);
            try testing.expect(r.set_cookie.domain == null and !r.set_cookie.secure);
        },
        else => return error.Unexpected,
    }
    switch (try parse(&.{ "delete-cookie", "--surface", "3", "--name", "sid" })) {
        .request => |r| {
            try testing.expectEqualStrings("sid", r.delete_cookie.name);
            try testing.expect(r.delete_cookie.domain == null);
        },
        else => return error.Unexpected,
    }
    try testing.expectError(error.MissingSurface, parse(&.{ "set-cookie", "--name", "n", "--value", "v" }));
    try testing.expectError(error.MissingName, parse(&.{ "set-cookie", "--surface", "1", "--value", "v" }));
    try testing.expectError(error.MissingValue, parse(&.{ "set-cookie", "--surface", "1", "--name", "n" }));
    try testing.expectError(error.MissingName, parse(&.{ "delete-cookie", "--surface", "1" }));
    try testing.expectError(error.MissingOptionValue, parse(&.{ "set-cookie", "--surface", "1", "--name" }));
    try testing.expectError(error.UnknownOption, parse(&.{ "set-cookie", "--surface", "1", "--name", "n", "--value", "v", "--bogus" }));
    try testing.expectError(error.UnexpectedArgument, parse(&.{ "set-cookie", "--surface", "1", "--name", "n", "--value", "v", "extra" }));
}

test "buildRequestBytes: setCookie/deleteCookie params(선택 필드 생략)" {
    {
        const b = try buildRequestBytes(testing.allocator, .{ .set_cookie = .{ .surface_id = 11, .name = "n", .value = "v", .domain = "x.com", .path = null, .secure = true } }, .{ .number = 1 });
        defer testing.allocator.free(b);
        var pm = try cp.parseMessage(testing.allocator, b);
        defer pm.deinit();
        try testing.expectEqualStrings("browser.setCookie", pm.message.request.method);
        const p = pm.message.request.params.?.object;
        try testing.expectEqualStrings("n", p.get("name").?.string);
        try testing.expectEqualStrings("x.com", p.get("domain").?.string);
        try testing.expect(p.get("secure").?.bool);
        try testing.expect(p.get("path") == null); // 생략
    }
    {
        const b = try buildRequestBytes(testing.allocator, .{ .delete_cookie = .{ .surface_id = 11, .name = "n", .domain = null, .path = null } }, .{ .number = 1 });
        defer testing.allocator.free(b);
        var pm = try cp.parseMessage(testing.allocator, b);
        defer pm.deinit();
        try testing.expectEqualStrings("browser.deleteCookie", pm.message.request.method);
        try testing.expect(pm.message.request.params.?.object.get("secure") == null); // delete엔 secure 없음
    }
}

test "renderResponse(ok): setCookie {ok:true} → ok" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    _ = try renderResponse(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ok\":true}}", .ok, &w);
    try testing.expectEqualStrings("ok\n", w.buffered());
}

// ── localStorage/clear(§9.4 D4) 파서·wire·렌더 단위 ──

test "parse: get/set/remove-local-storage·clear-storage·에러" {
    switch (try parse(&.{ "get-local-storage", "--surface", "3", "--key", "tok" })) {
        .request => |r| {
            try testing.expectEqual(@as(u64, 3), r.get_local_storage.surface_id);
            try testing.expectEqualStrings("tok", r.get_local_storage.key);
        },
        else => return error.Unexpected,
    }
    switch (try parse(&.{ "set-local-storage", "--surface=3", "--key=k", "--value=v" })) {
        .request => |r| {
            try testing.expectEqualStrings("k", r.set_local_storage.key);
            try testing.expectEqualStrings("v", r.set_local_storage.value);
        },
        else => return error.Unexpected,
    }
    try testing.expectEqual(@as(u64, 5), (try parse(&.{ "remove-local-storage", "--surface", "5", "--key", "k" })).request.remove_local_storage.surface_id);
    try testing.expectEqual(@as(u64, 7), (try parse(&.{ "clear-storage", "--surface", "7" })).request.clear_storage.surface_id);
    try testing.expectError(error.MissingKey, parse(&.{ "get-local-storage", "--surface", "1" }));
    try testing.expectError(error.MissingValue, parse(&.{ "set-local-storage", "--surface", "1", "--key", "k" }));
    try testing.expectError(error.MissingSurface, parse(&.{"clear-storage"})); // --surface 없음
    try testing.expectError(error.UnexpectedArgument, parse(&.{ "clear-storage", "--surface", "1", "extra" }));
}

test "buildRequestBytes: localStorage/clear 메서드·params" {
    {
        const b = try buildRequestBytes(testing.allocator, .{ .get_local_storage = .{ .surface_id = 11, .key = "tok" } }, .{ .number = 1 });
        defer testing.allocator.free(b);
        var pm = try cp.parseMessage(testing.allocator, b);
        defer pm.deinit();
        try testing.expectEqualStrings("browser.getLocalStorage", pm.message.request.method);
        try testing.expectEqualStrings("tok", pm.message.request.params.?.object.get("key").?.string);
        try testing.expect(pm.message.request.params.?.object.get("value") == null); // get엔 value 없음
    }
    {
        const b = try buildRequestBytes(testing.allocator, .{ .set_local_storage = .{ .surface_id = 11, .key = "k", .value = "v" } }, .{ .number = 1 });
        defer testing.allocator.free(b);
        var pm = try cp.parseMessage(testing.allocator, b);
        defer pm.deinit();
        try testing.expectEqualStrings("browser.setLocalStorage", pm.message.request.method);
        try testing.expectEqualStrings("v", pm.message.request.params.?.object.get("value").?.string);
    }
    {
        const b = try buildRequestBytes(testing.allocator, .{ .clear_storage = .{ .surface_id = 11 } }, .{ .number = 1 });
        defer testing.allocator.free(b);
        var pm = try cp.parseMessage(testing.allocator, b);
        defer pm.deinit();
        try testing.expectEqualStrings("browser.clearStorage", pm.message.request.method);
    }
}

test "parse·build: back·forward·reload(W9b①) — surface 만" {
    try testing.expectEqual(@as(u64, 7), (try parse(&.{ "back", "--surface", "7" })).request.back.surface_id);
    try testing.expectEqual(@as(u64, 8), (try parse(&.{ "forward", "--surface", "8" })).request.forward.surface_id);
    try testing.expectEqual(@as(u64, 9), (try parse(&.{ "reload", "--surface", "9" })).request.reload.surface_id);
    try testing.expectError(error.MissingSurface, parse(&.{"back"}));
    try testing.expectError(error.UnexpectedArgument, parse(&.{ "reload", "--surface", "1", "x" }));
    inline for (.{ .{ "back", "browser.back" }, .{ "forward", "browser.forward" }, .{ "reload", "browser.reload" } }) |c| {
        const req = (try parse(&.{ c[0], "--surface", "11" })).request;
        const b = try buildRequestBytes(testing.allocator, req, .{ .number = 1 });
        defer testing.allocator.free(b);
        var pm = try cp.parseMessage(testing.allocator, b);
        defer pm.deinit();
        try testing.expectEqualStrings(c[1], pm.message.request.method);
        try testing.expectEqual(@as(i64, 11), pm.message.request.params.?.object.get("id").?.integer);
    }
}

test "renderResponse(value): getLocalStorage {value} → 값 출력" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    _ = try renderResponse(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"value\":\"hello\"}}", .value, &w);
    try testing.expectEqualStrings("hello\n", w.buffered());
}

// ── act(5f-2) 파서·wire 단위 ──

test "parse: click/type/scroll locator selector·ref·에러" {
    switch (try parse(&.{ "click", "--surface", "3", "--selector", "#btn" })) {
        .request => |r| try testing.expectEqualStrings("#btn", r.click.locator.selector),
        else => return error.Unexpected,
    }
    // --ref(§9.5.4 snapshot-2) — selector 대안.
    switch (try parse(&.{ "click", "--surface", "3", "--ref", "e4" })) {
        .request => |r| try testing.expectEqualStrings("e4", r.click.locator.ref),
        else => return error.Unexpected,
    }
    switch (try parse(&.{ "type", "--surface=3", "--ref=e2", "--text=hi" })) {
        .request => |r| {
            try testing.expectEqualStrings("e2", r.type_text.locator.ref);
            try testing.expectEqualStrings("hi", r.type_text.text);
        },
        else => return error.Unexpected,
    }
    try testing.expectEqual(@as(u64, 5), (try parse(&.{ "scroll", "--surface", "5", "--selector", ".x" })).request.scroll.surface_id);
    // locator 미지정·배타 위반.
    try testing.expectError(error.MissingLocator, parse(&.{ "click", "--surface", "1" }));
    try testing.expectError(error.ConflictingLocator, parse(&.{ "click", "--surface", "1", "--selector", "#b", "--ref", "e1" }));
    try testing.expectError(error.MissingText, parse(&.{ "type", "--surface", "1", "--selector", "#i" }));
    try testing.expectError(error.MissingSurface, parse(&.{ "click", "--selector", "#b" }));
}

test "parse·buildRequestBytes: hover·press(W9b①b-2) — press 는 --key 필수, 대상은 없어도 된다" {
    try testing.expectEqualStrings("#h", (try parse(&.{ "hover", "--surface", "3", "--selector", "#h" })).request.hover.locator.selector);
    try testing.expectError(error.MissingLocator, parse(&.{ "hover", "--surface", "3" }));
    const bare = (try parse(&.{ "press", "--surface", "3", "--key", "Enter" })).request.press;
    try testing.expectEqualStrings("Enter", bare.key);
    try testing.expect(bare.locator == null);
    try testing.expectEqualStrings("n7", (try parse(&.{ "press", "--surface=3", "--key=Meta+a", "--ref=n7" })).request.press.locator.?.ref);
    try testing.expectError(error.MissingPressKey, parse(&.{ "press", "--surface", "3", "--selector", "#i" }));
    try testing.expectError(error.ConflictingLocator, parse(&.{ "press", "--surface", "3", "--key", "a", "--selector", "#i", "--ref", "n1" }));
    const b = try buildRequestBytes(testing.allocator, .{ .press = .{ .surface_id = 11, .key = "Shift+Tab", .locator = .{ .selector = "#i" } } }, .{ .number = 1 });
    defer testing.allocator.free(b);
    var pm = try cp.parseMessage(testing.allocator, b);
    defer pm.deinit();
    try testing.expectEqualStrings("browser.press", pm.message.request.method);
    const params = pm.message.request.params.?.object;
    try testing.expectEqualStrings("Shift+Tab", params.get("key").?.string);
    try testing.expectEqualStrings("#i", params.get("selector").?.string);
}

test "parse·buildRequestBytes: role 로케이터(W9b②) — 옵션 규칙·act 명령은 다른 명령의 옵션을 받지 않는다" {
    const r = (try parse(&.{ "click", "--surface", "3", "--role", "button", "--name", "Save", "--exact", "--nth", "1" })).request.click.locator.role;
    try testing.expectEqualStrings("button", r.role);
    try testing.expectEqualStrings("Save", r.name.?);
    try testing.expect(r.exact);
    try testing.expectEqual(@as(u32, 1), r.nth.?);
    try testing.expectEqual(@as(u32, 2), (try parse(&.{ "press", "--surface=3", "--key=Enter", "--role=heading", "--level=2" })).request.press.locator.?.role.level.?);
    try testing.expectError(error.ConflictingLocator, parse(&.{ "click", "--surface", "3", "--role", "button", "--selector", "#b" }));
    try testing.expectError(error.LocatorOptionWithoutRole, parse(&.{ "click", "--surface", "3", "--name", "Save" }));
    try testing.expectError(error.LocatorOptionWithoutRole, parse(&.{ "press", "--surface", "3", "--key", "a", "--nth", "0" }));
    try testing.expectError(error.ExactWithoutName, parse(&.{ "click", "--surface", "3", "--role", "button", "--exact" }));
    try testing.expectError(error.InvalidLocatorNumber, parse(&.{ "click", "--surface", "3", "--role", "heading", "--level", "0" }));
    try testing.expectError(error.UnknownOption, parse(&.{ "click", "--surface", "3", "--selector", "#b", "--value", "x" }));
    try testing.expectError(error.UnknownOption, parse(&.{ "click", "--surface", "3", "--selector", "#b", "--text", "x" }));
    try testing.expectError(error.UnknownOption, parse(&.{ "scroll", "--surface", "3", "--selector", "#b", "--key", "x" }));
    const b = try buildRequestBytes(testing.allocator, .{ .type_text = .{ .surface_id = 11, .locator = .{ .role = .{ .role = "textbox", .name = "Email" } }, .text = "hi" } }, .{ .number = 1 });
    defer testing.allocator.free(b);
    var pm = try cp.parseMessage(testing.allocator, b);
    defer pm.deinit();
    const params = pm.message.request.params.?.object;
    try testing.expectEqualStrings("textbox", params.get("locator").?.object.get("role").?.string);
    try testing.expectEqualStrings("Email", params.get("locator").?.object.get("name").?.string);
    try testing.expectEqualStrings("hi", params.get("text").?.string);
    try testing.expect(params.get("selector") == null);
}

test "parse·buildRequestBytes: --by-text·--by-label(W9b②-2) — exact·nth 는 셋 모두와, name·level 은 role 과만" {
    const t = (try parse(&.{ "click", "--surface", "3", "--by-text", "Sign in", "--exact", "--nth", "2" })).request.click.locator.text;
    try testing.expectEqualStrings("Sign in", t.value);
    try testing.expect(t.exact);
    try testing.expectEqual(@as(u32, 2), t.nth.?);
    try testing.expectEqualStrings("Email", (try parse(&.{ "type", "--surface=3", "--by-label=Email", "--text=x" })).request.type_text.locator.label.value);
    try testing.expectError(error.ConflictingLocator, parse(&.{ "click", "--surface", "3", "--by-text", "a", "--by-label", "b" }));
    try testing.expectError(error.LocatorOptionWithoutRole, parse(&.{ "click", "--surface", "3", "--by-text", "a", "--name", "b" }));
    try testing.expectError(error.LocatorOptionWithoutRole, parse(&.{ "click", "--surface", "3", "--selector", "#a", "--exact" }));
    const b = try buildRequestBytes(testing.allocator, .{ .click = .{ .surface_id = 11, .locator = .{ .label = .{ .value = "Dark mode", .exact = true } } } }, .{ .number = 1 });
    defer testing.allocator.free(b);
    var pm = try cp.parseMessage(testing.allocator, b);
    defer pm.deinit();
    const loc = pm.message.request.params.?.object.get("locator").?.object;
    try testing.expectEqualStrings("Dark mode", loc.get("label").?.string);
    try testing.expect(loc.get("exact").?.bool);
}

test "renderResponse: 숨은 일치만이면 not ok 에 hint 한 줄" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try testing.expect(!try renderResponse(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ok\":false,\"hint\":\"1 matching element(s) are hidden\"}}", .ok, &w));
    try testing.expectEqualStrings("error: not ok\nhint: 1 matching element(s) are hidden\n", w.buffered());
}

test "renderResponse: -32008 의 param 과 오류 메시지는 표시 안전하게 찍는다" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try testing.expect(!try renderResponse(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32008,\"message\":\"Not supported\\u001b[2J\",\"data\":{\"engine\":\"webkit\",\"param\":\"locator\"}}}", .ok, &w));
    try testing.expectEqualStrings("error: Not supported[2J (-32008) [engine=webkit] [param=locator]\n", w.buffered());
}

test "renderResponse: matched 의 페이지 글은 제어·양방향 제어 글자를 빼고 찍는다" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try testing.expect(try renderResponse(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ok\":true,\"matched\":{\"ref\":\"n11\",\"name\":\"Sa\\u001b[2Jve\\u009b\\u202edoc\"}}}", .ok, &w));
    try testing.expectEqualStrings("ok\nmatched n11 \"Sa[2Jvedoc\"\n", w.buffered());
}

test "renderResponse: 로케이터로 찾은 ok 는 matched 줄을 덧붙인다(첫 줄은 그대로 ok)" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try testing.expect(try renderResponse(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ok\":true,\"matched\":{\"ref\":\"n11\",\"name\":\"Save\"}}}", .ok, &w));
    try testing.expectEqualStrings("ok\nmatched n11 \"Save\"\n", w.buffered());
}

test "buildRequestBytes: act 메서드·params(selector|ref)" {
    {
        const b = try buildRequestBytes(testing.allocator, .{ .click = .{ .surface_id = 11, .locator = .{ .selector = "#btn" } } }, .{ .number = 1 });
        defer testing.allocator.free(b);
        var pm = try cp.parseMessage(testing.allocator, b);
        defer pm.deinit();
        try testing.expectEqualStrings("browser.click", pm.message.request.method);
        try testing.expectEqualStrings("#btn", pm.message.request.params.?.object.get("selector").?.string);
        try testing.expect(pm.message.request.params.?.object.get("ref") == null);
        try testing.expect(pm.message.request.params.?.object.get("text") == null);
    }
    // ref locator → params에 {ref}(selector 없음).
    {
        const b = try buildRequestBytes(testing.allocator, .{ .click = .{ .surface_id = 11, .locator = .{ .ref = "e9" } } }, .{ .number = 1 });
        defer testing.allocator.free(b);
        var pm = try cp.parseMessage(testing.allocator, b);
        defer pm.deinit();
        try testing.expectEqualStrings("e9", pm.message.request.params.?.object.get("ref").?.string);
        try testing.expect(pm.message.request.params.?.object.get("selector") == null);
    }
    {
        const b = try buildRequestBytes(testing.allocator, .{ .type_text = .{ .surface_id = 11, .locator = .{ .ref = "e1" }, .text = "hi" } }, .{ .number = 1 });
        defer testing.allocator.free(b);
        var pm = try cp.parseMessage(testing.allocator, b);
        defer pm.deinit();
        try testing.expectEqualStrings("browser.type", pm.message.request.method);
        try testing.expectEqualStrings("e1", pm.message.request.params.?.object.get("ref").?.string);
        try testing.expectEqualStrings("hi", pm.message.request.params.?.object.get("text").?.string);
    }
}

// ── wait 파서·wire·렌더 단위 ──

test "browser --help 스냅샷: wait 포함 구현 명령만 정확히 공개" {
    try testing.expectEqualStrings(
        \\usage: maru browser <command> [--surface <id>] [args]
        \\
        \\Specify --surface only once per invocation (repeated IDs are also rejected).
        \\Control a web surface (browser panel). First discover the target web surface_id with
        \\`maru browser list`, then pass it to the other commands as --surface <id>. Without a
        \\capability the request opens a confirmation dialog; allowing it runs the command (§9.2 Model B).
        \\
        \\commands:
        \\  list                                   list open web panels (id, url, title, engine — for discovery)
        \\  navigate    --surface <id> <url>       navigate to URL (Chromium tabs: http, https or about:blank; waits for the first load)
        \\  get-url     --surface <id>             print the current document URL
        \\  exec        --surface <id> [--args json-array] [--max-result-bytes n] [--out f] <expression>   run and await a JavaScript expression
        \\  get-cookies --surface <id>             print cookies for the current document host as JSON
        \\  set-cookie  --surface <id> --name n --value v [--domain d] [--path p] [--secure]   set a cookie
        \\  delete-cookie --surface <id> --name n [--domain d] [--path p]                      delete a cookie
        \\  get-local-storage    --surface <id> --key k             print a localStorage value
        \\  set-local-storage    --surface <id> --key k --value v   set a localStorage value
        \\  remove-local-storage --surface <id> --key k             remove a localStorage entry
        \\  clear-storage        --surface <id>                     clear the target origin's storage and its host's cookies
        \\  click   --surface <id> (--selector <css> | --ref <ref>)         click an element (by selector or snapshot ref; real mouse input on Chromium tabs)
        \\  type    --surface <id> (--selector <css> | --ref <ref>) --text <t>  type text into an element (replaces its text; real input on Chromium tabs)
        \\  scroll  --surface <id> (--selector <css> | --ref <ref>)         scroll an element into view
        \\  (click/type/scroll/hover/press also take --role <role> [--name <n>] [--level <n>], --by-text <t> or --by-label <t>, with [--exact] [--nth <n>], instead of --selector/--ref; Chromium tabs)
        \\  wait    --surface <id> (--selector <css> | --load) [--timeout <ms>]   wait for a condition (default and max 25000ms)
        \\  (wait also takes --role <role> [--name <n>] [--level <n>], --by-text <t> or --by-label <t>, with [--exact] [--nth <n>] [--visible]: wait until it is visible; Chromium tabs)
        \\  snapshot --surface <id> [--interactive] [--max-depth <n>] [--selector <css>]   print the page ARIA tree (role/name/ref)
        \\  console --surface <id> [--clear]                        print page console logs (level, text); --clear empties after reading
        \\  screenshot  --surface <id> [--out f] [--rect x,y,w,h] [--scale s]   capture PNG of the visible view (--rect region in view coordinates, --scale factor; omit for the whole view at device scale)
        \\  back    --surface <id>                     go back in the tab's history (Chromium tabs; "not ok" when there is nothing to go back to)
        \\  forward --surface <id>                     go forward in the tab's history (Chromium tabs)
        \\  reload  --surface <id>                     reload the page (Chromium tabs)
        \\  hover   --surface <id> (--selector <css> | --ref <ref>)         move the pointer onto an element (real input; Chromium tabs)
        \\  press   --surface <id> --key <keys> [--selector <css> | --ref <ref>]   press a key like Enter, Shift+Tab or Meta+a (real input; on the element, or where the focus is; Chromium tabs)
        \\  open    [--url <url>] [--timeout <ms>]     open a tab behind the current one in this pane and print its id (waits for the first load; Chromium; from a maru pane)
        \\  close   --surface <id>                     close a tab this pane opened (asks the page; "not closed" if it asks before leaving)
        \\  repl    [--surface <id>]                   read one command per line; `use <id>` (or `open`) picks the tab so --surface can be left out
        \\
    ,
        browser_help,
    );
    // 첫 wait slice에서 명시적으로 제외한 조건은 help에도 노출하지 않는다.
    for ([_][]const u8{ "networkidle", "wait --url", "wait --text", "--function", "--hidden", "--detached" }) |future| {
        try testing.expect(std.mem.indexOf(u8, browser_help, future) == null);
    }
}

test "parse: wait selector/load·timeout 기본값·상한·상호배타" {
    switch (try parse(&.{ "wait", "--surface", "3", "--selector", "#ready" })) {
        .request => |r| {
            try testing.expectEqual(@as(u64, 3), r.wait.surface_id);
            try testing.expectEqual(WaitCondition.selector, r.wait.condition);
            try testing.expectEqualStrings("#ready", r.wait.selector.?);
            try testing.expectEqual(wait_default_timeout_ms, r.wait.timeout_ms);
        },
        else => return error.Unexpected,
    }
    switch (try parse(&.{ "wait", "--surface=7", "--load", "--timeout=125" })) {
        .request => |r| {
            try testing.expectEqual(WaitCondition.load, r.wait.condition);
            try testing.expect(r.wait.selector == null);
            try testing.expectEqual(@as(u32, 125), r.wait.timeout_ms);
        },
        else => return error.Unexpected,
    }
    try testing.expectError(error.MissingSurface, parse(&.{ "wait", "--load" }));
    try testing.expectError(error.MissingWaitCondition, parse(&.{ "wait", "--surface", "1" }));
    try testing.expectError(error.ConflictingWaitCondition, parse(&.{ "wait", "--surface", "1", "--load", "--selector", "#x" }));
    try testing.expectError(error.MissingSelector, parse(&.{ "wait", "--surface", "1", "--selector=" }));
    try testing.expectError(error.MissingTimeoutValue, parse(&.{ "wait", "--surface", "1", "--load", "--timeout" }));
    try testing.expectError(error.InvalidTimeout, parse(&.{ "wait", "--surface", "1", "--load", "--timeout", "0" }));
    try testing.expectError(error.InvalidTimeout, parse(&.{ "wait", "--surface", "1", "--load", "--timeout", "25001" }));
    try testing.expectError(error.InvalidTimeout, parse(&.{ "wait", "--surface", "1", "--load", "--timeout", "abc" }));
}

test "buildRequestBytes: browser.wait selector/load params" {
    {
        const b = try buildRequestBytes(testing.allocator, .{ .wait = .{
            .surface_id = 11,
            .condition = .selector,
            .selector = "#ready",
            .timeout_ms = 500,
        } }, .{ .number = 1 });
        defer testing.allocator.free(b);
        var pm = try cp.parseMessage(testing.allocator, b);
        defer pm.deinit();
        try testing.expectEqualStrings("browser.wait", pm.message.request.method);
        const p = pm.message.request.params.?.object;
        try testing.expectEqual(@as(i64, 11), p.get("id").?.integer);
        try testing.expectEqualStrings("selector", p.get("condition").?.string);
        try testing.expectEqualStrings("#ready", p.get("selector").?.string);
        try testing.expectEqual(@as(i64, 500), p.get("timeout_ms").?.integer);
    }
    {
        const b = try buildRequestBytes(testing.allocator, .{ .wait = .{
            .surface_id = 11,
            .condition = .load,
            .selector = null,
            .timeout_ms = wait_default_timeout_ms,
        } }, .{ .number = 2 });
        defer testing.allocator.free(b);
        var pm = try cp.parseMessage(testing.allocator, b);
        defer pm.deinit();
        const p = pm.message.request.params.?.object;
        try testing.expectEqualStrings("load", p.get("condition").?.string);
        try testing.expect(p.get("selector") == null);
    }
}

test "parse/build/render: snapshot(§9.5.4) — 기본·옵션·에러·트리 렌더" {
    // 기본(surface만).
    switch (try parse(&.{ "snapshot", "--surface", "11" })) {
        .request => |r| switch (r) {
            .snapshot => |sn| {
                try testing.expectEqual(@as(u64, 11), sn.surface_id);
                try testing.expect(!sn.interactive_only and sn.max_depth == null and sn.selector == null);
            },
            else => return error.Unexpected,
        },
        else => return error.Unexpected,
    }
    // 전체 옵션.
    switch (try parse(&.{ "snapshot", "--surface=3", "--interactive", "--max-depth", "5", "--selector", "#app" })) {
        .request => |r| switch (r) {
            .snapshot => |sn| {
                try testing.expect(sn.interactive_only);
                try testing.expectEqual(@as(u32, 5), sn.max_depth.?);
                try testing.expectEqualStrings("#app", sn.selector.?);
            },
            else => return error.Unexpected,
        },
        else => return error.Unexpected,
    }
    try testing.expectError(error.MissingSurface, parse(&.{"snapshot"}));
    try testing.expectError(error.InvalidMaxDepth, parse(&.{ "snapshot", "--surface", "1", "--max-depth", "x" }));
    try testing.expectError(error.MissingMaxDepthValue, parse(&.{ "snapshot", "--surface", "1", "--max-depth" }));
    try testing.expectError(error.UnknownOption, parse(&.{ "snapshot", "--surface", "1", "--bogus" }));

    // build: interactive_only=false면 생략, max_depth/selector 실림.
    {
        const b = try buildRequestBytes(testing.allocator, .{ .snapshot = .{ .surface_id = 3, .interactive_only = false, .max_depth = 2, .selector = "#x" } }, .{ .number = 1 });
        defer testing.allocator.free(b);
        var pm = try cp.parseMessage(testing.allocator, b);
        defer pm.deinit();
        const o = pm.message.request.params.?.object;
        try testing.expectEqualStrings("browser.snapshot", pm.message.request.method);
        try testing.expect(o.get("interactive_only") == null); // false=생략
        try testing.expectEqual(@as(i64, 2), o.get("max_depth").?.integer);
        try testing.expectEqualStrings("#x", o.get("selector").?.string);
    }

    // render: {snapshot:{tree:[...]}} → 들여쓰기 텍스트(role "name" [ref=eN] + 자식 2칸).
    {
        var buf: [256]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        _ = try renderResponse(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"snapshot\":{\"tree\":[{\"role\":\"navigation\",\"name\":\"\",\"children\":[{\"role\":\"link\",\"name\":\"Home\",\"ref\":\"e1\"}]}]}}}", .snapshot, &w);
        try testing.expectEqualStrings("navigation\n  link \"Home\" [ref=e1]\n", w.buffered());
    }
}

test "parse/build/render: console(§9.5.9) — 기본·clear·에러·항목 렌더" {
    // 기본(surface만) → clear=false.
    switch (try parse(&.{ "console", "--surface", "11" })) {
        .request => |r| switch (r) {
            .console => |c| {
                try testing.expectEqual(@as(u64, 11), c.surface_id);
                try testing.expect(!c.clear);
            },
            else => return error.Unexpected,
        },
        else => return error.Unexpected,
    }
    // --clear flag.
    switch (try parse(&.{ "console", "--surface=3", "--clear" })) {
        .request => |r| try testing.expect(r.console.clear),
        else => return error.Unexpected,
    }
    try testing.expectError(error.MissingSurface, parse(&.{"console"}));
    try testing.expectError(error.UnknownOption, parse(&.{ "console", "--surface", "1", "--bogus" }));

    // build: clear=false면 생략, true면 실림.
    {
        const b = try buildRequestBytes(testing.allocator, .{ .console = .{ .surface_id = 3, .clear = false } }, .{ .number = 1 });
        defer testing.allocator.free(b);
        var pm = try cp.parseMessage(testing.allocator, b);
        defer pm.deinit();
        try testing.expectEqualStrings("browser.console", pm.message.request.method);
        try testing.expect(pm.message.request.params.?.object.get("clear") == null); // false=생략
    }
    {
        const b = try buildRequestBytes(testing.allocator, .{ .console = .{ .surface_id = 3, .clear = true } }, .{ .number = 1 });
        defer testing.allocator.free(b);
        var pm = try cp.parseMessage(testing.allocator, b);
        defer pm.deinit();
        try testing.expect(pm.message.request.params.?.object.get("clear").?.bool);
    }

    // render: {console:[{level,text}]} → `[level] text` 줄. 비면 안내.
    {
        var buf: [256]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        _ = try renderResponse(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"console\":[{\"level\":\"log\",\"text\":\"hi\"},{\"level\":\"error\",\"text\":\"boom\"}]}}", .console, &w);
        try testing.expectEqualStrings("[log] hi\n[error] boom\n", w.buffered());
    }
    {
        var buf: [64]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        _ = try renderResponse(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"console\":[]}}", .console, &w);
        try testing.expectEqualStrings("(empty console)\n", w.buffered());
    }
}

test {
    testing.refAllDecls(@This());
}

test "response outcome distinguishes server failure from successful rendering" {
    const wires = [_][]const u8{ "invalid-json", "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32601,\"message\":\"fixture\"}}", "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"url\":\"https://example.invalid/\"}}" };
    for (wires, 0..) |wire, index| {
        var w: std.Io.Writer.Allocating = .init(testing.allocator);
        defer w.deinit();
        try testing.expectEqual(index == 2, try renderResponse(testing.allocator, wire, .get_url, &w.writer));
    }
}

// Every target-bearing verb must reject repeated selection, independent of spelling/value.
test "browser target is selected once across every verb and option spelling" {
    const verbs = [_][]const []const u8{
        &.{ "navigate", "https://example.invalid/" },
        &.{"get-url"},
        &.{ "exec", "1 + 1" },
        &.{"get-cookies"},
        &.{ "set-cookie", "--name", "n", "--value", "v" },
        &.{ "delete-cookie", "--name", "n" },
        &.{ "get-local-storage", "--key", "k" },
        &.{ "set-local-storage", "--key", "k", "--value", "v" },
        &.{ "remove-local-storage", "--key", "k" },
        &.{"clear-storage"},
        &.{ "click", "--ref", "e1" },
        &.{ "type", "--ref", "e1", "--text", "t" },
        &.{ "scroll", "--ref", "e1" },
        &.{ "wait", "--load" },
        &.{"snapshot"},
        &.{"console"},
        &.{"screenshot"},
        // W8–W9 동사·로케이터도 같은 규칙이다(main 기준 rebase 에서 act 파서만 덮어쓰던 것을 이 목록이 잡았다).
        &.{"back"},
        &.{"forward"},
        &.{"reload"},
        &.{ "hover", "--selector", "#h" },
        &.{ "press", "--key", "Enter" },
        &.{ "click", "--role", "button", "--name", "Save" },
        &.{ "click", "--by-text", "Save" },
        &.{ "type", "--by-label", "Name", "--text", "t" },
        &.{ "wait", "--role", "button" },
        &.{ "wait", "--selector", "#x", "--visible" },
    };
    const firsts = [_][]const []const u8{ &.{ "--surface", "1" }, &.{"--surface=1"} };
    const seconds = [_][]const []const u8{ &.{ "--surface", "1" }, &.{ "--surface", "2" }, &.{"--surface=1"}, &.{"--surface=2"} };
    for (verbs) |verb| {
        for (firsts) |first| {
            var args: std.ArrayList([]const u8) = .empty;
            defer args.deinit(testing.allocator);
            try args.append(testing.allocator, verb[0]);
            try args.appendSlice(testing.allocator, first);
            try args.appendSlice(testing.allocator, verb[1..]);
            _ = try parse(args.items); // valid single-target positive control
            const original_len = args.items.len;
            for (seconds) |second| {
                args.items.len = original_len;
                try args.appendSlice(testing.allocator, second);
                try testing.expectError(error.DuplicateSurface, parse(args.items));
            }
        }
    }
    // Values that happen to look like target options are opaque values, not selections.
    _ = try parse(&.{ "type", "--surface", "1", "--ref", "e1", "--text", "--surface=2" });
    _ = try parse(&.{ "screenshot", "--surface", "1", "--out", "--surface=2" });
}

test "parse·buildRequestBytes: wait 의 로케이터(W9b②-3) — 로케이터면 visible, --selector 는 --visible 이어도 selector 조건, 옵션 규칙은 act 와 같다" {
    const r = (try parse(&.{ "wait", "--surface", "3", "--role", "button", "--name", "Save", "--timeout", "900" })).request.wait;
    try testing.expectEqual(WaitCondition.visible, r.condition);
    try testing.expectEqualStrings("Save", r.locator.?.role.name.?);
    try testing.expectEqual(@as(u32, 900), r.timeout_ms);
    const t = (try parse(&.{ "wait", "--surface=3", "--visible", "--by-text=Done", "--exact", "--nth=1" })).request.wait;
    try testing.expectEqualStrings("Done", t.locator.?.text.value);
    try testing.expect(t.locator.?.text.exact);
    const sel = (try parse(&.{ "wait", "--surface", "3", "--selector", "#a", "--visible" })).request.wait;
    try testing.expectEqual(WaitCondition.selector, sel.condition);
    try testing.expect(sel.locator == null);
    try testing.expectError(error.ConflictingWaitCondition, parse(&.{ "wait", "--surface", "3", "--load", "--role", "button" }));
    try testing.expectError(error.ConflictingWaitCondition, parse(&.{ "wait", "--surface", "3", "--load", "--visible" }));
    try testing.expectError(error.ConflictingLocator, parse(&.{ "wait", "--surface", "3", "--selector", "#a", "--role", "button" }));
    try testing.expectError(error.LocatorOptionWithoutRole, parse(&.{ "wait", "--surface", "3", "--name", "Save" }));
    try testing.expectError(error.LocatorOptionWithoutRole, parse(&.{ "wait", "--surface", "3", "--selector", "#a", "--nth", "1" }));
    try testing.expectError(error.ExactWithoutName, parse(&.{ "wait", "--surface", "3", "--role", "button", "--exact" }));
    try testing.expectError(error.MissingWaitCondition, parse(&.{ "wait", "--surface", "3", "--visible" }));
    try testing.expectError(error.UnknownOption, parse(&.{ "wait", "--surface", "3", "--ref", "n4" }));
    const b = try buildRequestBytes(testing.allocator, .{ .wait = .{ .surface_id = 11, .condition = .visible, .selector = null, .timeout_ms = 25000, .locator = .{ .label = .{ .value = "Email", .exact = true } } } }, .{ .number = 1 });
    defer testing.allocator.free(b);
    var pm = try cp.parseMessage(testing.allocator, b);
    defer pm.deinit();
    const params = pm.message.request.params.?.object;
    try testing.expectEqualStrings("visible", params.get("condition").?.string);
    try testing.expectEqualStrings("Email", params.get("locator").?.object.get("label").?.string);
    try testing.expect(params.get("locator").?.object.get("exact").?.bool);
    try testing.expect(params.get("selector") == null);
}

test "renderResponse: wait 이 찾은 것이 여럿과 맞으면 matched 뒤에 경고 한 줄" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    _ = try renderResponse(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ok\":true,\"matched\":{\"ref\":\"n4\",\"name\":\"Save\"},\"ambiguous\":true}}", .ok, &w);
    try testing.expectEqualStrings("ok\nmatched n4 \"Save\"\nwarning: ambiguous — the locator matches several elements; act with the matched ref, --exact or --nth\n", w.buffered());
}

test "renderResponse: 로케이터 wait 의 시한에 숨은 일치가 있으면 hint 한 줄" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    _ = try renderResponse(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32004,\"message\":\"Timeout\",\"data\":{\"condition\":\"visible\",\"timeout_ms\":300,\"hidden\":2}}}", .ok, &w);
    try testing.expectEqualStrings("error: Timeout (-32004)\nhint: 2 matching element(s) are hidden (not rendered, aria-hidden or off-page)\n", w.buffered());
}

test "parse·build: open(W9b③) — 대상 없이 [--url] [--timeout], close — surface 만" {
    const o = (try parse(&.{ "open", "--url", "https://e.test/a", "--timeout", "5000" })).request.open;
    try testing.expectEqualStrings("https://e.test/a", o.url.?);
    try testing.expectEqual(@as(u32, 5000), o.timeout_ms.?);
    const bare = (try parse(&.{"open"})).request.open;
    try testing.expect(bare.url == null and bare.timeout_ms == null);
    try testing.expectError(error.UnknownOption, parse(&.{ "open", "--surface", "3" })); // 대상 탭이 없다
    try testing.expectError(error.MissingUrl, parse(&.{ "open", "--url" }));
    try testing.expectError(error.InvalidTimeout, parse(&.{ "open", "--timeout", "0" }));
    try testing.expectError(error.InvalidTimeout, parse(&.{ "open", "--timeout", "25001" }));
    try testing.expectError(error.UnexpectedArgument, parse(&.{ "open", "https://e.test/" }));
    try testing.expectEqual(@as(u64, 9), (try parse(&.{ "close", "--surface", "9" })).request.close.surface_id);
    try testing.expectError(error.MissingSurface, parse(&.{"close"}));
    {
        const b = try buildRequestBytes(testing.allocator, (try parse(&.{ "open", "--url", "https://e.test/a", "--timeout", "5000" })).request, .{ .number = 1 });
        defer testing.allocator.free(b);
        var pm = try cp.parseMessage(testing.allocator, b);
        defer pm.deinit();
        try testing.expectEqualStrings("browser.open", pm.message.request.method);
        const p = pm.message.request.params.?.object;
        try testing.expectEqualStrings("https://e.test/a", p.get("url").?.string);
        try testing.expectEqual(@as(i64, 5000), p.get("timeout_ms").?.integer);
        try testing.expect(p.get("id") == null);
    }
    {
        const b = try buildRequestBytes(testing.allocator, (try parse(&.{"open"})).request, .{ .number = 1 });
        defer testing.allocator.free(b);
        var pm = try cp.parseMessage(testing.allocator, b);
        defer pm.deinit();
        try testing.expectEqual(@as(usize, 0), pm.message.request.params.?.object.count()); // 엄격 키 — 빈 params
    }
    {
        const b = try buildRequestBytes(testing.allocator, (try parse(&.{ "close", "--surface", "9" })).request, .{ .number = 1 });
        defer testing.allocator.free(b);
        var pm = try cp.parseMessage(testing.allocator, b);
        defer pm.deinit();
        try testing.expectEqualStrings("browser.close", pm.message.request.method);
        try testing.expectEqual(@as(i64, 9), pm.message.request.params.?.object.get("id").?.integer);
    }
}

test "render: open(W9b③) 은 id·주소(다 못 불렀으면 경고), close 는 closed 또는 not closed: 이유(실패)" {
    var buf: [512]u8 = undefined;
    const cases = [_]struct { bytes: []const u8, kind: ResponseKind, want: []const u8, ok: bool }{
        .{ .bytes = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"id\":42,\"url\":\"https://e.test/\",\"loaded\":true}}", .kind = .open, .want = "opened 42 https://e.test/\n", .ok = true },
        .{ .bytes = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"id\":42,\"url\":\"\",\"loaded\":false}}", .kind = .open, .want = "opened 42\nwarning: the page did not finish loading in time — wait --load before acting\n", .ok = true },
        .{ .bytes = "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32002,\"message\":\"Unauthorized\"}}", .kind = .close, .want = "error: Unauthorized (-32002)\nhint: only tabs this pane opened with `browser open` can be closed\n", .ok = false },
        .{ .bytes = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"closed\":true}}", .kind = .close, .want = "closed\n", .ok = true },
        .{ .bytes = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"closed\":false,\"reason\":\"asks \\u001b[31m\"}}", .kind = .close, .want = "not closed: asks [31m\n", .ok = false },
    };
    for (cases) |c| {
        var w: std.Io.Writer = .fixed(&buf);
        try testing.expectEqual(c.ok, try renderResponse(testing.allocator, c.bytes, c.kind, &w));
        try testing.expectEqualStrings(c.want, w.buffered());
    }
}

test "W9b③ 적대 리뷰 3 회차: 누른 뒤 페이지가 대화상자를 띄웠으면 ok 뒤에 「다시 하지 말라」 경고 한 줄" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try testing.expect(try renderResponse(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ok\":true,\"dialog\":true}}", .ok, &w));
    try testing.expectEqualStrings("ok\nwarning: the page opened a dialog right after the input — the input reached the page, do not repeat it; answer the dialog in that tab\n", w.buffered());
}

// ── W9f: repl ─────────────────────────────────────────────────────────────────────────────────────────────

/// repl 한 줄을 셸처럼 나눈다 — 공백으로 가르고, 작은따옴표 안은 그대로, 큰따옴표 안은 `\"`·`\\` 만 푼다. 따옴표가 닫히지 않으면 null.
/// 돌려준 글은 `arena` 소유.
pub fn splitLine(arena: std.mem.Allocator, line: []const u8) std.mem.Allocator.Error!?[]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var cur: std.ArrayList(u8) = .empty;
    var in_token = false;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const ch = line[i];
        switch (ch) {
            ' ', '\t', '\r', '\n' => if (in_token) {
                try out.append(arena, try cur.toOwnedSlice(arena));
                in_token = false;
            },
            '\'' => {
                in_token = true;
                const end = std.mem.indexOfScalarPos(u8, line, i + 1, '\'') orelse return null;
                try cur.appendSlice(arena, line[i + 1 .. end]);
                i = end;
            },
            '"' => {
                in_token = true;
                i += 1;
                while (true) : (i += 1) {
                    if (i >= line.len) return null;
                    if (line[i] == '"') break;
                    if (line[i] == '\\' and i + 1 < line.len and (line[i + 1] == '"' or line[i + 1] == '\\')) i += 1;
                    try cur.append(arena, line[i]);
                }
            },
            else => {
                in_token = true;
                try cur.append(arena, ch);
            },
        }
    }
    if (in_token) try out.append(arena, try cur.toOwnedSlice(arena));
    return try out.toOwnedSlice(arena);
}

pub const ReplLine = union(enum) {
    empty,
    exit,
    help,
    use: u64,
    /// `use` 뒤가 탭 id 하나가 아니다.
    bad_use,
    unterminated_quote,
    /// 돌릴 하위 명령 인자(고른 탭이 있고 필요하면 `--surface` 를 붙였다).
    command: []const []const u8,
};

/// 대상 탭을 받지 않는 하위 명령.
fn takesNoSurface(sub: []const u8) bool {
    return eq(sub, "list") or eq(sub, "open") or eq(sub, "help") or eq(sub, "repl");
}

/// repl 한 줄 — `exit`·`quit`, `help`·`?`, `use <id>`, `#` 주석, 그 밖은 하위 명령(고른 탭이 있고 대상이 빠졌으면 `--surface` 를 붙인다).
pub fn replLine(arena: std.mem.Allocator, line: []const u8, current: ?u64) std.mem.Allocator.Error!ReplLine {
    const toks = (try splitLine(arena, line)) orelse return .unterminated_quote;
    if (toks.len == 0 or std.mem.startsWith(u8, toks[0], "#")) return .empty;
    if (eq(toks[0], "exit") or eq(toks[0], "quit")) return .exit;
    if (eq(toks[0], "help") or eq(toks[0], "?")) return .help;
    if (eq(toks[0], "use")) {
        if (toks.len != 2) return .bad_use;
        // wire 의 탭 id 는 JSON 정수(i64) — 넘으면 받아 놓고 뒤 명령이 모두 틀렸다(W9f 적대 리뷰 1 회차).
        const id = std.fmt.parseInt(u64, toks[1], 10) catch return .bad_use;
        if (id > std.math.maxInt(i64)) return .bad_use;
        return .{ .use = id };
    }
    // 대상이 빠졌을 때만 붙인다 — 파서에 묻는다(`--text --surface=2` 의 값은 대상 옵션이 아니다, `--` 뒤도).
    const missing_surface = if (parse(toks)) |_| false else |e| e == error.MissingSurface;
    if (current == null or !missing_surface or takesNoSurface(toks[0])) return .{ .command = toks };
    var out: std.ArrayList([]const u8) = .empty;
    try out.append(arena, toks[0]);
    try out.appendSlice(arena, &.{ "--surface", try std.fmt.allocPrint(arena, "{d}", .{current.?}) });
    try out.appendSlice(arena, toks[1..]);
    return .{ .command = try out.toOwnedSlice(arena) };
}

/// `opened <id> …` 줄에서 id(repl 이 연 탭을 곧 고른다).
pub fn openedId(output: []const u8) ?u64 {
    if (!std.mem.startsWith(u8, output, "opened ")) return null;
    const rest = output["opened ".len..];
    const end = std.mem.indexOfAny(u8, rest, " \n") orelse rest.len;
    return std.fmt.parseInt(u64, rest[0..end], 10) catch null;
}

test "W9f repl: 줄 나누기 — 공백·작은따옴표·큰따옴표(\\\" 풀기), 닫히지 않은 따옴표는 null" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const t = (try splitLine(a, "click  --role button --name 'Save draft'")).?;
    try testing.expectEqual(@as(usize, 5), t.len);
    try testing.expectEqualStrings("Save draft", t[4]);
    const q = (try splitLine(a, "type --text \"say \\\"hi\\\"\" x")).?;
    try testing.expectEqual(@as(usize, 4), q.len);
    try testing.expectEqualStrings("say \"hi\"", q[2]);
    try testing.expectEqualStrings("a'b", (try splitLine(a, "x \"a'b\"")).?[1]);
    try testing.expectEqualStrings("ab", (try splitLine(a, "x a'b'")).?[1]);
    try testing.expect((try splitLine(a, "click --name 'open")) == null);
    try testing.expect((try splitLine(a, "type --text \"x")) == null);
    try testing.expectEqual(@as(usize, 0), (try splitLine(a, "   ")).?.len);
    try testing.expectEqualStrings("", (try splitLine(a, "type --text ''")).?[2]);
}

test "W9f repl: 줄 해석 — use·exit·help·주석, 고른 탭은 --surface 로 붙이고(이미 있거나 list·open 이면 그대로)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqual(@as(u64, 7), (try replLine(a, "use 7", null)).use);
    try testing.expect(try replLine(a, "use x", null) == .bad_use);
    try testing.expect(try replLine(a, "use", null) == .bad_use);
    try testing.expect(try replLine(a, "quit", 3) == .exit);
    try testing.expect(try replLine(a, "?", 3) == .help);
    try testing.expect(try replLine(a, "# note", 3) == .empty);
    try testing.expect(try replLine(a, "", 3) == .empty);
    try testing.expect(try replLine(a, "click --name 'x", 3) == .unterminated_quote);
    const c = (try replLine(a, "click --selector '#b'", 7)).command;
    try testing.expectEqual(@as(u64, 7), (try parse(c)).request.click.surface_id);
    const own = (try replLine(a, "click --surface 9 --selector a", 7)).command;
    try testing.expectEqual(@as(u64, 9), (try parse(own)).request.click.surface_id);
    const own_eq = (try replLine(a, "click --surface=9 --selector a", 7)).command;
    try testing.expectEqual(@as(u64, 9), (try parse(own_eq)).request.click.surface_id);
    const nav = (try replLine(a, "navigate https://e.test/", 7)).command;
    try testing.expectEqual(@as(u64, 7), (try parse(nav)).request.navigate.surface_id);
    try testing.expectEqual(@as(usize, 1), (try replLine(a, "list", 7)).command.len);
    const op = (try replLine(a, "open --url https://e.test/", 7)).command;
    try testing.expect((try parse(op)).request.open.url != null);
    try testing.expectError(error.MissingSurface, parse((try replLine(a, "click --selector a", null)).command));
    try testing.expectEqual(@as(?u64, 12), openedId("opened 12 https://e.test/\n"));
    try testing.expectEqual(@as(?u64, 4), openedId("opened 4\n"));
    try testing.expectEqual(@as(?u64, null), openedId("error: x"));
    try testing.expectEqual(@as(u64, 5), (try parse(&.{ "repl", "--surface", "5" })).repl.surface.?);
    try testing.expectEqual(@as(?u64, null), (try parse(&.{"repl"})).repl.surface);
    try testing.expectError(error.UnexpectedArgument, parse(&.{ "repl", "x" }));
}

test "W9f: `--` 뒤 하나는 `-` 로 시작해도 위치 인자 — 도움말 검사도 거기서 멈춘다" {
    try testing.expectEqualStrings("-1", (try parse(&.{ "exec", "--surface", "2", "--", "-1" })).request.exec.script);
    try testing.expectEqualStrings("-h", (try parse(&.{ "exec", "--surface", "2", "--", "-h" })).request.exec.script);
    try testing.expectEqualStrings("--help", (try parse(&.{ "navigate", "--surface", "2", "--", "--help" })).request.navigate.url);
    try testing.expect(try parse(&.{ "exec", "--help", "--", "-1" }) == .help);
    try testing.expectError(error.MissingScript, parse(&.{ "exec", "--surface", "2", "--" }));
    try testing.expectError(error.UnexpectedArgument, parse(&.{ "exec", "--surface", "2", "--", "a", "b" }));
    try testing.expectError(error.UnexpectedArgument, parse(&.{ "exec", "--surface", "2", "x", "--", "a" }));
    try testing.expectError(error.MissingUrl, parse(&.{ "navigate", "--surface", "2", "--" }));
    try testing.expectError(error.UnexpectedArgument, parse(&.{ "navigate", "--surface", "2", "--", "a", "b" }));
    try testing.expectError(error.UnexpectedArgument, parse(&.{ "navigate", "--surface", "2", "a", "--", "b" }));
    try testing.expectEqualStrings("--help", (try parse(&.{ "type", "--surface", "2", "--selector", "a", "--text=--help" })).request.type_text.text);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const c = (try replLine(arena_state.allocator(), "exec -- --surface", 7)).command;
    try testing.expectEqual(@as(u64, 7), (try parse(c)).request.exec.surface_id);
    // 값이 대상 옵션처럼 보여도 대상이 아니다(「CLI 대상 서페이스 단일 지정」) — 고른 탭을 붙인다.
    const t = (try replLine(arena_state.allocator(), "type --selector a --text --surface=2", 7)).command;
    try testing.expectEqual(@as(u64, 7), (try parse(t)).request.type_text.surface_id);
    try testing.expectEqualStrings("--surface=2", (try parse(t)).request.type_text.text);
}

test "W9f 적대 리뷰 1 회차: 값 자리의 -h·--help 는 도움말이 아니다(repl 에서 `type --text -h` 가 도움말을 「성공」 으로 냈다)" {
    try testing.expectEqualStrings("-h", (try parse(&.{ "type", "--surface", "1", "--selector", "a", "--text", "-h" })).request.type_text.text);
    try testing.expectEqualStrings("--help", (try parse(&.{ "press", "--surface", "1", "--key", "--help" })).request.press.key);
    try testing.expect(try parse(&.{ "click", "--help" }) == .help);
    try testing.expect(try parse(&.{ "snapshot", "--interactive", "--help" }) == .help); // 값을 받지 않는 옵션 뒤는 도움말
    try testing.expect(try parse(&.{"-h"}) == .help);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expect((try parse((try replLine(a, "type --selector a --text -h", 3)).command)) == .request);
    // 깊게 중첩된 exec 인자는 거절한다(요청을 만들 때 panic 했다).
    var deep: std.ArrayList(u8) = .empty;
    for (0..300) |_| try deep.append(a, '[');
    for (0..300) |_| try deep.append(a, ']');
    try testing.expectError(error.ArgsTooDeep, parse(&.{ "exec", "--surface", "1", "--args", deep.items, "1" }));
    // 고른 탭 — i64 를 넘는 id 는 「use 가 틀렸다」(전에는 받아 놓고 뒤 명령이 모두 실패했다).
    try testing.expect(try replLine(a, "use 9223372036854775808", null) == .bad_use);
    // 대상이 이미 있고 다른 이유로 틀린 명령에는 붙이지 않는다(붙이면 「--surface 두 번」 이 진짜 이유를 가린다).
    try testing.expectError(error.UnknownOption, parse((try replLine(a, "click --surface 9 --bogus", 7)).command));
}

test "W9f 적대 리뷰 2 회차: exec args 깊이는 서버 계약(배열 안쪽 128 단 = 글 깊이 129)까지 받는다 — 문자열 안의 괄호는 세지 않는다" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var ok: std.ArrayList(u8) = .empty;
    try ok.appendNTimes(a, '[', 129);
    try ok.appendNTimes(a, ']', 129);
    const cmd = try parse(&.{ "exec", "--surface", "1", "--args", ok.items, "1" });
    try testing.expect((try buildRequestBytes(a, cmd.request, .{ .number = 1 })).len > 0);
    var deep: std.ArrayList(u8) = .empty; // 가장 안쪽 빈 [] 가 깊이 129(서버 셈법 — 3 회차)
    try deep.appendNTimes(a, '[', 131);
    try deep.appendNTimes(a, ']', 131);
    if (parse(&.{ "exec", "--surface", "1", "--args", deep.items, "1" })) |_| return error.TestUnexpectedResult else |_| {}
    // 요청을 만드는 자리도 막는다(파서를 거치지 않은 값).
    var raw = cmd.request;
    raw.exec.args_json = deep.items;
    if (buildRequestBytes(a, raw, .{ .number = 1 })) |_| return error.TestUnexpectedResult else |_| {}
    try testing.expectEqual(@as(usize, 0), argsValueDepth("[\"[[[[\", \"\\\"]]\", \"\\\\\"]"));
    try testing.expectEqual(@as(usize, 1), argsValueDepth("[{\"a\":\"}}}\"}]"));
    // 값 없는 플래그 뒤의 -h 는 도움말이고, `--opt=값` 뒤도 그렇다.
    for ([_][]const u8{ "--interactive", "--clear", "--load", "--visible", "--exact", "--secure", "--surface=1" }) |flag|
        try testing.expect(try parse(&.{ "snapshot", flag, "-h" }) == .help);
}

fn nestedArgs(a: std.mem.Allocator, brackets: usize, inner: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendNTimes(a, '[', brackets);
    try out.appendSlice(a, inner);
    try out.appendNTimes(a, ']', brackets);
    return out.toOwnedSlice(a);
}

test "W9f 적대 리뷰 3 회차: exec args 깊이는 서버 셈법(원소 깊이 0 부터, 값마다 128 이하)과 같다 — 가장 안쪽이 빈 컨테이너면 한 단 더" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const Case = struct { text: []const u8, ok: bool };
    for ([_]Case{
        .{ .text = try nestedArgs(a, 129, "1"), .ok = true }, // 스칼라가 깊이 128
        .{ .text = try nestedArgs(a, 130, "1"), .ok = false }, // 129
        .{ .text = try nestedArgs(a, 130, ""), .ok = true }, // 가장 안쪽 [] 가 깊이 128
        .{ .text = try nestedArgs(a, 131, ""), .ok = false },
        .{ .text = "[\"[[[[\\\"[[[[\"]", .ok = true }, // 문자열 안 괄호·이스케이프
    }) |c| {
        const r = parse(&.{ "exec", "--surface", "1", "--args", c.text, "1" });
        if (c.ok) _ = try r else try testing.expectError(error.ArgsTooDeep, r);
    }
    // 형제 객체가 많아도 깊어지지 않는다.
    var wide: std.ArrayList(u8) = .empty;
    try wide.append(a, '[');
    for (0..300) |i| try wide.appendSlice(a, if (i == 0) "{}" else ",{}");
    try wide.append(a, ']');
    try testing.expectEqual(@as(usize, 0), argsValueDepth(wide.items));
    // 이스케이프된 따옴표 뒤의 괄호는 아직 문자열 안이다.
    try testing.expectEqual(@as(usize, 0), argsValueDepth("[\"\\\"[[[[\"]"));
}

test "W9f 적대 리뷰 4 회차: snapshot·list·console 의 페이지 글은 걸러 인용한다(가짜 ref 끼우기·화면 지우기·방향 바꾸기)" {
    var buf: [2048]u8 = undefined;
    {
        var w: std.Io.Writer = .fixed(&buf);
        const resp = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"snapshot\":{\"tree\":[{\"role\":\"button\",\"name\":\"Q\\\" [ref=n7]\",\"ref\":\"n10\"},{\"role\":\"button\",\"name\":\"Ok\\u001b[2J\\u202elive\\u202c\",\"ref\":\"n8\"},{\"role\":\"button\",\"name\":\"L\\u2028surface 1 fake\",\"ref\":\"n9\"}]}}}";
        _ = try renderResponse(testing.allocator, resp, .snapshot, &w);
        try testing.expectEqualStrings("button \"Q\\\" [ref=n7]\" [ref=n10]\nbutton \"Ok[2Jlive\" [ref=n8]\nbutton \"Lsurface 1 fake\" [ref=n9]\n", w.buffered());
    }
    {
        var w: std.Io.Writer = .fixed(&buf);
        const resp = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"surfaces\":[{\"id\":3,\"panel_kind\":\"browser\",\"url\":\"https://a/\\u001b[2J\",\"title\":\"T\\\"  engine=webkit\",\"engine\":\"chromium\",\"methods\":[\"click\"]}]}}";
        _ = try renderResponse(testing.allocator, resp, .list, &w);
        try testing.expect(std.mem.indexOf(u8, w.buffered(), "\x1b") == null);
        try testing.expect(std.mem.indexOf(u8, w.buffered(), "\"T\\\"  engine=webkit\"") != null);
    }
}

test "W9f 적대 리뷰 4 회차: unauthorized 안내는 닫힌 탭·목록에 없는 id 도 같은 거절이라고 알린다" {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    _ = try renderResponse(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32002,\"message\":\"Unauthorized\"}}", .ok, &w);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "not in `browser list`") != null);
}

test "W9f 적대 리뷰 5 회차: get-local-storage 의 값·get-url 의 주소도 페이지가 정한 글이다 — 제어·방향 글자를 거른다" {
    var buf: [512]u8 = undefined;
    {
        var w: std.Io.Writer = .fixed(&buf);
        _ = try renderResponse(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"value\":\"a\\u001b]52;c;eA==\\u0007b\\u202e\\nfake line\"}}", .value, &w);
        try testing.expectEqualStrings("a]52;c;eA==bfake line\n", w.buffered());
    }
    {
        var w: std.Io.Writer = .fixed(&buf);
        _ = try renderResponse(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"url\":\"https://a/\\u001b[2J\\u202e\"}}", .get_url, &w);
        try testing.expectEqualStrings("https://a/[2J\n", w.buffered());
    }
}

test "W9f 적대 리뷰 5 회차: 아주 깊은 snapshot 트리는 정해진 깊이에서 끊고 한 줄로 알린다(스택·출력이 깊이에 묶인다)" {
    const depth = 5000;
    var req: std.ArrayList(u8) = .empty;
    defer req.deinit(testing.allocator);
    try req.appendSlice(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"snapshot\":{\"tree\":[");
    for (0..depth) |_| try req.appendSlice(testing.allocator, "{\"role\":\"group\",\"children\":[");
    for (0..depth) |_| try req.appendSlice(testing.allocator, "]}");
    try req.appendSlice(testing.allocator, "]}}}");
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    _ = try renderResponse(testing.allocator, req.items, .snapshot, &out.writer);
    const text = out.written();
    try testing.expectEqual(@as(usize, max_snapshot_render_depth + 1), std.mem.count(u8, text, "\n"));
    try testing.expect(std.mem.indexOf(u8, text, "deeper levels omitted") != null);
    try testing.expect(text.len < 64 * 1024);
}

test "W9a: Chromium 탭의 navigate 가 불러온 문서 없이 끝나면 ok 뒤 경고 한 줄 — loaded 가 없거나 참이면 ok 만" {
    var buf: [512]u8 = undefined;
    const cases = [_]struct { body: []const u8, want: []const u8 }{
        .{ .body = "{\"ok\":true}", .want = "ok\n" },
        .{ .body = "{\"ok\":true,\"loaded\":true}", .want = "ok\n" },
        .{ .body = "{\"ok\":true,\"loaded\":false}", .want = "ok\nwarning: no page finished loading (an empty response, a download, a same-page link, or the time ran out) — check with get-url\n" },
    };
    for (cases) |c| {
        var w: std.Io.Writer = .fixed(&buf);
        var resp_buf: [256]u8 = undefined;
        const resp = try std.fmt.bufPrint(&resp_buf, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{s}}}", .{c.body});
        try testing.expect(try renderResponse(testing.allocator, resp, .navigate, &w));
        try testing.expectEqualStrings(c.want, w.buffered());
    }
}

test "W9a②: 스크립트 오류(-32006)는 종류·이름·메시지를 한 줄로 — 페이지가 정한 글은 걸러서" {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try testing.expect(!try renderResponse(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32006,\"message\":\"Script error\",\"data\":{\"kind\":\"execution\",\"name\":\"TypeError\",\"message\":\"x is not\\u001b[2J a function\",\"stack\":\"TypeError: …\",\"diagnostics_truncated\":false}}}", .exec, &w));
    try testing.expectEqualStrings("error: Script error (-32006)\nscript error (execution): TypeError: x is not[2J a function\n", w.buffered());
}

test "W9a③ 적대 리뷰 8 회차 재현: get-cookies 는 페이지가 정한 쿠키 이름·값의 C1 CSI(U+009B)·RLO(U+202E)를 터미널로 내지 않고 \\u 로 쓴다 — 값은 그대로, JSON 은 유효" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    _ = try renderResponse(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"cookies\":[{\"name\":\"n\\u202em\",\"value\":\"a\\u009b2Jb\"}]}}", .get_cookies, &w);
    // get-local-storage·get-url 은 이것들을 뺀다(W9f 5 회차) — get-cookies 도 빼거나 \u 로 써야 한다.
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "\xc2\x9b") == null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "\xe2\x80\xae") == null);
    // 값은 잃지 않는다 — 파싱하면 원래 글자다, 한글은 그대로.
    const line = std.mem.trimEnd(u8, w.buffered(), "\n");
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("n\u{202e}m", parsed.value.array.items[0].object.get("name").?.string);
    try testing.expectEqualStrings("a\u{009b}2Jb", parsed.value.array.items[0].object.get("value").?.string);
    w = .fixed(&buf);
    _ = try renderResponse(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"cookies\":[{\"name\":\"한\",\"value\":\"\\\"q\"}]}}", .get_cookies, &w);
    try testing.expectEqualStrings("[{\"name\":\"한\",\"value\":\"\\\"q\"}]\n", w.buffered());
}

test "W9a③ 적대 리뷰 9 회차 재현: exec 결과(페이지가 정한 글)의 C1 CSI·RLO·U+2028 은 터미널로 내지 않고 \\u 로 — JSON 은 그대로 유효" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    _ = try renderResponse(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"result\":\"\\\"t\\u009b2J\\u202ex\\u2028y\\\"\"}}", .exec, &w);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "\xc2\x9b") == null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "\xe2\x80\xae") == null);
}
