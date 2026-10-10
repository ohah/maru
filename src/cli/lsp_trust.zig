//! `maru editor lsp trust` 서브커맨드의 **순수 CLI 로직** — 인자 파싱·`--help`·client wire(요청 바이트 조립·응답 포맷). 계획
//! docs/plans/workspace-trust.md WT4b, 메서드 docs/control-plane.md §6(`lsp.trust.*`), wire 절반은 `session/control_lsp_trust.zig`.
//!
//! **무엇을 하나**: 언어 서버 신뢰 결정을 **조회·철회·잊기**만 한다 — 부여 명령은 없다(에이전트가 신뢰를 주지 못하게, 계획 WT2).
//!   - `maru editor lsp trust list` → `lsp.trust.list`.
//!   - `maru editor lsp trust revoke <path> [--volume <hex>]` → `lsp.trust.revoke {path, volume?}` — 지금 허용인 저장소를 거부로.
//!   - `maru editor lsp trust forget <path> [--volume <hex>]` → `lsp.trust.forget {path, volume?}` — 결정을 지운다(다시 열면 묻는다).
//! 소켓 접착은 `cli/control_client.zig`(셀렉터 없이 — 앱 전역 표라 자기 패인으로 좁힐 이유가 없다, 2026-10-09 사용자 결정), 상대 경로를
//! 절대 경로로 펴는 데 쓸 현재 디렉터리는 `main.zig` 가 준다.

const std = @import("std");
const cp = @import("../session/control_plane.zig");

pub const Request = union(enum) {
    list,
    revoke: Target,
    forget: Target,

    /// `path` 는 절대 경로(`absolutize` 가 편다), `volume` 은 목록이 보여 준 16진 그대로.
    pub const Target = struct { path: []const u8, volume: ?u64 = null };
};

pub const Command = union(enum) {
    request: Request,
    help,
};

pub const ParseError = error{
    /// `maru editor lsp` 뒤에 `trust` 가 없다.
    MissingTopic,
    /// `maru editor lsp foo`.
    UnknownTopic,
    /// `maru editor lsp trust` 뒤에 서브커맨드가 없다.
    MissingSubcommand,
    /// `maru editor lsp trust grant` 등.
    UnknownSubcommand,
    /// `revoke`·`forget` 에 경로가 없다.
    MissingPath,
    /// `--volume` 값이 없다.
    MissingVolumeValue,
    /// Reject repeated target selection, including a valid zero.
    DuplicateVolume,
    /// `--volume` 값이 16진이 아니다.
    InvalidVolumeValue,
    UnknownOption,
    UnexpectedArgument,
};

/// `maru editor lsp` 뒤 인자. `--help`/`-h` 가 어디 있든 help.
pub fn parse(args: []const []const u8) ParseError!Command {
    for (args) |a| if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) return .help;
    if (args.len == 0) return error.MissingTopic;
    if (!std.mem.eql(u8, args[0], "trust")) return error.UnknownTopic;
    const rest = args[1..];
    if (rest.len == 0) return error.MissingSubcommand;
    const sub = rest[0];
    if (std.mem.eql(u8, sub, "list")) {
        if (rest.len > 1) return if (std.mem.startsWith(u8, rest[1], "-")) error.UnknownOption else error.UnexpectedArgument;
        return .{ .request = .list };
    }
    const is_revoke = std.mem.eql(u8, sub, "revoke");
    if (!is_revoke and !std.mem.eql(u8, sub, "forget")) return error.UnknownSubcommand;
    var path: ?[]const u8 = null;
    var volume: ?u64 = null;
    var i: usize = 1;
    while (i < rest.len) {
        const a = rest[i];
        if (std.mem.eql(u8, a, "--volume")) {
            if (i + 1 >= rest.len) return error.MissingVolumeValue;
            try assignVolume(&volume, rest[i + 1]);
            i += 2;
        } else if (std.mem.startsWith(u8, a, "--volume=")) {
            try assignVolume(&volume, a["--volume=".len..]);
            i += 1;
        } else if (std.mem.startsWith(u8, a, "-")) {
            return error.UnknownOption;
        } else {
            if (path != null) return error.UnexpectedArgument;
            // 빈 인자는 경로가 아니다 — 펴면 현재 디렉터리가 되어 엉뚱한 저장소에 닿는다(`"$REPO"` 가 비었다).
            if (a.len == 0) return error.MissingPath;
            path = a;
            i += 1;
        }
    }
    const target: Request.Target = .{ .path = path orelse return error.MissingPath, .volume = volume };
    return .{ .request = if (is_revoke) .{ .revoke = target } else .{ .forget = target } };
}

/// 상대 경로를 `cwd` 기준 절대 경로로 편다(서버는 CLI 의 현재 디렉터리를 모른다). 이미 절대면 그대로 복사. `.`·`..` 는 정리한다 —
/// 심링크는 서버가 실제 경로로 푼다. caller free.
pub fn absolutize(gpa: std.mem.Allocator, cwd: []const u8, path: []const u8) std.mem.Allocator.Error![]u8 {
    return std.fs.path.resolve(gpa, &.{ cwd, path });
}

// Do not let a later mount selector replace the repository target chosen earlier.
fn assignVolume(target: *?u64, value: []const u8) ParseError!void {
    if (target.* != null) return error.DuplicateVolume;
    target.* = std.fmt.parseInt(u64, value, 16) catch return error.InvalidVolumeValue;
}

pub fn buildRequestBytes(gpa: std.mem.Allocator, req: Request, id: cp.Id) std.mem.Allocator.Error![]u8 {
    const method, const target = switch (req) {
        .list => return cp.serializeMessage(gpa, .{ .request = .{ .id = id, .method = "lsp.trust.list", .params = null } }),
        .revoke => |t| .{ "lsp.trust.revoke", t },
        .forget => |t| .{ "lsp.trust.forget", t },
    };
    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(gpa);
    try obj.put(gpa, "path", .{ .string = target.path });
    var vbuf: [16]u8 = undefined;
    if (target.volume) |v| try obj.put(gpa, "volume", .{ .string = std.fmt.bufPrint(&vbuf, "{x}", .{v}) catch unreachable });
    return cp.serializeMessage(gpa, .{ .request = .{ .id = id, .method = method, .params = .{ .object = obj } } });
}

pub const ResponseKind = enum { list, revoke, forget };

pub fn kindOf(req: Request) ResponseKind {
    return switch (req) {
        .list => .list,
        .revoke => .revoke,
        .forget => .forget,
    };
}

/// 응답을 사람이 읽게 쓴다. 성공했으면 `true` — 오류 응답·모르는 모양이면 `false`(main 이 종료 코드로 쓴다). 철회·잊기에서 `path` 는
/// 요청 경로(main 이 절대 경로로 편 것 — 맞은 저장소와 다르면 문구에 「matched」로 보인다).
pub fn renderResponse(gpa: std.mem.Allocator, response_bytes: []const u8, kind: ResponseKind, path: []const u8, w: *std.Io.Writer) !bool {
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
        if (e.code == @intFromEnum(cp.ErrorCode.method_not_found))
            try w.print("error: this Maru does not support language server trust commands ({d})\n", .{e.code})
        else
            try w.print("error: {s} ({d})\n", .{ e.message, e.code });
        return false;
    }
    const obj = switch (resp.result orelse std.json.Value.null) {
        .object => |o| o,
        else => {
            try w.writeAll("error: unexpected result\n");
            return false;
        },
    };
    switch (kind) {
        .list => {
            const arr = switch (obj.get("decisions") orelse std.json.Value.null) {
                .array => |a| a.items,
                else => {
                    try w.writeAll("error: unexpected result\n");
                    return false;
                },
            };
            if (arr.len == 0) {
                try w.writeAll("(no language server trust decisions)\n");
                return true;
            }
            for (arr) |item| {
                const o = switch (item) {
                    .object => |o| o,
                    else => continue,
                };
                try w.print("{s: <6} {s}  (volume {s})\n", .{ str(o.get("decision")), str(o.get("path")), str(o.get("volume")) });
            }
            return true;
        },
        .revoke, .forget => {
            const previous: ?[]const u8 = switch (obj.get("previous") orelse std.json.Value.null) {
                .string => |s| s,
                else => null,
            };
            const changed = switch (obj.get("changed") orelse std.json.Value.null) {
                .bool => |b| b,
                else => false,
            };
            const saved = switch (obj.get("saved") orelse std.json.Value.null) {
                .bool => |b| b,
                else => true,
            };
            // 맞은 저장소(심링크를 풀었으면 친 글자와 다르다)와, 결정이 없을 때 그 경로를 품은 저장소.
            const repo = entryOf(obj.get("repository"));
            const shown = if (repo) |r| r.path else path;
            if (!changed) {
                if (previous) |p| {
                    try w.print("unchanged: {s} is already {s}", .{ shown, if (std.mem.eql(u8, p, "deny")) "denied" else p });
                    if (!std.mem.eql(u8, shown, path)) try w.print(" (matched {s})", .{path});
                    try w.writeAll("\n");
                } else {
                    try w.print("unchanged: no decision for {s}\n", .{path});
                    if (entryOf(obj.get("containing"))) |c|
                        try w.print("hint: decisions are per repository — {s} ({s}) contains this path\n", .{ c.path, c.decision });
                }
                return true;
            }
            try w.print("{s}: {s} (was {s}", .{ if (kind == .revoke) "revoked" else "forgot", shown, previous orelse "?" });
            if (!std.mem.eql(u8, shown, path)) try w.print("; matched {s}", .{path});
            try w.writeAll(")\n");
            if (!saved) try w.writeAll("warning: not saved to the trust file — this applies to this run only; the previous decision returns on the next launch\n");
            return true;
        },
    }
}

const ShownEntry = struct { path: []const u8, decision: []const u8 };

fn entryOf(v: ?std.json.Value) ?ShownEntry {
    const o = switch (v orelse return null) {
        .object => |o| o,
        else => return null,
    };
    return .{ .path = str(o.get("path")), .decision = str(o.get("decision")) };
}

fn str(v: ?std.json.Value) []const u8 {
    return switch (v orelse return "?") {
        .string => |s| s,
        else => "?",
    };
}

/// `maru editor lsp --help`. 동작하는 명령만 싣는다(§11 CLI help gate — 부여 명령은 없다).
pub const help =
    \\usage:
    \\  maru editor lsp trust list
    \\  maru editor lsp trust revoke <path> [--volume <hex>]
    \\  maru editor lsp trust forget <path> [--volume <hex>]
    \\
    \\show or withdraw language server trust decisions of the running Maru.
    \\
    \\  list     every repository with a decision (allow or deny)
    \\  revoke   deny a repository that is allowed now (stops its servers)
    \\  forget   remove the decision (Maru asks again when you next open a file there)
    \\
    \\options:
    \\  --volume <hex>   pick the repository when the same path has decisions on more than one volume (specify once)
    \\
    \\exit status 0 also when nothing changed ("unchanged: ..."); 1 on an error.
    \\`..` is folded as text before the path is sent (it is not resolved through symlinks).
    \\there is no command that grants trust — answer the prompt in Maru instead.
    \\
;

// ══ 테스트 ══════════════════════════════════════════════════════════════════════════════════════════════════
const testing = std.testing;

test "lsp trust CLI: 파싱 — list·revoke·forget 셋, 부여 명령은 없다; 경로·--volume 검사" {
    try testing.expect((try parse(&.{ "trust", "list" })).request == .list);
    {
        const c = try parse(&.{ "trust", "revoke", "/r" });
        try testing.expectEqualStrings("/r", c.request.revoke.path);
        try testing.expect(c.request.revoke.volume == null);
    }
    {
        const c = try parse(&.{ "trust", "forget", "--volume", "ff", "rel/x" });
        try testing.expectEqualStrings("rel/x", c.request.forget.path);
        try testing.expectEqual(@as(?u64, 0xff), c.request.forget.volume);
    }
    try testing.expectEqual(@as(?u64, 0x10), (try parse(&.{ "trust", "revoke", "/r", "--volume=10" })).request.revoke.volume);
    try testing.expect(try parse(&.{ "trust", "revoke", "--help" }) == .help);
    try testing.expect(try parse(&.{"-h"}) == .help);
    try testing.expectError(error.MissingTopic, parse(&.{}));
    try testing.expectError(error.UnknownTopic, parse(&.{"servers"}));
    try testing.expectError(error.MissingSubcommand, parse(&.{"trust"}));
    for ([_][]const u8{ "grant", "allow", "set", "add" }) |g| try testing.expectError(error.UnknownSubcommand, parse(&.{ "trust", g, "/r" }));
    try testing.expectError(error.MissingPath, parse(&.{ "trust", "revoke" }));
    try testing.expectError(error.MissingPath, parse(&.{ "trust", "forget", "" }));
    try testing.expectError(error.MissingVolumeValue, parse(&.{ "trust", "revoke", "/r", "--volume" }));
    try testing.expectError(error.InvalidVolumeValue, parse(&.{ "trust", "revoke", "/r", "--volume", "zz" }));
    try testing.expectError(error.UnknownOption, parse(&.{ "trust", "revoke", "/r", "--force" }));
    try testing.expectError(error.UnexpectedArgument, parse(&.{ "trust", "revoke", "/r", "/s" }));
    try testing.expectError(error.UnexpectedArgument, parse(&.{ "trust", "list", "x" }));
    try testing.expectError(error.UnknownOption, parse(&.{ "trust", "list", "--json" }));
}

test "lsp trust CLI: 상대 경로는 현재 디렉터리 기준으로 펴고 . 와 .. 를 정리한다" {
    const a = try absolutize(testing.allocator, "/home/me/work", "proj/../repo/.");
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("/home/me/work/repo", a);
    const b = try absolutize(testing.allocator, "/home/me", "/abs/p/");
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("/abs/p", b); // 절대 경로도 끝 `/` 를 정리한다(목록의 글자와 맞게)
}

test "lsp trust CLI: 요청 바이트는 서버의 실제 해석기(control_lsp_trust.parseTarget)를 지난다 — 볼륨은 16진 문자열" {
    const clt = @import("../session/control_lsp_trust.zig");
    const bytes = try buildRequestBytes(testing.allocator, .{ .revoke = .{ .path = "/r x/한글", .volume = 0xdeadbeef } }, .{ .number = 1 });
    defer testing.allocator.free(bytes);
    var pm = try cp.parseMessage(testing.allocator, bytes);
    defer pm.deinit();
    const req = pm.message.request;
    try testing.expectEqual(clt.Op.revoke, clt.opFor(cp.parseMethod(req.method).rest).?);
    const t = try clt.parseTarget(req.params);
    try testing.expectEqualStrings("/r x/한글", t.path);
    try testing.expectEqual(@as(?u64, 0xdeadbeef), t.volume);
    const list = try buildRequestBytes(testing.allocator, .list, .{ .number = 2 });
    defer testing.allocator.free(list);
    var pl = try cp.parseMessage(testing.allocator, list);
    defer pl.deinit();
    try testing.expectEqual(clt.Op.list, clt.opFor(cp.parseMethod(pl.message.request.method).rest).?);
    const fz = try buildRequestBytes(testing.allocator, .{ .forget = .{ .path = "/f" } }, .{ .number = 3 });
    defer testing.allocator.free(fz);
    var pf = try cp.parseMessage(testing.allocator, fz);
    defer pf.deinit();
    try testing.expectEqual(clt.Op.forget, clt.opFor(cp.parseMethod(pf.message.request.method).rest).?);
    try testing.expect((try clt.parseTarget(pf.message.request.params)).volume == null);
}

test "lsp trust CLI: 서버 직렬화기의 응답을 그대로 렌더한다 — 목록·바뀜·그대로·저장 실패·옛 앱" {
    const clt = @import("../session/control_lsp_trust.zig");
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    {
        const resp = try clt.serializeList(testing.allocator, .{ .number = 1 }, &.{
            .{ .volume = 0xab, .path = "/Users/me/proj", .decision = .allow },
            .{ .volume = 1, .path = "/tmp/x", .decision = .deny },
        });
        defer testing.allocator.free(resp);
        try testing.expect(try renderResponse(testing.allocator, resp, .list, "", &out.writer));
    }
    {
        const resp = try clt.serializeList(testing.allocator, .{ .number = 1 }, &.{});
        defer testing.allocator.free(resp);
        try testing.expect(try renderResponse(testing.allocator, resp, .list, "", &out.writer));
    }
    {
        const resp = try clt.serializeOutcome(testing.allocator, .{ .number = 1 }, .allow, true, true, .{ .volume = 1, .path = "/real/p" }, null);
        defer testing.allocator.free(resp);
        try testing.expect(try renderResponse(testing.allocator, resp, .revoke, "/p", &out.writer));
    }
    {
        const resp = try clt.serializeOutcome(testing.allocator, .{ .number = 1 }, .deny, true, false, .{ .volume = 1, .path = "/p" }, null);
        defer testing.allocator.free(resp);
        try testing.expect(try renderResponse(testing.allocator, resp, .forget, "/p", &out.writer));
    }
    {
        const resp = try clt.serializeOutcome(testing.allocator, .{ .number = 1 }, .deny, false, true, .{ .volume = 1, .path = "/p" }, null);
        defer testing.allocator.free(resp);
        try testing.expect(try renderResponse(testing.allocator, resp, .revoke, "/p", &out.writer));
    }
    {
        const resp = try clt.serializeOutcome(testing.allocator, .{ .number = 1 }, null, false, true, null, .{ .volume = 1, .path = "/repo", .decision = .allow });
        defer testing.allocator.free(resp);
        try testing.expect(try renderResponse(testing.allocator, resp, .forget, "/q", &out.writer));
    }
    {
        const resp = try clt.serializeUnavailable(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"lsp.trust.list\"}");
        defer testing.allocator.free(resp);
        try testing.expect(!try renderResponse(testing.allocator, resp, .list, "", &out.writer));
    }
    try testing.expectEqualStrings(
        \\allow  /Users/me/proj  (volume ab)
        \\deny   /tmp/x  (volume 1)
        \\(no language server trust decisions)
        \\revoked: /real/p (was allow; matched /p)
        \\forgot: /p (was deny)
        \\warning: not saved to the trust file — this applies to this run only; the previous decision returns on the next launch
        \\unchanged: /p is already denied
        \\unchanged: no decision for /q
        \\hint: decisions are per repository — /repo (allow) contains this path
        \\error: this Maru does not support language server trust commands (-32601)
        \\
    , out.written());
}

test "lsp trust CLI: help 는 동작하는 명령만 — 세 줄, 부여 명령 없음" {
    try testing.expect(std.mem.indexOf(u8, help, "maru editor lsp trust list\n") != null);
    try testing.expect(std.mem.indexOf(u8, help, "maru editor lsp trust revoke <path> [--volume <hex>]\n") != null);
    try testing.expect(std.mem.indexOf(u8, help, "maru editor lsp trust forget <path> [--volume <hex>]\n") != null);
    for ([_][]const u8{ "trust grant", "trust allow", "trust add", "trust set" }) |w| try testing.expect(std.mem.indexOf(u8, help, w) == null);
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, help, "  maru editor lsp trust "));
}

test "lsp selector rejects repeated volume including zero and hexadecimal case" {
    const firsts = [_][]const []const u8{ &.{ "--volume", "a" }, &.{"--volume=A"}, &.{ "--volume", "0" }, &.{"--volume=0"} };
    const seconds = [_][]const []const u8{ &.{ "--volume", "a" }, &.{"--volume=A"}, &.{ "--volume", "b" }, &.{"--volume=b"}, &.{"--volume=0"}, &.{"--volume=0a"} };
    for ([_][]const u8{ "revoke", "forget" }) |verb| {
        for (firsts) |first| {
            var args: std.ArrayList([]const u8) = .empty;
            defer args.deinit(testing.allocator);
            try args.appendSlice(testing.allocator, &.{ "trust", verb, "/fixture/--volume=b" });
            try args.appendSlice(testing.allocator, first);
            const parsed = try parse(args.items);
            try testing.expectEqualStrings("/fixture/--volume=b", switch (parsed.request) {
                .revoke => |t| t.path,
                .forget => |t| t.path,
                .list => unreachable,
            });
            const length = args.items.len;
            for (seconds) |second| {
                args.items.len = length;
                try args.appendSlice(testing.allocator, second);
                try testing.expectError(error.DuplicateVolume, parse(args.items));
            }
        }
    }
}
