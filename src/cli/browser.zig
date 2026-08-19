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
    \\Control a web surface (browser panel). First discover the target web surface_id with
    \\`maru browser list`, then pass it to the other commands as --surface <id>. Without a
    \\capability the request opens a confirmation dialog; allowing it runs the command (§9.2 Model B).
    \\
    \\commands:
    \\  list                                   list open web panels (id, url, title — for discovery)
    \\  navigate    --surface <id> <url>       navigate to URL
    \\  get-url     --surface <id>             print the current document URL
    \\  exec        --surface <id> [--args json-array] [--max-result-bytes n] [--out f] <expression>   run and await a JavaScript expression
    \\  get-cookies --surface <id>             print cookies for the current document host as JSON
    \\  set-cookie  --surface <id> --name n --value v [--domain d] [--path p] [--secure]   set a cookie
    \\  delete-cookie --surface <id> --name n [--domain d] [--path p]                      delete a cookie
    \\  get-local-storage    --surface <id> --key k             print a localStorage value
    \\  set-local-storage    --surface <id> --key k --value v   set a localStorage value
    \\  remove-local-storage --surface <id> --key k             remove a localStorage entry
    \\  clear-storage        --surface <id>                     clear all cookies and storage for the target origin
    \\  click   --surface <id> (--selector <css> | --ref <e#>)          click an element (by selector or snapshot ref)
    \\  type    --surface <id> (--selector <css> | --ref <e#>) --text <t>   type text into an element (input)
    \\  scroll  --surface <id> (--selector <css> | --ref <e#>)          scroll an element into view
    \\  wait    --surface <id> (--selector <css> | --load) [--timeout <ms>]   wait for a condition (default and max 25000ms)
    \\  snapshot --surface <id> [--interactive] [--max-depth <n>] [--selector <css>]   print the page ARIA tree (role/name/ref)
    \\  console --surface <id> [--clear]                        print page console logs (level, text); --clear empties after reading
    \\  screenshot  --surface <id> [--out f] [--rect x,y,w,h] [--scale s]   capture PNG (--rect region, --scale factor; omit for full page at device scale)
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
    /// `browser click`(act 5f-2·snapshot-2). locator=--selector 또는 --ref 하나. 응답 {ok}(요소 발견+클릭).
    click: struct { surface_id: u64, locator: Locator },
    /// `browser type`(act 5f-2·snapshot-2). locator + text 필수. 응답 {ok}.
    type_text: struct { surface_id: u64, locator: Locator, text: []const u8 },
    /// `browser scroll`(act 5f-2·snapshot-2). locator 필수(scrollIntoView). 응답 {ok}.
    scroll: struct { surface_id: u64, locator: Locator },
    /// `browser wait`: visible selector 또는 현재 load idle까지 polling. timeout은 1..25_000ms. 응답 {ok}.
    wait: struct { surface_id: u64, condition: WaitCondition, selector: ?[]const u8, timeout_ms: u32 },
    /// `browser snapshot`(§9.5.4): 페이지 ARIA 트리(role/name/ref). interactive_only/max_depth/selector 선택. 응답 {snapshot}.
    snapshot: struct { surface_id: u64, interactive_only: bool, max_depth: ?u32, selector: ?[]const u8 },
    /// `browser console`(§9.5.9): 서버 버퍼에 쌓인 콘솔을 회수. clear=반환 후 버퍼 비움. 응답 {console:[{level,text}]}.
    console: struct { surface_id: u64, clear: bool },

    /// 응답 렌더용 종류(어느 result 모양인지). renderResponse가 소비.
    pub fn kind(self: Request) ResponseKind {
        return switch (self) {
            .list => .list,
            .navigate => .navigate,
            .get_url => .get_url,
            .exec => .exec,
            .get_cookies => .get_cookies,
            .set_cookie, .delete_cookie, .set_local_storage, .remove_local_storage, .clear_storage, .click, .type_text, .scroll, .wait => .ok,
            .get_local_storage => .value,
            .snapshot => .snapshot,
            .console => .console,
        };
    }
};

pub const WaitCondition = enum {
    selector,
    load,

    fn wire(self: WaitCondition) []const u8 {
        return switch (self) {
            .selector => "selector",
            .load => "load",
        };
    }
};

/// act(click/type/scroll) 대상 지시자 — `--selector <css>` 또는 `--ref <e#>`(§9.5.4 snapshot) 중 정확히 하나.
/// ref는 snapshot이 매긴 불투명 토큰이라 CLI는 값을 그대로 wire에 실을 뿐 해석하지 않는다. parse가 배타성을 강제한다.
pub const Locator = union(enum) {
    selector: []const u8,
    ref: []const u8,
};

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
};

/// 파싱 실패. main이 usage/에러 메시지를 stderr에 낸다(sessions.ParseError와 동형 규율).
pub const ParseError = error{
    MissingSubcommand, // `maru browser`에 서브커맨드 없음
    UnknownSubcommand, // 알 수 없는 서브커맨드(`browser foo`)
    MissingSurface, // `--surface` 미제공(모든 서브커맨드 필수)
    InvalidSurface, // surface 값이 비숫자/음수/범위밖
    MissingSurfaceValue, // `--surface`에 값 없음
    MissingUrl, // `navigate`에 url 없음
    MissingScript, // `exec`에 script 없음
    MissingArgsValue,
    InvalidArgs,
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
    MissingLocator, // `click`/`type`/`scroll`에 `--selector`/`--ref` 둘 다 없음
    ConflictingLocator, // `click`/`type`/`scroll`에 `--selector`와 `--ref` 동시 지정
    MissingWaitCondition, // `wait`에 `--selector` 또는 `--load` 없음
    ConflictingWaitCondition, // `wait` 조건을 둘 이상 지정
    MissingTimeoutValue, // `wait --timeout`에 값 없음
    InvalidTimeout, // timeout이 1..25_000 정수가 아님
    MissingText, // `type`에 `--text` 없음
    MissingValue, // `set-cookie`/`set-local-storage`에 `--value` 없음
    MissingOptionValue, // `--name`/`--value`/`--domain`/`--path`/`--selector`에 값 없음
    MissingMaxDepthValue, // `snapshot --max-depth`에 값 없음
    InvalidMaxDepth, // `--max-depth`가 비음수 정수(u32)가 아님
    UnknownOption, // 알 수 없는 옵션(`--bogus`)
    UnexpectedArgument, // 남는 위치 인자
};

// ══ 파서 ═══════════════════════════════════════════════════════════════════════════════════════════════════

/// `maru browser` 뒤 인자를 파싱한다. `--help`/`-h` 있으면 `.help`.
pub fn parse(args: []const []const u8) ParseError!Command {
    if (hasHelpFlag(args)) return .help;
    if (args.len == 0) return error.MissingSubcommand;
    const sub = args[0];
    const rest = args[1..];
    if (eq(sub, "list")) {
        // 발견 — 대상 surface 불요(전부 나열). 남는 인자(옵션/위치)는 에러(오타 방지).
        if (rest.len != 0) {
            if (std.mem.startsWith(u8, rest[0], "-")) return error.UnknownOption;
            return error.UnexpectedArgument;
        }
        return .{ .request = .list };
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
    if (eq(sub, "click")) {
        const ca = try parseCookieArgs(rest);
        const s = ca.surface orelse return error.MissingSurface;
        return .{ .request = .{ .click = .{ .surface_id = s, .locator = try locatorFromArgs(ca) } } };
    }
    if (eq(sub, "type")) {
        const ca = try parseCookieArgs(rest);
        const s = ca.surface orelse return error.MissingSurface;
        const loc = try locatorFromArgs(ca);
        const text = ca.text orelse return error.MissingText;
        return .{ .request = .{ .type_text = .{ .surface_id = s, .locator = loc, .text = text } } };
    }
    if (eq(sub, "scroll")) {
        const ca = try parseCookieArgs(rest);
        const s = ca.surface orelse return error.MissingSurface;
        return .{ .request = .{ .scroll = .{ .surface_id = s, .locator = try locatorFromArgs(ca) } } };
    }
    if (eq(sub, "wait")) {
        const wa = try parseWaitArgs(rest);
        const s = wa.surface orelse return error.MissingSurface;
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
                surface = parseU64(args[i + 1]) catch return error.InvalidSurface;
                i += 2;
            } else if (std.mem.startsWith(u8, a, "--surface=")) {
                surface = parseU64(a["--surface=".len..]) catch return error.InvalidSurface;
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
                surface = parseU64(args[i + 1]) catch return error.InvalidSurface;
                i += 2;
            } else if (std.mem.startsWith(u8, a, "--surface=")) {
                surface = parseU64(a["--surface=".len..]) catch return error.InvalidSurface;
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
                surface = parseU64(args[i + 1]) catch return error.InvalidSurface;
                i += 2;
            } else if (std.mem.startsWith(u8, a, "--surface=")) {
                surface = parseU64(a["--surface=".len..]) catch return error.InvalidSurface;
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
            surface = parseU64(rest[i + 1]) catch return error.InvalidSurface;
            i += 2;
        } else if (std.mem.startsWith(u8, arg, "--surface=")) {
            surface = parseU64(arg["--surface=".len..]) catch return error.InvalidSurface;
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
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownOption;
        } else {
            if (script != null) return error.UnexpectedArgument;
            script = arg;
            i += 1;
        }
    }
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
            surface = parseU64(rest[i + 1]) catch return error.InvalidSurface;
            i += 2;
        } else if (std.mem.startsWith(u8, a, "--surface=")) {
            surface = parseU64(a["--surface=".len..]) catch return error.InvalidSurface;
            i += 1;
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
            r.surface = parseU64(value) catch return error.InvalidSurface;
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
            r.surface = parseU64(try optValue(rest, &i, "--surface")) catch return error.InvalidSurface;
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
    for (args) |a| if (eq(a, "--help") or eq(a, "-h")) return true;
    return false;
}

/// 10진 파싱 후 wire i64 범위 제한(surface_id는 JSON integer=i64). sessions.parseU64와 동일 규율.
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
        .click => |c| return actRequest(gpa, id, "browser.click", c.surface_id, c.locator, null),
        .type_text => |c| return actRequest(gpa, id, "browser.type", c.surface_id, c.locator, c.text),
        .scroll => |c| return actRequest(gpa, id, "browser.scroll", c.surface_id, c.locator, null),
        .wait => |w| {
            var obj: std.json.ObjectMap = .empty;
            defer obj.deinit(gpa);
            try obj.put(gpa, "id", .{ .integer = @intCast(w.surface_id) });
            try obj.put(gpa, "condition", .{ .string = w.condition.wire() });
            if (w.selector) |selector| try obj.put(gpa, "selector", .{ .string = selector });
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

/// act 요청 바이트: `{id, selector|ref, text?}`(§9.5.4). locator=selector 또는 ref 하나, text null이면 locator만(click/scroll).
/// ref는 wire 불투명 토큰(서버가 [data-maru-ref]로 해소). caller free.
fn actRequest(gpa: std.mem.Allocator, id: cp.Id, method: []const u8, surface_id: u64, locator: Locator, text: ?[]const u8) std.mem.Allocator.Error![]u8 {
    return switch (locator) {
        .selector => |s| twoFieldRequest(gpa, id, method, surface_id, "selector", s, "text", text),
        .ref => |r| twoFieldRequest(gpa, id, method, surface_id, "ref", r, "text", text),
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
pub const ResponseKind = enum { list, navigate, get_url, exec, get_cookies, ok, value, snapshot, console };

/// 응답 바이트 한 줄을 기계·사람 읽기 편한 형태로 `w`에 쓴다. 에러 응답이면 균일하게 `error: <msg> (<code>)`
/// (sessions.renderResponse 규율 — 미grant 거부는 `error: Unauthorized (-32002)`). result는 kind별 한 줄.
pub fn renderResponse(gpa: std.mem.Allocator, response_bytes: []const u8, kind: ResponseKind, w: *std.Io.Writer) !void {
    var pm = cp.parseMessage(gpa, response_bytes) catch {
        try w.writeAll("error: malformed response from server\n");
        return;
    };
    defer pm.deinit();
    const resp = switch (pm.message) {
        .response => |r| r,
        else => {
            try w.writeAll("error: unexpected message (not a response)\n");
            return;
        },
    };
    if (resp.err) |e| {
        try w.print("error: {s} ({d})\n", .{ e.message, e.code });
        return;
    }
    const result = switch (resp.result orelse {
        try w.writeAll("error: empty result\n");
        return;
    }) {
        .object => |o| o,
        else => {
            try w.writeAll("error: malformed result\n");
            return;
        },
    };
    switch (kind) {
        .list => {
            // {surfaces:[{id,url,title,panel_kind}]} → surface별 한 줄. 에이전트가 id를 골라 제어를 건다.
            const surfaces = switch (result.get("surfaces") orelse std.json.Value{ .null = {} }) {
                .array => |a| a,
                else => {
                    try w.writeAll("error: malformed surfaces\n");
                    return;
                },
            };
            if (surfaces.items.len == 0) {
                try w.writeAll("(no web surfaces)\n");
                return;
            }
            for (surfaces.items) |item| {
                const o = switch (item) {
                    .object => |oo| oo,
                    else => continue,
                };
                try w.print("surface {d}  {s}  {s}  \"{s}\"\n", .{
                    intField(o.get("id")) orelse 0,
                    strField(o.get("panel_kind")),
                    strField(o.get("url")),
                    strField(o.get("title")),
                });
            }
        },
        .navigate => {
            if (boolField(result.get("ok"))) try w.writeAll("ok\n") else try w.writeAll("error: navigate not ok\n");
        },
        .ok => { // set-cookie/delete-cookie/set·remove-local-storage/clear-storage 성공 = {ok:true}
            if (boolField(result.get("ok"))) try w.writeAll("ok\n") else try w.writeAll("error: not ok\n");
        },
        .value => try w.print("{s}\n", .{strField(result.get("value"))}), // get-local-storage → {value}
        .get_url => try w.print("{s}\n", .{strField(result.get("url"))}),
        .exec => try w.print("{s}\n", .{strField(result.get("result"))}),
        .get_cookies => {
            // cookies 배열을 JSON 한 줄로 재직렬화(에이전트가 파싱). 배열 아니면 에러.
            const cookies = switch (result.get("cookies") orelse std.json.Value{ .null = {} }) {
                .array => |a| a,
                else => {
                    try w.writeAll("error: malformed cookies\n");
                    return;
                },
            };
            var s: std.json.Stringify = .{ .writer = w, .options = .{} };
            s.write(std.json.Value{ .array = cookies }) catch return error.WriteFailed;
            try w.writeAll("\n");
        },
        .snapshot => {
            // {snapshot:{tree:[{role,name,ref?,children?}]}} → compact 들여쓰기 텍스트(§9.5.4). 에이전트가 role/name/ref를 읽고 ref로 조작.
            const snap = switch (result.get("snapshot") orelse std.json.Value{ .null = {} }) {
                .object => |o| o,
                else => {
                    try w.writeAll("error: malformed snapshot\n");
                    return;
                },
            };
            const tree = switch (snap.get("tree") orelse std.json.Value{ .null = {} }) {
                .array => |a| a,
                else => {
                    try w.writeAll("error: malformed snapshot tree\n");
                    return;
                },
            };
            if (tree.items.len == 0) {
                try w.writeAll("(empty snapshot)\n");
                return;
            }
            for (tree.items) |node| try renderSnapshotNode(node, 0, w);
        },
        .console => {
            // {console:[{level,text},...]} → 각 항목 `[level] text` 한 줄(§9.5.9). 배열 아니면 에러, 비면 안내.
            const entries = switch (result.get("console") orelse std.json.Value{ .null = {} }) {
                .array => |a| a,
                else => {
                    try w.writeAll("error: malformed console\n");
                    return;
                },
            };
            if (entries.items.len == 0) {
                try w.writeAll("(empty console)\n");
                return;
            }
            for (entries.items) |entry| {
                const o = switch (entry) {
                    .object => |oo| oo,
                    else => continue,
                };
                try w.print("[{s}] {s}\n", .{ strField(o.get("level")), strField(o.get("text")) });
            }
        },
    }
}

/// snapshot 트리 노드 한 줄 + 자식 재귀(들여쓰기 2칸). `<role> "<name>" [ref=<ref>]`(name/ref 없으면 생략).
fn renderSnapshotNode(node: std.json.Value, depth: usize, w: *std.Io.Writer) !void {
    const o = switch (node) {
        .object => |oo| oo,
        else => return,
    };
    var i: usize = 0;
    while (i < depth) : (i += 1) try w.writeAll("  ");
    try w.print("{s}", .{strField(o.get("role"))});
    const name = strField(o.get("name"));
    if (name.len > 0) try w.print(" \"{s}\"", .{name});
    const ref = strField(o.get("ref"));
    if (ref.len > 0) try w.print(" [ref={s}]", .{ref});
    try w.writeAll("\n");
    switch (o.get("children") orelse std.json.Value{ .null = {} }) {
        .array => |kids| for (kids.items) |kid| try renderSnapshotNode(kid, depth + 1, w),
        else => {},
    }
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
        try renderResponse(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ok\":true}}", .navigate, &w);
        try testing.expectEqualStrings("ok\n", w.buffered());
    }
    // getUrl {url} → url 한 줄.
    {
        var w = std.Io.Writer.fixed(&buf);
        try renderResponse(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"url\":\"https://x/y\"}}", .get_url, &w);
        try testing.expectEqualStrings("https://x/y\n", w.buffered());
    }
    // exec {result} → 값 한 줄.
    {
        var w = std.Io.Writer.fixed(&buf);
        try renderResponse(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"result\":\"My Page\"}}", .exec, &w);
        try testing.expectEqualStrings("My Page\n", w.buffered());
    }
    // getCookies {cookies:[...]} → JSON 배열 한 줄.
    {
        var w = std.Io.Writer.fixed(&buf);
        try renderResponse(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"cookies\":[{\"name\":\"sid\",\"value\":\"v\"}]}}", .get_cookies, &w);
        try testing.expect(std.mem.indexOf(u8, w.buffered(), "\"name\":\"sid\"") != null);
    }
    // error 응답(미grant 거부) → 균일 "error: msg (code)".
    {
        var w = std.Io.Writer.fixed(&buf);
        try renderResponse(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32002,\"message\":\"Unauthorized\"}}", .navigate, &w);
        try testing.expectEqualStrings("error: Unauthorized (-32002)\n", w.buffered());
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
        try renderResponse(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"surfaces\":[{\"id\":3,\"url\":\"https://naver.com/\",\"title\":\"Browser\",\"panel_kind\":\"browser\"},{\"id\":7,\"url\":\"\",\"title\":\"docs\",\"panel_kind\":\"markdown\"}]}}", .list, &w);
        const out = w.buffered();
        try testing.expect(std.mem.indexOf(u8, out, "surface 3  browser  https://naver.com/  \"Browser\"") != null);
        try testing.expect(std.mem.indexOf(u8, out, "surface 7  markdown  ") != null);
    }
    // 빈 목록.
    {
        var buf: [128]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        try renderResponse(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"surfaces\":[]}}", .list, &w);
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
    try renderResponse(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ok\":true}}", .ok, &w);
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

test "renderResponse(value): getLocalStorage {value} → 값 출력" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try renderResponse(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"value\":\"hello\"}}", .value, &w);
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
        \\web surface(브라우저 패널)를 제어한다. 먼저 `maru browser list`로 대상 web surface_id를 발견하고,
        \\나머지 명령에 --surface <id>로 지정한다. 권한이 없으면 확인 모달이 뜨고, 허용하면 실행된다(§9.2 Model B).
        \\
        \\commands:
        \\  list                                   열린 web 패널을 나열(id·url·title — 대상 발견용)
        \\  navigate    --surface <id> <url>       URL로 이동
        \\  get-url     --surface <id>             현재 문서 URL 출력
        \\  exec        --surface <id> [--args json-array] [--max-result-bytes n] [--out f] <expression>   JavaScript 표현식 실행·await
        \\  get-cookies --surface <id>             현재 문서 host의 쿠키를 JSON으로 출력
        \\  set-cookie  --surface <id> --name n --value v [--domain d] [--path p] [--secure]   쿠키 설정
        \\  delete-cookie --surface <id> --name n [--domain d] [--path p]                      쿠키 삭제
        \\  get-local-storage    --surface <id> --key k             localStorage 값 출력
        \\  set-local-storage    --surface <id> --key k --value v   localStorage 값 설정
        \\  remove-local-storage --surface <id> --key k             localStorage 항목 삭제
        \\  clear-storage        --surface <id>                     대상 origin 쿠키+스토리지 전부 삭제
        \\  click   --surface <id> (--selector <css> | --ref <e#>)          요소 클릭(selector 또는 snapshot ref)
        \\  type    --surface <id> (--selector <css> | --ref <e#>) --text <t>   요소(input)에 값 입력
        \\  scroll  --surface <id> (--selector <css> | --ref <e#>)          요소로 스크롤
        \\  wait    --surface <id> (--selector <css> | --load) [--timeout <ms>]   조건 충족까지 대기(기본·최대 25000ms)
        \\  snapshot --surface <id> [--interactive] [--max-depth <n>] [--selector <css>]   페이지 ARIA 트리(role/name/ref) 출력
        \\  console --surface <id> [--clear]                        페이지 콘솔 로그(level·text) 출력, --clear=회수 후 비움
        \\  screenshot  --surface <id> [--out f] [--rect x,y,w,h] [--scale s]   PNG 캡처(--rect 영역·--scale 배율, 생략=전체·기기배율)
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
        try renderResponse(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"snapshot\":{\"tree\":[{\"role\":\"navigation\",\"name\":\"\",\"children\":[{\"role\":\"link\",\"name\":\"Home\",\"ref\":\"e1\"}]}]}}}", .snapshot, &w);
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
        try renderResponse(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"console\":[{\"level\":\"log\",\"text\":\"hi\"},{\"level\":\"error\",\"text\":\"boom\"}]}}", .console, &w);
        try testing.expectEqualStrings("[log] hi\n[error] boom\n", w.buffered());
    }
    {
        var buf: [64]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        try renderResponse(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"console\":[]}}", .console, &w);
        try testing.expectEqualStrings("(empty console)\n", w.buffered());
    }
}

test {
    testing.refAllDecls(@This());
}
