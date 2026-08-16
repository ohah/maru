//! `maru sessions` / `maru session` 서브커맨드의 **순수 CLI 로직** — 인자 파싱, `--help` 텍스트, client wire
//! (요청 바이트 조립·응답 포맷). Track C slice 1d. 단일 출처: docs/control-plane.md §6·docs/control-plane-implementation.md §11(CLI help gate·코드
//! 배치 gate)·§16(CLI = src/cli.zig).
//!
//! **무엇을 하나**: read-only 메타데이터 조회 CLI다.
//!   - `maru sessions list [--window <id>]` → `sessions.list {window?}` 요청.
//!   - `maru session get <id>` → `session.get {id}` 요청(id=surface_id).
//! `main.zig`는 얇은 impure 접착(소켓 connect·stdout·argv 수집)만 하고, 파싱·요청 조립·응답 포맷 같은 테스트
//! 가능한 로직은 여기 둔다(cli/ssh.zig·install.zig와 같은 패턴 — docs/project-structure.md `src/cli/`).
//!
//! **재사용(재구현 금지)**: 요청 바이트는 1a `control_plane.serializeMessage`, 응답 파싱은 1a `parseMessage`.
//! 응답 Surface 필드 이름은 1c `control_surface` wire 스키마(§3)를 소비한다. 서버측 라우팅/scope 판정은 1d
//! `control_dispatch`(L2)가 소유하고, 여긴 client 절반(요청 만들기·응답 사람이 읽기)만.
//!
//! **§11 CLI help gate**: `--help`에는 **이 slice에서 실제 동작하는 명령만** 공개한다 — `sessions list`·
//! `session get`뿐이고, 후속 Phase의 `capture`/`send-text`/`send-keys`/`subscribe` 등은 싣지 않는다. help 텍스트는
//! 순수 상수(`sessions_help`·`session_help`)로 두고 스냅샷 테스트가 정확한 바이트를 고정한다("구현됐는데 help에
//! 없음"과 "help엔 있는데 parser 없음"을 모두 잡는 gate).
//!
//! **레이어**: cli는 presentation 층이라 session(L2)을 relative import로 소비한다(app/frame_loop.zig가
//! `../session/surface.zig`를 쓰는 것과 같은 관례 — check-boundaries는 cli를 제약하지 않는다). std + 1a만 의존.

const std = @import("std");
const path_shape = @import("../path_shape.zig"); // 후행 구분자 다듬기의 단일 출처(다섯 파일에 복제돼 있었다)
const cp = @import("../session/control_plane.zig");

// ══ 파싱 결과 타입 ═════════════════════════════════════════════════════════════════════════════════════════

/// 파싱된 read-only 요청(서브커맨드별 인자). client wire가 이걸 JSON-RPC 요청 바이트로 만든다.
pub const Request = union(enum) {
    list: List,
    get: Get,

    /// `sessions list [--window <id>]`. `window`가 있으면 그 window로 좁힌다(§6 `{window?}`).
    pub const List = struct { window: ?u64 = null };
    /// `session get <id>`. `surface_id`는 조회 대상 surface_id(§3, generation 한정은 후속).
    pub const Get = struct { surface_id: u64 };
};

/// 파싱 결과: 실제 요청이거나 `--help` 요청. main이 help면 해당 help 텍스트를 출력한다.
pub const Command = union(enum) {
    request: Request,
    help,
};

/// 파싱 실패. main이 각각에 맞는 usage/에러 메시지를 stderr에 낸다.
pub const ParseError = error{
    /// `maru sessions` / `maru session`에 서브커맨드가 없음.
    MissingSubcommand,
    /// 알 수 없는 서브커맨드(`sessions foo`).
    UnknownSubcommand,
    /// `session get`에 id가 없음.
    MissingSurfaceId,
    /// id가 비숫자/음수/범위밖.
    InvalidSurfaceId,
    /// `--window`에 값이 없음.
    MissingWindowValue,
    /// `--window` 값이 비숫자/음수.
    InvalidWindowValue,
    /// 알 수 없는 옵션(`list --bogus`).
    UnknownOption,
    /// 남는 인자(`get 5 6`, `list foo`).
    UnexpectedArgument,
};

// ══ 파서 ═══════════════════════════════════════════════════════════════════════════════════════════════════

/// `maru sessions` 뒤 인자를 파싱한다(`list [--window <id>]`). `--help`/`-h`가 있으면 `.help`.
pub fn parseSessions(args: []const []const u8) ParseError!Command {
    if (hasHelpFlag(args)) return .help;
    if (args.len == 0) return error.MissingSubcommand;
    if (std.mem.eql(u8, args[0], "list")) return .{ .request = .{ .list = try parseListArgs(args[1..]) } };
    return error.UnknownSubcommand;
}

/// `sessions list [--window <id>]`의 옵션을 파싱한다. `--window <val>`와 `--window=<val>` 두 형태 모두.
fn parseListArgs(rest: []const []const u8) ParseError!Request.List {
    var window: ?u64 = null;
    var i: usize = 0;
    while (i < rest.len) {
        const a = rest[i];
        if (std.mem.eql(u8, a, "--window")) {
            if (i + 1 >= rest.len) return error.MissingWindowValue;
            window = parseU64(rest[i + 1]) catch return error.InvalidWindowValue;
            i += 2;
        } else if (std.mem.startsWith(u8, a, "--window=")) {
            window = parseU64(a["--window=".len..]) catch return error.InvalidWindowValue;
            i += 1;
        } else if (std.mem.startsWith(u8, a, "-")) {
            return error.UnknownOption; // 알 수 없는 옵션(정의 안 된 플래그).
        } else {
            return error.UnexpectedArgument; // 위치 인자는 받지 않는다.
        }
    }
    return .{ .window = window };
}

/// `maru session` 뒤 인자를 파싱한다(`get <id>`). `--help`/`-h`가 있으면 `.help`.
pub fn parseSession(args: []const []const u8) ParseError!Command {
    if (hasHelpFlag(args)) return .help;
    if (args.len == 0) return error.MissingSubcommand;
    if (std.mem.eql(u8, args[0], "get")) {
        const rest = args[1..];
        if (rest.len == 0) return error.MissingSurfaceId;
        if (rest.len > 1) return error.UnexpectedArgument;
        const id = parseU64(rest[0]) catch return error.InvalidSurfaceId;
        return .{ .request = .{ .get = .{ .surface_id = id } } };
    }
    return error.UnknownSubcommand;
}

/// 인자 어디에든 `--help`/`-h`가 있으면 true(help가 파싱보다 우선 — `session get --help`도 help).
fn hasHelpFlag(args: []const []const u8) bool {
    for (args) |a| {
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) return true;
    }
    return false;
}

/// 10진 파싱 후 **wire i64 범위로 제한**한다. surface_id/window는 JSON integer(=i64, 1a `Id`)로 실리므로,
/// i64 상한(9.2e18, ~19자리)을 넘는 값은 wire에 담을 수 없다 — `@intCast(u64→i64)` panic 대신 `Overflow`로 거부해
/// 호출부가 깔끔한 `InvalidSurfaceId`/`InvalidWindowValue`로 접는다(20자리+ 극단 입력에도 CLI가 crash 안 함).
/// 음수·비숫자·빈 문자열·u64 범위밖은 `parseInt`가, i64 상한 초과는 아래가 거부한다.
fn parseU64(s: []const u8) !u64 {
    const v = try std.fmt.parseInt(u64, s, 10);
    if (v > std.math.maxInt(i64)) return error.Overflow;
    return v;
}

// ══ client wire ════════════════════════════════════════════════════════════════════════════════════════════

/// 파싱된 `Request` → JSON-RPC 요청 바이트 한 줄(1a `serializeMessage` 재사용). caller free.
pub fn buildRequestBytes(gpa: std.mem.Allocator, req: Request, id: cp.Id) std.mem.Allocator.Error![]u8 {
    switch (req) {
        .list => |l| {
            const w = l.window orelse
                // window 없음 → params 생략(§6 `{window?}`의 없음).
                return cp.serializeMessage(gpa, .{ .request = .{ .id = id, .method = "sessions.list", .params = null } });
            var obj: std.json.ObjectMap = .empty; // ObjectMap은 0.16서 unmanaged(put/deinit에 allocator 전달).
            defer obj.deinit(gpa);
            try obj.put(gpa, "window", .{ .integer = @intCast(w) });
            return cp.serializeMessage(gpa, .{ .request = .{ .id = id, .method = "sessions.list", .params = .{ .object = obj } } });
        },
        .get => |g| {
            var obj: std.json.ObjectMap = .empty;
            defer obj.deinit(gpa);
            try obj.put(gpa, "id", .{ .integer = @intCast(g.surface_id) });
            return cp.serializeMessage(gpa, .{ .request = .{ .id = id, .method = "session.get", .params = .{ .object = obj } } });
        },
    }
}

/// 응답이 어느 명령의 것인지(list=배열, get=단건 객체). renderResponse가 결과 모양을 안다.
pub const ResponseKind = enum { list, get };

/// 응답 바이트 한 줄을 사람이 읽을 형태로 `w`에 쓴다. 에러 응답이면 균일하게 `error: <msg> (<code>)`.
pub fn renderResponse(
    gpa: std.mem.Allocator,
    response_bytes: []const u8,
    kind: ResponseKind,
    w: *std.Io.Writer,
) !void {
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
    // 에러 응답(unauthorized·process_exited·method_not_found 등)은 kind와 무관하게 균일한 형태로.
    if (resp.err) |e| {
        try w.print("error: {s} ({d})\n", .{ e.message, e.code });
        return;
    }
    const result = resp.result orelse {
        try w.writeAll("error: empty result\n");
        return;
    };
    switch (kind) {
        .list => {
            const arr = switch (result) {
                .array => |a| a,
                else => {
                    try w.writeAll("error: expected a list result\n");
                    return;
                },
            };
            if (arr.items.len == 0) {
                try w.writeAll("(no sessions)\n");
                return;
            }
            for (arr.items) |item| try renderSurfaceLine(item, w);
        },
        .get => try renderSurfaceLine(result, w),
    }
}

/// Surface 객체 하나를 사람이 읽을 한 줄로 쓴다(1c wire 스키마 §3 소비). 공통 메타 → kind별 필드.
/// 형태: `[<sid>] <kind> "<title>" win<w>/tab<t>/pane<p>[ *focused*]<extras>`.
fn renderSurfaceLine(v: std.json.Value, w: *std.Io.Writer) !void {
    const o = switch (v) {
        .object => |o| o,
        else => {
            try w.writeAll("error: malformed surface\n");
            return;
        },
    };
    const surface_id = blk: {
        const id_obj = switch (o.get("id") orelse std.json.Value.null) {
            .object => |io| io,
            else => break :blk @as(i64, -1),
        };
        break :blk intOr(id_obj.get("surface_id"), -1);
    };
    const kind = strOr(o.get("kind"), "?");
    const title = strOr(o.get("title"), "");
    const win = intOr(o.get("window"), 0);
    const tab = intOr(o.get("tab"), 0);
    const pane = intOr(o.get("pane"), 0);
    const focused = boolOr(o.get("focused"), false);

    try w.print("[{d}] {s} \"{s}\" win{d}/tab{d}/pane{d}", .{ surface_id, kind, title, win, tab, pane });
    if (focused) try w.writeAll(" *focused*");

    if (std.mem.eql(u8, kind, "terminal")) {
        if (strField(o, "cwd")) |c| try w.print(" cwd={s}", .{c});
        if (strField(o, "git_branch")) |b| try w.print(" git={s}", .{b});
        if (o.get("agent")) |ag| switch (ag) {
            .object => |ao| try w.print(" agent={s}:{s}", .{ strOr(ao.get("kind"), "?"), strOr(ao.get("state"), "?") }),
            else => {},
        };
        // at_prompt 3상(§3): JSON true/false/null → true/false/unknown(절대 접지 않음).
        try w.print(" at_prompt={s}", .{atPromptWire(o.get("at_prompt"))});
    } else if (std.mem.eql(u8, kind, "web")) {
        if (strField(o, "url")) |u| try w.print(" url={s}", .{u});
        try w.print(" panel={s}", .{strOr(o.get("panel_kind"), "?")});
        if (boolOr(o.get("loading"), false)) try w.writeAll(" loading");
        try w.print(" trust={s}", .{strOr(o.get("trust"), "?")});
    }
    try w.writeAll("\n");
}

// ── JSON Value 읽기 헬퍼(누락/타입불일치는 기본값·null로 접어 render가 panic하지 않게) ──
fn intOr(v: ?std.json.Value, default: i64) i64 {
    return switch (v orelse return default) {
        .integer => |i| i,
        else => default,
    };
}
fn strOr(v: ?std.json.Value, default: []const u8) []const u8 {
    return switch (v orelse return default) {
        .string => |s| s,
        else => default,
    };
}
fn strField(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (o.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}
fn boolOr(v: ?std.json.Value, default: bool) bool {
    return switch (v orelse return default) {
        .bool => |b| b,
        else => default,
    };
}
/// at_prompt 3상 wire 디코딩: JSON true→"true", false→"false", null/부재→"unknown"(§3, false로 접지 않음).
fn atPromptWire(v: ?std.json.Value) []const u8 {
    return switch (v orelse return "unknown") {
        .bool => |b| if (b) "true" else "false",
        else => "unknown", // JSON null 포함.
    };
}

// ══ 소켓 발견(A2a — §4.2 다중 인스턴스·결정론 경로) ═══════════════════════════════════════════════════════
// CLI-side 순수 경로/정책(cli/ssh.zig `controlSocketPath`와 같은 결 — I/O(getenv·readdir)는 main이 하고 여긴
// 계산만). 소켓 syscall(connect/read/write)은 L4다(§11) — main.zig가 그 얇은 접착을 갖는다. 서버측 경로 파생
// (`control_socket.controlDirPath`/`socketPathIn`, L4·macOS-gated)와 **같은 `<cache>/maru/control/*.sock` 계약**을
// 공유한다(그 파일은 dev-CLI 모듈 그래프 밖이라 여기서 같은 형식을 CLI-side로 둔다 — cli/ssh.zig 선례).

/// 컨트롤 소켓 디렉터리 경로 `<cache>/maru/control`. `cache` = `$XDG_CACHE_HOME`(설정+비어있지 않음) else
/// `<home>/.cache`(셸 `${XDG_CACHE_HOME:-$HOME/.cache}` 규칙 — terminfo_cache.cacheDirZ와 동일). trailing slash는
/// 떼어 이중 슬래시를 막는다. caller free. 서버(A2b)가 `control_socket.controlDirPath(<cache>/maru)`로 만드는
/// 것과 같은 경로로 resolve된다(§4.2 단일 계약).
pub fn controlDir(gpa: std.mem.Allocator, xdg_cache_home: ?[]const u8, home: []const u8) std.mem.Allocator.Error![]u8 {
    if (xdg_cache_home) |x| {
        if (x.len > 0) return std.fmt.allocPrint(gpa, "{s}/maru/control", .{path_shape.trimTrailingSep(x)});
    }
    return std.fmt.allocPrint(gpa, "{s}/.cache/maru/control", .{path_shape.trimTrailingSep(home)});
}

/// 컨트롤 디렉터리의 엔트리 이름들에서 살아있는 인스턴스 소켓을 고르는 순수 정책(§4.2). `.sock`으로 끝나는 항목이
/// 정확히 하나면 `single`(그 이름 borrow), 없으면 `none`, 둘 이상이면 `multiple`이다. main이 readdir 결과를 넘긴다.
/// **A2a는 단일 인스턴스 자동 발견까지만**이다 — 여럿 중 선택 어휘(`$MARU_SESSION` selector 매칭 등)는 미정(§13).
pub const SocketDiscovery = union(enum) {
    /// 살아있는 소켓 없음 → main은 "실행 중인 maru 인스턴스를 찾지 못했습니다"로 접는다.
    none,
    /// 정확히 하나 → 이 `.sock` 파일명(디렉터리 엔트리 borrow, main이 dir과 조합).
    single: []const u8,
    /// 둘 이상 → 선택 어휘 미정(§13). main은 graceful하게 알린다.
    multiple,
};

/// 엔트리 이름 목록에서 `.sock` 하나를 고른다(위 정책). 순수 — I/O 없음.
pub fn pickSocket(entries: []const []const u8) SocketDiscovery {
    var found: ?[]const u8 = null;
    for (entries) |e| {
        if (!std.mem.endsWith(u8, e, ".sock")) continue;
        if (found != null) return .multiple; // 둘째 발견 → 즉시 multiple.
        found = e;
    }
    return if (found) |f| .{ .single = f } else .none;
}

// ══ --help 텍스트(§11 CLI help gate — 구현된 명령만) ════════════════════════════════════════════════════════

/// `maru sessions --help`. 이 slice에서 동작하는 `list`만 공개한다(후속 명령 미기재 — §11).
pub const sessions_help =
    \\usage:
    \\  maru sessions list [--window <id>]
    \\
    \\list running Maru sessions (surfaces) with read-only metadata.
    \\
    \\options:
    \\  --window <id>   only list surfaces in window <id>
    \\
;

/// `maru session --help`. 이 slice에서 동작하는 `get`만 공개한다(후속 명령 미기재 — §11).
pub const session_help =
    \\usage:
    \\  maru session get <id>
    \\
    \\show read-only metadata for a single surface by id.
    \\
;

// ══ 테스트(헤드리스, Linux CI 포함 — 순수 로직) ══════════════════════════════════════════════════════════════
const testing = std.testing;

// ── 파서: sessions list ──
test "parseSessions: list(플래그 없음) → window=null" {
    const c = try parseSessions(&.{"list"});
    try testing.expect(c == .request);
    try testing.expect(c.request == .list);
    try testing.expect(c.request.list.window == null);
}

test "parseSessions: list --window <id> (공백/= 두 형태)" {
    {
        const c = try parseSessions(&.{ "list", "--window", "2" });
        try testing.expectEqual(@as(?u64, 2), c.request.list.window);
    }
    {
        const c = try parseSessions(&.{ "list", "--window=7" });
        try testing.expectEqual(@as(?u64, 7), c.request.list.window);
    }
}

test "parseSessions: 인자 부족·잉여·비숫자·미지 옵션·미지 서브커맨드 에러" {
    try testing.expectError(error.MissingSubcommand, parseSessions(&.{}));
    try testing.expectError(error.UnknownSubcommand, parseSessions(&.{"foo"}));
    try testing.expectError(error.MissingWindowValue, parseSessions(&.{ "list", "--window" }));
    try testing.expectError(error.InvalidWindowValue, parseSessions(&.{ "list", "--window", "abc" }));
    try testing.expectError(error.InvalidWindowValue, parseSessions(&.{ "list", "--window", "-1" }));
    try testing.expectError(error.InvalidWindowValue, parseSessions(&.{ "list", "--window=" }));
    try testing.expectError(error.UnknownOption, parseSessions(&.{ "list", "--bogus" }));
    try testing.expectError(error.UnexpectedArgument, parseSessions(&.{ "list", "extra" }));
}

test "parseSessions: --help/-h는 어디에 있든 .help" {
    try testing.expect((try parseSessions(&.{"--help"})) == .help);
    try testing.expect((try parseSessions(&.{"-h"})) == .help);
    try testing.expect((try parseSessions(&.{ "list", "--help" })) == .help);
    try testing.expect((try parseSessions(&.{ "list", "--window", "2", "--help" })) == .help);
}

// ── 파서: session get ──
test "parseSession: get <id> → surface_id" {
    const c = try parseSession(&.{ "get", "5" });
    try testing.expect(c.request == .get);
    try testing.expectEqual(@as(u64, 5), c.request.get.surface_id);
}

test "parseSession: 인자 부족·잉여·비숫자·음수·미지 서브커맨드 에러" {
    try testing.expectError(error.MissingSubcommand, parseSession(&.{}));
    try testing.expectError(error.UnknownSubcommand, parseSession(&.{"foo"}));
    try testing.expectError(error.MissingSurfaceId, parseSession(&.{"get"}));
    try testing.expectError(error.InvalidSurfaceId, parseSession(&.{ "get", "abc" }));
    try testing.expectError(error.InvalidSurfaceId, parseSession(&.{ "get", "-1" }));
    try testing.expectError(error.UnexpectedArgument, parseSession(&.{ "get", "5", "6" }));
    // wire i64 상한 초과(i64max+1, u64엔 유효)는 @intCast panic이 아니라 깔끔한 InvalidSurfaceId로 거부(code-review 반영).
    try testing.expectError(error.InvalidSurfaceId, parseSession(&.{ "get", "9223372036854775808" }));
}

test "parseSessions: --window i64 상한 초과(20자리)는 panic 대신 InvalidWindowValue" {
    try testing.expectError(error.InvalidWindowValue, parseSessions(&.{ "list", "--window", "99999999999999999999" }));
    // 경계: i64 max(9223372036854775807)는 허용, +1은 거부.
    try testing.expect((try parseSessions(&.{ "list", "--window", "9223372036854775807" })) == .request);
    try testing.expectError(error.InvalidWindowValue, parseSessions(&.{ "list", "--window", "9223372036854775808" }));
}

test "parseSession: --help/-h는 .help(id 자리의 --help도 help)" {
    try testing.expect((try parseSession(&.{"--help"})) == .help);
    try testing.expect((try parseSession(&.{ "get", "--help" })) == .help);
}

// ── --help 스냅샷(§11 gate: 구현된 명령만) ──
test "help 스냅샷: sessions/session help는 구현된 명령만 정확히 공개한다" {
    // 정확한 텍스트 고정(바이트 스냅샷).
    try testing.expectEqualStrings(
        "usage:\n  maru sessions list [--window <id>]\n\nlist running Maru sessions (surfaces) with read-only metadata.\n\noptions:\n  --window <id>   only list surfaces in window <id>\n",
        sessions_help,
    );
    try testing.expectEqualStrings(
        "usage:\n  maru session get <id>\n\nshow read-only metadata for a single surface by id.\n",
        session_help,
    );
    // 구현된 명령을 담는다.
    try testing.expect(std.mem.indexOf(u8, sessions_help, "list") != null);
    try testing.expect(std.mem.indexOf(u8, session_help, "get") != null);
    // 후속 Phase 명령은 아직 help에 없어야 한다(gate: help에는 있는데 parser 없음 방지).
    for ([_][]const u8{ "capture", "send-text", "send-keys", "subscribe", "panel", "browser" }) |future| {
        try testing.expect(std.mem.indexOf(u8, sessions_help, future) == null);
        try testing.expect(std.mem.indexOf(u8, session_help, future) == null);
    }
}

// ── client wire: 요청 바이트 조립 ──
test "buildRequestBytes: sessions.list(window 없음) → params 생략" {
    const bytes = try buildRequestBytes(testing.allocator, .{ .list = .{} }, .{ .number = 1 });
    defer testing.allocator.free(bytes);
    var pm = try cp.parseMessage(testing.allocator, bytes);
    defer pm.deinit();
    try testing.expect(pm.message == .request);
    try testing.expectEqualStrings("sessions.list", pm.message.request.method);
    try testing.expect(pm.message.request.params == null); // window 없으면 params 생략
}

test "buildRequestBytes: sessions.list --window → params.window" {
    const bytes = try buildRequestBytes(testing.allocator, .{ .list = .{ .window = 2 } }, .{ .number = 1 });
    defer testing.allocator.free(bytes);
    var pm = try cp.parseMessage(testing.allocator, bytes);
    defer pm.deinit();
    try testing.expectEqual(@as(i64, 2), pm.message.request.params.?.object.get("window").?.integer);
}

test "buildRequestBytes: session.get → method + params.id, 한 줄" {
    const bytes = try buildRequestBytes(testing.allocator, .{ .get = .{ .surface_id = 42 } }, .{ .string = "req-1" });
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.indexOfScalar(u8, bytes, '\n') == null); // 한 줄
    var pm = try cp.parseMessage(testing.allocator, bytes);
    defer pm.deinit();
    try testing.expectEqualStrings("session.get", pm.message.request.method);
    try testing.expectEqual(@as(i64, 42), pm.message.request.params.?.object.get("id").?.integer);
    try testing.expect(cp.idEql(pm.message.request.id, .{ .string = "req-1" }));
}

// ── client wire: 응답 포맷 ──
// 실제 서버 응답 바이트를 흉내내 render를 검증한다(control_surface 스키마 소비).
fn render(bytes: []const u8, kind: ResponseKind, out: *std.ArrayList(u8)) !void {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try renderResponse(testing.allocator, bytes, kind, &aw.writer);
    try out.appendSlice(testing.allocator, aw.written());
}

test "renderResponse: sessions.list 결과를 surface 줄로 렌더(터미널·web·에이전트·at_prompt)" {
    const wire =
        \\{"jsonrpc":"2.0","id":1,"result":[{"id":{"surface_id":10,"generation":0},"kind":"terminal","title":"shell-a","window":1,"tab":0,"pane":0,"focused":true,"cwd":"/home/a","git_branch":"main","agent":{"kind":"claude","state":"running"},"at_prompt":false},{"id":{"surface_id":11,"generation":0},"kind":"web","title":"docs","window":1,"tab":1,"pane":0,"focused":false,"url":"https://x/y","panel_kind":"markdown","loading":false,"trust":"trusted"}]}
    ;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try render(wire, .list, &out);
    const s = out.items;
    try testing.expect(std.mem.indexOf(u8, s, "[10]") != null);
    try testing.expect(std.mem.indexOf(u8, s, "terminal") != null);
    try testing.expect(std.mem.indexOf(u8, s, "shell-a") != null);
    try testing.expect(std.mem.indexOf(u8, s, "win1/tab0/pane0") != null);
    try testing.expect(std.mem.indexOf(u8, s, "cwd=/home/a") != null);
    try testing.expect(std.mem.indexOf(u8, s, "git=main") != null);
    try testing.expect(std.mem.indexOf(u8, s, "agent=claude:running") != null);
    try testing.expect(std.mem.indexOf(u8, s, "at_prompt=false") != null);
    try testing.expect(std.mem.indexOf(u8, s, "[11]") != null);
    try testing.expect(std.mem.indexOf(u8, s, "web") != null);
    try testing.expect(std.mem.indexOf(u8, s, "url=https://x/y") != null);
    try testing.expect(std.mem.indexOf(u8, s, "trust=trusted") != null);
}

test "renderResponse: 빈 목록 → (no sessions)" {
    const wire =
        \\{"jsonrpc":"2.0","id":1,"result":[]}
    ;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try render(wire, .list, &out);
    try testing.expect(std.mem.indexOf(u8, out.items, "(no sessions)") != null);
}

test "renderResponse: session.get 단건 객체를 렌더" {
    const wire =
        \\{"jsonrpc":"2.0","id":1,"result":{"id":{"surface_id":20,"generation":2},"kind":"terminal","title":"shell-b","window":2,"tab":0,"pane":0,"focused":false,"cwd":"/srv/b","at_prompt":true}}
    ;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try render(wire, .get, &out);
    const s = out.items;
    try testing.expect(std.mem.indexOf(u8, s, "[20]") != null);
    try testing.expect(std.mem.indexOf(u8, s, "shell-b") != null);
    try testing.expect(std.mem.indexOf(u8, s, "at_prompt=true") != null);
}

test "renderResponse: 에러 응답(unauthorized)은 균일 error 메시지로" {
    const wire =
        \\{"jsonrpc":"2.0","id":1,"error":{"code":-32002,"message":"Unauthorized"}}
    ;
    // list·get 어느 kind든 에러는 같은 형태로 렌더된다.
    for ([_]ResponseKind{ .list, .get }) |k| {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(testing.allocator);
        try render(wire, k, &out);
        try testing.expect(std.mem.indexOf(u8, out.items, "error:") != null);
        try testing.expect(std.mem.indexOf(u8, out.items, "Unauthorized") != null);
        try testing.expect(std.mem.indexOf(u8, out.items, "-32002") != null);
    }
}

test "renderResponse: at_prompt unknown(JSON null)은 unknown으로" {
    const wire =
        \\{"jsonrpc":"2.0","id":1,"result":{"id":{"surface_id":30,"generation":0},"kind":"terminal","title":"quick","window":3,"tab":0,"pane":0,"focused":false,"at_prompt":null}}
    ;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try render(wire, .get, &out);
    try testing.expect(std.mem.indexOf(u8, out.items, "at_prompt=unknown") != null);
}

// ── 커버리지 보강(test/foundation-coverage-gaps) ──────────────────────────────────────────────────────────

// renderResponse의 방어 분기(파싱 실패·비-response·list인데 배열 아님·surface가 객체 아님)는 정상 응답만 넣던
// 기존 테스트가 하나도 안 밟았다. 사용자에게 노출되는 실패 경로라 각 메시지를 못박는다.
test "renderResponse 방어 경로: 손상 응답·비-response·잘못된 result 모양이 각각 명확한 error 줄로" {
    // (a) 파싱 실패 바이트 → "malformed response from server".
    {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(testing.allocator);
        try render("{not json", .list, &out);
        try testing.expect(std.mem.indexOf(u8, out.items, "malformed response from server") != null);
    }
    // (b) response가 아닌 메시지(notification) → "unexpected message (not a response)".
    {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(testing.allocator);
        try render("{\"jsonrpc\":\"2.0\",\"method\":\"hello\"}", .get, &out);
        try testing.expect(std.mem.indexOf(u8, out.items, "not a response") != null);
    }
    // (c) kind=list인데 result가 배열이 아님(단건 객체) → "expected a list result".
    {
        const wire =
            \\{"jsonrpc":"2.0","id":1,"result":{"id":{"surface_id":1,"generation":0},"kind":"terminal","title":"x","window":0,"tab":0,"pane":0,"focused":false,"at_prompt":null}}
        ;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(testing.allocator);
        try render(wire, .list, &out);
        try testing.expect(std.mem.indexOf(u8, out.items, "expected a list result") != null);
    }
    // (d) list 배열 안에 객체 아닌 항목 → "malformed surface"(개별 항목 방어).
    {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(testing.allocator);
        try render("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":[5]}", .list, &out);
        try testing.expect(std.mem.indexOf(u8, out.items, "malformed surface") != null);
    }
}

// web surface의 loading=true 렌더 분기(" loading" 부착)는 기존 테스트가 loading:false만 써서 안 밟혔다.
test "renderResponse: web surface loading=true면 'loading' 표시" {
    const wire =
        \\{"jsonrpc":"2.0","id":1,"result":{"id":{"surface_id":11,"generation":0},"kind":"web","title":"docs","window":1,"tab":0,"pane":0,"focused":false,"url":"https://x/y","panel_kind":"browser","loading":true,"trust":"untrusted"}}
    ;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try render(wire, .get, &out);
    try testing.expect(std.mem.indexOf(u8, out.items, " loading") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "panel=browser") != null);
}

// ── A2a: 소켓 발견 순수 정책(단일 인스턴스 결정론 경로 — §4.2) ──────────────────────────────────────────────

test "controlDir: XDG_CACHE_HOME 우선, 없으면 <home>/.cache, trailing slash 정규화" {
    {
        const d = try controlDir(testing.allocator, "/x/cache", "/home/me");
        defer testing.allocator.free(d);
        try testing.expectEqualStrings("/x/cache/maru/control", d);
    }
    {
        const d = try controlDir(testing.allocator, null, "/home/me");
        defer testing.allocator.free(d);
        try testing.expectEqualStrings("/home/me/.cache/maru/control", d);
    }
    {
        // 빈 XDG_CACHE_HOME은 미설정으로 취급(shell ${XDG_CACHE_HOME:-...} 규칙).
        const d = try controlDir(testing.allocator, "", "/home/me");
        defer testing.allocator.free(d);
        try testing.expectEqualStrings("/home/me/.cache/maru/control", d);
    }
    {
        // trailing slash는 떼어 이중 슬래시를 막는다.
        const d = try controlDir(testing.allocator, "/x/cache/", "/home/me");
        defer testing.allocator.free(d);
        try testing.expectEqualStrings("/x/cache/maru/control", d);
    }
}

test "pickSocket: .sock 항목이 정확히 하나면 single, 0개면 none, 2개+면 multiple(§4.2 단일 인스턴스)" {
    // 없음(빈 목록/비-.sock만).
    try testing.expect(pickSocket(&.{}) == .none);
    try testing.expect(pickSocket(&.{ "a.lock", "notes.txt" }) == .none);
    // 단일 — 이름을 그대로 돌려준다(borrow).
    {
        const p = pickSocket(&.{ "1234-ab.sock", "1234-ab.lock" });
        try testing.expect(p == .single);
        try testing.expectEqualStrings("1234-ab.sock", p.single);
    }
    // 여럿 — 어느 것을 고를지 어휘 미정(§13)이라 multiple로 접는다.
    try testing.expect(pickSocket(&.{ "a.sock", "b.sock" }) == .multiple);
    try testing.expect(pickSocket(&.{ "a.sock", "x.lock", "b.sock", "c.sock" }) == .multiple);
}

test {
    testing.refAllDecls(@This());
}
