//! control_lsp_trust — 컨트롤 플레인의 **언어 서버 신뢰 조회·철회·잊기**(`lsp.trust.list`·`lsp.trust.revoke`·`lsp.trust.forget`)의
//! wire 절반(L2 순수, OS-중립). 계획 docs/plans/workspace-trust.md WT4b, 메서드 표 docs/control-plane.md §6, 인가 §8.3.
//!
//! **부여는 없다** — 에이전트가 신뢰를 주지 못하게(계획 WT2 「신뢰 부여는 사용자 클릭으로만」). 철회는 지금 허용인 저장소를 거부로,
//! 잊기는 결정을 지울 뿐이다(다시 열면 묻는다 — 곧바로 묻지는 않는다). 표(앱 전역 `trust_store`)를 읽고 쓰는 일은 L4(`editor/lsp.zig`)가
//! 하고, 이 모듈은 요청 해석과 응답 직렬화만 한다 — 도메인 동작은 호출자가 넘긴 `impl` 이 한다(`respond`).
//!
//! **누가 부르나**(2026-10-09 사용자 결정): 셀렉터 없이 붙은 연결 — 같은 uid 의 그 사용자 자신(SSH 로 붙은 폰 포함, §8.4 「셀렉터 없음 →
//! 전체」와 같은 근거). 같은 uid 는 신뢰 파일을 직접 고칠 수도 있다. 철회는 권한을 낮추기만 하지만, **잊기는 거부를 「결정 없음」으로
//! 되돌릴 수 있다**(다시 열면 묻는다 — 그 위험을 알고 택한 결정, 보안 §8.3). 셀렉터를 댄 연결(자기 패인 하나라고 주장한 것)은 균일
//! `unauthorized` 다(`control_dispatch` 가 판정한다 — 방어 경계가 아니라 정리다; 이 모듈은 메서드·params 만).
//!
//! **키**: 저장소는 (볼륨, 실제 경로)다. 볼륨은 u64(볼륨 UUID 를 접은 값)라 JSON 정수(i64)에 못 실어 16진 문자열로 싣는다(신뢰 파일과
//! 같은 표기). 요청은 경로만 줘도 된다 — 같은 경로가 여러 볼륨에 있으면 `volume` 으로 고르라고 `invalid_params` 로 돌려준다.
//! 원격(SSH) 저장소는 (목적지, 원격 실제 경로)다(계획 WT7a) — 목록·결과에서 `volume` 자리에 `host`(목적지)가 서고, 요청은 `host` 로 원격
//! 키를 고른다(`volume` 과 함께 주면 `invalid_params` — 둘은 다른 종류의 키다). `host` 가 없는 요청은 로컬 키만 본다.
//!
//! **감사 기록 조회**(`lsp.trust.log` — 계획 docs/plans/workspace-trust-audit.md TA2): 결정이 바뀐 기록(`lsp-trust-log`)의 최근 `limit`
//! 건을 시간 순서로 낸다. 읽기만 한다 — 기록을 지우거나 고치는 메서드는 없다.

const std = @import("std");
const cp = @import("control_plane.zig");
const trust_log = @import("lsp/trust_log.zig");

/// 네임스페이스(`lsp.*`)와 그 아래 메서드.
pub const namespace = "lsp";

pub const Op = enum {
    list,
    revoke,
    forget,
    /// 감사 기록 조회(계획 workspace-trust-audit TA2) — 읽기만 한다.
    log,

    pub fn method(self: Op) []const u8 {
        return switch (self) {
            .list => "lsp.trust.list",
            .revoke => "lsp.trust.revoke",
            .forget => "lsp.trust.forget",
            .log => "lsp.trust.log",
        };
    }
};

/// `lsp.` 뒤 나머지(`parseMethod(...).rest`)가 신뢰 메서드인가.
pub fn opFor(rest: []const u8) ?Op {
    if (std.mem.eql(u8, rest, "trust.list")) return .list;
    if (std.mem.eql(u8, rest, "trust.revoke")) return .revoke;
    if (std.mem.eql(u8, rest, "trust.forget")) return .forget;
    if (std.mem.eql(u8, rest, "trust.log")) return .log;
    return null;
}

pub const Decision = enum { allow, deny };

/// 철회·잊기의 대상. `path`·`host` 는 요청 arena 를 빌린다. `host` 가 있으면 원격 키(그 목적지의 원격 경로)다.
pub const Target = struct {
    path: []const u8,
    volume: ?u64 = null,
    host: ?[]const u8 = null,
};

/// 목적지 문자열의 상한(신뢰 키와 같다 — `trust.max_dest_bytes`).
pub const max_host_bytes: usize = 256;

pub const ParamError = error{InvalidParams};

/// `{path, volume?, host?}` — `path` 는 비어 있지 않은 절대 경로, `volume` 은 16진 문자열(신뢰 파일·목록과 같은 표기), `host` 는 원격 목적지
/// (빈 값·제어 문자·상한 초과는 거절; `volume` 과 함께 오면 거절).
pub fn parseTarget(params: ?std.json.Value) ParamError!Target {
    const obj = switch (params orelse return error.InvalidParams) {
        .object => |o| o,
        else => return error.InvalidParams,
    };
    const path = switch (obj.get("path") orelse return error.InvalidParams) {
        .string => |s| s,
        else => return error.InvalidParams,
    };
    if (path.len == 0 or path[0] != '/') return error.InvalidParams;
    // 경로 안의 NUL 은 거절한다 — 실제 경로로 풀 때 NUL 앞까지로 열려 다른 저장소(`/repo\u0000x` → `/repo`)에 닿는다.
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidParams;
    const volume: ?u64 = if (obj.get("volume")) |v| switch (v) {
        .string => |s| std.fmt.parseInt(u64, s, 16) catch return error.InvalidParams,
        .null => null,
        else => return error.InvalidParams,
    } else null;
    const host: ?[]const u8 = if (obj.get("host")) |v| switch (v) {
        .string => |h| blk: {
            if (h.len == 0 or h.len > max_host_bytes) return error.InvalidParams;
            for (h) |c| if (c < 0x20 or c == 0x7f) return error.InvalidParams;
            break :blk h;
        },
        .null => null,
        else => return error.InvalidParams,
    } else null;
    if (host != null and volume != null) return error.InvalidParams;
    var it = obj.iterator();
    while (it.next()) |e| {
        const k = e.key_ptr.*;
        if (!std.mem.eql(u8, k, "path") and !std.mem.eql(u8, k, "volume") and !std.mem.eql(u8, k, "host")) return error.InvalidParams;
    }
    return .{ .path = path, .volume = volume, .host = host };
}

/// `lsp.trust.list` 의 params — 없거나 빈 객체만(철회·잊기처럼 모르는 키는 거절한다).
pub fn checkListParams(params: ?std.json.Value) ParamError!void {
    const p = params orelse return;
    switch (p) {
        .object => |o| if (o.count() != 0) return error.InvalidParams,
        .null => {},
        else => return error.InvalidParams,
    }
}

/// `lsp.trust.log` 의 기본·최대 건수. 최대는 응답이 프레임 상한(1 MiB)에 들게 둔다 — 한 건은 경로 상한(1 KiB)을 넣어도 2 KiB 아래다.
pub const default_log_limit: u32 = 50;
pub const max_log_limit: u32 = 200;

/// `lsp.trust.log` 의 params — 없거나 빈 객체, 또는 `{limit: 1..200}`(정수). 모르는 키는 거절한다.
pub fn parseLogParams(params: ?std.json.Value) ParamError!u32 {
    const p = params orelse return default_log_limit;
    const obj = switch (p) {
        .object => |o| o,
        .null => return default_log_limit,
        else => return error.InvalidParams,
    };
    var limit = default_log_limit;
    var it = obj.iterator();
    while (it.next()) |e| {
        if (!std.mem.eql(u8, e.key_ptr.*, "limit")) return error.InvalidParams;
        const n = switch (e.value_ptr.*) {
            .integer => |i| i,
            else => return error.InvalidParams,
        };
        if (n < 1 or n > max_log_limit) return error.InvalidParams;
        limit = @intCast(n);
    }
    return limit;
}

/// 표의 키(볼륨·실제 경로, 원격이면 목적지·원격 경로 — `host` 가 비면 로컬).
pub const Key = struct { volume: u64, path: []const u8, host: []const u8 = "" };

/// 목록 한 줄.
pub const Entry = struct {
    volume: u64,
    path: []const u8,
    decision: Decision,
    host: []const u8 = "",
};

/// 철회·잊기의 결과.
pub const Outcome = union(enum) {
    /// 표에서 그 저장소를 찾았다. `previous` 는 바꾸기 전 결정, `changed` 는 실제로 바뀌었나(철회는 허용일 때만 — 이미 거부면 그대로),
    /// `saved` 는 파일에 남았나(못 남았으면 이번 실행에만 먹는다 — 다음 실행은 파일의 옛 결정을 읽는다), `key` 는 맞은 표의 키(요청의
    /// 글자와 다를 수 있다 — 심링크를 실제 경로로 풀었다; 경로는 응답을 쓰는 동안만 빌린다).
    done: struct { previous: Decision, changed: bool, saved: bool, key: Key },
    /// 그 경로의 결정이 없다. `containing` 은 그 경로를 품은 저장소의 결정(있으면) — 결정은 저장소 root 단위라 하위 폴더를 주면 여기로
    /// 온다(「결정 없음」으로만 답하면 신뢰된 적 없는 것으로 읽힌다). 바꾸지는 않는다.
    none: struct { containing: ?Entry = null },
    /// 그 경로의 결정이 여러 볼륨에 있다 — `volume` 으로 골라야 한다.
    ambiguous,
};

/// 요청 한 줄에 답한다. `impl` 은 `entries(gpa) ![]Entry`(목록 — 호출자가 빌려 준 경로, 응답을 쓰는 동안만 살면 된다),
/// `apply(op, target) Outcome`, `logText(gpa) ?[]u8`(감사 기록 파일의 내용 — 없으면 `null`; 여기서 푼다)을 가진다. 요청은 `control_dispatch` 가 이미 메서드·params 를 검사한 것이다 — 그래도 여기서 다시 읽어
/// 어긋나면 `invalid_params` 다(앞 판정에 기대지 않는다).
pub fn respond(gpa: std.mem.Allocator, request_bytes: []const u8, impl: anytype) std.mem.Allocator.Error![]u8 {
    var pm = cp.parseMessage(gpa, request_bytes) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return cp.serializeError(gpa, .null, .internal_error, cp.ErrorCode.internal_error.defaultMessage(), null),
    };
    defer pm.deinit();
    const req = switch (pm.message) {
        .request => |r| r,
        else => return cp.serializeError(gpa, .null, .internal_error, cp.ErrorCode.internal_error.defaultMessage(), null),
    };
    const parsed = cp.parseMethod(req.method);
    const op = (if (std.mem.eql(u8, parsed.namespace, namespace)) opFor(parsed.rest) else null) orelse
        return errorResponse(gpa, req.id, .method_not_found);
    switch (op) {
        .list => {
            checkListParams(req.params) catch return errorResponse(gpa, req.id, .invalid_params);
            const entries = try impl.entries(gpa);
            defer gpa.free(entries);
            return serializeList(gpa, req.id, entries);
        },
        .log => {
            const limit = parseLogParams(req.params) catch return errorResponse(gpa, req.id, .invalid_params);
            const text = impl.logText(gpa);
            defer if (text) |t| gpa.free(t);
            return serializeLog(gpa, req.id, text orelse "", limit);
        },
        .revoke, .forget => {
            const target = parseTarget(req.params) catch return errorResponse(gpa, req.id, .invalid_params);
            return switch (impl.apply(op, target)) {
                .done => |d| serializeOutcome(gpa, req.id, d.previous, d.changed, d.saved, d.key, null),
                .none => |n| serializeOutcome(gpa, req.id, null, false, true, null, n.containing),
                .ambiguous => cp.serializeError(gpa, req.id, .invalid_params, "ambiguous path: decisions exist on more than one volume; pass volume", null),
            };
        },
    }
}

/// 신뢰 표가 없는 자리(전송 계층 판정자의 drain)의 답 — 그 요청 id 로 `method_not_found`.
pub fn serializeUnavailable(gpa: std.mem.Allocator, request_bytes: []const u8) std.mem.Allocator.Error![]u8 {
    var pm = cp.parseMessage(gpa, request_bytes) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return errorResponse(gpa, .null, .method_not_found),
    };
    defer pm.deinit();
    const id: cp.Id = switch (pm.message) {
        .request => |r| r.id,
        else => .null,
    };
    return errorResponse(gpa, id, .method_not_found);
}

fn errorResponse(gpa: std.mem.Allocator, id: cp.Id, code: cp.ErrorCode) std.mem.Allocator.Error![]u8 {
    return cp.serializeError(gpa, id, code, code.defaultMessage(), null);
}

/// `{"decisions":[{"volume":"<16진>","path":"…","decision":"allow"|"deny"}]}`. 볼륨은 신뢰 파일과 같은 표기(패딩 없는 소문자 16진 — `trust.line`).
/// 원격 항목은 `volume` 자리에 `"host":"<목적지>"`(칸 수는 같다).
pub fn serializeList(gpa: std.mem.Allocator, id: cp.Id, entries: []const Entry) std.mem.Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    writeList(&s, id, entries) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn writeList(s: *std.json.Stringify, id: cp.Id, entries: []const Entry) !void {
    try cp.beginResult(s, id);
    try s.objectField("decisions");
    try s.beginArray();
    for (entries) |e| try writeEntry(s, e);
    try s.endArray();
    try cp.endResult(s);
}

/// `{"previous":"allow"|"deny"|null,"changed":bool,"saved":bool,"repository"?:{volume,path},"containing"?:{volume,path,decision}}`.
/// `repository` 는 맞은 표의 키(결정은 `previous` — 바꾸기 전), `containing` 은 결정이 없을 때 그 경로를 품은 저장소와 그 결정.
pub fn serializeOutcome(gpa: std.mem.Allocator, id: cp.Id, previous: ?Decision, changed: bool, saved: bool, repository: ?Key, containing: ?Entry) std.mem.Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    writeOutcome(&s, id, previous, changed, saved, repository, containing) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn writeOutcome(s: *std.json.Stringify, id: cp.Id, previous: ?Decision, changed: bool, saved: bool, repository: ?Key, containing: ?Entry) !void {
    try cp.beginResult(s, id);
    try s.objectField("previous");
    if (previous) |p| try s.write(@tagName(p)) else try s.write(null);
    try s.objectField("changed");
    try s.write(changed);
    try s.objectField("saved");
    try s.write(saved);
    if (repository) |k| {
        try s.objectField("repository");
        try s.beginObject();
        try writeWhere(s, k.volume, k.host);
        try s.objectField("path");
        try s.write(k.path);
        try s.endObject();
    }
    if (containing) |e| {
        try s.objectField("containing");
        try writeEntry(s, e);
    }
    try cp.endResult(s);
}

/// 키의 「어디」 칸 — 로컬은 `volume`(16진), 원격은 `host`(목적지).
fn writeWhere(s: *std.json.Stringify, volume: u64, host: []const u8) !void {
    if (host.len > 0) {
        try s.objectField("host");
        try s.write(host);
        return;
    }
    var vbuf: [16]u8 = undefined;
    try s.objectField("volume");
    try s.write(std.fmt.bufPrint(&vbuf, "{x}", .{volume}) catch unreachable);
}

/// `{"records":[{"at":<unix ms>,"action":"allow"|"deny"|"forget","source":"sheet"|"manage"|"control"|"migrate","peer"?:{"pid","name"},
/// "volume"|"host":…,"path":…}],"more":bool}` — 기록 `text` 의 읽히는 줄 중 **마지막 `limit` 건**을 줄 순서대로(시간 순서 — 시계가 아니라
/// 줄 순서다). `more` 는 그보다 앞선 기록이 더 있나. 못 읽는 줄·끊긴 마지막 줄은 세지 않는다(`trust_log.Records`).
///
/// 응답이 `budget` 바이트를 넘으면 건수를 반씩 줄여 다시 쓴다(오래된 것부터 빠지고 `more` 가 선다) — 경로의 제어 문자는 JSON 에서
/// `\u00XX` 로 여섯 배가 되어, 상한 건수로도 프레임 상한(`cp.default_max_frame`)을 넘으면 CLI 가 응답을 통째로 거절한다(적대적 검증
/// TA2 1회차). 한 건이어도 넘으면 그대로 낸다(그 한 건은 경로 상한으로 6 KiB 아래다).
pub fn serializeLog(gpa: std.mem.Allocator, id: cp.Id, text: []const u8, limit: u32) std.mem.Allocator.Error![]u8 {
    return serializeLogWithin(gpa, id, text, limit, log_response_budget);
}

/// `lsp.trust.log` 응답의 바이트 예산 — 프레임 상한에서 여유를 둔다.
pub const log_response_budget: usize = cp.default_max_frame - 16 * 1024;

pub fn serializeLogWithin(gpa: std.mem.Allocator, id: cp.Id, text: []const u8, limit: u32, budget: usize) std.mem.Allocator.Error![]u8 {
    var total: usize = 0;
    var count_it = trust_log.Records.init(text);
    while (count_it.next()) |_| total += 1;
    var n: usize = limit;
    while (true) {
        const skip = total -| n;
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
        writeLog(&s, id, text, skip) catch return error.OutOfMemory;
        if (aw.written().len <= budget or n <= 1) return aw.toOwnedSlice();
        n /= 2;
    }
}

fn writeLog(s: *std.json.Stringify, id: cp.Id, text: []const u8, skip: usize) !void {
    try cp.beginResult(s, id);
    try s.objectField("records");
    try s.beginArray();
    var it = trust_log.Records.init(text);
    var i: usize = 0;
    while (it.next()) |r| : (i += 1) {
        if (i < skip) continue;
        try s.beginObject();
        try s.objectField("at");
        try s.write(r.at_ms);
        try s.objectField("action");
        try s.write(if (r.decision) |d| @tagName(d) else "forget");
        try s.objectField("source");
        try s.write(@tagName(r.source));
        if (r.peer) |p| {
            try s.objectField("peer");
            try s.beginObject();
            try s.objectField("pid");
            try s.write(p.pid);
            try s.objectField("name");
            try s.write(p.name);
            try s.endObject();
        }
        try writeWhere(s, r.key.volume, r.key.dest);
        try s.objectField("path");
        try s.write(r.key.path);
        try s.endObject();
    }
    try s.endArray();
    try s.objectField("more");
    try s.write(skip > 0);
    try cp.endResult(s);
}

fn writeEntry(s: *std.json.Stringify, e: Entry) !void {
    try s.beginObject();
    try writeWhere(s, e.volume, e.host);
    try s.objectField("path");
    try s.write(e.path);
    try s.objectField("decision");
    try s.write(@tagName(e.decision));
    try s.endObject();
}

// ══ 테스트 ══════════════════════════════════════════════════════════════════════════════════════════════════
const testing = std.testing;

test "control_lsp_trust: 메서드 이름 — trust.list·revoke·forget·log 넷뿐(부여 메서드는 없다)" {
    try testing.expectEqual(Op.list, opFor("trust.list").?);
    try testing.expectEqual(Op.revoke, opFor("trust.revoke").?);
    try testing.expectEqual(Op.forget, opFor("trust.forget").?);
    try testing.expectEqual(Op.log, opFor("trust.log").?);
    for ([_][]const u8{ "trust.allow", "trust.grant", "trust.decide", "trust.set", "trust.clear", "trust.log.clear", "trust", "list", "" }) |m| try testing.expect(opFor(m) == null);
    try testing.expectEqual(@as(usize, 4), @typeInfo(Op).@"enum".fields.len);
    inline for (@typeInfo(Op).@"enum".fields) |f| {
        const op: Op = @field(Op, f.name);
        const p = cp.parseMethod(op.method());
        try testing.expectEqualStrings(namespace, p.namespace);
        try testing.expectEqual(op, opFor(p.rest).?);
    }
}

test "control_lsp_trust: params — 절대 경로 필수, volume 은 16진 문자열, 모르는 키는 거절" {
    const Case = struct { json: []const u8, ok: bool };
    const cases = [_]Case{
        .{ .json = "{\"path\":\"/a/b\"}", .ok = true },
        .{ .json = "{\"path\":\"/a/b\",\"volume\":\"00000000000000ff\"}", .ok = true },
        .{ .json = "{\"path\":\"/a/b\",\"volume\":null}", .ok = true },
        .{ .json = "{\"path\":\"a/b\"}", .ok = false },
        .{ .json = "{\"path\":\"\"}", .ok = false },
        .{ .json = "{\"path\":7}", .ok = false },
        .{ .json = "{}", .ok = false },
        .{ .json = "[]", .ok = false },
        .{ .json = "{\"path\":\"/a\",\"volume\":255}", .ok = false },
        .{ .json = "{\"path\":\"/a\",\"volume\":\"zz\"}", .ok = false },
        .{ .json = "{\"path\":\"/a\",\"decision\":\"allow\"}", .ok = false },
        .{ .json = "{\"path\":\"/a/b\\u0000x\"}", .ok = false },
    };
    for (cases) |c| {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, c.json, .{});
        defer parsed.deinit();
        const r = parseTarget(parsed.value);
        if (c.ok) {
            const t = try r;
            try testing.expectEqualStrings("/a/b", t.path);
        } else try testing.expectError(error.InvalidParams, r);
    }
    try testing.expectError(error.InvalidParams, parseTarget(null));
    // 목록은 params 가 없거나 빈 객체만.
    try checkListParams(null);
    {
        const e = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{}", .{});
        defer e.deinit();
        try checkListParams(e.value);
        const x = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"x\":1}", .{});
        defer x.deinit();
        try testing.expectError(error.InvalidParams, checkListParams(x.value));
        const a = try std.json.parseFromSlice(std.json.Value, testing.allocator, "[]", .{});
        defer a.deinit();
        try testing.expectError(error.InvalidParams, checkListParams(a.value));
    }
    const p = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"path\":\"/a/b\",\"volume\":\"00000000000000ff\"}", .{});
    defer p.deinit();
    try testing.expectEqual(@as(?u64, 0xff), (try parseTarget(p.value)).volume);
}

const FakeImpl = struct {
    list: []const Entry,
    outcome: Outcome = .{ .done = .{ .previous = .allow, .changed = true, .saved = true, .key = .{ .volume = 0x0a, .path = "/real/r" } } },
    seen_op: ?Op = null,
    seen_path: [64]u8 = undefined,
    seen_path_len: usize = 0,
    seen_volume: ?u64 = null,

    fn entries(self: *FakeImpl, gpa: std.mem.Allocator) ![]Entry {
        return gpa.dupe(Entry, self.list);
    }
    fn logText(_: *FakeImpl, _: std.mem.Allocator) ?[]u8 {
        return null;
    }
    fn apply(self: *FakeImpl, op: Op, t: Target) Outcome {
        self.seen_op = op;
        @memcpy(self.seen_path[0..t.path.len], t.path);
        self.seen_path_len = t.path.len;
        self.seen_volume = t.volume;
        return self.outcome;
    }
};

test "control_lsp_trust: 목록 응답은 실제 디코더(parseMessage)를 지나 볼륨 16진·경로·결정을 그대로 낸다 — 결과 키는 decisions 하나" {
    var impl: FakeImpl = .{ .list = &.{
        .{ .volume = 0xdeadbeef00000001, .path = "/Users/me/proj", .decision = .allow },
        .{ .volume = 1, .path = "/tmp/한글 \"quote\"", .decision = .deny },
    } };
    const resp = try respond(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"lsp.trust.list\"}", &impl);
    defer testing.allocator.free(resp);
    var pm = try cp.parseMessage(testing.allocator, resp);
    defer pm.deinit();
    const r = pm.message.response;
    try testing.expect(cp.idEql(r.id, .{ .number = 3 }));
    const obj = r.result.?.object;
    try testing.expectEqual(@as(usize, 1), obj.count());
    const arr = obj.get("decisions").?.array.items;
    try testing.expectEqual(@as(usize, 2), arr.len);
    try testing.expectEqual(@as(usize, 3), arr[0].object.count());
    try testing.expectEqualStrings("deadbeef00000001", arr[0].object.get("volume").?.string);
    try testing.expectEqualStrings("/Users/me/proj", arr[0].object.get("path").?.string);
    try testing.expectEqualStrings("allow", arr[0].object.get("decision").?.string);
    try testing.expectEqualStrings("1", arr[1].object.get("volume").?.string); // 신뢰 파일과 같은 표기(패딩 없음)
    try testing.expectEqualStrings("/tmp/한글 \"quote\"", arr[1].object.get("path").?.string);
    try testing.expectEqualStrings("deny", arr[1].object.get("decision").?.string);
    // 볼륨 문자열은 요청 params 로 그대로 돌려줄 수 있다(왕복).
    try testing.expectEqual(@as(u64, 0xdeadbeef00000001), try std.fmt.parseInt(u64, arr[0].object.get("volume").?.string, 16));
}

test "control_lsp_trust: 철회·잊기 응답은 previous·changed·saved 셋 — 대상은 params 그대로 impl 에 간다; 모호하면 invalid_params" {
    var impl: FakeImpl = .{ .list = &.{} };
    {
        const resp = try respond(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":\"x\",\"method\":\"lsp.trust.revoke\",\"params\":{\"path\":\"/r\",\"volume\":\"0a\"}}", &impl);
        defer testing.allocator.free(resp);
        var pm = try cp.parseMessage(testing.allocator, resp);
        defer pm.deinit();
        const obj = pm.message.response.result.?.object;
        try testing.expectEqual(@as(usize, 4), obj.count());
        try testing.expectEqualStrings("allow", obj.get("previous").?.string);
        const rep = obj.get("repository").?.object;
        try testing.expectEqual(@as(usize, 2), rep.count()); // 볼륨·경로 — 결정은 previous 하나(바꾸기 전)
        try testing.expectEqualStrings("/real/r", rep.get("path").?.string);
        try testing.expectEqualStrings("a", rep.get("volume").?.string);
        try testing.expect(obj.get("changed").?.bool);
        try testing.expect(obj.get("saved").?.bool);
        try testing.expectEqual(Op.revoke, impl.seen_op.?);
        try testing.expectEqualStrings("/r", impl.seen_path[0..impl.seen_path_len]);
        try testing.expectEqual(@as(?u64, 0x0a), impl.seen_volume);
    }
    impl.outcome = .{ .none = .{ .containing = .{ .volume = 1, .path = "/repo", .decision = .allow } } };
    {
        const resp = try respond(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"lsp.trust.forget\",\"params\":{\"path\":\"/r\"}}", &impl);
        defer testing.allocator.free(resp);
        var pm = try cp.parseMessage(testing.allocator, resp);
        defer pm.deinit();
        const obj = pm.message.response.result.?.object;
        try testing.expect(obj.get("previous").? == .null);
        try testing.expect(!obj.get("changed").?.bool);
        try testing.expect(obj.get("repository") == null);
        try testing.expectEqual(@as(usize, 4), obj.count());
        try testing.expectEqualStrings("/repo", obj.get("containing").?.object.get("path").?.string);
        try testing.expectEqualStrings("allow", obj.get("containing").?.object.get("decision").?.string);
    }
    impl.outcome = .{ .none = .{} };
    {
        const resp = try respond(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"lsp.trust.forget\",\"params\":{\"path\":\"/r\"}}", &impl);
        defer testing.allocator.free(resp);
        var pm = try cp.parseMessage(testing.allocator, resp);
        defer pm.deinit();
        try testing.expectEqual(@as(usize, 3), pm.message.response.result.?.object.count()); // 품은 저장소가 없으면 그 필드도 없다
        try testing.expectEqual(Op.forget, impl.seen_op.?);
        try testing.expectEqual(@as(?u64, null), impl.seen_volume);
    }
    impl.outcome = .ambiguous;
    {
        const resp = try respond(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"lsp.trust.forget\",\"params\":{\"path\":\"/r\"}}", &impl);
        defer testing.allocator.free(resp);
        var pm = try cp.parseMessage(testing.allocator, resp);
        defer pm.deinit();
        try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.invalid_params)), pm.message.response.err.?.code);
    }
    // params 가 틀리면 impl 에 닿지 않는다.
    impl.seen_op = null;
    {
        const resp = try respond(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"lsp.trust.revoke\",\"params\":{\"path\":\"rel\"}}", &impl);
        defer testing.allocator.free(resp);
        var pm = try cp.parseMessage(testing.allocator, resp);
        defer pm.deinit();
        try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.invalid_params)), pm.message.response.err.?.code);
        try testing.expect(impl.seen_op == null);
    }
}

test "control_lsp_trust: 원격 키 (계획 workspace-trust WT7a) — `host` 로 원격 키를 고르고(`volume` 과 함께면 거절), 목록·결과에서 원격 항목은 `volume` 자리에 `host` 가 선다(칸 수는 같다)" {
    const Case = struct { json: []const u8, host: ?[]const u8 };
    const ok = [_]Case{
        .{ .json = "{\"path\":\"/srv/app\",\"host\":\"me@openclaw\"}", .host = "me@openclaw" },
        .{ .json = "{\"path\":\"/srv/app\",\"host\":null}", .host = null },
    };
    for (ok) |c| {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, c.json, .{});
        defer parsed.deinit();
        const t = try parseTarget(parsed.value);
        if (c.host) |h| try testing.expectEqualStrings(h, t.host.?) else try testing.expect(t.host == null);
    }
    for ([_][]const u8{
        "{\"path\":\"/a\",\"host\":\"h\",\"volume\":\"ff\"}", // 둘은 다른 종류의 키다
        "{\"path\":\"/a\",\"host\":\"\"}",
        "{\"path\":\"/a\",\"host\":\"h\\u001b\"}",
        "{\"path\":\"/a\",\"host\":7}",
    }) |j| {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, j, .{});
        defer parsed.deinit();
        try testing.expectError(error.InvalidParams, parseTarget(parsed.value));
    }
    // 목록 — 원격 항목은 `host`·`path`·`decision`.
    const list = try serializeList(testing.allocator, .{ .number = 1 }, &.{
        .{ .volume = 0x1f, .path = "/l", .decision = .allow },
        .{ .volume = 0, .path = "/srv/app", .decision = .deny, .host = "openclaw" },
    });
    defer testing.allocator.free(list);
    var parsed_list = try std.json.parseFromSlice(std.json.Value, testing.allocator, list, .{});
    defer parsed_list.deinit();
    const items = parsed_list.value.object.get("result").?.object.get("decisions").?.array.items;
    try testing.expectEqual(@as(usize, 3), items[1].object.count());
    try testing.expectEqualStrings("openclaw", items[1].object.get("host").?.string);
    try testing.expect(items[1].object.get("volume") == null);
    try testing.expectEqualStrings("1f", items[0].object.get("volume").?.string);
    // 결과의 `repository` 도 같다.
    const out = try serializeOutcome(testing.allocator, .{ .number = 2 }, .allow, true, true, .{ .volume = 0, .path = "/srv/app", .host = "openclaw" }, null);
    defer testing.allocator.free(out);
    var parsed_out = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer parsed_out.deinit();
    const repo = parsed_out.value.object.get("result").?.object.get("repository").?.object;
    try testing.expectEqual(@as(usize, 2), repo.count());
    try testing.expectEqualStrings("openclaw", repo.get("host").?.string);
}

test "control_lsp_trust: 감사 기록 조회 (계획 workspace-trust-audit TA2) — 마지막 limit 건을 줄 순서대로, 상대·원격 키·잊기, 못 읽는 줄은 세지 않고 앞선 기록이 더 있으면 more; params 는 limit 1..200 뿐" {
    const Impl = struct {
        text: []const u8,
        fn entries(_: *@This(), gpa: std.mem.Allocator) ![]Entry {
            return gpa.alloc(Entry, 0);
        }
        fn apply(_: *@This(), _: Op, _: Target) Outcome {
            return .ambiguous;
        }
        fn logText(self: *@This(), gpa: std.mem.Allocator) ?[]u8 {
            if (self.text.len == 0) return null;
            return gpa.dupe(u8, self.text) catch null;
        }
    };
    var impl: Impl = .{ .text = "1\tallow\tsheet\t-\t1f\t/r\n" ++
        "garbage\n" ++
        "2\tdeny\tmanage\t-\t1f\t/r\n" ++
        "3\tforget\tcontrol\t4321:maru\tssh\topenclaw\t/srv/app\n" ++
        "4\tallow\tsheet\t-\t1f\t/cut" }; // 끊긴 마지막 줄 — 세지 않는다
    {
        const resp = try respond(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"lsp.trust.log\",\"params\":{\"limit\":2}}", &impl);
        defer testing.allocator.free(resp);
        var pm = try cp.parseMessage(testing.allocator, resp);
        defer pm.deinit();
        const obj = pm.message.response.result.?.object;
        try testing.expectEqual(@as(usize, 2), obj.count());
        try testing.expect(obj.get("more").?.bool);
        const recs = obj.get("records").?.array.items;
        try testing.expectEqual(@as(usize, 2), recs.len);
        const a = recs[0].object;
        try testing.expectEqual(@as(usize, 5), a.count()); // at·action·source·volume·path — 상대가 없으면 그 칸도 없다
        try testing.expectEqual(@as(i64, 2), a.get("at").?.integer);
        try testing.expectEqualStrings("deny", a.get("action").?.string);
        try testing.expectEqualStrings("manage", a.get("source").?.string);
        try testing.expectEqualStrings("1f", a.get("volume").?.string);
        try testing.expectEqualStrings("/r", a.get("path").?.string);
        const b = recs[1].object;
        try testing.expectEqualStrings("forget", b.get("action").?.string);
        try testing.expectEqualStrings("control", b.get("source").?.string);
        try testing.expectEqual(@as(i64, 4321), b.get("peer").?.object.get("pid").?.integer);
        try testing.expectEqualStrings("maru", b.get("peer").?.object.get("name").?.string);
        try testing.expectEqualStrings("openclaw", b.get("host").?.string);
        try testing.expect(b.get("volume") == null);
    }
    {
        // 기본 limit(50) — 셋 다, 더 없다.
        const resp = try respond(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"lsp.trust.log\"}", &impl);
        defer testing.allocator.free(resp);
        var pm = try cp.parseMessage(testing.allocator, resp);
        defer pm.deinit();
        const obj = pm.message.response.result.?.object;
        try testing.expectEqual(@as(usize, 3), obj.get("records").?.array.items.len);
        try testing.expect(!obj.get("more").?.bool);
        try testing.expectEqual(@as(i64, 1), obj.get("records").?.array.items[0].object.get("at").?.integer);
    }
    impl.text = "";
    {
        const resp = try respond(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"lsp.trust.log\",\"params\":{}}", &impl);
        defer testing.allocator.free(resp);
        var pm = try cp.parseMessage(testing.allocator, resp);
        defer pm.deinit();
        const obj = pm.message.response.result.?.object;
        try testing.expectEqual(@as(usize, 0), obj.get("records").?.array.items.len);
        try testing.expect(!obj.get("more").?.bool);
    }
    // params.
    for ([_][]const u8{ "{\"limit\":0}", "{\"limit\":201}", "{\"limit\":\"5\"}", "{\"limit\":1.5}", "{\"x\":1}", "[]", "7" }) |j| {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, j, .{});
        defer parsed.deinit();
        try testing.expectError(error.InvalidParams, parseLogParams(parsed.value));
    }
    try testing.expectEqual(default_log_limit, try parseLogParams(null));
    {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"limit\":200}", .{});
        defer parsed.deinit();
        try testing.expectEqual(@as(u32, 200), try parseLogParams(parsed.value));
    }
}

test "control_lsp_trust: 감사 기록 응답이 예산을 넘으면 건수를 반씩 줄여 최근 것을 남기고 more 를 세운다 — 제어 문자 경로는 JSON 에서 여섯 배다 (적대적 검증 TA2 1회차)" {
    // 제어 문자(0x01) 200 개짜리 경로 — 줄은 230 바이트 남짓인데 JSON 에서는 1.2 KiB 다.
    const weird = "/" ++ "\x01" ** 200;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    for (0..8) |i| {
        var buf: [512]u8 = undefined;
        try text.appendSlice(testing.allocator, try std.fmt.bufPrint(&buf, "{d}\tallow\tsheet\t-\t1\t{s}\n", .{ i + 1, weird }));
    }
    // 예산 3 KiB — 여덟 건(10 KiB 남짓)은 넘고, 둘은 든다.
    const resp = try serializeLogWithin(testing.allocator, .{ .number = 1 }, text.items, 8, 3 * 1024);
    defer testing.allocator.free(resp);
    try testing.expect(resp.len <= 3 * 1024);
    var pm = try cp.parseMessage(testing.allocator, resp);
    defer pm.deinit();
    const obj = pm.message.response.result.?.object;
    try testing.expect(obj.get("more").?.bool);
    const recs = obj.get("records").?.array.items;
    try testing.expectEqual(@as(usize, 2), recs.len);
    try testing.expectEqual(@as(i64, 7), recs[0].object.get("at").?.integer); // 최근 것이 남는다
    try testing.expectEqual(@as(i64, 8), recs[1].object.get("at").?.integer);
    try testing.expectEqualStrings(weird, recs[1].object.get("path").?.string);
    // 한 건도 안 들면 한 건은 낸다(빈 응답보다 낫다 — 프레임 상한 안이다).
    const one = try serializeLogWithin(testing.allocator, .{ .number = 2 }, text.items, 8, 100);
    defer testing.allocator.free(one);
    var po = try cp.parseMessage(testing.allocator, one);
    defer po.deinit();
    try testing.expectEqual(@as(usize, 1), po.message.response.result.?.object.get("records").?.array.items.len);
    // 상한 건수의 최악(경로 상한 1 KiB 가 모두 제어 문자) 한 건도 프레임 상한 아래다.
    try testing.expect(log_response_budget < cp.default_max_frame);
}
