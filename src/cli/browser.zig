//! browser — `maru browser` CLI 클라이언트(L2 순수, §9.6). `browser.*`(navigate/getUrl/executeScript/getCookies)를
//! 에이전트가 쓸 CLI로 노출한다. 1d `sessions` CLI(cli/sessions.zig)와 **동형**: 여기는 인자 파싱 + 요청 바이트
//! 조립(`buildRequestBytes`, 1a `serializeMessage` 재사용) + 응답 렌더(`renderResponse`, 1a `parseMessage` 재사용)만
//! 하고, 소켓 발견·connect·`auth.self`·프레임 왕복은 main.zig(`runSessionCli` 미러)가 한다.
//!
//! **auth·grant(§9.2 Model B)**: CLI는 `auth.self`(selector=`MARU_PANE_ID`·cap_nonce=null)만 보낸다 — browser 요청은
//! 세션 cap이 없어 needs_grant→서버 held→**확인 모달**. main의 read는 사용자가 모달을 클릭할 때까지 블록(승인=응답
//! 렌더·거부=`Unauthorized`·무응답 timeout=EOF). 대상 `--surface N`은 필수(에이전트는 `maru sessions list`로 web
//! surface_id 발견). 확장(screenshot·act·set/delete)은 서브커맨드 dispatch에 한 줄씩.
//!
//! **L2 순수**: std + control_plane(1a)만. 소켓/OS 0(파싱·wire만 — I/O는 main).

const std = @import("std");
const cp = @import("../session/control_plane.zig");

/// `maru browser --help`. 구현된 서브커맨드만 노출한다(§11 help gate — 정직성). 대상 surface는 `maru sessions list`로 발견.
pub const browser_help =
    \\usage: maru browser <command> [--surface <id>] [args]
    \\
    \\web surface(브라우저 패널)를 제어한다. 먼저 `maru browser list`로 대상 web surface_id를 발견하고,
    \\나머지 명령에 --surface <id>로 지정한다. 권한이 없으면 확인 모달이 뜨고, 허용하면 실행된다(§9.2 Model B).
    \\
    \\commands:
    \\  list                                   열린 web 패널을 나열(id·url·title — 대상 발견용)
    \\  navigate    --surface <id> <url>       URL로 이동
    \\  get-url     --surface <id>             현재 문서 URL 출력
    \\  exec        --surface <id> <script>    JavaScript 실행, 결과 출력
    \\  get-cookies --surface <id>             현재 문서 host의 쿠키를 JSON으로 출력
    \\  set-cookie  --surface <id> --name n --value v [--domain d] [--path p] [--secure]   쿠키 설정
    \\  delete-cookie --surface <id> --name n [--domain d] [--path p]                      쿠키 삭제
    \\  get-local-storage    --surface <id> --key k             localStorage 값 출력
    \\  set-local-storage    --surface <id> --key k --value v   localStorage 값 설정
    \\  remove-local-storage --surface <id> --key k             localStorage 항목 삭제
    \\  clear-storage        --surface <id>                     대상 origin 쿠키+스토리지 전부 삭제
    \\  click   --surface <id> --selector <css>                 셀렉터 요소 클릭
    \\  type    --surface <id> --selector <css> --text <t>      셀렉터 요소(input)에 값 입력
    \\  scroll  --surface <id> --selector <css>                 셀렉터 요소로 스크롤
    \\  wait    --surface <id> (--selector <css> | --load) [--timeout <ms>]   조건 충족까지 대기(기본·최대 25000ms)
    \\  screenshot  --surface <id> [--out f] [--rect x,y,w,h] [--scale s]   PNG 캡처(--rect 영역·--scale 배율, 생략=전체·기기배율)
    \\
;

// ── 명령 모델 ─────────────────────────────────────────────────────────────────────────────────────────────

/// `browser.*` 요청(핵심 4개). id는 대상 web surface_id.
pub const Request = union(enum) {
    /// `browser list`(§9.6 발견) — **surface_id 불요**(인스턴스의 web surface 전부 나열). ungated 발견(제어는 별도 모달).
    /// 다른 서브커맨드가 `--surface`로 대상을 지정하는 것과 달리 대상이 없다(에이전트가 이걸로 대상 id를 발견).
    list,
    navigate: struct { surface_id: u64, url: []const u8 },
    get_url: struct { surface_id: u64 },
    exec: struct { surface_id: u64, script: []const u8 },
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
    /// `browser click`(act 5f-2). selector 필수. 응답 {ok}(요소 발견+클릭).
    click: struct { surface_id: u64, selector: []const u8 },
    /// `browser type`(act 5f-2). selector/text 필수. 응답 {ok}.
    type_text: struct { surface_id: u64, selector: []const u8, text: []const u8 },
    /// `browser scroll`(act 5f-2). selector 필수(scrollIntoView). 응답 {ok}.
    scroll: struct { surface_id: u64, selector: []const u8 },
    /// `browser wait`: visible selector 또는 현재 load idle까지 polling. timeout은 1..25_000ms. 응답 {ok}.
    wait: struct { surface_id: u64, condition: WaitCondition, selector: ?[]const u8, timeout_ms: u32 },

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

pub const wait_default_timeout_ms: u32 = 25_000;
pub const wait_max_timeout_ms: u32 = 25_000;

/// screenshot(5f-1)은 단일 응답이 아니라 **chunk 스트림**(§9.5.7)이라 단일-응답 `Request`와 분리한다 — main이
/// `ScreenshotAssembler`로 chunk를 재조립해 PNG를 `out`(nil=stdout)에 쓴다. surface_id=대상 web surface. named 타입이라
/// main.zig 핸들러 인자로 그대로 전달된다(익명 struct는 별개 타입이 되어 안 맞음).
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
    MissingOutValue, // `screenshot --out`에 값 없음
    MissingRectValue, // `screenshot --rect`에 값 없음
    MissingScaleValue, // `screenshot --scale`에 값 없음
    InvalidRect, // `--rect`가 `x,y,w,h`(4개 수치, w/h>0) 형식 아님
    InvalidScale, // `--scale`이 양수 수치 아님
    MissingName, // `set-cookie`/`delete-cookie`에 `--name` 없음
    MissingKey, // `*-local-storage`에 `--key` 없음
    MissingSelector, // `click`/`type`/`scroll`에 `--selector` 없음
    MissingWaitCondition, // `wait`에 `--selector` 또는 `--load` 없음
    ConflictingWaitCondition, // `wait` 조건을 둘 이상 지정
    MissingTimeoutValue, // `wait --timeout`에 값 없음
    InvalidTimeout, // timeout이 1..25_000 정수가 아님
    MissingText, // `type`에 `--text` 없음
    MissingValue, // `set-cookie`/`set-local-storage`에 `--value` 없음
    MissingOptionValue, // `--name`/`--value`/`--domain`/`--path`에 값 없음
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
        const p = try parseSurfaceArg(rest);
        const s = p.surface orelse return error.MissingSurface;
        const script = p.arg orelse return error.MissingScript;
        return .{ .request = .{ .exec = .{ .surface_id = s, .script = script } } };
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
        const sel = ca.selector orelse return error.MissingSelector;
        return .{ .request = .{ .click = .{ .surface_id = s, .selector = sel } } };
    }
    if (eq(sub, "type")) {
        const ca = try parseCookieArgs(rest);
        const s = ca.surface orelse return error.MissingSurface;
        const sel = ca.selector orelse return error.MissingSelector;
        const text = ca.text orelse return error.MissingText;
        return .{ .request = .{ .type_text = .{ .surface_id = s, .selector = sel, .text = text } } };
    }
    if (eq(sub, "scroll")) {
        const ca = try parseCookieArgs(rest);
        const s = ca.surface orelse return error.MissingSurface;
        const sel = ca.selector orelse return error.MissingSelector;
        return .{ .request = .{ .scroll = .{ .surface_id = s, .selector = sel } } };
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
    return error.UnknownSubcommand;
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

const CookieArgs = struct { surface: ?u64, name: ?[]const u8, key: ?[]const u8, value: ?[]const u8, domain: ?[]const u8, path: ?[]const u8, selector: ?[]const u8, text: ?[]const u8, secure: bool };

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
    var r: CookieArgs = .{ .surface = null, .name = null, .key = null, .value = null, .domain = null, .path = null, .selector = null, .text = null, .secure = false };
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
pub fn buildRequestBytes(gpa: std.mem.Allocator, req: Request, id: cp.Id) std.mem.Allocator.Error![]u8 {
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
        .click => |c| return selectorRequest(gpa, id, "browser.click", c.surface_id, c.selector, null),
        .type_text => |c| return selectorRequest(gpa, id, "browser.type", c.surface_id, c.selector, c.text),
        .scroll => |c| return selectorRequest(gpa, id, "browser.scroll", c.surface_id, c.selector, null),
        .wait => |w| {
            var obj: std.json.ObjectMap = .empty;
            defer obj.deinit(gpa);
            try obj.put(gpa, "id", .{ .integer = @intCast(w.surface_id) });
            try obj.put(gpa, "condition", .{ .string = w.condition.wire() });
            if (w.selector) |selector| try obj.put(gpa, "selector", .{ .string = selector });
            try obj.put(gpa, "timeout_ms", .{ .integer = w.timeout_ms });
            return cp.serializeMessage(gpa, .{ .request = .{ .id = id, .method = "browser.wait", .params = .{ .object = obj } } });
        },
    }
}

/// act 요청 바이트: `{id, selector, text?}`. text null이면 selector만(click/scroll). caller free.
fn selectorRequest(gpa: std.mem.Allocator, id: cp.Id, method: []const u8, surface_id: u64, selector: []const u8, text: ?[]const u8) std.mem.Allocator.Error![]u8 {
    return twoFieldRequest(gpa, id, method, surface_id, "selector", selector, "text", text);
}

/// localStorage 요청 바이트: `{id, key, value?}`. value null이면 key만(get/remove). caller free.
fn keyRequest(gpa: std.mem.Allocator, id: cp.Id, method: []const u8, surface_id: u64, key: []const u8, value: ?[]const u8) std.mem.Allocator.Error![]u8 {
    return twoFieldRequest(gpa, id, method, surface_id, "key", key, "value", value);
}

/// 23차 [8]: `{id, <req_field>, <opt_field>?}` 모양 요청 빌더 공용(act=selector/text·localStorage=key/value가 필드명만
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
/// 부재면 `{id}`만=전체 뷰·기기 배율). 응답은 단일이 아니라 chunk 스트림이라 렌더는 `ScreenshotAssembler`가 맡는다
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
pub const ResponseKind = enum { list, navigate, get_url, exec, get_cookies, ok, value };

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
fn clampU32(v: i64) u32 {
    if (v < 0) return 0;
    if (v > std.math.maxInt(u32)) return std.math.maxInt(u32);
    return @intCast(v);
}

// ══ screenshot(5f-1) chunk 재조립(L2 순수, §9.5.7) ═══════════════════════════════════════════════════════════

/// screenshot chunk notification의 method(server→client push). control_browser의 wire 이름과 동일해야 한다(client측 상수).
const screenshot_chunk_method = cp.browser_screenshot_chunk_method; // 22차 [8]: 단일 출처(control_plane)
const execute_script_chunk_method = cp.browser_execute_script_chunk_method;

/// executeScript chunk 재조립기(5f-5b L2). 전체 결과는 max_bytes를 넘지 않으며,
/// chunk는 request/result id·encoding·seq·최종 bytes를 모두 검증한다.
pub const ExecuteScriptAssembler = struct {
    gpa: std.mem.Allocator,
    request_id: cp.Id,
    result_id: ?i64 = null,
    max_bytes: usize,
    buf: std.ArrayList(u8) = .empty,
    next_seq: i64 = 0,
    done: bool = false,

    pub const Step = enum { need_more, done, failed };

    pub fn init(gpa: std.mem.Allocator, request_id: cp.Id, max_bytes: usize) ExecuteScriptAssembler {
        return .{ .gpa = gpa, .request_id = request_id, .max_bytes = max_bytes };
    }
    pub fn deinit(self: *ExecuteScriptAssembler) void {
        self.buf.deinit(self.gpa);
    }
    pub fn bytes(self: *const ExecuteScriptAssembler) []const u8 {
        return self.buf.items;
    }

    pub fn feed(self: *ExecuteScriptAssembler, frame: []const u8) std.mem.Allocator.Error!Step {
        if (self.done) return .failed;
        var pm = cp.parseMessage(self.gpa, frame) catch {
            self.done = true;
            return .failed;
        };
        defer pm.deinit();
        const step = try switch (pm.message) {
            .notification => |n| if (std.mem.eql(u8, n.method, execute_script_chunk_method)) self.feedChunk(n.params) else .need_more,
            .response => |r| self.feedFinal(r),
            else => .failed,
        };
        if (step == .failed) self.done = true;
        return step;
    }

    fn feedChunk(self: *ExecuteScriptAssembler, params: ?std.json.Value) std.mem.Allocator.Error!Step {
        const obj = switch (params orelse return .failed) {
            .object => |o| o,
            else => return .failed,
        };
        const rid = intField(obj.get("result_id")) orelse return .failed;
        const seq = intField(obj.get("seq")) orelse return .failed;
        if (rid < 0 or seq != self.next_seq) return .failed;
        if (self.result_id) |bound| {
            if (rid != bound) return .failed;
        } else self.result_id = rid;
        const encoding = switch (obj.get("encoding") orelse return .failed) {
            .string => |s| s,
            else => return .failed,
        };
        if (!std.mem.eql(u8, encoding, "base64-json")) return .failed;
        const req = obj.get("request_id") orelse return .failed;
        const chunk_request_id = valueAsId(req) orelse return .failed;
        if (!cp.idEql(chunk_request_id, self.request_id)) return .failed;
        const encoded = switch (obj.get("data") orelse return .failed) {
            .string => |s| s,
            else => return .failed,
        };
        const decoder = std.base64.standard.Decoder;
        const n = decoder.calcSizeForSlice(encoded) catch return .failed;
        if (n > 512 * 1024 or n > self.max_bytes -| self.buf.items.len) return .failed;
        const start = self.buf.items.len;
        self.buf.resize(self.gpa, start + n) catch |err| {
            self.done = true;
            return err;
        };
        decoder.decode(self.buf.items[start..], encoded) catch return .failed;
        self.next_seq += 1;
        return .need_more;
    }

    fn feedFinal(self: *ExecuteScriptAssembler, resp: cp.Response) std.mem.Allocator.Error!Step {
        if (!cp.idEql(resp.id, self.request_id) or resp.err != null) return .failed;
        const obj = switch (resp.result orelse return .failed) {
            .object => |o| o,
            else => return .failed,
        };
        const transfer = switch (obj.get("transfer") orelse return .failed) {
            .string => |s| s,
            else => return .failed,
        };
        if (!std.mem.eql(u8, transfer, "chunked")) return .failed;
        const final_result_id = intField(obj.get("result_id")) orelse return .failed;
        const final_seq_total = intField(obj.get("seq_total")) orelse return .failed;
        const final_bytes = intField(obj.get("bytes")) orelse return .failed;
        if (self.result_id == null or final_result_id != self.result_id.? or final_seq_total != self.next_seq or final_bytes != self.buf.items.len) return .failed;
        const parsed = std.json.parseFromSlice(std.json.Value, self.gpa, self.buf.items, .{}) catch return .failed;
        defer parsed.deinit();
        self.done = true;
        return .done;
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
pub const ScreenshotAssembler = struct {
    gpa: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty, // 누적 PNG 바이트
    err_buf: std.ArrayList(u8) = .empty, // 실패 메시지(owned) — .failed 시 failureMessage()
    next_seq: i64 = 0, // 다음 기대 seq(연속성)
    capture_id: ?i64 = null,
    width: u32 = 0,
    height: u32 = 0,

    /// feed 결과: need_more(계속 read)·done(완성 — png()·width·height 유효)·failed(실패 — failureMessage()).
    pub const Step = enum { need_more, done, failed };

    pub fn init(gpa: std.mem.Allocator) ScreenshotAssembler {
        return .{ .gpa = gpa };
    }
    pub fn deinit(self: *ScreenshotAssembler) void {
        self.buf.deinit(self.gpa);
        self.err_buf.deinit(self.gpa);
    }
    pub fn png(self: *const ScreenshotAssembler) []const u8 {
        return self.buf.items;
    }
    pub fn failureMessage(self: *const ScreenshotAssembler) []const u8 {
        return self.err_buf.items;
    }

    fn fail(self: *ScreenshotAssembler, msg: []const u8) std.mem.Allocator.Error!Step {
        self.err_buf.clearRetainingCapacity();
        try self.err_buf.appendSlice(self.gpa, msg);
        return .failed;
    }

    /// 소켓 프레임 하나(개행 제외) 소비. chunk notification/최종 응답/무관 프레임을 §9.5.7 계약대로 처리.
    pub fn feed(self: *ScreenshotAssembler, frame_bytes: []const u8) std.mem.Allocator.Error!Step {
        var pm = cp.parseMessage(self.gpa, frame_bytes) catch return self.fail("malformed frame from server");
        defer pm.deinit();
        switch (pm.message) {
            .notification => |n| {
                if (!eq(n.method, screenshot_chunk_method)) return .need_more; // hello 등 무관 notification 무시
                return self.feedChunk(n.params);
            },
            .response => |r| return self.feedFinal(r),
            .request => return .need_more, // 서버가 request 보낼 일 없음 — 무시
        }
    }

    fn feedChunk(self: *ScreenshotAssembler, params: ?std.json.Value) std.mem.Allocator.Error!Step {
        const obj = switch (params orelse return self.fail("chunk missing params")) {
            .object => |o| o,
            else => return self.fail("chunk params not object"),
        };
        const cid = intField(obj.get("capture_id")) orelse return self.fail("chunk missing capture_id");
        const seq = intField(obj.get("seq")) orelse return self.fail("chunk missing seq");
        const data = switch (obj.get("data") orelse return self.fail("chunk missing data")) {
            .string => |s| s,
            else => return self.fail("chunk data not string"),
        };
        if (self.capture_id) |c| {
            if (c != cid) return self.fail("chunk capture_id mismatch");
        } else self.capture_id = cid;
        if (seq != self.next_seq) return self.fail("chunk out of order"); // FIFO 보장이나 방어
        const decoder = std.base64.standard.Decoder;
        const dlen = decoder.calcSizeForSlice(data) catch return self.fail("chunk bad base64");
        const start = self.buf.items.len;
        try self.buf.resize(self.gpa, start + dlen);
        decoder.decode(self.buf.items[start..], data) catch return self.fail("chunk bad base64");
        self.next_seq += 1;
        return .need_more;
    }

    fn feedFinal(self: *ScreenshotAssembler, resp: cp.Response) std.mem.Allocator.Error!Step {
        if (resp.err) |e| {
            var tmp: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&tmp, "server error: {s} ({d})", .{ e.message, e.code }) catch e.message;
            return self.fail(msg);
        }
        const obj = switch (resp.result orelse return self.fail("final missing result")) {
            .object => |o| o,
            else => return self.fail("final result not object"),
        };
        const seq_total = intField(obj.get("seq_total")) orelse return self.fail("final missing seq_total");
        if (seq_total != self.next_seq) return self.fail("screenshot incomplete (chunk count mismatch)"); // 누락/과다
        self.width = clampU32(intField(obj.get("width")) orelse 0);
        self.height = clampU32(intField(obj.get("height")) orelse 0);
        return .done;
    }
};

// ══ 테스트(헤드리스, Linux CI 포함 — 순수 파싱·wire·렌더) ═══════════════════════════════════════════════════
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
    // executeScript {id, script}.
    {
        const b = try buildRequestBytes(testing.allocator, .{ .exec = .{ .surface_id = 5, .script = "1+1" } }, .{ .number = 1 });
        defer testing.allocator.free(b);
        var pm = try cp.parseMessage(testing.allocator, b);
        defer pm.deinit();
        try testing.expectEqualStrings("browser.executeScript", pm.message.request.method);
        try testing.expectEqualStrings("1+1", pm.message.request.params.?.object.get("script").?.string);
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

test "ScreenshotAssembler: chunk 재조립 → PNG, seq/capture/seq_total 검증, 서버 에러" {
    const chunk0 = "{\"jsonrpc\":\"2.0\",\"method\":\"browser.screenshotChunk\",\"params\":{\"capture_id\":7,\"seq\":0,\"encoding\":\"base64\",\"data\":\"SEVM\"}}"; // "HEL"
    const chunk1 = "{\"jsonrpc\":\"2.0\",\"method\":\"browser.screenshotChunk\",\"params\":{\"capture_id\":7,\"seq\":1,\"encoding\":\"base64\",\"data\":\"TE8=\"}}"; // "LO"
    // 정상: 2 chunk → done, png()="HELLO", metadata.
    {
        var a = ScreenshotAssembler.init(testing.allocator);
        defer a.deinit();
        try testing.expectEqual(ScreenshotAssembler.Step.need_more, try a.feed(chunk0));
        try testing.expectEqual(ScreenshotAssembler.Step.need_more, try a.feed(chunk1));
        try testing.expectEqual(ScreenshotAssembler.Step.done, try a.feed("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"capture_id\":7,\"seq_total\":2,\"width\":800,\"height\":600,\"format\":\"png\"}}"));
        try testing.expectEqualStrings("HELLO", a.png());
        try testing.expectEqual(@as(u32, 800), a.width);
        try testing.expectEqual(@as(u32, 600), a.height);
    }
    // 무관 notification(hello 등)은 무시(need_more).
    {
        var a = ScreenshotAssembler.init(testing.allocator);
        defer a.deinit();
        try testing.expectEqual(ScreenshotAssembler.Step.need_more, try a.feed("{\"jsonrpc\":\"2.0\",\"method\":\"hello\",\"params\":{}}"));
    }
    // seq 재정렬(0 기대인데 5) → failed.
    {
        var a = ScreenshotAssembler.init(testing.allocator);
        defer a.deinit();
        try testing.expectEqual(ScreenshotAssembler.Step.failed, try a.feed("{\"jsonrpc\":\"2.0\",\"method\":\"browser.screenshotChunk\",\"params\":{\"capture_id\":7,\"seq\":5,\"data\":\"SEVM\"}}"));
    }
    // capture_id 불일치 → failed.
    {
        var a = ScreenshotAssembler.init(testing.allocator);
        defer a.deinit();
        _ = try a.feed(chunk0);
        try testing.expectEqual(ScreenshotAssembler.Step.failed, try a.feed("{\"jsonrpc\":\"2.0\",\"method\":\"browser.screenshotChunk\",\"params\":{\"capture_id\":9,\"seq\":1,\"data\":\"TE8=\"}}"));
    }
    // seq_total 불일치(1개 받았는데 5) → failed(누락 감지).
    {
        var a = ScreenshotAssembler.init(testing.allocator);
        defer a.deinit();
        _ = try a.feed(chunk0);
        try testing.expectEqual(ScreenshotAssembler.Step.failed, try a.feed("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"capture_id\":7,\"seq_total\":5,\"width\":1,\"height\":1}}"));
    }
    // 서버 에러 응답(screenshot too large) → failed, 메시지 전달.
    {
        var a = ScreenshotAssembler.init(testing.allocator);
        defer a.deinit();
        try testing.expectEqual(ScreenshotAssembler.Step.failed, try a.feed("{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32603,\"message\":\"screenshot too large\"}}"));
        try testing.expect(std.mem.indexOf(u8, a.failureMessage(), "screenshot too large") != null);
    }
}

test "ExecuteScriptAssembler: id·seq·bytes 검증 후 strict JSON 재조립" {
    const chunk0 = "{\"jsonrpc\":\"2.0\",\"method\":\"browser.executeScriptChunk\",\"params\":{\"request_id\":7,\"result_id\":9,\"seq\":0,\"encoding\":\"base64-json\",\"data\":\"eyJh\"}}";
    const chunk1 = "{\"jsonrpc\":\"2.0\",\"method\":\"browser.executeScriptChunk\",\"params\":{\"request_id\":7,\"result_id\":9,\"seq\":1,\"encoding\":\"base64-json\",\"data\":\"IjoxfQ==\"}}";
    const final = "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"transfer\":\"chunked\",\"result_id\":9,\"seq_total\":2,\"bytes\":7}}";
    var a = ExecuteScriptAssembler.init(testing.allocator, .{ .number = 7 }, 32);
    defer a.deinit();
    try testing.expectEqual(ExecuteScriptAssembler.Step.need_more, try a.feed(chunk0));
    try testing.expectEqual(ExecuteScriptAssembler.Step.need_more, try a.feed(chunk1));
    try testing.expectEqual(ExecuteScriptAssembler.Step.done, try a.feed(final));
    try testing.expectEqualStrings("{\"a\":1}", a.bytes());
    try testing.expectEqual(ExecuteScriptAssembler.Step.failed, try a.feed(final)); // terminal latch
}

test "ExecuteScriptAssembler: mismatch·잘못된 encoding·상한·invalid JSON 거부" {
    const bad_id = "{\"jsonrpc\":\"2.0\",\"method\":\"browser.executeScriptChunk\",\"params\":{\"request_id\":8,\"result_id\":9,\"seq\":0,\"encoding\":\"base64-json\",\"data\":\"e30=\"}}";
    var id_a = ExecuteScriptAssembler.init(testing.allocator, .{ .number = 7 }, 8);
    defer id_a.deinit();
    try testing.expectEqual(ExecuteScriptAssembler.Step.failed, try id_a.feed(bad_id));

    const bad_encoding = "{\"jsonrpc\":\"2.0\",\"method\":\"browser.executeScriptChunk\",\"params\":{\"request_id\":7,\"result_id\":9,\"seq\":0,\"encoding\":\"base64\",\"data\":\"e30=\"}}";
    var enc_a = ExecuteScriptAssembler.init(testing.allocator, .{ .number = 7 }, 8);
    defer enc_a.deinit();
    try testing.expectEqual(ExecuteScriptAssembler.Step.failed, try enc_a.feed(bad_encoding));

    const oversized = "{\"jsonrpc\":\"2.0\",\"method\":\"browser.executeScriptChunk\",\"params\":{\"request_id\":7,\"result_id\":9,\"seq\":0,\"encoding\":\"base64-json\",\"data\":\"e30=\"}}";
    var size_a = ExecuteScriptAssembler.init(testing.allocator, .{ .number = 7 }, 1);
    defer size_a.deinit();
    try testing.expectEqual(ExecuteScriptAssembler.Step.failed, try size_a.feed(oversized));

    var json_a = ExecuteScriptAssembler.init(testing.allocator, .{ .number = 7 }, 8);
    defer json_a.deinit();
    const invalid_json = "{\"jsonrpc\":\"2.0\",\"method\":\"browser.executeScriptChunk\",\"params\":{\"request_id\":7,\"result_id\":9,\"seq\":0,\"encoding\":\"base64-json\",\"data\":\"bm9wZQ==\"}}";
    _ = try json_a.feed(invalid_json);
    try testing.expectEqual(ExecuteScriptAssembler.Step.failed, try json_a.feed("{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"transfer\":\"chunked\",\"result_id\":9,\"seq_total\":1,\"bytes\":4}}"));
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

test "parse: click/type/scroll·에러" {
    switch (try parse(&.{ "click", "--surface", "3", "--selector", "#btn" })) {
        .request => |r| try testing.expectEqualStrings("#btn", r.click.selector),
        else => return error.Unexpected,
    }
    switch (try parse(&.{ "type", "--surface=3", "--selector=#in", "--text=hi" })) {
        .request => |r| {
            try testing.expectEqualStrings("#in", r.type_text.selector);
            try testing.expectEqualStrings("hi", r.type_text.text);
        },
        else => return error.Unexpected,
    }
    try testing.expectEqual(@as(u64, 5), (try parse(&.{ "scroll", "--surface", "5", "--selector", ".x" })).request.scroll.surface_id);
    try testing.expectError(error.MissingSelector, parse(&.{ "click", "--surface", "1" }));
    try testing.expectError(error.MissingText, parse(&.{ "type", "--surface", "1", "--selector", "#i" }));
    try testing.expectError(error.MissingSurface, parse(&.{ "click", "--selector", "#b" }));
}

test "buildRequestBytes: act 메서드·params" {
    {
        const b = try buildRequestBytes(testing.allocator, .{ .click = .{ .surface_id = 11, .selector = "#btn" } }, .{ .number = 1 });
        defer testing.allocator.free(b);
        var pm = try cp.parseMessage(testing.allocator, b);
        defer pm.deinit();
        try testing.expectEqualStrings("browser.click", pm.message.request.method);
        try testing.expectEqualStrings("#btn", pm.message.request.params.?.object.get("selector").?.string);
        try testing.expect(pm.message.request.params.?.object.get("text") == null);
    }
    {
        const b = try buildRequestBytes(testing.allocator, .{ .type_text = .{ .surface_id = 11, .selector = "#in", .text = "hi" } }, .{ .number = 1 });
        defer testing.allocator.free(b);
        var pm = try cp.parseMessage(testing.allocator, b);
        defer pm.deinit();
        try testing.expectEqualStrings("browser.type", pm.message.request.method);
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
        \\  exec        --surface <id> <script>    JavaScript 실행, 결과 출력
        \\  get-cookies --surface <id>             현재 문서 host의 쿠키를 JSON으로 출력
        \\  set-cookie  --surface <id> --name n --value v [--domain d] [--path p] [--secure]   쿠키 설정
        \\  delete-cookie --surface <id> --name n [--domain d] [--path p]                      쿠키 삭제
        \\  get-local-storage    --surface <id> --key k             localStorage 값 출력
        \\  set-local-storage    --surface <id> --key k --value v   localStorage 값 설정
        \\  remove-local-storage --surface <id> --key k             localStorage 항목 삭제
        \\  clear-storage        --surface <id>                     대상 origin 쿠키+스토리지 전부 삭제
        \\  click   --surface <id> --selector <css>                 셀렉터 요소 클릭
        \\  type    --surface <id> --selector <css> --text <t>      셀렉터 요소(input)에 값 입력
        \\  scroll  --surface <id> --selector <css>                 셀렉터 요소로 스크롤
        \\  wait    --surface <id> (--selector <css> | --load) [--timeout <ms>]   조건 충족까지 대기(기본·최대 25000ms)
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

test {
    testing.refAllDecls(@This());
}
