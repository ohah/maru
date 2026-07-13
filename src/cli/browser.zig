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
    \\usage: maru browser <command> --surface <id> [args]
    \\
    \\web surface(브라우저 패널)를 제어한다. <id>는 대상 web surface_id(maru sessions list로 발견).
    \\권한이 없으면 사용자에게 확인 모달이 뜨고, 허용하면 실행된다(§9.2 Model B).
    \\
    \\commands:
    \\  navigate    --surface <id> <url>       URL로 이동
    \\  get-url     --surface <id>             현재 문서 URL 출력
    \\  exec        --surface <id> <script>    JavaScript 실행, 결과 출력
    \\  get-cookies --surface <id>             현재 문서 host의 쿠키를 JSON으로 출력
    \\
;

// ── 명령 모델 ─────────────────────────────────────────────────────────────────────────────────────────────

/// `browser.*` 요청(핵심 4개). id는 대상 web surface_id.
pub const Request = union(enum) {
    navigate: struct { surface_id: u64, url: []const u8 },
    get_url: struct { surface_id: u64 },
    exec: struct { surface_id: u64, script: []const u8 },
    get_cookies: struct { surface_id: u64 },

    /// 응답 렌더용 종류(어느 result 모양인지). renderResponse가 소비.
    pub fn kind(self: Request) ResponseKind {
        return switch (self) {
            .navigate => .navigate,
            .get_url => .get_url,
            .exec => .exec,
            .get_cookies => .get_cookies,
        };
    }
};

pub const Command = union(enum) {
    request: Request,
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

// ══ client wire ════════════════════════════════════════════════════════════════════════════════════════════

/// 파싱된 `Request` → JSON-RPC 요청 바이트 한 줄(1a `serializeMessage` 재사용). caller free. 메서드명은 camelCase
/// (control_browser `parseBrowserMethod` 계약: navigate/getUrl/executeScript/getCookies).
pub fn buildRequestBytes(gpa: std.mem.Allocator, req: Request, id: cp.Id) std.mem.Allocator.Error![]u8 {
    switch (req) {
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
    }
}

fn idOnlyRequest(gpa: std.mem.Allocator, id: cp.Id, method: []const u8, surface_id: u64) std.mem.Allocator.Error![]u8 {
    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(gpa);
    try obj.put(gpa, "id", .{ .integer = @intCast(surface_id) });
    return cp.serializeMessage(gpa, .{ .request = .{ .id = id, .method = method, .params = .{ .object = obj } } });
}

// ══ 응답 렌더 ══════════════════════════════════════════════════════════════════════════════════════════════

/// 어느 요청의 응답인지 — result 모양을 안다(navigate={ok}·get_url={url}·exec={result}·get_cookies={cookies}).
pub const ResponseKind = enum { navigate, get_url, exec, get_cookies };

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
        .navigate => {
            if (boolField(result.get("ok"))) try w.writeAll("ok\n") else try w.writeAll("error: navigate not ok\n");
        },
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

// ══ 테스트(헤드리스, Linux CI 포함 — 순수 파싱·wire·렌더) ═══════════════════════════════════════════════════
const testing = std.testing;

test "parse: navigate/get-url/exec/get-cookies + --surface" {
    switch (try parse(&.{ "navigate", "--surface", "11", "https://a/" })) {
        .request => |r| {
            try testing.expectEqual(@as(u64, 11), r.navigate.surface_id);
            try testing.expectEqualStrings("https://a/", r.navigate.url);
        },
        .help => return error.Unexpected,
    }
    // --surface=N 형태 + 순서 무관(url 먼저).
    switch (try parse(&.{ "navigate", "https://b/", "--surface=7" })) {
        .request => |r| try testing.expectEqual(@as(u64, 7), r.navigate.surface_id),
        .help => return error.Unexpected,
    }
    try testing.expectEqual(@as(u64, 3), (try parse(&.{ "get-url", "--surface", "3" })).request.get_url.surface_id);
    switch (try parse(&.{ "exec", "--surface", "5", "document.title" })) {
        .request => |r| try testing.expectEqualStrings("document.title", r.exec.script),
        .help => return error.Unexpected,
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

test {
    testing.refAllDecls(@This());
}
